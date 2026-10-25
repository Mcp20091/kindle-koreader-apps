--[[--
Settings (addresses, account, screens, what asks first, update timing, the
dashboard), the reorder screen (Home sections, Quick tiles, rooms, the
devices in a room: pick one up, move it with the arrows, hide it with the
eye) and the device picker. Also the sign-in dialogs.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Api = require("haapi")
local Canvas = require("hacanvas")
local Model = require("hamodel")
local Sheet = require("hasheet")
local KO = require("hako")
local PS = require("pluginshare")

local C = Canvas
local Settings = {}

Settings.TOKEN_FILE = DataStorage:getSettingsDir() .. "/homeassistant-token.txt"

local SECTION_NAMES = {
    status = _("Weather and status bar"), shortcuts = _("Shortcuts"), routines = _("Routines"),
    on = _("On now"), quick = _("Quick"), rooms = _("Rooms"),
}
Settings.SECTION_NAMES = SECTION_NAMES

-- Looks: how tiles are drawn, dark mode and the dashboard's style.
local LAYOUTS = {
    { label = _("Cards"), value = "cards" }, { label = _("Big tiles"), value = "big" },
    { label = _("List"), value = "list" }, { label = _("Minimal"), value = "minimal" },
}
local DARK = {
    { label = _("Off"), value = "off" }, { label = _("On"), value = "on" }, { label = _("Dashboard only"), value = "dashboard" },
}
local DASH_STYLES = {
    { label = _("Clock and info"), value = "clock" }, { label = _("Security"), value = "security" },
    { label = _("Info cards"), value = "info" }, { label = _("Camera"), value = "camera" }, { label = _("Clock only"), value = "clockonly" },
}
Settings.LAYOUTS, Settings.DARK, Settings.DASH_STYLES = LAYOUTS, DARK, DASH_STYLES

local DOORBELL_LABELS = { motion = _("Ring and motion"), ring = _("Ring only"), off = _("Off") }

local DASH_SECTION_NAMES = {
    status = _("Status bar"), rooms = _("Room temperatures"), next = _("Next up"), media = _("Now playing"),
    tasks = _("Today's tasks"), scenes = _("Scenes and routines"), graph = _("24-hour graph"), camera = _("Camera"), quick = _("Quick tiles"),
}

local function labelOf(options, value)
    for __, o in ipairs(options) do
        if o.value == value then return o.label end
    end
    return options[1].label
end

-- ------------------------------------------------------------------ dialogs

local function input(title, value, hint, done)
    -- The launcher's text box (no pen: addresses and tokens need exact characters).
    if KO.askText then
        return KO.askText{ title = title, text = value, hint = hint, pen = false, done = done }
    end
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value or "",
        input_hint = hint,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                done(text)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end
Settings.input = input

-- A choice in the apps' shared pop-up (KOReader's own without Apps).
local function choose(title, options, current, done)
    KO.choose(title, options, current, done)
end
Settings.choose = choose

--- Signing in the way the phone app does: address, username, password, then a code if asked.
--- Signing in with the user name and password, once the addresses are known.
local function signInWith(ha, home, away, user, password, done)
    ha.api:set("home_url", home or away)
    ha.api:set("away_url", home and away or nil)
    ha.store:saveSetting("username", user)
    ha:online(_("Signing in…"), function()
        local login, why
        local urls = {}
        if home then table.insert(urls, home) end
        if away then table.insert(urls, away) end
        for __, url in ipairs(urls) do
            login, why = ha.api:startLogin(url)
            if login then break end
        end
        if not login then return ha:failed(why) end
        local result
        result, why = ha.api:loginStep(login, { username = user, password = password })
        if result == "mfa" then
            return Settings.askCode(ha, login, done)
        end
        if not result then return ha:failed(why) end
        ha:signedIn(done)
    end)
end

--- With the launcher: one field a step in its request box (no pen: exact characters).
-- The Internal URL (and, ticked, the External URL as its own step), the user name, the
-- password; Back goes to the step before, and what was typed is kept.
local function signInSteps(ha, done)
    local P = PS.popup
    if not (P and P.request) then return false end
    local st = {
        home = ha.api:get("home_url") or "",
        away = ha.api:get("away_url") or "",
        user = ha.store:readSetting("username") or "",
        password = "",
    }
    st.wantAway = st.away ~= ""
    local order
    local function steps()
        order = { "home" }
        if st.wantAway then table.insert(order, "away") end
        table.insert(order, "user")
        table.insert(order, "password")
        return order
    end
    local SPEC = {
        home = { sub = _("The address on your home Wi-Fi"), hint = "http://homeassistant.local:8123" },
        away = { sub = _("External URL: an address that works from anywhere"), hint = "https://…" },
        user = { sub = _("Your Home Assistant user name"), hint = _("User name") },
        password = { sub = _("Password"), hint = "", password = true },
    }
    local show
    show = function(i)
        steps()
        local key = order[i]
        local spec = SPEC[key]
        local last = i == #order
        local function keep(text) st[key] = text or "" end
        local sections
        if key == "home" then
            sections = { { chips = { { text = _("External URL"), on = function() return st.wantAway end,
                tap = function() st.wantAway = not st.wantAway end } } } }
        end
        local buttons = {
            i == 1 and { icon = "x", text = _("Cancel"), cancel = true }
                or { icon = "arrow-left", text = _("Back"), fn = function(text) keep(text) show(i - 1) end },
        }
        if last then
            table.insert(buttons, { icon = "log-in", text = _("Sign in"), primary = true, needsText = true, fn = function(text)
                keep(text)
                local home, away = Api.cleanUrl(st.home), st.wantAway and Api.cleanUrl(st.away) or nil
                signInWith(ha, home, away, st.user, st.password, done)
            end })
        else
            table.insert(buttons, { icon = "arrow-right", text = _("Next"), primary = true, needsText = key ~= "away", fn = function(text)
                keep(text)
                if key == "home" and not Api.cleanUrl(st.home) then
                    require("hako").message(_("Enter the Internal URL first."))
                    return show(i)
                end
                show(i + 1)
            end })
        end
        P.request{ app = "ha", title = _("Sign in to Home Assistant"),
            subtitle = T(_("%1 of %2 · %3"), i, #order, spec.sub),
            text = st[key], hint = spec.hint, password = spec.password, typing = true,
            sections = sections, buttons = buttons }
    end
    show(1)
    return true
end

function Settings.signIn(ha, done)
    if signInSteps(ha, done) then return end
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Connect to Home Assistant"),
        fields = {
            { description = _("Internal URL"), text = ha.api:get("home_url") or "", hint = "http://homeassistant.local:8123" },
            { description = _("External URL (optional)"), text = ha.api:get("away_url") or "", hint = "https://…" },
            { description = _("Username"), text = ha.store:readSetting("username") or "", hint = _("Home Assistant username") },
            { description = _("Password"), text = "", text_type = "password", hint = "" },
        },
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Sign in"), is_enter_default = true, callback = function()
                local f = dialog:getFields()
                local home, away = Api.cleanUrl(f[1]), Api.cleanUrl(f[2])
                if not home and not away then
                    require("hako").message(_("Enter the Internal URL first."))
                    return
                end
                UIManager:close(dialog)
                ha.api:set("home_url", home or away)
                ha.api:set("away_url", home and away or nil)
                ha.store:saveSetting("username", f[3])
                ha:online(_("Signing in…"), function()
                    local login, why
                    local urls = {}
                    if home then table.insert(urls, home) end
                    if away then table.insert(urls, away) end
                    for __, url in ipairs(urls) do
                        login, why = ha.api:startLogin(url)
                        if login then break end
                    end
                    if not login then return ha:failed(why) end
                    local result
                    result, why = ha.api:loginStep(login, { username = f[3], password = f[4] })
                    if result == "mfa" then
                        return Settings.askCode(ha, login, done)
                    end
                    if not result then return ha:failed(why) end
                    ha:signedIn(done)
                end)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Settings.askCode(ha, login, done)
    local function signIn(code)
        ha:online(_("Signing in…"), function()
            local result, why = ha.api:loginStep(login, { code = code })
            if result == "mfa" then return Settings.askCode(ha, login, done) end
            if not result then return ha:failed(why) end
            ha:signedIn(done)
        end)
    end
    if KO.askText then
        return KO.askText{ title = _("Two-factor code"), hint = _("Code from your authenticator app"), number = true,
            pen = false, ok = _("Sign in"), okIcon = "log-in", needsText = true, done = signIn }
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Two-factor code"),
        input_type = "number",
        input_hint = _("Code from your authenticator app"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Sign in"), is_enter_default = true, callback = function()
                local code = dialog:getInputText()
                UIManager:close(dialog)
                ha:online(_("Signing in…"), function()
                    local result, why = ha.api:loginStep(login, { code = code })
                    if result == "mfa" then return Settings.askCode(ha, login, done) end
                    if not result then return ha:failed(why) end
                    ha:signedIn(done)
                end)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- A long-lived token: from the token file (copied over USB) or typed.
function Settings.useToken(ha, done)
    local function apply(token)
        if not ha.api:get("home_url") and not ha.api:get("away_url") then
            return input(_("Internal URL"), "", "http://homeassistant.local:8123", function(url)
                ha.api:set("home_url", Api.cleanUrl(url))
                apply(token)
            end)
        end
        ha:online(_("Checking token…"), function()
            local ok, why = ha.api:useToken(token)
            if not ok then return ha:failed(why) end
            ha:signedIn(done)
        end)
    end
    KO.list(T(_("Create a long-lived access token in Home Assistant (Profile > Security), then copy it to\n%1\nover USB, or enter it here."), Settings.TOKEN_FILE), {
        { text = _("Load from file"), fn = function()
            local f = io.open(Settings.TOKEN_FILE, "r")
            local token = f and f:read("*a")
            if f then f:close() end
            if not token or token:gsub("%s", "") == "" then
                return require("hako").message(T(_("No token found in\n%1"), Settings.TOKEN_FILE))
            end
            apply(token)
        end },
        { text = _("Enter manually"), fn = function() input(_("Long-lived token"), "", "", apply) end },
    })
end

-- ------------------------------------------------------------------ settings screen

local function rowsOf(view)
    local ha, prefs = view.ha, view.ha.prefs
    local api = ha.api
    local function save() ha:savePrefs() view:refresh("ui") end
    local function flip(key) return function() prefs[key] = prefs[key] == false and true or false save() end end
    local function on(key) return prefs[key] ~= false end
    local minutes = function(n) return n == 0 and _("Off") or T(_("Every %1 min"), n) end
    local cams = {}
    if ha.snap then
        for __, e in ipairs(ha.snap.list) do
            if e.domain == "camera" and Model.visible(e, prefs) then table.insert(cams, e) end
        end
    end
    local camLabel = _("Rotate through all")
    if prefs.dash_camera == "none" then camLabel = _("None")
    elseif prefs.dash_camera and prefs.dash_camera ~= "cycle" and ha.snap and ha.snap.byId[prefs.dash_camera] then
        camLabel = ha.snap.byId[prefs.dash_camera].name
    end
    local shown, total = 0, 0
    if ha.snap then
        for __, e in ipairs(ha.snap.list) do
            total = total + 1
            if Model.visible(e, prefs) then shown = shown + 1 end
        end
    end
    local graphLabel = _("Auto")
    if prefs.dash_graph and ha.snap and ha.snap.byId[prefs.dash_graph] then graphLabel = ha.snap.byId[prefs.dash_graph].name end
    local weatherLabel = _("Auto")
    for __, w in ipairs(prefs.weather and ha.snap and ha.snap.weathers or {}) do
        if w.id == prefs.weather then weatherLabel = w.name end
    end
    local keepOff = ha:keepOffMinutes()
    -- The same sections as every app: Display first, then the app's own
    -- (Home, Devices and cameras, Dashboard, Sleep screen, Confirm), the
    -- connection last. Light, night mode and a screen refresh are in ⋮.
    return {
        { _("DISPLAY") },
        { _("Start screen"), prefs.start == "dashboard" and _("Dashboard") or _("Home"), function()
            prefs.start = prefs.start == "dashboard" and "home" or "dashboard"
            save()
        end },
        { _("Layout"), labelOf(LAYOUTS, prefs.layout or "cards"), function()
            choose(_("Layout"), LAYOUTS, prefs.layout or "cards", function(v) prefs.layout = v save() end)
        end },

        { _("HOME") },
        { _("Home sections"), _("Reorder or hide"), function() view:go({ kind = "reorder", what = "sections" }) end },
        { _("Shortcuts"), _("Choose and reorder"), function() view:go({ kind = "reorder", what = "shortcuts" }) end },
        { _("Quick tiles"), T(_("%1 tiles"), ha.snap and #Model.quick(ha.snap, prefs) or 0), function() view:go({ kind = "reorder", what = "quick" }) end },
        { _("Rooms"), _("Reorder or hide"), function() view:go({ kind = "reorder", what = "rooms" }) end },
        { _("Routines"), #(prefs.routines or {}) == 0 and _("None yet") or tostring(#prefs.routines), function() view:go({ kind = "routines" }) end },
        { _("Keep turned off in On now"), keepOff > 0 and T(_("%1 min"), keepOff) or _("Off"), function()
            choose(_("Keep turned off in On now"), {
                { label = _("Off"), value = 0 }, { label = T(_("%1 min"), 1), value = 1 }, { label = T(_("%1 min"), 3), value = 3 },
                { label = T(_("%1 min"), 5), value = 5 }, { label = T(_("%1 min"), 10), value = 10 },
            }, keepOff, function(v) prefs.keep_off = v save() end)
        end },
        { _("DEVICES AND CAMERAS") },
        { _("Devices"), ha.snap and T(_("%1 of %2 shown"), shown, total) or "", function() view:go({ kind = "devices", filter = "all" }) end },
        { _("Cameras"), _("Reorder or hide"), function() view:go({ kind = "reorder", what = "cameras" }) end },
        { _("Security cameras"), _("Reorder or hide"), function() view:go({ kind = "reorder", what = "security_cams" }) end },
        { _("Weather"), weatherLabel, function()
            local options = { { label = _("Auto"), value = "auto" } }
            for __, w in ipairs(ha.snap and ha.snap.weathers or {}) do table.insert(options, { label = w.name, value = w.id }) end
            choose(_("Weather"), options, prefs.weather or "auto", function(v)
                prefs.weather = v ~= "auto" and v or nil
                ha.forecast, ha.forecastAt, ha.hourly, ha.hourlyAt = nil, nil, nil, nil
                save()
                ha:update(true)
            end)
        end },
        { _("DASHBOARD") },
        { _("Style"), labelOf(DASH_STYLES, prefs.dash_layout or "clock"), function()
            choose(_("Dashboard style"), DASH_STYLES, prefs.dash_layout or "clock", function(v) prefs.dash_layout = v save() end)
        end },
        { _("Camera"), camLabel, function()
            local options = { { label = _("Rotate through all"), value = "cycle" }, { label = _("None"), value = "none" } }
            for __, e in ipairs(cams) do table.insert(options, { label = e.name, value = e.id }) end
            choose(_("Dashboard camera"), options, prefs.dash_camera or "cycle", function(v) prefs.dash_camera = v save() end)
        end },
        { _("Sections"), _("Reorder or hide"), function() view:go({ kind = "reorder", what = "dash_sections" }) end },
        { _("Quick tiles"), T(_("%1 tiles"), ha.snap and #Model.dashQuick(ha.snap, prefs) or 0), function() view:go({ kind = "reorder", what = "dash_quick" }) end },
        { _("Scenes"), T(_("%1 buttons"), ha.snap and #Model.dashScenes(ha.snap, prefs) or 0), function() view:go({ kind = "reorder", what = "dash_scenes" }) end },
        { _("Graph"), graphLabel, function()
            local options = { { label = _("Auto"), value = "auto" } }
            for __, e in ipairs(ha.snap and Model.graphSensors(ha.snap) or {}) do
                table.insert(options, { label = e.name .. (e.area ~= "" and ("  \u{00B7}  " .. e.area) or ""), value = e.id })
            end
            choose(_("Dashboard graph"), options, prefs.dash_graph or "auto", function(v) prefs.dash_graph = v ~= "auto" and v or nil save() end)
        end },
        (function() local D = require("device") return D.hasLightSensor and D:hasLightSensor() end)() and { _("Auto brightness"), prefs.auto_light == true, function()
            prefs.auto_light = not prefs.auto_light or nil
            save()
            if prefs.auto_light then ha:followRoomLight(true) end
        end } or false,
        { _("Doorbell alerts"), DOORBELL_LABELS[prefs.doorbell or "motion"], function()
            choose(_("Doorbell alerts"), {
                { label = DOORBELL_LABELS.motion, value = "motion" }, { label = DOORBELL_LABELS.ring, value = "ring" }, { label = DOORBELL_LABELS.off, value = "off" },
            }, prefs.doorbell or "motion", function(v) prefs.doorbell = v save() end)
        end },
        { _("Update interval"), minutes(prefs.dash_minutes or 5), function()
            choose(_("Dashboard update interval"), {
                { label = _("Every minute"), value = 1 }, { label = minutes(5), value = 5 }, { label = minutes(10), value = 10 },
                { label = minutes(15), value = 15 }, { label = minutes(30), value = 30 },
            }, prefs.dash_minutes or 5, function(v) prefs.dash_minutes = v save() ha:schedule() end)
        end },
        { _("Keep awake"), ({ charging = _("While charging"), always = _("Always"), never = _("Never") })[prefs.dash_awake or "charging"], function()
            choose(_("Keep awake"), {
                { label = _("While charging"), value = "charging" }, { label = _("Always"), value = "always" }, { label = _("Never"), value = "never" },
            }, prefs.dash_awake or "charging", function(v) prefs.dash_awake = v save() ha:keepAwake() end)
        end },
        { _("SLEEP SCREEN") },
        -- Which sleep screen, and how often it's drawn again, are the launcher's (one for every app);
        -- here only without it.
        PS.showSleepSettings and { _("Sleep screen"), _("Launcher settings"), function() PS.showSleepSettings() end } or false,
        not PS.showSleepSettings and { _("Sleep screen"), Settings.sleepName(view), function() Settings.chooseSleep(view) end } or false,
        not PS.showSleepSettings and { _("Sleep screen updates"), KO.sleepUpdateName(KO.sleepMinutes()), function()
            local options = {}
            for __, m in ipairs(KO.SLEEP_UPDATES) do table.insert(options, { label = KO.sleepUpdateName(m), value = m }) end
            choose(_("Sleep screen updates"), options, KO.sleepMinutes(), function(v)
                G_reader_settings:saveSetting("sleep_screen_update", v)
                view:refresh("ui")
            end)
        end } or false,
        { _("Sleep screen alerts"), #(prefs.sleep_alerts or {}) == 0 and _("None") or T(_("%1 chosen"), #prefs.sleep_alerts),
            function() view:go({ kind = "reorder", what = "sleep_alerts" }) end },
        { _("Wake alerts"), prefs.wake_warning ~= false, function() prefs.wake_warning = prefs.wake_warning == false save() end },
        { _("CONFIRM") },
        { _("Unlock doors"), on("ask_unlock"), flip("ask_unlock") },
        { _("Open or close garage"), on("ask_garage"), flip("ask_garage") },
        { _("Run scripts"), on("ask_scripts"), flip("ask_scripts") },
        { _("CONNECTION") },
        { _("Update interval"), minutes(prefs.refresh_minutes or 1), function()
            choose(_("Update interval"), {
                { label = _("Every minute"), value = 1 }, { label = minutes(2), value = 2 }, { label = minutes(5), value = 5 },
                { label = minutes(10), value = 10 }, { label = _("Manual only"), value = 0 },
            }, prefs.refresh_minutes or 1, function(v) prefs.refresh_minutes = v save() ha:schedule() end)
        end },
        { _("Internal URL"), api:get("home_url") or _("Not set"), function()
            input(_("Internal URL"), api:get("home_url"), "http://homeassistant.local:8123", function(t)
                api:set("home_url", Api.cleanUrl(t))
                api.settings.save()
                view:refresh("ui")
            end)
        end },
        { _("External URL"), api:get("away_url") or _("Not set"), function()
            input(_("External URL (leave empty for none)"), api:get("away_url"), "https://…", function(t)
                api:set("away_url", Api.cleanUrl(t))
                api.settings.save()
                view:refresh("ui")
            end)
        end },
        PS.showConnectionTest and (api:get("home_url") or api:get("away_url")) and { _("Test connection"), _("Each address on its own"), function()
            PS.showConnectionTest("homeassistant")
        end } or false,
        { _("Account"), api:signedIn() and (api:get("token") and _("Using a token") or _("Signed in")) or _("Sign in"), function()
            if api:signedIn() then
                KO.confirm{
                    text = _("Sign out of Home Assistant on this Kindle?"),
                    ok = _("Sign out"),
                    onOk = function() ha:signOut() end,
                }
            else
                Settings.signIn(ha, function() view:refresh("ui") end)
            end
        end },
        { _("Long-lived token"), api:get("token") and _("Active") or _("Not used"), function()
            Settings.useToken(ha, function() view:refresh("ui") end)
        end },
    }
end

-- One sleep screen setting for To Do, Home Assistant and Apps
-- (G_reader_settings "sleep_screen_app"; To Do's older on/off counts until one is picked).
local SLEEP_NAMES = { todo = _("To Do tasks"), homeassistant = _("Home Assistant"), apps = _("Summary"), widgets = _("Widgets") }

local function sleepSource(view)
    local src = G_reader_settings:readSetting("sleep_screen_app")
    if src == nil then
        local ui = view:currentUI()
        if ui and ui.todo and ui.todo.opt and ui.todo:opt("sleep_screen") then return "todo" end
    end
    return src
end

function Settings.sleepName(view)
    return SLEEP_NAMES[sleepSource(view) or ""] or _("KOReader's own")
end

function Settings.chooseSleep(view)
    local Device = require("device")
    if Device.supportsScreensaver and not Device:supportsScreensaver() then
        return require("hako").message(_("On this device KOReader does not draw the sleep screen (on a Kindle: Amazon's ads, \"special offers\", are on), so it cannot show anything there."))
    end
    local ui = view:currentUI()
    local options = { { label = _("KOReader's own"), value = "none" }, { label = _("Home Assistant"), value = "homeassistant" } }
    if ui and ui.todo then table.insert(options, 2, { label = _("To Do tasks"), value = "todo" }) end
    if ui and ui.apps then table.insert(options, { label = _("Summary"), value = "apps" }) end
    if ui and ui.apps and ui.apps.showMode then table.insert(options, { label = _("Widgets"), value = "widgets" }) end
    choose(_("Sleep screen"), options, sleepSource(view) or "none", function(v)
        if v == "none" then G_reader_settings:delSetting("sleep_screen_app") else G_reader_settings:saveSetting("sleep_screen_app", v) end
        if ui and ui.todo and ui.todo.setOpt then pcall(ui.todo.setOpt, ui.todo, "sleep_screen", v == "todo") end
        view:refresh("ui")
    end)
end

--- The settings' rows (their names, for the launcher's search): { name } each, headings left out.
function Settings.searchRows(ha)
    local ok, rows = pcall(rowsOf, { ha = ha, refresh = function() end })
    local out = {}
    for __, row in ipairs(ok and rows or {}) do
        if row and type(row[1]) == "string" and (row[2] ~= nil or row[3]) then table.insert(out, { row[1] }) end
    end
    return out
end

function Settings.settings(view, c)
    local F = c:flow(56, c.H - 8, view.pageNo)
    -- Opened at a row (from the launcher's search): the page it's on.
    local jump, jumpPage = view.ha.settingsJump, nil
    view.ha.settingsJump = nil
    for __, row in ipairs(rowsOf(view)) do
        -- (false: a row left out, such as Light without a front light)
        local name, value, fn = row and row[1], row and row[2], row and row[3]
        if not row then
            -- nothing
        elseif value == nil and not fn then
            F:gap(10)
            F:block(24, function(y) c:text(14, y + 16, name, 9.5, { bold = true, color = C.GREY }) end, 36)
        else
            if jump and name == jump then jumpPage = F.page end
            F:block(36, function(y)
                c:text(14, y + 23, name, 12, { maxw = 330 })
                if type(value) == "boolean" then
                    Sheet.toggle(c, c.W - 54, y + 7, value, fn)
                    c:hit(0, y, c.W, 36, fn)
                else
                    c:text(c.W - 32, y + 23, value, 11, { align = "end", color = C.GREY, maxw = 250 })
                    c:icon("chevron-right", c.W - 26, y + 12, 12)
                    c:hit(0, y, c.W, 36, fn)
                end
                c:hline(14, y + 35, c.W - 14)
            end)
        end
    end
    if jumpPage and jumpPage ~= view.pageNo then
        view.pageNo = jumpPage
        UIManager:nextTick(function() view:refresh("ui") end)
    end
    view:titlebar(c, true, _("Home Assistant settings"), {}, F:pages())
    return F:pages()
end

-- ------------------------------------------------------------------ reorder

-- The rows of a reorder screen: { keys, labels, hidden = { [key] = true }, save(order), hide(key) }.
local function reorderList(view)
    local ha, prefs, snap = view.ha, view.ha.prefs, view.ha.snap
    local what = view.route.what
    local L = { keys = {}, labels = {}, hidden = {} }
    if what == "sections" then
        L.title = _("Home sections")
        for __, k in ipairs(Model.ordered(Model.HOME_SECTIONS, prefs.sections, function(s) return s end)) do
            table.insert(L.keys, k)
            L.labels[k] = SECTION_NAMES[k]
        end
        L.hidden = prefs.hidden_sections or {}
        L.save = function(order) prefs.sections = order end
        L.hide = function(k)
            prefs.hidden_sections = prefs.hidden_sections or {}
            prefs.hidden_sections[k] = not prefs.hidden_sections[k] or nil
        end
        L.hint = _("Tap a section to select it, then use the arrows to move it. Tap the eye to show or hide it.")
    elseif what == "shortcuts" then
        L.title = _("Shortcuts")
        for __, s in ipairs(Model.shortcuts(snap, prefs, true)) do
            table.insert(L.keys, s.key)
            L.labels[s.key] = _(s.label)
            L.hidden[s.key] = s.hidden or nil
        end
        L.save = function(order) prefs.shortcuts = order end
        L.hide = function(k)
            prefs.hidden_shortcuts = prefs.hidden_shortcuts or {}
            prefs.hidden_shortcuts[k] = not L.hidden[k]
        end
        L.hint = _("These buttons appear at the top of Home. Tap one to select it, then use the arrows to move it. Tap the eye to show or hide it.")
    elseif what == "quick" then
        L.title = _("Quick tiles")
        for __, e in ipairs(snap and Model.quick(snap, prefs) or {}) do
            table.insert(L.keys, e.id)
            L.labels[e.id] = e.name
        end
        L.save = function(order) prefs.quick = order end
        L.remove = function(k)
            local list = {}
            for __, id in ipairs(L.keys) do if id ~= k then table.insert(list, id) end end
            prefs.quick = list
        end
        L.hint = _("Tap a tile to select it, then use the arrows to move it. The \u{2715} removes it. To add one, hold any device and choose Quick & dashboard.")
    elseif what == "dash_sections" then
        L.title = _("Dashboard sections")
        for __, k in ipairs(Model.dashSections(prefs)) do
            table.insert(L.keys, k)
            L.labels[k] = DASH_SECTION_NAMES[k]
            L.hidden[k] = Model.dashHidden(prefs, k) or nil
        end
        L.save = function(order) prefs.dash_sections = order end
        L.hide = function(k) Model.setDashHidden(prefs, k, not Model.dashHidden(prefs, k)) end
        L.hint = _("Clock and info style. Tap a section, then use the arrows to move it. The eye shows or hides it.")
    elseif what == "dash_quick" or what == "dash_scenes" then
        local scenes = what == "dash_scenes"
        L.title = scenes and _("Dashboard scenes") or _("Dashboard Quick tiles")
        for __, e in ipairs(snap and (scenes and Model.dashScenes(snap, prefs) or Model.dashQuick(snap, prefs)) or {}) do
            table.insert(L.keys, e.id)
            L.labels[e.id] = e.name
        end
        L.save = function(order) prefs[what] = order end
        L.remove = function(k)
            local list = {}
            for __, id in ipairs(L.keys) do if id ~= k then table.insert(list, id) end end
            prefs[what] = list
        end
        L.hint = scenes and _("Tap one, then use the arrows to move it. The \u{2715} removes it. To add one, hold it: Quick & dashboard.")
            or _("Tap one, then use the arrows to move it. The \u{2715} removes it. To add one, hold a device: Quick & dashboard.")
    elseif what == "cameras" then
        L.title = _("Cameras")
        for __, e in ipairs(snap and Model.cameraList(snap, prefs, true) or {}) do
            table.insert(L.keys, e.id)
            L.labels[e.id] = e.name
        end
        L.hidden = prefs.cameras_hidden or {}
        L.save = function(order) prefs.camera_order = order end
        L.hide = function(k)
            prefs.cameras_hidden = prefs.cameras_hidden or {}
            prefs.cameras_hidden[k] = not prefs.cameras_hidden[k] or nil
        end
        L.hint = _("Cameras screen and the dashboard's rotation. Tap a camera, then use the arrows to move it. The eye shows or hides it.")
    elseif what == "security_cams" then
        L.title = _("Security cameras")
        for __, e in ipairs(snap and Model.securityCams(snap, prefs, true) or {}) do
            table.insert(L.keys, e.id)
            L.labels[e.id] = e.name
            L.hidden[e.id] = Model.securityHidden(snap, prefs, e) or nil
        end
        L.save = function(order) prefs.security_cams = order end
        L.hide = function(k)
            prefs.security_hidden = prefs.security_hidden or {}
            prefs.security_hidden[k] = not L.hidden[k]
        end
        L.hint = _("Security and the Security dashboard. Tap a camera, then use the arrows to move it. The eye shows or hides it.")
    elseif what == "sleep_alerts" then
        -- The chosen first (in their order), then the rest to choose from.
        L.title = _("Sleep screen alerts")
        local chosen = {}
        for __, id in ipairs(prefs.sleep_alerts or {}) do
            local e = snap and snap.byId[id]
            if e then
                table.insert(L.keys, id)
                L.labels[id] = e.name
                chosen[id] = true
            end
        end
        for __, e in ipairs(snap and Model.sleepAlertChoices(snap) or {}) do
            if not chosen[e.id] then
                table.insert(L.keys, e.id)
                L.labels[e.id] = e.name .. (e.area ~= "" and ("  \u{00B7}  " .. e.area) or "")
                L.hidden[e.id] = true
            end
        end
        local function keep(order)
            local list = {}
            for __, id in ipairs(order) do if not L.hidden[id] then table.insert(list, id) end end
            prefs.sleep_alerts = #list > 0 and list or nil
        end
        L.save = keep
        L.hide = function(k)
            L.hidden[k] = not L.hidden[k] or nil
            keep(L.keys)
        end
        L.hint = _("Shown on the sleep screen when they need attention; a sensor always. The eye picks one.")
    elseif what == "rooms" then
        L.title = _("Rooms")
        for __, r in ipairs(snap and Model.rooms(snap, prefs, true) or {}) do
            table.insert(L.keys, r.name)
            L.labels[r.name] = r.name
        end
        L.hidden = prefs.hidden_rooms or {}
        L.save = function(order) prefs.room_order = order end
        L.hide = function(k)
            prefs.hidden_rooms = prefs.hidden_rooms or {}
            prefs.hidden_rooms[k] = not prefs.hidden_rooms[k] or nil
        end
        L.hint = _("Tap a room to select it, then use the arrows to move it. Tap the eye to show or hide it.")
    else
        local room = view.route.room
        L.title = room
        for __, r in ipairs(snap and Model.rooms(snap, prefs, true) or {}) do
            if r.name == room then
                for __, e in ipairs(r.entities) do
                    table.insert(L.keys, e.id)
                    L.labels[e.id] = e.name
                end
            end
        end
        L.save = function(order)
            prefs.entity_order = prefs.entity_order or {}
            prefs.entity_order[room] = order
        end
        L.hide = function(k)
            prefs.hidden = prefs.hidden or {}
            prefs.shown = prefs.shown or {}
            prefs.hidden[k] = true
            prefs.shown[k] = nil
        end
        L.hint = _("Tap a device to select it, then use the arrows to move it within its group. Tap the eye to hide it (Settings > Devices shows it again).")
    end
    return L
end

function Settings.reorder(view, c)
    local L = reorderList(view)
    local ha = view.ha
    local sel = view.route.sel
    local F = c:flow(52, c.H - 8, view.pageNo)
    F:block(40, function(y) c:text(14, y + 16, L.hint, 10, { color = C.GREY, maxw = c.W - 28 }) end)
    for __, k in ipairs(L.keys) do
        F:block(44, function(y)
            local isSel = k == sel
            local hidden = L.hidden[k]
            local fg = isSel and C.ON_FILL or (hidden and C.MID or C.BLACK)
            if isSel then c:rect(0, y, c.W, 44, C.FILL) end
            c:icon("grip-vertical", 12, y + 13, 18, isSel)
            c:text(42, y + 27, L.labels[k] or k, 12.5, { bold = isSel, color = fg, maxw = c.W - (isSel and 300 or 220) })
            c:hit(0, y, isSel and c.W - 250 or c.W - 60, 44, function()
                view.route.sel = (sel ~= k) and k or nil
                view:refresh("ui")
            end)
            if isSel then
                -- To the top, up, down, to the bottom (the order before kept for Undo).
                local n = #L.keys
                for i, dir in ipairs({ { "arrow-up-to-line", -n }, { "arrow-up", -1 }, { "arrow-down", 1 }, { "arrow-down-to-line", n } }) do
                    local bx = c.W - 240 + (i - 1) * 46
                    c:box(bx, y + 7, 40, 30, { r = 6, fill = C.WHITE })
                    c:icon(dir[1], bx + 11, y + 13, 18)
                    c:hit(bx - 3, y, 46, 44, function()
                        view.route.undo = view.route.undo or {}
                        local before = {}
                        for j, key in ipairs(L.keys) do before[j] = key end
                        table.insert(view.route.undo, before)
                        L.save(Model.move(L.keys, k, dir[2]))
                        ha:savePrefs()
                        view:refresh("ui")
                    end)
                end
            end
            if L.hide then
                c:icon(hidden and "eye-off" or "eye", c.W - 36, y + 13, 18, isSel)
                c:hit(c.W - 52, y, 52, 44, function()
                    L.hide(k)
                    ha:savePrefs()
                    view:refresh("ui")
                end)
            elseif L.remove then
                c:icon("x", c.W - 36, y + 13, 18, isSel)
                c:hit(c.W - 52, y, 52, 44, function()
                    L.remove(k)
                    ha:savePrefs()
                    view:refresh("ui")
                end)
            end
            c:hline(0, y + 44, c.W)
        end)
    end
    if #L.keys == 0 then F:block(30, function(y) c:text(14, y + 20, _("Nothing here yet."), 11, { color = C.GREY }) end) end
    -- Undo: the order before the last move.
    local icons = {}
    if view.route.undo and #view.route.undo > 0 then
        icons = { { "undo-2", function()
            L.save(table.remove(view.route.undo))
            ha:savePrefs()
            view:refresh("ui")
        end } }
    end
    view:titlebar(c, true, L.title or "", icons, F:pages())
    return F:pages()
end

-- ------------------------------------------------------------------ devices

local KIND_NAMES = {
    light = _("light"), switch = _("switch"), fan = _("fan"), climate = _("thermostat"), lock = _("lock"), cover = _("cover"),
    vacuum = _("vacuum"), media_player = _("player"), camera = _("camera"), scene = _("scene"), script = _("script"),
    input_boolean = _("toggle"),
}

function Settings.devices(view, c, snap)
    local ha, prefs = view.ha, view.ha.prefs
    local filter, q = view.route.filter or "all", (view.route.query or ""):lower()
    local F = c:flow(52, c.H - 8, view.pageNo)
    F:block(70, function(y)
        local x = 14
        for __, f in ipairs({ { "all", _("All") }, { "shown", _("Shown") }, { "hidden", _("Hidden") } }) do
            local w = c:width(f[2], 11) + 28
            local sel = f[1] == filter
            c:box(x, y + 2, w, 30, { r = 15, fill = sel and C.FILL or C.WHITE, border = C.BLACK })
            c:text(x + w / 2, y + 21, f[2], 11, { align = "middle", color = sel and C.ON_FILL or C.BLACK })
            c:hit(x, y, w, 34, function()
                view.route.filter = f[1]
                view.pageNo = 1
                view:refresh("ui")
            end)
            x = x + w + 8
        end
        if q ~= "" then
            local label = T(_("“%1” ✕"), view.route.query)
            local w = c:width(label, 11) + 28
            c:box(x, y + 2, w, 30, { r = 15, border = C.BLACK })
            c:text(x + w / 2, y + 21, label, 11, { align = "middle" })
            c:hit(x, y, w, 34, function() view.route.query = nil view.pageNo = 1 view:refresh("ui") end)
        end
        c:text(14, y + 56, _("Configuration switches (LEDs, firmware, detection, mute) are hidden by default."), 10, { color = C.GREY })
    end)
    local groups = {}
    local byRoom = {}
    for __, r in ipairs(snap.rooms) do
        local g = { name = r.name, list = {} }
        byRoom[r.name] = g
        table.insert(groups, g)
    end
    local other = { name = _("Everything Else"), list = {} }
    table.insert(groups, other)
    for __, e in ipairs(snap.list) do
        local vis = Model.visible(e, prefs)
        if (filter == "all" or (filter == "shown") == vis) and
                (q == "" or (e.name .. " " .. e.id .. " " .. e.area):lower():find(q, 1, true)) then
            table.insert((byRoom[e.area] or other).list, e)
        end
    end
    for __, g in ipairs(groups) do
        if #g.list > 0 then
            F:block(22, function(y)
                c:rect(0, y, c.W, 22, C.PALE)
                c:text(14, y + 15, g.name:upper(), 9.5, { bold = true, color = C.GREY })
            end, 36)
            for __, e in ipairs(g.list) do
                F:block(36, function(y)
                    local vis = Model.visible(e, prefs)
                    if vis then
                        c:box(14, y + 10, 16, 16, { r = 3, fill = C.FILL })
                        c:icon("check", 16, y + 12, 12, true)
                    else
                        c:box(14, y + 10, 16, 16, { r = 3, border = C.BLACK, bw = 1.3 })
                    end
                    c:text(42, y + 23, e.name, 12, { color = vis and C.BLACK or C.MID, maxw = c.W - 140 })
                    c:text(c.W - 14, y + 23, KIND_NAMES[e.domain] or e.domain, 10, { align = "end", color = C.GREY })
                    c:hline(42, y + 36, c.W - 42)
                    c:hit(0, y, c.W, 36, function()
                        prefs.hidden = prefs.hidden or {}
                        prefs.shown = prefs.shown or {}
                        if vis then
                            prefs.hidden[e.id], prefs.shown[e.id] = true, nil
                        else
                            prefs.shown[e.id], prefs.hidden[e.id] = true, nil
                        end
                        ha:savePrefs()
                        view:refresh("ui")
                    end)
                end)
            end
        end
    end
    view:titlebar(c, true, _("Devices"), { { "search", function()
        input(_("Search devices"), view.route.query, "", function(t)
            view.route.query = t ~= "" and t or nil
            view.pageNo = 1
            view:refresh("ui")
        end)
    end } }, F:pages())
    return F:pages()
end

return Settings
