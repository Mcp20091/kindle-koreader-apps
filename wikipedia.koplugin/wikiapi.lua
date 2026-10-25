--[[--
Wikipedia over the network: search, an article's summary and its other
languages, a random article, and the day's featured feed (featured article,
On this day, In the news, Most read). Everything returns nil and a short
reason when Wikipedia can't be reached.
]]

local JSON = require("json")
local logger = require("logger")

local M = require("wikimodel")

local API = {}

local AGENT = "KOReader-Wikipedia/1.0 (Kindle; KOReader plugin)"

function API.base(lang)
    return "https://" .. lang .. ".wikipedia.org"
end

local function escape(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function query(params)
    local parts = {}
    for k, v in pairs(params) do table.insert(parts, k .. "=" .. escape(v)) end
    table.sort(parts)
    return table.concat(parts, "&")
end

--- GET a URL: the body, or nil and why not.
function API.get(url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    socketutil:set_timeout(10, 30)
    local code, __, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
        headers = { ["User-Agent"] = AGENT, ["Api-User-Agent"] = AGENT },
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.warn("Wikipedia:", url, code, status)
        return nil, tostring(status or code or "no answer")
    end
    return table.concat(sink)
end

function API.json(url)
    local body, err = API.get(url)
    if not body then return nil, err end
    local ok, t = pcall(JSON.decode, body)
    if not ok or type(t) ~= "table" then return nil, "bad answer" end
    return t
end

local function action(lang, params)
    params.format, params.formatversion = "json", "2"
    return API.json(API.base(lang) .. "/w/api.php?" .. query(params))
end

local function pageOf(t)
    local pages = type(t) == "table" and type(t.query) == "table" and t.query.pages
    return type(pages) == "table" and pages[1] or nil
end

--- Articles matching `text`: { { title, description } }.
function API.search(lang, text)
    local t, err = action(lang, {
        action = "query", generator = "search", gsrsearch = text, gsrnamespace = "0", gsrlimit = "30",
        prop = "description|extracts", exintro = "1", explaintext = "1", exsentences = "1", exlimit = "max",
        redirects = "1",
    })
    if not t then return nil, err end
    local pages = type(t.query) == "table" and t.query.pages or {}
    table.sort(pages, function(a, b) return (a.index or 0) < (b.index or 0) end)
    local out = {}
    for __, p in ipairs(pages) do
        if type(p.title) == "string" then
            local d = p.description
            if type(d) ~= "string" or d == "" then d = type(p.extract) == "string" and p.extract or nil end
            table.insert(out, { title = p.title, description = d })
        end
    end
    return out
end

--- An article's real title (redirects followed), description and opening paragraphs.
-- Returns false when there is no such article.
function API.summary(lang, title)
    local t, err = action(lang, {
        action = "query", titles = title, redirects = "1",
        prop = "description|extracts", exintro = "1", explaintext = "1",
    })
    if not t then return nil, err end
    local p = pageOf(t)
    if not p or p.missing or p.invalid or type(p.title) ~= "string" then return false end
    return { title = p.title, description = type(p.description) == "string" and p.description or nil,
        extract = type(p.extract) == "string" and p.extract or "" }
end

--- A random article's title.
function API.random(lang)
    local t, err = action(lang, { action = "query", list = "random", rnnamespace = "0", rnlimit = "1" })
    if not t then return nil, err end
    local r = type(t.query) == "table" and t.query.random
    return type(r) == "table" and r[1] and r[1].title or nil, "no article"
end

--- The article in other languages: { { lang, title, name } }, by language name.
function API.languages(lang, title)
    local t, err = action(lang, {
        action = "query", titles = title, redirects = "1", prop = "langlinks", lllimit = "500", llprop = "autonym",
    })
    if not t then return nil, err end
    local p = pageOf(t)
    local out = {}
    for __, l in ipairs(p and p.langlinks or {}) do
        if type(l.lang) == "string" and type(l.title) == "string" then
            table.insert(out, { lang = l.lang, title = l.title, name = type(l.autonym) == "string" and l.autonym or l.lang })
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

--- The featured feed for the day of `time` (parsed: see wikimodel.parseFeed).
function API.featured(lang, time)
    local t, err = API.json(API.base(lang) .. "/api/rest_v1/feed/featured/" .. os.date("%Y/%m/%d", time or os.time()))
    if not t then return nil, err end
    return M.parseFeed(t)
end

return API
