--[[--
Things on a page besides ink: typed text boxes, pictures, and tape (a grey
strip over part of the page that a tap lifts and puts back, for studying).
Text and pictures go under the ink, so they can be written on; tape goes
over everything.

An item: { k = "text", x, y, w, size (pixels), text } | { k = "image", x, y,
w, h, file (in the notebooks' images folder) } | { k = "tape", x, y, w, h,
open }.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local logger = require("logger")

local Screen = Device.screen

local Items = {}

local TAPE = Blitbuffer.Color8(0xA0)
local TAPE_EDGE = Blitbuffer.Color8(0x60)
local REVEALED = Blitbuffer.Color8(0x70)   -- a crossword's revealed letters

--- The font file of a text box: Noto Sans or Serif, regular, bold, italic.
function Items.fontFile(it)
    local style = (it.bold and it.italic and "BoldItalic") or (it.bold and "Bold") or (it.italic and "Italic") or "Regular"
    return (it.serif and "NotoSerif-" or "NotoSans-") .. style .. ".ttf"
end

--- How wide a text box's text is on one line, in pixels.
function Items.textWidth(it)
    local scale = Screen:scaleBySize(1000) / 1000
    local tw = require("ui/widget/textwidget"):new{
        text = it.text ~= "" and it.text or " ",
        face = Font:getFace(Items.fontFile(it), math.max(6, math.floor(it.size / scale + 0.5))),
    }
    local w = tw:getSize().w
    tw:free()
    return w
end

-- Text in a box `w` wide, `size` pixels high letters.
local function textWidget(it)
    local scale = Screen:scaleBySize(1000) / 1000
    return TextBoxWidget:new{
        text = it.text ~= "" and it.text or " ",
        face = Font:getFace(Items.fontFile(it), math.max(6, math.floor(it.size / scale + 0.5))),
        width = math.max(10, it.w),
        alignment = it.align or "left",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end

--- The area an item covers: x, y, w, h. Text is as tall as its lines.
function Items.box(it)
    if it.k == "text" then
        local key = it.text .. it.w .. it.size .. Items.fontFile(it)
        if not it._h or it._for ~= key then
            local tw = textWidget(it)
            it._h = tw:getSize().h
            it._for = key
            tw:free()
        end
        return it.x, it.y, it.w, it._h
    end
    return it.x, it.y, it.w, it.h
end

--- The last item (the one on top) whose area holds (x, y), and its index;
-- only of kind `kind` when given.
function Items.at(items, x, y, kind)
    for i = #(items or {}), 1, -1 do
        local it = items[i]
        if not kind or it.k == kind then
            local bx, by, bw, bh = Items.box(it)
            if x >= bx and x < bx + bw and y >= by and y < by + bh then return it, i end
        end
    end
end

-- Pictures drawn at their size, kept while the notebook is open.
local cache = {}

function Items.clearCache()
    for __, bb in pairs(cache) do bb:free() end
    cache = {}
end

local function picture(it, dir)
    local key = it.file .. ":" .. it.w .. "x" .. it.h
    if cache[key] == nil then
        local RenderImage = require("ui/renderimage")
        local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, dir .. "/" .. it.file, false, it.w, it.h)
        if not ok or not bb then
            logger.warn("Notes: cannot draw picture", it.file, bb)
            cache[key] = false
        else
            cache[key] = bb
        end
    end
    return cache[key] or nil
end

--- A PNG's or JPEG's size from the start of its file (no decoding): w, h
-- or nil.
function Items.imageDims(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(32) or ""
    local function u16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
    if head:byte(1) == 0x89 and head:sub(2, 4) == "PNG" and #head >= 24 then
        f:close()
        local function u32(i) return ((head:byte(i) * 256 + head:byte(i + 1)) * 256 + head:byte(i + 2)) * 256 + head:byte(i + 3) end
        return u32(17), u32(21)
    end
    if not (head:byte(1) == 0xFF and head:byte(2) == 0xD8) then f:close() return nil end
    -- JPEG: the markers up to the frame header (SOF), which has the size.
    f:seek("set", 2)
    for __ = 1, 500 do
        local m = f:read(4)
        if not m or #m < 4 or m:byte(1) ~= 0xFF then break end
        local code, len = m:byte(2), u16(m, 3)
        if code >= 0xC0 and code <= 0xCF and code ~= 0xC4 and code ~= 0xC8 and code ~= 0xCC then
            local sof = f:read(5)
            f:close()
            if not sof or #sof < 5 then return nil end
            return u16(sof, 4), u16(sof, 2)
        end
        f:seek("cur", len - 2)
    end
    f:close()
    return nil
end

--- A picture much larger than the screen made smaller in place, once (a
-- phone's photo would otherwise be decoded at full size whenever its page
-- is drawn). True when it was, or didn't need to be.
function Items.shrinkPicture(path, long)
    local w, h = Items.imageDims(path)
    if not w or math.max(w, h) <= long then return true end
    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false)
    if not ok or not bb then return false end
    local f = long / math.max(bb:getWidth(), bb:getHeight())
    local small = require("notesui").scale(bb, math.max(1, math.floor(bb:getWidth() * f)), math.max(1, math.floor(bb:getHeight() * f)))
    bb:free()
    local done
    if path:lower():match("%.png$") then done = pcall(small.writePNG, small, path)
    else done = pcall(small.writeJPG, small, path, 90) end
    small:free()
    return done
end

--- The size a picture file shows at, fitted in `maxW` x `maxH`.
function Items.pictureSize(path, maxW, maxH)
    local w, h = Items.imageDims(path)
    if not w then
        local RenderImage = require("ui/renderimage")
        local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false)
        if not ok or not bb then return nil end
        w, h = bb:getWidth(), bb:getHeight()
        bb:free()
    end
    local f = math.min(1, maxW / w, maxH / h)
    return math.max(1, math.floor(w * f)), math.max(1, math.floor(h * f))
end

local function overlaps(x, y, w, h, area)
    if not area then return true end
    return x < area[1] + area[3] and x + w > area[1] and y < area[2] + area[4] and y + h > area[2]
end

--- Items into an image: "under" (pictures), "text" (typed text, over fills
-- and ink) or "over" (tape); only
-- those crossing `area` when given; none in `skip`. `dir`: the pictures'
-- folder.
function Items.draw(bb, items, layer, area, skip, dir)
    for __, it in ipairs(items or {}) do
        local itsLayer = it.k == "tape" and "over" or (it.k == "text" and "text" or "under")
        if layer == itsLayer and not (skip and skip[it]) then
            local x, y, w, h = Items.box(it)
            if overlaps(x, y, w, h, area) then
                if it.k == "text" then
                    -- Only the letters, so what is under the text shows
                    -- around them: drawn on white, turned into a mask, and
                    -- painted through it in black.
                    local tw = textWidget(it)
                    local tb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
                    tb:fill(Blitbuffer.COLOR_WHITE)
                    tw:paintTo(tb, 0, 0)
                    tw:free()
                    tb:invertRect(0, 0, w, h)
                    bb:colorblitFrom(tb, x, y, 0, 0, w, h, it.rev and REVEALED or Blitbuffer.COLOR_BLACK)
                    tb:free()
                    -- A crossword's revealed letter: a mark in its square's
                    -- corner (the square is w across, its top 0.36 of the
                    -- letter's size above the text box).
                    if it.rev then
                        local s = math.max(4, math.floor(it.w * 0.2))
                        local right, bottom = x + it.w - 2, math.floor(y - it.size * 0.36 + it.w) - 2
                        for i = 0, s - 1 do bb:paintRect(right - i, bottom - s + 1 + i, i + 1, 1, Blitbuffer.COLOR_BLACK) end
                    end
                    -- A link: underlined.
                    if it.link then bb:paintRect(x, y + h - math.max(2, math.floor(it.size / 14)), w, math.max(2, math.floor(it.size / 14)), Blitbuffer.COLOR_BLACK) end
                elseif it.k == "image" then
                    local pic = picture(it, dir)
                    if pic then
                        bb:blitFrom(pic, x, y, 0, 0, pic:getWidth(), pic:getHeight())
                    else
                        bb:paintBorder(x, y, w, h, 2, TAPE_EDGE)
                    end
                elseif it.open then
                    -- Lifted tape: only its outline, dashed.
                    local d = 12
                    for i = 0, w, 2 * d do
                        bb:paintRect(x + i, y, math.min(d, w - i), 2, TAPE_EDGE)
                        bb:paintRect(x + i, y + h - 2, math.min(d, w - i), 2, TAPE_EDGE)
                    end
                    for i = 0, h, 2 * d do
                        bb:paintRect(x, y + i, 2, math.min(d, h - i), TAPE_EDGE)
                        bb:paintRect(x + w - 2, y + i, 2, math.min(d, h - i), TAPE_EDGE)
                    end
                else
                    bb:paintRect(x, y, w, h, TAPE)
                    bb:paintBorder(x, y, w, h, 2, TAPE_EDGE)
                end
            end
        end
    end
end

--- A copy of an item scaled by `s` around (ox, oy), then moved by (dx, dy).
function Items.transform(it, ox, oy, s, dx, dy)
    local out = { k = it.k, text = it.text, file = it.file, open = it.open, align = it.align, bold = it.bold,
        italic = it.italic, serif = it.serif, link = it.link }
    out.x = math.floor(ox + (it.x - ox) * s + dx + 0.5)
    out.y = math.floor(oy + (it.y - oy) * s + dy + 0.5)
    out.w = math.max(4, math.floor(it.w * s + 0.5))
    if it.h then out.h = math.max(4, math.floor(it.h * s + 0.5)) end
    if it.size then out.size = math.max(8, math.floor(it.size * s + 0.5)) end
    return out
end

return Items
