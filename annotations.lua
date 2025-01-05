local Annotations = {}
local mupdf = require("ffi/mupdf")
local DrawContext = require("ffi/drawcontext")
local BlitBuffer = require("ffi/blitbuffer")
local DocSettings = require("docsettings")
local JSON = require("json")
local logger = require('logger')

local Z2K_COLORS = {
["#ffd400"] = "yellow",
["#ff6666"] = "red",
["#5fb236"] = "green",
["#2ea8e5"] = "blue",
["#a28ae5"] = "purple",
["#e56eee"] = "red", -- this would be magenta, but that is not in KOreaders palette
["#f19837"] = "orange",
["#aaaaaa"] = "gray",
}

local K2Z_COLORS = {
    ["red"]    = "#ff6666",
    ["orange"] = "#f19837",
    ["yellow"] = "#ffd400",
    ["green"]  = "#5fb236",
    ["olive"]  = "#88ff77",
    ["cyan"]   = "#00ffee",
    ["blue"]   = "#0066FF",
    ["purple"] = "#a28ae5",
    ["gray"]   = "#aaaaaa",
}

local K2Z_STYLE = {
    ["underscore"] = "underline",
    ["lighten"] = "highlight",
    ["strikeout"] = "highlight",
    ["invert"] = "highlight",
}

local Z2K_STYLE = {
    ["underline"] = "underscore",
    ["highlight"] = "lighten",
}


local defaultKColor = "yellow"
local defaultZColor = K2Z_COLORS["gray"]

local function limitDigits(x, num_places)
    local fac = 10^num_places
    return math.floor(x * fac) / fac
end

function Annotations.setDefaultColor(ZColor)
	defaultZColor = K2Z_COLORS[ZColor] or K2Z_COLORS["gray"]
end

function Annotations.getPageDimensions(file, pages)
    if pages == nil then
        return {}
    end

    local result = {}
    local dc = DrawContext.new()
    local document = mupdf.openDocument(file)

    if document == nil then
        return nil
    end

    for pageno,v in pairs(pages) do
        local page = document:openPage(pageno)

        if page == nil then
            document:close()
            return nil
        end
        result[pageno] = {page:getSize(dc)}

        page:close()
    end

    document:close()

    return result
end
--
-- Output the timezone-agnostic timestamp, since KOReader uses timestamps with
-- local time.
function Annotations.utcFromLocal(timestamp)
    local year, month, day, hour, minute, second = string.match(timestamp,
        "(%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)")
    local time = {
        ["year"] = year,
        ["month"] = month,
        ["day"] = day,
        ["hour"] = hour,
        ["min"] = minute,
        ["sec"] = second
    }

    return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time(time))
end

function Annotations.localFromUtc(utc_timestamp)
    local year, month, day, hour, minute, second = string.match(utc_timestamp,
        "(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z")
    local time = {
        ["year"] = year,
        ["month"] = month,
        ["day"] = day,
        ["hour"] = hour,
        ["min"] = minute,
        ["sec"] = second
    }

    return os.date("%Y-%m-%d %H:%M:%S", os.time(time))
end


function Annotations.supportedZoteroTypes()

	local types = {}
	for key, _ in pairs(Z2K_STYLE) do
		table.insert(types, key)
	end
	return types
end

function Annotations.colorZoteroToKOReader(hex_code)


end

function Annotations.colorKOReaderToZotero(color_name)
    return string.lower(BlitBuffer.HIGHLIGHT_COLORS[string.lower(color_name)])
end

function Annotations.annotationTypeKOReaderToZotero(type)
    return K2Z_STYLE[string.lower(type)]
end

-- Generate a annotationSortIndex based on page, offset and miny 
function Annotations.makeSortIndex(page, offset, miny)
	local zoteroSortIndex = string.format("%05d|%06d|%05d", page-1, offset, math.max(0, math.floor(miny)))
	return zoteroSortIndex
end

function Annotations.convertKOReaderToZotero(annotation, page_height, parent_key)
    local date = Annotations.utcFromLocal(annotation.datetime)
    local color = defaultZColor
    if annotation.color ~= nil then color = Annotations.colorKOReaderToZotero(annotation.color) end
    local type = Annotations.annotationTypeKOReaderToZotero(annotation.drawer)
    local rects = {}

    -- Coordinate systems of KOReader and Zotero are flipped. On KOReader, the
    -- y-axis extends towards the bottom whereas on Zotero the y-axis extends
    -- towards the bottom.
    -- Therefore, we need to transform coordinates before uploading them to Zotero
    local digits = 2
    local miny = page_height
    for _, pbox in ipairs(annotation.pboxes) do
        local x1 = pbox.x
        local y1 = page_height - pbox.y - pbox.h
        local x2 = pbox.x + pbox.w
        local y2 = y1 + pbox.h

        table.insert(rects, {limitDigits(x1,digits), limitDigits(y1,digits), limitDigits(x2,digits), limitDigits(y2,digits)})
		if pbox.y < miny then miny = pbox.y end
    end

	-- make 'fake' sort key
	-- middle parameter should be offset (number of characters on page before the highlighted text?)
	-- we don't know this
	local zoteroSortIndex = Annotations.makeSortIndex(annotation.pageno, 0, miny)
    
    local ZAnnotation = {
        ["itemType"] = "annotation",
        ["parentItem"] = parent_key,
        ["annotationType"] = type,
        ["annotationColor"] = color,
        ["annotationPageLabel"] = tostring(annotation.page),
        ["annotationSortIndex"] = zoteroSortIndex,
        ["annotationPosition"] = JSON.encode({
            ["pageIndex"] = annotation.pageno - 1,
            ["rects"] = rects,
        }),
        ["dateModified"] = date
    }                
	
	if annotation.note then ZAnnotation["annotationComment"] = annotation.note end
	if annotation.text then ZAnnotation["annotationText"] = annotation.text end
	
    return ZAnnotation
