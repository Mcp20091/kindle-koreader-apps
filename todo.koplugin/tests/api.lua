-- todoapi against a fake network: `luajit tests/api.lua` from the plugin folder.
package.path = "./?.lua;./tests/?.lua;" .. package.path
local Api = require("todoapi")
local json = require("json")

local failed, passed = 0, 0
local function check(name, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    end
end

-- A fake network: `routes` answers by "METHOD url-prefix"; calls are logged.
local function fake(routes)
    local net = { calls = {} }
    function net.request(method, url, headers, body)
        table.insert(net.calls, { method = method, url = url, headers = headers, body = body })
        for _, route in ipairs(routes) do
            if method == route[1] and url:sub(1, #route[2]) == route[2] then
                local answer = route[3]
                if type(answer) == "function" then return answer(url, headers, body) end
                return answer[1], answer[2]
            end
        end
        return 404, "{}"
    end
    return net
end

local function memory()
    local values = {}
    return {
        values = values,
        get = function(k) return values[k] end,
        set = function(k, v) values[k] = v end,
        save = function() end,
    }, values
end

local clock = 1000
local function api(net, settings)
    return Api.new{ settings = settings, clientId = "app-1", request = net.request, json = json,
        now = function() return clock end }
end

-- Sign-in: /common refuses a personal-accounts app, /consumers starts it.
do
    local net = fake({
        { "POST", "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode",
            { 400, json.encode({ error = "invalid_request", error_description = "AADSTS9002331: Application ..." }) } },
        { "POST", "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode",
            { 200, json.encode({ device_code = "DEV", user_code = "ABCD-EFGH", verification_uri = "https://microsoft.com/devicelogin", interval = 5 }) } },
    })
    local settings, values = memory()
    local a = api(net, settings)
    local signIn = a:startSignIn()
    check("sign-in falls back to consumers", signIn and signIn.authority, "consumers")
    check("sign-in code", signIn and signIn.user_code, "ABCD-EFGH")
    check("form has scope", net.calls[1].body:find("scope=Tasks.ReadWrite%20offline_access", 1, true) ~= nil, true)

    local answers = {
        { 400, json.encode({ error = "authorization_pending" }) },
        { 200, json.encode({ access_token = "AT1", refresh_token = "RT1", expires_in = 3600 }) },
    }
    local polls = 0
    net = fake({ { "POST", "https://login.microsoftonline.com/consumers/oauth2/v2.0/token", function()
        polls = polls + 1
        return answers[polls][1], answers[polls][2]
    end } })
    a = api(net, settings)
    check("poll pending", a:pollSignIn(signIn), "pending")
    check("poll ok", a:pollSignIn(signIn), "ok")
    check("keeps refresh token", values.refresh_token, "RT1")
    check("keeps authority", values.authority, "consumers")
    check("signed in", a:signedIn(), true)
end

-- A Graph call refreshes an expired token first, and once more on a 401.
do
    local settings, values = memory()
    values.access_token, values.refresh_token, values.expires_at, values.authority = "OLD", "RT", clock - 10, "consumers"
    local refreshes = 0
    local net = fake({
        { "POST", "https://login.microsoftonline.com/consumers/oauth2/v2.0/token", function()
            refreshes = refreshes + 1
            return 200, json.encode({ access_token = "AT" .. refreshes, expires_in = 3600 })
        end },
        { "GET", "https://graph.microsoft.com/v1.0/me/todo/lists", function(_, headers)
            if headers.Authorization == "Bearer AT1" then return 401, "{}" end
            return 200, json.encode({ value = { { id = "L1==", displayName = "Tasks", wellknownListName = "defaultList" } } })
        end },
    })
    local a = api(net, settings)
    local items = a:getAll("/me/todo/lists")
    check("refreshed twice (expired, then 401)", refreshes, 2)
    check("got lists", items and items[1].displayName, "Tasks")
end

-- Every page of tasks, list ids percent-encoded, open tasks only with steps.
do
    local settings, values = memory()
    values.access_token, values.refresh_token, values.expires_at = "AT", "RT", clock + 3600
    local net = fake({
        { "GET", "https://graph.microsoft.com/v1.0/me/todo/lists/L1%3D%3D/tasks?", function(url)
            if url:find("skiptoken", 1, true) then
                return 200, json.encode({ value = { { id = "T2", title = "Second", status = "notStarted" } } })
            end
            return 200, json.encode({
                value = { { id = "T1", title = "First", status = "notStarted", importance = "high",
                    dueDateTime = { dateTime = "2026-10-20T04:00:00.0000000", timeZone = "UTC" } } },
                ["@odata.nextLink"] = "https://graph.microsoft.com/v1.0/me/todo/lists/L1%3D%3D/tasks?$skiptoken=X",
            })
        end },
        { "GET", "https://graph.microsoft.com/v1.0/me/todo/lists", { 200, json.encode({ value = { { id = "L1==", displayName = "Tasks" } } }) } },
    })
    local a = api(net, settings)
    local lists = a:fetchAll(-4 * 3600)
    check("fetch lists", lists and #lists, 1)
    check("fetch both pages", lists and #lists[1].tasks, 2)
    check("task starred", lists and lists[1].tasks[1].important, true)
    local first = net.calls[2].url
    check("open tasks filter", first:find("$filter=status%20ne%20'completed'", 1, true) ~= nil, true)
    check("steps expanded", first:find("$expand=checklistItems", 1, true) ~= nil, true)
end

-- Changes: complete, due cleared by hand-written null, add with a due day.
do
    local settings, values = memory()
    values.access_token, values.refresh_token, values.expires_at = "AT", "RT", clock + 3600
    local net = fake({
        { "PATCH", "https://graph.microsoft.com/v1.0/me/todo/lists/L1/tasks/T1", { 200, "{}" } },
        { "POST", "https://graph.microsoft.com/v1.0/me/todo/lists/L1/tasks", function(_, _, body)
            local sent = json.decode(body)
            return 201, json.encode({ id = "T9", title = sent.title, dueDateTime = sent.dueDateTime })
        end },
        { "DELETE", "https://graph.microsoft.com/v1.0/me/todo/lists/L1/tasks/T1", { 204, "" } },
    })
    local a = api(net, settings)
    check("complete", a:complete("L1", "T1"), true)
    check("complete body", net.calls[#net.calls].body, '{"status":"completed"}')
    check("clear due", a:setDue("L1", "T1", nil), true)
    check("clear due body", net.calls[#net.calls].body, '{"dueDateTime":null}')
    check("json content type", net.calls[#net.calls].headers["Content-Type"], "application/json")
    local Dates = require("tododates")
    local task = a:add("L1", "New", Dates.parse("2026-10-21"), -4 * 3600)
    check("add", task and task.title, "New")
    check("add due", task and Dates.format(task.due), "2026-10-21")
    check("delete", a:delete("L1", "T1"), true)
end

-- Microsoft ends the sign-in: signed out, with the reason.
do
    local settings, values = memory()
    values.access_token, values.refresh_token, values.expires_at = "AT", "RT", clock - 1
    local net = fake({ { "POST", "https://login.microsoftonline.com/common/oauth2/v2.0/token",
        { 400, json.encode({ error = "invalid_grant" }) } } })
    local a = api(net, settings)
    local status, why = a:graph("GET", "/me/todo/lists")
    check("no status when signed out", status, nil)
    check("signed out", a:signedIn(), false)
    check("why", why ~= nil and why:find("sign in again", 1, true) ~= nil, true)
end

-- Sending the reader's changes: each kind of change as To Do wants it.
do
    local Dates = require("tododates")
    local Model = require("todomodel")
    local Store = require("todostore")
    local settings, values = memory()
    values.access_token, values.refresh_token, values.expires_at = "AT", "RT", clock + 3600
    local made = 0
    local G = "https://graph.microsoft.com/v1.0/me/todo/lists/"
    local net = fake({
        { "POST", G .. "L1/tasks/T1/checklistItems", { 201, json.encode({ id = "S9" }) } },
        { "POST", G .. "L1/tasks", function() made = made + 1 return 201, json.encode({ id = "N" .. made }) end },
        { "POST", G .. "L2/tasks/N", { 201, json.encode({ id = "S10" }) } },
        { "POST", G .. "L2/tasks", function() made = made + 1 return 201, json.encode({ id = "N" .. made }) end },
        { "PATCH", G .. "L1/tasks/GONE", { 400, json.encode({ error = { code = "invalidRequest", message = "Invalid request" } }) } },
        { "PATCH", G .. "L1/tasks/BUSY", { 503, "{}" } },
        { "PATCH", G .. "L1/tasks/", { 200, "{}" } },
        { "DELETE", G .. "L1/tasks/", { 204, "" } },
        { "GET", "https://graph.microsoft.com/v1.0/me/todo/lists", { 200, json.encode({ value = {} }) } },
    })
    local a = api(net, settings)
    local d = Dates.parse("2026-10-20")
    local sunday = Dates.parse("2026-10-25")

    check("nulls appended", a:encodeWithNulls({ title = "x" }, { "recurrence" }), '{"title":"x","recurrence":null}')
    check("nulls only", a:encodeWithNulls({}, { "dueDateTime", "recurrence" }), '{"dueDateTime":null,"recurrence":null}')

    local result, map = a:send({ kind = "add", list = "L1", id = "new:1",
        fields = { title = "Smoke alarm batteries", due = d, remindAt = d * 86400 + 18 * 3600, important = true } })
    check("add ok", result, "ok")
    check("add real id", map and map["new:1"], "N1")
    local body = json.decode(net.calls[#net.calls].body)
    check("add due midnight utc", body.dueDateTime.dateTime, "2026-10-20T00:00:00")
    check("add reminder", body.isReminderOn and body.reminderDateTime.dateTime, "2026-10-20T18:00:00")
    check("add starred", body.importance, "high")

    -- A repeating task's new date: repeat off, date, repeat back from the new day.
    local n = #net.calls
    result = a:send({ kind = "due", list = "L1", task = "T1", day = sunday + 7, recurrence = Model.preset("weekly", sunday) })
    check("repeat due ok", result, "ok")
    check("repeat due three calls", #net.calls - n, 3)
    check("repeat off first", net.calls[n + 1].body, '{"recurrence":null}')
    check("then the date", json.decode(net.calls[n + 2].body).dueDateTime.dateTime, "2026-11-01T00:00:00")
    local back = json.decode(net.calls[n + 3].body).recurrence
    check("repeat back from the new day", back.range.startDate, "2026-11-01")
    check("repeat back weekly", back.pattern.daysOfWeek[1], "sunday")

    n = #net.calls
    a:send({ kind = "due", list = "L1", task = "T1", day = nil })
    check("plain due cleared", net.calls[n + 1].body, '{"dueDateTime":null}')
    a:send({ kind = "remind", list = "L1", task = "T1", at = false })
    check("reminder off", net.calls[n + 2].body, '{"isReminderOn":false}')
    a:send({ kind = "norepeat", list = "L1", task = "T1", notes = "Old date" })
    local nb = net.calls[n + 3].body
    check("repeat removed body", nb:find('"recurrence":null', 1, true) ~= nil and nb:find('"dueDateTime":null', 1, true) ~= nil, true)
    result, map = a:send({ kind = "stepAdd", list = "L1", task = "T1", id = "new:2", title = "Laundry" })
    check("step added", map and map["new:2"], "S9")

    n = #net.calls
    result, map = a:send({ kind = "move", list = "L1", task = "T1", to = "L2", id = "new:3",
        copy = { title = "Call the dentist", important = false, steps = { { title = "Ask about the bill", checked = true } } } })
    check("move ok", result, "ok")
    check("move copy made", net.calls[n + 1].method .. " " .. net.calls[n + 1].url, "POST " .. G .. "L2/tasks")
    check("move steps copied", json.decode(net.calls[n + 2].body).isChecked, true)
    check("move old deleted", net.calls[n + 3].method, "DELETE")
    check("move new id", map and map["new:3"], "N" .. made)

    check("refused: dropped", (a:send({ kind = "rename", list = "L1", task = "GONE", title = "x" })), "drop")
    check("busy: stop", (a:send({ kind = "rename", list = "L1", task = "BUSY", title = "x" })), "stop")

    -- A sync sends in order, drops what To Do refuses, stops when it is busy (the rest kept).
    local store = Store.new{ data = { lists = { { id = "L1", name = "Tasks", tasks = {
        { id = "T1", title = "Call the dentist", steps = {} }, { id = "GONE", title = "Gone", steps = {} }, { id = "BUSY", title = "Busy", steps = {} } } } } } }
    local newId = store:addTask("L1", { title = "Laundry" })
    store:rename("L1", newId, "Laundry and towels")
    store:rename("L1", "GONE", "Still gone")
    store:rename("L1", "BUSY", "Later")
    store:rename("L1", "T1", "After the busy one")
    local report = store:sync(a, { offset = 0 })
    check("sync sent", report.sent, 2)
    check("rename follows the new id", net.calls[#net.calls - 3].url:find("/tasks/N", 1, true) ~= nil, true)
    check("sync dropped", #report.dropped, 1)
    check("sync stopped", report.stopped ~= nil, true)
    check("rest kept", store:pending(), 2)
    check("downloaded anyway", store:syncedAt() ~= nil, true)
    local only = store:sync(a, { downloadOnly = true })
    check("download only sends nothing", only.sent, 0)
    check("download only keeps the queue", store:pending(), 2)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
