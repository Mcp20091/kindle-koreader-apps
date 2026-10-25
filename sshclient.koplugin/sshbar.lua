--[[--
The shared title bar on SSH's list pages, drawn by sshtitle.lua (the same
code as the other apps):

    ‹  ⌂  Title         [the page's buttons]  12:45  ▭ 80%   ⟳   🔔   ⋮

‹ Back (on the top page, to the Apps launcher), ⌂ Home (the launcher), the
title, then the page's own buttons, the clock and battery, ⟳ Refresh,
🔔 Notifications (with the unread count) and ⋮. ⌂ and 🔔
need the Apps plugin. It takes the place of KOReader's TitleBar in a Menu
(custom_title_bar), so it has the calls Menu makes on one.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local Canvas = require("sshcanvas")
local Title = require("sshtitle")

Canvas.setDir((debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."))

local Bar = InputContainer:extend{
    title = "",
    buttons = nil,      -- the page's own: { { "icon", fn } }
    on_back = nil,
    on_home = nil,
    on_refresh = nil,
    on_menu = nil,
}

local function PS() return require("pluginshare") end

function Bar:init()
    self.width = Screen:getWidth()
    local u = math.min(Screen:getWidth(), Screen:getHeight()) / 620
    -- 44 units and the 2-unit line under it
    self.height = math.floor(46 * u + 0.5)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    -- (a firm pen press lasts long enough to be a hold: it taps too)
    local range = function() return self.dimen end
    self.ges_events = {
        TapBar = { GestureRange:new{ ges = "tap", range = range } },
        HoldBar = { GestureRange:new{ ges = "hold", range = range } },
    }
end

function Bar:draw()
    -- (a canvas the size of the screen: its units are the screen's)
    local c = Canvas.new(Screen:getWidth(), Screen:getHeight())
    local ps = PS()
    Title.draw(c, {
        title = self.title,
        back = self.on_back,
        home = ps.appsHome and self.on_home or nil,
        buttons = self.buttons,
        clock = true,
        twentyFour = not G_reader_settings:isTrue("twelve_hour_clock"),
        refresh = self.on_refresh,
        bell = ps.showNotifications and function() ps.showNotifications() end or nil,
        menu = self.on_menu,
    })
    return c
end

function Bar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.canvas = self:draw()
    self.canvas:paint(bb, x, y)
    -- (back on top: the clock ticks again)
    if self._tick and not self.ticking then self:schedule() end
end

function Bar:onTapBar(__, ges)
    local c = self.canvas
    if not c then return false end
    local h = c:find(ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y)
    if h and h.tap then
        UIManager:nextTick(h.tap)
        return true
    end
    return true
end

function Bar:onHoldBar(__, ges) return self:onTapBar(__, ges) end

function Bar:getHeight() return self.height end
function Bar:getSize() return Geom:new{ w = self.width, h = self.height } end
function Bar:setTitle(title) self.title = title end
-- (the shared bar has no subtitle)
function Bar:setSubTitle() end
function Bar:generateVerticalLayout() return {} end
function Bar:setLeftIcon() end

--- Redraws the clock at each minute while `page` is on top; it stops when
-- something else is, and starts again when the bar is drawn. stop() ends it.
function Bar:tick(page)
    self:stop()
    self.page = page
    self._tick = function()
        self.ticking = false
        if UIManager:getTopmostVisibleWidget() ~= page then return end
        UIManager:setDirty(page, "ui", self.dimen)
        self:schedule()
    end
    self:schedule()
end

function Bar:schedule()
    self.ticking = true
    UIManager:scheduleIn(60 - tonumber(os.date("%S")), self._tick)
end

function Bar:stop()
    if self._tick then UIManager:unschedule(self._tick) end
    self.ticking = false
    self._tick = nil
end

--- The bar in place of a KOReader InputDialog's title (the full-screen
-- editor, the live session), the same height. opts: Bar's fields (title,
-- on_back, on_home, on_refresh, on_menu).
function Bar.swapInto(dialog, opts)
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    if o.title == nil then o.title = dialog.title end
    local bar = Bar:new(o)
    local h = dialog.title_bar:getHeight()
    bar.height, bar.dimen.h = h, h
    for i, w in ipairs(dialog.vgroup) do
        if w == dialog.title_bar then dialog.vgroup[i] = bar end
    end
    dialog.vgroup:resetLayout()
    if dialog.ssh_bar then dialog.ssh_bar:stop() end
    dialog.ssh_bar = bar
    bar:tick(dialog)
    return bar
end

--- An InputDialog dressed so: `bar_opts` (as swapInto's) and, optional,
-- `dress(dialog)` (more of the apps' look: the editor's icon row). KOReader
-- lays a dialog out again when its keyboard shows or hides: dressed again then.
function Bar.dialogClass()
    if Bar.Dialog then return Bar.Dialog end
    local InputDialog = require("ui/widget/inputdialog")
    local D = InputDialog:extend{}
    function D:init()
        InputDialog.init(self)
        if self.bar_opts then Bar.swapInto(self, self.bar_opts) end
        if self.dress then self:dress() end
    end
    Bar.Dialog = D
    return D
end

return Bar
