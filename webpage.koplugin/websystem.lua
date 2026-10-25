--[[--
The Kindle itself, from the web page: its light, warmth, night mode, a
refresh, Wi-Fi off, sleep and restarting KOReader; taps, holds and swipes on
its screen (the remote, over the picture of the screen); its logs; each
plugin's version; automatic backups kept on the Kindle; and the gestures
(to look at only: KOReader keeps them, so they are changed on the Kindle).
]]

local Common = require("webcommon")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local Web = {}

-- ------------------------------------------------------------------ controls

--- The light, warmth, night mode and Wi-Fi now.
function Web.state()
    local powerd = Device:getPowerDevice()
    local out = { night = G_reader_settings:isTrue("night_mode") }
    if Device:hasFrontlight() and powerd then
        out.light = { on = powerd:isFrontlightOn(), value = powerd:frontlightIntensity(), min = powerd.fl_min, max = powerd.fl_max }
    end
    if Device.hasNaturalLight and Device:hasNaturalLight() and powerd then
        out.warmth = { value = powerd:frontlightWarmth(), min = 0, max = 100 }
    end
    local ok, on = pcall(function() return require("ui/network/manager"):isWifiOn() end)
    out.wifi = ok and on or false
    return out
end

--- One control: "light" (value, or on = true|false), "warmth" (value),
-- "night", "refresh", "wifi_off", "sleep" or "restart". Returns nil or why not.
function Web.control(plugin, b)
    local powerd = Device:getPowerDevice()
    local action = b.action
    if action == "light" then
        if not (Device:hasFrontlight() and powerd) then return "No front light" end
        if b.on == false then powerd:turnOffFrontlight()
        elseif b.on == true then powerd:turnOnFrontlight()
        elseif tonumber(b.value) then powerd:setIntensity(math.floor(tonumber(b.value))) end
    elseif action == "warmth" then
        if not (Device.hasNaturalLight and Device:hasNaturalLight() and powerd) then return "No warmth" end
        if not tonumber(b.value) then return "No value" end
        powerd:setWarmth(math.floor(tonumber(b.value)))
    elseif action == "night" then
        local ui = Common.ui()
        if not ui then return "KOReader isn't ready" end
        ui:handleEvent(Event:new("ToggleNightMode"))
        UIManager:setDirty("all", "full")
    elseif action == "refresh" then
        UIManager:setDirty("all", "full")
    elseif action == "wifi_off" then
        -- After the answer has gone: this page goes with it.
        UIManager:scheduleIn(1, function()
            if plugin and plugin.stop then plugin:stop() end
            require("ui/network/manager"):toggleWifiOff(nil, true)
        end)
    elseif action == "sleep" then
        UIManager:scheduleIn(1, function() UIManager:suspend() end)
    elseif action == "restart" then
        UIManager:scheduleIn(1, function()
            if plugin and plugin.stop then plugin:stop() end
            if Device.canRestart == nil or Device:canRestart() then UIManager:restartKOReader() end
        end)
    else
        return "Unknown action"
    end
end

-- ------------------------------------------------------------------ remote

--- A tap, hold or swipe on the Kindle's screen, as a finger would: x and y
-- from 0 to 1 across the picture of the screen (as it is turned now).
function Web.gesture(b)
    local Screen = Device.screen
    local w, h = Screen:getWidth(), Screen:getHeight()
    local x = math.floor(math.max(0, math.min(1, tonumber(b.x) or 0.5)) * (w - 1))
    local y = math.floor(math.max(0, math.min(1, tonumber(b.y) or 0.5)) * (h - 1))
    local now = require("ui/time").now()
    local pos = Geom:new{ x = x, y = y, w = 0, h = 0 }
    if b.kind == "tap" then
        UIManager:sendEvent(Event:new("Gesture", { ges = "tap", pos = pos, time = now }))
    elseif b.kind == "hold" then
        UIManager:sendEvent(Event:new("Gesture", { ges = "hold", pos = pos, time = now }))
        UIManager:scheduleIn(0.3, function()
            UIManager:sendEvent(Event:new("Gesture", { ges = "hold_release", pos = pos, time = require("ui/time").now() }))
        end)
    elseif b.kind == "swipe" then
        local dirs = { west = true, east = true, north = true, south = true }
        if not dirs[b.direction] then return "Which way?" end
        -- From the middle of the screen, a third of it long.
        local mid = Geom:new{ x = math.floor(w / 2), y = math.floor(h / 2), w = 0, h = 0 }
        local distance = math.floor(((b.direction == "west" or b.direction == "east") and w or h) / 3)
        UIManager:sendEvent(Event:new("Gesture", { ges = "swipe", direction = b.direction, distance = distance, pos = mid, time = now }))
    else
        return "Unknown gesture"
    end
