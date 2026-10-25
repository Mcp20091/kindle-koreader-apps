--[[--
Quick buttons: the row under the launcher's clock (two rows at most, then
More ▾) and the control center (every button, groups dropped down in it).
Tap does the quick thing; hold opens what's behind it (Wi-Fi: the network
list; Continue reading: the library; a To Do list: a new task in it…).

The buttons are the launcher's setting `quick` (appsmodel.lua: Model.quickList):
built-ins (Model.QUICK_BUILTIN), shortcuts (the same pins as tiles: a Home
Assistant screen, a To Do view or list, a notebook, a Notes folder, a
crossword source, a KOReader action), other apps' buttons ({ app, id, name }:
what PluginShare.registerQuick gave, such as a Home Assistant device with
− and +, a speaker's controls or a sensor's reading) and groups of them. Settings > Launcher
> Quick buttons (the launcher's "quick" mode) edits them, and so does the web
page's Launcher tab.
]]

local Device = require("device")
local Event = require("ui/event")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("appscanvas")
local KO = require("appsko")
local Model = require("appsmodel")

local C = Canvas
local Quick = {}

-- ------------------------------------------------------------------ where things are

local function PS() return require("pluginshare") end
local function apps() local p = PS() return p.appsApps and p.appsApps() end

--- The open library or book.
local function ui()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if ReaderUI and ReaderUI.instance then return ReaderUI.instance end
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    return FileManager and FileManager.instance
end

local function plugin(name)
    local u = ui()
    return u and u[name]
end

