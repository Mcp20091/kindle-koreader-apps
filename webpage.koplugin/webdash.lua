--[[--
The Dashboard tab: parts picked from the other tabs (a To Do list, Home
Assistant's Quick tiles or a room, recent notebooks, today's crossword, saved
Wikipedia articles, Syncthing, an SSH command, recent files, a favorite
folder, the Kindle's controls and screen), in the order chosen, saved on this
Kindle (G_reader_settings "web_dashboard"). Most parts use their tab's own
calls; these add Home Assistant's tiles with their states (a tap switches
one, as on the Kindle) and running a saved SSH command on the Kindle.
]]

local Common = require("webcommon")
local UIManager = require("ui/uimanager")

local Web = {}

-- The kinds of part, and what each keeps.
local KINDS = {
    todo = { "list" }, haQuick = {}, haRoom = { "room" }, notebooks = {}, crossword = {}, wikipedia = {},
    syncthing = {}, ssh = { "ref", "name" }, recent = {}, folder = { "path", "name" }, controls = {}, remote = {},
}

local function parts()
    local list = G_reader_settings:readSetting("web_dashboard")
    return type(list) == "table" and list or {}
end

--- Only known kinds, with only their own fields (strings), at most 40.
local function clean(list)
    local out = {}
    for __, p in ipairs(type(list) == "table" and list or {}) do
        local keep = type(p) == "table" and KINDS[p.kind]
        if keep and #out < 40 then
            local part = { kind = p.kind }
            for __, k in ipairs(keep) do
                if type(p[k]) == "string" or type(p[k]) == "number" then part[k] = tostring(p[k]) end
            end
            table.insert(out, part)
        end
    end
    return out
end

-- A device as a tile: its state in words, whether it is on, and what a tap asks first.
local function tile(Model, e, prefs)
    local action = Model.tapAction(e, prefs)
    return {
        id = e.id, name = e.name, area = e.area, state = Model.stateText(e), on = Model.isOn(e),
        gone = e.state == "unavailable", confirm = action.confirm,
        tap = (action.service and not action.camera and not action.sheet) and true or false,
    }
end

function Web.routes(server)
    server:route("GET", "^/api/dashboard$", function(req, res)
        res:json({ parts = parts() })
    end)

    -- { parts = { { kind, ... } } }: the whole dashboard, in its order.
    server:route("POST", "^/api/dashboard$", function(req, res)
        local list = clean(req.json().parts)
        if #list == 0 then G_reader_settings:delSetting("web_dashboard") else G_reader_settings:saveSetting("web_dashboard", list) end
        res:json({ ok = true, parts = list })
    end)

    -- Home Assistant's Quick tiles (?quick=1) or a room's devices (?room=Kitchen),
    -- and the rooms to pick from.
    server:route("GET", "^/api/dashboard/ha$", function(req, res)
        local h = Common.plugin("homeassistant")
        if not h then return res:json({ installed = false }) end
        local out = { installed = true, signedIn = h.api:signedIn(), tiles = {}, rooms = {}, updated = h.updatedAt }
        local snap = h.snap
        if not snap then return res:json(out) end
        local Model = require("hamodel")
        local list = {}
        if req.query.quick then
            list = Model.quick(snap, h.prefs)
        end
        for __, r in ipairs(Model.rooms(snap, h.prefs)) do
            table.insert(out.rooms, r.name)
            if r.name == req.query.room then list = r.entities end
        end
        for __, e in ipairs(list) do table.insert(out.tiles, tile(Model, e, h.prefs)) end
        res:json(out)
    end)

    -- A tile tapped: { id } (what a tap does on the Kindle; asked first on the page).
    server:route("POST", "^/api/dashboard/ha/act$", function(req, res)
        local h = Common.plugin("homeassistant")
        if not (h and h.snap) then return res:error(404, "Home Assistant isn't connected") end
        local e = h.snap.byId[req.json().id or ""]
        if not e then return res:error(404, "No such device") end
        local Model = require("hamodel")
        local action = Model.tapAction(e, h.prefs)
        if not action.service or action.camera or action.sheet then
            return res:error(400, "Open it on the Kindle to change it")
        end
        h:act(e, action.service, action.data)
        res:json({ ok = true, tile = tile(Model, e, h.prefs) })
    end)

    -- A saved SSH command run on the Kindle, its output shown there: { ref = "host/command" }.
    server:route("POST", "^/api/dashboard/ssh$", function(req, res)
        local s = Common.plugin("sshclient")
        if not (s and s.onRunSSHCommand) then return res:error(404, "SSH isn't installed") end
        local ref = tostring(req.json().ref or "")
        local ok, M = pcall(require, "sshmodel")
        if ok and M.hostCommand and not M.hostCommand(s.store.data, ref) then
            return res:error(404, "That command was deleted")
        end
        UIManager:nextTick(function() s:onRunSSHCommand(ref) end)
        res:json({ ok = true })
    end)
end

return Web
