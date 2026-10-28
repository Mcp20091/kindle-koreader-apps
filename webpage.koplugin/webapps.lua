--[[--
The Apps launcher on the web page (needs the Apps plugin): its tiles (order,
shown or hidden), shortcuts to add or remove (a Home Assistant screen or
room, a To Do list, a notebook, a Notes folder), and its settings, as in Apps > Settings.
]]

local Common = require("webcommon")

local Web = {}

-- Settings the page may change, and their kinds.
local SETTINGS = { layout = "string", clock = "string", columns = "number", clock_24h = "boolean", button_labels = "boolean", button_labels_app = "table", at_start = "boolean",
    today = "boolean", toggles = "boolean", recent = "boolean", recent_notes = "boolean", recent_crosswords = "boolean", recent_together = "boolean", quick_off = "table", wifi_idle = "number",
    weather = "string", weather_units = "string", weather_place = "table", sleep_widgets = "table", sleep_widgets_order = "table" }
local WEATHER = { auto = true, ha = true, openmeteo = true, off = true }
local LAYOUTS = { tiles = true, bold = true, compact = true, list = true, icons = true }

local function apps() return Common.plugin("apps") end

local function state(a)
    local Model = require("appsmodel")
    local s = a.settings
    local out = { installed = true, settings = {}, tiles = {}, choices = {}, groups = {} }
    for k in pairs(SETTINGS) do out.settings[k] = s[k] end
    -- The clock: KOReader's own setting, the same for every app.
    out.settings.clock_24h = not G_reader_settings:isTrue("twelve_hour_clock")
    out.settings.button_labels = G_reader_settings:readSetting("apps_button_labels") ~= false
    -- Each app's own (Default, On, Off), as on the Kindle's Button labels page.
    local okP, Popup = pcall(require, "appspopup")
    if okP and Popup.labelApps then
        out.buttonLabelApps = {}
        local by = G_reader_settings:readSetting("apps_button_labels_by_app") or {}
        for __, ap in ipairs(Popup.labelApps()) do
            if ap.key == "apps" or (a.plugin and a:plugin(ap.plugin)) then
                local v = by[ap.key]
                table.insert(out.buttonLabelApps, { key = ap.key, name = ap.name, value = v == nil and "default" or (v and "on" or "off") })
            end
        end
    end
    local groups = {}
    for __, g in ipairs(s.groups or {}) do
        groups[g.id] = true
        table.insert(out.groups, { id = g.id, name = g.name, icon = g.icon or "folder", sort = g.sort })
    end
    for __, t in ipairs(a:tiles(true)) do
        local g = s.grouped and s.grouped[t.key]
        -- (A tile off by default, such as Restart KOReader, is hidden until shown.)
        local M = package.loaded["appsmodel"]
        local hidden = M and M.isHidden and M.isHidden(s.hidden, t) or (s.hidden and s.hidden[t.key]) == true
        table.insert(out.tiles, { key = t.key, name = t.name, hidden = hidden, pin = t.pin ~= nil,
            groupTile = t.groupTile, group = groups[g] and g or nil, icon = t.icon })
    end
    for __, kind in ipairs({ "ha", "todo", "note", "notefolder", "action", "crossword" }) do
        local list = {}
        for __, p in ipairs(a:pinChoices(kind)) do
            table.insert(list, { key = Model.pinKey(p), name = p.group and (p.group .. " \u{00B7} " .. p.name) or p.name, icon = p.icon })
        end
        out.choices[kind] = list
    end
    -- The quick buttons (appsquick.lua): the list as set, and the built-ins there are.
    local okQ, Quick = pcall(require, "appsquick")
    if okQ then
        local function entry(e)
            local item = Quick.item(e)
            local x = { key = Model.quickKey(e), name = Quick.nameOf(e), here = item ~= nil,
                icon = (e.group and (e.icon or "folder")) or (item and item.icon) or "app-window" }
            if e.b then x.kind = "b" elseif e.pin then x.kind = "pin" elseif e.app then x.kind = "app" else x.kind = "group" end
            if e.items then
                x.items = {}
                for __, sub in ipairs(e.items) do table.insert(x.items, entry(sub)) end
            end
            return x
        end
        out.quick = {}
        for __, e in ipairs(Model.quickList(s)) do table.insert(out.quick, entry(e)) end
        -- Where they show: the home screen's two rows (worked out as the launcher draws them,
        -- on a canvas the Kindle's size), and the built-ins every control center has.
        if Quick.homeKeys then
            local Screen = require("device").screen
            local c = require("appscanvas").new(Screen:getWidth(), Screen:getHeight(), false)
            local okH, __, last = pcall(Quick.homeKeys, c, s)
            out.quickHome = okH and last or 0
            out.quickCore = {}
            for __, e in ipairs(Quick.coreMissing(Model.quickList(s))) do
                local item = Quick.item(e)
                table.insert(out.quickCore, { key = "b:" .. e.b, name = Quick.nameOf(e), icon = item and item.icon or "app-window" })
            end
        end
        out.quickBuiltins = {}
        for __, b in ipairs(Model.QUICK_BUILTIN) do
            if Quick.available(b.key) then table.insert(out.quickBuiltins, { key = "b:" .. b.key, name = b.name, icon = b.icon }) end
        end
        out.settings.toggles = s.toggles ~= false
        -- The widgets sleep screen's parts, in their order, each on or off.
        local okV, View = pcall(require, "appsview")
        if okV and View.widgetOrder then
            out.widgets = {}
            for __, k in ipairs(View.widgetOrder(s)) do
                table.insert(out.widgets, { key = k, name = View.WIDGET_NAMES[k], on = View.widgetOn(s, k) })
            end
        end
        -- Other apps' buttons (a Home Assistant device...), by their groups.
        out.quickApps = {}
        for key, P in pairs(require("pluginshare").quickApps or {}) do
            if P.choices then
                local okC, list = pcall(P.choices)
                local choices = {}
                for __, ch in ipairs(okC and list or {}) do
                    table.insert(choices, { key = "a:" .. key .. ":" .. ch.id, name = ch.name, icon = ch.icon, group = ch.group })
                end
                table.insert(out.quickApps, { key = key, name = P.name or key, choices = choices })
            end
        end
    end
    return out
