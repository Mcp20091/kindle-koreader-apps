--[[--
Microsoft To Do over Microsoft Graph: the device-code sign-in (a code entered
on a phone or computer, so the Kindle never sees a password), token refresh,
and the task calls the plugin makes.

Network and JSON are passed in (`request`, `json`), so the tests can run it
without KOReader; main.lua passes KOReader's.
]]

local Dates = require("tododates")
local Model = require("todomodel")

local Api = {}
Api.__index = Api

local GRAPH = "https://graph.microsoft.com/v1.0"
local LOGIN = "https://login.microsoftonline.com/%s/oauth2/v2.0/"
local SCOPE = "Tasks.ReadWrite offline_access"

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function form(fields)
    local parts = {}
    for k, v in pairs(fields) do table.insert(parts, urlencode(k) .. "=" .. urlencode(v)) end
    table.sort(parts)
    return table.concat(parts, "&")
end

--- options: settings (get(key), set(key, value), save()), clientId, request(method, url, headers, body)
-- returning (status number or error string, body string), json (encode, decode), now() (seconds).
function Api.new(options)
    local self = setmetatable({}, Api)
    self.settings = options.settings
    self.clientId = options.clientId
    self.request = options.request
    self.json = options.json
    self.now = options.now or os.time
    return self
end

function Api:decode(body)
    if not body or body == "" then return nil end
    local ok, value = pcall(self.json.decode, body)
    if ok and type(value) == "table" then return value end
    return nil
end

-- With the launcher, the sign-in is the shared Microsoft account's (apps'
-- appsmicrosoft.lua, PS.microsoft): `self.account` then answers these.

function Api:signedIn()
    -- (A shared sign-in made before To Do was part of it doesn't cover To Do yet:
    -- To Do shows Sign in, which signs in once more for every app.)
    if self.account then return self.account.signedIn() and self.account.allowed("Tasks.ReadWrite") end
    return self.settings.get("refresh_token") ~= nil
end

function Api:signOut()
    if self.account then return self.account.forget() end
    for _, key in ipairs({ "refresh_token", "access_token", "expires_at", "authority" }) do
        self.settings.set(key, nil)
    end
    self.settings.save()
end

function Api:postForm(authority, endpoint, fields)
    local status, body = self.request("POST", string.format(LOGIN, authority) .. endpoint,
        { ["Content-Type"] = "application/x-www-form-urlencoded" }, form(fields))
    return status, self:decode(body)
end

--- Starts a sign-in. Returns { user_code, verification_uri, device_code,
-- interval, expires_in, message } or nil and why. An app that takes personal
-- accounts only must use /consumers (AADSTS9002331): tried when /common says so.
function Api:startSignIn()
    if self.account then return self.account.startSignIn() end
    if not self.clientId or self.clientId == "" then return nil, "No app ID set" end
    local fields = { client_id = self.clientId, scope = SCOPE }
    for _, authority in ipairs({ "common", "consumers" }) do
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

function Api:keepTokens(data, authority)
    self.settings.set("access_token", data.access_token)
    if data.refresh_token then self.settings.set("refresh_token", data.refresh_token) end
    self.settings.set("expires_at", self.now() + (tonumber(data.expires_in) or 3600))
    if authority then self.settings.set("authority", authority) end
    self.settings.save()
end

