local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings = require("frontend/luasettings")
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local FrameContainer = require("ui/widget/container/framecontainer")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local Menu = require("ui/widget/menu")
local Geom = require("ui/geometry")
local _ = require("gettext")


local MAX_RESULTS = 200



-- first parameter: collection id (NULL for root collection)
local SUB_COLLECTION_QUERY = [[
SELECT collectionID, collectionName FROM collections
WHERE parentCollectionID IS ?;
]]

-- first parameter: collection id (NULL for root collection)
local ITEM_QUERY = [[
SELECT author || " - " || title AS name, path FROM (
SELECT
creators.firstName || " " || creators.lastName AS author,
(
	SELECT value FROM itemData
	LEFT JOIN itemDataValues ON itemData.valueID = itemDataValues.valueID
	WHERE
	itemData.itemID = items.itemID AND
	itemData.fieldID = (SELECT fieldID FROM fields WHERE fieldName = 'title')
) AS title,
(
	SELECT attachItem.key || "/" || substr(path, 9) FROM itemAttachments
	LEFT JOIN items AS attachItem ON attachItem.itemID = itemAttachments.itemID
	WHERE itemAttachments.parentItemID = items.itemID AND
		contentType = 'application/pdf' AND
		path LIKE 'storage:%'
	LIMIT 1
) AS path
 FROM collectionItems
	LEFT JOIN items ON items.itemID = collectionItems.itemID
	LEFT JOIN itemCreators ON items.itemID = itemCreators.itemID
	LEFT JOIN creators ON itemCreators.creatorID = creators.creatorID
	WHERE itemCreators.orderIndex = 0 AND collectionItems.collectionID IS ?
)
WHERE path IS NOT NULL;
]]

local ROOT_ITEM_QUERY = [[
SELECT author || " - " || title AS name, path FROM (
SELECT
creators.firstName || " " || creators.lastName AS author,
(
	SELECT value FROM itemData
	LEFT JOIN itemDataValues ON itemData.valueID = itemDataValues.valueID
	WHERE
	itemData.itemID = items.itemID AND
	itemData.fieldID = (SELECT fieldID FROM fields WHERE fieldName = 'title')
) AS title,
(
	SELECT attachItem.key || "/" || substr(path, 9) FROM itemAttachments
	LEFT JOIN items AS attachItem ON attachItem.itemID = itemAttachments.itemID
	WHERE itemAttachments.parentItemID = items.itemID AND
		contentType = 'application/pdf' AND
		path LIKE 'storage:%'
	LIMIT 1
) AS path
 FROM items
	LEFT JOIN itemCreators ON items.itemID = itemCreators.itemID
	LEFT JOIN creators ON itemCreators.creatorID = creators.creatorID
	WHERE itemCreators.orderIndex = 0 
        AND items.itemID NOT IN (SELECT DISTINCT itemID FROM collectionItems)
)
WHERE path IS NOT NULL;
]]

-- first parameter: search query for first author and title
local SEARCH_QUERY = [[
SELECT author || " - " || title || COALESCE(" - " || doi, "") AS name, path FROM (
SELECT
creators.firstName || " " || creators.lastName AS author,
(
	SELECT value FROM itemData
	LEFT JOIN itemDataValues ON itemData.valueID = itemDataValues.valueID
	WHERE
	itemData.itemID = items.itemID AND
	itemData.fieldID = (SELECT fieldID FROM fields WHERE fieldName = 'title')
) AS title,
(
	SELECT attachItem.key || "/" || substr(path, 9) FROM itemAttachments
	LEFT JOIN items AS attachItem ON attachItem.itemID = itemAttachments.itemID
	WHERE itemAttachments.parentItemID = items.itemID AND
		contentType = 'application/pdf' AND
		path LIKE 'storage:%'
	LIMIT 1
) AS path,
(
    SELECT value FROM itemData
    LEFT JOIN itemDataValues ON itemData.valueID = itemDataValues.valueID
    WHERE
        itemData.itemID = items.itemID AND
        itemData.fieldID = (SELECT fieldID FROM fields WHERE fieldName = 'DOI')
    LIMIT 1
) AS doi
 FROM items
	LEFT JOIN itemCreators ON items.itemID = itemCreators.itemID
	LEFT JOIN creators ON itemCreators.creatorID = creators.creatorID
	WHERE itemCreators.orderIndex = 0
)
WHERE path IS NOT NULL AND name LIKE ?;
]]


