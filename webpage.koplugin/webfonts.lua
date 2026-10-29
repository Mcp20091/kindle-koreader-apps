--[[--
Fonts on the web page (the Fonts tab): the routes. The work
is the launcher's appsfonts.lua (the Kindle's Fonts screen uses it too); without
the launcher, the card says it's needed.
]]

local util = require("util")

local Web = {}

local EXTS = { ttf = true, otf = true, ttc = true }

local function F() return require("appsfonts") end

--- Fonts taken out a while ago are gone for good (once per start).
function Web.emptyTrash()
    local ok, Fonts = pcall(require, "appsfonts")
    if ok then Fonts.emptyTrash() end
end

-- ------------------------------------------------------------------ routes

function Web.routes(server)
    -- Without the launcher: every fonts route says so.
    if not pcall(require, "appsfonts") then
        server:route("GET", "^/api/fonts", function(req, res) res:error(404, "Fonts needs the launcher plugin (apps.koplugin).") end)
        return
    end
    server:route("GET", "^/api/fonts$", function(req, res) res:json(F().list()) end)

    -- A font file, for the page to draw its name in it.
    server:route("GET", "^/api/fonts/file$", function(req, res)
        local path = F().byId and F().byId[tonumber(req.query.id)]
        if not path then return res:error(404, "No such font") end
        res:file(path, path:match("[^/]+$"), true)
    end)

    -- PUT with the file as the body, written as it arrives (as Files' upload).
    server:route("PUT", "^/api/fonts/upload$", function(req, res)
        local name = tostring(req.query.name or ""):match("[^/\\]+$") or ""
        local ext = (name:match("%.(%w+)$") or ""):lower()
        if not (EXTS[ext] or ext == "zip") then
            return res:error(400, "Only font files (TTF, OTF or TTC) or a zip of them.")
        end
        if (req.length or 0) > 200 * 1024 * 1024 then return res:error(400, "That file is too big.") end
        local dir = (F().writeDir and F().writeDir() or F().addedDirs()[1])
        util.makePath(dir)
        local tmp = dir .. "/.upload-" .. os.time() .. ".part"
        local f = io.open(tmp, "wb")
        if not f then return res:error(500, "Can't write to " .. dir) end
        local got = 0
        while true do
            local chunk = req:read(64 * 1024)
            if not chunk then break end
            f:write(chunk)
            got = got + #chunk
        end
        f:close()
        if got ~= req.length then
            os.remove(tmp)
            return res:error(400, "The upload was interrupted")
        end
        local added, why = F().install(tmp, name)
        if not added then return res:error(400, why) end
        res:json({ ok = true, added = added })
    end, true)

    server:route("POST", "^/api/fonts/remove$", function(req, res)
        local token, why = F().remove((req.json() or {}).id)
        if not token then return res:error(400, why) end
        res:json({ ok = true, token = token })
    end)

    server:route("POST", "^/api/fonts/undo$", function(req, res)
        local ok, why = F().undo((req.json() or {}).token)
        if not ok then return res:error(400, why) end
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/fonts/default$", function(req, res)
        local ok, why = F().setDefault((req.json() or {}).family)
        if not ok then return res:error(400, why) end
        res:json({ ok = true })
    end)

    -- One of KOReader's font settings: { key, value }.
    server:route("POST", "^/api/fonts/setting$", function(req, res)
        local ok, S = pcall(require, "appskosettings")
        if not ok then return res:error(404, "The launcher isn't installed") end
        local b = req.json() or {}
        if type(b.key) ~= "string" then return res:error(400, "No setting") end
        local msg = S.set(b.key, b.value)
        res:json({ ok = msg == nil, message = msg })
    end)

    server:route("POST", "^/api/fonts/google$", function(req, res)
        local why = F().google((req.json() or {}).family)
        if why then return res:error(400, why) end
        res:json({ ok = true })
    end)

    server:route("GET", "^/api/fonts/google$", function(req, res) res:json(F().googleState() or { status = "none" }) end)

    -- Every Google Fonts family to browse (appsgooglefonts.lua, as the Kindle's Get more tab):
    -- ?q=&cat=suggested|all|serif|sans|mono|hand|display&sort=popular|az|new&page=&per=
    server:route("GET", "^/api/fonts/catalogue$", function(req, res)
        local G = require("appsgooglefonts")
        G.ensure()
        local q = req.query or {}
        local per = math.max(5, math.min(100, tonumber(q.per) or 24))
        local page = math.max(1, tonumber(q.page) or 1)
        local r = G.query{ q = q.q, cat = q.cat, sort = q.sort, from = (page - 1) * per + 1, count = per }
        local categories, sorts = {}, {}
        for __, c in ipairs(G.CATEGORIES) do table.insert(categories, { c[1], c[2] }) end
        for __, s in ipairs(G.SORTS) do table.insert(sorts, { s[1], s[2] }) end
        res:json({ state = G.state(), total = r.total, items = r.items, exact = r.exact or false, page = page,
            pages = math.max(1, math.ceil(r.total / per)), categories = categories, sorts = sorts })
    end)

    server:route("POST", "^/api/fonts/catalogue/update$", function(req, res)
        local why = require("appsgooglefonts").update()
        if why then return res:error(400, why) end
        res:json({ ok = true })
    end)
end

return Web
