--[[--
Crosswords from the Guardian, USA Today, Universal, the Washington Post
(Sundays) and the New Yorker for Notes' puzzle books, in plain Lua (JSON is
passed in) so the tests run it.

The others are by date: USA Today and Universal as one string of the grid's
letters ("-" a black square) with the clues by number, the Washington Post
as its squares and words, the New Yorker as text (found from its day's
page). Each becomes the same puzzle as the Guardian's (fromGrid numbers the
grid the usual way), in its own book.

The Guardian gives each crossword as JSON at /crosswords/<kind>/<number>.json
("crossword": the grid's size, and each entry's number, clue, place, length,
word breaks and answer), and a series' latest puzzles at
/crosswords/series/<kind>.json (a page of HTML in "html": each puzzle's
number and when it was published).

A puzzle is laid out as PDF pages the shape of the Kindle Scribe's screen:
the grid as large as fits, the clues in two columns clear of the toolbar
(carried on to another page when they do not fit), and the answers on a
page of their own; and again on its side (landscape: the grid at the left,
the clues beside it). A source's puzzles go into one puzzle book (feed =
"guardian"); each of its pages says which puzzle page it shows (pz =
"quick/17616:1", ":2", ":a" for the answers, ":L1"… ":La" on its side), and
its PDF is made again from the puzzles whenever one is added. Also here: a
puzzle's state and time, the stats, tidying finished puzzles, and checking
the letters the AI read in a grid.
]]

local MdPdf = require("notesmdpdf")

local Crossword = {}

Crossword.BASE = "https://www.theguardian.com"
Crossword.KINDS = { "quick", "cryptic", "quiptic", "prize" }
Crossword.W, Crossword.H = 620, 827   -- a page in points: the Scribe's 1860 x 2480 screen at a third

local W, H = Crossword.W, Crossword.H
local LEFT, RIGHT = 48, 14            -- clear of the toolbar on the left
local CLUE, LINE = 10.5, 13.2         -- clue text size and line height

--- A series' list of puzzles: page 1 the newest 20, page 2 the 20 before…
function Crossword.seriesURL(kind, page)
    return Crossword.BASE .. "/crosswords/series/" .. kind .. ".json" .. ((page or 1) > 1 and ("?page=" .. page) or "")
end

Crossword.PER_PAGE = 20
-- How many list pages back a random puzzle is picked from (the lists go
-- back further: Quick to 2001, Cryptic to about 2015, Quiptic and Prize to 2007).
Crossword.RANDOM_PAGES = { quick = 380, cryptic = 140, quiptic = 45, prize = 45 }

-- ------------------------------------------------------------------ sources by date

local UNIVERSAL = "https://gamedata.services.amuniversal.com/c/uucom/l/U2FsdGVkX18YuMv20%2B8cekf85%2Friz1H%2FzlWW4bn0cizt8yclLsp7UYv34S77X0aX%0Axa513fPTc5RoN2wa0h4ED9QWuBURjkqWgHEZey0WFL8%3D/g/fcx/d/"

--- The sources: their names, their books, and for those by date the first
-- day kept and which days have a puzzle ("day", "sunday", "weekday").
Crossword.SOURCES = {
    guardian = { name = "The Guardian", short = "Guardian", book = "Guardian crosswords" },
    usa = { name = "USA Today", short = "USA Today", book = "USA Today crosswords", every = "day", from = { 2010, 1, 1 } },
    universal = { name = "Universal", short = "Universal", book = "Universal crosswords", every = "day", from = { 2019, 1, 1 } },
    wapo = { name = "The Washington Post", short = "Wash. Post", book = "Washington Post crosswords", every = "sunday", from = { 2025, 5, 4 } },
    tny = { name = "The New Yorker", short = "New Yorker", book = "New Yorker crosswords", every = "weekday", from = { 2018, 1, 1 } },
    -- .puz and .ipuz files imported (crosswordspuz, in the Crosswords plugin), not in the picker.
    imp = { name = "Imported", short = "Imported", book = "Imported crosswords" },
}
Crossword.SOURCE_ORDER = { "guardian", "usa", "universal", "wapo", "tny" }


function Crossword.puzzleURL(kind, number)
    return string.format("%s/crosswords/%s/%d.json", Crossword.BASE, kind, number)
end

-- ------------------------------------------------------------------ days

