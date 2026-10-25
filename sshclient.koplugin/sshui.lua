--[[--
The SSH app's screens, with KOReader's own lists and dialogs:
  SSH          the hosts; Run on several hosts, Keys, Command list
  a host       Run a command, Live session, its saved commands (tap: run),
               Recent commands, Edit host
  Edit host    name, address, user, port, sign-in, password
  Keys         make a key on this Kindle or import one; show the public key
  Command list the commands Commands pastes (for every host)
]]

local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local PathChooser = require("ui/widget/pathchooser")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local Dark = require("sshdark")
local KO = require("sshko")
local K = require("sshkeys")
local M = require("sshmodel")
local Run = require("sshrun")

local UI = {}

local AUTH_NAMES = { key = _("Key"), password = _("Password"), ask = _("Ask for password") }

local function info(text)
    KO.message(text)
end

local function short(s, n)
    s = tostring(s or ""):gsub("\n", " ")
    n = n or 28
    if #s <= n then return s end
    return s:sub(1, n - 1) .. "…"
end

-- The pages open now, oldest first (Home closes them all).
UI.pages = {}

--- The Apps launcher (when it's installed).
function UI.launcher()
    if KO.home() then return end
    local plugin = UI.plugin
    if plugin and plugin.ui and plugin.ui.apps then plugin.ui:handleEvent(Event:new("ShowApps")) end
end

--- ⋮: Add host, Run on several hosts, Keys, Command list, then Recent apps,
-- Light, Night mode and Refresh screen.
function UI.more()
    local plugin = UI.plugin
    if not plugin then return end
    KO.menu(plugin.ui, {
        { _("Add host"), function() UI.addHost(plugin) end },
        { _("Run on several hosts"), function() UI.several(plugin) end },
        { _("Keys"), function() UI.keys(plugin) end },
        { _("Command list"), function() UI.commandList(plugin) end },
        { _("History"), function() require("sshscreens").history(plugin) end },
    }, function() require("sshscreens").settings(plugin) end,
    -- (SSH's dark terminal gives way to KOReader's Night mode)
    function() Dark.release() end)
end

--- Home: every SSH page closes, then the launcher.
function UI.home()
    local pages = {}
    for i, p in ipairs(UI.pages) do pages[i] = p end
    for i = #pages, 1, -1 do pages[i]:onCloseAllMenus() end
    UI.launcher()
end

-- SSH's full-screen pages (sshpage: drawn as the other apps' pages; the
-- items are described there).
local List = require("sshpage")

