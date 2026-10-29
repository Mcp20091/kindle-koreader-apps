--[[--
KOReader's own controls on Apps's screens: the light, night mode, a screen
refresh, and your KOReader gestures (the same as Notes' notesko.lua).

Apps's screens cover KOReader's library or book, and KOReader only gives
gestures and gesture actions to the screen on top. So the gestures the
screens don't use themselves (two fingers, edge swipes, multiswipes,
pinches...) are handed to the Gestures plugin underneath, and the actions
they run reach the library or book as if
Apps weren't open: only those that make sense over them (light, warmth,
refresh, night mode, Wi-Fi, these apps), not folder or book ones.

@module koplugin.apps.ko
]]

local Device = require("device")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")

local KO = {}

-- Gestures plugin zones a screen here does not use itself: not taps, holds,
-- double taps or the diagonal swipe (the screen's buttons and pages are
-- those).
function KO.notOurs(id)
    return not (id:find("^tap_") or id:find("^hold_") or id:find("^double_tap_") or id == "short_diagonal_swipe")
end

--- Gesture actions that make sense over these apps (by name): KOReader's own
-- here, the launcher's, and each app's as it says (appsinfo.lua). Others open
-- the library's folders or a book's menus over them.
local OVER_APPS = { "frontlight", "warmth", "refresh", "night_mode", "wifi", "screenshot", "^apps_" }

local function overApp(name)
    for __, pat in ipairs(OVER_APPS) do
        if name:find(pat) then return true end
    end
    local ok, pats = pcall(function() return require("appsinfo").gestures() end)
    for __, pat in ipairs(ok and pats or {}) do
        if name:find(pat) then return true end
    end
    return false
end

--- Whether a gesture's actions all make sense over these apps. A QuickMenu
-- only lists them (nothing runs until one is picked): it needs one that does.
function KO.overApps(actions)
    if type(actions) ~= "table" then return false end
    local quick = type(actions.settings) == "table" and actions.settings.show_as_quickmenu
    local any, all = false, true
    for name in pairs(actions) do
        if name ~= "settings" then
            if overApp(name) then any = true else all = false end
        end
    end
    return any and (all or quick == true)
end

--- A gesture handed on: one the screens don't use, doing what makes sense here.
function KO.allowed(id, actions)
    return KO.notOurs(id) and KO.overApps(actions)
end

--- Hands a gesture to KOReader's Gestures plugin (only its zones, so a tap
-- never turns the page of the book underneath). True when it ran an action.
-- `allowed(id, actions)` (optional) says which may run.
function KO.passGesture(kui, ev, allowed)
    local g = kui and kui.gestures
    if not (g and g.gestures and kui._ordered_touch_zones) then return false end
    for __, tz in ipairs(kui._ordered_touch_zones) do
        local id = tz.def and tz.def.id
        if id and (g.gestures[id] or id == "multiswipe") and tz.gs_range:match(ev) then
            -- A multiswipe's actions are those of its shape.
            local name = id
            if id == "multiswipe" and ev.multiswipe_directions and g.safeMultiswipeName then
                name = "multiswipe_" .. g:safeMultiswipeName(ev.multiswipe_directions)
            end
            if allowed and not allowed(id, g.gestures[name]) then return false end
            if tz.handler(ev) then return true end
        end
    end
    return false
end

-- Whether a gesture action (Dispatcher) is running now: its events then go on
-- to the library or book underneath.
Dispatcher.apps_running = Dispatcher.apps_running or 0
if not Dispatcher.apps_wrapped then
    Dispatcher.apps_wrapped = true
    local execute = Dispatcher.execute
    Dispatcher.execute = function(...)
        Dispatcher.apps_running = Dispatcher.apps_running + 1
        local ok, err = pcall(execute, ...)
        Dispatcher.apps_running = Dispatcher.apps_running - 1
        if not ok then error(err, 0) end
    end
end

-- Whether KOReader is broadcasting an event now: those already reach the
-- library or book, so they are not handed on again.
UIManager.apps_broadcasting = UIManager.apps_broadcasting or 0
if not UIManager.apps_bwrapped then
    UIManager.apps_bwrapped = true
    local broadcast = UIManager.broadcastEvent
    UIManager.broadcastEvent = function(...)
        UIManager.apps_broadcasting = UIManager.apps_broadcasting + 1
        local ok, err = pcall(broadcast, ...)
        UIManager.apps_broadcasting = UIManager.apps_broadcasting - 1
        if not ok then error(err, 0) end
    end
end

