--[[--
Notes' folders: which folder each notebook is in, and the folders made
(empty ones too), kept in koreader/notes/folders.lua apart from the
notebooks (moving one does not change its file or its "last changed").

A folder is a path of names: "Work", "Work/Clients"; "" is the top level.
Plain Lua (no KOReader modules), for the tests.

@module koplugin.notes.folders
]]

local Folders = {}
Folders.__index = Folders

Folders.TRASH_DAYS = 30   -- as the store's trash (shown in the trash's list)

--- The folders kept in the file at `path` (made when first saved).
function Folders.open(path)
    local self = setmetatable({ path = path, list = {}, at = {}, covers = {}, created = {} }, Folders)
    local file = io.open(path, "rb")
    if file then
        local fn = (loadstring or load)(file:read("*a"))
        file:close()
        if fn then
            if setfenv then setfenv(fn, {}) end
            local ok, t = pcall(fn)
            if ok and type(t) == "table" then
                for __, p in ipairs(type(t.folders) == "table" and t.folders or {}) do
                    if type(p) == "string" and p ~= "" then self.list[p] = true end
                end
                for id, p in pairs(type(t.at) == "table" and t.at or {}) do
                    if type(id) == "string" and type(p) == "string" and p ~= "" then self.at[id] = p end
                end
                for p, c in pairs(type(t.covers) == "table" and t.covers or {}) do
                    if type(p) == "string" and type(c) == "string" and Folders.validCover(c) then self.covers[p] = c end
                end
                for p, at in pairs(type(t.created) == "table" and t.created or {}) do
                    if type(p) == "string" and type(at) == "number" then self.created[p] = at end
                end
            end
        end
    end
    return self
end

--- All of it as it is now (folders, which notebook is where, covers, dates),
-- to put back with restore() (Undo after a delete).
function Folders:snapshot()
    local function copy(t)
        local out = {}
        for k, v in pairs(t) do out[k] = v end
        return out
    end
    return { list = copy(self.list), at = copy(self.at), covers = copy(self.covers), created = copy(self.created) }
end

function Folders:restore(snap)
    self.list, self.at, self.covers, self.created = snap.list, snap.at, snap.covers, snap.created
end

function Folders:save()
    local out = { "return {\nfolders = {\n" }
    for __, p in ipairs(self:all()) do table.insert(out, string.format("%q,\n", p)) end
    table.insert(out, "},\nat = {\n")
    local ids = {}
    for id in pairs(self.at) do table.insert(ids, id) end
    table.sort(ids)
    for __, id in ipairs(ids) do table.insert(out, string.format("[%q] = %q,\n", id, self.at[id])) end
    table.insert(out, "},\ncovers = {\n")
    local paths = {}
    for p in pairs(self.covers) do table.insert(paths, p) end
    table.sort(paths)
    for __, p in ipairs(paths) do table.insert(out, string.format("[%q] = %q,\n", p, self.covers[p])) end
    table.insert(out, "},\ncreated = {\n")
    paths = {}
    for p in pairs(self.created) do table.insert(paths, p) end
    table.sort(paths)
    for __, p in ipairs(paths) do table.insert(out, string.format("[%q] = %d,\n", p, self.created[p])) end
    table.insert(out, "},\n}\n")
    local file = io.open(self.path .. ".tmp", "wb")
    if not file then return false end
    file:write(table.concat(out))
    file:close()
    os.remove(self.path)
    return os.rename(self.path .. ".tmp", self.path) ~= nil
end

--- The last name of a path ("Clients" of "Work/Clients").
function Folders.name(path)
    return (path or ""):match("([^/]+)$") or ""
end

--- The folder a path is in ("Work" of "Work/Clients", "" of "Work").
function Folders.parent(path)
    return (path or ""):match("^(.*)/[^/]+$") or ""
end

function Folders.join(parent, name)
    return (parent == nil or parent == "") and name or (parent .. "/" .. name)
end

