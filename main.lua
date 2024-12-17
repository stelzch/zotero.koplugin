local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local SpinWidget = require("ui/widget/spinwidget")
local DataStorage = require("datastorage")
local FrameContainer = require("ui/widget/container/framecontainer")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local Menu = require("ui/widget/menu")
local Geom = require("ui/geometry")
local _ = require("gettext")
local ZoteroAPI = require("zoteroapi")
local itemInfoViewer = require("zoteroiteminfo")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")


local DEFAULT_LINES_PER_PAGE = 14

local init_done = false

local table_empty = function(table)
    -- see https://stackoverflow.com/a/1252776
    local next = next
    return (next(table) == nil)
end

local ZoteroBrowser = Menu:extend{
    no_title = false,
    is_borderless = true,
    is_popout = false,
    show_path = true,
--    subtitle = "test path",
    title_bar_fm_style = true,
    parent = nil,
    title_bar_left_icon = "appbar.search",
    covers_full_screen = true,
    return_arrow_propagation = false,
}


function ZoteroBrowser:init()
    Menu.init(self)
    self.paths = {}
    self.keys = {}
end

-- Show search input
function ZoteroBrowser:onLeftButtonTap()
    local search_query_dialog
    search_query_dialog = InputDialog:new{
        title = _("Search Zotero titles"),
        input = "",
        input_hint = "search query",
        description = _("This will search title and first author of all entries."),
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
    local dir = table.remove(self.keys, #self.keys)
    if #self.keys == 0 then
        self:displayCollection(nil)
    else
        self:displayCollection(self.keys[#self.keys])
    end
    return true
end


function ZoteroBrowser:openAttachment(key)
    local full_path, e = ZoteroAPI.downloadAndGetPath(key)
    if e ~= nil or full_path == nil then
        local b = InfoMessage:new{
            text = _("Could not open file.") .. e,
            timeout = 5,
            icon = "notice-warning"
        }
        UIManager:show(b)
    else
        assert(full_path ~= nil)
        UIManager:close(self.download_dialog)
        local ReaderUI = require("apps/reader/readerui")
        self.close_callback()
        ReaderUI:showReader(full_path)
    end
end

function ZoteroBrowser:onMenuSelect(item)
    if item.type == "collection" then
        table.insert(self.paths, item.text)
        table.insert(self.keys, item.key)
        self:displayCollection(item.key)
    elseif item.type == "wildcard_collection"  then
        table.insert(self.paths, "All items")
        table.insert(self.keys, "all")
        self:displaySearchResults("")
    elseif item.type == "item" then
        self.download_dialog = InfoMessage:new{
            text = _("Downloading file"),
            timeout = 5,
            icon = "notice-info",
        }
        UIManager:scheduleIn(0.05, function()
            local attachments = ZoteroAPI.getItemAttachments(item.key)
            if attachments == nil or table_empty(attachments)  then
                local b = InfoMessage:new{
                    text = _("The selected entry does not have any attachments."),
                    timeout = 5,
                    icon = "notice-warning"
                }
                UIManager:show(b)
                return
            else
				-- open the *last* attachment associated with the item.
				-- For all the items I've tested this is the one that 
				-- Zotero desktop defaults to, but this might be fluke...
                self:openAttachment(attachments[#attachments].key)
            end
        end)
        UIManager:show(self.download_dialog)
    elseif item.type == "attachment" then
        self:openAttachment(item.key)
    elseif item.type == "label" then
        -- nop
    end
end

function ZoteroBrowser:onMenuHold(item)
    if item.type == "item" then
        --table.insert(self.paths, item.key)
        --table.insert(self.keys, item.key)
        --self:displayAttachments(item.key)
        local itemDetails = ZoteroAPI.getItemWithAttachments(item.key)
        local itemInfo = itemInfoViewer:new()
        itemInfo:show(itemDetails.data, itemDetails.attachments, function(key)
			local full_path, e = ZoteroAPI.downloadAndGetPath(key)
			if e ~= nil or full_path == nil then
				local b = InfoMessage:new{
					text = _("Could not open file.") .. e,
					timeout = 5,
					icon = "notice-warning"
				}
				UIManager:show(b)
			else
				assert(full_path ~= nil)
				local ReaderUI = require("apps/reader/readerui")
				self.close_callback()
				ReaderUI:showReader(full_path)
			end
		end)
    elseif item.type == "collection" then
        local is_offline_enabled = ZoteroAPI.isOfflineCollection(item.key)
        local button_label = "▢  Download this collection during sync"
        if is_offline_enabled then
            button_label = "✓ Download this collection during sync"
        end
        local collection_dialog
        collection_dialog = ButtonDialog:new{
            title = item.text,
            buttons = {
                {
                {
                    text = button_label,
                    callback = function()
                        if is_offline_enabled then
                            ZoteroAPI.removeOfflineCollection(item.key)
                        else
                            ZoteroAPI.addOfflineCollection(item.key)
                        end
                        UIManager:close(collection_dialog)
                    end

                }
            }
            }
        }
        UIManager:show(collection_dialog)
    end
end

function ZoteroBrowser:displaySearchResults(query)
    local items = ZoteroAPI.displaySearchResults(query)
	table.insert(self.paths, query)
    table.insert(self.keys, "search")
    items = self:addLabelIfEmpty(items, "No search results!")
    self:setItems(items)
end

function ZoteroBrowser:displayCollection(collection_id)
    local items = ZoteroAPI.displayCollection(collection_id)

    if collection_id == nil then
		if table_empty(items) then
			items = self:addLabelIfEmpty(items, "Library is empty! Synchronise first...")
		else
			table.insert(items, 1, {
				["text"] = _("All Items"),
				["type"] = "wildcard_collection"
			})
		end
	else
	    items = self:addLabelIfEmpty(items)
	end
    self:setItems(items)
end

function ZoteroBrowser:addLabelIfEmpty(items, msg)
    if table_empty(items) then
		if msg == nil then msg = "No Items" end
        table.insert(items, 1, {
            ["text"] = _(msg),
            ["type"] = "label",
        })
    end

    return items
end

function ZoteroBrowser:displayAttachments(key)
    local attachments = ZoteroAPI.getItemAttachments(key) or {}
    attachments = self:addLabelIfEmpty(attachments)

    self:setItems(attachments)
end

function ZoteroBrowser:zPath()
	local path = "HOME"
	if #self.paths > 0 then
		if self.keys[#self.keys] == "search" then
			path = "Search results: '"..self.paths[#self.paths].."'"
		else
			path = "/"..table.concat(self.paths, "")
		end	
	end
	return path
end

function ZoteroBrowser:setItems(items, subtitle)
	local subtitle = self:zPath()
    self:switchItemTable("Zotero Browser", items, nil, nil, subtitle)
end

local Plugin = WidgetContainer:new{
    name = "zotero",
    is_doc_only = false
}

function Plugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("zotero_browser_action", {
        category="none",
        event="ZoteroBrowserAction",
        title=_("Zotero Collection Browser"),
        general=true,
    })
    Dispatcher:registerAction("zotero_sync_action", {
        category="none",
        event="ZoteroSyncAction",
        title=_("Zotero Sync"),
        general=true
    })
end

function Plugin:init()
	-- not sure when this is called, so I don't understand why some bits need to be 
	-- re-initialised every time. 
	-- But at least the ZoteroAPI only needs to be initialised once
	self:onDispatcherRegisterActions()
	self.ui.menu:registerToMainMenu(self)
    if not init_done then
		xpcall(self.initAPI, self.initError, self)
		init_done = true
	end
	xpcall(self.initBrowser, self.initError, self)	
	self.initialized = init_done

	logger.dbg("Zotero: successfully initialized!")
end

function Plugin:initError(e)
    logger.err("Could not initialize Zotero: " .. e)
end

function Plugin:checkInitialized()
    if not self.initialized  or self.browser == nil then
        UIManager:show(InfoMessage:new{
            text = _("Zotero not initialized. Please set the plugin directory first."),
            timeout = 3,
            icon = "notice-warning"
        })
    end

    return self.initialized
end

function Plugin:initAPI()
    self.zotero_dir_path = DataStorage:getDataDir() .. "/zotero"
    lfs.mkdir(self.zotero_dir_path)
    ZoteroAPI.init(self.zotero_dir_path)
end

function Plugin:initBrowser()
    self.small_font_face = Font:getFace("smallffont")
    self.browser = ZoteroBrowser:new{
        refresh_callback = function()
            UIManager:setDirty(self.zotero_dialog)
            self.ui:onRefresh()
        end,
        close_callback = function()
            UIManager:close(self.zotero_dialog)
        end,
		items_per_page = self:getItemsPerPage()
    }
    self.zotero_dialog = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.browser
    }
    self.browser.show_parent = self.zotero_dialog
    logger.dbg("Zotero: Browser initialized")
end

function Plugin:addToMainMenu(menu_items)
    menu_items.zotero = {
        text = _("Zotero"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Browse"),
                callback = function()
                    self:onZoteroBrowserAction()
                end,
            },
            {
                text = _("Synchronize"),
                callback = function()
                    self:onZoteroSyncAction()
                end,

            },
            {
                text = _("Maintenance"),
                callback = function()
                    return nil
                end,
                sub_item_table = {
                    {
                        text = _("Re-analyse local items"),
                        callback = function()
                            self:onZoteroReanalyzeAction()
                        end,
                    },
                    {
                        text = _("Re-scan storage for local items"),
                        callback = function()
                            self:onZoteroRescanAction()
                        end,
                    },
                    {
                        text = _("Resync entire collection"),
                        callback = function()
                            ZoteroAPI.resetSyncState()
                            self:onZoteroSyncAction()
                        end,
                    },
                },
            },
            {
                text = _("Settings"),
                callback = function()
                    return nil
                end,
                sub_item_table = {
                    {
                        text = _("Configure Zotero account"),
                        callback = function()
                            self:setAccount()
                        end,
                    },
                    {
                        text = _("Enable WebDAV storage"),
                        checked_func = function()
                            return ZoteroAPI.getWebDAVEnabled()
                        end,
                        callback = function()
                            ZoteroAPI.toggleWebDAVEnabled()
                        end,
                    },
                    {
                        text = _("Configure WebDAV account"),
                        callback = function()
                            self:setWebdavAccount()
                        end,
                    },
                    {
                        text = _("Check WebDAV connection"),
                        callback = function()
                            local msg = nil
                            local result = ZoteroAPI.checkWebDAV()
                            if result == nil then
                                msg = _("Success, WebDAV works!")
                            else
                                msg = _("WebDAV could not connect: ") .. result
                            end
                            UIManager:show(InfoMessage:new{
                                text = msg,
                                timeout = 3,
                                icon = "notice-info"
                            })
                        end,
                    },
                    {
                        text = _("Items per page"),
                        callback = function()
                            self:setItemsPerPage()
                        end,
                    },
                }
            },
            {
                text = _("About/Info"),
                callback = function()
					local version = ZoteroAPI.version
					local stats = ZoteroAPI.getStats()
					UIManager:show(InfoMessage:new{
						text = _("Plugin version: \n"..version..
						"\n\nLibrary info:\n  Version:\t\t\t"..stats.libVersion..
						"\n  Last sync:  "..stats.lastSync..
						"\n\nLibrary stats:\n\tCollections:\t\t"..stats.collections..
						'\n\tTotal items:\t\t'..stats.items..
						"\n\tAttachments:\t"..stats.attachments..
						"\n\tAnnotations:\t"..stats.annotations.."\n"),
						--timeout = 10,
						--icon = "notice"
						show_icon = false,
					})

                    return nil
                end,
			}
        },
    }
end

function Plugin:setAccount()
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
                        local fields = self.account_dialog:getFields()
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
                        ZoteroAPI.saveSettingsToFile()
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

function Plugin:setWebdavAccount()
    self.webdav_account_dialog = MultiInputDialog:new{
        title = _("Edit WebDAV credentials"),
        fields = {
            {
                text = ZoteroAPI.getWebDAVUrl(),
                hint = _("URL")
            },
            {
                text = ZoteroAPI.getWebDAVUser(),
                hint = _("Username"),
            },
            {
                text = ZoteroAPI.getWebDAVPassword(),
                hint = _("Password"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.webdav_account_dialog:onClose()
                        UIManager:close(self.webdav_account_dialog)
                    end
                },
                {
                    text = _("Update"),
                    callback = function()
                        local fields = self.webdav_account_dialog:getFields()

                        ZoteroAPI.setWebDAVUrl(fields[1])
                        ZoteroAPI.setWebDAVUser(fields[2])
                        ZoteroAPI.setWebDAVPassword(fields[3])
                        ZoteroAPI.saveSettingsToFile()
                        self.webdav_account_dialog:onClose()
                        UIManager:close(self.webdav_account_dialog)
                    end
                },
            },
        },
    }
    UIManager:show(self.webdav_account_dialog)
    self.webdav_account_dialog:onShowKeyboard()
end

function Plugin:setItemsPerPage()
    assert(ZoteroAPI.getSettings ~= nil)
    self.items_per_page_dialog = SpinWidget:new {
        title_text = _("Set items per page"),
        value = self:getItemsPerPage(),
		value_min = 1,
		value_max = 1000,
        callback = function(d)
						ZoteroAPI.getSettings():saveSetting("items_per_page", d.value)
						ZoteroAPI.saveSettingsToFile()
                        UIManager:show(InfoMessage:new{
                            text = _("This change requires a restart of KOReader to take effect."),
                            timeout = 3,
                            icon = "notice"
                        })
                    end,
    }
	UIManager:show(self.items_per_page_dialog)
end

function Plugin:getItemsPerPage()
    return ZoteroAPI.getSettings():readSetting("items_per_page", DEFAULT_LINES_PER_PAGE)
end

function Plugin:onZoteroBrowserAction()
    if not self:checkInitialized() then
        return
    end

    self.browser:init()
    UIManager:show(self.zotero_dialog, "full", Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight()
    })
    self.browser:displayCollection(nil)
end

function Plugin:onZoteroSyncAction()
    if not self:checkInitialized() then
        return
    end
    local Trapper = require("frontend/ui/trapper")
    Trapper:wrap(function()
        Trapper:info("Synchronizing Zotero library.")
        local e = ZoteroAPI.syncAllItems(function(msg)
            Trapper:info(msg)
        end)


        if e == nil then
            Trapper:info("Success")
        else
            Trapper:info(e)
        end

    end)
end

function Plugin:onZoteroReanalyzeAction()
    if not self:checkInitialized() then
        return
    end
    local Trapper = require("frontend/ui/trapper")
    Trapper:wrap(function()
        Trapper:info("Synchronizing Zotero library.")
        local e = ZoteroAPI.checkItemData(function(msg)
            Trapper:info(msg)
        end)


        if e == nil then
            Trapper:info("Success")
        else
            Trapper:info(e)
        end

    end)
end

function Plugin:onZoteroRescanAction()
    if not self:checkInitialized() then
        return
    end
    local Trapper = require("frontend/ui/trapper")
    Trapper:wrap(function()
        Trapper:info("Scanning local Zotero storage.")
        local cnt = ZoteroAPI.scanStorage()
		
		Trapper:info("Found "..cnt.." local attachments.")

    end)
end

return Plugin
