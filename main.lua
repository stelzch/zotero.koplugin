local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings = require("frontend/luasettings")
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local Button = require("ui/widget/button")
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
local _ = require("gettext")


local MAX_RESULTS = 20
local SEARCH_QUERY = [[
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
	SELECT items.key || "/" || substr(path, 9) FROM itemAttachments
	WHERE itemAttachments.parentItemID = items.itemID AND
		contentType = 'application/pdf' AND
		path LIKE 'storage:%'
	LIMIT 1
) AS path
 FROM collectionItems
	LEFT JOIN items ON items.itemID = collectionItems.itemID
	LEFT JOIN itemCreators ON items.itemID = itemCreators.itemID
	LEFT JOIN creators ON itemCreators.creatorID = creators.creatorID
	WHERE  itemCreators.orderIndex = 0
)
WHERE path IS NOT NULL AND name LIKE ?;
]]


local ZoteroBrowser = Menu:extend{
    width = Screen:getWidth() * 0.7,
    --height = Screen:getHeight(),
    no_title = true,
    is_borderless = true,
    is_popout = false,
    height = Screen:getHeight() *0.8
}


function ZoteroBrowser:init()
    Menu.init(self)
    print("Menu initialized")
end

function ZoteroBrowser:setItems(items)
    self.item_table = items
    self:init()
end

function ZoteroBrowser:onMenuSelect(item)
    print("Menu selected")
    print("Should open ", item.path)
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
    self:initUI()
end

function Plugin:initUI()
    self.search_query_input = InputText:new{
            hint = "Search (Wildcard: ?)",
            parent = self.search_page,
            edit_callback = function(modified)
                if modified == false then
                    return
                end

                self:searchQueryModified(self.search_query_input.text)
            end,
            width = Screen:getWidth() - Screen:scaleBySize(50)
    }
    self.browser = ZoteroBrowser:new{
        parent = w,
        item_table = {
            {text ="Hello World"}
        },
    }
    self.quit_button = Button:new{
        text = "X",
        callback = function()
            print("Closing page")
            UIManager:close(self.search_page)
        end
    }
    self.search_page = VerticalGroup:new{
        HorizontalGroup:new{
            self.search_query_input,
            self.quit_button
        },
        self.browser
    }
end

function Plugin:searchQueryModified(query)
    local sqlQuery = "%" .. string.gsub(query, " ", "%%") .. "%"
    print("Searching for ", "'" .. sqlQuery .. "'")
    local conn = SQ3.open(("%s/zotero.sqlite"):format(self.zotero_dir_path))
    local stmt = conn:prepare(SEARCH_QUERY)
    local resultset, nrecord = stmt:reset():bind(sqlQuery):resultset("hik", MAX_RESULTS)
    conn:close()
    

    results = {}
    if nrecord ~= 0 then
        for i=1,#resultset[1] do
            table.insert(results,
            {
                text = resultset[1][i],
                path = resultset[2][i]
            })
        end
    end
    self.browser:setItems(results)

    UIManager:setDirty(self.browser)

    print("Search results: ", #self.browser.item_table)
end

function Plugin:addToMainMenu(menu_items)
    menu_items.zotero = {
        text = _("Zotero"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Search Database"),
                callback = function()
                    local w
                    self:initUI()
                    UIManager:show(self.search_page)
                    self.search_query_input:onShowKeyboard()
                    self:searchQueryModified("")
                    print("Dialog should be opened")
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
            self.settings:saveSetting("zotero_dir", self.zotero_dir_path)
            self.settings:flush()
        end,
    }:chooseDir()
end

function Plugin:onZotero()

end

return Plugin
