local Annotations = {}
local DocSettings = require("docsettings")
local JSON = require("json")
local logger = require("logger")

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
    ["red"] = "#ff6666",
    ["orange"] = "#f19837",
    ["yellow"] = "#ffd400",
    ["green"] = "#5fb236",
    ["olive"] = "#88ff77",
    ["cyan"] = "#00ffee",
    ["blue"] = "#0066FF",
    ["purple"] = "#a28ae5",
    ["gray"] = "#aaaaaa",
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
    local fac = 10 ^ num_places
    return math.floor(x * fac) / fac
end

function Annotations.setDefaultColor(ZColor)
    defaultZColor = K2Z_COLORS[ZColor] or defaultZColor
end

-- Get BBOX dimensions for specified pages
-- Returns a table with page numbers as keys, containing:
--   width, height (full page dimensions)
--   bbox_x0, bbox_y0, bbox_x1, bbox_y1 (usedBBox coordinates)
--   bbox_width, bbox_height (calculated from bbox)
-- TODO: Simplify this function and remove extensive logging after testing for a while
function Annotations.getPageDimensions(file, pages)
    if pages == nil or type(pages) ~= "table" then
        logger.warn("Annotations.getPageDimensions: pages parameter is nil or invalid")
        return {}
    end

    logger.info("Annotations.getPageDimensions: Getting BBOX data for file: " .. file)
    logger.info("Annotations.getPageDimensions: Pages requested: " .. JSON.encode(pages))

    local result = {}

    -- Use DocumentRegistry to get usedBBox which is the actual content area
    local DocumentRegistry = require("document/documentregistry")
    local doc = DocumentRegistry:openDocument(file)

    if doc == nil then
        logger.err("Annotations.getPageDimensions: Could not open document: " .. file)
        return nil
    end

    for pageno, _ in pairs(pages) do
        logger.info("Annotations.getPageDimensions: Processing page " .. pageno)

        -- Get native page dimensions
        local page_dims = doc:getNativePageDimensions(pageno)
        if page_dims == nil then
            logger.err("Annotations.getPageDimensions: Could not get dimensions for page " .. pageno)
            doc:close()
            return nil
        end

        -- Get usedBBox for this specific page
        local bbox = doc:getUsedBBox(pageno)
        if bbox == nil then
            logger.warn("Annotations.getPageDimensions: Could not get usedBBox for page " ..
                pageno .. ", using full page")
            bbox = { x0 = 0, y0 = 0, x1 = page_dims.w, y1 = page_dims.h }
        end

        -- TODO: To remove after testing
        local bbox_width = bbox.x1 - bbox.x0
        local bbox_height = bbox.y1 - bbox.y0

        result[pageno] = {
            width = page_dims.w,
            height = page_dims.h,
            -- TODO: To remove after testing
            bbox_x0 = bbox.x0,
            bbox_y0 = bbox.y0,
            bbox_x1 = bbox.x1,
            bbox_y1 = bbox.y1,
            bbox_width = bbox_width,
            bbox_height = bbox_height,
        }

        logger.info(string.format(
            "Annotations.getPageDimensions: Page %d - Full: %.2fx%.2f, BBox: [%.2f,%.2f,%.2f,%.2f], BBox Size: %.2fx%.2f",
            pageno, page_dims.w, page_dims.h,
            bbox.x0, bbox.y0, bbox.x1, bbox.y1,
            bbox_width, bbox_height
        ))
    end

    doc:close()
    logger.info("Annotations.getPageDimensions: Completed, returning data for " .. table.getn(result) .. " pages")

    return result
end

-- Output the timezone-agnostic timestamp, since KOReader uses timestamps with
-- local time.
function Annotations.utcFromLocal(timestamp)
    local year, month, day, hour, minute, second =
        string.match(timestamp, "(%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)")
    local time = {
        ["year"] = year,
        ["month"] = month,
        ["day"] = day,
        ["hour"] = hour,
        ["min"] = minute,
        ["sec"] = second,
    }

    return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time(time))
end

