--[[--
Crosswords on the web page (needs a Notes with crosswords): the books of
crosswords and each puzzle's day, state and time; puzzles picked by day (or
number) and downloaded by the Kindle into their books; .puz and .ipuz files
imported; a puzzle opened on the Kindle or removed; Crossword settings.
]]

local Common = require("webcommon")

local Web = {}

-- Notes, when it has crosswords.
local function notes()
    local n = Common.plugin("notes")
    if n and n.crosswordState then return n end
end

local SOURCES = { guardian = true, usa = true, universal = true, wapo = true, tny = true }
local KINDS = { quick = true, cryptic = true, quiptic = true, prize = true }
local SETTINGS = { crossword_today = "string", crossword_clues = "string", crossword_boxes = "boolean", crossword_find = "boolean", crossword_card = "string", crossword_timer = "boolean",
    crossword_finished = "string", crossword_auto = "table" }

-- A puzzle's key from the browser: "quick/17616", "usa/20261021", "imp/2026102112000001".
local function validKey(key)
    return type(key) == "string" and key:match("^%a+/%d+$") ~= nil
end

function Web.routes(server)
    -- { installed, books = { { src, name, id, puzzles } }, sources, settings }.
    server:route("GET", "^/api/crosswords$", function(req, res)
        local n = notes()
        if not n then return res:json({ installed = false }) end
        local Settings = require("notessettings")
        local settings = {}
        for k in pairs(SETTINGS) do settings[k] = Settings.get(k) end
        res:json({ installed = true, books = n:crosswordState(), sources = n:crosswordSources(), settings = settings })
    end)

    -- Five (or seven) puzzles to pick: ?src=usa&from=0, ?src=guardian&kind=quick&from=5.
    server:route("GET", "^/api/crosswords/choices$", function(req, res)
        local n = notes()
        if not n then return res:error(404, "Notes with crosswords isn't installed") end
        local src, kind = req.query.src, req.query.kind
        if not SOURCES[src] then return res:error(400, "Unknown source") end
        if src == "guardian" and not KINDS[kind] then kind = "quick" end
        if not require("ui/network/manager"):isOnline() then return res:error(503, "The Kindle isn't online") end
        local items, more = n:crosswordChoices(src, kind, math.max(0, math.floor(tonumber(req.query.from) or 0)))
        -- The Guardian's list is fetched in the background: asked for again.
        if not items and more == "loading" then return res:json({ loading = true }) end
        if not items then return res:error(502, "Could not get the list (" .. tostring(more) .. ")") end
        res:json({ items = items, more = more == true })
    end)

    -- Puzzles downloaded into their book: { src, items = { { key, day, kind, number } } }.
    -- Fetched in the background: { job } to ask /api/crosswords/job about.
    server:route("POST", "^/api/crosswords/get$", function(req, res)
        local n = notes()
        if not n then return res:error(404, "Notes with crosswords isn't installed") end
        local b = req.json()
        if not SOURCES[b.src] or type(b.items) ~= "table" then return res:error(400, "Nothing to get") end
        local items = {}
        for __, it in ipairs(b.items) do
            if type(it) == "table" and validKey(it.key) and #items < 14 then
                table.insert(items, { key = it.key, day = tonumber(it.day), kind = KINDS[it.kind] and it.kind or nil,
                    number = tonumber(it.number), label = type(it.label) == "string" and it.label or nil })
            end
        end
        if #items == 0 then return res:error(400, "Nothing to get") end
        if not require("ui/network/manager"):isOnline() then return res:error(503, "The Kindle isn't online") end
        if n.getCrosswordsLater then return res:json({ job = n:getCrosswordsLater(b.src, items) }) end
        local got, missed, why = n:getCrosswordsFor(b.src, items)
        if why == "open" then return res:error(409, "That book is open on the Kindle: close it there first") end
        res:json({ got = got, missed = missed })
    end)

    -- A download's state: { state = "running" } until { state = "done", got, missed }.
    server:route("GET", "^/api/crosswords/job$", function(req, res)
        local n = notes()
        local job = n and n.crosswordJob and n:crosswordJob(req.query.id)
        if not job then return res:error(404, "No such download") end
        if job.state == "open" then return res:error(409, "That book is open on the Kindle: close it there first") end
        if job.state == "failed" then return res:error(502, "Could not get the crosswords (" .. tostring(job.error) .. ")") end
        res:json({ state = job.state, got = job.got, missed = job.missed })
    end)

    -- A .puz or .ipuz file (the body) into the Imported crosswords book.
    server:route("POST", "^/api/crosswords/import$", function(req, res)
        local n = notes()
        if not n then return res:error(404, "Notes with crosswords isn't installed") end
        local first, p = n:importCrosswordData(req.body or "", false)
        if not first then return res:error(400, tostring(p)) end
        res:json({ name = p.name })
    end)

    -- A PDF of puzzles (the body, written as it arrives) made a puzzle book in Crosswords: ?name=.
    server:route("PUT", "^/api/crosswords/pdf$", function(req, res)
        local n = notes()
        if not n or not n.importPDF then return res:error(404, "Notes with crosswords isn't installed") end
        local name = tostring(req.query.name or ""):gsub("%.[Pp][Dd][Ff]$", ""):gsub("[%c/\\]", ""):sub(1, 120)
        if name == "" then name = "Puzzle book" end
        local dir = require("datastorage"):getDataDir() .. "/cache"
        require("util").makePath(dir)
        local tmp = dir .. "/notes-upload.pdf"
        local f = io.open(tmp, "wb")
        if not f then return res:error(500, "Can't write the PDF") end
        local got = 0
        while true do
            local chunk = req:read(64 * 1024)
            if not chunk then break end
            f:write(chunk)
            got = got + #chunk
        end
        f:close()
        if got ~= req.length then
            os.remove(tmp)
            return res:error(400, "The upload was interrupted")
        end
        local nb, why = n:importPDF(tmp, true, true, name)
        os.remove(tmp)
        if not nb then return res:error(400, "Not a PDF that can be read (" .. tostring(why) .. ")") end
        res:json({ name = nb.name, pages = #nb.pages })
    end, true)

    -- A puzzle opened on the Kindle: { book, key }.
    server:route("POST", "^/api/crosswords/open$", function(req, res)
        local n = notes()
        if not n then return res:error(404, "Notes with crosswords isn't installed") end
        local b = req.json()
        if type(b.book) ~= "string" or not b.book:match("^nb%d+$") or not validKey(b.key) then return res:error(400, "No such puzzle") end
        local nb = n.store:read(b.book)
        local at = nb and require("notescrossword").pageOf(nb, b.key, "1")
        if not at then return res:error(404, "No such puzzle") end
        require("ui/uimanager"):nextTick(function() n:open(b.book, at) end)
        res:json({ ok = true })
    end)

    -- A puzzle taken out of its book: { book, key }.
    server:route("POST", "^/api/crosswords/remove$", function(req, res)
        local n = notes()
        if not n then return res:error(404, "Notes with crosswords isn't installed") end
        local b = req.json()
        if type(b.book) ~= "string" or not b.book:match("^nb%d+$") or not validKey(b.key) then return res:error(400, "No such puzzle") end
        local ok, why = n:removeCrossword(b.book, b.key, true)
        if why == "open" then return res:error(409, "That book is open on the Kindle: close it there first") end
        if not ok then return res:error(404, "No such puzzle") end
        res:json({ ok = true })
    end)

    -- A puzzle's time put right: { book, key, minutes }.
    server:route("POST", "^/api/crosswords/time$", function(req, res)
        local n = notes()
        if not n or not n.crosswordSetTime then return res:error(404, "Crosswords isn't installed") end
        local b = req.json()
        local minutes = tonumber(b.minutes)
        if type(b.book) ~= "string" or not b.book:match("^nb%d+$") or not validKey(b.key) then return res:error(400, "No such puzzle") end
        if not minutes or minutes < 0 or minutes > 100000 then return res:error(400, "Enter the minutes as a number") end
        local ok, why = n:crosswordSetTime(b.book, b.key, minutes * 60)
        if why == "open" then return res:error(409, "That book is open on the Kindle: close it there first") end
        if not ok then return res:error(404, "No such puzzle") end
        res:json({ ok = true })
    end)

    -- Crossword settings: { key = value }.
    server:route("POST", "^/api/crosswords/settings$", function(req, res)
        local n = notes()
        if not n then return res:error(404, "Notes with crosswords isn't installed") end
        local Settings = require("notessettings")
        local relay = false
        for k, v in pairs(req.json()) do
            if SETTINGS[k] and type(v) == SETTINGS[k] then
                if k == "crossword_clues" and (Settings.get(k) == "large") ~= (v == "large") then relay = true end
                if k == "crossword_boxes" and (Settings.get(k) ~= false) ~= v then relay = true end
                if k == "crossword_auto" then Settings.set("crossword_auto_at", 0) end
                Settings.set(k, v)
            end
        end
        if relay and n.relayCrosswordBooks then require("ui/uimanager"):nextTick(function() n:relayCrosswordBooks() end) end
        res:json({ ok = true })
    end)
end

return Web
