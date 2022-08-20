local Blitbuffer = require("ffi/blitbuffer")
local InfoBuffer = require("ui/widget/infomessage")
local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TopContainer = require("ui/widget/container/topcontainer")
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
	WHERE  itemCreators.orderIndex = 0
)
WHERE path IS NOT NULL AND name LIKE ?;
]]


local ZoteroBrowser = Menu:extend{
    --width = Screen:getWidth() * 0.7,
    --height = Screen:getHeight(),
    no_title = true,
    is_borderless = true,
    is_popout = false,
    outer_title_bar = Button:new{
        text = _("Whoop"),
        callback = function()
        end,
    },
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
    local full_path = self.zotero_dir_path .. "/storage/" .. item.path
    print("Should open ", full_path)
    --UIManager:close(self)
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(full_path)
end

local SearchDialog = TopContainer:new{
        dimen = Geom:new{
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        },
        ignore_if_over = "height",
}

function SearchDialog:init()
    print("initializing search dialog")
    local padding, margin, border_size
    border_size = Size.border.window
    padding = Size.padding.default
    margin = Size.margin.default
    self.search_query_input = InputText:new{
            hint = "Search (Wildcard: ?)",
            parent = self,
            margin = 2 * margin,
            edit_callback = function(modified)
                if modified == false then
                    return
                end
                print("Searching for", self.search_query_input.text)

                self:searchQueryModified(self.search_query_input.text)
            end,
            width = Screen:getWidth() - Screen:scaleBySize(50) - border_size * 2 - 3 * padding - 4 * margin,
            --height = Screen:getHeight() * 0.06
    }
    print("New height is ", self.search_query_input.height)
    --local keyboard_height = self.search_query_input:getKeyboardDimen()
    --print("Keyboard height is: ", keyboard_height)
    self.browser = ZoteroBrowser:new{
        parent = self,
        item_table = {
            {text ="Hello World"}
        },
        width = Screen:getWidth() + padding * 2,
        height = Screen:getHeight() - self.search_query_input.height - 2 * border_size - padding * 5 - 2 * margin,
        zotero_dir_path = self.zotero_dir_path
    }
    self.quit_button = IconButton:new{
        icon = 'close',
        callback = function()
            print("Closing page")
            UIManager:close(self)
        end,
        height = self.search_query_input.height + 2 * padding,
        width = Screen:scaleBySize(50),
        parent = self
    }
    print("Padding: ", padding)
    self.search_page = FocusManager:new{
        layout = {
            {self.search_query_input, self.quit_button},
            {self.browser}
        }
    }

    self.vgroup = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            self.search_query_input,
            self.quit_button
        },
        self.browser
    }
    self.layout = {{self.search_query_input, self.quit_button}, {self.browser}}

    self.dialog_frame = FrameContainer:new {
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.vgroup
    }

    self[1] = self.dialog_frame
end


function SearchDialog:searchQueryModified(query)

    local sqlQuery = "%" .. string.gsub(query, " ", "%%") .. "%"
    local db_path = ("%s/zotero.sqlite"):format(self.zotero_dir_path)
    print("Searching for " .. "'" .. sqlQuery .. "'" .. " in " .. db_path)

    self.conn = SQ3.open(db_path, "ro")

    local stmt = self.conn:prepare(SEARCH_QUERY)
    local resultset, nrecord = stmt:reset():bind(sqlQuery):resultset("hik", MAX_RESULTS)
    self.conn:close()
    

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

function SearchDialog:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.dialog_frame.dimen
    end)
end


function SearchDialog:onShowKeyboard(ignore_first_hold_release)
    self.search_query_input:onShowKeyboard(ignore_first_hold_release)
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
    print("Starting dialog init")
    self.search_dialog = SearchDialog:new{
        zotero_dir_path = self.zotero_dir_path
    }
    print("Finished init")
end


function Plugin:zoteroDatabaseExists()
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
                text = _("Search Database"),
                callback = function()
                    print(self.zotero_dir_path)
                    print("SHowing search dialog", self, self.search_dialog)
                    if not self:zoteroDatabaseExists() then
                        self:alertDatabaseNotReadable()
                    else
                        self.search_dialog:init()
                        UIManager:show(self.search_dialog, "full", Geom:new{
                            w = Screen:getWidth(),
                            h = Screen:getHeight()
                        })
                        self.search_dialog:searchQueryModified("")
                        self.search_dialog:onShowKeyboard()
                    end
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
            self.search_dialog.zotero_dir_path = path
            self.settings:saveSetting("zotero_dir", self.zotero_dir_path)
            self.settings:flush()
        end,
    }:chooseDir()
end

function Plugin:onZotero()

end

return Plugin
