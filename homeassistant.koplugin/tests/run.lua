-- Plain Lua tests: `luajit tests/run.lua` from the plugin folder.
package.path = "./?.lua;./tests/?.lua;" .. package.path
package.loaded["hatemplate"] = { ALL = "{{ template }}", all = function() return "{{ template }}" end }
local Model = require("hamodel")
local Api = require("haapi")
local json = require("json")

local failed, passed = 0, 0
local function check(name, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    end
end

-- KOReader's decoder gives JSON null as a sentinel function, not nil.
local NULL = function() end

local NOW = 1800000000
local data = {
    v = 1, now = NOW,
    e = {
        { "light.living_room_lights", "Living Room Lights", "on", "Living Room", "", NOW - 600,
            { { "brightness", 255 }, { "supported_color_modes", { "color_temp" } }, { "min_color_temp_kelvin", 2000 },
              { "max_color_temp_kelvin", 6500 }, { "entity_id", { "light.living_room_1", "light.living_room_2" } } } },
        { "light.living_room_1", "Living Room 1", "on", "Living Room", "Living Room 1", NOW, { { "brightness", 128 }, { "supported_color_modes", { "brightness" } } } },
        { "light.living_room_2", "Living Room 2", "off", "Living Room", "Living Room 2", NOW, {} },
        { "switch.candle", "Candle", "on", "Living Room", "Candle", NOW, {} },
        { "switch.candle_led", "Candle LED", "on", "Living Room", "Candle", NOW, {} },
        { "switch.tablet_charger", "Tablet Charger", "off", "Kitchen", "", NOW, {} },
        { "climate.thermostat", "Thermostat", "off", "Living Room", "Thermostat", NOW,
            { { "hvac_modes", { "off", "heat", "cool", "heat", "heat_cool" } }, { "current_temperature", 70 }, { "current_humidity", 36 }, { "temperature", 68 } } },
        { "fan.tower_fan", "Bedroom Fan", "on", "Bedroom", "Bedroom Fan", NOW, { { "percentage", 50 }, { "percentage_step", 16.666 } } },
        { "lock.front_door", "Front Door", "locked", "Foyer", "Front Door", NOW, {} },
        { "lock.back_door", "Back Door", "locked", "Utility Room", "Back Door", NOW, {} },
        { "cover.garage", "Garage Door", "closed", "Garage", "Garage", NOW - 900, { { "device_class", "garage" } } },
        { "media_player.living_room_tv", "Living Room TV", "on", "Living Room", "Living Room TV", NOW, { { "source", "YouTube" } } },
        { "media_player.tvs", "TVs", "on", "House", "", NOW, { { "entity_id", { "media_player.living_room_tv" } } } },
        { "vacuum.robot", "Robot Vacuum", "docked", "Dining Room", "Robot Vacuum", NOW, { { "battery_level", 100 } } },
        { "script.backup", "Nightly Backup", "off", "", "", NOW, {} },
        { "camera.doorbell", "Doorbell", "idle", "Foyer", "Doorbell", NOW, {} },
        { "switch.doorbell", "Doorbell", "on", "Foyer", "Doorbell", NOW, {} },
        { "sensor.ignored", "Not a control", "1", "", "", NOW, {} },
        { "light.gone", "Gone", "unavailable", "Bedroom", "Gone", NOW, {} },
        { "sensor.kitchen_temp", "Kitchen Temperature", "69.44", "Kitchen", "Kitchen Sensor", NOW,
            { { "device_class", "temperature" }, { "unit_of_measurement", "\194\176F" } } },
        { "sensor.kitchen_battery", "Kitchen Battery", "100", "Kitchen", "Kitchen Sensor", NOW,
            { { "device_class", "battery" }, { "unit_of_measurement", "%" } } },
        { "binary_sensor.robot_vacuum_water", "Robot Vacuum Water shortage", "on", "Dining Room", "Robot Vacuum", NOW, { { "device_class", "problem" } } },
        { "binary_sensor.patio", "Patio Door", "off", "Living Room", "Patio", NOW, { { "device_class", "door" } } },
    },
    r = { { "Foyer", "Ground Floor", NULL, NULL }, { "Living Room", "", 70.5, 36 }, { "Kitchen", "", 69.08, 46 },
          { "Bedroom", "2nd Floor", 68.54, 46 }, { "Gym", "", 69.6, 45 }, { "Garage", "Outside", NULL, NULL },
          { "Utility Room", "", NULL, NULL }, { "Dining Room", "", NULL, NULL } },
    d = {}, b = {},
    w = { "clear-night", 59, "°F", "weather.forecast_home" },
}

local snap = Model.parse(data)
check("parsed entities (and sensors)", #snap.list, 23)
check("nulls are nil", snap.rooms[1].temp, nil)
check("weather", snap.weather.temp, 59)
check("weather id", snap.weather.id, "weather.forecast_home")
check("bad snapshot", Model.parse({ e = "x" }), nil)
local wsnap = Model.parse({ v = 1, now = 1, e = {}, ws = { { "weather.home", "Home" }, { "weather.cabin" } } })
check("weather choices", wsnap and #wsnap.weathers, 2)
check("weather name falls back to id", wsnap and wsnap.weathers[2].name, "weather.cabin")

local P = {}
local E = snap.byId
check("switch named as its device is shown", Model.visible(E["switch.candle"], P), true)
check("a device's setting switch starts hidden", Model.visible(E["switch.candle_led"], P), false)
check("switch with no device is shown", Model.visible(E["switch.tablet_charger"], P), true)
check("player groups start hidden", Model.visible(E["media_player.tvs"], P), false)
check("a camera's own switch starts hidden", Model.visible(E["switch.doorbell"], P), false)
check("shown by hand", Model.visible(E["switch.candle_led"], { shown = { ["switch.candle_led"] = true } }), true)
check("hidden by hand", Model.visible(E["switch.candle"], { hidden = { ["switch.candle"] = true } }), false)

check("light state", Model.stateText(E["light.living_room_lights"]), "On · 100%")
check("dim light", Model.stateText(E["light.living_room_1"]), "On · 50%")
check("thermostat state", Model.stateText(E["climate.thermostat"]), "Off · 70°")
check("fan state", Model.stateText(E["fan.tower_fan"]), "On · 50%")
check("player state", Model.stateText(E["media_player.living_room_tv"]), "On · YouTube")
check("vacuum full battery", Model.stateText(E["vacuum.robot"]), "Docked")
check("unavailable", Model.stateText(E["light.gone"]), "Unavailable")
check("garage icon", Model.icon(E["cover.garage"]), "warehouse")
check("tv icon", Model.icon(E["media_player.living_room_tv"]), "tv")

-- Taps.
local a = Model.tapAction(E["light.living_room_1"], P)
check("light toggles", a.service, "light.toggle")
check("light no question", a.confirm, nil)
a = Model.tapAction(E["lock.front_door"], P)
check("unlock", a.service, "lock.unlock")
check("unlock asks", a.confirm, "Unlock Front Door?")
check("unlock without asking", Model.tapAction(E["lock.front_door"], { ask_unlock = false }).confirm, nil)
check("garage opens", Model.tapAction(E["cover.garage"], P).service, "cover.open_cover")
check("garage asks", Model.tapAction(E["cover.garage"], P).confirm, "Open Garage Door?")
check("script asks", Model.tapAction(E["script.backup"], P).confirm, "Run Nightly Backup?")
check("thermostat opens its controls", Model.tapAction(E["climate.thermostat"], P).sheet, true)
check("camera takes a picture", Model.tapAction(E["camera.doorbell"], P).camera, true)
check("unavailable opens controls", Model.tapAction(E["light.gone"], P).sheet, true)
check("expected after toggle", Model.expected(E["light.living_room_1"], "light.toggle"), "off")
check("expected after unlock", Model.expected(E["lock.front_door"], "lock.unlock"), "unlocking")

-- Orders.
local o = Model.ordered({ "a", "b", "c", "d" }, { "c", "a" }, function(x) return x end)
check("saved order first, rest after", table.concat(o, ""), "cabd")
check("move up", table.concat(Model.move({ "a", "b", "c" }, "c", -1), ""), "acb")
check("move past the top stays", table.concat(Model.move({ "a", "b", "c" }, "a", -1), ""), "abc")

-- Rooms.
local rooms = Model.rooms(snap, P)
local names = {}
for __, r in ipairs(rooms) do table.insert(names, r.name) end
check("rooms with something to show, in order", table.concat(names, ","),
    "Foyer,Living Room,Kitchen,Bedroom,Garage,Utility Room,Dining Room,Everything Else")
rooms = Model.rooms(snap, { room_order = { "Kitchen" }, hidden_rooms = { Foyer = true } })
check("saved room order", rooms[1].name, "Kitchen")
check("hidden room left out", rooms[2].name, "Living Room")
check("hidden rooms with withHidden", #Model.rooms(snap, { hidden_rooms = { Foyer = true } }, true), 8)
local living
for __, r in ipairs(Model.rooms(snap, P)) do if r.name == "Living Room" then living = r end end
check("living room summary", Model.roomSummary(living), "2 on · 70.5°")
local garage
for __, r in ipairs(Model.rooms(snap, P)) do if r.name == "Garage" then garage = r end end
check("garage summary", Model.roomSummary(garage), "closed")
check("kinds", Model.kinds(living.entities)[1].title, "LIGHTS")
check("groups first, then by name", living.entities[1].name .. "," .. living.entities[2].name, "Living Room Lights,Candle")

-- On now: members, not groups; hidden left out.
local on = Model.onNow(snap, P)
local onNames = {}
for __, e in ipairs(on) do table.insert(onNames, e.name) end
check("on now", table.concat(onNames, ","), "Living Room 1,Candle,Bedroom Fan,Living Room TV")
-- Just turned off here: kept in On now, in its place.
do
    local candle
    for __, e in ipairs(on) do if e.name == "Candle" then candle = e end end
    local was = candle.state
    candle.state = "off"
    local names = {}
    for __, e in ipairs(Model.onNow(snap, P, { [candle.id] = true })) do table.insert(names, e.name) end
    check("on now keeps turned off", table.concat(names, ","), "Living Room 1,Candle,Bedroom Fan,Living Room TV")
    check("on now without keep", #Model.onNow(snap, P), 3)
    candle.state = was
end

-- Quick: locks, garage, thermostat, vacuum, light groups.
local q = Model.quick(snap, P)
check("quick default first", q[1].id, "lock.back_door")
check("quick default count", #q, 6)
check("quick saved", Model.quick(snap, { quick = { "fan.tower_fan", "nope" } })[1].id, "fan.tower_fan")
check("quick saved skips gone", #Model.quick(snap, { quick = { "fan.tower_fan", "nope" } }), 1)

-- The dashboard: sections, its own tiles and scene buttons, the player.
check("dash sections default", table.concat(Model.dashSections({}), ","), "status,rooms,next,media,tasks,scenes,graph,camera,quick")
check("dash sections saved first", Model.dashSections({ dash_sections = { "quick", "status" } })[1], "quick")
check("tasks start hidden", Model.dashHidden({}, "tasks"), true)
check("status bar switch", Model.dashHidden({ dash_attention = false }, "status"), true)
local DP = {}
Model.setDashHidden(DP, "rooms", true)
Model.setDashHidden(DP, "tasks", false)
check("rooms hidden by its switch", DP.dash_temps, false)
check("tasks shown", Model.dashHidden(DP, "tasks"), false)
check("dash tiles default to Quick", Model.dashQuick(snap, P)[1].id, "lock.back_door")
check("dash tiles saved", #Model.dashQuick(snap, { dash_quick = { "fan.tower_fan", "nope" } }), 1)
check("dash scenes default", Model.dashScenes(snap, P)[1].id, "script.backup")
check("scene button", Model.isSceneButton(E["script.backup"]), true)
local tv = E["media_player.living_room_tv"]
check("nothing playing", Model.nowPlaying(snap, P), nil)
tv.state, tv.attr.supported_features, tv.attr.media_title = "playing", 1 + 16 + 32 + 16384, "Song"
check("now playing", Model.nowPlaying(snap, P).id, tv.id)
local mb = {}
for __, b in ipairs(Model.mediaButtons(tv)) do table.insert(mb, b[1]) end
check("player buttons", table.concat(mb, ","), "skip-back,pause,skip-forward")
check("playing text", Model.playingText(tv), "Song")
tv.state, tv.attr.supported_features, tv.attr.media_title = "on", nil, nil

-- Waking: locks open, the garage, doors.
check("wake issues", #Model.wakeIssues(snap, P) >= 0, true)

-- Attention.
E["binary_sensor.robot_vacuum_water"].state = "off"
local att = Model.attention(snap, P)
check("all clear", att.text, "All 2 doors locked · Garage closed")
check("all clear ok", att.ok, true)
E["binary_sensor.robot_vacuum_water"].state = "on"
E["lock.back_door"].state = "unlocked"
E["cover.garage"].state = "open"
snap.doors = { { name = "Patio Door", since = NOW - 300 } }
snap.batteries = { { name = "Hall Sensor Battery", percent = 8 } }
att = Model.attention(snap, P)
check("issues", att.text, "Back Door unlocked · Garage Door open 15 min · Robot Vacuum Water shortage problem · Patio Door open 5 min · Hall Sensor Battery 8%")
check("issues not ok", att.ok, false)
E["lock.back_door"].state = "locked"
E["cover.garage"].state = "closed"

-- Sensors.
check("temperature shown", Model.visible(E["sensor.kitchen_temp"], P), true)
check("battery starts hidden", Model.visible(E["sensor.kitchen_battery"], P), false)
check("problem starts hidden", Model.visible(E["binary_sensor.robot_vacuum_water"], P), false)
check("door shown", Model.visible(E["binary_sensor.patio"], P), true)
check("temperature text", Model.stateText(E["sensor.kitchen_temp"]), "69.4\194\176F")
check("percent text", Model.stateText(E["sensor.kitchen_battery"]), "100%")
check("door text", Model.stateText(E["binary_sensor.patio"]), "Closed")
check("sensor opens its sheet", Model.tapAction(E["sensor.kitchen_temp"], P).sheet, true)
check("door icon", Model.icon(E["binary_sensor.patio"]), "door-closed")
check("short name", Model.shortName({ name = "Kitchen Sensor Humidity", device = "Kitchen Sensor" }), "Humidity")
check("doorbell placeholder", Model.placeholder({ id = "camera.front_door", name = "Doorbell" }), "door")
check("garage placeholder", Model.placeholder({ id = "camera.floodlight", name = "Floodlight Camera" }), "garage")
check("printer placeholder", Model.placeholder({ id = "camera.study_3d_printer_camera", name = "3D Printer Camera" }), "printer")
check("picked placeholder", Model.placeholder({ id = "camera.living_room", name = "Living Room" }, { placeholders = { ["camera.living_room"] = "garage" } }), "garage")
check("room placeholder", Model.placeholder({ id = "camera.living_room", name = "Living Room Camera" }), "room")
check("short name kept", Model.shortName({ name = "Candle", device = "Candle" }), "Candle")
check("sensors not on now", #Model.onNow(snap, P), 4)

-- Shortcuts: the default ones with something to show, in order; picked ones.
local function keys(list) local out = {} for i, x in ipairs(list) do out[i] = x.key end return table.concat(out, ",") end
check("default shortcuts", keys(Model.shortcuts(snap, P)), "lights,climate,switches,sensors,cameras,media,scenes,dashboard,security")
check("all shortcuts", keys(Model.shortcuts(snap, P, true)), "lights,climate,switches,sensors,cameras,media,scenes,dashboard,security,doors,vacuums,weather,activity,batteries")
check("shortcuts picked and ordered", keys(Model.shortcuts(snap, { shortcuts = { "doors", "lights" }, hidden_shortcuts = { doors = false, media = true } })),
    "doors,lights,climate,switches,sensors,cameras,scenes,dashboard,security")

-- Light colours: the named one closest to what it shows, and what a swatch sends.
do
    local red = { state = "on", attr = { supported_color_modes = { "color_temp", "hs" }, color_mode = "hs", hs_color = { 0, 100 }, brightness = 255,
        min_color_temp_kelvin = 2000, max_color_temp_kelvin = 6500 } }
    check("bedroom red", Model.colorOf(red).name, "Red")
    check("red in the state line", Model.stateText({ domain = "light", state = "on", attr = red.attr }), "On · Red · 100%")
    check("hue 350 is red", Model.colorOf({ state = "on", attr = { supported_color_modes = { "hs" }, color_mode = "hs", hs_color = { 350, 90 } } }).name, "Red")
    check("pale pink", Model.colorOf({ state = "on", attr = { supported_color_modes = { "hs" }, color_mode = "hs", hs_color = { 330, 55 } } }).name, "Pink")
    check("warm white by kelvin", Model.colorOf({ state = "on", attr = { supported_color_modes = { "color_temp", "hs" }, color_mode = "color_temp", color_temp_kelvin = 2700 } }).name, "Warm white")
    check("whites sent as kelvin", Model.colorData(red, Model.COLORS[9]).color_temp_kelvin, 2700)
    check("colours sent as hs", Model.colorData(red, Model.COLORS[6]).hs_color[1], 240)
    check("white-only light: no colours", Model.hasColor({ attr = { supported_color_modes = { "color_temp" } } }), false)
    check("off: no colour", Model.colorOf({ state = "off", attr = red.attr }), nil)
end

-- A player's power: an LG TV without Wake-on-LAN can only be turned off.
do
    local on, off = Model.power({ attr = { supported_features = 24381 } })
    check("LG TV: no turn on", on, false)
    check("LG TV: turn off", off, true)
    on, off = Model.power({ attr = { supported_features = 152461 } })
    check("speaker: on and off", tostring(on) .. tostring(off), "truetrue")
    check("no features", select(1, Model.power({ attr = {} })), false)
end

-- Screens of their own: batteries lowest first, the printer (only the device
-- that prints), a printer's buttons, forecast days.
do
    local t0 = 1760000000
    local s2 = Model.parse({ now = t0, e = {
        { "sensor.a_battery", "A Battery", "80", "Hall", "A", t0 - 60, { { "device_class", "battery" }, { "unit_of_measurement", "%" } } },
        { "sensor.b_battery", "B Battery", "12", "", "B", t0 - 600, { { "device_class", "battery" }, { "unit_of_measurement", "%" } } },
        { "sensor.study_3d_printer_nozzle_temperature", "Nozzle", "210", "Study", "SN1", t0, { { "device_class", "temperature" } } },
        { "sensor.study_3d_printer_print_progress", "Progress", "42", "Study", "SN1", t0, {} },
        { "button.study_3d_printer_cancel_print", "Cancel print", "unknown", "Study", "SN1", t0, {} },
        { "sensor.3d_printer_host_cpu", "CPU", "18", "", "3D Printer Host", t0, {} },
        { "switch.lxc_3d_printer_ui", "Web UI", "on", "", "Proxmox", t0, {} },
        { "camera.study_3d_printer_camera", "3D Printer Camera", "idle", "Study", "SN1", t0, {} },
        { "camera.living_room_live_view", "Living Room Live view", "idle", "Living Room", "Living Room Camera", t0, {} },
        { "camera.front_door_hd_stream", "Doorbell HD Stream", "idle", "Foyer", "Front Door", t0, {} },
    } })
    local function camIds(list) local o = {} for __, e in ipairs(list) do table.insert(o, e.id:match("camera%.(%w+)")) end return table.concat(o, ",") end
    check("security leaves out the printer camera", camIds(Model.securityCams(s2, {})), "living,front")
    check("dashboard camera first", camIds(Model.securityCams(s2, { dash_camera = "camera.front_door_hd_stream" })), "front,living")
    check("security order and shown", camIds(Model.securityCams(s2, { security_cams = { "camera.study_3d_printer_camera" }, security_hidden = { ["camera.study_3d_printer_camera"] = false } })), "study,living,front")
    check("all keeps hidden", #Model.securityCams(s2, {}, true), 3)
    check("cameras: the printer's last", camIds(Model.cameraList(s2, {})), "living,front,study")
    check("cameras in their order", camIds(Model.cameraList(s2, { camera_order = { "camera.front_door_hd_stream" } })), "front,living,study")
    check("cameras hidden there", #Model.cameraList(s2, { cameras_hidden = { ["camera.living_room_live_view"] = true } }), 2)
    -- The doorbell: its ring sensor and the motion on the same device.
    local s3 = Model.parse({ now = t0, e = {
        { "camera.front_door_hd_stream", "Doorbell HD Stream", "idle", "Foyer", "Front Door", t0, {} },
        { "binary_sensor.front_door_doorbell", "Doorbell", "off", "Foyer", "Front Door", t0, { { "device_class", "sound" } } },
        { "binary_sensor.front_door_motion", "Motion", "off", "Foyer", "Front Door", t0, { { "device_class", "motion" } } },
        { "binary_sensor.garage_floodlight_motion", "Motion", "off", "Garage", "Floodlight", t0, { { "device_class", "motion" } } },
        { "camera.floodlight", "Floodlight", "idle", "Garage", "Floodlight", t0, {} },
    } })
    local bells = Model.doorbells(s3)
    check("doorbell ring", bells["binary_sensor.front_door_doorbell"].kind, "ring")
    check("doorbell motion", bells["binary_sensor.front_door_motion"].camera, "camera.front_door_hd_stream")
    check("not a doorbell's motion", bells["binary_sensor.garage_floodlight_motion"], nil)
    -- A day by the hour: averages, the last reading kept through quiet hours.
    local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%S+00:00", t) end
    local hr = Model.hourly({ { state = "70", last_changed = iso(t0 - 30 * 3600) }, { state = "72", last_changed = iso(t0 - 90 * 60) },
        { state = "74", last_changed = iso(t0 - 80 * 60) }, { state = "unavailable", last_changed = iso(t0 - 70 * 60) } }, t0, 24)
    check("hourly first hour keeps the reading before", hr.values[1], 70)
    check("hourly average", hr.values[23], 73)
    check("hourly quiet hour keeps the last", hr.values[24], 74)
    check("hourly range", hr.min .. "-" .. hr.max, "70-74")
    local b = Model.batteryList(s2, {})
    check("batteries lowest first", b[1].e.id .. "," .. b[2].e.id, "sensor.b_battery,sensor.a_battery")
    local ids = {}
    for __, e in ipairs(Model.printer(s2, {})) do table.insert(ids, e.id) end
    table.sort(ids)
    check("printer: only the printing device", table.concat(ids, ","),
        "button.study_3d_printer_cancel_print,camera.study_3d_printer_camera,sensor.study_3d_printer_nozzle_temperature,sensor.study_3d_printer_print_progress")
    local cancel = s2.byId["button.study_3d_printer_cancel_print"]
    local a = Model.tapAction(cancel, {})
    check("printer cancel asks first", a.service .. " " .. tostring(a.confirm ~= nil), "button.press true")
    check("buttons start hidden", Model.visible(cancel, {}), false)
    check("printer shortcut", keys(Model.shortcuts(s2, { hidden_shortcuts = { printer = false } })):find("printer") ~= nil, true)
    local today = os.date("*t", t0)
    check("forecast today", Model.dayName(string.format("%04d-%02d-%02dT12:00:00+00:00", today.year, today.month, today.day), t0), "Today")
    local three = os.time({ year = today.year, month = today.month, day = today.day, hour = 15 })
    local u = os.date("!*t", three)
    check("hourly label", Model.hourLabel(string.format("%04d-%02d-%02dT%02d:%02d:00+00:00", u.year, u.month, u.day, u.hour, u.min)), "3 PM")
    check("hourly label 24h", Model.hourLabel(string.format("%04d-%02d-%02dT%02d:00:00Z", u.year, u.month, u.day, u.hour), true), "15:00")
    local tomorrow = os.date("*t", t0 + 86400)
    check("forecast tomorrow", Model.dayName(string.format("%04d-%02d-%02dT12:00:00+00:00", tomorrow.year, tomorrow.month, tomorrow.day), t0), "Tomorrow")
end
check("by kind, by room", Model.byKind(snap, P, { light = true })[1].name, "Living Room")
check("sensors by room", #Model.byKind(snap, P, { sensor = true, binary_sensor = true }), 2)

local t, h = Model.inside(snap, P)
check("inside from the thermostat", t, 70)
check("inside humidity", h, 36)
check("fan steps", select(1, Model.fanSteps(E["fan.tower_fan"])), 6)
check("fan lit", select(2, Model.fanSteps(E["fan.tower_fan"])), 3)
check("modes without repeats", table.concat(Model.hvacModes(E["climate.thermostat"]), ","), "off,heat,cool,heat_cool")
check("whole degrees", Model.formatTemp(70.0), "70°")
check("tenths", Model.formatTemp(70.54), "70.5°")
check("weather text", (Model.weather("clear-night")), "Clear")
check("ago", Model.ago(125), "2 min ago")
check("dimmable", Model.dimmable(E["light.living_room_1"]), true)
check("colour temperature", Model.hasColorTemp(E["light.living_room_lights"]), true)

-- ------------------------------------------------------------------ the API

check("address cleaned", Api.cleanUrl(" ha.local:8123/ "), "http://ha.local:8123")
check("https kept", Api.cleanUrl("https://ha.example.com"), "https://ha.example.com")
check("empty address", Api.cleanUrl("  "), nil)

local function newApi(store, handler, clock)
    store = store or {}
    local calls = {}
    local api = Api.new{
        settings = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, save = function() end },
        request = function(method, url, headers, body, timeout)
            table.insert(calls, { method = method, url = url, headers = headers, body = body, timeout = timeout })
            return handler(method, url, headers, body)
        end,
        json = json,
        now = function() return clock or NOW end,
    }
    return api, calls, store
end

-- Signing in: the flow, the code, the tokens.
local api, calls, store = newApi({}, function(method, url, headers, body)
    if url:find("/auth/login_flow$") then return 200, json.encode({ flow_id = "F1", type = "form", step_id = "init" }) end
    if url:find("/auth/login_flow/F1") then
        local f = json.decode(body)
        if f.password == "right" then return 200, json.encode({ type = "create_entry", result = "CODE" }) end
        return 200, json.encode({ type = "form", step_id = "init", errors = { base = "invalid_auth" } })
    end
    if url:find("/auth/token") then
        if body:find("code=CODE") then return 200, json.encode({ access_token = "A1", refresh_token = "R1", expires_in = 1800 }) end
    end
    return 404, ""
end)
local login = api:startLogin("ha.local:8123")
check("flow started", login and login.flow_id, "F1")
check("handler with null", calls[1].body:find('"handler":%["homeassistant",null%]') ~= nil, true)
local ok, why = api:loginStep(login, { username = "me", password = "wrong" })
check("wrong password", why, "Wrong username or password.")
ok = api:loginStep(login, { username = "me", password = "right" })
check("signed in", ok, "done")
check("refresh token kept", store.refresh_token, "R1")
check("expiry kept", store.expires_at, NOW + 1800)
check("home address kept", store.home_url, "http://ha.local:8123")
check("signed in now", api:signedIn(), true)

-- Signed in from the web page: its client id is kept, and refreshing uses it.
api, calls, store = newApi({ home_url = "http://h" }, function(method, url, headers, body)
    if url:find("/auth/token") then return 200, json.encode({ access_token = "A", refresh_token = "R", expires_in = 1 }) end
    return 200, "{}"
end)
check("web sign-in", api:exchange("http://h", "CODE", "http://192.168.1.50:8080/"), "done")
check("web client kept", store.client_id, "http://192.168.1.50:8080/")
check("code sent for the web client", calls[1].body:find("client_id=http%%3A%%2F%%2F192.168.1.50%%3A8080%%2F") ~= nil, true)
api:sendJson("GET", "/api/")
check("refreshed for the web client", calls[2].body:find("192.168.1.50") ~= nil, true)
api:signOut()
check("client forgotten at sign-out", store.client_id, nil)

-- A two-step code.
api = newApi({}, function(method, url, headers, body)
    if url:find("/auth/login_flow/F2") then
        local f = json.decode(body)
        if f.code then return 200, json.encode({ type = "create_entry", result = "C2" }) end
        return 200, json.encode({ type = "form", step_id = "mfa" })
    end
    if url:find("/auth/token") then return 200, json.encode({ access_token = "A", refresh_token = "R", expires_in = 1800 }) end
    return 404, ""
end)
check("code asked for", api:loginStep({ base = "http://h", flow_id = "F2" }, { username = "u", password = "p" }), "mfa")
check("code accepted", api:loginStep({ base = "http://h", flow_id = "F2" }, { code = "123456" }), "done")

-- Home address first; away when home does not answer; then away first.
local seen = {}
api, calls, store = newApi({ home_url = "http://home", away_url = "https://away", token = "LONGTOKEN" }, function(method, url)
    table.insert(seen, url)
    if url:find("^http://home") then return "timeout", nil end
    return 200, '{"message":"API running."}'
end)
local res = api:sendJson("GET", "/api/")
check("answered from away", res and res.message, "API running.")
check("home tried first, briefly", calls[1].timeout, 6)
check("away remembered", store.active, "away")
api:sendJson("GET", "/api/")
check("away tried first next time", calls[3].url, "https://away/api/")
check("bearer token", calls[3].headers.Authorization, "Bearer LONGTOKEN")

-- An access token about to run out is refreshed first.
api, calls, store = newApi({ home_url = "http://home", refresh_token = "R", access_token = "OLD", expires_at = NOW + 30 },
    function(method, url, headers, body)
        if url:find("/auth/token") then return 200, json.encode({ access_token = "NEW", expires_in = 1800 }) end
        return 200, "{}"
    end)
api:sendJson("GET", "/api/")
check("refreshed", calls[1].url, "http://home/auth/token")
check("refresh body", calls[1].body:find("grant_type=refresh_token") ~= nil, true)
check("new token used", calls[2].headers.Authorization, "Bearer NEW")

-- Refused refresh: signed out of Home Assistant.
api = newApi({ home_url = "http://home", refresh_token = "R" }, function(method, url)
    if url:find("/auth/token") then return 400, '{"error":"invalid_grant"}' end
    return 200, "{}"
end)
local _, err = api:sendJson("GET", "/api/")
check("sign in again", err and err.kind, "signin")

-- A proxy's sign-in page instead of Home Assistant.
api = newApi({ home_url = "https://ha.example.com", token = "LONGTOKEN" }, function()
    return 200, "<!DOCTYPE html><html>Sign in</html>"
end)
_, err = api:sendJson("GET", "/api/")
check("not Home Assistant", err and err.kind, "notapi")

-- A token: checked, kept or put back.
api, calls, store = newApi({ home_url = "http://home" }, function(method, url, headers)
    if headers.Authorization == "Bearer GOODTOKEN0123456789abc" then return 200, '{"message":"API running."}' end
    return 401, "401: Unauthorized"
end)
check("good token", api:useToken("  GOODTOKEN0123456789abc\n"), true)
check("token kept", store.token, "GOODTOKEN0123456789abc")
store.token = nil
local bad = api:useToken("BADTOKEN0123456789abcdef")
check("bad token refused", bad, nil)
check("bad token not kept", store.token, nil)

-- The snapshot and a service.
api, calls = newApi({ home_url = "http://home", token = "LONGTOKEN" }, function(method, url, headers, body)
    if url:find("/api/template") then return 200, json.encode(data) end
    if url:find("/api/services/") then return 200, "[]" end
    return 404, ""
end)
local s2 = api:snapshot()
check("snapshot", s2 and #s2.list, 23)
check("template sent", json.decode(calls[1].body).template, "{{ template }}")
check("service called", api:call("light.toggle", { entity_id = "light.x" }), true)
check("service path", calls[2].url, "http://home/api/services/light/toggle")
check("service body", json.decode(calls[2].body).entity_id, "light.x")


-- Sleep screen alerts: only what needs attention; a sensor always.
do
    local as = Model.parse({ v = 1, now = 1, e = {
        { "lock.front", "Front", "unlocked", "Foyer", "", 0, {} },
        { "lock.back", "Back", "locked", "Foyer", "", 0, {} },
        { "binary_sensor.leak", "Leak", "on", "Basement", "", 0, { { "device_class", "moisture" } } },
        { "binary_sensor.dry", "Dry", "off", "Basement", "", 0, { { "device_class", "moisture" } } },
        { "sensor.t", "Garage temp", "41", "Garage", "", 0, { { "device_class", "temperature" }, { "unit_of_measurement", "F" } } },
    } })
    local lines = Model.sleepAlerts(as, { sleep_alerts = { "lock.front", "lock.back", "binary_sensor.leak", "binary_sensor.dry", "sensor.t", "lock.gone" } })
    check("sleep alerts count", #lines, 3)
    check("sleep alert lock", lines[1], "Front  \u{00B7}  Unlocked")
    check("sleep alert leak", lines[2], "Leak  \u{00B7}  Wet")
    check("sleep alert choices", #Model.sleepAlertChoices(as), 5)
end
-- The connection test: each address on its own.
do
    local tick = 0
    local clock = function() tick = tick + 0.25 return tick end
    local api2 = newApi({ home_url = "http://home", away_url = "https://away", token = "T" }, function(method, url)
        if url == "http://home/api/" then return 200, '{"message":"API running."}' end
        if url == "https://away/api/" then return 200, "<html>Sign in</html>" end
    end)
    local rows = api2:testAddresses(clock)
    check("test rows", #rows, 2)
    check("home works", rows[1].ok and rows[1].kind, "ok")
    check("home time", rows[1].ms, 250)
    check("away is a proxy page", rows[2].kind, "notapi")
    local api3 = newApi({ home_url = "http://home" }, function() return "timeout" end)
    rows = api3:testAddresses(clock)
    check("unreachable", rows[1].kind .. " " .. rows[1].err, "unreachable timeout")
    local api4 = newApi({ home_url = "http://home" }, function() return 401, "" end)
    check("not signed in yet", api4:testAddresses(clock)[1].kind, "notsignedin")
    check("no addresses", #newApi({}, function() end):testAddresses(clock), 0)
end

-- Plex: the server's sensor (who's watching), Scan clients, its libraries
do
    local ps = Model.parse({ v = 1, now = 1, e = {
        { "sensor.plex_server", "Plex Server", "2", "", "Plex Server", 1,
            { { "unit_of_measurement", "watching" }, { "plex", 1 }, { "w:sam - Living Room TV", "Dune (2021)" }, { "w:alex - Phone", "The Office - S02E03" } } },
        { "button.plex_server_scan_clients", "Plex Server Scan clients", "x", "", "Plex Server", 1, { { "plex", 1 } } },
        { "sensor.plex_server_library_movies", "Plex Server Library - Movies", "812", "", "Plex Server", 1, { { "plex", 1 }, { "library_type", "movie" } } },
    } })
    local p = Model.plex(ps)
    check("plex watching", p.count .. " " .. #p.watching .. " " .. p.watching[1].who .. ": " .. p.watching[1].what, "2 2 alex - Phone: The Office - S02E03")
    check("plex scan clients and a library", p.scan.id .. " " .. p.libraries[1].name .. " " .. p.libraries[1].count, "button.plex_server_scan_clients Movies 812")
    check("no plex", Model.plex(Model.parse({ v = 1, now = 1, e = {} })), nil)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
