--[[--
SSH's pages, drawn as the other apps' (sshpage's items):

  SSH          the hosts (an online dot, their address and two stats), then
               Run on several hosts, Keys, Command list, History
  a host       its line, Status (stat tiles), Run a command / Live session /
               Write with AI, Quick commands, Docker, Services, Saved
               commands, Recent, Files
  Stats        which stats show, how often it's checked, its alerts
  Quick commands   which show, in what order (and your own)
  Docker, Services, Files, History, Settings

What runs uses sshrun (Run.command: a run with its output page) or, for
sudo, a live session (UI.session); what is read quietly uses sshnet.
]]

local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local KO = require("sshko")
local M = require("sshmodel")
local Net = require("sshnet")
local S = require("sshstats")

local Screens = {}

local function UI() return require("sshui") end
local function H() return require("sshui").h end
local function Run() return require("sshrun") end

--- "just now", "5 min ago", "2 h ago", "Oct 21".
function Screens.ago(t)
    if not t then return nil end
    local d = os.time() - t
    if d < 60 then return _("just now") end
    if d < 3600 then return T(_("%1 min ago"), math.floor(d / 60)) end
    if d < 86400 then return T(_("%1 h ago"), math.floor(d / 3600)) end
    return os.date("%b %d", t)
end

local function hostOS(host) return M.hostOS(host) end

local function osLabel(host)
    if host.os and host.os ~= "auto" then return M.osName(host.os) end
    if host.detected then return M.osName(host.detected) end
    return _("System not detected yet")
end

local function authLabel(plugin, host)
    if host.auth == "key" then
        local k = host.key and M.key(plugin.store.data, host.key)
        return T(_("Key: %1"), k and k.name or "?")
    end
    if host.auth == "password" then return host.password and _("Password (saved)") or _("Password") end
    return _("Asks for the password")
end

local function docker(host)
    local v = host.last and host.last.v
    return v and v.docker or nil
end

local function wants(host, id)
    for __, s in ipairs(S.shown(host, true)) do if s == id then return true end end
    return false
end

-- ------------------------------------------------------------------ running

--- A quick command (or any): its blanks asked, asked first when it says so,
-- sudo in a live session (where sudo can ask for the password), the rest run.
function Screens.runCommand(plugin, host, cmd, opts)
    opts = opts or {}
    Screens.fillBlanks(plugin, host, cmd, function(filled)
        local function go()
            if opts.session or M.usesSudo(filled) then return UI().session(plugin, host, filled) end
            Run().command(plugin, host, filled, { full = opts.full })
        end
        if opts.ask then
            return KO.confirm{ title = T(_("%1 on %2?"), opts.name or filled, M.hostName(host)), text = filled,
                ok = opts.name or _("Run"), onOk = go }
        end
        go()
    end)
end

--- A command's blanks ({service}, {container}, {folder}…), each asked with
-- what fits it; done(command) once filled.
function Screens.fillBlanks(plugin, host, cmd, done)
    local names = S.blanks(cmd)
    if #names == 0 then return done(cmd) end
    local values = {}
    local i = 0
    local function next()
        i = i + 1
        local name = names[i]
        if not name then return done(S.fill(cmd, values)) end
        local items = {}
        local v = host and host.last and host.last.v
        local lname = name:lower()
        if v and (lname == "service" or lname == "unit") then
            for __, f in ipairs(v.failed or {}) do items[#items + 1] = f end
            for __, p in ipairs(v.pinned or {}) do items[#items + 1] = p.name end
            for __, s in ipairs(host.servicesSeen or {}) do items[#items + 1] = s end
        elseif v and v.docker and (lname == "container" or lname == "name") then
            for __, c in ipairs(v.docker.list) do items[#items + 1] = c.name end
        elseif host and (lname == "folder" or lname == "dir") and host.compose then
            items[#items + 1] = host.compose
        end
        local request = KO.request()
        if request then
            local rows, seen = {}, {}
            for __, it in ipairs(items) do
                if not seen[it] and #rows < 12 then
                    seen[it] = true
                    rows[#rows + 1] = { text = it, fn = function(box) box:setText(it) end }
                end
            end
            return request{ title = T(_("Fill in: %1"), name), subtitle = cmd, text = (lname == "folder" and host and host.compose) or "",
                typing = #rows == 0, sections = #rows > 0 and { { heading = _("ON THIS HOST"), items = rows } } or nil,
                buttons = {
                    { icon = "x", text = _("Cancel"), cancel = true },
                    { icon = "check", text = _("OK"), primary = true, needsText = true, fn = function(t)
                        values[name] = t
                        if host and lname == "folder" then
                            host.compose = t
                            plugin:saved()
                        end
                        next()
                    end },
                } }
        end
        H().ask(T(_("Fill in: %1"), name), "", function(t)
            if not t:match("%S") then return end
            values[name] = t
            next()
        end, { description = cmd, ok = _("OK") })
    end
    next()
end

-- ------------------------------------------------------------------ status

--- Reads a host's status and redraws its page; interactive (⟳): asks what
-- it needs first (Wi-Fi, a password, trusting its key).
function Screens.readStatus(plugin, host, interactive)
    local function after()
        UI().refreshHost(plugin, host)
        UI().refreshMain(plugin)
    end
    if Net.quiet(plugin, host) and not interactive then
        Net.status(plugin, host, after)
        UI().refreshHost(plugin, host)
        return
    end
    if not interactive then return end
    Run().prepare(plugin, host, function(password)
        Net.status(plugin, host, after, { password = password })
        UI().refreshHost(plugin, host)
    end)
end

--- A host's page just opened: its status read (when it's quiet to, on
-- Wi-Fi already, and asked to on opening).
function Screens.opened(plugin, host)
    if host.readOnOpen == false then return end
    if not (NetworkMgr:isWifiOn() and NetworkMgr:isConnected()) then return end
    if host.last and os.time() - host.last.at < 60 then return end
    Screens.readStatus(plugin, host, false)
end

function Screens.pingAll(plugin)
    if not (NetworkMgr:isWifiOn() and NetworkMgr:isConnected()) then return end
    Net.ping(plugin.store.data.hosts, function() UI().refreshMain(plugin) end)
end

-- ------------------------------------------------------------------ the main page

function Screens.mainButtons(plugin)
    return {
        { "search", function() Screens.history(plugin, true) end },
        { "plus", function() UI().addHost(plugin) end },
    }
end

--- The foot: how many hosts and keys, and the last run.
function Screens.mainStatus(plugin)
    local data = plugin.store.data
    local left = T(_("%1 hosts · %2 keys"), #data.hosts, #data.keys)
    local last = type(data.history) == "table" and data.history[1]
    local right
    if last then
        local h = M.host(data, last.host)
        right = T(_("Last run: %1, %2"), h and M.hostName(h) or "?", Screens.ago(last.at))
    end
    return left, right, function() Screens.history(plugin) end
end

local function groupsOf(data)
    local out, seen = {}, {}
    for __, h in ipairs(data.hosts) do
        for __, g in ipairs(h.groups or {}) do
            if not seen[g] then
                seen[g] = true
                out[#out + 1] = g
            end
        end
    end
    table.sort(out)
    return out
end
Screens.groupsOf = groupsOf

local function inGroup(h, g)
    if not g then return true end
    for __, x in ipairs(h.groups or {}) do if x == g then return true end end
    return false
end

--- A host's second line: its address, then two stats (when read), or its system and sign-in.
local function hostLine(plugin, h)
    local parts = { M.hostLabel(h) }
    local short = plugin.store.data.main_stats ~= false and h.last and S.short(h.last.v, S.shown(h), 2) or ""
    if short ~= "" then
        parts[#parts + 1] = short
    else
        parts[#parts + 1] = osLabel(h)
        parts[#parts + 1] = authLabel(plugin, h)
    end
    if h.paused then parts[#parts + 1] = _("Checks paused") end
    return table.concat(parts, " · ")
end

function Screens.hostHold(plugin, h, i)
    local data = plugin.store.data
    local items = {
        { text = _("Run a command"), fn = function() UI().runDialog(plugin, h, "", function(cmd) Run().command(plugin, h, cmd) end) end },
        { text = _("Live session"), fn = function() UI().session(plugin, h) end },
    }
    if h.mac or (h.last and h.last.v and h.last.v.mac) then
        items[#items + 1] = { text = _("Wake"), fn = function() Screens.wake(plugin, h) end }
    end
    items[#items + 1] = { text = _("Edit host"), fn = function() UI().editHost(plugin, h) end }
    items[#items + 1] = { text = _("Copy host"), fn = function()
        local r = H().saveHost(plugin, { name = T(_("%1 copy"), M.hostName(h)), address = h.address,
            user = h.user, port = h.port, auth = h.auth, key = h.key, password = h.password })
        if not r then return end
        local copy = M.host(data, r.id)
        for __, c in ipairs(h.commands) do
            copy.commands[#copy.commands + 1] = { id = M.newId(data, "c"), name = c.name, cmd = c.cmd, os = c.os }
        end
        copy.groups = h.groups
        plugin:saved()
        UI().refreshMain(plugin)
        UI().editHost(plugin, copy)
    end }
    items[#items + 1] = { text = _("Copy address"), fn = function() H().copyText(M.hostLabel(h)) end }
    items[#items + 1] = { text = _("Move up"), enabled = i > 1, fn = function()
        M.move(data.hosts, i, -1)
        plugin:saved()
        UI().refreshMain(plugin)
    end }
    items[#items + 1] = { text = _("Move down"), enabled = i < #data.hosts, fn = function()
        M.move(data.hosts, i, 1)
        plugin:saved()
        UI().refreshMain(plugin)
    end }
    items[#items + 1] = { text = _("Delete host"), fn = function()
        H().deleteWithUndo(plugin, M.hostName(h), function() return H().takeOut(data.hosts, h) end,
            function() UI().refreshMain(plugin) end)
    end }
    KO.list(M.hostName(h), items)
end

function Screens.mainItems(plugin)
    local data = plugin.store.data
    local t = {}
    local groups = groupsOf(data)
    if #groups > 0 then
        local chips = { { text = _("All"), on = UI().group == nil, fn = function()
            UI().group = nil
            UI().refreshMain(plugin)
        end } }
        for __, g in ipairs(groups) do
            chips[#chips + 1] = { text = g, on = UI().group == g, fn = function()
                UI().group = g
                UI().refreshMain(plugin)
            end }
        end
        t[#t + 1] = { chips = chips }
    end
    local shown = {}
    for i, h in ipairs(data.hosts) do
        if inGroup(h, UI().group) then shown[#shown + 1] = { h = h, i = i } end
    end
    t[#t + 1] = { band = UI().group and UI().group:upper() or _("HOSTS"), right = tostring(#shown) }
    if #data.hosts == 0 then
        t[#t + 1] = { message = _("No hosts yet. Add your PC, NAS or Raspberry Pi with +.") }
    end
    for __, x in ipairs(shown) do
        local h = x.h
        local o = Net.online[h.id]
        t[#t + 1] = { text = M.hostName(h), sub = hostLine(plugin, h), icon = "square-terminal",
            dot = o and (o.ok and "on" or "off") or nil, chevron = true,
            callback = function() UI().host(plugin, h) end,
            hold_callback = function() Screens.hostHold(plugin, h, x.i) end }
    end
    t[#t + 1] = { band = _("MORE") }
    t[#t + 1] = { text = _("Run on several hosts"), sub = _("One command on the hosts you tick"), icon = "layers",
        chevron = true, callback = function() UI().several(plugin) end }
    t[#t + 1] = { text = _("Keys"), sub = T(_("%1 keys"), #data.keys), icon = "key-round", chevron = true,
        callback = function() UI().keys(plugin) end }
    t[#t + 1] = { text = _("Command list"), sub = T(_("%1 commands for any host"), #data.commands), icon = "list",
        chevron = true, callback = function() UI().commandList(plugin) end }
    t[#t + 1] = { text = _("History"), sub = _("Everything you ran, on every host"), icon = "history", chevron = true,
        callback = function() Screens.history(plugin) end }
    return t
end

-- ------------------------------------------------------------------ a host's page

function Screens.hostButtons(plugin, host)
    return {
        { "plus", function()
            H().editCommand(nil, function(__, name, cmd, os_id)
                table.insert(host.commands, { id = M.newId(plugin.store.data, "c"), name = name, cmd = cmd, os = os_id })
                plugin:saved()
                UI().refreshHost(plugin, host)
            end)
        end },
        { "pencil", function() UI().editHost(plugin, host) end },
    }
end

function Screens.wake(plugin, host)
    local ok, why = Net.wake(host)
    if not ok then return KO.message(why) end
    KO.toast(T(_("Wake sent to %1. It may take a minute to start."), M.hostName(host)))
    UIManager:scheduleIn(30, function() Screens.pingAll(plugin) end)
end

local function statusRight(plugin, host)
    if Net.busy[host.id] then return _("Reading…") end
    if host.last then return T(_("Updated %1"), Screens.ago(host.last.at)) end
    return nil
end

local function statusNote(plugin, host)
    local ok, why = Net.quiet(plugin, host)
    if host.lastError and not Net.busy[host.id] then
        return T(_("Couldn't read it (%1). Tap ⟳ to try again."), host.lastError)
    end
    if not ok and why == "ask" then return _("It asks for a password: tap ⟳ to read its status.") end
    if not ok and why == "untrusted" then return _("Its host key isn't trusted yet: tap ⟳ to connect once.") end
    if not ok and why == "nokey" then return _("It has no key: edit the host and choose one.") end
    return _("Tap ⟳ to read its status.")
end

local function containerMenu(plugin, host, c)
    local d = docker(host)
    local sudo = d and d.denied
    local function act(action)
        local cmd = S.dockerCommand(c.name, action, sudo)
        if sudo then return UI().session(plugin, host, cmd) end
        Net.run(plugin, host, cmd, function(out, rc, why)
            if not out then return KO.message(tostring(why)) end
            KO.toast(rc == 0 and T(_("%1: done."), c.name) or (out ~= "" and out or T(_("Exit status %1"), rc)))
            Screens.readStatus(plugin, host, false)
        end)
    end
    local items = {
        { text = _("Start"), enabled = c.state ~= "running", fn = function() act("start") end },
        { text = _("Restart"), fn = function() act("restart") end },
        { text = _("Stop"), enabled = c.state == "running", fn = function() act("stop") end },
        { text = _("Logs (last 100 lines)"), fn = function() Run().command(plugin, host, S.dockerCommand(c.name, "logs", sudo)) end },
    }
    if require("sshai").available() then
        items[#items + 1] = { text = _("Explain with AI"), fn = function()
            local cmd = S.dockerCommand(c.name, "logs", sudo)
            Net.run(plugin, host, cmd, function(out)
                if not out then return KO.message(_("Couldn't read its logs.")) end
                require("sshai").output(plugin, "explain", { host = host, cmd = cmd, output = out })
            end)
        end }
    end
    items[#items + 1] = { text = _("Live session in it"), fn = function()
        UI().session(plugin, host, S.dockerCommand(c.name, "shell", sudo))
    end }
    KO.list(c.name, items)
end

local function containerRow(plugin, host, c)
    return { text = c.name, sub = (c.status ~= "" and c.status or c.state) .. " · " .. (c.image or ""), icon = "box",
        right = c.state == "running" and _("Running") or _("Stopped"),
        callback = function() containerMenu(plugin, host, c) end,
        hold_callback = function() containerMenu(plugin, host, c) end }
end

-- ------------------------------------------------------------------ TrueNAS, Proxmox, ReadyNAS

local function vals(host) return host.last and host.last.v or nil end

-- "Daily at 03:00" for a cron line "0 3 * * *"; else the line as it is.
local function cronText(c)
    local m, h, rest = tostring(c or ""):match("^(%d+) (%d+) (.*)$")
    if m and rest == "* * *" then return T(_("Daily at %1"), string.format("%02d:%02d", tonumber(h), tonumber(m))) end
    return c ~= "" and T(_("Schedule: %1"), c) or ""
end

local function upText(state)
    local st = tostring(state or ""):lower()
    if st == "running" then return _("Running") end
    if st == "stopped" or st == "stop" then return _("Stopped") end
    return st ~= "" and (st:sub(1, 1):upper() .. st:sub(2)) or "?"
end

local function appMenu(plugin, host, a)
    local up = tostring(a.state):lower() == "running"
    KO.list(a.name, {
        { text = _("Start"), enabled = not up, fn = function() Screens.runCommand(plugin, host, S.truenasApp(a.name, "start")) end },
        { text = _("Stop"), enabled = up, fn = function() Screens.runCommand(plugin, host, S.truenasApp(a.name, "stop"), { ask = true, name = T(_("Stop %1"), a.name) }) end },
        { text = _("Update"), enabled = a.upgrade == true, fn = function()
            Screens.runCommand(plugin, host, S.truenasApp(a.name, "upgrade"), { ask = true, name = T(_("Update %1"), a.name) })
        end },
        -- (a newer image of the same version: redeploying pulls it)
        { text = _("Get the newer image"), enabled = a.images == true and not a.upgrade, fn = function()
            Screens.runCommand(plugin, host, S.truenasApp(a.name, "redeploy"), { ask = true, name = T(_("Redeploy %1"), a.name) })
        end },
        { text = _("Redeploy"), fn = function() Screens.runCommand(plugin, host, S.truenasApp(a.name, "redeploy"), { ask = true, name = T(_("Redeploy %1"), a.name) }) end },
        { text = _("Open a shell"), enabled = up, fn = function() UI().session(plugin, host, S.truenasShell("app", a.name)) end },
        { text = _("Logs"), fn = function() Screens.runCommand(plugin, host, S.truenasAppLogs(a.name)) end },
    })
end

local function tnGuestMenu(plugin, host, g)
    local up = g.state == "running"
    local function go(action, ask)
        Screens.runCommand(plugin, host, S.truenasGuest(g.kind, g.id, action), { ask = ask, name = T("%1: %2", g.name, action) })
    end
    local items = {
        { text = _("Start"), enabled = not up, fn = function() go("start") end },
        { text = _("Stop"), enabled = up, fn = function() go("stop", true) end },
        { text = _("Restart"), enabled = up, fn = function() go("restart", true) end },
    }
    if g.kind == "ct" then
        items[#items + 1] = { text = _("Open a shell"), enabled = up, fn = function() UI().session(plugin, host, S.truenasShell("ct", g.id)) end }
    end
    KO.list(g.name, items)
end

local function tnGuestRow(plugin, host, g)
    local sub = { g.kind == "ct" and _("Container") or _("VM") }
    if g.cpus then sub[#sub + 1] = g.cpus == 1 and _("1 CPU") or T(_("%1 CPUs"), g.cpus) end
    if g.memory then sub[#sub + 1] = T(_("RAM %1"), S.size(g.memory * 1024)) end
    return { text = g.name, sub = table.concat(sub, " · "), icon = g.kind == "ct" and "box" or "monitor", right = upText(g.state),
        callback = function() tnGuestMenu(plugin, host, g) end, hold_callback = function() tnGuestMenu(plugin, host, g) end }
end

local function alertRow(a)
    local lvl = tostring(a.level):upper()
    local bad = lvl == "CRITICAL" or lvl == "ERROR" or lvl == "ALERT" or lvl == "EMERGENCY" or lvl == "WARNING"
    return { text = a.text, icon = bad and "triangle-alert" or "info", right = lvl:sub(1, 1) .. lvl:sub(2):lower() }
end

local function appRow(plugin, host, a)
    local sub = a.version ~= "" and a.version or nil
    if a.upgrade then sub = (sub and (sub .. " · ") or "") .. _("Update available")
    elseif a.images then sub = (sub and (sub .. " · ") or "") .. _("Newer image available") end
    return { text = a.name, sub = sub, icon = a.upgrade and "circle-arrow-up" or "package", right = upText(a.state),
        callback = function() appMenu(plugin, host, a) end, hold_callback = function() appMenu(plugin, host, a) end }
end

local function shareRow(x)
    return { text = x.name, sub = x.path, icon = "folder", right = x.on and _("On") or _("Off") }
end

local function rsyncRow(plugin, host, t)
    local sub = cronText(t.schedule)
    if t.last ~= "" then sub = sub .. " · " .. T(_("Last: %1"), upText(t.last)) end
    return { text = t.path .. (t.remote ~= "" and (" → " .. t.remote) or ""), sub = sub, icon = "arrow-right-left",
        right = t.on and _("On") or _("Off"),
        callback = function()
            KO.list(t.path, {
                { text = _("Run now"), fn = function() Screens.runCommand(plugin, host, S.truenasRsync(t.id), { ask = true, name = _("Run this rsync task now") }) end },
            })
        end }
end

local function guestMenu(plugin, host, g)
    local up = g.status == "running"
    local label = g.name ~= "" and g.name or g.id
    local function go(action, ask)
        Screens.runCommand(plugin, host, S.proxmoxGuest(g.kind, g.id, action), { ask = ask, name = T("%1: %2", label, action) })
    end
    KO.list(T("%1 %2", g.id, label), {
        { text = _("Start"), enabled = not up, fn = function() go("start") end },
        { text = _("Shut down"), enabled = up, fn = function() go("shutdown", true) end },
        { text = _("Reboot"), enabled = up, fn = function() go("reboot", true) end },
        { text = _("Stop (at once)"), enabled = up, fn = function() go("stop", true) end },
        { text = _("Back up now"), fn = function()
            Screens.runCommand(plugin, host, S.proxmoxBackup(g.id), { ask = true, name = T(_("Back up %1 now"), label) })
        end },
        { text = g.kind == "lxc" and _("Open a shell") or _("Open its console"), enabled = up, fn = function()
            if g.kind == "lxc" then return UI().session(plugin, host, S.proxmoxShell(g.kind, g.id)) end
            KO.confirm{ title = T(_("Console of %1"), label), ok = _("Open"),
                text = _("A VM's console needs a serial port set up in the VM (serial0 in its hardware, and a console on ttyS0 inside). Ctrl+O leaves it."),
                onOk = function() UI().session(plugin, host, S.proxmoxShell(g.kind, g.id)) end }
        end },
        { text = _("Run a command in it"), enabled = up, fn = function()
            UI().runDialogText(plugin, host, T(_("Run in %1"), label), "", function(cmd)
                Run().command(plugin, host, S.proxmoxExec(g.kind, g.id, cmd))
            end)
        end },
        { text = _("Memory"), fn = function()
            UI().ask(T(_("Memory of %1 (MB)"), label), g.maxmem and tostring(math.floor(g.maxmem / 1024 + 0.5)) or "", function(mb)
                local cmd = S.proxmoxSet(g.kind, g.id, mb, nil)
                if not cmd then return KO.toast(_("Type the memory in MB, such as 2048."), 3) end
                Screens.runCommand(plugin, host, cmd, { ask = true, name = T(_("Set %1's memory to %2 MB"), label, mb) })
            end, { number = true, ok = _("Set") })
        end },
        { text = _("CPU cores"), fn = function()
            UI().ask(T(_("CPU cores of %1"), label), g.cpus and tostring(g.cpus) or "", function(n)
                local cmd = S.proxmoxSet(g.kind, g.id, nil, n)
                if not cmd then return KO.toast(_("Type a number of cores, such as 2."), 3) end
                Screens.runCommand(plugin, host, cmd, { ask = true, name = T(_("Set %1's CPU cores to %2"), label, n) })
            end, { number = true, ok = _("Set") })
        end },
        { text = _("Status"), fn = function() Run().command(plugin, host, S.proxmoxGuest(g.kind, g.id, "status")) end },
        { text = _("Its settings"), fn = function() Run().command(plugin, host, S.proxmoxGuest(g.kind, g.id, "config")) end },
    })
end

local function guestRow(plugin, host, g)
    local sub = { g.kind == "lxc" and _("Container") or _("VM") }
    if g.status == "running" and g.cpu then sub[#sub + 1] = T(_("CPU %1 %"), g.cpu) .. (g.cpus and (" " .. T(_("of %1"), g.cpus)) or "") end
    if g.maxmem and g.maxmem > 0 then
        sub[#sub + 1] = g.status == "running" and g.mem and T(_("RAM %1 / %2"), S.size(g.mem), S.size(g.maxmem)) or T(_("RAM %1"), S.size(g.maxmem))
    end
    if g.maxdisk and g.maxdisk > 0 then
        sub[#sub + 1] = (g.disk and g.disk > 0) and T(_("Disk %1 / %2"), S.size(g.disk), S.size(g.maxdisk)) or T(_("Disk %1"), S.size(g.maxdisk))
    end
    return { text = T("%1 %2", g.id, g.name), sub = table.concat(sub, " · "),
        icon = g.kind == "lxc" and "box" or "monitor", right = upText(g.status),
        callback = function() guestMenu(plugin, host, g) end, hold_callback = function() guestMenu(plugin, host, g) end }
end

local function storageRow(x)
    local pct = x.total > 0 and math.floor(x.used * 100 / x.total + 0.5) or nil
    return { text = x.name, icon = "hard-drive", right = not x.on and _("Inactive") or (pct and (pct .. " %") or ""),
        sub = x.kind .. (x.total > 0 and (" · " .. S.size(x.used) .. " / " .. S.size(x.total)) or "") }
end

local function jobRow(j)
    return { text = j.which == "all" and _("All guests") or T(_("Guests %1"), j.which), icon = "clock",
        sub = j.schedule .. (j.storage ~= "" and (" · " .. j.storage) or ""), right = j.on and _("On") or _("Off") }
end

local function backupRow(b)
    local ok = b.status == "OK"
    return { text = b.at and os.date("%b %d, %H:%M", b.at) or "?", sub = b.guest ~= "" and T(_("Guest %1"), b.guest) or _("All guests"),
        icon = ok and "circle-check" or "triangle-alert", right = ok and _("OK") or b.status }
end

-- A list's first few on the host's page, then "N more" to its page.
local function some(t, list, row, open, n)
    n = n or 3
    for i = 1, math.min(n, #list) do t[#t + 1] = row(list[i]) end
    if #list > n then t[#t + 1] = { text = T(_("%1 more"), #list - n), icon = "chevron-down", callback = open } end
    if #list == 0 then t[#t + 1] = { line = _("None.") } end
end

local function serviceMenu(plugin, host, name, state)
    local pinned = false
    for __, s in ipairs(host.services or {}) do if s == name then pinned = true end end
    KO.list(name, {
        { text = _("Start"), enabled = state ~= "active", fn = function() Screens.runCommand(plugin, host, S.serviceCommand(name, "start")) end },
        { text = _("Restart"), fn = function() Screens.runCommand(plugin, host, S.serviceCommand(name, "restart")) end },
        { text = _("Stop"), enabled = state == "active", fn = function() Screens.runCommand(plugin, host, S.serviceCommand(name, "stop")) end },
        { text = _("Status"), fn = function() Run().command(plugin, host, S.serviceCommand(name, "status")) end },
        { text = _("Logs (last 100 lines)"), fn = function() Run().command(plugin, host, S.serviceCommand(name, "logs")) end },
        { text = pinned and _("Take off the host's page") or _("Show on the host's page"), fn = function()
            host.services = host.services or {}
            if pinned then
                for i, s in ipairs(host.services) do if s == name then table.remove(host.services, i) break end end
            else
                table.insert(host.services, name)
            end
            plugin:saved()
            Screens.readStatus(plugin, host, false)
            UI().refreshHost(plugin, host)
        end },
    })
end
Screens.serviceMenu = serviceMenu

function Screens.hostItems(plugin, host)
    local t = {}
    local v = host.last and host.last.v
    local known = plugin.store:isKnown(host.address)
    t[#t + 1] = { line = T("%1 · %2 · %3 · %4", M.hostLabel(host), osLabel(host), authLabel(plugin, host),
        known and _("Host key trusted") or _("Host key not trusted yet")) }
    -- (off now, and it can be woken)
    local o = Net.online[host.id]
    if o and not o.ok and (host.mac or (v and v.mac)) then
        t[#t + 1] = { tiles = { { icon = "power", text = _("Wake"), sub = _("It doesn't answer: send Wake on LAN"), primary = true,
            fn = function() Screens.wake(plugin, host) end } }, cols = 1 }
    end
    -- Status
    t[#t + 1] = { band = _("STATUS"), right = statusRight(plugin, host),
        callback = function() Screens.stats(plugin, host) end }
    -- (its checks paused: it didn't answer several in a row)
    if host.paused and not Net.busy[host.id] then
        t[#t + 1] = { note = T(_("Its checks are paused: it didn't answer %1 in a row. Tap ⟳ (or open it when it's on) and they start again."), host.fails or Net.PAUSE_AFTER) }
    end
    if v then
        local tiles = {}
        for __, id in ipairs(S.shown(host)) do
            local tile = S.tileOf(id, v, host.sensors)
            -- (one on by default that this host can't give, such as a PC's
            -- temperature: left out; one you turned on shows "Not available")
            if tile and tile.dim and not (host.stats and host.stats[id]) and not id:match("^cs_") then tile = nil end
            if tile then
                tile.hold = function() Screens.stats(plugin, host) end
                if id == "docker" and v.docker and v.docker.ok then tile.fn = function() Screens.docker(plugin, host) end end
                if (id == "failed" or id == "services") and v.hasSystemd then tile.fn = function() Screens.services(plugin, host) end end
                tiles[#tiles + 1] = tile
            end
        end
        if #tiles > 0 then t[#t + 1] = { stats = tiles } end
    else
        t[#t + 1] = { note = statusNote(plugin, host) }
    end
    -- what to do
    local tiles = {
        { icon = "terminal", text = _("Run a command"), sub = _("Type or write it"), primary = true,
            fn = function() UI().runDialog(plugin, host, "", function(cmd) Run().command(plugin, host, cmd) end) end },
        { icon = "square-terminal", text = _("Live session"), sub = _("A shell on it"), fn = function() UI().session(plugin, host) end },
    }
    if require("sshai").available() then
        tiles[#tiles + 1] = { icon = "sparkles", text = _("Write with AI"), sub = _("Say what you want"),
            fn = function() require("sshai").write(plugin, { host = host }) end,
            hold = function()
                local ai = require("pluginshare").ai
                if ai and ai.quickPick then ai.quickPick("ssh_write") end
            end }
    end
    t[#t + 1] = { tiles = tiles }
    -- Quick commands
    local d = docker(host)
    local quick = S.quickShown(host, d and d.ok and wants(host, "docker"))
    if #quick > 0 then
        t[#t + 1] = { band = _("QUICK COMMANDS"), right = osLabel(host), callback = function() Screens.quickPage(plugin, host) end }
        local q = {}
        for __, x in ipairs(quick) do
            q[#q + 1] = { icon = x.icon, text = x.name, sub = x.sub,
                fn = function() Screens.runCommand(plugin, host, x.cmd, { ask = x.ask, name = x.name, session = x.session }) end,
                hold = function() Screens.quickHold(plugin, host, x) end }
        end
        t[#t + 1] = { quick = q }
    end
    -- Docker
    if d and wants(host, "docker") then
        t[#t + 1] = { band = _("DOCKER"), right = d.denied and _("needs sudo") or T(_("%1 containers"), #d.list),
            callback = function() Screens.docker(plugin, host) end }
        if d.denied then
            t[#t + 1] = { note = _("Docker needs sudo here: its commands open in a live session. Or add your user to the docker group.") }
        else
            -- stopped ones first (they're the ones to look at)
            local list = {}
            for __, c in ipairs(d.list) do if c.state ~= "running" then list[#list + 1] = c end end
            for __, c in ipairs(d.list) do if c.state == "running" then list[#list + 1] = c end end
            for i = 1, math.min(3, #list) do t[#t + 1] = containerRow(plugin, host, list[i]) end
            if #list > 3 then
                t[#t + 1] = { text = T(_("%1 more"), #list - 3), icon = "chevron-down", callback = function() Screens.docker(plugin, host) end }
            end
        end
    end
    -- TrueNAS: apps, SMB shares, rsync tasks
    local tn = v and v.truenas
    if tn and wants(host, "truenas") then
        local open = function() Screens.truenas(plugin, host) end
        if tn.denied then
            t[#t + 1] = { band = _("TRUENAS"), right = _("needs sudo"), callback = open }
            t[#t + 1] = { note = _("TrueNAS's apps, shares and rsync tasks need sudo without a password here (or sign in as root), so they can be read.") }
        else
            if tn.alerts and #tn.alerts > 0 then
                t[#t + 1] = { band = _("ALERTS"), right = tostring(#tn.alerts), callback = open }
                some(t, tn.alerts, alertRow, open, 2)
            end
            t[#t + 1] = { band = _("APPS"), right = T(_("%1 of %2 running"), S.upCount(tn.apps), #tn.apps) .. ((tn.updates or 0) > 0 and (" · " .. (tn.updates == 1 and _("1 update") or T(_("%1 updates"), tn.updates))) or ""), callback = open }
            some(t, tn.apps, function(a) return appRow(plugin, host, a) end, open)
            if tn.guests and #tn.guests > 0 then
                t[#t + 1] = { band = _("VMS AND CONTAINERS"), right = T(_("%1 of %2 running"), S.upCount(tn.guests), #tn.guests), callback = open }
                some(t, tn.guests, function(g) return tnGuestRow(plugin, host, g) end, open)
            end
            t[#t + 1] = { band = _("SMB SHARES"), right = tostring(#tn.shares), callback = open }
            some(t, tn.shares, shareRow, open)
            t[#t + 1] = { band = _("RSYNC TASKS"), right = tostring(#tn.rsync), callback = open }
            some(t, tn.rsync, function(x) return rsyncRow(plugin, host, x) end, open)
        end
    end
    -- Proxmox: VMs and containers, backups
    local pv = v and v.proxmox
    if pv and wants(host, "proxmox") then
        local open = function() Screens.proxmox(plugin, host) end
        if pv.denied then
            t[#t + 1] = { band = _("PROXMOX"), right = _("needs root"), callback = open }
            t[#t + 1] = { note = _("Proxmox's VMs, containers and backups are read as root: sign in as root, or allow sudo without a password.") }
        else
            t[#t + 1] = { band = _("VMS AND CONTAINERS"), right = T(_("%1 of %2 running"), S.upCount(pv.guests), #pv.guests), callback = open }
            some(t, pv.guests, function(g) return guestRow(plugin, host, g) end, open, 4)
            t[#t + 1] = { band = _("STORAGE"), right = tostring(#pv.storage), callback = open }
            some(t, pv.storage, storageRow, open, 4)
            t[#t + 1] = { band = _("BACKUPS"), right = #pv.jobs == 1 and _("1 job") or T(_("%1 jobs"), #pv.jobs), callback = open }
            some(t, pv.backups, backupRow, open, 2)
        end
    end
    -- ReadyNAS: its SMB shares
    if v and v.shares and wants(host, "shares") then
        local open = function() Screens.shares(plugin, host) end
        t[#t + 1] = { band = _("SMB SHARES"), right = tostring(#v.shares), callback = open }
        some(t, v.shares, shareRow, open)
    end
    -- Pools and disks, snapshots, Proxmox's node, updates, Raspberry Pi, pfSense, the printer
    if v then Screens.moreItems(plugin, host, v, t, false) end
    -- Services (failed ones and the ones you picked)
    if v and v.hasSystemd and wants(host, "services") then
        t[#t + 1] = { band = _("SERVICES"), right = v.running and T(_("%1 running"), v.running) or nil,
            callback = function() Screens.services(plugin, host) end }
        for __, f in ipairs(v.failed) do
            t[#t + 1] = { text = f, sub = _("Failed"), icon = "triangle-alert", right = _("Failed"),
                callback = function() serviceMenu(plugin, host, f, "failed") end }
        end
        for __, p in ipairs(v.pinned) do
            t[#t + 1] = { text = p.name, icon = "server", right = p.state == "active" and _("Running") or p.state,
                callback = function() serviceMenu(plugin, host, p.name, p.state) end }
        end
        t[#t + 1] = { text = _("All services"), icon = "list", chevron = true, callback = function() Screens.services(plugin, host) end }
    end
    -- Saved commands
    t[#t + 1] = { band = _("SAVED COMMANDS"), right = tostring(#host.commands) }
    for i, c in ipairs(host.commands) do
        t[#t + 1] = { text = M.commandName(c), sub = c.cmd, mono = true, icon = "play",
            callback = function() Run().command(plugin, host, c.cmd) end,
            hold_callback = function()
                H().commandActions(plugin, host.commands, i, function() UI().refreshHost(plugin, host) end, { {
                    { text = _("Run"), callback = function() Run().command(plugin, host, c.cmd) end },
                    { text = _("Edit and run"), callback = function()
                        UI().runDialog(plugin, host, c.cmd, function(cmd) Run().command(plugin, host, cmd) end)
                    end },
                } })
            end }
    end
    if #host.commands == 0 then
        t[#t + 1] = { text = _("Add saved command"), icon = "plus", callback = Screens.hostButtons(plugin, host)[1][2] }
    end
    -- Recent
    if #host.recent > 0 then
        t[#t + 1] = { band = _("RECENT"), right = tostring(#host.recent), callback = function() Screens.recent(plugin, host) end }
        local times = {}
        for __, r in ipairs(type(plugin.store.data.history) == "table" and plugin.store.data.history or {}) do
            if r.host == host.id and not times[r.cmd] then times[r.cmd] = r.at end
        end
        for i = 1, math.min(3, #host.recent) do
            local r = host.recent[i]
            t[#t + 1] = { text = r, monoText = not times[r], sub = times[r] and Screens.ago(times[r]) or nil, icon = "history",
                callback = function() Run().command(plugin, host, r) end,
                hold_callback = function() Screens.recent(plugin, host) end }
        end
        if #host.recent > 3 then
            t[#t + 1] = { text = _("All recent commands"), icon = "list", chevron = true, callback = function() Screens.recent(plugin, host) end }
        end
    end
    -- Files
    t[#t + 1] = { band = _("MORE") }
    t[#t + 1] = { text = _("Files"), sub = _("Browse its folders, read a file, copy one to the Kindle"), icon = "folder",
        chevron = true, callback = function() Screens.files(plugin, host) end }
    t[#t + 1] = { text = _("Stats and alerts"), sub = _("Which stats show, how often it's checked"), icon = "activity",
        chevron = true, callback = function() Screens.stats(plugin, host) end }
    return t
end

-- ------------------------------------------------------------------ recent

function Screens.recent(plugin, host)
    local m
    local function items()
        local t = {}
        for i, r in ipairs(host.recent) do
            t[#t + 1] = { text = r, monoText = true, icon = "history", callback = function()
                UIManager:close(m)
                Run().command(plugin, host, r)
            end, hold_callback = function()
                KO.list(r, {
                    { text = _("Run"), fn = function() Run().command(plugin, host, r) end },
                    { text = _("Edit and run"), fn = function()
                        UI().runDialog(plugin, host, r, function(cmd) Run().command(plugin, host, cmd) end)
                    end },
                    { text = _("Save as command"), fn = function()
                        H().editCommand({ name = "", cmd = r }, function(__, name, cmd, os_id)
                            table.insert(host.commands, { id = M.newId(plugin.store.data, "c"), name = name, cmd = cmd, os = os_id })
                            plugin:saved()
                            UI().refreshHost(plugin, host)
                        end, false, _("Save as command"))
                    end },
                    { text = _("Copy text"), fn = function() H().copyText(r) end },
                    { text = _("Remove from recent"), fn = function()
                        table.remove(host.recent, i)
                        plugin:saved()
                        if #host.recent == 0 then UIManager:close(m) else H().refresh(m, items()) end
                        UI().refreshHost(plugin, host)
                    end },
                })
            end }
        end
        return t
    end
    m = H().list(_("Recent commands"), items(), M.hostName(host))
end

-- ------------------------------------------------------------------ Stats

local function pickNumber(title, current, options, done)
    local opts = {}
    for __, o in ipairs(options) do opts[#opts + 1] = { label = o[2], value = o[1] } end
    KO.choose(title, opts, current, done)
end

local EVERY = { { 0, _("Off") }, { 5, _("Every 5 min") }, { 15, _("Every 15 min") }, { 30, _("Every 30 min") },
    { 60, _("Every hour") }, { 180, _("Every 3 hours") } }
local function everyName(n)
    for __, e in ipairs(EVERY) do if e[1] == n then return e[2] end end
    return T(_("Every %1 min"), n)
end
Screens.EVERY, Screens.everyName = EVERY, everyName

--- A host's stats: which show, how often it's checked, its alerts.
function Screens.stats(plugin, host)
    local m
    local function save()
        plugin:saved()
        H().refresh(m, Screens.statsItems(plugin, host, save))
        UI().refreshHost(plugin, host)
        UI().refreshMain(plugin)
    end
    m = H().list(_("Stats and alerts"), Screens.statsItems(plugin, host, save), M.hostName(host))
end

function Screens.statsItems(plugin, host, save)
    local t = {}
    local shown = {}
    for __, id in ipairs(S.shown(host, true)) do shown[id] = true end
    local os_id = hostOS(host)
    t[#t + 1] = { band = _("SHOWN"), right = osLabel(host) }
    for __, st in ipairs(S.STATS) do
        if S.fits(st, os_id) then
            t[#t + 1] = { toggle = shown[st.id] == true, text = _(st.name), sub = st.sub and _(st.sub), icon = st.icon, callback = function()
                host.stats = host.stats or {}
                host.stats[st.id] = not shown[st.id]
                save()
                if not shown[st.id] then Screens.readStatus(plugin, host, false) end
            end }
        end
    end
    -- custom sensors: a command of yours and what it gives
    t[#t + 1] = { band = _("CUSTOM SENSORS"), right = S.family(os_id) == "windows" and _("not on Windows") or nil }
    for i, cs in ipairs(host.sensors or {}) do
        local id = "cs_" .. cs.id
        local kindName = ""
        for __, k in ipairs(S.SENSOR_KINDS) do if k.id == cs.kind then kindName = _(k.name) end end
        t[#t + 1] = { toggle = shown[id] == true, text = (cs.name or "") ~= "" and cs.name or cs.cmd,
            sub = T("%1 · %2", cs.cmd, kindName), icon = cs.icon or "gauge",
            callback = function()
                host.stats = host.stats or {}
                host.stats[id] = not shown[id]
                save()
            end,
            hold_callback = function()
                KO.list((cs.name or "") ~= "" and cs.name or cs.cmd, {
                    { text = _("Edit"), fn = function() Screens.editSensor(plugin, host, cs, save) end },
                    { text = _("Delete"), fn = function()
                        table.remove(host.sensors, i)
                        host.alerts[id] = nil
                        save()
                    end },
                })
            end }
    end
    t[#t + 1] = { text = _("Add a custom sensor"), sub = _("A command of yours, shown as a number, a percent, text or OK"),
        icon = "plus", callback = function() Screens.editSensor(plugin, host, nil, save) end }
    t[#t + 1] = { band = _("CHECKS") }
    local all = plugin.store.data.check_every
    if all == nil then all = 15 end
    t[#t + 1] = { setting = true, text = _("Check it"),
        value = host.check == nil and T(_("Like every host (%1)"), everyName(all):lower()) or everyName(host.check),
        hint = _("While the Kindle is awake and on Wi-Fi"), callback = function()
            local opts = { { -1, T(_("Like every host (%1)"), everyName(all):lower()) } }
            for __, e in ipairs(EVERY) do opts[#opts + 1] = e end
            pickNumber(_("Check it"), host.check == nil and -1 or host.check, opts, function(n)
                host.check = n >= 0 and n or nil
                save()
            end)
        end }
    t[#t + 1] = { toggle = host.readOnOpen ~= false, text = _("Read when its page opens"), sub = _("Otherwise only with ⟳ and the checks"),
        callback = function()
            host.readOnOpen = host.readOnOpen == false and true or false
            save()
        end }
    t[#t + 1] = { band = _("ALERTS"), right = _("a notification") }
    host.alerts = host.alerts or {}
    for __, a in ipairs(S.ALERTS) do
        local on = host.alerts[a.id]
        if a.yesno then
            t[#t + 1] = { toggle = on == true, text = _(a.name), callback = function()
                host.alerts[a.id] = not on or nil
                save()
            end }
        else
            t[#t + 1] = { setting = true, text = _(a.name), value = on and T(_("Over %1 %2"), on, a.unit) or _("Off"), callback = function()
                local opts = { { 0, _("Off") } }
                local steps = a.unit == "°C" and { 50, 60, 65, 70, 75, 80, 85 } or { 50, 70, 80, 85, 90, 95 }
                for __, n in ipairs(steps) do opts[#opts + 1] = { n, T(_("Over %1 %2"), n, a.unit) } end
                pickNumber(_(a.name), on or 0, opts, function(n)
                    host.alerts[a.id] = n > 0 and n or nil
                    save()
                end)
            end }
        end
    end
    for __, cs in ipairs(host.sensors or {}) do
        local id = "cs_" .. cs.id
        local on = host.alerts[id]
        local name = (cs.name or "") ~= "" and cs.name or cs.cmd
        if cs.kind == "ok" then
            t[#t + 1] = { toggle = on == true, text = T(_("%1 failing"), name), callback = function()
                host.alerts[id] = not on or nil
                save()
            end }
        elseif cs.kind ~= "text" then
            t[#t + 1] = { setting = true, text = name, value = on and T(_("Over %1"), on) or _("Off"), callback = function()
                H().ask(T(_("Alert when %1 is over"), name), on and tostring(on) or "", function(val)
                    host.alerts[id] = tonumber(val)
                    save()
                end, { number = true, description = _("Empty: no alert") })
            end }
        end
    end
    -- custom alerts: any stat or sensor, a test and a value
    t[#t + 1] = { band = _("CUSTOM ALERTS") }
    for i, a in ipairs(host.customAlerts or {}) do
        t[#t + 1] = { text = S.alertText(a, host.sensors), icon = "triangle-alert", callback = function()
            Screens.editAlert(plugin, host, a, save)
        end, hold_callback = function()
            KO.list(S.alertText(a, host.sensors), {
                { text = _("Edit"), fn = function() Screens.editAlert(plugin, host, a, save) end },
                { text = _("Delete"), fn = function()
                    table.remove(host.customAlerts, i)
                    save()
                end },
            })
        end }
    end
    t[#t + 1] = { text = _("Add a custom alert"), sub = _("Any stat or sensor: above, below, is, isn't or contains a value"),
        icon = "plus", callback = function() Screens.editAlert(plugin, host, nil, save) end }
    if docker(host) then
        t[#t + 1] = { band = _("DOCKER") }
        t[#t + 1] = { setting = true, text = _("Compose folder"), value = host.compose or _("Asked the first time"),
            hint = _("For Pull all and Up again"), callback = function()
                H().ask(_("Compose folder"), host.compose or "", function(v)
                    host.compose = v:match("%S") and v or nil
                    save()
                end, { description = _("The folder with docker-compose.yml, for example /opt/stacks") })
            end }
    end
    return t
end

--- A custom alert, new (a nil) or changed: what it watches, the test, the
-- value. done() after.
function Screens.editAlert(plugin, host, a, done)
    local new = a == nil
    a = a or {}
    local function finish()
        if new then
            host.customAlerts = host.customAlerts or {}
            local n = 1
            for __, x in ipairs(host.customAlerts) do if (tonumber(x.id) or 0) >= n then n = tonumber(x.id) + 1 end end
            a.id = n
            table.insert(host.customAlerts, a)
        end
        done()
    end
    local function value(w)
        H().ask(T("%1 %2", w.name, (function()
            for __, o in ipairs(S.OPS) do if o.id == a.op then return _(o.name) end end
        end)()), a.value and tostring(a.value) or "", function(val)
            val = val:match("^%s*(.-)%s*$")
            if val == "" then return end
            a.value = val
            finish()
        end, { number = not w.text and a.op ~= "has" and a.op ~= "eq" and a.op ~= "ne",
            description = w.unit and T(_("In %1"), w.unit) or (w.text and _("Text, such as OK or 192.168.1.20") or nil) })
    end
    local function op(w)
        local items = {}
        for __, o in ipairs(S.OPS) do
            if not (w.text and (o.id == "gt" or o.id == "lt")) then
                items[#items + 1] = { text = _(o.name), checked = a.op == o.id, fn = function()
                    a.op = o.id
                    value(w)
                end }
            end
        end
        KO.list(T(_("When %1 is…"), w.name), items)
    end
    local items = {}
    for __, w in ipairs(S.watchable(host.sensors)) do
        items[#items + 1] = { text = w.name, checked = a.what == w.id, fn = function()
            a.what = w.id
            op(w)
        end }
    end
    KO.list(_("Alert when"), items)
end

--- A custom sensor, new (cs nil) or changed: its name, its command, what it
-- gives (and a number's unit). done() after.
function Screens.editSensor(plugin, host, cs, done)
    local new = cs == nil
    cs = cs or { kind = "number" }
    local function finish()
        if new then
            host.sensors = host.sensors or {}
            local n = 1
            for __, x in ipairs(host.sensors) do
                local k = tonumber(tostring(x.id):match("^s(%d+)$"))
                if k and k >= n then n = k + 1 end
            end
            cs.id = "s" .. n
            table.insert(host.sensors, cs)
        end
        done()
        Screens.readStatus(plugin, host, false)
    end
    local function unit()
        if cs.kind ~= "number" then return finish() end
        H().ask(_("Unit"), cs.unit or "", function(u)
            cs.unit = u:match("^%s*(.-)%s*$")
            finish()
        end, { description = _("Shown after the number: °C, GB, rpm… (or nothing)") })
    end
    local function kind()
        local items = {}
        for __, k in ipairs(S.SENSOR_KINDS) do
            items[#items + 1] = { text = _(k.name) .. " · " .. _(k.sub), checked = cs.kind == k.id, fn = function()
                cs.kind = k.id
                unit()
            end }
        end
        KO.list(_("What it gives"), items)
    end
    H().ask(_("Name"), cs.name or "", function(name)
        cs.name = name:match("^%s*(.-)%s*$")
        UI().runDialogText(plugin, host, _("The sensor's command"), cs.cmd or "", function(cmd)
            cs.cmd = cmd
            kind()
        end)
    end, { kind = "name", description = _("Pool temperature, Backup done, …") })
end

-- ------------------------------------------------------------------ Quick commands

function Screens.quickHold(plugin, host, q)
    KO.list(q.name, {
        { text = _("Run"), fn = function() Screens.runCommand(plugin, host, q.cmd, { ask = q.ask, name = q.name, session = q.session }) end },
        { text = _("Run full screen"), enabled = not q.session, fn = function()
            Screens.runCommand(plugin, host, q.cmd, { ask = q.ask, name = q.name, session = q.session, full = true })
        end },
        { text = _("Edit and run"), fn = function()
            UI().runDialog(plugin, host, q.cmd, function(cmd) Screens.runCommand(plugin, host, cmd) end)
        end },
        { text = _("Save as command"), fn = function()
            table.insert(host.commands, { id = M.newId(plugin.store.data, "c"), name = q.name, cmd = q.cmd })
            plugin:saved()
            UI().refreshHost(plugin, host)
            KO.toast(_("Saved."))
        end },
        { text = _("Choose quick commands"), fn = function() Screens.quickPage(plugin, host) end },
    })
end

--- Which quick commands show, and in what order: tap to show or hide,
-- hold to move; your own commands too.
function Screens.quickPage(plugin, host)
    local m
    local function ids()
        if type(host.quick) == "table" then return host.quick end
        local out = {}
        for __, q in ipairs(S.quickShown(host, docker(host) and docker(host).ok)) do out[#out + 1] = q.id end
        return out
    end
    local items
    local function save()
        plugin:saved()
        H().refresh(m, items())
        UI().refreshHost(plugin, host)
    end
    items = function()
        local t = {}
        local d = docker(host)
        local all = S.quickFor(hostOS(host), d and d.ok)
        local on = {}
        local list = ids()
        for __, id in ipairs(list) do on[id] = true end
        t[#t + 1] = { band = _("SHOWN, IN THIS ORDER"), right = osLabel(host) }
        local byId = {}
        for __, q in ipairs(all) do byId[q.id] = q end
        for i, id in ipairs(list) do
            local q = byId[id]
            local cmd, name = tostring(id):match("^cmd:(.*)|(.*)$")
            if q or cmd then
                t[#t + 1] = { toggle = true, text = q and q.name or name, sub = q and q.cmd or cmd, icon = q and q.icon or "terminal",
                    callback = function()
                        host.quick = ids()
                        table.remove(host.quick, i)
                        save()
                    end,
                    hold_callback = function()
                        KO.list(q and q.name or name, {
                            { text = _("Move up"), enabled = i > 1, fn = function()
                                host.quick = ids()
                                M.move(host.quick, i, -1)
                                save()
                            end },
                            { text = _("Move down"), enabled = i < #list, fn = function()
                                host.quick = ids()
                                M.move(host.quick, i, 1)
                                save()
                            end },
                        })
                    end }
            end
        end
        t[#t + 1] = { band = _("MORE FOR THIS SYSTEM") }
        for __, q in ipairs(all) do
            if not on[q.id] then
                t[#t + 1] = { toggle = false, text = q.name, sub = q.cmd, icon = q.icon, callback = function()
                    host.quick = ids()
                    table.insert(host.quick, q.id)
                    save()
                end }
            end
        end
        t[#t + 1] = { text = _("New quick command"), sub = _("A command of yours, with a short name and an icon"), icon = "plus",
            callback = function()
                H().ask(_("Name"), "", function(name)
                    name = name:match("^%s*(.-)%s*$")
                    UI().runDialogText(plugin, host, T(_("%1: the command"), name ~= "" and name or _("Quick command")), "", function(cmd)
                        local list = {}
                        for __, ic in ipairs(Screens.QUICK_ICONS) do
                            list[#list + 1] = { text = ic[2], fn = function()
                                local id = "cmd:" .. cmd .. "|" .. name
                                host.quick = ids()
                                table.insert(host.quick, id)
                                host.quickIcons = host.quickIcons or {}
                                host.quickIcons[id] = ic[1]
                                save()
                            end }
                        end
                        KO.list(_("Its icon"), list)
                    end)
                end, { kind = "name", description = _("Short: it goes under the icon, such as Backup or Logs") })
            end }
        t[#t + 1] = { text = _("Add one of your commands"), sub = _("From its saved commands or the command list"), icon = "plus",
            callback = function()
                UI().pickCommand(plugin, host, function(cmd)
                    if not cmd then return end
                    local name = cmd
                    for __, c in ipairs(host.commands) do if c.cmd == cmd then name = M.commandName(c) end end
                    for __, c in ipairs(plugin.store.data.commands) do if c.cmd == cmd then name = M.commandName(c) end end
                    host.quick = ids()
                    table.insert(host.quick, "cmd:" .. cmd .. "|" .. name)
                    save()
                end)
            end }
        t[#t + 1] = { text = _("Back to the usual ones"), icon = "rotate-ccw", callback = function()
            host.quick = nil
            save()
        end }
        return t
    end
    m = H().list(_("Quick commands"), items(), M.hostName(host))
end

-- The icons a quick command of yours can have.
Screens.QUICK_ICONS = {
    { "terminal", _("Terminal") }, { "play", _("Play") }, { "refresh-cw", _("Refresh") }, { "download", _("Download") },
    { "upload", _("Upload") }, { "trash-2", _("Trash") }, { "hard-drive", _("Disk") }, { "folder", _("Folder") },
    { "server", _("Server") }, { "box", _("Box") }, { "activity", _("Activity") }, { "power", _("Power") },
    { "rotate-cw", _("Restart") }, { "list-checks", _("Checklist") }, { "scroll-text", _("Logs") }, { "wifi", _("Network") },
}

-- ------------------------------------------------------------------ Docker

function Screens.docker(plugin, host)
    local m
    local function items()
        local t = {}
        local d = docker(host)
        if not d then return { { message = _("Docker wasn't found on this host.") } } end
        local q = {}
        for __, x in ipairs(S.DOCKER_QUICK) do
            local cmd = d.denied and ("sudo " .. x.cmd:gsub("&& docker", "&& sudo docker")) or x.cmd
            q[#q + 1] = { icon = x.icon, text = x.name, sub = x.sub, fn = function() Screens.runCommand(plugin, host, cmd, { ask = x.ask, name = x.name }) end }
        end
        t[#t + 1] = { quick = q }
        t[#t + 1] = { band = _("CONTAINERS"), right = T(_("%1 of %2 running"), S.running(d.list), #d.list) }
        for __, c in ipairs(d.list) do t[#t + 1] = containerRow(plugin, host, c) end
        if host.last then t[#t + 1] = { line = T(_("Updated %1 · ⟳ reads it again"), Screens.ago(host.last.at)) } end
        return t
    end
    m = H().list(_("Docker"), items(), M.hostName(host))
    m.items_fn = items
    m.on_refresh = function()
        Net.status(plugin, host, function() H().refresh(m, items()) end)
    end
end

-- ------------------------------------------------------------------ TrueNAS, Proxmox, ReadyNAS pages

local function updated(t, host)
    if host.last then t[#t + 1] = { line = T(_("Updated %1 · ⟳ reads it again"), Screens.ago(host.last.at)) } end
end

local function page(plugin, host, title, items)
    local m = H().list(title, items(), M.hostName(host))
    m.items_fn = items
    m.on_refresh = function() Net.status(plugin, host, function() H().refresh(m, items()) end) end
    return m
end

function Screens.truenas(plugin, host)
    page(plugin, host, _("TrueNAS"), function()
        local t = {}
        local tn = vals(host) and vals(host).truenas
        if not tn then return { { message = _("TrueNAS wasn't found on this host.") } } end
        if tn.denied then return { { message = _("TrueNAS's apps, shares and rsync tasks need sudo without a password here (or sign in as root).") } } end
        if tn.alerts and #tn.alerts > 0 then
            t[#t + 1] = { band = _("ALERTS"), right = tostring(#tn.alerts) }
            for __, a in ipairs(tn.alerts) do t[#t + 1] = alertRow(a) end
        end
        t[#t + 1] = { band = _("APPS"), right = T(_("%1 of %2 running"), S.upCount(tn.apps), #tn.apps) .. ((tn.updates or 0) > 0 and (" · " .. (tn.updates == 1 and _("1 update") or T(_("%1 updates"), tn.updates))) or "") }
        for __, a in ipairs(tn.apps) do t[#t + 1] = appRow(plugin, host, a) end
        if tn.guests and #tn.guests > 0 then
            t[#t + 1] = { band = _("VMS AND CONTAINERS"), right = T(_("%1 of %2 running"), S.upCount(tn.guests), #tn.guests) }
            for __, g in ipairs(tn.guests) do t[#t + 1] = tnGuestRow(plugin, host, g) end
        end
        t[#t + 1] = { band = _("SMB SHARES"), right = tostring(#tn.shares) }
        for __, x in ipairs(tn.shares) do t[#t + 1] = shareRow(x) end
        t[#t + 1] = { band = _("RSYNC TASKS"), right = tostring(#tn.rsync) }
        for __, x in ipairs(tn.rsync) do t[#t + 1] = rsyncRow(plugin, host, x) end
        updated(t, host)
        return t
    end)
end

function Screens.proxmox(plugin, host)
    page(plugin, host, _("Proxmox"), function()
        local t = {}
        local pv = vals(host) and vals(host).proxmox
        if not pv then return { { message = _("Proxmox wasn't found on this host.") } } end
        if pv.denied then return { { message = _("Proxmox's VMs, containers and backups are read as root: sign in as root, or allow sudo without a password.") } } end
        t[#t + 1] = { band = _("VMS AND CONTAINERS"), right = T(_("%1 of %2 running"), S.upCount(pv.guests), #pv.guests) }
        for __, g in ipairs(pv.guests) do t[#t + 1] = guestRow(plugin, host, g) end
        t[#t + 1] = { band = _("STORAGE"), right = tostring(#pv.storage) }
        for __, x in ipairs(pv.storage) do t[#t + 1] = storageRow(x) end
        if #pv.storage == 0 then t[#t + 1] = { line = _("None.") } end
        t[#t + 1] = { band = _("BACKUP JOBS"), right = tostring(#pv.jobs) }
        for __, j in ipairs(pv.jobs) do t[#t + 1] = jobRow(j) end
        if #pv.jobs == 0 then t[#t + 1] = { line = _("None.") } end
        t[#t + 1] = { band = _("LATEST BACKUPS") }
        for __, b in ipairs(pv.backups) do t[#t + 1] = backupRow(b) end
        if #pv.backups == 0 then t[#t + 1] = { line = _("None yet.") } end
        updated(t, host)
        return t
    end)
end

local MORE_TITLES = { pools = "Pools and disks", dataprotect = "Snapshots and replication", node = "Node and cluster", pfsense = "pfSense" }

function Screens.more(plugin, host, which)
    page(plugin, host, _(MORE_TITLES[which] or which), function()
        local t = {}
        local v = vals(host)
        if not v then return { { message = _("Not read yet.") } } end
        -- (only this section: the others' switches off for the moment)
        local keep = host.stats
        host.stats = {}
        for __, st in ipairs(S.STATS) do if st.section then host.stats[st.id] = st.id == which end end
        local ok, err = pcall(Screens.moreItems, plugin, host, v, t, true)
        host.stats = keep
        if not ok then error(err) end
        updated(t, host)
        return t
    end)
end

function Screens.shares(plugin, host)
    page(plugin, host, _("SMB shares"), function()
        local t = {}
        local v = vals(host)
        local list = v and (v.shares or (v.truenas and v.truenas.shares)) or {}
        t[#t + 1] = { band = _("SMB SHARES"), right = tostring(#list) }
        for __, x in ipairs(list) do t[#t + 1] = shareRow(x) end
        if #list == 0 then t[#t + 1] = { line = _("None.") } end
        updated(t, host)
        return t
    end)
end

-- ------------------------------------------------------------------ Pools, disks, upkeep, Pi, pfSense, printer

local function onOff(on) return on and _("On") or _("Off") end

local function poolRow(x)
    local sub = {}
    if x.total and x.total > 0 then sub[#sub + 1] = T(_("%1 of %2 used"), S.size(x.used), S.size(x.total)) end
    if x.raid and x.raid ~= "" then sub[#sub + 1] = x.raid end
    if x.scan and x.scan ~= "" then sub[#sub + 1] = x.scan end
    local h = tostring(x.health or "")
    local ok = h == "" or h == "ONLINE"
    return { text = x.name, sub = table.concat(sub, " · "), icon = ok and "layers" or "triangle-alert",
        right = h == "" and "" or (ok and _("Healthy") or (h:sub(1, 1) .. h:sub(2):lower())) }
end

local function diskRow(d)
    local sub = {}
    if d.model and d.model ~= "" then sub[#sub + 1] = d.model end
    if d.size and d.size > 0 then sub[#sub + 1] = S.size(d.size) end
    if d.pool and d.pool ~= "" then sub[#sub + 1] = T(_("In %1"), d.pool) end
    local right = {}
    if d.health and d.health ~= "OK" then right[#right + 1] = d.health end
    if d.temp then right[#right + 1] = string.format("%d °C", math.floor(d.temp + 0.5)) end
    if d.health == "OK" and not d.temp then right[#right + 1] = _("OK") end
    return { text = d.name, sub = table.concat(sub, " · "), icon = (d.health and d.health ~= "OK") and "triangle-alert" or "hard-drive",
        right = table.concat(right, " · ") }
end

local function snapRow(plugin, host, x)
    local sub = cronText(x.schedule)
    if x.state ~= "" then sub = sub .. " · " .. T(_("Last: %1"), upText(x.state)) end
    return { text = x.dataset, sub = sub, icon = "history", right = onOff(x.on),
        callback = function()
            KO.list(x.dataset, {
                { text = _("Take a snapshot now"), fn = function()
                    Screens.runCommand(plugin, host, S.truenasSnapshot(x.id), { ask = true, name = _("Take a snapshot now") })
                end },
            })
        end }
end

local function replRow(plugin, host, x)
    local sub = x.state ~= "" and T(_("Last: %1"), upText(x.state)) or ""
    if x.at then sub = sub .. " · " .. os.date("%b %d, %H:%M", x.at) end
    return { text = x.name, sub = sub, icon = "copy", right = onOff(x.on),
        callback = function()
            KO.list(x.name, {
                { text = _("Run now"), fn = function()
                    Screens.runCommand(plugin, host, S.truenasReplication(x.id), { ask = true, name = _("Run this replication now") })
                end },
            })
        end }
end

local function ifaceRow(x)
    return { text = x.name, icon = "network", right = T(_("↓ %1  ↑ %2"), S.size(x.inb), S.size(x.outb)) }
end

local function gatewayRow(g)
    local ok = tostring(g.status):lower() == "online" or tostring(g.status):lower() == "none"
    local sub = {}
    if g.delay ~= "" then sub[#sub + 1] = T(_("Delay %1"), g.delay) end
    if g.loss ~= "" then sub[#sub + 1] = T(_("Loss %1"), g.loss) end
    return { text = g.name, sub = table.concat(sub, " · "), icon = ok and "globe" or "triangle-alert", right = upText(g.status) }
end

local function printerMenu(plugin, host, pr)
    local st = tostring(pr.state)
    local function go(action, ask, name)
        Screens.runCommand(plugin, host, S.printerCmd(action), { ask = ask, name = name })
    end
    KO.list(_("3D printer"), {
        { text = _("Pause"), enabled = st == "printing", fn = function() go("pause", true, _("Pause the print")) end },
        { text = _("Resume"), enabled = st == "paused", fn = function() go("resume", false) end },
        { text = _("Cancel the print"), enabled = st == "printing" or st == "paused", fn = function() go("cancel", true, _("Cancel the print")) end },
    })
end

local function temp(now, target)
    if not now then return "?" end
    local s = string.format("%d °C", math.floor(now + 0.5))
    if target and target > 0 then s = s .. " → " .. string.format("%d °C", math.floor(target + 0.5)) end
    return s
end

--- These sections: on the host's page (full = false: a few of each list) or their own page.
function Screens.moreItems(plugin, host, v, t, full)
    local function open(which) return function() Screens.more(plugin, host, which) end end
    local function list(items, row, which, n)
        if full then
            for __, x in ipairs(items) do t[#t + 1] = row(x) end
            if #items == 0 then t[#t + 1] = { line = _("None.") } end
        else
            some(t, items, row, open(which), n)
        end
    end
    -- Pools and disks
    if wants(host, "pools") and (v.pools or v.disks) then
        if v.pools then
            t[#t + 1] = { band = _("POOLS"), right = tostring(#v.pools), callback = open("pools") }
            list(v.pools, poolRow, "pools", 3)
        end
        if v.disks then
            t[#t + 1] = { band = _("DISKS"), right = tostring(#v.disks), callback = open("pools") }
            list(v.disks, diskRow, "pools", 4)
        end
    end
    -- TrueNAS: snapshots and replication
    local tn = v.truenas
    if tn and tn.ok and tn.snaps and wants(host, "dataprotect") then
        t[#t + 1] = { band = _("SNAPSHOT TASKS"), right = tostring(#tn.snaps), callback = open("dataprotect") }
        list(tn.snaps, function(x) return snapRow(plugin, host, x) end, "dataprotect", 3)
        t[#t + 1] = { band = _("REPLICATION"), right = tostring(#tn.repl), callback = open("dataprotect") }
        list(tn.repl, function(x) return replRow(plugin, host, x) end, "dataprotect", 3)
    end
    -- Proxmox: the node and the cluster
    local pv = v.proxmox
    if pv and pv.ok and wants(host, "node") and (pv.node or pv.cluster or #pv.failed > 0) then
        t[#t + 1] = { band = _("NODE"), right = pv.node and pv.node.version:match("^pve%-manager/([%d%.]+)") and ("Proxmox VE " .. pv.node.version:match("^pve%-manager/([%d%.]+)")) or nil }
        if pv.node then
            t[#t + 1] = { text = T(_("CPU %1 %"), pv.node.cpu or "?"), icon = "cpu",
                sub = T(_("Memory %1 of %2"), S.size(pv.node.used), S.size(pv.node.total)) }
        end
        if pv.cluster then
            local up = 0
            for __, n in ipairs(pv.nodes) do if n.online then up = up + 1 end end
            t[#t + 1] = { text = T(_("Cluster %1"), pv.cluster.name), icon = "server",
                sub = T(_("%1 of %2 nodes online"), up, #pv.nodes), right = pv.cluster.quorate and _("Quorate") or _("No quorum") }
        end
        if #pv.failed > 0 then
            t[#t + 1] = { band = _("FAILED TASKS"), right = tostring(#pv.failed), callback = open("node") }
            list(pv.failed, function(x)
                local kinds = { vzdump = _("Backup"), qmstart = _("Start"), qmshutdown = _("Shut down"), qmstop = _("Stop"), qmreboot = _("Reboot"),
                    vzstart = _("Start"), vzshutdown = _("Shut down"), vzstop = _("Stop"), vzreboot = _("Reboot"), aptupdate = _("Update check") }
                return { text = (kinds[x.kind] or x.kind) .. (x.guest ~= "" and (" " .. x.guest) or ""), icon = "triangle-alert",
                    sub = x.at and os.date("%b %d, %H:%M", x.at) or "", right = x.status }
            end, "node", 2)
        end
    end
    -- Updates and logs
    local up = v.upkeep
    if up and wants(host, "upkeep") then
        local mgr = up.manager
        t[#t + 1] = { band = _("UPDATES AND LOGS") }
        if up.updates then
            t[#t + 1] = { text = up.updates == 0 and _("Up to date") or (up.updates == 1 and _("1 update waiting") or T(_("%1 updates waiting"), up.updates)),
                icon = up.updates == 0 and "circle-check" or "download",
                callback = mgr and S.UPGRADE[mgr] and function()
                    KO.list(_("Updates"), {
                        { text = _("Update everything"), enabled = up.updates > 0, fn = function()
                            Screens.runCommand(plugin, host, S.UPGRADE[mgr], { ask = true, name = _("Update everything") })
                        end },
                        { text = _("Show them"), fn = function()
                            Run().command(plugin, host, mgr == "apt" and "apt list --upgradable 2>/dev/null" or "checkupdates 2>/dev/null || pacman -Qu")
                        end },
                    })
                end or nil }
        end
        if up.cache and mgr and S.CLEAN[mgr] then
            t[#t + 1] = { text = _("Package cache"), icon = "package", right = S.size(up.cache),
                callback = function()
                    KO.list(_("Package cache"), {
                        { text = _("Empty it"), fn = function() Screens.runCommand(plugin, host, S.CLEAN[mgr], { ask = true, name = _("Empty the package cache") }) end },
                    })
                end }
        end
        if up.errors then
            t[#t + 1] = { text = up.errors == 0 and _("No errors since it started") or (up.errors == 1 and _("1 error since it started") or T(_("%1 errors since it started"), up.errors)),
                sub = up.lines[#up.lines], icon = up.errors == 0 and "circle-check" or "triangle-alert",
                callback = up.errors > 0 and function() Run().command(plugin, host, "journalctl -b -p err -q --no-pager -n 50") end or nil }
        end
        if up.journal then
            t[#t + 1] = { text = _("Logs"), icon = "scroll-text", right = S.size(up.journal),
                callback = function()
                    KO.list(_("Logs"), {
                        { text = _("Remove logs older than 2 weeks"), fn = function()
                            Screens.runCommand(plugin, host, S.LOGS_CLEAN, { ask = true, name = _("Remove old logs") })
                        end },
                    })
                end }
        end
    end
    -- Raspberry Pi
    local pi = v.pi
    if pi and wants(host, "pi") then
        t[#t + 1] = { band = _("RASPBERRY PI") }
        local th = pi.throttled
        if th then
            local sub
            if #th.now > 0 then sub = table.concat(th.now, ", ")
            elseif #th.past > 0 then sub = T(_("Since it started: %1"), table.concat(th.past, ", ")) end
            t[#t + 1] = { text = _("Power and heat"), sub = sub, icon = th.ok and "circle-check" or "triangle-alert",
                right = #th.now > 0 and _("Throttled") or _("OK") }
        end
        for __, o in ipairs(S.PI_OPTS) do
            local on = pi.opts[o.id]
            if on ~= nil then
                t[#t + 1] = { text = _(o.name), sub = o.reboot and _("Takes effect after a restart") or nil, icon = "settings", right = onOff(on),
                    callback = function()
                        Screens.runCommand(plugin, host, S.piSet(o.id, not on),
                            { ask = true, name = T(on and _("Turn off %1") or _("Turn on %1"), _(o.name)) })
                    end }
            end
        end
    end
    -- pfSense
    local pf = v.pfsense
    if pf and wants(host, "pfsense") then
        t[#t + 1] = { band = _("PFSENSE") }
        t[#t + 1] = { text = T(_("%1 firewall states"), pf.states or "?"), icon = "lock",
            sub = pf.dhcp and T(_("%1 DHCP leases"), pf.dhcp) or nil }
        for __, g in ipairs(pf.gateways) do t[#t + 1] = gatewayRow(g) end
        for __, x in ipairs(pf.vpns) do
            if x.count > 0 then t[#t + 1] = { text = x.name, icon = "lock", right = x.name == "OpenVPN" and T(_("%1 running"), x.count) or T(_("%1 up"), x.count) } end
        end
        t[#t + 1] = { band = _("INTERFACES"), right = tostring(#pf.ifaces), callback = open("pfsense") }
        list(pf.ifaces, ifaceRow, "pfsense", 3)
        t[#t + 1] = { text = _("Check for updates"), icon = "download",
            callback = function() Run().command(plugin, host, "pfSense-upgrade -c") end }
    end
    -- The printer
    local pr = v.printer
    if pr and wants(host, "printer") then
        local st = tostring(pr.state)
        t[#t + 1] = { band = _("3D PRINTER"), right = upText(st) }
        local sub = {}
        if pr.progress and (st == "printing" or st == "paused") then sub[#sub + 1] = string.format("%d %%", math.floor(pr.progress * 100 + 0.5)) end
        if pr.elapsed and pr.elapsed > 0 then sub[#sub + 1] = S.duration(pr.elapsed) end
        if pr.message ~= "" then sub[#sub + 1] = pr.message end
        t[#t + 1] = { text = pr.file ~= "" and pr.file or _("Nothing printing"), sub = table.concat(sub, " · "), icon = "box",
            callback = function() printerMenu(plugin, host, pr) end, hold_callback = function() printerMenu(plugin, host, pr) end }
        t[#t + 1] = { text = _("Nozzle"), icon = "thermometer", right = temp(pr.nozzle, pr.nozzleTarget) }
        t[#t + 1] = { text = _("Bed"), icon = "thermometer", right = temp(pr.bed, pr.bedTarget) }
    end
end

-- ------------------------------------------------------------------ Services

function Screens.services(plugin, host)
    local m
    local list, filter = nil, "all"
    local function items()
        local t = {}
        t[#t + 1] = { chips = {
            { text = _("All"), on = filter == "all", fn = function() filter = "all" H().refresh(m, items()) end },
            { text = _("Running"), on = filter == "running", fn = function() filter = "running" H().refresh(m, items()) end },
            { text = _("Failed"), on = filter == "failed", fn = function() filter = "failed" H().refresh(m, items()) end },
        } }
        if not list then
            t[#t + 1] = { message = _("Reading its services…") }
            return t
        end
        local n = 0
        for __, s in ipairs(list) do
            local show = filter == "all" or (filter == "running" and s.sub == "running") or (filter == "failed" and s.active == "failed")
            if show then
                n = n + 1
                t[#t + 1] = { text = s.name, sub = s.desc, icon = s.active == "failed" and "triangle-alert" or "server",
                    right = s.active == "failed" and _("Failed") or (s.sub == "running" and _("Running"))
                        or (s.sub == "exited" and _("Done")) or ((s.sub == "dead" or s.sub == "inactive") and _("Stopped")) or s.sub,
                    callback = function() serviceMenu(plugin, host, s.name, s.active) end }
            end
        end
        if n == 0 then t[#t + 1] = { message = _("None.") } end
        return t
    end
    local function load()
        Net.run(plugin, host, S.SERVICES_CMD, function(out, __, why)
            if not out then
                list = {}
                KO.message(T(_("Couldn't read its services (%1)."), tostring(why)))
            else
                list = S.parseServices(out)
                table.sort(list, function(a, b)
                    if (a.active == "failed") ~= (b.active == "failed") then return a.active == "failed" end
                    return a.name < b.name
                end)
                host.servicesSeen = {}
                for __, s in ipairs(list) do host.servicesSeen[#host.servicesSeen + 1] = s.name end
            end
            if m then H().refresh(m, items()) end
        end)
    end
    m = H().list(_("Services"), items(), M.hostName(host))
    m.on_refresh = load
    load()
end

-- ------------------------------------------------------------------ the editor

-- The biggest file the editor opens (the Kindle edits it in memory).
local EDIT_MAX = 1024 * 1024

--- Edits a file on a host in KOReader's full-screen text editor: Save writes
-- it back (sudo when the file needs it: its password asked once, or none
-- with passwordless sudo). password: the SSH sign-in's, asked already.
function Screens.editFile(plugin, host, path, password, after, closed)
    local store = plugin.store
    local tmp = store.cache .. "/edit-in.txt"
    os.remove(tmp)
    local box = KO.wait(T(_("Opening %1…"), path))
    Net.run(plugin, host, "cat -- " .. M.quote(path), function(err, rc, why)
        if box and box.close then box.close() end
        local text = store.readFile(tmp)
        os.remove(tmp)
        if not text or rc ~= 0 then
            return KO.message(T(_("Can't open %1:\n%2"), path, tostring(err ~= "" and err or why or rc)), nil, closed)
        end
        if #text > EDIT_MAX then return KO.message(T(_("%1 is too big to edit here (over 1 MB)."), path), nil, closed) end
        if text:find("\0", 1, true) then return KO.message(T(_("%1 isn't a text file."), path), nil, closed) end
        Screens.editor(plugin, host, path, text, password, after, closed)
    end, { password = password, outFile = tmp, limit = 60 })
end

--- Writes text to a file on a host: as you, or (it needs it) with sudo.
-- done(true) or done(nil, why).
function Screens.writeFile(plugin, host, path, text, password, done)
    local store = plugin.store
    local tmp = store.cache .. "/edit-out.txt"
    if not store.writeFile(tmp, text) then return done(nil, _("Can't write on the Kindle.")) end
    Net.run(plugin, host, "cat > " .. M.quote(path), function(out, rc, why)
        if rc == 0 then
            os.remove(tmp)
            return done(true)
        end
        local msg = tostring(out or why or "")
        if not msg:lower():find("permission denied", 1, true) then
            os.remove(tmp)
            return done(nil, msg ~= "" and msg or T(_("Exit status %1"), tostring(rc)))
        end
        -- It needs sudo: without a password when sudo allows it, else asked
        -- (sent first, then the text: sudo -S reads one line, tee the rest).
        Net.run(plugin, host, "sudo -n true", function(__, nrc)
            local tee = "tee -- " .. M.quote(path) .. " > /dev/null"
            if nrc == 0 then
                return Net.run(plugin, host, "sudo " .. tee, function(o2, rc2)
                    os.remove(tmp)
                    if rc2 == 0 then return done(true) end
                    done(nil, tostring(o2))
                end, { password = password, inFile = tmp })
            end
            local function withPassword(pw)
                local both = store.cache .. "/edit-sudo.txt"
                store.writeFile(both, pw .. "\n" .. text, true)
                os.remove(tmp)
                Net.run(plugin, host, "sudo -S -p '' " .. tee, function(o3, rc3)
                    os.remove(both)
                    if rc3 == 0 then return done(true) end
                    done(nil, (tostring(o3):gsub("^%s*Sorry, try again%.?", _("Wrong sudo password."))))
                end, { password = password, inFile = both })
            end
            local request = KO.request()
            local title = T(_("sudo password for %1"), host.user)
            if request then
                return request{ title = title, subtitle = T(_("%1 needs sudo to change."), path), password = true, typing = true,
                    text = host.auth == "password" and host.password or "", buttons = {
                        { icon = "x", text = _("Cancel"), cancel = true },
                        { icon = "check", text = _("Save"), primary = true, needsText = true, fn = withPassword },
                    }, onCancel = function()
                        os.remove(tmp)
                        done(nil, "cancelled")
                    end }
            end
            H().ask(title, "", withPassword, { password = true, description = T(_("%1 needs sudo to change."), path) })
        end, { password = password })
    end, { password = password, inFile = tmp })
end

-- KOReader's full-screen text editor, dressed as the apps' pages: the
-- shared title bar (‹, ⌂, recent apps, the clock, ⟳, 🔔, ⋮) in place of its
-- title, and the apps' icon row in place of its text buttons. (It lays
-- itself out again when the keyboard shows or hides: dressed again then.)
local Editor
local function editorClass()
    if Editor then return Editor end
    local InputDialog = require("ui/widget/inputdialog")
    Editor = InputDialog:extend{}
    function Editor:init()
        InputDialog.init(self)
        self:dress()
    end
    -- a button of KOReader's (by its id, or its text): what it does
    function Editor:own(id, text)
        local b = id and self.button_table:getButtonById(id)
        if b then return b.callback end
        for __, row in ipairs(self.buttons or {}) do
            for __, x in ipairs(row) do
                if x.text == text then return x.callback end
            end
        end
    end
    function Editor:close()
        local fn = self:own("close")
        if fn then fn() else UIManager:close(self) end
    end
    function Editor:dress()
        require("sshbar").swapInto(self, {
            on_back = function() self:close() end,
            on_home = function()
                self.goHome = true
                self:close()
            end,
            on_refresh = function() UIManager:setDirty(self, "full") end,
            on_menu = function() UI().more() end,
        })
        local keyboard = self:own("keyboard")
        local foot = require("sshbuttons"):new{
            width = self.button_table:getSize().w, bare = true, height = self.button_table:getSize().h, show_parent = self,
            buttons = {
                { icon = "list", text = _("Line"), fn = self:own("go") },
                { icon = "search", text = _("Find"), fn = self:own(nil, _("Find")) },
                { icon = "type", text = _("Keyboard"), fn = keyboard },
                { icon = "x", text = _("Close"), fn = function() self:close() end },
                { icon = "check", text = _("Save"), primary = true, fn = self:own("save") },
            },
        }
        for __, w in ipairs(self.vgroup) do
            if type(w) == "table" and w[1] == self.button_table then w[1] = foot end
        end
        self.vgroup:resetLayout()
    end
    return Editor
end

--- KOReader's full-screen text editor on a file's text; Save writes it back.
function Screens.editor(plugin, host, path, text, password, after, closed)
    local editor
    editor = editorClass():new{
        title = T("%1: %2", M.hostName(host), path),
        input = text,
        input_face = require("ui/font"):getFace("smallinfont", 18),
        fullscreen = true,
        condensed = true,
        allow_newline = true,
        cursor_at_end = false,
        add_nav_bar = true,
        scroll_by_pan = true,
        -- Save (and Close, which asks when it changed): KOReader's editor's own
        save_callback = function(content, closing)
            -- KOReader runs Save in a coroutine (Trapper): it waits here for
            -- the device's answer, so the editor knows whether it was saved.
            local co = coroutine.running()
            local result
            Screens.writeFile(plugin, host, path, content, password, function(ok, why)
                result = { ok, why }
                if co and coroutine.status(co) == "suspended" then coroutine.resume(co) end
            end)
            if not result and co then coroutine.yield() end
            if not result then return false, _("Still saving…") end
            if result[1] then
                if after then after() end
                return true, T(_("Saved on %1."), M.hostName(host))
            end
            if result[2] == "cancelled" then return false, _("Not saved.") end
            return false, T(_("Couldn't save %1:\n%2"), path, tostring(result[2]))
        end,
        close_callback = function()
            if editor.goHome then return UIManager:nextTick(function() UI().home() end) end
            if closed then UIManager:nextTick(closed) end
        end,
    }
    UIManager:show(editor)
    editor:onShowKeyboard()
end

-- ------------------------------------------------------------------ Files

local function sizeOf(n)
    if not n then return "" end
    if n < 1024 then return T(_("%1 bytes"), n) end
    return S.size(n / 1024)
end

--- The Kindle's folder for a copied file: books in the home folder (the
-- Kindle's documents), others in its Downloads.
local function kindleFolder(name)
    local home = G_reader_settings:readSetting("home_dir") or Device.home_dir or "/mnt/us/documents"
    if S.isBook(name) then return home end
    local dl = home .. "/Downloads"
    require("util").makePath(dl)
    return dl
end

function Screens.files(plugin, host, start)
    local m
    local path = start or host.filesAt or "~"
    local listing, err
    local password
    local items
    local function load(p)
        listing, err = nil, nil
        if m then H().refresh(m, items()) end
        local function go()
            Net.run(plugin, host, S.listCommand(p == "~" and "." or p), function(out, __, why)
                if out then
                    local l, e = S.parseList(out)
                    listing, err = l, e
                    if l then
                        path = l.pwd
                        host.filesAt = path
                    end
                else
                    err = why
                end
                if m then H().refresh(m, items()) end
            end, { password = password })
        end
        if password ~= nil or Net.quiet(plugin, host) then return go() end
        Run().prepare(plugin, host, function(pw)
            password = pw or false
            go()
        end)
    end
    local function fileMenu(f)
        local full = S.join(path, f.name)
        local menu = {
            { text = _("Edit"), enabled = (f.size or 0) <= EDIT_MAX, fn = function()
                Screens.editFile(plugin, host, full, password, function() load(path) end)
            end },
            { text = _("Read it"), fn = function()
                Net.run(plugin, host, "head -c 300000 " .. M.quote(full), function(out, __, why)
                    if not out then return KO.message(tostring(why)) end
                    Run().show(plugin, f.name, out, function() end, { host = host, cmd = "cat " .. full })
                end, { password = password })
            end },
            { text = T(_("Copy to the Kindle (%1)"), sizeOf(f.size)), fn = function()
                local dir = kindleFolder(f.name)
                local to = dir .. "/" .. f.name
                KO.confirm{ title = _("Copy to the Kindle?"), text = T(_("%1 (%2)\nto %3"), f.name, sizeOf(f.size), dir), ok = _("Copy"),
                    onOk = function()
                        local box = KO.wait(T(_("Copying %1…"), f.name))
                        Net.run(plugin, host, "cat " .. M.quote(full), function(out, rc, why)
                            if box and box.close then box.close() end
                            local lfs = require("libs/libkoreader-lfs")
                            if not out or rc ~= 0 then
                                os.remove(to)
                                return KO.message(T(_("Couldn't copy it (%1)."), tostring(why or rc)))
                            end
                            KO.message(T(_("Copied to %1 (%2)."), to, sizeOf(lfs.attributes(to, "size"))))
                        end, { password = password, outFile = to, limit = 600 })
                    end }
            end },
        }
        if require("sshai").available() and S.isText(f.name) then
            menu[#menu + 1] = { text = _("Explain with AI"), fn = function()
                Net.run(plugin, host, "tail -n 300 " .. M.quote(full), function(out)
                    if not out then return KO.message(_("Couldn't read it.")) end
                    require("sshai").output(plugin, "explain", { host = host, cmd = "tail -n 300 " .. full, output = out })
                end, { password = password })
            end }
        end
        menu[#menu + 1] = { text = _("Copy its path"), fn = function() H().copyText(full) end }
        KO.list(f.name, menu)
    end
    items = function()
        local t = {}
        t[#t + 1] = { line = path, mono = true }
        if err then
            t[#t + 1] = { message = err == "cd" and _("Can't open this folder.") or T(_("Couldn't read it (%1)."), tostring(err)) }
        elseif not listing then
            t[#t + 1] = { message = _("Reading…") }
            return t
        end
        if path ~= "/" then
            t[#t + 1] = { text = _("Up one folder"), icon = "folder-open", callback = function() load(S.parent(path)) end }
        end
        for __, f in ipairs(listing and listing.items or {}) do
            if f.dir then
                t[#t + 1] = { text = f.name, icon = "folder", chevron = true, callback = function() load(S.join(path, f.name)) end }
            else
                t[#t + 1] = { text = f.name, sub = sizeOf(f.size), icon = S.isBook(f.name) and "file-text" or "file",
                    callback = function() fileMenu(f) end, hold_callback = function() fileMenu(f) end }
            end
        end
        return t
    end
    m = H().list(_("Files"), items(), M.hostName(host))
    m.bar_buttons = { { "house", function() load("~") end } }
    m.on_refresh = function() load(path) end
    load(path)
end

-- ------------------------------------------------------------------ History

--- Everything run, newest first; search (the title bar's 🔍) narrows it.
function Screens.history(plugin, askFirst)
    local data = plugin.store.data
    local q = ""
    local m
    local function items()
        local t = {}
        local found = M.searchHistory(data, q)
        if q ~= "" then t[#t + 1] = { line = T(_("Search: %1 (%2 found)"), q, #found), callback = function()
            q = ""
            H().refresh(m, items())
        end } end
        if #found == 0 then t[#t + 1] = { message = q ~= "" and _("Nothing found.") or _("Nothing run yet.") } end
        for __, r in ipairs(found) do
            local h = M.host(data, r.host)
            t[#t + 1] = { text = r.cmd, monoText = false, sub = T("%1 · %2", h and M.hostName(h) or _("A deleted host"), Screens.ago(r.at)),
                icon = "history",
                callback = function()
                    if not h then return end
                    UI().runDialog(plugin, h, r.cmd, function(cmd) Run().command(plugin, h, cmd) end)
                end,
                hold_callback = function()
                    if not h then return end
                    KO.list(r.cmd, {
                        { text = T(_("Run again on %1"), M.hostName(h)), fn = function() Run().command(plugin, h, r.cmd) end },
                        { text = _("Run on another host"), fn = function()
                            local list = {}
                            for __, x in ipairs(data.hosts) do
                                list[#list + 1] = { text = M.hostName(x), fn = function()
                                    UI().runDialog(plugin, x, r.cmd, function(cmd) Run().command(plugin, x, cmd) end)
                                end }
                            end
                            KO.list(_("Run on"), list)
                        end },
                        { text = T(_("Save on %1"), M.hostName(h)), fn = function()
                            table.insert(h.commands, { id = M.newId(data, "c"), name = "", cmd = r.cmd })
                            plugin:saved()
                            KO.toast(_("Saved."))
                        end },
                        { text = _("Copy text"), fn = function() H().copyText(r.cmd) end },
                    })
                end }
        end
        return t
    end
    local function search()
        H().ask(_("Search history"), q, function(v)
            q = v:match("^%s*(.-)%s*$")
            H().refresh(m, items())
        end, { ok = _("Search") })
    end
    m = H().list(_("History"), items(), nil)
    m.bar_buttons = { { "search", search } }
    m.items_fn = items
    if askFirst then search() end
end

-- ------------------------------------------------------------------ Settings

--- SSH's settings (⋮ > Settings, and the launcher's Settings): checks, the
-- main page's stats, the dark terminal, AI.
function Screens.settingsItems(plugin, redo)
    local data = plugin.store.data
    local t = {}
    local all = data.check_every
    if all == nil then all = 15 end
    t[#t + 1] = { band = _("CHECKS") }
    t[#t + 1] = { setting = true, text = _("Check hosts"), value = everyName(all),
        hint = _("Their status and alerts, while the Kindle is awake and on Wi-Fi. A host can have its own."),
        callback = function()
            pickNumber(_("Check hosts"), all, EVERY, function(n)
                data.check_every = n
                plugin:saved()
                redo()
            end)
        end }
    t[#t + 1] = { band = _("THE SSH PAGE") }
    t[#t + 1] = { toggle = data.main_stats ~= false, text = _("Stats under each host"), sub = _("Its first two, such as up 3 days · 52 °C"),
        callback = function()
            data.main_stats = data.main_stats == false and true or false
            plugin:saved()
            redo()
            UI().refreshMain(plugin)
        end }
    -- SSH's own PIN (a host can have its own too: Edit host)
    t[#t + 1] = { band = _("PIN") }
    t[#t + 1] = { setting = true, text = data.app_pin and _("Change app PIN") or _("Set an app PIN"), value = data.app_pin and _("On") or _("Off"),
        hint = _("Asked when SSH opens, and before a host's page, a live session or a command from outside it (again after 5 minutes)"),
        callback = function()
            UI().editPin(UI().appLock(plugin), function(hash)
                data.app_pin = hash
                plugin:saved()
                redo()
            end)
        end }
    if data.app_pin then
        t[#t + 1] = { setting = true, text = _("Remove app PIN"), callback = function()
            data.app_pin = nil
            M.unlocked.app = nil
            plugin:saved()
            redo()
            KO.toast(_("PIN removed"), 2)
        end }
    end
    t[#t + 1] = { band = _("LIVE SESSION") }
    local Dark = require("sshdark")
    t[#t + 1] = { toggle = Dark.isOn(), text = _("Dark terminal"), sub = _("Also the moon and sun key in a live session"),
        callback = function()
            Dark.set(not Dark.isOn())
            redo()
        end }
    -- (KOReader's own setting, shared with its Terminal emulator.)
    local size = G_reader_settings:readSetting("terminal_font_size", 14)
    t[#t + 1] = { setting = true, text = _("Text size"), value = tostring(size),
        hint = _("The next live session opens with it (the same as KOReader's Terminal emulator)"),
        callback = function()
            local sizes = {}
            for __, n in ipairs({ 10, 12, 14, 16, 18, 20, 22, 24 }) do
                sizes[#sizes + 1] = { n, n == 14 and T(_("%1 (default)"), n) or tostring(n) }
            end
            pickNumber(_("Text size"), size, sizes, function(n)
                if not n then return end
                G_reader_settings:saveSetting("terminal_font_size", n)
                redo()
                local S = package.loaded["sshsession"]
                if S and S.current and S.current.open then KO.toast(_("The next live session opens with it"), 3) end
            end)
        end }
    if require("pluginshare").ai then
        t[#t + 1] = { band = _("AI") }
        t[#t + 1] = { setting = true, text = _("AI settings"), value = require("sshai").available() and require("pluginshare").ai.jobName("ssh") or _("Not set up"),
            callback = function() require("pluginshare").ai.showSettings() end }
    end
    return t
end

function Screens.settings(plugin)
    local m
    local function redo() H().refresh(m, Screens.settingsItems(plugin, redo)) end
    m = H().list(_("SSH settings"), Screens.settingsItems(plugin, redo), nil)
end

return Screens
