--[[--
NextDNS's API (https://api.nextdns.io): JSON over HTTPS, with the account's
API key sent as `X-Api-Key`. Answers come as { data, meta }; errors as
{ errors = { { code, detail } } }. Changes answer 204 with nothing.

And test.nextdns.io, which says whether the DNS of whoever asks (here, this
Kindle) goes through NextDNS. It gets no key.

Everything here blocks: it runs in a child process (ndbg.lua), never on
KOReader's loop. Answers come back as plain tables.

Why something failed, as the plugin reads it: "signin" (401 or 403: the key
was refused), "notfound" (404: no such profile), "busy" (429: too many
requests for now), "notapi" (an answer that isn't the API's), or the
network's own words ("timeout", "connection refused"…).
]]

local JSON = require("json")

local M = require("ndmodel")

local API = {}
API.__index = API

--- cfg: { key, profile }; request: (method, url, headers, body, timeout) -> status or
-- error, body (KOReader's socket.http by default; the tests pass their own).
function API.new(cfg, request)
    return setmetatable({ key = cfg.key, profile = cfg.profile, send = request or API.http }, API)
end

--- KOReader's network: (status or error, body). HTTPS through KOReader's luasec.
function API.http(method, url, headers, body, timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    local request = { url = url, method = method, headers = headers or {}, sink = ltn12.sink.table(sink) }
    if body then
        request.source = ltn12.source.string(body)
        request.headers["Content-Length"] = tostring(#body)
    end
    timeout = timeout or 20
    socketutil:set_timeout(math.min(timeout, 10), timeout)
    local ok, code = pcall(function() return socket.skip(1, http.request(request)) end)
    socketutil:reset_timeout()
    if not ok then code = tostring(code) end
    return code, table.concat(sink)
end

local function looksLikeHtml(s)
    if type(s) ~= "string" then return false end
    local head = s:sub(1, 200):lower()
    return head:find("<!doctype html", 1, true) ~= nil or head:find("<html", 1, true) ~= nil
end

--- One request to path (after api.nextdns.io): (data, meta) (data true when there's none),
-- or nil and why.
function API:request(method, path, params, body, timeout)
    local url = M.API .. path
    local q = params and M.query(params) or ""
    if q ~= "" then url = url .. "?" .. q end
    local headers = { ["X-Api-Key"] = self.key or "", Accept = "application/json" }
    local data
    if body then
        data = JSON.encode(body)
        headers["Content-Type"] = "application/json"
    end
    local status, text = self.send(method, url, headers, data, timeout)
    if type(status) ~= "number" then return nil, tostring(status or "no answer") end
    if status == 401 or status == 403 then return nil, "signin" end
    if status == 404 then return nil, "notfound" end
    if status == 429 then return nil, "busy" end
    if looksLikeHtml(text) or (status >= 300 and status < 400) then return nil, "notapi" end
    if (text or "") == "" then
        if status >= 400 then return nil, "HTTP " .. status end
        return true
    end
    local okJ, t = pcall(JSON.decode, text)
    if not okJ or type(t) ~= "table" then
        if status >= 400 then return nil, "HTTP " .. status end
        return nil, "notapi"
    end
    if type(t.errors) == "table" and t.errors[1] then
        local e = t.errors[1]
        local why = M.str(type(e) == "table" and (e.detail or e.code) or e)
        return nil, why ~= "" and why or ("HTTP " .. status)
    end
    if status >= 400 then return nil, "HTTP " .. status end
    if t.data == nil then return true end
    return t.data, type(t.meta) == "table" and t.meta or {}
end

--- The account's profiles: { { id, name } } as the API gives them, or nil and why.
function API:profiles()
    local d, why = self:request("GET", "/profiles")
    if not d then return nil, why end
    return type(d) == "table" and d or {}
end

--- The profile: { id, name, denylist, allowlist, security, privacy, parentalControl, … }.
function API:profileData()
    local d, why = self:request("GET", "/profiles/" .. self.profile)
    if not d then return nil, why end
    return type(d) == "table" and d or {}
end

--- Today's queries by status ({ { status, queries } }); from: a Unix time.
function API:status(from)
    return self:request("GET", "/profiles/" .. self.profile .. "/analytics/status", { from = from })
end

--- The domains blocked most since from: { { domain, queries } }.
function API:topBlocked(from, limit)
    return self:request("GET", "/profiles/" .. self.profile .. "/analytics/domains",
        { from = from, status = "blocked", limit = limit or M.TOP })
end

--- Whether this Kindle's DNS goes through NextDNS: test.nextdns.io's answer, or nil and why.
-- (No key: it isn't the API.)
function API:kindle()
    local status, text = self.send("GET", M.TEST, { Accept = "application/json" }, nil, 10)
    if type(status) ~= "number" then return nil, tostring(status or "no answer") end
    if status ~= 200 then return nil, "HTTP " .. status end
    local okJ, t = pcall(JSON.decode, text or "")
    if not okJ or type(t) ~= "table" then return nil, "notapi" end
    return t
end

--- Everything the first page shows: { profile, status, top, kindle }, or nil and why
-- (only when the profile or today's numbers can't be read). The top blocked domains and
-- the Kindle's check are left out when they fail.
function API:readAll(from)
    local p, why = self:profileData()
    if not p then return nil, why end
    local st
    st, why = self:status(from)
    if not st then return nil, why end
    local out = { profile = p, status = type(st) == "table" and st or {} }
    local top = self:topBlocked(from)
    if top then out.top = type(top) == "table" and top or {} end
    out.kindle = self:kindle()
    return out
end

--- The query log, newest first: { items, cursor }, or nil and why.
-- opts: { status = "blocked" | "allowed" | nil, search, cursor, limit }.
function API:logs(opts)
    opts = opts or {}
    local params = { limit = opts.limit or M.LOG_PAGE }
    if opts.status and opts.status ~= "all" then params.status = opts.status end
    if opts.search and opts.search ~= "" then params.search = opts.search end
    if opts.cursor and opts.cursor ~= "" then params.cursor = opts.cursor end
    local d, meta = self:request("GET", "/profiles/" .. self.profile .. "/logs", params)
    if not d then return nil, meta end
    local pag = type(meta) == "table" and type(meta.pagination) == "table" and meta.pagination or {}
    return { items = type(d) == "table" and d or {}, cursor = M.str(pag.cursor) }
end

--- A switch on or off: group is security, privacy or parentalControl.
function API:setSwitch(group, key, on)
    return self:request("PATCH", "/profiles/" .. self.profile .. "/" .. group, nil, { [key] = on })
end

local LISTS = { deny = "denylist", allow = "allowlist" }

--- A domain added to a list (deny or allow), on unless active is false.
function API:listAdd(which, domain, active)
    return self:request("POST", "/profiles/" .. self.profile .. "/" .. LISTS[which], nil,
        { id = domain, active = active ~= false })
end

--- A list entry turned on or off.
function API:listActive(which, domain, on)
    return self:request("PATCH", "/profiles/" .. self.profile .. "/" .. LISTS[which] .. "/" .. domain, nil, { active = on })
end

--- A list entry taken out.
function API:listDelete(which, domain)
    return self:request("DELETE", "/profiles/" .. self.profile .. "/" .. LISTS[which] .. "/" .. domain)
end

return API
