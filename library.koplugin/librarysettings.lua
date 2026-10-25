--[[--
The Library's settings, in KOReader's settings folder (library.lua):

  view       "covers" or "list" (how books show)
  sort       { [page] = "read" | "added" | "title" | "author" | "progress" | "name" | "size" }
  group      { [page] = "none" | "author" | "series" | "status" | "format" | "language" | "folder" }
  hidden     true: hidden files and folders show in Folders
  browser    "library" (default) or "koreader": which one Back from a book and the launcher's Library open
  start      "home" (default) or "last": where the Library opens
  last       { tab, folder }: where it was left
]]

local S = {}

local store

local function open()
    if store then return store end
    local DataStorage = require("datastorage")
    store = require("luasettings"):open(DataStorage:getSettingsDir() .. "/library.lua")
    return store
end

function S.get(key, default)
    local v = open():readSetting(key)
    if v == nil then return default end
    return v
end

function S.set(key, value)
    local s = open()
    if value == nil then s:delSetting(key) else s:saveSetting(key, value) end
    s:flush()
end

--- A per-page value (sort, group): t[page] or the default.
function S.of(key, page, default)
    local t = S.get(key)
    local v = type(t) == "table" and t[page] or nil
    if v == nil then return default end
    return v
end

function S.setOf(key, page, value)
    local t = S.get(key)
    if type(t) ~= "table" then t = {} end
    t[page] = value
    S.set(key, t)
end

--- Whether the Library is where books are browsed (not KOReader's file browser).
function S.isBrowser() return S.get("browser", "library") ~= "koreader" end

return S