--- Days since 1970-01-01 of a date (any year).
function Crossword.daysFrom(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
    return era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
end

--- The date of a day since 1970-01-01: year, month, day.
function Crossword.dateOf(days)
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
end

local WEEKDAYS = { "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" }   -- 1970-01-01 was a Thursday
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- A day as "Wed 21 Oct" (with the year: "Wed 21 Oct 2026").
function Crossword.dayLabel(days, withYear)
    local y, m, d = Crossword.dateOf(days)
    return string.format("%s %d %s%s", WEEKDAYS[days % 7 + 1], d, MONTHS[m], withYear and (" " .. y) or "")
end

--- Whether a source by date has a puzzle on a day.
function Crossword.publishes(src, day)
    local every = Crossword.SOURCES[src].every
    local wd = day % 7   -- 0 Thursday ... 3 Sunday ... 6 Wednesday
    if every == "sunday" then return wd == 3 end
    if every == "weekday" then return wd ~= 2 and wd ~= 3 end
    return true
end

function Crossword.firstDay(src)
    local f = Crossword.SOURCES[src].from
    return Crossword.daysFrom(f[1], f[2], f[3])
end

--- Days with a puzzle, newest first: `count` of them after skipping the
-- `from` newest, up to `today`; and whether there are older ones.
function Crossword.days(src, today, from, count)
    local first = Crossword.firstDay(src)
    local out, skipped, day = {}, 0, today
    while day >= first and #out < count do
        if Crossword.publishes(src, day) then
            if skipped < from then skipped = skipped + 1 else table.insert(out, day) end
        end
        day = day - 1
    end
    while day >= first and not Crossword.publishes(src, day) do day = day - 1 end
    return out, day >= first
end

--- A random day with a puzzle, from the first kept to `today`
-- (`random(a, b)` as math.random).
function Crossword.randomDay(src, today, random)
    local first = Crossword.firstDay(src)
    for __ = 1, 50 do
        local day = random(first, today)
        if Crossword.publishes(src, day) then return day end
    end
    return today
end

--- A day as a number, 20261021 (in a puzzle's key: "usa/20261021").
function Crossword.ymd(day)
    local y, m, d = Crossword.dateOf(day)
    return y * 10000 + m * 100 + d
end

--- Where a source by date has its puzzle for a day (the New Yorker: the
-- day's page, which names the puzzle; then tnyURL).
function Crossword.dateURL(src, day)
    local y, m, d = Crossword.dateOf(day)
    if src == "usa" then
        return string.format("http://picayune.uclick.com/comics/usaon/data/usaon%02d%02d%02d-data.xml", y % 100, m, d)
    elseif src == "universal" then
        return string.format("%s%04d-%02d-%02d/data.json", UNIVERSAL, y, m, d)
    elseif src == "wapo" then
        return string.format("https://games-service-prod.site.aws.wapo.pub/crossword/levels/sunday/%04d/%02d/%02d", y, m, d)
    elseif src == "tny" then
        return string.format("https://www.newyorker.com/puzzles-and-games-dept/crossword/%04d/%02d/%02d", y, m, d)
    end
end

--- The New Yorker's puzzle named on its day's page, or nil.
function Crossword.tnyId(html)
    local h = "%x%x%x%x"
    return html:match('"id":"(' .. h .. h .. "%-" .. h .. "%-" .. h .. "%-" .. h .. "%-" .. h .. h .. h .. ')"')
end

function Crossword.tnyURL(id)
    return "https://puzzles-games-api.gp-prod.conde.digital/api/v1/games/" .. id
end

-- ------------------------------------------------------------------ the Guardian's JSON

--- A series' latest puzzles, newest first: { { kind, number, day }... }
-- (day: the puzzle's day, days since 1970; nil when the list does not say),
-- or nil and why.
function Crossword.recent(body, kind, json)
    local ok, data = pcall(json.decode, body or "")
    local html = ok and type(data) == "table" and data.html
    if type(html) ~= "string" or not kind:match("^%a+$") then return nil, "not a list of crosswords" end
    local out, seen = {}, {}
    for number, card in html:gmatch('data%-id="crosswords/' .. kind .. '/(%d+)"(.-)</li>') do
        number = tonumber(number)
        if not seen[number] then
            seen[number] = true
            -- Published at midnight in London the evening before (23:00 or
            -- 00:00 UTC): a few hours on is the puzzle's day.
            local y, m, d, h = card:match('datetime="(%d+)%-(%d+)%-(%d+)T(%d+):')
            local day = y and Crossword.daysFrom(tonumber(y), tonumber(m), tonumber(d)) + (tonumber(h) + 3 >= 24 and 1 or 0)
            table.insert(out, { kind = kind, number = number, day = day })
        end
    end
    table.sort(out, function(a, b) return a.number > b.number end)
    return out
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

--- A clue as plain text: HTML marks (italics) gone, entities as characters.
function Crossword.plain(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("<[^>]*>", "")
    s = s:gsub("&#[xX](%x+);", function(h) return utf8char(math.min(tonumber(h, 16), 0xFFFF)) end)
    s = s:gsub("&#(%d+);", function(n) return utf8char(math.min(tonumber(n), 0xFFFF)) end)
    s = s:gsub("&(%a+);", function(e) return ENTITIES[e] end)
    return (s:gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

--- A puzzle from the Guardian's JSON: { key = "quick/17616", kind, number,
-- name, day, cols, rows, entries = { { number, label, clue, across, x, y,
-- length, breaks = { { at, "," or "-" }... }, answer }... }, answers =
-- true when every entry has its answer } or nil and why.
function Crossword.parse(body, json)
    local ok, data = pcall(json.decode, body or "")
    local c = ok and type(data) == "table" and (type(data.crossword) == "table" and data.crossword or data)
    if type(c) ~= "table" or type(c.entries) ~= "table" or type(c.dimensions) ~= "table" then return nil, "not a crossword" end
    local cols, rows = tonumber(c.dimensions.cols), tonumber(c.dimensions.rows)
    local kind, number = c.crosswordType, tonumber(c.number)
    if not (cols and rows and cols >= 3 and rows >= 3 and cols <= 30 and rows <= 30)
            or type(kind) ~= "string" or not kind:match("^%a+$") or not number then
        return nil, "not a crossword"
    end
    local p = { kind = kind, number = math.floor(number), cols = cols, rows = rows, entries = {}, answers = true,
        source = "The Guardian" }
    p.key = kind .. "/" .. p.number
    p.name = Crossword.plain(c.name)
    if p.name == "" then p.name = kind .. " " .. p.number end
    if tonumber(c.date) then p.day = math.floor((c.date / 1000 + 3 * 3600) / 86400) end
    for _, e in ipairs(c.entries) do
        local pos = type(e) == "table" and type(e.position) == "table" and e.position
        local x, y, len = pos and tonumber(pos.x), pos and tonumber(pos.y), type(e) == "table" and tonumber(e.length)
        local across = type(e) == "table" and e.direction == "across"
        if x and y and len and len >= 1 and tonumber(e.number) and (across or e.direction == "down")
                and x >= 0 and y >= 0 and (across and x + len or x + 1) <= cols and (across and y + 1 or y + len) <= rows then
            local entry = { number = math.floor(e.number), label = type(e.humanNumber) == "string" and e.humanNumber or tostring(e.number),
                clue = Crossword.plain(e.clue), across = across, x = x, y = y, length = len, breaks = {} }
            if type(e.separatorLocations) == "table" then
                for sep, at in pairs(e.separatorLocations) do
                    if type(at) == "table" then
                        for _, k in ipairs(at) do
                            if tonumber(k) and k > 0 and k < len then table.insert(entry.breaks, { k, sep == "-" and "-" or "," }) end
                        end
                    end
                end
            end
            local answer = type(e.solution) == "string" and e.solution:upper() or nil
            if answer and #answer == len and answer:match("^[%u%d]+$") then entry.answer = answer else p.answers = false end
            table.insert(p.entries, entry)
        end
    end
    if #p.entries == 0 then return nil, "not a crossword" end
    if c.solutionAvailable == false then p.answers = false end
    return p
end

-- ------------------------------------------------------------------ the other sources

--- A puzzle from its grid: `grid` rows of letters (false a black square),
-- clues by number or by first square ("x,y") in `across` and `down`,
-- numbered the usual way. `meta`: key, name, source, day; `circles`:
-- { ["x,y"] = true }. Nil when the grid is not one.
function Crossword.fromGrid(meta, grid, across, down, circles)
    local rows, cols = #grid, grid[1] and #grid[1] or 0
    if rows < 3 or cols < 3 or rows > 30 or cols > 30 then return nil, "not a crossword" end
    local function at(x, y) return x >= 0 and y >= 0 and x < cols and y < rows and grid[y + 1][x + 1] or false end
    local p = { key = meta.key, name = meta.name, source = meta.source, day = meta.day, cols = cols, rows = rows,
        entries = {}, answers = true, circles = circles }
    local downs, n = {}, 0
    for y = 0, rows - 1 do
        for x = 0, cols - 1 do
            if at(x, y) then
                local a = not at(x - 1, y) and at(x + 1, y)
                local d = not at(x, y - 1) and at(x, y + 1)
                if a or d then
                    n = n + 1
                    local dirs = {}
                    if a then table.insert(dirs, true) end
                    if d then table.insert(dirs, false) end
                    for _, isA in ipairs(dirs) do
                        local len, letters = 0, {}
                        while at(isA and x + len or x, isA and y or y + len) do
                            local ch = at(isA and x + len or x, isA and y or y + len)
                            table.insert(letters, ch)
                            len = len + 1
                        end
                        local clues = isA and across or down
                        local entry = { number = n, label = tostring(n), across = isA, x = x, y = y, length = len, breaks = {},
                            clue = Crossword.plain(clues[n] or clues[x .. "," .. y] or "") }
                        local answer = table.concat(letters)
                        if answer:match("^[%u%d]+$") then entry.answer = answer else p.answers = false end
                        table.insert(isA and p.entries or downs, entry)
                    end
                end
            end
        end
    end
    for _, e in ipairs(downs) do table.insert(p.entries, e) end
    if #p.entries == 0 then return nil, "not a crossword" end
    return p
end

local function unescape(s)
    return (s or ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
end

-- Rows of letters from one string of them ("-" or "." a black square).
local function gridOf(all, cols, rows)
    if type(all) ~= "string" or not cols or not rows or #all ~= cols * rows then return nil end
    local grid = {}
    for y = 1, rows do
        local row = {}
        for x = 1, cols do
            local ch = all:sub((y - 1) * cols + x, (y - 1) * cols + x):upper()
            row[x] = ch:match("[%u%d]") or false
        end
        grid[y] = row
    end
    return grid
end

local function sourceName(src) return Crossword.SOURCES[src].name end

--- USA Today's XML for a day.
function Crossword.parseUSA(body, day)
    local function attr(tag) return body:match("<" .. tag .. ' v="([^"]*)"') end
    local cols, rows = tonumber(attr("Width")), tonumber(attr("Height"))
    local grid = gridOf(attr("AllAnswer"), cols, rows)
    if not grid then return nil, "not a crossword" end
    local function clues(section)
        local out = {}
        for item in (body:match("<" .. section .. ">(.-)</" .. section .. ">") or ""):gmatch("<%a%d+ (.-)/>") do
            local n, c = tonumber(item:match('cn="(%d+)"')), item:match('c="([^"]*)"')
            if n and c then out[n] = unescape(c) end
        end
        return out
    end
    local title = Crossword.plain(unescape(attr("Title")))
    return Crossword.fromGrid({ key = "usa/" .. Crossword.ymd(day), day = day, source = sourceName("usa"),
        name = title ~= "" and title or "USA Today crossword" }, grid, clues("across"), clues("down"))
end

--- Universal's JSON for a day.
function Crossword.parseUniversal(body, json, day)
    local ok, d = pcall(json.decode, body or "")
    if not ok or type(d) ~= "table" then return nil, "not a crossword" end
    local grid = gridOf(d.AllAnswer, tonumber(d.Width), tonumber(d.Height))
    if not grid then return nil, "not a crossword" end
    local function clues(text)
        local out = {}
        for line in (type(text) == "string" and text or ""):gmatch("[^\n]+") do
            local n, c = line:match("^(%d+)|(.*)$")
            if n then out[tonumber(n)] = c end
        end
        return out
    end
    local title = Crossword.plain(d.Title)
    return Crossword.fromGrid({ key = "universal/" .. Crossword.ymd(day), day = day, source = sourceName("universal"),
        name = title ~= "" and title or "Universal crossword" }, grid, clues(d.AcrossClue), clues(d.DownClue))
end

--- The Washington Post's JSON for a Sunday: its squares (an answer, or
-- "locked" for black), circled squares, and words (a clue and squares).
function Crossword.parseWapo(body, json, day)
    local ok, d = pcall(json.decode, body or "")
    local cols = ok and type(d) == "table" and tonumber(d.width)
    if not cols or type(d.cells) ~= "table" or #d.cells % cols ~= 0 then return nil, "not a crossword" end
    local rows = #d.cells / cols
    local grid, circles = {}, {}
    for i, c in ipairs(d.cells) do
        local x, y = (i - 1) % cols, math.floor((i - 1) / cols)
        grid[y + 1] = grid[y + 1] or {}
        local answer = type(c) == "table" and c.type ~= "locked" and type(c.answer) == "string" and c.answer:upper():sub(1, 1)
        grid[y + 1][x + 1] = answer and answer:match("[%u%d]") or false
        if type(c) == "table" and c.circle then circles[x .. "," .. y] = true end
    end
    local across, down = {}, {}
    for _, w in ipairs(type(d.words) == "table" and d.words or {}) do
        local first = type(w) == "table" and type(w.indexes) == "table" and tonumber(w.indexes[1])
        if first then
            local key = (first % cols) .. "," .. math.floor(first / cols)
            if w.direction == "across" then across[key] = w.clue else down[key] = w.clue end
        end
    end
    local title = Crossword.plain(d.title)
    return Crossword.fromGrid({ key = "wapo/" .. Crossword.ymd(day), day = day, source = sourceName("wapo"),
        name = title ~= "" and title or "Washington Post crossword" }, grid, across, down, next(circles) and circles or nil)
end

--- The New Yorker's puzzle (its API's JSON: the puzzle as text, a
-- "## Grid" of rows and "## Clues" as "A1. clue ~ ANSWER").
function Crossword.parseTNY(body, json, day)
    local ok, d = pcall(json.decode, body or "")
    local text = ok and type(d) == "table" and d.data
    if type(text) ~= "string" then return nil, "not a crossword" end
    local gridText = text:match("## Grid%s*\n(.-)\n%s*\n") or ""
    local lines = {}
    for line in gridText:gmatch("[^\n]+") do table.insert(lines, line) end
    local cols = lines[1] and #lines[1]
    local grid = gridOf(table.concat(lines), cols, #lines)
    if not grid then return nil, "not a crossword" end
    local across, down = {}, {}
    for dir, n, clue in text:gmatch("\n([AD])(%d+)%. ([^\n]-) ~ [^\n]*") do
        -- Marks of italics and the like: {/word/}.
        clue = clue:gsub("{[/*_-](.-)[/*_-]}", "%1")
        if dir == "A" then across[tonumber(n)] = clue else down[tonumber(n)] = clue end
    end
    -- Its title is mostly the day ("The Crossword: Wednesday, October 21, 2026"), shown already.
    local title = Crossword.plain(text:match("title: ([^\n]+)") or "")
    if title == "" or title:match("^The [%a ]*Crossword:") then title = "New Yorker crossword" end
    return Crossword.fromGrid({ key = "tny/" .. Crossword.ymd(day), day = day, source = sourceName("tny"),
        name = title }, grid, across, down)
end

--- A puzzle of a source by date from what was fetched for it.
function Crossword.parseFor(src, body, json, day)
    if src == "usa" then return Crossword.parseUSA(body or "", day) end
    if src == "universal" then return Crossword.parseUniversal(body, json, day) end
    if src == "wapo" then return Crossword.parseWapo(body, json, day) end
    if src == "tny" then return Crossword.parseTNY(body, json, day) end
    return nil, "unknown source"
end

-- ------------------------------------------------------------------ pages

-- A page being drawn (`pw` x `ph` points; W x H unless said): PDF content,
-- with y measured down from the top.
local function newPage(pw, ph)
    pw, ph = pw or W, ph or H
    local ops = {}
    local page = { ops = ops, w = pw, h = ph }
    function page.rect(x, y, w, h, grey)
        table.insert(ops, string.format("%.3f g %.2f %.2f %.2f %.2f re f", grey or 0, x, ph - y - h, w, h))
    end
    --- A ring around (cx, cy), `r` across, of a line `w` wide.
    function page.circle(cx, cy, r, w, grey)
        local k = r * 0.5523
        local x, y = cx, ph - cy
        table.insert(ops, string.format("%.3f G %.2f w %.2f %.2f m %.2f %.2f %.2f %.2f %.2f %.2f c %.2f %.2f %.2f %.2f %.2f %.2f c "
            .. "%.2f %.2f %.2f %.2f %.2f %.2f c %.2f %.2f %.2f %.2f %.2f %.2f c S", grey or 0, w, x + r, y,
            x + r, y + k, x + k, y + r, x, y + r, x - k, y + r, x - r, y + k, x - r, y,
            x - r, y - k, x - k, y - r, x, y - r, x + k, y - r, x + r, y - k, x + r, y))
    end
    --- Text at baseline y; align "center" or "right" from x.
    function page.text(x, y, s, size, bold, grey, align)
        s = MdPdf.winAnsi(s)
        local w = MdPdf.textWidth(s, size, bold)
        if align == "center" then x = x - w / 2 elseif align == "right" then x = x - w end
        table.insert(ops, string.format("BT /%s %.2f Tf %.3f g %.2f %.2f Td (%s) Tj ET", bold and "F2" or "F1", size,
            grey or 0, x, ph - y, MdPdf.escape(s)))
    end
    --- A filled shape through points { x1, y1, x2, y2, ... }.
    function page.shape(pts, grey)
        local o = { string.format("%.3f g", grey or 0) }
        for i = 1, #pts - 1, 2 do
            table.insert(o, string.format("%.2f %.2f %s", pts[i], ph - pts[i + 1], i == 1 and "m" or "l"))
        end
        table.insert(o, "h f")
        table.insert(ops, table.concat(o, " "))
    end
    --- An empty square's outline, a line `lw` wide.
    function page.box(x, y, w, h, lw, grey)
        table.insert(ops, string.format("%.3f G %.2f w %.2f %.2f %.2f %.2f re S", grey or 0, lw, x, ph - y - h, w, h))
    end
    return page
end

local function textWidth(s, size, bold)
    return MdPdf.textWidth(MdPdf.winAnsi(s), size, bold)
end

--- Text broken into lines no wider than `max`.
function Crossword.wrap(s, size, max)
    local lines, cur = {}, ""
    for word in s:gmatch("%S+") do
        local next = cur == "" and word or (cur .. " " .. word)
        if cur == "" or textWidth(next, size) <= max then
            cur = next
        else
            table.insert(lines, cur)
            cur = word
        end
    end
    if cur ~= "" or #lines == 0 then table.insert(lines, cur) end
    return lines
end

--- Where the grid's squares are: white = { ["x,y"] = true }, numbers and
-- answer letters by square.
function Crossword.squares(p)
    local white, numbers, letters = {}, {}, {}
    for _, e in ipairs(p.entries) do
        numbers[e.x .. "," .. e.y] = e.number
        for i = 0, e.length - 1 do
            local key = e.across and (e.x + i) .. "," .. e.y or e.x .. "," .. (e.y + i)
            white[key] = true
            if e.answer then letters[key] = e.answer:sub(i + 1, i + 1) end
        end
    end
    return white, numbers, letters
end

-- The grid at (x0, y0), `cell` points a square; with the answers in it.
local function drawGrid(page, p, x0, y0, cell, answers)
    local white, numbers, letters = Crossword.squares(p)
    page.rect(x0, y0, p.cols * cell, p.rows * cell, 0)
    local inset = 0.6
    for key in pairs(white) do
        local x, y = key:match("(%d+),(%d+)")
        page.rect(x0 + x * cell + inset, y0 + y * cell + inset, cell - 2 * inset, cell - 2 * inset, 1)
    end
    for key in pairs(p.circles or {}) do
        local x, y = key:match("(%d+),(%d+)")
        page.circle(x0 + (x + 0.5) * cell, y0 + (y + 0.5) * cell, cell * 0.45, 0.7, 0.35)
    end
    for key, n in pairs(numbers) do
        local x, y = key:match("(%d+),(%d+)")
        page.text(x0 + x * cell + 1.8, y0 + y * cell + cell * 0.3, tostring(n), cell * 0.27, true)
    end
    if answers then
        for key, ch in pairs(letters) do
            local x, y = key:match("(%d+),(%d+)")
            page.text(x0 + (x + 0.5) * cell, y0 + y * cell + cell * 0.8, ch, cell * 0.55, false, 0.15, "center")
        end
    end
    -- Word breaks: a thick line between two squares (a short one for a hyphen).
    for _, e in ipairs(p.entries) do
        for _, b in ipairs(e.breaks) do
            local k, short = b[1], b[2] == "-"
            if e.across then
                local bx, by = x0 + (e.x + k) * cell, y0 + e.y * cell
                page.rect(bx - 1.6, by + (short and cell * 0.35 or 0), 3.2, short and cell * 0.3 or cell, 0)
            else
                local bx, by = x0 + e.x * cell, y0 + (e.y + k) * cell
                page.rect(bx + (short and cell * 0.35 or 0), by - 1.6, short and cell * 0.3 or cell, 3.2, 0)
            end
        end
    end
end

local function header(page, p, title)
    page.text(LEFT, 30, title, 15, true)
    if p.day then
        page.text(page.w - RIGHT, 30, Crossword.dayLabel(p.day, true) .. " · " .. (p.source or "The Guardian"), 10, false, 0.33, "right")
    end
end

-- Clue text size and line height: normal, and large (Crossword settings > Clue size).
local SIZES = { normal = { 10.5, 13.2 }, large = { 13.5, 17 } }

-- The clues, across then down, flowed down columns: `first` those of the
-- first page, `more` those of each page after ({ x, top, w, bottom }...),
-- each clue `indent` points in (for its tick box). put(pageNo, x, y, w,
-- lines, entry) for each clue, put(pageNo, x, y) with the heading's text
-- for each heading. Returns how many pages it took.
local function flowClues(p, first, more, size, line, put, indent)
    indent = indent or 0
    local pageNo, cols, ci = 1, first, 1
    local y = cols[1].top
    local function nextColumn()
        if ci < #cols then ci = ci + 1 else pageNo, cols, ci = pageNo + 1, more, 1 end
        y = cols[ci].top
    end
    for _, across in ipairs({ true, false }) do
        -- Down starts the second column when Across left room in the first
        -- (on the first page; after, it carries straight on).
        if not across and pageNo == 1 and ci == 1 and y > cols[1].top then nextColumn() end
        if y + line * 3 > cols[ci].bottom + 2 then nextColumn() end
        put(pageNo, cols[ci].x, y, nil, across and "ACROSS" or "DOWN")
        y = y + line + 2
        for _, e in ipairs(p.entries) do
            if e.across == across then
                local c = cols[ci]
                local lines = Crossword.wrap(e.clue, size, c.w - size * 2.1 - indent)
                if y + line * (#lines - 1) > c.bottom then
                    nextColumn()
                    c = cols[ci]
                    lines = Crossword.wrap(e.clue, size, c.w - size * 2.1 - indent)
                end
                put(pageNo, c.x, y, c.w, lines, e)
                y = y + line * #lines + 2
            end
        end
    end
    return pageNo
end

-- Room above the clues for their bar, when they take more than one page.
local BAR = 36

-- The bar above the clues of page k of n (from x0 to x1, its line at y):
-- "Clues 1 of 2" and arrows turning to the clues before and after (their
-- places kept in page.turn, for taps).
local function clueBar(page, k, n, x0, x1, y)
    page.rect(x0, y, x1 - x0, 0.8, 0)
    page.text(x0, y + 17, string.format("Clues %d of %d", k, n), 10.5, true, 0.33)
    page.turn = { k = k, n = n }
    local function arrow(bx, dir, on)
        local grey = on and 0 or 0.7
        page.box(bx, y + 5, 28, 22, 0.9, grey)
        local cx, cy = bx + 14, y + 16
        page.shape(dir < 0 and { cx + 3.5, cy - 6, cx + 3.5, cy + 6, cx - 4.5, cy } or { cx - 3.5, cy - 6, cx - 3.5, cy + 6, cx + 4.5, cy }, grey)
        if on then page.turn[dir < 0 and "prev" or "next"] = { bx, y + 5, 28, 22 } end
    end
    arrow(x1 - 62, -1, k > 1)
    arrow(x1 - 28, 1, k < n)
end

-- Columns across a page from x0 to x1, `n` of them, from `top` down.
local function columns(x0, x1, n, top, bottom)
    local gap = 16
    local w = (x1 - x0 - gap * (n - 1)) / n
    local out = {}
    for i = 1, n do table.insert(out, { x = x0 + (i - 1) * (w + gap), top = top, w = w, bottom = bottom }) end
    return out
end

--- A puzzle as pages: { { part = "1", ops, grid, clues }, ..., { part = "a" } }
-- (the answers page only when the puzzle has its answers). `opts.large`:
-- bigger clues; `opts.landscape`: pages on their side (H x W points, parts
-- "L1"…, "La"), the grid at the left as tall as fits with the clues beside it.
-- `opts.swap`: the grid and the clues the other way round: the clues above
-- the grid at the bottom, or on its side the clues at the left of the grid.
-- `opts.boxes`: a tick box before each clue (its place kept in the page's
-- clues). The grid is where it always is for its orientation, whatever the
-- clue size or boxes. Clues that don't fit carry on to pages with the same
-- grid in the same place (so turning them looks like only the clues
-- turning), a bar with arrows above the clues on each.
function Crossword.layout(p, opts)
    opts = opts or {}
    local size, line = SIZES.normal[1], SIZES.normal[2]
    if opts.large then size, line = SIZES.large[1], SIZES.large[2] end
    local indent = opts.boxes and size * 1.25 or 0
    local land = opts.landscape
    local pw, ph = land and H or W, land and W or H
    local prefix = land and "L" or ""
    local n = math.max(p.cols, p.rows)
    local cell, gx, gy, first
    if land then
        -- As big as the page's height allows, smaller while that leaves no
        -- room for the clues beside it (down to about half the width).
        -- Swapped: the grid at the right, the clues at the left.
        gy = 44
        local big = math.floor(math.min((ph - gy - 14) / p.rows, (pw - LEFT - RIGHT) * 0.7 / p.cols) * 10) / 10
        local small = math.floor(math.min((ph - gy - 14) / p.rows, (pw - LEFT - RIGHT) * 0.52 / p.cols) * 10) / 10
        -- The clue columns beside a grid of cells `c` wide.
        local function beside(c)
            if opts.swap then return columns(LEFT, pw - RIGHT - p.cols * c - 18, 2, gy + 8, ph - 10) end
            return columns(LEFT + p.cols * c + 18, pw - RIGHT, 2, gy + 8, ph - 10)
        end
        cell = small
        for c = big, small, -1 do
            local cols = beside(c)
            if flowClues(p, cols, cols, size, line, function() end, indent) == 1 then
                cell = c
                break
            end
        end
        gx = opts.swap and pw - RIGHT - p.cols * cell or LEFT
        first = beside(cell)
    else
        -- The full width for big grids (21 x 21 Sundays); room for clues below the others.
        -- Swapped: the clues above, the grid at the bottom.
        cell = math.floor((n > 15 and W - LEFT - RIGHT or math.min(450, W - LEFT - RIGHT)) / n * 10) / 10
        gx, gy = LEFT + (W - LEFT - RIGHT - p.cols * cell) / 2, 44
        if opts.swap then
            gy = ph - 14 - p.rows * cell
            first = columns(LEFT, W - RIGHT, 2, 58, gy - 14)
        else
            first = columns(LEFT, W - RIGHT, 2, gy + p.rows * cell + 20, ph - 10)
        end
    end
    -- More than a page of clues: room above them for the bar.
    local barY
    if flowClues(p, first, first, size, line, function() end, indent) > 1 then
        -- (On its side, below the clue count at the top right.)
        barY = first[1].top - 4
        for __, c in ipairs(first) do c.top = c.top + BAR end
    end
    local pages = {}
    local function newClues()
        local pg = newPage(pw, ph)
        header(pg, p, p.name)
        drawGrid(pg, p, gx, gy, cell, false)
        pg.grid = { x = gx, y = gy, cell = cell }
        pg.clues = {}
        return pg
    end
    pages[1] = newClues()
    local npages = flowClues(p, first, first, size, line, function(no, x, y, w, lines, e)
        local pg = pages[no]
        if not pg then
            pg = newClues()
            pages[no] = pg
        end
        if not w then
            pg.text(x, y, lines, size + 0.5, true)
            return
        end
        -- Its place, and its number's (tapped to show the clue's squares).
        local clue = { x, y - size, w, line * #lines + 2, e, num = { x + indent, y - size - 2, size * 1.8, line + 2 } }
        if opts.boxes then
            local bs = size * 0.85
            clue.box = { x, y - size * 0.78, bs }
            pg.box(x, y - size * 0.78, bs, bs, 0.6)
        end
        table.insert(pg.clues, clue)
        pg.text(x + indent + size * 1.52, y, e.label, size, true, 0, "right")
        for k, text in ipairs(lines) do pg.text(x + indent + size * 2, y + (k - 1) * line, text, size) end
    end, indent)
    for i, pg in ipairs(pages) do
        pg.part = prefix .. i
        if barY then clueBar(pg, i, npages, first[1].x, pw - RIGHT, barY) end
    end
    if p.answers then
        local a = newPage(pw, ph)
        header(a, p, p.name .. " · answers")
        drawGrid(a, p, gx, gy, cell, true)
        a.grid = { x = gx, y = gy, cell = cell }
        a.clues = {}
        a.part = prefix .. "a"
        table.insert(pages, a)
    end
    return pages
end

--- Where a page (pw x ph points; W x H unless said) lies on a `w` x `h`
-- screen, as notespdf fits it: x, y, pixels per point.
function Crossword.fit(w, h, pw, ph)
    pw, ph = pw or W, ph or H
    local zoom = math.min(w / pw, h / ph)
    return math.floor((w - pw * zoom) / 2), math.floor((h - ph * zoom) / 2), zoom
end

--- The entries a box on a laid-out page ({ x, y, w, h } in points) takes
-- in: the clues it touches, and the entries crossing the squares it
-- touches; in order, each once.
function Crossword.entriesIn(p, page, box)
    local out, seen = {}, {}
    local function add(e)
        if not seen[e] then
            seen[e] = true
            table.insert(out, e)
        end
    end
    local function overlaps(x, y, w, h)
        return x < box[1] + box[3] and x + w > box[1] and y < box[2] + box[4] and y + h > box[2]
    end
    for _, c in ipairs(page.clues or {}) do
        if overlaps(c[1], c[2], c[3], c[4]) then add(c[5]) end
    end
    local g = page.grid
    if g then
        for _, e in ipairs(p.entries) do
            for i = 0, e.length - 1 do
                local cx, cy = e.across and e.x + i or e.x, e.across and e.y or e.y + i
                if overlaps(g.x + cx * g.cell, g.y + cy * g.cell, g.cell, g.cell) then
                    add(e)
                    break
                end
            end
        end
    end
    return out
end

--- The squares of an entry on a laid-out page with a grid, in points:
-- { { x, y, size, letter }... }.
function Crossword.squaresOf(page, e)
    local g, out = page.grid, {}
    if not g then return out end
    for i = 0, e.length - 1 do
        local cx, cy = e.across and e.x + i or e.x, e.across and e.y or e.y + i
        table.insert(out, { g.x + cx * g.cell, g.y + cy * g.cell, g.cell, e.answer and e.answer:sub(i + 1, i + 1) or nil })
    end
    return out
end

--- What a tap at (x, y) (in points) on a laid-out page points at: an arrow
-- of the clue bar ("turn", -1 or 1), a clue's number ("clue", entry) or a
-- grid square's number ("square", its entries across then down), else nil.
function Crossword.tapped(p, page, x, y)
    -- The clue bar's arrows (room around them for a finger): "turn", -1 or 1.
    local t = page.turn
    if t then
        local best, bestD
        for dir, r in pairs({ [-1] = t.prev or false, [1] = t.next or false }) do
            if r and x >= r[1] - 10 and x <= r[1] + r[3] + 10 and y >= r[2] - 12 and y <= r[2] + r[4] + 12 then
                local d = math.abs(x - (r[1] + r[3] / 2))
                if not bestD or d < bestD then best, bestD = dir, d end
            end
        end
        if best then return "turn", best end
    end
    for _, c in ipairs(page.clues or {}) do
        local n = c.num
        if n and x >= n[1] and x <= n[1] + n[3] and y >= n[2] and y <= n[2] + n[4] then return "clue", { c[5] } end
    end
    local g = page.grid
    if g and x >= g.x and y >= g.y then
        local cx, cy = math.floor((x - g.x) / g.cell), math.floor((y - g.y) / g.cell)
        -- The number's corner of the square (its top left half).
        local fx, fy = (x - g.x) / g.cell - cx, (y - g.y) / g.cell - cy
        if cx < p.cols and cy < p.rows and fx < 0.55 and fy < 0.5 then
            local out = {}
            for _, across in ipairs({ true, false }) do
                for _, e in ipairs(p.entries) do
                    if e.x == cx and e.y == cy and e.across == across then table.insert(out, e) end
                end
            end
            if #out > 0 then return "square", out end
        end
    end
end

--- The white square at (x, y) (in points) on a laid-out page with a grid:
-- cx, cy (from 0), or nil.
function Crossword.squareAt(p, page, x, y)
    local g = page.grid
    if not g or x < g.x or y < g.y then return nil end
    local cx, cy = math.floor((x - g.x) / g.cell), math.floor((y - g.y) / g.cell)
    if #Crossword.entriesAt(p, cx, cy) == 0 then return nil end
    return cx, cy
end

--- The entries through square (cx, cy): across, then down.
function Crossword.entriesAt(p, cx, cy)
    local out = {}
    for _, across in ipairs({ true, false }) do
        for _, e in ipairs(p.entries) do
            if e.across == across and (across and e.y == cy and cx >= e.x and cx < e.x + e.length
                    or not across and e.x == cx and cy >= e.y and cy < e.y + e.length) then
                table.insert(out, e)
            end
        end
    end
    return out
end

--- The clue at (x, y) (in points, on its number or its words) on a laid-out page: its entry, or nil.
function Crossword.clueAt(page, x, y)
    for _, c in ipairs(page.clues or {}) do
        if x >= c[1] - 4 and x <= c[1] + c[3] and y >= c[2] - 2 and y <= c[2] + c[4] then return c[5] end
    end
end

--- What the AI is asked for a hint to entry `e` (with a picture of its
-- clue): a nudge, never the answer, saying something new each time.
-- `previous`: the hints already given for it (each one goes further);
-- `strict`: the last one gave the answer away.
--- The AI hint's and the check's instructions, as AI settings > Advanced
-- shows them: a fixed intro, the wording you may change, and a fixed format
-- (what the reply has to look like). The request comes after them.
Crossword.AI = {
    hint = {
        intro = "You're giving a crossword solver a hint for one clue. Never give the answer.\n",
        words = "Be accurate: if you aren't sure how a cryptic clue's wordplay works, don't guess at it; hint at the "
            .. "answer's meaning instead.\nOnly talk about the clue and its answer. Don't mention the picture, their "
            .. "handwriting, or which of their letters look right or wrong, and never say you can't read something.",
        format = "\nReply with the hint only, in one or two short sentences.",
    },
    check = {
        intro = "This is a photo of a crossword grid with letters written in by hand.\n",
        words = "Read the handwritten letter in each white square. The small printed numbers in the corners are not "
            .. "letters. Write what is there, even if it looks wrong.",
        format = "\nReply with one line per row of the grid, from the top, with one entry per square: the capital "
            .. "letter written in the square, - for a white square with nothing written in it, # for a black square, "
            .. "separated by single spaces (a row # C A T - # is a black square, C, A, T, an empty square and a black "
            .. "square). Nothing else.",
    },
}

local function instructionsOf(key)
    local a = Crossword.AI[key]
    return a.intro .. a.words .. a.format
end

-- How far each hint goes (1, 2, 3), for each kind of crossword ("plain":
-- straight clues; "cryptic"; "both" when it isn't known).
local HINT_LEVELS = {
    plain = {
        "Make it a gentle first nudge: the subject or category to think in, or a different way to read the clue. Say only "
            .. "that, nothing more: later hints can go further.",
        "Make it clearly stronger: a closely related fact, a well-known phrase it appears in, or what it's a kind of. You "
            .. "may give the first letter.",
        "Make it the strongest hint short of the answer: for example the first and last letters, or a fill-in-the-blank "
            .. "phrase it completes.",
    },
    cryptic = {
        "Make it a gentle first nudge: which end of the clue is the definition, and what kind of wordplay the rest is "
            .. "(anagram, hidden word, charade, homophone, container, reversal, double definition...). Say only that, nothing "
            .. "more: later hints can go further.",
        "Make it clearly stronger: explain how the wordplay works, piece by piece, without giving the result. You may give "
            .. "the first letter.",
        "Make it the strongest hint short of the answer: for example the first and last letters, or the wordplay's pieces "
            .. "with only the last step left.",
    },
    both = {
        "Make it a gentle first nudge. For a cryptic clue: which end of the clue is the definition, and what kind of wordplay the rest "
            .. "is (anagram, hidden word, charade, homophone, container, reversal, double definition...). For a straight clue: the "
            .. "subject or category to think in, or a different way to read the clue. Say only that, nothing more: later hints "
            .. "can go further.",
        "Make it clearly stronger. For a cryptic clue: explain how the wordplay works, piece by piece, without giving the result. For "
            .. "a straight clue: a closely related fact, a well-known phrase it appears in, or what it's a kind of. You may give the "
            .. "first letter.",
        "Make it the strongest hint short of the answer: for example the first and last letters, the wordplay's pieces with only the "
            .. "last step left, or a fill-in-the-blank phrase it completes.",
    },
}
local KIND_LINES = {
    plain = "This is a plain crossword, not a cryptic one: each clue is a straight definition or a general-knowledge "
        .. "question, with no wordplay to work out.",
    cryptic = "This is a cryptic crossword: each clue has a definition at one end and wordplay for the same answer.",
}

--- The kind of crossword a puzzle key is ("cryptic/29812" → "cryptic",
-- "quick/17616" or "usa/20261021" → "plain"); nil for an imported one.
function Crossword.kindOf(key)
    local kind = tostring(key or ""):match("^(%a+)/")
    if kind == "cryptic" or kind == "quiptic" or kind == "prize" then return "cryptic" end
    if kind == "imp" or not kind then return nil end
    return "plain"
end

--- An AI hint's prompt: `instructions` (as AI settings > Advanced has them;
-- the defaults when nil), what kind of crossword it is (`kind`: "plain",
-- "cryptic", or nil when not known), then the clue, its answer (never to be
-- written), the hints given before and how far this one goes.
function Crossword.hintPrompt(e, previous, strict, instructions, kind)
    previous = previous or {}
    local level = math.min(3, #previous + 1)
    local lines = {
        instructions or instructionsOf("hint"),
        "",
    }
    if KIND_LINES[kind] then table.insert(lines, KIND_LINES[kind]) end
    for __, l in ipairs({
        string.format("Clue (%s %s): %s", e.label, e.across and "Across" or "Down", e.clue),
        string.format("The answer has %d letters%s.", e.length,
            (e.enumeration and e.enumeration ~= "" and e.enumeration ~= tostring(e.length)) and (" (" .. e.enumeration .. ")") or ""),
    }) do table.insert(lines, l) end
    if e.answer then
        table.insert(lines, "The answer is " .. e.answer .. ". Use it to make the hint right, but never write it, any word of it or any "
            .. "word containing it, and never spell out its letters.")
    end
    if #previous > 0 then
        table.insert(lines, "They've already had these hints, and still need help:")
        for i, h in ipairs(previous) do table.insert(lines, string.format("%d. %s", i, h)) end
        table.insert(lines, "Give a new hint that goes further than those. Don't repeat or reword them.")
    end
    table.insert(lines, (HINT_LEVELS[kind] or HINT_LEVELS.both)[level])
    if strict then
        table.insert(lines, "Your last hint gave the answer away. This time make sure it doesn't appear in any form.")
    end
    return table.concat(lines, "\n")
end

--- Whether a hint gives the answer away: the answer (or a word of it, of 4
-- letters or more) in it as a word or the start of one, or all its letters
-- in a row.
function Crossword.spoils(text, answer)
    if type(text) ~= "string" or type(answer) ~= "string" then return false end
    local up = text:upper()
    local flat = up:gsub("[^A-Z]", "")
    local letters = answer:upper():gsub("[^A-Z]", "")
    if #letters >= 5 and flat:find(letters, 1, true) then return true end
    local words = {}
    for w in answer:upper():gmatch("[A-Z]+") do table.insert(words, w) end
    if #words > 1 then table.insert(words, letters) end
    for _, w in ipairs(words) do
        if #w >= 4 or (#words == 1 and #w >= 3) then
            for word in up:gmatch("[A-Z]+") do
                if word:sub(1, #w) == w then return true end
            end
        end
    end
    -- Spelled out: "G-A-N-D-E-R", "G A N D E R".
    local run = ""
    for tok in up:gmatch("[^%-%s]+") do
        run = tok:match("^[A-Z]$") and run .. tok or ""
        if #letters >= 3 and run:find(letters, 1, true) then return true end
    end
    return false
end

--- Where an entry's clue is on a laid-out page ({ x, y, w, h } in points), or nil.
function Crossword.clueOf(page, e)
    for _, c in ipairs(page.clues or {}) do
        if c[5] == e then return { c[1], c[2], c[3], c[4] } end
    end
end

--- An entry's squares as one box on a laid-out page with a grid ({ x, y, w, h } in points).
function Crossword.entryBox(page, e)
    local g = page.grid
    return { g.x + e.x * g.cell, g.y + e.y * g.cell, (e.across and e.length or 1) * g.cell, (e.across and 1 or e.length) * g.cell }
end

--- An entry's name for its tick box: "8A", "12D".
function Crossword.entryId(e)
    return e.label .. (e.across and "A" or "D")
end

--- An entry as "8 Across · Wrath (3)".
function Crossword.entryTitle(e)
    return string.format("%s %s · %s", e.label, e.across and "Across" or "Down", e.clue)
end

local KIND_NAMES = { quick = "Quick", cryptic = "Cryptic", quiptic = "Quiptic", prize = "Prize" }
Crossword.KIND_NAMES = KIND_NAMES

--- The day of a puzzle page (days since 1970): kept on the page, or from a
-- key by date ("usa/20261021"); nil when not known.
function Crossword.dayOfPage(page)
    if page.day then return page.day end
    local y, m, d = (page.pz or ""):match("/(%d%d%d%d)(%d%d)(%d%d):")
    return y and Crossword.daysFrom(tonumber(y), tonumber(m), tonumber(d)) or nil
end

--- A puzzle page's name in a list: "Wed 21 Oct", for the Guardian "Quick ·
-- Wed 21 Oct" ("Quick 17616" when its day is not known), an imported one
-- by its title, "… · answers" for an answers page. `today`: the year is
-- shown for older ones.
function Crossword.pageLabel(page, today)
    local key, part = (page.pz or ""):match("^(.-):(%w+)$")
    if not key then return nil end
    local kind, num = key:match("^(%a+)/(%d+)$")
    local day = Crossword.dayOfPage(page)
    local when = day and Crossword.dayLabel(day, today and day < today - 300) or nil
    local label
    if kind == "imp" then
        label = page.title or "Crossword"
    elseif KIND_NAMES[kind] then
        label = when and (KIND_NAMES[kind] .. " · " .. when) or (KIND_NAMES[kind] .. " " .. num)
    else
        label = when or key
    end
    if part == "a" or part == "La" then label = label .. " · answers" end
    return label
end

--- PDF pages ({ ops, w, h }...) as a PDF file (Helvetica and Helvetica-Bold).
function Crossword.pdf(pages, title)
    local objects = {}
    local function add(body)
        table.insert(objects, body)
        return #objects
    end
    add("<< /Type /Catalog /Pages 2 0 R >>")
    add("PAGES")
    add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
    local kids = {}
    for _, pg in ipairs(pages) do
        local stream = table.concat(pg.ops, "\n")
        local content = add(string.format("<< /Length %d >>\nstream\n%s\nendstream", #stream, stream))
        local page = add(string.format("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] "
            .. "/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents %d 0 R >>", pg.w or W, pg.h or H, content))
        table.insert(kids, page .. " 0 R")
    end
    objects[2] = string.format("<< /Type /Pages /Kids [%s] /Count %d >>", table.concat(kids, " "), #kids)
    local info = add(string.format("<< /Title (%s) /Producer (Notes for KOReader) >>", MdPdf.escape(MdPdf.winAnsi(title or "Crosswords"))))
    local out = { "%PDF-1.4\n%\226\227\207\211\n" }
    local offsets, size = {}, #out[1]
    for i, body in ipairs(objects) do
        offsets[i] = size
        local chunk = string.format("%d 0 obj\n%s\nendobj\n", i, body)
        table.insert(out, chunk)
        size = size + #chunk
    end
    local xref = { string.format("xref\n0 %d\n0000000000 65535 f \n", #objects + 1) }
    for i = 1, #objects do table.insert(xref, string.format("%010d 00000 n \n", offsets[i])) end
    table.insert(out, table.concat(xref))
    table.insert(out, string.format("trailer\n<< /Size %d /Root 1 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n", #objects + 1, info, size))
    return table.concat(out)
end

-- ------------------------------------------------------------------ a book's pages

--- A page's puzzle and part ("quick/17616", "1"); nil for a page of no puzzle.
function Crossword.keyPart(page)
    return (page and page.pz or ""):match("^(.-):(%w+)$")
end

local function isAnswers(part) return part == "a" or part == "La" end
local function written(page) return #(page.strokes or {}) > 0 or (page.items and #page.items > 0) or false end
Crossword.written = written

--- Whether a book's page is one of the pages for that orientation (a
-- crossword's pages are laid out once upright and once on its side).
function Crossword.inView(page, landscape)
    local key, part = Crossword.keyPart(page)
    if not key then return true end
    return (part:sub(1, 1) == "L") == (landscape and true or false)
end

--- A puzzle's pages in a book: { { i, page }... } in order.
function Crossword.pagesOf(nb, key)
    local out = {}
    for i, page in ipairs(nb.pages) do
        if Crossword.keyPart(page) == key then table.insert(out, { i, page }) end
    end
    return out
end

--- The index and page of a puzzle's part in a book, or nil.
function Crossword.pageOf(nb, key, part)
    for i, page in ipairs(nb.pages) do
        if page.pz == key .. ":" .. part then return i, page end
    end
end

--- A laid-out page's grid on a screen of w × h: { x, y, size (a square),
-- cols, rows }; nil when the page has no grid.
function Crossword.gridOnScreen(p, lp, w, h)
    if not lp.grid then return nil end
    local ox, oy, z = Crossword.fit(w, h, lp.w, lp.h)
    return { ox + lp.grid.x * z, oy + lp.grid.y * z, lp.grid.cell * z, p.cols, p.rows }
end

-- Whether (x, y) is in a grid on the screen.
local function inGrid(g, x, y)
    return x >= g[1] and y >= g[2] and x < g[1] + g[4] * g[3] and y < g[2] + g[5] * g[3]
end

-- A stroke's middle (of the box around it).
local function strokeMiddle(s)
    local p = s.p
    local x0, y0, x1, y1 = p[1], p[2], p[1], p[2]
    for i = 3, #p - 1, 2 do
        x0, x1 = math.min(x0, p[i]), math.max(x1, p[i])
        y0, y1 = math.min(y0, p[i + 1]), math.max(y1, p[i + 1])
    end
    return (x0 + x1) / 2, (y0 + y1) / 2
end

local function round(v) return math.floor(v + 0.5) end

--- The writing in a grid (strokes and typed text) as text, to tell whether
-- it changed.
function Crossword.gridText(page, g)
    local out = {}
    for __, s in ipairs(page.strokes or {}) do
        if #s.p >= 2 and inGrid(g, strokeMiddle(s)) then table.insert(out, table.concat(s.p, ",")) end
    end
    for __, it in ipairs(page.items or {}) do
        if it.k == "text" and inGrid(g, it.x + it.w / 2, it.y + (it.size or 20) / 2) then
            table.insert(out, it.x .. "," .. it.y .. it.text)
        end
    end
    return table.concat(out, ";")
end

--- The writing in a puzzle's grid on page `src` (the grid `from` on the
-- screen, as gridOnScreen gives) put in the same squares of the grid `to`
-- on page `dst` (the puzzle laid out for the other orientation), in place
-- of what was there; writing outside the grids stays where it is.
function Crossword.carryGrid(src, dst, from, to)
    local k = to[3] / from[3]
    local function x(v) return round(to[1] + (v - from[1]) * k) end
    local function y(v) return round(to[2] + (v - from[2]) * k) end
    local strokes = {}
    for __, s in ipairs(dst.strokes or {}) do
        if #s.p < 2 or not inGrid(to, strokeMiddle(s)) then table.insert(strokes, s) end
    end
    for __, s in ipairs(src.strokes or {}) do
        if #s.p >= 2 and inGrid(from, strokeMiddle(s)) then
            local c = {}
            for f, v in pairs(s) do c[f] = v end
            c.p, c.w = {}, math.max(1, round(s.w * k))
            for i = 1, #s.p - 1, 2 do
                c.p[i], c.p[i + 1] = x(s.p[i]), y(s.p[i + 1])
            end
            if s.q then
                c.q = {}
                for i, v in ipairs(s.q) do c.q[i] = math.max(1, round(v * k)) end
            end
            table.insert(strokes, c)
        end
    end
    dst.strokes = strokes
    local items = {}
    for __, it in ipairs(dst.items or {}) do
        if not (it.k == "text" and inGrid(to, it.x + it.w / 2, it.y + (it.size or 20) / 2)) then table.insert(items, it) end
    end
    for __, it in ipairs(src.items or {}) do
        if it.k == "text" and inGrid(from, it.x + it.w / 2, it.y + (it.size or 20) / 2) then
            local c = {}
            for f, v in pairs(it) do if f:sub(1, 1) ~= "_" then c[f] = v end end
            c.x, c.y = x(it.x), y(it.y)
            c.w, c.size = math.max(1, round(it.w * k)), math.max(6, round((it.size or 20) * k))
            table.insert(items, c)
        end
    end
    dst.items = #items > 0 and items or nil
end

--- The writing in the grid `from` of one page put in the same squares of
-- the grid `to` of the same page (the grid moved: the grid and the clues
-- swapped); writing outside the grid stays where it is. (Not carryGrid on
-- the page itself: that would clear the new grid's place of writing that
-- was outside the old grid.)
function Crossword.moveGrid(page, from, to)
    local before = { strokes = page.strokes, items = page.items }
    local strokes, items = {}, {}
    for __, s in ipairs(page.strokes or {}) do
        if #s.p < 2 or not inGrid(from, strokeMiddle(s)) then table.insert(strokes, s) end
    end
    for __, it in ipairs(page.items or {}) do
        if not (it.k == "text" and inGrid(from, it.x + it.w / 2, it.y + (it.size or 20) / 2)) then table.insert(items, it) end
    end
    local moved = {}
    Crossword.carryGrid(before, moved, from, to)
    for __, s in ipairs(moved.strokes or {}) do table.insert(strokes, s) end
    for __, it in ipairs(moved.items or {}) do table.insert(items, it) end
    page.strokes = strokes
    page.items = #items > 0 and items or nil
end

--- A book's grid writing moved with its grids when the grid and the clues
-- swap (`opts.swap` now, `was` before): on every written page of every
-- puzzle, in its orientation. `load(key)` gives a parsed puzzle or nil.
-- Returns whether anything moved.
function Crossword.moveGrids(nb, load, opts, was)
    if (was and true or false) == (opts.swap and true or false) then return false end
    local pw, ph = nb.width or 1860, nb.height or 2480
    if pw > ph then pw, ph = ph, pw end
    local puzzles, laid, moved = {}, {}, false
    local function lay(key, land, swap)
        local id = key .. (land and "|L" or "|P") .. (swap and "s" or "")
        if laid[id] == nil then
            laid[id] = puzzles[key] and Crossword.layout(puzzles[key], { large = opts.large, boxes = opts.boxes, swap = swap, landscape = land }) or false
        end
        return laid[id] or {}
    end
    for __, page in ipairs(nb.pages) do
        local key, part = Crossword.keyPart(page)
        if key and written(page) then
            if puzzles[key] == nil then puzzles[key] = load(key) or false end
            local p = puzzles[key]
            local land = part:sub(1, 1) == "L"
            local w, h = land and ph or pw, land and pw or ph
            local function gridOf(swap)
                for __, lp in ipairs(lay(key, land, swap)) do
                    if lp.part == part then return Crossword.gridOnScreen(p, lp, w, h) end
                end
            end
            local from, to = p and gridOf(was), p and gridOf(opts.swap)
            if from and to and (from[1] ~= to[1] or from[2] ~= to[2] or from[3] ~= to[3]) then
                Crossword.moveGrid(page, from, to)
                moved = true
            end
        end
    end
    return moved
end

--- The page (index) of the same puzzle laid out for the other orientation:
-- the same part ("2" and "L2", the answers), else its first page.
function Crossword.counterpart(nb, i)
    local key, part = Crossword.keyPart(nb.pages[i])
    if not key then return nil end
    local land = part:sub(1, 1) == "L"
    local base = land and part:sub(2) or part
    local other = (land and "" or "L") .. base
    return Crossword.pageOf(nb, key, other) or Crossword.pageOf(nb, key, land and "1" or "L1")
end

--- A puzzle's state over all its pages: "done", "started" or "new".
function Crossword.state(nb, key)
    local any = false
    for _, ip in ipairs(Crossword.pagesOf(nb, key)) do
        local page = ip[2]
        local __, part = Crossword.keyPart(page)
        if page.done then return "done" end
        if not isAnswers(part) and (written(page) or (page.ticks and next(page.ticks))) then any = true end
    end
    return any and "started" or "new"
end

--- A puzzle marked done or not on every page of it; its first page keeps
-- when (`now`, seconds).
function Crossword.setDone(nb, key, on, now)
    for _, ip in ipairs(Crossword.pagesOf(nb, key)) do
        local page = ip[2]
        page.done = on or nil
        page.doneat = nil
        if on and page.pz == key .. ":1" then page.doneat = now end
    end
end

--- The part names of a puzzle's pages in book order: upright ("1", "2"…,
-- "a" with answers), then on its side ("L1"…, "La").
function Crossword.partsOf(p, opts)
    local out = {}
    for _, land in ipairs({ false, true }) do
        for _, pg in ipairs(Crossword.layout(p, { large = opts and opts.large, boxes = opts and opts.boxes, swap = opts and opts.swap, landscape = land })) do
            table.insert(out, pg.part)
        end
    end
    return out
end

-- A puzzle's pages made to match its layouts: pages kept by their part
-- (with their ink), new ones made (answers pages hidden, the rest as the
-- puzzle is: hidden, done), ones no longer laid out dropped (kept, hidden,
-- when written on). Returns the pages and whether anything changed.
local function syncPuzzle(pages, p, newId, opts)
    local byPart = {}
    for _, page in ipairs(pages) do
        local __, part = Crossword.keyPart(page)
        if not byPart[part] then byPart[part] = page end
    end
    local first = byPart["1"] or pages[1]
    local out, used, changed = {}, {}, false
    for _, part in ipairs(Crossword.partsOf(p, opts)) do
        local page = byPart[part]
        if not page then
            changed = true
            page = { id = newId(), pz = p.key .. ":" .. part, day = p.day, strokes = {},
                hide = (isAnswers(part) or (first and first.hide)) or nil, done = first and first.done or nil }
        end
        if p.imported and part == "1" then page.title = p.name end
        if part == "1" then page.nclues = #p.entries end
        used[page] = true
        table.insert(out, page)
    end
    for _, page in ipairs(pages) do
        if not used[page] then
            if written(page) then
                if not page.hide then changed = true end
                page.hide = true
                table.insert(out, page)
            else
                changed = true
            end
        end
    end
    return out, changed
end

--- A book's pages made to match each puzzle's layouts with `opts` (`load(key)`
-- gives a parsed puzzle or nil; new pages get `newId()`): landscape pages
-- added to older books, pages added or dropped when the clue size changes.
-- Puzzles that cannot be read are left as they are. Returns whether
-- anything changed.
function Crossword.syncBook(nb, load, newId, opts)
    local groups, order = {}, {}
    for _, page in ipairs(nb.pages) do
        local key = Crossword.keyPart(page)
        if key then
            if not groups[key] then
                groups[key] = {}
                table.insert(order, { key = key })
            end
            table.insert(groups[key], page)
        else
            table.insert(order, { page = page })
        end
    end
    local out, changed = {}, false
    for _, o in ipairs(order) do
        if o.page then
            table.insert(out, o.page)
        else
            local pages, p = groups[o.key], load(o.key)
            local ch
            if p then pages, ch = syncPuzzle(pages, p, newId, opts) end
            if ch then changed = true end
            for _, page in ipairs(pages) do table.insert(out, page) end
        end
    end
    for i, page in ipairs(out) do
        if nb.pages[i] ~= page then changed = true end
    end
    nb.pages = out
    return changed
end

--- A puzzle put in the book `nb` (its pages: new ones get `newId()`), laid
-- out with `opts`: appended when new (the answers pages hidden); when there,
-- its pages matched to it again (its answers page added when it has answers
-- now and had none). Returns the index of the puzzle's first page and
-- whether pages were added.
function Crossword.addToBook(nb, p, newId, opts)
    local at, mine, rest = nil, {}, {}
    for i, page in ipairs(nb.pages) do
        if Crossword.keyPart(page) == p.key then
            at = at or i
            table.insert(mine, page)
        else
            table.insert(rest, page)
        end
    end
    local pages, changed = syncPuzzle(mine, p, newId, opts)
    at = at or #rest + 1
    for k, page in ipairs(pages) do table.insert(rest, at + k - 1, page) end
    nb.pages = rest
    return at, changed
end

--- A puzzle's pages taken out of the book. Returns how many.
function Crossword.removeFromBook(nb, key)
    local n = 0
    for i = #nb.pages, 1, -1 do
        if (nb.pages[i].pz or ""):match("^(.-):") == key then
            table.remove(nb.pages, i)
            n = n + 1
        end
    end
    return n
end

--- The book's PDF made again from its puzzles (`load(key)` gives a parsed
-- puzzle or nil) laid out with `opts`, each page's bg set to its PDF page.
-- Pages whose puzzle cannot be read show a page saying so. Returns the PDF.
function Crossword.bookPDF(nb, load, opts)
    local puzzles, layouts, pages = {}, {}, {}
    for _, page in ipairs(nb.pages) do
        local key, part = Crossword.keyPart(page)
        if key then
            if puzzles[key] == nil then puzzles[key] = load(key) or false end
            local land = part:sub(1, 1) == "L"
            local lk = key .. (land and ":L" or ":P")
            if layouts[lk] == nil then
                layouts[lk] = puzzles[key] and Crossword.layout(puzzles[key], { large = opts and opts.large, boxes = opts and opts.boxes, swap = opts and opts.swap, landscape = land }) or false
            end
            local shown
            for _, pg in ipairs(layouts[lk] or {}) do
                if pg.part == part then shown = pg end
            end
            if not shown then
                shown = land and newPage(H, W) or newPage()
                shown.text(LEFT, 30, "This crossword could not be read (" .. key .. ")", 13, true)
            end
            table.insert(pages, shown)
            page.bg = #pages
        else
            page.bg = nil
        end
    end
    if #pages == 0 then table.insert(pages, newPage()) end   -- a PDF needs a page
    return Crossword.pdf(pages, nb.name)
end

-- ------------------------------------------------------------------ time, stats, finished puzzles

Crossword.TIMER_GAP = 180   -- seconds: a longer gap between strokes counts as this

--- How long a time is, "14 min" ("1 h 05 min"; "under a minute").
function Crossword.duration(secs)
    if (secs or 0) < 60 then return "under a minute" end
    local m = math.floor(secs / 60 + 0.5)
    if m < 60 then return m .. " min" end
    return string.format("%d h %02d min", math.floor(m / 60), m % 60)
end

-- The day (days since 1970, local time) of a time in seconds.
local function localDay(t)
    local d = os.date("*t", t)
    return Crossword.daysFrom(d.year, d.month, d.day)
end
Crossword.localDay = localDay

--- A puzzle's name in the stats: "Guardian Quick", "USA Today", "Imported".
function Crossword.sourceName(key)
    local first = key:match("^(%a+)/")
    if KIND_NAMES[first] then return "Guardian " .. KIND_NAMES[first] end
    if first == "imp" then return "Imported" end
    local s = Crossword.SOURCES[first]
    return s and (s.name:gsub("^The ", "")) or first
end

--- Stats of the puzzles done in `books` (notebooks), at time `now`
-- (seconds): { streak (days in a row with one done, up to today or
-- yesterday), week (since Monday), month, rows = { { name, done, avg, best
-- } } (times in seconds, nil when none were timed) }.
function Crossword.stats(books, now)
    local today = localDay(now)
    local t = os.date("*t", now)
    local month = Crossword.daysFrom(t.year, t.month, 1)
    local monday = today - (today + 3) % 7   -- 1970-01-01 was a Thursday
    local days, rows, byName = {}, {}, {}
    local out = { streak = 0, week = 0, month = 0, rows = rows }
    for _, nb in ipairs(books) do
        for _, page in ipairs(nb.pages or {}) do
            local key, part = Crossword.keyPart(page)
            if key and part == "1" and page.done then
                local name = Crossword.sourceName(key)
                local row = byName[name]
                if not row then
                    row = { name = name, done = 0, timed = 0, total = 0 }
                    byName[name] = row
                    table.insert(rows, row)
                end
                row.done = row.done + 1
                if page.secs and page.secs > 0 then
                    row.timed, row.total = row.timed + 1, row.total + page.secs
                    row.best = math.min(row.best or page.secs, page.secs)
                end
                if page.doneat then
                    local d = localDay(page.doneat)
                    days[d] = true
                    if d >= monday then out.week = out.week + 1 end
                    if d >= month then out.month = out.month + 1 end
                end
            end
        end
    end
    for _, row in ipairs(rows) do
        row.avg = row.timed > 0 and math.floor(row.total / row.timed + 0.5) or nil
        row.timed, row.total = nil, nil
    end
    table.sort(rows, function(a, b) return a.done > b.done end)
    local d = days[today] and today or today - 1
    while days[d] do
        out.streak = out.streak + 1
        d = d - 1
    end
    return out
end

--- Finished puzzles tidied ("hide": hidden 7 days after done; "remove": 30
-- days after), at `now` (seconds). Puzzles done before it was known when
-- start counting now. Returns the keys of puzzles to remove (still in the
-- book) and whether the book changed.
function Crossword.tidy(nb, mode, now)
    local remove, changed = {}, false
    for _, page in ipairs(nb.pages) do
        local key, part = Crossword.keyPart(page)
        if key and part == "1" and page.done then
            if not page.doneat then
                page.doneat = now
                changed = true
            elseif mode == "hide" and now - page.doneat >= 7 * 86400 and not page.hide then
                for _, ip in ipairs(Crossword.pagesOf(nb, key)) do ip[2].hide = true end
                changed = true
            elseif mode == "remove" and now - page.doneat >= 30 * 86400 then
                table.insert(remove, key)
            end
        end
    end
    return remove, changed
end

-- ------------------------------------------------------------------ checking answers

--- What the AI is asked when it checks a grid (or `rowOnly`, one row of it:
-- 0-based): the shape ("#" a black square, "_" a white one) and how to
-- answer: each row its squares separated by spaces, "-" an empty one.
function Crossword.checkPrompt(p, rowOnly, instructions)
    local white = Crossword.squares(p)
    local rows = {}
    for y = 0, p.rows - 1 do
        local row = {}
        for x = 0, p.cols - 1 do row[x + 1] = white[x .. "," .. y] and "_" or "#" end
        rows[y + 1] = table.concat(row, " ")
    end
    local how = "the capital letter written in the square, - for a white square with nothing written in it, # for a "
        .. "black square, separated by single spaces (a row # C A T - # is a black square, C, A, T, an empty square "
        .. "and a black square). The small printed numbers in the corners are not letters. Write what is there, even "
        .. "if it looks wrong. Nothing else."
    if rowOnly then
        return string.format("This is one row of a crossword grid, %d squares from left to right, with letters written "
            .. "in by hand. Its shape, with # for a black square and _ for a white one:\n%s\n"
            .. "Reply with one line of exactly %d squares: %s", p.cols, rows[rowOnly + 1], p.cols, how)
    end
    -- The instructions (AI settings > Advanced; the defaults when nil), then this grid.
    return string.format("%s\n\nThe grid has %d rows and %d columns. Its shape, row by row, with # for a black square "
        .. "and _ for a white one:\n%s\nReply with exactly %d lines of exactly %d squares each.",
        instructions or instructionsOf("check"), p.rows, p.cols, table.concat(rows, "\n"), p.rows, p.cols)
end

-- A line of the AI's answer as its white squares' letters ("-" empty), or
-- nil when it doesn't have `n` of them. Squares are separated by spaces
-- (as asked) or written together; black squares are dropped, so a row
-- with one missing or added still fits; "C.A.T" (a separator between
-- squares) is read as C, A, T.
local function rowCells(l, n)
    l = l:gsub("[`|,]", " "):upper()
    if not l:match("^[%u%.#_%-%?%s]+$") then return nil end
    local out = {}
    if l:match("%S%s+%S") then
        for tok in l:gmatch("%S+") do
            if #tok ~= 1 then return nil end
            if tok ~= "#" then out[#out + 1] = tok end
        end
    else
        local c = l:gsub("[%s#]", "")
        if #c == 2 * n - 1 and n > 1 then
            local sep = c:sub(2, 2)
            for k = 2, #c, 2 do
                if c:sub(k, k) ~= sep or not (sep == "." or sep == "-" or sep == "_") then sep = nil break end
            end
            if sep then c = c:gsub("(.).", "%1") end
        end
        for k = 1, #c do out[k] = c:sub(k, k) end
    end
    if #out ~= n then return nil end
    return out
end

--- The AI's answer read as rows of letters: { [y] = { [x] = "A" or false } }
-- (0-based; a row that could not be read left out) and how many rows were
-- left out; nil when it is not the grid's shape (or half of it isn't).
-- `rowOnly`: the answer is that one row.
function Crossword.readGrid(text, p, rowOnly)
    local white = Crossword.squares(p)
    local whites = {}
    for y = 0, p.rows - 1 do
        whites[y] = {}
        for x = 0, p.cols - 1 do
            if white[x .. "," .. y] then table.insert(whites[y], x) end
        end
    end
    local lines = {}
    for l in (text or ""):gmatch("[^\r\n]+") do
        if l:match("%S") then table.insert(lines, l) end
    end
    local function fill(out, y, cells)
        out[y] = {}
        for k, x in ipairs(whites[y]) do
            local ch = cells[k]
            out[y][x] = ch:match("%u") and ch or false
        end
    end
    if rowOnly then
        for _, l in ipairs(lines) do
            local cells = rowCells(l, #whites[rowOnly])
            if cells then
                local out = {}
                fill(out, rowOnly, cells)
                return out, 0
            end
        end
        return nil
    end
    -- The run of lines that fits the grid best; rows that don't fit are left
    -- out (not checked), as long as most of them fit.
    local best, bestMissed
    for start = 1, #lines - p.rows + 1 do
        local out, missed = {}, 0
        for y = 0, p.rows - 1 do
            local cells = rowCells(lines[start + y], #whites[y])
            if cells then fill(out, y, cells) else missed = missed + 1 end
        end
        if not best or missed < bestMissed then best, bestMissed = out, missed end
    end
    if not best or bestMissed * 2 > p.rows then return nil end
    return best, bestMissed
end

--- How many clues a crossword's first page has ticked (nil for none).
function Crossword.ticked(page)
    local n = 0
    for __ in pairs(page.ticks or {}) do n = n + 1 end
    return n > 0 and n or nil
end

--- The entries (their ids, as entryId) whose squares were all read as
-- their answer. `only`: as for check.
function Crossword.solved(p, read, only)
    local out = {}
    for _, e in ipairs(p.entries) do
        local ok = e.answer ~= nil
        for i = 0, ok and e.length - 1 or -1 do
            local x, y = e.across and e.x + i or e.x, e.across and e.y or e.y + i
            if not (read[y] and read[y][x] == e.answer:sub(i + 1, i + 1)) or (only and not only[x .. "," .. y]) then
                ok = false
                break
            end
        end
        if ok then table.insert(out, Crossword.entryId(e)) end
    end
    return out
end

--- The squares written in that are not the answer: { { x, y }... }, and how
-- many squares were written in. `only`: { ["x,y"] = true } to check just
-- those squares.
function Crossword.check(p, read, only)
    local white, __, letters = Crossword.squares(p)
    local wrong, filled = {}, 0
    for y = 0, p.rows - 1 do
        for x = 0, p.cols - 1 do
            local key = x .. "," .. y
            local ch = read[y] and read[y][x]
            if white[key] and ch and (not only or only[key]) then
                filled = filled + 1
                if letters[key] and letters[key] ~= ch then table.insert(wrong, { x, y }) end
            end
        end
    end
    return wrong, filled
end

return Crossword
