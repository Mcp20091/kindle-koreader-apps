--[[--
Plain Lua pieces (no KOReader modules, so the tests can load them): article
names in file names and links, the recent list, Wikipedia's daily feed boiled
down to what the front page shows, and small labels.
]]

local M = {}

--- The key an article is known by: "en:Nixon in China".
function M.key(lang, title)
    return (lang or ""):lower() .. ":" .. (title or "")
end

--- "Nixon in China.EN.epub" -> "Nixon in China", "en" (KOReader's own Wikipedia EPUB names).
function M.fileTitle(name)
    local title, lang = tostring(name or ""):match("^(.+)%.([%a][%a%-]*)%.epub$")
    if not title or lang ~= lang:upper() then return nil end
    return title, lang:lower()
end

function M.urlDecode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Pages that are not articles (Wikipedia's namespaces, in English and as Wikipedia writes them in links).
local NOT_ARTICLES = { "File", "Image", "Special", "Help", "Category", "Template", "Wikipedia", "Portal", "Talk",
    "User", "Draft", "Module", "MediaWiki", "Book", "TimedText" }

--- A link to a Wikipedia article: its language and title (nil for anything else,
-- or for a page that is not an article). "https://en.wikipedia.org/wiki/Nixon_in_China#Music"
function M.fromUrl(url)
    url = tostring(url or "")
    local lang, page = url:match("^https?://([%w%-]+)%.m%.wikipedia%.org/wiki/([^#?]+)")
    if not lang then lang, page = url:match("^https?://([%w%-]+)%.wikipedia%.org/wiki/([^#?]+)") end
    if not lang or lang == "www" or lang == "commons" or lang == "meta" then return nil end
    local title = M.urlDecode(page):gsub("_", " ")
    local ns = title:match("^([%a ]+):%S")
    if ns then
        for __, n in ipairs(NOT_ARTICLES) do
            if ns == n or ns == n .. " talk" then return nil end
        end
    end
    return lang:lower(), title
end

--- The recent list with `entry` ({ title, lang, time }) first, without its earlier
-- visit, and at most `keep` long.
function M.addRecent(list, entry, keep)
    local out = { entry }
    local k = M.key(entry.lang, entry.title)
    for __, e in ipairs(list or {}) do
        if #out >= (keep or 100) then break end
        if M.key(e.lang, e.title) ~= k then table.insert(out, e) end
    end
    return out
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", ndash = "–", mdash = "—" }

--- HTML to plain text: tags and comments out, the usual entities decoded, spaces tidied.
function M.stripHtml(s)
    s = tostring(s or ""):gsub("<!%-%-.-%-%->", ""):gsub("<[^>]*>", "")
    s = s:gsub("&#(%d+);", function(n)
        n = tonumber(n)
        if n < 128 then return string.char(n) end
        return M.utf8(n)
    end)
    s = s:gsub("&(%a+);", function(e) return ENTITIES[e] or ("&" .. e .. ";") end)
    s = s:gsub("\194\160", " "):gsub("%s+", " ")
    return (s:gsub("^ ", ""):gsub(" $", ""))
end

function M.utf8(n)
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64) end
    if n < 0x10000 then
        return string.char(0xE0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
    end
    return string.char(0xF0 + math.floor(n / 262144), 0x80 + math.floor(n / 4096) % 64,
        0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
end

local function page(p)
    if type(p) ~= "table" then return nil end
    local title = (type(p.titles) == "table" and p.titles.normalized) or p.normalizedtitle or p.title
    if type(title) ~= "string" then return nil end
    title = title:gsub("_", " ")
    return { title = title, description = type(p.description) == "string" and p.description or nil,
        extract = type(p.extract) == "string" and p.extract or nil, views = tonumber(p.views) }
end

local function pages(list, max)
    local out = {}
    for __, p in ipairs(type(list) == "table" and list or {}) do
        local got = page(p)
        if got then table.insert(out, got) end
        if max and #out >= max then break end
    end
    return out
end

--- Wikipedia's featured feed for a day, as the front page uses it:
-- { featured = page, onthisday = { { year, text, pages } }, news = { { text, pages } }, mostread = { page } }.
function M.parseFeed(feed)
    feed = type(feed) == "table" and feed or {}
    local out = { featured = page(feed.tfa), onthisday = {}, news = {}, mostread = {} }
    for __, e in ipairs(type(feed.onthisday) == "table" and feed.onthisday or {}) do
        if type(e.text) == "string" then
            table.insert(out.onthisday, { year = tonumber(e.year), text = M.stripHtml(e.text), pages = pages(e.pages) })
        end
    end
    for __, n in ipairs(type(feed.news) == "table" and feed.news or {}) do
        if type(n.story) == "string" then
            table.insert(out.news, { text = M.stripHtml(n.story), pages = pages(n.links) })
        end
    end
    local mr = type(feed.mostread) == "table" and feed.mostread.articles or nil
    for __, p in ipairs(pages(mr, 20)) do
        -- (the Main Page and Special:Search are in the list too)
        if not p.title:find(":") and p.title ~= "Main Page" then table.insert(out.mostread, p) end
    end
    return out
end

--- "Today", "Yesterday", or the date ("Oct 12").
function M.dayLabel(t, now)
    now = now or os.time()
    local d, n = os.date("*t", t), os.date("*t", now)
    local function day(x) return os.time{ year = x.year, month = x.month, day = x.day, hour = 12 } end
    local diff = math.floor((day(n) - day(d)) / 86400 + 0.5)
    if diff == 0 then return "Today" end
    if diff == 1 then return "Yesterday" end
    return (os.date("%b %d", t):gsub(" 0", " "))
end

--- "1.2 MB", "640 KB".
function M.sizeLabel(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / 1024 / 1024) end
    return string.format("%d KB", math.max(1, math.floor(bytes / 1024 + 0.5)))
end

--- The Wikipedias the language list offers first: code, name in its own language.
M.LANGUAGES = {
    { "en", "English" }, { "de", "Deutsch" }, { "es", "Español" }, { "fr", "Français" }, { "it", "Italiano" },
    { "nl", "Nederlands" }, { "pt", "Português" }, { "sv", "Svenska" }, { "pl", "Polski" }, { "ru", "Русский" },
    { "uk", "Українська" }, { "ja", "日本語" }, { "zh", "中文" }, { "ar", "العربية" }, { "ca", "Català" },
    { "cs", "Čeština" }, { "da", "Dansk" }, { "el", "Ελληνικά" }, { "fi", "Suomi" }, { "he", "עברית" },
    { "hu", "Magyar" }, { "id", "Bahasa Indonesia" }, { "ko", "한국어" }, { "no", "Norsk bokmål" },
    { "ro", "Română" }, { "tr", "Türkçe" }, { "vi", "Tiếng Việt" }, { "simple", "Simple English" },
}

function M.languageName(code)
    for __, l in ipairs(M.LANGUAGES) do
        if l[1] == code then return l[2] end
    end
    return code
end

return M
