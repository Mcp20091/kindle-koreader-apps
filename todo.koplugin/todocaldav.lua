--[[--
Calendar events from a CalDAV server, shown in To Do's calendar. Read from it,
and written to: events added or changed on the Kindle are built as iCal and
PUT to the server, taken-away ones DELETEd (the changes wait in a queue until
the calendar is synced again).

A GET of the calendar's address serves most servers their events whole; when
the answer isn't a calendar, a REPORT calendar-query asks the collection for
the events in a window. Plain Lua (no KOReader modules) for the tests; the
network and the settings are passed in, as todoapi does. A time with a Z is
UTC; one without (or with a TZID) is taken as this Kindle's time. Times the
Kindle writes are UTC (with a Z), so every client reads the same moment.
]]

local Dates = require("tododates")

local Caldav = {}
Caldav.__index = Caldav

-- Events kept from so many days before and after today (the REPORT window;
-- a GET keeps what it gets, the calendar shows the month it is on).
Caldav.BEFORE = 60
Caldav.AFTER = 200

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- An event's own text: the backslashes iCal puts in front of , ; \ and newlines come off.
local function unescape(text)
    text = text:gsub("\\\\", "\1")
    text = text:gsub("\\n", "\n"):gsub("\\N", "\n"):gsub("\\,", ","):gsub("\\;", ";")
    return (text:gsub("\1", "\\"))
end

-- The other way: text as iCal wants it in a property's value.
local function escape(text)
    text = tostring(text or ""):gsub("\\", "\\\\"):gsub(";", "\\;"):gsub(",", "\\,")
    return (text:gsub("\r?\n", "\\n"))
end

