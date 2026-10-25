--[[--
AI for every app: the AI services (Claude, Gemini, OpenRouter, Groq, your
local AI on its Internal or External URL, Custom), which one does each job, and what
each AI feature sends (its instructions, how much, a preview). Notes,
Crosswords and SSH use it through PluginShare (PS.ai, set up in main.lua),
so it works whichever of them is installed. The Kindle's screens are
appsaiview.lua; the web page's AI tab (webai.lua) calls this too.

What the apps register (main.lua keeps the lists, so registering loads
nothing):
- PS.ai.registerJob{ key, name, app, order, only = { service ids }, default }:
  a line of "Which AI does each job" (setting "ai_<key>"). `only`: the
  services it may use (SSH: { "server" } for your local AI only).
- PS.ai.registerFeature{ key, name, app, job, intro, words, format, amounts,
  request, args, preview, without }: an entry of Advanced. Its instructions
  are intro (fixed; string.format'ed with the call's values), words (the
  default wording, which you can change) and format (fixed: the form of the
  answer the app reads). `amounts`: { { value, label } }, how much is sent,
  the first the default. `request` = false: nothing follows the
  instructions (Preview adds "[your request]" otherwise). `args`: the intro's
  values for Preview. `preview()` -> { pngs, where } or nil: the pictures it
  would send now; `without`: what Preview says when there are none.

Settings: G_reader_settings "apps_ai"; keys in koreader/settings/ai_secrets.lua.
Both moved here once from Notes (its settings and notes_secrets.lua).
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Client = require("appsaiclient")

local AI = {}
AI.Client = Client
AI.PROVIDERS = Client.PROVIDERS
AI.PROVIDER = Client.PROVIDER

local DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*/)") or "./"

-- ------------------------------------------------------------------ settings

-- Notes' AI settings and keys, moved here once.
local MOVED = { "ai_read", "ai_ask", "ai_draw", "claude_model", "server_home", "server_pangolin", "server_model",
    "server_think", "gemini_model", "openrouter_model", "groq_model", "custom_model", "custom_url", "ai_words", "ai_amount" }
local SECRETS = { "anthropic_key", "server_key", "gemini_key", "openrouter_key", "groq_key", "custom_key" }

local secretsFile

--- The keys (apart from KOReader's settings).
function AI.secrets()
    if not secretsFile then
        secretsFile = LuaSettings:open(DataStorage:getSettingsDir() .. "/ai_secrets.lua")
    end
    return secretsFile
end

local function migrate(t)
    -- (Through Notes' own settings when it's there: its defaults count too.)
    local okN, NS = pcall(require, "notessettings")
    local notes = G_reader_settings:readSetting("notes")
    for __, k in ipairs(MOVED) do
        local v
        if okN and type(NS) == "table" and NS.get then v = NS.get(k) elseif type(notes) == "table" then v = notes[k] end
        if t[k] == nil and v ~= nil then t[k] = v end
        if type(notes) == "table" then notes[k] = nil end
    end
    if type(notes) == "table" then G_reader_settings:saveSetting("notes", notes) end
    local path = DataStorage:getSettingsDir() .. "/notes_secrets.lua"
    if require("libs/libkoreader-lfs").attributes(path, "mode") == "file" then
        local old, new = LuaSettings:open(path), AI.secrets()
        local moved = false
        for __, k in ipairs(SECRETS) do
            local v = old:readSetting(k)
            if v ~= nil then
                if new:readSetting(k) == nil then new:saveSetting(k, v) end
                old:delSetting(k)
                moved = true
            end
        end
        if moved then
            new:flush()
            old:flush()
        end
    end
end

local function all()
    local t = G_reader_settings:readSetting("apps_ai")
    if type(t) ~= "table" then t = {} end
    if not t.moved_from_notes then
        local ok, err = pcall(migrate, t)
        if ok then t.moved_from_notes = true else logger.warn("AI: could not move Notes' AI settings:", err) end
        G_reader_settings:saveSetting("apps_ai", t)
    end
    return t
end

function AI.get(key) return all()[key] end

function AI.set(key, value)
    local t = all()
    t[key] = value
    G_reader_settings:saveSetting("apps_ai", t)
end

--- A key (nil or "" removes it).
function AI.setSecret(key, value)
    local s = AI.secrets()
    if value == nil or value == "" then s:delSetting(key) else s:saveSetting(key, value) end
    s:flush()
end

-- ------------------------------------------------------------------ the services

--- KOReader's network: (status number or error string, body).
function AI.request(method, url, headers, body, timeouts)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    local request = { url = url, method = method, headers = headers or {}, sink = ltn12.sink.table(sink) }
    if body then
        request.source = ltn12.source.string(body)
        request.headers["Content-Length"] = tostring(#body)
    end
    if timeouts then
        socketutil:set_timeout(timeouts[1], timeouts[2])
    else
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    local code, rheaders = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if type(code) ~= "number" then logger.warn("AI:", method, (url:gsub("%?.*", "")), code) end
    if type(rheaders) == "table" then AI.noteLimits(url, rheaders) end
    return code, table.concat(sink), rheaders
end

-- ------------------------------------------------------------------ limits left

-- What Claude and Groq say is left with each answer (their rate-limit headers): kept per
-- service in AI.lastLimits (in the child process the request ran in), handed back by
-- AI.background and saved as "limits" { [id] = { at, requests = { limit, remaining, reset },
-- tokens = { ... } } }. reset: when it resets (a time), or nil.
AI.lastLimits = {}
local LIMIT_HEADERS = {
    claude = { host = "api%.anthropic%.com", prefix = "anthropic-ratelimit-",
        parts = { requests = "requests-", tokens = "tokens-", input = "input-tokens-", output = "output-tokens-" } },
    groq = { host = "api%.groq%.com", prefix = "x-ratelimit-", parts = { requests = "%s-requests", tokens = "%s-tokens" } },
}

--- When a reset header's value is: an RFC 3339 time (Claude) or a duration such as "2m59.56s" (Groq).
local function resetAt(v, now)
    if type(v) ~= "string" then return nil end
    local y, mo, d, h, mi, s = v:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if y then
        -- (A UTC time: counted from 1970 directly, so summer time can't shift it.)
        y, mo = tonumber(y), tonumber(mo)
        if mo <= 2 then y = y - 1 end
        local era = math.floor(y / 400)
        local yoe = y - era * 400
        local doy = math.floor((153 * ((mo + 9) % 12) + 2) / 5) + tonumber(d) - 1
        local days = era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
        return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
    end
    local secs = 0
    for n, unit in v:gmatch("([%d%.]+)([hms])") do
        secs = secs + tonumber(n) * (unit == "h" and 3600 or unit == "m" and 60 or 1)
    end
    return secs > 0 and math.floor(now + secs + 0.5) or nil
end

function AI.noteLimits(url, headers)
    for id, spec in pairs(LIMIT_HEADERS) do
        if url:find(spec.host) then
            local now = os.time()
            local got = { at = now }
            local any = false
            for part, pattern in pairs(spec.parts) do
                local function h(kind)
                    local name = pattern:find("%%s") and spec.prefix .. pattern:format(kind) or spec.prefix .. pattern .. kind
                    return headers[name]
                end
                local limit, remaining = tonumber(h("limit")), tonumber(h("remaining"))
                if limit or remaining then
                    got[part] = { limit = limit, remaining = remaining, reset = resetAt(h("reset"), now) }
                    any = true
                end
            end
            if any then AI.lastLimits[id] = got end
        end
    end
end

--- The limits last seen for a service (Claude, Groq): the saved table, or nil.
function AI.limits(id) return (AI.get("limits") or {})[id] end

--- OpenRouter's own account of your key: what's used (today, this month) and what's left.
-- { usage, daily, monthly, limit, remaining, reset, free, credits, spent } or nil and why. Blocking.
function AI.openRouterUsage()
    local key = AI.secrets():readSetting("openrouter_key")
    if not key or key == "" then return nil, "No key" end
    local json = require("json")
    local headers = { Authorization = "Bearer " .. key }
    local status, body = AI.request("GET", "https://openrouter.ai/api/v1/key", headers, nil, { 5, 15 })
    local ok, data = pcall(json.decode, body or "")
    if status ~= 200 or not ok or type(data) ~= "table" or type(data.data) ~= "table" then
        return nil, type(status) == "number" and ("HTTP " .. status) or tostring(status)
    end
    local d = data.data
    local out = { usage = tonumber(d.usage), daily = tonumber(d.usage_daily), monthly = tonumber(d.usage_monthly),
        limit = tonumber(d.limit), remaining = tonumber(d.limit_remaining), reset = d.limit_reset ~= json.null and d.limit_reset or nil,
        free = d.is_free_tier == true }
    -- The account's credit (bought minus spent), when the key may see it.
    local s2, b2 = AI.request("GET", "https://openrouter.ai/api/v1/credits", headers, nil, { 5, 15 })
    local ok2, c = pcall(json.decode, b2 or "")
    if s2 == 200 and ok2 and type(c) == "table" and type(c.data) == "table" then
        out.credits, out.spent = tonumber(c.data.total_credits), tonumber(c.data.total_usage)
    end
    return out
end

--- A service's name as shown ("Claude", "Gemini", "Local AI"…).
function AI.name(id)
    local p = Client.PROVIDER[id]
    return p and _(p.name) or _("Claude")
end

function AI.serverConfig()
    return {
        urls = { AI.get("server_home"), AI.get("server_pangolin") },
        keys = { nil, AI.secrets():readSetting("server_key") },
        model = AI.get("server_model") or "gemma4",
        think = AI.get("server_think") or nil,
    }
end

local homeCheck

--- Whether the home address answers (asked quickly, remembered a few
-- minutes), so away from home the External URL is used without a long wait.
function AI.homeReachable(url)
    local now = os.time()
    local c = homeCheck
    if c and c.url == url and now - c.at < 300 then return c.ok end
    local base = tostring(url):gsub("/+$", ""):gsub("/v1$", "")
    local status = AI.request("GET", base .. "/api/tags", nil, nil, { 3, 5 })
    if type(status) ~= "number" then
        status = AI.request("GET", base .. "/v1/models", nil, nil, { 3, 5 })
    end
    local ok = type(status) == "number"
    homeCheck = { url = url, at = now, ok = ok }
    return ok
end

--- The home address asked again next time (it changed, or a test).
function AI.forgetHome() homeCheck = nil end

--- What the OpenAI-style client needs for a service other than Claude
-- (appsaiclient's `server`): its address(es), key, model, name.
function AI.config(id)
    if id == "server" then
        local c = AI.serverConfig()
        c.reachable = function(url, i) return i ~= 1 or AI.homeReachable(url) end
        return c
    end
    local p = Client.PROVIDER[id] or Client.PROVIDER.custom
    return {
        name = _(p.name),
        urls = { p.url or AI.get("custom_url") },
        keys = { AI.secrets():readSetting(id .. "_key") },
        model = AI.get(id .. "_model") or p.model,
        think = true,   -- (no reasoning_effort: not every service's models take it)
        maxTokens = p.maxTokens,
    }
end

--- Whether a service can be used: Claude and the presets need a key, your
-- local AI and Custom an address.
function AI.ready(id)
    if id == "server" then
        local c = AI.serverConfig()
        return (c.urls[1] or "") ~= "" or (c.urls[2] or "") ~= ""
    end
    if id == "custom" then return (AI.get("custom_url") or "") ~= "" end
    local key = AI.secrets():readSetting(id == "claude" and "anthropic_key" or (id .. "_key"))
    return key ~= nil and key ~= ""
end

--- Whether any service is set up (without one, the apps leave out their AI).
function AI.any()
    for __, p in ipairs(Client.PROVIDERS) do
        if AI.ready(p.id) then return true end
    end
    return false
end

--- A client for a service (an id of AI.PROVIDERS), with :transcribe(png,
-- instructions, more pictures). An answer can take a while (a local AI
-- loading its model first, a long reply): long timeouts for every request.
function AI.clientOf(id)
    return Client.new{
        key = AI.secrets():readSetting("anthropic_key"),
        model = AI.get("claude_model") or Client.DEFAULT_MODEL,
        request = function(method, url, headers, body, timeouts)
            return AI.request(method, url, headers, body, timeouts or (method == "POST" and { 45, 180 } or nil))
        end,
        json = require("json"),
        b64 = function(bytes) return (require("mime").b64(bytes)) end,
        server = id ~= "claude" and AI.config(id) or nil,
    }
end

-- ------------------------------------------------------------------ jobs

local function PS() return require("pluginshare") end

--- The jobs the apps registered, in order.
function AI.jobs()
    local out = {}
    for __, j in pairs(PS().aiJobs or {}) do table.insert(out, j) end
    table.sort(out, function(a, b)
        if (a.order or 50) ~= (b.order or 50) then return (a.order or 50) < (b.order or 50) end
        return tostring(a.name) < tostring(b.name)
    end)
    return out
end

function AI.job(key) return (PS().aiJobs or {})[key] end

local function allowed(job, id)
    if not (job and job.only) then return Client.PROVIDER[id] ~= nil end
    for __, o in ipairs(job.only) do
        if o == id then return true end
    end
    return false
end

--- The services a job may use (every one, or its `only`).
function AI.servicesFor(key)
    local job = AI.job(key)
    local out = {}
    for __, p in ipairs(Client.PROVIDERS) do
        if allowed(job, p.id) then table.insert(out, p) end
    end
    return out
end

--- Which service does a job ("claude" when none was picked). (Notes saved
-- "claude" or "server" before there were more: those still mean the same.)
function AI.serviceFor(key)
    local job = AI.job(key)
    local saved = AI.get("ai_" .. key)
    if saved and allowed(job, saved) then return saved end
    return job and (job.default or (job.only and job.only[1])) or "claude"
end

function AI.setServiceFor(key, id) AI.set("ai_" .. key, id) end

--- The name of the service a job uses.
function AI.jobName(key) return AI.name(AI.serviceFor(key)) end

--- Whether the service a job uses is set up.
function AI.readyFor(key) return AI.ready(AI.serviceFor(key)) end

--- Who does these jobs (every job when none given): one service's name, or "Mixed".
function AI.allName(keys)
    if not keys then
        keys = {}
        for __, j in ipairs(AI.jobs()) do table.insert(keys, j.key) end
    end
    local first = keys[1] and AI.serviceFor(keys[1]) or "claude"
    for __, k in ipairs(keys) do
        if AI.serviceFor(k) ~= first then return _("Mixed") end
    end
    return AI.name(first)
end

--- Why a job can't run yet.
function AI.notReadyText(key)
    local id = AI.serviceFor(key)
    if id == "server" then return _("Set your local AI's address first (Settings > AI > Local AI).") end
    if id == "custom" then return _("Set the Custom service's address first (Settings > AI > Custom).") end
    return T(_("Set your %1 API key first (Settings > AI), or pick another AI for this job."), AI.name(id))
end

--- A client for the service a job uses.
function AI.client(key)
    local id = AI.serviceFor(key)
    local client = AI.clientOf(id)
    -- A model of its own for this job (on this service): AI for this > Model.
    local m = AI.modelFor(key, id)
    if m then
        if client.server then client.server.model = m else client.model = m end
    end
    return client
end

--- A job's own model on a service (nil: the service's): saved as "model_<job>" { service, model }.
function AI.modelFor(key, id)
    local o = AI.get("model_" .. key)
    return type(o) == "table" and o.service == (id or AI.serviceFor(key)) and o.model or nil
end

function AI.setModelFor(key, id, model)
    AI.set("model_" .. key, model and { service = id, model = model } or nil)
end

--- The job a feature or job key means (features name their job).
function AI.jobOf(key)
    if AI.job(key) then return key end
    local f = AI.feature(key)
    return f and f.job or key
end

--- "AI for this": which service does this job and with which model, a tap each, from
-- wherever the AI is used (a hold on an AI button: Popup's buttons with aiJob, or an app's
-- own). `key`: a job or feature key. done() after a change.
function AI.quickPick(key, done)
    local job = AI.jobOf(key)
    local j = AI.job(job)
    local KO = require("appsko")
    local UIManager = require("ui/uimanager")
    local menu
    menu = function()
        local id = AI.serviceFor(job)
        local own = AI.modelFor(job, id)
        local cfgModel = id == "claude" and (AI.get("claude_model") or Client.DEFAULT_MODEL)
            or id == "server" and (AI.get("server_model") or "gemma4") or AI.config(id).model
        local names = Client.MODEL_NAMES or {}
        local items = {
            { text = T(_("Service: %1"), AI.name(id)), fn = function()
                local options = {}
                for __, p in ipairs(AI.servicesFor(job)) do
                    local label = _(p.name)
                    if not AI.ready(p.id) then label = T(_("%1 (not set up)"), label) end
                    table.insert(options, { label = label, value = p.id })
                end
                KO.choose(_("Service"), options, id, function(v)
                    if v then AI.setServiceFor(job, v) if done then done() end end
                    UIManager:nextTick(menu)
                end, menu)
            end },
            { text = T(_("Model: %1"), own and (names[own] or own) or T(_("%1 (the service's)"), names[cfgModel] or tostring(cfgModel))), fn = function()
                require("appsaiview").pickModel(id, own or cfgModel, id == "claude" and Client.MODELS or (Client.PROVIDER[id] or {}).models,
                    id == "claude" and names or nil, function(m)
                        AI.setModelFor(job, id, m ~= cfgModel and m or nil)
                        if done then done() end
                        UIManager:nextTick(menu)
                    end, own and { text = T(_("The service's: %1"), names[cfgModel] or tostring(cfgModel)), fn = function()
                        AI.setModelFor(job, id, nil)
                        if done then done() end
                        UIManager:nextTick(menu)
                    end } or nil)
            end },
            { text = _("AI settings…"), fn = function() require("appsaiview").show() end },
        }
        -- What's left (Claude, Groq: as of their last answer; OpenRouter: asked on a tap).
        if (id == "claude" or id == "groq" or id == "openrouter") and AI.ready(id) then
            local row = require("appsaiview").usageRow(id)
            table.insert(items, 3, { text = T(_("Usage: %1"), row[2]), fn = row[3] })
        end
        KO.list(T(_("AI for %1"), j and j.name or job), items)
    end
    menu()
end

-- ------------------------------------------------------------------ features (Advanced)

--- The features the apps registered, in the order they did.
function AI.features() return PS().aiFeatures or {} end

function AI.feature(key)
    for __, f in ipairs(AI.features()) do
        if f.key == key then return f end
    end
end

--- A feature's wording: yours, or its default.
function AI.words(key)
    local saved = (AI.get("ai_words") or {})[key]
    if type(saved) == "string" and saved:match("%S") then return saved end
    local f = AI.feature(key)
    return f and f.words or ""
end

--- Whether you changed a feature's wording.
function AI.edited(key)
    local saved = (AI.get("ai_words") or {})[key]
    return type(saved) == "string" and saved:match("%S") ~= nil
end

--- Your wording for a feature (nil, "" or the default: back to the default).
function AI.setWords(key, text)
    local all_ = AI.get("ai_words") or {}
    local f = AI.feature(key)
    local mine = type(text) == "string" and text:match("%S") and not (f and text == f.words)
    all_[key] = mine and text or nil
    AI.set("ai_words", all_)
end

--- How much a feature sends: one of its amounts' values.
function AI.amount(key)
    local f = AI.feature(key)
    local saved = (AI.get("ai_amount") or {})[key]
    for __, a in ipairs(f and f.amounts or {}) do
        if a[1] == saved then return saved end
    end
    return f and f.amounts and f.amounts[1][1] or "page"
end

function AI.setAmount(key, value)
    local all_ = AI.get("ai_amount") or {}
    all_[key] = value
    AI.set("ai_amount", all_)
end

--- A feature's instructions, as sent: its intro, your wording, its format
-- (then the app adds the request). `...`: the intro's values.
function AI.instructions(key, ...)
    local f = AI.feature(key)
    if not f then return nil end
    local intro = f.intro or ""
    if select("#", ...) > 0 then intro = string.format(intro, ...) end
    return intro .. AI.words(key) .. (f.format or "")
end

--- What a feature would send now, for Preview: { text, pngs, where, note }.
function AI.preview(key)
    local f = AI.feature(key)
    if not f then return nil end
    local text = f.args and AI.instructions(key, unpack(f.args)) or AI.instructions(key)
    if f.request ~= false then text = text .. _("[your request]") end
    local pics
    if f.preview then
        local ok, r = pcall(f.preview, key)
        if ok then pics = r else logger.warn("AI: preview of", key, r) end
    end
    local note
    if pics and pics.pngs and #pics.pngs > 0 then
        note = pics.where and T(_("With %1 picture(s), from %2."), #pics.pngs, pics.where) or T(_("With %1 picture(s)."), #pics.pngs)
    else
        pics = nil
        note = f.without
    end
    return { text = text, pngs = pics and pics.pngs or nil, where = pics and pics.where or nil, note = note }
end

-- ------------------------------------------------------------------ asking (in a child process)

--- `job()` run in a child process, so KOReader keeps answering while it
-- waits on the network; its result (plain values) goes to done(result), or
-- done(nil, why) when it failed or took longer than `limit` seconds (300).
function AI.background(job, done, limit)
    local UIManager = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    local pid, fd = ffiutil.runInSubProcess(function(__, write_fd)
        local ok, result = pcall(job)
        -- (With what Claude or Groq said is left, to keep.)
        local okd, out = pcall(require("dump"), ok and { ok = result, limits = AI.lastLimits } or { err = tostring(result), limits = AI.lastLimits })
        ffiutil.writeToFD(write_fd, okd and out or '{ err = "failed" }', true)
    end, true)
    if not pid then return done(nil, tostring(fd)) end
    local deadline = os.time() + (limit or 300)
    local function reap()
        if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end
    end
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(0.3, check) end
            ffiutil.terminateSubProcess(pid)
            reap()
            return done(nil, _("It took too long."))
        end
        local raw = (size and size > 0) and ffiutil.readAllFromFD(fd) or ""
        if not exited then reap() end
        local fn = raw ~= "" and (loadstring or load)("return " .. raw)
        if fn and setfenv then setfenv(fn, {}) end
        local ok, r = pcall(fn or error)
        if ok and type(r) == "table" and type(r.limits) == "table" and next(r.limits) then
            local saved = AI.get("limits") or {}
            for id, l in pairs(r.limits) do saved[id] = l end
            AI.set("limits", saved)
        end
        if ok and type(r) == "table" and r.ok ~= nil then return done(r.ok) end
        done(nil, ok and type(r) == "table" and r.err or _("It stopped without an answer."))
    end
    UIManager:scheduleIn(0.3, check)
end

--- Ask the AI for a feature: its instructions, then content.text, with
-- content.images (PNGs, the first the main one); `content.wait`: a waiting
-- box with this text (closed when the answer comes). done(text) or
-- done(nil, why). Runs in a child process; Wi-Fi is turned on first if needed.
function AI.ask(key, content, done)
    content = content or {}
    local f = AI.feature(key)
    local job = f and f.job or key
    if not AI.readyFor(job) then return done(nil, AI.notReadyText(job)) end
    local prompt = (AI.instructions(key, unpack(content.args or {})) or "") .. (content.text or "")
    local images = content.images or {}
    local more = {}
    for i = 2, #images do more[i - 1] = images[i] end
    require("ui/network/manager"):runWhenOnline(function()
        local box = content.wait and require("appsko").wait(content.wait)
        local client = AI.client(job)
        AI.background(function()
            local text, why = client:transcribe(images[1], prompt, #more > 0 and more or nil)
            return { text = text, why = why and tostring(why) or nil }
        end, function(r, err)
            if box then box:close() end
            if r and r.text then return done(r.text) end
            done(nil, r and r.why or err)
        end, content.limit or 240)
    end)
end

-- ------------------------------------------------------------------ Try a prompt

-- (Read handwriting's instructions when Notes is there.)
local SAMPLE_PROMPT = "This is handwriting. Transcribe it into plain text, keeping the line breaks. "
    .. "Reply with the transcription only, nothing before or after it."
AI.SAMPLE_TEXT = "Buy milk and bread / Call the dentist at 3 / Water the plants"

--- One real, short request to a service: the built-in sample (three
-- handwritten lines). Blocking (run it in a child). Returns { ok, name,
-- text, why, secs, model }.
function AI.tryNow(id)
    local name = AI.name(id)
    local f = io.open(DIR .. "samples/handwriting.png", "rb")
    local png = f and f:read("*a")
    if f then f:close() end
    if not png then return { ok = false, name = name, why = _("The sample picture is missing.") } end
    local client = AI.clientOf(id)
    local socket = require("socket")
    local t0 = socket.gettime()
    local text, why = client:transcribe(png, AI.feature("read") and AI.instructions("read") or SAMPLE_PROMPT)
    local secs = math.floor((socket.gettime() - t0) * 10 + 0.5) / 10
    if not text then return { ok = false, name = name, why = tostring(why), secs = secs } end
    return { ok = true, name = name, text = text, secs = secs,
        model = client.lastModel or (client.server and client.server.model) or client.model }
end

--- A small question to a service ("Reply with just the word OK"), to see
-- that its address, key and model work: text and (your local AI) where it
-- answered (1 at home, 2 via Pangolin), or nil and why. Blocking.
function AI.testNow(id)
    if id == "server" then AI.forgetHome() end
    return AI.clientOf(id):transcribe(nil, "Reply with just the word OK.")
end

-- ------------------------------------------------------------------ Test connection (the launcher's appstest.lua)

--- Each service set up, with cheap calls only (a key checked or the models
-- listed, never a question); your local AI's home and away addresses on
-- their own. In the test's child process.
function AI.tests(Test)
    local out = {}
    -- What an answer means.
    local function check(model)
        return function(status, body)
            if status == 200 then
                if model and model ~= "" and not tostring(body):find(model, 1, true) then
                    return true, T(_("Answers; the model %1 isn't in its list"), model)
                end
                return true, _("Working")
            end
            -- (Gemini answers a wrong key with 400 and API_KEY_INVALID.)
            local text = tostring(body or "")
            if status == 401 or status == 403 or (status == 400 and (text:find("API_KEY", 1, true) or text:find("API key", 1, true))) then
                return false, _("The key was refused")
            end
            if status == 404 then return false, _("Nothing found at this address") end
            if status == 429 then return false, _("Too many requests (a free tier's limit?)") end
            local ok, data = pcall(require("json").decode, text)
            local err = ok and type(data) == "table" and data.error
            local msg = type(err) == "table" and err.message or (type(err) == "string" and err) or nil
            return false, msg and ("HTTP " .. status .. ": " .. tostring(msg)) or ("HTTP " .. status)
        end
    end
    for __, p in ipairs(Client.PROVIDERS) do
        if AI.ready(p.id) then
            local name = _(p.name)
            if p.id == "claude" then
                table.insert(out, Test.http{ name = name, url = "https://api.anthropic.com/v1/models?limit=1",
                    headers = { ["x-api-key"] = AI.secrets():readSetting("anthropic_key"), ["anthropic-version"] = "2023-06-01" },
                    check = check() })
            elseif p.id == "server" then
                local c = AI.serverConfig()
                local home, away = c.urls[1], c.urls[2]
                if home and home ~= "" then
                    table.insert(out, Test.http{ name = _("Local AI: Internal URL"), detail = home,
                        url = (Client.chatUrl(home):gsub("/chat/completions$", "/models")), check = check(c.model) })
                end
                if away and away ~= "" then
                    local key = c.keys[2]
                    table.insert(out, Test.http{ name = _("Local AI: External URL"), detail = away,
                        url = (Client.chatUrl(away):gsub("/chat/completions$", "/models")),
                        headers = key and key ~= "" and { Authorization = "Bearer " .. key } or nil, check = check(c.model) })
                end
            else
                local cfg = AI.config(p.id)
                local key = cfg.keys[1]
                local url = p.id == "openrouter" and "https://openrouter.ai/api/v1/key"
                    or (Client.chatUrl(cfg.urls[1]):gsub("/chat/completions$", "/models"))
                table.insert(out, Test.http{ name = name, detail = p.id == "custom" and cfg.urls[1] or nil, url = url,
                    headers = key and key ~= "" and { Authorization = "Bearer " .. key } or nil,
                    check = check(p.id ~= "openrouter" and cfg.model or nil) })
            end
        end
    end
    return out
end

--- The Kindle's AI settings (appsaiview.lua); `note`: why they opened.
function AI.showSettings(note) require("appsaiview").show(note) end

--- One service's page, or Advanced.
function AI.showService(id) require("appsaiview").service(id) end
function AI.showAdvanced() require("appsaiview").advanced() end

--- Whether any service is set up (PS.ai.configured()).
AI.configured = AI.any

--- The models a service offers now, asked with your key (Claude, Gemini, OpenRouter, Groq,
-- Custom): { { id, name, images = true | false | nil (not known), created (a time, when
-- the service says) } }, or nil and why.
-- Models that can't answer a prompt (embeddings, speech, pictures made) are left out.
-- Blocks: run it in AI.background.
local SKIP = { "embed", "tts", "whisper", "imagen", "veo", "aqa", "guard", "audio", "transcribe", "image%-generation", "live", "moderation" }
function AI.listModels(id)
    local json = require("json")
    local function get(url, headers)
        local status, body = AI.request("GET", url, headers, nil, { 5, 15 })
        if status ~= 200 then return nil, type(status) == "number" and ("HTTP " .. status) or tostring(status) end
        local ok, data = pcall(json.decode, body or "")
        if not ok or type(data) ~= "table" then return nil, "Not a model list" end
        return data
    end
    local out = {}
    local function add(mid, name, images, created)
        if type(mid) ~= "string" or mid == "" then return end
        local low = mid:lower()
        for __, w in ipairs(SKIP) do if low:find(w) then return end end
        if type(name) ~= "string" or name == mid then name = nil end
        table.insert(out, { id = mid, name = name, images = images, created = tonumber(created) })
    end
    if id == "claude" then
        local key = AI.secrets():readSetting("anthropic_key")
        if not key or key == "" then return nil, "No key" end
        local data, why = get("https://api.anthropic.com/v1/models?limit=100",
            { ["x-api-key"] = key, ["anthropic-version"] = "2023-06-01" })
        if not data then return nil, why end
        -- (Every Claude model reads pictures.)
        for __, m in ipairs(data.data or {}) do add(m.id, m.display_name, true, #out) end
        -- (Newest first already: the order is kept.)
        for __, m in ipairs(out) do m.created = -m.created end
        return out
    end
    if id == "server" then
        -- Your local AI: the address that answers (home first), as its own picker does.
        local c = AI.serverConfig()
        for i = 1, 2 do
            local url = c.urls[i]
            if url and url ~= "" and (i == 2 or AI.homeReachable(url)) then
                local h = {}
                if c.keys[i] and c.keys[i] ~= "" then h["Authorization"] = "Bearer " .. c.keys[i] end
                local data = get(url:gsub("/+$", ""):gsub("/v1$", "") .. "/v1/models", h)
                if data then
                    for __, m in ipairs(data.data or {}) do add(m.id) end
                    return out
                end
            end
        end
        return nil, "Your local AI didn't answer"
    end
    local p = AI.PROVIDER[id]
    if not p then return nil, "Unknown service" end
    local base = id == "custom" and AI.get("custom_url") or p.url
    if not base or base == "" then return nil, "No address" end
    local key = AI.secrets():readSetting(id .. "_key")
    local headers = {}
    if key and key ~= "" then headers["Authorization"] = "Bearer " .. key end
    local data, why = get((Client.chatUrl(base):gsub("/chat/completions$", "/models")), headers)
    -- Gemini: Google's own list when its OpenAI-style one doesn't answer (the ones that write text).
    if not data and id == "gemini" and key and key ~= "" then
        local g = get("https://generativelanguage.googleapis.com/v1beta/models?pageSize=200", { ["x-goog-api-key"] = key })
        if g then
            for __, m in ipairs(g.models or {}) do
                local writes = false
                for __, x in ipairs(m.supportedGenerationMethods or {}) do if x == "generateContent" then writes = true end end
                if writes and type(m.name) == "string" then add((m.name:gsub("^models/", "")), m.displayName) end
            end
            return out
        end
    end
    if not data then return nil, why end
    for __, m in ipairs(data.data or data.models or {}) do
        local mid = type(m) == "table" and (m.id or m.name) or m
        if type(mid) == "string" then mid = mid:gsub("^models/", "") end
        -- OpenRouter says what each model takes in.
        local images
        local arch = type(m) == "table" and m.architecture
        if type(arch) == "table" and type(arch.input_modalities) == "table" then
            images = false
            for __, x in ipairs(arch.input_modalities) do if x == "image" then images = true end end
        end
        add(mid, type(m) == "table" and (m.display_name or m.displayName or (m.id and m.name)) or nil, images,
            type(m) == "table" and m.created or nil)
    end
    return out
end

return AI
