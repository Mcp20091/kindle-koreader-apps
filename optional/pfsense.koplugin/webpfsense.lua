--[[--
pfSense on the web page (needs the optional pfSense plugin): the firewall's
health, gateways, interfaces, services (start, stop, restart), devices (Wake),
DHCP static mappings and DNS host overrides (add, delete), firewall rules on or
off, reboot and update, and its settings (address, API key, how often it's
read, notifications). The plugin talks to pfSense; these routes only pass
things on.
]]

local Common = require("webcommon")

local Web = {}

local function pfsense()
    local p = Common.plugin("pfsense")
    if p and p.webState then return p end
end

function Web.routes(server)
    -- { installed, configured, url, name, hasKey, interval, notify, read, why, summary, skipped,
    --   system, gateways, interfaces, services, devices, rules, statics, overrides } (see PfSense:webState).
    server:route("GET", "^/api/pfsense$", function(req, res)
        local p = pfsense()
        if not p then return res:json({ installed = false }) end
        local out = p:webState()
        out.installed = true
        res:json(out)
    end)

    -- { name, args }: service, rule_enabled, wake, static_add, static_delete, override_add,
    -- override_delete, reboot, update, refresh, read, lookup, settings, and the rest PfSense:webAct lists.
    server:route("POST", "^/api/pfsense/act$", function(req, res)
        local p = pfsense()
        if not p then return res:error(404, "pfSense isn't installed") end
        local b = req.json() or {}
        local ok, why = p:webAct(tostring(b.name or ""), type(b.args) == "table" and b.args or {})
        if not ok then return res:error(400, tostring(why or "pfSense couldn't do that")) end
        res:json({ ok = true })
    end)
end

return Web
