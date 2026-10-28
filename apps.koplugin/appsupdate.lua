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
already on Wi-Fi: a notification when there's a newer release, and a line on the
launcher's Settings tile until it's installed. After an update, its notes show once
(What's new). Select version picks one of the repo's releases (the latest or a previous
one); its test versions (pre-releases, tools/test-release.sh) only with Show test versions
on (update_tests), turned on past a warning. A Kindle installed from a branch (an option of
before) has Back to the releases; update_source says which branch, and until then the checks
look for newer commits on it. The install goes a plugin at a time, KOReader's
loop running between, with its progress for the pop-up (and the web page, webplugins.lua).
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
-- What these apps are called together: the header over the version (Settings > Updates, Set up).
U.NAME = "Clod UI"

-- The note over the optional apps (Settings > Updates; the web page's System > Updates says the same).
U.OPTIONAL_NOTE = _("Install optional apps here. Once installed, they update automatically with each new version of the primary apps.")
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

--- Whether Select version offers test versions (off to start with).
function U.tests() return settings().update_tests == true end
function U.setTests(on)
    local s = settings()
    s.update_tests = on and true or nil
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
-- KOReader keeps answering; `isOk(path)` checks what came, done(ok, why) after;
-- `onBytes(n)` each second with how much has come so far.
local function fetch(url, path, isOk, done, onBytes)
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
            if onBytes then pcall(onBytes, lfs.attributes(part, "size") or 0) end
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

--- A release's files: its kindle-plugins.zip (url, size) and the optional apps' zips
-- (kindle-<app>.zip): { { folder = "flashforge.koplugin", zip, size } }.
local function assetsOf(r)
    local zip, size, optional = nil, nil, {}
    for __, a in ipairs(r.assets or {}) do
        local app = type(a.name) == "string" and a.name:match("^kindle%-([%w_%-]+)%.zip$")
        if a.name == ASSET then zip, size = a.browser_download_url, a.size
        elseif app and app ~= "plugins" then
            optional[#optional + 1] = { folder = app .. ".koplugin", zip = a.browser_download_url, size = a.size }
        end
    end
    return zip, size, optional
end

--- The latest release of the repo: done({ tag, notes, url, zip, size, optional }) or done(nil, why).
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
        local zip, size, optional = assetsOf(r)
        if not zip then return done(nil, T(_("The latest release (%1) has no %2."), r.tag_name, ASSET)) end
        local s = settings()
        s.update_latest = r.tag_name
        G_reader_settings:saveSetting("apps", s)
        done({ tag = r.tag_name, notes = r.body or "", url = r.html_url, zip = zip, size = size, optional = optional })
    end)
end

--- A newer release seen by the last check ("v1.0.13"), until it's installed; else nil.
function U.available(plugin)
    local tag = settings().update_latest
    if tag and U.newer(tag, U.installed(plugin)) and U.installed(plugin) then return tag end
end

--- The repo's releases, newest first (at most 20): done({ { tag, notes, zip, pre } }) or done(nil, why).
function U.releases(done, repo)
    if NetworkMgr:isConnected() == false then return done(nil, _("The Kindle isn't on Wi-Fi.")) end
    local path = cacheDir() .. "/releases.json"
    fetch("https://api.github.com/repos/" .. (repo or U.repo()) .. "/releases?per_page=20", path, nil, function(ok, why)
        if not ok then return done(nil, why) end
        local f = io.open(path, "r")
        local text = f and f:read("*a")
        if f then f:close() end
        local okJ, list = pcall(decode, text or "")
        if not (okJ and type(list) == "table") then return done(nil, _("GitHub's answer couldn't be read.")) end
        local out = {}
        for __, r in ipairs(list) do
            local zip, size, optional = assetsOf(r)
            if zip and not r.draft then
                out[#out + 1] = { tag = r.tag_name, notes = r.body or "", zip = zip, size = size, pre = r.prerelease == true, optional = optional }
            end
        end
        done(out)
    end)
end

--- The repo's branches (at most 100): done({ { name, sha } }) or done(nil, why). A branch
-- installs as the repo's code at that commit (GitHub's zip of it), like a release.
function U.branches(done, repo)
    if NetworkMgr:isConnected() == false then return done(nil, _("The Kindle isn't on Wi-Fi.")) end
    repo = repo or U.repo()
    local path = cacheDir() .. "/branches.json"
    fetch("https://api.github.com/repos/" .. repo .. "/branches?per_page=100", path, nil, function(ok, why)
        if not ok then
            if why == "not found" then why = T(_("%1 isn't on GitHub (or isn't public)."), repo) end
            return done(nil, why)
        end
        local f = io.open(path, "r")
        local text = f and f:read("*a")
        if f then f:close() end
        local okJ, list = pcall(decode, text or "")
        if not (okJ and type(list) == "table") then return done(nil, _("GitHub's answer couldn't be read.")) end
        local out = {}
        for __, b in ipairs(list) do
            if type(b) == "table" and type(b.name) == "string" then
                out[#out + 1] = { name = b.name, sha = type(b.commit) == "table" and b.commit.sha or nil }
            end
        end
        done(out)
    end)
end

--- A branch as something to install: { branch, sha, tag (for the messages: "main @ 1a2b3c4"), zip }.
function U.branchRelease(b, repo)
    local short = (b.sha or ""):sub(1, 7)
    return { branch = b.name, sha = b.sha, tag = b.name .. (short ~= "" and (" @ " .. short) or ""), notes = "",
        zip = "https://api.github.com/repos/" .. (repo or U.repo()) .. "/zipball/" .. (b.sha or b.name) }
end

--- What's installed, for showing: the release ("v1.0.12"), the branch and commit ("main @ 1a2b3c4"), or nil.
function U.installedText(plugin)
    local src = settings().update_source
    if type(src) == "table" and src.branch then return src.branch .. " @ " .. tostring(src.sha or ""):sub(1, 7) end
    return U.installed(plugin)
end

-- ------------------------------------------------------------------ installing

--- The plugins in a zip: { name = { files = { rel = entry path }, optional } }, or nil, why.
-- The optional apps are the ones in an optional/ folder (a branch's zip has it).
local function scan(r)
    local found = {}
    for entry in r:iterate() do
        local p = entry.path or ""
        if entry.mode == "file" and not p:find("%.%.") and not p:find("^/") and not p:find("\\", 1, true) then
            local prefix, name, rel = p:match("^(([^/]*%.koplugin)/)(.+)$")
            if not prefix then prefix, name, rel = p:match("^([^/]+/([^/]*%.koplugin)/)(.+)$") end
            local optional = false
            if not prefix then
                prefix, name, rel = p:match("^([^/]+/optional/([^/]*%.koplugin)/)(.+)$")
                optional = prefix ~= nil
            end
            if prefix and prefix:match("^optional/") then optional = true end
            if name and name:match("^[%w_%-%.]+%.koplugin$") and not rel:match("^%.git/") then
                found[name] = found[name] or { files = {}, optional = optional }
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

local function short(name) return (name:gsub("%.koplugin$", "")) end

--- Downloads the release's (or branch's) zip and installs it: done(names) or done(nil, why).
-- progress(stage, done, total, text) as it goes: "downloading" (bytes, the size when
-- GitHub gives it), then "checking" and "installing" a plugin at a time, KOReader's loop
-- running between (the screen and the web page keep answering). Nothing is put in place
-- until every plugin has passed its check.
function U.install(plugin, rel, done, progress)
    progress = progress or function() end
    local zip = cacheDir() .. "/" .. ASSET
    local function mb(n) return string.format("%.1f", (n or 0) / 1048576) end
    progress("downloading", 0, rel.size, T(_("Downloading %1…"), rel.tag))
    fetch(rel.zip, zip, function(p)
        local f = io.open(p, "rb")
        local head = f and f:read(2)
        if f then f:close() end
        return head == "PK"
    end, function(ok, why)
        if not ok then return done(nil, why) end
        local dir = U.dir(plugin)
        local names
        local co = coroutine.create(function()
            local Archiver = require("ffi/archiver")
            local r = Archiver.Reader:new()
            if not r:open(zip) then error(_("The release's file isn't a zip."), 0) end
            local found, err = scan(r)
            if not found then
                r:close()
                error(err, 0)
            end
            -- Which of them: `only` the ones asked for (an optional app), or every plugin but
            -- the optional apps that aren't installed here.
            local only = {}
            for __, n in ipairs(rel.only or {}) do only[n] = true end
            for name, plug in pairs(found) do
                local keep
                if rel.only then keep = only[name]
                else keep = not plug.optional or lfs.attributes(dir .. "/" .. name, "mode") == "directory" end
                if not keep then found[name] = nil end
            end
            if not next(found) then
                r:close()
                error(_("The zip doesn't have what was asked for."), 0)
            end
            local list = {}
            for name in pairs(found) do table.insert(list, name) end
            table.sort(list)
            local plugins = {}
            for i, name in ipairs(list) do
                progress("checking", i - 1, #list, T(_("Checking the update: %1 (%2 of %3)"), short(name), i, #list))
                coroutine.yield()
                local one
                one, err = check(r, { [name] = found[name] })
                if not one then
                    r:close()
                    error(err, 0)
                end
                plugins[name] = one[name]
            end
            r:close()
            os.remove(zip)
            for i, name in ipairs(list) do
                progress("installing", i - 1, #list, T(_("Installing %1 (%2 of %3)"), short(name), i, #list))
                coroutine.yield()
                -- (one plugin a pass: its files written, then it's put in place)
                local one = install(dir, { [name] = plugins[name] })
                plugins[name] = nil
                names = names or {}
                names[#names + 1] = one[1]
            end
        end)
        local function resume()
            local okC, err = coroutine.resume(co)
            if okC and coroutine.status(co) ~= "dead" then return UIManager:scheduleIn(0.05, resume) end
            os.remove(zip)
            if not okC then return done(nil, tostring(err)) end
            -- Where it came from: a branch's commit, or a release (its release.txt says which).
            -- (An optional app on its own leaves that as it is.)
            if not rel.optional then
                local s = settings()
                s.update_source = rel.branch and { branch = rel.branch, sha = rel.sha } or nil
                G_reader_settings:saveSetting("apps", s)
            end
            done(names or {})
        end
        UIManager:scheduleIn(0.05, resume)
    end, function(n)
        progress("downloading", n, rel.size, rel.size and rel.size > 0
            and T(_("Downloading %1… %2%"), rel.tag, math.min(99, math.floor(n * 100 / rel.size)))
            or T(_("Downloading %1… %2 MB"), rel.tag, mb(n)))
    end)
end

local function isDir(path) return lfs.attributes(path, "mode") == "directory" end

-- An optional app's name and what it does, from its _meta.lua (fullname, description).
local function readMeta(text)
    local function field(k)
        local v = text:match(k .. '%s*=%s*_%(%[%[(.-)%]%]%)') or text:match(k .. '%s*=%s*_%("(.-)"%)')
            or text:match(k .. '%s*=%s*%[%[(.-)%]%]') or text:match(k .. '%s*=%s*"(.-)"')
        return v
    end
    return field("fullname"), field("description")
end

--- U.install, and with a release the optional apps installed here too, each from its own
-- zip on the release (a branch's zip has them already): done(names) or done(nil, why).
-- An optional app that can't be updated is left as it was (the rest is in), and a notification
-- says so: an older copy can lack what the launcher now needs (its tile, say).
function U.installAll(plugin, rel, done, progress)
    U.install(plugin, rel, function(names, why)
        if not names or rel.branch or rel.optional then return done(names, why) end
        local dir, todo = U.dir(plugin), {}
        for __, o in ipairs(rel.optional or {}) do
            if isDir(dir .. "/" .. o.folder) then todo[#todo + 1] = o end
        end
        local i = 0
        local function nextOne()
            i = i + 1
            local o = todo[i]
            if not o then return done(names) end
            U.install(plugin, { tag = short(o.folder) .. " " .. rel.tag, zip = o.zip, size = o.size, optional = true, only = { o.folder } },
                function(more, why2)
                    if more then
                        for __, n in ipairs(more) do names[#names + 1] = n end
                    else
                        require("logger").warn("Update:", o.folder, "not updated:", why2)
                        local f = io.open(dir .. "/" .. o.folder .. "/_meta.lua", "r")
                        local name = f and readMeta(f:read("*a") or "")
                        if f then f:close() end
                        name = name or short(o.folder)
                        local PS = require("pluginshare")
                        if PS.notify then
                            pcall(PS.notify, { app = "apps", name = _("Launcher"), icon = "download", key = "apps:optional:" .. o.folder,
                                text = T(_("%1 wasn't updated with the rest (%2). In Settings > Updates, Remove it, then Install it again."), name, tostring(why2)),
                                route = { settings = "updates" },
                                open = function() if PS.showSettings then PS.showSettings("updates") end end })
                        end
                    end
                    nextOne()
                end, progress)
        end
        nextOne()
    end, progress)
end

-- ------------------------------------------------------------------ optional apps

local function encode(t)
    local ok, rj = pcall(require, "rapidjson")
    if ok and rj and rj.encode then return rj.encode(t) end
    return require("json").encode(t)
end

local function savedFile() return cacheDir() .. "/optional-apps.json" end

--- The optional apps just looked up, kept on the Kindle so the next time shows them at once.
local function saveOptional(rel, list)
    local apps = {}
    for k, o in ipairs(list) do
        apps[k] = { folder = o.folder, title = o.title, description = o.description, zip = o.zip, size = o.size }
    end
    local ok, text = pcall(encode, { tag = rel.tag, sha = rel.sha, branch = rel.branch, zip = rel.zip, apps = apps })
    if not ok then return end
    local f = io.open(savedFile(), "w")
    if f then f:write(text) f:close() end
end

--- The optional apps to show at once, before they're looked up (or off Wi-Fi): the list last looked
-- up, kept on the Kindle, and the ones installed here (each says what it is: PS.appInfo, group
-- "optional"), each marked installed or not. Returns the list and the version the kept list is
-- from (nil without one: then only the installed ones, which can be removed).
function U.optionalNow(plugin)
    local dir = U.dir(plugin)
    local PS = package.loaded["pluginshare"]
    local info = type(PS) == "table" and type(PS.appInfo) == "table" and PS.appInfo or {}
    local list, seen, rel = {}, {}, nil
    local f = io.open(savedFile(), "r")
    if f then
        local text = f:read("*a")
        f:close()
        local ok, saved = pcall(decode, text or "")
        if ok and type(saved) == "table" and type(saved.apps) == "table" then
            rel = { tag = saved.tag, sha = saved.sha, branch = saved.branch, zip = saved.zip }
            for __, o in ipairs(saved.apps) do
                if type(o) == "table" and type(o.folder) == "string" then
                    list[#list + 1] = { folder = o.folder, title = o.title or short(o.folder), description = o.description,
                        zip = o.zip, size = o.size }
                    seen[o.folder] = true
                end
            end
        end
    end
    for name, e in pairs(info) do
        if type(e) == "table" and e.group == "optional" and not seen[name .. ".koplugin"] then
            list[#list + 1] = { folder = name .. ".koplugin", title = e.name or name }
        end
    end
    for __, o in ipairs(list) do
        o.installed = isDir(dir .. "/" .. o.folder)
        o.old = o.installed and info[short(o.folder)] == nil or nil
    end
    table.sort(list, function(a, b) return tostring(a.title):lower() < tostring(b.title):lower() end)
    return list, rel
end

--- The optional apps' list to pick from, each with Install, Update or Remove (Settings > Updates
-- and Set up your Kindle open it from their Optional apps row).
function U.optionalList(plugin, list, rel)
    local items = {}
    for __, o in ipairs(list or {}) do
        items[#items + 1] = { text = o.title .. "  \u{00B7}  " .. U.optionalLabel(o), fn = function() U.optionalAction(plugin, o, rel) end }
    end
    KO.list(_("Optional apps"), items)
end

--- The Optional apps row's value and the line under it: "2 of 4 installed", "Installed: NextDNS, pfSense".
function U.optionalSummary(list)
    local names = {}
    for __, o in ipairs(list or {}) do if o.installed then names[#names + 1] = o.title end end
    return T(_("%1 of %2 installed"), #names, #(list or {})),
        #names > 0 and T(_("Installed: %1"), table.concat(names, ", ")) or _("None installed yet. Tap to see what there is.")
end

--- What a release or branch offers as optional apps (optional/ in the repo, each a zip of
-- its own on a release): done({ { folder, title, description, installed, zip, size } }) or
-- done(nil, why). Looked up on GitHub, a request at a time in the child process.
function U.optionalApps(plugin, rel, done, repo)
    repo = repo or U.repo()
    local dir = U.dir(plugin)
    local ref = rel.sha or rel.tag
    local function described(list)
        local i = 0
        local function nextOne()
            i = i + 1
            local o = list[i]
            if not o then return done(list) end
            o.installed = isDir(dir .. "/" .. o.folder)
            -- (Installed, but it hasn't told the launcher what it is: a copy from before apps
            -- registered themselves, older than the launcher, so it has no tile. Update, not Remove.)
            local PS = package.loaded["pluginshare"]
            o.old = o.installed and type(PS) == "table" and type(PS.appInfo) == "table" and PS.appInfo[short(o.folder)] == nil or nil
            o.title = short(o.folder):gsub("^%l", string.upper)
            local path = cacheDir() .. "/meta.lua"
            fetch("https://raw.githubusercontent.com/" .. repo .. "/" .. ref .. "/optional/" .. o.folder .. "/_meta.lua", path, nil, function(ok)
                if ok then
                    local f = io.open(path, "r")
                    local text = f and f:read("*a") or ""
                    if f then f:close() end
                    local title, description = readMeta(text)
                    o.title, o.description = title or o.title, description
                end
                nextOne()
            end)
        end
        nextOne()
    end
    if not rel.branch then
        local list = {}
        for __, o in ipairs(rel.optional or {}) do list[#list + 1] = { folder = o.folder, zip = o.zip, size = o.size } end
        return described(list)
    end
    local path = cacheDir() .. "/optional.json"
    fetch("https://api.github.com/repos/" .. repo .. "/contents/optional?ref=" .. ref, path, nil, function(ok, why)
        if not ok then
            if why == "not found" then return done({}) end
            return done(nil, why)
        end
        local f = io.open(path, "r")
        local text = f and f:read("*a")
        if f then f:close() end
        local okJ, entries = pcall(decode, text or "")
        if not (okJ and type(entries) == "table") then return done(nil, _("GitHub's answer couldn't be read.")) end
        local list = {}
        for __, e in ipairs(entries) do
            if type(e) == "table" and e.type == "dir" and type(e.name) == "string" and e.name:match("^[%w_%-]+%.koplugin$") then
                list[#list + 1] = { folder = e.name }
            end
        end
        table.sort(list, function(a, b) return a.folder < b.folder end)
        described(list)
    end)
end

--- One optional app (from U.optionalApps) to install from `rel`: its own zip on a release,
-- or the branch's zip with only that app taken from it.
function U.optionalRelease(rel, o)
    if rel.branch then
        return { tag = T(_("%1 from %2"), o.title, rel.tag), zip = rel.zip, optional = true, only = { o.folder } }
    end
    return { tag = o.title .. " " .. rel.tag, zip = o.zip, size = o.size, optional = true, only = { o.folder } }
end

--- Takes an optional app off: its folder set aside (plugins/.backup, so Undo a plugin
-- update can bring it back). KOReader restarts after. Returns true, or nil and why.
function U.removeOptional(plugin, folder)
    if not (type(folder) == "string" and folder:match("^[%w_%-]+%.koplugin$")) then return nil, _("No such app") end
    local dir = U.dir(plugin)
    local dest, backup = dir .. "/" .. folder, dir .. "/.backup/" .. folder
    if not isDir(dest) then return nil, _("It isn't installed.") end
    require("util").makePath(dir .. "/.backup")
    purge(backup)
    local ok, err = os.rename(dest, backup)
    if not ok then return nil, tostring(err) end
    writeFile(backup .. "/.replaced", os.date("%Y-%m-%d %H:%M"))
    return true
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

-- Downloads and installs a release, then offers the restart; its notes are kept to show
-- once the new version runs (What's new).
local function run(plugin, rel)
    local wait = KO.wait and KO.wait(T(_("Downloading %1…"), rel.tag))
    local said
    U.installAll(plugin, rel, function(names, why)
        if wait then wait:close() end
        if not names then return KO.message(T(_("The update didn't go through, so nothing changed.\n\n%1"), tostring(why))) end
        local s = settings()
        if not (rel.branch or rel.optional) then s.update_whatsnew = { tag = rel.tag, notes = rel.notes or "" } end
        G_reader_settings:saveSetting("apps", s)
        restart(plugin)
    end, function(__, ___, ____, text)
        -- The pop-up says how far it is (the launcher's: its text redrawn in place).
        if wait and wait.redraw and text ~= said then
            said = text
            wait.text = text
            wait:redraw()
        end
    end)
end
U.run = run

--- After an update: its notes, once, when that version is the one running.
function U.whatsNew(plugin)
    local s = settings()
    local w = s.update_whatsnew
    if type(w) ~= "table" then return end
    if U.installed(plugin) ~= w.tag then return end
    s.update_whatsnew = nil
    G_reader_settings:saveSetting("apps", s)
    local notes = tostring(w.notes or ""):gsub("\r", "")
    if notes == "" then notes = _("No notes for this release.") end
    local P = require("pluginshare").popup
    if P and P.read then
        return P.read{ title = T(_("What's new in %1"), w.tag), text = notes }
    end
    KO.message{ title = T(_("What's new in %1"), w.tag), text = notes }
end

--- Select version: the repo's releases to pick from (the one installed and the latest
-- marked; test versions only with Show test versions on, or the one installed), then the
-- one picked installed (a previous one too: going back).
function U.pickVersion(plugin)
    local wait = KO.wait and KO.wait(T(_("Getting %1's versions…"), U.repo()))
    U.releases(function(list, why)
        if wait then wait:close() end
        if not list then return KO.message(T(_("Couldn't get the versions.\n\n%1"), tostring(why))) end
        if #list == 0 then return KO.message(T(_("%1 has no releases with %2."), U.repo(), ASSET)) end
        local src = settings().update_source
        local have = not (type(src) == "table" and src.branch) and U.installed(plugin) or nil
        local latest
        for __, r in ipairs(list) do if not r.pre then latest = latest or r.tag end end
        local items = {}
        for __, r in ipairs(list) do
          if not r.pre or U.tests() or r.tag == have then
            local marks = {}
            if r.tag == have then marks[#marks + 1] = _("installed") end
            if r.tag == latest then marks[#marks + 1] = _("latest") end
            if r.pre then marks[#marks + 1] = _("test") end
            items[#items + 1] = { text = r.tag .. (#marks > 0 and (" · " .. table.concat(marks, ", ")) or ""), checked = r.tag == have,
                fn = function()
                    local older = have and U.newer(have, r.tag)
                    local notes = (r.notes or ""):gsub("\r", "")
                    if #notes > 1200 then notes = notes:sub(1, 1200) .. "…" end
                    KO.confirm{ title = T(_("Install %1"), r.tag),
                        text = (older and T(_("This goes back from %1 to a previous version.\n\n"), have) or "") .. notes,
                        ok = _("Install"), onOk = function() run(plugin, r) end }
                end }
          end
        end
        KO.list(_("Select version"), items)
    end)
end

--- The branch updates come from (Settings > Updates' Branch): none (the releases), or the one
-- installed from.
function U.branchName()
    local src = settings().update_source
    return type(src) == "table" and src.branch or nil
end

--- Installed from a branch: the latest release installed in its place, and updates from the
-- releases again (Settings > Updates' Back to the releases).
function U.leaveBranch(plugin)
    local current = U.branchName()
    if not current then return end
    local w = KO.wait and KO.wait(T(_("Checking %1…"), U.repo()))
    U.latest(function(rel, why)
        if w then w:close() end
        if not rel then return KO.message(T(_("Couldn't get the latest release.\n\n%1"), tostring(why))) end
        KO.confirm{ title = T(_("Install %1"), rel.tag),
            text = T(_("Back to the releases: %1 is installed in place of the %2 branch, and updates come from the releases again."), rel.tag, current),
            ok = _("Install"), onOk = function() run(plugin, rel) end }
    end)
end

--- Show test versions: on only past a warning (a test version may not be finished).
function U.toggleTests(refresh)
    if U.tests() then
        U.setTests(false)
        if refresh then refresh() end
        return
    end
    KO.confirm{ title = _("Show test versions"),
        text = _("Test versions are for trying changes before they're released. They may have bugs or be unfinished, and aren't offered as updates: you pick one in Select version. Select version or Undo a plugin update takes you back to a release."),
        ok = _("Show them"), onOk = function()
            U.setTests(true)
            if refresh then refresh() end
        end }
end

--- Shows the release and offers Update.
function U.offer(plugin, rel)
    local have = U.installed(plugin)
    local notes = (rel.notes or ""):gsub("\r", "")
    if #notes > 1500 then notes = notes:sub(1, 1500) .. "…" end
    local text = T(_("%1 is out (installed: %2).\n\n%3"), rel.tag, have or _("not known"), notes)
    KO.confirm{ title = _("Update available"), text = text, ok = _("Update"), onOk = function() run(plugin, rel) end }
end

--- Installed from a branch: its newest commit, to compare: done(branchRelease, newer) or done(nil, why).
local function branchNow(done)
    local src = settings().update_source
    U.branches(function(list, why)
        if not list then return done(nil, why) end
        for __, b in ipairs(list) do
            if b.name == src.branch then return done(U.branchRelease(b), b.sha ~= src.sha) end
        end
        done(nil, T(_("%1 has no %2 branch any more."), U.repo(), src.branch))
    end)
end

local function fromBranch()
    local src = settings().update_source
    return type(src) == "table" and src.branch ~= nil
end

--- Check for updates (from Launcher settings): up to date, or the release with Update.
function U.check(plugin)
    local wait = KO.wait and KO.wait(T(_("Checking %1…"), U.repo()))
    if fromBranch() then
        -- Installed from a branch: its newer commits, not the releases.
        return branchNow(function(rel, newer)
            if wait then wait:close() end
            if not rel then return KO.message(T(_("Couldn't check for updates.\n\n%1"), tostring(newer))) end
            if not newer then
                return KO.confirm{ title = _("Up to date"), text = T(_("%1 is the newest on %2. Install it again?"), rel.tag, U.repo()),
                    ok = _("Reinstall"), onOk = function() run(plugin, rel) end }
            end
            KO.confirm{ title = _("Update available"), text = T(_("The %1 branch has newer commits (installed: %2, now: %3)."),
                rel.branch, U.installedText(plugin), rel.tag), ok = _("Update"), onOk = function() run(plugin, rel) end }
        end)
    end
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
    if fromBranch() then
        return branchNow(function(rel, newer)
            if not (rel and newer == true) then return end
            local PS = require("pluginshare")
            if PS.notify then
                pcall(PS.notify, { app = "apps", name = _("Launcher"), icon = "download", key = "apps:update",
                    text = T(_("The %1 branch has newer commits. Tap to update."), rel.branch),
                    open = function() run(plugin, rel) end })
            end
        end)
    end
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

--- What's been looked up for the Updates page and Set up's Updates step (this run): { busy,
-- rel (where updates come from now: the latest release, or the branch's newest commit), why,
-- optional (its optional apps) }. Looked up when they show and the Kindle is on Wi-Fi.
U.look = {}

--- Looks up the latest release (or the branch's newest commit) and its optional apps, once;
-- `redraw()` when done. Nothing while off Wi-Fi.
function U.lookUp(plugin, redraw)
    local look = U.look
    -- (at once: the list kept from last time and the ones installed, until the lookup is in)
    if not look.optional then
        look.optional, look.optionalRel = U.optionalNow(plugin)
        look.early = true
    end
    if look.busy or look.rel or look.why or not NetworkMgr:isConnected() then return end
    look.busy = true
    local function optional(rel)
        U.optionalApps(plugin, rel, function(list, why2)
            look.busy = nil
            if list then
                look.optional, look.optionalRel, look.early = list, rel, nil
                saveOptional(rel, list)
            else
                look.why = why2
            end
            if redraw then redraw() end
        end)
    end
    local function with(rel, why)
        look.rel, look.why = rel, why
        if not rel then
            look.busy = nil
            return redraw and redraw()
        end
        -- The optional apps from the version installed when it's a test one (its apps can be newer
        -- than the latest release's, or not in it yet), else from the latest release.
        local have = U.installed(plugin)
        if rel.branch or not have or have == rel.tag or not have:find("-", 1, true) then return optional(rel) end
        U.releases(function(list)
            for __, r in ipairs(list or {}) do
                if r.tag == have then return optional(r) end
            end
            optional(rel)
        end)
    end
    if fromBranch() then return branchNow(function(rel, newer) with(rel, not rel and newer or nil) end) end
    U.latest(with)
end

--- Looked up again next time (the repository or branch changed, or something was installed).
function U.forget() U.look = {} end

--- What one optional app's row offers: Install, Update (a copy older than the launcher) or Remove.
function U.optionalLabel(o)
    return not o.installed and _("Install") or o.old and _("Update") or _("Remove")
end

--- One optional app's Install (from where updates come from now), Update or Remove.
function U.optionalAction(plugin, o, rel)
    if (o.old or not o.installed) and not (rel and rel.tag and (o.zip or rel.branch)) then
        return KO.message(_("Connect to Wi-Fi first: the Kindle looks up where to get it."))
    end
    if o.old then
        return KO.confirm{ title = T(_("Update %1"), o.title),
            text = T(_("This copy of %1 is older than the launcher, so it has no tile. Install it again from %2? KOReader restarts after."), o.title, rel.tag),
            ok = _("Update"), onOk = function() U.forget() run(plugin, U.optionalRelease(rel, o)) end }
    end
    if not o.installed then
        return KO.confirm{ title = T(_("Install %1"), o.title), text = (o.description and (o.description .. "\n\n") or "") .. T(_("From %1. KOReader restarts after."), rel.tag),
            ok = _("Install"), onOk = function() U.forget() run(plugin, U.optionalRelease(rel, o)) end }
    end
    KO.confirm{ title = T(_("Remove %1"), o.title),
        text = _("It's taken off the Kindle; Undo a plugin update can bring it back. KOReader restarts after."), ok = _("Remove"),
        onOk = function()
            local ok, err = U.removeOptional(plugin, o.folder)
            if not ok then return KO.message(tostring(err)) end
            U.forget()
            restart(plugin)
        end }
end

--- Settings > Updates: the release installed and a check, the repository updates come from,
-- a version to install (and whether test versions are offered), the daily check and Undo, then
-- the optional apps, each with Install or Remove. `refresh()` draws the page again after a
-- change made in a box.
function U.settingsRows(plugin, refresh)
    U.lookUp(plugin, refresh)
    local branch = U.branchName()
    local rows = {
        { heading = U.NAME:upper() },
        { _("Check for updates"), U.installedText(plugin) or _("Version not known"), function() U.check(plugin) end },
        { _("Repository"), U.repo(), function()
            KO.askText{ title = _("Repository"), text = U.repo(), hint = T(_("owner/repository, such as %1"), U.DEFAULT_REPO), pen = false, ok = _("Save"),
                done = function(t)
                    if not U.setRepo(t) then return KO.message(T(_("Type it as owner/repository, as on GitHub (such as %1). Left empty, it's that one."), U.DEFAULT_REPO)) end
                    U.forget()
                    if refresh then refresh() end
                end }
        end },
        { _("Select version"), _("The latest or a previous one"), function() U.pickVersion(plugin) end },
        { _("Show test versions"), U.tests(), function() U.toggleTests(refresh) end },
        { note = _("Versions for trying changes before they're released, in Select version.") },
        { _("Check automatically"), U.auto(), function() U.setAuto(not U.auto()) end },
        { _("Undo a plugin update"), "", function() require("appsundo").undoMenu(plugin) end },
        { heading = _("OPTIONAL APPS") },
        { note = U.OPTIONAL_NOTE },
    }
    -- (Installed from a branch, as could be done before: the way back to the releases.)
    if branch then
        table.insert(rows, 3, { _("Back to the releases"), T(_("On the %1 branch"), branch), function() U.leaveBranch(plugin) end })
    end
    local look = U.look
    if look.optional and #look.optional > 0 then
        local value, line = U.optionalSummary(look.optional)
        rows[#rows + 1] = { _("Optional apps"), value, function() U.optionalList(plugin, look.optional, look.optionalRel or look.rel) end }
        rows[#rows + 1] = { note = line }
    elseif look.optional and not look.early then
        rows[#rows + 1] = { note = T(_("None in %1."), (look.optionalRel or look.rel or {}).tag or U.repo()) }
    elseif look.busy then
        rows[#rows + 1] = { note = _("Looking them up…") }
    elseif look.why then
        rows[#rows + 1] = { _("Couldn't look them up"), _("Try again"), function() U.forget() U.lookUp(plugin, refresh) if refresh then refresh() end end }
    else
        rows[#rows + 1] = { note = _("Connect to Wi-Fi to see them.") }
    end
    return rows
end

return U
