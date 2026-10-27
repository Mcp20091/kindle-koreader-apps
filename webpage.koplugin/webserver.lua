--[[--
A small HTTP server for KOReader, polled by UIManager between input events
(as the HTTP inspector plugin does): one request at a time, read, answered
and closed. Request bodies are read whole (up to MAX_BODY) unless the route
takes them as a stream (file uploads go straight to disk).

Routes: server:route("GET", "^/api/files$", function(req, res) ... end).
req: method, path, query (decoded), headers (lower case), body (string),
json() (the body decoded), read(n) for streamed bodies, length.
res: json(value), text(s, type), file(path, name, inline), redirect(url),
status(code) before any of those.
]]

local Event = require("ui/event")
local logger = require("logger")
local socket = require("socket")

local Server = {}
Server.__index = Server

local MAX_BODY = 4 * 1024 * 1024
local CHUNK = 64 * 1024

local REASONS = {
    [200] = "OK", [204] = "No Content", [302] = "Found", [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden", [429] = "Too Many Requests",
    [404] = "Not Found", [405] = "Method Not Allowed", [409] = "Conflict", [413] = "Payload Too Large",
    [500] = "Internal Server Error", [503] = "Service Unavailable",
}

local TYPES = {
    html = "text/html; charset=utf-8", css = "text/css; charset=utf-8", js = "application/javascript; charset=utf-8",
    json = "application/json; charset=utf-8", txt = "text/plain; charset=utf-8", svg = "image/svg+xml",
    png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg", gif = "image/gif", webp = "image/webp",
    pdf = "application/pdf", epub = "application/epub+zip", mobi = "application/x-mobipocket-ebook",
    azw3 = "application/vnd.amazon.ebook", cbz = "application/vnd.comicbook+zip", fb2 = "application/x-fictionbook+xml",
    lua = "text/plain; charset=utf-8", md = "text/plain; charset=utf-8", csv = "text/csv; charset=utf-8",
    zip = "application/zip", ico = "image/x-icon", woff2 = "font/woff2", ttf = "font/ttf", otf = "font/otf", ttc = "font/collection", webmanifest = "application/manifest+json",
    log = "text/plain; charset=utf-8",
}
Server.TYPES = TYPES

function Server.typeOf(name)
    local ext = (name:match("%.([%w]+)$") or ""):lower()
    return TYPES[ext] or "application/octet-stream"
end

local function unescape(s)
    s = s:gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
Server.unescape = unescape

function Server.parseQuery(q)
    local out = {}
    for pair in (q or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k and k ~= "" then out[unescape(k)] = unescape(v or "") end
    end
    return out
end

--- options: port, json (encode, decode), onStart(method, target) (a request begins),
-- onRequest() (each request answered: keeps the reader awake), tls (a LuaSec server
-- context: HTTPS, webtls.lua).
function Server.new(options)
    local self = setmetatable({}, Server)
    self.port = options.port or 8080
    self.tls = options.tls
    self.json = options.json
    self.onRequest = options.onRequest
    self.onStart = options.onStart
    self.routes = {}
    return self
end

--- stream: the handler reads the body itself (req:read).
function Server:route(method, pattern, handler, stream)
    table.insert(self.routes, { method = method, pattern = pattern, handler = handler, stream = stream })
end

function Server:start()
    local server, err = socket.bind("*", self.port)
    if not server then return false, err end
    server:settimeout(0)
    self.server = server
    return true
end

function Server:stop()
    for __, w in ipairs(self.waiting or {}) do w.client:close() end
    self.waiting = {}
    if self.server then self.server:close() end
    self.server = nil
end

-- ------------------------------------------------------------------ responses

local Response = {}
Response.__index = Response

function Response:status(code)
    self.code = code
    return self
end

--- Sends `data` (from byte `i` to `j`); false when the browser stops taking
-- it. The reader waits while this runs, so a browser that keeps the
-- connection but reads nothing (a phone gone to sleep) is given up on after
-- two timeouts in a row, not waited for forever.
local function sendAll(client, data, i, j)
    i, j = i or 1, j or #data
    local stalls = 0
    while i <= j do
        local last, err, partial = client:send(data, i, j)
        if last then
            i, stalls = last + 1, 0
        elseif err == "timeout" and partial and partial >= i then
            i, stalls = partial + 1, 0
        elseif err == "timeout" and stalls < 1 then
            stalls = stalls + 1
        else
            logger.warn("Web server: stopped sending,", err)
            return false
        end
    end
    return true
end

function Response:head(length, ctype, extra)
    local lines = { string.format("HTTP/1.1 %d %s", self.code, REASONS[self.code] or "OK") }
    if ctype then table.insert(lines, "Content-Type: " .. ctype) end
    if length then table.insert(lines, "Content-Length: " .. length) end
    table.insert(lines, "Cache-Control: no-store")
    table.insert(lines, "Connection: close")
    for k, v in pairs(extra or {}) do table.insert(lines, k .. ": " .. v) end
    table.insert(lines, "")
    table.insert(lines, "")
    self.sent = true
    self.broken = not sendAll(self.client, table.concat(lines, "\r\n"))
    return not self.broken
end

function Response:send(body, ctype, extra)
    body = body or ""
    if not self:head(#body, ctype, extra) then return end
    local i = 1
    while i <= #body do
        local j = math.min(#body, i + CHUNK - 1)
        if not sendAll(self.client, body, i, j) then return end
        i = j + 1
    end
end

function Response:json(value)
    self:send(self.server.json.encode(value), TYPES.json)
end

function Response:text(s, ctype)
    self:send(s, ctype or TYPES.txt)
end

function Response:error(code, message)
    self.code = code
    self:json({ error = message or REASONS[code] })
end

function Response:redirect(url)
    self.code = 302
    self:send("", TYPES.txt, { Location = url })
end

--- A file, streamed: downloaded (or shown in the browser when inline).
function Response:file(path, name, inline)
    local f = io.open(path, "rb")
    if not f then return self:error(404, "Not found") end
    local size = f:seek("end")
    f:seek("set", 0)
    name = name or path:match("[^/]+$")
    local disposition = (inline and "inline" or "attachment") .. "; filename*=UTF-8''" ..
        name:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)
    if not self:head(size, Server.typeOf(name), { ["Content-Disposition"] = disposition }) then
        f:close()
        return
    end
    while true do
        local data = f:read(CHUNK)
        if not data then break end
        if not sendAll(self.client, data) then
            f:close()
            return
        end
    end
    f:close()
end

-- ------------------------------------------------------------------ HTTPS

-- The first byte a connection sent, left for whoever reads next (recv with
-- MSG_PEEK): 22 starts a TLS hello; a letter, a plain HTTP request.
local peekBuf
local function firstByte(client)
    local ffi = require("ffi")
    if not peekBuf then
        pcall(ffi.cdef, "long recv(int sockfd, void *buf, unsigned long len, int flags);")
        peekBuf = ffi.new("unsigned char[1]")
    end
    local MSG_PEEK = 2
    local n = ffi.C.recv(client:getfd(), peekBuf, 1, MSG_PEEK)
    if n == 1 then return peekBuf[0] end
end

-- A plain HTTP request to the HTTPS server (an old bookmark, http:// typed): sent
-- on to the same address over https. 302, not 301: browsers keep a 301, and the
-- page must work over http again once HTTPS is turned off.
local function toHttps(client)
    client:settimeout(5)
    local line = client:receive("*l")
    local target = line and line:match("^%u+%s+(/%S*)") or "/"
    local host
    for __ = 1, 100 do
        local h = client:receive("*l")
        if not h or h == "" then break end
        host = host or h:match("^[Hh][Oo][Ss][Tt]:%s*(%S+)")
    end
    if not host then return end
    sendAll(client, "HTTP/1.1 302 Found\r\nLocation: https://" .. host .. target ..
        "\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
end

-- With HTTPS, each new connection: its first bytes looked at once they come (plain
-- HTTP is sent on to https), then the TLS handshake, a step each pass of the loop
-- (it never waits for the browser). Returns whether `w` is ready for its request.
function Server:tlsStep(w, readable)
    if w.fresh then
        if not readable then return false end
        w.fresh = nil
        local b = firstByte(w.client)
        if b ~= 22 then
            if b then pcall(toHttps, w.client) end
            w.done = true
            return false
        end
        w.client = require("ssl").wrap(w.client, self.tls)
        w.client:settimeout(0)
        w.hs = true
    end
    if w.hs then
        local ok, err = w.client:dohandshake()
        if ok then
            w.hs = nil
        elseif err ~= "wantread" and err ~= "wantwrite" then
            -- (A browser that hasn't accepted the certificate yet closes here.)
            w.done = true
        end
        return false
    end
    return readable or w.client:dirty()
end

-- ------------------------------------------------------------------ requests

-- Each loop of KOReader's event loop: new connections kept, and the ones
-- whose request has arrived answered (browsers also open spare connections
-- that send nothing; those must not hold the others up). Called as an
-- iterator (until it returns nil).
function Server:waitEvent()
    if not self.server then return nil end
    self.waiting = self.waiting or {}
    while true do
        local client = self.server:accept()
        if not client then break end
        client:settimeout(0)
        table.insert(self.waiting, { client = client, since = os.time(), address = (client:getpeername()), fresh = self.tls ~= nil })
    end
    -- (TLS handshakes move on every pass, even one that answers no request.)
    if self.tls then
        local sockets = {}
        for __, w in ipairs(self.waiting) do
            if w.fresh or w.hs then table.insert(sockets, w.client) end
        end
        local readable = #sockets > 0 and socket.select(sockets, nil, 0) or {}
        for i = #self.waiting, 1, -1 do
            local w = self.waiting[i]
            if w.fresh or w.hs then
                self:tlsStep(w, readable[w.client] ~= nil)
                if w.done then
                    table.remove(self.waiting, i)
                    w.client:close()
                end
            end
        end
    end
    -- One request per pass of KOReader's loop (it asks again until nil): taps
    -- and the screen get their turn between requests, even in a burst (the
    -- loop comes back within 50 ms while the server runs).
    if self.answered then
        self.answered = false
        return nil
    end
    if #self.waiting == 0 then return nil end
    local sockets = {}
    for __, w in ipairs(self.waiting) do
        if not (w.fresh or w.hs) then table.insert(sockets, w.client) end
    end
    local ready = #sockets > 0 and socket.select(sockets, nil, 0) or {}
    local now = os.time()
    for i = #self.waiting, 1, -1 do
        local w = self.waiting[i]
        -- (Over TLS, a request can be read already and waiting in LuaSec: dirty.)
        if not (w.fresh or w.hs) and (ready[w.client] or (self.tls and w.client:dirty())) then
            table.remove(self.waiting, i)
            w.client:settimeout(10)
            local ok, err = pcall(self.handle, self, w.client, w.address)
            if not ok then logger.warn("Web server:", err) end
            w.client:close()
            if self.onRequest then self.onRequest() end
            self.answered = true
            -- As a key press: resets the reader's sleep timers while the page is in use.
            return Event:new("InputEvent")
        elseif now - w.since > 30 then
            table.remove(self.waiting, i)
            w.client:close()
        end
    end
    return nil
end

--- `address`: the browser's (a TLS connection can't tell it).
function Server:handle(client, address)
    local line = client:receive("*l")
    if not line then return end
    local method, target = line:match("^(%u+)%s+(%S+)")
    if not method then return end
    if self.onStart then self.onStart(method, target) end
    local headers = {}
    -- At most 100 header lines, all within 20 s: a client trickling them in
    -- can't hold the reader.
    local by, count = os.time() + 20, 0
    while true do
        local h = client:receive("*l")
        if not h or h == "" then break end
        count = count + 1
        if count > 100 or os.time() > by then return end
        local k, v = h:match("^([^:]+):%s*(.*)$")
        if k then headers[k:lower()] = v end
    end
    local path, query = target:match("^([^?]*)%??(.*)$")
    local req = { method = method, path = unescape(path), query = Server.parseQuery(query), headers = headers,
        length = tonumber(headers["content-length"]) or 0, secure = self.tls ~= nil,
        address = address or (client.getpeername and client:getpeername()) }
    local res = setmetatable({ client = client, code = 200, server = self }, Response)
    -- A change sent by another website (a browser names it in Origin) is refused.
    if method ~= "GET" and method ~= "HEAD" and headers.origin and headers.host then
        local from = headers.origin:match("^%a+://([^/]+)")
        if from and from:lower() ~= headers.host:lower() then
            if req.length > 0 and req.length <= MAX_BODY then client:receive(req.length) end
            return res:error(403, "Not from this page")
        end
    end
    -- The password, when one is set: the login page, or "sign in first".
    if self.guard and self.guard(req, res) then
        if req.length > 0 and req.length <= MAX_BODY then client:receive(req.length) end
        return
    end
    local route, captures
    for __, r in ipairs(self.routes) do
        local m = { req.path:match(r.pattern) }
        if #m > 0 and (r.method == method or (r.method == "GET" and method == "HEAD")) then
            route, captures = r, m
            break
        end
    end
    if not route then
        -- Leftover body read and dropped, so the browser sees the answer.
        if req.length > 0 and req.length <= MAX_BODY then client:receive(req.length) end
        return res:error(404, "Not found")
    end
    req.captures = captures
    local remaining = req.length
    -- A body that comes slower than 1 KB in 20 s is given up on (the reader
    -- waits while it arrives; a trickle could hold it for ever).
    local since, got = os.time(), 0
    function req.read(_, n)
        if remaining <= 0 then return nil end
        local want = math.min(n or CHUNK, remaining)
        local data, rerr, partial = client:receive(want)
        data = data or partial
        if not data or #data == 0 then return nil, rerr end
        remaining = remaining - #data
        got = got + #data
        if os.time() - since >= 20 then
            if got < 1024 then
                logger.warn("Web server: upload too slow, stopped")
                remaining = 0
                return nil, "too slow"
            end
            since, got = os.time(), 0
        end
        return data
    end
    if not route.stream and req.length > 0 then
        if req.length > MAX_BODY then return res:error(413, "File too large") end
        local parts = {}
        while true do
            local chunk = req:read()
            if not chunk then break end
            table.insert(parts, chunk)
        end
        req.body = table.concat(parts)
    end
    function req.json()
        if not req.body or req.body == "" then return {} end
        local okj, value = pcall(self.json.decode, req.body)
        return okj and type(value) == "table" and value or {}
    end
    local okh, herr = pcall(route.handler, req, res)
    if not okh then
        logger.err("Web server:", req.method, req.path, herr)
        if not res.sent then res:error(500, tostring(herr)) end
    elseif not res.sent then
        res:status(204):send("")
    end
end

return Server
