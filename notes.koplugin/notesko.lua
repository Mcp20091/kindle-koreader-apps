--[[--
KOReader's own controls on Notes' screens: the light, night mode, a screen
refresh, and your KOReader gestures.

Notes' screens cover KOReader's library or book, and KOReader only gives
gestures and gesture actions to the screen on top. So the gestures that
can't be a resting palm (two fingers, edge swipes, multiswipes) are handed
to the Gestures plugin underneath, and the actions they run reach the
library or book as if Notes weren't open: only those that make sense over
Notes (light, warmth, refresh, night mode, Wi-Fi, these apps), not folder
or book ones.

@module koplugin.notes.ko
]]

local Device = require("device")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")

local KO = {}

-- Gestures plugin zones that are safe on a page you write on.
function KO.palmSafe(id)
    return id:find("^two_finger_") ~= nil or id == "spread_gesture" or id == "pinch_gesture"
        or id:find("^rotate_") ~= nil or id == "multiswipe" or id:find("_edge_") ~= nil
end

--- Gesture actions that make sense over these apps (by name). Others open
-- the library's folders or a book's menus over them.
local OVER_APPS = { "frontlight", "warmth", "refresh", "night_mode", "wifi", "screenshot",
    "^apps_", "^notes_", "^todo_", "^homeassistant_", "^webpage_", "^wikipedia_" }

--- Whether a gesture's actions all make sense over these apps.
function KO.overApps(actions)
    if type(actions) ~= "table" then return false end
    local any = false
    for name in pairs(actions) do
        if name ~= "settings" then
            local ok = false
            for __, pat in ipairs(OVER_APPS) do
                if name:find(pat) then
                    ok = true
                    break
                end
            end
            if not ok then return false end
            any = true
        end
    end
    return any
end

--- A gesture Notes hands on: one a resting palm can't make, doing only what
-- makes sense over Notes.
function KO.notesSafe(id, actions)
    return KO.palmSafe(id) and KO.overApps(actions)
end

--- A screen shown with a full refresh (on the Scribe only "full" clears
-- ghosting: "flashui" is the same as "ui" there). Opened from a gesture or
-- QuickMenu, once more after that menu has closed.
function KO.showFull(widget)
    UIManager:show(widget, "full")
    if Dispatcher.apps_running > 0 then
        UIManager:scheduleIn(0.6, function()
            if UIManager:getTopmostVisibleWidget() == widget then UIManager:setDirty(widget, "full") end
        end)
    end
end

