--[[--
Home Assistant on the web page (needs the Home Assistant plugin): addresses,
signing in through Home Assistant's own page (the browser goes there and
comes back with a code) or a pasted token, which devices show and which are
Quick tiles, the order of rooms, Quick tiles and Home's sections, the
plugin's settings, and a backup of them.
]]

local Common = require("webcommon")
local UIManager = require("ui/uimanager")

local Web = {}

local SECTIONS = {
    status = "Weather and attention bar", shortcuts = "Cameras, Media, Scenes, Dashboard", routines = "Routines",
    on = "On now", quick = "Quick", rooms = "Rooms",
}
local SECTION_KEYS = { "status", "shortcuts", "routines", "on", "quick", "rooms" }
-- The Clock and info dashboard's sections (the plugin's Model.DASH_SECTIONS).
local DASH_SECTIONS = {
    status = "Status bar", rooms = "Room temperatures", next = "Next up", media = "Now playing",
    tasks = "Today's tasks", scenes = "Scenes and routines", graph = "24-hour graph", camera = "Camera", quick = "Quick tiles",
}

-- Settings the page may change, and their kinds.
local PREFS = {
    ask_unlock = "boolean", ask_garage = "boolean", ask_scripts = "boolean",
    refresh_minutes = "number", dash_minutes = "number", dash_awake = "string", dash_camera = "string",
    dash_temps = "boolean", dash_attention = "boolean", start = "string",
    layout = "string", dash_layout = "string",
    doorbell = "string", wake_warning = "boolean", keep_off = "number", dash_graph = "string", auto_light = "boolean",
    stable_lists = "boolean",
}

local function ha() return Common.plugin("homeassistant") end

local function changed(h)
    h:savePrefs()
    if h.screen then h.screen:refresh("ui") end
end

local pending = {}  -- sign-ins sent to Home Assistant's page: state -> { base, client }

