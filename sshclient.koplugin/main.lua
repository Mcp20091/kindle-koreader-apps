--[[--
SSH: connect from the Kindle to your other devices (PCs, a NAS, a Raspberry
Pi) and run commands. Saved hosts (address, user, port; a key or a
password), a key made on this Kindle or imported, a host's key trusted the
first time, commands run in the background with their output in a scrolling
page, saved one-tap commands, a command list to paste from, a live session,
and one command on several hosts at once.

It uses KOReader's own dbclient (Dropbear's SSH client, koreader/dbclient on
a Kindle). Hosts, keys and passwords are kept in KOReader's settings folder
(sshclient.json, sshclient_passwords.json, sshclient/).

Also: the Apps launcher's line (appsLine, event ShowSSH), gestures (open,
and run a saved command), and calls for the web page (webState, act).

@module koplugin.sshclient
]]

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local M = require("sshmodel")
local Store = require("sshstore")

-- One store while KOReader runs (each book and the library get a new plugin).
local state = { store = nil }

local SSH = WidgetContainer:extend{
    name = "sshclient",
    is_doc_only = false,
}

function SSH:init()
    if not state.store then state.store = Store.new(self.path) end
    self.store = state.store
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    require("sshui").plugin = self
    require("sshko").flashOnUncover()
    -- SSH's job and AI features in Settings > AI (the launcher's)
    require("sshai").register()
    local PS = require("pluginshare")
    -- the checks every few minutes (once while KOReader runs)
    if not state.checking then
        state.checking = true
        require("sshnet").start(self)
    end
    -- What it is for the launcher and the web page: its tile, Settings group, web tab
    -- (apps.koplugin/appsinfo.lua).
    -- (The tile's key is ssh; the folder is sshclient.koplugin: KOReader's own SSH server is SSH.koplugin.)
    PS.appInfo = PS.appInfo or {}
    PS.appInfo.sshclient = { name = _("SSH"), icon = "terminal", order = 70, group = "tools",
        -- "3 hosts".
        tiles = { { key = "ssh", event = "ShowSSH", line = function(s) return s:appsLine() end } },
        web = { page = "ssh", routes = "webssh", script = "web/ssh.js", dir = self.path,
            card = "Hosts, the command list and keys." } }
    -- SSH's settings in the launcher's Settings
    if PS.registerSettings then
        PS.registerSettings{ key = "sshclient", name = _("SSH"), icon = "terminal",
            open = function() require("sshscreens").settings(require("sshui").plugin or self) end }
    end
    -- a step in the launcher's Set up your Kindle
    if PS.registerSetup then
        local here = (debug.getinfo(1, "S").source or ""):match("^@(.*/)") or ""
        PS.registerSetup{ key = "ssh", order = 55, icon = "terminal", title = _("SSH"),
            text = _("SSH connects the Kindle to your other devices: a PC, a NAS, a Raspberry Pi. Add one once, then see its status, run commands with a tap, edit its files or open a live session."),
            image = here .. "setup-ssh.png",
            done = function() return #((self.store and self.store.data.hosts) or {}) > 0 end,
            doneText = _("Host added"), action = _("Add a host"),
            skipped = _("SSH stays empty until you add a host. You can add one later from its page."),
            run = function() require("sshui").addHost(require("sshui").plugin or self) end }
    end
    -- hosts and saved commands in the launcher's search
    if PS.registerSearch then
        PS.registerSearch{ key = "sshclient", name = _("SSH"), icon = "terminal",
            search = function(q) return SSH.search(q) end }
    end
    -- Hosts' saved commands as the launcher's quick buttons (grouped by host):
    -- a tap runs it as the app does, a hold opens its host in SSH. And each
    -- host's status ("NAS · 71 % disk · 7/8 running"): a tap reads it again.
    if PS.registerQuick then
        PS.registerQuick{ key = "sshclient", name = _("SSH commands"),
            choices = function() return SSH.quickChoices() end,
            item = function(id) return SSH.quickItem(id) end }
    end
    -- The web page's backup: hosts, commands and trusted host keys; saved
    -- passwords and private keys only with Include keys and sign-ins.
    PS.backupApps = PS.backupApps or {}
    PS.backupApps.sshclient = { key = "sshclient", name = _("SSH"),
        files = { "^sshclient%.json$" },
        reader_keys = { "^sshclient_" },
        dirs = { "settings/sshclient/.ssh" },
        secret_files = { "sshclient_passwords.json" },
        secret_dirs = { "settings/sshclient/keys" } }
    -- a notification tapped after a restart: the host's page
    PS.notifyOpeners = PS.notifyOpeners or {}
    PS.notifyOpeners.sshclient = function(route)
        local UI = require("sshui")
        UI.show(UI.plugin)
        local h = route and route.host and M.host(state.store.data, route.host)
        if h then UI.host(UI.plugin, h) end
        -- (seen: it goes; the host's page is what is left of it after a restart)
        if route and route.host and PS.unnotify then pcall(PS.unnotify, "sshclient:done:" .. route.host) end
    end
end

function SSH:onDispatcherRegisterActions()
    Dispatcher:registerAction("sshclient_show", { category = "none", event = "ShowSSH", title = _("SSH"), general = true })
    Dispatcher:registerAction("sshclient_run", { category = "string", event = "RunSSHCommand",
        title = _("SSH: run a saved command"), general = true,
        args_func = function() return M.gestureChoices(state.store.data) end })
end

function SSH:addToMainMenu(menu_items)
    menu_items.sshclient = {
        text = _("SSH"),
        sorting_hint = "network",
        callback = function() self:show() end,
    }
end

function SSH:show()
    return require("sshui").show(self)
end

function SSH:onShowSSH()
    self:show()
    return true
end

function SSH:onRunSSHCommand(ref)
    local h, c = M.hostCommand(self.store.data, ref)
    if not h then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("This SSH command was deleted. Choose another for the gesture.") })
        return true
    end
    require("sshui").withPin(h, function() require("sshrun").command(self, h, c.cmd) end)
    return true
