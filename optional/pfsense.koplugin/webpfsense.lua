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

--- Whether the web page has a password (without one, anyone on the Wi-Fi can open it).
local function locked()
    local ok, Auth = pcall(require, "webauth")
    return ok and Auth.isSet and Auth.isSet() == true
end

-- What the page may do only with a password: a cron job runs any command as root on the firewall.
local NEEDS_PASSWORD = { cron_add = true }

function Web.routes(server)
    -- { installed, configured, url, name, hasKey, interval, notify, read, why, summary, skipped,
    --   system, gateways, interfaces, services, devices, rules, statics, overrides } (see PfSense:webState).
    server:route("GET", "^/api/pfsense$", function(req, res)
        local p = pfsense()
        if not p then return res:json({ installed = false }) end
        local out = p:webState()
        out.installed = true
        out.locked = locked()
        res:json(out)
    end)

    -- { name, args }: service, rule_enabled, wake, static_add, static_delete, override_add,
    -- override_delete, reboot, update, refresh, read, lookup, settings, and the rest PfSense:webAct lists.
    server:route("POST", "^/api/pfsense/act$", function(req, res)
        local p = pfsense()
        if not p then return res:error(404, "pfSense isn't installed") end
        local b = req.json() or {}
        if NEEDS_PASSWORD[tostring(b.name or "")] and not locked() then
            return res:error(403, "Set a password for the web page first (on the Kindle: Web server > Password). A cron job runs a command as root on the firewall, so without one anyone on the Wi-Fi could add one. On the Kindle itself it works without.")
        end
        local ok, why = p:webAct(tostring(b.name or ""), type(b.args) == "table" and b.args or {})
        if not ok then return res:error(400, tostring(why or "pfSense couldn't do that")) end
        res:json({ ok = true })
    end)
end

return Web
