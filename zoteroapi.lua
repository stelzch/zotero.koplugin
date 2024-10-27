local BaseUtil = require("ffi/util")
local LuaSettings = require("luasettings")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local sha2 = require("ffi/sha2")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")
local Annotations = require("annotations")
local _ = require("gettext")

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
CREATE TABLE IF NOT EXISTS itemData (
	itemID INTEGER PRIMARY KEY,    
    value BLOB,
    FOREIGN KEY (itemID) REFERENCES items(itemID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS items (    
	itemID INTEGER PRIMARY KEY,    
	itemTypeID INT NOT NULL,    
	libraryID INT NOT NULL,    
	key TEXT NOT NULL,    
	version INT NOT NULL DEFAULT 0,    
	synced INT NOT NULL DEFAULT 0,    
	UNIQUE (libraryID, key),    
	FOREIGN KEY (libraryID) REFERENCES libraries(libraryID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS libraries (
	libraryID INTEGER PRIMARY KEY,
	type TEXT NOT NULL,
	editable INT NOT NULL,
	name TEXT NOT NUll,
	userID INT NOT NULL DEFAULT 0,
	version INT NOT NULL DEFAULT 0,
	storageVersion INT NOT NULL DEFAULT 0,
	lastSync INT NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS collections (    
	collectionID INTEGER PRIMARY KEY,
	collectionName TEXT NOT NULL,
	parentCollectionID INT DEFAULT NULL,
	libraryID INT NOT NULL,
	key TEXT NOT NULL,
	version INT NOT NULL DEFAULT 0,
	synced INT NOT NULL DEFAULT 0,
	UNIQUE (libraryID, key),
	FOREIGN KEY (libraryID) REFERENCES libraries(libraryID) ON DELETE CASCADE,
	FOREIGN KEY (parentCollectionID) REFERENCES collections(collectionID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS collectionItems (
	collectionID INT NOT NULL,
	itemID INT NOT NULL,
	PRIMARY KEY(collectionID, itemID), 
	FOREIGN KEY (collectionID) REFERENCES collections(collectionID) ON DELETE CASCADE,
	FOREIGN KEY (itemID) REFERENCES items(itemID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS itemTypes ( 
	itemTypeID INTEGER PRIMARY KEY, 
	typeName TEXT, 
	display INT DEFAULT 1 
);
CREATE TABLE IF NOT EXISTS itemAttachments ( 
	itemID INTEGER PRIMARY KEY, 
	parentItemID INT,
	syncedVersion INT NOT NULL DEFAULT 0,
	FOREIGN KEY (itemID) REFERENCES items(itemID) ON DELETE CASCADE,
	FOREIGN KEY (parentItemID) REFERENCES items(itemID) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS itemAnnotations ( 
	itemID INTEGER PRIMARY KEY, 
	parentItemID INT,
	syncedVersion INT NOT NULL DEFAULT 0,
	FOREIGN KEY (itemID) REFERENCES items(itemID) ON DELETE CASCADE,
	FOREIGN KEY (parentItemID) REFERENCES items(itemID) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS offline_collections(
    key TEXT PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS attachment_versions(
    key TEXT PRIMARY KEY,
    version INTEGER
);
]]

local ZOTERO_DB_INIT_ITEMTYPES = [[
INSERT INTO itemTypes(itemTypeID,typeName)
VALUES
(1,"annotation"          ),
(2,"artwork"             ),
(3,"attachment"          ),
(4,"audioRecording"      ),
(5,"bill"                ),
(6,"blogPost"            ),
(7,"book"                ),
(8,"bookSection"         ),
(9,"case"                ),
(10,"computerProgram"    ),
(11,"conferencePaper"    ),
(12,"dictionaryEntry"    ),
(13,"document"           ),
(14,"email"              ),
(15,"encyclopediaArticle"),
(16,"film"               ),
(17,"forumPost"          ),
(18,"hearing"            ),
(19,"instantMessage"     ),
(20,"interview"          ),
(21,"journalArticle"     ),
(22,"letter"             ),
(23,"magazineArticle"    ),
(24,"manuscript"         ),
(25,"map"                ),
(26,"newspaperArticle"   ),
(27,"note"               ),
(28,"patent"             ),
(29,"podcast"            ),
(30,"preprint"           ),
(31,"presentation"       ),
(32,"radioBroadcast"     ),
(33,"report"             ),
(34,"statute"            ),
(35,"thesis"             ),
(36,"tvBroadcast"        ),
(37,"videoRecording"     ),
(38,"webpage"            ),
(39,"dataset"            ),
(40,"standard"           );
]]

--[[
local ZOTERO_CREATE_VIEWS = [[ 
CREATE TEMPORARY TABLE IF NOT EXISTS supported_media_types (mime TEXT);
INSERT INTO supported_media_types(mime) VALUES ('application/pdf'), ('application/epub+zip'), ('text/html') ON CONFLICT DO NOTHING;

CREATE TEMPORARY TABLE IF NOT EXISTS supported_link_types (type TEXT);
INSERT INTO supported_link_types(type) VALUES ('imported_file'), ('imported_url') ON CONFLICT DO NOTHING;

-- create view that holds metadata of the parent item. if it does not exist, it is equal to the item itself
CREATE TEMPORARY VIEW IF NOT EXISTS attachment_data AS
SELECT items.key AS key, items.value AS value, parents.key AS parent_key, coalesce(parents.value, items.value) AS parent_value
FROM items
LEFT JOIN items AS parents ON jsonb_extract(items.value, '$.data.parentItem') = parents.key
WHERE
(jsonb_extract(items.value, '$.data.itemType')  = 'attachment');


CREATE TEMPORARY VIEW IF NOT EXISTS item_download_queue AS
-- A collection is a offline collection if it is in the respective table or any of its parent collections are 
-- in the respective table
WITH RECURSIVE collection_hierarchy(key) AS
 (SELECT key FROM offline_collections -- starting values are all collections inside the offline_collections table
  UNION
  SELECT collections.key              -- select all other keys of collections
  FROM collections, collection_hierarchy 
  WHERE jsonb_extract(collections.value, '$.data.parentCollection') = collection_hierarchy.key) -- whose parentCollection is the collection we just inserted
SELECT attachment_data.key FROM attachment_data
LEFT JOIN attachment_versions ON attachment_data.key = attachment_versions.key
WHERE
-- must be an attachment with supported media type
(jsonb_extract(value, '$.data.itemType') = 'attachment') AND
(jsonb_extract(value, '$.data.linkMode') IN (SELECT type FROM supported_link_types)) AND
(jsonb_extract(value, '$.data.contentType') IN (SELECT mime FROM supported_media_types)) AND
-- the item may not be deleted
(jsonb_extract(value, '$.data.deleted') IS NOT 1)
-- and must belong to a collection in the offline collection hierarchy
AND EXISTS (SELECT collection_hierarchy.key FROM collection_hierarchy INTERSECT SELECT value FROM json_each(jsonb_extract(attachment_data.parent_value, '$.data.collections')))
-- and local version must be lower than remote version (otherwise its considered up-to-date)
AND coalesce((SELECT version FROM attachment_versions WHERE attachment_versions.key = attachment_data.key), 0) < jsonb_extract(attachment_data.value, '$.version');

-- select all pdf attachments present locally
CREATE TEMPORARY VIEW IF NOT EXISTS local_pdf_items AS
SELECT
    items.key AS key,
    jsonb_extract(items.value, '$.data.filename') AS filename
FROM attachment_versions
LEFT JOIN items ON attachment_versions.key = items.key
WHERE
(jsonb_extract(items.value, '$.data.linkMode') IN (SELECT type FROM supported_link_types)) AND
(jsonb_extract(items.value, '$.data.contentType') = 'application/pdf');
]]
--]]

local ZOTERO_DB_INIT_LIBS = [[
-- only insert item if table is empty:
INSERT INTO libraries(type, editable, name) SELECT 'user',1,'' WHERE NOT EXISTS(SELECT libraryID FROM libraries);
]]

local ZOTERO_DB_INIT_COLLECTIONS = [[
-- only insert item if table is empty:
-- 'Fake collection' for items in root
INSERT INTO collections(collectionName, libraryID, key) SELECT '',1,'/' WHERE NOT EXISTS(SELECT collectionID FROM collections);
]]

local ZOTERO_GET_DOWNLOAD_QUEUE = [[
select
    item_download_queue.key,
    jsonb_extract(items.value, '$.data.filename') as filename
from item_download_queue
left join items on items.key = item_download_queue.key;
]]

local ZOTERO_GET_DOWNLOAD_QUEUE_SIZE = [[ SELECT COUNT(*) FROM item_download_queue; ]]

local ZOTERO_GET_LOCAL_PDF_ITEMS = [[ SELECT * FROM local_pdf_items; ]]

local ZOTERO_GET_LOCAL_PDF_ITEMS_SIZE = [[ SELECT COUNT(*) FROM local_pdf_items; ]]

local ZOTERO_DB_UPDATE_ITEM = [[
INSERT INTO items(itemTypeID, libraryID, key, version) SELECT itemTypeID, ?1, ?3, ?4 FROM itemTypes WHERE typeName IS ?2 
ON CONFLICT DO UPDATE SET itemTypeID = excluded.itemTypeID, version = excluded.version;
]]
local ZOTERO_DB_DELETE_ITEM = [[
DELETE FROM items WHERE key IS ?1
]]

local ZOTERO_DB_UPDATE_ITEMDATA = [[
INSERT INTO itemData(itemID, value) SELECT itemID,jsonb(?2) FROM items WHERE key IS ?1 
ON CONFLICT DO UPDATE SET value = excluded.value;
]]

local ZOTERO_DB_UPDATE_COLLECTION = [[
-- hardcoded libraryID = 1 for now
INSERT INTO collections(collectionName, parentCollectionID, libraryID , key, version) SELECT ?1, collectionID, 1, ?3, ?4 FROM collections WHERE key=?2
ON CONFLICT DO UPDATE SET collectionName = excluded.collectionName, version = excluded.version, parentCollectionID = excluded.parentCollectionID;
]]
local ZOTERO_DB_DELETE_COLLECTION = [[
DELETE FROM collections WHERE key IS ?1
]]

local ZOTERO_DB_UPDATE_COLLECTION_ITEMS = [[
INSERT INTO collectionItems(collectionID, itemID) SELECT collections.collectionID, items.itemID FROM collections, items WHERE collections.key = ?1 AND items.key=?2
ON CONFLICT DO NOTHING;
]]

local ZOTERO_DB_DELETE = [[
DELETE FROM libraries;
DELETE FROM items;
DELETE FROM itemData;
DELETE FROM collections;
DELETE FROM offline_collections;
DELETE FROM attachment_versions;
PRAGMA user_version = 0;
]]

local ZOTERO_GET_DB_VERSION = [[ PRAGMA user_version; ]]

local ZOTERO_GET_ITEM = [[ SELECT json(value) 	FROM 
		itemData INNER JOIN items ON itemData.itemID = items.itemID WHERE items.key = ?; ]]

local ZOTERO_GET_OFFLINE_COLLECTION = [[ SELECT key FROM offline_collections WHERE key = ?; ]]
local ZOTERO_ADD_OFFLINE_COLLECTION = [[ INSERT INTO offline_collections(key) VALUES(?); ]]
local ZOTERO_REMOVE_OFFLINE_COLLECTION = [[ DELETE FROM offline_collections WHERE key = ?; ]]

local ZOTERO_QUERY_ITEMS = [[
WITH cid AS (SELECT collectionID AS ID FROM collections WHERE key = ?1) 
SELECT 
	key, 
	collectionName || '/', 
	'collection' 
FROM collections, cid 
WHERE parentCollectionID = cid.ID
UNION ALL
SELECT 
	key, 
	name || title AS name, 
	type 
FROM (
	SELECT
	   items.key,
		jsonb_extract(value, '$.data.title') AS title,
		---- if possible, prepend creator summary
		coalesce(jsonb_extract(value, '$.meta.creatorSummary') || ' - ', '') AS name,
		iif(items.itemTypeID = 3, 'attachment', 'item') AS type
	FROM 
		itemData INNER JOIN items ON itemData.itemID = items.itemID, cid
	WHERE
		itemData.itemID IN (SELECT itemID FROM collectionItems,cid WHERE collectionID = cid.ID
	)
);

---- don't display items in root collection
--?1 IS NOT NULL
---- the item should not be deleted
--AND (jsonb_extract(value, '$.data.deleted') IS NOT 1)
---- the item must belong to the collection we query
--AND (?1 IN (SELECT value FROM json_each(jsonb_extract(items.value, '$.data.collections'))))
---- and it must either be an attachment or have at least one attachment
--AND (jsonb_extract(value, '$.data.itemType') = 'attachment'
     --OR (SELECT COUNT(key) FROM items AS child
            --WHERE jsonb_extract(child.value, '$.data.parentItem') = items.key
                  --AND jsonb_extract(child.value, '$.data.itemType') = 'attachment'
                  --AND jsonb_extract(child.value, '$.data.deleted') IS NOT 1) > 0)
--ORDER BY title);
]]

local ZOTERO_SEARCH_ITEMS = [[
SELECT
    key,
    jsonb_extract(value, '$.data.title') AS title,
    -- if possible, prepend creator summary
    coalesce(jsonb_extract(value, '$.meta.creatorSummary') || ' - ', '') AS name,
	iif(items.itemTypeID = 3, 'attachment', 'item') AS type
FROM itemData INNER JOIN items ON itemData.itemID = items.itemID 
WHERE
-- the item should not be deleted
(jsonb_extract(value, '$.data.deleted') IS NOT 1)
-- and it must either be an attachment or have at least one attachment
AND (items.itemTypeID = 3)
     --OR (SELECT COUNT(key) FROM items AS child
            --WHERE jsonb_extract(child.value, '$.data.parentItem') = items.key
                  --AND jsonb_extract(child.value, '$.data.itemType') = 'attachment'
                  --AND jsonb_extract(child.value, '$.data.deleted') IS NOT 1) > 0)
AND title LIKE ?1
ORDER BY title;
]]

local ZOTERO_GET_ATTACHMENTS = [[
SELECT
	key,
	jsonb_extract(value, '$.data.filename') AS filename,
	(jsonb_extract(value, '$.data.contentType') = 'application/pdf') AS is_pdf
FROM itemData INNER JOIN items ON itemData.itemID = items.itemID 
WHERE
	items.itemTypeID = 3 AND
	jsonb_extract(value, '$.data.deleted') IS NOT 1 AND
	((key = ?1) OR (jsonb_extract(value, '$.data.parentItem') = ?1));
--ORDER BY is_pdf DESC, filename ASC;
]]
local ZOTERO_GET_ITEM_ANNOTATIONS_INFO = [[
SELECT
	key,
	version,
	syncedVersion
FROM 
	itemAnnotations INNER JOIN items ON itemAnnotations.itemID = items.itemID 
WHERE
	itemAnnotations.parentItemID IN (SELECT itemID FROM items WHERE key = ?1);
]]
local ZOTERO_INSERT_ITEM_ATTACHMENTS = [[
INSERT INTO itemAttachments(itemID, parentItemID) SELECT i.itemID, p.itemID FROM items i, items p WHERE i.key = ?1 AND p.key=?2;
ON CONFLICT DO UPDATE SET parentItemID = excluded.parentItemID;
]]

local ZOTERO_INSERT_ITEM_ANNOTATIONS = [[
INSERT INTO itemAnnotations(itemID, parentItemID) SELECT i.itemID, p.itemID FROM items i, items p WHERE i.key = ?1 AND p.key=?2;
ON CONFLICT DO UPDATE SET parentItemID = excluded.parentItemID;
]]

local ZOTERO_GET_ITEM_VERSION = [[ SELECT itemID, version FROM items WHERE key = ?; ]]

local ZOTERO_GET_VERSION = [[ SELECT version FROM attachment_versions WHERE key = ?; ]]
local ZOTERO_SET_VERSION = [[
INSERT INTO attachment_versions(key,version)
       VALUES(?,?)
       ON CONFLICT DO UPDATE SET version = excluded.version;
]];

-- to check whether changes where made
local ZOTERO_DB_CHANGES = [[ SELECT changes() ]]

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
    if API.db ~= nil then
        return API.db
    else
        API.db = SQ3.open(API.db_path)
--        API.db:exec(ZOTERO_CREATE_VIEWS)
		API.db:exec("PRAGMA foreign_keys=ON")
		logger.info("Zotero: db opened with foreign keys enabled: ", tonumber(unpack(API.db:exec("PRAGMA foreign_keys")[1])))
        return API.db
    end

end

-- TODO: call this at appropriate time
function API.closeDB()
    if API.db ~= nil then
        API.db:close()
    end
    API.db = nil
end

function API.init(zotero_dir)
    API.zotero_dir = zotero_dir
    local settings_path = BaseUtil.joinPath(API.zotero_dir, "meta.lua")
    API.settings = LuaSettings:open(settings_path)

    API.storage_dir = BaseUtil.joinPath(API.zotero_dir, "storage")
    if not file_exists(API.storage_dir) then
        lfs.mkdir(API.storage_dir)
    end

    logger.dbg("Zotero: storage dir" .. API.storage_dir)

    API.db_path = BaseUtil.joinPath(API.zotero_dir, "zotero.db")
    logger.info("Zotero: opening db path ", API.db_path)
    local db = API.openDB()
    if API.getLibraryVersion() == 0 then
		logger.info("Zotero: db version is 0. Set up libraries.")
		db:exec(ZOTERO_DB_SCHEMA)
		db:exec(ZOTERO_DB_INIT_LIBS)

		local cnt, _ = db:exec("SELECT COUNT(*) FROM itemTypes")
		if cnt[1][1] == 0 then
			db:exec(ZOTERO_DB_INIT_ITEMTYPES)
		end
		db:exec(ZOTERO_DB_INIT_COLLECTIONS)

	end
    --db:exec(ZOTERO_CREATE_VIEWS)
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

    return version
end

function API.setLibraryVersion(version)
    local v = tonumber(version)
    local db = API.openDB()
    local sql = "PRAGMA user_version = " .. tostring(v) .. ";"
    db:exec(sql)
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

    local b, c, h = https.request {
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
    logger.dbg("Zotero: Determining size of '" .. collection_url .. "'")
    local r, c, h = https.request {
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
-- The second parameter to callback is the percentage of completion
--
-- If an error occurs, the function will return nil and the error message as second parameter.
function API.fetchCollectionPaginated(collection_url, headers, callback)
    -- Try to determine the size
    local collection_size, e = API.fetchCollectionSize(collection_url, headers)
    if e ~= nil then return nil, e end

    logger.dbg(("Zotero: Fetching %s items."):format(collection_size))
    -- The API returns the results in pages with 100 entries each, loop accordingly.
    local items = {}
    local library_version = 0
    local step_size = 100
    for item_nr = 0, collection_size, step_size do
        local page_url = ("%s&limit=%i&start=%i"):format(collection_url, step_size, item_nr)

        local page_data = {}
        local r, c, h = https.request {
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

        local percentage = 100 * item_nr / collection_size
        if collection_size == 0 then
            percentage = 100
        end

        if callback then
            callback(result, percentage)
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

function API.syncAllItems(progress_callback)
    local callback = progress_callback or function() end

    local db = API.openDB()
    local since = API.getLibraryVersion()
	print("Local Zotero lib version: "..since)
	
    local e, api_key, user_id = API.ensureKeyAndID()
    if e ~= nil then return e end
    
	local stmt_update_item = db:prepare(ZOTERO_DB_UPDATE_ITEM)
    local stmt_update_itemData = db:prepare(ZOTERO_DB_UPDATE_ITEMDATA)
	local stmt_update_collectionItems = db:prepare(ZOTERO_DB_UPDATE_COLLECTION_ITEMS)
	local stmt_get_ItemVersion = db:prepare(ZOTERO_GET_ITEM_VERSION)
	local stmt_delete_item = db:prepare(ZOTERO_DB_DELETE_ITEM)
	
    -- to check whether changes where made
	local stmt_changes = db:prepare(ZOTERO_DB_CHANGES)
	
    local headers = API.getHeaders(api_key)
    local items_url = ("https://api.zotero.org/users/%s/items?since=%s&includeTrashed=true"):format(user_id, since)
    local collections_url = ("https://api.zotero.org/users/%s/collections?since=%s&includeTrashed=true"):format(user_id, since)

    -- Sync library collections
	local stmt_update_collection = db:prepare(ZOTERO_DB_UPDATE_COLLECTION)

    local r, e = API.fetchCollectionPaginated(collections_url, headers, function(partial_entries, percentage)
        callback(string.format("Syncing collections %.0f%%", percentage))
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local collection = partial_entries[i].data
            local key = collection.key
			print(collection.name, collection.key, collection.parentCollection,collection.version)
			if collection.parentCollection == false then collection.parentCollection = '/' end
            stmt_update_collection:reset():bind(collection.name, collection.parentCollection, collection.key, collection.version):step()
--            stmt_update_collection:reset():bind(collection.name, collection.key, collection.version):step()
			local cnt = stmt_changes:reset():step()
			if cnt ~= nil then 
				print("Changes: ", tonumber(cnt[1]))
			end

        end
    end)
    stmt_update_collection:close()
    if e ~= nil then return e end
	
	local attachments = {}
	local annotations = {}
	
    -- Sync library items
    r, e = API.fetchCollectionPaginated(items_url, headers, function(partial_entries, percentage)
        callback(string.format("Syncing items %.0f%%", percentage))
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local item = partial_entries[i]
            local key = item.key
            local res = stmt_get_ItemVersion:reset():bind(key):step()
            if res ~= nil then 
            -- we have a local version already; should do something different?
				logger.info("Zotero: update for local item "..key..": itemID ", tonumber(res[1]), ", version ", tonumber(res[2]) ) 
			else
				logger.info("New item: "..key)
			end
            
            if item.data.deleted == 1 then
				print("Item "..key.." has been deleted.")
				if res ~= nil then
					stmt_delete_item:reset():bind(key):step()
					local cnt = stmt_changes:reset():step()
					if cnt ~= nil then 
						logger.info("Changes: ", tonumber(cnt[1]))
					end
				end
			else
				-- remove some unused data
				item.links = nil
				item.library = nil

				stmt_update_item:reset():bind(1, item.data.itemType, key, item.version):step()
				local cnt = stmt_changes:reset():step()
				if cnt ~= nil then 
					print("Changes: ", tonumber(cnt[1]))
				end
				stmt_update_itemData:reset():bind(key, JSON.encode(item)):step()
				if item.data.collections ~= nil then
					local itemCol = item.data.collections[1]
					if itemCol == nil then itemCol = '/' end
					logger.info("Item "..key.." is part of collection "..itemCol)
					stmt_update_collectionItems:reset():bind(itemCol, key):step()
				end
				if item.data.itemType == 'attachment' then
				-- if there is no parent item then use the item as its own parent
					attachments[key] = item.data.parentItem or key
				elseif item.data.itemType == 'annotation' then
					annotations[key] = item.data.parentItem
				end
			end
        end
    end)
    if e ~= nil then return e end

    API.setLibraryVersion(r)
	
	-- deal with attachment items:
	local next = next	
	if next(attachments) ~= nil then
	-- there are attachments
		local stmt_insert_attachments = db:prepare(ZOTERO_INSERT_ITEM_ATTACHMENTS)
		for item, parent in pairs(attachments) do
			stmt_insert_attachments:reset():bind(item, parent):step()
		end
		stmt_insert_attachments:close()
	end
	
	-- deal with annotation items:
	if next(annotations) ~= nil then
	-- there are annotations
		local stmt_insert_annotations = db:prepare(ZOTERO_INSERT_ITEM_ANNOTATIONS)
		for item, parent in pairs(annotations) do
			stmt_insert_annotations:reset():bind(item, parent):step()
		end
		stmt_insert_annotations:close()
	end

	
    --API.batchDownload(callback)
    --API.syncAnnotations()

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

    if nr == 0 then
        return nil
    else
		print(result[1][1])
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
    elseif item.data.linkMode ~= "imported_file" and item.data.linkMode ~= "imported_url" then
        return nil, "Error: this item is not a stored attachment"
    elseif table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType) == false then
        return nil, "Error: this item has an unsupported content type (" .. item.data.contentType .. ")"
    end

    local targetDir, targetPath = API.getDirAndPath(item)
    lfs.mkdir(targetDir)

    local local_version = API.getAttachmentVersion(key)

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
        logger.dbg("Zotero: fetching " .. url)

        local r, c, h = https.request {
            url = url,
            headers = API.getHeaders(api_key),
            sink = ltn12.sink.file(io.open(targetPath, "wb"))
        }

        local e = API.verifyResponse(r, c)
        if e ~= nil then return nil, e end
    end

    API.setAttachmentVersion(key, item.version)

    return targetPath, nil
end


function API.downloadWebDAV(key, targetDir, targetPath)
    if API.getWebDAVUrl() == nil then
        return nil, "WebDAV url not set"
    end
    local url = API.getWebDAVUrl() .. "/" .. key .. ".zip"
    local headers = API.getWebDAVHeaders()
    local zipPath = targetDir .. "/" .. key .. ".zip"
    logger.dbg("Zotero: fetching URL " .. url)
    local r, c, h = https.request {
        method = "GET",
        url = url,
        headers = headers,
        sink = ltn12.sink.file(io.open(zipPath, "wb"))
    }

    if c ~= 200 then
        return nil, "Download failed with status code " .. c
    end

    -- Zotero WebDAV storage packs documents inside a zipfile
    local zip_cmd = "unzip -qq '" .. zipPath .. "' -d '" .. targetDir .. "'"
    logger.dbg("Zotero: unzipping with " .. zip_cmd)
    local zip_result = os.execute(zip_cmd)

    local remove_result, e, ecode = os.remove(zipPath)
    if remove_result == nil then
        logger.err(("Zotero: failed to remove zip file %s, error %s"):format(zipPath, e))
    end

    if zip_result then
        return targetPath
    else
        return nil, "Unzipping failed"
    end
end

function API.getWebDAVHeaders()
    local user = API.getWebDAVUser() or ""
    local pass = API.getWebDAVPassword() or ""

    return {
        ["Authorization"] = "Basic " .. sha2.bin_to_base64(user .. ":" .. pass)
    }
end

-- Download all files that are part of an offline collection
function API.batchDownload(progress_callback)
    local db = API.openDB()

    local item_count = db:exec(ZOTERO_GET_DOWNLOAD_QUEUE_SIZE)[1][1]

    local stmt = db:prepare(ZOTERO_GET_DOWNLOAD_QUEUE)
    stmt:reset()

    local row, nr = stmt:step({}, {})
    local i = 1
    while row ~= nil do
        local download_key = row[1]
        local filename = row[2]
        progress_callback(string.format(_("Downloading attachment %i/%i"), i, item_count))
        local path, e = API.downloadAndGetPath(download_key, nil)

        if e ~= nil then
            progress_callback(string.format(_("Error downloading attachment %s: %s"), filename, e))
        end

        row = stmt:step(row)
        i = i + 1
    end
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

    if key == nil then
		-- use fake key for root collection
		key = '/'
        --print("Key is nil")
    end
	stmt:bind1(1, key)

    local result = {}
    local row, _ = stmt:step({}, {})
    while row ~= nil do
        table.insert(result, {
            ["key"] = row[1],
            ["text"] = row[2],
            ["type"] = row[3],
        })
		--print(row[1], row[2], row[3])
        row = stmt:step(row)
    end
    stmt:close()
	
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

        row = stmt:step(row)
    end
    stmt:close()

    return result
end


function API.resetSyncState()
    local db = API.openDB()
    db:exec(ZOTERO_DB_DELETE)
end


function API.isOfflineCollection(key)
    local db = API.openDB()

    local stmt = db:prepare(ZOTERO_GET_OFFLINE_COLLECTION):reset():bind1(1, key)

    local _, nr = stmt:resultset()


    return (nr > 0)
end

function API.addOfflineCollection(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_ADD_OFFLINE_COLLECTION)
    stmt:reset():bind1(1, key):step()

end

function API.removeOfflineCollection(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_REMOVE_OFFLINE_COLLECTION)
    stmt:reset():bind1(1, key):step()
end

function API.getAttachmentVersion(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_GET_VERSION)
    local result, nr = stmt:reset():bind(key):resultset()

    stmt:close()

    if nr == 0 then
        return nil
    else
        return result[1][1]
    end

end

function API.setAttachmentVersion(key, version)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_SET_VERSION)
    stmt:reset():bind(key, version):step()
    stmt:close()
end

function API.syncAnnotations(progress_callback)
    local db = API.openDB()
    local item_count = db:exec(ZOTERO_GET_LOCAL_PDF_ITEMS_SIZE)[1][1]


    local stmt = db:prepare(ZOTERO_GET_LOCAL_PDF_ITEMS)

    stmt:reset()
    stmt:clearbind()

    local row, _ = stmt:step({}, {})
    local i = 1
    while row ~= nil do
        local key = row[1]
        local filename = row[2]

        local file_path = API.storage_dir .. "/" .. key .. "/" .. filename
        Annotations.createAnnotations(file_path, key, API.createItems)
        row = stmt:step(row)

        if progress_callback ~= nil and (i == 1 or i % 10 == 0 or i == item_count) then
            progress_callback(string.format(_("Syncing annotations of file %i/%i"), i, item_count))
        end

        i = i + 1
    end
    stmt:close()
end

-- Create a whole range of items.
-- Returns an array with a status code per item
function API.createItems(items)
    -- up to 50 items can be created with one request, see https://www.zotero.org/support/dev/web_api/v3/write_requests#creating_multiple_objects for details
    local API_MAX_ITEMS_PER_REQUEST = 50
    local total_items = #items
    local total_requests = math.ceil(total_items / API_MAX_ITEMS_PER_REQUEST)

    local created_items = {}
    for i=1,total_items do
        table.insert(created_items, nil)
    end

    local e, api_key, user_id = API.ensureKeyAndID()
    if e ~= nil then
        return created_items, e
    end
    local headers = API.getHeaders(api_key)
    local create_url = ("https://api.zotero.org/users/%s/items"):format(user_id)


    for request_no=1,total_requests do
        local request_items = {}
        local start_item = (request_no - 1) * API_MAX_ITEMS_PER_REQUEST
        local end_item = math.min(start_item + API_MAX_ITEMS_PER_REQUEST, total_items)
        for i=start_item,end_item do
            table.insert(request_items, items[i])
        end

        local request_json = JSON.encode(request_items)
        headers["if-unmodified-since"] = API.getLibraryVersion()
        local response = {}
        logger.dbg(("Zotero: POST request to %s, body:\n%s"):format(create_url, request_json))
        local r,c, response_headers = https.request {
            method = "POST",
            url = create_url,
            headers = headers,
            sink = ltn12.sink.table(response),
            source = ltn12.source.string(request_json)
        }
        e = API.verifyResponse(r, c)
        if e ~= nil then return created_items, e end

        local content = table.concat(response, "")
        local ok, result = pcall(JSON.decode, content)
        if not ok then
            return created_items, "Error: failed to parse JSON in response to annotation creation request"
        end

        local new_library_version = response_headers["last-modified-version"]
        if new_library_version ~= nil then
            API.setLibraryVersion(new_library_version)
        else
            logger.err("Z: could not update library version from create request, got " .. tostring(new_library_version))
        end

        for k,v in pairs(result["successful"]) do
            local index = start_item + tonumber(k) + 1
            created_items[index] = v
        end

        for k,v in pairs(result["unchanged"]) do
            local index = start_item + tonumber(k) + 1
            local zotero_key = v
            created_items[index] = {
                ["key"] = zotero_key
            }
        end
    end

    return created_items, nil
end


return API
