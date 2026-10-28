--[[--
To Do: Microsoft To Do in KOReader.

Tools > To Do (or a gesture: General > To Do) opens it. Tasks live on the
reader (todostore.lua): changes show at once and are sent to To Do at the
next sync, right away when Wi-Fi is already on, or in the background every
few minutes while KOReader is open. KOReader only asks to turn Wi-Fi on when
you sync by hand.

@module koplugin.todo
]]

local Blitbuffer = require("ffi/blitbuffer")
local bit = require("bit")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DateTimeWidget = require("ui/widget/datetimewidget")
local Device = require("device")
local Geom = require("ui/geometry")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local ffiutil = require("ffi/util")
local Screen = Device.screen

local Api = require("todoapi")
local Dates = require("tododates")
local Model = require("todomodel")
local Store = require("todostore")
local UI = require("todoui")
local Views = require("todoviews")

local notify     -- (a toast; below)

local Todo = WidgetContainer:extend{
    name = "todo",
    is_doc_only = false,
}

local DEFAULTS = {
    starred_first = true,
    group_by_due = true,
    show_hidden = false,
    sync_interval = 30,
    send_now = true,
    send_delay = 4,     -- seconds after the last change (2 at least)
    download_only = false,
    sleep_screen = false,
    sleep_content = "today_next",
    week_start = "sunday",
    tap_opens = "task",
    push_days = 7,
    confirm_delete = true,
    deghost = 6,                 -- a flashing refresh every this many screen changes (0: never)
    reminders = true,            -- a message at a task's reminder while KOReader is open
    two_panes = true,            -- on its side: the lists at the left, the open one at the right
    local_lists = true,          -- lists kept only on this Kindle (off: hidden, still kept)
}

local TILE_KEYS = { "today", "agenda", "starred", "calendar", "search" }

-- KOReader's network and JSON, for todoapi.
local function httpRequest(method, url, headers, body)
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
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if type(code) ~= "number" then logger.warn("To Do:", method, url:gsub("%?.*", ""), code) end
    return code, table.concat(sink)
end

function Todo:init()
    UI.setIconDir(self.path .. "/icons")
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/todo.lua")
    self.tasksFile = LuaSettings:open(DataStorage:getSettingsDir() .. "/todo_tasks.lua")
    local settings = {
        get = function(key) return self.settings:readSetting(key) end,
        set = function(key, value)
            if value == nil then self.settings:delSetting(key) else self.settings:saveSetting(key, value) end
        end,
        save = function() self.settings:flush() end,
    }
    self.api = Api.new{
        settings = settings,
        clientId = self:clientId(),
        request = httpRequest,
        json = require("json"),
    }
    self:useMicrosoftAccount()
    self:openStore()
    -- The clock: KOReader's own setting, the same in every app.
    Dates.use24h = require("todoko").twentyFour
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    Todo.instance = self
    self:hookSleepScreen()
    self:scheduleBackground()
    self:scheduleReminders()
    self:shareWithApps()
    local PS = require("pluginshare")
    -- What it is for the launcher and the web page: its tiles, Settings group, web tab
    -- (apps.koplugin/appsinfo.lua).
    PS.appInfo = PS.appInfo or {}
    PS.appInfo.todo = { name = _("To Do"), icon = "list-checks", dir = self.path, order = 20, group = "tools",
        tiles = { { key = "todo", event = "ShowTodo", line = function(todo) return todo:appsLine() end } },
        web = { page = "todo", routes = "webtodo", script = "web/todo.js",
            card = "Lists and tasks, import and export, account and options." } }
    -- A tap on one of its notifications in the shared list (Apps): the task, or Sync.
    PS.notifyOpeners = PS.notifyOpeners or {}
    PS.notifyOpeners.todo = function(route)
        local todo = Todo.instance
        if todo then todo:show(route or { kind = "sync" }) end
    end
    -- A tap on a reminder there: its pop-up again (Snooze, Open, Done) over the list.
    PS.notifyPopups = PS.notifyPopups or {}
    PS.notifyPopups.todo = {
        has = function(route) return type(route) == "table" and route.kind == "task" and route.remindAt ~= nil end,
        show = function(route)
            local todo = Todo.instance
            if not todo then return end
            local list = todo.store:findList(route.listId)
            local task = list and todo.store:findTask(route.listId, route.taskId)
            if not task or task.completed then
                if PS.unnotify then pcall(PS.unnotify, "todo:remind:" .. tostring(route.taskId)) end
                return notify(_("That task is done or gone."))
            end
            todo:showReminder(list, task, true)
        end,
    }
end

