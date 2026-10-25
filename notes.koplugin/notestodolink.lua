--[[--
Pages and To Do tasks kept together. A checklist or tasks page added to
To Do remembers which task (or step) each written line became, so a box
ticked on the page ticks the task, a task ticked in To Do is ticked on the
page when it is shown, and To Do can open the page a task came from.
Kept in koreader/settings/notes_todo.lua; To Do's ids made on the Kindle
are followed when a sync gives them their real ones. Mixed into the Notes
plugin (main.lua).

@module koplugin.notes.todolink
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")

return function(Notes)

function Notes:todoLinkFile()
    if not self.todoLinksFile then
        self.todoLinksFile = LuaSettings:open(DataStorage:getSettingsDir() .. "/notes_todo.lua")
    end
    return self.todoLinksFile
end

-- { [key] = { nb, page (page id), line, list, task, step, name } }, key
-- "t:<task>" or "s:<task>:<step>".
function Notes:todoLinks()
    local f = self:todoLinkFile()
    local t = f:readSetting("links")
    if type(t) ~= "table" then
        t = {}
        f:saveSetting("links", t)
    end
    return t
end

function Notes:saveTodoLinks()
    self:todoLinkFile():flush()
end

--- To Do's store gives its own ids for tasks made on the Kindle when they are
-- sent: the links follow them.
function Notes:hookTodo()
    local todo = self:todo()
    local store = todo and todo.store
    if not store or store.notesHooked or type(store.remap) ~= "function" then return end
    store.notesHooked = true
    local remap = store.remap
    store.remap = function(st, map)
        remap(st, map)
        pcall(self.remapTodoLinks, self, map)
    end
end

function Notes:remapTodoLinks(map)
    local links = self:todoLinks()
    local moved = {}
    for key, e in pairs(links) do
        local list, task, step = map[e.list] or e.list, map[e.task] or e.task, e.step and (map[e.step] or e.step)
        if list ~= e.list or task ~= e.task or step ~= e.step then
            e.list, e.task, e.step = list, task, step
            moved[key] = e
        end
    end
    local any = false
    for key, e in pairs(moved) do
        links[key] = nil
        links[e.step and ("s:" .. e.task .. ":" .. e.step) or ("t:" .. e.task)] = e
        any = true
    end
    if any then self:saveTodoLinks() end
end

--- Tasks just added from a page (`ctx` { nb, page, name, lines }, `added`
-- { { task, steps = { step ids } }... } in the tasks' order): each task (and
-- step) linked to the page, and to its line when the lines written match the
-- tasks and steps one for one (subtask lines for steps on the tasks paper).
function Notes:recordTodoLinks(ctx, listId, tasks, added)
    if not ctx or not ctx.nb then return end
    self:hookTodo()
    local flat = {}
    for i, a in ipairs(added) do
        table.insert(flat, { task = a.task, kind = "task" })
        for __, sid in ipairs(a.steps or {}) do
            if sid then table.insert(flat, { task = a.task, step = sid, kind = "sub" }) else flat.bad = true end
        end
        if tasks[i] and #(tasks[i].steps or {}) ~= #(a.steps or {}) then flat.bad = true end
    end
    local lines = ctx.lines
    local matched = lines and not flat.bad and #lines == #flat
    if matched and ctx.paper == "tasks" then
        for i, f in ipairs(flat) do
            if lines[i].kind ~= f.kind then matched = false end
        end
    end
    local links = self:todoLinks()
    for i, f in ipairs(flat) do
        local key = f.step and ("s:" .. f.task .. ":" .. f.step) or ("t:" .. f.task)
        links[key] = { nb = ctx.nb, page = ctx.page, name = ctx.name, list = listId, task = f.task, step = f.step,
            line = matched and lines[i].line or nil }
    end
    self:saveTodoLinks()
end

--- The page a To Do task came from: { id, page (number), name }, or nil.
function Notes:pageForTask(taskId)
    local e = self:todoLinks()["t:" .. tostring(taskId)]
    if not e then return nil end
    local nb = self.store:read(e.nb)
    if not nb then return nil end
    for i, page in ipairs(nb.pages) do
        if page.id == e.page then return { id = nb.id, page = i, name = nb.name } end
    end
    return { id = nb.id, page = 1, name = nb.name }
end

-- The links of one page's lines: { [line] = link }.
function Notes:pageLinks(nbId, pageId)
    local out = {}
    for __, e in pairs(self:todoLinks()) do
        if e.nb == nbId and e.page == pageId and e.line then out[e.line] = e end
    end
    return out
end

--- A box ticked or unticked on a page: its task (or step) ticked in To Do.
-- (To Do can't untick a task once its tick was sent.)
function Notes:onPageTick(nb, pageId, line, on)
    local e = self:pageLinks(nb.id, pageId)[line]
    local todo = e and self:todo()
    if not todo then return end
    self:hookTodo()
    local store = todo.store
    local task = store:task(e.list, e.task)
    if not task then return end
    if e.step then
        for __, st in ipairs(task.steps or {}) do
            if st.id == e.step and (st.checked == true) ~= on then store:toggleStep(e.list, e.task, e.step) end
        end
    elseif (task.completed == true) ~= on then
        store:toggleDone(e.list, e.task)
    end
    pcall(todo.changed, todo)
end

--- A page shown: its boxes ticked as To Do has their tasks.
function Notes:syncPageTicks(editor)
    local paper = editor:paper()
    if paper ~= "checklist" and paper ~= "tasks" then return end
    local page = editor.notebook.pages[editor.page]
    local links = page and self:pageLinks(editor.notebook.id, page.id)
    if not links or next(links) == nil then return end
    local todo = self:todo()
    if not todo then return end
    self:hookTodo()
    UIManager:nextTick(function()
        for line, e in pairs(links) do
            local task = todo.store:task(e.list, e.task)
            if task then
                local on = task.completed == true
                if e.step then
                    on = nil
                    for __, st in ipairs(task.steps or {}) do
                        if st.id == e.step then on = st.checked == true end
                    end
                end
                if on ~= nil then editor:setBoxTicked(line, on) end
            end
        end
    end)
end

end
