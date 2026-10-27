--[[--
The web page's front page: the reader's battery, storage, KOReader version,
which of the plugins with pages here are installed, a picture of the
Kindle's screen, and text sent to Notes.
]]

local Common = require("webcommon")
local Device = require("device")

local Home = {}

function Home.routes(server, plugin)
    server:route("GET", "^/api/home$", function(req, res)
        local util = require("util")
        local Files = require("webfiles")
        local powerd = Device:getPowerDevice()
        local disk = util.diskUsage(Files.root()) or {}
        local ok, version = pcall(function() return require("version"):getShortVersion() end)
        res:json({
            model = Device.model or "KOReader",
            battery = powerd and powerd:getCapacity() or nil,
            charging = powerd and powerd:isCharging() or false,
            storage = { total = disk.total, available = disk.available },
            koreader = ok and version or "",
            time = os.time(),
            plugins = {
                apps = Common.plugin("apps") ~= nil,
                homeassistant = Common.plugin("homeassistant") ~= nil,
                todo = Common.plugin("todo") ~= nil,
                notes = Common.plugin("notes") ~= nil,
                -- Crosswords: its own plugin now (inside Notes before).
                crosswords = Common.plugin("crosswords") ~= nil or (Common.plugin("notes") or {}).crosswordSources ~= nil,
                wikipedia = Common.plugin("wikipedia") ~= nil,
                syncthing = Common.plugin("syncthing") ~= nil,
                sshclient = Common.plugin("sshclient") ~= nil,
                -- FlashForge: an optional app (optional/ in the repo).
                flashforge = Common.plugin("flashforge") ~= nil,
                -- Pangolin: an optional app too.
                pangolin = Common.plugin("pangolin") ~= nil,
            },
            -- Notes can take typed text (a newer Notes).
            sendNotes = (Common.plugin("notes") or {}).addTextPage ~= nil,
            awake = plugin:keepsAwake(),
            tabs = G_reader_settings:readSetting("webpage_tabs") or {},
        })
    end)

    -- The tabs' order and the hidden ones (System > Tabs): { order = { page… }, hidden = { page… } },
    -- kept on the Kindle so every phone and computer shows the same. Home and System stay shown.
    server:route("POST", "^/api/tabs$", function(req, res)
        local b = req.json() or {}
        local function pages(list)
            local out = {}
            for __, p in ipairs(type(list) == "table" and list or {}) do
                if type(p) == "string" and p:match("^[%w_-]+$") then table.insert(out, p) end
            end
            return out
        end
        local hidden = {}
        for __, p in ipairs(pages(b.hidden)) do
            if p ~= "home" and p ~= "system" then table.insert(hidden, p) end
        end
        local order = pages(b.order)
        if #order == 0 and #hidden == 0 then
            G_reader_settings:delSetting("webpage_tabs")
        else
            G_reader_settings:saveSetting("webpage_tabs", { order = order, hidden = hidden })
        end
        G_reader_settings:flush()
        res:json({ ok = true })
    end)

    -- The sleep screen To Do, Home Assistant and Apps share: which one draws
    -- it, and how often it is drawn again while asleep.
    server:route("GET", "^/api/sleep$", function(req, res)
        local src = G_reader_settings:readSetting("sleep_screen_app")
        local todo = Common.plugin("todo")
        if src == nil and todo and todo.opt and todo:opt("sleep_screen") then src = "todo" end
        local choices = { { "none", "KOReader's own" } }
        if todo then table.insert(choices, { "todo", "To Do tasks" }) end
        if Common.plugin("homeassistant") then table.insert(choices, { "homeassistant", "Home Assistant" }) end
        if Common.plugin("apps") then table.insert(choices, { "apps", "Summary" }) end
        if Common.plugin("apps") and Common.plugin("apps").showMode then table.insert(choices, { "widgets", "Widgets" }) end
        res:json({
            supported = not (Device.supportsScreensaver and not Device:supportsScreensaver()),
            choices = choices, app = src or "none",
            update = G_reader_settings:readSetting("sleep_screen_update") or 0,
        })
    end)

    server:route("POST", "^/api/sleep$", function(req, res)
        local b = req.json()
        if type(b.app) == "string" then
            local ok = { none = true, todo = Common.plugin("todo") ~= nil, homeassistant = Common.plugin("homeassistant") ~= nil, apps = Common.plugin("apps") ~= nil, widgets = Common.plugin("apps") ~= nil }
            if not ok[b.app] then return res:error(400, "Not on this Kindle") end
            if b.app == "none" then G_reader_settings:delSetting("sleep_screen_app") else G_reader_settings:saveSetting("sleep_screen_app", b.app) end
            local todo = Common.plugin("todo")
            if todo and todo.setOpt then pcall(todo.setOpt, todo, "sleep_screen", b.app == "todo") end
        end
        if type(b.update) == "number" then
            if b.update ~= 0 and b.update ~= 15 and b.update ~= 30 and b.update ~= 60 then return res:error(400, "Every 15, 30 or 60 minutes") end
            if b.update == 0 then G_reader_settings:delSetting("sleep_screen_update") else G_reader_settings:saveSetting("sleep_screen_update", b.update) end
        end
        G_reader_settings:flush()
        res:json({ ok = true })
    end)

    -- What is on the Kindle's screen now, as a picture.
    server:route("GET", "^/api/screen$", function(req, res)
        local util = require("util")
        local cache = require("datastorage"):getDataDir() .. "/cache"
        util.makePath(cache)
        local path = cache .. "/webpage-screen.png"
        os.remove(path)
        local ok = pcall(function() Device.screen:shot(path) end)
        if not ok or not require("libs/libkoreader-lfs").attributes(path, "mode") then
            return res:error(500, "Can't take a picture of the screen")
        end
        res:file(path, "kindle-screen.png", true)
        os.remove(path)
    end)

    -- Typing on the Kindle: the text into the box open there (the apps' shared box, or
    -- KOReader's own), at its cursor, as its keyboard would; `enter`: then its Enter
    -- (the box's main button). The topmost box takes it.
    server:route("POST", "^/api/kindle/type$", function(req, res)
        local b = req.json() or {}
        local text = type(b.text) == "string" and b.text or ""
        local UIManager = require("ui/uimanager")
        local stack = UIManager._window_stack or {}
        for i = #stack, 1, -1 do
            local w = stack[i].widget
            -- (The shared box's field, or InputDialog's.)
            local field = (w.is_shared_popup and w.field) or w._input_widget
            if field and field.addChars then
                if text ~= "" then field:addChars(text) end
                if w.is_shared_popup and w.redraw then w:redraw() else UIManager:setDirty(w, "ui") end
                if b.enter then
                    UIManager:nextTick(function()
                        if field.enter_callback then field.enter_callback()
                        elseif field.addChars then field:addChars("\n") end
                    end)
                end
                return res:json({ ok = true, title = w.title })
            end
        end
        res:error(409, "No box to type in is open on the Kindle. Open one there first (a search, a new task…).")
    end)

    -- Text for Notes: a new page with it typed on (Notes says where).
    server:route("POST", "^/api/send/notes$", function(req, res)
        local notes = Common.plugin("notes")
        if not (notes and notes.addTextPage) then return res:error(404, "Notes can't take text yet") end
        local b = req.json()
        if type(b.text) ~= "string" or b.text:match("^%s*$") then return res:error(400, "Nothing to send") end
        local ok, where = pcall(notes.addTextPage, notes, b.text)
        if not ok or not where then return res:error(500, tostring(where or "Couldn't add it")) end
        res:json({ ok = true, where = where })
    end)
end

return Home
