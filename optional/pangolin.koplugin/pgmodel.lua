--[[--
Pangolin's organization as words and tables, in plain Lua for the tests:
what the Integration API's lists mean (sites, public and private resources,
clients), the addresses and key as typed, health and sizes as text, what
needs attention, the launcher's line, and which notifications a new read
brings (a site or resource gone offline, or back).

The field names and their quirks are the Home Assistant integration's
(ha-pangolin), checked there against Pangolin's route handlers:
* lists page with page and pageSize, and data.pagination.total;
* a public resource's `sso` and `whitelist` are numbers (0 or 1) in the
  list, and passwordId, pincodeId and headerAuthId are null when off;
* health is healthy, degraded, offline or unknown (older builds said
  "unhealthy" for offline);
* machine clients and user devices share one clientId namespace.
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

M.PAGE_SIZE = 100

-- (JSON's null comes back as a value of its own: anything not a plain string or number is nothing)
local function str(v)
    if type(v) == "string" then return v end
    if type(v) == "number" then return tostring(v) end
    return ""
end
M.str = str

local function num(v)
    return tonumber(v) or 0
end

local function list(v)
    if type(v) == "table" then return v end
    return {}
end

--- Whether a field is set: true, a number other than 0, or a non-empty string (null, false and 0 are not).
local function set(v)
    if v == true then return true end
    if type(v) == "number" then return v ~= 0 end
    if type(v) == "string" then return v ~= "" end
    return false
end
M.set = set

local function byName(a, b)
    local x, y = a.name:lower(), b.name:lower()
    if x == y then return a.id < b.id end
    return x < y
end

-- ------------------------------------------------------------------ the address and key

--- The API's address as typed, made usable: "api.example.com" -> "https://api.example.com";
-- a trailing /v1 (or slash) goes, since the requests add /v1 themselves. nil when empty.
function M.cleanUrl(url)
    url = str(url):gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then return nil end
    if not url:find("^https?://") then url = "https://" .. url end
    url = url:gsub("/+$", ""):gsub("/v1$", ""):gsub("/+$", "")
    return url
end

--- The base every request starts with: ".../v1".
function M.apiBase(url)
    return (M.cleanUrl(url) or "") .. "/v1"
end

--- Pangolin's keys look like "<apiKeyId>.<secret>": the ID part, or nil.
function M.keyId(key)
    local id, secret = str(key):gsub("^%s+", ""):gsub("%s+$", ""):match("^([^.]+)%.(.+)$")
    if id and secret then return id end
end

--- "••••••3f": a key or secret with only its last two characters showing.
function M.masked(s)
    s = str(s)
    if #s <= 2 then return s ~= "" and "••" or "" end
    return string.rep("•", math.min(#s - 2, 12)) .. s:sub(-2)
end

--- Query parameters in a stable order: "page=1&pageSize=100".
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

-- ------------------------------------------------------------------ the lists

--- healthy, degraded, offline or unknown.
function M.health(v)
    v = str(v):lower()
    if v == "unhealthy" then return "offline" end
    if v == "healthy" or v == "degraded" or v == "offline" then return v end
    return "unknown"
end

local HEALTH_TEXT = { healthy = _("Healthy"), degraded = _("Degraded"), offline = _("Offline"), unknown = _("Unknown") }
function M.healthText(h) return HEALTH_TEXT[h] or HEALTH_TEXT.unknown end

function M.site(s)
    return {
        id = num(s.siteId), name = str(s.name) ~= "" and str(s.name) or str(s.niceId),
        niceId = str(s.niceId), online = s.online == true, type = str(s.type), address = str(s.address),
        status = str(s.status), newt = str(s.newtVersion), exitNode = str(s.exitNodeName),
        resources = tonumber(s.resourceCount), mbIn = num(s.megabytesIn), mbOut = num(s.megabytesOut),
    }
end

function M.resource(r)
    local t = {
        id = num(r.resourceId), name = str(r.name), niceId = str(r.niceId), domain = str(r.fullDomain),
        enabled = r.enabled ~= false, health = M.health(r.health), mode = str(r.mode),
        sso = set(r.sso), password = set(r.passwordId), pin = set(r.pincodeId), whitelist = set(r.whitelist),
        headerAuth = set(r.headerAuthId), targets = {}, sites = {},
    }
    if t.name == "" then t.name = t.domain ~= "" and t.domain or t.niceId end
    for __, x in ipairs(list(r.targets)) do
        local host = str(x.ip)
        if str(x.port) ~= "" then host = host .. ":" .. str(x.port) end
        table.insert(t.targets, { id = num(x.targetId), site = str(x.siteName), target = host,
            enabled = x.enabled ~= false, check = x.hcEnabled == true, health = M.health(x.healthStatus) })
    end
    for __, s in ipairs(list(r.sites)) do
        table.insert(t.sites, { name = str(s.siteName), online = s.online == true })
    end
    return t
end

function M.private(r)
    local t = {
        id = num(r.siteResourceId), name = str(r.name), niceId = str(r.niceId), mode = str(r.mode),
        destination = str(r.destination), alias = str(r.alias), aliasAddress = str(r.aliasAddress),
        enabled = r.enabled ~= false, tcp = str(r.tcpPortRangeString), udp = str(r.udpPortRangeString),
        sites = {},
    }
    if type(r.disableIcmp) == "boolean" then t.icmp = not r.disableIcmp end
    if t.name == "" then t.name = t.alias ~= "" and t.alias or t.niceId end
    local names, onlines = list(r.siteNames), list(r.siteOnlines)
    for k, n in ipairs(names) do
        local on = onlines[k]
        table.insert(t.sites, { name = str(n), online = type(on) == "boolean" and on or nil })
    end
    return t
end

--- kind: "machine" (from /clients) or "user" (from /user-devices).
function M.client(c, kind)
    local t = {
        id = num(c.clientId), name = str(c.name), kind = kind or str(c.kind), online = c.online == true,
        blocked = c.blocked == true, archived = c.archived == true, user = str(c.username),
        version = str(c.olmVersion), platform = str(c.fingerprintPlatform), os = str(c.fingerprintOsVersion),
        model = str(c.deviceModel), approval = str(c.approvalState), lastSeen = tonumber(c.lastSeen),
        mbIn = num(c.megabytesIn), mbOut = num(c.megabytesOut),
    }
    if t.name == "" then t.name = T(_("Client %1"), t.id) end
    return t
end

--- What a read brought ({ org, sites, resources, private, machines, devices, skipped }) as
-- sorted lists: { orgName, sites, resources, private, clients, skipped }. skipped: the
-- lists the key couldn't read ({ resources = true, … }).
function M.data(raw)
    raw = raw or {}
    local d = { orgName = str(list(raw.org).name), sites = {}, resources = {}, private = {}, clients = {},
        skipped = {} }
    for k, v in pairs(list(raw.skipped)) do d.skipped[k] = v end
    for __, s in ipairs(list(raw.sites)) do table.insert(d.sites, M.site(s)) end
    for __, r in ipairs(list(raw.resources)) do table.insert(d.resources, M.resource(r)) end
    for __, r in ipairs(list(raw.private)) do table.insert(d.private, M.private(r)) end
    for __, c in ipairs(list(raw.machines)) do table.insert(d.clients, M.client(c, "machine")) end
    for __, c in ipairs(list(raw.devices)) do table.insert(d.clients, M.client(c, "user")) end
    table.sort(d.sites, byName)
    table.sort(d.resources, byName)
    table.sort(d.private, byName)
    -- (archived ones last, then online first, then by name)
    table.sort(d.clients, function(a, b)
        if a.archived ~= b.archived then return b.archived end
        if a.online ~= b.online then return a.online end
        return byName(a, b)
    end)
    return d
end

--- One of the lists' items by kind ("site", "resource", "private", "client") and id.
function M.find(d, kind, id)
    local t = d and ({ site = d.sites, resource = d.resources, private = d.private, client = d.clients })[kind]
    for __, x in ipairs(t or {}) do
        if x.id == id then return x end
    end
end

-- ------------------------------------------------------------------ as text

--- "820 KB", "12.3 MB", "1.2 GB" (from megabytes, as Pangolin counts them).
function M.size(mb)
    mb = num(mb)
    if mb < 1 then return T(_("%1 KB"), math.floor(mb * 1000 + 0.5)) end
    if mb < 1000 then return T(_("%1 MB"), string.format("%.1f", mb)) end
    if mb < 1000000 then return T(_("%1 GB"), string.format("%.1f", mb / 1000)) end
    return T(_("%1 TB"), string.format("%.1f", mb / 1000000))
end

--- "Just now", "5 min ago", "3 h ago", "2 days ago".
function M.ago(t, now)
    local s = math.max(0, (now or os.time()) - num(t))
    if s < 60 then return _("Just now") end
    if s < 3600 then return T(_("%1 min ago"), math.floor(s / 60)) end
    if s < 86400 then return T(_("%1 h ago"), math.floor(s / 3600)) end
    local days = math.floor(s / 86400)
    return days == 1 and _("1 day ago") or T(_("%1 days ago"), days)
end

--- The time as KOReader shows it ("2:35 PM" or "14:35"). date: os.date (tests pass their own).
function M.clock(t, twentyFour, date)
    date = date or os.date
    local s = date(twentyFour and "%H:%M" or "%I:%M %p", t)
    if not twentyFour then s = s:gsub("^0", "") end
    return s
end

local SITE_TYPES = { newt = "Newt", wireguard = "WireGuard", ["local"] = _("Local") }
function M.siteType(s) return SITE_TYPES[s.type] or s.type end

--- A site's second line: "Newt · 10.0.0.2" (offline or pending first).
function M.siteLine(s)
    local parts = {}
    if s.status == "pending" then parts[#parts + 1] = _("Waiting for approval") end
    if M.siteType(s) ~= "" then parts[#parts + 1] = M.siteType(s) end
    if s.address ~= "" then parts[#parts + 1] = s.address end
    return table.concat(parts, " · ")
end

--- A public resource's second line: "app.example.com · Healthy" ("Disabled" when it's off).
function M.resourceLine(r)
    local parts = {}
    if r.domain ~= "" then parts[#parts + 1] = r.domain end
    parts[#parts + 1] = r.enabled and M.healthText(r.health) or _("Disabled")
    return table.concat(parts, " · ")
end

--- A private resource's second line: "Host · 192.168.1.20" ("Disabled" when it's off).
function M.privateLine(r)
    local parts = {}
    if r.mode ~= "" then parts[#parts + 1] = r.mode:sub(1, 1):upper() .. r.mode:sub(2) end
    if r.destination ~= "" then parts[#parts + 1] = r.destination end
    if not r.enabled then parts[#parts + 1] = _("Disabled") end
    return table.concat(parts, " · ")
end

--- A client's kind: "Machine" or "User device".
function M.kindText(c) return c.kind == "user" and _("User device") or _("Machine") end

--- A client's second line: "User device · pat · Online" ("Blocked", "Archived").
function M.clientLine(c)
    local parts = { M.kindText(c) }
    if c.user ~= "" then parts[#parts + 1] = c.user end
    if c.archived then parts[#parts + 1] = _("Archived")
    elseif c.blocked then parts[#parts + 1] = _("Blocked")
    else parts[#parts + 1] = c.online and _("Online") or _("Offline") end
    return table.concat(parts, " · ")
end

--- What protects a public resource, in words: "Sign-in, PIN" ("None" when nothing does).
function M.protection(r)
    local parts = {}
    if r.sso then parts[#parts + 1] = _("Sign-in") end
    if r.password then parts[#parts + 1] = _("Password") end
    if r.pin then parts[#parts + 1] = _("PIN") end
    if r.whitelist then parts[#parts + 1] = _("Email whitelist") end
    if r.headerAuth then parts[#parts + 1] = _("Header auth") end
    if #parts == 0 then return _("None") end
    return table.concat(parts, ", ")
end

-- ------------------------------------------------------------------ the whole organization

--- { sites, sitesOnline, resources, resourcesDown, resourcesDegraded, private, clients, clientsOnline }.
-- Disabled resources aren't down; archived clients aren't counted.
function M.counts(d)
    local c = { sites = #d.sites, sitesOnline = 0, resources = #d.resources, resourcesDown = 0,
        resourcesDegraded = 0, private = #d.private, clients = 0, clientsOnline = 0 }
    for __, s in ipairs(d.sites) do if s.online then c.sitesOnline = c.sitesOnline + 1 end end
    for __, r in ipairs(d.resources) do
        if r.enabled and r.health == "offline" then c.resourcesDown = c.resourcesDown + 1 end
        if r.enabled and r.health == "degraded" then c.resourcesDegraded = c.resourcesDegraded + 1 end
    end
    for __, x in ipairs(d.clients) do
        if not x.archived then
            c.clients = c.clients + 1
            if x.online then c.clientsOnline = c.clientsOnline + 1 end
        end
    end
    return c
end

--- What needs looking at, worst first: { { kind = "site" | "resource", item, why } }:
-- offline sites (not ones waiting for approval), enabled resources that are offline or degraded.
function M.attention(d)
    local out = {}
    for __, s in ipairs(d.sites) do
        if not s.online and s.status ~= "pending" then
            out[#out + 1] = { kind = "site", item = s, why = _("Site offline") }
        end
    end
    for __, r in ipairs(d.resources) do
        if r.enabled and r.health == "offline" then
            out[#out + 1] = { kind = "resource", item = r, why = _("Resource offline") }
        end
    end
    for __, r in ipairs(d.resources) do
        if r.enabled and r.health == "degraded" then
            out[#out + 1] = { kind = "resource", item = r, why = _("Resource degraded") }
        end
    end
    return out
end

--- "All online", "1 site offline", "1 site offline · 2 resources down".
function M.summary(d)
    local c = M.counts(d)
    local parts = {}
    local off = c.sites - c.sitesOnline
    for __, s in ipairs(d.sites) do if not s.online and s.status == "pending" then off = off - 1 end end
    if off == 1 then parts[#parts + 1] = _("1 site offline")
    elseif off > 1 then parts[#parts + 1] = T(_("%1 sites offline"), off) end
    if c.resourcesDown == 1 then parts[#parts + 1] = _("1 resource down")
    elseif c.resourcesDown > 1 then parts[#parts + 1] = T(_("%1 resources down"), c.resourcesDown) end
    if c.resourcesDegraded == 1 then parts[#parts + 1] = _("1 degraded")
    elseif c.resourcesDegraded > 1 then parts[#parts + 1] = T(_("%1 degraded"), c.resourcesDegraded) end
    if #parts == 0 then return _("All online") end
    return table.concat(parts, " · ")
end

--- The launcher tile's line: "All online · 4 sites", "1 site offline · 1 resource down".
function M.appsLine(d, configured)
    if not configured then return _("Not set up") end
    if not d then return _("Open to read Pangolin") end
    local s = M.summary(d)
    if s == _("All online") then
        if #d.sites == 1 then return _("All online · 1 site") end
        return T(_("All online · %1 sites"), #d.sites)
    end
    return s
end

--- The notifications a new read brings, compared with the one before (nil: the first
-- read, which says nothing): { add = { { key, text, kind, id } }, remove = { keys } }.
-- A site going offline, an enabled resource going offline; each goes when it's back.
function M.changes(before, after)
    local out = { add = {}, remove = {} }
    if not before or not after then return out end
    local was = {}
    for __, s in ipairs(before.sites) do was["site:" .. s.id] = s.online end
    for __, r in ipairs(before.resources) do was["resource:" .. r.id] = r.enabled and r.health ~= "offline" end
    for __, s in ipairs(after.sites) do
        local key = "site:" .. s.id
        if was[key] == true and not s.online then
            table.insert(out.add, { key = "pangolin:" .. key, kind = "site", id = s.id, text = T(_("Site offline: %1"), s.name) })
        elseif was[key] == false and s.online then
            table.insert(out.remove, "pangolin:" .. key)
        end
    end
    for __, r in ipairs(after.resources) do
        local key = "resource:" .. r.id
        local up = r.enabled and r.health ~= "offline"
        if was[key] == true and r.enabled and r.health == "offline" then
            table.insert(out.add, { key = "pangolin:" .. key, kind = "resource", id = r.id, text = T(_("Resource offline: %1"), r.name) })
        elseif was[key] == false and up then
            table.insert(out.remove, "pangolin:" .. key)
        end
    end
    return out
end

--- What the launcher's search finds (q in lower case), at most 20:
-- { { kind, item, title, sub } } from every list, by name, domain or address.
function M.search(d, q)
    local out = {}
    if not d or not q or q == "" then return out end
    local function hit(...)
        for __, s in ipairs({ ... }) do
            if s ~= "" and s:lower():find(q, 1, true) then return true end
        end
    end
    local function add(kind, item, sub)
        if #out < 20 then out[#out + 1] = { kind = kind, item = item, title = item.name, sub = sub } end
    end
    for __, s in ipairs(d.sites) do if hit(s.name, s.address) then add("site", s, M.siteLine(s)) end end
    for __, r in ipairs(d.resources) do if hit(r.name, r.domain) then add("resource", r, M.resourceLine(r)) end end
    for __, r in ipairs(d.private) do if hit(r.name, r.destination, r.alias) then add("private", r, M.privateLine(r)) end end
    for __, c in ipairs(d.clients) do if hit(c.name, c.user) then add("client", c, M.clientLine(c)) end end
    return out
end

return M
