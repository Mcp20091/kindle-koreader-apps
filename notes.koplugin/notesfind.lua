--[[--
Finding things in notebooks: search over typed text (text boxes, text
downloaded from OneNote, pages added as text) and handwriting read before,
with no AI needed; and the pages that link to a page (Linked from).

The links are kept in koreader/notes/links.lua ({ [notebook id] = { { from
= page id, to = "nb…|page id" }, … } }), updated as notebooks are saved and
made from every notebook the first time.

@module koplugin.notes.find
]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Find = {}

--- The text of a page that can be searched without AI: its text boxes in
-- order (links left out: they only name another page).
function Find.typedText(page)
    local parts = {}
    for __, it in ipairs(page.items or {}) do
        if it.k == "text" and not it.link and type(it.text) == "string" and it.text ~= "" then
            table.insert(parts, it.text)
        end
    end
    return table.concat(parts, "\n")
end

--- A line of text around position `at` (where `len` bytes matched), on one
-- line, with … where it was cut.
function Find.snippet(text, at, len)
    local from = math.max(1, at - 30)
    if from > 1 then
        -- From the start of a word (up to 15 more letters back).
        local base = math.max(1, from - 15)
        local space = text:sub(base, from - 1):match(".*()%s")
        if space then from = base + space elseif base == 1 then from = 1 end
    end
    -- Not in the middle of a letter (UTF-8 continuation bytes).
    while from > 1 and text:byte(from) and text:byte(from) >= 0x80 and text:byte(from) < 0xC0 do from = from - 1 end
    local to = math.min(#text, at + len + 40)
    while to < #text and text:byte(to + 1) and text:byte(to + 1) >= 0x80 and text:byte(to + 1) < 0xC0 do to = to + 1 end
    local s = text:sub(from, to):gsub("%s+", " ")
    return (from > 1 and "…" or "") .. s .. (to < #text and "…" or "")
end

--- The links on a notebook's pages: { { from = page id, to = link } }.
function Find.linksOf(nb)
    local out = {}
    for __, page in ipairs(nb.pages or {}) do
        for __, it in ipairs(page.items or {}) do
            if it.k == "text" and type(it.link) == "string" then table.insert(out, { from = page.id, to = it.link }) end
        end
    end
    return out
end

local function sameLinks(a, b)
    if (a == nil) ~= (b == nil) then return false end
    if not a then return true end
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i].from ~= b[i].from or a[i].to ~= b[i].to then return false end
    end
    return true
end

return function(Notes)
    Notes.Find = Find

    -- ------------------------------------------------------------------ search

    --- Pages where `q` is found (case doesn't matter): typed text and
    -- handwriting read before, over every notebook but locked ones.
    -- { { nb, name, page (number), pageId, snippet, kind ("typed",
    -- "handwriting", "name") } }, at most `limit` (100).
    --- What search needs of a notebook (its name, each page's typed text and,
    -- for pages with ink, the hash its read text is kept under), kept while
    -- KOReader runs and made again only when the notebook changed: searching
    -- again doesn't read every notebook again.
    function Notes:searchEntry(entry)
        self.searchCache = self.searchCache or {}
        local c = self.searchCache[entry.id]
        if c and c.modified == entry.modified then return c end
        local nb = self.store:read(entry.id)
        if not nb then return nil end
        local md5 = require("ffi/sha2").md5
        c = { modified = entry.modified, name = nb.name or "", pages = {} }
        for i, page in ipairs(nb.pages) do
            c.pages[i] = { id = page.id, typed = Find.typedText(page),
                hash = #page.strokes > 0 and md5(require("notesstore").pageText(page, "")) or nil }
        end
        self.searchCache[entry.id] = c
        return c
    end

    --- Pages where `q` is found (case doesn't matter): typed text and
    -- handwriting read before, over every notebook but locked ones.
    -- { { nb, name, page (number), pageId, snippet, kind ("typed",
    -- "handwriting", "name") } }, at most `limit` (100).
    function Notes:findText(q, limit)
        limit = limit or 100
        local needle = (q or ""):lower()
        local out = {}
        if needle == "" then return out end
        local kept = self:textFile():readSetting("pages") or {}
        -- (Puzzle books: the Crosswords app's, when it's installed.)
        local skipPuzzles = self:hasCrosswords()
        for __, entry in ipairs(self.store:list()) do
            if #out >= limit then break end
            local c = not self:isLocked(entry.id) and not (skipPuzzles and entry.puzzle) and self:searchEntry(entry)
            if c then
                if c.name:lower():find(needle, 1, true) then
                    table.insert(out, { nb = entry.id, name = c.name, page = 1, pageId = c.pages[1] and c.pages[1].id,
                        snippet = c.name, kind = "name" })
                end
                local read = kept[entry.id] or {}
                for i, page in ipairs(c.pages) do
                    if #out >= limit then break end
                    local at = page.typed ~= "" and page.typed:lower():find(needle, 1, true)
                    local text, kind = page.typed, "typed"
                    if not at then
                        local k = page.hash and read[page.id]
                        text = k and k.hash == page.hash and k.text or nil
                        at = text and text:lower():find(needle, 1, true)
                        kind = "handwriting"
                    end
                    if at then
                        table.insert(out, { nb = entry.id, name = c.name, page = i, pageId = page.id,
                            snippet = Find.snippet(text, at, #needle), kind = kind })
                    end
                end
            end
        end
        return out
    end

    -- ------------------------------------------------------------------ links

    function Notes:linksFile()
        if not self.linksSettings then
            self.linksSettings = require("luasettings"):open(DataStorage:getDataDir() .. "/notes/links.lua")
        end
        return self.linksSettings
    end

    --- Every notebook's links (made from all notebooks the first time).
    function Notes:linkIndex()
        if self.links then return self.links end
        local file = self:linksFile()
        local index = file:readSetting("links")
        if type(index) ~= "table" then
            index = {}
            for __, entry in ipairs(self.store:list()) do
                local nb = self.store:read(entry.id)
                local links = nb and Find.linksOf(nb)
                if links and #links > 0 then index[nb.id] = links end
            end
            file:saveSetting("links", index)
            file:flush()
        end
        self.links = index
        return index
    end

    --- A notebook saved: its links kept (written only when they changed).
    function Notes:noteLinks(nb)
        if not (nb and nb.id) then return end
        local index = self:linkIndex()
        local links = Find.linksOf(nb)
        if #links == 0 then links = nil end
        if sameLinks(index[nb.id], links) then return end
        index[nb.id] = links
        local file = self:linksFile()
        file:saveSetting("links", index)
        file:flush()
    end

    --- The pages linking to page `pageId` of notebook `nbId`: { { nb,
    -- pageId } } (not resolved: notebooks may have gone).
    function Notes:linksTo(nbId, pageId)
        local want = nbId .. "|" .. pageId
        local out = {}
        for id, links in pairs(self:linkIndex()) do
            -- Not notebooks deleted since.
            local f = io.open(self.store:path(id), "rb")
            if f then f:close() else links = {} end
            for __, l in ipairs(links) do
                if l.to == want then table.insert(out, { nb = id, pageId = l.from }) end
            end
        end
        table.sort(out, function(a, b) return a.nb == b.nb and a.pageId < b.pageId or a.nb < b.nb end)
        return out
    end

    --- ⋯ > Linked from: the pages linking here; tapping one goes there.
    function Notes:showLinkedFrom(ed)
        local here = ed.notebook
        local items = {}
        for __, l in ipairs(self:linksTo(here.id, here.pages[ed.page].id)) do
            local nb = l.nb == here.id and here or (not self:isLocked(l.nb) and self.store:read(l.nb))
            if nb then
                for i, page in ipairs(nb.pages) do
                    if page.id == l.pageId then
                        table.insert(items, {
                            text = nb.id == here.id and T(_("Page %1"), i) or nb.name,
                            mandatory = T(_("p. %1"), i),
                            link = nb.id .. "|" .. page.id,
                        })
                    end
                end
            end
        end
        if #items == 0 then table.insert(items, { text = _("No pages link here."), dim = true }) end
        local page
        for __, it in ipairs(items) do
            local link = it.link
            if link then it.callback = function() UIManager:close(page) ed:followLink(link) end end
        end
        page = self:listPage(_("Linked from"), items)
    end
end
