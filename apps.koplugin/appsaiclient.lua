--[[--
The AI services' requests, for every app (the launcher's AI, appsai.lua):
Claude (Anthropic's Messages API) and the services speaking the OpenAI chat
API (Gemini, OpenRouter, Groq, your local AI on its Internal or External URL, and
Custom). Pictures (PNG) and instructions go up, the answer's text comes back.

Plain Lua: network, JSON and base64 are passed in, so the tests run it
without KOReader.
]]

local Client = {}
Client.__index = Client

local URL = "https://api.anthropic.com/v1/messages"
Client.MODELS = { "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5" }
Client.MODEL_NAMES = { ["claude-opus-5-5"] = "Opus 5.5", ["claude-sonnet-5-5"] = "Sonnet 5.5", ["claude-haiku-5-5"] = "Haiku 5.5" }
Client.DEFAULT_MODEL = "claude-opus-5-5"

--- options: key, model, request(method, url, headers, body) returning
-- (status number or error string, body string), json (encode, decode),
-- b64(bytes).
function Client.new(options)
    local self = setmetatable({}, Client)
    self.key = options.key
    self.model = options.model or Client.DEFAULT_MODEL
    self.request = options.request
    self.json = options.json
    self.b64 = options.b64
    self.server = options.server
    return self
end

