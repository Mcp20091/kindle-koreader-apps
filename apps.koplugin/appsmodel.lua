--[[--
The launcher's tiles and their order, in plain Lua for the tests. Each tile
is an app (a plugin's screen, opened by its event), one of KOReader's own
places (the book being read, the library, Wi-Fi, leaving KOReader), or a pin: a Home Assistant
screen, a To Do list or a notebook, opened straight there.
]]

local Model = {}

-- key, name, icon, the plugin it needs (nil: always there; "@homeassistant":
-- Home Assistant set up; "@frontlight": a
-- Kindle with a front light).
Model.TILES = {
    { key = "reading", name = "Continue reading", icon = "book-open" },
    { key = "library", name = "Library", icon = "library" },
    -- Reading statistics: every book's, today's and the days in a row (KOReader's reading statistics).
    -- (Its key from when it was the Reading time tile: saved orders keep it.)
    { key = "readingtime", name = "Reading statistics", icon = "activity", plugin = "statistics" },
    -- Now, alerts, 24 hours and 7 days (Open-Meteo), or Home Assistant's weather screen.
    { key = "weather", name = "Weather", icon = "cloud-sun" },
    { key = "ha", name = "Home Assistant", icon = "house", plugin = "homeassistant", event = "ShowHomeAssistant" },
    { key = "dashboard", name = "Dashboard", icon = "layout-dashboard", plugin = "@homeassistant", event = "ShowHomeAssistantDashboard" },
    { key = "todo", name = "To Do", icon = "list-checks", plugin = "todo", event = "ShowTodo" },
    { key = "notes", name = "Notes", icon = "notebook-pen", plugin = "notes", event = "ShowNotes" },
    -- The Crosswords app (its own plugin since 2026-10-24): its list of puzzle books.
    { key = "crosswords", name = "Crosswords", icon = "grid-3x3", plugin = "crosswords", event = "ShowCrosswords" },
    { key = "wikipedia", name = "Wikipedia", icon = "wikipedia", plugin = "wikipedia", event = "ShowWikipedia" },
    { key = "syncthing", name = "Syncthing", icon = "folder-sync", plugin = "syncthing", event = "ShowSyncthing" },
    -- (The SSH plugin's folder is sshclient.koplugin: KOReader's own SSH server is SSH.koplugin.)
    { key = "ssh", name = "SSH", icon = "terminal", plugin = "sshclient", event = "ShowSSH" },
    -- A FlashForge 3D printer (optional/flashforge.koplugin: only there when it's installed).
    { key = "flashforge", name = "FlashForge", icon = "printer", plugin = "flashforge", event = "ShowFlashForge" },
    -- A Pangolin server (optional/pangolin.koplugin: only there when it's installed).
    { key = "pangolin", name = "Pangolin", icon = "shield-check", plugin = "pangolin", event = "ShowPangolin" },
    { key = "web", name = "Web server", icon = "globe", plugin = "webpage" },
    -- Screens set up once or looked at now and then: off to start with (each is in
    -- Settings and search too); Edit home screen shows them.
    { key = "gestures", name = "Gestures", icon = "hand", plugin = "gestures", offByDefault = true },
    -- KOReader's battery statistics (its Battery statistics plugin), plainly.
    { key = "battery", name = "Battery", icon = "battery-medium", plugin = "batterystat", offByDefault = true },
    -- Your fonts, getting more, and KOReader's font settings.
    { key = "fonts", name = "Fonts", icon = "type" },
    -- Settings for every app (the launcher's ⋮ > Settings), as a tile.
    { key = "settings", name = "Settings", icon = "sliders-horizontal" },
    -- KOReader's own menu at its Settings (gear) tab (Settings > KOReader has its common ones).
    { key = "kosettings", name = "KOReader settings", icon = "settings", offByDefault = true },
    { key = "wifi", name = "Wi-Fi", icon = "wifi" },
    { key = "light", name = "Light", icon = "sun", plugin = "@frontlight" },
    { key = "night", name = "Night mode", icon = "moon" },
    { key = "exit", name = "Exit KOReader", icon = "log-out" },
    -- Hidden until shown in Settings (it is also in the ⋮ menu).
    { key = "restart", name = "Restart KOReader", icon = "rotate-ccw", offByDefault = true },
}

--- Whether a tile is hidden: as set in Settings, else hidden to start with
-- when it is off by default (shown again it is kept as false).
function Model.isHidden(hidden, tile)
    local h = hidden and hidden[tile.key]
    if h == nil then return tile.offByDefault == true end
    return h == true
end

-- A pin's plugin, by its kind (a To Do list "todo", To Do's Today, Agenda...
-- "todoview", a notebook "note", a Notes folder "notefolder", a source's
-- newest crossword "crossword").
Model.PIN_PLUGINS = { ha = "homeassistant", todo = "todo", todoview = "todo", note = "notes", notefolder = "notes",
    crossword = "notes" }

--- A pin's key: "pin:ha:room:Kitchen", "pin:todo:<list id>", "pin:note:<id>",
-- "pin:notefolder:Work/Clients".
function Model.pinKey(p)
    if p.kind == "ha" then
        local r = p.route or {}
        return "pin:ha:" .. tostring(r.kind) .. ":" .. tostring(r.name or r.key or r.id or "")
    end
    return "pin:" .. tostring(p.kind) .. ":" .. tostring(p.id)
end

--- A pin as a tile: { key, name, icon, plugin, pin }.
function Model.pinTile(p)
    return { key = Model.pinKey(p), name = p.name or "", icon = p.icon or "star", plugin = Model.PIN_PLUGINS[p.kind], pin = p }
end

--- pins with p added (not twice); returns the list and whether it was added.
function Model.addPin(pins, p)
    pins = pins or {}
    local key = Model.pinKey(p)
    for __, q in ipairs(pins) do
        if Model.pinKey(q) == key then return pins, false end
    end
    table.insert(pins, p)
    return pins, true
end

--- pins without the one with this key.
function Model.removePin(pins, key)
    local out = {}
    for __, q in ipairs(pins or {}) do
        if Model.pinKey(q) ~= key then table.insert(out, q) end
    end
    return out
end

--- The tiles (the apps, then the pins) in the saved order (any not in it
-- after, in the usual order), leaving out those whose plugin is missing
-- (has(plugin) false) and, unless withHidden, the hidden ones.
function Model.tiles(order, hidden, has, withHidden, pins, groups)
    local rank = {}
    for i, k in ipairs(order or {}) do rank[k] = i end
    local list = {}
    local all = {}
    for __, t in ipairs(Model.TILES) do table.insert(all, t) end
    for __, p in ipairs(pins or {}) do table.insert(all, Model.pinTile(p)) end
    for __, g in ipairs(groups or {}) do
        table.insert(all, { key = "group:" .. g.id, name = g.name, icon = g.icon or "folder", groupTile = g.id })
    end
    for i, t in ipairs(all) do
        if (not t.plugin or has(t.plugin)) and (withHidden or not Model.isHidden(hidden, t)) then
            table.insert(list, { tile = t, i = i, r = rank[t.key] })
        end
    end
    table.sort(list, function(a, b)
        if a.r and b.r then return a.r < b.r end
        if a.r then return true end
        if b.r then return false end
        return a.i < b.i
    end)
    local out = {}
    for i, x in ipairs(list) do out[i] = x.tile end
    return out
end

--- Days read in a row: `days` the days with reading ("2026-10-21"), newest
-- first. Counts back from today, or from yesterday while today has none yet.
function Model.streak(days, today, yesterday)
    local n, want = 0, nil
    for __, d in ipairs(days or {}) do
        if not want then
            if d == today or d == yesterday then want = d else return 0 end
        end
        if d ~= want then break end
        n = n + 1
        local y, m, dd = d:match("^(%d+)-(%d+)-(%d+)$")
        want = os.date("%Y-%m-%d", os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd) - 1, hour = 12 }))
    end
    return n
end

--- "25 min" or "1 h 5 min" for seconds.
function Model.duration(seconds)
    local m = math.floor((seconds or 0) / 60 + 0.5)
    if m < 60 then return m .. " min" end
    return math.floor(m / 60) .. " h" .. (m % 60 > 0 and (" " .. m % 60 .. " min") or "")
end

--- The most days read in a row, ever: `days` the days with reading ("2026-10-21"), any order.
function Model.longestStreak(days)
    local sorted = {}
    for __, d in ipairs(days or {}) do table.insert(sorted, d) end
    table.sort(sorted)
    local best, run, prev = 0, 0, nil
    for __, d in ipairs(sorted) do
        local y, m, dd = d:match("^(%d+)-(%d+)-(%d+)$")
        local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 })
        if prev and math.floor((t - prev) / 86400 + 0.5) == 1 then run = run + 1
        elseif not prev or t ~= prev then run = 1 end
        best = math.max(best, run)
        prev = t
    end
    return best
