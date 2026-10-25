--[[--
The AI settings on the Kindle (Settings > AI), drawn by the launcher as
every app's settings (PS.settingsPage): which AI does each job, the AI
services (each its own page: key and model, or addresses; Test it, Try a
prompt), Test connection and Advanced (each feature's instructions, how much
is sent, Preview). Notes', Crosswords' and SSH's settings open it from their
"AI settings" row. The work is appsai.lua.
]]

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local AI = require("appsai")
local KO = require("appsko")

local View = {}

local function PS() return require("pluginshare") end

-- Opened from another app (its settings): ‹ on the AI page goes back there.
local fromApp = false

-- The page drawn again after a change made in a dialog.
local function redraw()
    local v = PS().appsView and PS().appsView()
    if v and v.mode == "page" then
        v:render()
        UIManager:setDirty(v, "ui")
    end
end

local function page(title, rows, back, jump)
    PS().settingsPage{ title = title, rows = rows, back = back, jump = jump }
end

-- An address, key or model: the launcher's box (no pen: these need the
-- exact characters), Cancel and Save.
local function input(title, value, hint, done, description)
    require("appspopup").request{ title = title, subtitle = description, text = value or "", hint = hint, typing = true,
        buttons = {
            { icon = "x", text = _("Cancel"), cancel = true },
            { icon = "check", text = _("Save"), primary = true, fn = function(v)
                done(v)
                redraw()
            end },
        } }
end

local function shortKey(key, n)
    return key and key ~= "" and (key:sub(1, n) .. "…") or _("Not set")
end

-- ------------------------------------------------------------------ the AI page

--- A pick of the services a job may use: done(id).
local function pickService(title, job, done)
    local options = {}
    for __, p in ipairs(AI.servicesFor(job)) do
        local label = _(p.name)
        if not AI.ready(p.id) then label = T(_("%1 (not set up)"), label) end
        table.insert(options, { label = label, value = p.id })
    end
    KO.choose(title, options, AI.serviceFor(job), function(id) if id then done(id) end end)
end

