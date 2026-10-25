--[[--
FTP and WebDAV servers, as places to open books from and copy books to.

The servers are KOReader's Cloud storage list (settings/cloudstorage.lua,
cs_servers: { name, type = "ftp" | "webdav", address, username, password,
url = the starting folder }), so one added here shows there and the other way
round. The network is KOReader's own code: the Cloud storage plugin's providers
(socket.ftp for FTP, its WebDAV client over http/https), or the older
apps/cloudstorage modules. Every call that goes on the network runs in a
child process (libraryonline's O.run), so the screen never waits on it.

Plain helpers first (tests/run.lua), then what needs KOReader.
]]

local R = {}

R.TYPES = { ftp = "FTP", webdav = "WebDAV" }

local function trim(s) return type(s) == "string" and (s:match("^%s*(.-)%s*$")) or "" end

--- The port written in an address, and the address without it:
-- "ftp://nas:2121/x" → "ftp://nas/x", 2121.
function R.splitPort(address)
    address = trim(address)
    local scheme, host, port, rest = address:match("^(%a[%w+.-]*://)([^/:@]+):(%d+)(.*)$")
    if not scheme then
        scheme = ""
        host, port, rest = address:match("^([^/:@]+):(%d+)(.*)$")
    end
    if host then return scheme .. host .. rest, tonumber(port) end
    return address, nil
end

--- The port a server of this type and address uses when none is written.
function R.defaultPort(kind, address)
    if kind == "ftp" then return 21 end
    return (trim(address):lower():match("^http://")) and 80 or 443
end

--- What the address field is saved as: a scheme added when there is none
-- (ftp://, else https://), no trailing slash, and the port written in only
-- when it isn't the usual one.
function R.normalize(kind, address, port)
    local addr, written = R.splitPort(address)
    if addr == "" then return "" end
    if not addr:match("^%a[%w+.-]*://") then addr = (kind == "ftp" and "ftp://" or "https://") .. addr end
    if kind == "ftp" then addr = addr:gsub("^%a[%w+.-]*://", "ftp://") end
    addr = addr:gsub("/+$", "")
    -- (a port in the Port field, else one typed in the address)
    port = tonumber(port) or written
    if port and port ~= R.defaultPort(kind, addr) then
        local scheme, host, rest = addr:match("^(%a[%w+.-]*://)([^/]+)(.*)$")
        addr = scheme .. host .. ":" .. port .. rest
    end
    return addr
end

--- A starting folder as the providers want it: "" (the top) or "/Books".
function R.folder(path)
    path = trim(path):gsub("/+$", "")
    if path == "" then return "" end
    if not path:match("^/") then path = "/" .. path end
    return path
end

--- The address without its scheme, for a second line: "192.168.1.20:2121".
function R.host(address)
    return (trim(address):gsub("^%a[%w+.-]*://", ""):gsub("/+$", ""))
end

--- A server's second line: "FTP · 192.168.1.20 · /Books".
function R.label(s)
    local parts = { R.TYPES[s.type] or tostring(s.type), R.host(s.address) }
    local f = R.folder(s.url)
    if f ~= "" then table.insert(parts, f) end
    return table.concat(parts, " · ")
end

--- A server's name: its own, or its host.
function R.name(s)
    local n = trim(s.name)
    if n ~= "" then return n end
    return (R.host(s.address):match("^[^/:]+")) or "?"
end

function R.join(dir, name)
    dir = (dir or ""):gsub("/+$", "")
    return dir .. "/" .. name
end

--- The folder above `path`, or nil at `start` (not above where the server starts).
function R.parent(path, start)
    path, start = R.folder(path), R.folder(start)
    if path == start or #path <= #start then return nil end
    return path:match("^(.*)/[^/]+$") or ""
end

function R.basename(path) return (path or ""):gsub("/+$", ""):match("[^/]+$") or "" end

--- What the providers' listFolder gives (either KOReader's new or old shape),
-- as { name, path, dir, size, mtime }: folders first, then files, by name.
function R.normalizeList(list)
    local dirs, files = {}, {}
    for __, it in ipairs(list or {}) do
        local isDir = it.is_folder or it.type == "folder"
        local isFile = it.is_file or it.type == "file"
        if isDir or isFile then
            local name = (it.text or ""):gsub("/+$", "")
            local e = { name = name, path = it.url, dir = isDir and true or false, size = tonumber(it.filesize), mtime = it.modification }
            table.insert(isDir and dirs or files, e)
        end
    end
    local function byName(a, b) return a.name:lower() < b.name:lower() end
    table.sort(dirs, byName)
    table.sort(files, byName)
    for __, f in ipairs(files) do table.insert(dirs, f) end
    return dirs
end

--- An HTTP-like answer from a provider as ok or not.
function R.okCode(code)
    if code == true then return true end
    code = tonumber(code)
    return code ~= nil and code >= 200 and code <= 299
end

