--[[--
Reading sessions in KOReader's reading statistics (statistics.sqlite3): a
book read with no break over 10 minutes. Listed, moved, shortened,
lengthened, deleted and put back. Reading statistics' book pages here and the
web page's Reading tab both use it, so the two always agree.
]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Sessions = {}

-- A break longer than this starts a new session.
Sessions.GAP = 600

local function open()
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    return require("lua-ljsqlite3/init").open(path)
end

-- Runs fn(conn); returns its results, or nil and why not.
local function with(fn)
    local conn = open()
    if not conn then return nil, "No reading statistics" end
    local ok, a, b = pcall(fn, conn)
    if not ok then pcall(conn.exec, conn, "ROLLBACK;") end
    conn:close()
    if not ok then return nil, (tostring(a):gsub("^.-:%d+: ", "")) end
    return a, b
end

-- Rows of page_stat_data in time order, into sessions: { { book, title, from,
-- to, seconds, pages } }.
local function group(rows)
    local sessions, cur = {}, nil
    for i = 1, rows and rows[1] and #rows[1] or 0 do
        local book, t, dur = tonumber(rows[1][i]), tonumber(rows[2][i]), tonumber(rows[3][i]) or 0
        if not cur or cur.book ~= book or t - cur.to > Sessions.GAP then
            cur = { book = book, title = rows[5] and rows[5][i] or "?", from = t, to = t + dur, seconds = 0, pages = 0 }
            table.insert(sessions, cur)
        end
        cur.to = math.max(cur.to, t + dur)
        cur.seconds = cur.seconds + dur
        cur.pages = cur.pages + 1
    end
    return sessions
end

--- A day's reading ("YYYY-MM-DD"), in sessions, in time order.
function Sessions.day(day)
    local y, m, d = tostring(day or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return nil, "Which day?" end
    local start = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 })
    return with(function(conn)
        return group(conn:exec(string.format([[
            SELECT p.id_book, p.start_time, p.duration, p.page, b.title
            FROM page_stat_data p LEFT JOIN book b ON b.id = p.id_book
            WHERE p.start_time >= %d AND p.start_time < %d ORDER BY p.start_time;]], start, start + 86400)))
    end)
end

--- Every session of a book, newest first.
function Sessions.ofBook(book)
    book = tonumber(book)
    if not book then return nil, "Which book?" end
    return with(function(conn)
        local list = group(conn:exec(string.format([[
            SELECT p.id_book, p.start_time, p.duration, p.page, b.title
            FROM page_stat_data p LEFT JOIN book b ON b.id = p.id_book
            WHERE p.id_book = %d ORDER BY p.start_time;]], book)))
        local out = {}
        for i = #list, 1, -1 do table.insert(out, list[i]) end
        return out
    end)
end

-- A book's totals counted again from what is left.
local function retotal(conn, book)
    pcall(conn.exec, conn, string.format([[UPDATE book SET
        total_read_time = (SELECT coalesce(sum(duration), 0) FROM page_stat_data WHERE id_book = %d),
        total_read_pages = (SELECT count(DISTINCT page) FROM page_stat_data WHERE id_book = %d)
        WHERE id = %d;]], book, book, book))
end

local function rowsOf(conn, book, from, to)
    local where = from and string.format(" AND start_time >= %d AND start_time <= %d", math.floor(from), math.floor(to)) or ""
    local r = conn:exec(string.format(
        "SELECT page, start_time, duration, total_pages FROM page_stat_data WHERE id_book = %d%s ORDER BY start_time;", book, where))
    local list = {}
    for i = 1, r and r[1] and #r[1] or 0 do
        table.insert(list, { page = tonumber(r[1][i]), t = tonumber(r[2][i]), d = tonumber(r[3][i]) or 0, total = tonumber(r[4][i]) or 0 })
    end
    return list
end

local function insert(conn, book, list)
    for __, r in ipairs(list) do
        conn:exec(string.format("INSERT OR REPLACE INTO page_stat_data (id_book, page, start_time, duration, total_pages) VALUES (%d, %d, %d, %d, %d);",
            book, r.page, r.t, r.d, r.total))
    end
