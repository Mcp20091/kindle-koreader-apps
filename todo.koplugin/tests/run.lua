-- Plain Lua tests for the parts with no KOReader modules: run from the
-- plugin folder with `luajit tests/run.lua` (or any Lua 5.1+).
package.path = "./?.lua;" .. package.path
local Dates = require("tododates")
local Model = require("todomodel")

local failed, passed = 0, 0
local function check(name, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    end
end

local EDT = -4 * 3600
local d = Dates.parse("2026-10-20")

check("civil round trip", Dates.format(d), "2026-10-20")
check("epoch", Dates.fromCivil(1970, 1, 1), 0)
check("leap day", Dates.format(Dates.fromCivil(2028, 2, 29) + 1), "2028-03-01")
check("weekday", Dates.weekday(d), "Tue")
check("iso seconds", Dates.isoSeconds("1970-01-02T00:00:01.0000000"), 86401)
check("iso utc", Dates.isoUtc(Dates.isoSeconds("2026-10-20T13:30:00")), "2026-10-20T13:30:00")

-- Due dates: the app's local midnight (04:00Z in New York), the API's midnight UTC.
check("due from app", Dates.dueFromGraph({ dateTime = "2026-10-20T04:00:00.0000000", timeZone = "UTC" }, EDT), d)
check("due from api", Dates.dueFromGraph({ dateTime = "2026-10-20T00:00:00.0000000", timeZone = "UTC" }, EDT), d)
check("due east of utc", Dates.dueFromGraph({ dateTime = "2026-10-19T22:00:00.0000000", timeZone = "UTC" }, 2 * 3600), d)
check("due to graph", Dates.dueToGraph(d).dateTime, "2026-10-20T00:00:00")

check("clock", Dates.clock(9 * 60 + 30), "9:30 AM")
check("clock pm", Dates.clock(17 * 60), "5 PM")
check("friendly today", Dates.friendly(d, d), "Today")
check("friendly tomorrow", Dates.friendly(d + 1, d), "Tomorrow")
check("friendly week", Dates.friendly(d + 3, d), "Fri")
check("friendly far", Dates.friendly(d + 30, d), "11/19")

-- A day's tasks by reminder time, untimed last; undated after dated.
local function at(day, h, m) return day * 86400 + (h * 60 + m) * 60 - EDT end
local tasks = {
    { title = "Order groceries", due = d, remindAt = at(d, 18, 0), important = false },
    { title = "Feed the cat", due = d, remindAt = at(d, 9, 30), important = false },
    { title = "No time", due = d, important = false },
    { title = "Undated", important = false },
    { title = "Overdue", due = d - 2, important = false },
}
Model.sort(tasks, EDT, true)
check("sort 1", tasks[1].title, "Overdue")
check("sort 2", tasks[2].title, "Feed the cat")
check("sort 3", tasks[3].title, "Order groceries")
check("sort 4", tasks[4].title, "No time")
check("sort 5", tasks[5].title, "Undated")

local starred = {
    { title = "B late", due = d, remindAt = at(d, 20, 0), important = true },
    { title = "A early", due = d, remindAt = at(d, 8, 0), important = false },
}
Model.sort(starred, EDT, true)
check("starred first", starred[1].title, "B late")
Model.sort(starred, EDT, false)
check("by time without starred first", starred[1].title, "A early")

check("when today", Model.whenText({ due = d, remindAt = at(d, 9, 30) }, d, EDT), "9:30 AM")
check("when overdue", Model.whenText({ due = d - 2 }, d, EDT), "Overdue 10/18")
check("when tomorrow", Model.whenText({ due = d + 1, remindAt = at(d + 1, 17, 0) }, d, EDT), "Tomorrow 5 PM")

-- Graph JSON into a task.
local task = Model.taskFromGraph({
    id = "T1", title = "Feed the cat", importance = "high", status = "notStarted",
    dueDateTime = { dateTime = "2026-10-20T04:00:00.0000000", timeZone = "UTC" },
    isReminderOn = true, reminderDateTime = { dateTime = "2026-10-20T13:30:00.0000000", timeZone = "UTC" },
    recurrence = { pattern = { type = "daily" } },
    body = { content = "  ", contentType = "text" },
    checklistItems = { { id = "C1", displayName = "Step", isChecked = true } },
}, EDT)
check("task due", task.due, d)
check("task reminder minute", Dates.reminderMinute(task, EDT), 9 * 60 + 30)
check("task important", task.important, true)
check("task recurring", task.recurring, true)
check("task empty notes dropped", task.notes, nil)
check("task step", task.steps[1].checked, true)

check("task repeat kept", task.recurrence.pattern.type, "daily")
check("html notes lose tags", Model.taskFromGraph({ id = "h", body = { contentType = "html", content = "<p>Ask&nbsp;Sam</p>" } }, EDT).notes, "Ask Sam\n")

-- The Agenda: overdue, today, then each day of the week; flagged emails and hidden lists left out.
local lists = {
    { id = "T", name = "Tasks", tasks = {
        { id = "a", title = "Clean the filter", due = d - 2, important = false, steps = {} },
        { id = "b", title = "Order groceries", due = d, remindAt = at(d, 18, 0), important = false, steps = {} },
        { id = "c", title = "Call the dentist", due = d + 5, important = true, steps = {} },
        { id = "e", title = "Far off", due = d + 9, important = false, steps = {} },
        { id = "f", title = "Undated", important = true, steps = {} },
    } },
    { id = "F", name = "Flagged", wellknown = "flaggedEmails", tasks = { { id = "m", title = "Mail", due = d, important = false, steps = {} } } },
    { id = "R", name = "Recurring", tasks = {
        { id = "w", title = "Go for a run", due = d, remindAt = at(d, 17, 0), important = false, steps = {},
            recurrence = Model.preset("custom", d, 2, "days"), recurring = true },
        { id = "l", title = "Water the plants", due = d + 3, important = false, steps = {},
            recurrence = Model.preset("monthly", d + 3), recurring = true },
    } },
    { id = "H", name = "Hidden", tasks = { { id = "h", title = "Secret", due = d, important = false, steps = {} } } },
}
local hidden = { H = true }
local sections = Model.agenda(lists, d, EDT, { starredFirst = true, hidden = hidden })
check("agenda sections", #sections, 4)
check("agenda overdue first", sections[1].key, "overdue")
check("agenda today title", sections[2].title, "TODAY  ·  TUE, OCT 20")
check("agenda today by time", sections[2].entries[1].task.title, "Go for a run")
check("agenda today count", #sections[2].entries, 2)
check("agenda next day", sections[3].title, "FRI, OCT 23")
check("agenda leaves out day 10", sections[4].entries[1].task.title, "Call the dentist")
local todayOnly = Model.agenda(lists, d, EDT, { todayOnly = true, hidden = hidden })
check("today view", #todayOnly, 2)

local groups = Model.groupByDue(Model.listEntries(lists[1]), d, EDT, true)
check("groups", #groups, 4)
check("group titles", groups[1].title .. "/" .. groups[4].title, "OVERDUE/NO DUE DATE")
check("starred", #Model.starred(lists), 2)
check("search title", #Model.search(lists, "dentist"), 1)
check("search empty", #Model.search(lists, " "), 0)
local summary = Model.summary(lists, d, { hidden = hidden })
check("summary", summary.today .. "/" .. summary.overdue .. "/" .. summary.week .. "/" .. summary.starred, "2/1/4/2")

local open, overdue, dueToday = Model.counts(lists[1], d)
check("counts", open .. "/" .. overdue .. "/" .. dueToday, "5/1/1")

-- Repeats: how they read, where they fall next.
local sunday = Dates.parse("2026-10-25")
check("repeat daily", Model.repeatText(Model.preset("daily", d)), "Daily")
check("repeat every 2 days", Model.repeatText(Model.preset("custom", d, 2, "days")), "Every 2 days")
check("repeat weekdays", Model.repeatText(Model.preset("weekdays", d)), "Weekdays")
check("repeat weekly", Model.repeatText(Model.preset("weekly", sunday)), "Weekly on Sunday")
check("repeat biweekly", Model.repeatText(Model.preset("biweekly", sunday)), "Every 2 weeks on Sunday")
check("repeat monthly", Model.repeatText(Model.preset("monthly", d + 3)), "Monthly on day 23")
check("repeat yearly", Model.repeatText(Model.preset("yearly", Dates.parse("2026-12-17"))), "Yearly on Dec 17")
check("repeat two days", Model.repeatText({ pattern = { type = "weekly", interval = 1, daysOfWeek = { "monday", "wednesday" } } }), "Weekly on Mon, Wed")
check("frequent", Model.isFrequent(Model.preset("custom", d, 2, "days")), true)
check("not frequent", Model.isFrequent(Model.preset("weekly", d)), false)

local weekly = Model.preset("weekly", sunday - 14)   -- Sundays from Oct 11
check("next weekly", Dates.format(Model.nextOccurrence(weekly, sunday - 14, d)), "2026-10-25")
check("next weekly on the day", Dates.format(Model.nextOccurrence(weekly, sunday - 14, sunday)), "2026-10-25")
local every3 = { pattern = { type = "weekly", interval = 3, daysOfWeek = { "sunday" } } }
check("next every 3 weeks", Dates.format(Model.nextOccurrence(every3, sunday - 7, d)), "2026-11-08")
check("next every 2 days", Dates.format(Model.nextOccurrence(Model.preset("custom", d - 5, 2, "days"), d - 5, d)), "2026-10-21")
check("next monthly", Dates.format(Model.nextOccurrence(Model.preset("monthly", Dates.parse("2026-08-23")), Dates.parse("2026-08-23"), d)), "2026-10-23")
check("next monthly 31st", Dates.format(Model.nextOccurrence(Model.preset("monthly", Dates.parse("2026-10-31")), Dates.parse("2026-10-31"), Dates.parse("2026-11-01"))), "2026-11-30")
check("next yearly", Dates.format(Model.nextOccurrence(Model.preset("yearly", Dates.parse("2025-12-17")), Dates.parse("2025-12-17"), d)), "2026-12-17")
local relative = { pattern = { type = "relativeMonthly", interval = 1, index = "last", daysOfWeek = { "friday" } } }
check("next last friday", Dates.format(Model.nextOccurrence(relative, Dates.parse("2026-09-25"), d)), "2026-10-30")
local ended = Model.preset("daily", d - 10)
ended.range = { type = "endDate", endDate = Dates.format(d - 1) }
check("ended repeat", Model.nextOccurrence(ended, d - 10, d), nil)
check("not behind", Model.nextOccurrence(weekly, sunday + 7, d), sunday + 7)

-- The calendar: dots per day, repeats carried forward, every-day-or-two ones listed once.
local cal = Model.calendar(lists, 2026, 10, d, EDT, { hidden = hidden })
check("calendar today", #cal.days[20], 1)
check("calendar frequent", cal.frequent[1].task.title, "Go for a run")
check("calendar overdue day", #cal.days[18], 1)
local nov = Model.calendar(lists, 2026, 11, d, EDT, { hidden = hidden })
check("calendar repeat next month", nov.days[23] and nov.days[23][1]["repeat"], true)
check("calendar first", Dates.format(cal.first), "2026-10-01")

-- The reader's copy: changes show at once, are queued, and stay on top of a download.
local Store = require("todostore")
local saved
local function freshLists()
    return Store.copy({
        { id = "T", name = "Tasks", tasks = { { id = "t1", title = "Call the dentist", due = d, remindAt = at(d, 9, 0), important = false, steps = {} } } },
        { id = "R", name = "Recurring", tasks = { { id = "r1", title = "Errands", due = sunday, important = false,
            recurrence = Model.preset("weekly", sunday), recurring = true,
            steps = { { id = "s1", title = "Vacuum", checked = false } } } } },
    })
end
local store = Store.new{ data = { lists = freshLists() }, save = function(data) saved = data end, now = function() return 5000 end }
local id = store:addTask("T", { title = "Smoke alarm batteries", due = d + 5 })
check("added shows", store:findTask("T", id).title, "Smoke alarm batteries")
check("queued", store:pending(), 1)
check("saved", saved ~= nil, true)
check("ticked", store:toggleDone("T", "t1"), true)
check("ticked shows", store:findTask("T", "t1").completed, true)
check("unticked before sending", store:toggleDone("T", "t1"), false)
check("untick leaves the queue", store:pending(), 1)
store:setDue("T", "t1", d + 2)
check("reminder moves with the due date", store:findTask("T", "t1").remindAt, at(d + 2, 9, 0))
store:toggleStep("R", "r1", "s1")
check("step ticked", store:findTask("R", "r1").steps[1].checked, true)
local stepId = store:addStep("R", "r1", "Laundry")
check("step added", #store:findTask("R", "r1").steps, 2)
store:renameStep("R", "r1", stepId, "Laundry + towels")
check("step renamed", store:findTask("R", "r1").steps[2].title, "Laundry + towels")
store:setStar("T", "t1", true)
store:setNotes("T", "t1", "Ask about the bill")
check("notes", store:findTask("T", "t1").notes, "Ask about the bill")
check("skip to current", Dates.format(store:skipToCurrent("R", "r1", sunday + 1)), "2026-11-01")
check("skipped shows", store:findTask("R", "r1").due, sunday + 7)
store:pushOff("T", "t1", 7, d)
check("pushed off", store:findTask("T", "t1").due, d + 9)
local moved = store:move("T", id, "R")
check("moved out", store:findTask("T", id), nil)
check("moved in", store:findTask("R", moved).title, "Smoke alarm batteries")
store:setPrivate(moved, true)
check("private", store:isPrivate(moved), true)

-- A download comes in: the unsent changes still show on top.
local again = freshLists()
again[1].tasks[1].title = "Call the dentist (from phone)"
store:downloaded(again)
check("download keeps changes", store:findTask("T", "t1").due, d + 9)
check("download takes new titles", store:findTask("T", "t1").title, "Call the dentist (from phone)")
check("synced at", store:syncedAt(), 5000)
local label, what = Store.describe(store.data.queue[1])
check("describe", label .. ": " .. what, "New: Smoke alarm batteries")
local c = store:counts()
check("counts new/edited", c.new .. "/" .. c.edited, "1/9")

-- Sent: real ids replace the reader's, in later changes and private marks.
store:sent({ [id] = "T-real" })
check("move follows real id", store.data.queue[#store.data.queue - 0].kind == "move" and store.data.queue[#store.data.queue].task, "T-real")
check("sent goes into the download", store.data.lists[1].tasks[2].id, "T-real")
store:sent()
check("next sent", store:pending(), 8)

-- Removing a repeat clears the due date and keeps a note; catch up moves overdue repeats.
local s2 = Store.new{ data = { lists = freshLists() } }
s2:removeRepeat("R", "r1", d)
local r1 = s2:findTask("R", "r1")
check("repeat removed", r1.recurring, false)
check("due cleared", r1.due, nil)
check("note kept", r1.notes, "Original due date was 2026-10-25 and recurrence was removed on 2026-10-20")
local s3 = Store.new{ data = { lists = freshLists() } }
check("catch up preview", #s3:catchUpPreview(sunday + 8), 1)
check("catch up", s3:catchUp(sunday + 8), 1)
check("caught up", Dates.format(s3:findTask("R", "r1").due), "2026-11-08")
check("reset", s3:discardQueue(), 1)
check("reset shows To Do's", s3:findTask("R", "r1").due, sunday)

-- Lists made, renamed, deleted on the reader.
local s4 = Store.new{ data = { lists = freshLists() } }
local listId = s4:addList("Moving")
check("list added", s4:findList(listId).name, "Moving")
s4:renameList("T", "Inbox")
check("list renamed", s4:findList("T").name, "Inbox")
s4:deleteList("R")
check("list deleted", s4:findList("R"), nil)

-- E-ink ghosting: a flash every few screen changes.
local count, flash = Model.flashDue(nil, 1, 6)
check("first change does not flash", flash, false)
for _i = 1, 4 do count, flash = Model.flashDue(count, 1, 6) end
check("five changes do not flash", flash, false)
count, flash = Model.flashDue(count, 1, 6)
check("the sixth flashes", flash, true)
check("and starts again", count, 0)
count, flash = Model.flashDue(0, 2, 3)
count, flash = Model.flashDue(count, 2, 3)
check("screen switches count double", flash, true)
check("every change flashes each time", select(2, Model.flashDue(0, 1, 1)), true)
check("never never flashes", select(2, Model.flashDue(99, 5, 0)), false)

-- Deleted: waits (whole) until the next full sync, can be put back, then goes;
-- tasks and lists never sent to To Do simply go.
do
    local t = Store.new{ data = { lists = freshLists() } }
    t:toggleDone("T", "t1")
    t:delete("T", "t1")
    check("deleted: gone from the list", t:findTask("T", "t1"), nil)
    local del = t:deletedTasks("T")
    check("deleted: waits", #del, 1)
    check("deleted: kept as it was", del[1].completed, true)
    t:restore(del[1].op)
    check("put back", t:findTask("T", "t1") ~= nil, true)
    check("put back as it was (completed)", t:findTask("T", "t1").completed, true)
    check("nothing deleted now", #t:deletedTasks("T"), 0)
    t:deleteList("R")
    check("deleted list waits", #t:deletedLists(), 1)
    t:restore(t:deletedLists()[1].op)
    check("list put back with its tasks", #t:findList("R").tasks, 1)

    -- Sending right away leaves deletes; a full sync sends them and names them.
    local sent = {}
    local api = {
        send = function(_, op) table.insert(sent, op.kind) return "ok" end,
        fetchAll = function() return freshLists() end,
    }
    local u = Store.new{ data = { lists = freshLists() } }
    u:delete("T", "t1")
    u:setStar("R", "r1", true)
    local r = u:sync(api, { sendOnly = true })
    check("send right away: delete waits", table.concat(sent, ","), "star")
    check("send right away: still deleted", #u:deletedTasks("T"), 1)
    r = u:sync(api, {})
    check("full sync sends the delete", table.concat(sent, ","), "star,delete")
    check("full sync names it", r.deleted[1], "Call the dentist")
    check("full sync: forgotten", #u:deletedTasks("T"), 0)

    -- Made on the reader and deleted before a sync: nothing is sent for it.
    sent = {}
    local v = Store.new{ data = { lists = freshLists() } }
    local newId = v:addTask("T", { title = "Scratch" })
    v:rename("T", newId, "Scratch 2")
    v:delete("T", newId)
    local listId = v:addList("Temp")
    v:addTask(listId, { title = "In temp" })
    v:deleteList(listId)
    -- Moved to a new list that is then deleted: the original is deleted.
    local tempId = v:addList("Temp 2")
    v:move("R", "r1", tempId)
    v:deleteList(tempId)
    r = v:sync(api, {})
    check("never sent: nothing sent but the original's delete", table.concat(sent, ","), "delete")
    check("never sent: named too", #r.deleted >= 3, true)
end

-- Review fixes: a task moved out of a deleted new list stays (as new where
-- it went); a new task moved and then deleted sends nothing.
do
    local sent = {}
    local api = {
        send = function(_, op) table.insert(sent, op.kind .. ":" .. tostring(op.list)) return "ok", nil end,
        fetchAll = function() return freshLists() end,
    }
    local w = Store.new{ data = { lists = freshLists() } }
    local shop = w:addList("Shopping")
    local milk = w:addTask(shop, { title = "Milk" })
    w:move(shop, milk, "T")
    w:deleteList(shop)
    check("moved out stays", w:findTask("T", w.data.queue[#w.data.queue - 1].id) ~= nil, true)
    w:sync(api, {})
    check("moved out: sent as new in Tasks", table.concat(sent, ","), "add:T")
    sent = {}
    local x = Store.new{ data = { lists = freshLists() } }
    local id = x:addTask("T", { title = "X" })
    local moved = x:move("T", id, "R")
    x:delete("R", moved)
    x:sync(api, {})
    check("new, moved, deleted: nothing sent", #sent, 0)
end


-- Dates in words: 2026-10-20 is a Tuesday; 10:00 AM now.
do
    local today = Dates.parse("2026-10-20")
    local function u(text, now) return Dates.understand(text, today, now or 600, 0) end
    local r = u("Pay rent Friday 9am")
    check("words: title", r and r.title, "Pay rent")
    check("words: friday", r and Dates.format(r.due), "2026-10-23")
    check("words: 9am", r and r.minute, 540)
    r = u("Call vet tomorrow at 3:30pm")
    check("words: tomorrow", r and Dates.format(r.due), "2026-10-21")
    check("words: 3:30pm", r and r.minute, 930)
    check("words: title without at", r and r.title, "Call vet")
    r = u("Dentist on Oct 24")
    check("words: oct 24", r and Dates.format(r.due), "2026-10-24")
    check("words: title without on", r and r.title, "Dentist")
    r = u("Renew passport 1/15")
    check("words: next year", r and Dates.format(r.due), "2027-01-15")
    r = u("Taxes 4/15/2027 noon")
    check("words: full date", r and Dates.format(r.due), "2027-04-15")
    check("words: noon", r and r.minute, 720)
    r = u("Water plants in 3 days")
    check("words: in 3 days", r and Dates.format(r.due), "2026-10-23")
    r = u("Plan trip next week")
    check("words: next week (Sunday)", r and Dates.format(r.due), "2026-10-25")
    r = u("Gym next tuesday")
    check("words: next tuesday", r and Dates.format(r.due), "2026-10-27")
    r = u("Gym tuesday")
    check("words: tuesday is today", r and Dates.format(r.due), "2026-10-20")
    r = u("Call mom 9am")
    check("words: past time is tomorrow", r and Dates.format(r.due), "2026-10-21")
    r = u("Call mom 5pm")
    check("words: time later today", r and Dates.format(r.due), "2026-10-20")
    r = u("Party 24th October")
    check("words: 24th october", r and Dates.format(r.due), "2026-10-24")
    check("words: nothing", u("Buy milk"), nil)
    check("words: may as a verb", u("I may buy milk"), nil)
    check("words: only a date", u("tomorrow"), nil)
end
-- Lists on this Kindle: changed at once, never queued, repeats made here, kept apart from a download.
do
    local showLocal = true
    local ls = Store.new{ data = { lists = freshLists() }, save = function() end, now = function() return 5000 end,
        showLocal = function() return showLocal end }
    local L = ls:addList("Groceries", true)
    check("local list: id", Store.isLocal(L), true)
    check("local list: not queued", ls:pending(), 0)
    check("local list: shows", ls:findList(L).name, "Groceries")
    local milk = ls:addTask(L, { title = "Milk", important = true })
    check("local task: not queued", ls:pending(), 0)
    check("local task: shows", ls:findTask(L, milk).title, "Milk")
    local trash = ls:addTask(L, { title = "Take out the trash", due = sunday, recurrence = Model.preset("weekly", sunday) })
    local step = ls:addStep(L, trash, "Recycling")
    check("local step: local id", Store.isLocal(step), true)
    ls:toggleStep(L, trash, step)
    check("local repeat: ticked", ls:toggleDone(L, trash), true)
    local nextOne
    for _, t in ipairs(ls:findList(L).tasks) do
        if t.title == "Take out the trash" and not t.completed then nextOne = t end
    end
    check("local repeat: next one made", nextOne and Dates.format(nextOne.due), Dates.format(sunday + 7))
    check("local repeat: its steps unticked", nextOne and nextOne.steps[1].checked, false)
    check("local done: shows today", ls:findTask(L, trash).completed, true)
    check("local repeat: unticked", ls:toggleDone(L, trash), false)
    check("local repeat: next one taken back", #ls:findList(L).tasks, 2)
    local op = ls:delete(L, milk)
    check("local delete: gone", ls:findTask(L, milk), nil)
    check("local delete: under Deleted", #ls:deletedTasks(L), 1)
    check("local delete: put back", ls:restore(op), true)
    check("local delete: back", ls:findTask(L, milk).title, "Milk")
    check("local delete: not queued", ls:pending(), 0)
    -- To To Do: queued as new there (with its steps), gone here.
    local moved = ls:move(L, trash, "T")
    check("move to To Do: there", ls:findTask("T", moved).title, "Take out the trash")
    check("move to To Do: gone here", ls:findTask(L, trash), nil)
    check("move to To Do: queued (task, step, its tick)", ls:pending(), 3)
    check("move to To Do: step went", ls:findTask("T", moved).steps[1].checked, true)
    -- And back.
    local back = ls:move("T", "t1", L)
    check("move from To Do: here", ls:findTask(L, back).title, "Call the dentist")
    check("move from To Do: deleted there (queued)", ls:pending(), 4)
    -- A download leaves them alone; hidden when turned off, still kept.
    ls:downloaded(freshLists())
    check("download keeps local lists", ls:findList(L).name, "Groceries")
    showLocal = false
    ls:save()
    check("turned off: hidden", ls:findList(L), nil)
    check("turned off: kept", #ls:localLists(), 1)
    showLocal = true
    ls:save()
    -- Ticked off yesterday: gone from view, still kept.
    local old = ls:addTask(L, { title = "Old chore" })
    ls:toggleDone(L, old)
    ls.data.locals[1].tasks[#ls.data.locals[1].tasks].completedAt = 5000 - 2 * 86400
    ls:save()
    check("local done yesterday: hidden", ls:findTask(L, old), nil)
    check("local done yesterday: under Completed", ls:completedTasks(L)[1].title, "Old chore")
    check("local done yesterday: Completed has it only", #ls:completedTasks(L), 1)
    ls:toggleDone(L, old)
    check("Not done: out of Completed", #ls:completedTasks(L), 0)
    check("Not done: back in the list", ls:findTask(L, old).completed, nil)
    ls:toggleDone(L, old)
    ls.data.locals[1].tasks[#ls.data.locals[1].tasks].completedAt = 5000 - 2 * 86400
    ls:save()
    -- A whole list to To Do.
    local newList = ls:moveListToTodo(L)
    check("list to To Do: new list", ls:findList(newList).name, "Groceries")
    check("list to To Do: its tasks", #ls:findList(newList).tasks, 2)
    check("list to To Do: local list gone", ls:findList(L), nil)
    check("list to To Do: put back", ls:restore(ls:deletedLists()[1].op), true)
    check("list to To Do: put back whole", #ls:localLists()[1].tasks, 3)
end
-- The connection test: Microsoft's sign-in server, then To Do (signed in).
do
    local Api = require("todoapi")
    local tick = 0
    local clock = function() tick = tick + 0.5 return tick end
    local store = { refresh_token = "R", access_token = "A", expires_at = 10 ^ 10 }
    local function api(handler)
        return Api.new{ settings = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end, save = function() end },
            clientId = "C", request = handler, json = { decode = function(b) return b:find("invalid_grant") and { error = "invalid_grant" } or {} end, encode = function() return "" end }, now = function() return 1000 end }
    end
    local rows = api(function(method, url)
        if url:find("openid%-configuration") then return 200, "{}" end
        if url:find("/me/todo/lists") then return 200, '{"value":[]}' end
    end):testConnection(clock)
    check("test: two rows", #rows, 2)
    check("test: sign-in server", rows[1].ok and rows[1].ms, 500)
    check("test: To Do works", rows[2].kind, "ok")
    rows = api(function(method, url)
        if url:find("openid%-configuration") then return 200, "{}" end
        if url:find("/token$") then return 400, '{"error":"invalid_grant"}' end
        return 401, ""
    end):testConnection(clock)
    check("test: sign-in ran out", rows[2].kind, "signin")
    check("test: signed out by Microsoft", store.refresh_token, nil)
    store.refresh_token = "R"
    rows = api(function() return "timeout" end):testConnection(clock)
    check("test: no network", rows[1].kind .. " " .. rows[2].kind, "unreachable unreachable")
end

-- Calendar events (CalDAV): the iCal parser, durations, repeats and the month merge.
do
    local Cal = require("todocaldav")

    check("base64", Cal.base64("user:pass"), "dXNlcjpwYXNz")
    check("base64 one byte", Cal.base64("a"), "YQ==")
    check("base64 two bytes", Cal.base64("ab"), "YWI=")
    check("unfold single lines", Cal.unfold("A:1\r\nB:2"), "A:1\r\nB:2")
    -- A fold is a line break and one space or tab, which are not part of the text (RFC 5545).
    check("unfold folded line", Cal.unfold("SUMMARY:Hello\r\n  world\n\t again"), "SUMMARY:Hello world again")
    check("unfold inside a word", Cal.unfold("DESCRIPTION:This is a l\r\n ong description"), "DESCRIPTION:This is a long description")

    check("duration minutes", Cal.parseDuration("PT45M"), 45 * 60)
    check("duration hours and minutes", Cal.parseDuration("PT2H30M"), 2 * 3600 + 30 * 60)
    check("duration day", Cal.parseDuration("P1D"), 86400)
    check("duration day and time", Cal.parseDuration("P1DT2H30M"), 86400 + 2 * 3600 + 30 * 60)
    check("duration weeks", Cal.parseDuration("P2W"), 2 * 7 * 86400)
    check("duration none", Cal.parseDuration("P"), nil)

    -- The parser: an event, its double (first kept), a cancelled one, an alarm inside.
    local events = Cal.parseIcs(table.concat({
        "BEGIN:VCALENDAR",
        "BEGIN:VEVENT",
        "UID:evt-1",
        "SUMMARY:Team call\\, weekly notes",
        "DTSTART:20261020T090000Z",
        "DTEND:20261020T100000Z",
        "LOCATION:Study",
        "DESCRIPTION:Bring notes\\nAnd the book",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:evt-1",
        "SUMMARY:Team call moved",
        "DTSTART:20261021T090000Z",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:evt-2",
        "SUMMARY:Trip",
        "DTSTART;VALUE=DATE:20261024",
        "DTEND;VALUE=DATE:20261026",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:evt-3",
        "SUMMARY:Postponed",
        "STATUS:CANCELLED",
        "DTSTART:20261022T090000Z",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:evt-4",
        "SUMMARY:With an alarm",
        "DTSTART:20261023T140000Z",
        "BEGIN:VALARM",
        "ACTION:DISPLAY",
        "TRIGGER:-PT10M",
        "END:VALARM",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:evt-5",
        "SUMMARY:Yoga",
        "DTSTART:20261020T180000Z",
        "RRULE:FREQ=DAILY",
        "END:VEVENT",
        "END:VCALENDAR",
    }, "\r\n"), EDT)
    check("events count", #events, 4)
    check("event title", events[1].title, "Team call, weekly notes")
    check("event starts", events[1].starts, Dates.parse("2026-10-20") * 86400 + 9 * 3600)
    check("event ends", events[1].ends, Dates.parse("2026-10-20") * 86400 + 10 * 3600)
    check("event location", events[1].location, "Study")
    check("event notes", events[1].notes, "Bring notes\nAnd the book")
    check("all-day day", events[2].day, Dates.parse("2026-10-24"))
    check("all-day days", events[2].days, 2)
    check("alarm left out", events[3].starts, Dates.parse("2026-10-23") * 86400 + 14 * 3600)
    check("alarm not repeated", events[3].rrule, nil)
    check("repeat kept", events[4].rrule.freq, "DAILY")

    -- A time without a zone follows the Kindle's clock.
    local localEv = Cal.parseIcs("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:l1\r\nSUMMARY:Local time\r\n"
        .. "DTSTART:20261020T090000\r\nEND:VEVENT\r\nEND:VCALENDAR", EDT)[1]
    check("local time in utc", localEv.starts, Dates.parse("2026-10-20") * 86400 + 13 * 3600)
    check("local time minute", Cal.occurrences(localEv, Dates.parse("2026-10-20"), Dates.parse("2026-10-20"), EDT)[1].minute, 9 * 60)

    -- Repeats: a weekly BYDAY series with COUNT, a daily one with UNTIL, monthly on the 31st.
    local weekly = Cal.parseIcs("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:r1\r\nSUMMARY:Club night\r\n"
        .. "DTSTART:20261006T200000\r\nRRULE:FREQ=WEEKLY;BYDAY=TU,TH;COUNT=6\r\nEND:VEVENT\r\nEND:VCALENDAR", EDT)[1]
    check("rrule kept", weekly.rrule.freq .. "," .. weekly.rrule.interval .. "," .. table.concat(weekly.rrule.byday, ","), "WEEKLY,1,TU,TH")
    local occ = Cal.occurrences(weekly, Dates.parse("2026-10-20"), Dates.parse("2026-10-31"), EDT)
    check("weekly in window", #occ, 2)
    check("weekly days", Dates.format(occ[1].day) .. "," .. Dates.format(occ[2].day), "2026-10-20,2026-10-22")
    check("weekly minute", occ[1].minute, 20 * 60)
    -- The series began on Oct 6, so both days in the window are later ones.
    check("weekly occurrences marked", occ[1]["repeat"] and occ[2]["repeat"], true)

    local daily = Cal.parseIcs("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:r2\r\nSUMMARY:Pills\r\n"
        .. "DTSTART;VALUE=DATE:20261018\r\nRRULE:FREQ=DAILY;UNTIL=20261023\r\nEND:VEVENT\r\nEND:VCALENDAR", EDT)[1]
    occ = Cal.occurrences(daily, Dates.parse("2026-10-01"), Dates.parse("2026-10-31"), EDT)
    check("daily until count", #occ, 6)
    check("daily until first", Dates.format(occ[1].day), "2026-10-18")
    check("daily until last", Dates.format(occ[6].day), "2026-10-23")
    check("daily is all-day", occ[1].minute, nil)

    local monthly = Cal.parseIcs("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:r3\r\nSUMMARY:Rent day\r\n"
        .. "DTSTART;VALUE=DATE:20260131\r\nRRULE:FREQ=MONTHLY\r\nEND:VEVENT\r\nEND:VCALENDAR", EDT)[1]
    occ = Cal.occurrences(monthly, Dates.parse("2026-10-01"), Dates.parse("2026-11-30"), EDT)
    check("monthly october", Dates.format(occ[1].day), "2026-10-31")
    check("monthly short month", Dates.format(occ[2].day), "2026-11-30")

    local biweekly = Cal.parseIcs("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:r4\r\nSUMMARY:Standup\r\n"
        .. "DTSTART:20261001T090000\r\nRRULE:FREQ=WEEKLY;INTERVAL=2\r\nEND:VEVENT\r\nEND:VCALENDAR", EDT)[1]
    occ = Cal.occurrences(biweekly, Dates.parse("2026-10-01"), Dates.parse("2026-10-31"), EDT)
    check("biweekly count", #occ, 3)
    check("biweekly last", Dates.format(occ[3].day), "2026-10-29")

    -- The calendar shows an event after the day's tasks, every day it spans.
    local cal = Model.calendar(lists, 2026, 10, d, EDT, { hidden = hidden, events = events })
    check("calendar task first", cal.days[20][1].task ~= nil, true)
    check("calendar event after", cal.days[20][2].event.title, "Team call, weekly notes")
    check("calendar event minute", cal.days[20][2].minute, 5 * 60)
    check("calendar event sorted", cal.days[20][3].event.title, "Yoga")
    check("calendar all-day", cal.days[24][1].event.title, "Trip")
    check("calendar all-day second day", cal.days[25][2].event.title, "Trip")
    check("calendar repeat event marked", cal.days[22][1]["repeat"], true)
    check("calendar first day plain", cal.days[20][3]["repeat"], nil)
    check("calendar without events", Model.calendar(lists, 2026, 10, d, EDT, { hidden = hidden }).days[20][2], nil)

    -- The REPORT body, and the calendars inside its answer.
    local body = Cal.queryBody(Dates.parse("2026-10-20") * 86400, Dates.parse("2026-11-20") * 86400)
    check("report asks for events", body:find("calendar-query", 1, true) ~= nil, true)
    check("report window start", body:find("start=\"20261020T000000Z\"", 1, true) ~= nil, true)
    check("report window end", body:find("end=\"20261120T000000Z\"", 1, true) ~= nil, true)
    check("report without window", Cal.queryBody():find("time-range", 1, true), nil)
    local xml = "<D:multistatus><D:response><D:href>/cal/1.ics</D:href><D:propstat><D:prop>"
        .. "<C:calendar-data>BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x1\r\n"
        .. "SUMMARY:From the report &amp; more\r\nDTSTART:20261020T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR"
        .. "</C:calendar-data></D:prop></D:propstat></D:response></D:multistatus>"
    local chunks = Cal.extractCalendarData(xml)
    check("report one calendar", #chunks, 1)
    local fromXml = Cal.parseIcs(chunks[1], EDT)
    check("report unescaped", fromXml[1].title, "From the report & more")

    -- The address, the sign-in and the fetching: a GET first, a REPORT when the GET isn't a calendar.
    local cfg = { caldav_url = "caldav.example.com", caldav_calendar = "/user/calendar/", caldav_user = "sam", caldav_pass = "book" }
    local function cal(handler)
        return Cal.new{ settings = { get = function(k) return cfg[k] end }, request = handler }
    end
    local good = cal(function() end)
    check("address joined", good:calendarUrl(), "http://caldav.example.com/user/calendar")
    check("configured", good:configured(), true)
    check("auth header", good:authHeader(), "Basic " .. Cal.base64("sam:book"))

    local ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:s1\r\nSUMMARY:From the server\r\n"
        .. "DTSTART:20261020T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR"
    local calls = {}
    local report = cal(function(method, url, headers, body)
        table.insert(calls, { method = method, url = url, auth = headers and headers.Authorization, body = body })
        if method == "REPORT" then return 207, "<C:calendar-data>" .. ics .. "</C:calendar-data>" end
        return 404, "no calendar here"
    end)
    local got, why = report:fetch(Dates.parse("2026-10-20") * 86400, Dates.parse("2026-11-20") * 86400, EDT)
    check("fetch via report", got and #got, 1)
    check("fetch event", got[1].title, "From the server")
    check("fetch get tried first", calls[1].method, "GET")
    check("fetch report second", calls[2].method, "REPORT")
    check("fetch report address", calls[2].url, "http://caldav.example.com/user/calendar")
    check("fetch sign-in sent", calls[1].auth ~= nil, true)
    check("fetch report window", calls[2].body:find("time-range", 1, true) ~= nil, true)

    calls = {}
    local whole = cal(function(method, __, headers)
        table.insert(calls, { method = method, auth = headers and headers.Authorization })
        if method == "GET" then return 200, ics end
        return 500, ""
    end)
    got = whole:fetch(nil, nil, EDT)
    check("fetch whole by get", #got, 1)
    check("fetch get once", #calls, 1)

    local dead = cal(function() return "timeout" end)
    got, why = dead:fetch()
    check("fetch no connection", got, nil)
    check("fetch no connection why", why, "No connection: timeout")
    local refused = cal(function() return 403, "" end)
    __, why = refused:fetch()
    check("fetch refused", why, "HTTP 403")
    local unset = Cal.new{ settings = { get = function() return nil end } }
    check("fetch no address", unset:fetch(), nil)
    check("not configured", unset:configured(), false)

    local tick = 0
    local clock = function() tick = tick + 0.5 return tick end
    local rows = whole:testConnection(clock)
    check("test: one row", #rows, 1)
    check("test: works", rows[1].kind, "ok")
    check("test: server named", rows[1].detail, "caldav.example.com")
    rows = dead:testConnection(clock)
    check("test: unreachable", rows[1].kind, "unreachable")
end

-- The write side of the calendar (CalDAV): an event built as iCal reads back
-- the same, the queue of changes on the fetched events, and the sending.
do
    local Cal = require("todocaldav")

    -- A timed event with everything in it, built and parsed back.
    local ev = {
        uid = "kindle-1", title = "Dentist, Dr. Ah\\; well",
        starts = d * 86400 + 9 * 3600, ends = d * 86400 + 10 * 3600,
        location = "High St. 12", notes = "Bring the card\nand the book",
    }
    local ics = Cal.buildIcs(ev, d * 86400)
    check("ics has uid", ics:find("UID:kindle-1", 1, true) ~= nil, true)
    check("ics dtstamp", ics:find("DTSTAMP:20261020T000000Z", 1, true) ~= nil, true)
    check("ics dtstart utc", ics:find("DTSTART:20261020T090000Z", 1, true) ~= nil, true)
    check("ics dtend utc", ics:find("DTEND:20261020T100000Z", 1, true) ~= nil, true)
    -- The comma, the semicolon and the backslash iCal wants escaped.
    check("ics escapes title", ics:find("SUMMARY:Dentist\\, Dr. Ah\\\\\\; well\r\n", 1, true) ~= nil, true)
    check("ics escapes notes", ics:find("DESCRIPTION:Bring the card\\nand the book\r\n", 1, true) ~= nil, true)
    local back = Cal.parseIcs(ics, EDT)[1]
    check("round trip uid", back.uid, "kindle-1")
    check("round trip title", back.title, ev.title)
    check("round trip starts", back.starts, ev.starts)
    check("round trip ends", back.ends, ev.ends)
    check("round trip location", back.location, ev.location)
    check("round trip notes", back.notes, ev.notes)

    -- An all-day one over two days, and one with no end (an hour long then).
    local back2 = Cal.parseIcs(Cal.buildIcs({ uid = "kindle-2", title = "Trip", allDay = true, day = d, days = 2 },
        d * 86400), EDT)[1]
    check("round trip all day", back2.allDay, true)
    check("round trip day", back2.day, d)
    check("round trip days", back2.days, 2)
    local ics3 = Cal.buildIcs({ uid = "kindle-3", title = "Open end", starts = d * 86400 }, d * 86400)
    check("ics end an hour on", ics3:find("DTEND:20261020T010000Z", 1, true) ~= nil, true)
    check("ics leaves out what is not there", ics3:find("LOCATION", 1, true), nil)

    -- A repeat goes back as the server wrote it.
    local ics4 = Cal.buildIcs({ uid = "kindle-4", title = "Club night", starts = d * 86400,
        rruleRaw = "FREQ=WEEKLY;BYDAY=TU,TH;COUNT=6" }, d * 86400)
    check("ics rrule", ics4:find("RRULE:FREQ=WEEKLY;BYDAY=TU,TH;COUNT=6", 1, true) ~= nil, true)
    local back4 = Cal.parseIcs(ics4, EDT)[1]
    check("round trip rrule raw", back4.rruleRaw, "FREQ=WEEKLY;BYDAY=TU,TH;COUNT=6")
    check("round trip rrule", back4.rrule.freq, "WEEKLY")

    -- The day's events (what the launcher and the sleep screens show):
    -- all-day first, then by start time, repeats included.
    local days = {
        { uid = "e-all", title = "Trip", allDay = true, day = d, days = 1 },
        { uid = "e-late", title = "Dinner", starts = d * 86400 + 23 * 3600 },
        { uid = "e-early", title = "Dentist", starts = d * 86400 + 9 * 3600 },
        { uid = "e-daily", title = "Standup", starts = (d - 1) * 86400 + 15 * 3600,
            rrule = Cal.parseRrule("FREQ=DAILY;COUNT=5") },
    }
    local todaysEvents = Cal.dayEvents(days, d, EDT)
    check("day events count", #todaysEvents, 4)
    check("all day first", todaysEvents[1].event.title, "Trip")
    check("all day no minute", todaysEvents[1].minute, nil)
    check("all day day", todaysEvents[1].day, d)
    check("timed minute local", todaysEvents[2].minute, 5 * 60)
    check("timed title", todaysEvents[2].event.title, "Dentist")
    check("repeat marked", todaysEvents[3]["repeat"], true)
    check("repeat title", todaysEvents[3].event.title, "Standup")
    check("nothing another day", #Cal.dayEvents(days, d + 9, EDT), 0)

    -- A UID for events made here, and the address one is kept at.
    local uid = Cal.newUid(d * 86400, 3)
    check("uid made", uid:match("^kindle%-%d+%-%x%x%x%x%x%x%x%x%-%x%x%x%x$") ~= nil, true)
    check("uid unique", Cal.newUid(1, 1) ~= Cal.newUid(1, 1), true)

    local cfg = { caldav_url = "caldav.example.com", caldav_calendar = "/user/calendar/", caldav_user = "sam", caldav_pass = "book" }
    local function cal(handler)
        return Cal.new{ settings = { get = function(k) return cfg[k] end }, request = handler }
    end
    local good = cal(function() end)
    check("event url made", good:eventUrl({ uid = "kindle-1" }), "http://caldav.example.com/user/calendar/kindle-1.ics")
    check("event url from the server", good:eventUrl({ href = "/cal/user/calendar/e1.ics", uid = "kindle-1" }),
        "http://caldav.example.com/cal/user/calendar/e1.ics")
    check("event url whole", good:eventUrl({ href = "https://dav.example.org/cal/e2.ics" }),
        "https://dav.example.org/cal/e2.ics")
    local unset = Cal.new{ settings = { get = function() return nil end } }
    check("event url unset", unset:eventUrl({ uid = "kindle-1" }), nil)

    -- The queue on the fetched events: added, changed in place, taken away.
    local fetched = {
        { uid = "srv-1", title = "From the server" },
        { uid = "srv-2", title = "Trip" },
        { title = "No uid", href = "/cal/n.ics" },
    }
    local queue = {
        { kind = "put", event = { uid = "kindle-9", title = "Added here" } },
        { kind = "put", event = { uid = "srv-1", title = "Changed here" } },
        { kind = "delete", event = { uid = "srv-2" } },
        { kind = "delete", event = { href = "/cal/n.ics" } },
    }
    local shown = Cal.applyQueue(fetched, queue)
    check("queue count", #shown, 2)
    check("queue changed in place", shown[1].title, "Changed here")
    check("queue added", shown[2].title, "Added here")
    check("queue leaves the fetched ones", fetched[1].title, "From the server")
    check("queue empty", #Cal.applyQueue(fetched, {}), 3)

    -- The sending: PUT with the iCal, DELETE without; the queue stops at the
    -- first one that fails (the rest stays queued).
    local calls
    local function sender(statuses)
        local i = 0
        return cal(function(method, url, headers, body)
            i = i + 1
            table.insert(calls, { method = method, url = url, headers = headers, body = body,
                auth = headers and headers.Authorization })
            return statuses[i]
        end)
    end
    local toSend = {
        { kind = "put", event = { uid = "kindle-1", title = "Dentist",
            starts = d * 86400 + 9 * 3600, ends = d * 86400 + 10 * 3600 } },
        { kind = "delete", event = { uid = "srv-2", href = "/cal/t.ics", title = "Trip" } },
    }
    calls = {}
    local report = sender({ 201, 204 }):pushQueue(toSend, d * 86400)
    check("push sent", report.sent, 2)
    check("push put first", calls[1].method, "PUT")
    check("push put address", calls[1].url, "http://caldav.example.com/user/calendar/kindle-1.ics")
    check("push put iCal", calls[1].body:find("BEGIN:VEVENT", 1, true) ~= nil, true)
    check("push put sign-in", calls[1].auth ~= nil, true)
    check("push put content type", calls[1].headers["Content-Type"], "text/calendar; charset=utf-8")
    check("push delete second", calls[2].method, "DELETE")
    check("push delete address", calls[2].url, "http://caldav.example.com/cal/t.ics")
    check("push delete no body", calls[2].body, nil)
    check("push no stop", report.stopped, nil)

    calls = {}
    report = sender({ 201, "timeout" }):pushQueue(toSend, d * 86400)
    check("push stops on no connection", report.sent, 1)
    check("push says why", report.stopped, "No connection: timeout")
    report = sender({ 403 }):pushQueue(toSend, d * 86400)
    check("push stops refused", report.sent, 0)
    check("push refused why", report.stopped, "HTTP 403")
    report = sender({ 404 }):pushQueue({ { kind = "delete", event = { uid = "gone" } } }, d * 86400)
    check("push delete gone counts", report.sent, 1)
    report = sender({ 404 }):pushQueue({ { kind = "put", event = { uid = "x", starts = d * 86400 } } }, d * 86400)
    check("push put refused stays queued", report.sent, 0)
    check("push put refused why", report.stopped, "HTTP 404")
    report = sender({}):pushQueue({ { kind = "put", event = { uid = "x" } } }, d * 86400)
    check("push put with no time stays queued", report.sent, 0)
    check("push no time why", report.stopped, "The event has no time")
    report = sender({}):pushQueue({}, d * 86400)
    check("push nothing queued", report.sent, 0)
end

do
    -- Skip to current: offered only when it moves the task (a repeating task that's overdue).
    local rec = Model.preset("custom", 100, 1, "days")
    check("skip: overdue repeating task", Model.canSkip({ recurring = true, recurrence = rec, due = 98 }, 100), true)
    check("skip: due today is already current", Model.canSkip({ recurring = true, recurrence = rec, due = 100 }, 100), false)
    check("skip: due later is already current", Model.canSkip({ recurring = true, recurrence = rec, due = 104 }, 100), false)
    check("skip: no date, nothing to skip", Model.canSkip({ recurring = true, recurrence = rec }, 100), false)
    check("skip: not repeating", Model.canSkip({ recurring = false, due = 98 }, 100), false)
    check("skip: done", Model.canSkip({ recurring = true, recurrence = rec, due = 98, completed = true }, 100), false)
end
do
    -- The hold menu's buttons get their taps: the box's own (empty) area comes before them, as later zones win.
    local src = io.open("todoviews.lua", "rb"):read("*a")
    local popup = src:match("function Views%.holdPopup.-\nend\n")
    local box = popup and popup:find("zone(x, y, w, h, function() end)", 1, true)
    local firstButton = popup and popup:find("zone(bx, by", 1, true)
    check("hold menu: the box's area before its buttons", box ~= nil and firstButton ~= nil and box < firstButton, true)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
