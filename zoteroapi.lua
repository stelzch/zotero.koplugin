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
-- For my annotation routines:
local DocSettings = require("docsettings")
local Geom = require("ui/geometry")


-- Functions expect config parameter, a lua table with the following keys:
-- zotero_dir: Path to a directory where cache files will be stored
-- api_key: self-explanatory
--
-- Directory layout of zoteroapi
-- /zotero.db: SQLite3 database that contains JSON items & collections
-- /storage/<KEY>/filename.pdf: Actual PDF files
-- /storage/<KEY>/version: Version number of downloaded attachment
-- /meta.lua: Metadata containing library version, items etc.

local API = { ["version"] = "JA sqlite v0.9"}

local SUPPORTED_MEDIA_TYPES = {
    [1] = "application/pdf",
    [2] = "application/epub+zip",
    [3] = "text/html"
}

local ZOTERO_BASE_URL = "https://api.zotero.org"

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
	lastSync INT NOT NULL DEFAULT 0,
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


--local ZOTERO_CREATE_VIEWS = [[ 
--CREATE TEMPORARY TABLE IF NOT EXISTS supported_media_types (mime TEXT);
--INSERT INTO supported_media_types(mime) VALUES ('application/pdf'), ('application/epub+zip'), ('text/html') ON CONFLICT DO NOTHING;

--CREATE TEMPORARY TABLE IF NOT EXISTS supported_link_types (type TEXT);
--INSERT INTO supported_link_types(type) VALUES ('imported_file'), ('imported_url') ON CONFLICT DO NOTHING;

---- create view that holds metadata of the parent item. if it does not exist, it is equal to the item itself
--CREATE TEMPORARY VIEW IF NOT EXISTS attachment_data AS
--SELECT items.key AS key, items.value AS value, parents.key AS parent_key, coalesce(parents.value, items.value) AS parent_value
--FROM items
--LEFT JOIN items AS parents ON jsonb_extract(items.value, '$.data.parentItem') = parents.key
--WHERE
--(jsonb_extract(items.value, '$.data.itemType')  = 'attachment');


--CREATE TEMPORARY VIEW IF NOT EXISTS item_download_queue AS
---- A collection is a offline collection if it is in the respective table or any of its parent collections are 
---- in the respective table
--WITH RECURSIVE collection_hierarchy(key) AS
 --(SELECT key FROM offline_collections -- starting values are all collections inside the offline_collections table
  --UNION
  --SELECT collections.key              -- select all other keys of collections
  --FROM collections, collection_hierarchy 
  --WHERE jsonb_extract(collections.value, '$.data.parentCollection') = collection_hierarchy.key) -- whose parentCollection is the collection we just inserted
--SELECT attachment_data.key FROM attachment_data
--LEFT JOIN attachment_versions ON attachment_data.key = attachment_versions.key
--WHERE
---- must be an attachment with supported media type
--(jsonb_extract(value, '$.data.itemType') = 'attachment') AND
--(jsonb_extract(value, '$.data.linkMode') IN (SELECT type FROM supported_link_types)) AND
--(jsonb_extract(value, '$.data.contentType') IN (SELECT mime FROM supported_media_types)) AND
---- the item may not be deleted
--(jsonb_extract(value, '$.data.deleted') IS NOT 1)
---- and must belong to a collection in the offline collection hierarchy
--AND EXISTS (SELECT collection_hierarchy.key FROM collection_hierarchy INTERSECT SELECT value FROM json_each(jsonb_extract(attachment_data.parent_value, '$.data.collections')))
---- and local version must be lower than remote version (otherwise its considered up-to-date)
--AND coalesce((SELECT version FROM attachment_versions WHERE attachment_versions.key = attachment_data.key), 0) < jsonb_extract(attachment_data.value, '$.version');
--[[
-- select all pdf attachments present locally
local ZOTERO_CREATE_VIEWS = [[ 
CREATE TEMPORARY TABLE IF NOT EXISTS supported_link_types (type TEXT);
INSERT INTO supported_link_types(type) VALUES ('imported_file'), ('imported_url') ON CONFLICT DO NOTHING;

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

-- Make sure there is at least one item in libraries table: ony insert if table is empty:
local ZOTERO_DB_INIT_LIBS = [[
INSERT INTO libraries(type, editable, name) SELECT 'user',1,'' WHERE NOT EXISTS(SELECT libraryID FROM libraries);
]]

local ZOTERO_DB_INIT_COLLECTIONS = [[
-- only insert item if table is empty:
-- 'Fake collection' for items in root
INSERT INTO collections(collectionName, libraryID, key) SELECT '',1,'/' WHERE NOT EXISTS(SELECT collectionID FROM collections);
]]

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
local ZOTERO_DB_UPDATE_PARENTCOLLECTION = [[
-- assume libraryID = 1 for now
UPDATE collections SET parentCollectionID = (SELECT collectionID FROM collections WHERE key = ?2) WHERE key=?1;
]]
local ZOTERO_DB_UPDATE_COLLECTION_ITEMS = [[
INSERT INTO collectionItems(collectionID, itemID) SELECT collections.collectionID, items.itemID FROM collections, items WHERE collections.key = ?1 AND items.key=?2
ON CONFLICT DO NOTHING;
]]
local ZOTERO_GET_COLLECTION_VERSION = [[ SELECT version, collectionID FROM collections WHERE key = ?; ]]

local ZOTERO_GET_DB_VERSION = [[ PRAGMA user_version; ]]

local ZOTERO_GET_ITEM = [[ SELECT json(value) 	FROM 
		itemData INNER JOIN items ON itemData.itemID = items.itemID WHERE items.key = ?; ]]

local ZOTERO_GET_OFFLINE_COLLECTION = [[ 
SELECT key FROM collections WHERE (synced > 0) AND (key = ?);
]]

local ZOTERO_ADD_OFFLINE_COLLECTION = [[ 
UPDATE collections
SET synced = 1
WHERE key=?;
]]

local ZOTERO_REMOVE_OFFLINE_COLLECTION = [[ 
UPDATE collections
SET synced = 0
WHERE key=?;
]]

local ZOTERO_QUERY_ITEMS = [[
WITH cid AS (SELECT collectionID AS ID FROM collections WHERE key = ?1) 
SELECT 
	key, 
	colname, 
	'collection' 
FROM (
	SELECT 
		key, 
		collectionName || '/' AS colname
	FROM collections, cid 
	WHERE parentCollectionID = cid.ID
	ORDER By colname)
UNION ALL
SELECT 
	key, 
	name, 
	type 
FROM (
	SELECT
	   items.key,
--		jsonb_extract(value, '$.data.title') AS title,
		---- if possible, prepend creator summary
		coalesce(jsonb_extract(value, '$.meta.creatorSummary') || ' - ', '') || jsonb_extract(value, '$.data.title') AS name,
		iif(items.itemTypeID = 3, 'attachment', 'item') AS type
	FROM 
		itemData INNER JOIN items ON itemData.itemID = items.itemID, cid
	WHERE
		itemData.itemID IN (
			SELECT itemID FROM collectionItems,cid WHERE collectionID = cid.ID
		)
	ORDER BY name
);
]]

local ZOTERO_GET_COLLECTION_ITEMS = [[
WITH cid AS (SELECT collectionID AS ID FROM collections WHERE key = ?1) 
SELECT
   items.key,
	---- if possible, prepend creator summary
	coalesce(jsonb_extract(value, '$.meta.creatorSummary') || ' - ', '') || jsonb_extract(value, '$.data.title') AS title,
	iif(items.itemTypeID = 3, 'attachment', 'item') AS type
FROM 
	itemData INNER JOIN items ON itemData.itemID = items.itemID, cid
WHERE
	itemData.itemID IN (
		SELECT itemID FROM collectionItems,cid WHERE collectionID = cid.ID
	)
;
--ORDER BY title);
]]

local ZOTERO_GET_COLLECTION_FOR_ITEM = [[
SELECT 
	collectionID
FROM 
	collectionItems INNER JOIN items USING (itemID)
WHERE
	key = ?
;
]]


local ZOTERO_GET_OFFLINE_COLLECTION_ATTACHMENTS = [[
SELECT
   items.key,
	---- if possible, prepend creator summary
	coalesce(jsonb_extract(value, '$.meta.creatorSummary') || ' - ', '') || jsonb_extract(value, '$.data.title') AS title,
	iif(items.itemTypeID = 3, 'attachment', 'item') AS type
FROM 
	itemData INNER JOIN items ON itemData.itemID = items.itemID
WHERE
	itemData.itemID IN (
		SELECT ItemID 
		FROM itemAttachments 
		WHERE
			parentItemID IN (
				SELECT itemID 
				FROM collectionItems INNER JOIN collections ON collections.collectionID = collectionItems.collectionID 
				WHERE synced = 1)  
	);
]]

local ZOTERO_SEARCH_ITEMS = [[
SELECT
    key,
    -- if possible, prepend creator summary
    coalesce(jsonb_extract(value, '$.meta.creatorSummary') || ' - ', '') || jsonb_extract(value, '$.data.title') AS title,
	iif(itemTypeID = 3, 'attachment', 'item') AS type
FROM itemData INNER JOIN items ON itemData.itemID = items.itemID 
WHERE
	itemData.itemID IN (SELECT parentItemID FROM itemAttachments)
AND title LIKE ?1
ORDER BY title;
]]

local ZOTERO_GET_ITEM_ATTACHMENTS = [[
SELECT
	key,
	jsonb_extract(value, '$.data.filename') AS filename,
	(jsonb_extract(value, '$.data.contentType') = 'application/pdf') AS is_pdf
FROM (itemAttachments INNER JOIN itemData ON itemData.itemID = itemAttachments.itemID) INNER JOIN items ON itemData.itemID = items.itemID 
WHERE
	itemAttachments.parentItemID IN (SELECT itemID FROM items WHERE key = ?1);
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

local ZOTERO_UPSERT_ITEM_ATTACHMENTS = [[
INSERT INTO itemAttachments(itemID, parentItemID) SELECT i.itemID, p.itemID AS pID FROM items i, items p WHERE i.key = ?1 AND p.key=?2
ON CONFLICT DO UPDATE SET parentItemID = excluded.parentItemID;
]]

local ZOTERO_DELETE_ITEM_ATTACHMENT = [[
DELETE FROM itemAttachments WHERE itemID IN (SELECT itemID FROM items WHERE key IS ?);
]]

local ZOTERO_UPSERT_ITEM_ANNOTATIONS = [[
INSERT INTO itemAnnotations(itemID, parentItemID) SELECT i.itemID, p.itemID FROM items i, items p WHERE i.key = ?1 AND p.key=?2
ON CONFLICT DO UPDATE SET parentItemID = excluded.parentItemID;
]]

local ZOTERO_GET_ITEM_VERSION = [[ SELECT version, itemID FROM items WHERE key = ?; ]]

-- Return synced version according to database for item identified by its key. Also return lastest version and itemID 
local ZOTERO_GET_ATTACHMENT_VERSION = [[ 
SELECT syncedVersion, lastSync, version, items.itemID
FROM itemAttachments INNER JOIN items ON itemAttachments.itemID = items.itemID 
WHERE key = ?;
]]

-- set synced version using the itemID (not key!) as the 1st parameter, and version number as the 2nd
local ZOTERO_SET_ATTACHMENT_SYNCEDVERSION = [[ 
UPDATE itemAttachments SET syncedVersion = ?2, lastSync = unixepoch('now') WHERE itemID = ?1;
]]

-- set synced version using not key as the 1st parameter, and version number as the 2nd
local ZOTERO_SET_ATTACHMENT_SYNCEDVERSION_KEY = [[ 
UPDATE itemAttachments SET syncedVersion = ?2 WHERE itemID IN (SELECT itemID FROM items WHERE key = ?1);
]]

-- set lastSync to now for attachment with key specified by parameter 
local ZOTERO_SET_ATTACHMENT_LASTSYNC = [[ 
UPDATE itemAttachments SET lastSync = unixepoch('now') WHERE itemID IN (SELECT itemID FROM items WHERE key = ?);
]]

-- Return key, filename and lastSync for all locally synced attachments. 
local ZOTERO_GET_LOCAL_ATTACHMENT = [[ 
SELECT
	key,
	jsonb_extract(value, '$.data.filename'),
	lastSync
FROM (itemAttachments INNER JOIN itemData ON itemData.itemID = itemAttachments.itemID) INNER JOIN items ON itemData.itemID = items.itemID 
WHERE itemAttachments.syncedVersion > 0;
]]

local ZOTERO_GET_VERSION = [[ SELECT version FROM attachment_versions WHERE key = ?; ]]
local ZOTERO_SET_VERSION = [[
INSERT INTO attachment_versions(key,version)
       VALUES(?,?)
       ON CONFLICT DO UPDATE SET version = excluded.version;
]];

-- to check whether changes where made
local ZOTERO_DB_CHANGES = [[ SELECT changes() ]]

-- Return some basic stats about database
local ZOTERO_DB_STATS = [[
SELECT
	colls,
	allItems,
	attachments,
	annotations
FROM
	(
	SELECT
		COUNT(collectionID) AS colls
	FROM
		collections
	),(
	SELECT
		COUNT(itemID) AS allItems
	FROM
		items
	),(
	SELECT
		COUNT(itemID) AS attachments
	FROM
		itemAttachments
	),(
	SELECT
		COUNT(itemID) AS annotations
	FROM
		itemAnnotations
	)
	);
]]

local function file_exists(path)
    if path == nil then return nil end
    local info = lfs.attributes(path)
    --print(JSON.encode(info))
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

-- Open the sqlite database. When opening it for the first time also get the current database version.
-- If sqlite library is empty make sure the required tables are set up
function API.openDB()
    if API.db ~= nil then
        return API.db
    else
        API.db = SQ3.open(API.db_path)
		--API.db:exec(ZOTERO_CREATE_VIEWS)
		API.db:exec("PRAGMA foreign_keys=ON")
		--logger.info("Zotero: db opened with foreign keys enabled: ", tonumber(unpack(API.db:exec("PRAGMA foreign_keys")[1])))
		if API.getLibraryVersion() == 0 then
			logger.info("Zotero: db version is 0. Set up tables.")
			API.db:exec(ZOTERO_DB_SCHEMA)
			logger.info("Zotero: Set up user library.")
			API.db:rowexec(ZOTERO_DB_INIT_LIBS)
			local cnt = API.db:rowexec(ZOTERO_DB_CHANGES)
			if cnt ~= nil then 
				logger.info("Zotero: Changes in libraries table: ", tonumber(cnt))
			end
			local cnt = API.db:rowexec("SELECT COUNT(*) FROM itemTypes")
			if cnt == 0 then
				logger.info("Zotero: Set up user itemTypes.")
				API.db:exec(ZOTERO_DB_INIT_ITEMTYPES)
				local cnt = API.db:rowexec(ZOTERO_DB_CHANGES)
				if cnt ~= nil then 
					logger.info("Zotero: Changes in itemTypes table: ", tonumber(cnt))
				end
			end
			logger.info("Zotero: Set up root collection.")
			API.db:exec(ZOTERO_DB_INIT_COLLECTIONS)
		else
			logger.info("Zotero: Local db version: "..API.libVersion)
		end
        return API.db
    end

end

-- TODO: call this at appropriate time
function API.closeDB()
    if API.db ~= nil then
        API.db:close()
    end
    API.db = nil
    API.libVersion = nil
end

-- Initialise plugin by setting correct path and opening the sqlite database
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
    local stats = {}

    -- get file modification time (to provide some indication of 'version')
    local path = debug.getinfo(1, "S").source:sub(2)
	local ts = lfs.attributes(path, "modification")
	API.version = API.version.." ("..os.date("%Y-%m-%d %X",ts)..")" 
	logger.info("Zotero version: "..API.version)

	--API.checkItemData()
end

function API.getStats()
    local db = API.openDB()

	--local c, i, a, n = db:rowexec(ZOTERO_DB_STATS)
	local c = tonumber(db:rowexec("SELECT COUNT(*) FROM collections;"))
	local i = tonumber(db:rowexec("SELECT COUNT(*) FROM items;"))
	local a = tonumber(db:rowexec("SELECT COUNT(*) FROM itemAttachments;"))
	local n = tonumber(db:rowexec("SELECT COUNT(*) FROM itemAnnotations;"))
	local stats = { ["libVersion"] = API.getLibraryVersion(), ["collections"] = c, ["items"] = i, ["attachments"] = a, ["annotations"] = n }
	logger.info(JSON.encode(stats))
	
    return stats
end


function API.getAPIKey()
    return API.settings:readSetting("api_key")
end
function API.setAPIKey(api_key)
    API.settings:saveSetting("api_key", api_key)
    API.zoteroAcessVerified = false
end

function API.getUserID()
    return API.settings:readSetting("user_id")
end

function API.setUserID(user_id)
    API.settings:saveSetting("user_id", user_id)
    API.zoteroAcessVerified = false
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
    if API.libVersion == nil then
		local db = API.openDB()
		local result, ncol = db:exec(ZOTERO_GET_DB_VERSION)
		assert(ncol == 1)
		local version = tonumber(result[1][1])
		API.libVersion = version
	end
    return API.libVersion
end

function API.setLibraryVersion(version)
    API.libVersion = tonumber(version)
    local db = API.openDB()
    local sql = "PRAGMA user_version = " .. tostring(API.libVersion) .. ";"
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

-- https get call which decodes JSON data 
function API.getZoteroData(page_url)

	local headers = API.zoteroHeader
	if headers == nil then
		return nil, "Error: Zotero header not set. Check user ID and API key"
	end
	local page_data = {}
	local r, c, h = https.request {
		method = "GET",
		url = page_url,
		headers = headers,
		sink = ltn12.sink.table(page_data)
	}
	local e = API.verifyResponse(r, c)
	if e ~= nil then 
		return nil, e 
	end
	-- convert table page_data into a string:
	local content = table.concat(page_data, "")
	local ok, result = pcall(JSON.decode, content)
	if ok then
		return result, h
	else	
		return nil, "Error: failed to parse JSON in response"		
	end    
end

-- Check the access provided by the Zotero API key
-- If needed, update info about library
function API.checkZoteroKey(page_url, headers)

	if API.access == nil then
		local result, e = API.getZoteroData(page_url)
		if result ~= nil then 
			logger.dbg("Zotero: Access: "..JSON.encode(result.access))
			--logger.info(header)
			local db = API.openDB()
			local sql = "SELECT userID FROM libraries WHERE libraryID=1;"
			local uID = db:rowexec(sql)
			if uID == 0 then
				-- userID has not been set yet. Should only happed for first ever sync...
				sql = ('UPDATE libraries SET userID=%i, name="%s", editable=%i WHERE libraryID=1;'):format(result.userID, result.username, 0)
				db:rowexec(sql)
			else
			-- should check that it is still the same user library and that we have sufficient access...
			end
			API.access = result.access
		else
			return nil, "Zotero API key check: "..e
		end
	end
	return API.access
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

    logger.info(("Zotero: Fetching %s items."):format(collection_size))
    -- The API returns the results in pages with 100 entries each, loop accordingly.
    local items = {}
    local library_version = 0
    local step_size = 100
    for item_nr = 0, collection_size, step_size do
        local page_url = ("%s&limit=%i&start=%i"):format(collection_url, step_size, item_nr)

		local result, header = API.getZoteroData(page_url)
		if result == nil then return nil, header end
		library_version = header["last-modified-version"]
		
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

-- Verify that we can access Zotero API
function API.verifyZoteroAccess()
	if API.zoteroAcessVerified then
		-- nothing to do here
	else
		local user_id = API.settings:readSetting("user_id", "")
		local api_key = API.settings:readSetting("api_key", "")

		if user_id == "" then
			return "Error: must set User ID"
		elseif api_key == "" then
			return "Error: must set API Key"
		end
		API.zoteroAcessVerified = true
		-- generate the headers we will need
		API.zoteroHeader = {
			["zotero-api-key"] = api_key,
			["zotero-api-version"] = "3"
		}
		-- generate the user library base URL
		API.userLibraryURL = ZOTERO_BASE_URL..("/users/%s"):format(user_id)
		-- check access of API key
		local key_url = API.userLibraryURL.."/keys/current"
		local access, e = API.checkZoteroKey(key_url, headers)
		if access == nil then
			return e
		end
	end
    return nil
end

function API.getHeaders(api_key)
    return {
        ["zotero-api-key"] = api_key,
        ["zotero-api-version"] = "3"
    }
end

-- Add/update attachments to itemAttachments db table
-- Input is a table of containing itemkey and parentkey pairs
function API.setItemAttachments(attachments)
    local db = API.openDB()
	local stmt_upsert_attachments = db:prepare(ZOTERO_UPSERT_ITEM_ATTACHMENTS)
	local stmt_check_collection = db:prepare(ZOTERO_GET_COLLECTION_FOR_ITEM)
	local stmt_delete = db:prepare(ZOTERO_DELETE_ITEM_ATTACHMENT)
	for item, parent in pairs(attachments) do
		if stmt_check_collection:reset():bind1(1, parent):step() then
			stmt_upsert_attachments:reset():bind(item, parent):step()
		else  -- parentItem is not part of a collection
			print("Deleting attachment "..item.." from itemsAttachment table")
			stmt_delete:reset():bind1(1, item):step()
		end
	end
	stmt_upsert_attachments:close()
end

-- Add/update annotations to itemAnnotations db table
-- Input is a table of containing item.key and parent.key pairs
function API.setAnnotations(annotations)
    local db = API.openDB()
	local stmt_upsert_annotations = db:prepare(ZOTERO_UPSERT_ITEM_ANNOTATIONS)
	for item, parent in pairs(annotations) do
		stmt_upsert_annotations:reset():bind(item, parent):step()
	end
	stmt_upsert_annotations:close()
end


-- Fetch (new) items from Zotero server and organise them into the local sqlite database
function API.fetchZoteroItems(since, progress_callback)
    
    local callback = progress_callback or function() end

    local db = API.openDB()
    if since == nil then  since = API.getLibraryVersion() end
	-- verify access
    local e = API.verifyZoteroAccess()
    if e ~= nil then return e end
    
	local stmt_update_item = db:prepare(ZOTERO_DB_UPDATE_ITEM)
    local stmt_update_itemData = db:prepare(ZOTERO_DB_UPDATE_ITEMDATA)
	local stmt_get_ItemVersion = db:prepare(ZOTERO_GET_ITEM_VERSION)
	local stmt_delete_item = db:prepare(ZOTERO_DB_DELETE_ITEM)
	local stmt_update_collectionItems = db:prepare(ZOTERO_DB_UPDATE_COLLECTION_ITEMS)
	
    local headers = API.zoteroHeader
    
    local items_url = API.userLibraryURL..("/items?since=%s&includeTrashed=true"):format(since)
 
	local attachments = {}
	local annotations = {}
	
	local annotationTypes = Annotations.supportedZoteroTypes()
	
    local r, e = API.fetchCollectionPaginated(items_url, headers, function(partial_entries, percentage)
        callback(string.format("Syncing items %.0f%%", percentage))
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local item = partial_entries[i]
            local key = item.key
            
            if item.data.deleted then
				logger.info("Item "..key.." has been deleted.")
				-- check if we have this item in the local database; if so, delete it:
				local res = stmt_get_ItemVersion:reset():bind(key):step()
				if res ~= nil then 
					stmt_delete_item:reset():bind(key):step()
				end
			else  -- not a deleted item, so we might want to add it to the local database

				-- remove some unused data
				item.links = nil
				item.library = nil

				stmt_update_item:reset():bind(1, item.data.itemType, key, item.version):step()
				stmt_update_itemData:reset():bind(key, JSON.encode(item)):step()
				
				-- Set the correct collection for the new item:
				if item.data.collections ~= nil then
					local itemCol = item.data.collections[1]
					if itemCol == nil then itemCol = '/' end
					--logger.info("Item "..key.." is part of collection "..itemCol)
					stmt_update_collectionItems:reset():bind(itemCol, key):step()
				end
				
				-- Check if it is a (supported) attachment or annotation
				-- If so, add it to the relevant table
				if (item.data.itemType == 'attachment' 
					and table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType)) then
						attachments[key] = item.data.parentItem or key -- if there is no parent item then use the item as its own parent
				elseif (item.data.itemType == 'annotation' 
						and table_contains(annotationTypes, item.data.annotationType)) then
					annotations[key] = item.data.parentItem
				end
			end
        end
    end)

	-- next is used to check whether table has entries. 
	-- Apparently defining it as a local var makes this more efficient.
	local next = next	
	-- deal with attachment items:
	if next(attachments) ~= nil then
		API.setItemAttachments(attachments)
	end
	
	-- deal with annotation items:
	if next(annotations) ~= nil then
		API.setAnnotations(annotations)
	end
	
	if e ~= nil then return e end
end

-- Fetch (new) collections from Zotero server and organise them into the local sqlite database
function API.fetchZoteroCollections(since, progress_callback)

    local callback = progress_callback or function() end

    local db = API.openDB()
    if since == nil then  since = API.getLibraryVersion() end
	-- verify access
    local e = API.verifyZoteroAccess()
    if e ~= nil then return e end

    -- to check whether changes where made
	local stmt_changes = db:prepare(ZOTERO_DB_CHANGES)
	
    local headers = API.zoteroHeader
    
    local collections_url = API.userLibraryURL..("/collections?since=%s&includeTrashed=true"):format(since)

	-- next is used to check whether table has entries. Apparently defining it as a local var makes this more efficient.
	local next = next	
    
    -- Prepare sql commands
	local stmt_update_collection = db:prepare(ZOTERO_DB_UPDATE_COLLECTION)
	local stmt_delete_collection = db:prepare(ZOTERO_DB_DELETE_COLLECTION)
	local stmt_get_collectionVersion = db:prepare(ZOTERO_GET_COLLECTION_VERSION)

	local nestedCollections = {}
	local nCnt = 0

    local r, e = API.fetchCollectionPaginated(collections_url, headers, function(partial_entries, percentage)
        callback(string.format("Syncing collections %.0f%%", percentage))
        for i = 1, #partial_entries do
            -- Ruthlessly update our local items
            local collection = partial_entries[i].data
            local key = collection.key
			--logger.info(JSON.encode(collection))
            -- for collections Zotero seems to use collection.deleted = true
			if collection.deleted then
				logger.info("Collection "..key.." has been deleted.")
				local localVersion = stmt_get_collectionVersion:reset():bind(key):step()
				if localVersion ~= nil then
					stmt_delete_collection:reset():bind(key):step()
					local cnt = stmt_changes:reset():step()
					if cnt ~= nil then 
						logger.info("Changes: ", tonumber(cnt[1]))
					end
				end
			else
				-- collection has not been deleted
				if collection.parentCollection == false then 
					collection.parentCollection = '/' 
				else 
					-- For nested collections sometimes the parent collection is not in the database yet.
					-- In this case insert would fail. So set parentCollection to root to start with and
					-- set the proper value once all the collections are in the db
					nestedCollections[key] = collection.parentCollection
					collection.parentCollection = '/'
					nCnt = nCnt + 1
				end
				stmt_update_collection:reset():bind(collection.name, collection.parentCollection, collection.key, collection.version):step()
				local cnt = stmt_changes:reset():step()
				if cnt ~= nil then 
					logger.info("Collection changes: ", tonumber(cnt[1]))
				end
			end
        end
    end)
    stmt_update_collection:close()
	
	-- deal with nested collections. 
	-- Now that the db for sure has entries for all collections we can safely set parent collections
	if nCnt > 0 then
	-- there are nestedCollections
		local stmt_update_parentCollection = db:prepare(ZOTERO_DB_UPDATE_PARENTCOLLECTION)
		for item, parent in pairs(nestedCollections) do
			stmt_update_parentCollection:reset():bind(item, parent):step()
		end
		stmt_update_parentCollection:close()
	end
	return r, e
end

-- Sync local db with zotero server
-- This includes:
-- 1. uploading local annotations
-- 2. downloading collections and organising them into local database structure
-- 3. same for items
-- 4. downloading attachments for marked collections
function API.syncAllItems(progress_callback)
    local callback = progress_callback or function() end

    local db = API.openDB()
    local since = API.getLibraryVersion()
	--logger.info("Local Zotero lib version: "..since)
	
	-- verify access
    local e = API.verifyZoteroAccess()
    if e ~= nil then return e end
    
    local err
    if since > 0 then 
    -- try to sync back first, so that any changes will be recorded when we update the db later on
		if (API.access.user.write and API.access.user.notes) then
			API.syncAnnotations()
		else
			err = "Zotero: API key does not have write access!"
			logger.warn(err)
		end
	end
	
	local r, e = API.fetchZoteroCollections(since, progress_callback)
    if e ~= nil then return e end
		
	e = API.fetchZoteroItems(since, callback)
    if e ~= nil then return e end
	
    API.setLibraryVersion(r)
	
    API.batchDownload(callback)

	API.getStats()
	-- err might show error for annotation upload which we have ignored so far..
    return err
end

---------------------
-- Check (local) library items
function API.checkItemData()
    
    local db = API.openDB()

    local stmt = db:prepare([[SELECT json(value) FROM 
    		itemData INNER JOIN items ON itemData.itemID = items.itemID]])

	local stmt_update_collectionItems = db:prepare(ZOTERO_DB_UPDATE_COLLECTION_ITEMS)
	
    -- to check whether changes where made
	local stmt_changes = db:prepare(ZOTERO_DB_CHANGES)
	
	local attachments = {}
	local annotations = {}
	
	local annotationTypes = Annotations.supportedZoteroTypes()

	db:exec("DELETE FROM collectionItems;")
	db:exec("DELETE FROM itemAnnotations;")
	db:exec("DELETE FROM itemAttachments;")
    local row = stmt:reset():step()
    local item
    while row ~= nil do
		item = JSON.decode(row[1])
		
		-- Set the correct collection for the new item:
		if item.data.collections ~= nil then
			--print("Item in collections: "..unpack(item.data.collections))
			local itemCol = item.data.collections[1]
			if itemCol == nil then itemCol = '/' end
			--logger.info("Item "..item.key.." is part of collection "..itemCol)
			-- This works, but maybe better check if collection exists first? Then could delete item if collection no longer there...
			stmt_update_collectionItems:reset():bind(itemCol, item.key):step()
		end

		-- Check if it is a (supported) attachment or annotation
		-- If so, add it to the relevant table
		if (item.data.itemType == 'attachment' 
			and table_contains(SUPPORTED_MEDIA_TYPES, item.data.contentType)) then
				attachments[item.key] = item.data.parentItem or item.key -- if there is no parent item then use the item as its own parent
		elseif (item.data.itemType == 'annotation' 
				and table_contains(annotationTypes, item.data.annotationType)) then
			annotations[item.key] = item.data.parentItem
		end

        row = stmt:step(row)
    end
    stmt:close()
	API.setItemAttachments(attachments)
	API.setAnnotations(annotations)
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
		--print(result[1][1])
        return JSON.decode(result[1][1])
    end
end

function API.getItemAttachments(key)
    local db = API.openDB()
    local stmt = db:prepare(ZOTERO_GET_ITEM_ATTACHMENTS)
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

    local e = API.verifyZoteroAccess()
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

    local downloadRequired = true
    
    local targetDir, targetPath = API.getDirAndPath(item)
	local file_ts = lfs.attributes(targetPath, "modification")
	if file_ts then  -- file already exists locally
		-- get local file version from doc settings file
		local docSettings = DocSettings:open(targetPath)    
		local libVersionAtLastSync  = docSettings:readSetting("zoteroLibVersion", 0)
		docSettings:close()
		-- check what the database expected to find (can be out-of date for many reasons...)
		local local_version, lastSync, itemVersion, itemID = API.getAttachmentVersion(key)
		logger.info("Zotero: ItemID:", itemID,", local item:",local_version, "(synced at", lastSync, ", lib version", libVersionAtLastSync,"), item version:", itemVersion)
		if libVersionAtLastSync >= item.version then
			logger.dbg("Up-to-date local file. No need for download.")
			downloadRequired = false
		end	
	else -- file does not exist, so make sure the folder is there...
	    lfs.mkdir(targetDir)
	end
	
	if downloadRequired then 
		if download_callback ~= nil then download_callback() end

		local errormsg
		logger.info("Zotero: Downloading attachment file")
		if API.settings:isTrue("webdav_enabled") then
			local result
			result, errormsg = API.downloadWebDAV(key, targetDir, targetPath)
		else
			local url = API.userLibraryURL .. "/items/" .. key .. "/file"
			logger.dbg("Zotero: fetching " .. url)

			local r, c, h = https.request {
				url = url,
				headers = API.zoteroHeader,
				sink = ltn12.sink.file(io.open(targetPath, "wb"))
			}

			errormsg = API.verifyResponse(r, c)
		end
		if errormsg then
			if file_ts then
				logger.warn("Failed to download updated attachtment version. Using local copy!")
			else
				logger.warn("Failed to download attachtment")
				return nil, errormsg
			end
		end
	end
	
	-- Check whether there are any annotations that need to be attached and save library version to sdr file 
	API.attachItemAnnotations(item)

    -- Update local db with synced item version number
    API.setAttachmentVersionByKey(key, item.version)

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
    local stmt = db:prepare(ZOTERO_GET_OFFLINE_COLLECTION_ATTACHMENTS)

	local result, item_count = stmt:reset():resultset()
	
	logger.info("Zotero:", item_count, "offline items to download") 
	for i=1,item_count do
		local download_key = result[1][i]
		local filename = result[2][i]
		progress_callback(string.format(_("Downloading attachment %i/%i"), i, item_count))
		local path, e = API.downloadAndGetPath(download_key, nil)

		if e ~= nil then
			progress_callback(string.format(_("Error downloading attachment %s: %s"), filename, e))
		end
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
	--print(JSON.encode(result))
    return result
end


function API.resetSyncState()
    API.closeDB()
    local bak_path = BaseUtil.joinPath(API.zotero_dir, "zotero.db.old")
    if not os.rename(API.db_path, bak_path) then
		os.delete(API.db_path)
	end
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
--    local stmt = db:prepare(ZOTERO_GET_VERSION)
    local stmt = db:prepare(ZOTERO_GET_ATTACHMENT_VERSION)
    local result, nr = stmt:reset():bind(key):resultset()
    stmt:close()

    if nr == 0 then
        return nil
    else
        return tonumber(result[1][1]), tonumber(result[2][1]), tonumber(result[3][1]), tonumber(result[4][1])
    end

end


function API.setAttachmentVersion(id, version)
    local db = API.openDB()
--    local stmt = db:prepare(ZOTERO_SET_VERSION)
	local stmt = db:prepare(ZOTERO_SET_ATTACHMENT_SYNCEDVERSION)
    stmt:reset():bind(id, version):step()
    stmt:close()
end

function API.setAttachmentVersionByKey(key, version)
    local db = API.openDB()
	local stmt = db:prepare(ZOTERO_SET_ATTACHMENT_SYNCEDVERSION_KEY)
    stmt:reset():bind(key, version):step()
    stmt:close()
end

function API.syncAnnotations(progress_callback)
    local db = API.openDB()
	local stmt = db:prepare(ZOTERO_GET_LOCAL_ATTACHMENT)
	-- get list of all local pdf files (according to db...)
    local files, item_count = stmt:resultset()
    logger.info("Checking for new local annotations on "..item_count.." pdf files.")
    stmt:close()
	local stmt_ts = db:prepare(ZOTERO_SET_ATTACHMENT_LASTSYNC)
	
    for i = 1, item_count do
        local key = files[1][i]
        local filename = files[2][i]
        local db_ts = tonumber(files[3][i])
        
        local file_path = API.storage_dir .. "/" .. key .. "/" .. filename
        -- Check time of last modification
        -- TO DO
		--local targetDir, targetPath = API.getDirAndPath(item)
		local sidecarFile = DocSettings:findSidecarFile (file_path, no_legacy)
		if sidecarFile then	-- only can have local annotations if sidecar file exists...
			local file_ts = lfs.attributes(sidecarFile, "modification")
			--print(file_ts, db_ts, file_ts > db_ts)
			-- Compare to last sync recorded in db
			if file_ts > db_ts then	-- sidecar files has been modified since last sync
				Annotations.createAnnotations(file_path, key, API.createItems)
				stmt_ts:reset():bind1(1, key):step()
 			end
		else
			-- TO-DO:
			-- Should check if local attachment still exists and update db if need be...
		end
				
        if progress_callback ~= nil and (i == 1 or i % 10 == 0 or i == item_count) then
            progress_callback(string.format(_("Syncing annotations of file %i/%i"), i, item_count))
        end
    end
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

    local e = API.verifyZoteroAccess()
    if e ~= nil then
        return created_items, e
    end
    local headers = API.zoteroHeader
    local create_url = API.userLibraryURL.."/items"


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
        
        -- Maybe don't update library version in here, becase we can't be sure that we have synced all items yet
        -- Should run a library update after we have finished creating new items...
        
        --local new_library_version = response_headers["last-modified-version"]
----        print("New lib version: ", new_library_version)
        --if new_library_version ~= nil then
            --API.setLibraryVersion(new_library_version)
        --else
            --logger.err("Z: could not update library version from create request, got " .. tostring(new_library_version))
        --end
		--print(JSON.encode(result))
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

function getPageDimensions(filePath)

    -- We need to get page height of pdf document to be able to convert Zotero position to KOReader positions
    -- Open document to get the dimensions of the first page
    local DocumentRegistry = require("document/documentregistry")	
    local provider = DocumentRegistry:getProvider(filePath)	
    local document = DocumentRegistry:openDocument(filePath, provider)
    if not document then
        UIManager:show(InfoMessage:new{
            text = _("No reader engine for this file or invalid file.")
        })
        return
    end
    -- Assume all pages have the same dimensions and thus just take first page:
    local pageDims = document:getNativePageDimensions(1)
    print("Page dimensions: ", JSON.encode(pageDims))
    document:close()
    return pageDims
end

-- Sync annotations for specified item from Zotero with sdr folder
function API.syncItemAnnotations(item, annotation_callback)

	if item.data.contentType ~= SUPPORTED_MEDIA_TYPES[1] then
        return "Warning: Can only sync annotations for pdf files for now"
    end
	
	local itemKey = item.key
    local fileDir, filePath = API.getDirAndPath(item)

    if filePath == nil then
        return "Error: could not find item"
    end
    
    -- (Relevant) Zotero annotation keys (currently only for highlights)
    local zoteroItems = {}
    local updateNeeded = true

    local zotCount = 0
    
    local settings = LuaSettings:open(BaseUtil.joinPath(fileDir, ".zotero.metadata.lua"))    
    local lastSyncedLibVersion = settings:readSetting("libraryVersion", 0)
    local libVersion = tonumber(API.getLibraryVersion())
    print("Local lib version: ", lastSyncedLibVersion)
    if lastSyncedLibVersion >= libVersion then 
        print("No need to check Zotero database") 
        zoteroItems = settings:readSetting("zoteroItems")
        updateNeeded = false
    else
        print("Checking item\'s annotations in Zotero database")
        -- Scan zotero annotations.
		local db = API.openDB()
		local stmt_get_ItemAnnotationInfo = db:prepare(ZOTERO_GET_ITEM_ANNOTATIONS_INFO)

		local row = stmt_get_ItemAnnotationInfo:bind(itemKey):step()
		while row ~= nil do
			local key = row[1]
			local versi = row[2]
			zoteroItems[row[1]] = { ["status"] = "newerRemote" , ["version"] = tonumber(row[2]), ["syncedVersion"] = tonumber(row[3])}
			zotCount = zotCount + 1
			row = stmt_get_ItemAnnotationInfo:step(row)
		end
        print(JSON.encode(zoteroItems))
        if zotCount > 0 then
            print("Found "..zotCount.." zotero annotations.")
        else  -- nothing to update!
            updateNeeded = false
        end
    end
    
	-- Find all the annotations that KOReader knows about from DocSettings
    local docSettings = DocSettings:open(filePath)    
    local koreaderAnnotations = docSettings:readSetting("annotations", {})
    print(#koreaderAnnotations.." KOReader Annotations. ")

    local localZotAnn = {}
    local localKORAnn = {}
    local localMods = 0
    -- If there are locally stored KOReader annotations, check them to identify Zotero annotations
    if #koreaderAnnotations > 0 then
        -- Iterate over KOReader annotations to check which ones are zotero items
        for idx, ann in ipairs(koreaderAnnotations) do
            if (ann.zoteroKey ~= nil) then
                --print("KOReader annotation imported from Zotero ", ann.zoteroKey)
                localZotAnn[ann.zoteroKey] = idx
            else
                if ann.drawer ~= nil then -- it's a note or highlight
                    logger.dbg("Zotero: Additional KOReader annotation: "..ann.text)
                    -- make 'fake' sort key
                    koreaderAnnotations[idx].zoteroSortIndex = string.format("%05d|%06d|%05d", ann.page-1, idx, math.floor(ann.pos0.y))
                    --print(koreaderAnnotations[idx].zoteroSortIndex)
                    table.insert(localKORAnn, idx)
                    localMods = localMods + 1
                else -- it's a bookmark (or even s/t else?)
                    logger.dbg("Zotero: Ignoring bookmark: "..ann.text)
                end
            end
        end
        
        -- Deal with local Zotero annotations
        --
        -- Iterate over local Zotero annotations to check whether they have been changed
        for key, idx in pairs(localZotAnn) do
            local item = API.getItem(key)
            local ann = koreaderAnnotations[idx]
            if item ~= nil then
	            if zoteroItems[key] ~= nil then
					zoteroItems[key].position = idx
				else
					zoteroItems[key] = { ["position"] = idx }
				end
                if item.version > ann.zoteroVersion then
                    print("Database item is newer. Overwrite local version of "..key)
                    zoteroItems[key].status = "newerRemote"
                else
                    if (item.data.annotationComment == ann.note) or -- same comment
                    (ann.note == nil and item.data.annotationComment == "") then  -- or unchanged text hightlight only
                        print("Up to date "..key) 
                        zoteroItems[key].status = "inSync"
                    else
                        print("Locally modified note "..key) 
                        zoteroItems[key].status = "newerLocal" 
                        localMods = localMods + 1
                    end                   
                end
            else
				if ann.zoteroVersion > libVersion then
					print("Local Annotation "..key.." ahead of DB")
					zoteroItems[key] = { ["status"] = "inSync" }
				else
					print("Annotation has been deleted in Zotero "..key)
					zoteroItems[key] = { ["status"] = "deletedRemote", ["position"] = idx  }
				end
            end
        end
        -- Check with the remote list of annotations to see if there are any new ones or local deletions...
        for key, annInfo in pairs(zoteroItems) do
            if localZotAnn[key] == nil then
                if API.getItem(key).version > lastSyncedLibVersion then
                    print("New Zotero annotation: "..key)
                    zoteroItems[key].status = "newRemote"
                else
                    print("Annotation has been deleted locally: "..key)
                    zoteroItems[key].status = "deletedLocal"
                    localMods = localMods + 1
                end
            end        
        end
        print("Zotero annotations ", JSON.encode(zoteroItems))
    else
        if zoteroItems ~= nil then updateNeeded = true end
    end
    -- Need to decide what to do in case there are local changes
    -- Maybe have dialogue with choice of discarding, keeping them locally or synching them to Zotero?
    local action = "keep"
    if annotation_callback ~= nil then action = annotation_callback() end
    action = "upload"
    --action = "discard"
    if localMods > 0 then
        print(localMods.." locally modified annotations")
        if action == "discard" then  -- delete all local annotations
            print("Discarding all local changes and revert to Zotero annotations.")
            koreaderAnnotations = {}
            updateNeeded = true
        elseif action == "upload" then
            print("Zotero upload of changes is not implemented yet! Just keeping changes locally.")
        else
            print("Keeping the local changes.")
        end
    end
    
    if updateNeeded then
        -- We need to get page height of pdf document to be able to convert Zotero position to KOReader positions
        local pageDims = settings:readSetting("pageDimensions")
        if pageDims == nil then
            pageDims = getPageDimensions(filePath)
        end
        
        if #koreaderAnnotations == 0 then
            for key, annInfo in pairs(zoteroItems) do
                table.insert(koreaderAnnotations, Annotations.convertZoteroToKOReader(API.getItem(key), pageDims.h))
            end
        else
            for key, itemInfo in pairs(zoteroItems) do
            print("Updating item ", key, itemInfo.status)
                if itemInfo.status == "newerRemote" then
                    koreaderAnnotations[itemInfo.position] = Annotations.convertZoteroToKOReader(API.getItem(key), pageDims.h)
                elseif itemInfo.status == "deletedRemote" then
                    koreaderAnnotations[itemInfo.position] = nil
                elseif itemInfo.status == "newRemote" then
                    table.insert(koreaderAnnotations, Annotations.convertZoteroToKOReader(API.getItem(key), pageDims.h))
                end
            end
        end
        
        -- Unsorted annotations seem to lead to spurious results when displaying notes!
        -- So seems important to have them in the right order before saving them
        
        -- Use zoteroSortIndex for sorting.
        -- No idea how this index is generated, but this seems to work...
        local comparator = function(a,b)
            return (a["zoteroSortIndex"] < b["zoteroSortIndex"])
        end
        table.sort(koreaderAnnotations, comparator)

        -- Write to sdr file
        docSettings:saveSetting("annotations", koreaderAnnotations)
        -- Save page dimensions for future use
        settings:saveSetting("pageDimensions", pageDims)

--      print(JSON.encode(koAnnotations))          
    end
    
    settings:saveSetting("zoteroItems", zoteroItems)
    settings:saveSetting("libraryVersion", tonumber(API.getLibraryVersion()))
    settings:flush() 
    docSettings:flush()
end

-- Attach Zotero annotations for specified item
-- by adding them to document settings
function API.attachItemAnnotations(item, annotation_callback)

	if item.data.contentType ~= SUPPORTED_MEDIA_TYPES[1] then
        return "Warning: Can only sync annotations for pdf files for now"
    end
	
	local itemKey = item.key
    local fileDir, filePath = API.getDirAndPath(item)

    if filePath == nil then
        return "Error: could not find item"
    end
    
    -- (Relevant) Zotero annotation keys (currently only for highlights)
    local zoteroItems = {}
    local zotCount = 0
    
	local docSettings = DocSettings:open(filePath)    
    local lastSyncedLibVersion = docSettings:readSetting("zoteroLibVersion", 0)
    local libVersion = API.getLibraryVersion()

    if lastSyncedLibVersion < libVersion then 
        --print("Checking item\'s annotations in Zotero database")
        -- Scan zotero annotations.
		local db = API.openDB()
		local stmt_get_ItemAnnotationInfo = db:prepare(ZOTERO_GET_ITEM_ANNOTATIONS_INFO)

		local row = stmt_get_ItemAnnotationInfo:bind(itemKey):step()
		while row ~= nil do
			local key = row[1]
			zoteroItems[key] = {["version"] = tonumber(row[2]), ["syncedVersion"] = tonumber(row[3])}
			zotCount = zotCount + 1
			row = stmt_get_ItemAnnotationInfo:step(row)
		end
        --print(JSON.encode(zoteroItems))
    end
    if zotCount > 0 then
		-- Find all the annotations that KOReader knows about from DocSettings
		local koreaderAnnotations = docSettings:readSetting("annotations", {})
		print(#koreaderAnnotations.." KOReader Annotations. ")

		local localZotAnn = {}
		-- If there are locally stored KOReader annotations, check them to identify Zotero annotations
		for idx, ann in ipairs(koreaderAnnotations) do
			if (ann.zoteroKey ~= nil) then
				if zoteroItems[ann.zoteroKey] ~= nil then
					localZotAnn[ann.zoteroKey] = { ["position"] = idx, ["version"] = ann.zoteroVersion }
				elseif ann.zoteroVersion < libVersion then
					logger.info("Delete local Zotero annotation "..ann.zoteroKey)
					table.remove(koreaderAnnotations, idx)
				end
			end
		end
		
		-- We need to get page height of pdf document to be able to convert Zotero position to KOReader positions
		local pageHeight = docSettings:readSetting("page_height")
		if pageHeight == nil then
			pageHeight = getPageDimensions(filePath).h
		end
		
		for key, itemInfo in pairs(zoteroItems) do
			local item = API.getItem(key)
			print(key, JSON.encode(localZotAnn[key]))
			if localZotAnn[key] == nil then
				--print(JSON.encode(item))
				table.insert(koreaderAnnotations, Annotations.convertZoteroToKOReader(item, pageHeight))
			elseif localZotAnn[key].version < itemInfo.version then
				logger.info("Updating annotation "..key)
				koreaderAnnotations[localZotAnn[key].position] = Annotations.convertZoteroToKOReader(item, pageHeight)
			end
		end
		--print(JSON.encode(koreaderAnnotations))
		-- Unsorted annotations seem to lead to spurious results when displaying notes!
		-- So seems important to have them in the right order before saving them
		
		-- Use zoteroSortIndex for sorting.
		-- No idea how this index is generated, but this seems to work...
		local comparator = function(a,b)
			return (a.page..(a.zoteroSortIndex or "") < b.page..(b.zoteroSortIndex or ""))
		end
		table.sort(koreaderAnnotations, comparator)

		docSettings:saveSetting("annotations", koreaderAnnotations)
		-- Save page dimensions for future use
		docSettings:saveSetting("page_height", pageHeight)
	else
		logger.info("Zotero: item annotations up to date.")
	end
	-- Write new lib version to sdr file
	docSettings:saveSetting("zoteroLibVersion", libVersion)
    docSettings:flush()
end


return API