end

--- The quick buttons from the page: { { key } | { key = "g:...", name, items = { { key } } } }.
-- Built-ins and shortcuts are looked up by key (a shortcut kept as it was, or
-- found among Add shortcut's places); a group keeps its id. Returns the list.
local function quickFromPage(a, list)
    local Model = require("appsmodel")
    local known = {}
    local function mark(l) for __, e in ipairs(l or {}) do known[Model.quickKey(e)] = e if e.items then mark(e.items) end end end
    mark(Model.quickList(a.settings))
    local function pinOf(key)
        if known[key] and known[key].pin then return known[key].pin end
        for __, kind in ipairs({ "ha", "todo", "note", "notefolder", "action", "crossword" }) do
            for __, p in ipairs(a:pinChoices(kind)) do
                if Model.pinKey(p) == key then return p end
            end
        end
    end
    local seen = {}
    local function one(x, inGroup)
        if type(x) ~= "table" or type(x.key) ~= "string" or seen[x.key] then return nil end
        seen[x.key] = true
        local b = x.key:match("^b:(.+)$")
        if b then return Model.quickBuiltin(b) and { b = b } or nil end
        local g = x.key:match("^g:(.+)$")
        if g then
            if inGroup then return nil end
            local items = {}
            for __, sub in ipairs(type(x.items) == "table" and x.items or {}) do
                local e = one(sub, true)
                if e then table.insert(items, e) end
            end
            local name = type(x.name) == "string" and x.name:match("^%s*(.-)%s*$") or ""
            local old = known[x.key]
            return { group = g, name = name ~= "" and name:sub(1, 40) or (old and old.name) or "Group", icon = old and old.icon or "folder", items = items }
        end
        local app, id = x.key:match("^a:([^:]+):(.+)$")
        if app then
            local P = (require("pluginshare").quickApps or {})[app]
            if known[x.key] then return known[x.key] end
            if not (P and P.choices) then return nil end
            local okC, list = pcall(P.choices)
            for __, ch in ipairs(okC and list or {}) do
                if tostring(ch.id) == id then return { app = app, id = ch.id, name = ch.name } end
            end
            return nil
        end
        local p = pinOf(x.key)
        return p and { pin = p } or nil
    end
    local out = {}
    for __, x in ipairs(type(list) == "table" and list or {}) do
        local e = one(x, false)
        if e then table.insert(out, e) end
    end
    return out
end

function Web.routes(server)
    server:route("GET", "^/api/apps$", function(req, res)
        local a = apps()
        if not a then return res:json({ installed = false }) end
        res:json(state(a))
    end)

    -- The quick buttons, as the page's editor left them.
    server:route("POST", "^/api/apps/quick$", function(req, res)
        local a = apps()
        if not a then return res:error(404, "The launcher isn't installed") end
        local b = req.json() or {}
        a.settings.quick = quickFromPage(a, b.list)
        a:changed()
        res:json({ ok = true })
    end)

    -- The icons a group can have (the launcher's own, as SVG drawn in the text colour);
    -- ?all=1: every icon the launcher has (for the quick buttons' editor).
    server:route("GET", "^/api/apps/icons$", function(req, res)
        local a = apps()
        if not a then return res:error(404, "The launcher isn't installed") end
        local list = {}
        local names = require("appsicons").LIST
        if req.query.all then
            names = {}
            local lfs = require("libs/libkoreader-lfs")
            for f in lfs.dir(a.path .. "/icons") do
                local n = f:match("^(.+)%.svg$")
                if n and not n:match("%-w$") then table.insert(names, n) end
            end
        end
        for __, name in ipairs(names) do
            local f = io.open(a.path .. "/icons/" .. name .. ".svg", "rb")
            if f then
                local svg = f:read("*a"):gsub('stroke="#000000"', 'stroke="currentColor"')
                f:close()
                table.insert(list, { name = name, svg = svg })
            end
        end
        res:json({ icons = list })
    end)

    server:route("POST", "^/api/apps/settings$", function(req, res)
        local a = apps()
        if not a then return res:error(404, "The launcher isn't installed") end
        local b = Common.pick(req.json(), SETTINGS)
        if b.layout and not LAYOUTS[b.layout] then return res:error(400, "Unknown layout") end
        if b.columns and (b.columns < 1 or b.columns > 3) then return res:error(400, "Columns: 1 to 3") end
        if type(b.button_labels_app) == "table" and type(b.button_labels_app.key) == "string" then
            local okP, Popup = pcall(require, "appspopup")
            local v = b.button_labels_app.value
            if okP then Popup.setLabelsOf(b.button_labels_app.key, Popup.labelsValue(v)) end
            b.button_labels_app = nil
        end
        if b.button_labels ~= nil then
            G_reader_settings:saveSetting("apps_button_labels", b.button_labels and true or false)
            b.button_labels = nil
        end
        if b.clock_24h ~= nil then
            G_reader_settings:saveSetting("twelve_hour_clock", not b.clock_24h)
            b.clock_24h = nil
        end
        -- The weather: its source, units and place (found by the page from Open-Meteo's place search).
        if b.weather and not WEATHER[b.weather] then return res:error(400, "Unknown weather source") end
        if b.weather_units and b.weather_units ~= "f" and b.weather_units ~= "c" then return res:error(400, "Units: f or c") end
        if b.weather_place then
            local p = b.weather_place
            if not (tonumber(p.lat) and tonumber(p.lon) and type(p.name) == "string" and p.name ~= "") then return res:error(400, "Which place?") end
            local function str(v) return type(v) == "string" and v:sub(1, 80) or nil end
            b.weather_place = { name = p.name:sub(1, 80), region = str(p.region), country = str(p.country), cc = str(p.cc),
                lat = tonumber(p.lat), lon = tonumber(p.lon) }
        end
        local weatherChanged = b.weather or b.weather_units or b.weather_place
        for k, v in pairs(b) do
            if v == false and (k == "dark" or k == "at_start") then v = nil end
            if k == "weather" and v == "auto" then v = nil end
            if k == "wifi_idle" and v <= 0 then v = nil end
            if k == "clock" and v ~= "small" then v = nil end
            -- (One row is the default: only Separate rows is kept, as false.)
            if k == "recent_together" and v == true then v = nil end
            a.settings[k] = v
        end
        a:changed()
        if weatherChanged then
            local ok, W = pcall(require, "appsweather")
            if ok then pcall(W.refresh, a, true) end
        end
        res:json({ ok = true })
    end)

    -- { order = [keys] } or { key, hidden } or { add = key } or { remove = key }
    server:route("POST", "^/api/apps/tiles$", function(req, res)
        local a = apps()
        if not a then return res:error(404, "The launcher isn't installed") end
        local Model = require("appsmodel")
        local b, s = req.json(), a.settings
        if type(b.order) == "table" then
            s.order = b.order
        elseif type(b.key) == "string" and b.hidden ~= nil then
            s.hidden = s.hidden or {}
            local tile
            for __, t in ipairs(Model.allTiles()) do if t.key == b.key then tile = t end end
            -- (Shown: false for one hidden to start with, no entry for the others.)
            if b.hidden == true then s.hidden[b.key] = true
            elseif tile and tile.offByDefault then s.hidden[b.key] = false
            else s.hidden[b.key] = nil end
        elseif type(b.add) == "string" then
            -- Only a place the Kindle itself offers.
            local found
            for __, kind in ipairs({ "ha", "todo", "note", "notefolder", "action" }) do
                for __, p in ipairs(a:pinChoices(kind)) do
                    if Model.pinKey(p) == b.add then found = p end
                end
            end
            if not found then return res:error(400, "Not found") end
            a:addPin(found)
            return res:json({ ok = true })
        elseif type(b.remove) == "string" then
            s.pins = Model.removePin(s.pins, b.remove)
        elseif type(b.layout) == "table" then
            -- The visual editor's whole layout: { order, hidden = { keys }, grouped = { key = group id } }.
            local L = b.layout
            local Model = require("appsmodel")
            if type(L.order) == "table" then
                local order = {}
                for __, k in ipairs(L.order) do if type(k) == "string" then table.insert(order, k) end end
                s.order = order
            end
            local hid = {}
            for __, k in ipairs(type(L.hidden) == "table" and L.hidden or {}) do hid[k] = true end
            s.hidden = s.hidden or {}
            for __, t in ipairs(a:tiles(true)) do
                if not t.groupTile then
                    if hid[t.key] then s.hidden[t.key] = true
                    elseif Model.isHidden(s.hidden, t) then s.hidden[t.key] = false end
                end
            end
            local groups = {}
            for __, g in ipairs(s.groups or {}) do groups[g.id] = true end
            s.grouped = {}
            for k, gid in pairs(type(L.grouped) == "table" and L.grouped or {}) do
                if type(k) == "string" and groups[gid] then s.grouped[k] = gid end
            end
        elseif type(b.move) == "string" then
            -- A tile into a group (an id), or back to the main page (false).
            s.grouped = s.grouped or {}
            local known = false
            for __, g in ipairs(s.groups or {}) do if g.id == b.group then known = true end end
            if b.group ~= false and not known then return res:error(400, "No such group") end
            s.grouped[b.move] = b.group or nil
        elseif type(b.newGroup) == "string" and b.newGroup:match("%S") then
            s.groups = s.groups or {}
            local id = tostring(os.time()) .. tostring(math.random(100, 999))
            table.insert(s.groups, { id = id, name = b.newGroup:match("^%s*(.-)%s*$") })
            if type(b.key) == "string" then
                s.grouped = s.grouped or {}
                s.grouped[b.key] = id
            end
        elseif type(b.renameGroup) == "string" and type(b.name) == "string" and b.name:match("%S") then
            for __, g in ipairs(s.groups or {}) do
                if g.id == b.renameGroup then g.name = b.name:match("^%s*(.-)%s*$") end
            end
        elseif type(b.groupIcon) == "string" and type(b.icon) == "string" then
            local ok = false
            for __, name in ipairs(require("appsicons").LIST) do if name == b.icon then ok = true end end
            if not ok then return res:error(400, "No such icon") end
            for __, g in ipairs(s.groups or {}) do
                if g.id == b.groupIcon then g.icon = b.icon ~= "folder" and b.icon or nil end
            end
        elseif type(b.deleteGroup) == "string" then
            -- Its tiles go back to the main page.
            for k, g in pairs(s.grouped or {}) do
                if g == b.deleteGroup then s.grouped[k] = nil end
            end
            local kept = {}
            for __, g in ipairs(s.groups or {}) do if g.id ~= b.deleteGroup then table.insert(kept, g) end end
            s.groups = kept
        else
            return res:error(400, "Unknown change")
        end
        a:changed()
        res:json({ ok = true })
    end)
end

return Web
