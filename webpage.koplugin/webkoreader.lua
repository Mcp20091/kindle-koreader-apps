--[[--
KOReader's own settings from the web page:
- Folders: the home folder, the download, screenshot and other folders
  KOReader keeps (and ones plugins add), and your folder shortcuts.
- Power: when the Kindle goes to sleep on its own (Autosuspend).
- The menu: KOReader's whole menu as it is now (the library's, or the book's
  while one is open), browsed from the page. A tap on an item does what a tap
  on the Kindle does: a switch flips here; a choice that opens a dialog opens
  it on the Kindle's screen (the page then shows it, to finish with the remote).
]]

local Common = require("webcommon")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local Web = {}

-- ------------------------------------------------------------------ folders

local function shortcuts()
    local ok, FMS = pcall(require, "apps/filemanager/filemanagershortcuts")
    if not ok then return nil end
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local fm = FileManager and FileManager.instance
    return (fm and fm.folder_shortcuts) or FMS, FMS, fm
end

--- { folders = { { key, name, path } }, shortcuts = { { folder, name } }, lock }
function Web.folders()
    local inst, FMS = shortcuts()
    if not inst then return nil end
    local out = { folders = {}, shortcuts = {}, lock = G_reader_settings:isTrue("lock_home_folder") }
    for __, key in ipairs(FMS.providers or {}) do
        local p = FMS.provider_props[key]
        if p then
            local ok, path = pcall(p.get)
            table.insert(out.folders, { key = key, name = p.name or key, path = ok and path or nil })
        end
    end
    for folder, s in pairs(inst.folder_shortcuts or {}) do
        if s.text then table.insert(out.shortcuts, { folder = folder, name = s.text }) end
    end
    table.sort(out.shortcuts, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

local function refresh(inst, fm)
    if fm then
        pcall(function() inst:refreshFileManager() end)
        pcall(function() fm:updateTitleBarPath() end)
    end
    G_reader_settings:flush()
end

--- One change: { key, path } a KOReader folder; { add = { folder, name } },
-- { rename = { folder, name } } or { remove = folder } a shortcut; { lock }.
function Web.changeFolders(b)
    local inst, FMS, fm = shortcuts()
    if not inst then return "Not available" end
    local function dir(path)
        return type(path) == "string" and path ~= "" and lfs.attributes(path, "mode") == "directory"
    end
    if b.key then
        local p = FMS.provider_props[b.key]
        if not p then return "Unknown folder" end
        if not dir(b.path) then return "No such folder" end
        pcall(function() inst:updateShortcut(b.key, b.path) end)
        p.set(b.path)
    elseif type(b.add) == "table" then
        if not dir(b.add.folder) then return "No such folder" end
        local name = tostring(b.add.name or ""):match("^%s*(.-)%s*$")
        if name == "" then name = b.add.folder:match("([^/]+)/?$") or b.add.folder end
        inst:_addShortcut(b.add.folder, nil, name)
    elseif type(b.rename) == "table" then
        local s = inst.folder_shortcuts[b.rename.folder]
        local name = tostring(b.rename.name or ""):match("^%s*(.-)%s*$")
        if not s or name == "" then return "No such shortcut" end
        s.text = name
    elseif type(b.remove) == "string" then
        inst:_delShortcut(b.remove)
    elseif type(b.lock) == "boolean" then
        G_reader_settings:saveSetting("lock_home_folder", b.lock)
    else
        return "Nothing to change"
    end
    refresh(inst, fm)
end

-- ------------------------------------------------------------------ power

--- Autosuspend: seconds before the Kindle sleeps on its own (-1 never), when KOReader has it.
function Web.power()
    local ui = Common.ui()
    local a = ui and ui.autosuspend
    if not a then return { available = false } end
    return { available = true, suspend = a.auto_suspend_timeout_seconds, kindle = require("device"):isKindle() }
end

function Web.setPower(b)
    local ui = Common.ui()
    local a = ui and ui.autosuspend
    if not a then return "Not available" end
    local secs = tonumber(b.suspend)
    if not secs then return "No time" end
    secs = secs <= 0 and -1 or math.max(60, math.min(24 * 3600, math.floor(secs)))
    a.auto_suspend_timeout_seconds = secs
    G_reader_settings:saveSetting("auto_suspend_timeout_seconds", secs)
    G_reader_settings:flush()
    -- As KOReader's own menu (and the launcher's Sleep after) do; on a Kindle
    -- the power manager's timer follows too.
    pcall(function()
        a:_unschedule()
        a:_start()
        if a._unschedule_kindle then
            a:_unschedule_kindle()
            a:_start_kindle()
        end
    end)
