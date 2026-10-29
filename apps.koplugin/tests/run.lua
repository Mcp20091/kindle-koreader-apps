-- Plain Lua tests: `luajit tests/run.lua` from the plugin folder.
package.path = "./?.lua;" .. package.path
local Model = require("appsmodel")

-- The apps as they register themselves at start (PS.appInfo, appsinfo.lua): the tests'
-- stand-in for PluginShare, with the real apps' tiles, orders and groups.
local function tile(key, extra)
    local t = { key = key, line = function() return "" end }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
package.loaded["pluginshare"] = { appInfo = {
    homeassistant = { name = "Home Assistant", icon = "house", order = 10, group = "home",
        tiles = { tile("ha"), tile("dashboard", { name = "Dashboard", fresh = true, shown = function() return true end }) } },
    todo = { name = "To Do", order = 20, group = "tools", tiles = { tile("todo") } },
    notes = { name = "Notes", order = 30, group = "writing", explore = "Handwritten notebooks", tiles = { tile("notes") } },
    crosswords = { name = "Crosswords", icon = "newspaper", order = 40, group = "writing", tiles = { tile("crosswords", { icon = "grid-3x3" }) } },
    library = { name = "Library", order = 45, group = "reading", gestures = {} },
    wikipedia = { name = "Wikipedia", order = 50, group = "reading", tiles = { tile("wikipedia") } },
    syncthing = { name = "Syncthing", order = 60, group = "tools", tiles = { tile("syncthing") },
        gestures = { "^syncthing_", "^toggle_syncthing_server$" } },
    sshclient = { name = "SSH", icon = "terminal", order = 70, group = "tools", tiles = { tile("ssh") } },
    flashforge = { name = "FlashForge", order = 80, group = "optional", tiles = { tile("flashforge", { group = "tools" }) } },
    pangolin = { name = "Pangolin", order = 85, group = "optional", tiles = { tile("pangolin", { group = "tools" }) } },
    nextdns = { name = "NextDNS", icon = "ban", dir = "/plugins/nextdns.koplugin", order = 87, group = "optional", tiles = { tile("nextdns", { group = "tools" }) } },
    pfsense = { name = "pfSense", order = 88, group = "optional", tiles = { tile("pfsense", { group = "tools" }) } },
    webpage = { name = "Web server", order = 90, group = "tools", tiles = { tile("web", { switches = true }) } },
} }

local failed, passed = 0, 0
local function check(name, got, want)
    if got == want then passed = passed + 1 else
        failed = failed + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    end
end
local function keys(tiles)
    local out = {}
    for i, t in ipairs(tiles) do out[i] = t.key end
    return table.concat(out, ",")
end
local all = function() return true end
local none = function() return false end

