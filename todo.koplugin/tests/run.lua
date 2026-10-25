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

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
