--[[--
Updating plugins from the web page: a zip with one or more plugin folders
(name.koplugin, at its top or inside one folder, as a zip of the
kindle-install folder has them) is checked, then installed in place of the
plugins of the same name, and KOReader restarts.

Checked first: each folder has _meta.lua and main.lua, and every Lua file in
it compiles; a zip that fails puts nothing in place. The folder replaced is
kept (plugins/.backup/name.koplugin) so it can be put back, here or from
KOReader's menu (Web server > Undo a plugin update; Apps has the same), the
web page itself too. Files the user keeps in a plugin's folder (To Do's
client_id.txt, Notes' notes_defaults.lua) carry over.
]]

local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local Web = {}

-- Files in a plugin's folder that are the user's, not the plugin's.
local KEEP = { "client_id.txt", "notes_defaults.lua" }
-- Files that are programs (run, not read): their run bit put back.
local RUNNABLE = { ["syncthing.koplugin/syncthing"] = true }
local MAX_ZIP = 60 * 1024 * 1024

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function copyFile(from, to)
    local f = io.open(from, "rb")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    return writeFile(to, data)
end

local function purge(dir)
    if lfs.attributes(dir, "mode") == "directory" then require("ffi/util").purgeDir(dir) end
end

--- Where the plugins are (the folder this one is in).
function Web.dir(plugin)
    return (plugin.path or ""):match("^(.*)/[^/]+$") or "plugins"
end

--- The plugins in a zip: { name = { prefix, files = { rel = entry path } } }, or nil, why.
function Web.scan(r)
    local found = {}
    for entry in r:iterate() do
        local p = entry.path or ""
        if entry.mode == "file" and not p:find("%.%.") and not p:find("^/") and not p:find("\\", 1, true) then
            -- The folder name.koplugin (at the top, or one level in).
            local prefix, name, rel = p:match("^(([^/]*%.koplugin)/)(.+)$")
            if not prefix then prefix, name, rel = p:match("^([^/]+/([^/]*%.koplugin)/)(.+)$") end
            if name and name:match("^[%w_%-%.]+%.koplugin$") and not rel:match("^%.git/") then
                found[name] = found[name] or { files = {} }
                found[name].files[rel] = p
            end
        end
    end
    if not next(found) then return nil, "That zip has no plugin folders (name.koplugin) in it." end
    return found
end

--- Reads and checks every plugin's files: { name = { rel = data } }, or nil, why.
function Web.check(r, found)
    local out = {}
    for name, plug in pairs(found) do
        if not (plug.files["_meta.lua"] and plug.files["main.lua"]) then
            return nil, name .. " has no _meta.lua and main.lua: not a KOReader plugin."
        end
        out[name] = {}
        for rel, path in pairs(plug.files) do
            local data = r:extractToMemory(path)
            if not data then return nil, "Couldn't read " .. path .. " from the zip." end
            if rel:match("%.lua$") then
                local ok, err = (loadstring or load)(data, "=" .. name .. "/" .. rel)
                if not ok then return nil, name .. "/" .. rel .. " has an error: " .. tostring(err) end
            end
            out[name][rel] = data
        end
    end
    return out
end

--- Puts checked plugins in place, the replaced ones kept. Returns the names.
function Web.install(dir, plugins)
    local util = require("util")
    local backups, staging = dir .. "/.backup", dir .. "/.install"
    util.makePath(backups)
    local names = {}
    for name, files in pairs(plugins) do
        local dest, stage, backup = dir .. "/" .. name, staging .. "/" .. name, backups .. "/" .. name
        purge(stage)
        for rel, data in pairs(files) do
            local folder = (stage .. "/" .. rel):match("^(.*)/[^/]+$")
            util.makePath(folder)
            if not writeFile(stage .. "/" .. rel, data) then error("Couldn't write " .. name .. "/" .. rel) end
            if RUNNABLE[name .. "/" .. rel] then os.execute("chmod 755 '" .. stage .. "/" .. rel .. "'") end
        end
        if lfs.attributes(dest, "mode") == "directory" then
            -- The user's own files carry over.
            for __, keep in ipairs(KEEP) do
                if lfs.attributes(dest .. "/" .. keep, "mode") == "file" and not files[keep] then
                    copyFile(dest .. "/" .. keep, stage .. "/" .. keep)
                end
            end
            purge(backup)
            local ok, err = os.rename(dest, backup)
            if not ok then error("Couldn't set " .. name .. " aside: " .. tostring(err)) end
            local tf = io.open(backup .. "/.replaced", "w")
            if tf then tf:write(os.date("%Y-%m-%d %H:%M")) tf:close() end
        end
        local ok, err = os.rename(stage, dest)
        if not ok then
            -- Put the old one back.
            if lfs.attributes(backup, "mode") == "directory" then os.rename(backup, dest) end
            error("Couldn't put " .. name .. " in place: " .. tostring(err))
        end
        table.insert(names, name)
    end
    purge(staging)
    table.sort(names)
    return names
end

