--[[--
Connection tests for every app: each app says what it connects to, and one
runner tries it all in a child process (the screen keeps answering), then
shows the results the same way everywhere. The web page's Test connection
buttons and the System tab's check run the same tests.

An app registers in KOReader's PluginShare (when Apps is installed):

    PS.registerTest{
        key = "homeassistant", name = _("Home Assistant"),
        configured = function() return addresses set end,  -- optional: shown to pick from only then
        -- Runs in the child: blocking requests are fine. One row per thing tried
        -- (each address on its own: at home and away, each AI service...).
        run = function(T) return {
            T.http{ name = _("Internal URL"), url = home .. "/api/", headers = {...},
                    check = function(status, body) return ok, text end },  -- optional
            { name = _("External URL"), detail = away, ok = false, why = _("Not set") },
        } end,
    }

    PS.testConnections(keys, done)  -- keys: a list, or nil for every app; done(results)
    PS.showConnectionTest(key)      -- on the Kindle: "Testing…", then the results

A result: { app, appName, name, detail, ok, why, raw, ms }. `detail` is shown
under the name (an address); `why` says what happened in plain words, and
`raw` is the error as it came (for the log and the diagnostics file). Every
run's failures go to KOReader's log (crash.log), and the last run is kept
(PS.lastConnectionTest) for the web page's diagnostics file.
]]

local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")
local T = ffiutil.template

local Test = {}

-- ------------------------------------------------------------------ in the child

--- What a failed request means, in plain words.
function Test.why(err)
    local s = tostring(err or "")
    if s:find("timeout") or s:find("timed out") then return _("No answer (timed out)") end
    if s:find("host not found") or s:find("Name or service") or s:find("not known") then return _("Its name couldn't be looked up (DNS)") end
    if s:find("refused") then return _("Connection refused (nothing answering on that port)") end
    if s:find("unreachable") then return _("Network unreachable") end
    if s:find("certificate") or s:find("handshake") or s:find("ssl") then return _("Secure connection failed (certificate)") end
    if s == "" or s == "nil" then return _("No answer") end
    return s
end

