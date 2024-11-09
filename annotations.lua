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
    ["red"]    = "#FF3300",
    ["orange"] = "#FF8800",
    ["yellow"] = "#FFFF33",
    ["green"]  = "#00AA66",
    ["olive"]  = "#88FF77",
    ["cyan"]   = "#00FFEE",
    ["blue"]   = "#0066FF",
    ["purple"] = "#EE00FF",
    ["gray"] = "#aaaaaa",
}

local K2Z_STYLE = {
    ["underscore"] = "underline",
    ["lighten"] = "highlight",
    ["strikeout"] = "highlight",
    ["invert"] = "highlight",
}

local defaultColor = K2Z_COLORS["gray"]

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



function Annotations.colorZoteroToKOReader(hex_code)


end

function Annotations.colorKOReaderToZotero(color_name)
    return string.lower(BlitBuffer.HIGHLIGHT_COLORS[string.lower(color_name)])
end

function Annotations.annotationTypeKOReaderToZotero(type)
    return K2Z_STYLE[string.lower(type)]
end

function Annotations.convertKOReaderToZotero(annotation, page_height, parent_key)
    local date = Annotations.utcFromLocal(annotation.datetime)
    local color = defaultColor
    if annotation.color ~= nil then color = Annotations.colorKOReaderToZotero(annotation.color) end
    local type = Annotations.annotationTypeKOReaderToZotero(annotation.drawer)
    local rects = {}

    -- Coordinate systems of KOReader and Zotero are flipped. On KOReader, the
    -- y-axis extends towards the bottom whereas on Zotero the y-axis extends
    -- towards the bottom.
    -- Therefore, we need to transform coordinates before uploading them to Zotero
    for _, pbox in ipairs(annotation.pboxes) do
        local x1 = pbox.x
        local y1 = page_height - pbox.y - pbox.h
        local x2 = pbox.x + pbox.w
        local y2 = y1 + pbox.h

        table.insert(rects, {x1, y1, x2, y2})
    end


    return {
        ["itemType"] = "annotation",
        ["parentItem"] = parent_key,
        ["annotationType"] = type,
        ["annotationComment"] = annotation.note or "",
        ["annotationText"] = annotation.text or "",
        ["annotationColor"] = color,
        ["annotationPageLabel"] = tostring(annotation.page),
        ["annotationSortIndex"] = "00000|000000|00000",
        ["annotationPosition"] = JSON.encode({
            ["pageIndex"] = annotation.pageno - 1,
            ["rects"] = rects,
        }),
--        ["tags"] = {},
        ["dateAdded"] = date,
        ["dateModified"] = date
    }

end


-- Create annotations for a single document using creation_callback.
function Annotations.createAnnotations(file_path, key, creation_callback)
    local doc_settings = DocSettings:open(file_path)
    if doc_settings.data == nil
        or doc_settings.data["annotations"] == nil
        or #doc_settings.data["annotations"] == 0 then
        return
    end

    local k_annotations_modified = false
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
        if k_annotations[i].zoteroKey == nil then
            local pageno = k_annotations[i].pageno
            local page_height = page_dimensions[pageno][2]
            local a = Annotations.convertKOReaderToZotero(k_annotations[i], page_height, key)
            table.insert(z_annotations, a)
            index_map[#z_annotations] = i -- keep track of index
        end
    end

    if #z_annotations == 0 then
        return nil, nil
    end
    logger.dbg(("Zotero: creating annotations for %s:\n%s"):format(file_path, JSON.encode(z_annotations)))
    local created_items, e = creation_callback(z_annotations)

    if created_items == nil then
        return nil, e
    end

    for k,v in pairs(created_items) do
        if v.key ~= nil then
            local k_index = index_map[k]
            assert(k_index ~= nil)
            k_annotations[k_index].zoteroKey = v.key
            k_annotations[k_index].zoteroVersion = v.version
            k_annotations_modified = true
            print(JSON.encode(v))
        end
    end

    if k_annotations_modified then
        doc_settings:flush()
    end

    return nil, nil
end

return Annotations
