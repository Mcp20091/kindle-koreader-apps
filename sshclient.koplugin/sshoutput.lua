--[[--
The output page with the launcher (KOReader's TextViewer without it, in
sshrun): the title bar with ✕, what the command printed in a monospace font
(long-press a word to copy it, or long-press and drag to copy a part), in
pages (swipe, or ‹ n/m ›), and a row of icon buttons (sshbuttons): Find,
Copy all, the AI's Explain and Summarize, and Run again.

    Out.show{ title, text, buttons = { { icon, text, primary, fn(page) } }, onClose }
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
    covers_fullscreen = true,
}

function Out:init()
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
        face = Font:getFace("smallinfont", 18),
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

function Out:pageChanged()
    if self.foot then self.foot:setPage(Foot.pageOf(self.scroll)) end
end

function Out:turn(d)
    self.scroll:scrollText(d)
    self:pageChanged()
end

function Out:onSwipe(__, ges)
    if KO.fromLeftEdge(ges) then return self:onClose() end
    local dir = ges.direction
    if dir == "west" or dir == "north" then self:turn(1) return true end
    if dir == "east" or dir == "south" then self:turn(-1) return true end
end

function Out:onClose()
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
    UIManager:show(page, "full")
    return page
end

return Out