check("longest streak", Model.longestStreak({ "2026-10-20", "2026-10-02", "2026-10-21", "2026-10-03", "2026-10-22", "2026-10-04", "2026-10-05" }), 4)
check("longest streak, one day", Model.longestStreak({ "2026-10-20" }), 1)
check("longest streak, none", Model.longestStreak({}), 0)
check("longest streak over a month's end", Model.longestStreak({ "2026-09-30", "2026-10-01", "2026-10-02" }), 3)
check("peak hours", Model.peakHours({ [21] = 600, [22] = 900, [8] = 1000 }), 21)
check("peak hours around midnight", Model.peakHours({ [23] = 600, [0] = 600, [12] = 900 }), 23)
check("peak hours, none", Model.peakHours({}), nil)
check("off to start with: Gestures, Battery, KOReader settings", Model.isHidden(nil, { key = "fonts", offByDefault = true }), true)
check("off to start with, shown again", Model.isHidden({ fonts = false }, { key = "fonts", offByDefault = true }), false)
-- Quick buttons.
do
    local list = Model.quickList({ quick_off = { light = true } })
    check("quick: from before", Model.quickKey(list[1]) .. "," .. Model.quickKey(list[2]) .. "," .. #list, "b:wifi,b:night,3")
    local q = { { b = "wifi" }, { b = "newtask" }, { group = "g1", name = "Bedroom", items = { { b = "night" } } }, { pin = { kind = "todo", id = "L1" } } }
    local tiles = Model.quickTiles(q)
    check("quick: tiles they do (groups too)", tostring(tiles.wifi) .. tostring(tiles.night) .. tostring(tiles.light), "truetruenil")
    Model.quickMove(q, "b:newtask", -1)
    check("quick: move up", Model.quickKey(q[1]), "b:newtask")
    Model.quickPut(q, "pin:todo:L1", "g:g1")
    check("quick: into a group", #q .. "," .. #q[3].items .. "," .. Model.quickKey(q[3].items[2]), "3,2,pin:todo:L1")
    Model.quickMove(q, "pin:todo:L1", -1)
    check("quick: move inside a group", Model.quickKey(q[3].items[1]), "pin:todo:L1")
    local e, l, i = Model.quickRemove(q, "b:night")
    check("quick: remove from a group", tostring(e.b) .. "," .. #q[3].items .. "," .. i, "night,1,2")
    Model.quickPut(q, "pin:todo:L1", nil)
    check("quick: out of a group", #q .. "," .. Model.quickKey(q[4]), "4,pin:todo:L1")
    check("quick: another app's button", Model.quickKey({ app = "homeassistant", id = "light.kitchen" }), "a:homeassistant:light.kitchen")
    check("quick: groups don't go in groups", (function() Model.quickPut(q, "g:g1", "g:g1") return #q end)(), 4)
end
check("all tiles", keys(Model.tiles(nil, nil, all)), "reading,library,readingtime,weather,ha,dashboard,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,nextdns,pfsense,web,fonts,settings,wifi,light,night,exit")
check("missing plugins left out", keys(Model.tiles(nil, nil, none)), "reading,library,weather,fonts,settings,wifi,night,exit")
check("saved order first", keys(Model.tiles({ "todo", "ha" }, nil, all)), "todo,ha,reading,library,readingtime,weather,dashboard,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,nextdns,pfsense,web,fonts,settings,wifi,light,night,exit")
check("hidden left out", keys(Model.tiles(nil, { library = true, wifi = true }, all)), "reading,readingtime,weather,ha,dashboard,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,nextdns,pfsense,web,fonts,settings,light,night,exit")
check("hidden kept when asked", #Model.tiles(nil, { library = true }, all, true), 27)
check("off by default: hidden to start with", Model.isHidden(nil, { key = "restart", offByDefault = true }), true)
check("off by default: shown when set so", Model.isHidden({ restart = false }, { key = "restart", offByDefault = true }), false)
check("a usual tile shown", Model.isHidden({}, { key = "exit" }), false)
local tiles = Model.tiles(nil, nil, all)
check("move later", table.concat(Model.move(tiles, "reading", 1), ","), "library,reading,readingtime,weather,ha,dashboard,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,nextdns,pfsense,web,fonts,settings,wifi,light,night,exit")
check("move past the start stays", table.concat(Model.move(tiles, "reading", -1), ","), "reading,library,readingtime,weather,ha,dashboard,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,nextdns,pfsense,web,fonts,settings,wifi,light,night,exit")
-- Pins: tiles of their own after the apps, keyed by what they open; not twice; removed by key.
local pins = {}
local added
pins, added = Model.addPin(pins, { kind = "ha", name = "Security", icon = "shield-check", route = { kind = "security" } })
check("pin added", added, true)
pins, added = Model.addPin(pins, { kind = "ha", name = "Security", route = { kind = "security" } })
check("pin not twice", added, false)
pins = Model.addPin(pins, { kind = "ha", name = "Kitchen", route = { kind = "room", name = "Kitchen" } })
pins = Model.addPin(pins, { kind = "todo", name = "Groceries", id = "L9" })
pins = Model.addPin(pins, { kind = "note", name = "Ideas", id = "nb1" })
check("pins after the apps", keys(Model.tiles(nil, nil, all, false, pins)),
    "reading,library,readingtime,weather,ha,dashboard,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,nextdns,pfsense,web,fonts,settings,wifi,light,night,exit,pin:ha:security:,pin:ha:room:Kitchen,pin:todo:L9,pin:note:nb1")
check("pins of missing plugins left out", keys(Model.tiles(nil, nil, function(p) return p == "todo" end, false, pins)),
    "reading,library,weather,todo,fonts,settings,wifi,night,exit,pin:todo:L9")
check("pins in the saved order", keys(Model.tiles({ "pin:todo:L9", "reading" }, nil, none, false, pins)), "reading,library,weather,fonts,settings,wifi,night,exit")
check("pin ordered first", keys(Model.tiles({ "pin:ha:room:Kitchen" }, nil, all, false, pins)):sub(1, 19), "pin:ha:room:Kitchen")
check("folder pin key", Model.pinKey({ kind = "notefolder", id = "Work/Clients" }), "pin:notefolder:Work/Clients")
check("folder pin needs Notes", Model.pinTile({ kind = "notefolder", id = "Work" }).plugin, "notes")
check("pin removed", #Model.removePin(pins, "pin:ha:security:"), 3)
local per, pages = Model.paging(12, 2, 110, 12, 600)
check("paging: rows that fit", per, 10)
check("paging: pages", pages, 2)
per, pages = Model.paging(4, 2, 110, 12, 600)
check("paging: one page", pages, 1)
check("light needs a front light", keys(Model.tiles(nil, nil, function(p) return p ~= "@frontlight" end)):find("light,") == nil, true)
check("book name", Model.bookName("/mnt/us/documents/The Hobbit.epub"), "The Hobbit")
check("no book", Model.bookName(nil), "")

-- Groups and the quick buttons: the main page and a group's page.
do
    check("a quick button turned off keeps its tile", keys(Model.page(Model.tiles(nil, nil, function() return true end), nil, nil, nil, { night = true })):find("wifi") ~= nil, true)
    local all = Model.tiles(nil, nil, function() return true end, false, nil, { { id = "g1", name = "Smart home" } })
    local main = Model.page(all, { { id = "g1", name = "Smart home" } }, { ha = "g1", dashboard = "g1" }, nil, { wifi = true, light = true, night = true })
    check("main page: grouped and quick-button tiles left off", keys(main), "reading,library,readingtime,weather,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,nextdns,pfsense,web,fonts,settings,exit,group:g1")
    check("a group's page", keys(Model.page(all, { { id = "g1" } }, { ha = "g1", dashboard = "g1" }, "g1", { wifi = true })), "ha,dashboard")
    check("a gone group's tiles come back", #Model.page(all, {}, { ha = "g9" }, nil, nil), #all)
    check("move among a page", table.concat(Model.moveAmong({ "a", "b", "c", "d" }, { "a", "c", "d" }, "c", -1), ","), "c,b,a,d")
end

-- What the apps say about themselves (appsinfo.lua): nothing in the launcher names them.
do
    local Info = require("appsinfo")
    check("apps in their order", table.concat(Info.order(), ","), "homeassistant,todo,notes,crosswords,library,wikipedia,syncthing,sshclient,flashforge,pangolin,nextdns,pfsense,webpage")
    check("a tile gets its app's plugin", Info.tile("ssh").plugin, "sshclient")
    check("a tile keeps its own icon", Info.tile("crosswords").icon .. "," .. Info.tile("ha").icon, "grid-3x3,house")
    check("a tile goes in its app's group", Info.tile("dashboard").group, "home")
    check("an optional app's tile in the suggested Tools group", Info.tile("pangolin").group, "tools")
    local pats = table.concat(Info.gestures(), " ")
    check("gestures: the app's name to start with", pats:find("^%^homeassistant_", 1) ~= nil and pats:find("%^crosswords_", 1, false) ~= nil, true)
    check("gestures: an app's own", pats:find("toggle_syncthing_server", 1, true) ~= nil, true)
    check("gestures: none when it says so", pats:find("library", 1, true), nil)
    check("notification name", (Info.nameOf("sshclient")), "SSH")
    check("the apps' folders, for their icons", table.concat(Info.dirs(), ","), "/plugins/nextdns.koplugin")
    local labels = {}
    for __, a in ipairs(Info.labelApps()) do labels[#labels + 1] = a.key end
    check("Button labels: each app's first tile, not a switch", table.concat(labels, ","), "ha,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,nextdns,pfsense")
    -- A new app: its tile, group and gestures with no change to the launcher.
    local PS = package.loaded["pluginshare"]
    PS.appInfo.printer3 = { name = "Printer", icon = "printer", order = 88, group = "tools", tiles = { tile("printer3", { event = "ShowPrinter" }) } }
    check("a new app's tile in its place", keys(Model.tiles(nil, nil, all)):find("nextdns,printer3,pfsense,web", 1, true) ~= nil, true)
    local tools
    for __, sg in ipairs(Model.suggestions(Model.tiles(nil, nil, all), {}, {})) do
        if sg.group.key == "tools" then tools = keys(sg.tiles) end
    end
    check("a new app in its suggested group", tools, "todo,syncthing,ssh,flashforge,pangolin,nextdns,printer3,pfsense,web")
    check("a new app's gestures", table.concat(Info.gestures(), " "):find("^printer3_", 1, true) ~= nil, true)
    PS.appInfo.printer3 = nil
    -- An app's tile hidden while it says so (Home Assistant's Dashboard, not set up).
    local shown = PS.appInfo.homeassistant.tiles[2].shown
    PS.appInfo.homeassistant.tiles[2].shown = function() return false end
    check("a tile not shown now", keys(Model.tiles(nil, nil, all)):find("dashboard", 1, true), nil)
    PS.appInfo.homeassistant.tiles[2].shown = function() error("broken") end
    check("a tile whose check fails isn't shown", keys(Model.tiles(nil, nil, all)):find("dashboard", 1, true), nil)
    PS.appInfo.homeassistant.tiles[2].shown = shown
end

check("web button starts hidden", Model.quickOn(nil, "web"), false)
check("web button turned on", Model.quickOn({ web = false }, "web"), true)
check("night button turned off", Model.quickOn({ night = true }, "night"), false)

-- Days read in a row.
check("streak from today", Model.streak({ "2026-10-21", "2026-10-20", "2026-10-19", "2026-10-17" }, "2026-10-21", "2026-10-20"), 3)
check("streak from yesterday", Model.streak({ "2026-10-20", "2026-10-19" }, "2026-10-21", "2026-10-20"), 2)
check("streak broken", Model.streak({ "2026-10-18" }, "2026-10-21", "2026-10-20"), 0)
check("streak over a month", Model.streak({ "2026-11-01", "2026-10-31" }, "2026-11-01", "2026-10-31"), 2)
check("duration minutes", Model.duration(25 * 60), "25 min")
check("duration hours", Model.duration(65 * 60), "1 h 5 min")
check("book lines: all", table.concat(Model.bookLines{ chapter = "Chapter 3", chapterLeft = 12, page = 120, pages = 340, avg = 50, read = 5 * 3600 }, " | "),
    "Chapter 3 · 12 pages left in the chapter | Page 120 of 340 · About 3 h 3 min left · 5 h read")
check("book lines: one page left, no stats", table.concat(Model.bookLines{ chapterLeft = 1, page = 10, pages = 20 }, " | "),
    "1 page left in the chapter | Page 10 of 20")
check("book lines: last page, under a minute read", table.concat(Model.bookLines{ chapter = "", page = 20, pages = 20, avg = 40, read = 30 }, " | "),
    "Page 20 of 20")
check("book lines: a chapter's last page", table.concat(Model.bookLines{ chapter = "3. Inland", chapterLeft = 0 }, " | "),
    "3. Inland · Last page of the chapter")
check("book lines: nothing known", table.concat(Model.bookLines{}, " | "), "")
-- AI (appsaiclient.lua): the requests to each service.
do
local json = dofile("tests/json.lua")
local Claude = require("appsaiclient")
local sentReq
local function claudeWith(status, reply, model)
    return Claude.new{ key = "sk-test", model = model, json = json, b64 = function(b) return "B64(" .. b .. ")" end,
        request = function(method, url, headers, body)
            sentReq = { method = method, url = url, headers = headers, body = json.decode(body) }
            return status, reply
        end }
end
local c = claudeWith(200, json.encode({ stop_reason = "end_turn", content = {
    { type = "thinking", thinking = "" }, { type = "text", text = "  Buy milk\n- [ ] Call Vet  " } } }))
check("transcription text", c:transcribe("PNG"), "Buy milk\n- [ ] Call Vet")
check("sent to the Messages API", sentReq.url, "https://api.anthropic.com/v1/messages")
check("key header", sentReq.headers["x-api-key"], "sk-test")
check("version header", sentReq.headers["anthropic-version"], "2023-06-01")
check("default model", sentReq.body.model, "claude-opus-5-5")
check("image first", sentReq.body.messages[1].content[1].source.data, "B64(PNG)")
check("png media type", sentReq.body.messages[1].content[1].source.media_type, "image/png")
check("fallback on", sentReq.body.fallbacks, "default")
check("fallback beta header", sentReq.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
claudeWith(200, json.encode({ content = {} }), "claude-haiku-5-5"):transcribe("PNG")
check("no fallback for haiku", sentReq.body.fallbacks, nil)
check("no beta header for haiku", sentReq.headers["anthropic-beta"], nil)
local text, why = claudeWith(401, json.encode({ error = { type = "authentication_error", message = "invalid x-api-key" } })):transcribe("P")
check("bad key explained", text == nil and why:find("API key") ~= nil, true)
text, why = claudeWith(400, json.encode({ error = { message = "Your credit balance is too low to access the Anthropic API." } })):transcribe("P")
check("no credit explained", why:find("claude.ai > Settings > Billing", 1, true) ~= nil, true)
text, why = claudeWith(200, json.encode({ stop_reason = "refusal", content = {} })):transcribe("P")
check("refusal reported", why, "Claude declined this page.")
text, why = Claude.new{ json = json }:transcribe("P")
check("no key, no request", text == nil and why:find("No API key") ~= nil, true)
check("thinking off by default", Claude.serverBody("m", nil, "p", nil, nil).reasoning_effort, "none")
check("thinking on when asked", Claude.serverBody("m", nil, "p", nil, nil, true).reasoning_effort, nil)
check("a question without a picture (Claude)", (function()
    claudeWith(200, json.encode({ content = { { type = "text", text = "OK" } } })):transcribe(nil, "Reply OK")
    return #sentReq.body.messages[1].content .. sentReq.body.messages[1].content[1].type
end)(), "1text")

-- Your own server (Ollama at home, Pangolin away).
check("chat url from an Ollama address", Claude.chatUrl("http://192.168.1.50:11434/"), "http://192.168.1.50:11434/v1/chat/completions")
check("chat url from a /v1 address", Claude.chatUrl("https://ai.example.com/v1"), "https://ai.example.com/v1/chat/completions")
check("chat url left as given", Claude.chatUrl("https://x/v1/chat/completions"), "https://x/v1/chat/completions")
local sbody = Claude.serverBody("gemma4", "PNG", "Read this", { "PNG2" }, function(b) return "B(" .. b .. ")" end)
check("server body: model", sbody.model, "gemma4")
check("server body: text first", sbody.messages[1].content[1].text, "Read this")
check("server body: picture as data url", sbody.messages[1].content[2].image_url.url, "data:image/png;base64,B(PNG)")
check("server body: second picture", sbody.messages[1].content[3].image_url.url, "data:image/png;base64,B(PNG2)")
check("server text, thinking left out", Claude.serverText({ choices = { { message = { content = "<think>hmm</think>\n Buy milk " } } } }), "Buy milk")
local calls2 = {}
local function serverWith(reply, homeUp)
    calls2 = {}
    return Claude.new{ json = json, b64 = function(b) return b end,
        request = function(method, url, headers, body)
            table.insert(calls2, { url = url, auth = headers.Authorization })
            if url:find("^http://home") and not homeUp then return "connection refused", "" end
            return reply[1], reply[2]
        end,
        server = { urls = { "http://home:11434", "https://ai.example.com" }, keys = { nil, "pangolin-key-1.abc" }, model = "gemma4" } }
end
local s1 = serverWith({ 200, json.encode({ choices = { { message = { content = "OK" } } } }) }, true)
local t1, via1 = s1:transcribe("PNG", "Read")
check("server at home answers", t1 .. "/" .. via1, "OK/1")
check("no key sent at home", calls2[1].auth, nil)
local s2 = serverWith({ 200, json.encode({ choices = { { message = { content = "OK" } } } }) }, false)
local t2, via2 = s2:transcribe("PNG", "Read")
check("away: Pangolin answers", t2 .. "/" .. via2, "OK/2")
check("Pangolin gets the key", calls2[2].auth, "Bearer pangolin-key-1.abc")
local t3, why3 = serverWith({ 401, json.encode({ error = { message = "bad key" } }) }, false):transcribe("PNG", "Read")
check("refused key explained", t3 == nil and why3:find("refused the key", 1, true) ~= nil, true)
local t4, why4 = serverWith({ 404, json.encode({ error = { message = "model 'gemma4' not found" } }) }, true):transcribe("PNG", "Read")
check("missing model explained", t4 == nil and why4:find("no model", 1, true) ~= nil, true)
local t5, why5 = Claude.new{ json = json, server = { urls = {}, model = "gemma4" } }:transcribe("PNG", "Read")
check("no address explained", t5 == nil and why5:find("No local AI address", 1, true) ~= nil, true)

-- AI services in one list: addresses, saved choices, keys and errors.
do
check("chat url from an /openai address (Gemini's)", Claude.chatUrl("https://generativelanguage.googleapis.com/v1beta/openai/"),
    "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
for _, p in ipairs(Claude.PROVIDERS) do
    if p.url then check(p.name .. "'s chat url left as given", Claude.chatUrl(p.url), p.url) end
    if p.models then check(p.name .. "'s default model is in its list", p.models[1] == p.model, true) end
end
check("saved Claude stays Claude", Claude.providerId("claude"), "claude")
check("saved local AI stays local AI", Claude.providerId("server"), "server")
check("nothing saved is Claude", Claude.providerId(nil), "claude")
check("an unknown service is Claude", Claude.providerId("nonesuch"), "claude")
check("Gemini is in the list", Claude.PROVIDER.gemini.name, "Gemini")
local pbody = Claude.serverBody("gemini-x", nil, "p", nil, nil, true, 32768)
check("services: no reasoning_effort sent", pbody.reasoning_effort, nil)
check("services: their answer room", pbody.max_tokens, 32768)
local pcalls = {}
local function serviceWith(reply)
    pcalls = {}
    return Claude.new{ json = json, b64 = function(b) return b end,
        request = function(method, url, headers, body)
            table.insert(pcalls, { url = url, auth = headers.Authorization, body = body })
            return reply[1], reply[2]
        end,
        server = { name = "Gemini", urls = { Claude.PROVIDER.gemini.url }, keys = { "AIza-test" }, model = "gemini-x",
            think = true, maxTokens = 32768 } }
end
local g1 = serviceWith({ 200, json.encode({ choices = { { message = { content = "OK" } } } }) }):transcribe("PNG", "Read")
check("a service answers", g1, "OK")
check("a service gets its key", pcalls[1].auth, "Bearer AIza-test")
check("a service gets its address", pcalls[1].url, Claude.PROVIDER.gemini.url)
local g2, gwhy2 = serviceWith({ 429, json.encode({ error = { message = "quota" } }) }):transcribe("PNG", "Read")
check("a free tier's limit explained", g2 == nil and gwhy2:find("too many requests", 1, true) ~= nil and gwhy2:find("Gemini", 1, true) ~= nil, true)
local g3, gwhy3 = serviceWith({ 401, "{}" }):transcribe("PNG", "Read")
check("a service's refused key names it", g3 == nil and gwhy3:find("Gemini refused the key", 1, true) ~= nil, true)
local g4, gwhy4 = Claude.new{ json = json, server = { name = "Custom", urls = {}, model = "m" } }:transcribe("PNG", "Read")
check("Custom with no address explained", g4 == nil and gwhy4:find("No address set for Custom", 1, true) ~= nil, true)
end

end

-- The shared Microsoft account (appsmicrosoft.lua).
do
    package.loaded["gettext"] = package.loaded["gettext"] or function(x) return x end
    local Account = dofile("appsmicrosoft.lua").Account
    local json = { decode = function(s)
        if s:find('"preferred_username"') then return { preferred_username = s:match('"preferred_username":"([^"]+)"') } end
        if s:find('"access_token"') then return { access_token = "A2", refresh_token = "R2", expires_in = 3600,
            scope = "Tasks.ReadWrite Notes.ReadWrite", id_token = s:match('"id_token":"([^"]+)"') } end
        return {} end, encode = function() return "" end }
    local store = {}
    local function newAccount(request)
        return Account.new{ store = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, save = function() end },
            request = request or function() end, json = json, now = function() return 1000 end,
            uses = function() return { { key = "todo", scope = "Tasks.ReadWrite" }, { key = "notes", scope = "Notes.ReadWrite" } } end }
    end
    local a = newAccount()
    check("ms: asks for every app's part", a:scopes(), "offline_access openid profile Tasks.ReadWrite Notes.ReadWrite")
    check("ms: adopts To Do's sign-in", a:adopt{ clientId = "C1", scope = "Tasks.ReadWrite offline_access",
        tokens = { refresh_token = "R1", access_token = "A1", expires_at = 5000, authority = "consumers" } }, true)
    check("ms: App ID adopted", a:clientId(), "C1")
    check("ms: signed in", a:signedIn(), true)
    check("ms: To Do allowed", a:allowed("Tasks.ReadWrite"), true)
    check("ms: OneNote not yet", a:allowed("Notes.ReadWrite"), false)
    check("ms: adopts only once", a:adopt{ tokens = { refresh_token = "OTHER" } }, false)
    check("ms: token still valid", a:accessToken(), "A1")
    -- {"preferred_username":"pat@example.com"} as a JWT's middle part (base64url).
    local idToken = "x.eyJwcmVmZXJyZWRfdXNlcm5hbWUiOiJwYXRAZXhhbXBsZS5jb20ifQ.y"
    check("ms: who from the id_token", Account.accountOf(json, idToken), "pat@example.com")
    local b = newAccount(function(method, url, headers, body)
        return 200, '{"access_token":"A2","id_token":"' .. idToken .. '"}'
    end)
    check("ms: refreshed", b:accessToken(true), "A2")
    check("ms: OneNote allowed after", b:allowed("Notes.ReadWrite"), true)
    check("ms: account kept", b:account(), "pat@example.com")
    b:forget()
    check("ms: signed out", b:signedIn(), false)
    check("ms: App ID stays", b:clientId(), "C1")
end

-- App lock (appslock.lua's core): made-up passcodes, a fake hash and clock.
do
    package.loaded["gettext"] = package.loaded["gettext"] or function(x) return x end
    package.loaded["ffi/util"] = package.loaded["ffi/util"] or { template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end }
    local hadPS = package.loaded["pluginshare"]
    package.loaded["pluginshare"] = { appInfo = {
        sshclient = { name = "SSH", order = 70, tiles = { { key = "ssh" } } },
        todo = { name = "To Do", order = 20, tiles = { { key = "todo" } } },
        homeassistant = { name = "Home Assistant", order = 10, tiles = { { key = "ha" }, { key = "dashboard" } }, lock = false },
        webpage = { name = "Web server", order = 90, tiles = { { key = "web", switches = true } } },
        library = { name = "Library", order = 45 },
    }, lockApps = { pfsense = { key = "pfsense", name = "pfSense", plugin = "pfsense" } } }
    local Lock = require("appslock")
    local data, clock, saves = {}, 1000, 0
    local l = Lock.new{ now = function() return clock end, random = function() return "salt1" end,
        hash = function(salt, secret) return salt .. ":" .. secret:reverse() end,
        store = { get = function(k) return data[k] end, set = function(k, v) data[k] = v end, save = function() saves = saves + 1 end } }
    check("lock: the apps that registered, by name, then Settings", (function()
        local names = {}
        for i, a in ipairs(Lock.apps()) do names[i] = a.key end
        return table.concat(names, ",")
    end)(), "pfsense,ssh,todo,settings")
    package.loaded["pluginshare"].appInfo.homeassistant.lock = nil
    check("lock: an app's other tiles find it", Lock.appOf("dashboard").plugin, "homeassistant")
    check("lock: no tile, or one that only switches: not listed", tostring((Lock.appOf("library"))) .. "," .. tostring((Lock.appOf("web"))), "nil,nil")
    check("lock: found by plugin name too", Lock.appOf("sshclient").key, "ssh")
    check("lock: nothing set, nothing locked", l:needs("ssh"), false)
    check("lock: a passcode is 4 to 8 digits", Lock.valid("passcode", "123"), "Use 4 to 8 digits.")
    check("lock: no letters in a passcode", Lock.valid("passcode", "12a4"), "Use 4 to 8 digits.")
    check("lock: 8 digits are fine", Lock.valid("passcode", "12345678"), true)
    check("lock: a password of 4 or more", Lock.valid("password", "abc"), "Use at least 4 characters.")
    check("lock: a short one isn't set", l:set("passcode", "12"), false)
    check("lock: set", l:set("passcode", "2468"), true)
    check("lock: kept as a hash, never the passcode", tostring(data.hash) .. "," .. tostring(data.salt), "salt1:8642,salt1")
    for k, v in pairs(data) do if v == "2468" then check("lock: the passcode itself saved as " .. k, true, false) end end
    check("lock: its length, for the keypad", l:digits(), 4)
    check("lock: unlocked right after setting it", l:isOpen(), true)
    l:setLocked("ssh", true)
    check("lock: one app locked", l:countLocked(), 1)
    check("lock: unlocked still", l:needs("ssh"), false)
    check("lock: an app not ticked never asks", (function() l:relock() return l:needs("todo") end)(), false)
    check("lock: asleep, it asks again", l:needs("ssh"), true)
    check("lock: by its plugin name too", l:needs("sshclient"), true)
    check("lock: something not an app never asks", l:needs("apps"), false)
    local ok, why = l:try("1111")
    check("lock: a wrong passcode", tostring(ok) .. "," .. why, "false,wrong")
    check("lock: still locked", l:needs("ssh"), true)
    check("lock: checked from the web page: right, still locked", tostring(l:check("2468")) .. "," .. tostring(l:needs("ssh")), "true,true")
    ok = l:try("2468")
    check("lock: the right one", ok, true)
    check("lock: open after", l:needs("ssh"), false)
    l:relock()
    l:try("1") l:try("2")
    local ok3, why3, left = l:try("3")
    check("lock: 3 wrong, then a wait", tostring(ok3) .. "," .. why3 .. "," .. left, "false,wait,30")
    check("lock: even the right one waits", select(2, l:try("2468")), "wait")
    check("lock: the line for a wait", Lock.why("passcode", "wait", 12.2), "Try again in 13 seconds.")
    check("lock: the line for a wrong password", Lock.why("password", "wrong"), "Wrong password. Try again.")
    clock = clock + 31
    check("lock: after the wait, the right one opens", l:try("2468"), true)
    l:setStay(5)
    check("lock: 5 minutes", l:isOpen(), true)
    clock = clock + 5 * 60
    check("lock: after 5 minutes it asks again", l:needs("ssh"), true)
    l:setStay("sleep")
    check("lock: until sleep is the default, not saved", data.stay, nil)
    l:set("password", "made-up words")
    check("lock: a password", l:kind() .. "," .. tostring(l:digits()), "password,nil")
    l:relock()
    check("lock: the password opens", l:try("made-up words"), true)
    l:clear()
    check("lock: turned off: nothing asks", l:needs("ssh"), false)
    check("lock: the apps stay ticked", l:apps().ssh, true)
    check("lock: no hash left", data.hash, nil)
    package.loaded["pluginshare"] = hadPS
end

-- Every Google Fonts family to browse (appsgooglefonts.lua): Google's catalogue kept short, then searched.
do
    local tmp = os.tmpname()
    package.loaded["datastorage"] = package.loaded["datastorage"] or { getDataDir = function() return "." end }
    package.loaded["ui/uimanager"] = package.loaded["ui/uimanager"] or {}
    local G = require("appsgooglefonts")
    G.cachePath = function() return tmp end
    local function fam(name, cat, fonts, pop, date)
        local f = {}
        for __, k in ipairs(fonts) do table.insert(f, '"' .. k .. '": { "thickness": 4 }') end
        return '{ "family": "' .. name .. '", "displayName": null, "category": "' .. cat .. '", "fonts": { '
            .. table.concat(f, ", ") .. ' }, "axes": [], "dateAdded": "' .. date .. '", "popularity": ' .. pop .. ' }'
    end
    local json = '{ "axisRegistry": [ { "tag": "wght", "family": "not one" } ], "familyMetadataList": [ '
        .. table.concat({
            fam("Sample Serif", "Serif", { "400", "400i", "700", "700i" }, 12, "2020-03-01"),
            fam("Lora", "Serif", { "400", "700" }, 3, "2011-05-01"),
            fam("Mono Example", "Monospace", { "400" }, 40, "2024-01-15"),
            fam("Quick Hand", "Handwriting", { "400", "400i" }, 7, "2026-09-30"),
            fam("Loraine Sans", "Sans Serif", { "300", "500" }, 9, "2018-07-07"),
            fam("Odd One", "Symbols", { "400" }, 1, "2019-01-01"),
        }, ", ") .. ' ] }'
    local parsed = G.parse(json)
    check("google list: families with a known category, popular first", (function()
        local n = {}
        for i, f in ipairs(parsed) do n[i] = f.name end
        return table.concat(n, ",")
    end)(), "Lora,Quick Hand,Loraine Sans,Sample Serif,Mono Example")
    check("google list: styles kept as flags", parsed[4].styles .. "," .. parsed[1].styles .. "," .. parsed[3].styles, "15,3,0")
    check("google list: date as a number", parsed[2].date, 20260930)
    local f = io.open(tmp, "wb")
    f:write(G.serialize(parsed, 1000))
    f:close()
    G.drop()
    local st = G.state()
    check("google list: read back from the cache", st.count .. "," .. st.at .. "," .. st.status, "5,1000,done")
    local function names(r)
        local n = {}
        for i, e in ipairs(r.items) do n[i] = e.name end
        return table.concat(n, ",")
    end
    check("google list: all, popular first", names(G.query{ cat = "all" }), "Lora,Quick Hand,Loraine Sans,Sample Serif,Mono Example")
    check("google list: a category", names(G.query{ cat = "serif" }), "Lora,Sample Serif")
    check("google list: A–Z", names(G.query{ cat = "all", sort = "az" }), "Lora,Loraine Sans,Mono Example,Quick Hand,Sample Serif")
    check("google list: newest first", names(G.query{ cat = "all", sort = "new" }), "Quick Hand,Mono Example,Sample Serif,Loraine Sans,Lora")
    check("google list: search, names that start with it first", names(G.query{ q = "LORA", cat = "suggested" }), "Lora,Loraine Sans")
    check("google list: search finds within names", names(G.query{ q = "hand", cat = "all" }), "Quick Hand")
    check("google list: an exact name", tostring(G.query{ q = "lora" }.exact) .. "," .. tostring(G.query{ q = "lor" }.exact), "true,false")
    local page = G.query{ cat = "all", from = 2, count = 2 }
    check("google list: a page of it", page.total .. ":" .. names(page), "5:Quick Hand,Loraine Sans")
    local one = G.query{ cat = "all", count = 1 }.items[1]
    check("google list: a row's words", one.category .. " · " .. one.styles, "Serif · Regular and Bold")
    check("google list: styles in words", G.stylesLabel(15) .. "|" .. G.stylesLabel(5) .. "|" .. G.stylesLabel(0) .. "|" .. G.stylesLabel(6),
        "4 styles|Regular and Italic|1 style|2 styles")
    local sug = G.query{}
    check("google list: suggestions, with their notes and what the list knows", sug.total .. "," .. sug.items[3].name .. "," .. tostring(sug.items[3].category) .. "," .. tostring(sug.items[1].category),
        #G.SUGGESTED .. ",Lora,Serif,nil")
    G.drop()
    os.remove(tmp)
    check("google list: none yet", G.state().status .. "," .. G.query{ cat = "all" }.total, "none,0")
end

-- PS.notifications is the plain list (To Do calls it); the web page's calls have their own names,
-- and only main.lua sets that one (an earlier table of the same name broke To Do's call).
do
    local function read(f) local h = assert(io.open(f, "rb")) local t = h:read("*a") h:close() return t end
    local notify, main = read("appsnotify.lua"), read("main.lua")
    check("notify doesn't set PS.notifications", notify:find("PS%.notifications%s*=") == nil, true)
    check("main sets PS.notifications to a function", main:find("PS%.notifications = function") ~= nil, true)
    for __, name in ipairs({ "notifyRows", "notifyOpen", "notifyRemove", "notifyClear" }) do
        check("notify sets PS." .. name, notify:find("PS%." .. name .. "%s*=") ~= nil, true)
    end
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