end

-- ------------------------------------------------------------------ logs

-- The logs worth reading: KOReader's crash log and the sleep screen updates'.
local function logs()
    local dir = DataStorage:getDataDir()
    local out = {}
    for __, l in ipairs({ { "crash.log", "KOReader's log (crash.log)" }, { "sleep-update.log", "Sleep screen updates" } }) do
        local a = lfs.attributes(dir .. "/" .. l[1])
        if a and a.mode == "file" then table.insert(out, { name = l[1], title = l[2], size = a.size, mtime = a.modification }) end
    end
    return out, dir
end

--- The last `n` lines of a log.
local function tail(path, n)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    local from = math.max(0, size - 256 * 1024)
    f:seek("set", from)
    local text = f:read("*a") or ""
    f:close()
    local lines = {}
    for line in text:gmatch("[^\n]*\n?") do if line ~= "" then table.insert(lines, line) end end
    if from > 0 then table.remove(lines, 1) end   -- a line cut in two
    local first = math.max(1, #lines - n + 1)
    return table.concat(lines, "", first), #lines - first + 1
end

-- ------------------------------------------------------------------ versions

--- Each plugin's version: { name, title, version (the line from version.txt),
-- changes = { "abc1234 2026-10-22 What changed" … }, updated }.
function Web.versions()
    -- The folder this plugin is in (koreader/plugins).
    local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."
    local dir = here:match("^(.*)/[^/]+%.koplugin$") or (DataStorage:getDataDir() .. "/plugins")
    local out = {}
    for name in lfs.dir(dir) do
        if name:match("%.koplugin$") and lfs.attributes(dir .. "/" .. name, "mode") == "directory" then
            local e = { name = name }
            local meta = loadfile(dir .. "/" .. name .. "/_meta.lua")
            if meta then
                local ok, m = pcall(meta)
                if ok and type(m) == "table" then e.title = type(m.fullname) == "string" and m.fullname or nil end
            end
            local f = io.open(dir .. "/" .. name .. "/version.txt", "r")
            if f then
                local lines = {}
                for line in f:lines() do table.insert(lines, line) end
                f:close()
                e.version = lines[1]
                e.changes = {}
                for i = 2, #lines do if lines[i] ~= "" then table.insert(e.changes, lines[i]) end end
            end
            e.updated = lfs.attributes(dir .. "/" .. name .. "/main.lua", "modification")
            table.insert(out, e)
        end
    end
    -- Ours (with version.txt) first, then KOReader's own, by name.
    table.sort(out, function(a, b)
        if (a.version ~= nil) ~= (b.version ~= nil) then return a.version ~= nil end
        return a.name < b.name
    end)
    return out
end

-- ------------------------------------------------------------------ automatic backups

-- Kept on the Kindle in koreader/backups: kindle-backup-YYYY-MM-DD.zip, the
-- settings and notebooks without sign-ins, the newest `keep` of them.
local function backupDir() return DataStorage:getDataDir() .. "/backups" end

local function autoSettings()
    local s = G_reader_settings:readSetting("webpage_autobackup") or {}
    return { on = s.on == true, keep = tonumber(s.keep) or 4, last = tonumber(s.last) }
end

function Web.backups()
    local out = {}
    local dir = backupDir()
    if lfs.attributes(dir, "mode") == "directory" then
        for name in lfs.dir(dir) do
            if name:match("^kindle%-backup%-.+%.zip$") then
                local a = lfs.attributes(dir .. "/" .. name)
                table.insert(out, { name = name, size = a.size, mtime = a.modification })
            end
        end
    end
    table.sort(out, function(a, b) return a.mtime > b.mtime end)
    return out
end

--- Makes a backup now (and keeps only the newest ones). Returns its name, or nil, why.
function Web.backupNow()
    local dir = backupDir()
    require("util").makePath(dir)
    local name = "kindle-backup-" .. os.date("%Y-%m-%d") .. ".zip"
    local path = dir .. "/" .. name
    os.remove(path)
    local n, why = require("webbackup").make(path, false)
    if not n then return nil, why end
    local s = G_reader_settings:readSetting("webpage_autobackup") or {}
    s.last = os.time()
    G_reader_settings:saveSetting("webpage_autobackup", s)
    local keep = autoSettings().keep
    for i, b in ipairs(Web.backups()) do
        if i > keep then os.remove(dir .. "/" .. b.name) end
    end
    return name
