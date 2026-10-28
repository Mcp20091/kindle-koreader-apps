-- Plain tests for ndmodel and ndapi (no KOReader): luajit tests/run.lua
package.path = "./?.lua;" .. package.path

-- ndapi's JSON: answers by their text (the stand-in network below sends these keys).
local ANSWERS = {}
package.preload.json = function()
    return {
        encode = function(t)
            local keys = {}
            for k, v in pairs(t) do keys[#keys + 1] = k .. "=" .. tostring(v) end
            table.sort(keys)
            return "{" .. table.concat(keys, ",") .. "}"
        end,
        decode = function(s)
            if ANSWERS[s] == nil then error("not JSON") end
            return ANSWERS[s]
        end,
    }
end

local M = require("ndmodel")
local API = require("ndapi")

local passed, failed = 0, 0
local function eq(got, want, what)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- the key, requests and domains
eq(M.masked("abcdef"), "••••ef", "masked")
eq(M.masked(""), "", "masked: empty")
eq(M.query({ status = "blocked", from = 1700000000, search = "a b" }), "from=1700000000&search=a%20b&status=blocked", "query")
eq(M.cleanDomain(" Ads.Example.com "), "ads.example.com", "domain: trimmed, lower case")
eq(M.cleanDomain("https://ads.example.com/path?x=1"), "ads.example.com", "domain: from an address")
eq(M.cleanDomain("*.example.com"), "example.com", "domain: wildcard")
eq(M.cleanDomain("example.com:443"), "example.com", "domain: port")
eq(M.cleanDomain("example.com."), "example.com", "domain: trailing dot")
eq(M.cleanDomain("localhost"), nil, "domain: no dot")
eq(M.cleanDomain("bad domain.com"), nil, "domain: a space")
eq(M.cleanDomain("a..b.com"), nil, "domain: two dots")
eq(M.cleanDomain(""), nil, "domain: empty")

-- numbers and times
eq(M.number(12480), "12,480", "number")
eq(M.number(999), "999", "number: small")
eq(M.number(1234567), "1,234,567", "number: millions")
eq(M.percent(1872, 12480), "15%", "percent")
eq(M.percent(1, 1000), "<1%", "percent: a little")
eq(M.percent(0, 0), "0%", "percent: none")
eq(M.parseTime("1970-01-01T00:00:00Z"), 0, "time: epoch")
eq(M.parseTime("2026-10-27T14:35:12.345Z"), 1793111712, "time")
eq(M.parseTime("2026-10-27T16:35:12+02:00"), 1793111712, "time: with an offset")
eq(M.parseTime("yesterday"), nil, "time: not one")
local function fakeDate(f, t)
    return ({ ["%I:%M %p"] = "02:35 PM", ["%H:%M"] = "14:35", ["%b %d"] = "Oct 07",
        ["%Y-%m-%d"] = t == 1 and "2026-10-27" or "2026-10-26" })[f]
end
eq(M.clock(0, false, fakeDate), "2:35 PM", "clock 12-hour")
eq(M.clock(0, true, fakeDate), "14:35", "clock 24-hour")
eq(M.when(1, 1, true, fakeDate), "14:35", "when: today")
eq(M.when(2, 1, true, fakeDate), "Oct 7, 14:35", "when: another day")
local start = M.todayStart(os.time({ year = 2026, month = 10, day = 27, hour = 15 }))
eq(os.date("%H:%M", start), "00:00", "today starts at midnight")

-- profiles and what was read
local profiles = M.profiles({ { id = "def456", name = "Kids" }, { id = "abc123", name = "Home" }, { id = "" }, { id = "x9y8z7" } })
eq(#profiles, 3, "profiles: empty ids left out")
eq(profiles[1].name, "Home", "profiles by name")
eq(profiles[3].name, "x9y8z7", "profile without a name: its id")

local raw = {
    profile = { id = "abc123", name = "Home",
        denylist = { { id = "games.example.com", active = true }, { id = "social.example.org", active = false } },
        allowlist = { { id = "news.example.com", active = true } },
        security = { threatIntelligenceFeeds = true, nrd = false, parked = true },
        privacy = { disguisedTrackers = true, allowAffiliate = false },
        parentalControl = { safeSearch = true } },
    status = { { status = "default", queries = 10558 }, { status = "blocked", queries = 1872 }, { status = "allowed", queries = 50 } },
    top = { { domain = "ads.example.net", queries = 412 }, { domain = "tracker.example.com", queries = 288 } },
    kindle = { status = "ok", profile = "abc123", protocol = "DOH" },
}
local d = M.data(raw)
eq(d.name, "Home", "data: name")
eq(d.total, 12480, "data: total")
eq(d.blocked, 1872, "data: blocked")
eq(d.allowed, 50, "data: allowed")
eq(#d.top, 2, "data: top")
eq(d.deny[2].active, false, "data: an entry turned off")
eq(d.switches.threatIntelligenceFeeds, true, "data: a switch on")
eq(d.switches.nrd, false, "data: a switch off")
eq(d.switches.ddns, false, "data: a switch not given is off")
eq(d.switches.safeSearch, true, "data: parental control")
eq(d.topSkipped, false, "data: top read")
eq(M.data({ profile = {}, status = {} }).topSkipped, true, "data: top left out")
eq(select(2, M.switchCount(d)), #M.SWITCHES, "switch count: all")
eq((M.switchCount(d)), 4, "switch count: on")
eq(M.switch("csam").group, "security", "a switch's group")
eq(M.switch("nothing"), nil, "an unknown switch")
eq(select(2, M.find(d, "deny", "social.example.org")), 2, "find in a list")
eq(M.find(d, "allow", "games.example.com"), nil, "find: not on that list")
eq((M.listCount(d, "deny")), 1, "list count: on")

-- lines
eq(M.summary(d), "1,872 blocked · 15%", "summary")
eq(M.summary(M.data({ profile = {}, status = {} })), "No queries today", "summary: no queries")
eq(M.appsLine(d, true), "1,872 blocked today · 15%", "launcher line")
eq(M.appsLine(nil, false), "Not set up", "launcher line: not set up")
eq(M.kindleText(d.kindle, "abc123"), "Using NextDNS · this profile", "kindle: this profile")
eq(M.kindleText(d.kindle, "def456"), "Using NextDNS · profile abc123", "kindle: another profile")
eq(M.kindleText(M.kindle({ status = "unconfigured" }), "abc123"), "Not using NextDNS", "kindle: not using it")
eq(M.kindleText(nil), "Not checked yet", "kindle: not checked")
eq(M.kindleSub(d.kindle), "Over DOH", "kindle: how")

-- the query log
local logs = M.logs({
    { timestamp = "2026-10-27T14:35:12.345Z", domain = "ads.example.net", root = "example.net", status = "blocked",
      reasons = { { id = "blocklist:x", name = "Ads & trackers" } }, device = { id = "D1", name = "Laptop" }, protocol = "DNS-over-HTTPS" },
    { timestamp = "2026-10-27T14:34:00Z", domain = "news.example.com", device = { model = "Kindle" } },
    { domain = "" },
})
eq(#logs, 2, "logs: empty domains left out")
eq(logs[1].reason, "Ads & trackers", "log: reason")
eq(logs[1].time, 1793111712, "log: time")
eq(logs[2].status, "default", "log: no status is default")
eq(logs[2].device, "Kindle", "log: device model when unnamed")
eq(M.statusText("blocked"), "Blocked", "status text")
eq(M.statusText("default"), "", "status text: default")
eq(M.logLine(logs[1], 1, true, function(f) return fakeDate(f, 1) end), "Laptop · 14:35 · Ads & trackers", "log line")

-- search
local hits = M.search(d, "example.com")
eq(#hits, 3, "search: lists and top")
eq(hits[1].kind, "deny", "search: denylist first")
eq(M.search(d, "safe")[1].key, "googleSafeBrowsing", "search: a switch")
eq(#M.search(nil, "x"), 0, "search: nothing read")

-- the API, against a stand-in network
local NULL = setmetatable({}, { __tostring = function() return "null" end })
ANSWERS['{"profiles"}'] = { data = { { id = "abc123", name = "Home" } } }
ANSWERS['{"profile"}'] = { data = raw.profile }
ANSWERS['{"status"}'] = { data = raw.status }
ANSWERS['{"top"}'] = { data = raw.top }
ANSWERS['{"logs"}'] = { data = { { domain = "a.example.com" } }, meta = { pagination = { cursor = "next1" } } }
ANSWERS['{"kindle"}'] = raw.kindle
ANSWERS['{"bad"}'] = { errors = { { code = "invalid", detail = "Invalid domain" } } }
ANSWERS['{"null"}'] = { data = NULL }

local sent = {}
local function net(routes)
    return function(method, url, headers, body)
        table.insert(sent, { method = method, url = url, headers = headers, body = body })
        for __, r in ipairs(routes) do
            if (not r.method or r.method == method) and url:find(r.url) then return r.status or 200, r.body end
        end
        return 404, ""
    end
end
local api = API.new({ key = "madeupkey", profile = "abc123" }, net({
    { url = "/profiles$", body = '{"profiles"}' },
    { url = "/profiles/abc123$", body = '{"profile"}' },
    { url = "/analytics/status", body = '{"status"}' },
    { url = "/analytics/domains", body = '{"top"}' },
    { url = "/logs", body = '{"logs"}' },
    { url = "test%.nextdns%.io", body = '{"kindle"}' },
    { method = "PATCH", url = "/security$", status = 204, body = "" },
    { method = "POST", url = "/denylist$", status = 204, body = "" },
    { method = "DELETE", url = "/allowlist/news%.example%.com$", status = 204, body = "" },
    { method = "POST", url = "/allowlist$", status = 400, body = '{"bad"}' },
}))
eq(api:profiles()[1].id, "abc123", "api: profiles")
eq(sent[1].headers["X-Api-Key"], "madeupkey", "api: the key's header")
local all = api:readAll(1793059200)
eq(all.profile.name, "Home", "api: readAll profile")
eq(#all.top, 2, "api: readAll top")
eq(all.kindle.status, "ok", "api: readAll kindle")
local statusReq, kindleReq
for __, s in ipairs(sent) do
    if s.url:find("analytics/status") then statusReq = s end
    if s.url:find("test%.nextdns") then kindleReq = s end
end
eq(statusReq.url, "https://api.nextdns.io/profiles/abc123/analytics/status?from=1793059200", "api: today's numbers since midnight")
eq(kindleReq.headers["X-Api-Key"], nil, "api: no key to test.nextdns.io")
local l = api:logs({ status = "blocked", search = "ads", cursor = "c1" })
eq(l.cursor, "next1", "api: logs cursor")
eq(sent[#sent].url, "https://api.nextdns.io/profiles/abc123/logs?cursor=c1&limit=40&search=ads&status=blocked", "api: logs filter")
api:logs({ status = "all" })
eq(sent[#sent].url, "https://api.nextdns.io/profiles/abc123/logs?limit=40", "api: logs, all")
eq(api:setSwitch("security", "nrd", true), true, "api: a switch")
eq(sent[#sent].body, "{nrd=true}", "api: the switch's body")
eq(api:listAdd("deny", "games.example.com"), true, "api: added")
eq(sent[#sent].body, "{active=true,id=games.example.com}", "api: added on")
api:listAdd("deny", "games.example.com", false)
eq(sent[#sent].body, "{active=false,id=games.example.com}", "api: added off (undo)")
eq(api:listDelete("allow", "news.example.com"), true, "api: deleted")
eq(sent[#sent].method, "DELETE", "api: delete method")
eq(select(2, api:listAdd("allow", "x.example.com")), "Invalid domain", "api: an error's detail")

local function one(status, body) return API.new({ key = "k", profile = "abc123" }, function() return status, body end) end
eq(select(2, one(403, '{"bad"}'):profiles()), "signin", "403: the key refused")
eq(select(2, one(401, ""):profiles()), "signin", "401: the key refused")
eq(select(2, one(404, ""):profileData()), "notfound", "404: no such profile")
eq(select(2, one(429, ""):profiles()), "busy", "429: too many")
eq(select(2, one(200, "<html>"):profiles()), "notapi", "html: not the API")
eq(select(2, one("timeout", nil):profiles()), "timeout", "network error")
eq(one(200, '{"null"}'):profileData() ~= nil, true, "data null")
eq(select(2, one(500, ""):profiles()), "HTTP 500", "500 with nothing")
eq(select(2, API.new({ key = "k", profile = "p" }, net({ { url = "/profiles/p$", status = 404, body = "" } })):readAll(0)), "notfound", "readAll: profile missing")

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
