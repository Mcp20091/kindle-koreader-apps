--[[--
Syncthing's REST API on this Kindle (http://127.0.0.1:<port>/rest/...), with
the API key from its config.xml. Calls are short (Syncthing is on the same
Kindle), so they block for at most a few seconds.
]]

local JSON = require("json")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local M = require("stmodel")

local API = {}
API.__index = API

--- An API for Syncthing's config folder (config.xml in it) and GUI port.
function API.new(dir, port)
    return setmetatable({ dir = dir, port = port }, API)
end

--- config.xml read as a table (M.parseConfig), cached until the file changes.
function API:config(myId)
    local path = self.dir .. "/config.xml"
    local mtime = lfs.attributes(path, "modification")
    if not mtime then return nil end
    if self.cfg and self.cfgTime == mtime and self.cfgId == myId then return self.cfg end
    local f = io.open(path, "r")
    if not f then return nil end
    local xml = f:read("*a")
    f:close()
    self.cfg, self.cfgTime, self.cfgId = M.parseConfig(xml, myId), mtime, myId
    return self.cfg
end

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end
API.urlencode = urlencode

--- A call: method, path after /rest/ (query included), a table to send as
-- JSON. Returns the decoded answer (true for an empty one), or nil and an error.
function API:call(method, path, body)
    local cfg = self:config()
    if not (cfg and cfg.apikey) then return nil, "no API key" end
    local sink = {}
    local data = body ~= nil and JSON.encode(body) or nil
    socketutil:set_timeout(2, 6)
    local code, headers, status = socket.skip(1, http.request({
        url = string.format("http://127.0.0.1:%s/rest/%s", self.port, path),
        method = method,
        source = data and ltn12.source.string(data) or nil,
        sink = ltn12.sink.table(sink),
        headers = {
            ["X-API-Key"] = cfg.apikey,
            ["Content-Type"] = "application/json",
            ["Content-Length"] = data and tostring(#data) or nil,
        },
    }))
    socketutil:reset_timeout()
    local text = table.concat(sink)
    if code ~= 200 then
        logger.dbg("Syncthing:", method, path, code, status, text)
        return nil, (text ~= "" and text:gsub("%s+$", "")) or tostring(status or code)
    end
    if text == "" then return true end
    local ok, result = pcall(JSON.decode, text)
    if not ok then return true end
    return result
end

function API:get(path) return self:call("GET", path) end
function API:post(path, body) return self:call("POST", path, body) end

--- Whether Syncthing answers yet.
function API:ping()
    local r = self:get("system/ping")
    return type(r) == "table" and r.ping == "pong"
end

--- Everything the screens show, at once:
-- { myId, folders = { { folder, status, stats } }, devices = { { device, conn, completion, lastSeen } },
--   connected, pendingDevices = { { id, name, address } }, pendingFolders = { { id, label, from, fromName } } }
-- nil (and an error) when Syncthing doesn't answer.
function API:snapshot()
    local status, err = self:get("system/status")
    if type(status) ~= "table" then return nil, err end
    local config = self:get("config")
    if type(config) ~= "table" then return nil, "no config" end
    local conns = (self:get("system/connections") or {}).connections or {}
    local devStats = self:get("stats/device") or {}
    local folderStats = self:get("stats/folder") or {}
    local snap = { myId = status.myID, folders = {}, devices = {}, connected = 0, pendingDevices = {}, pendingFolders = {},
        uptime = status.uptime }
    local names = {}
    for __, d in ipairs(config.devices or {}) do
        names[d.deviceID] = d.name ~= "" and d.name or M.shortId(d.deviceID)
        if d.deviceID == status.myID then
            snap.myName = d.name
        else
            local conn = conns[d.deviceID]
            local completion = conn and conn.connected and self:get("db/completion?device=" .. urlencode(d.deviceID)) or nil
            local seen = devStats[d.deviceID]
            table.insert(snap.devices, { device = d, name = names[d.deviceID], conn = conn,
                completion = type(completion) == "table" and completion or nil,
                lastSeen = seen and M.parseTime(seen.lastSeen) })
            if conn and conn.connected then snap.connected = snap.connected + 1 end
        end
    end
    for __, f in ipairs(config.folders or {}) do
        local st = not f.paused and self:get("db/status?folder=" .. urlencode(f.id)) or nil
        local shared = {}
        for __, d in ipairs(f.devices or {}) do
            if d.deviceID ~= status.myID then table.insert(shared, names[d.deviceID] or M.shortId(d.deviceID)) end
        end
        if not f.label or f.label == "" then f.label = f.id end
        table.insert(snap.folders, { folder = f, status = type(st) == "table" and st or nil, stats = folderStats[f.id],
            shared = shared })
    end
    local pd = self:get("cluster/pending/devices")
    for id, d in pairs(type(pd) == "table" and pd or {}) do
        table.insert(snap.pendingDevices, { id = id, name = d.name ~= "" and d.name or nil, address = d.address,
            time = M.parseTime(d.time) })
    end
    local pf = self:get("cluster/pending/folders")
    for id, f in pairs(type(pf) == "table" and pf or {}) do
        for from, offer in pairs(f.offeredBy or {}) do
            table.insert(snap.pendingFolders, { id = id, label = offer.label ~= "" and offer.label or id, from = from,
                fromName = names[from] or M.shortId(from), time = M.parseTime(offer.time) })
        end
    end
    table.sort(snap.pendingDevices, function(a, b) return (a.time or 0) < (b.time or 0) end)
    table.sort(snap.pendingFolders, function(a, b) return (a.time or 0) < (b.time or 0) end)
    snap.deviceCount = #snap.devices
    snap.config = config
    -- (whether the web GUI has a password; the password itself is not kept)
    snap.passwordSet = type(config.gui) == "table" and type(config.gui.password) == "string" and config.gui.password ~= ""
    return snap
end

-- ------------------------------------------------------------------ actions

function API:rescan(folderId)
    return self:post(folderId and ("db/scan?folder=" .. urlencode(folderId)) or "db/scan")
end

function API:pauseFolder(id, paused)
    return self:call("PATCH", "config/folders/" .. urlencode(id), { paused = paused })
end

function API:pauseDevice(id, paused)
    return self:call("PATCH", "config/devices/" .. urlencode(id), { paused = paused })
end

function API:acceptDevice(id, name)
    return self:post("config/devices", { deviceID = id, name = name })
end

--- Never ask again about this device (Syncthing's Ignore).
function API:ignoreDevice(id, name, address)
    local config = self:get("config")
    if type(config) ~= "table" then return nil, "no config" end
    config.remoteIgnoredDevices = config.remoteIgnoredDevices or {}
    table.insert(config.remoteIgnoredDevices, { deviceID = id, name = name or "", address = address or "",
        time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
    return self:call("PUT", "config", config)
end

--- Ask about this device again (Undo after Ignore).
function API:unignoreDevice(id)
    local config = self:get("config")
    if type(config) ~= "table" then return nil, "no config" end
    local kept = {}
    for __, d in ipairs(config.remoteIgnoredDevices or {}) do
        if d.deviceID ~= id then table.insert(kept, d) end
    end
    -- (an empty list must go as [], not {})
    config.remoteIgnoredDevices = JSON.util and JSON.util.InitArray and JSON.util.InitArray(kept) or kept
    return self:call("PUT", "config", config)
end

--- Add a folder a device offers, at `path` on the Kindle, shared back with it.
function API:acceptFolder(id, label, path, from, myId)
    local folder = self:get("config/defaults/folder")
    if type(folder) ~= "table" then folder = { type = "sendreceive", filesystemType = "basic" } end
    folder.id, folder.label, folder.path = id, label, path
    folder.devices = { { deviceID = myId }, { deviceID = from } }
    folder.paused = false
    return self:post("config/folders", folder)
end

--- Never ask again about this folder from this device (Syncthing's Ignore).
function API:ignoreFolder(id, label, from)
    local device = self:get("config/devices/" .. urlencode(from))
    if type(device) ~= "table" then return nil, "no such device" end
    local ignored = device.ignoredFolders or {}
    table.insert(ignored, { id = id, label = label or "", time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
    return self:call("PATCH", "config/devices/" .. urlencode(from), { ignoredFolders = ignored })
end

--- Ask about this folder from this device again (Undo after Ignore).
function API:unignoreFolder(id, from)
    local device = self:get("config/devices/" .. urlencode(from))
    if type(device) ~= "table" then return nil, "no such device" end
    local kept = {}
    for __, f in ipairs(device.ignoredFolders or {}) do
        if f.id ~= id then table.insert(kept, f) end
    end
    if JSON.util and JSON.util.InitArray then kept = JSON.util.InitArray(kept) end
    return self:call("PATCH", "config/devices/" .. urlencode(from), { ignoredFolders = kept })
end

--- The web GUI's user and password (Syncthing keeps it hashed).
function API:setPassword(password)
    return self:call("PATCH", "config/gui", { user = "syncthing", password = password })
end

return API
