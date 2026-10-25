--[[--
This Kindle's ID, to add it from Syncthing on a phone or computer: a box over
the app drawn as the launcher's pop-ups (title, the ID as a QR code and as
text, icon buttons Copy and Done). A tap outside or Back closes it.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Canvas = require("stcanvas")
local KO = require("stko")

local Screen = Device.screen
local C = Canvas

local Box = InputContainer:extend{
    id = nil,
    say = nil,   -- a short notice (Copied)
}

function Box:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    -- A firm pen press is a hold: it does what a tap does.
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    self:render()
end

function Box:render()
    local c = Canvas.new(self.w, self.h)
    self.canvas = c
    local bw = math.min(c.W - 60, 460)
    local x = (c.W - bw) / 2
    local qr = math.floor(bw * 0.62)
    local h = 60 + qr + 100 + 76 + 10
    local y = math.max(40, (c.H - h) / 2)
    c:box(x + 5, y + 5, bw, h, { r = 12, fill = C.MID })
    c:box(x, y, bw, h, { r = 12, fill = C.WHITE, border = C.BLACK, bw = 2 })
    self.rect = { x - 2, y - 2, bw + 9, h + 9 }
    -- Taps inside the box but on nothing do nothing.
    c:hit(x, y, bw, h, function() end)
    c:text(x + 18, y + 30, _("This Kindle's ID"), 14, { bold = true })
    c:hline(x, y + 46, bw, C.BLACK, 1.5)
    local px = c:X(qr)
    local image = QRWidget:new{ text = self.id, width = px, height = px }.image
    if image then
        local iw = image:getWidth() / c.u
        c:image(image, x + (bw - iw) / 2, y + 60)
    end
    local ty = y + 60 + qr + 26
    local first, rest = self.id:match("^([^-]+%-[^-]+%-[^-]+%-[^-]+%-)(.*)$")
    c:text(x + bw / 2, ty, first or self.id, 12, { bold = true, align = "middle" })
    if rest then c:text(x + bw / 2, ty + 18, rest, 12, { bold = true, align = "middle" }) end
    c:text(x + bw / 2, ty + 46, _("In Syncthing on your computer or phone: Add Remote Device,"), 10.5, { color = C.GREY, align = "middle", maxw = bw - 36 })
    c:text(x + bw / 2, ty + 62, _("then scan or type this ID."), 10.5, { color = C.GREY, align = "middle", maxw = bw - 36 })
    KO.iconButtons(c, C, x, y + h - 86, bw, {
        { icon = "copy", text = _("Copy"), copy = true },
        { icon = "check", text = _("Done"), primary = true },
    }, function(b)
        if b.copy then
            if Device.input and Device.input.setClipboardText then Device.input.setClipboardText(self.id) end
            if self.say then self.say(_("Copied")) end
        else
            self:close()
        end
    end)
end

function Box:region()
    local c, r = self.canvas, self.rect
    return Geom:new{ x = c:X(r[1]), y = c:X(r[2]), w = c:X(r[3]), h = c:X(r[4]) }
end

function Box:paintTo(bb, x, y)
    if self.canvas then self.canvas:paint(bb, x, y) end
end

function Box:onTap(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and hit.tap then hit.tap() else self:close() end
    return true
end

Box.onHold = Box.onTap

function Box:onClose()
    self:close()
    return true
end

function Box:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self, "full", self:region())
end

function Box:onCloseWidget()
    if self.canvas then self.canvas:release() end
end

local M = {}

function M.show(id, say)
    local box = Box:new{ id = id, say = say }
    UIManager:show(box, "ui", box:region())
    return box
end

return M
