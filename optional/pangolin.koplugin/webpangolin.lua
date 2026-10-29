--[[--
Pangolin on the web page (needs the optional Pangolin plugin): the
organization's sites, resources and clients, turning resources on or off,
sign-in, blocking and archiving clients, resetting the bandwidth counters,
and its settings (API URL, API key, organization, how often it's read,
notifications). The plugin talks to Pangolin; these routes only pass things on.
]]

local Common = require("webcommon")

local Web = {}

local function pangolin()
    local p = Common.plugin("pangolin")
    if p and p.webState then return p end
end

function Web.routes(server)
    -- { installed, configured, url, org, name, hasKey, keyId, interval, notify, read, why,
    --   summary, counts, skipped, sites, resources, private, clients } (see Pangolin:webState).
    server:route("GET", "^/api/pangolin$", function(req, res)
        local p = pangolin()
        if not p then return res:json({ installed = false }) end
        local out = p:webState()
        out.installed = true
        res:json(out)
    end)

    -- { name, args }: resource_enabled, resource_sso, private_enabled, client_blocked,
    -- client_archived ({ id, on }), reset_bandwidth, refresh, settings { url, key, org, interval, notify }.
    server:route("POST", "^/api/pangolin/act$", function(req, res)
        local p = pangolin()
        if not p then return res:error(404, "Pangolin isn't installed") end
        local b = req.json() or {}
        local ok, why = p:webAct(tostring(b.name or ""), type(b.args) == "table" and b.args or {})
        if not ok then return res:error(400, tostring(why or "Pangolin couldn't do that")) end
        res:json({ ok = true })
    end)
end

return Web
