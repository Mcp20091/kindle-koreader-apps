--[[--
Drawing the editor's toolbar and panels straight into a blitbuffer: text,
icons (Lucide SVGs in icons/), boxes, and the tap areas they leave behind.

Everything is measured in units of the approved mockup (the Scribe's 1860 x
2480 screen drawn 620 wide): one unit is about 3 pixels on a 300 dpi screen,
scaled with the screen's dpi elsewhere.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")

local Screen = Device.screen
local ICONS = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/icons/"

local UI = {}
UI.__index = UI

UI.BLACK = Blitbuffer.COLOR_BLACK
UI.WHITE = Blitbuffer.COLOR_WHITE
UI.LINE = Blitbuffer.Color8(0xDD)
UI.MID = Blitbuffer.Color8(0x99)
UI.GREY_TEXT = Blitbuffer.Color8(0x55)

function UI.new()
    local self = setmetatable({ texts = {}, icons = {} }, UI)
    -- 3 pixels a unit at 300 dpi; text sizes through KOReader's own scaling.
    self.unit = Screen:getDPI() / 100
    self.fontScale = self.unit / (Screen:scaleBySize(1000) / 1000)
    return self
end

--- Units into pixels.
function UI:u(n)
    return math.floor(n * self.unit + 0.5)
end

function UI:free()
    for __, w in pairs(self.texts) do w:free() end
    for __, w in pairs(self.icons) do w:free() end
    self.texts, self.icons = {}, {}
end

function UI:text(s, size, bold, color)
    local key = table.concat({ s, size, bold and "b" or "", color and color:getColor8().a or "" }, "|")
    local w = self.texts[key]
    if not w then
        w = TextWidget:new{
            text = s,
            face = Font:getFace("cfont", math.max(6, math.floor(size * self.fontScale + 0.5))),
            bold = bold,
            fgcolor = color or UI.BLACK,
            padding = 0,
        }
        self.texts[key] = w
    end
    return w
end

--- Text with its left edge at x and its middle at cy; returns its width.
function UI:drawText(bb, s, x, cy, size, opts)
    opts = opts or {}
    local w = self:text(s, size, opts.bold, opts.color)
    local sz = w:getSize()
    if opts.align == "center" then x = x - math.floor(sz.w / 2)
    elseif opts.align == "right" then x = x - sz.w end
    w:paintTo(bb, x, cy - math.floor(sz.h / 2))
    return sz.w
end

-- Text that changes (the time): drawn without keeping it.
local function drawOnce(self, bb, s, x, cy, size, bold, align)
    local w = TextWidget:new{
        text = s,
        face = Font:getFace("cfont", math.max(6, math.floor(size * self.fontScale + 0.5))),
        bold = bold,
        fgcolor = UI.BLACK,
        padding = 0,
    }
    local sz = w:getSize()
    if align == "center" then x = x - math.floor(sz.w / 2)
    elseif align == "right" then x = x - sz.w end
    w:paintTo(bb, x, cy - math.floor(sz.h / 2))
    w:free()
    return sz.w
end

--- The time now, as KOReader shows it (12 or 24 hours, as set there).
function UI.clock()
    local ok, s = pcall(function()
        return require("datetime").secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    end)
    return ok and s or os.date("%H:%M")
end

--- The battery: its percent (nil when unknown) and whether it's charging.
function UI.battery()
    local powerd = Device.getPowerDevice and Device:getPowerDevice()
    if not powerd then return nil, false end
    local ok, pct = pcall(powerd.getCapacity, powerd)
    local ok2, charging = pcall(powerd.isCharging, powerd)
    return ok and tonumber(pct) or nil, ok2 and charging == true
end

-- A battery icon `size` square at (x, y), filled as far as it's charged.
function UI:drawBattery(bb, x, y, size, pct, charging)
    self:drawIcon(bb, charging and "battery-charging" or "battery", x, y, size)
    if not charging and pct and pct > 0 then
        -- Inside the outline (3..17 by 7..17 of its 24).
        local k = size / 24
        bb:paintRect(x + math.floor(4.5 * k), y + math.floor(8.5 * k),
            math.max(1, math.floor(11 * k * math.min(100, pct) / 100)), math.max(1, math.floor(7 * k)), UI.BLACK)
    end
end

--- The time and battery on one line, ending at x (its middle at cy).
-- Returns how wide it was.
function UI:drawStatus(bb, x, cy, size)
    local pct, charging = UI.battery()
    local right = x
    if pct then
        local w = drawOnce(self, bb, pct .. "%", x, cy, size, false, "right")
        local is = self:u(size * 1.6)
        x = x - w - self:u(2) - is
        self:drawBattery(bb, x, cy - math.floor(is / 2), is, pct, charging)
        x = x - self:u(10)
    end
    local w = drawOnce(self, bb, UI.clock(), x, cy, size, true, "right")
    return right - (x - w)
end

--- The time and battery stacked, `w` wide from x, in the middle of the
-- `room` high below y; returns the height used (0: it didn't fit).
function UI:drawStatusStacked(bb, x, y, w, room, size)
    local pct, charging = UI.battery()
    local line = self:u(size * 1.6)
    local need = line * (pct and 2 or 1)
    if need > room then return 0 end
    y = y + math.floor((room - need) / 2)
    local cx = x + math.floor(w / 2)
    -- Narrow: "12:45", without AM/PM.
    local clock = UI.clock()
    if self:textWidth(clock, size, true) > w then clock = clock:match("^(%S+)") or clock end
    drawOnce(self, bb, clock, cx, y + math.floor(line / 2), size, true, "center")
    if pct then
        -- The battery and its percent side by side.
        local is = self:u(size * 1.3)
        local small = size * 0.85
        local tw = self:textWidth(pct .. "%", small)
        local bx = cx - math.floor((is + self:u(1) + tw) / 2)
        self:drawBattery(bb, bx, y + line + math.floor((line - is) / 2), is, pct, charging)
        drawOnce(self, bb, pct .. "%", bx + is + self:u(1), y + line + math.floor(line / 2), small, false)
    end
    return need
end

--- Calls fn at the start of every minute from now on; returns a function
-- that stops it.
function UI.everyMinute(fn)
    local UIManager = require("ui/uimanager")
    local task
    task = function()
        fn()
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), task)
    end
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), task)
    return function() UIManager:unschedule(task) end