--- To Do's settings: on its open screen (brought back over Apps), or opened there.
--- Settings; `jump`: the row to open them at (the launcher's search).
function Todo:openSettings(jump)
    self.settingsJump = jump
    local page = self.page
    if page and UIManager:isWidgetShown(page) then
        local stack = UIManager._window_stack or {}
        local over = {}
        for i = #stack, 1, -1 do
            if stack[i].widget == page then break end
            table.insert(over, stack[i].widget)
        end
        for __, w in ipairs(over) do UIManager:close(w) end
        if self.screen.kind ~= "settings" then self:open({ kind = "settings" }) else self:refreshScreen() end
        return
    end
    self:show({ kind = "settings" })
end

--- What the apps share (Apps' PluginShare): To Do's settings in the list of
-- every app's, its tasks in Search, its step in Set up your Kindle.
function Todo:shareWithApps()
    local PS = require("pluginshare")
    if PS.registerSettings then
        PS.registerSettings{ key = "todo", name = _("To Do"), icon = "list-checks",
            open = function(jump) local t = Todo.instance if t then t:openSettings(jump) end end,
            -- The settings' names, for the launcher's search.
            rows = function()
                local t = Todo.instance
                if not t then return {} end
                local ok, spec = pcall(require("todoviews").settings, t, {})
                local out = {}
                for __, r in ipairs(ok and spec.rows or {}) do
                    if r.name then table.insert(out, { r.name }) end
                end
                return out
            end }
    end
    if PS.registerSearch then
        PS.registerSearch{ key = "todo", name = _("To Do"), icon = "list-checks", search = function(q)
            local t = Todo.instance
            local out = {}
            if not (t and t.store) then return out end
            for __, list in ipairs(t.store:lists()) do
                for __, task in ipairs(list.tasks or {}) do
                    if #out >= 20 then return out end
                    if not task.deleted and (task.title or ""):lower():find(q, 1, true) then
                        local due = task.due and Dates.short(task.due)
                        table.insert(out, { title = task.title,
                            sub = list.name .. (task.completed and ("  \u{00B7}  " .. _("Done")) or "") .. (due and ("  \u{00B7}  " .. due) or ""),
                            open = function()
                                local td = Todo.instance
                                if td then td:show({ kind = "task", listId = list.id, taskId = task.id }) end
                            end })
                    end
                end
            end
            return out
        end }
    end
    if PS.registerTest then
        -- Test connection (appstest.lua): Microsoft's sign-in, then To Do itself. Only once
        -- there's an App ID (lists on this Kindle alone connect to nothing).
        PS.registerTest{ key = "todo", name = _("To Do"),
            configured = function() local t = Todo.instance return t ~= nil and (t.api.clientId ~= nil or t.api:signedIn()) end,
            run = function(Test)
            local t = Todo.instance
            if not (t and (t.api.clientId or t.api:signedIn())) then return {} end
            -- (In the test's child: a token it gets isn't kept, the next sync gets its own.)
            t.api.settings.save = function() end
            local PS2 = require("pluginshare")
            if t.api.account and PS2.microsoft.store then PS2.microsoft.store().save = function() end end
            local out = {}
            for __, r in ipairs(t.api:testConnection(require("socket").gettime)) do
                if not (r.name == "signin" and t.api.account) then
                table.insert(out, { name = r.name == "signin" and _("Microsoft sign-in") or _("Microsoft To Do"), detail = r.detail,
                    ok = r.ok, ms = r.ms, raw = r.err and r.err ~= "nil" and tostring(r.err) or nil, why = r.kind == "signin" and _("Your sign-in has run out. Sign in again.")
                        or r.kind == "unreachable" and Test.why(r.err) or r.err })
                end
            end
            return out
        end }
    end
    if PS.registerQuick then
        -- A quick button for the launcher (appsquick.lua): Sync To Do (hold: what's waiting to go).
        PS.registerQuick{ key = "todo", name = _("To Do"),
            choices = function() return { { id = "sync", name = _("Sync To Do"), icon = "refresh-cw" } } end,
            item = function(id)
                local t = Todo.instance
                if id ~= "sync" or not (t and t.api:signedIn()) then return nil end
                local n = t.store:pending()
                return { label = _("Sync To Do"), icon = "refresh-cw", value = n > 0 and tostring(n) or nil,
                    tap = function() t:syncNow() end,
                    hold = function() t:show({ kind = "sync" }) end }
            end }
    end
    if PS.registerSetup and not PS.microsoft then
        PS.registerSetup{ key = "todo", order = 30, icon = "list-checks", title = _("To Do"),
            text = _("Your Microsoft To Do lists and reminders on the Kindle. It needs an App ID (a free app registration with Microsoft), then you sign in with a code on your phone or computer."),
            help = { button = _("How to get an App ID"), title = _("Getting an App ID"),
                steps = {
                    _("A personal Microsoft account first needs a free Azure account (azure.microsoft.com/free), which gives it the directory apps are registered in. A work or school account already has one."),
                    _("On a computer, sign in at portal.azure.com and open App registrations > New registration."),
                    _("Name it (\"Kindle\"), choose \"Accounts in any organizational directory and personal Microsoft accounts\", leave the redirect empty, and Register."),
                    _("Authentication: set \"Allow public client flows\" to Yes, and Save."),
                    _("API permissions: Add a permission > Microsoft Graph > Delegated: Tasks.ReadWrite (and Notes.ReadWrite for OneNote)."),
                    _("Copy the Application (client) ID from Overview, and enter it here as the App ID."),
                },
                after = _("It's free. The same App ID works for Notes' OneNote."),
                guide = "setup.md#microsoft-to-do-and-onenote" },
            done = function() local t = Todo.instance return t ~= nil and t.api:signedIn() end,
            doneText = _("Signed in"),
            action = _("Sign in"),
            skipped = _("To Do keeps lists on this Kindle only, with everything but syncing. Sign in any time to sync with Microsoft To Do (and move lists there)."),
            run = function()
                local t = Todo.instance
                if not t then return end
                if not t.api.clientId or t.api.clientId == "" then t:editClientId() else t:signIn() end
            end }
    end
end

--- In the notifications every app shares (Apps' 🔔), when Apps is there.
function Todo:notify(text, key, route)
    local PS = require("pluginshare")
    if PS.notify then pcall(PS.notify, { app = "todo", text = text, key = key, route = route }) end
end

-- The reader's copy of the tasks (todo_tasks.lua; older versions kept the
-- lists in todo.lua: moved over once).
function Todo:openStore()
    local data = self.tasksFile:readSetting("data")
    if not data and self.settings:readSetting("lists") then
        data = { lists = self.settings:readSetting("lists"), syncedAt = self.settings:readSetting("synced_at") }
        self.settings:delSetting("lists")
        self.settings:delSetting("synced_at")
        self.settings:flush()
    end
    self.store = Store.new{
        data = data,
        showLocal = function() return self:opt("local_lists") end,
        save = function(d)
            self.tasksFile:saveSetting("data", d)
            self.tasksFile:flush()
        end,
    }
end

function Todo:onDispatcherRegisterActions()
    Dispatcher:registerAction("todo_show", { category = "none", event = "ShowTodo", title = _("To Do"), general = true })
    Dispatcher:registerAction("todo_today", { category = "none", event = "ShowTodoToday", title = _("To Do: Today"), general = true })
    -- Opens the add dialog over whatever is showing (To Do need not be open).
    Dispatcher:registerAction("todo_add", { category = "none", event = "AddTodoTask", title = _("New To Do task"), general = true })
    Dispatcher:registerAction("todo_sync", { category = "none", event = "SyncTodo", title = _("To Do: sync"), general = true })
end

function Todo:addToMainMenu(menu_items)
    menu_items.todo = {
        text = _("To Do"),
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

function Todo:onShowTodo() self:show() return true end
function Todo:onShowTodoToday() self:show({ kind = "today" }) return true end
function Todo:onAddTodoTask() self:addTask({}) return true end
function Todo:onSyncTodo() self:syncNow() return true end

-- The app ID: set in To Do's settings, else client_id.txt beside this file.
--- With the launcher: the shared Microsoft account (Settings > Microsoft) signs
-- in for To Do. To Do's own sign-in from before is handed over once, and its
-- sign-out (lists on this Kindle stay) runs when the account signs out.
function Todo:useMicrosoftAccount()
    local PS = require("pluginshare")
    local account = PS.microsoft
    if not account then return end
    local s = self.settings
    if account.adopt{ clientId = self:clientId(), scope = "Tasks.ReadWrite offline_access",
            tokens = { refresh_token = s:readSetting("refresh_token"), access_token = s:readSetting("access_token"),
                expires_at = s:readSetting("expires_at"), authority = s:readSetting("authority") } } or account.signedIn() then
        -- Handed over (or the account has its own): To Do's copy goes.
        if s:readSetting("refresh_token") then
            for __, k in ipairs({ "refresh_token", "access_token", "expires_at", "authority" }) do s:delSetting(k) end
            s:flush()
        end
    end
    self.api.account = account
    self.api.clientId = account.clientId()
    account.use{ key = "todo", name = _("To Do"), scope = "Tasks.ReadWrite",
        signedIn = function()
            self.api.clientId = account.clientId()
            self:render()
            self:syncNow()
        end,
        signedOut = function() self:afterSignOut() end }
end

function Todo:clientId()
    local PS = require("pluginshare")
    if self.api and self.api.account and PS.microsoft then
        local shared = PS.microsoft.clientId()
        if shared then return shared end
    end
    local id = self.settings:readSetting("client_id")
    if id and id ~= "" then return id end
    local file = io.open(self.path .. "/client_id.txt", "r")
    if not file then return nil end
    id = file:read("*l")
    file:close()
    return id and id:match("^%s*(.-)%s*$") or nil
end

-- ------------------------------------------------------------------ settings

function Todo:opt(key)
    local v = self.settings:readSetting(key)
    if v == nil then return DEFAULTS[key] end
    return v
end

function Todo:setOpt(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
    if key == "sync_interval" then self:scheduleBackground() end
    -- Lists on this Kindle shown or hidden: the lists are worked out again.
    if key == "local_lists" then self.store.view = nil end
    self:render()
end

function Todo:flip(key)
    self:setOpt(key, not self:opt(key))
end

--- Signed in to To Do, or using lists on this Kindle: the lists and tasks show.
function Todo:usable()
    return self.api:signedIn() or self:opt("local_lists")
end

--- Not signed in, lists on this Kindle on and none yet: a first one, "Tasks".
function Todo:ensureLocalList()
    if self.api:signedIn() or not self:opt("local_lists") or #self.store:localLists() > 0 then return end
    self.store:addList(_("Tasks"), true)
end

function Todo:offset()
    return Dates.utcOffset()
end

function Todo:today()
    return Dates.today(nil, self:offset())
end

function Todo:ago(seconds)
    local minutes = math.floor((os.time() - seconds) / 60)
    if minutes < 1 then return _("just now") end
    if minutes < 60 then return T(_("%1 min ago"), minutes) end
    if minutes < 48 * 60 then return T(_("%1 h ago"), math.floor(minutes / 60)) end
    return T(_("%1 days ago"), math.floor(minutes / 1440))
end

function Todo:hiddenSet()
    return self.settings:readSetting("hidden_lists") or {}
end

-- Home tiles in order: { {key, on} }.
function Todo:tileSettings()
    local saved = self.settings:readSetting("tiles") or {}
    local out, seen = {}, {}
    for _i, t in ipairs(saved) do
        if Views.TILES[t.key] and not seen[t.key] then
            table.insert(out, { key = t.key, on = t.on ~= false })
            seen[t.key] = true
        end
    end
    for _i, key in ipairs(TILE_KEYS) do
        if not seen[key] then table.insert(out, { key = key, on = key ~= "search" }) end
    end
    return out
end

function Todo:tiles()
    local out = {}
    for _i, t in ipairs(self:tileSettings()) do
        if t.on then table.insert(out, t.key) end
    end
    return out
end

-- The lists in the user's order (pinned first); hidden ones left out unless
-- `all` or "Show hidden lists".
function Todo:orderedLists(all)
    local order = {}
    for i, id in ipairs(self.settings:readSetting("list_order") or {}) do order[id] = i end
    local pinned = self.settings:readSetting("pinned_list")
    local hidden = self:hiddenSet()
    local lists = {}
    for i, list in ipairs(self.store:lists()) do
        if all or self:opt("show_hidden") or not hidden[list.id] then
            table.insert(lists, { list = list, i = i })
        end
    end
    table.sort(lists, function(a, b)
        local pa, pb = a.list.id == pinned, b.list.id == pinned
        if pa ~= pb then return pa end
        local oa, ob = order[a.list.id] or (1000 + a.i), order[b.list.id] or (1000 + b.i)
        return oa < ob
    end)
    local out = {}
    for i, l in ipairs(lists) do out[i] = l.list end
    return out
end

function Todo:defaultListId()
    local id = self.settings:readSetting("default_list")
    if id and self.store:findList(id) then return id end
    for _i, list in ipairs(self.store:lists()) do
        if list.wellknown == "defaultList" then return list.id end
    end
    local first = self:orderedLists()[1]
    return first and first.id
end

-- ------------------------------------------------------------------ the screen

local VIEW = {
    home = Views.home, today = Views.agenda, agenda = Views.agenda, starred = Views.starred, list = Views.list,
    search = Views.search, task = Views.task, calendar = Views.calendar, sync = Views.sync, settings = Views.settings,
    order = Views.order,
}

function Todo:show(view)
    -- App lock (the launcher's): its passcode first, when this app is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask("todo", function() self:show(view) end) then return end
    if self.page then UIManager:close(self.page) end
    self:ensureLocalList()
    local PS = require("pluginshare")
    if PS.noteRecent then PS.noteRecent("todo") end
    self.stack = {}
    self.screen = { kind = "home" }
    if view then
        table.insert(self.stack, self.screen)
        self.screen = view
    end
    self.page = UI.Page:new{
        draw = function(p, zone) self:drawView(p, zone) end,
        swipe = function(direction, ges) self:onSwipe(direction, ges) end,
        close = function() self:back() end,
        kui = self.ui,
        -- A full refresh when a dialog, menu or keyboard over it closes (todoko.flashOnUncover).
        flash_on_uncover = true,
    }
    self.page.notificationsChanged = function(page)
        if UIManager:getTopmostVisibleWidget() == page then page:refresh("ui") end
    end
    require("todoko").showFull(self.page)
    require("todoko").flashOnUncover()
    self.ghost = 0
    self:tickClock()
    if self.api:signedIn() and not self.store:syncedAt() then
        UIManager:nextTick(function() self:syncNow() end)
    end
end

--- The time in the title bar, once a minute while To Do shows (only the
-- title bar is refreshed, and only when To Do is on top).
function Todo:tickClock()
    if self.clockTask then UIManager:unschedule(self.clockTask) end
    self.clockTask = function()
        self.clockTask = nil
        if not self.page then return end
        if UIManager:getTopmostVisibleWidget() == self.page then
            UIManager:setDirty(self.page, "ui", Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = math.ceil(45 * UI.unit()) })
        end
        self:tickClock()
    end
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), self.clockTask)
end

function Todo:drawView(p, zone)
    local W, H = UI.size()
    if W > H and self:opt("two_panes") and self.screen.kind ~= "home" then
        -- On its side: the views and lists at the left, the open one at the right.
        local lw = math.floor(W * 0.34)
        Views.pane(self, p, zone, lw, H)
        local rp = UI.painter(p.bb, p.ox + p:px(lw), p.oy)
        local function rzone(x, y, w, h, tap, hold) zone(x + lw, y, w, h, tap, hold) end
        Views.paneW = W - lw
        local ok, err = pcall(self.drawSpec, self, rp, rzone, W - lw)
        Views.paneW = nil
        if not ok then error(err, 0) end
        return
    end
    self:drawSpec(p, zone)
end

function Todo:drawSpec(p, zone, W)
    for _i = 1, 10 do
        local spec = VIEW[self.screen.kind](self, self.screen)
        if spec then
            Views.frame(self, self.screen, p, zone, spec, W)
            return
        end
        -- The task or list is gone (deleted, or changed by a sync): back one.
        self.screen = table.remove(self.stack) or { kind = "home" }
    end
end

--- From the left pane: a view or list in place of the one open (Home under it).
function Todo:openFromPane(view)
    self.stack = { { kind = "home" } }
    if view.kind == "search" then
        self.screen = { kind = "home" }
        return self:askSearch()
    end
    self.screen = view
    self:render(2)
end

-- The screen drawn again. Every few changes (Settings > Full refresh) the
-- refresh flashes, clearing the ghosts e-ink keeps of earlier screens;
-- switching screens (`weight` 2) leaves more than a change in place.
function Todo:render(weight)
    if not self.page then return end
    local flash
    self.ghost, flash = Model.flashDue(self.ghost, weight or 1, self:opt("deghost"))
    self.page:refresh(flash and "full" or "ui")
end

--- Refresh screen: a full flash, clearing all ghosting.
--- The ⋯ menu on Home: KOReader's light and night mode, a screen refresh, Settings.
function Todo:moreMenu()
    local extra = { { _("Sync now"), function() self:syncNow() end } }
    local web = self:webPage()
    if web then table.insert(extra, { _("Open on the web page"), function() web:openOnWeb("todo") end }) end
    require("todoko").menu(self.ui, self.page, extra, function() self:open({ kind = "settings" }) end)
end

--- 🔔: the notifications every app shares (Apps), or To Do's Sync screen without Apps.
function Todo:showNotifications()
    local PS = require("pluginshare")
    if PS.showNotifications then return PS.showNotifications() end
    self:open({ kind = "sync" })
end

--- ⌂: To Do closed, Apps on top.
function Todo:home()
    if self.page then UIManager:close(self.page) end
    self.page = nil
    require("todoko").home()
end

--- The Web server plugin, when it can open a page on the phone (Open on the web page).
function Todo:webPage()
    local web = self.ui and self.ui.webpage
    return web and web.openOnWeb and web or nil
end

function Todo:refreshScreen()
    self.ghost = 0
    if self.page then UIManager:setDirty(self.page, "full") end
end


function Todo:open(view)
    if not self.page then return self:show(view) end
    table.insert(self.stack, self.screen)
    self.screen = view
    self:render(2)
end

function Todo:back()
    if #self.stack == 0 then
        -- From Home: back to Apps (or what was under To Do).
        return self:home()
    end
    self.screen = table.remove(self.stack)
    self:render(2)
end

function Todo:turnPage(delta, wrap)
    local view = self.screen
    local pages = view.pages or 1
    local page = (view.page or 1) + delta
    if wrap and page > pages then page = 1 end
    page = math.max(1, math.min(page, pages))
    if page ~= view.page then
        view.page = page
        self:render(2)
    end
end

function Todo:onSwipe(direction, ges)
    local view = self.screen
    -- In from the left edge: Back, as in every app.
    if require("todoko").fromLeftEdge(ges) then return self:back() end
    if view.kind == "calendar" and (view.pages or 1) == 1 and (direction == "west" or direction == "east") then
        if view.monthSwipe then view.monthSwipe(direction == "west" and 1 or -1) end
        return
    end
    if direction == "west" or direction == "north" then
        self:turnPage(1)
    elseif direction == "east" or direction == "south" then
        self:turnPage(-1)
    end
end

function Todo:openTile(key)
    if key == "search" then return self:askSearch() end
    self:open({ kind = key })
end

function Todo:openTask(list, task)
    self:open({ kind = "task", listId = list.id, taskId = task.id })
end

function Todo:tapTask(list, task)
    if self:opt("tap_opens") == "menu" then return self:holdTask(list, task) end
    self:openTask(list, task)
end

function Todo:holdTask(list, task, onTask)
    local popup
    local function close() UIManager:close(popup) self:render() end
    popup = UI.Page:new{
        popup = true,
        draw = Views.holdPopup(self, list, task, close, onTask),
        outside = close,
        close = close,
        kui = self.ui,
    }
    UIManager:show(popup)
end

-- ------------------------------------------------------------------ small dialogs

local function input(title, text, onSave, extra)
    -- One line: the launcher's text box (with the pen to write it by hand), when it's there.
    local KO = require("todoko")
    -- (Several lines: a taller box; write = false: no pen, as for an App ID.)
    if KO.askText then
        local pen
        if extra and extra.write == false then pen = false end
        return KO.askText{ title = title, text = text, ok = extra and extra.ok, okIcon = extra and extra.okIcon,
            kind = "name", lines = extra and extra.multiline and 6 or nil, pen = pen, done = onSave }
    end
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = text or "",
        allow_newline = extra and extra.multiline or false,
        fullscreen = extra and extra.multiline or false,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = extra and extra.ok or _("Save"), is_enter_default = not (extra and extra.multiline), callback = function()
                local value = dialog:getInputText()
                UIManager:close(dialog)
                onSave(extra and extra.multiline and value or value:match("^%s*(.-)%s*$"))
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- A menu of choices, one a row; `current` (a choice's value) ticked. In the
-- apps' shared pop-up (KOReader's own without Apps).
local function choose(title, choices, current, back)
    local items = {}
    for _i, ch in ipairs(choices) do
        table.insert(items, { text = ch.text, enabled = ch.enabled ~= false, fn = ch.fn,
            checked = current ~= nil and ch.value == current })
    end
    require("todoko").list(title, items, back)
end

local function confirm(text, ok, fn)
    require("todoko").confirm{ text = text, ok = ok, onOk = fn }
end

function notify(text)
    require("todoko").toast(text)
end

function Todo:pickDate(day, title, fn)
    local y, m, d = Dates.toCivil(day or self:today())
    UIManager:show(DateTimeWidget:new{
        year = y, month = m, day = d,
        ok_text = _("Set date"),
        title_text = title,
        callback = function(t) fn(Dates.fromCivil(t.year, t.month, t.day)) end,
    })
end

function Todo:pickTime(minute, title, fn)
    minute = minute or 9 * 60
    UIManager:show(DateTimeWidget:new{
        hour = math.floor(minute / 60), min = minute % 60,
        ok_text = _("Set time"),
        title_text = title,
        callback = function(t) fn(t.hour * 60 + t.min) end,
    })
end

-- A moment (Unix seconds) for a local day and minute.
function Todo:moment(day, minute)
    return day * 86400 + minute * 60 - self:offset()
end

-- ------------------------------------------------------------------ changes

-- After every change: drawn again, and sent soon if Wi-Fi is already on.
function Todo:changed()
    self:render()
    self:sendSoon()
    self:pruneReminderNotes()
end

--- Reminders in the shared notifications that no longer stand (the task is
-- done, deleted, moved to another day or reminded at another time): taken out.
function Todo:pruneReminderNotes()
    local PS = require("pluginshare")
    if not (PS.notifications and PS.unnotify) then return end
    for __, e in ipairs(PS.notifications()) do
        local id = type(e.key) == "string" and e.key:match("^todo:remind:(.+)$")
        if id then
            local r = e.route or {}
            local task
            for __, list in ipairs(self.store:lists()) do
                for __, t in ipairs(list.tasks or {}) do
                    if tostring(t.id) == id then task = t end
                end
            end
            local stale = not task or task.completed or task.deleted
                or (r.remindAt ~= nil and task.remindAt ~= r.remindAt)
                or (r.due ~= nil and task.due ~= r.due)
            if stale then pcall(PS.unnotify, e.key) end
        end
    end
end

function Todo:toggleDone(list, task)
    local done = self.store:toggleDone(list.id, task.id)
    if done then notify(T(_("Done: %1"), task.title)) end
    self:changed()
end

--- Marks a task done from another plugin (Home Assistant's dashboard, Apps).
-- True when it was open and is now done.
function Todo:complete(listId, taskId)
    local list = self.store:findList(listId)
    local task = list and self.store:findTask(listId, taskId)
    if not (task and not task.completed) then return false end
    self:toggleDone(list, task)
    return true
end

function Todo:toggleStar(list, task)
    self.store:setStar(list.id, task.id, not task.important)
    self:changed()
end

function Todo:setDue(list, task, day)
    self.store:setDue(list.id, task.id, day)
    self:changed()
end

function Todo:pickDue(list, task)
    self:pickDate(task.due, _("Due date"), function(day) self:setDue(list, task, day) end)
end

function Todo:dueMenu(list, task)
    local today = self:today()
    local choices = {
        { text = _("Today"), value = today, fn = function() self:setDue(list, task, today) end },
        { text = _("Tomorrow"), value = today + 1, fn = function() self:setDue(list, task, today + 1) end },
        { text = _("Next week"), value = today + 7, fn = function() self:setDue(list, task, today + 7) end },
        { text = _("Pick a date…"), fn = function() self:pickDue(list, task) end },
    }
    if task.due then
        table.insert(choices, { text = _("No due date"), fn = function() self:clearDue(list, task) end })
    end
    choose(_("Due date"), choices, task.due)
end

function Todo:clearDue(list, task)
    if not task.due then return end
    if task.recurring then
        return self:removeRepeat(list, task)
    end
    confirm(_("Clear the due date?"), _("Clear"), function() self:setDue(list, task, nil) end)
end

function Todo:reminderMenu(list, task)
    local today = self:today()
    local day = task.due or today
    local current = task.remindAt and math.floor((task.remindAt + self:offset()) % 86400 / 60) or nil
    local choices = {
        { text = T(_("At a time on %1…"), Dates.short(day)), fn = function()
            self:pickTime(current, _("Reminder time"), function(minute)
                self.store:setReminder(list.id, task.id, self:moment(day, minute))
                self:changed()
            end)
        end },
        { text = _("Another day…"), fn = function()
            self:pickDate(day, _("Reminder day"), function(d)
                self:pickTime(current, _("Reminder time"), function(minute)
                    self.store:setReminder(list.id, task.id, self:moment(d, minute))
                    self:changed()
                end)
            end)
        end },
    }
    if task.remindAt then
        table.insert(choices, { text = _("No reminder"), fn = function() self:clearReminder(list, task) end })
    end
    choose(_("Reminder (rings on your phone; To Do keeps it)"), choices)
end

function Todo:clearReminder(list, task)
    if not task.remindAt then return end
    confirm(_("Clear the reminder?"), _("Clear"), function()
        self.store:setReminder(list.id, task.id, nil)
        self:changed()
    end)
end

function Todo:repeatMenu(list, task)
    local base = task.due or self:today()
    local function set(rec)
        self.store:setRepeat(list.id, task.id, rec, base)
        self:changed()
    end
    local current = task.recurring and Model.repeatText(task.recurrence) or nil
    local choices = {}
    for _i, kind in ipairs({ "daily", "weekdays", "weekly", "biweekly", "monthly", "yearly" }) do
        local rec = Model.preset(kind, base)
        local text = Model.repeatText(rec)
        table.insert(choices, { text = text, value = text, fn = function() set(rec) end })
    end
    table.insert(choices, { text = _("Custom…"), fn = function()
        local units = {}
        for _i, u in ipairs({ { "days", _("Days") }, { "weeks", _("Weeks") }, { "months", _("Months") }, { "years", _("Years") } }) do
            table.insert(units, { text = u[2], fn = function()
                UIManager:show(SpinWidget:new{
                    title_text = T(_("Every how many %1?"), u[2]:lower()),
                    value = 2, value_min = 1, value_max = 99, value_step = 1,
                    ok_text = _("Set"),
                    callback = function(spin) set(Model.preset("custom", base, spin.value, u[1])) end,
                })
            end })
        end
        choose(_("Repeat every…"), units, nil, function() self:repeatMenu(list, task) end)
    end })
    if task.recurring then
        table.insert(choices, { text = _("Remove repeat"), fn = function() self:removeRepeat(list, task) end })
    end
    choose(T(_("Repeat (from %1)"), Dates.short(base)), choices, current)
end

function Todo:removeRepeat(list, task)
    confirm(_("Remove the repeat?\n\nIt stops repeating and its due date is cleared. A note with the old date is added."),
        _("Remove"), function()
            self.store:removeRepeat(list.id, task.id, self:today())
            self:changed()
        end)
end

function Todo:skipToCurrent(list, task)
    local before = task.due
    local day = self.store:skipToCurrent(list.id, task.id, self:today())
    if not day then
        require("todoko").message(_("Its repeat has ended."))
    elseif day == before then
        notify(_("Already current"))
    else
        notify(T(_("Moved to %1"), Dates.short(day)))
        self:changed()
    end
end

function Todo:pushOff(list, task, days)
    self.store:pushOff(list.id, task.id, days, self:today())
    local moved = self.store:findTask(list.id, task.id)
    if moved and moved.due then notify(T(_("Pushed off to %1"), Dates.short(moved.due))) end
    self:changed()
end

function Todo:pushOffMenu(list, task)
    local choices = {}
    for _i, n in ipairs({ 1, 2, 3, 7, 14, 30 }) do
        table.insert(choices, { text = n == 1 and _("1 day") or T(_("%1 days"), n), value = n,
            fn = function() self:pushOff(list, task, n) end })
    end
    table.insert(choices, { text = _("Pick a date…"), fn = function() self:pickDue(list, task) end })
    choose(_("Postpone by"), choices, self:opt("push_days"))
end

function Todo:renameTask(list, task)
    input(_("Rename task"), task.title, function(typed)
        if typed == "" then return end
        self:understood(typed, _("Rename and set date"), function(title, due, minute)
            self.store:rename(list.id, task.id, title)
            self.store:setDue(list.id, task.id, due)
            if minute then self.store:setReminder(list.id, task.id, self:moment(due, minute)) end
            self:changed()
        end, function()
            self.store:rename(list.id, task.id, typed)
            self:changed()
        end)
    end)
end

--- A date or time in the words of `text` (Dates.understand: "Pay rent
-- Friday 9am"): what was understood is shown first, then use(title, due,
-- minute), or keep() for the text as typed. Straight to keep() when there is none.
function Todo:understood(text, action, use, keep)
    local now = os.date("*t")
    local r = Dates.understand(text, self:today(), now.hour * 60 + now.min, self:opt("week_start") == "monday" and 1 or 0)
    if not r then return keep() end
    local parts = { T(_("Due %1"), Dates.short(r.due)) }
    if r.minute then table.insert(parts, T(_("Reminder %1"), Dates.clock(r.minute))) end
    require("todoko").list("\u{201C}" .. r.title .. "\u{201D}\n" .. table.concat(parts, "  \u{00B7}  "), {
        { text = action, fn = function() use(r.title, r.due, r.minute) end },
        { text = _("Keep as typed"), fn = function() keep() end },
    })
end

function Todo:addStep(list, task)
    input(T(_("New step in %1"), task.title), "", function(title)
        if title == "" then return end
        self.store:addStep(list.id, task.id, title)
        self:changed()
    end, { ok = _("Add") })
end

function Todo:toggleStep(list, task, step)
    self.store:toggleStep(list.id, task.id, step.id)
    self:changed()
end

function Todo:stepMenu(list, task, step)
    choose(step.title, {
        { text = step.checked and _("Untick") or _("Tick off"), fn = function() self:toggleStep(list, task, step) end },
        { text = _("Rename"), fn = function()
            input(_("Rename step"), step.title, function(title)
                self.store:renameStep(list.id, task.id, step.id, title)
                self:changed()
            end)
        end },
        { text = _("Delete"), fn = function()
            confirm(_("Delete step?"), _("Delete"), function()
                self.store:deleteStep(list.id, task.id, step.id)
                self:changed()
            end)
        end },
    })
end

function Todo:editNotes(list, task)
    input(T(_("Notes: %1"), task.title), task.notes or "", function(text)
        self.store:setNotes(list.id, task.id, (text:gsub("%s+$", "")))
        self:changed()
    end, { multiline = true })
end

function Todo:moveMenu(list, task)
    local choices = {}
    for _i, l in ipairs(self:orderedLists(true)) do
        if l.id ~= list.id and l.wellknown ~= "flaggedEmails" then
            table.insert(choices, { text = l.name, fn = function()
                local id = self.store:move(list.id, task.id, l.id)
                if id and self.screen.kind == "task" and self.screen.taskId == task.id then
                    self.screen.listId, self.screen.taskId = l.id, id
                end
                notify(T(_("Moved to %1"), l.name))
                self:changed()
            end })
        end
    end
    choose(_("Move to list"), choices)
end

function Todo:togglePrivate(task)
    local on = not self.store:isPrivate(task.id)
    self.store:setPrivate(task.id, on)
    notify(on and _("Hidden on the sleep screen") or _("Shown on the sleep screen"))
    self:render()
end

--- A list's deleted tasks (until the next sync): tap one to put it back.
function Todo:showDeleted(listId)
    local choices = {}
    for _i, d in ipairs(self.store:deletedTasks(listId)) do
        table.insert(choices, { text = d.title .. (d.completed and ("  " .. _("(completed)")) or ""), fn = function()
            if self.store:restore(d.op) then
                notify(T(_("“%1” is back."), d.title))
            else
                notify(T(_("“%1” was already deleted in To Do."), d.title))
            end
            self:changed()
        end })
    end
    choose(_("Deleted: tap one to put it back"), choices)
end

--- Deleted lists (until the next sync): tap one to put it back with its tasks.
function Todo:showDeletedLists()
    local choices = {}
    for _i, d in ipairs(self.store:deletedLists()) do
        table.insert(choices, { text = d.title, fn = function()
            if self.store:restore(d.op) then
                notify(T(_("“%1” is back."), d.title))
            else
                notify(T(_("“%1” was already deleted in To Do."), d.title))
            end
            self:changed()
        end })
    end
    choose(_("Deleted lists: tap one to put it back"), choices)
end

--- Deletes a task at once, with Undo for a few seconds (and under Deleted at
-- the end of its list until the next sync).
function Todo:deleteTask(list, task)
    local op = self.store:delete(list.id, task.id)
    if self.screen.kind == "task" and self.screen.taskId == task.id then
        self.screen = table.remove(self.stack) or { kind = "home" }
    end
    self:changed()
    require("todoko").undo(T(_("Deleted “%1”"), task.title), function()
        if op and self.store:restore(op) then self:changed() end
    end)
end

--- The Add dialog: title, then list, due day, reminder, repeat and star.
-- `state`: listId, due, remindMinute, recurrence kind, important, title.
--- A new task in the launcher's request box: the title (typed, or written with the
-- pen), switches for the due date, reminder, repeat, star and list under it, Cancel
-- and Add. Pickers open over it and come back. A date or time in the words ("Pay rent
-- Friday 9am") is offered on Add, as with the keyboard. False without the launcher.
function Todo:addTaskBox(state, list, today)
    local P = require("pluginshare").popup
    if not (P and P.request) then return false end
    local box
    local function redraw() if box then box:redraw() end end
    local function picked() return state.due and state.due ~= today and state.due ~= today + 1 end
    local function titleOf() return T(_("Add to %1"), (self.store:findList(state.listId) or list).name) end
    local function add(typed)
        local function save(title)
            local fields = { title = title, due = state.due, important = state.important or false }
            if state.remindMinute then fields.remindAt = self:moment(state.due or today, state.remindMinute) end
            if state.repeatKind then fields.recurrence = Model.preset(state.repeatKind, state.due or today) end
            self.store:addTask(state.listId, fields)
            notify(T(_("Added to %1"), (self.store:findList(state.listId) or list).name))
            self:changed()
        end
        self:understood(typed, _("Add"), function(title, due, minute)
            state.due = due
            if minute then state.remindMinute = minute end
            save(title)
        end, function() save(typed) end)
    end
    box = P.request{
        app = "todo",
        title = titleOf(),
        text = state.title or "",
        hint = _("What needs doing?"),
        typing = true,
        pen = (function()
            local hw = require("pluginshare").handwriting
            local ok, on = pcall(function() return hw and hw.available() end)
            return (ok and on) and true or nil
        end)(),
        penTitle = _("New task"),
        penKind = "text",
        sections = {
            { chips = {
                { text = _("Today"), on = function() return state.due == today end,
                    tap = function() state.due = state.due ~= today and today or nil end },
                { text = _("Tomorrow"), on = function() return state.due == today + 1 end,
                    tap = function() state.due = state.due ~= today + 1 and today + 1 or nil end },
                { text = function() return picked() and Dates.short(state.due) or _("Pick date") end, on = picked,
                    tap = function()
                        self:pickDate(state.due or today, _("Due date"), function(day) state.due = day redraw() end)
                    end },
            } },
            { chips = {
                { text = function()
                    return state.remindMinute and T(_("Reminder %1"), Dates.clock(state.remindMinute)) or _("Reminder")
                end, on = function() return state.remindMinute ~= nil end,
                    tap = function()
                        if state.remindMinute then state.remindMinute = nil return end
                        self:pickTime(nil, _("Reminder time"), function(minute)
                            state.remindMinute = minute
                            state.due = state.due or today
                            redraw()
                        end)
                    end },
                { text = function()
                    return state.repeatKind and Model.repeatText(Model.preset(state.repeatKind, state.due or today)) or _("Repeat")
                end, on = function() return state.repeatKind ~= nil end,
                    tap = function()
                        local base = state.due or today
                        local choices = { { text = _("Does not repeat"), fn = function() state.repeatKind = nil redraw() end } }
                        for _i, kind in ipairs({ "daily", "weekdays", "weekly", "biweekly", "monthly", "yearly" }) do
                            table.insert(choices, { text = Model.repeatText(Model.preset(kind, base)), value = kind,
                                fn = function() state.repeatKind = kind state.due = base redraw() end })
                        end
                        choose(_("Repeat"), choices, state.repeatKind)
                    end },
                { text = function() return state.important and _("Starred") or _("Star") end, on = function() return state.important == true end,
                    tap = function() state.important = not state.important end },
            } },
            { chips = {
                { text = function() return T(_("List: %1"), (self.store:findList(state.listId) or list).name) end, on = false,
                    tap = function()
                        local choices = {}
                        for _i, l in ipairs(self:orderedLists(true)) do
                            if l.wellknown ~= "flaggedEmails" then
                                table.insert(choices, { text = l.name, value = l.id, fn = function()
                                    state.listId = l.id
                                    if box then box.title = titleOf() end
                                    redraw()
                                end })
                            end
                        end
                        choose(_("Add to list"), choices, state.listId)
                    end },
            } },
        },
        buttons = {
            { icon = "x", text = _("Cancel"), cancel = true },
            { icon = "plus", text = _("Add"), primary = true, needsText = true, fn = function(text) add(text) end },
        },
    }
    return true
end

function Todo:addTask(state)
    self:ensureLocalList()
    if not self.api:signedIn() and #self.store:lists() == 0 then
        return require("todoko").message(_("Sign in to To Do first, or turn on Lists on this Kindle in To Do's settings."))
    end
    state.listId = state.listId or self:defaultListId()
    local list = state.listId and self.store:findList(state.listId)
    if not list then return require("todoko").message(_("No list to add to. Sync first.")) end
    local today = self:today()
    -- With the launcher: its request box (the task, the pen, switches under it).
    if self:addTaskBox(state, list, today) then return end
    local dialog
    local function reopen(change)
        state.title = dialog:getInputText()
        UIManager:close(dialog)
        change(function() self:addTask(state) end)
    end
    local dueText = _("Pick date")
    if state.due and state.due ~= today and state.due ~= today + 1 then dueText = Dates.short(state.due) end
    local remindText = state.remindMinute and T(_("Reminder %1"), Dates.clock(state.remindMinute)) or _("Reminder")
    local repeatText = state.repeatKind and Model.repeatText(Model.preset(state.repeatKind, state.due or today)) or _("Repeat")
    local buttons = {
            {
                { text = T(_("List: %1"), list.name), font_bold = false, callback = function()
                    reopen(function(back)
                        local choices = {}
                        for _i, l in ipairs(self:orderedLists(true)) do
                            if l.wellknown ~= "flaggedEmails" then
                                table.insert(choices, { text = l.name, value = l.id, fn = function() state.listId = l.id back() end })
                            end
                        end
                        choose(_("Add to list"), choices, state.listId)
                    end)
                end },
            },
            {
                { text = _("Today"), font_bold = state.due == today, callback = function()
                    reopen(function(back) state.due = state.due ~= today and today or nil back() end)
                end },
                { text = _("Tomorrow"), font_bold = state.due == today + 1, callback = function()
                    reopen(function(back) state.due = state.due ~= today + 1 and today + 1 or nil back() end)
                end },
                { text = dueText, font_bold = dueText ~= _("Pick date"), callback = function()
                    reopen(function(back)
                        self:pickDate(state.due or today, _("Due date"), function(day) state.due = day back() end)
                    end)
                end },
            },
            {
                { text = remindText, font_bold = state.remindMinute ~= nil, callback = function()
                    reopen(function(back)
                        if state.remindMinute then
                            state.remindMinute = nil
                            return back()
                        end
                        self:pickTime(nil, _("Reminder time"), function(minute)
                            state.remindMinute = minute
                            state.due = state.due or today
                            back()
                        end)
                    end)
                end },
                { text = repeatText, font_bold = state.repeatKind ~= nil, callback = function()
                    reopen(function(back)
                        local base = state.due or today
                        local choices = { { text = _("Does not repeat"), fn = function() state.repeatKind = nil back() end } }
                        for _i, kind in ipairs({ "daily", "weekdays", "weekly", "biweekly", "monthly", "yearly" }) do
                            table.insert(choices, { text = Model.repeatText(Model.preset(kind, base)), value = kind,
                                fn = function() state.repeatKind = kind state.due = base back() end })
                        end
                        choose(_("Repeat"), choices, state.repeatKind)
                    end)
                end },
                { text = state.important and _("Starred") or _("Star"), font_bold = state.important == true, callback = function()
                    reopen(function(back) state.important = not state.important back() end)
                end },
            },
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("Add"), is_enter_default = true, callback = function()
                    local typed = dialog:getInputText():match("^%s*(.-)%s*$")
                    UIManager:close(dialog)
                    if typed == "" then return end
                    local function add(title)
                        local fields = { title = title, due = state.due, important = state.important or false }
                        if state.remindMinute then fields.remindAt = self:moment(state.due or today, state.remindMinute) end
                        if state.repeatKind then fields.recurrence = Model.preset(state.repeatKind, state.due or today) end
                        self.store:addTask(state.listId, fields)
                        notify(T(_("Added to %1"), list.name))
                        self:changed()
                    end
                    -- A date or time in the words ("Pay rent Friday 9am"): shown first.
                    self:understood(typed, _("Add"), function(title, due, minute)
                        state.due = due
                        if minute then state.remindMinute = minute end
                        add(title)
                    end, function() add(typed) end)
                end },
            },
    }
    local write = self:handwriteRow(state, reopen)
    if write then table.insert(buttons, #buttons, write) end
    -- Every row the same number of buttons, so the dividers line up: the options, then
    -- Cancel and Add, three to a row (nine buttons), or two (ten, with Write it).
    -- (The list's button goes from the top to just before Write it, Cancel and Add:
    -- dates, then reminder, repeat and star, then list, Cancel and Add.)
    local listRow = table.remove(buttons, 1)
    table.insert(buttons, write and #buttons - 1 or #buttons, listRow)
    local flat = {}
    for __, row in ipairs(buttons) do for __, b in ipairs(row) do table.insert(flat, b) end end
    local cols = #flat % 3 == 0 and 3 or 2
    buttons = {}
    for i, b in ipairs(flat) do
        if (i - 1) % cols == 0 then table.insert(buttons, {}) end
        table.insert(buttons[#buttons], b)
    end
    dialog = InputDialog:new{
        title = T(_("Add to %1"), list.name),
        input = state.title or "",
        buttons = buttons,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- "Write it": the task written by hand in Notes (when Notes can read
-- handwriting), its text as the title and any date it read as the due date
-- and reminder. Nil (no row) without Notes.
function Todo:handwriteRow(state, reopen)
    -- The launcher's handwriting input (PS.handwriting), else Notes' own strip.
    local H = require("pluginshare").handwriting
    local shared = H and H.available and H.available()
    local notes = self.ui.notes
    if not shared and not (notes and notes.handwrite) then return nil end
    local function write(o, done)
        if shared then return H.write({ title = o.title, kind = "task" }, done) end
        return notes:handwrite(o, done)
    end
    return {
        { text = _("Write it"), callback = function()
            reopen(function(back)
                write({ title = _("New task") }, function(text, found)
                    if text and text ~= "" then state.title = text end
                    if type(found) == "table" then
                        local due = found.due and Dates.parse(found.due)
                        if due then state.due = due end
                        local remind = type(found.remind) == "table" and found.remind or nil
                        if remind and tonumber(remind.minute) then
                            state.remindMinute = tonumber(remind.minute)
                            state.due = (remind.date and Dates.parse(remind.date)) or state.due or self:today()
                        end
                    end
                    back()
                end)
            end)
        end },
    }
end

--- Where Notes made this task from a page: { id, page, name } (Notes records it), or nil.
function Todo:notesPage(taskId)
    local notes = self.ui.notes
    if not (notes and notes.pageForTask) then return nil end
    local ok, where = pcall(notes.pageForTask, notes, taskId)
    return ok and type(where) == "table" and where.id and where or nil
end

--- A new list: in To Do, or (`onKindle`, or when not signed in) on this Kindle only.
function Todo:newList(onKindle)
    onKindle = onKindle or not self.api:signedIn()
    input(onKindle and _("New list on this Kindle") or _("New list"), "", function(name)
        if name == "" then return end
        self.store:addList(name, onKindle)
        self:changed()
    end, { ok = _("Add") })
end

--- A list's menu; back: opened from another menu (Back goes to it).
function Todo:listMenu(list, back)
    local pinned = self.settings:readSetting("pinned_list") == list.id
    local hidden = self:hiddenSet()[list.id]
    local builtIn = list.wellknown == "defaultList" or list.wellknown == "flaggedEmails"
    choose(list.name, {
        { text = _("Open"), fn = function() self:open({ kind = "list", listId = list.id }) end },
        { text = _("New task"), fn = function() self:addTask({ listId = list.id }) end },
        { text = pinned and _("Unpin") or _("Pin to top"), fn = function()
            self:setOpt("pinned_list", not pinned and list.id or false)
        end },
        { text = _("Add to launcher"), enabled = self.ui.apps ~= nil and self.ui.apps.addPin ~= nil, fn = function()
            self.ui.apps:addPin({ kind = "todo", id = list.id, name = list.name, icon = "list-checks" })
        end },
        { text = _("Set as default list"), fn = function() self:setOpt("default_list", list.id) end },
        { text = hidden and _("Show list") or _("Hide list"), fn = function()
            local set = self:hiddenSet()
            set[list.id] = not hidden or nil
            self:setOpt("hidden_lists", set)
        end },
        { text = _("Rename"), enabled = not builtIn, fn = function()
            input(_("Rename list"), list.name, function(name)
                self.store:renameList(list.id, name)
                self:changed()
            end)
        end },
        { text = _("Move to Microsoft To Do"), enabled = list.isLocal == true and self.api:signedIn(), fn = function()
            -- Asked first: once sent it's in To Do, where Undo can't take it back.
            confirm(T(_("Move “%1” to Microsoft To Do?\n\nIts tasks become To Do tasks and sync to your account. The list here goes under Deleted lists."), list.name),
                _("Move"), function()
                    local id = self.store:moveListToTodo(list.id)
                    if self.screen.listId == list.id then self.screen = { kind = "list", listId = id } end
                    self:changed()
                end)
        end },
        { text = _("Delete list"), enabled = not builtIn, fn = function()
            -- At once, with Undo (and under Deleted lists on Home until the next sync).
            local op = self.store:deleteList(list.id)
            if self.screen.listId == list.id then self.screen = table.remove(self.stack) or { kind = "home" } end
            self:changed()
            require("todoko").undo(T(_("Deleted “%1”"), list.name), function()
                if op and self.store:restore(op) then self:changed() end
            end)
        end },
    }, nil, back)
end

function Todo:viewMenu(view)
    local choices = {
        { text = self:opt("starred_first") and _("Starred first: on") or _("Starred first: off"), fn = function() self:flip("starred_first") end },
    }
    if view.kind == "list" then
        table.insert(choices, { text = self:opt("group_by_due") and _("Group by due date: on") or _("Group by due date: off"),
            fn = function() self:flip("group_by_due") end })
        local list = self.store:findList(view.listId)
        if list then table.insert(choices, { text = _("List options…"), fn = function() self:listMenu(list, function() self:viewMenu(view) end) end }) end
    end
    table.insert(choices, { text = _("Sync now"), fn = function() self:syncNow() end })
    -- This list on the phone (the web server started, a QR code to scan).
    local web = self:webPage()
    if web then
        table.insert(choices, { text = _("Open on the web page"), fn = function()
            web:openOnWeb(view.kind == "list" and view.listId and ("todo?list=" .. view.listId) or "todo")
        end })
    end
    table.insert(choices, { text = _("Refresh screen"), fn = function() self:refreshScreen() end })
    table.insert(choices, { text = _("Settings"), fn = function() self:open({ kind = "settings" }) end })
    choose(_("View"), choices)
end

function Todo:askSearch(query)
    input(_("Search tasks"), query or "", function(q)
        if q == "" then return end
        if self.screen.kind == "search" then
            self.screen.query, self.screen.page = q, 1
            self:render()
        else
            self:open({ kind = "search", query = q })
        end
    end, { ok = _("Search"), okIcon = "search" })
end

-- ------------------------------------------------------------------ settings screens

-- ------------------------------------------------------------------ order

--- Home tiles or lists, in order, for the order screen: { { key, title, on } }.
function Todo:orderItems(what)
    local out = {}
    if what == "tiles" then
        for _i, t in ipairs(self:tileSettings()) do
            table.insert(out, { key = t.key, title = Views.TILES[t.key].title, on = t.on })
        end
    else
        local hidden = self:hiddenSet()
        for _i, list in ipairs(self:orderedLists(true)) do
            table.insert(out, { key = list.id, title = list.name, on = not hidden[list.id] })
        end
    end
    return out
end

--- The order screen's order saved (all the keys, in their new order).
function Todo:saveOrder(what, keys)
    if what == "tiles" then
        local on = {}
        for _i, t in ipairs(self:tileSettings()) do on[t.key] = t.on end
        local out = {}
        for _i, key in ipairs(keys) do table.insert(out, { key = key, on = on[key] ~= false }) end
        self:setOpt("tiles", out)
    else
        self.settings:saveSetting("list_order", keys)
        self.settings:flush()
    end
end

--- A tile or list shown or hidden.
function Todo:toggleShown(what, key)
    if what == "tiles" then
        local list = self:tileSettings()
        for _i, t in ipairs(list) do if t.key == key then t.on = not t.on end end
        self:setOpt("tiles", list)
    else
        local hidden = self:hiddenSet()
        hidden[key] = not hidden[key] or nil
        self:setOpt("hidden_lists", hidden)
    end
end

--- Moves `key` by `delta` places (to the top or bottom past the ends), the
-- order before kept for Undo.
function Todo:moveOrder(view, keys, key, delta)
    local order = {}
    for i, k in ipairs(keys) do order[i] = k end
    view.undo = view.undo or {}
    table.insert(view.undo, keys)
    for i, k in ipairs(order) do
        if k == key then
            local j = math.max(1, math.min(#order, i + delta))
            table.remove(order, i)
            table.insert(order, j, key)
            break
        end
    end
    self:saveOrder(view.what, order)
    self:render()
end

function Todo:editTiles() self:open({ kind = "order", what = "tiles" }) end
function Todo:editListOrder() self:open({ kind = "order", what = "lists" }) end

function Todo:chooseList(key, allowNone)
    local choices = {}
    if allowNone then
        table.insert(choices, { text = _("None"), value = false, fn = function() self:setOpt(key, false) end })
    end
    for _i, l in ipairs(self:orderedLists(true)) do
        if l.wellknown ~= "flaggedEmails" then
            table.insert(choices, { text = l.name, value = l.id, fn = function() self:setOpt(key, l.id) end })
        end
    end
    choose(key == "pinned_list" and _("Pinned list") or _("Default list"), choices,
        key == "default_list" and self:defaultListId() or self.settings:readSetting(key))
end

function Todo:chooseTap()
    choose(_("Tap a task"), {
        { text = _("Open task"), value = "task", fn = function() self:setOpt("tap_opens", "task") end },
        { text = _("Quick actions"), value = "menu", fn = function() self:setOpt("tap_opens", "menu") end },
    }, self:opt("tap_opens"))
end

function Todo:choosePushDays()
    UIManager:show(SpinWidget:new{
        title_text = _("Postpone by (days)"),
        value = self:opt("push_days"), value_min = 1, value_max = 60, value_step = 1,
        ok_text = _("Set"),
        callback = function(spin) self:setOpt("push_days", spin.value) end,
    })
end

function Todo:chooseInterval()
    local choices = {}
    for _i, n in ipairs({ 0, 15, 30, 60, 120 }) do
        table.insert(choices, { text = n == 0 and _("Off") or T(_("Every %1 min"), n), value = n,
            fn = function() self:setOpt("sync_interval", n) end })
    end
    choose(_("Background sync"), choices, self:opt("sync_interval"))
end

--- How long after the last change they go out (Sync changes immediately): 2 seconds at least.
Todo.SEND_DELAYS = { 2, 4, 10, 30, 60 }
function Todo.sendDelayName(n) return n < 60 and T(_("After %1 s"), n) or T(_("After %1 min"), math.floor(n / 60)) end

function Todo:chooseSendDelay()
    local choices = {}
    for __, n in ipairs(Todo.SEND_DELAYS) do
        table.insert(choices, { text = Todo.sendDelayName(n), value = n, fn = function() self:setOpt("send_delay", n) end })
    end
    choose(_("Send changes"), choices, self:opt("send_delay"))
end

Todo.DEGHOST = { [6] = _("Every 6 changes"), [3] = _("Every 3 changes"), [1] = _("Every change"), [0] = _("Never") }

function Todo:chooseDeghost()
    local choices = {}
    for __, n in ipairs({ 6, 3, 1, 0 }) do
        table.insert(choices, { text = Todo.DEGHOST[n], value = n, fn = function() self:setOpt("deghost", n) end })
    end
    choose(_("Full refresh"), choices, self:opt("deghost"))
end

function Todo:flipWeekStart()
    self:setOpt("week_start", self:opt("week_start") == "monday" and "sunday" or "monday")
end

function Todo:chooseSleepContent()
    local current = self:opt("sleep_content")
    choose(_("Sleep screen content"), {
        { text = _("Today + Up next"), value = "today_next", fn = function() self:setOpt("sleep_content", "today_next") end },
        { text = _("Today"), value = "today", fn = function() self:setOpt("sleep_content", "today") end },
        { text = _("Starred"), value = "starred", fn = function() self:setOpt("sleep_content", "starred") end },
        { text = _("Pinned list"), value = "pinned", fn = function() self:setOpt("sleep_content", "pinned") end },
    }, current)
end

-- ------------------------------------------------------------------ syncing

function Todo:connected()
    local ok, on = pcall(function() return NetworkMgr:isWifiOn() and NetworkMgr:isConnected() end)
    return ok and on
end

local function describeDropped(report)
    local lines = {}
    for i, d in ipairs(report.dropped) do
        if i > 6 then
            table.insert(lines, T(_("… and %1 more"), #report.dropped - 6))
            break
        end
        local kind, what = Store.describe(d.op)
        table.insert(lines, T("%1: %2 (%3)", kind, what, tostring(d.why)))
    end
    return table.concat(lines, "\n")
end

-- Tells what a sync did, when there is something to tell.
function Todo:reportSync(report, quiet)
    -- A failure stays in the notifications until a sync goes through.
    local PS = require("pluginshare")
    if report.failed then
        self:notify(T(_("Could not download from To Do: %1"), tostring(report.failed)), "todo:sync", { kind = "sync" })
    elseif report.stopped then
        self:notify(T(_("Could not send to To Do (kept for the next sync): %1"), tostring(report.stopped)), "todo:sync", { kind = "sync" })
    elseif #report.dropped > 0 then
        self:notify(T(_("To Do refused %1 changes (they were left out)."), #report.dropped), "todo:sync", { kind = "sync" })
    elseif PS.unnotify then
        pcall(PS.unnotify, "todo:sync")
    end
    if #report.dropped > 0 then
        require("todoko").message(T(_("To Do refused %1 changes (they were left out):\n\n%2"),
            #report.dropped, describeDropped(report)))
    elseif report.failed and not quiet then
        require("todoko").message(T(_("Could not download from To Do:\n%1"), tostring(report.failed)))
    elseif report.stopped and not quiet then
        require("todoko").message(T(_("Could not send to To Do (kept for the next sync):\n%1"), tostring(report.stopped)))
    elseif not quiet and #report.deleted > 0 then
        -- Each one deleted for good, by name.
        local names = {}
        for i, title in ipairs(report.deleted) do
            if i > 8 then
                table.insert(names, T(_("… and %1 more"), #report.deleted - 8))
                break
            end
            table.insert(names, "• " .. title)
        end
        require("todoko").message(T(_("To Do synced: %1 changes sent.\n\nDeleted:\n%2"), report.sent, table.concat(names, "\n")))
    elseif not quiet then
        notify(report.sent > 0 and T(_("To Do synced: %1 changes sent"), report.sent) or _("To Do synced"))
    end
end

-- What a sync in the child may change in the sign-in settings (kept here after).
local TOKEN_KEYS = { "access_token", "refresh_token", "expires_at", "authority" }

--- The sync itself, in a child process (each request can wait on the network
-- for many seconds; the screen keeps answering meanwhile). The child sends
-- back what it ended with; changes made here in the meantime stay on top.
-- done(ok, report) runs here when it is over.
function Todo:syncInBackground(options, done)
    local store, api = self.store, self.api
    -- Each queued change gets a number, so what the child sent can be told
    -- from what was added here while it worked.
    store.data.qseq = store.data.qseq or 0
    local before = {}
    for __, op in ipairs(store.data.queue) do
        if not op.qid then
            store.data.qseq = store.data.qseq + 1
            op.qid = store.data.qseq
        end
        before[op.qid] = true
    end
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        store.saveFn = function() end
        api.settings.save = function() end
        local had = {}
        for __, k in ipairs(TOKEN_KEYS) do had[k] = api.settings.get(k) end
        local ok, report = pcall(store.sync, store, api, options)
        local tokens = {}
        for __, k in ipairs(TOKEN_KEYS) do
            if api.settings.get(k) ~= had[k] then tokens[k] = api.settings.get(k) or false end
        end
        local out = { ok = ok, report = ok and report or tostring(report), tokens = tokens }
        if ok then out.data = { lists = store.data.lists, queue = store.data.queue, syncedAt = store.data.syncedAt } end
        ffiutil.writeToFD(write_fd, require("dump")(out), true)
    end, true)
    if not pid then return done(false, tostring(fd)) end
    local deadline = os.time() + 5 * 60
    local function finish(out)
        if self.store ~= store then return done(false, "signed out") end
        for k, v in pairs(out.tokens or {}) do api.settings.set(k, v ~= false and v or nil) end
        if next(out.tokens or {}) then api.settings.save() end
        if not out.ok then return done(false, out.report) end
        local report, data = out.report, out.data
        local map = report.map or {}
        -- The child's queue (what is left of it, less what was taken out here
        -- meanwhile), then the changes made here since, with the real ids.
        local still, queue = {}, {}
        for __, op in ipairs(store.data.queue) do
            if op.qid then still[op.qid] = true end
        end
        for __, op in ipairs(data.queue or {}) do
            if op.qid and still[op.qid] then table.insert(queue, op) end
        end
        for __, op in ipairs(store.data.queue) do
            if not (op.qid and before[op.qid]) then table.insert(queue, op) end
        end
        store.data.lists = data.lists or store.data.lists
        store.data.syncedAt = data.syncedAt
        store.data.queue = queue
        -- The real ids for the changes made here meanwhile and the private
        -- marks (here, so what follows remap, like Notes' links, sees them).
        store:remap(map)
        store:save()
        done(true, report)
    end
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(0.3, check) end
            -- Stuck (a lookup that never answers): stopped; the queue is as it was.
            ffiutil.terminateSubProcess(pid)
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
            return done(true, { sent = 0, dropped = {}, deleted = {}, map = {}, stopped = _("To Do took too long to answer") })
        end
        local raw = (size and size > 0) and ffiutil.readAllFromFD(fd) or ""
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
        end
        local fn = raw ~= "" and loadstring("return " .. raw)
        local okf, out = pcall(fn or error)
        if not (okf and type(out) == "table") then return done(false, "no answer from the sync") end
        local okm, err = pcall(finish, out)
        if not okm then done(false, err) end
    end
    UIManager:scheduleIn(0.3, check)
end

--- A sync (in the background); done() when it is over. One asked for while
-- another runs follows it.
function Todo:runSync(options, quiet, done)
    if self.syncing then
        self.syncNext = { options, quiet, done }
        return
    end
    self.syncing = true
    options.offset = self:offset()
    self:syncInBackground(options, function(ok, report)
        self.syncing = false
        self:syncFinished(ok, report, quiet)
        if done then done() end
        local nextSync = self.syncNext
        self.syncNext = nil
        if nextSync then self:runSync(nextSync[1], nextSync[2], nextSync[3]) end
    end)
end

function Todo:syncFinished(ok, report, quiet)
    if not ok then
        logger.err("To Do sync:", report)
        self:notify(T(_("Sync failed: %1"), tostring(report)), "todo:sync", { kind = "sync" })
        if not quiet then require("todoko").message(T(_("Something went wrong:\n%1"), tostring(report))) end
        return
    end
    -- What is on screen (and back) follows the real ids To Do gave new things.
    local map = report.map or {}
    if next(map) then
        for _i, v in ipairs({ self.screen, unpack(self.stack or {}) }) do
            if type(v) == "table" then
                if v.listId and map[v.listId] then v.listId = map[v.listId] end
                if v.taskId and map[v.taskId] then v.taskId = map[v.taskId] end
            end
        end
    end
    self:reportSync(report, quiet)
    self:pruneReminderNotes()
    self:render()
end

--- A sync by hand (KOReader asks to turn Wi-Fi on if it is off).
function Todo:syncNow(options)
    if not self.api:signedIn() then return self:signIn() end
    options = options or {}
    if options.downloadOnly == nil then options.downloadOnly = self:opt("download_only") end
    NetworkMgr:runWhenOnline(function()
        local message = require("todoko").wait(_("Syncing To Do…"))
        self:runSync(options, false, function() message:close() end)
    end)
end

-- Changes go out a few seconds after the last one, when Wi-Fi is already on.
function Todo:sendSoon()
    if not self:opt("send_now") or self:opt("download_only") or not self.api:signedIn() then return end
    if not self.sendTask then
        self.sendTask = function()
            if self.store:pending() > 0 and self:connected() then
                self:runSync({ sendOnly = true }, true)
            end
        end
    end
    UIManager:unschedule(self.sendTask)
    UIManager:scheduleIn(math.max(2, tonumber(self:opt("send_delay")) or 4), self.sendTask)
end

local function backgroundTick()
    local self = Todo.instance
    if not self then return end
    local interval = self:opt("sync_interval")
    if interval <= 0 then return end
    if self.api:signedIn() and not Device.screen_saver_mode and self:connected() then
        self:runSync({ downloadOnly = self:opt("download_only") }, true)
    end
    UIManager:scheduleIn(interval * 60, backgroundTick)
end

-- ------------------------------------------------------------------ reminders

-- Reminders that came due since the last look (at most two hours back, as
-- after a sleep): a message for each while KOReader is open. Looked at every
-- minute.
local function reminderTick()
    local self = Todo.instance
    if not self then return end
    UIManager:scheduleIn(60, reminderTick)
    if not self:opt("reminders") or Device.screen_saver_mode then return end
    local now = os.time()
    local from = math.max(self.reminderFrom or (now - 60), now - 2 * 3600)
    self.reminderFrom = now
    -- Snoozed ones whose time came (not ones more than two hours late, as after a sleep).
    local snoozes = self.settings:readSetting("reminder_snoozes") or {}
    local left, any = {}, false
    for id, z in pairs(snoozes) do
        if z.at <= now then
            any = true
            local list = self.store:findList(z.listId)
            local task = list and self.store:findTask(z.listId, id)
            if task and not task.completed and z.at > now - 2 * 3600 then self:showReminder(list, task) end
        else
            left[id] = z
        end
    end
    if any then
        self.settings:saveSetting("reminder_snoozes", left)
        self.settings:flush()
    end
    for __, list in ipairs(self.store:lists()) do
        for __, task in ipairs(list.tasks or {}) do
            if not task.completed and task.remindAt and task.remindAt > from and task.remindAt <= now then
                self:showReminder(list, task)
            end
        end
    end
end

function Todo:scheduleReminders()
    self.reminderFrom = os.time()
    UIManager:unschedule(reminderTick)
    UIManager:scheduleIn(60, reminderTick)
end

--- A reminder's pop-up: Snooze, Open, Done. It's in the shared notifications too
-- until one of them is picked (`again`: shown from there, already in it).
function Todo:showReminder(list, task, again)
    local key = "todo:remind:" .. tostring(task.id)
    local PS = require("pluginshare")
    if not again then
        -- (Its reminder time and day kept: changed, the notification goes.)
        self:notify(T(_("Reminder: %1"), task.title), key,
            { kind = "task", listId = list.id, taskId = task.id, remindAt = task.remindAt, due = task.due })
    end
    local function dealt() if PS.unnotify then pcall(PS.unnotify, key) end end
    local function done()
        dealt()
        if not task.completed then self:toggleDone(list, task) end
    end
    local function open()
        dealt()
        self:show({ kind = "task", listId = list.id, taskId = task.id })
    end
    local function snooze() self:snoozeReminder(list, task) end
    local P = PS.popup
    if P and P.read then
        local text = task.title
        if task.remindAt then text = text .. "\n" .. T(_("At %1"), self:clockAt(task.remindAt)) end
        return P.read{ title = _("Reminder"), subtitle = list.name, text = text, buttons = {
            { icon = "clock", text = _("Snooze"), fn = snooze },
            { icon = "arrow-right", text = _("Open"), fn = open },
            { icon = "check", text = _("Done"), primary = true, fn = done },
        } }
    end
    require("todoko").list(T(_("Reminder: %1"), task.title), {
        { text = _("Done"), fn = done },
        { text = _("Snooze…"), fn = snooze },
        { text = _("Open"), fn = open },
    })
end

-- "3:30 PM" for a moment (Unix seconds).
function Todo:clockAt(t)
    return Dates.clock(math.floor((t + self:offset()) % 86400 / 60))
end

Todo.SNOOZES = { 15, 30, 60, 180 }

--- Snooze: the reminder comes back then (on this Kindle only; To Do's reminder stays as it is).
function Todo:snoozeReminder(list, task)
    local function snoozeTo(at)
        local PS = require("pluginshare")
        if PS.unnotify then pcall(PS.unnotify, "todo:remind:" .. tostring(task.id)) end
        local snoozes = self.settings:readSetting("reminder_snoozes") or {}
        snoozes[tostring(task.id)] = { listId = list.id, at = at }
        self.settings:saveSetting("reminder_snoozes", snoozes)
        self.settings:flush()
        notify(T(_("Snoozed until %1"), self:clockAt(at)))
    end
    local items = {}
    for __, m in ipairs(Todo.SNOOZES) do
        table.insert(items, { text = m < 60 and T(_("%1 minutes"), m) or (m == 60 and _("1 hour") or T(_("%1 hours"), m / 60)),
            fn = function() snoozeTo(os.time() + m * 60) end })
    end
    local morning = self:moment(self:today() + 1, 9 * 60)
    table.insert(items, { text = T(_("Tomorrow %1"), self:clockAt(morning)), fn = function() snoozeTo(morning) end })
    -- Any number of minutes, hours or days (the launcher's box, with the number keyboard): the
    -- number typed, then its unit's button.
    local P = require("pluginshare").popup
    if P and P.request then
        table.insert(items, { text = _("Custom…"), fn = function()
            local function unit(name, icon, seconds, most, primary)
                return { icon = icon, text = name, primary = primary, needsText = true, fn = function(text)
                    local n = tonumber(text)
                    if not n or n <= 0 or n > most then
                        return notify(T(_("Type a number, up to %1."), most))
                    end
                    snoozeTo(os.time() + math.floor(n * seconds))
                end }
            end
            P.request{ title = _("Snooze for"), subtitle = _("Type a number, then pick minutes, hours or days"),
                text = "", number = true, typing = true,
                onCancel = function() self:snoozeReminder(list, task) end,
                buttons = {
                    { icon = "x", text = _("Cancel"), cancel = true },
                    unit(_("Minutes"), "clock", 60, 24 * 60, true),
                    unit(_("Hours"), "clock", 3600, 24 * 7),
                    unit(_("Days"), "calendar-days", 86400, 30),
                } }
        end })
    end
    require("todoko").list(_("Snooze for"), items, function() self:showReminder(list, task, true) end)
end

function Todo:scheduleBackground()
    UIManager:unschedule(backgroundTick)
    local interval = self:opt("sync_interval")
    if interval > 0 then UIManager:scheduleIn(interval * 60, backgroundTick) end
end

-- Wi-Fi came on: a sync if the last one is older than the interval.
function Todo:onNetworkConnected()
    local interval = self:opt("sync_interval")
    if Todo.instance ~= self or interval <= 0 or not self.api:signedIn() then return end
    local last = self.store:syncedAt() or 0
    if os.time() - last >= interval * 60 or self.store:pending() > 0 then
        UIManager:scheduleIn(5, function()
            if self:connected() then self:runSync({ downloadOnly = self:opt("download_only") }, true) end
        end)
    end
end

--- Downloads To Do's copy and counts what differs from the reader's last
-- download; changes nothing.
function Todo:previewFromTodo()
    if not self.api:signedIn() then return self:signIn() end
    NetworkMgr:runWhenOnline(function()
        local message = require("todoko").wait(_("Reading To Do…"))
        UIManager:forceRePaint()
        local lists, why = self.api:fetchAll(self:offset())
        message:close()
        if not lists then
            return require("todoko").message(T(_("Could not reach To Do:\n%1"), tostring(why)))
        end
        local old = {}
        for _i, list in ipairs(self.store.data.lists) do
            for _j, t in ipairs(list.tasks) do old[t.id] = t end
        end
        local new, changed, seen = 0, 0, {}
        for _i, list in ipairs(lists) do
            for _j, t in ipairs(list.tasks) do
                seen[t.id] = true
                local o = old[t.id]
                if not o then
                    new = new + 1
                elseif o.title ~= t.title or o.due ~= t.due or o.important ~= t.important or o.remindAt ~= t.remindAt
                    or (o.notes or "") ~= (t.notes or "") or #o.steps ~= #t.steps then
                    changed = changed + 1
                end
            end
        end
        local gone = 0
        for id in pairs(old) do if not seen[id] then gone = gone + 1 end end
        require("todoko").message(T(_("Since the last sync, To Do has:\n\n%1 new tasks\n%2 changed\n%3 done or deleted\n\nNothing was changed on the reader. Sync to take them."),
            new, changed, gone))
    end)
end

function Todo:resetToTodo()
    local n = self.store:pending()
    local text = n > 0 and T(_("Reset to To Do?\n\n%1 unsent changes on the reader are thrown away and To Do's version is downloaded."), n)
        or _("Download To Do's copy again?")
    confirm(text, _("Reset"), function()
        self.store:discardQueue()
        self:render()
        self:syncNow({ downloadOnly = true })
    end)
end

function Todo:catchUp()
    local today = self:today()
    local behind = self.store:catchUpPreview(today)
    if #behind == 0 then
        return require("todoko").message(_("No repeating task is overdue."))
    end
    local lines = {}
    for i, b in ipairs(behind) do
        if i > 8 then
            table.insert(lines, T(_("… and %1 more"), #behind - 8))
            break
        end
        table.insert(lines, T("%1 → %2", b.task.title, b.day and Dates.short(b.day) or _("its repeat has ended")))
    end
    confirm(T(_("Catch up overdue repeats?\n\n%1"), table.concat(lines, "\n")), T(_("Move %1 tasks"), #behind), function()
        local moved = self.store:catchUp(today)
        notify(T(_("%1 tasks moved"), moved))
        self:changed()
    end)
end

-- ------------------------------------------------------------------ sleep screen

function Todo:sleepSupported()
    if Device.supportsScreensaver then return Device:supportsScreensaver() and true or false end
    return true
end

-- One sleep screen setting for To Do, Home Assistant and Apps (each shows
-- its own only when picked): G_reader_settings "sleep_screen_app" = "todo",
-- "homeassistant", "apps", or nil for KOReader's own.
local SLEEP_KEY = "sleep_screen_app"

--- Which sleep screen shows (To Do's older on/off setting counts until one is picked).
function Todo:sleepSource()
    local src = G_reader_settings:readSetting(SLEEP_KEY)
    if src == nil and self:opt("sleep_screen") then return "todo" end
    return src
end

function Todo:sleepSourceName()
    local names = { todo = _("To Do tasks"), homeassistant = _("Home Assistant"), apps = _("Summary"), widgets = _("Widgets") }
    return names[self:sleepSource() or ""] or _("KOReader's own")
end

function Todo:chooseSleepScreen()
    if not self:sleepSupported() then
        return require("todoko").message(_("On this device KOReader does not draw the sleep screen (on a Kindle: Amazon's ads, \"special offers\", are on), so it cannot show anything there."))
    end
    local function set(v)
        return function()
            G_reader_settings:saveSetting(SLEEP_KEY, v or false)
            if v == nil then G_reader_settings:delSetting(SLEEP_KEY) end
            self:setOpt("sleep_screen", v == "todo")
        end
    end
    local choices = {
        { text = _("KOReader's own"), value = "none", fn = set(nil) },
        { text = _("To Do tasks"), value = "todo", fn = set("todo") },
    }
    if self.ui.homeassistant then table.insert(choices, { text = _("Home Assistant"), value = "homeassistant", fn = set("homeassistant") }) end
    if self.ui.apps then table.insert(choices, { text = _("Summary"), value = "apps", fn = set("apps") }) end
    if self.ui.apps and self.ui.apps.showMode then table.insert(choices, { text = _("Widgets"), value = "widgets", fn = set("widgets") }) end
    choose(_("Sleep screen"), choices, self:sleepSource() or "none")
end

function Todo:flipSleepScreen() self:chooseSleepScreen() end

-- A plain widget that draws the sleep screen (taps go to KOReader's sleep
-- screen, which closes it).
local SleepCanvas = Widget:extend{ draw = nil }

function SleepCanvas:getSize()
    return { w = Screen:getWidth(), h = Screen:getHeight() }
end

function SleepCanvas:paintTo(bb, x, y)
    bb:paintRect(x, y, Screen:getWidth(), Screen:getHeight(), Blitbuffer.COLOR_WHITE)
    self.draw(UI.painter(bb, x, y))
end

-- KOReader's Screensaver:show, wrapped once: when the setting is on, the tasks
-- are shown instead (the same way KOReader shows its own sleep screens).
function Todo:hookSleepScreen()
    if Todo.sleepHooked then return end
    Todo.sleepHooked = true
    local Screensaver = require("ui/screensaver")
    local original = Screensaver.show
    Screensaver.show = function(saver, ...)
        local inst = Todo.instance
        if inst and inst:sleepSource() == "todo" and inst:usable() and #inst.store:lists() > 0 then
            local ok, err = pcall(inst.showSleepScreen, inst, saver)
            if ok then return end
            logger.warn("To Do sleep screen:", err)
            -- Turned upright for it: back as it was, for KOReader's own.
            local Dev = require("device")
            if Dev.orig_rotation_mode then
                Dev.screen:setRotationMode(Dev.orig_rotation_mode)
                Dev.orig_rotation_mode = nil
            end
        end
        return original(saver, ...)
    end
end

function Todo:showSleepScreen(saver)
    local ScreenSaverWidget = require("ui/widget/screensaverwidget")
    Device.screen_saver_mode = true
    local rotation = Screen:getRotationMode()
    if bit.band(rotation, 1) == 1 then
        Device.orig_rotation_mode = rotation
        Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
    else
        Device.orig_rotation_mode = nil
    end
    saver.screensaver_widget = ScreenSaverWidget:new{
        widget = SleepCanvas:new{ draw = Views.sleep(self) },
        background = Blitbuffer.COLOR_WHITE,
        covers_fullscreen = true,
    }
    saver.screensaver_widget.modal = true
    saver.screensaver_widget.dithered = true
    UIManager:show(saver.screensaver_widget, "full")
    -- Drawn again while asleep (Update while asleep): the day, what is due.
    local widget = saver.screensaver_widget
    require("todoko").sleepUpdates(function() UIManager:setDirty(widget, "full") end)
end

function Todo:chooseSleepUpdate()
    local KO = require("todoko")
    local choices = {}
    for _i, m in ipairs(KO.SLEEP_UPDATES) do
        table.insert(choices, { text = KO.sleepUpdateName(m), value = m, fn = function()
            G_reader_settings:saveSetting("sleep_screen_update", m)
            self:render()
        end })
    end
    choose(_("Sleep screen updates"), choices, KO.sleepMinutes())
end

-- ------------------------------------------------------------------ sign-in

function Todo:signIn()
    -- The shared Microsoft account (its sign-in tells To Do, which syncs).
    if self.api.account then return self.api.account.signIn() end
    if not self.api.clientId then
        require("todoko").message(_("Set the app ID first (To Do > Settings > App ID)."))
        return
    end
    NetworkMgr:runWhenOnline(function()
        local signIn, why = self.api:startSignIn()
        if not signIn then
            return require("todoko").message(T(_("Could not reach To Do:\n%1"), tostring(why)))
        end
        local cancelled = false
        local dialog
        dialog = require("todoko").buttonDialog{
            title = T(_("On a phone or computer, open\n\n%1\n\nand enter\n\n%2"), signIn.verification_uri, signIn.user_code),
            title_align = "center",
            -- Only Cancel closes it: closed any other way, it would go on asking To Do unseen.
            dismissable = false,
            buttons = { {
                { text = _("QR code"), callback = function()
                    local caption = T(_("Scan to open the sign-in page, then enter %1"), signIn.user_code)
                    local PS = require("pluginshare")
                    if PS.showQR then return PS.showQR{ text = signIn.verification_uri, caption = caption } end
                    local QRMessage = require("ui/widget/qrmessage")
                    UIManager:show(QRMessage:new{
                        text = signIn.verification_uri,
                        width = Screen:getWidth(),
                        height = Screen:getHeight(),
                    })
                end },
                { text = _("Cancel"), callback = function()
                    cancelled = true
                    UIManager:close(dialog)
                end },
            } },
        }
        local interval = tonumber(signIn.interval) or 5
        local deadline = os.time() + (tonumber(signIn.expires_in) or 900)
        -- Each look waits on the network (and the screen with it): three slow
        -- ones in a row (the connection is gone) end it.
        local slow = 0
        local function poll()
            if cancelled then return end
            if os.time() > deadline then
                UIManager:close(dialog)
                require("todoko").message(_("The code ran out. Try signing in again."))
                return
            end
            local started = os.time()
            local result, err = self.api:pollSignIn(signIn)
            slow = (result == "pending" and os.time() - started >= 8) and slow + 1 or 0
            if slow >= 3 then
                UIManager:close(dialog)
                require("todoko").message(_("Lost the connection to Microsoft. Check Wi-Fi and try signing in again."))
                return
            end
            if result == "ok" then
                UIManager:close(dialog)
                notify(_("Signed in to To Do"))
                self:render()
                self:syncNow()
            elseif result == "pending" or result == "slow_down" then
                if result == "slow_down" then interval = interval + 5 end
                UIManager:scheduleIn(interval, poll)
            else
                UIManager:close(dialog)
                require("todoko").message(T(_("Could not sign in:\n%1"), tostring(err or _("The code ran out"))))
            end
        end
        UIManager:scheduleIn(interval, poll)
    end)
end

function Todo:signOut()
    local n = self.store:pending()
    local text = n > 0 and T(_("Sign out?\n\n%1 unsent changes and the tasks kept on the reader are removed."), n)
        or _("Sign out?\n\nThe tasks kept on the reader are removed.")
    confirm(text, _("Sign out"), function()
        -- The shared account signs out every app (and tells To Do: afterSignOut).
        if self.api.account then return self.api.account.signOut() end
        self.api:signOut()
        self:afterSignOut()
    end)
end

--- After signing out: To Do's synced lists go; lists on this Kindle stay.
function Todo:afterSignOut()
    local d = self.store.data
    self.tasksFile:saveSetting("data", { locals = d.locals, localSeq = d.localSeq, localTrash = d.localTrash })
    self.tasksFile:flush()
    self:openStore()
    self.stack, self.screen = {}, { kind = "home" }
    self:render()
end

function Todo:editClientId()
    if self.api.account then return require("pluginshare").microsoft.showSettings() end
    input(_("App ID (Microsoft Entra application ID)"), self.api.clientId or "", function(id)
        self.settings:saveSetting("client_id", id ~= "" and id or nil)
        self.settings:flush()
        self.api.clientId = self:clientId()
        self:render()
    end, { write = false })
end

-- ------------------------------------------------------------------ in Apps

--- Today, Agenda, Starred, Calendar and Search as Apps pins:
-- { kind = "todoview", id = "agenda", name, icon }.
function Todo:viewPins()
    local out = {}
    for _i, key in ipairs(TILE_KEYS) do
        local t = Views.TILES[key]
        table.insert(out, { kind = "todoview", id = key, name = t.title, icon = t.icon })
    end
    return out
end

--- A view's line, as on its Home tile ("5 in the next 7 days").
function Todo:viewLine(key)
    local today = self:today()
    local s = Model.summary(self.store:lists(), today, { hidden = self:hiddenSet() })
    return Views.tileLines(s, today)[key] or ""
end

--- Opens a view from Apps (Search asks what to look for).
function Todo:showView(key)
    -- App lock (the launcher's): its passcode first, when this app is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask("todo", function() self:showView(key) end) then return end
    if key == "search" then
        self:show()
        return self:askSearch()
    end
    self:show({ kind = key })
end

--- Holding a Home tile: open it, or add it to Apps.
function Todo:tileMenu(key)
    local pin
    for _i, p in ipairs(self:viewPins()) do
        if p.id == key then pin = p end
    end
    local apps = self.ui.apps
    choose(pin and pin.name or "", {
        { text = _("Open"), fn = function() self:openTile(key) end },
        { text = _("Add to launcher"), enabled = apps ~= nil and apps.addPin ~= nil and pin ~= nil, fn = function() apps:addPin(pin) end },
    })
end

--- The launcher's tile line: "2 today · 1 overdue", "Nothing due".
function Todo:appsLine()
    if not self.store then return "" end
    local s = require("todomodel").summary(self.store:lists(), self:today(), { hidden = self:hiddenSet() })
    if s.today == 0 and s.overdue == 0 then
        return s.week > 0 and T(_("Nothing today · %1 this week"), s.week) or _("Nothing due")
    end
    return T(_("%1 today"), s.today) .. (s.overdue > 0 and (" · " .. T(_("%1 overdue"), s.overdue)) or "")
end

return Todo
