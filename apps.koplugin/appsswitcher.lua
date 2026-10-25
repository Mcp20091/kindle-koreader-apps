--[[--
The app switcher: the apps opened lately, then the recent books, notebooks
and crosswords, as cards (a screen of the launcher). ⋮ > Recent apps in any
app (PluginShare.showSwitcher()) shows it; tapping a card goes
straight there: an app that is still open underneath comes back as it was.

Apps note what was opened in settings.recent_apps (the launcher's taps, and
PluginShare.noteRecent(key) from an app opened another way).
]]

local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Bar = require("appsbar")
local Canvas = require("appscanvas")
local Model = require("appsmodel")

local C = Canvas

local Switcher = {}

-- Tiles that switch something rather than open an app.
local NOT_APPS = { wifi = true, light = true, night = true, refresh = true, web = true, exit = true, restart = true,
    reading = true, kosettings = true }

--- Notes `key` as opened just now (newest first, at most 12).
function Switcher.note(settings, key)
    if not key or NOT_APPS[key] then return end
    local list = { key }
    for __, k in ipairs(settings.recent_apps or {}) do
        if k ~= key and #list < 12 then table.insert(list, k) end
    end
    settings.recent_apps = list
end

--- What a tile's app has open now (a screen still under the launcher), or nil.
local function openWidget(view, tile)
    local name = (tile.plugin or tile.key):match("^[^:@]+")
    local p = name and view:plugin(name)
    if type(p) ~= "table" then return nil end
    for __, field in ipairs({ "screen", "page", "view", "widget" }) do
        local w = p[field]
        if type(w) == "table" and w.paintTo and UIManager:isWidgetShown(w) then return w end
    end
end

--- Goes to a tile: an app open underneath is brought back (what is over it closed), else opened.
function Switcher.go(view, tile)
    local w = not tile.pin and openWidget(view, tile)
    if w then
        local stack = UIManager._window_stack or {}
        local over = {}
        for i = #stack, 1, -1 do
            if stack[i].widget == w then break end
            table.insert(over, stack[i].widget)
        end
        for __, x in ipairs(over) do UIManager:close(x) end
        UIManager:setDirty(w, "full")
        return
    end
    view.mode = "tiles"
    view:open(tile)
end

function Switcher.draw(view, c)
    local s = view.apps.settings
    local all = view:tiles(true)
    local byKey = {}
    for __, t in ipairs(all) do byKey[t.key] = t end
    local apps = {}
    for __, k in ipairs(s.recent_apps or {}) do
        if byKey[k] and #apps < 9 then table.insert(apps, byKey[k]) end
    end
    local y = Bar.H + 16
    c:text(28, y + 6, _("APPS"), 9.5, { bold = true, color = C.GREY })
    y = y + 16
    if #apps == 0 then
        c:text(28, y + 22, _("Apps you open show here."), 11, { color = C.GREY })
        y = y + 40
    end
    -- Cards three across (four on its side): icon, name and its line.
    local cols = c.W > c.H and 4 or 3
    local gap = 12
    local w = (c.W - 56 - (cols - 1) * gap) / cols
    local h = 88
    for i, tile in ipairs(apps) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        local x, ty = 28 + col * (w + gap), y + row * (h + gap)
        c:box(x, ty, w, h, { r = 10, border = C.BLACK, bw = 1.2 })
        c:icon(tile.icon or "app-window", x + 12, ty + 12, 24)
        c:text(x + 12, ty + 58, _(tile.name or tile.key), 12, { bold = true, maxw = w - 24 })
        local line = view:line(tile)
        if line and line ~= "" then c:text(x + 12, ty + 76, line, 9.5, { color = C.GREY, maxw = w - 24 }) end
        c:hit(x, ty, w, h, function() Switcher.go(view, tile) end)
    end
    y = y + math.ceil(#apps / cols) * (h + gap) + 10
    -- The recent books, notebooks and crosswords, as on the launcher.
    local cap = math.max(1, math.min(5, math.floor((c.W - 56 + gap) / (170 + gap))))
    local cw = (c.W - 56 - (cap - 1) * gap) / cap
    for __, g in ipairs({ { _("RECENT BOOKS"), view:recentCards() }, { _("RECENT NOTEBOOKS"), view:notebookCards() },
            { _("RECENT CROSSWORDS"), view:crosswordCards() } }) do
        if #g[2] > 0 and y + 81 < c.H - 10 then
            y = y + view:cardRow(c, y, g[1], g[2], 28, math.min(#g[2], cap), cw) + 6
        end
    end
    local back = function()
        if view.switcherBack then
            -- Shown from another app: back there.
            view.switcherBack = nil
            view.mode = "tiles"
            UIManager:close(view)
        else
            view.mode = "tiles"
            view:refresh()
        end
    end
    view.switcherClose = back
    Bar.draw(c, {
        title = _("Recent"),
        back = back,
        home = function() view.switcherBack = nil view.mode = "tiles" view:refresh() end,
        clock = true,
        refresh = function() view:reload() end,
        bell = require("pluginshare").showNotifications and function() view:showNotifications() end or nil,
        menu = function() view:moreMenu() end,
    })
end

return Switcher
