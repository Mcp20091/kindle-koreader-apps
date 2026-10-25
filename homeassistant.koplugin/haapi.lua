--[[--
Home Assistant's REST API: signing in the way the phone app does (username,
password, then a two-step code if the account has one), or a long-lived
token; the home address tried first and the away one after; tokens kept
fresh; and the calls the plugin makes.

Network and JSON are passed in (`request`, `json`), so the tests can run it
without KOReader; main.lua passes KOReader's.
]]

local Model = require("hamodel")
local Template = require("hatemplate")

local Api = {}
Api.__index = Api

-- Who the plugin is to Home Assistant (shown under Profile > Security). The
-- redirect address shares its host, so Home Assistant needs to fetch nothing.
Api.CLIENT_ID = "https://koreader.rocks/homeassistant/"
Api.REDIRECT_URI = "https://koreader.rocks/homeassistant/"

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function form(fields)
    local parts = {}
    for k, v in pairs(fields) do table.insert(parts, urlencode(k) .. "=" .. urlencode(v)) end
    table.sort(parts)
    return table.concat(parts, "&")
end

--- An address as typed made usable: "ha.local:8123" -> "http://ha.local:8123".
function Api.cleanUrl(url)
    url = (url or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then return nil end
    if not url:find("^https?://") then url = "http://" .. url end
    return (url:gsub("/+$", ""))
end

--- options: settings (get, set, save), request(method, url, headers, body, timeout) returning
-- (status number or error string, body), json (encode, decode), now() (seconds).
function Api.new(options)
    local self = setmetatable({}, Api)
    self.settings = options.settings
    self.request = options.request
    -- One request over the WebSocket API (hawebsocket.lua; the tests and the
    -- emulator put a stand-in here).
    self.websocket = options.websocket or function(...) return require("hawebsocket").exchange(...) end
    self.json = options.json
    self.now = options.now or os.time
    return self
end

function Api:decode(body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, value = pcall(self.json.decode, body)
    if ok and type(value) == "table" then return value end
    return nil
end

function Api:get(key) return self.settings.get(key) end

--- Who the tokens were made for: the plugin, or the reader's web page when
-- signing in from a browser (refreshing must give the same).
function Api:clientId() return self:get("client_id") or Api.CLIENT_ID end
function Api:set(key, value) self.settings.set(key, value) end

--- The addresses to try: the one that answered last first.
function Api:addresses()
    local list = {}
    local home, away = self:get("home_url"), self:get("away_url")
    if home then table.insert(list, { "home", home }) end
    if away then table.insert(list, { "away", away }) end
    if #list == 2 and self:get("active") == "away" then list[1], list[2] = list[2], list[1] end
    return list
end

function Api:signedIn()
    return self:get("token") ~= nil or self:get("refresh_token") ~= nil
end

local ERRORS = {
    unreachable = "Can't reach Home Assistant. Check Wi-Fi and the addresses in Settings.",
    signin = "Your Home Assistant sign-in has expired. Sign in again in Settings.",
    notapi = "That address didn't return Home Assistant (it may be a proxy's login page). Check the address.",
    failed = "Home Assistant couldn't complete that.",
}
Api.ERRORS = ERRORS

local function fail(kind, detail)
    return nil, { kind = kind, message = ERRORS[kind] .. (detail and ("\n" .. detail) or "") }
end

local function looksLikeHtml(body)
    return type(body) == "string" and body:match("^%s*<") ~= nil
end

--- A fresh access token from the refresh token, at `base`.
function Api:refreshAt(base)
    local status, body = self.request("POST", base .. "/auth/token",
        { ["Content-Type"] = "application/x-www-form-urlencoded" },
        form{ grant_type = "refresh_token", refresh_token = self:get("refresh_token"), client_id = self:clientId() }, 15)
    if type(status) ~= "number" then return nil, "unreachable" end
    local data = self:decode(body)
    if status == 200 and data and data.access_token then
        self:set("access_token", data.access_token)
        self:set("expires_at", self.now() + (Model.num(data.expires_in) or 1800))
        self.settings.save()
        return data.access_token
    end
    if looksLikeHtml(body) or status >= 300 and status < 400 then return nil, "notapi" end
    if status == 400 or status == 401 or status == 403 then return nil, "signin" end
    return nil, "failed"
end

--- The bearer token for `base` (refreshed when it is about to run out).
function Api:tokenFor(base, force)
    local token = self:get("token")
    if token then return token end
    if not self:get("refresh_token") then return nil, "signin" end
    local access, expires = self:get("access_token"), self:get("expires_at") or 0
    if access and not force and expires - 60 > self.now() then return access end
    return self:refreshAt(base)
end

--- One call to Home Assistant at whichever address answers. Returns
-- status, body (any status Home Assistant gave) or nil, { kind, message }.
function Api:send(method, path, body, contentType, timeout)
    local addresses = self:addresses()
    if #addresses == 0 then return fail("unreachable", "No address set.") end
    local lastKind = "unreachable"
    for i, a in ipairs(addresses) do
        local name, base = a[1], a[2]
        local token, why = self:tokenFor(base)
        if not token then
            if why ~= "unreachable" then return fail(why) end
        else
            local headers = { Authorization = "Bearer " .. token }
            if body then headers["Content-Type"] = contentType or "application/json" end
            -- The home address gets a short wait (away from home it does not answer).
            local wait = timeout or ((name == "home" and i < #addresses) and 6 or 25)
            local status, data = self.request(method, base .. path, headers, body, wait)
            if status == 401 and not self:get("token") then
                token = self:tokenFor(base, true)
                if token then
                    headers.Authorization = "Bearer " .. token
                    status, data = self.request(method, base .. path, headers, body, wait)
                end
            end
            if type(status) == "number" then
                if self:get("active") ~= name then
                    self:set("active", name)
                    self.settings.save()
                end
                if status == 401 or status == 403 then return fail("signin") end
                if (status >= 300 and status < 400) or (looksLikeHtml(data) and status ~= 200) or
                        (status == 200 and looksLikeHtml(data) and path:find("^/api/") and not path:find("camera_proxy")) then
                    lastKind = "notapi"
                else
                    return status, data
                end
            end
        end
    end
    return fail(lastKind)
end

--- The connection test: each address on its own (not just the one that answers).
-- Returns { { which = "home"|"away", detail = url, ok, kind, err, ms } }: kind is
-- "ok", "notsignedin" (it answered; not signed in yet), "signin" (the sign-in
-- didn't work), "notapi" (not Home Assistant), "unreachable" or "failed".
-- clock() gives seconds (with fractions) for the time it took.
function Api:testAddresses(clock)
    local rows = {}
    for __, which in ipairs({ "home", "away" }) do
        local url = self:get(which .. "_url")
        if url then
            local started = clock()
            local headers = {}
            local token = self:tokenFor(url)
            if token then headers.Authorization = "Bearer " .. token end
            local status, body = self.request("GET", url .. "/api/", headers, nil, 8)
            local row = { which = which, detail = url, ms = math.floor((clock() - started) * 1000) }
            if type(status) ~= "number" then
                row.ok, row.kind, row.err = false, "unreachable", status
            elseif (status >= 300 and status < 400) or looksLikeHtml(body) then
                row.ok, row.kind = false, "notapi"
            elseif status == 200 then
                row.ok, row.kind = true, "ok"
            elseif status == 401 or status == 403 then
                if self:signedIn() then row.ok, row.kind = false, "signin" else row.ok, row.kind = true, "notsignedin" end
            else
                row.ok, row.kind, row.err = false, "failed", "HTTP " .. status
            end
            table.insert(rows, row)
        end
    end
    return rows
end

function Api:sendJson(method, path, value, timeout)
    local status, body = self:send(method, path, value and self.json.encode(value) or nil, "application/json", timeout)
    if not status then return nil, body end
    if status >= 200 and status < 300 then return self:decode(body) or {}, nil, body end
    local data = self:decode(body)
    return fail("failed", data and Model.str(data.message) or ("HTTP " .. status))
end

-- ------------------------------------------------------------------ signing in

--- Starts the sign-in at `url`: { flow_id } or nil, why.
function Api:startLogin(url)
    local base = Api.cleanUrl(url)
    if not base then return nil, "Enter the address first." end
    -- The handler is ["homeassistant", null]: written by hand (a nil would be dropped).
    local body = string.format('{"client_id":%s,"handler":["homeassistant",null],"redirect_uri":%s}',
        self.json.encode(Api.CLIENT_ID), self.json.encode(Api.REDIRECT_URI))
    local status, data = self.request("POST", base .. "/auth/login_flow", { ["Content-Type"] = "application/json" }, body, 20)
    if type(status) ~= "number" then return nil, ERRORS.unreachable end
    if looksLikeHtml(data) or status >= 300 and status < 400 then return nil, ERRORS.notapi end
    local flow = self:decode(data)
    if status ~= 200 or not flow or not Model.str(flow.flow_id) then
        return nil, ERRORS.failed .. ((flow and Model.str(flow.message)) and ("\n" .. flow.message) or "")
    end
    return { base = base, flow_id = flow.flow_id }
end

local function flowError(data)
    local errors = data and type(data.errors) == "table" and data.errors or {}
    local e = Model.str(errors.base) or Model.str(errors.code) or ""
    if e == "invalid_auth" then return "Wrong username or password." end
    if e == "invalid_code" then return "Incorrect code. Try the current one." end
    if e ~= "" then return "Home Assistant said: " .. e end
    return nil
end

--- The next step of a sign-in (fields: username + password, or code).
-- Returns "done", "mfa" (a two-step code is asked for next) or nil, why.
function Api:loginStep(login, fields)
    fields.client_id = Api.CLIENT_ID
    local status, body = self.request("POST", login.base .. "/auth/login_flow/" .. login.flow_id,
        { ["Content-Type"] = "application/json" }, self.json.encode(fields), 20)
    if type(status) ~= "number" then return nil, ERRORS.unreachable end
    local data = self:decode(body)
    if not data then return nil, ERRORS.failed end
    if data.type == "create_entry" and Model.str(data.result) then
        return self:exchange(login.base, data.result)
    end
    if data.type == "form" then
        local why = flowError(data)
        if why then return nil, why end
        if data.step_id == "mfa" then return "mfa" end
    end
    if data.type == "abort" then return nil, "Sign-in timed out. Try again." end
    return nil, flowError(data) or ERRORS.failed
end

--- The sign-in's code swapped for tokens, which are kept. clientId: when the
-- code came from another client (the reader's web page).
function Api:exchange(base, code, clientId)
    local status, body = self.request("POST", base .. "/auth/token",
        { ["Content-Type"] = "application/x-www-form-urlencoded" },
        form{ grant_type = "authorization_code", code = code, client_id = clientId or Api.CLIENT_ID }, 20)
    local data = type(status) == "number" and self:decode(body)
    if status ~= 200 or not data or not data.refresh_token then return nil, ERRORS.failed end
    self:set("token", nil)
    self:set("client_id", clientId)
    self:set("refresh_token", data.refresh_token)
    self:set("access_token", data.access_token)
    self:set("expires_at", self.now() + (Model.num(data.expires_in) or 1800))
    self:set("home_url", self:get("home_url") or base)
    self.settings.save()
    return "done"
end

--- A long-lived token (from Profile > Security) used instead of signing in.
-- Checked against Home Assistant first. Returns true or nil, why.
function Api:useToken(token)
    token = (token or ""):gsub("%s+", "")
    if #token < 20 then return nil, "That doesn't look like a valid token." end
    local old = { token = self:get("token"), refresh = self:get("refresh_token") }
    self:set("token", token)
    local data, err = self:sendJson("GET", "/api/")
    if not data then
        self:set("token", old.token)
        return nil, err.message
    end
    self:set("refresh_token", nil)
    self:set("access_token", nil)
    self.settings.save()
    return true
end

function Api:signOut()
    local refresh = self:get("refresh_token")
    if refresh then
        -- Best effort: the sign-in is removed from Home Assistant too.
        for __, a in ipairs(self:addresses()) do
            local status = self.request("POST", a[2] .. "/auth/token", { ["Content-Type"] = "application/x-www-form-urlencoded" },
                form{ token = refresh, action = "revoke" }, 6)
            if type(status) == "number" then break end
        end
    end
    for __, key in ipairs({ "token", "refresh_token", "access_token", "expires_at", "client_id" }) do self:set(key, nil) end
    self.settings.save()
end

-- ------------------------------------------------------------------ calls

--- Everything the screens show, in one call: a snapshot (see hamodel), nil and the
-- answer as text (kept for opening without Wi-Fi); or nil, err.
function Api:snapshot(weather)
    local data, err, raw = self:sendJson("POST", "/api/template", { template = Template.all(weather) })
    if not data then return nil, err end
    local snap = Model.parse(data)
    if not snap then return fail("failed", "Unexpected response.") end
    return snap, nil, raw
end

--- A service: "light.toggle", { entity_id = ... }. Returns true or nil, err.
--- Home Assistant's notifications (persistent_notification/get, WebSocket
-- only): { { id, title, message, created }... } or nil, err.
function Api:notifications()
    local lastKind = "unreachable"
    for i, a in ipairs(self:addresses()) do
        local base = a[2]
        local token, why = self:tokenFor(base)
        if not token then
            if why ~= "unreachable" then return fail(why) end
        else
            local result, kind = self.websocket(base, token, { type = "persistent_notification/get" }, (i < #self:addresses()) and 6 or 20)
            if result then
                local out = {}
                for __, n in ipairs(type(result) == "table" and result or {}) do
                    if type(n) == "table" and Model.str(n.notification_id) then
                        table.insert(out, { id = n.notification_id, title = Model.str(n.title) or "", message = Model.str(n.message) or "",
                            created = Model.str(n.created_at) })
                    end
                end
                return out
            end
            lastKind = kind or "failed"
            if lastKind == "signin" then return fail("signin") end
        end
    end
    return fail(lastKind)
end

function Api:call(service, data)
    local domain, verb = service:match("^([%w_]+)%.([%w_]+)$")
    if not domain then return fail("failed", service) end
    local ok, err = self:sendJson("POST", "/api/services/" .. domain .. "/" .. verb, data or {})
    if not ok then return nil, err end
    return true
end

--- The path of a sensor's last day in Home Assistant's history (only the
-- states and when they changed).
function Api.historyPath(id, now)
    local function at(t) return os.date("!%Y-%m-%dT%H:%M:%S", t) .. "%2B00:00" end
    return "/api/history/period/" .. at(now - 86400) .. "?filter_entity_id=" .. id .. "&end_time=" .. at(now)
        .. "&minimal_response&no_attributes"
end

--- A camera's picture (JPEG bytes) or nil, err.
function Api:camera(id, width)
    local path = "/api/camera_proxy/" .. id .. (width and ("?width=" .. width) or "")
    local status, body = self:send("GET", path, nil, nil, 25)
    if not status then return nil, body end
    if status ~= 200 or type(body) ~= "string" or #body < 100 then return fail("failed", "No image.") end
    return body
end

--- The forecast, "daily" (the default) or "hourly":
-- { { high, low, condition, day = "2026-10-21T...", rain = percent }, ... } or nil.
function Api:forecast(id, kind)
    local data = self:sendJson("POST", "/api/services/weather/get_forecasts?return_response", { entity_id = id, type = kind or "daily" })
    local resp = data and type(data.service_response) == "table" and data.service_response[id]
    local list = resp and type(resp.forecast) == "table" and resp.forecast
    if not list then return nil end
    local out = {}
    for __, f in ipairs(list) do
        table.insert(out, { high = Model.num(f.temperature), low = Model.num(f.templow), condition = Model.str(f.condition),
            day = Model.str(f.datetime), rain = Model.num(f.precipitation_probability) })
    end
    return out
end

return Api
