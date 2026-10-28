--[[--
pfSense's REST API (the pfSense-pkg-RESTAPI package, v2: the one its Swagger
page shows at /api/v2/documentation): JSON over HTTPS, with an API key sent as
`X-API-Key: <key>`. Answers come wrapped as { code, status, response_id,
message, data }.

Everything here blocks: it runs in a child process (pfsbg.lua), never on
KOReader's loop. Answers come back as plain tables.

Why something failed, as the plugin reads it: "signin" (401, the key was
refused), "forbidden" (403, the key's user lacks the privilege; the caller
knows which), "notfound" (404), "missing" (424, a package it needs isn't
installed, such as WireGuard), "changed" (the object isn't the one it was:
the list moved since it was read), "notapi" (an answer that isn't the API's,
such as the web interface's page), or the network's own words ("timeout",
"connection refused"…).

An object's `id` is its place in its list, so each change first reads the
object again and checks it's still the one meant.
]]

local JSON = require("json")

local M = require("pfsmodel")

local API = {}
API.__index = API

--- cfg: { url, key }; request: (method, url, headers, body, timeout) -> status or
-- error, body (KOReader's socket.http by default; the tests pass their own).
function API.new(cfg, request)
    return setmetatable({ base = M.apiBase(cfg.url), key = cfg.key, send = request or API.http }, API)
end

--- KOReader's network: (status or error, body). HTTPS through KOReader's luasec, which
-- takes pfSense's own (self-signed) certificate.
function API.http(method, url, headers, body, timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    local request = { url = url, method = method, headers = headers or {}, sink = ltn12.sink.table(sink) }
    if body then
        request.source = ltn12.source.string(body)
        request.headers["Content-Length"] = tostring(#body)
    end
    timeout = timeout or 20
    socketutil:set_timeout(math.min(timeout, 10), timeout)
    local ok, code = pcall(function() return socket.skip(1, http.request(request)) end)
    socketutil:reset_timeout()
    if not ok then code = tostring(code) end
    return code, table.concat(sink)
end

local function looksLikeHtml(s)
    if type(s) ~= "string" then return false end
    local head = s:sub(1, 200):lower()
    return head:find("<!doctype html", 1, true) ~= nil or head:find("<html", 1, true) ~= nil
end

--- One request to path (after /api/v2): the answer's data (true when it has none), or nil and why.
function API:request(method, path, params, body, timeout)
    local url = self.base .. path
    local q = params and M.query(params) or ""
    if q ~= "" then url = url .. "?" .. q end
    local headers = { ["X-API-Key"] = self.key or "", Accept = "application/json" }
    local data
    if body then
        data = JSON.encode(body)
        headers["Content-Type"] = "application/json"
    end
    local status, text = self.send(method, url, headers, data, timeout)
    if type(status) ~= "number" then return nil, tostring(status or "no answer") end
    if looksLikeHtml(text) or (status >= 300 and status < 400) then return nil, "notapi" end
    if status == 401 then return nil, "signin" end
    if status == 403 then return nil, "forbidden" end
    if status == 404 then return nil, "notfound" end
    if status == 424 then return nil, "missing" end
    local okJ, t = pcall(JSON.decode, text or "")
    if not okJ or type(t) ~= "table" then
        if status >= 400 then return nil, "HTTP " .. status end
        return nil, "notapi"
    end
    if status >= 400 then
        local msg = M.str(t.message)
        return nil, msg ~= "" and msg or ("HTTP " .. status)
    end
    local d = t.data
    if type(d) ~= "table" then return true end
    return d
end

--- Every page of a list: its items, or nil and why.
function API:all(path, extra)
    local items, offset = {}, 0
    for __ = 1, 20 do
        local params = { limit = M.PAGE_SIZE, offset = offset }
        for k, v in pairs(extra or {}) do params[k] = v end
        local d, why = self:request("GET", path, params)
        if not d then return nil, why end
        local batch = type(d) == "table" and d or {}
        for __, x in ipairs(batch) do items[#items + 1] = x end
        if #batch < M.PAGE_SIZE then return items end
        offset = offset + #batch
    end
    return items
end

--- Whether the REST API answers at all (with no key: its "unauthorized" is an answer):
-- true, or false and why.
function API:ping()
    local status, text = self.send("GET", self.base .. "/system/version", { Accept = "application/json" }, nil, 10)
    if type(status) ~= "number" then return false, tostring(status or "no answer") end
    if looksLikeHtml(text) then return false, "notapi" end
    if status == 404 then return false, "notapi" end
    local okJ, t = pcall(JSON.decode, text or "")
    if okJ and type(t) == "table" and (t.code ~= nil or t.status ~= nil) then return true end
    return false, "notapi"
end

-- What each list is read from, and the privilege a 403 means its key's user lacks.
API.LISTS = {
    gateways = { "/status/gateways", "api-v2-status-gateways-get" },
    interfaces = { "/status/interfaces", "api-v2-status-interfaces-get" },
    services = { "/status/services", "api-v2-status-services-get" },
    leases = { "/status/dhcp_server/leases", "api-v2-status-dhcp-server-leases-get" },
    arp = { "/diagnostics/arp_table", "api-v2-diagnostics-arp-table-get" },
    rules = { "/firewall/rules", "api-v2-firewall-rules-get" },
    statics = { "/services/dhcp_server/static_mappings", "api-v2-services-dhcp-server-static-mappings-get" },
    overrides = { "/services/dns_resolver/host_overrides", "api-v2-services-dns-resolver-host-overrides-get" },
    peers = { "/status/wireguard/peers", "api-v2-status-wireguard-peers-get" },
    ovpn = { "/status/openvpn/servers", "api-v2-status-openvpn-servers-get" },
    aliases = { "/firewall/aliases", "api-v2-firewall-aliases-get" },
    forwards = { "/firewall/nat/port_forwards", "api-v2-firewall-nat-port-forwards-get" },
    outbound = { "/firewall/nat/outbound/mappings", "api-v2-firewall-nat-outbound-mappings-get" },
    onetoone = { "/firewall/nat/one_to_one/mappings", "api-v2-firewall-nat-one-to-one-mappings-get" },
    gwconfig = { "/routing/gateways", "api-v2-routing-gateways-get" },
    gwgroups = { "/routing/gateway/groups", "api-v2-routing-gateway-groups-get" },
    routes = { "/routing/static_routes", "api-v2-routing-static-routes-get" },
    wgpeers = { "/vpn/wireguard/peers", "api-v2-vpn-wireguard-peers-get" },
    ovpnconns = { "/status/openvpn/server/connections", "api-v2-status-openvpn-server-connections-get" },
    ovpnclients = { "/status/openvpn/clients", "api-v2-status-openvpn-clients-get" },
    ipsec = { "/status/ipsec/sas", "api-v2-status-ipsec-sas-get" },
    -- (each certificate's name and dates only: its private key and certificate stay in the child)
    certs = { "/system/certificates", "api-v2-system-certificates-get", keep = { "id", "descr", "refid", "type",
        "valid_from", "valid_until", "valid_days_left" } },
    acme = { "/services/acme/certificates", "api-v2-services-acme-certificates-get", keep = { "id", "name",
        "descr", "status", "renewafter" } },
}
API.STATUS = { "gateways", "interfaces", "services" }
API.MORE = { "leases", "arp", "rules", "statics", "overrides", "peers", "ovpn", "aliases", "forwards", "outbound",
    "onetoone", "gwconfig", "gwgroups", "routes", "wgpeers", "ovpnconns", "ovpnclients", "ipsec", "certs", "acme" }

--- Only the fields in keep of each item (a list's private keys never leave the child process).
local function only(list, keep)
    if not keep then return list end
    local out = {}
    for k, x in ipairs(list) do
        local t = {}
        if type(x) == "table" then for __, f in ipairs(keep) do t[f] = x[f] end end
        out[k] = t
    end
    return out
end

--- What the app shows: { system, version, <lists>, skipped }, or nil and why (only when the
-- system's status can't be read). parts: { status = true, lists = true } (both by default).
-- Lists the key may not read (or this pfSense doesn't have) are left out, named in skipped.
function API:readAll(parts)
    parts = parts or { status = true, lists = true }
    local out = { skipped = {} }
    local why
    out.system, why = self:request("GET", "/status/system")
    if not out.system then return nil, why == "forbidden" and "forbidden:api-v2-status-system-get" or why end
    out.version = self:request("GET", "/system/version") or nil
    out.hostname = self:request("GET", "/system/hostname") or nil
    if parts.lists then
        out.defaultgw = self:request("GET", "/routing/gateway/default") or nil
        out.natmode = self:request("GET", "/firewall/nat/outbound/mode") or nil
    end
    local names = {}
    if parts.status then for __, n in ipairs(API.STATUS) do names[#names + 1] = n end end
    if parts.lists then for __, n in ipairs(API.MORE) do names[#names + 1] = n end end
    for __, name in ipairs(names) do
        local t, w = self:all(API.LISTS[name][1])
        if t then
            out[name] = only(t, API.LISTS[name].keep)
        elseif w == "forbidden" or w == "notfound" or w == "missing" then
            out.skipped[name] = w
        else
            return nil, w
        end
    end
    return out
end

--- The installed packages, with updates ({ { name, installed_version, latest_version,
-- update_available } }), or nil and why. Slow: pfSense asks its package server.
function API:packages()
    return self:all("/system/packages")
end

--- A log's lines as pfSense keeps them (kind: "system" or "firewall"), or nil and why. All of
-- them: a log line's id is only its place in the file, which the API won't sort by ("sort_by must
-- be a valid field"), and it doesn't say how many there are; pfSense keeps its logs short (it
-- rotates them), and pfsmodel.newest keeps the last ones.
function API:log(kind)
    local d, why = self:request("GET", "/status/logs/" .. kind, { limit = 0 }, nil, 40)
    if not d then return nil, why end
    return type(d) == "table" and d or {}
end

--- A service started, stopped or restarted (action), found by its internal name.
function API:service(name, action)
    local list, why = self:request("GET", "/status/services", { limit = 0 })
    if not list then return nil, why end
    for __, s in ipairs(type(list) == "table" and list or {}) do
        if M.str(s.name) == name then
            return self:request("POST", "/status/service", nil, { id = s.id, action = action }, 40)
        end
    end
    return nil, "changed"
end

--- A firewall rule on or off (checked by its tracker), then the rules applied.
function API:setRule(id, tracker, on)
    local r, why = self:request("GET", "/firewall/rule", { id = id })
    if not r then return nil, why end
    if type(r) ~= "table" or M.str(r.tracker) ~= M.str(tracker) then return nil, "changed" end
    local ok
    ok, why = self:request("PATCH", "/firewall/rule", nil, { id = id, disabled = not on })
    if not ok then return nil, why end
    return self:request("POST", "/firewall/apply", nil, {}, 40)
end

--- A Wake-on-LAN packet to a MAC address on an interface (its internal name, such as "lan").
function API:wake(iface, mac)
    return self:request("POST", "/services/wake_on_lan/send", nil, { interface = iface, mac_addr = mac })
end

local STATIC = "/services/dhcp_server/static_mapping"

--- Whether a static mapping is still the one with this MAC: true, or nil and why.
function API:checkStatic(parent, id, mac)
    local s, why = self:request("GET", STATIC, { parent_id = parent, id = id })
    if not s then return nil, why == "notfound" and "changed" or why end
    if type(s) ~= "table" or M.mac(s.mac) ~= M.mac(mac) then return nil, "changed" end
    return true
end

--- A new DHCP static mapping (fields: parent, mac, ip, hostname, descr), then DHCP applied.
function API:addStatic(f)
    local ok, why = self:request("POST", STATIC, nil, { parent_id = f.parent, mac = f.mac, ipaddr = f.ip,
        hostname = f.hostname, descr = f.descr })
    if not ok then return nil, why end
    return self:request("POST", "/services/dhcp_server/apply", nil, {}, 40)
end

--- A static mapping changed (fields: ip, hostname, descr; mac: the one it must have).
function API:editStatic(parent, id, mac, fields)
    local ok, why = self:checkStatic(parent, id, mac)
    if not ok then return nil, why end
    local body = { parent_id = parent, id = id }
    if fields.ip ~= nil then body.ipaddr = fields.ip end
    if fields.hostname ~= nil then body.hostname = fields.hostname end
    if fields.descr ~= nil then body.descr = fields.descr end
    ok, why = self:request("PATCH", STATIC, nil, body)
    if not ok then return nil, why end
    return self:request("POST", "/services/dhcp_server/apply", nil, {}, 40)
end

function API:deleteStatic(parent, id, mac)
    local ok, why = self:checkStatic(parent, id, mac)
    if not ok then return nil, why end
    ok, why = self:request("DELETE", STATIC, { parent_id = parent, id = id })
    if not ok then return nil, why end
    return self:request("POST", "/services/dhcp_server/apply", nil, {}, 40)
end

local OVERRIDE = "/services/dns_resolver/host_override"

--- Whether a host override is still the one for host.domain: true, or nil and why.
function API:checkOverride(id, host, domain)
    local o, why = self:request("GET", OVERRIDE, { id = id })
    if not o then return nil, why == "notfound" and "changed" or why end
    if type(o) ~= "table" or M.str(o.host) ~= host or M.str(o.domain) ~= domain then return nil, "changed" end
    return true
end

local function overrideBody(f)
    local body = {}
    if f.host ~= nil then body.host = f.host end
    if f.domain ~= nil then body.domain = f.domain end
    if f.ips ~= nil then body.ip = f.ips end
    if f.descr ~= nil then body.descr = f.descr end
    if f.aliases ~= nil then
        body.aliases = {}
        for __, a in ipairs(f.aliases) do
            local h, dom = a:match("^([^.]+)%.(.+)$")
            table.insert(body.aliases, { host = h or a, domain = dom or "", description = "" })
        end
    end
    return body
end

--- A new DNS Resolver host override (fields: host, domain, ips, descr, aliases), then applied.
function API:addOverride(f)
    local ok, why = self:request("POST", OVERRIDE, nil, overrideBody(f))
    if not ok then return nil, why end
    return self:request("POST", "/services/dns_resolver/apply", nil, {}, 40)
end

function API:editOverride(id, host, domain, fields)
    local ok, why = self:checkOverride(id, host, domain)
    if not ok then return nil, why end
    local body = overrideBody(fields)
    body.id = id
    ok, why = self:request("PATCH", OVERRIDE, nil, body)
    if not ok then return nil, why end
    return self:request("POST", "/services/dns_resolver/apply", nil, {}, 40)
end

function API:deleteOverride(id, host, domain)
    local ok, why = self:checkOverride(id, host, domain)
    if not ok then return nil, why end
    ok, why = self:request("DELETE", OVERRIDE, { id = id })
    if not ok then return nil, why end
    return self:request("POST", "/services/dns_resolver/apply", nil, {}, 40)
end

--- An ARP entry taken out (checked by its address; it comes back when the device talks again).
function API:deleteArp(id, ip)
    local e, why = self:request("GET", "/diagnostics/arp_table/entry", { id = id })
    if not e then return nil, why == "notfound" and "changed" or why end
    if type(e) ~= "table" or M.str(e.ip_address) ~= ip then return nil, "changed" end
    return self:request("DELETE", "/diagnostics/arp_table/entry", { id = id })
end

-- ------------------------------------------------------------------ aliases, NAT, states, ping

--- A firewall alias's entries changed: its addresses (and each one's description) as a whole,
-- checked by its name (unique), then the firewall applied.
function API:setAlias(id, name, addresses, details)
    local a, why = self:request("GET", "/firewall/alias", { id = id })
    if not a then return nil, why == "notfound" and "changed" or why end
    if type(a) ~= "table" or M.str(a.name) ~= name then return nil, "changed" end
    local ok
    ok, why = self:request("PATCH", "/firewall/alias", nil, { id = id, address = addresses, detail = details })
    if not ok then return nil, why end
    return self:request("POST", "/firewall/apply", nil, {}, 40)
end

-- A NAT rule's paths, and what tells it apart (its id is its place in the list).
API.NAT = {
    forward = { path = "/firewall/nat/port_forward", sig = { "interface", "target", "local_port", "destination_port", "descr" } },
    outbound = { path = "/firewall/nat/outbound/mapping", sig = { "interface", "source", "target", "descr" } },
    onetoone = { path = "/firewall/nat/one_to_one/mapping", sig = { "interface", "external", "source", "descr" } },
}

--- A NAT rule (kind: forward, outbound or onetoone) on or off, checked by its fields
-- (sig: what was read), then the firewall applied.
function API:setNat(kind, id, sig, on)
    local k = API.NAT[kind]
    if not k then return nil, "Unknown kind" end
    local r, why = self:request("GET", k.path, { id = id })
    if not r then return nil, why == "notfound" and "changed" or why end
    if type(r) ~= "table" then return nil, "changed" end
    for __, f in ipairs(k.sig) do
        if M.str(r[f]) ~= M.str(sig[f]) then return nil, "changed" end
    end
    local ok
    ok, why = self:request("PATCH", k.path, nil, { id = id, disabled = not on })
    if not ok then return nil, why end
    return self:request("POST", "/firewall/apply", nil, {}, 40)
end

--- A device's connections (the firewall states from or to an address): the list, at most 200 each way.
function API:states(ip)
    local out, seen = {}, {}
    for __, field in ipairs({ "source__startswith", "destination__startswith" }) do
        local d, why = self:request("GET", "/firewall/states", { limit = 200, [field] = ip .. ":" }, nil, 30)
        if not d then return nil, why end
        for __, x in ipairs(type(d) == "table" and d or {}) do
            local key = M.str(x.interface) .. M.str(x.source) .. M.str(x.destination) .. M.str(x.protocol)
            if not seen[key] then seen[key] = true out[#out + 1] = x end
        end
    end
    return out
end

--- A device's connections closed (the firewall states from and to an address): it has to connect again.
function API:killStates(ip)
    for __, field in ipairs({ "source__startswith", "destination__startswith" }) do
        local ok, why = self:request("DELETE", "/firewall/states", { limit = 0, [field] = ip .. ":" }, nil, 30)
        -- (none to close is fine)
        if not ok and why ~= "notfound" then return nil, why end
    end
    return true
end

--- A ping from pfSense: { output, ok }, or nil and why.
function API:pingHost(host, count)
    local d, why = self:request("POST", "/diagnostics/ping", nil, { host = host, count = count or 3 }, 40)
    if not d then return nil, why end
    if type(d) ~= "table" then d = {} end
    return { output = M.str(d.output), ok = tonumber(d.result_code) == 0 }
end

-- ------------------------------------------------------------------ routing

--- The default gateway (family: "inet" or "inet6"; name: a gateway or group, "" for automatic), applied.
function API:setDefaultGateway(family, name)
    local body = family == "inet6" and { defaultgw6 = name } or { defaultgw4 = name }
    local ok, why = self:request("PATCH", "/routing/gateway/default", nil, body)
    if not ok then return nil, why end
    return self:request("POST", "/routing/apply", nil, {}, 40)
end

--- A static route on or off (checked by its network and gateway), applied.
function API:setRoute(id, network, gateway, on)
    local r, why = self:request("GET", "/routing/static_route", { id = id })
    if not r then return nil, why == "notfound" and "changed" or why end
    if type(r) ~= "table" or M.str(r.network) ~= network or M.str(r.gateway) ~= gateway then return nil, "changed" end
    local ok
    ok, why = self:request("PATCH", "/routing/static_route", nil, { id = id, disabled = not on })
    if not ok then return nil, why end
    return self:request("POST", "/routing/apply", nil, {}, 40)
end

-- ------------------------------------------------------------------ VPN

--- A WireGuard peer on or off (checked by its public key), then WireGuard applied.
function API:setWgPeer(id, key, on)
    local r, why = self:request("GET", "/vpn/wireguard/peer", { id = id })
    if not r then return nil, why == "notfound" and "changed" or why end
    if type(r) ~= "table" or M.str(r.publickey) ~= key then return nil, "changed" end
    local ok
    ok, why = self:request("PATCH", "/vpn/wireguard/peer", nil, { id = id, enabled = on })
    if not ok then return nil, why end
    return self:request("POST", "/vpn/wireguard/apply", nil, {}, 40)
end

--- An OpenVPN server's connection closed (checked by its name and address in the list now).
function API:killOvpn(parent, id, name, remote)
    local list, why = self:all("/status/openvpn/server/connections")
    if not list then return nil, why end
    for __, c in ipairs(list) do
        if tonumber(c.parent_id) == parent and tonumber(c.id) == id then
            if M.str(c.common_name) ~= name or M.str(c.remote_host) ~= remote then return nil, "changed" end
            return self:request("DELETE", "/status/openvpn/server/connection", { parent_id = parent, id = id })
        end
    end
    return nil, "changed"
end

-- ------------------------------------------------------------------ certificates and history

--- An ACME certificate's renewal started (by its name: the ACME package renews it in the background).
function API:renewAcme(name)
    return self:request("POST", "/services/acme/certificate/renew", nil, { certificate = name }, 40)
end

--- The configuration's history, newest first: { { time, description, version } }, or nil and why.
function API:history()
    local list, why = self:all("/diagnostics/config_history/revisions")
    if not list then return nil, why end
    local out = {}
    for __, x in ipairs(list) do
        out[#out + 1] = { time = tonumber(x.time), description = M.str(x.description), version = M.str(x.version) }
    end
    table.sort(out, function(a, b) return (a.time or 0) > (b.time or 0) end)
    return out
end

function API:reboot()
    return self:request("POST", "/diagnostics/reboot", nil, {})
end

--- pfSense's own update (it downloads, installs and restarts on its own).
function API:update()
    return self:request("POST", "/system/update", nil, {}, 40)
end

return API
