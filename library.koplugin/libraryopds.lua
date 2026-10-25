--[[--
OPDS catalogs (Standard Ebooks, Project Gutenberg, a Calibre server…) as
places to find books and download them.

The catalogs are KOReader's OPDS list (settings/opds.lua, servers: { title,
url, username, password }), so one added here shows in KOReader's OPDS catalog
and the other way round. Fetching and reading the feeds is KOReader's own OPDS
browser code (opds.koplugin's opdsbrowser and opdsparser: OPDS 1 and 2,
OpenSearch, Calibre's search); the network runs in a child process
(libraryonline's O.run).

Plain helpers first (tests/run.lua), then what needs KOReader.
]]

local C = {}

--- The catalogs every list has (added once when missing; they can be deleted).
C.SUGGESTED = {
    { title = "Standard Ebooks", url = "https://standardebooks.org/feeds/opds", about = "Beautifully formatted public domain books" },
    { title = "Project Gutenberg", url = "https://m.gutenberg.org/ebooks.opds/", about = "70,000+ public domain titles" },
    { title = "Feedbooks", url = "https://catalog.feedbooks.com/catalog/index.atom", about = "Public domain and original ebooks" },
    { title = "ManyBooks", url = "https://manybooks.net/opds/index.php", about = "50,000+ free titles" },
    { title = "Internet Archive", url = "https://bookserver.archive.org/catalog/", about = "Massive digital library" },
    { title = "OAPEN", url = "https://library.oapen.org/opds", about = "Open access academic books" },
}

-- The formats a book is downloaded in, best first.
C.FORMATS = { "epub", "kepub", "azw3", "mobi", "fb2", "pdf", "cbz", "djvu", "txt", "html" }

local function trim(s) return type(s) == "string" and (s:match("^%s*(.-)%s*$")) or "" end

--- A catalog's host without "www." or "m.": "gutenberg.org".
function C.host(url)
    local h = trim(url):lower():match("^%a[%w+.-]*://([^/:?#]+)") or trim(url):lower():match("^([^/:?#]+)")
    if not h then return "" end
    return (h:gsub("^www%.", ""):gsub("^m%.", ""))
end

--- Whether `list` has a catalog on the same host as `url`.
function C.has(list, url)
    local h = C.host(url)
    for __, c in ipairs(list or {}) do
        if C.host(c.url) == h then return true end
    end
    return false
end

--- The suggested catalogs `list` doesn't have.
function C.missing(list)
    local out = {}
    for __, s in ipairs(C.SUGGESTED) do
        if not C.has(list, s.url) then table.insert(out, s) end
    end
    return out
end

--- What a catalog's address is saved as: https:// added when there's no scheme.
function C.normalize(url)
    url = trim(url)
    if url == "" then return "" end
    if not url:match("^%a[%w+.-]*://") then url = "https://" .. url end
    return url
end

--- A catalog's second line: its host, or what it is.
function C.label(c)
    for __, s in ipairs(C.SUGGESTED) do
        if C.host(s.url) == C.host(c.url) and s.about then return s.about end
    end
    return C.host(c.url)
end

--- The formats on offer, best first: { { ext, href, type } }. `extOf(link)`
-- gives a link's extension KOReader can open (nil: it can't).
function C.formats(acquisitions, extOf)
    local rank = {}
    for i, f in ipairs(C.FORMATS) do rank[f] = i end
    local out, seen = {}, {}
    for __, a in ipairs(acquisitions or {}) do
        if a.href and a.type ~= "borrow" then
            local ext = extOf(a)
            if ext then
                ext = ext:lower()
                -- (Standard Ebooks and Gutenberg offer EPUB twice: keep the first of each)
                local key = ext .. "|" .. (a.title or "")
                if not seen[key] then
                    seen[key] = true
                    table.insert(out, { ext = ext, href = a.href, type = a.type, title = a.title })
                end
            end
        end
    end
    table.sort(out, function(x, y)
        local rx, ry = rank[x.ext] or 99, rank[y.ext] or 99
        if rx ~= ry then return rx < ry end
        return false
    end)
    return out
end

--- A file name for a downloaded book: "Title - Author.epub", without / and the like.
function C.fileName(title, author, ext)
    local name = trim(title)
    if name == "" then name = "Book" end
    author = trim(author)
    if author ~= "" and author ~= "Unknown Author" then name = name .. " - " .. author end
    name = name:gsub('[/\\:*?"<>|%c]', "_"):gsub("%s+", " ")
    if #name > 120 then name = name:sub(1, 120):gsub("[\128-\191]+$", ""):gsub("[\192-\255]$", "") end
    return name .. "." .. ext
end

--- A feed's text (a description: may be HTML) as plain text.
function C.plain(s)
    if type(s) == "table" then s = s.div or s[1] or "" end
    if type(s) ~= "string" then return nil end
    s = s:gsub("<br%s*/?>", "\n"):gsub("</p>", "\n\n"):gsub("<[^>]+>", "")
    s = s:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&")
    s = s:gsub("[ \t]+", " "):gsub("\n[ \t]+", "\n"):gsub("\n\n\n+", "\n\n")
    s = trim(s)
    return s ~= "" and s or nil
