--[[--
Dates for the To Do plugin, in plain Lua (no KOReader modules), so the tests
can run them with any Lua.

A due date is a day ("2026-10-20"), kept as days since 1970-01-01. Reminders
are moments, kept as Unix seconds (UTC).
]]

local Dates = {}

-- Days since 1970-01-01 for a civil date (proleptic Gregorian).
function Dates.fromCivil(y, m, d)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

function Dates.toCivil(days)
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    return m <= 2 and y + 1 or y, m, d
end

-- "2026-10-20" for a day, and back (nil when it is not that).
function Dates.format(days)
    local y, m, d = Dates.toCivil(days)
    return string.format("%04d-%02d-%02d", y, m, d)
end

function Dates.parse(text)
    local y, m, d = tostring(text or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return nil end
    return Dates.fromCivil(tonumber(y), tonumber(m), tonumber(d))
end

-- "2026-10-20T15:00:00.0000000" (UTC) as Unix seconds; nil when it is not that.
function Dates.isoSeconds(text)
    local y, mo, d, h, mi, s = tostring(text or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not y then return nil end
    return Dates.fromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
        + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

function Dates.isoUtc(seconds)
    local days = math.floor(seconds / 86400)
    local rest = seconds - days * 86400
    return string.format("%sT%02d:%02d:%02d", Dates.format(days),
        math.floor(rest / 3600), math.floor(rest % 3600 / 60), rest % 60)
end

-- The device's offset from UTC now, in seconds.
function Dates.utcOffset(now)
    now = now or os.time()
    local utc = os.date("!*t", now)
    local here = os.date("*t", now)
    local function stamp(t)
        return Dates.fromCivil(t.year, t.month, t.day) * 86400 + t.hour * 3600 + t.min * 60 + t.sec
    end
    return stamp(here) - stamp(utc)
end

-- Today, as days, here.
function Dates.today(now, offset)
    now = now or os.time()
    return math.floor((now + (offset or Dates.utcOffset(now))) / 86400)
end

-- A due date from Graph's dueDateTime. The To Do apps store "midnight on the
-- due day" in the user's zone, which Graph returns in UTC (04:00Z for New
-- York): the nearest local midnight gives the day. A due date written through
-- the API comes back as midnight UTC: the day as is.
function Dates.dueFromGraph(due, offset)
    if type(due) ~= "table" or type(due.dateTime) ~= "string" or #due.dateTime < 10 then return nil end
    local day = Dates.parse(due.dateTime)
    if not day then return nil end
    if due.timeZone and due.timeZone ~= "UTC" then return day end
    if due.dateTime:sub(11, 19) == "T00:00:00" then return day end
    local utc = Dates.isoSeconds(due.dateTime)
    if not utc then return day end
    return math.floor((utc + offset + 12 * 3600) / 86400)
end

-- Graph's dueDateTime for a day: the date at midnight UTC (Graph keeps only
-- the date, so local midnight in UTC would read back a day off).
function Dates.dueToGraph(day)
    return { dateTime = Dates.format(day) .. "T00:00:00", timeZone = "UTC" }
end

-- A reminder from Graph: UTC unless it names another zone (taken as local).
function Dates.reminderFromGraph(reminder, offset)
    if type(reminder) ~= "table" then return nil end
    local t = Dates.isoSeconds(reminder.dateTime)
    if not t then return nil end
    if reminder.timeZone and reminder.timeZone ~= "UTC" then t = t - offset end
    return t
end

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local WEEKDAY_NAMES = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local MONTH_NAMES = { "January", "February", "March", "April", "May", "June", "July", "August", "September",
    "October", "November", "December" }
Dates.WEEKDAY_NAMES = WEEKDAY_NAMES
Dates.MONTHS = MONTHS
Dates.MONTH_NAMES = MONTH_NAMES

-- "Sun" .. "Sat" (1970-01-01 was a Thursday).
function Dates.weekday(days)
    return WEEKDAYS[(days + 4) % 7 + 1]
end

-- 0 (Sunday) .. 6 (Saturday).
function Dates.weekdayIndex(days)
    return (days + 4) % 7
end

function Dates.weekdayName(days)
    return WEEKDAY_NAMES[(days + 4) % 7 + 1]
end

-- "Tue, Oct 20".
function Dates.short(days)
    local _, m, d = Dates.toCivil(days)
    return string.format("%s, %s %d", Dates.weekday(days), MONTHS[m], d)
end

-- "Tuesday, October 20".
function Dates.long(days)
    local _, m, d = Dates.toCivil(days)
    return string.format("%s, %s %d", Dates.weekdayName(days), MONTH_NAMES[m], d)
