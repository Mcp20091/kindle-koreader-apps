--[[--
NextDNS's screens, drawn as the other apps' pages (ndpage):
  NextDNS          the profile (and picking another), today's queries and
                   how many were blocked, the domains blocked most, whether
                   this Kindle goes through NextDNS, and Recent queries,
                   Denylist, Allowlist and Protection
  Recent queries   the query log: All, Blocked or Allowed, and a search; a
                   query: block or allow its domain
  Denylist         each domain with its switch; + adds one; hold: delete
  Allowlist        (with Undo) or move it to the other list
  Protection       the security, privacy and parental control switches
  Settings         how often it's read, the API key and the profile
While the first page or a list is on top, NextDNS is read every so often
(Settings > Read every); nothing is read once it closes. The query log is read
when its page opens, and with ⟳.
]]

local Event = require("ui/event")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local KO = require("ndko")
local M = require("ndmodel")

local UI = {}

-- The pages open now, oldest first (Home closes them all).
UI.pages = {}

local function Page() return require("ndpage") end
local function PS() return require("pluginshare") end
local function twentyFour() return not G_reader_settings:isTrue("twelve_hour_clock") end

local LIST_NAME = { deny = _("Denylist"), allow = _("Allowlist") }
local OTHER = { deny = "allow", allow = "deny" }

--- The Apps launcher (when it's installed).
function UI.launcher()
    if KO.home() then return end
    local plugin = UI.plugin
    if plugin and plugin.ui and plugin.ui.apps then plugin.ui:handleEvent(Event:new("ShowApps")) end
end

--- Home: every NextDNS page closes, then the launcher.
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

--- ⋮ on every page: Profile, Help; then Recent apps, Light, Night mode, Refresh screen
-- and Settings last.
function UI.more()
    local plugin = UI.plugin
    if not plugin then return end
    local extra = {}
    if plugin:configured() then
        table.insert(extra, { _("Profile"), function() UI.pickProfile(plugin) end })
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
-- opts.live: NextDNS is read every so often while it's on top.
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

--- An action, with a toast when it didn't work (NextDNS is read again either way).
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

--- Every so often while one of NextDNS's live pages is on top: NextDNS again.
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

--- The line at the foot: when it was read; the profile's ID.
local function status(plugin)
    local when = plugin:readTime()
    local left
    if plugin:reading() and when == 0 then left = _("Reading…")
    elseif when > 0 then left = T(_("Updated %1"), M.clock(when, twentyFour())) end
    if plugin:lastWhy() and when > 0 then left = T(_("Not answering · last read %1"), M.clock(when, twentyFour())) end
    return left, plugin:cfg().profile
end

--- What a page shows before anything is read, or when the read failed: a message
-- (and Try again), or nil once there is something to show.
local function notRead(plugin)
    if plugin:data() then return nil end
    local why = plugin:lastWhy()
    local t = { { message = why and plugin:whyText(why) or _("Reading NextDNS…") } }
    if why then
        t[#t + 1] = { tiles = {
            { icon = "refresh-cw", text = _("Try again"), primary = true, fn = function() plugin:fetch() end },
            { icon = "sliders-horizontal", text = _("Settings"), fn = function() UI.settings(plugin) end },
        }, cols = 2 }
    end
    return t
end

-- ------------------------------------------------------------------ a domain's choices

