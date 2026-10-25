--[[--
The full-screen Home Assistant view: Home, a room, cameras, media, scenes and
scripts, security, climate, weather, activity, batteries, a 3D printer, search
results and the dashboard, drawn on a Canvas (hacanvas.lua). Tiles come as
cards, big tiles, a list or minimal (Settings).
Controls for one entity open as a sheet from the bottom (hasheet.lua);
settings, reordering and device picking are in hasettings.lua.

Fingers: tap a tile to switch it, hold it for its controls; swipe left/right
(or up/down) to turn pages; the arrow at the top left goes back.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("hacanvas")
local KO = require("hako")
local Model = require("hamodel")
local Sheet = require("hasheet")
local Settings = require("hasettings")
local Routines = require("haroutines")

local Screen = Device.screen
local C = Canvas

-- Not modal: KOReader puts a dialog that is not modal (a list to choose from,
-- a menu, a text box) under a modal screen, out of sight.
local View = InputContainer:extend{
    covers_fullscreen = true,
    flash_on_uncover = true,   -- a full refresh when a dialog over it closes (KO.flashOnUncover)
    ha = nil,          -- the plugin (main.lua): data, settings, network
    start = nil,       -- "home", "dashboard" or a screen: { kind = "room", name = "Kitchen" }
}

function View:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = all } },
        Hold = { GestureRange:new{ ges = "hold", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    self.route = type(self.start) == "table" and self.start or { kind = self.start or "home" }
    self.stack = {}
    self.pageNo = 1
    self:render()
end

-- ------------------------------------------------------------------ navigation

function View:go(route)
    table.insert(self.stack, { route = self.route, pageNo = self.pageNo })
    self.route, self.pageNo, self.sheet = route, 1, nil
    self:onRouteChanged()
    self:refresh("full")
end

function View:back()
    if self.sheet then return self:closeSheet() end
    local prev = table.remove(self.stack)
    -- From the screen it opened on: back to Apps (or what was under it).
    if not prev then
        self:close()
        KO.home()
        return
    end
    self.route, self.pageNo = prev.route, prev.pageNo
    self:onRouteChanged()
    self:refresh("full")
end

-- What a screen needs once it is shown (camera pictures, the dashboard's clock).
function View:onRouteChanged()
    self.ha:cancelJobs("picture")
    self.ha:screenChanged(self.route.kind)
    if self.route.kind == "dashboard" then self:scheduleClock() end
    UIManager:nextTick(function() self:loadPictures() end)
end

function View:turn(delta)
    local n = math.max(1, math.min(self.pages or 1, self.pageNo + delta))
    if n == self.pageNo then return end
    self.pageNo = n
    self:refresh("full")
    UIManager:nextTick(function() self:loadPictures() end)
end

function View:close()
    UIManager:close(self)
end

function View:onClose()
    self:back()
    return true
end


function View:onShow()
    KO.flashOnUncover()
    self:scheduleTitleClock()
end

function View:onCloseWidget()
    if self.clockTask then UIManager:unschedule(self.clockTask) end
    if self.settleTask then UIManager:unschedule(self.settleTask) end
    if self.titleTask then UIManager:unschedule(self.titleTask) end
    if self.canvas then self.canvas:release() end
    self.ha:viewClosed()
    UIManager:setDirty(nil, "full")
end

-- ------------------------------------------------------------------ KOReader's gestures

-- Gestures this screen does not use go to KOReader's Gestures plugin (the
-- light, night mode, your QuickMenus...), and the events their actions send
-- go on to the library or book underneath.
function View:onGesture(ev)
    if KO.passGesture(self:currentUI(), ev, KO.allowed) then return true end
    return InputContainer.onGesture(self, ev)
end

function View:handleEvent(event)
    if InputContainer.handleEvent(self, event) then return true end
    return KO.passEvent(self:currentUI(), event)
end

-- ------------------------------------------------------------------ gestures

function View:onTap(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and hit.tap then hit.tap() end
    return true
end

function View:onHold(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit then
        if hit.hold then hit.hold() elseif hit.tap then hit.tap() end
    end
    return true
end

function View:onSwipe(_, ges)
    local d = ges.direction
    -- A diagonal swipe (as in KOReader) flashes the screen clean.
    if d == "northeast" or d == "northwest" or d == "southeast" or d == "southwest" then
        UIManager:setDirty(self, "full")
        return true
    end
    -- In from the left edge: Back, as in every app (a sheet closes first).
    if KO.fromLeftEdge(ges) then self:back() return true end
    if self.sheet then return true end
    if d == "west" or d == "north" then self:turn(1)
    elseif d == "east" or d == "south" then self:turn(-1)
    end
    return true
end

-- ------------------------------------------------------------------ drawing

function View:paintTo(bb, x, y)
    self:checkSize()
    bb:paintRect(x, y, self.w, self.h, self.canvas and self.canvas:background() or Blitbuffer.COLOR_WHITE)
    if self.canvas then self.canvas:paint(bb, x, y) end
end

function View:render()
    if self.canvas then self.canvas:release() end
    local c = Canvas.new(self.w, self.h, self:isDark())
    self.canvas = c
    self.wantPictures, self.hasPictures, self.pictureRects = {}, false, {}
    local draw = View.screens[self.route.kind] or View.screens.home
    local snap = self.ha.snap
    if not snap and self.route.kind ~= "settings" and self.route.kind ~= "reorder" then
        self:titlebar(c, nil, _("Home Assistant"))
        c:text(310, 380, self.ha.error and self.ha.error or _("Connecting to Home Assistant…"), 12,
            { align = "middle", color = C.GREY, maxw = 580 })
        self.pages = 1
        return
    end
    self.pages = draw(self, c, snap) or 1
    if self.pageNo > self.pages then
        self.pageNo = self.pages
        return self:render()
    end
    if self.sheet then
        local e = snap and snap.byId[self.sheet]
        if e then Sheet.draw(self, c, e) else self.sheet = nil end
    end
    -- Pictures: every refresh of this screen with the Kindle's own dithering.
    self.dithered = self.hasPictures or nil
end

-- Dark mode (Settings): everywhere, or the dashboard only.
-- (Home Assistant's own dark mode is gone: KOReader's night mode is the one for every app.)
function View:isDark()
    return false
end

-- How tiles look (Settings): "cards", "big", "list" or "minimal".
function View:layout()
    return self.ha.prefs.layout or "cards"
end

-- Every few updates the screen flashes, clearing the ghosts e-ink keeps of
-- earlier screens (a diagonal swipe does it any time).
local FLASH_EVERY = 8

-- An update that moves things (tiles came or went, a sheet opened or
-- closed) is a full one too: a partial one leaves ghosts of where they were.
function View:refresh(mode, dither)
    local before = KO.layoutOf(self.canvas)
    self:render()
    mode = mode or "ui"
    if mode ~= "full" then
        if before ~= KO.layoutOf(self.canvas) then
            mode = "full"
        elseif mode ~= "fast" then
            self.updates = (self.updates or 0) + 1
            if self.updates % FLASH_EVERY == 0 then mode = "full" end
        end
    end
    UIManager:setDirty(self, mode, nil, dither or self.hasPictures)
end

-- After new states from Home Assistant.
function View:updated()
    self:refresh("ui")
    UIManager:nextTick(function() self:loadPictures() end)
end

--- A notification came or went (the shared list): the bell's badge.
function View:notificationsChanged()
    if self.canvas and UIManager:getTopmostVisibleWidget() == self then self:refresh("ui") end
end

--- A while after something was switched from a sheet or a menu (its state
-- back from Home Assistant by then): one full refresh, clearing what the
-- quick updates left.
function View:settle(seconds)
    if self.settleTask then UIManager:unschedule(self.settleTask) end
    self.settleTask = function()
        self.settleTask = nil
        if self.canvas and UIManager:getTopmostVisibleWidget() == self then
            self:render()
            UIManager:setDirty(self, "full", nil, self.hasPictures)
        end
    end
    UIManager:scheduleIn(seconds or 3, self.settleTask)
end


-- ------------------------------------------------------------------ turning the reader

-- The reader turned (its accelerometer): KOReader's own screen turns too, and
-- this one is laid out again for the new shape.
function View:onSetRotationMode(mode)
    local ui = self:currentUI()
    if ui then ui:handleEvent(Event:new("SetRotationMode", mode)) end
    if Screen:getRotationMode() ~= mode then Screen:setRotationMode(mode) end
    self:relayout()
    UIManager:setDirty("all", "full")
    return true
end

-- Sizes and tap areas from the screen as it is now.
function View:relayout()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    for __, g in pairs(self.ges_events or {}) do
        if g[1] and g[1].range then g[1].range = all end
    end
    self.pageNo = 1
    self:render()
end

-- Another screen of ours on top turned the reader: this one catches up when shown again.
function View:checkSize()
    if self.w ~= Screen:getWidth() or self.h ~= Screen:getHeight() then self:relayout() end
end

function View:currentUI()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if ReaderUI and ReaderUI.instance then return ReaderUI.instance end
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    return FileManager and FileManager.instance
end

-- ------------------------------------------------------------------ parts

-- ------------------------------------------------------------------ the Kindle's time and battery

--- The Kindle's battery: percent (nil when unknown) and whether it's charging.
local function kindleBattery()
    local powerd = Device:getPowerDevice()
    local ok, pct = pcall(function() return powerd:getCapacity() end)
    local ok2, charging = pcall(function() return powerd:isCharging() end)
    return ok and tonumber(pct) or nil, ok2 and charging == true
end

--- The battery icon (filled as far as charged) and its percent, from x, its
-- middle at cy, text `size` tall. Returns how wide it was (0: unknown).
function View:drawBattery(c, x, cy, size)
    local pct, charging = kindleBattery()
    if not pct then return 0 end
    local is = size * 1.6
    c:icon(charging and "battery-charging" or "battery", x, cy - is / 2, is)
    if not charging and pct > 0 then
        -- Inside Lucide's outline: 3..17 by 7..17 of 24.
        local k = is / 24
        c:box(x + 4.5 * k, cy - is / 2 + 8.5 * k, 11 * k * math.min(100, pct) / 100, 7 * k, { fill = C.BLACK })
    end
    local tw = c:text(x + is + 3, cy + size * 0.36, pct .. "%", size) or 0
    return is + 3 + tw
end

--- The time and battery on one line ending at x (its middle at cy). Returns how wide.
function View:drawStatus(c, x, cy, size)
    local pct = kindleBattery()
    local bw = 0
    if pct then
        bw = size * 1.6 + 3 + c:width(pct .. "%", size)
        self:drawBattery(c, x - bw, cy, size)
        bw = bw + 10
    end
    -- What's running now (the web server…), as every app's corner shows it.
    local PS = require("pluginshare")
    for __, icon in ipairs(PS.statusIcons and PS.statusIcons() or {}) do
        local is = size * 1.45
        c:icon(icon, x - bw - is, cy - is / 2, is)
        bw = bw + is + 8
    end
    local time, ampm = self:clockText()
    local clock = time .. (ampm and (" " .. ampm) or "")
    local tw = c:width(clock, size, true)
    c:text(x - bw, cy + size * 0.36, clock, size, { bold = true, align = "end" })
    return bw + tw
end

--- The time in the title bar, once a minute (only the bar; only when on top;
-- the dashboard has its own clock).
function View:scheduleTitleClock()
    if self.titleTask then UIManager:unschedule(self.titleTask) end
    self.titleTask = function()
        self.titleTask = nil
        if not self.canvas then return end
        if self.route.kind ~= "dashboard" and UIManager:getTopmostVisibleWidget() == self then
            self:render()
            UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.w, h = self.canvas:X(45) })
        end
        self:scheduleTitleClock()
    end
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), self.titleTask)
end