--- One poll of a sign-in started with startSignIn(). Returns "ok",
-- "pending", "slow_down", "expired" or "error" (with why).
function Api:pollSignIn(signIn)
    if self.account then return self.account.pollSignIn(signIn) end
    local status, data = self:postForm(signIn.authority, "token", {
        grant_type = "urn:ietf:params:oauth:grant-type:device_code",
        client_id = self.clientId,
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
function Api:accessToken(force)
    if self.account then return self.account.accessToken(force) end
    local token = self.settings.get("access_token")
    if not force and token and (self.settings.get("expires_at") or 0) > self.now() + 60 then return token end
    local refresh = self.settings.get("refresh_token")
    if not refresh then return nil, "Not signed in" end
    local status, data = self:postForm(self.settings.get("authority") or "common", "token", {
        grant_type = "refresh_token",
        client_id = self.clientId,
        refresh_token = refresh,
        scope = SCOPE,
    })
    if type(status) ~= "number" then return nil, "No connection: " .. tostring(status) end
    if status == 200 and data and data.access_token then
        self:keepTokens(data)
        return data.access_token
    end
    if data and (data.error == "invalid_grant" or data.error == "interaction_required") then
        self:signOut()
        return nil, "Signed out by Microsoft: sign in again"
    end
    return nil, data and (data.error_description or data.error) or ("HTTP " .. status)
end

--- A Graph call. `path` is under /v1.0 or a full URL (a next page). Returns
-- status (or nil) and the decoded body (or why it failed).
function Api:graph(method, path, body)
    local url = path:sub(1, 8) == "https://" and path or GRAPH .. path
    local text = body
    if type(body) == "table" then text = self.json.encode(body) end
    for attempt = 1, 2 do
        local token, why = self:accessToken(attempt == 2)
        if not token then return nil, why end
        local headers = { Authorization = "Bearer " .. token }
        if text then headers["Content-Type"] = "application/json" end
        local status, reply = self.request(method, url, headers, text)
        if type(status) ~= "number" then return nil, "No connection: " .. tostring(status) end
        if status ~= 401 then
            local data = self:decode(reply)
            if status >= 200 and status < 300 then return status, data end
            local err = data and data.error and (data.error.message or data.error.code)
            return status, err or ("HTTP " .. status)
        end
    end
    return 401, "Microsoft refused the sign-in"
end

--- The connection test: Microsoft's sign-in server, then (signed in) To Do itself.
-- Returns { { name = "signin"|"todo", detail, ok, kind, err, ms } }; kind is "ok",
-- "signin" (sign in again), "unreachable" or "failed". clock() gives seconds.
function Api:testConnection(clock)
    local rows = {}
    local started = clock()
    local status = self.request("GET", "https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration")
    local row = { name = "signin", detail = "login.microsoftonline.com", ms = math.floor((clock() - started) * 1000) }
    if type(status) ~= "number" then row.ok, row.kind, row.err = false, "unreachable", status
    elseif status == 200 then row.ok, row.kind = true, "ok"
    else row.ok, row.kind, row.err = false, "failed", "HTTP " .. status end
    table.insert(rows, row)
    if self:signedIn() then
        started = clock()
        local st, why = self:graph("GET", "/me/todo/lists?$top=1")
        row = { name = "todo", detail = "graph.microsoft.com", ms = math.floor((clock() - started) * 1000) }
        if st and st >= 200 and st < 300 then row.ok, row.kind = true, "ok"
        elseif st == 401 or not self:signedIn() then row.ok, row.kind, row.err = false, "signin", why
        elseif not st and tostring(why):find("^No connection") then row.ok, row.kind, row.err = false, "unreachable", tostring(why):gsub("^No connection: ", "")
        else row.ok, row.kind, row.err = false, "failed", why end
        table.insert(rows, row)
    end
    return rows
end

-- Every page of a collection.
function Api:getAll(path)
    local items = {}
    local next = path
    -- (At most 200 pages, and never the same page twice: a broken link can't go on for ever.)
    local seen, pages = {}, 0
    while next do
        if seen[next] or pages >= 200 then break end
        seen[next], pages = true, pages + 1
        local status, data = self:graph("GET", next)
        if status ~= 200 then return nil, data end
        for _, item in ipairs(data.value or {}) do table.insert(items, item) end
        next = data["@odata.nextLink"]
    end
    return items
end

local OPEN_TASKS = "/tasks?$filter=status%20ne%20'completed'&$top=100&$expand=checklistItems"

--- Every list with its open tasks. Returns lists, or nil and why.
function Api:fetchAll(offset)
    local raw, why = self:getAll("/me/todo/lists")
    if not raw then return nil, why end
    local lists = {}
    for _, l in ipairs(raw) do
        local list = Model.listFromGraph(l)
        local tasks, err = self:getAll("/me/todo/lists/" .. urlencode(list.id) .. OPEN_TASKS)
        if not tasks then return nil, err end
        for _, t in ipairs(tasks) do table.insert(list.tasks, Model.taskFromGraph(t, offset)) end
        table.insert(lists, list)
    end
    return lists
end

--- One list's open tasks again (after completing a repeating task, To Do
-- makes its next one).
function Api:fetchList(listId, offset)
    local tasks, why = self:getAll("/me/todo/lists/" .. urlencode(listId) .. OPEN_TASKS)
    if not tasks then return nil, why end
    local out = {}
    for _, t in ipairs(tasks) do table.insert(out, Model.taskFromGraph(t, offset)) end
    return out
end

local function listPath(listId)
    return "/me/todo/lists/" .. urlencode(listId)
end

local function taskPath(listId, taskId)
    return listPath(listId) .. "/tasks/" .. urlencode(taskId)
end

local function ok(status)
    return status ~= nil and status >= 200 and status < 300
end
Api.ok = ok

-- Graph's recurrence for a repeat (todomodel's, starting `day` if given).
function Api.recurrenceToGraph(rec, day)
    local p, r = rec.pattern, rec.range or {}
    local pattern = { type = p.type, interval = p.interval or 1 }
    if p.daysOfWeek and #p.daysOfWeek > 0 then pattern.daysOfWeek = p.daysOfWeek end
    if p.firstDayOfWeek then pattern.firstDayOfWeek = p.firstDayOfWeek end
    if p.dayOfMonth then pattern.dayOfMonth = p.dayOfMonth end
    if p.month then pattern.month = p.month end
    if p.index then pattern.index = p.index end
    local range = { type = r.type or "noEnd", startDate = day and Dates.format(day) or r.startDate }
    if range.type == "endDate" then range.endDate = r.endDate end
    if range.type == "numbered" then range.numberOfOccurrences = r.numberOfOccurrences end
    return { pattern = pattern, range = range }
end

local function reminderFields(body, at)
    if at then
        body.isReminderOn = true
        body.reminderDateTime = { dateTime = Dates.isoUtc(at), timeZone = "UTC" }
    else
        body.isReminderOn = false
    end
end

-- A task's fields (todomodel's) as Graph's JSON, for a new task.
function Api.taskBody(t)
    local body = { title = t.title, importance = t.important and "high" or "normal" }
    if t.due then body.dueDateTime = Dates.dueToGraph(t.due) end
    if t.remindAt then reminderFields(body, t.remindAt) end
    if t.recurrence and t.due then body.recurrence = Api.recurrenceToGraph(t.recurrence, t.due) end
    if t.notes and t.notes ~= "" then body.body = { content = t.notes, contentType = "text" } end
    return body
