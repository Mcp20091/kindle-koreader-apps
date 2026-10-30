--[[--
Syncthing: keeps folders on the Kindle in sync with your other devices,
peer to peer over Wi-Fi. A full-screen app (on/off, requests to accept,
folders, devices, this Kindle's ID), a line for the Apps launcher, and calls
for the web page's Syncthing tab. Can start by itself when Wi-Fi connects.

Based on koreader-syncthing by jasonchoimtt (AGPL-3.0): the same folder name,
settings (settings/syncthing) and start script, so it takes its place.

@module koplugin.syncthing
]]

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local JSON = require("json")
local _ = require("gettext")
local T = ffiutil.template

local API = require("stapi")
local Canvas = require("stcanvas")
local M = require("stmodel")

local PID_FILE = "/tmp/syncthing_koreader.pid"
-- Syncthing's own ports: devices connect on 22000, and find each other on the Wi-Fi on 21027.
local SYNC_PORT, DISCOVERY_PORT = 22000, 21027

-- Kept while KOReader runs (each book and the library get a new plugin).
local state = {
    snap = nil,         -- the last status read (API:snapshot)
    snapTime = 0,
    view = nil,         -- the app, when showing
    stopped = false,    -- turned off by hand: Start with Wi-Fi waits for the next connection
    starting = nil,     -- when it was started, until it answers
    cancel = nil,       -- turned off while starting
    stopping = nil,     -- the process being stopped
    fetching = false,   -- a status read in the background
    waiting = {},       -- what waits for it
    line = nil,         -- the launcher's line last shown
    offBy = nil,        -- when to turn off even if not up to date (Turn off when up to date, Sync now)
}

local Syncthing = WidgetContainer:extend{
    name = "syncthing",
    is_doc_only = false,
}

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- This Kindle's address on the Wi-Fi (no packet is sent to find it).
local function localIp()
    local socket = require("socket")
    local udp = socket.udp()
    if not udp then return nil end
    udp:setpeername("192.0.2.1", 9)
    local ip = udp:getsockname()
    udp:close()
    if ip and ip ~= "0.0.0.0" then return ip end
end

-- The Syncthing plugin of the open library or book.
local function current()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    return ui and ui.syncthing
end

-- The Syncthing app (from a notification, the launcher's lists); "settings":
-- its settings page.
local function openApp(page)
    local st = current()
    if st then st:show(page) end
end

--- The ongoing notification while Syncthing runs: its icon shows in every app's clock
-- corner (shared notifications, when the launcher is there).
local function runningNote(on)
    local PS = require("pluginshare")
    -- (what waited for it to be up to date ends when it stops)
    if not on then state.offBy = nil end
    if on then
        if PS.notify then
            pcall(PS.notify, { app = "syncthing", key = "syncthing:running", ongoing = true, icon = "folder-sync",
                name = _("Syncthing"), text = _("Syncthing is on. Tap to open it."), open = openApp, route = {} })
        end
    elseif PS.unnotify then
        pcall(PS.unnotify, "syncthing:running")
    end
end

function Syncthing:init()
    Canvas.setDir(self.path)
    local PS = require("pluginshare")
    PS.notifyOpeners = PS.notifyOpeners or {}
    PS.notifyOpeners.syncthing = function() openApp() end
    -- What it is for the launcher and the web page: its tile, Settings group, web tab
    -- (apps.koplugin/appsinfo.lua).
    PS.appInfo = PS.appInfo or {}
    PS.appInfo.syncthing = { name = _("Syncthing"), icon = "folder-sync", dir = self.path, order = 60, group = "tools",
        -- "On · Up to date", "On · Syncing · 3 files left", "Off".
        tiles = { { key = "syncthing", event = "ShowSyncthing", line = function(s) return s:appsLine() end } },
        gestures = { "^syncthing_", "^toggle_syncthing_server$" },
        web = { page = "syncthing", routes = "websyncthing", script = "web/syncthing.js",
            card = "Folders, devices and requests." } }
    -- The web page's backup: the settings always; Syncthing's own folder (its
    -- config, this Kindle's keys and so its device ID, its database) only with
    -- "Include keys and sign-ins".
    PS.backupApps = PS.backupApps or {}
    PS.backupApps.syncthing = { key = "syncthing", name = _("Syncthing"),
        reader_keys = { "^syncthing_" },
        secret_dirs = { "settings/syncthing" },
        -- (Syncthing has its database open while it runs: stop it before files are put back)
        beforeRestore = function()
            local st = current()
            if st then st:stopNow() end
        end }
    -- The launcher's Settings list, its search and its Set up your Kindle.
    if PS.registerSettings then
        -- (rows: each setting by name, for the launcher's search; one page, so open() needs no name)
        PS.registerSettings{ key = "syncthing", name = _("Syncthing"), icon = "folder-sync",
            open = function() openApp("settings") end,
            rows = function()
                local st = current()
                if not st then return {} end
                local out = {}
                for __, r in ipairs(require("stview").settingsRows(st)) do
                    if r[2] ~= nil then table.insert(out, { r[1] }) end
                end
                return out
            end }
    end
    if PS.registerSearch then
        PS.registerSearch{ key = "syncthing", name = _("Syncthing"), icon = "folder-sync", search = function(q)
            local st = current()
            return st and st:search(q) or {}
        end }
    end
    -- A launcher quick button: tap turns Syncthing on or off, hold opens the app.
    if PS.registerQuick then
        PS.registerQuick{ key = "syncthing", name = _("Syncthing"),
            choices = function() return { { id = "toggle", name = _("Syncthing"), icon = "folder-sync" } } end,
            item = function()
                local st = current()
                if not (st and st:installed()) then return nil end
                local on = st:isRunning()
                local value
                if st:isStarting() then
                    value = _("Starting…")
                elseif on then
                    local snap = st:status(20)
                    for __, f in ipairs(snap and snap.folders or {}) do
                        if f.status and f.status.state == "syncing" then value = _("Syncing") break end
                    end
                end
                return { label = _("Syncthing"), icon = "folder-sync", on = on, value = value,
                    tap = function(done)
                        st:toggle()
                        done()
                    end,
                    hold = function() openApp() end }
            end }
    end
    if PS.registerSetup then
        PS.registerSetup{ key = "syncthing", order = 50, icon = "folder-sync", title = _("Syncthing"),
            text = _("Keep folders on the Kindle in sync with your computer or phone. Install Syncthing there, then add this Kindle with its ID (the Syncthing app shows it as a QR code) and accept it on the Kindle."),
            done = function()
                local st = current()
                local cfg = st and st:offline()
                return cfg ~= nil and #cfg.devices > 0
            end,
            doneText = _("Paired with a device"),
            skipped = _("Nothing else needs it: copy books using the web server feature. If you prefer a physical connection, exit KOReader and connect your Kindle via USB. Set up Syncthing any time from the app."),
            action = _("Show this Kindle's ID"),
            run = function()
                local st = current()
                if not st then return end
                st:show()
                if not st:isRunning() then NetworkMgr:runWhenConnected(function() st:start() end) end
                st:showIdWhenReady()
            end }
    end
    self.dir = DataStorage:getSettingsDir() .. "/syncthing"
    self.api = API.new(self.dir, self:port())
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    -- (Syncthing keeps running when KOReader restarts: its icon is back)
    if self:isRunning() then
        runningNote(true)
        if self:offWhenSynced() then self:armOff() end
    end
    if self:withWifi() and not state.stopped and not self:isRunning() and NetworkMgr:isConnected() then
        UIManager:nextTick(function() self:start(true) end)
    end
end

function Syncthing:onDispatcherRegisterActions()
    Dispatcher:registerAction("syncthing_show", { category = "none", event = "ShowSyncthing", title = _("Syncthing"), general = true })
    -- (the upstream plugin's action, so gestures set up for it keep working)
    Dispatcher:registerAction("toggle_syncthing_server", { category = "none", event = "ToggleSyncthingServer", title = _("Turn Syncthing on or off"), general = true })
end

function Syncthing:addToMainMenu(menu_items)
    menu_items.syncthing = {
        text = _("Syncthing"),
        sorting_hint = "network",
        callback = function() self:show() end,
    }
end

-- ------------------------------------------------------------------ settings

function Syncthing:port()
    return tostring(G_reader_settings:readSetting("syncthing_port") or "8384")
end

function Syncthing:setPort(port)
    G_reader_settings:saveSetting("syncthing_port", tostring(port))
    self.api = API.new(self.dir, self:port())
end

--- Whether the web GUI has a password: true or false, nil when not known (Syncthing is off).
function Syncthing:passwordSet()
    return state.snap and state.snap.passwordSet
end

--- Change the port (from the web page): only while Syncthing is off, from 1024 to 65535.
function Syncthing:changePort(v)
    if self:isRunning() then return false, _("Turn Syncthing off to change the port") end
    local port = M.validPort(v)
    if not port then return false, _("Pick a port from 1024 to 65535") end
    self:setPort(math.floor(port))
    return true
end

--- Start with Wi-Fi (the upstream plugin's "Start with KOReader" carries over).
function Syncthing:withWifi()
    local v = G_reader_settings:readSetting("syncthing_with_wifi")
    if v == nil then return G_reader_settings:isTrue("syncthing_autostart") end
    return v
end

function Syncthing:setWithWifi(on)
    G_reader_settings:saveSetting("syncthing_with_wifi", on)
end

--- Warn about stuck sync and conflicts in the shared notifications (on unless turned off).
function Syncthing:warnsOfProblems()
    return G_reader_settings:readSetting("syncthing_warn") ~= false
end

function Syncthing:setWarnsOfProblems(on)
    G_reader_settings:saveSetting("syncthing_warn", on and true or false)
    if not on then state.since = nil end
end

--- Turn off when up to date: Syncthing turns itself off once everything is in sync.
function Syncthing:offWhenSynced()
    return G_reader_settings:isTrue("syncthing_off_when_synced")
end

function Syncthing:setOffWhenSynced(on)
    G_reader_settings:saveSetting("syncthing_off_when_synced", on)
    if on then
        if self:isRunning() and not state.offBy then self:armOff() end
    else
        self:disarmOff()
    end
end

function Syncthing:installed()
    return lfs.attributes(self.path .. "/syncthing", "mode") == "file"
end

function Syncthing:deviceId()
    local f = io.open(self.dir .. "/device-id", "r")
    if not f then return state.snap and state.snap.myId or nil end
    local id = f:read("*l")
    f:close()
    return id ~= "" and id or nil
end

function Syncthing:ip() return localIp() end

function Syncthing:guiAddress()
    return T("http://%1:%2", localIp() or "?", self:port())
end

-- ------------------------------------------------------------------ running

local function readPid()
    local f = io.open(PID_FILE, "r")
    if not f then return nil end
    local pid = tonumber(f:read("*l") or "")
    f:close()
    return pid
end

local function alive(pid)
    return pid and lfs.attributes("/proc/" .. pid, "mode") == "directory"
end

--- On: Syncthing runs or is starting (while being stopped it counts as off).
function Syncthing:isRunning()
    local pid = readPid()
    if alive(pid) then return not state.stopping end
    if pid then os.remove(PID_FILE) end
    return state.starting ~= nil
end

function Syncthing:isStarting()
    return state.starting ~= nil
end

-- Kindles block incoming connections: holes for the GUI and sync ports while running.
local function firewall(port, open)
    if not Device:isKindle() then return end
    local flag = open and "-A" or "-D"
    os.execute(string.format("iptables %s INPUT -p tcp --dport %s -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", flag, port))
    os.execute(string.format("iptables %s OUTPUT -p tcp --sport %s -m conntrack --ctstate ESTABLISHED -j ACCEPT", flag, port))
    os.execute(string.format("iptables %s INPUT -i wlan0 -p tcp --dport %d -j ACCEPT", flag, SYNC_PORT))
    os.execute(string.format("iptables %s INPUT -i wlan0 -p udp --dport %d -j ACCEPT", flag, SYNC_PORT))
    os.execute(string.format("iptables %s INPUT -i wlan0 -p udp --dport %d -j ACCEPT", flag, DISCOVERY_PORT))
end


-- A finished child collected (so it does not linger).
local function reap(pid)
    if ffiutil.isSubProcessDone(pid) then return end
    UIManager:scheduleIn(0.5, function() reap(pid) end)
end

--- fn() run in a child process, so a slow answer from Syncthing never holds
-- up KOReader; done(result) or done(nil, error) back here.
local function job(fn, done, timeout)
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, result, err = pcall(fn)
        local out = { ok = ok and result ~= nil and result ~= false }
        if out.ok then out.result = result else out.err = tostring(ok and err or result) end
        ffiutil.writeToFD(write_fd, JSON.encode(out), true)
    end, true)
    if not pid then return done(nil, tostring(fd)) end
    local deadline = os.time() + (timeout or 20)
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = not (size and size > 0) and ffiutil.isSubProcessDone(pid)
        if (size and size > 0) or exited then
            local text = ffiutil.readAllFromFD(fd) or ""
            if not exited then reap(pid) end
            local ok, r = pcall(JSON.decode, text)
            if ok and type(r) == "table" and r.ok then return done(r.result == nil and true or r.result) end
            return done(nil, ok and type(r) == "table" and r.err or "no answer")
        end
        if os.time() > deadline then
            ffiutil.terminateSubProcess(pid)
            reap(pid)
            return done(nil, "no answer")
        end
        UIManager:scheduleIn(0.15, check)
    end
    UIManager:scheduleIn(0.05, check)
end

--- Start Syncthing (quiet: no messages, for Start with Wi-Fi). The script runs
-- in the background (the first start makes keys, which takes a while); the
-- app shows "Starting…" until Syncthing answers.
function Syncthing:start(quiet)
    state.stopped = false
    if self:isRunning() then return true end
    if state.stopping then
        UIManager:scheduleIn(1, function() self:start(quiet) end)
        return true
    end
    if not self:installed() then
        if not quiet then require("stko").toast(_("Syncthing isn't installed: the syncthing program is missing")) end
        return false
    end
    -- Kobos: the loopback interface, so KOReader can reach Syncthing's API.
    if Device:isKobo() then os.execute("ifconfig lo up") end
    firewall(self:port(), true)
    os.remove(PID_FILE)
    local cmd = string.format("sh %s %s %s %s", shellQuote(self.path .. "/start-syncthing"), shellQuote(self.dir),
        shellQuote(G_reader_settings:readSetting("home_dir") or "/"), shellQuote(self:port()))
    logger.dbg("Syncthing: starting", cmd)
    os.execute(cmd .. " > /dev/null 2>&1 &")
    state.snap, state.starting, state.cancel = nil, os.time(), nil
    runningNote(true)
    local PS = require("pluginshare")
    if PS.unnotify then pcall(PS.unnotify, "syncthing:turnedoff") end
    if self:offWhenSynced() and not state.offBy then self:armOff() end
    self:changed()
    self:waitUntilReady(quiet)
    return true
end

-- Ask until Syncthing answers (it takes a few seconds on a Kindle), then show its status.
function Syncthing:waitUntilReady(quiet, tries)
    tries = tries or 0
    UIManager:scheduleIn(tries == 0 and 1 or 2, function()
        local up = alive(readPid())
        if state.cancel then
            -- Turned off while starting: stopped once it is there.
            if up then
                state.cancel = nil
                self:stop(true)
            elseif tries < 30 then
                self:waitUntilReady(quiet, tries + 1)
            else
                state.cancel = nil
            end
            return
        end
        if not state.starting then return end
        local function again()
            if tries < 30 then return self:waitUntilReady(quiet, tries + 1) end
            state.starting = nil
            if not alive(readPid()) then
                runningNote(false)
                firewall(self:port(), false)
                if not quiet then require("stko").toast(_("Couldn't start Syncthing")) end
            end
            self:changed()
        end
        if not up then return again() end
        self:fetch(function(snap)
            if snap then
                state.starting = nil
                self:changed()
            else
                again()
            end
        end, true)
    end)
end

--- Stop Syncthing (quiet: no messages; byHand: Start with Wi-Fi waits for the
-- next connection). Asks it to quit, and makes sure a little later.
--- Stop Syncthing and wait until it has quit (at most about 5 s): only for a
-- restore, which must not write its files while Syncthing has them open.
function Syncthing:stopNow()
    state.starting, state.cancel = nil, nil
    local pid = readPid()
    if not alive(pid) then return end
    state.stopping, state.snap = pid, nil
    runningNote(false)
    local function signal(sig)
        os.execute(string.format("pkill -%s -P %d; kill -%s %d", sig, pid, sig, pid))
    end
    signal("TERM")
    for i = 1, 50 do
        if not alive(pid) then break end
        if i == 30 then signal("KILL") end
        ffiutil.sleep(0.1)
    end
    firewall(self:port(), false)
    if not alive(pid) then os.remove(PID_FILE) end
    state.stopping = nil
end

function Syncthing:stop(quiet, byHand)
    if byHand then state.stopped = true end
    if state.starting then
        state.cancel, state.starting = true, nil
        runningNote(false)
        firewall(self:port(), false)
        self:changed()
        return true
    end
    local pid = readPid()
    if not alive(pid) then
        os.remove(PID_FILE)
        runningNote(false)
        return true
    end
    local function signal(sig)
        os.execute(string.format("pkill -%s -P %d; kill -%s %d", sig, pid, sig, pid))
    end
    state.stopping, state.snap = pid, nil
    runningNote(false)
    signal("TERM")
    firewall(self:port(), false)
    self:changed()
    local tries = 0
    local function check()
        tries = tries + 1
        if not alive(pid) then
            os.remove(PID_FILE)
            state.stopping = nil
            return self:changed()
        end
        if tries == 30 then signal("KILL") end
        if tries > 60 then
            state.stopping = nil
            if not quiet then require("stko").toast(_("Syncthing is still shutting down…")) end
            return self:changed()
        end
        UIManager:scheduleIn(0.1, check)
    end
    UIManager:scheduleIn(0.1, check)
    return true
end

--- On or off (from the app, the web page, a gesture).
function Syncthing:toggle()
    if self:isRunning() then
        self:stop(false, true)
    else
        NetworkMgr:runWhenConnected(function() self:start() end)
    end
end

function Syncthing:onToggleSyncthingServer()
    self:toggle()
    return true
end

-- Start with Wi-Fi: on when Wi-Fi connects, off before it goes.
function Syncthing:onNetworkConnected()
    state.stopped = false
    if self:withWifi() and not self:isRunning() then self:start(true) end
end

function Syncthing:onNetworkDisconnecting()
    if self:withWifi() and self:isRunning() then self:stop(true) end
end

-- ------------------------------------------------------------------ status

-- Conflicting copies are looked for at most every 10 minutes. Syncthing keeps a change
-- that clashed with another device's as "<name>.sync-conflict-<date>-<id>.<ext>" beside it.
local CONFLICT_EVERY = 600

--- { [folder id] = number of conflicting copies (up to 50) } for the folders that are
-- on. Runs in the status read's background process, never on the screen's loop.
local function countConflicts(snap)
    local out = {}
    for __, f in ipairs(snap.folders or {}) do
        local path = f.folder.path
        if not f.folder.paused and type(path) == "string" and path:sub(1, 1) == "/" then
            local p = io.popen(string.format("find %s -name '*.sync-conflict-*' ! -path '*/.stversions/*' 2>/dev/null | head -50",
                shellQuote(path)))
            if p then
                local n = 0
                for __ in p:lines() do n = n + 1 end
                p:close()
                out[f.folder.id] = n
            end
        end
    end
    return out
end

--- Read Syncthing's status (API:snapshot) in the background; done(snap) when
-- it is in (nil if Syncthing didn't answer). One read at a time. quiet: don't
-- redraw (waitUntilReady does that itself).
function Syncthing:fetch(done, quiet)
    if done then table.insert(state.waiting, done) end
    if state.fetching then return end
    local function finish(snap)
        local waiting = state.waiting
        state.waiting = {}
        for __, f in ipairs(waiting) do f(snap) end
    end
    if not alive(readPid()) or state.stopping then return finish(nil) end
    state.fetching = true
    local api = self.api
    local lookForConflicts = self:warnsOfProblems() and os.time() - (state.conflictTime or 0) >= CONFLICT_EVERY
    job(function()
        local snap, err = api:snapshot()
        if snap then
            if lookForConflicts then snap.conflicts = countConflicts(snap) end
            snap.config = nil
        end
        return snap, err
    end, function(snap)
        state.fetching = false
        if type(snap) == "table" and self:isRunning() then
            if lookForConflicts then state.conflictTime = os.time() end
            state.snap, state.snapTime = snap, os.time()
            self:notifyChanges(snap)
            self:checkOff(snap)
        else
            snap = nil
        end
        if not quiet then self:changed() end
        finish(snap)
    end)
end

--- New requests and folders with errors to the shared notifications (the
-- Apps plugin's bell); taken away again once accepted, ignored or fixed.
function Syncthing:notifyChanges(snap)
    local PS = require("pluginshare")
    if not PS.notify then return end
    local before = G_reader_settings:readSetting("syncthing_notified") or {}
    local now = {}
    local function note(key, text)
        now[key] = true
        if before[key] then return end
        pcall(PS.notify, { app = "syncthing", name = _("Syncthing"), icon = "folder-sync", key = key, text = text,
            open = openApp, route = {} })
    end
    for __, p in ipairs(snap.pendingDevices or {}) do
        note("syncthing:req:dev:" .. p.id, T(_("%1 wants to connect"), p.name or M.shortId(p.id)))
    end
    for __, p in ipairs(snap.pendingFolders or {}) do
        note("syncthing:req:folder:" .. p.id .. ":" .. p.from, T(_("%1 shares “%2”"), p.fromName, p.label))
    end
    for __, f in ipairs(snap.folders or {}) do
        local st = f.status
        if st and not f.folder.paused and (st.state == "error" or (tonumber(st.pullErrors) or 0) > 0) then
            note("syncthing:err:" .. f.folder.id, T(_("Errors in %1"), f.folder.label))
        end
    end
    -- Stuck folders and folders with conflicting copies (Warn about stuck sync and conflicts).
    if self:warnsOfProblems() then
        state.since = state.since or {}
        for __, p in ipairs(M.problems(snap, state.since, os.time())) do note(p.key, p.text) end
        -- (Not looked for conflicts this time: the ones told about stay until the next look.)
        if not snap.conflicts then
            for key in pairs(before) do
                if key:find("^syncthing:conflicts:") then now[key] = true end
            end
        end
    end
    local changed = false
    for key in pairs(before) do
        if not now[key] then
            changed = true
            if PS.unnotify then pcall(PS.unnotify, key) end
        end
    end
    for key in pairs(now) do
        if not before[key] then changed = true end
    end
    if changed then G_reader_settings:saveSetting("syncthing_notified", now) end
end

-- ------------------------------------------------------------------ turn off when up to date

local OFF_BY = 30 * 60   -- turn off after this many seconds even if not up to date
local OFF_CHECK = 30     -- seconds between checks while waiting

--- Wait for everything to be up to date, then turn Syncthing off (or give up at the
-- deadline). The only timer is one check every 30 s while this waits.
function Syncthing:armOff()
    state.offBy = os.time() + OFF_BY
    self:offTimer()
    self:changed()
end

function Syncthing:disarmOff()
    state.offBy = nil
    if state.offTask then UIManager:unschedule(state.offTask) end
    self:changed()
end

--- The waiting is on.
function Syncthing:turnsOff() return state.offBy ~= nil end

function Syncthing:offTimer()
    if state.offTask then UIManager:unschedule(state.offTask) end
    state.offTask = state.offTask or function()
        if not state.offBy then return end
        if not self:isRunning() then state.offBy = nil return end
        -- (the status read checks it when it is in; this asks for one)
        if not state.starting then self:fetch() end
        if state.offBy and os.time() >= state.offBy then return self:finishOff(false) end
        UIManager:scheduleIn(OFF_CHECK, state.offTask)
    end
    UIManager:scheduleIn(OFF_CHECK, state.offTask)
end

--- After a status read: up to date, then off.
function Syncthing:checkOff(snap)
    if not state.offBy or state.starting then return end
    if M.allInSync(snap) then
        self:finishOff(true)
    elseif os.time() >= state.offBy then
        self:finishOff(false)
    end
end

function Syncthing:finishOff(synced)
    if not state.offBy then return end
    state.offBy = nil
    if state.offTask then UIManager:unschedule(state.offTask) end
    self:stop(true, true)
    local PS = require("pluginshare")
    if PS.notify then
        pcall(PS.notify, { app = "syncthing", name = _("Syncthing"), icon = "folder-sync", key = "syncthing:turnedoff",
            text = synced and _("Syncthing turned off: everything is up to date")
                or _("Syncthing turned off: still not up to date after 30 minutes"),
            open = openApp, route = {} })
    end
end

--- Sync now, then turn off: on if it is off, off once up to date.
function Syncthing:syncThenOff()
    if not self:installed() then
        require("stko").toast(_("Syncthing isn't installed: the syncthing program is missing"))
        return false
    end
    self:armOff()
    if not self:isRunning() then NetworkMgr:runWhenConnected(function() self:start() end) end
    return true
end

--- The last status read (nil while off or not read yet); read again in the
-- background when older than maxAge seconds.
function Syncthing:status(maxAge)
    if not self:isRunning() then
        state.snap = nil
        return nil
    end
    if not state.starting and (not state.snap or os.time() - state.snapTime >= (maxAge or 10)) then self:fetch() end
    return state.snap
end

function Syncthing:statusTime() return state.snapTime end

--- Read the status again now; what shows it is redrawn when it is in.
function Syncthing:refresh()
    if self:isRunning() and not state.starting then self:fetch() end
end

--- Redraw the app (only if something shown changed), or the launcher when its
-- line changed.
function Syncthing:changed()
    if state.view then return state.view:refresh(true) end
    local line = self:appsLine()
    if line == state.line then return end
    state.line = line
    local apps = self.ui and self.ui.apps
    if apps and apps.changed then pcall(apps.changed, apps) end
end

--- What config.xml says (folders and devices) while Syncthing is off.
function Syncthing:offline()
    return self.api:config(self:deviceId())
end

--- The launcher tile's line: "On · Up to date", "On · Syncing · 3 files left", "Off".
function Syncthing:appsLine()
    if not self:isRunning() then return M.appsLine(false) end
    if self:isStarting() then return T(_("On · %1"), _("Starting…")) end
    local snap = self:status(20)
    return snap and M.appsLine(true, snap) or _("On")
end

-- ------------------------------------------------------------------ actions

--- An action from the app or the web page, done in the background; then
-- done(ok, error) and the status read again. Returns false and an error at
-- once when it can't be done.
-- name: rescan (folder or all), pauseFolder, pauseDevice, acceptDevice,
-- ignoreDevice, unignoreDevice, acceptFolder, ignoreFolder, unignoreFolder, password.
function Syncthing:act(name, a, done)
    a = a or {}
    if not self:isRunning() or state.starting then return false, _("Syncthing is off.") end
    local api, myId = self.api, self:deviceId()
    local calls = {
        rescan = function() return api:rescan(a.folder) end,
        pauseFolder = function() return api:pauseFolder(a.folder, a.paused) end,
        pauseDevice = function() return api:pauseDevice(a.device, a.paused) end,
        acceptDevice = function() return api:acceptDevice(a.device, a.name) end,
        ignoreDevice = function() return api:ignoreDevice(a.device, a.name, a.address) end,
        acceptFolder = function() return api:acceptFolder(a.folder, a.label, a.path, a.from, myId) end,
        ignoreFolder = function() return api:ignoreFolder(a.folder, a.label, a.from) end,
        unignoreDevice = function() return api:unignoreDevice(a.device) end,
        unignoreFolder = function() return api:unignoreFolder(a.folder, a.from) end,
        password = function() return api:setPassword(a.password) end,
    }
    if not calls[name] then return false, "unknown action" end
    if name == "acceptFolder" and (type(a.path) ~= "string" or not a.path:match("^/")) then
        return false, _("The folder must be a full path, such as /mnt/us/documents/Books.")
    end
    job(calls[name], function(ok, err)
        if not ok then logger.warn("Syncthing:", name, err) end
        -- (after a change, Syncthing takes a moment to show it)
        UIManager:scheduleIn(1, function() self:refresh() end)
        if done then done(ok ~= nil, err) end
    end)
    return true
end

--- Folders (by name or path) and devices (by name) with q in them (lower case), for
-- the launcher's search; a result opens that folder's or device's menu.
function Syncthing:search(q)
    local out = {}
    local running = self:isRunning() and state.snap ~= nil
    local folders, devices = {}, {}
    -- (from memory: the last status read, or config.xml as last read)
    if state.snap then
        folders, devices = state.snap.folders or {}, state.snap.devices or {}
    else
        local cfg = self.api.cfg
        for __, f in ipairs(cfg and cfg.folders or {}) do table.insert(folders, { folder = f }) end
        for __, d in ipairs(cfg and cfg.devices or {}) do table.insert(devices, { device = d, name = d.name }) end
    end
    -- (the app first, then its menu on top of it)
    local function openMenu(menu, entry)
        return function()
            openApp()
            UIManager:nextTick(function()
                if state.view then state.view[menu](state.view, entry, running) end
            end)
        end
    end
    for __, f in ipairs(folders) do
        local label, path = tostring(f.folder.label or ""), tostring(f.folder.path or "")
        if label:lower():find(q, 1, true) or path:lower():find(q, 1, true) then
            table.insert(out, { title = label, sub = path, open = openMenu("folderMenu", f) })
            if #out >= 20 then return out end
        end
    end
    for __, d in ipairs(devices) do
        local name = tostring(d.name or "")
        if name:lower():find(q, 1, true) then
            table.insert(out, { title = name, sub = _("Device"), open = openMenu("deviceMenu", d) })
            if #out >= 20 then break end
        end
    end
    return out
end

--- Where a folder offered by a device would go on the Kindle.
function Syncthing:folderPath(label)
    return M.folderPath(G_reader_settings:readSetting("home_dir") or "/mnt/us/documents", label)
end

-- ------------------------------------------------------------------ the app

--- The app (page "settings": its settings, back from them closes the app, for
-- the launcher's Settings list). An app already open is brought back on top.
function Syncthing:show(page)
    -- App lock (the launcher's): its passcode first, when this app is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask("syncthing", function() self:show(page) end) then return end
    local PS = require("pluginshare")
    if PS.noteRecent then pcall(PS.noteRecent, "syncthing") end
    if state.view then UIManager:close(state.view) end
    local View = require("stview")
    state.view = View:new{ st = self }
    self.view = state.view
    UIManager:show(state.view)
    if page == "settings" then
        state.view.settingsOnly = true
        state.view:settings()
    end
    self:refresh()
end

--- This Kindle's ID as a QR code once Syncthing has made it (the first start
-- makes it), for Set up your Kindle.
function Syncthing:showIdWhenReady(tries)
    tries = tries or 0
    if self:deviceId() then
        if state.view then state.view:showId() end
        return
    end
    if tries < 30 then UIManager:scheduleIn(1, function() self:showIdWhenReady(tries + 1) end) end
end

function Syncthing:onShowSyncthing()
    self:show()
    return true
end

function Syncthing:closeView()
    if state.view then
        UIManager:close(state.view)
        state.view = nil
    end
    self.view = nil
end

-- ------------------------------------------------------------------ the web page

--- Everything the web page's Syncthing tab shows.
function Syncthing:webState()
    local running = self:isRunning()
    local out = { program = self:installed(), running = running, starting = self:isStarting(),
        id = self:deviceId(), withWifi = self:withWifi(), offWhenSynced = self:offWhenSynced(), warn = self:warnsOfProblems(), turnsOff = self:turnsOff(),
        port = self:port(), passwordSet = self:passwordSet(), gui = running and self:guiAddress() or nil,
        folders = {}, devices = {}, pendingDevices = {}, pendingFolders = {} }
    local snap = running and not self:isStarting() and self:status(3)
    M.twentyFour = not G_reader_settings:isTrue("twelve_hour_clock")
    local now = os.time()
    if snap then
        out.summary = M.summary(snap)
        for __, f in ipairs(snap.folders) do
            local st = f.status or {}
            local label = M.folderState(f.folder, f.status)
            local last = f.stats and f.stats.lastFile
            table.insert(out.folders, { id = f.folder.id, label = f.folder.label, path = f.folder.path, paused = f.folder.paused,
                state = label, busy = st.state == "syncing", progress = st.state == "syncing" and M.progress(st) or nil,
                need = M.need(st), files = st.localFiles, bytes = st.localBytes and M.bytes(st.localBytes) or nil,
                lastFile = last and last.filename ~= "" and last.filename or nil,
                lastAt = last and M.ago(M.parseTime(last.at), now) or nil, shared = f.shared })
        end
        for __, d in ipairs(snap.devices) do
            table.insert(out.devices, { id = d.device.deviceID, name = d.name, paused = d.device.paused,
                connected = d.conn and d.conn.connected or false,
                state = M.deviceState(d.device, d.conn, d.completion, d.lastSeen, now) })
        end
        for __, p in ipairs(snap.pendingDevices) do
            table.insert(out.pendingDevices, { id = p.id, name = p.name, address = p.address })
        end
        for __, p in ipairs(snap.pendingFolders) do
            table.insert(out.pendingFolders, { id = p.id, label = p.label, from = p.from, fromName = p.fromName,
                path = self:folderPath(p.label) })
        end
    else
        local cfg = self:offline()
        out.summary = running and (self:isStarting() and _("Starting…") or _("Reading the status…")) or nil
        for __, f in ipairs(cfg and cfg.folders or {}) do
            table.insert(out.folders, { id = f.id, label = f.label, path = f.path, paused = f.paused })
        end
        for __, d in ipairs(cfg and cfg.devices or {}) do
            table.insert(out.devices, { id = d.deviceID, name = d.name, paused = d.paused })
        end
    end
    return out
end

return Syncthing
