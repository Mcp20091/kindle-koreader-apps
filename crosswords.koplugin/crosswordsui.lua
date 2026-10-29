--[[--
Get a crossword: today's (or an older, or a random) crossword from the
Guardian, USA Today, Universal, the Washington Post (Sundays) or the New
Yorker into that source's puzzle book ("Guardian crosswords", "USA Today
crosswords"…), with its answers on a hidden page after it (notescrossword
lays it out).

+ New notebook > Get a crossword…, or ⋯ > Get a crossword… in one of those
books: pick the source (and for the Guardian Quick, Cryptic, Quiptic or
Prize), then the day; Newer and Older go back through the years, Random
picks one not in the book yet, Get the last 7 days the ones missing. Get new
ones automatically picks sources whose newest puzzles are added when Notes
opens with Wi-Fi on (and Guardian Prize answers once out). In a book, the
lasso's Answer shows a clue's answer and Check (or ⋯ > Check my answers)
has the AI read the letters written in the grid and dots the wrong ones;
the puzzle list removes a puzzle and shows the stats; turning the Kindle
shows the pages laid out for landscape. Today's crossword (a gesture, or
ui.notes:todaysCrossword()) opens the newest from the source set in
Crossword settings (or the one last used). .puz and .ipuz files go into an
"Imported crosswords" book. The puzzles fetched are kept in
koreader/notes/crosswords/ (a book's PDF is made again from them when one is
added). For your own use.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Crossword = require("notescrossword")
local Settings = require("notessettings")
local Store = require("notesstore")

local Screen = Device.screen

-- The apps' pop-ups (the launcher's, when it has them; else KOReader's).
local function popup(kind)
    local P = require("pluginshare").popup
    local ok, fn = pcall(function() return P and P[kind] end)
    return ok and fn or nil
end

-- A message to read, with OK.
local function message(text, title)
    local show = popup("message")
    if show then return show{ title = title, text = text } end
    UIManager:show(InfoMessage:new{ text = title and (title .. "\n\n" .. text) or text })
end

local NAMES = { quick = _("Quick"), cryptic = _("Cryptic"), quiptic = _("Quiptic"), prize = _("Prize") }
-- Each source's book in Crosswords/<this> (imported crosswords in Crosswords itself).
local FOLDERS = { guardian = _("Guardian"), usa = _("USA Today"), universal = _("Universal"), wapo = _("Washington Post"),
    tny = _("New Yorker") }
-- Today's crossword's sources ("last": the one last opened in Get a crossword).
local TODAY_KEYS = { "last", "guardian/quick", "guardian/cryptic", "guardian/quiptic", "guardian/prize", "usa", "universal", "wapo", "tny" }
local TODAY_NAMES = { last = _("The one I last opened in Get a crossword"), ["guardian/quick"] = _("Guardian Quick"),
    ["guardian/cryptic"] = _("Guardian Cryptic"), ["guardian/quiptic"] = _("Guardian Quiptic"), ["guardian/prize"] = _("Guardian Prize"),
    usa = _("USA Today"), universal = _("Universal"), wapo = _("Washington Post (Sundays)"), tny = _("New Yorker (weekdays)") }
local FINISHED = { keep = _("Keep"), hide = _("Hide after 7 days"), remove = _("Remove after 30 days") }
local LIST_FOR = 600   -- seconds a series' list is kept before it is fetched again

local function get(url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request({ url = url, method = "GET", sink = ltn12.sink.table(sink),
        headers = { ["User-Agent"] = "Mozilla/5.0 (KOReader; Notes)" } }))
    socketutil:reset_timeout()
    if code ~= 200 then logger.warn("Notes crossword:", url, code) end
    return code, table.concat(sink)
end

-- `job` run in a child process, so KOReader goes on while it waits on the
-- network (poor Wi-Fi, a name lookup that never answers): it fetches and
-- keeps puzzle files and saves nothing else. Its result (a table of plain
-- values) goes to done(result), or done(nil, why) when it failed or took
-- longer than `limit` seconds (90).
local function inBackground(job, done, limit)
    local ffiutil = require("ffi/util")
    local json = require("json")
    local pid, fd = ffiutil.runInSubProcess(function(__, write_fd)
        local ok, result = pcall(job)
        local okj, out = pcall(json.encode, ok and { ok = result } or { err = tostring(result) })
        ffiutil.writeToFD(write_fd, okj and out or '{"err":"failed"}', true)
    end, true)
    if not pid then return done(nil, tostring(fd)) end
    local deadline = os.time() + (limit or 90)
    local function reap()
        if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end
    end
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(0.2, check) end
            logger.warn("Notes crossword: stopped a download that took too long")
            ffiutil.terminateSubProcess(pid)
            reap()
            return done(nil, "timeout")
        end
        local out = (size and size > 0) and ffiutil.readAllFromFD(fd) or ""
        if not exited then reap() end
        local ok, r = pcall(json.decode, out)
        if ok and type(r) == "table" and type(r.ok) == "table" then return done(r.ok) end
        done(nil, ok and type(r) == "table" and r.err or "failed")
    end
    UIManager:scheduleIn(0.2, check)
end

-- A message while the network is used (the screen drawn before it starts).
local function busy(text)
    local msg = require("notesko").wait(text)
    UIManager:forceRePaint()
    return msg
end

local function withCommas(n)
    local s = tostring(n)
    while true do
        local k
        s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
        if k == 0 then return s end
    end
end

local function today()
    local t = os.date("*t")
    return Crossword.daysFrom(t.year, t.month, t.day)
end

-- The source of a puzzle's key: "quick/17616" is the Guardian's.
local function sourceOf(key)
    local first = key:match("^(%a+)/")
    return NAMES[first] and "guardian" or first
end

-- The file a fetched puzzle is kept in.
local function fileOf(dir, key)
    return dir .. "/" .. key:gsub("/", "-") .. (sourceOf(key) == "guardian" and ".json" or ".dat")
end

-- A day back from a key's number (20261021; an imported one's starts with
-- the day it was imported).
local function dayOfKey(key)
    local y, m, d = key:match("/(%d%d%d%d)(%d%d)(%d%d)$")
    if not y then y, m, d = key:match("^imp/(%d%d%d%d)(%d%d)(%d%d)") end
    return y and Crossword.daysFrom(tonumber(y), tonumber(m), tonumber(d))
end

-- How the books' puzzles are laid out (Crossword settings > Clue size,
-- Clue boxes).
local function layoutOpts()
    return { large = Settings.get("crossword_clues") == "large", boxes = Settings.get("crossword_boxes") ~= false }
end
-- How a book was laid out ("+t": clue pages under the same grid).
local function layName()
    local o = layoutOpts()
    return (o.large and "large" or "normal") .. (o.boxes and "+b" or "") .. "+t"
end

return function(Notes)

