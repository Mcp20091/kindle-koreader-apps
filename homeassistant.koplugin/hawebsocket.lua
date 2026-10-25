--[[--
One request over Home Assistant's WebSocket API (what its REST API does not
have, such as the persistent notifications): connect, sign in with the
token, send the request, return its result, close. Blocking: run it in the
background (main.lua's child processes).

Plain LuaSocket and LuaSec (KOReader has both), text frames only.
]]

local bit = require("bit")
local socket = require("socket")

local WS = {}

local function b64(s)
    local mime = require("mime")
    return (mime.b64(s))
end

-- base ("http://host:8123", "https://host/prefix") -> host, port, path, secure
local function parse(base)
    local scheme, rest = base:match("^(https?)://(.+)$")
    if not scheme then return nil end
    local hostport, prefix = rest:match("^([^/]+)(.*)$")
    local host, port = hostport:match("^(.-):(%d+)$")
    host = host or hostport
    port = tonumber(port) or (scheme == "https" and 443 or 80)
    prefix = (prefix or ""):gsub("/+$", "")
    return host, port, prefix .. "/api/websocket", scheme == "https"
end

local function sendFrame(sock, text)
    local len = #text
    local head = { string.char(0x81) }
    if len < 126 then
        table.insert(head, string.char(bit.bor(0x80, len)))
    elseif len < 65536 then
        table.insert(head, string.char(0x80 + 126, bit.rshift(len, 8), bit.band(len, 0xFF)))
    else
        table.insert(head, string.char(0x80 + 127, 0, 0, 0, 0,
            bit.band(bit.rshift(len, 24), 0xFF), bit.band(bit.rshift(len, 16), 0xFF),
            bit.band(bit.rshift(len, 8), 0xFF), bit.band(len, 0xFF)))
    end
    local mask = { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
    table.insert(head, string.char(mask[1], mask[2], mask[3], mask[4]))
    local out = {}
    for i = 1, len do
        out[i] = string.char(bit.bxor(text:byte(i), mask[(i - 1) % 4 + 1]))
    end
    return sock:send(table.concat(head) .. table.concat(out))
end

-- One whole message (continuations joined; pings answered), or nil, why.
local function receive(sock)
    local parts = {}
    while true do
        local h, err = sock:receive(2)
        if not h then return nil, err end
        local b1, b2 = h:byte(1, 2)
        local fin, op = bit.band(b1, 0x80) ~= 0, bit.band(b1, 0x0F)
        local len = bit.band(b2, 0x7F)
        if len == 126 then
            local e = sock:receive(2)
            if not e then return nil, "closed" end
            len = e:byte(1) * 256 + e:byte(2)
        elseif len == 127 then
            local e = sock:receive(8)
            if not e then return nil, "closed" end
            len = 0
            for i = 1, 8 do len = len * 256 + e:byte(i) end
        end
        local masked = bit.band(b2, 0x80) ~= 0
        local mask = masked and sock:receive(4) or nil
        local data = ""
        if len > 0 then
            data = sock:receive(len)
            if not data then return nil, "closed" end
        end
        if mask then
            local out = {}
            for i = 1, #data do out[i] = string.char(bit.bxor(data:byte(i), mask:byte((i - 1) % 4 + 1))) end
            data = table.concat(out)
        end
        if op == 0x8 then return nil, "closed" end
        if op == 0x9 then
            -- A pong carries the ping's data back (masked: from a client).
            local out = { string.char(0x8A, bit.bor(0x80, #data), 0, 0, 0, 0) }
            if #data < 126 then sock:send(table.concat(out) .. data) end
        elseif op == 0x1 or op == 0x0 then
            table.insert(parts, data)
            if fin then return table.concat(parts) end
        end
    end
end

--- The result of one `request` ({ type = ..., ... }) at `base` with `token`:
-- result, or nil, kind ("unreachable", "signin", "failed").
function WS.exchange(base, token, request, timeout)
    local json = require("json")
    local host, port, path, secure = parse(base)
    if not host then return nil, "unreachable" end
    local sock = socket.tcp()
    sock:settimeout(timeout or 15)
    local ok = sock:connect(host, port)
    if not ok then sock:close() return nil, "unreachable" end
    if secure then
        local ssl = require("ssl")
        local wrapped = ssl.wrap(sock, { mode = "client", protocol = "any", verify = "none", options = { "all" } })
        if not wrapped then sock:close() return nil, "unreachable" end
        sock = wrapped
        sock:settimeout(timeout or 15)
        if sock.sni then sock:sni(host) end
        if not sock:dohandshake() then sock:close() return nil, "unreachable" end
    end
    local key = b64(string.char(math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255),
        math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255),
        math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255),
        math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255)))
    local hostHeader = host .. ((port == 80 or port == 443) and "" or (":" .. port))
    sock:send("GET " .. path .. " HTTP/1.1\r\nHost: " .. hostHeader .. "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ..
        "Sec-WebSocket-Key: " .. key .. "\r\nSec-WebSocket-Version: 13\r\n\r\n")
    local status = sock:receive("*l")
    if not status or not status:find(" 101") then sock:close() return nil, "failed" end
    repeat
        local line = sock:receive("*l")
        if not line then sock:close() return nil, "failed" end
    until line == ""
    local function close(...) pcall(function() sock:close() end) return ... end
    local msg = receive(sock)
    local m = msg and json.decode(msg)
    if not (m and m.type == "auth_required") then return close(nil, "failed") end
    sendFrame(sock, json.encode({ type = "auth", access_token = token }))
    msg = receive(sock)
    m = msg and json.decode(msg)
    if not m or m.type == "auth_invalid" then return close(nil, "signin") end
    if m.type ~= "auth_ok" then return close(nil, "failed") end
    request.id = 1
    sendFrame(sock, json.encode(request))
    for _ = 1, 20 do
        msg = receive(sock)
        if not msg then return close(nil, "failed") end
        m = json.decode(msg)
        if type(m) == "table" and m.id == 1 and m.type == "result" then
            if m.success then return close(m.result) end
            return close(nil, "failed")
        end
    end
    return close(nil, "failed")
end

return WS
