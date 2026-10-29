--[[--
Syncthing's status as words, in plain Lua for the tests: a folder's state,
a device's, the line for the launcher, sizes and times. Reads the tables
Syncthing's REST API returns (db/status, system/connections, stats/...) and
its config.xml.
]]

local M = {}

-- Gettext when inside KOReader; the words themselves in the tests.
local ok, gettext = pcall(require, "gettext")
local _ = ok and gettext or function(s) return s end
local function T(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end
local function N(one, many, n) return n == 1 and one or many end

--- "1.8 GB", "212 MB", "18 KB", "0 B".
function M.bytes(n)
    n = tonumber(n) or 0
    local units = { "B", "KB", "MB", "GB", "TB" }
    local i = 1
    while n >= 1000 and i < #units do
        n = n / 1000
        i = i + 1
    end
    if i == 1 then return string.format("%d B", n) end
    return (n < 10 and string.format("%.1f", n) or string.format("%d", math.floor(n + 0.5))) .. " " .. units[i]
end

--- Seconds since 1970 (UTC) for Syncthing's times ("2026-10-22T09:26:40.123-04:00"
-- or "...Z"); nil for none (Syncthing's zero time is year 1).
function M.parseTime(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, sec, rest = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)[%.%d]*(.*)$")
    if not y or tonumber(y) < 1970 then return nil end
    -- Days since 1970 for the date (proleptic Gregorian), so no local time zone gets in.
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    local a = mo <= 2 and 1 or 0
    local yy, mm = y - a, mo + 12 * a - 3
    local days = d + math.floor((153 * mm + 2) / 5) + 365 * yy + math.floor(yy / 4) - math.floor(yy / 100) + math.floor(yy / 400) - 719469
    local t = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
    local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
    if sign then
        local off = tonumber(oh) * 3600 + tonumber(om) * 60
        t = sign == "+" and t - off or t + off
    end
    return t
end

-- Whether times are 24-hour when not said (set from KOReader's clock setting).
M.twentyFour = false

--- A time of day: "8:14 PM", or "20:14" with twentyFour (KOReader's clock setting).
function M.clock(t, twentyFour, date)
    date = date or os.date
    if twentyFour == nil then twentyFour = M.twentyFour end
    if twentyFour then return date("%H:%M", t) end
    return (date("%I:%M %p", t):gsub("^0", ""))
end

--- "Just now", "10 min ago", "3 h ago", "Oct 21, 8:14 PM" (then: now, the
-- local-time formatter, os.date in KOReader, and whether the clock is 24-hour).
function M.ago(t, now, date, twentyFour)
    if not t then return nil end
    local s = now - t
    if s < 60 then return _("Just now") end
    if s < 3600 then return T(_("%1 min ago"), math.floor(s / 60)) end
    if s < 6 * 3600 then return T(_("%1 h ago"), math.floor(s / 3600)) end
    date = date or os.date
    return (date("%b %d", t):gsub(" 0", " ")) .. ", " .. M.clock(t, twentyFour, date)
end

--- The first part of a device ID ("7QK3MZB").
function M.shortId(id)
    return type(id) == "string" and (id:match("^([^-]+)") or id) or ""
end

-- How far a folder is in sync (0..1), from db/status.
function M.progress(st)
    local g = tonumber(st and st.globalBytes) or 0
    if g <= 0 then return 1 end
    return math.max(0, math.min(1, (tonumber(st.inSyncBytes) or 0) / g))
end

-- Files still to come or go, from db/status.
function M.need(st)
    if not st then return 0 end
    return (tonumber(st.needFiles) or 0) + (tonumber(st.needDeletes) or 0) + (tonumber(st.needSymlinks) or 0)
        + (tonumber(st.needDirectories) or 0)
end

--- A folder's state in words, and whether it is busy (syncing or scanning):
-- "Up to date", "Syncing 42%", "Scanning", "Paused", "Error", "Waiting to sync".
function M.folderState(folder, st)
    if folder and folder.paused then return _("Paused"), false end
    if not st then return _("Unknown"), false end
    local s = st.state or ""
    if s == "syncing" then return T(_("Syncing %1%"), math.floor(M.progress(st) * 100)), true end
    if s == "scanning" then return _("Scanning"), true end
    if s == "sync-preparing" then return _("Preparing to sync"), true end
    if s == "sync-waiting" then return _("Waiting to sync"), true end
    if s == "scan-waiting" then return _("Waiting to scan"), true end
    if s == "cleaning" or s == "clean-waiting" then return _("Cleaning up"), true end
    if s == "error" then return _("Error"), false end
    if (tonumber(st.pullErrors) or 0) > 0 or (tonumber(st.errors) or 0) > 0 then return _("Out of sync"), false end
    if M.need(st) > 0 then return _("Out of sync"), false end
    if s == "idle" then return _("Up to date"), false end
    return s, false
end

--- A device's line: "Connected · 100%", "Paused", "Last seen Oct 21, 8:14 PM", "Never seen".
function M.deviceState(device, conn, completion, lastSeen, now, date)
    if device and device.paused then return _("Paused"), false end
    if conn and conn.connected then
        local pct = completion and tonumber(completion.completion)
        -- (nothing shared with it yet: no percentage)
        if completion and (tonumber(completion.globalBytes) or 0) == 0 and (tonumber(completion.needItems) or 0) == 0 then pct = nil end
        return pct and T(_("Connected · %1%"), math.floor(pct)) or _("Connected"), true
    end
    local seen = M.ago(lastSeen, now, date)
    if seen == _("Just now") then return _("Last seen just now"), false end
    return seen and T(_("Last seen %1"), seen) or _("Never seen"), false
end

--- The line under "Syncthing" (and on the launcher's tile, after "On · "):
-- what the folders are doing first, then the devices.
-- snap: { folders = { { folder, status } }, connected, deviceCount }
function M.summary(snap)
    if not snap then return _("Starting…") end
    local busy, need, errors, paused, active = nil, 0, nil, 0, 0
    for __, f in ipairs(snap.folders or {}) do
        local st = f.status
        if f.folder.paused then
            paused = paused + 1
        else
            active = active + 1
            if st and (st.state == "syncing" or st.state == "sync-preparing") then
                busy = busy or f
                need = need + M.need(st)
            elseif st and st.state == "scanning" and not busy then
                busy = f
            elseif st and (st.state == "error" or (tonumber(st.pullErrors) or 0) > 0) then
                errors = errors or f
            end
        end
    end
    if busy and busy.status.state == "scanning" and need == 0 then
        return T(_("Scanning %1"), busy.folder.label)
    end
    if busy then
        if need > 0 then return T(N(_("Syncing · 1 file left"), _("Syncing · %1 files left"), need), need) end
        return _("Syncing")
    end
    if errors then return T(_("Errors in %1"), errors.folder.label) end
    if active == 0 and paused > 0 then return _("All folders paused") end
    if (snap.deviceCount or 0) > 0 and (snap.connected or 0) == 0 then return _("No devices connected") end
    if active == 0 then return _("No folders yet") end
    return _("Up to date")
end

--- Whether everything is up to date: at least one folder that isn't paused and every one of
-- those idle with nothing left to get or send, and at least one connected device (not paused)
-- and every one of those with nothing left to get. snap as API:snapshot makes it. Used by
-- "Turn off when up to date".
function M.allInSync(snap)
    if type(snap) ~= "table" then return false end
    local folders, devices = 0, 0
    for __, f in ipairs(snap.folders or {}) do
        if not f.folder.paused then
            local st = f.status
            if not st or st.state ~= "idle" or M.need(st) > 0 then return false end
            if (tonumber(st.pullErrors) or 0) > 0 or (tonumber(st.errors) or 0) > 0 then return false end
            folders = folders + 1
        end
    end
    for __, d in ipairs(snap.devices or {}) do
        if not (d.device and d.device.paused) and d.conn and d.conn.connected then
            -- (a connected device whose progress wasn't read is not known to be done)
            local c = d.completion
            if not c or (tonumber(c.needItems) or 0) > 0 or (tonumber(c.needBytes) or 0) > 0 then return false end
            devices = devices + 1
        end
    end
    return folders > 0 and devices > 0
end

--- A port Syncthing's web GUI can use (1024 to 65535) as a whole number, or nil.
function M.validPort(v)
    local n = tonumber(v)
    if not n or n ~= math.floor(n) or n < 1024 or n > 65535 then return nil end
    return n
end

--- The launcher's line: "On · Up to date", "On · Syncing · 3 files left", "Off".
function M.appsLine(running, snap)
    if not running then return _("Off") end
    return T(_("On · %1"), M.summary(snap))
end

--- "1 of 2 devices connected".
function M.devicesLine(connected, total)
    if total == 0 then return _("No devices yet") end
    return T(_("%1 of %2 connected"), connected, total)
end

-- ------------------------------------------------------------------ config.xml

local function attrs(s)
    local out = {}
    for k, v in s:gmatch('([%w_]+)="([^"]*)"') do
        out[k] = v:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    end
    return out
end

--- What config.xml says while Syncthing is off: { apikey, folders = { { id, label, path, paused } },
-- devices = { { deviceID, name, paused } } } (this Kindle itself left out).
function M.parseConfig(xml, myId)
    if type(xml) ~= "string" then return nil end
    local cfg = { folders = {}, devices = {} }
    cfg.apikey = xml:match("<gui[^>]*>.-<apikey>([^<]*)</apikey>")
    -- The defaults (an empty folder and device) are not real ones.
    local body = xml:gsub("<defaults>.-</defaults>", "")
    for a, inner in body:gmatch("<folder%s([^>]*)>(.-)</folder>") do
        local f = attrs(a)
        if f.id and f.id ~= "" then
            table.insert(cfg.folders, { id = f.id, label = f.label ~= "" and f.label or f.id, path = f.path,
                paused = inner:match("<paused>true</paused>") ~= nil })
        end
    end
    -- Devices outside the folders (inside them they are only who it is shared with).
    local rest = body:gsub("<folder%s.-</folder>", "")
    for a, inner in rest:gmatch("<device%s([^>]*)>(.-)</device>") do
        local d = attrs(a)
        if d.id and d.id ~= "" and d.id ~= myId then
            table.insert(cfg.devices, { deviceID = d.id, name = d.name ~= "" and d.name or M.shortId(d.id),
                paused = inner:match("<paused>true</paused>") ~= nil })
        end
    end
    return cfg
end

--- Where a shared folder goes on the Kindle: the home folder plus its label
-- (characters a folder name cannot have replaced).
function M.folderPath(home, label)
    home = (home or "/"):gsub("/+$", "")
    local name = tostring(label or "Sync"):gsub("[/\\:*?\"<>|]", "_")
    if name == "" or name == "." or name == ".." then name = "Sync" end
    return home .. "/" .. name
end

return M
