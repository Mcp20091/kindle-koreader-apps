--[[--
Pangolin's Integration API (the one its Swagger page shows at /v1/docs):
JSON over HTTPS, with an API key sent as `Authorization: Bearer <key>`.
Answers come wrapped as { data, success, error, message, status }.

Everything here blocks: it runs in a child process (pgbg.lua), never on
KOReader's loop. Answers come back as plain tables.

Why something failed, as the plugin reads it: "signin" (401, the key was
refused), "forbidden" (403, the key lacks the permission; the caller knows
which), "notfound" (404), "notapi" (an answer that isn't the API's, such as
a web page), or the network's own words ("timeout", "connection refused"…).
]]

local JSON = require("json")

local M = require("pgmodel")

local API = {}
API.__index = API

--- cfg: { url, key, org }; request: (method, url, headers, body, timeout) -> status or
-- error, body (KOReader's socket.http by default; the tests pass their own).
function API.new(cfg, request)
    return setmetatable({ base = M.apiBase(cfg.url), key = cfg.key, org = cfg.org,
        send = request or API.http }, API)
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
    return type(s) == "string" and s:sub(1, 200):lower():find("<!doctype html", 1, true) ~= nil
        or type(s) == "string" and s:sub(1, 200):lower():find("<html", 1, true) ~= nil
end

--- One request to path (after /v1): the answer's data (true when it has none), or nil and why.
function API:request(method, path, params, body, timeout)
    local url = self.base .. path
    local q = params and M.query(params) or ""
    if q ~= "" then url = url .. "?" .. q end
    local headers = { Authorization = "Bearer " .. (self.key or ""), Accept = "application/json" }
    local data
    if body then
        data = JSON.encode(body)
        headers["Content-Type"] = "application/json"
    end
    local status, text = self.send(method, url, headers, data, timeout)
    if type(status) ~= "number" then return nil, tostring(status or "no answer") end
    if status == 401 then return nil, "signin" end
    if status == 403 then return nil, "forbidden" end
    if status == 404 then return nil, "notfound" end
    if looksLikeHtml(text) or (status >= 300 and status < 400) then return nil, "notapi" end
    local okJ, t = pcall(JSON.decode, text or "")
    if not okJ or type(t) ~= "table" then
        if status >= 400 then return nil, "HTTP " .. status end
        return nil, "notapi"
    end
    if status >= 400 or t.error == true or t.success == false then
        local msg = M.str(t.message)
        return nil, msg ~= "" and msg or ("HTTP " .. status)
    end
    local d = t.data
    if type(d) ~= "table" then return true end
    return d
end

--- Every page of a list: its items, or nil and why.
function API:all(path, key, extra)
    local items, page = {}, 1
    while true do
        local params = { page = page, pageSize = M.PAGE_SIZE }
        for k, v in pairs(extra or {}) do params[k] = v end
        local d, why = self:request("GET", path, params)
        if not d then return nil, why end
        local batch = type(d) == "table" and type(d[key]) == "table" and d[key] or {}
        for __, x in ipairs(batch) do items[#items + 1] = x end
        local total = type(d) == "table" and type(d.pagination) == "table" and tonumber(d.pagination.total) or 0
        if #batch == 0 or #items >= total or page >= 50 then return items end
        page = page + 1
    end
end

--- Whether the API answers its health check (GET /v1/, no key needed): true, or false and why.
function API:ping()
    local status, text = self.send("GET", self.base .. "/", { Accept = "application/json" }, nil, 10)
    if type(status) ~= "number" then return false, tostring(status or "no answer") end
    if status == 200 and not looksLikeHtml(text) then return true end
    if status == 404 or looksLikeHtml(text) then return false, "notapi" end
    return false, "HTTP " .. status
end

--- The organizations (only root keys may list them): { { orgId, name } }, or nil and why.
function API:orgs()
    local d, why = self:request("GET", "/orgs", { limit = 1000, offset = 0 })
    if not d then return nil, why end
    return type(d) == "table" and type(d.orgs) == "table" and d.orgs or {}
end

--- The organization: { orgId, name, … }, or nil and why.
function API:organization()
    local d, why = self:request("GET", "/org/" .. self.org)
    if not d then return nil, why end
    if type(d) ~= "table" then return {} end
    return type(d.org) == "table" and d.org or d
end

--- Everything the app shows: { org, sites, resources, private, machines, devices, skipped },
-- or nil and why (only when the organization or its sites can't be read). Lists the key
-- may not read (or this Pangolin doesn't have) are left out, named in skipped.
function API:readAll()
    local org, why = self:organization()
    if not org then return nil, why end
    local sites
    sites, why = self:all("/org/" .. self.org .. "/sites", "sites")
    if not sites then return nil, why == "forbidden" and "forbidden:List Sites" or why end
    local out = { org = org, sites = sites, skipped = {} }
    local function optional(name, path, key, extra)
        local t, w = self:all(path, key, extra)
        if t then
            out[name] = t
        elseif w == "forbidden" or w == "notfound" then
            out.skipped[name] = w
        else
            return w
        end
    end
    local o = "/org/" .. self.org
    why = optional("resources", o .. "/resources", "resources")
        or optional("private", o .. "/private-resources", "siteResources")
        -- (blocked and archived ones only come when asked for)
        or optional("machines", o .. "/clients", "clients", { status = "active,blocked,archived" })
    if why then return nil, why end
    if not out.skipped.machines then
        why = optional("devices", o .. "/user-devices", "devices", { status = "active,pending,denied,blocked,archived" })
        if why then return nil, why end
        -- (an older Pangolin without user devices: nothing missing)
        if out.skipped.devices == "notfound" then out.skipped.devices = nil end
    end
    return out
end

--- One public resource's settings ({ blockAccess, … }), or nil and why.
function API:resource(id)
    local d, why = self:request("GET", "/resource/" .. id)
    if not d then return nil, why end
    return type(d) == "table" and d or {}
end

--- Changes on a public resource ({ enabled }, { sso }, { blockAccess }).
function API:updateResource(id, fields)
    return self:request("POST", "/resource/" .. id, nil, fields)
end

--- A private resource on or off (the newer address first, then the older one).
function API:setPrivate(id, enabled)
    local ok, why = self:request("POST", "/private-resource/" .. id, nil, { enabled = enabled })
    if why == "notfound" then ok, why = self:request("POST", "/site-resource/" .. id, nil, { enabled = enabled }) end
    return ok, why
end

--- A client: action is block, unblock, archive or unarchive.
function API:client(id, action)
    return self:request("POST", "/client/" .. id .. "/" .. action)
end

--- Every site's data in and out back to zero.
function API:resetBandwidth()
    return self:request("POST", "/org/" .. self.org .. "/reset-bandwidth")
end

return API
