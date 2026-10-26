-- Plain Lua tests: `luajit tests/run.lua` from the plugin folder.
package.path = "./?.lua;" .. package.path
local Ink = require("notesink")
local Store = require("notesstore")

local failed, passed = 0, 0
local function check(name, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    end
end

-- Stamps along a segment leave no gaps however far apart the points are.
local covered = {}
Ink.segment(0, 0, 100, 0, 4, function(x, y, s)
    for px = x, x + s - 1 do covered[px] = true end
end)
local gaps = 0
for x = 0, 100 do if not covered[x] then gaps = gaps + 1 end end
check("no gaps on a long segment", gaps, 0)

local stamps = 0
Ink.stroke({ w = 2, p = { 10, 10 } }, function() stamps = stamps + 1 end)
check("a dot stamps once or more", stamps >= 1, true)

local x, y, w, h = Ink.box({ w = 4, p = { 10, 20, 30, 5 } })
check("box x", x, 7)
check("box y", y, 2)
check("box w", w, 26)
check("box h", h, 21)

local line = { w = 2, p = { 0, 0, 100, 0 } }
check("eraser on the line", Ink.hits(line, 50, 3, 4), true)
check("eraser near the line", Ink.hits(line, 50, 20, 4), false)
check("eraser past the end", Ink.hits(line, 120, 0, 4), false)
check("eraser on a dot", Ink.hits({ w = 2, p = { 5, 5 } }, 6, 6, 3), true)

local u = Ink.union({ 0, 0, 10, 10 }, { 5, 5, 10, 10 })
check("union", table.concat(u, ","), "0,0,15,15")
check("clip under the toolbar", table.concat(Ink.clip({ -5, 10, 20, 100 }, 100, 50, 30), ","), "0,30,15,20")
check("clip away", Ink.clip({ 0, 0, 10, 10 }, 100, 100, 50), nil)

-- Notebooks: written and read back; damaged files refused; no code runs.
local nb = { id = "nb1", name = 'Q3 "plans"', created = 1, modified = 2, paper = "grid", width = 1860, height = 2480,
    pages = { { strokes = { { w = 3, p = { 1, 2, 3, 4 } } } }, { strokes = {} } } }
local back = Store.parse(Store.serialize(nb))
check("round trip name", back.name, 'Q3 "plans"')
check("round trip pages", #back.pages, 2)
check("round trip points", table.concat(back.pages[1].strokes[1].p, ","), "1,2,3,4")
check("round trip paper", back.paper, "grid")
check("damaged refused", Store.parse("return {"), nil)
check("no code runs", Store.parse("return { pages = { os.exit(1) } }"), nil)
local odd = Store.parse("return { pages = { { strokes = { { w = 2, p = { 1, 2, 3 } } } } } }")
check("odd points dropped", #odd.pages[1].strokes, 0)
check("unknown paper", Store.parse("return { paper = 'x', pages = {} }").paper, "plain")
check("empty notebook gets a page", #Store.parse("return { pages = {} }").pages, 1)

-- Saving and listing in a temporary folder.
local dir = os.tmpname()
os.remove(dir)
local made = os.execute((package.config:sub(1, 1) == "\\" and "mkdir " or "mkdir -p ") .. dir)
local clock = 100
local files = {}
local store = Store.new{ dir = dir, now = function() clock = clock + 1 return clock end,
    list = function() local out = {} for name in pairs(files) do table.insert(out, name) end return out end }
local a = store:create("First", 1860, 2480)
files[a.id .. ".lua"] = true
local b = store:create("Second", 1860, 2480)
files[b.id .. ".lua"] = true
table.insert(a.pages[1].strokes, { w = 3, p = { 5, 6, 7, 8 } })
store:save(a)
local listed = store:list()
check("listed both", #listed, 2)
check("latest first", listed[1].name, "First")
check("saved strokes", #store:read(a.id).pages[1].strokes, 1)
check("deleted", store:delete(b.id), true)
store:delete(a.id)
os.remove(dir)
check("temporary folder made", made ~= nil and made ~= false, true)

-- The digitizer: near, touching, moving, lifting; the eraser end; dropped events.
local Pen = require("notespen")
local state = Pen.newState()
local function feed(t, c, v) return Pen.parse(state, t, c, v, 1000) end
feed(1, 320, 1)           -- BTN_TOOL_PEN: near
feed(3, 0, 1000)
feed(3, 1, 2000)
check("hovering reports nothing", feed(0, 0, 0), nil)
feed(1, 330, 1)           -- BTN_TOUCH
feed(3, 24, 2048)
local ev = feed(0, 0, 0)
check("touch is down", ev and ev.kind, "down")
check("down pressure", ev and ev.pressure, 2048)
check("down not eraser", ev and ev.eraser, false)
feed(3, 0, 1010)
ev = feed(0, 0, 0)
check("move", ev and ev.kind, "move")
check("move x", ev and ev.x, 1010)
feed(0, 3, 0)             -- SYN_DROPPED
feed(3, 0, 3000)
ev = feed(0, 0, 0)
check("after dropped events: restart", ev and ev.kind, "restart")
feed(1, 330, 0)
ev = feed(0, 0, 0)
check("lift is up", ev and ev.kind, "up")
feed(1, 320, 0)
feed(1, 321, 1)           -- BTN_TOOL_RUBBER: the eraser end
feed(1, 330, 1)
ev = feed(0, 0, 0)
check("eraser end", ev and ev.eraser, true)
feed(1, 330, 0)
feed(0, 0, 0)
feed(1, 321, 0)
feed(1, 320, 1)
feed(1, 331, 1)           -- the side button held
feed(1, 330, 1)
ev = feed(0, 0, 0)
check("side button erases", ev and ev.eraser, true)

-- Pressure into width; widths kept per point.
check("light pressure is thin", Ink.pressureWidth(10, 0, 4095), 3)
check("full pressure is full width", Ink.pressureWidth(10, 4095, 4095), 10)
check("no pressure range keeps width", Ink.pressureWidth(6, nil, nil), 6)
local wide = { w = 8, p = { 0, 0, 10, 0, 20, 0 }, q = { 2, 8, 8 } }
check("segment width averages its ends", Ink.segmentWidth(wide, 1), 5)
check("stroke without widths", Ink.segmentWidth({ w = 4, p = { 0, 0, 1, 1 } }, 1), 4)
local nbq = Store.parse(Store.serialize({ id = "nb2", name = "q", pages = { { strokes = { wide } } } }))
check("widths saved", table.concat(nbq.pages[1].strokes[1].q, ","), "2,8,8")
check("pressure on by default", nbq.pressure, true)
check("wrong widths count dropped", Store.parse("return { pages = { { strokes = { { w = 2, p = { 1, 2, 3, 4 }, q = { 1 } } } } } }").pages[1].strokes[1].q, nil)

-- Precise erasing: only what the eraser covers goes.
local long = { w = 2, p = { 0, 0, 100, 0 } }   -- drawn fast: two points far apart
local cut = Ink.eraseCircle(long, 50, 0, 5)
check("cut in two", cut and #cut, 2)
check("left piece ends before the eraser", cut and cut[1].p[#cut[1].p - 1] < 45, true)
check("right piece starts after it", cut and cut[2].p[1] > 55, true)
check("pieces keep widths", cut and #cut[1].q == #cut[1].p / 2, true)
check("missed", Ink.eraseCircle(long, 50, 30, 5), nil)
local tip = Ink.eraseCircle(long, 100, 0, 5)
check("end trimmed", tip and #tip, 1)
check("dot erased whole", #Ink.eraseCircle({ w = 3, p = { 10, 10 } }, 10, 10, 5), 0)
local wavy = { w = 4, p = { 0, 0, 10, 0, 20, 0, 30, 0 }, q = { 2, 4, 6, 8 } }
local trimmed = Ink.eraseCircle(wavy, 0, 0, 3)
check("start trimmed keeps the rest", trimmed and #trimmed, 1)
check("trimmed widths follow", trimmed and trimmed[1].q[#trimmed[1].q], 8)

-- Tips: sizes, pressure, grey.
check("ballpoint full size", Ink.tipWidth("pen", 3, nil, 1), 6)
check("ballpoint light touch a bit thinner", Ink.tipWidth("pen", 3, 0, 1), 4)
check("fountain light touch a third", Ink.tipWidth("fountain", 5, 0, 1), 5)
check("fountain full pressure", Ink.tipWidth("fountain", 5, 1, 1), 15)
check("marker ignores pressure", Ink.tipWidth("marker", 2, 0, 1), 10)
check("sizes clamped", Ink.tipWidth("pen", 9, nil, 1), 13)
check("scaled for the screen", Ink.tipWidth("pen", 5, nil, 2), 26)
check("pencil is grey", Ink.tipOf({ t = "pencil" }).grey > 0, true)
check("highlighter goes under", Ink.tipOf({ t = "hl" }).under, true)
check("no tip is the ballpoint", Ink.tipOf({}).grey, 0)
check("erased pieces keep their tip", Ink.eraseCircle({ t = "hl", w = 20, p = { 0, 0, 100, 0 } }, 50, 0, 5)[1].t, "hl")

-- The lasso.
local square = { 0, 0, 100, 0, 100, 100, 0, 100 }
check("inside the lasso", Ink.inside(square, 50, 50), true)
check("outside the lasso", Ink.inside(square, 150, 50), false)
local page = {
    { w = 2, p = { 10, 10, 20, 20, 30, 30 } },           -- inside
    { w = 2, p = { 50, 50, 150, 50, 160, 50 } },         -- a third inside
    { w = 2, p = { 90, 90, 120, 90 } },                  -- half inside
}
check("lasso takes strokes mostly inside", table.concat(Ink.lassoed(page, square), ","), "1,3")
check("a lasso needs three corners", #Ink.lassoed(page, { 0, 0, 10, 10 }), 0)
local moved = Ink.transform({ t = "pencil", w = 4, p = { 10, 10, 20, 30 }, q = { 2, 4 } }, 10, 10, 2, 5, -5)
check("scaled from the corner and moved", table.concat(moved.p, ","), "15,5,35,45")
check("widths scale too", table.concat(moved.q, ","), "4,8")
check("transform keeps the tip", moved.t, "pencil")
local bx = Ink.boxOf({ { w = 2, p = { 10, 10 } }, { w = 2, p = { 40, 50 } } })
check("box of several strokes", table.concat(bx, ","), "8,8,34,44")
check("clip left of the toolbar", table.concat(Ink.clip({ 0, 0, 50, 50 }, 100, 100, 0, 20), ","), "20,0,30,50")

-- Tips and templates saved.
local tipped = Store.parse(Store.serialize({ id = "nb3", name = "t", paper = "dots",
    pages = { { strokes = { { t = "hl", w = 30, p = { 1, 2, 3, 4 } }, { t = "bogus", w = 2, p = { 1, 1 } } } } } }))
check("tip saved", tipped.pages[1].strokes[1].t, "hl")
check("unknown tip is the ballpoint", tipped.pages[1].strokes[2].t, nil)
check("dots paper", tipped.paper, "dots")
check("old lined paper is narrow ruled", Store.parse("return { paper = 'lined', pages = {} }").paper, "narrow")

-- Notebook order.
local books = { { id = "a", name = "beta", created = 1, modified = 9 }, { id = "b", name = "Alpha", created = 3, modified = 5 },
    { id = "c", name = "gamma", created = 2, modified = 7 } }
local function ids(list) local out = {} for i, nb in ipairs(list) do out[i] = nb.id end return table.concat(out) end
check("sorted by name", ids(Store.sorted(books, "name")), "bac")
check("sorted by created", ids(Store.sorted(books, "created")), "bca")
check("custom order, new ones first", ids(Store.sorted(books, "custom", { "c", "a" })), "bca")
check("last changed keeps the list", ids(Store.sorted(books, "modified")), "abc")

-- The eraser end and the side button told apart.
state = Pen.newState()
feed(1, 320, 1) feed(3, 0, 5) feed(3, 1, 5) feed(1, 331, 1) feed(1, 330, 1)
ev = feed(0, 0, 0)
check("side button reported", ev and ev.side, true)
check("side button is not the eraser end", ev and ev.rubber, false)

-- Page ids: kept, made for old notebooks, saved.
local withIds = Store.parse(Store.serialize({ id = "nb4", name = "i", pages = { { id = "pg123", strokes = {} }, { strokes = {} } } }))
check("page id kept", withIds.pages[1].id, "pg123")
check("page id made when saving", withIds.pages[2].id ~= nil and withIds.pages[2].id ~= "pg123", true)
local old = Store.parse("return { pages = { { strokes = {} }, { strokes = {} } } }")
check("old notebook gets ids", old.pages[1].id ~= nil and old.pages[1].id ~= old.pages[2].id, true)
check("old notebook flagged for saving", old.newIds, true)
check("bad id replaced", Store.parse("return { pages = { { id = 'x); os.exit()', strokes = {} } } }").pages[1].id:match("^pg%d+$") ~= nil, true)
check("page text follows the ink", Store.pageText({ strokes = { { w = 2, p = { 1, 2 } } } }, "grid") ~= Store.pageText({ strokes = {} }, "grid"), true)
check("page text follows the paper", Store.pageText({ strokes = {} }, "grid") ~= Store.pageText({ strokes = {} }, "dots"), true)

-- OneNote: names, bodies, the plan, and a send against a pretend Graph.
local OneNote = require("notesonenote")
check("section name cleaned", OneNote.sectionName('Q3: "plans" & more?'), "Q3 plans more")
check("section name shortened", #OneNote.sectionName(string.rep("a", 80)), 50)
check("section name never empty", OneNote.sectionName("???"), "Notebook")
local json = dofile("tests/json.lua")
local body = OneNote.pageBody("Page 1", "PNGDATA", "2026-10-20T10:00:00Z")
check("page body is multipart", body.type:match("^multipart/form%-data; boundary=") ~= nil, true)
check("page body has the html", body.data:find('<title>Page 1</title>', 1, true) ~= nil, true)
check("page body has the image", body.data:find("PNGDATA", 1, true) ~= nil, true)
check("image tag names the part", body.data:find('src="name:page"', 1, true) ~= nil, true)
local upd = OneNote.updateBody("Page 2", "PNG2", json)
check("update replaces the image by its data-id", upd.data:find('"target":"#notes-page"', 1, true) ~= nil, true)

local nbo = { name = "Kitchen", pages = { { id = "pga" }, { id = "pgb" }, { id = "pgc" } } }
local plan = OneNote.plan(nbo, { pages = { pga = { id = "A", hash = "1", n = 1 }, pgb = { id = "B", hash = "x", n = 2 }, pgz = { id = "Z", hash = "1", n = 3 } } }, { "1", "2", "3" })
check("plan: new page created", table.concat(plan.create, ","), "3")
check("plan: changed page updated", table.concat(plan.update, ","), "2")
check("plan: deleted page deleted", table.concat(plan.delete, ","), "Z")
local moved = OneNote.plan(nbo, { pages = { pga = { id = "A", hash = "1", n = 2 }, pgb = { id = "B", hash = "2", n = 1 }, pgc = { id = "C", hash = "3", n = 3 } } }, { "1", "2", "3" })
check("plan: reordered pages retitled", table.concat(moved.update, ","), "1,2")

local calls = {}
local graphPages = { G1 = true }
local fake = function(method, url, headers, data)
    table.insert(calls, method .. " " .. url:gsub("https://graph.microsoft.com/v1.0", ""))
    if url:find("/oauth2/") then return 200, json.encode({ access_token = "t", refresh_token = "r", expires_in = 3600 }) end
    if url:find("/sections%?") then return 200, json.encode({ value = { { id = "S1", displayName = "Kitchen" } } }) end
    if method == "POST" and url:find("/pages$") then
        local id = "P" .. #calls
        graphPages[id] = true
        return 201, json.encode({ id = id })
    end
    if method == "PATCH" then
        local id = url:match("/pages/(.-)/content")
        if graphPages[id] then return 204, "" end
        return 404, json.encode({ error = { code = "20102", message = "gone" } })
    end
    if method == "DELETE" then return 204, "" end
    return 500, ""
end
local tokens = { refresh_token = "r" }
local api = OneNote.new{ tokens = { get = function(k) return tokens[k] end, set = function(k, v) tokens[k] = v end, save = function() end },
    clientId = "app", request = fake, json = json, now = function() return 1000 end }
local sent = { section = "S1", pages = { pga = { id = "G1", hash = "old", n = 1 }, pgb = { id = "G2", hash = "2", n = 2 }, pgq = { id = "G9", hash = "9", n = 9 } } }
local counts = api:send(nbo, { oneNoteNotebook = "N1", sent = sent, hash = function(page) return ({ pga = "1", pgb = "2", pgc = "3" })[page.id] end,
    png = function(i) return "PNG" .. i end })
check("send: counts", counts and string.format("%d/%d/%d", counts.created, counts.updated, counts.deleted), "1/1/1")
check("send: first page updated in place", sent.pages.pga.id, "G1")
check("send: new page kept", sent.pages.pgc.id ~= nil, true)
check("send: deleted page forgotten", sent.pages.pgq, nil)
check("send: time kept", sent.at, 1000)
graphPages.G1 = nil   -- deleted in OneNote by hand
nbo.pages[1].changed = true
sent.pages.pga.hash = "older"
counts = api:send(nbo, { oneNoteNotebook = "N1", sent = sent, hash = function(page) return ({ pga = "1", pgb = "2", pgc = "3" })[page.id] end,
    png = function(i) return "PNG" .. i end })
check("send: a page gone from OneNote is made again", counts and counts.created, 1)
check("send: and remembered", sent.pages.pga.id ~= "G1", true)
counts = api:send(nbo, { oneNoteNotebook = "N1", sent = sent, hash = function(page) return ({ pga = "1", pgb = "2", pgc = "3" })[page.id] end,
    png = function(i) return "PNG" .. i end })
check("send: nothing changed, nothing sent", counts and (counts.created + counts.updated + counts.deleted), 0)

-- Where a notebook goes: its own choice, its folder's (or a folder above), else the default.
do
    local parent = function(p) return p:match("^(.*)/[^/]*$") or "" end
    local targets = { ["n:nb1"] = { nb = { id = "W", name = "Work" }, sec = { id = "S9", name = "Meetings" } },
        ["f:Work"] = { nb = { id = "W", name = "Work" } } }
    local def = { id = "D", name = "Kindle Scribe" }
    check("onenote target: the notebook's own", OneNote.targetFor(targets, "nb1", "Work", parent, def).sec.id, "S9")
    local t, from = OneNote.targetFor(targets, "nb2", "Work/2026", parent, def)
    check("onenote target: a folder's above", t.nb.id .. "|" .. tostring(from), "W|folder")
    check("onenote target: else the default", OneNote.targetFor(targets, "nb3", "Home", parent, def).nb.id, "D")
    check("onenote target: nothing set", OneNote.targetFor({}, "nb3", "", parent, nil), nil)
    local mv = OneNote.moveTargets({ ["f:Work"] = 1, ["f:Work/2026"] = 2, ["f:Workshop"] = 3, ["n:nb1"] = 4 }, "Work", "Jobs")
    check("onenote target: moves with its folder", tostring(mv["f:Jobs"]) .. tostring(mv["f:Jobs/2026"]) .. tostring(mv["f:Workshop"])
        .. tostring(mv["f:Work"]) .. tostring(mv["n:nb1"]), "123nil4")
    -- A section chosen: pages go there, titled with the notebook's name; a section gone is explained.
    local seen = {}
    local api2 = OneNote.new{ tokens = { get = function(k) return tokens[k] end, set = function(k, v) tokens[k] = v end, save = function() end },
        clientId = "app", json = json, now = function() return 1000 end,
        request = function(method, url, headers, data)
            local u = url:gsub("https://graph.microsoft.com/v1.0", "")
            table.insert(seen, { method .. " " .. u, type(data) == "table" and data.data or data })
            if u:find("^/me/onenote/sections/S9%?") then return 200, json.encode({ id = "S9" }) end
            if u:find("^/me/onenote/sections/GONE%?") then return 404, json.encode({ error = { message = "gone" } }) end
            return fake(method, url, headers, data)
        end }
    local s2 = {}
    local c2 = api2:send(nbo, { oneNoteNotebook = "W", sectionId = "S9", titlePrefix = "Kitchen", sent = s2,
        hash = function(page) return page.id end, png = function(i) return "PNG" .. i end })
    local into, titled = false, false
    for __, c in ipairs(seen) do
        if c[1]:find("POST /me/onenote/sections/S9/pages", 1, true) then into = true end
        if type(c[2]) == "string" and c[2]:find("Kitchen – Page 1", 1, true) then titled = true end
    end
    check("onenote: into the section chosen", c2 ~= nil and into and s2.section == "S9", true)
    check("onenote: pages titled with the notebook's name", titled, true)
    local c3, why3 = api2:send(nbo, { oneNoteNotebook = "W", sectionId = "GONE", sent = {},
        hash = function(page) return page.id end, png = function(i) return "PNG" .. i end })
    check("onenote: a section gone is explained", c3 == nil and tostring(why3):find("gone", 1, true) ~= nil, true)
end

-- Shapes.
local Shapes = require("notesshapes")
local function path(fn, n)
    local p = {}
    for i = 0, n do
        local x, y = fn(i / n)
        table.insert(p, math.floor(x + 0.5))
        table.insert(p, math.floor(y + 0.5))
    end
    return p
end
local function wobble(t) return 3 * math.sin(t * 37) end
check("rectangle shape closes", (function() local r = Shapes.make("rect", 10, 10, 110, 60, 3)[1].p return r[1] == r[#r - 1] and r[2] == r[#r] end)(), true)
check("arrow has a head", #Shapes.make("arrow", 0, 0, 100, 0, 3), 2)
check("table of 3 x 4: box and lines", #Shapes.make("table", 0, 0, 300, 200, 2, nil, { rows = 3, cols = 4 }), 1 + 2 + 3)
check("shapes keep the tip", Shapes.make("star", 0, 0, 100, 100, 3, "pencil")[1].t, "pencil")

local x, y = Shapes.lockAngle(0, 0, 200, 9)
check("near level becomes level", x .. "," .. y, "200,0")
x, y = Shapes.lockAngle(0, 0, 100, 104)
check("near 45 degrees becomes 45", x == y, true)
x, y = Shapes.lockAngle(0, 0, 100, 30)
check("clearly sloped stays", x .. "," .. y, "100,30")
x, y = Shapes.snapPoint(103, 52, { { w = 2, p = { 100, 50, 100, 150 } } }, 10)
check("end joins a corner nearby", x .. "," .. y, "100,50")
x, y = Shapes.snapPoint(140, 52, { { w = 2, p = { 100, 50, 100, 150 } } }, 10)
check("end far away stays", x .. "," .. y, "140,52")

local r = Shapes.recognize(path(function(t) return 50 + 300 * t, 100 + wobble(t) end, 40))
check("rough line recognised", r and r.kind, "line")
r = Shapes.recognize(path(function(t) local a = t * 2 * math.pi return 200 + 80 * math.cos(a) + wobble(t), 200 + 80 * math.sin(a) end, 60))
check("rough circle recognised", r and r.kind, "ellipse")
check("circle made round", r and r.rx == r.ry, true)
r = Shapes.recognize(path(function(t)
    -- a rectangle 200 x 100 drawn from the middle of its top side
    local d = (t * 600 + 100) % 600
    if d < 200 then return 100 + d, 100 + wobble(t) end
    if d < 300 then return 300 + wobble(t), 100 + (d - 200) end
    if d < 500 then return 300 - (d - 300), 200 + wobble(t) end
    return 100 + wobble(t), 200 - (d - 500)
end, 120))
check("rough rectangle recognised", r and r.kind, "rect")
r = Shapes.recognize(path(function(t)
    local d = t * 3
    local A, B, C = { 200, 100 }, { 300, 260 }, { 100, 260 }
    local P, Q
    if d < 1 then P, Q = A, B elseif d < 2 then P, Q, d = B, C, d - 1 else P, Q, d = C, A, d - 2 end
    return P[1] + (Q[1] - P[1]) * d + wobble(t), P[2] + (Q[2] - P[2]) * d
end, 90))
check("rough triangle recognised", r and r.kind == "polygon" and #r.points, 6)
check("writing is left alone", Shapes.recognize(path(function(t) return 50 + 400 * t, 100 + 20 * math.sin(t * 40) end, 200)), nil)
check("a dot is left alone", Shapes.recognize({ 10, 10, 12, 11 }), nil)
local smooth = Shapes.smooth({ w = 3, p = { 0, 0, 10, 10, 20, 0, 30, 10, 40, 0 }, q = { 3, 3, 3, 3, 3 } }, 1)
check("smoothing keeps the ends", smooth.p[1] .. "," .. smooth.p[#smooth.p], "0,0")
check("smoothing evens the middle", smooth.p[4] < 10, true)

-- The notebook list from file starts, kept in an index.
local h = Store.header(Store.serialize({ id = "nb9", name = 'A "b"', created = 5, modified = 7, pages = { { strokes = {} }, { strokes = {} } } }))
check("header: name", h and h.name, 'A "b"')
check("header: pages", h and h.pages, 2)
check("header: older file has no count", Store.header("return {id=\"nb1\",name=\"x\",pages={}}"), nil)
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute((package.config:sub(1, 1) == "\\" and "mkdir " or "mkdir -p ") .. dir)
    local files, times, reads = {}, {}, 0
    local s = Store.new{ dir = dir, now = function() return 50 end,
        list = function() local out = {} for n in pairs(files) do table.insert(out, n) end return out end,
        stat = function(path) local n = path:match("([^/\\]+)$") return times[n] and { size = 1, modification = times[n] } end }
    local nb = s:create("Indexed", 100, 100)
    files[nb.id .. ".lua"] = true
    times[nb.id .. ".lua"] = 1
    local summary = s.summary
    s.summary = function(self, id) reads = reads + 1 return summary(self, id) end
    check("list reads a new file", (function() s:list() return reads end)(), 1)
    s:list()
    check("unchanged file not read again", reads, 1)
    times[nb.id .. ".lua"] = 2
    check("changed file read again", (function() local l = s:list() return reads .. ":" .. l[1].name end)(), "2:Indexed")
    s.index = nil   -- as if KOReader restarted: the index file is read back
    s:list()
    check("index kept on disk", reads, 2)
    s:delete(nb.id)
    os.remove(dir .. "/index.lua")
    os.remove(dir)
end

-- Notebooks made from a PDF.
local fromPdf = Store.parse(Store.serialize({ id = "nb7", name = "Sheet", pdf = "nb7.pdf",
    pages = { { id = "pg1", bg = 1, strokes = {} }, { id = "pg2", strokes = {} }, { id = "pg3", bg = 2, strokes = {} } } }))
check("pdf kept", fromPdf.pdf, "nb7.pdf")
check("pdf page kept", fromPdf.pages[1].bg, 1)
check("own page has no pdf page", fromPdf.pages[2].bg, nil)
check("pdf name checked", Store.parse("return { pdf = '../x.pdf', pages = {} }").pdf, nil)
check("no pdf, no pdf pages", Store.parse("return { pages = { { bg = 3, strokes = {} } } }").pages[1].bg, nil)
check("header still read with a pdf", Store.header(Store.serialize({ id = "nb7", name = "Sheet", pdf = "nb7.pdf", pages = { { strokes = {} } } })).name, "Sheet")
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute((package.config:sub(1, 1) == "\\" and "mkdir " or "mkdir -p ") .. dir)
    local src = dir .. "/source.pdf"
    local f = io.open(src, "wb") f:write("%PDF-1.4 pretend") f:close()
    local s = Store.new{ dir = dir, list = function() return {} end, now = function() return 77 end }
    local nb = s:createFromPDF("Sheet", src, 3, 100, 140)
    check("pdf notebook: a page per pdf page", nb and #nb.pages, 3)
    check("pdf notebook: pages point at the pdf", nb and nb.pages[3].bg, 3)
    local copy = io.open(dir .. "/" .. nb.pdf, "rb")
    check("pdf copied beside it", copy and copy:read("*a"), "%PDF-1.4 pretend")
    if copy then copy:close() end
    check("pdf path when read", s:read(nb.id).pdfPath, dir .. "/" .. nb.pdf)
    local dup = s:duplicate(nb.id, "Sheet 2")
    check("duplicate has its own pdf", dup and dup.pdf ~= nb.pdf and io.open(dir .. "/" .. dup.pdf, "rb") ~= nil, true)
    s:delete(nb.id)
    check("delete removes the pdf", io.open(dir .. "/" .. nb.pdf, "rb"), nil)
    s:delete(dup.id)
    os.remove(src)
    os.remove(dir)
end

-- New tips, shades, dashes, fills.
check("brush light touch is very thin", Ink.tipWidth("brush", 5, 0, 1) <= 3, true)
check("brush pressed is full", Ink.tipWidth("brush", 5, 1, 1), 26)
check("nib thin along its slant", Ink.nibWidth(20, math.cos(Ink.NIB_ANGLE) * 10, math.sin(Ink.NIB_ANGLE) * 10) <= 4, true)
check("nib full across it", Ink.nibWidth(20, -math.sin(Ink.NIB_ANGLE) * 10, math.cos(Ink.NIB_ANGLE) * 10), 20)
check("shader goes under", Ink.TIPS.shader.under, true)
check("a shade overrides the tip's grey", Ink.greyOf({ t = "pencil", c = 0x99 }), 0x99)
check("an older light shade shows as the new one", Ink.greyOf({ t = "pencil", c = 0xA8 }), 0xAA)
check("no shade: the tip's grey", Ink.greyOf({ t = "pencil" }), 0x44)
local on, off = Ink.dashes("dash", 4)
check("dashes have gaps", on > 0 and off > 0, true)
check("solid has no dashes", Ink.dashes(nil, 4), nil)
local dashed = 0
Ink.dashedSegment(0, 0, 100, 0, 2, 10, 10, 0, function() dashed = dashed + 1 end)
local solid = 0
Ink.segment(0, 0, 100, 0, 2, function() solid = solid + 1 end)
check("a dashed line stamps about half", dashed > solid * 0.3 and dashed < solid * 0.7, true)
local rows = 0
Ink.fillPolygon({ 0, 0, 10, 0, 10, 10, 0, 10 }, function(y, a, b) rows = rows + 1 check("fill row inside", a >= 0 and b <= 10, true) end)
check("fill covers the square's rows", rows >= 10, true)
local styled = Store.parse(Store.serialize({ id = "nb8", name = "s", pages = { { strokes = {
    { t = "calligraphy", c = 96, d = "dash", f = 216, w = 4, p = { 1, 2, 3, 4 } } } } } })).pages[1].strokes[1]
check("tip, shade, dash and fill saved", table.concat({ styled.t, styled.c, styled.d, styled.f }, ","), "calligraphy,96,dash,216")
check("transform keeps the style", Ink.transform(styled, 0, 0, 2, 0, 0).d, "dash")

-- Page items, bookmarks, templates.
local withItems = Store.parse(Store.serialize({ id = "nb9", name = "i", paper = "tasks", pages = { { star = true, strokes = {}, items = {
    { k = "text", x = 10, y = 20, w = 300, size = 54, text = 'Say "hi"\nthen go' },
    { k = "image", x = 1, y = 2, w = 30, h = 40, file = "img123.png" },
    { k = "tape", x = 5, y = 6, w = 70, h = 8, open = true } } } } }))
check("template kept", withItems.paper, "tasks")
check("bookmark kept", withItems.pages[1].star, true)
check("text box kept", withItems.pages[1].items[1].text, 'Say "hi"\nthen go')
check("picture kept", withItems.pages[1].items[2].file, "img123.png")
check("tape kept", withItems.pages[1].items[3].open, true)
check("bad picture name dropped", #(Store.parse("return { pages = { { strokes = {}, items = { { k = 'image', x = 1, y = 1, w = 2, h = 2, file = '../x.png' } } } } }").pages[1].items or {}), 0)

-- Claude's tasks.
local tasks = require("notesclaude").parseTasks('```json\n{"tasks":[{"title":" Call Vet ","done":false,"steps":[{"title":"Ask about shots","done":true},{"title":""}]},{"title":"","steps":[]}]}\n```', json)
check("tasks read", tasks and #tasks, 1)
check("task title trimmed", tasks and tasks[1].title, "Call Vet")
check("steps read, empty dropped", tasks and #tasks[1].steps, 1)
check("step done", tasks and tasks[1].steps[1].done, true)
check("not tasks", require("notesclaude").parseTasks("sorry", json), nil)
local dated = require("notesclaude").parseTasks('{"tasks":[{"title":"Vet","due":"2026-10-24","remind":"2026-10-23T15:30","steps":[]},'
    .. '{"title":"Gym","remind":"2026-10-25","steps":[]},{"title":"Bad","due":"Friday","remind":"soon","steps":[]}]}', json)
check("due read", dated[1].due, "2026-10-24")
check("reminder day", dated[1].remind.date, "2026-10-23")
check("reminder minute", dated[1].remind.minute, 15 * 60 + 30)
check("reminder without a time: 9 AM", dated[2].remind.minute, 9 * 60)
check("not a date: none", dated[3].due == nil and dated[3].remind == nil, true)

-- Markdown into a PDF.
local MdPdf = require("notesmdpdf")
check("winansi keeps accents", MdPdf.winAnsi("café"), "caf\233")
check("winansi curly quotes and dashes", MdPdf.winAnsi("\226\128\156a\226\128\157 \226\128\148"), "\147a\148 \151")
check("winansi unknown is ?", MdPdf.winAnsi("\226\152\131"), "?")
local pdf, npages = MdPdf.render("# Kitchen project\n\nOrder **countertop** samples\n- [x] Measure the window wall\n- [ ] Ask Dad about (the) vent hood\n1. Budget\n> Note\n---\n| a | b |\n|---|---|\n| 1 | 2 |", "Kitchen")
check("pdf header", pdf:sub(1, 8), "%PDF-1.4")
check("one page", npages, 1)
check("text escaped", pdf:find("Ask Dad about \\(the\\) vent hood", 1, true) ~= nil, true)
check("bold marks removed", pdf:find("**", 1, true) == nil and pdf:find("countertop", 1, true) ~= nil, true)
local runs = MdPdf.runs("Plain **bold** and *italic* and ***both*** snake_case 2*3")
check("runs: plain", runs[1].text, "Plain ")
check("runs: bold", runs[2].bold and runs[2].text, "bold")
check("runs: italic", runs[4].italic and not runs[4].bold and runs[4].text, "italic")
check("runs: both", runs[6].bold and runs[6].italic and runs[6].text, "both")
check("runs: snake_case and 2*3 untouched", runs[7].text, " snake_case 2*3")
local styledPdf = MdPdf.render("Plain **bold words** here", "S")
check("pdf: bold font used", styledPdf:find("/F2 11 Tf ( bold words) Tj", 1, true) ~= nil, true)
check("pdf: back to regular", styledPdf:find("/F1 11 Tf ( here) Tj", 1, true) ~= nil, true)
local xrefAt = tonumber(pdf:match("startxref\n(%d+)"))
check("startxref points at xref", pdf:sub(xrefAt + 1, xrefAt + 4), "xref")
local firstObj = tonumber(pdf:match("xref\n0 %d+\n0000000000 65535 f \n(%d+)"))
check("xref offset of object 1", pdf:sub(firstObj + 1, firstObj + 7), "1 0 obj")
local long = {}
for i = 1, 120 do long[i] = "Line " .. i .. " of a long note that goes on" end
local __, many = MdPdf.render(table.concat(long, "\n"), "Long")
check("long notes go over pages", many > 1, true)

-- Drawings from Claude (SVG) into ink.
local Svg = require("notessvg")
local d = Svg.parse([[Here you go:
```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">
  <rect x="10" y="10" width="80" height="40" fill="none" stroke="black" stroke-width="2"/>
  <line x1="90" y1="30" x2="150" y2="30" stroke="black" stroke-dasharray="4 2"/>
  <g transform="translate(150,0)"><circle cx="20" cy="30" r="15" fill="#ccc" stroke="black"/></g>
  <path d="M10 80 C 40 60, 60 100, 90 80 L 100 90 Z" stroke="black" fill="none"/>
  <text x="20" y="35" font-size="12" text-anchor="start">Start &amp; go</text>
</svg>
```]])
check("svg read", d ~= nil, true)
check("svg viewBox", d and (d.w .. "x" .. d.h), "200x100")
check("svg shapes", d and #d.lines, 4)
check("rect closed", d and d.lines[1].closed, true)
check("rect no fill", d and d.lines[1].fill, nil)
check("dashed line", d and d.lines[2].dashed, true)
check("group moves the circle", d and d.lines[3].p[1] > 150, true)
check("grey fill", d and d.lines[3].fill, Svg.grey("#ccc"))
check("curve has points", d and #d.lines[4].p > 20, true)
check("path closed by Z", d and d.lines[4].closed, true)
check("text read and unescaped", d and d.texts[1].text, "Start & go")
check("no svg", Svg.parse("I can't draw that"), nil)
local cut = Svg.parse('<svg viewBox="0 0 100 100"><rect x="1" y="1" width="10" height="10" stroke="black" fill="none"/><line x1="0" y1="0" x2="5')
check("an answer cut short keeps what is whole", cut and #cut.lines, 1)
local strokes, texts = Svg.place(d, { 1000, 500, 400, 200 }, 3)
check("placed: one stroke per shape", #strokes, 4)
check("placed inside the box", strokes[1].p[1] >= 1000 and strokes[1].p[1] <= 1400 and strokes[1].p[2] >= 500, true)
check("placed scaled", strokes[1].p[3] - strokes[1].p[1], 160)
check("placed widths at least the pen's", strokes[1].w >= 3, true)
check("placed dashes", strokes[2].d, "dash")
check("placed text box", texts[1] and texts[1].k, "text")
local arcs = Svg.parse('<svg viewBox="0 0 100 100"><path d="M10 50 A 40 40 0 0 1 90 50" stroke="black" fill="none"/></svg>')
check("arc becomes a curve", arcs and #arcs.lines[1].p > 10, true)
check("arc reaches its end", arcs and math.floor(arcs.lines[1].p[#arcs.lines[1].p - 1] + 0.5), 90)

-- The pen taken away (BTN_TOOL_PEN 0): no tool any more; the eraser end likewise.
do
    local P = require("notespen")
    local st = P.newState()
    P.parse(st, 1, 320, 1, 0)
    check("pen near: its tool", st.tool, "pen")
    P.parse(st, 1, 320, 0, 0)
    check("pen away: no tool", st.tool, nil)
    P.parse(st, 1, 321, 1, 0)
    P.parse(st, 1, 321, 0, 0)
    check("eraser end away: no tool", st.tool, nil)
    P.parse(st, 1, 321, 1, 0)
    P.parse(st, 1, 320, 0, 0)
    check("the pen's end going doesn't drop the eraser", st.tool, "rubber")
end

-- OneNote on the launcher's shared Microsoft account.
do
    local granted, signed = "openid Tasks.ReadWrite offline_access", true
    local acct = {
        signedIn = function() return signed end,
        allowed = function(sc) return granted:find(sc, 1, true) ~= nil end,
        accessToken = function() return "tok-shared" end,
    }
    local one = OneNote.new{ tokens = { get = function() return "own-refresh" end }, json = json, account = acct }
    check("shared account: To Do's sign-in alone isn't OneNote's", one:signedIn(), false)
    check("shared account: sign in again to allow OneNote", one:needsAllow(), true)
    granted = granted .. " Notes.ReadWrite"
    check("shared account: allowed, signed in", one:signedIn(), true)
    check("shared account: allowed, nothing more to do", one:needsAllow(), false)
    check("shared account: its token", one:accessToken(), "tok-shared")
    signed = false
    check("shared account: signed out", one:signedIn(), false)
    check("own sign-in without the launcher", OneNote.new{ tokens = { get = function() return "r" end }, json = json }:signedIn(), true)
end

-- OneNote: typed text under the image.
check("text paragraph escapes and breaks lines", OneNote.textTag("a < b\nc & d\n"), '<p data-id="notes-text">a &lt; b<br/>c &amp; d</p>')
check("page body carries text", OneNote.pageBody("Page 1", "P", nil, "hello").data:find("notes-text", 1, true) ~= nil, true)
check("text appended the first time", OneNote.updateBody("Page 1", "P", json, "hi", false).data:find('"action":"append"', 1, true) ~= nil, true)
check("text replaced after", OneNote.updateBody("Page 1", "P", json, "hi", true).data:find('"target":"#notes-text"', 1, true) ~= nil, true)
check("no text, no paragraph", OneNote.updateBody("Page 1", "P", json, nil, false).data:find("notes-text", 1, true), nil)

-- Puzzle books: the zoom box and pages' done and hidden marks kept.
local book = Store.parse(Store.serialize({ id = "nb2", name = "Puzzles", pdf = "nb2.pdf", puzzle = true,
    zbox = { 240, 110, 760, 770 }, pages = { { bg = 1, done = true, strokes = {} }, { bg = 2, hide = true, strokes = {} },
    { bg = 3, strokes = {} } } }))
check("puzzle book kept", book.puzzle, true)
check("zoom box kept", table.concat(book.zbox, ","), "240,110,760,770")
check("done kept", book.pages[1].done, true)
check("hidden kept", book.pages[2].hide, true)
check("plain page", book.pages[3].done == nil and book.pages[3].hide == nil, true)
check("puzzle needs a PDF", Store.parse("return { puzzle = true, pages = {} }").puzzle, nil)
check("bad zoom box dropped", Store.parse("return { pdf = 'nb3.pdf', puzzle = true, zbox = { 1, 2, 0, 4 }, pages = {} }").zbox, nil)
check("puzzle book header", Store.header(Store.serialize(book)).pages, 3)
check("puzzle book header: a puzzle book", Store.header(Store.serialize(book)).puzzle, book.puzzle == true and book.pdf ~= nil)

-- A finger filed in the pen's slot.
local PenM = require("notespen")
check("pen contact is the pen", PenM.isFinger({ id = 4 }, 4), false)
check("pen lifted is the pen", PenM.isFinger({ id = -1 }, 4), false)
check("panel tracking id is a finger", PenM.isFinger({ id = 317 }, 4), true)
check("no pen slot known: the pen", PenM.isFinger({ id = 317 }, nil), false)

-- The trash.
do
    local tdir = os.tmpname()
    os.remove(tdir)
    os.execute((package.config:sub(1, 1) == "\\" and "mkdir " or "mkdir -p ") .. tdir)
    local now = 1000
    local ts = Store.new{ dir = tdir, now = function() return now end, list = function() return {} end,
        mkdir = function(p)
            if package.config:sub(1, 1) == "\\" then os.execute('mkdir "' .. p:gsub("/", "\\") .. '"') else os.execute("mkdir -p " .. p) end
        end }
    local nb = ts:create("Old list", 100, 100)
    check("to the trash", ts:trash(nb.id, "Work"), true)
    check("file gone from the notebooks", io.open(ts:path(nb.id), "rb"), nil)
    check("listed in the trash", #ts:trashList() .. "|" .. ts:trashList()[1].name .. "|" .. ts:trashList()[1].folder, "1|Old list|Work")
    check("restored to its folder", ts:restore(nb.id), "Work")
    check("back with the notebooks", ts:read(nb.id) ~= nil, true)
    ts:trash(nb.id, "")
    ts.trashed = nil   -- read the index from its file again
    check("trash kept in its file", #ts:trashList(), 1)
    now = now + 29 * 86400
    ts:emptyTrash()
    check("kept under 30 days", #ts:trashList(), 1)
    now = now + 2 * 86400
    ts:emptyTrash()
    check("emptied after 30 days", #ts:trashList(), 0)
end

-- Folders.
local Folders = require("notesfolders")
local fpath = os.tmpname()
os.remove(fpath)
local fo = Folders.open(fpath)
check("no folders at first", #fo:all(), 0)
fo:set("nb1", "Work/Clients")
fo:set("nb2", "Work")
fo:add("Home")
check("folders with their parents", table.concat(fo:all(), ","), "Home,Work,Work/Clients")
check("top level children", table.concat(fo:children(""), ","), "Home,Work")
check("subfolders", table.concat(fo:children("Work"), ","), "Work/Clients")
check("notebook's folder", fo:of("nb1"), "Work/Clients")
check("top level notebook", fo:of("nb3"), "")
check("inside a folder and its subfolders", #fo:inside("Work", { "nb1", "nb2", "nb3" }), 2)
check("name and parent", Folders.name("Work/Clients") .. "|" .. Folders.parent("Work/Clients") .. "|" .. Folders.parent("Work"), "Clients|Work|")
check("clean name", Folders.clean("  a/b  "), "a-b")
check("empty name", Folders.clean("   "), nil)
check("can't move a folder into itself", fo:rename("Work", "Work/Clients/Work"), false)
check("rename onto an existing folder refused", fo:rename("Work", "Home"), false)
check("rename", fo:rename("Work", "Home/Work"), true)
check("notebooks follow", fo:of("nb1") .. "|" .. fo:of("nb2"), "Home/Work/Clients|Home/Work")
check("saved", fo:save(), true)
local fo2 = Folders.open(fpath)
check("read back", table.concat(fo2:all(), ","), "Home,Home/Work,Home/Work/Clients")
check("read back notebooks", fo2:of("nb1"), "Home/Work/Clients")
local kept = fo2:remove("Home/Work", "Home")
check("remove keeping notebooks", #kept .. "|" .. fo2:of("nb1") .. "|" .. fo2:of("nb2"), "0|Home|Home")
check("subfolders removed too", table.concat(fo2:all(), ","), "Home")
local gone = fo2:remove("Home", nil)
check("remove with notebooks", #gone .. "|" .. fo2:of("nb1"), "2|")
-- Folder covers: kept, moved with a renamed folder, gone with a removed one.
do
    local cpath = fpath .. ".covers"
    local fc = Folders.open(cpath)
    fc:add("Work/Clients")
    fc:setCover("Work", "icon:briefcase")
    fc:setCover("Work/Clients", "nb:nb123")
    fc:setCover("Work", "icon:../x")
    check("a bad cover is not kept", fc:cover("Work"), nil)
    fc:setCover("Work", "icon:briefcase")
    check("covers saved", fc:save(), true)
    local fc2 = Folders.open(cpath)
    check("covers read back", tostring(fc2:cover("Work")) .. "|" .. tostring(fc2:cover("Work/Clients")), "icon:briefcase|nb:nb123")
    fc2:rename("Work", "Job")
    check("cover follows a rename", tostring(fc2:cover("Job")) .. "|" .. tostring(fc2:cover("Job/Clients")) .. "|" .. tostring(fc2:cover("Work")),
        "icon:briefcase|nb:nb123|nil")
    fc2:remove("Job", "")
    check("covers go with the folder", fc2:cover("Job") == nil and fc2:cover("Job/Clients") == nil, true)
    fc2:setCover("Home", nil)
    check("back to automatic", fc2:cover("Home"), nil)
    os.remove(cpath)
end
check("a notebook within the top level", Folders.within("Home", ""), true)
check("not within a sibling", Folders.within("Homework", "Home"), false)
os.remove(fpath)

-- Saving reuses a stroke's text only while the stroke is unchanged.
do
    local st = { w = 3, p = { 1, 2, 3, 4 } }
    local nb = { id = "nb1", name = "K", pages = { { id = "pg1", strokes = { st } } } }
    local first = Store.serialize(nb)
    check("same text again", Store.serialize(nb), first)
    table.insert(st.p, 5) table.insert(st.p, 6)
    check("a stroke that grew", Store.serialize(nb):find("p={1,2,3,4,5,6}", 1, true) ~= nil, true)
    st.c = 120
    check("a stroke's shade changed", Store.serialize(nb):find("c=120,", 1, true) ~= nil, true)
    st.q = { 2, 2, 2 }
    check("widths added", Store.serialize(nb):find("q={2,2,2}", 1, true) ~= nil, true)
    check("reads back", #Store.parse(Store.serialize(nb)).pages[1].strokes[1].p, 6)
end

-- A page's own template, its date, and deleted pages kept 30 days.
do
    local now = os.time()
    local nb = { id = "nb9", name = "P", paper = "narrow", pages = {
        { id = "pg1", paper = "grid", created = now - 100, strokes = {} },
        { id = "pg2", strokes = {} },
    }, deleted = {
        { at = now - 3600, index = 2, page = { id = "pg3", paper = "dots", strokes = { { w = 3, p = { 1, 2, 3, 4 } } } } },
        { at = now - 40 * 86400, index = 1, page = { id = "pg4", strokes = {} } },
    } }
    local back = Store.parse(Store.serialize(nb))
    check("a page's own template kept", back.pages[1].paper, "grid")
    check("the other page has the notebook's", tostring(back.pages[2].paper), "nil")
    check("a page's date kept", back.pages[1].created, now - 100)
    check("a deleted page kept", back.deleted and #back.deleted, 1)
    check("its ink and place", #back.deleted[1].page.strokes .. "|" .. back.deleted[1].index .. "|" .. back.deleted[1].page.paper, "1|2|dots")
    check("one deleted 40 days ago is gone", back.deleted[1].page.id, "pg3")
    local bad = Store.parse(Store.serialize({ id = "nb9", name = "P", paper = "narrow", pages = { { id = "pg1", paper = "../x", strokes = {} } } }))
    check("a bad page template is dropped", tostring(bad.pages[1].paper), "nil")
    check("new templates allowed", Store.parse(Store.serialize({ id = "nb9", name = "P", paper = "hex", pages = { { id = "pg1", paper = "calendar", strokes = {} } } })).pages[1].paper, "calendar")
end

-- Reading OneNote: a page's parts, its handwriting, text and layout.
do
    local ON = require("notesonenote")
    local body = "--Part7\r\nContent-Type: text/html\r\n\r\n<html>page</html>\r\n--Part7\r\nContent-Type: application/inkml+xml\r\n\r\n<ink/>\r\n--Part7--\r\n"
    local parts = ON.multipart(body)
    check("multipart parts", #parts, 2)
    check("multipart html", parts[1].type .. "|" .. parts[1].body, "text/html|<html>page</html>")
    check("multipart inkml", parts[2].type, "application/inkml+xml")
    check("not multipart", ON.multipart("<html></html>"), nil)
    local ink = [[<inkml:ink><inkml:definitions><inkml:context xml:id="c"><inkml:inkSource><inkml:traceFormat>
<inkml:channel name="X" type="integer" max="32767" units="himetric" /></inkml:traceFormat></inkml:inkSource></inkml:context>
<inkml:brush xml:id="{a}{1}"><inkml:brushProperty name="width" value="50" units="himetric" />
<inkml:brushProperty name="color" value="#808080" /><inkml:brushProperty name="transparency" value="0" /></inkml:brush>
</inkml:definitions><inkml:traceGroup>
<inkml:trace xml:id="t1" contextRef="#c" brushRef="#{a}{1}">2540 2540 100, 5080 2540 200</inkml:trace>
<inkml:trace xml:id="t2" contextRef="#c" brushRef="#{a}{1}">2540 0, '254 0, '254 0</inkml:trace>
</inkml:traceGroup></inkml:ink>]]
    local st = ON.inkStrokes(ink)
    check("ink strokes (not the trace format or group)", #st, 2)
    check("himetric to CSS pixels", math.floor(st[1].p[1] + 0.5) .. "," .. math.floor(st[1].p[3] + 0.5), "96,192")
    check("brush grey and width", st[1].grey .. "|" .. math.floor(st[1].w * 10 + 0.5), "128|19")
    check("first differences", math.floor(st[2].p[5] * 10 + 0.5), math.floor((2540 + 508) / (2540 / 96) * 10 + 0.5))
    check("nested lists indented", ON.htmlText("<ul><li><p>A</p><ul><li>B</li></ul></li><li>C &amp; D&#8217;s</li></ul>"),
        "• A\n    • B\n• C & D\226\128\153s")
    local L = ON.layout([[<html><head><title>T&#65532;itle</title></head><body style="font-size:11pt">
<div style="position:absolute;left:48px;top:115px;width:600px"><p>One</p><p>Two</p></div>
<img style="position:absolute;left:10px;top:300px" width="200" height="100" src="https://x/1" data-fullres-src="https://x/1full" />
</body></html>]])
    check("layout text", #L.texts .. "|" .. L.texts[1].x .. "," .. L.texts[1].y .. "," .. L.texts[1].w .. "|" .. L.texts[1].text, "1|48,115,600|One\nTwo")
    check("layout picture", #L.images .. "|" .. L.images[1].src .. "|" .. L.images[1].y, "1|https://x/1full|300")
    local R = ON.readableHtml('<html><body><div style="position:absolute;left:5px;width:600px;font-weight:bold">Hi</div><img src="https://x/1" width="50"/></body></html>',
        { ["https://x/1"] = "img1.png" }, true)
    check("readable: no fixed places", R:find("position", 1, true), nil)
    check("readable: bold kept", R:find("font-weight:bold", 1, true) ~= nil, true)
    check("readable: local picture", R:find('src="img1.png"', 1, true) ~= nil, true)
    check("readable: handwriting note", R:find("handwriting", 1, true) ~= nil, true)
    local B = ON.pagesBody("Shop", { "PNG1", "PNG2" }, "2024-03-05T00:07:00")
    check("pictures page: two images", select(2, B.data:gsub('src="name:page%d"', "")), 2)
    check("pictures page: parts", B.data:find('name="page2"', 1, true) ~= nil and B.data:find("2024-03-05T00:07:00", 1, true) ~= nil, true)
end

-- Pencil shades, pen pressure feel, the highlighter.
do
    local Ink = require("notesink")
    check("pencil darker is black", Ink.tipShade("pencil", "dark"), 0x00)
    check("pencil lighter", Ink.tipShade("pencil", "light"), 0x88)
    check("pencil shades apart from its own", math.abs(Ink.tipShade("pencil", "dark") - Ink.TIPS.pencil.grey) >= 0x44, true)
    check("pen dark grey", Ink.tipShade("pen", "dark"), Ink.SHADES.dark)
    check("own shade", Ink.tipShade("pencil", "default"), nil)
    check("soft feel: wider for a light touch", Ink.feel(0.25, "soft") > 0.25, true)
    check("firm feel: thinner for a light touch", Ink.feel(0.25, "firm") < 0.25, true)
    check("normal feel unchanged", Ink.feel(0.25, "normal"), 0.25)
    check("highlighter is a highlight", Ink.isHighlight({ t = "hl" }), true)
    check("pencil is not", Ink.isHighlight({ t = "pencil" }), false)
end

-- Folders sorted with the notebooks; when each was made.
do
    local Folders = require("notesfolders")
    local f = Folders.open("/nonexistent/folders.lua")
    f:add("Work", 100)
    f:add("Home/Kitchen", 200)
    f:add("Work", 999)   -- already there: keeps its time
    check("folder made: its time", f.created.Work .. "|" .. f.created.Home .. "|" .. f.created["Home/Kitchen"], "100|200|200")
    local info = { Work = { created = 100, modified = 50 }, Home = { created = 200, modified = 10 }, Art = { created = 150, modified = 70 } }
    local function of(p) return info[p] end
    local list = { "Work", "Home", "Art" }
    check("folders by name", table.concat(Folders.sorted(list, "name", of), ","), "Art,Home,Work")
    check("folders by date created", table.concat(Folders.sorted(list, "created", of), ","), "Home,Art,Work")
    check("folders by date modified", table.concat(Folders.sorted(list, "modified", of), ","), "Art,Work,Home")
    check("my order: folders by name", table.concat(Folders.sorted(list, "custom", of), ","), "Art,Home,Work")
    f:rename("Home", "House")
    check("renamed folder keeps its time", tostring(f.created.House) .. tostring(f.created.Home), "200nil")
    f:remove("House", "")
    check("removed folder forgotten", tostring(f.created.House) .. tostring(f.created["House/Kitchen"]), "nilnil")
end

-- Tidying handwriting: level, upright, even size and spacing.
do
    local Tidy = require("notestidy")
    -- A "word": up-down strokes (letters) leaning right by `lean` (dx per
    -- dy, "/" negative), its baseline at `base`, `n` letters `size` tall.
    local function word(x, base, n, size, lean)
        local p = {}
        for i = 0, n - 1 do
            local lx = x + i * size * 0.6
            for k = 0, 10 do
                local y = base - size * (k <= 5 and k / 5 or (10 - k) / 5)
                table.insert(p, math.floor(lx + (k / 10) * size * 0.4 + lean * (y - base) + 0.5))
                table.insert(p, math.floor(y + 0.5))
            end
        end
        return { w = 3, p = p }
    end
    local strokes = {
        word(100, 500, 4, 40, -0.4),   -- leaning, on a tilted line
        word(300, 520, 3, 40, -0.4),
        word(560, 545, 5, 40, -0.4),
        word(100, 800, 3, 40, 0),       -- another line
        { t = "hl", w = 30, p = { 100, 480, 700, 480 } },
    }
    local function bottom(s) local b = -math.huge for i = 2, #s.p, 2 do b = math.max(b, s.p[i]) end return b end
    local skip = function(s) return s.t == "hl" end
    check("tidy: two lines, three words in the first", (function()
        local lines = Tidy.lines(strokes, skip)
        return #lines .. "|" .. #lines[1].words
    end)(), "2|3")
    local out, moved = Tidy.apply(strokes, { level = true }, { skip = skip })
    check("tidy level: words moved", moved >= 2, true)
    check("tidy level: one baseline", math.abs(bottom(out[1]) - bottom(out[3])) <= 3, true)
    check("tidy level: highlighter left", out[5] == strokes[5], true)
    local up = Tidy.apply(strokes, { upright = true }, { skip = skip })
    local t0 = Tidy.slant({ strokes = { 1 } }, { strokes[1].p })
    local t1 = Tidy.slant({ strokes = { 1 } }, { up[1].p })
    check("tidy upright: less lean", math.abs(t1) < math.abs(t0) / 2, true)
    check("tidy upright: an upright word left", up[4] == strokes[4], true)
    local sp = Tidy.apply(strokes, { space = true }, { skip = skip })
    local function box(s) local a, b = math.huge, -math.huge for i = 1, #s.p - 1, 2 do a = math.min(a, s.p[i]) b = math.max(b, s.p[i]) end return a, b end
    local a1, b1 = box(sp[1]) local a2, b2 = box(sp[2]) local a3 = box(sp[3])
    check("tidy space: even gaps", math.abs((a2 - b1) - (a3 - b2)) <= 2, true)
    local ruled = Tidy.apply(strokes, { level = true }, { skip = skip, rule = { first = 100, step = 84 }, gap = 84 })
    -- A capital written apart from the rest of its word stays with it.
    local function box(x0, x1, y0, y1) return { w = 3, p = { x0, y0, x1, y1 } } end
    local cap = { box(100, 130, 460, 500), box(140, 230, 470, 500), box(290, 380, 470, 500), box(440, 520, 470, 500) }
    local capLines = Tidy.lines(cap, function() return false end)
    check("tidy: a lifted capital stays in its word", #capLines[1].words .. "|" .. #capLines[1].words[1].strokes, "3|2")
    -- Even size keeps the gaps: a small word made bigger moves the next one along.
    local small = { word(100, 500, 3, 30, 0), word(260, 500, 3, 50, 0), word(460, 500, 3, 50, 0) }
    local function span(st) local a, b = math.huge, -math.huge for i = 1, #st.p - 1, 2 do a = math.min(a, st.p[i]) b = math.max(b, st.p[i]) end return a, b end
    local gap0 = select(1, span(small[2])) - select(2, span(small[1]))
    local sized = Tidy.apply(small, { size = true }, {})
    local gap1 = select(1, span(sized[2])) - select(2, span(sized[1]))
    check("tidy size: the gap after a resized word kept", math.abs(gap1 - gap0) <= 2, true)
    check("tidy level: onto the ruled line", math.abs(bottom(ruled[1]) - 520) <= 10 and math.abs(bottom(ruled[1]) - bottom(ruled[3])) <= 3, true)

    -- Messy writing (from testing with bad handwriting).
    local function ys(st) local a, b = math.huge, -math.huge for i = 2, #st.p, 2 do a = math.min(a, st.p[i]) b = math.max(b, st.p[i]) end return a, b end
    -- A tall f reaching into the next line stays with its own line.
    local f = { box(100, 200, 470, 500), { w = 3, p = { 215, 420, 225, 600 } }, box(230, 320, 470, 500),
        box(100, 200, 554, 584), box(240, 330, 554, 584) }
    local fLines = Tidy.lines(f, function() return false end, 84)
    local inFirst = false
    for __, w in ipairs(fLines[1].words) do for __, k in ipairs(w.strokes) do if k == 2 then inFirst = true end end end
    check("tidy: a tall letter stays with its line", #fLines .. "|" .. tostring(inFirst), "2|true")
    -- Letters touching, a capital apart, then words: the capital stays in its word.
    local touch = { box(100, 130, 440, 500), box(140, 170, 460, 500), box(171, 200, 460, 500), box(201, 230, 460, 500),
        box(290, 320, 460, 500), box(321, 350, 460, 500), box(410, 440, 460, 500), box(441, 470, 460, 500) }
    local tLines = Tidy.lines(touch, function() return false end)
    check("tidy: touching letters and a lifted capital", #tLines[1].words, 3)
    -- A dash before a word (a list): the line isn't tilted, and the dash moves with its word.
    local list = { box(100, 140, 485, 487), word(170, 520, 4, 40, 0) }
    local lv = Tidy.apply(list, { level = true }, {})
    local d0 = select(1, ys(list[1])) - select(2, ys(list[2]))
    local d1 = select(1, ys(lv[1])) - select(2, ys(lv[2]))
    check("tidy level: a dash keeps its place by its word", math.abs(d1 - d0) <= 1, true)
    check("tidy level: a dash stays flat", select(2, ys(lv[1])) - select(1, ys(lv[1])) <= 3, true)
    -- Two words a little up and down: set on one baseline, not tilted.
    local two = { word(100, 500, 4, 40, 0), word(400, 530, 4, 40, 0) }
    local tw = Tidy.apply(two, { level = true }, {})
    local h1 = select(2, ys(tw[1])) - select(1, ys(tw[1]))
    check("tidy level: two words not tilted", math.abs(h1 - 40) <= 2 and math.abs(bottom(tw[1]) - bottom(tw[2])) <= 2, true)
    -- Writing climbing steeply stays one line.
    local climb = {}
    for i = 0, 5 do table.insert(climb, word(100 + i * 200, 900 - i * 34, 3, 40, 0)) end
    check("tidy: a steeply climbing line stays one line", #Tidy.lines(climb, function() return false end, 84), 1)
    -- Printed letters spaced unevenly: words found, so spacing doesn't run them together.
    local printed, x = {}, 100
    for __, n in ipairs({ 4, 3, 5 }) do
        for i = 1, n do
            table.insert(printed, box(x, x + 26, 470, 500))
            x = x + 26 + (i % 2 == 0 and 9 or 15)
        end
        x = x + 40
    end
    check("tidy: printed letters make words", #Tidy.lines(printed, function() return false end)[1].words, 3)
end

-- Smoothing keeps a stroke's shade.
do
    local Shapes = require("notesshapes")
    local s = { t = "pencil", c = 0x88, w = 4, p = { 0, 0, 10, 2, 20, 0, 30, 3, 40, 0, 50, 2 } }
    check("smoothed stroke keeps its shade", Shapes.smooth(s, 2).c, 0x88)
end

-- Search without AI, and links between pages.
do
    local stub = { "datastorage", "ui/widget/menu", "ui/uimanager", "gettext", "ffi/util" }
    local saved = {}
    for __, m in ipairs(stub) do saved[m] = package.loaded[m] end
    package.loaded["datastorage"] = saved["datastorage"] or {}
    package.loaded["ui/widget/menu"] = saved["ui/widget/menu"] or {}
    package.loaded["ui/uimanager"] = saved["ui/uimanager"] or {}
    package.loaded["gettext"] = saved["gettext"] or function(s) return s end
    package.loaded["ffi/util"] = saved["ffi/util"] or { template = function(s) return s end }
    local N = {}
    require("notesfind")(N)
    local F = N.Find
    local t = "Banana bread: flour, sugar, two bananas"
    check("snippet whole", F.snippet(t, t:lower():find("bananas", 1, true), 7), t)
    local t2 = string.rep("word ", 20) .. "target here"
    check("snippet from a word", F.snippet(t2, t2:find("target"), 6):sub(1, 8), "\226\128\166word ")
    local page = { items = { { k = "text", text = "Typed" }, { k = "text", text = "→ Other", link = "nb1|p1" }, { k = "image" } } }
    check("typed text, not links", F.typedText(page), "Typed")
    local links = F.linksOf({ pages = { { id = "a", items = page.items }, { id = "b" } } })
    check("links of a notebook", #links .. "|" .. links[1].from .. "|" .. links[1].to, "1|a|nb1|p1")
    for __, m in ipairs(stub) do package.loaded[m] = saved[m] end
end

-- The reorder screen's moves.
do
    local Order = require("notesorder")
    local function j(t) return t and table.concat(t, ",") or "nil" end
    check("up one", j(Order.move({ "a", "b", "c", "d" }, "c", -1)), "a,c,b,d")
    check("down one", j(Order.move({ "a", "b", "c", "d" }, "b", 1)), "a,c,b,d")
    check("to the top", j(Order.move({ "a", "b", "c", "d" }, "d", -4)), "d,a,b,c")
    check("to the bottom", j(Order.move({ "a", "b", "c", "d" }, "a", 4)), "b,c,d,a")
    check("already at the top", j(Order.move({ "a", "b" }, "a", -1)), "nil")
    check("not in the list", j(Order.move({ "a", "b" }, "z", 1)), "nil")
    local keys = { 1, 2, 3 }
    Order.move(keys, 1, 1)
    check("the old list is left as it was (for Undo)", j(keys), "1,2,3")
end

-- KOReader gestures handed on in Notes.
do
    local saved = { package.loaded["device"], package.loaded["dispatcher"], package.loaded["ui/uimanager"] }
    package.loaded["device"] = {}
    package.loaded["dispatcher"] = { execute = function() end }
    package.loaded["ui/uimanager"] = { broadcastEvent = function() end }
    local KO = require("notesko")
    check("light on two fingers", KO.notesSafe("two_finger_swipe_north", { increase_frontlight = 0 }), true)
    check("no light on an edge swipe (Swipes change the light off)", KO.notesSafe("one_finger_swipe_left_edge_up", { increase_frontlight = 0 }), false)
    check("refresh multiswipe", KO.notesSafe("multiswipe", { full_refresh = true }), true)
    check("folder shortcuts left out", KO.notesSafe("two_finger_swipe_west", { folder_shortcuts = true }), false)
    check("an app's own action", KO.notesSafe("one_finger_swipe_left_edge_up", { todo_add = true, settings = {} }), true)
    check("mixed actions left out", KO.notesSafe("two_finger_swipe_east", { toggle_wifi = true, history = true }), false)
    check("a tap a palm can make left out", KO.notesSafe("tap_left_bottom_corner", { toggle_frontlight = true }), false)
    check("nothing set", KO.notesSafe("multiswipe", nil), false)
    package.loaded["notesko"] = nil
    package.loaded["device"], package.loaded["dispatcher"], package.loaded["ui/uimanager"] = saved[1], saved[2], saved[3]
end

-- Crosswords from the Guardian: read, laid out, put in the book.
do
    local C = require("notescrossword")
    check("days from a date", C.daysFrom(1970, 1, 1), 0)
    check("days and back", table.concat({ C.dateOf(C.daysFrom(2026, 10, 21)) }, "-"), "2026-10-21")
    check("leap day back", table.concat({ C.dateOf(C.daysFrom(2024, 2, 29)) }, "-"), "2024-2-29")
    check("day label", C.dayLabel(C.daysFrom(2026, 10, 21), true), "Wed 21 Oct 2026")
    check("clue as plain text", C.plain("<i>Hamlet</i> &amp; co &#8217;s (4)"), "Hamlet & co \226\128\153s (4)")

    local series = json.encode({ html = '<li data-id="crosswords/quick/17616" x> <time datetime="2026-10-20T23:00:48+0000">'
        .. '</time></li><li data-id="crosswords/quick/17615"><time datetime="2026-10-20T00:00:09+0000"></time></li>'
        .. '<li data-id="crosswords/quick/17616"></li>' })
    local list = C.recent(series, "quick", json)
    check("series: newest first, once each", #list .. ":" .. list[1].number .. "," .. list[2].number, "2:17616,17615")
    check("series: 23:00 UTC is the next day", C.dayLabel(list[1].day), "Wed 21 Oct")
    check("series: midnight UTC is that day", C.dayLabel(list[2].day), "Tue 20 Oct")
    check("series: not a list", C.recent("<html>", "quick", json), nil)
    check("series: first page", C.seriesURL("quick", 1), "https://www.theguardian.com/crosswords/series/quick.json")
    check("series: older page", C.seriesURL("prize", 3), "https://www.theguardian.com/crosswords/series/prize.json?page=3")

    -- A 3 x 3 puzzle: CAT across the top, COW down the left, TEA down the right.
    local function puzzle(answers)
        local function e(n, dir, x, y, clue, sol, seps)
            return { number = n, humanNumber = tostring(n), direction = dir, position = { x = x, y = y }, length = 3,
                clue = clue, solution = answers and sol or nil, separatorLocations = seps }
        end
        return json.encode({ crossword = { id = "crosswords/quick/9", number = 9, name = "Quick crossword No 9",
            crosswordType = "quick", date = 1792540800000, solutionAvailable = answers, dimensions = { cols = 3, rows = 3 },
            entries = { e(1, "across", 0, 0, "Pet (3)", "CAT"), e(1, "down", 0, 0, "Milker (3)", "COW", { [","] = { 1 } }),
                e(2, "down", 2, 0, "Brew (3)", "TEA") } } })
    end
    local p = C.parse(puzzle(true), json)
    check("puzzle read", p and p.key .. " " .. #p.entries .. " " .. p.cols .. "x" .. p.rows, "quick/9 3 3x3")
    check("puzzle day", C.dayLabel(p.day), "Wed 21 Oct")
    check("puzzle answers", p.answers, true)
    check("word break kept", p.entries[2].breaks[1] and p.entries[2].breaks[1][1], 1)
    local white, numbers, letters = C.squares(p)
    check("squares: answer letters", letters["0,0"] .. letters["2,0"] .. letters["0,2"] .. letters["2,2"], "CTWA")
    check("squares: a black square", white["1,1"], nil)
    check("squares: numbers", numbers["0,0"] .. numbers["2,0"], "12")
    local pages = C.layout(p)
    check("layout: puzzle page and answers", #pages .. pages[1].part .. pages[#pages].part, "21a")
    check("no answers yet", C.parse(puzzle(false), json).answers, false)
    check("no answers, no answers page", #C.layout(C.parse(puzzle(false), json)), 1)
    check("not a crossword", C.parse('{"crossword":{}}', json), nil)
    check("entry off the grid dropped", #C.parse(puzzle(true):gsub('"x":2', '"x":5'), json).entries, 2)
    local lines = C.wrap("one two three four five six seven eight nine ten", 10, 60)
    check("clues wrap", #lines > 2 and #lines < 10, true)

    -- The book: pages added once, the answers hidden, then the answers added later.
    local nb = { name = "Guardian crosswords", pages = {} }
    local n = 0
    local function newId() n = n + 1 return "pg" .. n end
    local early = C.parse(puzzle(false), json)
    local first, added = C.addToBook(nb, early, newId)
    check("book: first puzzle (upright and on its side)", first .. tostring(added) .. #nb.pages, "1true2")
    check("book: same again adds nothing", select(2, C.addToBook(nb, early, newId)), false)
    nb.pages[1].strokes = { { w = 3, p = { 1, 2, 3, 4 } } }
    local other = C.parse(puzzle(true):gsub("quick/9", "quick/10"):gsub('"number":9', '"number":10'), json)
    check("book: second puzzle after", C.addToBook(nb, other, newId), 3)
    local at, more = C.addToBook(nb, p, newId)
    check("book: answers come later", at .. "," .. tostring(more), "1,true")
    local order = {}
    for _, pg in ipairs(nb.pages) do table.insert(order, pg.pz .. (pg.hide and "h" or "")) end
    check("book: answers after their puzzle, hidden", table.concat(order, " "),
        "quick/9:1 quick/9:ah quick/9:L1 quick/9:Lah quick/10:1 quick/10:ah quick/10:L1 quick/10:Lah")
    local pdf = C.bookPDF(nb, function(key) return key == "quick/9" and p or other end)
    check("book: a PDF", pdf:sub(1, 8), "%PDF-1.4")
    local bgs = ""
    for _, pg in ipairs(nb.pages) do bgs = bgs .. pg.bg end
    check("book: pages mapped in order", bgs, "12345678")
    check("book: writing stays with its page", #nb.pages[1].strokes, 1)
    check("book: a page count of 8", pdf:match("/Count (%d+)"), "8")
    check("book: landscape pages on their side", pdf:match("/MediaBox %[0 0 827 620%]") ~= nil, true)

    -- On its side and with bigger clues.
    local land = C.layout(p, { landscape = true })
    check("landscape: parts", land[1].part .. land[#land].part, "L1La")
    check("landscape: page size", land[1].w .. "x" .. land[1].h, "827x620")
    check("landscape: the grid fits the height", land[1].grid.y + 3 * land[1].grid.cell <= 620, true)
    check("landscape: the grid at least as big", land[1].grid.cell >= C.layout(p)[1].grid.cell, true)
    local wide = {}
    for y = 1, 15 do
        wide[y] = {}
        for x = 1, 15 do wide[y][x] = string.char(64 + (x + y) % 26 + 1) end
    end
    local long, longD = {}, {}
    for k = 1, 15 do
        long[k] = string.rep("A clue long enough to take up more than one line of the column it is in ", 2) .. "(6,7)"
        longD[k] = long[k]
    end
    local big = C.fromGrid({ key = "usa/20261021", name = "Big" }, wide, long, longD)
    check("large clues: fewer on the first page", #C.layout(big, { large = true })[1].clues < #C.layout(big)[1].clues, true)
    check("large clues: the grid stays put", C.layout(big, { large = true })[1].grid.cell, C.layout(big)[1].grid.cell)
    do
        local bigL = C.layout(big, { large = true })
        local g1, g2 = bigL[1].grid, bigL[2].grid
        check("clue pages: the same grid on each", g2 and (g1.x .. "," .. g1.y .. "," .. g1.cell) == (g2.x .. "," .. g2.y .. "," .. g2.cell), true)
        local t1, t2 = bigL[1].turn, bigL[2].turn
        check("clue pages: the bar's arrows", t1 and (t1.k .. "/" .. t1.n .. tostring(t1.prev) .. tostring(t1.next ~= nil)), "1/" .. t1.n .. "niltrue")
        local nx = t1.next
        check("clue pages: tap on an arrow", select(2, C.tapped(big, bigL[1], nx[1] + 10, nx[2] + 10)), 1)
        check("clue pages: back from the second", t2.prev ~= nil, true)
        check("clue pages: no bar when they fit", C.layout(p)[1].turn, nil)
        -- Hints: the square or clue tapped, the AI's prompt, a hint that gives the answer away.
        local lp = C.layout(p)[1]
        local g, e1 = lp.grid, p.entries[1]
        local sx, sy = C.squareAt(p, lp, g.x + (e1.x + 0.5) * g.cell, g.y + (e1.y + 0.5) * g.cell)
        check("hint: the square tapped", tostring(sx) .. "," .. tostring(sy), e1.x .. "," .. e1.y)
        check("hint: outside the grid", C.squareAt(p, lp, g.x - 5, g.y - 5), nil)
        local through = C.entriesAt(p, e1.x, e1.y)
        check("hint: the words through a square", through[1] == e1 and #through >= 1, true)
        local c1 = lp.clues[1]
        check("hint: the clue tapped", C.clueAt(lp, c1[1] + c1[3] / 2, c1[2] + c1[4] / 2) == c1[5], true)
        local hp = C.hintPrompt({ label = "8", across = true, clue = "Male goose - look (6)", length = 6, answer = "GANDER" })
        check("hint: the prompt", hp:find("Male goose", 1, true) ~= nil and hp:find("GANDER", 1, true) ~= nil and hp:find("6 letters", 1, true) ~= nil, true)
        local hp2 = C.hintPrompt({ label = "8", across = true, clue = "Male goose - look (6)", length = 6, answer = "GANDER" }, { "A bird and a look." })
        check("hint: a second one goes further", hp2:find("A bird and a look.", 1, true) ~= nil and hp2:find("stronger", 1, true) ~= nil, true)
        check("hint: a nudge is fine", C.spoils("A male goose, and a word for a quick look. It starts with G.", "GANDER"), false)
        check("hint: the answer gives it away", C.spoils("Try GANDER.", "GANDER"), true)
        check("hint: so does a word starting with it", C.spoils("Think of ganders.", "GANDER"), true)
        check("hint: spelled out", C.spoils("It's G-A-N-D-E-R", "GANDER"), true)
        check("hint: a word of a longer answer", C.spoils("Something done in private, say", "IN PRIVATE"), true)
        check("hint: a short answer inside another word", C.spoils("Think of fire and anger", "IRE"), false)
    end
    check("parts of a puzzle", table.concat(C.partsOf(p), ","), "1,a,L1,La")
    local ox2, oy2, z2 = C.fit(2480, 1860, 827, 620)
    check("landscape page fitted", ox2 .. "," .. oy2 .. "," .. string.format("%.2f", z2), "0,0,3.00")

    -- A book matched to its layouts again: missing pages made, extra ones dropped (kept hidden when written on).
    local sb = { pages = { { id = "a", pz = "quick/9:1", strokes = { 1 } }, { id = "b", pz = "quick/9:3", strokes = {} },
        { id = "c", pz = "quick/9:4", strokes = { 1 } } } }
    check("sync: changed", C.syncBook(sb, function() return p end, newId), true)
    local so = {}
    for _, pg in ipairs(sb.pages) do table.insert(so, pg.pz .. (pg.hide and "h" or "")) end
    check("sync: pages", table.concat(so, " "), "quick/9:1 quick/9:ah quick/9:L1 quick/9:Lah quick/9:4h")
    check("sync: again, nothing", C.syncBook(sb, function() return p end, newId), false)
    check("sync: unreadable left alone", C.syncBook(sb, function() return nil end, newId), false)

    -- Orientation, state, done.
    check("in view: upright", C.inView(sb.pages[1], false) and not C.inView(sb.pages[3], false), true)
    check("in view: page of no puzzle", C.inView({}, true), true)
    check("counterpart", C.counterpart(sb, 1) .. C.counterpart(sb, 3) .. C.counterpart(sb, 2), "314")
    check("state: started", C.state(sb, "quick/9"), "started")
    C.setDone(sb, "quick/9", true, 1000)
    check("state: done everywhere", C.state(sb, "quick/9") .. tostring(sb.pages[3].done) .. sb.pages[1].doneat, "donetrue1000")
    C.setDone(sb, "quick/9", false)
    check("state: not done", tostring(sb.pages[1].done) .. tostring(sb.pages[1].doneat), "nilnil")

    -- Time, stats, finished puzzles.
    check("duration", C.duration(30) .. "|" .. C.duration(14 * 60) .. "|" .. C.duration(65 * 60), "under a minute|14 min|1 h 05 min")
    local now = os.time({ year = 2026, month = 10, day = 21, hour = 12 })
    local day = 86400
    local books = { { pages = {
        { pz = "quick/1:1", done = true, doneat = now, secs = 300 },
        { pz = "quick/2:1", done = true, doneat = now - day, secs = 500 },
        { pz = "quick/3:1", done = true, doneat = now - 3 * day },
        { pz = "quick/3:a", done = true },
        { pz = "usa/20261001:1", done = true, doneat = now - 20 * day, secs = 900 },
        { pz = "usa/20261002:1" } } } }
    local st = C.stats(books, now)
    check("stats: streak", st.streak, 2)
    check("stats: this week (since Monday)", st.week, 2)
    check("stats: this month", st.month, 4)
    check("stats: rows", st.rows[1].name .. st.rows[1].done .. "," .. st.rows[1].avg .. "," .. st.rows[1].best
        .. " " .. st.rows[2].name .. st.rows[2].done, "Guardian Quick3,400,300 USA Today1")
    local tb = { pages = { { pz = "usa/1:1", done = true, doneat = now - 8 * day }, { pz = "usa/1:2", done = true },
        { pz = "usa/2:1", done = true, doneat = now - 31 * day }, { pz = "usa/3:1", done = true }, { pz = "usa/4:1" } } }
    local rm, ch = C.tidy(tb, "hide", now)
    check("tidy: hide after a week", tostring(tb.pages[1].hide) .. tostring(tb.pages[2].hide) .. #rm .. tostring(ch), "truetrue0true")
    check("tidy: done before, counted from now", tb.pages[4].doneat, now)
    check("tidy: remove after 30 days", table.concat((C.tidy(tb, "remove", now)), ","), "usa/2")

    -- Checking the letters read in a grid.
    check("check: the grid's shape asked", C.checkPrompt(p):match("_ _ _\n_ # _\n_ # _") ~= nil, true)
    check("check: one row asked", C.checkPrompt(p, 1):match("\n_ # _\n") ~= nil, true)
    check("check: one row read", ((C.readGrid("O # E", p, 1)) or {})[1][2], "E")
    check("check: spaced squares, - empty", ((C.readGrid("C A T\nO # E\nX # -", p)) or {})[2][2], false)
    local read = C.readGrid("Here:\nC A T\nO#E\nX#.\n", p)
    check("check: read", read and (read[0][0] .. read[2][0] .. tostring(read[2][2])), "CXfalse")
    local wrongs, filled = C.check(p, read)
    check("check: wrong squares", #wrongs .. ":" .. wrongs[1][1] .. "," .. wrongs[1][2] .. " of " .. filled, "1:0,2 of 6")
    check("check: only some squares", #(C.check(p, read, { ["0,0"] = true })), 0)
    check("check: not the grid", C.readGrid("CAT\nOE", p), nil)
    do
        local loose = C.readGrid("CAT\nOE\nX.", p)
        check("check: black squares left out", loose and (loose[1][2] .. loose[2][0] .. tostring(loose[2][2])), "EXfalse")
        local dotted = C.readGrid("C.A.T\nO#E\nX#.", p)
        check("check: a separator between squares", dotted and (dotted[0][0] .. dotted[0][1] .. dotted[0][2]), "CAT")
        local part, missed = C.readGrid("CATS\nO#E\nX#.", p)
        check("check: a row that doesn't fit left out", tostring(part and part[0]) .. missed .. part[1][0], "nil1O")
        check("check: most rows don't fit", C.readGrid("CATS\nOEXX\nX#.", p), nil)
    end
    check("check: solved clues", table.concat(C.solved(p, (C.readGrid("CAT\nO#E\nW#A", p))), ","), "1A,1D,2D")
    check("check: solved, only some squares", table.concat(C.solved(p, read, { ["0,0"] = true, ["1,0"] = true, ["2,0"] = true }), ","), "1A")

    -- Tapping a number: a clue's, or one in the grid.
    do
        local lp1 = C.layout(p, { boxes = true })[1]
        local c1 = lp1.clues[1]
        local kind, es = C.tapped(p, lp1, c1.num[1] + 2, c1.num[2] + 4)
        check("tap: a clue's number", kind .. " " .. C.entryId(es[1]), "clue 1A")
        local g1 = lp1.grid
        kind, es = C.tapped(p, lp1, g1.x + g1.cell * 0.2, g1.y + g1.cell * 0.2)
        check("tap: a grid number, across then down", kind .. " " .. C.entryId(es[1]) .. C.entryId(es[2]), "square 1A1D")
        check("tap: the middle of a square", C.tapped(p, lp1, g1.x + g1.cell * 0.7, g1.y + g1.cell * 0.7), nil)
        check("tap: a square without a number", C.tapped(p, lp1, g1.x + g1.cell * 1.2, g1.y + g1.cell * 0.2), nil)
        local box = C.entryBox(lp1, p.entries[2])
        check("tap: an entry's squares", box[3] .. "x" .. box[4], g1.cell .. "x" .. (3 * g1.cell))
        check("tap: its clue's place", C.clueOf(lp1, p.entries[1])[1], c1[1])
    end

    -- Clue boxes.
    local boxed = C.layout(p, { boxes = true })[1]
    local cb = boxed.clues[1]
    check("boxes: a box before each clue", cb.box ~= nil and cb.box[1] == cb[1] and #boxed.clues, 3)
    check("boxes: the grid stays put", boxed.grid.x .. "," .. boxed.grid.cell, C.layout(p)[1].grid.x .. "," .. C.layout(p)[1].grid.cell)
    check("boxes: none without", C.layout(p)[1].clues[1].box, nil)
    check("entry ids", C.entryId(p.entries[1]) .. C.entryId(p.entries[2]), "1A1D")
    check("ticked count", C.ticked({ ticks = { ["1A"] = true, ["2D"] = true } }) .. tostring(C.ticked({})), "2nil")
    check("state: ticked is started", C.state({ pages = { { pz = "quick/9:1", ticks = { ["1A"] = true }, strokes = {} } } }, "quick/9"), "started")

    -- The other sources: a grid numbered the usual way, clues by number or square.
    -- C A T
    -- O # E
    -- W E A   (1 across CAT, 1 down COW, 2 down TEA, 3 across WEA)
    local grid = { { "C", "A", "T" }, { "O", false, "E" }, { "W", "E", "A" } }
    local g = C.fromGrid({ key = "usa/20261021", name = "Pets", source = "USA Today" }, grid,
        { [1] = "Pet", ["0,2"] = "Bottom row" }, { [1] = "Milker", [2] = "Brew" })
    local got = {}
    for _, e in ipairs(g.entries) do table.insert(got, e.number .. (e.across and "A" or "D") .. e.answer .. "=" .. e.clue) end
    check("grid numbered", table.concat(got, " "), "1ACAT=Pet 3AWEA=Bottom row 1DCOW=Milker 2DTEA=Brew")
    check("grid answers", g.answers, true)

    local usa = C.parseUSA('<crossword><Title v="Pet%27s" /><Width v="3" /><Height v="3" /><AllAnswer v="CATO-EWEA" />'
        .. '<across><a1 a="CAT" c="%22Pet%22" n="1" cn="1" /><a2 a="WEA" c="Row" n="7" cn="3" /></across>'
        .. '<down><d1 a="COW" c="Milker" n="1" cn="1" /><d2 a="TEA" c="Brew" n="3" cn="2" /></down></crossword>', C.daysFrom(2026, 10, 21))
    check("USA Today: read", usa and usa.key .. " " .. usa.name .. " " .. #usa.entries, "usa/20261021 Pet's 4")
    check("USA Today: clues", usa.entries[1].clue .. "|" .. usa.entries[4].clue, '"Pet"|Brew')

    local uni = C.parseUniversal(json.encode({ Title = "Pets", Width = "3", Height = "3", AllAnswer = "CATO-EWEA",
        AcrossClue = "01|Pet\n03|Row\n", DownClue = "01|Milker\n02|Brew\n" }), json, C.daysFrom(2026, 10, 21))
    check("Universal: read", uni and uni.key .. " " .. uni.entries[3].clue, "universal/20261021 Milker")

    local cells = {}
    for i, ch in ipairs({ "C", "A", "T", "O", false, "E", "W", "E", "A" }) do
        cells[i] = ch and { answer = ch, circle = i == 5 and nil or (i == 1 or nil) } or { type = "locked" }
    end
    local wapo = C.parseWapo(json.encode({ width = "3", title = "Sunday", cells = cells,
        words = { { clue = "Pet", direction = "across", indexes = { 0, 1, 2 } }, { clue = "Brew", direction = "down", indexes = { 2, 5, 8 } } } }),
        json, C.daysFrom(2026, 10, 18))
    check("Washington Post: read", wapo and wapo.key .. " " .. wapo.entries[1].clue .. " " .. wapo.entries[4].clue, "wapo/20261018 Pet Brew")
    check("Washington Post: circles", wapo.circles and wapo.circles["0,0"], true)

    local tny = C.parseTNY(json.encode({ data = "## Metadata\n\ntitle: The Crossword: Wednesday, October 21, 2026\n\n## Grid\n\nCAT\nO.E\nWEA\n\n"
        .. "## Clues\n\nA1. {/Pet/} ~ CAT\nA3. Row ~ WEA\n\nD1. Milker ~ COW\nD2. Brew ~ TEA\n\n## End\n" }), json, C.daysFrom(2026, 10, 21))
    check("New Yorker: read", tny and tny.key .. " " .. tny.name .. " " .. tny.entries[1].clue, "tny/20261021 New Yorker crossword Pet")
    check("New Yorker: puzzle id", C.tnyId('x "id":"d25139cd-2e62-4736-8a46-58dfc337a0f6" y'), "d25139cd-2e62-4736-8a46-58dfc337a0f6")

    -- Days with a puzzle: every day, Sundays, weekdays; back to the first kept.
    local wed = C.daysFrom(2026, 10, 21)
    local function labels(days) local t = {} for _, d in ipairs(days) do table.insert(t, C.dayLabel(d)) end return table.concat(t, ", ") end
    check("days: Sundays", labels((C.days("wapo", wed, 0, 2))), "Sun 18 Oct, Sun 11 Oct")
    check("days: weekdays, older", labels((C.days("tny", wed, 3, 2))), "Fri 16 Oct, Thu 15 Oct")
    local first = C.firstDay("wapo")
    local last, more = C.days("wapo", first + 7, 1, 5)
    check("days: back to the first kept", #last .. tostring(more), "1false")
    check("random day publishes", C.publishes("wapo", C.randomDay("wapo", wed, math.random)), true)
    check("a day's URL", C.dateURL("usa", wed), "http://picayune.uclick.com/comics/usaon/data/usaon261021-data.xml")
    check("a day's key", C.ymd(wed), 20261021)

    -- Answers from where the lasso was; pages named by their day; a puzzle removed.
    local lp = C.layout(p)[1]
    local g0 = lp.grid
    local inTop = C.entriesIn(p, lp, { g0.x + 0.2 * g0.cell, g0.y + 0.2 * g0.cell, 0.2 * g0.cell, 0.2 * g0.cell })
    local names = {}
    for _, e in ipairs(inTop) do table.insert(names, e.number .. (e.across and "A" or "D")) end
    check("answer: the top-left square's entries", table.concat(names, " "), "1A 1D")
    local clue = lp.clues[1]
    check("answer: a clue lassoed", C.entriesIn(p, lp, { clue[1] + 2, clue[2] + 2, 4, 4 })[1].clue, "Pet (3)")
    check("answer: nothing there", #C.entriesIn(p, lp, { 1, 1, 2, 2 }), 0)
    local sq = C.squaresOf(lp, p.entries[1])
    check("answer: its squares", #sq .. sq[1][4] .. sq[3][4], "3CT")
    check("answer's title", C.entryTitle(p.entries[1]), "1 Across · Pet (3)")
    local ox, oy, zf = C.fit(1860, 2480)
    check("page fitted like the PDF's", ox .. "," .. oy .. "," .. string.format("%.2f", zf), "0,0,3.00")
    check("label: Guardian", C.pageLabel({ pz = "quick/9:1", day = C.daysFrom(2026, 10, 21) }, wed), "Quick · Wed 21 Oct")
    check("label: by date, answers", C.pageLabel({ pz = "usa/20180711:a" }, wed), "Wed 11 Jul 2018 · answers")
    check("label: no day known", C.pageLabel({ pz = "cryptic/30143:1" }, wed), "Cryptic 30143")
    local book2 = { pages = { { pz = "usa/1:1" }, { pz = "usa/1:a" }, { pz = "usa/2:1" } } }
    check("remove a puzzle", C.removeFromBook(book2, "usa/1") .. " " .. #book2.pages .. " " .. book2.pages[1].pz, "2 1 usa/2:1")

    -- Kept by the store.
    local saved = Store.parse(Store.serialize({ id = "nb5", name = "G", pdf = "nb5.pdf", puzzle = true, feed = "guardian",
        pages = nb.pages }))
    check("store: the book's feed", saved.feed, "guardian")
    check("store: page's puzzle", saved.pages[2].pz .. tostring(saved.pages[2].hide), "quick/9:atrue")
    check("store: page's day", saved.pages[1].day, C.daysFrom(2026, 10, 21))
    check("store: bad puzzle page dropped", Store.parse("return { pdf = 'nb6.pdf', puzzle = true, pages = { { pz = 'x;y' } } }").pages[1].pz, nil)
    check("store: feed needs a puzzle book", Store.parse("return { feed = 'guardian', pages = {} }").feed, nil)
    local kept = Store.parse(Store.serialize({ id = "nb7", name = "I", pdf = "nb7.pdf", puzzle = true, feed = "imp", lay = "large",
        pages = { { id = "pg1", pz = "imp/5:1", title = "Pets", secs = 95, done = true, doneat = 1000, nclues = 4,
            ticks = { ["1A"] = true, ["12D"] = true }, strokes = {} } } }))
    check("store: ticks and clue count", kept.pages[1].nclues .. tostring(kept.pages[1].ticks["12D"]) .. tostring(kept.pages[1].ticks["1A"]), "4truetrue")
    check("store: imported, its lay", kept.feed .. kept.lay, "implarge")
    check("store: time, done at, title", kept.pages[1].secs .. "," .. kept.pages[1].doneat .. "," .. kept.pages[1].title, "95,1000,Pets")

end

do
    -- Grid writing carried to the other orientation's grid.
    local C = require("notescrossword")
    local from, to = { 100, 200, 50, 3, 3 }, { 300, 100, 100, 3, 3 }
    local src = { strokes = { { w = 4, p = { 110, 210, 140, 240 }, q = { 4, 4 } }, { w = 2, p = { 600, 600 } } },
        items = { { k = "text", x = 150, y = 250, w = 50, size = 24, text = "A", _h = 9 } } }
    local dst = { strokes = { { w = 3, p = { 320, 120, 330, 130 } }, { w = 3, p = { 900, 900, 910, 910 } } } }
    C.carryGrid(src, dst, from, to)
    local s = dst.strokes
    check("carry: outside kept, grid replaced", #s .. " " .. table.concat(s[1].p, ",") .. " " .. table.concat(s[2].p, ","),
        "2 900,900,910,910 320,120,380,180")
    check("carry: widths scaled", s[2].w .. " " .. table.concat(s[2].q, ","), "8 8,8")
    local it = dst.items and dst.items[1]
    check("carry: typed letters", it and (it.x .. "," .. it.y .. " " .. it.w .. " " .. it.size .. " " .. it.text .. tostring(it._h)), "400,200 100 48 Anil")
    check("carry: grid text", C.gridText(dst, to) ~= "" and C.gridText(dst, to) ~= C.gridText(src, from), true)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
