--[[--
What NextDNS shares with the other apps' screens (from apps.koplugin's
appsko.lua): a full e-ink refresh when something over a screen closes, Home,
the ⋮ menu (the page's own items, Light, Night mode, Refresh screen, then
Settings last; Recent apps with Apps), and the apps' pop-ups (lists,
choices, confirmations, notices; KOReader's own without Apps).
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local KO = {}

--- A full refresh of a screen of these apps as soon as a dialog, menu or
-- keyboard over it closes: e-ink keeps a ghost of it otherwise (KOReader
-- redraws only that spot, without a flash). A screen asks for it with
-- `flash_on_uncover = true`; notices that show for a moment (toasts) don't
-- count. (The same hook as the other apps': whichever plugin loads first sets it.)
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

--- ⌂: Apps on top; false without Apps.
function KO.home()
    local PS = require("pluginshare")
    if PS.appsHome then
        PS.appsHome()
        return true
    end
    return false
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

-- ------------------------------------------------------------------ pop-ups

-- The apps' pop-ups (Apps' appspopup, shared in PluginShare), or nil without Apps.
local function popup()
    return require("pluginshare").popup
end

--- A list to pick from: items { text, fn, enabled, checked }. back (a menu
-- opened from another one): Back instead of Close, and it goes back there.
function KO.list(title, items, back)
    local P = popup()
    if P and P.menu then return P.menu{ title = title, items = items, back = back } end
    local dialog
    local buttons = {}
    for __, it in ipairs(items) do
        table.insert(buttons, { { text = (it.checked and "✓ " or "") .. it.text, enabled = it.enabled ~= false,
            callback = function()
                UIManager:close(dialog)
                if it.fn then it.fn() end
            end } })
    end
    table.insert(buttons, { { text = back and _("Back") or _("Close"), callback = function()
        UIManager:close(dialog)
        if back then back() end
    end } })
    dialog = require("ui/widget/buttondialog"):new{ title = title, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

--- One of options { { label, value } }, the current one ticked; done(value).
-- back: as KO.list's.
function KO.choose(title, options, current, done, back)
    local items = {}
    for __, o in ipairs(options) do
        table.insert(items, { text = o.label, checked = o.value == current, fn = function() done(o.value) end })
    end
    return KO.list(title, items, back)
end

--- A question: { title, text, ok, cancel, danger, onOk, onCancel }.
function KO.confirm(o)
    local P = popup()
    if P and P.confirm then return P.confirm(o) end
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = (o.title and (o.title .. "\n\n") or "") .. (o.text or ""), ok_text = o.ok, cancel_text = o.cancel,
        ok_callback = o.onOk, cancel_callback = o.onCancel,
    })
end

--- A short notice that goes by itself.
function KO.toast(text, seconds)
    local P = popup()
    if P and P.toast then return P.toast(text, seconds) end
    UIManager:show(require("ui/widget/notification"):new{ text = text })
end

--- Something to read (a result, a problem), with OK; onOk (optional) when it closes.
function KO.message(text, title, onOk)
    local P = popup()
    if P and P.message then return P.message{ title = title, text = text, onOk = onOk } end
    UIManager:show(require("ui/widget/infomessage"):new{ text = (title and (title .. "\n\n") or "") .. text,
        dismiss_callback = onOk })
end

