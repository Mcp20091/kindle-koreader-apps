--[[--
A small drawing surface for the screens (the same one as Apps and Wikipedia): positions and
sizes in units of a 620-wide page (the Scribe's 1860 pixels are 3 to a unit),
so every screen keeps its proportions on any Kindle. Drawing is recorded and
played onto the screen's image when painted; tap and hold areas are kept
alongside. Text can be serif and can wrap.

A flow places blocks down the page and starts a new page when the next block
does not fit, so long screens turn pages instead of scrolling (kinder to
e-ink).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local IconWidget = require("ui/widget/iconwidget")
local lfs = require("libs/libkoreader-lfs")
local RenderText = require("ui/rendertext")

local Screen = Device.screen

local Canvas = {}
Canvas.__index = Canvas

Canvas.BLACK = Blitbuffer.COLOR_BLACK
Canvas.WHITE = Blitbuffer.COLOR_WHITE
Canvas.GREY = Blitbuffer.Color8(0x55)
Canvas.MID = Blitbuffer.Color8(0x88)
Canvas.LIGHT = Blitbuffer.Color8(0xBB)
Canvas.LINE = Blitbuffer.Color8(0xDD)
Canvas.PALE = Blitbuffer.Color8(0xEC)

-- Filled to stand out, and the writing on it (see above).
Canvas.FILL, Canvas.ON_FILL, Canvas.ON_FILL_DIM = { "fill" }, { "on fill" }, { "on fill, dim" }
local DARK_FILL = Blitbuffer.Color8(0x4A)
-- (a grey's own == fails when compared with anything but a grey)
local function isFill(color) return type(color) == "table" and color == Canvas.FILL end

local iconDir = "icons/"
local icons = {}
local FALLBACK = "star"
local faces = {}

function Canvas.setDir(path)
    iconDir = path .. "/icons/"
end

-- KOReader scales font sizes by the screen's density; sizes here are pixels.
local function face(px, bold, serif)
    local key = (bold and "b" or "r") .. (serif and "s" or "") .. px
    if not faces[key] then
        local scale = Screen:scaleBySize(1000) / 1000
        local name = serif and (bold and "NotoSerif-Bold.ttf" or "NotoSerif-Regular.ttf")
            or (bold and "NotoSans-Bold.ttf" or "NotoSans-Regular.ttf")
        faces[key] = Font:getFace(name, px / scale)
    end
    return faces[key]
end

-- The dark version of a grey (cached: the same few greys again and again).
local swapped = {}
local function swap(color)
    local v = color:getColor8().a
    if not swapped[v] then swapped[v] = Blitbuffer.Color8(0xFF - v) end
    return swapped[v]
end

--- A canvas; a dark one swaps the greys (black for white, white icons for black
-- ones). What is filled to stand out is drawn in FILL with ON_FILL writing:
-- black with white writing on a light canvas; on a dark one, as e-readers do
-- dark mode, a thick white outline around black instead.
function Canvas.new(w, h, dark)
    local self = setmetatable({}, Canvas)
    self.dark = dark or false
    -- 620 units across the short side: the same sizes upright or on its side
    -- (on its side there is simply more room across).
    self.u = math.min(w, h) / 620
    self.W, self.H = w / self.u, h / self.u
    self.ops, self.hits = {}, {}
    return self
end

function Canvas:X(v) return math.floor(v * self.u + 0.5) end

--- A grey as drawn: swapped on a dark canvas.
function Canvas:col(color)
    if type(color) == "table" then
        -- (a dark canvas's FILL boxes and circles are outlines: see box and circle;
        -- a filled band, such as a selected row, is dark grey)
        if color == Canvas.FILL then return self.dark and DARK_FILL or Canvas.BLACK end
        return color == Canvas.ON_FILL and Canvas.WHITE or Canvas.LIGHT
    end
    if self.dark and color then return swap(color) end
    return color
end

--- The page's background.
function Canvas:background() return self.dark and Canvas.BLACK or Canvas.WHITE end

function Canvas:rect(x, y, w, h, color)
    local px, py, pw, ph = self:X(x), self:X(y), self:X(x + w) - self:X(x), self:X(y + h) - self:X(y)
    color = self:col(color)
    table.insert(self.ops, function(bb, ox, oy) bb:paintRect(ox + px, oy + py, pw, ph, color) end)
end

--- A rounded box: filled and/or bordered.
function Canvas:box(x, y, w, h, opts)
    local px, py = self:X(x), self:Y(y)
    local pw, ph = self:X(x + w) - px, self:Y(y + h) - py
    local r = self:X(opts.r or 0)
    local fill, border = self:col(opts.fill), self:col(opts.border)
    local bw = math.max(1, self:X(opts.bw or 1))
    if self.dark and isFill(opts.fill) then
        fill, border, bw = Canvas.BLACK, Canvas.WHITE, math.max(2, self:X(2.2))
    end
    table.insert(self.ops, function(bb, ox, oy)
        if fill then bb:paintRoundedRect(ox + px, oy + py, pw, ph, fill, r) end
        if border then bb:paintBorder(ox + px, oy + py, pw, ph, bw, border, r, true) end
    end)
end
Canvas.Y = Canvas.X

function Canvas:hline(x, y, w, color, thick)
    self:rect(x, y, w, (thick or 1) / self.u, color or Canvas.LINE)
end

function Canvas:circle(cx, cy, r, color, ring)
    local px, py, pr = self:X(cx), self:X(cy), self:X(r)
    local w = ring and math.max(1, self:X(ring)) or nil
    if self.dark and isFill(color) and not ring then w = math.max(2, self:X(1.8)) end
    color = self:col(color)
    table.insert(self.ops, function(bb, ox, oy) bb:paintCircle(ox + px, oy + py, pr, color, w) end)
end

function Canvas:width(s, size, bold, serif)
    local f = face(self:X(size), bold, serif)
    return RenderText:sizeUtf8Text(0, Screen:getWidth() * 4, f, s, true, false).x / self.u
end

--- `s` broken into lines no wider than maxw; at most `max` lines (the last cut with …).
function Canvas:wrap(s, size, maxw, opts)
    opts = opts or {}
    local out, cur = {}, ""
    for word in tostring(s or ""):gmatch("%S+") do
        local try = cur == "" and word or (cur .. " " .. word)
        if cur ~= "" and self:width(try, size, opts.bold, opts.serif) > maxw then
            table.insert(out, cur)
            cur = word
        else
            cur = try
        end
    end
    if cur ~= "" then table.insert(out, cur) end
    if opts.max and #out > opts.max then
        local cut = {}
        for i = 1, opts.max do cut[i] = out[i] end
        cut[opts.max] = cut[opts.max]:gsub("[,.;:]?$", "") .. "…"
        out = cut
    end
    return out
end

--- Wrapped text from baseline y, `lh` apart (opts as text and wrap); returns the y after it.
function Canvas:para(x, y, s, size, maxw, lh, opts)
    opts = opts or {}
    local lines = self:wrap(s, size, maxw, opts)
    for i, l in ipairs(lines) do
        self:text(x, y + (i - 1) * lh, l, size, { bold = opts.bold, serif = opts.serif, color = opts.color, maxw = maxw })
    end
    return y + #lines * lh, #lines
end

--- Text with its baseline at y. opts: bold, serif, color, align ("middle", "end"), maxw (cut with …).
function Canvas:text(x, y, s, size, opts)
    opts = opts or {}
    if not s or s == "" then return end
    local f = face(self:X(size), opts.bold, opts.serif)
    if opts.maxw then
        local maxpx = self:X(opts.maxw)
        if RenderText:sizeUtf8Text(0, Screen:getWidth() * 4, f, s, true, false).x > maxpx then
            s = RenderText:truncateTextByWidth(s, f, maxpx, true, false)
        end
    end
    local w = RenderText:sizeUtf8Text(0, Screen:getWidth() * 4, f, s, true, false).x
    local px = self:X(x)
    if opts.align == "middle" then px = px - math.floor(w / 2)
    elseif opts.align == "end" then px = px - w end
    local py = self:X(y)
    local color = self:col(opts.color or Canvas.BLACK)
    table.insert(self.ops, function(bb, ox, oy) RenderText:renderUtf8Text(bb, ox + px, oy + py, f, s, true, false, color) end)
    return w / self.u
end

--- A Lucide icon from icons/ (white for dark backgrounds).
function Canvas:icon(name, x, y, size, white)
    -- On a dark canvas everything around an icon is dark (FILL included).
    if self.dark then white = true end
    local px = self:X(size)
    local key = name .. (white and "-w" or "") .. "@" .. px
    local widget = icons[key]
    if not widget then
        local file = iconDir .. name .. (white and "-w" or "") .. ".svg"
        -- An icon this plugin does not have (named by another plugin): a plain one instead.
        if lfs.attributes(file, "mode") ~= "file" then file = iconDir .. FALLBACK .. (white and "-w" or "") .. ".svg" end
        widget = IconWidget:new{ file = file, width = px, height = px, alpha = true }
        icons[key] = widget
    end
    local ix, iy = self:X(x), self:X(y)
    table.insert(self.ops, function(bb, ox, oy) widget:paintTo(bb, ox + ix, oy + iy) end)
end

--- A picture (a blitbuffer already its size in pixels), dithered for e-ink when KOReader dithers.
function Canvas:image(img, x, y)
    local ix, iy = self:X(x), self:X(y)
    table.insert(self.ops, function(bb, ox, oy)
        if Screen.sw_dithering then
            bb:ditherblitFrom(img, ox + ix, oy + iy, 0, 0, img:getWidth(), img:getHeight())
        else
            bb:blitFrom(img, ox + ix, oy + iy, 0, 0, img:getWidth(), img:getHeight())
        end
    end)
end

--- A tap (and hold) area.
function Canvas:hit(x, y, w, h, tap, hold)
    table.insert(self.hits, { x = self:X(x), y = self:X(y), w = self:X(w), h = self:X(h), tap = tap, hold = hold })
end

--- The topmost area at pixel (x, y).
function Canvas:find(x, y)
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then return h end
    end
end

function Canvas:paint(bb, ox, oy)
    for __, op in ipairs(self.ops) do op(bb, ox, oy) end
end

function Canvas:release()
    self.ops, self.hits = {}, {}
end

-- ------------------------------------------------------------------ flow

local Flow = {}
Flow.__index = Flow

-- The bar at the foot of a page when there's more than one. How it looks is one setting for
-- every app (Settings > Launcher > Page bar, apps_page_bar):
--   "parts"  one part per page with its number, the page you're on filled; a tap on one goes there
--   "next"   "Page 1 of 4" over thin parts (a tap goes there), and Next
--   "words"  "Page 1 of 4 · Next page ›", only on a page with more after it
-- With more than 12 pages, "parts" drops the numbers and adds the "Page 1 of 4" line.
local MORE_H = 48

--- The page bar's look: "parts" (the default), "next" or "words".
function Canvas.pageBar()
    local s = rawget(_G, "G_reader_settings")
    local v = s and s:readSetting("apps_page_bar")
    if v == "next" or v == "words" then return v end
    return "parts"
end

--- Blocks from `top` to `bottom`; only page `want` is drawn. With the canvas's
-- `turn` (fn(delta), set by the page that draws it), a page of several ends in the
-- page bar (room kept for it at the foot).
function Canvas:flow(top, bottom, want)
    return setmetatable({ c = self, top = top, bottom = bottom, y = top, page = 1, want = want or 1,
        room = self.turn and MORE_H or 0 }, Flow)
end

--- A block `h` tall, drawn by draw(y); `keep` more units must fit after it
-- on the same page (a heading stays with what it heads).
function Flow:block(h, draw, keep)
    if self.y + h + (keep or 0) > self.bottom - self.room and self.y > self.top then
        self.page = self.page + 1
        self.y = self.top
    end
    if self.page == self.want then draw(self.y) end
    self.y = self.y + h
end

function Flow:gap(h)
    if self.y > self.top then self.y = self.y + h end
end

--- How many pages (once every block is in); draws the page bar when there's more than one.
function Flow:pages()
    if self.room == 0 or self.barDone or self.page < 2 then return self.page end
    self.barDone = true
    local c, n, at = self.c, self.page, self.want
    local style = Canvas.pageBar()
    local T = require("ffi/util").template
    local _ = require("gettext")
    local y, h = self.bottom - MORE_H + 6, MORE_H - 10
    local function go(k) return function() if k ~= at then c.turn(k - at) end end end
    if style == "words" then
        if at < n then
            c:box(14, y, c.W - 28, h, { r = 8, border = Canvas.BLACK, bw = 1.5 })
            c:text(c.W / 2, y + 25, T(_("Page %1 of %2 · Next page"), at, n) .. "  \u{203A}", 12, { align = "middle", bold = true })
            c:hit(14, y, c.W - 28, h, go(at + 1))
        end
        return n
    end
    local x0, x1 = 14, c.W - 14
    local numbered = style == "parts" and n <= 12
    local py, ph = y, h
    if not numbered then
        c:text(14, y + 11, T(_("Page %1 of %2"), at, n), 9.5, { color = Canvas.GREY })
        py, ph = y + 18, 16
    end
    if style == "next" then
        local label = _("Next") .. "  \u{203A}"
        local bw = c:width(label, 11.5, true) + 28
        if at < n then
            c:box(x1 - bw, y + 4, bw, h - 4, { r = 8, border = Canvas.BLACK, bw = 1.5 })
            c:text(x1 - bw / 2, y + 26, label, 11.5, { align = "middle", bold = true })
            c:hit(x1 - bw, y, bw, h + 4, go(at + 1))
        end
        x1 = x1 - bw - 10
    end
    local gap = n > 12 and 3 or 6
    local w = (x1 - x0 - (n - 1) * gap) / n
    for k = 1, n do
        local x = x0 + (k - 1) * (w + gap)
        local on = k == at
        c:box(x, py, w, ph, { r = math.min(6, ph / 2), fill = on and Canvas.FILL or Canvas.WHITE, border = Canvas.BLACK, bw = 1.3 })
        if numbered then
            c:text(x + w / 2, py + ph / 2 + 5, tostring(k), 12, { align = "middle", bold = true, color = on and Canvas.ON_FILL or Canvas.BLACK })
        end
        c:hit(x, y, w + gap, h + 4, go(k))
    end
    return n
end

return Canvas
