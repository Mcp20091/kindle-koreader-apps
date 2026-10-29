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

local KEEP = { 25, 50, 100, 200 }
local SECTIONS = { "featured", "onthisday", "news", "mostread" }

-- The settings, as the Kindle's Wikipedia settings have them.
local function settings(w)
    local s = w.store
    local M = require("wikimodel")
    local languages = {}
    for __, l in ipairs(M.LANGUAGES) do table.insert(languages, { code = l[1], name = l[2] }) end
    local sections = s:read("sections")
    local out = { installed = true, toolbar = s:read("toolbar") == "top" and "top" or "left", images = s:read("images") == true,
        lang = s:lang(), languages = languages, link_tap = s:read("link_tap") == "open" and "open" or "preview",
        folder = s:folder(), sections = {}, keep_recent = s:read("keep_recent"), keep_choices = KEEP,
        in_history = s:read("in_history") ~= false }
    for __, k in ipairs(SECTIONS) do out.sections[k] = sections[k] == true end
    return out
end

local function setSettings(w, b)
    local s = w.store
    if b.toolbar ~= nil and b.toolbar ~= "left" and b.toolbar ~= "top" then return nil, "Toolbar: Left or Top" end
    if b.link_tap ~= nil and b.link_tap ~= "preview" and b.link_tap ~= "open" then return nil, "Tap a link: Preview or Open" end
    if b.lang ~= nil and not lang(b.lang) then return nil, "Not a language code" end
    if b.keep_recent ~= nil then
        local ok
        for __, n in ipairs(KEEP) do if n == b.keep_recent then ok = true end end
        if not ok then return nil, "Keep recent: 25, 50, 100 or 200" end
    end
    if b.folder ~= nil then
        if type(b.folder) ~= "string" or b.folder:sub(1, 1) ~= "/" or
                require("libs/libkoreader-lfs").attributes(b.folder, "mode") ~= "directory" then
            return nil, "That folder isn't on the Kindle"
        end
    end
    if b.toolbar ~= nil then w:setToolbar(b.toolbar) end
    if b.images ~= nil then s:write("images", b.images == true) end
    if b.lang ~= nil then s:write("lang", lang(b.lang)) end
    if b.link_tap ~= nil then s:write("link_tap", b.link_tap) end
    if b.folder ~= nil then s:write("folder", (b.folder:gsub("(.)/$", "%1"))) end
    if type(b.sections) == "table" then
        local sections = s:read("sections")
        for __, k in ipairs(SECTIONS) do
            if b.sections[k] ~= nil then sections[k] = b.sections[k] == true end
        end
        s:write("sections", sections)
    end
    if b.keep_recent ~= nil then s:write("keep_recent", b.keep_recent) end
    if b.in_history ~= nil then
        s:write("in_history", b.in_history == true)
        w:tidyHistory()
    end
    if b.clear_recent == true then s:clearRecent() end
    return settings(w)
end

function Web.routes(server)
    -- ?q=: the saved articles whose title has it (the header search).
    server:route("GET", "^/api/wikipedia/search$", function(req, res)
        local w = wiki()
        if not w or not w.searchSaved then return res:json({ articles = {} }) end
        local q = tostring(req.query.q or ""):lower():match("^%s*(.-)%s*$")
        if #q < 2 then return res:json({ articles = {} }) end
        local out = {}
        for __, a in ipairs(w:searchSaved(q)) do
            table.insert(out, { title = a.title, description = a.sub })
        end
        res:json({ articles = out })
    end)

    -- The settings page of the Kindle's Wikipedia, on the web tab (Settings card).
    server:route("GET", "^/api/wikipedia/settings$", function(req, res)
        local w = wiki()
        if not w then return res:json({ installed = false }) end
        res:json(settings(w))
    end)
    -- Any of: toolbar, images, lang, link_tap, folder, sections = { featured, onthisday, news, mostread },
    -- keep_recent, in_history, clear_recent = true.
    server:route("POST", "^/api/wikipedia/settings$", function(req, res)
        local w = wiki()
        if not w then return res:error(404, "Wikipedia isn't installed") end
        local out, why = setSettings(w, req.json())
        if not out then return res:error(400, why) end
        res:json(out)
    end)

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
