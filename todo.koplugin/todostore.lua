--[[--
The reader's copy of To Do, offline first (as CrossInk keeps it): the lists as
last downloaded, plus a queue of changes made on the reader since. What the
screens show is the download with the queue applied on top, so a change shows
at once and still shows after a download that came before it was sent.

At a sync the queue is sent in order (todosync.lua), then everything is
downloaded again.

Deleted tasks and lists wait (as in CrossInk): their delete stays in the
queue, kept whole, until the next full sync (sending changes right away
leaves them), so they can be put back as they were. The sync then deletes
them in To Do; ones never sent to To Do simply go. Tasks, steps and lists made on the reader have ids like
"new:7" until To Do gives them real ones.

Lists on this Kindle (ids "local:…") are kept apart in data.locals and never
synced: their changes are made straight away, not queued, and their deletes
wait in data.localTrash (the last 30) so they can be put back. A repeating
task in one makes its next one when ticked off, as To Do does for its own.
They show after the To Do lists unless options.showLocal() says no (they are
kept either way).

Plain Lua (no KOReader modules) for the tests.
]]

local Dates = require("tododates")
local Model = require("todomodel")

local Store = {}
Store.__index = Store

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end
Store.copy = copy

--- options: data (as saved before, or nil), save(data) to keep it, now().
function Store.new(options)
    local self = setmetatable({}, Store)
    self.data = options.data or {}
    self.data.lists = self.data.lists or {}
    self.data.queue = self.data.queue or {}
    self.data.seq = self.data.seq or 0
    self.data.private = self.data.private or {}
    self.data.locals = self.data.locals or {}
    self.data.localSeq = self.data.localSeq or 0
    self.data.localTrash = self.data.localTrash or {}
    self.showLocal = options.showLocal or function() return true end
    self.saveFn = options.save or function() end
    self.now = options.now or os.time
    return self
end

function Store:save()
    self.view = nil
    self.saveFn(self.data)
end

function Store:newId()
    self.data.seq = self.data.seq + 1
    return "new:" .. self.data.seq
end

function Store.isNew(id)
    return type(id) == "string" and id:sub(1, 4) == "new:"
end

function Store:newLocalId()
    self.data.localSeq = self.data.localSeq + 1
    return "local:" .. self.data.localSeq
end

--- A list (or task, or step) kept only on this Kindle.
function Store.isLocal(id)
    return type(id) == "string" and id:sub(1, 6) == "local:"
end

-- A new id for something in that list: a local one in a list on this Kindle.
function Store:idFor(listId)
    return Store.isLocal(listId) and self:newLocalId() or self:newId()
end

-- ------------------------------------------------------------------ applying changes

local function findList(lists, id)
    for i, list in ipairs(lists) do
        if list.id == id then return list, i end
    end
end

local function findTask(list, id)
    if not list then return nil end
    for i, task in ipairs(list.tasks) do
        if task.id == id then return task, i end
    end
end

local function findStep(task, id)
    if not task then return nil end
    for i, step in ipairs(task.steps) do
        if step.id == id then return step, i end
    end
end

local function isDelete(op) return op.kind == "delete" or op.kind == "listDelete" end

local Apply = {}

function Apply.add(lists, op)
    local list = findList(lists, op.list)
    if not list then return end
    local t = copy(op.fields)
    t.id = op.id
    t.steps = t.steps or {}
    t.recurring = t.recurrence ~= nil
    table.insert(list.tasks, t)
end

function Apply.done(lists, op)
    local task = findTask(findList(lists, op.list), op.task)
    if task then task.completed = true end
end

function Apply.star(lists, op)
    local task = findTask(findList(lists, op.list), op.task)
    if task then task.important = op.on end
end

function Apply.due(lists, op)
    local task = findTask(findList(lists, op.list), op.task)
    if not task then return end
    task.due = op.day
    if op.remind ~= nil then task.remindAt = op.remind or nil end
end

function Apply.remind(lists, op)
    local task = findTask(findList(lists, op.list), op.task)
    if task then task.remindAt = op.at or nil end
end

