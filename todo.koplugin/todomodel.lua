--[[--
Tasks for the To Do plugin: Graph's JSON into plain tables, their order, the
views (Today, Agenda, Starred, a list, the calendar, search) and repeats.
Plain Lua (no KOReader modules) for the tests.

A task: { id, title, important, completed, due (days), remindAt (Unix seconds),
recurrence = { pattern, range } (as Graph has it), recurring, notes,
steps = { {id, title, checked} } }. A list: { id, name, wellknown, tasks }.
]]

local Dates = require("tododates")

local Model = {}

local function copyArray(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for i, v in ipairs(t) do out[i] = v end
    return #out > 0 and out or nil
end

-- Graph's recurrence, kept to the fields the plugin reads and writes back.
function Model.recurrenceFromGraph(r)
    if type(r) ~= "table" or type(r.pattern) ~= "table" or not r.pattern.type then return nil end
    local p, g = r.pattern, type(r.range) == "table" and r.range or {}
    return {
        pattern = {
            type = p.type,
            interval = tonumber(p.interval) or 1,
            daysOfWeek = copyArray(p.daysOfWeek),
            dayOfMonth = tonumber(p.dayOfMonth) ~= 0 and tonumber(p.dayOfMonth) or nil,
            month = tonumber(p.month) ~= 0 and tonumber(p.month) or nil,
            index = p.index,
            firstDayOfWeek = p.firstDayOfWeek,
        },
        range = {
            type = g.type or "noEnd",
            startDate = g.startDate,
            endDate = g.endDate ~= "0001-01-01" and g.endDate or nil,
            numberOfOccurrences = tonumber(g.numberOfOccurrences) ~= 0 and tonumber(g.numberOfOccurrences) or nil,
        },
    }
end

-- Notes as text: HTML bodies (from Outlook) lose their tags.
local function bodyText(body)
    if type(body) ~= "table" or type(body.content) ~= "string" then return nil end
    local text = body.content
    if body.contentType == "html" then
        text = text:gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("</[Pp]>", "\n"):gsub("<[^>]+>", "")
        text = text:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&amp;", "&")
    end
    text = text:gsub("\r\n", "\n")
    if text:match("^%s*$") then return nil end
    return text
end

-- Graph's task JSON into a task.
function Model.taskFromGraph(t, offset)
    local task = {
        id = t.id,
        title = t.title or "",
        important = t.importance == "high",
        completed = t.status == "completed",
        due = Dates.dueFromGraph(t.dueDateTime, offset),
        recurrence = Model.recurrenceFromGraph(t.recurrence),
        notes = bodyText(t.body),
        steps = {},
    }
    task.recurring = task.recurrence ~= nil
    if t.isReminderOn then task.remindAt = Dates.reminderFromGraph(t.reminderDateTime, offset) end
    if type(t.checklistItems) == "table" then
        for _, item in ipairs(t.checklistItems) do
            table.insert(task.steps, { id = item.id, title = item.displayName or "", checked = item.isChecked == true })
        end
    end
    return task
end

-- Graph's list JSON into a list (its tasks come separately).
function Model.listFromGraph(l)
    return { id = l.id, name = l.displayName or "", wellknown = l.wellknownListName, tasks = {} }
end

-- Lists the Today and Agenda views leave out (flagged emails).
function Model.inAgenda(list)
    return list.wellknown ~= "flaggedEmails"
end

-- The order of tasks: by due day (undated last), starred first within a day
-- if `starredFirst`, then by reminder time (untimed after), then by title.
function Model.sort(tasks, offset, starredFirst)
    local function key(task)
        return task.due or math.huge, Dates.reminderMinute(task, offset) or math.huge
    end
    table.sort(tasks, function(a, b)
        local da, ta = key(a)
        local db, tb = key(b)
        if da ~= db then return da < db end
        if starredFirst and a.important ~= b.important then return a.important end
        if ta ~= tb then return ta < tb end
        return a.title:lower() < b.title:lower()
    end)
    return tasks
end

-- Entries ({list, task}) sorted as Model.sort does.
function Model.sortEntries(entries, offset, starredFirst)
    local tasks, byTask = {}, {}
    for _, e in ipairs(entries) do
        table.insert(tasks, e.task)
        byTask[e.task] = e
    end
    Model.sort(tasks, offset, starredFirst)
    local out = {}
    for i, task in ipairs(tasks) do out[i] = byTask[task] end
    return out
end

-- Every open task in the lists the views show: { list, task }.
-- opts.hidden: a set of list ids left out; opts.all: flagged emails too.
local function openEntries(lists, opts)
    local out = {}
    for _, list in ipairs(lists) do
        if (opts.all or Model.inAgenda(list)) and not (opts.hidden and opts.hidden[list.id]) then
            for _, task in ipairs(list.tasks) do
                if not task.completed or opts.withDone then table.insert(out, { list = list, task = task }) end
            end
        end
    end
    return out
end

local function dayTitle(day)
    local _, m, d = Dates.toCivil(day)
    return string.format("%s, %s %d", Dates.weekday(day):upper(), Dates.MONTHS[m]:upper(), d)
end

--- The Agenda: overdue, today, then each of the next days (`opts.days`, 7
-- with today), each a section { key, title, entries }. `opts.todayOnly`:
-- overdue and today (the Today view). Ticked-off tasks stay (struck through)
-- until the next sync.
function Model.agenda(lists, today, offset, opts)
    opts = opts or {}
    local days = opts.todayOnly and 1 or (opts.days or 7)
    local picked = {}
    for _, e in ipairs(openEntries(lists, { hidden = opts.hidden, withDone = true })) do
        local due = e.task.due
        if due and due < today + days then table.insert(picked, e) end
    end
    picked = Model.sortEntries(picked, offset, opts.starredFirst)
    local sections, current = {}, nil
    for _, e in ipairs(picked) do
        local key, title
        if e.task.due < today then
            key, title = "overdue", "OVERDUE"
        elseif e.task.due == today then
            key, title = "today", "TODAY  ·  " .. dayTitle(today)
        else
            key, title = e.task.due, dayTitle(e.task.due)
        end
        if not current or current.key ~= key then
            current = { key = key, title = title, entries = {} }
            table.insert(sections, current)
        end
        table.insert(current.entries, e)
    end
    return sections
end

--- Entries in four groups by due date: Overdue, Today, Upcoming, No due date
-- (empty groups left out). Used by a list and Starred.
function Model.groupByDue(entries, today, offset, starredFirst)
    entries = Model.sortEntries(entries, offset, starredFirst)
    local groups = {
        { key = "overdue", title = "OVERDUE", entries = {} },
        { key = "today", title = "TODAY", entries = {} },
        { key = "upcoming", title = "UPCOMING", entries = {} },
        { key = "none", title = "NO DUE DATE", entries = {} },
    }
    for _, e in ipairs(entries) do
        local due = e.task.due
        local g = not due and 4 or (due < today and 1) or (due == today and 2) or 3
        table.insert(groups[g].entries, e)
    end
    local out = {}
    for _, g in ipairs(groups) do
        if #g.entries > 0 then table.insert(out, g) end
    end
    return out
end

-- A list's tasks as entries.
function Model.listEntries(list)
    local out = {}
    for _, task in ipairs(list.tasks) do table.insert(out, { list = list, task = task }) end
    return out
end

-- Starred tasks across the lists.
function Model.starred(lists, opts)
    local out = {}
    for _, e in ipairs(openEntries(lists, { hidden = opts and opts.hidden, all = true, withDone = true })) do
        if e.task.important then table.insert(out, e) end
    end
    return out
end

-- Tasks whose title, notes or steps hold `query` (any case).
function Model.search(lists, query)
    local q = tostring(query or ""):lower()
    if q:match("^%s*$") then return {} end
    local out = {}
    local function has(s) return s and s:lower():find(q, 1, true) ~= nil end
    for _, e in ipairs(openEntries(lists, { all = true, withDone = true })) do
        local t = e.task
        local hit = has(t.title) or has(t.notes)
        for _, step in ipairs(t.steps or {}) do hit = hit or has(step.title) end
        if hit then table.insert(out, e) end
    end
    return out
end

-- What shows for a task's time: "9:30 AM" today, "Tomorrow 5 PM", "Overdue 10/18".
function Model.whenText(task, today, offset)
    if not task.due then return "" end
    local minute = Dates.reminderMinute(task, offset)
    if task.due < today then
        local _, m, d = Dates.toCivil(task.due)
        return string.format("Overdue %d/%d", m, d)
    end
    local day = Dates.friendly(task.due, today)
    if minute then
        return task.due == today and Dates.clock(minute) or day .. " " .. Dates.clock(minute)
    end
    return day
end

-- How many open tasks there are, overdue and due today, in a list.
function Model.counts(list, today)
    local open, overdue, dueToday = 0, 0, 0
    for _, task in ipairs(list.tasks) do
        if not task.completed then
            open = open + 1
            if task.due and task.due < today then overdue = overdue + 1 end
            if task.due == today then dueToday = dueToday + 1 end
        end
    end
    return open, overdue, dueToday
end

-- The home screen's numbers: due today, overdue, in the next 7 days, starred.
--- E-ink ghosting: screen changes add up (`weight` each); every `every`
-- of them (0: never) the refresh flashes, clearing what earlier screens
-- left. Returns the new count and whether to flash now.
function Model.flashDue(count, weight, every)
    if not every or every <= 0 then return 0, false end
    count = (count or 0) + (weight or 1)
    if count >= every then return 0, true end
    return count, false
end

function Model.summary(lists, today, opts)
    local s = { today = 0, overdue = 0, week = 0, starred = 0 }
    for _, e in ipairs(openEntries(lists, { hidden = opts and opts.hidden })) do
        local due = e.task.due
        if due == today then s.today = s.today + 1 end
        if due and due < today then s.overdue = s.overdue + 1 end
        if due and due >= today and due < today + 7 then s.week = s.week + 1 end
    end
    s.starred = #Model.starred(lists, opts)
    for _, e in ipairs(Model.starred(lists, opts)) do
        if e.task.completed then s.starred = s.starred - 1 end
    end
    return s
end

-- ------------------------------------------------------------------ repeats

local DAY_KEYS = { "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" }
local INDEX = { first = 1, second = 2, third = 3, fourth = 4, last = 5 }
Model.DAY_KEYS = DAY_KEYS

local function dayKeyIndex(key)
    for i, k in ipairs(DAY_KEYS) do
        if k == key then return i - 1 end
    end
end

local function capital(s) return (s:gsub("^%l", string.upper)) end

local function dayList(days)
    local names = {}
    for _, key in ipairs(days or {}) do
        local i = dayKeyIndex(key)
        if i then table.insert(names, i) end
    end
    table.sort(names)
    if #names == 1 then return Dates.WEEKDAY_NAMES[names[1] + 1] end
    local short = {}
    for k, i in ipairs(names) do short[k] = Dates.weekday(i - 4) end  -- day -4 was a Sunday
    return table.concat(short, ", ")
end

local function isWeekdays(days)
    if not days or #days ~= 5 then return false end
    local set = {}
    for _, k in ipairs(days) do set[k] = true end
    return set.monday and set.tuesday and set.wednesday and set.thursday and set.friday or false
end

--- How a repeat reads: "Daily", "Every 2 days", "Weekdays", "Weekly on
-- Sunday", "Monthly on day 23", "Yearly on Dec 17".
function Model.repeatText(rec)
    if not rec or not rec.pattern then return "" end
    local p = rec.pattern
    local n = p.interval or 1
    if p.type == "daily" then
        return n == 1 and "Daily" or string.format("Every %d days", n)
    elseif p.type == "weekly" then
        if n == 1 and isWeekdays(p.daysOfWeek) then return "Weekdays" end
        local on = p.daysOfWeek and (" on " .. dayList(p.daysOfWeek)) or ""
        return (n == 1 and "Weekly" or string.format("Every %d weeks", n)) .. on
    elseif p.type == "absoluteMonthly" then
        return (n == 1 and "Monthly" or string.format("Every %d months", n)) .. (p.dayOfMonth and (" on day " .. p.dayOfMonth) or "")
    elseif p.type == "relativeMonthly" then
        return (n == 1 and "Monthly" or string.format("Every %d months", n)) .. " on the " .. (p.index or "first") .. " " .. capital(p.daysOfWeek and p.daysOfWeek[1] or "")
    elseif p.type == "absoluteYearly" then
        local on = p.month and p.dayOfMonth and string.format(" on %s %d", Dates.MONTHS[p.month], p.dayOfMonth) or ""
        return (n == 1 and "Yearly" or string.format("Every %d years", n)) .. on
    elseif p.type == "relativeYearly" then
        return (n == 1 and "Yearly" or string.format("Every %d years", n)) .. " on the " .. (p.index or "first") .. " " .. capital(p.daysOfWeek and p.daysOfWeek[1] or "") .. (p.month and (" of " .. Dates.MONTH_NAMES[p.month]) or "")
    end
    return "Repeats"
end

-- Repeats every day or two: the calendar lists these once instead of a dot a day.
function Model.isFrequent(rec)
    return rec ~= nil and rec.pattern.type == "daily" and (rec.pattern.interval or 1) <= 2
end

-- The `index` (first..fourth, last) `weekday` (0-6) of a month, as days.
local function nthWeekday(y, m, index, weekday)
    if index == "last" then
        local last = Dates.fromCivil(y, m, Dates.daysInMonth(y, m))
        return last - (Dates.weekdayIndex(last) - weekday) % 7
    end
    local first = Dates.fromCivil(y, m, 1)
    return first + (weekday - Dates.weekdayIndex(first)) % 7 + 7 * ((INDEX[index] or 1) - 1)
end

local function weekStart(day, firstDay)
    return day - (Dates.weekdayIndex(day) - (firstDay or 0)) % 7
end

--- The first day a repeat falls on that is on or after `from`, counting from
-- `anchor` (the task's due date, one of its days). nil when it never does
-- (a range that ended).
function Model.nextOccurrence(rec, anchor, from)
    if not rec or not anchor then return nil end
    local p = rec.pattern
    local n = math.max(1, p.interval or 1)
    local result
    if anchor >= from then
        result = anchor
    elseif p.type == "daily" then
        result = anchor + math.ceil((from - anchor) / n) * n
    elseif p.type == "weekly" then
        local set = {}
        for _, k in ipairs(p.daysOfWeek or { DAY_KEYS[Dates.weekdayIndex(anchor) + 1] }) do
            local i = dayKeyIndex(k)
            if i then set[i] = true end
        end
        local firstDay = dayKeyIndex(p.firstDayOfWeek or "sunday") or 0
        local base = weekStart(anchor, firstDay)
        for d = from, from + 7 * n * 2 do
            local weeks = math.floor((weekStart(d, firstDay) - base) / 7)
            if weeks % n == 0 and set[Dates.weekdayIndex(d)] then
                result = d
                break
            end
        end
    else
        local ay, am, ad = Dates.toCivil(anchor)
        local yearly = p.type == "absoluteYearly" or p.type == "relativeYearly"
        local step = yearly and 12 * n or n
        for k = 1, 1200 do
            local y, m = Dates.addMonths(ay, am, k * step)
            local d
            if p.type == "absoluteMonthly" or p.type == "absoluteYearly" then
                local dm = p.dayOfMonth or ad
                d = Dates.fromCivil(y, m, math.min(dm, Dates.daysInMonth(y, m)))
            else
                local wd = dayKeyIndex(p.daysOfWeek and p.daysOfWeek[1] or "") or Dates.weekdayIndex(anchor)
                d = nthWeekday(y, m, p.index or "first", wd)
            end
            if d >= from then
                result = d
                break
            end
        end
    end
    local range = rec.range or {}
    if result and range.type == "endDate" and range.endDate then
        local last = Dates.parse(range.endDate)
        if last and result > last then return nil end
    end
    return result
end

--- A repeat from the presets: "daily", "weekdays", "weekly", "biweekly",
-- "monthly", "yearly", or "custom" with `n` and `unit` ("days", "weeks",
-- "months", "years"); falls on `day`.
function Model.preset(kind, day, n, unit)
    local _, m, d = Dates.toCivil(day)
    local weekday = DAY_KEYS[Dates.weekdayIndex(day) + 1]
    local p
    if kind == "custom" then
        kind = ({ days = "daily", weeks = "weekly", months = "monthly", years = "yearly" })[unit] or "daily"
    else
        n = nil
    end
    if kind == "daily" then
        p = { type = "daily", interval = n or 1 }
    elseif kind == "weekdays" then
        p = { type = "weekly", interval = 1, daysOfWeek = { "monday", "tuesday", "wednesday", "thursday", "friday" },
            firstDayOfWeek = "sunday" }
    elseif kind == "weekly" or kind == "biweekly" then
        p = { type = "weekly", interval = kind == "biweekly" and 2 or (n or 1), daysOfWeek = { weekday }, firstDayOfWeek = "sunday" }
    elseif kind == "monthly" then
        p = { type = "absoluteMonthly", interval = n or 1, dayOfMonth = d }
    else
        p = { type = "absoluteYearly", interval = n or 1, dayOfMonth = d, month = m }
    end
    return { pattern = p, range = { type = "noEnd", startDate = Dates.format(day) } }
end

-- The note kept when a repeat is removed (as CrossInk writes it).
function Model.repeatRemovedNote(oldDue, today)
    return string.format("Original due date was %s and recurrence was removed on %s",
        oldDue and Dates.format(oldDue) or "none", Dates.format(today))
end

-- ------------------------------------------------------------------ calendar

--- A month: `days[d]` = entries due that day (with `repeat = true` for a
-- later day a repeating task falls on), and `frequent` = the tasks that
-- repeat every day or two (listed once, not dotted every day).
function Model.calendar(lists, y, m, today, offset, opts)
    opts = opts or {}
    local first = Dates.fromCivil(y, m, 1)
    local last = first + Dates.daysInMonth(y, m) - 1
    local days, frequent = {}, {}
    local function add(day, e)
        local d = day - first + 1
        days[d] = days[d] or {}
        table.insert(days[d], e)
    end
    for _, e in ipairs(openEntries(lists, { hidden = opts.hidden })) do
        local t = e.task
        if t.due then
            if Model.isFrequent(t.recurrence) then
                table.insert(frequent, e)
            else
                if t.due >= first and t.due <= last then add(t.due, e) end
                if t.recurrence then
                    local from = math.max(t.due + 1, first)
                    local guard = 0
                    while guard < 40 do
                        guard = guard + 1
                        local nxt = Model.nextOccurrence(t.recurrence, t.due, from)
                        if not nxt or nxt > last then break end
                        add(nxt, { list = e.list, task = t, ["repeat"] = true })
                        from = nxt + 1
                    end
                end
            end
        end
    end
    for _, entries in pairs(days) do
        local sorted = Model.sortEntries(entries, offset, opts.starredFirst)
        for i, e in ipairs(sorted) do entries[i] = e end
    end
    frequent = Model.sortEntries(frequent, offset, false)
    return { first = first, last = last, days = days, frequent = frequent }
end

return Model