--- The launcher, shown (opened when it isn't).
local function launcher()
    local A = apps()
    if not A then return nil end
    local v = PS().appsView and PS().appsView()
    if not (v and UIManager:isWidgetShown(v)) then
        A:show()
        v = PS().appsView and PS().appsView()
    end
    return v
end

--- A launcher screen (its mode), from anywhere.
local function screen(mode, prepare)
    local A = apps()
    if A then A:showMode(mode, prepare) end
end

local function openTile(tile)
    local v = launcher()
    if v then
        v.mode = "tiles"
        v:open(tile)
    end
end

local function event(name, arg)
    local u = ui()
    if u then u:handleEvent(Event:new(name, arg)) end
end

-- One of KOReader's settings in the launcher's list (appskosettings.lua), as a choice.
local function chooseSetting(key)
    local S = require("appskosettings")
    for __, item in ipairs(S.items()) do
        if item.key == key then
            local options = {}
            for __, o in ipairs(item.options or {}) do table.insert(options, { label = o[1], value = o[2] }) end
            return KO.choose(item.name, options, item.value, function(v)
                local msg = S.set(key, v)
                if msg then KO.toast(msg) end
            end)
        end
    end
end

-- ------------------------------------------------------------------ the buttons

local function powerd() return Device:getPowerDevice() end

-- What each built-in shows and does: label, icon, on, tap(refresh), hold(refresh).
local BUILTIN = {}

BUILTIN.wifi = function()
    local on = NetworkMgr:isWifiOn()
    return { label = _("Wi-Fi"), icon = on and "wifi" or "wifi-off", on = on,
        tap = function(done)
            if NetworkMgr:isWifiOn() then NetworkMgr:toggleWifiOff(done, true) else NetworkMgr:toggleWifiOn(done, nil, true) end
            UIManager:scheduleIn(1, done)
        end,
        -- The networks to pick from (Wi-Fi turned on first).
        hold = function() NetworkMgr:reconnectOrShowNetworkMenu(nil, true) end }
end

BUILTIN.light = function()
    local okO, on = pcall(function() return powerd():isFrontlightOn() end)
    return { label = _("Light"), icon = "sun", on = okO and on or false,
        tap = function(done) pcall(function() powerd():toggleFrontlight() end) UIManager:scheduleIn(0.5, done) end,
        hold = function() KO.light() end }
end

BUILTIN.night = function()
    return { label = _("Night mode"), icon = "moon", on = KO.nightMode(),
        tap = function(done) KO.toggleNightMode(ui()) done("full") end,
        hold = function() if PS().koreaderMenu then PS().koreaderMenu() end end }
end

BUILTIN.refresh = function()
    return { label = _("Refresh"), icon = "refresh-cw",
        tap = function() UIManager:setDirty("all", "full") end,
        hold = function() chooseSetting("refresh") end }
end

BUILTIN.web = function()
    local web = plugin("webpage")
    if not (web and web.onToggleWebPage) then return nil end
    local on = web.address and web:address() ~= ""
    return { label = _("Web server"), icon = "globe", on = on,
        -- Tap: on or off, no pop-up (the notification while it runs has the address).
        tap = function(done)
            if web:address() ~= "" then
                web:stop()
                UIManager:scheduleIn(1, done)
            else
                web:start(done)
            end
        end,
        -- Its address and QR code (started first when it isn't running).
        hold = function() if web:address() ~= "" then web:showAddress() else web:start() end end }
end

BUILTIN.awake = function()
    local CC = require("appscontrol")
    return { label = _("Keep awake"), icon = "eye", on = CC.keptAwake(),
        tap = function(done) CC.keepAwake(not CC.keptAwake()) done() end,
        hold = function() chooseSetting("sleep_after") end }
end

BUILTIN.newtask = function()
    return { label = _("New task"), icon = "plus",
        tap = function() event("AddTodoTask") end,
        hold = function() event("ShowTodo") end }
end

BUILTIN.newnote = function()
    return { label = _("New note"), icon = "notebook-pen",
        tap = function() event("NotesQuickNote") end,
        hold = function() event("ShowNotes") end }
end

BUILTIN.reading = function()
    local file = G_reader_settings:readSetting("lastfile")
    return { label = _("Continue"), icon = "book-open",
        tap = function()
            if not file then return KO.toast(_("No recent book")) end
            local v = PS().appsView and PS().appsView()
            if v and UIManager:isWidgetShown(v) then UIManager:close(v) end
            require("appsreaderbar").openBook(file)
        end,
        -- The library (the Library app when it's there and chosen).
        hold = function()
            local v = PS().appsView and PS().appsView()
            if v and UIManager:isWidgetShown(v) then UIManager:close(v) end
            local lib = PS().library
            if lib and lib.isBrowser and lib.isBrowser() then return lib.open() end
            local u = ui()
            if u and u.onHome then u:onHome() end
        end }
end

BUILTIN.weather = function()
    local A = apps()
    local W = require("appsweather")
    local w = A and W.now(A)
    return { label = w and w.temp or _("Weather"), icon = w and (w.alert and "triangle-alert" or w.icon) or "cloud-sun",
        tap = function() local v = launcher() if v then W.open(v) end end,
        hold = function() if A then W.choosePlace(A) end end }
end

BUILTIN.search = function()
    return { label = _("Search"), icon = "search",
        tap = function() local v = launcher() if v then require("appssearch").ask(v) end end }
end

BUILTIN.sleep = function()
    return { label = _("Sleep"), icon = "power",
        tap = function() UIManager:broadcastEvent(Event:new("RequestSuspend")) end,
        hold = function() chooseSetting("sleep_after") end }
end

BUILTIN.rotate = function()
    return { label = _("Rotate"), icon = "rotate-ccw",
        tap = function() event("IterateRotation") end,
        hold = function() chooseSetting("rotation") end }
end

BUILTIN.battery = function()
    local ok, pct = pcall(function() return powerd():getCapacity() end)
    return { label = ok and pct and (pct .. "%") or _("Battery"), icon = "battery-medium",
        tap = function() screen("battery") end }
end

BUILTIN.stats = function()
    local A = apps()
    local s = A and (function() local ok, r = pcall(A.readingStats, A) return ok and r end)()
    return { label = s and Model.duration(s.today) or _("Reading time"), icon = "activity",
        tap = function() screen("stats", function(v) v.statsData = nil end) end,
        hold = function()
            local u = ui()
            if u and u.statistics and u.statistics.onShowCalendarView then u.statistics:onShowCalendarView() end
        end }
end

--- What a shortcut button does: open its place; hold for its app, or a new
-- task in its To Do list.
local function pinItem(p)
    local tile = Model.pinTile(p)
    local item = { label = p.name or tile.name or "", icon = p.icon or tile.icon or "app-window",
        tap = function() openTile(tile) end }
    if p.kind == "todo" then
        item.hold = function()
            local todo = plugin("todo")
            if todo then todo:addTask({ listId = p.id }) end
        end
    elseif p.kind == "todoview" then
        item.hold = function() event("AddTodoTask") end
    elseif p.kind == "note" or p.kind == "notefolder" then
        item.hold = function() event("ShowNotes") end
    elseif p.kind == "crossword" then
        item.hold = function() event("ShowCrosswords") end
    elseif p.kind == "ha" then
        item.hold = function() event("ShowHomeAssistant") end
    elseif p.kind == "action" then
        item.hold = function()
            KO.list(item.label, {
                { text = _("Run"), fn = function() openTile(tile) end },
                { text = _("Edit quick buttons"), fn = function() local A = apps() if A then A:showMode("quick") end end },
            })
        end
    end
    return item
end

--- Whether a built-in can show here (its plugin, or a front light).
local function available(key)
    local b = Model.quickBuiltin(key)
    if not b then return false end
    if b.plugin == "@frontlight" then return Device:hasFrontlight() end
    if b.plugin then return plugin(b.plugin) ~= nil end
    return true
end
Quick.available = available

--- An entry as a button: { label, icon, on, tap, hold, group, items } or nil
-- (not here: its plugin is missing).
function Quick.item(e)
    if e.b then
        if not (available(e.b) and BUILTIN[e.b]) then return nil end
        local ok, item = pcall(BUILTIN[e.b])
        return ok and item or nil
    elseif e.pin then
        local ok, item = pcall(pinItem, e.pin)
        return ok and item or nil
    elseif e.app then
        local P = (PS().quickApps or {})[e.app]
        if not P then return nil end
        local ok, item = pcall(P.item, e.id)
        return ok and item or nil
    elseif e.group then
        return { label = e.name or _("Group"), icon = e.icon or "folder", group = true, entry = e }
    end
end

--- The entries' buttons (those here), each with its entry.
function Quick.items(list)
    local out = {}
    for __, e in ipairs(list or {}) do
        local item = Quick.item(e)
        if item then
            item.entry = e
            table.insert(out, item)
        end
    end
    return out
end

--- The buttons as set, or none when the row is off.
function Quick.list(s)
    return Model.quickList(s)
end

-- ------------------------------------------------------------------ drawing

local H, GAP = 40, 10

-- A button's controls at its right: { icon, fn } (− and +, a player's).
local function controls(it)
    local out = {}
    if it.media then
        local m = it.media
        if m.prev then table.insert(out, { "skip-back", m.prev }) end
        if m.play then table.insert(out, { m.playing and "pause" or "play", m.play }) end
        if m.next then table.insert(out, { "skip-forward", m.next }) end
        if m.mute then table.insert(out, { m.muted and "volume-x" or "volume-2", m.mute }) end
        if m.minus then table.insert(out, { "minus", m.minus }) end
        if m.plus then table.insert(out, { "plus", m.plus }) end
    elseif it.steps then
        table.insert(out, { "minus", it.steps.minus })
        table.insert(out, { "plus", it.steps.plus })
    end
    return out
end

local CW = 30   -- each control's width

-- The name, cut to fit a button.
local function labelWidth(c, it, size) return math.min(c:width(it.label, size, true), 190) end

--- A button's width at `size`: icon, name, value, controls.
local function width(c, it, size)
    local w = labelWidth(c, it, size) + 24 + 30 + (it.group and 16 or 0)
    if it.value then w = w + c:width(it.value, size - 1) + 8 end
    return w + #controls(it) * CW
end

local function pill(c, x, y, w, it, size, tap, hold)
    local ctl = controls(it)
    local cw = #ctl * CW
    if it.chip then
        -- A reading: no tap, a lighter edge.
        c:box(x, y, w, H, { r = H / 2, border = C.GREY, bw = 1 })
    else
        c:box(x, y, w, H, { r = H / 2, fill = it.on and C.FILL or nil, border = C.BLACK, bw = 1.2 })
    end
    local vw = it.value and (c:width(it.value, size - 1) + 8) or 0
    local tw = math.min(labelWidth(c, it, size), w - 54 - cw - vw - (it.group and 16 or 0))
    local ix = cw > 0 and (x + 14) or (x + (w - tw - 24 - vw - (it.group and 16 or 0)) / 2)
    c:icon(it.icon or "app-window", ix, y + 11, 18, it.on)
    c:text(ix + 24, y + 25, it.label, size, { bold = not it.chip, color = it.on and C.ON_FILL or C.BLACK, maxw = tw + 1 })
    if it.value then c:text(ix + 24 + tw + 8, y + 25, it.value, size - 1, { color = it.on and C.ON_FILL or C.GREY }) end
    if it.group then c:icon("chevron-down", ix + 26 + tw, y + 13, 14, it.on) end
    if not it.chip then c:hit(x, y, w, H, tap, hold) elseif hold then c:hit(x, y, w, H, hold, hold) end
    -- The controls, each its own circle (taps there don't toggle the button).
    local cx = x + w - cw - 6
    for __, k in ipairs(ctl) do
        c:circle(cx + CW / 2, y + H / 2, 12, it.on and C.ON_FILL or C.BLACK, 1.1)
        c:icon(k[1], cx + CW / 2 - 8, y + H / 2 - 8, 16, it.on)
        c:hit(cx, y, CW, H, k[2], k[2])
        cx = cx + CW
    end
end

--- Lays buttons out in rows from x0 to x1, at most `maxRows` (then the last
-- place is More ▾, which calls `more`). Calls draw(it, x, y, w, moreFn) for
-- each. Returns the rows used.
local function flow(c, items, x0, x1, top, maxRows, size, more, draw)
    local moreItem = { label = _("More"), icon = "ellipsis-vertical", group = true }
    local moreW = width(c, moreItem, size)
    -- Where each goes; with `withMore`, the last row keeps room for More.
    local function place(withMore)
        local out, x, row = {}, x0, 1
        for __, it in ipairs(items) do
            local w = math.min(width(c, it, size), x1 - x0)
            local nx, nrow = x, row
            if nx > x0 and nx + w > x1 then nx, nrow = x0, row + 1 end
            if maxRows and (nrow > maxRows or (withMore and nrow == maxRows and nx + w + GAP + moreW > x1)) then
                return out, true, (nrow > maxRows) and x or nx
            end
            x, row = nx, nrow
            table.insert(out, { it = it, x = x, row = row, w = w })
            x = x + w + GAP
        end
        return out, false
    end
    local placed, over = place(false)
    local moreX
    if over then placed, over, moreX = place(true) end
    local rows = 1
    for __, p in ipairs(placed) do
        draw(p.it, p.x, top + (p.row - 1) * (H + GAP), p.w)
        rows = math.max(rows, p.row)
    end
    if over then
        rows = maxRows
        draw(moreItem, moreX, top + (maxRows - 1) * (H + GAP), moreW, more)
    end
    return rows
end

--- The buttons a control center always has, when they aren't among yours.
Quick.CORE = { "wifi", "night", "refresh", "web", "awake" }

--- The core buttons not in this list (or in one of its groups): { { b = key } }.
function Quick.coreMissing(list)
    local have = {}
    for __, e in ipairs(list) do
        have[Model.quickKey(e)] = true
        for __, sub in ipairs(e.items or {}) do have[Model.quickKey(sub)] = true end
    end
    local out = {}
    for __, k in ipairs(Quick.CORE) do
        if not have["b:" .. k] and Quick.available(k) then table.insert(out, { b = k }) end
    end
    return out
end

--- Which of your buttons the home screen shows (upright, two rows, as drawRow
-- places them): { [quickKey] = true } and how far down the list they go (the
-- index of the last one; 0 for none). Any canvas the launcher's width will do.
function Quick.homeKeys(c, s)
    local keys, last = {}, 0
    if s.toggles == false then return keys, last end
    local list = Quick.list(s)
    flow(c, Quick.items(list), 28, c.W - 28, 0, 2, 11.5, nil, function(it)
        if it.entry then keys[Model.quickKey(it.entry)] = true end
    end)
    for i, e in ipairs(list) do if keys[Model.quickKey(e)] then last = i end end
    return keys, last
end

--- After a tap: the launcher's lines and the screen drawn again.
local function redrawLauncher(mode)
    local v = PS().appsView and PS().appsView()
    if v and UIManager:isWidgetShown(v) then
        if v.updateLines then pcall(v.updateLines, v) end
        v:render()
        UIManager:setDirty(mode == "full" and "all" or v, mode == "full" and "full" or "ui")
    end
end

-- The controls call back with the redraw (as a tap does).
local function wired(it, done)
    local function wrap(fn) return fn and function() fn(done) end or nil end
    if it.steps then it.steps = { minus = wrap(it.steps.minus), plus = wrap(it.steps.plus) } end
    if it.media then
        local m = {}
        for k, v in pairs(it.media) do m[k] = type(v) == "function" and wrap(v) or v end
        it.media = m
    end
    return it
end

--- The launcher's row(s): from x0 to x1 at `top`. Returns the height, or 0 when off.
function Quick.drawRow(view, c, top, x0, x1)
    local s = view.apps.settings
    if s.toggles == false then return 0 end
    local items = Quick.items(Quick.list(s))
    if #items == 0 then return 0 end
    for __, it in ipairs(items) do wired(it, redrawLauncher) end
    local CC = function(open) require("appscontrol").show(nil, open) end
    local rows = flow(c, items, x0, x1, top, 2, 11.5, function() CC() end, function(it, x, y, w, more)
        if more then return pill(c, x, y, w, it, 11.5, more) end
        local tap = it.group and function() CC(Model.quickKey(it.entry)) end
            or function() it.tap(redrawLauncher) end
        local hold = it.group and function() Quick.groupMenu(view, it.entry) end or it.hold
        pill(c, x, y, w, it, 11.5, tap, hold or tap)
    end)
    return rows * (H + GAP) + 6
end

--- The control center's buttons: all of them, then the open group's under them
-- (in a box). `open`: a group's key or nil; toggle(key) opens or closes one; done
-- redraws the panel; close closes it (before a button that opens something);
-- pager = { page, turn(delta) } when there may be more rows than fit.
-- Returns the height.
function Quick.drawAll(c, top, list, open, toggle, done, close, pager)
    local raw = Quick.items
    local function items(l)
        local out = raw(l)
        for __, it in ipairs(out) do wired(it, done) end
        return out
    end
    -- A switch stays (to see it change); anything else closes the panel first.
    local function tapOf(it)
        return function()
            if it.on == nil and close then close() end
            it.tap(done)
        end
    end
    local all = items(list)
    local y = top
    -- About half the screen of rows a page; past that, pages.
    local per = math.max(2, math.floor(c.H * 0.45 / (H + GAP)))
    local placed, rowsAll = {}, 0
    flow(c, all, 28, c.W - 28, 0, nil, 11.5, nil, function(it, x, yy, w)
        local row = math.floor(yy / (H + GAP) + 0.5) + 1
        table.insert(placed, { it = it, x = x, row = row, w = w })
        rowsAll = math.max(rowsAll, row)
    end)
    local pages = math.max(1, math.ceil(rowsAll / per))
    local page = math.min(pager and pager.page or 1, pages)
    local first = (page - 1) * per + 1
    local shown = 0
    for __, p in ipairs(placed) do
        if p.row >= first and p.row < first + per then
            local it = p.it
            local key = it.entry and Model.quickKey(it.entry)
            if it.group then it.on = key == open end
            local tap = it.group and function() toggle(key) end or tapOf(it)
            pill(c, p.x, y + (p.row - first) * (H + GAP), p.w, it, 11.5, tap, it.hold or tap)
            shown = math.max(shown, p.row - first + 1)
        end
    end
    y = y + shown * (H + GAP)
    if pages > 1 and pager then
        local label = page .. " / " .. pages
        local cx = c.W / 2
        c:icon("chevron-left", cx - 70, y + 4, 20)
        c:text(cx, y + 20, label, 11.5, { align = "middle", color = C.GREY })
        c:icon("chevron-right", cx + 50, y + 4, 20)
        c:hit(cx - 100, y - 4, 90, 36, function() if page > 1 then pager.turn(-1) end end)
        c:hit(cx + 10, y - 4, 90, 36, function() if page < pages then pager.turn(1) end end)
        y = y + 36
    end
    -- The open group's buttons, in a box under the rest.
    local g = open and Model.quickFind(list, open)
    if g and g.items then
        local inner = items(g.items)
        local h0 = y
        c:text(40, y + 22, g.name or "", 11, { bold = true, color = C.GREY })
        y = y + 32
        local r2 = #inner > 0 and flow(c, inner, 40, c.W - 40, y, nil, 11.5, nil, function(it, x, yy, w)
            pill(c, x, yy, w, it, 11.5, tapOf(it), it.hold or tapOf(it))
        end) or 0
        if #inner == 0 then c:text(40, y + 22, _("Nothing in it yet. Settings > Launcher > Quick buttons adds some."), 11, { color = C.GREY, maxw = c.W - 80 }) r2 = 1 end
        y = y + r2 * (H + GAP) + 4
        c:box(28, h0, c.W - 56, y - h0, { r = 12, border = C.BLACK, bw = 1.2 })
        y = y + GAP
    end
    return y - top
end

-- ------------------------------------------------------------------ editing

local function settings(view) return view.apps.settings end

-- The list, kept from now on (made from the buttons as they were).
local function editable(view)
    local s = settings(view)
    if type(s.quick) ~= "table" then
        s.quick = require("util").tableDeepCopy(Model.quickList(s))
    end
    return s.quick
end

local function saved(view)
    view.apps:save()
    view:refresh()
end

local function nameOf(e)
    if e.b then local b = Model.quickBuiltin(e.b) return b and _(b.name) or e.b end
    if e.pin then return e.pin.name or Model.pinTile(e.pin).name or "" end
    if e.group then return e.name or _("Group") end
    if e.app then return e.name or tostring(e.id) end
    return ""
end
Quick.nameOf = nameOf

--- A group's hold: rename it, or edit what's in it.
function Quick.groupMenu(view, e)
    KO.list(e.name, {
        { text = _("Rename"), fn = function()
            view:askName(_("Rename group"), e.name or "", function(name)
                local g = Model.quickFind(editable(view), Model.quickKey(e))
                if g then g.name = name end
                saved(view)
            end)
        end },
        { text = _("Change icon"), fn = function()
            view.mode, view.iconQuick, view.iconGroup, view.iconsPage = "icons", Model.quickKey(e), nil, 1
            view:refresh()
        end },
        { text = _("Edit quick buttons"), fn = function() Quick.edit(view) end },
    })
end

--- The editor (the launcher's "quick" mode).
function Quick.edit(view)
    view.backTo = view.mode ~= "quick" and view.mode or view.backTo
    view.mode, view.quickPage = "quick", 1
    view:refresh()
end

-- One entry's menu: move, into or out of a group, remove (Undo).
local function entryMenu(view, e, inGroup)
    local key = Model.quickKey(e)
    local list = editable(view)
    local items = {
        { text = _("Move to top"), fn = function() Model.quickMove(list, key, -math.huge) saved(view) end },
        { text = _("Move up"), fn = function() Model.quickMove(list, key, -1) saved(view) end },
        { text = _("Move down"), fn = function() Model.quickMove(list, key, 1) saved(view) end },
        { text = _("Move to bottom"), fn = function() Model.quickMove(list, key, math.huge) saved(view) end },
    }
    if not e.group then
        local groups = {}
        for __, g in ipairs(list) do
            if g.group and Model.quickKey(g) ~= key then table.insert(groups, g) end
        end
        if inGroup then
            table.insert(items, { text = _("Out of the group"), fn = function() Model.quickPut(list, key, nil) saved(view) end })
        end
        if #groups > 0 then
            table.insert(items, { text = _("Move to a group…"), fn = function()
                local choices = {}
                for __, g in ipairs(groups) do
                    table.insert(choices, { text = g.name or _("Group"), fn = function() Model.quickPut(list, key, Model.quickKey(g)) saved(view) end })
                end
                KO.list(_("Move to a group"), choices, function() entryMenu(view, e, inGroup) end)
            end })
        end
    else
        table.insert(items, { text = _("Rename"), fn = function()
            view:askName(_("Rename group"), e.name or "", function(name) e.name = name saved(view) end)
        end })
        table.insert(items, { text = _("Change icon"), fn = function()
            view.backTo = "quick"
            view.mode, view.iconQuick, view.iconGroup, view.iconsPage = "icons", key, nil, 1
            view:refresh()
        end })
    end
    table.insert(items, { text = _("Remove"), fn = function()
        local before = require("util").tableDeepCopy(list)
        Model.quickRemove(list, key)
        saved(view)
        KO.undo(T(_("Removed %1"), nameOf(e)), function()
            settings(view).quick = before
            saved(view)
        end)
    end })
    KO.list(nameOf(e), items)
end

-- Adding: a built-in, a shortcut (as Add shortcut's lists), or a new group.
local addMenu
addMenu = function(view)
    local top = function() addMenu(view) end
    local list = editable(view)
    local have = {}
    local function mark(l) for __, e in ipairs(l) do have[Model.quickKey(e)] = true if e.items then mark(e.items) end end end
    mark(list)
    local function add(e)
        table.insert(list, e)
        saved(view)
        KO.toast(T(_("Added %1"), nameOf(e)))
    end
    local menu = {
        { text = _("Built-in buttons…"), fn = function()
            local choices = {}
            for __, b in ipairs(Model.QUICK_BUILTIN) do
                if available(b.key) and not have["b:" .. b.key] then
                    table.insert(choices, { text = _(b.name), fn = function() add({ b = b.key }) end })
                end
            end
            if #choices == 0 then return KO.toast(_("They're all added.")) end
            KO.list(_("Built-in buttons"), choices, top)
        end },
    }
    local kinds = {
        { "ha", _("Home Assistant…"), "homeassistant" }, { "todo", _("To Do…"), "todo" },
        { "note", _("Notebook…"), "notes" }, { "notefolder", _("Notes folder…"), "notes" },
        { "crossword", _("Crossword…"), "notes" }, { "action", _("KOReader action…") },
    }
    -- An app's own buttons under the same name as a kind (To Do: Sync To Do) go first in its list.
    local merged = {}
    for __, k in ipairs(kinds) do
        if not k[3] or plugin(k[3]) then
            local P = k[3] and (PS().quickApps or {})[k[3]]
            if P and P.choices and P.name == k[2]:gsub("…$", "") then merged[k[3]] = true else P = nil end
            table.insert(menu, { text = k[2], fn = function()
                local choices = {}
                if P then
                    local ok, list2 = pcall(P.choices)
                    for __, ch in ipairs(ok and list2 or {}) do
                        if not have["a:" .. k[3] .. ":" .. ch.id] then
                            table.insert(choices, { text = ch.name, fn = function() add({ app = k[3], id = ch.id, name = ch.name }) end })
                        end
                    end
                end
                for __, p in ipairs(view.apps:pinChoices(k[1])) do
                    if not have[Model.pinKey(p)] then
                        table.insert(choices, { text = p.name, fn = function() add({ pin = p }) end })
                    end
                end
                if #choices == 0 then return KO.toast(_("Nothing more to add here.")) end
                KO.list((k[2]:gsub("…$", "")), choices, top)
            end })
        end
    end
    for key, P in pairs(PS().quickApps or {}) do
        if P.choices and not merged[key] then
            table.insert(menu, { text = (P.name or key) .. "…", fn = function()
                local ok, list2 = pcall(P.choices)
                local byGroup, order = {}, {}
                for __, ch in ipairs(ok and list2 or {}) do
                    if not have["a:" .. key .. ":" .. ch.id] then
                        local g = ch.group or ""
                        if not byGroup[g] then byGroup[g] = {} table.insert(order, g) end
                        table.insert(byGroup[g], ch)
                    end
                end
                local groups = {}
                local function showGroups() KO.list(P.name or key, groups, top) end
                local function pickFrom(g)
                    local choices = {}
                    for __, ch in ipairs(byGroup[g]) do
                        table.insert(choices, { text = ch.name, fn = function() add({ app = key, id = ch.id, name = ch.name }) end })
                    end
                    KO.list(g ~= "" and g or (P.name or key), choices, #order > 1 and showGroups or top)
                end
                if #order == 0 then return KO.toast(_("Nothing more to add here.")) end
                if #order == 1 then return pickFrom(order[1]) end
                for __, g in ipairs(order) do
                    table.insert(groups, { text = (g ~= "" and g or _("Other")) .. "  (" .. #byGroup[g] .. ")", fn = function() pickFrom(g) end })
                end
                showGroups()
            end })
        end
    end
    table.insert(menu, { text = _("New group…"), fn = function()
        view:askName(_("New group"), "", function(name)
            add({ group = tostring(os.time()) .. tostring(math.random(100, 999)), name = name, icon = "folder", items = {} })
        end)
    end })
    KO.list(_("Add a quick button"), menu)
end
Quick.addMenu = addMenu

function Quick.drawEditor(view, c)
    local s = settings(view)
    local list = Model.quickList(s)
    local onHome = s.toggles ~= false
    local __, last = Quick.homeKeys(c, s)
    local F = c:flow(56, c.H - 8, view.quickPage or 1)
    F:block(48, function(y)
        c:text(14, y + 30, _("Show on the home screen"), 12.5)
        c:box(c.W - 66, y + 12, 52, 26, { r = 13, fill = onHome and C.FILL or nil, border = C.BLACK, bw = 1.4 })
        c:circle(onHome and (c.W - 27) or (c.W - 53), y + 25, 9, onHome and C.ON_FILL or C.BLACK)
        c:hline(14, y + 48, c.W - 28)
        c:hit(0, y, c.W, 48, function() s.toggles = not onHome saved(view) end)
    end)
    F:block(34, function(y)
        c:text(14, y + 24, _("Tap does the quick thing; hold opens what's behind it."), 10.5, { color = C.GREY, maxw = c.W - 28 })
    end)
    -- A section's name and what it means.
    local function section(title, note)
        F:block(note and 54 or 36, function(y)
            c:text(14, y + 26, title, 9.5, { bold = true, color = C.GREY })
            if note then c:text(14, y + 46, note, 10.5, { color = C.GREY, maxw = c.W - 28 }) end
        end, 80)
    end
    local function row(e, indent, inGroup)
        F:block(48, function(y)
            local item = Quick.item(e)
            local x = 14 + indent
            c:icon((item and item.icon) or (e.group and "folder") or "app-window", x, y + 15, 18)
            c:text(x + 30, y + 30, nameOf(e), 12.5, { maxw = c.W - x - 120, bold = e.group ~= nil })
            local note = not item and _("Not here") or (e.group and T(_("%1 in it"), #(e.items or {}))) or nil
            if note then c:text(c.W - 44, y + 30, note, 10.5, { align = "end", color = C.GREY }) end
            c:icon("ellipsis-vertical", c.W - 34, y + 15, 18)
            c:hline(x, y + 48, c.W - 14 - x)
            c:hit(0, y, c.W, 48, function() entryMenu(view, e, inGroup) end)
        end)
    end
    if #list == 0 then
        section(_("YOUR BUTTONS"))
        F:block(40, function(y) c:text(14, y + 28, _("None yet."), 12, { color = C.GREY }) end)
    end
    for i, e in ipairs(list) do
        if i == 1 and onHome and last > 0 then
            section(_("ON THE HOME SCREEN"), _("Two rows under the clock, then More. Also in the control center."))
        end
        if i == last + 1 then
            if onHome and last > 0 then
                section(_("ONLY IN THE CONTROL CENTER"), _("More on the home screen opens these."))
            else
                section(_("IN THE CONTROL CENTER"), (not onHome) and _("Show on the home screen is off.") or nil)
            end
        end
        row(e, 0, false)
        for __, sub in ipairs(e.items or {}) do row(sub, 28, true) end
    end
    F:block(70, function(y)
        local label = _("Add a button")
        local bw = c:width(label, 12) + 64
        c:box(14, y + 18, bw, 38, { r = 19, border = C.BLACK, bw = 1.4 })
        c:icon("plus", 30, y + 28, 18)
        c:text(56, y + 43, label, 12)
        c:hit(14, y + 12, bw, 50, function() addMenu(view) end)
    end)
    -- The ones every control center has: tap one to add it to yours and place it.
    local core = Quick.coreMissing(list)
    if #core > 0 then
        section(_("ALWAYS IN THE CONTROL CENTER"), _("Built in. Tap one to add it to your buttons and place it yourself."))
        local items = Quick.items(core)
        F:block(2 * (H + GAP) + 10, function(y)
            flow(c, items, 14, c.W - 14, y + 4, nil, 11.5, nil, function(it, x, py, w)
                c:box(x, py, w, H, { r = H / 2, border = C.GREY, bw = 1 })
                c:icon(it.icon, x + 14, py + 11, 18, false)
                c:text(x + 40, py + 26, it.label, 11.5, { color = C.GREY })
                c:hit(x, py, w, H, function()
                    table.insert(list, it.entry)
                    saved(view)
                    KO.toast(T(_("Added %1"), nameOf(it.entry)))
                end)
            end)
        end)
    end
    view.pages = F:pages()
    if (view.quickPage or 1) > view.pages then
        view.quickPage = view.pages
        return view:render()
    end
    view:bar(c, _("Quick buttons"))
end

return Quick
