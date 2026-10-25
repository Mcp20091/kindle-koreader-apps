--[[--
The title bar the apps share ("an OS inside KOReader"), as Apps draws it
(apps.koplugin/appsbar.lua), on Wikipedia's canvas:

    ‹  ⌂  ↺  Title       [the app's buttons]  12:45  ▭ 80% ▾   ⟳   🔔   ⋮

‹ goes one screen back (on the top page, to Apps), ⌂ to Apps, ↺ the recent
apps; then the title; at the right the app's own buttons, the clock and battery, ⟳ Refresh,
🔔 the shared notifications (a badge counts the unread ones) and ⋮ the menu
(Recent apps, Light, Night mode, Refresh screen, then Settings). A tap on the
time and battery (▾) opens the control center. Without Apps: no ⌂, ↺, ▾
or 🔔. 44 units tall; Lucide icons 18 units, 34 apart.

Also the menu and the full e-ink refresh when something over a screen of
these apps closes (both as in Apps, Home Assistant and To Do).
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Canvas = require("wikicanvas")

local C = Canvas
local Bar = {}

Bar.H = 44

local function PS() return require("pluginshare") end

--- The Apps launcher is there to go Home to.
function Bar.hasHome() return PS().appsHome ~= nil end

--- The shared notifications are there.
function Bar.hasBell() return PS().showNotifications ~= nil end

function Bar.unread()
    local ok, n = pcall(function() return PS().notifyCount and PS().notifyCount() or 0 end)
    return ok and tonumber(n) or 0
end

function Bar.bell(c, x, y, n)
    c:icon("bell", x, y, 18)
    if n and n > 0 then
        local s = n > 99 and "99+" or tostring(n)
        local bw = math.max(14, c:width(s, 8, true) + 6)
        c:box(x + 10, y - 6, bw, 14, { r = 7, fill = C.FILL })
        c:text(x + 10 + bw / 2, y + 5, s, 8, { bold = true, align = "middle", color = C.ON_FILL })
    end
end

local function battery()
    local powerd = Device:getPowerDevice()
    local ok, pct = pcall(function() return powerd:getCapacity() end)
    local ok2, charging = pcall(function() return powerd:isCharging() end)
    return ok and tonumber(pct) or nil, ok2 and charging == true
end

--- The time and battery ending at x, their middle at cy. Returns how wide.
function Bar.status(c, x, cy, caret)
    local size = 11
    local right = x
    -- ▾: a tap here drops down the control center.
    if caret then
        c:icon("chevron-down", x - 12, cy - 6, 12)
        x = x - 16
    end
    local pct, charging = battery()
    if pct then
        local tw = c:width(pct .. "%", size)
        c:text(x, cy + size * 0.36, pct .. "%", size, { align = "end" })
        x = x - tw - 3 - 18
        c:icon(charging and "battery-charging" or "battery", x, cy - 9, 18)
        if not charging and pct > 0 then
            -- Filled as far as charged (inside Lucide's outline: 3..17 by 7..17 of 24).
            local k = 18 / 24
            c:box(x + 4.5 * k, cy - 9 + 8.5 * k, 11 * k * math.min(100, pct) / 100, 7 * k, { fill = C.BLACK })
        end
        x = x - 10
    end
    -- What's running now (the web server…): its icon, as every app's corner shows it.
    for __, icon in ipairs(PS().statusIcons and PS().statusIcons() or {}) do
        c:icon(icon, x - 16, cy - 8, 16)
        x = x - 16 - 8
    end
    local now = os.date("*t")
    local clock
    if G_reader_settings:isTrue("twelve_hour_clock") then
        clock = string.format("%d:%02d %s", (now.hour + 11) % 12 + 1, now.min, now.hour < 12 and "AM" or "PM")
    else
        clock = string.format("%02d:%02d", now.hour, now.min)
    end
    c:text(x, cy + size * 0.36, clock, size, { bold = true, align = "end" })
    x = x - c:width(clock, size, true)
    return right - x
end

--- Draws the bar. opts: title, back, home, buttons = { { icon, fn } or
-- { label = "EN", fn } }, pager = { page, pages, turn = fn(delta) },
-- refresh, bell, menu (each a function, or nil for none).
function Bar.draw(c, opts)
    c:rect(0, 0, c.W, Bar.H, C.WHITE)
    c:hline(0, Bar.H, c.W, C.BLACK, 2)
    local x = 14
    if opts.back then
        c:icon("chevron-left", 12, 13, 18)
        c:hit(0, 0, 40, Bar.H, opts.back)
        x = 42
    end
    if opts.home then
        c:icon("house", x + 2, 13, 18)
        c:hit(x - 4, 0, 34, Bar.H, opts.home)
        x = x + 36
    end
    -- Recent apps (Apps' switcher), next to ⌂.
    if opts.home and PS().showSwitcher then
        c:icon("history", x + 2, 13, 18)
        c:hit(x - 4, 0, 34, Bar.H, function() PS().showSwitcher() end)
        x = x + 36
    end
    local right = c.W - 32
    if opts.menu then
        c:icon("ellipsis-vertical", right, 13, 18)
        c:hit(right - 8, 0, 40, Bar.H, opts.menu)
        right = right - 34
    end
    if opts.bell then
        Bar.bell(c, right, 13, Bar.unread())
        c:hit(right - 8, 0, 34, Bar.H, opts.bell)
        right = right - 34
    end
    if opts.refresh then
        c:icon("refresh-cw", right, 13, 18)
        c:hit(right - 8, 0, 34, Bar.H, opts.refresh)
        right = right - 34
    end
    right = right + 18
    -- A tap on the time and battery (▾): the control center (light, Wi-Fi, night mode…), with Apps.
    local sw = Bar.status(c, right - 14, 22, PS().showControlCenter ~= nil)
    if PS().showControlCenter then
        c:hit(right - 20 - sw, 0, sw + 12, Bar.H, function() PS().showControlCenter() end)
    end
    right = right - 14 - sw
    local buttons = opts.buttons or {}
    for i = #buttons, 1, -1 do
        local b = buttons[i]
        if b.label then
            -- A short word in a box (the language).
            local lw = math.max(30, c:width(b.label, 10.5, true) + 12)
            right = right - lw - 10
            c:box(right, 11, lw, 22, { r = 5, border = C.BLACK, bw = 1.2 })
            c:text(right + lw / 2, 26, b.label, 10.5, { bold = true, align = "middle" })
            c:hit(right - 5, 0, lw + 10, Bar.H, b[1])
        else
            right = right - 34
            c:icon(b[1], right + 8, 13, 18)
            c:hit(right, 0, 34, Bar.H, b[2])
        end
    end
    local p = opts.pager
    if p and (p.pages or 1) > 1 then
        local label = p.page .. "/" .. p.pages
        local lw = c:width(label, 11) + 40
        right = right - lw - 4
        c:icon("chevron-left", right + 2, 15, 14)
        c:text(right + lw / 2, 27, label, 11, { align = "middle", color = C.GREY })
        c:icon("chevron-right", right + lw - 16, 15, 14)
        c:hit(right - 6, 0, lw / 2 + 6, Bar.H, function() p.turn(-1) end)
        c:hit(right + lw / 2, 0, lw / 2 + 6, Bar.H, function() p.turn(1) end)
    end
    c:text(x, 28, opts.title or "", 15, { bold = true, maxw = math.max(40, right - x - 8) })
end

--- A swipe in from the left edge (it starts in the leftmost tenth): Back, in every app.
function Bar.fromLeftEdge(ges)
    return ges ~= nil and ges.direction == "east" and ges.pos ~= nil and ges.pos.x < Device.screen:getWidth() * 0.1
end

function Bar.home()
    if PS().appsHome then return PS().appsHome() end
end

function Bar.showNotifications()
    if PS().showNotifications then PS().showNotifications() end
end

-- ------------------------------------------------------------------ the menu

local function toggleNightMode(kui)
    local listener = kui and kui.devicelistener
    if listener and listener.onToggleNightMode then return listener:onToggleNightMode() end
    local night = G_reader_settings:isTrue("night_mode")
    Device.screen:toggleNightMode()
    UIManager:ToggleNightMode(not night)
    G_reader_settings:saveSetting("night_mode", not night)
    UIManager:setDirty("all", "full")
end

-- ------------------------------------------------------------------ the shared pop-ups

-- (Apps' pop-ups, in the look of the title bar; KOReader's own without Apps)
local function popup() return PS().popup end

-- With the launcher, its copy of the generic helpers (PS.ko: list, choose,
-- confirm, toast) answers, so a change there (a menu's Back) reaches every app;
-- these are for when it isn't installed.
local function shared(name)
    local ko = PS().ko
    return ko and ko[name]
end

--- A list to pick from ({ { text, fn, enabled, checked, danger } }), with a title;
-- back = fn: one level down (Back instead of Close, back to the list before).
function Bar.list(title, items, back)
    local f = shared("list")
    if f then return f(title, items, back) end
    local P = popup()
    if P then return P.menu{ title = title, items = items, back = back } end
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

--- A notice for a few seconds (an error: "Can't reach Wikipedia…").
function Bar.notice(text, seconds)
    local P = popup()
    if P then return P.toast(text, seconds or 3) end
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = seconds or 3 })
end

--- A box while something runs ("Downloading…"); a tap on it calls onStop
-- (a touch in its first second doesn't: the rest of the tap that started it,
-- the pen, a lingering finger). Returns { close = fn } for when the work ends.
function Bar.wait(text, onStop)
    local time = require("ui/time")
    local logger = require("logger")
    local handle = { done = false }
    local box
    local function stop()
        if handle.done then return end
        handle.done = true
        logger.info("Wikipedia: stopped by a tap:", text)
        onStop()
    end
    local P = popup()
    if P then
        local shown = time.now()
        box = P.wait(text)
        -- (the shared wait box isn't tappable: a tap anywhere is Stop here)
        local Geom = require("ui/geometry")
        local GestureRange = require("ui/gesturerange")
        local all = Geom:new{ x = 0, y = 0, w = Device.screen:getWidth(), h = Device.screen:getHeight() }
        box.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = all } } }
        box.onTap = function()
            if time.to_s(time.since(shown)) < 1 then
                logger.info("Wikipedia: a touch as the message showed, not taken as Stop")
                return true
            end
            box:close()
            stop()
            return true
        end
        handle.close = function() handle.done = true; box:close() end
        return handle
    end
    -- Without Apps: KOReader's message, which closes on any tap.
    local function showMessage()
        local shown = time.now()
        box = require("ui/widget/infomessage"):new{ text = text, flush_events_on_show = true, dismiss_callback = function()
            box = nil
            if handle.done then return end
            if time.to_s(time.since(shown)) < 1 then
                logger.info("Wikipedia: a touch as the message showed, not taken as Stop")
                return UIManager:nextTick(function() if not handle.done then showMessage() end end)
            end
            stop()
        end }
        UIManager:show(box)
    end
    showMessage()
    handle.close = function()
        handle.done = true
        if box then
            box.dismiss_callback = nil
            UIManager:close(box)
        end
    end
    return handle
end

--- One of `options` ({ label, value }), the current one ticked; done(value).
function Bar.choose(title, options, current, done, back)
    local f = shared("choose")
    if f then return f(title, options, current, done, back) end
    local items = {}
    for __, o in ipairs(options) do
        table.insert(items, { text = o.label, checked = o.value == current, fn = function() done(o.value) end })
    end
    return Bar.list(title, items, back)
end

--- A row of buttons as the launcher's pop-ups draw them (appspopup's iconButtons):
-- { icon, text, primary }, each an icon over a short label, the main one black, as
-- wide as one of five, lined up on the right of x..x+bw; act(b) when one is tapped.
-- 76 tall; enabled = false greys one out. The launcher's own (PS.popup.iconButtons)
-- draws them when it's there; this copy is for without it.
function Bar.iconButtons(c, x, y, bw, buttons, act)
    local P = popup()
    if P and P.iconButtons then return P.iconButtons(c, x, y, bw, buttons, act) end
    local gap = 10
    local n = math.max(1, #buttons)
    local w = math.min((bw - 36 - gap * (n - 1)) / n, (bw - 36 - gap * 4) / 5)
    local withLabels = true
    if P and P.labels then
        local ok, on = pcall(P.labels)
        if ok then withLabels = on end
    end
    local allIcons = true
    for __, b in ipairs(buttons) do if not b.icon then allIcons = false end end
    if not withLabels and allIcons then w = math.min(w, 56) end
    local bx = x + bw - 18 - (n * w + gap * (n - 1))
    for __, b in ipairs(buttons) do
        local off = b.enabled == false
        c:box(bx, y + 10, w, 56, { r = 14, fill = b.primary and not off and C.FILL or C.WHITE,
            border = off and C.LIGHT or C.BLACK, bw = 1.2 })
        local white = b.primary and not off
        if b.icon and not withLabels then
            c:icon(b.icon, bx + w / 2 - 12, y + 26, 24, white)
        else
            if b.icon then c:icon(b.icon, bx + w / 2 - 11, y + 17, 22, white) end
            c:text(bx + w / 2, b.icon and (y + 58) or (y + 44), b.text or "", 10.5, { bold = true, align = "middle",
                maxw = w - 8, color = white and C.ON_FILL or (off and C.MID or C.BLACK) })
        end
        if not off then c:hit(bx, y + 6, w, 64, function() act(b) end) end
        bx = bx + w + gap
    end
end

--- Text to the clipboard, with a moment's notice.
function Bar.copy(text)
    if not text or text == "" then return end
    Device.input.setClipboardText(text)
    Bar.toast(_("Copied"))
end

--- Typing: { title, subtitle, text, hint, ok (its name), okIcon, needsText, done(text) },
-- done gets the text trimmed. The launcher's text box (PS.ko.askText: icon buttons,
-- the pen to write by hand) when it's there; KOReader's InputDialog without it.
function Bar.ask(o)
    local f = shared("askText")
    if f then return f(o) end
    local dialog
    dialog = require("ui/widget/inputdialog"):new{
        title = o.title,
        description = o.subtitle,
        input = o.text or "",
        input_hint = o.hint,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = o.ok, is_enter_default = true, callback = function()
                local v = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if o.needsText and v == "" then return end
                UIManager:close(dialog)
                o.done(v)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Ask first: { title, text, ok, cancel, danger, onOk, onCancel }.
function Bar.confirm(o)
    local f = shared("confirm")
    if f then return f(o) end
    local P = popup()
    if P then return P.confirm(o) end
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = (o.title and (o.title .. "\n\n") or "") .. (o.text or ""), ok_text = o.ok, cancel_text = o.cancel,
        ok_callback = o.onOk, cancel_callback = o.onCancel,
    })
