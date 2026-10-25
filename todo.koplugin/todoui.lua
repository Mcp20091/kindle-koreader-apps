--[[--
The drawing kit for To Do's screens.

Screens are laid out in the units of the mockup: the screen's width in
portrait is 620 units (a Kindle Scribe's 1860 pixels: 3 pixels a unit), so
a row 46 units tall is about 12 mm on the Scribe and the same share of the
screen on any other device. A Painter draws in units onto KOReader's
framebuffer; a Page is a full-screen widget that draws through one and
answers taps, holds and swipes on the areas the drawing registered.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local KO = require("todoko")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local UI = {}

UI.BLACK = Blitbuffer.COLOR_BLACK
UI.WHITE = Blitbuffer.COLOR_WHITE
UI.GREY = Blitbuffer.Color8(0x55)
UI.MID = Blitbuffer.Color8(0x88)
UI.LIGHT = Blitbuffer.Color8(0xBB)
UI.LINE = Blitbuffer.Color8(0xE0)
UI.BAND = Blitbuffer.Color8(0xEC)

local iconDir

function UI.setIconDir(dir)
    iconDir = dir
end

-- Pixels per unit, and the screen in units.
function UI.unit()
    return math.min(Screen:getWidth(), Screen:getHeight()) / 620
end

function UI.size()
    local u = UI.unit()
    return Screen:getWidth() / u, Screen:getHeight() / u
end

local faces = {}

-- A face `size` units tall (an em), regular or bold (KOReader's own UI fonts).
function UI.face(size, bold)
    local key = size .. (bold and "b" or "")
    if not faces[key] then
        -- Font:getFace scales sizes by the screen; undo that to get exact pixels.
        local scale = Screen:scaleBySize(1000) / 1000
        faces[key] = Font:getFace(bold and "tfont" or "cfont", size * UI.unit() / scale)
    end
    return faces[key]
end

function UI.resetFaces()
    faces = {}
end

-- A text's width, in units.
function UI.textWidth(text, size, bold)
    local face = UI.face(size, bold)
    return RenderText:sizeUtf8Text(0, Screen:getWidth() * 4, face, text, true, false).x / UI.unit()
end

-- The text cut to `width` units (with an ellipsis) when it is longer.
function UI.fit(text, size, bold, width)
    if UI.textWidth(text, size, bold) <= width then return text end
    local face = UI.face(size, bold)
    return RenderText:truncateTextByWidth(text, face, math.floor(width * UI.unit()), true, false)
end

-- The text in lines of at most `width` units (at most `maxLines`, the last cut).
function UI.wrap(text, size, bold, width, maxLines)
    local lines = {}
    for para in (text .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in para:gmatch("%S+") do
            local try = line == "" and word or (line .. " " .. word)
            if UI.textWidth(try, size, bold) <= width or line == "" then
                line = try
            else
                table.insert(lines, line)
                line = word
            end
        end
        table.insert(lines, line)
    end
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    if maxLines and #lines > maxLines then
        local cut = {}
        for i = 1, maxLines do cut[i] = lines[i] end
        cut[maxLines] = UI.fit(cut[maxLines] .. " …", size, bold, width)
        lines = cut
    end
    for i, l in ipairs(lines) do lines[i] = UI.fit(l, size, bold, width) end
    return lines
end

-- ------------------------------------------------------------------ painter

local Painter = {}
Painter.__index = Painter

function UI.painter(bb, ox, oy)
    return setmetatable({ bb = bb, ox = ox or 0, oy = oy or 0, u = UI.unit() }, Painter)
end

function Painter:px(v)
    return math.floor(v * self.u + 0.5)
end

function Painter:X(x) return self.ox + self:px(x) end
function Painter:Y(y) return self.oy + self:px(y) end

function Painter:rect(x, y, w, h, color, radius)
    local X, Y = self:X(x), self:Y(y)
    local W, H = self:X(x + w) - X, self:Y(y + h) - Y
    if radius and radius > 0 then
        self.bb:paintRoundedRect(X, Y, W, H, color, self:px(radius))
    else
        self.bb:paintRect(X, Y, W, H, color)
    end
end

-- A border `thick` units wide (at least a pixel).
function Painter:frame(x, y, w, h, thick, color, radius)
    local X, Y = self:X(x), self:Y(y)
    local W, H = self:X(x + w) - X, self:Y(y + h) - Y
    local bw = math.max(1, self:px(thick))
    self.bb:paintBorder(X, Y, W, H, bw, color, radius and self:px(radius) or 0, true)
end

function Painter:hline(x, y, w, color, thick)
    local X, Y = self:X(x), self:Y(y)
    self.bb:paintRect(X, Y, self:X(x + w) - X, math.max(1, self:px(thick or 0.8)), color or UI.LINE)
end

function Painter:vline(x, y, h, color, thick)
    local X, Y = self:X(x), self:Y(y)
    self.bb:paintRect(X, Y, math.max(1, self:px(thick or 0.8)), self:Y(y + h) - Y, color or UI.LINE)
end

function Painter:circle(cx, cy, r, color, thick)
    self.bb:paintCircle(self:X(cx), self:Y(cy), self:px(r), color, thick and math.max(1, self:px(thick)) or nil)
end

--- Text at baseline `y`; anchor "start", "middle" or "end"; cut to `maxWidth`
-- units if given. Returns its width in units.
function Painter:text(x, y, text, size, bold, color, anchor, maxWidth)
    if not text or text == "" then return 0 end
    if maxWidth then text = UI.fit(text, size, bold, maxWidth) end
    local w = UI.textWidth(text, size, bold)
    if anchor == "middle" then x = x - w / 2 elseif anchor == "end" then x = x - w end
    RenderText:renderUtf8Text(self.bb, self:X(x), self:Y(y), UI.face(size, bold), text, true, false, color or UI.BLACK)
    return w
end

local icons = {}

local function iconWidget(name, px)
    local key = name .. "@" .. px
    if not icons[key] then
        icons[key] = IconWidget:new{ file = iconDir .. "/" .. name .. ".svg", width = px, height = px, alpha = true }
    end
    return icons[key]
end

local inverted = {}

--- A Lucide icon `size` units square; `white` draws it white (on black).
function Painter:icon(name, x, y, size, white)
    local px = self:px(size)
    local X, Y = self:X(x), self:Y(y)
    if not white then
        iconWidget(name, px):paintTo(self.bb, X, Y)
        return
    end
    local key = name .. "@" .. px
    if not inverted[key] then
        local bb = Blitbuffer.new(px, px, self.bb:getType())
        bb:fill(UI.WHITE)
        iconWidget(name, px):paintTo(bb, 0, 0)
        bb:invertRect(0, 0, px, px)
        inverted[key] = bb
    end
    self.bb:blitFrom(inverted[key], X, Y, 0, 0, px, px)
end

-- ------------------------------------------------------------------ page

--[[--
A full-screen screen. `draw(painter, zone, page)` draws it (in units) and
calls `zone(x, y, w, h, tap, hold)` for each area that answers a finger;
later zones win. `swipe(direction)` gets swipes. As a popup (`popup =
true`) it does not cover the screen: what is under it is drawn first, and a
tap outside its zones calls `outside`.
]]
local Page = InputContainer:extend{
    draw = nil,
    swipe = nil,
    outside = nil,
    popup = false,
    kui = nil,         -- KOReader's library or book under it (for your gestures)
}
UI.Page = Page

-- The screens shown now (laid out again when the Kindle turns).
local shown = setmetatable({}, { __mode = "k" })

function Page:init()
    shown[self] = true
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = not self.popup
    self.zones = {}
    if Device:isTouchDevice() then
        local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        self.ges_events = {
            TapPage = { GestureRange:new{ ges = "tap", range = range } },
            HoldPage = { GestureRange:new{ ges = "hold", range = range } },
            SwipePage = { GestureRange:new{ ges = "swipe", range = range } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function Page:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local p = UI.painter(bb, x, y)
    if not self.popup then bb:paintRect(x, y, self.dimen.w, self.dimen.h, UI.WHITE) end
    local zones = {}
    local u = p.u
    local function zone(zx, zy, w, h, tap, hold)
        table.insert(zones, { x = zx * u, y = zy * u, w = w * u, h = h * u, tap = tap, hold = hold })
    end
    if self.draw then self.draw(p, zone) end
    self.zones = zones
    -- Rows came or went (a task done, another screen): the partial update
    -- just drawn is followed by a full one, or e-ink keeps ghosts of the old.
    if not self.popup then
        local parts = {}
        for i, z in ipairs(zones) do parts[i] = math.floor(z.x) .. "," .. math.floor(z.y) .. "," .. math.floor(z.w) .. "," .. math.floor(z.h) end
        local layout = table.concat(parts, ";")
        if self.layout and layout ~= self.layout and self.lastMode ~= "full" then
            UIManager:nextTick(function()
                if UIManager:getTopmostVisibleWidget() == self then
                    self.lastMode = "full"
                    UIManager:setDirty(self, "full")
                end
            end)
        end
        self.layout = layout
        self.lastMode = nil
    end
end

function Page:hit(pos, field)
    for i = #self.zones, 1, -1 do
        local z = self.zones[i]
        if pos.x >= z.x and pos.x < z.x + z.w and pos.y >= z.y and pos.y < z.y + z.h then
            if z[field] then return z[field] end
            if field == "hold" and z.tap then return nil end
            return z[field]
        end
    end
end

function Page:onTapPage(_, ges)
    local fn = self:hit(ges.pos, "tap")
    if fn then
        fn()
    elseif self.popup and self.outside then
        self.outside()
    end
    return true
end

function Page:onHoldPage(_, ges)
    local fn = self:hit(ges.pos, "hold")
    if fn then fn() end
    return true
end

function Page:onSwipePage(_, ges)
    if self.swipe then self.swipe(ges.direction, ges) end
    return true
end

function Page:onCloseWidget()
    shown[self] = nil
end

--- The Kindle turned (its tilt sensor): KOReader's own screen turns too, and
-- each To Do screen is laid out again for the new shape.
function Page:onSetRotationMode(mode)
    if self.kui then self.kui:handleEvent(require("ui/event"):new("SetRotationMode", mode)) end
    if Screen:getRotationMode() ~= mode then Screen:setRotationMode(mode) end
    for page in pairs(shown) do page:relayout() end
    UIManager:setDirty("all", "full")
    return true
end

function Page:relayout()
    local all = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.dimen = Geom:new{ x = self.dimen.x, y = self.dimen.y, w = all.w, h = all.h }
    for __, g in pairs(self.ges_events or {}) do
        if g[1] and g[1].range then g[1].range = all end
    end
end

function Page:onClose()
    if self.close then self.close() end
    return true
end

-- Gestures a page does not use go to KOReader's Gestures plugin (the light,
-- night mode, your QuickMenus...), and the events their actions send go on
-- to the library or book underneath.
function Page:onGesture(ev)
    if KO.passGesture(self.kui, ev, KO.allowed) then return true end
    return InputContainer.onGesture(self, ev)
end

function Page:handleEvent(event)
    if InputContainer.handleEvent(self, event) then return true end
    return KO.passEvent(self.kui, event)
end

function Page:refresh(mode)
    self.lastMode = mode or "ui"
    UIManager:setDirty(self.popup and "all" or self, mode or "ui")
end

-- ------------------------------------------------------------------ rows and pages

--- Splits `rows` ({ h = units }) into pages that fit between `top` and
-- `bottom`. Returns { {first, last}, ... }.
function UI.paginate(rows, top, bottom)
    local pages, y, first = {}, top, 1
    for i, row in ipairs(rows) do
        if y + row.h + (row.keep or 0) > bottom and i > first then
            table.insert(pages, { first, i - 1 })
            first, y = i, top
        end
        y = y + row.h
    end
    table.insert(pages, { first, #rows })
    return pages
end

return UI