end

--- The weekly backup, made in a child process (reading every notebook can
-- take a while; the reader keeps answering meanwhile), then kept like
-- Back up now's.
function Web.backupInBackground()
    if Web.backingUp then return end
    local ffiutil = require("ffi/util")
    local dir = backupDir()
    require("util").makePath(dir)
    local name = "kindle-backup-" .. os.date("%Y-%m-%d") .. ".zip"
    local tmp = dir .. "/." .. name .. ".part"
    os.remove(tmp)
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, n, why = pcall(require("webbackup").make, tmp, false)
        ffiutil.writeToFD(write_fd, (ok and n) and "ok" or tostring(ok and why or n), true)
    end, true)
    if not pid then return end
    Web.backingUp = true
    local deadline = os.time() + 30 * 60
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(2, check) end
            ffiutil.terminateSubProcess(pid)
        end
        local out = (size and size > 0) and ffiutil.readAllFromFD(fd) or "stopped"
        Web.backingUp = nil
        if out == "ok" then
            os.remove(dir .. "/" .. name)
            os.rename(tmp, dir .. "/" .. name)
            local s = G_reader_settings:readSetting("webpage_autobackup") or {}
            s.last = os.time()
            G_reader_settings:saveSetting("webpage_autobackup", s)
            local keep = autoSettings().keep
            for i, b in ipairs(Web.backups()) do
                if i > keep then os.remove(dir .. "/" .. b.name) end
            end
        else
            os.remove(tmp)
            require("logger").warn("Web server: automatic backup failed:", out)
        end
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
        end
    end
    UIManager:scheduleIn(2, check)
end

--- Once per KOReader start: a weekly backup when it is on (checked now and
-- then while KOReader runs, whether or not the web server is). One that
-- failed is tried again a day later, not at every check.
function Web.scheduleBackups()
    if Web.backupTask then return end
    Web.backupTask = function()
        UIManager:scheduleIn(6 * 3600, Web.backupTask)
        local s = autoSettings()
        if s.on and (not s.last or os.time() - s.last >= 7 * 86400) and os.time() - (Web.backupTried or 0) >= 86400 then
            Web.backupTried = os.time()
            Web.backupInBackground()
        end
    end
    UIManager:scheduleIn(120, Web.backupTask)
end

-- ------------------------------------------------------------------ gestures

--- What each gesture does, in the library and in a book (KOReader's names),
-- as the Apps launcher's Gestures screen shows it: { fm = sections, reader = sections }.
function Web.gestures()
    local ui = Common.ui()
    local g = ui and ui.gestures
    if not g then return nil end
    local ok, G = pcall(require, "appsgestures")
    if not (ok and G and G.sections) then return nil end
    local out = {}
    for __, mode in ipairs({ "gesture_fm", "gesture_reader" }) do
        local okS, sections = pcall(G.sections, g, mode)
        out[mode == "gesture_fm" and "fm" or "reader"] = okS and sections or {}
    end
    out.current = g.ges_mode == "gesture_reader" and "reader" or "fm"
    return out
end

-- ------------------------------------------------------------------ battery

-- One of KOReader's Usage records as { percent, seconds, perHour }.
local function usage(u)
    if type(u) ~= "table" then return nil end
    local ok, secs = pcall(function() return require("ui/time").to_s(u.time or 0) end)
    secs = ok and secs or 0
    return { percent = u.percentage or 0, seconds = secs, perHour = secs >= 300 and (u.percentage or 0) / secs * 3600 or nil }
end

--- The battery, from KOReader's Battery statistics plugin: { pct, charging,
-- available, awake, asleep, discharging, charged, on = { what uses power now } }.
function Web.battery()
    local powerd = Device:getPowerDevice()
    local okp, pct = pcall(function() return powerd:getCapacity() end)
    local okc, charging = pcall(function() return powerd:isCharging() end)
    local out = { pct = okp and tonumber(pct) or nil, charging = okc and charging == true, on = {} }
    local w = Common.plugin("batterystat")
    local ok, s = pcall(function() return w and w.stat and w:stat() end)
    if ok and s then
        pcall(s.accumulate, s)
        out.available = true
        out.awake, out.asleep, out.discharging, out.charged = usage(s.awake), usage(s.sleeping), usage(s.discharging), usage(s.charging)
    end
    local NetworkMgr = require("ui/network/manager")
    local PluginShare = require("pluginshare")
    local okw, wifi = pcall(function() return NetworkMgr:isWifiOn() end)
    if okw and wifi then table.insert(out.on, "Wi-Fi is on") end
    if Device:hasFrontlight() then
        local okl, light = pcall(function() return powerd:isFrontlightOn() and powerd:frontlightIntensity() end)
        if okl and light then table.insert(out.on, "Front light at " .. light) end
    end
    table.insert(out.on, "Web server running")
    local st = Common.plugin("syncthing")
    local okr, running = pcall(function() return st and st.isRunning and st:isRunning() end)
    if okr and running then table.insert(out.on, "Syncthing running") end
    local reasons = PluginShare.awake_reasons or {}
    if reasons.homeassistant then table.insert(out.on, "Home Assistant dashboard keeping the screen on") end
    if next(reasons) or PluginShare.pause_auto_suspend then table.insert(out.on, "Kept awake (it won't sleep by itself)") end
    return out