-- ------------------------------------------------------------------ KOReader's Cloud storage list

-- The Cloud storage plugin running in this KOReader (it keeps the list in
-- memory and writes it out itself), or nil.
local function plugin()
    for __, m in ipairs({ "apps/filemanager/filemanager", "apps/reader/readerui" }) do
        local mod = package.loaded[m]
        local ui = mod and mod.instance
        local cs = ui and ui.cloudstorage
        if cs and cs.loadSettings then return cs end
    end
end

local function settingsFile()
    return require("datastorage"):getSettingsDir() .. "/cloudstorage.lua"
end

-- The settings (LuaSettings) and, when it's running, the plugin.
local function store()
    local cs = plugin()
    if cs then
        pcall(cs.loadSettings, cs)
        if cs.settings then return cs.settings, cs end
    end
    return require("luasettings"):open(settingsFile()), nil
end

local function save(settings, cs)
    if cs then cs.updated = true end
    settings:flush()
end

--- FTP and WebDAV servers (Dropbox ones stay in Cloud storage), each with its
-- place in KOReader's list (`index`).
function R.servers()
    local settings = store()
    local out = {}
    for i, s in ipairs(settings:readSetting("cs_servers") or {}) do
        if R.TYPES[s.type] then
            local c = {}
            for k, v in pairs(s) do c[k] = v end
            c.index = i
            table.insert(out, c)
        end
    end
    return out
end

local KEYS = { "name", "type", "address", "username", "password", "url" }

local function plain(s)
    local c = {}
    for __, k in ipairs(KEYS) do c[k] = s[k] end
    -- (keep what Cloud storage added: its sync folder)
    for k, v in pairs(s) do if c[k] == nil and k ~= "index" then c[k] = v end end
    return c
end

--- Adds `s` (index nil) or changes the one at s.index; returns its index.
function R.save(s)
    local settings, cs = store()
    local list = settings:readSetting("cs_servers") or {}
    local i = s.index
    if i and list[i] then
        local keep = list[i]
        local c = plain(s)
        for k, v in pairs(keep) do if c[k] == nil then c[k] = v end end
        list[i] = c
    else
        table.insert(list, plain(s))
        i = #list
    end
    settings:saveSetting("cs_servers", list)
    if cs then cs.servers = list end
    save(settings, cs)
    return i
end

--- Removes the server at `index`; returns it (for Undo: R.restore).
function R.remove(index)
    local settings, cs = store()
    local list = settings:readSetting("cs_servers") or {}
    local gone = table.remove(list, index)
    settings:saveSetting("cs_servers", list)
    if cs then cs.servers = list end
    save(settings, cs)
    return gone
end

