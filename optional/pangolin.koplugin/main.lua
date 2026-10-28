--[[--
Pangolin: your Pangolin server's organization on the Kindle, over its
Integration API (an API key, as the Home Assistant integration uses it).
Sites and whether they're online, public resources and their health (each
target's), private resources and clients; resources turned on or off, a
resource's sign-in and block access, clients blocked or archived, and the
sites' data counters reset.

Nothing runs in the background: Pangolin is read while the app is open, and
when the launcher's tile or a quick button shows it.

Also: the launcher's tile line (appsLine, event ShowPangolin), its settings,
search, setup step, quick buttons, connection test and backup, gestures,
notifications (a site or resource gone offline), and calls for the web page
(webState, webAct).

@module koplugin.pangolin
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

local M = require("pgmodel")

-- Kept while KOReader runs (each book and the library get a new plugin).
local state = {
    data = nil,        -- the organization as last read (pgmodel.data)
    time = 0,          -- when
    tried = 0,         -- when it was last asked (answered or not)
    why = nil,         -- why the last read failed (nil: it worked)
    reading = false,
    waiting = {},
    line = nil,        -- the launcher's line as last shown
    details = {},      -- resource id -> its settings ({ blockAccess }), or false when the key can't read them
}

local Pangolin = WidgetContainer:extend{
    name = "pangolin",
    is_doc_only = false,
}

-- The Pangolin plugin of the open library or book.
local function current()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    return ui and ui.pangolin
end
Pangolin.current = current

function Pangolin:init()
    self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/pangolin.lua")
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    require("pgko").flashOnUncover()
    require("pgui").plugin = self
    self:shareWithApps()
end

function Pangolin:onDispatcherRegisterActions()
    Dispatcher:registerAction("pangolin_show", { category = "none", event = "ShowPangolin", title = _("Pangolin"), general = true })
end

function Pangolin:addToMainMenu(menu_items)
    menu_items.pangolin = {
        text = _("Pangolin"),
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

function Pangolin:onShowPangolin()
    self:show()
    return true
end

function Pangolin:show(page)
    return require("pgui").show(self, page)
end

-- ------------------------------------------------------------------ the connection's settings

--- { url, key, org, orgName } (fields nil until set).
function Pangolin:cfg()
    return { url = self.store:readSetting("url"), key = self.store:readSetting("key"),
        org = self.store:readSetting("org"), orgName = self.store:readSetting("org_name") }
end

function Pangolin:configured()
    local c = self:cfg()
    return c.url ~= nil and c.key ~= nil and c.org ~= nil
end

--- Change some of the settings ({ url = …, … }; false clears one); what was read is forgotten.
function Pangolin:setCfg(t)
    for k, v in pairs(t) do
        local name = k == "orgName" and "org_name" or k
        if v == false or v == "" then self.store:delSetting(name) else self.store:saveSetting(name, v) end
    end
    self.store:flush()
    state.data, state.why, state.time, state.tried, state.details = nil, nil, 0, 0, {}
    self:changed()
end

--- The organization's name as shown: the one read, else the one saved, else "Pangolin".
function Pangolin:orgName()
    local d = state.data
    local c = self:cfg()
    return (d and d.orgName ~= "" and d.orgName) or c.orgName or c.org or _("Pangolin")
end

--- How often the open app reads Pangolin (seconds, 10 to 300).
function Pangolin:interval()
    return math.max(10, math.min(300, tonumber(G_reader_settings:readSetting("pangolin_interval")) or 30))
end

--- Whether a site or resource going offline is a notification.
function Pangolin:notifying()
    return G_reader_settings:nilOrTrue("pangolin_notify")
end

-- ------------------------------------------------------------------ reading Pangolin

function Pangolin:api(cfg)
    return require("pgapi").new(cfg or self:cfg())
end

--- Why something failed, in plain words. perm: the permission the key needed, for a 403.
function Pangolin:whyText(why, perm)
    local s = tostring(why or "")
    local needs = s:match("^forbidden:(.+)$")
    if needs then return T(_("The API key needs the %1 permission."), needs) end
    if s == "forbidden" then
        return perm and T(_("The API key needs the %1 permission."), perm) or _("The API key isn't allowed to do that.")
    end
    if s == "signin" then return _("Pangolin refused the API key. Check it in Settings.") end
    if s == "notfound" then return _("Pangolin doesn't know that address or organization. Check the API URL and organization ID.") end
    if s == "notapi" then return _("That address doesn't answer as Pangolin's Integration API. Enter its address, such as https://api.example.com.") end
    if s == "offline" then return _("Not on Wi-Fi.") end
    if s == "notset" then return _("Pangolin isn't set up yet.") end
    if s:find("timeout") or s:find("timed out") then return _("Pangolin didn't answer in time.") end
    if s:find("refused") then return _("The connection was refused. Is the Integration API turned on?") end
    if s:find("host not found") or s:find("unreachable") or s:find("No route") or s:find("resolve") then
        return _("The API URL can't be reached from this Wi-Fi.")
    end
    if s:find("certificate") or s:find("handshake") or s:find("ssl") then return _("The secure connection failed (its certificate).") end
    if s == "" or s == "nil" or s == "no answer" or s == "nothing" then return _("Pangolin didn't answer.") end
    return s
end

--- Read Pangolin in the background; done(data) when it is in (nil and why when it
-- didn't answer). One read at a time.
function Pangolin:fetch(done)
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
    state.reading, state.tried = true, os.time()
    local api = self:api()
    require("pgbg").run(function()
        local r, why = api:readAll()
        if not r then return { why = why } end
        return { raw = r }
    end, function(r, why)
        state.reading = false
        if r and r.raw then
            local before = state.data
            state.data, state.time, state.why = M.data(r.raw), os.time(), nil
            -- (the organization's own name, for when Pangolin isn't answering)
            if state.data.orgName ~= "" and state.data.orgName ~= self.store:readSetting("org_name") then
                self.store:saveSetting("org_name", state.data.orgName)
                self.store:flush()
            end
            self:notifyChanges(before, state.data)
            self:changed()
            return finish(state.data)
        end
        state.why = (r and r.why) or why or "no answer"
        logger.info("Pangolin: no answer:", state.why)
        self:changed()
        finish(nil, state.why)
    end, { limit = 30 })
end

--- The organization as last read (nil until read); read again in the background when
-- older than maxAge seconds (and on Wi-Fi).
function Pangolin:status(maxAge)
    -- (a server that doesn't answer is asked again no sooner than one that does)
    local last = math.max(state.time, state.tried)
    if self:configured() and os.time() - last >= (maxAge or 60) and not state.reading and NetworkMgr:isConnected() then
        self:fetch()
    end
    return state.data
end

function Pangolin:data() return state.data end
function Pangolin:readTime() return state.time end
function Pangolin:lastWhy() return state.why end
function Pangolin:reading() return state.reading end

--- A site or resource gone offline to the shared notifications; it goes when it's back.
function Pangolin:notifyChanges(before, after)
    local PS = require("pluginshare")
    if not PS.notify then return end
    local ch = M.changes(before, after)
    for __, key in ipairs(ch.remove) do
        if PS.unnotify then pcall(PS.unnotify, key) end
    end
    if not self:notifying() then return end
    for __, n in ipairs(ch.add) do
        local kind, id = n.kind, n.id
        pcall(PS.notify, { app = "pangolin", name = _("Pangolin"), icon = "shield-check", key = n.key, text = n.text,
            route = { kind = kind, id = id },
            open = function() local p = current() if p then p:showItem(kind, id) end end })
    end
end

--- Open Pangolin at a site's or resource's page (from a notification or search).
function Pangolin:showItem(kind, id)
    self:show()
    require("pgui").item(self, kind, id)
end

--- Redraw what shows Pangolin: the app's pages, or the launcher when its line changed.
function Pangolin:changed()
    local UI = require("pgui")
    if #UI.pages > 0 then UI.refreshAll() end
    local line = self:appsLine()
    if line == state.line then return end
    state.line = line
    local apps = self.ui and self.ui.apps
    if apps and apps.changed then pcall(apps.changed, apps) end
end

--- The launcher tile's line: "All online · 4 sites", "1 site offline".
function Pangolin:appsLine()
    if not self:configured() then return M.appsLine(nil, false) end
    local d = self:status(120)
    if not d and state.why == "offline" then return _("Not on Wi-Fi") end
    if not d and state.why then return _("Pangolin not answering") end
    return M.appsLine(d, true)
end

-- ------------------------------------------------------------------ actions

-- What each action does, in the child; the permission a 403 means it lacks; and the
-- change it makes, put in what was read at once (the next read confirms it).
local ACTIONS = {
    resource_enabled = { run = function(api, a) return api:updateResource(a.id, { enabled = a.on }) end,
        perm = function() return _("Update Resource") end,
        apply = function(d, a) local r = M.find(d, "resource", a.id) if r then r.enabled = a.on end end },
    resource_sso = { run = function(api, a) return api:updateResource(a.id, { sso = a.on }) end,
        perm = function() return _("Update Resource") end,
        apply = function(d, a) local r = M.find(d, "resource", a.id) if r then r.sso = a.on end end },
    resource_block = { run = function(api, a) return api:updateResource(a.id, { blockAccess = a.on }) end,
        perm = function() return _("Update Resource") end,
        apply = function(__, a) if state.details[a.id] then state.details[a.id].blockAccess = a.on end end },
    private_enabled = { run = function(api, a) return api:setPrivate(a.id, a.on) end,
        perm = function() return _("Update Site Resource") end,
        apply = function(d, a) local r = M.find(d, "private", a.id) if r then r.enabled = a.on end end },
    client_blocked = { run = function(api, a) return api:client(a.id, a.on and "block" or "unblock") end,
        perm = function(a) return a.on and _("Block Client") or _("Unblock Client") end,
        apply = function(d, a) local c = M.find(d, "client", a.id) if c then c.blocked = a.on end end },
    client_archived = { run = function(api, a) return api:client(a.id, a.on and "archive" or "unarchive") end,
        perm = function(a) return a.on and _("Archive Client") or _("Unarchive Client") end,
        apply = function(d, a) local c = M.find(d, "client", a.id) if c then c.archived = a.on end end },
    reset_bandwidth = { run = function(api) return api:resetBandwidth() end,
        perm = function() return _("Reset Organization Bandwidth") end,
        apply = function(d)
            for __, s in ipairs(d.sites) do s.mbIn, s.mbOut = 0, 0 end
        end },
}
Pangolin.ACTIONS = ACTIONS

--- Do an action in the background; then done(ok, text) (text: why it failed, in plain
-- words) and Pangolin read again. args: { id, on } (reset_bandwidth: none).
-- opts.text: a waiting message meanwhile.
function Pangolin:act(name, args, done, opts)
    local a = ACTIONS[name]
    if not a then return done and done(false, "Unknown action") end
    if not self:configured() then return done and done(false, self:whyText("notset")) end
    if not NetworkMgr:isConnected() then return done and done(false, self:whyText("offline")) end
    local api = self:api()
    args = args or {}
    if state.data then
        a.apply(state.data, args)
        self:changed()
    end
    require("pgbg").run(function()
        local ok, why = a.run(api, args)
        if not ok then return { why = why or "refused" } end
        return { ok = true }
    end, function(r, why)
        local good = r and r.ok
        local text
        if not good then
            why = (r and r.why) or why
            logger.warn("Pangolin:", name, why)
            text = self:whyText(why, a.perm(args))
        end
        -- (read again: confirms the change, or puts back what it couldn't do)
        UIManager:scheduleIn(good and 1 or 0, function() self:fetch() end)
        if done then done(good and true or false, text) end
    end, { limit = 25, text = opts and opts.text })
end

--- A public resource's settings beyond the list (block access): done(detail) or
-- done(nil, text). Read once per run, and again after a change made here.
function Pangolin:resourceDetail(id, done, again)
    local d = state.details[id]
    if d ~= nil and not again then return done(d or nil, d == false and self:whyText("forbidden", _("Get Resource")) or nil) end
    if not self:configured() or not NetworkMgr:isConnected() then return done(nil, self:whyText("offline")) end
    local api = self:api()
    require("pgbg").run(function()
        local r, why = api:resource(id)
        if not r then return { why = why } end
        return { detail = { blockAccess = r.blockAccess == true } }
    end, function(r, why)
        if r and r.detail then
            state.details[id] = r.detail
            return done(r.detail)
        end
        why = (r and r.why) or why
        if why == "forbidden" or why == "notfound" then state.details[id] = false end
        done(nil, self:whyText(why, _("Get Resource")))
    end, { limit = 20 })
end

function Pangolin:detail(id) return state.details[id] end

--- The organizations a root key sees: done(list) (each { id, name }); done(nil, why)
-- for an organization key (why "forbidden") or when it failed. cfg: { url, key }.
function Pangolin:orgs(cfg, done)
    if not NetworkMgr:isConnected() then return done(nil, "offline") end
    local api = self:api(cfg)
    require("pgbg").run(function()
        local ok, why = api:ping()
        if not ok then return { why = why } end
        local list
        list, why = api:orgs()
        if not list then return { why = why } end
        local out = {}
        for __, o in ipairs(list) do
            table.insert(out, { id = M.str(o.orgId), name = M.str(o.name) ~= "" and M.str(o.name) or M.str(o.orgId) })
        end
        return { list = out }
    end, function(r, why)
        if r and r.list then return done(r.list) end
        done(nil, (r and r.why) or why)
    end, { limit = 25, text = _("Connecting to Pangolin…") })
end

--- Whether the key reads this organization: done(name) or done(nil, why). cfg: { url, key, org }.
function Pangolin:checkOrg(cfg, done)
    if not NetworkMgr:isConnected() then return done(nil, "offline") end
    local api = self:api(cfg)
    require("pgbg").run(function()
        local o, why = api:organization()
        if not o then return { why = why } end
        return { name = M.str(o.name) }
    end, function(r, why)
        if r and r.name then return done(r.name ~= "" and r.name or cfg.org) end
        done(nil, (r and r.why) or why)
    end, { limit = 25, text = _("Checking the organization…") })
end

-- ------------------------------------------------------------------ the launcher

function Pangolin:shareWithApps()
    local PS = require("pluginshare")
    PS.notifyOpeners = PS.notifyOpeners or {}
    -- What it is for the launcher and the web page: its tile (only there while it's installed:
    -- an optional app), Settings group (Optional apps; its tile in the suggested Tools group), web tab
    -- (apps.koplugin/appsinfo.lua).
    PS.appInfo = PS.appInfo or {}
    PS.appInfo.pangolin = { name = _("Pangolin"), icon = "shield-check", dir = self.path, order = 85, group = "optional",
        -- "All online · 4 sites", "1 site offline".
        tiles = { { key = "pangolin", group = "tools", event = "ShowPangolin", line = function(p) return p:appsLine() end } },
        web = { page = "pangolin", routes = "webpangolin", script = "web/pangolin.js",
            card = "Your Pangolin server: sites, resources and clients, and turning them on or off." } }
    PS.notifyOpeners.pangolin = function(route)
        local p = current()
        if not p then return end
        if type(route) == "table" and route.kind then p:showItem(route.kind, route.id) else p:show() end
    end
    -- The web page's backup: the connection and the settings; the API key only with
    -- Include keys and sign-ins.
    PS.backupApps = PS.backupApps or {}
    PS.backupApps.pangolin = { key = "pangolin", name = _("Pangolin"),
        files = { "^pangolin%.lua$" },
        reader_keys = { "^pangolin_" },
        secret_keys = { ["pangolin.lua"] = { "key" } } }
    if PS.registerSettings then
        PS.registerSettings{ key = "pangolin", name = _("Pangolin"), icon = "shield-check",
            open = function() local p = current() if p then p:show("settings") end end,
            rows = function()
                local p = current()
                return p and require("pgui").searchRows(p) or {}
            end }
    end
    if PS.registerSearch then
        PS.registerSearch{ key = "pangolin", name = _("Pangolin"), icon = "shield-check", search = function(q)
            local p = current()
            return p and p:search(q) or {}
        end }
    end
    if PS.registerSetup then
        PS.registerSetup{ key = "pangolin", order = 58, icon = "shield-check", title = _("Pangolin"),
            text = _("Your Pangolin server on the Kindle: which sites are online, each resource's health, and turning resources and clients on or off."),
            done = function() local p = current() return p ~= nil and p:configured() end,
            doneText = _("Pangolin set up"), action = _("Set up"),
            skipped = _("Nothing else needs it. Set it up any time from the Pangolin app."),
            help = { button = _("What you need"), title = _("Connecting to Pangolin"),
                steps = {
                    _("Pangolin's Integration API turned on and reachable (its address shows Swagger at /v1/docs)."),
                    _("An organization API key from Pangolin's dashboard, with List Sites and Get Organization at least, and the List and Update permissions for what you want to see and change."),
                    _("The organization ID: it's in the dashboard's address."),
                },
                after = _("The key stays on the Kindle and is only sent to your Pangolin server."),
                guide = "pangolin.md" },
            run = function() local p = current() if p then require("pgui").setup(p) end end }
    end
    if PS.registerTest then
        PS.registerTest{ key = "pangolin", name = _("Pangolin"),
            configured = function() local p = current() return p ~= nil and p:configured() end,
            run = function(Test)
                local p = current()
                local c = p and p:cfg() or {}
                local api = require("pgapi").new(c)
                local socket = require("socket")
                local rows = {}
                local started = socket.gettime()
                local ok, why = api:ping()
                local row = { name = _("Integration API"), detail = M.apiBase(c.url),
                    ms = math.floor((socket.gettime() - started) * 1000) }
                row.ok = ok
                if not ok then row.raw, row.why = tostring(why), (p and p:whyText(why)) or Test.why(why) end
                table.insert(rows, row)
                if ok then
                    started = socket.gettime()
                    local o
                    o, why = api:organization()
                    row = { name = _("API key and organization"), detail = c.org or "?",
                        ms = math.floor((socket.gettime() - started) * 1000) }
                    row.ok = o ~= nil
                    if o then
                        row.why = M.str(o.name)
                    else
                        row.raw = tostring(why)
                        row.why = why == "forbidden" and _("The key can't read this organization (Get Organization)")
                            or (p and p:whyText(why)) or Test.why(why)
                    end
                    table.insert(rows, row)
                end
                return rows
            end }
    end
    if PS.registerQuick then
        PS.registerQuick{ key = "pangolin", name = _("Pangolin"),
            choices = function()
                local out = { { id = "status", name = _("Pangolin status"), icon = "shield-check", group = _("Pangolin") } }
                local d = state.data
                for __, r in ipairs(d and d.resources or {}) do
                    table.insert(out, { id = "resource:" .. r.id, name = r.name, icon = "globe", group = _("Public resources") })
                end
                for __, r in ipairs(d and d.private or {}) do
                    table.insert(out, { id = "private:" .. r.id, name = r.name, icon = "lock", group = _("Private resources") })
                end
                return out
            end,
            item = function(id)
                local p = current()
                return p and p:quickItem(id)
            end }
    end
end

--- A quick button: the status (tap reads it again), or a resource on or off.
function Pangolin:quickItem(id)
    if not self:configured() then return nil end
    local d = self:status(120)
    local ko = require("pgko")
    if id == "status" then
        return { label = self:orgName(), icon = "shield-check", value = d and M.summary(d) or nil,
            tap = function(done) self:fetch(function() if done then done() end end) end,
            hold = function() self:show() end }
    end
    local kind, n = id:match("^(%a+):(%d+)$")
    n = tonumber(n)
    if (kind == "resource" or kind == "private") and n then
        local r = d and M.find(d, kind, n)
        return { label = r and r.name or _("Resource"), icon = kind == "resource" and "globe" or "lock",
            on = r and r.enabled or false,
            value = r and (kind == "resource" and M.resourceLine(r) or M.privateLine(r)) or nil,
            tap = function(done)
                if not r then
                    ko.toast(_("Not read yet"))
                    return done and done()
                end
                self:act(kind == "resource" and "resource_enabled" or "private_enabled", { id = n, on = not r.enabled },
                    function(ok, text)
                        if not ok then ko.toast(text, 4) end
                        if done then done() end
                    end)
            end,
            hold = function() self:showItem(kind, n) end }
    end
end

--- The launcher's search (q in lower case): sites, resources and clients as last read
-- (each opens its page), and the organization itself.
function Pangolin:search(q)
    local out = {}
    if not q or q == "" then return out end
    local name = self:orgName()
    if name:lower():find(q, 1, true) or ("pangolin"):find(q, 1, true) then
        table.insert(out, { title = name, sub = state.data and M.summary(state.data) or _("Pangolin"),
            open = function() self:show() end })
    end
    for __, hit in ipairs(M.search(state.data, q)) do
        local kind, id = hit.kind, hit.item.id
        table.insert(out, { title = hit.title, sub = hit.sub, open = function() self:showItem(kind, id) end })
    end
    return out
end

-- ------------------------------------------------------------------ the web page

--- What the web page's Pangolin tab shows (no API key).
function Pangolin:webState()
    local c = self:cfg()
    local d = self:configured() and self:status(10) or nil
    local out = { configured = self:configured(), url = c.url, org = c.org, name = self:orgName(),
        hasKey = c.key ~= nil, keyId = c.key and M.keyId(c.key) or nil, interval = self:interval(),
        notify = self:notifying(), read = state.time > 0 and state.time or nil,
        why = state.why and self:whyText(state.why) or nil }
    if d then
        out.summary, out.counts, out.skipped = M.summary(d), M.counts(d), d.skipped
        out.sites, out.resources, out.private, out.clients = {}, {}, {}, {}
        for __, s in ipairs(d.sites) do
            table.insert(out.sites, { id = s.id, name = s.name, online = s.online, line = M.siteLine(s),
                dataIn = M.size(s.mbIn), dataOut = M.size(s.mbOut) })
        end
        for __, r in ipairs(d.resources) do
            table.insert(out.resources, { id = r.id, name = r.name, domain = r.domain, enabled = r.enabled,
                health = r.health, healthText = M.healthText(r.health), sso = r.sso, protection = M.protection(r) })
        end
        for __, r in ipairs(d.private) do
            table.insert(out.private, { id = r.id, name = r.name, enabled = r.enabled, line = M.privateLine(r) })
        end
        for __, x in ipairs(d.clients) do
            table.insert(out.clients, { id = x.id, name = x.name, online = x.online, blocked = x.blocked,
                archived = x.archived, line = M.clientLine(x) })
        end
    end
    return out
end

--- The web page's actions: resource_enabled, resource_sso, private_enabled,
-- client_blocked, client_archived ({ id, on }), reset_bandwidth, refresh (started in
-- the background: the page reads the state again after); settings { url, key, org,
-- interval, notify }. Returns true, or false and why.
function Pangolin:webAct(name, args)
    args = type(args) == "table" and args or {}
    if name == "settings" then
        local t = {}
        if args.url ~= nil and args.url ~= "" then
            local url = M.cleanUrl(args.url)
            if not url then return false, _("Enter the API URL, such as https://api.example.com.") end
            t.url = url
        end
        if args.key ~= nil and args.key ~= "" then t.key = args.key end
        if args.org ~= nil and args.org ~= "" and args.org ~= self:cfg().org then t.org, t.orgName = args.org, false end
        if next(t) then self:setCfg(t) end
        if tonumber(args.interval) then
            G_reader_settings:saveSetting("pangolin_interval", math.max(10, math.min(300, math.floor(tonumber(args.interval)))))
        end
        if type(args.notify) == "boolean" then G_reader_settings:saveSetting("pangolin_notify", args.notify) end
        if self:configured() and next(t) then self:fetch() end
        return true
    end
    if not self:configured() then return false, self:whyText("notset") end
    if not NetworkMgr:isConnected() then return false, self:whyText("offline") end
    if name == "refresh" then
        self:fetch()
        return true
    end
    if not ACTIONS[name] then return false, "Unknown action" end
    local a = {}
    if name ~= "reset_bandwidth" then
        a.id, a.on = tonumber(args.id), args.on == true
        if not a.id then return false, "Which one?" end
    end
    self:act(name, a)
    return true
end

return Pangolin