end

--- When most of the reading is: the first hour of the two in a row (around
-- midnight too) with the most time; `hours` the seconds read in each hour, [0] to [23]. nil with none.
function Model.peakHours(hours)
    local best, at = 0, nil
    for h = 0, 23 do
        local v = (hours[h] or 0) + (hours[(h + 1) % 24] or 0)
        if v > best then best, at = v, h end
    end
    return at
end

--- How many fit on a page and how many pages: `n` things in rows of `per`,
-- each row `size` tall with `gap` between, in `room`. Returns per page, pages.
function Model.paging(n, per, size, gap, room)
    local rows = math.max(1, math.floor((room + gap) / (size + gap)))
    local perPage = rows * per
    return perPage, math.max(1, math.ceil(n / perPage))
end

-- The quick buttons, in their order; the tiles of the same name are left off
-- the main page while their button shows.
Model.QUICK = { "wifi", "light", "night", "refresh", "web" }
-- Quick buttons that start hidden (until turned on in the list).
Model.QUICK_OFF = { web = true }

--- Whether a quick button shows: as set (quick_off[k] true or false), else its default.
function Model.quickOn(quickOff, key)
    local off = quickOff and quickOff[key]
    if off == nil then off = Model.QUICK_OFF[key] == true end
    return not off
end

