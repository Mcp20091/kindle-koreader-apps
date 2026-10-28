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
  Logs                the system and firewall logs, newest first
  Packages            installed ones and their updates
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
    { "logs", "scroll-text", _("Logs") },
    { "packages", "package", _("Packages") },
}

-- A browse tile's second line when nothing read says more (every tile has one, so they line up).
local BROWSE_SUB = { logs = _("System and firewall"), packages = _("Updates"), vpn = _("WireGuard and OpenVPN") }

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
        local icons = { gateway = "activity", interface = "network", service = "cpu" }
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
        logs = UI.logs, packages = UI.packages }
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

-- ------------------------------------------------------------------ gateways and interfaces

function UI.gateways(plugin)
    listPage(plugin, _("Gateways"), listItems(plugin, "gateways", "api-v2-status-gateways-get", function(d, t)
        t[#t + 1] = { band = _("GATEWAYS"), right = tostring(#d.gateways) }
        if #d.gateways == 0 then t[#t + 1] = { message = _("No gateways.") } end
        for __, g in ipairs(d.gateways) do
            t[#t + 1] = { text = g.name, sub = M.gatewayLine(g), icon = "activity", dot = dotOf(g.state ~= "down"),
                chevron = true, callback = function() UI.gateway(plugin, g.id) end }
        end
        return t
    end))
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
        return t
    end)
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
        t[#t + 1] = { band = _("SERVICES"), right = tostring(#d.services) }
        for __, s in ipairs(d.services) do
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
        t[#t + 1] = { band = _("DHCP LEASES"), right = T(_("%1 online"), c.online) }
        if #d.leases == 0 then t[#t + 1] = { message = _("No DHCP leases.") } end
        for __, l in ipairs(d.leases) do
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
        local tiles = { { icon = "zap", text = _("Wake"), fn = function() wake(plugin, l.iface, l.mac) end } }
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
        t[#t + 1] = { band = _("ARP TABLE"), right = tostring(#d.arp) }
        if #d.arp == 0 then t[#t + 1] = { message = _("The ARP table is empty.") } end
        for __, a in ipairs(d.arp) do
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
        if #d.statics == 0 then t[#t + 1] = { message = _("No static mappings yet.") } end
        local by, order = {}, {}
        for __, s in ipairs(d.statics) do
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
        t[#t + 1] = { band = _("HOST OVERRIDES"), right = tostring(#d.overrides) }
        if #d.overrides == 0 then t[#t + 1] = { message = _("No host overrides yet.") } end
        for __, o in ipairs(d.overrides) do
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
        if #d.rules == 0 then t[#t + 1] = { message = _("No firewall rules.") } end
        local by, order = {}, {}
        for __, r in ipairs(d.rules) do
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
        if d.peers and #d.peers > 0 then
            local c = M.counts(d)
            t[#t + 1] = { band = _("WIREGUARD PEERS"), right = T(_("%1 connected"), c.peersOnline) }
            for __, p in ipairs(d.peers) do
                local sub = M.peerLine(p)
                if p.endpoint ~= "" and p.online then sub = sub .. " · " .. p.endpoint end
                t[#t + 1] = { text = p.name, sub = sub, icon = "key-round", dot = dotOf(p.online),
                    right = (p.rx + p.tx > 0) and M.bytes(p.rx + p.tx) or nil }
            end
        end
        if d.ovpn and #d.ovpn > 0 then
            for __, s in ipairs(d.ovpn) do
                t[#t + 1] = { band = s.name:upper(), right = T(_("%1 connected"), #s.conns) }
                if #s.conns == 0 then t[#t + 1] = { note = _("No one connected.") } end
                for __, c in ipairs(s.conns) do
                    local sub = {}
                    for __, x in ipairs({ c.vip, c.remote, c.since }) do if x ~= "" then sub[#sub + 1] = x end end
                    t[#t + 1] = { text = c.name ~= "" and c.name or c.remote, icon = "laptop", dot = "on",
                        sub = table.concat(sub, " · ") }
                end
            end
        end
        if #t == 0 then
            t[#t + 1] = { message = _("No VPN to show.") }
            t[#t + 1] = { note = _("WireGuard peers (with the WireGuard package) and OpenVPN servers show here.") }
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
        local t = { { chips = { chip("system", _("System")), chip("firewall", _("Firewall")) } } }
        if busy and not lines then t[#t + 1] = { message = _("Reading…") } return t end
        if not lines then t[#t + 1] = { message = why or _("Reading…") } return t end
        if #lines == 0 then t[#t + 1] = { message = _("The log is empty.") } return t end
        for __, s in ipairs(lines) do
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

function UI.packages(plugin)
    local list, why
    local p
    local function load(again)
        plugin:packages(function(l, text)
            list, why = l, text
            if alive(p) then UI.refreshAll() end
        end, again)
    end
    p = page(_("Packages"), function()
        local t = {}
        if not list then
            t[#t + 1] = { message = why or _("Asking pfSense's package server…") }
            return t
        end
        local updates = {}
        for __, x in ipairs(list) do if x.update then updates[#updates + 1] = x end end
        if #updates > 0 then
            t[#t + 1] = { band = _("UPDATES"), right = tostring(#updates) }
            for __, x in ipairs(updates) do
                t[#t + 1] = { text = x.short, sub = T(_("%1 → %2"), x.installed, x.latest), icon = "circle-arrow-up", dot = "off" }
            end
            t[#t + 1] = { note = _("Update packages in pfSense's web interface: System > Package Manager. The REST API can't update them.") }
        end
        t[#t + 1] = { band = _("INSTALLED"), right = tostring(#list) }
        if #list == 0 then t[#t + 1] = { message = _("No packages installed.") } end
        for __, x in ipairs(list) do
            if not x.update then
                t[#t + 1] = { text = x.short, sub = x.installed ~= "" and x.installed or nil, icon = "package", right = _("Up to date") }
            end
        end
        return t
    end, { on_refresh = function() list, why = nil, nil UI.refreshAll() load(true) end })
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

It talks to the REST API package (pfSense-pkg-RESTAPI) with an API key. Install the package, allow API keys in System > REST API > Settings (Authentication methods), and make a key in System > REST API > Keys. The key can do what its user is allowed to: page-all for everything, or the API privileges for what you want.

pfSense is read while the app is open, and when the launcher shows its tile or a quick button. Nothing runs in the background.]])
    if read then
        return read{ title = _("pfSense"), text = text, buttons = { { icon = "check", text = _("Done"), primary = true } } }
    end
    KO.message(text, _("pfSense"))
end

return UI
