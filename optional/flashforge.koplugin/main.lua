--[[--
FlashForge: a FlashForge 3D printer on the Kindle, straight over the Wi-Fi
(the printer's own LAN API, as the Home Assistant integration and
FlashForge's desktop app use it). The print and its progress, temperatures,
pause, resume and cancel, the light and the air filter, a picture from the
camera, the Material Station's slots, and starting one of the printer's
recent files (with material matching on the AD5X).

For the Adventurer 5M, 5M Pro, AD5X, Creator 5 and Creator 5 Pro, in
LAN-only mode. Nothing runs in the background: the printer is read while
the app is open, and when the launcher's tile or a quick button shows it.

Also: the launcher's tile line (appsLine, event ShowFlashForge), its
settings, search, setup step, quick buttons, connection test and backup,
gestures, and calls for the web page (webState, act).

@module koplugin.flashforge
]]

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local M = require("ffmodel")

-- Answers to the discovery broadcast come to this port (opened in the Kindle's firewall meanwhile).
local DISCOVERY_PORT = 18007

-- Kept while KOReader runs (each book and the library get a new plugin).
local state = {
    info = nil,        -- the printer as last read (ffmodel.info)
    raw = nil,         -- /detail as last read (for Details)
    time = 0,          -- when
    tried = 0,         -- when it was last asked (answered or not)
    why = nil,         -- why the last read failed (nil: it worked)
    product = nil,     -- /product (what it can control), once per run
    reading = false,
    waiting = {},
    files = nil,       -- the recent files as last read
    line = nil,        -- the launcher's line as last shown
    lastState = nil,   -- for "Print finished" and errors
}

local FlashForge = WidgetContainer:extend{
    name = "flashforge",
    is_doc_only = false,
}

-- The FlashForge plugin of the open library or book.
local function current()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    return ui and ui.flashforge
end
FlashForge.current = current

function FlashForge:init()
    self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/flashforge.lua")
    self.dir = DataStorage:getDataDir() .. "/cache/flashforge"
    if lfs.attributes(self.dir, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        lfs.mkdir(self.dir)
    end
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    require("ffko").flashOnUncover()
    require("ffui").plugin = self
    self:shareWithApps()
end

function FlashForge:onDispatcherRegisterActions()
    Dispatcher:registerAction("flashforge_show", { category = "none", event = "ShowFlashForge", title = _("FlashForge"), general = true })
    Dispatcher:registerAction("flashforge_light", { category = "none", event = "ToggleFlashForgeLight", title = _("FlashForge: light on or off"), general = true })
end

function FlashForge:addToMainMenu(menu_items)
    menu_items.flashforge = {
        text = _("FlashForge"),
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

function FlashForge:onShowFlashForge()
    self:show()
    return true
end

function FlashForge:onToggleFlashForgeLight()
    local i = state.info
    if not self:configured() then return true end
    self:act("light", { on = not (i and i.light) }, function(ok, why)
        if not ok then require("ffko").toast(self:whyText(why)) end
    end)
    return true
end

function FlashForge:show(page)
    return require("ffui").show(self, page)
end

-- ------------------------------------------------------------------ the printer's settings

--- { ip, serial, code, name, model } (fields nil until set).
function FlashForge:cfg()
    return { ip = self.store:readSetting("ip"), serial = self.store:readSetting("serial"),
        code = self.store:readSetting("code"), name = self.store:readSetting("name"), model = self.store:readSetting("model") }
end

function FlashForge:configured()
    local c = self:cfg()
    return c.ip ~= nil and c.serial ~= nil and c.code ~= nil
end

--- Change some of the settings ({ ip = …, … }; false clears one); what was read is forgotten.
function FlashForge:setCfg(t)
    for k, v in pairs(t) do
        if v == false or v == "" then self.store:delSetting(k) else self.store:saveSetting(k, v) end
    end
    self.store:flush()
    state.info, state.raw, state.product, state.files, state.why, state.time, state.tried = nil, nil, nil, nil, nil, 0, 0
    self:changed()
end

--- The printer's name as shown: the one read from it, else the one saved, else "FlashForge".
function FlashForge:printerName()
    local i = state.info
    return (i and i.name ~= "" and i.name) or self.store:readSetting("name") or _("FlashForge")
end

--- How often the open app reads the printer (seconds, 5 to 300).
function FlashForge:interval()
    return math.max(5, math.min(300, tonumber(G_reader_settings:readSetting("flashforge_interval")) or 10))
end

function FlashForge:leveling()
    return G_reader_settings:isTrue("flashforge_leveling")
end

-- ------------------------------------------------------------------ reading the printer

function FlashForge:api()
    return require("ffapi").new(self:cfg(), self.dir)
end

--- Why something failed, in plain words.
function FlashForge:whyText(why)
    local s = tostring(why or "")
    if s == "signin" then return _("The printer refused the serial number or check code. Check them in Settings.") end
    if s == "offline" then return _("Not on Wi-Fi.") end
    if s == "notset" then return _("No printer set up yet.") end
    if s:find("timeout") or s:find("timed out") then return _("The printer didn't answer. Is it on, and on this Wi-Fi?") end
    if s:find("refused") then return _("The printer refused the connection. Is LAN-only mode on?") end
    if s:find("unreachable") or s:find("No route") then return _("The printer can't be reached from this Wi-Fi.") end
    if s == "" or s == "nil" or s == "no answer" then return _("The printer didn't answer.") end
    return s
end

--- Read the printer in the background; done(info) when it is in (nil and why
-- when it didn't answer). One read at a time.
function FlashForge:fetch(done)
    if done then table.insert(state.waiting, done) end
    if state.reading then return end
    local function finish(i, why)
        local waiting = state.waiting
        state.waiting = {}
        for __, f in ipairs(waiting) do pcall(f, i, why) end
    end
    if not self:configured() then return finish(nil, "notset") end
    if not NetworkMgr:isConnected() then
        state.why = "offline"
        return finish(nil, "offline")
    end
    state.reading, state.tried = true, os.time()
    local api = self:api()
    local wantProduct = state.product == nil
    require("ffbg").run(function()
        local d, why = api:detail()
        if not d then return { why = why } end
        local p = wantProduct and api:product() or nil
        return { detail = d, product = p }
    end, function(r, why)
        state.reading = false
        if r and r.detail then
            state.raw, state.time, state.why = r.detail, os.time(), nil
            state.info = M.info(r.detail)
            if r.product then state.product = r.product end
            -- (the printer's own name and model, for when it isn't answering)
            local c = self:cfg()
            if c.name ~= state.info.name or c.model ~= state.info.model then
                self.store:saveSetting("name", state.info.name)
                self.store:saveSetting("model", state.info.model)
                self.store:flush()
            end
            self:notifyChanges(state.info)
            self:changed()
            return finish(state.info)
        end
        state.why = (r and r.why) or why or "no answer"
        logger.info("FlashForge: no answer:", state.why)
        self:changed()
        finish(nil, state.why)
    end, { limit = 20 })
end

--- The printer as last read (nil until read); read again in the background
-- when older than maxAge seconds (and on Wi-Fi).
function FlashForge:status(maxAge)
    -- (a printer that's off is asked again no sooner than one that answers)
    local last = math.max(state.time, state.tried)
    if self:configured() and os.time() - last >= (maxAge or 30) and not state.reading and NetworkMgr:isConnected() then
        self:fetch()
    end
    return state.info
end

function FlashForge:info() return state.info end
function FlashForge:raw() return state.raw end
function FlashForge:readTime() return state.time end
function FlashForge:lastWhy() return state.why end
function FlashForge:reading() return state.reading end

--- Whether the printer says it has a light to switch (its /product; yes when unknown).
function FlashForge:hasLight()
    if G_reader_settings:isTrue("flashforge_light_always") then return true end
    local p = state.product
    if not p then return true end
    return tonumber(p.lightCtrlState) ~= 0
end

--- Print finished and printer errors to the shared notifications; the
-- notification goes when the next print starts or the printer is ready again.
function FlashForge:notifyChanges(i)
    local PS = require("pluginshare")
    local before = state.lastState
    state.lastState = i.state
    if not PS.notify or before == nil or before == i.state then return end
    local key = "flashforge:job"
    local function open() local ff = current() if ff then ff:show() end end
    if i.state == "completed" and M.active(before) then
        pcall(PS.notify, { app = "flashforge", name = _("FlashForge"), icon = "printer", key = key,
            text = T(_("Print finished: %1"), i.file ~= "" and i.file or self:printerName()), open = open, route = {} })
    elseif i.state == "error" then
        pcall(PS.notify, { app = "flashforge", name = _("FlashForge"), icon = "printer", key = key,
            text = i.error and T(_("Printer error %1"), i.error) or _("The printer stopped with an error"), open = open, route = {} })
    elseif M.active(i.state) or (i.state == "ready" and before ~= "ready") then
        if PS.unnotify then pcall(PS.unnotify, key) end
    end
end

--- Redraw what shows the printer: the app's pages, or the launcher when its line changed.
function FlashForge:changed()
    local UI = require("ffui")
    if #UI.pages > 0 then UI.refreshAll() end
    local line = self:appsLine()
    if line == state.line then return end
    state.line = line
    local apps = self.ui and self.ui.apps
    if apps and apps.changed then pcall(apps.changed, apps) end
end

--- The launcher tile's line: "Printing 42% · 1 h 5 min left", "Ready".
function FlashForge:appsLine()
    if not self:configured() then return M.appsLine(nil, false) end
    local i = self:status(60)
    if not i and state.why == "offline" then return _("Not on Wi-Fi") end
    if not i and state.why and state.why ~= "offline" then return _("Printer not answering") end
    return M.appsLine(i, true)
end

-- ------------------------------------------------------------------ actions

-- What each action does, in the child.
local ACTIONS = {
    pause = function(api) return api:job("pause") end,
    resume = function(api) return api:job("continue") end,
    cancel = function(api) return api:job("cancel") end,
    clear = function(api) return api:clearPlate() end,
    light = function(api, a) return api:light(a.on) end,
    filtration = function(api, a) return api:filtration(a.mode) end,
    print = function(api, a) return api:print(a.body) end,
}
FlashForge.ACTIONS = ACTIONS

--- Do an action in the background; then done(ok, why) and the printer read again.
-- name: pause, resume, cancel, clear, light { on }, filtration { mode }, print { body }.
-- opts.text: a waiting message meanwhile.
function FlashForge:act(name, args, done, opts)
    local fn = ACTIONS[name]
    if not fn then return done and done(false, "unknown action") end
    if not self:configured() then return done and done(false, "notset") end
    if not NetworkMgr:isConnected() then return done and done(false, "offline") end
    local api = self:api()
    args = args or {}
    require("ffbg").run(function()
        local ok, why = fn(api, args)
        if not ok then return { why = why or "refused" } end
        return { ok = true }
    end, function(r, why)
        local good = r and r.ok
        if not good then logger.warn("FlashForge:", name, (r and r.why) or why) end
        -- (the printer takes a moment to show the change)
        UIManager:scheduleIn(1.5, function() self:fetch() end)
        if done then done(good and true or false, (r and r.why) or why) end
    end, { limit = 25, text = opts and opts.text })
end

--- The recent files; done(files) or done(nil, why). Kept for search.
function FlashForge:readFiles(done)
    if not self:configured() then return done(nil, "notset") end
    if not NetworkMgr:isConnected() then return done(nil, "offline") end
    local api = self:api()
    require("ffbg").run(function()
        local t, why = api:files()
        if not t then return { why = why } end
        return { list = t }
    end, function(r, why)
        if r and r.list then
            state.files = M.files(r.list)
            return done(state.files)
        end
        done(nil, (r and r.why) or why)
    end, { limit = 20, text = _("Reading the printer's files…") })
end

function FlashForge:files() return state.files end

-- A file name safe to save under.
local function safeName(s)
    return (tostring(s):gsub("[^%w%-%.]", "_"))
end

--- A file's thumbnail; done(path) or done(nil). Read once per file name.
function FlashForge:thumbnail(fileName, done)
    local name = "thumb-" .. safeName(fileName) .. ".png"
    local path = self.dir .. "/" .. name
    if lfs.attributes(path, "mode") == "file" then return done(path) end
    if not self:configured() or not NetworkMgr:isConnected() then return done(nil) end
    local api = self:api()
    require("ffbg").run(function()
        local p = api:thumbnail(fileName, name)
        return { path = p }
    end, function(r)
        done(r and r.path or nil)
    end, { limit = 20 })
end

--- A picture from the camera; done(path) or done(nil, why). Each one a new
-- file (the page keeps pictures by name); the one before is removed.
function FlashForge:snapshot(done)
    if not self:configured() then return done(nil, "notset") end
    if not NetworkMgr:isConnected() then return done(nil, "offline") end
    local api = self:api()
    local name = "camera-" .. os.time() .. ".jpg"
    local url = state.raw and type(state.raw.cameraStreamUrl) == "string" and state.raw.cameraStreamUrl or ""
    require("ffbg").run(function()
        local p, why = api:snapshot(name, url)
        return { path = p, why = why }
    end, function(r, why)
        if r and r.path then
            if state.camera and state.camera ~= r.path then os.remove(state.camera) end
            state.camera = r.path
            return done(r.path)
        end
        done(nil, (r and r.why) or why)
    end, { limit = 20, text = _("Taking a picture…") })
end

-- Kindles block incoming connections: the discovery answers' port while it listens.
local function firewall(open)
    if not Device:isKindle() then return end
    os.execute(string.format("iptables %s INPUT -p udp --dport %d -j ACCEPT", open and "-A" or "-D", DISCOVERY_PORT))
end

--- Printers on this Wi-Fi; done(list) or done(nil, why).
function FlashForge:discover(done)
    if not NetworkMgr:isConnected() then return done(nil, "offline") end
    firewall(true)
    require("ffbg").run(function()
        return require("ffapi").discover(4, DISCOVERY_PORT)
    end, function(list, why)
        firewall(false)
        if type(list) ~= "table" then return done(nil, why) end
        done(list)
    end, { limit = 15, text = _("Looking for printers…") })
end

-- ------------------------------------------------------------------ the launcher

function FlashForge:shareWithApps()
    local PS = require("pluginshare")
    PS.notifyOpeners = PS.notifyOpeners or {}
    -- What it is for the launcher and the web page: its tile (only there while it's installed:
    -- an optional app), Settings group (Optional apps; its tile in the suggested Tools group), web tab
    -- (apps.koplugin/appsinfo.lua).
    PS.appInfo = PS.appInfo or {}
    PS.appInfo.flashforge = { name = _("FlashForge"), icon = "printer", order = 80, group = "optional",
        -- "Printing 42% · 1 h 5 min left", "Ready".
        tiles = { { key = "flashforge", group = "tools", event = "ShowFlashForge", line = function(f) return f:appsLine() end } },
        web = { page = "flashforge", routes = "webflashforge", script = "web/flashforge.js", dir = self.path,
            card = "Your 3D printer: the print, pause and cancel, the light and settings." } }
    PS.notifyOpeners.flashforge = function()
        local ff = current()
        if ff then ff:show() end
    end
    -- The web page's backup: the printer and the settings; the serial number
    -- and check code only with Include keys and sign-ins.
    PS.backupApps = PS.backupApps or {}
    PS.backupApps.flashforge = { key = "flashforge", name = _("FlashForge"),
        files = { "^flashforge%.lua$" },
        reader_keys = { "^flashforge_" },
        secret_keys = { ["flashforge.lua"] = { "serial", "code" } } }
    if PS.registerSettings then
        PS.registerSettings{ key = "flashforge", name = _("FlashForge"), icon = "printer",
            open = function() local ff = current() if ff then ff:show("settings") end end,
            rows = function()
                local ff = current()
                return ff and require("ffui").searchRows(ff) or {}
            end }
    end
    if PS.registerSearch then
        PS.registerSearch{ key = "flashforge", name = _("FlashForge"), icon = "printer", search = function(q)
            local ff = current()
            return ff and ff:search(q) or {}
        end }
    end
    if PS.registerSetup then
        PS.registerSetup{ key = "flashforge", order = 57, icon = "printer", title = _("FlashForge printer"),
            text = _("Your FlashForge 3D printer on the Kindle: the print and its progress, temperatures, pause and cancel, the light, a picture from the camera, and starting a recent file. For the Adventurer 5M and 5M Pro, AD5X, Creator 5 and Creator 5 Pro."),
            done = function() local ff = current() return ff ~= nil and ff:configured() end,
            doneText = _("Printer set up"), action = _("Find printers"),
            skipped = _("Nothing else needs it. Set up a printer any time from the FlashForge app."),
            help = { button = _("What you need"), title = _("Connecting a FlashForge printer"),
                steps = {
                    _("The printer and the Kindle on the same Wi-Fi."),
                    _("On the printer's screen: Settings > Network > LAN-only mode, on. Note the check code it shows."),
                    _("The serial number: on the printer's screen (Settings > About), including its SN at the start."),
                    _("Tap Find printers and pick yours (or enter its address by hand), then type the check code."),
                },
                after = _("Nothing is sent anywhere else: the Kindle talks to the printer directly."),
                guide = "flashforge.md" },
            run = function() local ff = current() if ff then require("ffui").find(ff) end end }
    end
    if PS.registerTest then
        PS.registerTest{ key = "flashforge", name = _("FlashForge"),
            configured = function() local ff = current() return ff ~= nil and ff:configured() end,
            run = function(Test)
                local ff = current()
                local c = ff and ff:cfg() or {}
                local started = require("socket").gettime()
                local d, why = require("ffapi").new(c, "/tmp"):detail()
                local ms = math.floor((require("socket").gettime() - started) * 1000)
                local row = { name = _("Printer"), detail = (c.ip or "?") .. ":" .. M.PORT, ms = ms }
                if d then
                    local i = M.info(d)
                    row.ok, row.why = true, T(_("%1 · %2"), i.model, M.stateText(i.state))
                else
                    row.ok, row.raw = false, tostring(why)
                    row.why = why == "signin" and _("Answers, but refused the serial number or check code")
                        or (ff and ff:whyText(why)) or Test.why(why)
                end
                return { row }
            end }
    end
    if PS.registerQuick then
        PS.registerQuick{ key = "flashforge", name = _("FlashForge"),
            choices = function()
                return {
                    { id = "status", name = _("Printer status"), icon = "printer", group = _("FlashForge") },
                    { id = "pause", name = _("Pause or resume"), icon = "pause", group = _("FlashForge") },
                    { id = "light", name = _("Printer light"), icon = "lightbulb", group = _("FlashForge") },
                }
            end,
            item = function(id)
                local ff = current()
                return ff and ff:quickItem(id)
            end }
    end
end

--- A quick button: the status (tap reads it again), pause or resume, the light.
function FlashForge:quickItem(id)
    if not self:configured() then return nil end
    local i = self:status(60)
    local ko = require("ffko")
    local function failed(ok, why) if not ok then ko.toast(self:whyText(why)) end end
    local function open() self:show() end
    if id == "status" then
        return { label = self:printerName(), icon = "printer", value = i and M.summary(i) or nil,
            tap = function(done) self:fetch(function() if done then done() end end) end, hold = open }
    elseif id == "pause" then
        local paused = i and M.canResume(i.state)
        return { label = paused and _("Resume") or _("Pause"), icon = paused and "play" or "pause",
            on = paused, value = i and M.summary(i) or nil,
            tap = function(done)
                if not (i and (M.canPause(i.state) or M.canResume(i.state))) then
                    ko.toast(_("Nothing is printing"))
                    return done and done()
                end
                self:act(paused and "resume" or "pause", {}, function(ok, why) failed(ok, why) if done then done() end end)
            end, hold = open }
    elseif id == "light" then
        return { label = _("Printer light"), icon = "lightbulb", on = i and i.light or false,
            tap = function(done)
                self:act("light", { on = not (i and i.light) }, function(ok, why) failed(ok, why) if done then done() end end)
            end, hold = open }
    end
end

--- The launcher's search (q in lower case): the recent files as last read
-- (they open their page), and the printer itself.
function FlashForge:search(q)
    local out = {}
    if not q or q == "" then return out end
    local name = self:printerName()
    if name:lower():find(q, 1, true) or ("flashforge printer"):find(q, 1, true) then
        table.insert(out, { title = name, sub = state.info and M.summary(state.info) or _("FlashForge"),
            open = function() self:show() end })
    end
    for __, f in ipairs(state.files or {}) do
        if #out >= 20 then break end
        if f.name:lower():find(q, 1, true) then
            table.insert(out, { title = f.name, sub = M.fileLine(f), open = function()
                self:show()
                require("ffui").file(self, f)
            end })
        end
    end
    return out
end

-- ------------------------------------------------------------------ the web page

--- What the web page's FlashForge tab shows (no serial number or check code).
function FlashForge:webState()
    local c = self:cfg()
    local i = self:configured() and self:status(5) or nil
    local out = { configured = self:configured(), ip = c.ip, name = self:printerName(), model = c.model,
        hasCode = c.code ~= nil, interval = self:interval(), leveling = self:leveling(),
        read = state.time > 0 and state.time or nil, why = state.why and self:whyText(state.why) or nil }
    if i then
        local twentyFour = not G_reader_settings:isTrue("twelve_hour_clock")
        out.state, out.stateText, out.summary = i.state, M.stateText(i.state), M.summary(i)
        out.file, out.progress, out.lines = i.file, i.progress, M.jobLines(i, os.time(), twentyFour)
        out.canPause, out.canResume, out.canCancel, out.canClear = M.canPause(i.state), M.canResume(i.state),
            M.active(i.state), M.canClear(i.state)
        out.temps = { { name = _("Nozzle"), value = M.temp(i.nozzle) }, { name = _("Bed"), value = M.temp(i.bed) } }
        if i.chamber then table.insert(out.temps, { name = _("Chamber"), value = M.temp(i.chamber) }) end
        if #i.tools > 1 then
            for k, t in ipairs(i.tools) do table.insert(out.temps, { name = T(_("Tool %1"), k), value = M.temp(t) }) end
        end
        out.light, out.hasLight = i.light, self:hasLight()
        out.filtration, out.hasFiltration = i.filtration, i.hasFiltration
        out.error = i.error
        out.slots = {}
        for __, s in ipairs(i.slots) do
            table.insert(out.slots, { id = s.id, text = M.slotText(s), color = s.color, empty = s.empty,
                current = s.id == i.currentSlot })
        end
    end
    return out
end

--- The web page's actions: pause, resume, cancel, clear, light { on },
-- filtration { mode }, refresh (started in the background: the page reads
-- the state again after); settings { ip, serial, code, interval, leveling }.
-- Returns true, or false and why.
function FlashForge:webAct(name, args)
    args = type(args) == "table" and args or {}
    if name == "settings" then
        local t = {}
        if args.ip ~= nil then
            if args.ip ~= "" and not M.isIp(args.ip) then return false, _("Enter the printer's IP address, such as 192.168.1.50.") end
            t.ip = args.ip
        end
        if args.serial ~= nil and args.serial ~= "" then t.serial = args.serial end
        if args.code ~= nil and args.code ~= "" then t.code = args.code end
        if next(t) then self:setCfg(t) end
        if tonumber(args.interval) then
            G_reader_settings:saveSetting("flashforge_interval", math.max(5, math.min(300, math.floor(tonumber(args.interval)))))
        end
        if type(args.leveling) == "boolean" then G_reader_settings:saveSetting("flashforge_leveling", args.leveling) end
        if self:configured() and next(t) then self:fetch() end
        return true
    end
    if not self:configured() then return false, self:whyText("notset") end
    if not NetworkMgr:isConnected() then return false, self:whyText("offline") end
    if name == "refresh" then
        self:fetch()
        return true
    end
    if name == "light" then args = { on = args.on == true } end
    if name == "filtration" and not (args.mode == "off" or args.mode == "internal" or args.mode == "external") then
        return false, "Unknown mode"
    end
    if not ACTIONS[name] or name == "print" then return false, "Unknown action" end
    self:act(name, args)
    return true
end

return FlashForge