--- One request, timed: o = { name, url, detail, method, headers, body, timeout (8 s),
-- check = fn(status, body) -> ok, text }. Without check, any answer counts as working.
function Test.http(o)
    local socket = require("socket")
    local socketutil = require("socketutil")
    local http = o.url:match("^https:") and require("ssl.https") or require("socket.http")
    local ltn12 = require("ltn12")
    local started = socket.gettime()
    socketutil:set_timeout(o.timeout or 8, (o.timeout or 8) + 2)
    local sink = {}
    local headers = { ["User-Agent"] = "KOReader" }
    for k, v in pairs(o.headers or {}) do headers[k] = v end
    if o.body then headers["Content-Length"] = tostring(#o.body) end
    local ok, code = pcall(function()
        local __, c = http.request{ url = o.url, method = o.method or "GET", headers = headers,
            source = o.body and ltn12.source.string(o.body) or nil, sink = ltn12.sink.table(sink) }
        return c
    end)
    socketutil:reset_timeout()
    local ms = math.floor((socket.gettime() - started) * 1000)
    local r = { name = o.name, detail = o.detail or o.url:match("^(https?://[^/]+)"), ms = ms }
    if ok and type(code) == "number" then
        if o.check then
            local good, text = o.check(code, table.concat(sink))
            r.ok, r.why = good and true or false, text
        else
            r.ok = true
        end
    else
        r.ok, r.why, r.raw = false, Test.why(code), code ~= nil and tostring(code) or nil
    end
    return r
end

local function runAll(keys)
    local PS = require("pluginshare")
    local out = {}
    for __, key in ipairs(keys) do
        local e = PS.testApps[key]
        local okR, rows = pcall(e.run, Test)
        if okR and type(rows) == "table" and #rows == 0 then rows = { { name = e.name, ok = false, why = _("Not set up") } } end
        if not okR then rows = { { name = e.name, ok = false, why = tostring(rows) } } end
        for __, r in ipairs(type(rows) == "table" and rows or {}) do
            r.app, r.appName = key, e.name
            table.insert(out, r)
        end
    end
    return out
end

-- ------------------------------------------------------------------ here

--- The registered apps' keys, in a steady order: the internet first, then by name.
function Test.keys()
    local PS = require("pluginshare")
    local list = {}
    for k in pairs(PS.testApps or {}) do table.insert(list, k) end
    table.sort(list, function(a, b)
        if (a == "internet") ~= (b == "internet") then return a == "internet" end
        return (PS.testApps[a].name or a) < (PS.testApps[b].name or b)
    end)
    return list
end

--- The apps set up to test (each one's configured() isn't false): { { key, name } }.
function Test.configured()
    local PS = require("pluginshare")
    local out = {}
    for __, k in ipairs(Test.keys()) do
        local e = PS.testApps[k]
        local ok, on = true, true
        if e.configured then ok, on = pcall(e.configured) end
        if ok and on ~= false then table.insert(out, { key = k, name = e.name }) end
    end
    return out
end

--- Runs the tests for `keys` (nil: every app that's set up) in a child; done(results) here.
function Test.run(keys, done)
    if not keys then
        keys = {}
        for __, e in ipairs(Test.configured()) do table.insert(keys, e.key) end
    end
    local PS = require("pluginshare")
    local valid = {}
    for __, k in ipairs(keys) do if PS.testApps[k] then table.insert(valid, k) end end
    if #valid == 0 then return done({}) end
    local pid, fd = ffiutil.runInSubProcess(function(__, write_fd)
        local ok, results = pcall(runAll, valid)
        if not ok then results = { { name = _("Test"), ok = false, why = tostring(results) } } end
        ffiutil.writeToFD(write_fd, require("json").encode(results), true)
    end, true)
    if not pid then return done({ { name = _("Test"), ok = false, why = tostring(fd) } }) end
    local deadline = os.time() + 120
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(0.5, check) end
            ffiutil.terminateSubProcess(pid)
            return done({ { name = _("Test"), ok = false, why = _("It took too long.") } })
        end
        local raw = (size and size > 0) and ffiutil.readAllFromFD(fd) or ""
        local okj, results = pcall(require("json").decode, raw)
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
        end
        if not okj or type(results) ~= "table" then
            logger.warn("Connection test: no answer", raw)
            results = { { name = _("Test"), ok = false, why = _("No answer from the test.") } }
        end
        -- Kept for the diagnostics file, and what didn't work in the log.
        local at = os.time()
        for __, r in ipairs(results) do
            if not r.ok then
                logger.warn("Connection test:", r.appName or "?", "/", r.name or "?", r.detail or "", "-", r.why or "", r.raw and ("(" .. r.raw .. ")") or "")
            end
        end
        -- Each app's last results: { [app] = { at, results } }.
        local last = PS.lastConnectionTest or {}
        local fresh = {}
        for __, r in ipairs(results) do
            local k = r.app or "?"
            if not fresh[k] then fresh[k] = true last[k] = { at = at, results = {} } end
            table.insert(last[k].results, r)
        end
        PS.lastConnectionTest = last
        done(results)
    end
    UIManager:scheduleIn(0.5, check)
end

--- "0.3 s" / "45 ms".
local function took(ms)
    if not ms then return "" end
    if ms < 1000 then return T(_("%1 ms"), ms) end
    return T(_("%1 s"), string.format("%.1f", ms / 1000))
end

--- The results as lines to read: "Internal URL: Works (45 ms)", the address under it.
function Test.text(results, withApp)
    local lines, last = {}, nil
    for __, r in ipairs(results) do
        if withApp and r.appName ~= last and r.appName ~= r.name then
            if #lines > 0 then table.insert(lines, "") end
            table.insert(lines, r.appName)
            last = r.appName
        end
        local state = r.ok and (r.why and r.why ~= "" and r.why or _("Works")) or (r.why or _("Doesn't work"))
        local time = r.ms and (r.ok or r.ms >= 1000) and (" (" .. took(r.ms) .. ")") or ""
        table.insert(lines, r.name .. ": " .. state .. time)
        if r.detail and r.detail ~= "" then table.insert(lines, "    " .. r.detail) end
        if not r.ok and r.raw and r.raw ~= state then table.insert(lines, "    " .. T(_("Error: %1"), r.raw)) end
    end
    return table.concat(lines, "\n")
end

--- On the Kindle: tests one app (or every one), showing the results.
function Test.show(key)
    local NetworkMgr = require("ui/network/manager")
    local PS = require("pluginshare")
    local KO = require("appsko")
    local title = key and PS.testApps[key] and PS.testApps[key].name or _("Connections")
    NetworkMgr:runWhenOnline(function()
        local wait = KO.wait(T(_("Testing %1…"), title))
        Test.run(key and { key } or nil, function(results)
            if wait then wait:close() end
            KO.message{ title = T(_("Test: %1"), title), lines = 30,
                text = #results > 0 and Test.text(results, key == nil) or _("Nothing set up to test yet.") }
        end)
    end)
end

-- ------------------------------------------------------------------ the launcher's Connection check

--- Settings > Launcher > Connection check: the launcher's "conntest" screen. The apps
-- set up are listed, all ticked; Test selected tries the ticked ones.
function Test.open(view)
    view.backTo = view.mode ~= "conntest" and view.mode or view.backTo
    view.mode, view.conntestPage = "conntest", 1
    view.connPick = view.connPick or {}
    view:refresh()
end

--- Tests the ticked apps (Wi-Fi first, if it's off).
function Test.again(view)
    local keys = {}
    for __, e in ipairs(Test.configured()) do
        if view.connPick[e.key] ~= false then table.insert(keys, e.key) end
    end
    if #keys == 0 then return require("appsko").toast(_("Tick at least one.")) end
    require("ui/network/manager"):runWhenOnline(function()
        view.connResults, view.connTesting = nil, true
        view:refresh()
        Test.run(keys, function(results)
            view.connResults, view.connTesting, view.connAt = results, false, os.time()
            if view.mode == "conntest" then view:refresh() end
        end)
    end)
end

function Test.draw(view, c)
    local C = require("appscanvas")
    local F = c:flow(56, c.H - 8, view.conntestPage or 1)
    F:block(46, function(y)
        c:text(14, y + 24, _("Each address on its own: the same test as each app's Test connection."), 10.5,
            { color = C.GREY, maxw = c.W - 28 })
    end)
    -- What to test: the apps set up, ticked to start with.
    local apps = Test.configured()
    local picked = 0
    for __, e in ipairs(apps) do if view.connPick[e.key] ~= false then picked = picked + 1 end end
    F:block(36, function(y)
        c:text(14, y + 26, _("WHAT TO TEST"), 9.5, { bold = true, color = C.GREY })
        local label = picked == #apps and _("Select none") or _("Select all")
        c:text(c.W - 14, y + 26, label, 10.5, { align = "end", bold = true })
        c:hit(c.W - 30 - c:width(label, 10.5, true), y, c:width(label, 10.5, true) + 30, 36, function()
            local on = picked ~= #apps
            for __, e in ipairs(apps) do view.connPick[e.key] = on end
            view:refresh()
        end)
    end, 120)
    for __, e in ipairs(apps) do
        F:block(46, function(y)
            local on = view.connPick[e.key] ~= false
            c:box(14, y + 12, 22, 22, { r = 4, border = C.BLACK, bw = 1.6, fill = on and C.FILL or nil })
            if on then c:icon("check", 16, y + 14, 18, true) end
            c:text(48, y + 29, e.name, 12.5)
            c:hline(48, y + 45, c.W - 62)
            c:hit(0, y, c.W, 46, function() view.connPick[e.key] = not on view:refresh() end)
        end)
    end
    F:block(64, function(y)
        local label = view.connTesting and _("Testing…") or T(_("Test selected (%1)"), picked)
        local bw = c:width(label, 12, true) + 48
        c:box(14, y + 14, bw, 40, { r = 20, fill = C.FILL })
        c:text(14 + bw / 2, y + 40, label, 12, { bold = true, align = "middle", color = C.ON_FILL })
        if not view.connTesting then c:hit(14, y + 10, bw, 48, function() Test.again(view) end) end
    end)
    if view.connTesting then
        F:block(50, function(y) c:text(14, y + 30, _("Testing… (up to 8 s for each address)"), 12, { color = C.GREY }) end)
    end
    local last
    for __, r in ipairs(view.connResults or {}) do
        if r.appName ~= last then
            last = r.appName
            if r.appName ~= r.name then F:block(36, function(y) c:text(14, y + 26, (r.appName or ""):upper(), 9.5, { bold = true, color = C.GREY }) end, 80) end
        end
        local state = r.ok and (r.why and r.why ~= "" and r.why or _("Works")) or (r.why or _("Doesn't work"))
        local lines = c:wrap(state, 11, c.W - 60, 3)
        -- The error as it came, when it says more than the plain words.
        local raw = not r.ok and r.raw and r.raw ~= state and c:wrap(T(_("Error: %1"), r.raw), 9.5, c.W - 60, 2) or {}
        local h = 34 + (r.detail and r.detail ~= "" and 18 or 0) + 18 * #lines + 16 * #raw
        F:block(h, function(y)
            c:icon(r.ok and "check" or "x", 14, y + 10, 18)
            c:text(44, y + 25, r.name or "", 12.5, { bold = true, maxw = c.W - 150 })
            if r.ms then c:text(c.W - 14, y + 25, took(r.ms), 10.5, { align = "end", color = C.GREY }) end
            local yy = y + 25
            if r.detail and r.detail ~= "" then
                yy = yy + 18
                c:text(44, yy, r.detail, 10.5, { color = C.GREY, maxw = c.W - 60 })
            end
            for __, l in ipairs(lines) do
                yy = yy + 18
                c:text(44, yy, l, 11, { bold = not r.ok })
            end
            for __, l in ipairs(raw) do
                yy = yy + 16
                c:text(44, yy, l, 9.5, { color = C.GREY })
            end
            c:hline(44, y + h - 1, c.W - 58)
        end)
    end
    if view.connResults and #view.connResults == 0 then
        F:block(50, function(y) c:text(14, y + 30, _("Nothing set up to test yet."), 12, { color = C.GREY }) end)
    end
    if view.connAt and not view.connTesting then
        F:block(40, function(y) c:text(14, y + 28, T(_("Last checked: %1"), require("appsnotify").when(view.connAt)), 10.5, { color = C.GREY }) end)
    end
    view.pages = F:pages()
    if (view.conntestPage or 1) > view.pages then
        view.conntestPage = view.pages
        return view:render()
    end
    view:bar(c, _("Connection check"))
end

function Test.install()
    local PS = require("pluginshare")
    PS.testApps = PS.testApps or {}
    PS.registerTest = function(e) if type(e) == "table" and e.key and e.run then PS.testApps[e.key] = e end end
    PS.testConnections = Test.run
    PS.showConnectionTest = Test.show
    PS.connectionTestText = Test.text
    -- The internet connection itself, first in the check of everything.
    PS.registerTest{ key = "internet", name = _("Internet connection"), run = function()
        return { Test.http{ name = _("Internet connection"), detail = "connectivitycheck.gstatic.com",
            url = "http://connectivitycheck.gstatic.com/generate_204" } }
    end }
end

return Test