end

function Dates.daysInMonth(y, m)
    if m == 12 then return 31 end
    return Dates.fromCivil(y, m + 1, 1) - Dates.fromCivil(y, m, 1)
end

-- The month `n` months after (y, m).
function Dates.addMonths(y, m, n)
    local k = y * 12 + (m - 1) + n
    return math.floor(k / 12), k % 12 + 1
end

-- When true, clock() reads "17:00". (Or a function saying so: the plugin
-- follows KOReader's own clock setting as it changes.)
Dates.use24h = false

-- "9:30 AM", "5 PM" (or "09:30", "17:00") for a minute of the day.
function Dates.clock(minute)
    local h = math.floor(minute / 60) % 24
    local m = minute % 60
    local h24 = Dates.use24h
    if type(h24) == "function" then h24 = h24() end
    if h24 then return string.format("%02d:%02d", h, m) end
    local h12 = h % 12 == 0 and 12 or h % 12
    local half = h < 12 and "AM" or "PM"
    if m == 0 then return string.format("%d %s", h12, half) end
    return string.format("%d:%02d %s", h12, m, half)
end

-- How a due day reads: "Today", "Tomorrow", "Yesterday", "Thu" (this week),
-- "10/18".
function Dates.friendly(day, today)
    if day == today then return "Today" end
    if day == today + 1 then return "Tomorrow" end
    if day == today - 1 then return "Yesterday" end
    if day > today and day < today + 7 then return Dates.weekday(day) end
    local _, m, d = Dates.toCivil(day)
    return string.format("%d/%d", m, d)
end

-- ------------------------------------------------------------------ dates in words

local DAY_WORDS = { sun = 0, sunday = 0, mon = 1, monday = 1, tue = 2, tues = 2, tuesday = 2, wed = 3, wednesday = 3,
    thu = 4, thur = 4, thurs = 4, thursday = 4, fri = 5, friday = 5, sat = 6, saturday = 6 }
local MONTH_WORDS = {}
for i, name in ipairs(MONTH_NAMES) do
    MONTH_WORDS[name:lower()] = i
    MONTH_WORDS[MONTHS[i]:lower()] = i
end
MONTH_WORDS.sept = 9

--- A due day and a time read from a task's text, the rest kept as its title:
-- "Pay rent Friday 9am" -> { title = "Pay rent", due = (Friday), minute = 540 }.
-- Understands today, tonight, tomorrow, weekday names (this/next/on), next
-- week, in 3 days/weeks, 10/24(/2026), Oct 24(, 2026), 24 Oct, and times
-- 9am, 9:30pm, at 17:30, noon, midnight. A time alone is today (tomorrow
-- once it has passed, at `nowMinute`). Nil when there is no date or time.
-- `weekStart` 0 (Sunday) or 1 (Monday) is where "next week" starts.
function Dates.understand(text, today, nowMinute, weekStart)
    text = tostring(text or "")
    local low = text:lower()
    local cut = {}
    local function take(s, e)
        table.insert(cut, { s, e })
        low = low:sub(1, s - 1) .. string.rep(" ", e - s + 1) .. low:sub(e + 1)
    end
    -- A word just before (on, at, by, due, this, next) goes too.
    local function takeWithLead(s, e, leads)
        local before = low:sub(1, s - 1)
        for __, w in ipairs(leads) do
            local ls = before:find("%f[%w]" .. w .. "%s+$")
            if ls then return take(ls, e) end
        end
        take(s, e)
    end
    local due, minute
    -- Times.
    local function findTime()
        local s, e, h, m, half = low:find("%f[%w](%d%d?):(%d%d)%s*([ap])%.?m%.?%f[%W]")
        if not s then s, e, h, half = low:find("%f[%w](%d%d?)%s*([ap])%.?m%.?%f[%W]") m = "0" end
        if s then
            h, m = tonumber(h), tonumber(m)
            if h >= 1 and h <= 12 and m < 60 then
                h = h % 12 + (half == "p" and 12 or 0)
                return s, e, h * 60 + m
            end
        end
        s, e, h, m = low:find("%f[%w]at%s+(%d%d?):(%d%d)%f[%W]")
        if s then
            h, m = tonumber(h), tonumber(m)
            if h < 24 and m < 60 then return s, e, h * 60 + m end
        end
        s, e = low:find("%f[%w]noon%f[%W]")
        if s then return s, e, 12 * 60 end
        s, e = low:find("%f[%w]midnight%f[%W]")
        if s then return s, e, 0 end
    end
    local ts, te, tm = findTime()
    if ts then
        minute = tm
        takeWithLead(ts, te, { "at", "by" })
    end
    -- Dates.
    local function relative()
        local s, e = low:find("%f[%w]today%f[%W]")
        if s then return s, e, today end
        s, e = low:find("%f[%w]tonight%f[%W]")
        if s then return s, e, today end
        s, e = low:find("%f[%w]tomorrow%f[%W]")
        if not s then s, e = low:find("%f[%w]tmrw%f[%W]") end
        if s then return s, e, today + 1 end
        local n, unit
        s, e, n, unit = low:find("%f[%w]in%s+(%d+)%s+(%a+)%f[%W]")
        if s then
            n = tonumber(n)
            if unit == "day" or unit == "days" then return s, e, today + n end
            if unit == "week" or unit == "weeks" then return s, e, today + 7 * n end
        end
        s, e = low:find("%f[%w]next%s+week%f[%W]")
        if s then
            local start = weekStart or 0
            local ahead = (start - Dates.weekdayIndex(today)) % 7
            return s, e, today + (ahead == 0 and 7 or ahead)
        end
    end
    local function weekday()
        for s, word, e in low:gmatch("()%f[%w](%a+)%f[%W]()") do
            local idx = DAY_WORDS[word]
            if idx then
                local ahead = (idx - Dates.weekdayIndex(today)) % 7
                local before = low:sub(1, s - 1)
                if before:find("%f[%w]next%s+$") and ahead == 0 then ahead = 7 end
                return s, e - 1, today + ahead
            end
        end
    end
    local function calendar()
        local function year(y, m, d)
            if y then
                y = tonumber(y)
                if y < 100 then y = y + 2000 end
                return Dates.fromCivil(y, m, d)
            end
            local ty = Dates.toCivil(today)
            local day = Dates.fromCivil(ty, m, d)
            if day < today then day = Dates.fromCivil(ty + 1, m, d) end
            return day
        end
        local function valid(m, d) return m >= 1 and m <= 12 and d >= 1 and d <= 31 end
        local s, e, m, d, y = low:find("%f[%w](%d%d?)/(%d%d?)/(%d%d%d?%d?)%f[%W]")
        if not s then s, e, m, d = low:find("%f[%w](%d%d?)/(%d%d?)%f[%W]") y = nil end
        if s and valid(tonumber(m), tonumber(d)) then return s, e, year(y, tonumber(m), tonumber(d)) end
        for ms, word, me in low:gmatch("()%f[%w](%a+)%f[%W]()") do
            local mon = MONTH_WORDS[word]
            if mon then
                -- "Oct 24", "October 24th", "Oct 24, 2026"
                local rest = low:sub(me)
                local ds, de, dd, yy = rest:find("^%s+(%d%d?)%a*,?%s+(%d%d%d%d)%f[%W]")
                if not ds then ds, de, dd = rest:find("^%s+(%d%d?)%a*%f[%W]") yy = nil end
                if ds and valid(mon, tonumber(dd)) then return ms, me + de - 1, year(yy, mon, tonumber(dd)) end
                -- "24 Oct", "24th October"
                local before = low:sub(1, ms - 1)
                local bs, __, bd = before:find("%f[%w](%d%d?)%a*%s+$")
                if bs and valid(mon, tonumber(bd)) then return bs, me - 1, year(nil, mon, tonumber(bd)) end
            end
        end
    end
    for __, find in ipairs({ relative, calendar, weekday }) do
        local s, e, day = find()
        if s then
            due = day
            takeWithLead(s, e, { "on", "by", "due", "this", "next" })
            break
        end
    end
    if not due and not minute then return nil end
    if not due then due = (nowMinute and minute <= nowMinute) and today + 1 or today end
    -- The title: the text with what was read taken out.
    table.sort(cut, function(a, b) return a[1] > b[1] end)
    local title = text
    for __, c in ipairs(cut) do title = title:sub(1, c[1] - 1) .. " " .. title:sub(c[2] + 1) end
    title = title:gsub("%s+", " "):gsub("^%s+", ""):gsub("[%s,;:%-]+$", "")
    if title == "" then return nil end
    return { title = title, due = due, minute = minute }
end

-- A task's reminder time when it falls on its due day (local), else nil.
function Dates.reminderMinute(task, offset)
    if not task.remindAt or not task.due then return nil end
    local localSeconds = task.remindAt + offset
    if math.floor(localSeconds / 86400) ~= task.due then return nil end
    return math.floor((localSeconds % 86400) / 60)
end

return Dates
