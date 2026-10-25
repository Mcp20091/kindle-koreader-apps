--[[--
The Syncthing app: on/off and what it is doing, requests to accept (new
devices and folders offered), the folders with their state, the devices,
and this Kindle's ID. Tap a folder or a device for what can be done with it;
the ⋮ menu has the settings. While open it reads Syncthing's status every few
seconds and redraws only when something shown changed. Long lists turn pages.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("stcanvas")
local KO = require("stko")
local M = require("stmodel")
local PS = require("pluginshare")

local Screen = Device.screen
local C = Canvas
local POLL = 5   -- seconds between status reads while open

-- Not modal: dialogs (menus, the keyboard) have to show on top of it.
local View = InputContainer:extend{
    covers_fullscreen = true,
    flash_on_uncover = true,   -- a full refresh when a dialog over it closes
    st = nil,   -- the plugin (main.lua)
}

function View:init()
    KO.flashOnUncover()
    self.page = 1
    self:relayout()
    self:schedulePoll()
end

--- A notification came or went (the shared service): the bell's count again.
function View:notificationsChanged()
    self:refresh(true)
end

function View:relayout()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = all } },
        Hold = { GestureRange:new{ ges = "hold", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    self:render()
end

function View:paintTo(bb, x, y)
    if self.w ~= Screen:getWidth() or self.h ~= Screen:getHeight() then self:relayout() end
    bb:paintRect(x, y, self.w, self.h, Blitbuffer.COLOR_WHITE)
    if self.canvas then self.canvas:paint(bb, x, y) end
end

--- Draw again; quiet: only put it on screen if something shown changed.
function View:refresh(quiet)
    local before = self.sig
    self:render()
    if quiet and before == self.sig then return end
    UIManager:setDirty(self, "ui")
end

-- Every few seconds while on top and Syncthing runs: the status again.
function View:schedulePoll()
    self.pollTask = self.pollTask or function()
        if UIManager:getTopmostVisibleWidget() == self and self.st:isRunning() and not self.st:isStarting() then
            -- (redrawn when it is in, only if something shown changed)
            self.st:refresh()
        end
        UIManager:scheduleIn(POLL, self.pollTask)
    end
    UIManager:unschedule(self.pollTask)
    UIManager:scheduleIn(POLL, self.pollTask)
end

function View:onCloseWidget()
    if self.pollTask then UIManager:unschedule(self.pollTask) end
end

function View:close()
    self.st:closeView()
end

function View:onClose()
    self:back()
    return true
end

--- Back: from the settings to the app; from the app (its only page) to the launcher.
function View:back()
    if self.mode == "settings" and self.settingsOnly then return self:close() end
    if self.mode == "settings" then
        self.mode, self.page = nil, self.mainPage or 1
        self:render()
        return UIManager:setDirty(self, "full")
    end
    self:home()
end

--- Back to the launcher (or, without one, to what was open before).
function View:home()
    self:close()
    if PS.appsHome then PS.appsHome() end
end

-- ------------------------------------------------------------------ gestures


function View:onTap(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and hit.tap then hit.tap() end
    return true
end

function View:onHold(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit then (hit.hold or hit.tap or function() end)() end
    return true
end

function View:onSwipe(_, ges)
    local d = ges.direction
    -- A swipe right from the left edge: back (as in the other apps); others turn pages.
    if KO.fromLeftEdge(ges) then return self:back() or true end
    if d == "west" or d == "north" then self:turn(1)
    elseif d == "east" or d == "south" then self:turn(-1)
    else UIManager:setDirty(self, "full") end
    return true
end

function View:turn(delta)
    local n = math.max(1, math.min(self.pages or 1, self.page + delta))
    if n == self.page then return end
    self.page = n
    self:render()
    UIManager:setDirty(self, "full")
end

-- ------------------------------------------------------------------ drawing

-- Text drawn and remembered, so a redraw that shows the same is skipped.
local function texter(c, seen)
    return function(x, y, s, size, opts)
        if s and s ~= "" then table.insert(seen, s) end
        return c:text(x, y, s, size, opts)
    end
end

function View:render()
    if self.canvas then self.canvas:release() end
    local c = Canvas.new(self.w, self.h)
    c.turn = function(d) self:turn(d) end
    local seen = {}
    local txt = texter(c, seen)
    self.canvas = c
    local st = self.st
    local running = st:isRunning()
    local starting = st:isStarting()
    local snap = running and not starting and st:status(60) or nil
    M.twentyFour = KO.twentyFour()

    if self.mode == "settings" then
        self:settingsPage(c, txt)
        self:titlebar(c, txt, _("Syncthing settings"))
        self.sig = table.concat(seen, "\n") .. "\nsettings " .. self.page .. "\n" .. (self.statusSig or "")
        return
    end

    -- the status card, with the switch
    c:box(14, 58, c.W - 28, 92, { r = 8, border = C.BLACK, bw = 1.3 })
    c:icon("folder-sync", 30, 76, 26)
    txt(68, 92, _("Syncthing"), 17, { bold = true })
    local line1, line2
    if not st:installed() then
        line1, line2 = _("Not installed"), _("The syncthing program is missing from the plugin's folder.")
    elseif starting then
        line1, line2 = _("Starting…"), ""
    elseif running then
        line1 = M.summary(snap)
        local ip = st:ip()
        line2 = snap and (M.devicesLine(snap.connected, snap.deviceCount) .. (ip and (" · " .. ip) or "")) or ""
    else
        line1 = _("Off")
        line2 = st:withWifi() and _("Starts when Wi-Fi connects") or _("Turn on to sync")
    end
    txt(68, 113, line1, 12.5, { color = C.GREY, maxw = c.W - 200 })
    txt(68, 133, line2, 11.5, { color = C.MID, maxw = c.W - 200 })
    -- On / Off: one icon button, black while on.
    KO.iconButtons(c, C, 14, 66, c.W - 28, { { icon = "power", text = running and _("On") or _("Off"), primary = running } },
        function() st:toggle() end)

    -- the lists, turning pages
    local footer = c.H - 40
    local flow = c:flow(168, footer - 8, self.page)
    local now = os.time()
    if snap then
        self:requests(c, txt, flow, snap)
        self:folders(c, txt, flow, snap.folders, now, true)
        self:devices(c, txt, flow, snap.devices, now, true)
    else
        local cfg = st:offline()
        local folders, devices = {}, {}
        for __, f in ipairs(cfg and cfg.folders or {}) do table.insert(folders, { folder = f }) end
        for __, d in ipairs(cfg and cfg.devices or {}) do table.insert(devices, { device = d, name = d.name }) end
        self:folders(c, txt, flow, folders, now, false)
        self:devices(c, txt, flow, devices, now, false)
    end
    self.pages = flow:pages()
    if self.page > self.pages then
        self.page = self.pages
        return self:render()
    end

    -- footer: this Kindle's ID; the pages; when it was read
    c:hline(0, footer, c.W, C.BLACK, 1.2)
    local id = st:deviceId()
    c:icon("qr-code", 14, footer + 10, 20)
    txt(42, footer + 25, id and T(_("This Kindle's ID: %1…"), M.shortId(id)) or _("This Kindle's ID: shown once Syncthing has run"),
        12.5, { maxw = c.W / 2 })
    if id then c:hit(0, footer, c.W / 2, 40, function() self:showId() end) end
    if snap then
        c:text(c.W - 14, footer + 25, T(_("Updated %1"), M.clock(st:statusTime(), KO.twentyFour())), 11.5,
            { color = C.MID, align = "end" })
    end
    self:titlebar(c, txt, _("Syncthing"))
    self.sig = table.concat(seen, "\n") .. "\n" .. self.page .. "\n" .. (self.statusSig or "")
end

--- The title bar all the apps share (as apps.koplugin's appsbar.lua):
--   ‹  ⌂  Title        [page count]  12:45 PM  ▭ 80%   ⟳   🔔   ⋮
-- ‹ one screen back (from the app itself, to the launcher); ⌂ the launcher;
-- ⟳ the status again and a full e-ink refresh; 🔔 the shared notifications,
-- with how many are unread. No ⌂ or 🔔 without the Apps plugin.
function View:titlebar(c, txt, title)
    local H = 44
    c:rect(0, 0, c.W, H, C.WHITE)
    c:hline(0, H, c.W, C.BLACK, 2)
    c:icon("chevron-left", 12, 13, 18)
    c:hit(0, 0, 40, H, function() self:back() end)
    local x = 42
    if PS.appsHome then
        c:icon("house", x + 2, 13, 18)
        c:hit(x - 4, 0, 34, H, function() self:home() end)
        x = x + 36
    end
    -- Recent apps (Apps' switcher), next to ⌂.
    if PS.showSwitcher then
        c:icon("history", x + 2, 13, 18)
        c:hit(x - 4, 0, 34, H, function() PS.showSwitcher() end)
        x = x + 36
    end
    local right = c.W - 32
    c:icon("ellipsis-vertical", right, 13, 18)
    c:hit(right - 8, 0, 40, H, function() self:menu() end)
    right = right - 34
    if PS.notify and PS.showNotifications then
        local ok, n = pcall(function() return PS.notifyCount and PS.notifyCount() or 0 end)
        n = ok and tonumber(n) or 0
        c:icon("bell", right, 13, 18)
        if n > 0 then
            local label = n > 99 and "99+" or tostring(n)
            local bw = math.max(14, c:width(label, 8, true) + 6)
            c:box(right + 10, 7, bw, 14, { r = 7, fill = C.FILL })
            txt(right + 10 + bw / 2, 18, label, 8, { bold = true, align = "middle", color = C.ON_FILL })
        end
        c:hit(right - 8, 0, 34, H, function() PS.showNotifications() end)
        right = right - 34
    end
    c:icon("refresh-cw", right, 13, 18)
    c:hit(right - 8, 0, 34, H, function() self:reload() end)
    right = right + 18 - 34 - 14
    -- The time and battery; ▾ (a tap on them drops down the control center).
    local statusRight = right
    if PS.showControlCenter then
        c:icon("chevron-down", right - 12, 16, 12)
        right = right - 16
    end
    local powerd = Device:getPowerDevice()
    local okB, pct = pcall(function() return powerd:getCapacity() end)
    local okC, charging = pcall(function() return powerd:isCharging() end)
    pct, charging = okB and tonumber(pct) or nil, okC and charging == true
    if pct then
        local tw = c:width(pct .. "%", 11)
        c:text(right, 26, pct .. "%", 11, { align = "end" })
        local bx = right - tw - 3 - 18
        c:icon(charging and "battery-charging" or "battery", bx, 13, 18)
        if not charging and pct > 0 then
            -- Filled as far as it is charged (inside Lucide's outline: 3..17 by 7..17 of 24).
            local k = 18 / 24
            c:box(bx + 4.5 * k, 13 + 8.5 * k, 11 * k * math.min(100, pct) / 100, 7 * k, { fill = C.BLACK })
        end
        right = bx - 10
    end
    -- What's running now (the web server…), as every app's corner shows it.
    local running = {}
    local okI, icons = pcall(function() return PS.statusIcons and PS.statusIcons() or {} end)
    for __, icon in ipairs(okI and icons or {}) do
        local is = 11 * 1.45
        c:icon(icon, right - is, 22 - is / 2, is)
        right = right - is - 8
        table.insert(running, icon)
    end
    -- (in the screen's signature, so a change redraws it)
    self.statusSig = table.concat(running, ",")
    local clock = M.clock(os.time(), KO.twentyFour())
    c:text(right, 26, clock, 11, { bold = true, align = "end" })
    -- A tap on the time and battery: the control center (Apps).
    if PS.showControlCenter then
        local from = right - c:width(clock, 11, true)
        c:hit(from - 6, 0, statusRight - from + 12, H, function() PS.showControlCenter() end)
    end
    right = right - c:width(clock, 11, true)
    -- The page count, when there is more than one page.
    if (self.pages or 1) > 1 then
        local label = self.page .. "/" .. self.pages
        local lw = c:width(label, 11) + 40
        right = right - lw - 14
        c:icon("chevron-left", right + 2, 15, 14)
        txt(right + lw / 2, 27, label, 11, { align = "middle", color = C.GREY })
        c:icon("chevron-right", right + lw - 16, 15, 14)
        c:hit(right - 6, 0, lw / 2 + 6, H, function() self:turn(-1) end)
        c:hit(right + lw / 2, 0, lw / 2 + 6, H, function() self:turn(1) end)
    end
    txt(x, 28, title, 15, { bold = true, maxw = math.max(40, right - x - 8) })
end

--- ⟳: the status again, and a full e-ink refresh.
function View:reload()
    self.st:refresh()
    self:render()
    UIManager:setDirty(self, "full")
end

local function section(txt, y, label)
    txt(14, y + 14, label, 11, { bold = true, color = C.GREY })
end

function View:requests(c, txt, flow, snap)
    local n = #snap.pendingDevices + #snap.pendingFolders
    if n == 0 then return end
    flow:block(24, function(y) section(txt, y, _("REQUESTS")) end, 54)
    local st = self.st
    -- (the text beside the two buttons: up to their left edge)
    local textW = c.W - 46 - 2 * ((c.W - 36 - 40) / 5) - 10 - 30
    local function buttons(y, accept, ignore)
        KO.iconButtons(c, C, 0, y - 2, c.W + 4, {
            { icon = "x", text = _("Ignore"), fn = ignore },
            { icon = "check", text = _("Accept"), primary = true, fn = accept },
        }, function(b) b.fn() end)
    end
    for __, p in ipairs(snap.pendingDevices) do
        flow:block(76, function(y)
            c:icon("user-plus", 14, y + 18, 20)
            txt(46, y + 32, T(_("%1 wants to connect"), p.name or M.shortId(p.id)), 14, { bold = true, maxw = textW })
            txt(46, y + 50, T(_("Device %1"), M.shortId(p.id)) .. (p.address and (" · " .. p.address) or ""), 11,
                { color = C.MID, maxw = textW })
            buttons(y, function() self:acceptDevice(p) end, function()
                self:act("ignoreDevice", { device = p.id, name = p.name, address = p.address }, function()
                    KO.undo(T(_("%1 ignored"), p.name or M.shortId(p.id)), function()
                        self:act("unignoreDevice", { device = p.id })
                    end)
                end)
            end)
        end)
    end
    for __, p in ipairs(snap.pendingFolders) do
        flow:block(76, function(y)
            c:icon("folder-plus", 14, y + 18, 20)
            txt(46, y + 32, T(_("%1 shares “%2”"), p.fromName, p.label), 14, { bold = true, maxw = textW })
            txt(46, y + 50, T(_("Save to %1"), st:folderPath(p.label)), 11, { color = C.MID, maxw = textW })
            buttons(y, function() self:acceptFolder(p) end, function()
                self:act("ignoreFolder", { folder = p.id, label = p.label, from = p.from }, function()
                    KO.undo(T(_("“%1” ignored"), p.label), function()
                        self:act("unignoreFolder", { folder = p.id, from = p.from })
                    end)
                end)
            end)
        end)
    end
    flow:gap(14)
end

function View:folders(c, txt, flow, folders, now, running)
    local st = self.st
    flow:block(24, function(y)
        section(txt, y, _("FOLDERS"))
        if running and #folders > 0 then
            txt(c.W - 14, y + 14, _("Rescan all"), 11.5, { bold = true, align = "end" })
            c:hit(c.W - 120, y - 8, 120, 34, function()
                if self:act("rescan", {}) then self:say(_("Rescanning all folders…")) end
            end)
        end
    end, 70)
    if #folders == 0 then
        flow:block(56, function(y)
            c:para(14, y + 20, running and _("No folders yet. Share a folder with this Kindle from Syncthing on another device; it shows here under Requests.")
                or _("No folders yet."), 12.5, c.W - 28, 18, { color = C.GREY })
        end)
    end
    for __, f in ipairs(folders) do
        local folder, status = f.folder, f.status
        local label, busy = M.folderState(folder, status)
        local syncing = running and status and status.state == "syncing"
        local h = syncing and 84 or 70
        flow:block(h, function(y)
            c:icon("folder", 14, y + 6, 20)
            txt(46, y + 21, folder.label, 15, { maxw = c.W - 46 - 150 })
            if running then
                txt(c.W - 14, y + 21, label, 12.5, { bold = busy, align = "end", color = busy and C.BLACK or C.GREY })
            end
            local info = folder.path or ""
            if status and status.localFiles then
                info = info .. " · " .. T(_("%1 files"), status.localFiles) .. " · " .. M.bytes(status.localBytes)
            end
            txt(46, y + 40, info, 11, { color = C.MID, maxw = c.W - 60 })
            local last
            if not running then
                last = folder.paused and _("Paused") or ""
            elseif folder.paused then
                last = _("Paused on this Kindle")
            elseif syncing then
                local need = M.need(status)
                last = T(_("%1 left · %2"), T(need == 1 and _("1 file") or _("%1 files"), need), M.bytes(status.needBytes))
            else
                local lf = f.stats and f.stats.lastFile
                if lf and lf.filename and lf.filename ~= "" then
                    last = lf.filename .. " · " .. (M.ago(M.parseTime(lf.at), now) or "")
                end
            end
            if syncing then
                local bw = c.W - 14 - 46
                c:box(46, y + 50, bw, 7, { r = 3.5, border = C.BLACK, bw = 1 })
                local p = M.progress(status)
                if p > 0 then c:box(46, y + 50, math.max(7, bw * p), 7, { r = 3.5, fill = C.BLACK }) end
                txt(46, y + 74, last, 11, { color = C.MID, maxw = c.W - 60 })
            else
                txt(46, y + 57, last, 11, { color = C.MID, maxw = c.W - 60 })
            end
            c:hline(46, y + h - 4, c.W - 46, C.LIGHT)
            c:hit(0, y, c.W, h - 2, function() self:folderMenu(f, running) end)
        end)
    end
    flow:gap(18)
end

function View:devices(c, txt, flow, devices, now, running)
    flow:block(24, function(y) section(txt, y, _("DEVICES")) end, 40)
    if #devices == 0 then
        flow:block(56, function(y)
            c:para(14, y + 20, _("No devices yet. In Syncthing on your computer or phone, add this Kindle with its ID (below), then accept it here."),
                12.5, c.W - 28, 18, { color = C.GREY })
        end)
    end
    for __, d in ipairs(devices) do
        flow:block(40, function(y)
            local name = d.name or M.shortId(d.device.deviceID)
            local icon = name:lower():find("phone") or name:lower():find("pixel") or name:lower():find("galaxy") or name:lower():find("android")
            c:icon(icon and "smartphone" or "monitor", 14, y + 6, 20)
            txt(46, y + 21, name, 15, { maxw = c.W - 46 - 200 })
            if running then
                local label, on = M.deviceState(d.device, d.conn, d.completion, d.lastSeen, now)
                txt(c.W - 14, y + 21, label, 12.5, { bold = on, align = "end", color = on and C.BLACK or C.GREY })
            elseif d.device.paused then
                txt(c.W - 14, y + 21, _("Paused"), 12.5, { align = "end", color = C.GREY })
            end
            c:hline(46, y + 36, c.W - 46, C.LIGHT)
            c:hit(0, y, c.W, 38, function() self:deviceMenu(d, running) end)
        end)
    end
end

-- ------------------------------------------------------------------ dialogs

--- Text to read (details, help) in the apps' box: o as KO.message.
function View:message(o)
    KO.message(o)
end

--- A short notice for a moment, in the apps' own style. (Not called "toast": KOReader stacks
-- any widget with a "toast" field as a toast, under which dialogs would go.)
function View:say(text)
    KO.toast(text)
end


-- An action (done in the background), with a message if it failed; then
-- success(), if given.
function View:act(name, args, success)
    local function failed(err) self:say(T(_("Syncthing couldn't do that: %1"), tostring(err or "?"))) end
    local ok, err = self.st:act(name, args, function(done, e)
        if not done then return failed(e) end
        if success then success() end
    end)
    if not ok then failed(err) end
    return ok
end

function View:folderMenu(f, running)
    local folder, status = f.folder, f.status
    local items = {}
    if running then
        table.insert(items, { text = _("Rescan"), fn = function()
            if self:act("rescan", { folder = folder.id }) then self:say(T(_("Rescanning %1…"), folder.label)) end
        end })
        table.insert(items, { text = folder.paused and _("Resume") or _("Pause"), fn = function()
            self:act("pauseFolder", { folder = folder.id, paused = not folder.paused })
        end })
    end
    if folder.path then
        table.insert(items, { text = _("Open in Library"), fn = function() self:openFolder(folder.path) end })
    end
    table.insert(items, { text = _("Details"), fn = function()
        local lines = { T(_("Folder: %1"), folder.path or "?") }
        if running then table.insert(lines, T(_("State: %1"), (M.folderState(folder, status)))) end
        if status then
            table.insert(lines, T(_("On this Kindle: %1 files, %2"), status.localFiles or 0, M.bytes(status.localBytes)))
            table.insert(lines, T(_("In all: %1 files, %2"), status.globalFiles or 0, M.bytes(status.globalBytes)))
            local errs = (tonumber(status.pullErrors) or 0) + (tonumber(status.errors) or 0)
            if errs > 0 then table.insert(lines, T(_("Errors: %1"), errs)) end
        end
        local scan = f.stats and M.parseTime(f.stats.lastScan)
        if scan then table.insert(lines, T(_("Last scan: %1"), M.ago(scan, os.time()))) end
        if f.shared and #f.shared > 0 then table.insert(lines, T(_("Shared with: %1"), table.concat(f.shared, ", "))) end
        table.insert(lines, T(_("Folder ID: %1"), folder.id))
        KO.read{ title = folder.label, text = table.concat(lines, "\n"),
            ok = folder.path and _("Open") or nil, okIcon = "folder", onOk = folder.path and function() self:openFolder(folder.path) end or nil }
    end })
    local sub = running and (M.folderState(folder, status)) or nil
    KO.list(sub and (folder.label .. " · " .. sub) or folder.label, items)
end

function View:openFolder(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "directory" then
        return self:say(T(_("%1 isn't on the Kindle yet"), path))
    end
    self:close()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance.file_chooser:changeToPath(path)
    else
        local rui = require("apps/reader/readerui").instance
        if rui then rui:onClose() end
        FileManager:showFiles(path)
    end
end

function View:deviceMenu(d, running)
    local device = d.device
    local name = d.name or M.shortId(device.deviceID)
    local items = {}
    if running then
        table.insert(items, { text = device.paused and _("Resume") or _("Pause"), fn = function()
            self:act("pauseDevice", { device = device.deviceID, paused = not device.paused })
        end })
    end
    table.insert(items, { text = _("Details"), fn = function()
        -- (the ID in two lines: it has no spaces to wrap at)
        local id = (tostring(device.deviceID):gsub("^([^-]+%-[^-]+%-[^-]+%-[^-]+%-)", "%1\n"))
        local lines = { _("Device ID:"), id }
        if d.conn and d.conn.connected then
            table.insert(lines, T(_("Address: %1"), d.conn.address or "?"))
            if d.conn.clientVersion and d.conn.clientVersion ~= "" then table.insert(lines, T(_("Version: %1"), d.conn.clientVersion)) end
        end
        if d.completion and d.completion.needItems and d.completion.needItems > 0 then
            table.insert(lines, T(_("It still needs: %1 files, %2"), d.completion.needItems, M.bytes(d.completion.needBytes)))
        end
        if d.lastSeen then table.insert(lines, T(_("Last seen: %1"), M.ago(d.lastSeen, os.time()))) end
        -- (Copy: the device's ID)
        KO.read{ title = name, text = table.concat(lines, "\n"), copy = device.deviceID,
            ok = running and (device.paused and _("Resume") or _("Pause")) or nil, okIcon = device.paused and "play" or "pause",
            onOk = running and function() self:act("pauseDevice", { device = device.deviceID, paused = not device.paused }) end or nil }
    end })
    local sub = running and (M.deviceState(device, d.conn, d.completion, d.lastSeen, os.time())) or nil
    KO.list(sub and (name .. " · " .. sub) or name, items)
end

--- A text box: the launcher's (icon buttons, the pen for names and folders when
-- handwriting is set up) or, without it, KOReader's InputDialog. o = { title,
-- subtitle, text, hint, ok, okIcon, password, number, pen, keep (check(text)
-- returns a reason to stay open), done(text) }.
function View:askText(o)
    local P = PS.popup
    local okReq, request = pcall(function() return P and P.request end)
    if okReq and request then
        local hw = PS.handwriting
        local okPen, pen = pcall(function() return o.pen and hw and hw.available() end)
        return request{ title = o.title, subtitle = o.subtitle, text = o.text or "", hint = o.hint, typing = true,
            password = o.password, number = o.number,
            pen = (okPen and pen) and true or nil, penTitle = o.title, penKind = "text",
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = o.okIcon or "check", text = o.ok or _("Save"), primary = true, needsText = true, keep = o.check ~= nil,
                    fn = function(v, box)
                        if o.check then
                            local why = o.check(v)
                            if why then return self:say(why) end
                            box:stopTyping()
                            box:close()
                        end
                        o.done(v)
                    end },
            } }
    end
    local dialog
    dialog = InputDialog:new{
        title = o.title,
        description = o.subtitle,
        input = o.text or "",
        input_hint = o.hint,
        input_type = o.number and "number" or nil,
        text_type = o.password and "password" or nil,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = o.ok or _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText()
                if v == "" then return end
                local why = o.check and o.check(v)
                if why then return self:say(why) end
                UIManager:close(dialog)
                o.done(v)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function View:acceptDevice(p)
    self:askText{ title = _("Add device"), subtitle = T(_("Device ID: %1"), M.shortId(p.id) .. "…"),
        text = p.name or "", hint = _("Name"), ok = _("Add"), okIcon = "plus", pen = true,
        done = function(name)
            self:act("acceptDevice", { device = p.id, name = name }, function()
                self:message{ title = T(_("%1 added"), name ~= "" and name or M.shortId(p.id)),
                    text = _("Now share a folder with this Kindle from it, then accept the folder here.") }
            end)
        end }
end

function View:acceptFolder(p)
    self:askText{ title = T(_("Add “%1”"), p.label), subtitle = T(_("From %1. The folder on the Kindle:"), p.fromName),
        text = self.st:folderPath(p.label), ok = _("Add"), okIcon = "plus", pen = true,
        check = function(path)
            if not path:match("^/") then return _("The folder must be a full path, such as /mnt/us/documents/Books") end
        end,
        done = function(path)
            self:act("acceptFolder", { folder = p.id, label = p.label, from = p.from, path = path })
        end }
end

--- This Kindle's ID as a QR code, to add it from Syncthing on a phone or computer;
-- Copy puts the ID on KOReader's clipboard.
function View:showId()
    local id = self.st:deviceId()
    if not id then return end
    require("stidbox").show(id, function(text) self:say(text) end)
end

function View:menu()
    local st = self.st
    local running = st:isRunning()
    KO.menu(st.ui, self, {
        { _("This Kindle's ID"), function()
            if st:deviceId() then self:showId() else self:say(_("Shown once Syncthing has run")) end
        end },
        { running and T(_("Web GUI: %1"), (st:guiAddress():gsub("^http://", ""))) or _("Web GUI"), function()
            if not running then return self:say(_("Turn Syncthing on first")) end
            KO.read{ title = _("Web GUI"), copy = st:guiAddress(),
                text = T(_("Syncthing's own web page, for settings not in this app:\n%1\n\nOpen it in a browser on the same Wi-Fi. User name: syncthing. Set a password first."),
                    st:guiAddress()),
                ok = _("Password"), okIcon = "key-round", onOk = function() self:askPassword() end }
        end },
        { _("Help"), function() self:help() end },
    }, function() self:settings() end)
end

function View:settings()
    if self.mode ~= "settings" then self.mainPage = self.page end
    self.mode, self.page = "settings", 1
    self:render()
    UIManager:setDirty(self, "full")
end

-- An on/off switch, as in Home Assistant's settings.
local function toggle(c, x, y, on, fn)
    c:box(x, y, 40, 22, { r = 11, fill = on and C.FILL or C.WHITE, border = C.BLACK })
    c:circle(x + (on and 29 or 11), y + 11, 7, on and C.ON_FILL or C.BLACK)
    c:hit(x - 10, y - 8, 60, 38, fn)
end

--- The settings page: section headings, one row per setting with its value
-- (or a switch) on the right; more than fit turn pages.
--- The settings page's rows: { heading } or { name, value (a switch: true or
-- false), fn }. Also what the launcher's search finds (view may be nil then).
function View.settingsRows(st, view)
    return {
        { _("SYNCING") },
        { _("Start with Wi-Fi"), st:withWifi(), function()
            st:setWithWifi(not st:withWifi())
            view:refresh()
        end },
        { _("WEB GUI") },
        { _("Password"), "", function() view:askPassword() end },
        { _("Port"), st:port(), function() view:askPort() end },
    }
end

function View:settingsPage(c, txt)
    local rows = View.settingsRows(self.st, self)
    local F = c:flow(56, c.H - 8, self.page)
    for __, row in ipairs(rows) do
        local name, value, fn = row[1], row[2], row[3]
        if value == nil then
            F:gap(10)
            F:block(24, function(y) txt(14, y + 16, name, 9.5, { bold = true, color = C.GREY }) end, 36)
        else
            F:block(36, function(y)
                txt(14, y + 23, name, 12, { maxw = 330 })
                if type(value) == "boolean" then
                    toggle(c, c.W - 54, y + 7, value, fn)
                else
                    txt(c.W - 32, y + 23, value, 11, { align = "end", color = C.GREY, maxw = 250 })
                    c:icon("chevron-right", c.W - 26, y + 12, 12)
                end
                c:hit(0, y, c.W, 36, fn)
                c:hline(14, y + 35, c.W - 14)
            end)
        end
    end
    self.pages = F:pages()
end

function View:askPassword()
    if not self.st:isRunning() then return self:say(_("Turn Syncthing on first")) end
    self:askText{ title = _("Web GUI password"), subtitle = _("For Syncthing's own web page. User name: syncthing."),
        password = true, ok = _("Set"),
        done = function(pw)
            self:act("password", { password = pw }, function() self:say(_("Password set")) end)
        end }
end

function View:askPort()
    if self.st:isRunning() then return self:say(_("Turn Syncthing off to change the port")) end
    self:askText{ title = _("Port"), subtitle = _("Syncthing's web GUI and API (8384 unless something else uses it)."),
        text = self.st:port(), number = true,
        check = function(v)
            local n = tonumber(v)
            if not n or n < 1024 or n > 65535 then return _("Pick a port from 1024 to 65535") end
        end,
        done = function(v)
            self.st:setPort(math.floor(tonumber(v)))
            self:refresh()
        end }
end

function View:help()
    KO.read{ title = _("Syncthing"), text = _([[Keeps folders on this Kindle in sync with your computer or phone, directly over Wi-Fi.

1. Install Syncthing on your computer or phone.
2. Turn Syncthing on here, then add this Kindle there with its ID (at the bottom; scan or type it).
3. Accept the request here, under Requests.
4. Share a folder with the Kindle there, then accept it here.

Tap a folder or a device for what you can do with it. Nothing syncs while the Kindle sleeps.]]),
        ok = _("Kindle ID"), okIcon = "key-round", onOk = function()
            if self.st:deviceId() then self:showId() else self:say(_("Shown once Syncthing has run")) end
        end }
end

return View
