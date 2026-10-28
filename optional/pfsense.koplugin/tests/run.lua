-- Plain tests for pfsmodel and pfsapi (no KOReader): luajit tests/run.lua
package.path = "./?.lua;" .. package.path

-- pfsapi's JSON: answers by their text (the stand-in network below sends these keys).
local ANSWERS = {}
package.preload.json = function()
    local function enc(v)
        if type(v) ~= "table" then return tostring(v) end
        local keys = {}
        for k, x in pairs(v) do keys[#keys + 1] = tostring(k) .. "=" .. enc(x) end
        table.sort(keys)
        return "{" .. table.concat(keys, ",") .. "}"
    end
    return {
        encode = enc,
        decode = function(s)
            if ANSWERS[s] == nil then error("not JSON") end
            return ANSWERS[s]
        end,
    }
end

local M = require("pfsmodel")
local API = require("pfsapi")

local passed, failed = 0, 0
local function eq(got, want, what)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- the address and the key
eq(M.cleanUrl(" 192.168.1.1 "), "https://192.168.1.1", "url: https added")
eq(M.cleanUrl("https://192.168.1.1/api/v2/"), "https://192.168.1.1", "url: /api/v2 taken off")
eq(M.cleanUrl("http://192.168.1.1:8080"), "http://192.168.1.1:8080", "url: http and port kept")
eq(M.cleanUrl("  "), nil, "url: empty")
eq(M.apiBase("192.168.1.1"), "https://192.168.1.1/api/v2", "api base")
eq(M.masked("abcdef"), "••••ef", "masked")
eq(M.query({ offset = 0, limit = 200, sort_order = "SORT_DESC" }), "limit=200&offset=0&sort_order=SORT_DESC", "query")
eq(M.mac("AA-BB-CC-DD-EE-01"), "aa:bb:cc:dd:ee:01", "mac as pfSense compares them")
eq(M.isMac("aa:bb:cc:dd:ee:01"), true, "a mac")
eq(M.isMac("aa:bb:cc"), false, "not a mac")
eq(M.isIPv4("192.168.1.20"), true, "an address")
eq(M.isIPv4("192.168.1.300"), false, "not an address")
eq(M.ipLess("192.168.1.5", "192.168.1.20"), true, "addresses in number order")
eq(table.concat(M.strings("192.168.1.20, 192.168.1.42"), "|"), "192.168.1.20|192.168.1.42", "strings from commas")

-- sizes and times
eq(M.bytes(820), "820 B", "bytes")
eq(M.bytes(12345), "12.3 KB", "KB")
eq(M.bytes(4500000), "4.5 MB", "MB")
eq(M.bytes(1.2e9), "1.2 GB", "GB")
eq(M.uptime("12 Days 03 Hours 04 Minutes 05 Seconds"), "12 days 3 h", "uptime days")
eq(M.uptime("01 Day 00 Hours 10 Minutes 00 Seconds"), "1 day 0 h", "uptime a day")
eq(M.uptime("02 Hours 04 Minutes 05 Seconds"), "2 h 4 min", "uptime hours")
eq(M.pct(12.4), "12%", "percent")
eq(M.ago(1000, 1000 + 300), "5 min ago", "ago")
local function fakeDate(f) return ({ ["%I:%M %p"] = "02:35 PM", ["%H:%M"] = "14:35" })[f] end
eq(M.clock(0, false, fakeDate), "2:35 PM", "clock 12-hour")

-- gateways' words
eq(M.gatewayState("none", "none"), "online", "pfSense's none is fine")
eq(M.gatewayState("online", ""), "online", "online")
eq(M.gatewayState("down", "down"), "down", "down")
eq(M.gatewayState("none", "highloss"), "loss", "loss in the substatus")
eq(M.gatewayState("delay", ""), "delay", "delay")
eq(M.gatewayState("", ""), "unknown", "nothing known")

-- the lists (null as JSON's own value: not a string or number)
local NULL = function() end
local NOW = 2000000
local raw = {
    system = { platform = "Netgate 1100", uptime = "03 Days 02 Hours 01 Minutes 00 Seconds", cpu_usage = 7.6,
        mem_usage = 31, disk_usage = 12, temp_c = 0, cpu_load_avg = { 0.12, 0.2, 0.3 }, cpu_count = 2 },
    version = { version = "2.8.1-RELEASE" },
    hostname = { hostname = "firewall", domain = "home.example.com" },
    gateways = {
        { name = "WAN_DHCP", monitorip = "1.2.3.4", delay = 12.34, loss = 0, status = "none", substatus = "none" },
        { name = "BACKUP", monitorip = "192.0.2.1", status = "down", substatus = "down" },
    },
    interfaces = {
        { name = "wan", descr = "WAN", enable = true, status = "up", ipaddr = "10.0.0.2", subnet = "24", media = "1000baseT <full-duplex>",
          inbytes = 4500000, outbytes = 1200 },
        { name = "lan", descr = "LAN", enable = true, status = "up", ipaddr = "192.168.1.1", subnet = "24" },
        { name = "opt1", descr = "", enable = true, status = "no carrier" },
        { name = "opt2", descr = "Guest", enable = false, status = "down" },
    },
    services = {
        { name = "unbound", description = "DNS Resolver", enabled = true, status = true },
        { name = "ntpd", description = "NTP clock sync", enabled = true, status = false },
        { name = "openvpn", description = "", enabled = false, status = false },
    },
    leases = {
        { ip = "192.168.1.50", mac = "AA:BB:CC:DD:EE:02", hostname = "nas", ["if"] = "lan", active_status = "static", online_status = "active/online" },
        { ip = "192.168.1.20", mac = "aa:bb:cc:dd:ee:01", hostname = "", ["if"] = "lan", active_status = "active", online_status = "idle/offline", descr = "Printer" },
        { ip = "192.168.1.42", mac = "aa:bb:cc:dd:ee:03", hostname = "laptop", ["if"] = "lan", active_status = "active", online_status = "active/online" },
    },
    arp = {
        { id = 0, ip_address = "192.168.1.50", mac_address = "aa:bb:cc:dd:ee:02", hostname = "?", dnsresolve = "nas.home.example.com", interface = "igc1" },
        { id = 1, ip_address = "192.168.1.5", mac_address = "aa:bb:cc:dd:ee:04", hostname = "", interface = "igc1", permanent = true },
    },
    rules = {
        { id = 0, tracker = 100, type = "pass", interface = { "lan" }, protocol = NULL, source = "lan", destination = NULL, descr = "Default allow LAN", disabled = false },
        { id = 1, tracker = 101, type = "block", interface = { "lan" }, protocol = "tcp", source = "192.168.1.42", destination = NULL,
          destination_port = "443", descr = "", disabled = true },
        { id = 2, tracker = 102, type = "pass", interface = { "wan", "lan" }, floating = true, descr = "Floating", disabled = false },
    },
    statics = {
        { parent_id = "lan", id = 0, mac = "AA:BB:CC:DD:EE:02", ipaddr = "192.168.1.50", hostname = "nas", descr = "" },
        { parent_id = "lan", id = 1, mac = "aa:bb:cc:dd:ee:05", ipaddr = "192.168.1.10", hostname = "", descr = "TV" },
    },
    overrides = {
        { id = 0, host = "nas", domain = "home.example.com", ip = { "192.168.1.50" }, descr = "",
          aliases = { { host = "files", domain = "home.example.com", description = "" } } },
        { id = 1, host = "", domain = "example.com", ip = { "192.168.1.20", "192.168.1.42" }, descr = "Test", aliases = {} },
    },
    peers = {
        { public_key = "AbCdEfGhIjKlMnOp", tunnel_device = "tun_wg0", endpoint = "1.2.3.4:51820", latest_handshake = NOW - 60,
          transfer_rx = 1000, transfer_tx = 2000, descr = "Phone" },
        { public_key = "QrStUvWxYz012345", tunnel_device = "tun_wg0", latest_handshake = 0, descr = "" },
    },
    ovpn = { { vpnid = 1, name = "Road warrior", conns = { { common_name = "pat", remote_host = "1.2.3.4", virtual_addr = "10.0.0.1" } } } },
    skipped = {},
}
local d = M.data(raw, NOW)
eq(d.hostname, "firewall.home.example.com", "hostname with its domain")
eq(d.system.version, "2.8.1-RELEASE", "version")
eq(d.system.temp, nil, "no temperature sensor")
eq(d.system.load[1], 0.12, "load")
eq(d.gateways[1].name, "BACKUP", "gateways by name")
eq(M.gatewayLine(M.find(d, "gateway", "WAN_DHCP")), "Online · 12.3 ms · 0% loss", "gateway line")
eq(d.interfaces[1].key, "wan", "interfaces in pfSense's order")
eq(M.interfaceLine(d.interfaces[1]), "Up · 10.0.0.2/24 · 1000baseT", "interface line")
eq(d.interfaces[3].name, "OPT1", "an interface without a description")
eq(M.interfaceState(d.interfaces[3]), "No cable", "no carrier")
eq(M.interfaceState(d.interfaces[4]), "Disabled", "disabled interface")
eq(M.interfaceState(M.interface({ name = "lan", enable = false, status = "up", ipaddr = "192.168.1.1" })), "Up", "enable false but up and addressed: on")
eq(M.interface({ name = "opt3", enable = false, status = "no carrier", ipaddr = "192.168.1.2" }).enabled, true, "enable false with an address: on")
eq(M.serviceState(M.find(d, "service", "ntpd")), "Stopped", "service stopped")
eq(M.find(d, "service", "openvpn").name, "openvpn", "service without a description")
eq(d.leases[1].name, "laptop", "online leases first, by name")
eq(d.leases[3].name, "Printer", "a lease without a hostname takes its description")
eq(d.leases[2].mac, "aa:bb:cc:dd:ee:02", "lease mac in lower case")
eq(M.leaseLine(d.leases[2]), "192.168.1.50 · Online · Static", "lease line")
eq(d.arp[1].ip, "192.168.1.5", "arp by address")
eq(d.arp[2].hostname, "", "arp ? is no hostname")
eq(d.arp[2].name, "nas.home.example.com", "arp name from DNS")
eq(M.arpLine(d.arp[1]), "aa:bb:cc:dd:ee:04 · igc1 · Permanent", "arp line")
eq(d.rules[1].name, "Default allow LAN", "rule named by its description")
eq(d.rules[2].name, "Block 192.168.1.42 to any:443", "rule without a description")
eq(d.rules[2].tracker, "101", "tracker as text")
eq(M.ruleLine(d.rules[2]), "Disabled · Block · LAN · TCP", "rule line")
eq(M.ruleLine(d.rules[3]), "Pass · Floating · WAN, LAN · any to any", "floating rule line")
eq(d.statics[1].ip, "192.168.1.10", "static mappings by address")
eq(d.statics[2].key, "lan:aa:bb:cc:dd:ee:02", "static key")
eq(M.findStatic(d, "lan", "AA:BB:CC:DD:EE:02").name, "nas", "static by mac")
eq(M.staticFor(d, "aa:bb:cc:dd:ee:03"), nil, "no mapping")
eq(d.overrides[1].fqdn, "example.com", "override without a host")
eq(M.overrideLine(d.overrides[2]), "192.168.1.50 · 1 alias", "override line")
eq(d.overrides[2].aliases[1], "files.home.example.com", "alias as a name")
eq(M.overrideLine(d.overrides[1]), "192.168.1.20, 192.168.1.42 · Test", "override with two addresses")
eq(d.peers[1].name, "Phone", "peers by name")
eq(d.peers[1].online, true, "a recent handshake is connected")
eq(d.peers[2].online, false, "no handshake")
eq(M.peerLine(d.peers[2], NOW), "Never connected", "peer never connected")
eq(M.peerLine(d.peers[1], NOW), "Connected · 1 min ago", "peer line")
eq(#d.ovpn[1].conns, 1, "openvpn connections")

-- logs
local l = M.logLine("Oct 27 14:35:01 firewall dhcpd[1234]: DHCPACK on 192.168.1.20")
eq(l.time, "Oct 27 14:35:01", "log time")
eq(l.text, "dhcpd[1234]: DHCPACK on 192.168.1.20", "log text without the host")
eq(M.logLine({ text = "no time here" }).text, "no time here", "a line without a time")
local f = M.filterLine("Oct 27 14:35:01 firewall filterlog[1]: 5,,,1000000103,igc0,match,block,in,4,0x0,,64,0,0,DF,6,tcp,60,1.2.3.4,10.0.0.2,51000,443,0,S,1,,64240,,mss")
eq(f and f.action, "block", "filter action")
eq(f and f.iface, "igc0", "filter interface")
eq(f and f.proto, "tcp", "filter protocol")
eq(f and f.src, "1.2.3.4:51000", "filter source")
eq(f and f.dst, "10.0.0.2:443", "filter destination")
eq(M.filterLine("Oct 27 14:35:01 firewall sshd[2]: hello"), nil, "not a filter line")

-- the firewall at a glance
local c = M.counts(d)
eq(c.gatewaysUp .. "/" .. c.gateways, "1/2", "gateways up")
eq(c.interfacesUp .. "/" .. c.interfaces, "2/3", "a disabled interface isn't counted")
eq(c.stopped, 1, "a disabled service isn't stopped")
eq(c.online, 2, "devices online")
eq(c.rulesOff, 1, "rules off")
eq(c.peersOnline, 1, "peers connected")
eq(M.summary(d), "BACKUP down · 1 interface down · 1 service stopped", "summary")
local att = M.attention(d)
eq(#att, 3, "attention: the gateway, the interface and the service")
eq(att[1].kind .. ":" .. att[1].item.name, "gateway:BACKUP", "attention: gateways first")
eq(M.appsLine(nil, false), "Not set up", "line: not set up")
eq(M.appsLine(nil, true), "Open to read pfSense", "line: not read")
eq(M.appsLine(d, true), "BACKUP down · 1 interface down · 1 service stopped", "line: problems")
local fine = M.data({ system = {}, gateways = { { name = "WAN", status = "none" } },
    leases = { { ip = "192.168.1.20", mac = "aa:bb:cc:dd:ee:01", online_status = "active/online" } } })
eq(M.appsLine(fine, true), "All up · 1 device online", "line: all up")
eq(M.summary(M.data({ system = {}, gateways = { { name = "WAN", status = "loss" } } })), "1 gateway degraded", "degraded gateway")

-- a status read keeps the lists from before
local status = M.merge(d, M.data({ system = raw.system, gateways = raw.gateways, skipped = {} }))
eq(#status.statics, 2, "merge: the lists kept")
eq(#status.gateways, 2, "merge: the status new")
eq(M.merge(nil, fine), fine, "merge: nothing before")

-- notifications: going down, and back
local function fw(gwUp, svcRunning, ifUp)
    return M.data({ system = {}, gateways = { { name = "WAN", status = gwUp and "none" or "down" } },
        services = { { name = "unbound", description = "DNS Resolver", enabled = true, status = svcRunning } },
        interfaces = { { name = "lan", descr = "LAN", enable = true, status = ifUp and "up" or "no carrier" } } })
end
eq(#M.changes(nil, fw(false, false, false)).add, 0, "first read says nothing")
local ch = M.changes(fw(true, true, true), fw(false, false, false))
eq(#ch.add, 3, "gateway, interface and service gone down")
eq(ch.add[1].key, "pfsense:gateway:WAN", "gateway key")
eq(ch.add[1].text, "Gateway down: WAN", "gateway text")
eq(ch.add[2].text, "Interface down: LAN", "interface text")
eq(ch.add[3].text, "Service stopped: DNS Resolver", "service text")
eq(#M.changes(fw(false, false, false), fw(false, false, false)).add, 0, "still down: nothing new")
ch = M.changes(fw(false, false, false), fw(true, true, true))
eq(table.concat(ch.remove, ","), "pfsense:gateway:WAN,pfsense:interface:lan,pfsense:service:unbound", "back up: notifications go")
local noLists = M.data({ system = {} })
eq(#M.changes(fw(true, true, true), noLists).add, 0, "a read without the lists isn't news")

-- sorting and searching the lists
local function names(list) local o = {} for k, x in ipairs(list) do o[k] = x.name end return table.concat(o, ",") end
eq(names(M.sorted(d.leases, "name")), "laptop,nas,Printer", "leases by name")
eq(names(M.sorted(d.leases, "ip")), "Printer,laptop,nas", "leases by IP address, in number order")
eq(names(M.sorted(d.leases, "ip", true)), "nas,laptop,Printer", "reversed")
eq(names(M.sorted(d.rules, nil, true)), "Floating,Block 192.168.1.42 to any:443,Default allow LAN", "own order, reversed")
eq(d.leases[1].name, "laptop", "sorting leaves the list as read")
eq(names(M.sorted(d.overrides, "ip")), "example.com,nas.home.example.com", "overrides by their first address")
eq(names(M.filter(d.leases, "aa:bb:cc:dd:ee:02")), "nas", "search by MAC address")
eq(names(M.filter(d.leases, "AA-BB-CC-DD-EE-02")), "nas", "a MAC typed with dashes and capitals")
eq(names(M.filter(d.statics, "tv")), "TV", "search the description")
eq(names(M.filter(d.overrides, "files")), "nas.home.example.com", "search an alias")
eq(names(M.filter(d.arp, "192.168.1.5")), "192.168.1.5,nas.home.example.com", "search ARP by address (.50 has it too)")
eq(#M.filter(d.leases, "nothing like it"), 0, "nothing found")
eq(#M.filter(d.leases, nil), 3, "no search: all of them")
local by, rev = M.sortOf(nil, "leases")
eq(by .. tostring(rev), "namefalse", "sorted by name to start with")
by, rev = M.sortOf({ leases = { by = "ip", reverse = true } }, "leases")
eq(by .. tostring(rev), "iptrue", "the saved sort")
eq(M.sortOf({ leases = { by = "bogus" } }, "leases"), "name", "an unknown sort is by name")
eq(#M.LOGS, 6, "every log the API has")

-- the newest log lines, newest first, whichever order pfSense sends them in
local oldFirst = { "Oct 26 23:59:00 a", "Oct 27 08:00:00 b", "Oct 27 14:35:01 c" }
eq(table.concat(M.newest(oldFirst, 2), "|"), "Oct 27 14:35:01 c|Oct 27 08:00:00 b", "oldest first: the last ones, turned round")
local newFirst = { "Oct 27 14:35:01 c", "Oct 27 08:00:00 b", "Oct 26 23:59:00 a" }
eq(table.concat(M.newest(newFirst, 2), "|"), "Oct 27 14:35:01 c|Oct 27 08:00:00 b", "newest first: kept as it is")
eq(#M.newest({}, 100), 0, "an empty log")
eq(M.logTime("2026-10-27T14:35:01+00:00 x") > M.logTime("2026-10-27T08:00:00+00:00 y"), true, "ISO times compare")
eq(M.logTime("no time"), nil, "a line without a time")

-- aliases, NAT, routes, VPN, certificates
local d2 = M.data({
    aliases = { { id = 0, name = "Kids", type = "host", descr = "Kids devices", address = { "192.168.1.42", "192.168.1.20" }, detail = { "Laptop" } } },
    forwards = { { id = 0, interface = "wan", protocol = "tcp", destination = "wanip", destination_port = "443", target = "192.168.1.50",
        local_port = "443", descr = "NAS", disabled = false },
        { id = 1, interface = "wan", protocol = "udp", destination_port = "51820", target = "192.168.1.5", local_port = "51820", disabled = true } },
    outbound = { { id = 0, interface = "wan", source = "192.168.1.0/24", nonat = true } },
    onetoone = { { id = 0, interface = "wan", external = "10.0.0.2", source = "192.168.1.50" } },
    routes = { { id = 0, network = "10.0.0.0/24", gateway = "WAN_DHCP", disabled = true } },
    wgpeers = { { id = 3, publickey = "AbCd1234", enabled = false, tun = "tun_wg0", descr = "Phone" } },
    ovpnconns = { { parent_id = 1, id = 0, common_name = "pat", remote_host = "1.2.3.4", connect_time_unix = 1000 } },
    ipsec = { { con_id = "con1", state = "ESTABLISHED", remote_host = "1.2.3.4" } },
    certs = { { id = 0, descr = "Web", valid_days_left = 90 }, { id = 1, descr = "VPN", valid_days_left = 5 }, { id = 2, descr = "Old", valid_days_left = -2 } },
    defaultgw = { defaultgw4 = "WAN_DHCP", defaultgw6 = "" }, natmode = { mode = "hybrid" } })
eq(M.aliasLine(d2.aliases[1]), "Hosts · 2 entries · Kids devices", "alias line")
eq(d2.aliases[1].entries[1].detail, "Laptop", "an entry's description")
eq(d2.aliases[1].entries[2].detail, "", "an entry without one")
eq(d2.forwards[1].name, "NAS", "port forward by its description")
eq(d2.forwards[2].name, "any:51820 to 192.168.1.5:51820", "port forward without one")
eq(M.natLine(d2.forwards[1]), "WAN · TCP · wanip:443 → 192.168.1.50:443", "port forward line")
eq(M.natLine(d2.forwards[2]):sub(1, 8), "Disabled", "disabled first")
eq(M.natLine(d2.outbound[1]), "WAN · 192.168.1.0/24: no NAT", "outbound line")
eq(M.natLine(d2.onetoone[1]), "WAN · 10.0.0.2 ↔ 192.168.1.50", "1:1 line")
eq(M.natMode(d2.natmode), "Hybrid", "outbound mode")
eq(M.routeLine(d2.routes[1]), "Disabled · 10.0.0.0/24 via WAN_DHCP", "route line")
eq(M.find(d2, "wgpeer", "AbCd1234").num, 3, "WireGuard peer by its key, with its place")
eq(d2.ovpnconns[1].key, "1:0", "an OpenVPN connection's key")
eq(d2.ipsec[1].up, true, "IPsec established")
eq(d2.defaultgw.inet, "WAN_DHCP", "default gateway")
eq(d2.certs[1].name, "Old", "certificates soonest first")
eq(M.certLine(d2.certs[1]), "Expired 2 days ago", "expired")
eq(M.certLine(d2.certs[2]), "Expires in 5 days", "expires soon")
eq(#M.attention(d2), 2, "two certificates need attention")
eq(M.summary(d2), "2 certificates expiring", "in the summary too")
local function certs(days) return M.data({ certs = { { id = 0, descr = "Web", valid_days_left = days } } }) end
local cc = M.changes(certs(20), certs(14))
eq(cc.add[1] and cc.add[1].text, "Certificate expires soon: Web", "a certificate coming close: a notification")
eq(M.changes(certs(5), certs(90)).remove[1], "pfsense:cert:0", "renewed: it goes")
eq(M.search(d2, "192.168.1.20")[1].kind, "alias", "search finds an alias by an entry")
eq(M.search(d2, "nas")[1].kind, "forward", "search finds a port forward")
local merged = M.merge(d2, M.data({ system = {} }))
eq(merged.defaultgw.inet, "WAN_DHCP", "a status read keeps the default gateway")
eq(#merged.forwards, 2, "and the NAT rules")

-- search
eq(#M.search(d, "nas"), 3, "search: the lease, the mapping and the override")
eq(M.search(d, "aa:bb:cc:dd:ee:05")[1].kind, "static", "search by mac")
eq(M.search(d, "dns resolver")[1].kind, "service", "search services")
eq(M.search(d, "files")[1].kind, "override", "search by alias")
eq(#M.search(d, ""), 0, "empty search")

-- the API: what each answer means (a stand-in network)
local sent = {}
local function net(answers)
    return function(method, url, headers, body)
        table.insert(sent, { method = method, url = url, headers = headers, body = body })
        for __, a in ipairs(answers) do
            if (not a.method or a.method == method) and url:find(a[1]) then return a[2], a[3] end
        end
        return "connection refused", ""
    end
end
ANSWERS['{"system"}'] = { code = 200, status = "ok", data = { platform = "pfSense", cpu_usage = 5 } }
ANSWERS['{"version"}'] = { code = 200, data = { version = "2.8.1-RELEASE" } }
ANSWERS['{"gw"}'] = { code = 200, data = { { name = "WAN", status = "none" } } }
ANSWERS['{"empty"}'] = { code = 200, data = {} }
ANSWERS['{"ok"}'] = { code = 200, status = "ok", data = NULL }
ANSWERS['{"bad"}'] = { code = 400, status = "bad request", message = "Field `ipaddr` must be a valid IPv4 address." }
ANSWERS['{"unauth"}'] = { code = 401, status = "unauthorized", message = "Authentication failed" }
ANSWERS['{"rule100"}'] = { code = 200, data = { id = 1, tracker = 100 } }
ANSWERS['{"static"}'] = { code = 200, data = { parent_id = "lan", id = 0, mac = "AA:BB:CC:DD:EE:02" } }
ANSWERS['{"services"}'] = { code = 200, data = { { id = 0, name = "unbound" }, { id = 3, name = "ntpd" } } }
ANSWERS['{"certs"}'] = { code = 200, data = { { id = 0, descr = "webConfigurator", valid_days_left = 3,
    valid_until = "Oct 31 2026", prv = "PRIVATE KEY", crt = "CERTIFICATE" } } }
ANSWERS['{"alias"}'] = { code = 200, data = { id = 2, name = "Kids", address = { "192.168.1.42" } } }
ANSWERS['{"fwd"}'] = { code = 200, data = { id = 0, interface = "wan", target = "192.168.1.50", local_port = "443",
    destination_port = "443", descr = "NAS" } }
ANSWERS['{"states"}'] = { code = 200, data = { { interface = "lan", protocol = "tcp", source = "192.168.1.42:51000",
    destination = "1.2.3.4:443", state = "ESTABLISHED:ESTABLISHED", bytes_total = 4096 } } }
ANSWERS['{"pong"}'] = { code = 200, data = { output = "3 packets transmitted, 3 received", result_code = 0 } }
-- (a full page of 200, then the rest)
local page1 = {}
for i = 1, 200 do page1[i] = { id = i - 1, ip = "192.168.1.20", mac = "aa:bb:cc:dd:ee:01" } end
ANSWERS['{"page1"}'] = { code = 200, data = page1 }
ANSWERS['{"page2"}'] = { code = 200, data = { { id = 200 } } }

local api = API.new({ url = "192.168.1.1", key = "s3cret" }, net({
    { "/status/system", 200, '{"system"}' },
    { "/system/version", 200, '{"version"}' },
    { "/system/hostname", 404, "" },
    { "/status/gateways", 200, '{"gw"}' },
    { "/status/interfaces", 200, '{"empty"}' },
    { "/status/services", 200, '{"services"}' },
    { "/status/dhcp_server/leases%?limit=200&offset=0", 200, '{"page1"}' },
    { "/status/dhcp_server/leases%?limit=200&offset=200", 200, '{"page2"}' },
    { "/diagnostics/arp_table", 403, '{"unauth"}' },
    { "/firewall/rules", 200, '{"empty"}' },
    { "/services/dhcp_server/static_mappings", 200, '{"empty"}' },
    { "/services/dns_resolver/host_overrides", 200, '{"empty"}' },
    { "/status/wireguard/peers", 424, '{"bad"}' },
    { "/status/openvpn/servers", 200, '{"empty"}' },
    { "/firewall/aliases", 200, '{"empty"}' },
    { "/firewall/nat/port_forward%?id=0", 200, '{"fwd"}', method = "GET" },
    { "/firewall/nat/port_forward$", 200, '{"ok"}', method = "PATCH" },
    { "/firewall/nat/", 200, '{"empty"}', method = "GET" },
    { "/routing/", 200, '{"empty"}', method = "GET" },
    { "/vpn/wireguard/peers", 424, '{"bad"}' },
    { "/status/openvpn/", 200, '{"empty"}' },
    { "/status/ipsec/sas", 200, '{"empty"}' },
    { "/system/certificates", 200, '{"certs"}' },
    { "/services/acme/certificates", 424, '{"bad"}' },
    { "/firewall/alias%?id=2", 200, '{"alias"}', method = "GET" },
    { "/firewall/alias$", 200, '{"ok"}', method = "PATCH" },
    { "/firewall/states", 200, '{"states"}', method = "GET" },
    { "/firewall/states", 200, '{"ok"}', method = "DELETE" },
    { "/diagnostics/ping", 200, '{"pong"}', method = "POST" },
    { "/firewall/rule%?id=1", 200, '{"rule100"}', method = "GET" },
    { "/firewall/rule$", 200, '{"ok"}', method = "PATCH" },
    { "/firewall/apply", 200, '{"ok"}' },
    { "/services/dhcp_server/static_mapping%?id=0&parent_id=lan", 200, '{"static"}', method = "GET" },
    { "/services/dhcp_server/static_mapping", 400, '{"bad"}', method = "PATCH" },
    { "/status/service$", 200, '{"ok"}', method = "POST" },
}))
local all = api:readAll()
eq(sent[1].headers["X-API-Key"], "s3cret", "the key in its header")
eq(sent[1].url, "https://192.168.1.1/api/v2/status/system", "the address with /api/v2")
eq(all and all.version.version, "2.8.1-RELEASE", "version read")
eq(all and all.hostname, nil, "no hostname is fine")
eq(all and #all.leases, 201, "every page of a list")
eq(all and all.skipped.arp, "forbidden", "a list the key can't read is skipped")
eq(all and all.skipped.peers, "missing", "a package that isn't there is skipped")
eq(all and all.certs[1].descr, "webConfigurator", "a certificate's name")
eq(all and all.certs[1].prv, nil, "a certificate's private key never leaves the child")
eq(all and all.certs[1].crt, nil, "nor the certificate itself")
eq(all and all.skipped.acme, "missing", "no ACME package: skipped")
sent = {}
local st = api:readAll({ status = true })
eq(st and st.leases, nil, "status only: no lists")
eq(#sent, 6, "status only: six requests")

-- aliases, NAT, states, ping
sent = {}
eq(api:setAlias(2, "Kids", { "192.168.1.42", "192.168.1.20" }, { "", "Tablet" }), true, "alias changed and applied")
eq(sent[2].body, "{address={1=192.168.1.42,2=192.168.1.20},detail={1=,2=Tablet},id=2}", "the whole list of entries")
eq(sent[3].url, "https://192.168.1.1/api/v2/firewall/apply", "then the firewall applied")
eq(select(2, api:setAlias(2, "Guests", {}, {})), "changed", "another alias at that place")
local fsig = { interface = "wan", target = "192.168.1.50", local_port = "443", destination_port = "443", descr = "NAS" }
sent = {}
eq(api:setNat("forward", 0, fsig, false), true, "port forward off")
eq(sent[2].body, "{disabled=true,id=0}", "off is disabled")
fsig.target = "192.168.1.20"
eq(select(2, api:setNat("forward", 0, fsig, true)), "changed", "a different port forward at that place")
sent = {}
local st2 = api:states("192.168.1.42")
eq(st2 and #st2, 1, "a device's connections, the same one only once")
eq(sent[1].url, "https://192.168.1.1/api/v2/firewall/states?limit=200&source__startswith=192.168.1.42%3A", "from its address (not .420)")
eq(sent[2].url:find("destination__startswith=192.168.1.42%3A", 1, true) ~= nil, true, "and to it")
sent = {}
eq(api:killStates("192.168.1.42"), true, "connections closed")
eq(sent[1].method, "DELETE", "by a query")
local pong = api:pingHost("1.2.3.4")
eq(pong and pong.ok, true, "ping answered")

sent = {}
eq(api:setRule(1, "100", false), true, "rule changed and applied")
eq(sent[2].method .. " " .. sent[2].body, "PATCH {disabled=true,id=1}", "rule off is disabled")
eq(sent[3].url, "https://192.168.1.1/api/v2/firewall/apply", "then applied")
eq(select(2, api:setRule(1, "999", true)), "changed", "another rule at that place: not changed")

eq(select(2, api:editStatic("lan", 0, "aa:bb:cc:dd:ee:02", { ip = "x" })), "Field `ipaddr` must be a valid IPv4 address.", "pfSense's message")
eq(select(2, api:editStatic("lan", 0, "aa:bb:cc:dd:ee:09", { ip = "192.168.1.5" })), "changed", "a mapping that moved")

sent = {}
eq(api:service("ntpd", "restart"), true, "service by its name")
eq(sent[2].body, "{action=restart,id=3}", "service's id from the list")
eq(select(2, api:service("gone", "start")), "changed", "a service that isn't there")

local function one(status, body)
    return API.new({ url = "192.168.1.1", key = "k" }, function() return status, body end)
end
eq(select(2, one(401, '{"unauth"}'):readAll()), "signin", "401 is the key")
eq(select(2, one(403, ""):readAll()), "forbidden:api-v2-status-system-get", "403 names the privilege")
eq(select(2, one(200, "<!DOCTYPE html><html>"):readAll()), "notapi", "the web interface isn't the API")
eq(select(2, one("timeout", nil):readAll()), "timeout", "the network's words")
eq(one(401, '{"unauth"}'):ping(), true, "ping: unauthorized is an answer")
eq(select(2, one(404, "<html>"):ping()), "notapi", "ping: not the API")
eq(select(2, one(200, "<html><body>pfSense"):ping()), "notapi", "ping: the login page")

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
