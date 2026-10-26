--[[--
Updates from GitHub: the latest release of the repo (Mcp20091/kindle-koreader-apps, or
another owner/repo set in Launcher settings, for a fork) against the one installed
(apps.koplugin/release.txt, written into the release zip), its notes, and Update: the
release's kindle-plugins.zip downloaded, every plugin in it checked (main.lua and
_meta.lua, every Lua file compiles), then put in place of the installed ones, which are
kept (plugins/.backup, for Undo a plugin update), and KOReader restarted. A plugin that
fails the check puts nothing in place. The user's own files in a plugin's folder (To
Do's client_id.txt, Notes' notes_defaults.lua) carry over; the Syncthing program keeps
its run bit.

With Check automatically on (it is to start with), once a day while the Kindle is
already on Wi-Fi: a notification when there's a newer release.
]]

local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local KO = require("appsko")

local U = {}

U.DEFAULT_REPO = "Mcp20091/kindle-koreader-apps"
local ASSET = "kindle-plugins.zip"
-- Files in a plugin's folder that are the user's, not the plugin's.
local KEEP = { "client_id.txt", "notes_defaults.lua" }
-- Files that are programs (run, not read).
local RUNNABLE = { ["syncthing.koplugin/syncthing"] = true }
local DAY = 24 * 3600

local function settings() return G_reader_settings:readSetting("apps") or {} end

--- The repo updates come from: "owner/name".
function U.repo()
    local r = settings().update_repo
    return (type(r) == "string" and r:match("^[%w%-%._]+/[%w%-%._]+$")) and r or U.DEFAULT_REPO
end

function U.setRepo(r)
    local s = settings()
    r = tostring(r or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^https?://github%.com/", ""):gsub("/+$", "")
    s.update_repo = (r ~= "" and r ~= U.DEFAULT_REPO) and r or nil
    G_reader_settings:saveSetting("apps", s)
    return r == "" or r:match("^[%w%-%._]+/[%w%-%._]+$") ~= nil
end

function U.auto() return settings().update_auto ~= false end
function U.setAuto(on)
    local s = settings()
    if on then s.update_auto = nil else s.update_auto = false end
    G_reader_settings:saveSetting("apps", s)
end

--- Where the plugins are (the folder the launcher is in).
function U.dir(plugin)
    return ((plugin and plugin.path) or ""):match("^(.*)/[^/]+$") or "plugins"
end

--- The release installed ("v1.0.11"), or nil when it isn't known (installed before the
-- release zips said, or copied by hand).
function U.installed(plugin)
    local f = io.open(U.dir(plugin) .. "/apps.koplugin/release.txt", "r")
    if not f then return nil end
    local tag = f:read("*l")
    f:close()
    return tag and tag:match("^%s*(v[%w%.%-]+)%s*$")
end

