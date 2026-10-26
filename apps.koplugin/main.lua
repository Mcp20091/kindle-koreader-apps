--[[--
Apps: a launcher for KOReader. A full screen of big tiles for the apps
(Home Assistant and its dashboard, To Do, Notes, the web server) and for
KOReader's own places (the book being read, the library, Wi-Fi), each with a
line of what is going on.

Open it from Tools > Apps, a gesture (General > Apps), or have it open when
KOReader starts.

@module koplugin.apps
]]

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("appscanvas")
local Model = require("appsmodel")
local Notify = require("appsnotify")
local View = require("appsview")

local Apps = WidgetContainer:extend{
    name = "apps",
    is_doc_only = false,
}

local started = false   -- opened once at KOReader's start (when that is on)
local current = nil     -- the launcher on screen

-- For every app (PluginShare): the notifications (appsnotify.lua), ⌂ Home,
-- and the calls of the pop-ups, the control center, the settings list, the
-- search, the setup and the app switcher. Only small tables and calls here:
-- each module loads the first time it is used, not at KOReader's start.
Notify.install()
require("appsfooter").install()
do
    local PS = require("pluginshare")
    PS.appsHome = function() if Apps.instance then Apps.instance:home() end end
    PS.appsView = function() return current end
    PS.appsApps = function() return Apps.instance end
    --- The notifications as they are (a copy), for apps that take theirs out when done.
    PS.notifications = function()
        local out = {}
        for i, e in ipairs(Notify.list()) do out[i] = e end
        return out
    end
    PS.popup = setmetatable({}, { __index = function(__, k) return require("appspopup")[k] end })
    -- The shared helpers (menus, pop-ups, the light…): the other apps' copies hand over to these.
    PS.ko = setmetatable({}, { __index = function(__, k) return require("appsko")[k] end })
    PS.showControlCenter = function(koMenu) require("appscontrol").show(koMenu) end
    -- What the other apps register (read by appshub, appssearch, appssetup).
    PS.settingsApps, PS.searchApps, PS.setupSteps = PS.settingsApps or {}, PS.searchApps or {}, PS.setupSteps or {}
    PS.registerSettings = function(e) if type(e) == "table" and e.key and e.open then PS.settingsApps[e.key] = e end end
    PS.registerSearch = function(e) if type(e) == "table" and e.key and e.search then PS.searchApps[e.key] = e end end
    -- Other apps' quick buttons (appsquick.lua): { key, name, choices = fn() -> { { id, name, icon, group } },
    -- item = fn(id) -> { label, icon, on, value, tap(done), hold, steps = { minus, plus }, media = {...}, chip } }.
    PS.quickApps = PS.quickApps or {}
    PS.registerQuick = function(e) if type(e) == "table" and e.key and e.item then PS.quickApps[e.key] = e end end
    PS.registerSetup = function(e) if type(e) == "table" and e.key and e.title then PS.setupSteps[e.key] = e end end
    -- Connection tests (appstest.lua): PS.registerTest{ key, name, run = fn(Test) -> results }.
    require("appstest").install()
    -- A QR code full screen, with a caption and Close (appsqr.lua): PS.showQR{ text, caption, onClose }.
    require("appsqr").install()
    -- One Microsoft account for To Do and OneNote (appsmicrosoft.lua): PS.microsoft.
    require("appsmicrosoft").install()
    PS.registerSettings{ key = "microsoft", name = _("Microsoft"), icon = "key-round",
        open = function(jump) require("appsmicrosoft").showSettings(jump) end,
        rows = function() return require("appsmicrosoft").settingsRows() end }
    PS.backupApps = PS.backupApps or {}
    PS.backupApps.microsoft = { key = "microsoft", name = "Microsoft", files = { "^microsoft%.lua$" },
        secret_keys = { ["microsoft.lua"] = { "refresh_token", "access_token", "expires_at" } } }
    PS.registerTest{ key = "microsoft", name = _("Microsoft"),
        configured = function() return PS.microsoft.clientId() ~= nil or PS.microsoft.signedIn() end,
        run = function(Test)
            local rows = { Test.http{ name = _("Microsoft sign-in"), detail = "login.microsoftonline.com",
                url = "https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration",
                check = function(status) return status == 200, status ~= 200 and ("HTTP " .. status) or nil end } }
            if PS.microsoft.signedIn() then
                -- A fresh token (not kept: this is the test's child).
                PS.microsoft.store().save = function() end
                local started = require("socket").gettime()
                local token, why = PS.microsoft.accessToken(true)
                table.insert(rows, { name = _("Your sign-in"), detail = PS.microsoft.account(),
                    ms = math.floor((require("socket").gettime() - started) * 1000), ok = token ~= nil,
                    why = not token and (tostring(why):find("sign in again") and _("It has run out. Sign in again.") or Test.why(why)) or nil,
                    raw = not token and tostring(why) or nil })
            end
            return rows
        end }
    PS.registerSetup{ key = "microsoft", order = 30, icon = "key-round", title = _("Microsoft"),
        text = _("To Do and Notes' OneNote use your Microsoft account: one App ID (a free app registration with Microsoft) and one sign-in, with a code on your phone or computer."),
        done = function() return PS.microsoft.signedIn() end,
        doneText = _("Signed in"),
        action = _("Sign in"),
        skipped = _("To Do keeps lists on this Kindle only, with everything but syncing, and Notes works without OneNote. Sign in any time in Settings > Microsoft."),
        run = function()
            local M = require("appsmicrosoft")
            if PS.microsoft.clientId() then return M.signIn() end
            M.showSettings()
        end,
        help = { button = _("How to get an App ID"), title = _("Getting an App ID"),
            steps = {
                _("A personal Microsoft account first needs a free Azure account (azure.microsoft.com/free), which gives it the directory apps are registered in. A work or school account already has one."),
                _("On a computer, sign in at portal.azure.com and open App registrations > New registration."),
                _("Name it (\"Kindle\"), choose \"Accounts in any organizational directory and personal Microsoft accounts\", leave the redirect empty, and Register."),
                _("Authentication: set \"Allow public client flows\" to Yes, and Save."),
                _("API permissions: Add a permission > Microsoft Graph > Delegated: Tasks.ReadWrite and Notes.ReadWrite."),
                _("Copy the Application (client) ID from Overview, and enter it in Settings > Microsoft > App ID."),
            },
            after = _("It's free, and the one App ID works for To Do and OneNote."),
            guide = "setup.md#microsoft-to-do-and-onenote" } }
    PS.registerTest{ key = "weather", name = _("Weather"),
        configured = function() return Apps.instance ~= nil and Apps.instance.settings.weather ~= "off" end,
        run = function(Test)
        return Apps.instance and require("appsweather").test(Apps.instance, Test) or {}
    end }
    --- An app opened (not from the launcher): first in the switcher's list.
    PS.noteRecent = function(key)
        if Apps.instance then
            require("appsswitcher").note(Apps.instance.settings, key)
            Apps.instance:save()
        end
    end
    PS.showSearch = function()
        if not Apps.instance then return end
        Apps.instance:showMode("tiles")
        if current then require("appssearch").ask(current) end
    end
    PS.showSwitcher = function() if Apps.instance then Apps.instance:showMode("switcher") end end
    PS.showSettings = function(key)
        local e = key and PS.settingsApps[key]
        if e then return e.open() end
        if Apps.instance then Apps.instance:showMode("hub") end
    end
    PS.settingsPage = function(spec)
        if not Apps.instance then return end
        Apps.instance:showMode("page", function(v) v.pageSpec, v.pagePage, v.pageJump = spec, 1, spec.jump end)
    end
    PS.showSetup = function() require("appssetup").show() end
    --- The launcher's settings at Sleep (the sleep screen is chosen there, for every app).
    PS.showSleepSettings = function()
        if not Apps.instance then return end
        Apps.instance:showMode("arrange", function(v) v.arrangePart, v.arrangePage, v.arrangeJump = "settings", 1, "sleep" end)
    end
    -- Apps' own rows in Settings: the launcher's settings, and KOReader's (its menu at the settings tab).
    PS.registerSettings{ key = "apps", name = _("Launcher"), icon = "app-window", open = function(jump)
        if current then
            current.mode, current.arrangePart, current.arrangePage, current.arrangeJump = "arrange", "settings", 1, jump
            current:refresh()
        end
    end, rows = function() return current and current:settingsRows() or {} end }
    PS.registerSettings{ key = "apps_tiles", name = _("Edit home screen"), icon = "grid-3x3", open = function()
        if current then current.mode, current.arrangePart, current.arrangePage = "arrange", "tiles", 1 current:refresh() end
    end }
    -- Screens of the launcher, in Settings too (their tiles are off to start with); Back returns here.
    local function screen(mode, prepare)
        return function()
            if not current then return end
            current.backTo = current.mode
            current.mode = mode
            current[mode .. "Page"] = 1
            if prepare then prepare(current) end
            current:refresh()
        end
    end
    PS.registerSettings{ key = "fonts", name = _("Fonts"), icon = "type",
        open = screen("fonts", function(v) v.fontsData = nil end) }
    -- AI for every app (appsai.lua): the services, which does each job, and
    -- each feature's instructions. The apps register their jobs and features
    -- here (only kept in lists: appsai loads when first used).
    PS.aiJobs, PS.aiFeatures = PS.aiJobs or {}, PS.aiFeatures or {}
    PS.ai = setmetatable({
        registerJob = function(e) if type(e) == "table" and e.key and e.name then PS.aiJobs[e.key] = e end end,
        registerFeature = function(e)
            if type(e) ~= "table" or not e.key then return end
            for __, f in ipairs(PS.aiFeatures) do
                if f.key == e.key then return end
            end
            table.insert(PS.aiFeatures, e)
        end,
    }, { __index = function(__, k) return require("appsai")[k] end })
    -- Handwriting input for every app's text boxes (appshandwrite.lua): read
    -- by the AI that reads handwriting, with its own instructions in Advanced.
    PS.ai.registerJob{ key = "read", name = _("Reading handwriting"), app = "apps", order = 10 }
    PS.ai.registerFeature{ key = "handwriting", name = _("Handwriting input"), app = "apps", job = "read",
        intro = "This is handwriting written on a Kindle instead of typing, for a text box. ",
        words = "Transcribe it exactly as written; fix only obvious misreadings. Keep the writer's capitals and punctuation.",
        format = " Reply with the text only, nothing before or after it.",
        request = false, without = _("With a picture of what was written.") }
    PS.handwriting = setmetatable({}, { __index = function(__, k) return require("appshandwrite")[k] end })
    PS.registerSettings{ key = "ai", name = _("AI"), icon = "sparkles", open = function(jump) require("appsaiview").show(nil, jump) end,
        rows = function() return require("appsaiview").mainRows() end }
    -- The web page's backup: its keys only with Include keys (its settings
    -- are the launcher's, "apps_ai").
    PS.backupApps = PS.backupApps or {}
    PS.backupApps.ai = { key = "ai", name = "AI", secret_files = { "ai_secrets.lua" } }
    PS.registerTest{ key = "ai", name = _("AI"),
        configured = function() return require("appsai").any() end,
        run = function(Test) return require("appsai").tests(Test) end }
    PS.registerSetup{ key = "ai", order = 40, icon = "sparkles", title = _("AI"),
        text = _("An AI turns your handwriting into text in the apps' text boxes, and helps in Notes (Ask, reading pages), Crosswords (hints, checks) and SSH (explaining output, writing commands). Pick one: Claude, Gemini, OpenRouter, Groq, your own local AI, or any OpenAI-compatible service. Each lists its current models. Later you can give each job its own AI or model, or hold any AI button to switch it there. No paid key? Gemini has a free key at aistudio.google.com."),
        done = function() return require("appsai").any() end,
        doneText = _("Set up"),
        action = _("Set up the AI"),
        run = function() require("appsaiview").show() end,
        skipped = _("Everything works without it; the AI buttons stay hidden. Set one up any time in Settings > AI."),
        -- Where each service's key comes from (the steps and a QR code to the guide).
        help = {
            button = _("How to get a key"),
            title = _("Getting an AI key"),
            steps = {
                _("Gemini (free): on a phone or computer, sign in at aistudio.google.com and tap Get API key."),
                _("Groq (free): sign in at console.groq.com and make a key under API Keys."),
                _("OpenRouter: sign in at openrouter.ai and make a key under Keys (openrouter/free costs nothing)."),
                _("Claude: make a key at platform.claude.com (paid; Max and Team plans include credits)."),
                _("Your own AI: the address of the computer running Ollama, such as http://192.168.1.50:11434."),
                _("Then tap Set up the AI, pick the service and enter the key."),
            },
            after = _("On free tiers the service may use what you send to improve its products."),
            guide = "setup.md#ai-notes-and-crosswords",
        } }
    -- (KOReader's own Gestures and Battery statistics plugins: there unless turned off.)
    PS.registerSettings{ key = "gestures", name = _("Gestures"), icon = "hand",
        open = screen("gestures", function(v) v.gesturesMode = nil end) }
    PS.registerSettings{ key = "battery", name = _("Battery"), icon = "battery-medium", open = screen("battery") }
    -- KOReader: its most-used settings on a page of their own (appskosettings.lua), its full menu last.
    local function koreaderMenu()
        local ui = Apps.instance and Apps.instance:currentUI()
        local menu = ui and ui.menu
        if not (menu and menu.onShowMenu) then return end
        if menu.tab_item_table == nil and menu.setUpdateItemTable then menu:setUpdateItemTable() end
        local index
        for i, tab in ipairs(menu.tab_item_table or {}) do
            if tab.icon == "appbar.settings" then index = i end
        end
        menu:onShowMenu(index)
    end
    -- (Night mode's quick button opens it on a hold.)
    PS.koreaderMenu = koreaderMenu
    PS.registerSettings{ key = "koreader", name = "KOReader", icon = "settings", open = function(jump)
        PS.settingsPage{ title = _("KOReader settings"), jump = jump, rows = function() return require("appskosettings").rows(koreaderMenu) end }
    end, rows = function() return require("appskosettings").rows(koreaderMenu) end }
    -- Set up your Kindle: Wi-Fi first.
    PS.registerSetup{ key = "wifi", order = 10, icon = "wifi", title = _("Wi-Fi"),
        text = _("Most of the apps need Wi-Fi now and then: Home Assistant, To Do's sync, Notes' AI and the web page. Turn it on and pick your network."),
        done = function() return NetworkMgr:isWifiOn() and NetworkMgr:isConnected() ~= false end,
        doneText = _("Connected"),
        action = _("Turn on Wi-Fi"),
        skipped = _("Reading, Notes, Crosswords you already have and lists on this Kindle all work. What syncs or downloads waits for Wi-Fi."),
        run = function() NetworkMgr:toggleWifiOn(nil, true, true) end }
    -- The weather for At a glance, the widgets sleep screen and the Weather tile.
    -- Which tiles show, the layout, and the quick buttons.
    PS.registerSetup{ key = "launcher", order = 65, icon = "grid-3x3", title = _("Your home screen"),
        text = _("Make the home screen yours. Tap a setting to change it. Gestures, Battery and KOReader settings start hidden: tick them under Tiles if you want them."),
        done = function() return Apps.instance ~= nil and Apps.instance.settings.launcher_setup_done == true end,
        doneText = _("Changed"),
        skipped = _("The home screen keeps the usual tiles and buttons. Change them any time in Settings > Edit home screen and Quick buttons."),
        rows = function() return Apps.instance and Apps.instance:setupRows() or {} end }
    -- Last: what's ready without setting anything up (only what's installed).
    PS.registerSetup{ key = "more", order = 95, icon = "sparkles", title = _("More to explore"),
        text = _("Ready to use, no setup needed:"),
        info = true, done = function() return true end,
        items = function()
            local ui = current and current:ui()
            local function has(name) return ui and ui[name] ~= nil end
            local out = {}
            if has("notes") then table.insert(out, { icon = "notebook-pen", title = _("Notes"), text = _("Handwritten notebooks") }) end
            if has("crosswords") then table.insert(out, { icon = "grid-3x3", title = _("Crosswords"), text = _("Daily crosswords to solve with the pen") }) end
            if has("wikipedia") then table.insert(out, { icon = "wikipedia", title = _("Wikipedia"), text = _("Read articles and save them for offline") }) end
            if has("statistics") then table.insert(out, { icon = "activity", title = _("Reading statistics"), text = _("Reading time, streaks and progress by book") }) end
            table.insert(out, { icon = "type", title = _("Fonts"), text = _("Download fonts from Google Fonts") })
            table.insert(out, { icon = "search", title = _("Search"), text = _("Search books, notes, tasks and settings") })
            return out
        end }
    -- The bar at the top of every app, button by button: nothing to set, a page to read.
    PS.registerSetup{ key = "bar", order = 66, icon = "app-window", title = _("Getting around: the top bar"),
        text = _("Every app has the same bar at the top:"),
        info = true, done = function() return true end,
        items = function()
            return {
                { icon = "chevron-left", title = _("Back"), text = _("Where you were, or the launcher. Swiping in from the left edge does the same.") },
                { icon = "house", title = _("Home"), text = _("The launcher, from any app, a book or the library.") },
                { icon = "history", title = _("Recent apps"), text = _("The apps, books and notebooks you used last.") },
                { icon = "chevron-down", title = _("The time and battery"), text = _("Tap for the control center: the light, Wi-Fi, night mode and your quick buttons.") },
                { icon = "refresh-cw", title = _("Refresh"), text = _("Draws the screen again, clearing e-ink ghosting (and updates the app).") },
                { icon = "bell", title = _("Notifications"), text = _("Reminders, alerts and messages from every app. The number is how many are new.") },
                { icon = "ellipsis-vertical", title = _("Menu"), text = _("The app's own options, then Light, Night mode, Refresh screen and Settings.") },
                { icon = "globe", title = _("The globe"), text = _("Shows next to the time while the web server is on. Tap the bell for its address.") },
            }
        end }
    -- What holding and swiping do, everywhere: nothing to set, a page to read.
    PS.registerSetup{ key = "tips", order = 67, icon = "hand", title = _("Getting around: hold and swipe"),
        text = _("Holding something shows what else it does:"),
        info = true, done = function() return true end,
        items = function()
            return {
                { icon = "grid-3x3", title = _("Hold a tile on the launcher"), text = _("Move it, put it in a group, or hide it.") },
                { icon = "folder", title = _("Hold a group"), text = _("Rename it, sort it (Custom or A–Z) or change its icon.") },
                { icon = "lightbulb", title = _("Hold a quick button"), text = _("What's behind it, such as a light's brightness.") },
                { icon = "house", title = _("Hold a Home Assistant device"), text = _("Its controls: brightness and color, fan speed, the thermostat and more.") },
                { icon = "book-open", title = _("Hold a book, notebook or task"), text = _("Its options, such as rename, move and delete.") },
                { icon = "sparkles", title = _("Hold a button that uses AI"), text = _("Pick which AI service and model does that job.") },
                { icon = "hand", title = _("Swipe"), text = _("Left or right turns the page, in from the left edge goes back, and a diagonal swipe clears the screen.") },
            }
        end }
    PS.registerSetup{ key = "weather", order = 25, icon = "cloud-sun", title = _("Weather"),
        text = _("The weather on the launcher and the sleep screen: Home Assistant's, or without it a free forecast from Open-Meteo (no account). Pick your town or city."),
        done = function() return Apps.instance ~= nil and require("appsweather").source(Apps.instance) ~= nil end,
        doneText = _("Set"), action = _("Pick a place"),
        skipped = _("The launcher and the sleep screen leave the weather out. Set a place any time: Settings > Launcher > WEATHER."),
        run = function() if Apps.instance then require("appsweather").choosePlace(Apps.instance) end end }
end

--- At KOReader's start: Set up your Kindle, only while nothing is set up yet
-- and it wasn't turned off (looked at without loading it).
local function setupAtStart()
    if G_reader_settings:isTrue("apps_setup_done") then return end
    local any = false
    for key, e in pairs(require("pluginshare").setupSteps) do
        -- (Pages that only explain, such as Hold for more, are always "done": not counted.)
        if key ~= "wifi" and not e.info then
            any = true
            local ok, isDone = pcall(function() return e.done and e.done() end)
            if ok and isDone == true then return end
        end
    end
    if any then require("appssetup").show() end
end

function Apps:init()
    Canvas.setDir(self.path)
    self.settings = G_reader_settings:readSetting("apps") or {}
    -- Gestures, Battery and KOReader settings became off to start with: a
    -- launcher set up before that keeps them as they were (once).
    if not self.settings.defaults_2 then
        if next(self.settings) ~= nil then
            self.settings.hidden = self.settings.hidden or {}
            for __, k in ipairs({ "gestures", "battery", "kosettings" }) do
                if self.settings.hidden[k] == nil then self.settings.hidden[k] = false end
            end
        end
        self.settings.defaults_2 = true
        G_reader_settings:saveSetting("apps", self.settings)
    end
    -- One clock for every app: KOReader's own (twelve_hour_clock). Once: the
    -- launcher's old 24-hour switch moves there, and the 12-hour clock the
    -- apps showed stays when KOReader's was never set.
    if not self.settings.clock_moved then
        if self.settings.clock_24h == true then
            G_reader_settings:makeFalse("twelve_hour_clock")
        elseif G_reader_settings:readSetting("twelve_hour_clock") == nil then
            G_reader_settings:makeTrue("twelve_hour_clock")
        end
        self.settings.clock_24h, self.settings.clock_moved = nil, true
        G_reader_settings:saveSetting("apps", self.settings)
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- Once per KOReader start, over the library or the book it opened. (Not
    -- by the library's file list: KOReader starts plugins before making it.)
    if not started then
        started = true
        if self.settings.at_start then
            UIManager:nextTick(function() self:show() end)
        end
        -- Set up your Kindle, while nothing is set up yet (after the other apps have started).
        UIManager:scheduleIn(3, setupAtStart)
        -- A newer release (Check automatically, once a day, only when already on Wi-Fi).
        UIManager:scheduleIn(60, function() pcall(require("appsupdate").daily, Apps.instance) end)
    end
    Apps.instance = self
    -- The apps' title bar on a tap at the top of a book or the library (appsreaderbar.lua).
    require("appsreaderbar").install()
    -- Where a book came from (Back goes there), Back from the left edge in a
    -- book and the library; the bar's tip, once.
    require("appsreaderbar").cameFrom(self.ui)
    require("appsreaderbar").edgeBack(self.ui)
    require("appsreaderbar").tipOnce(self.ui)
    -- (The launcher's own dark mode is gone: KOReader's night mode is the one for every app.)
    if self.settings.dark ~= nil then
        self.settings.dark = nil
        self:save()
    end

    self:hookSleepScreen()
    Apps.watchWifi()
    -- After AutoSuspend (it starts after this plugin).
    UIManager:nextTick(function() Apps.guardAutoSuspend(self.ui) end)
end

-- ------------------------------------------------------------------ KOReader's sleep timer

--- On a Kindle, KOReader's sleep timer (AutoSuspend) resets the power manager's
-- own timer every 4 minutes. If its check runs after KOReader's sleep time has
-- passed while the Kindle is still awake (it slept without KOReader hearing of
-- it and has just woken, say), it schedules the next check for "now" and does
-- so forever: KOReader freezes. Then: check again in a minute instead (a tap
-- starts the timer over; with none, the power manager's timer puts it to sleep).
function Apps.guardAutoSuspend(ui)
    local Device = require("device")
    local as = ui and ui.autosuspend
    if not Device:isKindle() or not as or as.apps_guarded or not as._schedule_kindle then return end
    as.apps_guarded = true
    local time = require("ui/time")
    local schedule = as._schedule_kindle
    as._schedule_kindle = function(s)
        local ok, stuck = pcall(function()
            local now = UIManager:getElapsedTimeSinceBoot()
            return s.auto_suspend_timeout_seconds - time.to_number(now - s.last_action_time) <= 0
                and 4 * 60 - time.to_number(now - s.last_t1_reset_time) <= 0
        end)
        if ok and stuck and s.kindle_task and not require("pluginshare").keepalive then
            require("logger").info("Apps: KOReader's sleep timer is past its time while awake; checking again in a minute")
            UIManager:unschedule(s.kindle_task)
            UIManager:scheduleIn(60, s.kindle_task)
            return
        end
        return schedule(s)
    end
end

-- ------------------------------------------------------------------ Wi-Fi when idle

-- Turn Wi-Fi off after settings.wifi_idle minutes with (almost) no network
-- use: the bytes in and out of every network interface (/proc/net/dev), so
-- a download, a sync or Home Assistant's updates keep it on. Not while the
-- web server is on. One check a minute, for all of KOReader.
local IDLE_BYTES = 16 * 1024 -- in a minute: less is the network's own chatter
local idle = { bytes = nil, at = os.time() }

--- Bytes in and out so far (all interfaces but loopback), or nil.
function Apps.networkBytes()
    local f = io.open("/proc/net/dev", "r")
    if not f then return nil end
    local total, any = 0, false
    for line in f:lines() do
        local name, rest = line:match("^%s*([%w%._%-]+):%s*(.*)$")
        if name and name ~= "lo" then
            local n = {}
            for v in rest:gmatch("%d+") do table.insert(n, tonumber(v)) end
            if n[1] and n[9] then
                total = total + n[1] + n[9]
                any = true
            end
        end
    end
    f:close()
    return any and total or nil
end

function Apps.watchWifi()
    if Apps.wifiTask then return end
    Apps.wifiTask = function()
        UIManager:scheduleIn(60, Apps.wifiTask)
        local inst = Apps.instance
        local minutes = inst and tonumber(inst.settings.wifi_idle)
        if minutes and minutes <= 0 then minutes = nil end
        local bytes = Apps.networkBytes()
        local now = os.time()
        if not (minutes and bytes and NetworkMgr:isWifiOn()) then
            idle.bytes, idle.at = bytes, now
            return
        end
        if not idle.bytes or bytes - idle.bytes > IDLE_BYTES then idle.at = now end
        idle.bytes = bytes
        local ui = inst:currentUI()
        local web = ui and ui.webpage
        if web and web.address and web:address() ~= "" then idle.at = now return end
        if now - idle.at >= minutes * 60 then
            idle.at = now
            NetworkMgr:toggleWifiOff(nil, true)
            require("appsko").toast(T(_("Wi-Fi turned off: not used for %1 min"), minutes))
        end
    end
    UIManager:scheduleIn(60, Apps.wifiTask)
end

-- Back from sleep: the time asleep doesn't count as idle.
function Apps:onResume()
    idle.bytes, idle.at = Apps.networkBytes(), os.time()
end

-- Wi-Fi on: the day's check for a newer release, if it hasn't been done (appsupdate.lua).
function Apps:onNetworkConnected()
    UIManager:scheduleIn(30, function() pcall(require("appsupdate").daily, Apps.instance) end)
end

function Apps:save()
    G_reader_settings:saveSetting("apps", self.settings)
end

--- The open KOReader screen (its plugins are the live ones).
function Apps:currentUI()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if ReaderUI and ReaderUI.instance then return ReaderUI.instance end
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    return FileManager and FileManager.instance or self.ui
end

function Apps:onDispatcherRegisterActions()
    Dispatcher:registerAction("apps_show", { category = "none", event = "ShowApps", title = _("Launcher"), general = true })
end

function Apps:addToMainMenu(menu_items)
    menu_items.apps = {
        text = _("Launcher"),
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

--- What can be pinned: Home Assistant's screens and rooms, To Do's lists,
-- Notes' notebooks. Each: { kind, name, icon, route or id }.
function Apps:pinChoices(kind)
    local out = {}
    if kind == "ha" then
        local ha = self:plugin("homeassistant")
        local ok, M = pcall(require, "hamodel")
        if not (ha and ok) then return out end
        table.insert(out, { kind = "ha", name = _("Home"), icon = "house", route = { kind = "home" } })
        table.insert(out, { kind = "ha", name = _("Dashboard"), icon = "layout-dashboard", route = { kind = "dashboard" } })
        for __, s in ipairs(M.SHORTCUTS) do
            if s.key ~= "dashboard" then
                table.insert(out, { kind = "ha", name = _(s.label), icon = s.icon,
                    route = s.screen and { kind = s.screen } or { kind = "category", key = s.key } })
            end
        end
        if ha.snap then
            for __, r in ipairs(M.rooms(ha.snap, ha.prefs)) do
                -- (not "Everything Else": the devices without a room)
                if r.name ~= "Everything Else" then table.insert(out, { kind = "ha", name = r.name, icon = "door-open", route = { kind = "room", name = r.name } }) end
            end
        end
    elseif kind == "todo" then
        local todo = self:plugin("todo")
        -- Its views (Today, Agenda, Starred, Calendar, Search) first, then the lists.
        local okv, views = pcall(function() return todo:viewPins() end)
        for __, p in ipairs(okv and views or {}) do table.insert(out, p) end
        local ok, lists = pcall(function() return todo:orderedLists() end)
        for __, l in ipairs(ok and lists or {}) do
            table.insert(out, { kind = "todo", name = l.name, icon = "list-checks", id = l.id })
        end
    elseif kind == "note" then
        local notes = self:plugin("notes")
        local ok, list = pcall(function() return notes.store:list() end)
        for __, n in ipairs(ok and list or {}) do
            table.insert(out, { kind = "note", name = n.name, icon = "notebook-pen", id = n.id })
        end
    elseif kind == "action" then
        -- KOReader's own actions (as gestures run them).
        local ok, list = pcall(function() return require("appsactions").choices() end)
        for __, p in ipairs(ok and list or {}) do table.insert(out, p) end
    elseif kind == "crossword" then
        -- A source's newest crossword ("usa", "guardian/quick").
        local notes = self:plugin("notes")
        local ok, list = pcall(function() return notes:crosswordSources() end)
        for __, s in ipairs(ok and list or {}) do
            table.insert(out, { kind = "crossword", name = T(_("%1 crossword"), (s.name:gsub(" %(.-%)$", ""))), icon = "grid-3x3", id = s.key })
        end
    elseif kind == "notefolder" then
        -- Notes' folders: a path of names ("Work/Clients"), shown by its last name.
        local notes = self:plugin("notes")
        local ok, list = pcall(function() return notes.folders:all() end)
        for __, path in ipairs(ok and list or {}) do
            table.insert(out, { kind = "notefolder", name = path:match("([^/]+)$") or path, icon = "folder", id = path })
        end
    end
    return out
end

--- Pins a place: { kind = "ha", name, icon, route }, { kind = "todo", id, name,
-- icon }, { kind = "note", id, name, icon } or { kind = "notefolder", id = path,
-- name, icon }. For other plugins too
-- (self.ui.apps:addPin{...}): Home Assistant, To Do and Notes call it.
function Apps:addPin(p)
    local s = self.settings
    local added
    s.pins, added = Model.addPin(s.pins, p)
    if s.hidden then s.hidden[Model.pinKey(p)] = nil end
    self:save()
    if current then
        current:refresh()
        UIManager:nextTick(function() if current then current:updateLines() end end)
    end
    require("appsko").toast(added and T(_("Added %1 to the launcher."), p.name) or T(_("%1 is already on the launcher."), p.name), 2)
    return added
end

--- Every tile (the apps, the pins, the groups) in its order; hidden ones only withHidden.
function Apps:tiles(withHidden)
    local s = self.settings
    local ui = self:currentUI()
    return Model.tiles(s.order, s.hidden, Apps.has(ui), withHidden, s.pins, s.groups)
end

--- Whether a tile's plugin (or "@frontlight", "@homeassistant" (set up), or "plugin:call") is there, on `ui`.
function Apps.has(ui)
    return function(name)
        if name == "@frontlight" then
            local Device = require("device")
            return Device:hasFrontlight() and true or false
        end
        -- Home Assistant set up (its Dashboard is nothing without it).
        if name == "@homeassistant" then
            local ha = ui and ui.homeassistant
            local ok, signed = pcall(function() return ha.api:signedIn() end)
            return ok and signed == true
        end
        -- "plugin:call": the plugin, new enough to have that call.
        local plugin, call = name:match("^([^:]+):(.+)$")
        if plugin then return ui ~= nil and ui[plugin] ~= nil and ui[plugin][call] ~= nil end
        return ui and ui[name] ~= nil
    end
end

--- A small picture of the home screen as it would look after `change(settings)` (applied for
-- the picture only): `w` pixels wide; `part` (0 to 1) keeps only the top of it. A blitbuffer.
function Apps:homePicture(change, w, part)
    local Blitbuffer = require("ffi/blitbuffer")
    local View = require("appsview")
    local s = self.settings
    local saved = {}
    for k, v in pairs(s) do saved[k] = v end
    local ok, err = pcall(change, s)
    local v = ok and View:new{ apps = self }
    for k in pairs(s) do s[k] = nil end
    for k, val in pairs(saved) do s[k] = val end
    if not v then error(err) end
    local full = Blitbuffer.new(v.w, v.h, Blitbuffer.TYPE_BB8)
    full:fill(Blitbuffer.COLOR_WHITE)
    v.canvas:paint(full, 0, 0)
    v.canvas:release()
    local h = math.floor(v.h * (part or 1))
    local top = full
    if h < v.h then
        top = Blitbuffer.new(v.w, h, Blitbuffer.TYPE_BB8)
        top:blitFrom(full, 0, 0, 0, 0, v.w, h)
        full:free()
    end
    return require("ui/renderimage"):scaleBlitBuffer(top, w, math.max(1, math.floor(h * w / v.w)), true)
end

--- Set up your Kindle's launcher step, as settings rows on the step itself:
-- { { title, value, fn(refresh) } }; refresh() draws the step again after a change.
function Apps:setupRows()
    local KO = require("appsko")
    local View = require("appsview")
    local s = self.settings
    local refresh = function() end
    local function done()
        s.launcher_setup_done = true
        self:changed()
        refresh()
    end
    local function tiles()
        local items = {}
        for __, t in ipairs(self:tiles(true)) do
            if not t.pin and not t.groupTile then
                local hidden = Model.isHidden(s.hidden, t)
                table.insert(items, { text = _(t.name), checked = not hidden, fn = function()
                    s.hidden = s.hidden or {}
                    s.hidden[t.key] = not hidden
                    done()
                    UIManager:nextTick(tiles)
                end })
            end
        end
        KO.list(_("Tiles on the launcher"), items)
    end
    local Quick = require("appsquick")
    -- The built-in quick buttons that can be added here: { b, entry, its list, its index }.
    local function builtins()
        if type(s.quick) ~= "table" then s.quick = require("util").tableDeepCopy(Model.quickList(s)) end
        local out = {}
        for __, b in ipairs(Model.QUICK_BUILTIN) do
            if Quick.available(b.key) then
                local e, l, i = Model.quickFind(s.quick, "b:" .. b.key)
                table.insert(out, { b = b, e = e, l = l, i = i })
            end
        end
        return out
    end
    local function quick()
        local items = {}
        for __, x in ipairs(builtins()) do
            table.insert(items, { text = _(x.b.name), checked = x.e ~= nil, fn = function()
                if x.e then table.remove(x.l, x.i) else table.insert(s.quick, { b = x.b.key }) end
                done()
                UIManager:nextTick(quick)
            end })
        end
        KO.list(_("Quick buttons"), items)
    end
    local shown, on = 0, 0
    for __, t in ipairs(self:tiles(true)) do
        if not t.pin and not t.groupTile and not Model.isHidden(s.hidden, t) then shown = shown + 1 end
    end
    for __, x in ipairs(builtins()) do if x.e then on = on + 1 end end
    local Popup = require("appspopup")
    local rows = {
        { title = _("Tiles"), sub = _("Which apps show on the home screen"), value = T(_("%1 shown"), shown),
            fn = function(r) refresh = r tiles() end },
        -- Each layout as a picture of the home screen drawn that way.
        { title = _("Layout"), sub = _("How the apps are drawn: tiles, a list or icons"), value = View.LAYOUT_NAMES[s.layout or "tiles"], fn = function(r)
            refresh = r
            local options = {}
            for __, v in ipairs(View.LAYOUTS) do
                table.insert(options, { label = View.LAYOUT_NAMES[v], value = v,
                    picture = function(w) return self:homePicture(function(t) t.layout = v end, w) end })
            end
            Popup.pictures{ title = _("Layout"), options = options, current = s.layout or "tiles",
                onPick = function(v) s.layout = v done() end }
        end },
        -- The recent books, notebooks and crosswords: the newest of each in one row, or a row each
        -- (pictures of the top of the home screen, where they are).
        { title = _("Recent items"), sub = _("Your latest books, notebooks and crosswords"),
            value = s.recent_together ~= false and _("One row") or _("Separate rows"), fn = function(r)
            refresh = r
            Popup.pictures{ title = _("Recent items"), current = s.recent_together ~= false and "together" or "separate", options = {
                { label = _("One row"), value = "together",
                    picture = function(w) return self:homePicture(function(t) t.recent_together = nil end, w, 0.45) end },
                { label = _("Separate rows"), value = "separate",
                    picture = function(w) return self:homePicture(function(t) t.recent_together = false end, w, 0.45) end },
            }, onPick = function(v)
                if v == "separate" then s.recent_together = false else s.recent_together = nil end
                done()
            end }
        end },
        -- Ready-made groups (Settings, Reading, Home...), from those that can be made (the launcher's own).
        { title = _("Suggested groups"), sub = _("Ready-made folders of apps: Settings, Reading, Home, Writing, Tools"),
            value = current == nil and _("Open the launcher first") or nil, fn = function(r)
            refresh = r
            if current then current:suggestGroups() else KO.toast(_("Open the launcher first, then come back here.")) end
        end },
        { title = _("Quick buttons"), sub = _("The round buttons under the clock: Wi-Fi, Light, Night mode…"),
            value = T(_("%1 on"), on), fn = function(r) refresh = r quick() end },
    }
    return rows
end

--- From KOReader's reading statistics: { today = seconds read today, streak
-- = days read in a row, ... } (nil without the statistics). Read only.
function Apps:readingStats()
    return require("appsstats").summary()
end

--- After a change from elsewhere (the web page): saved, and the launcher redrawn if it shows.
function Apps:changed()
    self:save()
    if current then
        current:refresh()
        UIManager:nextTick(function() if current then current:updateLines() end end)
    end
end

--- The plugin of that name on the open KOReader screen.
function Apps:plugin(name)
    local ui = self:currentUI()
    return ui and ui[name]
end

function Apps:onShowApps()
    self:show()
    return true
end

--- ⌂ in a title bar: Apps on top, with what was opened over it closed.
function Apps:home()
    if current then
        local stack = UIManager._window_stack or {}
        local at
        for i, w in ipairs(stack) do if w.widget == current then at = i end end
        if at then
            local over = {}
            for i = #stack, at + 1, -1 do table.insert(over, stack[i].widget) end
            for __, w in ipairs(over) do UIManager:close(w) end
            current:refresh()
            UIManager:setDirty(current, "full")
            return
        end
    end
    self:show()
end

--- The launcher on top in one of its screens ("switcher", "hub", "page"):
-- from another app, back closes it again.
function Apps:showMode(mode, prepare)
    local wasTop = current and UIManager:getTopmostVisibleWidget() == current
    if not wasTop then self:show() end
    if not current then return end
    current.switcherBack = not wasTop or nil
    current.mode = mode
    current[mode .. "Page"] = 1
    if prepare then prepare(current) end
    current:render()
    UIManager:setDirty(current, "full")
end

--- The launcher's settings (from a ⋮ menu's Settings).
function Apps:openSettings()
    if not current then self:show() end
    if current then
        current.mode, current.arrangePart, current.arrangePage = "arrange", "settings", 1
        current:refresh()
    end
end

function Apps:show()
    if current then
        if UIManager:getTopmostVisibleWidget() == current then
            current:refresh()
            return
        end
        -- Under an app opened from it: brought back on top.
        UIManager:close(current)
        current = nil
    end
    current = View:new{ apps = self, on_close = function() current = nil end }
    require("appsko").showFull(current)
end

-- ------------------------------------------------------------------ sleep screen

-- One sleep screen setting for To Do, Home Assistant and Apps:
-- G_reader_settings "sleep_screen_app" ("apps" here; To Do's older on/off
-- counts until one is picked).
local SLEEP_NAMES = { todo = _("To Do tasks"), homeassistant = _("Home Assistant"), apps = _("Summary"), widgets = _("Widgets") }

function Apps:sleepSource()
    local src = G_reader_settings:readSetting("sleep_screen_app")
    if src == nil then
        local todo = self:plugin("todo")
        if todo and todo.opt and todo:opt("sleep_screen") then return "todo" end
    end
    return src
end

function Apps:sleepName() return SLEEP_NAMES[self:sleepSource() or ""] or _("KOReader's own") end

function Apps:sleepChoices()
    local out = { { _("KOReader's own"), "none" } }
    if self:plugin("todo") then table.insert(out, { _("To Do tasks"), "todo" }) end
    if self:plugin("homeassistant") then table.insert(out, { _("Home Assistant"), "homeassistant" }) end
    table.insert(out, { _("Summary"), "apps" })
    table.insert(out, { _("Widgets"), "widgets" })
    return out
end

function Apps:setSleep(v)
    local Device = require("device")
    if Device.supportsScreensaver and not Device:supportsScreensaver() then
        return require("appsko").message(_("On this device KOReader does not draw the sleep screen (on a Kindle: Amazon's ads, \"special offers\", are on), so it cannot show anything there."))
    end
    if v == "none" then G_reader_settings:delSetting("sleep_screen_app") else G_reader_settings:saveSetting("sleep_screen_app", v) end
    local todo = self:plugin("todo")
    if todo and todo.setOpt then pcall(todo.setOpt, todo, "sleep_screen", v == "todo") end
end

-- KOReader's Screensaver:show, wrapped once: with Apps picked, the summary is
-- shown instead (as KOReader shows its own).
function Apps:hookSleepScreen()
    if Apps.sleepHooked then return end
    Apps.sleepHooked = true
    local Screensaver = require("ui/screensaver")
    local original = Screensaver.show
    Screensaver.show = function(saver, ...)
        local inst = Apps.instance
        local src = G_reader_settings:readSetting("sleep_screen_app")
        if inst and (src == "apps" or src == "widgets") then
            local ok, err = pcall(inst.showSleepScreen, inst, saver)
            if ok then return end
            require("logger").warn("Apps sleep screen:", err)
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

function Apps:showSleepScreen(saver)
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
        if G_reader_settings:readSetting("sleep_screen_app") == "widgets" then View.drawWidgets(self, c) else View.drawSleep(self, c) end
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
    -- Drawn again while asleep (Update while asleep).
    local widget = saver.screensaver_widget
    require("appsko").sleepUpdates(function()
        draw()
        UIManager:setDirty(widget, "full")
    end)
end

return Apps
