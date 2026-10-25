--[[--
What the plugin knows about the home, in plain Lua (no KOReader modules) so
the tests can run it: the snapshot from Home Assistant made into entities and
rooms, what each entity shows and does when tapped, and the summaries (on
now, rooms, the attention bar). Settings come in as a plain table.
]]

local Model = {}

-- JSON nulls arrive as a sentinel (not nil) from KOReader's decoder.
local function num(v) return type(v) == "number" and v or nil end
local function str(v) return type(v) == "string" and v or nil end
Model.num, Model.str = num, str

local DOMAINS = {
    light = true, switch = true, fan = true, climate = true, lock = true, cover = true, vacuum = true,
    media_player = true, camera = true, scene = true, script = true, input_boolean = true,
    sensor = true, binary_sensor = true, button = true, calendar = true,
}

-- Sensors shown unless picked otherwise (others, such as batteries and motion, start hidden).
local SHOWN_SENSORS = { temperature = true, humidity = true }
local SHOWN_BINARY = { door = true, window = true, garage_door = true, opening = true, moisture = true, smoke = true,
    gas = true, carbon_monoxide = true }
-- Binary sensors that need attention when on.
local ALARMS = { moisture = true, smoke = true, gas = true, carbon_monoxide = true, problem = true, safety = true }

local MAIN = { camera = true, lock = true, cover = true, vacuum = true, media_player = true, climate = true, fan = true }

