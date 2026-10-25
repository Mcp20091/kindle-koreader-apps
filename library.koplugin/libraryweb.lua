--[[--
The web page's Servers and catalogs card (webpage.koplugin's webservers
passes its calls on): the FTP and WebDAV servers and the OPDS catalogs (the
same lists as KOReader's Cloud storage and OPDS catalog), the download folder,
and Test. Passwords come from the page but never go back to it.
]]

local R = require("libraryservers")
local Cat = require("libraryopds")

local W = {}

local function pick(t, keys)
    local o = {}
    for __, k in ipairs(keys) do o[k] = t[k] end
    return o
end

--- { servers = { { index, name, type, address, port, username, hasPassword, url, label } },
-- catalogs = { { index, title, url, username, hasPassword, label } }, suggested = { { title, url, about } },
-- downloadDir, opds (KOReader's OPDS code there) }.
function W.state()
    local servers = {}
    for __, s in ipairs(R.servers()) do
        local addr, port = R.splitPort(s.address)
        local o = pick(s, { "index", "type", "url" })
        o.name = R.name(s)
        o.address = addr
        o.port = port or R.defaultPort(s.type, addr)
        o.username = s.username or ""
        o.hasPassword = type(s.password) == "string" and s.password ~= ""
        o.label = R.label(s)
        table.insert(servers, o)
    end
    local out = { servers = servers, catalogs = {}, suggested = {}, downloadDir = R.downloadDir(), opds = Cat.available() }
    if out.opds then
        local list = Cat.catalogs()
        for __, c in ipairs(list) do
            table.insert(out.catalogs, { index = c.index, title = c.title or Cat.host(c.url), url = c.url, username = c.username or "",
                hasPassword = type(c.password) == "string" and c.password ~= "", label = Cat.label(c) })
        end
        out.suggested = Cat.missing(list)
    end
    return out
end

-- What Delete took, for Undo (this KOReader run only).
local removed = {}
local function keep(kind, entry, index)
    local key = kind .. os.time() .. math.random(1000, 9999)
    removed[key] = { kind = kind, entry = entry, index = index }
    return key
end

local function serverFrom(a, old)
    local kind = a.type == "webdav" and "webdav" or "ftp"
    local s = { index = old and old.index, type = kind, name = a.name ~= "" and a.name or nil,
        address = R.normalize(kind, a.address or "", a.port), username = a.username or "",
        password = a.password ~= nil and a.password or (old and old.password) or "", url = R.folder(a.url) }
    return s
end

local function find(list, index)
    for __, x in ipairs(list) do if x.index == tonumber(index) then return x end end
end

--- The card's actions; the answer, or nil, why.
function W.act(name, a)
    a = type(a) == "table" and a or {}
    if name == "saveServer" then
        local old = a.index and find(R.servers(), a.index)
        if a.index and not old then return nil, "That server is gone" end
        local s = serverFrom(a, old)
        if s.address == "" then return nil, "Type the address" end
        return { index = R.save(s) }
    elseif name == "deleteServer" then
        local old = find(R.servers(), a.index)
        if not old then return nil, "That server is gone" end
        return { undo = keep("server", R.remove(old.index), old.index) }
    elseif name == "saveCatalog" then
        local old = a.index and find(Cat.catalogs(), a.index)
        if a.index and not old then return nil, "That catalog is gone" end
        local url = Cat.normalize(a.url or "")
        if url == "" then return nil, "Type the address" end
        local title = (a.title or ""):match("^%s*(.-)%s*$")
        return { index = Cat.save({ index = old and old.index, title = title ~= "" and title or Cat.host(url), url = url,
            username = a.username or "", password = a.password ~= nil and a.password or (old and old.password) or "" }) }
    elseif name == "addSuggested" then
        for __, s in ipairs(Cat.missing(Cat.catalogs())) do
            if s.url == a.url then return { index = Cat.save({ title = s.title, url = s.url }) } end
        end
        return nil, "Already in the list"
    elseif name == "deleteCatalog" then
        local old = find(Cat.catalogs(), a.index)
        if not old then return nil, "That catalog is gone" end
        return { undo = keep("catalog", Cat.remove(old.index), old.index) }
    elseif name == "restore" then
        local r = removed[a.key]
        if not r then return nil, "Too late to undo" end
        removed[a.key] = nil
        if r.kind == "server" then R.restore(r.entry, r.index) else Cat.restore(r.entry, r.index) end
        return { ok = true }
    elseif name == "setDownloadDir" then
        local lfs = require("libs/libkoreader-lfs")
        if type(a.path) ~= "string" or lfs.attributes(a.path, "mode") ~= "directory" then return nil, "No such folder" end
        R.setDownloadDir(a.path)
        return { ok = true }
    end
    return nil, "Unknown action"
end

-- Tests running in a child process: key → { status, … }.
local tests = {}

--- Test a server or a catalog (saved: index; or as typed: the fields) in the background; { key }.
function W.testStart(a)
    a = type(a) == "table" and a or {}
    local key = tostring(os.time()) .. math.random(1000, 9999)
    tests[key] = { status = "waiting" }
    local fn
    if a.kind == "catalog" then
        local old = a.index and find(Cat.catalogs(), a.index)
        local c = { url = Cat.normalize(a.url or (old and old.url) or ""), username = a.username or (old and old.username) or "",
            password = a.password ~= nil and a.password or (old and old.password) or "" }
        if c.url == "" then return nil, "Type the address" end
        fn = function()
            local p = Cat.page(c, c.url)
            if not p then return { ok = false } end
            local books, sections = 0, 0
            for __, e in ipairs(p.entries) do if e.formats then books = books + 1 else sections = sections + 1 end end
            return { ok = true, books = books, sections = sections, search = p.search ~= nil }
        end
    else
        local old = a.index and find(R.servers(), a.index)
        local s = serverFrom(a.address and a or old or {}, old)
        if s.address == "" then return nil, "Type the address" end
        fn = function()
            local list, why = R.list(s, s.url)
            if not list then return { ok = false, why = why } end
            local folders, books = 0, 0
            for __, e in ipairs(list) do if e.dir then folders = folders + 1 else books = books + 1 end end
            return { ok = true, folders = folders, books = books }
        end
    end
    R.run(fn, function(res)
        local t = res or { ok = false }
        t.status = "done"
        tests[key] = t
    end, 60)
    return { key = key }
end

function W.testResult(key)
    return tests[key]
end

return W
