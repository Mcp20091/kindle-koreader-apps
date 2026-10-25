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

local Bar = require("appsbar")
local Canvas = require("appscanvas")
local KO = require("appsko")

local C = Canvas

local Hub = {}

-- The order of the list; what is registered but not here comes after, by name.
local ORDER = { "apps", "apps_tiles", "ai", "microsoft", "homeassistant", "todo", "notes", "crosswords", "wikipedia", "syncthing", "sshclient", "webpage", "koreader" }

-- (Kept in PluginShare: apps register at start, before this module is loaded.)
local PS0 = require("pluginshare")
PS0.settingsApps = PS0.settingsApps or {}
local registry = PS0.settingsApps

function Hub.register(e)
    if type(e) == "table" and e.key and e.open then registry[e.key] = e end
end

--- The rows of the list: { key, name, icon, open }.
function Hub.entries(view)
    local out = {}
    local rank = {}
    for i, k in ipairs(ORDER) do rank[k] = i end
    local list = {}
    for __, e in pairs(registry) do table.insert(list, e) end
    table.sort(list, function(a, b)
        local ra, rb = rank[a.key] or 99, rank[b.key] or 99
        if ra ~= rb then return ra < rb end
        return a.name < b.name
    end)
    for __, e in ipairs(list) do table.insert(out, e) end
    return out
end

-- ------------------------------------------------------------------ the rows, as every app's settings

--- Draws settings rows into flow F ({ heading } or { name, value, fn | pick, refresh mode }).
function Hub.rows(view, c, F, rows, changed)
    for i, r in ipairs(rows) do
        if r then
            if r.heading then
                F:block(34, function(y) c:text(14, y + 26, r.heading, 9.5, { bold = true, color = C.GREY }) end, 36)
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
                    end)
                end)
            end
        end
    end
end

-- ------------------------------------------------------------------ the screens (launcher modes)

--- The list of every app's settings (the launcher's "hub" mode).
function Hub.draw(view, c)
    local F = c:flow(Bar.H + 12, c.H - 8, view.hubPage or 1)
    local rows = { { heading = _("SETTINGS") } }
    for __, e in ipairs(Hub.entries(view)) do
        table.insert(rows, { _(e.name), e.value and e.value() or "", function() e.open() end, icon = e.icon })
    end
    local PS = require("pluginshare")
    if PS.showSetup then
        table.insert(rows, { heading = _("GETTING STARTED") })
        table.insert(rows, { _("Set up your Kindle"), "", function() PS.showSetup(true) end, icon = "sparkles" })
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
