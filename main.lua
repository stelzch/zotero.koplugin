local Blitbuffer = require("ffi/blitbuffer")
local InfoBuffer = require("ui/widget/infomessage")
local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local LuaSettings = require("frontend/luasettings")
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local Button = require("ui/widget/button")
local IconButton = require("ui/widget/iconbutton")
local ListView = require("ui/widget/listview")
local TextBoxWidget = require("ui/widget/textboxwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local Menu = require("ui/widget/menu")
local InputText = require("ui/widget/inputtext")
local FocusManager = require("ui/widget/focusmanager")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local _ = require("gettext")


local MAX_RESULTS = 20



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


local ZoteroBrowser = Menu:extend{
    width = Screen:getWidth(),
    height = Screen:getHeight(),
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

function ZoteroBrowser:onLeftButtonTap()
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

function ZoteroBrowser:displayCollection(collection_id)
    local db_path = ("%s/zotero.sqlite"):format(self.zotero_dir_path)

    self.conn = SQ3.open(db_path, "ro")

    -- add collections (folders)
    local collectionStmt = self.conn:prepare(SUB_COLLECTION_QUERY):reset():bind(collection_id)
    local collectionResults, nrecord = collectionStmt:resultset("hik", MAX_RESULTS)
    local itemStmt = self.conn:prepare(ITEM_QUERY):reset():bind(collection_id)
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
                        self.zotero_dialog:init()
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
            self.settings:saveSetting("zotero_dir", self.zotero_dir_path)
            self.settings:flush()
        end,
    }:chooseDir()
end

function Plugin:onZotero()

end

return Plugin
