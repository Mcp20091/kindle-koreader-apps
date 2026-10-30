--[[--
To Do's screens, drawn with todoui in the mockup's units: Home, Today,
Agenda, Starred, a list, search, a task, the calendar, Sync, Settings, the
hold popup and the sleep screen. Each screen builds rows; the frame (title
bar, rows a page at a time, status bar) is shared.

`c` is the plugin (main.lua): it holds the store, the settings and the
actions the screens call.
]]

local Dates = require("tododates")
local Device = require("device")
local Model = require("todomodel")
local Store = require("todostore")
local UI = require("todoui")
local _ = require("gettext")
local T = require("ffi/util").template

local Views = {}

local BLACK, WHITE, GREY, MID, LIGHT, LINE, BAND = UI.BLACK, UI.WHITE, UI.GREY, UI.MID, UI.LIGHT, UI.LINE, UI.BAND

-- ------------------------------------------------------------------ pieces

-- The time and the battery (KOReader's screen, with its own, is covered),
-- ending at x, their digits level with the middle of the icons. Returns how
-- wide they were.
local function status(p, x)
    local right = x
    local powerd = Device.getPowerDevice and Device:getPowerDevice()
    local okp, pct = pcall(function() return powerd and powerd:getCapacity() end)
    local okc, charging = pcall(function() return powerd and powerd:isCharging() end)
    pct = okp and tonumber(pct) or nil
    charging = okc and charging == true
    if pct then
        x = x - p:text(x, 26, pct .. "%", 11, false, BLACK, "end") - 3 - 18
        p:icon(charging and "battery-charging" or "battery", x, 13, 18)
        if not charging and pct > 0 then
            -- Filled as far as it is charged (inside the outline: 3..17 by 7..17 of 24).
            local k = 18 / 24
            p:rect(x + 4.5 * k, 13 + 8.5 * k, 11 * k * math.min(100, pct) / 100, 7 * k, BLACK)
        end
        x = x - 10
    end
    -- What's running now (the web server…), as every app's corner shows it.
    local PS = require("pluginshare")
    for __, icon in ipairs(PS.statusIcons and PS.statusIcons() or {}) do
        p:icon(icon, x - 16, 14, 16)
        x = x - 16 - 8
    end
    local now = os.date("*t")
    x = x - p:text(x, 26, Dates.clock(now.hour * 60 + now.min), 11, true, BLACK, "end")
    return right - x
end

--- The title bar every app shares (see apps.koplugin/appsbar.lua): ‹ back
-- (from Home, to Apps), ⌂ Apps, the title; at the right the screen's own
-- buttons (`right`, the first rightmost), the time and battery, ⟳ (a
-- screen's own refresh-cw, or Sync now; a full refresh either way), 🔔 and
-- ⋮ (a screen's own ellipsis-vertical, or the To Do menu; Settings last).
local function titleBar(c, p, zone, W, title, left, right, withStatus, pager)
    local PS = require("pluginshare")
    -- (A hold works a button as a tap does, when it has none of its own: a firm
    -- press of the pen lasts long enough to be a hold.)
    local tapZone = zone
    zone = function(x, y, w, h, tap, hold) tapZone(x, y, w, h, tap, hold or tap) end
    p:rect(0, 0, W, 44, WHITE)
    p:hline(0, 44, W, BLACK, 2)
    p:icon("chevron-left", 12, 13, 18)
    zone(0, 0, 40, 44, left and left.fn or function() c:back() end)
    local x = 42
    if PS.appsHome then
        p:icon("house", x + 2, 13, 18)
        zone(x - 4, 0, 34, 44, function() c:home() end)
        x = x + 36
    end
    -- Recent apps (Apps' switcher), next to ⌂.
    if PS.showSwitcher then
        p:icon("history", x + 2, 13, 18)
        zone(x - 4, 0, 34, 44, function() PS.showSwitcher() end)
        x = x + 36
    end
    local menu, sync
    local own = {}
    for __, r in ipairs(right or {}) do
        if r.icon == "ellipsis-vertical" then menu = r.fn
        elseif r.icon == "refresh-cw" then sync = r.fn
        else table.insert(own, r) end
    end
    p:icon("ellipsis-vertical", W - 32, 13, 18)
    zone(W - 40, 0, 40, 44, menu or function() c:moreMenu() end)
    local bx = W - 66
    p:icon("bell", bx, 13, 18)
    local unread = 0
    pcall(function() unread = PS.notifyCount and PS.notifyCount() or 0 end)
    if unread > 0 then
        local s = unread > 99 and "99+" or tostring(unread)
        local bw = math.max(14, UI.textWidth(s, 8, true) + 6)
        p:rect(bx + 10, 7, bw, 14, BLACK, 7)
        p:text(bx + 10 + bw / 2, 18, s, 8, true, WHITE, "middle")
    end
    zone(bx - 8, 0, 34, 44, function() c:showNotifications() end)
    local rx = W - 100
    p:icon("refresh-cw", rx, 13, 18)
    zone(rx - 8, 0, 34, 44, function()
        if sync then sync() else c:syncNow() end
        c:refreshScreen()
    end)
    local edge = rx - 14
    if withStatus then
        -- A tap on the time and battery (▾): the control center (Apps: light, Wi-Fi, night mode…).
        local caret = PS.showControlCenter and 16 or 0
        if caret > 0 then p:icon("chevron-down", edge - 12, 16, 12) end
        local sw = status(p, edge - caret) + caret
        if PS.showControlCenter then zone(edge - sw - 6, 0, sw + 12, 44, function() PS.showControlCenter() end) end
        edge = edge - sw - 14
    end
    for __, r in ipairs(own) do
        edge = edge - 34
        p:icon(r.icon, edge + 8, 13, 18)
        zone(edge, 0, 34, 44, r.fn, r.hold)
    end
    -- The page count (screens without the status bar at the bottom).
    if pager and pager.pages > 1 then
        local s = pager.page .. "/" .. pager.pages
        local lw = UI.textWidth(s, 11, false) + 40
        edge = edge - lw - 4
        p:icon("chevron-left", edge + 2, 15, 14)
        p:text(edge + lw / 2, 27, s, 11, false, GREY, "middle")
        p:icon("chevron-right", edge + lw - 16, 15, 14)
        zone(edge - 6, 0, lw / 2 + 6, 44, function() c:turnPage(-1) end)
        zone(edge + lw / 2, 0, lw / 2 + 6, 44, function() c:turnPage(1) end)
    end
    p:text(x, 28, title, 15, true, BLACK, "start", math.max(40, edge - x - 8))
end

local function label(p, x, y, text, color)
    p:text(x, y, text, 9.5, true, color or GREY)
end

-- Small icons and texts in a row (a task's second line). Returns the end x.
local function parts(p, x, y, list, maxX, color)
    color = color or GREY
    for __, part in ipairs(list) do
        if x > maxX - 20 then break end
        if part[1] then
            p:icon(part[1], x, y - 8.5, 10)
            x = x + 13
        end
        if part[2] and part[2] ~= "" then
            x = x + p:text(x, y, part[2], 9.5, false, color, "start", maxX - x)
        end
        x = x + 9
    end
    return x
end
Views.parts = parts

-- A switch, as in every app's settings: 40 by 22, black with the knob at the right when on.
local function toggle(p, x, y, on)
    p:rect(x, y, 40, 22, on and BLACK or WHITE, 11)
    p:frame(x, y, 40, 22, 1, BLACK, 11)
    p:circle(on and x + 29 or x + 11, y + 11, 7, on and WHITE or BLACK)
end

local function chevron(p, W, y)
    p:icon("chevron-right", W - 26, y + 12, 12)
end

-- A task's second line: when, reminder, repeat, steps, notes, list.
function Views.taskParts(c, e, opts)
    local task, today, offset = e.task, c:today(), c:offset()
    local out = {}
    if task.due and (opts.showDate or task.due ~= today) then
        local text
        if task.due < today or task.due > today + 6 then text = Dates.short(task.due)
        else text = Dates.friendly(task.due, today) end
        -- In the Agenda the section names the day: only overdue tasks say theirs.
        if opts.agenda and task.due >= today then text = nil end
        if text then table.insert(out, { "calendar", text }) end
    end
    local minute = Dates.reminderMinute(task, offset)
    if minute then
        table.insert(out, { "bell", Dates.clock(minute) })
    elseif task.remindAt then
        local local_ = task.remindAt + offset
        table.insert(out, { "bell", Dates.short(math.floor(local_ / 86400)) .. " " .. Dates.clock(math.floor(local_ % 86400 / 60)) })
    end
    if task.recurring then table.insert(out, { "repeat", e["repeat"] and _("repeats") or "" }) end
    if #task.steps > 0 then
        local done = 0
        for __, s in ipairs(task.steps) do done = done + (s.checked and 1 or 0) end
        table.insert(out, { "list-checks", done .. "/" .. #task.steps })
    end
    if task.notes then table.insert(out, { "notebook-text", "" }) end
    if opts.withList then table.insert(out, { "list", e.list.name }) end
    if c.store:isPrivate(task.id) then table.insert(out, { "eye-off", "" }) end
    return out
end

--- A task row (46 units): box ticks it, the rest opens it, hold for actions.
function Views.taskRow(c, e, opts)
    opts = opts or {}
    return { h = 46, draw = function(p, y, zone, W)
        local task = e.task
        if task.completed then
            p:rect(14, y + 10, 16, 16, BLACK, 3)
            p:icon("check", 16, y + 12, 12, true)
            local w = p:text(42, y + 21, task.title, 12.5, false, MID, "start", W - 84)
            p:hline(42, y + 16.5, w, MID, 0.8)
        else
            p:rect(14, y + 10, 16, 16, WHITE, 3)
            p:frame(14, y + 10, 16, 16, 1.3, BLACK, 3)
            p:text(42, y + 21, task.title, 12.5, false, BLACK, "start", W - 84)
        end
        parts(p, 42, y + 37, Views.taskParts(c, e, opts), W - 40)
        if task.important then p:icon("star-filled", W - 32, y + 14, 16) end
        p:hline(42, y + 46, W - 42, LINE)
        zone(0, y, W, 46, function() c:tapTask(e.list, task) end, function() c:holdTask(e.list, task) end)
        zone(0, y, 40, 46, function() c:toggleDone(e.list, task) end, function() c:holdTask(e.list, task) end)
        if task.important or opts.starZone then
            zone(W - 44, y, 44, 46, function() c:toggleStar(e.list, task) end)
        end
    end }
end

function Views.bandRow(title, right)
    return { h = 22, draw = function(p, y, zone, W)
        p:rect(0, y, W, 22, BAND)
        label(p, 14, y + 15, title)
        if right then p:text(W - 14, y + 15, right, 9.5, false, GREY, "end") end
    end }
end

function Views.messageRow(text)
    return { h = 60, draw = function(p, y, zone, W)
        p:text(W / 2, y + 36, text, 12, false, MID, "middle", W - 40)
    end }
end

--- "Deleted (2)": what waits for the next sync, to put back.
function Views.deletedRow(text, tap, icon, action)
    return { h = 40, draw = function(p, y, zone, W)
        p:icon(icon or "trash-2", 14, y + 12, 15)
        p:text(40, y + 26, text, 11.5, false, GREY, "start", W - 80)
        p:text(W - 14, y + 26, action or _("Put back"), 10, false, GREY, "end")
        zone(0, y, W, 40, tap)
    end }
end

function Views.labelRow(text, right, plus)
    return { h = 30, draw = function(p, y, zone, W)
        label(p, 14, y + 21, text)
        if right then p:text(W - 14, y + 21, right, 9.5, false, GREY, "end") end
        if plus then
            p:icon("plus", W - 30, y + 9, 16)
            zone(W - 44, y, 44, 30, plus)
        end
    end }
end

--- A section heading of the settings, as every app's: grey capitals, kept
-- on a page with at least its first row.
function Views.settingsHeading(text)
    return { h = 34, keep = 36, draw = function(p, y)
        label(p, 14, y + 26, text)
    end }
end

-- A settings row: label, then a value (with a chevron) or a switch.
function Views.settingRow(text, value, on, tap, hint)
    local h = hint and 46 or 36
    return { h = h, name = text, draw = function(p, y, zone, W)
        p:text(14, y + 23, text, 12, false, BLACK, "start", W - 180)
        if hint then p:text(14, y + 39, hint, 9.5, false, GREY, "start", W - 70) end
        if on ~= nil then
            toggle(p, W - 54, y + 7, on)
        elseif value then
            p:text(W - 30, y + 23, value, 11, false, GREY, "end", 200)
            chevron(p, W, y)
        end
        p:hline(14, y + h, W - 14, LINE)
        if tap then zone(0, y, W, h, tap) end
    end }
end

-- ------------------------------------------------------------------ frame

--- Draws a screen: title bar, the rows of the current page, the status bar (or
-- `bottom`, a function drawing a bar `bottomH` units tall). Keeps view.page
-- in range and returns the number of pages.
--- The width the views draw in: the screen's, or the right pane's on its side.
function Views.width() return Views.paneW or (UI.size()) end

function Views.frame(c, view, p, zone, spec, paneW)
    local W, H = UI.size()
    W = paneW or W
    local bottomH = spec.bottomH or 34
    local top, bottom = 45, H - bottomH - (spec.reserve or 0)
    local pages = UI.paginate(spec.rows, top, bottom)
    view.pages = #pages
    -- Opened at a row (from the launcher's search): the page with the row of that name.
    if view.jump then
        for n, range in ipairs(pages) do
            for i = range[1], range[2] do
                if spec.rows[i].name == view.jump then view.page = n end
            end
        end
        view.jump = nil
    end
    view.page = math.max(1, math.min(view.page or 1, #pages))
    local range = pages[view.page]
    local y = top
    for i = range[1], range[2] do
        local row = spec.rows[i]
        if row.draw then row.draw(p, y, zone, W) end
        y = y + row.h
    end
    titleBar(c, p, zone, W, spec.title, spec.left, spec.right, true,
        spec.pagerTop and { page = view.page, pages = view.pages } or nil)
    if spec.after then spec.after(p, zone, W, H) end
    if spec.bottom then
        spec.bottom(p, zone, W, H)
    else
        Views.statusBar(c, view, p, zone, W, H)
    end
    return #pages
end

function Views.statusBar(c, view, p, zone, W, H)
    local y = H - 34
    p:rect(0, y, W, 34, WHITE)
    p:hline(0, y, W, BLACK, 1)
    local n = c.store:pending()
    local left
    if not c.api:signedIn() then left = c:opt("local_lists") and _("On this Kindle only") or _("Not signed in")
    elseif n == 0 then left = _("Everything sent")
    elseif n == 1 then left = _("1 change to send")
    else left = T(_("%1 changes to send"), n) end
    p:icon(n == 0 and "cloud-check" or "cloud-upload", 14, y + 9, 15)
    p:text(36, y + 21, left, 10, false, BLACK, "start", W / 2 - 90)
    local synced = c.store:syncedAt()
    if c.api:signedIn() then
        p:text(W - 14, y + 21, synced and T(_("Synced %1"), c:ago(synced)) or _("Never synced"), 10, false, GREY, "end", W / 2 - 90)
    end
    zone(0, y, W, 34, function() c:open({ kind = "sync" }) end)
    if (view.pages or 1) > 1 then
        local cx = W / 2
        p:rect(cx - 70, y + 2, 140, 31, WHITE)
        p:icon("chevron-left", cx - 60, y + 9, 16)
        p:text(cx, y + 22, view.page .. " / " .. view.pages, 11, true, BLACK, "middle")
        p:icon("chevron-right", cx + 44, y + 9, 16)
        zone(cx - 70, y, 60, 34, function() c:turnPage(-1) end)
        zone(cx + 10, y, 60, 34, function() c:turnPage(1) end)
    end
end

-- ------------------------------------------------------------------ order

--- Home tiles or lists (view.what): their order and which show. Tap one to
-- select it: to the top, up, down, to the bottom; the eye shows or hides
-- it; Undo puts the order back as it was before the last move.
function Views.order(c, view)
    local what = view.what
    local items = c:orderItems(what)
    local keys = {}
    for i, it in ipairs(items) do keys[i] = it.key end
    local rows = {}
    table.insert(rows, { h = 40, draw = function(p, y, zone, W)
        p:text(14, y + 24, _("Tap one, then use the arrows to move it. The eye shows or hides it."), 10, false, GREY, "start", W - 28)
    end })
    local n = #items
    for _i, it in ipairs(items) do
        table.insert(rows, { h = 44, draw = function(p, y, zone, W)
            local sel = view.sel == it.key
            if sel then p:rect(0, y, W, 44, BLACK) end
            p:text(14, y + 28, it.title, 12.5, sel, sel and WHITE or (it.on and BLACK or MID), "start", W - (sel and 300 or 80))
            zone(0, y, sel and W - 250 or W - 60, 44, function()
                view.sel = (not sel) and it.key or nil
                c:render()
            end)
            if sel then
                for j, a in ipairs({ { "arrow-up-to-line", -n }, { "arrow-up", -1 }, { "arrow-down", 1 }, { "arrow-down-to-line", n } }) do
                    local bx = W - 240 + (j - 1) * 46
                    p:rect(bx, y + 7, 40, 30, WHITE, 6)
                    p:icon(a[1], bx + 11, y + 13, 18)
                    zone(bx - 3, y, 46, 44, function() c:moveOrder(view, keys, it.key, a[2]) end)
                end
            end
            p:icon(it.on and "eye" or "eye-off", W - 36, y + 13, 18, sel)
            zone(W - 52, y, 52, 44, function()
                c:toggleShown(what, it.key)
                c:render()
            end)
            p:hline(14, y + 44, W - 14, LINE, 0.6)
        end })
    end
    local right = {}
    if view.undo and #view.undo > 0 then
        table.insert(right, { icon = "undo-2", fn = function()
            c:saveOrder(what, table.remove(view.undo))
            c:render()
        end })
    end
    return {
        title = what == "tiles" and _("Home tiles") or _("Lists"),
        left = { icon = "chevron-left", fn = function() c:back() end },
        right = right,
        rows = rows,
    }
end

-- ------------------------------------------------------------------ the left pane

--- On its side: the Home views and the lists in a column `W` wide (the open
-- one marked); tapping one opens it at the right.
function Views.pane(c, p, zone, W, H)
    local today = c:today()
    local s = Model.summary(c.store:lists(), today, { hidden = c:hiddenSet() })
    local lines = Views.tileLines(s, today)
    local items = {}
    for __, key in ipairs(c:tiles()) do
        local t = Views.TILES[key]
        if t then
            table.insert(items, { icon = t.icon, title = t.title, right = key == "today" and tostring(s.today + s.overdue) or nil,
                view = { kind = key }, on = c.screen.kind == key })
        end
    end
    local hidden = c:hiddenSet()
    for __, l in ipairs(c:orderedLists()) do
        if not hidden[l.id] then
            local open = Model.counts(l, today)
            table.insert(items, { icon = "list", title = l.name, right = open > 0 and tostring(open) or nil,
                view = { kind = "list", listId = l.id },
                on = c.screen.listId == l.id and (c.screen.kind == "list" or c.screen.kind == "task") })
        end
    end
    p:rect(0, 0, W, H, WHITE)
    p:rect(W - 1, 0, 1.2, H, BLACK)
    p:text(14, 28, _("To Do"), 15, true, BLACK, "start", W - 28)
    zone(0, 0, W, 44, function() c.stack, c.screen = {}, { kind = "home" } c:render(2) end)
    p:hline(0, 44, W, BLACK, 1.2)
    local rh, top = 40, 45
    local per = math.max(1, math.floor((H - top - 40) / rh))
    local pages = math.max(1, math.ceil(#items / per))
    c.panePage = math.max(1, math.min(c.panePage or 1, pages))
    local first = (c.panePage - 1) * per
    for k = 1, per do
        local it = items[first + k]
        if not it then break end
        local y = top + (k - 1) * rh
        if it.on then p:rect(0, y + 6, 4, rh - 12, BLACK) end
        p:icon(it.icon, 14, y + 11, 18)
        local rw = it.right and p:text(W - 14, y + 26, it.right, 11, false, GREY, "end") or 0
        p:text(42, y + 26, it.title, 12.5, it.on, BLACK, "start", W - 42 - rw - 22)
        p:hline(42, y + rh - 1, W - 42, LINE, 0.6)
        zone(0, y, W, rh, function() c:openFromPane(it.view) end)
    end
    if pages > 1 then
        local y = H - 34
        p:icon("chevron-left", W / 2 - 50, y + 9, 16)
        p:text(W / 2, y + 22, c.panePage .. " / " .. pages, 11, true, BLACK, "middle")
        p:icon("chevron-right", W / 2 + 34, y + 9, 16)
        zone(0, y, W / 2, 34, function() c.panePage = math.max(1, c.panePage - 1) c:render() end)
        zone(W / 2, y, W / 2, 34, function() c.panePage = math.min(pages, c.panePage + 1) c:render() end)
    end
end

-- ------------------------------------------------------------------ home

local TILES = {
    today = { icon = "sun", title = _("Today") },
    agenda = { icon = "calendar-days", title = _("Agenda") },
    starred = { icon = "star", title = _("Starred") },
    calendar = { icon = "calendar", title = _("Calendar") },
    search = { icon = "search", title = _("Search") },
}
Views.TILES = TILES

--- Each Home tile's line, from Model.summary: "3 due · 1 overdue", "5 in the next 7 days"...
function Views.tileLines(s, today)
    return {
        today = s.overdue > 0 and T(_("%1 due · %2 overdue"), s.today, s.overdue) or T(_("%1 due"), s.today),
        agenda = T(_("%1 in the next 7 days"), s.week),
        starred = s.starred == 1 and _("1 task") or T(_("%1 tasks"), s.starred),
        calendar = Dates.MONTH_NAMES[select(2, Dates.toCivil(today))],
        search = _("Titles, notes and steps"),
    }
end

function Views.home(c, view)
    local today = c:today()
    local rows = {}
    if not c:usable() then
        table.insert(rows, { h = 70, draw = function(p, y, zone, W)
            p:text(14, y + 30, _("Sign in to see your tasks."), 13, false, BLACK)
            p:text(14, y + 52, _("A short code is shown: enter it on a phone or computer."), 10, false, GREY, "start", W - 28)
        end })
        table.insert(rows, Views.settingRow(_("Sign in to Microsoft To Do"), "", nil, function() c:signIn() end))
        table.insert(rows, Views.settingRow(_("App ID"), c.api.clientId and _("Set") or _("Not set"), nil, function() c:editClientId() end))
        table.insert(rows, Views.settingRow(_("Settings"), "", nil, function() c:open({ kind = "settings" }) end))
    else
        local lists = c.store:lists()
        local hidden = c:hiddenSet()
        local s = Model.summary(lists, today, { hidden = hidden })
        table.insert(rows, { h = 30, draw = function(p, y, zone, W)
            p:text(14, y + 21, Dates.long(today), 11, false, GREY)
        end })
        local tiles = c:tiles()
        if #tiles > 0 then
            local subs = Views.tileLines(s, today)
            local n = math.ceil(#tiles / 2)
            table.insert(rows, { h = n * 62 + 4, draw = function(p, y, zone, W)
                local tw = (W - 38) / 2
                for i, key in ipairs(tiles) do
                    local t = TILES[key]
                    local x, ty = 14 + ((i - 1) % 2) * (tw + 10), y + 6 + math.floor((i - 1) / 2) * 62
                    p:rect(x, ty, tw, 52, WHITE, 8)
                    p:frame(x, ty, tw, 52, 1, BLACK, 8)
                    p:icon(t.icon, x + 12, ty + 10, 18)
                    p:text(x + 40, ty + 23, t.title, 12.5, true, BLACK, "start", tw - 50)
                    p:text(x + 40, ty + 40, subs[key], 9.5, false, GREY, "start", tw - 50)
                    zone(x, ty, tw, 52, function() c:openTile(key) end, function() c:tileMenu(key) end)
                end
            end })
        end
        local pinned = c:opt("pinned_list")
        -- To Do's lists, then the ones on this Kindle (each heading's + makes one there).
        local mine, kindle = {}, {}
        for __, list in ipairs(c:orderedLists()) do table.insert(list.isLocal and kindle or mine, list) end
        local sections = {}
        if c.api:signedIn() then table.insert(sections, { _("LISTS"), mine, function() c:newList(false) end }) end
        if c:opt("local_lists") then table.insert(sections, { _("ON THIS KINDLE"), kindle, function() c:newList(true) end }) end
        for __, sec in ipairs(sections) do
            table.insert(rows, Views.labelRow(sec[1], nil, sec[3]))
            for __, list in ipairs(sec[2]) do
                local open, overdue, dueToday = Model.counts(list, today)
                local flag = overdue > 0 and T(_("%1 overdue"), overdue) or (dueToday > 0 and T(_("%1 today"), dueToday)) or nil
                local isHidden = hidden[list.id]
                table.insert(rows, { h = 38, draw = function(p, y, zone, W)
                    p:icon(list.id == pinned and "pin" or (isHidden and "eye-off" or "list"), 14, y + 11, 15)
                    p:text(40, y + 24, list.name, 12, false, isHidden and MID or BLACK, "start", W - 200)
                    if flag then p:text(W - 50, y + 24, flag, 9.5, true, BLACK, "end") end
                    p:text(W - 14, y + 24, tostring(open), 11, false, GREY, "end")
                    p:hline(40, y + 38, W - 40, LINE)
                    zone(0, y, W, 38, function() c:open({ kind = "list", listId = list.id }) end,
                        function() c:listMenu(list) end)
                end })
            end
        end
        if not c.api:signedIn() then
            table.insert(rows, Views.settingRow(_("Sign in to Microsoft To Do"), "", nil, function() c:signIn() end,
                _("To sync your lists with To Do on your phone and computer.")))
        end
        local deletedLists = #c.store:deletedLists()
        if deletedLists > 0 then
            table.insert(rows, Views.deletedRow(T(_("Deleted lists (%1)"), deletedLists), function() c:showDeletedLists() end))
        end
    end
    return {
        title = _("To Do"),
        right = {
            { icon = "search", fn = function() c:askSearch() end },
        },
        left = { icon = "chevron-left", fn = function() c:back() end },
        rows = rows,
        reserve = c:usable() and 52 or 0,
        after = c:usable() and function(p, zone, W, H)
            p:circle(W - 40, H - 70, 22, BLACK)
            p:icon("plus", W - 51, H - 81, 22, true)
            zone(W - 64, H - 94, 48, 48, function() c:addTask({}) end)
        end or nil,
    }
end

-- ------------------------------------------------------------------ task lists

local function sectionRows(c, sections, opts)
    local rows = {}
    for __, s in ipairs(sections) do
        table.insert(rows, Views.bandRow(s.title, tostring(#s.entries)))
        for __, e in ipairs(s.entries) do table.insert(rows, Views.taskRow(c, e, opts)) end
    end
    return rows
end

--- The sections as they'll be drawn: with Keep rows in place, a task ticked,
-- starred or given a new date stays where it was (up to date) until the screen
-- is left or refreshed (the launcher's PS.stable; without it, as sorted).
local function keepOrder(c, view, sections)
    local stable = require("pluginshare").stable
    if not stable then return sections end
    return stable.order(view, sections, { on = c:opt("stable_lists"),
        id = function(e) return e.task.id end,
        fresh = function(e)
            local list = c.store:findList(e.list.id)
            local task = list and c.store:findTask(list.id, e.task.id)
            if not task or task.deleted then return nil end
            local out = {}
            for k, v in pairs(e) do out[k] = v end
            out.list, out.task = list, task
            return out
        end })
end

local function listMenuIcons(c, view, add)
    local icons = {
        { icon = "ellipsis-vertical", fn = function() c:viewMenu(view) end },
        { icon = "plus", fn = add },
        { icon = "search", fn = function() c:askSearch() end },
    }
    -- With Keep rows in place: sort the rows again now (no sync), beside ⟳.
    if c:opt("stable_lists") and require("pluginshare").stable then
        table.insert(icons, 2, { icon = "arrow-up-down", fn = function() c:sortAgain() c:render() end })
    end
    return icons
end

function Views.agenda(c, view)
    local today = c:today()
    local sections = Model.agenda(c.store:lists(), today, c:offset(), {
        todayOnly = view.kind == "today", starredFirst = c:opt("starred_first"), hidden = c:hiddenSet() })
    local rows = sectionRows(c, keepOrder(c, view, sections), { withList = true, agenda = true })
    if #rows == 0 then
        table.insert(rows, Views.messageRow(view.kind == "today" and _("Nothing due today.") or _("Nothing due this week.")))
    end
    return {
        title = view.kind == "today" and _("Today") or _("Agenda"),
        left = { icon = "chevron-left", fn = function() c:back() end },
        right = listMenuIcons(c, view, function() c:addTask({ due = today }) end),
        rows = rows,
    }
end

function Views.starred(c, view)
    local today = c:today()
    local entries = Model.starred(c.store:lists(), { hidden = c:hiddenSet() })
    local rows = sectionRows(c, keepOrder(c, view, Model.groupByDue(entries, today, c:offset(), false)), { withList = true, starZone = true })
    if #rows == 0 then table.insert(rows, Views.messageRow(_("No starred tasks."))) end
    return {
        title = _("Starred"),
        left = { icon = "chevron-left", fn = function() c:back() end },
        right = listMenuIcons(c, view, function() c:addTask({ important = true }) end),
        rows = rows,
    }
end

function Views.list(c, view)
    local list = c.store:findList(view.listId)
    if not list then return nil end
    local today = c:today()
    local entries = Model.listEntries(list)
    local rows
    if c:opt("group_by_due") then
        rows = sectionRows(c, keepOrder(c, view, Model.groupByDue(entries, today, c:offset(), c:opt("starred_first"))), { starZone = true })
    else
        rows = {}
        for __, s in ipairs(keepOrder(c, view, { { entries = Model.sortEntries(entries, c:offset(), c:opt("starred_first")) } })) do
            for __, e in ipairs(s.entries) do table.insert(rows, Views.taskRow(c, e, { starZone = true })) end
        end
    end
    if #rows == 0 then table.insert(rows, Views.messageRow(_("Nothing to do here."))) end
    local completed = #c.store:completedTasks(list.id)
    if completed > 0 then table.insert(rows, Views.deletedRow(T(_("Completed (%1)"), completed), function() c:showCompleted(list.id) end, "check", _("Not done"))) end
    local deleted = #c.store:deletedTasks(list.id)
    if deleted > 0 then table.insert(rows, Views.deletedRow(T(_("Deleted (%1)"), deleted), function() c:showDeleted(list.id) end)) end
    return {
        title = list.name,
        left = { icon = "chevron-left", fn = function() c:back() end },
        right = listMenuIcons(c, view, function() c:addTask({ listId = list.id }) end),
        rows = rows,
    }
end

function Views.search(c, view)
    local rows = {}
    for __, e in ipairs(Model.sortEntries(Model.search(c.store:lists(), view.query), c:offset(), false)) do
        table.insert(rows, Views.taskRow(c, e, { withList = true, showDate = true }))
    end
    if #rows == 0 then table.insert(rows, Views.messageRow(T(_("Nothing found for “%1”."), view.query))) end
    return {
        title = T(_("Search: %1"), view.query),
        left = { icon = "chevron-left", fn = function() c:back() end },
        right = { { icon = "search", fn = function() c:askSearch(view.query) end } },
        rows = rows,
    }
end

-- ------------------------------------------------------------------ a task

function Views.task(c, view)
    local list = c.store:findList(view.listId)
    local task = list and c.store:findTask(view.listId, view.taskId)
    if not task then return nil end
    local today, offset = c:today(), c:offset()
    local e = { list = list, task = task }
    local rows = {}
    local W = Views.width()
    local titleLines = UI.wrap(task.title, 17, true, W - 46 - 50, 3)
    table.insert(rows, { h = 26 + 22 * #titleLines, draw = function(p, y, zone)
        if task.completed then
            p:rect(14, y + 14, 20, 20, BLACK, 4)
            p:icon("check", 17, y + 17, 14, true)
        else
            p:rect(14, y + 14, 20, 20, WHITE, 4)
            p:frame(14, y + 14, 20, 20, 1.4, BLACK, 4)
        end
        for i, l in ipairs(titleLines) do
            p:text(46, y + 8 + 22 * i, l, 17, true, task.completed and MID or BLACK)
        end
        p:icon(task.important and "star-filled" or "star", W - 36, y + 14, 20)
        zone(46, y, W - 100, 26 + 22 * #titleLines, function() c:renameTask(list, task) end)
        zone(0, y, 46, 50, function() c:toggleDone(list, task) end)
        zone(W - 50, y, 50, 50, function() c:toggleStar(list, task) end)
    end })
    table.insert(rows, Views.labelRow(_("WHEN")))
    local minute = Dates.reminderMinute(task, offset)
    local remindText = _("None")
    if minute then
        remindText = Dates.clock(minute)
    elseif task.remindAt then
        local l = task.remindAt + offset
        remindText = Dates.short(math.floor(l / 86400)) .. "  " .. Dates.clock(math.floor(l % 86400 / 60))
    end
    local function whenRow(icon, text, value, tap, hold)
        return { h = 36, draw = function(p, y, zone)
            p:icon(icon, 14, y + 10, 16)
            p:text(40, y + 23, text, 12, false, BLACK)
            p:text(W - 32, y + 23, value, 12, value ~= _("None"), value == _("None") and MID or BLACK, "end", W - 160)
            chevron(p, W, y)
            p:hline(40, y + 36, W - 40, LINE)
            zone(0, y, W, 36, tap, hold)
        end }
    end
    table.insert(rows, whenRow("calendar", _("Due"), task.due and Dates.short(task.due) or _("None"),
        function() c:dueMenu(list, task) end, function() c:clearDue(list, task) end))
    table.insert(rows, whenRow("bell", _("Reminder"), remindText,
        function() c:reminderMenu(list, task) end, function() c:clearReminder(list, task) end))
    table.insert(rows, whenRow("repeat", _("Repeat"), task.recurring and Model.repeatText(task.recurrence) or _("None"),
        function() c:repeatMenu(list, task) end))
    -- Chips: what moves the date.
    local chips = {}
    if Model.canSkip(task, today) then
        table.insert(chips, { "skip-forward", _("Skip to current"), function() c:skipToCurrent(list, task) end })
    end
    table.insert(chips, { "calendar-clock", T(_("Postpone %1 days"), c:opt("push_days")), function() c:pushOff(list, task, c:opt("push_days")) end,
        function() c:pushOffMenu(list, task) end })
    if task.due ~= today then
        table.insert(chips, { "sun", _("Due today"), function() c:setDue(list, task, today) end })
    end
    if task.recurring then
        table.insert(chips, { "x", _("Remove repeat"), function() c:removeRepeat(list, task) end })
    end
    local placed, x, line = {}, 14, 0
    for __, chip in ipairs(chips) do
        local w = 34 + UI.textWidth(chip[2], 10.5, false)
        if x + w > W - 14 and x > 14 then
            x, line = 14, line + 1
        end
        table.insert(placed, { chip = chip, x = x, line = line, w = w })
        x = x + w + 8
    end
    table.insert(rows, { h = 12 + 36 * (line + 1), draw = function(p, y, zone)
        for __, pl in ipairs(placed) do
            local cy = y + 10 + pl.line * 36
            p:rect(pl.x, cy, pl.w, 28, WHITE, 14)
            p:frame(pl.x, cy, pl.w, 28, 1, BLACK, 14)
            p:icon(pl.chip[1], pl.x + 10, cy + 7, 14)
            p:text(pl.x + 28, cy + 18.5, pl.chip[2], 10.5, false, BLACK)
            zone(pl.x, cy - 4, pl.w, 36, pl.chip[3], pl.chip[4])
        end
    end })
    -- Made from a page in Notes: back to that page.
    local where = c:notesPage(task.id)
    if where then
        table.insert(rows, { h = 40, draw = function(p, y, zone)
            p:icon("notebook-text", 14, y + 12, 16)
            p:text(40, y + 25, T(_("Open in Notes: %1, page %2"), where.name or "", where.page or 1), 12, false, BLACK, "start", W - 70)
            chevron(p, W, y + 2)
            p:hline(40, y + 40, W - 40, LINE)
            zone(0, y, W, 40, function() c.ui.notes:open(where.id, where.page) end)
        end })
    end
    -- Steps.
    local done = 0
    for __, s in ipairs(task.steps) do done = done + (s.checked and 1 or 0) end
    table.insert(rows, Views.labelRow(_("STEPS"), #task.steps > 0 and T(_("%1 of %2"), done, #task.steps) or nil))
    for __, step in ipairs(task.steps) do
        table.insert(rows, { h = 32, draw = function(p, y, zone)
            if step.checked then
                p:circle(22, y + 16, 7.5, BLACK)
                p:icon("check", 17, y + 11, 10, true)
                local w = p:text(40, y + 20, step.title, 11.5, false, MID, "start", W - 60)
                p:hline(40, y + 16, w, MID, 0.8)
            else
                p:circle(22, y + 16, 7.5, BLACK, 1.2)
                p:text(40, y + 20, step.title, 11.5, false, BLACK, "start", W - 60)
            end
            p:hline(40, y + 32, W - 40, LINE)
            zone(0, y, W, 32, function() c:stepMenu(list, task, step) end, function() c:stepMenu(list, task, step) end)
            zone(0, y, 40, 32, function() c:toggleStep(list, task, step) end)
        end })
    end
    table.insert(rows, { h = 36, draw = function(p, y, zone)
        p:icon("plus", 15, y + 10, 15)
        p:text(40, y + 22, _("Add step"), 11.5, true, BLACK)
        zone(0, y, W, 36, function() c:addStep(list, task) end)
    end })
    -- Notes.
    table.insert(rows, Views.labelRow(_("NOTES")))
    local noteLines = task.notes and UI.wrap(task.notes, 11.5, false, W - 52, 8) or nil
    local boxH = noteLines and (14 + 18 * #noteLines) or 44
    table.insert(rows, { h = boxH + 16, draw = function(p, y, zone)
        p:frame(14, y + 4, W - 28, boxH, 1, LIGHT, 6)
        if noteLines then
            for i, l in ipairs(noteLines) do p:text(24, y + 4 + 18 * i, l, 11.5, false, BLACK) end
        else
            p:text(24, y + 30, _("Add note"), 11.5, false, MID)
        end
        zone(14, y + 4, W - 28, boxH, function() c:editNotes(list, task) end)
    end })
    local private = c.store:isPrivate(task.id)
    return {
        title = list.name,
        left = { icon = "chevron-left", fn = function() c:back() end },
        right = { { icon = "ellipsis-vertical", fn = function() c:holdTask(list, task, true) end } },
        rows = rows,
        bottomH = 52,
        bottom = function(p, zone, BW, H)
            local y = H - 52
            p:rect(0, y, BW, 52, WHITE)
            p:hline(0, y, BW, BLACK, 1)
            local buttons = {
                { "arrow-right", _("Move to list"), function() c:moveMenu(list, task) end },
                { private and "eye" or "eye-off", private and _("Show on sleep") or _("Hide on sleep"), function() c:togglePrivate(task) end },
                { "trash-2", _("Delete"), function() c:deleteTask(list, task) end },
            }
            if (view.pages or 1) > 1 then
                table.insert(buttons, 1, { "chevron-down", T(_("Page %1/%2"), view.page, view.pages), function() c:turnPage(1, true) end })
            end
            local n = #buttons
            for i, b in ipairs(buttons) do
                local cx = BW * (2 * i - 1) / (2 * n)
                p:icon(b[1], cx - 9, y + 8, 18)
                p:text(cx, y + 42, b[2], 9.5, false, BLACK, "middle", BW / n - 8)
                zone(cx - BW / (2 * n), y, BW / n, 52, b[3])
            end
        end,
    }
end

-- ------------------------------------------------------------------ calendar

function Views.calendar(c, view)
    local today = c:today()
    local ty, tm = Dates.toCivil(today)
    view.y, view.m = view.y or ty, view.m or tm
    local cal = Model.calendar(c.store:lists(), view.y, view.m, today, c:offset(),
        { hidden = c:hiddenSet(), starredFirst = c:opt("starred_first") })
    local monday = c:opt("week_start") == "monday"
    local firstCol = (Dates.weekdayIndex(cal.first) - (monday and 1 or 0)) % 7
    local daysInMonth = cal.last - cal.first + 1
    local weeks = math.ceil((firstCol + daysInMonth) / 7)
    view.sel = view.sel and math.min(view.sel, daysInMonth) or (view.y == ty and view.m == tm and select(3, Dates.toCivil(today)) or 1)
    local rows = {}
    local W = Views.width()
    local cw = (W - 28) / 7
    table.insert(rows, { h = 26 + weeks * 54, draw = function(p, y, zone)
        local names = monday and { "M", "T", "W", "T", "F", "S", "S" } or { "S", "M", "T", "W", "T", "F", "S" }
        for i, n in ipairs(names) do p:text(14 + cw * (i - 1) + cw / 2, y + 17, n, 9.5, true, GREY, "middle") end
        local gy = y + 24
        for r = 0, weeks do p:hline(14, gy + r * 54, W - 28, LINE, 0.6) end
        for col = 0, 7 do p:vline(14 + col * cw, gy, weeks * 54, LINE, 0.6) end
        for d = 1, daysInMonth do
            local k = firstCol + d - 1
            local x, cy = 14 + (k % 7) * cw, gy + math.floor(k / 7) * 54
            local day = cal.first + d - 1
            if day == today then
                p:circle(x + 14, cy + 14, 10, BLACK)
                p:text(x + 14, cy + 18, tostring(d), 11, true, WHITE, "middle")
            else
                p:text(x + 14, cy + 18, tostring(d), 11, day > today, day < today and MID or BLACK, "middle")
            end
            if d == view.sel then p:frame(x + 1.5, cy + 1.5, cw - 3, 51, 2, BLACK) end
            local entries = cal.days[d] or {}
            for j = 1, math.min(#entries, 3) do
                local overdue = entries[j].task.due < today and not entries[j]["repeat"]
                if overdue then
                    p:circle(x + 10 + (j - 1) * 8, cy + 40, 3, BLACK, 1)
                else
                    p:circle(x + 10 + (j - 1) * 8, cy + 40, 3, BLACK)
                end
            end
            if #entries > 3 then p:text(x + 34, cy + 43, "+" .. (#entries - 3), 9, true, BLACK) end
            zone(x, cy, cw, 54, function() view.sel = d c:render() end, function() c:addTask({ due = day }) end)
        end
    end })
    if #cal.frequent > 0 then
        local names = {}
        for __, e in ipairs(cal.frequent) do table.insert(names, e.task.title) end
        table.insert(rows, { h = 26, draw = function(p, y)
            p:icon("repeat", 14, y + 9, 11)
            p:text(30, y + 18, T(_("Every day or two: %1"), table.concat(names, ", ")), 9.5, false, GREY, "start", W - 44)
        end })
    end
    local selDay = cal.first + view.sel - 1
    local entries = cal.days[view.sel] or {}
    table.insert(rows, Views.bandRow(Dates.short(selDay):upper(), #entries == 1 and _("1 task") or T(_("%1 tasks"), #entries)))
    for __, e in ipairs(entries) do table.insert(rows, Views.taskRow(c, e, { withList = true })) end
    if #entries == 0 then
        table.insert(rows, Views.messageRow(_("Nothing due. Hold a day to add a task.")))
    else
        table.insert(rows, { h = 28, draw = function(p, y)
            p:text(14, y + 20, _("Hollow dot: overdue. Tap a day for its tasks; hold a day to add one."), 9.5, false, MID, "start", W - 28)
        end })
    end
    local function month(n)
        view.y, view.m = Dates.addMonths(view.y, view.m, n)
        view.sel, view.page = 1, 1
        if view.y == ty and view.m == tm then view.sel = select(3, Dates.toCivil(today)) end
        c:render()
    end
    view.monthSwipe = month
    return {
        title = Dates.MONTH_NAMES[view.m] .. " " .. view.y,
        left = { icon = "chevron-left", fn = function() c:back() end },
        right = { { icon = "chevron-right", fn = function() month(1) end }, { icon = "chevron-left", fn = function() month(-1) end } },
        rows = rows,
    }
end

-- ------------------------------------------------------------------ sync

local KIND_ICON = {
    add = "plus", done = "square-check", star = "star", due = "calendar", remind = "bell", repeats = "repeat",
    norepeat = "x", rename = "pencil", notes = "notebook-text", stepAdd = "list-checks", stepCheck = "list-checks",
    stepRename = "list-checks", stepDelete = "list-checks", move = "arrow-right", delete = "trash-2",
    listAdd = "list-plus", listRename = "pencil", listDelete = "trash-2",
}

function Views.sync(c, view)
    local rows = {}
    local W = Views.width()
    local interval = c:opt("sync_interval")
    local synced = c.store:syncedAt()
    table.insert(rows, { h = 66, draw = function(p, y, zone)
        p:frame(14, y + 8, W - 28, 52, 1, BLACK, 8)
        p:icon("refresh-cw", 26, y + 24, 20)
        p:text(58, y + 30, synced and T(_("Last sync %1"), c:ago(synced)) or _("Not synced yet"), 12.5, true, BLACK, "start", W - 90)
        local sub = interval > 0 and T(_("Every %1 min while KOReader is open and Wi-Fi is on"), interval)
            or _("Only when you sync")
        p:text(58, y + 47, sub, 9.5, false, GREY, "start", W - 90)
        zone(14, y + 8, W - 28, 52, function() c:syncNow() end)
    end })
    local queue = c.store.data.queue
    table.insert(rows, Views.labelRow(_("CHANGES TO SEND"), #queue > 0 and tostring(#queue) or nil))
    if #queue == 0 then
        table.insert(rows, { h = 36, draw = function(p, y)
            p:text(40, y + 23, _("Nothing to send. A sync only downloads."), 11.5, false, MID)
        end })
    end
    for __, op in ipairs(queue) do
        local kind, what = Store.describe(op)
        table.insert(rows, { h = 36, draw = function(p, y)
            p:icon(KIND_ICON[op.kind] or "pencil", 14, y + 10, 16)
            local w = p:text(40, y + 23, kind, 11.5, true, BLACK, "start", 160)
            p:text(math.max(150, 48 + w), y + 23, what, 11.5, false, BLACK, "start", W - math.max(150, 48 + w) - 14)
            p:hline(40, y + 36, W - 40, LINE)
        end })
    end
    local downloadOnly = c:opt("download_only")
    table.insert(rows, { h = 54, draw = function(p, y, zone)
        p:rect(14, y + 10, W - 28, 40, BLACK, 8)
        p:text(W / 2, y + 35, downloadOnly and _("Download now") or _("Sync now"), 12.5, true, WHITE, "middle")
        zone(14, y + 10, W - 28, 40, function() c:syncNow() end)
    end })
    table.insert(rows, { h = 48, draw = function(p, y, zone)
        local hw = (W - 38) / 2
        local buttons = {
            { _("Download only"), function() c:syncNow({ downloadOnly = true }) end },
            { _("Preview changes"), function() c:previewFromTodo() end },
        }
        for i, b in ipairs(buttons) do
            local x = 14 + (i - 1) * (hw + 10)
            p:frame(x, y + 6, hw, 36, 1, BLACK, 8)
            p:text(x + hw / 2, y + 29, b[1], 11.5, false, BLACK, "middle", hw - 10)
            zone(x, y + 6, hw, 36, b[2])
        end
    end })
    table.insert(rows, { h = 52, draw = function(p, y, zone)
        p:icon("rotate-ccw", 14, y + 10, 15)
        p:text(38, y + 22, _("Reset to To Do"), 11.5, true, BLACK)
        p:text(38, y + 38, #queue > 0 and T(_("Throws away the reader's %1 unsent changes"), #queue)
            or _("Downloads To Do's copy again"), 9.5, false, GREY, "start", W - 52)
        zone(0, y, W, 52, function() c:resetToTodo() end)
    end })
    local behind = #c.store:catchUpPreview(c:today())
    table.insert(rows, Views.labelRow(_("SYNC SETTINGS")))
    table.insert(rows, Views.settingRow(_("Background sync"), interval > 0 and T(_("Every %1 min"), interval) or _("Off"), nil,
        function() c:chooseInterval() end))
    table.insert(rows, Views.settingRow(_("Sync changes immediately"), nil, c:opt("send_now"), function() c:flip("send_now") end))
    if c:opt("send_now") then
        table.insert(rows, Views.settingRow(_("Send changes"), c.sendDelayName(c:opt("send_delay")), nil, function() c:chooseSendDelay() end))
    end
    table.insert(rows, Views.settingRow(_("Download only"), nil, downloadOnly, function() c:flip("download_only") end))
    table.insert(rows, Views.settingRow(_("Catch up overdue repeats"), behind == 1 and _("1 task") or T(_("%1 tasks"), behind), nil,
        function() c:catchUp() end))
    table.insert(rows, Views.settingRow(_("All settings"), "", nil, function() c:open({ kind = "settings" }) end))
    return {
        title = _("Sync"),
        left = { icon = "chevron-left", fn = function() c:back() end },
        rows = rows,
    }
end

-- ------------------------------------------------------------------ settings

function Views.settings(c, view)
    if c.settingsJump then view.jump, c.settingsJump = c.settingsJump, nil end
    local rows = {}
    local function add(r) table.insert(rows, r) end
    local function nameOf(id)
        local l = id and c.store:findList(id)
        return l and l.name or _("None")
    end
    local hiddenCount = 0
    for __ in pairs(c:hiddenSet()) do hiddenCount = hiddenCount + 1 end
    -- As every app's settings: Display first, then To Do's own, the account
    -- last. (Light, night mode and a screen refresh are in ⋮.)
    local KO = require("todoko")
    add(Views.settingsHeading(_("DISPLAY")))
    add(Views.settingRow(_("Week starts on"), c:opt("week_start") == "monday" and _("Monday") or _("Sunday"), nil,
        function() c:flipWeekStart() end))
    add(Views.settingRow(_("Split view (landscape)"), nil, c:opt("two_panes"), function() c:flip("two_panes") end))
    add(Views.settingRow(_("Full refresh"), c.DEGHOST[c:opt("deghost")] or c.DEGHOST[6], nil, function() c:chooseDeghost() end))
    add(Views.settingsHeading(_("HOME")))
    add(Views.settingRow(_("Home tiles"), T(_("%1 shown"), #c:tiles()), nil, function() c:editTiles() end))
    add(Views.settingRow(_("Lists"), hiddenCount > 0 and T(_("%1 hidden"), hiddenCount) or _("All shown"), nil,
        function() c:editListOrder() end))
    add(Views.settingRow(_("Show hidden lists"), nil, c:opt("show_hidden"), function() c:flip("show_hidden") end))
    add(Views.settingRow(_("Pinned list"), nameOf(c:opt("pinned_list")), nil, function() c:chooseList("pinned_list", true) end))
    add(Views.settingRow(_("Default list"), nameOf(c:defaultListId()), nil, function() c:chooseList("default_list") end))
    add(Views.settingsHeading(_("TASKS")))
    add(Views.settingRow(_("Starred on top"), nil, c:opt("starred_first"), function() c:flip("starred_first") end))
    add(Views.settingRow(_("Group by due date"), nil, c:opt("group_by_due"), function() c:flip("group_by_due") end))
    add(Views.settingRow(_("Keep rows in place"), nil, c:opt("stable_lists"), function() c:flip("stable_lists") end,
        _("After you tick, star or reschedule a task, it stays where it is until you leave the screen or refresh it.")))
    add(Views.settingRow(_("Tap action"), c:opt("tap_opens") == "menu" and _("Quick actions") or _("Open task"), nil,
        function() c:chooseTap() end))
    add(Views.settingRow(_("Postpone by"), T(_("%1 days"), c:opt("push_days")), nil, function() c:choosePushDays() end))
    add(Views.settingRow(_("Reminder alerts"), nil, c:opt("reminders"), function() c:flip("reminders") end))
    add(Views.settingRow(_("Lists on this Kindle"), nil, c:opt("local_lists"), function() c:flip("local_lists") end,
        _("Lists kept only here, never synced. Off hides them (they're kept).")))
    add(Views.settingsHeading(_("SYNC")))
    add(Views.settingRow(_("Background sync"), c:opt("sync_interval") > 0 and T(_("Every %1 min"), c:opt("sync_interval")) or _("Off"),
        nil, function() c:chooseInterval() end))
    add(Views.settingRow(_("Sync changes immediately"), nil, c:opt("send_now"), function() c:flip("send_now") end))
    if c:opt("send_now") then
        add(Views.settingRow(_("Send changes"), c.sendDelayName(c:opt("send_delay")), nil, function() c:chooseSendDelay() end))
    end
    add(Views.settingRow(_("Download only"), nil, c:opt("download_only"), function() c:flip("download_only") end))
    add(Views.settingsHeading(_("SLEEP SCREEN")))
    -- Which sleep screen, and how often it's drawn again, are the launcher's
    -- (one for every app); here only without it.
    local PS = require("pluginshare")
    local supported = c:sleepSupported()
    if PS.showSleepSettings then
        add(Views.settingRow(_("Sleep screen"), _("Launcher settings"), nil, function() PS.showSleepSettings() end))
    else
        add(Views.settingRow(_("Sleep screen"), supported and c:sleepSourceName() or _("Not on this device"), nil,
            function() c:chooseSleepScreen() end,
            not supported and _("Not on this device: KOReader does not draw its sleep screen here") or nil))
    end
    local shows = { today_next = _("Today + Up next"), today = _("Today"), starred = _("Starred"), pinned = _("Pinned list") }
    add(Views.settingRow(_("Sleep screen content"), shows[c:opt("sleep_content")] or shows.today_next, nil, function() c:chooseSleepContent() end))
    if not PS.showSleepSettings then
        add(Views.settingRow(_("Sleep screen updates"), KO.sleepUpdateName(KO.sleepMinutes()), nil, function() c:chooseSleepUpdate() end))
    end
    add(Views.settingsHeading(_("ACCOUNT")))
    if c.api.account then
        -- The shared Microsoft account (Settings > Microsoft): App ID, sign-in and sign-out there.
        local who = c.api.account.account()
        local value = c.api:signedIn() and (who or _("Signed in"))
            or c.api.account.signedIn() and _("Sign in again to allow To Do") or _("Not signed in")
        add(Views.settingRow(_("Microsoft account"), value, nil,
            function() c.api.account.showSettings() end))
    elseif c.api:signedIn() then
        add(Views.settingRow(_("Signed in"), _("Microsoft account"), nil, nil))
        add(Views.settingRow(_("Sign out"), "", nil, function() c:signOut() end))
    else
        add(Views.settingRow(_("Sign in to Microsoft To Do"), "", nil, function() c:signIn() end))
    end
    if not c.api.account then
        add(Views.settingRow(_("App ID"), c.api.clientId and (c.api.clientId:sub(1, 8) .. "…") or _("Not set"), nil, function() c:editClientId() end))
    end
    if PS.showConnectionTest and (c.api.clientId or c.api:signedIn()) then
        add(Views.settingRow(_("Test connection"), _("Microsoft"), nil, function() PS.showConnectionTest("todo") end))
    end
    return {
        title = _("To Do settings"),
        left = { icon = "chevron-left", fn = function() c:back() end },
        rows = rows,
        -- Full screen to the bottom, the page count in the title bar.
        pagerTop = true, bottomH = 8, bottom = function() end,
    }
end

-- ------------------------------------------------------------------ hold popup

--- The quick actions for a task, drawn as a popup.
--- `onTask`: from the task's own screen (its ⋮): Settings at the bottom, not Open.
function Views.holdPopup(c, list, task, close, onTask)
    return function(p, zone)
        local W, H = UI.size()
        local w = math.min(440, W - 40)
        local today = c:today()
        local buttons = {
            { "check", task.completed and _("Not done") or _("Done"), function() close() c:toggleDone(list, task) end },
            { task.important and "star-filled" or "star", task.important and _("Unstar") or _("Star"), function() close() c:toggleStar(list, task) end },
            { "sun", _("Due today"), function() close() c:setDue(list, task, today) end },
            { "sunrise", _("Tomorrow"), function() close() c:setDue(list, task, today + 1) end },
            Model.canSkip(task, today) and { "skip-forward", _("Skip to current"), function() close() c:skipToCurrent(list, task) end }
                or { "calendar-days", _("Pick a date…"), function() close() c:pickDue(list, task) end },
            { "calendar-clock", _("Postpone…"), function() close() c:pushOffMenu(list, task) end },
            { "arrow-right", _("Move to list"), function() close() c:moveMenu(list, task) end },
            { "trash-2", _("Delete"), function() close() c:deleteTask(list, task) end },
        }
        local h = 58 + math.ceil(#buttons / 2) * 46 + 48
        local x, y = (W - w) / 2, math.max(60, (H - h) / 2)
        -- (A tap on the box between buttons does nothing; first, as later zones win over it.)
        zone(x, y, w, h, function() end)
        p:rect(x + 4, y + 4, w, h, MID, 10)
        p:rect(x, y, w, h, WHITE, 10)
        p:frame(x, y, w, h, 1.4, BLACK, 10)
        p:text(x + 16, y + 26, task.title, 14, true, BLACK, "start", w - 32)
        local sub = Views.taskParts(c, { list = list, task = task }, { showDate = true, withList = true })
        parts(p, x + 16, y + 44, sub, x + w - 16)
        local bw = (w - 40) / 2
        for i, b in ipairs(buttons) do
            local bx, by = x + 16 + ((i - 1) % 2) * (bw + 8), y + 58 + math.floor((i - 1) / 2) * 46
            p:frame(bx, by, bw, 38, 1, BLACK, 6)
            p:icon(b[1], bx + 12, by + 11, 16)
            p:text(bx + 38, by + 24, b[2], 11.5, false, BLACK, "start", bw - 44)
            zone(bx, by, bw, 38, b[3])
        end
        local cy = y + h - 48
        p:hline(x, cy, w, LINE, 1)
        p:text(x + w / 2, cy + 31, onTask and _("Settings") or _("Open"), 12, true, BLACK, "middle")
        zone(x, cy, w, 48, function()
            close()
            if onTask then c:open({ kind = "settings" }) else c:openTask(list, task) end
        end)
    end
end

-- ------------------------------------------------------------------ sleep screen

--- The sleep screen: the date, then (by the setting) overdue, today and up
-- next, or starred, or the pinned list. Tasks hidden on sleep and hidden
-- lists are left out.
function Views.sleep(c)
    return function(p)
        local W, H = UI.size()
        local today, offset = c:today(), c:offset()
        local lists = c.store:lists()
        local hidden = c:hiddenSet()
        local s = Model.summary(lists, today, { hidden = hidden })
        p:text(28, 70, Dates.WEEKDAY_NAMES[Dates.weekdayIndex(today) + 1], 30, true, BLACK)
        local __, m, d = Dates.toCivil(today)
        p:text(28, 98, Dates.MONTH_NAMES[m] .. " " .. d, 16, false, GREY)
        p:text(W - 28, 70, T(_("%1 due today"), s.today), 13, true, BLACK, "end")
        if s.overdue > 0 then p:text(W - 28, 90, T(_("%1 overdue"), s.overdue), 13, false, BLACK, "end") end
        p:hline(28, 116, W - 56, BLACK, 2)
        local y = 140
        local bottom = H - 70
        local function visible(e) return not c.store:isPrivate(e.task.id) and not e.task.completed end
        local more = 0
        local function sectionLabel(text)
            if y + 64 > bottom then return false end
            local w = UI.textWidth(text, 10, true)
            p:rect(28, y, w + 16, 20, BLACK, 3)
            p:text(36, y + 14, text, 10, true, WHITE)
            y = y + 30
            return true
        end
        local function item(e, right)
            if y + 34 > bottom then
                more = more + 1
                return
            end
            p:rect(30, y + 2, 16, 16, WHITE, 3)
            p:frame(30, y + 2, 16, 16, 1.4, BLACK, 3)
            local rw = right and UI.textWidth(right, 13, false) or 0
            p:text(58, y + 16, e.task.title, 15, false, BLACK, "start", W - 58 - 28 - rw - 16)
            if right then p:text(W - 28, y + 16, right, 13, false, BLACK, "end") end
            y = y + 34
        end
        local function when(e)
            local minute = Dates.reminderMinute(e.task, offset)
            if e.task.due == today then return minute and Dates.clock(minute) or nil end
            local day = e.task.due and Dates.weekday(e.task.due) or nil
            if day and e.task.due > today + 6 then day = Dates.short(e.task.due) end
            if day and minute then return day .. " " .. Dates.clock(minute) end
            return day
        end
        local content = c:opt("sleep_content")
        local shown = 0
        if content == "starred" or content == "pinned" then
            local entries
            local title = _("STARRED")
            if content == "starred" then
                entries = Model.starred(lists, { hidden = hidden })
            else
                local list = c.store:findList(c:opt("pinned_list") or "") or c.store:findList(c:defaultListId() or "")
                entries = list and Model.listEntries(list) or {}
                title = list and list.name:upper() or _("NO PINNED LIST")
            end
            entries = Model.sortEntries(entries, offset, c:opt("starred_first"))
            sectionLabel(title)
            for __, e in ipairs(entries) do
                if visible(e) then
                    item(e, when(e))
                    shown = shown + 1
                end
            end
        else
            local sections = Model.agenda(lists, today, offset, { todayOnly = content == "today", hidden = hidden,
                starredFirst = c:opt("starred_first") })
            local upNext = false
            for __, sec in ipairs(sections) do
                local entries = {}
                for __, e in ipairs(sec.entries) do
                    if visible(e) then table.insert(entries, e) end
                end
                if #entries > 0 then
                    local title = sec.key == "overdue" and _("OVERDUE") or (sec.key == "today" and _("TODAY") or _("UP NEXT"))
                    local isNext = sec.key ~= "overdue" and sec.key ~= "today"
                    if not (isNext and upNext) then
                        if y > 140 then y = y + 8 end
                        if not sectionLabel(title) then
                            more = more + #entries
                            entries = {}
                        end
                        upNext = upNext or isNext
                    end
                    for __, e in ipairs(entries) do
                        item(e, sec.key == "overdue" and Dates.weekday(e.task.due) or when(e))
                        shown = shown + 1
                    end
                end
            end
        end
        if shown == 0 then p:text(W / 2, 220, _("All clear"), 18, true, BLACK, "middle") end
        if more > 0 then p:text(58, y + 10, T(_("+%1 more"), more), 12, false, GREY) end
        p:hline(28, H - 50, W - 56, BLACK, 1)
        local synced = c.store:syncedAt()
        p:text(28, H - 26, synced and T(_("Synced %1"), c:ago(synced)) or _("Not synced yet"), 11, false, GREY)
        p:text(W - 28, H - 26, _("To Do"), 11, false, GREY, "end")
    end
end

return Views
