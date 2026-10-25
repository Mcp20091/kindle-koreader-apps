--[[--
A QR code, full screen, for every app (PS.showQR): the code as large as the
screen allows (a phone reads it best that way on e-ink), a line under it saying
what it's for (the address, "Scan to sign in"…), and Close. A tap anywhere or
the Back key closes it too; the whole screen gets a full refresh then, so no
ghost of the code stays behind.

    PS.showQR{ text = url, caption = _("Scan with your phone to open the web page") }
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Screen = Device.screen

local QR = InputContainer:extend{
    covers_fullscreen = true,
    text = "",
    caption = nil,
}

function QR:init()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    local size = math.floor(math.min(w, h) * 0.72)
    local group = VerticalGroup:new{ align = "center",
        QRWidget:new{ text = self.text, width = size, height = size },
    }
    local captions = {}
    if self.caption and self.caption ~= "" then table.insert(captions, self.caption) end
    if self.showText ~= false and self.text ~= "" and self.text ~= self.caption then table.insert(captions, self.text) end
    if #captions > 0 then
        table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(24) })
        table.insert(group, TextBoxWidget:new{
            text = table.concat(captions, "\n"),
            face = Font:getFace("cfont", 22),
            width = math.floor(w * 0.85),
            alignment = "center",
        })
    end
    table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(28) })
    table.insert(group, Button:new{
        text = _("Close"),
        width = Screen:scaleBySize(180),
        bordersize = Screen:scaleBySize(2),
        radius = Screen:scaleBySize(20),
        callback = function() self:close() end,
    })
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, group },
    }
    -- (A hold as a tap: a firm press of the pen lasts long enough to be a hold.)
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } } }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
end

function QR:onTap()
    -- (The Close button takes its own taps; anywhere else closes too.)
    self:close()
    return true
end

function QR:onHold() return self:onTap() end

function QR:onClose()
    self:close()
    return true
end

function QR:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    if self.on_close then self.on_close() end
end

local M = {}

--- Shows a QR code full screen: o = { text, caption, showText = false (don't repeat the text
-- under it), onClose (called once it's closed, however: Close, a tap or Back) }.
function M.show(o)
    if type(o) == "string" then o = { text = o } end
    local w = QR:new{ text = o.text or "", caption = o.caption, showText = o.showText, on_close = o.onClose }
    UIManager:show(w, "full")
    return w
end

function M.install()
    require("pluginshare").showQR = M.show
end

return M
