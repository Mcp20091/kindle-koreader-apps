--[[--
KOReader's own actions (the ones gestures can run: Calibre wireless, progress
sync, Wi-Fi, …) as launcher tiles. The list, titles and groups are
KOReader's (its Dispatcher), so they match the gesture setup screens; only
actions that need no value are offered.

A tile runs its action as a gesture does: on the library or book under the
launcher (appsko.lua passes its events on).

@module koplugin.apps.actions
]]

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Actions = {}

--- The groups, as KOReader's gesture menus name them ("Book" for its reader
-- groups: those need a book open).
Actions.SECTIONS = {
    { "general", _("General") }, { "device", _("Device") }, { "screen", _("Screen and lights") },
    { "filemanager", _("File browser") }, { "reader", _("Book") },
}

-- Dispatcher's actions and their order (kept inside it; read from its own
-- registerAction, which uses both).
local function lists()
    Dispatcher:init()
    local list, order
    for i = 1, 20 do
        local name, v = debug.getupvalue(Dispatcher.registerAction, i)
        if not name then break end
        if name == "settingsList" then list = v elseif name == "dispatcher_menu_order" then order = v end
    end
    return list, order
end

local function inSection(a, section)
    if section == "reader" then return a.reader == true or a.rolling == true or a.paging == true end
    return a[section] == true
end

local function bookOnly(a)
    return inSection(a, "reader") and not a.general and not a.device and not a.screen
end

-- Book-only plugins (progress sync…) add their actions only while a book is
-- open. Those are known here, and others seen are remembered, so they can be
-- picked over the library too.
local KNOWN_BOOK = {
    { "kosync_push_progress", _("Push progress from this device") },
    { "kosync_pull_progress", _("Pull progress from other devices") },
    { "kosync_toggle_autosync", _("Toggle auto progress sync") },
}
local SEEN = "apps_book_actions"

local function bookTitle(key)
    for __, k in ipairs(KNOWN_BOOK) do
        if k[1] == key then return k[2] end
    end
    local seen = G_reader_settings:readSetting(SEEN)
    return seen and seen[key]
end
Actions.bookTitle = bookTitle

--- The actions of a group that need no value: { { key, title } }.
function Actions.list(section)
    local list, order = lists()
    local out = {}
    if not (list and order) then return out end
    local have, seen, added = {}, G_reader_settings:readSetting(SEEN) or {}, false
    for __, k in ipairs(order) do
        local a = list[k]
        if a and a.title and a.condition ~= false and (a.category == "none" or a.category == "arg") and inSection(a, section) then
            table.insert(out, { key = k, title = a.title })
            have[k] = true
            if section == "reader" and bookOnly(a) and seen[k] ~= a.title then
                seen[k] = a.title
                added = true
            end
        end
    end
    if section == "reader" then
        if added then G_reader_settings:saveSetting(SEEN, seen) end
        local extra = {}
        for __, k in ipairs(KNOWN_BOOK) do
            if not have[k[1]] then table.insert(extra, { key = k[1], title = k[2] }) have[k[1]] = true end
        end
        local rest = {}
        for k, title in pairs(seen) do
            if not have[k] then table.insert(rest, { key = k, title = title }) end
        end
        table.sort(rest, function(a, b) return a.title < b.title end)
        for __, x in ipairs(rest) do table.insert(extra, x) end
        for __, x in ipairs(extra) do table.insert(out, x) end
    end
    return out
end

--- An action's settings (title, groups…), or nil when KOReader no longer has it.
function Actions.get(key)
    local list = lists()
    return list and list[key]
end

--- Whether an action works only with a book open.
function Actions.needsBook(key)
    local a = Actions.get(key)
    if a then return bookOnly(a) end
    return bookTitle(key) ~= nil
end

local ICONS = {
    { "wifi", "wifi" }, { "calibre", "library" }, { "kosync", "refresh-cw" }, { "ssh", "terminal" },
    { "night", "moon" }, { "frontlight", "sun" }, { "light", "sun" }, { "refresh", "refresh-cw" },
    { "history", "history" }, { "suspend", "moon" }, { "sleep", "moon" }, { "restart", "power" },
    { "reboot", "power" }, { "poweroff", "power" }, { "exit", "log-out" }, { "search", "search" },
    { "folder", "folder" }, { "favorites", "star" }, { "collections", "star" }, { "dictionary", "book-open" },
    { "rotat", "refresh-cw" }, { "statistics", "activity" }, { "battery", "battery" },
}

function Actions.icon(key)
    for __, m in ipairs(ICONS) do
        if key:find(m[1], 1, true) then return m[2] end
    end
    return "zap"
end

--- Every action, for "Add shortcut": { kind = "action", id, name, icon, group }.
function Actions.choices()
    local out = {}
    for __, s in ipairs(Actions.SECTIONS) do
        for __, a in ipairs(Actions.list(s[1])) do
            table.insert(out, { kind = "action", id = a.key, name = a.title, icon = Actions.icon(a.key), group = s[2] })
        end
    end
    return out
end

--- The line under an action's tile: on or off where KOReader says, else
-- what it needs.
function Actions.status(key, ui)
    if key == "toggle_wifi" or key == "wifi_on" or key == "wifi_off" then
        local ok, on = pcall(function() return require("ui/network/manager"):isWifiOn() end)
        if ok then return on and _("Wi-Fi on") or _("Wi-Fi off") end
    elseif key:find("^calibre_") and key:find("connection") then
        local w = package.loaded["wireless"]
        if type(w) == "table" then return w.calibre_socket and _("Connected") or _("Not connected") end
    elseif key == "kosync_toggle_autosync" then
        local k = ui and ui.kosync
        if k and k.settings then return k.settings.auto_sync and _("Auto sync on") or _("Auto sync off") end
    end
    if Actions.needsBook(key) and not require("apps/reader/readerui").instance then return _("Open a book first") end
    return ""
end

--- Runs an action as a gesture would. False (and a message) when it can't now.
function Actions.run(key)
    local InfoMessage = require("ui/widget/infomessage")
    if Actions.needsBook(key) and not require("apps/reader/readerui").instance then
        require("appsko").toast(_("Open a book first."), 2)
        return false
    end
    if not Actions.get(key) then
        require("appsko").toast(_("KOReader no longer has this action. Hold the tile to remove it."), 3)
        return false
    end
    Dispatcher:execute({ [key] = true })
    return true
end

return Actions
