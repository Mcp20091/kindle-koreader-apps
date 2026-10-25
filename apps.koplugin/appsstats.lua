--[[--
Reading statistics: today, the last 7 and 30 days, the days in a row (now and
the most ever) and the time in all; when you read (by hour and by weekday);
then every book read, last read first, with how far along it is and the time
left at its own pace. Tap a book for its own page; Calendar opens KOReader's
calendar of each day's reading. Read from KOReader's statistics.sqlite3; a
book's sessions are edited, deleted or reset with appssessions (as the web
page's Reading tab does), each with Undo.
]]

local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("appscanvas")
local Model = require("appsmodel")

local C = Canvas
local Stats = {}

-- Runs fn(conn) on KOReader's statistics; nil without them (or on an error, logged).
local function withDB(fn)
    local path = require("datastorage"):getSettingsDir() .. "/statistics.sqlite3"
    if not require("libs/libkoreader-lfs").attributes(path, "mode") then return nil end
    local conn = require("lua-ljsqlite3/init").open(path)
    local ok, a, b = pcall(fn, conn)
    conn:close()
    if not ok then
        require("logger").warn("Apps: reading statistics:", a)
        return nil
    end
    return a, b
end

-- The rows of a query as columns (empty when none).
local function rows(conn, sql)
    local r = conn:exec(sql)
    return r or {}, r and r[1] and #r[1] or 0
end

local function hoursOf(conn, where)
    local hours = {}
    for h = 0, 23 do hours[h] = 0 end
    local r, n = rows(conn, [[
        SELECT CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER), sum(duration)
        FROM page_stat_data ]] .. (where or "") .. " GROUP BY 1;")
    for i = 1, n do hours[tonumber(r[1][i])] = tonumber(r[2][i]) or 0 end
    return hours
end

--- Every day's reading and when: { today, week, month (the last 7 and 30
-- days, today in them), streak, longest, total, hours = [0..23], weekdays =
-- [0..6] (Sunday first), seconds each } or nil without the statistics.
function Stats.summary()
    return withDB(function(conn)
        local r, n = rows(conn, [[
            SELECT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS d, sum(duration)
            FROM page_stat_data GROUP BY d ORDER BY d DESC;]])
        local now = os.date("*t")
        local midnight = os.time({ year = now.year, month = now.month, day = now.day, hour = 0 })
        local today = os.date("%Y-%m-%d")
        local since7, since30 = os.date("%Y-%m-%d", midnight - 6 * 86400 + 3600), os.date("%Y-%m-%d", midnight - 29 * 86400 + 3600)
        local out = { today = 0, week = 0, month = 0, total = 0, weekdays = {} }
        local days = {}
        for i = 1, n do
            local d, secs = r[1][i], tonumber(r[2][i]) or 0
            days[i] = d
            out.total = out.total + secs
            if d == today then out.today = secs end
            if d >= since7 then out.week = out.week + secs end
            if d >= since30 then out.month = out.month + secs end
        end
        out.streak = Model.streak(days, today, os.date("%Y-%m-%d", midnight - 12 * 3600))
        out.longest = Model.longestStreak(days)
        out.hours = hoursOf(conn)
        for w = 0, 6 do out.weekdays[w] = 0 end
        local wr, wn = rows(conn, [[
            SELECT CAST(strftime('%w', start_time, 'unixepoch', 'localtime') AS INTEGER), sum(duration)
            FROM page_stat_data GROUP BY 1;]])
        for i = 1, wn do out.weekdays[tonumber(wr[1][i])] = tonumber(wr[2][i]) or 0 end
        return out
    end)
end

-- How far along and the time left at its own pace (the time per page read so far).
local function pace(b)
    if b.pages and b.pages > 0 and b.lastPage then
        b.percent = math.min(1, b.lastPage / b.pages)
        if b.read > 0 and b.percent < 1 then b.left = b.seconds / b.read * (b.pages - b.lastPage) end
    end
    return b
end

