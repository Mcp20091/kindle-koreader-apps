--[[--
Web server: the reader's own web page, for a phone or computer on the same
Wi-Fi (as CrossInk's web page): files, and pages for the Home Assistant, To
Do and Notes plugins (setup, sign-ins, app IDs, reordering, and more).

Tools > Web server starts it and shows the address (and a QR code). It runs
until stopped, or after 30 minutes nobody uses it; meanwhile the reader stays
awake.

@module koplugin.webpage
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local _ = require("gettext")
local T = require("ffi/util").template

local Server = require("webserver")

local Screen = Device.screen

-- One server for all of KOReader (the plugin is made again for each book and the file browser).
local running = nil   -- { server, port, last, task }

local WebPage = WidgetContainer:extend{
    name = "webpage",
    is_doc_only = false,
}

local function setting(key, default)
    local v = G_reader_settings:readSetting("webpage_" .. key)
    if v == nil then return default end
    return v
end

local function setSetting(key, value)
    G_reader_settings:saveSetting("webpage_" .. key, value)
end

--- The reader's address on the Wi-Fi (no packet is sent to find it).
local function localIp()
    local socket = require("socket")
    local udp = socket.udp()
    if not udp then return nil end
    udp:setpeername("192.0.2.1", 9)
    local ip = udp:getsockname()
    udp:close()
    if ip and ip ~= "0.0.0.0" then return ip end
end

function WebPage:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- Automatic backups run whether or not the web server is on.
    require("websystem").scheduleBackups()
    -- Diagnostics: KOReader's start in the sleep history (once per start),
    -- and detailed logging turned off after its day.
    local Diag = require("webdiag")
    if not Diag.started then
        Diag.started = true
        pcall(Diag.note, "start")
    end
    Diag.watchLogging()
    -- (the log's lines kept, without the noise, across KOReader's restarts)
    Diag.watchHistory()
    self:shareWithApps()
end

--- What the apps share (Apps' PluginShare): the web server's settings as a
-- full page in the list of every app's settings, and its password in Set up
-- your Kindle.
function WebPage:shareWithApps()
    local PS = require("pluginshare")
    local function web()
        local ReaderUI = package.loaded["apps/reader/readerui"]
        local FileManager = package.loaded["apps/filemanager/filemanager"]
        local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
        return ui and ui.webpage
    end
    if PS.registerSettings and PS.settingsPage then
        -- The settings page's rows (search reads their names too).
        local function rows()
            local w = web()
            if not w then return {} end
            local Auth = require("webauth")
            return {
                { heading = _("WEB SERVER") },
                { _("Web server"), running ~= nil, function() if running then w:stop() else w:start() end end },
                { _("Address"), running and w:address() or _("Off"), function() if running then w:showAddress() else w:start() end end },
                { _("Keep the Kindle awake while on"), setting("awake", true), function()
                    setSetting("awake", not setting("awake", true))
                    w:keepAwake()
                end },
                { _("Stop after 30 minutes unused"), setting("idle_stop", true), function() setSetting("idle_stop", not setting("idle_stop", true)) end },
                { _("Port"), tostring(setting("port", 8080)), function() w:askPort() end },
                { heading = _("SECURITY") },
                { _("Password"), Auth.isSet() and _("On") or _("Off"), function() w:askPassword() end },
                Auth.isSet() and { _("Remove password"), "", function()
                    Auth.clear()
                    require("webcommon").toast(_("Password removed."), 3)
                end } or false,
                { heading = _("PLUGINS") },
                { _("Undo a plugin update"), "", function() require("webplugins").undoMenu(w) end },
            }
        end
        PS.registerSettings{ key = "webpage", name = _("Web server"), icon = "globe", open = function(jump)
            PS.settingsPage{ title = _("Web server settings"), jump = jump, rows = rows }
        end, rows = rows }
    end
    if PS.registerSetup then
        local here = (debug.getinfo(1, "S").source or ""):match("^@(.*/)") or ""
        PS.registerSetup{ key = "webpage", order = 70, icon = "globe", title = _("The web page"),
            text = _("Start the web server (Tools > Web server, or Web server in the control center) and open the address it shows on a phone or computer on the same Wi-Fi. There you can install updates (System > Update plugins), add books and fonts, arrange the home screen and quick buttons by dragging, and type tasks and notes with a real keyboard. Set a password so only you can use it."),
            image = here .. "setup-web.png",
            done = function() return require("webauth").isSet() end,
            doneText = _("Password set"), action = _("Set a password"),
            skipped = _("The web page works without one, but anyone on your Wi-Fi can open it while the web server runs."),
            run = function() local w = web() if w then w:askPassword() end end }
    end
end

function WebPage:onDispatcherRegisterActions()
    Dispatcher:registerAction("webpage_toggle", { category = "none", event = "ToggleWebPage", title = _("Toggle web server"), general = true })
end

function WebPage:addToMainMenu(menu_items)
    menu_items.webpage = {
        text_func = function()
            return running and T(_("Web server: %1"), self:address()) or _("Web server")
        end,
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function() return running and _("Stop web server") or _("Start web server") end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    if running then self:stop() else self:start() end
                    if touchmenu then touchmenu:updateItems() end
                end,
            },
            {
                text = _("Show address"),
                enabled_func = function() return running ~= nil end,
                callback = function() self:showAddress() end,
            },
            {
                text = _("Keep Kindle awake while running"),
                checked_func = function() return setting("awake", true) end,
                callback = function()
                    setSetting("awake", not setting("awake", true))
                    self:keepAwake()
                end,
            },
            {
                text = _("Stop after 30 minutes of inactivity"),
                checked_func = function() return setting("idle_stop", true) end,
                callback = function() setSetting("idle_stop", not setting("idle_stop", true)) end,
            },
            {
                text_func = function() return require("webauth").isSet() and _("Password: On") or _("Password: Off") end,
                keep_menu_open = true,
                callback = function(touchmenu) self:askPassword(touchmenu) end,
            },
            {
                text = _("Remove password"),
                enabled_func = function() return require("webauth").isSet() end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    require("webauth").clear()
                    require("webcommon").toast(_("Password removed."), 3)
                    if touchmenu then touchmenu:updateItems() end
                end,
            },
            {
                text = _("Undo a plugin update"),
                callback = function() require("webplugins").undoMenu(self) end,
            },
            {
                text_func = function() return T(_("Port: %1"), setting("port", 8080)) end,
                keep_menu_open = true,
                callback = function(touchmenu) self:askPort(touchmenu) end,
            },
        },
    }
end

--- Sets (or changes) the web server's password.
function WebPage:askPassword(touchmenu)
    local function set(pw)
        require("webauth").set(pw)
        require("webcommon").toast(_("Password set. Browsers will ask for it."), 3)
        if touchmenu then touchmenu:updateItems() end
    end
    -- The launcher's text box (dots, no pen), when it's there.
    local KO = require("pluginshare").ko
    if KO and KO.askText then
        return KO.askText{ title = _("Web server password"), hint = _("At least 4 characters"), password = true, pen = false,
            subtitle = _("Browsers ask for it. It keeps visitors out; it isn't encryption."),
            ok = _("Set"), check = function(pw) if #pw < 4 then return _("Use at least 4 characters.") end end, done = set }
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Web server password"),
        input = "",
        text_type = "password",
        input_hint = _("At least 4 characters"),
        description = _("The page asks for it from any browser. It's plain HTTP on your home network: it keeps casual visitors out, but it isn't encryption."),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Set"), is_enter_default = true, callback = function()
                local pw = dialog:getInputText()
                if #pw < 4 then
                    return require("webcommon").toast(_("Use at least 4 characters."), 2)
                end
                UIManager:close(dialog)
                require("webauth").set(pw)
                require("webcommon").toast(_("Password set. Browsers will ask for it."), 3)
                if touchmenu then touchmenu:updateItems() end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function WebPage:onToggleWebPage()
    if running then self:stop() else self:start() end
    return true
end

-- The Kindle going to sleep (the power button, the cover): the server
-- stops then (nothing can reach it asleep), without a message over the
-- sleep screen; waking says so.
function WebPage:onSuspend()
    pcall(require("webdiag").note, "sleep")
    pcall(require("webdiag").keepHistory)
    if running then
        logger.info("Web server: stopped as the Kindle went to sleep")
        WebPage.stoppedBySleep = true
        self:stop(nil, true)
    end
end

function WebPage:onResume()
    pcall(require("webdiag").note, "wake")
    if WebPage.stoppedBySleep then
        WebPage.stoppedBySleep = nil
        UIManager:scheduleIn(1, function()
            require("webcommon").toast(_("The web server stopped while the Kindle slept"))
        end)
    end
end

-- Wi-Fi going off: the page cannot be reached any more, so it stops.
function WebPage:onNetworkDisconnecting()
    if running then self:stop(_("Web server stopped because Wi-Fi was turned off.")) end
end

function WebPage:address()
    if not running then return "" end
    local port = running.port == 80 and "" or (":" .. running.port)
    return "http://" .. (localIp() or "?") .. port
end

function WebPage:keepsAwake()
    return running ~= nil and setting("awake", true)
end

-- Keeping the Kindle awake, shared with the other plugins that do (the web
-- server, Home Assistant's dashboard): each asks for itself, and it sleeps
-- again once none asks. KOReader's own sleep timer is held off, and on a
-- Kindle its power manager is told not to sleep too (it ignores KOReader's
-- timer), as KOReader's Keep alive does (and its flag is raised, which KOReader's
-- timer checks); told it may again when KOReader exits.
local function stayAwake(who, on)
    local reasons = PluginShare.awake_reasons or {}
    PluginShare.awake_reasons = reasons
    reasons[who] = on and true or nil
    local any = next(reasons) ~= nil
    PluginShare.pause_auto_suspend = any or nil
    if Device:isKindle() and (PluginShare.kindle_kept_awake or false) ~= any then
        PluginShare.kindle_kept_awake = any
        -- KOReader's sleep timer resets the power manager's timer (t1) every few minutes and
        -- stands aside only for its own Keep alive. Kept awake past the sleep time without this,
        -- it reschedules itself for "now" forever and KOReader freezes.
        if any then
            PluginShare.keepalive_ours = not PluginShare.keepalive
            PluginShare.keepalive = true
        elseif PluginShare.keepalive_ours then
            PluginShare.keepalive_ours = nil
            PluginShare.keepalive = false
        end
        -- The power manager's own sleep timer (t1) put back every 4 minutes, as KOReader's sleep
        -- timer does, so the cover and the power button still put it to sleep (its
        -- preventScreenSaver, used before, made it ignore them). Not while charging, as KOReader.
        -- (preventScreenSaver 0: undoes it, if an older copy of this left it on.)
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1")
        if PluginShare.kindle_t1_task then UIManager:unschedule(PluginShare.kindle_t1_task) end
        PluginShare.kindle_t1_task = nil
        if any then
            local task
            task = function()
                if PluginShare.kindle_t1_task ~= task then return end
                local p = Device.powerd
                if p and p.resetT1Timeout and not (p.isCharging and p:isCharging()) then pcall(p.resetT1Timeout, p) end
                UIManager:scheduleIn(240, task)
            end
            PluginShare.kindle_t1_task = task
            task()
        end
        require("logger").info("Kindle", any and "kept awake" or "may sleep again")
    end
end
if not Device.__stayAwakeExit then
    Device.__stayAwakeExit = true
    local exit = Device.exit
    Device.exit = function(...)
        if PluginShare.kindle_kept_awake then
            PluginShare.kindle_kept_awake = false
            os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1")
        end
        return exit(...)
    end
end

function WebPage:keepAwake()
    stayAwake("webpage", running ~= nil and setting("awake", true))
end

-- Kindles block incoming connections: a hole for the port while running.
local function firewall(port, open)
    if not Device:isKindle() then return end
    local flag = open and "-A" or "-D"
    os.execute(string.format("iptables %s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", flag, port))
    os.execute(string.format("iptables %s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", flag, port))
end

function WebPage:routes(server)
    local dir = self.path .. "/web/"
    local Auth = require("webauth")
    server.guard = function(req, res) return Auth.guard(req, res, dir) end
    Auth.routes(server, dir)
    server:route("GET", "^/$", function(req, res) res:file(dir .. "index.html", "index.html", true) end)
    server:route("GET", "^/static/([%w%._%-]+)$", function(req, res)
        res:file(dir .. req.captures[1], req.captures[1], true)
    end)
    server:route("GET", "^/favicon%.ico$", function(req, res) res:status(204):send("") end)
    require("webhome").routes(server, self)
    require("webfiles").routes(server)
    require("weblibrary").routes(server)
    require("webservers").routes(server)
    require("webdiag").routes(server)
    require("webha").routes(server)
    require("webdash").routes(server)
    require("webapps").routes(server)
    require("webbackup").routes(server, self)
    require("webmicrosoft").routes(server)
    require("webtodo").routes(server)
    require("webnotes").routes(server)
    require("webcrosswords").routes(server)
    require("webwikipedia").routes(server)
    require("websyncthing").routes(server)
    require("webssh").routes(server)
    require("webplugins").routes(server, self)
    require("websearch").routes(server)
    require("websystem").routes(server, self)
    require("webbooks").routes(server)
    require("webkoreader").routes(server)
    require("webfonts").routes(server)
    require("webai").routes(server)
    pcall(require("webfonts").emptyTrash)
    pcall(require("webfiles").emptyTrash)
end

-- ------------------------------------------------------------------ watchdog

-- While the server runs, a heartbeat every 5 s and the request being answered
-- go to small files that watchdog.sh (a separate process) checks: if
-- KOReader stops answering, it notes in crash.log where it is stuck.
local TMP = lfs.attributes("/tmp", "mode") == "directory" and "/tmp" or (DataStorage:getDataDir() .. "/cache")
local HEART, REQUEST = TMP .. "/koreader-web-heartbeat", TMP .. "/koreader-web-request"
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."

local function note(path, text)
    local f = io.open(path, "w")
    if f then
        f:write(text)
        f:close()
    end
end

local function startWatchdog()
    note(HEART, tostring(os.time()))
    note(REQUEST, "none yet")
    running.beat = function()
        if not running then return end
        note(HEART, tostring(os.time()))
        UIManager:scheduleIn(5, running.beat)
    end
    UIManager:scheduleIn(5, running.beat)
    local ok, pid = pcall(function()
        local ffi = require("ffi")
        pcall(ffi.cdef, "int getpid(void);")
        return ffi.C.getpid()
    end)
    if not ok then return end
    local log = (lfs.currentdir() or ".") .. "/crash.log"
    os.execute(string.format("sh '%s/watchdog.sh' %d '%s' '%s' '%s' >/dev/null 2>&1 &", here, pid, HEART, REQUEST, log))
end

local function stopWatchdog(r)
    if r.beat then UIManager:unschedule(r.beat) end
    os.remove(HEART)
end

--- Starts the web server if it isn't running, then `ready()` (the address shown by default).
function WebPage:start(ready)
    ready = ready or function() self:showAddress() end
    NetworkMgr:runWhenOnline(function()
        if running then return ready() end
        local port = setting("port", 8080)
        local server = Server.new{
            port = port,
            json = require("json"),
            onStart = function(method, target)
                -- A change to the files: the library's list of every file is read again.
                if method ~= "GET" and (target:find("^/api/files") or target:find("^/api/notes")) then
                    local L = package.loaded["weblibrary"]
                    if L then L.forget() end
                end
                -- (The path only: what follows "?" may hold a code.)
                note(REQUEST, os.date("%H:%M:%S ") .. method .. " " .. (target:match("^[^?]*") or ""))
            end,
            onRequest = function()
                if running then running.last = os.time() end
                note(REQUEST, os.date("%H:%M:%S ") .. "idle")
                self:keepAwake()
            end,
        }
        self:routes(server)
        local ok, err = server:start()
        if not ok then
            require("webcommon").message(T(_("Couldn't start the web server on port %1:\n%2"), port, tostring(err)))
            return
        end
        firewall(port, true)
        UIManager:insertZMQ(server)
        running = { server = server, port = port, last = os.time() }
        self:keepAwake()
        self:watchIdle()
        startWatchdog()
        logger.info("Web server: listening on", port, "at", self:address())
        UIManager:broadcastEvent(require("ui/event"):new("WebServerChanged"))
        -- While it runs: a notification that stays (with the launcher), its address a tap away.
        local PS = require("pluginshare")
        if PS.notify then
            PS.notify{ app = "webpage", key = "webpage:running", ongoing = true,
                text = T(_("On at %1. Tap for the address and QR code."), self:address()),
                open = function() self:showAddress() end }
        end
        ready()
    end)
end

--- "Open on the web page" (the apps' ⋮ menus): the web server started if
-- needed, then a QR code of the page at `fragment` ("todo?list=…", "ha",
-- "notes?nb=…") to scan with a phone. ui.webpage:openOnWeb(fragment).
function WebPage:openOnWeb(fragment)
    self:start(function()
        local url = self:address() .. "/" .. (fragment and fragment ~= "" and ("#" .. fragment) or "")
        self:showQR(url, _("Scan with your phone to open it there"))
    end)
end

--- The address as a QR code, full screen, `caption` under it (the launcher's QR
-- page). Closed: the whole screen with a full refresh (KOReader redraws only that
-- spot, and e-ink keeps a ghost of the code over the library, a book or an app).
function WebPage:showQR(url, caption)
    local PS = require("pluginshare")
    if PS.showQR then return PS.showQR{ text = url, caption = caption } end
    local QRMessage = require("ui/widget/qrmessage")
    UIManager:show(QRMessage:new{
        text = url, width = Screen:getWidth(), height = Screen:getHeight(),
        dismiss_callback = function() UIManager:setDirty(nil, "full") end,
    }, "full")
end

function WebPage:stop(message, quiet)
    if not running then return end
    local r = running
    running = nil
    if r.task then UIManager:unschedule(r.task) end
    stopWatchdog(r)
    UIManager:removeZMQ(r.server)
    r.server:stop()
    firewall(r.port, false)
    self:keepAwake()
    local PS = require("pluginshare")
    if PS.unnotify then PS.unnotify("webpage:running") end
    UIManager:broadcastEvent(require("ui/event"):new("WebServerChanged"))
    if not quiet then require("webcommon").toast(message or _("Web server stopped."), 3) end
end

function WebPage:watchIdle()
    if not running then return end
    running.task = function()
        if not running then return end
        if setting("idle_stop", true) and os.time() - running.last > 30 * 60 then
            return self:stop(_("Web server stopped after 30 minutes of inactivity."))
        end
        self:keepAwake()
        UIManager:scheduleIn(60, running.task)
    end
    UIManager:scheduleIn(60, running.task)
end

function WebPage:showAddress()
    local url = self:address()
    local dialog
    dialog = require("webcommon").buttonDialog{
        title = T(_("On a phone or computer on the same Wi-Fi, go to\n\n%1\n\nAvailable while the web server is running and the Kindle is awake."), url),
        title_align = "center",
        buttons = { {
            { text = _("QR code"), callback = function()
                UIManager:close(dialog)
                self:showQR(url, _("Scan with a phone on the same Wi-Fi to open the web page"))
            end },
            { text = _("Stop"), callback = function()
                UIManager:close(dialog)
                self:stop()
            end },
            { text = _("Close"), callback = function() UIManager:close(dialog) end },
        } },
    }
end

function WebPage:askPort(touchmenu)
    local function save(port)
        if port and port >= 1024 and port <= 65535 then
            setSetting("port", math.floor(port))
            if running then
                self:stop()
                self:start()
            end
            if touchmenu then touchmenu:updateItems() end
        end
    end
    -- The launcher's text box (the numbers' keyboard), when it's there.
    local KO = require("pluginshare").ko
    if KO and KO.askText then
        return KO.askText{ title = _("Port (1024–65535, default 8080)"), text = tostring(setting("port", 8080)), number = true,
            pen = false, check = function(v)
                local n = tonumber(v)
                if not (n and n >= 1024 and n <= 65535) then return _("Use a number from 1024 to 65535.") end
            end, done = function(v) save(tonumber(v)) end }
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Port (1024–65535, default 8080)"),
        input = tostring(setting("port", 8080)),
        input_type = "number",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local port = tonumber(dialog:getInputText())
                UIManager:close(dialog)
                if port and port >= 1024 and port <= 65535 then
                    setSetting("port", math.floor(port))
                    if running then
                        self:stop()
                        self:start()
                    end
                    if touchmenu then touchmenu:updateItems() end
                end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return WebPage