--- The snapshot (the template's JSON) made into { now, list, byId, rooms, doors, batteries, weather }.
function Model.parse(data)
    if type(data) ~= "table" or type(data.e) ~= "table" then return nil end
    local snap = { now = num(data.now) or os.time(), list = {}, byId = {}, rooms = {}, doors = {}, batteries = {} }
    for __, row in ipairs(data.e) do
        local id = str(row[1])
        local domain = id and id:match("^([%w_]+)%.")
        if domain and DOMAINS[domain] then
            local attr = {}
            if type(row[7]) == "table" then
                for __, kv in ipairs(row[7]) do
                    if str(kv[1]) and kv[2] ~= nil and type(kv[2]) ~= "function" then attr[kv[1]] = kv[2] end
                end
            end
            local e = {
                id = id, domain = domain, name = str(row[2]) or id, state = str(row[3]) or "unknown",
                area = str(row[4]) or "", device = str(row[5]) or "", changed = num(row[6]), attr = attr,
            }
            table.insert(snap.list, e)
            snap.byId[id] = e
        end
    end
    -- Devices that are a camera, lock, player...: their switches (privacy,
    -- detection, power) are the device's settings.
    local main = {}
    for __, e in ipairs(snap.list) do
        if MAIN[e.domain] and e.device ~= "" then main[e.device] = true end
    end
    for __, e in ipairs(snap.list) do
        if e.domain == "switch" and main[e.device] then e.onMainDevice = true end
    end
    for __, r in ipairs(type(data.r) == "table" and data.r or {}) do
        if str(r[1]) then
            table.insert(snap.rooms, { name = r[1], floor = str(r[2]) or "", temp = num(r[3]), humidity = num(r[4]) })
        end
    end
    for __, d in ipairs(type(data.d) == "table" and data.d or {}) do
        if str(d[1]) then table.insert(snap.doors, { name = d[1], since = num(d[2]) }) end
    end
    for __, b in ipairs(type(data.b) == "table" and data.b or {}) do
        if str(b[1]) and num(b[2]) then table.insert(snap.batteries, { name = b[1], percent = b[2] }) end
    end
    if type(data.w) == "table" and str(data.w[1]) then
        snap.weather = { state = data.w[1], temp = num(data.w[2]), unit = str(data.w[3]) or "", id = str(data.w[4]),
            humidity = num(data.w[5]), wind = num(data.w[6]), windUnit = str(data.w[7]) }
    end
    snap.weathers = {}
    for __, w in ipairs(type(data.ws) == "table" and data.ws or {}) do
        if str(w[1]) then table.insert(snap.weathers, { id = w[1], name = str(w[2]) or w[1] }) end
    end
    return snap
end

-- ------------------------------------------------------------------ entities

--- Whether a group (a light or player made of others).
function Model.isGroup(e)
    return type(e.attr.entity_id) == "table" and #e.attr.entity_id > 0
end

--- Shown unless picked otherwise: a switch named apart from its device (its
-- LED, firmware updates, motion detection...), or on a device that is a
-- camera, lock, player and so on, is one of the device's settings, not
-- something to switch from a reader, so it starts hidden.
function Model.isPrimary(e)
    if e.domain == "button" or e.domain == "calendar" then return false end
    if e.domain == "sensor" then return SHOWN_SENSORS[str(e.attr.device_class) or ""] == true end
    if e.domain == "binary_sensor" then return SHOWN_BINARY[str(e.attr.device_class) or ""] == true end
    if e.domain == "switch" then
        return (e.device == "" or e.name == e.device) and not e.onMainDevice
    end
    if e.domain == "media_player" and Model.isGroup(e) then return false end
    return true
end

--- settings.shown / settings.hidden: { [id] = true } picked in Devices.
function Model.visible(e, settings)
    if settings.hidden and settings.hidden[e.id] then return false end
    if settings.shown and settings.shown[e.id] then return true end
    return Model.isPrimary(e)
end

local function features(e) return num(e.attr.supported_features) or 0 end

--- Whether Home Assistant can turn a player on, and off (its supported
-- features: an LG TV without Wake-on-LAN set up can only be turned off).
function Model.power(e)
    local f = features(e)
    return math.floor(f / 128) % 2 == 1, math.floor(f / 256) % 2 == 1
end

function Model.isOn(e)
    local s = e.state
    if e.domain == "media_player" then return s == "on" or s == "playing" or s == "paused" or s == "buffering" end
    if e.domain == "climate" then return s ~= "off" and s ~= "unavailable" and s ~= "unknown" end
    if e.domain == "cover" then return s == "open" or s == "opening" end
    if e.domain == "lock" then return s == "unlocked" or s == "open" end
    if e.domain == "vacuum" then return s == "cleaning" end
    return s == "on"
end

--- Lights, switches, fans and players: what On now counts and Turn all off turns off.
function Model.switchable(e)
    local d = e.domain
    return d == "light" or d == "switch" or d == "fan" or d == "input_boolean" or d == "media_player"
end

function Model.brightnessPercent(e)
    local b = num(e.attr.brightness)
    if not b then return nil end
    return math.floor(b * 100 / 255 + 0.5)
end

function Model.dimmable(e)
    local modes = e.attr.supported_color_modes
    if type(modes) ~= "table" then return num(e.attr.brightness) ~= nil end
    for __, m in ipairs(modes) do
        if m ~= "onoff" then return true end
    end
    return false
end

-- ------------------------------------------------------------------ light colours

--- Named colours for a light that has colour (e-ink shows no colour: each a
-- name and its own grey). hs: hue and saturation; kelvin: a white.
Model.COLORS = {
    { name = "Red", hs = { 0, 100 }, grey = 0x55 },
    { name = "Orange", hs = { 30, 100 }, grey = 0x88 },
    { name = "Yellow", hs = { 55, 100 }, grey = 0xDD },
    { name = "Green", hs = { 120, 100 }, grey = 0x99 },
    { name = "Cyan", hs = { 180, 100 }, grey = 0xBB },
    { name = "Blue", hs = { 240, 100 }, grey = 0x33 },
    { name = "Purple", hs = { 275, 100 }, grey = 0x44 },
    { name = "Pink", hs = { 320, 60 }, grey = 0xAA },
    { name = "Warm white", kelvin = 2700, hs = { 30, 20 }, grey = 0xEE },
    { name = "Cool white", kelvin = 6000, hs = { 210, 8 }, grey = 0xFF },
}

--- Whether a light takes colours (not only whites).
function Model.hasColor(e)
    local modes = e.attr.supported_color_modes
    if type(modes) ~= "table" then return false end
    for __, m in ipairs(modes) do
        if m == "hs" or m == "xy" or m == "rgb" or m == "rgbw" or m == "rgbww" then return true end
    end
    return false
end

--- The named colour closest to what a light shows now (nil when off or unknown).
function Model.colorOf(e)
    if e.state ~= "on" or not Model.hasColor(e) then return nil end
    local a = e.attr
    local mode = str(a.color_mode)
    if mode == "color_temp" then
        local k = num(a.color_temp_kelvin)
        if not k then return nil end
        return k < 4000 and Model.COLORS[9] or Model.COLORS[10]
    end
    local hs = type(a.hs_color) == "table" and a.hs_color or nil
    local h, s = hs and num(hs[1]), hs and num(hs[2])
    if not (h and s) then return nil end
    if s < 25 then return (h >= 15 and h <= 70) and Model.COLORS[9] or Model.COLORS[10] end
    local best, bestD
    for i = 1, 8 do
        local c = Model.COLORS[i]
        local d = math.abs(h - c.hs[1]) % 360
        if d > 180 then d = 360 - d end
        if i == 8 and s < 75 then d = d - 15 end
        if not bestD or d < bestD then best, bestD = c, d end
    end
    return best
end

--- What turning a light to a named colour sends (light.turn_on data).
function Model.colorData(e, color)
    if color.kelvin and Model.hasColorTemp(e) then
        local lo, hi = num(e.attr.min_color_temp_kelvin), num(e.attr.max_color_temp_kelvin)
        local k = color.kelvin
        if lo and k < lo then k = lo end
        if hi and k > hi then k = hi end
        return { color_temp_kelvin = k }
    end
    return { hs_color = { color.hs[1], color.hs[2] } }
end

function Model.hasColorTemp(e)
    local modes = e.attr.supported_color_modes
    if type(modes) ~= "table" then return false end
    for __, m in ipairs(modes) do
        if m == "color_temp" or m == "hs" or m == "xy" or m == "rgb" or m == "rgbw" or m == "rgbww" then
            return num(e.attr.min_color_temp_kelvin) ~= nil
        end
    end
    return false
end

function Model.formatTemp(v)
    if not v then return "" end
    if math.abs(v - math.floor(v + 0.5)) < 0.05 then return string.format("%d°", math.floor(v + 0.5)) end
    return string.format("%.1f°", v)
end

local TITLES = {
    on = "On", off = "Off", unavailable = "Unavailable", unknown = "Unknown",
    locked = "Locked", unlocked = "Unlocked", locking = "Locking", unlocking = "Unlocking", jammed = "Jammed",
    open = "Open", closed = "Closed", opening = "Opening", closing = "Closing",
    docked = "Docked", cleaning = "Cleaning", returning = "Returning", paused = "Paused", idle = "Idle", error = "Error",
    playing = "Playing", standby = "Standby", buffering = "Loading",
    heat = "Heat", cool = "Cool", heat_cool = "Heat/Cool", auto = "Auto", dry = "Dry", fan_only = "Fan",
}
Model.TITLES = TITLES

function Model.title(state)
    return TITLES[state] or (state:gsub("_", " "):gsub("^%l", string.upper))
end

local BINARY_WORDS = {
    door = { "Open", "Closed" }, window = { "Open", "Closed" }, garage_door = { "Open", "Closed" }, opening = { "Open", "Closed" },
    motion = { "Motion", "Clear" }, occupancy = { "Someone there", "Clear" }, presence = { "Home", "Away" },
    moisture = { "Wet", "Dry" }, smoke = { "Smoke", "Clear" }, gas = { "Gas", "Clear" }, carbon_monoxide = { "CO", "Clear" },
    safety = { "Unsafe", "Safe" }, problem = { "Problem", "OK" }, lock = { "Unlocked", "Locked" }, plug = { "Plugged in", "Unplugged" },
    light = { "Light", "Dark" },
}

Model.PLACEHOLDERS = { { "door", "Doorway" }, { "garage", "Garage" }, { "room", "Room" }, { "printer", "3D printer" } }

--- Which drawing stands in for a camera's picture until it comes: "door",
-- "garage", "room" or "printer" (the one picked in settings.placeholders, else by its name).
function Model.placeholder(e, settings)
    local picked = e and settings and settings.placeholders and settings.placeholders[e.id]
    if picked == "door" or picked == "garage" or picked == "room" or picked == "printer" then return picked end
    local text = ((e and e.id or "") .. " " .. (e and e.name or "")):lower()
    for __, word in ipairs({ "printer", "flashforge", "bambu", "prusa", "creality", "ender", "octoprint", "klipper", "mainsail", "3d" }) do
        if text:find(word, 1, true) then return "printer" end
    end
    if text:find("garage") or text:find("driveway") or text:find("floodlight") then return "garage" end
    if text:find("door") or text:find("foyer") or text:find("porch") or text:find("entry") then return "door" end
    return "room"
end

--- A name without its device's name in front ("Kitchen Sensor Humidity" -> "Humidity").
function Model.shortName(e)
    local d = e.device or ""
    if d ~= "" and #e.name > #d + 1 and e.name:sub(1, #d + 1) == d .. " " then
        local rest = e.name:sub(#d + 2)
        return (rest:gsub("^%l", string.upper))
    end
    return e.name
end

--- A sensor's value with its unit: "70.5°F", "46%", "212 lx".
function Model.sensorText(e)
    local unit = str(e.attr.unit_of_measurement) or ""
    local v = tonumber(e.state)
    if not v then return Model.title(e.state) end
    local text
    if math.abs(v - math.floor(v + 0.5)) < 0.05 then text = tostring(math.floor(v + 0.5)) else text = string.format("%.1f", v) end
    if unit == "" then return text end
    if unit:find("^\194\176") or unit == "%" then return text .. unit end
    return text .. " " .. unit
end

--- The short state line under a tile.
function Model.stateText(e)
    local s, a = e.state, e.attr
    if s == "unavailable" then return "Unavailable" end
    local d = e.domain
    if d == "sensor" then return Model.sensorText(e) end
    if d == "binary_sensor" then
        local words = BINARY_WORDS[str(a.device_class) or ""]
        if words and (s == "on" or s == "off") then return s == "on" and words[1] or words[2] end
        return Model.title(s)
    end
    if d == "light" then
        local pct = Model.brightnessPercent(e)
        local color = Model.colorOf(e)
        if s == "on" and (pct or color) then
            return "On" .. (color and (" · " .. color.name) or "") .. (pct and (" · " .. pct .. "%") or "")
        end
        return Model.title(s)
    end
    if d == "fan" then
        if s == "on" then
            if str(a.preset_mode) then return "On · " .. a.preset_mode end
            if num(a.percentage) then return "On · " .. math.floor(a.percentage + 0.5) .. "%" end
        end
        return Model.title(s)
    end
    if d == "climate" then
        local now = num(a.current_temperature)
        local mode = Model.title(s)
        if now then return mode .. " · " .. Model.formatTemp(now) end
        return mode
    end
    if d == "cover" then
        local pos = num(a.current_position)
        if s == "open" and pos and pos < 100 then return "Open · " .. pos .. "%" end
        return Model.title(s)
    end
    if d == "media_player" then
        if s == "playing" or s == "paused" then
            local what = str(a.media_title) or str(a.app_name) or str(a.source)
            return Model.title(s) .. (what and (" · " .. what) or "")
        end
        if s == "on" then
            local what = str(a.source) or str(a.app_name)
            return "On" .. (what and (" · " .. what) or "")
        end
        return Model.title(s)
    end
    if d == "vacuum" then
        local battery = num(a.battery_level)
        return Model.title(s) .. (battery and battery < 100 and s ~= "cleaning" and (" · " .. battery .. "%") or "")
    end
    if d == "scene" then return "Scene" end
    if d == "script" then return s == "on" and "Running" or "Script" end
    if d == "camera" then return "Camera" end
    return Model.title(s)
end

--- The icon's name (in icons/).
local SENSOR_ICONS = {
    temperature = "thermometer", humidity = "droplets", battery = "battery-medium", power = "zap", energy = "zap",
    voltage = "zap", current = "zap", illuminance = "sun", carbon_dioxide = "wind", pm25 = "wind", pressure = "gauge",
    moisture = "droplets",
}
local BINARY_ICONS = {
    motion = "footprints", occupancy = "person-standing", presence = "person-standing", moisture = "droplets",
    smoke = "siren", gas = "siren", carbon_monoxide = "siren", safety = "triangle-alert", problem = "triangle-alert",
    lock = "lock", plug = "plug", light = "sun", window = "app-window",
}

function Model.icon(e)
    local d, s = e.domain, e.state
    if d == "sensor" then return SENSOR_ICONS[str(e.attr.device_class) or ""] or "activity" end
    if d == "binary_sensor" then
        local class = str(e.attr.device_class) or ""
        if class == "door" or class == "garage_door" or class == "opening" then return s == "on" and "door-open" or "door-closed" end
        return BINARY_ICONS[class] or "activity"
    end
    if d == "light" then return "lightbulb" end
    if d == "switch" then return "plug" end
    if d == "input_boolean" then return s == "on" and "toggle-right" or "toggle-left" end
    if d == "fan" then return "fan" end
    if d == "climate" then return "thermometer" end
    if d == "lock" then return (s == "unlocked" or s == "open") and "lock-open" or "lock" end
    if d == "cover" then
        local class = str(e.attr.device_class) or ""
        if class == "garage" or e.id:find("garage") then return "warehouse" end
        if class == "door" or class == "gate" then return s == "closed" and "door-closed" or "door-open" end
        return "blinds"
    end
    if d == "vacuum" then return "bot" end
    if d == "camera" then return "camera" end
    if d == "button" then
        local id = e.id
        if id:find("pause") then return "pause" end
        if id:find("resume") or id:find("start") then return "play" end
        if id:find("cancel") or id:find("stop") then return "x" end
        return "circle-help"
    end
    if d == "scene" then return "sparkles" end
    if d == "script" then return "terminal" end
    if d == "media_player" then
        local text = (e.id .. " " .. e.name):lower()
        if str(e.attr.device_class) == "tv" or text:find("tv") or text:find("webos") then return "tv" end
        if text:find("clock") then return "clock" end
        return "speaker"
    end
    return "circle-help"
end

-- ------------------------------------------------------------------ tapping

--- What a tap on a tile does: { service = "light.toggle", data = {...}, confirm = text }
-- or { sheet = true } (the controls open) or { camera = true } (a new picture).
-- settings.ask_unlock / ask_garage / ask_scripts (true when not set).
function Model.tapAction(e, settings)
    local d, s, id = e.domain, e.state, e.id
    local function ask(key) return settings[key] ~= false end
    if s == "unavailable" or d == "sensor" or d == "binary_sensor" then return { sheet = true } end
    if d == "light" or d == "switch" or d == "fan" or d == "input_boolean" then
        return { service = d .. ".toggle", data = { entity_id = id } }
    end
    if d == "lock" then
        if s == "locked" then
            return { service = "lock.unlock", data = { entity_id = id }, confirm = ask("ask_unlock") and ("Unlock " .. e.name .. "?") or nil }
        end
        return { service = "lock.lock", data = { entity_id = id } }
    end
    if d == "cover" then
        local garage = Model.icon(e) == "warehouse"
        local opening = s == "closed" or s == "closing"
        local text = (opening and "Open " or "Close ") .. e.name .. "?"
        return { service = opening and "cover.open_cover" or "cover.close_cover", data = { entity_id = id },
            confirm = garage and ask("ask_garage") and text or nil }
    end
    if d == "scene" then return { service = "scene.turn_on", data = { entity_id = id } } end
    if d == "script" then
        return { service = "script.turn_on", data = { entity_id = id }, confirm = ask("ask_scripts") and ("Run " .. e.name .. "?") or nil }
    end
    if d == "camera" then return { camera = true } end
    if d == "button" then
        local risky = id:find("cancel") or id:find("stop") or id:find("reboot") or id:find("shutdown") or id:find("restart")
        return { service = "button.press", data = { entity_id = id }, confirm = risky and (e.name .. "?") or nil }
    end
    return { sheet = true }
end

--- The state a tap is expected to leave (shown at once, before Home Assistant answers).
function Model.expected(e, service)
    local verb = service:match("%.(.+)$")
    if verb == "toggle" then return e.state == "on" and "off" or "on" end
    if verb == "turn_on" then return e.domain == "script" and e.state or "on" end
    if verb == "turn_off" then return "off" end
    if verb == "lock" then return "locking" end
    if verb == "unlock" then return "unlocking" end
    if verb == "open_cover" then return "opening" end
    if verb == "close_cover" then return "closing" end
    return e.state
end

-- ------------------------------------------------------------------ orders

--- items sorted by a saved order (keys first, in that order; the rest after, as they were).
function Model.ordered(items, order, key)
    local rank = {}
    for i, k in ipairs(order or {}) do rank[k] = i end
    local out = {}
    for i, it in ipairs(items) do out[i] = { it = it, i = i, r = rank[key(it)] } end
    table.sort(out, function(a, b)
        if a.r and b.r then return a.r < b.r end
        if a.r then return true end
        if b.r then return false end
        return a.i < b.i
    end)
    local sorted = {}
    for i, o in ipairs(out) do sorted[i] = o.it end
    return sorted
end

--- A new order with `k` moved by `delta` places among `keys` (all the keys, in their current order).
function Model.move(keys, k, delta)
    local order = {}
    for i, key in ipairs(keys) do order[i] = key end
    for i, key in ipairs(order) do
        if key == k then
            local j = math.max(1, math.min(#order, i + delta))
            table.remove(order, i)
            table.insert(order, j, k)
            break
        end
    end
    return order
end

-- ------------------------------------------------------------------ rooms

local KINDS = {
    { "LIGHTS", { light = true } },
    { "SWITCHES", { switch = true, input_boolean = true } },
    { "CLIMATE", { climate = true, fan = true } },
    { "DOORS", { lock = true, cover = true } },
    { "MEDIA", { media_player = true } },
    { "CLEANING", { vacuum = true } },
    { "CAMERAS", { camera = true } },
    { "SCENES & SCRIPTS", { scene = true, script = true } },
    { "SENSORS", { sensor = true, binary_sensor = true } },
}

--- The shortcuts at the top of Home: a screen of all of one kind, by room.
Model.SHORTCUTS = {
    { key = "lights", label = "Lights", icon = "lightbulb", domains = { light = true } },
    { key = "climate", label = "Climate", icon = "thermometer", screen = "climate", domains = { climate = true, fan = true } },
    { key = "switches", label = "Switches", icon = "plug", domains = { switch = true, input_boolean = true } },
    { key = "sensors", label = "Sensors", icon = "gauge", domains = { sensor = true, binary_sensor = true } },
    { key = "cameras", label = "Cameras", icon = "camera", screen = "cameras", domains = { camera = true } },
    { key = "media", label = "Media", icon = "tv", screen = "media", domains = { media_player = true } },
    { key = "scenes", label = "Scenes", icon = "sparkles", screen = "scripts", domains = { scene = true, script = true } },
    { key = "dashboard", label = "Dashboard", icon = "layout-dashboard", screen = "dashboard" },
    { key = "security", label = "Security", icon = "shield-check", screen = "security", domains = { camera = true, lock = true, cover = true } },
    { key = "doors", label = "Doors", icon = "lock", domains = { lock = true, cover = true }, off = true },
    { key = "vacuums", label = "Vacuums", icon = "bot", domains = { vacuum = true }, off = true },
    { key = "weather", label = "Weather", icon = "cloud-sun", screen = "weather", off = true,
        when = function(snap) return snap.weather ~= nil end },
    { key = "activity", label = "Activity", icon = "history", screen = "activity", off = true },
    { key = "batteries", label = "Batteries", icon = "battery-medium", screen = "batteries", off = true,
        when = function(snap, settings) return #Model.batteryList(snap, settings) > 0 end },
    { key = "printer", label = "3D printer", icon = "printer", screen = "printer", off = true,
        when = function(snap, settings) return #Model.printer(snap, settings) > 0 end },
}

function Model.shortcut(key)
    for __, s in ipairs(Model.SHORTCUTS) do
        if s.key == key then return s end
    end
end

--- The shortcuts in the saved order; hidden ones (picked, or off by default)
-- left out unless withHidden, and those with nothing to show always left out.
-- Each: the definition, plus hidden = true/false.
function Model.shortcuts(snap, settings, withHidden)
    local has = {}
    for __, e in ipairs(snap and snap.list or {}) do
        if Model.visible(e, settings) then has[e.domain] = true end
    end
    local out = {}
    for __, s in ipairs(Model.ordered(Model.SHORTCUTS, settings.shortcuts, function(x) return x.key end)) do
        local any = not s.domains
        for d in pairs(s.domains or {}) do any = any or has[d] end
        if s.when then any = snap ~= nil and s.when(snap, settings) end
        local picked = settings.hidden_shortcuts and settings.hidden_shortcuts[s.key]
        local hidden
        if picked ~= nil then hidden = picked else hidden = s.off == true end
        if any and (withHidden or not hidden) then
            table.insert(out, setmetatable({ hidden = hidden }, { __index = s }))
        end
    end
    return out
end

--- Every visible entity of a shortcut's kinds, by room (rooms in their order).
function Model.byKind(snap, settings, domains)
    local out = {}
    for __, room in ipairs(Model.rooms(snap, settings)) do
        local list = {}
        for __, e in ipairs(room.entities) do
            if domains[e.domain] then table.insert(list, e) end
        end
        if #list > 0 then table.insert(out, { name = room.name, entities = list }) end
    end
    return out
end
Model.KINDS = KINDS

--- Every visible entity, in rooms (Home Assistant's order, or the saved
-- one), rooms with nothing shown left out; entities without a room in
-- "Everything Else" at the end. Each room: { name, temp, humidity, entities }.
function Model.rooms(snap, settings, withHidden)
    local byName, rooms = {}, {}
    for __, r in ipairs(snap.rooms) do
        local room = { name = r.name, floor = r.floor, temp = r.temp, humidity = r.humidity, entities = {} }
        byName[r.name] = room
        table.insert(rooms, room)
    end
    local other = { name = "Everything Else", floor = "", entities = {}, other = true }
    for __, e in ipairs(snap.list) do
        if Model.visible(e, settings) then
            local room = byName[e.area] or other
            table.insert(room.entities, e)
        end
    end
    table.insert(rooms, other)
    local out = {}
    for __, room in ipairs(Model.ordered(rooms, settings.room_order, function(r) return r.name end)) do
        local hidden = settings.hidden_rooms and settings.hidden_rooms[room.name]
        if #room.entities > 0 and (withHidden or not hidden) then
            room.hidden = hidden or nil
            -- Groups first, then by name; or the saved order.
            table.sort(room.entities, function(a, b)
                local ga, gb = Model.isGroup(a), Model.isGroup(b)
                if ga ~= gb then return ga end
                return a.name:lower() < b.name:lower()
            end)
            room.entities = Model.ordered(room.entities, settings.entity_order and settings.entity_order[room.name],
                function(e) return e.id end)
            table.insert(out, room)
        end
    end
    return out
end

--- A room's entities in kinds: { { title, entities }, ... }.
function Model.kinds(entities)
    local out = {}
    for __, kind in ipairs(KINDS) do
        local list = {}
        for __, e in ipairs(entities) do
            if kind[2][e.domain] then table.insert(list, e) end
        end
        if #list > 0 then table.insert(out, { title = kind[1], entities = list }) end
    end
    return out
end

--- One line about a room: "5 on · 70.5°", "all off · 69°", "closed · locked".
function Model.roomSummary(room)
    local parts = {}
    local switches, on = 0, 0
    local locks, unlocked, covers, open = 0, 0, 0, 0
    local vacuum
    for __, e in ipairs(room.entities) do
        local d = e.domain
        if (d == "light" or d == "switch" or d == "fan" or d == "input_boolean") and not Model.isGroup(e) then
            switches = switches + 1
            if e.state == "on" then on = on + 1 end
        elseif d == "lock" then
            locks = locks + 1
            if e.state ~= "locked" then unlocked = unlocked + 1 end
        elseif d == "cover" then
            covers = covers + 1
            if e.state ~= "closed" then open = open + 1 end
        elseif d == "vacuum" then
            vacuum = vacuum or e
        end
    end
    if switches > 0 then table.insert(parts, on > 0 and (on .. " on") or "all off") end
    if covers > 0 then table.insert(parts, open > 0 and (covers == 1 and "open" or (open .. " open")) or "closed") end
    if locks > 0 then table.insert(parts, unlocked > 0 and (locks == 1 and "unlocked" or (unlocked .. " unlocked")) or "locked") end
    if vacuum then table.insert(parts, "vacuum " .. Model.title(vacuum.state):lower()) end
    if room.temp then table.insert(parts, Model.formatTemp(room.temp)) end
    return table.concat(parts, " · ")
end

--- What is on now (no groups: their members show).
--- What is on (On now); with `keep` ({ [id] = true }), those just turned off
-- too, where they were (shown as off, so a tap turns one back on).
function Model.onNow(snap, settings, keep)
    local out = {}
    for __, e in ipairs(snap.list) do
        if Model.switchable(e) and not Model.isGroup(e) and Model.visible(e, settings)
                and (Model.isOn(e) or (keep and keep[e.id])) then
            table.insert(out, e)
        end
    end
    return out
end

--- The Quick tiles: the saved list, or locks, garage doors, thermostats, vacuums and light groups.
function Model.quick(snap, settings)
    local out = {}
    if settings.quick then
        for __, id in ipairs(settings.quick) do
            if snap.byId[id] then table.insert(out, snap.byId[id]) end
        end
        return out
    end
    local rank = { lock = 1, cover = 2, climate = 3, vacuum = 4, light = 5 }
    local picked = {}
    for __, e in ipairs(snap.list) do
        local r = rank[e.domain]
        if r and Model.visible(e, settings) and (e.domain ~= "light" or (Model.isGroup(e) and e.area ~= "" )) then
            table.insert(picked, { e = e, r = r })
        end
    end
    table.sort(picked, function(a, b) if a.r ~= b.r then return a.r < b.r end return a.e.name < b.e.name end)
    for i = 1, math.min(9, #picked) do out[i] = picked[i].e end
    return out
end

local function minutesSince(snap, t)
    if not t then return nil end
    return math.max(0, math.floor((snap.now - t) / 60))
end

--- The attention bar: { ok = true/false, text }. Unlocked locks, open
-- garage doors and doors, low batteries; else the all-clear.
function Model.attention(snap, settings)
    local issues = {}
    local locks, garages = 0, 0
    for __, e in ipairs(snap.list) do
        if Model.visible(e, settings) then
            if e.domain == "lock" then
                locks = locks + 1
                if e.state ~= "locked" and e.state ~= "unavailable" then
                    table.insert(issues, e.name .. " " .. Model.title(e.state):lower())
                end
            elseif e.domain == "cover" and Model.icon(e) == "warehouse" then
                garages = garages + 1
                if e.state ~= "closed" and e.state ~= "unavailable" then
                    local m = minutesSince(snap, e.changed)
                    table.insert(issues, e.name .. " " .. Model.title(e.state):lower() .. (m and m > 0 and (" " .. m .. " min") or ""))
                end
            end
        end
    end
    for __, e in ipairs(snap.list) do
        if e.domain == "binary_sensor" and ALARMS[str(e.attr.device_class) or ""] and e.state == "on" then
            table.insert(issues, e.name .. " " .. Model.stateText(e):lower())
        end
    end
    for __, d in ipairs(snap.doors) do
        local m = minutesSince(snap, d.since)
        table.insert(issues, d.name .. " open" .. (m and m > 0 and (" " .. m .. " min") or ""))
    end
    for __, b in ipairs(snap.batteries) do
        table.insert(issues, b.name .. " " .. math.floor(b.percent + 0.5) .. "%")
    end
    if #issues > 0 then return { ok = false, text = table.concat(issues, " · ") } end
    local parts = {}
    if locks > 0 then table.insert(parts, locks == 1 and "Locked" or ("All " .. locks .. " doors locked")) end
    if garages > 0 then table.insert(parts, garages == 1 and "Garage closed" or "Garage doors closed") end
    if #parts == 0 then parts[1] = "All clear" end
    return { ok = true, text = table.concat(parts, " · ") }
end

--- Inside: a thermostat's reading, else the rooms' average. Returns temp, humidity.
function Model.inside(snap, settings)
    for __, e in ipairs(snap.list) do
        if e.domain == "climate" and Model.visible(e, settings) and num(e.attr.current_temperature) then
            return e.attr.current_temperature, num(e.attr.current_humidity)
        end
    end
    local sum, n = 0, 0
    for __, r in ipairs(snap.rooms) do
        if r.temp then sum, n = sum + r.temp, n + 1 end
    end
    if n > 0 then return sum / n, nil end
    return nil
end

local WEATHER = {
    ["clear-night"] = { "Clear", "moon" }, sunny = { "Sunny", "sun" }, partlycloudy = { "Partly cloudy", "cloud-sun" },
    cloudy = { "Cloudy", "cloud" }, rainy = { "Rain", "cloud-rain" }, pouring = { "Heavy rain", "cloud-rain" },
    snowy = { "Snow", "cloud-snow" }, ["snowy-rainy"] = { "Sleet", "cloud-snow" }, lightning = { "Storms", "cloud-lightning" },
    ["lightning-rainy"] = { "Storms", "cloud-lightning" }, fog = { "Fog", "cloud-fog" }, hail = { "Hail", "cloud-snow" },
    windy = { "Windy", "wind" }, ["windy-variant"] = { "Windy", "wind" }, exceptional = { "Unusual weather", "triangle-alert" },
}

--- Weather as text and an icon name.
function Model.weather(state)
    local w = WEATHER[state or ""]
    if w then return w[1], w[2] end
    return Model.title(state or "unknown"), "cloud"
end

--- The steps of a fan's speed: n buttons (at most 10) and the one now lit.
function Model.fanSteps(e)
    local step = num(e.attr.percentage_step) or 10
    local n = math.max(1, math.min(10, math.floor(100 / step + 0.5)))
    local pct = num(e.attr.percentage) or 0
    local lit = e.state == "on" and math.max(1, math.floor(pct * n / 100 + 0.5)) or 0
    return n, lit
end

--- Whether a fan oscillates (and can be told to).
function Model.canOscillate(e)
    return e.attr.oscillating ~= nil or (features(e) % 4 >= 2)
end

--- A thermostat's modes, without repeats, in Home Assistant's order.
function Model.hvacModes(e)
    local seen, out = {}, {}
    for __, m in ipairs(type(e.attr.hvac_modes) == "table" and e.attr.hvac_modes or {}) do
        if not seen[m] then
            seen[m] = true
            table.insert(out, m)
        end
    end
    return out
end

--- Climate step size (°F 1, °C 0.5 unless the thermostat says).
function Model.tempStep(e, unit)
    return num(e.attr.target_temp_step) or ((unit or ""):find("C") and 0.5 or 1)
end

--- Seconds as "just now" / "3 min ago" / "2 h ago".
-- ------------------------------------------------------------------ screens of their own

--- Every battery (hidden ones left out), lowest first: { e, percent }.
function Model.batteryList(snap, settings)
    local out = {}
    for __, e in ipairs(snap.list) do
        if e.domain == "sensor" and str(e.attr.device_class) == "battery" and not (settings.hidden and settings.hidden[e.id]) then
            local v = tonumber(e.state)
            if v then table.insert(out, { e = e, percent = v }) end
        end
    end
    table.sort(out, function(a, b) if a.percent ~= b.percent then return a.percent < b.percent end return a.e.name < b.e.name end)
    return out
end

-- A 3D printer's entities, by their names (Flashforge, Bambu, Prusa, OctoPrint, Klipper...).
local PRINTER_WORDS = { "flashforge", "bambu", "prusa", "creality", "octoprint", "klipper", "moonraker", "3d_printer",
    "ender", "ad5m", "elegoo", "anycubic", "voron" }
-- Not the printer: a proxy or a container named after it.
local NOT_PRINTER = { "pangolin", "lxc_", "proxmox", "uptime" }
-- What a printer's screen shows first: its state and the print, then temperatures.
local PRINTER_FIRST = { "online", "status", "state", "progress", "remaining", "finish", "file", "job", "layer",
    "nozzle", "hotend", "bed", "chamber", "temperature", "filament", "health" }

function Model.isPrinter(e)
    local id = e.id:lower()
    for __, w in ipairs(NOT_PRINTER) do
        if id:find(w, 1, true) then return false end
    end
    for __, w in ipairs(PRINTER_WORDS) do
        if id:find(w, 1, true) then return true end
    end
    return false
end

--- The 3D printer's entities (hidden ones left out): cameras first, then
-- state and the print, then the rest by name. When one device has a nozzle
-- or a print's progress, only that device's (not, say, a monitor of its
-- computer named after it).
function Model.printer(snap, settings)
    local out, printing = {}, {}
    for __, word in ipairs({ "progress", "nozzle" }) do
        for __, e in ipairs(snap.list) do
            if Model.isPrinter(e) and e.id:find(word, 1, true) then printing[e.device] = true end
        end
        if next(printing) then break end
    end
    local onlyThose = next(printing) ~= nil
    for __, e in ipairs(snap.list) do
        if Model.isPrinter(e) and not (settings.hidden and settings.hidden[e.id]) and (not onlyThose or printing[e.device]) then
            local rank = #PRINTER_FIRST + 1
            local name = e.name:lower()
            for i, w in ipairs(PRINTER_FIRST) do
                if name:find(w, 1, true) then rank = i break end
            end
            if e.domain == "camera" then rank = 0 end
            table.insert(out, { e = e, rank = rank })
        end
    end
    table.sort(out, function(a, b) if a.rank ~= b.rank then return a.rank < b.rank end return a.e.name < b.e.name end)
    for i, x in ipairs(out) do out[i] = x.e end
    return out
end

--- Everything visible, most recently changed first.
function Model.activity(snap, settings)
    local out = {}
    for __, e in ipairs(snap.list) do
        if e.changed and Model.visible(e, settings) and e.domain ~= "camera" then table.insert(out, e) end
    end
    table.sort(out, function(a, b) return a.changed > b.changed end)
    return out
end

--- A time from Home Assistant ("2026-10-21T05:00:00+00:00", "...Z", or no
-- zone: local) as os.time(), or nil.
--- Home Assistant's notice text: markdown links and bold made plain.
function Model.plain(s)
    s = tostring(s or ""):gsub("%[([^%]]*)%]%([^%)]*%)", "%1"):gsub("%*%*", ""):gsub("__", "")
    return s
end

function Model.isoTime(iso)
    local y, mo, d, h, mi, s, zone = tostring(iso or ""):match("^(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):?(%d*)[%.%d]*(.*)$")
    if not y then
        y, mo, d = tostring(iso or ""):match("^(%d+)-(%d+)-(%d+)")
        if not y then return nil end
        return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
    end
    local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi),
        sec = tonumber(s) or 0 })
    if zone == "" then return t end
    -- The fields were UTC (less the zone's offset), read above as local time.
    local zs, zh, zm = zone:match("^([%+%-])(%d%d):?(%d%d)$")
    local offset = zs and ((tonumber(zh) * 3600 + tonumber(zm) * 60) * (zs == "-" and -1 or 1)) or 0
    -- This place's offset from UTC then (summer time included).
    local here = t - os.time(os.date("!*t", t)) + (os.date("*t", t).isdst and 3600 or 0)
    return t + here - offset
end

--- The hour of an hourly forecast: "3 PM", or "15:00" on a 24-hour clock.
function Model.hourLabel(iso, h24)
    local t = Model.isoTime(iso)
    if not t then return "" end
    local hour = os.date("*t", t).hour
    if h24 then return string.format("%02d:00", hour) end
    return ((hour + 11) % 12 + 1) .. (hour < 12 and " AM" or " PM")
end

--- The day of a forecast ("2026-10-21T..."): "Today", "Tomorrow" or "Wednesday".
function Model.dayName(iso, now)
    local t = Model.isoTime(iso)
    if not t then return "" end
    local at = os.date("*t", t)
    t = os.time({ year = at.year, month = at.month, day = at.day, hour = 12 })
    local today = os.date("*t", now or os.time())
    local days = math.floor((t - os.time({ year = today.year, month = today.month, day = today.day, hour = 12 })) / 86400 + 0.5)
    if days == 0 then return "Today" end
    if days == 1 then return "Tomorrow" end
    return os.date("%A", t)
end

--- The next calendar event (from calendar entities): { title, start (os.time), allDay, calendar } or nil.
function Model.nextEvent(snap, now)
    local best
    for __, e in ipairs(snap.list) do
        if e.domain == "calendar" and str(e.attr.message) and str(e.attr.start_time) then
            local t = Model.isoTime(e.attr.start_time)
            if t and (t >= (now or os.time()) - 3600 or e.state == "on") and (not best or t < best.start) then
                best = { title = e.attr.message, start = t, allDay = e.attr.all_day == true, calendar = e.name }
            end
        end
    end
    return best
end

function Model.ago(seconds)
    if not seconds or seconds < 60 then return "just now" end
    local m = math.floor(seconds / 60)
    if m < 60 then return m .. " min ago" end
    return math.floor(m / 60) .. " h ago"
end

-- ------------------------------------------------------------------ the dashboard's sections

--- Home's sections, in their default order.
Model.HOME_SECTIONS = { "status", "shortcuts", "routines", "on", "quick", "rooms" }

--- The Clock and info dashboard's sections, in their default order.
Model.DASH_SECTIONS = { "status", "rooms", "next", "media", "tasks", "scenes", "graph", "camera", "quick" }

--- Whether a dashboard section is hidden. The status bar and room
-- temperatures keep their own switches (the web page sets them too); Today's
-- tasks and Scenes start hidden (they take the camera's room).
function Model.dashHidden(settings, key)
    if key == "status" then return settings.dash_attention == false end
    if key == "rooms" then return settings.dash_temps == false end
    local h = settings.dash_hidden and settings.dash_hidden[key]
    if h == nil then return key == "tasks" or key == "scenes" or key == "graph" end
    return h == true
end

function Model.setDashHidden(settings, key, hidden)
    if key == "status" then settings.dash_attention = not hidden
    elseif key == "rooms" then settings.dash_temps = not hidden
    else
        settings.dash_hidden = settings.dash_hidden or {}
        settings.dash_hidden[key] = hidden
    end
end

--- The sections in the saved order (all of them, hidden too).
function Model.dashSections(settings)
    return Model.ordered(Model.DASH_SECTIONS, settings.dash_sections, function(k) return k end)
end

local function savedList(snap, ids)
    local out = {}
    for __, id in ipairs(ids) do
        if snap.byId[id] then table.insert(out, snap.byId[id]) end
    end
    return out
end

--- The dashboard's tiles: its own list once changed, else Home's Quick tiles.
function Model.dashQuick(snap, settings)
    if settings.dash_quick then return savedList(snap, settings.dash_quick) end
    return Model.quick(snap, settings)
end

--- The dashboard's scene and script buttons: its own list once changed, else
-- every scene, then every script, shown.
function Model.dashScenes(snap, settings)
    if settings.dash_scenes then return savedList(snap, settings.dash_scenes) end
    local scenes, scripts = {}, {}
    for __, e in ipairs(snap.list) do
        if Model.visible(e, settings) then
            if e.domain == "scene" then table.insert(scenes, e)
            elseif e.domain == "script" then table.insert(scripts, e) end
        end
    end
    local byName = function(a, b) return a.name < b.name end
    table.sort(scenes, byName)
    table.sort(scripts, byName)
    for __, e in ipairs(scripts) do table.insert(scenes, e) end
    return scenes
end

--- Whether `e` goes in the dashboard's scene buttons (else its tiles).
function Model.isSceneButton(e)
    return e.domain == "scene" or e.domain == "script"
end

--- The player to show on the dashboard: one playing, else one paused (shown ones only).
function Model.nowPlaying(snap, settings)
    local paused
    for __, e in ipairs(snap.list) do
        if e.domain == "media_player" and not Model.isGroup(e) and Model.visible(e, settings) then
            if e.state == "playing" then return e end
            if e.state == "paused" and not paused then paused = e end
        end
    end
    return paused
end

--- A player's buttons: { icon, service } for those it has (previous, play or pause, next).
function Model.mediaButtons(e)
    local f = features(e)
    local function has(b) return math.floor(f / b) % 2 == 1 end
    local out = {}
    if has(16) then table.insert(out, { "skip-back", "media_player.media_previous_track" }) end
    if e.state == "playing" then
        if has(1) then table.insert(out, { "pause", "media_player.media_pause" }) end
    elseif has(16384) or has(1) then
        table.insert(out, { "play", "media_player.media_play" })
    end
    if has(32) then table.insert(out, { "skip-forward", "media_player.media_next_track" }) end
    return out
end

--- What a player is playing: "Title · Artist", or its app or source.
function Model.playingText(e)
    local a = e.attr
    local title, artist = str(a.media_title), str(a.media_artist)
    if title and artist then return title .. " \u{00B7} " .. artist end
    return title or str(a.app_name) or str(a.source) or (e.state == "paused" and "Paused" or "Playing")
end

-- ------------------------------------------------------------------ Security's cameras

--- The Cameras screen's cameras (and the dashboard's when it rotates through
-- them) in their order (a 3D printer's last until reordered); `all` keeps the
-- ones hidden there.
function Model.cameraList(snap, settings, all)
    local cams, printers = {}, {}
    for __, e in ipairs(snap.list) do
        if e.domain == "camera" and Model.visible(e, settings)
                and (all or not (settings.cameras_hidden and settings.cameras_hidden[e.id])) then
            table.insert(Model.isPrinter(e) and printers or cams, e)
        end
    end
    for __, e in ipairs(printers) do table.insert(cams, e) end
    return Model.ordered(cams, settings.camera_order, function(e) return e.id end)
end

--- Whether a camera is left out of Security: as set, else a 3D printer's
-- camera is (it stays in Cameras and Printer).
function Model.securityHidden(snap, settings, e)
    local h = settings.security_hidden and settings.security_hidden[e.id]
    if h ~= nil then return h end
    return Model.isPrinter(e)
end

--- Security's cameras in their order (the dashboard's camera first until
-- reordered); `all` keeps the ones left out.
function Model.securityCams(snap, settings, all)
    local cams = {}
    for __, e in ipairs(snap.list) do
        if e.domain == "camera" and Model.visible(e, settings) and (all or not Model.securityHidden(snap, settings, e)) then
            table.insert(cams, e)
        end
    end
    local order = settings.security_cams
    if not order and settings.dash_camera and snap.byId[settings.dash_camera] then order = { settings.dash_camera } end
    return Model.ordered(cams, order, function(e) return e.id end)
end

-- ------------------------------------------------------------------ the doorbell, waking, history

--- Doorbells with a camera: their ring sensors, and the motion sensors on the
-- same device: { [sensor id] = { kind = "ring" | "motion", camera = camera id } }.
function Model.doorbells(snap)
    local cams = {}
    for __, e in ipairs(snap.list) do
        if e.domain == "camera" and e.device ~= "" and not cams[e.device] then cams[e.device] = e.id end
    end
    local out, rings = {}, {}
    for __, e in ipairs(snap.list) do
        local id = e.id:lower()
        if e.domain == "binary_sensor" and cams[e.device] and e.state ~= "unavailable" and not id:find("motion", 1, true)
                and (id:find("doorbell", 1, true) or id:find("_ring", 1, true) or id:find("_ding", 1, true)) then
            out[e.id] = { kind = "ring", camera = cams[e.device] }
            rings[e.device] = true
        end
    end
    for __, e in ipairs(snap.list) do
        local dc = str(e.attr.device_class) or ""
        if e.domain == "binary_sensor" and rings[e.device] and not out[e.id] and e.state ~= "unavailable"
                and (dc == "motion" or dc == "occupancy" or dc == "presence" or e.id:find("motion", 1, true) or e.id:find("person", 1, true)) then
            out[e.id] = { kind = "motion", camera = cams[e.device] }
        end
    end
    return out
end

--- What to say when the Kindle wakes: unlocked locks, open garage doors, open doors and windows.
function Model.wakeIssues(snap, settings)
    local out = {}
    for __, e in ipairs(snap.list) do
        if Model.visible(e, settings) and e.state ~= "unavailable" then
            if (e.domain == "lock" and e.state ~= "locked") or (e.domain == "cover" and Model.icon(e) == "warehouse" and e.state ~= "closed") then
                table.insert(out, e.name .. " " .. Model.title(e.state):lower())
            end
        end
    end
    for __, d in ipairs(snap.doors) do table.insert(out, d.name .. " open") end
    return out
end

--- What can be a sleep screen alert: locks, covers, binary sensors and
-- sensors with a number, by name.
function Model.sleepAlertChoices(snap)
    local out = {}
    for __, e in ipairs(snap and snap.list or {}) do
        local d = e.domain
        if d == "lock" or d == "cover" or d == "binary_sensor" or (d == "sensor" and tonumber(e.state)) then
            table.insert(out, e)
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- The chosen sleep screen alerts (prefs.sleep_alerts, in their order) that
-- say something now: a lock unlocked, a cover open, a binary sensor on
-- ("Back door Open", "Basement Wet"); a sensor always with its value. Text lines.
function Model.sleepAlerts(snap, prefs)
    local out = {}
    for __, id in ipairs(prefs.sleep_alerts or {}) do
        local e = snap and snap.byId[id]
        if e and e.state ~= "unavailable" and e.state ~= "unknown" then
            local d = e.domain
            local show = (d == "lock" and e.state ~= "locked") or (d == "cover" and e.state ~= "closed")
                or (d == "binary_sensor" and e.state == "on") or d == "sensor"
            if show then table.insert(out, e.name .. "  \u{00B7}  " .. Model.stateText(e)) end
        end
    end
    return out
end

--- Sensors with a day worth drawing: temperatures and humidity, by name.
function Model.graphSensors(snap)
    local out = {}
    for __, e in ipairs(snap.list) do
        local dc = str(e.attr.device_class)
        if e.domain == "sensor" and (dc == "temperature" or dc == "humidity") and tonumber(e.state) then table.insert(out, e) end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- History rows ({ state, last_changed }...) as hourly averages over the last
-- `hours` before `now`: { values = { ... } (an hour without a reading keeps
-- the one before; nil before the first), min, max }.
function Model.hourly(rows, now, hours)
    local points = {}
    for __, r in ipairs(type(rows) == "table" and rows or {}) do
        local v, t = tonumber(r.state), Model.isoTime(r.last_changed)
        if v and t then table.insert(points, { t = t, v = v }) end
    end
    table.sort(points, function(a, b) return a.t < b.t end)
    local start = now - hours * 3600
    local values, min, max = {}, nil, nil
    local j, last = 1, nil
    for h = 1, hours do
        local from, to = start + (h - 1) * 3600, start + h * 3600
        local sum, n = 0, 0
        while points[j] and points[j].t < to do
            if points[j].t >= from then sum, n = sum + points[j].v, n + 1 end
            last = points[j].v
            j = j + 1
        end
        local v = n > 0 and sum / n or last
        values[h] = v
        if v then min, max = math.min(min or v, v), math.max(max or v, v) end
    end
    return { values = values, min = min, max = max }
end


--- Plex (its integration's entities, marked `plex` by the template): the
-- server's sensor, who's watching ("user - player": what), its Scan clients
-- button and its libraries (their sensors, when turned on). nil without Plex.
function Model.plex(snap)
    local p = { watching = {}, libraries = {} }
    for __, e in ipairs(snap and snap.list or {}) do
        if e.attr.plex then
            if e.domain == "button" then
                p.scan = e
            elseif e.attr.library_type then
                p.libraries[#p.libraries + 1] = { name = (e.name:gsub("^.-[Ll]ibrary%s*%-?%s*", "")), count = tonumber(e.state), e = e }
            elseif e.domain == "sensor" and not p.server then
                p.server = e
                for k, v in pairs(e.attr) do
                    local who = type(k) == "string" and k:match("^w:(.+)$")
                    if who then p.watching[#p.watching + 1] = { who = who, what = tostring(v) } end
                end
                table.sort(p.watching, function(a, b) return a.who < b.who end)
            end
        end
    end
    if not p.server and not p.scan then return nil end
    p.count = p.server and tonumber(p.server.state) or #p.watching
    table.sort(p.libraries, function(a, b) return a.name:lower() < b.name:lower() end)
    return p
end

return Model