end

--- The launcher's search (q in lower case): hosts (they open their page)
-- and hosts' saved commands (they open in the host's command box, to run).
function SSH.search(q)
    local out = {}
    local data = state.store and state.store.data
    if not data or not q or q == "" then return out end
    local function has(s) return s and tostring(s):lower():find(q, 1, true) end
    local UI = require("sshui")
    for __, h in ipairs(data.hosts) do
        if #out >= 20 then break end
        if has(h.name) or has(h.address) then
            out[#out + 1] = { title = M.hostName(h), sub = M.hostLabel(h), open = function()
                UI.show(UI.plugin)
                UI.host(UI.plugin, h)
            end }
        end
    end
    for __, h in ipairs(data.hosts) do
        for __, c in ipairs(h.commands) do
            if #out >= 20 then return out end
            if has(c.name) or has(c.cmd) then
                out[#out + 1] = { title = M.commandName(c), sub = T("%1: %2", M.hostName(h), c.cmd), open = function()
                    UI.show(UI.plugin)
                    UI.withPin(h, function()
                        UI.host(UI.plugin, h)
                        UI.runDialog(UI.plugin, h, c.cmd, function(cmd) require("sshrun").command(UI.plugin, h, cmd) end)
                    end)
                end }
            end
        end
    end
    return out
end

