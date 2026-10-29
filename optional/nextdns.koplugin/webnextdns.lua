--[[--
NextDNS on the web page (needs the optional NextDNS plugin): the profile's
numbers for today, the domains blocked most, the query log (filtered and
searched), the denylist and allowlist, the protection switches, the profile,
and its settings (API key, how often it's read). The plugin talks to NextDNS;
these routes only pass things on.
]]

local Common = require("webcommon")

local Web = {}

local function nextdns()
    local p = Common.plugin("nextdns")
    if p and p.webState then return p end
end

function Web.routes(server)
    -- { installed, configured, hasKey, keyHint, profile, name, interval, read, why, profiles,
    --   summary, stats, top, deny, allow, switches, kindle, logs } (see NextDNS:webState).
    server:route("GET", "^/api/nextdns$", function(req, res)
        local p = nextdns()
        if not p then return res:json({ installed = false }) end
        local out = p:webState()
        out.installed = true
        res:json(out)
    end)

    -- { name, args }: switch { key, on }, list_add { list, domain }, list_active { list, domain, on },
    -- list_delete { list, domain }, logs { filter, search, device, more }, devices, profiles, profile { id }, refresh,
    -- settings { key, interval }.
    server:route("POST", "^/api/nextdns/act$", function(req, res)
        local p = nextdns()
        if not p then return res:error(404, "NextDNS isn't installed") end
        local b = req.json() or {}
        local ok, why = p:webAct(tostring(b.name or ""), type(b.args) == "table" and b.args or {})
        if not ok then return res:error(400, tostring(why or "NextDNS couldn't do that")) end
        res:json({ ok = true })
    end)
end

return Web