function Web.state(h)
    local Model = require("hamodel")
    local api, prefs, snap = h.api, h.prefs, h.snap
    local out = {
        installed = true,
        signedIn = api:signedIn(),
        method = api:get("token") and "token" or (api:get("refresh_token") and "signin") or nil,
        home = api:get("home_url") or "", away = api:get("away_url") or "", active = api:get("active") or "home",
        updated = h.updatedAt, error = h.error,
        prefs = {},
        devices = {}, rooms = {}, quick = {}, sections = {}, cameras = {}, shortcuts = {},
        dashSections = {}, dashQuick = {}, dashScenes = {}, securityCams = {}, cameraList = {}, graphSensors = {}, weathers = {}, sleepAlerts = {}, sleepAlertChoices = {},
        routines = prefs.routines or {}, routineDevices = {},
        quickSaved = prefs.quick ~= nil, dashQuickSaved = prefs.dash_quick ~= nil, dashScenesSaved = prefs.dash_scenes ~= nil,
    }
    for k in pairs(PREFS) do out.prefs[k] = prefs[k] end
    out.prefs.weather = prefs.weather
    out.placeholders = {}
    for id, v in pairs(prefs.placeholders or {}) do table.insert(out.placeholders, { id = id, value = v }) end
    if not snap then return out end
    local quick = {}
    for __, s in ipairs(Model.shortcuts and Model.shortcuts(snap, prefs, true) or {}) do
        table.insert(out.shortcuts, { key = s.key, name = s.label, hidden = s.hidden or false, icon = s.icon })
    end
    for __, e in ipairs(Model.quick(snap, prefs)) do
        table.insert(out.quick, { id = e.id, name = e.name })
        quick[e.id] = true
    end
    for __, e in ipairs(snap.list) do
        table.insert(out.devices, {
            id = e.id, name = e.name, domain = e.domain, area = e.area, state = Model.stateText(e), changed = Model.changedText and Model.changedText(snap, e) or nil,
            visible = Model.visible(e, prefs), primary = Model.isPrimary(e), quick = quick[e.id] or false,
        })
        if e.domain == "camera" then table.insert(out.cameras, { id = e.id, name = e.name }) end
    end
    for __, r in ipairs(Model.rooms(snap, prefs, true)) do
        table.insert(out.rooms, { name = r.name, hidden = r.hidden or false, count = #r.entities })
    end
    for __, k in ipairs(Model.ordered(SECTION_KEYS, prefs.sections, function(s) return s end)) do
        table.insert(out.sections, { key = k, name = SECTIONS[k], hidden = (prefs.hidden_sections or {})[k] or false })
    end
    -- The dashboard's sections, tiles and scene buttons, and Security's cameras
    -- (an older Home Assistant plugin has none of them).
    if Model.dashSections then
        for __, k in ipairs(Model.dashSections(prefs)) do
            table.insert(out.dashSections, { key = k, name = DASH_SECTIONS[k] or k, hidden = Model.dashHidden(prefs, k) })
        end
        for __, e in ipairs(Model.dashQuick(snap, prefs)) do table.insert(out.dashQuick, { id = e.id, name = e.name }) end
        for __, e in ipairs(Model.dashScenes(snap, prefs)) do table.insert(out.dashScenes, { id = e.id, name = e.name }) end
    end
    -- What a routine's step can be: a shown device, and what it can do.
    local okr, Routines = pcall(require, "haroutines")
    if okr then
        for __, e in ipairs(snap.list) do
            local actions = Model.visible(e, prefs) and Routines.actions(e) or {}
            if #actions > 0 then
                table.insert(out.routineDevices, { id = e.id, name = e.name, area = e.area, actions = actions })
            end
        end
        table.sort(out.routineDevices, function(a, b) return a.name < b.name end)
    end
    for __, e in ipairs(Model.graphSensors and Model.graphSensors(snap) or {}) do
        table.insert(out.graphSensors, { id = e.id, name = e.name .. (e.area ~= "" and (" \u{00B7} " .. e.area) or "") })
    end
    for __, w in ipairs(snap.weathers or {}) do table.insert(out.weathers, { id = w.id, name = w.name }) end
    if Model.sleepAlertChoices then
        for __, id in ipairs(prefs.sleep_alerts or {}) do
            local e = snap.byId[id]
            if e then table.insert(out.sleepAlerts, { id = id, name = e.name }) end
        end
        for __, e in ipairs(Model.sleepAlertChoices(snap)) do
            table.insert(out.sleepAlertChoices, { id = e.id, name = e.name, area = e.area })
        end
    end
    if Model.cameraList then
        for __, e in ipairs(Model.cameraList(snap, prefs, true)) do
            table.insert(out.cameraList, { id = e.id, name = e.name, hidden = (prefs.cameras_hidden or {})[e.id] == true })
        end
    end
    if Model.securityCams then
        for __, e in ipairs(Model.securityCams(snap, prefs, true)) do
            table.insert(out.securityCams, { id = e.id, name = e.name, hidden = Model.securityHidden(snap, prefs, e) })
        end
    end
    return out
end

function Web.routes(server)
    server:route("GET", "^/api/ha$", function(req, res)
        local h = ha()
        if not h then return res:json({ installed = false }) end
        res:json(Web.state(h))
    end)

    server:route("POST", "^/api/ha/addresses$", function(req, res)
        local h = ha()
        if not h then return res:error(404, "The Home Assistant plugin isn't installed") end
        local Api = require("haapi")
        local b = req.json()
        local home, away = Api.cleanUrl(b.home), Api.cleanUrl(b.away)
        h.api:set("home_url", home or away)
        h.api:set("away_url", home and away or nil)
        h.api.settings.save()
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/ha/token$", function(req, res)
        local h = ha()
        if not h then return res:error(404, "The Home Assistant plugin isn't installed") end
        local ok, why = h.api:useToken(req.json().token)
        if not ok then return res:error(400, why) end
        h.error = nil
        UIManager:nextTick(function() h:update(true) end)
        res:json({ ok = true })
    end)

    -- Sign in on Home Assistant's own page: the browser is sent there and
    -- comes back to /ha/callback with a code. The client is this page.
    server:route("GET", "^/api/ha/signin$", function(req, res)
        local h = ha()
        if not h then return res:error(404, "The Home Assistant plugin isn't installed") end
        local Api = require("haapi")
        local base = Api.cleanUrl(req.query.base) or h.api:get("home_url")
        if not base then return res:error(400, "Enter the address first") end
        local origin = "http://" .. (req.headers.host or "")
        local state = tostring(math.random(100000000, 999999999))
        pending[state] = { base = base, client = origin .. "/" }
        local function q(s) return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)) end
        res:json({ url = base .. "/auth/authorize?response_type=code&client_id=" .. q(origin .. "/") ..
            "&redirect_uri=" .. q(origin .. "/ha/callback") .. "&state=" .. state })
    end)

    server:route("GET", "^/ha/callback$", function(req, res)
        local h = ha()
        local p = pending[req.query.state or ""]
        if not h or not p or not req.query.code then return res:redirect("/#ha?signin=failed") end
        pending[req.query.state] = nil
        local ok, why = h.api:exchange(p.base, req.query.code, p.client)
        if ok ~= "done" then
            local text = type(why) == "table" and why.message or tostring(why)
            return res:redirect("/#ha?signin=failed&why=" .. (text:gsub("[^%w%-%._~]", function(ch) return string.format("%%%02X", ch:byte()) end)))
        end
        if not h.api:get("home_url") then h.api:set("home_url", p.base) h.api.settings.save() end
        h.error = nil
        UIManager:nextTick(function() h:update(true) end)
        res:redirect("/#ha?signin=ok")
    end)

    server:route("POST", "^/api/ha/signout$", function(req, res)
        local h = ha()
        if h then h:signOut() end
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/ha/refresh$", function(req, res)
        local h = ha()
        if not h then return res:error(404, "The Home Assistant plugin isn't installed") end
        if not h.api:signedIn() then return res:error(400, "Sign in first") end
        UIManager:nextTick(function() h:update(true) end)
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/ha/prefs$", function(req, res)
        local h = ha()
        if not h then return res:error(404, "The Home Assistant plugin isn't installed") end
        local b = req.json()
        for k, v in pairs(Common.pick(b, PREFS)) do h.prefs[k] = v end
        if b.dash_graph == "auto" then h.prefs.dash_graph = nil end
        if b.weather ~= nil and b.weather ~= h.prefs.weather then
            h.prefs.weather = b.weather ~= "auto" and b.weather or nil
            h.forecast, h.forecastAt, h.hourly, h.hourlyAt = nil, nil, nil, nil
            UIManager:nextTick(function() h:update(true) end)
        end
        if type(b.sections) == "table" then
            h.prefs.sections = b.sections
            h.prefs.hidden_sections = Common.fromList(b.hidden_sections)
        end
        if type(b.rooms) == "table" then
            h.prefs.room_order = b.rooms
            h.prefs.hidden_rooms = Common.fromList(b.hidden_rooms)
        end
        if type(b.shortcuts) == "table" then
            h.prefs.shortcuts = b.shortcuts
            local hidden = {}
            for __, k in ipairs(b.shortcuts) do hidden[k] = false end
            for __, k in ipairs(type(b.hidden_shortcuts) == "table" and b.hidden_shortcuts or {}) do hidden[k] = true end
            h.prefs.hidden_shortcuts = hidden
        end
        if type(b.placeholders) == "table" then
            h.prefs.placeholders = h.prefs.placeholders or {}
            for id, v in pairs(b.placeholders) do
                h.prefs.placeholders[id] = (v == "door" or v == "garage" or v == "room" or v == "printer") and v or nil
            end
        end
        if b.quick == false then h.prefs.quick = nil
        elseif type(b.quick) == "table" then h.prefs.quick = b.quick end
        local Model = require("hamodel")
        if type(b.dash_sections) == "table" and Model.setDashHidden then
            h.prefs.dash_sections = b.dash_sections
            local hidden = Common.fromList(b.dash_hidden)
            for __, k in ipairs(b.dash_sections) do Model.setDashHidden(h.prefs, k, hidden[k] == true) end
        end
        if b.sleep_alerts == false then h.prefs.sleep_alerts = nil
        elseif type(b.sleep_alerts) == "table" then h.prefs.sleep_alerts = #b.sleep_alerts > 0 and b.sleep_alerts or nil end
        for __, key in ipairs({ "dash_quick", "dash_scenes" }) do
            if b[key] == false then h.prefs[key] = nil
            elseif type(b[key]) == "table" then h.prefs[key] = b[key] end
        end
        if type(b.camera_order) == "table" then
            h.prefs.camera_order = b.camera_order
            h.prefs.cameras_hidden = Common.fromList(b.cameras_hidden)
        end
        if type(b.security_cams) == "table" then
            -- Each camera shown or hidden as set (a printer's starts hidden otherwise).
            h.prefs.security_cams = b.security_cams
            local hidden = Common.fromList(b.security_hidden)
            h.prefs.security_hidden = {}
            for __, id in ipairs(b.security_cams) do h.prefs.security_hidden[id] = hidden[id] == true end
        end
        if b.refresh_minutes or b.dash_minutes then h:schedule() end
        changed(h)
        res:json({ ok = true })
    end)

    -- The routines, all of them: { routines = { { id, name, steps = { { id, service, label } } } } }.
    -- Only steps a device can do are kept.
    server:route("POST", "^/api/ha/routines$", function(req, res)
        local h = ha()
        if not h then return res:error(404, "The Home Assistant plugin isn't installed") end
        local b = req.json()
        if type(b.routines) ~= "table" then return res:error(400, "No routines") end
        local Routines = require("haroutines")
        local list = {}
        for __, r in ipairs(b.routines) do
            if type(r) == "table" and type(r.name) == "string" and r.name:match("%S") then
                local steps = {}
                for __, st in ipairs(type(r.steps) == "table" and r.steps or {}) do
                    local e = type(st) == "table" and h.snap and h.snap.byId[st.id]
                    if e then
                        for __, a in ipairs(Routines.actions(e)) do
                            if a[2] == st.service then table.insert(steps, { id = e.id, service = a[2], label = a[1] }) end
                        end
                    end
                end
                table.insert(list, { id = type(r.id) == "string" and r.id ~= "" and r.id or (tostring(os.time()) .. tostring(math.random(100, 999))),
                    name = r.name:match("^%s*(.-)%s*$"), steps = steps })
            end
        end
        h.prefs.routines = list
        changed(h)
        res:json({ ok = true, routines = list })
    end)

    -- Runs a routine now (the page asked first where the Kindle would).
    server:route("POST", "^/api/ha/routines/run$", function(req, res)
        local h = ha()
        if not h then return res:error(404, "The Home Assistant plugin isn't installed") end
        local Routines = require("haroutines")
        local r = Routines.find(h.prefs, req.json().id)
        if not r then return res:error(404, "No such routine") end
        Routines.run(h, r, true)
        res:json({ ok = true })
    end)

    -- Devices shown or hidden: { changes = { { id, visible } } }.
    server:route("POST", "^/api/ha/devices$", function(req, res)
        local h = ha()
        if not h or not h.snap then return res:error(404, "No devices yet") end
        local Model = require("hamodel")
        h.prefs.hidden = h.prefs.hidden or {}
        h.prefs.shown = h.prefs.shown or {}
        for __, c in ipairs(req.json().changes or {}) do
            local e = h.snap.byId[c.id]
            if e then
                h.prefs.hidden[e.id], h.prefs.shown[e.id] = nil, nil
                if c.visible ~= Model.isPrimary(e) then
                    if c.visible then h.prefs.shown[e.id] = true else h.prefs.hidden[e.id] = true end
                end
            end
        end
        changed(h)
        res:json({ ok = true })
    end)

    server:route("GET", "^/api/ha/backup$", function(req, res)
        local h = ha()
        if not h then return res:error(404, "The Home Assistant plugin isn't installed") end
        local p = h.prefs
        res:json({
            kind = "koreader-homeassistant", version = 1,
            home = h.api:get("home_url"), away = h.api:get("away_url"),
            prefs = p, hidden = Common.set(p.hidden), shown = Common.set(p.shown),
            hidden_rooms = Common.set(p.hidden_rooms), hidden_sections = Common.set(p.hidden_sections),
        })
    end)

    server:route("POST", "^/api/ha/restore$", function(req, res)
        local h = ha()
        local b = req.json()
        if not h or b.kind ~= "koreader-homeassistant" or type(b.prefs) ~= "table" then return res:error(400, "That file isn't a Home Assistant backup") end
        local p = b.prefs
        p.hidden, p.shown = Common.fromList(b.hidden), Common.fromList(b.shown)
        p.hidden_rooms, p.hidden_sections = Common.fromList(b.hidden_rooms), Common.fromList(b.hidden_sections)
        h.prefs = p
        if b.home then h.api:set("home_url", b.home) end
        if b.away then h.api:set("away_url", b.away) end
        h.api.settings.save()
        changed(h)
        res:json({ ok = true })
    end)
end

return Web
