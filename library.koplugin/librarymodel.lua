--[[--
The Library's books and files, from KOReader's own records:

- the books: every book file under KOReader's Home folder (one walk, kept
  while KOReader runs; ⟳ walks again);
- titles, authors, series, descriptions and covers: the Cover browser's
  cache (BookInfoManager), read in the background for books it hasn't seen;
- status and progress: each book's settings (DocSettings, through
  KOReader's BookList cache); "To read" is a book never opened;
- last read: KOReader's history (ReadHistory); collections and Favorites:
  ReadCollection; reading time, first read, days and pace: the Reading
  statistics plugin's database (read only);
- publisher, date and subjects: the EPUB's own package file, read when a
  book's page opens;
- moving, copying, renaming and deleting as KOReader's file browser does it
  (the book's settings, history and collections follow), and Delete with
  Undo: the file waits in a trash folder for a few seconds first.

The helpers at the top need no KOReader (tests/run.lua).
]]

local M = {}

-- ------------------------------------------------------------------ plain helpers

-- What counts as a book (KOReader opens more: text files, web pages and pictures show as
-- other files, and still open in it from their menu).
M.BOOK_EXT = { epub = true, kepub = true, pdf = true, mobi = true, azw = true, azw3 = true, fb2 = true, fbz = true,
    cbz = true, cbr = true, cbt = true, djvu = true, djv = true, docx = true, rtf = true, chm = true, doc = true,
    pdb = true, prc = true, xps = true, oxps = true }

function M.ext(name)
    return ((tostring(name or "")):match("%.([%w]+)$") or ""):lower()
end

--- The format as shown: "EPUB", "PDF"…
function M.format(name)
    local e = M.ext(name)
    return e ~= "" and e:upper() or nil
end

--- Authors as KOReader keeps them (one per line; some books use "A & B" or "A; B").
function M.splitAuthors(s)
    local out = {}
    if type(s) ~= "string" then return out end
    for line in (s .. "\n"):gmatch("(.-)\n") do
        for part in (line .. ";"):gmatch("(.-);") do
            local a = part:match("^%s*(.-)%s*$")
            if a ~= "" then table.insert(out, a) end
        end
    end
    return out
end

--- How an author sorts: by last name ("Wells, H. G."); "Surname, Name" stays.
function M.authorKey(name)
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name:find(",") then return name:lower() end
    local words = {}
    for w in name:gmatch("%S+") do table.insert(words, w) end
    if #words < 2 then return name:lower() end
    -- (Jr., Sr., II stay with the name before them.)
    local last = #words
    local suffix = { ["jr."] = true, ["jr"] = true, ["sr."] = true, ["ii"] = true, ["iii"] = true }
    if suffix[words[last]:lower()] and last > 2 then last = last - 1 end
    local rest = {}
    for i = 1, #words do if i ~= last then table.insert(rest, words[i]) end end
    return (words[last] .. ", " .. table.concat(rest, " ")):lower()
end

--- A title as it sorts: without "The", "A", "An" at the front.
function M.titleKey(title)
    local t = tostring(title or ""):lower():match("^%s*(.-)%s*$")
    t = t:gsub("^the%s+", ""):gsub("^an?%s+", "")
    return t
end

