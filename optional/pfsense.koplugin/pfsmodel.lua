--[[--
pfSense as words and tables, in plain Lua for the tests: what the REST API's
lists mean (the system, gateways, interfaces, services, DHCP leases and static
mappings, the ARP table, DNS host overrides, firewall rules, VPN, packages,
logs), the address and key as typed, sizes and times as text, what needs
attention, the launcher's line, and which notifications a new read brings (a
gateway, interface or service gone down, or back).

The field names are the pfSense REST API package's (pfrest, v2), from its
OpenAPI document:
* answers are { code, status, response_id, message, data };
* lists page with limit and offset, and sort with sort_by and sort_order;
* an object's `id` is its place in its list, so it changes when one before it
  goes: a change checks the object is still the one it was (by its tracker,
  MAC or address) before it's made;
* a gateway's status is "none" or "online" when it's fine (pfSense's own
  word for fine is "none"), else down, loss, delay, highloss or highdelay.
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

M.PAGE_SIZE = 200
M.LOG_LINES = 100

-- (JSON's null comes back as a value of its own: anything not a plain string or number is nothing)
local function str(v)
    if type(v) == "string" then return v end
    if type(v) == "number" then return tostring(v) end
    return ""
end
M.str = str

local function num(v) return tonumber(v) or 0 end

local function list(v)
    if type(v) == "table" then return v end
    return {}
end

--- A list of strings from an array or a comma-separated string ("a, b").
local function strings(v)
    local out = {}
    if type(v) == "table" then
        for __, x in ipairs(v) do if str(x) ~= "" then out[#out + 1] = str(x) end end
    elseif str(v) ~= "" then
        for x in str(v):gmatch("[^,%s]+") do out[#out + 1] = x end
    end
    return out
end
M.strings = strings

local function byName(a, b)
    local x, y = a.name:lower(), b.name:lower()
    if x == y then return tostring(a.id) < tostring(b.id) end
    return x < y
end

-- ------------------------------------------------------------------ the address and key

--- The firewall's address as typed, made usable: "192.168.1.1" -> "https://192.168.1.1";
-- a trailing /api/v2 (or slash) goes, since the requests add it. nil when empty.
function M.cleanUrl(url)
    url = str(url):gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then return nil end
    if not url:find("^https?://") then url = "https://" .. url end
    url = url:gsub("/+$", ""):gsub("/api/v2$", ""):gsub("/api$", ""):gsub("/+$", "")
    return url
end

--- The base every request starts with: ".../api/v2".
function M.apiBase(url)
    return (M.cleanUrl(url) or "") .. "/api/v2"
end

--- "••••••3f": a key with only its last two characters showing.
function M.masked(s)
    s = str(s)
    if #s <= 2 then return s ~= "" and "••" or "" end
    return string.rep("•", math.min(#s - 2, 12)) .. s:sub(-2)
end

--- Query parameters in a stable order: "limit=200&offset=0".
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

--- A MAC address as pfSense compares them: lower case, colons.
function M.mac(s)
    s = str(s):lower():gsub("%-", ":"):gsub("%s", "")
    return s
end

--- Whether text looks like a MAC address (aa:bb:cc:dd:ee:ff).
function M.isMac(s)
    return M.mac(s):match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

--- Whether text looks like an IPv4 address.
function M.isIPv4(s)
    local a, b, c, d = str(s):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return false end
    for __, n in ipairs({ a, b, c, d }) do if tonumber(n) > 255 then return false end end
    return true
end

-- ------------------------------------------------------------------ the lists

function M.system(s, v)
    s, v = list(s), list(v)
    local t = {
        platform = str(s.platform), uptime = str(s.uptime), cpuModel = str(s.cpu_model),
        cpus = tonumber(s.cpu_count), cpu = tonumber(s.cpu_usage), mem = tonumber(s.mem_usage),
        swap = tonumber(s.swap_usage), disk = tonumber(s.disk_usage), mbuf = tonumber(s.mbuf_usage),
        temp = tonumber(s.temp_c), load = {}, version = str(v.version), buildtime = str(v.buildtime),
    }
    for __, x in ipairs(list(s.cpu_load_avg)) do t.load[#t.load + 1] = tonumber(x) or 0 end
    -- (no sensor: 0)
    if t.temp == 0 then t.temp = nil end
    return t
end

--- online, loss, delay, down or unknown, from a gateway's status and substatus.
function M.gatewayState(status, substatus)
    local s, sub = str(status):lower(), str(substatus):lower()
    local function word(x)
        if x:find("down") then return "down" end
        if x:find("loss") then return "loss" end
        if x:find("delay") then return "delay" end
    end
    local w = word(s) or word(sub)
    if w then return w end
    if s == "none" or s == "online" or s == "up" then return "online" end
    return "unknown"
end

function M.gateway(g)
    return { id = str(g.name), name = str(g.name), monitor = str(g.monitorip), source = str(g.srcip),
        delay = tonumber(g.delay), stddev = tonumber(g.stddev), loss = tonumber(g.loss),
        state = M.gatewayState(g.status, g.substatus) }
end

local IFACE_UP = { up = true, associated = true }

function M.interface(i)
    local t = {
        id = str(i.name), key = str(i.name), name = str(i.descr) ~= "" and str(i.descr) or str(i.name):upper(),
        hw = str(i.hwif), mac = str(i.macaddr), enabled = i.enable ~= false, status = str(i.status):lower(),
        ip = str(i.ipaddr), subnet = str(i.subnet), ipv6 = str(i.ipaddrv6), subnetv6 = str(i.subnetv6),
        media = str(i.media), gateway = str(i.gateway), inBytes = num(i.inbytes), outBytes = num(i.outbytes),
        inErrs = num(i.inerrs), outErrs = num(i.outerrs), collisions = num(i.collisions), mtu = str(i.mtu),
    }
    t.up = IFACE_UP[t.status] == true
    return t
end

function M.service(s)
    local t = { id = str(s.name), name = str(s.description) ~= "" and str(s.description) or str(s.name),
        key = str(s.name), enabled = s.enabled ~= false, running = s.status == true }
    return t
end

function M.lease(l)
    local online = str(l.online_status):lower()
    local t = { id = str(l.mac) .. "@" .. str(l.ip), ip = str(l.ip), mac = M.mac(l.mac), hostname = str(l.hostname),
        iface = str(l["if"]), starts = str(l.starts), ends = str(l.ends), state = str(l.active_status):lower(),
        online = online:find("online") ~= nil, descr = str(l.descr) }
    t.static = t.state == "static"
    t.name = t.hostname ~= "" and t.hostname or (t.descr ~= "" and t.descr or t.ip)
    return t
end

function M.arp(a)
    local t = { id = num(a.id), ip = str(a.ip_address), mac = M.mac(a.mac_address), hostname = str(a.hostname),
        iface = str(a.interface), type = str(a.type), permanent = a.permanent == true, expires = str(a.expires),
        dns = str(a.dnsresolve) }
    if t.hostname == "?" then t.hostname = "" end
    if t.dns == "?" then t.dns = "" end
    t.name = t.hostname ~= "" and t.hostname or (t.dns ~= "" and t.dns or t.ip)
    return t
end

local function where(v)
    v = str(v)
    if v == "" then return _("any") end
    return v
end

function M.rule(r)
    local t = { id = num(r.id), tracker = str(r.tracker), type = str(r.type), ifaces = strings(r.interface),
        protocol = str(r.protocol), source = where(r.source), sport = str(r.source_port), dest = where(r.destination),
        dport = str(r.destination_port), descr = str(r.descr), disabled = r.disabled == true,
        floating = r.floating == true, log = r.log == true, sched = str(r.sched), gateway = str(r.gateway),
        updatedBy = str(r.updated_by) }
    if t.descr ~= "" then t.name = t.descr
    else
        local to = t.dest .. (t.dport ~= "" and (":" .. t.dport) or "")
        t.name = T(_("%1 %2 to %3"), M.ruleType(t), t.source, to)
    end
    return t
end

local RULE_TYPES = { pass = _("Pass"), block = _("Block"), reject = _("Reject") }
function M.ruleType(r) return RULE_TYPES[r.type] or r.type end

function M.static(s)
    local t = { parent = str(s.parent_id), id = num(s.id), mac = M.mac(s.mac), ip = str(s.ipaddr),
        hostname = str(s.hostname), descr = str(s.descr), domain = str(s.domain), cid = str(s.cid) }
    t.key = t.parent .. ":" .. t.mac
    t.name = t.hostname ~= "" and t.hostname or (t.descr ~= "" and t.descr or t.mac)
    return t
end

function M.override(o)
    local t = { id = num(o.id), host = str(o.host), domain = str(o.domain), ips = strings(o.ip),
        descr = str(o.descr), aliases = {} }
    for __, a in ipairs(list(o.aliases)) do
        if type(a) == "table" then
            local name = str(a.host)
            if str(a.domain) ~= "" then name = name ~= "" and (name .. "." .. str(a.domain)) or str(a.domain) end
            if name ~= "" then t.aliases[#t.aliases + 1] = name end
        elseif str(a) ~= "" then
            t.aliases[#t.aliases + 1] = str(a)
        end
    end
    t.fqdn = t.host ~= "" and (t.host .. "." .. t.domain) or t.domain
    t.name = t.fqdn
    return t
end

function M.peer(p, now)
    local t = { id = str(p.public_key), tunnel = str(p.tunnel_device), endpoint = str(p.endpoint),
        allowed = strings(p.allowed_ips), handshake = tonumber(p.latest_handshake), rx = num(p.transfer_rx),
        tx = num(p.transfer_tx), descr = str(p.descr) }
    t.name = t.descr ~= "" and t.descr or (t.id:sub(1, 8) .. "…")
    -- (WireGuard says nothing about "connected": a handshake in the last three minutes is)
    t.online = t.handshake ~= nil and t.handshake > 0 and (now or os.time()) - t.handshake < 180
    return t
end

function M.ovpn(s)
    local t = { id = num(s.vpnid), name = str(s.name), mode = str(s.mode), port = str(s.port), conns = {} }
    for __, c in ipairs(list(s.conns)) do
        t.conns[#t.conns + 1] = { name = str(c.common_name), remote = str(c.remote_host),
            vip = str(c.virtual_addr), since = str(c.connect_time) }
    end
    if t.name == "" then t.name = T(_("OpenVPN server %1"), t.id) end
    return t
end

function M.package(p)
    return { name = str(p.name), short = str(p.shortname) ~= "" and str(p.shortname) or str(p.name):gsub("^pfSense%-pkg%-", ""),
        descr = str(p.descr), installed = str(p.installed_version), latest = str(p.latest_version),
        update = p.update_available == true }
end

--- A log line as pfSense gives it, split: { time, text } ("Oct 27 14:35:01" and the rest).
function M.logLine(s)
    s = str(type(s) == "table" and s.text or s)
    local time, rest = s:match("^(%a%a%a%s+%d+%s+%d+:%d+:%d+)%s+(.*)$")
    if not time then time, rest = s:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)[^%s]*%s+(.*)$") end
    if not time then return { time = "", text = s } end
    -- (the host's name first in syslog lines: left out)
    rest = rest:gsub("^[%w%.%-]+%s+(%S+%[?%d*%]?:)", "%1")
    return { time = time, text = rest }
end

--- A firewall log line ("…,match,block,in,4,…,tcp,…,192.168.1.20,10.0.0.2,51000,443,…"),
-- as words: { action, dir, iface, proto, src, dst } (nil when it isn't one).
function M.filterLine(s)
    local text = str(type(s) == "table" and s.text or s)
    local csv = text:match("filterlog%[?%d*%]?:%s*(.*)$")
    if not csv then return nil end
    local f = {}
    for x in (csv .. ","):gmatch("([^,]*),") do f[#f + 1] = x end
    local out = { iface = f[5] or "", action = f[7] or "", dir = f[8] or "", ver = f[9] or "" }
    local p
    if out.ver == "4" then out.proto, p = f[17] or "", 19
    elseif out.ver == "6" then out.proto, p = f[13] or "", 16
    else return out end
    out.src, out.dst = f[p] or "", f[p + 1] or ""
    local proto = out.proto:lower()
    if proto == "tcp" or proto == "udp" then
        if f[p + 2] and f[p + 2] ~= "" then out.src = out.src .. ":" .. f[p + 2] end
        if f[p + 3] and f[p + 3] ~= "" then out.dst = out.dst .. ":" .. f[p + 3] end
    end
    return out
end

--- What a read brought, as sorted lists. raw: { system, version, gateways, interfaces,
-- services, leases, arp, rules, statics, overrides, peers, ovpn, skipped }; lists not
-- read this time stay out (nil), so the ones from before can be kept (M.merge).
function M.data(raw, now)
    raw = raw or {}
    local d = { skipped = {} }
    for k, v in pairs(list(raw.skipped)) do d.skipped[k] = v end
    if raw.system then d.system = M.system(raw.system, raw.version) end
    local h = list(raw.hostname)
    d.hostname = str(h.hostname) ~= "" and (str(h.hostname) .. (str(h.domain) ~= "" and ("." .. str(h.domain)) or "")) or ""
    local function each(name, fn, sort)
        if raw[name] == nil then return end
        local out = {}
        for __, x in ipairs(list(raw[name])) do out[#out + 1] = fn(x, now) end
        if sort then table.sort(out, sort) end
        d[name] = out
    end
    each("gateways", M.gateway, byName)
    -- (interfaces in pfSense's own order: WAN, LAN, then the others)
    each("interfaces", M.interface)
    each("services", M.service, byName)
    each("leases", M.lease, function(a, b)
        if a.online ~= b.online then return a.online end
        return byName(a, b)
    end)
    each("arp", M.arp, function(a, b) return M.ipLess(a.ip, b.ip) end)
    -- (rules in their order: the order pfSense matches them)
    each("rules", M.rule)
    each("statics", M.static, function(a, b) return M.ipLess(a.ip, b.ip) end)
    each("overrides", M.override, byName)
    each("peers", M.peer, byName)
    each("ovpn", M.ovpn, byName)
    return d
end

--- The lists of a new read over the ones from before (a read of the status only keeps
-- the lists as they were).
function M.merge(before, after)
    if not before then return after end
    for __, k in ipairs({ "system", "gateways", "interfaces", "services", "leases", "arp", "rules", "statics",
        "overrides", "peers", "ovpn" }) do
        if after[k] == nil then after[k] = before[k] end
    end
    for k, v in pairs(before.skipped or {}) do
        if after.skipped[k] == nil and after[k] == nil then after.skipped[k] = v end
    end
    return after
end

--- Addresses in number order ("192.168.1.5" before "192.168.1.10"); others after, by text.
function M.ipLess(a, b)
    local function key(s)
        local p = { str(s):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
        if #p < 4 then return nil end
        return ((tonumber(p[1]) * 256 + tonumber(p[2])) * 256 + tonumber(p[3])) * 256 + tonumber(p[4])
    end
    local x, y = key(a), key(b)
    if x and y then return x < y end
    if x then return true end
    if y then return false end
    return str(a) < str(b)
end

local KINDS = { gateway = "gateways", interface = "interfaces", service = "services", lease = "leases", arp = "arp",
    rule = "rules", static = "statics", override = "overrides", peer = "peers", ovpn = "ovpn" }
M.KINDS = KINDS

--- One of the lists' items by kind ("gateway", "interface", …) and id.
function M.find(d, kind, id)
    local t = d and KINDS[kind] and d[KINDS[kind]]
    for __, x in ipairs(t or {}) do
        if x.id == id then return x end
    end
end

--- A static mapping by its interface and MAC (ids change; these don't).
function M.findStatic(d, parent, mac)
    for __, s in ipairs(d and d.statics or {}) do
        if s.parent == parent and s.mac == M.mac(mac) then return s end
    end
end

--- The static mapping for a lease or ARP entry (by MAC), if there is one.
function M.staticFor(d, mac)
    mac = M.mac(mac)
    for __, s in ipairs(d and d.statics or {}) do
        if s.mac == mac then return s end
    end
end

-- ------------------------------------------------------------------ as text

--- "820 B", "12.3 KB", "4.5 MB", "1.2 GB" (from bytes).
function M.bytes(n)
    n = num(n)
    if n < 1000 then return T(_("%1 B"), math.floor(n)) end
    if n < 1e6 then return T(_("%1 KB"), string.format("%.1f", n / 1e3)) end
    if n < 1e9 then return T(_("%1 MB"), string.format("%.1f", n / 1e6)) end
    if n < 1e12 then return T(_("%1 GB"), string.format("%.1f", n / 1e9)) end
    return T(_("%1 TB"), string.format("%.1f", n / 1e12))
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

--- "12%" (nil stays nil).
function M.pct(v)
    if v == nil then return nil end
    return T(_("%1%"), math.floor(v + 0.5))
end

--- pfSense's uptime ("12 Days 03 Hours 04 Minutes 05 Seconds") shorter: "12 days 3 h".
function M.uptime(s)
    s = str(s)
    local d = tonumber(s:match("(%d+)%s+[Dd]ay")) or 0
    local h = tonumber(s:match("(%d+)%s+[Hh]our")) or 0
    local m = tonumber(s:match("(%d+)%s+[Mm]inute")) or 0
    if d == 0 and h == 0 and m == 0 then return s end
    if d > 0 then return d == 1 and T(_("1 day %1 h"), h) or T(_("%1 days %2 h"), d, h) end
    if h > 0 then return T(_("%1 h %2 min"), h, m) end
    return T(_("%1 min"), m)
end

local GW_TEXT = { online = _("Online"), loss = _("Packet loss"), delay = _("High latency"), down = _("Down"), unknown = _("Unknown") }
function M.gatewayText(g) return GW_TEXT[g.state] or GW_TEXT.unknown end

--- A gateway's second line: "Online · 12 ms · 0% loss".
function M.gatewayLine(g)
    local parts = { M.gatewayText(g) }
    if g.delay then parts[#parts + 1] = T(_("%1 ms"), string.format("%.1f", g.delay):gsub("%.0$", "")) end
    if g.loss then parts[#parts + 1] = T(_("%1% loss"), string.format("%.0f", g.loss)) end
    return table.concat(parts, " · ")
end

--- "Up", "Down", "No carrier", "Disabled".
function M.interfaceState(i)
    if not i.enabled then return _("Disabled") end
    if i.up then return _("Up") end
    if i.status == "no carrier" then return _("No cable") end
    return _("Down")
end

--- An interface's second line: "Up · 192.168.1.1/24 · 1000baseT".
function M.interfaceLine(i)
    local parts = { M.interfaceState(i) }
    if i.ip ~= "" then parts[#parts + 1] = i.ip .. (i.subnet ~= "" and ("/" .. i.subnet) or "") end
    if i.media ~= "" then parts[#parts + 1] = (i.media:gsub("%s*<.*$", "")) end
    return table.concat(parts, " · ")
end

--- "Running", "Stopped", "Disabled".
function M.serviceState(s)
    if s.running then return _("Running") end
    if not s.enabled then return _("Disabled") end
    return _("Stopped")
end

--- A lease's second line: "192.168.1.20 · Online · Static".
function M.leaseLine(l)
    local parts = { l.ip }
    parts[#parts + 1] = l.online and _("Online") or _("Offline")
    if l.static then parts[#parts + 1] = _("Static") elseif l.state == "expired" then parts[#parts + 1] = _("Expired") end
    return table.concat(parts, " · ")
end

--- An ARP entry's second line: "aa:bb:cc:dd:ee:ff · lan".
function M.arpLine(a)
    local parts = { a.mac }
    if a.iface ~= "" then parts[#parts + 1] = a.iface end
    if a.permanent then parts[#parts + 1] = _("Permanent") end
    return table.concat(parts, " · ")
end

--- A rule's second line: "Block · LAN · TCP · 192.168.1.42 to any:443" ("Disabled" first when off).
function M.ruleLine(r)
    local parts = {}
    if r.disabled then parts[#parts + 1] = _("Disabled") end
    parts[#parts + 1] = M.ruleType(r)
    if r.floating then parts[#parts + 1] = _("Floating") end
    if #r.ifaces > 0 then parts[#parts + 1] = table.concat(r.ifaces, ", "):upper() end
    if r.protocol ~= "" then parts[#parts + 1] = r.protocol:upper() end
    if r.descr ~= "" then
        parts[#parts + 1] = T(_("%1 to %2"), r.source .. (r.sport ~= "" and (":" .. r.sport) or ""),
            r.dest .. (r.dport ~= "" and (":" .. r.dport) or ""))
    end
    return table.concat(parts, " · ")
end

--- A static mapping's second line: "192.168.1.20 · aa:bb:cc:dd:ee:ff".
function M.staticLine(s)
    local parts = {}
    if s.ip ~= "" then parts[#parts + 1] = s.ip end
    parts[#parts + 1] = s.mac
    return table.concat(parts, " · ")
end

--- A host override's second line: "192.168.1.20 · 2 aliases".
function M.overrideLine(o)
    local parts = { table.concat(o.ips, ", ") }
    if #o.aliases == 1 then parts[#parts + 1] = _("1 alias")
    elseif #o.aliases > 1 then parts[#parts + 1] = T(_("%1 aliases"), #o.aliases) end
    if o.descr ~= "" then parts[#parts + 1] = o.descr end
    return table.concat(parts, " · ")
end

--- A WireGuard peer's second line: "Connected · 2 min ago" or "Last seen 3 days ago".
function M.peerLine(p, now)
    if p.online then return T(_("Connected · %1"), M.ago(p.handshake, now)) end
    if p.handshake and p.handshake > 0 then return T(_("Last seen %1"), M.ago(p.handshake, now):lower()) end
    return _("Never connected")
end

-- ------------------------------------------------------------------ the whole firewall

--- { gateways, gatewaysUp, interfaces, interfacesUp, services, servicesRunning, stopped, leases,
-- online, rules, rulesOff, statics, overrides, peers, peersOnline }. Disabled interfaces and
-- services aren't counted as down.
function M.counts(d)
    local c = { gateways = 0, gatewaysUp = 0, interfaces = 0, interfacesUp = 0, services = 0, servicesRunning = 0,
        stopped = 0, leases = 0, online = 0, rules = 0, rulesOff = 0, statics = #(d.statics or {}),
        overrides = #(d.overrides or {}), arp = #(d.arp or {}), peers = 0, peersOnline = 0 }
    for __, g in ipairs(d.gateways or {}) do
        c.gateways = c.gateways + 1
        if g.state ~= "down" then c.gatewaysUp = c.gatewaysUp + 1 end
    end
    for __, i in ipairs(d.interfaces or {}) do
        if i.enabled then
            c.interfaces = c.interfaces + 1
            if i.up then c.interfacesUp = c.interfacesUp + 1 end
        end
    end
    for __, s in ipairs(d.services or {}) do
        c.services = c.services + 1
        if s.running then c.servicesRunning = c.servicesRunning + 1
        elseif s.enabled then c.stopped = c.stopped + 1 end
    end
    for __, l in ipairs(d.leases or {}) do
        c.leases = c.leases + 1
        if l.online then c.online = c.online + 1 end
    end
    for __, r in ipairs(d.rules or {}) do
        c.rules = c.rules + 1
        if r.disabled then c.rulesOff = c.rulesOff + 1 end
    end
    for __, p in ipairs(d.peers or {}) do
        c.peers = c.peers + 1
        if p.online then c.peersOnline = c.peersOnline + 1 end
    end
    return c
end

--- What needs looking at, worst first: { { kind, item, why } }: gateways down, then with
-- loss or latency, interfaces down (enabled ones), services stopped (enabled ones).
function M.attention(d)
    local out = {}
    for __, g in ipairs(d.gateways or {}) do
        if g.state == "down" then out[#out + 1] = { kind = "gateway", item = g, why = _("Gateway down") } end
    end
    for __, g in ipairs(d.gateways or {}) do
        if g.state == "loss" or g.state == "delay" then out[#out + 1] = { kind = "gateway", item = g, why = M.gatewayText(g) } end
    end
    for __, i in ipairs(d.interfaces or {}) do
        if i.enabled and not i.up then out[#out + 1] = { kind = "interface", item = i, why = _("Interface down") } end
    end
    for __, s in ipairs(d.services or {}) do
        if s.enabled and not s.running then out[#out + 1] = { kind = "service", item = s, why = _("Service stopped") } end
    end
    return out
end

--- "All up", "WAN down", "1 service stopped", "WAN down · 2 services stopped".
function M.summary(d)
    local parts = {}
    local down = {}
    for __, g in ipairs(d.gateways or {}) do if g.state == "down" then down[#down + 1] = g.name end end
    if #down == 1 then parts[#parts + 1] = T(_("%1 down"), down[1])
    elseif #down > 1 then parts[#parts + 1] = T(_("%1 gateways down"), #down) end
    local slow = 0
    for __, g in ipairs(d.gateways or {}) do if g.state == "loss" or g.state == "delay" then slow = slow + 1 end end
    if slow == 1 then parts[#parts + 1] = _("1 gateway degraded")
    elseif slow > 1 then parts[#parts + 1] = T(_("%1 gateways degraded"), slow) end
    local ifs = 0
    for __, i in ipairs(d.interfaces or {}) do if i.enabled and not i.up then ifs = ifs + 1 end end
    if ifs == 1 then parts[#parts + 1] = _("1 interface down")
    elseif ifs > 1 then parts[#parts + 1] = T(_("%1 interfaces down"), ifs) end
    local c = M.counts(d)
    if c.stopped == 1 then parts[#parts + 1] = _("1 service stopped")
    elseif c.stopped > 1 then parts[#parts + 1] = T(_("%1 services stopped"), c.stopped) end
    if #parts == 0 then return _("All up") end
    return table.concat(parts, " · ")
end

--- The launcher tile's line: "All up · 14 devices online", "WAN down".
function M.appsLine(d, configured)
    if not configured then return _("Not set up") end
    if not d or not d.system then return _("Open to read pfSense") end
    local s = M.summary(d)
    if s == _("All up") and d.leases then
        local c = M.counts(d)
        if c.online == 1 then return _("All up · 1 device online") end
        return T(_("All up · %1 devices online"), c.online)
    end
    return s
end

--- The notifications a new read brings, compared with the one before (nil: the first
-- read, which says nothing): { add = { { key, text, kind, id } }, remove = { keys } }.
-- A gateway going down, an enabled interface going down, an enabled service stopping;
-- each goes when it's back.
function M.changes(before, after)
    local out = { add = {}, remove = {} }
    if not before or not after then return out end
    local function track(kind, beforeList, afterList, isUp, text)
        if not beforeList or not afterList then return end
        local was = {}
        for __, x in ipairs(beforeList) do was[x.id] = isUp(x) end
        for __, x in ipairs(afterList) do
            local key = "pfsense:" .. kind .. ":" .. x.id
            local up = isUp(x)
            if was[x.id] == true and up == false then
                table.insert(out.add, { key = key, kind = kind, id = x.id, text = T(text, x.name) })
            elseif was[x.id] == false and up == true then
                table.insert(out.remove, key)
            end
        end
    end
    track("gateway", before.gateways, after.gateways, function(g) return g.state ~= "down" end, _("Gateway down: %1"))
    track("interface", before.interfaces, after.interfaces, function(i)
        if not i.enabled then return nil end
        return i.up
    end, _("Interface down: %1"))
    track("service", before.services, after.services, function(s)
        if not s.enabled then return nil end
        return s.running
    end, _("Service stopped: %1"))
    return out
end

--- What the launcher's search finds (q in lower case), at most 20:
-- { { kind, item, title, sub } }, by name, address or MAC.
function M.search(d, q)
    local out = {}
    if not d or not q or q == "" then return out end
    local function hit(...)
        for __, s in ipairs({ ... }) do
            if type(s) == "string" and s ~= "" and s:lower():find(q, 1, true) then return true end
        end
    end
    local function add(kind, item, sub)
        if #out < 20 then out[#out + 1] = { kind = kind, item = item, title = item.name, sub = sub } end
    end
    for __, g in ipairs(d.gateways or {}) do if hit(g.name, g.monitor) then add("gateway", g, M.gatewayLine(g)) end end
    for __, i in ipairs(d.interfaces or {}) do if hit(i.name, i.key, i.ip, i.hw) then add("interface", i, M.interfaceLine(i)) end end
    for __, s in ipairs(d.services or {}) do if hit(s.name, s.key) then add("service", s, M.serviceState(s)) end end
    for __, l in ipairs(d.leases or {}) do if hit(l.name, l.ip, l.mac, l.descr) then add("lease", l, M.leaseLine(l)) end end
    for __, s in ipairs(d.statics or {}) do if hit(s.name, s.ip, s.mac, s.descr) then add("static", s, M.staticLine(s)) end end
    for __, o in ipairs(d.overrides or {}) do
        if hit(o.fqdn, o.descr, table.concat(o.ips, " "), table.concat(o.aliases, " ")) then add("override", o, M.overrideLine(o)) end
    end
    for __, r in ipairs(d.rules or {}) do if hit(r.descr) then add("rule", r, M.ruleLine(r)) end end
    return out
end

return M