--- Whether tag a is newer than tag b ("v1.0.12" > "v1.0.9"); b unknown: yes.
function U.newer(a, b)
    if not b then return true end
    local function parts(t)
        local out = {}
        for n in tostring(t):gmatch("%d+") do out[#out + 1] = tonumber(n) end
        return out
    end
    local x, y = parts(a), parts(b)
    for i = 1, math.max(#x, #y) do
        if (x[i] or 0) ~= (y[i] or 0) then return (x[i] or 0) > (y[i] or 0) end
    end
    return false
end

-- ------------------------------------------------------------------ downloads

local function decode(text)
    local ok, rj = pcall(require, "rapidjson")
    if ok and rj then return rj.decode(text) end
    return require("json").decode(text)
end

--- Fetches url into path in a child process (redirects followed, as GitHub's are), so
-- KOReader keeps answering; `isOk(path)` checks what came, done(ok, why) after.
local function fetch(url, path, isOk, done)
    local ffiutil = require("ffi/util")
    local part = path .. ".part"
    local pid, fd = ffiutil.runInSubProcess(function(__, write_fd)
        local ok, err = pcall(function()
            local socketutil = require("socketutil")
            local https = require("ssl.https")
            local ltn12 = require("ltn12")
            for __ = 1, 5 do
                local f = assert(io.open(part, "wb"))
                socketutil:set_timeout(20, 600)
                local okR, __, code, headers = pcall(https.request, { url = url, method = "GET", redirect = false,
                    sink = ltn12.sink.file(f), headers = { ["User-Agent"] = "KOReader", ["Accept"] = "*/*" } })
                socketutil:reset_timeout()
                if not okR then error(tostring(code)) end
                if (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) and headers and headers.location then
                    url = headers.location
                elseif code == 200 then
                    os.remove(path)
                    assert(os.rename(part, path))
                    return
                elseif code == 404 then
                    error("not found")
                else
                    error("GitHub answered " .. tostring(code))
                end
            end
            error("Too many redirects")
        end)
        if not ok then os.remove(part) end
        ffiutil.writeToFD(write_fd, ok and "K" or ("E" .. tostring(err)), true)
    end, true)
    if not pid then return done(false, tostring(fd)) end
    local deadline = os.time() + 15 * 60
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(1, check) end
            ffiutil.terminateSubProcess(pid)
            return done(false, _("It took too long. Try again when Wi-Fi is better."))
        end
        local out = (size and size > 0) and ffiutil.readAllFromFD(fd) or "EIt stopped"
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
        end
        if out:sub(1, 1) ~= "K" then return done(false, (out:sub(2):gsub("^.-:%d+: ", ""))) end
        if isOk and not isOk(path) then return done(false, _("What came back isn't what was expected.")) end
        done(true)
    end
    UIManager:scheduleIn(1, check)
end

local function cacheDir()
    local d = DataStorage:getDataDir() .. "/cache/apps-update"
    require("util").makePath(d)
    return d
end

--- The latest release of the repo: done({ tag, notes, url, zip }) or done(nil, why).
function U.latest(done)
    if NetworkMgr:isConnected() == false then return done(nil, _("The Kindle isn't on Wi-Fi.")) end
    local path = cacheDir() .. "/latest.json"
    fetch("https://api.github.com/repos/" .. U.repo() .. "/releases/latest", path, nil, function(ok, why)
        if not ok then
            if why == "not found" then why = T(_("%1 has no releases (or isn't there)."), U.repo()) end
            return done(nil, why)
        end
        local f = io.open(path, "r")
        local text = f and f:read("*a")
        if f then f:close() end
        local okJ, r = pcall(decode, text or "")
        if not (okJ and type(r) == "table" and r.tag_name) then return done(nil, _("GitHub's answer couldn't be read.")) end
        local zip
        for __, a in ipairs(r.assets or {}) do
            if a.name == ASSET then zip = a.browser_download_url end
        end
        if not zip then return done(nil, T(_("The latest release (%1) has no %2."), r.tag_name, ASSET)) end
        done({ tag = r.tag_name, notes = r.body or "", url = r.html_url, zip = zip })
    end)
end

-- ------------------------------------------------------------------ installing

--- The plugins in a zip: { name = { files = { rel = entry path } } }, or nil, why.
local function scan(r)
    local found = {}
    for entry in r:iterate() do
        local p = entry.path or ""
        if entry.mode == "file" and not p:find("%.%.") and not p:find("^/") and not p:find("\\", 1, true) then
            local prefix, name, rel = p:match("^(([^/]*%.koplugin)/)(.+)$")
            if not prefix then prefix, name, rel = p:match("^([^/]+/([^/]*%.koplugin)/)(.+)$") end
            if name and name:match("^[%w_%-%.]+%.koplugin$") and not rel:match("^%.git/") then
                found[name] = found[name] or { files = {} }
                found[name].files[rel] = p
            end
        end
    end
    if not next(found) then return nil, _("The release's zip has no plugin folders in it.") end
    return found
end

--- Every plugin's files read and checked: { name = { rel = data } }, or nil, why.
local function check(r, found)
    local out = {}
    for name, plug in pairs(found) do
        if not (plug.files["_meta.lua"] and plug.files["main.lua"]) then
            return nil, T(_("%1 has no _meta.lua and main.lua."), name)
        end
        out[name] = {}
        for rel, path in pairs(plug.files) do
            local data = r:extractToMemory(path)
            if not data then return nil, T(_("Couldn't read %1 from the zip."), path) end
            if rel:match("%.lua$") then
                local ok, err = (loadstring or load)(data, "=" .. name .. "/" .. rel)
                if not ok then return nil, T(_("%1 has an error: %2"), name .. "/" .. rel, tostring(err)) end
            end
            out[name][rel] = data
        end
    end
    return out
end

local function purge(dir)
    if lfs.attributes(dir, "mode") == "directory" then require("ffi/util").purgeDir(dir) end
end

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

--- Puts checked plugins in place, the replaced ones kept (plugins/.backup). Returns the names.
local function install(dir, plugins)
    local util = require("util")
    local backups, staging = dir .. "/.backup", dir .. "/.install"
    util.makePath(backups)
    local names = {}
    for name, files in pairs(plugins) do
        local dest, stage, backup = dir .. "/" .. name, staging .. "/" .. name, backups .. "/" .. name
        purge(stage)
        for rel, data in pairs(files) do
            util.makePath((stage .. "/" .. rel):match("^(.*)/[^/]+$"))
            if not writeFile(stage .. "/" .. rel, data) then error("Couldn't write " .. name .. "/" .. rel) end
            if RUNNABLE[name .. "/" .. rel] then os.execute("chmod 755 '" .. stage .. "/" .. rel .. "'") end
        end
        if lfs.attributes(dest, "mode") == "directory" then
            for __, keep in ipairs(KEEP) do
                if lfs.attributes(dest .. "/" .. keep, "mode") == "file" and not files[keep] then
                    local i = io.open(dest .. "/" .. keep, "rb")
                    if i then
                        writeFile(stage .. "/" .. keep, i:read("*a"))
                        i:close()
                    end
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
            if lfs.attributes(backup, "mode") == "directory" then os.rename(backup, dest) end
            error("Couldn't put " .. name .. " in place: " .. tostring(err))
        end
        table.insert(names, name)
    end
    purge(staging)
    table.sort(names)
    return names
end

--- Downloads the release's zip and installs it: done(names) or done(nil, why).
function U.install(plugin, rel, done)
    local zip = cacheDir() .. "/" .. ASSET
    fetch(rel.zip, zip, function(p)
        local f = io.open(p, "rb")
        local head = f and f:read(2)
        if f then f:close() end
        return head == "PK"
    end, function(ok, why)
        if not ok then return done(nil, why) end
        local Archiver = require("ffi/archiver")
        local r = Archiver.Reader:new()
        if not r:open(zip) then
            os.remove(zip)
            return done(nil, _("The release's file isn't a zip."))
        end
        local found, err = scan(r)
        local plugins
        if found then plugins, err = check(r, found) end
        r:close()
        os.remove(zip)
        if not plugins then return done(nil, err) end
        local okI, names = pcall(install, U.dir(plugin), plugins)
        if not okI then return done(nil, tostring(names)) end
        done(names)
    end)
end

-- ------------------------------------------------------------------ on the Kindle

local function restart(plugin)
    local Device = require("device")
    if (Device.canRestart == nil or Device:canRestart()) and UIManager.restartKOReader then
        KO.confirm{ title = _("Updated"), text = _("Restart KOReader now to use the new version?"), ok = _("Restart"),
            onOk = function()
                -- (the web server stopped first: its firewall opening closes)
                local web = plugin and plugin.ui and plugin.ui.webpage
                if web and web.stop then pcall(web.stop, web, nil, true) end
                UIManager:restartKOReader()
            end }
    else
        KO.message(_("Updated. Restart KOReader to use the new version."))
    end
end

-- Downloads and installs a release, then offers the restart.
local function run(plugin, rel)
    local wait = KO.wait and KO.wait(T(_("Downloading %1…"), rel.tag))
    U.install(plugin, rel, function(names, why)
        if wait then wait:close() end
        if not names then return KO.message(T(_("The update didn't go through, so nothing changed.\n\n%1"), tostring(why))) end
        restart(plugin)
    end)
end

--- Shows the release and offers Update.
function U.offer(plugin, rel)
    local have = U.installed(plugin)
    local notes = (rel.notes or ""):gsub("\r", "")
    if #notes > 1500 then notes = notes:sub(1, 1500) .. "…" end
    local text = T(_("%1 is out (installed: %2).\n\n%3"), rel.tag, have or _("not known"), notes)
    KO.confirm{ title = _("Update available"), text = text, ok = _("Update"), onOk = function() run(plugin, rel) end }
end

--- Check for updates (from Launcher settings): up to date, or the release with Update.
function U.check(plugin)
    local wait = KO.wait and KO.wait(T(_("Checking %1…"), U.repo()))
    U.latest(function(rel, why)
        if wait then wait:close() end
        if not rel then return KO.message(T(_("Couldn't check for updates.\n\n%1"), tostring(why))) end
        local have = U.installed(plugin)
        if not U.newer(rel.tag, have) then
            -- (installed again on asking: a plugin damaged, or a file of it deleted)
            return KO.confirm{ title = _("Up to date"), text = T(_("%1 is the latest from %2. Install it again?"), have, U.repo()),
                ok = _("Reinstall"), onOk = function() run(plugin, rel) end }
        end
        U.offer(plugin, rel)
    end)
end

--- Once a day, when on: a notification when there's a newer release (only when the
-- Kindle is already on Wi-Fi: never turns it on).
function U.daily(plugin)
    if not U.auto() then return end
    local s = settings()
    if os.time() - (s.update_checked or 0) < DAY then return end
    if not NetworkMgr:isConnected() then return end
    s.update_checked = os.time()
    G_reader_settings:saveSetting("apps", s)
    U.latest(function(rel)
        if not (rel and U.newer(rel.tag, U.installed(plugin))) then return end
        local PS = require("pluginshare")
        if PS.notify then
            pcall(PS.notify, { app = "apps", name = _("Launcher"), icon = "download", key = "apps:update",
                text = T(_("%1 is out. Tap to see what's new and update."), rel.tag),
                open = function() U.offer(plugin, rel) end })
        end
    end)
end

return U