local ZoteroBrowser = Menu:extend{
    no_title = false,
    is_borderless = true,
    is_popout = false,
    parent = nil,
    title_bar_left_icon = "appbar.search",
    covers_full_screen = true
--    return_arrow_propagation = false
}


function ZoteroBrowser:init()
    Menu.init(self)
    self.paths = {}
end

-- Show search input
function ZoteroBrowser:onLeftButtonTap()
    local search_query_dialog
    search_query_dialog = InputDialog:new{
        title = _("Search Zotero titles"),
        input = "",
        input_hint = "search query",
        description = _("This will search title, first author and DOI of all entries."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(search_query_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(search_query_dialog)
                        self:displaySearchResults(search_query_dialog:getInputText())
                    end,
                },
            }
        }
    }
    UIManager:show(search_query_dialog)
    search_query_dialog:onShowKeyboard()


end


function ZoteroBrowser:onReturn()
    table.remove(self.paths, #self.paths)
    if #self.paths == 0 then
        self:displayCollection(nil)
    else
        self:displayCollection(self.paths[#self.paths])
    end
    return true
end


function ZoteroBrowser:onMenuSelect(item)
    if item.collectionID ~= nil then
        table.insert(self.paths, item.collectionID)
        self:displayCollection(item.collectionID)
    elseif item.path ~= nil then
        local full_path = self.zotero_dir_path .. "/storage/" .. item.path
        local ReaderUI = require("apps/reader/readerui")
        self.close_callback()
        ReaderUI:showReader(full_path)
    end
end

function ZoteroBrowser:displaySearchResults(query)
    local cur_path = self.paths[#self.paths]
    if cur_path ~= nil and type(cur_path) == "string" then
        -- Replace the currently displayed search query
        self.paths[#self.paths] = query
    else
        -- Insert search query as path
        table.insert(self.paths, query)
    end


    query = "%" .. string.gsub(query, " ", "%%") .. "%"
    local db_path = ("%s/zotero.sqlite"):format(self.zotero_dir_path)
    self.conn = SQ3.open(db_path, "ro")
    local searchStmt = self.conn:prepare(SEARCH_QUERY):reset():bind(query)
    local searchResults, nrecords = searchStmt:resultset("hik", MAX_RESULTS)
    self.conn:close()
    searchResults = searchResults or {{}, {}}

    local menu_items = {}
    if nrecords == 0 then
        table.insert(menu_items,
        {
            text = "No search results."
        })
    else
        for i=1,#searchResults[1] do
            table.insert(menu_items,
            {
                text = searchResults[1][i],
                path = searchResults[2][i],
            })
        end
    end

    self:setItems(menu_items)
end

function ZoteroBrowser:displayCollection(collection_id)
    local db_path = ("%s/zotero.sqlite"):format(self.zotero_dir_path)
    self.conn = SQ3.open(db_path, "ro")

    -- add collections (folders)
    local collectionStmt = self.conn:prepare(SUB_COLLECTION_QUERY):reset():bind(collection_id)
    local collectionResults, nrecord = collectionStmt:resultset("hik", MAX_RESULTS)
    local itemStmt
    if collection_id == nil then
        itemStmt = self.conn:prepare(ROOT_ITEM_QUERY):reset()
    else
        itemStmt = self.conn:prepare(ITEM_QUERY):reset():bind(collection_id)
    end
    local itemResults, nrecord2 = itemStmt:resultset("hik", MAX_RESULTS)
    collectionResults = collectionResults or {{},{}}
    itemResults = itemResults or {{}, {}}
    self.conn:close()

    local results = {}

    if nrecord + nrecord2 == 0 then
        table.insert(results,
        {
            text = "<EMPTY>"
        })
    end

    if nrecord ~= 0 then
        for i=1,#collectionResults[1] do
            table.insert(results,
            {
                text = collectionResults[2][i] .. "/",
                collectionID = collectionResults[1][i]
            })
        end
    end

    -- add items (papers)
    if nrecord2 ~= 0 then
        for i=1,#itemResults[1] do
            table.insert(results,
            {
                text = itemResults[1][i],
                path = itemResults[2][i]
            })
        end
    end

    self:setItems(results)
end

function ZoteroBrowser:setItems(items)
    self:switchItemTable("Zotero", items)
end

local Plugin = WidgetContainer:new{
    name = "zotero",
    is_doc_only = false
}

function Plugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("zotero_open_action", {
        category="none",
        event="Zotero",
        title=_("Zotero"),
        general=true,
    })
end

function Plugin:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self.settings = LuaSettings:open(("%s/%s"):format(DataStorage:getSettingsDir(), "zotero_settings.lua"))
    self.zotero_dir_path = self.settings:readSetting("zotero_dir")
    self.small_font_face = Font:getFace("smallffont")
    self.browser = ZoteroBrowser:new{
        zotero_dir_path = self.zotero_dir_path,
        refresh_callback = function()
            UIManager:setDirty(self.zotero_dialog)
            self.ui:onRefresh()
        end,
        close_callback = function()
            UIManager:close(self.zotero_dialog)
        end
    }
    self.zotero_dialog = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.browser
    }
    self.browser.show_parent = self.zotero_dialog
end


function Plugin:zoteroDatabaseExists()
    if self.zotero_dir_path == nil or self.zotero_dir_path == "" then
        return false
    end

    local f = io.open((self.zotero_dir_path .. "/zotero.sqlite"), "r")
    if f~= nil then
        io.close()
        return true
    else
        return false
    end
end

function Plugin:alertDatabaseNotReadable()
    local b = InfoMessage:new{
        text = _("The Zotero database file is not readable. Please try setting the correct Zotero directory."),
        timeout = 5,
        icon = "notice-warning"
    }
    UIManager:show(b)
end

function Plugin:addToMainMenu(menu_items)
    menu_items.zotero = {
        text = _("Zotero"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Browse Database"),
                callback = function()
                    if not self:zoteroDatabaseExists() then
                        self:alertDatabaseNotReadable()
                    else
                        self.browser:init()
                        UIManager:show(self.zotero_dialog, "full", Geom:new{
                            w = Screen:getWidth(),
                            h = Screen:getHeight()
                        })
                        self.browser:displayCollection(nil)
                    end
                end,
            },
            {
                text = _("Settings"),
                callback = function()
                    return nil
                end,
                sub_item_table = {
                    {
                        text = _("Set Zotero directory"),
                        callback = function()
                            self:setZoteroDirectory()
                        end,
                    }
                }
            }
        },
    }
end

function Plugin:setZoteroDirectory()
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            self.zotero_dir_path = path
            self.zotero_dialog.zotero_dir_path = path
            self.browser.zotero_dir_path = path
            self.settings:saveSetting("zotero_dir", self.zotero_dir_path)
            self.settings:flush()
            if not self:zoteroDatabaseExists() then
                self:alertDatabaseNotReadable()
            else
                local b = InfoMessage:new{
                    text = _("Success! Your Zotero library should now be accessible."),
                    timeout = 3,
                    icon = "check"
                }
                UIManager:show(b)
            end
        end,
    }:chooseDir()
end

function Plugin:onZotero()

end

return Plugin
