--[[--
Weather without Home Assistant: Open-Meteo's free forecast (no account or
key) for a place picked once by name, and, in the US, the National Weather
Service's alerts (warnings, watches and advisories). Fetched in a child
process every 30 minutes while Wi-Fi is on and something shows it; the last
one is kept in koreader/settings/apps_weather.lua.

The Weather screen (the launcher's "weather" mode): now, any alerts, the
next 24 hours and the next 7 days. The At a glance line and the widgets sleep
screen use Weather.now(), whichever source is picked (Settings > Launcher >
WEATHER: Home Assistant, Open-Meteo or Off).
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("appscanvas")

local C = Canvas
local Weather = {}

local FORECAST = "https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s"
    .. "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"
    .. "&hourly=temperature_2m,precipitation_probability,weather_code,is_day"
    .. "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"
    .. "&timezone=auto&forecast_days=7&forecast_hours=24&timeformat=unixtime&temperature_unit=%s&wind_speed_unit=%s"
local GEOCODE = "https://geocoding-api.open-meteo.com/v1/search?count=8&format=json&name="
local ALERTS = "https://api.weather.gov/alerts/active?point=%.4f,%.4f"
local EVERY = 30 * 60

-- WMO weather codes: { text, day icon, night icon }.
local CODES = {
    [0] = { "Clear", "sun", "moon" }, [1] = { "Mostly clear", "sun", "moon" }, [2] = { "Partly cloudy", "cloud-sun", "cloud" },
    [3] = { "Cloudy", "cloud" }, [45] = { "Fog", "cloud-fog" }, [48] = { "Freezing fog", "cloud-fog" },
    [51] = { "Light drizzle", "cloud-rain" }, [53] = { "Drizzle", "cloud-rain" }, [55] = { "Heavy drizzle", "cloud-rain" },
    [56] = { "Freezing drizzle", "cloud-rain" }, [57] = { "Freezing drizzle", "cloud-rain" },
    [61] = { "Light rain", "cloud-rain" }, [63] = { "Rain", "cloud-rain" }, [65] = { "Heavy rain", "cloud-rain" },
    [66] = { "Freezing rain", "cloud-rain" }, [67] = { "Freezing rain", "cloud-rain" },
    [71] = { "Light snow", "cloud-snow" }, [73] = { "Snow", "cloud-snow" }, [75] = { "Heavy snow", "cloud-snow" },
    [77] = { "Snow grains", "cloud-snow" }, [80] = { "Showers", "cloud-rain" }, [81] = { "Showers", "cloud-rain" },
    [82] = { "Heavy showers", "cloud-rain" }, [85] = { "Snow showers", "cloud-snow" }, [86] = { "Snow showers", "cloud-snow" },
    [95] = { "Thunderstorms", "cloud-lightning" }, [96] = { "Thunderstorms, hail", "cloud-lightning" },
    [99] = { "Thunderstorms, hail", "cloud-lightning" },
}

--- A weather code as { text, icon } (`night`: the moon for a clear night).
function Weather.code(n, night)
    local e = CODES[tonumber(n) or -1] or { "Unknown", "cloud" }
    return _(e[1]), night and e[3] or e[2]
end

-- ------------------------------------------------------------------ the settings

-- The launcher's settings (apps.lua): weather = "ha" | "openmeteo" | "off" | nil (as fits),
-- weather_place = { name, region, lat, lon, cc }, weather_units = "f" | "c".
local function settings(apps) return apps.settings end

local function ha(apps)
    local p = apps:plugin("homeassistant")
    return p and p.snap and p.snap.weather and p or nil
end

--- The source in use: "ha", "openmeteo" or nil (none). Not picked: Home
-- Assistant's when it has weather, else Open-Meteo's once a place is set.
function Weather.source(apps)
    local s = settings(apps)
    if s.weather == "off" then return nil end
    if s.weather == "ha" then return ha(apps) and "ha" or nil end
    if s.weather == "openmeteo" then return s.weather_place and "openmeteo" or nil end
    if ha(apps) then return "ha" end
    return s.weather_place and "openmeteo" or nil
end

function Weather.sourceName(apps)
    local s = settings(apps)
    local names = { ha = _("Home Assistant"), openmeteo = _("Open-Meteo (free)"), off = _("Off") }
    return s.weather and names[s.weather] or _("Automatic")
end

function Weather.sourceChoices()
    return { { _("Automatic"), "auto" }, { _("Home Assistant"), "ha" }, { _("Open-Meteo (free)"), "openmeteo" }, { _("Off"), "off" } }
end

--- °F in the US (and a few others), else °C, until picked.
function Weather.units(apps)
    local s = settings(apps)
    if s.weather_units then return s.weather_units end
    local cc = s.weather_place and s.weather_place.cc
    return (cc == "US" or cc == "LR" or cc == "MM" or cc == nil) and "f" or "c"
end

-- ------------------------------------------------------------------ fetching

local store
local function file()
    store = store or LuaSettings:open(DataStorage:getSettingsDir() .. "/apps_weather.lua")
    return store
end

--- The last forecast: { at, key, current, hourly, daily, alerts } or nil.
function Weather.data(apps)
    local d = file():readSetting("data")
    local s = settings(apps)
    local p = s.weather_place
    if not (d and p and d.key == string.format("%.3f,%.3f,%s", p.lat, p.lon, Weather.units(apps))) then return nil end
    return d
end

-- One GET in the child: the body, or nil and why.
local function get(url, headers)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{ url = url, method = "GET", headers = headers or {}, sink = ltn12.sink.table(sink) })
    socketutil:reset_timeout()
    if code ~= 200 then return nil, tostring(code) end
    return table.concat(sink)
end

--- The connection test's rows (appstest.lua, in its child): Open-Meteo for the place
-- (or its place search before a place is set) and, in the US, the weather service's alerts.
function Weather.test(apps, Test)
    local s = settings(apps)
    if s.weather == "off" then return {} end
    local rows = {}
    if Weather.source(apps) == "ha" then
        table.insert(rows, { name = _("From Home Assistant"), ok = true, why = _("Tested under Home Assistant") })
    end
    local p = s.weather_place
    local okJson = function(status, body)
        if status == 200 and body:match("^%s*{") then return true end
        return false, T(_("It answered, but with an error (%1)"), status)
    end
    if p then
        local units = Weather.units(apps)
        table.insert(rows, Test.http{ name = _("Open-Meteo forecast"), detail = "api.open-meteo.com",
            url = string.format(FORECAST, p.lat, p.lon, units == "f" and "fahrenheit" or "celsius", units == "f" and "mph" or "kmh"),
            check = okJson })
        if (p.cc or "") == "US" then
            table.insert(rows, Test.http{ name = _("US weather alerts"), detail = "api.weather.gov",
                url = string.format(ALERTS, p.lat, p.lon),
                headers = { ["User-Agent"] = "(kindle-koreader-apps weather)", Accept = "application/geo+json" }, check = okJson })
        end
    else
        table.insert(rows, Test.http{ name = _("Open-Meteo place search"), detail = "geocoding-api.open-meteo.com",
            url = GEOCODE .. "London", check = okJson })
    end
    return rows
end

-- Runs fn() in a child process; done(result) with what it returned (a plain table), or done(nil, why).
local function inChild(fn, done)
    local ffiutil = require("ffi/util")
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, out, why = pcall(fn)
        ffiutil.writeToFD(write_fd, require("dump")({ ok = ok and out ~= nil, out = out, why = ok and why or tostring(out) }), true)
    end, true)
    if not pid then return done(nil, tostring(fd)) end
    local deadline = os.time() + 60
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(0.5, check) end
            ffiutil.terminateSubProcess(pid)
            return done(nil, _("No answer"))
        end
        local raw = (size and size > 0) and ffiutil.readAllFromFD(fd) or ""
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
        end
        local okL, res = pcall(function() return loadstring("return " .. raw)() end)
        if not (okL and type(res) == "table" and res.ok) then return done(nil, okL and type(res) == "table" and res.why or _("No answer")) end
        done(res.out)
    end
    UIManager:scheduleIn(0.5, check)
