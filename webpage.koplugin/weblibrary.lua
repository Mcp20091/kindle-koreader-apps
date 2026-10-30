--[[--
The Files tab's library tools: search every folder (names, and titles and
authors from KOReader's book records), the newest files, what uses the
space, getting a file from a link (in a child process), KOReader's
collections, a book's details and its highlights and notes.
]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Files = require("webfiles")

local Web = {}

-- ------------------------------------------------------------------ every file

-- Folders not walked for search and the newest files (KOReader's own and the
-- Kindle's system folders); still counted for the space they use.
local SYSTEM = { koreader = true, system = true, extensions = true }

local walked -- { at, list = { { rel, name, dir, size, mtime, system } }, sizes = { [rel] = bytes } }

--- Every file and folder under the root (at most 30,000, in at most 4 s),
-- kept for 30 s. Hidden names and books' .sdr folders are left out.
function Web.walk()
    if walked and os.time() - walked.at < 30 then return walked end
    local root = Files.root()
    local list, sizes = {}, {}
    local started = os.clock()
    local function go(dir, rel, system)
        if #list >= 30000 or os.clock() - started > 4 then return 0 end
        local total = 0
        local ok, iter, state = pcall(lfs.dir, dir)
        if not ok then return 0 end
        for name in iter, state do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                local full = dir .. "/" .. name
                local a = (lfs.symlinkattributes or lfs.attributes)(full)
                if a and a.mode == "directory" and not name:match("%.sdr$") then
                    local r = rel .. "/" .. name
                    local sys = system or (rel == "" and SYSTEM[name:lower()]) or false
                    table.insert(list, { rel = r, name = name, dir = true, mtime = a.modification or 0, system = sys or nil })
                    total = total + go(full, r, sys)
                elseif a and a.mode == "file" then
                    total = total + (a.size or 0)
                    table.insert(list, { rel = rel .. "/" .. name, name = name, size = a.size or 0, mtime = a.modification or 0, system = system or nil })
                elseif a and a.mode == "directory" then
                    -- A book's .sdr folder: its size counts for the folder it is in.
                    for sub in lfs.dir(full) do
                        local sa = sub ~= "." and sub ~= ".." and lfs.attributes(full .. "/" .. sub)
                        if sa and sa.mode == "file" then total = total + (sa.size or 0) end
                    end
                end
            end
        end
        sizes[rel == "" and "/" or rel] = total
        return total
    end
    go(root, "", false)
    walked = { at = os.time(), list = list, sizes = sizes, partial = #list >= 30000 or os.clock() - started > 4 }
    return walked
end

--- Forgets the last walk (after a change to the files).
function Web.forget() walked = nil end

-- KOReader's book records (the Cover browser's), opened read-only, or nil.
local function bookDb()
    local path = DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok, conn = pcall(function() return require("lua-ljsqlite3/init").open(path, "ro") end)
    return ok and conn or nil
end

local function likeText(s)
    return "'%" .. s:gsub("'", "''"):gsub("[%%_\\]", "\\%0") .. "%' ESCAPE '\\'"
end

--- Files and folders anywhere whose name, or book title or author, has `q`:
-- { { path, name, dir, size, mtime, title, authors } } (at most 200).
function Web.search(q)
    q = tostring(q or ""):match("^%s*(.-)%s*$")
    if #q < 2 then return {}, "Type at least 2 letters" end
    local needle = q:lower()
    local out, seen = {}, {}
    local w = Web.walk()
    for __, e in ipairs(w.list) do
        if #out >= 200 then break end
        if not e.system and e.name:lower():find(needle, 1, true) then
            table.insert(out, { path = e.rel, name = e.name, dir = e.dir, size = e.size, mtime = e.mtime })
            seen[e.rel] = out[#out]
        end
    end
    -- Titles and authors from KOReader's records.
    local conn = bookDb()
    if conn then
        local ok, rows = pcall(conn.exec, conn, "SELECT directory, filename, title, authors FROM bookinfo WHERE title LIKE " ..
            likeText(q) .. " OR authors LIKE " .. likeText(q) .. " LIMIT 200;")
        pcall(conn.close, conn)
        for i = 1, ok and rows and rows[1] and #rows[1] or 0 do
            local rel = Files.relative((rows[1][i] or ""):gsub("/+$", "") .. "/" .. (rows[2][i] or ""))
            if rel and lfs.attributes(Files.full(rel) or "", "mode") == "file" then
                local e = seen[rel]
                if not e and #out < 200 then
                    local a = lfs.attributes(Files.full(rel))
                    e = { path = rel, name = rows[2][i], size = a.size, mtime = a.modification }
                    table.insert(out, e)
                    seen[rel] = e
                end
                if e then e.title, e.authors = rows[3][i], rows[4][i] end
            end
        end
    end
    return out, nil, w.partial
end

--- The newest files (not in KOReader's or the Kindle's own folders): at most `n`.
function Web.recent(n)
    local files = {}
    for __, e in ipairs(Web.walk().list) do
        if not e.dir and not e.system then table.insert(files, e) end
    end
    table.sort(files, function(a, b) return a.mtime > b.mtime end)
    local out = {}
    for i = 1, math.min(n or 40, #files) do
        local e = files[i]
        table.insert(out, { path = e.rel, name = e.name, size = e.size, mtime = e.mtime })
    end
    return out
end

--- What uses the space: the biggest folders and files (25 of each), and the
-- disk's total and free space.
function Web.usage()
    local w = Web.walk()
    local folders, files = {}, {}
    for rel, size in pairs(w.sizes) do
        if rel ~= "/" then table.insert(folders, { path = rel, size = size }) end
    end
    for __, e in ipairs(w.list) do
        if not e.dir then table.insert(files, { path = e.rel, name = e.name, size = e.size, mtime = e.mtime }) end
    end
    table.sort(folders, function(a, b) return a.size > b.size end)
    table.sort(files, function(a, b) return a.size > b.size end)
    local disk = require("util").diskUsage(Files.root()) or {}
    return {
        folders = { unpack(folders, 1, math.min(25, #folders)) },
        files = { unpack(files, 1, math.min(25, #files)) },
        used = w.sizes["/"], total = disk.total, free = disk.available, partial = w.partial,
    }
end

-- ------------------------------------------------------------------ from a link

local fetches = {} -- [key] = { status = "getting" | "done" | "failed", name, message }

-- A file name from the answer's Content-Disposition or the link itself.
local function nameFor(url, headers)
    local cd = headers and (headers["content-disposition"] or "")
    local name = cd and (cd:match("filename%*=[^']*''([^;]+)") or cd:match('filename="([^"]+)"') or cd:match("filename=([^;]+)"))
    if name then name = name:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end) end
    if not name or name == "" then
        name = (url:match("^[^?#]*/([^/?#]+)") or ""):gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
    end
    name = (name or ""):gsub("[/\\%z]", "_"):match("^%s*(.-)%s*$")
    if name == "" or name == "." or name == ".." then name = "download" end
    return name
end

-- In the child: the file at `url` into `dir`. Returns its name, or errors.
local function download(url, dir)
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")
    local tmp = dir .. "/.download-" .. os.time() .. ".part"
    for __ = 1, 6 do
        local http = url:match("^https:") and require("ssl.https") or require("socket.http")
        local f = assert(io.open(tmp, "wb"))
        socketutil:set_timeout(30, 15 * 60)
        local ok, code, headers = pcall(function()
            local __, c, h = http.request{ url = url, method = "GET", sink = socketutil.file_sink and socketutil.file_sink(f) or ltn12.sink.file(f),
                redirect = false, headers = { ["User-Agent"] = "KOReader" } }
            return c, h
        end)
        socketutil:reset_timeout()
        pcall(f.close, f)
        if not ok then
            os.remove(tmp)
            error("Couldn't get it: " .. tostring(code))
        end
        if type(code) == "number" and code >= 300 and code < 400 and headers and headers.location then
            os.remove(tmp)
            local loc = headers.location
            if not loc:match("^%a+://") then loc = url:match("^(%a+://[^/]+)") .. (loc:sub(1, 1) == "/" and loc or ("/" .. loc)) end
            url = loc
        elseif code == 200 then
            local name = nameFor(url, headers)
            local final = dir .. "/" .. name
            os.remove(final)
            assert(os.rename(tmp, final))
            return name
        else
            os.remove(tmp)
            error("The link answered " .. tostring(code))
        end
    end
    error("Too many redirects")
end

--- Starts getting `url` into folder `rel`; returns a key to ask about, or nil, why.
function Web.fetch(url, rel)
    url = tostring(url or ""):match("^%s*(.-)%s*$")
    if not url:match("^https?://[^%s]+$") then return nil, "That isn't a web link (http:// or https://)" end
    local dir = Files.full(rel)
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then return nil, "No such folder" end
    local key = tostring(os.time()) .. tostring(math.random(1000, 9999))
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, name = pcall(download, url, dir)
        ffiutil.writeToFD(write_fd, (ok and "K" or "E") .. tostring(name), true)
    end, true)
    if not pid then return nil, tostring(fd) end
    local state = { status = "getting", folder = rel }
    fetches[key] = state
    local deadline = os.time() + 20 * 60
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(1, check) end
            ffiutil.terminateSubProcess(pid)
            state.status, state.message = "failed", "It took too long"
        else
            local out = (size and size > 0) and ffiutil.readAllFromFD(fd) or "EIt stopped"
            if out:sub(1, 1) == "K" then
                state.status, state.name = "done", out:sub(2)
                Web.forget()
            else
                state.status, state.message = "failed", out:sub(2):gsub("^.-:%d+: ", "")
            end
        end
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
        end
    end
    UIManager:scheduleIn(1, check)
    return key
end

-- ------------------------------------------------------------------ collections

local function collections()
    local ok, RC = pcall(require, "readcollection")
    if not ok then return nil end
    pcall(RC._read, RC)
    return RC.coll and RC or nil
end

--- KOReader's collections: { { name, label, files = { { name, path } } } }, Favorites first.
function Web.collections()
    local RC = collections()
    if not RC then return nil end
    local out = {}
    for name in pairs(RC.coll) do
        local files = {}
        local ok, list = pcall(RC.getOrderedCollection, RC, name)
        for __, item in ipairs(ok and list or {}) do
            local rel = Files.relative(item.file)
            if rel then table.insert(files, { name = item.text or rel:match("[^/]+$"), path = rel }) end
        end
        table.insert(out, { name = name, label = name == RC.default_collection_name and "Favorites" or name, files = files })
    end
    table.sort(out, function(a, b)
        if (a.name == RC.default_collection_name) ~= (b.name == RC.default_collection_name) then return a.name == RC.default_collection_name end
        return a.label:lower() < b.label:lower()
    end)
    return out
end

--- Files (paths from the browser) into a collection (made if `create`), or out of it.
function Web.collect(paths, name, on, create)
    local RC = collections()
    if not RC then return "KOReader's collections aren't available" end
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name == "" then return "Which collection?" end
    if not RC.coll[name] then
        if not create then return "No such collection" end
        RC:addCollection(name)
    end
    for __, rel in ipairs(type(paths) == "table" and paths or {}) do
        local full = Files.full(rel)
        if full and lfs.attributes(full, "mode") == "file" then
            local real = ffiutil.realpath(full) or full
            if on and not RC.coll[name][real] then
                RC:addItem(full, name)
            elseif not on and RC.coll[name][real] then
                RC.coll[name][real] = nil
            end
        end
    end
    RC:write({ [name] = true })
end

-- ------------------------------------------------------------------ a book

local function plain(html)
    if type(html) ~= "string" then return nil end
    local s = html:gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("</[Pp]>", "\n\n"):gsub("<[^>]+>", "")
    s = s:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'")
    s = s:gsub("\n%s*\n%s*\n+", "\n\n"):match("^%s*(.-)%s*$")
    return s ~= "" and s or nil
end

-- The open book's reader, when `full` is the book open now.
local function openReader(full)
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local r = ReaderUI and ReaderUI.instance
    if r and r.document and r.document.file == full then return r end
end

--- A book's metadata from its EPUB package file (the OPF's XML): publisher,
-- published (the year, or as written when not a date), subjects, isbn.
-- (As the Library app's librarymodel.lua M.parseOpf.)
function Web.parseOpf(xml)
    local out = {}
    if type(xml) ~= "string" then return out end
    local meta = xml:match("<[%w:]*metadata.->(.-)</[%w:]*metadata>") or xml
    local function unescape(s)
        s = s:gsub("<!%[CDATA%[(.-)%]%]>", "%1"):gsub("<[^>]+>", "")
        s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&#39;", "'"):gsub("&amp;", "&")
        return (s:gsub("%s+", " "):match("^%s*(.-)%s*$"))
    end
    local function all(tag)
        local list = {}
        for attrs, body in meta:gmatch("<dc:" .. tag .. "([^>]*)>(.-)</dc:" .. tag .. ">") do
            local v = unescape(body)
            if v ~= "" then table.insert(list, { v = v, attrs = attrs }) end
        end
        return list
    end
    local p = all("publisher")[1]
    out.publisher = p and p.v or nil
    local dates = all("date")
    local pick
    for __, d in ipairs(dates) do
        if d.attrs:find("publication") or d.attrs:find("original") then pick = d break end
    end
    pick = pick or dates[1]
    if pick then
        local y = pick.v:match("^(%d%d%d%d)")
        -- (0101 is what some tools write when they don't know)
        if y and y ~= "0101" and y ~= "0001" then out.published = y
        elseif not y then out.published = pick.v end
    end
    local subjects = {}
    for __, sub in ipairs(all("subject")) do
        if #subjects < 6 then table.insert(subjects, sub.v) end
    end
    if #subjects > 0 then out.subjects = table.concat(subjects, ", ") end
    for __, id in ipairs(all("identifier")) do
        local digits = id.v:gsub("^[Uu][Rr][Nn]:[Ii][Ss][Bb][Nn]:", ""):gsub("[%s%-]", "")
        if (id.attrs:lower():find("isbn") or id.v:lower():find("isbn")) and digits:match("^%d+[%dXx]$") then
            out.isbn = digits
            break
        elseif #digits == 13 and digits:match("^97[89]%d+$") then
            out.isbn = digits
            break
        end
    end
    return out
end

-- An EPUB's own metadata (publisher, published, subjects, isbn).
local function opf(full)
    if not full:lower():match("%.epub$") then return {} end
    local ok, res = pcall(function()
        local arc = require("ffi/archiver").Reader:new()
        if not arc:open(full) then return {} end
        -- (its entries are found only once listed)
        for __ in arc:iterate() do end
        local container = arc:extractToMemory("META-INF/container.xml")
        local path = container and container:match('<rootfile[^>]-full%-path="([^"]+)"')
        local xml = path and arc:extractToMemory(path)
        arc:close()
        return Web.parseOpf(xml)
    end)
    return ok and type(res) == "table" and res or {}
end

--- A book's details: title, authors, series, description, language, pages,
-- publisher, published, subjects, ISBN, how far read, its reading (time,
-- pages, first and last read, days, pace) and how many highlights and notes it has.
function Web.details(rel)
    local full = Files.full(rel)
    if not full or lfs.attributes(full, "mode") ~= "file" then return nil, "No such file" end
    local out = require("webbooks").book(full)
    out.unread = nil
    local okb, BIM = pcall(require, "bookinfomanager")
    local info = okb and BIM and BIM.getBookInfo and select(2, pcall(BIM.getBookInfo, BIM, full, false))
    if type(info) == "table" then
        out.series = info.series ~= "" and info.series or nil
        out.seriesIndex = info.series_index
        out.description = plain(info.description)
        out.language = info.language ~= "" and info.language or nil
        out.pages = info.pages
        out.keywords = info.keywords ~= "" and info.keywords or nil
    end
    local o = opf(full)
    out.publisher, out.published, out.isbn = o.publisher, o.published, o.isbn
    out.subjects = o.subjects or (out.keywords and (out.keywords:gsub("%s*\n%s*", ", ")))
    local r = openReader(full)
    local ds = r and r.doc_settings or require("docsettings"):open(full)
    -- (its pages as KOReader counted them when read, before the Cover browser's)
    out.pages = tonumber(ds:readSetting("doc_pages")) or tonumber(out.pages)
    local anns = (r and r.annotation and r.annotation.annotations) or ds:readSetting("annotations") or {}
    local highlights, notes = 0, 0
    for __, a in ipairs(anns) do
        if a.text and a.text ~= "" then highlights = highlights + 1 end
        if a.note and a.note ~= "" then notes = notes + 1 end
    end
    out.highlights, out.notes = highlights, notes
    local sm = ds:readSetting("summary")
    if type(sm) == "table" and sm.modified then out.statusChanged = sm.modified end
    -- KOReader's reading statistics (found by the book's checksum).
    local md5 = ds:readSetting("partial_md5_checksum")
    if not md5 then
        local okm, m = pcall(require("util").partialMD5, full)
        md5 = okm and m or nil
    end
    local stats = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if md5 and lfs.attributes(stats, "mode") == "file" then
        local okq, row = pcall(function()
            local conn = require("lua-ljsqlite3/init").open(stats, "ro")
            local got
            local okr, err = pcall(function()
                local id, last = conn:rowexec("SELECT id, last_open FROM book WHERE md5 = '" .. md5:gsub("[^%x]", "") .. "';")
                if not id then return end
                id = tonumber(id)
                local secs, read, first = conn:rowexec(string.format(
                    "SELECT sum(duration), count(DISTINCT page), min(start_time) FROM page_stat WHERE id_book = %d;", id))
                local days = conn:rowexec(string.format([[
                    SELECT count(DISTINCT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime'))
                    FROM page_stat_data WHERE id_book = %d;]], id))
                got = { last = tonumber(last), seconds = tonumber(secs) or 0, read = tonumber(read) or 0,
                    first = tonumber(first), days = tonumber(days) or 0 }
            end)
            conn:close()
            if not okr then error(err) end
            return got
        end)
        if okq and row then
            out.readTime, out.readPages, out.lastRead = row.seconds, row.read, row.last
            out.firstRead, out.readDays = row.first, row.days
            -- Pages an hour, once there's enough reading to tell.
            if row.seconds > 300 and row.read > 0 then out.pace = math.floor(row.read / (row.seconds / 3600) + 0.5) end
        end
    end
    local a = lfs.attributes(full)
    out.size, out.added = a.size, a.change
    out.name = full:match("[^/]+$")
    out.folder = Files.relative(full:match("^(.*)/[^/]+$"))
    -- The collections it's in (Favorites as named on the Kindle).
    local RC = collections()
    if RC then
        local real = ffiutil.realpath(full) or full
        out.collections = {}
        for name, items in pairs(RC.coll) do
            if items[real] then table.insert(out.collections, name == RC.default_collection_name and "Favorites" or name) end
        end
        table.sort(out.collections, function(x, y) return x:lower() < y:lower() end)
    end
    return out
end

--- A book's highlights and notes, in reading order:
-- { title, authors, items = { { text, note, chapter, page, datetime, kind } } }.
function Web.highlights(rel)
    local full = Files.full(rel)
    if not full or lfs.attributes(full, "mode") ~= "file" then return nil, "No such file" end
    local r = openReader(full)
    local ds = r and r.doc_settings or require("docsettings"):open(full)
    local anns = (r and r.annotation and r.annotation.annotations) or ds:readSetting("annotations") or {}
    local items = {}
    for __, a in ipairs(anns) do
        if (a.text and a.text ~= "") or (a.note and a.note ~= "") then
            table.insert(items, { text = a.text, note = a.note, chapter = a.chapter, page = a.pageno or (type(a.page) == "number" and a.page) or nil,
                datetime = a.datetime, kind = a.drawer, color = a.color })
        end
    end
    local book = require("webbooks").book(full)
    return { title = book.title or full:match("[^/]+$"), authors = book.authors, items = items }
end

-- ------------------------------------------------------------------ routes

-- The Library app's settings (library.koplugin's librarysettings), as the Kindle's Library settings.
local SETTINGS = {
    { key = "view", default = "covers", values = { covers = true, list = true } },
    { key = "start", default = "home", values = { home = true, last = true } },
    { key = "home_first", default = "places", values = { places = true, books = true } },
    { key = "hidden", default = false },
    { key = "stable_lists", default = true },
    { key = "browser", default = "library", values = { library = true, koreader = true } },
}

local function librarySettings()
    if not require("webcommon").plugin("library") then return nil end
    local ok, S = pcall(require, "librarysettings")
    return ok and S or nil
end

function Web.librarySettings()
    local S = librarySettings()
    if not S then return { installed = false } end
    local out = { installed = true }
    for __, d in ipairs(SETTINGS) do out[d.key] = S.get(d.key, d.default) end
    return out
end

--- Sets the ones given (checked); returns the settings, or nil and why.
function Web.setLibrarySettings(b)
    local S = librarySettings()
    if not S then return nil, "The Library app isn't installed" end
    for __, d in ipairs(SETTINGS) do
        local v = b[d.key]
        if v ~= nil then
            if d.values and not d.values[v] then return nil, "Not a choice for " .. d.key end
            if not d.values and type(v) ~= "boolean" then return nil, "On or off, please" end
        end
    end
    for __, d in ipairs(SETTINGS) do
        local v = b[d.key]
        if v ~= nil then
            S.set(d.key, v)
            -- Hidden files show in Folders: the Library walks them again.
            if d.key == "hidden" then
                local ok, M = pcall(require, "librarymodel")
                if ok and M.forget then pcall(M.forget) end
            end
        end
    end
    return Web.librarySettings()
end

function Web.routes(server)
    server:route("GET", "^/api/library/settings$", function(req, res) res:json(Web.librarySettings()) end)
    server:route("POST", "^/api/library/settings$", function(req, res)
        local out, why = Web.setLibrarySettings(req.json())
        if not out then return res:error(400, why) end
        res:json(out)
    end)

    server:route("GET", "^/api/library/search$", function(req, res)
        local results, why, partial = Web.search(req.query.q)
        if why then return res:error(400, why) end
        res:json({ results = results, partial = partial or nil })
    end)

    server:route("GET", "^/api/library/recent$", function(req, res)
        res:json({ files = Web.recent(tonumber(req.query.n) or 40) })
    end)

    server:route("GET", "^/api/library/usage$", function(req, res)
        res:json(Web.usage())
    end)

    -- { url, path }: starts getting it; GET with ?key= asks how it went.
    server:route("POST", "^/api/library/fetch$", function(req, res)
        local b = req.json()
        local key, why = Web.fetch(b.url, b.path)
        if not key then return res:error(400, why) end
        res:json({ key = key })
    end)

    server:route("GET", "^/api/library/fetch$", function(req, res)
        local s = fetches[req.query.key or ""]
        if not s then return res:error(404, "Not found") end
        res:json(s)
    end)

    server:route("GET", "^/api/library/collections$", function(req, res)
        local list = Web.collections()
        if not list then return res:error(404, "KOReader's collections aren't available") end
        res:json({ collections = list })
    end)

    -- { paths, name, on, create }
    server:route("POST", "^/api/library/collections$", function(req, res)
        local b = req.json()
        local why = Web.collect(b.paths, b.name, b.on ~= false, b.create == true)
        if why then return res:error(400, why) end
        res:json({ ok = true })
    end)

    server:route("GET", "^/api/library/details$", function(req, res)
        local d, why = Web.details(req.query.path)
        if not d then return res:error(404, why) end
        res:json(d)
    end)

    server:route("GET", "^/api/library/highlights$", function(req, res)
        local d, why = Web.highlights(req.query.path)
        if not d then return res:error(404, why) end
        res:json(d)
    end)
end

return Web
