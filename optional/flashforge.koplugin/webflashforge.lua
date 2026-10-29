--[[--
FlashForge on the web page (needs the optional FlashForge plugin): the
printer's state, pause, resume, cancel, clear, the light and the air filter,
and its settings (address, serial number, check code, how often it's read,
levelling). The plugin talks to the printer; these routes only pass things on.
]]

local Common = require("webcommon")

local Web = {}

local function ff()
    local f = Common.plugin("flashforge")
    if f and f.webState then return f end
end

function Web.routes(server)
    -- { installed, configured, ip, name, model, hasCode, interval, leveling, read, why,
    --   state, stateText, summary, file, progress, lines, canPause…, temps, light, hasLight,
    --   filtration, hasFiltration, error, slots } (see FlashForge:webState).
    server:route("GET", "^/api/flashforge$", function(req, res)
        local f = ff()
        if not f then return res:json({ installed = false }) end
        local out = f:webState()
        out.installed = true
        res:json(out)
    end)

    -- { name, args }: pause, resume, cancel, clear, light { on }, filtration { mode }, refresh,
    -- settings { ip, serial, code, interval, leveling }.
    server:route("POST", "^/api/flashforge/act$", function(req, res)
        local f = ff()
        if not f then return res:error(404, "FlashForge isn't installed") end
        local b = req.json() or {}
        local ok, why = f:webAct(tostring(b.name or ""), type(b.args) == "table" and b.args or {})
        if not ok then return res:error(400, tostring(why or "The printer couldn't do that")) end
        res:json({ ok = true })
    end)
end

return Web