end

--- JSON for `fields` plus `nulls` (names set to null: the JSON encoders drop nil).
function Api:encodeWithNulls(fields, nulls)
    local text = next(fields) and self.json.encode(fields) or "{}"
    if not nulls or #nulls == 0 then return text end
    local extra = {}
    for _, k in ipairs(nulls) do table.insert(extra, string.format('"%s":null', k)) end
    if text == "{}" then return "{" .. table.concat(extra, ",") .. "}" end
    return (text:gsub("}%s*$", "," .. table.concat(extra, ",") .. "}"))
end

--- PATCHes a task: status and decoded body (or why).
function Api:patch(listId, taskId, fields, nulls)
    return self:graph("PATCH", taskPath(listId, taskId), self:encodeWithNulls(fields or {}, nulls))
end

function Api:patchTask(listId, taskId, fields)
    local status, data = self:graph("PATCH", taskPath(listId, taskId), fields)
    return ok(status), data
end

function Api:complete(listId, taskId)
    return self:patchTask(listId, taskId, { status = "completed" })
end

function Api:setImportant(listId, taskId, important)
    return self:patchTask(listId, taskId, { importance = important and "high" or "normal" })
end

--- `day` (days since 1970) or nil to clear the due date.
function Api:setDue(listId, taskId, day)
    if day then return self:patchTask(listId, taskId, { dueDateTime = Dates.dueToGraph(day) }) end
    local status, data = self:patch(listId, taskId, {}, { "dueDateTime" })
    return ok(status), data
