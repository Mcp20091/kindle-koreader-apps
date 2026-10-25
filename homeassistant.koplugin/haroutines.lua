--[[--
Routines: one tap runs several actions ("Leaving": lock the doors, close the
garage, lights off). Made and kept on the Kindle (prefs.routines), nothing
in Home Assistant: each step is a service call on one device.

A routine: { id, name, steps = { { id = entity, service, label } } }.
]]

local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("hacanvas")
local Model = require("hamodel")
local Settings = require("hasettings")

local C = Canvas
local Routines = {}

--- What a device can do in a routine: { { label, service } }.
function Routines.actions(e)
    local d = e.domain
    if d == "light" or d == "switch" or d == "fan" or d == "input_boolean" then
        return { { _("Turn on"), d .. ".turn_on" }, { _("Turn off"), d .. ".turn_off" } }
    elseif d == "lock" then
        return { { _("Lock"), "lock.lock" }, { _("Unlock"), "lock.unlock" } }
    elseif d == "cover" then
        return { { _("Close"), "cover.close_cover" }, { _("Open"), "cover.open_cover" } }
    elseif d == "scene" then
        return { { _("Turn on"), "scene.turn_on" } }
    elseif d == "script" then
        return { { _("Run"), "script.turn_on" } }
    elseif d == "media_player" then
        return { { _("Turn off"), "media_player.turn_off" }, { _("Turn on"), "media_player.turn_on" }, { _("Pause"), "media_player.media_pause" } }
    elseif d == "climate" then
        return { { _("Turn off"), "climate.turn_off" }, { _("Turn on"), "climate.turn_on" } }
    elseif d == "vacuum" then
        return { { _("Start"), "vacuum.start" }, { _("Return to dock"), "vacuum.return_to_base" } }
    end
    return {}
end

function Routines.list(prefs)
    prefs.routines = prefs.routines or {}
    return prefs.routines
end

function Routines.find(prefs, id)
    for __, r in ipairs(Routines.list(prefs)) do
        if r.id == id then return r end
    end
end

-- Steps that need asking first (as the Confirm settings say).
local function asks(prefs, snap, r)
    for __, s in ipairs(r.steps) do
        local e = snap and snap.byId[s.id]
        if s.service == "lock.unlock" and prefs.ask_unlock ~= false then return true end
        if s.service == "cover.open_cover" and e and Model.icon(e) == "warehouse" and prefs.ask_garage ~= false then return true end
        if s.service == "script.turn_on" and prefs.ask_scripts ~= false then return true end
    end
    return false
end

--- Runs a routine's steps one after another; says how it went.
function Routines.run(ha, r, confirmed)
    if #r.steps == 0 then
        return require("hako").toast(_("This routine has no steps yet."), 2)
    end
    if not confirmed and asks(ha.prefs, ha.snap, r) then
        return require("hako").confirm{ text = T(_("Run %1?"), r.name), ok = _("Run"), onOk = function() Routines.run(ha, r, true) end }
    end
    local Notification = require("ui/widget/notification")
    local i, failed = 0, 0
    local function step()
        i = i + 1
        local s = r.steps[i]
        if not s then
            require("hako").toast(failed == 0 and T(_("%1: done"), r.name) or T(_("%1: %2 steps did not work"), r.name, failed))
            UIManager:scheduleIn(2, function() ha:update(true) end)
            return
        end
        ha:send(s.service, { entity_id = s.id }, function(ok)
            if not ok then failed = failed + 1 end
            step()
        end)
    end
    require("hako").toast(T(_("Running %1…"), r.name))
    step()
end

-- ------------------------------------------------------------------ screens

local function row(c, F, name, value, fn, hold)
    F:block(40, function(y)
        c:text(14, y + 25, name, 12, { maxw = c.W - 200 })
        if value then c:text(c.W - 32, y + 25, value, 11, { align = "end", color = C.GREY, maxw = 160 }) end
        if fn then c:icon("chevron-right", c.W - 26, y + 14, 12) end
        c:hit(0, y, c.W, 40, fn, hold)
        c:hline(14, y + 39, c.W - 14)
    end)
end

local function stepText(snap, s)
    local e = snap and snap.byId[s.id]
    return (e and e.name or s.id) .. ": " .. (s.label or s.service)
end