--- Whether `path` is `folder` or inside it.
function Folders.within(path, folder)
    return path == folder or (folder == "" and path ~= nil) or (path or ""):sub(1, #folder + 1) == folder .. "/"
end

--- A name as a folder name: trimmed, without "/" (nil when nothing is left).
function Folders.clean(name)
    name = tostring(name or ""):gsub("/", "-"):match("^%s*(.-)%s*$")
    return name ~= "" and name or nil
end

--- A folder cover choice: "peek" (the notebooks in it), "plain", an icon
-- ("icon:house") or a notebook ("nb:<id>").
function Folders.validCover(c)
    return c == "peek" or c == "plain" or c:match("^icon:[%w%-]+$") ~= nil or c:match("^nb:nb%d+$") ~= nil
end

--- A folder's cover as chosen (nil: the default).
function Folders:cover(path)
    return self.covers[path]
end

function Folders:setCover(path, c)
    self.covers[path] = (c and Folders.validCover(c)) and c or nil
end

--- The folder a notebook is in ("" at the top level).
function Folders:of(id)
    return self.at[id] or ""
end

function Folders:set(id, path)
    self.at[id] = (path ~= nil and path ~= "") and path or nil
    if path and path ~= "" then self:add(path) end
end

function Folders:forget(id)
    self.at[id] = nil
end

--- A folder made (and the folders it is in). New ones get the time they
-- were made (for sorting by date created).
function Folders:add(path, now)
    local known = {}
    for __, p in ipairs(self:all()) do known[p] = true end
    while path and path ~= "" do
        self.list[path] = true
        if not known[path] and not self.created[path] then self.created[path] = now or os.time() end
        path = Folders.parent(path)
    end
end

--- Folders in an order: "name" (A to Z), or newest first by "created" or
-- "modified" (`info(path)` gives { created, modified } for those).
function Folders.sorted(paths, by, info)
    local out = {}
    for i, p in ipairs(paths) do out[i] = p end
    local function byName(a, b) return Folders.name(a):lower() < Folders.name(b):lower() end
    if by == "created" or by == "modified" then
        local v = {}
        for __, p in ipairs(out) do v[p] = (info(p) or {})[by] or 0 end
        table.sort(out, function(a, b)
            if v[a] ~= v[b] then return v[a] > v[b] end
            return byName(a, b)
        end)
    else
        table.sort(out, byName)
    end
    return out
end

--- Every folder, sorted ("Work" before "Work/Clients").
function Folders:all()
    local set = {}
    for p in pairs(self.list) do set[p] = true end
    for __, p in pairs(self.at) do
        while p ~= "" do set[p] = true p = Folders.parent(p) end
    end
    local out = {}
    for p in pairs(set) do table.insert(out, p) end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

--- The folders right inside `parent`, sorted by name.
function Folders:children(parent)
    local out = {}
    for __, p in ipairs(self:all()) do
        if Folders.parent(p) == (parent or "") then table.insert(out, p) end
    end
    table.sort(out, function(a, b) return Folders.name(a):lower() < Folders.name(b):lower() end)
    return out
end

--- The notebooks in a folder or the folders inside it (ids, from `ids`).
function Folders:inside(path, ids)
    local out = {}
    for __, id in ipairs(ids) do
        local p = self:of(id)
        if p ~= "" and Folders.within(p, path) then table.insert(out, id) end
    end
    return out
end

--- A folder (and what is in it) under a new path. False when the new path
-- is the folder itself or inside it, or already a folder.
function Folders:rename(path, to)
    if to == path or Folders.within(to, path) then return false end
    for __, p in ipairs(self:all()) do
        if p == to then return false end
    end
    local function moved(p)
        if Folders.within(p, path) then return to .. p:sub(#path + 1) end
        return p
    end
    local list = {}
    for p in pairs(self.list) do list[moved(p)] = true end
    self.list = list
    for id, p in pairs(self.at) do self.at[id] = moved(p) end
    local covers = {}
    for p, c in pairs(self.covers) do covers[moved(p)] = c end
    self.covers = covers
    local created = {}
    for p, at in pairs(self.created) do created[moved(p)] = at end
    self.created = created
    self:add(to)
    return true
end

--- A folder taken away with the folders inside it. Its notebooks go to
-- `moveTo` (a folder, or "" for the top level), or when that is nil are
-- forgotten and returned (to be deleted).
function Folders:remove(path, moveTo)
    local gone = {}
    for p in pairs(self.list) do
        if Folders.within(p, path) then self.list[p] = nil end
    end
    for p in pairs(self.covers) do
        if Folders.within(p, path) then self.covers[p] = nil end
    end
    for p in pairs(self.created) do
        if Folders.within(p, path) then self.created[p] = nil end
    end
    for id, p in pairs(self.at) do
        if Folders.within(p, path) then
            if moveTo ~= nil then
                self.at[id] = moveTo ~= "" and moveTo or nil
            else
                self.at[id] = nil
                table.insert(gone, id)
            end
        end
    end
    return gone
end

return Folders
