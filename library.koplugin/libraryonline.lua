--[[--
Find details online: a book looked up in Open Library first, and in Google
Books when Open Library has nothing (both free, no account). By its ISBN when
the book has one, else by title and author, or by what was typed (Search
again). The lookups run in a child process, so the screen keeps answering;
what was found is shown beside what the book has, and only what is ticked is
saved, on Save.

Saved as KOReader's own custom metadata and cover for the book, as Book
information > Set custom metadata does it, so KOReader, the Cover browser and
the Library all show it: title, authors, series, language, subjects (KOReader's
keywords) and description are KOReader's own; published, publisher and print
length are kept beside them in the same file for the Library. Undo puts the
files back as they were.

(Goodreads closed its API in 2020, and calibre's Amazon, Barnes & Noble and
Kobo sources read web pages, which break: these two are the ones with real APIs.)

The helpers at the top need no KOReader (tests/run.lua).
]]

local O = {}

local okG, gettext = pcall(require, "gettext")
local _ = okG and gettext or function(s) return s end
local function T(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)] or "") end))
end

O.AGENT = "KOReader-Library/1.0 (Kindle; KOReader plugin)"
O.OL = "https://openlibrary.org"
O.GOOGLE = "https://www.googleapis.com/books/v1/volumes"
local OL_FIELDS = "key,title,subtitle,author_name,first_publish_year,publisher,subject,number_of_pages_median,cover_i,isbn,"
    .. "editions,editions.key,editions.title,editions.publisher,editions.publish_date,editions.number_of_pages,"
    .. "editions.isbn,editions.cover_i,editions.language"

-- ------------------------------------------------------------------ plain helpers

local function nonEmpty(s) return type(s) == "string" and s:match("%S") and s or nil end
local function trim(s) return (s:gsub("%s+", " "):match("^%s*(.-)%s*$")) end

function O.escape(s)
    return (tostring(s):gsub("[^%w%-%._~ ]", function(c) return string.format("%%%02X", c:byte()) end):gsub(" ", "+"))
end

--- An ISBN-10 or ISBN-13 as digits (X kept), or nil.
function O.isbn(s)
    if type(s) ~= "string" then return nil end
    local d = s:gsub("^%s*[Uu][Rr][Nn]:[Ii][Ss][Bb][Nn]:", ""):gsub("^%s*[Ii][Ss][Bb][Nn][%-%s:]*", ""):gsub("[%s%-]", ""):upper()
    if d:match("^%d%d%d%d%d%d%d%d%d[%dX]$") or d:match("^97[89]%d%d%d%d%d%d%d%d%d%d$") then return d end
end