--- A message while something runs, with Stop (on_stop; the apps' waiting box
-- with a Stop button, or KOReader's message, which a tap stops). The result
-- has :close() (closes it without on_stop).
function KO.wait(text, on_stop)
    local P = popup()
    local handle = { done = false }
    local function stopped()
        if handle.done then return end
        handle.done = true
        if on_stop then on_stop() end
    end
    if P and P.wait then
        local box = P.wait(text, on_stop and { cancel = stopped, cancelText = _("Stop") } or nil)
        local close = box.close
        if on_stop and not box.onCancel then
            -- (an older Apps without a Cancel button: a tap anywhere on it is Stop)
            box.close = function(b)
                close(b)
                stopped()
            end
            box.onTap = function(b)
                b:close()
                return true
            end
        end
        handle.close = function()
            handle.done = true
            close(box)
        end
        return handle
    end
    local msg = require("ui/widget/infomessage"):new{
        text = on_stop and (text .. "\n\n" .. _("Tap to stop.")) or text, flush_events_on_show = true,
        dismiss_callback = stopped }
    UIManager:show(msg)
    handle.close = function()
        handle.done = true
        msg.dismiss_callback = nil
        UIManager:close(msg)
    end
    return handle
end

--- The launcher's text box (PS.popup.request: a pen for handwriting, icon
-- buttons), or nil without it (then KOReader's InputDialog).
function KO.request()
    local P = popup()
    if not (P and P.request) then return nil end
    return function(o)
        local box = P.request(o)
        -- Taps on its buttons while the keyboard is up: KOReader gives an
        -- event the keyboard doesn't take only to "always active" widgets
        -- (as its own InputDialog is), so the box must be one too.
        if type(box) == "table" then box.is_always_active = true end
        return box
    end
end

--- The launcher's page of text to read (PS.popup.read: in pages, icon
-- buttons), or nil without it (then KOReader's TextViewer).
function KO.read()
    local P = popup()
    return P and P.read or nil
end

--- Whether handwriting can be read (the launcher's PS.handwriting, with an AI
-- set up for it): a pen in the launcher's text boxes, Write it in KOReader's.
function KO.pen()
    local H = require("pluginshare").handwriting
    local ok, yes = pcall(function() return H and H.available and H.available() end)
    return ok and yes == true or nil
end

--- A KOReader InputDialog row with Write it second, when handwriting can be
-- read (kind: "text", "name" or "command"); the row as it was otherwise.
function KO.withWrite(row, getDialog, kind)
    if KO.pen() then table.insert(row, 2, require("pluginshare").handwriting.button(getDialog, { kind = kind or "text" })) end
    return row
end

--- Undo can follow a delete (the apps' undo bar); without Apps a delete asks first.
function KO.canUndo()
    local P = popup()
    return P ~= nil and P.undo ~= nil
end

--- The undo bar: text and Undo (onUndo) for a few seconds.
function KO.undo(text, onUndo)
    local P = popup()
    if P and P.undo then return P.undo(text, onUndo) end
    KO.toast(text)
end

--- A swipe right that starts at the screen's left edge: Back, on every screen.
function KO.fromLeftEdge(ges)
    return ges ~= nil and ges.direction == "east" and ges.pos ~= nil and ges.pos.x < Device.screen:getWidth() * 0.1
end

--- The ⋮ menu: `extra` ({ { text, fn }, ... }) first, then KOReader's light
-- and night mode and a full refresh, and Settings (`settings`, a function) last.
-- before_night (optional) runs before Night mode changes.
function KO.menu(kui, extra, settings, before_night)
    local items = {}
    for __, x in ipairs(extra or {}) do table.insert(items, { text = x[1], fn = x[2] }) end
    -- The apps opened lately, the recent books and notebooks (Apps).
    local PS = require("pluginshare")
    if PS.showSwitcher then table.insert(items, { text = _("Recent apps"), fn = function() PS.showSwitcher() end }) end
    if Device:hasFrontlight() then
        table.insert(items, { text = _("Light"), fn = function() Device:showLightDialog() end })
    end
    table.insert(items, { text = KO.nightMode() and _("Night mode: On") or _("Night mode: Off"), fn = function()
        if before_night then before_night() end
        KO.toggleNightMode(kui)
    end })
    table.insert(items, { text = _("Refresh screen"), fn = function()
        UIManager:nextTick(function() UIManager:setDirty("all", "full") end)
    end })
    if settings then table.insert(items, { text = _("Settings"), fn = settings }) end
    return KO.list(nil, items)
end

-- ------------------------------------------------------------------ the launcher's copy

-- With the launcher, the generic helpers are its one copy (PS.ko), so a
-- change there (Back in menus, say) is made once; the ones above are the
-- fallback without it. NextDNS's own (flashOnUncover, home, menu, canUndo…) stay
-- here.
local SHARED = { list = true, choose = true, confirm = true, toast = true, undo = true, fromLeftEdge = true }

-- (NextDNS calls these two its own way: message(text, title, onOk) and
-- wait(text, on_stop) with a handle whose close() doesn't stop.)
local ADAPTED = {
    message = function(ko)
        return function(text, title, onOk) return ko.message{ title = title, text = text, onOk = onOk } end
    end,
    wait = function(ko)
        return function(text, on_stop)
            local handle = { done = false }
            local box = ko.wait(text, on_stop and { cancel = function()
                if handle.done then return end
                handle.done = true
                on_stop()
            end, cancelText = _("Stop") } or nil)
            handle.close = function()
                handle.done = true
                if box and box.close then box:close() end
            end
            return handle
        end
    end,
}

return setmetatable({}, {
    __index = function(__, k)
        local ko = require("pluginshare").ko
        if ko and SHARED[k] and ko[k] then return ko[k] end
        if ko and ADAPTED[k] and ko[k] then return ADAPTED[k](ko) end
        return KO[k]
    end,
    __newindex = KO,
})
