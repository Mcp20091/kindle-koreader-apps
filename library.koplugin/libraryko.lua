--[[--
What the Library shares with the other apps' screens (from apps.koplugin's
appsko.lua, as SSH's sshko.lua has it): a full e-ink refresh when something
over a screen closes, Home, the ⋮ menu (the page's own items, Recent apps,
Light, Night mode, Refresh screen, then Settings last), and the apps' pop-ups
(lists, choices, confirmations, notices, text boxes, Undo; KOReader's own
without the launcher).
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local KO = {}

--- A full refresh of a screen of these apps as soon as a dialog, menu or
-- keyboard over it closes (e-ink keeps a ghost of it otherwise). A screen asks
-- for it with `flash_on_uncover = true`. (The same hook as the other apps':
-- whichever plugin loads first sets it.)
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

--- ⌂: the launcher on top; false without it.
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
    local night = G_reader_settings:isTrue("night_mode")
    Device.screen:toggleNightMode()
    UIManager:ToggleNightMode(not night)
    G_reader_settings:saveSetting("night_mode", not night)
    UIManager:setDirty("all", "full")
end

-- ------------------------------------------------------------------ pop-ups

-- The apps' pop-ups (the launcher's appspopup, shared in PluginShare), or nil without it.
local function popup()
    return require("pluginshare").popup
end
KO.popup = popup

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

--- A box while something runs; returns it (:close() it when done). With
-- opts.cancel (a function), a Cancel button stops it (only that does).
function KO.wait(text, opts)
    local P = popup()
    if P and P.wait then return P.wait(text, opts) end
    local m
    if opts and opts.cancel then
        m = require("ui/widget/buttondialog"):new{ title = text, title_align = "center", dismissable = false, buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(m) opts.cancel() end } } } }
    else
        m = require("ui/widget/infomessage"):new{ text = text }
    end
    m.close = function() UIManager:close(m) end
    UIManager:show(m)
    return m
end

--- Something to read (a problem), with OK.
function KO.message(text, title)
    local P = popup()
    if P and P.message then return P.message{ title = title, text = text } end
    UIManager:show(require("ui/widget/infomessage"):new{ text = (title and (title .. "\n\n") or "") .. text })
end

--- Undo can follow a delete (the apps' undo bar); without it a delete asks first.
function KO.canUndo()
    local P = popup()
    return P ~= nil and P.undo ~= nil
end

--- The undo bar: text and Undo (onUndo) for about 6 s; done() when it has gone
-- without Undo (then what was deleted can go for good).
function KO.undo(text, onUndo, done)
    local P = popup()
    local undone = false
    if P and P.undo then
        local box = P.undo(text, function()
            undone = true
            onUndo()
        end)
        UIManager:scheduleIn(7, function()
            if not undone and done then done() end
        end)
        return box
    end
    KO.toast(text)
    if done then UIManager:scheduleIn(1, done) end
end

--- A text box: { title, subtitle, text, hint, ok (the main button's label),
-- okIcon, rows = { { text, fn(box) } } (filled in with a tap; heading: rowsTitle),
-- done(text) }. The launcher's box (a pen for handwriting, icon buttons);
-- KOReader's InputDialog without it.
function KO.ask(o)
    local P = popup()
    if P and P.request then
        local sections
        if o.rows and #o.rows > 0 then
            local items = {}
            for __, r in ipairs(o.rows) do
                table.insert(items, { text = r.text, fn = function(box) box:setText(r.value or r.text) end })
            end
            sections = { { heading = o.rowsTitle, items = items } }
        end
        local box = P.request{ title = o.title, subtitle = o.subtitle, text = o.text, hint = o.hint, sections = sections,
            pen = true, penKind = "name", typing = o.typing,
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = o.okIcon or "check", text = o.ok or _("Save"), primary = true, needsText = true,
                    fn = function(text) o.done(text) end },
            } }
        if type(box) == "table" then box.is_always_active = true end
        return box
    end
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = o.title, input = o.text or "", input_hint = o.hint,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = o.ok or _("Save"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                if text and text ~= "" then o.done(text) end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

--- A swipe right that starts at the screen's left edge: Back, on every screen.
function KO.fromLeftEdge(ges)
    return ges ~= nil and ges.direction == "east" and ges.pos ~= nil and ges.pos.x < Device.screen:getWidth() * 0.1
end

--- The ⋮ menu: `extra` ({ { text, fn, checked }, ... }) first, then Recent
-- apps, Light, Night mode and Refresh screen, and Settings (`settings`) last.
function KO.menu(kui, extra, settings)
    local items = {}
    for __, x in ipairs(extra or {}) do table.insert(items, { text = x[1], fn = x[2], checked = x[3] }) end
    local PS = require("pluginshare")
    if PS.showSwitcher then table.insert(items, { text = _("Recent apps"), fn = function() PS.showSwitcher() end }) end
    if Device:hasFrontlight() then
        table.insert(items, { text = _("Light"), fn = function() Device:showLightDialog() end })
    end
    table.insert(items, { text = KO.nightMode() and _("Night mode: On") or _("Night mode: Off"), fn = function()
        KO.toggleNightMode(kui)
    end })
    table.insert(items, { text = _("Refresh screen"), fn = function()
        UIManager:nextTick(function() UIManager:setDirty("all", "full") end)
    end })
    if settings then table.insert(items, { text = _("Settings"), fn = settings }) end
    return KO.list(nil, items)
end

-- ------------------------------------------------------------------ the launcher's copy

-- With the launcher, the generic helpers are its one copy (PS.ko); the ones
-- above are the fallback without it.
local SHARED = { list = true, choose = true, confirm = true, toast = true, fromLeftEdge = true }

return setmetatable({}, {
    __index = function(__, k)
        local ko = require("pluginshare").ko
        if ko and SHARED[k] and ko[k] then return ko[k] end
        return KO[k]
    end,
    __newindex = KO,
})
