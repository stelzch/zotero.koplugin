--[[
This module provides a way to display item information (adapted from apps/filemanager/filemanagerbookinfo.lua)
--]]

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
		
-- Shows item information.
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
    local sep = 0  -- To count separators
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
        end
        -- Only add keys if its value has been set
        if prop ~= nil then
			if prop_key == "tags" then -- Add separator line after the bibliographical entries are complete
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

	-- Deal with abstract
	local abstract = itemData.abstractNote
	if abstract ~= "" then
		if sep == 0 then
			table.insert(kv_pairs, "--")
			sep = sep + 1
		end
		-- Description may (often in EPUB, but not always) or may not (rarely in PDF) be HTML
		-- not sure if this applies to Zotero abstracts; but leave it for now...
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


function itemInfo:showBookProp(prop_key, prop_text)
    UIManager:show(TextViewer:new{
        title = self.prop_text[prop_key],
        text = prop_text,
        text_type = prop_key == "description" and "book_info" or nil,
    })
end


return itemInfo