--- The routines, and New routine.
function Routines.screen(view, c, snap)
    local prefs = view.ha.prefs
    local F = c:flow(52, c.H - 8, view.pageNo)
    F:block(48, function(y)
        c:text(14, y + 20, _("Tap a routine to change it. Routines show on Home and in the dashboard's Scenes section."), 10,
            { color = C.GREY, maxw = c.W - 28 })
    end)
    for __, r in ipairs(Routines.list(prefs)) do
        row(c, F, r.name, #r.steps == 1 and _("1 step") or T(_("%1 steps"), #r.steps),
            function() view:go({ kind = "routine", id = r.id }) end)
    end
    F:gap(8)
    F:block(48, function(y)
        view:button(c, 14, y + 4, c.W - 28, 40, _("New routine"), "plus", function()
            Settings.input(_("New routine"), "", _("Leaving"), function(name)
                name = name:match("^%s*(.-)%s*$")
                if name == "" then return end
                local r = { id = tostring(os.time()) .. tostring(math.random(100, 999)), name = name, steps = {} }
                table.insert(Routines.list(prefs), r)
                view.ha:savePrefs()
                view:go({ kind = "routine", id = r.id })
            end)
        end)
    end)
    view:titlebar(c, true, _("Routines"), {}, F:pages())
    return F:pages()
end

--- One routine: its steps (tap one to remove it), Add a step, Run, Rename, Delete.
function Routines.edit(view, c, snap)
    local ha, prefs = view.ha, view.ha.prefs
    local r = Routines.find(prefs, view.route.id)
    local F = c:flow(52, c.H - 8, view.pageNo)
    if not r then
        view:titlebar(c, true, _("Routine"), {}, 1)
        return 1
    end
    F:block(28, function(y) view:label(c, y, _("STEPS"), _("Tap a step to remove it")) end)
    if #r.steps == 0 then
        F:block(36, function(y) c:text(14, y + 22, _("No steps yet."), 11, { color = C.GREY }) end)
    end
    for i, s in ipairs(r.steps) do
        F:block(40, function(y)
            c:text(14, y + 25, i .. ".  " .. stepText(snap, s), 12, { maxw = c.W - 60 })
            c:icon("x", c.W - 34, y + 12, 16)
            c:hit(0, y, c.W, 40, function()
                table.remove(r.steps, i)
                ha:savePrefs()
                view:refresh("ui")
            end)
            c:hline(14, y + 39, c.W - 14)
        end)
    end
    F:gap(8)
    F:block(52, function(y)
        local w = (c.W - 36) / 2
        view:button(c, 14, y + 4, w, 40, _("Add step"), "plus", function() Routines.addStep(view, r) end)
        view:button(c, 22 + w, y + 4, w, 40, _("Run now"), "play", function() Routines.run(ha, r) end, true)
    end)
    F:block(52, function(y)
        local w = (c.W - 36) / 2
        view:button(c, 14, y + 4, w, 40, _("Rename"), "pencil", function()
            Settings.input(_("Rename routine"), r.name, nil, function(name)
                name = name:match("^%s*(.-)%s*$")
                if name ~= "" then r.name = name ha:savePrefs() view:refresh("ui") end
            end)
        end)
        view:button(c, 22 + w, y + 4, w, 40, _("Delete"), "trash-2", function()
            -- At once, with Undo (it goes back where it was).
            local list = Routines.list(prefs)
            local at
            for k, x in ipairs(list) do if x.id == r.id then at = k table.remove(list, k) break end end
            ha:savePrefs()
            view:back()
            require("hako").undo(T(_("Deleted %1"), r.name), function()
                local l = Routines.list(prefs)
                table.insert(l, math.min(at or #l + 1, #l + 1), r)
                ha:savePrefs()
                if view.canvas then view:refresh("ui") end
            end)
        end)
    end)
    view:titlebar(c, true, r.name, {}, F:pages())
    return F:pages()
end

--- A device (shown ones, by name), then what it does.
function Routines.addStep(view, r)
    local ha = view.ha
    local snap = ha.snap
    if not snap then return end
    local items = {}
    local devices = {}
    for __, e in ipairs(snap.list) do
        if Model.visible(e, ha.prefs) and #Routines.actions(e) > 0 then table.insert(devices, e) end
    end
    table.sort(devices, function(a, b) return a.name < b.name end)
    local Menu = require("ui/widget/menu")
    local menu
    for __, e in ipairs(devices) do
        table.insert(items, { text = e.name .. (e.area ~= "" and ("  \u{00B7}  " .. e.area) or ""), callback = function()
            local options = {}
            for __, a in ipairs(Routines.actions(e)) do table.insert(options, { label = a[1], value = a[2] }) end
            Settings.choose(e.name, options, nil, function(service)
                local label
                for __, o in ipairs(options) do if o.value == service then label = o.label end end
                table.insert(r.steps, { id = e.id, service = service, label = label })
                ha:savePrefs()
                view:refresh("ui")
            end)
        end })
    end
    menu = Menu:new{
        title = _("Add step"), item_table = items, covers_fullscreen = true, is_borderless = true, is_popout = false,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

return Routines
