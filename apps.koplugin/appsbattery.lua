--[[--
The Battery screen: KOReader's own battery statistics (its Battery
statistics plugin: how much went while awake, asleep and charging, since the
last charge) shown plainly, with what is on right now that uses power.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("appscanvas")
local Model = require("appsmodel")

local C = Canvas
local Battery = {}

-- KOReader's statistics object (BatteryStat), or nil when its plugin is off.
local function stat(ui)
    local w = ui and ui.batterystat
    local ok, s = pcall(function() return w and w.stat and w:stat() end)
    return ok and s or nil
end

-- One Usage as { percent, seconds, perHour } (perHour nil when too short to tell).
local function usage(u)
    if type(u) ~= "table" then return nil end
    local ok, secs = pcall(function() return require("ui/time").to_s(u.time or 0) end)
    secs = ok and secs or 0
    local per = secs >= 300 and (u.percentage or 0) / secs * 3600 or nil
    return { percent = u.percentage or 0, seconds = secs, perHour = per }
end

--- What KOReader knows: { pct, charging, awake, asleep, discharging, charged
-- (each { percent, seconds, perHour }), left (seconds awake at the awake
-- rate), on = { what uses power now } } or nil without its statistics.
function Battery.read(ui)
    local powerd = Device:getPowerDevice()
    local okp, pct = pcall(function() return powerd:getCapacity() end)
    local okc, charging = pcall(function() return powerd:isCharging() end)
    local out = { pct = okp and tonumber(pct) or nil, charging = okc and charging == true }
    local s = stat(ui)
    if s then
        -- Brings its numbers up to now (as its own screen does).
        pcall(s.accumulate, s)
        out.available = true
        out.awake, out.asleep = usage(s.awake), usage(s.sleeping)
        out.discharging, out.charged = usage(s.discharging), usage(s.charging)
        if out.pct and out.awake and out.awake.perHour and out.awake.perHour > 0 then
            out.left = out.pct / out.awake.perHour * 3600
        end
    end
    -- What is on now that uses power.
    local on = {}
    local okw, wifi = pcall(function() return NetworkMgr:isWifiOn() end)
    if okw and wifi then table.insert(on, _("Wi-Fi is on")) end
    if Device:hasFrontlight() then
        local okl, light = pcall(function() return powerd:isFrontlightOn() and powerd:frontlightIntensity() end)
        if okl and light then table.insert(on, T(_("Front light at %1"), light)) end
    end
    local web = ui and ui.webpage
    if web and web.address and web:address() ~= "" then table.insert(on, _("Web server running")) end
    local st = ui and ui.syncthing
    local okr, running = pcall(function() return st and st.isRunning and st:isRunning() end)
    if okr and running then table.insert(on, _("Syncthing running")) end
    local reasons = PluginShare.awake_reasons or {}
    if reasons.homeassistant then table.insert(on, _("Home Assistant dashboard keeping the screen on")) end
    if next(reasons) or PluginShare.pause_auto_suspend then table.insert(on, _("Kept awake (it won't sleep by itself)")) end
    out.on = on
    return out
end

local function rate(u)
    if not u then return "" end
    local text = T(_("%1% in %2"), math.floor(u.percent + 0.5), Model.duration(u.seconds))
    if u.perHour then text = text .. "  ·  " .. T(_("%1% an hour"), string.format("%.1f", u.perHour)) end
    return text
end

--- The line on the Battery tile.
function Battery.line(ui)
    local b = Battery.read(ui)
    if not b.pct then return "" end
    if b.charging then return T(_("%1% · Charging"), b.pct) end
    if b.awake and b.awake.perHour then return T(_("%1% · %2% an hour awake"), b.pct, string.format("%.1f", b.awake.perHour)) end
    return T(_("%1%"), b.pct)
end

function Battery.draw(view, c)
    local ui = view:ui()
    local b = Battery.read(ui)
    local F = c:flow(56, c.H - 8, view.batteryPage or 1)
    -- The level, big, and how long it may last.
    F:block(92, function(y)
        local pct = b.pct or 0
        c:icon(b.charging and "battery-charging" or "battery", 14, y + 16, 48)
        if not b.charging and pct > 0 then
            local k = 48 / 24
            c:box(14 + 4.5 * k, y + 16 + 8.5 * k, 11 * k * math.min(100, pct) / 100, 7 * k, { fill = C.BLACK })
        end
        c:text(76, y + 54, b.pct and (b.pct .. "%") or "–", 30, { bold = true })
        local sub = b.charging and _("Charging")
            or (b.left and T(_("About %1 left while awake, at this rate"), Model.duration(b.left)))
            or _("Not enough use yet to tell how long it will last")
        c:text(76, y + 80, sub, 11, { color = C.GREY, maxw = c.W - 90 })
    end)
    local function heading(text)
        F:block(36, function(y) c:text(14, y + 26, text, 9.5, { bold = true, color = C.GREY }) end, 44)
    end
    local function row(label, value, hint)
        F:block(hint and 58 or 44, function(y)
            c:text(14, y + 28, label, 12.5)
            c:text(c.W - 14, y + 28, value, 12, { align = "end", color = C.GREY, maxw = c.W * 0.62 })
            if hint then c:text(14, y + 48, hint, 10, { color = C.GREY, maxw = c.W - 28 }) end
            c:hline(14, y + (hint and 58 or 44), c.W - 28)
        end)
    end
    if not b.available then
        F:block(70, function(y)
            c:text(14, y + 26, _("KOReader's Battery statistics plugin is turned off."), 12, { color = C.GREY, maxw = c.W - 28 })
            c:text(14, y + 50, _("Turn it on in Tools > More tools > Plugin management."), 10.5, { color = C.GREY, maxw = c.W - 28 })
        end)
    else
        heading(_("SINCE THE LAST CHARGE"))
        row(_("Awake"), rate(b.awake))
        row(_("Asleep"), rate(b.asleep))
        row(_("In all"), rate(b.discharging))
        heading(_("THE LAST CHARGE"))
        row(_("Charged"), rate(b.charged))
    end
    heading(_("ON NOW"))
    if #b.on == 0 then
        F:block(40, function(y) c:text(14, y + 26, _("Nothing extra: Wi-Fi off, no light, nothing running."), 12, { color = C.GREY }) end)
    end
    for __, what in ipairs(b.on) do
        F:block(40, function(y) c:text(14, y + 26, "•  " .. what, 12) end)
    end
    F:block(30, function(y)
        c:text(14, y + 24, _("Wi-Fi, the light and anything kept running or awake use the most."), 10, { color = C.GREY, maxw = c.W - 28 })
    end)
    if b.available then
        F:block(64, function(y)
            local label = _("Reset statistics")
            local bw = c:width(label, 12) + 40
            c:box(14, y + 16, bw, 36, { r = 18, border = C.BLACK, bw = 1.4 })
            c:text(14 + bw / 2, y + 39, label, 12, { align = "middle" })
            c:hit(14, y + 10, bw, 48, function()
                require("appsko").confirm{ text = _("Clear KOReader's battery statistics and start counting again?"), ok = _("Clear"), onOk = function()
                        local s = stat(ui)
                        if s then pcall(s.resetAll, s) end
                        view:refresh()
                    end }
            end)
        end)
    end
    view.pages = F:pages()
    if (view.batteryPage or 1) > view.pages then
        view.batteryPage = view.pages
        return view:render()
    end
    view:bar(c, _("Battery"))
end

return Battery