--- The words to look a book up by: its ISBN, else its title (without a
-- subtitle or what's in brackets) and first author.
function O.queryOf(d)
    local isbn = O.isbn(d.isbn)
    if isbn then return { isbn = isbn } end
    local title = nonEmpty(d.title) and d.title:gsub("%b()", ""):gsub("%b[]", "") or ""
    title = trim(title:gsub("%s*[:;]%s.*$", ""))
    local author = nonEmpty(d.authors) and trim((d.authors:match("^[^\n;]+"))) or nil
    return { title = title, author = author }
end

--- What was typed (Search again): an ISBN, or words.
function O.queryFromText(text)
    local isbn = O.isbn(text)
    if isbn then return { isbn = isbn } end
    return { text = trim(text or "") }
end

--- A query as words for the text box.
function O.queryText(q)
    if q.isbn then return q.isbn end
    if q.text then return q.text end
    return trim((q.title or "") .. " " .. (q.author or ""))
end

--- Open Library's and Google Books' addresses for a query.
function O.urls(q, lang)
    local ol, google
    if q.isbn then
        ol = "q=isbn:" .. q.isbn
        google = "q=isbn:" .. q.isbn
    elseif q.text then
        ol = "q=" .. O.escape(q.text)
        google = "q=" .. O.escape(q.text)
    else
        ol = "title=" .. O.escape(q.title or "") .. (q.author and ("&author=" .. O.escape(q.author)) or "")
        google = "q=intitle:" .. O.escape(q.title or "") .. (q.author and ("+inauthor:" .. O.escape(q.author)) or "")
    end
    return {
        ol = O.OL .. "/search.json?" .. ol .. "&limit=6&lang=" .. (lang or "en") .. "&fields=" .. OL_FIELDS,
        google = O.GOOGLE .. "?" .. google .. "&maxResults=6&printType=books",
    }
end

--- Text from HTML (Google's descriptions) or Open Library's Markdown-ish text.
function O.plainText(s)
    if not nonEmpty(s) then return nil end
    s = s:gsub("\r\n", "\n")
    -- (Open Library: "----------" and what follows is a list of other editions; links as [text](address))
    s = s:gsub("\n%s*%-%-%-%-.*$", "")
    s = s:gsub("%[([^%]]+)%]%([^)]*%)", "%1")
    s = s:gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("</[Pp]>", "\n\n"):gsub("<[^>]+>", "")
    s = s:gsub("&nbsp;", " "):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
    s = s:gsub("[ \t]+", " "):gsub(" *\n *", "\n"):gsub("\n\n\n+", "\n\n")
    return nonEmpty(s:match("^%s*(.-)%s*$"))
end

--- A series and number from "Name, #2", "Name #2", "Name, Book 2" or "Name Book 2".
function O.seriesOf(s)
    if not nonEmpty(s) then return nil end
    s = trim(s)
    local name, n = s:match("^(.-),?%s*#%s*(%d+%.?%d*)$")
    if not name then name, n = s:match("^(.-),?%s+[Bb]ook%s+(%d+)$") end
    if name and name:match("%S") then return trim(name), tonumber(n) end
end

--- A title without a series in brackets ("Kidnapped (David Balfour, #1)"),
-- and the series and number from there or from the subtitle.
function O.splitTitle(title, subtitle)
    title = trim(title or "")
    local base, inner = title:match("^(.-)%s*(%b())%s*$")
    if base and base ~= "" then
        local s, n = O.seriesOf(inner:sub(2, -2))
        if s then return base, s, n end
    end
    local s, n = O.seriesOf(subtitle)
    if s then return title, s, n end
    return title
end

-- (Open Library's three-letter languages, for the common ones)
local LANG3 = { eng = "en", fre = "fr", fra = "fr", ger = "de", deu = "de", spa = "es", ita = "it", por = "pt", dut = "nl",
    nld = "nl", swe = "sv", dan = "da", nor = "no", fin = "fi", pol = "pl", cze = "cs", ces = "cs", rus = "ru", ukr = "uk",
    jpn = "ja", chi = "zh", zho = "zh", kor = "ko", lat = "la", gre = "el", ell = "el", hun = "hu", tur = "tr", ara = "ar",
    heb = "he", cat = "ca", rum = "ro", ron = "ro" }

-- Subjects that say nothing about the book (Open Library's own tags).
local NOISE = { ["accessible book"] = true, ["protected daisy"] = true, ["in library"] = true, ["large type books"] = true,
    ["lending library"] = true, ["open library staff picks"] = true, ["fiction"] = false }

local function subjectsOf(list, max)
    local out, seen = {}, {}
    for __, s in ipairs(type(list) == "table" and list or {}) do
        if type(s) == "string" then
            for part in s:gmatch("[^/]+") do
                part = trim(part)
                local k = part:lower()
                if part ~= "" and not NOISE[k] and not seen[k] and not part:find("[:=]") and #part <= 40 then
                    seen[k] = true
                    table.insert(out, part)
                end
            end
        end
        if #out >= (max or 5) then break end
    end
    return #out > 0 and table.concat(out, ", ", 1, math.min(#out, max or 5)) or nil
end

local function first(list) return type(list) == "table" and nonEmpty(list[1]) or nil end

local function isbnOf(list)
    local ten
    for __, v in ipairs(type(list) == "table" and list or {}) do
        local i = O.isbn(tostring(v))
        if i and #i == 13 then return i end
        ten = ten or i
    end
    return ten
end

local function yearOf(s)
    s = tostring(s or "")
    return s:match("(%d%d%d%d)")
end

--- Open Library's search answer as matches.
function O.olMatches(t, how)
    local out = {}
    local docs = type(t) == "table" and type(t.docs) == "table" and t.docs or {}
    for __, w in ipairs(docs) do
        if nonEmpty(w.title) then
            local eds = type(w.editions) == "table" and type(w.editions.docs) == "table" and w.editions.docs or {}
            local ed = type(eds[1]) == "table" and eds[1] or {}
            local title, series, index = O.splitTitle(w.title, w.subtitle)
            local m = { source = "Open Library", how = how, key = nonEmpty(w.key), title = title, series = series, seriesIndex = index }
            if type(w.author_name) == "table" and #w.author_name > 0 then
                m.authors = table.concat(w.author_name, "\n", 1, math.min(3, #w.author_name))
            end
            m.published = w.first_publish_year and tostring(w.first_publish_year) or yearOf(first(ed.publish_date))
            m.publisher = first(ed.publisher) or first(w.publisher)
            m.pages = tonumber(ed.number_of_pages) or tonumber(w.number_of_pages_median)
            m.subjects = subjectsOf(w.subject)
            local langs = type(ed.language) == "table" and ed.language or {}
            if #langs == 1 then m.language = LANG3[langs[1]] end
            m.isbn = isbnOf(ed.isbn) or isbnOf(w.isbn)
            local cover = tonumber(ed.cover_i) or tonumber(w.cover_i)
            if cover and cover > 0 then m.cover = "https://covers.openlibrary.org/b/id/" .. math.floor(cover) .. "-L.jpg?default=false" end
            table.insert(out, m)
        end
    end
    return out
end

--- Google Books' answer as matches.
function O.googleMatches(t, how)
    local out = {}
    for __, item in ipairs(type(t) == "table" and type(t.items) == "table" and t.items or {}) do
        local v = type(item) == "table" and type(item.volumeInfo) == "table" and item.volumeInfo or {}
        if nonEmpty(v.title) then
            local title, series, index = O.splitTitle(v.title, v.subtitle)
            local m = { source = "Google Books", how = how, title = title, series = series, seriesIndex = index, complete = true }
            if type(v.authors) == "table" and #v.authors > 0 then m.authors = table.concat(v.authors, "\n", 1, math.min(3, #v.authors)) end
            m.published = yearOf(v.publishedDate)
            m.publisher = nonEmpty(v.publisher) and trim(v.publisher:gsub('^"(.*)"$', "%1")) or nil
            m.pages = tonumber(v.pageCount) and tonumber(v.pageCount) > 0 and tonumber(v.pageCount) or nil
            m.subjects = subjectsOf(v.categories)
            m.description = O.plainText(v.description)
            m.language = nonEmpty(v.language) and v.language:lower():match("^(%a%a)") or nil
            local ids = {}
            for __, id in ipairs(type(v.industryIdentifiers) == "table" and v.industryIdentifiers or {}) do
                if type(id) == "table" and nonEmpty(id.identifier) then table.insert(ids, id.identifier) end
            end
            m.isbn = isbnOf(ids)
            local img = type(v.imageLinks) == "table" and (nonEmpty(v.imageLinks.thumbnail) or nonEmpty(v.imageLinks.smallThumbnail))
            if img then m.cover = img:gsub("^http:", "https:"):gsub("&edge=curl", "") end
            table.insert(out, m)
        end
    end
    return out
end

local function norm(s)
    return (tostring(s or ""):lower():gsub("^the%s+", ""):gsub("^an?%s+", ""):gsub("[%p%s]+", ""))
end
O.norm = norm

--- Matches with the one whose title is the book's first (the order kept otherwise).
function O.rank(matches, title)
    local want = norm(title)
    if want == "" then return matches end
    local exact, rest = {}, {}
    for __, m in ipairs(matches) do table.insert(norm(m.title) == want and exact or rest, m) end
    for __, m in ipairs(rest) do table.insert(exact, m) end
    return exact
end

-- What can be saved, in the order shown.
O.FIELDS = {
    { key = "title", name = _("Title"), onlyIfDifferent = true },
    { key = "authors", name = _("Authors"), onlyIfDifferent = true },
    { key = "series", name = _("Series") },
    { key = "published", name = _("Published") },
    { key = "publisher", name = _("Publisher") },
    { key = "pages", name = _("Print length") },
    { key = "subjects", name = _("Subjects") },
    { key = "language", name = _("Language") },
    { key = "description", name = _("Description"), long = true },
}

local function shown(key, x, languageName)
    if key == "series" then
        if not nonEmpty(x.series) then return nil end
        local n = tonumber(x.seriesIndex)
        if n then return x.series .. " · " .. T(_("Book %1"), n == math.floor(n) and math.floor(n) or n) end
        return x.series
    elseif key == "pages" then
        return tonumber(x.pages) and T(_("%1 pages"), math.floor(tonumber(x.pages))) or nil
    elseif key == "authors" then
        return nonEmpty(x.authors) and (x.authors:gsub("%s*\n%s*", ", ")) or nil
    elseif key == "language" then
        return nonEmpty(x.language) and (languageName and languageName(x.language) or x.language) or nil
    end
    local v = x[key]
    if type(v) == "number" then v = tostring(v) end
    return nonEmpty(v)
end

--- What was found beside what the book has: rows { key, name, found, now
-- (nil: the book has none), tick (ticked where the book has nothing), long },
-- and the names of what is the same in both.
-- d: the book's details (its printPages as `pages` here), f: a match.
function O.compare(d, f, languageName)
    local rows, same = {}, {}
    for __, fd in ipairs(O.FIELDS) do
        local found = shown(fd.key, f, languageName)
        if found then
            local now = shown(fd.key, d, languageName)
            if now and norm(now) == norm(found) then
                table.insert(same, fd.name:lower())
            elseif not (fd.onlyIfDifferent and not now) then
                table.insert(rows, { key = fd.key, name = fd.name, found = found, now = now, tick = now == nil, long = fd.long })
            end
        end
    end
    return rows, same
end

--- What a book's custom metadata gets for the ticked keys (KOReader's own
-- names; published, publisher and print_pages are the Library's).
function O.props(f, ticked)
    local p = {}
    for key, on in pairs(ticked) do
        if on then
            if key == "series" then
                p.series = f.series
                p.series_index = tonumber(f.seriesIndex)
            elseif key == "subjects" then
                p.keywords = f.subjects and (f.subjects:gsub("%s*,%s*", "\n")) or nil
            elseif key == "pages" then
                p.print_pages = tonumber(f.pages)
            else
                p[key] = f[key]
            end
        end
    end
    return p
end

-- ------------------------------------------------------------------ the network (in the child process)

--- GET a URL (redirects followed): the body, or nil and the answer's code.
function O.get(url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    for __ = 1, 4 do
        local sink = {}
        socketutil:set_timeout(10, 30)
        local code, headers, status = socket.skip(1, http.request{
            url = url, method = "GET", sink = ltn12.sink.table(sink), redirect = false,
            headers = { ["User-Agent"] = O.AGENT },
        })
        socketutil:reset_timeout()
        local loc = type(headers) == "table" and (headers.location or headers.Location)
        if (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) and loc then
            if loc:sub(1, 1) == "/" then loc = url:match("^(https?://[^/]+)") .. loc end
            url = loc
        elseif code == 200 then
            return table.concat(sink)
        else
            return nil, code or status
        end
    end
    return nil, "too many redirects"
end

function O.json(url)
    local body, err = O.get(url)
    if not body then return nil, err end
    local ok, t = pcall(require("json").decode, body)
    if not ok or type(t) ~= "table" then return nil, "bad answer" end
    return t
end

--- The rest of a match: Open Library's description (from the work) and the cover, saved in `dir`.
function O.complete(m, dir)
    if m.source == "Open Library" and m.key and not m.description then
        local w = O.json(O.OL .. m.key .. ".json")
        if type(w) == "table" then
            local desc = w.description
            if type(desc) == "table" then desc = desc.value end
            m.description = O.plainText(desc)
            if not m.subjects then m.subjects = subjectsOf(w.subjects) end
        end
    end
    if m.cover and dir and not m.coverFile then
        local body = O.get(m.cover)
        -- (a placeholder picture is a few hundred bytes)
        if body and #body > 1000 then
            local ext = body:sub(1, 4) == "\137PNG" and "png" or "jpg"
            local file = string.format("%s/found-%d-%d.%s", dir, os.time(), math.random(1, 999999), ext)
            local fh = io.open(file, "wb")
            if fh then
                fh:write(body)
                fh:close()
                m.coverFile = file
            end
        end
    end
    m.complete = true
    return m
end

--- A lookup: { matches, offline = true when neither answered }. The first match in full.
function O.find(q, title, lang, dir)
    local urls = O.urls(q, lang)
    local how = q.isbn and "isbn" or (q.text and "text" or "title")
    local matches, failed = {}, 0
    local t = O.json(urls.ol)
    if t then matches = O.olMatches(t, how) else failed = failed + 1 end
    if #matches == 0 then
        local g = O.json(urls.google)
        if g then matches = O.googleMatches(g, how) else failed = failed + 1 end
    end
    if #matches == 0 then return { matches = {}, offline = failed == 2 } end
    matches = O.rank(matches, title)
    O.complete(matches[1], dir)
    return { matches = matches }
end

-- ------------------------------------------------------------------ on the Kindle

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(path, s)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

--- Where found covers wait until Save (emptied when done).
function O.dir()
    local d = require("datastorage"):getDataDir() .. "/cache/library-found"
    require("util").makePath(d)
    return d
end

function O.cleanup()
    local lfs = require("libs/libkoreader-lfs")
    local d = require("datastorage"):getDataDir() .. "/cache/library-found"
    local ok, iter, obj = pcall(lfs.dir, d)
    if not ok then return end
    for f in iter, obj do
        if f:match("^found%-") then os.remove(d .. "/" .. f) end
    end
end

--- fn() in a child process; done(result) here, or done(nil, why). Returns
-- { cancel = fn } (then done isn't called).
function O.run(fn, done, seconds)
    local UIManager = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    local pid, fd = ffiutil.runInSubProcess(function(__, write_fd)
        local ok, res = pcall(fn)
        ffiutil.writeToFD(write_fd, require("dump")({ ok = ok, res = res }), true)
    end, true)
    if not pid then
        done(nil, tostring(fd))
        return { cancel = function() end }
    end
    local handle = {}
    local deadline = os.time() + (seconds or 60)
    local function reap()
        if not ffiutil.isSubProcessDone(pid) then return UIManager:scheduleIn(1, reap) end
        if handle.cancelled then pcall(ffiutil.readAllFromFD, fd) end
    end
    local function check()
        if handle.cancelled then return end
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(0.3, check) end
            handle.cancelled = true
            ffiutil.terminateSubProcess(pid)
            reap()
            return done(nil, "timeout")
        end
        local raw = (size and size > 0) and ffiutil.readAllFromFD(fd) or ""
        if not exited then reap() end
        local load = raw ~= "" and loadstring("return " .. raw)
        local okf, out = pcall(load or error)
        if not (okf and type(out) == "table") then return done(nil, "no answer") end
        if not out.ok then return done(nil, tostring(out.res)) end
        done(out.res)
    end
    UIManager:scheduleIn(0.3, check)
    function handle.cancel()
        if handle.cancelled then return end
        handle.cancelled = true
        ffiutil.terminateSubProcess(pid)
        reap()
    end
    return handle
end

-- KOReader's props of a book that has no custom metadata yet (kept in the
-- file as KOReader keeps them, for its Reset in Book information).
local function originalProps(path)
    local M = require("librarymodel")
    local i = M.known(path)
    local p = {}
    if i then
        for __, k in ipairs({ "title", "authors", "series", "series_index", "language", "keywords", "description", "pages" }) do
            if i[k] ~= nil and i[k] ~= "" then p[k] = i[k] end
        end
    end
    if next(p) == nil then
        local DS = require("docsettings")
        if DS:hasSidecarFile(path) then p = DS:open(path):readSetting("doc_props") or {} end
    end
    p.display_title = nil
    return p
end

--- KOReader, the Cover browser, an open book and the Library told about a
-- book's new details. original: the book's own props (shown with what is
-- saved over them while the Cover browser reads it again).
function O.changed(path, original)
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    local M = require("librarymodel")
    local bim = M.bim()
    if bim then
        -- (a reading of it still running would write the details from before; the
        -- Library's covers start again for what it stopped, as after its own extractInBackground)
        pcall(bim.terminateBackgroundJobs, bim)
        pcall(bim.deleteBookInfo, bim, path)
    end
    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", path))
    UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local r = ReaderUI and ReaderUI.instance
    if r and r.document and r.document.file == path then
        if r.doc_settings then
            r.doc_settings:getCustomMetadataFile(true)
            r.doc_settings:getCustomCoverFile(true)
        end
        if r.doc_props then
            local cp = M.customProps(path, true)
            for __, k in ipairs({ "title", "authors", "series", "series_index", "language", "keywords", "description" }) do
                if cp[k] ~= nil then r.doc_props[k] = cp[k] end
            end
            if cp.title then r.doc_props.display_title = cp.title end
        end
    end
    M.forget(path)
    if original then
        local ok, BI = pcall(require, "apps/filemanager/filemanagerbookinfo")
        if ok and BI.extendProps then M.state.stale[path] = BI.extendProps(original, path) end
    end
    require("librarycovers").forget(path)
end

--- Saves the ticked details (and the cover, a file) as the book's custom
-- metadata and cover. Returns what Undo needs.
function O.save(path, f, ticked, coverFile)
    local DS = require("docsettings")
    local snap = { path = path }
    local props = O.props(f, ticked)
    if next(props) ~= nil then
        local file = DS:findCustomMetadataFile(path)
        snap.metaFile, snap.meta = file, file and readFile(file)
        local cds = DS.openSettingsFile(file)
        if not file then cds:saveSetting("doc_props", originalProps(path)) end
        snap.original = cds:readSetting("doc_props")
        local cp = cds:readSetting("custom_props", {})
        for k, v in pairs(props) do cp[k] = v end
        cds:flushCustomMetadata(path)
        snap.newMeta = DS:findCustomMetadataFile(path)
    end
    if coverFile then
        local old = DS:findCustomCoverFile(path)
        if old then
            snap.coverFile, snap.cover = old, readFile(old)
            os.remove(old)
        end
        DS:flushCustomCover(path, coverFile)
        snap.newCover = DS:findCustomCoverFile(path)
    end
    O.changed(path, snap.original)
    return snap
end

--- Undo: the book's custom metadata and cover as they were.
function O.restore(snap)
    local DS = require("docsettings")
    local dir
    if snap.newMeta then
        os.remove(snap.newMeta)
        dir = snap.newMeta:match("^(.*)/")
    end
    if snap.metaFile and snap.meta then writeFile(snap.metaFile, snap.meta) end
    if snap.newCover then
        os.remove(snap.newCover)
        dir = dir or snap.newCover:match("^(.*)/")
    end
    if snap.coverFile and snap.cover then writeFile(snap.coverFile, snap.cover) end
    -- (a sidecar folder made only for these goes too; one with anything else in it stays)
    if dir then pcall(DS.removeSidecarDir, dir) end
    O.changed(snap.path, snap.original)
end

O.T = T
return O