--- For a screen's handleEvent: a gesture action's event that the screen
-- did not take goes to KOReader underneath (not a broadcast: that got there).
-- (Never a screen's own showing or closing: a screen closed during a gesture's action handed
-- its CloseWidget on, and KOReader's file browser took it for its own and tore itself down,
-- leaving every app's plugin gone while it was still on the screen.)
local OWN = { onCloseWidget = true, onShow = true }
function KO.passEvent(kui, event)
    if event and OWN[event.handler] then return end
    if Dispatcher.apps_running > 0 and UIManager.apps_broadcasting == 0 and kui and kui.handleEvent then
        return kui:handleEvent(event)
    end
end

--- Shows a screen with a full refresh (on the Scribe and other MediaTek
-- Kindles a "flashui" or partial one leaves ghosts of what was there); opened
-- by a gesture or QuickMenu, once more a moment later, after the menu has gone
-- (the same as Notes' notesko.lua).
function KO.showFull(widget)
    UIManager:show(widget, "full")
    if Dispatcher.apps_running > 0 then
        UIManager:scheduleIn(0.6, function()
            if UIManager:getTopmostVisibleWidget() == widget then UIManager:setDirty(widget, "full") end
        end)
    end
end

--- How often a sleep screen of these apps is drawn again while the Kindle
-- sleeps, in minutes (0: never). One setting for To Do, Home Assistant and Apps.
function KO.sleepMinutes() return G_reader_settings:readSetting("sleep_screen_update") or 0 end

KO.SLEEP_UPDATES = { 0, 15, 30, 60 }

function KO.sleepUpdateName(minutes)
    local _ = require("gettext")
    if not minutes or minutes <= 0 then return _("Off") end
    if minutes == 60 then return _("Every hour") end
    return require("ffi/util").template(_("Every %1 min"), minutes)
end

--- A line in koreader/sleep-update.log (what woke the Kindle, and how it went).
function KO.sleepLog(text)
    local path = require("datastorage"):getDataDir() .. "/sleep-update.log"
    local size = require("libs/libkoreader-lfs").attributes(path, "size") or 0
    local f = io.open(path, size > 100000 and "w" or "a")
    if not f then return end
    local powerd = Device:getPowerDevice()
    local ok, battery = pcall(function() return powerd:getCapacity() end)
    f:write(os.date("%Y-%m-%d %H:%M:%S  "), text, ok and battery and ("  (battery " .. battery .. "%)") or "", "\n")
    f:close()
end

--- While a sleep screen of these apps shows: the Kindle woken every few
-- minutes (KOReader's wakeup manager sets the clock's alarm) to draw it
-- again with `redraw`; it then goes back to sleep by itself.
function KO.sleepUpdates(redraw)
    local mgr = Device.wakeup_mgr
    if Device.apps_sleep_task and mgr then mgr:removeTasks(nil, Device.apps_sleep_task) end
    Device.apps_sleep_task = nil
    local minutes = KO.sleepMinutes()
    if minutes <= 0 then return end
    if not mgr then
        KO.sleepLog("KOReader can't wake this Kindle on a timer, so the sleep screen isn't updated.")
        return
    end
    local task
    task = function()
        if Device.apps_sleep_task ~= task then return end
        if not Device.screen_saver_mode then
            KO.sleepLog("Timer: the Kindle is awake, so no more updates.")
            Device.apps_sleep_task = nil
            return
        end
        local ok, err = pcall(redraw)
        UIManager:forceRePaint()
        KO.sleepLog(ok and "Woken by the timer: the sleep screen was drawn again." or ("Woken by the timer, but drawing failed: " .. tostring(err)))
        mgr:addTask(minutes * 60, task)
    end
    Device.apps_sleep_task = task
    mgr:addTask(minutes * 60, task)
    KO.sleepLog("Sleep screen shown; the next update in " .. minutes .. " min.")
end

function KO.hasLight() return Device:hasFrontlight() end

function KO.light()
    if Device:hasFrontlight() then Device:showLightDialog() end
end

function KO.nightMode() return G_reader_settings:isTrue("night_mode") end

--- The clock as KOReader's own setting has it (its Time and date menu), one
-- for every app: true for 24-hour.
function KO.twentyFour() return not G_reader_settings:isTrue("twelve_hour_clock") end

function KO.toggleNightMode(kui)
    local listener = kui and kui.devicelistener
    if listener and listener.onToggleNightMode then return listener:onToggleNightMode() end
    -- No library or book to ask: as KOReader does it.
    local night = G_reader_settings:isTrue("night_mode")
    Device.screen:toggleNightMode()
    UIManager:ToggleNightMode(not night)
    G_reader_settings:saveSetting("night_mode", not night)
    UIManager:setDirty("all", "full")
end

--- A full refresh of a screen of these apps as soon as a dialog, menu or
-- keyboard over it closes: e-ink keeps a ghost of it otherwise (KOReader
-- redraws only that spot, without a flash). A screen asks for it with
-- `flash_on_uncover = true`; notices that show for a moment (toasts) don't
-- count. One hook on UIManager:close for all of KOReader (the same in Apps,
-- Home Assistant and To Do: whichever loads first sets it up).
function KO.flashOnUncover()
    if UIManager.apps_uncover_hooked then return end
    UIManager.apps_uncover_hooked = true
    local close = UIManager.close
    UIManager.close = function(um, widget, ...)
        local a, b, c = close(um, widget, ...)
        if type(widget) == "table" and not widget.toast and not widget.no_uncover_flash and not widget.flash_on_uncover then
            um:nextTick(function()
                local top = um:getTopmostVisibleWidget()
                if top and top ~= widget and top.flash_on_uncover then um:setDirty(top, "full") end
            end)
        end
        return a, b, c
    end
end

--- Where a screen's taps are, as text: when it changes (rows came or went,
-- a sheet opened), the update is a full one.
function KO.layoutOf(canvas)
    local parts = {}
    for i, h in ipairs(canvas and canvas.hits or {}) do
        parts[i] = h.x .. "," .. h.y .. "," .. h.w .. "," .. h.h
    end
    return table.concat(parts, ";")
end

--- ⌂: Apps on top (whatever was opened over it closed); false without Apps.
function KO.home()
    local PS = require("pluginshare")
    if PS.appsHome then PS.appsHome() return true end
    return false
end

function KO.refresh(widget)
    UIManager:setDirty(widget or "all", "full")
end

--- The shared pop-ups (appspopup.lua in Apps), or KOReader's own without Apps.
local function popup()
    local ok, P = pcall(require, "appspopup")
    return ok and P or nil
end

--- The ⋮ menu: `extra` ({ { text, fn }, ... }) first, then KOReader's light
-- and night mode and a full refresh, and Settings (`settings`, a function) last.
function KO.menu(kui, widget, extra, settings)
    local _ = require("gettext")
    local items = {}
    for __, x in ipairs(extra or {}) do table.insert(items, { text = x[1], fn = x[2] }) end
    -- The apps opened lately, the recent books and notebooks (Apps).
    local PS = require("pluginshare")
    if PS.showSwitcher then table.insert(items, { text = _("Recent apps"), fn = function() PS.showSwitcher() end }) end
    if KO.hasLight() then table.insert(items, { text = _("Light"), fn = function() KO.light() end }) end
    table.insert(items, { text = KO.nightMode() and _("Night mode: On") or _("Night mode: Off"), fn = function() KO.toggleNightMode(kui) end })
    table.insert(items, { text = _("Refresh screen"), fn = function() UIManager:nextTick(function() KO.refresh(widget) end) end })
    if settings then table.insert(items, { text = _("Settings"), fn = settings }) end
    local P = popup()
    if P then return P.menu{ items = items } end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for __, it in ipairs(items) do
        table.insert(buttons, { { text = it.text, callback = function() UIManager:close(dialog) it.fn() end } })
    end
    table.insert(buttons, { { text = _("Close"), callback = function() UIManager:close(dialog) end } })
    dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(dialog)
end

--- A list to pick from ({ { text, fn, enabled, checked } }), with a title.
-- back = fn: one level down a menu; Back instead of Close goes to it.
function KO.list(title, items, back)
    local P = popup()
    if P then return P.menu{ title = title, items = items, back = back } end
    local _ = require("gettext")
    local dialog
    local buttons = {}
    for __, it in ipairs(items) do
        table.insert(buttons, { { text = (it.checked and "\u{2713} " or "") .. it.text, enabled = it.enabled ~= false,
            callback = function() UIManager:close(dialog) if it.fn then it.fn() end end } })
    end
    table.insert(buttons, { { text = back and _("Back") or _("Close"), callback = function()
        UIManager:close(dialog)
        if back then back() end
    end } })
    dialog = require("ui/widget/buttondialog"):new{ title = title, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

--- A menu from KOReader's ButtonDialog fields ({ title, buttons = { { { text,
-- callback, enabled }, ... } } }), shown in the shared look: one row per
-- button, its own Close (a button that only closes is left out). Returns
-- the menu (UIManager:close of it is harmless after a pick).
function KO.buttonDialog(o)
    local P = popup()
    if not P then
        local d = require("ui/widget/buttondialog"):new(o)
        UIManager:show(d)
        return d
    end
    local _ = require("gettext")
    local items = {}
    -- One only its buttons close (dismissable = false): as it is, every button
    -- kept and none closing it by itself.
    local strict = o.dismissable == false
    for __, row in ipairs(o.buttons or {}) do
        for __, b in ipairs(row) do
            local text = b.text or (b.text_func and b.text_func())
            if text and text ~= "" and (strict or (text ~= _("Close") and text ~= _("Cancel"))) then
                local on = b.enabled ~= false and not (b.enabled_func and not b.enabled_func())
                table.insert(items, { text = text, enabled = on, fn = b.callback })
            end
        end
    end
    return P.menu{ title = o.title, items = items, no_close = strict, keep_open = strict, dismissable = o.dismissable }
