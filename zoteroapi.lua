local BaseUtil = require("ffi/util")
local LuaSettings = require("luasettings")
local http = require("socket.http")
local ltn12 = require("ltn12")
local https = require("ssl.https")
local JSON = require("json")

-- Functions expect config parameter, a lua table with the following keys:
-- zotero_dir: Path to a directory where cache files will be stored
-- api_key: self-explanatory
--
-- Directory layout of zotero_di
-- /items.json: Contains all items
-- /storage/<KEY>/filename.pdf: Actual PDF files
-- /meta.lua: Metadata containing library version, items etc.

local API = {}

function API.init(zotero_dir)
    API.zotero_dir = zotero_dir
    local settings_path = BaseUtil.joinPath(API.zotero_dir, "meta.lua")
    print(settings_path)
    API.settings = LuaSettings:open(settings_path)
end

function API.setAPIKey(api_key)
    API.settings:saveSetting("api_key", api_key)
end

function API.setUserID(user_id)
    API.settings:saveSetting("user_id", user_id)
end

function API.getLibraryVersion(config)
    return API.settings:readSetting("library_version", 0)
end

function API.setItems(items)
    return API.settings:saveSetting("items", items)
end

function API.getItems()
    return API.settings:readSetting("items", {})
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

function API.fetchCollectionPaginated(collection_url, headers, callback)
    -- Try to determine the size
    local collection_size, e = API.fetchCollectionSize(collection_url, headers)
    if e ~= nil then return nil, e end

    print(("Fetching %s items."):format(collection_size))
    -- The API returns the results in pages with 100 entries each, loop accordingly.
    local items = {}
    for item_nr = 0, collection_size, 25 do
        local page_url = ("%s&limit=25&start=%i"):format(collection_url, item_nr)
        print("Fetching page ", item_nr, page_url)

        local page_data = {}
        local r, c, h = http.request {
            method = "GET",
            url = page_url,
            headers = headers,
            sink = ltn12.sink.table(page_data)
        }

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

    return items, nil

end

function API.syncItems()
    local user_id = API.settings:readSetting("user_id", "")
    local api_key = API.settings:readSetting("api_key", "")
    local since = API.settings:readSetting("library_version", 0)

    if user_id == "" then
        return "Error: must set User ID"
    else if api_key == "" then
        return "Error: must set API Key"
    end

    local headers = {
        ["zotero-api-key"] = api_key,
        ["zotero-api-version"] = "3"
    }

    local items_url = ("https://api.zotero.org/users/%s/items?since=%s"):format(user_id, since)

    local items = API.getItems()
    local r, e = API.fetchCollectionPaginated(items_url, headers, function(partial_entries) 
        print("Received callback, processing entries: " .. #partial_entries)
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local item = partial_entries[i]
            local key = item.key
            items[key] = item
        end
    end)
    API.setItems(items)
    API.settings:flush()

    return nil
end



end

return API
