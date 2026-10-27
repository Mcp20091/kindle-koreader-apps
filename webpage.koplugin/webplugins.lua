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

--- Writes one checked plugin's files into the staging folder (plugins/.install/name).
function Web.stage(dir, name, files)
    local util = require("util")
    local stage = dir .. "/.install/" .. name
    purge(stage)
    for rel, data in pairs(files) do
        local folder = (stage .. "/" .. rel):match("^(.*)/[^/]+$")
        util.makePath(folder)
        if not writeFile(stage .. "/" .. rel, data) then error("Couldn't write " .. name .. "/" .. rel) end
        if RUNNABLE[name .. "/" .. rel] then os.execute("chmod 755 '" .. stage .. "/" .. rel .. "'") end
    end
end

--- Puts checked plugins in place, the replaced ones kept. Returns the names. With
-- `staged`, their files are in plugins/.install already (Web.stage).
function Web.install(dir, plugins, staged)
    local util = require("util")
    local backups, staging = dir .. "/.backup", dir .. "/.install"
    util.makePath(backups)
    local names = {}
    for name, files in pairs(plugins) do
        local dest, stage, backup = dir .. "/" .. name, staging .. "/" .. name, backups .. "/" .. name
        if not staged then Web.stage(dir, name, files) end
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
        if plugin and plugin.stop then plugin:stop(nil, true) end
        if can and UIManager.restartKOReader then
            -- (The web server on again after the restart, for the page waiting on it: main.lua.)
            G_reader_settings:saveSetting("webpage_start_after_restart", true)
            G_reader_settings:flush()
            UIManager:restartKOReader()
        else
            require("webcommon").message("Plugins updated. Restart KOReader to use them.")
        end
    end)
    return can
end

-- ------------------------------------------------------------------ progress

-- The install under way, as the page asks for it (GET /api/plugins/progress): { stage =
-- "receiving" | "checking" | "installing" | "restarting" | "done" | "failed", done, total,
-- text, error, installed }. On the Kindle the same text, in a pop-up that stays until it ends.
Web.job = nil
local box

local function short(name) return (name:gsub("%.koplugin$", "")) end

--- The Kindle's pop-up says `text` (shown the first time); `now` paints it at once, for
-- while a request holds KOReader's loop (the upload coming in).
local function say(text, now)
    if Web.job then Web.job.text = text end
    local P = require("pluginshare").popup
    if box and box.redraw then
        box.text = text
        box:redraw()
    else
        if box then UIManager:close(box) end
        if P and P.wait then
            box = P.wait(text)
        else
            box = require("ui/widget/infomessage"):new{ text = text, dismissable = false }
            UIManager:show(box)
        end
    end
    if now and UIManager.forceRePaint then UIManager:forceRePaint() end
end

local function closeBox()
    if box then
        if box.close then box:close() else UIManager:close(box) end
    end
    box = nil
end

--- Whether an install is under way (another one waits for it).
function Web.busy()
    local j = Web.job
    return j ~= nil and (j.stage == "receiving" or j.stage == "downloading" or j.stage == "checking" or j.stage == "installing" or j.stage == "restarting")
end