-- ------------------------------------------------------------------ quick buttons

-- Every built-in quick button: key, name, icon, and what it needs (a plugin, or
-- "@frontlight"). Tap does the quick thing; hold opens what's behind it.
Model.QUICK_BUILTIN = {
    { key = "wifi", name = "Wi-Fi", icon = "wifi" },
    { key = "light", name = "Light", icon = "sun", plugin = "@frontlight" },
    { key = "night", name = "Night mode", icon = "moon" },
    { key = "refresh", name = "Refresh", icon = "refresh-cw" },
    { key = "web", name = "Web server", icon = "globe", plugin = "webpage" },
    { key = "awake", name = "Keep awake", icon = "eye" },
    { key = "newtask", name = "New task", icon = "plus", plugin = "todo" },
    { key = "newnote", name = "New note", icon = "notebook-pen", plugin = "notes" },
    { key = "reading", name = "Continue reading", icon = "book-open" },
    { key = "weather", name = "Weather", icon = "cloud-sun" },
    { key = "search", name = "Search", icon = "search" },
    { key = "sleep", name = "Sleep", icon = "power" },
    { key = "rotate", name = "Rotate", icon = "rotate-ccw" },
    { key = "battery", name = "Battery", icon = "battery-medium", plugin = "batterystat" },
    { key = "stats", name = "Reading statistics", icon = "activity", plugin = "statistics" },
}

-- Buttons that do what a tile does: while one shows, that tile is left off the main page.
Model.QUICK_TILE = { wifi = "wifi", light = "light", night = "night", web = "web" }

function Model.quickBuiltin(key)
    for __, b in ipairs(Model.QUICK_BUILTIN) do if b.key == key then return b end end
end

