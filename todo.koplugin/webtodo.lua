--[[--
To Do on the web page (needs the To Do plugin): the lists and tasks kept on
the reader, changed through the plugin's own store (so they go to Microsoft
To Do at the next sync, as changes made on the reader do), lists made,
renamed, hidden, pinned or deleted, the plugin's options, CSV export and
import, the app ID and signing in. Lists on this Kindle (never synced) show
too, can be made here, and a whole one can move to To Do.
]]

local Common = require("webcommon")

local Web = {}

local OPTIONS = {
    starred_first = "boolean", group_by_due = "boolean", show_hidden = "boolean", sync_interval = "number",
    send_now = "boolean", send_delay = "number", download_only = "boolean", sleep_screen = "boolean", sleep_content = "string",
    week_start = "string", tap_opens = "string", push_days = "number", reminders = "boolean", two_panes = "boolean",
    local_lists = "boolean", deghost = "number", stable_lists = "boolean",
}

local signIn  -- the sign-in under way

local function todo()
    local t = Common.plugin("todo")
    if t and t.store then return t end
end

local function taskJson(t, store, Dates, Model)
    local steps = {}
    for __, s in ipairs(t.steps or {}) do table.insert(steps, { id = s.id, title = s.title, checked = s.checked or false }) end
    return {
        id = t.id, title = t.title, completed = t.completed or false, important = t.important or false,
        due = t.due and Dates.format(t.due) or nil, remindAt = t.remindAt,
        ["repeat"] = t.recurrence and Model.repeatText(t.recurrence) or nil,
        notes = t.notes or "", steps = steps, private = store:isPrivate(t.id) or false,
    }
end

function Web.state(t)
    local Dates, Model = require("tododates"), require("todomodel")
    local store = t.store
    local hidden = t:hiddenSet()
    local pinned = t.settings:readSetting("pinned_list")
    local default = t:defaultListId()
    local lists = {}
    for __, l in ipairs(t:orderedLists(true)) do
        local tasks = {}
        for __, task in ipairs(l.tasks or {}) do
            if not task.completed then table.insert(tasks, taskJson(task, store, Dates, Model)) end
        end
        -- Done tasks: Completed (n), as on the Kindle.
        local completed = {}
        for __, task in ipairs(store:completedTasks(l.id)) do table.insert(completed, { id = task.id, title = task.title }) end
        -- Deleted tasks wait until the next sync (store:deletedTasks), to put back.
        local deleted = {}
        for __, d in ipairs(store.deletedTasks and store:deletedTasks(l.id) or {}) do
            table.insert(deleted, { id = d.op.task, title = d.title, completed = d.completed })
        end
        table.insert(lists, {
            id = l.id, name = l.name, hidden = hidden[l.id] or false, pinned = pinned == l.id,
            default = default == l.id, flagged = l.wellknown == "flaggedEmails", tasks = tasks, completed = completed, deleted = deleted,
            onKindle = l.isLocal == true,
        })
    end
    local deletedLists = {}
    for __, d in ipairs(store.deletedLists and store:deletedLists() or {}) do
        table.insert(deletedLists, { id = d.op.list, title = d.title })
    end
    local options = {}
    for k in pairs(OPTIONS) do options[k] = t:opt(k) end
    -- The sleep screen setting is shared with Home Assistant and Apps.
    if t.sleepSource then options.sleep_screen = t:sleepSource() == "todo" end
    return {
        installed = true, signedIn = t.api:signedIn(), clientId = t.api.clientId or "",
        microsoft = t.api.account ~= nil,
        syncedAt = store:syncedAt(), pending = store:pending(), today = Dates.format(t:today()),
        options = options, lists = lists, deletedLists = deletedLists, homeTiles = (function()
            -- Home's tiles (Today, Agenda...), in order, each shown or not.
            local out, Views = {}, require("todoviews")
            for __, x in ipairs(t.tileSettings and t:tileSettings() or {}) do
                local def = Views.TILES[x.key] or {}
                table.insert(out, { key = x.key, name = def.title or x.key, icon = def.icon, on = x.on })
            end
            return out
        end)(),
    }
end

local function csvField(s)
    s = tostring(s or "")
    if s:find('[,"\n\r]') then s = '"' .. s:gsub('"', '""') .. '"' end
    return s
