--[[--
One Microsoft account for every app (To Do, Notes' OneNote): one App ID, one
sign-in (a code entered on a phone or computer), one set of tokens, kept in
koreader/settings/microsoft.lua. Each app says what it needs; signing in asks
Microsoft for all of it at once, and the account (who signed in) is shown.

In KOReader's PluginShare (apps registers it when it loads, before the others):

    PS.microsoft.use{ key = "todo", name = _("To Do"), scope = "Tasks.ReadWrite",
        signedIn = fn(), signedOut = fn() }      -- after a sign-in / a sign-out
    PS.microsoft.clientId()  PS.microsoft.signedIn()  PS.microsoft.account()
    PS.microsoft.allowed(scope)        -- the sign-in covers it (else: sign in again)
    PS.microsoft.accessToken(force)    -- token, or nil, why (blocking: in a child is fine)
    PS.microsoft.startSignIn()  PS.microsoft.pollSignIn(signIn)   -- as the apps' own were
    PS.microsoft.adopt{ clientId, tokens = { refresh_token, ... }, scope }  -- an app's old sign-in, once
    PS.microsoft.signIn(done)  PS.microsoft.signOut()  PS.microsoft.showSettings()

The account's logic (Account.new) takes its storage and network, so the tests
run it without KOReader.
]]

local Account = {}
Account.__index = Account

local LOGIN = "https://login.microsoftonline.com/%s/oauth2/v2.0/"
-- Always asked for: staying signed in, and who it is (shown in the settings).
local BASE_SCOPE = "offline_access openid profile"
local TOKEN_KEYS = { "refresh_token", "access_token", "expires_at", "authority", "scope", "account" }
Account.TOKEN_KEYS = TOKEN_KEYS

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function form(fields)
    local parts = {}
    for k, v in pairs(fields) do table.insert(parts, urlencode(k) .. "=" .. urlencode(v)) end
    table.sort(parts)
    return table.concat(parts, "&")
end

--- options: store (get(key), set(key, value), save()), request(method, url, headers, body)
-- returning (status number or error string, body), json (encode, decode), now() (seconds),
-- uses() -> { { key, name, scope } }.
function Account.new(options)
    local self = setmetatable({}, Account)
    self.store = options.store
    self.request = options.request
    self.json = options.json
    self.now = options.now or os.time
    self.uses = options.uses or function() return {} end
    return self
end

function Account:decode(body)
    if not body or body == "" then return nil end
    local ok, value = pcall(self.json.decode, body)
    return ok and type(value) == "table" and value or nil
end

function Account:clientId()
    local id = self.store.get("client_id")
    return id and id ~= "" and id or nil
end

function Account:setClientId(id)
    id = id and tostring(id):match("^%s*(.-)%s*$") or ""
    self.store.set("client_id", id ~= "" and id or nil)
    self.store.save()
end

function Account:signedIn()
    return self.store.get("refresh_token") ~= nil
end

--- Who signed in ("name@outlook.com"), when Microsoft said.
function Account:account()
    return self.store.get("account")
end

--- What signing in asks for: staying signed in, who it is, and each app's part.
function Account:scopes()
    local seen, parts = {}, {}
    for word in BASE_SCOPE:gmatch("%S+") do seen[word:lower()] = true table.insert(parts, word) end
    for __, u in ipairs(self.uses()) do
        for word in tostring(u.scope or ""):gmatch("%S+") do
            if not seen[word:lower()] then seen[word:lower()] = true table.insert(parts, word) end
        end
    end
    return table.concat(parts, " ")
end

--- Whether the sign-in covers `scope` (Microsoft names it in its answers).
function Account:allowed(scope)
    local granted = (self.store.get("scope") or ""):lower()
    for word in tostring(scope or ""):gmatch("%S+") do
        if not (" " .. granted .. " "):find(" " .. word:lower() .. " ", 1, true) then return false end
    end
    return true
end

-- Who it is, from the sign-in's id_token (a JWT: its middle part).
local function accountOf(json, idToken)
    local payload = type(idToken) == "string" and idToken:match("^[^.]+%.([^.]+)%.")
    if not payload then return nil end
    payload = payload:gsub("-", "+"):gsub("_", "/")
    payload = payload .. string.rep("=", (4 - #payload % 4) % 4)
    local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local bits = payload:gsub("=", ""):gsub(".", function(c)
        local i = b64:find(c, 1, true) - 1
        local s = ""
        for b = 5, 0, -1 do s = s .. (math.floor(i / 2 ^ b) % 2) end
        return s
    end)
    local text = bits:gsub("%d%d%d?%d?%d?%d?%d?%d?", function(byte)
        if #byte ~= 8 then return "" end
        return string.char(tonumber(byte, 2))
    end)
    local ok, t = pcall(json.decode, text)
    if not ok or type(t) ~= "table" then return nil end
    return t.preferred_username or t.email or t.name
end
Account.accountOf = accountOf

function Account:postForm(authority, endpoint, fields)
    local status, body = self.request("POST", string.format(LOGIN, authority) .. endpoint,
        { ["Content-Type"] = "application/x-www-form-urlencoded" }, form(fields))
    return status, self:decode(body)
end

function Account:keepTokens(data, authority)
    self.store.set("access_token", data.access_token)
    if data.refresh_token then self.store.set("refresh_token", data.refresh_token) end
    self.store.set("expires_at", self.now() + (tonumber(data.expires_in) or 3600))
    if data.scope then self.store.set("scope", data.scope) end
    local who = accountOf(self.json, data.id_token)
    if who then self.store.set("account", who) end
    if authority then self.store.set("authority", authority) end
    self.store.save()
end

--- Starts a sign-in: { user_code, verification_uri, device_code, interval,
-- expires_in, authority }, or nil and why. An app for personal accounts only
-- must use /consumers (AADSTS9002331): tried when /common says so.
function Account:startSignIn()
    local id = self:clientId()
    if not id then return nil, "No App ID set" end
    local fields = { client_id = id, scope = self:scopes() }
    for __, authority in ipairs({ "common", "consumers" }) do
        local status, data = self:postForm(authority, "devicecode", fields)
        if type(status) ~= "number" then return nil, "No connection: " .. tostring(status) end
        if status == 200 and data and data.device_code then
            data.authority = authority
            return data
        end
        local why = data and (data.error_description or data.error) or ("HTTP " .. status)
        if not tostring(why):find("AADSTS9002331", 1, true) then return nil, why end
    end
    return nil, "Sign-in refused"
end

--- One look at a sign-in: "ok", "pending", "slow_down", "expired" or "error" (and why).
function Account:pollSignIn(signIn)
    local status, data = self:postForm(signIn.authority, "token", {
        grant_type = "urn:ietf:params:oauth:grant-type:device_code",
        client_id = self:clientId(),
        device_code = signIn.device_code,
    })
    if type(status) ~= "number" then return "pending" end  -- The network dropped: try again.
    if status == 200 and data and data.access_token then
        self:keepTokens(data, signIn.authority)
        return "ok"
    end
    local err = data and data.error or ""
    if err == "authorization_pending" then return "pending" end
    if err == "slow_down" then return "slow_down" end
    if err == "expired_token" or err == "code_expired" then return "expired" end
    return "error", data and (data.error_description or err) or ("HTTP " .. status)
end

--- A valid access token, refreshed when it is about to run out; nil and why.
function Account:accessToken(force)
    local token = self.store.get("access_token")
    if not force and token and (self.store.get("expires_at") or 0) > self.now() + 60 then return token end
    local refresh = self.store.get("refresh_token")
    if not refresh then return nil, "Not signed in" end
    -- What this sign-in was given (asking for more would be refused).
    local scope = self.store.get("scope")
    scope = (scope and scope ~= "") and (scope:find("offline_access", 1, true) and scope or (scope .. " offline_access")) or self:scopes()
    local status, data = self:postForm(self.store.get("authority") or "common", "token", {
        grant_type = "refresh_token", client_id = self:clientId(), refresh_token = refresh, scope = scope,
    })
    if type(status) ~= "number" then return nil, "No connection: " .. tostring(status) end
    if status == 200 and data and data.access_token then
        self:keepTokens(data)
        return data.access_token
    end
    if data and (data.error == "invalid_grant" or data.error == "interaction_required") then
        self:forget()
        return nil, "Signed out by Microsoft: sign in again"
    end
    return nil, data and (data.error_description or data.error) or ("HTTP " .. status)
end

--- The sign-in removed here (the App ID stays).
function Account:forget()
    for __, k in ipairs(TOKEN_KEYS) do self.store.set(k, nil) end
    self.store.save()
end

--- An app's sign-in from before the shared account, taken once (when there's
-- none here yet): o = { clientId, tokens = { refresh_token, access_token,
-- expires_at, authority }, scope }. Returns whether it was taken.
function Account:adopt(o)
    if type(o) ~= "table" then return false end
    if o.clientId and not self:clientId() then self:setClientId(o.clientId) end
    local t = o.tokens or {}
    if self:signedIn() or not t.refresh_token then return false end
    for __, k in ipairs({ "refresh_token", "access_token", "expires_at", "authority" }) do self.store.set(k, t[k]) end
    self.store.set("scope", o.scope)
    self.store.save()
    return true
end

-- ------------------------------------------------------------------ on the Kindle

local M = {}
M.Account = Account

local uses = {}   -- key -> { key, name, scope, signedIn, signedOut }
local account

local function usesList()
    local list = {}
    for __, u in pairs(uses) do table.insert(list, u) end
    table.sort(list, function(a, b) return (a.name or a.key) < (b.name or b.key) end)
    return list
end

local function httpRequest(method, url, headers, body)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    headers = headers or {}
    if body then headers["Content-Length"] = tostring(#body) end
    socketutil:set_timeout(10, 25)
    local ok, code = pcall(function()
        return socket.skip(1, http.request{ url = url, method = method, headers = headers,
            source = body and ltn12.source.string(body) or nil, sink = ltn12.sink.table(sink) })
    end)
    socketutil:reset_timeout()
    if not ok then code = tostring(code) end
    return code, table.concat(sink)
end

function M.get()
    if account then return account end
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local file = LuaSettings:open(DataStorage:getSettingsDir() .. "/microsoft.lua")
    account = Account.new{
        store = {
            get = function(k) return file:readSetting(k) end,
            set = function(k, v) if v == nil then file:delSetting(k) else file:saveSetting(k, v) end end,
            save = function() file:flush() end,
        },
        request = httpRequest,
        json = require("json"),
        uses = usesList,
    }
    return account
end

local function T(...) return require("ffi/util").template(...) end
local function _(s) return require("gettext")(s) end

--- Signing in on the Kindle: the code to enter (and its QR code) until done.
function M.signIn(done)
    local KO = require("appsko")
    local a = M.get()
    if not a:clientId() then return KO.message(_("Set the App ID first (Settings > Microsoft > App ID).")) end
    local UIManager = require("ui/uimanager")
    require("ui/network/manager"):runWhenOnline(function()
        local signIn, why = a:startSignIn()
        if not signIn then return KO.message(T(_("Couldn't reach Microsoft:\n%1"), tostring(why))) end
        local cancelled, dialog = false, nil
        dialog = KO.buttonDialog{
            title = T(_("On a phone or computer, open\n\n%1\n\nand enter\n\n%2"), signIn.verification_uri, signIn.user_code),
            title_align = "center",
            -- Only Cancel closes it: closed any other way, it would go on asking unseen.
            dismissable = false,
            buttons = { {
                { text = _("QR code"), callback = function()
                    require("appsqr").show{ text = signIn.verification_uri,
                        caption = T(_("Scan to open the sign-in page, then enter %1"), signIn.user_code) }
                end },
                { text = _("Cancel"), callback = function() cancelled = true UIManager:close(dialog) end },
            } },
        }
        local interval = tonumber(signIn.interval) or 5
        local deadline = os.time() + (tonumber(signIn.expires_in) or 900)
        local slow = 0
        local function poll()
            if cancelled then return end
            if os.time() > deadline then
                UIManager:close(dialog)
                return KO.message(_("The code ran out. Try signing in again."))
            end
            local started = os.time()
            local result, err = a:pollSignIn(signIn)
            slow = (result == "pending" and os.time() - started >= 8) and slow + 1 or 0
            if slow >= 3 then
                UIManager:close(dialog)
                return KO.message(_("Lost the connection to Microsoft. Check Wi-Fi and try signing in again."))
            end
            if result == "ok" then
                UIManager:close(dialog)
                KO.toast(a:account() and T(_("Signed in as %1"), a:account()) or _("Signed in to Microsoft"))
                M.signedIn()
                if done then done() end
            elseif result == "pending" or result == "slow_down" then
                if result == "slow_down" then interval = interval + 5 end
                UIManager:scheduleIn(interval, poll)
            else
                UIManager:close(dialog)
                KO.message(T(_("Couldn't sign in:\n%1"), tostring(err or _("The code ran out"))))
            end
        end
        UIManager:scheduleIn(interval, poll)
    end)
end

--- After a sign-in (here or on the web page): each app hears of it.
function M.signedIn()
    for __, u in ipairs(usesList()) do if u.signedIn then pcall(u.signedIn) end end
end

--- Signs out of Microsoft on this Kindle (each app hears of it: To Do keeps its lists here).
function M.signOut()
    M.get():forget()
    for __, u in ipairs(usesList()) do if u.signedOut then pcall(u.signedOut) end end
end

--- Settings > Microsoft's rows (search reads their names too).
function M.settingsRows()
    local PS = require("pluginshare")
    local a = M.get()
    local id = a:clientId()
    local rows = {
        { heading = _("ACCOUNT") },
        { _("App ID"), id and (id:sub(1, 8) .. "…") or _("Not set"), function()
            require("appsko").askText{ title = _("App ID (Microsoft Entra application ID)"), text = id or "",
                hint = "00000000-0000-0000-0000-000000000000", pen = false,
                done = function(v) a:setClientId(v) M.showSettings() end }
        end },
    }
    if a:signedIn() then
        table.insert(rows, { a:account() and T(_("Signed in as %1"), a:account()) or _("Signed in"), _("Sign out"), function()
            require("appsko").confirm{
                text = _("Sign out of Microsoft on this Kindle?\n\nTo Do and OneNote stop syncing. To Do keeps its lists on this Kindle."),
                ok = _("Sign out"),
                onOk = function() M.signOut() M.showSettings() end,
            }
        end })
        table.insert(rows, { _("Test connection"), "", function() PS.showConnectionTest("microsoft") end })
    else
        table.insert(rows, { _("Sign in"), id and "" or _("Set the App ID first"), function() M.signIn(function() M.showSettings() end) end })
    end
    local list = usesList()
    if #list > 0 then
        table.insert(rows, { heading = _("USED BY") })
        for __, u in ipairs(list) do
            local ok = a:signedIn() and a:allowed(u.scope)
            table.insert(rows, { u.name or u.key,
                not a:signedIn() and _("Not signed in") or ok and _("Allowed") or _("Sign in again to allow"),
                (a:signedIn() and not ok) and function() M.signIn(function() M.showSettings() end) end or nil })
        end
    end
    return rows
end

--- Settings > Microsoft; `jump`: the row to open it at.
function M.showSettings(jump)
    local PS = require("pluginshare")
    if not PS.settingsPage then return end
    PS.settingsPage{ title = _("Microsoft"), jump = jump, rows = M.settingsRows }
end

function M.install()
    local PS = require("pluginshare")
    PS.microsoft = {
        use = function(u) if type(u) == "table" and u.key then uses[u.key] = u end end,
        clientId = function() return M.get():clientId() end,
        setClientId = function(id) M.get():setClientId(id) end,
        signedIn = function() return M.get():signedIn() end,
        account = function() return M.get():account() end,
        allowed = function(scope) return M.get():allowed(scope) end,
        accessToken = function(force) return M.get():accessToken(force) end,
        startSignIn = function() return M.get():startSignIn() end,
        pollSignIn = function(s) return M.get():pollSignIn(s) end,
        adopt = function(o) return M.get():adopt(o) end,
        forget = function() M.get():forget() end,
        signIn = M.signIn,
        afterSignIn = M.signedIn,
        signOut = M.signOut,
        showSettings = M.showSettings,
        uses = usesList,
        -- The token store itself, for an app that keeps its own Api (in its children too).
        store = function() return M.get().store end,
    }
end

return M
