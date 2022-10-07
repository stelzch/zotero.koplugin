local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings = require("frontend/luasettings")
local DataStorage = require("datastorage")
local FrameContainer = require("ui/widget/container/framecontainer")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local Menu = require("ui/widget/menu")
local Geom = require("ui/geometry")
local _ = require("gettext")
local ZoteroAPI = require("zoteroapi")
local MultiInputDialog = require("ui/widget/multiinputdialog")



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
    if item.collection ~= nil then
        table.insert(self.paths, item.key)
        self:displayCollection(item.key)
    else
        self.download_dialog = InfoMessage:new{
            text = _("Downloading file"),
            timeout = 5,
            icon = "notice-info",
        }
        UIManager:scheduleIn(0.05, function()
            local full_path, e = ZoteroAPI.downloadAndGetPath(item.key)
            print("Trying to sync annotations")
            ZoteroAPI.syncAnnotations(item.key)
            print("Annot sync done")
            if e ~= nil then
                local b = InfoMessage:new{
                    text = _("Could not open file.") .. e,
                    timeout = 5,
                    icon = "notice-warning"
                }
                UIManager:show(b)
            else
                UIManager:close(self.download_dialog)
                local ReaderUI = require("apps/reader/readerui")
                self.close_callback()
                ReaderUI:showReader(full_path)
            end
        end)
        UIManager:show(self.download_dialog)
    end
end

function ZoteroBrowser:displaySearchResults(query)
    self:setItems(ZoteroAPI.displaySearchResults(query))
end

function ZoteroBrowser:displayCollection(collection_id)
    self:setItems(ZoteroAPI.displayCollection(collection_id))
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
    ZoteroAPI.init(self.zotero_dir_path)
    self.small_font_face = Font:getFace("smallffont")
    self.browser = ZoteroBrowser:new{
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

function Plugin:addToMainMenu(menu_items)
    menu_items.zotero = {
        text = _("Zotero"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Browse"),
                callback = function()
                    self.zotero_dialog:init()
                    self.browser:init()
                    UIManager:show(self.zotero_dialog, "full", Geom:new{
                        w = Screen:getWidth(),
                        h = Screen:getHeight()
                    })
                    self.browser:displayCollection(nil)
                end,
            },
            {
                text = _("Synchronize"),
                callback = function()
                    UIManager:scheduleIn(1, function()
                        local e = ZoteroAPI.syncAllItems()

                        if e == nil then
                            UIManager:show(InfoMessage:new{
                                text = _("Success."),
                                timeout = 3,
                                icon = "check"
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = e,
                                timeout = 3,
                                icon = "notice-warning"
                            })
                        end
                    end)

                    UIManager:show(InfoMessage:new{
                        text = _("Synchronizing Zotero library. This might take some time."),
                        timeout = 3,
                        icon = "notice-info"
                    })
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
                    },
                    {
                        text = _("Configure account"),
                        callback = function()
                            self:setAccount()
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
            self.settings:saveSetting("zotero_dir", path)
            self.settings:flush()
            local b = InfoMessage:new{
                text = _("Restart KOReader for this setting to take effect"),
                timeout = 3,
                icon = "notice-info"
            }
            UIManager:show(b)
        end,
    }:chooseDir()
end

function Plugin:setAccount()
    print(ZoteroAPI.getUserID())
    self.account_dialog = MultiInputDialog:new{
        title = _("Edit User Info"),
        fields = {
            {
                text = ZoteroAPI.getUserID(),
                hint = _("User ID (integer)"),
            },
            {
                text = ZoteroAPI.getAPIKey(),
                hint = _("API Key"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.account_dialog:onClose()
                        UIManager:close(self.account_dialog)
                    end
                },
                {
                    text = _("Update"),
                    callback = function()
                        local fields = MultiInputDialog:getFields()
                        if not string.match(fields[1], "[0-9]+") then
                            UIManager:show(InfoMessage:new{
                                text = _("The User ID must be an integer number."),
                                timeout = 3,
                                icon = "notice-warning"
                            })
                            return
                        end

                        ZoteroAPI.setUserID(fields[1])
                        ZoteroAPI.setAPIKey(fields[2])
                        self.account_dialog:onClose()
                        UIManager:close(self.account_dialog)
                    end
                },
            },
        },
    }
    UIManager:show(self.account_dialog)
    self.account_dialog:onShowKeyboard()
end


function Plugin:onZotero()

end

return Plugin