--- The title bar every app shares (see apps.koplugin/appsbar.lua):
-- ‹ back (from the first screen, to Apps), ⌂ Apps, the title; at the right
-- the screen's own buttons (`icons`, the first rightmost; "settings" and
-- "bell" are left out: Settings is in ⋮, the bell is always there), page
-- n/m, the time and battery, ⟳ (a screen's own { "refresh-cw", fn }, or
-- the states again; a full refresh either way), 🔔 and ⋮. `back` is no
-- longer needed: every screen has it.
function View:titlebar(c, back, title, icons, pages)
    local PS = require("pluginshare")
    local shared = PS.showNotifications ~= nil
    local reload
    local own = {}
    for __, item in ipairs(icons or {}) do
        local name, fn = item, nil
        if type(item) == "table" then name, fn = item[1], item[2] end
        if name == "refresh-cw" then reload = fn
        elseif name ~= "settings" and name ~= "bell" then table.insert(own, { name, fn }) end
    end
    c:rect(0, 0, c.W, 44, C.WHITE)
    c:hline(0, 44, c.W, C.BLACK, 2)
    c:icon("chevron-left", 12, 13, 18)
    c:hit(0, 0, 40, 44, function() self:back() end)
    local x = 42
    if PS.appsHome then
        c:icon("house", x + 2, 13, 18)
        c:hit(x - 4, 0, 34, 44, function() self:home() end)
        x = x + 36
    end
    -- Recent apps (Apps' switcher), next to ⌂.
    if PS.showSwitcher then
        c:icon("history", x + 2, 13, 18)
        c:hit(x - 4, 0, 34, 44, function() PS.showSwitcher() end)
        x = x + 36
    end
    -- From the right: ⋮, 🔔, ⟳.
    c:icon("ellipsis-vertical", c.W - 32, 13, 18)
    c:hit(c.W - 40, 0, 40, 44, function() self:titleAction("ellipsis-vertical") end)
    local bx = c.W - 66
    local count = shared and (PS.notifyCount and PS.notifyCount() or 0) or #(self.ha.notifications or {})
    c:icon("bell", bx, 13, 18)
    if count > 0 then
        -- How many (not seen yet), on the bell.
        local n = count > 99 and "99+" or tostring(count)
        local bw = math.max(14, c:width(n, 8, true) + 6)
        c:box(bx + 10, 7, bw, 14, { r = 7, fill = C.FILL })
        c:text(bx + 10 + bw / 2, 18, n, 8, { bold = true, align = "middle", color = C.ON_FILL })
    end
    c:hit(bx - 8, 0, 34, 44, function() self:titleAction("bell") end)
    local rx = c.W - 100
    if self.ha.busy then
        c:circle(rx + 9, 22, 9, C.FILL)
        c:icon("refresh-cw", rx + 2, 15, 14, true)
    else
        c:icon("refresh-cw", rx, 13, 18)
    end
    c:hit(rx - 8, 0, 34, 44, function()
        if reload then reload() else self.ha:update() end
        self:refresh("full")
    end)
    local right = rx - 14
    do
        -- Always there (the tap target for the control center). A tap on the time and battery (▾): the control center (Apps: light, Wi-Fi, night mode…).
        local caret = PS.showControlCenter and 16 or 0
        if caret > 0 then c:icon("chevron-down", right - 12, 16, 12) end
        local sw = self:drawStatus(c, right - caret, 22, 11) + caret
        if PS.showControlCenter then c:hit(right - sw - 6, 0, sw + 12, 44, function() PS.showControlCenter() end) end
        right = right - sw - 14
    end
    for __, b in ipairs(own) do
        right = right - 34
        c:icon(b[1], right + 8, 13, 18)
        c:hit(right, 0, 34, 44, b[2] or function() self:titleAction(b[1]) end)
    end
    if pages and pages > 1 then
        local label = T("%1/%2", self.pageNo, pages)
        local lw = c:width(label, 11) + 40
        right = right - lw - 4
        c:icon("chevron-left", right + 2, 15, 14, false)
        c:text(right + lw / 2, 27, label, 11, { align = "middle", color = C.GREY })
        c:icon("chevron-right", right + lw - 16, 15, 14, false)
        c:hit(right - 6, 0, lw / 2 + 6, 44, function() self:turn(-1) end)
        c:hit(right + lw / 2, 0, lw / 2 + 6, 44, function() self:turn(1) end)
    end
    c:text(x, 28, title, 15, { bold = true, maxw = math.max(40, right - x - 8) })
end

--- ⌂: Home Assistant closed, Apps on top.
function View:home()
    self:close()
    KO.home()
end

function View:titleAction(name)
    local PS = require("pluginshare")
    if name == "refresh-cw" then self.ha:update()
    elseif name == "settings" then self:go({ kind = "settings" })
    elseif name == "search" then self:askSearch()
    elseif name == "bell" then
        -- The notifications of every app (Home Assistant's among them), or its own.
        if PS.showNotifications then PS.showNotifications() else self:go({ kind = "notifications" }) end
    elseif name == "ellipsis-vertical" then
        local pin = self:pinOf(self.route)
        local extra = pin and { { _("Add to launcher"), function() self:addToApps(pin) end } } or {}
        if PS.showNotifications and self.route.kind ~= "notifications" then
            table.insert(extra, { _("Home Assistant notifications"), function() self:go({ kind = "notifications" }) end })
        end
        -- The camera screens: their order and which show.
        if self.route.kind == "cameras" then
            table.insert(extra, 1, { _("Reorder or hide cameras"), function() self:go({ kind = "reorder", what = "cameras" }) end })
        elseif self.route.kind == "security" then
            table.insert(extra, 1, { _("Reorder or hide cameras"), function() self:go({ kind = "reorder", what = "security_cams" }) end })
        end
        -- Home Assistant's settings on the phone: the web server started, a QR code to scan.
        local ui = self:currentUI()
        local web = ui and ui.webpage
        if web and web.openOnWeb then table.insert(extra, { _("Open on the web page"), function() web:openOnWeb("ha") end }) end
        KO.menu(self:currentUI(), self, extra, function() self:go({ kind = "settings" }) end)
    end
end

-- ------------------------------------------------------------------ pins in Apps

-- Screens that can be a tile in Apps: { kind = "ha", name, icon, route } or nil.
local PINNABLE = { notifications = true, home = true, dashboard = true, room = true, category = true, cameras = true, camera = true,
    media = true, scripts = true, security = true, climate = true, weather = true, activity = true,
    batteries = true, printer = true }

function View:pinOf(route)
    local k = route.kind
    if not PINNABLE[k] then return nil end
    local pin = { kind = "ha", route = {} }
    for key, v in pairs(route) do pin.route[key] = v end
    if k == "home" then pin.name, pin.icon = _("Home"), "house"
    elseif k == "notifications" then pin.name, pin.icon = _("Notifications"), "bell"
    elseif k == "dashboard" then pin.name, pin.icon = _("Dashboard"), "layout-dashboard"
    elseif k == "room" then pin.name, pin.icon = route.name, "door-open"
    elseif k == "camera" then
        local e = self.ha.snap and self.ha.snap.byId[route.id]
        pin.name, pin.icon = e and e.name or _("Camera"), "camera"
    else
        for __, s in ipairs(Model.SHORTCUTS) do
            if (k == "category" and s.key == route.key) or (k ~= "category" and s.screen == k) then
                pin.name, pin.icon = _(s.label), s.icon
            end
        end
    end
    if not pin.name then return nil end
    return pin
end

--- Adds a screen to Apps as a tile of its own.
function View:addToApps(pin)
    local ui = self:currentUI()
    local apps = ui and ui.apps
    if not (apps and apps.addPin) then
        return require("hako").toast(_("The launcher isn't installed."), 2)
    end
    apps:addPin(pin)
end

--- Holding a shortcut or a room on Home: open it, or add it to Apps.
function View:holdMenu(route)
    local pin = self:pinOf(route)
    KO.list(pin and pin.name or "", {
        { text = _("Open"), fn = function() self:go(route) end },
        { text = _("Add to launcher"), enabled = pin ~= nil, fn = function() self:addToApps(pin) end },
    })
end

function View:label(c, y, s, right, rightFn)
    c:text(14, y + 15, s, 9.5, { bold = true, color = C.GREY })
    if right then
        local w = c:width(right, 9.5)
        c:text(c.W - 14, y + 15, right, 9.5, { align = "end", color = C.GREY })
        if rightFn then c:hit(c.W - w - 30, y, w + 30, 22, rightFn) end
    end
end

-- Dark tiles: on, open or unlocked.
local function dark(e)
    local d = e.domain
    if d == "camera" or d == "scene" or d == "script" then return false end
    return Model.isOn(e)
end

--- One tile: "cards" (a box, dark when on), "big" (the same, larger) or
-- "minimal" (no box: a line under it, bold when on).
function View:tile(c, x, y, w, h, e, style)
    style = style or (self:layout() == "minimal" and "minimal" or "cards")
    local on = dark(e)
    local gone = e.state == "unavailable"
    if style == "minimal" then
        if on then
            c:circle(x + 11, y + 19, 14, C.FILL)
            c:icon(Model.icon(e), x + 2, y + 10, 18, true)
        else
            c:icon(Model.icon(e), x + 2, y + 10, 18)
        end
        c:text(x + 32, y + 22, e.name, 11.5, { bold = on, maxw = w - 34, color = gone and C.MID or C.BLACK })
        c:text(x + 32, y + 38, Model.stateText(e), 9.5, { bold = on, maxw = w - 34, color = on and C.BLACK or C.GREY })
        c:hline(x, y + h - 2, w)
    elseif style == "big" then
        c:box(x, y, w, h, { r = 10, fill = on and C.FILL or C.WHITE, border = C.BLACK, bw = 1.2 })
        c:icon(Model.icon(e), x + 14, y + 14, 28, on)
        c:text(x + 14, y + h - 30, e.name, 14, { bold = true, maxw = w - 26, color = on and C.ON_FILL or (gone and C.MID or C.BLACK) })
        c:text(x + 14, y + h - 12, Model.stateText(e), 11, { maxw = w - 26, color = on and C.ON_FILL_DIM or C.GREY })
    else
        c:box(x, y, w, h, { r = 8, fill = on and C.FILL or C.WHITE, border = C.BLACK, bw = 1 })
        c:icon(Model.icon(e), x + 10, y + 9, 18, on)
        c:text(x + 10, y + 42, e.name, 11.5, { bold = true, maxw = w - 18, color = on and C.ON_FILL or (gone and C.MID or C.BLACK) })
        c:text(x + 10, y + 56, Model.stateText(e), 9.5, { maxw = w - 18, color = on and C.ON_FILL_DIM or C.GREY })
    end
    c:hit(x, y, w, h, function() self:tapEntity(e) end, function() self:openSheet(e) end)
end

--- Tiles in rows of `cols`, each row a block of the flow (in the List
-- layout, a row each).
function View:tiles(c, F, list, cols)
    local layout = self:layout()
    if layout == "list" then
        for __, e in ipairs(list) do
            F:block(46, function(y) self:listRow(c, y, e) end)
        end
        return
    end
    local wide = c.W > c.H
    local h, gap = 64, 8
    if layout == "big" then cols, h = (wide and 3 or 2), 100
    else cols = cols or (wide and 4 or 3) end
    if layout == "minimal" then h, gap = 52, 16 end
    local w = (c.W - 28 - (cols - 1) * gap) / cols
    for i = 1, #list, cols do
        F:block(h + 8, function(y)
            for k = 0, cols - 1 do
                local e = list[i + k]
                if e then self:tile(c, 14 + k * (w + gap), y, w, h, e, layout == "big" and "big" or nil) end
            end
        end)
    end
end

--- A row of the List layout: icon, name and state, a switch or a button at the right.
function View:listRow(c, y, e, x, w)
    x, w = x or 14, w or (c.W - 28)
    local on = dark(e)
    if on then
        c:circle(x + 13, y + 22, 15, C.FILL)
        c:icon(Model.icon(e), x + 4, y + 13, 18, true)
    else
        c:icon(Model.icon(e), x + 4, y + 13, 18)
    end
    local cw = self:control(c, x + w, y + 10, e)
    local gone = e.state == "unavailable"
    c:text(x + 38, y + 20, e.name, 12, { bold = on, maxw = w - 44 - cw, color = gone and C.MID or C.BLACK })
    c:text(x + 38, y + 37, Model.stateText(e), 10, { maxw = w - 44 - cw, color = C.GREY })
    c:hline(x + 38, y + 45, w - 38)
    c:hit(x, y, w - cw, 46, function() self:tapEntity(e) end, function() self:openSheet(e) end)
end

local BUTTON_WORDS = {
    ["lock.unlock"] = _("Unlock"), ["lock.lock"] = _("Lock"), ["cover.open_cover"] = _("Open"),
    ["cover.close_cover"] = _("Close"), ["button.press"] = _("Press"),
}

--- What a row's right side does: a switch, or a button (Unlock, Open, Start,
-- Adjust...) ending at `right`. Returns the width it took.
function View:control(c, right, y, e)
    if e.state == "unavailable" then return 0 end
    local action = Model.tapAction(e, self.ha.prefs)
    local tap = function() self:tapEntity(e) end
    if action.service and action.service:match("%.toggle$") then
        Sheet.toggle(c, right - 44, y + 3, Model.isOn(e), tap)
        return 56
    end
    local label
    if action.camera then
        label, tap = _("View"), function() self:go({ kind = "camera", id = e.id }) end
    elseif e.domain == "vacuum" then
        local cleaning = e.state == "cleaning"
        label = cleaning and _("Dock") or _("Start")
        tap = function() self.ha:act(e, cleaning and "vacuum.return_to_base" or "vacuum.start", { entity_id = e.id }) end
    elseif action.sheet then
        label, tap = _("Adjust"), function() self:openSheet(e) end
    else
        label = BUTTON_WORDS[action.service] or _("Run")
    end
    local bw = math.max(66, c:width(label, 10) + 26)
    self:button(c, right - bw, y, bw, 26, label, nil, tap)
    return bw + 10
end

function View:button(c, x, y, w, h, s, icon, fn, darkFill)
    c:box(x, y, w, h, { r = h < 30 and h / 2 or 8, fill = darkFill and C.FILL or C.WHITE, border = C.BLACK })
    local size = h < 30 and 10 or 11.5
    local tw = c:width(s, size) + (icon and 19 or 0)
    local tx = x + (w - tw) / 2
    if icon then
        c:icon(icon, tx, y + h / 2 - 7, 14, darkFill)
        tx = tx + 19
    end
    c:text(tx, y + h / 2 + size * 0.36, s, size, { color = darkFill and C.ON_FILL or C.BLACK })
    if fn then c:hit(x, y, w, h, fn) end
end

-- ------------------------------------------------------------------ acting

--- A tap on a tile: switched at once (shown before Home Assistant answers),
-- asked first for locks, the garage and scripts, controls for the rest.
function View:tapEntity(e)
    local action = Model.tapAction(e, self.ha.prefs)
    if action.camera then return self:loadPicture(e.id, true) end
    if action.sheet then return self:openSheet(e) end
    local function run() self.ha:act(e, action.service, action.data) end
    if action.confirm then
        KO.confirm{
            title = action.confirm,
            text = T(_("Currently: %1"), Model.stateText(e)),
            ok = action.service:match("unlock") and _("Unlock") or action.service:match("open") and _("Open")
                or action.service:match("close") and _("Close") or _("Run"),
            onOk = run,
        }
    else
        run()
    end
end

function View:openSheet(e)
    self.sheet = e.id
    self:refresh("ui")
end

function View:closeSheet()
    self.sheet = nil
    self:refresh("full")
end

function View:askSearch()
    local function search(q)
        if q == "" then return end
        if self.route.kind == "search" then self.route.query = q self.pageNo = 1 self:refresh("ui")
        else self:go({ kind = "search", query = q }) end
    end
    -- The launcher's text box (with the pen to write it by hand), when it's there.
    if KO.askText then
        return KO.askText{ title = _("Search devices"), text = self.route.kind == "search" and self.route.query or "",
            ok = _("Search"), okIcon = "search", needsText = true, done = search }
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search devices"),
        input = self.route.kind == "search" and self.route.query or "",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = dialog:getInputText()
                UIManager:close(dialog)
                search(q)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ------------------------------------------------------------------ pictures

-- Camera pictures on this page, fetched in the background (three at a time);
-- each drawn in its own spot when it comes.
function View:loadPictures()
    for __, w in ipairs(self.wantPictures or {}) do
        if self.ha:pictureJobs() >= 3 then return end
        local pic = self.ha.pictures[w.id]
        local resting = pic and pic.failedAt and os.time() - pic.failedAt < 180
        if not self.ha.loading[w.id] and not resting and (not pic or pic.w ~= w.w or pic.h ~= w.h or pic.stale) then
            self.ha:picture(w.id, w.w, w.h, function() self:pictureArrived(w.id) end)
        end
    end
end

function View:pictureArrived(id)
    if not self.canvas then return end
    -- Drawn again either way: the old picture's memory is freed now.
    self:render()
    if UIManager:getTopmostVisibleWidget() ~= self then return end
    local r = self.pictureRects[id]
    if r then
        UIManager:setDirty(self, function() return "ui", Geom:new{ x = r[1], y = r[2], w = r[3], h = r[4] + r[5] }, true end)
    end
    self:loadPictures()
end

function View:loadPicture(id, fresh)
    local old = self.ha.pictures[id]
    local w, h = old and old.w, old and old.h
    for __, want in ipairs(self.wantPictures or {}) do
        if want.id == id then w, h = want.w, want.h end
    end
    if not w then return end
    self.ha:picture(id, w, h, function() self:pictureArrived(id) end, fresh)
    self:refresh("fast")
end

--- A camera's picture area: the picture if there is one (asked for after showing).
function View:picture(c, id, x, y, w, h)
    local pw, ph = c:X(w), c:X(h)
    local pic = self.ha.pictures[id]
    -- The spot (and the line under it, "Taken ...") redrawn when the picture comes.
    self.pictureRects[id] = { c:X(x), c:X(y), pw, ph, c:X(44) }
    if pic and pic.bb and pic.w == pw and pic.h == ph then
        c:image(pic.bb, x, y)
        self.hasPictures = true
        if pic.stale then table.insert(self.wantPictures, { id = id, w = pw, h = ph }) end
    else
        -- A drawing of a doorway, garage or room until the picture comes.
        c:drawing(Model.placeholder(self.ha.snap and self.ha.snap.byId[id], self.ha.prefs), x, y, w, h)
        self.hasPictures = true
        if pic and pic.failed then
            c:box(x + w - 44, y + 8, 36, 36, { r = 18, fill = C.WHITE })
            c:icon("image-off", x + w - 36, y + 16, 20)
        end
        if not (pic and pic.failed) then table.insert(self.wantPictures, { id = id, w = pw, h = ph }) end
    end
    return pic
end

-- ------------------------------------------------------------------ screens

View.screens = {}
local S = View.screens

function S.home(self, c, snap)
    local prefs = self.ha.prefs
    local F = c:flow(52, c.H - 8, self.pageNo)
    local sections = Model.ordered(Model.HOME_SECTIONS, prefs.sections, function(s) return s end)
    for __, section in ipairs(sections) do
        if not (prefs.hidden_sections and prefs.hidden_sections[section]) then
            S["home_" .. section](self, c, snap, F)
        end
    end
    self:titlebar(c, nil, _("Home"), { "search" }, F:pages())
    return F:pages()
end

function S.home_routines(self, c, snap, F)
    local list = Routines.list(self.ha.prefs)
    if #list == 0 then return end
    F:block(28, function(y) self:label(c, y, _("ROUTINES"), _("Edit"), function() self:go({ kind = "routines" }) end) end, 76)
    local per = c.W > c.H and 4 or 2
    for i = 1, #list, per do
        F:block(50, function(y)
            local bw = (c.W - 28 - (per - 1) * 8) / per
            for k = 0, per - 1 do
                local r = list[i + k]
                if r then
                    local bx = 14 + k * (bw + 8)
                    c:box(bx, y + 2, bw, 42, { r = 8, fill = C.WHITE, border = C.BLACK })
                    c:icon("play", bx + 10, y + 15, 16)
                    c:text(bx + 32, y + 28, r.name, 11.5, { bold = true, maxw = bw - 40 })
                    c:hit(bx, y + 2, bw, 42, function() Routines.run(self.ha, r) end,
                        function() self:go({ kind = "routine", id = r.id }) end)
                end
            end
        end)
    end
    F:gap(6)
end

function S.home_status(self, c, snap, F)
    F:block(70, function(y)
        local w = snap.weather
        if w then
            local text, icon = Model.weather(w.state)
            c:icon(icon, 14, y + 2, 20)
            c:text(42, y + 18, (w.temp and Model.formatTemp(w.temp) .. "  " or "") .. text, 14, { bold = true })
            c:hit(0, y, 300, 26, function() self:go({ kind = "dashboard" }) end)
        end
        local temp, hum = Model.inside(snap, self.ha.prefs)
        if temp then
            c:text(c.W - 14, y + 18, T(_("Inside %1"), Model.formatTemp(temp)) .. (hum and ("  ·  " .. T(_("%1% humidity"), math.floor(hum + 0.5))) or ""),
                11, { align = "end", color = C.GREY })
        end
        local att = Model.attention(snap, self.ha.prefs)
        local status = self.ha:statusText()
        c:box(14, y + 32, c.W - 28, 28, { r = 6, fill = att.ok and C.WHITE or C.FILL, border = C.BLACK })
        c:icon(att.ok and "shield-check" or "triangle-alert", 22, y + 39, 14, not att.ok)
        local sw = c:width(status, 9)
        c:text(42, y + 50, att.text, 10.5, { maxw = c.W - 84 - sw, color = att.ok and C.BLACK or C.ON_FILL })
        c:text(c.W - 22, y + 50, status, 9, { align = "end", color = att.ok and C.GREY or C.ON_FILL_DIM })
    end)
end

function S.home_shortcuts(self, c, snap, F)
    local list = Model.shortcuts(snap, self.ha.prefs)
    local per = c.W > c.H and 5 or 4
    local w = (c.W - 28 - (per - 1) * 8) / per
    for i = 1, #list, per do
        F:block(42, function(y)
            for k = 0, per - 1 do
                local s = list[i + k]
                if s then
                    local route = s.screen and { kind = s.screen } or { kind = "category", key = s.key }
                    self:button(c, 14 + k * (w + 8), y, w, 34, _(s.label), s.icon, function() self:go(route) end)
                    c:hit(14 + k * (w + 8), y, w, 34, function() self:go(route) end, function() self:holdMenu(route) end)
                end
            end
        end)
    end
    F:gap(6)
end

function S.home_on(self, c, snap, F)
    -- With those just turned off here still in their places (shown as off).
    local all = Model.onNow(snap, self.ha.prefs, self.ha:keptOff())
    local on = {}
    for __, e in ipairs(all) do if Model.isOn(e) then table.insert(on, e) end end
    F:block(28, function(y)
        self:label(c, y, T(_("ON NOW  %1"), #on))
        if #on > 0 then
            self:button(c, c.W - 118, y, 104, 22, _("Turn all off"), "power", function() self.ha:allOff(on) end)
        end
    end, 32)
    if #all == 0 then
        F:block(28, function(y) c:text(14, y + 16, _("Nothing is on."), 11, { color = C.GREY }) end)
    else
        local rows, row, x = {}, {}, 14
        for __, e in ipairs(all) do
            local w = math.min(c.W - 28, c:width(e.name, 10.5) + 36)
            if x + w > c.W - 14 and #row > 0 then
                table.insert(rows, row)
                row, x = {}, 14
            end
            table.insert(row, { e = e, x = x, w = w })
            x = x + w + 6
        end
        table.insert(rows, row)
        for __, r in ipairs(rows) do
            F:block(32, function(y)
                for __, chip in ipairs(r) do
                    local e = chip.e
                    local lit = Model.isOn(e)
                    c:box(chip.x, y, chip.w, 26, { r = 13, fill = lit and C.FILL or C.WHITE, border = C.BLACK })
                    c:icon(Model.icon(e), chip.x + 9, y + 6, 14, lit)
                    c:text(chip.x + 27, y + 17, e.name, 10.5, { color = lit and C.ON_FILL or C.GREY, maxw = chip.w - 34 })
                    c:hit(chip.x, y, chip.w, 26, function() self:tapEntity(e) end, function() self:openSheet(e) end)
                end
            end)
        end
    end
    F:gap(10)
end

function S.home_quick(self, c, snap, F)
    local quick = Model.quick(snap, self.ha.prefs)
    F:block(28, function(y)
        self:label(c, y, _("QUICK"), _("Hold a tile to edit"))
    end, 72)
    if #quick == 0 then
        F:block(30, function(y) c:text(14, y + 16, _("To add one, hold any device and choose Add to Quick."), 11, { color = C.GREY }) end)
    end
    self:tiles(c, F, quick)
    F:gap(10)
end

function S.home_rooms(self, c, snap, F)
    F:block(28, function(y) self:label(c, y, _("ROOMS")) end, 32)
    for __, room in ipairs(Model.rooms(snap, self.ha.prefs)) do
        F:block(34, function(y)
            c:text(14, y + 22, room.name, 12)
            c:text(c.W - 32, y + 22, Model.roomSummary(room), 10.5, { align = "end", color = C.GREY, maxw = 360 })
            c:icon("chevron-right", c.W - 26, y + 11, 12)
            c:hline(14, y + 33, c.W - 14)
            c:hit(0, y, c.W, 34, function() self:go({ kind = "room", name = room.name }) end,
                function() self:holdMenu({ kind = "room", name = room.name }) end)
        end)
    end
end

function S.room(self, c, snap)
    local room
    for __, r in ipairs(Model.rooms(snap, self.ha.prefs, true)) do
        if r.name == self.route.name then room = r end
    end
    local F = c:flow(52, c.H - 8, self.pageNo)
    if not room then
        self:titlebar(c, true, self.route.name or "")
        c:text(14, 80, _("Nothing to show in this room."), 12, { color = C.GREY })
        return 1
    end
    local on, switchable = {}, 0
    for __, e in ipairs(room.entities) do
        if Model.switchable(e) and not Model.isGroup(e) then
            switchable = switchable + 1
            if Model.isOn(e) then table.insert(on, e) end
        end
    end
    F:block(36, function(y)
        local parts = {}
        if room.temp then table.insert(parts, Model.formatTemp(room.temp)) end
        if room.humidity then table.insert(parts, T(_("%1% humidity"), math.floor(room.humidity + 0.5))) end
        if switchable > 0 then table.insert(parts, #on > 0 and T(_("%1 on"), #on) or _("all off")) end
        c:text(14, y + 16, table.concat(parts, "  ·  "), 11, { color = C.GREY })
        if #on > 0 then self:button(c, c.W - 104, y + 2, 90, 22, _("All off"), "power", function() self.ha:allOff(on) end) end
    end)
    for __, kind in ipairs(Model.kinds(room.entities)) do
        if kind.title == "SENSORS" then
            F:block(26, function(y) self:label(c, y, _("SENSORS")) end, 36)
            self:sensorRows(c, F, kind.entities)
        elseif kind.title == "CAMERAS" then
            F:block(26, function(y) self:label(c, y, _("CAMERAS")) end, 180)
            for __, e in ipairs(kind.entities) do
                F:block(184, function(y) self:cameraRow(c, y, e) end)
            end
        else
            F:block(26, function(y) self:label(c, y, _(kind.title)) end, 72)
            self:tiles(c, F, kind.entities)
        end
        F:gap(6)
    end
    self:titlebar(c, true, room.name, { { "grip-vertical", function()
        self:go({ kind = "reorder", what = "entities", room = room.name })
    end } }, F:pages())
    return F:pages()
end

--- Sensors two to a row: icon, name, value; hold one for its controls (Quick, hide).
function View:sensorRows(c, F, list)
    local w = (c.W - 36) / 2
    for i = 1, #list, 2 do
        F:block(38, function(y)
            for k = 0, 1 do
                local e = list[i + k]
                if e then
                    local x = 14 + k * (w + 8)
                    local value = Model.stateText(e)
                    local vw = c:width(value, 12, true)
                    c:icon(Model.icon(e), x, y + 9, 16)
                    c:text(x + 24, y + 22, Model.shortName(e), 11, { maxw = w - vw - 36, color = e.state == "unavailable" and C.MID or C.BLACK })
                    c:text(x + w - 4, y + 22, value, 12, { bold = true, align = "end" })
                    c:hline(x, y + 36, w)
                    c:hit(x, y, w, 38, function() self:openSheet(e) end)
                end
            end
        end)
    end
end

function View:cameraRow(c, y, e)
    local pic = self:picture(c, e.id, 14, y, 300, 169)
    c:hit(14, y, 300, 169, function() self:loadPicture(e.id, true) end, function() self:go({ kind = "camera", id = e.id }) end)
    c:text(326, y + 18, e.name, 12, { bold = true, maxw = 280 })
    c:text(326, y + 36, self:takenText(pic), 10, { color = C.GREY })
    c:text(326, y + 62, _("Tap to refresh"), 10, { color = C.GREY })
    c:text(326, y + 78, _("Hold for full screen"), 10, { color = C.GREY })
end

function View:takenText(pic)
    if pic and pic.failed then return _("No image") end
    if not pic or not pic.at then return _("Loading…") end
    return T(_("Updated %1"), Model.ago(os.time() - pic.at))
end

local function visibleOf(self, snap, domains)
    local out = {}
    for __, e in ipairs(snap.list) do
        if domains[e.domain] and Model.visible(e, self.ha.prefs) then table.insert(out, e) end
    end
    return out
end

function S.category(self, c, snap)
    local def = Model.shortcut(self.route.key) or Model.SHORTCUTS[1]
    local groups = Model.byKind(snap, self.ha.prefs, def.domains or {})
    local F = c:flow(52, c.H - 8, self.pageNo)
    local on = {}
    for __, g in ipairs(groups) do
        for __, e in ipairs(g.entities) do
            if Model.switchable(e) and Model.isOn(e) and not Model.isGroup(e) then table.insert(on, e) end
        end
    end
    local switchable = def.key == "lights" or def.key == "switches" or def.key == "climate"
    if switchable then
        F:block(36, function(y)
            c:text(14, y + 16, #on > 0 and T(_("%1 on"), #on) or _("All off"), 11, { color = C.GREY })
            if #on > 0 then self:button(c, c.W - 118, y + 2, 104, 22, _("Turn all off"), "power", function() self.ha:allOff(on) end) end
        end)
    end
    for __, g in ipairs(groups) do
        local sensors = def.key == "sensors"
        F:block(26, function(y) self:label(c, y, g.name:upper()) end, sensors and 36 or 72)
        if sensors then self:sensorRows(c, F, g.entities) else self:tiles(c, F, g.entities) end
        F:gap(6)
    end
    if #groups == 0 then F:block(30, function(y) c:text(14, y + 20, _("Nothing to show. Choose devices in Settings > Devices."), 11, { color = C.GREY }) end) end
    self:titlebar(c, true, _(def.label), {}, F:pages())
    return F:pages()
end

--- Cameras two across (three on its side), each a block row of the flow.
function View:cameraGrid(c, F, cams)
    local cols = c.W > c.H and 3 or 2
    local w = (c.W - 28 - (cols - 1) * 8) / cols
    local ph = math.floor(w * 9 / 16)
    for i = 1, #cams, cols do
        F:block(ph + 52, function(y)
            for k = 0, cols - 1 do
                local e = cams[i + k]
                if e then
                    local x = 14 + k * (w + 8)
                    local pic = self:picture(c, e.id, x, y, w, ph)
                    c:hit(x, y, w, ph + 44, function() self:loadPicture(e.id, true) end, function() self:go({ kind = "camera", id = e.id }) end)
                    c:text(x, y + ph + 20, e.name, 12, { bold = true, maxw = w })
                    c:text(x, y + ph + 36, self:takenText(pic), 10, { color = C.GREY })
                end
            end
        end)
    end
end

function S.cameras(self, c, snap)
    local cams = Model.cameraList(snap, self.ha.prefs)
    local F = c:flow(56, c.H - 50, self.pageNo)
    self:cameraGrid(c, F, cams)
    if #cams == 0 then c:text(14, 80, _("No cameras to show. Choose them in Settings > Devices."), 12, { color = C.GREY }) end
    c:text(14, c.H - 22, _("Tap a camera to refresh it. Hold for full screen."), 10, { color = C.GREY })
    self:titlebar(c, true, _("Cameras"), { { "refresh-cw", function()
        for __, e in ipairs(cams) do self.ha.pictures[e.id] = nil end
        self:refresh("ui")
        UIManager:nextTick(function() self:loadPictures() end)
    end } }, F:pages())
    return F:pages()
end

function S.camera(self, c, snap)
    local e = snap.byId[self.route.id]
    self:titlebar(c, true, e and e.name or "", { { "refresh-cw", function() self:loadPicture(self.route.id, true) end } })
    if not e then return 1 end
    local w = c.W
    local h = math.floor(w * 9 / 16)
    local y = math.max(52, (c.H - h) / 2 - 20)
    local pic = self:picture(c, e.id, 0, y, w, h)
    c:hit(0, y, w, h, function() self:loadPicture(e.id, true) end)
    c:text(c.W / 2, y + h + 28, self:takenText(pic), 12, { align = "middle", color = C.GREY })
    local below = y + h + 50
    if self.ha:notes() then
        self:button(c, c.W / 2 - 90, below, 180, 36, _("Send to Notes"), "notebook-pen", function()
            local time, ampm = self:clockText()
            self.ha:sendToNotes(e, e.name .. " \u{00B7} " .. time .. (ampm and (" " .. ampm) or ""))
        end)
        below = below + 52
    end
    Sheet.placeholderChips(self, c, below, e)
    return 1
end

function S.media(self, c, snap)
    local players = visibleOf(self, snap, { media_player = true })
    local F = c:flow(56, c.H - 8, self.pageNo)
    local active, rest = {}, {}
    for __, e in ipairs(players) do
        if Model.isOn(e) then table.insert(active, e) else table.insert(rest, e) end
    end
    for __, e in ipairs(active) do
        F:block(170, function(y) Sheet.mediaCard(self, c, 14, y, c.W - 28, e) end)
    end
    if #rest > 0 then
        F:block(26, function(y) self:label(c, y, #active > 0 and _("OTHER PLAYERS") or _("PLAYERS")) end, 36)
        for __, e in ipairs(rest) do
            F:block(38, function(y)
                c:icon(Model.icon(e), 14, y + 10, 16)
                c:text(40, y + 23, e.name, 12, { maxw = 380 })
                c:text(c.W - 50, y + 23, Model.stateText(e) .. (e.area ~= "" and (" · " .. e.area) or ""), 10.5,
                    { align = "end", color = C.GREY, maxw = 160 })
                c:icon("power", c.W - 34, y + 10, 16)
                c:hline(40, y + 37, c.W - 40)
                c:hit(0, y, c.W - 50, 38, function() self:openSheet(e) end)
                c:hit(c.W - 50, y, 50, 38, function() self.ha:act(e, "media_player.turn_on", { entity_id = e.id }) end)
            end)
        end
    end
    if #players == 0 then c:text(14, 80, _("No media players to show."), 12, { color = C.GREY }) end
    self:titlebar(c, true, _("Media"), {}, F:pages())
    return F:pages()
end

function S.scripts(self, c, snap)
    local list = visibleOf(self, snap, { scene = true, script = true })
    local F = c:flow(56, c.H - 8, self.pageNo)
    F:block(28, function(y)
        local ask = self.ha.prefs.ask_scripts ~= false
        c:text(14, y + 12, ask and _("Scripts ask for confirmation before running (change this in Settings).") or _("Scripts run without confirmation."), 10, { color = C.GREY })
    end)
    for __, e in ipairs(list) do
        F:block(44, function(y)
            c:icon(Model.icon(e), 14, y + 14, 16)
            c:text(40, y + 27, e.name, 12.5, { maxw = 470 })
            self:button(c, c.W - 82, y + 8, 68, 28, e.domain == "script" and e.state == "on" and _("Running") or _("Run"), "play",
                function() self:tapEntity(e) end)
            c:hline(40, y + 44, c.W - 40)
        end)
    end
    if #list == 0 then F:block(30, function(y) c:text(14, y + 20, _("No scenes or scripts to show."), 11, { color = C.GREY }) end) end
    self:titlebar(c, true, _("Scenes & scripts"), {}, F:pages())
    return F:pages()
end

function S.search(self, c, snap)
    local q = (self.route.query or ""):lower()
    local found = {}
    for __, e in ipairs(snap.list) do
        if (e.name .. " " .. e.area .. " " .. e.id):lower():find(q, 1, true) then table.insert(found, e) end
    end
    local F = c:flow(52, c.H - 8, self.pageNo)
    F:block(26, function(y) self:label(c, y, T(_("%1 RESULTS"), #found)) end)
    self:tiles(c, F, found)
    self:titlebar(c, true, T(_("“%1”"), self.route.query or ""), { "search" }, F:pages())
    return F:pages()
end

-- ------------------------------------------------------------------ dashboard

function View:scheduleClock()
    if self.clockTask then UIManager:unschedule(self.clockTask) end
    self.clockTask = function()
        self.clockTask = nil
        if self.route.kind ~= "dashboard" then return end
        if self.ha.prefs.auto_light then self.ha:followRoomLight() end
        if UIManager:getTopmostVisibleWidget() == self then self:refresh("ui") end
        self:scheduleClock()
    end
    UIManager:scheduleIn(60 - os.date("*t").sec + 1, self.clockTask)
end

-- The Clock and info dashboard's sections (Settings > Dashboard > Sections).
local D = {}

function S.dashboard(self, c, snap)
    local style = self.ha.prefs.dash_layout or "clock"
    if style == "security" then return S.dashSecurity(self, c, snap) end
    if style == "info" then return S.dashInfo(self, c, snap) end
    if style == "camera" then return S.dashCamera(self, c, snap) end
    if style == "clockonly" then return S.dashClock(self, c, snap) end
    local prefs = self.ha.prefs
    local wide = c.W > c.H
    local y = self:dashHeader(c, snap, wide)
    local keys = {}
    for __, k in ipairs(Model.dashSections(prefs)) do
        if not Model.dashHidden(prefs, k) then keys[#keys + 1] = k end
    end
    local bottom = c.H - 48
    if not wide then
        self:dashColumn(c, snap, keys, 24, y, c.W - 48, bottom, false)
    else
        -- On its side: the sections on the left, the camera on the right.
        local cam
        for __, k in ipairs(keys) do if k == "camera" then cam = self:dashCam(snap) end end
        local leftW = cam and math.floor((c.W - 48) * 0.45) or (c.W - 48)
        self:dashColumn(c, snap, keys, 24, y, leftW, bottom, true)
        if cam then
            local cx = 24 + leftW + 20
            local pw = c.W - 24 - cx
            local ph = math.min(bottom - y - 30, math.floor(pw * 9 / 16))
            local cy = y + 18
            c:text(cx, cy - 4, cam.name:upper(), 9.5, { bold = true, color = C.GREY, maxw = pw - 120 })
            c:text(c.W - 24, cy - 4, self:takenText(self.ha.pictures[cam.id]), 9.5, { align = "end", color = C.GREY })
            self:picture(c, cam.id, cx, cy + 4, pw, ph)
            c:hit(cx, cy + 4, pw, ph, function() self:loadPicture(cam.id, true) end, function() self:go({ kind = "camera", id = cam.id }) end)
        end
    end
    self:dashFooter(c)
    return 1
end

--- The big clock and the weather across the top. Returns where the sections start.
function View:dashHeader(c, snap, wide)
    local now = os.date("*t")
    local twelve = not KO.twentyFour()
    local hour = twelve and ((now.hour + 11) % 12 + 1) or now.hour
    local base, size = wide and 86 or 92, wide and 66 or 72
    local w1 = c:text(24, base, string.format(twelve and "%d:%02d" or "%02d:%02d", hour, now.min), size, { bold = true })
    if twelve then c:text(24 + w1 + 8, base, now.hour < 12 and "AM" or "PM", wide and 18 or 20, { bold = true }) end
    local dsize = wide and 14 or 15
    local dw = c:text(26, base + 30 - (wide and 2 or 0), os.date("%A, %B ") .. now.day, dsize, { color = C.GREY }) or 0
    self:drawBattery(c, 26 + dw + 18, base + 30 - (wide and 2 or 0) - dsize * 0.36, dsize)
    local rule = wide and 128 or 140
    c:hit(0, 0, c.W / 2, rule - 10, function() self:back() end)
    local w = snap.weather
    if w then
        local text, icon = Model.weather(w.state)
        local wy = wide and 70 or 74
        local tw = c:text(c.W - 24, wy, w.temp and Model.formatTemp(w.temp) or "", 34, { bold = true, align = "end" }) or 0
        c:icon(icon, c.W - 24 - tw - 52, wy - 32, 40)
        c:text(c.W - 24, wy + 24, text, 13, { align = "end", color = C.GREY })
        local f = self.ha.forecast and self.ha.forecast[2]
        if f and f.high then
            c:text(c.W - 24, wy + 43, T(_("Tomorrow %1 / %2"), Model.formatTemp(f.high), f.low and Model.formatTemp(f.low) or "\u{2013}"), 11,
                { align = "end", color = C.GREY })
        end
        c:hit(c.W / 2, 0, c.W / 2, rule - 10, function() self:go({ kind = "weather" }) end)
    end
    c:hline(24, rule, c.W - 48, C.BLACK, 2)
    return rule + 12
end

--- The sections, one under another from y. A camera takes the room the
-- others leave; a section that does not fit is left out.
function View:dashColumn(c, snap, keys, x, y, w, bottom, wide)
    local parts, fixed, filler = {}, 0, nil
    for __, k in ipairs(keys) do
        if not (wide and k == "camera") and D[k] then
            local p = D[k](self, c, snap, x, w, wide)
            if p then
                if p.fill then filler = p else fixed = fixed + p.h end
                parts[#parts + 1] = p
            end
        end
    end
    if filler then
        filler.h = math.min(filler.max, bottom - y - fixed)
        if filler.h < filler.min then filler.h = nil end
    end
    for __, p in ipairs(parts) do
        if p.h and y + p.h <= bottom + 4 then
            p.draw(y, p.h)
            y = y + p.h
        end
    end
end

local function sectionLabel(c, x, y, text, right)
    c:text(x, y + 10, text, 9.5, { bold = true, color = C.GREY })
    if right then c:text(x + right[2], y + 10, right[1], 9.5, { align = "end", color = C.GREY }) end
end

-- The sections: each gives { h, draw(y, h) } (a camera: { fill, min, max }), or nil when it has nothing.
D.status = function(self, c, snap, x, w, wide)
    return { h = wide and 46 or 52, draw = function(y) self:attentionBar(c, x, y, w, snap) end }
end

D.rooms = function(self, c, snap, x, w, wide)
    local prefs = self.ha.prefs
    local temps = {}
    for __, r in ipairs(snap.rooms) do
        if r.temp and not (prefs.hidden_rooms and prefs.hidden_rooms[r.name]) then temps[#temps + 1] = r end
    end
    temps = Model.ordered(temps, prefs.room_order, function(r) return r.name end)
    if #temps == 0 then return nil end
    local per = wide and 3 or 4
    local n = math.min(per * 2, #temps)
    local rows = math.ceil(n / per)
    return { h = 22 + rows * 46 + 6, draw = function(y)
        sectionLabel(c, x, y, _("INSIDE"))
        local cw = w / per
        for i = 1, n do
            local r = temps[i]
            local xx, yy = x + ((i - 1) % per) * cw, y + 18 + math.floor((i - 1) / per) * 46
            c:text(xx, yy + 18, Model.formatTemp(r.temp), 17, { bold = true })
            c:text(xx, yy + 34, r.name, 9.5, { color = C.GREY, maxw = cw - 8 })
        end
    end }
end

D.next = function(self, c, snap, x, w)
    local nxt = self:dashNext(snap)
    if not nxt then return nil end
    return { h = 36, draw = function(y)
        c:icon("clock", x, y + 4, 16)
        local ww = c:text(x + w, y + 17, nxt.when, 11, { align = "end", color = C.GREY }) or 0
        c:text(x + 24, y + 17, nxt.title, 12, { bold = true, maxw = w - 24 - ww - 12 })
        if nxt.open then c:hit(x, y - 4, w, 30, nxt.open) end
    end }
end

D.media = function(self, c, snap, x, w)
    local e = Model.nowPlaying(snap, self.ha.prefs)
    if not e then return nil end
    return { h = 76, draw = function(y)
        c:box(x, y, w, 60, { r = 8, fill = C.WHITE, border = C.BLACK })
        local buttons = Model.mediaButtons(e)
        local bw = #buttons * 46
        c:icon(Model.icon(e), x + 12, y + 18, 24)
        c:text(x + 48, y + 26, e.name, 12, { bold = true, maxw = w - 60 - bw })
        c:text(x + 48, y + 44, Model.playingText(e), 10.5, { color = C.GREY, maxw = w - 60 - bw })
        c:hit(x, y, w - bw - 6, 60, function() self:openSheet(e) end)
        for i, b in ipairs(buttons) do
            local bx = x + w - bw - 6 + (i - 1) * 46
            c:icon(b[1], bx + 11, y + 19, 22)
            c:hit(bx, y, 46, 60, function() self.ha:act(e, b[2], { entity_id = e.id }) end)
        end
    end }
end

D.tasks = function(self, c, snap, x, w, wide)
    local tasks = self:dashTasks()
    if not tasks then return nil end
    local todo = self:currentUI().todo
    local max = wide and 6 or 4
    local n = math.min(max, #tasks)
    local more = #tasks - n
    local h = 22 + math.max(1, n) * 30 + (more > 0 and 24 or 0) + 8
    return { h = h, draw = function(y)
        sectionLabel(c, x, y, _("TODAY"), { #tasks == 1 and _("1 task") or T(_("%1 tasks"), #tasks), w })
        c:hit(x, y - 4, w, 20, function() todo:show({ kind = "today" }) end)
        local ry = y + 18
        if n == 0 then c:text(x, ry + 20, _("Nothing due today."), 11, { color = C.GREY }) end
        for i = 1, n do
            local t = tasks[i]
            c:box(x, ry + 8, 15, 15, { r = 3, fill = C.WHITE, border = C.BLACK })
            local rw = t.overdue and (c:text(x + w, ry + 21, _("Overdue"), 10, { align = "end", color = C.GREY }) or 0) or 0
            c:text(x + 26, ry + 21, t.title, 11.5, { maxw = w - 26 - rw - 10 })
            c:hit(x, ry, w, 30, function() todo:show({ kind = "task", listId = t.listId, taskId = t.id }) end)
            -- The box: done (To Do sends it).
            if todo.complete then
                c:hit(x - 6, ry, 36, 30, function()
                    if todo:complete(t.listId, t.id) then self:refresh("ui") end
                end)
            end
            ry = ry + 30
        end
        if more > 0 then
            c:text(x + 26, ry + 16, T(_("%1 more"), more), 10.5, { color = C.GREY })
            c:hit(x, ry, w, 24, function() todo:show({ kind = "today" }) end)
        end
    end }
end

D.scenes = function(self, c, snap, x, w, wide)
    local list = {}
    for __, r in ipairs(Routines.list(self.ha.prefs)) do
        table.insert(list, { name = r.name, routine = r })
    end
    for __, e in ipairs(Model.dashScenes(snap, self.ha.prefs)) do table.insert(list, e) end
    if #list == 0 then return nil end
    local per = wide and 2 or 3
    local n = math.min(per * 2, #list)
    local rows = math.ceil(n / per)
    return { h = 18 + rows * 52 + 6, draw = function(y)
        sectionLabel(c, x, y, _("SCENES"))
        local bw = (w - (per - 1) * 8) / per
        for i = 1, n do
            local e = list[i]
            local bx, by = x + ((i - 1) % per) * (bw + 8), y + 18 + math.floor((i - 1) / per) * 52
            c:box(bx, by, bw, 44, { r = 8, fill = C.WHITE, border = C.BLACK })
            c:icon(e.routine and "play" or Model.icon(e), bx + 10, by + 14, 16)
            c:text(bx + 32, by + 27, e.name, 11, { bold = true, maxw = bw - 40 })
            if e.routine then
                c:hit(bx, by, bw, 44, function() Routines.run(self.ha, e.routine) end,
                    function() self:go({ kind = "routine", id = e.routine.id }) end)
            else
                c:hit(bx, by, bw, 44, function() self:tapEntity(e) end, function() self:openSheet(e) end)
            end
        end
    end }
end

D.graph = function(self, c, snap, x, w)
    local e = self:graphSensor(snap)
    if not e then return nil end
    return { h = 120, draw = function(y)
        sectionLabel(c, x, y, e.name:upper() .. "  \u{00B7}  " .. _("LAST 24 HOURS"))
        self:graph(c, x, y + 22, w, 78, e)
        c:hit(x, y, w, 112, function() self:openSheet(e) end)
    end }
end

--- The dashboard's graph: the sensor picked, else the first temperature.
function View:graphSensor(snap)
    local id = self.ha.prefs.dash_graph
    if id and snap.byId[id] then return snap.byId[id] end
    for __, e in ipairs(Model.graphSensors(snap)) do
        if Model.str(e.attr.device_class) == "temperature" then return e end
    end
end

--- A sensor's last day, an hour a bar, with its highest and lowest (asked
-- for when not here yet).
function View:graph(c, x, y, w, h, e)
    local hist = self.ha.histories and self.ha.histories[e.id]
    if not (hist and hist.hourly) or (not hist.loading and os.time() - hist.at >= 600) then
        self.ha:loadHistory(e.id, function() if self.canvas then self:refresh("ui") end end)
    end
    local hr = hist and hist.hourly
    if not (hr and hr.min) then
        c:text(x, y + h / 2, (hist and hist.loading or not hist) and _("Loading\u{2026}") or _("No readings in the last day."), 10.5, { color = C.GREY })
        return
    end
    local temp = Model.str(e.attr.device_class) == "temperature"
    local unit = Model.str(e.attr.unit_of_measurement) or ""
    local function fmt(v) return temp and Model.formatTemp(v) or (string.format("%.0f", v) .. unit) end
    local lo, hi = hr.min, hr.max
    if hi - lo < 1 then lo, hi = lo - 0.5, hi + 0.5 end
    local lw = 46
    local gw, gh = w - lw, h - 16
    local bw = gw / #hr.values
    for i, v in ipairs(hr.values) do
        if v then
            local bh = 4 + (gh - 4) * (v - lo) / (hi - lo)
            c:rect(x + lw + (i - 1) * bw + 1, y + gh - bh, math.max(1, bw - 2), bh, C.BLACK)
        end
    end
    c:hline(x + lw, y + gh, gw, C.BLACK, 1)
    c:text(x, y + 10, fmt(hr.max), 9.5, { color = C.GREY })
    c:text(x, y + gh, fmt(hr.min), 9.5, { color = C.GREY })
    c:text(x + lw, y + h, _("24 h ago"), 9, { color = C.GREY })
    c:text(x + w, y + h, _("Now"), 9, { align = "end", color = C.GREY })
end

--- A doorbell rang or saw someone: its camera, full screen, taken again every
-- few seconds for a minute; then back to the dashboard.
function View:doorbell(id)
    if self.route.kind ~= "dashboard" or not self.ha.snap.byId[id] then return end
    self:go({ kind = "camera", id = id, popup = true })
    local function tick(n)
        if not (self.canvas and self.route.kind == "camera" and self.route.popup) then return end
        if n <= 0 then return self:back() end
        self:loadPicture(id, true)
        UIManager:scheduleIn(6, function() tick(n - 1) end)
    end
    UIManager:scheduleIn(6, function() tick(9) end)
end

D.camera = function(self, c, snap, x, w)
    local cam = self:dashCam(snap)
    if not cam then return nil end
    return { fill = true, min = 140, max = 18 + math.floor(w * 9 / 16) + 16, draw = function(y, h)
        local ph = h - 18 - 16
        c:text(x, y + 10, cam.name:upper(), 9.5, { bold = true, color = C.GREY, maxw = w - 120 })
        c:text(x + w, y + 10, self:takenText(self.ha.pictures[cam.id]), 9.5, { align = "end", color = C.GREY })
        self:picture(c, cam.id, x, y + 18, w, ph)
        c:hit(x, y + 18, w, ph, function() self:loadPicture(cam.id, true) end, function() self:go({ kind = "camera", id = cam.id }) end)
    end }
end

D.quick = function(self, c, snap, x, w, wide)
    local quick = Model.dashQuick(snap, self.ha.prefs)
    if #quick == 0 then return nil end
    local per = wide and 2 or 4
    local n = math.min(per * (wide and 2 or 1), #quick)
    local rows = math.ceil(n / per)
    return { h = 18 + rows * 72 + 6, draw = function(y)
        sectionLabel(c, x, y, _("QUICK"))
        local cols = math.min(per, n)
        local tw = (w - (cols - 1) * 8) / cols
        for i = 1, n do
            local col, row = (i - 1) % per, math.floor((i - 1) / per)
            self:tile(c, x + col * (tw + 8), y + 18 + row * 72, tw, 64, quick[i])
        end
    end }
end

--- The next thing with a time: a calendar event, else a To Do reminder in
-- the next day and a half. { title, when, open } or nil.
function View:dashNext(snap)
    local twelve = not KO.twentyFour()
    local function at(t)
        local d = os.date("*t", t)
        local h = twelve and ((d.hour + 11) % 12 + 1) or d.hour
        local day = os.date("%x", t) == os.date("%x") and _("Today") or os.date("%a", t)
        return day .. " " .. string.format(twelve and "%d:%02d %s" or "%02d:%02d", h, d.min, twelve and (d.hour < 12 and "AM" or "PM") or "")
    end
    local ev = Model.nextEvent(snap)
    if ev then return { title = ev.title, when = ev.allDay and _("All day") or at(ev.start) } end
    local todo = self:currentUI() and self:currentUI().todo
    if not (todo and todo.store) then return nil end
    local ok, best = pcall(function()
        local now, found = os.time(), nil
        for __, list in ipairs(todo.store:lists()) do
            for __, t in ipairs(list.tasks or {}) do
                if not t.completed and t.remindAt and t.remindAt > now and (not found or t.remindAt < found.t.remindAt) then
                    found = { t = t, listId = list.id }
                end
            end
        end
        if found and found.t.remindAt - now < 36 * 3600 then return found end
    end)
    if not (ok and best) then return nil end
    return { title = best.t.title, when = at(best.t.remindAt),
        open = function() todo:show({ kind = "task", listId = best.listId, taskId = best.t.id }) end }
end

--- To Do's tasks due today or before (overdue first), or nil without To Do.
function View:dashTasks()
    local todo = self:currentUI() and self:currentUI().todo
    if not (todo and todo.store) then return nil end
    local ok, out = pcall(function()
        local list, today = {}, todo:today()
        local hidden = todo.hiddenSet and todo:hiddenSet() or {}
        for __, l in ipairs(todo.store:lists()) do
            if not hidden[l.id] and l.wellknown ~= "flaggedEmails" then
                for __, t in ipairs(l.tasks or {}) do
                    if not t.completed and t.due and t.due <= today then
                        list[#list + 1] = { title = t.title, overdue = t.due < today, due = t.due, listId = l.id, id = t.id }
                    end
                end
            end
        end
        table.sort(list, function(a, b) if a.due ~= b.due then return a.due < b.due end return a.title < b.title end)
        return list
    end)
    return ok and out or nil
end

-- ------------------------------------------------------------------ dashboard parts and styles

--- The time ("9:41" and "AM", or "21:41" and nil) and os.date's table.
function View:clockText()
    local now = os.date("*t")
    local twelve = not KO.twentyFour()
    local hour = twelve and ((now.hour + 11) % 12 + 1) or now.hour
    return string.format(twelve and "%d:%02d" or "%02d:%02d", hour, now.min), twelve and (now.hour < 12 and "AM" or "PM") or nil, now
end

--- A one-line top for the styles that give the room to something else:
-- time and date at the left, the weather at the right. Returns where the rest starts.
function View:dashTop(c, snap)
    local time, ampm, now = self:clockText()
    local x = 24 + c:text(24, 50, time, 36, { bold = true }) + 6
    if ampm then x = x + c:text(x, 50, ampm, 13, { bold = true }) + 10 end
    local dw = c:text(x, 50, os.date("%a, %b ") .. now.day, 13, { color = C.GREY }) or 0
    self:drawBattery(c, x + dw + 14, 50 - 13 * 0.36, 13)
    c:hit(0, 0, c.W / 2, 66, function() self:back() end)
    local w = snap.weather
    if w then
        local text, icon = Model.weather(w.state)
        local tw = c:text(c.W - 24, 50, w.temp and Model.formatTemp(w.temp) or text, 22, { bold = true, align = "end" }) or 0
        c:icon(icon, c.W - 24 - tw - 34, 29, 26)
        c:hit(c.W / 2, 0, c.W / 2, 66, function() self:go({ kind = "weather" }) end)
    end
    c:hline(24, 66, c.W - 48, C.BLACK, 2)
    return 80
end

--- The status at the bottom: last update and keep-awake (tapping it goes
-- back), then ⋮ and the settings.
function View:dashFooter(c)
    c:hline(24, c.H - 40, c.W - 48, C.BLACK, 1)
    c:text(24, c.H - 18, self.ha:statusText(), 10.5, { color = C.GREY })
    c:text(c.W - 24 - 72, c.H - 18, self.ha:awakeText(), 10.5, { align = "end", color = C.GREY })
    c:hit(c.W / 2, c.H - 40, c.W / 2 - 72, 40, function() self:back() end)
    c:icon("ellipsis-vertical", c.W - 24 - 54, c.H - 31, 18)
    c:hit(c.W - 24 - 64, c.H - 40, 36, 40, function() self:titleAction("ellipsis-vertical") end)
    c:icon("settings", c.W - 24 - 18, c.H - 31, 18)
    c:hit(c.W - 24 - 28, c.H - 40, 52, 40, function() self:titleAction("settings") end)
end

--- The black bar: locks, garage, open doors, alarms, low batteries. 30 tall.
function View:attentionBar(c, x, y, w, snap)
    local prefs = self.ha.prefs
    local att = Model.attention(snap, prefs)
    local on = #Model.onNow(snap, prefs)
    c:box(x, y, w, 30, { r = 6, fill = C.FILL })
    c:icon(att.ok and "shield-check" or "triangle-alert", x + 10, y + 8, 15, true)
    c:text(x + 32, y + 20, att.text .. (on > 0 and ("  \u{00B7}  " .. T(_("%1 on"), on)) or ""), 11,
        { bold = true, color = C.ON_FILL, maxw = w - 44 })
end

--- The dashboard's camera (the one picked, or the next in turn), or nil.
function View:dashCam(snap)
    local prefs = self.ha.prefs
    local cams = Model.cameraList(snap, prefs)
    if prefs.dash_camera == "none" or #cams == 0 then return nil end
    if prefs.dash_camera and prefs.dash_camera ~= "cycle" and snap.byId[prefs.dash_camera] then
        return snap.byId[prefs.dash_camera]
    end
    return cams[(self.ha.dashCamera or 0) % #cams + 1]
end

--- Quick tiles in one row along the bottom (above the status). Returns the space they took.
function View:dashQuick(c, snap, x, w)
    local quick = Model.dashQuick(snap, self.ha.prefs)
    if #quick == 0 then return 0 end
    local yq = c.H - 48 - 96 + 14
    c:text(x, yq, _("QUICK"), 9.5, { bold = true, color = C.GREY })
    local n = math.min(c.W > c.H and 6 or 4, #quick)
    local tw = (w - (n - 1) * 8) / n
    for i = 1, n do self:tile(c, x + (i - 1) * (tw + 8), yq + 8, tw, 64, quick[i]) end
    return 96
end

--- Locks, garage doors and doors (not blinds): what Security shows.
local function securityDevices(self, snap)
    local out = {}
    for __, e in ipairs(visibleOf(self, snap, { lock = true, cover = true })) do
        if e.domain == "lock" or Model.icon(e) ~= "blinds" then table.insert(out, e) end
    end
    return out
end

local function lockAll(self, list)
    for __, e in ipairs(list) do
        if e.domain == "lock" and e.state == "unlocked" then self.ha:act(e, "lock.lock", { entity_id = e.id }) end
    end
end

local function unlockedCount(list)
    local n = 0
    for __, e in ipairs(list) do
        if e.domain == "lock" and e.state == "unlocked" then n = n + 1 end
    end
    return n
end

-- Security: the status, up to four cameras (six on its side), then the locks and doors with their buttons.
function S.dashSecurity(self, c, snap)
    local y = self:dashTop(c, snap)
    self:attentionBar(c, 24, y, c.W - 48, snap)
    y = y + 42
    local cams = Model.securityCams(snap, self.ha.prefs)
    local cols = c.W > c.H and 3 or 2
    local n = math.min(#cams, cols * 2)
    if n > 0 then
        local w = (c.W - 48 - (cols - 1) * 8) / cols
        local ph = math.floor(w * 9 / 16)
        for i = 1, n do
            local e = cams[i]
            local x = 24 + ((i - 1) % cols) * (w + 8)
            local yy = y + math.floor((i - 1) / cols) * (ph + 26)
            self:picture(c, e.id, x, yy, w, ph)
            c:hit(x, yy, w, ph + 20, function() self:loadPicture(e.id, true) end, function() self:go({ kind = "camera", id = e.id }) end)
            local taken = self:takenText(self.ha.pictures[e.id])
            c:text(x, yy + ph + 16, e.name, 10.5, { bold = true, maxw = w - c:width(taken, 9) - 10 })
            c:text(x + w, yy + ph + 16, taken, 9, { align = "end", color = C.GREY })
        end
        y = y + math.ceil(n / cols) * (ph + 26) + 6
    end
    local doors = securityDevices(self, snap)
    if #doors > 0 then
        c:text(24, y + 15, _("LOCKS & DOORS"), 9.5, { bold = true, color = C.GREY })
        if unlockedCount(doors) > 0 then
            self:button(c, c.W - 124, y, 100, 22, _("Lock all"), "lock", function() lockAll(self, doors) end)
        end
        y = y + 28
        for __, e in ipairs(doors) do
            if y + 46 > c.H - 44 then break end
            self:listRow(c, y, e, 24, c.W - 48)
            y = y + 46
        end
    end
    self:dashFooter(c)
    return 1
end

--- One card of Info cards: a label, a big value and a line under it.
function View:infoCard(c, x, y, w, h, label, big, sub, fn)
    c:box(x, y, w, h, { r = 10, border = C.BLACK, bw = 1.2 })
    c:text(x + 14, y + 22, label, 9.5, { bold = true, color = C.GREY, maxw = w - 28 })
    local size = c:width(big, 32, true) > w - 28 and 20 or 32
    c:text(x + 14, y + 66, big, size, { bold = true, maxw = w - 28 })
    if sub and sub ~= "" then c:text(x + 14, y + h - 14, sub, 10.5, { color = C.GREY, maxw = w - 28 }) end
    if fn then c:hit(x, y, w, h, fn) end
end

-- Info cards: big numbers for the weather, inside, doors, locks, the garage, lights, vacuums and batteries.
function S.dashInfo(self, c, snap)
    local prefs = self.ha.prefs
    local y = self:dashTop(c, snap)
    local cards = {}
    local function add(label, big, sub, fn) table.insert(cards, { label, big, sub, fn }) end
    local w = snap.weather
    if w then
        local text = Model.weather(w.state)
        local f = self.ha.forecast and self.ha.forecast[1]
        add(_("WEATHER"), w.temp and Model.formatTemp(w.temp) or text,
            text .. (f and f.high and ("  \u{00B7}  " .. Model.formatTemp(f.high) .. " / " .. (f.low and Model.formatTemp(f.low) or "\u{2013}")) or ""),
            function() self:go({ kind = "weather" }) end)
    end
    local temp, hum = Model.inside(snap, prefs)
    if temp then
        add(_("INSIDE"), Model.formatTemp(temp), hum and T(_("%1% humidity"), math.floor(hum + 0.5)) or "",
            function() self:go({ kind = "climate" }) end)
    end
    local doors = securityDevices(self, snap)
    local locks, unlocked, garage = 0, {}, nil
    for __, e in ipairs(doors) do
        if e.domain == "lock" then
            locks = locks + 1
            if e.state ~= "locked" then table.insert(unlocked, e.name) end
        elseif Model.icon(e) == "warehouse" and not garage then
            garage = e
        end
    end
    add(_("DOORS"), #snap.doors == 0 and _("Closed") or T(_("%1 open"), #snap.doors),
        #snap.doors > 0 and snap.doors[1].name or _("Doors and windows"), function() self:go({ kind = "security" }) end)
    if locks > 0 then
        add(_("LOCKS"), #unlocked == 0 and _("Locked") or T(_("%1 unlocked"), #unlocked),
            #unlocked > 0 and table.concat(unlocked, ", ") or (locks == 1 and _("1 lock") or T(_("All %1 locks"), locks)),
            function() self:go({ kind = "security" }) end)
    end
    if garage then
        local m = garage.changed and math.floor((snap.now - garage.changed) / 60)
        add(_("GARAGE"), Model.title(garage.state), m and T(_("Changed %1"), Model.ago(m * 60)) or "",
            function() self:tapEntity(garage) end)
    end
    local on, lights = 0, 0
    for __, e in ipairs(visibleOf(self, snap, { light = true })) do
        if not Model.isGroup(e) then
            lights = lights + 1
            if Model.isOn(e) then on = on + 1 end
        end
    end
    if lights > 0 then
        add(_("LIGHTS ON"), tostring(on), T(_("of %1 lights"), lights), function() self:go({ kind = "category", key = "lights" }) end)
    end
    for __, e in ipairs(visibleOf(self, snap, { vacuum = true })) do
        local battery = Model.num(e.attr.battery_level)
        add(e.name:upper(), Model.title(e.state), battery and T(_("Battery %1%"), math.floor(battery + 0.5)) or "",
            function() self:openSheet(e) end)
    end
    local batteries = Model.batteryList(snap, prefs)
    if #batteries > 0 then
        local low = batteries[1]
        add(_("LOWEST BATTERY"), math.floor(low.percent + 0.5) .. "%", Model.shortName(low.e), function() self:go({ kind = "batteries" }) end)
    end
    local cols = c.W > c.H and 4 or 2
    local cw = (c.W - 48 - (cols - 1) * 10) / cols
    local quickH = #Model.dashQuick(snap, prefs) > 0 and 96 or 0
    local bottom = c.H - 48 - quickH
    local ch = 104
    for i, card in ipairs(cards) do
        local x = 24 + ((i - 1) % cols) * (cw + 10)
        local yy = y + math.floor((i - 1) / cols) * (ch + 10)
        if yy + ch > bottom then break end
        self:infoCard(c, x, yy, cw, ch, card[1], card[2], card[3], card[4])
    end
    self:dashQuick(c, snap, 24, c.W - 48)
    self:dashFooter(c)
    return 1
end

-- Camera: one big picture, the status under it, Quick tiles.
function S.dashCamera(self, c, snap)
    local y = self:dashTop(c, snap)
    local quickH = self:dashQuick(c, snap, 24, c.W - 48)
    local bottom = c.H - 48 - quickH - 46
    local cam = self:dashCam(snap)
    if cam then
        -- As big as the space allows: upright, as tall as it goes (no taller
        -- than wide); on its side, as wide as 16:9 lets it, in the middle.
        -- The picture is cropped to fill it, never stretched.
        local pw = c.W - 48
        local ph = math.min(bottom - y - 20, pw)
        if pw > ph * 16 / 9 then pw = math.floor(ph * 16 / 9) end
        local px = (c.W - pw) / 2
        c:text(px, y + 8, cam.name:upper(), 9.5, { bold = true, color = C.GREY, maxw = pw - 120 })
        c:text(px + pw, y + 8, self:takenText(self.ha.pictures[cam.id]), 9.5, { align = "end", color = C.GREY })
        self:picture(c, cam.id, px, y + 16, pw, ph)
        c:hit(px, y + 16, pw, ph, function() self:loadPicture(cam.id, true) end, function() self:go({ kind = "camera", id = cam.id }) end)
    else
        c:text(c.W / 2, (y + bottom) / 2, _("No camera to show. Choose one in Settings > Dashboard."), 12, { align = "middle", color = C.GREY })
    end
    self:attentionBar(c, 24, bottom + 6, c.W - 48, snap)
    self:dashFooter(c)
    return 1
end

-- Clock only: a big clock in the middle, the date, the weather and the status under it.
function S.dashClock(self, c, snap)
    local time, ampm, now = self:clockText()
    local size = c.W > c.H and 150 or 128
    local tw = c:width(time, size, true)
    local aw = ampm and (c:width(ampm, 28, true) + 12) or 0
    local cy = c.H * 0.42
    local x = (c.W - tw - aw) / 2
    c:text(x, cy, time, size, { bold = true })
    if ampm then c:text(x + tw + 12, cy, ampm, 28, { bold = true }) end
    -- The date and the Kindle's battery, centred together.
    local date = os.date("%A, %B ") .. now.day
    local dw = c:width(date, 20)
    local bw = 20 * 1.6 + 3 + c:width("100%", 20)
    local dx = (c.W - dw - 22 - bw) / 2
    c:text(dx, cy + 46, date, 20, { color = C.GREY })
    self:drawBattery(c, dx + dw + 22, cy + 46 - 20 * 0.36, 20)
    c:hit(0, 0, c.W, cy, function() self:back() end)
    local w = snap.weather
    if w then
        local text, icon = Model.weather(w.state)
        local line = (w.temp and (Model.formatTemp(w.temp) .. "  ") or "") .. text
        local lw = c:width(line, 18, true) + 36
        c:icon(icon, (c.W - lw) / 2, cy + 74, 26)
        c:text((c.W - lw) / 2 + 36, cy + 95, line, 18, { bold = true })
        c:hit(0, cy + 66, c.W, 40, function() self:go({ kind = "weather" }) end)
    end
    if self.ha.prefs.dash_attention ~= false then
        local bw = math.min(c.W - 48, 460)
        self:attentionBar(c, (c.W - bw) / 2, cy + 126, bw, snap)
    end
    self:dashFooter(c)
    return 1
end

-- ------------------------------------------------------------------ security, climate, weather, activity, batteries, 3D printer

-- Security: the status, every lock and door with its button (and Lock all),
-- every camera, then door, window, motion and alarm sensors.
local SECURITY_SENSORS = { door = true, window = true, garage_door = true, opening = true, motion = true, occupancy = true,
    smoke = true, gas = true, carbon_monoxide = true, moisture = true, safety = true, problem = true, lock = true }

function S.security(self, c, snap)
    local F = c:flow(52, c.H - 8, self.pageNo)
    F:block(42, function(y) self:attentionBar(c, 14, y + 2, c.W - 28, snap) end)
    local doors = securityDevices(self, snap)
    if #doors > 0 then
        F:block(30, function(y)
            self:label(c, y, _("LOCKS & DOORS"))
            if unlockedCount(doors) > 0 then
                self:button(c, c.W - 114, y, 100, 22, _("Lock all"), "lock", function() lockAll(self, doors) end)
            end
        end, 46)
        for __, e in ipairs(doors) do
            F:block(46, function(y) self:listRow(c, y, e) end)
        end
        F:gap(10)
    end
    local cams = Model.securityCams(snap, self.ha.prefs)
    if #cams > 0 then
        F:block(26, function(y) self:label(c, y, _("CAMERAS")) end, 120)
        self:cameraGrid(c, F, cams)
        F:gap(4)
    end
    local sensors = {}
    for __, e in ipairs(visibleOf(self, snap, { binary_sensor = true })) do
        if SECURITY_SENSORS[Model.str(e.attr.device_class) or ""] then table.insert(sensors, e) end
    end
    if #sensors > 0 then
        F:block(26, function(y) self:label(c, y, _("SENSORS")) end, 38)
        self:sensorRows(c, F, sensors)
    end
    self:titlebar(c, true, _("Security"), { { "refresh-cw", function()
        for __, e in ipairs(cams) do self.ha.pictures[e.id] = nil end
        self.ha:update()
        UIManager:nextTick(function() self:loadPictures() end)
    end } }, F:pages())
    return F:pages()
end

--- A thermostat: its reading, what it is doing, and the set point with - and +.
function View:thermostat(c, y, e)
    local a = e.attr
    local x, w = 14, c.W - 28
    c:box(x, y, w, 112, { r = 10, border = C.BLACK, bw = 1.2 })
    c:text(x + 14, y + 26, e.name, 13, { bold = true, maxw = w / 2 })
    if e.area ~= "" then c:text(x + 14, y + 44, e.area, 10, { color = C.GREY, maxw = w / 2 }) end
    local cur = Model.num(a.current_temperature)
    c:text(x + 14, y + 92, cur and Model.formatTemp(cur) or "\u{2013}", 36, { bold = true })
    local doing = Model.str(a.hvac_action) and Model.title(a.hvac_action) or Model.title(e.state)
    local hum = Model.num(a.current_humidity)
    c:text(x + 110, y + 92, doing .. (hum and ("  \u{00B7}  " .. math.floor(hum + 0.5) .. "%") or ""), 10.5, { color = C.GREY, maxw = w / 2 - 110 })
    c:hit(x, y, w / 2, 112, function() self:openSheet(e) end)
    local target = Model.num(a.temperature)
    local bx = x + w - 14 - 160
    if target and e.state ~= "off" then
        local unit = self.ha.snap and self.ha.snap.weather and self.ha.snap.weather.unit
        local step = Model.tempStep(e, unit)
        local function set(dir)
            local v = target + dir * step
            local lo, hi = Model.num(a.min_temp), Model.num(a.max_temp)
            if lo and v < lo then v = lo end
            if hi and v > hi then v = hi end
            a.temperature = v
            self.ha:act(e, "climate.set_temperature", { entity_id = e.id, temperature = v })
        end
        c:text(bx + 80, y + 26, e.state == "cool" and _("COOL TO") or e.state == "heat" and _("HEAT TO") or _("SET TO"), 9.5,
            { bold = true, color = C.GREY, align = "middle" })
        self:button(c, bx, y + 44, 44, 44, "", "minus", function() set(-1) end)
        c:text(bx + 80, y + 76, Model.formatTemp(target), 22, { bold = true, align = "middle" })
        self:button(c, bx + 116, y + 44, 44, 44, "", "plus", function() set(1) end)
    else
        self:button(c, bx + 60, y + 44, 100, 36, _("Adjust"), nil, function() self:openSheet(e) end)
    end
end

-- Climate: thermostats with their set points, fans, then every room's temperature.
function S.climate(self, c, snap)
    local F = c:flow(52, c.H - 8, self.pageNo)
    for __, e in ipairs(visibleOf(self, snap, { climate = true })) do
        F:block(122, function(y) self:thermostat(c, y, e) end)
    end
    local fans = visibleOf(self, snap, { fan = true })
    if #fans > 0 then
        F:block(26, function(y) self:label(c, y, _("FANS")) end, 72)
        self:tiles(c, F, fans)
        F:gap(6)
    end
    local rooms = {}
    for __, r in ipairs(snap.rooms) do
        if (r.temp or r.humidity) and not (self.ha.prefs.hidden_rooms and self.ha.prefs.hidden_rooms[r.name]) then table.insert(rooms, r) end
    end
    rooms = Model.ordered(rooms, self.ha.prefs.room_order, function(r) return r.name end)
    if #rooms > 0 then
        F:block(26, function(y) self:label(c, y, _("ROOMS")) end, 36)
        for __, r in ipairs(rooms) do
            F:block(36, function(y)
                c:text(14, y + 23, r.name, 12, { maxw = c.W - 220 })
                c:text(c.W - 90, y + 23, r.temp and Model.formatTemp(r.temp) or "", 13, { bold = true, align = "end" })
                c:text(c.W - 14, y + 23, r.humidity and (math.floor(r.humidity + 0.5) .. "%") or "", 11, { align = "end", color = C.GREY })
                c:hline(14, y + 35, c.W - 14)
                c:hit(0, y, c.W, 36, function() self:go({ kind = "room", name = r.name }) end)
            end)
        end
    end
    self:titlebar(c, true, _("Climate"), {}, F:pages())
    return F:pages()
end

-- Weather: now (temperature, humidity, wind, inside), then the days ahead.
function S.weather(self, c, snap)
    local F = c:flow(52, c.H - 8, self.pageNo)
    local w = snap.weather
    if w then
        F:block(130, function(y)
            local text, icon = Model.weather(w.state)
            c:icon(icon, 14, y + 18, 64)
            local tw = c:text(96, y + 72, w.temp and Model.formatTemp(w.temp) or "", 52, { bold = true }) or 0
            c:text(96, y + 102, text, 16, { color = C.GREY })
            local lines = {}
            if w.humidity then table.insert(lines, T(_("Humidity %1%"), math.floor(w.humidity + 0.5))) end
            if w.wind then table.insert(lines, T(_("Wind %1 %2"), math.floor(w.wind + 0.5), w.windUnit or "")) end
            local inside = Model.inside(snap, self.ha.prefs)
            if inside then table.insert(lines, T(_("Inside %1"), Model.formatTemp(inside))) end
            for i, line in ipairs(lines) do
                c:text(c.W - 14, y + 30 + (i - 1) * 24, line, 12, { align = "end", color = i == 3 and C.BLACK or C.GREY, maxw = c.W - 130 - tw })
            end
        end)
    end
    -- The next hours, across.
    local hours = {}
    for __, f in ipairs(self.ha.hourly or {}) do
        local t = Model.isoTime(f.day)
        if t and t > os.time() - 1800 then table.insert(hours, f) end
    end
    if #hours > 0 then
        local n = math.min(#hours, c.W > c.H and 10 or 6)
        F:block(30, function(y) self:label(c, y + 4, _("NEXT HOURS")) end, 100)
        F:block(104, function(y)
            local cw = (c.W - 28) / n
            for i = 1, n do
                local f = hours[i]
                local x = 14 + (i - 1) * cw + cw / 2
                local text, icon = Model.weather(f.condition)
                c:text(x, y + 18, Model.hourLabel(f.day, KO.twentyFour()), 10, { align = "middle", color = C.GREY })
                c:icon(icon, x - 12, y + 28, 24)
                c:text(x, y + 76, f.high and Model.formatTemp(f.high) or "\u{2013}", 14, { bold = true, align = "middle" })
                if f.rain and f.rain > 0 then c:text(x, y + 94, f.rain .. "%", 9.5, { align = "middle", color = C.GREY }) end
            end
            c:hline(14, y + 103, c.W - 14)
        end)
        F:gap(6)
    end
    local days = self.ha.forecast or {}
    F:block(30, function(y) self:label(c, y + 4, _("NEXT DAYS")) end, 48)
    if #days == 0 then
        F:block(30, function(y) c:text(14, y + 20, _("Loading the forecast…"), 11, { color = C.GREY }) end)
    end
    for __, f in ipairs(days) do
        F:block(50, function(y)
            local text, icon = Model.weather(f.condition)
            c:text(14, y + 30, _(Model.dayName(f.day, snap.now)), 13, { bold = true, maxw = 150 })
            c:icon(icon, 170, y + 13, 24)
            c:text(206, y + 30, text, 12, { color = C.GREY, maxw = 170 })
            if f.rain and f.rain > 0 then c:text(c.W - 150, y + 30, f.rain .. "%", 11, { align = "end", color = C.GREY }) end
            c:text(c.W - 14, y + 30, (f.high and Model.formatTemp(f.high) or "\u{2013}") .. "  " .. (f.low and Model.formatTemp(f.low) or ""), 14,
                { bold = true, align = "end" })
            c:hline(14, y + 49, c.W - 14)
        end)
    end
    self:titlebar(c, true, _("Weather"), {}, F:pages())
    return F:pages()
end

-- Activity: what changed, newest first.
function S.activity(self, c, snap)
    local F = c:flow(52, c.H - 8, self.pageNo)
    local list = Model.activity(snap, self.ha.prefs)
    for i = 1, math.min(#list, 120) do
        local e = list[i]
        F:block(42, function(y)
            c:icon(Model.icon(e), 14, y + 12, 16)
            local ago = Model.ago(snap.now - e.changed)
            local aw = c:width(ago, 10)
            local state = Model.stateText(e)
            local sw = math.min(c:width(state, 11, true), 170)
            c:text(42, y + 26, e.name, 12, { maxw = c.W - 42 - aw - sw - 40 })
            c:text(c.W - 28 - aw, y + 26, state, 11, { bold = true, align = "end", maxw = 170 })
            c:text(c.W - 14, y + 26, ago, 10, { align = "end", color = C.GREY })
            c:hline(42, y + 41, c.W - 42)
            c:hit(0, y, c.W, 42, function() self:openSheet(e) end)
        end)
    end
    if #list == 0 then F:block(30, function(y) c:text(14, y + 20, _("Nothing to show."), 11, { color = C.GREY }) end) end
    self:titlebar(c, true, _("Activity"), { "refresh-cw" }, F:pages())
    return F:pages()
end

-- Batteries: every battery, lowest first, with a bar.
function S.batteries(self, c, snap)
    local F = c:flow(52, c.H - 8, self.pageNo)
    local list = Model.batteryList(snap, self.ha.prefs)
    for __, b in ipairs(list) do
        F:block(44, function(y)
            local e, pct = b.e, math.max(0, math.min(100, b.percent))
            local low = pct < 20
            c:icon(low and "battery-low" or (pct > 80 and "battery-full" or "battery-medium"), 14, y + 13, 18)
            local name = e.name:gsub("%s+[Bb]attery.*$", "")
            c:text(44, y + 21, name ~= "" and name or e.name, 12, { bold = low, maxw = c.W - 250 })
            if e.area ~= "" then c:text(44, y + 37, e.area, 9.5, { color = C.GREY, maxw = c.W - 250 }) end
            local bx, bw = c.W - 190, 110
            c:box(bx, y + 15, bw, 14, { r = 3, border = C.BLACK })
            if pct > 0 then c:box(bx + 2, y + 17, (bw - 4) * pct / 100, 10, { r = 2, fill = low and C.BLACK or C.GREY }) end
            c:text(c.W - 14, y + 28, math.floor(pct + 0.5) .. "%", 13, { bold = true, align = "end" })
            c:hline(44, y + 43, c.W - 44)
            c:hit(0, y, c.W, 44, function() self:openSheet(e) end)
        end)
    end
    if #list == 0 then F:block(30, function(y) c:text(14, y + 20, _("No batteries to show."), 11, { color = C.GREY }) end) end
    self:titlebar(c, true, _("Batteries"), {}, F:pages())
    return F:pages()
end

local function findId(list, ...)
    local words = { ... }
    for __, e in ipairs(list) do
        local ok = true
        for __, w in ipairs(words) do
            if w:sub(1, 1) == "-" then
                if e.id:find(w:sub(2), 1, true) then ok = false end
            elseif not e.id:find(w, 1, true) then
                ok = false
            end
        end
        if ok then return e end
    end
end

-- 3D printer: its camera, the print (state, progress, file, time left,
-- layers), its buttons, temperatures, then everything else it has.
function S.printer(self, c, snap)
    local list = Model.printer(snap, self.ha.prefs)
    local used = {}
    local function take(e) if e then used[e.id] = true end return e end
    local F = c:flow(52, c.H - 8, self.pageNo)
    local cam
    for __, e in ipairs(list) do
        if e.domain == "camera" then cam = take(e) break end
    end
    if cam then
        local pw = c.W - 28
        local ph = math.floor(pw * 9 / 16)
        F:block(ph + 30, function(y)
            local pic = self:picture(c, cam.id, 14, y, pw, ph)
            c:hit(14, y, pw, ph, function() self:loadPicture(cam.id, true) end, function() self:go({ kind = "camera", id = cam.id }) end)
            c:text(c.W - 14, y + ph + 18, self:takenText(pic), 10, { align = "end", color = C.GREY })
        end)
    end
    local status = take(findId(list, "machine_status")) or take(findId(list, "status", "-health", "-connection", "-manual", "-collection"))
    local progress = take(findId(list, "progress"))
    local file = take(findId(list, "current_file", "-thumbnail"))
    local left = take(findId(list, "remaining"))
    local layer, layers = take(findId(list, "current_layer")), take(findId(list, "total_layers"))
    F:block(96, function(y)
        c:text(14, y + 30, status and Model.title(status.state) or _("3D printer"), 20, { bold = true, maxw = c.W - 140 })
        local pct = progress and tonumber(progress.state)
        if pct then
            c:text(c.W - 14, y + 30, math.floor(pct + 0.5) .. "%", 20, { bold = true, align = "end" })
            c:box(14, y + 42, c.W - 28, 12, { r = 4, border = C.BLACK })
            if pct > 0 then c:box(16, y + 44, (c.W - 32) * math.min(100, pct) / 100, 8, { r = 3, fill = C.BLACK }) end
        end
        local parts = {}
        if file and file.state ~= "" and file.state ~= "unknown" then table.insert(parts, file.state) end
        if left and tonumber(left.state) then table.insert(parts, T(_("%1 left"), Model.sensorText(left))) end
        if layer and tonumber(layer.state) then
            table.insert(parts, T(_("Layer %1"), layer.state) .. (layers and tonumber(layers.state) and (" / " .. layers.state) or ""))
        end
        c:text(14, y + 80, table.concat(parts, "  \u{00B7}  "), 11, { color = C.GREY, maxw = c.W - 28 })
    end)
    -- Its buttons: pause, resume, then cancel and stop.
    local buttons = {}
    for __, icon in ipairs({ "pause", "play", "x" }) do
        for __, e in ipairs(list) do
            if e.domain == "button" and Model.icon(e) == icon then table.insert(buttons, take(e)) end
        end
    end
    if #buttons > 0 then
        F:block(48, function(y)
            local bw = (c.W - 28 - (#buttons - 1) * 8) / #buttons
            for i, e in ipairs(buttons) do
                local id = e.id
                local name = id:find("pause") and _("Pause") or id:find("resume") and _("Resume")
                    or id:find("cancel") and _("Cancel") or id:find("stop") and _("Stop") or Model.shortName(e)
                self:button(c, 14 + (i - 1) * (bw + 8), y + 4, bw, 36, name, Model.icon(e), function() self:tapEntity(e) end)
            end
        end)
    end
    local temps = {}
    for __, part in ipairs({ "nozzle", "bed", "chamber" }) do
        local now, want = findId(list, part, "temperature", "-target"), findId(list, part, "target")
        if now then take(now) take(want) table.insert(temps, { part, now, want }) end
    end
    if #temps > 0 then
        F:block(26, function(y) self:label(c, y, _("TEMPERATURES")) end, 70)
        F:block(72, function(y)
            local tw = (c.W - 28 - (#temps - 1) * 8) / #temps
            for i, t in ipairs(temps) do
                local x = 14 + (i - 1) * (tw + 8)
                c:box(x, y, tw, 64, { r = 8, border = C.BLACK })
                c:text(x + 12, y + 20, _(Model.title(t[1])), 10, { bold = true, color = C.GREY })
                c:text(x + 12, y + 50, Model.sensorText(t[2]), 18, { bold = true, maxw = tw - 24 })
                if t[3] and tonumber(t[3].state) and tonumber(t[3].state) > 0 then
                    c:text(x + tw - 12, y + 50, "/ " .. Model.sensorText(t[3]), 10.5, { align = "end", color = C.GREY })
                end
            end
        end)
        F:gap(6)
    end
    local switches, sensors = {}, {}
    for __, e in ipairs(list) do
        if not used[e.id] and e.domain ~= "button" and e.domain ~= "camera" then
            if e.domain == "sensor" or e.domain == "binary_sensor" then table.insert(sensors, e) else table.insert(switches, e) end
        end
    end
    if #switches > 0 then
        F:block(26, function(y) self:label(c, y, _("CONTROLS")) end, 46)
        for __, e in ipairs(switches) do F:block(46, function(y) self:listRow(c, y, e) end) end
        F:gap(6)
    end
    if #sensors > 0 then
        F:block(26, function(y) self:label(c, y, _("DETAILS")) end, 38)
        self:sensorRows(c, F, sensors)
    end
    if #list == 0 then F:block(30, function(y) c:text(14, y + 20, _("No 3D printer found."), 11, { color = C.GREY }) end) end
    self:titlebar(c, true, _("3D printer"), { "refresh-cw" }, F:pages())
    return F:pages()
end

-- ------------------------------------------------------------------ notifications

-- Home Assistant's own notice text: markdown links and bold made plain.
local function plain(s)
    s = s:gsub("%[([^%]]*)%]%([^%)]*%)", "%1"):gsub("%*%*", ""):gsub("__", "")
    return s
end

--- Lines of `s` at `size` no wider than `w` (at most `max`).
local function wrap(c, s, size, w, max)
    local lines = {}
    for para in (s .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in para:gmatch("%S+") do
            local try = line == "" and word or (line .. " " .. word)
            if c:width(try, size) > w and line ~= "" then
                table.insert(lines, line)
                line = word
            else
                line = try
            end
        end
        table.insert(lines, line)
        if #lines >= max then break end
    end
    while #lines > max do table.remove(lines) end
    return lines
end

-- Notifications: each with its message and Dismiss; Dismiss all.
function S.notifications(self, c, snap)
    local F = c:flow(52, c.H - 8, self.pageNo)
    local list = self.ha.notifications or {}
    if #list > 1 then
        F:block(40, function(y)
            self:button(c, c.W - 134, y + 4, 120, 28, _("Dismiss all"), "x", function() self.ha:dismiss(nil) end)
        end)
    end
    for __, n in ipairs(list) do
        local lines = wrap(c, plain(n.message), 11, c.W - 56, 8)
        F:block(56 + #lines * 17 + 44, function(y)
            local h = 48 + #lines * 17 + 36
            c:box(14, y, c.W - 28, h, { r = 10, border = C.BLACK })
            c:text(28, y + 26, plain(n.title ~= "" and n.title or _("Notification")), 13, { bold = true, maxw = c.W - 160 })
            local t = Model.isoTime and Model.isoTime(n.created)
            if t then c:text(c.W - 28, y + 26, Model.ago(os.time() - t), 9.5, { align = "end", color = C.GREY }) end
            for i, l in ipairs(lines) do c:text(28, y + 30 + i * 17, l, 11, { color = C.BLACK }) end
            self:button(c, c.W - 128, y + h - 38, 100, 28, _("Dismiss"), nil, function() self.ha:dismiss(n.id) end)
        end)
    end
    if #list == 0 then
        F:block(40, function(y) c:text(14, y + 24, self.ha.notifications and _("No notifications.") or _("Checking for notifications…"), 12, { color = C.GREY }) end)
    end
    self:titlebar(c, true, _("Notifications"), { { "refresh-cw", function() self.ha:loadNotifications(true) end } }, F:pages())
    return F:pages()
end

-- ------------------------------------------------------------------ sleep screen

--- The sleep screen: when it was, the weather, the status, each room's
-- temperature and the Quick tiles' states (no fingers: only drawn).
function View.drawSleep(ha, c)
    local snap, prefs = ha.snap, ha.prefs
    local now = os.date("*t")
    local twelve = not KO.twentyFour()
    local hour = twelve and ((now.hour + 11) % 12 + 1) or now.hour
    c:text(28, 72, os.date("%A, %B ") .. now.day, 22, { bold = true })
    c:text(28, 100, T(_("Sleeping since %1"), string.format(twelve and "%d:%02d %s" or "%02d:%02d", hour, now.min, twelve and (now.hour < 12 and "AM" or "PM") or "")), 12, { color = C.GREY })
    local y = 120
    local w = snap.weather
    if w then
        local text, icon = Model.weather(w.state)
        c:icon(icon, c.W - 28 - 44, 36, 44)
        c:text(c.W - 84, 70, w.temp and Model.formatTemp(w.temp) or "", 30, { bold = true, align = "end" })
        local f = ha.forecast and ha.forecast[1]
        c:text(c.W - 28, 100, text .. (f and f.high and ("  ·  " .. Model.formatTemp(f.high) .. " / " .. (f.low and Model.formatTemp(f.low) or "–")) or ""), 12,
            { align = "end", color = C.GREY })
    end
    c:hline(28, y, c.W - 56, C.BLACK, 2)
    y = y + 16
    local att = Model.attention(snap, prefs)
    c:box(28, y, c.W - 56, 34, { r = 6, fill = C.FILL })
    c:icon(att.ok and "shield-check" or "triangle-alert", 40, y + 9, 16, true)
    c:text(64, y + 23, att.text, 12, { bold = true, color = C.ON_FILL, maxw = c.W - 104 })
    y = y + 54
    local nn = ha.notifications and #ha.notifications or 0
    if nn > 0 then
        c:icon("bell", 28, y - 4, 18)
        c:text(54, y + 10, nn == 1 and _("1 notification") or T(_("%1 notifications"), nn), 12, { bold = true })
        y = y + 30
    end
    local temps = {}
    for __, r in ipairs(snap.rooms) do
        if r.temp and not (prefs.hidden_rooms and prefs.hidden_rooms[r.name]) then table.insert(temps, r) end
    end
    temps = Model.ordered(temps, prefs.room_order, function(r) return r.name end)
    if #temps > 0 then
        c:text(28, y + 6, _("INSIDE"), 10, { bold = true, color = C.GREY })
        local per = c.W > c.H and 6 or 4
        local cw = (c.W - 56) / per
        for i = 1, math.min(per * 2, #temps) do
            local r = temps[i]
            local x, yy = 28 + ((i - 1) % per) * cw, y + 16 + math.floor((i - 1) / per) * 50
            c:text(x, yy + 22, Model.formatTemp(r.temp), 20, { bold = true })
            c:text(x, yy + 40, r.name, 10, { color = C.GREY, maxw = cw - 8 })
        end
        y = y + 16 + math.ceil(math.min(per * 2, #temps) / per) * 50 + 16
    end
    local quick = Model.quick(snap, prefs)
    if #quick > 0 then
        c:text(28, y + 6, _("QUICK"), 10, { bold = true, color = C.GREY })
        y = y + 16
        local cols = 2
        local cw = (c.W - 56 - 16) / cols
        for i, e in ipairs(quick) do
            local x, yy = 28 + ((i - 1) % cols) * (cw + 16), y + math.floor((i - 1) / cols) * 44
            if yy + 44 > c.H - 50 then break end
            c:icon(Model.icon(e), x, yy + 10, 18)
            c:text(x + 28, yy + 25, e.name, 12, { maxw = cw - 130 })
            c:text(x + cw, yy + 25, Model.stateText(e), 12, { bold = Model.isOn(e), align = "end", maxw = 120 })
            c:hline(x + 28, yy + 40, cw - 28)
        end
    end
    c:hline(28, c.H - 40, c.W - 56, C.BLACK, 1)
    c:text(28, c.H - 18, ha:statusText(), 10.5, { color = C.GREY })
end

-- Settings, reordering and devices.
S.settings = Settings.settings
S.routines = Routines.screen
S.routine = Routines.edit
S.reorder = Settings.reorder
S.devices = Settings.devices

return View
