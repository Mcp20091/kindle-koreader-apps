--[[--
NextDNS as words and tables, in plain Lua for the tests: a profile as the
API gives it (its deny and allow lists and its security, privacy and
parental control switches), today's numbers and top blocked domains, the
query log, whether this Kindle itself is using NextDNS (test.nextdns.io),
domains as typed, the launcher's line and search.

The API's shapes (from NextDNS's API and the nextdns-mcp OpenAPI file):
* answers are { data, meta }; errors { errors = { { code, detail } } };
* a list entry's id is its domain: { id = "example.com", active = true };
* analytics/status gives { { status, queries } } (default, blocked, allowed…);
* analytics/domains gives { { domain, root, queries } };
* a log entry is { timestamp, domain, root, status, reasons = { { id, name } },
  device = { id, name, model }, protocol }, and the next page's cursor is
  meta.pagination.cursor.
]]

local M = {}

-- Gettext when inside KOReader; the words themselves in the tests.
local ok, gettext = pcall(require, "gettext")
local _ = ok and gettext or function(s) return s end
local function T(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end
M.T = T

M.API = "https://api.nextdns.io"
M.TEST = "https://test.nextdns.io"
M.LOG_PAGE = 40
M.TOP = 5

-- (JSON's null comes back as a value of its own: anything not a plain string or number is nothing)
local function str(v)
    if type(v) == "string" then return v end
    if type(v) == "number" then return tostring(v) end
    return ""
end
M.str = str

local function num(v) return tonumber(v) or 0 end
local function list(v) return type(v) == "table" and v or {} end

-- ------------------------------------------------------------------ the key and requests

--- "••••••3f": a key with only its last two characters showing.
function M.masked(s)
    s = str(s)
    if #s <= 2 then return s ~= "" and "••" or "" end
    return string.rep("•", math.min(#s - 2, 12)) .. s:sub(-2)
end

--- Query parameters in a stable order: "from=1700000000&limit=5".
function M.query(params)
    local keys = {}
    for k in pairs(params or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for __, k in ipairs(keys) do
        local v = tostring(params[k]):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)
        parts[#parts + 1] = k .. "=" .. v
    end
    return table.concat(parts, "&")
end

--- A domain as typed, made usable: "https://Ads.Example.com/x" -> "ads.example.com";
-- "*.example.com" -> "example.com" (NextDNS's lists take in subdomains anyway). nil when it
-- isn't a domain.
function M.cleanDomain(s)
    s = str(s):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    s = s:gsub("^%a[%w+.-]*://", ""):gsub("[/?#].*$", ""):gsub(":%d+$", "")
    s = s:gsub("^%*%.", ""):gsub("^%.+", ""):gsub("%.+$", "")
    if s == "" or not s:find("%.") or s:find("[^%w%-%._]") or s:find("%.%.") then return nil end
    return s
end

-- ------------------------------------------------------------------ numbers and times

--- "12,480".
function M.number(n)
    local s = tostring(math.floor(num(n) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

--- "15%" (part of total); "<1%" for a little; "0%" for none.
function M.percent(part, total)
    part, total = num(part), num(total)
    if total <= 0 or part <= 0 then return "0%" end
    local p = part * 100 / total
    if p < 1 then return "<1%" end
    return tostring(math.floor(p + 0.5)) .. "%"
end

--- When today started on this Kindle (local midnight), as a Unix time.
function M.todayStart(now, date)
    date = date or os.date
    local t = date("*t", now or os.time())
    return os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0, isdst = t.isdst })
end

-- (days since 1970-01-01 for a date; Howard Hinnant's days_from_civil)
local function days(y, m, d)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- "2026-10-27T14:35:12.345Z" (or with +02:00) -> a Unix time; nil when it isn't one.
function M.parseTime(s)
    s = str(s)
    local y, mo, d, h, mi, se, rest = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
    if not y then return nil end
    local t = days(tonumber(y), tonumber(mo), tonumber(d)) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
    local sign, oh, om = rest:match("([+-])(%d%d):?(%d%d)$")
    if sign then
        local off = tonumber(oh) * 3600 + tonumber(om) * 60
        t = sign == "+" and t - off or t + off
    end
    return t
end

--- "14:35" or "2:35 PM". date: os.date (the tests pass their own).
function M.clock(t, twentyFour, date)
    date = date or os.date
    if twentyFour then return date("%H:%M", t) end
    return (date("%I:%M %p", t):gsub("^0", ""))
end

--- A log entry's time: the clock today, else the day and the clock.
function M.when(t, now, twentyFour, date)
    date = date or os.date
    if not t then return "" end
    if date("%Y-%m-%d", t) == date("%Y-%m-%d", now or os.time()) then return M.clock(t, twentyFour, date) end
    return date("%b %d", t):gsub(" 0", " ") .. ", " .. M.clock(t, twentyFour, date)
end

-- ------------------------------------------------------------------ the switches

-- Each switch on the Protection page, by the API's group (its path) and field.
M.GROUPS = {
    { key = "security", name = _("SECURITY") },
    { key = "privacy", name = _("PRIVACY") },
    { key = "parentalControl", name = _("PARENTAL CONTROL") },
}

M.SWITCHES = {
    { group = "security", key = "threatIntelligenceFeeds", name = _("Threat intelligence feeds"), sub = _("Known malware, phishing and scam domains") },
    { group = "security", key = "aiThreatDetection", name = _("AI threat detection"), sub = _("Threats spotted from patterns in the queries") },
    { group = "security", key = "googleSafeBrowsing", name = _("Safe browsing list"), sub = _("Google Safe Browsing's list of unsafe sites") },
    { group = "security", key = "cryptojacking", name = _("Block cryptojacking"), sub = _("Sites that mine cryptocurrency on your devices") },
    { group = "security", key = "dnsRebinding", name = _("DNS rebinding protection"), sub = _("Outside domains that point into your home network") },
    { group = "security", key = "homographs", name = _("Look-alike domain protection"), sub = _("Letters from other alphabets that look the same") },
    { group = "security", key = "typosquatting", name = _("Typosquatting protection"), sub = _("Misspellings of well-known domains") },
    { group = "security", key = "dga", name = _("Block generated domains"), sub = _("Domains made up by malware") },
    { group = "security", key = "nrd", name = _("Block newly registered domains"), sub = _("Registered in the last 30 days") },
    { group = "security", key = "ddns", name = _("Block dynamic DNS hostnames"), sub = _("Free hostnames often used by malware") },
    { group = "security", key = "parked", name = _("Block parked domains"), sub = _("Placeholder pages full of ads") },
    { group = "security", key = "csam", name = _("Block child sexual abuse material") },
    { group = "privacy", key = "disguisedTrackers", name = _("Block disguised trackers"), sub = _("Trackers hidden behind a site's own domain") },
    { group = "privacy", key = "allowAffiliate", name = _("Allow affiliate links"), sub = _("Lets affiliate and tracking links through") },
    { group = "parentalControl", key = "safeSearch", name = _("Safe search"), sub = _("Filtered results on search engines") },
    { group = "parentalControl", key = "youtubeRestrictedMode", name = _("Restricted video mode"), sub = _("YouTube's Restricted Mode") },
    { group = "parentalControl", key = "blockBypass", name = _("Block bypass methods"), sub = _("VPNs, proxies and other DNS services") },
}

local BY_KEY = {}
for __, s in ipairs(M.SWITCHES) do BY_KEY[s.key] = s end

--- A switch's description ({ group, key, name, sub }), or nil.
function M.switch(key) return BY_KEY[key] end

--- How many switches are on: on, of how many.
function M.switchCount(d)
    local n = 0
    for __, s in ipairs(M.SWITCHES) do if d.switches[s.key] then n = n + 1 end end
    return n, #M.SWITCHES
end

-- ------------------------------------------------------------------ profiles and what was read

--- The account's profiles: { { id, name } }, by name.
function M.profiles(raw)
    local out = {}
    for __, p in ipairs(list(raw)) do
        local id = str(p.id)
        if id ~= "" then out[#out + 1] = { id = id, name = str(p.name) ~= "" and str(p.name) or id } end
    end
    table.sort(out, function(a, b)
        if a.name:lower() == b.name:lower() then return a.id < b.id end
        return a.name:lower() < b.name:lower()
    end)
    return out
end

local function entries(raw)
    local out = {}
    for __, e in ipairs(list(raw)) do
        local domain = str(e.id)
        if domain ~= "" then out[#out + 1] = { domain = domain, active = e.active ~= false } end
    end
    return out
end

--- test.nextdns.io's answer: { using, profile, protocol }. Its status is "ok" when the
-- Kindle's DNS goes to NextDNS, "unconfigured" when it doesn't.
function M.kindle(raw)
    if type(raw) ~= "table" then return nil end
    return { using = str(raw.status) == "ok", profile = str(raw.profile), protocol = str(raw.protocol) }
end

--- What was read (raw: { profile, status, top, kindle }) as the app shows it:
-- { id, name, total, blocked, allowed, top = { { domain, queries } }, deny, allow
-- (each { { domain, active } }), switches = { key = on }, kindle }.
function M.data(raw)
    local p = type(raw.profile) == "table" and raw.profile or {}
    local d = { id = str(p.id), name = str(p.name), total = 0, blocked = 0, allowed = 0, top = {},
        deny = entries(p.denylist), allow = entries(p.allowlist), switches = {}, kindle = M.kindle(raw.kindle),
        topSkipped = raw.top == nil }
    for __, s in ipairs(list(raw.status)) do
        local n = num(s.queries)
        d.total = d.total + n
        local st = str(s.status)
        if st == "blocked" then d.blocked = d.blocked + n elseif st == "allowed" then d.allowed = d.allowed + n end
    end
    for __, x in ipairs(list(raw.top)) do
        local domain = str(x.domain)
        if domain ~= "" then d.top[#d.top + 1] = { domain = domain, queries = num(x.queries) } end
    end
    for __, s in ipairs(M.SWITCHES) do
        d.switches[s.key] = type(p[s.group]) == "table" and p[s.group][s.key] == true
    end
    return d
end

--- A list entry and its place: (entry, index), or nil.
function M.find(d, which, domain)
    for i, e in ipairs(d and d[which] or {}) do
        if e.domain == domain then return e, i end
    end
end

--- How many entries of a list are on: on, of how many.
function M.listCount(d, which)
    local n = 0
    for __, e in ipairs(d[which]) do if e.active then n = n + 1 end end
    return n, #d[which]
end

-- ------------------------------------------------------------------ lines

--- "1,872 blocked · 15%"; "No queries today".
function M.summary(d)
    if not d then return "" end
    if d.total <= 0 then return _("No queries today") end
    return T(_("%1 blocked · %2"), M.number(d.blocked), M.percent(d.blocked, d.total))
end

--- The launcher tile's line: "1,872 blocked today · 15%".
function M.appsLine(d, configured)
    if not configured then return _("Not set up") end
    if not d then return "" end
    if d.total <= 0 then return _("No queries today") end
    return T(_("%1 blocked today · %2"), M.number(d.blocked), M.percent(d.blocked, d.total))
end

--- Whether this Kindle uses NextDNS, in words. profile: the profile shown in the app.
function M.kindleText(k, profile)
    if not k then return _("Not checked yet") end
    if not k.using then return _("Not using NextDNS") end
    if k.profile ~= "" and profile and k.profile ~= profile then return T(_("Using NextDNS · profile %1"), k.profile) end
    if k.profile ~= "" then return _("Using NextDNS · this profile") end
    return _("Using NextDNS")
end

--- The second line under it: how it connects, or what to do.
function M.kindleSub(k)
    if not k then return nil end
    if not k.using then return _("Its DNS doesn't go through NextDNS") end
    if k.protocol ~= "" then return T(_("Over %1"), k.protocol) end
end

-- ------------------------------------------------------------------ the query log

M.LOG_FILTERS = {
    { id = "all", name = _("All") },
    { id = "blocked", name = _("Blocked") },
    { id = "allowed", name = _("Allowed") },
}

--- One log entry: { domain, root, time, device, status, reason, protocol }.
function M.logEntry(x)
    local dev = type(x.device) == "table" and x.device or {}
    local reason = ""
    for __, r in ipairs(list(x.reasons)) do
        reason = str(r.name)
        if reason ~= "" then break end
    end
    local status = str(x.status)
    if status == "" then status = "default" end
    return { domain = str(x.domain), root = str(x.root), time = M.parseTime(x.timestamp),
        device = str(dev.name) ~= "" and str(dev.name) or str(dev.model), status = status, reason = reason,
        protocol = str(x.protocol) }
end

function M.logs(raw)
    local out = {}
    for __, x in ipairs(list(raw)) do
        local e = M.logEntry(x)
        if e.domain ~= "" then out[#out + 1] = e end
    end
    return out
end

local STATUS_TEXT = { blocked = _("Blocked"), allowed = _("Allowed"), error = _("Error") }
function M.statusText(s) return STATUS_TEXT[s] or "" end

--- "Laptop · 14:35 · Ads & trackers".
function M.logLine(e, now, twentyFour, date)
    local parts = {}
    if e.device ~= "" then parts[#parts + 1] = e.device end
    local w = M.when(e.time, now, twentyFour, date)
    if w ~= "" then parts[#parts + 1] = w end
    if e.reason ~= "" then parts[#parts + 1] = e.reason end
    return table.concat(parts, " · ")
end

-- ------------------------------------------------------------------ search

--- The launcher's search (q in lower case) in what was read: list entries, top blocked
-- domains and switches. Each hit: { kind = "deny" | "allow" | "top" | "switch", title, sub, key }.
function M.search(d, q)
    local out = {}
    if not d or not q or q == "" then return out end
    local function has(s) return s:lower():find(q, 1, true) ~= nil end
    for __, which in ipairs({ "deny", "allow" }) do
        for __, e in ipairs(d[which]) do
            if has(e.domain) then
                out[#out + 1] = { kind = which, key = e.domain, title = e.domain,
                    sub = (which == "deny" and _("Denylist") or _("Allowlist")) .. " · " .. (e.active and _("On") or _("Off")) }
            end
        end
    end
    for __, x in ipairs(d.top) do
        if has(x.domain) then
            out[#out + 1] = { kind = "top", key = x.domain, title = x.domain, sub = T(_("Blocked today · %1"), M.number(x.queries)) }
        end
    end
    for __, s in ipairs(M.SWITCHES) do
        if has(s.name) then
            out[#out + 1] = { kind = "switch", key = s.key, title = s.name, sub = d.switches[s.key] and _("On") or _("Off") }
        end
    end
    return out
end

return M