end

function UI:textWidth(s, size, bold)
    return self:text(s, size, bold):getSize().w
end

function UI:icon(name, size, white, dim)
    local key = table.concat({ name, size, white and "w" or "", dim and "d" or "" }, "|")
    local w = self.icons[key]
    if not w then
        w = ImageWidget:new{
            file = ICONS .. name .. (white and "-w.svg" or ".svg"),
            width = size,
            height = size,
            alpha = true,
            dim = dim,
            file_do_cache = false,
            original_in_nightmode = false,   -- icons turn white with the page
        }
        self.icons[key] = w
    end
    return w
end

function UI:drawIcon(bb, name, x, y, size, white, dim)
    self:icon(name, size, white, dim):paintTo(bb, x, y)
end

function UI:box(bb, x, y, w, h, opts)
    opts = opts or {}
    local r = opts.r or 0
    if opts.fill then bb:paintRoundedRect(x, y, w, h, opts.fill, r) end
    if opts.border then bb:paintBorder(x, y, w, h, opts.bw or math.max(1, self:u(1)), opts.border, r) end
end

function UI:line(bb, x, y, w, h, color)
    bb:paintRect(x, y, math.max(1, w), math.max(1, h), color or UI.LINE)
end

--- A dashed rectangle outline.
--- An image made smaller (or bigger) smoothly, by MuPDF: thin lines and
-- ink stay (Blitbuffer's own scaling keeps every so many pixels, losing
-- lines between them). Falls back to that one.
function UI.scale(bb, w, h)
    local ok, out = pcall(function() return require("ffi/mupdf").scaleBlitBuffer(bb, w, h) end)
    if ok and out then return out end
    return bb:scale(w, h)
end

function UI:dashed(bb, x, y, w, h, color)
    local d, t = self:u(4), math.max(2, self:u(0.8))
    color = color or UI.BLACK
    for i = 0, w, 2 * d do
        bb:paintRect(x + i, y, math.min(d, w - i), t, color)
        bb:paintRect(x + i, y + h - t, math.min(d, w - i), t, color)
    end
    for i = 0, h, 2 * d do
        bb:paintRect(x, y + i, t, math.min(d, h - i), color)
        bb:paintRect(x + w - t, y + i, t, math.min(d, h - i), color)
    end
end

return UI
