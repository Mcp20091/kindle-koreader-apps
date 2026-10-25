--[[--
Files: the reader's storage from a browser, as CrossInk's file manager does:
list a folder, upload (several at once, straight to disk), download, preview,
new folder, rename, move, copy and delete (with Undo). Everything stays inside
the storage root (/mnt/us on a Kindle, else KOReader's home folder).

Moving, renaming, copying and deleting work as in KOReader's file browser and
the Library app (library.koplugin, librarymodel.lua): a book's settings,
reading history, collections and folder shortcuts follow it, and Delete moves
into the Library's trash folder first so Undo can bring it back.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Files = {}

function Files.root()
    if Device:isKindle() and lfs.attributes("/mnt/us", "mode") == "directory" then return "/mnt/us" end
    local home = G_reader_settings:readSetting("home_dir")
    if home and lfs.attributes(home, "mode") == "directory" then return home end
    return DataStorage:getDataDir()
end

--- A path from the browser ("/documents/a.epub") as a full path inside the
-- root, or nil when it would leave it.
function Files.full(rel)
    local parts = {}
    for part in (rel or ""):gmatch("[^/]+") do
        if part == ".." then return nil end
        if part ~= "." then table.insert(parts, part) end
    end
    local inner = table.concat(parts, "/")
    return Files.root() .. (inner ~= "" and ("/" .. inner) or ""), "/" .. inner
end

local function validName(name)
    return type(name) == "string" and name ~= "" and name ~= "." and name ~= ".." and not name:find("[/%z]")
end

-- The file browser on the reader shows the change, and the Library and the
-- search here walk the files again.
local function refreshReader()
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    if FileManager and FileManager.instance and FileManager.instance.file_chooser then
        pcall(function() FileManager.instance.file_chooser:refreshPath() end)
    end
    local LM = package.loaded["librarymodel"]
    if LM and LM.changed then pcall(LM.changed) end
    local WL = package.loaded["weblibrary"]
    if WL then WL.forget() end
end

--- A full path as one from the browser ("/documents/Books"), or nil when
-- it isn't inside the root.
function Files.relative(path)
    if type(path) ~= "string" then return nil end
    path = path:gsub("/+$", "")
    -- (KOReader often keeps the real path: /mnt/base-us for /mnt/us on a Kindle.)
    local root = Files.root()
    for __, r in ipairs({ root, require("ffi/util").realpath(root) }) do
        if path == r then return "/" end
        if path:sub(1, #r + 1) == r .. "/" then return path:sub(#r + 1) end
    end
end

-- ------------------------------------------------------------------ favorites

-- Favorite folders are KOReader's folder shortcuts; favorite files are its
-- Favorites collection. So a star here shows on the Kindle too, and the
-- other way round.

local function realpath(p) return require("ffi/util").realpath(p) or p end

-- KOReader's folder shortcuts: { [full path] = { text = name } }, and where to change them.
local function shortcutTable()
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local fm = FileManager and FileManager.instance
    return (fm and fm.folder_shortcuts and fm.folder_shortcuts.folder_shortcuts) or G_reader_settings:readSetting("folder_shortcuts") or {}
end

-- The Favorites collection (read fresh), or nil without one.
local function favorites()
    local ok, RC = pcall(require, "readcollection")
    if not ok then return nil end
    pcall(RC._read, RC)
    local coll = RC.coll and RC.coll[RC.default_collection_name]
    return coll and RC, coll
end

--- Which of a folder's entries are favorites: sets `fav` on each.
function Files.markFavorites(dir, entries)
    local folders = {}
    for folder, s in pairs(shortcutTable()) do
        if type(s) == "table" and s.text then folders[realpath(folder)] = true end
    end
    local __, coll = favorites()
    for __, e in ipairs(entries) do
        local full = realpath(dir .. "/" .. e.name)
        if e.dir then
            e.fav = folders[full] or nil
        else
            e.fav = (coll and coll[full]) and true or nil
        end
    end
end

--- A star on (`on`) or off for a folder or file ("/documents/a.epub").
-- Returns nil or why not.
function Files.setFavorite(rel, on)
    local full = Files.full(rel)
    local mode = full and lfs.attributes(full, "mode")
    if not mode then return "No such file or folder" end
    if mode == "directory" then
        local KO = require("webkoreader")
        if on then return KO.changeFolders({ add = { folder = full } }) end
        -- The shortcut as KOReader keeps it (perhaps under the real path).
        local real = realpath(full)
        for folder, s in pairs(shortcutTable()) do
            if type(s) == "table" and s.text and realpath(folder) == real then return KO.changeFolders({ remove = folder }) end
        end
        return
    end
    local RC, coll = favorites()
    if not RC then return "KOReader's collections aren't available" end
    if on then
        if not coll[realpath(full)] then RC:addItem(full, RC.default_collection_name) end
        RC:write({ [RC.default_collection_name] = true })
    else
        RC:removeItem(full, RC.default_collection_name)
    end
end

--- KOReader's Home folder and folder shortcuts, for quick links:
-- { home = "/documents/Books" or nil, shortcuts = { { name, path } } }.
function Files.places()
    local out = { home = Files.relative(G_reader_settings:readSetting("home_dir")), shortcuts = {} }
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local fm = FileManager and FileManager.instance
    local list = (fm and fm.folder_shortcuts and fm.folder_shortcuts.folder_shortcuts) or G_reader_settings:readSetting("folder_shortcuts") or {}
    for folder, s in pairs(list) do
        local rel = Files.relative(folder)
        -- (KOReader keeps its own folders here too, without a name: not shortcuts.)
        if rel and type(s) == "table" and s.text and lfs.attributes(folder, "mode") == "directory" then
            table.insert(out.shortcuts, { name = s.text, path = rel })
        end
    end
    table.sort(out.shortcuts, function(a, b) return a.name:lower() < b.name:lower() end)
    -- Favorite files, in KOReader's order.
    out.files = {}
    local RC = favorites()
    if RC then
        local ok, list = pcall(RC.getOrderedCollection, RC, RC.default_collection_name)
        for __, item in ipairs(ok and list or {}) do
            local rel = Files.relative(item.file)
            if rel then table.insert(out.files, { name = item.text or rel:match("[^/]+$"), path = rel }) end
        end
    end
    return out
end

-- ------------------------------------------------------------------ moving, copying, deleting

local ffiutil = require("ffi/util")

-- The Library app's model when it's installed: its moves, copies and trash are
-- then the very code its own screens use. What follows here is the same done
-- without it (keep the two alike).
local function library()
    local ok, LM = pcall(require, "librarymodel")
    if ok and type(LM) == "table" and LM.moveTo and LM.copyTo and LM.trash and LM.untrash and LM.purgeTrash then return LM end
end

local function history()
    local ok, RH = pcall(require, "readhistory")
    return ok and RH or nil
end

-- KOReader's collections, read fresh.
local function collections()
    local ok, RC = pcall(require, "readcollection")
    if not ok then return nil end
    pcall(RC._read, RC)
    return RC.coll and RC or nil
end

local function fileManager()
    return package.loaded["apps/filemanager/filemanager"] or require("apps/filemanager/filemanager")
end

local function mv(from, to)
    return ffiutil.execute(fileManager().mv_bin or "/bin/mv", from, to) == 0
end

local function cp(from, to)
    return ffiutil.execute(fileManager().cp_bin or "/bin/cp", "-r", from, to) == 0
end

local function resetCache(path)
    local ok, BL = pcall(require, "ui/widget/booklist")
    if ok and BL and BL.resetBookInfoCache then pcall(BL.resetBookInfoCache, path) end
end

-- The Cover browser's record follows a file (so its cover isn't read again).
local function moveInfo(from, to, isDir)
    local ok, bim = pcall(require, "bookinfomanager")
    if not ok or type(bim) ~= "table" or not bim.openDbConnection then return end
    pcall(function()
        bim:openDbConnection()
        local util = require("util")
        local conn = bim.db_conn
        if isDir then
            local a, b = from:gsub("/+$", "") .. "/", to:gsub("/+$", "") .. "/"
            local stmt = conn:prepare("UPDATE bookinfo SET directory = ? || substr(directory, ?) WHERE substr(directory, 1, ?) = ?;")
            stmt:bind(b, #a + 1, #a, a):step()
            stmt:close()
        else
            local fd, fn = util.splitFilePathName(from)
            local td, tn = util.splitFilePathName(to)
            local stmt = conn:prepare("UPDATE OR REPLACE bookinfo SET directory = ?, filename = ? WHERE directory = ? AND filename = ?;")
            stmt:bind(td, tn, fd, fn):step()
            stmt:close()
        end
    end)
end

-- KOReader's folder shortcuts follow a moved folder.
local function shortcutsMoved(from, to)
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local fs = FileManager and FileManager.instance and FileManager.instance.folder_shortcuts
    if fs and fs.updateItemsByPath then
        pcall(fs.updateItemsByPath, fs, from, to)
        return
    end
    local list = G_reader_settings:readSetting("folder_shortcuts")
    if type(list) ~= "table" then return end
    local changed = {}
    for folder, v in pairs(list) do
        if folder == from or folder:sub(1, #from + 1) == from .. "/" then changed[folder] = v end
    end
    for folder, v in pairs(changed) do
        list[folder] = nil
        list[to .. folder:sub(#from + 1)] = v
    end
    if next(changed) then G_reader_settings:saveSetting("folder_shortcuts", list) end
end

--- A name for a file going where one of that name is: "Name (2).epub".
function Files.freeName(name, exists)
    if not exists(name) then return name end
    local base, ext = name:match("^(.-)(%.[^.]*)$")
    if not base or base == "" then base, ext = name, "" end
    for i = 2, 999 do
        local n = base .. " (" .. i .. ")" .. ext
        if not exists(n) then return n end
    end
    return name
end

--- Moves a file or folder (full paths) into the folder `dest`, perhaps under
-- a new name, as KOReader does it. Returns the new path, or nil and "exists" or "failed".
function Files.moveTo(path, dest, newName)
    local LM = library()
    if LM then return LM.moveTo(path, dest, newName) end
    local name = newName or path:match("[^/]+$")
    local to = dest .. "/" .. name
    if to == path then return path end
    if lfs.attributes(to, "mode") then return nil, "exists" end
    local isFile = lfs.attributes(path, "mode") == "file"
    -- (KOReader's collections read before the move: read after it, they drop the file that's gone)
    local RH, RC = history(), collections()
    if not mv(path, to) then return nil, "failed" end
    local DocSettings = require("docsettings")
    if isFile then
        pcall(DocSettings.updateLocation, path, to)
        if RH then pcall(RH.updateItem, RH, path, to) end
        if RC then pcall(RC.updateItem, RC, path, to) end
        resetCache(path)
    else
        if RH then pcall(RH.updateItemsByPath, RH, path, to) end
        if RC then pcall(RC.updateItemsByPath, RC, path, to) end
        shortcutsMoved(path, to)
    end
    moveInfo(path, to, not isFile)
    return to
end

--- Copies into the folder `dest`; a name already there gets " (2)". A book's
-- settings (its progress, highlights and notes) are copied too. Returns the new path, or nil, why.
function Files.copyTo(path, dest)
    local LM = library()
    if LM then return LM.copyTo(path, dest) end
    local name = path:match("[^/]+$")
    local free = Files.freeName(name, function(n) return lfs.attributes(dest .. "/" .. n, "mode") ~= nil end)
    local to = dest .. "/" .. free
    if lfs.attributes(to, "mode") then return nil, "exists" end
    if not cp(path, to) then return nil, "failed" end
    if lfs.attributes(path, "mode") == "file" then
        pcall(require("docsettings").updateLocation, path, to, true)
    end
    return to
end

-- Where deleted files wait for Undo: the Library app's trash folder (on the
-- same storage, so moving is instant).
function Files.trashDir()
    return DataStorage:getDataDir() .. "/cache/library-trash"
end

local trashed = {} -- [key] = { dir, moved = { { from, to, dir } } }, or { lib = the Library's }

-- For good (the Undo has gone): as KOReader's Delete, from the trash.
local function purge(t)
    local DocSettings = require("docsettings")
    local RH, RC = history(), collections()
    for __, m in ipairs(t.moved) do
        local mode = lfs.attributes(m.to, "mode")
        if mode == "file" then
            if os.remove(m.to) then
                resetCache(m.to)
                pcall(DocSettings.updateLocation, m.to)
                if RH then pcall(RH.fileDeleted, RH, m.to) end
                if RC then pcall(RC.removeItem, RC, m.to) end
            end
        elseif mode == "directory" then
            if RH then pcall(RH.folderDeleted, RH, m.to) end
            if RC then pcall(RC.removeItemsByPath, RC, m.to) end
            pcall(ffiutil.purgeDir, m.to)
        end
    end
    pcall(ffiutil.purgeDir, t.dir)
end

--- Deletes at once into the trash (KOReader's history and collections follow
-- it there). Returns a key for Undo (nil when nothing went) and the paths that couldn't go.
function Files.trash(fulls)
    local key = os.time() .. "-" .. math.random(1000, 9999)
    local failed = {}
    local LM = library()
    if LM then
        local t = #fulls > 0 and LM.trash(fulls) or nil
        local went = {}
        for __, m in ipairs(t and t.moved or {}) do went[m.from] = true end
        for __, p in ipairs(fulls) do if not went[p] then table.insert(failed, p) end end
        if not t then return nil, failed end
        trashed[key] = { lib = t }
    else
        local dir = Files.trashDir() .. "/web-" .. key
        require("util").makePath(dir)
        local moved = {}
        for i, p in ipairs(fulls) do
            local slot = dir .. "/" .. i
            lfs.mkdir(slot)
            local to = Files.moveTo(p, slot)
            if to then
                table.insert(moved, { from = p, to = to, dir = p:match("^(.*)/[^/]+$") })
            else
                table.insert(failed, p)
            end
        end
        if #moved == 0 then
            pcall(ffiutil.purgeDir, dir)
            return nil, failed
        end
        trashed[key] = { dir = dir, moved = moved }
    end
    -- Gone for good when the page says its Undo has gone, or after a minute
    -- if it never does (the page was closed).
    require("ui/uimanager"):scheduleIn(60, function() Files.purge(key) end)
    return key, failed
end

--- Undo: everything back where it was. Returns how many came back, or nil, why.
function Files.untrash(key)
    local t = trashed[key or ""]
    if not t then return nil, "Too late to undo" end
    trashed[key] = nil
    if t.lib then
        local LM = library()
        if not LM then return nil, "Too late to undo" end
        return LM.untrash(t.lib)
    end
    local back = 0
    for __, m in ipairs(t.moved) do
        if Files.moveTo(m.to, m.dir, m.from:match("[^/]+$")) then back = back + 1 end
    end
    purge(t)
    return back
end

function Files.purge(key)
    local t = trashed[key or ""]
    if not t then return end
    trashed[key] = nil
    if t.lib then
        local LM = library()
        if LM then LM.purgeTrash(t.lib) end
        return
    end
    purge(t)
end

--- Left over from a KOReader that stopped before an Undo went: gone now.
-- (Only the web page's: the Library's own may still have its Undo showing,
-- and the Library empties its leftovers when KOReader starts.)
function Files.emptyTrash()
    local root = Files.trashDir()
    if lfs.attributes(root, "mode") ~= "directory" then return end
    for name in lfs.dir(root) do
        local key = name:match("^web%-(.+)$")
        if key and not trashed[key] then
            local dir = root .. "/" .. name
            local moved = {}
            for slot in lfs.dir(dir) do
                local sub = dir .. "/" .. slot
                if slot ~= "." and slot ~= ".." and lfs.attributes(sub, "mode") == "directory" then
                    for f in lfs.dir(sub) do
                        if f ~= "." and f ~= ".." and not f:match("%.sdr$") then table.insert(moved, { to = sub .. "/" .. f }) end
                    end
                end
            end
            purge({ dir = dir, moved = moved })
        end
    end
end

function Files.routes(server)
    server:route("GET", "^/api/files$", function(req, res)
        local full, rel = Files.full(req.query.path)
        if not full or lfs.attributes(full, "mode") ~= "directory" then return res:error(404, "No such folder") end
        local entries = {}
        for name in lfs.dir(full) do
            -- (books' .sdr folders hold KOReader's settings for them: hidden, as on the Kindle)
            if name ~= "." and name ~= ".." and (req.query.hidden == "1" or (name:sub(1, 1) ~= "." and not name:match("%.sdr$"))) then
                local a = lfs.attributes(full .. "/" .. name)
                if a then
                    table.insert(entries, { name = name, dir = a.mode == "directory", size = a.size or 0, mtime = a.modification or 0 })
                end
            end
        end
        table.sort(entries, function(a, b)
            if a.dir ~= b.dir then return a.dir end
            return a.name:lower() < b.name:lower()
        end)
        Files.markFavorites(full, entries)
        res:json({ path = rel, root = Files.root(), entries = entries, places = Files.places() })
    end)

    -- { path, on }: a star on a folder (a folder shortcut) or file (Favorites).
    server:route("POST", "^/api/files/favorite$", function(req, res)
        local b = req.json()
        local why = Files.setFavorite(b.path, b.on == true)
        if why then return res:error(400, why) end
        res:json({ ok = true })
    end)

    -- PUT with the file as the body (not a form), written as it arrives.
    server:route("PUT", "^/api/files/upload$", function(req, res)
        local dir = Files.full(req.query.path)
        local name = req.query.name
        if not dir or lfs.attributes(dir, "mode") ~= "directory" or not validName(name) then
            return res:error(400, "Invalid folder or file name")
        end
        local target = dir .. "/" .. name
        local tmp = target .. ".part"
        local f = io.open(tmp, "wb")
        if not f then return res:error(500, "Can't write to this folder") end
        local got = 0
        while true do
            local chunk = req:read(64 * 1024)
            if not chunk then break end
            f:write(chunk)
            got = got + #chunk
        end
        f:close()
        if got ~= req.length then
            os.remove(tmp)
            return res:error(400, "The upload was interrupted")
        end
        os.remove(target)
        os.rename(tmp, target)
        refreshReader()
        res:json({ ok = true, size = got })
    end, true)

    server:route("GET", "^/api/files/download$", function(req, res)
        local full = Files.full(req.query.path)
        if not full or lfs.attributes(full, "mode") ~= "file" then return res:error(404, "No such file") end
        res:file(full, nil, req.query.inline == "1")
    end)

    server:route("POST", "^/api/files/mkdir$", function(req, res)
        local b = req.json()
        local dir = Files.full(b.path)
        if not dir or not validName(b.name) then return res:error(400, "Invalid name") end
        local ok, err = lfs.mkdir(dir .. "/" .. b.name)
        if not ok then return res:error(409, tostring(err)) end
        refreshReader()
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/files/rename$", function(req, res)
        local b = req.json()
        local full = Files.full(b.path)
        if not full or full == Files.root() or not validName(b.name) then return res:error(400, "Invalid name") end
        local to, why = Files.moveTo(full, full:match("^(.*)/[^/]+$"), b.name)
        if not to then return res:error(why == "exists" and 409 or 500, why == "exists" and "That name is already taken" or "Couldn't rename it") end
        refreshReader()
        res:json({ ok = true, path = Files.relative(to) })
    end)

    -- { paths, to, copy }: Move to… or Copy to… a folder. `failed` names what
    -- couldn't, with why ("Name (already there)").
    server:route("POST", "^/api/files/move$", function(req, res)
        local b = req.json()
        local to = Files.full(b.to)
        if not to or lfs.attributes(to, "mode") ~= "directory" then return res:error(400, "No such folder") end
        local failed, done = {}, 0
        for __, p in ipairs(type(b.paths) == "table" and b.paths or {}) do
            local full = Files.full(p)
            local name = full and full:match("[^/]+$") or tostring(p)
            local ok, why
            if not full or full == Files.root() or not lfs.attributes(full, "mode") then
                why = "failed"
            elseif (to .. "/"):sub(1, #full + 1) == full .. "/" then
                why = "inside"
            elseif b.copy then
                ok, why = Files.copyTo(full, to)
            elseif full:match("^(.*)/[^/]+$") == to then
                ok = true -- (already in that folder)
            else
                ok, why = Files.moveTo(full, to)
            end
            if ok then
                done = done + 1
            else
                table.insert(failed, name .. (why == "exists" and " (already there)" or why == "inside" and " (a folder can't go inside itself)" or ""))
                logger.warn("Web server: could not", b.copy and "copy" or "move", p)
            end
        end
        refreshReader()
        res:json({ ok = #failed == 0, done = done, failed = failed })
    end)

    -- { paths }: into the trash at once; { key } for Undo (/undo) or to make it
    -- final when the Undo has gone (/purge).
    server:route("POST", "^/api/files/delete$", function(req, res)
        local b = req.json()
        local fulls, failed = {}, {}
        for __, p in ipairs(type(b.paths) == "table" and b.paths or {}) do
            local full = Files.full(p)
            if not full or full == Files.root() or not lfs.attributes(full, "mode") then
                table.insert(failed, tostring(p))
            else
                table.insert(fulls, full)
            end
        end
        local key, notMoved = Files.trash(fulls)
        for __, full in ipairs(notMoved or {}) do
            table.insert(failed, Files.relative(full) or full)
            logger.warn("Web server: could not delete", full)
        end
        refreshReader()
        res:json({ ok = #failed == 0, key = key, deleted = #fulls - #(notMoved or {}), failed = failed })
    end)

    server:route("POST", "^/api/files/undo$", function(req, res)
        local back, why = Files.untrash(req.json().key)
        if not back then return res:error(410, why) end
        refreshReader()
        res:json({ ok = true, back = back })
    end)

    server:route("POST", "^/api/files/purge$", function(req, res)
        Files.purge(req.json().key)
        res:json({ ok = true })
    end)
end

return Files