end

--- Clears KOReader's battery statistics. Returns nil or why not.
function Web.batteryReset()
    local w = Common.plugin("batterystat")
    local ok, s = pcall(function() return w and w.stat and w:stat() end)
    if not (ok and s) then return "KOReader's Battery statistics plugin is off" end
    pcall(s.resetAll, s)
    pcall(s.onFlushSettings, s)
end

function Web.routes(server, plugin)
    server:route("GET", "^/api/kindle$", function(req, res) res:json(Web.state()) end)

    server:route("GET", "^/api/battery$", function(req, res) res:json(Web.battery()) end)

    server:route("POST", "^/api/battery/reset$", function(req, res)
        local why = Web.batteryReset()
        if why then return res:error(400, why) end
        res:json({ ok = true })
    end)

    server:route("GET", "^/api/logs$", function(req, res) res:json({ logs = (logs()) }) end)

    -- ?name=crash.log&lines=400 (the end of it), &download=1 for the whole file.
    server:route("GET", "^/api/logs/view$", function(req, res)
        local list, dir = logs()
        local name
        for __, l in ipairs(list) do if l.name == req.query.name then name = l.name end end
        if not name then return res:error(404, "No such log") end
        if req.query.download == "1" then return res:file(dir .. "/" .. name, name) end
        local text, n = tail(dir .. "/" .. name, math.min(5000, tonumber(req.query.lines) or 400))
        res:json({ name = name, text = text or "", lines = n or 0 })
    end)

    server:route("GET", "^/api/versions$", function(req, res) res:json({ plugins = Web.versions() }) end)

    server:route("GET", "^/api/autobackup$", function(req, res)
        local s = autoSettings()
        res:json({ on = s.on, keep = s.keep, last = s.last, backups = Web.backups() })
    end)

    -- { on, keep }
    server:route("POST", "^/api/autobackup$", function(req, res)
        local b = req.json()
        local s = G_reader_settings:readSetting("webpage_autobackup") or {}
        if type(b.on) == "boolean" then s.on = b.on end
        if tonumber(b.keep) then s.keep = math.max(1, math.min(20, math.floor(tonumber(b.keep)))) end
        G_reader_settings:saveSetting("webpage_autobackup", s)
        G_reader_settings:flush()
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/autobackup/now$", function(req, res)
        local name, why = Web.backupNow()
        if not name then return res:error(500, tostring(why)) end
        res:json({ ok = true, name = name })
    end)

    -- ?name= : download one; POST { name } with delete = true removes it.
    server:route("GET", "^/api/autobackup/file$", function(req, res)
        local name = req.query.name or ""
        if not name:match("^kindle%-backup%-[%w%-]+%.zip$") then return res:error(400, "No such backup") end
        local path = backupDir() .. "/" .. name
        if lfs.attributes(path, "mode") ~= "file" then return res:error(404, "No such backup") end
        res:file(path, name)
    end)

    server:route("POST", "^/api/autobackup/delete$", function(req, res)
        local name = req.json().name or ""
        if not name:match("^kindle%-backup%-[%w%-]+%.zip$") then return res:error(400, "No such backup") end
        os.remove(backupDir() .. "/" .. name)
        res:json({ ok = true })
    end)

    server:route("GET", "^/api/gestures$", function(req, res)
        local g = Web.gestures()
        if not g then return res:json({ available = false }) end
        g.available = true
        res:json(g)
    end)

    server:route("POST", "^/api/kindle/control$", function(req, res)
        local why = Web.control(plugin, req.json())
        if why then return res:error(400, why) end
        res:json(Web.state())
    end)

    server:route("POST", "^/api/kindle/gesture$", function(req, res)
        local why = Web.gesture(req.json())
        if why then return res:error(400, why) end
        res:json({ ok = true })
    end)
end

return Web
