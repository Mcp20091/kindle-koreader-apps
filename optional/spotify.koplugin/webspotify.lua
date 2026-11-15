--[[--
Spotify on the web page (needs the optional Spotify plugin): what's playing,
the remote's buttons, the volume, the devices, playlists, recently played
songs and a search, and its settings and sign-in (Client ID, Sign in, the
address to paste). The plugin talks to Spotify; these routes only pass
things on.
]]

local Common = require("webcommon")

local Web = {}

local function spotify()
    local p = Common.plugin("spotify")
    if p and p.webState then return p end
end

function Web.routes(server)
    -- { installed, configured, hasClientId, clientIdHint, signedIn, redirect, interval, art, volumeStep,
    --   read, reading, why, player, nothing, devices, playlists, recent, search, failed, signInResult }
    -- (see Spotify:webState).
    server:route("GET", "^/api/spotify$", function(req, res)
        local p = spotify()
        if not p then return res:json({ installed = false }) end
        local out = p:webState()
        out.installed = true
        res:json(out)
    end)

    -- { name, args }: toggle, next, previous, seek { ms }, volume { percent }, shuffle { on },
    -- repeat { mode }, transfer { device }, play { context, track, device }, queue { uri }, refresh,
    -- playlists, recent, search { q }, settings { clientId, interval, art, volumeStep },
    -- signin (answers { url }), finish { address }, signout.
    server:route("POST", "^/api/spotify/act$", function(req, res)
        local p = spotify()
        if not p then return res:error(404, "Spotify Remote isn't installed") end
        local b = req.json() or {}
        local ok, why = p:webAct(tostring(b.name or ""), type(b.args) == "table" and b.args or {})
        if not ok then return res:error(400, tostring(why or "Spotify couldn't do that")) end
        if type(ok) == "table" then
            ok.ok = true
            return res:json(ok)
        end
        res:json({ ok = true })
    end)
end

return Web
