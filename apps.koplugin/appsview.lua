--[[--
The launcher: the time and date, the battery and Wi-Fi, then a big tile for
each app, and for each pinned place (a Home Assistant screen, a To Do list,
a notebook), with a line of what is going on in it. Tap a tile to open it
(on top, so closing it comes back here); hold a tile to move, hide or remove
it; ⋮ > Settings arranges the tiles, adds pins and picks the layout (tiles,
bold tiles, a list or icons) and dark mode. More tiles than fit turn pages.
At the top right, as in every app's title bar: refresh, the notifications
(a bell with a count) and ⋮.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Bar = require("appsbar")
local Canvas = require("appscanvas")
local KO = require("appsko")
local Model = require("appsmodel")

local Screen = Device.screen
local C = Canvas

-- Not modal: KOReader puts a dialog that is not modal (a list to choose from,
-- a menu, a text box) under a modal screen, out of sight.
local View = InputContainer:extend{
    covers_fullscreen = true,
    flash_on_uncover = true,   -- a full refresh when a dialog over it closes (KO.flashOnUncover)
    apps = nil,       -- the plugin (main.lua): settings, save(), currentUI()
    on_close = nil,
}

function View:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = all } },
        Hold = { GestureRange:new{ ges = "hold", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    self.mode = "tiles"
    self.pageNo, self.arrangePage = 1, 1
    self:render()
end

function View:ui() return self.apps:currentUI() end
function View:currentUI() return self.apps:currentUI() end

function View:plugin(name)
    local ui = self:ui()
    return ui and ui[name]
end

-- ------------------------------------------------------------------ what each tile says

-- Each tile's line, kept between showings (and across restarts), so the
-- launcher draws at once; worked out again a tile at a time afterwards.
local lines = G_reader_settings:readSetting("apps_lines") or {}

function View:line(tile)
    return lines[tile.key] or ""
end

-- The last few books read (file, title, percent read), kept like the lines.
local recent = G_reader_settings:readSetting("apps_recent") or {}
-- Notes' recent notebooks and crosswords (ui.notes:recentNotebooks / recentCrosswords).
local recentNotes, recentPuzzles = {}, {}

--- The last `n` books in KOReader's history that still exist, with how far
-- read (from each book's settings: worked out between showings).
--- A book's own title when KOReader has read it (its Cover browser record), else the file's name.
local function bookTitle(file)
    local okb, BIM = pcall(require, "bookinfomanager")
    if okb and BIM and BIM.getBookInfo then
        local got, info = pcall(BIM.getBookInfo, BIM, file, false)
        if got and info and type(info.title) == "string" and info.title ~= "" then return info.title end
    end
    return Model.bookName(file)
end

function View:readRecent(n)
    local out = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok then return out end
    local lfs = require("libs/libkoreader-lfs")
    for __, item in ipairs(ReadHistory.hist or {}) do
        if #out >= n then break end
        local file = item.file
        if file and lfs.attributes(file, "mode") == "file" then
            -- The book's settings opened once (a big one, with many highlights, is slow to read).
            local okd, ds = pcall(function() return require("docsettings"):open(file) end)
            local pct = okd and ds:readSetting("percent_finished")
            if type(pct) ~= "number" then pct = nil end
            local sm = okd and ds:readSetting("summary")
            local finished = type(sm) == "table" and sm.status == "complete" or nil
            table.insert(out, { file = file, title = bookTitle(file), percent = pct and math.floor(pct * 100 + 0.5) or nil, finished = finished })
        end
    end
    return out
end

function View:updateLines()
    if self.updating then return end
    self.updating = true
    local tiles = self:tiles()
    local i, changed = 0, false
    local function step()
        if not self.canvas or self.closed then self.updating = false return end
        i = i + 1
        local tile = tiles[i]
        if not tile then
            self.updating = false
            -- The recent books too.
            if self.apps.settings.recent ~= false then
                local r = self:readRecent(5)
                local before, after = {}, {}
                for __, b in ipairs(recent) do table.insert(before, b.file .. (b.percent or "") .. (b.title or "")) end
                for __, b in ipairs(r) do table.insert(after, b.file .. (b.percent or "") .. (b.title or "")) end
                if table.concat(before, "|") ~= table.concat(after, "|") then
                    recent = r
                    G_reader_settings:saveSetting("apps_recent", recent)
                    changed = true
                end
            end
            local nb, pz = self:readRecentNotes()
            if nb.sig ~= recentNotes.sig or pz.sig ~= recentPuzzles.sig then
                recentNotes, recentPuzzles = nb, pz
                changed = true
            end
            if changed then
                G_reader_settings:saveSetting("apps_lines", lines)
                if UIManager:getTopmostVisibleWidget() == self then self:refresh() end
            end
            return
        end
        local started = os.clock()
        local text = self:status(tile) or ""
        logger.dbg("Apps:", tile.key, "line in", os.clock() - started, "s")
        if lines[tile.key] ~= text then
            lines[tile.key] = text
            changed = true
        end
        UIManager:nextTick(step)
    end
    UIManager:nextTick(step)
end

-- Notes' notebooks without reading their ink: how many, and the newest one's
-- name (from the start of its file).
local function notebooksLine(notes)
    local dir = notes.store and notes.store.dir
    local lfs = require("libs/libkoreader-lfs")
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then return nil end
    local count, newest, newestTime = 0, nil, -1
    for name in lfs.dir(dir) do
        if name:match("^nb%d+%.lua$") then
            count = count + 1
            local t = lfs.attributes(dir .. "/" .. name, "modification") or 0
            if t > newestTime then newest, newestTime = name, t end
        end
    end
    if count == 0 then return _("No notebooks yet") end
    local title
    local f = io.open(dir .. "/" .. newest, "r")
    if f then
        local head = f:read(2048) or ""
        f:close()
        local quoted = head:match('name=("[^"\\]*")') or head:match("name=(%b\"\")")
        if quoted then
            local fn = loadstring("return " .. quoted)
            if fn then
                setfenv(fn, {})
                local ok, v = pcall(fn)
                if ok and type(v) == "string" then title = v end
            end
        end
    end
    return title and T(_("%1 notebooks \u{00B7} last: %2"), count, title) or T(_("%1 notebooks"), count)
end

local function try(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    logger.dbg("Apps:", v)
end

-- A crossword tile's line: "Wed 21 Oct · Started", or "Not downloaded yet"
-- (with the source's name first when `named`). `which`: the source, or nil
-- for the one Today's crossword is set to.
local function crosswordLine(notes, which, named)
    local info = notes:todaysCrosswordInfo(which) or {}
    local parts = { named and info.name or nil }
    if not info.have then
        table.insert(parts, _("Not downloaded yet"))
    else
        if info.day then table.insert(parts, os.date("!%a %d %b", info.day * 86400)) end
        local states = { new = _("New"), started = _("Started"), done = _("Done") }
        table.insert(parts, states[info.state])
    end
    return table.concat(parts, " \u{00B7} ")
end

local function keysOf(tiles)
    local out = {}
    for i, t in ipairs(tiles) do out[i] = t.key end
    return out
end

local function groupOf(s, id)
    for __, g in ipairs(s.groups or {}) do
        if g.id == id then return g end
    end
end

-- A pinned place's line: what is going on there.
function View:pinStatus(p)
    if p.kind == "action" then
        return try(function() return require("appsactions").status(p.id, self:currentUI()) end) or ""
    elseif p.kind == "ha" then
        local ha = self:plugin("homeassistant")
        if not (ha and ha.snap) then return "" end
        return try(function()
            local M = require("hamodel")
            local snap, prefs, r = ha.snap, ha.prefs, p.route or {}
            local k = r.kind
            if k == "room" then
                for __, room in ipairs(M.rooms(snap, prefs)) do
                    if room.name == r.name then return M.roomSummary(room) end
                end
                return ""
            elseif k == "home" or k == "security" then
                return M.attention(snap, prefs).text
            elseif k == "notifications" then
                local n = ha.notifications and #ha.notifications
                if not n then return "" end
                return n == 0 and _("None") or (n == 1 and _("1 notification") or T(_("%1 notifications"), n))
            elseif k == "climate" then
                local t, h = M.inside(snap, prefs)
                return t and (T(_("Inside %1"), M.formatTemp(t)) .. (h and (" \u{00B7} " .. math.floor(h + 0.5) .. "%") or "")) or ""
            elseif k == "weather" or k == "dashboard" then
                local w = snap.weather
                return w and ((w.temp and M.formatTemp(w.temp) .. " " or "") .. M.weather(w.state)) or ""
            elseif k == "batteries" then
                local b = M.batteryList(snap, prefs)[1]
                return b and T(_("Lowest: %1 %2%"), M.shortName(b.e), math.floor(b.percent + 0.5)) or ""
            elseif k == "printer" then
                local state, pct
                for __, e in ipairs(M.printer(snap, prefs)) do
                    if not state and e.id:find("status") then state = M.title(e.state) end
                    if not pct and e.id:find("progress") then pct = tonumber(e.state) end
                end
                return (state or "") .. (pct and (" \u{00B7} " .. math.floor(pct + 0.5) .. "%") or "")
            elseif k == "camera" then
                local e = snap.byId[r.id or ""]
                return e and M.stateText(e) or ""
            elseif k == "activity" then
                local e = M.activity(snap, prefs)[1]
                return e and (e.name .. " \u{00B7} " .. M.stateText(e)) or ""
            end
            -- A kind of device (lights, cameras, players...): how many are on.
            local def = M.shortcut(r.key or "") or {}
            for __, s in ipairs(M.SHORTCUTS) do
                if s.screen == k then def = s end
            end
            local on, total = 0, 0
            for __, e in ipairs(snap.list) do
                if def.domains and def.domains[e.domain] and M.visible(e, prefs) then
                    total = total + 1
                    if M.isOn(e) then on = on + 1 end
                end
            end
            if k == "cameras" or k == "scripts" then return T(_("%1 to show"), total) end
            if r.key == "doors" then return M.attention(snap, prefs).text end
            if r.key == "vacuums" then
                local states = {}
                for __, e in ipairs(snap.list) do
                    if e.domain == "vacuum" and M.visible(e, prefs) then table.insert(states, e.name .. " " .. M.stateText(e):lower()) end
                end
                return table.concat(states, " · ")
            end
            return T(_("%1 of %2 on"), on, total)
        end) or ""
    elseif p.kind == "todo" then
        local todo = self:plugin("todo")
        if not (todo and todo.store) then return "" end
        return try(function()
            local list = todo.store:findList(p.id)
            if not list then return _("List not found") end
            local open, overdue, today = require("todomodel").counts(list, todo:today())
            if today > 0 or overdue > 0 then
                return T(_("%1 today"), today) .. (overdue > 0 and (" \u{00B7} " .. T(_("%1 overdue"), overdue)) or "")
            end
            return open > 0 and T(_("%1 open"), open) or _("Nothing open")
        end) or ""
    elseif p.kind == "todoview" then
        local todo = self:plugin("todo")
        if not (todo and todo.viewLine) then return "" end
        return try(function() return todo:viewLine(p.id) end) or ""
    elseif p.kind == "note" then
        local notes = self:plugin("notes")
        if not (notes and notes.store) then return "" end
        return try(function()
            for __, n in ipairs(notes.store:list()) do
                if n.id == p.id then
                    return n.modified and T(_("Edited %1"), os.date("%b %d", n.modified)) or ""
                end
            end
            return _("Notebook not found")
        end) or ""
    elseif p.kind == "crossword" then
        local notes = self:plugin("notes")
        if not (notes and notes.todaysCrosswordInfo) then return "" end
        return try(function() return crosswordLine(notes, p.id) end) or ""
    elseif p.kind == "notefolder" then
        local notes = self:plugin("notes")
        if not (notes and notes.store and notes.folders) then return "" end
        return try(function()
            local ids, newest = {}, nil
            for __, n in ipairs(notes.store:list()) do
                table.insert(ids, n.id)
            end
            local inside = notes.folders:inside(p.id, ids)
            local exists = false
            for __, path in ipairs(notes.folders:all()) do
                if path == p.id then exists = true end
            end
            if not exists then return _("Folder not found") end
            return #inside == 1 and _("1 notebook") or T(_("%1 notebooks"), #inside)
        end) or ""
    end
    return ""
end

function View:status(tile)
    if tile.pin then return self:pinStatus(tile.pin) end
    if tile.groupTile then
        local s, n = self.apps.settings, 0
        for __, g in pairs(s.grouped or {}) do
            if g == tile.groupTile then n = n + 1 end
        end
        return n == 1 and _("1 tile") or T(_("%1 tiles"), n)
    end
    local key = tile.key
    if key == "readingtime" then
        local stats = try(function() return self.apps:readingStats() end)
        if not stats then return _("No reading yet") end
        local today = T(_("%1 today"), Model.duration(stats.today))
        if stats.streak < 2 then return today end
        return today .. " \u{00B7} " .. T(_("%1 days in a row"), stats.streak)
    elseif key == "reading" then
        local file = G_reader_settings:readSetting("lastfile")
        if not file then return _("No recent book") end
        local pct = try(function()
            local DocSettings = require("docsettings")
            return DocSettings:open(file):readSetting("percent_finished")
        end)
        return bookTitle(file) .. (pct and string.format(" · %d%%", math.floor(pct * 100 + 0.5)) or "")
    elseif key == "settings" then
        -- (a newer release seen, until it's installed)
        local tag = try(function() return require("appsupdate").available(self.apps) end)
        return tag and T(_("Update available: %1"), tag) or _("Every app's settings")
    elseif key == "kosettings" then
        return _("Device, screen, network and more")
    elseif key == "wikipedia" then
        local w = self:plugin("wikipedia")
        local line = w and w.appsLine and try(function() return w:appsLine() end) or ""
        return line ~= "" and line or _("Search and save articles")
    elseif key == "syncthing" then
        -- "On · Up to date", "On · Syncing · 3 files left", "Off".
        local s = self:plugin("syncthing")
        return s and s.appsLine and try(function() return s:appsLine() end) or ""
    elseif key == "ssh" then
        -- "3 hosts".
        local s = self:plugin("sshclient")
        return s and s.appsLine and try(function() return s:appsLine() end) or ""
    elseif key == "battery" then
        return try(function() return require("appsbattery").line(self:ui()) end) or ""
    elseif key == "weather" then
        return try(function() return require("appsweather").line(self.apps) end) or ""
    elseif key == "fonts" then
        return try(function()
            local font = G_reader_settings:readSetting("cre_font") or require("document/credocument").default_font
            return T(_("New books: %1"), font)
        end) or ""
    elseif key == "gestures" then
        local ui = self:ui()
        local g = ui and ui.gestures
        if not g then return "" end
        -- (Read from the Gestures plugin's insides: a KOReader update may change them.)
        local n = try(function()
            local count = 0
            for __, s in ipairs(require("appsgestures").sections(g, g.ges_mode)) do count = count + #s.rows end
            return count
        end)
        if not n then return _("Taps and gestures") end
        return n == 1 and _("1 gesture set") or T(_("%1 gestures set"), n)
    elseif key == "library" then
        local home = G_reader_settings:readSetting("home_dir")
        return home and (home:match("([^/]+)/*$") or home) or _("Your books")
    elseif key == "ha" then
        local ha = self:plugin("homeassistant")
        if not (ha and ha.snap) then return ha and ha.api and ha.api:signedIn() and _("Open to load") or _("Not signed in") end
        return try(function()
            local HaModel = require("hamodel")
            local on = #HaModel.onNow(ha.snap, ha.prefs)
            local att = HaModel.attention(ha.snap, ha.prefs)
            return (on > 0 and T(_("%1 on"), on) or _("All off")) .. " · " .. att.text
        end) or ""
    elseif key == "dashboard" then
        local ha = self:plugin("homeassistant")
        local w = ha and ha.snap and ha.snap.weather
        if not w then return _("Clock, weather, cameras") end
        return try(function()
            local HaModel = require("hamodel")
            local text = HaModel.weather(w.state)
            local inside = HaModel.inside(ha.snap, ha.prefs)
            return (w.temp and HaModel.formatTemp(w.temp) .. " " or "") .. text ..
                (inside and (" · " .. T(_("inside %1"), HaModel.formatTemp(inside))) or "")
        end) or ""
    elseif key == "todo" then
        local todo = self:plugin("todo")
        if not (todo and todo.store) then return "" end
        return try(function()
            local s = require("todomodel").summary(todo.store:lists(), todo:today(), { hidden = todo:hiddenSet() })
            if s.today == 0 and s.overdue == 0 then
                return s.week > 0 and T(_("Nothing today · %1 this week"), s.week) or _("Nothing due")
            end
            return T(_("%1 today"), s.today) .. (s.overdue > 0 and (" · " .. T(_("%1 overdue"), s.overdue)) or "")
        end) or ""
    elseif key == "notes" then
        local notes = self:plugin("notes")
        if not (notes and notes.store) then return "" end
        return try(function() return notebooksLine(notes) end) or ""
    elseif key == "crosswords" then
        -- The Crosswords app: today's puzzle, as the crossword tile says it.
        local notes = self:plugin("notes")
        if not (notes and notes.todaysCrosswordInfo) then return "" end
        return try(function() return crosswordLine(notes, nil, true) end) or ""
    elseif key == "web" then
        local web = self:plugin("webpage")
        local address = web and web.address and web:address() or ""
        return address ~= "" and T(_("On · %1"), address) or _("Off · Tap to start")
    elseif key == "wifi" then
        return NetworkMgr:isWifiOn() and (NetworkMgr:isConnected() and _("Connected") or _("On")) or _("Off")
    elseif key == "exit" then
        return _("Back to the Kindle")
    elseif key == "restart" then
        return _("Close and open it again")
    elseif key == "light" then
        local powerd = Device:getPowerDevice()
        return try(function()
            if not powerd:isFrontlightOn() then return _("Off") end
            return T(_("On · %1"), powerd:frontlightIntensity())
        end) or ""
    elseif key == "night" then
        return KO.nightMode() and _("On") or _("Off")
    end
    return ""
end

-- ------------------------------------------------------------------ opening

function View:open(tile)
    self.away = true
    local key = tile.key
    require("appsswitcher").note(self.apps.settings, key)
    self.apps:save()
    local ui = self:ui()
    if tile.groupTile then
        self.away = false
        self.group, self.pageNo = tile.groupTile, 1
        self:render()
        UIManager:setDirty(self, "full")
        return
    elseif tile.pin and tile.pin.kind == "action" then
        self.away = false
        require("appsactions").run(tile.pin.id)
        UIManager:scheduleIn(1.5, function()
            lines[tile.key] = self:status(tile) or ""
            if UIManager:getTopmostVisibleWidget() == self then self:refresh() end
        end)
        return
    elseif tile.pin then
        local p = tile.pin
        if p.kind == "ha" then
            local ha = self:plugin("homeassistant")
            if ha then ha:show(p.route) end
        elseif p.kind == "todo" then
            local todo = self:plugin("todo")
            if todo then todo:show({ kind = "list", listId = p.id }) end
        elseif p.kind == "todoview" then
            local todo = self:plugin("todo")
            if todo and todo.showView then todo:showView(p.id) end
        elseif p.kind == "note" then
            local notes = self:plugin("notes")
            if notes then notes:open(p.id) end
        elseif p.kind == "crossword" then
            -- That source's newest crossword (downloaded first when needed).
            local notes = self:plugin("notes")
            if notes and notes.todaysCrossword then notes:todaysCrossword(p.id) end
        elseif p.kind == "notefolder" then
            -- Notes' list of notebooks, in that folder.
            local notes = self:plugin("notes")
            if notes then
                local exists = false
                for __, path in ipairs(notes.folders and notes.folders:all() or {}) do
                    if path == p.id then exists = true end
                end
                if not exists then
                    -- Renamed or deleted in Notes: not opened as an empty folder.
                    self.away = false
                    return require("appsko").toast(T(_("The folder “%1” is no longer in Notes. Hold the tile to remove it."), p.name), 4)
                end
                notes:openFolder(p.id)
                notes:show()
            end
        end
    elseif tile.event then
        if ui then ui:handleEvent(Event:new(tile.event)) end
    elseif key == "weather" then
        require("appsweather").open(self)
        return
    elseif key == "fonts" then
        self.away = false
        self.mode, self.fontsPage, self.fontsData = "fonts", 1, nil
        self:refresh()
        return
    elseif key == "readingtime" then
        -- Reading statistics, on this screen: every book's, and KOReader's calendar from there.
        self.away = false
        self.mode, self.statsPage, self.statsData = "stats", 1, nil
        self:render()
        UIManager:setDirty(self, "full")
        return
    elseif key == "reading" then
        local file = G_reader_settings:readSetting("lastfile")
        if not file then return end
        UIManager:close(self)
        require("appsreaderbar").openBook(file)
    elseif key == "library" then
        UIManager:close(self)
        -- The Library app (library.koplugin) when it's there and chosen; else KOReader's file browser.
        local PS = require("pluginshare")
        if PS.library and PS.library.isBrowser and PS.library.isBrowser() then
            PS.library.open()
            return
        end
        local ReaderUI = package.loaded["apps/reader/readerui"]
        if ReaderUI and ReaderUI.instance then
            ReaderUI.instance:onHome()
        elseif ui and ui.onHome then
            ui:onHome()
        end
    elseif key == "kosettings" then
        -- KOReader's own menu, open at its Settings (gear) tab; closing it comes back here.
        self.away = false
        local menu = ui and ui.menu
        if not (menu and menu.onShowMenu) then return end
        if menu.tab_item_table == nil and menu.setUpdateItemTable then menu:setUpdateItemTable() end
        local index
        for i, tab in ipairs(menu.tab_item_table or {}) do
            if tab.icon == "appbar.settings" then index = i end
        end
        menu:onShowMenu(index)
        return
    elseif key == "battery" then
        -- KOReader's battery statistics, on this screen.
        self.away = false
        self.mode, self.batteryPage = "battery", 1
        self:render()
        UIManager:setDirty(self, "full")
        return
    elseif key == "gestures" then
        -- What each gesture does, on this screen (KOReader's menus to change them).
        self.away = false
        self.mode, self.gesturesPage, self.gesturesMode = "gestures", 1, nil
        self:render()
        UIManager:setDirty(self, "full")
        return
    elseif key == "web" then
        local web = self:plugin("webpage")
        if web then
            if web:address() ~= "" then web:showAddress() else web:start() end
        end
    elseif key == "wifi" then
        -- Says what is happening at once (turning Wi-Fi off takes a few
        -- seconds on a Kindle), then the real state when KOReader is done.
        self.away = false
        local on = NetworkMgr:isWifiOn()
        lines.wifi = on and _("Turning off…") or _("Turning on…")
        self:refresh()
        local function done()
            lines.wifi = self:status(tile)
            self:refresh()
        end
        if on then
            NetworkMgr:toggleWifiOff(done, true)
        else
            NetworkMgr:toggleWifiOn(done, nil, true)
        end
        -- Cancelled or failed (KOReader then never calls back): the real state soon anyway.
        UIManager:scheduleIn(15, function()
            if lines.wifi == _("Turning off…") or lines.wifi == _("Turning on…") then done() end
        end)
        return
    elseif key == "light" then
        self.away = false
        KO.light()
        UIManager:scheduleIn(1, function() lines.light = self:status(tile) self:refresh() end)
        return
    elseif key == "night" then
        self.away = false
        KO.toggleNightMode(self:currentUI())
        lines.night = self:status(tile)
        self:render()
        UIManager:setDirty("all", "full")
        return
    elseif key == "restart" then
        self.away = false
        View.restart()
        return
    elseif key == "settings" then
        self.away = false
        self.mode, self.hubPage = "hub", 1
        self:refresh()
        return
    elseif key == "exit" then
        -- Asked first: a stray tap must not close KOReader. Then as KOReader's
        -- own Exit (its menu, the "Exit KOReader" gesture action) does it.
        self.away = false
        require("appsko").confirm{ text = _("Exit KOReader and go back to the Kindle?"), ok = _("Exit"), onOk = function()
                UIManager:broadcastEvent(Event:new("Exit"))
                -- The library or book closes (a book on the next tick). What
                -- else is open (KOReader's History list, these apps) would keep
                -- KOReader running until closed by hand: closed too.
                UIManager:scheduleIn(0.3, function()
                    local FileManager = require("apps/filemanager/filemanager")
                    local ReaderUI = require("apps/reader/readerui")
                    for __ = 1, 50 do
                        local top = UIManager._window_stack[#UIManager._window_stack]
                        if not top then break end
                        local w = top.widget
                        if w == FileManager.instance or w == ReaderUI.instance then
                            w:onClose()
                        else
                            UIManager:close(w)
                        end
                    end
                end)
            end }
        return
    end
    UIManager:scheduleIn(1, function() self:refresh() end)
end

function View:tileMenu(tile, tiles)
    local dialog
    local s = self.apps.settings
    local function save(order)
        s.order = order
        self.apps:save()
        UIManager:close(dialog)
        self:refresh()
    end
    local function move(delta)
        save(Model.moveAmong(keysOf(self:tiles(true)), keysOf(self:tiles()), tile.key, delta))
    end
    -- (In a group sorted A–Z the order is the names': no moving.)
    local open = self.group and groupOf(s, self.group)
    local buttons = {}
    if not (open and open.sort == "az") then
        table.insert(buttons, { { text = _("Move up"), callback = function() move(-1) end },
          { text = _("Move down"), callback = function() move(1) end } })
    end
    if tile.groupTile then
        table.insert(buttons, { { text = _("Rename group"), callback = function()
            UIManager:close(dialog)
            self:askName(_("Rename group"), tile.name, function(name)
                local g = groupOf(s, tile.groupTile)
                if g then g.name = name end
                self.apps:save()
                self:refresh()
            end)
        end } })
        -- Its tiles in the order you put them, or by name.
        table.insert(buttons, { { text = _("Sort…"), callback = function()
            UIManager:close(dialog)
            local g = groupOf(s, tile.groupTile)
            if not g then return end
            KO.choose(_("Sort"), { { label = _("Custom"), value = "custom" }, { label = _("A–Z"), value = "az" } },
                g.sort == "az" and "az" or "custom", function(v)
                    g.sort = v == "az" and "az" or nil
                    self.apps:save()
                    self:refresh()
                end)
        end } })
        table.insert(buttons, { { text = _("Change icon"), callback = function()
            UIManager:close(dialog)
            self.mode, self.iconGroup, self.iconsPage = "icons", tile.groupTile, 1
            self:render()
            UIManager:setDirty(self, "full")
        end } })
        table.insert(buttons, { { text = _("Delete group"), callback = function()
            -- Its tiles go back to the main page (Undo puts it back).
            self:withUndo(T(_("Deleted %1"), tile.name), function()
                for k, g in pairs(s.grouped or {}) do
                    if g == tile.groupTile then s.grouped[k] = nil end
                end
                local kept = {}
                for __, g in ipairs(s.groups or {}) do if g.id ~= tile.groupTile then table.insert(kept, g) end end
                s.groups = kept
                save(s.order)
            end)
        end } })
    else
        table.insert(buttons, { { text = _("Move to a group…"), callback = function()
            UIManager:close(dialog)
            self:groupMenu(tile)
        end } })
        table.insert(buttons, { { text = tile.pin and _("Remove") or _("Hide"), callback = function()
            self:withUndo(tile.pin and T(_("Removed %1"), _(tile.name)) or T(_("Hid %1"), _(tile.name)), function()
                if tile.pin then
                    s.pins = Model.removePin(s.pins, tile.key)
                else
                    s.hidden = s.hidden or {}
                    s.hidden[tile.key] = true
                end
                save(s.order)
            end)
        end } })
    end
    table.insert(buttons, { { text = _("Edit home screen"), callback = function()
        UIManager:close(dialog)
        self.mode, self.arrangePart, self.arrangePage = "arrange", "tiles", 1
        self:refresh()
    end } })
    table.insert(buttons, { { text = _("Close"), callback = function() UIManager:close(dialog) end } })
    dialog = require("appsko").buttonDialog{ title = _(tile.name), title_align = "center", buttons = buttons }
end

--- Runs `change` (a tile, shortcut or group removed), then offers Undo for a
-- few seconds: the tiles, shortcuts and groups as they were before.
function View:withUndo(text, change)
    local s = self.apps.settings
    local copy = require("util").tableDeepCopy
    local before = {}
    for __, k in ipairs({ "order", "pins", "hidden", "groups", "grouped" }) do
        before[k] = s[k] ~= nil and copy(s[k]) or false
    end
    change()
    KO.undo(text, function()
        for k, v in pairs(before) do s[k] = v or nil end
        self.apps:save()
        self:refresh()
    end)
end

function View:askName(title, value, done)
    require("appsko").askText{ title = title, text = value, kind = "name", needsText = true, done = done }
end

--- Suggested groups: each that can be made now (Model.suggestions), with its tiles; a tap
-- asks, then makes it (hidden tiles in it show again). `back`: the menu it came from.
function View:suggestGroups(back)
    local s = self.apps.settings
    local list = Model.suggestions(self:tiles(true), s.groups, s.grouped)
    if #list == 0 then
        return KO.message(_("No suggestions left: each one's apps are already in groups, or a group has its name."))
    end
    local items = {}
    for __, x in ipairs(list) do
        local names = {}
        for __, t in ipairs(x.tiles) do table.insert(names, _(t.name)) end
        local joined = table.concat(names, ", ")
        table.insert(items, { text = T(_("%1: %2"), _(x.group.name), joined), fn = function()
            KO.confirm{ text = T(_("Make a group called %1 with %2?"), _(x.group.name), joined), ok = _("Make group"),
                onOk = function()
                    local id = tostring(os.time()) .. tostring(math.random(100, 999))
                    s.groups = s.groups or {}
                    table.insert(s.groups, { id = id, name = _(x.group.name), icon = x.group.icon, sort = "az" })
                    s.grouped, s.hidden = s.grouped or {}, s.hidden or {}
                    for __, t in ipairs(x.tiles) do
                        s.grouped[t.key] = id
                        -- (One hidden to start with stays shown with false; the others by no entry.)
                        if Model.isHidden(s.hidden, t) then
                            if t.offByDefault then s.hidden[t.key] = false else s.hidden[t.key] = nil end
                        end
                    end
                    self.apps:save()
                    self:refresh()
                    KO.toast(T(_("Made the group %1"), _(x.group.name)))
                end }
        end })
    end
    KO.list(_("Suggested groups"), items, back)
end

--- The tiles' order, shortcuts, hidden tiles and groups, saved as they are (in the launcher's
-- settings, so backups keep it too), and put back later (with Undo).
local HOME_KEYS = { "order", "pins", "hidden", "groups", "grouped" }
function View:savedHomeScreen()
    local s = self.apps.settings
    local copy = require("util").tableDeepCopy
    KO.list(_("Saved home screen"), {
        { text = _("Save the home screen now"), fn = function()
            local saved = { at = os.time() }
            for __, k in ipairs(HOME_KEYS) do saved[k] = s[k] ~= nil and copy(s[k]) or false end
            s.home_saved = saved
            self.apps:save()
            self:refresh()
            KO.toast(_("Home screen saved"))
        end },
        { text = s.home_saved and T(_("Put back the one saved %1"), os.date("%b %d, %H:%M", s.home_saved.at)) or _("Put back the saved one"),
            enabled = s.home_saved ~= nil, fn = function()
                self:withUndo(_("Saved home screen put back"), function()
                    for __, k in ipairs(HOME_KEYS) do s[k] = s.home_saved[k] and copy(s.home_saved[k]) or nil end
                    self.apps:save()
                    self:refresh()
                end)
            end },
    })
end

--- A tile into a group (a new one, or one made before), or back to the main page.
function View:groupMenu(tile)
    local s = self.apps.settings
    local dialog
    local current = s.grouped and s.grouped[tile.key]
    local function put(id)
        UIManager:close(dialog)
        s.grouped = s.grouped or {}
        s.grouped[tile.key] = id
        self.apps:save()
        self:refresh()
    end
    local buttons = {}
    for __, g in ipairs(s.groups or {}) do
        table.insert(buttons, { { text = (g.id == current and "✓ " or "") .. g.name, callback = function() put(g.id) end } })
    end
    table.insert(buttons, { { text = _("Suggested groups…"), callback = function()
        UIManager:close(dialog)
        self:suggestGroups()
    end } })
    table.insert(buttons, { { text = _("New group…"), callback = function()
        UIManager:close(dialog)
        self:askName(_("New group"), "", function(name)
            s.groups = s.groups or {}
            local id = tostring(os.time()) .. tostring(math.random(100, 999))
            table.insert(s.groups, { id = id, name = name })
            s.grouped = s.grouped or {}
            s.grouped[tile.key] = id
            self.apps:save()
            self:refresh()
        end)
    end } })
    if current then
        table.insert(buttons, { { text = _("Main page"), callback = function() put(nil) end } })
    end
    table.insert(buttons, { { text = _("Close"), callback = function() UIManager:close(dialog) end } })
    dialog = require("appsko").buttonDialog{ title = _("Move to a group"), title_align = "center", buttons = buttons }
end


-- ------------------------------------------------------------------ turning the reader

-- The reader turned (its accelerometer): KOReader's own screen turns too, and
-- this one is laid out again for the new shape.
function View:onSetRotationMode(mode)
    local ui = self:currentUI()
    if ui then ui:handleEvent(Event:new("SetRotationMode", mode)) end
    if Screen:getRotationMode() ~= mode then Screen:setRotationMode(mode) end
    self:relayout()
    UIManager:setDirty("all", "full")
    return true
end

-- Sizes and tap areas from the screen as it is now.
function View:relayout()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    for __, g in pairs(self.ges_events or {}) do
        if g[1] and g[1].range then g[1].range = all end
    end
    self.pageNo, self.arrangePage = 1, 1
    self:render()
end

-- Another screen of ours on top turned the reader: this one catches up when shown again.
function View:checkSize()
    if self.w ~= Screen:getWidth() or self.h ~= Screen:getHeight() then self:relayout() end
end

-- ------------------------------------------------------------------ gestures, drawing

function View:onTap(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and hit.tap then hit.tap() end
    return true
end

function View:onHold(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit then (hit.hold or hit.tap or function() end)() end
    return true
end

-- ------------------------------------------------------------------ KOReader's gestures

-- Gestures this screen does not use go to KOReader's Gestures plugin (the
-- light, night mode, your QuickMenus...), and the events their actions send
-- go on to the library or book underneath.
function View:onGesture(ev)
    if KO.passGesture(self:currentUI(), ev, KO.allowed) then return true end
    return InputContainer.onGesture(self, ev)
end

function View:handleEvent(event)
    if InputContainer.handleEvent(self, event) then return true end
    return KO.passEvent(self:currentUI(), event)
end

-- A swipe turns the page; a diagonal one (as in KOReader) flashes the screen clean.
function View:onSwipe(_, ges)
    local d = ges.direction
    if d == "northeast" or d == "northwest" or d == "southeast" or d == "southwest" then
        UIManager:setDirty(self, "full")
    elseif KO.fromLeftEdge(ges) then
        -- In from the left edge: Back, as in every app.
        self:onClose()
    elseif d == "west" or d == "north" then
        self:turn(1)
    elseif d == "east" or d == "south" then
        self:turn(-1)
    end
    return true
end

function View:turn(delta)
    local key = self.mode == "tiles" and "pageNo" or (self.mode .. "Page")
    local n = math.max(1, math.min(self.pages or 1, self[key] + delta))
    if n == self[key] then return end
    self[key] = n
    self:render()
    UIManager:setDirty(self, "full")
end

--- "‹ 1/2 ›" centred at y, tappable on each side.
function View:pager(c, cx, y)
    local label = T("%1/%2", self.mode == "tiles" and self.pageNo or self[self.mode .. "Page"], self.pages)
    local lw = c:width(label, 11) + 44
    c:icon("chevron-left", cx - lw / 2, y - 13, 16)
    c:text(cx, y, label, 11, { align = "middle", color = C.GREY })
    c:icon("chevron-right", cx + lw / 2 - 16, y - 13, 16)
    c:hit(cx - lw / 2 - 16, y - 24, lw / 2 + 16, 36, function() self:turn(-1) end)
    c:hit(cx, y - 24, lw / 2 + 16, 36, function() self:turn(1) end)
end

local HELP = [[
THE LAUNCHER
• Tap a tile to open it. Hold a tile to move, hide or remove it, or to put it in a group (a tile that opens its own page).
• Under the clock: the weather, what is next and the tasks due; then buttons for Wi-Fi, the light, night mode and a refresh.
• Hold a recent book to mark it finished, take it out of the history or open its folder.
• Swipe left or right to turn the page.
• Swipe diagonally to refresh the screen.
• At the top right: refresh (the lines again and a full screen refresh), the bell (notifications from every app; the count is how many are new) and ⋮ (the light, night mode, screen refresh, this help, and Settings: the launcher's tiles and shortcuts, its layout and the sleep screen).
• To leave, open Library or a book, or tap Exit KOReader.
• In any app, tap the time and battery at the top for the control center (Wi-Fi, light, night mode, Keep awake…). ⋮ > Recent apps shows what you opened lately. Swipe in from the left edge to go back.
• The magnifying glass searches books, notebooks, tasks and devices.
• In a book or the library, tap the top for the same bar as the apps: back, the house (the launcher), the time, refresh, the bell and ⋮ (KOReader's menu and the book's contents, bookmarks and search). Launcher settings > Title bar in books turns it off.

HOME ASSISTANT, TO DO AND THE OTHER APPS
• The same bar at the top of each: ‹ goes back (from an app's first screen, to the launcher), the house goes to the launcher; at the right the app's own buttons, the time and battery, refresh, the bell and ⋮ (Settings is its last item).
• Swipe left or right to turn the page.
• Hold an item for more options.
• ⋮ has the light, night mode, screen refresh, Add to launcher and Settings.
• On the dashboard: tap the time or the status line to close it, the weather for the forecast, ⚙ for the settings.

YOUR KOREADER GESTURES
• The two-finger swipes, edge swipes and multiswipes set in KOReader also work here, for the light, warmth, night mode, refresh, Wi-Fi and these apps.
• Gestures for folders and books only work in the library or a book.]]

function View:showHelp()
    UIManager:show(require("ui/widget/textviewer"):new{ title = _("Help"), text = _(HELP) })
end

function View:leaveGroup()
    self.group, self.pageNo = nil, 1
    self:render()
    UIManager:setDirty(self, "full")
end

function View:onClose()
    -- Shown over another app (the switcher, Settings): back to it.
    if self.mode ~= "tiles" and self.switcherBack and (self.mode == "switcher" or self.mode == "hub" or self.mode == "search") then
        self.switcherBack, self.mode = nil, "tiles"
        UIManager:close(self)
        return true
    end
    if self.mode == "page" then
        -- A page opened from another: back to it.
        local spec = self.pageSpec
        if spec and spec.back then
            spec.back()
            return true
        end
        -- Opened from another app (an app's own settings): back to it.
        if self.switcherBack then
            self.switcherBack, self.mode, self.pageSpec = nil, "tiles", nil
            UIManager:close(self)
            return true
        end
        self.mode, self.pageSpec = "hub", nil
        self:refresh()
        return true
    end
    if self.mode == "arrange" then
        self.mode, self.orderUndo = "hub", nil
        self:refresh()
        return true
    end
    if self.mode == "fontsget" then
        -- Get fonts: back to Fonts.
        self.mode = "fonts"
        self:refresh()
        return true
    end
    if self.backTo and self.mode ~= "tiles" then
        -- Opened from Settings: back there.
        self.mode, self.backTo = self.backTo, nil
        self:refresh()
        return true
    end
    if self.mode == "statsbook" then
        -- A book's reading statistics: back to every book's.
        self.mode = "stats"
        self:refresh()
        return true
    end
    if self.mode ~= "tiles" then
        self.mode, self.orderUndo = "tiles", nil
        self:refresh()
    elseif self.group then
        self:leaveGroup()
    else
        UIManager:close(self)
    end
    return true
end



-- Once per KOReader start: if it ended badly last time (a crash, or stopped
-- without closing: a freeze), say so (the web server's diagnostics read it).
local checkedEnding = false
local function noticeLastEnding()
    if checkedEnding then return end
    checkedEnding = true
    local ok, Diag = pcall(require, "webdiag")
    if not ok then return end
    local okE, e = pcall(Diag.lastEnding)
    if not (okE and e and e.time) then return end
    local when = (os.date("%a %b %d, %I:%M %p", e.time):gsub(" 0", " "))
    require("appsko").message(e.kind == "crash"
        and T(_("KOReader crashed last time, at %1.\n\nThe web page's System tab (Problems) has the details."), when)
        or T(_("KOReader stopped without closing last time, at %1 (it may have frozen).\n\nThe web page's System tab (Problems) has the details."), when))
end

function View:onShow()
    UIManager:scheduleIn(1, noticeLastEnding)
    KO.flashOnUncover()
    self:scheduleClock()
    UIManager:nextTick(function() self:updateLines() end)
    return true
end

--- The web server started or stopped (from here, a menu, a gesture or by
-- itself): its quick button and tile follow.
function View:onWebServerChanged()
    self:refresh()
end

function View:onCloseWidget()
    self.closed = true
    if self.clockTask then UIManager:unschedule(self.clockTask) end
    self.clockTask = nil
    if self.on_close then self.on_close() end
    UIManager:setDirty(nil, "full")
end

-- Each minute: the clock (and the tiles' lines) again, while the launcher is on top.
function View:scheduleClock()
    if self.clockTask then UIManager:unschedule(self.clockTask) end
    self.clockTask = function()
        if UIManager:getTopmostVisibleWidget() == self then self:refresh() end
        self:scheduleClock()
    end
    UIManager:scheduleIn(60 - os.date("*t").sec + 1, self.clockTask)
end

-- Every few updates the screen flashes, clearing e-ink's ghosts of earlier
-- screens; so does an update that moves things (tiles came or went).
function View:refresh()
    local before = KO.layoutOf(self.canvas)
    self:render()
    self.updates = (self.updates or 0) + 1
    local moved = before ~= KO.layoutOf(self.canvas)
    UIManager:setDirty(self, (moved or self.updates % 8 == 0) and "full" or "ui")
end

--- A notification came or went: the bell's badge.
function View:notificationsChanged()
    if UIManager:getTopmostVisibleWidget() == self then
        self:render()
        UIManager:setDirty(self, "ui")
    end
end

--- ⟳: the tiles' lines worked out again, and a full refresh.
function View:reload()
    self.statsData = nil
    self:render()
    UIManager:setDirty(self, "full")
    UIManager:nextTick(function() self:updateLines() end)
end

--- The ⋮ menu: the web page, Restart, Help, KOReader's light and night mode, Settings last.
function View:moreMenu()
    local extra = {}
    -- The launcher's settings on the phone: the web server started, a QR code to scan.
    local web = self:plugin("webpage")
    if web and web.openOnWeb then table.insert(extra, { _("Open on the web page"), function() web:openOnWeb("apps") end }) end
    table.insert(extra, { _("Restart KOReader"), function() View.restart() end })
    table.insert(extra, { _("Help"), function() self:showHelp() end })
    KO.menu(self:currentUI(), self, extra, function() self.mode, self.hubPage = "hub", 1 self:refresh() end)
end

--- The title bar of the launcher's own screens (Settings, Gestures,
-- Battery): ‹ and ⌂ both back to the tiles.
function View:bar(c, title, buttons)
    local function home()
        self.backTo = nil
        if self.switcherBack then return self:onClose() end
        self.mode, self.orderUndo, self.arrangePage = "tiles", nil, 1
        self:refresh()
    end
    -- Apps' settings, opened from the list of every app's: back to the list.
    local back = self.mode == "arrange" and function() self.mode, self.orderUndo = "hub", nil self:refresh() end
        or (self.mode == "statsbook" or self.mode == "fontsget" or self.backTo) and function() self:onClose() end or home
    Bar.draw(c, {
        title = title,
        back = back, home = home,
        buttons = buttons,
        pager = { page = self[self.mode .. "Page"] or 1, pages = self.pages or 1, turn = function(d) self:turn(d) end },
        clock = true,
        refresh = function() self:reload() end,
        bell = require("pluginshare").showNotifications and function() self:showNotifications() end or nil,
        menu = function() self:moreMenu() end,
    })
end

--- Which parts the Apps widgets sleep screen shows (ticked ones; a tap turns one on or off).
function View:widgetsMenu()
    local s = self.apps.settings
    local items = {}
    for __, k in ipairs(View.widgetOrder(s)) do
        table.insert(items, { text = View.WIDGET_NAMES[k], checked = View.widgetOn(s, k), fn = function()
            s.sleep_widgets = s.sleep_widgets or {}
            s.sleep_widgets[k] = not View.widgetOn(s, k)
            self.apps:save()
            self:refresh()
            UIManager:nextTick(function() self:widgetsMenu() end)
        end })
    end
    KO.list(_("Widgets"), items)
end

function View:showNotifications()
    local PS = require("pluginshare")
    if PS.showNotifications then PS.showNotifications() end
end

function View:paintTo(bb, x, y)
    self:checkSize()
    -- Back from an app: the time drawn fresh, and the lines worked out again.
    if self.away then
        self.away = false
        self:render()
        UIManager:nextTick(function() self:updateLines() end)
    end
    -- Settings drawn here: their values as they are now (a dialog over them may have changed one).
    if self.mode == "page" or self.mode == "hub" then self:render() end
    bb:paintRect(x, y, self.w, self.h, self.canvas and self.canvas:background() or Blitbuffer.COLOR_WHITE)
    if self.canvas then self.canvas:paint(bb, x, y) end
end

function View:render()
    if self.canvas then self.canvas:release() end
    self.dithered = nil
    local c = Canvas.new(self.w, self.h, false)
    c.turn = function(d) self:turn(d) end
    self.canvas = c
    self.renderedAt = os.time()
    if self.mode == "arrange" then self:drawArrange(c)
    elseif self.mode == "gestures" then require("appsgestures").draw(self, c)
    elseif self.mode == "battery" then require("appsbattery").draw(self, c)
    elseif self.mode == "stats" then require("appsstats").draw(self, c)
    elseif self.mode == "statsbook" then require("appsstats").drawBook(self, c)
    elseif self.mode == "icons" then require("appsicons").draw(self, c)
    elseif self.mode == "weather" then require("appsweather").draw(self, c)
    elseif self.mode == "fonts" then require("appsfontsview").draw(self, c)
    elseif self.mode == "fontsget" then require("appsfontsview").drawGet(self, c)
    elseif self.mode == "quick" then require("appsquick").drawEditor(self, c)
    elseif self.mode == "conntest" then require("appstest").draw(self, c)
    elseif self.mode == "switcher" then require("appsswitcher").draw(self, c)
    elseif self.mode == "hub" then require("appshub").draw(self, c)
    elseif self.mode == "search" then require("appssearch").draw(self, c)
    elseif self.mode == "page" then require("appshub").drawPage(self, c)
    else self:drawTiles(c) end
end

function View:header(c)
    local s = self.apps.settings
    local now = os.date("*t")
    local twelve = not KO.twentyFour()
    local hour = twelve and ((now.hour + 11) % 12 + 1) or now.hour
    -- On its side the clock is always one line: there's little height to spare.
    local small = s.clock == "small" or c.W > c.H
    local clock = string.format(twelve and "%d:%02d" or "%02d:%02d", hour, now.min)
    if small then
        -- One line: the time, then the date (more room for the rest).
        local w = c:text(28, 50, clock, 26, { bold = true }) or 0
        local x = 28 + w + 6
        if twelve then x = x + (c:text(x, 50, now.hour < 12 and "AM" or "PM", 12, { bold = true }) or 0) end
        c:text(x + 14, 50, os.date("%a, %b ") .. now.day, 13, { color = C.GREY })
    else
        local w = c:text(28, 84, clock, 60, { bold = true })
        if twelve then c:text(28 + w + 8, 84, now.hour < 12 and "AM" or "PM", 18, { bold = true }) end
        c:text(30, 112, os.date("%A, %B ") .. now.day, 14, { color = C.GREY })
    end
    -- The top right, one line level with the clock, as in every app's title
    -- bar: the battery and Wi-Fi (each icon just left of its label), ⟳, 🔔
    -- and the ⋮ menu (Settings last).
    local right = c.W - 28
    local y = small and 32 or 52
    c:icon("ellipsis-vertical", right - 22, y - 1, 22)
    c:hit(right - 34, y - 12, 46, 44, function() self:moreMenu() end)
    local x = right - 56
    if require("pluginshare").showNotifications then
        c:icon("bell", x, y - 1, 22)
        local n = Bar.unread()
        if n > 0 then
            local s = n > 99 and "99+" or tostring(n)
            local bw = math.max(16, c:width(s, 9, true) + 7)
            c:box(x + 12, y - 8, bw, 16, { r = 8, fill = C.FILL })
            c:text(x + 12 + bw / 2, y + 4, s, 9, { bold = true, align = "middle", color = C.ON_FILL })
        end
        c:hit(x - 5, y - 12, 32, 44, function() self:showNotifications() end)
        x = x - 32
    end
    c:icon("refresh-cw", x, y - 1, 22)
    c:hit(x - 5, y - 12, 32, 44, function() self:reload() end)
    -- Search everything (books, notebooks, tasks, devices…).
    x = x - 32
    c:icon("search", x, y - 1, 22)
    c:hit(x - 5, y - 12, 32, 44, function() require("appssearch").ask(self) end)
    x = x - 18
    -- ▾: a tap on the battery and Wi-Fi drops down the control center.
    local ccRight = x + 4
    if require("pluginshare").showControlCenter then
        c:icon("chevron-down", x - 14, y + 4, 14)
        x = x - 18
    end
    local function status(icon, label)
        local tw = c:width(label, 13)
        c:text(x, y + 15, label, 13, { align = "end" })
        x = x - tw - 25
        c:icon(icon, x, y, 20)
        local at = x
        x = x - 12
        return at
    end
    local statusRight = ccRight
    status(NetworkMgr:isWifiOn() and "wifi" or "wifi-off", NetworkMgr:isWifiOn() and _("Wi-Fi") or _("Off"))
    local powerd = Device:getPowerDevice()
    local battery = powerd and try(function() return powerd:getCapacity() end)
    local charging = powerd and try(function() return powerd:isCharging() end)
    if battery then
        local bx = status(charging and "battery-charging" or "battery", battery .. "%")
        if not charging then
            -- Filled as far as it is charged (inside Lucide's outline: 3..17 by 7..17 of 24).
            local k = 20 / 24
            local fill = math.max(0, math.min(100, battery)) / 100
            if fill > 0 then c:box(bx + 4.5 * k, y + 8.5 * k, 11 * k * fill, 7 * k, { fill = C.BLACK }) end
        end
    end
    -- What's running now (an ongoing notification: the web server…): its icon.
    local PS = require("pluginshare")
    for __, icon in ipairs(PS.statusIcons and PS.statusIcons() or {}) do
        c:icon(icon, x - 20, y, 20)
        x = x - 26
    end
    -- A tap on the battery and Wi-Fi: the control center (light, Wi-Fi, night mode…).
    if require("pluginshare").showControlCenter then
        c:hit(x, y - 12, statusRight - x, 44, function() require("pluginshare").showControlCenter() end)
    end
    c:hline(28, small and 68 or 132, c.W - 56, C.BLACK, 2)
    return small and 88 or 152
end

--- The tiles of the page shown (the main page or a group's); with
-- `withHidden`, every tile, hidden and grouped ones too (Settings).
function View:tiles(withHidden)
    local s = self.apps.settings
    local ui = self:ui()
    local all = Model.tiles(s.order, s.hidden, self.apps.has(ui), withHidden, s.pins, s.groups)
    if withHidden then return all end
    return Model.page(all, s.groups, s.grouped, self.group, self:quickShown())
end

function View:togglesOn() return self.apps.settings.toggles ~= false end

--- The quick buttons that show (a set of keys), or nil when the row is off
-- (or has none).
function View:quickShown()
    local s = self.apps.settings
    if not self:togglesOn() then return nil end
    local list = Model.quickList(s)
    if #list == 0 then return nil end
    -- The tiles their buttons do (Wi-Fi, Light, Night mode, Web server) are left off the main page.
    local out = Model.quickTiles(list)
    if out.light and not KO.hasLight() then out.light = nil end
    if out.web and not self:plugin("webpage") then out.web = nil end
    return out
end

--- "Off", "After 5 min" (Turn off Wi-Fi when idle).
function View.wifiIdleName(minutes)
    return (minutes and minutes ~= 0) and T(_("After %1 min"), minutes) or _("Off")
end

--- Restarts KOReader (asked first), as its own Restart does.
function View.restart()
    if Device.canRestart and not Device:canRestart() then
        return require("appsko").message(_("KOReader can't restart itself on this device. Exit and open it again."))
    end
    require("appsko").confirm{ text = _("Restart KOReader?"), ok = _("Restart"), onOk = function() UIManager:restartKOReader() end }
end

local function iconOf(tile)
    if tile.icon == "wifi" then return NetworkMgr:isWifiOn() and "wifi" or "wifi-off" end
    return tile.icon
end

View.LAYOUTS = { "tiles", "bold", "compact", "list", "icons" }
View.LAYOUT_NAMES = { tiles = _("Tiles"), bold = _("Bold tiles"), compact = _("Compact"), list = _("List"), icons = _("Icons") }

-- Book covers (from the cover browser plugin, when it has them), scaled once.
local covers = {}

local coverRetry = {}
local function cover(file, w, h)
    local key = file .. "@" .. w .. "x" .. h
    -- (A book not read yet is asked about again after a minute, not on every
    -- drawing: each look can wait on the Cover browser's database.)
    if covers[key] == nil and (coverRetry[key] or 0) <= os.time() then
        local ok, BIM = pcall(require, "bookinfomanager")
        if not (ok and BIM and BIM.getBookInfo) then
            covers[key] = false
        else
            local got, info = pcall(BIM.getBookInfo, BIM, file, true)
            if got and info and info.cover_bb then
                -- Fitted inside the card's space, keeping its shape (the copy given is freed).
                local bw, bh = info.cover_bb:getWidth(), info.cover_bb:getHeight()
                local k = math.min(w / bw, h / bh)
                local RenderImage = require("ui/renderimage")
                covers[key] = RenderImage:scaleBlitBuffer(info.cover_bb, math.max(1, math.floor(bw * k)), math.max(1, math.floor(bh * k)), true) or false
            elseif got and info and info.cover_fetched then
                covers[key] = false   -- read, and it has none
            end
            -- Not read yet: asked again in a minute.
            if covers[key] == nil then coverRetry[key] = os.time() + 60 end
        end
    end
    return covers[key] or nil
end

-- A small picture from a file (a notebook's cover, a crossword's grid), fitted
-- inside w x h pixels; kept until the file changes.
local pictures = {}
local function picture(path, w, h)
    if not path then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local t = lfs.attributes(path, "modification")
    if not t then return nil end
    local key = path .. "@" .. w .. "x" .. h
    local had = pictures[key]
    if had and had.t == t then return had.bb end
    if had and had.bb then had.bb:free() end
    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false)
    local out = false
    if ok and bb then
        local bw, bh = bb:getWidth(), bb:getHeight()
        local k = math.min(w / bw, h / bh)
        out = RenderImage:scaleBlitBuffer(bb, math.max(1, math.floor(bw * k)), math.max(1, math.floor(bh * k)), true) or false
    end
    pictures[key] = { t = t, bb = out }
    return out or nil
end

--- A row of cards under a heading: each { title, line, bar (0-100) or nil,
-- image (a blitbuffer) or nil, icon, tap, hold }; `n` of them, `w` wide,
-- from `x0`. Returns its height.
function View:cardRow(c, top, heading, cards, x0, n, w)
    if #cards == 0 then return 0 end
    local gap = 12
    c:text(x0, top + 6, heading, 9.5, { bold = true, color = C.GREY })
    local y = top + 15
    local cw, ch = 40, 58
    for i = 1, n do
        local card = cards[i]
        local x = x0 + (i - 1) * (w + gap)
        local bb = card.image and card.image(c:X(cw), c:X(ch))
        if bb then
            local iw, ih = bb:getWidth() / c.u, bb:getHeight() / c.u
            local ix, iy = x + (cw - iw) / 2, y + 2 + (ch - ih) / 2
            c:image(bb, ix, iy)
            -- A picture: refreshed with the screen's own dithering.
            self.dithered = true
            c:box(ix, iy, iw, ih, { border = C.BLACK })
        else
            c:box(x, y + 2, cw, ch, { r = 4, border = C.BLACK })
            c:icon(card.icon, x + cw / 2 - 10, y + 2 + ch / 2 - 10, 20)
        end
        local tx, tw = x + cw + 9, w - cw - 9
        c:text(tx, y + 18, card.title, 11, { bold = true, maxw = tw })
        if card.line then c:text(tx, y + 35, card.line, 9.5, { color = C.GREY, maxw = tw }) end
        if card.bar then
            c:box(tx, y + 44, tw, 6, { r = 3, border = C.BLACK })
            if card.bar > 0 then c:box(tx + 1, y + 45, (tw - 2) * math.min(100, card.bar) / 100, 4, { r = 2, fill = C.BLACK }) end
        end
        c:hit(x, y, w, ch + 4, card.tap, card.hold)
    end
    return 81
end

--- The recent books row's cards (cover or title, how far read).
function View:recentCards()
    if self.apps.settings.recent == false then return {} end
    local cards = {}
    for __, b in ipairs(recent) do
        local line = b.finished and _("Finished") or (b.percent and T(_("%1% read"), b.percent)) or _("Not started")
        table.insert(cards, { title = b.title, line = line, bar = not b.finished and b.percent or nil, icon = "book-open",
            image = function(w, h) return cover(b.file, w, h) end,
            tap = function() self:openBook(b.file) end, hold = function() self:bookMenu(b) end })
    end
    return cards
end

--- Notes' recent notebooks and crosswords, as Notes gives them: { list, sig }
-- each (sig changes when something shown changes). Empty when turned off.
function View:readRecentNotes()
    local s = self.apps.settings
    local notes = self:plugin("notes")
    local hidden = s.recent_hidden or {}
    local function read(on, fn, sig)
        if not (on and notes and notes[fn]) then return { list = {}, sig = "" } end
        local ok, list = pcall(notes[fn], notes, 10)
        if not ok or type(list) ~= "table" then return { list = {}, sig = "" } end
        local shown, parts = {}, {}
        for __, e in ipairs(list) do
            local key, stamp = View.recentKey(e)
            local h = hidden[key]
            if h and (type(h) == "table" and h.stamp or h) ~= stamp then
                -- Changed since: back on its row.
                hidden[key] = nil
                h = nil
                self.apps:save()
            end
            if #shown < 5 and not h then
                table.insert(shown, e)
                table.insert(parts, sig(e))
            end
        end
        return { list = shown, sig = table.concat(parts, "|") }
    end
    return read(s.recent_notes ~= false, "recentNotebooks", function(e)
            return tostring(e.id) .. tostring(e.name) .. tostring(e.modified) .. tostring(e.locked) .. tostring(e.cover) end),
        read(s.recent_crosswords ~= false, "recentCrosswords", function(e)
            return tostring(e.book) .. ":" .. tostring(e.page) .. tostring(e.state) .. tostring(e.solved) .. tostring(e.thumb) end)
end

--- A recent notebook's or crossword's key, and what it was like when taken
-- off the recent rows: it comes back once edited (or solved further).
function View.recentKey(e)
    if e.book then return "c:" .. tostring(e.book) .. ":" .. tostring(e.page), tostring(e.state) .. ":" .. tostring(e.solved) end
    return "n:" .. tostring(e.id), tostring(e.modified)
end

--- How many entries a table has.
function View.count(t)
    local n = 0
    for __ in pairs(t or {}) do n = n + 1 end
    return n
end

--- Takes a notebook or crossword off the recent rows (until it changes).
function View:hideRecent(e)
    local s = self.apps.settings
    local key, stamp = View.recentKey(e)
    s.recent_hidden = s.recent_hidden or {}
    s.recent_hidden[key] = { stamp = stamp, name = e.name }
    self.apps:save()
    recentNotes, recentPuzzles = self:readRecentNotes()
    self:refresh()
end

--- The recent notebooks row's cards (Notes): its first page, its name, when edited.
function View:notebookCards()
    if self.apps.settings.recent_notes == false then return {} end
    local cards = {}
    for __, n in ipairs(recentNotes.list or {}) do
        local line = n.modified and n.modified > 0 and T(_("Edited %1"), os.date("%b %d", n.modified):gsub(" 0", " ")) or nil
        table.insert(cards, { title = n.name or "", line = line, icon = n.locked and "lock" or "notebook-pen",
            image = not n.locked and n.cover and function(w, h) return picture(n.cover, w, h) end or nil,
            tap = function() self:openNotebook(n.id) end, hold = function() self:notebookMenu(n) end })
    end
    return cards
end

--- The recent crosswords row's cards (Notes' puzzle books): the grid, its name, how far solved.
function View:crosswordCards()
    if self.apps.settings.recent_crosswords == false then return {} end
    local states = { new = _("New"), started = _("Started"), done = _("Done") }
    local cards = {}
    for __, p in ipairs(recentPuzzles.list or {}) do
        local line = states[p.state] or ""
        local bar
        if tonumber(p.total) and p.total > 0 and p.state ~= "done" then
            line = T(_("%1 of %2 clues"), p.solved or 0, p.total)
            bar = math.floor((p.solved or 0) * 100 / p.total)
        end
        table.insert(cards, { title = p.name or "", line = line, bar = bar, icon = "grid-3x3",
            image = p.thumb and function(w, h) return picture(p.thumb, w, h) end or nil,
            tap = function() self:openNotebook(p.book, p.page) end,
            hold = function() self:crosswordMenu(p) end })
    end
    return cards
end

--- The recent rows (books, notebooks, crosswords) from `top`: rows that
-- fit together share a line (a book and two notebooks, say); with "One row",
-- just the newest of each, side by side. Returns their height.
function View:recentRows(c, top)
    local groups = { { _("RECENT BOOKS"), self:recentCards() }, { _("RECENT NOTEBOOKS"), self:notebookCards() },
        { _("RECENT CROSSWORDS"), self:crosswordCards() } }
    local rows = {}
    -- (One row unless set to separate rows: recent_together false.)
    if self.apps.settings.recent_together ~= false then
        local cards = {}
        for __, g in ipairs(groups) do if g[2][1] then table.insert(cards, g[2][1]) end end
        if #cards > 0 then rows = { { _("RECENT"), cards } } end
    else
        for __, g in ipairs(groups) do if #g[2] > 0 then table.insert(rows, g) end end
    end
    -- Cards about 170 wide: 3 upright, 4 on its side.
    local gap = 12
    local width = c.W - 56
    local cap = math.max(1, math.min(5, math.floor((width + gap) / (170 + gap))))
    local w = (width - (cap - 1) * gap) / cap
    local y = top
    local line, used = {}, 0
    local function flush()
        if #line == 0 then return end
        local x, h = 28, 0
        for __, r in ipairs(line) do
            h = math.max(h, self:cardRow(c, y, r[1], r[2], x, r.n, w))
            x = x + r.n * (w + gap)
        end
        y = y + h
        line, used = {}, 0
    end
    for __, r in ipairs(rows) do
        local n = math.min(#r[2], cap)
        if used + n > cap then flush() end
        table.insert(line, { r[1], r[2], n = n })
        used = used + n
    end
    flush()
    return y - top
end

--- A notebook in Notes (at a page), on top of the launcher.
function View:openNotebook(id, page)
    local notes = self:plugin("notes")
    if not notes then return end
    self.away = true
    notes:open(id, page)
end

--- Holding a recent notebook: open it, or put it on the launcher.
function View:notebookMenu(n)
    local dialog
    dialog = require("appsko").buttonDialog{
        title = n.name or "",
        title_align = "center",
        buttons = {
            { { text = _("Open"), callback = function() UIManager:close(dialog) self:openNotebook(n.id) end } },
            { { text = _("Add to launcher"), callback = function()
                UIManager:close(dialog)
                self:addPin({ kind = "note", name = n.name, icon = "notebook-pen", id = n.id })
            end } },
            { { text = _("Remove from recent"), callback = function() UIManager:close(dialog) self:hideRecent(n) end } },
            { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        },
    }
end

--- Holding a recent crossword: open it, or take it off the recent row.
function View:crosswordMenu(p)
    local dialog
    dialog = require("appsko").buttonDialog{
        title = p.name or "",
        title_align = "center",
        buttons = {
            { { text = _("Open"), callback = function() UIManager:close(dialog) self:openNotebook(p.book, p.page) end } },
            { { text = _("Remove from recent"), callback = function() UIManager:close(dialog) self:hideRecent(p) end } },
            { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        },
    }
end

--- Holding a recent book: open it, finished or not, out of the history, its folder.
function View:bookMenu(b)
    local DocSettings = require("docsettings")
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local reader = ReaderUI and ReaderUI.instance
    local open = reader and reader.document and reader.document.file == b.file and reader.doc_settings or nil
    local function summary()
        if open then return open:readSetting("summary") or {}, open end
        local ds = DocSettings:open(b.file)
        return ds:readSetting("summary") or {}, ds
    end
    local ok, sm = pcall(summary)
    local finished = ok and sm.status == "complete"
    local dialog
    local function close() UIManager:close(dialog) end
    local buttons = {
        { { text = _("Open"), callback = function() close() self:openBook(b.file) end } },
        { { text = finished and _("Mark as reading") or _("Mark as finished"), callback = function()
            close()
            local s, ds = summary()
            s.status = finished and "reading" or "complete"
            s.modified = os.date("%Y-%m-%d")
            ds:saveSetting("summary", s)
            if ds ~= open then ds:flush() end
            recent = self:readRecent(5)
            self:refresh()
        end } },
        { { text = _("Remove from history"), callback = function()
            close()
            require("readhistory"):removeItemByPath(b.file)
            recent = self:readRecent(5)
            G_reader_settings:saveSetting("apps_recent", recent)
            self:refresh()
        end } },
        { { text = _("Open its folder"), callback = function() close() self:openFolder(b.file) end } },
        { { text = _("Close"), callback = close } },
    }
    -- The book's page in the Library app, when it's there.
    if require("pluginshare").library then
        table.insert(buttons, 2, { { text = _("Book details"), callback = function()
            close()
            UIManager:close(self)
            require("pluginshare").library.openBook(b.file)
        end } })
    end
    dialog = require("appsko").buttonDialog{ title = b.title, title_align = "center", buttons = buttons }
end

--- The library, at a book's folder (the book closed first if it is open).
function View:openFolder(file)
    UIManager:close(self)
    local PS = require("pluginshare")
    if PS.library and PS.library.isBrowser and PS.library.isBrowser() then return PS.library.openFolder(file) end
    local dir = file:match("^(.*)/[^/]+$") or "/"
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if ReaderUI and ReaderUI.instance then
        local r = ReaderUI.instance
        r:onClose()
        r:showFileManager(file)
        return
    end
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance.file_chooser:changeToPath(dir, file)
    else
        FileManager:showFiles(dir, file)
    end
end

--- Opens a book (closing the launcher; a book already open stays as it is).
-- Back in it comes back here.
function View:openBook(file)
    UIManager:close(self)
    require("appsreaderbar").openBook(file)
end

function View:drawTiles(c)
    local top = self:header(c)
    local tiles = self:tiles()
    local layout = self.apps.settings.layout or "tiles"
    local bottom = c.H - 40
    if self.group then
        local g = groupOf(self.apps.settings, self.group)
        c:icon("chevron-left", 24, top - 6, 22)
        c:text(56, top + 11, g and g.name or "", 18, { bold = true, maxw = c.W - 100 })
        c:hit(0, top - 20, c.W, 48, function() self:leaveGroup() end)
        top = top + 40
    else
        if c.W > c.H and self:quickShown() and self.apps.settings.today ~= false then
            -- On its side: the line and the buttons side by side (room for another row of tiles).
            local split = 28 + math.floor((c.W - 56) * 0.42)
            self:todayStrip(c, top + 13, split)
            top = top + self:togglesRow(c, top, split + 16)
        else
            top = top + self:todayStrip(c, top)
            top = top + self:togglesRow(c, top)
        end
        top = top + self:recentRows(c, top - 4)
    end
    local room = bottom - top
    local function hit(tile, x, y, w, h)
        c:hit(x, y, w, h, function() self:open(tile) end, function() self:tileMenu(tile, tiles) end)
    end
    -- Each layout: how many fit on a page, then where each one on this page goes.
    local perPage, place
    if layout == "list" then
        -- A row each: icon, name and its line, an arrow (two columns on its side).
        local cols = c.W > c.H and 2 or 1
        local cw = (c.W - 56 - (cols - 1) * 24) / cols
        local pages
        perPage, pages = Model.paging(#tiles, cols, 60, 0, room)
        local rows = math.max(1, math.ceil(math.min(#tiles, perPage) / cols))
        local rh = math.min(78, room / rows)
        if pages > 1 then perPage = math.floor(room / rh) * cols end
        place = function(tile, k, last)
            local col, row = (k - 1) % cols, math.floor((k - 1) / cols)
            local x, y = 28 + col * (cw + 24), top + row * rh
            c:icon(iconOf(tile), x, y + rh / 2 - 15, 30)
            c:text(x + 50, y + rh / 2 - 2, _(tile.name), 16, { bold = true, maxw = cw - 90 })
            c:text(x + 50, y + rh / 2 + 18, self:line(tile), 11, { color = C.GREY, maxw = cw - 90 })
            c:icon("chevron-right", x + cw - 18, y + rh / 2 - 9, 18)
            if not last and (k + cols - 1) < perPage then c:hline(x + 50, y + rh - 1, cw - 50) end
            hit(tile, x - 10, y, cw + 20, rh)
        end
    elseif layout == "compact" then
        -- Small tiles: the icon and the name side by side, no line (many to a page).
        local cols = c.W > c.H and 3 or 2
        local gap = 10
        local cw = (c.W - 56 - (cols - 1) * gap) / cols
        local th = 58
        perPage = Model.paging(#tiles, cols, th, gap, room)
        place = function(tile, k)
            local col, row = (k - 1) % cols, math.floor((k - 1) / cols)
            local x, y = 28 + col * (cw + gap), top + row * (th + gap)
            c:box(x, y, cw, th, { r = 10, border = C.BLACK, bw = 1.4 })
            c:icon(iconOf(tile), x + 14, y + th / 2 - 13, 26)
            c:text(x + 52, y + th / 2 + 6, _(tile.name), 14, { bold = true, maxw = cw - 64 })
            hit(tile, x, y, cw, th)
        end
    elseif layout == "icons" then
        -- Like a phone: an icon in an outlined rounded square, its name under it;
        -- smaller when that lets two rows fit.
        local cols = c.W > c.H and 5 or 3
        local cw = (c.W - 56) / cols
        local size = math.max(64, math.min(110, cw - 40, math.floor((room - 10) / 2 - 66)))
        local rh = size + 66
        perPage = Model.paging(#tiles, cols, rh, 0, room - 10)
        place = function(tile, k)
            local col, row = (k - 1) % cols, math.floor((k - 1) / cols)
            local x, y = 28 + col * cw, top + 10 + row * rh
            local bx = x + (cw - size) / 2
            c:box(bx, y, size, size, { r = size / 4.5, border = C.BLACK, bw = 1.4 })
            c:icon(iconOf(tile), bx + size * 0.28, y + size * 0.28, size * 0.44)
            c:text(x + cw / 2, y + size + 24, _(tile.name), 12.5, { bold = true, align = "middle", maxw = cw - 8 })
            c:text(x + cw / 2, y + size + 42, self:line(tile), 9.5, { align = "middle", color = C.GREY, maxw = cw - 8 })
            hit(tile, x, y, cw, rh - 6)
        end
    else
        -- Tiles: outlined, or (bold) filled black with white writing; as
        -- tall as fits, but not so small that a page would do better.
        local bold = layout == "bold"
        local cols = (self.apps.settings.columns or 2) + (c.W > c.H and 2 or 0)
        local gap = 12
        local pages
        perPage, pages = Model.paging(#tiles, cols, 110, gap, room)
        local rows = math.max(1, math.ceil(math.min(#tiles, perPage) / cols))
        if pages > 1 then rows = perPage / cols end
        local tw = (c.W - 56 - (cols - 1) * gap) / cols
        local th = math.min(150, (room - (rows - 1) * gap) / rows)
        place = function(tile, k)
            local col, row = (k - 1) % cols, math.floor((k - 1) / cols)
            local x, y = 28 + col * (tw + gap), top + row * (th + gap)
            c:box(x, y, tw, th, { r = 12, fill = bold and C.FILL or nil, border = C.BLACK, bw = 1.4 })
            c:icon(iconOf(tile), x + 18, y + 18, 34, bold)
            c:text(x + 18, y + th - 42, _(tile.name), 17, { bold = true, maxw = tw - 30, color = bold and C.ON_FILL or C.BLACK })
            c:text(x + 18, y + th - 20, self:line(tile), 11, { color = bold and C.ON_FILL_DIM or C.GREY, maxw = tw - 30 })
            hit(tile, x, y, tw, th)
        end
    end
    self.pages = math.max(1, math.ceil(#tiles / perPage))
    self.pageNo = math.min(self.pageNo, self.pages)
    local first = (self.pageNo - 1) * perPage
    for k = 1, perPage do
        local tile = tiles[first + k]
        if tile then place(tile, k, k == perPage or not tiles[first + k + 1]) end
    end
    if #tiles == 0 then
        c:text(c.W / 2, 300, self.group and _("No tiles in this group yet. Hold a tile and choose Move to a group.")
            or _("All tiles are hidden. Show them in ⋮ > Settings."), 13, { align = "middle", color = C.GREY, maxw = c.W - 60 })
    end
    if self.pages > 1 then
        self:pager(c, c.W / 2, c.H - 12)
    else
        c:text(c.W / 2, c.H - 14, _("Hold a tile to move or hide it"), 10, { align = "middle", color = C.MID })
    end
end

-- ------------------------------------------------------------------ sleep screen

--- Today's tasks (overdue first) from To Do: { title, overdue, list }.
local function tasksToday(todo)
    local out = {}
    local today = todo:today()
    local hidden = todo:hiddenSet()
    for __, list in ipairs(todo.store:lists()) do
        if not hidden[list.id] and list.wellknown ~= "flaggedEmails" then
            for __, t in ipairs(list.tasks or {}) do
                if not t.completed and t.due and t.due <= today then
                    table.insert(out, { title = t.title, overdue = t.due < today, due = t.due, remindAt = t.remindAt })
                end
            end
        end
    end
    table.sort(out, function(a, b) if a.due ~= b.due then return a.due < b.due end return a.title < b.title end)
    return out
end

--- The next thing with a time: a Home Assistant calendar event, else a To Do reminder today.
local function nextUp(apps)
    local ha = apps:plugin("homeassistant")
    if ha and ha.snap then
        local ok, ev = pcall(function() return require("hamodel").nextEvent(ha.snap) end)
        if ok and ev then return ev.title, ev.allDay and _("All day") or os.date("%a %I:%M %p", ev.start):gsub(" 0", " "), "calendar" end
    end
    local todo = apps:plugin("todo")
    if todo and todo.store then
        local soonest
        for __, list in ipairs(todo.store:lists()) do
            for __, t in ipairs(list.tasks or {}) do
                if not t.completed and t.remindAt and t.remindAt > os.time() and (not soonest or t.remindAt < soonest.remindAt) then soonest = t end
            end
        end
        if soonest and soonest.remindAt - os.time() < 36 * 3600 then
            return soonest.title, os.date("%a %I:%M %p", soonest.remindAt):gsub(" 0", " "), "clock"
        end
    end
end

--- The line under the clock: the weather, what is next, the tasks due. Returns its height.
function View:todayStrip(c, top, right)
    if self.apps.settings.today == false then return 0 end
    local parts = {}
    -- The weather (Home Assistant's or Open-Meteo's, as set): today's high and low too.
    local w = try(function() return require("appsweather").now(self.apps, self) end)
    if w then
        local range = w.high and ("  \u{00B7}  " .. w.high .. (w.low and (" / " .. w.low) or "")) or ""
        table.insert(parts, { icon = w.alert and "triangle-alert" or w.icon,
            text = (w.temp and (w.temp .. "  ") or "") .. (w.alert or w.text) .. range,
            fn = w.open and function()
                if not w.open then return end
                self.away = require("appsweather").source(self.apps) == "ha"
                w.open()
            end })
    end
    local todo = self:plugin("todo")
    local okn, title, when = pcall(nextUp, self.apps)
    if okn and title then
        table.insert(parts, { icon = "clock", text = title .. "  \u{00B7}  " .. when, grow = true,
            fn = todo and function() self.away = true todo:show({ kind = "today" }) end })
    end
    if todo and todo.store then
        local ok, list = pcall(tasksToday, todo)
        if ok then
            table.insert(parts, { icon = "list-checks", text = #list == 0 and _("Nothing due") or T(_("%1 due"), #list),
                fn = function() self.away = true todo:show({ kind = "today" }) end })
        end
    end
    if #parts == 0 then return 0 end
    -- Each part as wide as it needs; what is next gets what is left.
    local room, fixed = (right or (c.W - 28)) - 28, 0
    for __, p in ipairs(parts) do
        if not p.grow then fixed = fixed + 24 + c:width(p.text, 11.5) + 22 end
    end
    local x = 28
    for __, p in ipairs(parts) do
        local tw = p.grow and math.max(60, room - fixed - 24 - 22) or c:width(p.text, 11.5)
        c:icon(p.icon, x, top - 2, 17)
        c:text(x + 24, top + 12, p.text, 11.5, { maxw = tw })
        if p.fn then c:hit(x - 6, top - 12, tw + 36, 36, p.fn) end
        x = x + 24 + tw + 22
    end
    return 34
end

--- The quick buttons (appsquick.lua): two rows at most, then More. Returns their height.
function View:togglesRow(c, top, left)
    return require("appsquick").drawRow(self, c, top, left or 28, c.W - 28)
end

--- The Apps sleep screen: the date, the battery, the weather, what is next,
-- and today's tasks (no fingers: only drawn).
function View.drawSleep(apps, c)
    local now = os.date("*t")
    local s = apps.settings
    local twelve = not KO.twentyFour()
    local hour = twelve and ((now.hour + 11) % 12 + 1) or now.hour
    c:text(28, 74, os.date("%A, %B ") .. now.day, 24, { bold = true })
    c:text(28, 102, T(_("Sleeping since %1"), string.format(twelve and "%d:%02d %s" or "%02d:%02d", hour, now.min, twelve and (now.hour < 12 and "AM" or "PM") or "")), 12, { color = C.GREY })
    local powerd = Device:getPowerDevice()
    local battery = powerd and try(function() return powerd:getCapacity() end)
    local charging = powerd and try(function() return powerd:isCharging() end)
    if battery then
        local label = battery .. "%"
        local tw = c:width(label, 14)
        c:text(c.W - 28, 74, label, 14, { align = "end" })
        local x = c.W - 28 - tw - 30
        -- Charging (asleep on the charger) as such, else filled as far as it is charged.
        c:icon(charging and "battery-charging" or "battery", x, 58, 22)
        local k = 22 / 24
        if not charging and battery > 0 then c:box(x + 4.5 * k, 58 + 8.5 * k, 11 * k * math.min(100, battery) / 100, 7 * k, { fill = C.BLACK }) end
    end
    c:hline(28, 120, c.W - 56, C.BLACK, 2)
    local y = 136
    -- The weather (Home Assistant's or Open-Meteo's, as set).
    local okW, w = pcall(function() return require("appsweather").now(apps) end)
    if okW and w then
        c:icon(w.icon, 28, y + 4, 40)
        c:text(80, y + 36, w.temp or "", 30, { bold = true })
        c:text(c.W - 28, y + 22, w.alert or w.text, 13, { align = "end", color = C.GREY, bold = w.alert ~= nil })
        if w.high then
            c:text(c.W - 28, y + 42, T(_("High %1 · Low %2"), w.high, w.low or "–"), 12, { align = "end", color = C.GREY })
        end
        y = y + 64
    end
    -- What is next.
    local title, when, icon = nextUp(apps)
    if title then
        c:text(28, y + 14, _("NEXT"), 10, { bold = true, color = C.GREY })
        c:icon(icon, 28, y + 24, 18)
        c:text(56, y + 39, title, 13, { bold = true, maxw = c.W - 230 })
        c:text(c.W - 28, y + 39, when, 12, { align = "end", color = C.GREY })
        y = y + 60
    end
    -- Today's tasks (To Do).
    local todo = apps:plugin("todo")
    if todo and todo.store then
        local ok, list = pcall(tasksToday, todo)
        list = ok and list or {}
        c:text(28, y + 14, T(_("TODAY  %1"), #list), 10, { bold = true, color = C.GREY })
        y = y + 24
        if #list == 0 then
            c:text(28, y + 22, _("Nothing due today."), 13, { color = C.GREY })
        end
        for __, t in ipairs(list) do
            if y + 36 > c.H - 48 then
                c:text(28, y + 22, _("… and more"), 12, { color = C.GREY })
                break
            end
            c:box(28, y + 8, 18, 18, { r = 4, border = C.BLACK, bw = 1.3 })
            c:text(58, y + 23, t.title, 13, { maxw = c.W - 190 })
            if t.overdue then c:text(c.W - 28, y + 23, _("Overdue"), 11, { bold = true, align = "end" }) end
            c:hline(58, y + 34, c.W - 86)
            y = y + 36
        end
    end
end

--- The parts the Apps widgets sleep screen can show, in their order.
View.WIDGETS = { "clock", "book", "todo", "ha", "notifications" }
View.WIDGET_NAMES = { clock = _("Clock"), book = _("Current book"), todo = _("To Do today"), ha = _("Home Assistant alerts"),
    notifications = _("Latest notifications") }

--- The parts in their order: as set (sleep_widgets_order), the others after in the usual order.
function View.widgetOrder(s)
    local out, seen = {}, {}
    for __, k in ipairs(type(s.sleep_widgets_order) == "table" and s.sleep_widgets_order or {}) do
        if View.WIDGET_NAMES[k] and not seen[k] then table.insert(out, k) seen[k] = true end
    end
    for __, k in ipairs(View.WIDGETS) do
        if not seen[k] then table.insert(out, k) end
    end
    return out
end

--- Whether a widget shows (all to start with).
function View.widgetOn(s, key)
    return not (s.sleep_widgets and s.sleep_widgets[key] == false)
end

--- A book's cover from those already in memory (the launcher's cards), fitted
-- to w x h pixels; nil when none is (nothing read from the disk).
local function cachedCover(file, w, h)
    local key = file .. "@" .. w .. "x" .. h
    if covers[key] then return covers[key] end
    for k, bb in pairs(covers) do
        if bb and k:sub(1, #file + 1) == file .. "@" then
            local bw, bh = bb:getWidth(), bb:getHeight()
            local f = math.min(w / bw, h / bh)
            local ok, scaled = pcall(function()
                return require("ui/renderimage"):scaleBlitBuffer(bb, math.max(1, math.floor(bw * f)), math.max(1, math.floor(bh * f)), false)
            end)
            if ok and scaled then covers[key] = scaled return scaled end
        end
    end
end

--- "Updated 5 min ago" (from when the app last had its data).
local function agoText(t)
    if not t then return nil end
    local m = math.floor((os.time() - t) / 60)
    if m < 1 then return _("Updated just now") end
    if m < 60 then return T(_("Updated %1 min ago"), m) end
    if m < 48 * 60 then return T(_("Updated %1 h ago"), math.floor(m / 60)) end
    return T(_("Updated %1 days ago"), math.floor(m / 1440))
end

--- The Apps widgets sleep screen: the parts picked (Settings > Sleep screen >
-- Widgets), each a card: the clock, the book being read (cover and how far),
-- To Do's today, Home Assistant's alerts, the latest notifications. Drawn
-- only from what is already in memory: nothing read from the disk or the
-- network as the Kindle goes to sleep; each card says how old its data is.
function View.drawWidgets(apps, c)
    local s = apps.settings
    local now = os.date("*t")
    local twelve = not KO.twentyFour()
    local y = 28
    local function card(h, draw)
        if y + h > c.H - 50 then return false end
        c:box(28, y, c.W - 56, h, { r = 14, border = C.BLACK, bw = 1.5 })
        draw(y)
        y = y + h + 14
        return true
    end
    local function heading(yy, text, right)
        c:text(46, yy + 26, text, 10, { bold = true, color = C.GREY })
        if right then c:text(c.W - 46, yy + 26, right, 9.5, { align = "end", color = C.GREY }) end
    end
    -- Each part, drawn in the order set (Settings or the web page), the ones switched on.
    local parts = {}
    parts.clock = function()
        card(130, function(yy)
            local hour = twelve and ((now.hour + 11) % 12 + 1) or now.hour
            local clock = string.format(twelve and "%d:%02d" or "%02d:%02d", hour, now.min)
            local w = c:text(46, yy + 78, clock, 56, { bold = true }) or 0
            if twelve then c:text(46 + w + 8, yy + 78, now.hour < 12 and "AM" or "PM", 18, { bold = true }) end
            c:text(48, yy + 110, os.date("%A, %B ") .. now.day, 14, { color = C.GREY })
            local powerd = Device:getPowerDevice()
            local battery = powerd and try(function() return powerd:getCapacity() end)
            local charging = powerd and try(function() return powerd:isCharging() end)
            if battery then
                local label = battery .. "%"
                c:text(c.W - 46, yy + 44, label, 14, { align = "end" })
                local x = c.W - 46 - c:width(label, 14) - 30
                c:icon(charging and "battery-charging" or "battery", x, yy + 28, 22)
                local k = 22 / 24
                if not charging and battery > 0 then c:box(x + 4.5 * k, yy + 28 + 8.5 * k, 11 * k * math.min(100, battery) / 100, 7 * k, { fill = C.BLACK }) end
            end
        end)
    end
    parts.book = function()
        -- The book open now (its page, in memory), else the launcher's last recent book.
        local file, title, pct
        local ReaderUI = package.loaded["apps/reader/readerui"]
        local ui = ReaderUI and ReaderUI.instance
        if ui and ui.document then
            file = ui.document.file
            local props = ui.doc_props or {}
            title = props.display_title or props.title
            pct = try(function() return math.floor(ui:getCurrentPage() / ui.document:getPageCount() * 100 + 0.5) end)
        end
        local r = recent[1]
        if not file and r then file, title, pct = r.file, r.title, r.percent end
        if file then
            if not title or title == "" then title = Model.bookName(file) end
            pct = pct or 0
            card(120, function(yy)
                heading(yy, _("READING"))
                local img = cachedCover(file, c:X(54), c:X(76))
                if img then
                    c:image(img, 46, yy + 34)
                    c:box(46, yy + 34, img:getWidth() / c.u, img:getHeight() / c.u, { border = C.BLACK })
                else
                    c:box(46, yy + 34, 54, 76, { r = 4, border = C.BLACK })
                    c:icon("book-open", 61, yy + 62, 24)
                end
                c:text(116, yy + 58, title, 15, { bold = true, maxw = c.W - 180 })
                c:box(116, yy + 76, c.W - 210, 8, { r = 4, border = C.BLACK })
                if pct > 0 then c:box(117, yy + 77, (c.W - 212) * math.min(100, pct) / 100, 6, { r = 3, fill = C.BLACK }) end
                c:text(c.W - 46, yy + 86, pct .. "%", 11, { align = "end", color = C.GREY })
            end)
        end
    end
    parts.todo = function()
        local todo = apps:plugin("todo")
        if todo and todo.store then
            local ok, list = pcall(tasksToday, todo)
            list = ok and list or {}
            local n = math.min(#list, 6)
            card(46 + math.max(1, n) * 32, function(yy)
                heading(yy, T(_("TODAY  %1"), #list), agoText(try(function() return todo.store:syncedAt() end)))
                if #list == 0 then c:text(46, yy + 60, _("Nothing due today."), 13, { color = C.GREY }) end
                for i = 1, n do
                    local t, ty = list[i], yy + 38 + (i - 1) * 32
                    c:box(46, ty + 4, 18, 18, { r = 4, border = C.BLACK, bw = 1.3 })
                    c:text(76, ty + 19, t.title, 13, { maxw = c.W - 210 })
                    if t.overdue then c:text(c.W - 46, ty + 19, _("Overdue"), 11, { bold = true, align = "end" }) end
                end
            end)
        end
    end
    parts.ha = function()
        local ha = apps:plugin("homeassistant")
        local okM, M = pcall(require, "hamodel")
        if ha and ha.snap and okM then
            local att = try(function() return M.attention(ha.snap, ha.prefs) end)
            local lines = try(function() return M.sleepAlerts(ha.snap, ha.prefs) end) or {}
            local n = math.min(#lines, 5)
            card(78 + n * 26, function(yy)
                heading(yy, _("HOME"), agoText(ha.updatedAt))
                if att then
                    c:icon(att.ok and "shield-check" or "triangle-alert", 46, yy + 40, 20)
                    c:text(76, yy + 56, att.text or "", 13, { bold = not att.ok, maxw = c.W - 130 })
                end
                for i = 1, n do c:text(76, yy + 56 + i * 26, lines[i], 12, { maxw = c.W - 130 }) end
            end)
        end
    end
    parts.notifications = function()
        local okN, Notify = pcall(require, "appsnotify")
        local list = okN and Notify.list() or {}
        local n = math.min(#list, 4)
        if n > 0 then
            card(46 + n * 44, function(yy)
                heading(yy, _("NOTIFICATIONS"))
                for i = 1, n do
                    local e, ty = list[i], yy + 38 + (i - 1) * 44
                    c:icon(Notify.appIcon(e), 46, ty + 4, 16)
                    c:text(70, ty + 16, Notify.appName(e) .. "  \u{00B7}  " .. Notify.when(e.time), 10, { bold = true, color = C.GREY, maxw = c.W - 140 })
                    c:text(70, ty + 35, e.text, 12, { maxw = c.W - 140 })
                end
            end)
        end
    end
    for __, k in ipairs(View.widgetOrder(s)) do
        if parts[k] and View.widgetOn(s, k) then parts[k]() end
    end
    c:text(28, c.H - 18, T(_("Sleeping since %1"), (os.date(twelve and "%I:%M %p" or "%H:%M"):gsub("^0", ""))), 10.5, { color = C.GREY })
end

-- ------------------------------------------------------------------ pins

function View:pinChoices(kind) return self.apps:pinChoices(kind) end

function View:addPin(p) self.apps:addPin(p) end

--- Add shortcut: pick a kind, then the place.
function View:pickPin()
    local dialog
    local function pick(title, kind)
        UIManager:close(dialog)
        local choices = self:pinChoices(kind)
        if #choices == 0 then
            return require("appsko").toast(_("Nothing to add yet."), 2)
        end
        local list
        local buttons = {}
        for __, p in ipairs(choices) do
            table.insert(buttons, { { text = p.name, callback = function()
                UIManager:close(list)
                self:addPin(p)
            end } })
        end
        table.insert(buttons, { { text = _("Close"), callback = function() UIManager:close(list) end } })
        list = require("appsko").buttonDialog{ title = title, title_align = "center", buttons = buttons }
    end
    local buttons = {}
    if self:plugin("homeassistant") then
        table.insert(buttons, { { text = _("Home Assistant screen or room"), callback = function() pick(_("Home Assistant"), "ha") end } })
    end
    if self:plugin("todo") then
        table.insert(buttons, { { text = _("To Do view or list"), callback = function() pick(_("To Do"), "todo") end } })
    end
    if self:plugin("notes") then
        table.insert(buttons, { { text = _("Notebook"), callback = function() pick(_("Notes"), "note") end } })
        if self:plugin("notes").folders then
            table.insert(buttons, { { text = _("Notes folder"), callback = function() pick(_("Notes folders"), "notefolder") end } })
        end
        if self:plugin("notes").crosswordSources then
            table.insert(buttons, { { text = _("Crossword"), callback = function() pick(_("A source's newest crossword"), "crossword") end } })
        end
    end
    table.insert(buttons, { { text = _("KOReader action"), callback = function()
        UIManager:close(dialog)
        self:pickAction()
    end } })
    table.insert(buttons, { { text = _("Close"), callback = function() UIManager:close(dialog) end } })
    dialog = require("appsko").buttonDialog{ title = _("Add shortcut"), title_align = "center", buttons = buttons }
end

--- A KOReader action (as gestures run them): its group, then the action.
function View:pickAction()
    local Actions = require("appsactions")
    local dialog
    local buttons = {}
    for __, s in ipairs(Actions.SECTIONS) do
        local list = Actions.list(s[1])
        if #list > 0 then
            table.insert(buttons, { { text = s[2], callback = function()
                UIManager:close(dialog)
                local Menu = require("ui/widget/menu")
                local menu
                local items = {}
                for __, a in ipairs(list) do
                    table.insert(items, { text = a.title, callback = function()
                        self:addPin({ kind = "action", id = a.key, name = a.title, icon = Actions.icon(a.key) })
                    end })
                end
                menu = Menu:new{
                    title = s[2], item_table = items, covers_fullscreen = true, is_borderless = true, is_popout = false,
                    close_callback = function() UIManager:close(menu) end,
                }
                UIManager:show(menu)
            end } })
        end
    end
    if #buttons == 0 then
        return require("appsko").toast(_("Nothing to add yet."), 2)
    end
    table.insert(buttons, { { text = _("Close"), callback = function() UIManager:close(dialog) end } })
    dialog = require("appsko").buttonDialog{ title = _("KOReader action"), title_align = "center", buttons = buttons }
end

-- ------------------------------------------------------------------ arrange

-- The arrange screen: each tile with its place (arrows) and whether it shows
-- (eye; a pin is removed with the x), then the settings. Pages turn when the
-- tiles do not fit; on its side the settings are a second column.
--- The launcher's two settings screens (mode "arrange"): its tiles
-- (arrangePart "tiles": order, hide, groups, shortcuts) or the rest of its
-- settings ("settings", the default).
--- The launcher's own settings (Settings > Launcher), as rows: { heading } or { name, value, fn | pick }.
-- Drawn by drawArrange; search lists their names (Search: Apps and settings).
function View:settingsRows()
    -- As in every app's settings: Display first, then the launcher's own,
    -- Wi-Fi and the plugins last. (Light, night mode and a screen refresh
    -- are in the ⋮ menu.) A row's value: text (a choice: tap for the list)
    -- or true/false (a switch).
    local s = self.apps.settings
    local rows = {
        { heading = _("DISPLAY") },
        { _("Layout"), View.LAYOUT_NAMES[s.layout or "tiles"], pick = function()
            local options = {}
            for __, v in ipairs(View.LAYOUTS) do table.insert(options, { View.LAYOUT_NAMES[v], v }) end
            return options, s.layout or "tiles", function(v) s.layout = v self.pageNo = 1 end
        end },
        { _("Columns"), tostring(s.columns or 2), pick = function()
            return { { "1", 1 }, { "2", 2 }, { "3", 3 } }, s.columns or 2, function(v) s.columns = v end
        end },

        { _("Clock"), s.clock == "small" and _("Small") or _("Large"), pick = function()
            return { { _("Large"), "large" }, { _("Small"), "small" } }, s.clock == "small" and "small" or "large",
                function(v) s.clock = v == "small" and "small" or nil end
        end },
        -- KOReader's own setting (its Time and date menu): every app's clock follows it.
        { _("24-hour clock"), KO.twentyFour(), function() G_reader_settings:saveSetting("twelve_hour_clock", KO.twentyFour()) end },
        -- The pop-ups' buttons (every app's): an icon over a label, or just the icon; an app may differ.
        { _("Button labels"), (function()
            local on = G_reader_settings:readSetting("apps_button_labels") ~= false
            local own = 0
            for k in pairs(G_reader_settings:readSetting("apps_button_labels_by_app") or {}) do own = own + 1 end
            local text = on and _("On") or _("Off")
            return own > 0 and T(_("%1 · %2 apps differ"), text, own) or text
        end)(), function() View.buttonLabels(self) end },
        { heading = _("HOME SCREEN") },
        { _("At a glance"), s.today ~= false, function() s.today = s.today == false and true or false end },
        { _("Quick buttons"), (function()
            if not self:togglesOn() then return _("Off") end
            local n = #Model.quickList(s)
            return n == 1 and _("1 button") or T(_("%1 buttons"), n)
        end)(), function() require("appsquick").edit(self) end },
        { _("Recent books"), s.recent ~= false, function() s.recent = s.recent == false and true or false end },
        self:plugin("notes") and { _("Recent notebooks"), s.recent_notes ~= false, function()
            s.recent_notes = s.recent_notes == false and true or false
            recentNotes = self:readRecentNotes()
        end } or false,
        self:plugin("notes") and { _("Recent crosswords"), s.recent_crosswords ~= false, function()
            s.recent_crosswords = s.recent_crosswords == false and true or false
            local __, pz = self:readRecentNotes()
            recentPuzzles = pz
        end } or false,
        -- Notebooks and crosswords taken off the recent rows: back one at a time, or all.
        s.recent_hidden and next(s.recent_hidden) and { _("Removed from recent"), tostring(View.count(s.recent_hidden)), pick = function()
            local options = {}
            for key, h in pairs(s.recent_hidden) do
                local name = type(h) == "table" and h.name or nil
                table.insert(options, { T(_("Show %1"), name and name ~= "" and name or (key:sub(1, 1) == "c" and _("a crossword") or _("a notebook"))), key })
            end
            table.sort(options, function(a, b) return a[1]:lower() < b[1]:lower() end)
            if #options > 1 then table.insert(options, { _("Show all"), "all" }) end
            return options, nil, function(v)
                if v == "all" then s.recent_hidden = nil else s.recent_hidden[v] = nil end
                if s.recent_hidden and not next(s.recent_hidden) then s.recent_hidden = nil end
                recentNotes, recentPuzzles = self:readRecentNotes()
            end
        end } or false,
        { _("Recent items"), s.recent_together ~= false and _("One row") or _("Separate rows"), pick = function()
            return { { _("One row"), "together" }, { _("Separate rows"), "separate" } }, s.recent_together ~= false and "together" or "separate",
                function(v) if v == "separate" then s.recent_together = false else s.recent_together = nil end end
        end },
        -- A tap at the top of a book or the library: the apps' title bar (appsreaderbar.lua).
        { heading = _("WEATHER") },
        -- For At a glance, the widgets sleep screen and the Weather tile.
        { _("Weather from"), require("appsweather").sourceName(self.apps), pick = function()
            return require("appsweather").sourceChoices(), s.weather or "auto", function(v) s.weather = v ~= "auto" and v or nil end
        end },
        s.weather ~= "off" and s.weather ~= "ha" and { _("Place"), s.weather_place and s.weather_place.name or _("Not set"), function()
            require("appsweather").choosePlace(self.apps, function() self:refresh() end, function() self:refresh() end)
        end } or false,
        s.weather ~= "off" and s.weather ~= "ha" and { _("Units"), require("appsweather").units(self.apps) == "f" and "°F" or "°C", pick = function()
            return { { "°F", "f" }, { "°C", "c" } }, require("appsweather").units(self.apps), function(v)
                s.weather_units = v
                require("appsweather").refresh(self.apps, true, function() self:refresh() end)
            end
        end } or false,
        s.weather ~= "off" and { _("Test connection"), "", function() require("appstest").show("weather") end } or false,
        { heading = _("BOOKS AND LIBRARY") },
        { _("Title bar in books"), s.book_bar ~= false, function() s.book_bar = s.book_bar == false and true or false end },
        { _("Title bar in the library"), s.library_bar ~= false, function() s.library_bar = s.library_bar == false and true or false end },
        { _("Status bar like the apps"), s.footer_style ~= false, function() s.footer_style = s.footer_style == false and true or false end },

        { heading = _("SLEEP") },
        -- KOReader's sleep timer (AutoSuspend), here so it's easy to find.
        self:autosuspend() and { _("Sleep after"), View.sleepAfterName(self:sleepAfter()), pick = function()
            local options, now = require("appskosettings").sleepOptions()
            return options, now, function(v) self:setSleepAfter(v) end
        end } or false,
        { _("Sleep screen"), self.apps:sleepName(), pick = function()
            return self.apps:sleepChoices(), self.apps:sleepSource() or "none", function(v) self.apps:setSleep(v) end
        end },
        G_reader_settings:readSetting("sleep_screen_app") == "widgets" and { _("Widgets"), (function()
            local names = {}
            for __, k in ipairs(View.WIDGETS) do if View.widgetOn(s, k) then table.insert(names, View.WIDGET_NAMES[k]) end end
            return #names > 0 and table.concat(names, ", ") or _("None")
        end)(), function() self:widgetsMenu() end } or false,
        { _("Sleep screen updates"), KO.sleepUpdateName(KO.sleepMinutes()), pick = function()
            local options = {}
            for __, m in ipairs(KO.SLEEP_UPDATES) do table.insert(options, { KO.sleepUpdateName(m), m }) end
            return options, KO.sleepMinutes(), function(v) G_reader_settings:saveSetting("sleep_screen_update", v) end
        end },
        { heading = _("START") },
        { _("Open at startup"), s.at_start == true, function() s.at_start = not s.at_start end },
        { heading = _("WI-FI") },
        { _("Turn off when idle"), View.wifiIdleName(s.wifi_idle), pick = function()
            local options = {}
            for __, m in ipairs({ false, 5, 15, 30 }) do table.insert(options, { View.wifiIdleName(m), m }) end
            return options, s.wifi_idle or false, function(v) s.wifi_idle = v or nil end
        end },
        -- Every app that's set up, tested the way its own Test connection does (appstest.lua).
        { _("Connection check"), _("Every app that's set up"), function() require("appstest").open(self) end },
        { heading = _("PLUGINS") },
        -- Updates from GitHub (appsupdate.lua): the release installed, a check, and the repo.
        { _("Check for updates"), require("appsupdate").installed(self.apps) or _("Version not known"),
            function() require("appsupdate").check(self.apps) end },
        { _("Update from"), require("appsupdate").repo(), function()
            local U = require("appsupdate")
            KO.askText{ title = _("Update from"), text = U.repo(), hint = "owner/repo", pen = false, ok = _("Save"),
                done = function(t)
                    if not U.setRepo(t) then return KO.message(_("Type it as owner/repo, as on GitHub (empty: the usual one).")) end
                    self:refresh()
                end }
        end },
        { _("Install a version"), _("Any release, an older one too"), function() require("appsupdate").pickVersion(self.apps) end },
        { _("Check automatically"), require("appsupdate").auto(), function()
            local U = require("appsupdate")
            U.setAuto(not U.auto())
        end },
        { _("Undo a plugin update"), "", function() require("appsundo").undoMenu(self.apps) end },
    }
    local list = {}
    for __, r in ipairs(rows) do
        if r then table.insert(list, r) end
    end
    return list
end

function View:drawArrange(c)
    local s = self.apps.settings
    local tiles = self:tiles(true)
    local lw = c.W
    local part = self.arrangePart == "tiles" and "tiles" or "settings"
    local F = c:flow(52, c.H - 8, self.arrangePage)
    if part == "tiles" then
    F:block(46, function(y)
        c:text(14, y + 14, _("TILES"), 9.5, { bold = true, color = C.GREY })
        c:text(14, y + 34, _("The arrows move a tile, the eye shows or hides it, the x removes a shortcut."), 10.5,
            { color = C.GREY, maxw = c.W - 28 })
    end)
    for i, tile in ipairs(tiles) do
        F:block(46, function(y)
            local hidden = Model.isHidden(s.hidden, tile)
            local g = s.grouped and s.grouped[tile.key] and groupOf(s, s.grouped[tile.key])
            c:icon(tile.icon, 14, y + 12, 20)
            local nw = c:text(46, y + 28, _(tile.name), 13, { color = hidden and C.MID or C.BLACK, maxw = lw - 236 }) or 0
            if g then c:text(46 + nw + 8, y + 28, "\u{00B7} " .. g.name, 10.5, { color = C.GREY, maxw = lw - 246 - nw }) end
            local function move(delta)
                -- The order before, for Undo.
                self.orderUndo = self.orderUndo or {}
                table.insert(self.orderUndo, keysOf(tiles))
                s.order = Model.move(tiles, tile.key, delta)
                self.apps:save()
                self:refresh()
            end
            -- To the top, up, down, to the bottom.
            local arrows = {
                { "arrow-up-to-line", -#tiles, i > 1 }, { "arrow-up", -1, i > 1 },
                { "arrow-down", 1, i < #tiles }, { "arrow-down-to-line", #tiles, i < #tiles },
            }
            for n, a in ipairs(arrows) do
                if a[3] then
                    local ax = lw - 214 + (n - 1) * 40
                    c:icon(a[1], ax, y + 12, 20)
                    c:hit(ax - 10, y, 40, 44, function() move(a[2]) end)
                end
            end
            if tile.pin or tile.groupTile then
                c:icon("x", lw - 46, y + 12, 20)
                c:hit(lw - 60, y, 60, 44, function()
                    self:withUndo(tile.groupTile and T(_("Deleted %1"), tile.name) or T(_("Removed %1"), _(tile.name)), function()
                        if tile.groupTile then
                            for k, gid in pairs(s.grouped or {}) do
                                if gid == tile.groupTile then s.grouped[k] = nil end
                            end
                            local kept = {}
                            for __, x in ipairs(s.groups or {}) do if x.id ~= tile.groupTile then table.insert(kept, x) end end
                            s.groups = kept
                        else
                            s.pins = Model.removePin(s.pins, tile.key)
                        end
                        self.apps:save()
                        self:refresh()
                    end)
                end)
            else
                c:icon(hidden and "eye-off" or "eye", lw - 46, y + 12, 20)
                c:hit(lw - 60, y, 60, 44, function()
                    s.hidden = s.hidden or {}
                    if not hidden then s.hidden[tile.key] = true
                    elseif tile.offByDefault then s.hidden[tile.key] = false
                    else s.hidden[tile.key] = nil end
                    self.apps:save()
                    self:refresh()
                end)
            end
            c:hline(14, y + 44, lw - 28)
        end)
    end
    -- Add shortcut, under the tiles.
    F:block(46, function(y)
        c:icon("plus", 14, y + 12, 20)
        c:text(46, y + 28, _("Add shortcut"), 13, { bold = true })
        c:text(lw - 14, y + 28, _("A screen, list, notebook or folder"), 10.5, { align = "end", color = C.GREY, maxw = lw - 200 })
        c:hit(0, y, lw, 46, function() self:pickPin() end)
        c:hline(14, y + 44, lw - 28)
    end)
    -- Suggested groups: ready-made ones (Settings, Reading...).
    F:block(46, function(y)
        c:icon("folder", 14, y + 12, 20)
        c:text(46, y + 28, _("Suggested groups"), 13, { bold = true })
        c:text(lw - 14, y + 28, _("Settings, Reading, Home, Tools…"), 10.5, { align = "end", color = C.GREY, maxw = lw - 240 })
        c:hit(0, y, lw, 46, function() self:suggestGroups() end)
        c:hline(14, y + 44, lw - 28)
    end)
    -- A copy of the home screen as it is, to put back later.
    F:block(46, function(y)
        c:icon("history", 14, y + 12, 20)
        c:text(46, y + 28, _("Saved home screen"), 13, { bold = true })
        local at = s.home_saved and s.home_saved.at
        c:text(lw - 14, y + 28, at and os.date("%b %d, %H:%M", at) or _("Not saved"), 10.5, { align = "end", color = C.GREY, maxw = lw - 240 })
        c:hit(0, y, lw, 46, function() self:savedHomeScreen() end)
        c:hline(14, y + 44, lw - 28)
    end)
    end
    local rows = self:settingsRows()
    -- Drawn as Home Assistant's settings are: headings in grey capitals,
    -- rows 36 tall, a choice's value and › at the right, or a switch.
    local function heading(x0, y, text)
        c:text(x0 + 14, y + 26, text, 9.5, { bold = true, color = C.GREY })
    end
    local function row(x0, y, r)
        if r.heading then return heading(x0, y, r.heading) end
        c:text(x0 + 14, y + 23, r[1], 12, { maxw = 330 })
        if type(r[2]) == "boolean" then
            local sx, sy = c.W - 54, y + 7
            c:box(sx, sy, 40, 22, { r = 11, fill = r[2] and C.FILL or C.WHITE, border = C.BLACK })
            c:circle(sx + (r[2] and 29 or 11), sy + 11, 7, r[2] and C.ON_FILL or C.BLACK)
        else
            c:text(c.W - 32, y + 23, r[2], 11, { align = "end", color = C.GREY, maxw = 250 })
            c:icon("chevron-right", c.W - 26, y + 12, 12)
        end
        local function apply(fn)
            fn()
            self.apps:save()
            self:render()
            UIManager:setDirty(self, r[4] or "ui")
        end
        c:hit(x0, y, c.W - x0, 36, function()
            -- More than two values: a list to pick from (the current one ticked).
            if r.pick then
                local options, current, set = r.pick()
                local dialog
                local buttons = {}
                for __, o in ipairs(options) do
                    table.insert(buttons, { { text = (o[2] == current and "✓ " or "") .. o[1], callback = function()
                        UIManager:close(dialog)
                        apply(function() set(o[2]) end)
                    end } })
                end
                table.insert(buttons, { { text = _("Close"), callback = function() UIManager:close(dialog) end } })
                dialog = require("appsko").buttonDialog{ title = r[1], title_align = "center", buttons = buttons }
            else
                apply(r[3])
            end
        end)
        c:hline(x0 + 14, y + 35, c.W - x0 - 14)
    end
    local function help(x0, y)
        c:text(x0 + 14, y + 30, _("To open the launcher with a gesture: Settings > Taps and gestures >"), 10.5, { color = C.GREY, maxw = c.W - x0 - 28 })
        c:text(x0 + 14, y + 46, _("Gesture manager > (a gesture) > General > Launcher."), 10.5, { color = C.GREY, maxw = c.W - x0 - 28 })
    end
    -- The settings in pages (each heading with at least its first row;
    -- Display with all of it).
    local sleepPage
    if part == "settings" then
        for i, r in ipairs(rows) do
            local h = r.heading and 34 or 36
            F:block(h, function(y) row(0, y, r) end, r.heading and (i == 1 and 5 * 36 or 36) or nil)
            if (self.arrangeJump == "sleep" and r.heading == _("SLEEP")) or (r[1] and r[1] == self.arrangeJump) then
                sleepPage = sleepPage or F.page
            end
        end
        F:block(56, function(y) help(0, y) end)
    end
    self.pages = F:pages()
    if self.arrangeJump and sleepPage then
        self.arrangeJump = nil
        if sleepPage ~= self.arrangePage then
            self.arrangePage = sleepPage
            return self:render()
        end
    end
    if self.arrangePage > self.pages then
        self.arrangePage = self.pages
        return self:render()
    end
    -- The title bar last (over the flow's top); Undo: the order before the last move.
    local buttons
    if self.orderUndo and #self.orderUndo > 0 then
        buttons = { { "undo-2", function()
            s.order = table.remove(self.orderUndo)
            self.apps:save()
            self:refresh()
        end } }
    end
    self:bar(c, part == "tiles" and _("Edit home screen") or _("Launcher settings"), buttons)
end

-- ------------------------------------------------------------------ Sleep after

--- KOReader's sleep timer: the same row as on the KOReader settings page (appskosettings.lua).
function View:autosuspend()
    local ui = self:currentUI()
    return ui and ui.autosuspend
end
function View:sleepAfter() return require("appskosettings").sleepAfter() end
function View.sleepAfterName(seconds) return require("appskosettings").sleepAfterName(seconds) end
function View:setSleepAfter(seconds) require("appskosettings").setSleepAfter(seconds) end


--- Settings > Launcher > Button labels: for every app, then each app on its own (As in
-- Default (as for every app), On, Off). The shared pop-ups read it (appspopup.lua's labels()).
function View.buttonLabels(view)
    local Popup = require("appspopup")
    local PS = require("pluginshare")
    local function apps()
        local out = {}
        for __, a in ipairs(Popup.LABEL_APPS) do
            if a.key == "apps" or view:plugin(a.plugin) then table.insert(out, a) end
        end
        return out
    end
    PS.settingsPage{ title = _("Button labels"), rows = function()
        local rows = {
            { heading = _("EVERY APP") },
            { _("Button labels"), G_reader_settings:readSetting("apps_button_labels") ~= false, function()
                G_reader_settings:saveSetting("apps_button_labels", G_reader_settings:readSetting("apps_button_labels") == false)
            end },
            { heading = _("EACH APP") },
        }
        local names = { [true] = _("On"), [false] = _("Off") }
        for __, a in ipairs(apps()) do
            local own = Popup.labelsOf(a.key)
            table.insert(rows, { _(a.name), own == nil and _("Default") or names[own], function()
                KO.choose(_(a.name), { { label = _("Default"), value = "launcher" }, { label = _("On"), value = "on" },
                    { label = _("Off"), value = "off" } }, own == nil and "launcher" or (own and "on" or "off"), function(v)
                    Popup.setLabelsOf(a.key, Popup.labelsValue(v))
                    View.buttonLabels(view)
                end)
            end })
        end
        return rows
    end }
end

return View
