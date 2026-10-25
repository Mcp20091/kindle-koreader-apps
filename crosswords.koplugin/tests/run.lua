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

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
