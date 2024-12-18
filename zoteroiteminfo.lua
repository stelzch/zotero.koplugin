--[[--
This module provides a way to display item information (adapted from apps/filemanager/filemanagerbookinfo.lua)
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local DocSettings = require("docsettings")
local Document = require("document/document")
local DocumentRegistry = require("document/documentregistry")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local Screen = Device.screen
local T = ffiUtil.template

local itemInfo = WidgetContainer:extend{
    title = _("Item information"),
    props = {
        --"itemType",
        "title",
        "creators",
        "bookTitle",
        "publicationTitle",
        "proceedingsTitle",
        "conferenceName",
        "volume",
        "issue",
        "series",
        "edition",
        "publisher",
        "pages",
        "date",
        "ISBN",
        "DOI",
        "tags",
        --"abstractNote",
    },
    prop_text = {
        itemType         = _("Type:"),
        title            = _("Title:"),
        creators         = _("Author(s):"),
        bookTitle        = _("Book title:"),
        publicationTitle = _("Publication:"),
        proceedingsTitle = _("Proceedings:"),
        conferenceName   = _("Conference:"),
        volume           = _("Volume:"),
        issue            = _("Issue:"),
        series           = _("Series:"),
        edition          = _("Edition:"),
        publisher        = _("Publisher:"),
        pages            = _("Pages:"),
        date             = _("Date:"),
        ISBN             = _("ISBN:"),
        language         = _("Language:"),
        DOI              = _("DOI:"),
        tags             = _("Tags:"),
        abstractNote     = _("Abstract:"),
    },
}

local itemTypeStrings = {
	annotation          = _("Annotation"),
	artwork             = _("Artwork"),
	attachment          = _("Attachment"),
	audioRecording      = _("Audio Recording"),
	bill                = _("Bill"),
	blogPost            = _("Blog Post"),
	book                = _("Book"),
	bookSection         = _("Book Section"),
	case                = _("Case"),
	computerProgram     = _("Computer Program"),
	conferencePaper     = _("Conference Paper"),
	dictionaryEntry     = _("Dictionary Entry"),
	document            = _("Document"),
	email               = _("Email"),
	encyclopediaArticle = _("Encyclopedia Article"),
	film                = _("Film"),
	forumPost           = _("Forum Post"),
	hearing             = _("Hearing"),
	instantMessage      = _("Instant Message"),
	interview           = _("Interview"),
	journalArticle      = _("Journal Article"),
	letter              = _("Letter"),
	magazineArticle     = _("Magazine Article"),
	manuscript          = _("Manuscript"),
	map                 = _("Map"),
	newspaperArticle    = _("Newspaper Article"),
	note                = _("Note"),
	patent              = _("Patent"),
	podcast             = _("Podcast"),
	preprint            = _("Preprint"),
	presentation        = _("Presentation"),
	radioBroadcast      = _("Radio Broadcast"),
	report              = _("Report"),
	statute             = _("Statute"),
	thesis              = _("Thesis"),
	tvBroadcast         = _("TV Broadcast"),
	videoRecording      = _("Video Recording"),
	webpage             = _("Webpage"),
	dataset             = _("Dataset"),
	standard            = _("Standard");
}

local mimeTypes = {
    ["application/pdf"] = "pdf",
	["application/epub+zip"] = "epub",
    ["text/html"] = "html" ,
}

--[[
function itemInfo:init()
	print("InfoItem:init ", self.document)
    if self.document then -- only for Reader menu
        self.ui.menu:registerToMainMenu(self)
    end
end
--]]

function itemInfo:addToMainMenu(menu_items)
    menu_items.book_info = {
        text = self.title,
        callback = function()
            self:onShowItemInfo()
        end,
    }
end

-- Format creator list into string
function itemInfo.formatCreators(creators)
	if creators[1] ~= nil then 
		local authors = {}
		for _, v in ipairs(creators) do
			if v.creatorType == "author" then
				table.insert(authors, v.firstName.." "..v.lastName)
			end
		end
		return table.concat(authors, ", ")
	end
end

-- Format creator list into string
function itemInfo.formatTags(tagArray)
	if tagArray[1] ~= nil then 
		local tags = {}
		for _, v in ipairs(tagArray) do
			table.insert(tags, v.tag)
		end
		return table.concat(tags, ", ")
	end
end
		
-- Shows book information.
function itemInfo:show(itemDetails, attachment_callback)
	local itemData = itemDetails.data
	local attachments = itemDetails.attachments
    self.prop_updated = nil
    self.summary_updated = nil
    local kv_pairs = {}
--    print("In itemInfo :", itemData["title"])
--	print(#attachments, " attachments")

    local type = itemData.itemType
	if type then
		--print(type, itemTypeStrings[type])
		self.title = itemTypeStrings[type] or "Item information"
	end
    
    local key_text
    local values_lang, callback
    local sep = 0  -- Count separators
    for _i, prop_key in ipairs(self.props) do
        local prop = itemData[prop_key]
        if prop == nil or prop == "" then
            prop = nil
        elseif prop_key == "language" then
            -- Get a chance to have title, authors... rendered with alternate
            -- glyphs for the book language (e.g. japanese book in chinese UI)
            values_lang = prop
        elseif prop_key == "creators" then
            prop = self.formatCreators(prop)
        elseif prop_key == "tags" then
            prop = self.formatTags(prop)
--[[ Moved further down       
			elseif prop_key == "abstractNote" then
            -- Description may (often in EPUB, but not always) or may not (rarely in PDF) be HTML
            prop = util.htmlToPlainTextIfHtml(prop)
            callback = function() -- proper text_type in TextViewer
                self:showBookProp("abstractNote", prop)
            end
--]]
        end
        -- Only add keys if its value has been set
        if prop ~= nil then
			if prop_key == "tags" then
				-- Separator
				table.insert(kv_pairs, "--")
				sep = sep + 1
			end
			key_text = self.prop_text[prop_key]
			table.insert(kv_pairs, { key_text, prop,
				callback = callback
			})
		end
    end

	-- Abstract
	local abstract = itemData.abstractNote
	if abstract ~= "" then
		if sep == 0 then
			table.insert(kv_pairs, "--")
			sep = sep + 1
		end
		-- Description may (often in EPUB, but not always) or may not (rarely in PDF) be HTML
		abstract = util.htmlToPlainTextIfHtml(abstract)
		local callback = function() -- proper text_type in TextViewer
			self:showBookProp("abstractNote", abstract)
		end
		key_text = self.prop_text.abstractNote
		table.insert(kv_pairs, { key_text, abstract,
			callback = callback, separator = true
		})
    else
		-- Separator
		table.insert(kv_pairs, "--")
	end
	
	-- Attachments
	if #attachments > 0 then
		table.insert(kv_pairs, { "Attachents:", "...tap to open..."	})
		local cb 
		for i, v in ipairs(attachments) do
			key_text = "["..i.."] ("..mimeTypes[v.contentType].."):"
			if attachment_callback then
				cb = function() attachment_callback(v.key) end
			else
				print("No cb supplied?")
				cb = nil
			end
			local vtext
			if 	v.syncedVersion == v.version then
				vtext = "✓ "..v.title
			else
				vtext = v.title
			end
			table.insert(kv_pairs, { key_text, vtext, callback = cb	})
		end
	end


    local KeyValuePage = require("ui/widget/keyvaluepage")
    self.kvp_widget = KeyValuePage:new{
        title = self.title,
        value_overflow_align = "right",
        kv_pairs = kv_pairs,
        values_lang = values_lang,
        single_page = true,
    }
    UIManager:show(self.kvp_widget)
end

function itemInfo.getCustomProp(prop_key, filepath)
    local custom_metadata_file = DocSettings:findCustomMetadataFile(filepath)
    return custom_metadata_file
        and DocSettings.openSettingsFile(custom_metadata_file):readSetting("custom_props")[prop_key]
end

-- Returns extended and customized metadata.
function itemInfo.extendProps(original_props, filepath)
    -- do not customize if filepath is not passed (eg from covermenu)
    local custom_metadata_file = filepath and DocSettings:findCustomMetadataFile(filepath)
    local custom_props = custom_metadata_file
        and DocSettings.openSettingsFile(custom_metadata_file):readSetting("custom_props") or {}
    original_props = original_props or {}

    local props = {}
    for _, prop_key in ipairs(itemInfo.props) do
        props[prop_key] = custom_props[prop_key] or original_props[prop_key]
    end
    props.pages = original_props.pages
    -- if original title is empty, generate it as filename without extension
    props.display_title = props.title or filemanagerutil.splitFileNameType(filepath)
    return props
end

-- Returns customized document metadata, including number of pages.
function itemInfo.getDocProps(file, book_props, no_open_document)
    if DocSettings:hasSidecarFile(file) then
        local doc_settings = DocSettings:open(file)
        if not book_props then
            -- Files opened after 20170701 have a "doc_props" setting with
            -- complete metadata and "doc_pages" with accurate nb of pages
            book_props = doc_settings:readSetting("doc_props")
        end
        if not book_props then
            -- File last opened before 20170701 may have a "stats" setting.
            -- with partial metadata, or empty metadata if statistics plugin
            -- was not enabled when book was read (we can guess that from
            -- the fact that stats.page = 0)
            local stats = doc_settings:readSetting("stats")
            if stats and stats.pages ~= 0 then
                -- title, authors, series, series_index, language
                book_props = Document:getProps(stats)
            end
        end
        -- Files opened after 20170701 have an accurate "doc_pages" setting.
        local doc_pages = doc_settings:readSetting("doc_pages")
        if doc_pages and book_props then
            book_props.pages = doc_pages
        end
    end

    -- If still no book_props (book never opened or empty "stats"),
    -- but custom metadata exists, it has a copy of original doc_props
    if not book_props then
        local custom_metadata_file = DocSettings:findCustomMetadataFile(file)
        if custom_metadata_file then
            book_props = DocSettings.openSettingsFile(custom_metadata_file):readSetting("doc_props")
        end
    end

    -- If still no book_props, open the document to get them
    if not book_props and not no_open_document then
        local document = DocumentRegistry:openDocument(file)
        if document then
            local loaded = true
            local pages
            if document.loadDocument then -- CreDocument
                if not document:loadDocument(false) then -- load only metadata
                    -- failed loading, calling other methods would segfault
                    loaded = false
                end
                -- For CreDocument, we would need to call document:render()
                -- to get nb of pages, but the nb obtained by simply calling
                -- here document:getPageCount() is wrong, often 2 to 3 times
                -- the nb of pages we see when opening the document (may be
                -- some other cre settings should be applied before calling
                -- render() ?)
            else
                -- for all others than crengine, we seem to get an accurate nb of pages
                pages = document:getPageCount()
            end
            if loaded then
                book_props = document:getProps()
                book_props.pages = pages
            end
            document:close()
        end
    end

    return itemInfo.extendProps(book_props, file)
end

function itemInfo:findInProps(book_props, search_string, case_sensitive)
    for _, key in ipairs(self.props) do
        local prop = book_props[key]
        if prop then
            if key == "series_index" then
                prop = tostring(prop)
            elseif key == "description" then
                prop = util.htmlToPlainTextIfHtml(prop)
            end
            if util.stringSearch(prop, search_string, case_sensitive) ~= 0 then
                return true
            end
        end
    end
end

-- Shows book information for currently opened document.
function itemInfo:onShowItemInfo()
    if self.document then
        self.ui.doc_props.pages = self.ui.doc_settings:readSetting("doc_pages")
        self:show(self.ui.doc_settings, self.ui.doc_props)
    end
end

function itemInfo:showBookProp(prop_key, prop_text)
    UIManager:show(TextViewer:new{
        title = self.prop_text[prop_key],
        text = prop_text,
        text_type = prop_key == "description" and "book_info" or nil,
    })
end

function itemInfo:onShowBookDescription(description, file)
    if not description then
        if file then
            description = itemInfo.getDocProps(file).description
        elseif self.document then -- currently opened document
            description = self.ui.doc_props.description
        end
    end
    if description then
        self:showBookProp("description", util.htmlToPlainTextIfHtml(description))
    else
        UIManager:show(InfoMessage:new{
            text = _("No book description available."),
        })
    end
end

function itemInfo:onShowBookCover(file, force_orig)
    local cover_bb = self:getCoverImage(self.document, file, force_orig)
    if cover_bb then
        local ImageViewer = require("ui/widget/imageviewer")
        local imgviewer = ImageViewer:new{
            image = cover_bb,
            with_title_bar = false,
            fullscreen = true,
        }
        UIManager:show(imgviewer)
    else
        UIManager:show(InfoMessage:new{
            text = _("No cover image available."),
        })
    end
end

function itemInfo:getCoverImage(document, file, force_orig)
    local curr_file = document and document.file
    local cover_bb
    -- check for a custom cover (orig cover is forcibly requested in "Book information" only)
    if not force_orig then
        local custom_cover = DocSettings:findCustomCoverFile(file or curr_file)
        if custom_cover then
            local cover_doc = DocumentRegistry:openDocument(custom_cover)
            if cover_doc then
                cover_bb = cover_doc:getCoverPageImage()
                cover_doc:close()
                return cover_bb, custom_cover
            end
        end
    end
    -- orig cover
    local doc
    local do_open = file ~= nil and file ~= curr_file
    if do_open then
        doc = DocumentRegistry:openDocument(file)
        if doc and doc.loadDocument then -- CreDocument
            doc:loadDocument(false) -- load only metadata
        end
    else
        doc = document
    end
    if doc then
        cover_bb = doc:getCoverPageImage()
        if do_open then
            doc:close()
        end
    end
    return cover_bb
end

function itemInfo:updateitemInfo(file, book_props, prop_updated, prop_value_old)
    if self.document and prop_updated == "cover" then
        self.ui.doc_settings:getCustomCoverFile(true) -- reset cover file cache
    end
    self.prop_updated = {
        filepath = file,
        doc_props = book_props,
        metadata_key_updated = prop_updated,
        metadata_value_old = prop_value_old,
    }
    self.kvp_widget:onClose()
    self:show(file, book_props)
end

function itemInfo:setCustomCover(file, book_props)
    if self.custom_book_cover then -- reset custom cover
        if os.remove(self.custom_book_cover) then
            DocSettings.removeSidecarDir(util.splitFilePathName(self.custom_book_cover))
            self:updateitemInfo(file, book_props, "cover")
        end
    else -- choose an image and set custom cover
        local PathChooser = require("ui/widget/pathchooser")
        local path_chooser = PathChooser:new{
            select_directory = false,
            file_filter = function(filename)
                return DocumentRegistry:isImageFile(filename)
            end,
            onConfirm = function(image_file)
                if DocSettings:flushCustomCover(file, image_file) then
                    self:updateitemInfo(file, book_props, "cover")
                end
            end,
        }
        UIManager:show(path_chooser)
    end
end

function itemInfo:setCustomCoverFromImage(file, image_file)
    local custom_book_cover = DocSettings:findCustomCoverFile(file)
    if custom_book_cover then
        os.remove(custom_book_cover)
    end
    DocSettings:flushCustomCover(file, image_file)
    if self.ui.doc_settings then
        self.ui.doc_settings:getCustomCoverFile(true) -- reset cover file cache
    end
    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file))
    UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
end

function itemInfo:setCustomMetadata(file, book_props, prop_key, prop_value)
    -- in file
    local custom_doc_settings, custom_props, display_title, no_custom_metadata
    if self.custom_doc_settings then
        custom_doc_settings = self.custom_doc_settings
    else -- no custom metadata file, create new
        custom_doc_settings = DocSettings.openSettingsFile()
        display_title = book_props.display_title -- backup
        book_props.display_title = nil
        custom_doc_settings:saveSetting("doc_props", book_props) -- save a copy of original props
    end
    custom_props = custom_doc_settings:readSetting("custom_props", {})
    local prop_value_old = custom_props[prop_key] or book_props[prop_key]
    custom_props[prop_key] = prop_value -- nil when resetting a custom prop
    if next(custom_props) == nil then -- no more custom metadata
        os.remove(custom_doc_settings.sidecar_file)
        DocSettings.removeSidecarDir(util.splitFilePathName(custom_doc_settings.sidecar_file))
        no_custom_metadata = true
    else
        if book_props.pages then -- keep a copy of original 'pages' up to date
            local original_props = custom_doc_settings:readSetting("doc_props")
            original_props.pages = book_props.pages
        end
        custom_doc_settings:flushCustomMetadata(file)
    end
    book_props.display_title = book_props.display_title or display_title -- restore
    -- in memory
    prop_value = prop_value or custom_doc_settings:readSetting("doc_props")[prop_key] -- set custom or restore original
    book_props[prop_key] = prop_value
    if prop_key == "title" then -- generate when resetting the customized title and original is empty
        book_props.display_title = book_props.title or filemanagerutil.splitFileNameType(file)
    end
    if self.is_current_doc then
        self.ui.doc_props[prop_key] = prop_value
        if prop_key == "title" then
            self.ui.doc_props.display_title = book_props.display_title
        end
        if no_custom_metadata then
            self.ui.doc_settings:getCustomMetadataFile(true) -- reset metadata file cache
        end
    end
    self:updateitemInfo(file, book_props, prop_key, prop_value_old)
end

function itemInfo:showCustomEditDialog(file, book_props, prop_key)
    local prop = book_props[prop_key]
    if prop and prop_key == "description" then
        prop = util.htmlToPlainTextIfHtml(prop)
    end
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Edit book metadata:") .. " " .. self.prop_text[prop_key]:gsub(":", ""),
        input = prop,
        input_type = prop_key == "series_index" and "number",
        allow_newline = prop_key == "authors" or prop_key == "keywords" or prop_key == "description",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local prop_value = input_dialog:getInputValue()
                        if prop_value and prop_value ~= "" then
                            UIManager:close(input_dialog)
                            self:setCustomMetadata(file, book_props, prop_key, prop_value)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function itemInfo:showCustomDialog(file, book_props, prop_key)
    local original_prop, custom_prop, prop_is_cover
    if prop_key then -- metadata
        if self.custom_doc_settings then
            original_prop = self.custom_doc_settings:readSetting("doc_props")[prop_key]
            custom_prop = self.custom_doc_settings:readSetting("custom_props")[prop_key]
        else
            original_prop = book_props[prop_key]
        end
        if original_prop and prop_key == "description" then
            original_prop = util.htmlToPlainTextIfHtml(original_prop)
        end
        prop_is_cover = false
    else -- cover
        prop_key = "cover"
        prop_is_cover = true
    end

    local button_dialog
    local buttons = {
        {
            {
                text = _("Copy original"),
                enabled = original_prop ~= nil and Device:hasClipboard(),
                callback = function()
                    UIManager:close(button_dialog)
                    Device.input.setClipboardText(original_prop)
                end,
            },
            {
                text = _("View original"),
                enabled = original_prop ~= nil or prop_is_cover,
                callback = function()
                    if prop_is_cover then
                        self:onShowBookCover(file, true)
                    else
                        self:showBookProp(prop_key, original_prop)
                    end
                end,
            },
        },
        {
            {
                text = _("Reset custom"),
                enabled = custom_prop ~= nil or (prop_is_cover and self.custom_book_cover ~= nil),
                callback = function()
                    local confirm_box = ConfirmBox:new{
                        text = prop_is_cover and _("Reset custom cover?\nImage file will be deleted.")
                                              or _("Reset custom book metadata field?"),
                        ok_text = _("Reset"),
                        ok_callback = function()
                            UIManager:close(button_dialog)
                            if prop_is_cover then
                                self:setCustomCover(file, book_props)
                            else
                                self:setCustomMetadata(file, book_props, prop_key)
                            end
                        end,
                    }
                    UIManager:show(confirm_box)
                end,
            },
            {
                text = _("Set custom"),
                enabled = not prop_is_cover or (prop_is_cover and self.custom_book_cover == nil),
                callback = function()
                    UIManager:close(button_dialog)
                    if prop_is_cover then
                        self:setCustomCover(file, book_props)
                    else
                        self:showCustomEditDialog(file, book_props, prop_key)
                    end
                end,
            },
        },
    }
    button_dialog = ButtonDialog:new{
        title = _("Book metadata:") .. " " .. self.prop_text[prop_key]:gsub(":", ""),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(button_dialog)
end


return itemInfo
