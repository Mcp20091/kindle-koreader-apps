--[[--
The output page with the launcher (KOReader's TextViewer without it, in
sshrun): the title bar with ✕, what the command printed in a monospace font
(long-press a word to copy it, or long-press and drag to copy a part), in
pages (swipe, or ‹ n/m ›), and a row of icon buttons (sshbuttons): Find,
Copy all, the AI's Explain and Summarize, and Run again.

    Out.show{ title, text, buttons = { { icon, text, primary, fn(page) } }, onClose, popup }

With `popup`: a box over the page under it (most of the width, about two thirds of the
height) with its title and ✕, closed by a tap outside it too, dragged by its title bar
(a finger, the pen held then moved, or a flick), as the launcher's pop-ups are. The text's size follows SSH
settings > Text size (the live session's), 18 at its usual 14.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

local Foot = require("sshbuttons")
local KO = require("sshko")

local Out = InputContainer:extend{
    title = "",
    text = "",
    buttons = nil,
    onClosed = nil,
    popup = false,
    covers_fullscreen = true,
}

-- The output's text size: SSH settings > Text size (KOReader's terminal size), scaled so
-- its usual 14 gives the 18 this page always had.
local function textSize()
    return math.floor(G_reader_settings:readSetting("terminal_font_size", 14) * 18 / 14 + 0.5)
end

function Out:init()
    if self.popup then return self:initPopup() end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local range = function() return self.dimen end
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = range } },
        -- a word or a part copied (KOReader's text selection, as in its TextViewer)
        HoldStartText = { GestureRange:new{ ges = "hold", range = range } },
        HoldPanText = { GestureRange:new{ ges = "hold", range = range } },
        HoldReleaseText = { GestureRange:new{ ges = "hold_release", range = range },
            args = function(text, __, start_idx, end_idx)
                Device.input.setClipboardText(text)
                KO.toast(start_idx == end_idx and _("Word copied.") or _("Copied."))
            end },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    local w, h = self.dimen.w, self.dimen.h
    local pad = Size.padding.large
    -- the apps' title bar (‹, ⌂, recent apps, the clock, ⟳, 🔔, ⋮)
    local title = require("sshbar"):new{
        title = self.title,
        on_back = function() self:onClose() end,
        on_home = function()
            self:onClose()
            require("sshui").home()
        end,
        on_refresh = function() UIManager:setDirty(self, "full") end,
        on_menu = function() require("sshui").more() end,
    }
    title:tick(self)
    self.foot = Foot:new{ width = w, buttons = self.buttons, show_parent = self,
        turn = function(d) self:turn(d) end }
    local gap = Size.padding.default
    self.scroll = ScrollTextWidget:new{
        text = self.text,
        face = Font:getFace("smallinfont", textSize()),
        width = w - 2 * pad,
        height = h - title:getHeight() - self.foot:getSize().h - 2 * gap,
        dialog = self,
        justified = false,
        scroll_callback = function() self:pageChanged() end,
    }
    self[1] = FrameContainer:new{
        width = w, height = h, background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0,
        VerticalGroup:new{ align = "center", title, VerticalSpan:new{ width = gap }, self.scroll,
            VerticalSpan:new{ width = gap }, self.foot },
    }
    self:pageChanged()
end

-- The pop-up: the box in the middle of the screen, the page under it showing round it.
function Out:initPopup()
    self.covers_fullscreen = false
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    local w, h = math.floor(sw * 0.92), math.floor(sh * 0.62)
    self.box = Geom:new{ x = math.floor((sw - w) / 2), y = math.floor((sh - h) / 2), w = w, h = h }
    local range = function() return self.dimen end
    -- (the title bar drags it; below it, holds select the text)
    local below = function()
        local t = self.titleH or 0
        return Geom:new{ x = self.box.x, y = self.box.y + t, w = self.box.w, h = self.box.h - t }
    end
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = function() return self.box end } },
        TapOutside = { GestureRange:new{ ges = "tap", range = range } },
        Pan = { GestureRange:new{ ges = "pan", range = range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        HoldTitle = { GestureRange:new{ ges = "hold", range = function() return self:titleRect() end } },
        HoldPanTitle = { GestureRange:new{ ges = "hold_pan", range = range } },
        HoldReleaseTitle = { GestureRange:new{ ges = "hold_release", range = range } },
        HoldStartText = { GestureRange:new{ ges = "hold", range = below } },
        HoldPanText = { GestureRange:new{ ges = "hold", range = below } },
        HoldReleaseText = { GestureRange:new{ ges = "hold_release", range = below },
            args = function(text, __, start_idx, end_idx)
                Device.input.setClipboardText(text)
                KO.toast(start_idx == end_idx and _("Word copied.") or _("Copied."))
            end },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    local border = Size.border.window
    local inner = w - 2 * border
    local title = require("ui/widget/titlebar"):new{
        width = inner, title = self.title, title_shrink_font_to_fit = true, with_bottom_line = true,
        close_callback = function() self:onClose() end, show_parent = self,
    }
    self.titleH = border + title:getHeight()
    self.foot = Foot:new{ width = inner, buttons = self.buttons, show_parent = self, center = true,
        turn = function(d) self:turn(d) end }
    local pad, gap = Size.padding.large, Size.padding.default
    self.scroll = ScrollTextWidget:new{
        text = self.text,
        face = Font:getFace("smallinfont", textSize()),
        width = inner - 2 * pad,
        height = h - 2 * border - title:getHeight() - self.foot:getSize().h - 2 * gap,
        dialog = self,
        justified = false,
        scroll_callback = function() self:pageChanged() end,
    }
    self.frame = FrameContainer:new{
        width = w, height = h, background = Blitbuffer.COLOR_WHITE, bordersize = border,
        radius = Size.radius.window, padding = 0,
        VerticalGroup:new{ align = "center", title, VerticalSpan:new{ width = gap }, self.scroll,
            VerticalSpan:new{ width = gap }, self.foot },
    }
    self[1] = self.frame
    self:pageChanged()
end

-- (The pop-up drawn where it is: the middle of the screen, or where it was dragged.)
function Out:paintTo(bb, x, y)
    if not self.box then return InputContainer.paintTo(self, bb, x, y) end
    self.frame:paintTo(bb, x + self.box.x, y + self.box.y)
end

function Out:titleRect()
    local b = self.box
    return Geom:new{ x = b.x, y = b.y, w = b.w, h = self.titleH or 0 }
end

function Out:inTitle(pos) return pos and self.box and pos:intersectWith(self:titleRect()) end

function Out:startDrag(pos)
    self.drag = { px = pos.x, py = pos.y, x0 = self.box.x, y0 = self.box.y }
end

-- Where the finger is now, kept on the screen: drawn again now and then (every 12 pixels
-- and 0.15 s at most, as e-ink can), and where it ends.
function Out:dragTo(pos, final)
    local d = self.drag
    if not (d and pos) then return end
    local nx = math.max(0, math.min(self.dimen.w - self.box.w, d.x0 + pos.x - d.px))
    local ny = math.max(0, math.min(self.dimen.h - self.box.h, d.y0 + pos.y - d.py))
    local now = require("socket").gettime()
    if not final and ((math.abs(nx - self.box.x) + math.abs(ny - self.box.y)) < 12 or (d.at and now - d.at < 0.15)) then return end
    d.at = now
    self.box.x, self.box.y = nx, ny
    UIManager:setDirty("all", "fast")
end

function Out:endDrag(pos)
    if not self.drag then return false end
    self:dragTo(pos, true)
    self.drag = nil
    -- (a clean picture where it ends: e-ink leaves ghosts of the steps on the way)
    UIManager:setDirty("all", "full")
    return true
end

function Out:onPan(__, ges)
    if not self.box then return end
    if not self.drag then
        local start = ges.start_pos or ges.pos
        if not self:inTitle(start) then return true end
        self:startDrag(start)
    end
    self:dragTo(ges.pos)
    return true
end

function Out:onPanRelease(__, ges)
    if self:endDrag(ges and ges.pos) then return true end
end

function Out:onHoldTitle(__, ges)
    self.holdStart = ges and ges.pos
    return true
end

function Out:onHoldPanTitle(__, ges)
    if not (self.box and (self.drag or (self.holdStart and self:inTitle(self.holdStart)))) then return end
    if not self.drag then self:startDrag(self.holdStart) end
    self:dragTo(ges.pos)
    return true
end

function Out:onHoldReleaseTitle(__, ges)
    self.holdStart = nil
    if self:endDrag(ges and ges.pos) then return true end
end

-- A tap outside the pop-up closes it (inside, its own parts take their taps).
function Out:onTapOutside(__, ges)
    if self.box and not ges.pos:intersectWith(self.box) then return self:onClose() end
end

function Out:pageChanged()
    if self.foot then self.foot:setPage(Foot.pageOf(self.scroll)) end
end

function Out:turn(d)
    self.scroll:scrollText(d)
    self:pageChanged()
    -- (the pop-up's new page clean: e-ink keeps a ghost of the last one)
    if self.box then UIManager:setDirty(self, function() return "full", self.box end) end
end

function Out:onSwipe(__, ges)
    -- (a quick flick on the pop-up's title bar: it moves by as much)
    if self.box and ges.end_pos and self:inTitle(ges.pos) then
        self:startDrag(ges.pos)
        self:endDrag(ges.end_pos)
        return true
    end
    if KO.fromLeftEdge(ges) then return self:onClose() end
    local dir = ges.direction
    if dir == "west" or dir == "north" then self:turn(1) return true end
    if dir == "east" or dir == "south" then self:turn(-1) return true end
end

function Out:onClose()
    if self.closed then return true end
    self.closed = true
    UIManager:close(self, "full")
    if self.onClosed then self.onClosed() end
    return true
end

--- Find: a word in the output (again: the next one).
function Out:find()
    local request = KO.request()
    if not request then return end
    request{ title = _("Find"), text = self.search or "", hint = _("Text to find"), typing = true, buttons = {
        { icon = "x", text = _("Cancel"), cancel = true },
        { icon = "search", text = _("Find"), primary = true, needsText = true, fn = function(t)
            if t ~= self.search then self.found = nil end
            self.search = t
            local pos
            pos, self.charlist = util.stringSearch(self.charlist or self.text, t, false, (self.found or 0) + 1)
            if not pos or pos <= 0 then
                self.found = nil
                return KO.toast(_("Not found."))
            end
            self.found = pos
            self.scroll:moveCursorToCharPos(pos, 3)
            self:pageChanged()
        end },
    } }
end

--- Shows the output page.
function Out.show(o)
    local page = Out:new(o)
    -- (a clean picture: the page under it may have ghosts that would show round it)
    UIManager:show(page, "full")
    return page
end

return Out