end

--- Pick one of `options` ({ label, value }), the current one ticked; done(value).
-- back = fn: opened from another menu (Back goes to it).
function KO.choose(title, options, current, done, back)
    local items = {}
    for __, o in ipairs(options) do
        table.insert(items, { text = o.label, checked = o.value == current, fn = function() done(o.value) end })
    end
    return KO.list(title, items, back)
end

--- Ask first: { text, title, ok, cancel, onOk, onCancel }.
function KO.confirm(o)
    local P = popup()
    if P then return P.confirm(o) end
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = (o.title and (o.title .. "\n\n") or "") .. (o.text or ""), ok_text = o.ok, cancel_text = o.cancel,
        ok_callback = o.onOk, cancel_callback = o.onCancel,
    })
end

--- Something to read, with OK (a result, a problem): text, or { title, text, onOk }.
function KO.message(o)
    local P = popup()
    if P then return P.message(o) end
    if type(o) == "string" then o = { text = o } end
    UIManager:show(require("ui/widget/infomessage"):new{
        text = (o.title and (o.title .. "\n\n") or "") .. (o.text or ""), dismiss_callback = o.onOk })
end

--- A notice for a moment ("Saved").
function KO.toast(text, seconds)
    local P = popup()
    if P then return P.toast(text, seconds) end
    UIManager:show(require("ui/widget/notification"):new{ text = text })