end

--- After a removal: the text with Undo for about 6 s. False without Apps
-- (ask before removing then: Bar.canUndo).
function Bar.undo(text, onUndo)
    local P = popup()
    if P and P.undo then
        P.undo(text, onUndo)
        return true
    end
    return false
end

function Bar.canUndo()
    local P = popup()
    return P ~= nil and P.undo ~= nil
end

--- A notice for a moment ("Saved").
function Bar.toast(text, seconds)
    local f = shared("toast")
    if f then return f(text, seconds) end
    local P = popup()
    if P then return P.toast(text, seconds) end
    UIManager:show(require("ui/widget/notification"):new{ text = text })
end

--- ⋮: `extra` ({ { text, fn } }) first, then Light, Night mode and Refresh
-- screen, then Settings (`settings`) last.
function Bar.menu(kui, widget, extra, settings)
    local items = {}
    for __, x in ipairs(extra or {}) do table.insert(items, { text = x[1], fn = x[2] }) end
    -- The apps opened lately, the recent books and notebooks (Apps).
    if PS().showSwitcher then table.insert(items, { text = _("Recent apps"), fn = function() PS().showSwitcher() end }) end
    if Device:hasFrontlight() then
        table.insert(items, { text = _("Light"), fn = function() Device:showLightDialog() end })
    end
    table.insert(items, { text = G_reader_settings:isTrue("night_mode") and _("Night mode: On") or _("Night mode: Off"),
        fn = function() toggleNightMode(kui) end })
    table.insert(items, { text = _("Refresh screen"), fn = function()
        UIManager:nextTick(function() UIManager:setDirty(widget or "all", "full") end)
    end })
    if settings then table.insert(items, { text = _("Settings"), fn = settings }) end
    return Bar.list(nil, items)
end

-- ------------------------------------------------------------------ e-ink

--- A full refresh of a screen with `flash_on_uncover` as soon as a dialog,
-- menu or keyboard over it closes (one hook for all of KOReader, shared with
-- Apps, Home Assistant and To Do: whichever loads first sets it up).
function Bar.flashOnUncover()
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

return Bar
