--[[--
Search on the web page: To Do's tasks (titles, notes and steps) and the
crosswords in Notes' puzzle books (puzzle names and clues), each match with
a line of text around it. Notes' notebooks are searched by Notes' own
/api/notes/search; the page asks all three and shows them together.
]]

local Common = require("webcommon")

local Web = {}

local MAX = 50

--- The text around the first match of `q` (lower case) in `text`.
local function snippet(text, q)
    local s = text:lower():find(q, 1, true)
    if not s then return nil end
    local from = math.max(1, s - 40)
    local to = math.min(#text, s + #q + 60)
    -- Not in the middle of a UTF-8 character.
    while from > 1 and text:byte(from) >= 0x80 and text:byte(from) < 0xC0 do from = from - 1 end
    while to < #text and text:byte(to + 1) >= 0x80 and text:byte(to + 1) < 0xC0 do to = to + 1 end
    return (from > 1 and "…" or "") .. text:sub(from, to):gsub("%s+", " ") .. (to < #text and "…" or "")
end

--- To Do: [{ list, listId, id, title, done, due, snippet }].
function Web.todo(q)
    local t = Common.plugin("todo")
    if not (t and t.store) then return nil end
    local Dates = require("tododates")
    local out = {}
    for __, list in ipairs(t.store:lists()) do
        for __, task in ipairs(list.tasks or {}) do
            if #out >= MAX then return out end
            if not task.deleted and not t.store:isPrivate(task.id) then
                local found = snippet(task.title or "", q) and ""
                if not found then found = snippet(task.notes or "", q) end
                if not found then
                    for __, s in ipairs(task.steps or {}) do
                        found = snippet(s.title or "", q)
                        if found then break end
                    end
                end
                if found then
                    table.insert(out, { list = list.name, listId = list.id, id = task.id, title = task.title,
                        done = task.completed or false, due = task.due and Dates.format(task.due) or nil,
                        snippet = found ~= "" and found or nil })
                end
            end
        end
    end
    return out
end

--- Crosswords: [{ nb, book, page, name, snippet }] (a clue: "12 Across: …").
function Web.crosswords(q)
    local notes = Common.plugin("notes")
    if not (notes and notes.crosswordBook and notes.loadCrossword) then return nil end
    local ok, Crossword = pcall(require, "notescrossword")
    if not ok or type(Crossword.SOURCES) ~= "table" then return nil end
    local out = {}
    for src in pairs(Crossword.SOURCES) do
        local nb = notes:crosswordBook(src, true)
        local locked = nb and notes.isLocked and notes:isLocked(nb.id)
        for i, page in ipairs(nb and not locked and nb.pages or {}) do
            local key = (page.pz or ""):match("^(.-):1$")
            local p = key and notes:loadCrossword(key)
            if p then
                local found = snippet(p.name or "", q)
                if not found then
                    for __, e in ipairs(p.entries or {}) do
                        local hit = snippet(e.clue or "", q)
                        if hit then
                            found = (e.label or e.number or "") .. " " .. (e.across and "Across" or "Down") .. ": " .. hit
                            break
                        end
                    end
                end
                if found then
                    table.insert(out, { nb = nb.id, book = nb.name, page = i, name = p.name or key, snippet = found })
                    if #out >= MAX then return out end
                end
            end
        end
    end
    return out
end

function Web.routes(server)
    server:route("GET", "^/api/search$", function(req, res)
        local q = tostring(req.query.q or ""):lower():match("^%s*(.-)%s*$")
        if #q < 2 then return res:json({ todo = {}, crosswords = {} }) end
        local okT, todo = pcall(Web.todo, q)
        local okC, crosswords = pcall(Web.crosswords, q)
        res:json({ todo = okT and todo or nil, crosswords = okC and crosswords or nil })
    end)
end

return Web