end

-- ------------------------------------------------------------------ the menu

local TAB_NAMES = {
    ["appbar.filebrowser"] = _("File browser"), ["appbar.settings"] = _("Settings"), ["appbar.tools"] = _("Tools"),
    ["appbar.search"] = _("Search"), ["appbar.menu"] = _("Main"), ["appbar.navigation"] = _("Navigation"),
    ["appbar.typeset"] = _("Typeset"), ["appbar.pageview"] = _("Page view"), ["appbar.textsize"] = _("Text"),
    ["appbar.contrast"] = _("Contrast"),
}

local function tabs()
    local ui = Common.ui()
    local menu = ui and ui.menu
    if not menu then return nil end
    if menu.tab_item_table == nil and menu.setUpdateItemTable then menu:setUpdateItemTable() end
    return menu.tab_item_table, ui
end

local function call(f, ...)
    if type(f) ~= "function" then return f end
    local ok, v = pcall(f, ...)
    return ok and v or nil
end

-- An item's name as the menu shows it (without the ▸ of a submenu).
local function nameOf(item)
    local text = item.text_func and call(item.text_func) or item.text
    return tostring(text or "")
end

-- A stand-in for the open menu, for callbacks that update or close it.
local touchmenu = { updateItems = function() end, closeMenu = function() end, item_table_stack = {} }

