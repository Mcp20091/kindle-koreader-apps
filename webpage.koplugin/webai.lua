--[[--
AI on the web page (the AI tab): the AI services (key, model, addresses),
which one does each job, Try a prompt, and Advanced (each feature's
instructions, how much is sent, Preview). The work is the launcher's
appsai.lua (the Kindle's Settings > AI uses it too); without the launcher,
the tab says it's needed.
]]

local Common = require("webcommon")

local Web = {}

-- Settings the page may change (appsai's own keys).
local SETTINGS = {
    claude_model = "string", server_home = "string", server_pangolin = "string", server_model = "string",
    server_think = "boolean", gemini_model = "string", openrouter_model = "string", groq_model = "string",
    custom_model = "string", custom_url = "string",
}

local function A() return require("appsai") end

-- Try a prompt's runs: { [key] = { status, result } }.
local tryJobs, tryCount = {}, 0

function Web.state()
    local AI = A()
    local Client = AI.Client
    local secrets = AI.secrets()
    local settings = {}
    for k in pairs(SETTINGS) do settings[k] = AI.get(k) end
    local models = {}
    for __, m in ipairs(Client.MODELS) do table.insert(models, { m, Client.MODEL_NAMES[m] or m }) end
    local providers = {}
    for __, p in ipairs(AI.PROVIDERS) do
        local own = p.id ~= "claude" and p.id ~= "server"
        table.insert(providers, { id = p.id, name = p.name, keyFrom = p.keyFrom, free = p.free or nil, models = p.models,
            model = own and (AI.get(p.id .. "_model") or p.model) or nil,
            keySet = own and secrets:readSetting(p.id .. "_key") ~= nil or nil, ready = AI.ready(p.id) })
    end
    local jobs = {}
    for __, j in ipairs(AI.jobs()) do
        local ids = {}
        for __, p in ipairs(AI.servicesFor(j.key)) do table.insert(ids, p.id) end
        table.insert(jobs, { key = j.key, name = j.name, app = j.app, service = AI.serviceFor(j.key), services = ids })
    end
    return {
        installed = true,
        settings = settings,
        claude = { keySet = secrets:readSetting("anthropic_key") ~= nil, model = AI.get("claude_model") or Client.DEFAULT_MODEL,
            models = models },
        serverKeySet = secrets:readSetting("server_key") ~= nil,
        providers = providers,
        jobs = jobs,
        any = AI.any(),
        sample = AI.SAMPLE_TEXT,
    }
end

local function trim(v) return (tostring(v):match("^%s*(.-)%s*$")) end

function Web.routes(server)
    -- Without the launcher: every AI route says so.
    if not pcall(require, "appsai") then
        server:route("GET", "^/api/ai", function(req, res) res:json({ installed = false }) end)
        return
    end

    server:route("GET", "^/api/ai$", function(req, res) res:json(Web.state()) end)

    -- Settings: { key = value } of SETTINGS; jobs = { [job] = service id }.
    server:route("POST", "^/api/ai/settings$", function(req, res)
        local AI = A()
        local b = req.json()
        for k, v in pairs(Common.pick(b, SETTINGS)) do
            if v == "" then v = nil end
            AI.set(k, v)
        end
        if b.server_home ~= nil then AI.forgetHome() end
        if type(b.jobs) == "table" then
            for job, id in pairs(b.jobs) do
                if AI.job(job) and AI.PROVIDER[id] then AI.setServiceFor(job, id) end
            end
        end
        res:json({ ok = true })
    end)

    -- A key: { service, key } (Claude, "server" for the local AI's API key, or
    -- another service), or { service, clear = true }.
    server:route("POST", "^/api/ai/key$", function(req, res)
        local AI = A()
        local b = req.json()
        local id = tostring(b.service or "")
        if not AI.PROVIDER[id] then return res:error(400, "No such AI service") end
        local name = id == "claude" and "anthropic_key" or (id .. "_key")
        if b.clear then
            AI.setSecret(name, nil)
        elseif type(b.key) == "string" and b.key:match("%S") then
            AI.setSecret(name, trim(b.key))
        end
        res:json({ ok = true })
    end)

    -- Try a prompt (a service's card): the sample sent in a child process;
    -- POST starts it ({ provider }) and gives a key, GET ?key= says when done.
    server:route("POST", "^/api/ai/try$", function(req, res)
        local AI = A()
        local id = tostring(req.json().provider or "")
        if not AI.PROVIDER[id] then return res:error(400, "No such AI service") end
        if not AI.ready(id) then return res:error(400, "Set up " .. AI.name(id) .. " first") end
        tryCount = tryCount + 1
        local key = tostring(tryCount)
        tryJobs[key] = { status = "waiting" }
        AI.background(function() return AI.tryNow(id) end, function(r, why)
            tryJobs[key] = { status = "done", result = r or { ok = false, name = AI.name(id), why = tostring(why) } }
        end, 240)
        res:json({ key = key })
    end)

    -- The models a service offers now (asked with its key): { models = { { id, name, images } }, error }.
    -- Newest first where the service says; the ones that don't read pictures left out.
    server:route("GET", "^/api/ai/models$", function(req, res)
        local list, why = A().listModels(tostring(req.query.id or ""))
        local out = {}
        for __, m in ipairs(list or {}) do if m.images ~= false then table.insert(out, m) end end
        table.sort(out, function(a, b)
            if a.created and b.created and a.created ~= b.created then return a.created > b.created end
            return (a.name or a.id):lower() < (b.name or b.id):lower()
        end)
        res:json({ models = out, error = list == nil and tostring(why) or nil })
    end)

    -- What's left: Claude's and Groq's limits from their last answer ({ limits }), or OpenRouter's
    -- usage asked now ({ openrouter }). Other services don't say.
    server:route("GET", "^/api/ai/usage$", function(req, res)
        local id = tostring(req.query.id or "")
        if id == "openrouter" then
            local u, why = A().openRouterUsage()
            return res:json({ openrouter = u, error = u == nil and tostring(why) or nil })
        end
        res:json({ limits = A().limits(id), now = os.time() })
    end)

    server:route("GET", "^/api/ai/try$", function(req, res)
        local job = tryJobs[tostring(req.query.key or "")]
        if not job then return res:error(404, "No such try") end
        res:json(job)
    end)

    -- Advanced: each feature's wording (yours or the default), how much it
    -- sends; POST { key, words | reset, amount }.
    server:route("GET", "^/api/ai/advanced$", function(req, res)
        local AI = A()
        local out = {}
        for __, f in ipairs(AI.features()) do
            table.insert(out, { key = f.key, name = f.name, app = f.app, words = AI.words(f.key), default = f.words,
                edited = AI.edited(f.key), amounts = f.amounts, amount = f.amounts and AI.amount(f.key) or nil })
        end
        res:json({ features = out })
    end)

    server:route("POST", "^/api/ai/advanced$", function(req, res)
        local AI = A()
        local b = req.json()
        local key = tostring(b.key or "")
        if not AI.feature(key) then return res:error(404, "No such feature") end
        if b.reset then AI.setWords(key, nil)
        elseif type(b.words) == "string" then AI.setWords(key, b.words) end
        if type(b.amount) == "string" then AI.setAmount(key, b.amount) end
        res:json({ ok = true })
    end)

    -- Preview what's sent: the exact instructions, and the pictures as data URLs.
    server:route("GET", "^/api/ai/preview$", function(req, res)
        local pv = A().preview(tostring(req.query.key or ""))
        if not pv then return res:error(404, "No such feature") end
        local images = {}
        for __, png in ipairs(pv.pngs or {}) do
            table.insert(images, "data:image/png;base64," .. require("mime").b64(png))
        end
        res:json({ text = pv.text, where = pv.where, note = pv.note, images = images })
    end)
end

return Web