--- The page on top, as the plugin's `screen` (the launcher's recent apps bring it back).
function UI.noteScreen()
    if UI.plugin then UI.plugin.screen = UI.pages[#UI.pages] end
end

--- Shows a list page; items is the items, or a function making them (then
-- Refresh makes them again).
local function list(title, items, subtitle)
    local fn = type(items) == "function" and items or nil
    local m = List:new{ title = title, subtitle = subtitle, item_table = fn and fn() or items, items_fn = fn }
    UIManager:show(m)
    return m
end

local function refresh(m, items, title)
    m:switchItemTable(title, items, -1)
end

--- One line of text: cb(text) on Save (not on Cancel). opts: { number,
-- password, description, ok, kind ("name": a pen or Write it, for
-- handwriting; none for exact values: addresses, users, ports) }. The
-- launcher's text box (numbers and passwords too), or KOReader's.
local function ask(title, value, cb, opts)
    opts = opts or {}
    local request = KO.request()
    if request then
        return request{ title = title, subtitle = opts.description, text = value or "",
            number = opts.number, password = opts.password, width = opts.width,
            pen = opts.kind and KO.pen() or nil, penTitle = title, penKind = opts.kind, typing = true,
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = "check", text = opts.ok or _("Save"), primary = true, fn = function(v) cb(v) end },
            } }
    end
    local dialog
    local row = {
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
        { text = opts.ok or _("Save"), is_enter_default = true, callback = function()
            local v = dialog:getInputText()
            UIManager:close(dialog)
            cb(v)
        end },
    }
    if opts.kind and not opts.password then KO.withWrite(row, function() return dialog end, opts.kind) end
    dialog = InputDialog:new{
        title = title,
        input = value or "",
        input_type = opts.number and "number" or nil,
        text_type = opts.password and "password" or nil,
        description = opts.description,
        buttons = { row },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- A text box (a number with opts.number); cb(text).
UI.ask = function(...) return ask(...) end

-- ------------------------------------------------------------------ commands

--- Choose a filter for the command list: (for a host) its system, All,
-- Custom (your own commands), or a system. cb(filter).
function UI.chooseFilter(host_os, cb, current)
    local options = {}
    if host_os then options[#options + 1] = { label = T(_("This host: %1"), M.osName(host_os)), value = host_os } end
    options[#options + 1] = { label = _("All"), value = "all" }
    options[#options + 1] = { label = _("Custom"), value = "custom" }
    for __, o in ipairs(M.OSES) do
        -- (the host's own is already first)
        if o.id ~= host_os then options[#options + 1] = { label = o.name, value = o.id } end
    end
    KO.choose(_("Show commands"), options, current, cb)
end

-- The filter last chosen, per host (and "" for no host), while KOReader runs.
UI.filters = {}

--- Commands to paste: the clipboard, the host's saved ones, its recent ones,
-- then the command list, shown for the host's system (Show changes it).
-- cb(cmd) with the one tapped, cb(nil) when closed.
function UI.pickCommand(plugin, host, cb)
    local data = plugin.store.data
    local host_os = host and M.hostOS(host)
    local key = host and host.id or ""
    local done = false
    local m
    local function pick(cmd)
        done = true
        UIManager:close(m)
        cb(cmd)
    end
    local function items()
        local t = {}
        local f = UI.filters[key] or host_os or "all"
        t[#t + 1] = { setting = true, text = _("Show"), value = M.filterName(f), callback = function()
            UI.chooseFilter(host_os, function(nf)
                UI.filters[key] = nf
                m:switchItemTable(nil, items(), 1)
            end, f)
        end }
        -- the clipboard first (Copy text, or text copied elsewhere in KOReader)
        local clip = Device.input.hasClipboardText() and Device.input.getClipboardText() or ""
        if clip ~= "" then
            t[#t + 1] = { text = _("Paste"), sub = clip, mono = true, icon = "copy", callback = function() pick(clip) end }
        end
        local function add(c)
            t[#t + 1] = { text = M.commandName(c), sub = c.cmd, mono = true, icon = "play",
                callback = function() pick(c.cmd) end }
        end
        if host then
            if #host.commands > 0 then t[#t + 1] = { band = _("SAVED ON THIS HOST"), right = tostring(#host.commands) } end
            for __, c in ipairs(host.commands) do add(c) end
            if #host.recent > 0 then t[#t + 1] = { band = _("RECENT"), right = tostring(#host.recent) } end
            for __, r in ipairs(host.recent) do
                t[#t + 1] = { text = r, monoText = true, icon = "history", callback = function() pick(r) end }
            end
        end
        local listed = M.filter(data.commands, f)
        t[#t + 1] = { band = _("COMMAND LIST"), right = tostring(#listed) }
        for __, c in ipairs(listed) do add(c) end
        return t
    end
    m = List:new{ title = _("Commands"), item_table = items(), items_fn = items,
        close_callback = function() if not done then cb(nil) end end }
    UIManager:show(m)
end

--- A command typed (or written) for something else than running it now (a
-- custom sensor's): Commands pastes one in; done(command) on OK.
function UI.runDialogText(plugin, host, title, initial, done)
    local request = KO.request()
    if request then
        return request{ title = title, text = initial or "", hint = "cat /sys/class/thermal/thermal_zone0/temp",
            pen = KO.pen(), penTitle = _("Write the command"), penKind = "command", typing = true, buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = "list", text = _("Commands"), keep = true, fn = function(__, box)
                    box:stopTyping()
                    UI.pickCommand(plugin, host, function(cmd)
                        if cmd then box:setText(cmd) end
                        box:startTyping()
                    end)
                end },
                { icon = "check", text = _("OK"), primary = true, needsText = true, fn = function(cmd) done(cmd) end },
            } }
    end
    ask(title, initial or "", function(cmd)
        if cmd:match("%S") then done(cmd) end
    end, { ok = _("OK"), kind = "command" })
end

--- The command box: Commands pastes one in, Save keeps it on the host
-- (none on several hosts), Run runs it.
function UI.runDialog(plugin, host, initial, on_run)
    local function saveOnHost(cmd)
        ask(_("Name"), "", function(name)
            table.insert(host.commands, { id = M.newId(plugin.store.data, "c"), name = name, cmd = cmd })
            plugin:saved()
            if UI.hostMenu then UI.refreshHost(plugin, host) end
        end, { description = cmd, kind = "name" })
    end
    -- The launcher's text box: a pen to write the command, Commands, Save, Run.
    local request = KO.request()
    if request then
        local buttons = {
            { icon = "x", text = _("Cancel"), cancel = true },
            { icon = "list", text = _("Commands"), keep = true, fn = function(__, box)
                box:stopTyping()
                UI.pickCommand(plugin, host, function(cmd)
                    if cmd then
                        local now = box:getText() or ""
                        box:setText(now:match("%S") and (now:gsub("%s+$", "") .. " " .. cmd) or cmd)
                    end
                    box:startTyping()
                end)
            end },
        }
        if host then
            buttons[#buttons + 1] = { icon = "download", text = _("Save"), needsText = true, fn = function(cmd) saveOnHost(cmd) end }
        end
        buttons[#buttons + 1] = { icon = "terminal", text = _("Run"), primary = true, needsText = true, fn = function(cmd) on_run(cmd) end }
        return request{ title = host and T(_("Run on %1"), M.hostName(host)) or _("Run on several hosts"),
            text = initial or "", hint = "uptime", pen = KO.pen(), penTitle = _("Write the command"), penKind = "command",
            typing = true, buttons = buttons }
    end
    local dialog
    local function insert()
        dialog:onCloseKeyboard()
        UI.pickCommand(plugin, host, function(cmd)
            if cmd then dialog:addTextToInput(cmd) end
            dialog:onShowKeyboard()
        end)
    end
    local row = {
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
        { text = _("Commands"), callback = insert },
    }
    if host then
        row[#row + 1] = { text = _("Save"), callback = function()
            local cmd = dialog:getInputText()
            if not cmd:match("%S") then return end
            UIManager:close(dialog)
            saveOnHost(cmd)
        end }
    end
    row[#row + 1] = { text = _("Run"), is_enter_default = true, callback = function()
        local cmd = dialog:getInputText()
        if not cmd:match("%S") then return end
        UIManager:close(dialog)
        on_run(cmd)
    end }
    KO.withWrite(row, function() return dialog end, "command")
    dialog = InputDialog:new{
        title = host and T(_("Run on %1"), M.hostName(host)) or _("Run on several hosts"),
        input = initial or "",
        input_face = require("ui/font"):getFace("smallinfont", 20),
        allow_newline = false,
        buttons = { row },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Edit a command (name, command and system); cb("save", name, cmd, os) or
-- cb("delete"). One even row: Cancel, Write it (with handwriting: into the
-- field being typed in), Delete, the system (tap to choose) and Save.
local function editCommand(c, cb, can_delete, title)
    local os_id = c and c.os
    -- The launcher's box: the command in the field (a pen to write it), its
    -- name and system under the title, Name and System to change them.
    local request = KO.request()
    if request then
        local name = c and c.name or ""
        local function subtitle()
            return T(_("Name: %1 · System: %2"), name ~= "" and name or _("none"), M.osName(os_id))
        end
        local buttons = { { icon = "x", text = _("Cancel"), cancel = true } }
        if can_delete then
            buttons[#buttons + 1] = { icon = "trash-2", text = _("Delete"), fn = function() cb("delete") end }
        end
        buttons[#buttons + 1] = { icon = "type", text = _("Name"), keep = true, fn = function(__, box)
            box:stopTyping()
            ask(_("Name"), name, function(v)
                name = v
                box.subtitle = subtitle()
                box:redraw()
            end, { kind = "name" })
        end }
        buttons[#buttons + 1] = { icon = "list", text = _("System"), keep = true, fn = function(__, box)
            box:stopTyping()
            local function set(id)
                os_id = id
                box.subtitle = subtitle()
                box:redraw()
            end
            local items = { { text = M.osName(nil), checked = os_id == nil, fn = function() set(nil) end },
                { text = M.osName("linux"), checked = os_id == "linux", fn = function() set("linux") end } }
            for __, o in ipairs(M.OSES) do
                if o.id ~= "linux" then
                    items[#items + 1] = { text = o.name, checked = os_id == o.id, fn = function() set(o.id) end }
                end
            end
            KO.list(_("System"), items)
        end }
        buttons[#buttons + 1] = { icon = "check", text = _("Save"), primary = true, needsText = true, fn = function(cmd)
            cb("save", name, cmd, os_id)
        end }
        return request{ title = title or (can_delete and _("Edit command") or _("New command")), subtitle = subtitle(),
            text = c and c.cmd or "", hint = "uptime", pen = KO.pen(), penTitle = _("Write the command"),
            penKind = "command", typing = true, buttons = buttons }
    end
    local dialog
    local function systemText() return M.osName(os_id) end
    local row = { { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end } }
    if can_delete then
        row[#row + 1] = { text = _("Delete"), callback = function()
            UIManager:close(dialog)
            cb("delete")
        end }
    end
    row[#row + 1] = { text = systemText(), id = "system", callback = function()
        dialog:onCloseKeyboard()
        local rows = { { { text = M.osName(nil), callback = function() os_id = nil end },
            { text = M.osName("linux"), callback = function() os_id = "linux" end } } }
        local r = {}
        for __, o in ipairs(M.OSES) do
            if o.id ~= "linux" then
                r[#r + 1] = { text = o.name, callback = function() os_id = o.id end }
                if #r == 2 then
                    rows[#rows + 1] = r
                    r = {}
                end
            end
        end
        if #r > 0 then rows[#rows + 1] = r end
        -- each choice also shows it on the button
        for __, rr in ipairs(rows) do
            for __, b in ipairs(rr) do
                local set = b.callback
                b.callback = function()
                    set()
                    local btn = dialog.button_table:getButtonById("system")
                    if btn then
                        btn:setText(systemText(), btn.width)
                        UIManager:setDirty(dialog, "ui")
                    end
                    dialog:onShowKeyboard()
                end
            end
        end
        UI.holdMenu(_("System"), rows)
    end }
    row[#row + 1] = { text = _("Save"), callback = function()
        local f = dialog:getFields()
        if not f[2]:match("%S") then return end
        UIManager:close(dialog)
        cb("save", f[1], f[2], os_id)
    end }
    KO.withWrite(row, function() return dialog end, "command")
    dialog = MultiInputDialog:new{
        title = title or (can_delete and _("Edit command") or _("New command")),
        fields = {
            { description = _("Name"), text = c and c.name or "", hint = _("Uptime") },
            { description = _("Command"), text = c and c.cmd or "", hint = "uptime" },
        },
        buttons = { row },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

UI.editCommand = editCommand

--- Copy to a host: choose the host, then change the copy before it's saved
-- with the host's commands.
local function copyToHost(plugin, c, back)
    local hosts = plugin.store.data.hosts
    if #hosts == 0 then return info(_("Add a host first.")) end
    local items = {}
    for __, h in ipairs(hosts) do
        items[#items + 1] = { text = M.hostName(h), fn = function()
            editCommand(c, function(__, name, cmd, os_id)
                table.insert(h.commands, { id = M.newId(plugin.store.data, "c"), name = name, cmd = cmd, os = os_id })
                plugin:saved()
                if UI.hostMenu then UI.refreshHost(plugin, h) end
                KO.toast(T(_("Saved to %1."), M.hostName(h)))
            end, false, T(_("Copy to %1"), M.hostName(h)))
        end }
    end
    KO.list(_("Copy to a host"), items, back)
end

--- A long-press menu (the apps' pop-up list): rows of { text, callback,
-- enabled }, one after the other; the menu closes before the callback runs.
-- back: a menu opened from another one (Back instead of Close).
local function holdMenu(title, rows, back)
    local items = {}
    for __, row in ipairs(rows) do
        for __, b in ipairs(row) do
            items[#items + 1] = { text = b.text, enabled = b.enabled ~= false, fn = function() b.callback() end }
        end
    end
    KO.list(title, items, back)
end
UI.holdMenu = holdMenu

local function copyText(text)
    Device.input.setClipboardText(text)
    KO.toast(_("Copied."))
end

--- Asks before deleting; then fn().
local function confirmDelete(what, fn)
    KO.confirm{ text = T(_("Delete %1?"), what), ok = _("Delete"), danger = true, onOk = fn }
end

--- Deletes at once with Undo (the apps' undo bar), or asks first without
-- it. remove() deletes and returns a function that puts it back; after() runs
-- after either (to redraw). The data is saved each time.
local function deleteWithUndo(plugin, what, remove, after)
    local function go()
        local putBack = remove()
        plugin:saved()
        if after then after() end
        if putBack and KO.canUndo() then
            KO.undo(T(_("Deleted %1."), what), function()
                putBack()
                plugin:saved()
                if after then after() end
            end)
        end
    end
    if KO.canUndo() then go() else confirmDelete(what, go) end
end
UI.deleteWithUndo = deleteWithUndo

--- Takes item out of list; returns what puts it back where it was.
local function takeOut(list, item)
    for i, x in ipairs(list) do
        if x == item then
            table.remove(list, i)
            return function() table.insert(list, math.min(i, #list + 1), item) end
        end
    end
end

--- Long-press on a command in a list: first rows (Run…), then Edit, Copy
-- (changed before it's saved, below the original), Copy to a host, Copy text,
-- Move up, Move down, Delete.
local function commandActions(plugin, cmds, i, after, first)
    local c = cmds[i]
    local rows = {}
    for __, r in ipairs(first or {}) do rows[#rows + 1] = r end
    rows[#rows + 1] = {
        { text = _("Edit"), callback = function()
            editCommand(c, function(what, name, cmd, os_id)
                if what == "delete" then
                    return deleteWithUndo(plugin, M.commandName(c), function() return takeOut(cmds, c) end, after)
                end
                c.name, c.cmd, c.os = name, cmd, os_id
                plugin:saved()
                after()
            end, true)
        end },
        { text = _("Copy"), callback = function()
            editCommand(c, function(__, name, cmd, os_id)
                table.insert(cmds, i + 1, { id = M.newId(plugin.store.data, "c"), name = name, cmd = cmd, os = os_id })
                plugin:saved()
                after()
            end, false, _("Copy command"))
        end },
    }
    rows[#rows + 1] = {
        { text = _("Copy to a host"), callback = function()
            -- (Back: this menu again)
            copyToHost(plugin, c, function()
                for j, x in ipairs(cmds) do
                    if x == c then return commandActions(plugin, cmds, j, after, first) end
                end
            end)
        end },
        { text = _("Copy text"), callback = function() copyText(c.cmd) end },
    }
    rows[#rows + 1] = {
        { text = _("Move up"), enabled = i > 1, callback = function()
            M.move(cmds, i, -1)
            plugin:saved()
            after()
        end },
        { text = _("Move down"), enabled = i < #cmds, callback = function()
            M.move(cmds, i, 1)
            plugin:saved()
            after()
        end },
    }
    rows[#rows + 1] = {
        { text = _("Delete"), callback = function()
            deleteWithUndo(plugin, M.commandName(c), function() return takeOut(cmds, c) end, after)
        end },
    }
    holdMenu(M.commandName(c), rows)
end

--- Run on a host: choose the host; the command opens in its command box.
local function runOnHost(plugin, cmd, back)
    local rows = {}
    for __, h in ipairs(plugin.store.data.hosts) do
        rows[#rows + 1] = { { text = M.hostName(h), callback = function()
            UI.runDialog(plugin, h, cmd, function(c) Run.command(plugin, h, c) end)
        end } }
    end
    if #rows == 0 then return info(_("Add a host first.")) end
    holdMenu(_("Run on a host"), rows, back)
end

--- Command list: the commands Commands offers on every host; Show filters
-- them (All, Custom, a system).
function UI.commandList(plugin)
    local data = plugin.store.data
    local m
    local function items()
        local t = {}
        local f = UI.filters.list or "all"
        t[#t + 1] = { setting = true, text = _("Show"), value = M.filterName(f), callback = function()
            UI.chooseFilter(nil, function(nf)
                UI.filters.list = nf
                refresh(m, items())
            end, f)
        end }
        local shown = M.filter(data.commands, f)
        t[#t + 1] = { band = _("COMMANDS"), right = tostring(#shown) }
        for j, c in ipairs(shown) do
            local function index()
                for i, x in ipairs(data.commands) do
                    if x == c then return i end
                end
            end
            t[#t + 1] = { text = M.commandName(c), sub = c.cmd, mono = true, icon = M.isBuiltIn(c) and "list" or "terminal",
                right = c.os and M.osName(c.os) or nil,
                callback = function()
                    editCommand(c, function(what, name, cmd, os_id)
                        if what == "delete" then
                            return deleteWithUndo(plugin, M.commandName(c), function() return takeOut(data.commands, c) end,
                                function() refresh(m, items()) end)
                        end
                        c.name, c.cmd, c.os = name, cmd, os_id
                        plugin:saved()
                        refresh(m, items())
                    end, true)
                end,
                hold_callback = function()
                    local function menu()
                        local i = index()
                        if not i then return end
                        commandActions(plugin, data.commands, i, function() refresh(m, items()) end, {
                            { { text = _("Run on a host"), callback = function() runOnHost(plugin, c.cmd, menu) end } },
                        })
                    end
                    menu()
                end }
        end
        t[#t + 1] = { text = _("Add command"), icon = "plus", callback = function()
            -- a new one belongs to the system shown
            local os_id = (f ~= "all" and f ~= "custom") and f or nil
            editCommand({ name = "", cmd = "", os = os_id }, function(__, name, cmd, nos)
                table.insert(data.commands, { id = M.newId(data, "c"), name = name, cmd = cmd, os = nos })
                plugin:saved()
                refresh(m, items())
            end, false, _("New command"))
        end }
        t[#t + 1] = { text = _("Restore built-in commands"), icon = "rotate-ccw", callback = function()
            local n = M.addBuiltIn(data)
            plugin:saved()
            refresh(m, items())
            KO.toast(n == 0 and _("All built-in commands are in the list.") or T(_("Added %1 commands."), n))
        end }
        return t
    end
    m = list(_("Command list"), items, _("Commands pastes these on any host. Long-press for more."))
end

-- ------------------------------------------------------------------ keys

local function keyHelp(store, k)
    return T(_("%1 (%2)\n\nAdd this public key to ~/.ssh/authorized_keys on each device:\n\n%3\n\nIt's also in %4.pub, and the web page can copy it."),
        k.name, K.typeName(k.type), k.public, store:keyFile(k.id))
end

--- A key's page (its public key and where it is): the launcher's read page
-- with Copy public key and Done, or KOReader's TextViewer.
function UI.keyPage(title, text, public)
    local read = KO.read()
    if read then
        return read{ title = title, text = text, buttons = {
            { icon = "copy", text = _("Copy public key"), keep = true, fn = function() copyText(public) end },
            { icon = "check", text = _("Done"), primary = true },
        } }
    end
    UIManager:show(TextViewer:new{ title = title, text = text, text_type = "code" })
end

--- A new Ed25519 key on this Kindle; cb(entry) after.
function UI.createKey(plugin, cb)
    ask(_("Key name"), _("Kindle"), function(name)
        if not name:match("%S") then name = _("Kindle") end
        local key, why = plugin.store.generateEd25519()
        if not key then return info(T(_("Can't create a key: %1"), why or "?")) end
        local entry, err = plugin.store:addKey(name, key)
        if not entry then return info(T(_("Can't save the key: %1"), err or "?")) end
        plugin:saved()
        UI.keyPage(_("New key"), keyHelp(plugin.store, entry), entry.public)
        if cb then cb(entry) end
    end, { ok = _("Create"), kind = "name" })
end

local IMPORT_WHY = {
    passphrase = _("This key has a passphrase. On the PC, remove it from a copy (ssh-keygen -p -N \"\" -f copy) and import the copy."),
    pem = _("This key is in the older PEM format. On the PC, convert a copy (ssh-keygen -p -N \"\" -f copy) and import the copy."),
    public = _("This is a public key (.pub). Import the private key: the file of the same name without .pub."),
    unsupported = _("This kind of key isn't supported. Use an Ed25519, RSA or ECDSA key."),
}

--- Saves a key file's text under a name; returns the entry or nil, why.
function UI.importText(plugin, text, name)
    local key, why = K.import(text)
    if not key then return nil, IMPORT_WHY[why] or _("This isn't a private key file.") end
    if not name or not name:match("%S") then name = key.comment ~= "" and key.comment or _("Imported key") end
    local entry, err = plugin.store:addKey(name, key)
    if not entry then return nil, err end
    plugin:saved()
    return entry
end

--- Import a key file from the Kindle's storage; cb(entry) after.
function UI.importKey(plugin, cb)
    local home = G_reader_settings:readSetting("home_dir") or require("device").home_dir or "/"
    local chooser = PathChooser:new{
        title = _("Long-press the private key file to import it"),
        path = home,
        select_directory = false,
        select_file = true,
        show_hidden = true,
        file_filter = function() return true end,
        onConfirm = function(path)
            local size = lfs.attributes(path, "size") or 0
            if size > 64 * 1024 then return info(_("This isn't a private key file.")) end
            local text = plugin.store.readFile(path) or ""
            local key, why = K.import(text)
            if not key then return info(IMPORT_WHY[why] or _("This isn't a private key file.")) end
            local base = path:match("([^/]+)$")
            ask(_("Key name"), key.comment ~= "" and key.comment or base, function(name)
                local entry, err = UI.importText(plugin, text, name)
                if not entry then return info(err) end
                KO.confirm{
                    title = _("Key imported"),
                    text = T(_("Delete %1 from the Kindle's storage? The key is kept in KOReader's settings folder."), base),
                    ok = _("Delete"),
                    cancel = _("Keep"),
                    onOk = function() os.remove(path) end,
                }
                if cb then cb(entry) end
            end, { kind = "name" })
        end,
    }
    UIManager:show(chooser)
end

function UI.keys(plugin)
    local store = plugin.store
    local m
    local items
    local function rename(k)
        ask(_("Key name"), k.name, function(name)
            M.act(store.data, "renameKey", { id = k.id, name = name })
            plugin:saved()
            refresh(m, items())
        end, { kind = "name" })
    end
    local function delete(k, after)
        local users = M.hostsUsingKey(store.data, k.id)
        local what = #users > 0 and T(_("%1 (used by %2)"), k.name, table.concat(users, ", ")) or k.name
        deleteWithUndo(plugin, what, function()
            if after then after() end
            -- (the key's files kept in memory, to put back on Undo)
            local file = store:keyFile(k.id)
            local priv, pub = store.readFile(file), store.readFile(file .. ".pub")
            local __, i = M.key(store.data, k.id)
            store:deleteKey(k.id)
            return function()
                if priv then store.writeFile(file, priv, true) end
                if pub then store.writeFile(file .. ".pub", pub) end
                table.insert(store.data.keys, math.min(i or 1, #store.data.keys + 1), k)
            end
        end, function() refresh(m, items()) end)
    end
    local function show(k)
        local read = KO.read()
        if read then
            return read{ title = k.name, text = keyHelp(store, k), buttons = {
                { icon = "copy", text = _("Copy public key"), keep = true, fn = function() copyText(k.public) end },
                { icon = "pencil", text = _("Rename"), fn = function() rename(k) end },
                { icon = "trash-2", text = _("Delete"), fn = function() delete(k, function() end) end },
                { icon = "check", text = _("Done"), primary = true },
            } }
        end
        local viewer
        viewer = TextViewer:new{
            title = k.name,
            text = keyHelp(store, k),
            text_type = "code",
            -- (one row; the text is short, so no Find or ⇱ ⇲, and the
            -- title bar's ✕ closes it)
            add_default_buttons = false,
            buttons_table = { {
                { text = _("Copy public key"), callback = function() copyText(k.public) end },
                { text = _("Rename"), callback = function()
                    UIManager:close(viewer)
                    rename(k)
                end },
                { text = _("Delete"), callback = function()
                    delete(k, function() UIManager:close(viewer) end)
                end },
            } },
        }
        UIManager:show(viewer)
    end
    items = function()
        local t = { { band = _("KEYS"), right = tostring(#store.data.keys) } }
        for i, k in ipairs(store.data.keys) do
            local users = M.hostsUsingKey(store.data, k.id)
            t[#t + 1] = { text = k.name, sub = #users > 0 and T(_("Used by %1"), table.concat(users, ", ")) or _("Not used by a host yet"),
                icon = "key-round", right = K.typeName(k.type), chevron = true,
                callback = function() show(k) end,
                hold_callback = function()
                    holdMenu(k.name, {
                        { { text = _("Show public key"), callback = function() show(k) end },
                            { text = _("Copy public key"), callback = function() copyText(k.public) end } },
                        { { text = _("Rename"), callback = function() rename(k) end },
                            { text = _("Delete"), callback = function() delete(k) end } },
                    })
                end }
        end
        t[#t + 1] = { text = _("Create key"), sub = _("A new Ed25519 key, made on this Kindle"), icon = "plus", callback = function()
            UI.createKey(plugin, function() refresh(m, items()) end)
        end }
        t[#t + 1] = { text = _("Import key file"), sub = _("A private key file copied to the Kindle"), icon = "download", callback = function()
            UI.importKey(plugin, function() refresh(m, items()) end)
        end }
        return t
    end
    m = list(_("Keys"), items)
end

--- Choose a key for a host: its keys, Create key, Import key file. cb(key id).
local function chooseKey(plugin, cb, back)
    local store = plugin.store
    local items = {}
    for __, k in ipairs(store.data.keys) do
        items[#items + 1] = { text = T("%1 (%2)", k.name, K.typeName(k.type)), fn = function() cb(k.id) end }
    end
    items[#items + 1] = { text = _("Create key"), fn = function() UI.createKey(plugin, function(e) cb(e.id) end) end }
    items[#items + 1] = { text = _("Import key file"), fn = function() UI.importKey(plugin, function(e) cb(e.id) end) end }
    KO.list(_("Key"), items, back)
end

--- Sign-in: Key (then which), Password (then the password), Ask for
-- password. cb({ auth, key, password }).
local function chooseSignIn(plugin, cb)
    KO.list(_("Sign in with"), {
        { text = AUTH_NAMES.key, fn = function()
            chooseKey(plugin, function(kid) cb({ auth = "key", key = kid }) end, function() chooseSignIn(plugin, cb) end)
        end },
        { text = AUTH_NAMES.password, fn = function()
            ask(_("Password"), "", function(pw) cb({ auth = "password", password = pw }) end,
                { password = true, description = _("Saved on this Kindle, in KOReader's settings folder.") })
        end },
        { text = AUTH_NAMES.ask, fn = function() cb({ auth = "ask", password = "" }) end },
    })
end

-- ------------------------------------------------------------------ hosts

--- Saves a change to a host through the model's checks; true when saved.
local function saveHost(plugin, args)
    local r, why = M.act(plugin.store.data, "saveHost", args)
    if not r then
        info(why)
        return nil
    end
    plugin:saved()
    return r
end

function UI.addHost(plugin)
    local function proceed(h)
        chooseSignIn(plugin, function(s)
            h.auth, h.key, h.password = s.auth, s.key, s.password
            local r = saveHost(plugin, h)
            if r then
                UI.refreshMain(plugin)
                UI.host(plugin, M.host(plugin.store.data, r.id))
            end
        end)
    end
    -- The launcher's box: user@address (with :port when it isn't 22), Name.
    local request = KO.request()
    if request then
        local name = ""
        local function subtitle() return T(_("Name: %1"), name ~= "" and name or _("the address")) end
        return request{ title = _("Add host"), subtitle = subtitle(), hint = "pi@192.168.1.20", typing = true,
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = "type", text = _("Name"), keep = true, fn = function(__, box)
                    box:stopTyping()
                    ask(_("Name"), name, function(v)
                        name = v
                        box.subtitle = subtitle()
                        box:redraw()
                    end, { kind = "name" })
                end },
                { icon = "arrow-right-left", text = _("Next"), primary = true, needsText = true, keep = true, fn = function(t, box)
                    local user, address, port = M.parseTarget(t)
                    if not user then return info(address) end
                    local h = { name = name, address = address, user = user, port = port }
                    local why = M.checkHost(h)
                    if why then return info(why) end
                    box:close()
                    proceed(h)
                end },
            } }
    end
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Add host"),
        fields = {
            { description = _("Name"), text = "", hint = _("Raspberry Pi") },
            { description = _("Address"), text = "", hint = "192.168.1.20" },
            { description = _("User"), text = "", hint = "pi" },
            { description = _("Port"), text = "22", input_type = "number" },
        },
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Next"), callback = function()
                local f = dialog:getFields()
                local h = { name = f[1], address = f[2]:match("^%s*(.-)%s*$"), user = f[3]:match("^%s*(.-)%s*$"), port = f[4] }
                local why = M.checkHost(h)
                if why then return info(why) end
                UIManager:close(dialog)
                proceed(h)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function UI.editHost(plugin, host)
    local store = plugin.store
    local m
    local items
    local function redo()
        refresh(m, items())
        UI.refreshMain(plugin)
        if UI.hostMenu then UI.refreshHost(plugin, host) end
    end
    local function field(label, key, opts)
        return { setting = true, text = label, value = short(tostring(host[key] or ""), 30), callback = function()
            ask(label, tostring(host[key] or ""), function(v)
                if saveHost(plugin, { id = host.id, [key] = v }) then redo() end
            end, opts)
        end }
    end
    items = function()
        local k = host.key and M.key(store.data, host.key)
        local Screens = require("sshscreens")
        local t = {
            { band = _("CONNECTION") },
            field(_("Name"), "name", { kind = "name" }),
            field(_("Address"), "address"),
            field(_("User"), "user"),
            field(_("Port"), "port", { number = true }),
            { setting = true, text = _("System"), value = host.os == "auto"
                and (host.detected and T(_("Auto: %1"), M.osName(host.detected)) or _("Auto (on the next connection)"))
                or M.osName(host.os), callback = function()
                local options = { { label = _("Detect automatically"), value = "auto" } }
                for __, o in ipairs(M.OSES) do options[#options + 1] = { label = o.name, value = o.id } end
                KO.choose(_("System"), options, host.os, function(id)
                    if saveHost(plugin, { id = host.id, os = id }) then redo() end
                end)
            end },
            { setting = true, text = _("Sign in with"), value = host.auth == "key" and T("%1: %2", AUTH_NAMES.key, k and k.name or "?")
                or AUTH_NAMES[host.auth], callback = function()
                chooseSignIn(plugin, function(s)
                    if saveHost(plugin, { id = host.id, auth = s.auth, key = s.key or "", password = s.password }) then redo() end
                end)
            end },
        }
        if host.auth == "password" then
            t[#t + 1] = { setting = true, text = _("Password"), value = host.password and _("Saved") or _("Not saved"), callback = function()
                ask(_("Password"), "", function(pw)
                    if saveHost(plugin, { id = host.id, password = pw }) then redo() end
                end, { password = true, description = _("Saved on this Kindle, in KOReader's settings folder.") })
            end }
        end
        t[#t + 1] = { band = _("PIN") }
        t[#t + 1] = { setting = true, text = host.pin and _("Change PIN") or _("Set a PIN"), value = host.pin and _("On") or _("Off"),
            hint = _("Asked before this host's page or a live session opens (again after 5 minutes)"), callback = function()
                ask(_("New PIN (4 to 8 digits)"), "", function(pin)
                    if not M.pinOk(pin) then return info(_("A PIN is 4 to 8 digits.")) end
                    ask(_("The same PIN again"), "", function(again)
                        if again ~= pin then return info(_("The PINs don't match.")) end
                        host.pin = M.pinHash(host, pin)
                        M.unlocked[host.id] = os.time()
                        plugin:saved()
                        redo()
                        KO.toast(_("PIN set"), 2)
                    end, { number = true, password = true, width = 230, ok = _("Set") })
                end, { number = true, password = true, width = 230, ok = _("Next") })
            end }
        if host.pin then
            t[#t + 1] = { setting = true, text = _("Remove PIN"), callback = function()
                host.pin = nil
                M.unlocked[host.id] = nil
                plugin:saved()
                redo()
                KO.toast(_("PIN removed"), 2)
            end }
        end
        t[#t + 1] = { band = _("ON THE SSH PAGE") }
        t[#t + 1] = { setting = true, text = _("Groups"), value = #(host.groups or {}) > 0 and table.concat(host.groups, ", ") or _("None"),
            hint = _("Home, Servers…: they filter the SSH page and Run on several hosts"), callback = function()
                local known = Screens.groupsOf(store.data)
                ask(_("Groups"), table.concat(host.groups or {}, ", "), function(v)
                    local g = {}
                    for name in (v .. ","):gmatch("%s*([^,]-)%s*,") do if name ~= "" then g[#g + 1] = name end end
                    host.groups = #g > 0 and g or nil
                    plugin:saved()
                    redo()
                end, { kind = "name", description = #known > 0 and T(_("Separated by commas. Groups so far: %1"), table.concat(known, ", "))
                    or _("Separated by commas, for example Home, Servers") })
            end }
        t[#t + 1] = { band = _("STATUS") }
        t[#t + 1] = { setting = true, text = _("Stats and alerts"), value = T(_("%1 shown"), #require("sshstats").shown(host)),
            callback = function() Screens.stats(plugin, host) end }
        t[#t + 1] = { setting = true, text = _("Quick commands"), value = T(_("%1 shown"), #require("sshstats").quickShown(host, false)),
            callback = function() Screens.quickPage(plugin, host) end }
        t[#t + 1] = { band = _("WAKE ON LAN") }
        local mac = host.mac or (host.last and host.last.v and host.last.v.mac)
        t[#t + 1] = { setting = true, text = _("MAC address"), value = mac or _("Read on the next connection"),
            hint = _("To wake it when it's off or asleep (Wake on LAN on in its BIOS or settings)"), callback = function()
                ask(_("MAC address"), mac or "", function(v)
                    v = v:match("^%s*(.-)%s*$")
                    if v ~= "" and not require("sshstats").magicPacket(v) then return info(_("That isn't a MAC address (like dc:a6:32:01:02:03).")) end
                    host.mac = v ~= "" and v:lower() or nil
                    plugin:saved()
                    redo()
                end)
            end }
        if mac then
            t[#t + 1] = { setting = true, text = _("Wake it now"), callback = function() Screens.wake(plugin, host) end }
        end
        t[#t + 1] = { band = _("HOST KEY AND HOST") }
        if store:isKnown(host.address) then
            t[#t + 1] = { setting = true, text = _("Forget host key"), hint = _("You'll be asked to trust it again next time"), callback = function()
                KO.confirm{
                    text = T(_("Forget the saved host key of %1? You'll be asked to trust it again next time."), host.address),
                    ok = _("Forget"),
                    onOk = function()
                        store:forget(host.address)
                        redo()
                    end,
                }
            end }
        end
        t[#t + 1] = { setting = true, text = _("Delete host"), callback = function()
            deleteWithUndo(plugin, M.hostName(host), function()
                UIManager:close(m)
                if UI.hostMenu then
                    UIManager:close(UI.hostMenu)
                    UI.hostMenu = nil
                end
                return takeOut(store.data.hosts, host)
            end, function() UI.refreshMain(plugin) end)
        end }
        return t
    end
    m = list(_("Edit host"), items(), M.hostName(host))
end

local function hostItems(plugin, host)
    return require("sshscreens").hostItems(plugin, host)
end

function UI.refreshHost(plugin, host)
    if UI.hostMenu then refresh(UI.hostMenu, hostItems(plugin, host), M.hostName(host)) end
end

--- done() once the host's PIN is typed (at once when it has none, or was
-- opened with it in the last 5 minutes). Five wrong tries: a minute's wait.
UI.pinFails = {}
function UI.withPin(host, done)
    if not M.needsPin(host) then return done() end
    local f = UI.pinFails[host.id]
    if f and f.n >= 5 and os.time() - f.at < 60 then
        return info(T(_("Too many wrong PINs. Try again in %1 s."), 60 - (os.time() - f.at)))
    end
    ask(T(_("PIN for %1"), M.hostName(host)), "", function(pin)
        if M.unlock(host, pin) then
            UI.pinFails[host.id] = nil
            return done()
        end
        f = UI.pinFails[host.id] or { n = 0 }
        f.n, f.at = f.n + 1, os.time()
        UI.pinFails[host.id] = f
        KO.toast(_("Wrong PIN"), 2)
    end, { number = true, password = true, width = 230, ok = _("Open") })
end

function UI.host(plugin, host)
    if not host then return end
    if M.needsPin(host) then return UI.withPin(host, function() UI.host(plugin, host) end) end
    if UI.hostMenu then UIManager:close(UI.hostMenu) end
    UI.plugin = plugin
    local Screens = require("sshscreens")
    local m = List:new{ title = M.hostName(host), item_table = hostItems(plugin, host),
        items_fn = function() return hostItems(plugin, host) end,
        bar_buttons = Screens.hostButtons(plugin, host),
        close_callback = function() UI.hostMenu = nil end }
    -- ⟳: its status read again (asking what it needs: a password, trust)
    m.on_refresh = function() Screens.readStatus(plugin, host, true) end
    UI.hostMenu = m
    UIManager:show(m)
    Screens.opened(plugin, host)
end

--- A live session; cmd (optional): typed in once it's open. An open session
-- to the same host is used again (brought to the front) instead.
function UI.session(plugin, host, cmd)
    if M.needsPin(host) then return UI.withPin(host, function() UI.session(plugin, host, cmd) end) end
    local S = require("sshsession")
    local cur = S.current
    if cmd and cur and cur.open and cur.host == host then
        cur:toFront()
        return cur:typeLine(cmd)
    end
    Run.prepare(plugin, host, function(password)
        S.open(plugin, host, password, cmd)
    end)
end

--- Run on several hosts: tick the hosts, then the command.
function UI.several(plugin)
    local data = plugin.store.data
    if #data.hosts == 0 then return info(_("Add a host first.")) end
    local picked = {}
    local m
    local function items()
        local t = {}
        -- a group ticks all its hosts at once
        local groups = require("sshscreens").groupsOf(data)
        if #groups > 0 then
            local chips = {}
            for __, g in ipairs(groups) do
                local all = true
                for __, h in ipairs(data.hosts) do
                    for __, x in ipairs(h.groups or {}) do if x == g and not picked[h.id] then all = false end end
                end
                chips[#chips + 1] = { text = g, on = all, fn = function()
                    for __, h in ipairs(data.hosts) do
                        -- (one with a PIN that wasn't typed: left out; tick it to type it)
                        for __, x in ipairs(h.groups or {}) do if x == g then picked[h.id] = (not all and not M.needsPin(h)) or nil end end
                    end
                    refresh(m, items())
                end }
            end
            t[#t + 1] = { chips = chips }
        end
        local n = 0
        for __, h in ipairs(data.hosts) do if picked[h.id] then n = n + 1 end end
        t[#t + 1] = { band = _("HOSTS"), right = T(_("%1 ticked"), n) }
        for __, h in ipairs(data.hosts) do
            t[#t + 1] = { toggle = picked[h.id] == true, text = M.hostName(h), sub = M.hostLabel(h), icon = "square-terminal",
                callback = function()
                    if picked[h.id] then
                        picked[h.id] = nil
                        return refresh(m, items())
                    end
                    UI.withPin(h, function()
                        picked[h.id] = true
                        refresh(m, items())
                    end)
                end }
        end
        t[#t + 1] = { tiles = { { icon = "terminal", text = _("Run a command"), sub = T(_("On the %1 ticked"), n), primary = true, fn = function()
            local hosts = {}
            for __, h in ipairs(data.hosts) do
                if picked[h.id] and not M.needsPin(h) then hosts[#hosts + 1] = h end
            end
            if #hosts == 0 then return info(_("Tick the hosts to run on.")) end
            UI.runDialog(plugin, nil, "", function(cmd) Run.many(plugin, hosts, cmd) end)
        end } }, cols = 2 }
        return t
    end
    m = list(_("Run on several hosts"), items(), _("Tick the hosts, then Run a command."))
end

-- ------------------------------------------------------------------ main

local function mainItems(plugin)
    return require("sshscreens").mainItems(plugin)
end

function UI.refreshMain(plugin)
    if UI.mainMenu then refresh(UI.mainMenu, mainItems(plugin)) end
end

function UI.show(plugin)
    if UI.mainMenu then UI.mainMenu:onCloseAllMenus() end
    UI.plugin = plugin
    local PS = require("pluginshare")
    if PS.noteRecent then pcall(PS.noteRecent, "ssh") end
    local Screens = require("sshscreens")
    local m = List:new{ title = _("SSH"), item_table = mainItems(plugin), top = true,
        items_fn = function() return mainItems(plugin) end,
        bar_buttons = Screens.mainButtons(plugin),
        status = function() return Screens.mainStatus(plugin) end,
        close_callback = function() UI.mainMenu = nil end }
    m.on_refresh = function() Screens.pingAll(plugin) end
    UI.mainMenu = m
    UIManager:show(m)
    Screens.pingAll(plugin)
    return m
end

-- (for the screens in sshscreens)
UI.h = { info = info, short = short, list = list, refresh = refresh, ask = ask, editCommand = editCommand,
    holdMenu = holdMenu, copyText = copyText, deleteWithUndo = deleteWithUndo, takeOut = takeOut,
    commandActions = commandActions, saveHost = saveHost, chooseSignIn = chooseSignIn, AUTH_NAMES = AUTH_NAMES }

return UI