function Apply.repeats(lists, op)
    local task = findTask(findList(lists, op.list), op.task)
    if not task then return end
    task.recurrence = copy(op.recurrence)
    task.recurring = true
    task.due = op.day
end

function Apply.norepeat(lists, op)
    local task = findTask(findList(lists, op.list), op.task)
    if not task then return end
    task.recurrence = nil
    task.recurring = false
    task.due = nil
    task.notes = op.notes
end

function Apply.rename(lists, op)
    local task = findTask(findList(lists, op.list), op.task)
    if task then task.title = op.title end
end

function Apply.notes(lists, op)
    local task = findTask(findList(lists, op.list), op.task)
    if task then task.notes = op.text ~= "" and op.text or nil end
end

function Apply.stepAdd(lists, op)
    local task = findTask(findList(lists, op.list), op.task)
    if task then table.insert(task.steps, { id = op.id, title = op.title, checked = false }) end
end

function Apply.stepCheck(lists, op)
    local step = findStep(findTask(findList(lists, op.list), op.task), op.step)
    if step then step.checked = op.on end
end

function Apply.stepRename(lists, op)
    local step = findStep(findTask(findList(lists, op.list), op.task), op.step)
    if step then step.title = op.title end
end

function Apply.stepDelete(lists, op)
    local task = findTask(findList(lists, op.list), op.task)
    local _, i = findStep(task, op.step)
    if i then table.remove(task.steps, i) end
end

function Apply.move(lists, op)
    local from = findList(lists, op.list)
    local to = findList(lists, op.to)
    local task, i = findTask(from, op.task)
    if not task or not to then return end
    table.remove(from.tasks, i)
    local moved = copy(op.copy)
    moved.id = op.id
    table.insert(to.tasks, moved)
end

function Apply.delete(lists, op)
    local list = findList(lists, op.list)
    local _, i = findTask(list, op.task)
    if i then table.remove(list.tasks, i) end
end

function Apply.listAdd(lists, op)
    table.insert(lists, { id = op.id, name = op.name, tasks = {}, isLocal = Store.isLocal(op.id) or nil })
end

function Apply.listRename(lists, op)
    local list = findList(lists, op.list)
    if list then list.name = op.name end
end

function Apply.listDelete(lists, op)
    local _, i = findList(lists, op.list)
    if i then table.remove(lists, i) end
end

--- Applies one change to `lists` (a missing task or list: nothing happens).
function Store.apply(lists, op)
    local fn = Apply[op.kind]
    if fn then fn(lists, op) end
end

-- ------------------------------------------------------------------ reading