end

-- The forecast as kept: plain numbers and short lists.
local function shape(f, alerts)
    local cur = f.current or {}
    local out = {
        current = { temp = cur.temperature_2m, feels = cur.apparent_temperature, humidity = cur.relative_humidity_2m,
            code = cur.weather_code, wind = cur.wind_speed_10m, day = cur.is_day ~= 0 },
        hourly = {}, daily = {}, alerts = alerts or {},
    }
    local h = f.hourly or {}
    for i = 1, #(h.time or {}) do
        table.insert(out.hourly, { t = h.time[i], temp = h.temperature_2m[i], rain = h.precipitation_probability[i],
            code = h.weather_code[i], day = (h.is_day or {})[i] ~= 0 })
    end
    local d = f.daily or {}
    for i = 1, #(d.time or {}) do
        table.insert(out.daily, { t = d.time[i], code = d.weather_code[i], high = d.temperature_2m_max[i],
            low = d.temperature_2m_min[i], rain = d.precipitation_probability_max[i],
            sunrise = (d.sunrise or {})[i], sunset = (d.sunset or {})[i] })
    end
    return out
end

local busy = false

--- Fetches again when it's older than 30 minutes (or `force`), Wi-Fi is on
-- and Open-Meteo is the source. done(ok) when it's back (not called when nothing was asked).
function Weather.refresh(apps, force, done)
    if busy or Weather.source(apps) ~= "openmeteo" then return end
    local d = Weather.data(apps)
    if not force and d and os.time() - (d.at or 0) < EVERY then return end
    local okN, online = pcall(function() return require("ui/network/manager"):isConnected() end)
    if not (okN and online) then return end
    local p, units = settings(apps).weather_place, Weather.units(apps)
    busy = true
    inChild(function()
        local json = require("json")
        local body, why = get(string.format(FORECAST, p.lat, p.lon, units == "f" and "fahrenheit" or "celsius", units == "f" and "mph" or "kmh"))
        if not body then return nil, why end
        local f = json.decode(body)
        local alerts = {}
        if p.cc == "US" then
            local a = get(string.format(ALERTS, p.lat, p.lon),
                { ["User-Agent"] = "(kindle-koreader-apps weather)", Accept = "application/geo+json" })
            local okA, aj = pcall(json.decode, a or "")
            -- (JSON's null comes back as something other than a string.)
            local function str(v) return type(v) == "string" and v or nil end
            for __, feat in ipairs(okA and type(aj) == "table" and aj.features or {}) do
                local pr = feat.properties or {}
                table.insert(alerts, { event = str(pr.event), headline = str(pr.headline), severity = str(pr.severity),
                    ends = str(pr.ends) or str(pr.expires), description = str(pr.description), instruction = str(pr.instruction) })
            end
        end
        return shape(f, alerts)
    end, function(out)
        busy = false
        if out then
            out.at = os.time()
            out.key = string.format("%.3f,%.3f,%s", p.lat, p.lon, units)
            file():saveSetting("data", out)
            file():flush()
            -- The launcher's lines and At a glance, drawn again with it.
            if apps.changed then pcall(apps.changed, apps) end
        end
        if done then done(out ~= nil) end
    end)
end

--- Asks for a place by name, then the matches to pick from; done() once one
-- is set, fetched() when its forecast is in.
function Weather.choosePlace(apps, done, fetched)
    local KO = require("appsko")
    KO.askText{ title = _("Your town or city"), text = settings(apps).weather_place and settings(apps).weather_place.name or "",
        ok = _("Search"), okIcon = "search", kind = "name", needsText = true, done = function(name)
                local wait = KO.wait(_("Looking for it…"))
                inChild(function()
                    local body, why = get(GEOCODE .. require("util").urlEncode(name))
                    if not body then return nil, why end
                    local r = require("json").decode(body)
                    local out = {}
                    for __, m in ipairs(r.results or {}) do
                        table.insert(out, { name = m.name, region = m.admin1, country = m.country, cc = m.country_code,
                            lat = m.latitude, lon = m.longitude })
                    end
                    return out
                end, function(list, why)
                    wait.close()
                    if not list then return KO.message(T(_("Couldn't look it up (%1). Is Wi-Fi on?"), why or "?")) end
                    if #list == 0 then return KO.message(T(_("No place called “%1” was found."), name)) end
                    local items = {}
                    for __, m in ipairs(list) do
                        local where = table.concat({ m.region or "", m.country or "" }, ", "):gsub("^, ", ""):gsub(", $", "")
                        table.insert(items, { text = m.name .. (where ~= "" and (", " .. where) or ""), fn = function()
                            settings(apps).weather_place = m
                            apps:save()
                            Weather.refresh(apps, true, fetched)
                            if done then done() end
                        end })
                    end
                    KO.list(_("Which one?"), items)
                end)
    end }
end

-- ------------------------------------------------------------------ for the launcher

local function deg(v) return v and (math.floor(v + 0.5) .. "°") or "–" end
Weather.deg = deg

--- Now, from the source in use: { temp, text, icon, high, low, open = fn } or nil.
function Weather.now(apps, view)
    local src = Weather.source(apps)
    if src == "ha" then
        local p = ha(apps)
        local okM, M = pcall(require, "hamodel")
        if not okM then return nil end
        local w = p.snap.weather
        local text, icon = M.weather(w.state)
        if p.loadForecast then pcall(p.loadForecast, p) end
        local f = p.forecast and p.forecast[1]
        return { temp = w.temp and M.formatTemp(w.temp), text = _(text), icon = icon,
            high = f and f.high and M.formatTemp(f.high), low = f and f.low and M.formatTemp(f.low),
            open = function() p:show({ kind = "weather" }) end }
    elseif src == "openmeteo" then
        Weather.refresh(apps)
        local d = Weather.data(apps)
        if not d then return nil end
        local text, icon = Weather.code(d.current.code, not d.current.day)
        local today = d.daily[1] or {}
        return { temp = deg(d.current.temp), text = text, icon = icon, high = deg(today.high), low = deg(today.low),
            rain = today.rain, alert = d.alerts[1] and d.alerts[1].event,
            open = view and function() view.mode, view.weatherPage = "weather", 1 view:refresh() end }
    end
end

--- The Weather tile's line: "62° Partly cloudy · 70° / 55°", or how to set it up.
function Weather.line(apps)
    local w = Weather.now(apps)
    if not w then
        return Weather.source(apps) == "openmeteo" and _("Loading…") or _("Pick a place")
    end
    local line = (w.temp and (w.temp .. " ") or "") .. w.text
    if w.alert then return line .. " · " .. w.alert end
    if w.high then line = line .. " · " .. w.high .. " / " .. (w.low or "–") end
    return line
end

--- The tile: Home Assistant's weather screen, ours, or setting a place.
function Weather.open(view)
    local apps = view.apps
    local src = Weather.source(apps)
    if src == "ha" then
        local p = ha(apps)
        view.away = true
        p:show({ kind = "weather" })
    elseif src == "openmeteo" then
        view.away = false
        view.mode, view.weatherPage = "weather", 1
        view:refresh()
        Weather.refresh(apps, false, function() if view.mode == "weather" then view:refresh() end end)
    else
        view.away = false
        Weather.choosePlace(apps, function()
            settings(apps).weather = settings(apps).weather ~= "off" and settings(apps).weather or nil
            apps:save()
            view.mode, view.weatherPage = "weather", 1
            view:refresh()
        end, function() if view.mode == "weather" then view:refresh() end end)
    end
end

-- ------------------------------------------------------------------ the screen

local function hour(t)
    if require("appsko").twentyFour() then return os.date("%H", t) end
    local h = tonumber(os.date("%H", t))
    return ((h + 11) % 12 + 1) .. (h < 12 and "a" or "p")
end

function Weather.draw(view, c)
    local apps = view.apps
    local d = Weather.data(apps)
    local p = settings(apps).weather_place
    local F = c:flow(56, c.H - 8, view.weatherPage or 1)
    if not d then
        F:block(90, function(y)
            c:text(14, y + 30, p and _("Getting the forecast…") or _("No place set."), 13, { color = C.GREY })
            c:text(14, y + 56, _("It needs Wi-Fi. Settings > Launcher > WEATHER sets the place."), 11, { color = C.GREY, maxw = c.W - 28 })
        end)
    else
        local cur = d.current
        local text, icon = Weather.code(cur.code, not cur.day)
        local today = d.daily[1] or {}
        -- Now.
        F:block(140, function(y)
            c:text(14, y + 26, p and (p.name .. (p.region and (", " .. p.region) or "")) or "", 12, { color = C.GREY, maxw = c.W - 28 })
            c:icon(icon, 14, y + 42, 64)
            c:text(94, y + 98, deg(cur.temp), 44, { bold = true })
            c:text(c.W - 14, y + 64, text, 15, { align = "end", bold = true })
            c:text(c.W - 14, y + 88, T(_("High %1 · Low %2"), deg(today.high), deg(today.low)), 12, { align = "end", color = C.GREY })
            c:text(c.W - 14, y + 110, T(_("Feels like %1"), deg(cur.feels)), 12, { align = "end", color = C.GREY })
            local bits = {}
            if today.rain then table.insert(bits, T(_("%1% chance of rain today"), today.rain)) end
            if cur.wind then table.insert(bits, T(_("Wind %1 %2"), math.floor(cur.wind + 0.5), Weather.units(apps) == "f" and "mph" or "km/h")) end
            if cur.humidity then table.insert(bits, T(_("Humidity %1%"), cur.humidity)) end
            c:text(14, y + 132, table.concat(bits, "  ·  "), 11, { color = C.GREY, maxw = c.W - 28 })
        end)
        -- Warnings, watches and advisories (US): tap one for the whole text.
        if #d.alerts > 0 then
            F:block(36, function(y) c:text(14, y + 26, _("ALERTS"), 9.5, { bold = true, color = C.GREY }) end, 60)
            for __, a in ipairs(d.alerts) do
                F:block(60, function(y)
                    c:box(14, y + 6, c.W - 28, 50, { r = 8, border = C.BLACK, bw = 1.6 })
                    c:icon("triangle-alert", 24, y + 20, 20)
                    c:text(54, y + 28, a.event or _("Alert"), 13, { bold = true, maxw = c.W - 90 })
                    -- "Until Sun 6:00 PM" (the time as the alert gives it, the place's own).
                    local Y, M, D, h, m = (a.ends or ""):match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+)")
                    local ends = Y and os.time({ year = tonumber(Y), month = tonumber(M), day = tonumber(D), hour = tonumber(h), min = tonumber(m) })
                    local when = ends and os.date(require("appsko").twentyFour() and "%a %H:%M" or "%a %I:%M %p", ends):gsub(" 0", " ")
                    c:text(54, y + 48, when and T(_("Until %1"), when) or (a.severity or ""), 10.5, { color = C.GREY, maxw = c.W - 90 })
                    c:hit(14, y + 6, c.W - 28, 50, function()
                        require("appsko").message({ title = a.headline or a.event,
                            text = (a.description or "") .. (a.instruction and ("\n\n" .. a.instruction) or "") })
                    end)
                end)
            end
        end
        -- The next 24 hours: two rows of twelve, each the hour, its icon, the temperature and the chance of rain.
        F:block(36, function(y) c:text(14, y + 26, _("NEXT 24 HOURS"), 9.5, { bold = true, color = C.GREY }) end, 120)
        for row = 0, 1 do
            F:block(96, function(y)
                local cw = (c.W - 28) / 12
                for i = 1, 12 do
                    local hh = d.hourly[row * 12 + i]
                    if hh then
                        local x = 14 + (i - 1) * cw + cw / 2
                        local _t, ic = Weather.code(hh.code, not hh.day)
                        c:text(x, y + 16, hour(hh.t), 10.5, { align = "middle", color = C.GREY })
                        c:icon(ic, x - 11, y + 24, 22)
                        c:text(x, y + 66, deg(hh.temp), 12, { align = "middle", bold = true })
                        c:text(x, y + 84, (hh.rain and hh.rain > 0) and (hh.rain .. "%") or "", 10, { align = "middle", color = C.GREY })
                    end
                end
                c:hline(14, y + 94, c.W - 28)
            end)
        end
        -- The next 7 days.
        F:block(36, function(y) c:text(14, y + 26, _("NEXT 7 DAYS"), 9.5, { bold = true, color = C.GREY }) end, 50)
        for i, day in ipairs(d.daily) do
            F:block(44, function(y)
                local dtext, ic = Weather.code(day.code)
                c:text(14, y + 28, i == 1 and _("Today") or os.date("%a", day.t), 13, { bold = i == 1 })
                c:icon(ic, 90, y + 11, 22)
                c:text(124, y + 28, dtext, 12, { maxw = c.W * 0.4 })
                if day.rain and day.rain > 0 then c:text(c.W - 150, y + 28, day.rain .. "%", 11, { align = "end", color = C.GREY }) end
                c:text(c.W - 14, y + 28, deg(day.high) .. " / " .. deg(day.low), 12, { align = "end" })
                c:hline(14, y + 44, c.W - 28)
            end)
        end
        F:block(32, function(y)
            c:text(14, y + 22, T(_("Updated %1 · Weather data by Open-Meteo.com%2"), os.date(require("appsko").twentyFour() and "%H:%M" or "%I:%M %p", d.at):gsub("^0", ""),
                (p and p.cc == "US") and _(", alerts from the National Weather Service") or ""), 9.5, { color = C.GREY, maxw = c.W - 28 })
        end)
    end
    view.pages = F:pages()
    if (view.weatherPage or 1) > view.pages then
        view.weatherPage = view.pages
        return view:render()
    end
    view:bar(c, _("Weather"))
end

return Weather
