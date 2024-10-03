local BaseUtil = require("ffi/util")
local LuaSettings = require("luasettings")
local http = require("socket.http")
local ltn12 = require("ltn12")
local https = require("ssl.https")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local DocSettings = require("docsettings")
local sha2 = require("ffi/sha2")
local SQ3 = require("lua-ljsqlite3/init")
local ffi = require("ffi")

-- Functions expect config parameter, a lua table with the following keys:
-- zotero_dir: Path to a directory where cache files will be stored
-- api_key: self-explanatory
--
-- Directory layout of zoteroapi
-- /zotero.db: SQLite3 database that contains JSON items & collections
-- /storage/<KEY>/filename.pdf: Actual PDF files
-- /storage/<KEY>/version: Version number of downloaded attachment
-- /meta.lua: Metadata containing library version, items etc.

local API = {}

local SUPPORTED_MEDIA_TYPES = {
    [1] = "application/pdf",
    [2] = "application/epub+zip",
    [3] = "text/html"
}

local ZOTERO_DB_SCHEMA = [[
CREATE TABLE IF NOT EXISTS items (
    key TEXT PRIMARY KEY,
    value BLOB
);
CREATE TABLE IF NOT EXISTS collections (
    key TEXT PRIMARY KEY,
    value BLOB
);
]]
local ZOTERO_DB_UPDATE_ITEM = [[
INSERT INTO items(key, value) VALUES(?,jsonb(?)) ON CONFLICT DO UPDATE SET value = excluded.value;
]]

local ZOTERO_DB_UPDATE_COLLECTION = [[
INSERT INTO collections(key, value) VALUES(?,jsonb(?)) ON CONFLICT DO UPDATE SET value = excluded.value;
]]

local ZOTERO_DB_DELETE = [[
DELETE FROM items;
DELETE FROM collections;
PRAGMA user_version = 0;
]]

local ZOTERO_GET_DB_VERSION = [[ PRAGMA user_version; ]]

local ZOTERO_GET_ITEM = [[ SELECT json(items.value) FROM items WHERE key = ?; ]]

local ZOTERO_QUERY_ITEMS = [[
SELECT key, name, type FROM (SELECT
    key,
    jsonb_extract(value, '$.data.name') || '/' AS name,
    jsonb_extract(value, '$.data.parentCollection') AS parent_key,
    'collection' AS type
FROM collections
WHERE (jsonb_extract(value, '$.data.deleted') IS NOT 1) AND ((?1 IS NULL AND parent_key = false) OR (?1 IS NOT NULL AND parent_key = ?1))
ORDER BY name)
UNION ALL
SELECT key, name || title AS name, type FROM (
SELECT
    key,
    jsonb_extract(value, '$.data.title') AS title,
    -- if possible, prepend creator summary
    coalesce(jsonb_extract(value, '$.meta.creatorSummary') || ' - ', '') AS name,
    iif(jsonb_extract(value, '$.data.itemType') = 'attachment', 'attachment', 'item') AS type
FROM items
WHERE
-- don't display items in root collection
?1 IS NOT NULL
-- the item should not be deleted
AND (jsonb_extract(value, '$.data.deleted') IS NOT 1)
-- the item must belong to the collection we query
AND (?1 IN (SELECT value FROM json_each(jsonb_extract(items.value, '$.data.collections'))))
-- and it must either be an attachment or have at least one attachment
AND (jsonb_extract(value, '$.data.itemType') = 'attachment'
     OR (SELECT COUNT(key) FROM items AS child
            WHERE jsonb_extract(child.value, '$.data.parentItem') = items.key
                  AND jsonb_extract(child.value, '$.data.itemType') = 'attachment'
                  AND jsonb_extract(child.value, '$.data.deleted') IS NOT 1) > 0)
ORDER BY title);
]]

local ZOTERO_SEARCH_ITEMS = [[
SELECT
    key,
    jsonb_extract(value, '$.data.title') AS title,
    -- if possible, prepend creator summary
    coalesce(jsonb_extract(value, '$.meta.creatorSummary') || ' - ', '') AS name,
    iif(jsonb_extract(value, '$.data.itemType') = 'attachment', 'attachment', 'item') AS type
FROM items
WHERE
-- the item should not be deleted
(jsonb_extract(value, '$.data.deleted') IS NOT 1)
-- and it must either be an attachment or have at least one attachment
AND (jsonb_extract(value, '$.data.itemType') = 'attachment'
     OR (SELECT COUNT(key) FROM items AS child
            WHERE jsonb_extract(child.value, '$.data.parentItem') = items.key
                  AND jsonb_extract(child.value, '$.data.itemType') = 'attachment'
                  AND jsonb_extract(child.value, '$.data.deleted') IS NOT 1) > 0)
AND title LIKE ?1
ORDER BY title;
]]