--- 380 kB, 1.2 MB.
function M.size(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then return bytes .. " bytes" end
    if bytes < 1024 * 1024 then return string.format("%d kB", math.floor(bytes / 1024 + 0.5)) end
    if bytes < 1024 * 1024 * 1024 then
        local mb = bytes / (1024 * 1024)
        return (mb < 10 and string.format("%.1f MB", mb) or string.format("%d MB", math.floor(mb + 0.5)))
    end
    return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
end

--- 2 h 12 min, 45 min, under a minute.
function M.duration(seconds)
    seconds = tonumber(seconds) or 0
    local m = math.floor(seconds / 60 + 0.5)
    if m < 1 then return "under a minute" end
    if m < 60 then return m .. " min" end
    local h = math.floor(m / 60)
    m = m % 60
    return m > 0 and (h .. " h " .. m .. " min") or (h .. " h")
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- A date: "Today, 7:43 PM", "Yesterday", "Oct 19", "Oct 19, 2025" (now: for tests).
function M.when(ts, now, twentyFour)
    ts = tonumber(ts)
    if not ts or ts <= 0 then return nil end
    now = now or os.time()
    local d, n = os.date("*t", ts), os.date("*t", now)
    local function clock()
        if twentyFour then return string.format("%02d:%02d", d.hour, d.min) end
        return string.format("%d:%02d %s", (d.hour + 11) % 12 + 1, d.min, d.hour < 12 and "AM" or "PM")
    end
    local dayStart = os.time{ year = n.year, month = n.month, day = n.day, hour = 0 }
    if ts >= dayStart and ts < dayStart + 86400 then return "Today, " .. clock() end
    if ts >= dayStart - 86400 and ts < dayStart then return "Yesterday, " .. clock() end
    if d.year == n.year then return MONTHS[d.month] .. " " .. d.day end
    return MONTHS[d.month] .. " " .. d.day .. ", " .. d.year
end

--- A date with its year always (first read, added): "Oct 19, 2026".
function M.date(ts)
    ts = tonumber(ts)
    if not ts or ts <= 0 then return nil end
    local d = os.date("*t", ts)
    return MONTHS[d.month] .. " " .. d.day .. ", " .. d.year
end

--- A book's metadata from its EPUB package file (the OPF's XML): publisher,
-- date (the year, or as written when not a date), subjects, identifier (an ISBN when there is one).
function M.parseOpf(xml)
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
    -- The publication date (opf:event="publication" when there are several), shown as its year.
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
    for __, s in ipairs(all("subject")) do
        if #subjects < 6 then table.insert(subjects, s.v) end
    end
    if #subjects > 0 then out.subjects = table.concat(subjects, ", ") end
    for __, id in ipairs(all("identifier")) do
        local digits = id.v:gsub("^[Uu][Rr][Nn]:[Ii][Ss][Bb][Nn]:", ""):gsub("[%s%-]", "")
        if (id.attrs:lower():find("isbn") or id.v:lower():find("isbn")) and digits:match("^%d+[%dXx]$") then
            out.isbn = digits
            break
        elseif (#digits == 13 and digits:match("^97[89]%d+$")) then
            out.isbn = digits
            break
        end
    end
    -- Calibre's series (when the cache has none).
    local series = meta:match('<meta[^>]-name="calibre:series"[^>]-content="([^"]*)"')
        or meta:match('<meta[^>]-content="([^"]*)"[^>]-name="calibre:series"')
    if series and series ~= "" then out.series = unescape(series) end
    local index = meta:match('<meta[^>]-name="calibre:series_index"[^>]-content="([^"]*)"')
        or meta:match('<meta[^>]-content="([^"]*)"[^>]-name="calibre:series_index"')
    if index then out.series_index = tonumber(index) end
    return out
end

--- Where an EPUB's package file is (from META-INF/container.xml).
function M.opfPath(container)
    if type(container) ~= "string" then return nil end
    return container:match('<rootfile[^>]-full%-path="([^"]+)"')
end

--- Names a book's file could have, from its title and author ("Title – Author.epub", "Title.epub").
function M.niceNames(name, title, authors)
    local out = {}
    if not title or title == "" then return out end
    local ext = name:match("(%.[^.]+)$") or ""
    local function clean(s) return (s:gsub("[/\\:*?\"<>|]+", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")) end
    local t = clean(title)
    local a = M.splitAuthors(authors)[1]
    local seen = { [name] = true }
    local tries = {}
    if a then table.insert(tries, t .. " – " .. clean(a) .. ext) end
    table.insert(tries, t .. ext)
    for __, n in ipairs(tries) do
        if not seen[n] and #n <= 200 then
            seen[n] = true
            table.insert(out, n)
        end
    end
    return out
end

--- A name for a file going where one of that name is: "Name (2).epub".
function M.freeName(name, exists)
    if not exists(name) then return name end
    local base, ext = name:match("^(.-)(%.[^.]*)$")
    if not base or base == "" then base, ext = name, "" end
    for i = 2, 999 do
        local n = base .. " (" .. i .. ")" .. ext
        if not exists(n) then return n end
    end
    return name
end

--- Books sorted: how = "read" (recently read), "added", "title", "author",
-- "progress", "name", "size"; get(book) gives what each needs.
function M.sortBooks(list, how, get)
    local function cmpText(a, b) return a < b end
    local keyed = {}
    for i, b in ipairs(list) do
        local k
        if how == "read" then k = -(get.lastRead(b) or 0)
        elseif how == "added" then k = -(b.added or b.mtime or 0)
        elseif how == "author" then k = M.authorKey(M.splitAuthors(get.authors(b))[1] or "~") .. "\0" .. M.titleKey(get.title(b))
        elseif how == "progress" then k = -(get.progress(b) or -1)
        elseif how == "name" then k = (b.name or ""):lower()
        elseif how == "size" then k = -(b.size or 0)
        else k = M.titleKey(get.title(b)) end
        keyed[i] = { b = b, k = k, i = i, t = M.titleKey(get.title(b)) }
    end
    table.sort(keyed, function(x, y)
        if x.k ~= y.k then
            if type(x.k) == "number" then return x.k < y.k end
            return cmpText(x.k, y.k)
        end
        if x.t ~= y.t then return x.t < y.t end
        return x.i < y.i
    end)
    local out = {}
    for i, e in ipairs(keyed) do out[i] = e.b end
    return out
end

-- ------------------------------------------------------------------ KOReader's records

local state = {
    books = nil,      -- { { path, name, dir, size, mtime, added } } every book under home
    byPath = {},
    info = {},        -- path -> the Cover browser's record (no cover), or false when it has none yet
    opf = {},         -- path -> parseOpf's
    custom = {},      -- path -> KOReader's custom metadata for it ({} when none)
    stale = {},       -- path -> the Cover browser's record from before it reads the book again
    walkedAt = 0,
    partial = false,
}
M.state = state

local function lfs() return require("libs/libkoreader-lfs") end

--- KOReader's Home folder.
function M.home()
    local home = G_reader_settings:readSetting("home_dir")
    if home and lfs().attributes(home, "mode") == "directory" then return (home:gsub("/+$", "")) end
    local ok, fmu = pcall(require, "apps/filemanager/filemanagerutil")
    local d = ok and fmu.getDefaultDir and fmu.getDefaultDir() or "/mnt/us/documents"
    return (d:gsub("/+$", ""))
end

--- A folder as shown: "Home folder", "Books/Classics" (inside the Home folder), else its path.
function M.shortPath(path)
    if not path then return "" end
    local home = M.home()
    path = path:gsub("/+$", "")
    if path == home then return "Home folder" end
    if path:sub(1, #home + 1) == home .. "/" then return path:sub(#home + 2) end
    return path
end

function M.isBook(name)
    return M.BOOK_EXT[M.ext(name)] == true
end

--- Whether KOReader's reader opens it (a book, or a text file, web page or picture).
function M.canOpen(name)
    if M.isBook(name) then return true end
    local ok, DR = pcall(require, "document/documentregistry")
    return ok and DR and DR.hasProvider and DR:hasProvider(name) and true or false
end

local LANGUAGES = { en = "English", fr = "French", de = "German", es = "Spanish", it = "Italian", pt = "Portuguese",
    nl = "Dutch", sv = "Swedish", da = "Danish", no = "Norwegian", nb = "Norwegian", fi = "Finnish", pl = "Polish",
    cs = "Czech", ru = "Russian", uk = "Ukrainian", el = "Greek", tr = "Turkish", ja = "Japanese", zh = "Chinese",
    ko = "Korean", ar = "Arabic", he = "Hebrew", hi = "Hindi", la = "Latin", ca = "Catalan", hu = "Hungarian", ro = "Romanian" }

--- A language as named ("en-GB" → "English").
function M.languageName(code)
    if type(code) ~= "string" or code == "" then return nil end
    local base = code:lower():match("^(%a%a%a?)")
    return (base and LANGUAGES[base]) or code
end

local function showHidden() return require("librarysettings").get("hidden") == true end

--- Every book under the Home folder (at most 20,000 files, in at most 4 s).
function M.books(force)
    if state.books and not force then return state.books end
    local L = lfs()
    local list, byPath = {}, {}
    local started = os.clock()
    local hidden = showHidden()
    local count = 0
    local function go(dir, depth)
        if depth > 12 or count > 20000 or os.clock() - started > 4 then state.partial = true return end
        local ok, iter, obj = pcall(L.dir, dir)
        if not ok then return end
        for name in iter, obj do
            if name ~= "." and name ~= ".." and (hidden or name:sub(1, 1) ~= ".") then
                count = count + 1
                local full = dir .. "/" .. name
                local a = L.attributes(full)
                if a and a.mode == "directory" then
                    if not name:match("%.sdr$") then go(full, depth + 1) end
                elseif a and a.mode == "file" and M.isBook(name) then
                    local b = { path = full, name = name, dir = dir, size = a.size or 0, mtime = a.modification or 0,
                        added = math.max(a.change or 0, a.modification or 0) }
                    table.insert(list, b)
                    byPath[full] = b
                end
            end
        end
    end
    state.partial = false
    go(M.home(), 0)
    state.books, state.byPath, state.walkedAt = list, byPath, os.time()
    return list
end

--- Forget the walk and what was read (after files change, or ⟳).
function M.forget(path)
    if path then
        if state.info[path] then state.stale[path] = state.info[path] end
        state.info[path] = nil
        state.opf[path] = nil
        state.custom[path] = nil
    else
        state.books = nil
        state.info = {}
        state.custom = {}
    end
end

function M.book(path)
    M.books()
    return state.byPath[path]
end

-- The Cover browser's BookInfoManager (it may be turned off: then its file is loaded from its folder).
local BIM
function M.bim()
    if BIM ~= nil then return BIM or nil end
    local ok, m = pcall(require, "bookinfomanager")
    if not ok then
        local dir = (package.path:match("([^;]*/plugins)/[^;]*") or "plugins") .. "/coverbrowser.koplugin/?.lua"
        package.path = dir .. ";" .. package.path
        ok, m = pcall(require, "bookinfomanager")
    end
    BIM = ok and type(m) == "table" and m or false
    return BIM or nil
end

--- The Cover browser's record of a book (title, authors, series, series_index,
-- language, keywords, description, pages, has_cover), or nil when it hasn't read it yet.
function M.info(path)
    local got = state.info[path]
    if got ~= nil then return got or nil end
    local bim = M.bim()
    local info
    if bim then
        -- (nil: not read yet; in_progress: being read now; _no_provider: not a book)
        local ok, i = pcall(bim.getBookInfo, bim, path, false)
        if ok and type(i) == "table" and not i._no_provider and (i.in_progress or 0) == 0 then info = i end
    end
    state.info[path] = info or false
    if info then state.stale[path] = nil end
    return info
end

-- The Cover browser's record, or what it had before it was asked to read
-- the book again (its details changed): shown meanwhile.
local function known(path) return M.info(path) or state.stale[path] end
M.known = known

local function nonEmpty(s) return type(s) == "string" and s ~= "" and s or nil end

function M.title(b)
    local i = known(b.path)
    return nonEmpty(i and i.title) or (b.name:gsub("%.[^.]+$", ""))
end

function M.authors(b)
    local i = known(b.path)
    return nonEmpty(i and i.authors)
end

function M.firstAuthor(b)
    return M.splitAuthors(M.authors(b))[1]
end

function M.series(b)
    local i = known(b.path)
    local s = nonEmpty(i and i.series)
    if s then return s, tonumber(i.series_index) end
    local o = state.opf[b.path]
    if o and o.series then return o.series, o.series_index end
end

-- KOReader's BookList cache (status and progress, as its file browser shows them).
local function booklist()
    local ok, BL = pcall(require, "ui/widget/booklist")
    return ok and BL or nil
end

-- The open book's own settings while it is open (newer than its file).
local function openReader(path)
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local r = ReaderUI and ReaderUI.instance
    if r and r.document and r.document.file == path then return r end
end

--- "new" (never opened: To read), "reading", "abandoned" (On hold) or "complete" (Finished).
function M.status(path)
    local r = openReader(path)
    if r and r.doc_settings then
        local sm = r.doc_settings:readSetting("summary")
        return (sm and sm.status) or "reading"
    end
    local BL = booklist()
    if BL then
        local ok, s = pcall(BL.getBookStatus, path)
        if ok and s then return s end
    end
    local DS = require("docsettings")
    if not DS:hasSidecarFile(path) then return "new" end
    local sm = DS:open(path):readSetting("summary")
    return (sm and sm.status) or "reading"
end

--- How far read, 0..1 (nil when never opened).
function M.progress(path)
    local r = openReader(path)
    if r and r.doc_settings then return r.doc_settings:readSetting("percent_finished") end
    local BL = booklist()
    if BL then
        local ok, i = pcall(BL.getBookInfo, path)
        if ok and i then return i.been_opened and i.percent_finished or nil end
    end
end

--- Its pages (from its settings when read, else the Cover browser's).
function M.pages(b)
    local BL = booklist()
    local i = BL and select(2, pcall(BL.getBookInfo, b.path))
    if type(i) == "table" and i.pages then return i.pages end
    local info = M.info(b.path)
    return info and tonumber(info.pages) or nil
end

M.STATUS_NAMES = { new = "To read", reading = "Reading", abandoned = "On hold", complete = "Finished" }

--- What the second line says: "42% read", "To read", "Finished", "On hold · 31%".
function M.stateText(path)
    local s = M.status(path)
    local p = M.progress(path)
    if s == "complete" then return "Finished" end
    if s == "new" then return "To read" end
    local pct = p and math.floor(p * 100 + 0.5) or 0
    if s == "abandoned" then return "On hold · " .. pct .. "%" end
    return pct .. "% read"
end

--- Status changed as KOReader's file browser does it (its buttons Reading, On hold, Finished).
function M.setStatus(path, status)
    local r = openReader(path)
    local fmu = require("apps/filemanager/filemanagerutil")
    local ds = r and r.doc_settings or require("docsettings"):open(path)
    local summary = ds:readSetting("summary") or {}
    summary.status = status
    fmu.saveSummary(ds, summary)
    local BL = booklist()
    if BL then pcall(BL.setBookInfoCacheProperty, path, "status", status) end
end

--- Back to the start, as KOReader's Reset (highlights and bookmarks kept).
function M.resetProgress(path)
    require("apps/filemanager/filemanagerutil").resetDocumentSettings(path)
end

-- ------------------------------------------------------------------ history

local function history()
    local ok, RH = pcall(require, "readhistory")
    if not ok then return nil end
    return RH
end

--- When each book was last opened: path -> time.
function M.lastReadMap()
    local RH = history()
    local out = {}
    for __, h in ipairs(RH and RH.hist or {}) do
        if h.file and not out[h.file] then out[h.file] = h.time end
    end
    return out
end

function M.lastRead(path)
    return M.lastReadMap()[path]
end

--- The books read lately, newest first (at most n).
function M.recent(n)
    local RH = history()
    local out = {}
    M.books()
    for __, h in ipairs(RH and RH.hist or {}) do
        if #out >= (n or 50) then break end
        local b = state.byPath[h.file]
        if not b and h.file and lfs().attributes(h.file, "mode") == "file" and M.isBook(h.file) then
            -- (a book outside the Home folder, opened from elsewhere)
            local a = lfs().attributes(h.file)
            b = { path = h.file, name = h.file:match("[^/]+$"), dir = h.file:match("^(.*)/"), size = a.size, mtime = a.modification,
                added = a.change }
            state.byPath[h.file] = b
        end
        if b then table.insert(out, b) end
    end
    return out
end

-- ------------------------------------------------------------------ lists

--- The books on a shelf: "all", "reading", "toread", "finished", "onhold".
function M.shelf(kind)
    local want = ({ reading = "reading", toread = "new", finished = "complete", onhold = "abandoned" })[kind]
    local out = {}
    for __, b in ipairs(M.books()) do
        if not want or M.status(b.path) == want then table.insert(out, b) end
    end
    return out
end

local getters = {
    title = M.title,
    authors = M.authors,
    progress = function(b) return M.progress(b.path) end,
}

function M.sort(list, how)
    local map = how == "read" and M.lastReadMap() or nil
    local get = setmetatable({ lastRead = function(b) return map and map[b.path] end }, { __index = getters })
    return M.sortBooks(list, how, get)
end

M.GROUPS = { { "none", "None" }, { "author", "Author" }, { "series", "Series" }, { "status", "Status" },
    { "format", "Format" }, { "language", "Language" }, { "folder", "Folder" } }

local STATUS_ORDER = { reading = 1, abandoned = 2, new = 3, complete = 4 }

--- Books in groups (their order kept inside each): { { label, key, books, kind, value } };
-- by = "author", "series", "status", "format", "language", "folder" (nil or "none": one group).
-- kind/value: what the group is (an author's or a series' own page opens from it).
function M.group(list, by)
    if not by or by == "none" then return { { label = nil, books = list } } end
    local groups, byKey = {}, {}
    local home = M.home()
    local function add(key, label, sortKey, b, kind, value)
        local g = byKey[key]
        if not g then
            g = { key = key, label = label, sortKey = sortKey, books = {}, kind = kind, value = value }
            byKey[key] = g
            table.insert(groups, g)
        end
        table.insert(g.books, b)
    end
    for __, b in ipairs(list) do
        if by == "author" then
            local a = M.firstAuthor(b)
            if a then add(M.authorKey(a), a, M.authorKey(a), b, "author", a)
            else add("~", "No author", "~", b) end
        elseif by == "series" then
            local s = M.series(b)
            if s then add("s:" .. s, s, M.titleKey(s), b, "series", s)
            else add("~", "Not in a series", "~", b) end
        elseif by == "status" then
            local s = M.status(b.path)
            add(s, M.STATUS_NAMES[s] or s, STATUS_ORDER[s] or 9, b, "status", s)
        elseif by == "format" then
            local f = M.format(b.name) or "?"
            add(f, f, f, b, "format", f)
        elseif by == "language" then
            local i = M.info(b.path)
            local l = nonEmpty(i and i.language)
            if l then add(l:lower(), l, l:lower(), b, "language", l) else add("~", "Not known", "~", b) end
        elseif by == "folder" then
            local d = b.dir or ""
            local label = M.shortPath(d)
            add(d, label, d == home and "" or label:lower(), b, "folder", d)
        end
    end
    table.sort(groups, function(x, y)
        if type(x.sortKey) ~= type(y.sortKey) then return type(x.sortKey) == "number" end
        return x.sortKey < y.sortKey
    end)
    return groups
end

--- A book's path by its title (and first author), as the reading statistics name it; nil when none matches.
function M.findTitle(title, authors)
    if type(title) ~= "string" or title == "" then return nil end
    local t = title:lower()
    local a = M.splitAuthors(authors)[1]
    a = a and a:lower()
    local best
    for __, b in ipairs(M.books()) do
        if M.title(b):lower() == t then
            local ba = M.firstAuthor(b)
            if not a or (ba and ba:lower() == a) then return b.path end
            best = best or b.path
        end
    end
    -- (from the history too: a book opened from outside the Home folder)
    for __, b in ipairs(M.recent(50)) do
        if M.title(b):lower() == t then return b.path end
    end
    return best
end

--- Every author: { { name, key, books = { b, ... } } }, by last name.
function M.authorList()
    local by, out = {}, {}
    for __, b in ipairs(M.books()) do
        for __, a in ipairs(M.splitAuthors(M.authors(b))) do
            local k = M.authorKey(a)
            if not by[k] then
                by[k] = { name = a, key = k, books = {} }
                table.insert(out, by[k])
            end
            table.insert(by[k].books, b)
        end
    end
    table.sort(out, function(x, y) return x.key < y.key end)
    return out
end

function M.byAuthor(name)
    local k = M.authorKey(name)
    for __, a in ipairs(M.authorList()) do
        if a.key == k then return a.books, a.name end
    end
    return {}, name
end

--- A series' books, in order.
function M.seriesBooks(name)
    local out = {}
    for __, b in ipairs(M.books()) do
        local s, i = M.series(b)
        if s == name then table.insert(out, { b = b, i = i or 999 }) end
    end
    table.sort(out, function(x, y)
        if x.i ~= y.i then return x.i < y.i end
        return M.titleKey(M.title(x.b)) < M.titleKey(M.title(y.b))
    end)
    local list = {}
    for i, e in ipairs(out) do list[i] = e.b end
    return list
end

-- ------------------------------------------------------------------ collections

local function rc()
    local ok, RC = pcall(require, "readcollection")
    if not ok then return nil end
    pcall(RC._read, RC)
    return RC.coll and RC or nil
end
M.rc = rc

function M.favoritesName()
    local RC = rc()
    return RC and RC.default_collection_name or "favorites"
end

--- KOReader's collections: { { name, label, files = { path, ... } } }, Favorites first.
function M.collections()
    local RC = rc()
    if not RC then return {} end
    local out = {}
    for name in pairs(RC.coll) do
        local files = {}
        local ok, list = pcall(RC.getOrderedCollection, RC, name)
        for __, item in ipairs(ok and list or {}) do table.insert(files, item.file) end
        table.insert(out, { name = name, label = name == RC.default_collection_name and "Favorites" or name, files = files })
    end
    table.sort(out, function(a, b)
        if (a.name == RC.default_collection_name) ~= (b.name == RC.default_collection_name) then return a.name == RC.default_collection_name end
        return a.label:lower() < b.label:lower()
    end)
    return out
end

function M.collectionBooks(name)
    local RC = rc()
    local out = {}
    if not (RC and RC.coll[name]) then return out end
    local ok, list = pcall(RC.getOrderedCollection, RC, name)
    M.books()
    for __, item in ipairs(ok and list or {}) do
        local b = state.byPath[item.file]
        if not b and lfs().attributes(item.file, "mode") == "file" then
            local a = lfs().attributes(item.file)
            b = { path = item.file, name = item.file:match("[^/]+$"), dir = item.file:match("^(.*)/"), size = a.size, mtime = a.modification, added = a.change }
            state.byPath[item.file] = b
        end
        if b then table.insert(out, b) end
    end
    return out
end

--- The collections a book is in (their labels).
function M.collectionsOf(path)
    local RC = rc()
    local out = {}
    if not RC then return out end
    for name, coll in pairs(RC.coll) do
        if coll[path] then table.insert(out, name == RC.default_collection_name and "Favorites" or name) end
    end
    table.sort(out, function(a, b)
        if (a == "Favorites") ~= (b == "Favorites") then return a == "Favorites" end
        return a:lower() < b:lower()
    end)
    return out
end

function M.inCollection(path, name)
    local RC = rc()
    return RC and RC.coll[name] and RC.coll[name][path] and true or false
end

function M.isFavorite(path) return M.inCollection(path, M.favoritesName()) end

--- Files into a collection (made when it isn't there), or out of it.
function M.collect(paths, name, on)
    local RC = rc()
    if not RC then return end
    if not RC.coll[name] then RC:addCollection(name) end
    for __, p in ipairs(paths) do
        if on and not RC.coll[name][p] then RC:addItem(p, name)
        elseif not on and RC.coll[name][p] then RC:removeItem(p, name, true) end
    end
    RC:write({ [name] = true })
end

function M.renameCollection(old, new)
    local RC = rc()
    if RC and RC.coll[old] and not RC.coll[new] then RC:renameCollection(old, new) end
end

function M.removeCollection(name)
    local RC = rc()
    if not (RC and RC.coll[name]) then return nil end
    local keep = { files = {} }
    for __, item in pairs(RC.coll[name]) do table.insert(keep.files, { file = item.file, order = item.order }) end
    RC:removeCollection(name)
    return keep
end

function M.restoreCollection(name, keep)
    local RC = rc()
    if not RC then return end
    RC:addCollection(name)
    table.sort(keep.files, function(a, b) return (a.order or 0) < (b.order or 0) end)
    for __, f in ipairs(keep.files) do
        if lfs().attributes(f.file, "mode") == "file" then RC:addItem(f.file, name) end
    end
    RC:write({ [name] = true })
end

-- ------------------------------------------------------------------ KOReader's folder shortcuts

--- KOReader's favorite folders (its Folder shortcuts): { { name, path } }.
function M.shortcuts()
    local out = {}
    for path, s in pairs(G_reader_settings:readSetting("folder_shortcuts") or {}) do
        if lfs().attributes(path, "mode") == "directory" then
            table.insert(out, { path = path, name = (type(s) == "table" and s.text) or path:match("[^/]+$") or path })
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

-- ------------------------------------------------------------------ a folder

--- A folder's folders and files: { dirs = { { name, path, mtime } }, books = { b }, files = { b } }.
function M.folder(dir)
    local L = lfs()
    local hidden = showHidden()
    local out = { dirs = {}, books = {}, files = {} }
    local ok, iter, obj = pcall(L.dir, dir)
    if not ok then return out end
    for name in iter, obj do
        if name ~= "." and name ~= ".." and (hidden or name:sub(1, 1) ~= ".") then
            local full = dir .. "/" .. name
            local a = L.attributes(full)
            if a and a.mode == "directory" then
                if not name:match("%.sdr$") then table.insert(out.dirs, { name = name, path = full, mtime = a.modification or 0, dir = true }) end
            elseif a and a.mode == "file" then
                local b = state.byPath[full] or { path = full, name = name, dir = dir, size = a.size or 0, mtime = a.modification or 0,
                    added = math.max(a.change or 0, a.modification or 0) }
                if M.isBook(name) then
                    state.byPath[full] = b
                    table.insert(out.books, b)
                else
                    table.insert(out.files, b)
                end
            end
        end
    end
    table.sort(out.dirs, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

--- What a folder holds, for its row: "2 folders, 13 files".
function M.folderSummary(dir)
    local L = lfs()
    local dirs, files = 0, 0
    local hidden = showHidden()
    local ok, iter, obj = pcall(L.dir, dir)
    if not ok then return "" end
    for name in iter, obj do
        if name ~= "." and name ~= ".." and (hidden or name:sub(1, 1) ~= ".") and not name:match("%.sdr$") then
            local m = L.attributes(dir .. "/" .. name, "mode")
            if m == "directory" then dirs = dirs + 1 elseif m == "file" then files = files + 1 end
        end
    end
    local parts = {}
    if dirs > 0 then table.insert(parts, dirs == 1 and "1 folder" or (dirs .. " folders")) end
    if files > 0 or dirs == 0 then table.insert(parts, files == 1 and "1 file" or (files .. " files")) end
    return table.concat(parts, ", ")
end

-- ------------------------------------------------------------------ search

--- Books (title, author, series, file name), authors, collections and other
-- files whose name matches q (lower case), from what is already known.
function M.search(q)
    q = tostring(q or ""):lower():match("^%s*(.-)%s*$")
    local res = { books = {}, authors = {}, collections = {}, files = {} }
    if #q < 2 then return res end
    local function has(s) return type(s) == "string" and s:lower():find(q, 1, true) ~= nil end
    for __, b in ipairs(M.books()) do
        if #res.books >= 60 then break end
        if has(M.title(b)) or has(M.authors(b)) or has((M.series(b))) or has(b.name) then table.insert(res.books, b) end
    end
    for __, a in ipairs(M.authorList()) do
        if #res.authors >= 20 then break end
        if has(a.name) then table.insert(res.authors, a) end
    end
    for __, c in ipairs(M.collections()) do
        if has(c.label) then table.insert(res.collections, c) end
    end
    -- Other files (not books) by name: a walk of the Home folder, as quick as the books' one.
    local L = lfs()
    local started = os.clock()
    local function go(dir, depth)
        if depth > 8 or #res.files >= 30 or os.clock() - started > 1.5 then return end
        local ok, iter, obj = pcall(L.dir, dir)
        if not ok then return end
        for name in iter, obj do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                local full = dir .. "/" .. name
                local m = L.attributes(full, "mode")
                if m == "directory" and not name:match("%.sdr$") then
                    if has(name) and #res.files < 30 then table.insert(res.files, { path = full, name = name, dir = dir, isDir = true }) end
                    go(full, depth + 1)
                elseif m == "file" and not M.isBook(name) and has(name) and #res.files < 30 then
                    local a = L.attributes(full)
                    table.insert(res.files, { path = full, name = name, dir = dir, size = a and a.size or 0, mtime = a and a.modification or 0 })
                end
            end
        end
    end
    go(M.home(), 0)
    return res
end

-- ------------------------------------------------------------------ a book's page

--- Highlights and notes in a book.
function M.annotations(path)
    local r = openReader(path)
    local anns = (r and r.annotation and r.annotation.annotations)
    if not anns then
        local DS = require("docsettings")
        if not DS:hasSidecarFile(path) then return 0, 0 end
        anns = DS:open(path):readSetting("annotations") or {}
    end
    local highlights, notes = 0, 0
    for __, a in ipairs(anns) do
        if a.text and a.text ~= "" then highlights = highlights + 1 end
        if a.note and a.note ~= "" then notes = notes + 1 end
    end
    return highlights, notes
end

--- From KOReader's reading statistics (read only): { id, seconds, read (pages),
-- first, last, days, pace (pages an hour) }, or nil.
function M.stats(path)
    local DataStorage = require("datastorage")
    local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs().attributes(db, "mode") ~= "file" then return nil end
    local r = openReader(path)
    local ds = r and r.doc_settings
    local md5 = ds and ds:readSetting("partial_md5_checksum")
    if not md5 then
        local DS = require("docsettings")
        if DS:hasSidecarFile(path) then md5 = DS:open(path):readSetting("partial_md5_checksum") end
    end
    if not md5 then
        local ok, m = pcall(require("util").partialMD5, path)
        md5 = ok and m or nil
    end
    if not md5 then return nil end
    local ok, out = pcall(function()
        local conn = require("lua-ljsqlite3/init").open(db, "ro")
        local res
        local okq, err = pcall(function()
            local id, last = conn:rowexec("SELECT id, last_open FROM book WHERE md5 = '" .. md5:gsub("[^%x]", "") .. "';")
            if not id then return end
            id = tonumber(id)
            local secs, read, first = conn:rowexec(string.format(
                "SELECT sum(duration), count(DISTINCT page), min(start_time) FROM page_stat WHERE id_book = %d;", id))
            local days = conn:rowexec(string.format([[
                SELECT count(DISTINCT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime'))
                FROM page_stat_data WHERE id_book = %d;]], id))
            res = { id = id, last = tonumber(last), seconds = tonumber(secs) or 0, read = tonumber(read) or 0,
                first = tonumber(first), days = tonumber(days) or 0 }
            if res.seconds > 300 and res.read > 0 then res.pace = math.floor(res.read / (res.seconds / 3600) + 0.5) end
        end)
        conn:close()
        if not okq then error(err) end
        return res
    end)
    return ok and out or nil
end

--- The EPUB's own metadata (publisher, published, subjects, isbn), read once.
function M.opf(path)
    if state.opf[path] then return state.opf[path] end
    local out = {}
    if M.ext(path) == "epub" then
        local ok, res = pcall(function()
            local Archiver = require("ffi/archiver")
            local arc = Archiver.Reader:new()
            if not arc:open(path) then return {} end
            -- (its entries are found only once listed)
            for __ in arc:iterate() do end
            local container = arc:extractToMemory("META-INF/container.xml")
            local opf = M.opfPath(container)
            local xml = opf and arc:extractToMemory(opf)
            arc:close()
            return M.parseOpf(xml)
        end)
        if ok and type(res) == "table" then out = res end
    end
    state.opf[path] = out
    return out
end

--- KOReader's custom metadata for a book (Book information > Set custom
-- metadata, or Find details online), or {}. fresh: read again.
function M.customProps(path, fresh)
    if state.custom[path] and not fresh then return state.custom[path] end
    local DS = require("docsettings")
    local file = DS:findCustomMetadataFile(path)
    local props = {}
    if file then
        local ok, s = pcall(DS.openSettingsFile, file)
        props = ok and s:readSetting("custom_props") or {}
    end
    state.custom[path] = props
    return props
end

--- Everything a book's page shows.
function M.details(b)
    local info = known(b.path) or {}
    local d = {
        title = M.title(b), authors = M.authors(b), format = M.format(b.name), size = b.size, name = b.name,
        dir = b.dir, added = b.added, pages = M.pages(b), language = nonEmpty(info.language),
        keywords = nonEmpty(info.keywords), status = M.status(b.path), progress = M.progress(b.path),
        collections = M.collectionsOf(b.path), favorite = M.isFavorite(b.path),
    }
    local desc = nonEmpty(info.description)
    if desc then
        desc = desc:gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("</[Pp]>", "\n\n"):gsub("<[^>]+>", "")
        desc = desc:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'")
        d.description = desc:gsub("\n%s*\n%s*\n+", "\n\n"):match("^%s*(.-)%s*$")
    end
    local o = M.opf(b.path)
    d.publisher, d.published, d.isbn = o.publisher, o.published, o.isbn
    d.subjects = o.subjects or (d.keywords and (d.keywords:gsub("%s*\n%s*", ", ")))
    d.series, d.seriesIndex = M.series(b)
    -- What was saved for it (Find details online, KOReader's Set custom metadata) comes first,
    -- also while the Cover browser hasn't read it again yet.
    local cp = M.customProps(b.path)
    d.title = nonEmpty(cp.title) or d.title
    d.authors = nonEmpty(cp.authors) or d.authors
    d.language = nonEmpty(cp.language) or d.language
    if nonEmpty(cp.series) then d.series, d.seriesIndex = cp.series, tonumber(cp.series_index) end
    if nonEmpty(cp.keywords) then d.subjects = cp.keywords:gsub("%s*\n%s*", ", ") end
    if nonEmpty(cp.description) then d.description = cp.description end
    d.publisher = nonEmpty(cp.publisher) or d.publisher
    d.published = nonEmpty(cp.published) or d.published
    d.printPages = tonumber(cp.print_pages)
    d.language = M.languageName(d.language)
    d.highlights, d.notes = M.annotations(b.path)
    d.stats = M.stats(b.path)
    d.lastRead = (d.stats and d.stats.last) or M.lastRead(b.path)
    return d
end

-- ------------------------------------------------------------------ changing files

local function fm() return package.loaded["apps/filemanager/filemanager"] and require("apps/filemanager/filemanager") end
local function ffiutil() return require("ffi/util") end

local function mv(from, to)
    local F = fm() or require("apps/filemanager/filemanager")
    return ffiutil().execute(F.mv_bin or "/bin/mv", from, to) == 0
end

local function cp(from, to)
    local F = fm() or require("apps/filemanager/filemanager")
    return ffiutil().execute(F.cp_bin or "/bin/cp", "-r", from, to) == 0
end

-- The Cover browser's record follows a file (so its cover doesn't have to be read again).
local function moveInfo(from, to, isDir)
    local bim = M.bim()
    if not bim then return end
    pcall(function()
        bim:openDbConnection()
        local util = require("util")
        local conn = bim.db_conn
        if isDir then
            local a, b = from:gsub("/+$", "") .. "/", to:gsub("/+$", "") .. "/"
            local stmt = conn:prepare("UPDATE bookinfo SET directory = ? || substr(directory, ?) WHERE substr(directory, 1, ?) = ?;")
            stmt:bind(b, #a + 1, #a, a):step()
            stmt:close()
        else
            local fd, fn = util.splitFilePathName(from)
            local td, tn = util.splitFilePathName(to)
            local stmt = conn:prepare("UPDATE OR REPLACE bookinfo SET directory = ?, filename = ? WHERE directory = ? AND filename = ?;")
            stmt:bind(td, tn, fd, fn):step()
            stmt:close()
        end
    end)
end

local function shortcutsMoved(from, to)
    local F = fm()
    local inst = F and F.instance
    if inst and inst.folder_shortcuts and inst.folder_shortcuts.updateItemsByPath then
        pcall(inst.folder_shortcuts.updateItemsByPath, inst.folder_shortcuts, from, to)
    end
end

local function resetCache(path)
    local BL = booklist()
    if BL then pcall(BL.resetBookInfoCache, path) end
end

--- Moves a file or folder into `dest` (a folder) as KOReader does it: its
-- settings, history, collections and folder shortcuts follow. Returns the new path or nil, why.
function M.moveTo(path, dest, newName)
    local L = lfs()
    local name = newName or path:match("[^/]+$")
    local to = dest .. "/" .. name
    if to == path then return path end
    if L.attributes(to, "mode") then return nil, "exists" end
    local isFile = L.attributes(path, "mode") == "file"
    -- (KOReader's collections and history read before the move: read after it, they drop the file that's gone)
    local RH, RC = history(), rc()
    if not mv(path, to) then return nil, "failed" end
    local DocSettings = require("docsettings")
    if isFile then
        DocSettings.updateLocation(path, to)
        if RH then RH:updateItem(path, to) end
        if RC then RC:updateItem(path, to) end
        resetCache(path)
    else
        if RH then RH:updateItemsByPath(path, to) end
        if RC then RC:updateItemsByPath(path, to) end
        shortcutsMoved(path, to)
    end
    moveInfo(path, to, not isFile)
    M.changed()
    return to
end

--- Renames in place (a file or folder).
function M.rename(path, name)
    local dir = path:match("^(.*)/[^/]+$") or "/"
    return M.moveTo(path, dir, name)
end

--- Copies into `dest`; a name already there gets " (2)". Its settings are copied too.
function M.copyTo(path, dest)
    local L = lfs()
    local name = M.freeName(path:match("[^/]+$"), function(n) return L.attributes(dest .. "/" .. n, "mode") ~= nil end)
    local to = dest .. "/" .. name
    local isFile = L.attributes(path, "mode") == "file"
    local okCopy
    if name == path:match("[^/]+$") then
        okCopy = cp(path, dest)
    else
        okCopy = cp(path, to)
    end
    if not okCopy then return nil, "failed" end
    if isFile then require("docsettings").updateLocation(path, to, true) end
    M.changed()
    return to
end

function M.newFolder(dir, name)
    local to = dir .. "/" .. name
    if lfs().attributes(to, "mode") then return nil, "exists" end
    local ok = lfs().mkdir(to)
    if not ok then return nil, "failed" end
    M.changed()
    return to
end

-- Where deleted files wait for Undo (on the same storage, so moving is instant).
function M.trashDir()
    return require("datastorage"):getDataDir() .. "/cache/library-trash"
end

--- Deletes at once into the trash (KOReader's history and collections follow
-- it there); returns what Undo needs, or nil, why.
function M.trash(paths)
    local L = lfs()
    local dir = M.trashDir() .. "/" .. os.time() .. "-" .. math.random(1000, 9999)
    require("util").makePath(dir)
    local moved = {}
    for i, p in ipairs(paths) do
        local slot = dir .. "/" .. i
        L.mkdir(slot)
        local to = M.moveTo(p, slot)
        if to then table.insert(moved, { from = p, to = to, dir = p:match("^(.*)/[^/]+$") }) end
    end
    if #moved == 0 then
        pcall(ffiutil().purgeDir, dir)
        return nil, "failed"
    end
    return { dir = dir, moved = moved }
end

--- Undo: everything back where it was.
function M.untrash(t)
    local back = 0
    for __, m in ipairs(t.moved) do
        local name = m.from:match("[^/]+$")
        if M.moveTo(m.to, m.dir, name) then back = back + 1 end
    end
    M.purgeTrash(t)
    return back
end

--- For good (the undo bar has gone): as KOReader's Delete, from the trash.
function M.purgeTrash(t)
    local L = lfs()
    local DocSettings = require("docsettings")
    local RH, RC = history(), rc()
    for __, m in ipairs(t.moved) do
        local mode = L.attributes(m.to, "mode")
        if mode == "file" then
            if os.remove(m.to) then
                resetCache(m.to)
                DocSettings.updateLocation(m.to)
                if RH then pcall(RH.fileDeleted, RH, m.to) end
                if RC then pcall(RC.removeItem, RC, m.to) end
            end
        elseif mode == "directory" then
            if RH then pcall(RH.folderDeleted, RH, m.to) end
            if RC then pcall(RC.removeItemsByPath, RC, m.to) end
            pcall(ffiutil().purgeDir, m.to)
        end
    end
    pcall(ffiutil().purgeDir, t.dir)
end

--- Left over from a KOReader that stopped while an Undo bar showed: gone now.
function M.emptyTrash()
    local L = lfs()
    local root = M.trashDir()
    if L.attributes(root, "mode") ~= "directory" then return end
    for name in L.dir(root) do
        if name ~= "." and name ~= ".." then
            local dir = root .. "/" .. name
            local moved = {}
            for slot in L.dir(dir) do
                if slot ~= "." and slot ~= ".." then
                    for f in L.dir(dir .. "/" .. slot) do
                        if f ~= "." and f ~= ".." and not f:match("%.sdr$") then table.insert(moved, { to = dir .. "/" .. slot .. "/" .. f }) end
                    end
                end
            end
            M.purgeTrash({ dir = dir, moved = moved })
        end
    end
end

-- After a change: the walk again next time, and KOReader's file browser shows it too.
function M.changed()
    state.books = nil
    local F = fm()
    if F and F.instance and F.instance.file_chooser then
        pcall(function() F.instance.file_chooser:refreshPath() end)
    end
end

return M
