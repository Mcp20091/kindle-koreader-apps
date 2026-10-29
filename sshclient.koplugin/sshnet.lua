--[[--
SSH's work in the background, without asking anything: a host's status
(sshstats' command, then its alerts), Docker's and services' lists, a
folder's listing, a file copied to the Kindle, whether hosts answer (their
SSH port, no sign-in), Wake on LAN, and the checks every few minutes.

Only hosts that need nothing asked go quietly: a key on the Kindle or a
saved password, and a trusted host key. The others wait for ⟳, which asks
as a run does (Run.prepare). Checks run while the Kindle is awake and
already on Wi-Fi; they never turn Wi-Fi on.
]]

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Bg = require("sshbg")
local M = require("sshmodel")
local S = require("sshstats")

local Net = {}

-- Whether each host answers on its SSH port: [host id] = { ok, at }.
Net.online = {}
-- Hosts whose status is being read now: [host id] = true.
Net.busy = {}

local function keyFile(plugin, host)
    if host.auth ~= "key" then return nil end
    return host.key and plugin.store:keyFile(host.key)
end

--- Whether a host can be reached without asking anything; or false, why
-- ("dbclient", "ask", "nokey", "untrusted").
function Net.quiet(plugin, host)
    if not plugin.store:dbclient() then return false, "dbclient" end
    if host.auth == "ask" then return false, "ask" end
    if host.auth == "password" and not (host.password and host.password ~= "") then return false, "ask" end
    if host.auth == "key" and not (host.key and plugin.store.readFile(plugin.store:keyFile(host.key))) then return false, "nokey" end
    if not plugin.store:isKnown(host.address) then return false, "untrusted" end
    return true
end

--- One command on a host, in the background: done(output, rc, why). opts:
-- { password (asked already), outFile (the output goes there, as it is),
-- inFile (what the command reads), limit (seconds) }.
function Net.run(plugin, host, cmd, done, opts)
    opts = opts or {}
    local password = opts.password
    if password == nil then
        local ok, why = Net.quiet(plugin, host)
        if not ok then return done(nil, nil, why) end
        password = host.auth == "password" and host.password or nil
    end
    local args = M.dbclientArgs(plugin.store:dbclient(), host, { cmd = cmd, keyFile = keyFile(plugin, host) })
    require("sshrun").jobs(plugin, { { args = args, password = password, outFile = opts.outFile, inFile = opts.inFile } },
        { prefix = "bg", limit = opts.limit or 45 }, function(results, why)
            local r = results[1] or {}
            local parsed = M.parseRun(r.text or "")
            if parsed.problem then return done(nil, r.rc, parsed.problem, parsed.message) end
            done(opts.outFile and (r.text or "") or parsed.output, r.rc, why)
        end)
end

-- ------------------------------------------------------------------ status

--- Reads a host's status (its shown stats, Docker, pinned services) and
-- keeps it as host.last = { at, v }; then its alerts. done(v | nil, why).
-- opts.password: asked already (⟳ on a host that asks). opts.auto: one of the
-- checks; PAUSE_AFTER of those failing in a row pause the host's checks
-- (host.paused) until a read of yours (its page, ⟳) gets an answer.
function Net.status(plugin, host, done, opts)
    opts = opts or {}
    done = done or function() end
    if Net.busy[host.id] then return done(nil, "busy") end
    Net.busy[host.id] = true
    local os_id = M.hostOS(host)
    Net.run(plugin, host, S.command(os_id, host.services, host.sensors), function(out, __, why, msg)
        Net.busy[host.id] = nil
        if not out then
            host.lastError = why and (msg or why) or nil
            if opts.auto then
                host.fails, host.failedAt = (host.fails or 0) + 1, os.time()
                if host.fails >= Net.PAUSE_AFTER then
                    host.paused = true
                    logger.info("SSH: checks paused for a host after", host.fails, "failed reads")
                end
                plugin:saved()
            end
            return done(nil, why)
        end
        host.fails, host.failedAt, host.paused = nil, nil, nil
        local raw = S.parse(out)
        -- (not known yet: the answer says which system it is; and one
        -- detected as Debian or FreeBSD may turn out to be TrueNAS or pfSense)
        if (not host.os or host.os == "auto") and raw.os then
            local found = M.detectOS(raw.os .. "\n" .. (raw.sys or ""))
            if found and (not os_id or M.REFINED[found]) then host.detected = found end
        end
        local v = S.values(raw)
        host.last = { at = os.time(), v = v }
        host.lastError = nil
        if v.mac then host.mac = v.mac end
        Net.online[host.id] = { ok = true, at = os.time() }
        Net.alerts(plugin, host, v)
        plugin:saved()
        done(v)
    end, { password = opts.password, limit = 40 })
end