local ZOTERO_GET_ATTACHMENTS = [[
SELECT
key,
jsonb_extract(value, '$.data.filename') AS filename,
(jsonb_extract(value, '$.data.contentType') = 'application/pdf') AS is_pdf
FROM items
WHERE
jsonb_extract(value, '$.data.itemType') = 'attachment' AND
jsonb_extract(value, '$.data.deleted') IS NOT 1 AND
((key = ?1) OR (jsonb_extract(value, '$.data.parentItem') = ?1))
ORDER BY is_pdf DESC, filename ASC;
]]

local function file_exists(path)
    if path == nil then return nil end
    return lfs.attributes(path) ~= nil
end

local function table_contains(t, search_value)
    for k, v in pairs(t) do
        if v == search_value then
            return true
        end
    end

    return false
end

local function file_slurp(path)
    if not file_exists(path) then
        return nil
    end
    local f = io.open(path, "r")

    if f == nil then
        return nil
    end

    local content = f:read("*all")
    f:close()
    return content
end

function API.cutDecimalPlaces(x, num_places)
    local fac = 10^num_places
    return math.floor(x * fac) / fac
end

function API.openDB()
    local db_path = BaseUtil.joinPath(API.zotero_dir, "zotero.db")
    local db = SQ3.open(db_path)

    return db
end

function API.init(zotero_dir)
    print("Z: initializing API")
    API.zotero_dir = zotero_dir
    local settings_path = BaseUtil.joinPath(API.zotero_dir, "meta.lua")
    API.settings = LuaSettings:open(settings_path)
    print("Z: settings opened")

    API.storage_dir = BaseUtil.joinPath(API.zotero_dir, "storage")
    if not file_exists(API.storage_dir) then
        lfs.mkdir(API.storage_dir)
    end

    print("Z: storage dir" .. API.storage_dir)

    local db = API.openDB()
    db:exec(ZOTERO_DB_SCHEMA)
    db:close()
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

function API.getWebDAVEnabled()
    return API.settings:isTrue("webdav_enabled")
end
function API.getWebDAVUser()
    return API.settings:readSetting("webdav_user")
end

function API.getWebDAVPassword()
    return API.settings:readSetting("webdav_password")
end

function API.getWebDAVUrl()
    return API.settings:readSetting("webdav_url")
end

function API.toggleWebDAVEnabled()
    API.settings:toggle("webdav_enabled")
end

function API.setWebDAVUser(user)
    API.settings:saveSetting("webdav_user", user)
end

function API.setWebDAVPassword(password)
    API.settings:saveSetting("webdav_password", password)
end

function API.setWebDAVUrl(url)
    API.settings:saveSetting("webdav_url", url)
end

function API.getLibraryVersion()
    local db = API.openDB()

    local result, ncol = db:exec(ZOTERO_GET_DB_VERSION)
    assert(ncol == 1)
    local version = tonumber(result[1][1])
    db:close()

    return version
end

function API.setLibraryVersion(version)
    local v = tonumber(version)
    local db = API.openDB()
    local sql = "PRAGMA user_version = " .. tostring(v) .. ";"
    db:exec(sql)
    db:close()
end

-- Retrieve underlying settings object to make changes from the outside
function API.getSettings()
    return API.settings
end


-- Check that a webdav connection works by performing a PROPFIND operation on the
-- URL with the associated credentials.
-- returns nil if no problems where found, otherwise error string
function API.checkWebDAV()
    local url = API.getWebDAVUrl()
    if url == nil then
        return "No WebDAV URL provided"
    end

    local user = API.getWebDAVUser()
    local pass = API.getWebDAVPassword()
    local headers = API.getWebDAVHeaders()

    local b, c, h = http.request {
        url = url,
        method = "PROPFIND",
        headers = headers
    }

    if c == 200 or c == 207 then
        return nil
    elseif c == 400 or c == 401 then
        return "Reached server, but access forbidden. Check username and password."
    end


end