--- An entry's key: "b:wifi", a pin's key ("pin:todo:L1"), "a:<app>:<id>" (another
-- app's button, such as a Home Assistant device) or "g:<group id>".
function Model.quickKey(e)
    if e.b then return "b:" .. e.b end
    if e.app then return "a:" .. e.app .. ":" .. tostring(e.id) end
    if e.pin then return Model.pinKey(e.pin) end
    if e.group then return "g:" .. e.group end
end

--- The quick buttons as set (settings.quick), else the ones from before
-- (Model.QUICK, as quick_off had them): { { b = key } | { pin = {...} } |
-- { group = id, name, icon, items = { ... } } }.
function Model.quickList(s)
    if type(s.quick) == "table" then return s.quick end
    local out = {}
    for __, k in ipairs(Model.QUICK) do
        if Model.quickOn(s.quick_off, k) then table.insert(out, { b = k }) end
    end
    return out
end

--- The tile keys the buttons do (every level, groups too): a set.
function Model.quickTiles(list)
    local out = {}
    local function walk(l)
        for __, e in ipairs(l or {}) do
            if e.b and Model.QUICK_TILE[e.b] then out[Model.QUICK_TILE[e.b]] = true end
            if e.items then walk(e.items) end
        end
    end
    walk(list)
    return out
end

--- Finds an entry by key: the entry, the list it is in, and its place there.
function Model.quickFind(list, key)
    for i, e in ipairs(list or {}) do
        if Model.quickKey(e) == key then return e, list, i end
        if e.items then
            local f, l, j = Model.quickFind(e.items, key)
            if f then return f, l, j end
        end
    end
end

--- Moves an entry `delta` places within its list (or group).
function Model.quickMove(list, key, delta)
    local e, l, i = Model.quickFind(list, key)
    if not e then return end
    local j = math.max(1, math.min(#l, i + delta))
    table.remove(l, i)
    table.insert(l, j, e)
end

--- Takes an entry out (a group's buttons go with it). Returns it, its list and place (for Undo).
function Model.quickRemove(list, key)
    local e, l, i = Model.quickFind(list, key)
    if not e then return end
    table.remove(l, i)
    return e, l, i
end

--- Puts an entry into a group (`groupKey`), or the main list (nil), at the end.
function Model.quickPut(list, key, groupKey)
    local e = Model.quickRemove(list, key)
    if not e then return end
    local into = list
    if groupKey then
        local g = Model.quickFind(list, groupKey)
        if g and g.items and not e.items then into = g.items end
    end
    table.insert(into, e)
end

--- Groups the launcher suggests (Suggested groups, on Edit home screen and in Set up your
-- Kindle): a name, an icon and the tiles that go in it (those installed).
Model.SUGGESTED_GROUPS = {
    { key = "settings", name = "Settings", icon = "settings", tiles = { "settings", "fonts", "gestures", "battery", "kosettings", "restart" } },
    { key = "reading", name = "Reading", icon = "book-open", tiles = { "library", "readingtime", "wikipedia" } },
    { key = "home", name = "Home", icon = "house", tiles = { "ha", "dashboard", "weather" } },
    { key = "writing", name = "Writing", icon = "notebook-pen", tiles = { "notes", "crosswords" } },
    { key = "tools", name = "Tools", icon = "terminal", tiles = { "todo", "ssh", "syncthing", "web", "flashforge", "pangolin" } },
    { key = "device", name = "Device", icon = "power", tiles = { "wifi", "light", "night", "exit" } },
}

--- The suggested groups that can be made now: { { group, tiles } }, each with at least two of
-- its tiles among `all` (every tile installed) and in no group yet, and no group of that name.
function Model.suggestions(all, groups, grouped)
    local byKey, names, exists = {}, {}, {}
    for __, t in ipairs(all) do byKey[t.key] = t end
    for __, g in ipairs(groups or {}) do
        exists[g.id] = true
        names[(g.name or ""):lower()] = true
    end
    local out = {}
    for __, sg in ipairs(Model.SUGGESTED_GROUPS) do
        if not names[sg.name:lower()] then
            local tiles = {}
            for __, k in ipairs(sg.tiles) do
                local gid = grouped and grouped[k]
                if byKey[k] and not (gid and exists[gid]) then table.insert(tiles, byKey[k]) end
            end
            if #tiles >= 2 then table.insert(out, { group = sg, tiles = tiles }) end
        end
    end
    return out
end

--- The tiles on one page of the launcher: the main page (tiles in no group,
-- and the groups; not those whose quick button shows: `toggles`, a set of
-- keys), or a group's own page (`group`: its id).
function Model.page(tiles, groups, grouped, group, toggles)
    local exists, az = {}, false
    for __, g in ipairs(groups or {}) do
        exists[g.id] = true
        if g.id == group and g.sort == "az" then az = true end
    end
    local out = {}
    for __, t in ipairs(tiles) do
        local g = grouped and grouped[t.key]
        if g and not exists[g] then g = nil end
        if group then
            if g == group then table.insert(out, t) end
        elseif not g and not (toggles and toggles[t.key]) then
            table.insert(out, t)
        end
    end
    -- A group sorted A–Z (its hold menu > Sort).
    if az then table.sort(out, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end) end
    return out
end

--- `key` swapped with its neighbour among `shown` (the keys on its page),
-- every other tile keeping its place: the new order of all `keys`.
function Model.moveAmong(keys, shown, key, delta)
    local at
    for i, k in ipairs(shown) do if k == key then at = i end end
    local other = at and shown[at + delta]
    local out = {}
    for i, k in ipairs(keys) do out[i] = k end
    if not other then return out end
    local a, b
    for i, k in ipairs(out) do
        if k == key then a = i elseif k == other then b = i end
    end
    if a and b then out[a], out[b] = out[b], out[a] end
    return out
end

--- The keys of `tiles` with `key` moved by `delta` places.
function Model.move(tiles, key, delta)
    local keys = {}
    for i, t in ipairs(tiles) do keys[i] = t.key end
    for i, k in ipairs(keys) do
        if k == key then
            local j = math.max(1, math.min(#keys, i + delta))
            table.remove(keys, i)
            table.insert(keys, j, key)
            break
        end
    end
    return keys
end

--- A book's name from its path: "/mnt/us/documents/The Hobbit.epub" -> "The Hobbit".
function Model.bookName(path)
    local name = (path or ""):match("([^/]+)$") or ""
    return (name:gsub("%.[%w]+$", ""))
end

return Model
