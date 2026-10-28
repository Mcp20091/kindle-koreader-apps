--[[--
Settings in one place, as a phone's Settings app: the launcher's ⋮ >
Settings lists every app (Apps, AI, Home Assistant, To Do, Notes, Crosswords,
Wikipedia, Syncthing, SSH, Web server, KOReader) and Set up your Kindle;
each row opens that app's own settings. Apps register through PluginShare:

    local PS = require("pluginshare")
    if PS.registerSettings then
        PS.registerSettings{ key = "notes", name = "Notes", icon = "notebook-pen",
            open = function() ... end }   -- shows the app's own full-page settings
    end

An app without settings screen of its own can have one drawn here, in the
same design as every app's settings:

    PS.settingsPage{ title = "Web server settings", rows = function()
        return {
            { heading = "WEB SERVER" },
            { "Web server", true, function() ... end },            -- a switch (true/false)
            { "Port", "8080", function() ... end },                -- a value and ›
            { "Password", "None", pick = function()                -- a choice: options, current, set
                return { { "None", "none" }, { "Set…", "set" } }, "none", function(v) ... end
            end },
        }
    end }

`jump = "Port"` opens the page at that row (search does). For search to find a page's rows,
the app's registerSettings entry gives `settings = function() return { { name, where, open } } end`
(Settings rows' names; `open` shows that row), or `rows` (the same rows as its page) and
`open(name)`, and the launcher lists their names.

A page opened from another of these pages gives `back = function() ... end`
(‹ opens the page it came from). Opened from another app, ‹ closes the
launcher again.

PS.showSettings() opens the list; PS.showSettings("todo") one app's settings.
]]

local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Bar = require("appsbar")
local Canvas = require("appscanvas")
local KO = require("appsko")

local C = Canvas

local Hub = {}

-- (Kept in PluginShare: apps register at start, before this module is loaded.)
local PS0 = require("pluginshare")
PS0.settingsApps = PS0.settingsApps or {}
local registry = PS0.settingsApps

function Hub.register(e)
    if type(e) == "table" and e.key and e.open then registry[e.key] = e end
end

-- ------------------------------------------------------------------ the list's layout

-- The list in groups to start with, as the home screen's suggested groups have it (Model.
-- SUGGESTED_GROUPS), with Getting started on top and Accounts for the sign-ins and keys
-- the other apps use. The launcher's own rows are here; each app's row (its settings key is
-- its plugin's name) goes in the group its entry names (appsinfo.lua: `group`), in the apps'
-- order. What's registered but in no group comes last (OTHER).
Hub.DEFAULT_GROUPS = {
    { id = "start", name = "Getting started", keys = { "updates", "setup" } },
    { id = "settings", name = "Settings", keys = { "apps", "apps_tiles", "fonts", "gestures", "battery", "koreader" } },
    { id = "accounts", name = "Accounts", keys = { "ai", "microsoft" } },
    { id = "reading", name = "Reading", keys = {} },
    { id = "home", name = "Home", keys = {} },
    { id = "writing", name = "Writing", keys = {} },
    { id = "tools", name = "Tools", keys = {} },
}

--- The apps' rows that go in group `id` to start with (their entries' `group`), in order.
local function appKeys(id)
    local out = {}
    for __, a in ipairs(require("appsinfo").list()) do
        if a.entry.group == id then out[#out + 1] = a.plugin end
    end
    return out
end

--- The default groups with the apps' rows in them.
function Hub.defaultGroups()
    local out = {}
    for __, g in ipairs(Hub.DEFAULT_GROUPS) do
        local keys = {}
        for __, k in ipairs(g.keys) do keys[#keys + 1] = k end
        for __, k in ipairs(appKeys(g.id)) do keys[#keys + 1] = k end
        out[#out + 1] = { id = g.id, name = g.name, keys = keys }
    end
    return out
end

--- One list's order: Getting started's two, the launcher's own, the apps in their order, then
-- KOReader's (what's registered but not here comes after, by name).
local function listOrder()
    local out = { "updates", "setup", "apps", "apps_tiles", "ai", "microsoft" }
    for __, k in ipairs(require("appsinfo").order()) do out[#out + 1] = k end
    out[#out + 1] = "koreader"
    return out
end

-- What the user changed, in the launcher's settings (`hub`): { layout = "list", groups (once
-- edited: a copy of the defaults, changed), order (One list, once moved), hidden = { key = true } }.
local function state(view)
    local s = view.apps.settings
    s.hub = s.hub or {}
    return s.hub
end
local function save(view)
    view.apps:save()
    view:render()
    UIManager:setDirty(view, "ui")
end

local function copyGroups(groups)
    local out = {}
    for __, g in ipairs(groups) do
        local keys = {}
        for __, k in ipairs(g.keys) do keys[#keys + 1] = k end
        out[#out + 1] = { id = g.id, name = g.name, keys = keys }
    end
    return out
end
local function groups(view, edit)
    local h = state(view)
    if edit and not h.groups then h.groups = copyGroups(Hub.defaultGroups()) end
    return h.groups or Hub.defaultGroups()
end

--- Whether `key`'s row is hidden from the list (search still finds it).
function Hub.isHidden(view, key)
    local h = view and view.apps and view.apps.settings.hub
    return h ~= nil and h.hidden ~= nil and h.hidden[key] == true
end
function Hub.setHidden(view, key, hidden)
    local h = state(view)
    h.hidden = h.hidden or {}
    h.hidden[key] = hidden or nil
    if not next(h.hidden) then h.hidden = nil end
    save(view)
end

--- The list as it shows: { { group (nil: One list, or OTHER), entries } }, hidden rows left
-- out, and how many are hidden.
function Hub.sections(view)
    local h = state(view)
    local byKey, hiddenN = {}, 0
    for k, e in pairs(registry) do
        if h.hidden and h.hidden[k] then hiddenN = hiddenN + 1 else byKey[k] = e end
    end
    local placed, out = {}, {}
    local function take(keys)
        local list = {}
        for __, k in ipairs(keys) do
            if byKey[k] and not placed[k] then
                placed[k] = true
                list[#list + 1] = byKey[k]
            end
        end
        return list
    end
    local function rest()
        local list = {}
        for k, e in pairs(byKey) do if not placed[k] then list[#list + 1] = e end end
        table.sort(list, function(a, b) return a.name < b.name end)
        return list
    end
    if h.layout == "list" then
        local list = take(h.order or listOrder())
        for __, e in ipairs(rest()) do list[#list + 1] = e end
        out[1] = { entries = list }
    else
        -- (An app added after the groups were changed goes in its own group when that's
        -- still there and the app's row is in no group yet.)
        local inGroup = {}
        for __, g in ipairs(groups(view)) do for __, k in ipairs(g.keys) do inGroup[k] = true end end
        for __, g in ipairs(groups(view)) do
            local list = take(g.keys)
            for __, k in ipairs(appKeys(g.id)) do
                if not inGroup[k] then for __, e in ipairs(take({ k })) do list[#list + 1] = e end end
            end
            if #list > 0 then out[#out + 1] = { group = g, entries = list } end
        end
        local other = rest()
        if #other > 0 then out[#out + 1] = { group = { id = "other", name = "Other" }, entries = other } end
    end
    return out, hiddenN
end

-- Moves `key` past the next shown row before (dir -1) or after (1) it in `keys`.
local function shift(view, keys, key, dir)
    local i
    for n, k in ipairs(keys) do if k == key then i = n end end
    if not i then return end
    local j = i + dir
    while keys[j] and (not registry[keys[j]] or Hub.isHidden(view, keys[j])) do j = j + dir end
    if not keys[j] then return end
    table.remove(keys, i)
    table.insert(keys, j, key)
end

local function newGroup(view, done)
    KO.askText{ title = _("New group"), hint = _("Its name"), ok = _("Create"), okIcon = "plus", needsText = true, done = function(name)
        if name == "" then return end
        local list = groups(view, true)
        local g = { id = "g" .. os.time() .. math.random(100, 999), name = name, keys = {} }
        list[#list + 1] = g
        if done then done(g) end
        save(view)
    end }
end

-- A row held: move it, put it in a group, or hide it.
local function rowMenu(view, e, section)
    local h = state(view)
    local items = {}
    if h.layout == "list" then
        local function move(dir)
            h.order = h.order or {}
            if #h.order == 0 then
                for __, s in ipairs(Hub.sections(view)) do for __, x in ipairs(s.entries) do h.order[#h.order + 1] = x.key end end
            end
            shift(view, h.order, e.key, dir)
            save(view)
        end
        items[#items + 1] = { text = _("Move up"), fn = function() move(-1) end }
        items[#items + 1] = { text = _("Move down"), fn = function() move(1) end }
    else
        local in_ = section.group and section.group.id ~= "other" and section.group.id
        if in_ then
            local function move(dir)
                for __, g in ipairs(groups(view, true)) do if g.id == in_ then shift(view, g.keys, e.key, dir) end end
                save(view)
            end
            items[#items + 1] = { text = _("Move up"), fn = function() move(-1) end }
            items[#items + 1] = { text = _("Move down"), fn = function() move(1) end }
        end
        items[#items + 1] = { text = _("Move to a group…"), fn = function()
            local function into(g)
                for __, x in ipairs(groups(view, true)) do
                    for n = #x.keys, 1, -1 do if x.keys[n] == e.key then table.remove(x.keys, n) end end
                end
                for __, x in ipairs(groups(view, true)) do if x.id == g.id then table.insert(x.keys, e.key) end end
                save(view)
            end
            local choices = {}
            for __, g in ipairs(groups(view)) do
                if g.id ~= in_ then choices[#choices + 1] = { text = _(g.name), fn = function() into(g) end } end
            end
            choices[#choices + 1] = { text = _("New group…"), fn = function() newGroup(view, into) end }
            KO.list(T(_("Move %1 to"), _(e.name)), choices)
        end }
    end
    items[#items + 1] = { text = _("Hide"), fn = function()
        Hub.setHidden(view, e.key, true)
        KO.toast(_("Hidden. Search still finds it: hold it there to show it again."), 4)
    end }
    KO.list(_(e.name), items)
end

-- A group's heading held: rename, move or delete it, or make another.
local function groupMenu(view, g)
    if g.id == "other" then return end
    local function find()
        for i, x in ipairs(groups(view, true)) do if x.id == g.id then return x, i end end
    end
    local function move(dir)
        local list = groups(view, true)
        local __, i = find()
        if not i or not list[i + dir] then return end
        list[i], list[i + dir] = list[i + dir], list[i]
        save(view)
    end
    KO.list(_(g.name), {
        { text = _("Rename"), fn = function()
            KO.askText{ title = _("Rename group"), text = _(g.name), ok = _("Save"), needsText = true, done = function(name)
                local x = find()
                if x and name ~= "" then x.name = name save(view) end
            end }
        end },
        { text = _("Move up"), fn = function() move(-1) end },
        { text = _("Move down"), fn = function() move(1) end },
        { text = _("New group…"), fn = function() newGroup(view) end },
        { text = _("Delete group"), fn = function()
            KO.confirm{ title = T(_("Delete %1"), _(g.name)), text = _("Its rows go to the end of the list (OTHER)."), ok = _("Delete"),
                onOk = function()
                    local __, i = find()
                    if i then table.remove(groups(view, true), i) save(view) end
                end }
        end },
    })
end

--- The rows of the list: { key, name, icon, open }.
function Hub.entries(view)
    local out = {}
    local rank = {}
    for i, k in ipairs(listOrder()) do rank[k] = i end
    local list = {}
    for __, e in pairs(registry) do table.insert(list, e) end
    table.sort(list, function(a, b)
        local ra, rb = rank[a.key] or 999, rank[b.key] or 999
        if ra ~= rb then return ra < rb end
        return a.name < b.name
    end)
    for __, e in ipairs(list) do table.insert(out, e) end
    return out
end

-- ------------------------------------------------------------------ the rows, as every app's settings

--- Draws settings rows into flow F ({ heading } or { name, value, fn | pick, refresh mode },
-- or { note = text }: a grey line). `hold = fn` on a heading or a row: what holding it does.
function Hub.rows(view, c, F, rows, changed)
    for i, r in ipairs(rows) do
        if r then
            if r.heading then
                F:block(34, function(y)
                    c:text(14, y + 26, r.heading, 9.5, { bold = true, color = C.GREY })
                    if r.hold then c:hit(0, y, c.W, 34, function() end, r.hold) end
                end, 36)
            elseif r.note then
                F:block(40, function(y) c:text(14, y + 24, r.note, 10, { color = C.GREY, maxw = c.W - 28 }) end)
            else
                if view.pageJump and r[1] == view.pageJump then view.pageJumpTo = view.pageJumpTo or (F.page or 1) end
                F:block(36, function(y)
                    local x = 14
                    if r.icon then
                        c:icon(r.icon, 14, y + 9, 18)
                        x = 46
                    end
                    c:text(x, y + 23, r[1], 12, { maxw = 330 })
                    if type(r[2]) == "boolean" then
                        local sx, sy = c.W - 54, y + 7
                        c:box(sx, sy, 40, 22, { r = 11, fill = r[2] and C.FILL or C.WHITE, border = C.BLACK })
                        c:circle(sx + (r[2] and 29 or 11), sy + 11, 7, r[2] and C.ON_FILL or C.BLACK)
                    else
                        c:text(c.W - 32, y + 23, r[2] or "", 11, { align = "end", color = C.GREY, maxw = 250 })
                        c:icon("chevron-right", c.W - 26, y + 12, 12)
                    end
                    c:hline(14, y + 35, c.W - 14)
                    c:hit(0, y, c.W, 36, function()
                        if r.pick then
                            local options, current, set = r.pick()
                            local opts = {}
                            for __, o in ipairs(options) do table.insert(opts, { label = o[1], value = o[2] }) end
                            KO.choose(r[1], opts, current, function(v) set(v) if changed then changed(r[4]) end end)
                        elseif r[3] then
                            r[3]()
                            if changed then changed(r[4]) end
                        end
                    end, r.hold)
                end)
            end
        end
    end
end

-- ------------------------------------------------------------------ the screens (launcher modes)

--- The list of every app's settings (the launcher's "hub" mode).
-- In groups (the user's, or the suggested ones to start with) or One list; hold a heading or a
-- row to change it. At the end: how many are hidden (search finds them), the layout, Reset.
function Hub.draw(view, c)
    local F = c:flow(Bar.H + 12, c.H - 8, view.hubPage or 1)
    local h = state(view)
    local sections, hiddenN = Hub.sections(view)
    local rows = {}
    for __, sec in ipairs(sections) do
        local g = sec.group
        rows[#rows + 1] = { heading = g and _(g.name):upper() or _("SETTINGS"), hold = g and function() groupMenu(view, g) end or nil }
        for __, e in ipairs(sec.entries) do
            rows[#rows + 1] = { _(e.name), e.value and e.value() or "", function() e.open() end, icon = e.icon,
                hold = function() rowMenu(view, e, sec) end }
        end
    end
    rows[#rows + 1] = { heading = _("THIS LIST") }
    if hiddenN > 0 then
        rows[#rows + 1] = { note = T(_("%1 hidden. Search finds them: hold one there to show it again."), hiddenN) }
    end
    rows[#rows + 1] = { _("Layout"), h.layout == "list" and _("One list") or _("Groups"), pick = function()
        return { { _("Groups"), "groups" }, { _("One list"), "list" } }, h.layout or "groups", function(v)
            h.layout = v ~= "groups" and v or nil
            save(view)
        end
    end }
    rows[#rows + 1] = { note = _("Hold a row or a group's name to move, group or hide it.") }
    if h.layout ~= nil or h.groups or h.order or h.hidden then
        rows[#rows + 1] = { _("Reset this list"), "", function()
            KO.confirm{ title = _("Reset this list"), text = _("Back to the suggested groups, with nothing hidden."), ok = _("Reset"),
                onOk = function() view.apps.settings.hub = nil save(view) end }
        end }
    end
    Hub.rows(view, c, F, rows)
    view.pages = F:pages()
    if (view.hubPage or 1) > view.pages then
        view.hubPage = view.pages
        return view:render()
    end
    view:bar(c, _("Settings"))
end

--- A settings screen drawn here for an app (the launcher's "page" mode).
function Hub.drawPage(view, c)
    local spec = view.pageSpec or { title = "", rows = function() return {} end }
    local F = c:flow(Bar.H + 6, c.H - 8, view.pagePage or 1)
    local rows = spec.rows() or {}
    Hub.rows(view, c, F, rows, function(mode)
        UIManager:nextTick(function()
            view:render()
            UIManager:setDirty(view, mode or "ui")
        end)
    end)
    view.pages = F:pages()
    -- Opened at a row (from search): the page it's on.
    if view.pageJump then
        local to = view.pageJumpTo
        view.pageJump, view.pageJumpTo = nil, nil
        if to and to ~= (view.pagePage or 1) then
            view.pagePage = to
            return view:render()
        end
    end
    if (view.pagePage or 1) > view.pages then
        view.pagePage = view.pages
        return view:render()
    end
    -- Back: to the page it came from (spec.back), or as the launcher's Back.
    local function back() view:onClose() end
    Bar.draw(c, {
        title = spec.title,
        back = back,
        home = function() view.mode, view.pageSpec = "tiles", nil view:refresh() end,
        pager = { page = view.pagePage or 1, pages = view.pages or 1, turn = function(d) view:turn(d) end },
        clock = true,
        refresh = function() view:reload() end,
        bell = require("pluginshare").showNotifications and function() view:showNotifications() end or nil,
        menu = function() view:moreMenu() end,
    })
end

return Hub
