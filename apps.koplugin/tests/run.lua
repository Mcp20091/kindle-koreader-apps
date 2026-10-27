-- Plain Lua tests: `luajit tests/run.lua` from the plugin folder.
package.path = "./?.lua;" .. package.path
local Model = require("appsmodel")

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
check("all tiles", keys(Model.tiles(nil, nil, all)), "reading,library,readingtime,weather,ha,dashboard,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,web,fonts,settings,wifi,light,night,exit")
check("missing plugins left out", keys(Model.tiles(nil, nil, none)), "reading,library,weather,fonts,settings,wifi,night,exit")
check("saved order first", keys(Model.tiles({ "todo", "ha" }, nil, all)), "todo,ha,reading,library,readingtime,weather,dashboard,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,web,fonts,settings,wifi,light,night,exit")
check("hidden left out", keys(Model.tiles(nil, { library = true, wifi = true }, all)), "reading,readingtime,weather,ha,dashboard,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,web,fonts,settings,light,night,exit")
check("hidden kept when asked", #Model.tiles(nil, { library = true }, all, true), 25)
check("off by default: hidden to start with", Model.isHidden(nil, { key = "restart", offByDefault = true }), true)
check("off by default: shown when set so", Model.isHidden({ restart = false }, { key = "restart", offByDefault = true }), false)
check("a usual tile shown", Model.isHidden({}, { key = "exit" }), false)
local tiles = Model.tiles(nil, nil, all)
check("move later", table.concat(Model.move(tiles, "reading", 1), ","), "library,reading,readingtime,weather,ha,dashboard,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,web,fonts,settings,wifi,light,night,exit")
check("move past the start stays", table.concat(Model.move(tiles, "reading", -1), ","), "reading,library,readingtime,weather,ha,dashboard,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,web,fonts,settings,wifi,light,night,exit")
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
    "reading,library,readingtime,weather,ha,dashboard,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,web,fonts,settings,wifi,light,night,exit,pin:ha:security:,pin:ha:room:Kitchen,pin:todo:L9,pin:note:nb1")
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
    check("main page: grouped and quick-button tiles left off", keys(main), "reading,library,readingtime,weather,todo,notes,crosswords,wikipedia,syncthing,ssh,flashforge,pangolin,web,fonts,settings,exit,group:g1")
    check("a group's page", keys(Model.page(all, { { id = "g1" } }, { ha = "g1", dashboard = "g1" }, "g1", { wifi = true })), "ha,dashboard")
    check("a gone group's tiles come back", #Model.page(all, {}, { ha = "g9" }, nil, nil), #all)
    check("move among a page", table.concat(Model.moveAmong({ "a", "b", "c", "d" }, { "a", "c", "d" }, "c", -1), ","), "c,b,a,d")
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

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