end

--- Forgets a session (a book's reading from `from` to `to`, Unix seconds), or
-- with no times every bit of that book's reading. Returns what was taken
-- out (for Sessions.putBack), or nil and why not.
function Sessions.forget(book, from, to)
    book = tonumber(book)
    if not book then return nil, "Which book?" end
    from, to = tonumber(from), tonumber(to)
    if not (from and to) then from, to = nil, nil end
    return with(function(conn)
        local old = rowsOf(conn, book, from, to)
        local where = from and string.format(" AND start_time >= %d AND start_time <= %d", math.floor(from), math.floor(to)) or ""
        conn:exec(string.format("DELETE FROM page_stat_data WHERE id_book = %d%s;", book, where))
        retotal(conn, book)
        return { book = book, rows = old }
    end)
end

--- Undoes Sessions.forget or Sessions.edit: what `undo` holds put back (an
-- edit's new times taken out first). Returns true, or nil and why not.
function Sessions.putBack(undo)
    if type(undo) ~= "table" or not undo.book then return nil, "Nothing to put back" end
    return with(function(conn)
        conn:exec("BEGIN;")
        if undo.from then
            conn:exec(string.format("DELETE FROM page_stat_data WHERE id_book = %d AND start_time >= %d AND start_time <= %d;",
                undo.book, undo.from, undo.to))
        end
        insert(conn, undo.book, undo.rows)
        conn:exec("COMMIT;")
        retotal(conn, undo.book)
        return true
    end)
end

--- Changes a session (a book's reading from `from` to `to`) to run from
-- `start` to `finish` (Unix seconds): moved as a whole, then shortened by
-- cutting time off the end, or lengthened by stretching each page's time.
-- Returns what to give Sessions.putBack to undo it, or nil and why not.
function Sessions.edit(book, from, to, start, finish)
    book, from, to, start, finish = tonumber(book), tonumber(from), tonumber(to), tonumber(start), tonumber(finish)
    if not (book and from and to and start and finish) then return nil, "Which session?" end
    start, finish = math.floor(start), math.floor(finish)
    if finish <= start then return nil, "The end must be after the start." end
    if finish - start > 86400 then return nil, "A session can't be longer than a day." end
    if finish > os.time() + 60 then return nil, "That's in the future." end
    return with(function(conn)
        local list = rowsOf(conn, book, from, to)
        local n = #list
        if n == 0 then error("That session isn't there any more.") end
        local first, last = list[1].t, list[n].t + list[n].d
        -- Not on top of other reading (it would count twice).
        local other = conn:rowexec(string.format([[
            SELECT count(*) FROM page_stat_data WHERE start_time < %d AND start_time + duration > %d
            AND NOT (id_book = %d AND start_time >= %d AND start_time <= %d);]],
            finish, start, book, math.floor(from), math.floor(to)))
        if tonumber(other) and tonumber(other) > 0 then error("That overlaps other reading. Pick times when nothing else was read.") end
        local new = {}
        if finish - start >= last - first then
            -- Longer (or the same): every page's time stretched alike.
            local k = (finish - start) / math.max(1, last - first)
            for __, r in ipairs(list) do
                table.insert(new, { page = r.page, t = start + math.floor((r.t - first) * k), d = math.max(1, math.floor(r.d * k + 0.5)), total = r.total })
            end
        else
            -- Shorter: moved, and what goes past the new end is cut off.
            for __, r in ipairs(list) do
                local t = start + (r.t - first)
                if t < finish then
                    table.insert(new, { page = r.page, t = t, d = math.max(1, math.min(r.d, finish - t)), total = r.total })
                end
            end
        end
        conn:exec("BEGIN;")
        conn:exec(string.format("DELETE FROM page_stat_data WHERE id_book = %d AND start_time >= %d AND start_time <= %d;",
            book, math.floor(from), math.floor(to)))
        insert(conn, book, new)
        conn:exec("COMMIT;")
        retotal(conn, book)
        return { book = book, rows = list, from = start, to = finish }
    end)
end

return Sessions