function Caldav.base64(data)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
            .. chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
            .. (b and chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=")
            .. (c and chars:sub(n % 64 + 1, n % 64 + 1) or "=")
    end
    return table.concat(out)
end

--- options: settings (get(key), set(key, value), save()), request(method, url,
-- headers, body) returning (status number or error string, body string).
function Caldav.new(options)
    local self = setmetatable({}, Caldav)
    self.settings = options.settings
    self.request = options.request
    return self
end

function Caldav:get(key) return self.settings and self.settings.get(key) or nil end

--- The calendar's address: an absolute one as given, or the calendar's path on
-- the server's address. Nil when neither is set.
function Caldav:calendarUrl()
    local calendar = trim(self:get("caldav_calendar"))
    if calendar == "" then return nil end
    if calendar:find("^https?://") then return calendar end
    local base = trim(self:get("caldav_url"))
    if base == "" then return nil end
    if not base:find("^https?://") then base = "http://" .. base end
    return base:gsub("/+$", "") .. "/" .. calendar:gsub("^/+", ""):gsub("/+$", "")
end

function Caldav:configured() return self:calendarUrl() ~= nil end

-- The Basic sign-in header (none when no username is set).
function Caldav:authHeader()
    local user = trim(self:get("caldav_user"))
    if user == "" then return nil end
    return "Basic " .. Caldav.base64(user .. ":" .. (self:get("caldav_pass") or ""))
end

-- ------------------------------------------------------------------ iCal parsing

-- A date or date-time as iCal writes it ("20261020", "20261020T093000", with a
-- Z for UTC, separators allowed): { day, second, utc, timed } or nil.
local function parseStamp(value)
    value = tostring(value or "")
    local y, m, d, rest = value:match("^(%d%d%d%d)-?(%d%d)-?(%d%d)T?(.*)$")
    if not y then return nil end
    local h, mi, s = 0, 0, 0
    if rest and #rest > 0 then
        h, mi, s = rest:match("^(%d%d?):?(%d%d?):?(%d%d?)")
        if not h then return nil end
        h, mi, s = tonumber(h), tonumber(mi), tonumber(s)
    end
    return { day = Dates.fromCivil(tonumber(y), tonumber(m), tonumber(d)),
        second = h * 3600 + mi * 60 + s, utc = value:find("Z%s*$") ~= nil, timed = rest and #rest > 0 or false }
end

-- A stamp as Unix seconds: UTC ones as they are, the rest as the Kindle's time.
local function stampSeconds(stamp, offset)
    if stamp.utc then return stamp.day * 86400 + stamp.second end
    return stamp.day * 86400 + stamp.second - offset
end

--- "PT2H30M", "P1D", "P2W" as seconds (nil when it is not one).
function Caldav.parseDuration(text)
    text = tostring(text or "")
    local sign = text:find("^%-") and -1 or 1
    local weeks = text:match("^[%+%-]?P(%d+)W$")
    if weeks then return sign * tonumber(weeks) * 7 * 86400 end
    local days = tonumber(text:match("^[%+%-]?P(%d+)D") or 0) or 0
    local time = text:match("^[%+%-]?P%d*D(.*)$") or text:match("^[%+%-]?P(.*)$") or ""
    local h = tonumber(time:match("T(%d+)H") or 0) or 0
    local m = tonumber(time:match("(%d+)M") or 0) or 0
    local s = tonumber(time:match("(%d+)S") or 0) or 0
    if days == 0 and h == 0 and m == 0 and s == 0 then return nil end
    return sign * (days * 86400 + h * 3600 + m * 60 + s)
end

-- An RRULE the calendar follows: DAILY, WEEKLY, MONTHLY or YEARLY with INTERVAL,
-- COUNT, UNTIL and (weekly) BYDAY. Anything else is no repeat.
local BYDAY = { MO = 1, TU = 2, WE = 3, TH = 4, FR = 5, SA = 6, SU = 0 }

function Caldav.parseRrule(text)
    local rule = { interval = 1 }
    for key, value in tostring(text or ""):upper():gmatch("([%w%-]+)=([^;]+)") do
        if key == "FREQ" then rule.freq = value
        elseif key == "INTERVAL" then rule.interval = tonumber(value) or 1
        elseif key == "COUNT" then rule.count = tonumber(value)
        elseif key == "UNTIL" then rule.untilStamp = parseStamp(value)
        elseif key == "BYDAY" then
            rule.byday = {}
            for token in value:gmatch("[^,]+") do
                local wd = token:match("([A-Z][A-Z])$")
                if BYDAY[wd] then table.insert(rule.byday, wd) end
            end
            if #rule.byday == 0 then rule.byday = nil end
        end
    end
    if not rule.freq or not ({ DAILY = true, WEEKLY = true, MONTHLY = true, YEARLY = true })[rule.freq] then return nil end
    return rule
end

-- A property line "NAME;PARAMS:VALUE" (the value may hold colons): name, params, value.
local function splitProp(line)
    local quotes = false
    for i = 1, #line do
        local c = line:sub(i, i)
        if c == '"' then quotes = not quotes
        elseif c == ":" and not quotes then
            local name, params = line:sub(1, i - 1):match("^([^;]+);?(.*)$")
            return name:upper(), params, line:sub(i + 1)
        end
    end
end

-- Folded lines back into one (RFC 5545: a line break and a space are none).
function Caldav.unfold(text)
    return (tostring(text or ""):gsub("\r?\n[ \t]", ""))
end

--- The VEVENTs of an .ics, as the calendar keeps them:
-- { uid, title, location, notes, allDay, day, days, starts, ends, rrule }.
-- All-day events have `day` and `days`; timed ones have `starts` (and `ends`,
-- when the event says so), in Unix seconds (UTC). A UID twice over counts once
-- (the first wins), cancelled events are left out. `offset`: the Kindle's
-- seconds from UTC, for times the server wrote without a zone.
function Caldav.parseIcs(text, offset)
    local events, seen = {}, {}
    local props, cancelled, depth
    local function keep()
        if cancelled or not (props and props.DTSTART) then return end
        local start = parseStamp(props.DTSTART.value)
        if not start then return end
        local event = {
            uid = props.UID and props.UID.value or nil,
            title = unescape((props.SUMMARY or props.LOCATION or { value = "" }).value),
            location = props.LOCATION and unescape(props.LOCATION.value) or nil,
            notes = props.DESCRIPTION and unescape(props.DESCRIPTION.value) or nil,
        }
        if event.title == "" then event.title = "(no title)" end
        if start.timed then
            event.starts = stampSeconds(start, offset)
            local endStamp = props.DTEND and parseStamp(props.DTEND.value) or nil
            if endStamp then event.ends = stampSeconds(endStamp, offset)
            elseif props.DURATION then event.ends = event.starts + (Caldav.parseDuration(props.DURATION.value) or 0) end
        else
            event.allDay = true
            event.day = start.day
            local endStamp = props.DTEND and parseStamp(props.DTEND.value) or nil
            event.days = endStamp and math.max(1, endStamp.day - start.day) or 1
        end
        if props.RRULE then
            event.rruleRaw = props.RRULE.value
            event.rrule = Caldav.parseRrule(props.RRULE.value)
        end
        if event.uid and seen[event.uid] then return end
        if event.uid then seen[event.uid] = true end
        table.insert(events, event)
    end
    for line in Caldav.unfold(text):gmatch("[^\r\n]+") do
        local name, params, value = splitProp(line)
        if name == "BEGIN" then
            if value == "VEVENT" then props, cancelled, depth = {}, false, 0
            elseif props then depth = depth + 1 end
        elseif name == "END" then
            if value == "VEVENT" then keep() props = nil
            elseif props and depth > 0 then depth = depth - 1 end
        elseif props and depth == 0 and name then
            if name == "STATUS" and value:upper():find("CANCELLED", 1, true) then cancelled = true end
            props[name] = { params = params, value = value }
        end
    end
    return events
end

-- ------------------------------------------------------------------ repeats

local function localDayOf(seconds, offset) return math.floor((seconds + offset) / 86400) end
local function localMinuteOf(seconds, offset) return math.floor((seconds + offset) % 86400 / 60) end

-- The Monday of a day's week (iCal's weeks start on Monday unless said otherwise).
local function weekBase(day) return day - (Dates.weekdayIndex(day) + 6) % 7 end

--- The occurrences of an event in the days [first..last]:
-- { { day, minute, ["repeat"] } } in day order (all-day ones have no minute).
-- Repeats follow a basic RRULE (DAILY, WEEKLY, MONTHLY, YEARLY with INTERVAL,
-- COUNT, UNTIL and a weekly BYDAY); a monthly one falls on the same day of the
-- month, shortened where the month is shorter.
function Caldav.occurrences(event, first, last, offset)
    local out = {}
    local function add(day, minute, isRepeat)
        if day >= first and day <= last then
            table.insert(out, { day = day, minute = minute, ["repeat"] = isRepeat or nil })
        end
    end
    local rule = event.rrule
    if not rule then
        if event.allDay then
            for i = 0, (event.days or 1) - 1 do add(event.day + i, nil) end
        elseif event.starts then
            add(localDayOf(event.starts, offset), localMinuteOf(event.starts, offset))
        end
        return out
    end
    local startDay = event.allDay and event.day or (event.starts and localDayOf(event.starts, offset))
    if not startDay then return out end
    local startMinute
    if not event.allDay and event.starts then startMinute = localMinuteOf(event.starts, offset) end
    local untilDay
    if rule.untilStamp then
        untilDay = rule.untilStamp.timed and localDayOf(stampSeconds(rule.untilStamp, offset), offset) or rule.untilStamp.day
    end
    local count = 0
    local function visit(day)
        count = count + 1
        if day >= startDay and (not untilDay or day <= untilDay) then
            if event.allDay then
                for i = 0, (event.days or 1) - 1 do add(day + i, nil, day ~= startDay) end
            else
                add(day, startMinute, day ~= startDay)
            end
        end
        if rule.count and count >= rule.count then return true end
        if untilDay and day > untilDay then return true end
        return false
    end
    local interval = math.max(1, rule.interval or 1)
    if rule.freq == "DAILY" then
        local day = startDay
        while day <= last do
            if visit(day) then break end
            day = day + interval
        end
    elseif rule.freq == "WEEKLY" then
        local set = {}
        if rule.byday then
            for __, k in ipairs(rule.byday) do set[BYDAY[k]] = true end
        else
            set[Dates.weekdayIndex(startDay)] = true
        end
        local week, stop = weekBase(startDay), false
        while week <= last and not stop do
            for wd = 0, 6 do
                local day = week + wd
                if day >= startDay and set[Dates.weekdayIndex(day)] then
                    if visit(day) then stop = true break end
                end
            end
            week = week + 7 * interval
        end
    else
        local y, m, d = Dates.toCivil(startDay)
        local step = rule.freq == "YEARLY" and 12 * interval or interval
        for k = 0, 1200 do
            local yy, mm = Dates.addMonths(y, m, k * step)
            local day = Dates.fromCivil(yy, mm, math.min(d, Dates.daysInMonth(yy, mm)))
            if day > last then break end
            if visit(day) then break end
        end
    end
    return out
end

--- The events on one `day` (a day number), each `{ event, day, minute,
-- ["repeat"] }` (all-day ones have no minute): all-day first, then by start
-- time, then title. The calendar view shows them in this order; the launcher's
-- home screen and the sleep screens put the ones with a time first.
function Caldav.dayEvents(events, day, offset)
    local out = {}
    for _, ev in ipairs(events or {}) do
        for __, occ in ipairs(Caldav.occurrences(ev, day, day, offset)) do
            table.insert(out, { event = ev, day = day, minute = occ.minute, ["repeat"] = occ["repeat"] })
        end
    end
    table.sort(out, function(a, b)
        local ma, mb = a.minute or -1, b.minute or -1
        if ma ~= mb then return ma < mb end
        return (a.event.title or ""):lower() < (b.event.title or ""):lower()
    end)
    return out
end

-- ------------------------------------------------------------------ writing

-- A day as iCal writes it ("20261020").
local function dayStamp(day) return os.date("!%Y%m%d", day * 86400) end

-- A moment as iCal writes it, in UTC ("20261020T133000Z").
local function utcStamp(seconds) return os.date("!%Y%m%dT%H%M%SZ", math.floor(seconds)) end

--- A UID for an event made on the Kindle (also its file's name on servers
-- that keep one event per resource): the time, a counter and two random
-- parts. `now` and `n` stand in for them in the tests.
function Caldav.newUid(now, n)
    now = now or os.time()
    n = n or 0
    return string.format("kindle-%d-%04x%04x-%04x", now, n % 65536, math.random(0, 65535), math.random(0, 65535))
end

--- One event as iCal (a whole VCALENDAR, what a PUT sends). `event` is as
-- parseIcs keeps them: uid, title, allDay with day and days, or starts and
-- ends, location, notes; `rruleRaw` (a repeat kept as the server wrote it)
-- goes back as it came. `stamp` (Unix seconds) is DTSTAMP. Lines are not
-- folded (RFC 5545's 75 octets is a should, and every server takes long ones).
function Caldav.buildIcs(event, stamp)
    local out = {
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//KOReader To Do//EN",
        "BEGIN:VEVENT",
        "UID:" .. tostring(event.uid or ""),
        "DTSTAMP:" .. utcStamp(stamp or os.time()),
    }
    if event.allDay then
        table.insert(out, "DTSTART;VALUE=DATE:" .. dayStamp(event.day))
        table.insert(out, "DTEND;VALUE=DATE:" .. dayStamp(event.day + (event.days or 1)))
    else
        table.insert(out, "DTSTART:" .. utcStamp(event.starts))
        table.insert(out, "DTEND:" .. utcStamp(event.ends or event.starts + 3600))
    end
    table.insert(out, "SUMMARY:" .. escape(event.title))
    if event.location and event.location ~= "" then table.insert(out, "LOCATION:" .. escape(event.location)) end
    if event.notes and event.notes ~= "" then table.insert(out, "DESCRIPTION:" .. escape(event.notes)) end
    if event.rruleRaw and event.rruleRaw ~= "" then table.insert(out, "RRULE:" .. event.rruleRaw) end
    table.insert(out, "END:VEVENT")
    table.insert(out, "END:VCALENDAR")
    return table.concat(out, "\r\n") .. "\r\n"
end

--- The address one event is kept at: the server's own (from the REPORT, kept
-- with the event) when we know it, else the calendar's with the UID as the
-- resource's name.
function Caldav:eventUrl(event)
    local href = event.href
    if href and href ~= "" then
        if href:find("^https?://") then return href end
        local base = self:calendarUrl()
        local host = base and base:match("^(https?://[^/]+)")
        if host then return host .. (href:sub(1, 1) == "/" and href or "/" .. href) end
        return href
    end
    local base = self:calendarUrl()
    if not base then return nil end
    return base:gsub("/+$", "") .. "/" .. tostring(event.uid or "") .. ".ics"
end

--- Puts one event to the server (method PUT), or takes one away (DELETE).
-- True when it worked, or nil and why. A DELETE that answers 404 counts
-- (the event is gone either way). No If-Match: the last change wins.
function Caldav:sendEvent(method, event, stamp)
    local url = self:eventUrl(event)
    if not url then return nil, "No calendar address is set" end
    if method == "PUT" and not ((event.allDay and event.day) or event.starts) then
        return nil, "The event has no time"
    end
    local headers, body = {}, nil
    if method == "PUT" then
        headers["Content-Type"] = "text/calendar; charset=utf-8"
        body = Caldav.buildIcs(event, stamp)
    end
    local auth = self:authHeader()
    if auth then headers.Authorization = auth end
    local status = self.request(method, url, headers, body)
    if type(status) ~= "number" then return nil, "No connection: " .. tostring(status) end
    if method == "DELETE" and status == 404 then return true end
    if status < 200 or status >= 300 then return nil, "HTTP " .. tostring(status) end
    return true
end

--- Sends a queue of changes ({ kind = "put" or "delete", event = ... }) in
-- order, stopping at the first one that fails: the rest stays queued.
-- Returns { sent = how many went, stopped = why (when one failed) }.
function Caldav:pushQueue(queue, stamp)
    local report = { sent = 0 }
    for __, op in ipairs(queue or {}) do
        local ok, why = self:sendEvent(op.kind == "delete" and "DELETE" or "PUT", op.event or {}, stamp)
        if not ok then
            report.stopped = why
            break
        end
        report.sent = report.sent + 1
    end
    return report
end

-- The queue's key for an event: its UID, or its address when it has none.
local function eventKey(ev)
    if ev.uid and ev.uid ~= "" then return "u:" .. ev.uid end
    if ev.href and ev.href ~= "" then return "h:" .. ev.href end
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

--- Puts `event` into `events` in place: replaces the one with its UID (or
-- address), or is added.
function Caldav.applyEvent(events, event)
    local key = eventKey(event)
    for i, ev in ipairs(events) do
        if key and eventKey(ev) == key then
            events[i] = copy(event)
            return
        end
    end
    table.insert(events, copy(event))
end

--- Takes the event with `event`'s UID (or address) out of `events`, in place.
function Caldav.removeEvent(events, event)
    local key = eventKey(event)
    for i, ev in ipairs(events) do
        if key and eventKey(ev) == key then
            table.remove(events, i)
            return
        end
    end
end

--- The events to show: the fetched ones with a queue of changes on top
-- ({ kind = "put" or "delete", event = ... }), each in place, newest last.
-- A fresh list; the ones passed in are left as they are.
function Caldav.applyQueue(events, queue)
    local out = {}
    for __, ev in ipairs(events or {}) do table.insert(out, copy(ev)) end
    for __, op in ipairs(queue or {}) do
        if op.kind == "delete" then Caldav.removeEvent(out, op.event or {})
        else Caldav.applyEvent(out, op.event or {}) end
    end
    return out
end

-- ------------------------------------------------------------------ fetching

-- A moment as iCal writes it (UTC).
local function queryStamp(seconds) return os.date("!%Y%m%dT%H%M%SZ", math.floor(seconds)) end

--- The REPORT calendar-query for the events between two moments (nil window:
-- every event, whatever its day).
function Caldav.queryBody(from, until_)
    local filter
    if from and until_ then
        filter = "<C:comp-filter name=\"VEVENT\"><C:time-range start=\"" .. queryStamp(from)
            .. "\" end=\"" .. queryStamp(until_) .. "\"/></C:comp-filter>"
    else
        filter = "<C:comp-filter name=\"VEVENT\"/>"
    end
    return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        .. "<C:calendar-query xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">"
        .. "<D:prop><D:getetag/><C:calendar-data/></D:prop>"
        .. "<C:filter><C:comp-filter name=\"VCALENDAR\">" .. filter .. "</C:comp-filter></C:filter>"
        .. "</C:calendar-query>"
end

-- The iCal body inside one answer's <…:calendar-data>…</…:calendar-data>.
local ENTITIES = { ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = "\"", ["&apos;"] = "'", ["&amp;"] = "&" }

local function calendarDataOf(block)
    local chunk = block:match("<[%w%-]*:?[cC]alendar%-data[^>]*>(.-)</[%w%-]*:?[cC]alendar%-data%s*>")
    if not chunk then return nil end
    chunk = chunk:match("<!%[CDATA%[(.-)%]%]>") or chunk
    return (chunk:gsub("&[%w]+;", ENTITIES))
end

--- The parts of a REPORT's answer: { { ics, href, etag } } for each response
-- that carries a calendar (the address and the etag as the server wrote them,
-- escapes off; the event's own address `href` is what a PUT or DELETE goes to).
-- An answer with calendars but no responses (not a proper 207) is one part.
function Caldav.responsesOf(xml)
    local out = {}
    if type(xml) ~= "string" then return out end
    local function prop(block, name)
        return (block:match("<[%w%-]*:?" .. name .. "[^>]*>(.-)</[%w%-]*:?" .. name .. "%s*>") or "")
            :gsub("&[%w]+;", ENTITIES)
    end
    for block in xml:gmatch("<[%w%-]*:?[rR]esponse[%s>].-</[%w%-]*:?[rR]esponse%s*>") do
        local ics = calendarDataOf(block)
        if ics then table.insert(out, { ics = ics, href = prop(block, "href"), etag = prop(block, "getetag") }) end
    end
    if #out == 0 then
        for chunk in xml:gmatch("<[%w%-]*:?[cC]alendar%-data[^>]*>(.-)</[%w%-]*:?[cC]alendar%-data%s*>") do
            chunk = chunk:match("<!%[CDATA%[(.-)%]%]>") or chunk
            table.insert(out, { ics = (chunk:gsub("&[%w]+;", ENTITIES)) })
        end
    end
    return out
end

--- The iCal bodies inside a REPORT's answer.
function Caldav.extractCalendarData(xml)
    local out = {}
    for __, r in ipairs(Caldav.responsesOf(xml)) do table.insert(out, r.ics) end
    return out
end

--- The events between `from` and `until_` (Unix seconds; nil: the server's
-- whole calendar). A GET of the calendar's address first; when the answer
-- isn't a calendar, a REPORT calendar-query asks the collection. Each event
-- keeps the server's address for it (`href`) when the REPORT gave one. Returns
-- the events, or nil and why.
function Caldav:fetch(from, until_, offset)
    local url = self:calendarUrl()
    if not url then return nil, "No calendar address is set" end
    local headers = { Depth = "1" }
    local auth = self:authHeader()
    if auth then headers.Authorization = auth end
    offset = offset or Dates.utcOffset()
    local status, body = self.request("GET", url, headers)
    if type(status) == "number" and status == 200 and type(body) == "string" and body:find("BEGIN:VCALENDAR", 1, true) then
        return Caldav.parseIcs(body, offset)
    end
    status, body = self.request("REPORT", url, headers, Caldav.queryBody(from, until_))
    if type(status) ~= "number" then return nil, "No connection: " .. tostring(status) end
    if status == 207 and type(body) == "string" then
        local events = {}
        for __, r in ipairs(Caldav.responsesOf(body)) do
            for __, event in ipairs(Caldav.parseIcs(r.ics, offset)) do
                if r.href ~= "" then event.href = r.href end
                table.insert(events, event)
            end
        end
        return events
    end
    return nil, "HTTP " .. tostring(status)
end

--- One row for the connection test (appstest.lua): the calendar asked for its
-- events. clock() gives seconds.
function Caldav:testConnection(clock, from, until_)
    local started = clock()
    local events, why = self:fetch(from, until_)
    local url = self:calendarUrl()
    local row = { name = "caldav", detail = url and tostring(url):match("^https?://([^/]+)") or tostring(url),
        ms = math.floor((clock() - started) * 1000) }
    if events then
        row.ok, row.kind = true, "ok"
    elseif tostring(why):find("^No connection") then
        row.ok, row.kind, row.err = false, "unreachable", tostring(why):gsub("^No connection: ", "")
    else
        row.ok, row.kind, row.err = false, "failed", why
    end
    return { row }
end

return Caldav