--- The lists as the reader shows them: the download with the queue on top.
function Store:lists()
    if not self.view then
        local lists = copy(self.data.lists)
        for _, op in ipairs(self.data.queue) do Store.apply(lists, op) end
        if self.showLocal() then
            -- Ticked off before today: gone from view (as To Do's go at a sync), kept 90 days.
            local now = os.date("*t", self.now())
            local midnight = os.time({ year = now.year, month = now.month, day = now.day, hour = 0 })
            for _, list in ipairs(self.data.locals) do
                local l = copy(list)
                l.tasks = {}
                for _, t in ipairs(list.tasks) do
                    if not (t.completed and t.completedAt and t.completedAt < midnight) then table.insert(l.tasks, copy(t)) end
                end
                table.insert(lists, l)
            end
        end
        self.view = lists
    end
    return self.view
end

function Store:findList(id)
    return (findList(self:lists(), id))
end

function Store:findTask(listId, taskId)
    return (findTask(findList(self:lists(), listId), taskId))
end

function Store:pending()
    return #self.data.queue
end

function Store:syncedAt()
    return self.data.syncedAt
end

-- ------------------------------------------------------------------ changes

--- The lists on this Kindle (shown or not).
function Store:localLists()
    return self.data.locals
end

-- A change to a list on this Kindle: made at once (deletes kept to put back).
local function isLocalOp(op)
    return Store.isLocal(op.list) or (op.kind == "listAdd" and Store.isLocal(op.id))
end

function Store:pushLocal(op)
    local locals = self.data.locals
    if op.kind == "listDelete" then op.copyList = copy(findList(locals, op.list)) end
    Store.apply(locals, op)
    if isDelete(op) then
        table.insert(self.data.localTrash, op)
        while #self.data.localTrash > 30 do table.remove(self.data.localTrash, 1) end
    end
    self:save()
    return op
end

function Store:push(op)
    if isLocalOp(op) then return self:pushLocal(op) end
    table.insert(self.data.queue, op)
    self:save()
    return op
end

-- Finds the task, or nil (the change is then not made).
function Store:task(listId, taskId)
    local task = self:findTask(listId, taskId)
    return task
end

--- A new task in a list. fields: title, due, remindAt, recurrence, important,
-- notes. Returns its id.
function Store:addTask(listId, fields)
    local id = self:idFor(listId)
    self:push({ kind = "add", list = listId, id = id, title = fields.title, fields = copy(fields) })
    return id
end

--- Ticks a task off, or (when it was ticked off on the reader and not sent
-- yet) back on.
function Store:toggleDone(listId, taskId)
    if Store.isLocal(listId) then return self:toggleLocalDone(listId, taskId) end
    local queue = self.data.queue
    for i = #queue, 1, -1 do
        local op = queue[i]
        if op.kind == "done" and op.list == listId and op.task == taskId then
            table.remove(queue, i)
            self:save()
            return false
        end
    end
    local task = self:task(listId, taskId)
    if not task then return nil end
    self:push({ kind = "done", list = listId, task = taskId, title = task.title })
    return true
end

-- On this Kindle: ticked off or back on. A repeating task's next one is
-- made (as To Do makes it), and taken away again if it's ticked back on.
function Store:toggleLocalDone(listId, taskId)
    local list = findList(self.data.locals, listId)
    local task = findTask(list, taskId)
    if not task then return nil end
    if task.completed then
        task.completed, task.completedAt = nil, nil
        local nextTask, i = findTask(list, task.spawned)
        if nextTask and not nextTask.completed then table.remove(list.tasks, i) end
        task.spawned = nil
        self:save()
        return false
    end
    task.completed = true
    task.completedAt = self.now()
    -- Ticked off long ago: forgotten.
    for i = #list.tasks, 1, -1 do
        local t = list.tasks[i]
        if t.completed and t.completedAt and t.completedAt < self.now() - 90 * 86400 then table.remove(list.tasks, i) end
    end
    local day = task.recurrence and task.due and Model.nextOccurrence(task.recurrence, task.due, task.due + 1)
    if day then
        local t = copy(task)
        t.id, t.completed, t.completedAt, t.spawned = self:newLocalId(), nil, nil, nil
        t.due = day
        if task.remindAt then t.remindAt = task.remindAt + (day - task.due) * 86400 end
        for _, step in ipairs(t.steps or {}) do
            step.id, step.checked = self:newLocalId(), false
        end
        table.insert(list.tasks, t)
        task.spawned = t.id
    end
    self:save()
    return true
end

function Store:setStar(listId, taskId, on)
    local task = self:task(listId, taskId)
    if not task then return end
    self:push({ kind = "star", list = listId, task = taskId, on = on, title = task.title })
end

--- A new due date (nil: none). The reminder moves with it, by as many days.
-- For a repeating task To Do is sent the repeat again from the new day.
function Store:setDue(listId, taskId, day)
    local task = self:task(listId, taskId)
    if not task then return end
    local op = { kind = "due", list = listId, task = taskId, day = day, title = task.title,
        recurrence = copy(task.recurrence) }
    if task.remindAt and task.due and day then
        op.remind = task.remindAt + (day - task.due) * 86400
    end
    self:push(op)
end

--- A reminder at `at` (Unix seconds), or none (nil).
function Store:setReminder(listId, taskId, at)
    local task = self:task(listId, taskId)
    if not task then return end
    self:push({ kind = "remind", list = listId, task = taskId, at = at or false, title = task.title })
end

--- A repeat (Model.preset) starting `day` (the task's due date becomes it).
function Store:setRepeat(listId, taskId, recurrence, day)
    local task = self:task(listId, taskId)
    if not task then return end
    self:push({ kind = "repeats", list = listId, task = taskId, recurrence = copy(recurrence), day = day,
        title = task.title, remind = task.remindAt })
end

--- Stops a task repeating: its due date is cleared and a note keeps the old one.
function Store:removeRepeat(listId, taskId, today)
    local task = self:task(listId, taskId)
    if not task then return end
    local note = Model.repeatRemovedNote(task.due, today)
    local notes = task.notes and (task.notes .. "\n\n" .. note) or note
    self:push({ kind = "norepeat", list = listId, task = taskId, notes = notes, title = task.title })
end

--- A repeating task that fell behind: moved to the first day it falls on
-- from `today`. Returns the new day (nil when its repeat has ended).
function Store:skipToCurrent(listId, taskId, today)
    local task = self:task(listId, taskId)
    if not task or not task.recurrence or not task.due then return nil end
    local day = Model.nextOccurrence(task.recurrence, task.due, today)
    if day and day ~= task.due then self:setDue(listId, taskId, day) end
    return day
end

--- Every overdue repeating task skipped to current. Returns how many moved.
function Store:catchUp(today)
    local moved = 0
    for _, list in ipairs(self:lists()) do
        local ids = {}
        for _, task in ipairs(list.tasks) do
            if task.recurrence and task.due and task.due < today and not task.completed then table.insert(ids, task.id) end
        end
        for _, id in ipairs(ids) do
            local before = self:task(list.id, id).due
            local day = self:skipToCurrent(list.id, id, today)
            if day and day ~= before then moved = moved + 1 end
        end
    end
    return moved
end

--- Overdue repeating tasks: { list, task, day (where it would go) }.
function Store:catchUpPreview(today)
    local out = {}
    for _, list in ipairs(self:lists()) do
        for _, task in ipairs(list.tasks) do
            if task.recurrence and task.due and task.due < today and not task.completed then
                table.insert(out, { list = list, task = task, day = Model.nextOccurrence(task.recurrence, task.due, today) })
            end
        end
    end
    return out
end

--- Pushes a task's due date (today when it has none) `days` later.
function Store:pushOff(listId, taskId, days, today)
    local task = self:task(listId, taskId)
    if not task then return end
    self:setDue(listId, taskId, (task.due or today) + days)
end

function Store:rename(listId, taskId, title)
    local task = self:task(listId, taskId)
    if not task or title == "" or title == task.title then return end
    self:push({ kind = "rename", list = listId, task = taskId, title = title, old = task.title })
end

function Store:setNotes(listId, taskId, text)
    local task = self:task(listId, taskId)
    if not task or (text or "") == (task.notes or "") then return end
    self:push({ kind = "notes", list = listId, task = taskId, text = text or "", title = task.title })
end

function Store:addStep(listId, taskId, title)
    local task = self:task(listId, taskId)
    if not task or title == "" then return end
    local id = self:idFor(listId)
    self:push({ kind = "stepAdd", list = listId, task = taskId, id = id, title = title, taskTitle = task.title })
    return id
end

function Store:toggleStep(listId, taskId, stepId)
    local step = findStep(self:task(listId, taskId), stepId)
    if not step then return end
    self:push({ kind = "stepCheck", list = listId, task = taskId, step = stepId, on = not step.checked, title = step.title,
        taskTitle = self:task(listId, taskId).title })
end

function Store:renameStep(listId, taskId, stepId, title)
    local step = findStep(self:task(listId, taskId), stepId)
    if not step or title == "" or title == step.title then return end
    self:push({ kind = "stepRename", list = listId, task = taskId, step = stepId, title = title,
        taskTitle = self:task(listId, taskId).title })
end

function Store:deleteStep(listId, taskId, stepId)
    local step = findStep(self:task(listId, taskId), stepId)
    if not step then return end
    self:push({ kind = "stepDelete", list = listId, task = taskId, step = stepId, title = step.title,
        taskTitle = self:task(listId, taskId).title })
end

--- Moves a task to another list (To Do has no move: it is copied there and
-- deleted here at the sync). Returns its new id.
function Store:move(listId, taskId, toListId)
    local task = self:task(listId, taskId)
    if not task or listId == toListId or not self:findList(toListId) then return nil end
    if Store.isLocal(listId) ~= Store.isLocal(toListId) then return self:moveAcross(listId, task, toListId) end
    local id = self:idFor(toListId)
    local private = self.data.private[taskId]
    self:push({ kind = "move", list = listId, task = taskId, to = toListId, id = id, copy = copy(task), title = task.title })
    if private then self.data.private[id] = true end
    return id
end

-- Between To Do and this Kindle: made new there (with its steps), deleted here.
function Store:moveAcross(listId, task, toListId)
    local private = self.data.private[task.id]
    local fields = copy(task)
    fields.id, fields.steps, fields.spawned, fields.completed = nil, nil, nil, nil
    local id = self:addTask(toListId, fields)
    for _, step in ipairs(task.steps or {}) do
        local sid = self:addStep(toListId, id, step.title)
        if step.checked and sid then self:toggleStep(toListId, id, sid) end
    end
    if task.completed then self:toggleDone(toListId, id) end
    self:delete(listId, task.id)
    if private then
        self.data.private[id] = true
        self:save()
    end
    return id
end

--- A whole list from this Kindle to To Do: a new To Do list of that name
-- with every task (steps, stars, dates, repeats), and the list here deleted
-- (Undo: Deleted lists). Returns the new list's id.
function Store:moveListToTodo(listId)
    local list = findList(self.data.locals, listId)
    if not list then return nil end
    local whole = copy(list)
    local id = self:addList(list.name)
    -- As shown (ones ticked off before today stay behind and go with the list).
    local shown = self:findList(listId) or list
    for _, task in ipairs(copy(shown.tasks)) do self:moveAcross(listId, task, id) end
    -- Under Deleted lists as it was, not task by task.
    local trash = self.data.localTrash
    for i = #trash, 1, -1 do
        if trash[i].kind == "delete" and trash[i].list == listId then table.remove(trash, i) end
    end
    local op = self:deleteList(listId)
    if op then op.copyList = whole end
    self:save()
    return id
end

function Store:delete(listId, taskId)
    local task = self:task(listId, taskId)
    if not task then return end
    return self:push({ kind = "delete", list = listId, task = taskId, title = task.title, copy = copy(task) })
end

-- ------------------------------------------------------------------ deleted, until the next sync

Store.isDelete = isDelete

--- A list's deleted tasks, newest first: { op, title, completed }.
function Store:deletedTasks(listId)
    local out = {}
    local queue = Store.isLocal(listId) and self.data.localTrash or self.data.queue
    for i = #queue, 1, -1 do
        local op = queue[i]
        if op.kind == "delete" and op.list == listId then
            table.insert(out, { op = op, title = op.title or "", completed = op.copy and op.copy.completed or false })
        end
    end
    return out
end

--- A list's done tasks, the latest first: { task }. To Do's go at the next
-- sync (the download has open tasks only); a list on this Kindle keeps them 90 days.
function Store:completedTasks(listId)
    local list = Store.isLocal(listId) and findList(self.data.locals, listId) or self:findList(listId)
    local out = {}
    for _i, t in ipairs(list and list.tasks or {}) do
        if t.completed then table.insert(out, t) end
    end
    table.sort(out, function(a, b) return (a.completedAt or 0) > (b.completedAt or 0) end)
    return out
end

--- Deleted lists, newest first: { op, title }.
function Store:deletedLists()
    local out = {}
    for _, queue in ipairs({ self.data.localTrash, self.data.queue }) do
        for i = #queue, 1, -1 do
            local op = queue[i]
            if op.kind == "listDelete" then table.insert(out, { op = op, title = op.title or "" }) end
        end
    end
    return out
end

--- Puts a deleted task or list back as it was (its delete leaves the queue).
function Store:restore(op)
    for i, o in ipairs(self.data.localTrash) do
        if o == op then
            if op.kind == "listDelete" then
                if not op.copyList then return false end
                table.insert(self.data.locals, copy(op.copyList))
            else
                local list = findList(self.data.locals, op.list)
                if not list or not op.copy then return false end
                local t = copy(op.copy)
                t.id = op.task
                table.insert(list.tasks, t)
            end
            table.remove(self.data.localTrash, i)
            self:save()
            return true
        end
    end
    for i, o in ipairs(self.data.queue) do
        if o == op then
            table.remove(self.data.queue, i)
            self:save()
            return true
        end
    end
    return false
end

--- Before a sync: tasks and lists made on the reader and deleted before they
-- were sent go, with every change to them (a task moved here and then
-- deleted: the move becomes deleting the original). Returns their deletes.
function Store:dropLocalDeleted()
    local queue, gone, dropped = self.data.queue, {}, {}
    for i = #queue, 1, -1 do
        local op = queue[i]
        if (op.kind == "delete" and Store.isNew(op.task)) or (op.kind == "listDelete" and Store.isNew(op.list)) then
            gone[op.kind == "delete" and op.task or op.list] = true
            table.remove(queue, i)
            table.insert(dropped, 1, op)
        end
    end
    if #dropped == 0 then return dropped end
    local changed = true
    while changed do
        changed = false
        for i = #queue, 1, -1 do
            local op = queue[i]
            if op.kind == "move" and gone[op.list] and not gone[op.to] and not gone[op.id] then
                -- Moved out of a list that goes: it is new where it went.
                local fields = copy(op.copy or {})
                fields.steps, fields.id = nil, nil
                queue[i] = { kind = "add", list = op.to, id = op.id, title = op.title, fields = fields }
                changed = true
            elseif op.kind == "move" and (gone[op.id] or gone[op.to]) and not gone[op.task] then
                if Store.isNew(op.task) then
                    -- Never sent: it simply goes, with its own add.
                    gone[op.task] = true
                    table.remove(queue, i)
                else
                    queue[i] = { kind = "delete", list = op.list, task = op.task, title = op.title, copy = op.copy }
                end
                changed = true
            elseif gone[op.id] or gone[op.task] or gone[op.list] then
                if op.id then gone[op.id] = true end
                table.remove(queue, i)
                changed = true
            end
        end
    end
    self:save()
    return dropped
end

--- A new list; `onKindle`: kept on this Kindle only (never synced).
function Store:addList(name, onKindle)
    if name == "" then return end
    local id = onKindle and self:newLocalId() or self:newId()
    self:push({ kind = "listAdd", id = id, name = name, title = name })
    return id
end

function Store:renameList(listId, name)
    local list = self:findList(listId)
    if not list or name == "" or name == list.name then return end
    self:push({ kind = "listRename", list = listId, name = name, title = list.name })
end

function Store:deleteList(listId)
    local list = self:findList(listId)
    if not list then return end
    return self:push({ kind = "listDelete", list = listId, title = list.name })
end

-- Hidden on the sleep screen (kept on the reader only).
function Store:isPrivate(taskId)
    return self.data.private[taskId] == true
end

function Store:setPrivate(taskId, on)
    self.data.private[taskId] = on or nil
    self:save()
end

-- ------------------------------------------------------------------ syncing

local KIND_LABEL = {
    add = "New", done = "Ticked off", star = "Starred", due = "Due date", remind = "Reminder",
    repeats = "Repeat", norepeat = "Repeat removed", rename = "Renamed", notes = "Notes",
    stepAdd = "Step added", stepCheck = "Step ticked", stepRename = "Step renamed", stepDelete = "Step deleted",
    move = "Moved", delete = "Deleted", listAdd = "New list", listRename = "List renamed", listDelete = "List deleted",
}

--- One queued change as text: "Ticked off", "Go for a run".
function Store.describe(op)
    local label = KIND_LABEL[op.kind] or op.kind
    if op.kind == "star" and not op.on then label = "Unstarred" end
    if op.kind == "stepCheck" and not op.on then label = "Step unticked" end
    if op.kind == "due" and not op.day then label = "Due date cleared" end
    local what = op.title or ""
    if op.taskTitle then what = op.taskTitle .. "  ·  " .. what end
    if op.kind == "due" and op.day then what = what .. "  ·  " .. Dates.short(op.day) end
    return label, what
end

--- Counts of the queue for the sync screen: { new, edited, ticked, deleted }.
function Store:counts()
    local c = { new = 0, edited = 0, ticked = 0, deleted = 0 }
    for _, op in ipairs(self.data.queue) do
        if op.kind == "add" or op.kind == "listAdd" then c.new = c.new + 1
        elseif op.kind == "done" then c.ticked = c.ticked + 1
        elseif op.kind == "delete" or op.kind == "listDelete" then c.deleted = c.deleted + 1
        else c.edited = c.edited + 1 end
    end
    return c
end

--- Real ids for ids made on the reader: every later change and the private
-- marks follow.
function Store:remap(map)
    local fields = { "list", "task", "step", "to", "id" }
    for _, op in ipairs(self.data.queue) do
        for _, f in ipairs(fields) do
            if op[f] and map[op[f]] then op[f] = map[op[f]] end
        end
    end
    for old, new in pairs(map) do
        if self.data.private[old] then
            self.data.private[new] = true
            self.data.private[old] = nil
        end
    end
end

--- The first change (or the one at `index`) was sent (with `map`, the real
-- ids it got): it leaves the queue and goes into the download, so the screens
-- stay right if the rest cannot be sent now.
function Store:sent(map, index)
    local op = table.remove(self.data.queue, index or 1)
    if not op then return end
    if map then
        self:remap(map)
        for _, f in ipairs({ "list", "task", "step", "to", "id" }) do
            if op[f] and map[op[f]] then op[f] = map[op[f]] end
        end
    end
    Store.apply(self.data.lists, op)
    self:save()
end

--- The first change (or the one at `index`) could not be sent (To Do refused it): dropped.
function Store:dropFirst(index)
    local op = table.remove(self.data.queue, index or 1)
    self:save()
    return op
end

--- A fresh download replaces the old one (the queue stays on top).
function Store:downloaded(lists)
    self.data.lists = lists
    self.data.syncedAt = self.now()
    -- Private marks for tasks that are gone are forgotten.
    local alive = {}
    for _, list in ipairs(lists) do
        for _, task in ipairs(list.tasks) do alive[task.id] = true end
    end
    for _, op in ipairs(self.data.queue) do
        if op.id then alive[op.id] = true end
    end
    for _, list in ipairs(self.data.locals) do
        for _, task in ipairs(list.tasks) do alive[task.id] = true end
    end
    for id in pairs(self.data.private) do
        if not alive[id] then self.data.private[id] = nil end
    end
    self:save()
end

--- Reset to To Do: the reader's unsent changes are thrown away.
function Store:discardQueue()
    local n = #self.data.queue
    self.data.queue = {}
    self:save()
    return n
end

--- A sync with To Do through `api` (todoapi): the queue sent in order
-- (unless `downloadOnly`), then everything downloaded again. With
-- `sendOnly` (changes sent right away) deletes wait for the next full sync.
-- Returns a report: { sent, dropped = { {op, why} }, deleted = { title... }
-- (tasks and lists deleted for good), stopped (why sending stopped), failed
-- (why the download failed) }.
function Store:sync(api, options)
    options = options or {}
    local report = { sent = 0, dropped = {}, deleted = {}, map = {} }
    if not options.downloadOnly then
        if not options.sendOnly then
            for _, op in ipairs(self:dropLocalDeleted()) do table.insert(report.deleted, op.title or "") end
        end
        local i = 1
        while i <= #self.data.queue do
            local op = self.data.queue[i]
            if options.sendOnly and isDelete(op) then
                i = i + 1
            else
                local result, extra = api:send(op)
                if result == "ok" then
                    for old, new in pairs(type(extra) == "table" and extra or {}) do report.map[old] = new end
                    self:sent(extra, i)
                    report.sent = report.sent + 1
                    if isDelete(op) then table.insert(report.deleted, op.title or "") end
                elseif result == "drop" then
                    self:dropFirst(i)
                    table.insert(report.dropped, { op = op, why = extra })
                else
                    report.stopped = extra or "No connection"
                    break
                end
            end
        end
    end
    if options.sendOnly then return report end
    local lists, why = api:fetchAll(options.offset or 0)
    if lists then
        self:downloaded(lists)
    else
        report.failed = why or "Download failed"
    end
    return report
end

return Store