--- The quick buttons to pick from: every host's saved commands, by host.
function SSH.quickChoices()
    local out = {}
    local data = state.store and state.store.data
    if not data then return out end
    for __, h in ipairs(data.hosts) do
        out[#out + 1] = { id = "status:" .. h.id, name = T(_("Status: %1"), M.hostName(h)), icon = "activity", group = _("Status") }
    end
    for __, h in ipairs(data.hosts) do
        for __, c in ipairs(h.commands) do
            out[#out + 1] = { id = h.id .. "/" .. c.id, name = M.commandName(c), icon = "terminal", group = M.hostName(h) }
        end
    end
    return out
end

--- A quick button for "<host id>/<command id>"; nil when the host or the
-- command is gone.
function SSH.quickItem(id)
    local data = state.store and state.store.data
    if not data then return nil end
    local sid = tostring(id):match("^status:(.+)$")
    if sid then
        local h = M.host(data, sid)
        if not h then return nil end
        local S = require("sshstats")
        local UI = require("sshui")
        local line = h.last and S.short(h.last.v, S.shown(h), 3) or ""
        return {
            label = line ~= "" and T("%1 · %2", M.hostName(h), line) or M.hostName(h),
            icon = "activity",
            tap = function(done)
                require("sshnet").status(UI.plugin, h, function() if done then done() end end)
            end,
            hold = function()
                UI.show(UI.plugin)
                UI.host(UI.plugin, h)
            end,
        }
    end
    local h, c = M.hostCommand(data, id)
    if not h then return nil end
    local UI = require("sshui")
    return {
        label = M.commandName(c),
        icon = "terminal",
        tap = function(done)
            -- as from the host's page: in the background, then its output
            UI.withPin(h, function() require("sshrun").command(UI.plugin, h, c.cmd) end)
            if done then done() end
        end,
        hold = function()
            UI.show(UI.plugin)
            UI.host(UI.plugin, h)
        end,
    }
end

--- After a change to the data: saved, and the lists showing it redrawn.
function SSH:saved()
    self.store:save()
end

-- ------------------------------------------------------------------ launcher

--- The Apps launcher's line: "3 hosts".
function SSH:appsLine()
    return M.appsLine(self.store.data)
end

-- ------------------------------------------------------------------ web page

--- What the web page's SSH tab shows: hosts (no passwords: hasPassword),
-- the command list, keys with their public key lines, and whether a host's
-- key is trusted (known).
function SSH:webState()
    local st = M.webState(self.store.data)
    for __, h in ipairs(st.hosts) do h.known = self.store:isKnown(h.address) end
    st.dbclient = self.store:dbclient() ~= nil
    -- AI help: whether an AI is set up (and for SSH's job), and the last
    -- output shown on the Kindle (its last 30 KB)
    local AI = require("sshai")
    local ai = require("pluginshare").ai
    st.ai = { available = AI.available(), ready = AI.available() and ai.readyFor(AI.JOB) or false,
        service = AI.available() and ai.jobName(AI.JOB) or nil }
    local last = self.lastOutput
    if last then st.last = { host = last.host, cmd = last.cmd, title = last.title, text = (M.tail(last.text or "", 30 * 1024)) } end
    return st
end

-- The web page's AI requests: key -> { status, answer, commands, why }.
local aiJobs, aiCount = {}, 0

--- AI help from the web page: { kind = "explain" | "summary" | "write",
-- host (id), cmd, output, want, turns = { { answer, question } } }. Starts
-- it and returns { key } (then aiResult(key)), or nil, why.
function SSH:aiStart(args)
    local AI = require("sshai")
    if not AI.available() then return nil, "Set up an AI first (Settings > AI)." end
    local ai = require("pluginshare").ai
    if not ai.readyFor(AI.JOB) then return nil, ai.notReadyText(AI.JOB) end
    local kind = args.kind
    if not AI.FEATURES[kind] then return nil, "Unknown request." end
    local host = args.host and M.host(self.store.data, args.host) or nil
    local secrets = AI.secrets(self)
    local first
    if kind == "write" then
        if not tostring(args.want or ""):match("%S") then return nil, "Describe the command first." end
        first = (M.redact(tostring(args.want), secrets))
    else
        if not tostring(args.output or ""):match("%S") then return nil, "Paste the output first." end
        first = M.aiOutputText(args.cmd and tostring(args.cmd) or nil, tostring(args.output), AI.amount(kind), secrets)
    end
    local turns = type(args.turns) == "table" and args.turns or {}
    local text = #turns > 0 and M.aiFollowUp(first, turns, secrets) or first
    aiCount = aiCount + 1
    local key = tostring(aiCount)
    aiJobs[key] = { status = "waiting" }
    ai.ask(AI.FEATURES[kind].key, { text = text, args = { AI.system(host) } }, function(answer, why)
        if not answer then
            aiJobs[key] = { status = "done", why = tostring(why or "No answer came.") }
            return
        end
        local cmds, shown = M.aiCommands(answer)
        aiJobs[key] = { status = "done", answer = shown, raw = answer, commands = cmds, service = ai.jobName(AI.JOB) }
    end)
    return { key = key }
end

--- An AI request's state: { status = "waiting" } or { status = "done",
-- answer, raw, commands, service } or { status = "done", why }; nil when unknown.
function SSH:aiResult(key)
    return aiJobs[tostring(key)]
end

--- The web page's changes: M.act's (saveHost, deleteHost, saveCommands,
-- saveHostCommands, renameKey) and importKey { name, text } (a private key
-- file's text), createKey { name }, deleteKey { id }, forgetHost { id }.
-- Returns a result table or nil, why.
function SSH:act(name, args)
    args = type(args) == "table" and args or {}
    local r, why
    if name == "importKey" then
        local entry, err = require("sshui").importText(self, tostring(args.text or ""), args.name)
        if not entry then return nil, err end
        r = { id = entry.id, public = entry.public }
    elseif name == "createKey" then
        local key, err = Store.generateEd25519()
        if not key then return nil, "Can't create a key: " .. tostring(err) end
        local n = tostring(args.name or ""):match("^%s*(.-)%s*$")
        local entry, serr = self.store:addKey(n ~= "" and n or "Kindle", key)
        if not entry then return nil, serr end
        r = { id = entry.id, public = entry.public }
    elseif name == "deleteKey" then
        if not self.store:deleteKey(args.id) then return nil, "No such key." end
        r = {}
    elseif name == "importConfig" then
        -- ~/.ssh/config's hosts: new ones added (the same user and address
        -- already there: skipped), signing in with the first key, or asking
        local S = require("sshstats")
        local data = self.store.data
        local added, skipped = 0, 0
        for __, c in ipairs(S.parseSshConfig(tostring(args.text or ""))) do
            local there = false
            for __, h in ipairs(data.hosts) do
                if h.address == c.address and h.user == (c.user or h.user) then there = true end
            end
            if there or not c.user then
                skipped = skipped + 1
            else
                local key = data.keys[1]
                local ok = M.act(data, "saveHost", { name = c.name, address = c.address, user = c.user, port = c.port,
                    auth = key and "key" or "ask", key = key and key.id or "" })
                if ok then added = added + 1 else skipped = skipped + 1 end
            end
        end
        r = { added = added, skipped = skipped }
    elseif name == "forgetHost" then
        local h = M.host(self.store.data, args.id)
        if not h then return nil, "No such host." end
        self.store:forget(h.address)
        r = {}
    else
        r, why = M.act(self.store.data, name, args)
        if not r then return nil, why end
    end
    self:saved()
    logger.info("SSH: web page", name)
    -- the lists on the Kindle show the change
    local UI = require("sshui")
    UI.refreshMain(self)
    return r
end

return SSH