end

-- ------------------------------------------------------------------ KOReader's OPDS list

local function plugin()
    for __, m in ipairs({ "apps/filemanager/filemanager", "apps/reader/readerui" }) do
        local mod = package.loaded[m]
        local ui = mod and mod.instance
        if ui and ui.opds and ui.opds.loadSettings then return ui.opds end
    end
end

local function store()
    local p = plugin()
    if p then
        pcall(p.loadSettings, p)
        if p.settings then return p.settings, p end
    end
    return require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/opds.lua"), nil
end

local function write(list)
    local settings, p = store()
    settings:saveSetting("servers", list)
    if p then
        p.servers = list
        p.updated = true
    end
    settings:flush()
end

--- The catalogs, each with its place in KOReader's list (`index`). The
-- suggested ones are added the first time (KOReader's own defaults stay).
function C.catalogs()
    local settings, p = store()
    local list = settings:readSetting("servers")
    local fresh = list == nil
    if fresh then
        list = {}
        for __, c in ipairs(p and p.default_servers or {}) do
            local copy = {}
            for k, v in pairs(c) do copy[k] = v end
            table.insert(list, copy)
        end
    end
    local S = require("librarysettings")
    if fresh or not S.get("opds_added") then
        for __, s in ipairs(C.missing(list)) do table.insert(list, { title = s.title, url = s.url }) end
        write(list)
        S.set("opds_added", true)
    end
    local out = {}
    for i, c in ipairs(list) do
        local copy = {}
        for k, v in pairs(c) do copy[k] = v end
        copy.index = i
        table.insert(out, copy)
    end
    return out
end

local function raw() return store():readSetting("servers") or {} end

function C.save(c)
    local list = raw()
    local entry = { title = c.title, url = c.url, username = c.username ~= "" and c.username or nil,
        password = c.password ~= "" and c.password or nil }
    if c.index and list[c.index] then
        for k, v in pairs(list[c.index]) do
            if entry[k] == nil and k ~= "username" and k ~= "password" then entry[k] = v end
        end
        list[c.index] = entry
    else
        table.insert(list, entry)
        c.index = #list
    end
    write(list)
    return c.index
end

function C.remove(index)
    local list = raw()
    local gone = table.remove(list, index)
    write(list)
    return gone
end

function C.restore(c, index)
    local list = raw()
    table.insert(list, math.min(index, #list + 1), c)
    write(list)
end

-- ------------------------------------------------------------------ KOReader's OPDS browser code

local function browserClass()
    local ok, B = pcall(require, "opdsbrowser")
    if ok then return B end
    local lfs = require("libs/libkoreader-lfs")
    for __, d in ipairs({ "plugins/opds.koplugin", require("datastorage"):getDataDir() .. "/plugins/opds.koplugin" }) do
        if lfs.attributes(d .. "/opdsbrowser.lua", "mode") == "file" then
            package.path = d .. "/?.lua;" .. package.path
            ok, B = pcall(require, "opdsbrowser")
            if ok then return B end
        end
    end
end

function C.available() return browserClass() ~= nil end

-- (in the child process: KOReader's messages there would go nowhere)
local function quiet()
    local UIManager = require("ui/uimanager")
    UIManager.show = function() end
end

local function browser(c)
    local B = browserClass()
    if not B then return nil end
    return setmetatable({ root_catalog_username = c.username, root_catalog_password = c.password }, { __index = B })
end

--- A catalog page: { entries = { { title, author, about, url (a page) | formats } }, next, search }, or nil.
function C.page(c, url)
    quiet()
    local b = browser(c)
    if not b then return nil end
    local ok, items = pcall(b.genItemTableFromURL, b, url)
    if not ok or type(items) ~= "table" then return nil end
    local extOf = b.getFiletype
    local out = { entries = {}, next = items.hrefs and items.hrefs.next, search = b.search_url }
    for __, it in ipairs(items) do
        local e = { title = it.title or it.text, author = it.author, about = C.plain(it.content) }
        if it.acquisitions and #it.acquisitions > 0 then
            e.formats = C.formats(it.acquisitions, function(a)
                local okExt, ext = pcall(extOf, a)
                return okExt and ext or nil
            end)
        end
        if e.formats and #e.formats > 0 then
            table.insert(out.entries, e)
        elseif it.url then
            e.url = it.url
            table.insert(out.entries, e)
        end
    end
    -- (an empty page that came back at all is still an answer)
    return out
end

--- Downloads a format's href to `dest`; true, or nil.
function C.download(c, href, dest)
    quiet()
    local b = browser(c)
    if not b then return nil end
    local ok, done = pcall(b.downloadFile, b, dest, href, c.username, c.password)
    return ok and done == true or nil
end

--- A search's address from the catalog's template ("…%s…") and the words.
function C.searchUrl(template, words)
    local enc = require("util").urlEncode(words)
    return (template:gsub("%%s", function() return enc end))
end

return C
