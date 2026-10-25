--[[--
Notebooks on the device for Notes, in plain Lua (no KOReader modules) for
the tests: one file per notebook, koreader/notes/<id>.lua.

A notebook: { id, name, created, modified, paper ("plain", "narrow",
"wide", "grid", "dots"), width, height, pressure, pages = { { id, strokes = {
{t, w, p, q}... } }... } } (strokes as in notesink; a page's id stays with
it when pages move, for OneNote).
A puzzle book (made from a PDF of puzzles) also has puzzle = true, zbox =
{ x, y, w, h } (the part of the page its zoom shows), and pages marked
done = true or hide = true. A book of crosswords fetched has feed = the
source ("guardian", "usa", "universal", "wapo", "tny", "imp" for files
imported), lay = how it was laid out ("normal", "large", "+b" with clue boxes,
"+t" clue pages under the grid), and its pages pz = "quick/17616:1" (the
puzzle page each shows, notescrossword; "…:L1" laid out for landscape); a puzzle's first page also keeps secs (the
time spent on it), doneat (when it was marked done) and, imported, title.
Written as compact Lua (strokes' points as flat number lists), read back in
an empty environment.
]]

local Store = {}
Store.__index = Store

local PAPERS = { plain = true, narrow = true, wide = true, grid = true, dots = true, checklist = true, tasks = true,
    cornell = true, weekly = true, music = true, margin = true, isometric = true, hex = true, calendar = true }
Store.PAPERS = { "plain", "narrow", "wide", "grid", "dots", "checklist", "tasks", "cornell", "weekly", "music",
    "margin", "isometric", "hex", "calendar" }
Store.PAGE_TRASH_DAYS = 30   -- deleted pages are kept this long (restored from the page list)

-- A template name kept: one of the templates or one of your own.
local function validPaper(p)
    return (PAPERS[p] or (type(p) == "string" and p:match("^tpl:[^/\\]+%.png$"))) and p or nil
end
local TIPS = { fineliner = true, fountain = true, calligraphy = true, brush = true, marker = true, pencil = true,
    mechanical = true, shader = true, hl = true }
local DASHES = { dash = true, dot = true }

local function quote(s)
    return string.format("%q", tostring(s or ""))
end

local idCount = 0

--- A new page id, different from the others made here.
function Store.newPageId()
    idCount = idCount + 1
    return string.format("pg%d%d%03d", os.time(), idCount, math.random(0, 999))
end

-- A page's items (typed text, pictures, tape) as Lua source.
local function itemsSource(page, out)
    if not page.items or #page.items == 0 then return end
    table.insert(out, "items={")
    for _, it in ipairs(page.items) do
        if it.k == "text" then
            table.insert(out, string.format("{k=\"text\",x=%d,y=%d,w=%d,size=%d,%s%s%s%s%stext=%q},", it.x, it.y, it.w, it.size or 20,
                (it.align == "center" or it.align == "right") and string.format("align=%q,", it.align) or "",
                it.bold and "bold=true," or "", it.italic and "italic=true," or "", it.serif and "serif=true," or "",
                (it.link and string.format("link=%q,", it.link) or "") .. (it.rev and "rev=true," or ""), it.text or ""))
        elseif it.k == "image" then
            table.insert(out, string.format("{k=\"image\",x=%d,y=%d,w=%d,h=%d,file=%q},", it.x, it.y, it.w, it.h, it.file))
        elseif it.k == "tape" then
            table.insert(out, string.format("{k=\"tape\",x=%d,y=%d,w=%d,h=%d,open=%s},", it.x, it.y, it.w, it.h, it.open and "true" or "false"))
        end
    end
    table.insert(out, "},")
end

-- Each stroke's source, kept while the stroke is the same, so saving a big
-- notebook writes out mostly kept text. A stroke that changes is a new
-- table; one still being drawn grows (its length is checked).
local kept = setmetatable({}, { __mode = "k" })

