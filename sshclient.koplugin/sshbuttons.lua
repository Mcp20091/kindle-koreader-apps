--[[--
The foot of SSH's own full pages (the command output, the AI chat), drawn
as the launcher's pop-ups draw theirs: a page counter ‹ n/m › when there is
more than one page, then a row of icon buttons, each an icon over a short
label, the main one black, as wide as one of five, lined up on the right:
the launcher's own (PS.popup.iconButtons), or without it this file's copy of
it. It follows Settings > Launcher > Display > Button labels (icons only).

    Foot:new{ width = px, buttons = { { icon, text, primary, aiJob, fn } },
        turn = function(d) end }   -- ‹ (-1) and › (+1)
    foot:setPage(n, m)   foot:setButtons(buttons)
]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local Screen = Device.screen

local Canvas = require("sshcanvas")
local C = Canvas

Canvas.setDir((debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."))

-- Whether the shared buttons show their labels (Settings > Launcher >
-- Display > Button labels: the launcher's PS.popup.labels()).
local function labels()
    local P = require("pluginshare").popup
    if P and P.labels then return P.labels() end
    return G_reader_settings:readSetting("apps_button_labels") ~= false
end

-- (A copy of appspopup.lua's iconButtons.) A row of buttons, each an icon
-- over a short label, the main one black: { icon, text, primary }; act(b)
-- when tapped. 76 tall. Each is as wide as one of five in a row, lined up on
-- the right. Without labels: just the icons, in squares.
local function iconButtons(c, x, y, bw, buttons, act)
    local gap = 10
    local n = math.max(1, #buttons)
    local w = math.min((bw - 36 - gap * (n - 1)) / n, (bw - 36 - gap * 4) / 5)
    local withLabels = labels()
    local allIcons = true
    for __, b in ipairs(buttons) do if not b.icon then allIcons = false end end
    if not withLabels and allIcons then w = math.min(w, 56) end
    local bx = x + bw - 18 - (n * w + gap * (n - 1))
    for __, b in ipairs(buttons) do
        c:box(bx, y + 10, w, 56, { r = 14, fill = b.primary and C.FILL or C.WHITE, border = C.BLACK, bw = 1.2 })
        if b.icon and not withLabels then
            c:icon(b.icon, bx + w / 2 - 12, y + 26, 24, b.primary)
        else
            if b.icon then c:icon(b.icon, bx + w / 2 - 11, y + 17, 22, b.primary) end
            c:text(bx + w / 2, b.icon and (y + 58) or (y + 44), b.text or "", 10.5, { bold = true, align = "middle", maxw = w - 8,
                color = b.primary and C.ON_FILL or C.BLACK })
        end
        -- A button that uses AI (aiJob): hold it for AI for this (service, model).
        c:hit(bx, y + 6, w, 64, function() act(b) end, b.aiJob and function()
            local ai = require("pluginshare").ai
            if ai and ai.quickPick then ai.quickPick(b.aiJob) end
        end or nil)
        bx = bx + w + gap
    end
end

-- The page counter's height, in canvas units.
local PAGES_H = 26

local Foot = InputContainer:extend{
    width = nil,
    buttons = nil,
    turn = nil,
    bare = false,     -- the buttons only (no page counter), in `height` pixels
    height = nil,
}

function Foot:init()
    self.u = math.min(Screen:getWidth(), Screen:getHeight()) / 620
    self.page, self.pages = 1, 1
    if not (self.bare and self.height) then
        self.height = math.floor(((self.bare and 0 or PAGES_H) + 76) * self.u + 0.5)
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        TapFoot = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldFoot = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

function Foot:getSize() return Geom:new{ w = self.width, h = self.height } end

function Foot:draw()
    -- With the launcher: its own row (PS.popup.iconButtons), drawn on its
    -- canvas (its colours and icons); this file's copy without it.
    local P = require("pluginshare").popup
    local shared = P and P.iconButtons
    local K = shared and require("appscanvas") or Canvas
    local c = K.new(Screen:getWidth(), Screen:getHeight())
    local bw = self.width / c.u
    if self.bare then
        -- (the buttons in the middle of the height given)
        local top = math.max(0, (self.height / c.u - 76) / 2)
        local act = function(b) if b.fn then b.fn() end end;
        ((P and P.iconButtons) or iconButtons)(c, 0, top, bw, self.buttons or {}, act)
        return c
    end
    if self.pages > 1 then
        -- ‹ n/m ›: a tap on either half turns a page
        local mid = bw / 2
        c:text(mid, 18, T("‹  %1/%2  ›", self.page, self.pages), 11, { align = "middle", color = K.GREY })
        c:hit(mid - 70, 0, 70, PAGES_H, function() if self.turn then self.turn(-1) end end)
        c:hit(mid, 0, 70, PAGES_H, function() if self.turn then self.turn(1) end end)
    end
    local act = function(b) if b.fn then b.fn() end end;
    (shared or iconButtons)(c, 0, PAGES_H, bw, self.buttons or {}, act)
    return c
end

function Foot:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self.canvas then self.canvas:release() end
    self.canvas = self:draw()
    self.canvas:paint(bb, x, y)
end

function Foot:onTapFoot(__, ges)
    local c = self.canvas
    if not c then return false end
    local h = c:find(ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y)
    if h and h.tap then UIManager:nextTick(h.tap) end
    return true
end

--- A hold: a button's own (an AI button's AI for this), or else its tap (a
-- firm pen press lasts long enough to be a hold).
function Foot:onHoldFoot(__, ges)
    local c = self.canvas
    if not c then return false end
    local h = c:find(ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y)
    local fn = h and (h.hold or h.tap)
    if fn then
        UIManager:nextTick(fn)
        return true
    end
    return false
end

function Foot:refresh()
    if self.show_parent then UIManager:setDirty(self.show_parent, "ui", self.dimen) end
end

--- The page counter: page n of m.
function Foot:setPage(n, m)
    if n == self.page and m == self.pages then return end
    self.page, self.pages = n, m
    self:refresh()
end

function Foot:setButtons(buttons)
    self.buttons = buttons
    self:refresh()
end

--- Page n of m of a ScrollTextWidget (from its text's lines).
function Foot.pageOf(scroll)
    local tw = scroll and scroll.text_widget
    if not tw or not tw.vertical_string_list then return 1, 1 end
    local per = math.max(1, tw.lines_per_page or 1)
    local total = #tw.vertical_string_list
    local m = math.max(1, math.ceil(total / per))
    local n = math.min(m, math.floor(((tw.virtual_line_num or 1) - 1) / per) + 1)
    -- (the last page can start before a multiple of a page: count it as the last)
    if (tw.virtual_line_num or 1) + per - 1 >= total then n = m end
    return n, m
end

return Foot