end

-- Convert a Zotero annotation item to a KOReader annotation
-- NOTE: currently only works with text highlights and annotations.
function Annotations.convertZoteroToKOReader(annotation, page_height)
    local pos = JSON.decode(annotation.data.annotationPosition)
    local page = pos.pageIndex + 1
    
    local rects = {}
    for k, bbox in ipairs(pos.rects) do
        table.insert(rects, {
            ["x"] = bbox[1],
            ["y"] = page_height - bbox[4],
            ["w"] = bbox[3] - bbox[1],
            ["h"] = bbox[4] - bbox[2],
        })
    end
    assert(#rects > 0)

    local shift = 1
    -- KOReader seems to find 'single word' text boxes which contain pos0 and pos1 to work out the boundaries of the highlight.
    -- If the positions are not inside any box it looks for the box which has its centre closest to the position. To avoid unexpected
    -- behaviour shift the positions slightly inside the first/last word box. Assumes top left to bottom right word arrangement...
    local pos0 = {
        ["page"] = page,
        ["rotation"] = 0,
        ["x"] = rects[1].x + shift,
        ["y"] = rects[1].y + shift,
    }
    -- Take last bounding box
    local pos1 = {
        ["page"] = page,
        ["rotation"] = 0,
        ["x"] = rects[#rects].x + rects[#rects].w - shift,
        ["y"] = rects[#rects].y + rects[#rects].h - shift,
    }
    -- Convert Zotero time stamp to the format used by KOReader
    -- e.g. "2024-09-24T18:13:49Z" to "2024-09-24 18:13:49"
    local koAnnotation = {
			["color"] = Z2K_COLORS[annotation.data.annotationColor] or defaultKColor,
            ["datetime"] = string.sub(string.gsub(annotation.data.dateModified, "T", " "), 1, -2), -- convert format
            ["drawer"] = Z2K_STYLE[annotation.data.annotationType] or "lighten",
            ["page"] = page,
            ["pboxes"] = rects,
            ["pos0"] = pos0,
            ["pos1"] = pos1,
            ["text"] = annotation.data.annotationText,
            ["zoteroKey"] = annotation.key,
            ["zoteroSortIndex"] = annotation.data.annotationSortIndex,
            ["zoteroVersion"] = annotation.version,
        }
    -- KOReader seems to use the presence of the "note" field to distinguish between "highlight" and "note"
    -- Important for how they get displayed in the bookmarks!
    if (annotation.data.annotationComment ~= "") then koAnnotation["note"] = annotation.data.annotationComment end

    return koAnnotation
end

-- Create annotations for a single document using creation_callback.
-- returns number of items it FAILED to sync (and error if applicable)
function Annotations.createAnnotations(file_path, key, creation_callback)
    local doc_settings = DocSettings:open(file_path)
    if doc_settings.data == nil
        or doc_settings.data["annotations"] == nil
        or #doc_settings.data["annotations"] == 0 then
        return
    end

    local k_annotations = doc_settings.data["annotations"]
    local z_annotations = {}
    local pages = {}

    -- the following associative array maps from indices of k_annotations to z_annotations.
    -- This is necessary because not all annotations necessitate a creation event, since some might
    -- have been created in a prevous sync.
    local index_map = {}

    -- gather page numbers beforehand so that we may determine page sizes in a
    -- single go
    for i=1,#k_annotations do
        local pageno = k_annotations[i].pageno or k_annotations[i].page  -- not sure what is the difference between page and pageno
        pages[pageno] = true
    end

    local page_dimensions = Annotations.getPageDimensions(file_path, pages)

    if page_dimensions == nil then
        logger.err(("Zotero: Skipping '%s' because page dimensions can not be determined. relevant pages where %s"):format(file_path, JSON.encode(pages)))
        return nil
    end

    for i = 1,#k_annotations do
        if (k_annotations[i].zoteroKey == nil) and (k_annotations[i].drawer ~= nil) then
            -- at some point should figure out what to do with annotations where k_annotations[i].drawer == 0
            local pageno = k_annotations[i].pageno
            local page_height = page_dimensions[pageno][2]
            local a = Annotations.convertKOReaderToZotero(k_annotations[i], page_height, key)
            table.insert(z_annotations, a)
            index_map[#z_annotations] = i -- keep track of index
        end
    end
	--print(JSON.encode(z_annotations))
    if #z_annotations == 0 then
        return 0, nil
    end
    logger.dbg(("Zotero: creating annotations for %s:\n%s"):format(file_path, JSON.encode(z_annotations)))
    local created_items, e = creation_callback(z_annotations)

    if created_items == nil then
        return #z_annotations, e
    end

	local cnt = 0
    for k,v in pairs(created_items) do
        if v.key ~= nil then
            local k_index = index_map[k]
            assert(k_index ~= nil)
            k_annotations[k_index].zoteroKey = v.key
            k_annotations[k_index].zoteroVersion = v.version
            cnt = cnt + 1
            logger.info("New Zotero annotation created: ", JSON.encode(v))
        end
    end

    if cnt > 0 then
        doc_settings:flush()
    end

    return #z_annotations-cnt, nil
end

return Annotations