end

local function csvRows(text)
    local rows, row, field, i, quoted = {}, {}, {}, 1, false
    text = text:gsub("\r\n", "\n")
    while i <= #text do
        local c = text:sub(i, i)
        if quoted then
            if c == '"' then
                if text:sub(i + 1, i + 1) == '"' then table.insert(field, '"') i = i + 1 else quoted = false end
            else
                table.insert(field, c)
            end
        elseif c == '"' then quoted = true
        elseif c == "," then table.insert(row, table.concat(field)) field = {}
        elseif c == "\n" then
            table.insert(row, table.concat(field))
            table.insert(rows, row)
            row, field = {}, {}
        else
            table.insert(field, c)
        end
        i = i + 1
    end
    if #field > 0 or #row > 0 then
        table.insert(row, table.concat(field))
        table.insert(rows, row)
    end
    return rows
end

function Web.routes(server)
    server:route("GET", "^/api/todo$", function(req, res)
        local t = todo()
        if not t then return res:json({ installed = Common.plugin("todo") ~= nil and true or false }) end
        res:json(Web.state(t))
    end)

    -- A date or time in the words of a new task ("Pay rent Friday 9am"), as the
    -- Kindle reads them: { title, due, minute, text } or { none = true }.
    server:route("GET", "^/api/todo/understand$", function(req, res)
        local t = todo()
        local Dates = require("tododates")
        if not (t and Dates.understand) then return res:json({ none = true }) end
        local now = os.date("*t")
        local r = Dates.understand(req.query.text or "", t:today(), now.hour * 60 + now.min, t:opt("week_start") == "monday" and 1 or 0)
        if not r then return res:json({ none = true }) end
        Dates.use24h = function() return not G_reader_settings:isTrue("twelve_hour_clock") end
        local text = "Due " .. Dates.short(r.due) .. (r.minute and (" \u{00B7} Reminder " .. Dates.clock(r.minute)) or "")
        res:json({ title = r.title, due = Dates.format(r.due), minute = r.minute, text = text })
    end)

    -- A change to a task: { op, list, id, ... }.
    server:route("POST", "^/api/todo/task$", function(req, res)
        local t = todo()
        if not t then return res:error(404, "The To Do plugin isn't installed") end
        local Dates = require("tododates")
        local s, b = t.store, req.json()
        local op, list, id = b.op, b.list, b.id
        if op == "add" then
            if type(b.title) ~= "string" or b.title == "" then return res:error(400, "A task needs a title") end
            local fields = { title = b.title, due = Dates.parse(b.due), notes = b.notes ~= "" and b.notes or nil, important = b.important == true }
            -- A reminder time from the words ("9am"), on the due day.
            if tonumber(b.minute) and t.moment then
                fields.due = fields.due or t:today()
                fields.remindAt = t:moment(fields.due, tonumber(b.minute))
            end
            id = s:addTask(list or t:defaultListId(), fields)
            for __, step in ipairs(type(b.steps) == "table" and b.steps or {}) do
                if type(step) == "string" and step ~= "" then s:addStep(list or t:defaultListId(), id, step) end
            end
        elseif op == "done" then s:toggleDone(list, id)
        elseif op == "star" then s:setStar(list, id, b.on == true)
        elseif op == "due" then s:setDue(list, id, Dates.parse(b.due))
        elseif op == "rename" then s:rename(list, id, b.title or "")
        elseif op == "notes" then s:setNotes(list, id, b.notes or "")
        elseif op == "delete" then s:delete(list, id)
        elseif op == "restore" then
            for __, d in ipairs(s:deletedTasks(list)) do
                if d.op.task == id then s:restore(d.op) break end
            end
        elseif op == "move" then s:move(list, id, b.to)
        elseif op == "stepAdd" then s:addStep(list, id, b.title or "")
        elseif op == "stepToggle" then s:toggleStep(list, id, b.step)
        elseif op == "stepRename" then s:renameStep(list, id, b.step, b.title or "")
        elseif op == "stepDelete" then s:deleteStep(list, id, b.step)
        elseif op == "private" then s:setPrivate(id, b.on == true)
        elseif op == "removeRepeat" then s:removeRepeat(list, id, t:today())
        elseif op == "skip" then s:skipToCurrent(list, id, t:today())
        else return res:error(400, "Unknown change") end
        t:changed()
        res:json({ ok = true, id = id })
    end)

    -- A change to a list: { op, id, name, on }.
    server:route("POST", "^/api/todo/list$", function(req, res)
        local t = todo()
        if not t then return res:error(404, "The To Do plugin isn't installed") end
        local s, b = t.store, req.json()
        if b.op == "add" then s:addList(b.name or "", b.onKindle == true or not t.api:signedIn())
        elseif b.op == "toTodo" then
            if not t.api:signedIn() then return res:error(400, "Sign in to To Do first") end
            s:moveListToTodo(b.id)
        elseif b.op == "rename" then s:renameList(b.id, b.name or "")
        elseif b.op == "delete" then s:deleteList(b.id)
        elseif b.op == "restore" then
            for __, d in ipairs(s:deletedLists()) do
                if d.op.list == b.id then s:restore(d.op) break end
            end
        elseif b.op == "hide" then
            local set = t:hiddenSet()
            set[b.id] = b.on and true or nil
            t:setOpt("hidden_lists", set)
        elseif b.op == "pin" then t:setOpt("pinned_list", b.on and b.id ~= "" and b.id or false)
        elseif b.op == "default" then t:setOpt("default_list", b.id)
        else return res:error(400, "Unknown change") end
        t:changed()
        res:json({ ok = true })
    end)

    -- Home's tiles: { tiles = { { key, on } } } in their order.
    server:route("POST", "^/api/todo/tiles$", function(req, res)
        local t = todo()
        if not t then return res:error(404, "The To Do plugin isn't installed") end
        local Views = require("todoviews")
        local list = {}
        for __, x in ipairs(type((req.json() or {}).tiles) == "table" and req.json().tiles or {}) do
            if type(x) == "table" and Views.TILES[x.key] then table.insert(list, { key = x.key, on = x.on ~= false }) end
        end
        t.settings:saveSetting("tiles", list)
        t.settings:flush()
        t:render()
        res:json({ ok = true })
    end)

    -- The lists' order and which show: { lists = { { id, on } } } in their order.
    server:route("POST", "^/api/todo/listorder$", function(req, res)
        local t = todo()
        if not t then return res:error(404, "The To Do plugin isn't installed") end
        local keys, hidden, known = {}, {}, {}
        for __, l in ipairs(t.store:lists()) do known[l.id] = true end
        for __, x in ipairs(type((req.json() or {}).lists) == "table" and req.json().lists or {}) do
            if type(x) == "table" and known[x.id] then
                table.insert(keys, x.id)
                if x.on == false then hidden[x.id] = true end
            end
        end
        t:saveOrder("lists", keys)
        t:setOpt("hidden_lists", hidden)
        t:render()
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/todo/options$", function(req, res)
        local t = todo()
        if not t then return res:error(404, "The To Do plugin isn't installed") end
        for k, v in pairs(Common.pick(req.json(), OPTIONS)) do
            t:setOpt(k, v)
            -- The one sleep screen setting To Do, Home Assistant and Apps share.
            if k == "sleep_screen" then
                if v then G_reader_settings:saveSetting("sleep_screen_app", "todo")
                elseif G_reader_settings:readSetting("sleep_screen_app") == "todo" then G_reader_settings:delSetting("sleep_screen_app") end
                G_reader_settings:flush()
            end
        end
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/todo/clientid$", function(req, res)
        local t = todo()
        if not t then return res:error(404, "The To Do plugin isn't installed") end
        local id = (req.json().id or ""):match("^%s*(.-)%s*$")
        t.settings:saveSetting("client_id", id ~= "" and id or nil)
        t.settings:flush()
        t.api.clientId = t:clientId()
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/todo/signin$", function(req, res)
        local t = todo()
        if not t then return res:error(404, "The To Do plugin isn't installed") end
        if not t.api.clientId then return res:error(400, "Set the app ID first") end
        if signIn then signIn.cancelled = true end
        local state, why = Common.deviceCode(t.api, function()
            t:render()
            t:syncNow()
        end)
        if not state then return res:error(502, "Can't reach Microsoft: " .. why) end
        signIn = state
        res:json(state)
    end)

    server:route("GET", "^/api/todo/signin$", function(req, res)
        res:json(signIn or { status = "none" })
    end)

    server:route("POST", "^/api/todo/signout$", function(req, res)
        local t = todo()
        if not t then return res:error(404, "The To Do plugin isn't installed") end
        t.api:signOut()
        if t.tasksFile and t.openStore then
            t.tasksFile:delSetting("data")
            t.tasksFile:flush()
            t:openStore()
        end
        t:render()
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/todo/sync$", function(req, res)
        local t = todo()
        if not t then return res:error(404, "The To Do plugin isn't installed") end
        if not t.api:signedIn() then return res:error(400, "Sign in first") end
        local b = req.json()
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function() t:syncNow({ downloadOnly = b.downloadOnly == true or nil }) end)
        res:json({ ok = true })
    end)

    -- ?lists=id,id: only those lists (all without it).
    server:route("GET", "^/api/todo/export%.csv$", function(req, res)
        local t = todo()
        if not t then return res:error(404, "The To Do plugin isn't installed") end
        local Dates = require("tododates")
        local only
        if req.query.lists and req.query.lists ~= "" then
            only = {}
            for id in req.query.lists:gmatch("[^,]+") do only[id] = true end
        end
        local out = { "List,Title,Due,Completed,Starred,Notes,Steps" }
        for __, l in ipairs(t:orderedLists(true)) do
          if not only or only[l.id] then
            for __, task in ipairs(l.tasks or {}) do
                local steps = {}
                for __, s in ipairs(task.steps or {}) do table.insert(steps, (s.checked and "[x] " or "") .. s.title) end
                table.insert(out, table.concat({
                    csvField(l.name), csvField(task.title), csvField(task.due and Dates.format(task.due) or ""),
                    task.completed and "yes" or "", task.important and "yes" or "", csvField(task.notes or ""),
                    csvField(table.concat(steps, "; ")),
                }, ","))
            end
          end
        end
        res:send(table.concat(out, "\r\n") .. "\r\n", "text/csv; charset=utf-8",
            { ["Content-Disposition"] = "attachment; filename=\"todo.csv\"" })
    end)

    -- CSV with List, Title, Due, Starred, Notes, Steps (; between steps): each row a new task.
    -- ?into=<list id>: every row into that list. Else ?where=todo or kindle: the lists named
    -- in the file, found or made there (To Do when signed in, else this Kindle).
    server:route("POST", "^/api/todo/import$", function(req, res)
        local t = todo()
        if not t then return res:error(404, "The To Do plugin isn't installed") end
        local Dates = require("tododates")
        local rows = csvRows(req.body or "")
        local head = rows[1] or {}
        local col = {}
        for i, name in ipairs(head) do col[name:lower():gsub("^%s+", ""):gsub("%s+$", "")] = i end
        if not col.title then return res:error(400, "The first row must list the column names (at least Title)") end
        local into = req.query.into ~= "" and req.query.into or nil
        if into and not t.store:findList(into) then return res:error(400, "That list isn't there any more") end
        local onKindle = req.query.where == "kindle" or not t.api:signedIn()
        local byName = {}
        for __, l in ipairs(t.store:lists()) do
            if (l.isLocal == true) == onKindle then byName[l.name:lower()] = l.id end
        end
        local added = 0
        for r = 2, #rows do
            local row = rows[r]
            local function get(name) return col[name] and row[col[name]] or "" end
            local title = get("title")
            if title ~= "" then
                local listName = get("list")
                local listId = into or byName[listName:lower()]
                if not listId then
                    listName = listName ~= "" and listName or "Imported"
                    listId = t.store:addList(listName, onKindle)
                    byName[listName:lower()] = listId
                end
                local starred = get("starred"):lower()
                local id = t.store:addTask(listId, {
                    title = title, due = Dates.parse(get("due")), notes = get("notes") ~= "" and get("notes") or nil,
                    important = starred == "yes" or starred == "true" or starred == "1",
                })
                for step in get("steps"):gmatch("[^;]+") do
                    step = step:match("^%s*(.-)%s*$")
                    if step ~= "" then t.store:addStep(listId, id, step) end
                end
                added = added + 1
            end
        end
        t:changed()
        res:json({ ok = true, added = added })
    end)
end

return Web