end

--- A new due date for a repeating task. Patching the due date of a repeating
-- task makes To Do split it (a copy with the old date is left behind), so
-- the repeat is taken off, the date changed, and the repeat put back from
-- the new day. `remindAt`: the reminder too (nil leaves it, false clears it).
function Api:setDueKeepingRepeat(listId, taskId, day, recurrence, remindAt)
    local status, data = self:patch(listId, taskId, {}, { "recurrence" })
    if not ok(status) then return status, data end
    local fields = { dueDateTime = Dates.dueToGraph(day) }
    if remindAt ~= nil then reminderFields(fields, remindAt or nil) end
    local status2, data2 = self:patch(listId, taskId, fields)
    -- The repeat goes back either way (from the old day if the date was refused).
    local status3, data3 = self:patch(listId, taskId,
        { recurrence = Api.recurrenceToGraph(recurrence, ok(status2) and day or nil) })
    if not ok(status2) then return status2, data2 end
    return status3, data3
end

function Api:rename(listId, taskId, title)
    return self:patchTask(listId, taskId, { title = title })
end

function Api:delete(listId, taskId)
    local status, data = self:graph("DELETE", taskPath(listId, taskId))
    return status == 204 or status == 404, data
end

--- A new task; returns the task (as the model has it) or nil and why.
function Api:add(listId, title, day, offset)
    local body = { title = title }
    if day then body.dueDateTime = Dates.dueToGraph(day) end
    local status, data = self:graph("POST", listPath(listId) .. "/tasks", body)
    if status ~= 201 then return nil, data end
    return Model.taskFromGraph(data, offset)
end

function Api:checkStep(listId, taskId, stepId, checked)
    local status, data = self:graph("PATCH", taskPath(listId, taskId) .. "/checklistItems/" .. urlencode(stepId),
        { isChecked = checked })
    return ok(status), data
end

-- ------------------------------------------------------------------ sending the reader's changes

-- What became of one change: "ok" (with real ids for new things), "drop" (To
-- Do refused it, e.g. a task deleted elsewhere or looked up in the wrong
-- list, which To Do answers with an error that is not 404; sending it again
-- would not help) or "stop" (no connection, or To Do busy: try later).
local function outcome(status, data, map)
    if ok(status) then return "ok", map end
    if status == nil or status == 429 or status == 408 or status >= 500 then return "stop", data end
    return "drop", data
end

local Send = {}

function Send.add(self, op)
    local status, data = self:graph("POST", listPath(op.list) .. "/tasks", Api.taskBody(op.fields))
    if ok(status) and type(data) == "table" and data.id then return "ok", { [op.id] = data.id } end
    return outcome(status, data)
end

function Send.done(self, op)
    return outcome(self:patch(op.list, op.task, { status = "completed" }))
end

function Send.star(self, op)
    return outcome(self:patch(op.list, op.task, { importance = op.on and "high" or "normal" }))
end

function Send.due(self, op)
    if op.day and op.recurrence then
        return outcome(self:setDueKeepingRepeat(op.list, op.task, op.day, op.recurrence, op.remind))
    end
    local fields, nulls = {}, {}
    if op.day then fields.dueDateTime = Dates.dueToGraph(op.day) else nulls = { "dueDateTime" } end
    if op.remind ~= nil then reminderFields(fields, op.remind or nil) end
    return outcome(self:patch(op.list, op.task, fields, nulls))