--- The request body for a page image (`prompt`: what to do with it).
function Client:body(png, prompt, more)
    local content = {}
    -- (A question about text only, such as SSH's, has no picture.)
    if png then
        table.insert(content, { type = "image", source = { type = "base64", media_type = "image/png", data = self.b64(png) } })
    end
    for _, extra in ipairs(more or {}) do
        table.insert(content, { type = "image", source = { type = "base64", media_type = "image/png", data = self.b64(extra) } })
    end
    table.insert(content, { type = "text", text = prompt or "" })
    local body = {
        model = self.model,
        max_tokens = 16000,
        messages = { { role = "user", content = content } },
    }
    -- If a safety check declines the request, the API runs it again on a
    -- model it picks (Haiku has no fallback).
    if self.model ~= "claude-haiku-5-5" then body.fallbacks = "default" end
    return body
end

local ERRORS = {
    [401] = "The API key was refused: check it in Settings > AI > Claude.",
    [403] = "This API key may not use that model.",
    [429] = "Too many requests. Try again in a minute.",
    [529] = "Claude is busy. Try again in a minute.",
}

--- The text of a page image, or nil and why.
function Client:transcribe(png, prompt, more)
    if self.server then return self:transcribeServer(png, prompt, more) end
    if not self.key or self.key == "" then return nil, "No API key set (Settings > AI > Claude)." end
    local headers = {
        ["x-api-key"] = self.key,
        ["anthropic-version"] = "2023-06-01",
        ["content-type"] = "application/json",
    }
    local body = self:body(png, prompt, more)
    if body.fallbacks then headers["anthropic-beta"] = "server-side-fallback-2026-07-01" end
    local status, reply = self.request("POST", URL, headers, self.json.encode(body))
    if type(status) ~= "number" then return nil, "No connection: " .. tostring(status) end
    local ok, data = pcall(self.json.decode, reply or "")
    if not ok or type(data) ~= "table" then data = nil end
    if status ~= 200 then
        local msg = data and data.error and data.error.message
        if msg and msg:find("credit balance", 1, true) then
            return nil, "No API credit left. Max plans' monthly credits are claimed in claude.ai > Settings > Billing."
        end
        return nil, ERRORS[status] or msg or ("HTTP " .. status)
    end
    if not data then return nil, "Claude's reply could not be read." end
    if data.stop_reason == "refusal" then return nil, "Claude declined this page." end
    local parts = {}
    for __, block in ipairs(data.content or {}) do
        if block.type == "text" and type(block.text) == "string" then table.insert(parts, block.text) end
    end
    local text = table.concat(parts, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    -- (Which model answered: Try a prompt shows it.)
    self.lastModel = type(data.model) == "string" and data.model or self.model
    return text
end


-- ------------------------------------------------------------------ your own server (Ollama, Pangolin)

--- The AI services, all peers in one list: Claude (its own API), the ones
-- speaking the OpenAI chat API (Gemini, OpenRouter, Groq: a preset address,
-- your key and a model), your local AI (Ollama at home, Pangolin away) and
-- Custom (any OpenAI-compatible address). Each keeps its own key and model:
-- secrets "<id>_key", settings "<id>_model" (Claude: anthropic_key and
-- claude_model; Local AI: the server_* ones; Custom also custom_url).
-- `models`: a few that read pictures (checked October 2026); any other can
-- be typed. `free`: where its free tier comes from.
Client.PROVIDERS = {
    { id = "claude", name = "Claude" },
    { id = "gemini", name = "Gemini", url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
        models = { "gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-3.1-pro-preview" }, model = "gemini-3.8-flash",
        maxTokens = 32768, keyFrom = "aistudio.google.com", free = true },
    { id = "openrouter", name = "OpenRouter", url = "https://openrouter.ai/api/v1/chat/completions",
        models = { "openrouter/free", "google/gemini-3.8-flash" }, model = "openrouter/free",
        maxTokens = 16000, keyFrom = "openrouter.ai/keys", free = true },
    { id = "groq", name = "Groq", url = "https://api.groq.com/openai/v1/chat/completions",
        models = { "qwen/qwen3.8-27b" }, model = "qwen/qwen3.8-27b",
        maxTokens = 16384, keyFrom = "console.groq.com/keys", free = true },
    { id = "server", name = "Local AI" },
    { id = "custom", name = "Custom", maxTokens = 16000 },
}
Client.PROVIDER = {}
for _, p in ipairs(Client.PROVIDERS) do Client.PROVIDER[p.id] = p end

--- A job's saved AI as one of the list ("claude" for anything unknown).
function Client.providerId(v)
    return Client.PROVIDER[v] and v or "claude"
end

--- The chat endpoint of an OpenAI-compatible server address: Ollama
-- (http://host:11434), a Pangolin AI gateway (https://ai.example.com), with
-- or without /v1 at the end, or an address ending in /openai (Gemini's).
function Client.chatUrl(base)
    base = tostring(base or ""):gsub("%s", ""):gsub("/+$", "")
    if base:match("/chat/completions$") then return base end
    if base:match("/v1$") or base:match("/openai$") then return base .. "/chat/completions" end
    return base .. "/v1/chat/completions"
end

--- The request body for an OpenAI-compatible server: the prompt, then the
-- pictures (data URLs). `think`: leave thinking as the model has it (no
-- reasoning_effort sent; the services' models don't all take "none").
-- `maxTokens`: the answer's room (16000 unless the service allows less).
function Client.serverBody(model, png, prompt, more, b64, think, maxTokens)
    local content = { { type = "text", text = prompt or "" } }
    for _, pic in ipairs(png and { png } or {}) do
        table.insert(content, { type = "image_url", image_url = { url = "data:image/png;base64," .. b64(pic) } })
    end
    for _, pic in ipairs(more or {}) do
        table.insert(content, { type = "image_url", image_url = { url = "data:image/png;base64," .. b64(pic) } })
    end
    local body = { model = model, max_tokens = maxTokens or 16000, stream = false, messages = { { role = "user", content = content } } }
    -- Thinking models (Gemma 4, Qwen 3.5) are many times faster with their
    -- thinking off, and their thinking can use up the answer's room.
    if not think then body.reasoning_effort = "none" end
    return body
end

--- The answer's text from an OpenAI-compatible reply (reasoning left out).
function Client.serverText(data)
    local choice = type(data) == "table" and type(data.choices) == "table" and data.choices[1]
    local msg = type(choice) == "table" and choice.message
    local content = type(msg) == "table" and msg.content
    if type(content) == "table" then
        local parts = {}
        for _, part in ipairs(content) do
            if type(part) == "table" and type(part.text) == "string" then table.insert(parts, part.text) end
        end
        content = table.concat(parts, "\n")
    end
    if type(content) ~= "string" then return nil end
    content = content:gsub("<think>.-</think>", "")
    return (content:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- What the server (self.server: { urls = { home, pangolin }, keys = {...},
-- model, reachable(url, i), name, think, maxTokens }) answers about the
-- pictures: text, and which address answered (1 home, 2 Pangolin); or nil
-- and why. The home address is tried first, skipped when not reachable
-- (away from home). `name`: the service, in messages ("Local AI" if none).
function Client:transcribeServer(png, prompt, more)
    local s = self.server
    local name = s.name or "Local AI"
    local where = " (Settings > AI > " .. name .. ")."
    if not s.model or s.model == "" then return nil, "No model set for " .. name .. where end
    if (s.urls[1] or "") == "" and (s.urls[2] or "") == "" then
        return nil, (s.name and ("No address set for " .. name) or "No local AI address set") .. where
    end
    local body = self.json.encode(Client.serverBody(s.model, png, prompt, more, self.b64, s.think, s.maxTokens))
    local why = "No address set for " .. name .. where
    for i = 1, 2 do
        local url = s.urls[i]
        if url and url ~= "" and (not s.reachable or s.reachable(url, i)) then
            local headers = { ["content-type"] = "application/json" }
            local key = s.keys and s.keys[i]
            if key and key ~= "" then headers["Authorization"] = "Bearer " .. key end
            local status, reply = self.request("POST", Client.chatUrl(url), headers, body)
            if type(status) ~= "number" then
                why = "Could not reach " .. url .. " (" .. tostring(status) .. ")"
            else
                local ok, data = pcall(self.json.decode, reply or "")
                if not ok then data = nil end
                if status == 200 then
                    local text = Client.serverText(data)
                    if not text then return nil, "The server's answer could not be read." end
                    self.lastModel = type(data.model) == "string" and data.model or s.model
                    return text, i
                end
                local err = type(data) == "table" and data.error
                local msg = type(err) == "table" and (err.message or err.type) or (type(err) == "string" and err) or nil
                if status == 401 or status == 403 then return nil, name .. " refused the key (" .. url .. ")." end
                if status == 429 then
                    return nil, name .. " says too many requests (a free tier's limit?). Wait a little, or pick another AI" .. where
                end
                if status == 404 and msg and msg:find("model", 1, true) then
                    return nil, name .. " has no model \"" .. s.model .. "\". Pick one" .. where
                end
                return nil, (msg or ("HTTP " .. status)) .. " (" .. url .. ")"
            end
        end
    end
    return nil, why
end


return Client