--- The alerts a host raises now: a notification for each new one, gone
-- when it's over.
function Net.alerts(plugin, host, v)
    local PS = require("pluginshare")
    local raised = S.check(v, host.alerts, host.sensors)
    for __, a in ipairs(S.checkCustom(v, host.customAlerts, host.sensors)) do raised[#raised + 1] = a end
    local now = {}
    host.raised = host.raised or {}
    for __, a in ipairs(raised) do
        now[a.id] = true
        if not host.raised[a.id] and PS.notify then
            pcall(PS.notify, {
                app = "sshclient", name = _("SSH"), icon = "triangle-alert",
                key = "sshclient:alert:" .. host.id .. ":" .. a.id,
                text = T("%1: %2", M.hostName(host), a.text),
                route = { host = host.id },
                open = function()
                    local UI = require("sshui")
                    UI.show(UI.plugin)
                    UI.host(UI.plugin, host)
                end,
            })
        end
    end
    for id in pairs(host.raised) do
        if not now[id] and PS.unnotify then pcall(PS.unnotify, "sshclient:alert:" .. host.id .. ":" .. id) end
    end
    host.raised = now
end

-- ------------------------------------------------------------------ online

--- Whether hosts answer on their SSH port (a connection, no sign-in), all at
-- once in the background: Net.online, then done().
function Net.ping(hosts, done)
    local list = {}
    for __, h in ipairs(hosts) do list[#list + 1] = { id = h.id, address = h.address, port = tonumber(h.port) or 22 } end
    if #list == 0 then return done and done() end
    Bg.run(function()
        local socket = require("socket")
        local out = {}
        for __, h in ipairs(list) do
            local tcp = socket.tcp()
            tcp:settimeout(2)
            local ok = tcp:connect(h.address, h.port)
            tcp:close()
            out[h.id] = ok and true or false
        end
        return out
    end, function(r)
        local now = os.time()
        for id, ok in pairs(r or {}) do Net.online[id] = { ok = ok, at = now } end
        if done then done() end
    end, { limit = 3 * #list + 5 })
end

-- ------------------------------------------------------------------ Wake on LAN

--- The magic packet to wake a host (its MAC, read with its status), to
-- the whole network and to its address's /24. True when sent, or nil, why.
function Net.wake(host)
    local mac = host.mac or (host.last and host.last.v and host.last.v.mac)
    local packet = S.magicPacket(mac)
    if not packet then return nil, _("Its MAC address isn't known yet: connect once while it's on.") end
    local socket = require("socket")
    local udp = socket.udp()
    if not udp then return nil, _("Can't send.") end
    udp:setoption("broadcast", true)
    local sent = false
    for __, to in ipairs({ "255.255.255.255", (host.last and host.last.v and host.last.v.ip or host.address or ""):match("^(%d+%.%d+%.%d+%.)%d+$") }) do
        if to then
            if to:sub(-1) == "." then to = to .. "255" end
            if udp:sendto(packet, to, 9) then sent = true end
        end
    end
    udp:close()
    if not sent then return nil, _("Can't send.") end
    return true
end

-- ------------------------------------------------------------------ checks

-- Failed checks in a row that pause a host's checks.
Net.PAUSE_AFTER = 3

-- Every how many minutes (0: off): the host's own, or every host's.
function Net.every(plugin, host)
    return M.checkEvery(host, plugin.store.data.check_every)
end

--- The checks: one timer, set for the next time a host is due (not every
-- minute), and only while some host can be checked. Called at the start and
-- after every change (plugin:saved()), so it follows the hosts and settings.
function Net.start(plugin)
    if Net.task then UIManager:unschedule(Net.task) end
    Net.task = nil
    local left = M.nextCheckIn(plugin.store.data.hosts, plugin.store.data.check_every, os.time(),
        function(h) return Net.quiet(plugin, h) end)
    if not left then return end
    Net.task = function()
        Net.task = nil
        Net.tick(plugin)
        Net.start(plugin)
    end
    -- (at least a minute: a check that can't run now, Wi-Fi off, comes back then)
    UIManager:scheduleIn(math.max(60, left), Net.task)
end

function Net.tick(plugin)
    if not (NetworkMgr:isWifiOn() and NetworkMgr:isConnected()) then return end
    local now = os.time()
    local due = {}
    for __, h in ipairs(plugin.store.data.hosts) do
        local every = Net.every(plugin, h)
        -- (a failed read waits its turn too; a paused host waits for you)
        local since = math.max(h.last and h.last.at or 0, h.failedAt or 0)
        if every and every > 0 and not h.paused and now - since >= every * 60 and Net.quiet(plugin, h) then
            due[#due + 1] = h
        end
    end
    -- one at a time (a Kindle's Wi-Fi and memory are small)
    local i = 0
    local function next()
        i = i + 1
        local h = due[i]
        if not h then
            local UI = require("sshui")
            if UI.refreshMain then UI.refreshMain(plugin) end
            return
        end
        Net.status(plugin, h, function(v)
            if not v then Net.online[h.id] = { ok = false, at = os.time() } end
            next()
        end, { auto = true })
    end
    if #due > 0 then
        logger.info("SSH: checking", #due, "hosts")
        next()
    end
end

return Net
