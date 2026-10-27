--[[--
Pangolin's screens, drawn as the other apps' pages (pgpage):
  Pangolin            the organization at a glance (sites online, resources
                      healthy, clients online), what needs attention, and
                      Sites, Public resources, Private resources and Clients
  Sites               each site online or not; a site: its type, address,
                      versions, data in and out, and what runs through it
  Public resources    each one's health; a resource: Enabled, Sign-in, Block
                      access, its protection, each target's health, its sites
  Private resources   each one; a private resource: Enabled, where it points
  Clients             machines and user devices; a client: Blocked, Archived
  Settings            how often it's read, notifications, the API URL, API key
                      and organization
While a Pangolin page is on top, Pangolin is read every so often (Settings >
Read every); nothing is read once it closes.
]]

local Event = require("ui/event")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local KO = require("pgko")
local M = require("pgmodel")

local UI = {}

-- The pages open now, oldest first (Home closes them all).
UI.pages = {}

local function Page() return require("pgpage") end
local function PS() return require("pluginshare") end
local function twentyFour() return not G_reader_settings:isTrue("twelve_hour_clock") end

--- The Apps launcher (when it's installed).
function UI.launcher()
    if KO.home() then return end
    local plugin = UI.plugin
    if plugin and plugin.ui and plugin.ui.apps then plugin.ui:handleEvent(Event:new("ShowApps")) end
end

--- Home: every Pangolin page closes, then the launcher.
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

--- ⋮ on every page: Reset bandwidth, Details, Help; then Recent apps, Light,
-- Night mode, Refresh screen and Settings last.
function UI.more()
    local plugin = UI.plugin
    if not plugin then return end
    local extra = {}
    if plugin:configured() then
        table.insert(extra, { _("Reset bandwidth"), function() UI.resetBandwidth(plugin) end })
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
        add(it.toggle) add(it.dot)
        if it.job then add(it.job.state) add(table.concat(it.job.lines or {}, "|")) end
        for __, k in ipairs({ "tiles", "stats", "quick" }) do
            for __, x in ipairs(it[k] or {}) do add(x.text) add(x.sub) add(x.value) add(x.label) end
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
-- opts.live: Pangolin is read every so often while it's on top.
local function page(title, items, opts)
    opts = opts or {}
    local fn = type(items) == "function" and items or nil
    local p = Page():new{ title = title, subtitle = opts.subtitle, item_table = fn and fn() or items, items_fn = fn,
        top = opts.top, status = opts.status, on_refresh = opts.on_refresh, bar_buttons = opts.buttons }
    p.sig = signature(p.item_table)
    p.live = opts.live
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

--- An action, with a toast when it didn't work (Pangolin is read again either way).
local function act(plugin, name, args, okText)
    plugin:act(name, args, function(ok, text)
        if ok then
            if okText then KO.toast(okText) end
        else
            KO.toast(text, 4)
        end
    end)
end

-- ------------------------------------------------------------------ reading while open

--- Every so often while one of Pangolin's live pages is on top: Pangolin again.
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
                plugin:fetch()
                break
            end
        end
        UIManager:scheduleIn(plugin:interval(), tick)
    end
    UIManager:scheduleIn(plugin:interval(), tick)
end

--- The line at the foot: when it was read; the organization.
local function status(plugin)
    local when = plugin:readTime()
    local left
    if plugin:reading() and when == 0 then left = _("Reading…")
    elseif when > 0 then left = T(_("Updated %1"), M.clock(when, twentyFour())) end
    if plugin:lastWhy() and when > 0 then left = T(_("Not answering · last read %1"), M.clock(when, twentyFour())) end
    return left, plugin:cfg().org
end

--- What a page shows before anything is read, or when the read failed: a message
-- (and Try again), or nil once there is something to show.
local function notRead(plugin)
    if plugin:data() then return nil end
    local why = plugin:lastWhy()
    local t = { { message = why and plugin:whyText(why) or _("Reading Pangolin…") } }
    if why then
        t[#t + 1] = { tiles = {
            { icon = "refresh-cw", text = _("Try again"), primary = true, fn = function() plugin:fetch() end },
            { icon = "sliders-horizontal", text = _("Settings"), fn = function() UI.settings(plugin) end },
        }, cols = 2 }
    end
    return t
