--[[--
The controls for one entity, as a sheet over the bottom of the screen (hold
a tile to open it): brightness and colour temperature for lights; speed,
presets and oscillation for fans; mode, temperature and fan for thermostats;
open, stop, close and position for covers; lock and unlock; vacuum start,
pause and dock; player controls; Run for scenes and scripts. Every sheet can
add the entity to (or take it off) Quick, or hide it.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("hacanvas")
local Model = require("hamodel")

local C = Canvas
local Sheet = {}

local function steps(view, c, y, n, lit, labels, fn)
    local w = (c.W - 28 - (n - 1) * 4) / n
    for i = 1, n do
        local x = 14 + (i - 1) * (w + 4)
        local on = i <= lit
        c:box(x, y, w, 40, { r = 4, fill = on and C.FILL or C.WHITE, border = C.BLACK })
        if labels then c:text(x + w / 2, y + 25, labels[i], 10.5, { align = "middle", color = on and C.ON_FILL or C.BLACK }) end
        c:hit(x, y, w, 40, function() fn(i) end)
    end
end

local function chips(view, c, y, items, selected, fn)
    local x = 14
    for __, it in ipairs(items) do
        local label = it.label or it
        local value = it.value or it
        local w = c:width(label, 11) + 28
        if x + w > c.W - 14 then break end
        local sel = value == selected
        c:box(x, y, w, 30, { r = 15, fill = sel and C.FILL or C.WHITE, border = C.BLACK })
        c:text(x + w / 2, y + 19, label, 11, { align = "middle", color = sel and C.ON_FILL or C.BLACK })
        c:hit(x, y, w, 30, function() fn(value) end)
        x = x + w + 8
    end
end

local function toggle(c, x, y, on, fn)
    c:box(x, y, 40, 22, { r = 11, fill = on and C.FILL or C.WHITE, border = C.BLACK })
    c:circle(x + (on and 29 or 11), y + 11, 7, on and C.ON_FILL or C.BLACK)
    c:hit(x - 10, y - 8, 60, 38, fn)
end
Sheet.toggle = toggle

local function label(c, y, s, right)
    c:text(14, y + 12, s, 9.5, { bold = true, color = C.GREY })
    if right then c:text(c.W - 14, y + 12, right, 9.5, { align = "end", color = C.GREY }) end
end

local function plusMinus(view, c, y, value, fn)
    c:circle(46, y + 32, 30, C.BLACK, 1.2)
    c:icon("minus", 34, y + 20, 24)
    c:hit(14, y, 64, 64, function() fn(-1) end)
    c:text(c.W / 2, y + 48, value, 40, { bold = true, align = "middle" })
    c:circle(c.W - 46, y + 32, 30, C.BLACK, 1.2)
    c:icon("plus", c.W - 58, y + 20, 24)
    c:hit(c.W - 78, y, 64, 64, function() fn(1) end)
end

-- Rows of the sheet for each kind: { height, draw(y) }.
local function rows(view, c, e)
    local ha, id, a = view.ha, e.id, e.attr
    local out = {}
    local function add(h, draw) table.insert(out, { h = h, draw = draw }) end
    local function act(service, data)
        data = data or {}
        data.entity_id = id
        ha:act(e, service, data)
    end
    if e.state == "unavailable" then
        add(40, function(y) c:text(14, y + 20, _("This device is unavailable in Home Assistant."), 11, { color = C.GREY }) end)
        return out
    end
    local d = e.domain
    if d == "light" then
        if Model.dimmable(e) then
            local pct = e.state == "on" and (Model.brightnessPercent(e) or 100) or 0
            add(68, function(y)
                label(c, y, _("BRIGHTNESS"), e.state == "on" and (pct .. "%") or _("off"))
                local labels = {}
                for i = 1, 10 do labels[i] = tostring(i * 10) end
                steps(view, c, y + 20, 10, math.floor(pct / 10 + 0.5), labels, function(i) act("light.turn_on", { brightness_pct = i * 10 }) end)
            end)
        end
        if Model.hasColor(e) then
            -- Colours: a circle each (its own grey) with its name under it.
            local now = Model.colorOf(e)
            local per = c.W > c.H and 10 or 5
            local rows = math.ceil(#Model.COLORS / per)
            add(24 + rows * 70, function(y)
                label(c, y, _("COLOR"), now and _(now.name) or nil)
                local cw = (c.W - 28) / per
                for i, col in ipairs(Model.COLORS) do
                    local cx = 14 + ((i - 1) % per) * cw + cw / 2
                    local cy = y + 44 + math.floor((i - 1) / per) * 70
                    local sel = now == col
                    c:circle(cx, cy, 20, require("ffi/blitbuffer").Color8(col.grey))
                    c:circle(cx, cy, 20, C.BLACK, sel and 3.5 or 1)
                    if sel then c:icon("check", cx - 9, cy - 9, 18, col.grey < 0x99) end
                    c:text(cx, cy + 36, _(col.name), 9.5, { align = "middle", bold = sel, maxw = cw - 4 })
                    c:hit(cx - cw / 2, cy - 24, cw, 66, function() act("light.turn_on", Model.colorData(e, col)) end)
                end
            end)
        end
        if Model.hasColorTemp(e) then
            local lo, hi = Model.num(a.min_color_temp_kelvin), Model.num(a.max_color_temp_kelvin) or 6500
            local now = Model.num(a.color_temp_kelvin)
            local mid = math.floor((lo + hi) / 2)
            local sel = now and (now < lo + (mid - lo) / 2 and lo or now > mid + (hi - mid) / 2 and hi or mid)
            -- Set to a colour: no white is lit.
            if Model.str(a.color_mode) and a.color_mode ~= "color_temp" then sel = nil end
            add(58, function(y)
                label(c, y, _("COLOR TEMPERATURE"))
                chips(view, c, y + 20, { { label = _("Warm"), value = lo }, { label = _("Neutral"), value = mid }, { label = _("Cool"), value = hi } },
                    sel, function(k) act("light.turn_on", { color_temp_kelvin = k }) end)
            end)
        end
    elseif d == "fan" then
        local n, lit = Model.fanSteps(e)
        if Model.num(a.percentage) or Model.num(a.percentage_step) then
            add(68, function(y)
                label(c, y, _("SPEED"), e.state == "on" and Model.num(a.percentage) and (math.floor(a.percentage + 0.5) .. "%") or nil)
                local labels = {}
                for i = 1, n do labels[i] = tostring(i) end
                steps(view, c, y + 20, n, lit, labels, function(i) act("fan.set_percentage", { percentage = math.floor(i * 100 / n + 0.5) }) end)
            end)
        end
        if type(a.preset_modes) == "table" and #a.preset_modes > 0 then
            add(58, function(y)
                label(c, y, _("PRESET"))
                chips(view, c, y + 20, a.preset_modes, Model.str(a.preset_mode), function(p) act("fan.set_preset_mode", { preset_mode = p }) end)
            end)
        end
        if Model.canOscillate(e) then
            add(40, function(y)
                c:text(14, y + 22, _("Oscillate"), 12)
                toggle(c, c.W - 54, y + 6, a.oscillating == true, function() act("fan.oscillate", { oscillating = a.oscillating ~= true }) end)
            end)
        end
    elseif d == "climate" then
        local modes = Model.hvacModes(e)
        if #modes > 0 then
            local items = {}
            for __, m in ipairs(modes) do table.insert(items, { label = Model.title(m), value = m }) end
            add(58, function(y)
                label(c, y, _("MODE"), Model.str(a.hvac_action) and Model.title(a.hvac_action) or nil)
                chips(view, c, y + 20, items, e.state, function(m) act("climate.set_hvac_mode", { hvac_mode = m }) end)
            end)
        end
        local unit = ha.snap and ha.snap.weather and ha.snap.weather.unit
        local step = Model.tempStep(e, unit)
        local function clamp(v)
            local lo, hi = Model.num(a.min_temp), Model.num(a.max_temp)
            if lo and v < lo then v = lo end
            if hi and v > hi then v = hi end
            return v
        end
        if e.state == "heat_cool" and Model.num(a.target_temp_low) and Model.num(a.target_temp_high) then
            add(88, function(y)
                label(c, y, _("HEAT TO"))
                plusMinus(view, c, y + 18, Model.formatTemp(a.target_temp_low), function(dir)
                    act("climate.set_temperature", { target_temp_low = clamp(a.target_temp_low + dir * step), target_temp_high = a.target_temp_high })
                end)
            end)
            add(88, function(y)
                label(c, y, _("COOL TO"))
                plusMinus(view, c, y + 18, Model.formatTemp(a.target_temp_high), function(dir)
                    act("climate.set_temperature", { target_temp_low = a.target_temp_low, target_temp_high = clamp(a.target_temp_high + dir * step) })
                end)
            end)
        elseif Model.num(a.temperature) then
            local title = e.state == "cool" and _("COOL TO") or e.state == "heat" and _("HEAT TO") or _("SET TO")
            add(88, function(y)
                label(c, y, title)
                plusMinus(view, c, y + 18, Model.formatTemp(a.temperature), function(dir)
                    a.temperature = clamp(a.temperature + dir * step)
                    act("climate.set_temperature", { temperature = a.temperature })
                end)
            end)
        end
        if type(a.fan_modes) == "table" and #a.fan_modes > 0 then
            local items = {}
            for __, m in ipairs(a.fan_modes) do table.insert(items, { label = Model.title(m), value = m }) end
            add(58, function(y)
                label(c, y, _("FAN"))
                chips(view, c, y + 20, items, Model.str(a.fan_mode), function(m) act("climate.set_fan_mode", { fan_mode = m }) end)
            end)
        end
    elseif d == "cover" then
        add(52, function(y)
            local w = (c.W - 44) / 3
            local items = { { _("Open"), "cover.open_cover", "arrow-up" }, { _("Stop"), "cover.stop_cover", "x" }, { _("Close"), "cover.close_cover", "arrow-down" } }
            for i, it in ipairs(items) do
                view:button(c, 14 + (i - 1) * (w + 8), y + 4, w, 40, it[1], it[3], function()
                    local action = Model.tapAction(e, ha.prefs)
                    if it[2] ~= "cover.stop_cover" and action.confirm then
                        require("hako").confirm{ text = T(_("%1 %2?"), it[1], e.name), ok = it[1], onOk = function() act(it[2]) end }
                    else
                        act(it[2])
                    end
                end)
            end
        end)
        if Model.num(a.current_position) then
            add(68, function(y)
                label(c, y, _("POSITION"), a.current_position .. "%")
                local labels = {}
                for i = 1, 10 do labels[i] = tostring(i * 10) end
                steps(view, c, y + 20, 10, math.floor(a.current_position / 10 + 0.5), labels,
                    function(i) act("cover.set_cover_position", { position = i * 10 }) end)
            end)
        end
    elseif d == "lock" then
        add(52, function(y)
            local locked = e.state == "locked"
            view:button(c, 14, y + 4, c.W - 28, 40, locked and _("Unlock") or _("Lock"), locked and "lock-open" or "lock",
                function() view:tapEntity(e) end, true)
        end)
    elseif d == "vacuum" then
        add(52, function(y)
            local w = (c.W - 44) / 3
            local items = { { _("Start"), "vacuum.start", "play" }, { _("Pause"), "vacuum.pause", "pause" }, { _("Return to dock"), "vacuum.return_to_base", "house" } }
            for i, it in ipairs(items) do
                view:button(c, 14 + (i - 1) * (w + 8), y + 4, w, 40, it[1], it[3], function() act(it[2]) end)
            end
        end)
    elseif d == "media_player" then
        add(150, function(y) Sheet.mediaControls(view, c, 14, y, c.W - 28, e) end)
    elseif d == "camera" then
        add(62, function(y) Sheet.placeholderChips(view, c, y + 4, e) end)
        add(52, function(y)
            view:button(c, 14, y + 4, c.W - 28, 40, _("Open full screen"), "camera", function()
                view.sheet = nil
                view:go({ kind = "camera", id = id })
            end)
        end)
    elseif d == "sensor" and tonumber(e.state) then
        add(132, function(y)
            label(c, y, _("LAST 24 HOURS"))
            view:graph(c, 14, y + 24, c.W - 28, 96, e)
        end)
    elseif d == "scene" or d == "script" then
        add(52, function(y) view:button(c, 14, y + 4, c.W - 28, 40, _("Run"), "play", function() view:tapEntity(e) end, true) end)
    end
    return out
end

--- Which drawing stands in for a camera's picture: Automatic (by its name), Doorway, Garage or Room.
function Sheet.placeholderChips(view, c, y, e)
    local ha = view.ha
    local picked = ha.prefs.placeholders and ha.prefs.placeholders[e.id] or "auto"
    label(c, y, _("PLACEHOLDER IMAGE"))
    local items = { { label = _("Automatic"), value = "auto" } }
    for __, p in ipairs(Model.PLACEHOLDERS) do table.insert(items, { label = _(p[2]), value = p[1] }) end
    chips(view, c, y + 20, items, picked, function(v)
        ha.prefs.placeholders = ha.prefs.placeholders or {}
        ha.prefs.placeholders[e.id] = v ~= "auto" and v or nil
        ha:savePrefs()
        view:refresh("ui")
    end)
end

local function inQuick(prefs, snap, id)
    for __, e in ipairs(Model.quick(snap, prefs)) do
        if e.id == id then return true end
    end
    return false
end

--- Quick as a saved list (the default made explicit the first time it changes).
local function setQuick(ha, id, add)
    local list = {}
    for __, e in ipairs(Model.quick(ha.snap, ha.prefs)) do
        if e.id ~= id then table.insert(list, e.id) end
    end
    if add then table.insert(list, id) end
    ha.prefs.quick = list
    ha:savePrefs()
end

--- Quick on Home, and the dashboard's tiles (or its scene buttons): added or removed.
function Sheet.pinMenu(view, e)
    local ha = view.ha
    local quick = inQuick(ha.prefs, ha.snap, e.id)
    local key = Model.isSceneButton(e) and "dash_scenes" or "dash_quick"
    local current = key == "dash_scenes" and Model.dashScenes(ha.snap, ha.prefs) or Model.dashQuick(ha.snap, ha.prefs)
    local onDash = false
    for __, x in ipairs(current) do if x.id == e.id then onDash = true end end
    require("hako").list(e.name, {
        { text = quick and _("Remove from Quick") or _("Add to Quick"), fn = function()
            setQuick(ha, e.id, not quick)
            view:refresh("ui")
            view:settle(1.5)
        end },
        { text = onDash and _("Remove from dashboard") or _("Add to dashboard"), fn = function()
            local list = {}
            for __, x in ipairs(current) do if x.id ~= e.id then table.insert(list, x.id) end end
            if not onDash then table.insert(list, e.id) end
            ha.prefs[key] = list
            ha:savePrefs()
            view:refresh("ui")
            view:settle(1.5)
        end },
    })
end

function Sheet.draw(view, c, e)
    local ha = view.ha
    local list = rows(view, c, e)
    local h = 72 + 60
    for __, r in ipairs(list) do h = h + r.h end
    local top = c.H - h
    -- Anywhere above the sheet closes it.
    c:hit(0, 0, c.W, top, function() view:closeSheet() end)
    c:hit(0, top, c.W, h, function() end)
    c:rect(0, top, c.W, h, C.WHITE)
    c:hline(0, top, c.W, C.BLACK, 2)
    c:box(c.W / 2 - 24, top + 8, 48, 4, { r = 2, fill = C.LIGHT })
    c:icon(Model.icon(e), 14, top + 24, 22)
    c:text(46, top + 40, e.name, 15, { bold = true, maxw = c.W - 120 })
    c:text(46, top + 57, (e.area ~= "" and (e.area .. "  ·  ") or "") .. Model.stateText(e), 10, { color = C.GREY, maxw = c.W - 120 })
    local d = e.domain
    if (d == "light" or d == "switch" or d == "fan" or d == "input_boolean") and e.state ~= "unavailable" then
        toggle(c, c.W - 58, top + 28, e.state == "on", function() ha:act(e, d .. ".toggle", { entity_id = e.id }) end)
    end
    -- A player's power, the same switch (when Home Assistant can turn it on or off).
    if d == "media_player" and e.state ~= "unavailable" then
        local canOn, canOff = Model.power(e)
        if canOn or canOff then toggle(c, c.W - 58, top + 28, Model.isOn(e), function() Sheet.power(view, e) end) end
    end
    local y = top + 72
    for __, r in ipairs(list) do
        r.draw(y)
        y = y + r.h
    end
    local w = (c.W - 44) / 3
    view:button(c, 14, y + 8, w, 40, _("Quick & dashboard"), "star", function() Sheet.pinMenu(view, e) end)
    view:button(c, 22 + w, y + 8, w, 40, _("Hide"), "eye-off", function()
        ha.prefs.hidden = ha.prefs.hidden or {}
        ha.prefs.shown = ha.prefs.shown or {}
        ha.prefs.hidden[e.id] = true
        ha.prefs.shown[e.id] = nil
        ha:savePrefs()
        view:closeSheet()
    end)
    view:button(c, 30 + 2 * w, y + 8, w, 40, _("Close"), nil, function() view:closeSheet() end)
end

-- ------------------------------------------------------------------ media

local function stillOff(e)
    require("hako").message(T(_("%1 is still off. Home Assistant can turn it on only once Wake-on-LAN or a turn-on automation is set up for it."), e.name))
end

--- The power switch: off, or on. A TV Home Assistant cannot turn on (an LG
-- without Wake-on-LAN) is not asked; one that says yes but stays off is
-- checked again a little later.
function Sheet.power(view, e)
    local ha = view.ha
    local canOn, canOff = Model.power(e)
    if Model.isOn(e) then
        if canOff then ha:act(e, "media_player.turn_off", { entity_id = e.id }) end
        return
    end
    if not canOn then return stillOff(e) end
    ha:act(e, "media_player.turn_on", { entity_id = e.id })
    UIManager:scheduleIn(10, function() ha:update(true) end)
    UIManager:scheduleIn(16, function()
        local now = ha.snap and ha.snap.byId[e.id]
        if now and not Model.isOn(now) then stillOff(e) end
    end)
end

--- Transport, mute, volume and source: 150 tall (100 in a card, without what is playing).
function Sheet.mediaControls(view, c, x, y, w, e, card)
    local ha, a = view.ha, e.attr
    local function act(service, data)
        data = data or {}
        data.entity_id = e.id
        ha:act(e, service, data)
    end
    local bx = x
    for __, it in ipairs({ { "skip-back", "media_player.media_previous_track" },
            { e.state == "playing" and "pause" or "play", "media_player.media_play_pause" },
            { "skip-forward", "media_player.media_next_track" } }) do
        c:box(bx, y + 4, 56, 44, { r = 8, border = C.BLACK })
        c:icon(it[1], bx + 18, y + 16, 20)
        c:hit(bx, y + 4, 56, 44, function() act(it[2]) end)
        bx = bx + 64
    end
    bx = bx + 16
    local muted = a.is_volume_muted == true
    c:box(bx, y + 4, 44, 44, { r = 8, fill = muted and C.FILL or C.WHITE, border = C.BLACK })
    c:icon("volume-x", bx + 12, y + 16, 20, muted)
    c:hit(bx, y + 4, 44, 44, function() act("media_player.volume_mute", { is_volume_muted = not muted }) end)
    c:box(bx + 52, y + 4, 44, 44, { r = 8, border = C.BLACK })
    c:icon("minus", bx + 64, y + 16, 20)
    c:hit(bx + 52, y + 4, 44, 44, function() act("media_player.volume_down") end)
    local vol = Model.num(a.volume_level)
    c:text(bx + 126, y + 31, vol and T(_("Vol %1"), math.floor(vol * 100 + 0.5)) or _("Vol"), 12, { bold = true, align = "middle" })
    c:box(bx + 156, y + 4, 44, 44, { r = 8, border = C.BLACK })
    c:icon("plus", bx + 168, y + 16, 20)
    c:hit(bx + 156, y + 4, 44, 44, function() act("media_player.volume_up") end)
    if type(a.source_list) == "table" and #a.source_list > 0 then
        c:box(x, y + 60, w, 36, { r = 8, border = C.BLACK })
        c:text(x + 12, y + 83, _("Source"), 11, { color = C.GREY })
        c:text(x + 72, y + 83, Model.str(a.source) or _("Choose"), 11.5, { bold = true, maxw = w - 110 })
        c:icon("chevron-down", x + w - 24, y + 71, 14)
        c:hit(x, y + 60, w, 36, function() Sheet.pickSource(view, e) end)
    end
    local now = not card and Model.str(a.media_title)
    if now then
        c:text(x, y + 124, now .. (Model.str(a.media_artist) and (" — " .. a.media_artist) or ""), 11, { color = C.GREY, maxw = w })
    end
end

function Sheet.pickSource(view, e)
    local items = {}
    for __, s in ipairs(e.attr.source_list) do
        table.insert(items, { text = s, checked = s == e.attr.source, fn = function()
            view.ha:act(e, "media_player.select_source", { entity_id = e.id, source = s })
        end })
    end
    require("hako").list(e.name, items)
end

--- A player as a card on the Media screen: 160 tall.
function Sheet.mediaCard(view, c, x, y, w, e)
    c:box(x, y, w, 160, { r = 10, border = C.BLACK, bw = 1.2 })
    c:icon(Model.icon(e), x + 14, y + 14, 22)
    c:text(x + 46, y + 30, e.name, 15, { bold = true, maxw = w - 110 })
    c:text(x + 46, y + 47, Model.stateText(e) .. (e.area ~= "" and ("  ·  " .. e.area) or ""), 10.5, { color = C.GREY, maxw = w - 110 })
    c:icon("power", x + w - 38, y + 14, 22)
    c:hit(x + w - 50, y, 50, 50, function() view.ha:act(e, "media_player.turn_off", { entity_id = e.id }) end)
    c:hit(x, y, w - 50, 50, function() view:openSheet(e) end)
    Sheet.mediaControls(view, c, x + 14, y + 56, w - 28, e, true)
end

return Sheet
