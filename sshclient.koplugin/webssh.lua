--[[--
SSH on the web page (needs the SSH plugin, sshclient.koplugin): the hosts
(address, user, port, sign-in with a key or a password), each host's saved
commands, the command list, and keys (upload a private key file, create one
on the Kindle, copy a public key), and AI help (explain or summarize output,
write a command; the launcher's AI). Passwords go to the Kindle but never come
back to the page. The plugin keeps everything; these routes pass it on.
]]

local Common = require("webcommon")

local Web = {}

local function ssh()
    local s = Common.plugin("sshclient")
    if s and s.webState then return s end
end

local ACTIONS = { saveHost = true, deleteHost = true, saveCommands = true, saveHostCommands = true, addBuiltIn = true, renameKey = true,
    addCommand = true, importConfig = true, saveHostStats = true, saveHostQuick = true, saveSettings = true, wakeHost = true,
    importKey = true, createKey = true, deleteKey = true, forgetHost = true }

function Web.routes(server)
    -- { installed, dbclient, hosts = { { id, name, address, user, port, auth, key, hasPassword, known,
    --   commands = { { id, name, cmd } }, recent } }, commands, keys = { { id, name, type, public } } }.
    server:route("GET", "^/api/ssh$", function(req, res)
        local s = ssh()
        if not s then return res:json({ installed = false }) end
        local out = s:webState()
        out.installed = true
        res:json(out)
    end)

    -- { name, args } (see SSH:act): saveHost { id?, name, address, user, port, auth, key, password? },
    -- deleteHost { id }, saveCommands { list }, saveHostCommands { id, list }, addBuiltIn {}, renameKey { id, name },
    -- importKey { name, text }, createKey { name }, deleteKey { id }, forgetHost { id }.
    server:route("POST", "^/api/ssh/act$", function(req, res)
        local s = ssh()
        if not s then return res:error(404, "SSH isn't installed") end
        local b = req.json()
        if not ACTIONS[b.name] then return res:error(400, "Unknown action") end
        local r, err = s:act(b.name, type(b.args) == "table" and b.args or {})
        if not r then return res:error(400, tostring(err or "SSH couldn't do that")) end
        res:json({ ok = true, result = r })
    end)

    -- AI help: POST { kind = "explain" | "summary" | "write", host, cmd, output, want, turns } starts it
    -- and gives { key }; GET ?key= gives { status = "waiting" } or { status = "done", answer, raw,
    -- commands, service } or { status = "done", why }.
    server:route("POST", "^/api/ssh/ai$", function(req, res)
        local s = ssh()
        if not s or not s.aiStart then return res:error(404, "SSH isn't installed") end
        local r, err = s:aiStart(req.json())
        if not r then return res:error(400, tostring(err)) end
        res:json(r)
    end)

    server:route("GET", "^/api/ssh/ai$", function(req, res)
        local s = ssh()
        local r = s and s.aiResult and s:aiResult(req.query.key)
        if not r then return res:error(404, "No such request") end
        res:json(r)
    end)
end

return Web
