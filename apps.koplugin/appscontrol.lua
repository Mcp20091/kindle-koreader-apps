--[[--
The control center: a tap on the time and battery in any app's title bar
(the launcher's battery and Wi-Fi, and the bar over a book or the library),
or More under the launcher's clock, drops down a panel over the top of the
screen with every quick button (appsquick.lua; Wi-Fi, night mode, refresh,
the web server and Keep awake are always there), groups dropped down in it,
the light and its warmth, and the battery. A tap outside it or a swipe up
closes it. Loaded the first time it opens.

PluginShare.showControlCenter() opens it from anywhere.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("appscanvas")
local KO = require("appsko")

local Screen = Device.screen
local C = Canvas
local PluginShare = require("pluginshare")

local CC = {}

-- ------------------------------------------------------------------ keep awake

-- Keeping the Kindle awake, shared with the web server and Home Assistant's
-- dashboard (PluginShare.awake_reasons: each asks for itself; it sleeps again
-- once none asks), as they do it.
local function stayAwake(who, on)
    local reasons = PluginShare.awake_reasons or {}
    PluginShare.awake_reasons = reasons
    reasons[who] = on and true or nil
    local any = next(reasons) ~= nil
    PluginShare.pause_auto_suspend = any or nil
    if Device:isKindle() and (PluginShare.kindle_kept_awake or false) ~= any then
        PluginShare.kindle_kept_awake = any
        if any then
            PluginShare.keepalive_ours = not PluginShare.keepalive
            PluginShare.keepalive = true
        elseif PluginShare.keepalive_ours then
            PluginShare.keepalive_ours = nil
            PluginShare.keepalive = false
        end
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (any and "1" or "0") .. " >/dev/null 2>&1")
        require("logger").info("Kindle", any and "kept awake" or "may sleep again")
    end
end

function CC.keptAwake() return PluginShare.awake_reasons and PluginShare.awake_reasons.apps == true or false end
function CC.keepAwake(on) stayAwake("apps", on) end

-- ------------------------------------------------------------------ the light

local function powerd() return Device:getPowerDevice() end

--- The light: { on, level, min, max } or nil without one.
local function light()
    if not Device:hasFrontlight() then return nil end
    local p = powerd()
    local ok, level = pcall(function() return p:frontlightIntensity() end)
    return { on = p:isFrontlightOn(), level = ok and level or 0, min = p.fl_min or 0, max = p.fl_max or 24 }
end

local function warmth()
    if not (Device.hasNaturalLight and Device:hasNaturalLight()) then return nil end
    local p = powerd()
    local ok, w = pcall(function() return p:frontlightWarmth() end)
    return { level = ok and w or 0, min = 0, max = 100 }
end

-- ------------------------------------------------------------------ the panel

local Panel = InputContainer:extend{
    kui = nil,         -- the library or book under it
    koMenu = nil,      -- KOReader's menu (over a book or the library)
    open = nil,        -- the quick buttons' group dropped down (its key)
}

local shown

function Panel:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    -- (As the shared pop-ups: its taps its own even with KOReader's keyboard above it.)
    self.is_always_active = true
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = all } },
        Hold = { GestureRange:new{ ges = "hold", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    self:render()
end

function Panel:settings()
    local s = G_reader_settings:readSetting("apps")
    return type(s) == "table" and s or {}
end

--- A level: − , a bar filled as far as it goes (tap a spot to go there), +.
local function slider(c, y, label, icon, v, set)
    c:icon(icon, 28, y + 11, 18)
    c:text(54, y + 25, label, 12, { bold = true })
    local x0, x1 = 170, c.W - 84
    c:circle(x0 - 20, y + 20, 15, C.BLACK, 1.2)
    c:icon("minus", x0 - 29, y + 11, 18)
    c:hit(x0 - 40, y, 40, 40, function() set(v.level - math.max(1, math.floor((v.max - v.min) / 10))) end)
    c:box(x0 + 10, y + 14, x1 - x0 - 20, 12, { r = 6, border = C.BLACK, bw = 1.2 })
    local f = v.max > v.min and (v.level - v.min) / (v.max - v.min) or 0
    if f > 0 then c:box(x0 + 10, y + 14, (x1 - x0 - 20) * math.min(1, f), 12, { r = 6, fill = C.FILL }) end
    c:hit(x0 + 4, y, x1 - x0 - 8, 40, function(px)
        -- (a tap's spot: set by onTap)
        set(v.min + math.floor((v.max - v.min) * (px or f) + 0.5))
    end)
    c:circle(x1 + 20, y + 20, 15, C.BLACK, 1.2)
    c:icon("plus", x1 + 11, y + 11, 18)
    c:hit(x1, y, 40, 40, function() set(v.level + math.max(1, math.floor((v.max - v.min) / 10))) end)
    c:text(c.W - 28, y + 25, tostring(v.level), 11, { align = "end", color = C.GREY })
    return { x0 = x0 + 10, x1 = x1 - 10 }
end

function Panel:render()
    if self.canvas then self.canvas:release() end
    local c = Canvas.new(self.w, self.h, false)
    self.canvas = c
    self.sliders = {}
    local s = self:settings()
    local y = 0
    -- Room for it: drawn first as a white sheet, its height known at the end.
    local ops = #c.ops
    -- The time, the date and the battery.
    local now = os.date("*t")
    local clock = require("appsko").twentyFour() and string.format("%02d:%02d", now.hour, now.min)
        or string.format("%d:%02d %s", (now.hour + 11) % 12 + 1, now.min, now.hour < 12 and "AM" or "PM")
    c:text(28, y + 46, clock, 26, { bold = true })
    c:text(28 + c:width(clock, 26, true) + 14, y + 46, os.date("%A, %B ") .. now.day, 12, { color = C.GREY })
    local p = powerd()
    local okB, pct = pcall(function() return p:getCapacity() end)
    local okC, charging = pcall(function() return p:isCharging() end)
    if okB and pct then
        local label = charging and T(_("%1% · Charging"), pct) or (pct .. "%")
        local lw = c:width(label, 12)
        c:text(c.W - 28, y + 44, label, 12, { align = "end" })
        local bx = c.W - 28 - lw - 30
        c:icon(okC and charging and "battery-charging" or "battery", bx, y + 26, 24)
        if not (okC and charging) and pct > 0 then
            local k = 24 / 24
            c:box(bx + 4.5 * k, y + 26 + 8.5 * k, 11 * k * math.min(100, pct) / 100, 7 * k, { fill = C.BLACK })
        end
        -- The Battery screen (what uses it), in Apps.
        c:hit(bx - 10, y + 10, c.W - bx, 50, function() self:close() CC.batteryScreen() end)
    end
    y = y + 70
    -- Every quick button, then the ones a control center always has (when not among them).
    local Quick = require("appsquick")
    local list = {}
    for __, e in ipairs(require("appsmodel").quickList(s)) do table.insert(list, e) end
    for __, e in ipairs(Quick.coreMissing(list)) do table.insert(list, e) end
    y = y + Quick.drawAll(c, y, list, self.open, function(key)
        self.open = self.open ~= key and key or nil
        self:refresh()
    end, function(mode)
        if self.closed then return end
        if mode == "full" then self:refresh("full") else UIManager:scheduleIn(0.3, function() if not self.closed then self:refresh() end end) end
    end, function() self:close() end, {
        -- More rows than fit: pages (‹ 1/2 ›).
        page = self.page or 1,
        turn = function(delta) self.page = math.max(1, (self.page or 1) + delta) self:refresh() end,
    }) + 4
    local l = light()
    if l then
        local sl = slider(c, y, l.on and _("Light") or _("Light off"), "sun", l, function(v)
            local pd = powerd()
            v = math.max(l.min, math.min(l.max, v))
            if v > l.min and not pd:isFrontlightOn() then pd:turnOnFrontlight() end
            pd:setIntensity(v)
            self:refresh()
        end)
        sl.y = y
        sl.v = l
        table.insert(self.sliders, sl)
        y = y + 50
    end
    local w = warmth()
    if w then
        local sl = slider(c, y, _("Warmth"), "flame", w, function(v)
            powerd():setWarmth(math.max(0, math.min(100, v)))
            self:refresh()
        end)
        sl.y = y
        sl.v = w
        table.insert(self.sliders, sl)
        y = y + 50
    end
    -- Over a book or the library: KOReader's own menu is a tap away. Settings (cog) and the
    -- quick buttons' editor (pencil, the launcher's Settings > Quick buttons) sit at the right.
    local PS = require("pluginshare")
    local icons = {}
    if PS.showSettings then table.insert(icons, { "settings", function() self:close() PS.showSettings() end }) end
    if PS.appsApps and PS.appsApps() then
        table.insert(icons, { "pencil", function()
            self:close()
            PS.appsApps():showMode("quick")
        end })
    end
    if self.koMenu or #icons > 0 then
        if self.koMenu then
            local label = _("KOReader menu")
            local bw = c:width(label, 11.5, true) + 32
            c:box(28, y + 4, bw, 34, { r = 17, border = C.BLACK })
            c:text(28 + bw / 2, y + 26, label, 11.5, { bold = true, align = "middle" })
            c:hit(28, y, bw, 42, function() self:close() self.koMenu() end)
        end
        local x = c.W - 28 - 34
        for i = #icons, 1, -1 do
            c:box(x, y + 4, 34, 34, { r = 17, border = C.BLACK })
            c:icon(icons[i][1], x + 8, y + 12, 18)
            c:hit(x - 4, y, 42, 42, icons[i][2])
            x = x - 44
        end
        y = y + 50
    end
    y = y + 6
    -- The grip at the bottom: swipe up (or tap outside) to close.
    c:box(c.W / 2 - 24, y, 48, 4, { r = 2, fill = C.LIGHT })
    y = y + 14
    -- The sheet under all of it, and its edge.
    local h = y
    table.insert(c.ops, ops + 1, function(bb, ox, oy) bb:paintRect(ox, oy, c:X(c.W), c:X(h), C.WHITE) end)
    c:hline(0, h, c.W, C.BLACK, 2)
    self.panelH = c:X(h) + 2
    -- Taps on the panel but on nothing stay in it.
    table.insert(c.hits, 1, { x = 0, y = 0, w = c:X(c.W), h = self.panelH, tap = function() end })
end

function Panel:region() return Geom:new{ x = 0, y = 0, w = self.w, h = self.panelH } end

function Panel:refresh(mode)
    local before = self:region()
    self:render()
    UIManager:setDirty(self, mode or "ui", before:combine(self:region()))
end

function Panel:paintTo(bb, x, y)
    if self.canvas then self.canvas:paint(bb, x, y) end
end

function Panel:onTap(_, ges)
    if ges.pos.y > self.panelH then self:close() return true end
    -- A tap on a slider's bar: its level at that spot.
    for __, sl in ipairs(self.sliders) do
        local c = self.canvas
        local bx0, bx1, by = c:X(sl.x0), c:X(sl.x1), c:X(sl.y)
        if ges.pos.x >= bx0 and ges.pos.x <= bx1 and ges.pos.y >= by and ges.pos.y <= by + c:X(40) then
            local hit = c:find(ges.pos.x, ges.pos.y)
            if hit and hit.tap then hit.tap((ges.pos.x - bx0) / math.max(1, bx1 - bx0)) end
            return true
        end
    end
    local hit = self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and hit.tap then hit.tap() end
    return true
end

-- A hold: what's behind a button (its hold), else as a tap.
function Panel:onHold(_, ges)
    if ges.pos.y > self.panelH then self:close() return true end
    local hit = self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and hit.hold then
        self:close()
        hit.hold()
        return true
    end
    return self:onTap(_, ges)
end

function Panel:onSwipe(_, ges)
    if ges.direction == "north" or ges.pos.y > self.panelH then self:close() end
    return true
end

function Panel:onClose()
    self:close()
    return true
end

function Panel:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self, "full", self:region())
end

function Panel:onCloseWidget()
    if self.canvas then self.canvas:release() end
    if shown == self then shown = nil end
    -- The keyboard it put aside: back, unless what the panel opened is on screen now.
    if self.keyboardBack then
        local back = self.keyboardBack
        self.keyboardBack = nil
        UIManager:nextTick(function()
            local top = UIManager:getTopmostVisibleWidget()
            if top and (top.is_shared_popup or (top.covers_fullscreen and top ~= self.under)) then return end
            back()
        end)
    end
end

--- The open library or book.
local function currentUI()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if ReaderUI and ReaderUI.instance then return ReaderUI.instance end
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    return FileManager and FileManager.instance
end

--- The Battery screen of Apps.
function CC.batteryScreen()
    local ui = currentUI()
    local apps = ui and ui.apps
    if not apps then return end
    apps:show()
    local PS = require("pluginshare")
    if PS.appsView then
        local v = PS.appsView()
        if v then v.mode, v.batteryPage = "battery", 1 v:refresh() end
    end
end

--- Shows it (koMenu: KOReader's menu, over a book or the library; open: a
-- quick buttons group to drop down, by its key).
function CC.show(koMenu, open)
    if shown then return end
    -- (KOReader keeps its keyboard above every window, where it would take the panel's taps and
    -- pass them to the screen under it, such as SSH's live session: aside while the panel is open.)
    local back = require("appspopup").keyboardAside()
    local under = UIManager:getTopmostVisibleWidget()
    shown = Panel:new{ kui = currentUI(), koMenu = koMenu, open = open }
    shown.keyboardBack, shown.under = back, under
    UIManager:show(shown, "ui", shown:region())
end

return CC
