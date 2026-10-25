--[[--
Undo a plugin update (the same as the web page's, which keeps the replaced
version in plugins/.backup): here too, so it works when the web server is the
plugin that broke.
]]

local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local Web = {}

local function purge(dir)
    if lfs.attributes(dir, "mode") == "directory" then require("ffi/util").purgeDir(dir) end
end

--- Where the plugins are (the folder this one is in).
function Web.dir(plugin)
    return (plugin.path or ""):match("^(.*)/[^/]+$") or "plugins"
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
            require("appsko").message("Plugins updated. Restart KOReader to use them.")
        end
    end)
    return can
end

--- KOReader's menu: put back a plugin's version from before an update
-- (works when the web server itself is the one that broke).
function Web.undoMenu(plugin)
    local dir = Web.dir(plugin)
    local list = Web.backups(dir)
    local InfoMessage = require("ui/widget/infomessage")
    if #list == 0 then
        return require("appsko").toast("No plugin has an earlier version to go back to.", 3)
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for __, b in ipairs(list) do
        table.insert(buttons, { { text = b.name:gsub("%.koplugin$", "") .. (b.when ~= "" and ("  (before " .. b.when .. ")") or ""), callback = function()
            UIManager:close(dialog)
            require("appsko").confirm{
                text = "Go back to the earlier version of " .. b.name:gsub("%.koplugin$", "") .. "? KOReader restarts.",
                ok = "Go back",
                onOk = function()
                    local ok, err = Web.rollback(dir, b.name)
                    if not ok then return require("appsko").message(tostring(err)) end
                    Web.restart(plugin)
                end,
            }
        end } })
    end
    table.insert(buttons, { { text = "Close", callback = function() UIManager:close(dialog) end } })
    dialog = require("appsko").buttonDialog{ title = "Undo a plugin update", title_align = "center", buttons = buttons }
end

return Web
