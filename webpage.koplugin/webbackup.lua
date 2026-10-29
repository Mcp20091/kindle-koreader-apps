--[[--
Backup on the web page: one zip of every app's settings and data, and putting
such a zip back.

What goes in comes from the apps themselves: each puts its part in KOReader's
PluginShare (a plain table, so it works whatever loads first and without the
launcher; the ones below are built in, for the apps written before this), so a
new app is in the backup without changing this file:

    PS.backupApps = PS.backupApps or {}
    PS.backupApps.wikipedia = {
        key = "wikipedia", name = "Wikipedia",
        files = { "^wikipedia.*%.lua$" },          -- in koreader/settings (Lua patterns)
        dirs = { "wikipedia" },                    -- folders in koreader/ (whole)
        reader_keys = { "^wikipedia" },            -- keys in KOReader's own settings
        secret_files = { "sshclient_keys.lua" },   -- only with Include keys and sign-ins
        secret_keys = { ["todo.lua"] = { "refresh_token" } }, -- taken out of a kept file
        secret_dirs = { "sshclient/keys" },        -- folders only with Include keys
        beforeRestore = function() ... end,        -- optional: before its files are written
    }                                              -- (Syncthing stops, its database is open)

The zip holds settings/ (koreader/settings), notes/ (Notes' notebooks, as
before), data/<folder>/ (the other apps' folders) and reader_settings.lua.
Restoring only writes what an app registered, never elsewhere.

After putting a zip back KOReader restarts, so the plugins read the files
again (they keep their settings in memory and would write the old ones back).
]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local Web = {}

-- Built in: the apps from before apps registered their own.
local BUILT_IN = {
    { key = "todo", name = "To Do", files = { "^todo.*%.lua$" },
        secret_keys = { ["todo.lua"] = { "access_token", "refresh_token", "expires_at" } } },
    { key = "notes", name = "Notes", files = { "^notes_.*%.lua$" }, reader_keys = { "^notes$", "^notes_" },
        secret_files = { "notes_secrets.lua" },
        secret_keys = { ["notes_onenote.lua"] = { "access_token", "refresh_token", "expires_at" } } },
    { key = "apps", name = "Launcher", reader_keys = { "^apps", "^sleep_screen_app$" } },
    { key = "gestures", name = "Gestures", files = { "^gestures%.lua$" } },
    -- (HTTPS's certificates, the Kindle's own and yours, with their keys: only with keys and sign-ins.)
    { key = "webpage", name = "Web server", reader_keys = { "^webpage" },
        secret_files = { "webpage-https-key.pem", "webpage-https-cert.pem", "webpage-https-own-key.pem", "webpage-https-own-cert.pem" } },
}

--- Every app's part: the built-in ones, then what apps registered (theirs win).
function Web.apps()
    local byKey, order = {}, {}
    local function add(e)
        if type(e) ~= "table" or not e.key then return end
        if not byKey[e.key] then table.insert(order, e.key) end
        byKey[e.key] = e
    end
    for __, e in ipairs(BUILT_IN) do add(e) end
    local PS = require("pluginshare")
    local keys = {}
    for k in pairs(PS.backupApps or {}) do table.insert(keys, k) end
    table.sort(keys)
    for __, k in ipairs(keys) do add(PS.backupApps[k]) end
    local out = {}
    for __, k in ipairs(order) do table.insert(out, byKey[k]) end
    return out
end

local function anyMatch(patterns, s)
    for __, p in ipairs(patterns or {}) do
        if s:match(p) then return true end
    end
    return false
end

-- Settings files kept (koreader/settings).
local function isSettingsFile(name)
    if name:match("%.old$") or name:match("%.part$") then return false end
    for __, e in ipairs(Web.apps()) do
        if anyMatch(e.files, name) then return true end
        for __, f in ipairs(e.secret_files or {}) do if f == name then return true end end
    end
    return false
end
-- Files that are only keys and sign-ins.
local function isSecretFile(name)
    for __, e in ipairs(Web.apps()) do
        for __, f in ipairs(e.secret_files or {}) do if f == name then return true end end
    end
    return false
end
-- Sign-ins inside a file that is kept anyway.
local function secretKeys(name)
    local out = {}
    for __, e in ipairs(Web.apps()) do
        for __, k in ipairs((e.secret_keys or {})[name] or {}) do table.insert(out, k) end
    end
    return #out > 0 and out or nil
end
-- The apps' part of KOReader's own settings.
local function isReaderKey(key)
    for __, e in ipairs(Web.apps()) do
        if anyMatch(e.reader_keys, key) then return true end
    end
    return false
end
-- The folders in koreader/ the apps keep (Notes' notebooks have their own place in the zip);
-- { dir, secret } each.
local function dataDirs()
    local out = {}
    for __, e in ipairs(Web.apps()) do
        for __, d in ipairs(e.dirs or {}) do if d ~= "notes" then table.insert(out, { dir = d }) end end
        for __, d in ipairs(e.secret_dirs or {}) do table.insert(out, { dir = d, secret = true }) end
    end
    return out
end
local function safeDir(d)
    return type(d) == "string" and d ~= "" and not d:find("%.%.") and not d:find("^/")
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

-- A Lua settings file's table, without running anything in it but data.
local function loadTable(text)
    local fn = (loadstring or load)(text)
    if not fn then return nil end
    if setfenv then setfenv(fn, {}) end
    local ok, t = pcall(fn)
    return ok and type(t) == "table" and t or nil
end

local function dumpTable(t)
    return "-- restored from a backup\nreturn " .. require("dump")(t, nil, true) .. "\n"
end

--- Every file under `dir` (relative paths), skipping the cache.
local function walk(dir, rel, out)
    out = out or {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local full = dir .. "/" .. name
            local path = rel and (rel .. "/" .. name) or name
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then walk(full, path, out)
            elseif mode == "file" then table.insert(out, path) end
        end
    end
    return out
end

--- Writes the backup zip at `path`. Returns the number of files, or nil, why
-- (no zip is left then).
function Web.make(path, secrets)
    local Archiver = require("ffi/archiver")
    local w = Archiver.Writer:new{}
    if not w:open(path, "zip") then return nil, w.err or "Can't write the zip" end
    local ok, n = pcall(Web.fill, w, secrets)
    w:close()
    if not ok then
        os.remove(path)
        return nil, tostring(n)
    end
    return n
end

function Web.fill(w, secrets)
    w:setZipCompression("deflate")
    local n = 0
    local settingsDir = DataStorage:getSettingsDir()
    for name in lfs.dir(settingsDir) do
        if isSettingsFile(name) and (secrets or not isSecretFile(name)) and lfs.attributes(settingsDir .. "/" .. name, "mode") == "file" then
            local data = readFile(settingsDir .. "/" .. name)
            if data and not secrets and secretKeys(name) then
                -- Its sign-ins taken out; a file that cannot be read is left out (never sent with them).
                local t = loadTable(data)
                if t then
                    for __, k in ipairs(secretKeys(name)) do t[k] = nil end
                    data = dumpTable(t)
                else
                    data = nil
                end
            end
            if data then
                w:addFileFromMemory("settings/" .. name, data)
                n = n + 1
            end
        end
    end
    local notesDir = DataStorage:getDataDir() .. "/notes"
    if lfs.attributes(notesDir, "mode") == "directory" then
        for __, rel in ipairs(walk(notesDir)) do
            local data = readFile(notesDir .. "/" .. rel)
            if data then
                w:addFileFromMemory("notes/" .. rel, data)
                n = n + 1
            end
        end
    end
    -- The other apps' folders (a secret one only with keys and sign-ins).
    for __, d in ipairs(dataDirs()) do
        local base = DataStorage:getDataDir() .. "/" .. d.dir
        if safeDir(d.dir) and (secrets or not d.secret) and lfs.attributes(base, "mode") == "directory" then
            for __, rel in ipairs(walk(base)) do
                local data = readFile(base .. "/" .. rel)
                if data then
                    w:addFileFromMemory("data/" .. d.dir .. "/" .. rel, data)
                    n = n + 1
                end
            end
        end
    end
    local reader = {}
    for key, value in pairs(G_reader_settings.data or {}) do
        if type(key) == "string" and isReaderKey(key) then reader[key] = value end
    end
    w:addFileFromMemory("reader_settings.lua", dumpTable(reader))
    return n + 1
end

--- Puts a backup zip back. Returns the number of files, or nil, why.
function Web.restore(path)
    local Archiver = require("ffi/archiver")
    local r = Archiver.Reader:new()
    if not r:open(path) then return nil, "That isn't a zip file." end
    local entries = {}
    for entry in r:iterate() do
        if entry.mode == "file" then table.insert(entries, entry.path) end
    end
    local settingsDir = DataStorage:getSettingsDir()
    local notesDir = DataStorage:getDataDir() .. "/notes"
    -- An app whose files this zip holds gets ready first (beforeRestore: Syncthing stops).
    for __, e in ipairs(Web.apps()) do
        if type(e.beforeRestore) == "function" then
            local touched = false
            for __, p in ipairs(entries) do
                local name = p:match("^settings/([^/]+)$")
                if (name and (anyMatch(e.files, name))) or p == "reader_settings.lua" and e.reader_keys then touched = true end
                for __, d in ipairs(e.dirs or {}) do if p:sub(1, #("data/" .. d .. "/")) == "data/" .. d .. "/" then touched = true end end
                for __, d in ipairs(e.secret_dirs or {}) do if p:sub(1, #("data/" .. d .. "/")) == "data/" .. d .. "/" then touched = true end end
                if touched then break end
            end
            if touched then pcall(e.beforeRestore) end
        end
    end
    local n, seen = 0, false
    for __, p in ipairs(entries) do
        -- Only paths this backup makes, never out of their folder.
        if not p:find("%.%.") then
            local name = p:match("^settings/([^/]+)$")
            local rel = p:match("^notes/(.+)$")
            -- data/<folder>/...: only into a folder an app registered.
            local dataTo
            for __, d in ipairs(dataDirs()) do
                local inner = safeDir(d.dir) and p:sub(1, #("data/" .. d.dir .. "/")) == "data/" .. d.dir .. "/" and p:sub(#("data/" .. d.dir .. "/") + 1)
                if inner and inner ~= "" then dataTo = DataStorage:getDataDir() .. "/" .. d.dir .. "/" .. inner break end
            end
            if name and isSettingsFile(name) then
                local data = r:extractToMemory(p)
                if data and name:match("%.lua$") then
                    -- Read as data and written back: a zip cannot put code in a settings file.
                    local t = loadTable(data)
                    if t and secretKeys(name) then
                        -- A backup without sign-ins keeps the ones here.
                        local here = loadTable(readFile(settingsDir .. "/" .. name) or "")
                        for __, k in ipairs(secretKeys(name)) do
                            if t[k] == nil and here then t[k] = here[k] end
                        end
                    end
                    data = t and dumpTable(t) or nil
                end
                if data and writeFile(settingsDir .. "/" .. name, data) then n = n + 1 seen = true end
            elseif rel then
                local data = r:extractToMemory(p)
                if data then
                    local dir = (notesDir .. "/" .. rel):match("^(.*)/[^/]+$")
                    require("util").makePath(dir)
                    if writeFile(notesDir .. "/" .. rel, data) then n = n + 1 seen = true end
                end
            elseif dataTo then
                local data = r:extractToMemory(p)
                if data then
                    require("util").makePath(dataTo:match("^(.*)/[^/]+$"))
                    if writeFile(dataTo, data) then n = n + 1 seen = true end
                end
            elseif p == "reader_settings.lua" then
                local t = loadTable(r:extractToMemory(p) or "")
                if t then
                    for key in pairs(G_reader_settings.data or {}) do
                        if type(key) == "string" and isReaderKey(key) then G_reader_settings:delSetting(key) end
                    end
                end
                for key, value in pairs(t or {}) do
                    if type(key) == "string" and isReaderKey(key) then G_reader_settings:saveSetting(key, value) end
                end
                G_reader_settings:flush()
                n = n + 1
                seen = true
            end
        end
    end
    r:close()
    if not seen then return nil, "That zip isn't a backup from this page." end
    return n
end

function Web.routes(server, plugin)
    -- What a backup holds: each app's name, and whether it has sign-ins or keys.
    server:route("GET", "^/api/backup/apps$", function(req, res)
        local out = {}
        for __, e in ipairs(Web.apps()) do
            local secret = (e.secret_files and #e.secret_files > 0) or (e.secret_dirs and #e.secret_dirs > 0) or e.secret_keys ~= nil
            table.insert(out, { key = e.key, name = e.name or e.key, secrets = secret and true or false })
        end
        res:json({ apps = out })
    end)

    -- The backup, downloaded (?secrets=1 with sign-ins and keys).
    server:route("GET", "^/api/backup$", function(req, res)
        local cache = DataStorage:getDataDir() .. "/cache"
        require("util").makePath(cache)
        local path = cache .. "/kindle-backup.zip"
        os.remove(path)
        local n, why = Web.make(path, req.query.secrets == "1")
        if not n then return res:error(500, tostring(why)) end
        res:file(path, "kindle-backup-" .. os.date("%Y-%m-%d") .. ".zip")
        os.remove(path)
    end)

    -- A backup zip as the body: put back, then KOReader restarts.
    server:route("PUT", "^/api/backup/restore$", function(req, res)
        local cache = DataStorage:getDataDir() .. "/cache"
        require("util").makePath(cache)
        local path = cache .. "/kindle-restore.zip"
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
        local n, why = Web.restore(path)
        os.remove(path)
        if not n then return res:error(400, why) end
        local Device = require("device")
        local restart = Device.canRestart == nil or Device:canRestart()
        res:json({ ok = true, files = n, restart = restart })
        -- KOReader starts again, so the plugins read what was put back (the
        -- page stopped first: its firewall opening is closed).
        UIManager:scheduleIn(2, function()
            if plugin and plugin.stop then plugin:stop() end
            if restart and UIManager.restartKOReader then
                UIManager:restartKOReader()
            else
                require("webcommon").message("Settings restored. Restart KOReader to use them.")
            end
        end)
    end, true)
end

return Web
