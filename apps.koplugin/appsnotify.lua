--[[--
Notifications for every app: one list, newest first, at most 100, kept in
koreader/settings/notifications.lua. The 🔔 in each app's title bar opens
it (full screen, with Clear); its badge counts the ones not seen yet.

Apps sets these up in KOReader's PluginShare when it loads; another plugin
calls them only when they are there (Apps may not be installed):

    local PS = require("pluginshare")
    if PS.notify then
        PS.notify{
            app = "todo",                 -- who sends it (its name and icon in the list)
            text = "Reminder: Call the bank",
            time = os.time(),             -- optional: now
            key = "todo:remind:<id>",     -- optional: replaces an earlier one with this key
            open = function() ... end,    -- optional: what a tap does (until KOReader restarts)
            route = { ... },              -- optional, saved: PS.notifyOpeners[app](route) after a restart
            name = "To Do", icon = "list-checks", -- optional (Lucide; known apps have theirs)
            ongoing = true,               -- optional: stays while something runs (key needed): first
                                          -- in the list, its icon by the clock in every bar, not
                                          -- counted, not cleared; tapping it doesn't remove it.
                                          -- Kept until PS.unnotify(key) or KOReader exits.
        }
    end
    PS.unnotify(key)            -- takes one out (dismissed elsewhere, say)
    PS.notifyCount()            -- how many are not seen yet (the badge on the bell)
    PS.showNotifications()      -- the full-screen list
    PS.notifyOpeners[app] = function(route, entry) ... end
    PS.notifyPopups[app] = { has = function(route) ... end, show = function(route, entry) ... end }
                                -- optional: a tap shows the app's pop-up for it over the
                                -- list (a reminder's Done, Snooze…), where `has` says so; the
                                -- pop-up takes it out (PS.unnotify) when it's dealt with. A
                                -- hold then opens it (the opener) instead of the menu.
    PS.appsHome()               -- Apps on top (the ⌂ in the title bar)

The screen on top hears of a change through its `notificationsChanged`
method, if it has one (to draw the badge again).
]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Bar = require("appsbar")
local Canvas = require("appscanvas")
local KO = require("appsko")

local Screen = Device.screen
local C = Canvas

local Notify = {}

local MAX = 100
local FILE = DataStorage:getSettingsDir() .. "/notifications.lua"

-- The apps' names and icons in the list: the launcher's here, each app's as it says
-- (appsinfo.lua, by its plugin's name).
local APPS = {
    apps = { _("Launcher"), "app-window" },
}

local function appOf(app)
    if APPS[app] then return APPS[app] end
    local ok, name, icon = pcall(function() return require("appsinfo").nameOf(app) end)
    if ok and name then return { name, icon } end
end

local store        -- LuaSettings
local opens = {}   -- entry id -> open function (this run only)
local ongoing = {} -- key -> entry, while something runs (this run only)

local function load()
    if not store then store = LuaSettings:open(FILE) end
    return store
end

local function entries()
    local list = load():readSetting("list")
    if type(list) ~= "table" then list = {} end
    return list
end

local function changed(list)
    load():saveSetting("list", list)
    store:flush()
    local top = UIManager:getTopmostVisibleWidget()
    if top and top.notificationsChanged then pcall(top.notificationsChanged, top) end
end

function Notify.list() return entries() end

--- The ongoing ones, the earliest first.
function Notify.ongoing()
    local list = {}
    for __, e in pairs(ongoing) do table.insert(list, e) end
    table.sort(list, function(a, b) return a.time < b.time end)
    return list
end

--- Adds one (see the top of this file).
function Notify.notify(n)
    if type(n) ~= "table" or not n.text or n.text == "" then return end
    if n.ongoing and n.key then
        local was = ongoing[n.key]
        ongoing[n.key] = { key = n.key, app = n.app or "apps", name = n.name, icon = n.icon, text = tostring(n.text),
            time = was and was.time or tonumber(n.time) or os.time(), open = n.open, ongoing = true }
        changed(entries())
        return n.key
    end
    local list = entries()
    local seq = (load():readSetting("seq") or 0) + 1
    store:saveSetting("seq", seq)
    local entry = {
        id = seq,
        app = n.app or "apps",
        name = n.name,
        icon = n.icon,
        text = tostring(n.text),
        time = tonumber(n.time) or os.time(),
        key = n.key,
        route = type(n.route) == "table" and n.route or nil,
    }
    if entry.key then
        for i = #list, 1, -1 do
            if list[i].key == entry.key then
                opens[list[i].id] = nil
                table.remove(list, i)
            end
        end
    end
    if n.open then opens[entry.id] = n.open end
    table.insert(list, 1, entry)
    table.sort(list, function(a, b) if a.time ~= b.time then return a.time > b.time end return a.id > b.id end)
    while #list > MAX do
        opens[list[#list].id] = nil
        table.remove(list)
    end
    changed(list)
    return entry.id
end

--- Takes out the one with this key (or id).
function Notify.unnotify(key)
    local list, any = entries(), false
    if key and ongoing[key] then
        ongoing[key] = nil
        any = true
    end
    for i = #list, 1, -1 do
        if list[i].key == key or list[i].id == key then
            opens[list[i].id] = nil
            table.remove(list, i)
            any = true
        end
    end
    if any then changed(list) end
end

function Notify.clear()
    opens = {}
    changed({})
end

--- How many came since the list was last open.
function Notify.count()
    local seen = load():readSetting("seen_id") or 0
    local n = 0
    for __, e in ipairs(entries()) do
        if (e.id or 0) > seen then n = n + 1 end
    end
    return n
end

function Notify.markSeen()
    local list = entries()
    load():saveSetting("seen_id", store:readSetting("seq") or 0)
    changed(list)
end

function Notify.appName(e)
    local a = appOf(e.app)
    return e.name or (a and a[1]) or e.app
end

function Notify.appIcon(e)
    local a = appOf(e.app)
    return e.icon or (a and a[2]) or "bell"
end

--- The app's pop-up for it (PS.notifyPopups), when it has one.
local function popupOf(e)
    if e.ongoing then return nil end
    local p = (require("pluginshare").notifyPopups or {})[e.app]
    if type(p) ~= "table" or not p.show then return nil end
    local ok, has = pcall(p.has or function() return true end, e.route, e)
    return ok and has and p or nil
end

function Notify.hasPopup(e) return popupOf(e) ~= nil end

--- Its pop-up (it stays in the list until the pop-up takes it out); false when it has none.
function Notify.popup(e)
    local p = popupOf(e)
    if not p then return false end
    pcall(p.show, e.route, e)
    return true
end

--- A tap: its own action, or the app's opener for its saved route; then gone from the list.
function Notify.open(e)
    if e.ongoing then
        if e.open then return pcall(e.open) end
        return
    end
    local fn = opens[e.id]
    Notify.unnotify(e.id)
    if fn then return pcall(fn) end
    local PS = require("pluginshare")
    local opener = PS.notifyOpeners and PS.notifyOpeners[e.app]
    if opener then return pcall(opener, e.route, e) end
end

--- "5 min ago", "2:15 PM", "Mon 9:00 AM", "Oct 12".
function Notify.when(t)
    local now = os.time()
    local d = now - t
    if d < 60 then return _("Just now") end
    if d < 3600 then return T(_("%1 min ago"), math.floor(d / 60)) end
    local clock = KO.twentyFour() and os.date("%H:%M", t) or (os.date("%I:%M %p", t):gsub("^0", ""))
    if os.date("%Y%m%d", t) == os.date("%Y%m%d", now) then return clock end
    if d < 6 * 86400 then return os.date("%a ", t) .. clock end
    return (os.date("%b %d", t):gsub(" 0", " "))
end

-- ------------------------------------------------------------------ the list

local List = InputContainer:extend{
    covers_fullscreen = true,
    flash_on_uncover = true,
}

local shown   -- the list on screen

function List:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = all } },
        Hold = { GestureRange:new{ ges = "hold", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    self.pageNo = 1
    self:render()
end

function List:currentUI()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if ReaderUI and ReaderUI.instance then return ReaderUI.instance end
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    return FileManager and FileManager.instance
end

function List:settings()
    local ui = self:currentUI()
    return ui and ui.apps and ui.apps.settings or {}
end

function List:render()
    if self.canvas then self.canvas:release() end
    local c = Canvas.new(self.w, self.h, false)
    c.turn = function(d) self:turn(d) end
    self.canvas = c
    local list = entries()
    local F = c:flow(Bar.H + 8, c.H - 8, self.pageNo)
    -- What's running now first: "Since 2:15 PM", no ✕.
    local now = Notify.ongoing()
    for __, e in ipairs(now) do
        local lines = c:wrap(e.text, 11.5, c.W - 100, 3)
        local h = 34 + 18 * #lines
        F:block(h, function(y)
            c:icon(Notify.appIcon(e), 14, y + 10, 20)
            c:text(46, y + 22, Notify.appName(e), 10, { bold = true, color = C.GREY, maxw = c.W - 200 })
            c:text(c.W - 14, y + 22, T(_("Since %1"), Notify.when(e.time)), 10, { align = "end", color = C.GREY })
            for i, line in ipairs(lines) do
                c:text(46, y + 22 + 18 * i, line, 11.5, { maxw = c.W - 100 })
            end
            c:hline(46, y + h - 1, c.W - 46)
            c:hit(0, y, c.W, h, function() self:openEntry(e) end)
        end)
    end
    if #list == 0 and #now == 0 then
        F:block(80, function(y)
            c:icon("bell", c.W / 2 - 16, y + 20, 32)
            c:text(c.W / 2, y + 74, _("No notifications."), 12, { align = "middle", color = C.GREY })
        end)
    end
    for __, e in ipairs(list) do
        local lines = c:wrap(e.text, 11.5, c.W - 100, 3)
        local h = 34 + 18 * #lines
        F:block(h, function(y)
            c:icon(Notify.appIcon(e), 14, y + 10, 20)
            c:text(46, y + 22, Notify.appName(e), 10, { bold = true, color = C.GREY, maxw = c.W - 200 })
            c:text(c.W - 14, y + 22, Notify.when(e.time), 10, { align = "end", color = C.GREY })
            for i, line in ipairs(lines) do
                c:text(46, y + 22 + 18 * i, line, 11.5, { maxw = c.W - 100 })
            end
            c:hline(46, y + h - 1, c.W - 46)
            -- (With the app's pop-up: a tap shows it over the list, a hold opens it.)
            c:hit(0, y, c.W, h, function() if not Notify.popup(e) then self:openEntry(e) end end, function()
                if Notify.hasPopup(e) then self:openEntry(e) else self:entryMenu(e) end
            end)
            -- ✕ dismisses it without opening it (added last, so it wins the tap).
            c:icon("x", c.W - 34, y + 30, 20)
            c:hit(c.W - 54, y + 26, 54, h - 26, function()
                Notify.unnotify(e.id)
                self:refresh("full")
            end)
        end)
    end
    self.pages = F:pages()
    if self.pageNo > self.pages then
        self.pageNo = self.pages
        return self:render()
    end
    Bar.draw(c, {
        title = _("Notifications"),
        back = function() self:close() end,
        home = function() self:close() Bar.home() end,
        buttons = #list > 0 and { { "trash-2", function() self:askClear() end } } or nil,
        pager = { page = self.pageNo, pages = self.pages, turn = function(d) self:turn(d) end },
        clock = true,
        refresh = function() self:refresh("full") end,
        bell = function() self:refresh("full") end,
        menu = function() self:menu() end,
    })
end

function List:menu()
    local extra = {}
    if #entries() > 0 then table.insert(extra, { _("Clear all"), function() self:askClear() end }) end
    KO.menu(self:currentUI(), self, extra, function()
        self:close()
        local ui = self:currentUI()
        if ui and ui.apps then ui.apps:show() ui.apps:openSettings() end
    end)
end

function List:askClear()
    require("appsko").confirm{ text = _("Clear all notifications?"), ok = _("Clear"), onOk = function()
            Notify.clear()
            self.pageNo = 1
            self:refresh("full")
        end }
end

function List:openEntry(e)
    self:close()
    Notify.open(e)
end

function List:entryMenu(e)
    local dialog
    dialog = require("appsko").buttonDialog{
        title = Notify.appName(e),
        title_align = "center",
        buttons = {
            { { text = _("Open"), callback = function() UIManager:close(dialog) self:openEntry(e) end } },
            { { text = _("Remove"), callback = function()
                UIManager:close(dialog)
                Notify.unnotify(e.id)
                self:refresh("full")
            end } },
            { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        },
    }
end

function List:notificationsChanged()
    self:refresh("ui")
end

function List:turn(delta)
    local n = math.max(1, math.min(self.pages or 1, self.pageNo + delta))
    if n == self.pageNo then return end
    self.pageNo = n
    self:refresh("full")
end

function List:refresh(mode)
    self:render()
    UIManager:setDirty(self, mode or "ui")
end

function List:close()
    UIManager:close(self)
end

function List:onClose()
    self:close()
    return true
end

function List:paintTo(bb, x, y)
    if self.w ~= Screen:getWidth() or self.h ~= Screen:getHeight() then
        self.w, self.h = Screen:getWidth(), Screen:getHeight()
        self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
        for __, g in pairs(self.ges_events or {}) do
            if g[1] and g[1].range then g[1].range = Geom:new{ x = 0, y = 0, w = self.w, h = self.h } end
        end
        self:render()
    end
    bb:paintRect(x, y, self.w, self.h, self.canvas and self.canvas:background() or Blitbuffer.COLOR_WHITE)
    if self.canvas then self.canvas:paint(bb, x, y) end
end

function List:onTap(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and hit.tap then hit.tap() end
    return true
end

function List:onHold(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit then (hit.hold or hit.tap or function() end)() end
    return true
end

function List:onSwipe(_, ges)
    local d = ges.direction
    if d == "northeast" or d == "northwest" or d == "southeast" or d == "southwest" then
        UIManager:setDirty(self, "full")
    elseif KO.fromLeftEdge(ges) then self:close()
    elseif d == "west" or d == "north" then self:turn(1)
    elseif d == "east" or d == "south" then self:turn(-1)
    end
    return true
end

function List:onGesture(ev)
    if KO.passGesture(self:currentUI(), ev, KO.allowed) then return true end
    return InputContainer.onGesture(self, ev)
end

function List:handleEvent(event)
    if InputContainer.handleEvent(self, event) then return true end
    return KO.passEvent(self:currentUI(), event)
end

function List:onCloseWidget()
    if self.canvas then self.canvas:release() end
    if shown == self then shown = nil end
    UIManager:setDirty(nil, "full")
end

function Notify.show()
    KO.flashOnUncover()
    if shown then UIManager:close(shown) end
    Notify.markSeen()
    shown = List:new{}
    KO.showFull(shown)
end

-- ------------------------------------------------------------------ in PluginShare

function Notify.install()
    local PS = require("pluginshare")
    PS.notify = Notify.notify
    PS.unnotify = Notify.unnotify
    PS.notifyOngoing = Notify.ongoing
    --- What's running now, for every app's clock corner: the ongoing notifications'
    -- icons (Lucide names), once each. An app draws them left of its clock (the icon
    -- must be in its icons/ folder; the web server's is globe).
    PS.statusIcons = function()
        local out, seen = {}, {}
        for __, e in ipairs(Notify.ongoing()) do
            local icon = e.icon or Notify.appIcon(e)
            if not seen[icon] then seen[icon] = true table.insert(out, icon) end
        end
        return out
    end
    PS.notifyCount = Notify.count
    PS.showNotifications = Notify.show
    PS.notifyOpeners = PS.notifyOpeners or {}
end

return Notify
