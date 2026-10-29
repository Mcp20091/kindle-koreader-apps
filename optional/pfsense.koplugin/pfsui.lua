--[[--
pfSense's screens, drawn as the other apps' pages (pfspage):
  pfSense             the firewall at a glance (version, uptime, CPU, memory,
                      disk, temperature), what needs attention, and the lists
  Gateways            each one's status, latency and loss
  Interfaces          up or down, addresses, traffic
  Services            running or not; a service: Start, Stop, Restart
  Devices             DHCP leases; a device: Wake, Add a static mapping
  ARP table           each entry; an entry: Wake, Remove
  DHCP static mappings  by interface; Add; a mapping: its fields, Wake, Delete
  DNS host overrides  Add; an override: its fields and aliases, Delete
  Firewall rules      by interface; a rule: Enabled
  VPN                 WireGuard peers and OpenVPN servers
  DHCP server         each interface's: on or off, range, DNS, gateway, lease
                      times; address pools and custom options to add or delete
  DNS Resolver        on or off, DNSSEC, forwarding, names from DHCP and VPN
  pf tables           the block lists; Look up an address, Empty a table
  Service watchdog    the services pfSense restarts; add, notify, stop watching
  Cron jobs           add, change, delete
  NTP and SSH         the NTP server on or off and its time servers; SSH on or
                      off and its port
  Logs                the system and firewall logs, newest first
  Packages            installed ones and their updates; Install, Remove
  Settings            how often it's read, notifications, the address and key
While a pfSense page is on top, pfSense is read every so often (Settings >
Read every); nothing is read once it closes.
]]

local Event = require("ui/event")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local KO = require("pfsko")
local M = require("pfsmodel")

local UI = {}

-- The pages open now, oldest first (Home closes them all).
UI.pages = {}

local function Page() return require("pfspage") end
local function PS() return require("pluginshare") end
local function twentyFour() return not G_reader_settings:isTrue("twelve_hour_clock") end

--- The Apps launcher (when it's installed).
function UI.launcher()
    if KO.home() then return end
    local plugin = UI.plugin
    if plugin and plugin.ui and plugin.ui.apps then plugin.ui:handleEvent(Event:new("ShowApps")) end
end

--- Home: every pfSense page closes, then the launcher.
function UI.home()
    local pages = {}
    for i, p in ipairs(UI.pages) do pages[i] = p end
    for i = #pages, 1, -1 do pages[i]:onCloseAllMenus() end
    UI.launcher()
end

--- The page on top, as the plugin's `screen` (the launcher's recent apps bring it back).
function UI.noteScreen()
    if UI.plugin then UI.plugin.screen = UI.pages[#UI.pages] end
end

--- ⋮ on every page: Update pfSense, Reboot, Details, Help; then Recent apps, Light,
-- Night mode, Refresh screen and Settings last.
function UI.more()
    local plugin = UI.plugin
    if not plugin then return end
    local extra = {}
    if plugin:configured() then
        table.insert(extra, { _("Ping"), function() UI.askPing(plugin) end })
        table.insert(extra, { _("Update pfSense"), function() UI.update(plugin) end })
        table.insert(extra, { _("Reboot"), function() UI.reboot(plugin) end })
        table.insert(extra, { _("Details"), function() UI.details(plugin) end })
    end
    table.insert(extra, { _("Help"), function() UI.help() end })
    KO.menu(plugin.ui, extra, function() UI.settings(plugin) end)
end

-- A short signature of a page's items, so a read that changed nothing shown doesn't redraw.
local function signature(items)
    local parts = {}
    local function add(v) if v ~= nil then parts[#parts + 1] = tostring(v) end end
    for __, it in ipairs(items or {}) do
        add(it.band) add(it.text) add(it.sub) add(it.value) add(it.right) add(it.note) add(it.message)
        add(it.toggle) add(it.dot) add(it.line)
        if it.job then add(it.job.state) add(table.concat(it.job.lines or {}, "|")) end
        for __, k in ipairs({ "tiles", "stats", "quick", "chips" }) do
            for __, x in ipairs(it[k] or {}) do add(x.text) add(x.sub) add(x.value) add(x.label) add(x.on) add(x.bar) end
        end
    end
    return table.concat(parts, "\n")
end

--- The pages again from what was read: each makes its items again; only the
-- one on top is redrawn, and only when something it shows changed.
function UI.refreshAll()
    local top = UIManager:getTopmostVisibleWidget()
    for __, p in ipairs(UI.pages) do
        if p.items_fn then
            local items = p.items_fn()
            local sig = signature(items)
            if sig ~= p.sig then
                p.sig = sig
                p.item_table = items
                if p == top then p:redraw() else p:render() end
            end
        end
    end
end

--- A page: items, or a function making them (then ⟳ and each read make them again).
-- opts.live: pfSense is read every so often while it's on top; opts.lists: the lists
-- too (devices, rules, mappings…), not only the status.
local function page(title, items, opts)
    opts = opts or {}
    local fn = type(items) == "function" and items or nil
    local p = Page():new{ title = title, subtitle = opts.subtitle, item_table = fn and fn() or items, items_fn = fn,
        top = opts.top, status = opts.status, on_refresh = opts.on_refresh, bar_buttons = opts.buttons }
    p.sig = signature(p.item_table)
    p.live = opts.live
    p.lists = opts.lists
    UIManager:show(p)
    return p
end

-- ------------------------------------------------------------------ boxes

--- One line of text: cb(text) on Save. opts: { password, description, ok, okIcon }.
local function ask(title, value, cb, opts)
    opts = opts or {}
    local request = KO.request()
    if request then
        return request{ title = title, subtitle = opts.description, text = value or "",
            password = opts.password, typing = true,
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = opts.okIcon or "check", text = opts.ok or _("Save"), primary = true, fn = function(v) cb(v) end },
            } }
    end
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value or "",
        text_type = opts.password and "password" or nil,
        description = opts.description,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = opts.ok or _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText()
                UIManager:close(dialog)
                cb(v)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

--- Whether a page is still open (an answer can come after it closed).
local function alive(p)
    for __, q in ipairs(UI.pages) do if q == p then return true end end
    return false
end

--- An action, with a toast when it didn't work (pfSense is read again either way).
local function act(plugin, name, args, okText, opts)
    plugin:act(name, args, function(ok, text)
        if ok then
            if okText then KO.toast(okText) end
        else
            KO.message(text, _("pfSense"))
        end
    end, opts)
end

-- ------------------------------------------------------------------ reading while open

--- Every so often while one of pfSense's live pages is on top: pfSense again (the lists
-- too when that page shows one).
function UI.poll(plugin)
    if UI.polling then return end
    UI.polling = true
    local function tick()
        if #UI.pages == 0 then
            UI.polling = false
            return
        end
        local top = UIManager:getTopmostVisibleWidget()
        for __, p in ipairs(UI.pages) do
            if p == top and p.live then
                plugin:fetch(nil, p.lists)
                break
            end
        end
        UIManager:scheduleIn(plugin:interval(), tick)
    end
    UIManager:scheduleIn(plugin:interval(), tick)
end

--- The line at the foot: when it was read; the firewall's address.
local function status(plugin)
    local when = plugin:readTime()
    local left
    if plugin:reading() and when == 0 then left = _("Reading…")
    elseif when > 0 then left = T(_("Updated %1"), M.clock(when, twentyFour())) end
    if plugin:lastWhy() and when > 0 then left = T(_("Not answering · last read %1"), M.clock(when, twentyFour())) end
    local url = plugin:cfg().url
    return left, url and url:gsub("^https?://", "") or nil
end

--- What a page shows before anything is read, or when the read failed: a message
-- (and Try again), or nil once there is something to show.
local function notRead(plugin)
    local d = plugin:data()
    if d and d.system then return nil end
    local why = plugin:lastWhy()
    local t = { { message = why and plugin:whyText(why) or _("Reading pfSense…") } }
    if why then
        t[#t + 1] = { tiles = {
            { icon = "refresh-cw", text = _("Try again"), primary = true, fn = function() plugin:fetch(nil, true) end },
            { icon = "sliders-horizontal", text = _("Settings"), fn = function() UI.settings(plugin) end },
        }, cols = 2 }
    end
    return t
end

local function dotOf(on) return on and "on" or "off" end

