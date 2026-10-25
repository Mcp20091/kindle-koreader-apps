--[[--
What Syncthing shares with the other apps (the same as apps.koplugin's
appsko.lua): their pop-ups (appspopup when the Apps plugin is there,
KOReader's own otherwise) and a full refresh when a dialog over a screen
closes.
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local KO = {}

function KO.hasLight() return Device:hasFrontlight() end

function KO.light()
    if Device:hasFrontlight() then Device:showLightDialog() end
end

function KO.nightMode() return G_reader_settings:isTrue("night_mode") end

--- The clock as KOReader shows it (its 12-hour setting; 24-hour otherwise), as in every app.
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

function KO.refresh(widget)
    UIManager:setDirty(widget or "all", "full")
end

--- A full refresh of a screen of these apps as soon as a dialog, menu or
-- keyboard over it closes: e-ink keeps a ghost of it otherwise. A screen asks
-- for it with `flash_on_uncover = true`. One hook on UIManager:close for all
-- of KOReader: whichever app loads first sets it up.
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

-- ------------------------------------------------------------------ pop-ups

--- The shared pop-ups (appspopup.lua in Apps), or KOReader's own without Apps.
local function popup()
    local ok, P = pcall(require, "appspopup")
    return ok and P or nil
end

--- The ⋮ menu: `extra` ({ { text, fn }, ... }) first, then KOReader's light
-- and night mode and a full refresh, and Settings (`settings`, a function) last.
function KO.menu(kui, widget, extra, settings)
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
function KO.list(title, items)
    local P = popup()
    if P then return P.menu{ title = title, items = items } end
    local dialog
    local buttons = {}
    for __, it in ipairs(items) do
        table.insert(buttons, { { text = (it.checked and "\u{2713} " or "") .. it.text, enabled = it.enabled ~= false,
            callback = function() UIManager:close(dialog) if it.fn then it.fn() end end } })
    end
    table.insert(buttons, { { text = _("Close"), callback = function() UIManager:close(dialog) end } })
    dialog = require("ui/widget/buttondialog"):new{ title = title, title_align = "center", buttons = buttons }
    UIManager:show(dialog)
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

--- Text to read (details, help), in the apps' box: { title, text, ok, onOk,
-- cancel }: only to read, one OK button; with onOk, Close and `ok` (doing
-- onOk). Without Apps, KOReader's own message (or a question when there is onOk).
function KO.message(o)
    local P = popup()
    -- Only to read: the one-button box. With an action: Close and the action
    -- (the one-button box would do it however it is closed).
    if P and P.message and not o.onOk then
        return P.message{ title = o.title, text = o.text, ok = o.ok }
    end
    if P then
        return P.confirm{ title = o.title, text = o.text, ok = o.ok or _("OK"), cancel = o.cancel or _("Close"), onOk = o.onOk }
    end
    local text = (o.title and (o.title .. "\n\n") or "") .. (o.text or "")
    if o.onOk then
        return UIManager:show(require("ui/widget/confirmbox"):new{ text = text, ok_text = o.ok, cancel_text = o.cancel or _("Close"),
            ok_callback = o.onOk })
    end
    UIManager:show(require("ui/widget/infomessage"):new{ text = text })
end

--- A swipe that starts at the left edge (the leftmost tenth), going right: Back, everywhere.
function KO.fromLeftEdge(ges)
    return ges ~= nil and ges.direction == "east" and ges.pos ~= nil and ges.pos.x < Device.screen:getWidth() * 0.1
end

--- After something is taken away: the text with Undo for about 6 s (onUndo
-- puts it back); without Apps, a notice only.
function KO.undo(text, onUndo)
    local P = popup()
    if P and P.undo then return P.undo(text, onUndo) end
    UIManager:show(require("ui/widget/notification"):new{ text = text })
end

--- A notice for a moment ("Rescanning Books…").
function KO.toast(text, seconds)
    local P = popup()
    if P then return P.toast(text, seconds) end
    UIManager:show(require("ui/widget/notification"):new{ text = text })
end

--- A row of icon buttons on one of Syncthing's own canvases, drawn as the
-- launcher's (Popup.iconButtons): each an icon over a short label, the main one
-- black, each as wide as one of five, lined up on the right (18 in from the
-- edge of x..x+bw). buttons = { { icon, text, primary } }; act(b). 76 tall.
function KO.iconButtons(c, C, x, y, bw, buttons, act)
    local PS = require("pluginshare")
    local okL, withLabels = pcall(function()
        if PS.popup and PS.popup.labels then return PS.popup.labels() end
        return true
    end)
    withLabels = not okL or withLabels ~= false
    local gap = 10
    local n = math.max(1, #buttons)
    local w = math.min((bw - 36 - gap * (n - 1)) / n, (bw - 36 - gap * 4) / 5)
    if not withLabels then w = math.min(w, 56) end
    local bx = x + bw - 18 - (n * w + gap * (n - 1))
    for __, b in ipairs(buttons) do
        c:box(bx, y + 10, w, 56, { r = 14, fill = b.primary and C.FILL or C.WHITE, border = C.BLACK, bw = 1.2 })
        if not withLabels then
            c:icon(b.icon, bx + w / 2 - 12, y + 26, 24, b.primary)
        else
            c:icon(b.icon, bx + w / 2 - 11, y + 17, 22, b.primary)
            c:text(bx + w / 2, y + 58, b.text or "", 10.5, { bold = true, align = "middle", maxw = w - 8,
                color = b.primary and C.ON_FILL or C.BLACK })
        end
        c:hit(bx, y + 6, w, 64, function() act(b) end)
        bx = bx + w + gap
    end
end

--- Text to read in the launcher's reading page, with Copy (what `copy` gives,
-- else all the text) and an optional action: { title, text, copy, ok, okIcon,
-- onOk }. Without the launcher, KOReader's own message.
function KO.read(o)
    local PS = require("pluginshare")
    local P = PS.popup
    local okR, read = pcall(function() return P and P.read end)
    if okR and read then
        local buttons = { { icon = "copy", text = _("Copy"), keep = true, fn = function()
            if Device.input and Device.input.setClipboardText then Device.input.setClipboardText(o.copy or o.text or "") end
            KO.toast(_("Copied"))
        end } }
        if o.onOk then
            table.insert(buttons, { icon = o.okIcon or "check", text = o.ok, fn = function() o.onOk() end })
        end
        table.insert(buttons, { icon = "check", text = _("Done"), primary = true })
        return read{ title = o.title, text = o.text, buttons = buttons }
    end
    return KO.message{ title = o.title, text = o.text, ok = o.ok, onOk = o.onOk }
end

-- With the launcher installed, its single copy of the generic helpers is used
-- (PS.ko), so a change there reaches every app; these copies are only for
-- without it. Not handed over: message (Syncthing's with an action keeps Close
-- next to it; the shared one runs its action however it is closed) and the rest.
local SHARED = { list = true, choose = true, buttonDialog = true, confirm = true, toast = true,
    wait = true, undo = true, fromLeftEdge = true }
local PS = require("pluginshare")
return setmetatable({}, {
    __index = function(__, k)
        local shared = SHARED[k] and PS.ko
        local v = shared and shared[k]
        if v == nil then v = KO[k] end
        return v
    end,
    __newindex = KO,
})
