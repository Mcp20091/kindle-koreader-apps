--[[--
The reorder screen (notebooks, pages, the toolbar), as in the other apps:
tap a row to select it, then move it to the top, up, down or to the
bottom; Undo puts back the order before each move, one at a time. ✓ keeps
the new order, ✕ leaves it as it was. Rows given `shown` have an eye: tap it
to show or hide that one (the toolbar's buttons). Given `defaults` (items as
`items`), Reset puts them back (Undo takes that back too).

@module koplugin.notes.reorder
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Order = require("notesorder")
local UI = require("notesui")

local Screen = Device.screen

local Reorder = InputContainer:extend{
    title = "",
    items = nil,      -- { { text, key, shown }... } (shown: true/false for an eye, nil for none)
    done = nil,       -- done(keys, shown) when kept (shown: { [key] = true/false })
    defaults = nil,   -- items as at first, for Reset
    covers_fullscreen = true,
}

function Reorder:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ui = UI.new()
    self.keys, self.names, self.notes, self.shown = {}, {}, {}, {}
    for i, it in ipairs(self.items or {}) do
        self.keys[i] = it.key
        self.names[it.key] = it.text
        self.notes[it.key] = it.mandatory   -- a word at the right ("blank")
        self.shown[it.key] = it.shown
    end
    self.undo = {}
    self.first = 1
    self.hits = {}
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        ReorderTap = { GestureRange:new{ ges = "tap", range = all } },
        ReorderHold = { GestureRange:new{ ges = "hold", range = all } },
        ReorderSwipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
end

function Reorder:geometry()
    local u = function(n) return self.ui:u(n) end
    local bar, hint, foot, row = u(44), u(30), u(44), u(40)
    local per = math.max(1, math.floor((self.h - bar - hint - foot) / row))
    return { bar = bar, hint = hint, foot = foot, row = row, per = per }
end

function Reorder:hit(x, y, w, h, fn)
    table.insert(self.hits, { x, y, w, h, fn })
end

function Reorder:onReorderTap(_arg, ges)
    if not (ges and ges.pos) then return true end
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if ges.pos.x >= h[1] and ges.pos.x < h[1] + h[3] and ges.pos.y >= h[2] and ges.pos.y < h[2] + h[4] then
            h[5]()
            return true
        end
    end
    return true
end

-- Held (a firm pen press counts as a hold): the same as a tap.
function Reorder:onReorderHold(arg, ges) return self:onReorderTap(arg, ges) end

function Reorder:onReorderSwipe(_arg, ges)
    if ges.direction == "west" or ges.direction == "north" then self:turn(1)
    elseif ges.direction == "east" or ges.direction == "south" then self:turn(-1) end
    return true
end

function Reorder:turn(dir)
    local per = self:geometry().per
    local first = self.first + dir * per
    if first < 1 or first > #self.keys then return end
    self.first = first
    self:redraw()
end

function Reorder:redraw()
    UIManager:setDirty(self, "ui")
end

-- The selected one moved by `delta` places (big: to the top or bottom), the
-- screen turned to where it is now.
function Reorder:move(delta)
    local moved = Order.move(self.keys, self.sel, delta)
    if not moved then return end
    table.insert(self.undo, self.keys)
    self.keys = moved
    self:showSelected()
    self:redraw()
end

function Reorder:showSelected()
    local per = self:geometry().per
    for i, k in ipairs(self.keys) do
        if k == self.sel then self.first = math.floor((i - 1) / per) * per + 1 end
    end
end

function Reorder:onClose()
    UIManager:close(self)
    return true
end

function Reorder:onCloseWidget()
    self.ui:free()
    UIManager:setDirty(nil, "full")
end

-- A name cut to fit `w`.
local function fit(ui, s, size, bold, w)
    if ui:textWidth(s, size, bold) <= w then return s end
    while #s > 1 and ui:textWidth(s .. "…", size, bold) > w do
        s = s:sub(1, -2):gsub("[\128-\191]+$", ""):gsub("[\192-\255]$", "")
    end
    return s .. "…"
end

function Reorder:paintTo(bb, x, y)
    local ui, g = self.ui, self:geometry()
    local u = function(n) return ui:u(n) end
    self.hits = {}
    bb:paintRect(x, y, self.w, self.h, Blitbuffer.COLOR_WHITE)
    -- Title: ✕ (leave as it was), the title, Undo and ✓ (keep).
    ui:drawIcon(bb, "x", u(14), u(13), u(18))
    self:hit(0, 0, u(50), g.bar, function() UIManager:close(self) end)
    ui:drawText(bb, fit(ui, self.title, 13, true, self.w - (self.defaults and u(340) or u(220))), math.floor(self.w / 2), math.floor(g.bar / 2), 13,
        { align = "center", bold = true })
    ui:drawIcon(bb, "check", self.w - u(32), u(13), u(18))
    self:hit(self.w - u(50), 0, u(50), g.bar, function()
        UIManager:close(self)
        if self.done then self.done(self.keys, self.shown) end
    end)
    if #self.undo > 0 then
        ui:drawIcon(bb, "undo-2", self.w - u(82), u(13), u(18))
        self:hit(self.w - u(100), 0, u(50), g.bar, function()
            local back = table.remove(self.undo)
            if back.keys then
                self.keys, self.shown = back.keys, back.shown
            else
                self.keys = back
            end
            if self.sel then self:showSelected() end
            self:redraw()
        end)
    end
    if self.defaults then
        -- Reset: the order (and what is shown) as it was to start with.
        local label = _("Reset")
        local lw = ui:textWidth(label, 10) + u(20)
        local rx = self.w - u(110) - lw
        ui:box(bb, rx, u(9), lw, u(26), { border = UI.BLACK, r = u(13) })
        ui:drawText(bb, label, rx + math.floor(lw / 2), u(22), 10, { align = "center" })
        self:hit(rx - u(4), 0, lw + u(8), g.bar, function()
            local shown = {}
            for k, v in pairs(self.shown) do shown[k] = v end
            table.insert(self.undo, { keys = self.keys, shown = shown })
            self.keys, self.shown = {}, {}
            for i, it in ipairs(self.defaults) do
                self.keys[i] = it.key
                self.names[it.key] = self.names[it.key] or it.text
                self.shown[it.key] = it.shown
            end
            self.sel = nil
            self.first = 1
            self:redraw()
        end)
    end
    bb:paintRect(0, g.bar, self.w, 1, UI.MID)
    local eyes = false
    for __, v in pairs(self.shown) do if v ~= nil then eyes = true end end
    ui:drawText(bb, eyes and _("Tap one, then use the arrows to move it. The eye shows or hides it.")
        or _("Tap one, then use the arrows to move it."), u(14), g.bar + math.floor(g.hint / 2), 10, { color = UI.GREY_TEXT })
    -- The rows.
    if self.first > math.max(1, #self.keys) then self.first = 1 end
    local top = g.bar + g.hint
    local n = #self.keys
    for k = 0, g.per - 1 do
        local i = self.first + k
        local key = self.keys[i]
        if not key then break end
        local ry = top + k * g.row
        local sel = key == self.sel
        if sel then bb:paintRect(0, ry, self.w, g.row, UI.BLACK) end
        local arrows = sel and u(4 * 46) or 0
        local note = not sel and self.notes[key]
        local noteW = 0
        if note then
            noteW = ui:drawText(bb, note, self.w - u(14), ry + math.floor(g.row / 2), 9.5, { align = "right", color = UI.GREY_TEXT }) + u(10)
        end
        local shown = self.shown[key]
        local tx = shown ~= nil and u(50) or u(14)
        ui:drawText(bb, fit(ui, tostring(self.names[key] or key), 11, sel, self.w - tx - u(14) - arrows - noteW), tx,
            ry + math.floor(g.row / 2), 11, { bold = sel, color = sel and UI.WHITE or (shown == false and UI.GREY_TEXT or UI.BLACK) })
        self:hit(0, ry, self.w - arrows, g.row, function()
            self.sel = (not sel) and key or nil
            self:redraw()
        end)
        if shown ~= nil then
            -- The eye: shown or hidden.
            ui:drawIcon(bb, shown and "eye" or "eye-off", u(16), ry + math.floor((g.row - u(18)) / 2), u(18), sel)
            self:hit(0, ry, u(48), g.row, function()
                self.shown[key] = not self.shown[key]
                self:redraw()
            end)
        end
        if sel then
            for j, a in ipairs({ { "arrow-up-to-line", -n }, { "arrow-up", -1 }, { "arrow-down", 1 }, { "arrow-down-to-line", n } }) do
                local bx = self.w - arrows + (j - 1) * u(46)
                ui:box(bb, bx, ry + u(5), u(40), g.row - u(10), { fill = UI.WHITE, r = u(6) })
                ui:drawIcon(bb, a[1], bx + u(11), ry + math.floor((g.row - u(18)) / 2), u(18))
                self:hit(bx - u(3), ry, u(46), g.row, function() self:move(a[2]) end)
            end
        end
        bb:paintRect(u(14), ry + g.row - 1, self.w - u(28), 1, UI.MID)
    end
    -- Paging.
    local pages = math.max(1, math.ceil(n / g.per))
    if pages > 1 then
        local fy = self.h - g.foot
        bb:paintRect(0, fy, self.w, 1, UI.MID)
        local at = math.floor((self.first - 1) / g.per) + 1
        ui:drawText(bb, T(_("%1 of %2"), at, pages), math.floor(self.w / 2), fy + math.floor(g.foot / 2), 11, { align = "center" })
        ui:drawIcon(bb, "chevron-left", u(60), fy + u(13), u(18), false, at <= 1)
        ui:drawIcon(bb, "chevron-right", self.w - u(78), fy + u(13), u(18), false, at >= pages)
        self:hit(u(30), fy, u(80), g.foot, function() self:turn(-1) end)
        self:hit(self.w - u(110), fy, u(80), g.foot, function() self:turn(1) end)
    end
end

return Reorder