--- A settings-style row with a value (left out when there's no value).
local function row(t, name, value, callback)
    if (value ~= nil and value ~= "") or callback then
        t[#t + 1] = { setting = true, text = name, value = value ~= "" and value or nil, callback = callback }
    end
end

--- What a thing's page shows when it isn't (or no longer) in what was read.
local function gone(plugin, t)
    local early = notRead(plugin)
    if early then return early end
    t[#t + 1] = { message = _("It isn't in pfSense any more.") }
    return t
end

--- A list the key can't read: why, and which privilege its user needs.
local function notAllowed(plugin, t, name, priv)
    local why = plugin:data().skipped[name]
    if why == "missing" or why == "notfound" then
        t[#t + 1] = { message = _("This pfSense doesn't have it (a package it needs isn't installed).") }
        return t
    end
    t[#t + 1] = { message = _("The API key can't read these.") }
    t[#t + 1] = { note = T(_("Give the key's user the %1 privilege (or page-all) in System > User Manager, then tap ⟳."), priv) }
    return t
end

-- ------------------------------------------------------------------ the main page

local BROWSE = {
    { "gateways", "activity", _("Gateways") },
    { "interfaces", "network", _("Interfaces") },
    { "services", "cpu", _("Services") },
    { "leases", "laptop", _("Devices") },
    { "statics", "tag", _("Static mappings") },
    { "overrides", "globe", _("DNS overrides") },
    { "rules", "shield-check", _("Firewall rules") },
    { "arp", "list", _("ARP table") },
    { "vpn", "key-round", _("VPN") },
    { "aliases", "shield", _("Aliases") },
    { "nat", "arrow-right-left", _("NAT") },
    { "connections", "plug", _("Connections") },
    { "ping", "wifi", _("Ping") },
    { "certs", "lock", _("Certificates") },
    { "history", "history", _("Config history") },
    { "dhcp", "server", _("DHCP server") },
    { "dnsres", "globe", _("DNS Resolver") },
    { "tables", "grid-3x3", _("pf tables") },
    { "watchdog", "eye", _("Service watchdog") },
    { "cron", "calendar", _("Cron jobs") },
    { "ntpssh", "clock", _("NTP and SSH") },
    { "logs", "scroll-text", _("Logs") },
    { "packages", "package", _("Packages") },
}

-- A browse tile's second line when nothing read says more (every tile has one, so they line up).
local BROWSE_SUB = { logs = _("System, firewall, DHCP…"), packages = _("Updates"), vpn = _("WireGuard, OpenVPN, IPsec"),
    aliases = _("Address lists"), nat = _("Port forwards"), connections = _("A device's, to close"), ping = _("From pfSense"),
    certs = _("When they expire"), history = _("Recent changes"), dhcp = _("Ranges, pools, options"), dnsres = _("Its settings"),
    tables = _("Block lists"), watchdog = _("Restarts stopped ones"), cron = _("Scheduled commands"), ntpssh = _("Time servers, SSH") }

--- A browse tile's second line, from what was read.
local function browseSub(d, key, c)
    if d.skipped[key] then return _("Not allowed") end
    if key == "gateways" then return d.gateways and T(_("%1 of %2 up"), c.gatewaysUp, c.gateways) end
    if key == "interfaces" then return d.interfaces and T(_("%1 of %2 up"), c.interfacesUp, c.interfaces) end
    if key == "services" then
        if not d.services then return nil end
        return c.stopped > 0 and T(_("%1 stopped"), c.stopped) or T(_("%1 running"), c.servicesRunning)
    end
    if key == "leases" then return d.leases and T(_("%1 online"), c.online) end
    if key == "statics" then return d.statics and tostring(c.statics) end
    if key == "overrides" then return d.overrides and tostring(c.overrides) end
    if key == "rules" then return d.rules and (c.rulesOff > 0 and T(_("%1 · %2 off"), c.rules, c.rulesOff) or tostring(c.rules)) end
    if key == "arp" then return d.arp and tostring(c.arp) end
    if key == "vpn" then
        if d.peers and #d.peers > 0 then return T(_("%1 of %2 connected"), c.peersOnline, c.peers) end
        if d.ovpn and #d.ovpn > 0 then return T(_("%1 OpenVPN"), #d.ovpn) end
        return nil
    end
    if key == "aliases" then return d.aliases and tostring(#d.aliases) end
    if key == "nat" then
        if not d.forwards then return nil end
        local off = 0
        for __, r in ipairs(d.forwards) do if r.disabled then off = off + 1 end end
        local n = #d.forwards == 1 and _("1 port forward") or T(_("%1 port forwards"), #d.forwards)
        return off > 0 and T(_("%1 · %2 off"), n, off) or n
    end
    if key == "certs" then
        if not d.certs then return nil end
        local soon = 0
        for __, c in ipairs(d.certs) do if M.certSoon(c) then soon = soon + 1 end end
        return soon > 0 and T(_("%1 expiring soon"), soon) or tostring(#d.certs)
    end
    local plugin = UI.plugin
    if key == "watchdog" or key == "cron" then
        local v = plugin and plugin:configData(key)
        return v and tostring(#v)
    end
    if key == "ntpssh" then
        local ssh = plugin and plugin:configData("ssh")
        return ssh and (ssh.enabled and _("SSH on") or _("SSH off"))
    end
    if key == "dhcp" then
        local v = plugin and plugin:configData("dhcp")
        if not v then return nil end
        local on = 0
        for __, x in ipairs(v.servers) do if x.enabled then on = on + 1 end end
        return T(_("%1 of %2 on"), on, #v.servers)
    end
    if key == "dnsres" then
        local v = plugin and plugin:configData("dnsres")
        return v and (v.enabled and _("On") or _("Off"))
    end
    if key == "packages" then
        local list = UI.plugin and UI.plugin:packageList()
        if not list then return nil end
        local n = 0
        for __, p in ipairs(list) do if p.update then n = n + 1 end end
        return n > 0 and T(_("%1 updates"), n) or tostring(#list)
    end
end

function UI.mainItems(plugin)
    local t = {}
    if not plugin:configured() then
        t[#t + 1] = { message = _("pfSense isn't set up yet.") }
        t[#t + 1] = { note = _("You need the REST API package on pfSense, the firewall's address and an API key.") }
        t[#t + 1] = { gap = 10 }
        t[#t + 1] = { tiles = {
            { icon = "key-round", text = _("Set up"), sub = _("Address and key"), primary = true, fn = function() UI.setup(plugin) end },
            { icon = "info", text = _("Help"), sub = _("What you need"), fn = function() UI.help() end },
        }, cols = 2 }
        return t
    end
    local early = notRead(plugin)
    if early then return early end
    local d = plugin:data()
    local s = d.system
    local lines = {}
    if s.version ~= "" then lines[#lines + 1] = T(_("pfSense %1"), s.version) end
    if s.uptime ~= "" then lines[#lines + 1] = T(_("Up %1"), M.uptime(s.uptime)) end
    if s.platform ~= "" then lines[#lines + 1] = s.platform end
    t[#t + 1] = { job = { state = M.summary(d), lines = lines } }
    local stats = {
        { icon = "cpu", label = _("CPU"), value = M.pct(s.cpu) or "–", bar = s.cpu and s.cpu / 100 or nil,
            sub = #s.load > 0 and T(_("Load %1"), string.format("%.2f", s.load[1])) or nil },
        { icon = "activity", label = _("Memory"), value = M.pct(s.mem) or "–", bar = s.mem and s.mem / 100 or nil },
        { icon = "hard-drive", label = _("Disk"), value = M.pct(s.disk) or "–", bar = s.disk and s.disk / 100 or nil },
    }
    if s.temp then
        stats[#stats + 1] = { icon = "thermometer", label = _("Temperature"), value = T(_("%1 °C"), math.floor(s.temp + 0.5)) }
    end
    t[#t + 1] = { stats = stats, cols = #stats }

    local attention = M.attention(d)
    if #attention > 0 then
        t[#t + 1] = { band = _("NEEDS ATTENTION"), right = tostring(#attention) }
        local icons = { gateway = "activity", interface = "network", service = "cpu", cert = "lock" }
        for __, a in ipairs(attention) do
            local x = a.item
            t[#t + 1] = { text = x.name, sub = a.why, icon = icons[a.kind], dot = "off", chevron = true,
                callback = function() UI.item(plugin, a.kind, x.id) end }
        end
    end

    t[#t + 1] = { band = _("BROWSE") }
    local c = M.counts(d)
    local tiles = {}
    for __, b in ipairs(BROWSE) do
        local key = b[1]
        tiles[#tiles + 1] = { icon = b[2], text = b[3], sub = browseSub(d, key, c) or BROWSE_SUB[key] or "",
            fn = function() UI.list(plugin, key) end }
    end
    t[#t + 1] = { tiles = tiles, cols = 2 }
    return t
end

--- pfSense's first page; page "settings": its settings over it.
function UI.show(plugin, which)
    UI.plugin = plugin
    if PS().noteRecent then pcall(PS().noteRecent, "pfsense") end
    -- (already open: back to its first page)
    if UI.pages[1] and UI.pages[1].isMain then
        for k = #UI.pages, 2, -1 do UI.pages[k]:onClose() end
    else
        local p = page(plugin:fwName(), function() return UI.mainItems(plugin) end,
            { top = true, live = true, status = function() return status(plugin) end,
              on_refresh = function() plugin:fetch(nil, true) end })
        p.isMain = true
        p.items_fn = function()
            p.title = plugin:fwName()
            return UI.mainItems(plugin)
        end
    end
    plugin:fetch()
    UI.poll(plugin)
    if which == "settings" then UI.settings(plugin) end
end

--- A page that follows each read (live), with ⟳ reading again (the lists too).
local function listPage(plugin, title, items, lists)
    return page(title, items, { live = true, lists = lists, status = function() return status(plugin) end,
        on_refresh = function() plugin:fetch(nil, true) end })
end

--- One of the browse tiles' pages.
function UI.list(plugin, key)
    local open = { gateways = UI.gateways, interfaces = UI.interfaces, services = UI.services, leases = UI.devices,
        statics = UI.statics, overrides = UI.overrides, rules = UI.rules, arp = UI.arpTable, vpn = UI.vpn,
        logs = UI.logs, packages = UI.packages, aliases = UI.aliases, nat = UI.nat, certs = UI.certs, history = UI.history,
        connections = function(p) UI.askConnections(p) end, ping = function(p) UI.askPing(p) end,
        dhcp = UI.dhcp, dnsres = UI.dnsResolver, tables = UI.tables, watchdog = UI.watchdog, cron = UI.cron, ntpssh = UI.ntpSsh }
    if open[key] then open[key](plugin) end
end

--- One thing's page (from a notification, search or a list), by kind and id.
function UI.item(plugin, kind, id)
    if kind == "gateway" then return UI.gateway(plugin, id) end
    if kind == "interface" then return UI.interface(plugin, id) end
    if kind == "service" then return UI.service(plugin, id) end
    if kind == "lease" then return UI.device(plugin, id) end
    if kind == "arp" then return UI.arpEntry(plugin, id) end
    if kind == "static" then return UI.static(plugin, id) end
    if kind == "override" then return UI.override(plugin, id) end
    if kind == "rule" then return UI.rule(plugin, id) end
    if kind == "alias" then return UI.alias(plugin, id) end
    if kind == "forward" or kind == "outbound" or kind == "onetoone" then return UI.natRule(plugin, kind, id) end
    if kind == "cert" then return UI.certs(plugin) end
end

--- The items of a list page: notRead, or not allowed, or fn(d, t).
local function listItems(plugin, name, priv, fn)
    return function()
        local early = notRead(plugin)
        if early then return early end
        local d = plugin:data()
        local t = {}
        if d.skipped[name] then return notAllowed(plugin, t, name, priv) end
        if not d[name] then
            t[#t + 1] = { message = _("Reading…") }
            return t
        end
        return fn(d, t)
    end
end

-- ------------------------------------------------------------------ searching and sorting lists

-- What each list is searched for now (its key -> the words as typed), and which of its items
-- show (its key -> true: only online or running ones, false: only the others), while KOReader runs.
UI.find = {}
UI.only = {}

-- The lists with something online or not: the chips' words, and whether an item is (d: what was read).
local STATUS = {
    leases = { _("Online"), _("Offline"), function(x) return x.online end },
    statics = { _("Online"), _("Offline"), function(x, d)
        for __, l in ipairs(d.leases or {}) do if l.mac == x.mac then return l.online end end
        return false
    end },
    services = { _("Running"), _("Stopped"), function(x) return x.running end },
}

local function short(s, n)
    if #s <= n then return s end
    return s:sub(1, n - 1) .. "…"
end

--- The row of chips over a list: Search (or the words searched, with Clear), and for a list
-- that sorts, Name, IP address and Reverse. Returns the words searched for, in lower case.
local function controls(plugin, key, t, sortable)
    local q = UI.find[key]
    local chips = {}
    if q and q ~= "" then
        chips[#chips + 1] = { text = T(_("“%1” · Clear"), short(q, 16)), on = true,
            fn = function() UI.find[key] = nil UI.refreshAll() end }
    else
        chips[#chips + 1] = { text = _("Search"), fn = function()
            ask(_("Search"), "", function(v)
                v = trim(v)
                UI.find[key] = v ~= "" and v or nil
                UI.refreshAll()
            end, { ok = _("Search"), okIcon = "search",
                description = _("A name, an IP address, a MAC address or a word of the description.") })
        end }
    end
    local status = STATUS[key]
    if status then
        -- (a tap shows only those; again, all of them)
        local only = UI.only[key]
        chips[#chips + 1] = { text = status[1], on = only == true, fn = function()
            UI.only[key] = only ~= true or nil
            UI.refreshAll()
        end }
        chips[#chips + 1] = { text = status[2], on = only == false, fn = function()
            if only == false then UI.only[key] = nil else UI.only[key] = false end
            UI.refreshAll()
        end }
    end
    if sortable then
        local by, reverse = plugin:sortOf(key)
        local function sortBy(b, r)
            plugin:setSort(key, b, r)
            UI.refreshAll()
        end
        chips[#chips + 1] = { text = _("Name"), on = by == "name", fn = function() sortBy("name", reverse) end }
        chips[#chips + 1] = { text = _("IP address"), on = by == "ip", fn = function() sortBy("ip", reverse) end }
        chips[#chips + 1] = { text = _("Reverse"), on = reverse, fn = function() sortBy(by, not reverse) end }
    end
    t[#t + 1] = { chips = chips }
    return q and q:lower() or nil
end

--- A list as it shows now: sorted as chosen (sortable lists), searched, and only the online (or
-- offline) ones when chosen.
local function shown(plugin, d, key, q)
    local list = M.filter(M.SORTABLE[key] and plugin:sortedList(key) or d[key], q)
    local only, status = UI.only[key], STATUS[key]
    if only == nil or not status then return list end
    local out = {}
    for __, x in ipairs(list) do
        if (status[3](x, d) and true or false) == only then out[#out + 1] = x end
    end
    return out
end

--- What a searched (or filtered) list says when nothing is left.
local function noneFound(t, q)
    t[#t + 1] = { message = q and T(_("Nothing has “%1”."), q) or _("None like that now.") }
end

-- ------------------------------------------------------------------ gateways and interfaces

--- The family (inet or inet6) of a gateway or group by its name, from what was read (inet if not known).
local function familyOf(d, name)
    local g = M.find(d, "gwconfig", name) or M.find(d, "gwgroup", name)
    return g and g.family == "inet6" and "inet6" or "inet"
end

--- Choose the default gateway for a family: a gateway, a group, or automatic.
local function chooseDefault(plugin, family)
    local d = plugin:data()
    if not d then return end
    local options = { { label = _("Automatic"), value = "" } }
    for __, g in ipairs(d.gwconfig or {}) do
        if (g.family == family or g.family == "") and not g.disabled then
            options[#options + 1] = { label = g.descr ~= "" and T("%1 · %2", g.name, g.descr) or g.name, value = g.name }
        end
    end
    for __, g in ipairs(d.gwgroups or {}) do
        if g.family == family or g.family == "" then options[#options + 1] = { label = T(_("%1 (group)"), g.name), value = g.name } end
    end
    local now = d.defaultgw and d.defaultgw[family] or ""
    KO.choose(family == "inet6" and _("Default gateway (IPv6)") or _("Default gateway (IPv4)"), options, now, function(name)
        if name == now then return end
        act(plugin, "default_gw", { family = family, name = name }, name ~= "" and T(_("Default gateway: %1"), name) or _("Default gateway: automatic"),
            { text = _("Changing the default gateway…") })
    end)
end

function UI.gateways(plugin)
    listPage(plugin, _("Gateways"), listItems(plugin, "gateways", "api-v2-status-gateways-get", function(d, t)
        if d.defaultgw then
            t[#t + 1] = { band = _("DEFAULT GATEWAY") }
            t[#t + 1] = { setting = true, text = _("IPv4"), value = d.defaultgw.inet ~= "" and d.defaultgw.inet or _("Automatic"),
                callback = function() chooseDefault(plugin, "inet") end }
            t[#t + 1] = { setting = true, text = _("IPv6"), value = d.defaultgw.inet6 ~= "" and d.defaultgw.inet6 or _("Automatic"),
                callback = function() chooseDefault(plugin, "inet6") end }
        end
        t[#t + 1] = { band = _("GATEWAYS"), right = tostring(#d.gateways) }
        if #d.gateways == 0 then t[#t + 1] = { message = _("No gateways.") } end
        for __, g in ipairs(d.gateways) do
            local isDefault = d.defaultgw and (d.defaultgw.inet == g.name or d.defaultgw.inet6 == g.name)
            t[#t + 1] = { text = g.name, sub = M.gatewayLine(g) .. (isDefault and (" · " .. _("Default")) or ""), icon = "activity",
                dot = dotOf(g.state ~= "down"), chevron = true, callback = function() UI.gateway(plugin, g.id) end }
        end
        if d.gwgroups and #d.gwgroups > 0 then
            t[#t + 1] = { band = _("GATEWAY GROUPS"), right = tostring(#d.gwgroups) }
            for __, g in ipairs(d.gwgroups) do
                local members = {}
                for __, m in ipairs(g.members) do members[#members + 1] = m.tier and T(_("%1 (tier %2)"), m.gateway, m.tier) or m.gateway end
                local isDefault = d.defaultgw and (d.defaultgw.inet == g.name or d.defaultgw.inet6 == g.name)
                t[#t + 1] = { text = g.name, sub = table.concat(members, ", ") .. (isDefault and (" · " .. _("Default")) or ""), icon = "activity" }
            end
        end
        if d.routes and #d.routes > 0 then
            t[#t + 1] = { band = _("STATIC ROUTES"), right = tostring(#d.routes) }
            for __, r in ipairs(d.routes) do
                t[#t + 1] = { toggle = not r.disabled, text = r.name, sub = M.routeLine(r), callback = function()
                    act(plugin, "route_enabled", { id = r.id, network = r.network, gateway = r.gateway, on = r.disabled },
                        r.disabled and _("Route on") or _("Route off"))
                end }
            end
        end
        return t
    end), true)
end

function UI.gateway(plugin, id)
    listPage(plugin, id, function()
        local d = plugin:data()
        local g = d and M.find(d, "gateway", id)
        local t = {}
        if not g then return gone(plugin, t) end
        t[#t + 1] = { band = _("GATEWAY") }
        row(t, _("Status"), M.gatewayText(g))
        row(t, _("Latency"), g.delay and T(_("%1 ms"), string.format("%.1f", g.delay)) or nil)
        row(t, _("Jitter"), g.stddev and T(_("%1 ms"), string.format("%.1f", g.stddev)) or nil)
        row(t, _("Packet loss"), g.loss and T(_("%1%"), string.format("%.0f", g.loss)) or nil)
        row(t, _("Monitor IP"), g.monitor)
        row(t, _("Source IP"), g.source)
        local cfg = M.find(d, "gwconfig", g.name)
        if cfg then
            row(t, _("Interface"), cfg.iface:upper())
            row(t, _("Address"), cfg.gateway)
            row(t, _("Description"), cfg.descr)
        end
        if d.defaultgw then
            local family = familyOf(d, g.name)
            local isDefault = d.defaultgw[family] == g.name
            row(t, _("Default"), isDefault and _("Yes") or _("No"))
            if not isDefault then
                t[#t + 1] = { gap = 8 }
                t[#t + 1] = { tiles = { { icon = "check", text = _("Make default"), primary = true, fn = function()
                    KO.confirm{ title = T(_("Make %1 the default gateway?"), g.name),
                        text = _("Traffic to the internet goes out through it from now on. If it doesn't work, the Kindle may lose the internet too (not the firewall)."),
                        ok = _("Make default"), cancel = _("Cancel"),
                        onOk = function()
                            act(plugin, "default_gw", { family = family, name = g.name }, T(_("Default gateway: %1"), g.name),
                                { text = _("Changing the default gateway…") })
                        end }
                end } }, cols = 2 }
            end
        end
        return t
    end, true)
end

function UI.interfaces(plugin)
    listPage(plugin, _("Interfaces"), listItems(plugin, "interfaces", "api-v2-status-interfaces-get", function(d, t)
        t[#t + 1] = { band = _("INTERFACES"), right = tostring(#d.interfaces) }
        for __, i in ipairs(d.interfaces) do
            t[#t + 1] = { text = i.name, sub = M.interfaceLine(i), icon = "network", chevron = true,
                dot = i.enabled and dotOf(i.up) or nil, callback = function() UI.interface(plugin, i.id) end }
        end
        return t
    end))
end

function UI.interface(plugin, id)
    local d0 = plugin:data()
    local i0 = d0 and M.find(d0, "interface", id)
    listPage(plugin, i0 and i0.name or _("Interface"), function()
        local d = plugin:data()
        local i = d and M.find(d, "interface", id)
        local t = {}
        if not i then return gone(plugin, t) end
        t[#t + 1] = { band = _("INTERFACE") }
        row(t, _("Status"), M.interfaceState(i))
        row(t, _("Name"), i.key)
        row(t, _("Device"), i.hw)
        row(t, _("IPv4 address"), i.ip ~= "" and (i.ip .. (i.subnet ~= "" and ("/" .. i.subnet) or "")) or nil)
        row(t, _("IPv6 address"), i.ipv6 ~= "" and (i.ipv6 .. (i.subnetv6 ~= "" and ("/" .. i.subnetv6) or "")) or nil)
        row(t, _("Gateway"), i.gateway)
        row(t, _("MAC address"), i.mac)
        row(t, _("Media"), i.media)
        row(t, _("MTU"), i.mtu)
        t[#t + 1] = { band = _("TRAFFIC") }
        row(t, _("Data in"), M.bytes(i.inBytes))
        row(t, _("Data out"), M.bytes(i.outBytes))
        if i.inErrs + i.outErrs + i.collisions > 0 then
            row(t, _("Errors"), T(_("%1 in · %2 out · %3 collisions"), i.inErrs, i.outErrs, i.collisions))
        end
        return t
    end)
end

-- ------------------------------------------------------------------ services

function UI.services(plugin)
    listPage(plugin, _("Services"), listItems(plugin, "services", "api-v2-status-services-get", function(d, t)
        local q = controls(plugin, "services", t)
        local list = shown(plugin, d, "services", q)
        t[#t + 1] = { band = _("SERVICES"), right = tostring(#list) }
        if #list == 0 then noneFound(t, q) end
        for __, s in ipairs(list) do
            t[#t + 1] = { text = s.name, sub = s.key ~= s.name and s.key or nil, icon = "cpu", chevron = true,
                dot = s.enabled and dotOf(s.running) or nil, right = M.serviceState(s),
                callback = function() UI.service(plugin, s.id) end }
        end
        return t
    end))
end

--- Start, stop or restart a service: stopping asks first (what it does stops working).
local function serviceAction(plugin, s, action)
    local done = { start = _("Started"), stop = _("Stopped"), restart = _("Restarted") }
    local function go()
        act(plugin, "service", { name = s.key, action = action }, T("%1: %2", s.name, done[action]),
            { text = action == "restart" and _("Restarting…") or (action == "start" and _("Starting…") or _("Stopping…")) })
    end
    if action == "stop" then
        return KO.confirm{ title = T(_("Stop %1?"), s.name),
            text = _("What it does stops until it's started again. Stopping some services (such as the DNS Resolver or the web interface) can cut off the Kindle too."),
            ok = _("Stop"), cancel = _("Cancel"), danger = true, onOk = go }
    end
    go()
end

function UI.service(plugin, id)
    local d0 = plugin:data()
    local s0 = d0 and M.find(d0, "service", id)
    listPage(plugin, s0 and s0.name or _("Service"), function()
        local d = plugin:data()
        local s = d and M.find(d, "service", id)
        local t = {}
        if not s then return gone(plugin, t) end
        t[#t + 1] = { band = _("SERVICE") }
        row(t, _("Status"), M.serviceState(s))
        row(t, _("Name"), s.key)
        row(t, _("Enabled"), s.enabled and _("Yes") or _("No"))
        t[#t + 1] = { gap = 8 }
        local tiles = {}
        if s.running then
            tiles[#tiles + 1] = { icon = "rotate-ccw", text = _("Restart"), primary = true, fn = function() serviceAction(plugin, s, "restart") end }
            tiles[#tiles + 1] = { icon = "square", text = _("Stop"), fn = function() serviceAction(plugin, s, "stop") end }
        else
            tiles[#tiles + 1] = { icon = "play", text = _("Start"), primary = true, fn = function() serviceAction(plugin, s, "start") end }
        end
        t[#t + 1] = { tiles = tiles, cols = 2 }
        return t
    end)
end

-- ------------------------------------------------------------------ devices, ARP and Wake-on-LAN

local function wake(plugin, iface, mac)
    if iface == "" then return KO.toast(_("Which interface it's on isn't known"), 3) end
    act(plugin, "wake", { iface = iface, mac = mac }, _("Wake-on-LAN sent"))
end

function UI.devices(plugin)
    listPage(plugin, _("Devices"), listItems(plugin, "leases", "api-v2-status-dhcp-server-leases-get", function(d, t)
        local c = M.counts(d)
        local q = controls(plugin, "leases", t, true)
        local list = shown(plugin, d, "leases", q)
        t[#t + 1] = { band = _("DHCP LEASES"), right = T(_("%1 online"), c.online) }
        if #d.leases == 0 then t[#t + 1] = { message = _("No DHCP leases.") } elseif #list == 0 then noneFound(t, q) end
        for __, l in ipairs(list) do
            t[#t + 1] = { text = l.name, sub = M.leaseLine(l), icon = "laptop", dot = dotOf(l.online), chevron = true,
                callback = function() UI.device(plugin, l.id) end }
        end
        return t
    end), true)
end

function UI.device(plugin, id)
    local d0 = plugin:data()
    local l0 = d0 and M.find(d0, "lease", id)
    listPage(plugin, l0 and l0.name or _("Device"), function()
        local d = plugin:data()
        local l = d and M.find(d, "lease", id)
        local t = {}
        if not l then return gone(plugin, t) end
        t[#t + 1] = { band = _("DEVICE") }
        row(t, _("Status"), l.online and _("Online") or _("Offline"))
        row(t, _("IP address"), l.ip)
        row(t, _("MAC address"), l.mac)
        row(t, _("Hostname"), l.hostname)
        row(t, _("Interface"), l.iface)
        row(t, _("Description"), l.descr)
        row(t, _("Lease"), l.static and _("Static") or (l.state ~= "" and (l.state:sub(1, 1):upper() .. l.state:sub(2)) or nil))
        row(t, _("Lease ends"), l.ends)
        t[#t + 1] = { gap = 8 }
        local mapping = M.staticFor(d, l.mac)
        local tiles = { { icon = "zap", text = _("Wake"), fn = function() wake(plugin, l.iface, l.mac) end },
            { icon = "plug", text = _("Connections"), fn = function() UI.connections(plugin, l.ip, l.name) end },
            { icon = "wifi", text = _("Ping"), fn = function() UI.ping(plugin, l.ip) end },
            { icon = "shield", text = _("Add to an alias"), fn = function() UI.addToAlias(plugin, l.ip, l.name) end } }
        if mapping then
            tiles[#tiles + 1] = { icon = "tag", text = _("Static mapping"), fn = function() UI.static(plugin, mapping.key) end }
        else
            tiles[#tiles + 1] = { icon = "plus", text = _("Add a static mapping"), primary = true,
                fn = function() UI.addStatic(plugin, { parent = l.iface, mac = l.mac, ip = l.ip, hostname = l.hostname }) end }
        end
        t[#t + 1] = { tiles = tiles, cols = 2 }
        return t
    end, true)
end

function UI.arpTable(plugin)
    listPage(plugin, _("ARP table"), listItems(plugin, "arp", "api-v2-diagnostics-arp-table-get", function(d, t)
        local q = controls(plugin, "arp", t, true)
        local list = shown(plugin, d, "arp", q)
        t[#t + 1] = { band = _("ARP TABLE"), right = tostring(#list) }
        if #d.arp == 0 then t[#t + 1] = { message = _("The ARP table is empty.") } elseif #list == 0 then noneFound(t, q) end
        for __, a in ipairs(list) do
            t[#t + 1] = { text = a.name ~= a.ip and (a.name .. " · " .. a.ip) or a.ip, sub = M.arpLine(a), icon = "list",
                chevron = true, callback = function() UI.arpEntry(plugin, a.id) end }
        end
        return t
    end), true)
end

function UI.arpEntry(plugin, id)
    local d0 = plugin:data()
    local a0 = d0 and M.find(d0, "arp", id)
    local p
    p = listPage(plugin, a0 and a0.ip or _("ARP entry"), function()
        local d = plugin:data()
        local a = d and M.find(d, "arp", id)
        local t = {}
        if not a then return gone(plugin, t) end
        t[#t + 1] = { band = _("ARP ENTRY") }
        row(t, _("IP address"), a.ip)
        row(t, _("MAC address"), a.mac)
        row(t, _("Hostname"), a.hostname)
        row(t, _("DNS name"), a.dns)
        row(t, _("Interface"), a.iface)
        row(t, _("Type"), a.type)
        row(t, _("Expires"), a.permanent and _("Permanent") or a.expires)
        t[#t + 1] = { gap = 8 }
        local mapping = M.staticFor(d, a.mac)
        t[#t + 1] = { tiles = {
            { icon = "zap", text = _("Wake"), fn = function() wake(plugin, a.iface, a.mac) end },
            mapping and { icon = "tag", text = _("Static mapping"), fn = function() UI.static(plugin, mapping.key) end }
                or { icon = "plus", text = _("Add a static mapping"),
                    fn = function() UI.addStatic(plugin, { parent = a.iface, mac = a.mac, ip = a.ip, hostname = a.hostname }) end },
            { icon = "plug", text = _("Connections"), fn = function() UI.connections(plugin, a.ip, a.name) end },
            { icon = "wifi", text = _("Ping"), fn = function() UI.ping(plugin, a.ip) end },
            -- (it comes back by itself when the device talks again: no Undo needed)
            { icon = "trash-2", text = _("Remove"), fn = function()
                act(plugin, "arp_delete", { id = a.id, ip = a.ip }, _("Removed from the ARP table"))
                if alive(p) then p:onClose() end
            end },
        }, cols = 3 }
        t[#t + 1] = { note = _("A removed entry comes back when the device talks again.") }
        return t
    end, true)
end

-- ------------------------------------------------------------------ DHCP static mappings

--- The interfaces a mapping can go on (DHCP servers run on these): their names, LAN first.
local function dhcpInterfaces(d)
    local out, seen = {}, {}
    for __, s in ipairs(d.statics or {}) do
        if not seen[s.parent] then seen[s.parent] = true out[#out + 1] = s.parent end
    end
    for __, l in ipairs(d.leases or {}) do
        if l.iface ~= "" and not seen[l.iface] then seen[l.iface] = true out[#out + 1] = l.iface end
    end
    for __, i in ipairs(d.interfaces or {}) do
        if i.key ~= "wan" and i.enabled and i.ip ~= "" and not seen[i.key] then seen[i.key] = true out[#out + 1] = i.key end
    end
    table.sort(out, function(a, b)
        if a == "lan" or b == "lan" then return a == "lan" end
        return a < b
    end)
    return out
end

--- An interface's name as shown ("LAN", or its description).
local function ifaceName(d, key)
    local i = d and M.find(d, "interface", key)
    return i and i.name or key:upper()
end

--- Adding a static mapping: the interface (when there's a choice), MAC, IP address and
-- hostname; f: what's known already (from a lease or ARP entry).
function UI.addStatic(plugin, f)
    f = f or {}
    local d = plugin:data() or {}
    local function save(hostname)
        act(plugin, "static_add", { parent = f.parent, mac = f.mac, ip = f.ip, hostname = hostname, descr = "" },
            _("Static mapping added"), { text = _("Saving…") })
    end
    local function askHost()
        ask(_("Hostname"), f.hostname or "", function(v) save(trim(v)) end,
            { ok = _("Add"), okIcon = "plus", description = _("Optional: the name pfSense gives it (letters, digits and dashes).") })
    end
    local function askIp()
        ask(_("IP address"), f.ip or "", function(v)
            v = trim(v)
            if v ~= "" and not M.isIPv4(v) then return KO.toast(_("Enter an IP address, such as 192.168.1.20")) end
            f.ip = v
            askHost()
        end, { ok = _("Next"), okIcon = "chevron-right",
            description = _("The address it always gets. Outside the DHCP range is best (Services > DHCP Server). Empty: any.") })
    end
    local function askMac()
        if f.mac and M.isMac(f.mac) then return askIp() end
        ask(_("MAC address"), f.mac or "", function(v)
            if not M.isMac(v) then return KO.toast(_("Enter a MAC address, such as aa:bb:cc:dd:ee:ff")) end
            f.mac = M.mac(v)
            askIp()
        end, { ok = _("Next"), okIcon = "chevron-right" })
    end
    if f.parent and f.parent ~= "" then return askMac() end
    local ifaces = dhcpInterfaces(d)
    if #ifaces == 0 then return KO.toast(_("No interface with a DHCP server was found"), 3) end
    if #ifaces == 1 then
        f.parent = ifaces[1]
        return askMac()
    end
    local options = {}
    for __, k in ipairs(ifaces) do options[#options + 1] = { label = ifaceName(d, k), value = k } end
    KO.choose(_("Interface"), options, ifaces[1], function(k)
        f.parent = k
        askMac()
    end)
end

function UI.statics(plugin)
    listPage(plugin, _("Static mappings"), listItems(plugin, "statics", "api-v2-services-dhcp-server-static-mappings-get", function(d, t)
        t[#t + 1] = { tiles = { { icon = "plus", text = _("Add"), primary = true, fn = function() UI.addStatic(plugin) end } }, cols = 3 }
        local q = controls(plugin, "statics", t, true)
        local list = shown(plugin, d, "statics", q)
        if #d.statics == 0 then t[#t + 1] = { message = _("No static mappings yet.") } elseif #list == 0 then noneFound(t, q) end
        local by, order = {}, {}
        for __, s in ipairs(list) do
            if not by[s.parent] then by[s.parent] = {} order[#order + 1] = s.parent end
            table.insert(by[s.parent], s)
        end
        for __, parent in ipairs(order) do
            t[#t + 1] = { band = ifaceName(d, parent):upper(), right = tostring(#by[parent]) }
            for __, s in ipairs(by[parent]) do
                local online
                for __, l in ipairs(d.leases or {}) do if l.mac == s.mac then online = l.online end end
                t[#t + 1] = { text = s.name, sub = M.staticLine(s), icon = "tag", chevron = true,
                    dot = online ~= nil and dotOf(online) or nil, callback = function() UI.static(plugin, s.key) end }
            end
        end
        return t
    end), true)
end

local function staticByKey(d, key)
    for __, s in ipairs(d and d.statics or {}) do if s.key == key then return s end end
end

function UI.static(plugin, key)
    local d0 = plugin:data()
    local s0 = staticByKey(d0, key)
    local p
    p = listPage(plugin, s0 and s0.name or _("Static mapping"), function()
        local d = plugin:data()
        local s = staticByKey(d, key)
        local t = {}
        if not s then return gone(plugin, t) end
        local function edit(field, title, value, check)
            return function()
                ask(title, value, function(v)
                    v = trim(v)
                    if check and v ~= "" and not check(v) then return KO.toast(_("Enter an IP address, such as 192.168.1.20")) end
                    act(plugin, "static_edit", { parent = s.parent, id = s.id, mac = s.mac, fields = { [field] = v } },
                        _("Saved"), { text = _("Saving…") })
                end)
            end
        end
        t[#t + 1] = { band = _("STATIC MAPPING") }
        row(t, _("Interface"), ifaceName(d, s.parent))
        row(t, _("MAC address"), s.mac)
        row(t, _("IP address"), s.ip ~= "" and s.ip or _("Any"), edit("ip", _("IP address"), s.ip, M.isIPv4))
        row(t, _("Hostname"), s.hostname ~= "" and s.hostname or _("None"), edit("hostname", _("Hostname"), s.hostname))
        row(t, _("Description"), s.descr ~= "" and s.descr or _("None"), edit("descr", _("Description"), s.descr))
        t[#t + 1] = { gap = 8 }
        t[#t + 1] = { tiles = {
            { icon = "zap", text = _("Wake"), fn = function() wake(plugin, s.parent, s.mac) end },
            { icon = "trash-2", text = _("Delete"), fn = function()
                local was = { parent = s.parent, mac = s.mac, ip = s.ip, hostname = s.hostname, descr = s.descr }
                plugin:act("static_delete", { parent = s.parent, id = s.id, mac = s.mac }, function(ok, text)
                    if not ok then return KO.message(text, _("pfSense")) end
                    KO.undo(_("Static mapping deleted"), function()
                        act(plugin, "static_add", was, _("Static mapping put back"))
                    end)
                end, { text = _("Deleting…") })
                if alive(p) then p:onClose() end
            end },
        }, cols = 3 }
        return t
    end, true)
end

-- ------------------------------------------------------------------ DNS host overrides

--- Adding a host override: host, domain, IP addresses.
function UI.addOverride(plugin)
    local f = {}
    local d = plugin:data() or {}
    local domain = ""
    for __, o in ipairs(d.overrides or {}) do if o.domain ~= "" then domain = o.domain break end end
    local function askIps()
        ask(_("IP addresses"), "", function(v)
            local ips = M.strings(v)
            if #ips == 0 then return KO.toast(_("Enter an IP address, such as 192.168.1.20")) end
            f.ips = ips
            act(plugin, "override_add", { host = f.host, domain = f.domain, ips = f.ips, descr = "", aliases = {} },
                _("Host override added"), { text = _("Saving…") })
        end, { ok = _("Add"), okIcon = "plus", description = _("What the name resolves to; several with commas.") })
    end
    local function askDomain()
        ask(_("Domain"), domain, function(v)
            v = trim(v)
            if v == "" then return KO.toast(_("Enter the domain, such as home.example.com")) end
            f.domain = v
            askIps()
        end, { ok = _("Next"), okIcon = "chevron-right", description = _("Such as home.example.com.") })
    end
    ask(_("Host"), "", function(v)
        f.host = trim(v)
        askDomain()
    end, { ok = _("Next"), okIcon = "chevron-right",
        description = _("The name before the domain, such as nas (empty: the domain itself).") })
end

function UI.overrides(plugin)
    listPage(plugin, _("DNS host overrides"), listItems(plugin, "overrides", "api-v2-services-dns-resolver-host-overrides-get", function(d, t)
        t[#t + 1] = { tiles = { { icon = "plus", text = _("Add"), primary = true, fn = function() UI.addOverride(plugin) end } }, cols = 3 }
        local q = controls(plugin, "overrides", t, true)
        local list = shown(plugin, d, "overrides", q)
        t[#t + 1] = { band = _("HOST OVERRIDES"), right = tostring(#list) }
        if #d.overrides == 0 then t[#t + 1] = { message = _("No host overrides yet.") } elseif #list == 0 then noneFound(t, q) end
        for __, o in ipairs(list) do
            t[#t + 1] = { text = o.fqdn, sub = M.overrideLine(o), icon = "globe", chevron = true,
                callback = function() UI.override(plugin, o.id) end }
        end
        return t
    end), true)
end

function UI.override(plugin, id)
    local d0 = plugin:data()
    local o0 = d0 and M.find(d0, "override", id)
    local p
    p = listPage(plugin, o0 and o0.fqdn or _("Host override"), function()
        local d = plugin:data()
        local o = d and M.find(d, "override", id)
        local t = {}
        if not o then return gone(plugin, t) end
        local function edit(field, title, value, description, parse)
            return function()
                ask(title, value, function(v)
                    v = trim(v)
                    local val = parse and parse(v) or v
                    if field == "domain" and v == "" then return end
                    if field == "ips" and #val == 0 then return KO.toast(_("Enter an IP address, such as 192.168.1.20")) end
                    act(plugin, "override_edit", { id = o.id, host = o.host, domain = o.domain, fields = { [field] = val } },
                        _("Saved"), { text = _("Saving…") })
                end, { description = description })
            end
        end
        t[#t + 1] = { band = _("HOST OVERRIDE") }
        row(t, _("Host"), o.host ~= "" and o.host or _("None"), edit("host", _("Host"), o.host))
        row(t, _("Domain"), o.domain, edit("domain", _("Domain"), o.domain))
        row(t, _("IP addresses"), table.concat(o.ips, ", "),
            edit("ips", _("IP addresses"), table.concat(o.ips, ", "), _("Several with commas."), M.strings))
        row(t, _("Description"), o.descr ~= "" and o.descr or _("None"), edit("descr", _("Description"), o.descr))
        row(t, _("Aliases"), #o.aliases > 0 and table.concat(o.aliases, ", ") or _("None"),
            edit("aliases", _("Aliases"), table.concat(o.aliases, ", "),
                _("Other names for the same addresses, such as files.home.example.com; several with commas."), M.strings))
        t[#t + 1] = { gap = 8 }
        t[#t + 1] = { tiles = {
            { icon = "trash-2", text = _("Delete"), fn = function()
                local was = { host = o.host, domain = o.domain, ips = o.ips, descr = o.descr, aliases = o.aliases }
                plugin:act("override_delete", { id = o.id, host = o.host, domain = o.domain }, function(ok, text)
                    if not ok then return KO.message(text, _("pfSense")) end
                    KO.undo(_("Host override deleted"), function()
                        act(plugin, "override_add", was, _("Host override put back"))
                    end)
                end, { text = _("Deleting…") })
                if alive(p) then p:onClose() end
            end },
        }, cols = 3 }
        return t
    end, true)
end

-- ------------------------------------------------------------------ firewall rules

function UI.rules(plugin)
    listPage(plugin, _("Firewall rules"), listItems(plugin, "rules", "api-v2-firewall-rules-get", function(d, t)
        -- (no sorting: rules stay in the order pfSense matches them)
        local q = controls(plugin, "rules", t)
        local list = shown(plugin, d, "rules", q)
        if #d.rules == 0 then t[#t + 1] = { message = _("No firewall rules.") } elseif #list == 0 then noneFound(t, q) end
        local by, order = {}, {}
        for __, r in ipairs(list) do
            local key = r.floating and "floating" or (r.ifaces[1] or "")
            if not by[key] then by[key] = {} order[#order + 1] = key end
            table.insert(by[key], r)
        end
        for __, key in ipairs(order) do
            t[#t + 1] = { band = key == "floating" and _("FLOATING") or ifaceName(d, key):upper(), right = tostring(#by[key]) }
            for __, r in ipairs(by[key]) do
                t[#t + 1] = { toggle = not r.disabled, text = r.name, sub = M.ruleLine(r),
                    callback = function()
                        act(plugin, "rule_enabled", { id = r.id, tracker = r.tracker, on = r.disabled },
                            r.disabled and _("Rule on") or _("Rule off"))
                    end,
                    hold_callback = function() UI.rule(plugin, r.id) end }
            end
        end
        t[#t + 1] = { note = _("Tap a switch to turn a rule on or off (applied at once). Hold a rule for its details.") }
        return t
    end), true)
end

function UI.rule(plugin, id)
    local d0 = plugin:data()
    local r0 = d0 and M.find(d0, "rule", id)
    local tracker = r0 and r0.tracker
    listPage(plugin, r0 and r0.name or _("Firewall rule"), function()
        local d = plugin:data()
        local r
        -- (by its tracker: ids move when rules are added or taken out)
        for __, x in ipairs(d and d.rules or {}) do if x.tracker == tracker then r = x end end
        local t = {}
        if not r then return gone(plugin, t) end
        t[#t + 1] = { band = _("RULE") }
        t[#t + 1] = { toggle = not r.disabled, text = _("Enabled"), sub = _("Applied at once"),
            callback = function()
                act(plugin, "rule_enabled", { id = r.id, tracker = r.tracker, on = r.disabled }, r.disabled and _("Rule on") or _("Rule off"))
            end }
        row(t, _("Action"), M.ruleType(r))
        row(t, _("Interface"), r.floating and _("Floating") or table.concat(r.ifaces, ", "):upper())
        row(t, _("Protocol"), r.protocol ~= "" and r.protocol:upper() or _("Any"))
        row(t, _("Source"), r.source .. (r.sport ~= "" and (":" .. r.sport) or ""))
        row(t, _("Destination"), r.dest .. (r.dport ~= "" and (":" .. r.dport) or ""))
        row(t, _("Description"), r.descr)
        row(t, _("Schedule"), r.sched)
        row(t, _("Gateway"), r.gateway)
        row(t, _("Logged"), r.log and _("Yes") or nil)
        row(t, _("Changed by"), r.updatedBy)
        return t
    end, true)
end

-- ------------------------------------------------------------------ VPN

function UI.vpn(plugin)
    listPage(plugin, _("VPN"), function()
        local early = notRead(plugin)
        if early then return early end
        local d = plugin:data()
        local t = {}
        -- WireGuard: each peer as configured (its switch), with how it's doing now (by its public key)
        local status = {}
        for __, p in ipairs(d.peers or {}) do status[p.id] = p end
        local peers = d.wgpeers or {}
        if #peers == 0 then
            for __, p in ipairs(d.peers or {}) do peers[#peers + 1] = { key = p.id, name = p.name, enabled = true, readonly = true } end
        end
        if #peers > 0 then
            local c = M.counts(d)
            t[#t + 1] = { band = _("WIREGUARD PEERS"), right = T(_("%1 connected"), c.peersOnline) }
            for __, w in ipairs(peers) do
                local p = status[w.key]
                local sub = p and M.peerLine(p) or (w.enabled and _("Never connected") or _("Off"))
                if p and p.endpoint ~= "" and p.online then sub = sub .. " · " .. p.endpoint end
                if p and p.rx + p.tx > 0 then sub = sub .. " · " .. M.bytes(p.rx + p.tx) end
                if w.readonly then
                    t[#t + 1] = { text = w.name, sub = sub, icon = "key-round", dot = p and dotOf(p.online) or nil }
                else
                    t[#t + 1] = { toggle = w.enabled, text = w.name, sub = sub, callback = function()
                        act(plugin, "wg_enabled", { num = w.num, key = w.key, on = not w.enabled },
                            w.enabled and _("Peer off") or _("Peer on"), { text = _("Applying WireGuard…") })
                    end }
                end
            end
        end
        -- OpenVPN servers: who's connected, each with Disconnect
        if d.ovpn and #d.ovpn > 0 then
            for __, s in ipairs(d.ovpn) do
                local conns = {}
                for __, c in ipairs(d.ovpnconns or {}) do if c.parent == s.id then conns[#conns + 1] = c end end
                if not d.ovpnconns then conns = s.conns end
                t[#t + 1] = { band = s.name:upper(), right = T(_("%1 connected"), #conns) }
                if #conns == 0 then t[#t + 1] = { note = _("No one connected.") } end
                for __, c in ipairs(conns) do
                    local sub = {}
                    for __, x in ipairs({ c.vip, c.remote }) do if x ~= "" then sub[#sub + 1] = x end end
                    if c.since then sub[#sub + 1] = M.ago(c.since) end
                    if c.rx and c.rx + c.tx > 0 then sub[#sub + 1] = M.bytes(c.rx + c.tx) end
                    t[#t + 1] = { text = c.name ~= "" and c.name or c.remote, icon = "laptop", dot = "on", sub = table.concat(sub, " · "),
                        chevron = c.key ~= nil, callback = c.key and function()
                            KO.list(c.name, { { text = _("Disconnect"), fn = function()
                                act(plugin, "ovpn_kill", { parent = c.parent, id = c.id, name = c.name, remote = c.remote },
                                    T(_("%1 disconnected"), c.name))
                            end } })
                        end or nil }
                end
            end
        end
        if d.ovpnclients and #d.ovpnclients > 0 then
            t[#t + 1] = { band = _("OPENVPN CLIENTS"), right = tostring(#d.ovpnclients) }
            for __, c in ipairs(d.ovpnclients) do
                local sub = {}
                for __, x in ipairs({ c.up and _("Connected") or (c.state ~= "" and c.state or _("Not connected")), c.remote, c.vip }) do
                    if x ~= "" then sub[#sub + 1] = x end
                end
                t[#t + 1] = { text = c.name, sub = table.concat(sub, " · "), icon = "key-round", dot = dotOf(c.up) }
            end
        end
        if d.ipsec and #d.ipsec > 0 then
            t[#t + 1] = { band = _("IPSEC TUNNELS"), right = tostring(#d.ipsec) }
            for __, x in ipairs(d.ipsec) do
                local sub = { x.up and _("Established") or (x.state ~= "" and x.state or _("Down")) }
                if x.remote ~= "" then sub[#sub + 1] = x.remote end
                t[#t + 1] = { text = x.name, sub = table.concat(sub, " · "), icon = "lock", dot = dotOf(x.up) }
            end
        end
        if #t == 0 then
            t[#t + 1] = { message = _("No VPN to show.") }
            t[#t + 1] = { note = _("WireGuard peers (with the WireGuard package), OpenVPN servers and clients, and IPsec tunnels show here.") }
        end
        return t
    end, true)
end

-- ------------------------------------------------------------------ logs

--- The system and firewall logs, newest first (read when the page opens and on ⟳).
function UI.logs(plugin)
    local kind = "system"
    local lines, why, busy = nil, nil, false
    local p
    local function load()
        busy = true
        plugin:log(kind, function(l, text)
            busy = false
            lines, why = l, text
            if alive(p) then UI.refreshAll() end
        end)
        if p then UI.refreshAll() end
    end
    local function chip(k, name)
        return { text = name, on = kind == k, fn = function()
            if kind == k then return end
            kind, lines, why = k, nil, nil
            load()
        end }
    end
    p = page(_("Logs"), function()
        local kinds = {}
        for __, k in ipairs(M.LOGS) do kinds[#kinds + 1] = chip(k.id, k.name) end
        local t = { { chips = kinds } }
        local q = controls(plugin, "logs", t)
        if busy and not lines then t[#t + 1] = { message = _("Reading…") } return t end
        if not lines then t[#t + 1] = { message = why or _("Reading…") } return t end
        if #lines == 0 then t[#t + 1] = { message = _("The log is empty.") } return t end
        local found = {}
        for __, s in ipairs(lines) do
            if M.matches({ s }, q) then found[#found + 1] = s end
        end
        if #found == 0 then noneFound(t, q) end
        for __, s in ipairs(found) do
            local l = M.logLine(s)
            local f = kind == "firewall" and M.filterLine(s)
            if f and f.src then
                local action = f.action ~= "" and (f.action:sub(1, 1):upper() .. f.action:sub(2)) or ""
                t[#t + 1] = { text = T("%1 · %2 · %3", action, f.iface, f.proto:upper()),
                    sub = T("%1 → %2 · %3", f.src, f.dst, l.time), dot = f.action == "pass" and "on" or "off" }
            else
                -- (a long line is cut at the edge: a tap shows all of it)
                t[#t + 1] = { text = l.text, sub = l.time ~= "" and l.time or nil, callback = function()
                    local read = KO.read()
                    if read then
                        return read{ title = l.time ~= "" and l.time or _("Log"), text = l.text,
                            buttons = { { icon = "check", text = _("Done"), primary = true } } }
                    end
                    KO.message(l.text, l.time)
                end }
            end
        end
        return t
    end, { on_refresh = function() load() end })
    load()
end

-- ------------------------------------------------------------------ packages

--- Remove an installed package: asks first (what it does stops, and its settings page goes).
local function removePackage(plugin, x)
    KO.confirm{ title = T(_("Remove %1?"), x.short),
        text = _("pfSense uninstalls it: what it does stops. Its settings are usually kept, for when it's installed again."),
        ok = _("Remove"), cancel = _("Cancel"), danger = true,
        onOk = function()
            act(plugin, "pkg_remove", { id = x.id, name = x.name }, T(_("%1 removed"), x.short), { text = T(_("Removing %1…"), x.short) })
        end }
end

function UI.packages(plugin)
    local why
    local p
    local function load(again)
        plugin:packages(function(l, text)
            why = text
            if alive(p) then UI.refreshAll() end
        end, again)
    end
    p = page(_("Packages"), function()
        local t = {}
        local list = plugin:packageList()
        if not list then
            t[#t + 1] = { message = why or _("Asking pfSense's package server…") }
            return t
        end
        t[#t + 1] = { tiles = { { icon = "download", text = _("Install"), primary = true, fn = function() UI.install(plugin) end } }, cols = 3 }
        local updates = {}
        for __, x in ipairs(list) do if x.update then updates[#updates + 1] = x end end
        if #updates > 0 then
            t[#t + 1] = { band = _("UPDATES"), right = tostring(#updates) }
            for __, x in ipairs(updates) do
                t[#t + 1] = { text = x.short, sub = T(_("%1 → %2"), x.installed, x.latest), icon = "circle-arrow-up", dot = "off",
                    callback = function() KO.list(x.short, { { text = _("Remove"), fn = function() removePackage(plugin, x) end } }) end }
            end
            t[#t + 1] = { note = _("Update packages in pfSense's web interface: System > Package Manager. The REST API can't update them.") }
        end
        t[#t + 1] = { band = _("INSTALLED"), right = tostring(#list) }
        if #list == 0 then t[#t + 1] = { message = _("No packages installed.") } end
        for __, x in ipairs(list) do
            if not x.update then
                t[#t + 1] = { text = x.short, sub = x.installed ~= "" and x.installed or nil, icon = "package", right = _("Up to date"),
                    callback = function() KO.list(x.short, { { text = _("Remove"), fn = function() removePackage(plugin, x) end } }) end }
            end
        end
        t[#t + 1] = { note = _("Tap a package to remove it.") }
        return t
    end, { on_refresh = function() why = nil UI.refreshAll() load(true) end })
    load()
end

--- The packages there are to install, with Search; one tapped asks first, then installs.
function UI.install(plugin)
    local list, why
    local p
    local function load(again)
        list, why = nil, nil
        plugin:available(function(l, text)
            list, why = l, text
            if alive(p) then UI.refreshAll() end
        end, again)
    end
    p = page(_("Install a package"), function()
        local t = {}
        if not list then
            t[#t + 1] = { message = why or _("Asking pfSense's package server…") }
            return t
        end
        local q = controls(plugin, "available", t)
        local found = M.filter(list, q)
        t[#t + 1] = { band = _("AVAILABLE"), right = tostring(#found) }
        if #list == 0 then t[#t + 1] = { message = _("Nothing more to install.") } elseif #found == 0 then noneFound(t, q) end
        for __, x in ipairs(found) do
            t[#t + 1] = { text = x.short, sub = x.descr ~= "" and x.descr or x.version, icon = "package", right = x.version,
                callback = function()
                    KO.confirm{ title = T(_("Install %1?"), x.short),
                        text = T(_("pfSense downloads it and sets it up, which can take a few minutes. %1"), x.descr),
                        ok = _("Install"), cancel = _("Cancel"),
                        onOk = function()
                            act(plugin, "pkg_install", { name = x.name }, T(_("%1 installed"), x.short), { text = T(_("Installing %1…"), x.short) })
                            if alive(p) then p:onClose() end
                        end }
                end }
        end
        return t
    end, { on_refresh = function() load(true) UI.refreshAll() end })
    load()
end

-- ------------------------------------------------------------------ pf tables

--- pf's tables (the block lists pfBlockerNG or Snort fill, and the aliases'), with Look up an address.
function UI.tables(plugin)
    local list, why
    local p
    local function load()
        list, why = nil, nil
        plugin:tables(function(l, text)
            list, why = l, text
            if alive(p) then UI.refreshAll() end
        end)
    end
    p = page(_("pf tables"), function()
        local t = {}
        t[#t + 1] = { tiles = { { icon = "search", text = _("Look up"), sub = _("An address"), primary = true, fn = function() UI.askLookup(plugin) end } }, cols = 3 }
        if not list then
            t[#t + 1] = { message = why or _("Reading the tables…") }
            return t
        end
        local q = controls(plugin, "tables", t)
        local found = M.filter(list, q)
        t[#t + 1] = { band = _("TABLES"), right = tostring(#found) }
        if #list == 0 then t[#t + 1] = { message = _("No tables.") } elseif #found == 0 then noneFound(t, q) end
        for __, x in ipairs(found) do
            t[#t + 1] = { text = x.name, icon = "grid-3x3", chevron = true,
                right = x.count == 1 and _("1 entry") or T(_("%1 entries"), x.count),
                callback = function() UI.table(plugin, x.name) end }
        end
        t[#t + 1] = { note = _("The tables pf blocks or passes by: pfBlockerNG's and Snort's block lists, and the aliases' addresses.") }
        return t
    end, { on_refresh = function() load() UI.refreshAll() end })
    load()
end

--- Empty a table: asks first (the API can't take out one address, only all of them).
local function flushTable(plugin, name, done)
    KO.confirm{ title = T(_("Empty %1?"), name),
        text = _("Every address in it goes now, so none of them is blocked (or passed) by it until it's filled again: pfBlockerNG and Snort fill theirs as they update. The REST API can't take out one address on its own."),
        ok = _("Empty"), cancel = _("Cancel"), danger = true,
        onOk = function()
            plugin:act("table_flush", { name = name }, function(ok, text)
                if ok then KO.toast(T(_("%1 emptied"), name)) else KO.message(text, _("pfSense")) end
                if done then done(ok) end
            end, { text = _("Emptying…") })
        end }
end

function UI.table(plugin, name)
    local tbl, why
    local p
    local function load()
        tbl, why = nil, nil
        plugin:table(name, function(x, text)
            tbl, why = x, text
            if alive(p) then UI.refreshAll() end
        end)
    end
    p = page(name, function()
        local t = {}
        if not tbl then
            t[#t + 1] = { message = why or _("Reading…") }
            return t
        end
        t[#t + 1] = { tiles = { { icon = "trash-2", text = _("Empty"), fn = function()
            flushTable(plugin, name, function(ok) if ok then load() end end)
        end } }, cols = 3 }
        local q = controls(plugin, "table", t)
        local found = {}
        for __, e in ipairs(tbl.entries) do if M.matches({ e }, q) then found[#found + 1] = e end end
        t[#t + 1] = { band = _("ENTRIES"), right = tostring(tbl.count) }
        if tbl.count == 0 then t[#t + 1] = { message = _("It's empty.") } elseif #found == 0 then noneFound(t, q) end
        for __, e in ipairs(found) do t[#t + 1] = { text = e, icon = "shield" } end
        if tbl.count > #tbl.entries then
            t[#t + 1] = { note = T(_("The first %1 of %2. Look up finds an address in all of them."), #tbl.entries, tbl.count) }
        end
        return t
    end, { on_refresh = function() load() UI.refreshAll() end })
    load()
end

--- Look up an address in every table: the ones it's in (itself, or a network it's in), each with Empty.
function UI.lookup(plugin, ip)
    plugin:lookup(ip, function(hits, why)
        if not hits then return KO.message(why, _("Look up")) end
        page(T(_("%1 in pf tables"), ip), function()
            local t = {}
            t[#t + 1] = { band = _("IN"), right = tostring(#hits) }
            if #hits == 0 then t[#t + 1] = { message = T(_("%1 isn't in any table."), ip) } end
            for __, h in ipairs(hits) do
                t[#t + 1] = { text = h.name, sub = table.concat(h.entries, ", "), icon = "grid-3x3", chevron = true,
                    callback = function()
                        KO.list(h.name, {
                            { text = _("Show the table"), fn = function() UI.table(plugin, h.name) end },
                            { text = _("Empty the table"), fn = function() flushTable(plugin, h.name) end },
                        })
                    end }
            end
            if #hits > 0 then
                t[#t + 1] = { note = _("The REST API can only empty a whole table, not take one address out. For a block list, an alias or rule that lets it through (or pfBlockerNG's own whitelist) keeps it out for good.") }
            end
            return t
        end)
    end)
end

function UI.askLookup(plugin)
    ask(_("Look up"), "", function(v)
        v = trim(v)
        if not M.isIPv4(v) then return KO.toast(_("Enter an IP address, such as 192.168.1.20")) end
        UI.lookup(plugin, v)
    end, { ok = _("Look up"), okIcon = "search", description = _("An IP address: the pf tables it's in (itself, or a network it's in).") })
end

-- ------------------------------------------------------------------ service settings (read when their page opens)

--- A settings page: what was read of name (pfsmodel.config) through fn(value, t), read when it opens and on ⟳.
local function configPage(plugin, name, title, fn)
    local p = page(title, function()
        local v = plugin:configData(name)
        local t = {}
        if not v then
            t[#t + 1] = { message = plugin:configWhy(name) or _("Reading…") }
            return t
        end
        return fn(v, t)
    end, { on_refresh = function() plugin:config(name, nil, true) end })
    plugin:config(name, function() if alive(p) then UI.refreshAll() end end, true)
    return p
end

--- A setting's switch that asks first when turned off (o: { title, text, ok }), else just does it.
local function offAsks(on, o, go)
    if not on then
        return KO.confirm{ title = o.title, text = o.text, ok = o.ok or _("Turn off"), cancel = _("Cancel"), danger = true, onOk = go }
    end
    go()
end

function UI.watchdog(plugin)
    configPage(plugin, "watchdog", _("Service watchdog"), function(list, t)
        t[#t + 1] = { tiles = { { icon = "plus", text = _("Add"), primary = true, fn = function() UI.addWatchdog(plugin) end } }, cols = 3 }
        t[#t + 1] = { band = _("WATCHED SERVICES"), right = tostring(#list) }
        if #list == 0 then t[#t + 1] = { message = _("No services watched.") } end
        for __, w in ipairs(list) do
            t[#t + 1] = { toggle = w.notify, text = w.title, sub = w.title ~= w.name and w.name or nil,
                callback = function()
                    act(plugin, "watchdog_notify", { id = w.id, name = w.name, on = not w.notify },
                        w.notify and _("Notifications off") or _("Notifications on"))
                end,
                hold_callback = function()
                    KO.list(w.title, { { text = _("Stop watching"), fn = function()
                        plugin:act("watchdog_delete", { id = w.id, name = w.name }, function(ok, text)
                            if not ok then return KO.message(text, _("pfSense")) end
                            KO.undo(T(_("%1 not watched"), w.title), function()
                                act(plugin, "watchdog_add", { name = w.name, description = w.descr, notify = w.notify }, T(_("%1 watched again"), w.title))
                            end)
                        end)
                    end } })
                end }
        end
        t[#t + 1] = { note = _("pfSense starts a watched service again when it stops (the Service Watchdog package). The switch: a notification from pfSense when it does. Hold one to stop watching it.") }
        return t
    end)
end

--- Watch a service: one of the services read, not yet watched.
function UI.addWatchdog(plugin)
    local d = plugin:data()
    local watched = {}
    for __, w in ipairs(plugin:configData("watchdog") or {}) do watched[w.name] = true end
    local options = {}
    for __, s in ipairs(d and d.services or {}) do
        if not watched[s.key] then
            options[#options + 1] = { text = s.name ~= s.key and T("%1 · %2", s.name, s.key) or s.name, fn = function()
                act(plugin, "watchdog_add", { name = s.key, description = s.name, notify = true }, T(_("%1 watched"), s.name))
            end }
        end
    end
    if #options == 0 then return KO.toast(_("Every service is watched already"), 3) end
    KO.list(_("Watch a service"), options)
end

function UI.cron(plugin)
    configPage(plugin, "cron", _("Cron jobs"), function(list, t)
        t[#t + 1] = { tiles = { { icon = "plus", text = _("Add"), primary = true, fn = function() UI.addCron(plugin) end } }, cols = 3 }
        local q = controls(plugin, "cron", t)
        local found = M.filter(list, q)
        t[#t + 1] = { band = _("CRON JOBS"), right = tostring(#found) }
        if #list == 0 then t[#t + 1] = { message = _("No cron jobs.") } elseif #found == 0 then noneFound(t, q) end
        for __, c in ipairs(found) do
            t[#t + 1] = { text = c.name, sub = M.cronLine(c), icon = "calendar", chevron = true, callback = function() UI.cronJob(plugin, c.sig) end }
        end
        t[#t + 1] = { note = _("What pfSense runs on a schedule (the Cron package). A change is applied at once.") }
        return t
    end)
end

--- A cron job by what it is (its id is its place in the list).
local function cronBySig(list, sig)
    for __, c in ipairs(list or {}) do
        local same = true
        for f, v in pairs(sig) do if c.sig[f] ~= v then same = false end end
        if same then return c end
    end
end

function UI.cronJob(plugin, sig)
    local p
    p = configPage(plugin, "cron", _("Cron job"), function(list, t)
        local c = cronBySig(list, sig)
        if not c then
            t[#t + 1] = { message = _("It isn't in pfSense any more.") }
            return t
        end
        local function edit(field, title, description)
            return function()
                ask(title, c[field], function(v)
                    v = trim(v)
                    if v == "" then return end
                    local now = {}
                    for f, x in pairs(c.sig) do now[f] = x end
                    now[field] = v
                    plugin:act("cron_edit", { id = c.id, sig = c.sig, fields = { [field] = v } }, function(ok, text)
                        if not ok then return KO.message(text, _("pfSense")) end
                        -- (the page follows the job as it is now)
                        sig = now
                        KO.toast(_("Saved"))
                    end, { text = _("Saving…") })
                end, { description = description })
            end
        end
        t[#t + 1] = { band = _("CRON JOB") }
        row(t, _("Runs"), M.cronWhen(c))
        row(t, _("Command"), c.command, edit("command", _("Command"), _("With its full path, such as /usr/local/bin/backup.sh.")))
        row(t, _("Minute"), c.minute, edit("minute", _("Minute"), _("0 to 59, */5 (every 5), or @daily, @hourly, @reboot…")))
        row(t, _("Hour"), c.hour, edit("hour", _("Hour"), _("0 to 23, or * for every hour.")))
        row(t, _("Day of the month"), c.mday, edit("mday", _("Day of the month"), _("1 to 31, or * for every day.")))
        row(t, _("Month"), c.month, edit("month", _("Month"), _("1 to 12, or * for every month.")))
        row(t, _("Day of the week"), c.wday, edit("wday", _("Day of the week"), _("0 to 7 (0 and 7 are Sunday), or * for every day.")))
        row(t, _("User"), c.who, edit("who", _("User"), _("Who it runs as, such as root.")))
        t[#t + 1] = { gap = 8 }
        t[#t + 1] = { tiles = { { icon = "trash-2", text = _("Delete"), fn = function()
            local was = {}
            for f, x in pairs(c.sig) do was[f] = x end
            plugin:act("cron_delete", { id = c.id, sig = c.sig }, function(ok, text)
                if not ok then return KO.message(text, _("pfSense")) end
                KO.undo(_("Cron job deleted"), function() act(plugin, "cron_add", was, _("Cron job put back")) end)
            end, { text = _("Deleting…") })
            if alive(p) then p:onClose() end
        end } }, cols = 3 }
        return t
    end)
end

--- Adding a cron job: when (five fields as one line, or @daily…), then the command.
function UI.addCron(plugin)
    ask(_("When"), "0 3 * * *", function(v)
        local parts = {}
        for x in trim(v):gmatch("%S+") do parts[#parts + 1] = x end
        if #parts == 0 or (#parts ~= 5 and not (#parts == 1 and parts[1]:find("^@"))) then
            return KO.toast(_("Enter five fields, such as 0 3 * * *, or @daily"), 3)
        end
        local f = { minute = parts[1], hour = parts[2] or "*", mday = parts[3] or "*", month = parts[4] or "*", wday = parts[5] or "*", who = "root" }
        ask(_("Command"), "", function(cmd)
            cmd = trim(cmd)
            if cmd == "" then return end
            f.command = cmd
            act(plugin, "cron_add", f, _("Cron job added"), { text = _("Saving…") })
        end, { ok = _("Add"), okIcon = "plus", description = _("With its full path, such as /usr/local/bin/backup.sh. It runs as root.") })
    end, { ok = _("Next"), okIcon = "chevron-right",
        description = _("Minute, hour, day of the month, month and day of the week, such as 0 3 * * * (every day at 03:00); or @daily, @hourly, @reboot.") })
end

function UI.ntpSsh(plugin)
    local p = page(_("NTP and SSH"), function()
        local t = {}
        local ssh, ntp = plugin:configData("ssh"), plugin:configData("ntp")
        t[#t + 1] = { band = _("SSH") }
        if ssh then
            t[#t + 1] = { toggle = ssh.enabled, text = _("SSH server"), sub = T(_("Port %1 · applied at once"), ssh.port), callback = function()
                offAsks(not ssh.enabled, { title = _("Turn SSH off?"),
                    text = _("pfSense stops taking SSH connections, and ones open now may be cut off (the SSH app on this Kindle too). The REST API keeps working.") },
                    function() act(plugin, "ssh_set", { enable = not ssh.enabled }, ssh.enabled and _("SSH off") or _("SSH on")) end)
            end }
            row(t, _("Port"), ssh.port, function()
                ask(_("Port"), ssh.port, function(v)
                    local n = tonumber(trim(v))
                    if not n or n < 1 or n > 65535 then return KO.toast(_("Enter a port from 1 to 65535")) end
                    act(plugin, "ssh_set", { port = tostring(math.floor(n)) }, _("Saved"), { text = _("Saving…") })
                end, { description = _("The port pfSense's SSH server listens on (22 to start with).") })
            end)
        else
            t[#t + 1] = { note = plugin:configWhy("ssh") or _("Reading…") }
        end
        t[#t + 1] = { band = _("NTP (TIME)") }
        if ntp then
            t[#t + 1] = { toggle = ntp.enabled, text = _("NTP server"), sub = _("pfSense gives the time to the network"), callback = function()
                offAsks(not ntp.enabled, { title = _("Turn the NTP server off?"),
                    text = _("Devices that ask pfSense for the time stop getting it. pfSense still keeps its own clock right.") },
                    function() act(plugin, "ntp_enabled", { on = not ntp.enabled }, ntp.enabled and _("NTP off") or _("NTP on")) end)
            end }
            if #ntp.ifaces > 0 then row(t, _("Listens on"), table.concat(ntp.ifaces, ", "):upper()) end
            t[#t + 1] = { band = _("TIME SERVERS"), right = tostring(#ntp.servers) }
            t[#t + 1] = { tiles = { { icon = "plus", text = _("Add"), primary = true, fn = function() UI.addTimeServer(plugin) end } }, cols = 3 }
            if #ntp.servers == 0 then t[#t + 1] = { message = _("No time servers.") } end
            for __, x in ipairs(ntp.servers) do
                t[#t + 1] = { text = x.server, sub = M.timeServerLine(x), icon = "clock", chevron = true, callback = function()
                    KO.list(x.server, { { text = _("Delete"), fn = function()
                        plugin:act("ntp_delete", { id = x.id, server = x.server }, function(ok, text)
                            if not ok then return KO.message(text, _("pfSense")) end
                            KO.undo(_("Time server deleted"), function()
                                act(plugin, "ntp_add", { server = x.server, type = x.type }, _("Time server put back"))
                            end)
                        end, { text = _("Deleting…") })
                    end } })
                end }
            end
            t[#t + 1] = { note = _("Where pfSense gets the time from. A change restarts NTP.") }
        else
            t[#t + 1] = { note = plugin:configWhy("ntp") or _("Reading…") }
        end
        return t
    end, { on_refresh = function() plugin:config("ssh", nil, true) plugin:config("ntp", nil, true) end })
    plugin:config("ssh", function() if alive(p) then UI.refreshAll() end end, true)
    plugin:config("ntp", function() if alive(p) then UI.refreshAll() end end, true)
end

function UI.addTimeServer(plugin)
    ask(_("Time server"), "", function(v)
        v = trim(v)
        if v == "" then return end
        KO.choose(_("Type"), { { label = _("Server"), value = "server" }, { label = _("Pool"), value = "pool" }, { label = _("Peer"), value = "peer" } },
            v:find("pool") and "pool" or "server", function(kind)
                act(plugin, "ntp_add", { server = v, type = kind }, _("Time server added"), { text = _("Saving…") })
            end)
    end, { ok = _("Next"), okIcon = "chevron-right", description = _("A name or address, such as 0.pool.ntp.org.") })
end

-- DHCP server

--- A DHCP server's field changed (API names: range_from, dnsserver…), checked as the web page's are.
local function setDhcp(plugin, s, field, value)
    local v, why = plugin:dhcpValue(field, value)
    if v == nil then return KO.toast(why, 3) end
    act(plugin, "dhcp_set", { iface = s.id, fields = { [field] = v } }, _("Saved"), { text = _("Saving…") })
end

function UI.dhcp(plugin)
    configPage(plugin, "dhcp", _("DHCP server"), function(v, t)
        local d = plugin:data()
        if #v.servers == 0 then t[#t + 1] = { message = _("No DHCP servers.") } end
        for __, s in ipairs(v.servers) do
            t[#t + 1] = { text = ifaceName(d, s.id), sub = s.enabled and M.rangeText(s) or _("Off"), icon = "server",
                dot = dotOf(s.enabled), chevron = true, callback = function() UI.dhcpServer(plugin, s.id) end }
        end
        t[#t + 1] = { note = _("Each interface's DHCP server: its range, pools and options. Static mappings have their own page.") }
        return t
    end)
end

function UI.dhcpServer(plugin, iface)
    local d0 = plugin:data()
    configPage(plugin, "dhcp", T(_("DHCP on %1"), ifaceName(d0, iface)), function(v, t)
        local s
        for __, x in ipairs(v.servers) do if x.id == iface then s = x end end
        if not s then
            t[#t + 1] = { message = _("It isn't in pfSense any more.") }
            return t
        end
        local function edit(field, title, value, description)
            return function()
                ask(title, value, function(x) setDhcp(plugin, s, field, trim(x)) end, { description = description })
            end
        end
        t[#t + 1] = { band = _("SERVER") }
        t[#t + 1] = { toggle = s.enabled, text = _("DHCP server"), sub = _("Applied at once"), callback = function()
            offAsks(not s.enabled, { title = _("Turn this DHCP server off?"),
                text = _("Devices on this network stop getting addresses as their leases run out, and new ones get none (the Kindle too if it's on it).") },
                function() setDhcp(plugin, s, "enable", not s.enabled) end)
        end }
        row(t, _("Range from"), s.from, edit("range_from", _("Range from"), s.from, _("The first address it gives, such as 192.168.1.10.")))
        row(t, _("Range to"), s.to, edit("range_to", _("Range to"), s.to, _("The last address it gives, such as 192.168.1.42.")))
        row(t, _("DNS servers"), #s.dns > 0 and table.concat(s.dns, ", ") or _("pfSense's"),
            edit("dnsserver", _("DNS servers"), table.concat(s.dns, ", "), _("Several with commas; empty: pfSense's own.")))
        row(t, _("Gateway"), s.gateway ~= "" and s.gateway or _("The interface's address"),
            edit("gateway", _("Gateway"), s.gateway, _("Empty: the interface's address; none: no gateway.")))
        row(t, _("Domain"), s.domain ~= "" and s.domain or _("pfSense's"), edit("domain", _("Domain"), s.domain, _("Such as home.example.com; empty: pfSense's own.")))
        row(t, _("Lease time"), M.duration(s.lease),
            edit("defaultleasetime", _("Lease time"), s.lease and tostring(s.lease) or "", _("In seconds, such as 7200 (2 h); empty: pfSense's default.")))
        row(t, _("Longest lease"), M.duration(s.maxLease),
            edit("maxleasetime", _("Longest lease"), s.maxLease and tostring(s.maxLease) or "", _("In seconds, such as 86400 (1 day); empty: pfSense's default.")))
        t[#t + 1] = { band = _("ADDRESS POOLS"), right = tostring(#s.pools) }
        t[#t + 1] = { tiles = { { icon = "plus", text = _("Add a pool"), fn = function()
            ask(_("Pool from"), "", function(from)
                from = trim(from)
                if not M.isIPv4(from) then return KO.toast(_("Enter an IP address, such as 192.168.1.20")) end
                ask(_("Pool to"), "", function(to)
                    to = trim(to)
                    if not M.isIPv4(to) then return KO.toast(_("Enter an IP address, such as 192.168.1.20")) end
                    act(plugin, "pool_add", { parent = s.id, from = from, to = to }, _("Pool added"), { text = _("Saving…") })
                end, { ok = _("Add"), okIcon = "plus", description = _("The pool's last address.") })
            end, { ok = _("Next"), okIcon = "chevron-right", description = _("Another range of addresses on this network: its first address.") })
        end } }, cols = 3 }
        for __, x in ipairs(s.pools) do
            t[#t + 1] = { text = x.name, sub = x.domain ~= "" and x.domain or nil, icon = "list", chevron = true, callback = function()
                KO.list(x.name, { { text = _("Delete"), fn = function()
                    plugin:act("pool_delete", { parent = x.parent, id = x.id, from = x.from, to = x.to }, function(ok, text)
                        if not ok then return KO.message(text, _("pfSense")) end
                        KO.undo(_("Pool deleted"), function()
                            act(plugin, "pool_add", { parent = x.parent, from = x.from, to = x.to }, _("Pool put back"))
                        end)
                    end, { text = _("Deleting…") })
                end } })
            end }
        end
        t[#t + 1] = { band = _("CUSTOM OPTIONS"), right = tostring(#s.options) }
        t[#t + 1] = { tiles = { { icon = "plus", text = _("Add an option"), fn = function() UI.addOption(plugin, s.id) end } }, cols = 3 }
        for __, o in ipairs(s.options) do
            t[#t + 1] = { text = T(_("Option %1"), o.number), sub = T("%1 · %2", o.type, o.value), icon = "sliders-horizontal", chevron = true,
                callback = function()
                    KO.list(T(_("Option %1"), o.number), { { text = _("Delete"), fn = function()
                        plugin:act("option_delete", { parent = o.parent, id = o.id, number = o.number, value = o.value }, function(ok, text)
                            if not ok then return KO.message(text, _("pfSense")) end
                            KO.undo(_("Option deleted"), function()
                                act(plugin, "option_add", { parent = o.parent, number = o.number, type = o.type, value = o.value }, _("Option put back"))
                            end)
                        end, { text = _("Deleting…") })
                    end } })
                end }
        end
        return t
    end)
end

-- The custom options' types, as the API names them.
local OPTION_TYPES = { "text", "string", "boolean", "unsigned integer 8", "unsigned integer 16", "unsigned integer 32",
    "signed integer 8", "signed integer 16", "signed integer 32", "ip-address" }

function UI.addOption(plugin, parent)
    ask(_("Option number"), "", function(v)
        local n = tonumber(trim(v))
        if not n or n < 1 or n > 254 then return KO.toast(_("Enter the option's number (1 to 254)")) end
        local options = {}
        for __, x in ipairs(OPTION_TYPES) do options[#options + 1] = { label = x, value = x } end
        KO.choose(_("Type"), options, "text", function(kind)
            ask(_("Value"), "", function(value)
                act(plugin, "option_add", { parent = parent, number = math.floor(n), type = kind, value = trim(value) }, _("Option added"),
                    { text = _("Saving…") })
            end, { ok = _("Add"), okIcon = "plus" })
        end)
    end, { ok = _("Next"), okIcon = "chevron-right", description = _("A DHCP option's number, such as 66 (a TFTP server) or 252 (a proxy's settings).") })
end

-- DNS Resolver

function UI.dnsResolver(plugin)
    configPage(plugin, "dnsres", _("DNS Resolver"), function(c, t)
        local function switch(field, on, text, sub, asks)
            t[#t + 1] = { toggle = on, text = text, sub = sub, callback = function()
                local function go() act(plugin, "dnsres_set", { fields = { [field] = not on } }, on and _("Turned off") or _("Turned on"),
                    { text = _("Applying…") }) end
                if asks then return offAsks(not on, asks, go) end
                go()
            end }
        end
        t[#t + 1] = { band = _("DNS RESOLVER") }
        switch("enable", c.enabled, _("DNS Resolver"), T(_("Port %1 · applied at once"), c.port),
            { title = _("Turn the DNS Resolver off?"),
              text = _("Devices that use pfSense for names (most on your network, maybe this Kindle) can't look any up until it's on again.") })
        switch("dnssec", c.dnssec, _("DNSSEC"), _("Checks the answers are signed"))
        switch("forwarding", c.forwarding, _("Forwarding mode"), _("Asks pfSense's DNS servers (System > General) instead of the root servers"))
        t[#t + 1] = { band = _("NAMES FROM DHCP AND VPN") }
        switch("regdhcp", c.regdhcp, _("DHCP leases"), _("Devices' names from their leases"))
        switch("regdhcpstatic", c.regdhcpstatic, _("DHCP static mappings"), _("Their hostnames"))
        switch("regovpnclients", c.regovpnclients, _("OpenVPN clients"), _("Their names"))
        if #c.ifaces > 0 then row(t, _("Listens on"), table.concat(c.ifaces, ", "):upper()) end
        t[#t + 1] = { note = _("Host overrides have their own page (DNS overrides).") }
        return t
    end)
end

-- ------------------------------------------------------------------ aliases

function UI.aliases(plugin)
    listPage(plugin, _("Aliases"), listItems(plugin, "aliases", "api-v2-firewall-aliases-get", function(d, t)
        local q = controls(plugin, "aliases", t)
        local list = M.filter(d.aliases, q)
        if q then
            -- (an alias's entries are searched too)
            list = {}
            for __, a in ipairs(d.aliases) do
                local hit = M.matches(a, q)
                for __, e in ipairs(a.entries) do hit = hit or M.matches(e, q) end
                if hit then list[#list + 1] = a end
            end
        end
        t[#t + 1] = { band = _("ALIASES"), right = tostring(#list) }
        if #d.aliases == 0 then t[#t + 1] = { message = _("No aliases.") } elseif #list == 0 then noneFound(t, q) end
        for __, a in ipairs(list) do
            t[#t + 1] = { text = a.name, sub = M.aliasLine(a), icon = "shield", chevron = true, callback = function() UI.alias(plugin, a.id) end }
        end
        t[#t + 1] = { note = _("Aliases are the lists of addresses, networks or ports that firewall rules use. A change is applied at once.") }
        return t
    end), true)
end

--- An alias by its name (ids move; names are unique).
local function aliasByName(d, name)
    for __, a in ipairs(d and d.aliases or {}) do if a.name == name then return a end end
end

--- An alias's entries set (addresses and their descriptions, in order), with done(ok) after.
local function setAlias(plugin, a, entries, okText, done)
    local addresses, details = {}, {}
    for k, e in ipairs(entries) do addresses[k], details[k] = e.address, e.detail end
    plugin:act("alias_set", { id = a.id, name = a.name, addresses = addresses, details = details }, function(ok, text)
        if ok then
            if okText then KO.toast(okText) end
        else
            KO.message(text, _("pfSense"))
        end
        if done then done(ok) end
    end, { text = _("Saving…") })
end

--- An entry added to an alias: its address (and a description).
local function addEntry(plugin, a, address, detail)
    local entries = {}
    for k, e in ipairs(a.entries) do
        if e.address == address then return KO.toast(T(_("%1 is in %2 already"), address, a.name), 3) end
        entries[k] = e
    end
    entries[#entries + 1] = { address = address, detail = detail or "" }
    setAlias(plugin, a, entries, T(_("Added to %1"), a.name))
end

function UI.alias(plugin, id)
    local d0 = plugin:data()
    local a0 = d0 and M.find(d0, "alias", id)
    local name = a0 and a0.name
    listPage(plugin, name or _("Alias"), function()
        local d = plugin:data()
        local a = aliasByName(d, name)
        local t = {}
        if not a then return gone(plugin, t) end
        t[#t + 1] = { tiles = { { icon = "plus", text = _("Add"), primary = true, fn = function()
            local what = a.type == "port" and _("Port") or (a.type == "network" and _("Network") or _("Address"))
            ask(what, "", function(v)
                v = trim(v)
                if v == "" then return end
                ask(_("Description"), "", function(desc) addEntry(plugin, a, v, trim(desc)) end,
                    { ok = _("Add"), okIcon = "plus", description = _("Optional: what it is.") })
            end, { ok = _("Next"), okIcon = "chevron-right", description = a.type == "port" and _("A port or range, such as 443 or 8000:8080.")
                or (a.type == "network" and _("A network, such as 192.168.1.0/24.") or _("An IP address, a range or a hostname, such as 192.168.1.20.")) })
        end } }, cols = 3 }
        t[#t + 1] = { band = _("ALIAS") }
        row(t, _("Type"), M.aliasType(a))
        row(t, _("Description"), a.descr)
        t[#t + 1] = { band = _("ENTRIES"), right = tostring(#a.entries) }
        if #a.entries == 0 then t[#t + 1] = { message = _("It has no entries.") } end
        for k, e in ipairs(a.entries) do
            t[#t + 1] = { text = e.address, sub = e.detail ~= "" and e.detail or nil, icon = "shield", chevron = true, callback = function()
                KO.list(e.address, { { text = _("Remove"), fn = function()
                    local entries, removed = {}, nil
                    for j, x in ipairs(a.entries) do if j ~= k then entries[#entries + 1] = x else removed = x end end
                    setAlias(plugin, a, entries, nil, function(ok)
                        if not ok then return end
                        KO.undo(T(_("Removed from %1"), a.name), function()
                            local now = aliasByName(plugin:data(), a.name)
                            if now then addEntry(plugin, now, removed.address, removed.detail) end
                        end)
                    end)
                end } })
            end }
        end
        return t
    end, true)
end

--- Add an address to one of the host aliases (from a device's page).
function UI.addToAlias(plugin, ip, name)
    local d = plugin:data()
    local options = {}
    for __, a in ipairs(d and d.aliases or {}) do
        if a.type == "host" then options[#options + 1] = { text = a.descr ~= "" and T("%1 · %2", a.name, a.descr) or a.name,
            fn = function() addEntry(plugin, a, ip, name ~= ip and name or "") end } end
    end
    if #options == 0 then
        return KO.message(_("There's no host alias to add it to. Make one in pfSense: Firewall > Aliases."), _("Add to an alias"))
    end
    KO.list(T(_("Add %1 to"), ip), options)
end

-- ------------------------------------------------------------------ NAT

--- A NAT list's band and rows with their switches (hold: the rule's page).
local function natRows(plugin, t, kind, list, title)
    if not list or #list == 0 then return end
    t[#t + 1] = { band = title, right = tostring(#list) }
    for __, r in ipairs(list) do
        t[#t + 1] = { toggle = not r.disabled, text = r.name, sub = M.natLine(r), callback = function()
            act(plugin, "nat_enabled", { kind = kind, id = r.id, sig = r.sig, on = r.disabled },
                r.disabled and _("Turned on") or _("Turned off"))
        end, hold_callback = function() UI.natRule(plugin, kind, r.id) end }
    end
end

function UI.nat(plugin)
    listPage(plugin, _("NAT"), function()
        local early = notRead(plugin)
        if early then return early end
        local d = plugin:data()
        local t = {}
        local q = controls(plugin, "nat", t)
        if d.skipped.forwards then
            t[#t + 1] = { band = _("PORT FORWARDS") }
            notAllowed(plugin, t, "forwards", "api-v2-firewall-nat-port-forwards-get")
        else
            natRows(plugin, t, "forward", M.filter(d.forwards, q), _("PORT FORWARDS"))
            if d.forwards and #d.forwards == 0 then t[#t + 1] = { band = _("PORT FORWARDS") } t[#t + 1] = { note = _("No port forwards.") } end
        end
        if d.natmode then
            t[#t + 1] = { band = _("OUTBOUND NAT") }
            row(t, _("Mode"), M.natMode(d.natmode))
        end
        natRows(plugin, t, "outbound", M.filter(d.outbound, q), d.natmode and _("OUTBOUND MAPPINGS") or _("OUTBOUND NAT"))
        natRows(plugin, t, "onetoone", M.filter(d.onetoone, q), _("1:1 NAT"))
        t[#t + 1] = { note = _("Tap a switch to turn a rule on or off (applied at once). Hold one for its details.") }
        return t
    end, true)
end

function UI.natRule(plugin, kind, id)
    local d0 = plugin:data()
    local r0 = d0 and M.find(d0, kind, id)
    local sig = r0 and r0.sig
    listPage(plugin, r0 and r0.name or _("NAT"), function()
        local d = plugin:data()
        local r
        -- (by what it is, not its place in the list)
        for __, x in ipairs(d and d[M.KINDS[kind]] or {}) do
            local same = sig ~= nil
            for f, v in pairs(sig or {}) do if x.sig[f] ~= v then same = false end end
            if same then r = x end
        end
        local t = {}
        if not r then return gone(plugin, t) end
        t[#t + 1] = { band = kind == "forward" and _("PORT FORWARD") or (kind == "outbound" and _("OUTBOUND NAT") or _("1:1 NAT")) }
        t[#t + 1] = { toggle = not r.disabled, text = _("Enabled"), sub = _("Applied at once"), callback = function()
            act(plugin, "nat_enabled", { kind = kind, id = r.id, sig = r.sig, on = r.disabled }, r.disabled and _("Turned on") or _("Turned off"))
        end }
        row(t, _("Interface"), r.iface:upper())
        row(t, _("Protocol"), r.protocol and r.protocol ~= "" and r.protocol:upper() or nil)
        if kind == "forward" then
            row(t, _("Source"), r.source)
            row(t, _("Destination"), r.dest .. (r.dport ~= "" and (":" .. r.dport) or ""))
            row(t, _("Forwarded to"), r.target .. (r.lport ~= "" and (":" .. r.lport) or ""))
        elseif kind == "outbound" then
            row(t, _("Source"), r.source)
            row(t, _("Destination"), r.dest)
            row(t, _("Translated to"), r.nonat and _("No NAT") or (r.target ~= "" and r.target or _("Interface address")))
        else
            row(t, _("External address"), r.external)
            row(t, _("Internal address"), r.source)
            row(t, _("Destination"), r.dest)
        end
        row(t, _("Description"), r.descr)
        return t
    end, true)
end

-- ------------------------------------------------------------------ connections and ping

--- A device's connections (the firewall states from or to its address), with Close all.
function UI.connections(plugin, ip, name)
    local list, why
    local p
    local function load()
        list, why = nil, nil
        plugin:states(ip, function(l, text)
            list, why = l, text
            if alive(p) then UI.refreshAll() end
        end)
    end
    p = page(name and name ~= ip and T("%1 · %2", name, ip) or ip, function()
        local t = {}
        if not list then
            t[#t + 1] = { message = why or _("Reading the connections…") }
            return t
        end
        t[#t + 1] = { tiles = { { icon = "ban", text = _("Close all"), fn = function()
            KO.confirm{ title = T(_("Close %1's connections?"), name or ip),
                text = _("Everything it has open is cut off now, so a block (a rule or an alias) works at once. It can connect again where it's allowed to."),
                ok = _("Close all"), cancel = _("Cancel"), danger = true,
                onOk = function()
                    plugin:act("kill_states", { ip = ip }, function(ok, text)
                        if ok then KO.toast(_("Connections closed")) load() else KO.message(text, _("pfSense")) end
                    end, { text = _("Closing…") })
                end }
        end } }, cols = 3 }
        t[#t + 1] = { band = _("CONNECTIONS"), right = tostring(#list) }
        if #list == 0 then t[#t + 1] = { message = _("No connections now.") } end
        for __, x in ipairs(list) do
            local sub = {}
            for __, v in ipairs({ x.protocol:upper(), x.iface, x.state, x.age }) do if v ~= "" then sub[#sub + 1] = v end end
            t[#t + 1] = { text = T("%1 → %2", x.source, x.dest), sub = table.concat(sub, " · "), icon = "plug",
                right = x.bytes > 0 and M.bytes(x.bytes) or nil }
        end
        return t
    end, { on_refresh = function() load() UI.refreshAll() end })
    load()
end

--- Connections: which device (its address).
function UI.askConnections(plugin)
    ask(_("Connections"), "", function(v)
        v = trim(v)
        if not M.isIPv4(v) then return KO.toast(_("Enter an IP address, such as 192.168.1.20")) end
        local d = plugin:data()
        local name
        for __, l in ipairs(d and d.leases or {}) do if l.ip == v then name = l.name end end
        UI.connections(plugin, v, name)
    end, { ok = _("Show"), okIcon = "search", description = _("A device's IP address: its connections through the firewall now. Devices and the ARP table have it on each one's page too.") })
end

--- A ping from pfSense, its answer to read.
function UI.ping(plugin, host)
    plugin:ping(host, function(r, why)
        if not r then return KO.message(why, _("Ping")) end
        local title = r.ok and T(_("%1 answers"), host) or T(_("%1 doesn't answer"), host)
        local read = KO.read()
        if read then
            return read{ title = title, text = r.output ~= "" and r.output or title,
                buttons = { { icon = "check", text = _("Done"), primary = true } } }
        end
        KO.message(r.output, title)
    end)
end

function UI.askPing(plugin)
    ask(_("Ping"), "", function(v)
        v = trim(v)
        if v == "" then return end
        UI.ping(plugin, v)
    end, { ok = _("Ping"), okIcon = "wifi", description = _("An IP address or a name, pinged from pfSense (three times), such as 1.2.3.4 or example.com.") })
end

-- ------------------------------------------------------------------ certificates and history

function UI.certs(plugin)
    listPage(plugin, _("Certificates"), listItems(plugin, "certs", "api-v2-system-certificates-get", function(d, t)
        t[#t + 1] = { band = _("CERTIFICATES"), right = tostring(#d.certs) }
        if #d.certs == 0 then t[#t + 1] = { message = _("No certificates.") } end
        for __, c in ipairs(d.certs) do
            t[#t + 1] = { text = c.name, sub = M.certLine(c) .. (c["until"] ~= "" and (" · " .. c["until"]) or ""), icon = "lock",
                dot = c.days and dotOf(not M.certSoon(c)) or nil }
        end
        if d.acme and #d.acme > 0 then
            t[#t + 1] = { band = _("ACME (LET'S ENCRYPT)"), right = tostring(#d.acme) }
            for __, a in ipairs(d.acme) do
                t[#t + 1] = { text = a.name, sub = a.active and (a.descr ~= "" and a.descr or nil) or _("Disabled"), icon = "lock",
                    chevron = true, callback = function()
                        KO.list(a.name, { { text = _("Renew now"), fn = function()
                            act(plugin, "acme_renew", { name = a.name }, _("Renewal started: the ACME package renews it in the background"))
                        end } })
                    end }
            end
        end
        t[#t + 1] = { note = T(_("A certificate that runs out within %1 days shows under Needs attention, with a notification."), M.CERT_DAYS) }
        return t
    end), true)
end

function UI.history(plugin)
    local list, why
    local p
    local function load()
        plugin:history(function(l, text)
            list, why = l, text
            if alive(p) then UI.refreshAll() end
        end)
    end
    p = page(_("Config history"), function()
        local t = {}
        if not list then
            t[#t + 1] = { message = why or _("Reading…") }
            return t
        end
        local q = controls(plugin, "history", t)
        local found = M.filter(list, q)
        t[#t + 1] = { band = _("CHANGES"), right = tostring(#found) }
        if #list == 0 then t[#t + 1] = { message = _("No changes kept.") } elseif #found == 0 then noneFound(t, q) end
        for __, x in ipairs(found) do
            local when = x.time and (os.date("%b %d", x.time) .. " · " .. M.clock(x.time, twentyFour())) or ""
            t[#t + 1] = { text = x.description ~= "" and x.description or _("Change"), sub = when, icon = "history" }
        end
        return t
    end, { on_refresh = function() list = nil UI.refreshAll() load() end })
    load()
end

-- ------------------------------------------------------------------ more

function UI.reboot(plugin)
    KO.confirm{ title = _("Reboot pfSense?"),
        text = _("The network is down for a few minutes while it restarts, the Kindle's Wi-Fi too if it goes through this firewall."),
        ok = _("Reboot"), cancel = _("Cancel"), danger = true,
        onOk = function()
            plugin:act("reboot", {}, function(ok, text)
                if ok then KO.toast(_("pfSense is restarting"), 4) else KO.message(text, _("pfSense")) end
            end, { text = _("Rebooting…") })
        end }
end

function UI.update(plugin)
    KO.confirm{ title = _("Update pfSense?"),
        text = _("pfSense looks for a newer version, installs it and restarts by itself. The network is down meanwhile, sometimes for several minutes. Nothing happens when it's up to date."),
        ok = _("Update"), cancel = _("Cancel"), danger = true,
        onOk = function()
            plugin:act("update", {}, function(ok, text)
                if ok then KO.toast(_("pfSense is updating"), 4) else KO.message(text, _("pfSense")) end
            end, { text = _("Starting the update…") })
        end }
end

function UI.details(plugin)
    page(_("Details"), function()
        local c = plugin:cfg()
        local d = plugin:data()
        local t = { { band = _("CONNECTION") } }
        row(t, _("Name"), plugin:fwName())
        row(t, _("Address"), c.url)
        row(t, _("API key"), c.key and M.masked(c.key) or nil)
        if d and d.system then
            local s = d.system
            t[#t + 1] = { band = _("SYSTEM") }
            row(t, _("Version"), s.version)
            row(t, _("Built"), s.buildtime)
            row(t, _("Platform"), s.platform)
            row(t, _("CPU"), s.cpuModel ~= "" and (s.cpuModel .. (s.cpus and T(_(" (%1 cores)"), s.cpus) or "")) or nil)
            row(t, _("Uptime"), M.uptime(s.uptime))
            row(t, _("Swap"), M.pct(s.swap))
            row(t, _("MBUF"), M.pct(s.mbuf))
            if #s.load == 3 then row(t, _("Load"), string.format("%.2f · %.2f · %.2f", s.load[1], s.load[2], s.load[3])) end
        end
        return t
    end)
end

-- ------------------------------------------------------------------ setting up

--- After the connection changed: read it, and say whether it worked.
local function check(plugin)
    plugin:fetch(function(d, why)
        if d then
            KO.toast(T(_("Connected to %1"), plugin:fwName()))
        else
            KO.message(plugin:whyText(why), _("pfSense didn't answer"))
        end
    end, true)
end

--- The API key, then a check, then saved (and the app opened, when set up from elsewhere).
local function askKey(plugin, url)
    ask(_("API key"), "", function(v)
        v = trim(v)
        if v == "" then return KO.toast(_("Enter the API key")) end
        local c = { url = url, key = v }
        plugin:check(c, function(name, why)
            if not name then return KO.message(plugin:whyText(why), _("pfSense didn't answer")) end
            plugin:setCfg({ url = url, key = v, name = name })
            if #UI.pages == 0 then UI.show(plugin) end
            check(plugin)
        end)
    end, { password = true, ok = _("Connect"), okIcon = "check",
        description = _("From pfSense: System > REST API > Keys. API keys must be allowed in System > REST API > Settings.") })
end

--- Setting up: the address, then the key.
function UI.setup(plugin)
    ask(_("Address"), plugin:cfg().url or "", function(v)
        local url = M.cleanUrl(v)
        if not url then return KO.toast(_("Enter the firewall's address, such as https://192.168.1.1")) end
        askKey(plugin, url)
    end, { ok = _("Next"), okIcon = "chevron-right",
        description = _("The firewall's web interface, such as https://192.168.1.1 (its own certificate is fine).") })
end

-- ------------------------------------------------------------------ settings

local EVERY = { 15, 30, 60, 120, 300 }

local function everyName(s)
    if s < 60 then return T(_("%1 seconds"), s) end
    if s == 60 then return _("1 minute") end
    return T(_("%1 minutes"), s / 60)
end

--- The settings rows: DISPLAY first, the connection last.
function UI.settingsItems(plugin, redo)
    local c = plugin:cfg()
    local t = {}
    t[#t + 1] = { band = _("DISPLAY") }
    t[#t + 1] = { setting = true, text = _("Read every"), value = everyName(plugin:interval()),
        hint = _("While pfSense is open. Nothing is read once it closes."),
        callback = function()
            local options = {}
            for __, s in ipairs(EVERY) do table.insert(options, { label = everyName(s), value = s }) end
            KO.choose(_("Read every"), options, plugin:interval(), function(s)
                G_reader_settings:saveSetting("pfsense_interval", s)
                redo()
            end)
        end }
    t[#t + 1] = { band = _("NOTIFICATIONS") }
    t[#t + 1] = { toggle = plugin:notifying(), text = _("Gateways, interfaces and services going down"),
        sub = _("Seen while pfSense is read; it goes when they're back"),
        callback = function()
            G_reader_settings:saveSetting("pfsense_notify", not plugin:notifying())
            redo()
        end }
    t[#t + 1] = { band = _("CONNECTION") }
    t[#t + 1] = { setting = true, text = _("Address"), value = c.url or _("Not set"), callback = function()
        ask(_("Address"), c.url or "", function(v)
            local url = M.cleanUrl(v)
            if not url then return KO.toast(_("Enter the firewall's address, such as https://192.168.1.1")) end
            plugin:setCfg({ url = url })
            redo()
            if plugin:configured() then check(plugin) end
        end, { description = _("The firewall's web interface, such as https://192.168.1.1.") })
    end }
    t[#t + 1] = { setting = true, text = _("API key"), value = c.key and M.masked(c.key) or _("Not set"), callback = function()
        ask(_("API key"), "", function(v)
            v = trim(v)
            if v == "" then return end
            plugin:setCfg({ key = v })
            redo()
            if plugin:configured() then check(plugin) end
        end, { password = true, description = _("From pfSense: System > REST API > Keys.") })
    end }
    if plugin:configured() and PS().showConnectionTest then
        t[#t + 1] = { setting = true, text = _("Test connection"), callback = function() PS().showConnectionTest("pfsense") end }
    end
    if plugin:configured() then
        t[#t + 1] = { setting = true, text = _("Remove connection"), callback = function()
            local before = plugin:cfg()
            plugin:setCfg({ url = false, key = false, name = false })
            redo()
            KO.undo(_("Connection removed"), function()
                plugin:setCfg(before)
                redo()
            end)
        end }
    else
        t[#t + 1] = { setting = true, text = _("Set up"), callback = function() UI.setup(plugin) end }
    end
    return t
end

function UI.settings(plugin)
    local p
    local function redo()
        p.item_table = UI.settingsItems(plugin, redo)
        p:redraw()
    end
    p = page(_("pfSense settings"), UI.settingsItems(plugin, function() redo() end))
end

--- The settings' names, for the launcher's search.
function UI.searchRows(plugin)
    local out = {}
    for __, r in ipairs(UI.settingsItems(plugin, function() end)) do
        if r.text then table.insert(out, { r.text }) end
    end
    return out
end

function UI.help()
    local read = KO.read()
    local text = _([[Shows your pfSense firewall on the Kindle: its health (CPU, memory, disk, temperature), gateways, interfaces and services, the devices on your network (DHCP leases and the ARP table), DHCP static mappings, DNS host overrides, firewall rules, VPN, the logs and packages with updates.

You can start, stop or restart a service, wake a device (Wake-on-LAN), add, change or delete static mappings and host overrides, turn firewall rules on or off, reboot pfSense or start its update.

It also has the DHCP server's and DNS Resolver's settings, pf's tables (look an address up, empty a block list), the service watchdog, cron jobs, NTP and SSH, and installs or removes packages. Turning a server off, removing a package and emptying a table ask first; deleting something has Undo.

It talks to the REST API package (pfSense-pkg-RESTAPI) with an API key. Install the package, allow API keys in System > REST API > Settings (Authentication methods), and make a key in System > REST API > Keys. The key can do what its user is allowed to: page-all for everything, or the API privileges for what you want.

pfSense is read while the app is open, and when the launcher shows its tile or a quick button. Nothing runs in the background.]])
    if read then
        return read{ title = _("pfSense"), text = text, buttons = { { icon = "check", text = _("Done"), primary = true } } }
    end
    KO.message(text, _("pfSense"))
end

return UI
