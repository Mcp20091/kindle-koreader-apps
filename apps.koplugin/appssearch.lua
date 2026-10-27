--[[--
Search everything from the launcher: one search box for books (titles and
authors), notebooks, tasks, crosswords, saved Wikipedia articles and Home
Assistant's devices. Results come grouped by app; a tap opens the item.

Each app adds its own through PluginShare:

    local PS = require("pluginshare")
    if PS.registerSearch then
        PS.registerSearch{ key = "todo", name = "To Do", icon = "list-checks",
            search = function(q)        -- q: what was typed, lower case
                return { { title = "Call the dentist", sub = "Tasks · due today",
                           open = function() ... end }, ... }   -- at most ~20
            end }
    end

Books (KOReader's book information, and the file names under the home
folder) are Apps' own, and so are the launcher's apps and screens (tiles
turned off too) and the Settings pages; notebooks too until Notes adds its own.
]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local Bar = require("appsbar")
local Canvas = require("appscanvas")
local KO = require("appsko")

local C = Canvas

local Search = {}

-- (Kept in PluginShare: apps register at start, before this module is loaded.)
local PS0 = require("pluginshare")
PS0.searchApps = PS0.searchApps or {}
local registry = PS0.searchApps
local ORDER = { "books", "notes", "crosswords", "todo", "wikipedia", "homeassistant" }

function Search.register(e)
    if type(e) == "table" and e.key and e.search then registry[e.key] = e end
end

-- ------------------------------------------------------------------ books

local BOOK = { epub = true, pdf = true, mobi = true, azw = true, azw3 = true, fb2 = true, djvu = true, cbz = true, txt = true, docx = true, kepub = true }

local function openBook(path)
    return function()
        local PS = require("pluginshare")
        local v = PS.appsView and PS.appsView()
        if v then UIManager:close(v) end
        require("appsreaderbar").openBook(path)
    end
end

--- Books whose title or author (KOReader's book information) or file name
-- has `q`: { { path, title, sub } }. Reads the disk: run in a child process
-- (Search.ask), never on KOReader's own loop.
function Search.findBooks(q)
    local out, seen = {}, {}
    local function add(path, title, sub)
        path = path:gsub("/+", "/")
        if seen[path] or #out >= 20 then return end
        seen[path] = true
        table.insert(out, { path = path, title = title, sub = sub })
    end
    -- The cover browser's book information (titles and authors), when it has it.
    local db = DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3"
    if lfs.attributes(db, "mode") == "file" then
        local ok, err = pcall(function()
            local SQ3 = require("lua-ljsqlite3/init")
            local conn = SQ3.open(db)
            local like = "'%" .. q:gsub("'", "''"):gsub("[%%_]", "") .. "%'"
            local rows = conn:exec("SELECT directory, filename, title, authors FROM bookinfo WHERE lower(title) LIKE " .. like
                .. " OR lower(authors) LIKE " .. like .. " OR lower(filename) LIKE " .. like .. " LIMIT 40;")
            conn:close()
            if rows and rows[1] then
                for i = 1, #rows[1] do
                    local path = (rows[1][i] or "") .. (rows[2][i] or "")
                    if lfs.attributes(path, "mode") == "file" then
                        local title = rows[3][i]
                        if not title or title == "" then title = rows[2][i] end
                        add(path, tostring(title), rows[4][i] and tostring(rows[4][i]):gsub("\n", ", ") or nil)
                    end
                end
            end
        end)
        if not ok then logger.warn("Apps search: book information:", err) end
    end
    -- File names under the home folder (a few levels down).
    local home = G_reader_settings:readSetting("home_dir") or require("apps/filemanager/filemanagerutil").getDefaultDir()
    local count = 0
    local function walk(dir, depth)
        if depth > 4 or count > 4000 or #out >= 20 then return end
        local ok, iter, dirobj = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, dirobj do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                count = count + 1
                local path = dir .. "/" .. name
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" and not name:match("%.sdr$") then
                    walk(path, depth + 1)
                elseif mode == "file" then
                    local ext = name:match("%.([%w]+)$")
                    if ext and BOOK[ext:lower()] and name:lower():find(q, 1, true) then
                        add(path, (name:gsub("%.[%w]+$", "")), dir:match("([^/]+)$"))
                    end
                end
            end
        end
    end
    if home then walk(home, 1) end
    return out
end

-- Notebooks by name, until Notes searches for itself.
local function notebooks(ui, q)
    local notes = ui and ui.notes
    if not (notes and notes.store) then return {} end
    local out = {}
    local ok, list = pcall(function() return notes.store:list() end)
    for __, n in ipairs(ok and list or {}) do
        if #out < 20 and (n.name or ""):lower():find(q, 1, true) then
            table.insert(out, { title = n.name, icon = "notebook-pen", open = function()
                local PS = require("pluginshare")
                local v = PS.appsView and PS.appsView()
                if v and v.openNotebook then v:openNotebook(n.id) else notes:open(n.id) end
            end })
        end
    end
    return out
end

--- The books found (a child's answer) as a group of results.
function Search.bookGroup(found)
    local items = {}
    for __, b in ipairs(found or {}) do
        table.insert(items, { title = b.title, sub = b.sub, open = openBook(b.path) })
    end
    if #items == 0 then return nil end
    return { key = "books", name = _("Books"), icon = "book-open", items = items }
end

--- Every app's results for `q` from what they hold in memory (no disk, no
-- network: at once): { { key, name, icon, items } } in order, empty groups
-- left out. The books come after, from a child process.
function Search.run(ui, q)
    q = (q or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return {} end
    local groups = {}
    local function add(key, name, icon, fn)
        local ok, items = pcall(fn, q)
        if not ok then logger.warn("Apps search:", key, items) items = {} end
        if type(items) == "table" and #items > 0 then table.insert(groups, { key = key, name = name, icon = icon, items = items }) end
    end
    -- The launcher's own: its apps and screens (tiles turned off too), the Settings pages and each setting.
    add("apps", _("Apps and settings"), "app-window", function(x)
        local PS = require("pluginshare")
        local view = PS.appsView and PS.appsView()
        local out = {}
        if view then
            for __, t in ipairs(view:tiles(true)) do
                if not t.pin and not t.groupTile and _(t.name):lower():find(x, 1, true) then
                    table.insert(out, { title = _(t.name), sub = _("App"), open = function()
                        view.mode = "tiles"
                        view:open(t)
                    end })
                end
            end
        end
        local seen = {}
        for __, r in ipairs(out) do seen[r.title:lower()] = true end
        for key, e in pairs(PS.settingsApps or {}) do
            local name = e.name or key
            -- (One that's an app too, such as Fonts, is listed once, as the app.)
            -- (Hidden from the Settings list: found here still, and a hold shows it there again;
            -- one that's an app too gets that on the app's result.)
            local Hub = require("appshub")
            local hidden = view and Hub.isHidden(view, key)
            local function showAgain()
                KO.list(name, { { text = _("Show in Settings"), fn = function()
                    Hub.setHidden(view, key, false)
                    KO.toast(_("Shown in Settings again."), 3)
                end } })
            end
            if hidden and name:lower():find(x, 1, true) and seen[name:lower()] then
                for __, r in ipairs(out) do
                    if r.title:lower() == name:lower() and not r.hold then
                        r.sub = (r.sub and r.sub ~= "" and (r.sub .. " · ") or "") .. _("hidden from Settings (hold to show it)")
                        r.hold = showAgain
                    end
                end
            end
            if name:lower():find(x, 1, true) and not seen[name:lower()] then
                table.insert(out, { title = name, sub = hidden and _("Settings · hidden from the list (hold to show it)") or _("Settings"), open = function()
                    if view then view.mode = "hub" end
                    pcall(e.open)
                end, hold = hidden and showAgain or nil })
            end
        end
        -- Each setting by its name ("labels" finds Button labels): an app's `settings` list, or the
        -- names in its `rows` (as its settings page draws them), opened at that row.
        local keys = {}
        for key in pairs(PS.settingsApps or {}) do table.insert(keys, key) end
        table.sort(keys)
        local found = 0
        for __, key in ipairs(keys) do
            local e = PS.settingsApps[key]
            local where = require("ffi/util").template(_("%1 settings"), e.name or key)
            local list = {}
            if e.settings then
                local ok, l = pcall(e.settings)
                if ok and type(l) == "table" then list = l end
            elseif e.rows then
                local ok, rows = pcall(e.rows)
                for __, r in ipairs(ok and type(rows) == "table" and rows or {}) do
                    if r and type(r[1]) == "string" and r[1] ~= "" then
                        table.insert(list, { name = r[1], open = function() e.open(r[1]) end })
                    end
                end
            end
            for __, it in ipairs(list) do
                local id = key .. "|" .. tostring(it.name):lower()
                if found < 30 and type(it.name) == "string" and it.name:lower():find(x, 1, true) and not seen[id] then
                    found = found + 1
                    seen[id] = true
                    table.insert(out, { title = it.name, sub = it.where or where, open = function()
                        if view then view.mode = "hub" end
                        pcall(it.open)
                    end })
                end
            end
        end
        return out
    end)
    if not registry.notes then add("notes", _("Notebooks"), "notebook-pen", function(x) return notebooks(ui, x) end) end
    local rank = {}
    for i, k in ipairs(ORDER) do rank[k] = i end
    local list = {}
    for __, e in pairs(registry) do table.insert(list, e) end
    table.sort(list, function(a, b) return (rank[a.key] or 99) < (rank[b.key] or 99) end)
    for __, e in ipairs(list) do add(e.key, e.name, e.icon, e.search) end
    return groups
end

-- ------------------------------------------------------------------ the screen (the launcher's "search" mode)

function Search.ask(view, again)
    require("appsko").askText{ title = _("Search"), text = again and view.searchQuery or "",
        hint = _("Books, notebooks, tasks, devices…"), ok = _("Search"), okIcon = "search", needsText = true,
        done = function(q) Search.start(view, q) end }
end

--- Shows the results at once (what the apps hold in memory), and the books
-- when a child process has looked for them (added then: the screen never waits).
function Search.start(view, q)
    view.searchQuery = q
    view.searchResults = Search.run(view:currentUI(), q)
    view.searchBusy = true
    view.mode, view.searchPage = "search", 1
    view:render()
    UIManager:setDirty(view, "full")
    local lq = q:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local ffiutil = require("ffi/util")
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, found = pcall(Search.findBooks, lq)
        ffiutil.writeToFD(write_fd, require("dump")(ok and found or {}), true)
    end, true)
    local function done(found)
        if view.searchQuery ~= q then return end
        view.searchBusy = nil
        local g = Search.bookGroup(found)
        if g then table.insert(view.searchResults, 1, g) end
        if view.mode == "search" and not view.closed then
            view:render()
            if UIManager:getTopmostVisibleWidget() == view then UIManager:setDirty(view, g and "full" or "ui") end
        end
    end
    if not pid then return done({}) end
    local deadline = os.time() + 20
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(0.3, check) end
            ffiutil.terminateSubProcess(pid)
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
            return done({})
        end
        local raw = (size and size > 0) and ffiutil.readAllFromFD(fd) or ""
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
        end
        local fn = raw ~= "" and loadstring("return " .. raw)
        local ok, found = pcall(fn or error)
        done(ok and type(found) == "table" and found or {})
    end
    UIManager:scheduleIn(0.3, check)
end

function Search.draw(view, c)
    local F = c:flow(Bar.H + 8, c.H - 8, view.searchPage or 1)
    local groups = view.searchResults or {}
    if view.searchBusy then
        F:block(40, function(y)
            c:icon("book-open", 14, y + 12, 16)
            c:text(38, y + 26, _("Looking for books…"), 11, { color = C.GREY })
        end)
    end
    if #groups == 0 and not view.searchBusy then
        F:block(60, function(y)
            c:text(c.W / 2, y + 36, _("Nothing found."), 12, { align = "middle", color = C.GREY })
        end)
    end
    for __, g in ipairs(groups) do
        F:block(34, function(y)
            c:icon(g.icon or "search", 14, y + 12, 16)
            c:text(38, y + 26, g.name:upper(), 9.5, { bold = true, color = C.GREY })
        end, 46)
        for __, it in ipairs(g.items) do
            F:block(46, function(y)
                c:text(38, y + 21, it.title or "", 12, { bold = true, maxw = c.W - 60 })
                if it.sub and it.sub ~= "" then c:text(38, y + 38, it.sub, 10, { color = C.GREY, maxw = c.W - 60 }) end
                c:hline(38, y + 45, c.W - 38)
                c:hit(0, y, c.W, 46, function()
                    view.mode = "tiles"
                    view:render()
                    if it.open then it.open() end
                end, it.hold)
            end)
        end
    end
    view.pages = F:pages()
    if (view.searchPage or 1) > view.pages then
        view.searchPage = view.pages
        return view:render()
    end
    local back = function()
        view.mode = "tiles"
        if view.switcherBack then view.switcherBack = nil UIManager:close(view) else view:refresh() end
    end
    Bar.draw(c, {
        title = "“" .. (view.searchQuery or "") .. "”",
        back = back,
        home = function() view.switcherBack = nil view.mode = "tiles" view:refresh() end,
        buttons = { { "search", function() Search.ask(view, true) end } },
        pager = { page = view.searchPage or 1, pages = view.pages or 1, turn = function(d) view:turn(d) end },
        clock = true,
        refresh = function() view:reload() end,
        bell = require("pluginshare").showNotifications and function() view:showNotifications() end or nil,
        menu = function() view:moreMenu() end,
    })
end

return Search
