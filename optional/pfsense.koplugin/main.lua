--[[--
pfSense: your pfSense firewall on the Kindle, over the REST API package
(pfSense-pkg-RESTAPI, v2) and an API key. The system's health, gateways,
interfaces and services (start, stop, restart), the devices on the network
(DHCP leases, the ARP table; Wake-on-LAN), DHCP static mappings and DNS host
overrides (add, change, delete), firewall rules on or off, VPN status, the
firewall and system logs, packages with updates, reboot and pfSense's update.

Nothing runs in the background: pfSense is read while the app is open, and
when the launcher's tile or a quick button shows it.

Also: the launcher's tile line (appsLine, event ShowPfSense), its settings,
search, setup step, quick buttons, connection test and backup, gestures,
notifications (a gateway, interface or service gone down), and calls for the
web page (webState, webAct).

@module koplugin.pfsense
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local M = require("pfsmodel")

-- Kept while KOReader runs (each book and the library get a new plugin).
local state = {
    data = nil,        -- pfSense as last read (pfsmodel.data)
    time = 0,          -- when
    listsTime = 0,     -- when the lists (devices, rules, mappings…) were last read
    tried = 0,         -- when it was last asked (answered or not)
    why = nil,         -- why the last read failed (nil: it worked)
    reading = false,
    waiting = {},
    line = nil,        -- the launcher's line as last shown
    packages = nil,    -- { list, time } or { why, time }
}

local PfSense = WidgetContainer:extend{
    name = "pfsense",
    is_doc_only = false,
}

-- The pfSense plugin of the open library or book.
local function current()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    return ui and ui.pfsense
end
PfSense.current = current

function PfSense:init()
    self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/pfsense.lua")
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    require("pfsko").flashOnUncover()
    require("pfsui").plugin = self
    self:shareWithApps()
end

function PfSense:onDispatcherRegisterActions()
    Dispatcher:registerAction("pfsense_show", { category = "none", event = "ShowPfSense", title = _("pfSense"), general = true })
end

function PfSense:addToMainMenu(menu_items)
    menu_items.pfsense = {
        text = _("pfSense"),
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

function PfSense:onShowPfSense()
    self:show()
    return true
end

function PfSense:show(page)
    -- App lock (the launcher's): its passcode first, when this app is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask("pfsense", function() self:show(page) end) then return end
    return require("pfsui").show(self, page)
end

-- ------------------------------------------------------------------ the connection's settings

--- { url, key, name } (fields nil until set).
function PfSense:cfg()
    return { url = self.store:readSetting("url"), key = self.store:readSetting("key"), name = self.store:readSetting("name") }
end

function PfSense:configured()
    local c = self:cfg()
    return c.url ~= nil and c.key ~= nil
end

--- Change some of the settings ({ url = …, … }; false clears one); what was read is forgotten.
function PfSense:setCfg(t)
    for k, v in pairs(t) do
        if v == false or v == "" then self.store:delSetting(k) else self.store:saveSetting(k, v) end
    end
    self.store:flush()
    state.data, state.why, state.time, state.listsTime, state.tried, state.packages = nil, nil, 0, 0, 0, nil
    self:changed()
end

--- The firewall's name as shown: its hostname as read, else as saved, else "pfSense".
function PfSense:fwName()
    local d = state.data
    local c = self:cfg()
    return (d and d.hostname ~= "" and d.hostname) or c.name or _("pfSense")
end

--- How often the open app reads pfSense (seconds, 15 to 300).
function PfSense:interval()
    return math.max(15, math.min(300, tonumber(G_reader_settings:readSetting("pfsense_interval")) or 60))
end

--- How a list is sorted (leases, arp, statics, overrides): by ("name" or "ip"), reverse.
function PfSense:sortOf(list)
    return M.sortOf(G_reader_settings:readSetting("pfsense_sort"), list)
end

--- Sort a list (by "name" or "ip"; reverse): kept for next time, the same on the web page.
function PfSense:setSort(list, by, reverse)
    if not M.SORTABLE[list] then return end
    local saved = G_reader_settings:readSetting("pfsense_sort")
    saved = type(saved) == "table" and saved or {}
    saved[list] = { by = by == "ip" and "ip" or "name", reverse = reverse == true }
    G_reader_settings:saveSetting("pfsense_sort", saved)
end

--- A list as read, sorted as the user chose.
function PfSense:sortedList(list)
    local d = state.data
    local by, reverse = self:sortOf(list)
    return M.sorted(d and d[list] or {}, by, reverse)
end

--- Whether a gateway, interface or service going down is a notification.
function PfSense:notifying()
    return G_reader_settings:nilOrTrue("pfsense_notify")
end

-- ------------------------------------------------------------------ reading pfSense

function PfSense:api(cfg)
    return require("pfsapi").new(cfg or self:cfg())
end

--- Why something failed, in plain words. priv: the privilege the key's user needed, for a 403.
function PfSense:whyText(why, priv)
    local s = tostring(why or "")
    local needs = s:match("^forbidden:(.+)$")
    if needs then return T(_("The API key's user needs the %1 privilege (or page-all)."), needs) end
    if s == "forbidden" then
        return priv and T(_("The API key's user needs the %1 privilege (or page-all)."), priv)
            or _("The API key isn't allowed to do that.")
    end
    if s == "signin" then return _("pfSense refused the API key. Check it in Settings, and that API keys are allowed (System > REST API > Settings > Authentication methods).") end
    if s == "notfound" then return _("pfSense doesn't know that address. Is the REST API package installed?") end
    if s == "missing" then return _("That needs a pfSense package that isn't installed.") end
    if s == "changed" then return _("It changed on pfSense since it was read. Read it again (⟳) and try once more.") end
    if s == "notapi" then return _("That address doesn't answer as pfSense's REST API. Enter the firewall's address, such as https://192.168.1.1, and check the REST API package is installed.") end
    if s == "offline" then return _("Not on Wi-Fi.") end
    if s == "notset" then return _("pfSense isn't set up yet.") end
    if s:find("timeout") or s:find("timed out") then return _("pfSense didn't answer in time.") end
    if s:find("refused") then return _("The connection was refused. Is the address and port right?") end
    if s:find("host not found") or s:find("unreachable") or s:find("No route") or s:find("resolve") then
        return _("The firewall can't be reached from this Wi-Fi.")
    end
    if s:find("certificate") or s:find("handshake") or s:find("ssl") then return _("The secure connection failed (its certificate).") end
    if s == "" or s == "nil" or s == "no answer" or s == "nothing" then return _("pfSense didn't answer.") end
    return s
end

--- Read pfSense in the background; done(data) when it is in (nil and why when it didn't
-- answer). full: the lists too (devices, rules, mappings…), not only the status; the first
-- read always has them. One read at a time.
function PfSense:fetch(done, full)
    if done then table.insert(state.waiting, done) end
    if state.reading then return end
    local function finish(d, why)
        local waiting = state.waiting
        state.waiting = {}
        for __, f in ipairs(waiting) do pcall(f, d, why) end
    end
    if not self:configured() then return finish(nil, "notset") end
    if not NetworkMgr:isConnected() then
        state.why = "offline"
        return finish(nil, "offline")
    end
    full = full or state.listsTime == 0 or not state.data
    state.reading, state.tried = true, os.time()
    local api = self:api()
    require("pfsbg").run(function()
        local r, why = api:readAll({ status = true, lists = full })
        if not r then return { why = why } end
        return { raw = r }
    end, function(r, why)
        state.reading = false
        if r and r.raw then
            local before = state.data
            state.data, state.time, state.why = M.merge(before, M.data(r.raw)), os.time(), nil
            if full then state.listsTime = state.time end
            -- (its hostname, for when pfSense isn't answering)
            if state.data.hostname ~= "" and state.data.hostname ~= self.store:readSetting("name") then
                self.store:saveSetting("name", state.data.hostname)
                self.store:flush()
            end
            self:notifyChanges(before, state.data)
            self:changed()
            return finish(state.data)
        end
        state.why = (r and r.why) or why or "no answer"
        logger.info("pfSense: no answer:", state.why)
        self:changed()
        finish(nil, state.why)
    end, { limit = 45 })
end

--- pfSense as last read (nil until read); read again in the background when older than
-- maxAge seconds (and on Wi-Fi).
function PfSense:status(maxAge)
    -- (a firewall that doesn't answer is asked again no sooner than one that does)
    local last = math.max(state.time, state.tried)
    if self:configured() and os.time() - last >= (maxAge or 60) and not state.reading and NetworkMgr:isConnected() then
        self:fetch()
    end
    return state.data
end

function PfSense:data() return state.data end
function PfSense:readTime() return state.time end
function PfSense:lastWhy() return state.why end
function PfSense:reading() return state.reading end

--- The installed packages and their updates: done(list) or done(nil, text). Read once
-- per run (it's slow: pfSense asks its package server), again with again.
function PfSense:packages(done, again)
    local p = state.packages
    if p and not again then
        if p.list then return done(p.list) end
        return done(nil, p.text)
    end
    if not self:configured() or not NetworkMgr:isConnected() then return done(nil, self:whyText("offline")) end
    local api = self:api()
    require("pfsbg").run(function()
        local list, why = api:packages()
        if not list then return { why = why } end
        return { list = list }
    end, function(r, why)
        if r and r.list then
            local out = {}
            for __, x in ipairs(r.list) do out[#out + 1] = M.package(x) end
            table.sort(out, function(a, b) return a.short:lower() < b.short:lower() end)
            state.packages = { list = out, time = os.time() }
            self:changed()
            return done(out)
        end
        why = (r and r.why) or why
        state.packages = { text = self:whyText(why, "api-v2-system-packages-get"), time = os.time() }
        done(nil, state.packages.text)
    end, { limit = 90 })
end

function PfSense:packageList() return state.packages and state.packages.list end

--- Something read only when asked (in a child): done(result) or done(nil, text). fn(api) -> result or nil, why.
function PfSense:ask(fn, priv, done, opts)
    if not self:configured() or not NetworkMgr:isConnected() then return done(nil, self:whyText("offline")) end
    local api = self:api()
    require("pfsbg").run(function()
        local r, why = fn(api)
        if not r then return { why = why } end
        return { r = r }
    end, function(r, why)
        if r and r.r then return done(r.r) end
        done(nil, self:whyText((r and r.why) or why, priv))
    end, { limit = 50, text = opts and opts.text })
end

--- A device's connections (firewall states from or to ip): done(list of pfsmodel.state) or done(nil, text).
function PfSense:states(ip, done)
    self:ask(function(api)
        local list, why = api:states(ip)
        if not list then return nil, why end
        local out = {}
        for k, x in ipairs(list) do out[k] = M.state(x) end
        return out
    end, "api-v2-firewall-states-get", done)
end

--- A ping from pfSense to host: done({ output, ok }) or done(nil, text).
function PfSense:ping(host, done)
    self:ask(function(api) return api:pingHost(host, 3) end, "api-v2-diagnostics-ping-post", done,
        { text = T(_("Pinging %1 from pfSense…"), host) })
end

--- The configuration's history, newest first: done(list) or done(nil, text).
function PfSense:history(done)
    self:ask(function(api) return api:history() end, "api-v2-diagnostics-config-history-revisions-get", done)
end

--- The newest lines of a log (kind: an id of pfsmodel.LOGS, such as "system"), newest first:
-- done(lines) or done(nil, text).
function PfSense:log(kind, done)
    if not self:configured() or not NetworkMgr:isConnected() then return done(nil, self:whyText("offline")) end
    local api = self:api()
    require("pfsbg").run(function()
        local list, why = api:log(kind)
        if not list then return { why = why } end
        local out = {}
        for __, x in ipairs(list) do out[#out + 1] = M.str(type(x) == "table" and x.text or x) end
        return { lines = M.newest(out, M.LOG_LINES) }
    end, function(r, why)
        if r and r.lines then return done(r.lines) end
        done(nil, self:whyText((r and r.why) or why, "api-v2-status-logs-" .. kind:gsub("/", "-") .. "-get"))
    end, { limit = 45 })
end

--- A gateway, interface or service gone down to the shared notifications; it goes when it's back.
function PfSense:notifyChanges(before, after)
    local PS = require("pluginshare")
    if not PS.notify then return end
    local ch = M.changes(before, after)
    for __, key in ipairs(ch.remove) do
        if PS.unnotify then pcall(PS.unnotify, key) end
    end
    if not self:notifying() then return end
    for __, n in ipairs(ch.add) do
        local kind, id = n.kind, n.id
        pcall(PS.notify, { app = "pfsense", name = _("pfSense"), icon = "router", key = n.key, text = n.text,
            route = { kind = kind, id = id },
            open = function() local p = current() if p then p:showItem(kind, id) end end })
    end
end

--- Open pfSense at one thing's page (from a notification or search).
function PfSense:showItem(kind, id)
    -- App lock (the launcher's): its passcode first, when this app is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask("pfsense", function() self:showItem(kind, id) end) then return end
    self:show()
    require("pfsui").item(self, kind, id)
end

--- Redraw what shows pfSense: the app's pages, or the launcher when its line changed.
function PfSense:changed()
    local UI = require("pfsui")
    if #UI.pages > 0 then UI.refreshAll() end
    local line = self:appsLine()
    if line == state.line then return end
    state.line = line
    local apps = self.ui and self.ui.apps
    if apps and apps.changed then pcall(apps.changed, apps) end
end

--- The launcher tile's line: "All up · 14 devices online", "WAN down".
function PfSense:appsLine()
    if not self:configured() then return M.appsLine(nil, false) end
    local d = self:status(120)
    if not d and state.why == "offline" then return _("Not on Wi-Fi") end
    if not d and state.why then return _("pfSense not answering") end
    return M.appsLine(d, true)
end

-- ------------------------------------------------------------------ actions

local function find(kind, id) return state.data and M.find(state.data, kind, id) end

-- What each action does, in the child; the privilege a 403 means the key's user lacks; and
-- the change it makes, put in what was read at once (the next read confirms it).
local ACTIONS = {
    service = { run = function(api, a) return api:service(a.name, a.action) end,
        priv = function() return "api-v2-status-service-post" end,
        apply = function(__, a)
            local s = find("service", a.name)
            if s then s.running = a.action ~= "stop" end
        end },
    rule_enabled = { run = function(api, a) return api:setRule(a.id, a.tracker, a.on) end,
        priv = function() return "api-v2-firewall-rule-patch" end,
        apply = function(__, a) local r = find("rule", a.id) if r then r.disabled = not a.on end end },
    wake = { run = function(api, a) return api:wake(a.iface, a.mac) end,
        priv = function() return "api-v2-services-wake-on-lan-send-post" end },
    static_add = { run = function(api, a) return api:addStatic(a) end, lists = true,
        priv = function() return "api-v2-services-dhcp-server-static-mapping-post" end },
    static_edit = { run = function(api, a) return api:editStatic(a.parent, a.id, a.mac, a.fields) end, lists = true,
        priv = function() return "api-v2-services-dhcp-server-static-mapping-patch" end,
        apply = function(d, a)
            local s = M.findStatic(d, a.parent, a.mac)
            if not s then return end
            for k, v in pairs(a.fields) do s[k] = v end
            s.name = s.hostname ~= "" and s.hostname or (s.descr ~= "" and s.descr or s.mac)
        end },
    static_delete = { run = function(api, a) return api:deleteStatic(a.parent, a.id, a.mac) end, lists = true,
        priv = function() return "api-v2-services-dhcp-server-static-mapping-delete" end,
        apply = function(d, a)
            for k, s in ipairs(d.statics or {}) do
                if s.parent == a.parent and s.mac == a.mac then table.remove(d.statics, k) break end
            end
        end },
    override_add = { run = function(api, a) return api:addOverride(a) end, lists = true,
        priv = function() return "api-v2-services-dns-resolver-host-override-post" end },
    override_edit = { run = function(api, a) return api:editOverride(a.id, a.host, a.domain, a.fields) end, lists = true,
        priv = function() return "api-v2-services-dns-resolver-host-override-patch" end },
    override_delete = { run = function(api, a) return api:deleteOverride(a.id, a.host, a.domain) end, lists = true,
        priv = function() return "api-v2-services-dns-resolver-host-override-delete" end,
        apply = function(d, a)
            for k, o in ipairs(d.overrides or {}) do
                if o.id == a.id then table.remove(d.overrides, k) break end
            end
        end },
    arp_delete = { run = function(api, a) return api:deleteArp(a.id, a.ip) end, lists = true,
        priv = function() return "api-v2-diagnostics-arp-table-entry-delete" end,
        apply = function(d, a)
            for k, x in ipairs(d.arp or {}) do
                if x.id == a.id then table.remove(d.arp, k) break end
            end
        end },
    reboot = { run = function(api) return api:reboot() end, quiet = true,
        priv = function() return "api-v2-diagnostics-reboot-post" end },
    update = { run = function(api) return api:update() end, quiet = true,
        priv = function() return "api-v2-system-update-post" end },
    -- An alias's entries as a whole ({ id, name, addresses, details }).
    alias_set = { run = function(api, a) return api:setAlias(a.id, a.name, a.addresses, a.details) end, lists = true,
        priv = function() return "api-v2-firewall-alias-patch" end,
        apply = function(d, a)
            local x = M.find(d, "alias", a.id)
            if not x or x.name ~= a.name then return end
            x.entries = {}
            for k, addr in ipairs(a.addresses) do x.entries[k] = { address = addr, detail = a.details[k] or "" } end
        end },
    -- A NAT rule on or off ({ kind = forward | outbound | onetoone, id, sig, on }).
    nat_enabled = { run = function(api, a) return api:setNat(a.kind, a.id, a.sig, a.on) end,
        priv = function(a) return ({ forward = "api-v2-firewall-nat-port-forward-patch",
            outbound = "api-v2-firewall-nat-outbound-mapping-patch", onetoone = "api-v2-firewall-nat-one-to-one-mapping-patch" })[a.kind] end,
        apply = function(d, a) local r = M.find(d, a.kind, a.id) if r then r.disabled = not a.on end end },
    kill_states = { run = function(api, a) return api:killStates(a.ip) end,
        priv = function() return "api-v2-firewall-states-delete" end },
    default_gw = { run = function(api, a) return api:setDefaultGateway(a.family, a.name) end, lists = true,
        priv = function() return "api-v2-routing-gateway-default-patch" end,
        apply = function(d, a) if d.defaultgw then d.defaultgw[a.family] = a.name end end },
    route_enabled = { run = function(api, a) return api:setRoute(a.id, a.network, a.gateway, a.on) end,
        priv = function() return "api-v2-routing-static-route-patch" end,
        apply = function(d, a) local r = M.find(d, "route", a.id) if r then r.disabled = not a.on end end },
    wg_enabled = { run = function(api, a) return api:setWgPeer(a.num, a.key, a.on) end,
        priv = function() return "api-v2-vpn-wireguard-peer-patch" end,
        apply = function(d, a) local r = M.find(d, "wgpeer", a.key) if r then r.enabled = a.on end end },
    ovpn_kill = { run = function(api, a) return api:killOvpn(a.parent, a.id, a.name, a.remote) end, lists = true,
        priv = function() return "api-v2-status-openvpn-server-connection-delete" end,
        apply = function(d, a)
            for k, c in ipairs(d.ovpnconns or {}) do
                if c.parent == a.parent and c.id == a.id then table.remove(d.ovpnconns, k) break end
            end
        end },
    acme_renew = { run = function(api, a) return api:renewAcme(a.name) end, lists = true,
        priv = function() return "api-v2-services-acme-certificate-renew-post" end },
}
PfSense.ACTIONS = ACTIONS

--- Do an action in the background; then done(ok, text) (text: why it failed, in plain
-- words) and pfSense read again (not after reboot or update: it's going away).
-- opts.text: a waiting message meanwhile.
function PfSense:act(name, args, done, opts)
    local a = ACTIONS[name]
    if not a then return done and done(false, "Unknown action") end
    if not self:configured() then return done and done(false, self:whyText("notset")) end
    if not NetworkMgr:isConnected() then return done and done(false, self:whyText("offline")) end
    local api = self:api()
    args = args or {}
    if state.data and a.apply then
        a.apply(state.data, args)
        self:changed()
    end
    require("pfsbg").run(function()
        local ok, why = a.run(api, args)
        if not ok then return { why = why or "refused" } end
        return { ok = true }
    end, function(r, why)
        local good = r and r.ok
        local text
        if not good then
            why = (r and r.why) or why
            logger.warn("pfSense:", name, why)
            text = self:whyText(why, a.priv(args))
        end
        -- (read again: confirms the change, or puts back what it couldn't do)
        if not a.quiet then
            UIManager:scheduleIn(good and 1 or 0, function() self:fetch(nil, a.lists or not good) end)
        end
        if done then done(good and true or false, text) end
    end, { limit = 60, text = opts and opts.text })
end

--- Whether the key reads this firewall: done(name) or done(nil, why). cfg: { url, key }.
function PfSense:check(cfg, done)
    if not NetworkMgr:isConnected() then return done(nil, "offline") end
    local api = self:api(cfg)
    require("pfsbg").run(function()
        local ok, why = api:ping()
        if not ok then return { why = why } end
        local s
        s, why = api:request("GET", "/status/system")
        if not s then return { why = why == "forbidden" and "forbidden:api-v2-status-system-get" or why } end
        local h = api:request("GET", "/system/hostname")
        return { name = type(h) == "table" and M.str(h.hostname) or "" }
    end, function(r, why)
        if r and r.name then return done(r.name ~= "" and r.name or _("pfSense")) end
        done(nil, (r and r.why) or why)
    end, { limit = 30, text = _("Connecting to pfSense…") })
end

-- ------------------------------------------------------------------ the launcher

function PfSense:shareWithApps()
    local PS = require("pluginshare")
    -- What it is, for the launcher and the web page: its tile, its Settings group, its web tab.
    PS.appInfo = PS.appInfo or {}
    PS.appInfo.pfsense = { name = _("pfSense"), icon = "router", dir = self.path, order = 88, group = "optional",
        -- "All up · 14 devices online", "WAN down".
        tiles = { { key = "pfsense", group = "tools", event = "ShowPfSense", line = function(p) return p:appsLine() end } },
        web = { page = "pfsense", routes = "webpfsense", script = "web/pfsense.js",
            card = "Your firewall: gateways, services, devices, DHCP and DNS entries, and firewall rules." } }
    PS.notifyOpeners = PS.notifyOpeners or {}
    PS.notifyOpeners.pfsense = function(route)
        local p = current()
        if not p then return end
        if type(route) == "table" and route.kind then p:showItem(route.kind, route.id) else p:show() end
    end
    -- App lock: Settings > Launcher > App lock can lock it (it asks in show).
    PS.lockApps = PS.lockApps or {}
    PS.lockApps.pfsense = { key = "pfsense", name = _("pfSense"), plugin = "pfsense" }
    -- The web page's backup: the connection and the settings; the API key only with
    -- Include keys and sign-ins.
    PS.backupApps = PS.backupApps or {}
    PS.backupApps.pfsense = { key = "pfsense", name = _("pfSense"),
        files = { "^pfsense%.lua$" },
        reader_keys = { "^pfsense_" },
        secret_keys = { ["pfsense.lua"] = { "key" } } }
    if PS.registerSettings then
        PS.registerSettings{ key = "pfsense", name = _("pfSense"), icon = "router",
            open = function() local p = current() if p then p:show("settings") end end,
            rows = function()
                local p = current()
                return p and require("pfsui").searchRows(p) or {}
            end }
    end
    if PS.registerSearch then
        PS.registerSearch{ key = "pfsense", name = _("pfSense"), icon = "router", search = function(q)
            local p = current()
            return p and p:search(q) or {}
        end }
    end
    if PS.registerSetup then
        PS.registerSetup{ key = "pfsense", order = 59, icon = "router", title = _("pfSense"),
            text = _("Your pfSense firewall on the Kindle: gateways, services, the devices on your network, DHCP and DNS entries, firewall rules and logs."),
            done = function() local p = current() return p ~= nil and p:configured() end,
            doneText = _("pfSense set up"), action = _("Set up"),
            skipped = _("Nothing else needs it. Set it up any time from the pfSense app."),
            help = { button = _("What you need"), title = _("Connecting to pfSense"),
                steps = {
                    _("The REST API package (pfSense-pkg-RESTAPI) installed on pfSense."),
                    _("API keys allowed: System > REST API > Settings > Authentication methods."),
                    _("An API key from System > REST API > Keys, made by a user with the privileges for what you want to see and change."),
                },
                after = _("The key stays on the Kindle and is only sent to your firewall."),
                guide = "pfsense.md" },
            run = function() local p = current() if p then require("pfsui").setup(p) end end }
    end
    if PS.registerTest then
        PS.registerTest{ key = "pfsense", name = _("pfSense"),
            configured = function() local p = current() return p ~= nil and p:configured() end,
            run = function(Test)
                local p = current()
                local c = p and p:cfg() or {}
                local api = require("pfsapi").new(c)
                local socket = require("socket")
                local rows = {}
                local started = socket.gettime()
                local ok, why = api:ping()
                local row = { name = _("REST API"), detail = M.apiBase(c.url),
                    ms = math.floor((socket.gettime() - started) * 1000) }
                row.ok = ok
                if not ok then row.raw, row.why = tostring(why), (p and p:whyText(why)) or Test.why(why) end
                table.insert(rows, row)
                if ok then
                    started = socket.gettime()
                    local s
                    s, why = api:request("GET", "/status/system")
                    row = { name = _("API key"), detail = M.masked(c.key),
                        ms = math.floor((socket.gettime() - started) * 1000) }
                    row.ok = s ~= nil
                    if not s then
                        row.raw = tostring(why)
                        row.why = (p and p:whyText(why, "api-v2-status-system-get")) or Test.why(why)
                    end
                    table.insert(rows, row)
                end
                return rows
            end }
    end
    if PS.registerQuick then
        PS.registerQuick{ key = "pfsense", name = _("pfSense"),
            choices = function()
                local out = { { id = "status", name = _("pfSense status"), icon = "router", group = _("pfSense") } }
                local d = state.data
                for __, r in ipairs(d and d.rules or {}) do
                    if r.descr ~= "" and r.tracker ~= "" then
                        table.insert(out, { id = "rule:" .. r.tracker, name = r.name, icon = "shield-check", group = _("Firewall rules") })
                    end
                end
                for __, s in ipairs(d and d.statics or {}) do
                    table.insert(out, { id = "wake:" .. s.parent .. ":" .. s.mac, name = T(_("Wake %1"), s.name), icon = "zap", group = _("Wake-on-LAN") })
                end
                for __, r in ipairs(d and d.forwards or {}) do
                    if r.descr ~= "" then
                        table.insert(out, { id = "forward:" .. r.descr, name = r.name, icon = "network", group = _("Port forwards") })
                    end
                end
                for __, w in ipairs(d and d.wgpeers or {}) do
                    table.insert(out, { id = "wg:" .. w.key, name = w.name, icon = "key-round", group = _("WireGuard peers") })
                end
                return out
            end,
            item = function(id)
                local p = current()
                return p and p:quickItem(id)
            end }
    end
end

--- A firewall rule by its tracker (ids move; trackers don't).
local function ruleByTracker(d, tracker)
    for __, r in ipairs(d and d.rules or {}) do
        if r.tracker == tracker then return r end
    end
end

--- A quick button: the status (tap reads it again), a firewall rule on or off, or Wake a device.
function PfSense:quickItem(id)
    if not self:configured() then return nil end
    local d = self:status(120)
    local ko = require("pfsko")
    if id == "status" then
        return { label = self:fwName(), icon = "router", value = d and d.system and M.summary(d) or nil,
            tap = function(done) self:fetch(function() if done then done() end end) end,
            hold = function() self:show() end }
    end
    local tracker = id:match("^rule:(.+)$")
    if tracker then
        local r = ruleByTracker(d, tracker)
        return { label = r and r.name or _("Firewall rule"), icon = "shield-check", on = r and not r.disabled or false,
            value = r and M.ruleLine(r) or nil,
            tap = function(done)
                if not r then
                    ko.toast(_("Not read yet"))
                    return done and done()
                end
                self:act("rule_enabled", { id = r.id, tracker = r.tracker, on = r.disabled }, function(ok, text)
                    if not ok then ko.toast(text, 4) end
                    if done then done() end
                end)
            end,
            hold = function() if r then self:showItem("rule", r.id) else self:show() end end }
    end
    local parent, mac = id:match("^wake:([^:]+):(.+)$")
    if parent then
        local s = d and M.findStatic(d, parent, mac)
        return { label = s and T(_("Wake %1"), s.name) or _("Wake"), icon = "zap", value = s and s.ip or nil,
            tap = function(done)
                self:act("wake", { iface = parent, mac = mac }, function(ok, text)
                    ko.toast(ok and _("Wake-on-LAN sent") or text, ok and 2 or 4)
                    if done then done() end
                end)
            end,
            hold = function() if s then self:showItem("static", s.key) else self:show() end end }
    end
    -- (a port forward by its description, a WireGuard peer by its public key: their ids move)
    local descr = id:match("^forward:(.+)$")
    local key = id:match("^wg:(.+)$")
    if descr or key then
        local r
        for __, x in ipairs(d and (descr and d.forwards or d.wgpeers) or {}) do
            if (descr and x.descr == descr) or (key and x.key == key) then r = x end
        end
        local on = r and (descr and not r.disabled or (key and r.enabled)) or false
        return { label = r and r.name or (descr or _("WireGuard peer")), icon = descr and "network" or "key-round", on = on,
            value = r and (descr and M.natLine(r) or r.tun) or nil,
            tap = function(done)
                if not r then
                    ko.toast(_("Not read yet"))
                    return done and done()
                end
                local name, args
                if descr then name, args = "nat_enabled", { kind = "forward", id = r.id, sig = r.sig, on = r.disabled }
                else name, args = "wg_enabled", { num = r.num, key = r.key, on = not r.enabled } end
                self:act(name, args, function(ok, text)
                    if not ok then ko.toast(text, 4) end
                    if done then done() end
                end)
            end,
            hold = function()
                if r and descr then self:showItem("forward", r.id) else self:show() end
            end }
    end
end

--- The launcher's search (q in lower case): what was last read (each opens its page),
-- and the firewall itself.
function PfSense:search(q)
    local out = {}
    if not q or q == "" then return out end
    local name = self:fwName()
    if name:lower():find(q, 1, true) or ("pfsense"):find(q, 1, true) then
        table.insert(out, { title = name, sub = state.data and state.data.system and M.summary(state.data) or _("pfSense"),
            open = function() self:show() end })
    end
    for __, hit in ipairs(M.search(state.data, q)) do
        local kind = hit.kind
        local id = kind == "static" and hit.item.key or hit.item.id
        table.insert(out, { title = hit.title, sub = hit.sub, open = function() self:showItem(kind, id) end })
    end
    return out
end

-- ------------------------------------------------------------------ the web page

--- What the web page's pfSense tab shows (no API key).
function PfSense:webState()
    local c = self:cfg()
    local d = self:configured() and self:status(15) or nil
    local sort = {}
    for list in pairs(M.SORTABLE) do
        local by, reverse = self:sortOf(list)
        sort[list] = { by = by, reverse = reverse }
    end
    local out = { configured = self:configured(), url = c.url, name = self:fwName(), hasKey = c.key ~= nil, sort = sort,
        interval = self:interval(), notify = self:notifying(), read = state.time > 0 and state.time or nil,
        why = state.why and self:whyText(state.why) or nil }
    if d and d.system then
        local s = d.system
        out.summary, out.skipped = M.summary(d), d.skipped
        out.system = { version = s.version, uptime = M.uptime(s.uptime), cpu = s.cpu, mem = s.mem, disk = s.disk, temp = s.temp }
        out.gateways, out.interfaces, out.services, out.devices, out.rules, out.statics, out.overrides = {}, {}, {}, {}, {}, {}, {}
        for __, g in ipairs(d.gateways or {}) do
            table.insert(out.gateways, { name = g.name, state = g.state, line = M.gatewayLine(g) })
        end
        for __, i in ipairs(d.interfaces or {}) do
            table.insert(out.interfaces, { key = i.key, name = i.name, up = i.up, enabled = i.enabled, line = M.interfaceLine(i) })
        end
        for __, x in ipairs(d.services or {}) do
            table.insert(out.services, { key = x.key, name = x.name, running = x.running, enabled = x.enabled, state = M.serviceState(x) })
        end
        for __, l in ipairs(self:sortedList("leases")) do
            table.insert(out.devices, { name = l.name, ip = l.ip, mac = l.mac, iface = l.iface, online = l.online, line = M.leaseLine(l) })
        end
        for __, r in ipairs(d.rules or {}) do
            table.insert(out.rules, { id = r.id, tracker = r.tracker, name = r.name, on = not r.disabled, line = M.ruleLine(r) })
        end
        for __, x in ipairs(self:sortedList("statics")) do
            table.insert(out.statics, { parent = x.parent, id = x.id, mac = x.mac, ip = x.ip, hostname = x.hostname, descr = x.descr, name = x.name })
        end
        for __, o in ipairs(self:sortedList("overrides")) do
            table.insert(out.overrides, { id = o.id, host = o.host, domain = o.domain, ips = table.concat(o.ips, ", "),
                aliases = table.concat(o.aliases, ", "), descr = o.descr, name = o.fqdn })
        end
        -- aliases, NAT, routing, VPN switches and certificates (names and dates only)
        out.aliases, out.nat, out.routes, out.wgpeers, out.certs, out.gwchoices = {}, {}, {}, {}, {}, {}
        for __, a in ipairs(d.aliases or {}) do
            local entries = {}
            for __, e in ipairs(a.entries) do entries[#entries + 1] = e.address end
            table.insert(out.aliases, { id = a.id, name = a.name, type = a.type, line = M.aliasLine(a), entries = table.concat(entries, ", ") })
        end
        for __, kind in ipairs({ "forward", "outbound", "onetoone" }) do
            for __, r in ipairs(d[M.KINDS[kind]] or {}) do
                table.insert(out.nat, { kind = kind, id = r.id, name = r.name, on = not r.disabled, line = M.natLine(r) })
            end
        end
        out.natmode = d.natmode and M.natMode(d.natmode) or nil
        for __, r in ipairs(d.routes or {}) do
            table.insert(out.routes, { id = r.id, name = r.name, on = not r.disabled, line = M.routeLine(r) })
        end
        local status = {}
        for __, p in ipairs(d.peers or {}) do status[p.id] = p end
        for __, w in ipairs(d.wgpeers or {}) do
            table.insert(out.wgpeers, { key = w.key, name = w.name, on = w.enabled,
                line = status[w.key] and M.peerLine(status[w.key]) or w.tun })
        end
        for __, c in ipairs(d.certs or {}) do
            table.insert(out.certs, { name = c.name, line = M.certLine(c), soon = M.certSoon(c) })
        end
        out.defaultgw = d.defaultgw
        for __, g in ipairs(d.gwconfig or {}) do
            if not g.disabled then table.insert(out.gwchoices, { name = g.name, family = g.family ~= "" and g.family or "inet" }) end
        end
        for __, g in ipairs(d.gwgroups or {}) do
            table.insert(out.gwchoices, { name = g.name, family = g.family ~= "" and g.family or "inet", group = true })
        end
    end
    return out
end

--- The web page's actions: service { name, action }, rule_enabled { id, tracker, on },
-- wake { iface, mac }, static_add { parent, mac, ip, hostname, descr }, static_delete
-- { parent, id, mac }, override_add { host, domain, ips, descr, aliases }, override_delete
-- { id, host, domain }, reboot, update, nat_enabled { kind, id, on }, wg_enabled { key, on }, route_enabled
-- { id, on }, default_gw { family, name }, kill_states { ip }, alias_set { id, name, addresses },
-- sort { list, by, reverse }, refresh (started in the background: the page reads
-- the state again after); settings { url, key, interval, notify }. Returns true, or false and why.
function PfSense:webAct(name, args)
    args = type(args) == "table" and args or {}
    if name == "settings" then
        local t = {}
        if args.url ~= nil and args.url ~= "" then
            local url = M.cleanUrl(args.url)
            if not url then return false, _("Enter the firewall's address, such as https://192.168.1.1.") end
            t.url = url
        end
        if args.key ~= nil and args.key ~= "" then t.key = args.key end
        if next(t) then self:setCfg(t) end
        if tonumber(args.interval) then
            G_reader_settings:saveSetting("pfsense_interval", math.max(15, math.min(300, math.floor(tonumber(args.interval)))))
        end
        if type(args.notify) == "boolean" then G_reader_settings:saveSetting("pfsense_notify", args.notify) end
        if self:configured() and next(t) then self:fetch(nil, true) end
        return true
    end
    if name == "sort" then
        if not M.SORTABLE[args.list] then return false, "Which list?" end
        self:setSort(args.list, args.by, args.reverse == true)
        require("pfsui").refreshAll()
        return true
    end
    if not self:configured() then return false, self:whyText("notset") end
    if not NetworkMgr:isConnected() then return false, self:whyText("offline") end
    if name == "refresh" then
        self:fetch(nil, true)
        return true
    end
    local a
    if name == "service" then
        if not (args.action == "start" or args.action == "stop" or args.action == "restart") or type(args.name) ~= "string" then
            return false, "Which one?"
        end
        a = { name = args.name, action = args.action }
    elseif name == "rule_enabled" then
        a = { id = tonumber(args.id), tracker = M.str(args.tracker), on = args.on == true }
        if not a.id or a.tracker == "" then return false, "Which one?" end
    elseif name == "wake" then
        if not M.isMac(args.mac) or M.str(args.iface) == "" then return false, _("Enter a MAC address, such as aa:bb:cc:dd:ee:ff.") end
        a = { iface = M.str(args.iface), mac = M.mac(args.mac) }
    elseif name == "static_add" then
        if not M.isMac(args.mac) then return false, _("Enter a MAC address, such as aa:bb:cc:dd:ee:ff.") end
        if M.str(args.ip) ~= "" and not M.isIPv4(args.ip) then return false, _("Enter an IP address, such as 192.168.1.20.") end
        a = { parent = M.str(args.parent), mac = M.mac(args.mac), ip = M.str(args.ip), hostname = M.str(args.hostname), descr = M.str(args.descr) }
        if a.parent == "" then return false, "Which interface?" end
    elseif name == "static_delete" then
        a = { parent = M.str(args.parent), id = tonumber(args.id), mac = M.mac(args.mac) }
        if not a.id or a.parent == "" then return false, "Which one?" end
    elseif name == "override_add" then
        a = { host = M.str(args.host), domain = M.str(args.domain), ips = M.strings(args.ips), descr = M.str(args.descr),
            aliases = M.strings(args.aliases) }
        if a.domain == "" or #a.ips == 0 then return false, _("Enter the domain and an IP address.") end
    elseif name == "override_delete" then
        a = { id = tonumber(args.id), host = M.str(args.host), domain = M.str(args.domain) }
        if not a.id then return false, "Which one?" end
    elseif name == "reboot" or name == "update" then
        a = {}
    elseif name == "nat_enabled" then
        local kind = M.str(args.kind)
        local d = state.data
        local r = d and M.find(d, kind, tonumber(args.id))
        if not r then return false, "Which one?" end
        a = { kind = kind, id = r.id, sig = r.sig, on = args.on == true }
    elseif name == "wg_enabled" then
        local d = state.data
        local r = d and M.find(d, "wgpeer", M.str(args.key))
        if not r then return false, "Which one?" end
        a = { num = r.num, key = r.key, on = args.on == true }
    elseif name == "route_enabled" then
        local d = state.data
        local r = d and M.find(d, "route", tonumber(args.id))
        if not r then return false, "Which one?" end
        a = { id = r.id, network = r.network, gateway = r.gateway, on = args.on == true }
    elseif name == "default_gw" then
        a = { family = args.family == "inet6" and "inet6" or "inet", name = M.str(args.name) }
    elseif name == "kill_states" then
        if not M.isIPv4(args.ip) then return false, _("Enter an IP address, such as 192.168.1.20.") end
        a = { ip = M.str(args.ip) }
    elseif name == "alias_set" then
        local d = state.data
        local x = d and M.find(d, "alias", tonumber(args.id))
        if not x or x.name ~= M.str(args.name) then return false, "Which one?" end
        a = { id = x.id, name = x.name, addresses = M.strings(args.addresses), details = {} }
        local old = {}
        for __, e in ipairs(x.entries) do old[e.address] = e.detail end
        for k, addr in ipairs(a.addresses) do a.details[k] = old[addr] or "" end
    else
        return false, "Unknown action"
    end
    self:act(name, a)
    return true
end

return PfSense
