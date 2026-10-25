--[[--
The Files tab's Servers and catalogs card (needs the Library app,
library.koplugin): FTP and WebDAV servers and OPDS catalogs (KOReader's Cloud
storage and OPDS lists), the download folder, and Test in the background.
Passwords go to the Kindle but never come back to the page. The Library's
libraryweb does the work; these routes pass it on.
]]

local Common = require("webcommon")
local Files = require("webfiles")

local Web = {}

local function library()
    if not Common.plugin("library") then return nil end
    local ok, W = pcall(require, "libraryweb")
    return ok and W or nil
end

local ACTIONS = { saveServer = true, deleteServer = true, saveCatalog = true, addSuggested = true, deleteCatalog = true,
    restore = true, setDownloadDir = true }

function Web.routes(server)
    -- { installed, servers, catalogs, suggested, downloadDir (as the Files tab's paths), opds }.
    server:route("GET", "^/api/servers$", function(req, res)
        local W = library()
        if not W then return res:json({ installed = false }) end
        local out = W.state()
        out.installed = true
        out.downloadDir = Files.relative(out.downloadDir) or out.downloadDir
        res:json(out)
    end)

    -- { name, args }: saveServer { index?, type, name, address, port, username, password?, url },
    -- deleteServer { index } → { undo }, saveCatalog { index?, title, url, username, password? },
    -- addSuggested { url }, deleteCatalog { index } → { undo }, restore { key }, setDownloadDir { path }.
    server:route("POST", "^/api/servers/act$", function(req, res)
        local W = library()
        if not W then return res:error(404, "The Library app isn't installed") end
        local b = req.json()
        if not ACTIONS[b.name] then return res:error(400, "Unknown action") end
        local args = type(b.args) == "table" and b.args or {}
        if b.name == "setDownloadDir" then args = { path = Files.full(args.path) } end
        local r, err = W.act(b.name, args)
        if not r then return res:error(400, tostring(err or "Couldn't do that")) end
        res:json(r)
    end)

    -- Test: POST { kind = "server" | "catalog", index?, fields… } gives { key }; GET ?key= gives
    -- { status = "waiting" } or { status = "done", ok, folders, books, sections, why }.
    server:route("POST", "^/api/servers/test$", function(req, res)
        local W = library()
        if not W then return res:error(404, "The Library app isn't installed") end
        local r, err = W.testStart(req.json())
        if not r then return res:error(400, tostring(err)) end
        res:json(r)
    end)

    server:route("GET", "^/api/servers/test$", function(req, res)
        local W = library()
        local r = W and W.testResult(req.query.key)
        if not r then return res:error(404, "No such test") end
        res:json(r)
    end)
end

return Web
