--[[--
Connecting: Wi-Fi, the password (saved, or asked for), trusting a host's key
the first time (its fingerprint is shown), then running a command in a child
process (sshbg) and showing what it printed. Also running one command on
several hosts at once.

dbclient runs with HOME = settings/sshclient (its known_hosts is there), in
BatchMode (it never waits for typing); a password goes to it in
DROPBEAR_PASSWORD, never on its command line.
]]

local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Bg = require("sshbg")
local KO = require("sshko")
local Dark = require("sshdark")
local M = require("sshmodel")

local Run = {}

-- How long a command may run before it is stopped, in seconds.
Run.LIMIT = 300

local function info(text)
    KO.message(text)
end

--- Calls fn(item, next) for each item in turn, then done(); next(false) stops.
local function each(list, fn, done)
    local i = 0
    local function step(go_on)
        if go_on == false then return end
        i = i + 1
        if i > #list then return done() end
        fn(list[i], step)
    end
    step()
end

-- ------------------------------------------------------------------ sign-in

--- cb(password or nil) for a host: its saved password, or asked for
-- ("Ask every time", or a password host with none saved). Not called on Cancel.
function Run.password(host, cb)
    if host.auth == "key" then return cb(nil) end
    if host.auth == "password" and host.password and host.password ~= "" then return cb(host.password) end
    -- (the launcher's box, with dots; KOReader's without it)
    local request = KO.request()
    if request then
        return request{ title = T(_("Password for %1"), M.hostLabel(host)), password = true, typing = true, buttons = {
            { icon = "x", text = _("Cancel"), cancel = true },
            { icon = "log-in", text = _("Connect"), primary = true, fn = function(pw) cb(pw) end },
        } }
    end
    local dialog
    dialog = InputDialog:new{
        title = T(_("Password for %1"), M.hostLabel(host)),
        text_type = "password",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Connect"), is_enter_default = true, callback = function()
                local pw = dialog:getInputText()
                UIManager:close(dialog)
                cb(pw)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ------------------------------------------------------------------ one dbclient

--- Runs dbclient jobs together in a child process: each { host, args,
-- password }. done({ { text, rc } … }, why) with why "stopped" or "timeout"
-- when it didn't finish (what was printed until then is kept).
-- opts: { text (a waiting box; none: quiet), limit, prefix (the files'
-- name, so jobs can run side by side; "run" by default) }; a job's outFile:
-- its output (stdout only, as it is: a file copied) goes there; inFile:
-- what it reads (a file saved back).
local jobCount = 0
function Run.jobs(plugin, jobs, opts, done)
    local store = plugin.store
    local home = store.dir
    jobCount = jobCount + 1
    local prefix = opts.prefix and (opts.prefix .. jobCount) or "run"
    for i, j in ipairs(jobs) do
        j.out = store.cache .. "/" .. prefix .. "-" .. i .. ".out"
        j.rc = store.cache .. "/" .. prefix .. "-" .. i .. ".rc"
        os.remove(j.out)
        os.remove(j.rc)
    end
    local function collect(why)
        local results = {}
        for i, j in ipairs(jobs) do
            local text = store.readFile(j.out) or ""
            local rc = tonumber((store.readFile(j.rc) or ""):match("%d+"))
            os.remove(j.out)
            os.remove(j.rc)
            local cut
            text, cut = M.tail(text)
            results[i] = { text = text, rc = rc, cut = cut }
        end
        done(results, why)
    end
    Bg.run(function()
        local ffi = require("ffi")
        require("ffi/posix_h")
        local C = ffi.C
        C.setenv("HOME", home, 1)
        C.unsetenv("SSH_AUTH_SOCK")
        local amp = #jobs > 1 and " &" or ""
        for __, j in ipairs(jobs) do
            if j.password then
                C.setenv("DROPBEAR_PASSWORD", j.password, 1)
            else
                C.unsetenv("DROPBEAR_PASSWORD")
            end
            -- (each in the background when there are several: they inherit
            -- the environment as it is now)
            local to = j.outFile and (M.quote(j.outFile) .. " 2> " .. M.quote(j.out)) or (M.quote(j.out) .. " 2>&1")
            local from = j.inFile and M.quote(j.inFile) or "/dev/null"
            os.execute("(" .. M.shellLine(j.args) .. " > " .. to .. " < " .. from .. "; echo $? > "
                .. M.quote(j.rc) .. ")" .. amp)
        end
        C.unsetenv("DROPBEAR_PASSWORD")
        if #jobs > 1 then
            local lfs = require("libs/libkoreader-lfs")
            while true do
                local left = 0
                for __, j in ipairs(jobs) do
                    if not lfs.attributes(j.rc, "mode") then left = left + 1 end
                end
                if left == 0 then break end
                ffi.C.usleep(200000)
            end
        end
        return true
    end, function(__, why)
        collect(why)
    end, { text = opts.text, limit = opts.limit or Run.LIMIT })
end

local function keyFileOf(plugin, host)
    if host.auth ~= "key" then return nil end
    return host.key and plugin.store:keyFile(host.key)
end

-- ------------------------------------------------------------------ host keys

--- Trusts a host's key: asks, then saves it (dbclient -y). cb() once trusted.
local function askTrust(plugin, host, keytype, fingerprint, cb)
    KO.confirm{
        title = _("Trust this host?"),
        text = T(_("%1 (%2)\n\n%3 key fingerprint:\n%4\n\nIf you're not sure, compare it with the device's own (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on the device)."),
            M.hostName(host), M.hostLabel(host), keytype or "", fingerprint or ""),
        ok = _("Trust"),
        onOk = function()
            local db = plugin.store:dbclient()
            Run.jobs(plugin, { { args = M.dbclientArgs(db, host, { probe = true, trust = true }) } },
                { text = T(_("Connecting to %1…"), M.hostName(host)), limit = 60 }, function(results, why)
                    if why then return end
                    local r = M.parseRun(results[1].text)
                    if r.accepted and r.fingerprint == fingerprint then
                        logger.info("SSH: trusted", host.address, fingerprint)
                        return cb()
                    end
                    if r.accepted then
                        -- the key that was saved isn't the one shown
                        plugin.store:forget(host.address)
                        return info(T(_("The host's key changed while connecting. Not trusted.\n\nShown: %1\nNow: %2"),
                            fingerprint, r.fingerprint or "?"))
                    end
                    if r.problem == "connect" then
                        return info(T(_("Can't connect to %1.\n\n%2"), M.hostName(host), r.message or ""))
                    end
                    -- already in known_hosts (by another name): go on
                    cb()
                end)
        end,
    }
end

--- cb() once the host's key is trusted (asking the first time).
function Run.trusted(plugin, host, cb)
    if plugin.store:isKnown(host.address) then return cb() end
    local db = plugin.store:dbclient()
    Run.jobs(plugin, { { args = M.dbclientArgs(db, host, { probe = true }) } },
        { text = T(_("Connecting to %1…"), M.hostName(host)), limit = 60 }, function(results, why)
            if why then return end
            local r = M.parseRun(results[1].text)
            if r.problem == "unknown_host" then
                return askTrust(plugin, host, r.keytype, r.fingerprint, cb)
            elseif r.problem == "connect" then
                return info(T(_("Can't connect to %1.\n\n%2"), M.hostName(host), r.message or ""))
            elseif r.problem == "changed_host" then
                return Run.changed(plugin, host, r, cb)
            end
            cb()
        end)
end

--- The host's key isn't the one saved: say so; Trust new key forgets the old
-- one and trusts the new one (asking again, with its fingerprint).
function Run.changed(plugin, host, r, cb)
    KO.confirm{
        title = T(_("The host key of %1 has changed"), M.hostName(host)),
        text = T(_("This happens when the device was reinstalled or got a new address. It can also mean someone is intercepting the connection.\n\nNew: %1\nSaved: %2"),
            r.fingerprint or "?", r.expected or "?"),
        ok = _("Trust new key"),
        danger = true,
        onOk = function()
            plugin.store:forget(host.address)
            Run.trusted(plugin, host, cb)
        end,
    }
end

--- Gets everything ready for a connection: dbclient, the key file, Wi-Fi,
-- the password and a trusted host key; then cb(password).
function Run.prepare(plugin, host, cb)
    if not plugin.store:dbclient() then
        return info(_("dbclient wasn't found. It comes with KOReader for Kindle (koreader/dbclient)."))
    end
    if host.auth == "key" then
        local f = keyFileOf(plugin, host)
        if not f or not plugin.store.readFile(f) then
            return info(T(_("%1 has no key. Edit the host and choose a key."), M.hostName(host)))
        end
    end
    NetworkMgr:runWhenConnected(function()
        Run.password(host, function(password)
            Run.trusted(plugin, host, function()
                Run.detect(plugin, host, password, function() cb(password) end)
            end)
        end)
    end)
end

--- A host set to detect its system ("auto") that hasn't been detected yet:
-- asks it once (/etc/os-release, or Darwin, or Windows' ver), then cb().
-- When it can't tell, it asks again next time.
function Run.detect(plugin, host, password, cb)
    if host.os ~= "auto" or host.detected then return cb() end
    local db = plugin.store:dbclient()
    local args = M.dbclientArgs(db, host, { cmd = M.DETECT_CMD, keyFile = keyFileOf(plugin, host) })
    Run.jobs(plugin, { { args = args, password = password } },
        { text = T(_("Connecting to %1…"), M.hostName(host)), limit = 30 }, function(results, why)
            if not why then
                local r = M.parseRun(results[1].text)
                local os_id = not r.problem and M.detectOS(r.output) or nil
                if os_id then
                    host.detected = os_id
                    plugin:saved()
                    logger.info("SSH:", host.address, "is", os_id)
                end
            end
            cb()
        end)
end

-- ------------------------------------------------------------------ results

--- The text for one result: the output, then how it ended.
local function describe(host, res, why)
    local r = M.parseRun(res.text)
    local lines = {}
    if res.cut then lines[#lines + 1] = _("(Only the last 200 KB are shown.)") .. "\n" end
    if r.output ~= "" then lines[#lines + 1] = r.output end
    local tail
    if why == "stopped" then
        tail = _("Stopped.")
    elseif why == "timeout" then
        tail = T(_("Stopped after %1 minutes."), math.floor(Run.LIMIT / 60))
    elseif r.problem == "signin" then
        tail = host.auth == "key" and _("Can't sign in: the device didn't accept the key. Add its public key to ~/.ssh/authorized_keys on the device.")
            or _("Can't sign in: check the user name and password.")
    elseif r.problem == "connect" then
        tail = T(_("Can't connect: %1"), r.message or "")
    elseif r.problem == "changed_host" then
        tail = _("Not connected: the host key has changed.")
    elseif r.problem == "unknown_host" then
        tail = _("Not connected: the host key isn't trusted yet. Connect to this host on its own first.")
    elseif r.problem == "other" then
        tail = r.message
    elseif res.rc and res.rc ~= 0 then
        tail = T(_("Exit status %1"), res.rc)
    elseif r.output == "" then
        tail = _("Done (no output).")
    end
    if tail then lines[#lines + 1] = (#lines > 0 and "\n" or "") .. tail end
    return table.concat(lines, "\n"), r
end

--- Runs a command on a host and shows what it printed.
function Run.command(plugin, host, cmd, opts)
    -- a command with blanks ({service}): they're asked for first
    if #require("sshstats").blanks(cmd) > 0 then
        return require("sshscreens").fillBlanks(plugin, host, cmd, function(filled) Run.command(plugin, host, filled, opts) end)
    end
    Run.prepare(plugin, host, function(password)
        local db = plugin.store:dbclient()
        local args = M.dbclientArgs(db, host, { cmd = cmd, keyFile = keyFileOf(plugin, host) })
        M.addRecent(host, cmd)
        M.addHistory(plugin.store.data, host.id, cmd)
        plugin:saved()
        local started = os.time()
        Run.jobs(plugin, { { args = args, password = password } },
            { text = T(_("Running on %1…\n\n%2"), M.hostName(host), cmd) }, function(results, why)
                local text, r = describe(host, results[1], why)
                if r.problem == "changed_host" then
                    return Run.changed(plugin, host, r, function() Run.command(plugin, host, cmd, opts) end)
                end
                local function show()
                    Run.show(plugin, T("%1: %2", M.hostName(host), cmd), text, function() Run.command(plugin, host, cmd, opts) end,
                        { host = host, cmd = cmd, full = opts and opts.full })
                end
                -- A long one (a minute or more) is also kept in Notifications, one
                -- per host: this host's earlier one goes (its output was seen, or
                -- this one takes its place), and opening it takes it out.
                local PS = require("pluginshare")
                local key = "sshclient:done:" .. tostring(host.id)
                if PS.unnotify then pcall(PS.unnotify, key) end
                if PS.notify and why ~= "stopped" and os.time() - started >= 60 then
                    local failed = r.problem or why or (results[1].rc and results[1].rc ~= 0)
                    pcall(PS.notify, {
                        app = "sshclient", name = _("SSH"), icon = "terminal", key = key,
                        text = failed and T(_("Command failed on %1: %2"), M.hostName(host), cmd)
                            or T(_("Command finished on %1: %2"), M.hostName(host), cmd),
                        open = function()
                            if PS.unnotify then pcall(PS.unnotify, key) end
                            show()
                        end,
                        route = { host = host.id },
                    })
                end
                show()
                -- sudo wanted a password, which a run without a terminal can't
                -- give: offer the same command in a live session
                if M.usesSudo(cmd) and M.sudoNeedsPassword(results[1].text) then
                    KO.confirm{ title = _("sudo needs a password"),
                        text = _("Run it in a live session, where sudo can ask for the password."),
                        ok = _("Run in a live session"), cancel = _("Close"),
                        onOk = function() require("sshui").session(plugin, host, cmd) end }
                end
            end)
    end)
end

--- Runs a command on several hosts at once; one page with each host's part.
function Run.many(plugin, hosts, cmd)
    if #require("sshstats").blanks(cmd) > 0 then
        return require("sshscreens").fillBlanks(plugin, nil, cmd, function(filled) Run.many(plugin, hosts, filled) end)
    end
    local ready = {}
    NetworkMgr:runWhenConnected(function()
        each(hosts, function(host, next)
            if host.auth == "key" and not (host.key and plugin.store.readFile(plugin.store:keyFile(host.key))) then
                ready[#ready + 1] = { host = host, skip = _("No key: edit the host and choose a key.") }
                return next()
            end
            Run.password(host, function(password)
                Run.trusted(plugin, host, function()
                    ready[#ready + 1] = { host = host, password = password }
                    next()
                end)
            end)
        end, function()
            local db = plugin.store:dbclient()
            if not db then return info(_("dbclient wasn't found. It comes with KOReader for Kindle (koreader/dbclient).")) end
            local jobs, order = {}, {}
            for __, x in ipairs(ready) do
                if not x.skip then
                    jobs[#jobs + 1] = { args = M.dbclientArgs(db, x.host, { cmd = cmd, keyFile = keyFileOf(plugin, x.host) }),
                        password = x.password }
                    order[#order + 1] = x
                    M.addRecent(x.host, cmd)
                    M.addHistory(plugin.store.data, x.host.id, cmd)
                end
            end
            plugin:saved()
            local function show(results, why)
                local parts = {}
                local n = 0
                for __, x in ipairs(ready) do
                    local body
                    if x.skip then
                        body = x.skip
                    else
                        n = n + 1
                        body = describe(x.host, results and results[n] or { text = "" }, why)
                    end
                    parts[#parts + 1] = T("── %1 (%2) ──\n%3", M.hostName(x.host), M.hostLabel(x.host), body)
                end
                Run.show(plugin, T(_("%1 hosts: %2"), #ready, cmd), table.concat(parts, "\n\n"), function()
                    Run.many(plugin, hosts, cmd)
                end, { hosts = hosts, cmd = cmd })
            end
            if #jobs == 0 then return show(nil) end
            Run.jobs(plugin, jobs, { text = T(_("Running on %1 hosts…\n\n%2"), #jobs, cmd) }, show)
        end)
    end)
end

--- The output: monospace, with Copy all and Run again (long-press a word to copy
-- it, or long-press and drag to copy a part); with an AI set up, Explain and
-- Summarize (sshai). ctx: { host or hosts, cmd, full }. One host's output shows in a
-- pop-up (with Live session on that host and Full screen) unless `full`; several
-- hosts', and with `full`, on the full page. The last one is kept for the web page's
-- AI help (plugin.lastOutput).
function Run.show(plugin, title, text, again, ctx)
    ctx = ctx or {}
    plugin.lastOutput = { host = ctx.host and ctx.host.id, cmd = ctx.cmd, text = text, title = title }
    local viewer
    -- Rows of the same number of buttons, so they line up: with the AI,
    -- four of SSH's over TextViewer's own Find, ⇱, ⇲, Close; without, two
    -- rows of three.
    local copy = { text = _("Copy all"), callback = function()
        require("device").input.setClipboardText(text)
        KO.toast(_("Copied."))
    end }
    local runAgain = { text = _("Run again"), callback = function()
        viewer:onClose()
        again()
    end }
    local rows
    local AI = require("sshai")
    -- With the launcher: SSH's own page with its icon buttons (sshoutput).
    if KO.read() then
        local page
        local buttons = {
            { icon = "search", text = _("Find"), fn = function() page:find() end },
            { icon = "copy", text = _("Copy all"), fn = copy.callback },
        }
        if AI.available() then
            local function aiCtx() return { host = ctx.host, hosts = ctx.hosts, cmd = ctx.cmd, output = text } end
            buttons[#buttons + 1] = { icon = "sparkles", text = _("Explain"), aiJob = "ssh_explain", fn = function() AI.output(plugin, "explain", aiCtx()) end }
            buttons[#buttons + 1] = { icon = "file-text", text = _("Summarize"), aiJob = "ssh_summary", fn = function() AI.output(plugin, "summary", aiCtx()) end }
        end
        buttons[#buttons + 1] = { icon = "rotate-ccw", text = _("Run again"), primary = true, fn = function()
            page:onClose()
            again()
        end }
        local popup = ctx.host and not ctx.full
        if popup then
            -- (Find is on the full page: Full screen.)
            table.remove(buttons, 1)
            buttons[#buttons + 1] = { icon = "terminal", text = _("Live session"), fn = function()
                page:onClose()
                require("sshui").session(plugin, ctx.host)
            end }
            buttons[#buttons + 1] = { icon = "maximize", text = _("Full screen"), fn = function()
                page:onClose()
                local c = {}
                for k, v in pairs(ctx) do c[k] = v end
                c.full = true
                Run.show(plugin, title, text, again, c)
            end }
            page = require("sshoutput").show{ title = title, text = text, buttons = buttons, popup = true }
            return
        end
        Dark.enter()
        page = require("sshoutput").show{ title = title, text = text, buttons = buttons, onClosed = function() Dark.leave() end }
        return
    end
    if AI.available() then
        local function aiCtx() return { host = ctx.host, hosts = ctx.hosts, cmd = ctx.cmd, output = text } end
        rows = { {
            { text = _("Explain"), callback = function() AI.output(plugin, "explain", aiCtx()) end },
            { text = _("Summarize"), callback = function() AI.output(plugin, "summary", aiCtx()) end },
            copy, runAgain,
        } }
    else
        rows = {
            { copy, runAgain, { text = _("Find"), id = "find", callback = function()
                if viewer._find_next then viewer:findCallback() else viewer:findDialog() end
            end } },
            { { text = "⇱", id = "top", callback = function() viewer.scroll_widget:scrollToTop() end },
                { text = "⇲", id = "bottom", callback = function() viewer.scroll_widget:scrollToBottom() end },
                { text = _("Close"), callback = function() viewer:onClose() end } },
        }
    end
    viewer = TextViewer:new{
        title = title,
        text = text,
        text_type = "code",
        add_default_buttons = AI.available(),
        close_callback = function() Dark.leave() end,
        buttons_table = rows,
    }
    Dark.enter()
    UIManager:show(viewer)
end

return Run
