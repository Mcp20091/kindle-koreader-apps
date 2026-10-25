--[[--
Diagnostics: KOReader's crashes and freezes read from crash.log (and when it
was stopped without closing), a file of diagnostics to send (no passwords or
sign-ins), a network check (in a child process), the sleep and wake history
(noted by this plugin), memory and uptime, and detailed logging that turns
itself off after a day.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local Common = require("webcommon")

local Diag = {}

-- ------------------------------------------------------------------ problems

local function crashLog() return (lfs.currentdir() or ".") .. "/crash.log" end

-- The end of a file (at most `bytes`), or "".
local function tail(path, bytes)
    local f = io.open(path, "rb")
    if not f then return "" end
    local size = f:seek("end")
    f:seek("set", math.max(0, size - bytes))
    local s = f:read("*a") or ""
    f:close()
    return s
end

local function stamp(line)
    local mo, d, y, h, mi, s = line:match("(%d%d)/(%d%d)/(%d%d)%-(%d%d):(%d%d):(%d%d)")
    if not mo then return nil end
    return os.time({ year = 2000 + tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
end

--- What went wrong, from the end of crash.log, newest first (at most 50):
-- { { time, kind = "crash" | "freeze" | "stopped", title, detail, session } }
-- and how many sessions (KOReader starts) it covers. The session now running
-- is the last; `session` says which one each problem was in.
function Diag.problems(bytes)
    local text = tail(crashLog(), bytes or 1536 * 1024)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do table.insert(lines, line) end
    local events, sessions = {}, 0
    local cur = nil
    local last = nil
    local function finish(nextStart)
        if cur and cur.started and not cur.closed and not cur.crashed then
            table.insert(events, { time = cur.last or cur.started, kind = "stopped", session = cur.n,
                title = "KOReader stopped without closing",
                detail = "It was ended from outside (a freeze, then a restart by holding the power button, or the battery ran out). The last thing it noted was at this time." })
        end
        cur = nextStart
    end
    local i = 1
    while i <= #lines do
        local line = lines[i]
        local t = stamp(line)
        if t then last = t if cur then cur.last = t end end
        if line:find("launching...", 1, true) then
            sessions = sessions + 1
            finish({ n = sessions })
        elseif cur and line:find("%[%*%] Current time:") then
            cur.started = t or cur.started
        elseif cur and line:find("Tearing down UIManager", 1, true) then
            cur.closed = true
        elseif line:match("^%./luajit: ") or line:match("^luajit: ") then
            local trace = {}
            for j = i + 1, math.min(#lines, i + 9) do
                local l = lines[j]
                if l:match("^%s") or l:find("stack traceback", 1, true) then table.insert(trace, (l:gsub("^%s+", ""))) else break end
            end
            if cur then cur.crashed = true end
            table.insert(events, { time = last, kind = "crash", session = cur and cur.n,
                title = "KOReader crashed", detail = line:gsub("^%.?/?luajit: ", "") .. "\n" .. table.concat(trace, "\n") })
        elseif line:find("Web server watchdog: KOReader hasn't answered", 1, true) then
            local secs = line:match("for (%d+) s")
            local detail = {}
            for j = i + 1, math.min(#lines, i + 14) do
                if lines[j]:match("^  ") then table.insert(detail, (lines[j]:gsub("^%s+", ""))) else break end
            end
            table.insert(events, { time = t or last, kind = "freeze", session = cur and cur.n,
                title = "KOReader stopped answering" .. (secs and (" (for " .. secs .. " s when noted)") or ""), detail = table.concat(detail, "\n") })
        elseif line:find("Web server watchdog: KOReader is answering again", 1, true) and #events > 0 and events[#events].kind == "freeze" then
            events[#events].recovered = t
        end
        i = i + 1
    end
    -- (The session running now isn't over: nothing to say about it ending.)
    table.sort(events, function(a, b) return (a.time or 0) > (b.time or 0) end)
    local out = {}
    for k = 1, math.min(50, #events) do out[k] = events[k] end
    return out, sessions
end

--- The problem that ended the last time KOReader ran, or nil (for the
-- launcher's notice on starting).
function Diag.lastEnding()
    local events, sessions = Diag.problems(512 * 1024)
    for __, e in ipairs(events) do
        if e.session == sessions - 1 and (e.kind == "crash" or e.kind == "stopped") then return e end
    end
end

-- ------------------------------------------------------------------ sleep history

local HISTORY = DataStorage:getSettingsDir() .. "/sleep_history.txt"

local function battery()
    local powerd = Device:getPowerDevice()
    local okp, pct = pcall(function() return powerd:getCapacity() end)
    local okc, charging = pcall(function() return powerd:isCharging() end)
    return okp and tonumber(pct) or nil, okc and charging == true
end

--- Notes a sleep, a wake or a start (with the battery) in the history.
function Diag.note(kind)
    local pct, charging = battery()
    local f = io.open(HISTORY, "a")
    if not f then return end
    f:write(string.format("%d\t%s\t%s\t%s\n", os.time(), kind, pct or "", charging and "charging" or ""))
    f:close()
    -- Kept short: the last 300 lines.
    local a = lfs.attributes(HISTORY, "size") or 0
    if a > 30000 then
        local keep = {}
        for line in io.lines(HISTORY) do table.insert(keep, line) end
        local w = io.open(HISTORY, "w")
        if w then
            w:write(table.concat(keep, "\n", math.max(1, #keep - 299)) .. "\n")
            w:close()
        end
    end
end

--- The history as stretches, newest first (at most 40): { { kind = "asleep" |
-- "awake", from, to, pctFrom, pctTo, charging } }, plus KOReader's starts.
function Diag.sleepHistory()
    local rows = {}
    local f = io.open(HISTORY, "r")
    if f then
        for line in f:lines() do
            local t, kind, pct, ch = line:match("^(%d+)\t(%a+)\t(%d*)\t(%a*)")
            if t then table.insert(rows, { t = tonumber(t), kind = kind, pct = tonumber(pct), charging = ch == "charging" }) end
        end
        f:close()
    end
    local out = {}
    for i = 1, #rows do
        local a, b = rows[i], rows[i + 1]
        local stretch
        if a.kind == "sleep" then stretch = "asleep" elseif a.kind == "wake" or a.kind == "start" then stretch = "awake" end
        if stretch then
            local nowPct = battery()
            table.insert(out, { kind = stretch, from = a.t, to = b and b.t or nil, pctFrom = a.pct,
                pctTo = b and b.pct or (stretch == "awake" and nowPct or nil), charging = a.charging or (b and b.charging) or nil,
                started = a.kind == "start" or nil })
        end
    end
    local newest = {}
    for i = #out, math.max(1, #out - 39), -1 do table.insert(newest, out[i]) end
    return newest
end

-- ------------------------------------------------------------------ memory and uptime

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- { rss, peak (KB of KOReader's memory), luaKB, memTotal, memAvailable (KB),
-- uptime (s since the Kindle started), running (s since KOReader started) }.
function Diag.memory()
    local out = { luaKB = math.floor(collectgarbage("count")) }
    local status = readFile("/proc/self/status") or ""
    out.rss = tonumber(status:match("VmRSS:%s*(%d+)"))
    out.peak = tonumber(status:match("VmHWM:%s*(%d+)"))
    local mem = readFile("/proc/meminfo") or ""
    out.memTotal = tonumber(mem:match("MemTotal:%s*(%d+)"))
    out.memAvailable = tonumber(mem:match("MemAvailable:%s*(%d+)")) or tonumber(mem:match("MemFree:%s*(%d+)"))
    local up = tonumber((readFile("/proc/uptime") or ""):match("^([%d%.]+)"))
    out.uptime = up and math.floor(up)
    local stat = readFile("/proc/self/stat") or ""
    -- Field 22 (after the name in brackets): when it started, in 1/100 s since boot.
    local rest = stat:match("%) (.*)$")
    if rest and up then
        local fields = {}
        for x in rest:gmatch("%S+") do table.insert(fields, x) end
        local start = tonumber(fields[20])
        if start then out.running = math.floor(up - start / 100) end
    end
    return out
end

-- ------------------------------------------------------------------ detailed logging

local function setting(k) return (G_reader_settings:readSetting("webpage") or {})[k] end
local function setSetting(k, v)
    local s = G_reader_settings:readSetting("webpage") or {}
    s[k] = v
    G_reader_settings:saveSetting("webpage", s)
end

--- { on, until (when it turns itself off, or nil when turned on in KOReader) }.
function Diag.logging()
    local on = G_reader_settings:isTrue("debug")
    return { on = on, ["until"] = on and setting("debug_until") or nil }
end

--- Turns KOReader's detailed (debug) logging on for a day, or off.
function Diag.setLogging(on)
    local dbg = require("dbg")
    if on then
        G_reader_settings:makeTrue("debug")
        dbg:turnOn()
        setSetting("debug_until", os.time() + 86400)
    else
        G_reader_settings:makeFalse("debug")
        G_reader_settings:makeFalse("debug_verbose")
        pcall(dbg.setVerbose, dbg, false)
        dbg:turnOff()
        setSetting("debug_until", nil)
    end
    G_reader_settings:flush()
end

--- Once per KOReader start: detailed logging turned on here goes off after its day.
function Diag.watchLogging()
    if Diag.logTask then return end
    Diag.logTask = function()
        local untilT = setting("debug_until")
        if untilT and os.time() >= untilT then
            if G_reader_settings:isTrue("debug") then Diag.setLogging(false) else setSetting("debug_until", nil) end
            require("logger").info("Diagnostics: detailed logging turned off after its day")
        end
        UIManager:scheduleIn(30 * 60, Diag.logTask)
    end
    UIManager:scheduleIn(60, Diag.logTask)
end

-- ------------------------------------------------------------------ network

-- Wi-Fi's signal from /proc/net/wireless: link quality (of 70) and level (dBm).
local function signal()
    local s = readFile("/proc/net/wireless") or ""
    for line in s:gmatch("[^\n]+") do
        local iface, q, lvl = line:match("^%s*(%w+):%s+%x+%s+([%d%.%-]+)%s+([%d%.%-]+)")
        if iface then return { interface = iface, quality = tonumber(q), level = tonumber(lvl) } end
    end
end

local function localIp()
    local socket = require("socket")
    local udp = socket.udp()
    if not udp then return nil end
    udp:setpeername("192.0.2.1", 9)
    local ip = udp:getsockname()
    udp:close()
    if ip and ip ~= "0.0.0.0" then return ip end
end

--- Wi-Fi now: { wifiOn, connected, ip, signal = { quality, level } }.
function Diag.network()
    local NetworkMgr = require("ui/network/manager")
    local okw, on = pcall(function() return NetworkMgr:isWifiOn() end)
    local okc, conn = pcall(function() return NetworkMgr:isConnected() end)
    -- The last connection check (each app's last test, with the errors as they came).
    local connections = require("pluginshare").lastConnectionTest
    return { wifiOn = okw and on and true or false, connected = okc and conn ~= false, ip = localIp(), signal = signal(),
        last = Diag.lastTest, connections = connections }
end

local tests = {} -- [key] = { status, results }

-- What to try: Home Assistant (its first address), Microsoft, Wikipedia, the internet.
local function targets()
    local list = {}
    local ha = Common.plugin("homeassistant")
    local ok, addrs = pcall(function() return ha and ha.api and ha.api:addresses() end)
    if ok and type(addrs) == "table" then
        for __, a in ipairs(addrs) do
            table.insert(list, { name = "Home Assistant (" .. (a[1] == "away" and "away" or "home") .. ")", url = a[2]:gsub("/+$", "") .. "/api/" })
        end
    end
    table.insert(list, { name = "Microsoft (To Do, OneNote)", url = "https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration" })
    table.insert(list, { name = "Wikipedia", url = "https://en.wikipedia.org/api/rest_v1/" })
    table.insert(list, { name = "Internet connection", url = "http://connectivitycheck.gstatic.com/generate_204" })
    return list
end

-- In the child: each target tried once (8 s at most each).
local function tryAll(list)
    local socket = require("socket")
    local socketutil = require("socketutil")
    local results = {}
    for __, t in ipairs(list) do
        local http = t.url:match("^https:") and require("ssl.https") or require("socket.http")
        local started = socket.gettime()
        socketutil:set_timeout(8, 10)
        local ok, code = pcall(function()
            local __, c = http.request{ url = t.url, method = "GET", sink = socketutil.table_sink({}), headers = { ["User-Agent"] = "KOReader" } }
            return c
        end)
        socketutil:reset_timeout()
        local ms = math.floor((socket.gettime() - started) * 1000)
        if ok and type(code) == "number" then
            table.insert(results, { name = t.name, ok = true, ms = ms, status = code })
        else
            local why = tostring(code)
            if why:find("timeout") then why = "No answer in 8 s"
            elseif why:find("host not found") or why:find("Name or service") then why = "Its name couldn't be looked up (DNS)"
            elseif why:find("refused") then why = "Refused" end
            table.insert(results, { name = t.name, ok = false, ms = ms, why = why })
        end
    end
    return results
end

--- Starts a test (in a child process); returns a key to ask about. With the
-- launcher, its connection tests (appstest.lua: every app's that's set up, or
-- those in `apps`, the same as on the Kindle); without it, a few addresses tried here.
function Diag.testNetwork(apps)
    local key = tostring(os.time()) .. tostring(math.random(1000, 9999))
    local PS = require("pluginshare")
    if PS.testConnections then
        local state = { status = "testing" }
        tests[key] = state
        PS.testConnections(apps, function(results)
            state.status, state.results = "done", results
        end)
        return key
    end
    local list = targets()
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, results = pcall(tryAll, list)
        ffiutil.writeToFD(write_fd, require("dump")(ok and results or { { name = "Test", ok = false, why = tostring(results) } }), true)
    end, true)
    if not pid then return nil, tostring(fd) end
    local state = { status = "testing" }
    tests[key] = state
    local deadline = os.time() + 90
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(0.5, check) end
            ffiutil.terminateSubProcess(pid)
            state.status, state.results = "done", { { name = "Test", ok = false, why = "Took too long" } }
        else
            local raw = (size and size > 0) and ffiutil.readAllFromFD(fd) or ""
            local fn = raw ~= "" and loadstring("return " .. raw)
            local okf, results = pcall(fn or error)
            state.status, state.results = "done", okf and results or { { name = "Test", ok = false, why = "No answer from the test" } }
            Diag.lastTest = { at = os.time(), results = state.results }
        end
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
        end
    end
    UIManager:scheduleIn(0.5, check)
    return key
end

-- ------------------------------------------------------------------ the file to send

--- A zip of what helps find a problem (no passwords, keys or sign-ins):
-- the end of crash.log, the sleep screen log, the plugins' versions, the
-- problems, the sleep history, memory, battery and network. Returns its path.
function Diag.bundle()
    local json = require("json")
    local path = DataStorage:getDataDir() .. "/cache/kindle-diagnostics.zip"
    os.remove(path)
    local Archiver = require("ffi/archiver")
    local w = Archiver.Writer:new{}
    if not w:open(path, "zip") then return nil, w.err or "Can't write the zip" end
    local function add(name, data) if data and data ~= "" then w:addFileFromMemory(name, data) end end
    add("crash.log", tail(crashLog(), 2 * 1024 * 1024))
    add("sleep-update.log", tail(DataStorage:getDataDir() .. "/sleep-update.log", 512 * 1024))
    local okv, versions = pcall(function() return require("websystem").versions() end)
    add("versions.json", okv and json.encode(versions) or nil)
    local okp, problems = pcall(Diag.problems)
    add("problems.json", okp and json.encode(problems) or nil)
    add("sleep_history.txt", readFile(HISTORY))
    add("memory.json", json.encode(Diag.memory()))
    local okb, bat = pcall(function() return require("websystem").battery() end)
    add("battery.json", okb and json.encode(bat) or nil)
    add("network.json", json.encode(Diag.network()))
    add("about.txt", table.concat({
        "Made " .. os.date("%Y-%m-%d %H:%M"),
        "Device: " .. tostring(Device.model),
        "KOReader: " .. tostring(select(2, pcall(function() return require("version"):getShortVersion() end))),
        "Detailed logging: " .. (G_reader_settings:isTrue("debug") and "on" or "off"),
    }, "\n") .. "\n")
    w:close()
    return path
end

-- ------------------------------------------------------------------ routes

function Diag.routes(server)
    server:route("GET", "^/api/diag/problems$", function(req, res)
        local events, sessions = Diag.problems()
        res:json({ problems = events, sessions = sessions })
    end)

    server:route("GET", "^/api/diag/bundle$", function(req, res)
        local path, why = Diag.bundle()
        if not path then return res:error(500, why) end
        res:file(path, "kindle-diagnostics-" .. os.date("%Y-%m-%d") .. ".zip")
        os.remove(path)
    end)

    server:route("GET", "^/api/diag/network$", function(req, res) res:json(Diag.network()) end)

    server:route("POST", "^/api/diag/network/test$", function(req, res)
        local b = req.json and req.json() or {}
        local apps
        if type(b) == "table" and type(b.app) == "string" then apps = { b.app } end
        if type(b) == "table" and type(b.apps) == "table" then
            apps = {}
            for __, k in ipairs(b.apps) do if type(k) == "string" then table.insert(apps, k) end end
        end
        local key, why = Diag.testNetwork(apps)
        if not key then return res:error(500, why) end
        res:json({ key = key })
    end)

    -- The apps set up to test (with the launcher), to pick from.
    server:route("GET", "^/api/diag/network/apps$", function(req, res)
        local ok, Test = pcall(require, "appstest")
        res:json({ apps = ok and require("pluginshare").testApps and Test.configured() or {} })
    end)

    server:route("GET", "^/api/diag/network/test$", function(req, res)
        local s = tests[req.query.key or ""]
        if not s then return res:error(404, "Not found") end
        res:json(s)
    end)

    server:route("GET", "^/api/diag/sleep$", function(req, res) res:json({ history = Diag.sleepHistory() }) end)

    server:route("GET", "^/api/diag/memory$", function(req, res) res:json(Diag.memory()) end)

    server:route("GET", "^/api/diag/logging$", function(req, res) res:json(Diag.logging()) end)

    server:route("POST", "^/api/diag/logging$", function(req, res)
        Diag.setLogging(req.json().on == true)
        res:json(Diag.logging())
    end)
end

return Diag