--- The plugins with a version kept from before an update: { { name, when } }.
function Web.backups(dir)
    local out = {}
    local backups = dir .. "/.backup"
    if lfs.attributes(backups, "mode") ~= "directory" then return out end
    for name in lfs.dir(backups) do
        if name:match("%.koplugin$") and lfs.attributes(backups .. "/" .. name, "mode") == "directory" then
            local f = io.open(backups .. "/" .. name .. "/.replaced", "r")
            local when = f and f:read("*l") or ""
            if f then f:close() end
            table.insert(out, { name = name, when = when })
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- Puts a plugin's earlier version back (the newer one is removed).
function Web.rollback(dir, name)
    if not (type(name) == "string" and name:match("^[%w_%-%.]+%.koplugin$")) then return nil, "No such plugin" end
    local backup, dest, gone = dir .. "/.backup/" .. name, dir .. "/" .. name, dir .. "/.install/" .. name
    if lfs.attributes(backup, "mode") ~= "directory" then return nil, "No earlier version of " .. name end
    require("util").makePath(dir .. "/.install")
    purge(gone)
    if lfs.attributes(dest, "mode") == "directory" then
        local ok, err = os.rename(dest, gone)
        if not ok then return nil, tostring(err) end
    end
    local ok, err = os.rename(backup, dest)
    if not ok then
        os.rename(gone, dest)
        return nil, tostring(err)
    end
    os.remove(dest .. "/.replaced")
    purge(gone)
    return true
end

--- KOReader starts again (the web page stopped first: its firewall opening closes).
function Web.restart(plugin)
    local Device = require("device")
    local can = Device.canRestart == nil or Device:canRestart()
    UIManager:scheduleIn(2, function()
        if plugin and plugin.stop then plugin:stop() end
        if can and UIManager.restartKOReader then
            UIManager:restartKOReader()
        else
            require("webcommon").message("Plugins updated. Restart KOReader to use them.")
        end
    end)
    return can
end

function Web.routes(server, plugin)
    local dir = Web.dir(plugin)

    server:route("GET", "^/api/plugins$", function(req, res)
        local installed = {}
        for name in lfs.dir(dir) do
            if name:match("%.koplugin$") and lfs.attributes(dir .. "/" .. name, "mode") == "directory" then table.insert(installed, name) end
        end
        table.sort(installed)
        res:json({ installed = installed, backups = Web.backups(dir) })
    end)

    -- A zip of plugin folders as the body: checked, installed, then KOReader restarts.
    server:route("PUT", "^/api/plugins/install$", function(req, res)
        if req.length > MAX_ZIP then return res:error(413, "That zip is too big") end
        local cache = require("datastorage"):getDataDir() .. "/cache"
        require("util").makePath(cache)
        local path = cache .. "/plugin-update.zip"
        local f = io.open(path, "wb")
        if not f then return res:error(500, "Can't write the upload") end
        local got = 0
        while true do
            local chunk = req:read(64 * 1024)
            if not chunk then break end
            f:write(chunk)
            got = got + #chunk
        end
        f:close()
        if got ~= req.length then
            os.remove(path)
            return res:error(400, "The upload was interrupted")
        end
        local Archiver = require("ffi/archiver")
        local r = Archiver.Reader:new()
        if not r:open(path) then
            os.remove(path)
            return res:error(400, "That isn't a zip file.")
        end
        local found, why = Web.scan(r)
        local plugins
        if found then plugins, why = Web.check(r, found) end
        r:close()
        os.remove(path)
        if not plugins then return res:error(400, why) end
        local ok, names = pcall(Web.install, dir, plugins)
        if not ok then return res:error(500, tostring(names)) end
        res:json({ ok = true, installed = names, restart = Web.restart(plugin) })
    end, true)

    server:route("POST", "^/api/plugins/rollback$", function(req, res)
        local ok, err = Web.rollback(dir, req.json().name)
        if not ok then return res:error(400, err) end
        res:json({ ok = true, restart = Web.restart(plugin) })
    end)
end

--- KOReader's menu: put back a plugin's version from before an update
-- (works when the web page itself is the one that broke).
function Web.undoMenu(plugin)
    local dir = Web.dir(plugin)
    local list = Web.backups(dir)
    local InfoMessage = require("ui/widget/infomessage")
    if #list == 0 then
        return require("webcommon").toast("No plugin has an earlier version to go back to.", 3)
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for __, b in ipairs(list) do
        table.insert(buttons, { { text = b.name:gsub("%.koplugin$", "") .. (b.when ~= "" and ("  (before " .. b.when .. ")") or ""), callback = function()
            UIManager:close(dialog)
            require("webcommon").confirm{
                text = "Go back to the earlier version of " .. b.name:gsub("%.koplugin$", "") .. "? KOReader restarts.",
                ok = "Go back",
                onOk = function()
                    local ok, err = Web.rollback(dir, b.name)
                    if not ok then return require("webcommon").message(tostring(err)) end
                    Web.restart(plugin)
                end,
            }
        end } })
    end
    table.insert(buttons, { { text = "Close", callback = function() UIManager:close(dialog) end } })
    dialog = require("webcommon").buttonDialog{ title = "Undo a plugin update", title_align = "center", buttons = buttons }
end

return Web
