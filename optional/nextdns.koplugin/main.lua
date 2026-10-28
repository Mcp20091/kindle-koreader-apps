--[[--
NextDNS: a NextDNS profile on the Kindle, over NextDNS's API with the
account's API key. Today's queries and how many were blocked, the domains
blocked most, the query log (filtered and searched), the denylist and
allowlist (add, turn on or off, delete), the security, privacy and parental
control switches, the profile in use, and whether this Kindle itself goes
through NextDNS (test.nextdns.io).

Nothing runs in the background: NextDNS is read while the app is open, and
when the launcher's tile or a quick button shows it.

Also: the launcher's tile line (appsLine, event ShowNextDNS), its settings,
search, setup step, quick buttons, connection test and backup, gestures,
and calls for the web page (webState, webAct).

@module koplugin.nextdns
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local M = require("ndmodel")

-- Kept while KOReader runs (each book and the library get a new plugin).
local state = {
    data = nil,        -- the profile and today's numbers as last read (ndmodel.data)
    time = 0,          -- when
    tried = 0,         -- when it was last asked (answered or not)
    why = nil,         -- why the last read failed (nil: it worked)
    reading = false,
    waiting = {},
    line = nil,        -- the launcher's line as last shown
    profiles = nil,    -- the account's profiles, once listed ({ { id, name } })
    -- the query log as last read: its filter, search and device (its id and name), the entries,
    -- the next page's cursor
    logs = { filter = "all", search = "", device = "", deviceName = "", items = nil, cursor = "", time = 0,
        why = nil, reading = false },
    -- today's devices, for the log's device filter (ndmodel.devices), and when they were read
    devices = nil, devicesTime = 0,
}

local NextDNS = WidgetContainer:extend{
    name = "nextdns",
    is_doc_only = false,
}

-- The NextDNS plugin of the open library or book.
local function current()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    return ui and ui.nextdns
end
NextDNS.current = current

function NextDNS:init()
    self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/nextdns.lua")
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    require("ndko").flashOnUncover()
    require("ndui").plugin = self
    self:shareWithApps()
end

function NextDNS:onDispatcherRegisterActions()
    Dispatcher:registerAction("nextdns_show", { category = "none", event = "ShowNextDNS", title = _("NextDNS"), general = true })
end

function NextDNS:addToMainMenu(menu_items)
    menu_items.nextdns = {
        text = _("NextDNS"),
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

function NextDNS:onShowNextDNS()
    self:show()
    return true
end

function NextDNS:show(page)
    return require("ndui").show(self, page)
end

-- ------------------------------------------------------------------ the connection's settings

--- { key, profile, profileName } (fields nil until set).
function NextDNS:cfg()
    return { key = self.store:readSetting("key"), profile = self.store:readSetting("profile"),
        profileName = self.store:readSetting("profile_name") }
end

function NextDNS:configured()
    local c = self:cfg()
    return c.key ~= nil and c.profile ~= nil
end

--- Change some of the settings ({ key = …, … }; false clears one); what was read is forgotten.
function NextDNS:setCfg(t)
    for k, v in pairs(t) do
        local name = k == "profileName" and "profile_name" or k
        if v == false or v == "" then self.store:delSetting(name) else self.store:saveSetting(name, v) end
    end
    self.store:flush()
    if t.key ~= nil then state.profiles = nil end
    state.data, state.why, state.time, state.tried = nil, nil, 0, 0
    state.logs.items, state.logs.cursor, state.logs.why, state.logs.time = nil, "", nil, 0
    state.logs.device, state.logs.deviceName, state.devices, state.devicesTime = "", "", nil, 0
    self:changed()
end

--- The profile's name as shown: the one read, else the one saved, else "NextDNS".
function NextDNS:profileName()
    local d = state.data
    local c = self:cfg()
    return (d and d.name ~= "" and d.name) or c.profileName or c.profile or _("NextDNS")
end

--- How often the open app reads NextDNS (seconds, 30 to 600).
function NextDNS:interval()
    return math.max(30, math.min(600, tonumber(G_reader_settings:readSetting("nextdns_interval")) or 60))
end

-- ------------------------------------------------------------------ reading NextDNS

function NextDNS:api(cfg)
    return require("ndapi").new(cfg or self:cfg())
end

--- Why something failed, in plain words.
function NextDNS:whyText(why)
    local s = tostring(why or "")
    if s == "signin" then return _("NextDNS refused the API key. Check it in Settings.") end
    if s == "notfound" then return _("NextDNS doesn't know that profile. Pick it again in Settings.") end
    if s == "busy" then return _("NextDNS asked to wait: too many requests for now. Try again in a minute.") end
    if s == "notapi" then return _("NextDNS's API didn't answer as expected.") end
    if s == "offline" then return _("Not on Wi-Fi.") end
    if s == "notset" then return _("NextDNS isn't set up yet.") end
    if s:find("timeout") or s:find("timed out") then return _("NextDNS didn't answer in time.") end
    if s:find("host not found") or s:find("unreachable") or s:find("No route") or s:find("resolve") then
        return _("NextDNS can't be reached from this Wi-Fi.")
    end
    if s:find("certificate") or s:find("handshake") or s:find("ssl") then return _("The secure connection failed (its certificate).") end
    if s == "" or s == "nil" or s == "no answer" or s == "nothing" then return _("NextDNS didn't answer.") end
    return s
end

--- Read the profile and today's numbers in the background; done(data) when they're in
-- (nil and why when it didn't answer). One read at a time.
function NextDNS:fetch(done)
    if done then table.insert(state.waiting, done) end
    if state.reading then return end
    local function finish(d, why)
        local waiting = state.waiting
        state.waiting = {}
        for __, f in ipairs(waiting) do pcall(f, d, why) end
    end
    if not self:configured() then return finish(nil, "notset") end
    if not NetworkMgr:isConnected() then
        state.why = "offline"
        return finish(nil, "offline")
    end
    state.reading, state.tried = true, os.time()
    local api = self:api()
    local from = M.todayStart()
    require("ndbg").run(function()
        local r, why = api:readAll(from)
        if not r then return { why = why } end
        return { raw = r }
    end, function(r, why)
        state.reading = false
        if r and r.raw then
            state.data, state.time, state.why = M.data(r.raw), os.time(), nil
            -- (the profile's own name, for when NextDNS isn't answering)
            if state.data.name ~= "" and state.data.name ~= self.store:readSetting("profile_name") then
                self.store:saveSetting("profile_name", state.data.name)
                self.store:flush()
            end
            self:changed()
            return finish(state.data)
        end
        state.why = (r and r.why) or why or "no answer"
        logger.info("NextDNS: no answer:", state.why)
        self:changed()
        finish(nil, state.why)
    end, { limit = 30 })
end

--- What was last read (nil until read); read again in the background when older than
-- maxAge seconds (and on Wi-Fi).
function NextDNS:status(maxAge)
    local last = math.max(state.time, state.tried)
    if self:configured() and os.time() - last >= (maxAge or 60) and not state.reading and NetworkMgr:isConnected() then
        self:fetch()
    end
    return state.data
end

function NextDNS:data() return state.data end
function NextDNS:readTime() return state.time end
function NextDNS:lastWhy() return state.why end
function NextDNS:reading() return state.reading end

--- Redraw what shows NextDNS: the app's pages, or the launcher when its line changed.
function NextDNS:changed()
    local UI = require("ndui")
    if #UI.pages > 0 then UI.refreshAll() end
    local line = self:appsLine()
    if line == state.line then return end
    state.line = line
    local apps = self.ui and self.ui.apps
    if apps and apps.changed then pcall(apps.changed, apps) end
end

--- The launcher tile's line: "1,872 blocked today · 15%".
function NextDNS:appsLine()
    if not self:configured() then return M.appsLine(nil, false) end
    local d = self:status(300)
    if not d and state.why == "offline" then return _("Not on Wi-Fi") end
    if not d and state.why then return _("NextDNS not answering") end
    return M.appsLine(d, true)
end

-- ------------------------------------------------------------------ the query log

--- The query log as last read: { filter, search, device, deviceName, items, cursor, time, why, reading }.
function NextDNS:logState() return state.logs end

--- Read the query log in the background. opts: { filter, search, device, deviceName } (each kept
-- for next time when given; device "" is every device), more = true for the next page after
-- what's shown. done() after.
function NextDNS:readLogs(opts, done)
    opts = opts or {}
    local L = state.logs
    if opts.filter then L.filter = opts.filter end
    if opts.search then L.search = opts.search end
    if opts.device then L.device, L.deviceName = opts.device, opts.deviceName or opts.device end
    local function finish() self:changed() if done then done() end end
    if not self:configured() then L.why = "notset" return finish() end
    if not NetworkMgr:isConnected() then L.why = "offline" return finish() end
    -- (one read at a time: one with another filter starts again when this one is in)
    if L.reading then
        if not opts.more then L.items = nil finish() end
        return
    end
    local more = opts.more and L.items and L.cursor ~= ""
    if not more then L.items, L.cursor = nil, "" end
    L.reading = true
    local api = self:api()
    local args = { status = L.filter, search = L.search, device = L.device, cursor = more and L.cursor or nil }
    local asked = L.filter .. "\n" .. L.search .. "\n" .. L.device
    require("ndbg").run(function()
        local r, why = api:logs(args)
        if not r then return { why = why } end
        return r
    end, function(r, why)
        L.reading = false
        -- (the filter changed while it was read: read it again with the new one)
        if asked ~= L.filter .. "\n" .. L.search .. "\n" .. L.device then return self:readLogs({}, done) end
        if r and r.items then
            local items = M.logs(r.items)
            if more then
                for __, e in ipairs(items) do table.insert(L.items, e) end
            else
                L.items = items
            end
            L.cursor, L.time, L.why = r.cursor or "", os.time(), nil
        else
            L.why = (r and r.why) or why or "no answer"
            logger.info("NextDNS: the log didn't come:", L.why)
        end
        finish()
    end, { limit = 30 })
end

--- Today's devices, busiest first (ndmodel.devices): done(list) or done(nil, why). Read in the
-- background, and kept for 5 minutes (again sooner with force); quiet: no waiting message (the web page).
function NextDNS:devices(done, force, quiet)
    if state.devices and not force and os.time() - state.devicesTime < 300 then return done(state.devices) end
    if not self:configured() then return done(nil, "notset") end
    if not NetworkMgr:isConnected() then return done(nil, "offline") end
    local api = self:api()
    local from = M.todayStart()
    require("ndbg").run(function()
        local list, why = api:devices(from)
        if not list then return { why = why } end
        return { list = list }
    end, function(r, why)
        if r and r.list then
            state.devices, state.devicesTime = M.devices(r.list), os.time()
            return done(state.devices)
        end
        done(nil, (r and r.why) or why or "no answer")
    end, { limit = 30, text = not quiet and _("Reading the devices…") or nil })
end

function NextDNS:knownDevices() return state.devices end

-- ------------------------------------------------------------------ actions

-- What each action does, in the child; and the change it makes, put in what was read
-- at once (the next read confirms it).
local ACTIONS = {
    switch = { run = function(api, a) return api:setSwitch(M.switch(a.key).group, a.key, a.on) end,
        check = function(a) return M.switch(a.key) ~= nil end,
        apply = function(d, a) d.switches[a.key] = a.on end },
    list_add = { run = function(api, a) return api:listAdd(a.list, a.domain, a.active) end,
        apply = function(d, a)
            local e = M.find(d, a.list, a.domain)
            if e then e.active = a.active ~= false else table.insert(d[a.list], { domain = a.domain, active = a.active ~= false }) end
        end },
    list_active = { run = function(api, a) return api:listActive(a.list, a.domain, a.on) end,
        apply = function(d, a) local e = M.find(d, a.list, a.domain) if e then e.active = a.on end end },
    list_delete = { run = function(api, a) return api:listDelete(a.list, a.domain) end,
        apply = function(d, a) local __, i = M.find(d, a.list, a.domain) if i then table.remove(d[a.list], i) end end },
}
NextDNS.ACTIONS = ACTIONS

--- Do an action in the background; then done(ok, text) (text: why it failed, in plain
-- words) and NextDNS read again. args: switch { key, on }; list_add { list, domain, active };
-- list_active { list, domain, on }; list_delete { list, domain } (list: "deny" or "allow").
function NextDNS:act(name, args, done, opts)
    local a = ACTIONS[name]
    args = args or {}
    if not a then return done and done(false, "Unknown action") end
    if a.check and not a.check(args) then return done and done(false, "Unknown switch") end
    if args.list and args.list ~= "deny" and args.list ~= "allow" then return done and done(false, "Which list?") end
    if not self:configured() then return done and done(false, self:whyText("notset")) end
    if not NetworkMgr:isConnected() then return done and done(false, self:whyText("offline")) end
    local api = self:api()
    if state.data then
        a.apply(state.data, args)
        self:changed()
    end
    require("ndbg").run(function()
        local ok, why = a.run(api, args)
        if not ok then return { why = why or "refused" } end
        return { ok = true }
    end, function(r, why)
        local good = r and r.ok
        local text
        if not good then
            why = (r and r.why) or why
            logger.warn("NextDNS:", name, why)
            text = self:whyText(why)
        end
        -- (read again: confirms the change, or puts back what it couldn't do)
        UIManager:scheduleIn(good and 1 or 0, function() self:fetch() end)
        if done then done(good and true or false, text) end
    end, { limit = 25, text = opts and opts.text })
end

--- The account's profiles: done(list) (each { id, name }) or done(nil, why). cfg: { key }
-- (the saved key when nil). Remembered for the saved key.
function NextDNS:profiles(cfg, done)
    local saved = cfg == nil
    if saved and state.profiles then return done(state.profiles) end
    if not NetworkMgr:isConnected() then return done(nil, "offline") end
    local api = self:api(cfg)
    require("ndbg").run(function()
        local list, why = api:profiles()
        if not list then return { why = why } end
        return { list = list }
    end, function(r, why)
        if r and r.list then
            local list = M.profiles(r.list)
            if saved then state.profiles = list end
            return done(list)
        end
        done(nil, (r and r.why) or why)
    end, { limit = 25, text = _("Connecting to NextDNS…") })
end

function NextDNS:knownProfiles() return state.profiles end

--- Another profile: saved, and read.
function NextDNS:useProfile(p)
    local list = state.profiles
    self:setCfg({ profile = p.id, profileName = p.name })
    state.profiles = list
    self:fetch()
end

-- ------------------------------------------------------------------ the launcher

function NextDNS:shareWithApps()
    local PS = require("pluginshare")
    -- What it is for the launcher and the web page: its tile (only there while it's installed:
    -- an optional app), Settings group (Optional apps; its tile in the suggested Tools group), web tab
    -- (apps.koplugin/appsinfo.lua).
    PS.appInfo = PS.appInfo or {}
    PS.appInfo.nextdns = { name = _("NextDNS"), icon = "ban", dir = self.path, order = 87, group = "optional",
        -- "1,872 blocked today · 15%".
        tiles = { { key = "nextdns", group = "tools", event = "ShowNextDNS", line = function(p) return p:appsLine() end } },
        web = { page = "nextdns", routes = "webnextdns", script = "web/nextdns.js",
            card = "Your NextDNS profile: blocked queries, the query log, the lists and the protection switches." } }
    PS.notifyOpeners = PS.notifyOpeners or {}
    PS.notifyOpeners.nextdns = function()
        local p = current()
        if p then p:show() end
    end
    -- The web page's backup: the profile and the settings; the API key only with
    -- Include keys and sign-ins.
    PS.backupApps = PS.backupApps or {}
    PS.backupApps.nextdns = { key = "nextdns", name = _("NextDNS"),
        files = { "^nextdns%.lua$" },
        reader_keys = { "^nextdns_" },
        secret_keys = { ["nextdns.lua"] = { "key" } } }
    if PS.registerSettings then
        PS.registerSettings{ key = "nextdns", name = _("NextDNS"), icon = "ban",
            open = function() local p = current() if p then p:show("settings") end end,
            rows = function()
                local p = current()
                return p and require("ndui").searchRows(p) or {}
            end }
    end
    if PS.registerSearch then
        PS.registerSearch{ key = "nextdns", name = _("NextDNS"), icon = "ban", search = function(q)
            local p = current()
            return p and p:search(q) or {}
        end }
    end
    if PS.registerSetup then
        PS.registerSetup{ key = "nextdns", order = 59, icon = "ban", title = _("NextDNS"),
            text = _("Your NextDNS profile on the Kindle: today's blocked queries, the query log, the denylist and allowlist, and the protection switches."),
            done = function() local p = current() return p ~= nil and p:configured() end,
            doneText = _("NextDNS set up"), action = _("Set up"),
            skipped = _("Nothing else needs it. Set it up any time from the NextDNS app."),
            help = { button = _("What you need"), title = _("Connecting to NextDNS"),
                steps = {
                    _("A NextDNS account with at least one profile."),
                    _("The account's API key: on NextDNS's website, open Account and find API at the bottom."),
                },
                after = _("The key stays on the Kindle and is only sent to NextDNS."),
                guide = "nextdns.md" },
            run = function() local p = current() if p then require("ndui").setup(p) end end }
    end
    if PS.registerTest then
        PS.registerTest{ key = "nextdns", name = _("NextDNS"),
            configured = function() local p = current() return p ~= nil and p:configured() end,
            run = function(Test)
                local p = current()
                local c = p and p:cfg() or {}
                local api = require("ndapi").new(c)
                local socket = require("socket")
                local rows = {}
                local function timed(name, detail, fn)
                    local started = socket.gettime()
                    local r, why = fn()
                    local row = { name = name, detail = detail, ok = r ~= nil, ms = math.floor((socket.gettime() - started) * 1000) }
                    if not r then row.raw, row.why = tostring(why), (p and p:whyText(why)) or Test.why(why) end
                    table.insert(rows, row)
                    return r, row
                end
                local list, row = timed(_("API key"), "api.nextdns.io", function() return api:profiles() end)
                if list then row.why = T(_("%1 profiles"), #list) end
                if list then
                    local prof
                    prof, row = timed(_("Profile"), c.profile or "?", function() return api:profileData() end)
                    if prof then row.why = M.str(prof.name) end
                end
                local k
                k, row = timed(_("This Kindle"), "test.nextdns.io", function() return api:kindle() end)
                if k then
                    local kk = M.kindle(k)
                    row.ok = kk.using
                    row.why = M.kindleText(kk, c.profile)
                end
                return rows
            end }
    end
    if PS.registerQuick then
        PS.registerQuick{ key = "nextdns", name = _("NextDNS"),
            choices = function()
                local out = { { id = "status", name = _("Blocked today"), icon = "ban", group = _("NextDNS") } }
                for __, s in ipairs(M.SWITCHES) do
                    table.insert(out, { id = "switch:" .. s.key, name = s.name, icon = "shield", group = _("Protection") })
                end
                return out
            end,
            item = function(id)
                local p = current()
                return p and p:quickItem(id)
            end }
    end
end

--- A quick button: today's blocked count (tap reads it again), or a switch on or off.
function NextDNS:quickItem(id)
    if not self:configured() then return nil end
    local d = self:status(300)
    local ko = require("ndko")
    if id == "status" then
        return { label = self:profileName(), icon = "ban", value = d and M.summary(d) or nil,
            tap = function(done) self:fetch(function() if done then done() end end) end,
            hold = function() self:show() end }
    end
    local key = id:match("^switch:(%w+)$")
    local s = key and M.switch(key)
    if s then
        local on = d and d.switches[key] or false
        return { label = s.name, icon = "shield", on = on, value = d and (on and _("On") or _("Off")) or nil,
            tap = function(done)
                if not d then
                    ko.toast(_("Not read yet"))
                    return done and done()
                end
                self:act("switch", { key = key, on = not on }, function(ok, text)
                    if not ok then ko.toast(text, 4) end
                    if done then done() end
                end)
            end,
            hold = function() self:show() require("ndui").protection(self) end }
    end
end

--- The launcher's search (q in lower case): list entries, top blocked domains and
-- switches as last read, and the profile itself.
function NextDNS:search(q)
    local out = {}
    if not q or q == "" then return out end
    local name = self:profileName()
    if name:lower():find(q, 1, true) or ("nextdns"):find(q, 1, true) then
        table.insert(out, { title = name, sub = state.data and M.summary(state.data) or _("NextDNS"),
            open = function() self:show() end })
    end
    for __, hit in ipairs(M.search(state.data, q)) do
        local kind = hit.kind
        table.insert(out, { title = hit.title, sub = hit.sub, open = function()
            self:show()
            local UI = require("ndui")
            if kind == "deny" or kind == "allow" then UI.list(self, kind)
            elseif kind == "switch" then UI.protection(self) end
        end })
    end
    return out
end

-- ------------------------------------------------------------------ the web page

--- What the web page's NextDNS tab shows (no API key).
function NextDNS:webState()
    local c = self:cfg()
    local d = self:configured() and self:status(30) or nil
    local L = state.logs
    local out = { configured = self:configured(), hasKey = c.key ~= nil, keyHint = c.key and M.masked(c.key) or nil,
        profile = c.profile, name = self:profileName(), interval = self:interval(),
        read = state.time > 0 and state.time or nil, why = state.why and self:whyText(state.why) or nil,
        profiles = state.profiles }
    if d then
        out.summary = M.summary(d)
        out.stats = { total = d.total, blocked = d.blocked, allowed = d.allowed,
            totalText = M.number(d.total), blockedText = M.number(d.blocked), percent = M.percent(d.blocked, d.total) }
        out.top = {}
        for __, x in ipairs(d.top) do table.insert(out.top, { domain = x.domain, queries = M.number(x.queries) }) end
        out.deny, out.allow = d.deny, d.allow
        out.switches = {}
        for __, s in ipairs(M.SWITCHES) do
            table.insert(out.switches, { key = s.key, group = s.group, name = s.name, sub = s.sub, on = d.switches[s.key] })
        end
        out.kindle = { using = d.kindle and d.kindle.using or false, text = M.kindleText(d.kindle, c.profile),
            sub = M.kindleSub(d.kindle) }
    end
    out.devices = state.devices
    out.logs = { filter = L.filter, search = L.search, device = L.device, deviceName = L.deviceName,
        reading = L.reading, more = L.cursor ~= "",
        why = L.why and self:whyText(L.why) or nil, read = L.time > 0 and L.time or nil }
    if L.items then
        local twentyFour = not G_reader_settings:isTrue("twelve_hour_clock")
        local now = os.time()
        out.logs.items = {}
        for __, e in ipairs(L.items) do
            table.insert(out.logs.items, { domain = e.domain, status = e.status, statusText = M.statusText(e.status),
                line = M.logLine(e, now, twentyFour) })
        end
    end
    return out
end

--- The web page's actions: switch { key, on }; list_add { list, domain }; list_active
-- { list, domain, on }; list_delete { list, domain }; logs { filter, search, device, more }; devices;
-- profiles (lists them); profile { id }; refresh (each started in the background: the page
-- reads the state again after); settings { key, interval }. Returns true, or false and why.
function NextDNS:webAct(name, args)
    args = type(args) == "table" and args or {}
    if name == "settings" then
        if args.key ~= nil and args.key ~= "" then self:setCfg({ key = tostring(args.key) }) end
        if tonumber(args.interval) then
            G_reader_settings:saveSetting("nextdns_interval", math.max(30, math.min(600, math.floor(tonumber(args.interval)))))
        end
        if self:configured() and args.key ~= nil and args.key ~= "" then self:fetch() end
        return true
    end
    if not self:cfg().key then return false, self:whyText("notset") end
    if not NetworkMgr:isConnected() then return false, self:whyText("offline") end
    if name == "profiles" then
        self:profiles(nil, function() end)
        return true
    end
    if name == "profile" then
        local id = tostring(args.id or "")
        if id == "" then return false, "Which profile?" end
        local pname = id
        for __, p in ipairs(state.profiles or {}) do if p.id == id then pname = p.name end end
        self:useProfile({ id = id, name = pname })
        return true
    end
    if not self:configured() then return false, self:whyText("notset") end
    if name == "refresh" then
        self:fetch()
        return true
    end
    if name == "logs" then
        local filter = args.filter
        if filter ~= "all" and filter ~= "blocked" and filter ~= "allowed" then filter = nil end
        local device, deviceName
        if args.device ~= nil then
            device = tostring(args.device)
            deviceName = device
            for __, d in ipairs(state.devices or {}) do if d.id == device then deviceName = d.name end end
        end
        self:readLogs({ filter = filter, search = args.search ~= nil and tostring(args.search) or nil,
            device = device, deviceName = deviceName, more = args.more == true })
        return true
    end
    if name == "devices" then
        self:devices(function() end, true, true)
        return true
    end
    if not ACTIONS[name] then return false, "Unknown action" end
    local a = {}
    if name == "switch" then
        a.key, a.on = tostring(args.key or ""), args.on == true
        if not M.switch(a.key) then return false, "Which switch?" end
    else
        a.list = args.list
        a.domain = M.cleanDomain(args.domain)
        if not a.domain then return false, _("Enter a domain, such as example.com.") end
        if name == "list_active" then a.on = args.on == true end
    end
    self:act(name, a)
    return true
end

return NextDNS
