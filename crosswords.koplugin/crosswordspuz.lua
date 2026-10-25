--[[--
Crossword files for Notes' imported crosswords, in plain Lua (JSON is passed
in) so the tests run it: Across Lite .puz (binary) and .ipuz (JSON). Each
becomes the same puzzle as the crosswords fetched (notescrossword's
fromGrid), with its circled squares; a .puz with scrambled answers, or an
.ipuz without its solution, has no answers page.

.puz: "ACROSS&DOWN" at byte 2; the width and height at 0x2C and 0x2D, the
clue count at 0x2E, whether it is scrambled at 0x32; the solution (one
letter a square, "." black) at 0x34, then what was filled in, then the
title, author, copyright, the clues (in grid order: a square's across clue
before its down clue) and notes, each ending in a zero byte, in Latin-1.
Then optional sections ("GEXT": a byte a square, 0x80 circled).
]]

local Crossword = require("notescrossword")

local Puz = {}

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
end

-- Latin-1 text as UTF-8.
local function latin1(s)
    return (s:gsub("[\128-\255]", function(c) return utf8char(c:byte()) end))
end

local function u16(s, at) return s:byte(at + 1) + s:byte(at + 2) * 256 end

--- A .puz file's bytes as a puzzle (`meta`: key, day), or nil and why.
function Puz.parsePuz(bytes, meta)
    if type(bytes) ~= "string" or #bytes < 0x34 or bytes:sub(3, 13) ~= "ACROSS&DOWN" then return nil, "not a crossword file" end
    local cols, rows = bytes:byte(0x2C + 1), bytes:byte(0x2D + 1)
    local count = u16(bytes, 0x2E)
    local scrambled = u16(bytes, 0x32) ~= 0
    local n = cols * rows
    if cols < 3 or rows < 3 or cols > 30 or rows > 30 or #bytes < 0x34 + 2 * n then return nil, "not a crossword file" end
    local solution = bytes:sub(0x34 + 1, 0x34 + n)
    -- The strings after the grids.
    local at = 0x34 + 2 * n + 1
    local strings = {}
    while #strings < 3 + count + 1 and at <= #bytes do
        local stop = bytes:find("\0", at, true) or (#bytes + 1)
        table.insert(strings, latin1(bytes:sub(at, stop - 1)))
        at = stop + 1
    end
    if #strings < 3 + count then return nil, "not a crossword file" end
    -- Circled squares (GEXT).
    local circles
    local gext = bytes:find("GEXT", at, true)
    if gext and #bytes >= gext + 7 + n then
        local data = bytes:sub(gext + 8, gext + 7 + n)
        for i = 1, n do
            if math.floor(data:byte(i) / 0x80) % 2 == 1 then
                circles = circles or {}
                circles[((i - 1) % cols) .. "," .. math.floor((i - 1) / cols)] = true
            end
        end
    end
    local grid = {}
    for y = 1, rows do
        local row = {}
        for x = 1, cols do
            local ch = solution:sub((y - 1) * cols + x, (y - 1) * cols + x)
            local black = ch == "." or ch == ":"
            row[x] = not black and (scrambled and "?" or (ch:upper():match("[%u%d]") or "?")) or false
        end
        grid[y] = row
    end
    -- Clues in grid order, numbered as fromGrid numbers them.
    local function white(x, y) return x >= 1 and y >= 1 and x <= cols and y <= rows and grid[y][x] ~= false end
    local across, down, k, num = {}, {}, 4, 0
    for y = 1, rows do
        for x = 1, cols do
            if white(x, y) then
                local a = not white(x - 1, y) and white(x + 1, y)
                local d = not white(x, y - 1) and white(x, y + 1)
                if a or d then
                    num = num + 1
                    if a then across[num] = strings[k] k = k + 1 end
                    if d then down[num] = strings[k] k = k + 1 end
                end
            end
        end
    end
    local title = Crossword.plain(strings[1])
    local author = Crossword.plain(strings[2])
    local p, why = Crossword.fromGrid({ key = meta.key, day = meta.day, name = title ~= "" and title or "Crossword",
        source = author ~= "" and author or "Imported" }, grid, across, down, circles)
    if not p then return nil, why end
    p.imported = true
    return p
end

local function cellValue(c)
    if type(c) == "table" then return c.cell or c.value end
    return c
end

-- A date in an .ipuz ("10/21/2026", "2026-10-21") as days since 1970.
local function dateOf(s)
    if type(s) ~= "string" then return nil end
    local m, d, y = s:match("^(%d+)/(%d+)/(%d%d%d%d)")
    if not m then y, m, d = s:match("^(%d%d%d%d)%-(%d+)%-(%d+)") end
    if not y then return nil end
    return Crossword.daysFrom(tonumber(y), tonumber(m), tonumber(d))
end

--- An .ipuz file's text as a puzzle (`meta`: key, day), or nil and why.
function Puz.parseIpuz(text, json, meta)
    local ok, d = pcall(json.decode, text or "")
    if not ok or type(d) ~= "table" or type(d.dimensions) ~= "table" or type(d.puzzle) ~= "table" then
        return nil, "not a crossword file"
    end
    local cols, rows = tonumber(d.dimensions.width), tonumber(d.dimensions.height)
    if not cols or not rows then return nil, "not a crossword file" end
    local block = d.block or "#"
    local grid, circles, answers = {}, nil, type(d.solution) == "table"
    for y = 1, rows do
        local row = {}
        local prow = d.puzzle[y] or {}
        local srow = answers and d.solution[y] or {}
        for x = 1, cols do
            local c, s = prow[x], srow[x]
            local cv, sv = cellValue(c), cellValue(s)
            local black = c == nil or c == json.null or cv == block or sv == block or (answers and (s == nil or s == json.null))
            if black then
                row[x] = false
            else
                local letter = type(sv) == "string" and sv:upper():match("^[%u%d]") or nil
                row[x] = letter or "?"
            end
            if type(c) == "table" and type(c.style) == "table" and c.style.shapebg == "circle" then
                circles = circles or {}
                circles[(x - 1) .. "," .. (y - 1)] = true
            end
        end
        grid[y] = row
    end
    local function clues(list)
        local out = {}
        for _, c in ipairs(type(list) == "table" and list or {}) do
            local n, clue
            if type(c) == "table" and c[1] ~= nil then n, clue = c[1], c[2]
            elseif type(c) == "table" then n, clue = c.number, c.clue end
            if tonumber(n) and type(clue) == "string" then out[tonumber(n)] = clue end
        end
        return out
    end
    local cl = type(d.clues) == "table" and d.clues or {}
    local title = Crossword.plain(type(d.title) == "string" and d.title or "")
    local author = Crossword.plain(type(d.author) == "string" and d.author or "")
    local p, why = Crossword.fromGrid({ key = meta.key, day = dateOf(d.date) or meta.day, name = title ~= "" and title or "Crossword",
        source = author ~= "" and author or "Imported" }, grid, clues(cl.Across or cl.across), clues(cl.Down or cl.down), circles)
    if not p then return nil, why end
    p.imported = true
    return p
end

--- A crossword file (.puz or .ipuz, told apart by its bytes) as a puzzle.
function Puz.parse(bytes, json, meta)
    if type(bytes) ~= "string" then return nil, "not a crossword file" end
    if bytes:sub(3, 13) == "ACROSS&DOWN" then return Puz.parsePuz(bytes, meta) end
    if bytes:match("^%s*{") then return Puz.parseIpuz(bytes, json, meta) end
    return nil, "not a .puz or .ipuz file"
end

return Puz