--- Every book in KOReader's reading statistics, last read first: { { id,
-- title, authors, pages, last, seconds, read, lastPage, percent, left } }
-- (nil without the statistics).
function Stats.books()
    return withDB(function(conn)
        local out = {}
        local r, n = rows(conn, [[
            SELECT b.id, b.title, b.authors, b.pages, b.last_open, sum(p.duration), count(DISTINCT p.page),
                   (SELECT q.page FROM page_stat AS q WHERE q.id_book = b.id ORDER BY q.start_time DESC LIMIT 1)
            FROM book AS b JOIN page_stat AS p ON p.id_book = b.id
            GROUP BY b.id ORDER BY b.last_open DESC;]])
        for i = 1, n do
            table.insert(out, pace({ id = tonumber(r[1][i]), title = r[2][i], authors = r[3][i],
                pages = tonumber(r[4][i]), last = tonumber(r[5][i]), seconds = tonumber(r[6][i]) or 0,
                read = tonumber(r[7][i]) or 0, lastPage = tonumber(r[8][i]) }))
        end
        return out
    end)
end

--- One book's: what Stats.books has, and days (how many), first (when
-- started), highlights, notes and hours = [0..23].
function Stats.book(id)
    return withDB(function(conn)
        local title, authors, pages, last, highlights, notes = conn:rowexec(string.format(
            "SELECT title, authors, pages, last_open, highlights, notes FROM book WHERE id = %d;", id))
        local secs, read, first = conn:rowexec(string.format(
            "SELECT sum(duration), count(DISTINCT page), min(start_time) FROM page_stat WHERE id_book = %d;", id))
        local lastPage = conn:rowexec(string.format(
            "SELECT page FROM page_stat WHERE id_book = %d ORDER BY start_time DESC LIMIT 1;", id))
        local days = conn:rowexec(string.format([[
            SELECT count(DISTINCT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime'))
            FROM page_stat_data WHERE id_book = %d;]], id))
        return pace({ id = id, title = title, authors = authors, pages = tonumber(pages), last = tonumber(last),
            seconds = tonumber(secs) or 0, read = tonumber(read) or 0, lastPage = tonumber(lastPage),
            first = tonumber(first), days = tonumber(days) or 0,
            highlights = tonumber(highlights), notes = tonumber(notes),
            hours = hoursOf(conn, string.format("WHERE id_book = %d", id)) })
    end)
end

--- "Today", "Yesterday", "3 days ago", or the date.
local function lastRead(t)
    if not t then return "" end
    local now = os.date("*t")
    local midnight = os.time({ year = now.year, month = now.month, day = now.day, hour = 0 })
    if t >= midnight then return _("Today") end
    local days = math.floor((midnight - t) / 86400) + 1
    if days == 1 then return _("Yesterday") end
    if days < 7 then return T(_("%1 days ago"), days) end
    return os.date("%b ", t) .. tonumber(os.date("%d", t)) .. os.date(", %Y", t)
end

local function date(t)
    return t and (os.date("%b ", t) .. tonumber(os.date("%d", t)) .. os.date(", %Y", t)) or "–"
end

-- An hour of the day as the clock shows it: "9 PM" or "21:00".
local function hourName(h)
    if require("appsko").twentyFour() then return string.format("%02d:00", h) end
    return ((h + 11) % 12 + 1) .. (h < 12 and " AM" or " PM")
end

local function days(n) return n == 1 and _("1 day") or T(_("%1 days"), n) end

-- "42% · 2 h 10 min left", "Finished" or "".
local function progress(b)
    if not b.percent then return "" end
    if b.percent >= 1 then return _("Finished") end
    local text = math.floor(b.percent * 100) .. "%"
    if b.left then text = text .. "  ·  " .. T(_("%1 left"), Model.duration(b.left)) end
    return text
end

local function bar(c, x, y, w, h, fraction)
    c:box(x, y, w, h, { r = h / 2, border = C.BLACK, bw = 1 })
    if fraction and fraction > 0 then c:box(x, y, math.max(h, w * math.min(1, fraction)), h, { r = h / 2, fill = C.BLACK }) end
end

-- Bars of `values` (from index `from`), `h` tall at most, with labels under some (labels[i]).
local function chart(c, x, y, w, h, values, from, count, labels)
    local most = 0
    for i = from, from + count - 1 do most = math.max(most, values[i] or 0) end
    local slot = w / count
    for i = from, from + count - 1 do
        local k = i - from
        local v = values[i] or 0
        if v > 0 and most > 0 then
            local bh = math.max(2, h * v / most)
            c:box(x + k * slot + slot * 0.15, y + h - bh, slot * 0.7, bh, { fill = C.BLACK })
        end
        if labels[i] then c:text(x + k * slot + slot / 2, y + h + 18, labels[i], 9.5, { align = "middle", color = C.GREY }) end
    end
    c:hline(x, y + h, w, C.GREY)
end

-- When the reading is, by hour: the chart and "Mostly 9 PM to 11 PM".
local function hoursBlock(F, c, hours)
    local at = Model.peakHours(hours)
    if not at then return end
    F:block(120, function(y)
        c:text(14, y + 24, T(_("Mostly %1 to %2"), hourName(at), hourName((at + 2) % 24)), 12)
        local labels = { [0] = hourName(0), [6] = hourName(6), [12] = hourName(12), [18] = hourName(18) }
        chart(c, 14, y + 38, c.W - 28, 56, hours, 0, 24, labels)
    end)
end

local function heading(F, c, text)
    F:block(36, function(y) c:text(14, y + 26, text, 9.5, { bold = true, color = C.GREY }) end, 64)
end

local function row(F, c, label, value, tap)
    F:block(44, function(y)
        c:text(14, y + 28, label .. (tap and "  ›" or ""), 12.5)
        c:text(c.W - 14, y + 28, value, 12, { align = "end", color = C.GREY, maxw = c.W * 0.55 })
        c:hline(14, y + 44, c.W - 28)
        if tap then c:hit(0, y, c.W, 44, tap) end
    end)
end

-- A time of day as the clock shows it: "9:05 PM" or "21:05".
local function clock(t)
    if require("appsko").twentyFour() then return os.date("%H:%M", t) end
    return (os.date("%I:%M %p", t):gsub("^0", ""))
end

local function dayName(t) return os.date("%a, %b ", t) .. tonumber(os.date("%d", t)) end

-- After a change: the numbers worked out again and drawn.
local function changed(view)
    view.statsData = nil
    view:refresh()
end

--- Day, start and end of a session (`x` from appssessions), changed in KOReader's pickers, then saved.
-- `e` holds the choices so far: { y, m, d, sh, smin, eh, emin } and which were changed.
function Stats.editSession(view, x, e)
    local Sessions = require("appssessions")
    local KO = require("appsko")
    local DateTimeWidget = require("ui/widget/datetimewidget")
    if not e then
        local a, b = os.date("*t", x.from), os.date("*t", x.to)
        e = { y = a.year, m = a.month, d = a.day, sh = a.hour, smin = a.min, eh = b.hour, emin = b.min }
    end
    -- A part left as it was keeps its exact time (the pickers only show minutes).
    local function times()
        local s = (not e.day and not e.start) and x.from
            or os.time({ year = e.y, month = e.m, day = e.d, hour = e.sh, min = e.smin, sec = 0 })
        local f = (not e.day and not e.finish) and x.to
            or os.time({ year = e.y, month = e.m, day = e.d, hour = e.eh, min = e.emin, sec = 0 })
        if f <= s then f = f + 86400 end   -- past midnight
        return s, f
    end
    local s, f = times()
    local again = function() Stats.editSession(view, x, e) end
    local function pick(o, done)
        -- Back to this menu once the picker has closed.
        o.ok_text, o.callback = _("Set"), function(t) done(t) UIManager:nextTick(again) end
        o.cancel_callback = function() UIManager:nextTick(again) end
        UIManager:show(DateTimeWidget:new(o))
    end
    local length = T(_("Length: %1 (was %2)"), Model.duration(f - s), Model.duration(x.to - x.from))
    local menu
    menu = KO.buttonDialog{ title = _("Edit this reading"), buttons = {
        { { text = T(_("Day: %1"), dayName(s)), callback = function()
            UIManager:close(menu)
            pick({ title_text = _("Day"), year = e.y, month = e.m, day = e.d, year_max = os.date("*t").year },
                function(t) e.y, e.m, e.d, e.day = t.year, t.month, t.day, true end)
        end } },
        { { text = T(_("Start: %1"), clock(s)), callback = function()
            UIManager:close(menu)
            pick({ title_text = _("Start"), hour = e.sh, min = e.smin }, function(t) e.sh, e.smin, e.start = t.hour, t.min, true end)
        end } },
        { { text = T(_("End: %1"), clock(f)), callback = function()
            UIManager:close(menu)
            pick({ title_text = _("End"), hour = e.eh, min = e.emin }, function(t) e.eh, e.emin, e.finish = t.hour, t.min, true end)
        end } },
        { { text = length, enabled = false } },
        { { text = _("Save"), callback = function()
            UIManager:close(menu)
            local undo, why = Sessions.edit(x.book, x.from, x.to, s, f)
            if not undo then return KO.message(why) end
            changed(view)
            KO.undo(_("Saved"), function() Sessions.putBack(undo) changed(view) end)
        end } },
    } }
end

--- A session's menu: Edit or Delete.
function Stats.sessionMenu(view, x)
    local Sessions = require("appssessions")
    local KO = require("appsko")
    local menu
    menu = KO.buttonDialog{ title = dayName(x.from) .. "  ·  " .. clock(x.from) .. " – " .. clock(x.to), buttons = {
        { { text = _("Edit"), callback = function()
            UIManager:close(menu)
            Stats.editSession(view, x)
        end } },
        { { text = _("Delete"), callback = function()
            UIManager:close(menu)
            local undo, why = Sessions.forget(x.book, x.from, x.to)
            if not undo then return KO.message(why) end
            changed(view)
            KO.undo(_("Deleted a session"), function() Sessions.putBack(undo) changed(view) end)
        end } },
    } }
end

function Stats.calendar(ui)
    local st = ui and ui.statistics
    if st and st.onShowCalendarView then st:onShowCalendarView() end
end

-- What the screens show, worked out again after half a minute (not on every page turn).
local function data(view)
    local d = view.statsData
    if d and os.time() - d.at < 30 then return d end
    local ui = view:ui()
    -- The book open now: its latest pages counted too (as KOReader's own lists do).
    local st = ui and ui.statistics
    if st and st.insertDB and ui.document then pcall(st.insertDB, st) end
    d = { at = os.time(), summary = Stats.summary(), books = Stats.books() }
    view.statsData = d
    return d
end

function Stats.draw(view, c)
    local ui = view:ui()
    local d = data(view)
    local s, books = d.summary, d.books
    local F = c:flow(56, c.H - 8, view.statsPage or 1)
    -- Two rows of three numbers, then Calendar.
    local function numbers(y, cols)
        local cw = (c.W - 28) / 3
        for i, col in ipairs(cols) do
            local x = 14 + (i - 1) * cw
            c:text(x, y + 34, col[1], 20, { bold = true, maxw = cw - 8 })
            c:text(x, y + 56, col[2], 10.5, { color = C.GREY, maxw = cw - 8 })
        end
    end
    F:block(194, function(y)
        local dur = function(v) return s and Model.duration(v) or "–" end
        numbers(y, { { dur(s and s.today), _("Today") }, { dur(s and s.week), _("Last 7 days") },
            { dur(s and s.month), _("Last 30 days") } })
        numbers(y + 70, { { s and days(s.streak) or "–", _("In a row") }, { s and days(s.longest) or "–", _("Longest streak") },
            { dur(s and s.total), _("In all") } })
        local label = _("Calendar")
        local bw = c:width(label, 12) + 64
        c:box(14, y + 148, bw, 36, { r = 18, border = C.BLACK, bw = 1.4 })
        c:icon("calendar-days", 14 + 18, y + 157, 18)
        c:text(14 + 44, y + 171, label, 12)
        c:hit(14, y + 142, bw, 48, function() Stats.calendar(ui) end)
    end)
    if s and s.total > 0 then
        heading(F, c, _("WHEN YOU READ"))
        hoursBlock(F, c, s.hours)
        F:block(118, function(y)
            local labels, best = {}, 0
            -- Sunday first, in the Kindle's language (Jan 4 2026 was a Sunday).
            local function day(w, f) return os.date(f, os.time({ year = 2026, month = 1, day = 4 + w, hour = 12 })) end
            for w = 0, 6 do
                labels[w] = day(w, "%a")
                if s.weekdays[w] > s.weekdays[best] then best = w end
            end
            c:text(14, y + 24, T(_("Most on %1"), day(best, "%A")), 12)
            chart(c, 14, y + 40, c.W - 28, 46, s.weekdays, 0, 7, labels)
        end)
    end
    heading(F, c, _("BOOKS"))
    if not books then
        F:block(70, function(y)
            c:text(14, y + 26, _("No reading statistics yet."), 12, { color = C.GREY, maxw = c.W - 28 })
            c:text(14, y + 50, _("They're kept by KOReader's Reading statistics plugin (Tools > More tools > Plugin management)."), 10.5, { color = C.GREY, maxw = c.W - 28 })
        end)
    elseif #books == 0 then
        F:block(44, function(y) c:text(14, y + 28, _("No books read yet."), 12, { color = C.GREY }) end)
    end
    for __, b in ipairs(books or {}) do
        F:block(80, function(y)
            local time = Model.duration(b.seconds)
            local tw = c:width(time, 12) + 12
            c:text(14, y + 26, b.title or _("Untitled"), 13, { bold = true, maxw = c.W - 42 - tw })
            c:text(c.W - 14, y + 26, time, 12, { align = "end" })
            local line = progress(b)
            if b.authors and b.authors ~= "" and b.authors ~= "N/A" then
                line = line ~= "" and (b.authors .. "  ·  " .. line) or b.authors
            end
            c:text(14, y + 48, line, 10.5, { color = C.GREY, maxw = c.W * 0.7 })
            c:text(c.W - 14, y + 48, lastRead(b.last), 10.5, { align = "end", color = C.GREY })
            if b.percent then bar(c, 14, y + 60, c.W - 28, 5, b.percent) end
            c:hline(14, y + 80, c.W - 28)
            c:hit(0, y, c.W, 80, function()
                view.mode, view.statsBook, view.statsbookPage = "statsbook", b.id, 1
                view:refresh()
            end)
        end)
    end
    view.pages = F:pages()
    if (view.statsPage or 1) > view.pages then
        view.statsPage = view.pages
        return view:render()
    end
    view:bar(c, _("Reading statistics"))
end

--- One book's page: how far along, the time left, its pace, its days and when it's read.
function Stats.drawBook(view, c)
    local ui = view:ui()
    local b = view.statsBook and Stats.book(view.statsBook)
    if not b then
        view.mode = "stats"
        return view:render()
    end
    local F = c:flow(56, c.H - 8, view.statsbookPage or 1)
    F:block(150, function(y)
        c:text(14, y + 38, b.title or _("Untitled"), 20, { bold = true, maxw = c.W - 28 })
        if b.authors and b.authors ~= "" and b.authors ~= "N/A" then
            c:text(14, y + 64, b.authors, 12, { color = C.GREY, maxw = c.W - 28 })
        end
        if b.percent then
            bar(c, 14, y + 84, c.W - 28, 12, b.percent)
            c:text(14, y + 126, math.floor(b.percent * 100) .. "%  ·  " .. T(_("page %1 of %2"), b.lastPage, b.pages), 12)
            c:text(c.W - 14, y + 126, b.percent >= 1 and _("Finished")
                or (b.left and T(_("About %1 left"), Model.duration(b.left)) or ""), 12, { align = "end", bold = true })
        end
    end)
    -- The book's page in the Library app (library.koplugin), when it's there.
    local PS = require("pluginshare")
    if PS.library and PS.library.openTitle then
        row(F, c, _("Book details"), _("Library"), function() PS.library.openTitle(b.title, b.authors) end)
    end
    heading(F, c, _("TIME"))
    row(F, c, _("Time reading"), Model.duration(b.seconds))
    if b.seconds > 0 and b.read > 0 then
        row(F, c, _("Pace"), T(_("%1 pages an hour"), math.floor(b.read / b.seconds * 3600 + 0.5)))
    end
    row(F, c, _("Days reading it"), tostring(b.days), b.days > 0 and function()
        -- KOReader's list of the days, with each one's time.
        local st = ui and ui.statistics
        if not (st and st.getDatesForBook) then return end
        local KeyValuePage = require("ui/widget/keyvaluepage")
        st.kv = KeyValuePage:new{ title = T(_("Days reading %1"), b.title or ""), value_overflow_align = "right",
            kv_pairs = st:getDatesForBook(b.id), close_callback = function() st.kv = nil end }
        UIManager:show(st.kv)
    end)
    if b.days > 0 then row(F, c, _("Average a day"), Model.duration(b.seconds / b.days)) end
    row(F, c, _("Started"), date(b.first))
    row(F, c, _("Last read"), date(b.last))
    row(F, c, _("Pages read"), b.pages and b.pages > 0 and T(_("%1 of %2"), b.read, b.pages) or tostring(b.read))
    if b.highlights then row(F, c, _("Highlights"), tostring(b.highlights)) end
    if b.notes then row(F, c, _("Notes"), tostring(b.notes)) end
    if b.seconds > 0 then
        heading(F, c, _("WHEN YOU READ IT"))
        hoursBlock(F, c, b.hours)
    end
    -- Each time it was read, newest first: tap one to edit or delete it.
    local list = require("appssessions").ofBook(b.id) or {}
    if #list > 0 then
        heading(F, c, _("SESSIONS"))
        F:block(30, function(y)
            c:text(14, y + 20, _("Tap one to change its day or times (a book left open by mistake, say), or delete it."), 10, { color = C.GREY, maxw = c.W - 28 })
        end)
    end
    for __, x in ipairs(list) do
        F:block(60, function(y)
            c:text(14, y + 26, dayName(x.from), 12.5)
            c:text(14, y + 48, clock(x.from) .. " – " .. clock(x.to), 10.5, { color = C.GREY })
            c:text(c.W - 14, y + 26, Model.duration(x.seconds), 12, { align = "end" })
            c:text(c.W - 14, y + 48, x.pages == 1 and _("1 page") or T(_("%1 pages"), x.pages), 10.5, { align = "end", color = C.GREY })
            c:hline(14, y + 60, c.W - 28)
            c:hit(0, y, c.W, 60, function() Stats.sessionMenu(view, x) end)
        end)
    end
    -- The whole book out of the statistics (Undo puts it back).
    F:block(70, function(y)
        local label = _("Reset statistics")
        local bw = c:width(label, 12) + 40
        c:box(14, y + 20, bw, 36, { r = 18, border = C.BLACK, bw = 1.4 })
        c:text(14 + bw / 2, y + 43, label, 12, { align = "middle" })
        c:hit(14, y + 14, bw, 48, function()
            local KO = require("appsko")
            KO.confirm{ text = T(_("Take all of “%1” out of the reading statistics (%2)?"), b.title or _("this book"), Model.duration(b.seconds)),
                ok = _("Reset"), onOk = function()
                    local Sessions = require("appssessions")
                    local undo, why = Sessions.forget(b.id)
                    if not undo then return KO.message(why) end
                    view.mode = "stats"
                    changed(view)
                    KO.undo(T(_("Reset %1"), b.title or _("this book")), function() Sessions.putBack(undo) changed(view) end)
                end }
        end)
    end)
    view.pages = F:pages()
    if (view.statsbookPage or 1) > view.pages then
        view.statsbookPage = view.pages
        return view:render()
    end
    view:bar(c, _("Reading statistics"))
end

return Stats
