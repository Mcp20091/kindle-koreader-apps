--[[--
Fonts: every font KOReader can use, adding fonts (TTF, OTF or a zip of them)
and taking added ones out again (with Undo), a font as the default for new
books, and a family from Google Fonts, fetched by the Kindle itself. The
launcher's Fonts screen (appsfontsview.lua) and the web page's Fonts tab
(webfonts.lua) both use it.

Added fonts go where KOReader looks for the user's fonts: EXT_FONT_DIR
(/mnt/us/fonts on a Kindle), else the system's user font folder where
KOReader reads one, else koreader/fonts/added. KOReader reads its font list
when it starts, so a change shows in books after a restart.

Google Fonts: the family's static TTF instances (regular, bold, italic, bold
italic, as many as it has), named by Google's CSS API, which needs no key
and makes static fonts even of variable families (KOReader's crengine
handles variable fonts poorly). Fetched in a child process with a deadline.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Fonts = {}

local EXTS = { ttf = true, otf = true, ttc = true }
local MAX_FONT = 40 * 1024 * 1024

-- ------------------------------------------------------------------ where

--- The folders KOReader reads the user's fonts from (the first is where new ones go).
function Fonts.addedDirs()
    local out = {}
    for dir in (os.getenv("EXT_FONT_DIR") or ""):gmatch("[^;]+") do table.insert(out, dir) end
    if #out == 0 and Device.hasSystemFonts and Device:hasSystemFonts() then
        local ok, path = pcall(function() return require("ui/elements/font_settings"):getPath() end)
        -- Only the user's own folder (the first); system folders aren't ours to change.
        local user = ok and path and path:match("^[^;]+")
        if user then table.insert(out, user) end
    end
    table.insert(out, lfs.currentdir() .. "/fonts/added")
    return out
end

--- Whether a file can be made in `dir` (made first if missing). A Kindle's own font
-- folder is read-only, and EXT_FONT_DIR may list it before the user's.
local canWrite = {}
local function writable(dir)
    if canWrite[dir] ~= nil then return canWrite[dir] end
    util.makePath(dir)
    local probe = dir .. "/.write-test"
    local f = io.open(probe, "wb")
    if f then
        f:close()
        os.remove(probe)
    end
    canWrite[dir] = f ~= nil
    return canWrite[dir]
end

--- Where new fonts go: the first of addedDirs() that takes a file.
function Fonts.writeDir()
    local dirs = Fonts.addedDirs()
    for __, d in ipairs(dirs) do
        if writable(d) then return d end
    end
    return dirs[#dirs]
end

local function realpath(p)
    local ok, r = pcall(ffiutil.realpath, p)
    return ok and r or p
end

local function inDir(path, dir)
    dir = realpath(dir)
    path = realpath(path)
    return dir and path and path:sub(1, #dir + 1) == dir .. "/"
end

local function isAdded(path)
    -- (Not in a read-only folder, such as the Kindle's own fonts: those can't be removed.)
    for __, d in ipairs(Fonts.addedDirs()) do
        if inDir(path, d) and writable(d) then return true end
    end
    return false
end

local function trashDir() return DataStorage:getDataDir() .. "/cache/fonts-removed" end

-- ------------------------------------------------------------------ the list

local function scan()
    local FontList = require("fontlist")
    -- Again from the folders, so fonts added since KOReader started are listed too.
    FontList.fontlist = {}
    local ok = pcall(FontList.getFontList, FontList)
    if not ok then return {} end
    return FontList.fontlist, FontList.fontinfo
end

local function styleOf(face)
    if face.bold and face.italic then return "Bold Italic" end
    if face.bold then return "Bold" end
    if face.italic then return "Italic" end
    return "Regular"
end

local ORDER = { Regular = 1, Italic = 2, Bold = 3, ["Bold Italic"] = 4 }

--- { families = { { name, added, default, faces = { { id, style, file, added } } } }, dir, default }
function Fonts.list()
    local paths, info = scan()
    Fonts.byId = {}
    local families, byName = {}, {}
    for __, path in ipairs(paths or {}) do
        for __, face in ipairs((info or {})[path] or {}) do
            local name = face.name or path:match("([^/]+)%.%w+$")
            local fam = byName[name]
            if not fam then
                fam = { name = name, faces = {}, added = false }
                byName[name] = fam
                table.insert(families, fam)
            end
            local id = #Fonts.byId + 1
            Fonts.byId[id] = path
            local added = isAdded(path)
            if added then fam.added = true end
            table.insert(fam.faces, { id = id, style = styleOf(face), file = path:match("[^/]+$"), added = added,
                mono = face.mono or nil, index = face.index, size = lfs.attributes(path, "size") })
        end
    end
    local default = G_reader_settings:readSetting("cre_font") or require("document/credocument").default_font
    for __, fam in ipairs(families) do
        table.sort(fam.faces, function(a, b) return (ORDER[a.style] or 9) < (ORDER[b.style] or 9) end)
        fam.default = fam.name == default or nil
    end
    table.sort(families, function(a, b) return a.name:lower() < b.name:lower() end)
    -- KOReader's font settings (the launcher's appskosettings.lua).
    local okS, S = pcall(require, "appskosettings")
    local settings = okS and S.fontItems and S.fontItems() or nil
    return { families = families, dir = Fonts.writeDir(), default = default, settings = settings }
end

-- ------------------------------------------------------------------ adding

--- Is this file a font (TrueType, OpenType, a collection)? By its first bytes.
local function looksLikeFont(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(4) or ""
    f:close()
    return head == "\0\1\0\0" or head == "OTTO" or head == "true" or head == "ttcf"
end

local function safeName(name)
    name = tostring(name or ""):gsub("[/\\%z]", "_"):match("^%s*(.-)%s*$")
    if name == "" or name:sub(1, 1) == "." then return nil end
    local ext = (name:match("%.(%w+)$") or ""):lower()
    if not EXTS[ext] then return nil end
    return name
end

--- A file just written to `tmp`: put in place as `name` (a font), or each
-- font inside it (a zip). Returns the names added, or nil, why.
function Fonts.install(tmp, name)
    local dir = Fonts.writeDir()
    util.makePath(dir)
    local added = {}
    if (name:match("%.(%w+)$") or ""):lower() == "zip" then
        local Archiver = require("ffi/archiver")
        local r = Archiver.Reader:new()
        if not r:open(tmp) then os.remove(tmp) return nil, "That isn't a zip file." end
        local entries = {}
        for entry in r:iterate() do
            if entry.mode == "file" then table.insert(entries, entry.path) end
        end
        for __, p in ipairs(entries) do
            -- Fonts only, by their own name (a zip's folders aren't kept; macOS's extra files are skipped).
            local base = safeName(p:match("[^/]+$"))
            if base and not p:find("__MACOSX", 1, true) then
                local data = r:extractToMemory(p)
                if data and #data <= MAX_FONT then
                    local part = dir .. "/." .. base .. ".part"
                    local f = io.open(part, "wb")
                    if f then
                        f:write(data)
                        f:close()
                        if looksLikeFont(part) then
                            os.remove(dir .. "/" .. base)
                            os.rename(part, dir .. "/" .. base)
                            table.insert(added, base)
                        else
                            os.remove(part)
                        end
                    end
                end
            end
        end
        r:close()
        os.remove(tmp)
        if #added == 0 then return nil, "There were no fonts (TTF or OTF) in that zip." end
        return added
    end
    local clean = safeName(name)
    if not clean then os.remove(tmp) return nil, "Only font files (TTF, OTF or TTC) or a zip of them." end
    if not looksLikeFont(tmp) then os.remove(tmp) return nil, clean .. " isn't a font file." end
    os.remove(dir .. "/" .. clean)
    local ok = os.rename(tmp, dir .. "/" .. clean)
    if not ok then os.remove(tmp) return nil, "Couldn't save it in " .. dir end
    return { clean }
end

-- ------------------------------------------------------------------ taking out

local removed = {}   -- token -> { from, to }

--- Takes an added font out (kept aside, so Undo can put it back). Returns a token, or nil, why.
function Fonts.remove(id)
    local path = Fonts.byId and Fonts.byId[tonumber(id)]
    if not path then return nil, "No such font" end
    if not isAdded(path) then return nil, "Built-in fonts can't be removed." end
    util.makePath(trashDir())
    local to = trashDir() .. "/" .. os.time() .. "-" .. path:match("[^/]+$")
    if not os.rename(path, to) then return nil, "Couldn't remove it" end
    local token = tostring(os.time()) .. tostring(math.random(1000, 9999))
    removed[token] = { from = path, to = to }
    return token
end

function Fonts.undo(token)
    local r = removed[token]
    if not r then return nil, "Too late to undo" end
    removed[token] = nil
    if not os.rename(r.to, r.from) then return nil, "Couldn't put it back" end
    return true
end

--- Fonts taken out a while ago are gone for good (once per start).
function Fonts.emptyTrash()
    if lfs.attributes(trashDir(), "mode") ~= "directory" then return end
    for f in lfs.dir(trashDir()) do
        if f ~= "." and f ~= ".." then os.remove(trashDir() .. "/" .. f) end
    end
end

-- ------------------------------------------------------------------ default

function Fonts.setDefault(family)
    if type(family) ~= "string" or family == "" then return nil, "No font" end
    -- The same setting as Common settings' Font for new books (the launcher's appskosettings.lua).
    local ok, S = pcall(require, "appskosettings")
    if ok then S.set("font", family) else
        G_reader_settings:saveSetting("cre_font", family)
        G_reader_settings:flush()
    end
    return true
end

-- ------------------------------------------------------------------ Google Fonts

local google = nil   -- { status = "getting" | "done" | "failed", family, message, files }

--- The Google Fonts download under way or last done (nil: none yet).
function Fonts.googleState() return google end

-- In the child: Google's CSS for the family (its TTF links), then each file into `dir`.
local function fetchFamily(family, dir)
    local socketutil = require("socketutil")
    local http = require("ssl.https")
    local ltn12 = require("ltn12")
    local function get(url, sink)
        socketutil:set_timeout(20, 120)
        local ok, __, code = pcall(http.request, { url = url, method = "GET", sink = sink,
            -- An old browser's name: Google then sends TrueType (not WOFF2), which KOReader reads.
            headers = { ["User-Agent"] = "Wget/1.21" } })
        socketutil:reset_timeout()
        if not ok then error("Couldn't reach Google Fonts: " .. tostring(code)) end
        return code
    end
    local q = family:gsub(" ", "+")
    local css
    -- With italics, then without, then the regular weight alone.
    for __, axes in ipairs({ ":ital,wght@0,400;0,700;1,400;1,700", ":wght@400;700", "" }) do
        local t = {}
        local code = get("https://fonts.googleapis.com/css2?family=" .. q .. axes, ltn12.sink.table(t))
        if code == 200 then css = table.concat(t) break end
    end
    if not css then error("Google Fonts has no family called “" .. family .. "”. Check the name on fonts.google.com.") end
    local real = css:match("font%-family:%s*'([^']+)'") or family
    local files = {}
    for block in css:gmatch("@font%-face%s*(%b{})") do
        local url = block:match("url%((https://[^)]+%.ttf)%)")
        local style = block:match("font%-style:%s*(%a+)") or "normal"
        local weight = tonumber(block:match("font%-weight:%s*(%d+)")) or 400
        if url then
            local label = (weight >= 600 and "Bold" or "Regular")
            if style == "italic" then label = weight >= 600 and "BoldItalic" or "Italic" end
            local name = real:gsub("[^%w]", "") .. "-" .. label .. ".ttf"
            local part = dir .. "/." .. name .. ".part"
            local f = assert(io.open(part, "wb"))
            local code = get(url, ltn12.sink.file(f))
            if code == 200 and looksLikeFont(part) then
                os.remove(dir .. "/" .. name)
                os.rename(part, dir .. "/" .. name)
                table.insert(files, name)
            else
                os.remove(part)
            end
        end
    end
    if #files == 0 then error("Google Fonts sent no TrueType files for “" .. real .. "”.") end
    return real, files
end

--- Starts fetching a family; done(state) when it's over. Returns nil, or why not.
function Fonts.google(family, done)
    family = tostring(family or ""):match("^%s*(.-)%s*$")
    if family == "" or #family > 60 or family:find("[^%w %-]") then return "Type a family name, such as Lora or Source Serif 4." end
    if google and google.status == "getting" then return "Already getting " .. google.family end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isConnected() == false then return "The Kindle isn't on Wi-Fi." end
    local dir = Fonts.writeDir()
    util.makePath(dir)
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, real, files = pcall(fetchFamily, family, dir)
        local out = ok and ("K" .. require("json").encode({ family = real, files = files })) or ("E" .. tostring(real))
        ffiutil.writeToFD(write_fd, out, true)
    end, true)
    if not pid then return tostring(fd) end
    google = { status = "getting", family = family }
    local state = google
    local deadline = os.time() + 5 * 60
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(1, check) end
            ffiutil.terminateSubProcess(pid)
            state.status, state.message = "failed", "It took too long. Try again when Wi-Fi is better."
        else
            local out = (size and size > 0) and ffiutil.readAllFromFD(fd) or "EIt stopped"
            if out:sub(1, 1) == "K" then
                local okj, r = pcall(require("json").decode, out:sub(2))
                state.status = "done"
                state.family = okj and r.family or family
                state.files = okj and r.files or {}
            else
                state.status, state.message = "failed", (out:sub(2):gsub("^.-:%d+: ", ""))
            end
        end
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
        end
        if done then done(state) end
    end
    UIManager:scheduleIn(1, check)
end

return Fonts