-- Hands a gesture to KOReader's Gestures plugin (only its zones, so a tap
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
-- library or book, so they are not handed on again. (Shared with the other
-- apps' copies of this: whichever loads first wraps.)
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
function KO.passEvent(kui, event)
    if Dispatcher.apps_running > 0 and UIManager.apps_broadcasting == 0 and kui and kui.handleEvent then
        return kui:handleEvent(event)
    end
end

function KO.hasLight() return Device:hasFrontlight() end

function KO.light()
    if Device:hasFrontlight() then Device:showLightDialog() end
end

function KO.nightMode() return G_reader_settings:isTrue("night_mode") end

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

function KO.refresh(widget)
    UIManager:setDirty(widget or "all", "full")
end

--- A full refresh of a screen of Notes' as soon as a dialog, menu or
-- keyboard over it closes: e-ink keeps a ghost of it otherwise (KOReader
-- redraws only that spot, without a flash). A screen asks for it with
-- `flash_on_uncover = true`; notices that show for a moment (toasts) don't
-- count. One hook on UIManager:close for all of KOReader (the same as the
-- other apps': whichever loads first sets it up).
function KO.flashOnUncover()
    if UIManager.apps_uncover_hooked then return end
    UIManager.apps_uncover_hooked = true
    local close = UIManager.close
    UIManager.close = function(um, widget, ...)
        local a, b, c = close(um, widget, ...)
        if type(widget) == "table" and not widget.toast and not widget.flash_on_uncover then
            um:nextTick(function()
                local top = um:getTopmostVisibleWidget()
                if top and top ~= widget and top.flash_on_uncover then um:setDirty(top, "full") end
            end)
        end
        return a, b, c
    end
end

--- The shared notifications (the Apps plugin): the bell's tap, or nil
-- without Apps (then no bell).
function KO.bell()
    local PS = require("pluginshare")
    if PS.showNotifications then return function() PS.showNotifications() end end
end

--- How many notifications are not seen yet (the bell's badge).
function KO.bellCount()
    local PS = require("pluginshare")
    local ok, n = pcall(function() return PS.notifyCount and PS.notifyCount() or 0 end)
    return ok and n or 0
end

--- A notice in the shared notifications (when Apps is there): `n` as
-- PS.notify takes it ({ text, key, open, route }), app = "notes".
function KO.notify(n)
    local PS = require("pluginshare")
    if not PS.notify then return end
    n.app = n.app or "notes"
    n.name = n.name or "Notes"
    n.icon = n.icon or "notebook-pen"
    pcall(PS.notify, n)
end

-- ------------------------------------------------------------------ the apps' pop-ups

-- Apps' pop-ups (appspopup), when Apps is there.
local function popup()
    local ok, P = pcall(require, "appspopup")
    return ok and P or nil
end

--- A list to pick from ({ { text, fn, enabled, checked, bold } }), with a
-- title (and `text` under it, when Apps' pop-ups show one); `dismissed()`
-- (optional) when the user closes it without a pick (Close, a tap outside;
-- not when the code closes it). `back()` (optional): opened from another
-- menu, it shows Back instead of Close, and Back (or the Back key) goes
-- back there (`dismissed` isn't called then).
function KO.list(title, items, dismissed, text, back)
    local picked = false
    local backed = false
    local rows = {}
    for __, it in ipairs(items) do
        table.insert(rows, { text = it.text, enabled = it.enabled, checked = it.checked, danger = it.danger, bold = it.bold,
            fn = function()
                picked = true
                if it.fn then it.fn() end
            end })
    end
    local P = popup()
    if P then
        -- (A menu's title takes up to 10 lines: the text goes under it there.)
        local box = P.menu{ title = text and ((title or "") .. "\n\n" .. text) or title, items = rows,
            back = back and function() backed = true back() end or nil }
        if dismissed and box and box.close then
            local close = box.close
            box.close = function(b, ...)
                local was = b.closed
                close(b, ...)
                -- (A pick closes it first, then runs: looked at once that has run.)
                if not was then UIManager:nextTick(function() if not picked and not backed then dismissed() end end) end
            end
        end
        return box
    end
    local _ = require("gettext")
    local dialog
    local buttons = {}
    for __, it in ipairs(rows) do
        table.insert(buttons, { { text = (it.checked and "✓  " or "") .. it.text, align = "left", enabled = it.enabled ~= false,
            font_bold = it.bold, callback = function() UIManager:close(dialog) it.fn() end } })
    end
    table.insert(buttons, { { text = back and _("Back") or _("Close"), callback = function()
        UIManager:close(dialog)
        if back then back() elseif dismissed then dismissed() end
    end } })
    dialog = require("ui/widget/buttondialog"):new{
        title = text and ((title or "") .. "\n\n" .. text) or title, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
    return dialog
end

--- A ButtonDialog's table ({ title, buttons = rows of { text, callback,
-- enabled } }) shown as the apps' list, one row per button. Close, Cancel
-- and Done aren't rows: the list's own Close does what they did; a Back
-- button (or o.back) makes it Back, to the menu before. A
-- title's lines after a blank one go under it as text; "✓ " before a
-- button's text ticks it. Returns what was shown, so a callback's
-- UIManager:close(dialog) still works.
function KO.buttonDialog(o)
    local _ = require("gettext")
    local closing = { [_("Close")] = true, [_("Cancel")] = true, [_("Done")] = true }
    local items, dismissed, back = {}, nil, o.back
    for __, row in ipairs(o.buttons or {}) do
        for __, b in ipairs(row) do
            if b.text == _("Back") then
                -- (A Back button: Back to the menu before, not Close.)
                back = back or b.callback
            elseif closing[b.text] then
                dismissed = dismissed or b.callback
            else
                local label, checked = b.text or "", nil
                local rest = label:match("^✓%s+(.*)$")
                if rest then label, checked = rest, true else label = label:gsub("^%s+", "") end
                table.insert(items, { text = label, checked = checked, enabled = b.enabled,
                    bold = b.font_bold or b.bold, fn = b.callback })
            end
        end
    end
    local title, text = o.title, nil
    if title then
        local head, tail = title:match("^(.-)\n\n(.*)$")
        if head then title, text = head, tail end
    end
    return KO.list(title, items, dismissed, text, back)
end

--- Something to read (a result, a problem), with OK: { title, text, onOk }
-- or just the text. Apps' message pop-up, KOReader's InfoMessage without it.
function KO.message(o)
    if type(o) == "string" then o = { text = o } end
    local P = popup()
    if P and P.message then return P.message(o) end
    local m = require("ui/widget/infomessage"):new{
        text = (o.title and (o.title .. "\n\n") or "") .. (o.text or ""), dismiss_callback = o.onOk }
    UIManager:show(m)
    return m
end

--- Pick one of `options` ({ label, value }), the current one ticked;
-- done(value), or done(nil) when it closes without a pick. `back()`
-- (optional): Back to the menu it came from instead of Close.
function KO.choose(title, options, current, done, back)
    local items = {}
    for __, o in ipairs(options) do
        table.insert(items, { text = o.label, checked = o.value == current, fn = function() done(o.value) end })
    end
    return KO.list(title, items, function() done(nil) end, nil, back)
end

--- Ask first: { text, title, ok, cancel, danger, onOk, onCancel }.
function KO.confirm(o)
    local P = popup()
    if P then return P.confirm(o) end
    local box = require("ui/widget/confirmbox"):new{
        text = (o.title and (o.title .. "\n\n") or "") .. (o.text or ""), ok_text = o.ok, cancel_text = o.cancel,
        ok_callback = o.onOk, cancel_callback = o.onCancel,
    }
    UIManager:show(box)
    return box
end

--- A notice for a moment ("Saved").
function KO.toast(text, seconds)
    local P = popup()
    if P then return P.toast(text, seconds) end
    UIManager:show(require("ui/widget/notification"):new{ text = text })
end

--- A box while something runs; returns it (UIManager:close it, or :close()).
function KO.wait(text)
    local P = popup()
    if P then return P.wait(text) end
    local m = require("ui/widget/infomessage"):new{ text = text }
    m.close = function() UIManager:close(m) end
    UIManager:show(m)
    return m
end

--- After a removal: the text with Undo for about 6 s (onUndo puts it
-- back); without Apps, a notice only.
function KO.undo(text, onUndo)
    local P = popup()
    if P and P.undo then return P.undo(text, onUndo) end
    UIManager:show(require("ui/widget/notification"):new{ text = text })
end

--- Whether Undo can be offered after a delete (Apps' pop-ups are there).
function KO.canUndo()
    local P = popup()
    return P ~= nil and P.undo ~= nil
end

--- A swipe right that starts at the left edge (the leftmost tenth): Back,
-- on Notes' list and settings screens (never in a notebook).
function KO.fromLeftEdge(ges)
    return ges ~= nil and ges.direction == "east" and ges.pos ~= nil and ges.pos.x < Device.screen:getWidth() * 0.1
end

--- A list with its left-out entries (false) taken out, in order: for rows or
-- buttons shown only sometimes ({ a, cond and b, c }).
--- A Write it button for an InputDialog: the launcher's handwriting input
-- (what is written goes into the dialog), or false without it (KO.compact
-- leaves it out). getDialog() -> the dialog; opts as PS.handwriting.write's.
function KO.writeButton(getDialog, opts)
    local hw = require("pluginshare").handwriting
    local ok, available = pcall(function() return hw and hw.available() end)
    if ok and available then return hw.button(getDialog, opts) end
    return false
end

--- The launcher's request box (PS.popup.request), or nil without it.
function KO.request()
    local P = require("pluginshare").popup
    return P and P.request
end

--- A small box to type one thing in: { title, subtitle, text, hint, ok (the button's
-- word), icon (its icon, "check"), number, password, pen = false (no
-- handwriting), penKind, done(text), onCancel }. The launcher's box with icon buttons
-- and a pen when it's there, else KOReader's (Cancel and ok).
function KO.ask(o)
    local request = KO.request()
    if request then
        return request{ title = o.title, subtitle = o.subtitle, text = o.text or "", hint = o.hint, number = o.number, password = o.password,
            pen = o.pen ~= false and not o.number and not o.password and KO.pen() or nil,
            penTitle = o.title, penKind = o.penKind or "name", typing = true, onCancel = o.onCancel,
            buttons = {
                { icon = "x", text = require("gettext")("Cancel"), cancel = true },
                { icon = o.icon or "check", text = o.ok, primary = true, needsText = o.needsText ~= false,
                    fn = function(t) o.done(t) end },
            } }
    end
    local dialog
    dialog = require("ui/widget/inputdialog"):new{
        title = o.title,
        description = o.subtitle,
        input = o.text or "",
        input_hint = o.hint,
        input_type = o.number and "number" or nil,
        text_type = o.password and "password" or nil,
        buttons = { {
            { text = require("gettext")("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
                if o.onCancel then o.onCancel() end
            end },
            { text = o.ok, is_enter_default = true, callback = function()
                local t = dialog:getInputText():match("^%s*(.-)%s*$")
                if o.needsText ~= false and t == "" then return end
                UIManager:close(dialog)
                o.done(t)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

--- A request box's pen: true when the launcher's handwriting input is there.
function KO.pen()
    local hw = require("pluginshare").handwriting
    local ok, available = pcall(function() return hw and hw.available() end)
    return (ok and available) and true or nil
end

function KO.compact(t)
    local out = {}
    for i = 1, table.maxn(t) do
        if t[i] then table.insert(out, t[i]) end
    end
    return out
end

--- A book (a PDF Notes made, a OneNote page) opened in KOReader's reader:
-- through Apps when it's there, so Back in the book comes back to Apps.
function KO.openBook(path)
    local ok, RB = pcall(require, "appsreaderbar")
    if ok and type(RB) == "table" and RB.openBook then return RB.openBook(path) end
    require("apps/reader/readerui"):showReader(path)
end

--- ⌂: Apps on top (whatever was opened over it closed); false without Apps.
function KO.home()
    local PS = require("pluginshare")
    if PS.appsHome then PS.appsHome() return true end
    return false
end

return KO