-- List of zotero items that need to be synced to the server.  Items that are
-- modified will have a "key" property, new items will not carry this property.
function API.getModifiedItems()
    if API.modified_items == nil then
        API.modified_items = API.settings:readSetting("modified_items", {})
    end

    return API.modified_items
end


-- This just syncs them to disk, it will not modify the Zotero collection!
function API.saveModifiedItems()
    API.settings:flush()
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
    print("Z: Determining size of '" .. collection_url .. "'")
    local r, c, h = http.request {
        method = "HEAD",
        url = collection_url,
        headers = headers
    }

    local e = API.verifyResponse(r, c)
    if e ~= nil then return nil, e end

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
    local db = API.openDB()
    local stmt_update_item = db:prepare(ZOTERO_DB_UPDATE_ITEM)
    local stmt_update_collection = db:prepare(ZOTERO_DB_UPDATE_COLLECTION)
    local since = API.getLibraryVersion()

    local e, api_key, user_id = API.ensureKeyAndID()
    if e ~= nil then return e end
    print(e, api_key, user_id)

    local headers = API.getHeaders(api_key)
    local items_url = ("https://api.zotero.org/users/%s/items?since=%s&includeTrashed=true"):format(user_id, since)
    local collections_url = ("https://api.zotero.org/users/%s/collections?since=%s&includeTrashed=true"):format(user_id, since)

    -- Sync library items
    local r, e
    r, e = API.fetchCollectionPaginated(items_url, headers, function(partial_entries)
        print("Received callback, processing entries: " .. #partial_entries)
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local item = partial_entries[i]
            local key = item.key

            stmt_update_item:reset():bind(key, JSON.encode(item)):step()
        end
    end)
    if e ~= nil then return e end

 -- Sync library collections
    r, e = API.fetchCollectionPaginated(collections_url, headers, function(partial_entries)
        print("Received callback, processing entries: " .. #partial_entries)
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local collection = partial_entries[i]
            local key = collection.key

            stmt_update_collection:reset():bind(key, JSON.encode(collection)):step()
        end
    end)
    if e ~= nil then return e end

    API.setLibraryVersion(r)
    API.settings:flush()
    db:close()

    return nil
end

function API.getDirAndPath(item)
    if item == nil then
        return nil, nil
    else
        local dir = BaseUtil.joinPath(API.storage_dir, item.key)
        local file = BaseUtil.joinPath(dir, item.data.filename)
        return dir, file
    end
end

function API.getItem(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_GET_ITEM)
    stmt:reset():bind1(1,key)

    local result, nr = stmt:resultset()
    stmt:close()
    db:close()

    if nr == 0 then
        return nil
    else
        return JSON.decode(result[1][1])
    end
end

function API.getItemAttachments(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_GET_ATTACHMENTS)
    stmt:reset()
    stmt:bind1(1, key)

    local result, nr = stmt:resultset()

    stmt:close()
    db:close()

    if nr == 0 then
        return nil
    end

    local items = {}

    for i=1,nr do
        table.insert(items, {
            ["key"] = result[1][i],
            ["text"] = result[2][i],
            ["type"] = 'attachment',
        })
    end

    return items
end

-- Downloads an attachment file to the correct directory and returns the path.
-- If the local version is up to date, no network request is made.
-- Before the download, the download_callback is called.
-- Returns tuple with path and error, if path is correct then error is nil.
function API.downloadAndGetPath(key, download_callback)
    local e, api_key, user_id = API.ensureKeyAndID()
    if e ~= nil then return nil, e end

    local item = API.getItem(key)
    if item == nil then
        return nil, "Error: the requested file can not be found in the database"
    end

    if item.data.itemType ~= "attachment" then
        return nil, "Error: this item is not an attachment"
    elseif item.data.linkMode ~= "imported_file" then
        return nil, "Error: this item is not a stored attachment"
    elseif table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType) == false then
        return nil, "Error: this item has an unsupported content type (" .. item.data.contentType .. ")"
    end

    local targetDir, targetPath = API.getDirAndPath(item)
    lfs.mkdir(targetDir)

    local local_version = tonumber(file_slurp(targetDir .. "/version"))

    if local_version ~= nil and local_version >= item.version and file_exists(targetPath) then
        return targetPath, nil -- all done, local file is up to date
    end

    if download_callback ~= nil then download_callback() end

    if API.settings:isTrue("webdav_enabled") then
        local result, errormsg = API.downloadWebDAV(key, targetDir, targetPath)
        if result == nil then
            return nil, errormsg
        end
    else
        local url = "https://api.zotero.org/users/" .. API.getUserID() .. "/items/" .. key .. "/file"
        print("Fetching " .. url)

        local r, c, h = http.request {
            url = url,
            headers = API.getHeaders(api_key),
            redirect = true,
            sink = ltn12.sink.file(io.open(targetPath, "wb"))
        }

        local e = API.verifyResponse(r, c)
        if e ~= nil then return nil, e end
    end

    local versionFile = io.open(targetDir .. "/version", "w")
    if versionFile == nil then
        return nil, "Could not write version file"
    end
    versionFile:write(tostring(item.version))
    versionFile:close()

    return targetPath, nil
end

function API.downloadWebDAV(key, targetDir, targetPath)
    if API.getWebDAVUrl() == nil then
        return nil, "WebDAV url not set"
    end
    local url = API.getWebDAVUrl() .. "/" .. key .. ".zip"
    local headers = API.getWebDAVHeaders()
    local zipPath = targetDir .. "/" .. key .. ".zip"
    print("Fetching URL " .. url)
    local r, c, h = http.request {
        method = "GET",
        url = url,
        headers = headers,
        redirect = true,
        sink = ltn12.sink.file(io.open(zipPath, "wb"))
    }

    if c ~= 200 then
        return nil, "Download failed with status code " .. c
    end

    -- Zotero WebDAV storage packs documents inside a zipfile
    local zip_cmd = "unzip -qq '" .. zipPath .. "' -d '" .. targetDir .. "'"
    print("Unzipping with " .. zip_cmd)
    local zip_result = os.execute(zip_cmd)
    if zip_result then
        return targetPath
    else
        return nil, "Unzipping failed"
    end

    local remove_result = os.remove(zipPath)
end

function API.getWebDAVHeaders()
    local user = API.getWebDAVUser() or ""
    local pass = API.getWebDAVPassword() or ""

    return {
        ["Authorization"] = "Basic " .. sha2.bin_to_base64(user .. ":" .. pass)
    }
end

-- Return a table of entries of a collection.
--
-- If key is nil, entries of the root collection will be given.
-- Each entry is a table with at least two values, the key and name.
-- Collections will have a display name that ends with a slash and contain true
-- under the key "collection" in their table.
function API.displayCollection(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_QUERY_ITEMS)

    stmt:reset()
    stmt:clearbind()

    if key ~= nil then
        stmt:bind1(1, key)
    end

    local result = {}
    local row, _ = stmt:step({}, {})
    while row ~= nil do
        table.insert(result, {
            ["key"] = row[1],
            ["text"] = row[2],
            ["type"] = row[3],
        })

        print(tostring(row[2]) .. " type = " .. (row[3] or 'nil'))

        row = stmt:step(row)
    end
    stmt:close()
    db:close()

    return result
end

function API.displaySearchResults(query)
    local queryExpr = "%" .. string.gsub(query, " ", "%") .. "%"
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_SEARCH_ITEMS)

    stmt:reset()
    stmt:clearbind()

    stmt:bind1(1, queryExpr)

    local result = {}
    local row, _ = stmt:step({}, {})
    while row ~= nil do
        table.insert(result, {
            ["key"] = row[1],
            ["text"] = row[2],
            ["type"] = row[3],
        })

        print(tostring(row[2]) .. " type = " .. (row[3] or 'nil'))

        row = stmt:step(row)
    end
    stmt:close()
    db:close()

    return result
end


-- Output the timezone-agnostic timestamp, since KOReader uses timestamps with
-- local time.
function API.addTimezone(timestamp)
    local year, month, day, hour, minute, second = string.match(timestamp,
        "(%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)")
    local time = {
        ["year"] = year,
        ["month"] = month,
        ["day"] = day,
        ["hour"] = hour,
        ["min"] = minute,
        ["sec"] = second
    }

    return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time(time))
end

function API.localTimezone(timestamp)
end

function API.compareTimestamps(zoteroTimestamp, koreaderTimestamp)
    local a,b = zoteroTimestamp, API.addTimezone(koreaderTimestamp)

    if a == b then
       return 0
    elseif a < b then
        return -1
    else
        return 1
    end
end

function API.syncModifiedItems()
    local modItems = API.getModifiedItems()
end

function API.resetSyncState()
    local db = API.openDB()
    db:exec(ZOTERO_DB_DELETE)
    db:close()
end

return API