function Annotations.localFromUtc(utc_timestamp)
    local year, month, day, hour, minute, second =
        string.match(utc_timestamp, "(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z")
    local time = {
        ["year"] = year,
        ["month"] = month,
        ["day"] = day,
        ["hour"] = hour,
        ["min"] = minute,
        ["sec"] = second,
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

function Annotations.annotationTypeKOReaderToZotero(type)
    return K2Z_STYLE[string.lower(type)]
end

-- Generate a annotationSortIndex based on page, offset and miny
function Annotations.makeSortIndex(page, offset, miny)
    local zoteroSortIndex = string.format("%05d|%06d|%05d", page - 1, offset, math.max(0, math.floor(miny)))
    return zoteroSortIndex
end

-- Convert KOReader annotation to Zotero format
-- page_bbox: table with bbox info for this specific page (from getPageDimensions)
function Annotations.convertKOReaderToZotero(annotation, page_bbox, parent_key)
    logger.info("=== SENDING ANNOTATION TO ZOTERO ===")
    logger.info("Local KOReader annotation data:")
    logger.info("  Page number: " .. (annotation.pageno or annotation.page or "nil"))
    logger.info("  Drawer type: " .. (annotation.drawer or "nil"))
    logger.info("  Color: " .. (annotation.color or "nil"))
    logger.info("  Text: " .. (annotation.text or ""))
    logger.info("  Note: " .. (annotation.note or ""))
    logger.info("  DateTime: " .. (annotation.datetime or "nil"))
    logger.info("  Number of pboxes: " .. #annotation.pboxes)

    local date = Annotations.utcFromLocal(annotation.datetime)
    local color = defaultZColor
    if annotation.color ~= nil then
        color = K2Z_COLORS[string.lower(annotation.color)] or K2Z_COLORS["yellow"]
    end
    local type = Annotations.annotationTypeKOReaderToZotero(annotation.drawer)

    -- Extract BBOX dimensions for coordinate conversion
    local page_height = page_bbox.height

    logger.info("")
    logger.info("Conversion parameters:")
    logger.info("  Page dimensions: " .. string.format("%.2fx%.2f", page_bbox.width, page_bbox.height))
    logger.info("  BBOX coordinates: " ..
        string.format("[%.2f x0, %.2f y0, %.2f x1, %.2f y1]", page_bbox.bbox_x0, page_bbox.bbox_y0, page_bbox.bbox_x1,
            page_bbox.bbox_y1))
    logger.info("  BBOX dimensions: " .. string.format("%.2fx%.2f", page_bbox.bbox_width, page_height))
    logger.info("  Using Page height for conversion: " .. page_height)
    logger.info("  Parent key: " .. parent_key)
    logger.info("  Decimal precision: 2 digits")

    logger.info("")
    logger.info("Field mappings:")
    logger.info("  DateTime: '" .. annotation.datetime .. "' -> '" .. date .. "'")
    logger.info("  Color: '" .. (annotation.color or "default") .. "' -> '" .. color .. "'")
    logger.info("  Type: '" .. annotation.drawer .. "' -> '" .. (type or "nil") .. "'")

    local rects = {}

    -- Coordinate systems of KOReader and Zotero are flipped. On KOReader, the
    -- y-axis extends towards the bottom whereas on Zotero the y-axis extends
    -- towards the top.
    -- Therefore, we need to transform coordinates before uploading them to Zotero
    local digits = 2
    local miny = page_height

    logger.info("")
    logger.info("Rectangle conversion (KOReader coordinates -> Zotero coordinates):")
    logger.info("  Using Page height " .. page_height .. " for Y-axis flip")
    for idx, pbox in ipairs(annotation.pboxes) do
        local x1 = pbox.x
        local x2 = pbox.x + pbox.w
        local y1 = page_height - pbox.y - pbox.h
        local y2 = y1 + pbox.h

        logger.info(string.format("  Rect %d:", idx))
        logger.info(string.format("    KOReader: {x=%.2f, y=%.2f, w=%.2f, h=%.2f}", pbox.x, pbox.y, pbox.w, pbox.h))
        logger.info(
            string.format(
                "    Math: x1=%.2f, y1=%.2f-%.2f-%.2f=%.2f, x2=%.2f+%.2f=%.2f, y2=%.2f+%.2f=%.2f",
                x1,
                page_height,
                pbox.y,
                pbox.h,
                y1,
                pbox.x,
                pbox.w,
                x2,
                y1,
                pbox.h,
                y2
            )
        )
        logger.info(
            string.format(
                "    Zotero (limited): [%.2f, %.2f, %.2f, %.2f] (x1, y1, x2, y2)",
                limitDigits(x1, digits),
                limitDigits(y1, digits),
                limitDigits(x2, digits),
                limitDigits(y2, digits)
            )
        )

        table.insert(
            rects,
            { limitDigits(x1, digits), limitDigits(y1, digits), limitDigits(x2, digits), limitDigits(y2, digits) }
        )
        if pbox.y < miny then
            miny = pbox.y
        end
    end

    -- make 'fake' sort key
    -- middle parameter should be offset (number of characters on page before the highlighted text?)
    -- we don't know this
    local zoteroSortIndex = Annotations.makeSortIndex(annotation.pageno, 0, miny)

    logger.info("")
    logger.info("Sort index calculation:")
    logger.info(
        string.format("  makeSortIndex(page=%d, offset=0, miny=%.2f) -> '%s'", annotation.pageno, miny, zoteroSortIndex)
    )

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
        ["dateModified"] = date,
    }

    if annotation.note then
        ZAnnotation["annotationComment"] = annotation.note
    end
    if annotation.text then
        ZAnnotation["annotationText"] = annotation.text
    end

    logger.info("")
    logger.info("Final Zotero annotation package:")
    logger.info(JSON.encode(ZAnnotation))
    logger.info("=== END CREATING ANNOTATION FOR ZOTERO ===")
    logger.info("")

    return ZAnnotation
end

-- Convert a Zotero annotation item to a KOReader annotation
-- NOTE: currently only works with text highlights and annotations.
-- page_bbox: table with bbox info for this specific page (from getPageDimensions)
function Annotations.convertZoteroToKOReader(annotation, page_bbox)
    logger.info("=== CONVERTING ANNOTATION FROM ZOTERO ===")
    logger.info("Raw Zotero annotation data:")
    logger.info("  Key: " .. (annotation.key or "nil"))
    logger.info("  Version: " .. (annotation.version or "nil"))
    logger.info("  Annotation Type: " .. (annotation.data.annotationType or "nil"))
    logger.info("  Annotation Color: " .. (annotation.data.annotationColor or "nil"))
    logger.info("  Annotation Text: " .. (annotation.data.annotationText or "nil"))
    logger.info("  Annotation Comment: " .. (annotation.data.annotationComment or ""))
    logger.info("  Date Modified: " .. (annotation.data.dateModified or "nil"))
    logger.info("  Sort Index: " .. (annotation.data.annotationSortIndex or "nil"))
    logger.info("  Annotation Position JSON: " .. (annotation.data.annotationPosition or "nil"))

    local pos = JSON.decode(annotation.data.annotationPosition)
    local page = pos.pageIndex + 1

    -- Extract BBOX dimensions for coordinate conversion TODO: Make it so it just uses the height as its the key metric
    -- local page_height = page_bbox.bbox_height or page_bbox.height
    local page_height = page_bbox.height

    logger.info("")
    logger.info("Conversion parameters:")
    logger.info("  Page dimensions: " .. string.format("%.2fx%.2f", page_bbox.width, page_bbox.height))
    logger.info("  BBOX coordinates: " ..
        string.format("[x0: %.2f, y0: %.2f, x1: %.2f, y1: %.2f]", page_bbox.bbox_x0, page_bbox.bbox_y0, page_bbox
            .bbox_x1,
            page_bbox.bbox_y1))
    logger.info("  BBOX dimensions: " .. string.format("%.2fx%.2f", page_bbox.bbox_width, page_height))
    logger.info("  Using Page Height height for conversion: " .. page_height)
    logger.info("  Page index (Zotero): " .. pos.pageIndex .. " -> Page number (KOReader): " .. page)
    logger.info("  Number of rectangles: " .. #pos.rects)

    local rects = {}
    logger.info("")
    logger.info("Rectangle conversion (Zotero coordinates -> KOReader coordinates):")
    logger.info("  Using Page height " .. page_height .. " for Y-axis flip")
    for k, bbox in ipairs(pos.rects) do
        local x1 = bbox[1]
        local y1_zotero = bbox[2]
        local x2 = bbox[3]
        local y2_zotero = bbox[4]

        -- Convert from Zotero coordinate system to KOReader
        local x_koreader = x1
        local h_koreader = y2_zotero - y1_zotero
        local y_koreader = page_height - y1_zotero - h_koreader
        local w_koreader = x2 - x1

        logger.info(string.format("  Rect %d:", k))
        logger.info(
            string.format("    Zotero: [%.2f, %.2f, %.2f, %.2f] (x1, y1, x2, y2)", x1, y1_zotero, x2, y2_zotero)
        )
        logger.info(
            string.format(
                "    Math: x=%.2f, y=%.2f-%.2f=%.2f, w=%.2f-%.2f=%.2f, h=%.2f-%.2f=%.2f",
                x1,
                page_height,
                y2_zotero,
                y_koreader,
                x2,
                x1,
                w_koreader,
                y2_zotero,
                y1_zotero,
                h_koreader
            )
        )
        logger.info(
            string.format(
                "    KOReader: {x=%.2f, y=%.2f, w=%.2f, h=%.2f}",
                x_koreader,
                y_koreader,
                w_koreader,
                h_koreader
            )
        )

        table.insert(rects, {
            ["x"] = x_koreader,
            ["y"] = y_koreader,
            ["w"] = w_koreader,
            ["h"] = h_koreader,
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

    logger.info("")
    logger.info("Position markers (with shift=" .. shift .. "):")
    logger.info(string.format("  pos0: {page=%d, x=%.2f, y=%.2f} (first rect + shift)", pos0.page, pos0.x, pos0.y))
    logger.info(string.format("  pos1: {page=%d, x=%.2f, y=%.2f} (last rect + shift)", pos1.page, pos1.x, pos1.y))

    -- Convert Zotero time stamp to the format used by KOReader
    -- e.g. "2024-09-24T18:13:49Z" to "2024-09-24 18:13:49"
    local color_mapped = Z2K_COLORS[annotation.data.annotationColor] or defaultKColor
    local drawer_mapped = Z2K_STYLE[annotation.data.annotationType] or "lighten"
    local datetime_converted = string.sub(string.gsub(annotation.data.dateModified, "T", " "), 1, -2)

    logger.info("")
    logger.info("Field mappings:")
    logger.info("  Color: '" .. annotation.data.annotationColor .. "' -> '" .. color_mapped .. "'")
    logger.info("  Type: '" .. annotation.data.annotationType .. "' -> '" .. drawer_mapped .. "'")
    logger.info("  DateTime: '" .. annotation.data.dateModified .. "' -> '" .. datetime_converted .. "'")

    local koAnnotation = {
        ["color"] = color_mapped,
        ["datetime"] = datetime_converted,
        ["drawer"] = drawer_mapped,
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
    if annotation.data.annotationComment ~= "" then
        koAnnotation["note"] = annotation.data.annotationComment
    end

    logger.info("")
    logger.info("Final KOReader annotation:")
    logger.info(JSON.encode(koAnnotation))
    logger.info("=== END RECEIVING ANNOTATION ===")
    logger.info("")

    return koAnnotation
end

-- Create annotations for a single document using creation_callback.
-- returns number of items it FAILED to sync (and error if applicable)
function Annotations.createAnnotations(file_path, key, creation_callback)
    logger.info("Annotations.createAnnotations: Starting for file: " .. file_path)
    local doc_settings = DocSettings:open(file_path)
    if
        doc_settings.data == nil
        or doc_settings.data["annotations"] == nil
        or #doc_settings.data["annotations"] == 0
    then
        logger.info("Annotations.createAnnotations: No annotations to create")
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
    for i = 1, #k_annotations do
        local pageno = k_annotations[i].pageno or
            k_annotations[i]
            .page -- not sure what is the difference between page and pageno
        pages[pageno] = true
    end

    logger.info("Annotations.createAnnotations: Getting BBOX dimensions for pages: " .. JSON.encode(pages))
    local page_dimensions = Annotations.getPageDimensions(file_path, pages)

    if page_dimensions == nil then
        logger.err(
            ("Zotero: Skipping '%s' because page dimensions can not be determined. relevant pages where %s"):format(
                file_path,
                JSON.encode(pages)
            )
        )
        return nil
    end

    logger.info("Annotations.createAnnotations: Processing " .. #k_annotations .. " annotations")
    for i = 1, #k_annotations do
        if (k_annotations[i].zoteroKey == nil) and (k_annotations[i].drawer ~= nil) then
            -- at some point should figure out what to do with annotations where k_annotations[i].drawer == 0
            local pageno = k_annotations[i].pageno
            local page_bbox = page_dimensions[pageno]
            if page_bbox == nil then
                logger.err("Annotations.createAnnotations: No BBOX data for page " .. pageno .. ", skipping annotation")
            else
                logger.info("Annotations.createAnnotations: Converting annotation " .. i .. " on page " .. pageno)
                local a = Annotations.convertKOReaderToZotero(k_annotations[i], page_bbox, key)
                table.insert(z_annotations, a)
                index_map[#z_annotations] = i -- keep track of index
            end
        end
    end

    if #z_annotations == 0 then
        logger.info("Annotations.createAnnotations: No new annotations to create")
        return 0, nil
    end
    logger.dbg(("Zotero: creating annotations for %s:\n%s"):format(file_path, JSON.encode(z_annotations)))
    local created_items, e = creation_callback(z_annotations)

    if created_items == nil then
        logger.err("Annotations.createAnnotations: Failed to create annotations: " .. tostring(e))
        logger.err(e)
        return #z_annotations, e
    end

    local cnt = 0
    for k, v in pairs(created_items) do
        if v.key ~= nil then
            local k_index = index_map[k]
            assert(k_index ~= nil)
            k_annotations[k_index].zoteroKey = v.key
            k_annotations[k_index].zoteroVersion = v.version
            cnt = cnt + 1
            logger.info("Zotero: New Zotero annotation created: ", JSON.encode(v))
        end
    end

    if cnt > 0 then
        doc_settings:flush()
        logger.info("Annotations.createAnnotations: Successfully created " .. cnt .. " annotations")
    end

    return #z_annotations - cnt, nil
end

return Annotations
