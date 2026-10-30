--[[--
Syncthing on the web page (needs the Syncthing plugin): on/off, requests to
accept or ignore (new devices, folders offered), the folders (rescan, pause)
and devices (pause), this Kindle's ID, Start with Wi-Fi, Turn off when up to date,
Sync now then turn off, the web GUI password and its port. The plugin
talks to Syncthing; these routes only pass things on.
]]

local Common = require("webcommon")

local Web = {}

local function st()
    local s = Common.plugin("syncthing")
    if s and s.webState then return s end
end

local ACTIONS = { rescan = true, pauseFolder = true, pauseDevice = true, acceptDevice = true, ignoreDevice = true,
    acceptFolder = true, ignoreFolder = true, password = true }

function Web.routes(server)
    -- { installed, program, running, starting, summary, id, withWifi, port, gui,
    --   offWhenSynced, warn, turnsOff, passwordSet, folders, devices, pendingDevices, pendingFolders }
    --   (see Syncthing:webState). The password is never sent, only whether one is set.
    server:route("GET", "^/api/syncthing$", function(req, res)
        local s = st()
        if not s then return res:json({ installed = false }) end
        local out = s:webState()
        out.installed = true
        res:json(out)
    end)

    -- { on = true | false }
    server:route("POST", "^/api/syncthing/power$", function(req, res)
        local s = st()
        if not s then return res:error(404, "Syncthing isn't installed") end
        local b = req.json()
        if b.on then
            if not s:installed() then return res:error(409, "The syncthing program is missing from the plugin's folder") end
            if not s:start(true) then return res:error(500, "Couldn't start Syncthing") end
        else
            s:stop(true, true)
        end
        res:json({ ok = true })
    end)

    -- { name, args }: rescan { folder? }, pauseFolder { folder, paused }, pauseDevice { device, paused },
    -- acceptDevice { device, name }, ignoreDevice { device, name, address },
    -- acceptFolder { folder, label, from, path }, ignoreFolder { folder, label, from },
    -- password { password }.
    server:route("POST", "^/api/syncthing/act$", function(req, res)
        local s = st()
        if not s then return res:error(404, "Syncthing isn't installed") end
        local b = req.json()
        if not ACTIONS[b.name] then return res:error(400, "Unknown action") end
        local ok, err = s:act(b.name, type(b.args) == "table" and b.args or {})
        if not ok then return res:error(500, tostring(err or "Syncthing couldn't do that")) end
        res:json({ ok = true })
    end)

    -- Sync now, then turn off: on if it is off, off once everything is up to date.
    server:route("POST", "^/api/syncthing/syncoff$", function(req, res)
        local s = st()
        if not s then return res:error(404, "Syncthing isn't installed") end
        if not s:syncThenOff() then return res:error(409, "The syncthing program is missing from the plugin's folder") end
        res:json({ ok = true })
    end)

    -- { withWifi, offWhenSynced, warn, port } (the port only while Syncthing is off)
    server:route("POST", "^/api/syncthing/settings$", function(req, res)
        local s = st()
        if not s then return res:error(404, "Syncthing isn't installed") end
        local b = req.json()
        if type(b.withWifi) == "boolean" then s:setWithWifi(b.withWifi) end
        if type(b.offWhenSynced) == "boolean" then s:setOffWhenSynced(b.offWhenSynced) end
        if type(b.warn) == "boolean" and s.setWarnsOfProblems then s:setWarnsOfProblems(b.warn) end
        if b.port ~= nil then
            local ok, err = s:changePort(b.port)
            if not ok then return res:error(409, err) end
        end
        res:json({ ok = true })
    end)
end

return Web