local function strokeSource(stroke)
    local p, q = stroke.p, stroke.q
    local k = kept[stroke]
    if k and k.n == #p and k.nq == (q and #q or -1) and k.w == stroke.w and k.t == stroke.t and k.c == stroke.c
            and k.d == stroke.d and k.f == stroke.f and k.ck == stroke.ck then
        return k.src
    end
    local nums = {}
    for i, v in ipairs(p) do nums[i] = string.format("%d", v) end
    local widths = ""
    if q then
        local qs = {}
        for i, v in ipairs(q) do qs[i] = string.format("%d", v) end
        widths = ",q={" .. table.concat(qs, ",") .. "}"
    end
    local tip = (TIPS[stroke.t] and string.format("t=%q,", stroke.t) or "")
        .. (stroke.c and string.format("c=%d,", stroke.c) or "")
        .. (DASHES[stroke.d] and string.format("d=%q,", stroke.d) or "")
        .. (stroke.f and string.format("f=%d,", stroke.f) or "")
        .. (stroke.ck and "ck=true," or "")
    local src = string.format("{%sw=%d,p={%s}%s},", tip, stroke.w, table.concat(nums, ","), widths)
    kept[stroke] = { n = #p, nq = q and #q or -1, w = stroke.w, t = stroke.t, c = stroke.c, d = stroke.d, f = stroke.f,
        ck = stroke.ck, src = src }
    return src
end

-- A page's strokes as Lua source.
local function strokesSource(page, out)
    for _, stroke in ipairs(page.strokes) do
        table.insert(out, strokeSource(stroke))
    end
end

--- What a page looks like, as text (the same text for the same page): its
-- ink and the notebook's paper.
function Store.pageText(page, paper)
    local out = { paper or "", ":" }
    itemsSource(page, out)
    strokesSource(page, out)
    return table.concat(out)
end

-- A crossword's ticked clues ({ ["8A"] = true }) as "ticks=\"8A 12D\",".
local function ticksSource(ticks)
    if not ticks or not next(ticks) then return "" end
    local ids = {}
    for id in pairs(ticks) do table.insert(ids, id) end
    table.sort(ids)
    return string.format("ticks=%q,", table.concat(ids, " "))
end

