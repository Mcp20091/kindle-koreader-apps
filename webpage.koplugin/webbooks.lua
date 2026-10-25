--[[--
Books on the web page: each book in a folder with its title, author and how
far it is read (from KOReader's own records), its cover, opening it on the
Kindle, marking it reading, on hold or finished, several files downloaded as one zip, and
the reading statistics (today, days in a row, each day, each book).
]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local Files = require("webfiles")

local Web = {}

-- What counts as a book: the Library app's list (librarymodel.lua M.BOOK_EXT). Text files, web
-- pages and pictures are other files, as on the Kindle.
local BOOK = { epub = true, kepub = true, pdf = true, mobi = true, azw = true, azw3 = true, fb2 = true, fbz = true,
    cbz = true, cbr = true, cbt = true, djvu = true, djv = true, docx = true, rtf = true, chm = true, doc = true,
    pdb = true, prc = true, xps = true, oxps = true }

function Web.isBook(name)
    return BOOK[(name:match("%.([%w]+)$") or ""):lower()] == true
end

-- KOReader's Cover browser record of a book (title, authors, cover), when it has read it.
local function bookInfo(full, withCover)
    local ok, BIM = pcall(require, "bookinfomanager")
    if not (ok and BIM and BIM.getBookInfo) then return nil end
    local got, info = pcall(BIM.getBookInfo, BIM, full, withCover)
    return got and info or nil
end

-- The open book's own settings (kept in memory while it is open), else the file's.
local function docSettings(full)
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local r = ReaderUI and ReaderUI.instance
    if r and r.document and r.document.file == full and r.doc_settings then return r.doc_settings, true end
    return require("docsettings"):open(full), false
end

--- What is known about a book: { title, authors, series, seriesIndex, percent, status ("new"
-- when never opened, "reading", "abandoned" (On hold) or "complete"), cover,
-- unread = true when KOReader hasn't read its title and cover yet }.
function Web.book(full)
    local out = {}
    local info = bookInfo(full, false)
    if not info then out.unread = true end
    if info then
        out.title = info.title ~= "" and info.title or nil
        out.authors = info.authors ~= "" and info.authors or nil
        out.cover = info.has_cover and true or nil
        if type(info.series) == "string" and info.series ~= "" then
            out.series, out.seriesIndex = info.series, tonumber(info.series_index)
        end
    end
    local DocSettings = require("docsettings")
    local ok, ds, open = pcall(docSettings, full)
    if ok and ds and (open or DocSettings:hasSidecarFile(full)) then
        local pct = ds:readSetting("percent_finished")
        if type(pct) == "number" then out.percent = math.floor(pct * 100 + 0.5) end
        local sm = ds:readSetting("summary")
        out.status = type(sm) == "table" and sm.status or "reading"
    else
        out.status = "new"
    end
    return out
end

--- A book's cover as a PNG file (made once per version of the book), or nil.
function Web.coverFile(full)
    local a = lfs.attributes(full)
    if not a then return nil end
    local dir = DataStorage:getDataDir() .. "/cache/webpage-covers"
    require("util").makePath(dir)
    local key = require("ffi/sha2").md5(full .. ":" .. tostring(a.modification) .. ":" .. tostring(a.size))
    local path = dir .. "/" .. key .. ".png"
    if lfs.attributes(path, "mode") == "file" then return path end
    local info = bookInfo(full, true)
    local bb = info and info.cover_bb
    if not bb then return nil end
    local w, h = bb:getWidth(), bb:getHeight()
    local k = math.min(1, 360 / math.max(w, h))
    local RenderImage = require("ui/renderimage")
    local small = k < 1 and RenderImage:scaleBlitBuffer(bb, math.floor(w * k), math.floor(h * k), true) or bb
    local ok = pcall(function() small:writePNG(path) end)
    if small ~= bb then small:free() end
    return ok and path or nil
end

-- ------------------------------------------------------------------ reading statistics

--- From KOReader's reading statistics (read only): { today, streak, days =
-- { { day, seconds } } for the last 30 days, books = { { title, authors,
-- seconds, pages, last } } most recent first, total }; nil without them.
function Web.reading()
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local SQ3 = require("lua-ljsqlite3/init")
    local conn = SQ3.open(path)
    local ok, out = pcall(function()
        local now = os.date("*t")
        local midnight = os.time({ year = now.year, month = now.month, day = now.day, hour = 0 })
        -- What the Launcher's statistics leave out (Wikipedia's articles, OneNote pages read), the same here.
        local okS, Stats = pcall(require, "appsstats")
        local skipBook = okS and Stats.skipWhere and Stats.skipWhere(conn, "id_book")
        local skipId = okS and Stats.skipWhere and Stats.skipWhere(conn, "id")
        local byDay = {}
        local rows = conn:exec(string.format([[
            SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS d, sum(duration)
            FROM page_stat_data WHERE start_time >= %d]], midnight - 400 * 86400)
            .. (skipBook and (" AND " .. skipBook) or "") .. " GROUP BY d;")
        if rows and rows[1] then
            for i = 1, #rows[1] do byDay[rows[1][i]] = tonumber(rows[2][i]) or 0 end
        end
        local days = {}
        for i = 29, 0, -1 do
            local d = os.date("%Y-%m-%d", midnight - i * 86400 + 12 * 3600)
            table.insert(days, { day = d, seconds = byDay[d] or 0 })
        end
        -- Days in a row: back from today (or yesterday while today has none yet).
        local streak, t = 0, midnight + 12 * 3600
        if not byDay[os.date("%Y-%m-%d", t)] then t = t - 86400 end
        while byDay[os.date("%Y-%m-%d", t)] do
            streak = streak + 1
            t = t - 86400
        end
        local books = {}
        local okb, b = pcall(conn.exec, conn, [[SELECT title, authors, total_read_time, total_read_pages, last_open, pages, id
            FROM book WHERE total_read_time > 0]] .. (skipId and (" AND " .. skipId) or "") .. " ORDER BY last_open DESC LIMIT 40;")
        if okb and b and b[1] then
            for i = 1, #b[1] do
                table.insert(books, { title = b[1][i], authors = b[2][i], seconds = tonumber(b[3][i]) or 0,
                    read = tonumber(b[4][i]) or 0, last = tonumber(b[5][i]) or 0, pages = tonumber(b[6][i]), id = tonumber(b[7][i]) })
            end
        end
        local total = tonumber(conn:rowexec("SELECT sum(duration) FROM page_stat_data"
            .. (skipBook and (" WHERE " .. skipBook) or "") .. ";")) or 0
        return { countWikipedia = okS and Stats.countWikipedia and Stats.countWikipedia() or false, today = byDay[os.date("%Y-%m-%d", midnight + 12 * 3600)] or 0, streak = streak, days = days, books = books, total = total }
    end)
    conn:close()
    return ok and out or nil
end

-- ------------------------------------------------------------------ fixing the statistics

-- The Launcher plugin's (Reading statistics on the Kindle uses the same), or nil without it.
local function sessions()
    local ok, S = pcall(require, "appssessions")
    return ok and S or nil
end
local NEEDS = "Fixing reading sessions needs the Launcher plugin (apps.koplugin)."

--- A day's reading, in sessions (a book read with no break over 10 minutes):
-- { { book, title, from, to, seconds, pages } } in time order, for "YYYY-MM-DD".
function Web.day(day)
    local S = sessions()
    if not S then return nil, NEEDS end
    return S.day(day)
end

--- Forgets a session (a book's reading from `from` to `to`, Unix seconds), or
-- with no times every bit of that book's reading. Returns nil or why not.
function Web.forget(book, from, to)
    local S = sessions()
    if not S then return NEEDS end
    local done, why = S.forget(book, from, to)
    if not done then return why end
end

--- Changes a session (a book's reading from `from` to `to`) to run from
-- `start` to `finish` (Unix seconds). Returns nil or why not.
function Web.editSession(book, from, to, start, finish)
    local S = sessions()
    if not S then return NEEDS end
    local done, why = S.edit(book, from, to, start, finish)
    if not done then return why end
end

-- ------------------------------------------------------------------ progress sync

-- The open book's title (or its file's name).
local function bookTitleOf(r)
    local props = r.doc_props or {}
    local title = props.display_title or props.title
    if not title or title == "" then title = (r.document.file or ""):match("([^/]+)$") end
    return title
end

--- KOReader's progress sync for the book open on the Kindle: { available,
-- book (its title, or nil with none open), signedIn, auto }.
function Web.kosync()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local r = ReaderUI and ReaderUI.instance
    local k = r and r.kosync
    local out = { available = k ~= nil }
    if r and r.document then out.book = bookTitleOf(r) end
    if k and k.settings then
        out.signedIn = k.settings.username ~= nil and k.settings.userkey ~= nil
        out.auto = k.settings.auto_sync == true
    end
    return out
end

function Web.routes(server)
    -- The books in a folder: { [name] = { title, authors, percent, status, cover } }.
    server:route("GET", "^/api/books$", function(req, res)
        local dir = Files.full(req.query.path)
        if not dir or lfs.attributes(dir, "mode") ~= "directory" then return res:error(404, "No such folder") end
        local out, unread = {}, {}
        for name in lfs.dir(dir) do
            if name:sub(1, 1) ~= "." and Web.isBook(name) and lfs.attributes(dir .. "/" .. name, "mode") == "file" then
                out[name] = Web.book(dir .. "/" .. name)
                if out[name].unread then
                    table.insert(unread, { filepath = dir .. "/" .. name, cover_specs = { max_cover_w = 360, max_cover_h = 540 } })
                end
            end
        end
        -- Titles and covers KOReader hasn't read yet: read in the background
        -- (as the Cover browser does), so a second look has them.
        local pending = false
        if #unread > 0 then
            local ok, BIM = pcall(require, "bookinfomanager")
            if ok and BIM and BIM.extractInBackground then
                pending = BIM:isExtractingInBackground() or (pcall(BIM.extractInBackground, BIM, unread))
            end
        end
        res:json({ books = out, pending = pending })
    end)

    server:route("GET", "^/api/books/cover$", function(req, res)
        local full = Files.full(req.query.path)
        if not full or lfs.attributes(full, "mode") ~= "file" then return res:error(404, "No such file") end
        local path = Web.coverFile(full)
        if not path then return res:error(404, "No cover") end
        res:file(path, "cover.png", true)
    end)

    -- Opens it on the Kindle (in place of the book that is open, if any).
    server:route("POST", "^/api/books/open$", function(req, res)
        local full = Files.full(req.json().path)
        if not full or lfs.attributes(full, "mode") ~= "file" then return res:error(404, "No such file") end
        UIManager:nextTick(function()
            local ReaderUI = require("apps/reader/readerui")
            if ReaderUI.instance and ReaderUI.instance.document and ReaderUI.instance.document.file == full then return end
            ReaderUI:showReader(full)
        end)
        res:json({ ok = true })
    end)

    -- { path, status = "reading" | "abandoned" | "complete" }: Reading, On hold
    -- or Finished, as KOReader's own buttons (and the Library) set it.
    server:route("POST", "^/api/books/status$", function(req, res)
        local b = req.json()
        local full = Files.full(b.path)
        if not full or lfs.attributes(full, "mode") ~= "file" then return res:error(404, "No such file") end
        if b.status ~= "complete" and b.status ~= "reading" and b.status ~= "abandoned" then
            return res:error(400, "Reading, on hold or finished?")
        end
        local ds = docSettings(full)
        local sm = ds:readSetting("summary") or {}
        sm.status = b.status
        require("apps/filemanager/filemanagerutil").saveSummary(ds, sm)
        local okb, BL = pcall(require, "ui/widget/booklist")
        if okb and BL and BL.setBookInfoCacheProperty then pcall(BL.setBookInfoCacheProperty, full, "status", b.status) end
        local LM = package.loaded["librarymodel"]
        if LM and LM.changed then pcall(LM.changed) end
        res:json({ ok = true, book = Web.book(full) })
    end)

    -- Several files (or folders) as one zip: ?paths=["/documents/a.epub",…].
    server:route("GET", "^/api/books/zip$", function(req, res)
        local ok, paths = pcall(require("json").decode, req.query.paths or "")
        if not ok or type(paths) ~= "table" or #paths == 0 then return res:error(400, "Nothing chosen") end
        local cache = DataStorage:getDataDir() .. "/cache"
        require("util").makePath(cache)
        local zip = cache .. "/webpage-files.zip"
        os.remove(zip)
        local Archiver = require("ffi/archiver")
        local w = Archiver.Writer:new{}
        if not w:open(zip, "zip") then return res:error(500, "Can't write the zip") end
        w:setZipCompression("store")
        for __, p in ipairs(paths) do
            local full = Files.full(p)
            local name = full and full:match("[^/]+$")
            if full and full ~= Files.root() and lfs.attributes(full) then
                w:addPath(name, full, true)
            end
        end
        w:close()
        res:file(zip, "kindle-files-" .. os.date("%Y-%m-%d") .. ".zip")
        os.remove(zip)
    end)

    server:route("GET", "^/api/reading/day$", function(req, res)
        local sessions, why = Web.day(req.query.day)
        if not sessions then return res:error(400, why) end
        res:json({ day = req.query.day, sessions = sessions })
    end)

    -- { book, from, to } forgets a session; { book } alone all of that book's reading.
    server:route("POST", "^/api/reading/forget$", function(req, res)
        local b = req.json()
        local why = Web.forget(b.book, b.from, b.to)
        if why then return res:error(400, why) end
        res:json({ ok = true })
    end)

    -- { book, from, to, start, finish } moves, shortens or lengthens a session.
    server:route("POST", "^/api/reading/edit$", function(req, res)
        local b = req.json()
        local why = Web.editSession(b.book, b.from, b.to, b.start, b.finish)
        if why then return res:error(400, why) end
        res:json({ ok = true })
    end)

    server:route("GET", "^/api/kosync$", function(req, res) res:json(Web.kosync()) end)

    -- { action = "push" | "pull" | "auto" }: as KOReader's own Progress sync menu (its messages show on the Kindle).
    server:route("POST", "^/api/kosync$", function(req, res)
        local ReaderUI = package.loaded["apps/reader/readerui"]
        local r = ReaderUI and ReaderUI.instance
        if not (r and r.kosync) then return res:error(400, "Open a book on the Kindle first") end
        local events = { push = "KOSyncPushProgress", pull = "KOSyncPullProgress", auto = "KOSyncToggleAutoSync" }
        local ev = events[req.json().action]
        if not ev then return res:error(400, "Push, pull or auto?") end
        UIManager:nextTick(function() r:handleEvent(require("ui/event"):new(ev)) end)
        res:json({ ok = true })
    end)

    -- Wikipedia's articles in the statistics or not (the Launcher's Reading statistics has the same switch).
    server:route("POST", "^/api/reading/wikipedia$", function(req, res)
        local okS, Stats = pcall(require, "appsstats")
        if not (okS and Stats.setCountWikipedia) then return res:error(404, NEEDS) end
        Stats.setCountWikipedia(req.json().on == true)
        G_reader_settings:flush()
        res:json({ ok = true })
    end)

    server:route("GET", "^/api/reading$", function(req, res)
        local r = Web.reading()
        if not r then return res:json({ available = false }) end
        r.available = true
        res:json(r)
    end)
end

return Web