end

-- ------------------------------------------------------------------ the main page

local function dotOf(on) return on and "on" or "off" end

function UI.mainItems(plugin)
    local t = {}
    if not plugin:configured() then
        t[#t + 1] = { message = _("Pangolin isn't set up yet.") }
        t[#t + 1] = { note = _("You need Pangolin's Integration API turned on, its address, an organization API key and the organization's ID.") }
        t[#t + 1] = { gap = 10 }
        t[#t + 1] = { tiles = {
            { icon = "key-round", text = _("Set up"), sub = _("API URL and key"), primary = true, fn = function() UI.setup(plugin) end },
            { icon = "info", text = _("Help"), sub = _("What you need"), fn = function() UI.help() end },
        }, cols = 2 }
        return t
    end
    local early = notRead(plugin)
    if early then return early end
    local d = plugin:data()
    local c = M.counts(d)
    local lines = { T(_("%1 of %2 sites online"), c.sitesOnline, c.sites) }
    if not d.skipped.resources then
        lines[#lines + 1] = T(_("%1 of %2 public resources healthy"),
            c.resources - c.resourcesDown - c.resourcesDegraded, c.resources)
    end
    if not d.skipped.machines then lines[#lines + 1] = T(_("%1 of %2 clients online"), c.clientsOnline, c.clients) end
    t[#t + 1] = { job = { state = M.summary(d), lines = lines } }

    local attention = M.attention(d)
    if #attention > 0 then
        t[#t + 1] = { band = _("NEEDS ATTENTION"), right = tostring(#attention) }
        for __, a in ipairs(attention) do
            local x = a.item
            t[#t + 1] = { text = x.name, sub = a.kind == "site" and (a.why .. " · " .. M.siteLine(x)) or (a.why .. " · " .. x.domain),
                icon = a.kind == "site" and "server" or "globe", dot = "off", chevron = true,
                callback = function() UI.item(plugin, a.kind, x.id) end }
        end
    end

    t[#t + 1] = { band = _("BROWSE") }
    local tiles = {
        { icon = "server", text = _("Sites"), sub = T(_("%1 of %2 online"), c.sitesOnline, c.sites), fn = function() UI.sites(plugin) end },
        { icon = "globe", text = _("Public resources"),
            sub = d.skipped.resources and _("Not allowed") or (c.resourcesDown > 0 and T(_("%1 · %2 down"), c.resources, c.resourcesDown) or tostring(c.resources)),
            fn = function() UI.resources(plugin) end },
        { icon = "lock", text = _("Private resources"), sub = d.skipped.private and _("Not allowed") or tostring(c.private),
            fn = function() UI.privates(plugin) end },
        { icon = "laptop", text = _("Clients"),
            sub = d.skipped.machines and _("Not allowed") or T(_("%1 online"), c.clientsOnline), fn = function() UI.clients(plugin) end },
    }
    t[#t + 1] = { tiles = tiles, cols = 2 }
    return t
end

--- Pangolin's first page; page "settings": its settings over it.
function UI.show(plugin, which)
    UI.plugin = plugin
    if PS().noteRecent then pcall(PS().noteRecent, "pangolin") end
    -- (already open: back to its first page)
    if UI.pages[1] and UI.pages[1].isMain then
        for k = #UI.pages, 2, -1 do UI.pages[k]:onClose() end
    else
        local p = page(plugin:orgName(), function() return UI.mainItems(plugin) end,
            { top = true, live = true, status = function() return status(plugin) end,
              on_refresh = function() plugin:fetch() end })
        p.isMain = true
        p.items_fn = function()
            p.title = plugin:orgName()
            return UI.mainItems(plugin)
        end
    end
    plugin:fetch()
    UI.poll(plugin)
    if which == "settings" then UI.settings(plugin) end
end

--- A list page that follows each read (live), with ⟳ reading again.
local function listPage(plugin, title, items)
    return page(title, items, { live = true, status = function() return status(plugin) end,
        on_refresh = function() plugin:fetch() end })
end

--- One thing's page (from a notification, search or a list), by kind and id.
function UI.item(plugin, kind, id)
    if kind == "site" then return UI.site(plugin, id) end
    if kind == "resource" then return UI.resource(plugin, id) end
    if kind == "private" then return UI.private(plugin, id) end
    if kind == "client" then return UI.client(plugin, id) end
end

--- A settings-style row with a value (left out when there's no value).
local function row(t, name, value)
    if value ~= nil and value ~= "" then t[#t + 1] = { setting = true, text = name, value = value } end
end

--- What a thing's page shows when it isn't (or no longer) in what was read.
local function gone(plugin, t)
    local early = notRead(plugin)
    if early then return early end
    t[#t + 1] = { message = _("It isn't in Pangolin any more.") }
    return t
end

-- ------------------------------------------------------------------ sites

function UI.sites(plugin)
    listPage(plugin, _("Sites"), function()
        local early = notRead(plugin)
        if early then return early end
        local d = plugin:data()
        local t = { { band = _("SITES"), right = tostring(#d.sites) } }
        if #d.sites == 0 then t[#t + 1] = { message = _("No sites yet.") } end
        for __, s in ipairs(d.sites) do
            t[#t + 1] = { text = s.name, sub = M.siteLine(s), icon = "server", dot = dotOf(s.online), chevron = true,
                right = s.online and _("Online") or _("Offline"), callback = function() UI.site(plugin, s.id) end }
        end
        return t
    end)
end

function UI.site(plugin, id)
    local d0 = plugin:data()
    local s0 = d0 and M.find(d0, "site", id)
    listPage(plugin, s0 and s0.name or _("Site"), function()
        local d = plugin:data()
        local s = d and M.find(d, "site", id)
        local t = {}
        if not s then return gone(plugin, t) end
        t[#t + 1] = { band = _("SITE") }
        row(t, _("Status"), s.online and _("Online") or _("Offline"))
        if s.status == "pending" then row(t, _("Approval"), _("Waiting for approval")) end
        row(t, _("Type"), M.siteType(s))
        row(t, _("Address"), s.address)
        row(t, _("Newt version"), s.newt)
        row(t, _("Exit node"), s.exitNode)
        row(t, _("Identifier"), s.niceId)
        t[#t + 1] = { band = _("DATA") }
        row(t, _("Data in"), M.size(s.mbIn))
        row(t, _("Data out"), M.size(s.mbOut))
        -- What runs through it: public resources by their sites' names, private ones by theirs.
        local through = {}
        for __, r in ipairs(d.resources) do
            for __, x in ipairs(r.sites) do
                if x.name == s.name then
                    through[#through + 1] = { text = r.name, sub = M.resourceLine(r), icon = "globe", chevron = true,
                        callback = function() UI.resource(plugin, r.id) end }
                    break
                end
            end
        end
        for __, r in ipairs(d.private) do
            for __, x in ipairs(r.sites) do
                if x.name == s.name then
                    through[#through + 1] = { text = r.name, sub = M.privateLine(r), icon = "lock", chevron = true,
                        callback = function() UI.private(plugin, r.id) end }
                    break
                end
            end
        end
        if #through > 0 then
            t[#t + 1] = { band = _("RESOURCES"), right = tostring(#through) }
            for __, x in ipairs(through) do t[#t + 1] = x end
        end
        return t
    end)
end

-- ------------------------------------------------------------------ public resources

--- A list the key can't read: why, and which permission it needs.
local function notAllowed(t, perm)
    t[#t + 1] = { message = _("The API key can't list these.") }
    t[#t + 1] = { note = T(_("Give it the %1 permission in Pangolin's dashboard, then tap ⟳."), perm) }
    return t
end

function UI.resources(plugin)
    listPage(plugin, _("Public resources"), function()
        local early = notRead(plugin)
        if early then return early end
        local d = plugin:data()
        local t = {}
        if d.skipped.resources then return notAllowed(t, _("List Resources")) end
        t[#t + 1] = { band = _("PUBLIC RESOURCES"), right = tostring(#d.resources) }
        if #d.resources == 0 then t[#t + 1] = { message = _("No public resources yet.") } end
        for __, r in ipairs(d.resources) do
            t[#t + 1] = { text = r.name, sub = M.resourceLine(r), chevron = true,
                icon = r.enabled and "globe" or "eye-off", dot = r.enabled and dotOf(r.health ~= "offline") or nil,
                callback = function() UI.resource(plugin, r.id) end }
        end
        return t
    end)
end

--- Sign-in off asks first: anyone could reach the resource then.
local function setSso(plugin, r)
    if r.sso then
        return KO.confirm{ title = _("Turn off sign-in?"),
            text = T(_("Anyone who knows %1 can reach it without signing in, unless it has a password, PIN or other protection."),
                r.domain ~= "" and r.domain or r.name),
            ok = _("Turn off"), cancel = _("Cancel"), danger = true,
            onOk = function() act(plugin, "resource_sso", { id = r.id, on = false }, _("Sign-in turned off")) end }
    end
    act(plugin, "resource_sso", { id = r.id, on = true }, _("Sign-in turned on"))
end

function UI.resource(plugin, id)
    local d0 = plugin:data()
    local r0 = d0 and M.find(d0, "resource", id)
    local detailWhy
    local p
    p = listPage(plugin, r0 and r0.name or _("Public resource"), function()
        local d = plugin:data()
        local r = d and M.find(d, "resource", id)
        local t = {}
        if not r then return gone(plugin, t) end
        t[#t + 1] = { band = _("RESOURCE") }
        t[#t + 1] = { toggle = r.enabled, text = _("Enabled"), sub = r.enabled and _("Reachable through Pangolin") or _("Turned off in Pangolin"),
            callback = function()
                act(plugin, "resource_enabled", { id = r.id, on = not r.enabled }, r.enabled and _("Resource disabled") or _("Resource enabled"))
            end }
        row(t, _("Health"), r.enabled and M.healthText(r.health) or nil)
        row(t, _("Address"), r.domain)
        row(t, _("Protocol"), r.mode ~= "" and r.mode:upper() or nil)

        t[#t + 1] = { band = _("ACCESS") }
        t[#t + 1] = { toggle = r.sso, text = _("Require sign-in"), sub = _("Pangolin's sign-in page before the resource"),
            callback = function() setSso(plugin, r) end }
        local detail = plugin:detail(r.id)
        if detail then
            t[#t + 1] = { toggle = detail.blockAccess, text = _("Block access"), sub = _("Turns every visitor away, without disabling it"),
                callback = function()
                    act(plugin, "resource_block", { id = r.id, on = not detail.blockAccess },
                        detail.blockAccess and _("Visitors let in again") or _("Access blocked"))
                end }
        elseif detailWhy then
            t[#t + 1] = { text = _("Block access"), sub = detailWhy }
        end
        row(t, _("Protection"), M.protection(r))

        if #r.targets > 0 then
            t[#t + 1] = { band = _("TARGETS"), right = tostring(#r.targets) }
            for __, x in ipairs(r.targets) do
                local sub = {}
                if x.site ~= "" then sub[#sub + 1] = x.site end
                if not x.enabled then sub[#sub + 1] = _("Disabled")
                elseif not x.check then sub[#sub + 1] = _("No health check") end
                t[#t + 1] = { text = x.target, sub = table.concat(sub, " · "), icon = "activity",
                    dot = x.enabled and x.check and dotOf(x.health ~= "offline") or nil,
                    right = x.enabled and x.check and M.healthText(x.health) or nil }
            end
        end
        if #r.sites > 0 then
            t[#t + 1] = { band = _("SITES") }
            for __, x in ipairs(r.sites) do
                t[#t + 1] = { text = x.name, icon = "server", dot = dotOf(x.online), right = x.online and _("Online") or _("Offline") }
            end
        end
        return t
    end)
    -- (block access isn't in the list: read once when the page opens)
    plugin:resourceDetail(id, function(__, why)
        if not alive(p) then return end
        detailWhy = why
        UI.refreshAll()
    end)
end

-- ------------------------------------------------------------------ private resources

function UI.privates(plugin)
    listPage(plugin, _("Private resources"), function()
        local early = notRead(plugin)
        if early then return early end
        local d = plugin:data()
        local t = {}
        if d.skipped.private then return notAllowed(t, _("List Site Resources")) end
        t[#t + 1] = { band = _("PRIVATE RESOURCES"), right = tostring(#d.private) }
        if #d.private == 0 then t[#t + 1] = { message = _("No private resources yet.") } end
        for __, r in ipairs(d.private) do
            t[#t + 1] = { text = r.name, sub = M.privateLine(r), icon = r.enabled and "lock" or "eye-off", chevron = true,
                callback = function() UI.private(plugin, r.id) end }
        end
        return t
    end)
end

function UI.private(plugin, id)
    local d0 = plugin:data()
    local r0 = d0 and M.find(d0, "private", id)
    listPage(plugin, r0 and r0.name or _("Private resource"), function()
        local d = plugin:data()
        local r = d and M.find(d, "private", id)
        local t = {}
        if not r then return gone(plugin, t) end
        t[#t + 1] = { band = _("RESOURCE") }
        t[#t + 1] = { toggle = r.enabled, text = _("Enabled"), sub = _("Reachable by clients on the private network"),
            callback = function()
                act(plugin, "private_enabled", { id = r.id, on = not r.enabled }, r.enabled and _("Resource disabled") or _("Resource enabled"))
            end }
        row(t, _("Mode"), r.mode ~= "" and (r.mode:sub(1, 1):upper() .. r.mode:sub(2)) or nil)
        row(t, _("Destination"), r.destination)
        row(t, _("Alias"), r.alias)
        row(t, _("Alias address"), r.aliasAddress)
        row(t, _("TCP ports"), r.tcp)
        row(t, _("UDP ports"), r.udp)
        if r.icmp ~= nil then row(t, _("Ping (ICMP)"), r.icmp and _("Allowed") or _("Blocked")) end
        if #r.sites > 0 then
            t[#t + 1] = { band = _("SITES") }
            for __, x in ipairs(r.sites) do
                t[#t + 1] = { text = x.name, icon = "server", dot = x.online ~= nil and dotOf(x.online) or nil,
                    right = x.online ~= nil and (x.online and _("Online") or _("Offline")) or nil }
            end
        end
        return t
    end)
end

-- ------------------------------------------------------------------ clients

function UI.clients(plugin)
    listPage(plugin, _("Clients"), function()
        local early = notRead(plugin)
        if early then return early end
        local d = plugin:data()
        local t = {}
        if d.skipped.machines then return notAllowed(t, _("List Clients")) end
        t[#t + 1] = { band = _("CLIENTS"), right = tostring(#d.clients) }
        if #d.clients == 0 then t[#t + 1] = { message = _("No clients yet.") } end
        for __, c in ipairs(d.clients) do
            t[#t + 1] = { text = c.name, sub = M.clientLine(c), chevron = true,
                icon = (c.blocked or c.archived) and "eye-off" or "laptop",
                dot = not (c.blocked or c.archived) and dotOf(c.online) or nil,
                callback = function() UI.client(plugin, c.id) end }
        end
        return t
    end)
end

function UI.client(plugin, id)
    local d0 = plugin:data()
    local c0 = d0 and M.find(d0, "client", id)
    listPage(plugin, c0 and c0.name or _("Client"), function()
        local d = plugin:data()
        local c = d and M.find(d, "client", id)
        local t = {}
        if not c then return gone(plugin, t) end
        t[#t + 1] = { band = _("CLIENT") }
        row(t, _("Status"), c.online and _("Online") or _("Offline"))
        row(t, _("Kind"), M.kindText(c))
        row(t, _("User"), c.user)
        row(t, _("Version"), c.version)
        row(t, _("Platform"), c.platform ~= "" and (c.platform .. (c.os ~= "" and (" " .. c.os) or "")) or nil)
        row(t, _("Device"), c.model)
        if c.lastSeen and c.lastSeen > 0 then row(t, _("Last seen"), M.ago(c.lastSeen)) end
        row(t, _("Data in"), M.size(c.mbIn))
        row(t, _("Data out"), M.size(c.mbOut))
        t[#t + 1] = { band = _("ACCESS") }
        t[#t + 1] = { toggle = c.blocked, text = _("Blocked"), sub = _("It can't connect until unblocked"),
            callback = function()
                act(plugin, "client_blocked", { id = c.id, on = not c.blocked }, c.blocked and _("Client unblocked") or _("Client blocked"))
            end }
        t[#t + 1] = { toggle = c.archived, text = _("Archived"), sub = _("Put away; it can't connect while archived"),
            callback = function()
                act(plugin, "client_archived", { id = c.id, on = not c.archived }, c.archived and _("Client unarchived") or _("Client archived"))
            end }
        return t
    end)
end

-- ------------------------------------------------------------------ more

--- Every site's data in and out back to zero: asks first (the counts can't be put back).
function UI.resetBandwidth(plugin)
    KO.confirm{ title = _("Reset bandwidth?"),
        text = _("Every site's data in and out goes back to zero. The counts so far can't be put back."),
        ok = _("Reset"), cancel = _("Cancel"), danger = true,
        onOk = function()
            plugin:act("reset_bandwidth", {}, function(ok, text)
                if ok then KO.toast(_("Bandwidth reset")) else KO.toast(text, 4) end
            end, { text = _("Resetting…") })
        end }
end

function UI.details(plugin)
    page(_("Details"), function()
        local c = plugin:cfg()
        local d = plugin:data()
        local t = { { band = _("CONNECTION") } }
        row(t, _("Organization"), plugin:orgName())
        row(t, _("Organization ID"), c.org)
        row(t, _("API URL"), c.url and M.apiBase(c.url) or nil)
        row(t, _("API key"), c.key and (M.keyId(c.key) and T(_("ID %1"), M.keyId(c.key)) or M.masked(c.key)) or nil)
        if d then
            local n = M.counts(d)
            t[#t + 1] = { band = _("COUNTS") }
            row(t, _("Sites"), tostring(n.sites))
            row(t, _("Public resources"), d.skipped.resources and _("Not allowed") or tostring(n.resources))
            row(t, _("Private resources"), d.skipped.private and _("Not allowed") or tostring(n.private))
            row(t, _("Clients"), d.skipped.machines and _("Not allowed") or tostring(n.clients))
            local total = 0
            for __, s in ipairs(d.sites) do total = total + s.mbIn + s.mbOut end
            row(t, _("Data through the sites"), M.size(total))
        end
        return t
    end)
end

-- ------------------------------------------------------------------ setting up

--- After the connection changed: read it, and say whether it worked.
local function check(plugin)
    plugin:fetch(function(d, why)
        if d then
            KO.toast(T(_("Connected to %1"), plugin:orgName()))
        else
            KO.message(plugin:whyText(why), _("Pangolin didn't answer"))
        end
    end)
end

--- Saved, then read (and the app opened, when set up from elsewhere).
local function connect(plugin, cfg, orgName)
    plugin:setCfg({ url = cfg.url, key = cfg.key, org = cfg.org, orgName = orgName or false })
    if #UI.pages == 0 then UI.show(plugin) end
    check(plugin)
end

--- The organization: picked from a root key's list, or typed (an organization key can't list them).
local function askOrg(plugin, cfg)
    local function typed()
        ask(_("Organization ID"), plugin:cfg().org or "", function(v)
            v = trim(v)
            if v == "" then return KO.toast(_("Enter the organization ID")) end
            local c = { url = cfg.url, key = cfg.key, org = v }
            plugin:checkOrg(c, function(name, why)
                if not name then
                    return KO.message(plugin:whyText(why, _("Get Organization")), _("Organization ID"))
                end
                connect(plugin, c, name)
            end)
        end, { description = _("It's in Pangolin's dashboard address, after /. Organization keys can't list organizations."),
            ok = _("Connect"), okIcon = "check" })
    end
    plugin:orgs(cfg, function(list, why)
        if not list then
            -- (an organization key: only root keys list organizations)
            if why == "forbidden" or why == "notfound" then return typed() end
            return KO.message(plugin:whyText(why), _("Pangolin didn't answer"))
        end
        if #list == 1 then
            return connect(plugin, { url = cfg.url, key = cfg.key, org = list[1].id }, list[1].name)
        end
        local items = {}
        for __, o in ipairs(list) do
            table.insert(items, { text = o.name ~= o.id and T("%1 · %2", o.name, o.id) or o.id,
                fn = function() connect(plugin, { url = cfg.url, key = cfg.key, org = o.id }, o.name) end })
        end
        table.insert(items, { text = _("Enter by hand…"), fn = typed })
        KO.list(_("Organization"), items)
    end)
end

--- The API key, then the organization.
local function askKey(plugin, url)
    ask(_("API key"), "", function(v)
        v = trim(v)
        if v == "" then return KO.toast(_("Enter the API key")) end
        askOrg(plugin, { url = url, key = v })
    end, { password = true, ok = _("Next"), okIcon = "chevron-right",
        description = _("From Pangolin's dashboard: the organization's Settings > API Keys. It looks like id.secret.") })
end

--- Setting up: the API URL, the key, then the organization.
function UI.setup(plugin)
    ask(_("API URL"), plugin:cfg().url or "", function(v)
        local url = M.cleanUrl(v)
        if not url then return KO.toast(_("Enter the API URL, such as https://api.example.com")) end
        askKey(plugin, url)
    end, { ok = _("Next"), okIcon = "chevron-right",
        description = _("Pangolin's Integration API, such as https://api.example.com (/v1 is added).") })
end

-- ------------------------------------------------------------------ settings

local EVERY = { 10, 15, 30, 60, 120, 300 }

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
        hint = _("While Pangolin is open. Nothing is read once it closes."),
        callback = function()
            local options = {}
            for __, s in ipairs(EVERY) do table.insert(options, { label = everyName(s), value = s }) end
            KO.choose(_("Read every"), options, plugin:interval(), function(s)
                G_reader_settings:saveSetting("pangolin_interval", s)
                redo()
            end)
        end }
    t[#t + 1] = { band = _("NOTIFICATIONS") }
    t[#t + 1] = { toggle = plugin:notifying(), text = _("Sites and resources going offline"),
        sub = _("Seen while Pangolin is read; it goes when they're back"),
        callback = function()
            G_reader_settings:saveSetting("pangolin_notify", not plugin:notifying())
            redo()
        end }
    t[#t + 1] = { band = _("CONNECTION") }
    t[#t + 1] = { setting = true, text = _("API URL"), value = c.url or _("Not set"), callback = function()
        ask(_("API URL"), c.url or "", function(v)
            local url = M.cleanUrl(v)
            if not url then return KO.toast(_("Enter the API URL, such as https://api.example.com")) end
            plugin:setCfg({ url = url })
            redo()
            if plugin:configured() then check(plugin) end
        end, { description = _("Pangolin's Integration API, such as https://api.example.com (/v1 is added).") })
    end }
    t[#t + 1] = { setting = true, text = _("API key"), value = c.key and M.masked(c.key) or _("Not set"), callback = function()
        ask(_("API key"), "", function(v)
            v = trim(v)
            if v == "" then return end
            plugin:setCfg({ key = v })
            redo()
            if plugin:configured() then check(plugin) end
        end, { password = true, description = _("From Pangolin's dashboard: the organization's Settings > API Keys.") })
    end }
    t[#t + 1] = { setting = true, text = _("Organization"), value = c.org and plugin:orgName() or _("Not set"), callback = function()
        if not (c.url and c.key) then return UI.setup(plugin) end
        askOrg(plugin, { url = c.url, key = c.key })
    end }
    if plugin:configured() and PS().showConnectionTest then
        t[#t + 1] = { setting = true, text = _("Test connection"), callback = function() PS().showConnectionTest("pangolin") end }
    end
    if plugin:configured() then
        t[#t + 1] = { setting = true, text = _("Remove connection"), callback = function()
            local before = plugin:cfg()
            plugin:setCfg({ url = false, key = false, org = false, orgName = false })
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
    p = page(_("Pangolin settings"), UI.settingsItems(plugin, function() redo() end))
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
    local text = _([[Shows your Pangolin server's organization on the Kindle: which sites are online, each public resource's health (and each of its targets'), private resources and clients.

You can turn resources on or off, require sign-in or block access to a public resource, block or archive a client, and reset the sites' data counters.

It talks to Pangolin's Integration API with an API key. Turn the API on in Pangolin's config.yml (enable_integration_api) and make it reachable, such as https://api.example.com. Then make an organization API key in the dashboard with the permissions for what you want: List Sites and Get Organization at least, List Resources, List Site Resources and List Clients to see those, and the Update, Block and Archive permissions to change them.

Pangolin is read while the app is open, and when the launcher shows its tile or a quick button. Nothing runs in the background.]])
    if read then
        return read{ title = _("Pangolin"), text = text, buttons = { { icon = "check", text = _("Done"), primary = true } } }
    end
    KO.message(text, _("Pangolin"))
end

return UI
