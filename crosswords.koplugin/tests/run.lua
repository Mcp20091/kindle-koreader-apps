-- Plain Lua tests: `luajit tests/run.lua` from the plugin folder, with Notes
-- (notes.koplugin) beside it for notescrossword.
package.path = "./?.lua;../notes.koplugin/?.lua;" .. package.path
local json = dofile("tests/json.lua")
local C = require("notescrossword")

local failed, passed = 0, 0
local function check(name, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    end
end

do
    local wed = C.daysFrom(2026, 10, 21)
    local n = 0
    local function newId() n = n + 1 return "pg" .. n end
    -- Crossword files: .puz and .ipuz.
    local Puz = require("crosswordspuz")
    local function puzFile(scrambled)
        local head = "\0\0ACROSS&DOWN\0" .. string.rep("\0", 0x2C - 14)
        local body = string.char(3, 3, 4, 0, 1, 0, scrambled and 4 or 0, 0) .. "CATO.EWEA" .. "---.-----"
            .. "Pets\0Me\0\0Pet\0Milker\0Brew\0Row\0\0" .. "GEXT" .. string.char(9, 0, 0, 0) .. string.char(0x80, 0, 0, 0, 0, 0, 0, 0, 0) .. "\0"
        return head .. body
    end
    local pz = Puz.parse(puzFile(), json, { key = "imp/1", day = wed })
    local pzc = {}
    for _, e in ipairs(pz and pz.entries or {}) do table.insert(pzc, e.number .. (e.across and "A" or "D") .. "=" .. e.clue) end
    check(".puz: read", pz and pz.name .. " " .. pz.source .. " " .. table.concat(pzc, " "), "Pets Me 1A=Pet 3A=Row 1D=Milker 2D=Brew")
    check(".puz: answers and circles", tostring(pz.answers) .. tostring(pz.circles["0,0"]) .. tostring(pz.imported), "truetruetrue")
    check(".puz: scrambled, no answers", Puz.parse(puzFile(true), json, { key = "imp/2" }).answers, false)
    check(".puz: not one", Puz.parse("hello", json, { key = "imp/3" }), nil)
    local ipuz = json.encode({ version = "http://ipuz.org/v2", kind = { "http://ipuz.org/crossword#1" }, title = "Pets", author = "Me",
        date = "10/21/2026", dimensions = { width = 3, height = 3 },
        puzzle = { { { cell = 1, style = { shapebg = "circle" } }, 0, 2 }, { 0, "#", 0 }, { 3, 0, 0 } },
        solution = { { "C", "A", "T" }, { "O", "#", "E" }, { "W", "E", "A" } },
        clues = { Across = { { 1, "Pet" }, { number = 3, clue = "Row" } }, Down = { { 1, "Milker" }, { 2, "Brew" } } } })
    local ip = Puz.parse(ipuz, json, { key = "imp/4", day = 1 })
    check(".ipuz: read", ip and ip.name .. " " .. #ip.entries .. " " .. ip.entries[2].clue .. " " .. C.dayLabel(ip.day), "Pets 4 Row Wed 21 Oct")
    check(".ipuz: answers and circles", tostring(ip.answers) .. tostring(ip.circles["0,0"]), "truetrue")
    local imported = { pages = {} }
    C.addToBook(imported, ip, newId)
    check("imported: titled first page", imported.pages[1].title .. " " .. C.pageLabel(imported.pages[1]), "Pets Pets")
end

do
    -- The hint prompt says which kind of crossword it is, with only that kind's instructions.
    check("kind: cryptic", C.kindOf("cryptic/29812") .. C.kindOf("prize/29000") .. C.kindOf("quiptic/1300"), "crypticcrypticcryptic")
    check("kind: plain", C.kindOf("quick/17616") .. C.kindOf("usa/20261021") .. C.kindOf("tny/20261020"), "plainplainplain")
    check("kind: imported unknown", C.kindOf("imp/2026102112000001"), nil)
    local e = { label = "11", across = true, clue = "Vipers and others (4)", length = 4, answer = "ASPS" }
    local plain, cryptic, both = C.hintPrompt(e, {}, false, nil, "plain"), C.hintPrompt(e, {}, false, nil, "cryptic"), C.hintPrompt(e, {})
    check("plain: says so, no wordplay instructions", plain:find("plain crossword", 1, true) ~= nil and plain:find("anagram", 1, true) == nil, true)
    check("cryptic: says so, wordplay instructions", cryptic:find("cryptic crossword", 1, true) ~= nil and cryptic:find("anagram", 1, true) ~= nil, true)
    check("unknown: both, as before", both:find("For a straight clue", 1, true) ~= nil, true)
end

do
    -- Source checks: nothing here may call NetworkMgr:isOnline() (a DNS lookup that can hang the loop).
    local function slurp(name) local f = io.open(name, "rb") local s = f and f:read("*a") or "" if f then f:close() end return s end
    local bad = {}
    for __, name in ipairs({ "crosswordsui.lua", "webcrosswords.lua" }) do
        if slurp(name):find(":isOnline()", 1, true) then table.insert(bad, name) end
    end
    check("no isOnline()", table.concat(bad, ","), "")
    check("web settings: puzzle_buttons", slurp("webcrosswords.lua"):find('puzzle_buttons = "table"', 1, true) ~= nil, true)
end

do
    -- Swap grid and clues: a made-up 15 x 15 puzzle with enough clues for a second clue page.
    local grid, across, down = {}, {}, {}
    for y = 1, 15 do
        grid[y] = {}
        for x = 1, 15 do grid[y][x] = string.char(65 + (x * 3 + y) % 26) end
    end
    for k = 1, 15 do
        across[k] = "Something to fill in, with a few words (5)"
        down[k] = across[k]
    end
    local p = C.fromGrid({ key = "usa/20261021", name = "Made up" }, grid, across, down)
    for __, land in ipairs({ false, true }) do
        local name = land and "swap, on its side: " or "swap: "
        local plain = C.layout(p, { landscape = land })
        local swapped = C.layout(p, { landscape = land, swap = true })
        local g = swapped[1].grid
        check(name .. "same cell size", g.cell, plain[1].grid.cell)
        check(name .. "same parts", #swapped .. swapped[#swapped].part, #plain .. plain[#plain].part)
        local clear = #swapped[1].clues > 0
        for __, c in ipairs(swapped[1].clues) do
            if land then clear = clear and c[1] + c[3] <= g.x + 1 else clear = clear and c[2] + c[4] <= g.y + 1 end
        end
        check(name .. "clues clear of the grid", clear, true)
        if land then
            check(name .. "grid at the right", g.x > plain[1].grid.x and g.x + 15 * g.cell <= swapped[1].w, true)
        else
            check(name .. "grid at the bottom", g.y > plain[1].grid.y and g.y + 15 * g.cell <= swapped[1].h, true)
        end
        local last = swapped[#swapped].grid
        check(name .. "every clue page has the grid in the same place", last.x .. "," .. last.y, g.x .. "," .. g.y)
    end

    -- The writing in the grid goes with it, and back; writing outside it stays.
    local load = function() return p end
    local function r(v) return math.floor(v + 0.5) end
    for __, land in ipairs({ false, true }) do
        local name = land and "move, on its side: " or "move: "
        local part = land and "L1" or "1"
        local w, h = 1860, 2480
        if land then w, h = h, w end
        local from = C.gridOnScreen(p, C.layout(p, { landscape = land })[1], w, h)
        local to = C.gridOnScreen(p, C.layout(p, { landscape = land, swap = true })[1], w, h)
        local x, y = r(from[1] + from[3] * 3.5), r(from[2] + from[3] * 6.5)
        local page = { pz = "usa/20261021:" .. part,
            strokes = { { w = 3, p = { 6, 6, 12, 12 } }, { w = 4, p = { x, y, x + 8, y + 8 } } },
            items = { { k = "text", x = x, y = y, w = 30, size = 24, text = "Q" } } }
        local nb = { width = 1860, height = 2480, lay = "normal+b+t", pages = { page } }
        local dx, dy = to[1] - from[1], to[2] - from[2]
        check(name .. "something moved", C.moveGrids(nb, load, { swap = true }, false), true)
        check(name .. "outside writing stays", #page.strokes .. " " .. table.concat(page.strokes[1].p, ","), "2 6,6,12,12")
        check(name .. "grid writing in the same square", table.concat(page.strokes[2].p, ","),
            r(x + dx) .. "," .. r(y + dy) .. "," .. r(x + 8 + dx) .. "," .. r(y + 8 + dy))
        check(name .. "typed letter moved", page.items[1].x .. "," .. page.items[1].y, r(x + dx) .. "," .. r(y + dy))
        check(name .. "no change, nothing moves", C.moveGrids(nb, load, { swap = true }, true), false)
        C.moveGrids(nb, load, { swap = false }, true)
        check(name .. "back where it was", table.concat(page.strokes[2].p, ",") .. " " .. page.items[1].x .. "," .. page.items[1].y,
            x .. "," .. y .. "," .. (x + 8) .. "," .. (y + 8) .. " " .. x .. "," .. y)
    end
    local function slurp(name) local f = io.open(name, "rb") local s = f and f:read("*a") or "" if f then f:close() end return s end
    check("web settings: crossword_swap", slurp("webcrosswords.lua"):find('crossword_swap = "boolean"', 1, true) ~= nil, true)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
