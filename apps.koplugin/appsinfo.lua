--[[--
What each app says about itself, for the launcher and the web page: its
tiles, their lines, where it goes in Settings, its gestures, its name in the
notifications and its web page tab. An app adds its entry at start, as a
plain table on PluginShare (like PS.backupApps, so load order doesn't
matter), and nothing in the launcher or the web server needs to change for a
new app:

    local PS = require("pluginshare")
    PS.appInfo = PS.appInfo or {}
    PS.appInfo.sshclient = {            -- the plugin's name (its folder without .koplugin)
        name = _("SSH"), icon = "terminal",
        order = 70,                     -- its place among the apps (tiles, Settings, web tabs)
        group = "tools",                -- its group: in Settings (appshub's DEFAULT_GROUPS, by
                                        -- id) and the home screen's suggested groups (appsmodel's
                                        -- SUGGESTED_GROUPS, by key); none: Other, and no group
        tiles = { {                     -- its launcher tiles (none: no tile)
            key = "ssh",                -- saved orders, hidden tiles and pins keep it: never change it
            name = _("SSH"), icon = "terminal",   -- (left out: the app's)
            event = "ShowSSH",          -- what a tap sends; or open = function() ... end
            line = function(plugin) return plugin:appsLine() end,   -- the line under its name (plugin:
                                        -- the app's, on the screen now; open gets it too)
            shown = function() return true end,   -- (optional) only shown while this says so (no
                                        -- plugin given: use the app's own, as Home Assistant.instance)
            group = "tools",            -- (optional) this tile's suggested group, if not the app's
            switches = true,            -- (optional) a tap switches something: not a recent app
            fresh = true,               -- (optional) a tap opens it anew, not the app's screen left open
            labels = false,             -- (optional) no Button labels setting of its own (Settings >
                                        -- Launcher > Button labels lists an app's first tile)
        } },
        explore = _("Run commands on your devices"),   -- (optional) in Set up your Kindle's More to
                                        -- explore: it's ready to use without setting anything up
        gestures = { "^sshclient_" },   -- its gesture actions, that work over the apps
                                        -- (left out: "^<plugin>_")
        web = {                         -- its web page tab (needs the web server)
            page = "ssh",               -- the tab's #page and App.pages key
            name = "SSH",               -- the tab's name (left out: the app's)
            card = "Hosts, the command list and keys.",   -- its card on the page's Home
            routes = "webssh",          -- a module in the app's folder with routes(server)
            script = "web/ssh.js",      -- the tab's script, in the app's web/ folder (served
                                        -- from there with anything else in that folder)
            dir = here,                 -- the app's folder: (debug.getinfo(1, "S").source or
                                        -- ""):match("^@(.*)/[^/]+$"), as the setup images do
        },
    }

Names are translated by the app (_()); the launcher's _() on them again
leaves them as they are. Everything here is read when it's needed, never
at start.
]]

local Info = {}

--- The registered apps' entries (PluginShare's appInfo), or `info` when given (the tests).
function Info.all(info)
    if info then return info end
    local ok, PS = pcall(require, "pluginshare")
    return ok and type(PS) == "table" and PS.appInfo or {}
end

--- The apps in order: { { plugin, entry } }, by `order` then name.
function Info.list(info)
    local out = {}
    for plugin, e in pairs(Info.all(info)) do
        if type(e) == "table" then table.insert(out, { plugin = plugin, entry = e }) end
    end
    table.sort(out, function(a, b)
        local oa, ob = tonumber(a.entry.order) or 999, tonumber(b.entry.order) or 999
        if oa ~= ob then return oa < ob end
        return tostring(a.entry.name or a.plugin) < tostring(b.entry.name or b.plugin)
    end)
    return out
end

--- Every app's tiles, in the apps' order: { key, name, icon, plugin, event, open, line, shown, group, switches }.
function Info.tiles(info)
    local out = {}
    for __, a in ipairs(Info.list(info)) do
        for __, t in ipairs(a.entry.tiles or {}) do
            if type(t) == "table" and t.key then
                local tile = {}
                for k, v in pairs(t) do tile[k] = v end
                tile.name = tile.name or a.entry.name or a.plugin
                tile.icon = tile.icon or a.entry.icon or "app-window"
                tile.plugin = tile.plugin or a.plugin
                tile.group = tile.group or a.entry.group
                tile.app = a.plugin
                table.insert(out, tile)
            end
        end
    end
    return out
end

--- The tile of this key, or nil.
function Info.tile(key, info)
    for __, t in ipairs(Info.tiles(info)) do
        if t.key == key then return t end
    end
end

--- The apps' plugin names in order (Settings' list puts their entries in this order).
function Info.order(info)
    local out = {}
    for __, a in ipairs(Info.list(info)) do table.insert(out, a.plugin) end
    return out
end

--- The patterns of the apps' gesture actions (those that make sense over the apps).
function Info.gestures(info)
    local out = {}
    for __, a in ipairs(Info.list(info)) do
        local g = a.entry.gestures
        if type(g) == "string" then g = { g } end
        if type(g) ~= "table" then g = { "^" .. a.plugin:gsub("%p", "%%%0") .. "_" } end
        for __, pat in ipairs(g) do table.insert(out, pat) end
    end
    return out
end

--- An app's name and icon (for the notifications list), or nil.
function Info.nameOf(plugin, info)
    local e = plugin and Info.all(info)[plugin]
    if type(e) == "table" then return e.name, e.icon end
end

--- The apps with their own Button labels setting: { { key (the tile's), plugin, name } }.
-- An app's first tile, unless it says labels = false.
function Info.labelApps(info)
    local out = {}
    for __, a in ipairs(Info.list(info)) do
        local t = (a.entry.tiles or {})[1]
        if type(t) == "table" and t.key and t.labels ~= false and not t.switches then
            table.insert(out, { key = t.key, plugin = a.plugin, name = t.name or a.entry.name or a.plugin })
        end
    end
    return out
end

--- The apps' web page tabs, in order: { { page, name, plugin, routes, script, dir } }.
function Info.webTabs(info)
    local out = {}
    for __, a in ipairs(Info.list(info)) do
        local w = a.entry.web
        if type(w) == "table" and (w.page or w.routes) then
            table.insert(out, { page = w.page, name = w.name or a.entry.name or a.plugin, plugin = a.plugin,
                routes = w.routes, script = w.script, dir = w.dir })
        end
    end
    return out
end

return Info