end

--- A swipe in from the left edge (it starts in the leftmost tenth of the
-- screen): Back, in every app. Other swipes right turn back a page (none on
-- the first page).
function KO.fromLeftEdge(ges)
    return ges ~= nil and ges.direction == "east" and ges.pos ~= nil and ges.pos.x < Device.screen:getWidth() * 0.1
end

--- After a removal: "Task deleted" with Undo for about 6 s (onUndo puts it
-- back); without Apps, a notice only.
function KO.undo(text, onUndo)
    local P = popup()
    if P and P.undo then return P.undo(text, onUndo) end
    UIManager:show(require("ui/widget/notification"):new{ text = text })
end

--- A box while something runs; returns it (:close() it when done). With
-- opts.cancel (a function), a Cancel button stops it (only that does).
function KO.wait(text, opts)
    local P = popup()
    if P then return P.wait(text, opts) end
    local m
    if opts and opts.cancel then
        local _ = require("gettext")
        m = require("ui/widget/buttondialog"):new{ title = text, title_align = "center", dismissable = false, buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(m) opts.cancel() end } } } }
    else
        m = require("ui/widget/infomessage"):new{ text = text }
    end
    m.close = function() UIManager:close(m) end
    UIManager:show(m)
    return m
end


--- A text box: the launcher's request box (the text, a pen at its end to write it by
-- hand when handwriting input is set up, and icon buttons: Cancel and `ok`), or
-- KOReader's InputDialog without it. o = { title, subtitle, text, hint, ok (its name,
-- "Save"), okIcon ("check"), kind (what's written: "name", "text"…), pen = false (an
-- exact value: no pen), number, password, needsText, check(text) -> why (the box
-- stays open, saying why), done(text) }. done gets the text trimmed (a password as typed).
function KO.askText(o)
    local _ = require("gettext")
    local function trim(v)
        if o.password then return tostring(v or "") end
        return (tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end
    local P = popup()
    if P and P.request then
        local hw = require("pluginshare").handwriting
        local okPen, pen = pcall(function() return hw and hw.available() end)
        return P.request{ title = o.title, subtitle = o.subtitle, text = o.text or "", hint = o.hint, typing = true,
            number = o.number, password = o.password, lines = o.lines,
            pen = (o.pen ~= false and okPen and pen) and true or nil, penTitle = o.title, penKind = o.kind or "text",
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = o.okIcon or "check", text = o.ok or _("Save"), primary = true, needsText = o.needsText,
                    keep = o.check ~= nil, fn = function(v, box)
                        v = trim(v)
                        if o.check then
                            local why = o.check(v)
                            if why then return KO.toast(why) end
                            box:stopTyping()
                            box:close()
                        end
                        o.done(v)
                    end },
            } }
    end
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = o.title,
        description = o.subtitle,
        input = o.text or "",
        input_hint = o.hint,
        input_type = o.number and "number" or nil,
        text_type = o.password and "password" or nil,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = o.ok or _("Save"), is_enter_default = true, callback = function()
                local v = trim(dialog:getInputText())
                if o.needsText and v == "" then return end
                local why = o.check and o.check(v)
                if why then return KO.toast(why) end
                UIManager:close(dialog)
                o.done(v)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return KO
