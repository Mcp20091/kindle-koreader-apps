--[[--
Wikipedia on the web page (needs the Wikipedia plugin): the articles saved on
the Kindle (download the EPUB, remove), an article saved to the Kindle, and
what was read recently. The browser searches Wikipedia itself; the Kindle
downloads a saved article in a child process (the page asks until it is done),
so nothing here holds up the Kindle.
]]

local Common = require("webcommon")

local Web = {}

local function wiki()
    local w = Common.plugin("wikipedia")
    if w and w.webSaved then return w end
end

local function lang(s)
    return type(s) == "string" and s:match("^[%a][%a%-]*$") and s:lower() or nil
end

function Web.routes(server)
    -- { installed, lang, folder, saved = { { title, lang, description, size, time, file } }, recent }.
    server:route("GET", "^/api/wikipedia$", function(req, res)
        local w = wiki()
        if not w then return res:json({ installed = false }) end
        local saved = {}
        for __, a in ipairs(w:webSaved()) do
            table.insert(saved, { title = a.title, lang = a.lang, description = a.description, size = a.size, time = a.time, file = a.file })
        end
        res:json({ installed = true, lang = w.store:lang(), folder = w.store:folder(), saved = saved, recent = w:webRecent() })
    end)

    -- { title, lang }: the Kindle starts downloading it into the Wikipedia folder; { key }.
    server:route("POST", "^/api/wikipedia/save$", function(req, res)
        local w = wiki()
        if not w or not w.webSaveStart then return res:error(404, "Wikipedia isn't installed") end
        local b = req.json()
        if type(b.title) ~= "string" or b.title == "" then return res:error(400, "No article") end
        if not require("ui/network/manager"):isConnected() then return res:error(503, "The Kindle isn't online") end
        res:json({ key = w:webSaveStart(b.title, lang(b.lang)) })
    end)

    -- ?key=en:Paris: { state = "saving" | "saved" | "failed", title, message }.
    server:route("GET", "^/api/wikipedia/save$", function(req, res)
        local w = wiki()
        if not w or not w.webSaveState then return res:error(404, "Wikipedia isn't installed") end
        local job = w:webSaveState(req.query.key)
        if not job then return res:error(404, "No such download") end
        res:json({ state = job.state, title = job.title, message = job.message })
    end)

    -- { file }
    server:route("POST", "^/api/wikipedia/remove$", function(req, res)
        local w = wiki()
        if not w then return res:error(404, "Wikipedia isn't installed") end
        local b = req.json()
        if not w:webRemove(b.file) then return res:error(404, "No such article") end
        res:json({ ok = true })
    end)

    -- ?file=Nixon in China.EN.epub
    server:route("GET", "^/api/wikipedia/download$", function(req, res)
        local w = wiki()
        if not w then return res:error(404, "Wikipedia isn't installed") end
        local file = req.query.file
        if type(file) ~= "string" or file:find("/") or not file:match("%.epub$") then return res:error(400, "No such article") end
        local path = w.store:folder() .. "/" .. file
        if require("libs/libkoreader-lfs").attributes(path, "mode") ~= "file" then return res:error(404, "No such article") end
        res:file(path, file)
    end)
end

return Web
