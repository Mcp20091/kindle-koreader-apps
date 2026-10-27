--[[--
The printer's own HTTP API on the Wi-Fi (port 8898), the one the Home
Assistant integration and FlashForge's desktop app use: every request is a
POST of JSON with the printer's serial number and check code (from LAN-only
mode on its screen). Also its camera (MJPEG on port 8080) and finding
printers with a UDP broadcast.

Everything here blocks: it runs in a child process (ffbg.lua), never on
KOReader's loop. Answers come back as plain tables; pictures are written to
files (`dir`) and their paths returned.
]]

local JSON = require("json")

local M = require("ffmodel")

local API = {}
API.__index = API

--- cfg: { ip, serial, code }; dir: where pictures go (koreader/cache/flashforge).
function API.new(cfg, dir)
    return setmetatable({ ip = cfg.ip, serial = cfg.serial, code = cfg.code, dir = dir }, API)
end

--- A POST of `body` (the serial number and check code added) to path: the
-- decoded answer, or nil and why. timeout: seconds (8).
function API:post(path, body, timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    body = body or {}
    body.serialNumber, body.checkCode = self.serial, self.code
    local data = JSON.encode(body)
    local sink = {}
    socketutil:set_timeout(timeout or 8, (timeout or 8) + 4)
    local ok, r, code = pcall(http.request, {
        url = "http://" .. self.ip .. ":" .. M.PORT .. path, method = "POST",
        headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#data) },
        source = ltn12.source.string(data), sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if not ok then return nil, tostring(r) end
    if not r then return nil, tostring(code) end
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    -- (some printers send "appliation/json": the body is read whatever the header says)
    local okJ, t = pcall(JSON.decode, table.concat(sink))
    if not okJ or type(t) ~= "table" then return nil, "unreadable answer" end
    return t
end

--- Whether an answer says it worked (code 0, or 200 on some firmware).
local function fine(t)
    return t and (tonumber(t.code) == 0 or tonumber(t.code) == 200)
end

--- /detail: the printer's state ({ detail = … }), or nil and why. A wrong
-- serial number or check code is "signin".
function API:detail()
    local t, err = self:post("/detail")
    if not t then return nil, err end
    if not fine(t) then return nil, "signin", t.message end
    if type(t.detail) ~= "table" then return nil, "unreadable answer" end
    return t.detail
end

--- /product: what the printer says it can control ({ lightCtrlState, … }).
function API:product()
    local t, err = self:post("/product")
    if not t then return nil, err end
    if not fine(t) or type(t.product) ~= "table" then return nil, "signin" end
    return t.product
end

--- A command (/control): cmd and args, as the printer's API names them.
function API:control(cmd, args)
    local t, err = self:post("/control", { payload = { cmd = cmd, args = args or {} } })
    if not t then return nil, err end
    if not fine(t) then return nil, tostring(t.message or "refused") end
    return true
end

function API:job(action) return self:control("jobCtl_cmd", { jobID = "", action = action }) end
function API:light(on) return self:control("lightControl_cmd", { status = on and "open" or "close" }) end
function API:filtration(mode) return self:control("circulateCtl_cmd", M.filtrationArgs(mode)) end
function API:clearPlate() return self:control("stateCtrl_cmd", { action = "setClearPlatform" }) end

--- /gcodeList: the ten most recent files (ffmodel.files reads it).
function API:files()
    local t, err = self:post("/gcodeList")
    if not t then return nil, err end
    if not fine(t) then return nil, tostring(t.message or "refused") end
    t.code, t.message = nil, nil
    return t
end

-- Base64 to bytes (KOReader's own when it has it; LuaJIT's bit otherwise).
local B64 = {}
for k = 1, 64 do B64[("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"):byte(k)] = k - 1 end
local function unbase64(s)
    local okS, sha2 = pcall(require, "ffi/sha2")
    if okS and sha2 and sha2.base64_to_bin then
        local okD, bin = pcall(sha2.base64_to_bin, (s:gsub("[^%w%+/=]", "")))
        if okD and bin then return bin end
    end
    local bit = require("bit")
    local out, acc, n = {}, 0, 0
    for k = 1, #s do
        local v = B64[s:byte(k)]
        if v then
            acc = bit.bor(bit.lshift(acc, 6), v)
            n = n + 6
            if n >= 8 then
                n = n - 8
                out[#out + 1] = string.char(bit.band(bit.rshift(acc, n), 255))
                acc = bit.band(acc, bit.lshift(1, n) - 1)
            end
        end
    end
    return table.concat(out)
end
API.unbase64 = unbase64

local function write(path, bytes)
    local f = io.open(path, "wb")
    if not f then return nil, "can't write " .. path end
    f:write(bytes)
    f:close()
    return path
end

--- A file's thumbnail (/gcodeThumb), saved as `name` in dir: its path, or nil.
function API:thumbnail(fileName, name)
    local t, err = self:post("/gcodeThumb", { fileName = fileName })
    if not t then return nil, err end
    if not fine(t) or type(t.imageData) ~= "string" or t.imageData == "" then return nil, "no picture" end
    return write(self.dir .. "/" .. name, unbase64(t.imageData))
end

--- Start a file already on the printer (/printGcode): body from ffmodel.printBody.
function API:print(body)
    local t, err = self:post("/printGcode", body, 15)
    if not t then return nil, err end
    if not fine(t) then return nil, tostring(t.message or "refused") end
    return true
end

--- One picture from the camera, saved as `name` in dir: its path, or nil and
-- why. The stream is read until its first whole JPEG (the printers' camera
-- has no separate snapshot address that works on all of them).
function API:snapshot(name, url)
    local socket = require("socket")
    url = url ~= "" and url or ("http://" .. self.ip .. ":" .. M.CAMERA_PORT .. "/?action=stream")
    local host, port, path = url:match("^http://([^/:]+):?(%d*)(.*)$")
    if not host then return nil, "bad camera address" end
    port = tonumber(port) or 80
    if path == "" then path = "/" end
    local tcp = socket.tcp()
    tcp:settimeout(6)
    local okC, err = tcp:connect(host, port)
    if not okC then
        tcp:close()
        return nil, err
    end
    tcp:send("GET " .. path .. " HTTP/1.0\r\nHost: " .. host .. "\r\nUser-Agent: KOReader\r\n\r\n")
    local buf, started = {}, socket.gettime()
    local data = ""
    while socket.gettime() - started < 10 and #data < 3 * 1024 * 1024 do
        local chunk, e, partial = tcp:receive(16384)
        chunk = chunk or partial
        if chunk and chunk ~= "" then
            table.insert(buf, chunk)
            data = table.concat(buf)
            buf = { data }
            local a = data:find("\255\216", 1, true)
            local b = a and data:find("\255\217", a + 2, true)
            if b then
                tcp:close()
                return write(self.dir .. "/" .. name, data:sub(a, b + 1))
            end
        end
        if e == "closed" then break end
        if e and e ~= "timeout" then break end
    end
    tcp:close()
    return nil, #data == 0 and "no answer" or "no picture"
end

--- Printers on this Wi-Fi: { { name, ip, serial, pid, model, supported } }.
-- A broadcast to port 48899 (and the old ports), then answers for `seconds`.
-- port: the local port answers come to (opened in the Kindle's firewall by the caller).
function API.discover(seconds, port)
    local socket = require("socket")
    local udp = socket.udp()
    udp:setoption("broadcast", true)
    udp:setsockname("*", port or 0)
    udp:settimeout(0.25)
    local function send()
        for __, p in ipairs({ 48899, 8899, 19000 }) do pcall(udp.sendto, udp, "", "255.255.255.255", p) end
        pcall(udp.sendto, udp, "", "225.0.0.9", 8899)
        pcall(udp.sendto, udp, "", "225.0.0.9", 19000)
    end
    send()
    local found, seen = {}, {}
    local started, resent = socket.gettime(), false
    while socket.gettime() - started < (seconds or 4) do
        local data, ip = udp:receivefrom()
        if data and not seen[ip] then
            local p = M.parseDiscovery(data, ip)
            if p then
                seen[ip] = true
                table.insert(found, p)
            end
        elseif not resent and socket.gettime() - started > 1.5 then
            -- (once more: a printer may have missed the first)
            resent = true
            send()
        end
    end
    udp:close()
    table.sort(found, function(a, b) return a.name < b.name end)
    return found
end

return API