--- The zip at `path` checked and installed a plugin at a time, KOReader's loop running
-- between (the screen, and the page asking how far it is): then KOReader restarts.
-- A plugin that fails the check puts nothing in place.
function Web.installSteps(path, dir, plugin)
    local job = Web.job or {}
    Web.job = job
    job.stage, job.done, job.total = "checking", 0, 0
    local function step(stage, done, text)
        job.stage, job.done = stage, done
        say(text)
        coroutine.yield()
    end
    local co = coroutine.create(function()
        local Archiver = require("ffi/archiver")
        local r = Archiver.Reader:new()
        if not r:open(path) then error("That isn't a zip file.", 0) end
        local found, why = Web.scan(r)
        if not found then
            r:close()
            error(why, 0)
        end
        local names = {}
        for name in pairs(found) do table.insert(names, name) end
        table.sort(names)
        job.total = #names
        local plugins = {}
        for i, name in ipairs(names) do
            step("checking", i - 1, string.format("Checking the update: %s (%d of %d)", short(name), i, #names))
            local one, err = Web.check(r, { [name] = found[name] })
            if not one then
                r:close()
                error(err, 0)
            end
            plugins[name] = one[name]
        end
        r:close()
        os.remove(path)
        for i, name in ipairs(names) do
            step("installing", i - 1, string.format("Installing %s (%d of %d)", short(name), i, #names))
            Web.stage(dir, name, plugins[name])
            -- (Its files are on disk now and their memory goes; kept: which of the user's own
            -- files the zip has, so Web.install doesn't carry those over.)
            local has = {}
            for __, keep in ipairs(KEEP) do has[keep] = plugins[name][keep] and true or nil end
            plugins[name] = has
        end
        job.installed = Web.install(dir, plugins, true)
    end)
    local function resume()
        local ok, err = coroutine.resume(co)
        if ok and coroutine.status(co) ~= "dead" then return UIManager:scheduleIn(0.05, resume) end
        os.remove(path)
        if not ok then
            purge(dir .. "/.install")
            job.stage, job.error = "failed", tostring(err)
            closeBox()
            return require("webcommon").message("The update didn't go through, so nothing changed.\n\n" .. tostring(err))
        end
        job.done = job.total
        if Web.restart(plugin) then
            job.stage = "restarting"
            say(string.format("Installed %d plugins. KOReader is restarting…", #job.installed))
        else
            job.stage = "done"
            closeBox()
        end
    end
    UIManager:scheduleIn(0.05, resume)
end

function Web.routes(server, plugin)
    local dir = Web.dir(plugin)

    server:route("GET", "^/api/plugins/progress$", function(req, res)
        res:json(Web.job or { stage = "none" })
    end)

    -- Updates from GitHub, as the launcher's Settings > Updates has them (appsupdate.lua, the
    -- launcher's: without it, the page says so). The repo typed: its releases and branches
    -- looked up in a child process (POST, then the page asks GET until they're in); one
    -- picked: downloaded and installed with the same progress as a zip.
    local function updater()
        local ok, U = pcall(require, "appsupdate")
        return ok and U or nil
    end
    server:route("GET", "^/api/update$", function(req, res)
        local U = updater()
        if not U then return res:json({ launcher = false }) end
        res:json({ launcher = true, repo = U.repo(), default = U.DEFAULT_REPO, installed = U.installedText(plugin), auto = U.auto() })
    end)
    server:route("POST", "^/api/update/list$", function(req, res)
        local U = updater()
        if not U then return res:error(404, "The launcher (apps.koplugin) isn't installed") end
        local repo = tostring(req.json().repo or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^https?://github%.com/", ""):gsub("/+$", "")
        if repo == "" then repo = U.DEFAULT_REPO end
        if not repo:match("^[%w%-%._]+/[%w%-%._]+$") then return res:error(400, "Type it as owner/repo, as on GitHub.") end
        local list = { repo = repo, pending = true }
        Web.updates = list
        U.releases(function(releases, why)
            U.branches(function(branches, bwhy)
                if Web.updates ~= list then return end
                list.pending = nil
                list.releases, list.branches = releases or {}, branches or {}
                if not releases and not branches then list.error = tostring(why or bwhy) end
            end, repo)
        end, repo)
        res:json(list)
    end)
    server:route("GET", "^/api/update/list$", function(req, res)
        local list = Web.updates or { pending = false }
        res:json({ repo = list.repo, pending = list.pending or false, error = list.error,
            releases = list.releases, branches = list.branches })
    end)
    -- { tag } or { branch } from the list just looked up, as something to install, or nil and why.
    local function picked(U, b)
        local list = Web.updates
        if not (list and list.releases) then return nil, "Look the repo up first." end
        for __, r in ipairs(list.releases) do if b.tag and r.tag == b.tag then return r end end
        for __, br in ipairs(list.branches or {}) do
            if b.branch and br.name == b.branch then return U.branchRelease(br, list.repo) end
        end
        return nil, "That isn't in the list any more: look the repo up again."
    end
    -- The optional apps of the release or branch picked ({ tag } or { branch }): looked up,
    -- then the page asks GET until they're in ({ pending, apps = { folder, title, description,
    -- installed } }). The main install updates the installed ones with the rest.
    server:route("POST", "^/api/update/optional$", function(req, res)
        local U = updater()
        if not U then return res:error(404, "The launcher (apps.koplugin) isn't installed") end
        local rel, why = picked(U, req.json())
        if not rel then return res:error(400, why) end
        local state = { pending = true, tag = rel.tag }
        Web.optional = state
        U.optionalApps(plugin, rel, function(apps, why2)
            if Web.optional ~= state then return end
            state.pending, state.apps, state.error = nil, apps, apps == nil and tostring(why2) or nil
        end, Web.updates.repo)
        res:json(state)
    end)
    server:route("GET", "^/api/update/optional$", function(req, res)
        local state = Web.optional or {}
        local apps = {}
        for __, o in ipairs(state.apps or {}) do
            apps[#apps + 1] = { folder = o.folder, title = o.title, description = o.description, installed = o.installed }
        end
        res:json({ pending = state.pending or false, tag = state.tag, error = state.error, apps = apps })
    end)
    -- Takes an optional app off ({ folder }, one of those just looked up): set aside, so Undo a
    -- plugin update can bring it back; KOReader restarts.
    server:route("POST", "^/api/update/remove$", function(req, res)
        local U = updater()
        if not U then return res:error(404, "The launcher (apps.koplugin) isn't installed") end
        if Web.busy() then return res:error(409, "An update is being installed.") end
        local folder, known = req.json().folder, false
        for __, o in ipairs((Web.optional or {}).apps or {}) do if o.folder == folder then known = true end end
        if not known then return res:error(400, "Only an optional app can be removed here.") end
        local ok, err = U.removeOptional(plugin, folder)
        if not ok then return res:error(400, tostring(err)) end
        local restarts = Web.restart(plugin)
        Web.job = { stage = restarts and "restarting" or "done", text = "Removed. KOReader is restarting…" }
        if restarts then say(string.format("Removed %s. KOReader is restarting…", short(folder))) end
        res:json({ ok = true, restart = restarts })
    end)
    -- { tag } or { branch }, from the list just looked up (with { optional = folder }: only that
    -- optional app from it): installed, then KOReader restarts.
    server:route("POST", "^/api/update/install$", function(req, res)
        local U = updater()
        if not U then return res:error(404, "The launcher (apps.koplugin) isn't installed") end
        if Web.busy() then return res:error(409, "An update is already being installed.") end
        local b = req.json()
        local rel, why = picked(U, b)
        if not rel then return res:error(400, why) end
        if b.optional then
            local o
            for __, a in ipairs((Web.optional or {}).apps or {}) do if a.folder == b.optional then o = a end end
            if not o then return res:error(400, "Look its optional apps up again.") end
            rel = U.optionalRelease(rel, o)
        end
        U.setRepo(Web.updates.repo)
        local job = { stage = "downloading", done = 0, total = rel.size }
        Web.job = job
        say(string.format("Downloading %s…", rel.tag))
        U.installAll(plugin, rel, function(names, why)
            if not names then
                job.stage, job.error = "failed", tostring(why)
                closeBox()
                return require("webcommon").message("The update didn't go through, so nothing changed.\n\n" .. tostring(why))
            end
            if not (rel.branch or rel.optional) then
                local s = G_reader_settings:readSetting("apps") or {}
                s.update_whatsnew = { tag = rel.tag, notes = rel.notes or "" }
                G_reader_settings:saveSetting("apps", s)
            end
            job.installed, job.done = names, job.total
            if Web.restart(plugin) then
                job.stage = "restarting"
                say(string.format("Installed %s. KOReader is restarting…", rel.tag))
            else
                job.stage = "done"
                closeBox()
            end
        end, function(stage, done, total, text)
            job.stage, job.done, job.total = stage, done, total
            if text ~= job.text then say(text) end
        end)
        res:json({ ok = true, started = true, what = rel.tag })
    end)

    server:route("GET", "^/api/plugins$", function(req, res)
        local installed = {}
        for name in lfs.dir(dir) do
            if name:match("%.koplugin$") and lfs.attributes(dir .. "/" .. name, "mode") == "directory" then table.insert(installed, name) end
        end
        table.sort(installed)
        res:json({ installed = installed, backups = Web.backups(dir) })
    end)

    -- A zip of plugin folders as the body: received (the Kindle showing how much), then
    -- checked and installed a step at a time (Web.installSteps; the page asks
    -- /api/plugins/progress), then KOReader restarts.
    server:route("PUT", "^/api/plugins/install$", function(req, res)
        if req.length > MAX_ZIP then return res:error(413, "That zip is too big") end
        if Web.busy() then return res:error(409, "An update is already being installed.") end
        local cache = require("datastorage"):getDataDir() .. "/cache"
        require("util").makePath(cache)
        local path = cache .. "/plugin-update.zip"
        local f = io.open(path, "wb")
        if not f then return res:error(500, "Can't write the upload") end
        Web.job = { stage = "receiving", done = 0, total = req.length }
        -- (The upload holds KOReader's loop while it comes in: the pop-up is painted as it goes.)
        say("Receiving the update… 0%", true)
        local got, shown = 0, 0
        while true do
            local chunk = req:read(64 * 1024)
            if not chunk then break end
            f:write(chunk)
            got = got + #chunk
            Web.job.done = got
            local pct = req.length > 0 and math.floor(got * 100 / req.length) or 100
            if pct >= shown + 5 then
                shown = pct - pct % 5
                say(string.format("Receiving the update… %d%%", shown), true)
            end
        end
        f:close()
        if got ~= req.length then
            os.remove(path)
            Web.job = { stage = "failed", error = "The upload was interrupted" }
            closeBox()
            return res:error(400, "The upload was interrupted")
        end
        Web.installSteps(path, dir, plugin)
        res:json({ ok = true, started = true })
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
