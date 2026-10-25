--[[--
The shared Microsoft account on the web page (the launcher's appsmicrosoft.lua,
PS.microsoft): the App ID, signing in with a code, who is signed in, which apps
use it, and signing out. The To Do and Notes tabs show it as one card.
]]

local Common = require("webcommon")

local Web = {}

local signIn   -- the sign-in under way: { status, code, url, message }

local function account() return require("pluginshare").microsoft end

-- Common.deviceCode's api: the shared account's sign-in.
local adapter = {
    startSignIn = function() return account().startSignIn() end,
    pollSignIn = function(_, s) return account().pollSignIn(s) end,
}

function Web.routes(server)
    server:route("GET", "^/api/microsoft$", function(req, res)
        local m = account()
        if not m then return res:json({ available = false }) end
        local uses = {}
        for __, u in ipairs(m.uses()) do
            table.insert(uses, { key = u.key, name = u.name or u.key, allowed = m.signedIn() and m.allowed(u.scope) })
        end
        res:json({ available = true, clientId = m.clientId() or "", signedIn = m.signedIn(), account = m.account(), uses = uses })
    end)

    server:route("POST", "^/api/microsoft/clientid$", function(req, res)
        local m = account()
        if not m then return res:error(404, "The launcher isn't installed") end
        m.setClientId(req.json().id or "")
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/microsoft/signin$", function(req, res)
        local m = account()
        if not m then return res:error(404, "The launcher isn't installed") end
        if not m.clientId() then return res:error(400, "Set the App ID first") end
        if signIn then signIn.cancelled = true end
        local state, why = Common.deviceCode(adapter, function() m.afterSignIn() end)
        if not state then return res:error(502, "Can't reach Microsoft: " .. tostring(why)) end
        signIn = state
        res:json(state)
    end)

    server:route("GET", "^/api/microsoft/signin$", function(req, res)
        res:json(signIn or { status = "none" })
    end)

    server:route("POST", "^/api/microsoft/signout$", function(req, res)
        local m = account()
        if not m then return res:error(404, "The launcher isn't installed") end
        m.signOut()
        res:json({ ok = true })
    end)
end

return Web