--- Settings > AI. `note` (optional): why it opened ("Set your key first"); `jump`: the row to open it at.
function View.show(note, jump)
    local ps = PS()
    if not ps.settingsPage then return end
    local v = ps.appsView and ps.appsView()
    -- (From another app the launcher isn't on top: ‹ goes back to that app.)
    fromApp = not (v and UIManager:getTopmostVisibleWidget() == v)
    View.main(jump)
    if note then KO.message(note) end
end

--- Settings > AI's rows (search reads their names too).
function View.mainRows()
    local rows = {}
    local jobs = AI.jobs()
    if #jobs > 0 then
        table.insert(rows, { heading = _("WHICH AI DOES EACH JOB") })
        for __, j in ipairs(jobs) do
            table.insert(rows, { j.name, AI.jobName(j.key), function()
                pickService(j.name, j.key, function(id)
                    AI.setServiceFor(j.key, id)
                    if not AI.ready(id) then UIManager:nextTick(function() View.service(id) end) else redraw() end
                end)
            end })
        end
    end
    table.insert(rows, { heading = _("AI SERVICES") })
    for __, p in ipairs(AI.PROVIDERS) do
        local name = _(p.name)
        table.insert(rows, { name, AI.ready(p.id) and _("Set up") or _("Not set"), function() View.service(p.id) end })
    end
    if AI.any() and PS().showConnectionTest then
        table.insert(rows, { _("Test connection"), "", function() PS().showConnectionTest("ai") end })
    end
    if #AI.features() > 0 then
        table.insert(rows, { heading = _("WHAT EACH FEATURE SENDS") })
        table.insert(rows, { _("Advanced"), "", function() View.advanced() end })
    end
    return rows
end

function View.main(jump)
    page(_("AI"), View.mainRows, nil, jump)
    -- (Each page opened takes the launcher's "came from another app"; the AI page keeps its own.)
    local v = PS().appsView and PS().appsView()
    if v then v.switcherBack = fromApp or nil end
end

-- ------------------------------------------------------------------ a service's page

local function busy(text)
    local box = KO.wait(text)
    UIManager:forceRePaint()
    return box
end

--- Try a prompt: the sample sent, the reply shown with how long it took and
-- which model answered. Costs a little on paid services, so only ever from
-- this button.
function View.try(id)
    if not AI.ready(id) then return KO.message(T(_("Set up %1 first."), AI.name(id))) end
    NetworkMgr:runWhenOnline(function()
        local box = busy(T(_("Asking %1 to read a sample…"), AI.name(id)))
        AI.background(function() return AI.tryNow(id) end, function(r, err)
            box:close()
            r = r or { ok = false, name = AI.name(id), why = tostring(err) }
            if not r.ok then
                return KO.message{ title = T(_("%1 did not answer"), r.name), text = tostring(r.why) }
            end
            KO.message{ title = T(_("%1 answered in %2 s"), r.name, r.secs),
                text = T(_("Model: %1"), tostring(r.model)) .. "\n\n" .. (r.text ~= "" and r.text or _("(Nothing read.)"))
                    .. "\n\n" .. T(_("The sample: \"%1\"."), AI.SAMPLE_TEXT) }
        end, 240)
    end)
end

--- Test it: a small question, to see that the service answers (and, for your
-- local AI, from where).
function View.test(id)
    NetworkMgr:runWhenOnline(function()
        local name = AI.name(id)
        local box = busy(T(_("Asking %1…"), name))
        AI.background(function()
            local text, via = AI.testNow(id)
            return { text = text, via = via and tostring(via) or nil }
        end, function(r, err)
            box:close()
            if r and r.text then
                if id == "server" then
                    KO.message(T(_("Your local AI answered (%1):\n\n%2"), r.via == "1" and _("Internal URL") or _("External URL"), r.text))
                else
                    KO.message(T(_("%1 answered:\n\n%2"), name, r.text))
                end
            else
                KO.message(T(_("%1 did not answer:\n%2"), name, tostring(r and r.via or err)))
            end
        end, 240)
    end)
end

-- Your local AI's models, to pick one (or type one).
local function pickServerModel()
    NetworkMgr:runWhenOnline(function()
        local box = busy(_("Asking your local AI for its models…"))
        AI.background(function()
            local c = AI.serverConfig()
            local names = {}
            local json = require("json")
            for i = 1, 2 do
                local url = c.urls[i]
                if #names == 0 and url and url ~= "" and (i == 2 or AI.homeReachable(url)) then
                    local base = url:gsub("/+$", ""):gsub("/v1$", "")
                    local headers = {}
                    if c.keys[i] and c.keys[i] ~= "" then headers["Authorization"] = "Bearer " .. c.keys[i] end
                    local status, body = AI.request("GET", base .. "/v1/models", headers, nil, { 5, 10 })
                    local ok, data = pcall(json.decode, body or "")
                    if status == 200 and ok and type(data) == "table" then
                        for __, m in ipairs(data.data or {}) do table.insert(names, m.id) end
                    end
                end
            end
            return names
        end, function(names)
            box:close()
            names = names or {}
            local current = AI.get("server_model") or "gemma4"
            local items = {}
            for __, n in ipairs(names) do
                table.insert(items, { text = n, checked = n == current, fn = function()
                    AI.set("server_model", n)
                    redraw()
                end })
            end
            table.insert(items, { text = _("Type a name…"), fn = function()
                input(_("Model name"), current, "gemma4", function(v)
                    if v ~= "" then AI.set("server_model", v) end
                end)
            end })
            KO.list(#names > 0 and _("Pick a model (one that reads pictures)") or _("Could not list your local AI's models."), items)
        end, 60)
    end)
end

local function back() View.main() end

-- ------------------------------------------------------------------ what's left

--- A time as the clock shows it (24-hour, or 12 with AM/PM).
local function clock(t) return (os.date(KO.twentyFour() and "%H:%M" or "%I:%M %p", t):gsub("^0(%d)", "%1")) end

--- "in 3 min", "at 5:40 PM": when a limit resets.
local function whenReset(t)
    if not t then return nil end
    local left = t - os.time()
    if left <= 0 then return _("reset since") end
    if left < 3600 then return T(_("resets in %1 min"), math.max(1, math.floor(left / 60 + 0.5))) end
    return T(_("resets at %1"), clock(t))
end

--- Claude's and Groq's limits, as they said with their last answer: a row's value, and the lines.
local function limitsText(id)
    local l = AI.limits(id)
    if not l then return nil end
    local names = { requests = _("Requests"), tokens = _("Tokens"), input = _("Input tokens"), output = _("Output tokens") }
    local lines = {}
    for __, part in ipairs({ "requests", "tokens", "input", "output" }) do
        local x = l[part]
        if x and x.remaining then
            local line = x.limit and T(_("%1: %2 of %3 left"), names[part], x.remaining, x.limit) or T(_("%1: %2 left"), names[part], x.remaining)
            local r = whenReset(x.reset)
            table.insert(lines, r and T(_("%1, %2"), line, r) or line)
        end
    end
    if #lines == 0 then return nil end
    return T(_("As of %1"), clock(l.at)), table.concat(lines, "\n")
end

--- The Usage row for Claude and Groq (the limits their last answer gave), and OpenRouter (asked now).
local function usageRow(id)
    if id == "openrouter" then
        return { _("Usage"), _("Check"), function()
            NetworkMgr:runWhenOnline(function()
                local box = busy(_("Asking OpenRouter…"))
                AI.background(function() return { AI.openRouterUsage() } end, function(r, err)
                    box:close()
                    local u = r and r[1]
                    if not u then return KO.message(T(_("Couldn't get OpenRouter's usage: %1"), tostring(r and r[2] or err))) end
                    local function usd(n) return n and string.format("$%.2f", n) or "?" end
                    local lines = {}
                    if u.daily then table.insert(lines, T(_("Used today: %1"), usd(u.daily))) end
                    if u.monthly then table.insert(lines, T(_("Used this month: %1"), usd(u.monthly))) end
                    if u.limit then
                        local resets = { daily = _("resets daily"), weekly = _("resets weekly"), monthly = _("resets monthly") }
                        table.insert(lines, T(_("This key's limit: %1 left of %2"), usd(u.remaining), usd(u.limit))
                            .. (u.reset and resets[u.reset] and (", " .. resets[u.reset]) or ""))
                    end
                    if u.credits and u.spent then table.insert(lines, T(_("Credit left: %1"), usd(u.credits - u.spent))) end
                    if u.free then table.insert(lines, _("Free tier: free models have a daily request limit.")) end
                    KO.message(table.concat(lines, "\n"))
                end, 40)
            end)
        end }
    end
    local value, lines = limitsText(id)
    return { _("Usage"), value or _("After the next answer"), function()
        KO.message(lines or T(_("%1 says what's left with each answer. Use Test it or Try a prompt, or any AI feature, then look again."), AI.name(id)))
    end }
end
View.usageRow = usageRow

--- A service's models to pick from: asked from the service now (with your key), the ones
-- known to read pictures first (`recommended`, then any the service says read pictures),
-- then the rest; Type a model… for any other. Without an answer, the recommended ones.
-- `names`: friendlier names ({ [id] = name }); set(id) saves the pick.
local function pickModel(id, current, recommended, names, set, extra)
    local function show(list, why)
        local items, seen = {}, {}
        -- (A first choice of the caller's: "The service's: …" in AI for this.)
        if extra then table.insert(items, extra) end
        local function add(mid, label, note)
            if seen[mid] then return end
            seen[mid] = true
            label = label or (names and names[mid]) or mid
            table.insert(items, { text = note and T(_("%1 · %2"), label, note) or label, checked = mid == current, fn = function()
                set(mid)
                redraw()
            end })
        end
        local nameOf = {}
        for __, m in ipairs(list or {}) do nameOf[m.id] = m.name end
        for __, m in ipairs(recommended or {}) do add(m, nameOf[m] or (names and names[m]), _("recommended")) end
        local pictures, others = {}, {}
        for __, m in ipairs(list or {}) do
            if m.images == true then table.insert(pictures, m) elseif m.images ~= false then table.insert(others, m) end
        end
        -- Newest first (when the service says), else by name; at most 40 (the rest: Type a model…).
        local function order(a, b)
            if a.created and b.created and a.created ~= b.created then return a.created > b.created end
            return (a.name or a.id):lower() < (b.name or b.id):lower()
        end
        table.sort(pictures, order)
        table.sort(others, order)
        local room = 40
        for __, m in ipairs(pictures) do if room > 0 then add(m.id, m.name) room = room - 1 end end
        -- (Not known to read pictures: handwriting may not work with these.)
        for __, m in ipairs(others) do if room > 0 then add(m.id, m.name, id ~= "server" and _("may not read pictures") or nil) room = room - 1 end end
        if current and current ~= "" then add(current) end
        table.insert(items, { text = _("Type a model…"), fn = function()
            input(_("Model name"), current, recommended and recommended[1] or "", function(v) set(v ~= "" and v or nil) end)
        end })
        local title = list and _("Pick a model that reads pictures") or T(_("Pick a model that reads pictures (couldn't load the list: %1)"), tostring(why or "?"))
        KO.list(title, items)
    end
    NetworkMgr:runWhenOnline(function()
        local box = busy(_("Loading models…"))
        AI.background(function() return { AI.listModels(id) } end, function(r, err)
            box:close()
            if r and r[1] then show(r[1]) else show(nil, r and r[2] or err) end
        end, 30)
    end)
end
View.pickModel = pickModel

-- Your local AI: its Internal URL (on the home network, used when the Kindle
-- can reach it) and/or its External URL (reachable from anywhere, with an
-- optional API key), both speaking the OpenAI API. (Saved as server_home,
-- server_pangolin and server_key, the names they had in Notes.)
local function serverRows()
    local home, external = AI.get("server_home"), AI.get("server_pangolin")
    local key = AI.secrets():readSetting("server_key")
    return {
        { heading = _("ADDRESSES") },
        { _("Internal URL"), (home and home ~= "") and home or _("Not set"), function()
            input(_("Internal URL (your AI on the home network)"), home, "http://192.168.1.50:11434", function(v)
                AI.set("server_home", v)
                AI.forgetHome()
            end)
        end },
        { _("External URL"), (external and external ~= "") and external or _("Not set"), function()
            input(_("External URL (reachable from anywhere)"), external, "https://ai.example.com/v1", function(v)
                AI.set("server_pangolin", v)
            end)
        end },
        { _("API key (optional)"), shortKey(key, 8), function()
            input(_("API key (optional)"), key, "", function(v) AI.setSecret("server_key", v) end,
                _("Sent as a Bearer token with the External URL."))
        end },
        { heading = _("MODEL") },
        { _("Model"), AI.get("server_model") or "gemma4", function() pickServerModel() end },
        { _("Thinking (slower, sometimes better)"), AI.get("server_think") == true, function()
            AI.set("server_think", not AI.get("server_think"))
        end },
        { heading = _("CHECK") },
        { _("Test it"), "", function() View.test("server") end },
        { _("Try a prompt"), "", function() View.try("server") end },
    }
end

local function claudeRows()
    local key = AI.secrets():readSetting("anthropic_key")
    local model = AI.get("claude_model") or AI.Client.DEFAULT_MODEL
    return {
        { heading = _("KEY") },
        { _("Claude API key"), shortKey(key, 10), function()
            input(_("Claude API key"), key, "sk-ant-…", function(v)
                v = v:gsub("%s", "")
                if v ~= "" then AI.setSecret("anthropic_key", v) end
            end, _("From platform.claude.com. Max and Team plans include monthly API credits: claude.ai > Settings > Billing."))
        end },
        key and key ~= "" and { _("Remove the key"), "", function()
            KO.confirm{ text = _("Remove the API key from the Kindle?"), danger = true, ok = _("Remove"), onOk = function()
                AI.setSecret("anthropic_key", nil)
                redraw()
            end }
        end } or false,
        { heading = _("MODEL") },
        { _("Claude model"), AI.Client.MODEL_NAMES[model] or model, function()
            pickModel("claude", model, AI.Client.MODELS, AI.Client.MODEL_NAMES, function(v) AI.set("claude_model", v) end)
        end },
        { heading = _("CHECK") },
        { _("Try a prompt"), "", function() View.try("claude") end },
        key and key ~= "" and usageRow("claude") or false,
    }
end

-- Gemini, OpenRouter, Groq and Custom: address (Custom), key, model.
local function providerRows(id)
    local p = AI.PROVIDER[id] or AI.PROVIDER.custom
    local key = AI.secrets():readSetting(id .. "_key")
    local model = AI.get(id .. "_model") or p.model
    local rows = {}
    if id == "custom" then
        local url = AI.get("custom_url")
        table.insert(rows, { heading = _("ADDRESS") })
        table.insert(rows, { _("Address"), (url and url ~= "") and url or _("Not set"), function()
            input(_("Address (OpenAI-compatible)"), url, "https://ai.example.com/v1", function(v)
                AI.set("custom_url", v ~= "" and v or nil)
            end)
        end })
    end
    table.insert(rows, { heading = _("KEY") })
    -- (Custom: only the address is needed; some services want a key too.)
    local keyLabel = id == "custom" and _("API key (optional)") or T(_("%1 API key"), _(p.name))
    table.insert(rows, { keyLabel, shortKey(key, 8), function()
        local title = p.keyFrom and T(_("%1 API key (from %2)"), _(p.name), p.keyFrom) or keyLabel
        input(title, key, "", function(v) AI.setSecret(id .. "_key", v) end)
    end })
    table.insert(rows, { heading = _("MODEL") })
    table.insert(rows, { _("Model"), (model and model ~= "") and model or _("Not set"), function()
        pickModel(id, model, p.models, nil, function(v) AI.set(id .. "_model", v) end)
    end })
    table.insert(rows, { heading = _("CHECK") })
    table.insert(rows, { _("Test it"), "", function() View.test(id) end })
    -- One real request (the sample handwriting): costs a little on paid services.
    table.insert(rows, { _("Try a prompt"), "", function() View.try(id) end })
    -- What's left (only the services that say).
    if (id == "openrouter" or id == "groq") and key and key ~= "" then table.insert(rows, usageRow(id)) end
    return rows
end

--- One service's page.
function View.service(id)
    local p = AI.PROVIDER[id]
    if not p then return end
    page(id == "server" and _("Local AI") or _(p.name), function()
        if id == "server" then return serverRows() end
        if id == "claude" then return claudeRows() end
        return providerRows(id)
    end, back)
end

-- ------------------------------------------------------------------ Advanced

--- Preview what's sent: the exact instructions, and the picture(s).
function View.preview(key)
    local f = AI.feature(key)
    local pv = f and AI.preview(key)
    if not pv then return end
    local Device = require("device")
    local Screen = Device.screen
    local pngs = pv.pngs
    local function showPictures()
        local dir = require("datastorage"):getDataDir() .. "/cache"
        require("util").makePath(dir)
        local files = {}
        for n, png in ipairs(pngs) do
            local path = dir .. "/ai-preview-" .. n .. ".png"
            local out = io.open(path, "wb")
            if out then out:write(png) out:close() table.insert(files, path) end
        end
        if #files > 0 then
            UIManager:show(require("ui/widget/imageviewer"):new{ file = files[1], fullscreen = true, with_title_bar = false })
        end
    end
    -- The shared box: the text in pages, Pictures (when there are some) and Done.
    local buttons = {}
    if pngs then table.insert(buttons, { icon = "image", text = _("Pictures"), keep = true, fn = showPictures }) end
    table.insert(buttons, { icon = "check", text = _("Done"), primary = true })
    require("appspopup").read{ title = T(_("What %1 sends"), f.name), subtitle = pv.note,
        text = pv.text, buttons = buttons }
end

local function editWords(f)
    -- The shared box: the wording (several lines, or the pen), Cancel, Reset and Save.
    local hw = PS().handwriting
    local okPen, pen = pcall(function() return hw and hw.available() end)
    require("appspopup").request{
        title = T(_("Instructions for %1"), f.name),
        subtitle = _("How it should do it; the answer's form is added after it."),
        text = AI.words(f.key), lines = 6, typing = true,
        pen = (okPen and pen) and true or nil, penTitle = _("Write the instructions"),
        buttons = {
            { icon = "x", text = _("Cancel"), cancel = true },
            { icon = "rotate-ccw", text = _("Reset"), fn = function()
                AI.setWords(f.key, nil)
                redraw()
            end },
            { icon = "check", text = _("Save"), primary = true, fn = function(__, box)
                AI.setWords(f.key, box:getText())
                redraw()
            end },
        },
    }
end

--- Advanced: for each feature, its instructions (yours or the default), how
-- much is sent, and a preview.
function View.advanced()
    page(_("Advanced"), function()
        local rows = {}
        for __, f in ipairs(AI.features()) do
            table.insert(rows, { heading = tostring(f.name):upper() })
            table.insert(rows, { _("Instructions"), AI.edited(f.key) and _("Edited") or _("Default"), function() editWords(f) end })
            if f.amounts then
                local now = AI.amount(f.key)
                local label
                for __, a in ipairs(f.amounts) do if a[1] == now then label = a[2] end end
                table.insert(rows, { _("How much is sent"), label, pick = function()
                    local opts = {}
                    for __, a in ipairs(f.amounts) do table.insert(opts, { a[2], a[1] }) end
                    return opts, now, function(v) AI.setAmount(f.key, v) end
                end })
            end
            table.insert(rows, { _("Preview what's sent"), "", function() View.preview(f.key) end })
        end
        return rows
    end, back)
end

return View