-- The AI hint and the check in AI settings > Advanced (their wording can be
-- changed there; the intro and the reply's format stay as they are).
if Notes.addAiFeature then
    local H, K = Crossword.AI.hint, Crossword.AI.check
    -- (job: the AI that does it, for "AI for this": hints are Ask's, checks read handwriting.)
    Notes.addAiFeature{ key = "cw_hint", job = "ask", name = _("Crossword hints"), intro = H.intro, words = H.words, format = H.format }
    Notes.addAiFeature{ key = "cw_check", job = "read", name = _("Crossword checks"), intro = K.intro, words = K.words, format = K.format }
end

function Notes:crosswordDir()
    local dir = DataStorage:getDataDir() .. "/notes/crosswords"
    require("util").makePath(dir)
    return dir
end

-- A puzzle kept here, parsed (nil when it is not).
function Notes:loadCrossword(key)
    local f = io.open(fileOf(self:crosswordDir(), key), "rb")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    local src = sourceOf(key)
    if src == "guardian" then return Crossword.parse(body, require("json")) end
    if src == "imp" then return require("crosswordspuz").parse(body, require("json"), { key = key, day = dayOfKey(key) }) end
    return Crossword.parseFor(src, body, require("json"), dayOfKey(key))
end

-- ------------------------------------------------------------------ the Guardian's lists

-- One page of a series' list (page 1 the newest; kept a few minutes), or
-- nil and why.
function Notes:crosswordList(kind, page, quiet, noFetch)
    page = page or 1
    self.crosswordLists = self.crosswordLists or {}
    local key = kind .. ":" .. page
    local kept = self.crosswordLists[key]
    if kept and os.time() - kept.at < LIST_FOR then return kept.list end
    if noFetch then return nil, self.crosswordListWhy or "no list" end
    local msg = not quiet and busy(_("Getting the list of crosswords…"))
    local code, body = get(Crossword.seriesURL(kind, page))
    if msg then UIManager:close(msg) end
    if code ~= 200 then return nil, tostring(code) end
    local list, why = Crossword.recent(body, kind, require("json"))
    if list then self.crosswordLists[key] = { at = os.time(), list = list } end
    return list, why
end

-- Five puzzles of a series from the `from`-th newest (0 the newest), from
-- the list pages they are on; and whether there are older ones. nil and
-- why when the list cannot be had.
function Notes:crosswordItems(kind, from, noFetch)
    local per = Crossword.PER_PAGE
    local items = {}
    local page = math.floor(from / per) + 1
    local skip = from % per
    local more = false
    while #items < 5 do
        local list, why = self:crosswordList(kind, page, nil, noFetch)
        if not list then
            if #items == 0 then return nil, why end
            break
        end
        for i = skip + 1, #list do
            if #items < 5 then table.insert(items, list[i]) else more = true end
        end
        if #list < per then break end   -- the last page
        if #items == 5 then
            more = true
            break
        end
        page, skip = page + 1, 0
    end
    return items, more
end

-- ------------------------------------------------------------------ the picker

--- The picker: the source (and the Guardian's kind), then the day; Newer
-- and Older go through it five at a time, Random picks one from any year.
function Notes:getCrossword(src, kind, from, listTried)
    src = src or Settings.get("crossword_source") or "guardian"
    if not Crossword.SOURCES[src] then src = "guardian" end
    kind = kind or Settings.get("crossword_kind") or "quick"
    if not NAMES[kind] then kind = "quick" end
    from = from or 0
    NetworkMgr:runWhenOnline(function()
        -- The Guardian's list first (in the background), then the picker.
        if src == "guardian" and not listTried and not self:loadCrosswordLists(kind, from, _("Getting the list of crosswords…"),
                function() self:getCrossword(src, kind, from, true) end) then
            return
        end
        -- One list: the days, then older and newer, Random, the last 7 days,
        -- and another source (the Guardian's kinds each a source of its own).
        local KO = require("notesko")
        local rows = {}
        local function add(text, fn) table.insert(rows, { text = text, fn = fn }) end
        local now = today()
        local items, more, why
        if src == "guardian" then
            items, more = self:crosswordItems(kind, from, true)
            if not items then why = more more = false end
        else
            local days
            days, more = Crossword.days(src, now, from, 5)
            items = {}
            for __, day in ipairs(days) do table.insert(items, { day = day }) end
        end
        if items and #items > 0 then
            for __, item in ipairs(items) do
                local when = item.day and Crossword.dayLabel(item.day, item.day < now - 300) or ""
                if item.day == now then when = T(_("Today · %1"), when) end
                add(item.number and T(_("%1   No %2"), when, withCommas(item.number)) or when, function()
                    if src == "guardian" then self:fetchCrossword(kind, item.number) else self:fetchDated(src, item.day) end
                end)
            end
        else
            table.insert(rows, { text = T(_("Could not get the list (%1)"), tostring(why)), enabled = false })
        end
        if more == true then add(_("Older"), function() self:getCrossword(src, kind, from + 5) end) end
        if from > 0 then add(_("Newer"), function() self:getCrossword(src, kind, math.max(0, from - 5)) end) end
        add(_("Random"), function() self:randomCrossword(src, kind) end)
        add(_("Get the last 7 days"), function() self:getRecentCrosswords(src, kind) end)
        add(_("Another source…"), function()
            local options = {}
            for __, s2 in ipairs(Crossword.SOURCE_ORDER) do
                if s2 == "guardian" then
                    for __, k in ipairs(Crossword.KINDS) do
                        table.insert(options, { label = T(_("Guardian %1"), NAMES[k]), value = "guardian/" .. k })
                    end
                else
                    table.insert(options, { label = Crossword.SOURCES[s2].name, value = s2 })
                end
            end
            KO.choose(_("Get a crossword from"), options, src == "guardian" and ("guardian/" .. kind) or src, function(v)
                if not v then return end
                local s2, k = v:match("^(%a+)/?(%a*)$")
                Settings.set("crossword_source", s2)
                if k ~= "" then Settings.set("crossword_kind", k) end
                self:getCrossword(s2, k ~= "" and k or nil)
            end, function() self:getCrossword(src, kind, from, true) end)   -- (Back: the days again)
        end)
        local name = src == "guardian" and T(_("Guardian %1"), NAMES[kind]) or Crossword.SOURCES[src].name
        local title = T(_("Get a crossword\nFrom %1"), name)
        if src == "guardian" and kind == "prize" then title = title .. _(". Prize answers come out a week later.") end
        KO.list(title, rows)
    end)
end

--- `job` run in the background (see inBackground) with `text` showing and
-- a Cancel button (only Cancel stops the wait: a stray tap does nothing);
-- done(result) or done(nil, why) after, unless Cancel was tapped (then
-- onCancel(), if given, and the result is dropped).
function Notes:download(text, job, done, limit, onCancel)
    local cancelled = false
    local msg
    local function cancel()
        cancelled = true
        if onCancel then onCancel() end
    end
    -- (Only one that takes the Cancel: wait(text, { cancel }).)
    local wait = popup("wait")
    local info = wait and debug.getinfo(wait, "u")
    if not (info and info.nparams and info.nparams >= 2) then wait = nil end
    if wait then
        -- (The apps' wait box, with its Cancel: other taps do nothing.)
        msg = wait(text, { cancel = cancel })
    else
        msg = ButtonDialog:new{
            title = text,
            title_align = "center",
            dismissable = false,
            buttons = { { { text = _("Cancel"), callback = function()
                UIManager:close(msg)
                cancel()
            end } } },
        }
        UIManager:show(msg)
    end
    inBackground(job, function(r, why)
        if cancelled then return end
        if wait then msg:close() else UIManager:close(msg) end
        done(r, why)
    end, limit)
end

--- The Guardian list pages that `from` needs, loaded in the background
-- when they aren't kept (`text` shown meanwhile, if given), then after().
-- True when they are kept already (after() isn't called then).
function Notes:loadCrosswordLists(kind, from, text, after)
    local per = Crossword.PER_PAGE
    local first = math.floor(from / per) + 1
    local pages = { first }
    if per - from % per < 5 then table.insert(pages, first + 1) end
    self.crosswordLists = self.crosswordLists or {}
    local missing = {}
    for __, pg in ipairs(pages) do
        local kept = self.crosswordLists[kind .. ":" .. pg]
        if not (kept and os.time() - kept.at < LIST_FOR) then table.insert(missing, pg) end
    end
    if #missing == 0 then return true end
    if self.crosswordListLoading then return false end
    self.crosswordListLoading = true
    local function job()
        local out = {}
        for __, pg in ipairs(missing) do
            local list, why = self:crosswordList(kind, pg, true)
            if not list then
                out.why = tostring(why)
                break
            end
            out["p" .. pg] = list
        end
        return out
    end
    local function got(r, why)
        self.crosswordListLoading = nil
        self.crosswordListWhy = r and r.why or why
        if self.crosswordListWhy then self.crosswordListFail = { id = kind .. ":" .. from, at = os.time() } end
        for __, pg in ipairs(missing) do
            local list = r and r["p" .. pg]
            if type(list) == "table" then self.crosswordLists[kind .. ":" .. pg] = { at = os.time(), list = list } end
        end
        after()
    end
    -- (Cancelled: loaded again next time.)
    if text then
        self:download(text, job, got, nil, function() self.crosswordListLoading = nil end)
    else
        inBackground(job, got)
    end
    return false
end

-- The puzzles already in a source's book: { ["quick/17616"] = true }.
function Notes:crosswordsHad(src)
    local had = {}
    local nb = self:crosswordBook(src, true)
    for __, page in ipairs(nb and nb.pages or {}) do
        local key = (page.pz or ""):match("^(.-):")
        if key then had[key] = true end
    end
    return had
end

--- A random puzzle of a source (any year it goes back to), not one already
-- in its book.
function Notes:randomCrossword(src, kind)
    if not self.randomSeeded then
        math.randomseed(os.time())   -- else the same picks after every start
        self.randomSeeded = true
    end
    NetworkMgr:runWhenOnline(function()
        local had = self:crosswordsHad(src)
        local seed = math.random(1, 2 ^ 30)
        self:download(T(_("Picking a random crossword from %1…"), Crossword.SOURCES[src].name), function()
            math.randomseed(seed)   -- (the child's own picks)
            if src ~= "guardian" then
                -- A random day: tried again when that day has no puzzle.
                for __ = 1, 8 do
                    local day = Crossword.randomDay(src, today(), math.random)
                    if not had[src .. "/" .. Crossword.ymd(day)] then
                        local p = self:fetchDatedPuzzle(src, day)
                        if p then return { key = p.key } end
                    end
                end
                return {}
            end
            local pages = Crossword.RANDOM_PAGES[kind] or 20
            for __ = 1, 6 do
                local page = math.random(1, pages)
                local list = self:crosswordList(kind, page, true)
                if list and #list > 0 then
                    local fresh = {}
                    for __, item in ipairs(list) do
                        if not had[kind .. "/" .. item.number] then table.insert(fresh, item) end
                    end
                    if #fresh > 0 then
                        local p = self:fetchGuardianPuzzle(kind, fresh[math.random(1, #fresh)].number)
                        return { key = p and p.key }
                    end
                elseif list then
                    pages = math.max(1, page - 1)   -- past the end of the lists: look nearer
                end
            end
            return {}
        end, function(r)
            local p = r and r.key and self:loadCrossword(r.key)
            if not p then
                message(_("Could not pick a crossword. Try again."))
                return
            end
            self:addCrossword(p, src)
        end, 150)
    end)
end

-- ------------------------------------------------------------------ fetching

-- What was fetched, kept for when the book's PDF is made again.
function Notes:keepCrossword(key, body)
    local f = io.open(fileOf(self:crosswordDir(), key), "wb")
    if f then
        f:write(body)
        f:close()
    end
end

-- A Guardian puzzle fetched, kept and read: the puzzle, or nil and why
-- (a number: the reply's code).
function Notes:fetchGuardianPuzzle(kind, number)
    local code, body = get(Crossword.puzzleURL(kind, number))
    if code ~= 200 then return nil, code end
    local p, why = Crossword.parse(body, require("json"))
    if not p then return nil, why end
    self:keepCrossword(p.key, body)
    return p
end

function Notes:fetchCrossword(kind, number)
    NetworkMgr:runWhenOnline(function()
        self:download(T(_("Getting %1 crossword No %2…"), NAMES[kind] or kind, withCommas(number)), function()
            local p, why = self:fetchGuardianPuzzle(kind, number)
            return { key = p and p.key, why = not p and tostring(why) or nil }
        end, function(r, why)
            local p = r and r.key and self:loadCrossword(r.key)
            if not p then
                why = r and r.why or why
                message(why == "404" and T(_("There is no %1 crossword No %2."), NAMES[kind] or kind, withCommas(number))
                    or T(_("Could not get the crossword (%1)."), tostring(why)))
                return
            end
            self:addCrossword(p, "guardian")
        end)
    end)
end

-- The newest puzzles of a source (of a kind for the Guardian), up to
-- `count`, newest first: { key, day, kind, number }; nil and why when the
-- list cannot be had.
function Notes:newestCrosswords(src, kind, count, quiet)
    local out = {}
    if src == "guardian" then
        local list, why = self:crosswordList(kind, 1, quiet)
        if not list then return nil, why end
        for i = 1, math.min(count, #list) do
            local item = list[i]
            table.insert(out, { key = kind .. "/" .. item.number, kind = kind, number = item.number, day = item.day })
        end
        return out
    end
    for __, day in ipairs((Crossword.days(src, today(), 0, count))) do
        table.insert(out, { key = src .. "/" .. Crossword.ymd(day), day = day })
    end
    return out
end

-- One of those fetched: the puzzle, or nil and why.
function Notes:fetchItem(src, item)
    if src == "guardian" then return self:fetchGuardianPuzzle(item.kind, item.number) end
    return self:fetchDatedPuzzle(src, item.day)
end

--- The last 7 puzzles of a source that are not in its book yet, fetched
-- and added (for when you will be away from Wi-Fi).
function Notes:getRecentCrosswords(src, kind)
    NetworkMgr:runWhenOnline(function()
        local had = self:crosswordsHad(src)
        self:download(_("Getting the last 7 days…"), function()
            local items, why = self:newestCrosswords(src, kind, 7, true)
            if not items then return { listWhy = tostring(why) } end
            local keys, wanted = {}, 0
            for __, item in ipairs(items) do
                if not had[item.key] then
                    wanted = wanted + 1
                    local p = self:fetchItem(src, item)
                    if p then table.insert(keys, p.key) end
                end
            end
            return { keys = keys, wanted = wanted }
        end, function(r, why)
            if not r or r.listWhy then
                message(T(_("Could not get the list (%1)."), tostring(r and r.listWhy or why)))
                return
            end
            if r.wanted == 0 then
                message(_("You already have the last 7."))
                return
            end
            local got = {}
            for __, key in ipairs(r.keys or {}) do
                local p = self:loadCrossword(key)
                if p then table.insert(got, p) end
            end
            if #got == 0 then
                message(_("Could not get the crosswords."))
                return
            end
            self:addCrosswords(src, got, true)
            require("notesko").toast(T(_("Added %1 crosswords"), #got))
        end, 240)
    end)
end

-- A source's puzzle for a day, fetched, kept and read: the puzzle, or nil
-- and why (a number: there is none that day).
function Notes:fetchDatedPuzzle(src, day)
    local code, body = get(Crossword.dateURL(src, day))
    if code == 200 and src == "tny" then
        -- The day's page names the puzzle; the puzzle itself is elsewhere.
        local id = Crossword.tnyId(body)
        if not id then return nil, 404 end
        code, body = get(Crossword.tnyURL(id))
    end
    if code ~= 200 then return nil, code end
    -- The Washington Post answers a day it has no puzzle for with nothing.
    if #body < 50 then return nil, 404 end
    local p, why = Crossword.parseFor(src, body, require("json"), day)
    if not p then return nil, why end
    self:keepCrossword(p.key, body)
    return p
end

function Notes:fetchDated(src, day)
    NetworkMgr:runWhenOnline(function()
        self:download(T(_("Getting the crossword for %1 from %2…"), Crossword.dayLabel(day, true), Crossword.SOURCES[src].name), function()
            local p, why = self:fetchDatedPuzzle(src, day)
            return { key = p and p.key, why = not p and tostring(why) or nil }
        end, function(r, why)
            local p = r and r.key and self:loadCrossword(r.key)
            if not p then
                why = r and r.why or why
                message((why == "404" or why == "0") and T(_("No crossword from %1 for %2."),
                    Crossword.SOURCES[src].name, Crossword.dayLabel(day, true)) or T(_("Could not get the crossword (%1)."), tostring(why)))
                return
            end
            self:addCrossword(p, src)
        end)
    end)
end

-- ------------------------------------------------------------------ the books

-- A source's book (made the first time, in Crosswords/<the source>, unless
-- `noMake`), read.
function Notes:crosswordBook(src, noMake)
    local books = Settings.get("crossword_books") or {}
    local id = books[src] or (src == "guardian" and Settings.get("crossword_book"))
    local nb = id and self.store:read(id)
    if nb and nb.feed == src then return nb end
    if noMake then return nil end
    -- Upright to start with (turned with the Kindle, or ⋯ > Page orientation).
    local w, h = Screen:getWidth(), Screen:getHeight()
    nb = self.store:create(_(Crossword.SOURCES[src].book), math.min(w, h), math.max(w, h), "plain")
    if not nb then return nil end
    nb.puzzle, nb.feed, nb.pdf, nb.pages = true, src, nb.id .. ".pdf", {}
    if not Settings.get("pressure") then nb.pressure = false end
    books[src] = nb.id
    Settings.set("crossword_books", books)
    -- Kept apart from the notebooks: Crosswords/<the source> (it can be moved).
    if self.folders then
        self.folders:set(nb.id, _("Crosswords") .. (FOLDERS[src] and ("/" .. FOLDERS[src]) or ""))
        self.folders:save()
    end
    nb.pdfPath = self.store.dir .. "/" .. nb.pdf
    return nb
end

-- A book's PDF made again (`fresh`: puzzles just fetched, by key) and the
-- book saved. True, or nil and why.
function Notes:saveCrosswordBook(nb, fresh)
    local pdf = Crossword.bookPDF(nb, function(key)
        return fresh and fresh[key] or self:loadCrossword(key)
    end, layoutOpts())
    nb.lay = layName()
    local path = self.store.dir .. "/" .. nb.pdf
    local f = io.open(path .. ".tmp", "wb")
    if not f then return nil, "cannot write the PDF" end
    f:write(pdf)
    f:close()
    os.remove(path)
    os.rename(path .. ".tmp", path)
    local ok, why = self.store:save(nb)
    if not ok then return nil, why end
    -- The copy kept from when the book was last closed (for its undo) is
    -- out of date now, even saved within the same second.
    if self.kept then self.kept[nb.id] = nil end
    return true
end

--- Puzzles into their source's book (its PDF made again once); with
-- `open`, the book opened at the first of them. Without, a book open in
-- Notes is left alone (nothing added). Returns the first one's page and
-- whether anything was added.
function Notes:addCrosswords(src, ps, open)
    local ed = self.editor
    local books = Settings.get("crossword_books") or {}
    local id = books[src] or (src == "guardian" and Settings.get("crossword_book"))
    if ed and UIManager:isWidgetShown(ed) then
        -- The book may be open: closed (saved) first, opened again after.
        if open then self:closeEditor() elseif id and ed.notebook.id == id then return nil, false end
    end
    local nb = self:crosswordBook(src)
    if not nb then
        message(_("Could not make the crossword book."))
        return nil, false
    end
    local first, any, fresh = nil, false, {}
    -- Laid out as the settings say now (an older book's other puzzles too).
    if nb.lay ~= layName() or self:crosswordBookOld(nb) then
        Crossword.syncBook(nb, function(key) return self:loadCrossword(key) end, Store.newPageId, layoutOpts())
        any = true
    end
    for __, p in ipairs(ps) do
        local at, added = Crossword.addToBook(nb, p, Store.newPageId, layoutOpts())
        first = first or at
        any = any or added
        fresh[p.key] = p
    end
    if any then
        local ok, why = self:saveCrosswordBook(nb, fresh)
        if not ok then
            message(T(_("Could not save the crossword:\n%1"), tostring(why)))
            return nil, false
        end
    end
    self:refresh()
    if open then self:open(nb.id, first) end
    return first, any
end

-- Whether a book of crosswords lacks pages: any puzzle without its pages
-- for landscape (books from before them).
function Notes:crosswordBookOld(nb)
    local land, keys = {}, {}
    for __, page in ipairs(nb.pages) do
        local key, part = Crossword.keyPart(page)
        if key then
            keys[key] = true
            if part == "L1" then land[key] = true end
        end
    end
    for key in pairs(keys) do
        if not land[key] then return true end
    end
    return false
end

--- A book of crosswords about to open, laid out as the settings say now
-- (its PDF made again when not). Returns the notebook.
function Notes:prepareCrosswordBook(nb)
    if not nb.feed or (nb.lay == layName() and not self:crosswordBookOld(nb)) then return nb end
    local msg = busy(_("Laying out the crosswords…"))
    Crossword.syncBook(nb, function(key) return self:loadCrossword(key) end, Store.newPageId, layoutOpts())
    local ok, why = self:saveCrosswordBook(nb)
    UIManager:close(msg)
    if not ok then logger.warn("Notes crossword: could not lay out the book", why) end
    return nb
end

--- A puzzle into its source's book, then the book opened at it.
function Notes:addCrossword(p, src)
    local __, added = self:addCrosswords(src, { p }, true)
    if not p.answers then
        require("notesko").toast(_("No answers yet: get this crossword again once they are out."))
    elseif not added then
        require("notesko").toast(_("Already in the book"))
    end
end

-- ------------------------------------------------------------------ automatic

local AUTO_KEYS = { "guardian/quick", "guardian/cryptic", "guardian/quiptic", "guardian/prize", "usa", "universal", "wapo", "tny" }
local AUTO_NAMES = { ["guardian/quick"] = _("Guardian Quick"), ["guardian/cryptic"] = _("Guardian Cryptic"),
    ["guardian/quiptic"] = _("Guardian Quiptic"), ["guardian/prize"] = _("Guardian Prize, and its answers when they come out"),
    usa = _("USA Today"), universal = _("Universal"), wapo = _("Washington Post (Sundays)"), tny = _("New Yorker") }
local AUTO_EVERY = 3600   -- seconds between automatic looks

--- Which sources get new puzzles automatically.
function Notes:crosswordAutoSettings(done)
    local on = {}
    for __, k in ipairs(Settings.get("crossword_auto") or {}) do on[k] = true end
    local items = {}
    for __, k in ipairs(AUTO_KEYS) do
        table.insert(items, { text = AUTO_NAMES[k], checked = on[k], fn = function()
            on[k] = not on[k] or nil
            local keys = {}
            for __, k2 in ipairs(AUTO_KEYS) do
                if on[k2] then table.insert(keys, k2) end
            end
            Settings.set("crossword_auto", keys)
            Settings.set("crossword_auto_at", 0)   -- look soon
            self:crosswordAutoSettings(done)
        end })
    end
    require("notesko").list(_("Get new crosswords automatically\nWhen Crosswords opens or Wi-Fi comes on. Up to the last 3 days."), items,
        function() if done then done() end end)
end

--- The newest puzzles (up to 3 days old) of the sources picked, added to
-- their books; with Guardian Prize picked, Prize answers once out. Only
-- with Wi-Fi on (it is never turned on), at most once an hour.
function Notes:autoCrosswords(force)
    local keys = Settings.get("crossword_auto") or {}
    if #keys == 0 or not NetworkMgr:isConnected() then return end
    if not force and os.time() - (Settings.get("crossword_auto_at") or 0) < AUTO_EVERY then return end
    if self.crosswordAutoRunning then return end
    Settings.set("crossword_auto_at", os.time())
    self.crosswordAutoRunning = true
    inBackground(function() return self:autoCrosswordsFetch(keys) end, function(r)
        self.crosswordAutoRunning = nil
        if not r then return end
        local added, opens = false, nil
        for src, keysOf in pairs(r.bySrc or {}) do
            local ps = {}
            for __, key in ipairs(keysOf) do
                local p = self:loadCrossword(key)
                if p then table.insert(ps, p) end
            end
            if #ps > 0 then
                local first, any = self:addCrosswords(src, ps, false)
                added = added or any
                local nb = first and self:crosswordBook(src, true)
                if nb and not opens then opens = { book = nb.id, page = first } end
            end
        end
        if added and (r.newCount or 0) > 0 then
            require("notesko").toast(T(_("Added %1 new crosswords"), r.newCount))
            -- In the shared notifications too (the launcher's), tapped to open the first.
            local PS = require("pluginshare")
            if PS.notify then
                PS.notify{ app = "crosswords", name = _("Crosswords"), icon = "newspaper", key = "crosswords:new",
                    text = r.newCount == 1 and _("A new crossword is ready") or T(_("%1 new crosswords are ready"), r.newCount),
                    route = opens, open = opens and function() self:open(opens.book, opens.page) end or nil }
            end
        elseif added and (r.answerCount or 0) > 0 then
            require("notesko").toast(_("Added answers for Prize crosswords"))
            -- In the notifications too, tapped to open the first of those puzzles.
            local PS = require("pluginshare")
            local nb = self:crosswordBook("guardian", true)
            local at = nb and r.answerKeys and r.answerKeys[1] and Crossword.pageOf(nb, r.answerKeys[1], "1")
            if PS.notify then
                PS.notify{ app = "crosswords", name = _("Crosswords"), icon = "newspaper", key = "crosswords:answers",
                    text = r.answerCount == 1 and _("A Prize crossword has its answers") or T(_("%1 Prize crosswords have their answers"), r.answerCount),
                    route = at and { book = nb.id, page = at } or nil,
                    open = at and function() self:open(nb.id, at) end or nil }
            end
        end
    end, 300)
end

-- (In the background.) The new puzzles of the sources picked, and Prize
-- answers now out: { bySrc = { src = { keys } }, newCount, answerCount }.
function Notes:autoCrosswordsFetch(keys)
    local now = today()
    local bySrc, newCount, answerCount = {}, 0, 0
    local answerKeys = {}
    local function want(src, p)
        bySrc[src] = bySrc[src] or {}
        table.insert(bySrc[src], p.key)
    end
    for __, k in ipairs(keys) do
        local src, kind = k:match("^(%a+)/?(%a*)$")
        kind = kind ~= "" and kind or nil
        if src and Crossword.SOURCES[src] then
            local had = self:crosswordsHad(src)
            for __, item in ipairs(self:newestCrosswords(src, kind, 3, true) or {}) do
                if item.day and item.day >= now - 2 and not had[item.key] then
                    local p = self:fetchItem(src, item)
                    if p then
                        want(src, p)
                        newCount = newCount + 1
                    end
                end
            end
            if k == "guardian/prize" then
                -- Prize puzzles in the book without answers, a week old or more.
                local nb = self:crosswordBook("guardian", true)
                local answered, waiting = {}, {}
                for __, page in ipairs(nb and nb.pages or {}) do
                    local key, part = (page.pz or ""):match("^(prize/%d+):(%w+)$")
                    if key and part == "a" then answered[key] = true end
                    if key and part == "1" and (not page.day or page.day <= now - 6) then table.insert(waiting, key) end
                end
                for __, key in ipairs(waiting) do
                    if not answered[key] and answerCount < 3 then
                        local p = self:fetchGuardianPuzzle("prize", tonumber(key:match("%d+$")))
                        if p and p.answers then
                            want("guardian", p)
                            answerCount = answerCount + 1
                            answered[key] = true
                            table.insert(answerKeys, key)
                        end
                    end
                end
            end
        end
    end
    return { bySrc = bySrc, newCount = newCount, answerCount = answerCount, answerKeys = answerKeys }
end

-- ------------------------------------------------------------------ in a book

-- The puzzle and laid-out page an editor's page shows: p, page, part; nil
-- when it is not a puzzle fetched or cannot be read.
function Notes:crosswordOnPage(ed)
    return self:crosswordPage(ed.notebook.pages[ed.page])
end

--- The puzzle and laid-out page a book's page shows: p, page, part; nil
-- when it is not a puzzle fetched or cannot be read. The last few puzzles
-- laid out are kept (pages turned, tapped).
function Notes:crosswordPage(page)
    local key, part = Crossword.keyPart(page)
    if not key then return nil end
    local land = part:sub(1, 1) == "L"
    local id = key .. "|" .. layName() .. (land and "|L" or "")
    self.laidOut = self.laidOut or {}
    local kept = self.laidOut[id]
    if not kept then
        local p = self:loadCrossword(key)
        if not p then return nil end
        local opts = layoutOpts()
        opts.landscape = land
        kept = { p = p, pages = Crossword.layout(p, opts) }
        if #self.laidOut >= 6 then self.laidOut = {} end
        self.laidOut[id] = kept
        table.insert(self.laidOut, id)
    end
    for __, lp in ipairs(kept.pages) do
        if lp.part == part then return kept.p, lp, part end
    end
end

--- Where page `i` of a book of crosswords has its grid on a w × h screen
-- ({ x, y, size, cols, rows }, as Crossword.gridOnScreen), or nil.
function Notes:crosswordGridAt(nb, i, w, h)
    local p, lp = self:crosswordPage(nb.pages[i])
    return p and Crossword.gridOnScreen(p, lp, w, h)
end

--- A puzzle's grid writing carried to its grid page for the other
-- orientation, turning to `landscape` (the screen w × h then, h × w
-- before); not when it is as it was carried here (turned back and forth,
-- it would shift a little each time). True when it was.
function Notes:carryCrosswordGrid(nb, key, landscape, w, h)
    local p = self:loadCrossword(key)
    if not p then return end
    local fromPart, toPart = landscape and "1" or "L1", landscape and "L1" or "1"
    local __, src = Crossword.pageOf(nb, key, fromPart)
    local __, dst = Crossword.pageOf(nb, key, toPart)
    if not (src and dst) then return end
    local function laid(land, part)
        local opts = layoutOpts()
        opts.landscape = land
        for __, lp in ipairs(Crossword.layout(p, opts)) do
            if lp.part == part then return lp end
        end
    end
    local slp, dlp = laid(not landscape, fromPart), laid(landscape, toPart)
    local from = slp and Crossword.gridOnScreen(p, slp, h, w)
    local to = dlp and Crossword.gridOnScreen(p, dlp, w, h)
    if not (from and to) then return end
    self.carried = self.carried or {}
    if self.carried[key] and self.carried[key] == Crossword.gridText(src, from) then return end
    Crossword.carryGrid(src, dst, from, to)
    self.carried[key] = Crossword.gridText(dst, to)
    -- And on its other clue pages that way round (the same grid in the same place).
    for k = 2, math.huge do
        local __, more = Crossword.pageOf(nb, key, (landscape and "L" or "") .. k)
        if not more then break end
        Crossword.carryGrid(dst, more, to, to)
    end
    return true
end

--- The lasso's Answer: the answers of the clues (or squares) in `area` (on
-- the screen), from the book; Show in the grid types them in their squares.
--- The lasso's Reveal: the letters of the squares whose middle is inside
-- `area` (on the screen) put in, grey and marked, as Reveal a letter does
-- (one Undo takes them out).
function Notes:crosswordReveal(ed, area)
    local p, lp = self:crosswordOnPage(ed)
    if not (p and lp.grid) or lp.part == "a" or lp.part == "La" then
        return message(_("Go to the page with the grid to reveal letters."))
    end
    if not p.answers then return message(_("This crossword has no answers yet.")) end
    local ox, oy, z = Crossword.fit(ed.w, ed.h, lp.w, lp.h)
    local bx, by, bw, bh = (area[1] - ox) / z, (area[2] - oy) / z, area[3] / z, area[4] / z
    local squares, seen = {}, {}
    for __, e in ipairs(p.entries) do
        for __, sq in ipairs(Crossword.squaresOf(lp, e)) do
            local mx, my = sq[1] + sq[3] / 2, sq[2] + sq[3] / 2
            local key = sq[1] .. "," .. sq[2]
            if not seen[key] and sq[4] and mx >= bx and mx < bx + bw and my >= by and my < by + bh then
                seen[key] = true
                table.insert(squares, sq)
            end
        end
    end
    if #squares == 0 then return message(_("Lasso some squares to reveal their letters.")) end
    self:revealSquares(ed, squares, ox, oy, z)
end

function Notes:crosswordAnswer(ed, area)
    local p, lp = self:crosswordOnPage(ed)
    if not p then
        message(_("This crossword could not be read."))
        return
    end
    local ox, oy, z = Crossword.fit(ed.w, ed.h, lp.w, lp.h)
    local box = { (area[1] - ox) / z, (area[2] - oy) / z, area[3] / z, area[4] / z }
    local entries = Crossword.entriesIn(p, lp, box)
    if #entries == 0 then
        message(_("Lasso a clue or some squares to see the answer."))
        return
    end
    local lines = {}
    for __, e in ipairs(entries) do
        table.insert(lines, Crossword.entryTitle(e) .. "\n" .. (e.answer or _("No answer yet")))
    end
    local text = table.concat(lines, "\n\n")
    require("notesko").list(text, {
        { text = _("Show in the grid"), enabled = lp.grid ~= nil and lp.part ~= "a" and lp.part ~= "La" and p.answers == true,
            fn = function() self:showAnswersInGrid(ed, lp, entries, ox, oy, z) end },
        -- (The answers on the clipboard.)
        { text = _("Copy"), fn = function()
            if Device.input.setClipboardText then Device.input.setClipboardText(text) end
            require("notesko").toast(_("Copied"))
        end },
    })
end

--- Answers typed in their squares (revealed: grey, the square marked;
-- Undo takes them away).
function Notes:showAnswersInGrid(ed, lp, entries, ox, oy, z)
    local squares = {}
    for __, e in ipairs(entries) do
        for __, sq in ipairs(Crossword.squaresOf(lp, e)) do table.insert(squares, sq) end
    end
    self:revealSquares(ed, squares, ox, oy, z)
end

--- Letters revealed in their squares ({ { x, y, size, letter } } in
-- points, as Crossword.squaresOf), each once, not where one already is;
-- the puzzle's hints counted.
function Notes:revealSquares(ed, squares, ox, oy, z)
    local have = {}
    for __, it in ipairs(ed:pageItems()) do
        if it.rev then have[it.x .. "," .. it.y] = true end
    end
    local items = {}
    for __, sq in ipairs(squares) do
        local size = sq[3] * z
        local it = { k = "text", x = math.floor(ox + sq[1] * z), y = math.floor(oy + sq[2] * z + size * 0.18),
            w = math.floor(size), size = math.floor(size * 0.5), align = "center", text = sq[4], rev = true }
        if sq[4] and not have[it.x .. "," .. it.y] then
            have[it.x .. "," .. it.y] = true
            table.insert(items, it)
        end
    end
    if #items == 0 then return end
    local first = ed:puzzleFirst()
    if first then first.hints = (first.hints or 0) + 1 end
    ed:addTypedItems(items)
end

--- A hint from the Hint panel: `mode` "letter", "word", "check" or "ask"
-- for what's at (sx, sy) on the editor's page; or "answers" (the answers
-- page). True when the tap was taken (else the hint waits on).
function Notes:crosswordHint(ed, mode, sx, sy)
    local nb = ed.notebook
    local function info(text) message(text) end
    if mode == "answers" then
        local key, part = Crossword.keyPart(nb.pages[ed.page])
        local at = key and Crossword.pageOf(nb, key, part:sub(1, 1) == "L" and "La" or "a")
        if at then ed:goPage(at) else info(_("This crossword has no answers yet.")) end
        return true
    end
    local p, lp = self:crosswordOnPage(ed)
    if not (p and lp.grid) then return false end
    local ox, oy, z = Crossword.fit(ed.w, ed.h, lp.w, lp.h)
    local x, y = (sx - ox) / z, (sy - oy) / z
    local cx, cy = Crossword.squareAt(p, lp, x, y)
    local function square(e, i)
        local g = lp.grid
        local ex, ey = e.across and e.x + i or e.x, e.across and e.y or e.y + i
        return { g.x + ex * g.cell, g.y + ey * g.cell, g.cell, e.answer and e.answer:sub(i + 1, i + 1) or nil }
    end
    if mode == "letter" then
        if not cx then return false end
        local e = Crossword.entriesAt(p, cx, cy)[1]
        if not (p.answers and e.answer) then
            info(_("This crossword has no answers yet."))
            return true
        end
        self:revealSquares(ed, { square(e, e.across and cx - e.x or cy - e.y) }, ox, oy, z)
        return true
    end
    local function go(e)
        if mode == "word" then
            if not (p.answers and e.answer) then return info(_("This crossword has no answers yet.")) end
            local squares = {}
            for i = 0, e.length - 1 do table.insert(squares, square(e, i)) end
            self:revealSquares(ed, squares, ox, oy, z)
        elseif mode == "check" then
            self:checkCrossword(ed, nil, e)
        else
            self:crosswordAIHint(ed, lp, e, { math.floor(sx), math.floor(sy) })
        end
    end
    local e = Crossword.clueAt(lp, x, y)
    if e then
        go(e)
        return true
    end
    if not cx then return false end
    local es = Crossword.entriesAt(p, cx, cy)
    if #es == 1 then
        go(es[1])
        return true
    end
    -- A square both ways: which word.
    local dialog
    local buttons = {}
    for __, e2 in ipairs(es) do
        table.insert(buttons, { { text = Crossword.entryTitle(e2), align = "left", callback = function()
            UIManager:close(dialog)
            go(e2)
        end } })
    end
    table.insert(buttons, { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } })
    dialog = require("notesko").buttonDialog{ title = _("Which word?"), buttons = buttons }
    return true
end

--- A hint to entry `e` from the AI (with a picture of its clue): a nudge,
-- never the answer (one that gives it away is asked again, then not
-- shown), pinned over the page by `near`. Asked again for the same clue,
-- it goes further each time (the hints given are kept while the book is open).
function Notes:crosswordAIHint(ed, lp, e, near, strict)
    if not self:claudeReady("ask") then
        return self:handwritingSettings(self:aiNotReadyText("ask"))
    end
    local ox, oy, z = Crossword.fit(ed.w, ed.h, lp.w, lp.h)
    -- The clue as printed (else its squares): the picture is only to go with the words.
    local b = Crossword.clueOf(lp, e) or Crossword.entryBox(lp, e)
    local pad = 4
    local png = ed:pictureOf({ crop = { math.floor(ox + (b[1] - pad) * z), math.floor(oy + (b[2] - pad) * z),
        math.ceil((b[3] + 2 * pad) * z), math.ceil((b[4] + 2 * pad) * z) } })
    if not png then return end
    ed.hintsGiven = ed.hintsGiven or {}
    local key = tostring(Crossword.keyPart(ed.notebook.pages[ed.page])) .. ":" .. Crossword.entryId(e)
    local given = ed.hintsGiven[key] or {}
    -- (Plain or cryptic, from the puzzle: only that kind's instructions.)
    local kind = Crossword.kindOf and Crossword.kindOf(Crossword.keyPart(ed.notebook.pages[ed.page])) or nil
    local prompt = Crossword.hintPrompt(e, given, strict, self.aiInstructions and self:aiInstructions("cw_hint") or nil, kind)
    NetworkMgr:runWhenOnline(function()
        local claude = self:claude("ask")
        self:download(_("Asking the AI for a hint…"), function()
            local text, why = claude:transcribe(png, prompt)
            return { text = text, why = why and tostring(why) or nil }
        end, function(r, why)
            local text = r and r.text
            if not text or text == "" then
                return message(T(_("The AI could not give a hint:\n%1"), tostring(r and r.why or why)))
            end
            if e.answer and Crossword.spoils(text, e.answer) then
                if not strict then return self:crosswordAIHint(ed, lp, e, near, true) end
                return message(_("The AI's hint gave the answer away, so it isn't shown. Try again."))
            end
            table.insert(given, text)
            ed.hintsGiven[key] = given
            local first = ed:puzzleFirst()
            if first then
                first.hints = (first.hints or 0) + 1
                ed:changed()
            end
            ed:pinClue({ { text = (#given > 1 and T(_("Hint %1 · %2"), #given, Crossword.entryTitle(e))
                or T(_("Hint · %1"), Crossword.entryTitle(e))), bold = true,
                id = Settings.get("crossword_boxes") ~= false and Crossword.entryId(e) or nil }, text }, near, text)
        end, 150)
    end)
end

--- Check my answers: the letters written in the grid read by the AI (the
-- one for reading handwriting) and compared with the answers; a dot in each
-- square that is wrong. `area` (lassoed, on the screen): only its squares.
function Notes:checkCrossword(ed, area, entry)
    local p, lp = self:crosswordOnPage(ed)
    if not p or not lp.grid then
        return message(_("Go to the page with the grid to check your answers."))
    end
    if not p.answers then
        return message(_("This crossword has no answers yet."))
    end
    if not self:claudeReady("read") then
        return self:handwritingSettings(self:aiNotReadyText("read"))
    end
    local ox, oy, z = Crossword.fit(ed.w, ed.h, lp.w, lp.h)
    local g = lp.grid
    local only
    if entry then
        -- One word (Hint > Check a word).
        only = {}
        for i = 0, entry.length - 1 do
            only[(entry.across and entry.x + i or entry.x) .. "," .. (entry.across and entry.y or entry.y + i)] = true
        end
    elseif area then
        local box = { (area[1] - ox) / z, (area[2] - oy) / z, area[3] / z, area[4] / z }
        local entries = Crossword.entriesIn(p, lp, box)
        if #entries == 0 then
            return message(_("Lasso some squares or clues to check those answers."))
        end
        only = {}
        for __, e in ipairs(entries) do
            for i = 0, e.length - 1 do
                only[(e.across and e.x + i or e.x) .. "," .. (e.across and e.y or e.y + i)] = true
            end
        end
    end
    local rect = { math.floor(ox + g.x * z), math.floor(oy + g.y * z), math.ceil(p.cols * g.cell * z), math.ceil(p.rows * g.cell * z) }
    local png = ed:pictureOf({ crop = rect })
    if not png then return end
    local prompt = Crossword.checkPrompt(p, nil, self.aiInstructions and self:aiInstructions("cw_check") or nil)
    -- The grid as sent: the answer is put on it only if it is still so.
    local at, onScreen = ed.page, Crossword.gridOnScreen(p, lp, ed.w, ed.h)
    local sent = Crossword.gridText(ed.notebook.pages[at], onScreen)
    NetworkMgr:runWhenOnline(function()
        -- (The AI is asked in the background, with a message that waits for
        -- it; its Cancel drops the answer.)
        local claude = self:claude("read")
        self:download(_("Checking your answers…"), function()
            local text, why = claude:transcribe(png, prompt)
            return { text = text, why = why and tostring(why) or nil }
        end, function(r, err)
        if self.editor ~= ed or not UIManager:isWidgetShown(ed) then return end
        if ed.page ~= at or Crossword.gridText(ed.notebook.pages[at], onScreen) ~= sent then
            return message(_("The grid changed while it was being checked. Check again."))
        end
        local text, why = r and r.text, r and r.why or err
        local read, missed
        if text then read, missed = Crossword.readGrid(text, p) end
        if not read then
            return message(text and _("Could not read the grid. Try again, or write the letters a little larger.")
                or T(_("The AI could not check the grid:\n%1"), tostring(why)))
        end
        local wrong, filled = Crossword.check(p, read, only)
        -- Clues whose squares are all right: their boxes ticked.
        local first = ed:puzzleFirst()
        if first and #ed:clueBoxes() > 0 then
            for __, id in ipairs(Crossword.solved(p, read, only)) do
                first.ticks = first.ticks or {}
                first.ticks[id] = true
            end
            ed:renderPage()
            ed:changed()
        end
        local marks = {}
        for __, sq in ipairs(wrong) do
            local size = g.cell * z
            table.insert(marks, { ox + (g.x + sq[1] * g.cell) * z, oy + (g.y + sq[2] * g.cell) * z, size })
        end
        local summary
        if filled == 0 then
            summary = _("Nothing written in to check")
        elseif #wrong == 0 then
            summary = T(_("All %1 filled squares look right"), filled)
        else
            summary = T(#wrong == 1 and _("1 square looks wrong (dotted) · %2 filled") or _("%1 squares look wrong (dotted) · %2 filled"),
                #wrong, filled)
        end
        if missed and missed > 0 then
            summary = summary .. " · " .. (missed == 1 and _("1 row not read") or T(_("%1 rows not read"), missed))
        end
        if entry then summary = (Crossword.entryTitle(entry):match("^(.-)%s*·") or "") .. ": " .. summary end
        ed:showCheck(marks, summary)
        end, 150)
    end)
end

--- A tap (pen or finger) at (sx, sy) on an editor's page: on an arrow
-- above the clues, the clues turned; on a clue's number, that clue's squares outlined (on the grid's page, gone to when
-- the clue is on another); on a grid square's number, the clues starting
-- there outlined (a clue on another page pinned over the page). True when
-- it was one.
function Notes:crosswordTap(ed, sx, sy)
    local p, lp, part = self:crosswordOnPage(ed)
    if not p then return false end
    local ox, oy, z = Crossword.fit(ed.w, ed.h, lp.w, lp.h)
    local kind, entries = Crossword.tapped(p, lp, (sx - ox) / z, (sy - oy) / z)
    if not kind then return false end
    if kind == "turn" then
        local to = ed:cluePage(entries)
        if to then ed:goPage(to) end
        return true
    end
    if Settings.get("crossword_find") == false then return false end
    if kind == "clue" and not lp.grid then
        -- A clue on a page without the grid: to the grid's page.
        local key = Crossword.keyPart(ed.notebook.pages[ed.page])
        local at = Crossword.pageOf(ed.notebook, key, part:sub(1, 1) == "L" and "L1" or "1")
        if not at then return true end
        local e = entries[1]
        ed:goPage(at)
        p, lp = self:crosswordOnPage(ed)
        if not p then return true end
        ox, oy, z = Crossword.fit(ed.w, ed.h, lp.w, lp.h)
        entries = {}
        for __, e2 in ipairs(p.entries) do
            if e2.number == e.number and e2.across == e.across then entries[1] = e2 end
        end
    end
    local function screen(r)
        return { math.floor(ox + r[1] * z), math.floor(oy + r[2] * z), math.ceil(r[3] * z), math.ceil(r[4] * z) }
    end
    -- The card: every clue (Crossword settings > Clue card: only clues on
    -- another page, those on this page just outlined in the list), each with
    -- its tick box when the clues have them.
    local every = Settings.get("crossword_card") ~= "other"
    local ticks = Settings.get("crossword_boxes") ~= false
    local boxes, rows = {}, {}
    for __, e in ipairs(entries) do
        table.insert(boxes, screen(Crossword.entryBox(lp, e)))
        local clue = Crossword.clueOf(lp, e)
        if clue then table.insert(boxes, screen(clue)) end
        if not clue or every then
            table.insert(rows, { text = Crossword.entryTitle(e), id = ticks and Crossword.entryId(e) or nil })
        end
    end
    ed:showOutline(boxes)
    if kind == "square" and #rows > 0 then ed:pinClue(rows, { math.floor(sx), math.floor(sy) }) end
    return true
end

--- The tick boxes of the clues on an editor's page, on the screen: { { x,
-- y, size, id }... }.
function Notes:crosswordBoxes(ed)
    local p, lp = self:crosswordOnPage(ed)
    local out = {}
    if not p then return out end
    local ox, oy, z = Crossword.fit(ed.w, ed.h, lp.w, lp.h)
    for __, c in ipairs(lp.clues or {}) do
        if c.box then
            table.insert(out, { ox + c.box[1] * z, oy + c.box[2] * z, c.box[3] * z, Crossword.entryId(c[5]) })
        end
    end
    return out
end

--- A puzzle taken out of its book (its pages, answers page and file); the
-- book opened again where it was (not `quiet`).
function Notes:removeCrossword(id, key, quiet)
    local ed = self.editor
    if quiet and ed and ed.notebook.id == id and UIManager:isWidgetShown(ed) then return nil, "open" end
    self:closeEditor()
    local nb = self.store:read(id)
    if not nb or not nb.feed then return end
    local at
    for i, page in ipairs(nb.pages) do
        if not at and (page.pz or ""):match("^(.-):") == key then at = i end
    end
    -- (What Undo puts back: the book as it was, and the puzzle's kept file.)
    local before = not quiet and self.store:read(id)
    local path = fileOf(self:crosswordDir(), key)
    local kept
    if before then
        local f = io.open(path, "rb")
        if f then
            kept = f:read("*a")
            f:close()
        end
    end
    if Crossword.removeFromBook(nb, key) == 0 then return end
    local ok, why = self:saveCrosswordBook(nb)
    if not ok then
        message(T(_("Could not save the crossword book:\n%1"), tostring(why)))
        return
    end
    os.remove(path)
    self:refresh()
    if quiet then return true end
    -- Opened at the puzzle nearest where it was (a first page, not an answers page).
    local open = math.max(1, math.min(at or 1, #nb.pages))
    while open > 1 and not (nb.pages[open].pz or ""):match(":1$") do open = open - 1 end
    if #nb.pages > 0 then self:open(nb.id, open) end
    local function undo()
        if not (before and kept) then return end
        local f = io.open(path, "wb")
        if not f then return end
        f:write(kept)
        f:close()
        self:closeEditor()
        local ok2, why2 = self:saveCrosswordBook(before)
        if not ok2 then return message(T(_("Could not save the crossword book:\n%1"), tostring(why2))) end
        self:refresh()
        self:open(before.id, at)
    end
    -- Undo for a few seconds (the apps' undo bar; a notice without it).
    local PS = require("pluginshare")
    local bar = PS.popup and (function()
        local okp, fn = pcall(function() return PS.popup.undo end)
        return okp and fn or nil
    end)()
    if bar and before and kept then
        bar(_("Crossword removed"), undo)
    else
        require("notesko").toast(_("Crossword removed"))
    end
    return true
end

-- ------------------------------------------------------------------ today's crossword

-- The source and kind Today's crossword opens: `which` ("usa",
-- "guardian/quick"), else Crossword settings > Today's crossword, else the
-- source last opened in Get a crossword.
local function sourceAndKind(which)
    which = which or Settings.get("crossword_today") or "last"
    local src, kind = tostring(which):match("^(%a+)/?(%a*)$")
    if which == "last" or not src or not Crossword.SOURCES[src] or src == "imp" then
        src = Settings.get("crossword_source") or "guardian"
        kind = Settings.get("crossword_kind")
    end
    if not Crossword.SOURCES[src] or src == "imp" then src = "guardian" end
    if not NAMES[kind] then kind = "quick" end
    return src, src == "guardian" and kind or nil
end

--- A random puzzle, opened: one not started yet in the books; else a random
-- one from the sources this Kindle gets puzzles from, downloaded (a waiting
-- box with Cancel). Offline, it says so.
function Notes:randomPuzzle()
    -- App lock (the launcher's): its passcode first, when this app is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask("crosswords", function() self:randomPuzzle() end) then return end
    if not self.randomSeeded then
        math.randomseed(os.time())   -- else the same picks after every start
        self.randomSeeded = true
    end
    local fresh = {}
    -- (Not the puzzle open now.)
    local ed = self.editor
    local here = ed and UIManager:isWidgetShown(ed) and ed.notebook and ed.notebook.pages[ed.page] and Crossword.keyPart(ed.notebook.pages[ed.page])
    for __, nb in ipairs(self:crosswordBooks()) do
        for i, page in ipairs(nb.pages) do
            local key, part = Crossword.keyPart(page)
            local current = here and key == here and ed.notebook.id == nb.id
            if key and part == "1" and not page.hide and not current and Crossword.state(nb, key) == "new" then
                table.insert(fresh, { book = nb.id, page = i })
            end
        end
    end
    if #fresh > 0 then
        local pick = fresh[math.random(1, #fresh)]
        return self:open(pick.book, pick.page)
    end
    if not NetworkMgr:isConnected() then
        return message(_("No puzzles left to start, and the Kindle isn't online. Turn on Wi-Fi to get one."))
    end
    local list = self:crosswordsSourcesUsed()
    if not list then
        local src, kind = sourceAndKind()
        list = { { src = src, kind = kind } }
    end
    local pick = list[math.random(1, #list)]
    self:randomCrossword(pick.src, pick.kind or "quick")
end

--- The sources Today's crossword can open (for the launcher's tiles):
-- { { key = "usa", name = "USA Today" }... }.
function Notes:crosswordSources()
    local out = {}
    for __, k in ipairs(TODAY_KEYS) do
        if k ~= "last" then table.insert(out, { key = k, name = TODAY_NAMES[k] }) end
    end
    return out
end

--- What Today's crossword would open (from `which` source, as in
-- crosswordSources; the one set by default), without the network: { name
-- ("USA Today", "Guardian Quick"), day (the newest day it has a puzzle, for
-- a source by date), have (true when that puzzle is in the book: book,
-- page, state "new", "started" or "done") }.
function Notes:todaysCrosswordInfo(which)
    local src, kind = sourceAndKind(which)
    local info = { name = src == "guardian" and T(_("Guardian %1"), NAMES[kind]) or Crossword.SOURCES[src].name }
    local nb = self:crosswordBook(src, true)
    local now = today()
    if src ~= "guardian" then info.day = (Crossword.days(src, now, 0, 1))[1] end
    for i, page in ipairs(nb and nb.pages or {}) do
        local key, part = (page.pz or ""):match("^(.-):(%w+)$")
        local mine = key and part == "1" and (src ~= "guardian" and key == src .. "/" .. Crossword.ymd(info.day)
            or (src == "guardian" and key:match("^" .. kind .. "/") and page.day == now))
        if mine then
            info.have, info.book, info.page = true, nb.id, i
            info.state = Crossword.state(nb, key)
            info.day = info.day or page.day
        end
    end
    return info
end

--- Today's crossword (the newest) from `which` source (by default the one
-- set): opened when it is in the book; else fetched (Wi-Fi asked for as
-- KOReader does) and added; when today's is not out yet, the one before.
function Notes:todaysCrossword(which)
    -- App lock (the launcher's): its passcode first, when this app is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask("crosswords", function() self:todaysCrossword(which) end) then return end
    local info = self:todaysCrosswordInfo(which)
    if info.have then return self:open(info.book, info.page) end
    local src, kind = sourceAndKind(which)
    NetworkMgr:runWhenOnline(function()
        local had = self:crosswordsHad(src)
        -- (The newest; when it isn't out yet, the one before.)
        self:download(T(_("Getting today's crossword from %1…"), info.name), function()
            for __, item in ipairs(self:newestCrosswords(src, kind, 2, true) or {}) do
                if had[item.key] then return { have = item.key } end
                local p = self:fetchItem(src, item)
                if p then return { key = p.key } end
            end
            return {}
        end, function(r)
            if r and r.have then
                local nb = self:crosswordBook(src, true)
                for i, page in ipairs(nb and nb.pages or {}) do
                    if page.pz == r.have .. ":1" then return self:open(nb.id, i) end
                end
            end
            local p = r and r.key and self:loadCrossword(r.key)
            if p then return self:addCrossword(p, src) end
            message(T(_("Could not get today's crossword from %1."), info.name))
        end, 120)
    end)
end

-- ------------------------------------------------------------------ the Crosswords app

--- The Crosswords app: Notes' notebook list showing only the puzzle books
-- (crosswordsItems), wherever they are kept; ‹ goes back to the launcher.
function Notes:showCrosswords()
    -- App lock (the launcher's): its passcode first, when this app is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask("crosswords", function() self:showCrosswords() end) then return end
    local PS = require("pluginshare")
    if PS.noteRecent then pcall(PS.noteRecent, "crosswords") end
    self:closeEditor()
    self.crosswordsApp = true
    self.inTrash, self.inRecent, self.selection = false, false, nil
    self:show()
    -- (Kept on the Crosswords plugin for the launcher's switcher to bring back.)
    local plugin = self.ui and self.ui.crosswords
    if plugin then plugin.screen = self.menu end
end

--- The Crosswords app's list: Get a crossword, Today's crossword, Import,
-- Stats and Sort along the top, then every puzzle book.
function Notes:crosswordsItems()
    local info = self:todaysCrosswordInfo()
    local states = { new = _("not started"), started = _("started"), done = _("done") }
    local SORTS = { name = _("Name"), created = _("Created"), modified = _("Modified"), custom = _("My order") }
    local items = {
        { text = _("+ Get a crossword"), bold = true, callback = function() self:getCrossword() end },
        { text = info.have and T(_("Today's: %1, %2"), info.name, states[info.state] or "") or T(_("Today's: %1"), info.name),
            callback = function() self:todaysCrossword() end },
        { text = _("Import"), callback = function() self:pickPDF(true) end },
        { text = _("Stats"), callback = function() self:showCrosswordStats() end },
        { text = T(_("Sort: %1"), SORTS[Settings.get("sort")] or SORTS.modified), icon = "arrow-up-down",
            callback = function() self:pickSort() end },
    }
    for __, nb in ipairs(self:notebooks()) do
        if nb.puzzle then
            local locked = self:isLocked(nb.id)
            table.insert(items, {
                nb = nb.id,
                modified = nb.modified,
                locked = locked or nil,
                text = nb.name,
                mandatory = (locked and (_("Locked") .. " · ") or "") .. T(_("Updated %1"), os.date("%b %d", nb.modified)),
                callback = function() self:open(nb.id) end,
                hold_callback = function() self:notebookActions(nb) end,
            })
        end
    end
    return items
end

--- The sources this Kindle gets puzzles from (its books, the automatic
-- ones, Today's crossword's), each once: { { src, kind }... } (kind for the
-- Guardian); nil when it has none yet.
function Notes:crosswordsSourcesUsed()
    local used, out = {}, {}
    local function add(key)
        local src, kind = tostring(key or ""):match("^(%a+)/?(%a*)$")
        if not src or src == "imp" or src == "last" or not Crossword.SOURCES[src] or used[src] then return end
        used[src] = true
        table.insert(out, { src = src, kind = src == "guardian" and (NAMES[kind] and kind or Settings.get("crossword_kind") or "quick") or nil })
    end
    for __, k in ipairs(Settings.get("crossword_auto") or {}) do add(k) end
    add(Settings.get("crossword_today"))
    for src in pairs(Settings.get("crossword_books") or {}) do add(src) end
    if Settings.get("crossword_book") then add("guardian") end
    return #out > 0 and out or nil
end

--- The connection test's rows (the launcher's test runs this in a child
-- process): one light request to each source used (every source before
-- any is), with plain words when it fails.
function Notes:crosswordsTestRows(Test)
    local list = self:crosswordsSourcesUsed()
    if not list then
        list = {}
        for __, src in ipairs(Crossword.SOURCE_ORDER) do table.insert(list, { src = src, kind = src == "guardian" and "quick" or nil }) end
    end
    local now = today()
    local function check(status)
        if status == 200 then return true end
        if status == 404 then return false, T(_("The site answered %1 (not found): its address may have changed."), status) end
        if status == 403 or status == 401 then return false, T(_("The site refused the request (%1)."), status) end
        return false, T(_("The site answered %1."), status)
    end
    local rows = {}
    for __, s in ipairs(list) do
        local url, method
        if s.src == "guardian" then
            url = Crossword.seriesURL(s.kind, 1)
        elseif s.src == "tny" then
            -- (Its crossword page: a day's puzzle can come out late.)
            url, method = "https://www.newyorker.com/puzzles-and-games-dept/crossword", "HEAD"
        else
            -- A day back, as its newest can come out later in the day.
            local days = Crossword.days(s.src, now, 0, 2)
            url = Crossword.dateURL(s.src, days[2] or days[1])
        end
        table.insert(rows, Test.http{ name = Crossword.SOURCES[s.src].name, url = url, method = method,
            detail = url:match("^https?://([^/:]+)"), check = check,
            headers = { ["User-Agent"] = "Mozilla/5.0 (KOReader; Notes)" } })
    end
    return rows
end

--- The launcher's search: puzzles whose name, day or book has `q` (lower
-- case) in it, and puzzle books by name; at most 20, without the network.
-- { { title, sub, open }... }. Answered from what's kept: a book is read
-- again only when it changed since (the first search reads each once).
function Notes:crosswordsSearch(q)
    self.crosswordsFound = self.crosswordsFound or {}
    local kept = self.crosswordsFound
    local out = {}
    local now = today()
    for __, s in ipairs(self:notebooks()) do
        if #out >= 20 then break end
        if s.puzzle and not self:isLocked(s.id) then
            local k = kept[s.id]
            if not (k and k.modified == s.modified) then
                -- { { text (searched), title, page }... }
                k = { modified = s.modified, rows = {} }
                local nb = self.store:read(s.id)
                if nb and nb.feed then
                    for i, page in ipairs(nb.pages) do
                        local label = (page.pz or ""):match(":1$") and not page.hide and Crossword.pageLabel(page, now)
                        if label then table.insert(k.rows, { text = (label .. " " .. nb.name):lower(), title = label, page = i }) end
                    end
                elseif nb then
                    table.insert(k.rows, { text = nb.name:lower(), title = nb.name })
                end
                k.name = nb and nb.name or s.name
                kept[s.id] = k
            end
            for __, r in ipairs(k.rows) do
                if #out < 20 and r.text:find(q, 1, true) then
                    table.insert(out, { title = r.title, sub = r.page and k.name or _("Puzzle book"),
                        open = function() self:open(s.id, r.page) end })
                end
            end
        end
    end
    return out
end

-- ------------------------------------------------------------------ the Crosswords button

--- The notebook list's Crosswords button: everything about crosswords in one place.
function Notes:crosswordMenu()
    local dialog
    local function pick(fn) return function() UIManager:close(dialog) fn() end end
    local info = self:todaysCrosswordInfo()
    local states = { new = _("not started"), started = _("started"), done = _("done") }
    local today = info.have and T(_("Today's crossword: %1, %2"), info.name, states[info.state] or "")
        or T(_("Today's crossword: %1"), info.name)
    local buttons = {
        { { text = _("Get a crossword…"), align = "left", callback = pick(function() self:getCrossword() end) } },
        { { text = today, align = "left", callback = pick(function() self:todaysCrossword() end) } },
        { { text = _("Import a puzzle book (PDF, .puz, .ipuz)…"), align = "left", callback = pick(function() self:pickPDF(true) end) } },
        { { text = _("Stats"), align = "left", callback = pick(function() self:showCrosswordStats() end) } },
        { { text = _("Crossword settings…"), align = "left", callback = pick(function() self:crosswordSettings() end) } },
    }
    if self:crosswordsOnWebReady() then
        table.insert(buttons, { { text = _("Open on the web page"), align = "left", callback = pick(function() self:crosswordsOnWeb() end) } })
    end
    table.insert(buttons, { { text = _("Close"), callback = function() UIManager:close(dialog) end } })
    dialog = require("notesko").buttonDialog{ title = _("Crosswords"), buttons = buttons }
end

--- Whether the Web page plugin can show the Crosswords section with a QR code.
function Notes:crosswordsOnWebReady()
    local web = self.ui and self.ui.webpage
    return web ~= nil and web.openOnWeb ~= nil
end

--- The web page's Crosswords section opened on a phone (a QR code of it):
-- at the book and puzzle of editor `ed` when it shows a crossword fetched.
function Notes:crosswordsOnWeb(ed)
    local fragment = "crosswords"
    local nb = ed and ed.notebook
    if nb and nb.feed then
        fragment = fragment .. "?book=" .. nb.id
        local key = Crossword.keyPart(nb.pages[ed.page])
        if key then fragment = fragment .. "&puzzle=" .. key end
    end
    self.ui.webpage:openOnWeb(fragment)
end

-- ------------------------------------------------------------------ settings

--- Crossword settings > Toolbar buttons (and Settings > Toolbar > Crossword
-- book buttons): which of a crossword book's ⋯ menu go on its toolbar.
-- A tap on a crossword notification after KOReader restarted: its puzzle opened.
do
    local PS = require("pluginshare")
    PS.notifyOpeners = PS.notifyOpeners or {}
    PS.notifyOpeners.crosswords = function(route)
        local ui = require("apps/filemanager/filemanager").instance or require("apps/reader/readerui").instance
        local notes = ui and ui.notes
        if notes and route and route.book then notes:open(route.book, route.page) end
    end
end

local function pickPuzzleButtons(done)
    local E = require("noteseditor")
    local on = {}
    for __, k in ipairs(Settings.get("puzzle_buttons") or E.PUZZLE_DEFAULT) do on[k] = true end
    local items = {}
    for __, b in ipairs(E.PUZZLE_BUTTONS) do
        -- (Check my answers and Ask AI only with an AI service set up.)
        if not ((b.key == "check" or b.key == "ask") and Settings.noAI and Settings.noAI()) then
        table.insert(items, { text = b.label, checked = on[b.key], fn = function()
            on[b.key] = not on[b.key]
            local keys = {}
            for __, b2 in ipairs(E.PUZZLE_BUTTONS) do
                if on[b2.key] then table.insert(keys, b2.key) end
            end
            Settings.set("puzzle_buttons", keys)
            pickPuzzleButtons(done)
        end })
        end
    end
    require("notesko").list(_("Crossword book buttons\n\nAdd things from a crossword book's ⋯ menu to its toolbar."), items,
        function() if done then done() end end)
end
Settings.puzzleButtons = pickPuzzleButtons

local function pickOne(title, keys, names, current, set)
    local options = {}
    for __, k in ipairs(keys) do table.insert(options, { label = names[k], value = k }) end
    require("notesko").choose(title, options, current, function(k) if k ~= nil then set(k) end end)
end

--- Whether any AI service is set up in Notes (else the AI items are left out).
function Notes:crosswordsAI()
    if self.anyAI then return self:anyAI() end
    return self:claudeReady("ask") or self:claudeReady("read")
end

--- Crossword settings, full pages as the other apps' (notessettingspage):
-- Display, Solving, Getting crosswords, then the AI. `changed()` runs after
-- a change (a crossword book open lays its toolbar out again).
function Notes:crosswordSettings(changed, rowsOnly)
    local page
    -- Clue size or clue boxes changed: the books laid out again once the
    -- settings close (a book open would otherwise reopen over them).
    local relay = false
    local function done()
        if changed then changed() end
        if page then page:refresh() end
    end
    local function onOff(v) return v and _("On") or _("Off") end
    local function build()
        local rows = {}
        local function add(r) table.insert(rows, r) end
        local function heading(text) add({ heading = text }) end
        -- On or off: flipped where it is.
        local function switch(label, on, flip)
            add({ text = label .. ": " .. onOff(on), kind = "row", fn = function()
                flip()
                done()
            end })
        end
        -- A list to pick from, or another screen.
        local function pick(label, value, fn) add({ text = label .. ": " .. value, kind = "pick", fn = fn }) end
        local function open(label, value, fn) add({ text = label .. ": " .. value, kind = "open", fn = fn }) end

        local large = Settings.get("crossword_clues") == "large"
        heading(_("Display"))
        pick(_("Clue size"), large and _("Large") or _("Normal"), function()
            Settings.choose(_("Clue size"), { { "normal", _("Normal") }, { "large", _("Large") } }, large and "large" or "normal", function(v)
                if v == nil or (v == "large") == large then return end
                Settings.set("crossword_clues", v == "large" and "large" or nil)
                relay = true
                done()
            end)
        end)
        switch(_("Clue boxes"), Settings.get("crossword_boxes") ~= false, function()
            Settings.set("crossword_boxes", Settings.get("crossword_boxes") == false)
            relay = true
        end)
        local card = Settings.get("crossword_card") ~= "other"
        pick(_("Clue card"), card and _("Every clue") or _("Clues on other pages"), function()
            Settings.choose(_("Clue card\nWhat a number tapped in the grid shows in a card."),
                { { "other", _("Clues on other pages") }, { "all", _("Every clue") } }, card and "all" or "other", function(v)
                    if v == nil then return end
                    Settings.set("crossword_card", v == "other" and "other" or nil)
                    done()
                end)
        end)
        local undo = tostring(tonumber(Settings.get("crossword_undo")) or 3)
        local UNDO = { { "0", _("Off") }, { "2", _("2 seconds") }, { "3", _("3 seconds") }, { "5", _("5 seconds") }, { "8", _("8 seconds") } }
        local undoName = undo
        for __, o in ipairs(UNDO) do if o[1] == undo then undoName = o[2] end end
        pick(_("Undo after a tick"), undoName, function()
            Settings.choose(_("Undo after a tick\nHow long Undo shows after ticking a clue on its card."), UNDO, undo, function(v)
                if v == nil then return end
                Settings.set("crossword_undo", v ~= "3" and v or nil)
                done()
            end)
        end)
        -- (Notes' own switch: crosswords are Notes pages.)
        local light = Settings.get("light_swipes") == true
        pick(_("Swipes change the light"), light and _("On") or _("Off"), function()
            Settings.choose(_("Swipes change the light") .. "\n" .. _("KOReader's brighter, dimmer and warmth swipes along the screen's edge. Off, a hand brushing the edge while you write doesn't change the light. The same switch as Notes > Settings."),
                { { "off", _("Off") }, { "on", _("On") } }, light and "on" or "off", function(v)
                    if v == nil then return end
                    Settings.set("light_swipes", v == "on")
                    done()
                end)
        end)
        local right = Settings.get("side") == "right"
        pick(_("Toolbar side"), right and _("Right") or _("Left"), function()
            Settings.choose(_("Toolbar side"), { { "left", _("Left") }, { "right", _("Right") } }, right and "right" or "left", function(v)
                if v == nil then return end
                Settings.set("side", v)
                done()
            end)
        end)
        local pinned = Settings.get("puzzle_buttons") or require("noteseditor").PUZZLE_DEFAULT
        open(_("Toolbar buttons"), #pinned == 0 and _("None") or T(_("%1 added"), #pinned), function()
            Settings.puzzleButtons(done)
        end)

        heading(_("Solving"))
        switch(_("Tap a number to find it"), Settings.get("crossword_find") ~= false, function()
            Settings.set("crossword_find", Settings.get("crossword_find") == false)
        end)
        switch(_("Timer"), Settings.get("crossword_timer") ~= false, function()
            Settings.set("crossword_timer", Settings.get("crossword_timer") == false)
        end)
        local finished = Settings.get("crossword_finished") or "keep"
        pick(_("Finished puzzles"), FINISHED[finished], function()
            pickOne(_("Finished puzzles\nPuzzles marked done: kept, hidden in the puzzle list a week later, or removed a month later."),
                { "keep", "hide", "remove" }, FINISHED, finished, function(k)
                    Settings.set("crossword_finished", k ~= "keep" and k or nil)
                    done()
                end)
        end)

        heading(_("Getting crosswords"))
        local today = Settings.get("crossword_today") or "last"
        pick(_("Today's crossword"), today == "last" and _("The one last opened") or TODAY_NAMES[today] or today, function()
            pickOne(_("Today's crossword\nThe gesture and the Crosswords tile on the launcher open this one."), TODAY_KEYS, TODAY_NAMES, today, function(k)
                Settings.set("crossword_today", k ~= "last" and k or nil)
                done()
            end)
        end)
        local auto = #(Settings.get("crossword_auto") or {})
        open(_("Get new ones automatically"), auto == 0 and _("None") or (auto == 1 and _("1 source") or T(_("%1 sources"), auto)), function()
            self:crosswordAutoSettings(done)
        end)
        -- Whether the sites answer (the launcher's connection test).
        local PS = require("pluginshare")
        if PS.showConnectionTest then
            open(_("Test connection"), "", function() PS.showConnectionTest("crosswords") end)
        end

        -- The AI is Notes' (shared with its other features): its settings there.
        heading(_("AI"))
        if self:crosswordsAI() then
            open(_("Check my answers"), self:aiName("read"), function() self:handwritingSettings() end)
            open(_("Hints from the AI"), self:aiName("ask"), function() self:handwritingSettings() end)
        else
            -- (No AI service set up: one row, and no AI items anywhere.)
            open(_("AI services"), _("Not set up"), function() self:handwritingSettings() end)
        end

        -- Crosswords are Notes pages: the pen, the toolbar, gestures and the rest are Notes' settings.
        heading(_("Writing, toolbar and gestures"))
        open(_("Notes settings"), _("Shared with Notes"), function() self:showSettings(nil, true) end)
        return rows
    end
    -- (Only the rows, for the launcher's search.)
    if rowsOnly then return build() end
    local KO = require("notesko")
    page = require("notessettingspage"):new{ title = _("Crossword settings"), build = build, titleOpts = {
        home = require("pluginshare").appsHome and function() self:goHome() end or nil,
        bell = KO.bell(),
        menu = function() self:crosswordTitleMenu() end,
    } }
    local closed = page.onCloseWidget
    page.onCloseWidget = function(pg)
        closed(pg)
        if relay then UIManager:nextTick(function() self:relayCrosswordBooks() end) end
    end
    self.settingsPage = page
    UIManager:show(page)
    return page
end

-- ⋮ on a Crosswords screen's title bar: Open on the web page, the light,
-- night mode, a screen refresh, and (`withSettings`, on the list) Settings last.
function Notes:crosswordTitleMenu(withSettings)
    local KO = require("notesko")
    local dialog
    local rows = {}
    local function add(text, fn)
        table.insert(rows, { { text = text, align = "left", callback = function()
            UIManager:close(dialog)
            fn()
        end } })
    end
    add(_("Random puzzle"), function() self:randomPuzzle() end)
    if self:crosswordsOnWebReady() then add(_("Open on the web page"), function() self:crosswordsOnWeb() end) end
    if KO.hasLight() then add(_("Light"), function() KO.light() end) end
    add(KO.nightMode() and _("Night mode: On") or _("Night mode: Off"), function() KO.toggleNightMode(self.ui) end)
    add(_("Refresh screen"), function() KO.refresh() end)
    if withSettings then add(_("Settings"), function() self:crosswordSettings() end) end
    dialog = require("notesko").buttonDialog{ buttons = rows }
end

--- Every book of crosswords laid out again (the clue size changed); one open
-- is closed first and opened again after.
function Notes:relayCrosswordBooks()
    local ed = self.editor
    local open = ed and UIManager:isWidgetShown(ed) and ed.notebook.feed and { ed.notebook.id, ed.page }
    if open then self:closeEditor() end
    local msg = busy(_("Laying out the crosswords…"))
    for __, id in pairs(Settings.get("crossword_books") or {}) do
        local nb = self.store:read(id)
        if nb and nb.feed then
            Crossword.syncBook(nb, function(key) return self:loadCrossword(key) end, Store.newPageId, layoutOpts())
            self:saveCrosswordBook(nb)
        end
    end
    UIManager:close(msg)
    if open then self:open(open[1], open[2]) end
end

-- ------------------------------------------------------------------ stats, finished puzzles

-- The books of crosswords, read: { nb... }.
function Notes:crosswordBooks()
    local out = {}
    for __, src in ipairs({ "guardian", "usa", "universal", "wapo", "tny", "imp" }) do
        local nb = self:crosswordBook(src, true)
        if nb then table.insert(out, nb) end
    end
    return out
end

--- The stats of the crosswords done, shown.
function Notes:showCrosswordStats()
    local s = Crossword.stats(self:crosswordBooks(), os.time())
    local lines = {
        (s.streak == 1 and _("1 day in a row") or T(_("%1 days in a row"), s.streak)) .. " · "
            .. T(_("%1 done this week · %2 done in %3"), s.week, s.month, os.date("%B")),
        "",
    }
    for __, r in ipairs(s.rows) do
        local times = r.avg and T(_(" · average %1 · best %2"), Crossword.duration(r.avg), Crossword.duration(r.best)) or ""
        table.insert(lines, T(_("%1: %2 done"), r.name, r.done) .. times)
    end
    if #s.rows == 0 then table.insert(lines, _("No crosswords marked done yet.")) end
    table.insert(lines, "")
    table.insert(lines, _("Times count only while a puzzle is open and being written on."))
    -- (A reading page, the launcher's; a message without it.)
    local read = popup("read")
    if read then return read{ title = _("Crossword stats"), text = table.concat(lines, "\n") } end
    message(table.concat(lines, "\n"), _("Crossword stats"))
end

--- Finished puzzles hidden or removed as Crossword settings say (books open
-- in Notes left alone).
function Notes:tidyCrosswords()
    local mode = Settings.get("crossword_finished")
    if mode ~= "hide" and mode ~= "remove" then return end
    local ed = self.editor
    local openId = ed and UIManager:isWidgetShown(ed) and ed.notebook.id
    for __, nb in ipairs(self:crosswordBooks()) do
        if nb.id ~= openId then
            local remove, changed = Crossword.tidy(nb, mode, os.time())
            for __, key in ipairs(remove) do
                Crossword.removeFromBook(nb, key)
                os.remove(fileOf(self:crosswordDir(), key))
            end
            if #remove > 0 then
                self:saveCrosswordBook(nb)
            elseif changed then
                self.store:save(nb)
                if self.kept then self.kept[nb.id] = nil end
            end
        end
    end
end

-- ------------------------------------------------------------------ crossword files

local importCount = 0

--- A crossword file's bytes (.puz or .ipuz) into the "Imported crosswords"
-- book. Returns the puzzle's first page and book, or nil and why.
function Notes:importCrosswordData(bytes, open)
    importCount = (importCount + 1) % 100
    local key = string.format("imp/%s%02d", os.date("%Y%m%d%H%M%S"), importCount)
    local p, why = require("crosswordspuz").parse(bytes, require("json"), { key = key, day = dayOfKey(key) })
    if not p then return nil, why end
    self:keepCrossword(key, bytes)
    local first = self:addCrosswords("imp", { p }, open)
    return first, p
end

--- A .puz or .ipuz file picked on the Kindle, imported and opened.
function Notes:importCrosswordFile(path)
    local f = io.open(path, "rb")
    local bytes = f and f:read("*a")
    if f then f:close() end
    local first, why = self:importCrosswordData(bytes, true)
    if not first then
        message(T(_("Could not import the crossword:\n%1"), tostring(why)))
    end
end

-- ------------------------------------------------------------------ for the web page

--- The books of crosswords and their puzzles (newest first): { { src, name,
-- id, puzzles = { { key, label, day, state, secs } } } }.
function Notes:crosswordState()
    local out = {}
    local now = today()
    for __, nb in ipairs(self:crosswordBooks()) do
        local puzzles = {}
        for __, page in ipairs(nb.pages) do
            local key, part = Crossword.keyPart(page)
            if key and part == "1" then
                table.insert(puzzles, { key = key, label = Crossword.pageLabel(page, now), day = Crossword.dayOfPage(page),
                    state = Crossword.state(nb, key), secs = page.secs, hidden = page.hide or nil,
                    ticked = Crossword.ticked(page), clues = page.nclues })
            end
        end
        table.sort(puzzles, function(a, b) return (a.day or 0) > (b.day or 0) end)
        table.insert(out, { src = nb.feed, name = nb.name, id = nb.id, puzzles = puzzles })
    end
    return out
end

--- A puzzle's time set (the web page's Edit time): `secs` on its first page.
-- True, or nil and why ("open": the book is open on the Kindle).
function Notes:crosswordSetTime(id, key, secs)
    local ed = self.editor
    if ed and ed.notebook.id == id and UIManager:isWidgetShown(ed) then return nil, "open" end
    local nb = self.store:read(id)
    if not nb then return nil, "no puzzle" end
    local __, first = Crossword.pageOf(nb, key, "1")
    if not first then return nil, "no puzzle" end
    first.secs = math.max(0, math.floor(secs + 0.5))
    local ok, why = self.store:save(nb)
    if not ok then return nil, why end
    return true
end

--- Puzzles to pick from for the web page: five from the `from`-th newest,
-- { { label, day, kind, number, key, had } }, and whether there are older.
function Notes:crosswordChoices(src, kind, from)
    if not Crossword.SOURCES[src] or src == "imp" then return nil, "unknown source" end
    local had = self:crosswordsHad(src)
    local items, more
    local now = today()
    if src == "guardian" then
        if not NAMES[kind] then kind = "quick" end
        -- Its list fetched in the background: "loading" until it's here
        -- (the page asks again), or why it failed just now.
        local fail = self.crosswordListFail
        if not self:loadCrosswordLists(kind, from or 0, nil, function() end) then
            if fail and fail.id == kind .. ":" .. (from or 0) and os.time() - fail.at < 20 then
                self.crosswordListFail = nil
                return nil, self.crosswordListWhy or "no list"
            end
            return nil, "loading"
        end
        items, more = self:crosswordItems(kind, from or 0, true)
        if not items then return nil, more end
        for __, it in ipairs(items) do it.key = kind .. "/" .. it.number end
    else
        local days
        days, more = Crossword.days(src, now, from or 0, 7)
        items = {}
        for __, day in ipairs(days) do table.insert(items, { day = day, key = src .. "/" .. Crossword.ymd(day) }) end
    end
    for __, it in ipairs(items) do
        it.label = (it.day and Crossword.dayLabel(it.day, it.day < now - 300) or "") .. (it.number and ("  No " .. withCommas(it.number)) or "")
        it.had = had[it.key] or nil
    end
    return items, more
end

--- Puzzles for the web page, fetched in the background and added (nothing
-- opened): a job id for crosswordJob.
function Notes:getCrosswordsLater(src, items)
    self.crosswordJobs = self.crosswordJobs or {}
    self.crosswordJobCount = (self.crosswordJobCount or 0) + 1
    local id = tostring(self.crosswordJobCount)
    self.crosswordJobs[self.crosswordJobCount - 10] = nil   -- (the last ten kept)
    local job = { state = "running", got = 0, missed = {} }
    self.crosswordJobs[self.crosswordJobCount] = job
    inBackground(function()
        local keys, missed = {}, {}
        for __, item in ipairs(items or {}) do
            local p = self:fetchItem(src, item)
            if p then table.insert(keys, p.key) else table.insert(missed, item.label or item.key or "?") end
        end
        return { keys = keys, missed = missed }
    end, function(r, why)
        if not r then
            job.state, job.error = "failed", tostring(why)
            return
        end
        job.missed = r.missed or {}
        local got = {}
        for __, key in ipairs(r.keys or {}) do
            local p = self:loadCrossword(key)
            if p then table.insert(got, p) end
        end
        if #got > 0 and not self:addCrosswords(src, got, false) then
            job.state = "open"
            return
        end
        job.got, job.state = #got, "done"
    end, 60 + 20 * #(items or {}))
    return id
end

--- A web page job: { state ("running", "done", "open": its book is open on
-- the Kindle, "failed"), got, missed, error }, or nil.
function Notes:crosswordJob(id)
    return self.crosswordJobs and self.crosswordJobs[tonumber(id) or 0]
end


-- ------------------------------------------------------------------ recent crosswords

local RECENT_MAX = 30

-- A puzzle in a book: its key in a book of crosswords, the page's id in a
-- puzzle book from a PDF.
local function puzzleRef(nb, page)
    if nb.feed then return (Crossword.keyPart(page)) end
    return page.id
end

-- What Recent crosswords shows of puzzle `ref` in notebook `nb`: { page (its
-- first page), name, source, state, solved, total, hidden }, or nil when it
-- is no longer there.
local function recentInfo(nb, ref)
    local land = (nb.width or 0) > (nb.height or 0)
    local at, first
    if nb.feed then
        at, first = Crossword.pageOf(nb, ref, land and "L1" or "1")
        if not at then at, first = Crossword.pageOf(nb, ref, "1") end
    else
        for i, page in ipairs(nb.pages) do
            if page.id == ref then at, first = i, page end
        end
    end
    if not first then return nil end
    -- (Hiding a crossword hides it both ways round.)
    local e = { page = at, hidden = first.hide or nil }
    if nb.feed then
        local __, top = Crossword.pageOf(nb, ref, "1")
        top = top or first
        local src = Crossword.sourceName(ref)
        local day = Crossword.dayOfPage(top)
        local when = day and Crossword.dayLabel(day)
        if sourceOf(ref) == "imp" then
            e.name = top.title or _("Crossword")
        elseif when then
            e.name = src .. " · " .. when
        else
            e.name = src .. " " .. withCommas(tonumber(ref:match("/(%d+)$")) or 0)
        end
        e.source = src:match("^Guardian") and _("Guardian") or src
        e.state = Crossword.state(nb, ref)
        local n = 0
        for __ in pairs(top.ticks or {}) do n = n + 1 end
        e.solved, e.total = n, top.nclues
    else
        e.name = T(_("%1 · page %2"), nb.name, at)
        e.source = nb.name
        e.state = first.done and "done" or (Crossword.written(first) and "started") or "new"
        e.solved = 0
    end
    return e
end

-- When a notebook's file last changed (nil: it's gone).
function Notes:bookStamp(id)
    return require("libs/libkoreader-lfs").attributes(self.store:path(id), "modification")
end

local function thumbPath(r)
    return DataStorage:getDataDir() .. "/cache/notes-recent/" .. r.book .. "-" .. tostring(r.ref):gsub("[^%w]", "_") .. ".png"
end

--- The puzzle on an editor's page noted as just opened or written in (for
-- Recent crosswords on the launcher). Closed (`closed`, the book just
-- saved): what the row shows kept from the notebook in memory, so the
-- launcher doesn't read the book again; its picture drawn a little later.
function Notes:noteCrosswordSeen(ed, closed)
    local nb = ed and ed.notebook
    if not (nb and (nb.puzzle or nb.feed)) then return end
    -- (The launcher's recent apps; the "new crosswords" notice done with.)
    local PS = require("pluginshare")
    if not closed and PS.noteRecent then pcall(PS.noteRecent, "crosswords") end
    if not closed and nb.feed and PS.unnotify then pcall(PS.unnotify, "crosswords:new") pcall(PS.unnotify, "crosswords:answers") end
    local page = nb.pages[ed.page]
    local ref = page and puzzleRef(nb, page)
    if not ref then return end
    local list = Settings.get("crossword_recent") or {}
    local old
    for i = #list, 1, -1 do
        if list[i].book == nb.id and list[i].ref == ref then old = table.remove(list, i) end
    end
    local r = { book = nb.id, ref = ref, at = os.time(), thumbAt = old and old.thumbAt, info = old and old.info, stamp = old and old.stamp }
    if closed then
        r.info, r.stamp = recentInfo(nb, ref), self:bookStamp(nb.id)
        self.recentBooks = self.recentBooks or {}
        self.recentBooks[nb.id] = { nb = nb, stamp = r.stamp }
    end
    table.insert(list, 1, r)
    while #list > RECENT_MAX do table.remove(list) end
    Settings.set("crossword_recent", list)
    if closed then self:refreshRecentLater() end
end

-- A notebook for Recent crosswords: the one open, else read again only when
-- its file changed.
function Notes:recentBook(id)
    local ed = self.editor
    if ed and ed.notebook.id == id and UIManager:isWidgetShown(ed) then return ed.notebook end
    local stamp = self:bookStamp(id)
    if not stamp then return nil end
    self.recentBooks = self.recentBooks or {}
    local kept = self.recentBooks[id]
    if kept and kept.stamp == stamp then return kept.nb end
    local nb = self.store:read(id)
    self.recentBooks[id] = nb and { nb = nb, stamp = stamp } or nil
    return nb
end

-- A small picture of a puzzle as written so far (the grid, or a PDF's
-- whole page): its path, or nil.
function Notes:crosswordThumb(nb, i, path)
    local page = nb.pages[i]
    local crop
    if nb.feed then
        local p, lp = self:crosswordPage(page)
        local w, h = nb.width or Screen:getWidth(), nb.height or Screen:getHeight()
        local g = p and Crossword.gridOnScreen(p, lp, w, h)
        if g then crop = { math.floor(g[1]), math.floor(g[2]), math.ceil(g[4] * g[3]), math.ceil(g[5] * g[3]) } end
    end
    local ok = pcall(require("noteseditor").pagePNG, nb, i, path, { crop = crop, long = 360 })
    return ok and path or nil
end

-- Whether a recent puzzle's row is out of date (its book changed since) or
-- its picture is (written in since; not tried already). Neither while its
-- book is open: the picture waits until it's closed.
local function stale(self, r, stamp)
    local ed = self.editor
    if ed and ed.notebook.id == r.book and UIManager:isWidgetShown(ed) then return false, false end
    local info = not r.info or r.stamp ~= stamp
    local thumb = r.thumbTried ~= r.at
        and not (r.thumbAt and r.thumbAt >= r.at and require("libs/libkoreader-lfs").attributes(thumbPath(r), "mode"))
    return info, thumb
end

--- Rows and pictures out of date, brought up to date one at a time a moment
-- later (reading a book and drawing a picture can take a while), so the
-- launcher never waits on them; it shows them at its next look.
function Notes:refreshRecentLater()
    if self.recentQueued then return end
    self.recentQueued = true
    local function step()
        local list = Settings.get("crossword_recent") or {}
        for i, r in ipairs(list) do
            local stamp = self:bookStamp(r.book)
            local info, thumb = stale(self, r, stamp)
            if not stamp then
                table.remove(list, i)
                Settings.set("crossword_recent", list)
                return UIManager:scheduleIn(0.2, step)
            end
            -- (The first dozen only: the launcher shows ten at most.)
            if i <= 12 and (info or thumb) then
                local nb = self:recentBook(r.book)
                if info then
                    r.info, r.stamp = nb and recentInfo(nb, r.ref) or nil, stamp
                    if not r.info then table.remove(list, i) end
                else
                    r.thumbTried = r.at
                    if nb and r.info then
                        require("util").makePath(DataStorage:getDataDir() .. "/cache/notes-recent")
                        if self:crosswordThumb(nb, r.info.page, thumbPath(r)) then r.thumbAt = os.time() end
                    end
                end
                Settings.set("crossword_recent", list)
                return UIManager:scheduleIn(0.3, step)
            end
        end
        self.recentQueued = nil
    end
    UIManager:scheduleIn(1.5, step)
end

--- Puzzles opened or written in lately, the latest first, at most `limit`
-- (10): from any crossword or puzzle book, not hidden ones, removed ones
-- or locked notebooks. { book, page (its first page), name, source,
-- state ("new", "started" or "done"), solved (clues ticked), total (clues,
-- nil when not known), thumb (a PNG of the grid as written, or nil) }.
-- Quick: what's kept is shown (the book open is looked at as it is), and
-- anything out of date is brought up to date afterwards (refreshRecentLater).
function Notes:recentCrosswords(limit)
    limit = limit or 10
    local out, later = {}, false
    local ed = self.editor
    for __, r in ipairs(Settings.get("crossword_recent") or {}) do
        if #out >= limit then break end
        local stamp = self:bookStamp(r.book)
        local info, thumb = stale(self, r, stamp)
        if not stamp or info or thumb then later = true end
        local e = r.info
        if ed and ed.notebook.id == r.book and UIManager:isWidgetShown(ed) then e = recentInfo(ed.notebook, r.ref) end
        if stamp and e and not e.hidden and not self:isLocked(r.book) then
            local path = thumbPath(r)
            table.insert(out, { book = r.book, page = e.page, name = e.name, source = e.source, state = e.state,
                solved = e.solved, total = e.total,
                thumb = require("libs/libkoreader-lfs").attributes(path, "mode") and path or nil })
        end
    end
    if later then self:refreshRecentLater() end
    return out
end

end