--- What can be done with a domain (from the top blocked or the log): block or allow it
-- (or take it off that list), or search the log for it.
function UI.domainMenu(plugin, domain, back)
    local d = plugin:data()
    local items = {}
    for __, which in ipairs({ "deny", "allow" }) do
        local e = d and M.find(d, which, domain)
        if e then
            items[#items + 1] = { text = T(_("Take off the %1"), LIST_NAME[which]:lower()), fn = function()
                act(plugin, "list_delete", { list = which, domain = domain }, T(_("Taken off the %1"), LIST_NAME[which]:lower()))
            end }
        else
            items[#items + 1] = { text = which == "deny" and _("Block (add to the denylist)") or _("Allow (add to the allowlist)"), fn = function()
                act(plugin, "list_add", { list = which, domain = domain },
                    which == "deny" and T(_("%1 blocked"), domain) or T(_("%1 allowed"), domain))
            end }
        end
    end
    items[#items + 1] = { text = _("Search the queries for it"), fn = function() UI.logs(plugin, { search = domain }) end }
    KO.list(domain, items, back)
end

-- ------------------------------------------------------------------ the main page

function UI.mainItems(plugin)
    local t = {}
    if not plugin:configured() then
        t[#t + 1] = { message = _("NextDNS isn't set up yet.") }
        t[#t + 1] = { note = _("You need your NextDNS account's API key (on NextDNS's website: Account, then API at the bottom).") }
        t[#t + 1] = { gap = 10 }
        t[#t + 1] = { tiles = {
            { icon = "key-round", text = _("Set up"), sub = _("API key and profile"), primary = true, fn = function() UI.setup(plugin) end },
            { icon = "info", text = _("Help"), sub = _("What you need"), fn = function() UI.help() end },
        }, cols = 2 }
        return t
    end
    local early = notRead(plugin)
    if early then return early end
    local d = plugin:data()
    local c = plugin:cfg()
    t[#t + 1] = { setting = true, text = _("Profile"), value = plugin:profileName(), callback = function() UI.pickProfile(plugin) end }
    t[#t + 1] = { band = _("TODAY") }
    t[#t + 1] = { stats = {
        { icon = "chart-column", label = _("Queries"), value = M.number(d.total), sub = T(_("%1 allowed by your lists"), M.number(d.allowed)) },
        { icon = "ban", label = T(_("Blocked · %1"), M.percent(d.blocked, d.total)), value = M.number(d.blocked),
            bar = d.total > 0 and d.blocked / d.total or 0 },
    }, cols = 2 }

    if not d.topSkipped and #d.top > 0 then
        t[#t + 1] = { band = _("BLOCKED MOST") }
        for __, x in ipairs(d.top) do
            t[#t + 1] = { text = x.domain, icon = "ban", right = M.number(x.queries),
                callback = function() UI.domainMenu(plugin, x.domain) end }
        end
    end

    t[#t + 1] = { band = _("THIS KINDLE") }
    t[#t + 1] = { text = M.kindleText(d.kindle, c.profile), sub = M.kindleSub(d.kindle), icon = "tablet",
        dot = d.kindle and (d.kindle.using and "on" or "off") or nil,
        callback = function() plugin:fetch() KO.toast(_("Checking again…")) end }

    t[#t + 1] = { band = _("BROWSE") }
    local denyOn, deny = M.listCount(d, "deny")
    local allowOn, allow = M.listCount(d, "allow")
    local on, all = M.switchCount(d)
    t[#t + 1] = { tiles = {
        { icon = "scroll-text", text = _("Recent queries"), sub = _("Filter and search"), fn = function() UI.logs(plugin) end },
        { icon = "shield", text = _("Protection"), sub = T(_("%1 of %2 on"), on, all), fn = function() UI.protection(plugin) end },
        { icon = "ban", text = _("Denylist"), sub = deny == denyOn and tostring(deny) or T(_("%1 · %2 on"), deny, denyOn),
            fn = function() UI.list(plugin, "deny") end },
        { icon = "circle-check", text = _("Allowlist"), sub = allow == allowOn and tostring(allow) or T(_("%1 · %2 on"), allow, allowOn),
            fn = function() UI.list(plugin, "allow") end },
    }, cols = 2 }
    return t
end

--- NextDNS's first page; page "settings": its settings over it.
function UI.show(plugin, which)
    UI.plugin = plugin
    if PS().noteRecent then pcall(PS().noteRecent, "nextdns") end
    -- (already open: back to its first page)
    if UI.pages[1] and UI.pages[1].isMain then
        for k = #UI.pages, 2, -1 do UI.pages[k]:onClose() end
    else
        local p = page(plugin:profileName(), function() return UI.mainItems(plugin) end,
            { top = true, live = true, status = function() return status(plugin) end,
              on_refresh = function() plugin:fetch() end })
        p.isMain = true
        p.items_fn = function()
            p.title = plugin:profileName()
            return UI.mainItems(plugin)
        end
    end
    plugin:fetch()
    UI.poll(plugin)
    if which == "settings" then UI.settings(plugin) end
end

--- Another profile, from the account's list.
function UI.pickProfile(plugin)
    plugin:profiles(nil, function(list, why)
        if not list then return KO.message(plugin:whyText(why), _("NextDNS didn't answer")) end
        local cur = plugin:cfg().profile
        local options = {}
        for __, p in ipairs(list) do table.insert(options, { label = T("%1 · %2", p.name, p.id), value = p.id }) end
        KO.choose(_("Profile"), options, cur, function(id)
            if id == cur then return end
            for __, p in ipairs(list) do
                if p.id == id then plugin:useProfile(p) end
            end
        end)
    end)
end

-- ------------------------------------------------------------------ recent queries

--- The query log's rows from what was read.
function UI.logItems(plugin)
    local L = plugin:logState()
    local t = {}
    local chips = {}
    for __, f in ipairs(M.LOG_FILTERS) do
        chips[#chips + 1] = { text = f.name, on = L.filter == f.id, fn = function()
            if L.filter == f.id then return end
            plugin:readLogs({ filter = f.id })
        end }
    end
    if L.search ~= "" then
        chips[#chips + 1] = { text = T(_("“%1” · Clear"), L.search), on = true, fn = function() plugin:readLogs({ search = "" }) end }
    end
    t[#t + 1] = { chips = chips }
    if not L.items then
        t[#t + 1] = { message = (not L.reading and L.why) and plugin:whyText(L.why) or _("Reading the queries…") }
        return t
    end
    if L.why then t[#t + 1] = { note = plugin:whyText(L.why) } end
    if #L.items == 0 then
        t[#t + 1] = { message = L.search ~= "" and T(_("No queries with “%1”."), L.search) or _("No queries yet.") }
        return t
    end
    local now = os.time()
    local icons = { blocked = "ban", allowed = "circle-check" }
    for __, e in ipairs(L.items) do
        t[#t + 1] = { text = e.domain, sub = M.logLine(e, now, twentyFour()), icon = icons[e.status] or "globe",
            right = M.statusText(e.status), callback = function() UI.domainMenu(plugin, e.domain) end }
    end
    if L.cursor ~= "" then
        t[#t + 1] = { text = L.reading and _("Reading…") or _("Show more"), icon = "chevron-down", callback = function()
            plugin:readLogs({ more = true })
        end }
    end
    return t
end

--- The query log. opts: { search } (a search to start with).
function UI.logs(plugin, opts)
    opts = opts or {}
    local function search()
        local L = plugin:logState()
        ask(_("Search the queries"), L.search, function(v)
            plugin:readLogs({ search = trim(v) })
        end, { ok = _("Search"), okIcon = "search", description = _("A domain or part of one, such as example.") })
    end
    page(_("Recent queries"), function() return UI.logItems(plugin) end,
        { buttons = { { "search", search } },
          status = function()
              local L = plugin:logState()
              if L.reading then return _("Reading…"), plugin:cfg().profile end
              return L.time > 0 and T(_("Updated %1"), M.clock(L.time, twentyFour())) or nil, plugin:cfg().profile
          end,
          on_refresh = function() plugin:readLogs({}) end })
    plugin:readLogs({ search = opts.search or (opts.search == nil and plugin:logState().search) or "" })
end

-- ------------------------------------------------------------------ the lists

--- A domain for a list, typed.
local function addTo(plugin, which)
    ask(T(_("Add to the %1"), LIST_NAME[which]:lower()), "", function(v)
        local domain = M.cleanDomain(v)
        if not domain then return KO.toast(_("Enter a domain, such as example.com")) end
        local d = plugin:data()
        if d and M.find(d, which, domain) then return KO.toast(T(_("%1 is already on it"), domain)) end
        act(plugin, "list_add", { list = which, domain = domain }, T(_("%1 added"), domain))
    end, { ok = _("Add"), okIcon = "plus",
        description = which == "deny" and _("Blocked with all its subdomains, such as example.com.")
            or _("Never blocked, with all its subdomains, such as example.com.") })
end

--- Deleted at once, with Undo (it comes back as it was: on or off).
local function delete(plugin, which, e)
    act(plugin, "list_delete", { list = which, domain = e.domain })
    KO.undo(T(_("%1 deleted"), e.domain), function()
        act(plugin, "list_add", { list = which, domain = e.domain, active = e.active })
    end)
end

--- To the other list: added there (on), then taken off this one.
local function move(plugin, which, e)
    local other = OTHER[which]
    plugin:act("list_add", { list = other, domain = e.domain }, function(ok, text)
        if not ok then return KO.toast(text, 4) end
        act(plugin, "list_delete", { list = which, domain = e.domain }, T(_("Moved to the %1"), LIST_NAME[other]:lower()))
    end)
end

function UI.listItems(plugin, which)
    local early = notRead(plugin)
    if early then return early end
    local d = plugin:data()
    local t = {}
    t[#t + 1] = { chips = {
        { text = _("Denylist"), on = which == "deny", fn = function() UI.switchList(plugin, "deny") end },
        { text = _("Allowlist"), on = which == "allow", fn = function() UI.switchList(plugin, "allow") end },
    } }
    local on, all = M.listCount(d, which)
    t[#t + 1] = { band = which == "deny" and _("BLOCKED DOMAINS") or _("ALLOWED DOMAINS"),
        right = on == all and tostring(all) or T(_("%1 · %2 on"), all, on) }
    if #d[which] == 0 then
        t[#t + 1] = { message = which == "deny" and _("Nothing on the denylist yet.") or _("Nothing on the allowlist yet.") }
    end
    for __, e in ipairs(d[which]) do
        t[#t + 1] = { toggle = e.active, text = e.domain,
            callback = function()
                act(plugin, "list_active", { list = which, domain = e.domain, on = not e.active },
                    e.active and T(_("%1 turned off"), e.domain) or T(_("%1 turned on"), e.domain))
            end,
            hold_callback = function()
                KO.list(e.domain, {
                    { text = e.active and _("Turn off") or _("Turn on"), fn = function()
                        act(plugin, "list_active", { list = which, domain = e.domain, on = not e.active })
                    end },
                    { text = T(_("Move to the %1"), LIST_NAME[OTHER[which]]:lower()), fn = function() move(plugin, which, e) end },
                    { text = _("Search the queries for it"), fn = function() UI.logs(plugin, { search = e.domain }) end },
                    { text = _("Delete"), fn = function() delete(plugin, which, e) end },
                })
            end }
    end
    t[#t + 1] = { note = which == "deny"
        and _("A switch turns an entry off without deleting it. Hold an entry to delete it or move it to the allowlist. + adds a domain.")
        or _("A switch turns an entry off without deleting it. Hold an entry to delete it or move it to the denylist. + adds a domain.") }
    return t
end

--- The denylist or allowlist (which: "deny" or "allow"; the chips switch between them).
function UI.list(plugin, which)
    local cur = { which = which }
    local p = page(LIST_NAME[which], function() return UI.listItems(plugin, cur.which) end,
        { live = true, buttons = { { "plus", function() addTo(plugin, cur.which) end } },
          status = function() return status(plugin) end, on_refresh = function() plugin:fetch() end })
    p.list = cur
end

--- The open list page shows the other list.
function UI.switchList(plugin, which)
    for __, p in ipairs(UI.pages) do
        if p.list and p.list.which ~= which then
            p.list.which = which
            p.title = LIST_NAME[which]
            p.item_table = UI.listItems(plugin, which)
            p.sig = signature(p.item_table)
            p:redraw("full")
        end
    end
end

-- ------------------------------------------------------------------ protection

function UI.protectionItems(plugin)
    local early = notRead(plugin)
    if early then return early end
    local d = plugin:data()
    local t = {}
    for __, g in ipairs(M.GROUPS) do
        t[#t + 1] = { band = g.name }
        for __, s in ipairs(M.SWITCHES) do
            if s.group == g.key then
                local on = d.switches[s.key]
                t[#t + 1] = { toggle = on, text = s.name, sub = s.sub, callback = function()
                    act(plugin, "switch", { key = s.key, on = not on }, T(on and _("%1: off") or _("%1: on"), s.name))
                end }
            end
        end
    end
    t[#t + 1] = { note = _("The rest (blocklists, native tracking, the services and categories of parental control) is on NextDNS's website.") }
    return t
end

function UI.protection(plugin)
    page(_("Protection"), function() return UI.protectionItems(plugin) end,
        { live = true, status = function() return status(plugin) end, on_refresh = function() plugin:fetch() end })
end

-- ------------------------------------------------------------------ setting up

--- After the connection changed: read it, and say whether it worked.
local function check(plugin)
    plugin:fetch(function(d, why)
        if d then
            KO.toast(T(_("Connected to %1"), plugin:profileName()))
        else
            KO.message(plugin:whyText(why), _("NextDNS didn't answer"))
        end
    end)
end

--- Saved, then read (and the app opened, when set up from elsewhere).
local function connect(plugin, key, p)
    plugin:setCfg({ key = key, profile = p.id, profileName = p.name })
    if #UI.pages == 0 then UI.show(plugin) end
    check(plugin)
end

--- The profile, from the key's account (picked for you when there's one).
local function askProfile(plugin, key)
    plugin:profiles({ key = key }, function(list, why)
        if not list then return KO.message(plugin:whyText(why), _("NextDNS didn't answer")) end
        if #list == 0 then return KO.message(_("This account has no profiles yet. Make one on NextDNS's website."), _("NextDNS")) end
        if #list == 1 then return connect(plugin, key, list[1]) end
        local items = {}
        for __, p in ipairs(list) do
            table.insert(items, { text = T("%1 · %2", p.name, p.id), fn = function() connect(plugin, key, p) end })
        end
        KO.list(_("Profile"), items)
    end)
end

--- Setting up: the API key, then the profile.
function UI.setup(plugin)
    ask(_("API key"), "", function(v)
        v = trim(v)
        if v == "" then return KO.toast(_("Enter the API key")) end
        askProfile(plugin, v)
    end, { password = true, ok = _("Next"), okIcon = "chevron-right",
        description = _("On NextDNS's website: Account, then API at the bottom.") })
end

-- ------------------------------------------------------------------ settings

local EVERY = { 30, 60, 120, 300, 600 }

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
        hint = _("While NextDNS is open. Nothing is read once it closes."),
        callback = function()
            local options = {}
            for __, s in ipairs(EVERY) do table.insert(options, { label = everyName(s), value = s }) end
            KO.choose(_("Read every"), options, plugin:interval(), function(s)
                G_reader_settings:saveSetting("nextdns_interval", s)
                redo()
            end)
        end }
    t[#t + 1] = { band = _("CONNECTION") }
    t[#t + 1] = { setting = true, text = _("API key"), value = c.key and M.masked(c.key) or _("Not set"), callback = function()
        ask(_("API key"), "", function(v)
            v = trim(v)
            if v == "" then return end
            if not c.profile then return askProfile(plugin, v) end
            plugin:setCfg({ key = v })
            redo()
            check(plugin)
        end, { password = true, description = _("On NextDNS's website: Account, then API at the bottom.") })
    end }
    t[#t + 1] = { setting = true, text = _("Profile"), value = c.profile and plugin:profileName() or _("Not set"), callback = function()
        if not c.key then return UI.setup(plugin) end
        if not c.profile then return askProfile(plugin, c.key) end
        UI.pickProfile(plugin)
    end }
    if plugin:configured() and PS().showConnectionTest then
        t[#t + 1] = { setting = true, text = _("Test connection"), callback = function() PS().showConnectionTest("nextdns") end }
    end
    if plugin:configured() then
        t[#t + 1] = { setting = true, text = _("Remove connection"), callback = function()
            local before = plugin:cfg()
            plugin:setCfg({ key = false, profile = false, profileName = false })
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
    p = page(_("NextDNS settings"), UI.settingsItems(plugin, function() redo() end))
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
    local text = _([[Shows a NextDNS profile on the Kindle: today's queries and how many were blocked, the domains blocked most, and whether this Kindle itself goes through NextDNS.

Recent queries is the query log: all of them, only the blocked or only the allowed ones, and a search. Tap a query to block or allow its domain.

The denylist and allowlist: each domain has a switch to turn it off without deleting it; + adds one, and holding one deletes it (with Undo) or moves it to the other list.

Protection has the security, privacy and parental control switches. ⋮ > Profile picks another profile.

It talks to NextDNS's API with your account's API key (on NextDNS's website: Account, then API at the bottom). NextDNS is read while the app is open, and when the launcher shows its tile or a quick button. Nothing runs in the background.]])
    if read then
        return read{ title = _("NextDNS"), text = text, buttons = { { icon = "check", text = _("Done"), primary = true } } }
    end
    KO.message(text, _("NextDNS"))
end

return UI