--- The items at `path` ("2.5": the second tab's fifth item): list, the
-- items' titles on the way, or nil, why.
local function resolve(path)
    local tt = tabs()
    if not tt then return nil, "KOReader's menu isn't ready" end
    local list, trail = nil, {}
    for i, part in ipairs(path) do
        if i == 1 then
            list = tt[part]
            if not list then return nil, "No such tab" end
            table.insert(trail, TAB_NAMES[list.icon] or list.icon or "")
        else
            local item = list[part]
            if type(item) ~= "table" then return nil, "No such item" end
            local sub = item.sub_item_table_func and call(item.sub_item_table_func) or item.sub_item_table
            if type(sub) ~= "table" then return nil, "Not a menu" end
            table.insert(trail, nameOf(item))
            list = sub
        end
    end
    return list, trail
end

local function parse(s)
    local path = {}
    for n in tostring(s or ""):gmatch("%d+") do table.insert(path, tonumber(n)) end
    return path
end

local function describe(item)
    local text = nameOf(item)
    local enabled = item.enabled ~= false
    if item.enabled_func then enabled = call(item.enabled_func) and true or false end
    local checked = item.checked_func and call(item.checked_func) or item.checked
    local help = item.help_text_func and call(item.help_text_func) or item.help_text
    local d = {
        text = text, enabled = enabled,
        checked = nil,
        radio = item.radio or nil,
        sub = (item.sub_item_table ~= nil or item.sub_item_table_func ~= nil) or nil,
        action = (item.callback ~= nil or item.callback_func ~= nil or item.tap_input ~= nil or item.tap_input_func ~= nil) or nil,
        hold = (item.hold_callback ~= nil or item.hold_input ~= nil) or nil,
        separator = item.separator or nil,
        help = type(help) == "string" and help or nil,
    }
    -- A switch or a choice: on or off (false kept: it shows an empty box).
    if item.checked_func or item.checked ~= nil then d.checked = checked and true or false end
    return d
end

--- { tabs = { names }, trail, items } for `path` (just the tabs for "").
function Web.menu(pathText)
    local tt, ui = tabs()
    if not tt then return nil, "KOReader's menu isn't ready" end
    local out = { tabs = {}, book = ui.document ~= nil }
    for i, t in ipairs(tt) do out.tabs[i] = TAB_NAMES[t.icon] or tostring(t.icon or i) end
    local path = parse(pathText)
    if #path == 0 then return out end
    local list, trail = resolve(path)
    if not list then return nil, trail end
    out.trail = trail
    out.items = {}
    for i, item in ipairs(list) do
        if type(item) == "table" then
            local ok, d = pcall(describe, item)
            out.items[i] = ok and d or { text = "?", enabled = false }
        end
    end
    return out
end

--- A tap (or hold) on the item at `path`, as on the Kindle. Returns
-- { opened = true when something showed on the Kindle's screen } or nil, why.
function Web.tap(pathText, hold)
    local path = parse(pathText)
    if #path < 2 then return nil, "No item" end
    local last = table.remove(path)
    local list, why = resolve(path)
    if not list then return nil, why end
    local item = list[last]
    if type(item) ~= "table" then return nil, "No such item" end
    local before = #UIManager._window_stack
    local ok, err
    if hold then
        if item.hold_input or item.hold_input_func then
            ok, err = pcall(require("ui/widget/container/inputcontainer").onInput, touchmenu, item.hold_input or item.hold_input_func())
        elseif item.hold_callback then
            ok, err = pcall(item.hold_callback, touchmenu, item)
        else
            return nil, "Nothing to do"
        end
    elseif item.tap_input or item.tap_input_func then
        ok, err = pcall(require("ui/widget/container/inputcontainer").onInput, touchmenu, item.tap_input or item.tap_input_func())
    else
        local cb = item.callback_func and call(item.callback_func) or item.callback
        if not cb then return nil, "Nothing to do" end
        ok, err = pcall(cb, touchmenu)
    end
    if not ok then return nil, tostring(err) end
    G_reader_settings:flush()
    return { opened = #UIManager._window_stack > before }
end

function Web.routes(server)
    server:route("GET", "^/api/koreader/folders$", function(req, res)
        local f = Web.folders()
        if not f then return res:error(404, "Not available") end
        f.root = require("webfiles").root()
        res:json(f)
    end)

    server:route("POST", "^/api/koreader/folders$", function(req, res)
        local why = Web.changeFolders(req.json())
        if why then return res:error(400, why) end
        res:json(Web.folders())
    end)

    server:route("GET", "^/api/koreader/power$", function(req, res) res:json(Web.power()) end)

    server:route("POST", "^/api/koreader/power$", function(req, res)
        local why = Web.setPower(req.json())
        if why then return res:error(400, why) end
        res:json(Web.power())
    end)

    -- KOReader's most-used settings (the launcher's appskosettings.lua, the same list as on the Kindle).
    server:route("GET", "^/api/koreader/common$", function(req, res)
        local ok, S = pcall(require, "appskosettings")
        if not ok then return res:json({ available = false }) end
        -- The font and its size are on the Fonts tab, with KOReader's other font settings.
        local items = {}
        for __, it in ipairs(S.items()) do
            if it.key ~= "font" and it.key ~= "font_size" then table.insert(items, it) end
        end
        res:json({ available = true, items = items })
    end)

    server:route("POST", "^/api/koreader/common$", function(req, res)
        local ok, S = pcall(require, "appskosettings")
        if not ok then return res:error(404, "The launcher isn't installed") end
        local b = req.json() or {}
        if type(b.key) ~= "string" then return res:error(400, "No setting") end
        local msg = S.set(b.key, b.value)
        res:json({ ok = msg == nil, message = msg })
    end)

    server:route("GET", "^/api/koreader/menu$", function(req, res)
        local m, why = Web.menu(req.query.path)
        if not m then return res:error(400, why) end
        res:json(m)
    end)

    server:route("POST", "^/api/koreader/menu/tap$", function(req, res)
        local b = req.json()
        local r, why = Web.tap(b.path, b.hold == true)
        if not r then return res:error(400, why) end
        res:json(r)
    end)
end

return Web