function R.restore(s, index)
    local settings, cs = store()
    local list = settings:readSetting("cs_servers") or {}
    table.insert(list, math.min(index, #list + 1), s)
    settings:saveSetting("cs_servers", list)
    if cs then cs.servers = list end
    save(settings, cs)
end

--- Where downloads go: Cloud storage's download folder when it has one, else
-- Downloads in the Home folder.
function R.downloadDir()
    local d = store():readSetting("download_dir")
    local lfs = require("libs/libkoreader-lfs")
    if type(d) == "string" and lfs.attributes(d, "mode") == "directory" then return d end
    return require("librarymodel").home() .. "/Downloads"
end

function R.setDownloadDir(dir)
    local settings, cs = store()
    settings:saveSetting("download_dir", dir)
    save(settings, cs)
end

-- ------------------------------------------------------------------ KOReader's FTP and WebDAV code

local function providerFiles(kind)
    local DataStorage = require("datastorage")
    return { "plugins/cloudstorage.koplugin/providers/" .. kind .. ".lua",
        DataStorage:getDataDir() .. "/plugins/cloudstorage.koplugin/providers/" .. kind .. ".lua" }
end

local providers = {}

-- The Cloud storage plugin's provider for `kind` (its own loaded one when the
-- plugin runs, else read from its folder), or nil on a KOReader without it.
local function provider(kind)
    if providers[kind] ~= nil then return providers[kind] or nil end
    local cs = plugin()
    local p = cs and cs.providers and cs.providers[kind]
    if not p then
        local lfs = require("libs/libkoreader-lfs")
        for __, f in ipairs(providerFiles(kind)) do
            if lfs.attributes(f, "mode") == "file" then
                local ok, got = pcall(dofile, f)
                if ok and type(got) == "table" and got.listFolder then p = got break end
            end
        end
    end
    providers[kind] = p or false
    return p
end

-- (only in the child process: the provider reads the server from .base)
local function use(s)
    local p = provider(s.type)
    if p then p.base = { address = s.address, username = s.username or "", password = s.password or "" } end
    return p
end

-- The older KOReader modules (apps/cloudstorage), for a KOReader without the plugin's providers.
local function old(kind)
    local ok, api = pcall(require, kind == "ftp" and "apps/cloudstorage/ftpapi" or "apps/cloudstorage/webdavapi")
    return ok and api or nil
end

local function ftpUrl(api, s, path)
    local util = require("util")
    return api:generateUrl(s.address, util.urlEncode(s.username or ""), util.urlEncode(s.password or "")) .. (path or "")
end

--- One line of an FTP MLSD answer ("type=dir;size=4096;modify=…; Name") as
-- { name, dir, size, modify }, or nil for "." and "..".
function R.parseMlsd(line)
    local facts, name = line:match("^(%S+)%s(.+)$")
    if not name then return nil end
    local t = {}
    for k, v in facts:gmatch("([%w%.%-]+)=([^;]*);") do t[k:lower()] = v end
    local kind = (t.type or ""):lower()
    if kind == "cdir" or kind == "pdir" or name == "." or name == ".." then return nil end
    return { name = name, dir = kind == "dir", size = tonumber(t.size), modify = t.modify }
end

-- FTP's MLSD through socket.ftp, read by its type= fact (KOReader's lister
-- takes a folder with a size for a file); nil when the server has no MLSD,
-- nil and the code when it refused the login (530) or the folder (550).
local function ftpMlsd(s, path)
    local p = require("socket.url").parse(R.normalize("ftp", s.address, select(2, R.splitPort(s.address))))
    if not (p and p.host) then return nil end
    local t = {}
    local ok, res, err = pcall(require("socket.ftp").get, {
        host = p.host, port = p.port, user = (s.username or "") ~= "" and s.username or nil,
        password = (s.password or "") ~= "" and s.password or nil, command = "mlsd",
        argument = (path:gsub("^/", "")), type = "i", sink = require("ltn12").sink.table(t) })
    if not ok then return nil end
    -- (the login refused or the folder missing: no point asking again another way)
    if not res then return nil, (tostring(err or ""):match("^%s*(5[35]%d)")) end
    local show = G_reader_settings:isTrue("show_unsupported")
    local DocumentRegistry = require("document/documentregistry")
    local raw = {}
    for line in (table.concat(t) .. "\n"):gmatch("(.-)\r?\n") do
        local e = line ~= "" and R.parseMlsd(line)
        if e then
            if e.dir then
                table.insert(raw, { is_folder = true, text = e.name .. "/", url = path .. "/" .. e.name })
            elseif show or DocumentRegistry:hasProvider(e.name) then
                local datetime = package.loaded["datetime"] or select(2, pcall(require, "datetime"))
                local mtime = e.modify and type(datetime) == "table" and datetime.stringRFC3659ToSeconds
                    and datetime.stringRFC3659ToSeconds(e.modify) or nil
                table.insert(raw, { is_file = true, text = e.name, url = path .. "/" .. e.name, filesize = e.size, modification = mtime })
            end
        end
    end
    return raw
end

--- A folder's folders and books: { { name, path, dir, size, mtime } }, or nil, why.
function R.list(s, path)
    path = R.folder(path)
    if s.type == "ftp" then
        local raw, code = ftpMlsd(s, path)
        if raw then return R.normalizeList(raw) end
        if code then return nil, code end
    end
    local p = use(s)
    local raw
    if p then
        raw = p.listFolder(path, true)
    else
        local api = old(s.type)
        if not api then return nil, "no client" end
        if s.type == "ftp" then raw = api:listFolder(ftpUrl(api, s, path), path)
        else raw = api:listFolder(s.address, s.username, s.password, path) end
    end
    if type(raw) ~= "table" then return nil, "no answer" end
    return R.normalizeList(raw)
end

--- R.list as one value, for the child process: { list } or { why }.
function R.listing(s, path)
    local list, why = R.list(s, path)
    return { list = list, why = why }
end

--- Downloads `path` on the server to `dest` on the Kindle; true, or nil, why.
function R.download(s, path, dest)
    local p = use(s)
    local code
    if p then
        code = p.downloadFile(path, dest)
    else
        local api = old(s.type)
        if not api then return nil, "no client" end
        if s.type == "ftp" then
            local f = io.open(dest, "wb")
            if not f then return nil, "can't write" end
            local res = api:ftpGet(ftpUrl(api, s, path), "retr", require("ltn12").sink.file(f))
            code = res and 200 or nil
        else
            code = api:downloadFile(api:getJoinedPath(s.address, path), s.username, s.password, dest)
        end
    end
    if R.okCode(code) then return true end
    return nil, tostring(code)
end

--- Uploads the file `src` into the folder `dir` on the server; true, or nil, why.
function R.upload(s, dir, src)
    local p = use(s)
    if not (p and p.uploadFile) then return nil, "no upload" end
    local code = p.uploadFile(R.folder(dir), src)
    if R.okCode(code) then return true end
    return nil, tostring(code)
end

--- Runs fn in a child process; done(result) or done(nil, why). (Cancel: handle.cancel())
function R.run(fn, done, seconds)
    return require("libraryonline").run(fn, done, seconds)
end

return R
