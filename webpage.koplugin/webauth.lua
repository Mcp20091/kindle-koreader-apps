--[[--
An optional password for the web page: set on the Kindle (Web server menu) or
on the page itself. Kept as a salted hash in koreader/settings/webpage.lua,
never the password. With one set, every page and /api route asks for it: a
small login page gives the browser a session cookie. With "Stay signed in"
the session is kept (as a hash, for 90 days) and survives KOReader
restarting; without it, it ends when KOReader does. A wrong password makes
the next try wait a few seconds (without holding up the Kindle).

The page is plain HTTP on the home network: this keeps casual visitors out,
it is not encryption.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Auth = {}

local ROUNDS = 2000
local WAIT = 3            -- seconds before another try after a wrong password
local KEEP = 90 * 86400   -- how long "Stay signed in" lasts
local sessions = {}       -- cookie value -> last used (this run of KOReader)
local lastFail = {}       -- address -> when

local store
local function settings()
    store = store or LuaSettings:open(DataStorage:getSettingsDir() .. "/webpage.lua")
    return store
end

local function hash(salt, password)
    local sha = require("ffi/sha2")
    local h = salt .. "\0" .. password
    for _ = 1, ROUNDS do h = sha.sha256(salt .. h) end
    return h
end

local function random(n)
    local out = {}
    local f = io.open("/dev/urandom", "rb")
    local bytes = f and f:read(n)
    if f then f:close() end
    for i = 1, n do
        local b = bytes and bytes:byte(i) or math.random(0, 255)
        out[i] = string.format("%02x", b)
    end
    return table.concat(out)
end

function Auth.isSet()
    return settings():readSetting("pw_hash") ~= nil
end

-- The kept sessions ("Stay signed in"): sha256(token) -> when it ends.
local function kept()
    local t = settings():readSetting("sessions") or {}
    local now, changed = os.time(), false
    for k, until_ in pairs(t) do
        if type(until_) ~= "number" or until_ < now then t[k] = nil changed = true end
    end
    if changed then settings():saveSetting("sessions", t) settings():flush() end
    return t
end

local function tokenHash(token) return require("ffi/sha2").sha256("kosess" .. token) end

--- Sets the password (and forgets every session: everyone signs in again).
function Auth.set(password)
    local salt = random(16)
    settings():saveSetting("pw_salt", salt)
    settings():saveSetting("pw_hash", hash(salt, password))
    settings():delSetting("sessions")
    settings():flush()
    sessions = {}
end

--- No password any more (Remove password on the Kindle, or Remove on the page).
function Auth.clear()
    settings():delSetting("pw_salt")
    settings():delSetting("pw_hash")
    settings():delSetting("sessions")
    settings():flush()
    sessions = {}
end

--- Whether `password` is the one set (true when none is set).
function Auth.check(password)
    if not Auth.isSet() then return true end
    local want = settings():readSetting("pw_hash")
    local got = hash(settings():readSetting("pw_salt") or "", tostring(password or ""))
    -- Compared whole, not stopping at the first difference.
    local diff = #want == #got and 0 or 1
    for i = 1, math.min(#want, #got) do
        if want:byte(i) ~= got:byte(i) then diff = 1 end
    end
    return diff == 0
end

--- A new session (kept across restarts when `remember`; Secure over HTTPS, `secure`); returns the Set-Cookie header value.
function Auth.newSession(remember, secure)
    local token = random(16)
    sessions[token] = os.time()
    if remember then
        local t = kept()
        t[tokenHash(token)] = os.time() + KEEP
        settings():saveSetting("sessions", t)
        settings():flush()
        return "kosess=" .. token .. "; Path=/; Max-Age=" .. KEEP .. "; HttpOnly; SameSite=Strict" .. (secure and "; Secure" or "")
    end
    return "kosess=" .. token .. "; Path=/; HttpOnly; SameSite=Strict"
end

function Auth.endSession(cookie)
    local token = cookie and cookie:match("kosess=(%x+)")
    if not token then return end
    sessions[token] = nil
    local t = kept()
    if t[tokenHash(token)] then
        t[tokenHash(token)] = nil
        settings():saveSetting("sessions", t)
        settings():flush()
    end
end

--- Whether the request's cookie is a session (always true with no password).
function Auth.signedIn(req)
    if not Auth.isSet() then return true end
    local token = req.headers.cookie and req.headers.cookie:match("kosess=(%x+)")
    if token and sessions[token] then
        sessions[token] = os.time()
        return true
    end
    -- Kept from before KOReader restarted ("Stay signed in").
    if token and kept()[tokenHash(token)] then
        sessions[token] = os.time()
        return true
    end
    return false
end

--- Too soon after a wrong password from `address`.
function Auth.tooSoon(address)
    local t = lastFail[address or ""]
    return t ~= nil and os.time() - t < WAIT
end

function Auth.failed(address)
    lastFail[address or ""] = os.time()
end

-- What can be fetched without signing in: the login page and its style.
local OPEN = { ["/login"] = true, ["/api/login"] = true, ["/static/app.css"] = true, ["/static/login.html"] = true,
    ["/static/manifest.webmanifest"] = true, ["/static/icon-192.png"] = true, ["/static/icon-512.png"] = true,
    ["/static/apple-touch-icon.png"] = true, ["/favicon.ico"] = true }

--- The server's guard: true when it answered (the login page, or "sign in first").
function Auth.guard(req, res, dir)
    if Auth.signedIn(req) or OPEN[req.path] then return false end
    if req.path:find("^/api/") then
        res:status(401):send(require("json").encode({ error = "Sign in first", login = true }), "application/json")
    else
        res:file(dir .. "login.html", "login.html", true)
    end
    return true
end

function Auth.routes(server, dir)
    server:route("GET", "^/login$", function(req, res) res:file(dir .. "login.html", "login.html", true) end)

    server:route("POST", "^/api/login$", function(req, res)
        local address = req.address
        if Auth.tooSoon(address) then return res:error(429, "Wait a moment and try again.") end
        local b = req.json()
        if not Auth.check(b.password) then
            Auth.failed(address)
            return res:error(403, "Wrong password.")
        end
        res:send(require("json").encode({ ok = true }), "application/json", { ["Set-Cookie"] = Auth.newSession(b.remember == true, req.secure) })
    end)

    server:route("POST", "^/api/logout$", function(req, res)
        Auth.endSession(req.headers.cookie)
        res:send(require("json").encode({ ok = true }), "application/json",
            { ["Set-Cookie"] = "kosess=; Path=/; Max-Age=0; SameSite=Strict" })
    end)

    -- On the page: { password } sets or changes it (this browser stays signed in), "" removes it.
    server:route("POST", "^/api/password$", function(req, res)
        local pw = req.json().password
        if type(pw) ~= "string" then return res:error(400, "No password") end
        if pw == "" then
            Auth.clear()
            return res:json({ ok = true, set = false })
        end
        if #pw < 4 then return res:error(400, "Use at least 4 characters.") end
        Auth.set(pw)
        res:send(require("json").encode({ ok = true, set = true }), "application/json", { ["Set-Cookie"] = Auth.newSession(true, req.secure) })
    end)

    server:route("GET", "^/api/password$", function(req, res) res:json({ set = Auth.isSet() }) end)
end

return Auth