end

function Send.remind(self, op)
    local fields = {}
    reminderFields(fields, op.at or nil)
    return outcome(self:patch(op.list, op.task, fields))
end

function Send.repeats(self, op)
    local status, data = self:patch(op.list, op.task, {}, { "recurrence" })
    if not ok(status) then return outcome(status, data) end
    return outcome(self:patch(op.list, op.task, {
        dueDateTime = Dates.dueToGraph(op.day),
        recurrence = Api.recurrenceToGraph(op.recurrence, op.day),
    }))
end

function Send.norepeat(self, op)
    return outcome(self:patch(op.list, op.task, { body = { content = op.notes or "", contentType = "text" } },
        { "recurrence", "dueDateTime" }))
end

function Send.rename(self, op)
    return outcome(self:patch(op.list, op.task, { title = op.title }))
end

function Send.notes(self, op)
    return outcome(self:patch(op.list, op.task, { body = { content = op.text or "", contentType = "text" } }))
end

local function stepPath(op, stepId)
    local path = taskPath(op.list, op.task) .. "/checklistItems"
    if stepId then path = path .. "/" .. urlencode(stepId) end
    return path
end

function Send.stepAdd(self, op)
    local status, data = self:graph("POST", stepPath(op), { displayName = op.title })
    if ok(status) and type(data) == "table" and data.id then return "ok", { [op.id] = data.id } end
    return outcome(status, data)
end

function Send.stepCheck(self, op)
    return outcome(self:graph("PATCH", stepPath(op, op.step), { isChecked = op.on }))
end

function Send.stepRename(self, op)
    return outcome(self:graph("PATCH", stepPath(op, op.step), { displayName = op.title }))
end

function Send.stepDelete(self, op)
    local status, data = self:graph("DELETE", stepPath(op, op.step))
    if status == 404 then return "ok" end
    return outcome(status, data)
end

-- To Do has no move: a copy in the other list (steps too), then the old one deleted.
function Send.move(self, op)
    local status, data = self:graph("POST", listPath(op.to) .. "/tasks", Api.taskBody(op.copy))
    if not (ok(status) and type(data) == "table" and data.id) then return outcome(status, data) end
    local newId = data.id
    for _, step in ipairs(op.copy.steps or {}) do
        local s = self:graph("POST", listPath(op.to) .. "/tasks/" .. urlencode(newId) .. "/checklistItems",
            { displayName = step.title, isChecked = step.checked })
        -- Connection gone: no more waiting on each step; the old task stays (better twice than lost).
        if type(s) ~= "number" then return "ok", { [op.id] = newId } end
    end
    -- If the old one cannot be deleted it stays: better twice than lost.
    self:graph("DELETE", taskPath(op.list, op.task))
    return "ok", { [op.id] = newId }
end

function Send.delete(self, op)
    local status, data = self:graph("DELETE", taskPath(op.list, op.task))
    if status == 404 then return "ok" end
    return outcome(status, data)
end

function Send.listAdd(self, op)
    local status, data = self:graph("POST", "/me/todo/lists", { displayName = op.name })
    if ok(status) and type(data) == "table" and data.id then return "ok", { [op.id] = data.id } end
    return outcome(status, data)
end

function Send.listRename(self, op)
    return outcome(self:graph("PATCH", listPath(op.list), { displayName = op.name }))
end

function Send.listDelete(self, op)
    local status, data = self:graph("DELETE", listPath(op.list))
    if status == 404 then return "ok" end
    return outcome(status, data)
end

--- Sends one queued change (todostore's): "ok" and the new ids, "drop" and
-- why, or "stop" and why.
function Api:send(op)
    local fn = Send[op.kind]
    if not fn then return "drop", "Unknown change " .. tostring(op.kind) end
    return fn(self, op)
end

Api.urlencode = urlencode
return Api
