--[[--
What Wikipedia keeps on the Kindle: its settings, the recent articles, today's
front page (so it shows again without Wi-Fi the same day), and the articles
themselves. Saved articles are EPUBs in the Wikipedia folder, named as
KOReader names its own ("Nixon in China.EN.epub"), so they show in the
Library and KOReader's own Wikipedia links find them. Articles read without
saving are kept a while in a cache folder (for Back and Recent).
]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local LuaSettings = require("luasettings")
local ffiutil = require("ffi/util")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local M = require("wikimodel")

local Store = {}
Store.__index = Store

Store.DEFAULTS = {
    lang = "en",
    images = false,
    toolbar = "left",          -- "left" or "top"
    toolbar_hidden = false,
    link_tap = "preview",      -- "preview" or "open"
    keep_recent = 100,
    in_history = true,         -- the articles in KOReader's history (the recent books)
    saved_sort = "newest",     -- or "title"
    sections = { featured = true, onthisday = true, news = false, mostread = false },
}

local CACHE_KEEP = 20
-- Saved articles removed with Undo: put aside beside themselves ("….removed")
-- for a few seconds, then gone (path → true while they wait).
local aside = {}

local shared

--- The one store (the plugin is made again for every book and the library).
function Store.get()
    if not shared then
        shared = setmetatable({}, Store)
        shared.path = DataStorage:getSettingsDir() .. "/wikipedia.lua"
        shared.file = LuaSettings:open(shared.path)
        shared.mtime = lfs.attributes(shared.path, "modification")
    end
    return shared
end

function Store:read(key)
    local v = self.file:readSetting(key)
    if v == nil then
        v = Store.DEFAULTS[key]
        if type(v) == "table" then v = util.tableDeepCopy(v) end
    end
    return v
end

function Store:write(key, value)
    -- (put back from a backup meanwhile: read again first, so the copy in memory doesn't win)
    local m = lfs.attributes(self.path, "modification")
    if m and m ~= self.mtime then self.file = LuaSettings:open(self.path) end
    self.file:saveSetting(key, value)
    self.file:flush()
    self.mtime = lfs.attributes(self.path, "modification")
end

function Store:lang() return self:read("lang") end

-- ------------------------------------------------------------------ folders

function Store:folder()
    local f = self.file:readSetting("folder")
    if f then return f end
    local home = G_reader_settings:readSetting("home_dir")
    if not home then
        local ok, fmu = pcall(require, "apps/filemanager/filemanagerutil")
        home = ok and fmu.getDefaultDir and fmu.getDefaultDir() or DataStorage:getDataDir()
    end
    return (home:gsub("/$", "")) .. "/Wikipedia"
end

-- A folder as the file system has it: KOReader's own folder is "./" on a
-- Kindle, while its history and the launcher name books by their full path.
local function real(p)
    return p and ffiutil.realpath(p) or p
end

function Store:cacheDir()
    if not self.cache_dir then
        local dir = DataStorage:getDataDir() .. "/cache/wikipedia"
        util.makePath(dir)
        self.cache_dir = real(dir)
    end
    return self.cache_dir
end

--- A file name as KOReader's Save as EPUB makes it (and as its Wikipedia links look for it).
function Store:fileName(title, lang, dir)
    local name = util.getSafeFilename(title:gsub(" ", "_") .. "." .. lang:upper() .. ".epub", dir)
    return (name:gsub("_", " "))
end

function Store:savedPath(title, lang)
    local dir = self:folder()
    return dir .. "/" .. self:fileName(title, lang, dir)
end

function Store:cachePath(title, lang)
    local dir = self:cacheDir()
    return dir .. "/" .. self:fileName(title, lang, dir)
end

local function isFile(p) return p and lfs.attributes(p, "mode") == "file" end

function Store:findSaved(title, lang)
    local p = self:savedPath(title, lang)
    if isFile(p) then return p end
end

function Store:findCached(title, lang)
    local p = self:cachePath(title, lang)
    if isFile(p) then return p end
end

--- Where the article is on the Kindle (saved first), if anywhere.
function Store:find(title, lang)
    return self:findSaved(title, lang) or self:findCached(title, lang)
end

local function dirOf(path) return (path:match("^(.*)/[^/]*$")) end
local function baseOf(path) return (path:match("([^/]*)$")) end

--- An article file of ours (saved or cached): its title and language, and whether it is saved.
function Store:article(path)
    if not path or not path:match("%.epub$") then return nil end
    local dir = real(dirOf(path))
    local saved = dir == real(self:folder())
    if not saved and dir ~= self:cacheDir() then return nil end
    local meta = self:meta(path)
    local title, lang = M.fileTitle(baseOf(path))
    if not title then return nil end
    return { title = meta.title or title, lang = meta.lang or lang, description = meta.description,
        saved = saved, path = path }
end

-- What the file name can't hold (the exact title, the one-line description), by file name.
function Store:meta(path)
    local all = self.file:readSetting("meta") or {}
    return all[baseOf(path)] or {}
end

function Store:setMeta(path, info)
    self.saved_index = nil
    local all = self.file:readSetting("meta") or {}
    all[baseOf(path)] = { title = info.title, lang = info.lang, description = info.description, images = info.images }
    self:write("meta", all)
end

--- With Images on, a copy downloaded without them (or before this was noted).
function Store:needsImages(path)
    return self:read("images") == true and self:meta(path).images ~= true
end

-- ------------------------------------------------------------------ saved articles

--- The saved articles' titles and paths, kept in memory for the launcher's
-- search (read from the folder again after a save or a removal).
function Store:savedIndex()
    if not self.saved_index then
        local list = {}
        for __, a in ipairs(self:listSaved()) do
            table.insert(list, { title = a.title, lower = a.title:lower(), description = a.description, path = a.path })
        end
        self.saved_index = list
    end
    return self.saved_index
end

function Store:listSaved()
    local out = {}
    local dir = self:folder()
    if lfs.attributes(dir, "mode") ~= "directory" then return out end
    for name in lfs.dir(dir) do
        local was = name:match("^(.+%.epub)%.removed$")
        if was and not aside[dir .. "/" .. was] then
            -- (put aside when KOReader closed before it was gone)
            os.remove(dir .. "/" .. name)
            if lfs.attributes(dir .. "/" .. was, "mode") ~= "file" then self:remove(dir .. "/" .. was) end
        elseif name:match("%.epub$") then
            local path = dir .. "/" .. name
            local a = self:article(path)
            local attr = lfs.attributes(path)
            if a and attr and attr.mode == "file" then
                a.size, a.time = attr.size, attr.modification
                table.insert(out, a)
            end
        end
    end
    if self:read("saved_sort") == "title" then
        table.sort(out, function(a, b) return a.title:lower() < b.title:lower() end)
    else
        table.sort(out, function(a, b) return a.time > b.time end)
    end
    return out
end

function Store:savedSize(list)
    local n = 0
    for __, a in ipairs(list or self:listSaved()) do n = n + (a.size or 0) end
    return n
end

--- Copy a file (the EPUB, from the cache into the Wikipedia folder).
function Store:copy(from, to)
    util.makePath(dirOf(to))
    local src = io.open(from, "rb")
    if not src then return false end
    local data = src:read("*a")
    src:close()
    local tmp = to .. ".tmp"
    local dst = io.open(tmp, "wb")
    if not dst then return false end
    dst:write(data)
    dst:close()
    return os.rename(tmp, to) and true or false
end

--- Delete an article file and what KOReader keeps beside it (its page, highlights).
function Store:remove(path)
    self.saved_index = nil
    pcall(function() DocSettings:open(path):purge() end)
    local ok = os.remove(path)
    pcall(function() require("readhistory"):removeItemByPath(path) end)
    return ok and true or false
end

--- Removed, but Undo can put it back for a few seconds (Store:restore);
-- after that it's gone for good, with its page and highlights.
function Store:putAside(path)
    self.saved_index = nil
    if not os.rename(path, path .. ".removed") then return false end
    aside[path] = true
    UIManager:scheduleIn(8, function()
        if not aside[path] then return end
        aside[path] = nil
        os.remove(path .. ".removed")
        -- (saved again meanwhile: that one stays)
        if lfs.attributes(path, "mode") ~= "file" then self:remove(path) end
    end)
    return true
end

function Store:restore(path)
    if not aside[path] then return false end
    aside[path] = nil
    self.saved_index = nil
    return os.rename(path .. ".removed", path) and true or false
end

--- Keep the cache to the last few articles (never the one in `keep`).
function Store:trimCache(keep)
    local dir = self:cacheDir()
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local files = {}
    for name in lfs.dir(dir) do
        if name:match("%.epub$") then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then table.insert(files, { path = path, time = attr.access or attr.modification }) end
        end
    end
    table.sort(files, function(a, b) return a.time > b.time end)
    for i = CACHE_KEEP + 1, #files do
        if files[i].path ~= keep then self:remove(files[i].path) end
    end
end

-- ------------------------------------------------------------------ recent

function Store:recent()
    return self.file:readSetting("recent") or {}
end

function Store:addRecent(title, lang)
    local list = M.addRecent(self:recent(), { title = title, lang = lang, time = os.time() }, self:read("keep_recent"))
    self:write("recent", list)
end

function Store:removeRecent(title, lang)
    local out, k = {}, M.key(lang, title)
    for __, e in ipairs(self:recent()) do
        if M.key(e.lang, e.title) ~= k then table.insert(out, e) end
    end
    self:write("recent", out)
end

function Store:clearRecent()
    self:write("recent", {})
end

--- How far into an article on the Kindle you got: page, pages (nil if never opened).
function Store:progress(path)
    if not path or not isFile(path) or not DocSettings:hasSidecarFile(path) then return nil end
    local ok, ds = pcall(DocSettings.open, DocSettings, path)
    if not ok then return nil end
    local pages = ds:readSetting("doc_pages")
    local pct = ds:readSetting("percent_finished")
    if type(pages) ~= "number" or type(pct) ~= "number" then return nil end
    return math.max(1, math.min(pages, math.floor(pct * pages + 0.5))), pages
end

-- ------------------------------------------------------------------ reading settings

-- KOReader keeps the font, size, margins, spacing and zoom per book, and every
-- article is a new book: the last article's are carried to the next.
local STYLE_KEYS = { font_face = true, font_family_fonts = true, css = true, style_tweaks = true,
    hyphenation = true, hyph_force_algorithmic = true, hyph_soft_hyphens_only = true,
    hyph_trust_soft_hyphens = true, floating_punctuation = true }
local NOT_STYLE = { copt_rotation_mode = true }

function Store.isStyleKey(k)
    return STYLE_KEYS[k] or (k:match("^copt_") ~= nil and not NOT_STYLE[k])
end

--- An article's reading settings (from its KOReader settings), kept for the next ones.
function Store:keepStyle(doc_settings)
    local style = {}
    for k, v in pairs(doc_settings.data or {}) do
        if type(k) == "string" and Store.isStyleKey(k) then style[k] = v end
    end
    if next(style) then self:write("style", style) end
end

--- The kept reading settings into an article's KOReader settings (before the reader reads them).
function Store:giveStyle(doc_settings)
    for k, v in pairs(self.file:readSetting("style") or {}) do
        doc_settings:saveSetting(k, v)
    end
end

-- ------------------------------------------------------------------ today

--- Today's front page for `lang`, if it was fetched today.
function Store:today(lang)
    local t = self.file:readSetting("today")
    if type(t) == "table" and t.lang == lang and t.date == os.date("%Y-%m-%d") then return t.feed end
end

function Store:setToday(lang, feed)
    self:write("today", { lang = lang, date = os.date("%Y-%m-%d"), feed = feed })
end

return Store
