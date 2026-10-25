--[[--
Home Assistant: control the home from KOReader.

Tools > Home Assistant (or a gesture: General > Home Assistant, or Home
Assistant dashboard) opens Home: what is on, Quick tiles, rooms, cameras,
media, scenes and scripts, and a dashboard that can stay up while the reader
charges. The last states are kept, so the screens open without Wi-Fi; while
open they update every minute when the reader is online (Wi-Fi is never
turned on for that).

@module koplugin.homeassistant
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local PluginShare = require("pluginshare")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local ffiutil = require("ffi/util")
local _ = require("gettext")
local T = ffiutil.template

local Api = require("haapi")
local Canvas = require("hacanvas")
local Model = require("hamodel")
local Settings = require("hasettings")
local Template = require("hatemplate")
local View = require("haview")

-- Online enough to try: Wi-Fi has an address. (NetworkMgr:isOnline looks up
-- a name on the internet, which can hang the screen for many seconds when
-- Wi-Fi is up but the internet isn't; Home Assistant at home doesn't need it.)
local function online()
    return NetworkMgr:isConnected() ~= false
end

-- Keeping the Kindle awake, shared with the other plugins that do (the web
-- server, Home Assistant's dashboard): each asks for itself, and it sleeps
-- again once none asks. KOReader's own sleep timer is held off, and on a
-- Kindle its power manager is told not to sleep too (it ignores KOReader's
-- timer), as KOReader's Keep alive does (and its flag is raised, which KOReader's
-- timer checks); told it may again when KOReader exits.
local function stayAwake(who, on)
    local reasons = PluginShare.awake_reasons or {}
    PluginShare.awake_reasons = reasons
    reasons[who] = on and true or nil
    local any = next(reasons) ~= nil
    PluginShare.pause_auto_suspend = any or nil
    if Device:isKindle() and (PluginShare.kindle_kept_awake or false) ~= any then
        PluginShare.kindle_kept_awake = any
        -- KOReader's sleep timer resets the power manager's timer (t1) every few minutes and
        -- stands aside only for its own Keep alive. Kept awake past the sleep time without this,
        -- it reschedules itself for "now" forever and KOReader freezes.
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
if not Device.__stayAwakeExit then
    Device.__stayAwakeExit = true
    local exit = Device.exit
    Device.exit = function(...)
        if PluginShare.kindle_kept_awake then
            PluginShare.kindle_kept_awake = false
            os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1")
        end
        return exit(...)
    end
end

local CACHE = DataStorage:getSettingsDir() .. "/homeassistant-states.json"

-- Devices just turned off here: id -> when (they stay in On now a while).
local turnedOff = {}

local HomeAssistant = WidgetContainer:extend{
    name = "homeassistant",
    is_doc_only = false,
}

-- KOReader's network, for haapi: (status or error, body).
local function httpRequest(method, url, headers, body, timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    local request = { url = url, method = method, headers = headers or {}, sink = ltn12.sink.table(sink) }
    if body then
        request.source = ltn12.source.string(body)
        request.headers["Content-Length"] = tostring(#body)
    end
    timeout = timeout or 25
    socketutil:set_timeout(math.min(timeout, 10), timeout)
    local ok, code = pcall(function() return socket.skip(1, http.request(request)) end)
    socketutil:reset_timeout()
    if not ok then code = tostring(code) end
    if type(code) ~= "number" then logger.warn("Home Assistant:", method, (url:gsub("%?.*", "")), code) end
    return code, table.concat(sink)
end

function HomeAssistant:init()
    Canvas.setDir(self.path)
    self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/homeassistant.lua")
    self.prefs = self.store:readSetting("prefs") or {}
    -- Gone: the clock is KOReader's own for every app, and the time and battery always show.
    self.prefs.clock_24h, self.prefs.time_battery = nil, nil
    -- Its own dark mode is gone (KOReader's night mode is the one for every app).
    if self.prefs.dark ~= nil then
        self.prefs.dark = nil
        self.store:saveSetting("prefs", self.prefs)
    end
    self.api = Api.new{
        settings = {
            get = function(key) return self.store:readSetting(key) end,
            set = function(key, value)
                if value == nil then self.store:delSetting(key) else self.store:saveSetting(key, value) end
            end,
            save = function() self.store:flush() end,
        },
        request = httpRequest,
        json = require("json"),
    }
    self.pictures = {}
    self.loading = {}   -- camera pictures being fetched: id -> true
    self.jobs = {}      -- work in child processes: pid -> job
    self:loadCache()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    HomeAssistant.instance = self
    self:hookSleepScreen()
    self:hookSleepAlerts()
    self:shareWithApps()
    -- A tap on one of its notifications in the shared list (Apps).
    local PS = require("pluginshare")
    PS.notifyOpeners = PS.notifyOpeners or {}
    PS.notifyOpeners.homeassistant = function(route)
        local ha = HomeAssistant.instance
        if not ha then return end
        if ha.screen then ha.screen:go(route or { kind = "notifications" }) else ha:show(route or { kind = "notifications" }) end
    end
end

function HomeAssistant:onDispatcherRegisterActions()
    Dispatcher:registerAction("homeassistant_show", { category = "none", event = "ShowHomeAssistant", title = _("Home Assistant"), general = true })
    Dispatcher:registerAction("homeassistant_dashboard", { category = "none", event = "ShowHomeAssistantDashboard", title = _("Home Assistant dashboard"), general = true })
end

function HomeAssistant:addToMainMenu(menu_items)
    menu_items.homeassistant = {
        text = _("Home Assistant"),
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

--- Signing in: with a user name and password, or a long-lived token.
function HomeAssistant:askSignIn(done)
    require("hako").list(_("Connect to Home Assistant"), {
        { text = _("Sign in with username and password"), fn = function() Settings.signIn(self, done) end },
        { text = _("Use a long-lived token"), fn = function() Settings.useToken(self, done) end },
    })
end

--- Home Assistant's settings: on its open screen (brought back over Apps), or opened there.
function HomeAssistant:openSettings(jump)
    self.settingsJump = jump
    if self.screen and UIManager:isWidgetShown(self.screen) then
        local stack = UIManager._window_stack or {}
        local over = {}
        for i = #stack, 1, -1 do
            if stack[i].widget == self.screen then break end
            table.insert(over, stack[i].widget)
        end
        for __, w in ipairs(over) do UIManager:close(w) end
        if self.screen.route.kind ~= "settings" then self.screen:go({ kind = "settings" }) else self.screen:refresh("full") end
        return
    end
    if not self.api:signedIn() then return self:askSignIn(function() self:openSettings() end) end
    self:show({ kind = "settings" })
end

--- What the apps share (Apps' PluginShare): this app's settings in the list of
-- every app's, its devices in Search and as quick buttons, its step in Set up your Kindle.
function HomeAssistant:shareWithApps()
    local PS = require("pluginshare")
    if PS.registerTest then
        -- Test connection (appstest.lua): each address on its own, at home and away.
        local KINDS = {
            notsignedin = _("Reaches Home Assistant (not signed in yet)"),
            signin = _("Reaches Home Assistant, but the sign-in didn't work. Sign in again."),
            notapi = _("Answers, but not as Home Assistant (a proxy's sign-in page?)"),
        }
        PS.registerTest{ key = "homeassistant", name = _("Home Assistant"),
            configured = function() return self.api:get("home_url") ~= nil or self.api:get("away_url") ~= nil end,
            run = function(Test)
            local out = {}
            for __, r in ipairs(self.api:testAddresses(require("socket").gettime)) do
                table.insert(out, { name = r.which == "home" and _("Internal URL") or _("External URL"), detail = r.detail,
                    ok = r.ok, ms = r.ms, raw = r.err, why = KINDS[r.kind] or (r.kind == "unreachable" and Test.why(r.err)) or r.err })
            end
            return out
        end }
    end
    if PS.registerQuick then
        -- A device as one of the launcher's quick buttons (appsquick.lua), by room.
        PS.registerQuick{ key = "homeassistant", name = _("Home Assistant devices"),
            choices = function()
                local ha = HomeAssistant.instance
                local out = {}
                if not ha then return out end
                -- Refresh: the states again now (hold: Home Assistant).
                table.insert(out, { id = "refresh", name = _("Refresh Home Assistant"), icon = "refresh-cw", group = _("Home Assistant") })
                if not ha.snap then return out end
                for __, e in ipairs(ha.snap.list) do
                    if HomeAssistant.QUICK[e.domain] and not e.onMainDevice and Model.visible(e, ha.prefs) then
                        table.insert(out, { id = e.id, name = e.name, icon = Model.icon(e), group = e.area ~= "" and e.area or _("No room") })
                    end
                end
                table.sort(out, function(a, b)
                    if a.group ~= b.group then return a.group < b.group end
                    return a.name:lower() < b.name:lower()
                end)
                return out
            end,
            item = function(id)
                local ha = HomeAssistant.instance
                return ha and ha:quickItem(id)
            end }
    end
    if PS.registerSettings then
        PS.registerSettings{ key = "homeassistant", name = _("Home Assistant"), icon = "house",
            open = function(jump) local ha = HomeAssistant.instance if ha then ha:openSettings(jump) end end,
            rows = function()
                local ha = HomeAssistant.instance
                return ha and require("hasettings").searchRows(ha) or {}
            end }
    end
    if PS.registerSearch then
        PS.registerSearch{ key = "homeassistant", name = _("Home Assistant"), icon = "house", search = function(q)
            local ha = HomeAssistant.instance
            local out = {}
            if not (ha and ha.snap) then return out end
            for __, e in ipairs(ha.snap.list) do
                if #out >= 20 then break end
                if Model.visible(e, ha.prefs) and ((e.name or ""):lower():find(q, 1, true) or (e.area or ""):lower():find(q, 1, true)) then
                    table.insert(out, { title = e.name, sub = (e.area ~= "" and (e.area .. "  \u{00B7}  ") or "") .. Model.stateText(e),
                        open = function()
                            local h = HomeAssistant.instance
                            if not h then return end
                            local route = e.area ~= "" and { kind = "room", name = e.area } or { kind = "search", query = e.name }
                            if h.screen then h.screen:go(route) else h:show(route) end
                        end })
                end
            end
            return out
        end }
    end
    if PS.registerSetup then
        PS.registerSetup{ key = "homeassistant", order = 20, icon = "house", title = _("Home Assistant"),
            text = _("Your lights, locks, cameras and the rest on the Kindle. Sign in with your Home Assistant user name and password (two-factor codes work), or a long-lived token."),
            done = function() local ha = HomeAssistant.instance return ha ~= nil and ha.api:signedIn() end,
            doneText = _("Signed in"), action = _("Sign in"),
            skipped = _("The other apps work without it. The Dashboard tile stays hidden, and the weather can come from Open-Meteo instead."),
            help = { button = _("What you need"), title = _("Connecting Home Assistant"),
                steps = {
                    _("Internal URL: your Home Assistant's address on your home Wi-Fi, such as http://homeassistant.local:8123 (or its IP address with :8123)."),
                    _("External URL (optional): an address that works from anywhere, such as Home Assistant Cloud's."),
                    _("Tap Sign in, enter the URLs, then your Home Assistant user name and password (two-factor codes work)."),
                    _("Or use a long-lived token: in Home Assistant, your profile > Security > Long-lived access tokens > Create token."),
                },
                after = _("Nothing changes in Home Assistant. The Kindle only reads it and does what you tap."),
                guide = "setup.md#home-assistant" },
            run = function() local ha = HomeAssistant.instance if ha then ha:askSignIn(function() end) end end }
    end
end

function HomeAssistant:onShowHomeAssistant() self:show("home") return true end
function HomeAssistant:onShowHomeAssistantDashboard() self:show("dashboard") return true end

function HomeAssistant:savePrefs()
    self.store:saveSetting("prefs", self.prefs)
    self.store:flush()
end

-- ------------------------------------------------------------------ the last states

function HomeAssistant:loadCache()
    local f = io.open(CACHE, "r")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    local ok, data = pcall(require("json").decode, raw)
    if ok and type(data) == "table" and data.v == 1 then
        self.snap = Model.parse(data)
        self.updatedAt = self.snap and self.snap.now
    end
end

function HomeAssistant:saveCache(raw)
    local f = io.open(CACHE .. ".tmp", "w")
    if not f then return end
    f:write(raw)
    f:close()
    os.rename(CACHE .. ".tmp", CACHE)
end

-- ------------------------------------------------------------------ opening

--- Opens Home, the dashboard, or any screen ({ kind = "security" },
-- { kind = "room", name = "Kitchen" }...: Back from it closes).
function HomeAssistant:show(start)
    if self.screen then return end
    if not self.api:signedIn() then return self:askSignIn(function() self:show(start) end) end
    local PS = require("pluginshare")
    if PS.noteRecent then PS.noteRecent(start == "dashboard" and "dashboard" or "ha") end
    -- Not self.view: inside a book KOReader gives every plugin its ReaderView there.
    self.screen = View:new{ ha = self, start = start or self.prefs.start or "home" }
    require("hako").showFull(self.screen)
    self.screen:onRouteChanged()
    if online() then
        UIManager:nextTick(function() self:update() end)
    elseif not self.snap then
        self:update()
    end
end

function HomeAssistant:viewClosed()
    self.screen = nil
    if self.doorTask then UIManager:unschedule(self.doorTask) end
    self.doorTask = nil
    self.doorGen = (self.doorGen or 0) + 1
    self:cancelJobs("picture")
    if self.tick then UIManager:unschedule(self.tick) end
    self.tick = nil
    stayAwake("homeassistant", false)
    for __, pic in pairs(self.pictures) do
        if pic.bb then pic.bb:free() end
    end
    self.pictures = {}
end

-- ------------------------------------------------------------------ network

--- fn runs once online (KOReader asks to turn Wi-Fi on when it is off), with `text` up meanwhile.
function HomeAssistant:online(text, fn)
    NetworkMgr:runWhenOnline(function()
        local info = text and require("hako").wait(text)
        if info then UIManager:forceRePaint() end
        UIManager:nextTick(function()
            local ok, err = pcall(fn)
            if info then info:close() end
            if not ok then
                logger.err("Home Assistant:", err)
                self:failed(tostring(err))
            end
        end)
    end)
end

function HomeAssistant:failed(why)
    require("hako").message(why or Api.ERRORS.failed)
end

function HomeAssistant:signedIn(done)
    require("hako").toast(_("Connected to Home Assistant"))
    self.error = nil
    if done then done() end
    if self.screen then self:update() end
end

function HomeAssistant:signOut()
    self.api:signOut()
    self.snap = nil
    os.remove(CACHE)
    -- Its notifications leave the shared list too.
    self.notifications = {}
    self:shareNotifications()
    if self.screen then self.screen:close() end
end

-- ------------------------------------------------------------------ work in the background

-- (Nothing to do here now: a token that ran out is made fresh in the child,
-- which sends it back; see background.)
function HomeAssistant:prepare() end

-- What a child may change in the sign-in settings (kept here once it ends).
local CHILD_KEYS = { "access_token", "expires_at", "active" }

--- job() runs in a child process (so the screen keeps answering taps while
-- Home Assistant takes its time) and returns a string, or errors with
-- { kind, message }; then done(result) or done(nil, err) runs here. A child
-- that hasn't answered in 90 s is stopped (done(nil, unreachable)).
function HomeAssistant:background(kind, job, done)
    local api = self.api
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        -- The child saves nothing itself; what it changed comes back first.
        api.settings.save = function() end
        local before = {}
        for __, k in ipairs(CHILD_KEYS) do before[k] = api:get(k) end
        local ok, result = pcall(job)
        local out
        if ok and type(result) == "string" then
            out = "K" .. result
        elseif type(result) == "table" then
            out = "E" .. tostring(result.kind or "failed") .. "\t" .. tostring(result.message or "")
        else
            out = "Efailed\t" .. tostring(result)
        end
        local changed = {}
        for __, k in ipairs(CHILD_KEYS) do
            if api:get(k) ~= before[k] then changed[k] = api:get(k) end
        end
        if next(changed) then out = "S" .. require("json").encode(changed) .. "\n" .. out end
        ffiutil.writeToFD(write_fd, out, true)
    end, true)
    if not pid then return done(nil, { kind = "failed", message = tostring(fd) }) end
    local entry = { pid = pid, fd = fd, kind = kind }
    self.jobs[pid] = entry
    local deadline = os.time() + 90
    local function check()
        if entry.cancelled then return end
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = not (size and size > 0) and ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited and os.time() > deadline then
            -- Stuck (a lookup that never answers): stopped, so updates go on.
            logger.warn("Home Assistant: stopped a", kind, "job that took too long")
            entry.cancelled = true
            self.jobs[pid] = nil
            ffiutil.terminateSubProcess(pid)
            self:reap(pid)
            return done(nil, { kind = "unreachable", message = Api.ERRORS.unreachable })
        end
        if (size and size > 0) or exited then
            local out = ffiutil.readAllFromFD(fd) or ""
            self.jobs[pid] = nil
            if not exited then self:reap(pid) end
            if out:sub(1, 1) == "S" then
                local head, rest = out:match("^S([^\n]*)\n(.*)$")
                local okj, changed = pcall(require("json").decode, head or "")
                if okj and type(changed) == "table" then
                    for k, v in pairs(changed) do api:set(k, v) end
                    api.settings.save()
                end
                out = rest or ""
            end
            if out:sub(1, 1) == "K" then return done(out:sub(2)) end
            local errKind, message = out:sub(2):match("^([^\t]*)\t?(.*)$")
            errKind = errKind ~= "" and errKind or "failed"
            return done(nil, { kind = errKind, message = message ~= "" and message or Api.ERRORS[errKind] or Api.ERRORS.failed })
        end
        UIManager:scheduleIn(0.15, check)
    end
    UIManager:scheduleIn(0.1, check)
end

-- A finished child collected (so it does not linger).
function HomeAssistant:reap(pid)
    if ffiutil.isSubProcessDone(pid) then return end
    UIManager:scheduleIn(0.5, function() self:reap(pid) end)
end

--- Work of a kind ("picture") stopped (leaving a screen).
function HomeAssistant:cancelJobs(kind)
    for pid, entry in pairs(self.jobs) do
        if not kind or entry.kind == kind then
            entry.cancelled = true
            self.jobs[pid] = nil
            ffiutil.terminateSubProcess(pid)
            local function collect()
                if ffiutil.isSubProcessDone(pid) then
                    ffiutil.readAllFromFD(entry.fd)
                else
                    UIManager:scheduleIn(0.3, collect)
                end
            end
            UIManager:scheduleIn(0.1, collect)
        end
    end
    if not kind or kind == "picture" then self.loading = {} end
end

-- ------------------------------------------------------------------ states

--- New states from Home Assistant (in the background). Quiet (a timer) only
-- runs when already online and says nothing when it fails.
function HomeAssistant:update(quiet)
    if self.busy then return end
    if quiet and not online() then
        -- Offline now: try again at the next tick.
        self:schedule()
        return
    end
    local function fetch()
        self.busy = true
        if self.screen then self.screen:refresh("fast") end
        self:prepare()
        local api = self.api
        local template = Template.all(self.prefs.weather)
        self:background("states", function()
            local data, err, raw = api:sendJson("POST", "/api/template", { template = template })
            if not data then error(err) end
            return raw
        end, function(raw, err)
            self.busy = false
            local snap
            if raw then
                local ok, data = pcall(require("json").decode, raw)
                snap = ok and Model.parse(data)
                if not snap then err = { kind = "failed", message = Api.ERRORS.failed } end
            end
            if snap then
                self.snap, self.error, self.updateFailed = snap, nil, false
                self.updatedAt = os.time()
                self:saveCache(raw)
                if self.screen and self.screen.route.kind == "dashboard" then
                    self:dashboardExtras()
                    if not self.doorTask then self:watchDoorbell() end
                end
                self:loadNotifications()
            else
                self.error = err.message
                self.updateFailed = true
                if err.kind == "signin" or not quiet then self:failed(err.message) end
            end
            if self.screen then self.screen:updated() end
            if self.wakeCheck then
                self.wakeCheck = nil
                if snap then self:wakeWarning() end
            end
            self:schedule()
        end)
    end
    if quiet then fetch() else NetworkMgr:runWhenOnline(fetch) end
end

-- ------------------------------------------------------------------ waking

--- The Kindle woke: once online, an update; a lock left open, the garage
-- or a door open is then said (Settings: Warn when the Kindle wakes).
function HomeAssistant:onResume()
    if self.prefs.wake_warning == false or not self.api:signedIn() then return end
    self.wakeCheck = true
    local tries = 0
    local function try()
        if not self.wakeCheck then return end
        tries = tries + 1
        if online() then
            if not self.busy then self:update(true) end
        elseif tries < 20 then
            UIManager:scheduleIn(3, try)
        else
            self.wakeCheck = nil
        end
    end
    UIManager:scheduleIn(2, try)
end

function HomeAssistant:wakeWarning()
    local issues = Model.wakeIssues(self.snap, self.prefs)
    if #issues == 0 then return end
    require("hako").confirm{ text = _("Home Assistant") .. "\n\n" .. table.concat(issues, "\n"), ok = _("Security"), cancel = _("Close"), onOk = function() self:show({ kind = "security" }) end }
end

-- ------------------------------------------------------------------ the doorbell

--- While the dashboard shows: the doorbells' ring (and motion) sensors,
-- every few seconds; one that turns on shows its camera (Settings > Dashboard
-- > Doorbell pop-up).
function HomeAssistant:watchDoorbell()
    if self.doorTask then UIManager:unschedule(self.doorTask) end
    self.doorTask = nil
    -- One chain at a time: a newer watch ends this one (even mid-poll).
    self.doorGen = (self.doorGen or 0) + 1
    local gen = self.doorGen
    local mode = self.prefs.doorbell or "motion"
    if mode == "off" or not (self.screen and self.screen.route.kind == "dashboard" and self.snap) then return end
    local triggers = Model.doorbells(self.snap)
    local ids = {}
    for id, t in pairs(triggers) do
        if mode == "motion" or t.kind == "ring" then table.insert(ids, id) end
    end
    if #ids == 0 then return end
    table.sort(ids)
    self.doorSeen = self.doorSeen or {}
    local function again()
        if self.doorGen ~= gen then return end
        self.doorTask = function() self:pollDoorbell(ids, triggers, again) end
        UIManager:scheduleIn(5, self.doorTask)
    end
    again()
end

function HomeAssistant:pollDoorbell(ids, triggers, again)
    self.doorTask = nil
    if not (self.screen and self.screen.route.kind == "dashboard") then return end
    if UIManager:getTopmostVisibleWidget() ~= self.screen or not online() then return again() end
    self:prepare()
    local api = self.api
    self:background("doorbell", function()
        local data, err, raw = api:sendJson("POST", "/api/template", { template = Template.states(ids) }, 8)
        if not data then error(err) end
        return raw
    end, function(raw, err)
        local ok, list = pcall(require("json").decode, raw or "")
        if ok and type(list) == "table" then
            for i, id in ipairs(ids) do
                local state, changed = list[i] and list[i][1], list[i] and list[i][2]
                local before = self.doorSeen[id]
                self.doorSeen[id] = changed
                -- (the first look only notes the time: something on already is not news)
                if state == "on" and before and changed ~= before and self.screen then
                    self.screen:doorbell(triggers[id].camera)
                    return
                end
            end
        end
        if self.screen and self.screen.route.kind == "dashboard" then again() end
    end)
end

-- ------------------------------------------------------------------ history

--- A sensor's last day, hour by hour (Model.hourly), into self.histories[id]
-- (asked again after ten minutes); done() when it came.
function HomeAssistant:loadHistory(id, done)
    self.histories = self.histories or {}
    local h = self.histories[id]
    if h and (h.loading or os.time() - h.at < 600) then return end
    if not online() then return end
    self.histories[id] = { at = h and h.at or 0, hourly = h and h.hourly, loading = true }
    self:prepare()
    local api, now = self.api, os.time()
    self:background("history", function()
        local status, body = api:send("GET", Api.historyPath(id, now), nil, nil, 20)
        if status ~= 200 then error(type(body) == "table" and body or { kind = "failed" }) end
        return body
    end, function(raw)
        local entry = self.histories[id]
        entry.loading, entry.at = nil, os.time()
        local ok, data = pcall(require("json").decode, raw or "")
        if ok and type(data) == "table" then entry.hourly = Model.hourly(data[1], now, 24) end
        if done then done() end
    end)
end

--- Home Assistant's notifications, every two minutes at most (after an
-- update; `force` now). Nil until known: a proxy may not pass the WebSocket.
function HomeAssistant:loadNotifications(force)
    if not force and self.notificationsAt and os.time() - self.notificationsAt < 120 then return end
    self.notificationsAt = os.time()
    local api, json = self.api, require("json")
    self:background("notifications", function()
        local list, err = api:notifications()
        if not list then error(err) end
        return json.encode(list)
    end, function(raw)
        local ok, list = pcall(json.decode, raw or "")
        if ok and type(list) == "table" then
            self.notifications = list
            self:shareNotifications()
            if self.screen then self.screen:refresh("ui") end
        end
    end)
end

--- Home Assistant's notifications in the list every app shares (Apps' 🔔):
-- each new one added once, those dismissed taken out.
function HomeAssistant:shareNotifications()
    local PS = require("pluginshare")
    if not PS.notify then return end
    local sent = self.store:readSetting("shared_notifications") or {}
    local now, keep = {}, {}
    for __, n in ipairs(self.notifications or {}) do
        local id = tostring(n.id)
        now[id] = true
        keep[id] = true
        if not sent[id] then
            local title = Model.plain(n.title or "")
            local text = Model.plain(n.message or "")
            PS.notify{
                app = "homeassistant",
                text = title ~= "" and (title .. ": " .. text) or text,
                time = Model.isoTime(n.created),
                key = "homeassistant:" .. id,
                route = { kind = "notifications" },
            }
        end
    end
    for id in pairs(sent) do
        if not now[id] then PS.unnotify("homeassistant:" .. id) end
    end
    self.store:saveSetting("shared_notifications", keep)
    self.store:flush()
end

--- Dismisses one notification (or all: id nil), then shows the rest.
function HomeAssistant:dismiss(id)
    local list = self.notifications or {}
    local gone = {}
    for __, n in ipairs(list) do
        if id == nil or n.id == id then table.insert(gone, n.id) end
    end
    local keep = {}
    for __, n in ipairs(list) do
        local isGone = false
        for __, g in ipairs(gone) do if g == n.id then isGone = true end end
        if not isGone then table.insert(keep, n) end
    end
    self.notifications = keep
    self:shareNotifications()
    if self.screen then self.screen:refresh("ui") end
    for __, nid in ipairs(gone) do
        self:send("persistent_notification.dismiss", { notification_id = nid }, function(ok, err)
            if not ok then self:failed(err.message) self:loadNotifications(true) end
        end)
    end
end

-- The daily forecast (every half hour), for the dashboard and the weather
-- screen; with hourly, the next hours too (for the weather screen).
function HomeAssistant:loadForecast(hourly)
    local w = self.snap and self.snap.weather
    if hourly and w and w.id and (not self.hourlyAt or os.time() - self.hourlyAt > 1800) then
        self.hourlyAt = os.time()
        local api, json = self.api, require("json")
        self:background("hourly", function()
            return json.encode(api:forecast(w.id, "hourly") or {})
        end, function(raw)
            local ok, list = pcall(json.decode, raw or "")
            if ok and type(list) == "table" and #list > 0 then
                self.hourly = list
                if self.screen and self.screen.route.kind == "weather" then self.screen:refresh("ui") end
            end
        end)
    end
    if w and w.id and (not self.forecastAt or os.time() - self.forecastAt > 1800) then
        self.forecastAt = os.time()
        local api, json = self.api, require("json")
        self:background("forecast", function()
            return json.encode(api:forecast(w.id) or {})
        end, function(raw)
            local ok, list = pcall(json.decode, raw or "")
            if ok and type(list) == "table" and #list > 0 then
                self.forecast = list
                local kind = self.screen and self.screen.route.kind
                if kind == "dashboard" or kind == "weather" then self.screen:refresh("ui") end
            end
        end)
    end
end

-- On the dashboard: the forecast and the next camera.
function HomeAssistant:dashboardExtras()
    self:loadForecast()
    if (self.prefs.dash_camera or "cycle") == "cycle" then
        self.dashCamera = (self.dashCamera or 0) + 1
    end
    -- Pictures on the dashboard are taken again at each update.
    for __, pic in pairs(self.pictures) do
        if pic.bb then pic.stale = true end
    end
end

function HomeAssistant:schedule()
    if self.tick then UIManager:unschedule(self.tick) end
    self.tick = nil
    if not self.screen then return end
    local dash = self.screen.route.kind == "dashboard"
    local minutes = dash and (self.prefs.dash_minutes or 5) or (self.prefs.refresh_minutes or 1)
    if minutes <= 0 then return end
    self.tick = function()
        self.tick = nil
        if self.screen and UIManager:getTopmostVisibleWidget() == self.screen then
            self:update(true)
        else
            self:schedule()
        end
    end
    UIManager:scheduleIn(minutes * 60, self.tick)
end

function HomeAssistant:screenChanged(kind)
    self:schedule()
    self:watchDoorbell()
    self:keepAwake()
    if kind == "weather" and self.snap and online() then
        UIManager:nextTick(function() self:loadForecast(true) end)
    end
    if kind == "dashboard" and self.prefs.auto_light then self:followRoomLight(true) end
    if kind == "dashboard" and self.snap and online() then
        UIManager:nextTick(function()
            self:dashboardExtras()
            if self.screen then self.screen:refresh("ui") end
        end)
    end
end

--- The dashboard holds off KOReader's auto-sleep (while charging, by default).
function HomeAssistant:onCharging() self:keepAwake() end
function HomeAssistant:onNotCharging() self:keepAwake() end

function HomeAssistant:keepAwake()
    local mode = self.prefs.dash_awake or "charging"
    local want = self.screen and self.screen.route.kind == "dashboard" and
        (mode == "always" or (mode == "charging" and Device:getPowerDevice():isCharging()))
    stayAwake("homeassistant", want)
end

function HomeAssistant:statusText()
    if self.busy then return _("Updating…") end
    if self.updateFailed then return _("Update failed") end
    if not self.updatedAt then return "" end
    return T(_("Updated %1"), Model.ago(os.time() - self.updatedAt))
end

function HomeAssistant:awakeText()
    local mode = self.prefs.dash_awake or "charging"
    local text = mode == "always" and _("Screen always on") or mode == "never" and _("Normal sleep") or _("Screen on while charging")
    return text .. "  ·  " .. _("Tap to exit")
end

-- ------------------------------------------------------------------ quick buttons

-- The kinds of device a quick button can be.
HomeAssistant.QUICK = { light = true, switch = true, fan = true, climate = true, media_player = true, cover = true,
    lock = true, scene = true, script = true, button = true, input_boolean = true, sensor = true, binary_sensor = true }

--- Opens a device's controls (its sheet), from anywhere.
function HomeAssistant:openDevice(id)
    local e = self.snap and self.snap.byId[id]
    local route = e and e.area ~= "" and { kind = "room", name = e.area } or "home"
    if self.screen then self.screen:go(type(route) == "table" and route or { kind = "home" }) else self:show(route) end
    UIManager:nextTick(function()
        local x = self.snap and self.snap.byId[id]
        if self.screen and x then self.screen:openSheet(x) end
    end)
end

--- A device as a quick button: { label, icon, on, value, tap(done), hold,
-- steps, media, chip } (appsquick.lua draws it), or nil when it isn't known
-- yet (the states are loaded then, quietly).
function HomeAssistant:quickItem(id)
    if id == "refresh" then
        return { label = _("Refresh Home Assistant"), icon = "refresh-cw", value = self.busy and _("Updating…") or nil,
            tap = function(done)
                self:update()
                if done then UIManager:scheduleIn(4, function() done() end) end
            end,
            hold = function() self:show() end }
    end
    local e = self.snap and self.snap.byId[id]
    if not e then
        if not self.snap and not self.busy and online() then self:update(true) end
        return nil
    end
    local d, a = e.domain, e.attr
    local item = { label = e.name, icon = Model.icon(e), hold = function() self:openDevice(id) end }
    -- Done: the button now; Home Assistant's own state a moment later.
    local function after(done)
        if done then done() end
        UIManager:scheduleIn(2, function() if not self.busy then self:update(true) end end)
        if done then UIManager:scheduleIn(4, function() done() end) end
    end
    local function act(service, data, done)
        data = data or {}
        data.entity_id = id
        self:act(e, service, data)
        after(done)
    end
    if e.state == "unavailable" then
        item.value, item.tap = _("Unavailable"), item.hold
        return item
    end
    if d == "sensor" or d == "binary_sensor" then
        -- A reading: no tap; hold for its device and history.
        item.chip, item.value = true, Model.stateText(e)
        return item
    end
    if d == "light" then
        item.on = Model.isOn(e)
        if Model.dimmable(e) then
            item.value = item.on and ((Model.brightnessPercent(e) or 100) .. "%") or nil
            item.steps = {
                minus = function(done) act("light.turn_on", { brightness_step_pct = -10 }, done) end,
                plus = function(done) act("light.turn_on", { brightness_step_pct = 10 }, done) end,
            }
        end
    elseif d == "fan" then
        item.on = Model.isOn(e)
        local pct = Model.num(a.percentage)
        if pct or Model.num(a.percentage_step) then
            item.value = item.on and pct and (math.floor(pct + 0.5) .. "%") or nil
            item.steps = {
                minus = function(done) act("fan.decrease_speed", nil, done) end,
                plus = function(done) act("fan.increase_speed", nil, done) end,
            }
        end
    elseif d == "climate" then
        -- The set point, − and +; a tap opens its controls (mode, fan).
        local t = Model.num(a.temperature)
        item.on = e.state ~= "off"
        item.value = t and Model.formatTemp(t) or Model.stateText(e)
        if t then
            local step = Model.tempStep(e, self.snap.weather and self.snap.weather.unit)
            local function set(dir, done)
                local v = (Model.num(a.temperature) or t) + dir * step
                local lo, hi = Model.num(a.min_temp), Model.num(a.max_temp)
                if lo and v < lo then v = lo end
                if hi and v > hi then v = hi end
                a.temperature = v
                act("climate.set_temperature", { temperature = v }, done)
            end
            item.steps = { minus = function(done) set(-1, done) end, plus = function(done) set(1, done) end }
        end
        item.tap = item.hold
        return item
    elseif d == "media_player" then
        -- ⏮ ⏯ ⏭, mute and the volume; a tap opens its controls (sources).
        local vol = Model.num(a.volume_level)
        item.on = e.state == "playing"
        item.value = vol and (math.floor(vol * 100 + 0.5) .. "%") or nil
        item.media = {
            playing = e.state == "playing", muted = a.is_volume_muted == true,
            prev = function(done) act("media_player.media_previous_track", nil, done) end,
            play = function(done) act("media_player.media_play_pause", nil, done) end,
            next = function(done) act("media_player.media_next_track", nil, done) end,
            mute = function(done) act("media_player.volume_mute", { is_volume_muted = not (a.is_volume_muted == true) }, done) end,
            minus = function(done) act("media_player.volume_down", nil, done) end,
            plus = function(done) act("media_player.volume_up", nil, done) end,
        }
        item.tap = item.hold
        return item
    else
        item.on = Model.isOn(e)
    end
    -- A tap: as Home Assistant's own tiles (asked first for locks, the garage, scripts).
    item.tap = function(done)
        local action = Model.tapAction(e, self.prefs)
        if action.sheet or not action.service then return self:openDevice(id) end
        local function run()
            self:act(e, action.service, action.data)
            after(done)
        end
        if action.confirm then
            require("hako").confirm{ title = action.confirm, text = T(_("Currently: %1"), Model.stateText(e)),
                ok = action.service:match("unlock") and _("Unlock") or action.service:match("open") and _("Open")
                    or action.service:match("close") and _("Close") or _("Run"), onOk = run }
        else
            run()
        end
    end
    return item
end

-- ------------------------------------------------------------------ acting

--- A service for an entity: its new state shown at once, the real one after.
function HomeAssistant:act(e, service, data)
    local old = e.state
    local wasOn = Model.isOn(e)
    e.state = Model.expected(e, service)
    self:noteTurnedOff(e, wasOn)
    if self.screen then
        self.screen:refresh("fast")
        -- From a sheet: once the real state is back, a full refresh.
        if self.screen.sheet then self.screen:settle(4) end
    end
    self:send(service, data, function(ok, err)
        if not ok then
            e.state = old
            if self.screen then self.screen:refresh("ui") end
            return self:failed(err.message)
        end
        local slow = e.domain == "lock" or e.domain == "cover" or e.domain == "vacuum" or e.domain == "climate"
        UIManager:scheduleIn(slow and 4 or 1.5, function() if self.screen then self:update(true) end end)
    end)
end

--- Everything in `list` off at once.
function HomeAssistant:allOff(list)
    local ids = {}
    for __, e in ipairs(list) do
        table.insert(ids, e.id)
        local wasOn = Model.isOn(e)
        e.state = "off"
        self:noteTurnedOff(e, wasOn)
    end
    if self.screen then self.screen:refresh("fast") end
    self:send("homeassistant.turn_off", { entity_id = ids }, function(ok, err)
        if not ok then self:failed(err.message) end
        UIManager:scheduleIn(1.5, function() if self.screen then self:update(true) end end)
    end)
end

--- How long a device turned off here stays in On now (shown as off, a tap
-- away from on again), in minutes; 0: not at all (Settings).
function HomeAssistant:keepOffMinutes()
    local m = self.prefs.keep_off
    if m == nil then return 3 end
    return tonumber(m) or 0
end

function HomeAssistant:noteTurnedOff(e, wasOn)
    if wasOn and not Model.isOn(e) and self:keepOffMinutes() > 0 then
        turnedOff[e.id] = os.time()
        self:scheduleKeptOff()
    elseif Model.isOn(e) then
        turnedOff[e.id] = nil
    end
end

--- The devices turned off here a moment ago: { [id] = true }.
function HomeAssistant:keptOff()
    local out, now, keep = {}, os.time(), self:keepOffMinutes() * 60
    for id, at in pairs(turnedOff) do
        if keep > 0 and now - at < keep then out[id] = true else turnedOff[id] = nil end
    end
    return out
end

--- When the first of them is due to leave On now: Home drawn again then.
function HomeAssistant:scheduleKeptOff()
    if self.keptOffTask then UIManager:unschedule(self.keptOffTask) end
    local soonest
    local keep = self:keepOffMinutes() * 60
    for __, at in pairs(turnedOff) do
        local left = at + keep - os.time()
        if not soonest or left < soonest then soonest = left end
    end
    if not soonest then return end
    self.keptOffTask = function()
        self.keptOffTask = nil
        self:keptOff()
        if self.screen and self.screen.route.kind == "home" and UIManager:getTopmostVisibleWidget() == self.screen then
            self.screen:refresh("ui")
        end
        self:scheduleKeptOff()
    end
    UIManager:scheduleIn(math.max(1, soonest + 1), self.keptOffTask)
end

-- A service call in the background: done(true) or done(false, err).
function HomeAssistant:send(service, data, done)
    NetworkMgr:runWhenOnline(function()
        self:prepare()
        local api = self.api
        self:background("service", function()
            local ok, err = api:call(service, data)
            if not ok then error(err) end
            return "ok"
        end, function(result, err) done(result ~= nil, err) end)
    end)
end

-- ------------------------------------------------------------------ pictures

--- A camera's picture, w x h pixels (cropped to fill), into self.pictures[id]
-- (fetched in the background); then done().
function HomeAssistant:picture(id, w, h, done, fresh)
    local old = self.pictures[id]
    if old and old.bb and old.w == w and old.h == h and not fresh and not old.stale then return done() end
    -- Failed a moment ago: not again for a few minutes (a tap asks at once).
    if old and old.failedAt and not fresh and os.time() - old.failedAt < 180 then return end
    if self.loading[id] then return end
    if not online() then
        if fresh then NetworkMgr:runWhenOnline(function() self:picture(id, w, h, done, fresh) end) end
        return
    end
    self.loading[id] = true
    self:prepare()
    local api = self.api
    self:background("picture", function()
        local data, err = api:camera(id, w)
        if not data then error(err) end
        return data
    end, function(data)
        self.loading[id] = nil
        local bb = data and RenderImage:renderImageData(data, #data, false)
        if not bb then
            if old and old.bb then
                old.stale, old.failedAt = nil, os.time()
            else
                self.pictures[id] = { failed = true, w = w, h = h, failedAt = os.time() }
            end
            return done()
        end
        local bw, bh = bb:getWidth(), bb:getHeight()
        local scale = math.max(w / bw, h / bh)
        local sw, sh = math.max(w, math.ceil(bw * scale)), math.max(h, math.ceil(bh * scale))
        local scaled = RenderImage:scaleBlitBuffer(bb, sw, sh, true)
        local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        out:blitFrom(scaled, 0, 0, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
        scaled:free()
        old = self.pictures[id]
        if old and old.bb then old.bb:free() end
        self.pictures[id] = { bb = out, w = w, h = h, at = os.time() }
        done()
    end)
end

--- Notes, if it is installed and can take a picture.
function HomeAssistant:notes()
    local notes = self.ui and self.ui.notes
    return notes and notes.addImagePage and notes or nil
end

--- A camera's picture now, as a new page in a notebook (picked when there
-- are some), with the camera and the time above it.
function HomeAssistant:sendToNotes(e, title)
    local notes = self:notes()
    if not notes then return end
    local function send(notebook)
        if not online() then
            return NetworkMgr:runWhenOnline(function() send(notebook) end)
        end
        self:prepare()
        local api = self.api
        require("hako").toast(_("Sending to Notes…"))
        self:background("picture", function()
            local data, err = api:camera(e.id)
            if not data then error(err) end
            return data
        end, function(data, err)
            if not data then
                return require("hako").message(T(_("Couldn't get the picture: %1"), err and err.message or _("No image.")))
            end
            local ext = data:sub(1, 4) == "\137PNG" and ".png" or ".jpg"
            local path = DataStorage:getDataDir() .. "/cache/homeassistant-camera" .. ext
            local f = io.open(path, "wb")
            if not f then return require("hako").message(_("Couldn't save the picture.")) end
            f:write(data)
            f:close()
            local ok, where, why = pcall(notes.addImagePage, notes, path, { notebook = notebook, title = title })
            os.remove(path)
            if ok and where then
                require("hako").toast(T(_("Sent to Notes: %1"), where), 3)
            else
                require("hako").message(T(_("Couldn't send to Notes: %1"), tostring(ok and why or where)))
            end
        end)
    end
    local ok, choices = pcall(function() return notes.notebookChoices and notes:notebookChoices() end)
    if not ok or type(choices) ~= "table" or #choices == 0 then return send(nil) end
    local items = {}
    for i, nb in ipairs(choices) do
        if i > 8 then break end
        table.insert(items, { text = nb.name, fn = function() send(nb.id) end })
    end
    require("hako").list(_("Send to Notes"), items)
end

--- How many pictures are being fetched.
function HomeAssistant:pictureJobs()
    local n = 0
    for __ in pairs(self.loading) do n = n + 1 end
    return n
end

-- ------------------------------------------------------------------ sleep screen

-- One sleep screen setting for To Do, Home Assistant and Apps:
-- G_reader_settings "sleep_screen_app" ("homeassistant" here).
function HomeAssistant.sleepSupported()
    local Device = require("device")
    if Device.supportsScreensaver then return Device:supportsScreensaver() and true or false end
    return true
end

-- Sleep screen alerts: whatever the sleep screen (KOReader's own, To Do's,
-- Apps', this one), the chosen alerts that say something are drawn in a box
-- at its bottom, from what was last fetched (its time shown).
function HomeAssistant:hookSleepAlerts()
    if HomeAssistant.alertsHooked then return end
    HomeAssistant.alertsHooked = true
    local ScreenSaverWidget = require("ui/widget/screensaverwidget")
    local original = ScreenSaverWidget.paintTo
    ScreenSaverWidget.paintTo = function(widget, bb, x, y)
        original(widget, bb, x, y)
        local inst = HomeAssistant.instance
        if inst and inst.snap and inst.prefs.sleep_alerts then
            local ok, err = pcall(inst.paintSleepAlerts, inst, bb, x, y)
            if not ok then require("logger").warn("Home Assistant sleep alerts:", err) end
        end
    end
end

function HomeAssistant:paintSleepAlerts(bb, x, y)
    local lines = Model.sleepAlerts(self.snap, self.prefs)
    if #lines == 0 then return end
    local Screen = require("device").screen
    local c = Canvas.new(Screen:getWidth(), Screen:getHeight(), false)
    local shown = math.min(#lines, 6)
    local h = 44 + shown * 26
    local top = c.H - 24 - h
    c:box(20, top, c.W - 40, h, { r = 10, fill = Canvas.WHITE, border = Canvas.BLACK, bw = 2 })
    local when = self.snap.now and os.date(require("hako").twentyFour() and "%H:%M" or "%I:%M %p", self.snap.now):gsub("^0", "") or ""
    c:text(36, top + 28, _("HOME ASSISTANT"), 10, { bold = true })
    c:text(c.W - 36, top + 28, T(_("as of %1"), when), 10, { align = "end", color = Canvas.GREY })
    for i = 1, shown do
        local text = lines[i]
        if i == shown and #lines > shown then text = T(_("+%1 more"), #lines - shown + 1) end
        c:text(36, top + 30 + i * 26, text, 12.5, { maxw = c.W - 72 })
    end
    c:paint(bb, x, y)
end

-- KOReader's Screensaver:show, wrapped once: when Home Assistant is the sleep
-- screen, its summary is shown instead (as KOReader shows its own).
function HomeAssistant:hookSleepScreen()
    if HomeAssistant.sleepHooked then return end
    HomeAssistant.sleepHooked = true
    local Screensaver = require("ui/screensaver")
    local original = Screensaver.show
    Screensaver.show = function(saver, ...)
        local inst = HomeAssistant.instance
        if inst and G_reader_settings:readSetting("sleep_screen_app") == "homeassistant" and inst.snap then
            local ok, err = pcall(inst.showSleepScreen, inst, saver)
            if ok then return end
            require("logger").warn("Home Assistant sleep screen:", err)
            -- Turned upright for it: back as it was, for KOReader's own.
            local Dev = require("device")
            if Dev.orig_rotation_mode then
                Dev.screen:setRotationMode(Dev.orig_rotation_mode)
                Dev.orig_rotation_mode = nil
            end
        end
        return original(saver, ...)
    end
end

function HomeAssistant:showSleepScreen(saver)
    local bit = require("bit")
    local Device = require("device")
    local Screen = Device.screen
    local ScreenSaverWidget = require("ui/widget/screensaverwidget")
    local Widget = require("ui/widget/widget")
    Device.screen_saver_mode = true
    local rotation = Screen:getRotationMode()
    if bit.band(rotation, 1) == 1 then
        Device.orig_rotation_mode = rotation
        Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
    else
        Device.orig_rotation_mode = nil
    end
    local w, h = Screen:getWidth(), Screen:getHeight()
    local c
    local function draw()
        if c then c:release() end
        c = Canvas.new(w, h, false)
        View.drawSleep(self, c)
    end
    draw()
    local Paint = Widget:extend{}
    function Paint:getSize() return { w = w, h = h } end
    function Paint.paintTo(_, bb, x, y)
        bb:paintRect(x, y, w, h, c:background())
        c:paint(bb, x, y)
    end
    saver.screensaver_widget = ScreenSaverWidget:new{
        widget = Paint:new{},
        background = c:background(),
        covers_fullscreen = true,
    }
    saver.screensaver_widget.modal = true
    saver.screensaver_widget.dithered = true
    UIManager:show(saver.screensaver_widget, "full")
    -- Drawn again while asleep (Update while asleep): the time, and what was last fetched.
    local widget = saver.screensaver_widget
    require("hako").sleepUpdates(function()
        draw()
        UIManager:setDirty(widget, "full")
    end)
end

-- ------------------------------------------------------------------ the room's light

-- The front light at each of the light sensor's five levels (dark to
-- bright), in percent of its range.
local ROOM_LIGHT = { 3, 15, 35, 60, 85 }

--- The front light set by the room's light (the Scribe's light sensor), when
-- it changed (Settings > Dashboard > Light follows the room).
function HomeAssistant:followRoomLight(force)
    local Device = require("device")
    if not (Device.hasLightSensor and Device:hasLightSensor() and Device:hasFrontlight() and Device.ambientBrightnessLevel) then return end
    local ok, level = pcall(Device.ambientBrightnessLevel, Device)
    if not ok or type(level) ~= "number" then return end
    if level == self.roomLevel and not force then return end
    self.roomLevel = level
    local powerd = Device:getPowerDevice()
    local lo, hi = powerd.fl_min or 0, powerd.fl_max or 100
    local pct = ROOM_LIGHT[level + 1] or 50
    pcall(powerd.setIntensity, powerd, math.floor(lo + (hi - lo) * pct / 100 + 0.5))
end

return HomeAssistant
