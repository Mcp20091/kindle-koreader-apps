--[[--
Every Google Fonts family, to browse on the Fonts screen's Get more tab and the
web page's Fonts tab: search, a category (serif, sans serif, monospace,
handwriting, display), popular first, A–Z or newest. Getting a family is
appsfonts.lua's Fonts.google.

The list is Google Fonts' own catalogue (https://fonts.google.com/metadata/fonts,
what its site reads; public, no key). It's about 2.7 MB of JSON, so a child
process fetches it, keeps only name, category, styles and date, and writes
those to the cache (about 50 KB, popular first). Here it's read into a few
plain arrays when first browsed (G.drop lets them go), and fetched again
when it's 30 days old.
]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local _ = require("gettext")

local G = {}

G.URL = "https://fonts.google.com/metadata/fonts"
G.MAX_AGE = 30 * 24 * 3600

-- Categories: { key, chip label, row label, Google's name }.
G.CATEGORIES = {
    { "serif", _("Serif"), _("Serif"), "Serif" },
    { "sans", _("Sans"), _("Sans serif"), "Sans Serif" },
    { "mono", _("Mono"), _("Monospace"), "Monospace" },
    { "hand", _("Handwriting"), _("Handwriting"), "Handwriting" },
    { "display", _("Display"), _("Display"), "Display" },
}
local CAT_OF, CAT_NO = {}, {}
for i, c in ipairs(G.CATEGORIES) do CAT_OF[c[4]] = i CAT_NO[c[1]] = i end

-- Good reading fonts: { family, what it's like }.
G.SUGGESTED = {
    { "Literata", _("Made for e-books (Google Play Books' font)") },
    { "Merriweather", _("A sturdy serif for screens") },
    { "Lora", _("A calligraphic serif, good for novels") },
    { "EB Garamond", _("The classic book face") },
    { "Crimson Pro", _("An elegant old-style serif") },
    { "Source Serif 4", _("A clear, modern serif") },
    { "Alegreya", _("A lively serif for long reading") },
    { "Bitter", _("A slab serif, clear at small sizes") },
    { "Atkinson Hyperlegible", _("A sans made for low vision") },
    { "Lexend", _("A sans made for easier reading") },
}

-- Sorts: { key, label }.
G.SORTS = {
    { "popular", _("Popular first") },
    { "az", _("A–Z") },
    { "new", _("Newest first") },
}

-- Styles a family has, of the four the Kindle gets (Fonts.google): bit flags.
local R, B, I, BI = 1, 2, 4, 8

function G.cachePath() return DataStorage:getDataDir() .. "/cache/google-fonts.tsv" end

-- ------------------------------------------------------------------ parsing (in the child)

--- Google's catalogue JSON → { { name, cat, styles, date } }, popular first.
-- Read with patterns, not a JSON parser: only a few fields of each family are kept.
function G.parse(text)
    local out = {}
    local at = text:find('"familyMetadataList"', 1, true)
    if not at then return out end
    local starts = {}
    for p in text:gmatch('()"family"%s*:%s*"', at) do table.insert(starts, p) end
    for k, p in ipairs(starts) do
        local chunk = text:sub(p, (starts[k + 1] or #text + 1) - 1)
        local name = chunk:match('^"family"%s*:%s*"([^"]+)"')
        local cat = CAT_OF[chunk:match('"category"%s*:%s*"([^"]+)"') or ""]
        if name and cat then
            local fonts = chunk:match('"fonts"%s*:%s*(%b{})') or ""
            local styles = 0
            if fonts:find('"400"%s*:') then styles = styles + R end
            if fonts:find('"700"%s*:') then styles = styles + B end
            if fonts:find('"400i"%s*:') then styles = styles + I end
            if fonts:find('"700i"%s*:') then styles = styles + BI end
            local y, m, d = chunk:match('"dateAdded"%s*:%s*"(%d+)%-(%d+)%-(%d+)"')
            table.insert(out, { name = name, cat = cat, styles = styles,
                date = y and tonumber(y .. m .. d) or 0,
                pop = tonumber(chunk:match('"popularity"%s*:%s*(%d+)')) or 1e9 })
        end
    end
    table.sort(out, function(a, b)
        if a.pop ~= b.pop then return a.pop < b.pop end
        return a.name < b.name
    end)
    return out
end

--- The cache file's text: a header, then a family a line (name, category, styles, date).
function G.serialize(list, now)
    local lines = { "#google-fonts 1 " .. tostring(now or os.time()) }
    for __, f in ipairs(list) do
        table.insert(lines, table.concat({ f.name, f.cat, f.styles, f.date }, "\t"))
    end
    return table.concat(lines, "\n") .. "\n"
end

-- ------------------------------------------------------------------ the list in memory

local list = nil      -- { names, cats, styles, dates, lower, at = time fetched }
local results = nil   -- the last query's indexes: { key, idx }

--- Reads the cache file into plain arrays (nil when there's none).
function G.read(path)
    local f = io.open(path or G.cachePath(), "rb")
    if not f then return nil end
    local head = f:read("*l") or ""
    local at = tonumber(head:match("^#google%-fonts 1 (%d+)"))
    if not at then f:close() return nil end
    local l = { names = {}, cats = {}, styles = {}, dates = {}, lower = {}, at = at }
    for line in f:lines() do
        local name, cat, styles, date = line:match("^([^\t]+)\t(%d)\t(%d+)\t(%d+)$")
        if name then
            local n = #l.names + 1
            l.names[n], l.cats[n], l.styles[n], l.dates[n] = name, tonumber(cat), tonumber(styles), tonumber(date)
            l.lower[n] = name:lower()
        end
    end
    f:close()
    if #l.names == 0 then return nil end
    return l
end

local function loaded()
    if list == nil then list = G.read() or false end
    return list or nil
end

--- Lets the list go (it's read again when needed).
function G.drop()
    list, results = nil, nil
end

-- ------------------------------------------------------------------ fetching

local state = nil   -- { status = "getting" | "done" | "failed", message }
local waiting = {}  -- done(state) callbacks while it's being fetched

--- { status = "none" | "getting" | "done" | "failed", count, at (time fetched), message }
function G.state()
    local l = loaded()
    return { status = state and state.status or (l and "done" or "none"), message = state and state.message,
        count = l and #l.names or 0, at = l and l.at or nil }
end

-- In the child: the catalogue, kept short, into the cache.
local function fetch(path)
    local socketutil = require("socketutil")
    local http = require("ssl.https")
    local ltn12 = require("ltn12")
    local t = {}
    socketutil:set_timeout(20, 90)
    local ok, __, code = pcall(http.request, { url = G.URL, method = "GET", sink = ltn12.sink.table(t),
        headers = { ["User-Agent"] = "Wget/1.21" } })
    socketutil:reset_timeout()
    if not ok then error("Couldn't reach Google Fonts: " .. tostring(code)) end
    if code ~= 200 then error("Google Fonts answered " .. tostring(code) .. ". Try again later.") end
    local parsed = G.parse(table.concat(t))
    t = nil
    if #parsed < 100 then error("Google Fonts sent a list that can't be read.") end
    local part = path .. ".part"
    local f = assert(io.open(part, "wb"))
    f:write(G.serialize(parsed))
    f:close()
    os.remove(path)
    assert(os.rename(part, path))
    return #parsed
end

--- Fetches the list again in a child process; done(state) when it's over.
-- Returns nil, or why it can't start.
function G.update(done)
    if done then table.insert(waiting, done) end
    if state and state.status == "getting" then return nil end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isConnected() == false then
        waiting = {}
        return _("The Kindle isn't on Wi-Fi.")
    end
    local path = G.cachePath()
    require("util").makePath(path:match("^(.*)/"))
    local pid, fd = ffiutil.runInSubProcess(function(__, write_fd)
        local ok, n = pcall(fetch, path)
        ffiutil.writeToFD(write_fd, ok and ("K" .. n) or ("E" .. tostring(n)), true)
    end, true)
    if not pid then
        waiting = {}
        return tostring(fd)
    end
    state = { status = "getting" }
    local deadline = os.time() + 2 * 60
    local function finish(status, message)
        state = { status = status, message = message }
        if status == "done" then list, results = nil, nil end
        local calls = waiting
        waiting = {}
        for __, fn in ipairs(calls) do pcall(fn, G.state()) end
    end
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(1, check) end
            ffiutil.terminateSubProcess(pid)
            return finish("failed", _("It took too long. Try again when Wi-Fi is better."))
        end
        local out = (size and size > 0) and ffiutil.readAllFromFD(fd) or "EIt stopped"
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
        end
        if out:sub(1, 1) == "K" then finish("done")
        else finish("failed", (out:sub(2):gsub("^.-:%d+: ", ""))) end
    end
    UIManager:scheduleIn(1, check)
end

--- Fetches the list when there's none, or it's old (and the Kindle is on Wi-Fi).
-- done(state) when a fetch it started (or one under way) is over. Returns whether one is under way.
function G.ensure(done)
    if state and state.status == "getting" then
        if done then table.insert(waiting, done) end
        return true
    end
    local l = loaded()
    if l and os.time() - l.at < G.MAX_AGE then return false end
    -- (One try per start when it failed; ⟳ tries again.)
    if state and state.status == "failed" then return false end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isConnected() == false then return false end
    return G.update(done) == nil
end

-- ------------------------------------------------------------------ browsing

local SORTS = { popular = true, az = true, new = true }

--- A family's styles in words: "4 styles", "Regular and Bold"…
function G.stylesLabel(styles)
    styles = tonumber(styles) or 0
    if styles == R + B + I + BI then return _("4 styles") end
    if styles == R + B then return _("Regular and Bold") end
    if styles == R + I then return _("Regular and Italic") end
    if styles == R then return _("Regular only") end
    local n = 0
    for __, bit in ipairs({ R, B, I, BI }) do
        if styles % (bit * 2) >= bit then n = n + 1 end
    end
    if n <= 1 then return _("1 style") end
    return require("ffi/util").template(_("%1 styles"), n)
end

--- A category's row label ("Serif", "Sans serif"…), by its number or key.
function G.categoryLabel(cat)
    local c = G.CATEGORIES[tonumber(cat) or CAT_NO[cat] or 0]
    return c and c[3] or ""
end

local function entry(l, i)
    return { name = l.names[i], cat = G.CATEGORIES[l.cats[i]][1], category = G.categoryLabel(l.cats[i]),
        styles = G.stylesLabel(l.styles[i]) }
end

local function indexOf(l, name)
    local low = name:lower()
    for i, n in ipairs(l.lower) do
        if n == low then return i end
    end
end

--- The families that match: opts = { q, cat = "suggested" | "all" | a category key, sort,
-- from, count }. Returns { total, items = { { name, cat, category, styles, note } }, exact }:
-- `items` from the `from`th (1 to start), at most `count`; `exact` whether a family is called q.
function G.query(opts)
    opts = opts or {}
    local q = tostring(opts.q or ""):match("^%s*(.-)%s*$"):lower()
    local cat = opts.cat or "suggested"
    local from, count = math.max(1, tonumber(opts.from) or 1), tonumber(opts.count) or 1e9
    local l = loaded()
    local out = { total = 0, items = {} }
    if cat == "suggested" and q == "" then
        out.total = #G.SUGGESTED
        for k = from, math.min(#G.SUGGESTED, from + count - 1) do
            local s = G.SUGGESTED[k]
            local i = l and indexOf(l, s[1])
            local e = i and entry(l, i) or { name = s[1] }
            e.note = s[2]
            table.insert(out.items, e)
        end
        return out
    end
    if not l then return out end
    local sort = SORTS[opts.sort] and opts.sort or "popular"
    local catNo = CAT_NO[cat]
    local key = table.concat({ q, catNo or "", sort }, "\1")
    if not (results and results.key == key) then
        local idx = {}
        for i = 1, #l.names do
            if (not catNo or l.cats[i] == catNo) and (q == "" or l.lower[i]:find(q, 1, true)) then
                table.insert(idx, i)
            end
        end
        if q ~= "" then
            -- Names that start with what's typed first, then popular first.
            table.sort(idx, function(a, b)
                local sa, sb = l.lower[a]:sub(1, #q) == q, l.lower[b]:sub(1, #q) == q
                if sa ~= sb then return sa end
                if sort == "az" then return l.lower[a] < l.lower[b] end
                if sort == "new" and l.dates[a] ~= l.dates[b] then return l.dates[a] > l.dates[b] end
                return a < b
            end)
        elseif sort == "az" then
            table.sort(idx, function(a, b) return l.lower[a] < l.lower[b] end)
        elseif sort == "new" then
            table.sort(idx, function(a, b)
                if l.dates[a] ~= l.dates[b] then return l.dates[a] > l.dates[b] end
                return a < b
            end)
        end
        results = { key = key, idx = idx }
    end
    local idx = results.idx
    out.total = #idx
    out.exact = q ~= "" and indexOf(l, q) ~= nil
    for k = from, math.min(#idx, from + count - 1) do table.insert(out.items, entry(l, idx[k])) end
    return out
end

return G