--- A notebook as Lua source ("return {...}").
function Store.serialize(nb)
    local out = { "return {" }
    table.insert(out, string.format("id=%s,name=%s,created=%d,modified=%d,paper=%s,%swidth=%d,height=%d,pressure=%s,npages=%d,pages={",
        quote(nb.id), quote(nb.name), nb.created or 0, nb.modified or 0, quote(nb.paper or "plain"),
        (nb.pdf and ("pdf=" .. quote(nb.pdf) .. ",") or "") .. (nb.puzzle and "puzzle=true," or "")
            .. (nb.feed and ("feed=" .. quote(nb.feed) .. ",") or "") .. (nb.lay and ("lay=" .. quote(nb.lay) .. ",") or "")
            .. (nb.zbox and string.format("zbox={%d,%d,%d,%d},", nb.zbox[1], nb.zbox[2], nb.zbox[3], nb.zbox[4]) or ""),
        nb.width or 0, nb.height or 0, nb.pressure == false and "false" or "true", #nb.pages))
    local function pageSource(page)
        page.id = page.id or Store.newPageId()
        table.insert(out, string.format("{id=%q,%s%s%s%s", page.id, page.bg and string.format("bg=%d,", page.bg) or "",
            page.star and "star=true," or "", page.done and "done=true," or "", page.hide and "hide=true," or "")
            .. (page.pz and string.format("pz=%q,", page.pz) or "") .. (page.day and string.format("day=%d,", page.day) or "")
            .. (page.paper and string.format("paper=%q,", page.paper) or "")
            .. (page.created and string.format("created=%d,", page.created) or "")
            .. (page.secs and string.format("secs=%d,", page.secs) or "") .. (page.doneat and string.format("doneat=%d,", page.doneat) or "")
            .. (page.title and string.format("title=%q,", page.title) or "")
            .. (page.nclues and string.format("nclues=%d,", page.nclues) or "") .. (page.hints and string.format("hints=%d,", page.hints) or "")
            .. ticksSource(page.ticks))
        itemsSource(page, out)
        table.insert(out, "strokes={")
        strokesSource(page, out)
        table.insert(out, "}}")
    end
    for _, page in ipairs(nb.pages) do
        pageSource(page)
        table.insert(out, ",")
    end
    table.insert(out, "}")
    -- Pages deleted (kept a while, to restore).
    if nb.deleted and #nb.deleted > 0 then
        table.insert(out, ",deleted={")
        for _, d in ipairs(nb.deleted) do
            table.insert(out, string.format("{at=%d,index=%d,page=", d.at or 0, d.index or 1))
            pageSource(d.page)
            table.insert(out, "},")
        end
        table.insert(out, "}")
    end
    table.insert(out, "}\n")
    return table.concat(out)
end

-- "8A 12D" as { ["8A"] = true, ["12D"] = true } (nil when none).
local function ticksOf(s)
    local out
    for id in s:gmatch("%w+") do
        out = out or {}
        out[id] = true
    end
    return out
end

--- A notebook from its source, or nil and why. Checked so a damaged file
-- cannot run code or break the editor.
function Store.parse(text)
    local fn, err = (loadstring or load)(text)
    if not fn then return nil, err end
    if setfenv then setfenv(fn, {}) end
    local ok, nb = pcall(fn)
    if not ok or type(nb) ~= "table" or type(nb.pages) ~= "table" then return nil, "not a notebook" end
    if nb.paper == "lined" then nb.paper = "narrow" end   -- before the five templates
    -- One of the templates, or one of your own ("tpl:<file>.png" in notes/templates).
    nb.paper = validPaper(nb.paper) or "plain"
    nb.name = type(nb.name) == "string" and nb.name or "Notebook"
    -- A PDF beside the notebook (its pages as backgrounds): a plain file name.
    nb.pdf = type(nb.pdf) == "string" and nb.pdf:match("^nb%d+%.pdf$") or nil
    nb.puzzle = nb.pdf and nb.puzzle == true or nil
    local FEEDS = { guardian = true, usa = true, universal = true, wapo = true, tny = true, imp = true }
    nb.feed = nb.puzzle and FEEDS[nb.feed] and nb.feed or nil
    nb.lay = nb.feed and type(nb.lay) == "string" and nb.lay:match("^%a+[%+%a]*$") and nb.lay or nil
    local z = nb.zbox
    nb.zbox = nil
    if nb.puzzle and type(z) == "table" and tonumber(z[1]) and tonumber(z[2]) and (tonumber(z[3]) or 0) > 0
            and (tonumber(z[4]) or 0) > 0 then
        nb.zbox = { math.floor(z[1]), math.floor(z[2]), math.floor(z[3]), math.floor(z[4]) }
    end
    local function parsePage(page)
        local strokes = {}
        for _, s in ipairs(type(page) == "table" and type(page.strokes) == "table" and page.strokes or {}) do
            if type(s) == "table" and type(s.p) == "table" and #s.p >= 2 and #s.p % 2 == 0 then
                local q = type(s.q) == "table" and #s.q == #s.p / 2 and s.q or nil
                local grey = function(v)
                    v = tonumber(v)
                    return v and v >= 0 and v <= 255 and math.floor(v) or nil
                end
                table.insert(strokes, { t = TIPS[s.t] and s.t or nil, c = grey(s.c), d = DASHES[s.d] and s.d or nil,
                    f = grey(s.f), ck = s.ck == true or nil, w = tonumber(s.w) or 3, p = s.p, q = q })
            end
        end
        local id = type(page) == "table" and type(page.id) == "string" and page.id:match("^pg%d+$") and page.id
        if not id then
            id = Store.newPageId()
            nb.newIds = true   -- saved before they are relied on
        end
        local bg = nb.pdf and type(page) == "table" and tonumber(page.bg) or nil
        if bg and (bg < 1 or bg ~= math.floor(bg)) then bg = nil end
        local items = {}
        for _, it in ipairs(type(page) == "table" and type(page.items) == "table" and page.items or {}) do
            local ok = type(it) == "table" and tonumber(it.x) and tonumber(it.y) and tonumber(it.w)
            if ok and it.k == "text" and type(it.text) == "string" then
                table.insert(items, { k = "text", x = it.x, y = it.y, w = it.w, size = tonumber(it.size) or 20, text = it.text,
                    align = (it.align == "center" or it.align == "right") and it.align or nil,
                    bold = it.bold == true or nil, italic = it.italic == true or nil, serif = it.serif == true or nil,
                    link = type(it.link) == "string" and it.link:match("^nb%d+|[%w]*$") or nil, rev = it.rev == true or nil })
            elseif ok and it.k == "image" and tonumber(it.h) and type(it.file) == "string" and it.file:match("^img[%w]+%.%a+$") then
                table.insert(items, { k = "image", x = it.x, y = it.y, w = it.w, h = it.h, file = it.file })
            elseif ok and it.k == "tape" and tonumber(it.h) then
                table.insert(items, { k = "tape", x = it.x, y = it.y, w = it.w, h = it.h, open = it.open == true })
            end
        end
        local t = type(page) == "table" and page or {}
        return { id = id, bg = bg, star = t.star == true or nil, done = t.done == true or nil,
            hide = t.hide == true or nil, pz = type(t.pz) == "string" and t.pz:match("^%a+/%d+:%w+$") or nil,
            day = type(t.pz) == "string" and tonumber(t.day) and math.floor(t.day) or nil, items = #items > 0 and items or nil,
            paper = validPaper(t.paper), created = tonumber(t.created) and math.floor(t.created) or nil,
            secs = tonumber(t.secs) and t.secs >= 0 and math.floor(t.secs) or nil,
            doneat = t.done == true and tonumber(t.doneat) and math.floor(t.doneat) or nil,
            title = type(t.pz) == "string" and type(t.title) == "string" and t.title:sub(1, 160) or nil,
            nclues = type(t.pz) == "string" and tonumber(t.nclues) and math.floor(t.nclues) or nil,
            hints = type(t.pz) == "string" and tonumber(t.hints) and t.hints > 0 and math.floor(t.hints) or nil,
            ticks = type(t.pz) == "string" and type(t.ticks) == "string" and ticksOf(t.ticks) or nil, strokes = strokes }
    end
    local pages = {}
    for _, page in ipairs(nb.pages) do table.insert(pages, parsePage(page)) end
    -- Deleted pages, the last 30 days' (older ones go).
    local deleted = {}
    local since = os.time() - Store.PAGE_TRASH_DAYS * 86400
    for _, d in ipairs(type(nb.deleted) == "table" and nb.deleted or {}) do
        if type(d) == "table" and type(d.page) == "table" and (tonumber(d.at) or 0) >= since then
            table.insert(deleted, { at = math.floor(d.at), index = math.max(1, math.floor(tonumber(d.index) or 1)), page = parsePage(d.page) })
        end
    end
    nb.deleted = #deleted > 0 and deleted or nil
    if #pages == 0 then
        pages[1] = { id = Store.newPageId(), strokes = {} }
        nb.newIds = true
    end
    nb.pages = pages
    return nb
end

--- options: dir (folder for the files), list(dir) returning file names,
-- now() for times.
--- What the list needs of a notebook, from the start of its file only
-- (everything before its pages): { id, name, created, modified, pages } or
-- nil when the start does not say (older files: no page count).
function Store.header(text)
    local head = text:match("^return {(.-),pages={")
    if not head then return nil end
    local fn = (loadstring or load)("return {" .. head .. "}")
    if not fn then return nil end
    if setfenv then setfenv(fn, {}) end
    local ok, h = pcall(fn)
    if not ok or type(h) ~= "table" or type(h.npages) ~= "number" then return nil end
    return { name = type(h.name) == "string" and h.name or "Notebook", created = tonumber(h.created) or 0,
        modified = tonumber(h.modified) or 0, pages = h.npages, puzzle = type(h.pdf) == "string" and h.puzzle == true }
end

--- options: dir (folder for the files), list(dir) returning file names,
-- now() for times, stat(path) returning { size, modification } (to keep a
-- list of the notebooks without reading them all each time).
function Store.new(options)
    local self = setmetatable({}, Store)
    self.dir = options.dir
    self.listDir = options.list
    self.now = options.now or os.time
    self.stat = options.stat
    self.mkdir = options.mkdir
    return self
end

function Store:path(id)
    return self.dir .. "/" .. id .. ".lua"
end

function Store:read(id)
    local file = io.open(self:path(id), "rb")
    if not file then return nil, "missing" end
    local text = file:read("*a")
    file:close()
    local nb, why = Store.parse(text)
    if nb and nb.pdf then nb.pdfPath = self.dir .. "/" .. nb.pdf end
    if nb then nb.imageDir = self:imageDir() end
    return nb, why
end

-- A file copied in pieces (a PDF can be large). true or nil and why.
function Store.copyFile(from, to)
    local src, why = io.open(from, "rb")
    if not src then return nil, why end
    local dst
    dst, why = io.open(to, "wb")
    if not dst then
        src:close()
        return nil, why
    end
    while true do
        local chunk = src:read(1024 * 1024)
        if not chunk then break end
        dst:write(chunk)
    end
    src:close()
    dst:close()
    return true
end

--- A notebook made from a PDF: one page per PDF page, the PDF copied in
-- beside it. `width`, `height`: the page size in pixels; `puzzle`: a
-- puzzle book. Returns the notebook or nil and why.
function Store:createFromPDF(name, path, count, width, height, puzzle)
    local nb, why = self:create(name, width, height, "plain")
    if not nb then return nil, why end
    nb.pdf = nb.id .. ".pdf"
    nb.puzzle = puzzle or nil
    local ok
    ok, why = Store.copyFile(path, self.dir .. "/" .. nb.pdf)
    if not ok then
        self:delete(nb.id)
        return nil, why
    end
    nb.pages = {}
    for i = 1, count do table.insert(nb.pages, { id = Store.newPageId(), bg = i, strokes = {} }) end
    ok, why = self:save(nb)
    if not ok then return nil, why end
    nb.pdfPath = self.dir .. "/" .. nb.pdf
    return nb
end

--- Written to a temporary file, then moved into place, so a power cut
-- mid-save leaves the last good copy.
function Store:save(nb)
    nb.modified = self.now()
    local path = self:path(nb.id)
    local tmp = path .. ".tmp"
    local file, err = io.open(tmp, "wb")
    if not file then return false, err end
    file:write(Store.serialize(nb))
    file:close()
    os.remove(path)
    local ok, why = os.rename(tmp, path)
    return ok ~= nil, why
end

-- A new notebook id, not one already in use (here or in the trash).
function Store:newId()
    for __ = 1, 50 do
        local id = string.format("nb%d%03d", self.now(), math.random(0, 999))
        local f = io.open(self:path(id), "rb") or io.open(self.dir .. "/trash/" .. id .. ".lua", "rb")
        if not f then return id end
        f:close()
    end
    return string.format("nb%d%06d", self.now(), math.random(0, 999999))
end

function Store:create(name, width, height, paper)
    local now = self.now()
    local id = self:newId()
    local nb = { id = id, name = name, created = now, modified = now, paper = paper or "narrow",
        width = width, height = height, pages = { { id = Store.newPageId(), created = now, strokes = {} } } }
    local ok, why = self:save(nb)
    if not ok then return nil, why end
    return nb
end

-- Pictures of a notebook's pages are kept in images/ (named img<id>...).
function Store:imageDir()
    return self.dir .. "/images"
end

function Store:delete(id)
    os.remove(self.dir .. "/" .. id .. ".pdf")
    return os.remove(self:path(id)) ~= nil
end

--- A copy of a notebook under a new name (saved), or nil and why.
function Store:duplicate(id, name)
    local nb, why = self:read(id)
    if not nb then return nil, why end
    local now = self.now()
    nb.id = self:newId()
    nb.name = name
    nb.created = now
    if nb.pdf then
        local copy = nb.id .. ".pdf"
        local copied, why2 = Store.copyFile(self.dir .. "/" .. nb.pdf, self.dir .. "/" .. copy)
        if not copied then return nil, why2 end
        nb.pdf = copy
        nb.pdfPath = self.dir .. "/" .. copy
    end
    local ok, err = self:save(nb)
    if not ok then return nil, err end
    return nb
end

-- ------------------------------------------------------------------ the trash

-- Deleted notebooks wait in trash/ (their files moved there, with when and
-- from which folder in trash/trash.lua) to be restored, until deleted for
-- good or emptied after TRASH_DAYS.
Store.TRASH_DAYS = 30

function Store:trashDir()
    return self.dir .. "/trash"
end

function Store:trashIndex()
    if self.trashed then return self.trashed end
    self.trashed = {}
    local file = io.open(self:trashDir() .. "/trash.lua", "rb")
    if file then
        local fn = (loadstring or load)(file:read("*a"))
        file:close()
        if fn then
            if setfenv then setfenv(fn, {}) end
            local ok, t = pcall(fn)
            if ok and type(t) == "table" then
                for id, e in pairs(t) do
                    if type(id) == "string" and id:match("^nb%d+$") and type(e) == "table" then
                        self.trashed[id] = { at = tonumber(e.at) or 0, name = type(e.name) == "string" and e.name or "Notebook",
                            pages = tonumber(e.pages) or 0, folder = type(e.folder) == "string" and e.folder or "",
                            pdf = type(e.pdf) == "string" and e.pdf:match("^nb%d+%.pdf$") or nil }
                    end
                end
            end
        end
    end
    return self.trashed
end

function Store:saveTrash()
    local out = { "return {\n" }
    for id, e in pairs(self:trashIndex()) do
        table.insert(out, string.format("[%q]={at=%d,name=%q,pages=%d,folder=%q%s},\n", id, e.at, e.name, e.pages, e.folder,
            e.pdf and string.format(",pdf=%q", e.pdf) or ""))
    end
    table.insert(out, "}\n")
    local path = self:trashDir() .. "/trash.lua"
    local file = io.open(path .. ".tmp", "wb")
    if not file then return false end
    file:write(table.concat(out))
    file:close()
    os.remove(path)
    return os.rename(path .. ".tmp", path) ~= nil
end

--- A notebook into the trash (`folder`: the folder it was in, to go back
-- to). True when moved.
function Store:trash(id, folder)
    local dir = self:trashDir()
    if self.mkdir then self.mkdir(dir) end
    local s = self:summary(id)
    if not s then return false end
    if not os.rename(self:path(id), dir .. "/" .. id .. ".lua") then return false end
    local pdf = id .. ".pdf"
    local moved = os.rename(self.dir .. "/" .. pdf, dir .. "/" .. pdf) and pdf or nil
    self:trashIndex()[id] = { at = self.now(), name = s.name, pages = s.pages or 0, folder = folder or "", pdf = moved }
    if not self:saveTrash() then
        -- Couldn't remember it there (a full card?): put back.
        self.trashed[id] = nil
        os.rename(dir .. "/" .. id .. ".lua", self:path(id))
        if moved then os.rename(dir .. "/" .. pdf, self.dir .. "/" .. pdf) end
        return false
    end
    return true
end

--- What is in the trash, most recently deleted first: { id, name, pages, at, folder }.
function Store:trashList()
    local out = {}
    for id, e in pairs(self:trashIndex()) do
        table.insert(out, { id = id, name = e.name, pages = e.pages, at = e.at, folder = e.folder })
    end
    table.sort(out, function(a, b) return a.at > b.at end)
    return out
end

--- A notebook back from the trash: the folder it was in, or nil when it
-- couldn't be.
function Store:restore(id)
    local e = self:trashIndex()[id]
    if not e then return nil end
    local dir = self:trashDir()
    if not os.rename(dir .. "/" .. id .. ".lua", self:path(id)) then return nil end
    if e.pdf then os.rename(dir .. "/" .. e.pdf, self.dir .. "/" .. e.pdf) end
    self.trashed[id] = nil
    self:saveTrash()
    return e.folder
end

--- A notebook in the trash deleted for good.
function Store:purge(id)
    local e = self:trashIndex()[id]
    if not e then return end
    os.remove(self:trashDir() .. "/" .. id .. ".lua")
    if e.pdf then os.remove(self:trashDir() .. "/" .. e.pdf) end
    self.trashed[id] = nil
    self:saveTrash()
end

--- Notebooks in the trash longer than TRASH_DAYS deleted for good (all of
-- them with `all`).
function Store:emptyTrash(all)
    local before = self.now() - Store.TRASH_DAYS * 86400
    for id, e in pairs(self:trashIndex()) do
        if all or e.at < before then self:purge(id) end
    end
end

--- Every notebook, most recently changed first: { id, name, modified,
-- created, pages }.
-- What is known of each notebook file (index.lua): its size and time, and
-- what the list shows. Read once, written when it changes.
function Store:loadIndex()
    if self.index then return self.index end
    self.index = {}
    local file = io.open(self.dir .. "/index.lua", "rb")
    if file then
        local fn = (loadstring or load)(file:read("*a"))
        file:close()
        if fn then
            if setfenv then setfenv(fn, {}) end
            local ok, t = pcall(fn)
            if ok and type(t) == "table" then self.index = t end
        end
    end
    return self.index
end

function Store:saveIndex()
    local out = { "return {\n" }
    for id, e in pairs(self.index) do
        table.insert(out, string.format("[%q]={size=%d,time=%d,name=%q,created=%d,modified=%d,pages=%d,puzzle=%s},\n",
            id, e.size or 0, e.time or 0, e.name or "", e.created or 0, e.modified or 0, e.pages or 0, tostring(e.puzzle == true)))
    end
    table.insert(out, "}\n")
    local path = self.dir .. "/index.lua"
    local file = io.open(path .. ".tmp", "wb")
    if not file then return end
    file:write(table.concat(out))
    file:close()
    os.remove(path)
    os.rename(path .. ".tmp", path)
end

-- What the list shows of one notebook, read from its file: the start only
-- when it has the page count, else the whole notebook (older files).
function Store:summary(id)
    local file = io.open(self:path(id), "rb")
    if not file then return nil end
    local start = file:read(4096) or ""
    file:close()
    local h = Store.header(start)
    if h then return h end
    local nb = self:read(id)
    if not nb then return nil end
    return { name = nb.name, created = nb.created or 0, modified = nb.modified or 0, pages = #nb.pages, puzzle = nb.puzzle == true }
end

--- Every notebook, most recently changed first: { id, name, modified,
-- created, pages, puzzle }. Files unchanged since last time are not read
-- again (kept before puzzle was: read once more).
function Store:list()
    local out = {}
    local index = self.stat and self:loadIndex() or {}
    local seen, changed = {}, false
    for _, name in ipairs(self.listDir(self.dir)) do
        local id = name:match("^(nb%d+)%.lua$")
        if id then
            seen[id] = true
            local st = self.stat and self.stat(self:path(id))
            local e = index[id]
            if not (st and e and e.size == st.size and e.time == st.modification and e.puzzle ~= nil) then
                local s = self:summary(id)
                e = s and { size = st and st.size, time = st and st.modification, name = s.name, created = s.created,
                    modified = s.modified, pages = s.pages, puzzle = s.puzzle }
                index[id] = e
                changed = true
            end
            if e then
                table.insert(out, { id = id, name = e.name, modified = e.modified or 0, created = e.created or 0, pages = e.pages,
                    puzzle = e.puzzle or nil })
            end
        end
    end
    for id in pairs(index) do
        if not seen[id] then index[id] = nil changed = true end
    end
    if self.stat and changed then self:saveIndex() end
    table.sort(out, function(a, b) return a.modified > b.modified end)
    return out
end

--- Notebooks (from list) in an order: "modified", "name", "created", or
-- "custom" (the ids in `custom` first, in that order; any others before
-- them, newest first).
function Store.sorted(list, by, custom)
    local out = { (table.unpack or unpack)(list) }
    if by == "name" then
        table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    elseif by == "created" then
        table.sort(out, function(a, b) return a.created > b.created end)
    elseif by == "custom" then
        local rank = {}
        for i, id in ipairs(custom or {}) do rank[id] = i end
        table.sort(out, function(a, b)
            local ra, rb = rank[a.id], rank[b.id]
            if ra and rb then return ra < rb end
            if ra or rb then return rb ~= nil end
            return a.created > b.created
        end)
    end
    return out
end

return Store
