local BaseUtil = require("ffi/util")
local LuaSettings = require("luasettings")
local http = require("socket.http")
local ltn12 = require("ltn12")
local https = require("ssl.https")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local DocSettings = require("docsettings")

-- Functions expect config parameter, a lua table with the following keys:
-- zotero_dir: Path to a directory where cache files will be stored
-- api_key: self-explanatory
--
-- Directory layout of zotero_di
-- /items.json: Contains all items
-- /storage/<KEY>/filename.pdf: Actual PDF files
-- /meta.lua: Metadata containing library version, items etc.

local API = {}

local SUPPORTED_MEDIA_TYPES = {
    [1] = "application/pdf"
}

function joinTables(target, source)
    return table.move(source, 1, #source, #target + 1, target)
end

function file_exists(path)
    if path == nil then return nil end
    return lfs.attributes(path) ~= nil
end

function table_contains(t, search_value)
    for k, v in pairs(t) do
        if v == search_value then
            return true
        end
    end

    return false
end

function file_slurp(path)
    if not file_exists(path) then
        return nil
    else
        f = io.open(path, "r")
        local content = f:read("*all")
        f:close()
        return content
    end
end

function API.cutDecimalPlaces(x, num_places)
    local fac = 10^num_places
    return math.floor(x * fac) / fac
end

function API.bboxFromZotero(bbox)
    return {
        ["x"]= bbox[1],
        ["y"]= bbox[2],
        ["w"]= bbox[3] - bbox[1],
        ["h"]= bbox[4] - bbox[2]
    }
end

function API.bboxToZotero(bbox, places)
    return {
        [1] = API.cutDecimalPlaces(bbox.x, places),
        [2] = API.cutDecimalPlaces(bbox.y, places),
        [3] = API.cutDecimalPlaces(bbox.x + bbox.w, places),
        [4] = API.cutDecimalPlaces(bbox.y + bbox.h, places)
    }
end

function API.bboxEqual(a, b, tolerance)
    return (math.abs(a.x - b.x) < tolerance 
        and math.abs(a.y - b.y) < tolerance 
        and math.abs(a.w - b.w) < tolerance 
        and math.abs(a.h - b.h) < tolerance)
end

function API.init(zotero_dir)
    API.zotero_dir = zotero_dir
    local settings_path = BaseUtil.joinPath(API.zotero_dir, "meta.lua")
    print(settings_path)
    API.settings = LuaSettings:open(settings_path)

    API.storage_dir = BaseUtil.joinPath(API.zotero_dir, "storage")
    if not file_exists(API.storage_dir) then
        lfs.mkdir(API.storage_dir)
    end
end

function API.getAPIKey()
    return API.settings:readSetting("api_key")
end
function API.setAPIKey(api_key)
    API.settings:saveSetting("api_key", api_key)
end

function API.getUserID()
    return API.settings:readSetting("user_id")
end

function API.setUserID(user_id)
    API.settings:saveSetting("user_id", user_id)
end

function API.getLibraryVersion()
    return API.settings:readSetting("library_version_nr", "0")
end

function API.setLibraryVersion(version)
    return API.settings:saveSetting("library_version_nr", version)
end

function API.getFilterTag()
    return API.settings:readSetting("filter_tag", "")
end

function API.setFilterTag(tag)
    return API.settings:saveSetting("filter_tag", tag)
end

function API.setItems(items)
    API.items = items
    local f = assert(io.open(BaseUtil.joinPath(API.zotero_dir, "items.json"), "w"))
    local content = JSON.encode(API.items)
    f:write(content)
    f:close()
end

function API.getItems()
    if API.items == nil then
        local path = BaseUtil.joinPath(API.zotero_dir, "items.json")
        local file_exists = lfs.attributes(path)

        if not file_exists then
            API.items = {}
        else
            API.items = JSON.decode(file_slurp(path))
        end
    end

    return API.items
end

function API.getCollections()
    if API.collections == nil then
        local path = BaseUtil.joinPath(API.zotero_dir, "collections.json")
        local file_exists = lfs.attributes(path)

        if not file_exists then
            API.collections = {}
        else
            API.collections = JSON.decode(file_slurp(path))
        end
    end

    return API.collections
end

function API.setCollections(collections)
    API.collections = collections
    local f = assert(io.open(BaseUtil.joinPath(API.zotero_dir, "collections.json"), "w"))
    local content = JSON.encode(API.collections)
    f:write(content)
    f:close()
end

function API.verifyResponse(r, c)
    if r ~= 1 then
        return ("Error: " .. c)
    elseif c ~= 200 then
        return ("Error: API responded with status code " .. c)
    end

    return nil
end

function API.fetchCollectionSize(collection_url, headers)
    print("Determining size of '" .. collection_url .. "'")
    local r, c, h = http.request {
        method = "HEAD",
        url = collection_url,
        headers = headers
    }

    local e = API.verifyResponse(r, c)
    if e ~= nil then return nil, e end

    print(JSON.encode(h))
    local total_results = tonumber(h["total-results"])
    if total_results == nil or total_results < 0 then
        return nil, "Error: could not determine number of items in library"
    end

    return tonumber(total_results)
end

-- Fetches a paginated URL collection.
--
-- If no callback is given, it returns an array containing all entries of the collection.
--
-- If a callback is given, it will be called with the entries on each page as they are fetched
-- and the function will return the version number.
--
-- If an error occurs, the function will return nil and the error message as second parameter.
function API.fetchCollectionPaginated(collection_url, headers, callback)
    -- Try to determine the size
    local collection_size, e = API.fetchCollectionSize(collection_url, headers)
    if e ~= nil then return nil, e end

    print(("Fetching %s items."):format(collection_size))
    -- The API returns the results in pages with 100 entries each, loop accordingly.
    local items = {}
    local library_version = 0
    local step_size = 100
    for item_nr = 0, collection_size, step_size do
        local page_url = ("%s&limit=%i&start=%i"):format(collection_url, step_size, item_nr)
        print("Fetching page ", item_nr, page_url)

        local page_data = {}
        local r, c, h = http.request {
            method = "GET",
            url = page_url,
            headers = headers,
            sink = ltn12.sink.table(page_data)
        }

        library_version = h["last-modified-version"]

        local e = API.verifyResponse(r, c)
        if e ~= nil then return nil, e end

        local content = table.concat(page_data, "")
        local ok, result = pcall(JSON.decode, content)
        if not ok then
            return nil, "Error: failed to parse JSON in response"
        end

        if callback then
            callback(result)
        else
            -- add items to the list we return in the end
            table.move(result, 1, #result, #items + 1, items)
        end
    end

    if callback then
        return library_version, nil
    else
        return items, nil
    end

end

function API.ensureKeyAndID()
    local user_id = API.settings:readSetting("user_id", "")
    local api_key = API.settings:readSetting("api_key", "")

    if user_id == "" then
        return "Error: must set User ID"
    elseif api_key == "" then
        return "Error: must set API Key"
    end

    return nil, api_key, user_id
end

function API.getHeaders(api_key)
    return {
        ["zotero-api-key"] = api_key,
        ["zotero-api-version"] = "3"
    }
end

function API.syncAllItems()
    local since = API.getLibraryVersion()

    local e, api_key, user_id = API.ensureKeyAndID()
    if e ~= nil then return e end
    print(e, api_key, user_id)

    local headers = API.getHeaders(api_key)
    local items_url = ("https://api.zotero.org/users/%s/items?since=%s"):format(user_id, since)
    local collections_url = ("https://api.zotero.org/users/%s/collections?since=%s"):format(user_id, since)

    -- Sync library items
    local items = API.getItems()
    print("loaded items: " .. #items)
    local r, e = API.fetchCollectionPaginated(items_url, headers, function(partial_entries)
        print("Received callback, processing entries: " .. #partial_entries)
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local item = partial_entries[i]
            local key = item.key
            items[key] = item
        end
    end)
    if e ~= nil then return e end
    API.setItems(items)

    -- Sync library collections
    local collections = API.getCollections()
    local r, e = API.fetchCollectionPaginated(collections_url, headers, function(partial_entries)
        print("Received callback, processing entries: " .. #partial_entries)
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local collection = partial_entries[i]
            local key = collection.key
            collections[key] = collection
        end
    end)
    if e ~= nil then return e end
    API.setCollections(collections)

    API.setLibraryVersion(r)
    API.settings:flush()

    return nil
end

-- If a tag is set, ensure all entries actually have that tag and it has not been removed
-- If no tag is set, just remove all deleted entries from the library
function API.purgeEntries()

end

--function API.fetchItemDetails(url, headers)
--    local e, api_key, user_id = API.ensureKeyAndID()
--    if e ~= nil then return nil, e end
--
--    local headers = joinTables(headers or {}, API.getHeaders(api_key))
--
--    local data = {}
--    r, c, h = http.request {
--        method = "GET",
--        url = url,
--        headers = headers,
--        sink = ltn12.sink.table(data)
--    }
--
--    local content = table.concat(data)
--    local ok, result = pcall(JSON.decode, content)
--    if not ok then
--        return nil, "Error: failed to parse JSON in response"
--    end
--
--    return result, nil
--end

-- Downloads an attachment file to the correct directory and returns the path.
-- If the local version is up to date, no network request is made.
-- Before the download, the download_callback is called.
-- Returns tuple with path and error, if path is correct then error is nil.
function API.downloadAndGetPath(key, download_callback)
    local e, api_key, user_id = API.ensureKeyAndID()
    if e ~= nil then return nil, e end

    local items = API.getItems()
    if items[key] == nil then
        return nil, "Error: the requested file can not be found in the database"
    end
    local item = items[key]

    if item.data.itemType ~= "attachment" then
        return nil, "Error: this item is not an attachment"
    end

    local attachment = item

    local targetDir = API.storage_dir .. "/" .. attachment.data.parentItem
    lfs.mkdir(targetDir)

    local local_version = tonumber(file_slurp(targetDir .. "/version"))
    local targetPath = targetDir .. "/" .. attachment.data.filename

    if local_version ~= nil and local_version >= attachment.version and file_exists(targetPath) then
        return targetPath, nil -- all done, local file is up to date
    end

    if download_callback ~= nil then download_callback() end

    local url = attachment.links.enclosure.href

    print("Fetching " .. url)
    r, c, h = http.request {
        url = url,
        headers = API.getHeaders(api_key),
        redirect = true,
        sink = ltn12.sink.file(io.open(targetPath, "wb"))
    }

    local e = API.verifyResponse(r, c)
    if e ~= nil then return nil, e end

    local versionFile = io.open(targetDir .. "/version", "w")
    versionFile:write(tostring(attachment.version))
    versionFile:close()

    return targetPath, nil
end

-- Return a table of entries of a collection.
--
-- If key is nil, entries of the root collection will be given.
-- Each entry is a table with at least two values, the key and name.
-- Collections will have a display name that ends with a slash and contain true
-- under the key "collection" in their table.
function API.displayCollection(key)
    local result = {}

    -- Get list of collections
    local collections = API.getCollections()
    for k, collection in pairs(collections) do
        if (key == nil and collection.data.parentCollection == false) or
            (key ~= nil and collection.data.parentCollection == key) then
            table.insert(result, {
                ["key"] = k,
                ["text"] = collection.data.name .. "/",
                ["collection"] = true
            })
        end
    end
    -- Sort collections by name
    local comparator = function(a,b)
        return (a["text"] < b["text"])
    end
    table.sort(result, comparator)

    -- Get list of items
    -- Careful: linear search. Can be optimized quite a bit!
    local items = API.getItems()
    local collectionItems = {}

    for k, item in pairs(items) do
        if item.data.itemType == "attachment"
            and table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType )
            and item.data.parentItem ~= nil then
            local parentItem = items[item.data.parentItem]
            if parentItem ~= nil and table_contains(parentItem.data.collections, key) then
                local author = parentItem.meta.creatorSummary or "Unknown"
                local name = author .. " - " .. parentItem.data.title

                print("Content: " .. item.data.contentType .. "\n" .. JSON.encode(item))
                table.insert(collectionItems, {
                    ["key"] = k,
                    ["text"] = name
                })
            end
        end
    end
    table.sort(collectionItems, comparator)

    -- Join collections and items together and return it
    return joinTables(result, collectionItems)
end

function API.displaySearchResults(query)
    local queryRegex = ".*" .. string.gsub(query, " ", ".*") .. ".*"
    print("Searching for " .. queryRegex)
    -- Careful: linear search. Can be optimized quite a bit!
    local items = API.getItems()
    local results = {}

    for k, item in pairs(items) do
        if item.data.itemType == "attachment" 
            and table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType )
            and item.data.parentItem ~= nil then
            local parentItem = items[item.data.parentItem]
            if parentItem ~= nil then
                local author = parentItem.meta.creatorSummary or "Unknown"
                local name = author .. " - " .. parentItem.data.title

                if parentItem.data.DOI ~= nil and parentItem.data.DOI ~= "" then
                    name = name .. " - " .. parentItem.data.DOI
                end

                if string.match(name, queryRegex) then
                    table.insert(results, {
                        ["key"] = k,
                        ["text"] = name
                    })
                end
            end
        end
    end

    return results
end

return API
