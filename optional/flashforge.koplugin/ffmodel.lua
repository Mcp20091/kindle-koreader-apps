--[[--
FlashForge's printer as words and tables, in plain Lua for the tests: what
the printer's /detail answer means (its state, the print, temperatures, the
Material Station), times and temperatures as text, the launcher's line, the
recent files, the material matching rules, the print-start request for each
model, and the printers' answers to discovery.

The matching rules and the per-model print start are a port of the Home
Assistant integration's job.py (ff-5mp-hass), which ports them from the
FlashForge desktop app:
* every tool in the file is mapped to a slot, exactly once;
* a slot backs at most one tool;
* an empty slot can't be used;
* the material names must match (ignoring case and spaces);
* a different colour is allowed, with a warning.
]]

local M = {}

-- Gettext when inside KOReader; the words themselves in the tests.
local ok, gettext = pcall(require, "gettext")
local _ = ok and gettext or function(s) return s end
local function T(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

-- The printers this app talks to: the firmware's `pid` on /detail (and the
-- product ID in its discovery answer). Older printers (Adventurer 3 and 4)
-- have no HTTP API.
M.MODELS = {
    [35] = "Adventurer 5M",
    [36] = "Adventurer 5M Pro",
    [38] = "AD5X",
    [40] = "Creator 5",
    [41] = "Creator 5 Pro",
}

M.PORT = 8898          -- the printer's HTTP API
M.CAMERA_PORT = 8080   -- its camera (MJPEG)
M.MAX_SLOTS = 4
-- Sent when a slot or a tool has no usable colour (as the desktop app does).
M.FALLBACK_COLOR = "#808080"

local function str(v)
    if v == nil or type(v) == "table" or type(v) == "userdata" then return "" end
    return tostring(v)
end

local function num(v)
    return tonumber(v) or 0
end

local function list(v)
    if type(v) == "table" then return v end
    return {}
end

-- ------------------------------------------------------------------ the printer's state

-- /detail's `status`, as one of these (the library's MachineState). The
-- Creator 5 Pro says "pause" where the others say "paused".
local STATES = {
    ready = "ready", busy = "busy", calibrate_doing = "calibrating", error = "error", heating = "heating",
    printing = "printing", pausing = "pausing", pause = "paused", paused = "paused", cancel = "cancelled",
    completed = "completed", downloading = "busy",
}

function M.state(status)
    return STATES[str(status):lower()] or "unknown"
end

local STATE_TEXT = {
    ready = _("Ready"), busy = _("Busy"), calibrating = _("Calibrating"), error = _("Error"), heating = _("Heating"),
    printing = _("Printing"), pausing = _("Pausing"), paused = _("Paused"), cancelled = _("Cancelled"),
    completed = _("Finished"), unknown = _("Unknown"),
}

function M.stateText(state)
    return STATE_TEXT[state] or STATE_TEXT.unknown
end

--- A print under way (it can be paused, resumed or cancelled).
function M.active(state)
    return state == "printing" or state == "heating" or state == "pausing" or state == "paused"
end

function M.canPause(state) return state == "printing" or state == "heating" end
function M.canResume(state) return state == "paused" or state == "pausing" end
--- After a print (finished, cancelled, or stopped by an error): the plate to clear.
function M.canClear(state) return state == "completed" or state == "cancelled" or state == "error" end

--- An error code worth showing ("" and zeros are none).
local function errorCode(v)
    local s = str(v)
    if s == "" or s:match("^0+$") then return nil end
    return s
end

--- A temperature pair { cur, set }.
local function temp(cur, set)
    return { cur = num(cur), set = num(set) }
end

--- The Material Station's slots: { { id, empty, material, color } } by slot,
-- 1 to 4 only (a printer can't be told about a fifth).
function M.slots(station)
    local out = {}
    for __, s in ipairs(list(station and station.slotInfos)) do
        local id = num(s.slotId)
        if id >= 1 and id <= M.MAX_SLOTS then
            local material = str(s.materialName)
            table.insert(out, { id = id, empty = not s.hasFilament or material == "", material = material,
                color = str(s.materialColor) })
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- /detail's `detail` as the app uses it.
function M.info(d)
    d = type(d) == "table" and d or {}
    local pid = tonumber(d.pid)
    local name = str(d.name)
    local i = { pid = pid, name = name }
    if M.MODELS[pid] then
        i.isPro, i.isAD5X = pid == 36, pid == 38
        i.isC5, i.isC5Pro = pid == 40 or pid == 41, pid == 41
    else
        -- (an unknown pid: by the name, as the library does)
        i.isC5 = name:find("Creator 5", 1, true) ~= nil
        i.isC5Pro = i.isC5 and (str(d.model) .. name):find("Pro", 1, true) ~= nil
        i.isAD5X = not i.isC5 and name:upper() == "AD5X"
        i.isPro = not i.isC5 and not i.isAD5X and name:find("Pro", 1, true) ~= nil
    end
    i.model = M.MODELS[pid] or (str(d.model) ~= "" and str(d.model)) or name
    if i.name == "" then i.name = i.model end
    i.status = str(d.status)
    i.state = M.state(d.status)
    i.progress = math.max(0, math.min(1, num(d.printProgress)))
    i.layer, i.layers = num(d.printLayer), num(d.targetPrintLayer)
    i.elapsed, i.left = num(d.printDuration), num(d.estimatedTime)
    i.file = str(d.printFileName)
    i.thumbUrl = str(d.printFileThumbUrl)
    i.nozzle = temp(d.rightTemp, d.rightTargetTemp)
    i.tools = {}
    local temps, sets = list(d.nozzleTemps), list(d.nozzleTargetTemps)
    for k, t in ipairs(temps) do i.tools[k] = temp(t, sets[k]) end
    if #i.tools > 0 then i.nozzle = i.tools[1] end
    i.bed = temp(d.platTemp, d.platTargetTemp)
    -- The heated chamber: only when reported (no chamber reads -108 on a Creator 5).
    local ct = tonumber(d.chamberTemp)
    if ct and ct > -50 then i.chamber = temp(ct, d.chamberTargetTemp) end
    i.light = d.lightStatus == "open"
    i.internalFan, i.externalFan = d.internalFanStatus == "open", d.externalFanStatus == "open"
    i.filtration = i.externalFan and "external" or i.internalFan and "internal" or "off"
    -- (by model: the printers' own capability report isn't to be trusted for this)
    i.hasFiltration = i.isPro or i.isC5Pro
    i.door = d.doorStatus == "open"
    i.hasDoor = i.isC5Pro
    i.error = errorCode(d.errorCode)
    i.tvoc = (i.isPro or i.isC5Pro) and tonumber(d.tvoc) or nil
    i.speed = num(d.printSpeedAdjust)
    i.zOffset = num(d.zAxisCompensation)
    i.coolingFan, i.chamberFan = num(d.coolingFanSpeed), num(d.chamberFanSpeed)
    i.filament = str(d.rightFilamentType)
    i.firmware = str(d.firmwareVersion)
    i.ip = str(d.ipAddr)
    i.nozzleSize = str(d.nozzleModel)
    i.disk = tonumber(d.remainingDiskSpace)
    i.totalMinutes = num(d.cumulativePrintTime)
    i.totalFilament = num(d.cumulativeFilament)
    i.weight = num(d.estimatedRightWeight)
    i.length = num(d.estimatedRightLen)
    i.camera = tonumber(d.camera) == 1 or str(d.cameraStreamUrl) ~= ""
    local st = type(d.matlStationInfo) == "table" and d.matlStationInfo or nil
    i.slots = M.slots(st)
    i.currentSlot = st and num(st.currentSlot) or 0
    i.hasStation = d.hasMatlStation == true or #i.slots > 0 or (st and num(st.slotCnt) > 0) or false
    return i
end

-- ------------------------------------------------------------------ as text

--- "1 h 5 min", "12 min", "Under a minute".
function M.duration(s)
    s = math.max(0, math.floor(num(s)))
    if s < 60 then return _("Under a minute") end
    local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
    if h == 0 then return T(_("%1 min"), m) end
    if m == 0 then return T(_("%1 h"), h) end
    return T(_("%1 h %2 min"), h, m)
end

--- "212 / 220 °C", or "24 °C" with nothing set.
function M.temp(t)
    if not t then return "" end
    local cur = math.floor(num(t.cur) + 0.5)
    if num(t.set) > 0 then return T("%1 / %2 °C", cur, math.floor(num(t.set) + 0.5)) end
    return T("%1 °C", cur)
end

--- The time as KOReader shows it ("2:35 PM" or "14:35"). date: os.date (tests pass their own).
function M.clock(t, twentyFour, date)
    date = date or os.date
    local s = date(twentyFour and "%H:%M" or "%I:%M %p", t)
    if not twentyFour then s = s:gsub("^0", "") end
    return s
end

--- "42%".
function M.percent(p)
    return T("%1%", math.floor(num(p) * 100 + 0.5))
end

--- A Material Station slot or a tool's colour, in words (the screen is grey).
local COLORS = {
    { _("Black"), 0, 0, 0 }, { _("White"), 255, 255, 255 }, { _("Grey"), 128, 128, 128 },
    { _("Silver"), 192, 192, 192 }, { _("Red"), 220, 30, 30 }, { _("Orange"), 255, 140, 0 },
    { _("Yellow"), 250, 220, 30 }, { _("Green"), 40, 170, 60 }, { _("Blue"), 30, 90, 220 },
    { _("Light blue"), 120, 190, 240 }, { _("Purple"), 130, 50, 180 }, { _("Pink"), 245, 130, 190 },
    { _("Brown"), 120, 75, 40 }, { _("Beige"), 225, 200, 160 },
}

local function rgb(hex)
    local r, g, b = str(hex):match("^#?(%x%x)(%x%x)(%x%x)$")
    if not r then return nil end
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

function M.colorName(hex)
    local r, g, b = rgb(hex)
    if not r then return "" end
    local best, bestD
    for __, c in ipairs(COLORS) do
        local d = (r - c[2]) ^ 2 * 0.3 + (g - c[3]) ^ 2 * 0.59 + (b - c[4]) ^ 2 * 0.11
        if not bestD or d < bestD then best, bestD = c[1], d end
    end
    return best
end

--- A colour as a grey for the e-ink screen (0 black .. 255 white); nil when it isn't a colour.
function M.grey(hex)
    local r, g, b = rgb(hex)
    if not r then return nil end
    return math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
end

--- "PLA · Red", "PETG", "Empty".
function M.slotText(s)
    if not s or s.empty then return _("Empty") end
    local c = M.colorName(s.color)
    return c ~= "" and (s.material .. " · " .. c) or s.material
end

--- The lines under the print's state: layers, time left and when it's done,
-- how long it has printed. now, twentyFour, date: for the time.
function M.jobLines(i, now, twentyFour, date)
    local out = {}
    if not i or not M.active(i.state) then return out end
    if i.layers > 0 then table.insert(out, T(_("Layer %1 of %2"), i.layer, i.layers)) end
    if i.left > 0 then
        local line = T(_("%1 left"), M.duration(i.left))
        -- (when it will be done only while it really advances: the printer stops counting down otherwise)
        if i.state == "printing" then
            line = line .. " · " .. T(_("done at %1"), M.clock((now or os.time()) + i.left, twentyFour, date))
        end
        table.insert(out, line)
    end
    if i.elapsed > 0 then table.insert(out, T(_("Printing for %1"), M.duration(i.elapsed))) end
    return out
end

--- The big line: "Printing · 42%", "Paused · 42%", "Error E0012", "Ready".
function M.summary(i)
    if not i then return "" end
    local s = M.stateText(i.state)
    if M.active(i.state) and i.state ~= "heating" then return s .. " · " .. M.percent(i.progress) end
    if i.state == "error" and i.error then return T(_("Error %1"), i.error) end
    return s
end

--- The launcher tile's line: "Printing 42% · 1 h 5 min left", "Paused · 42%",
-- "Ready"; nil i: not read yet (`set`: whether a printer is set up).
function M.appsLine(i, set)
    if not set then return _("No printer set up") end
    if not i then return _("Open to read the printer") end
    if i.state == "printing" and i.left > 0 then
        return T(_("Printing %1 · %2 left"), M.percent(i.progress), M.duration(i.left))
    end
    return M.summary(i)
end

--- "12 h 30 min" of lifetime print time (the printer counts minutes).
function M.lifetime(minutes)
    return M.duration(num(minutes) * 60)
end

-- ------------------------------------------------------------------ the recent files

--- /gcodeList's answer as files: { { name, time, weight, tools = { { id, material,
-- color, weight, slot } }, toolCount } }. Only the AD5X sends the details
-- (gcodeListDetail); every other model sends bare names, and then `tools` is
-- empty and `known` false (a file that may still use several materials).
function M.files(resp)
    resp = type(resp) == "table" and resp or {}
    local out = {}
    local entries = list(resp.gcodeListDetail)
    if #entries == 0 then entries = list(resp.gcodeList) end
    for __, e in ipairs(entries) do
        if type(e) == "string" then
            table.insert(out, { name = e, tools = {}, known = false })
        elseif type(e) == "table" and str(e.gcodeFileName) ~= "" then
            local f = { name = str(e.gcodeFileName), time = tonumber(e.printingTime), weight = tonumber(e.totalFilamentWeight),
                toolCount = tonumber(e.gcodeToolCnt), tools = {}, known = e.gcodeToolDatas ~= nil }
            for __, t in ipairs(list(e.gcodeToolDatas)) do
                table.insert(f.tools, { id = num(t.toolId), material = str(t.materialName), color = str(t.materialColor),
                    weight = num(t.filamentWeight), slot = num(t.slotId) })
            end
            if f.time == 0 then f.time = nil end
            table.insert(out, f)
        end
    end
    return out
end

--- A file's second line: "1 h 20 min · 35 g · 2 materials".
function M.fileLine(f)
    local parts = {}
    if f.time then table.insert(parts, M.duration(f.time)) end
    if f.weight and f.weight > 0 then table.insert(parts, T(_("%1 g"), math.floor(f.weight + 0.5))) end
    if #f.tools > 1 then table.insert(parts, T(_("%1 materials"), #f.tools))
    elseif #f.tools == 1 and f.tools[1].material ~= "" then table.insert(parts, f.tools[1].material) end
    return table.concat(parts, " · ")
end

-- ------------------------------------------------------------------ material matching

--- A material name folded for comparing.
function M.norm(s)
    return (str(s):gsub("^%s+", ""):gsub("%s+$", ""):lower())
end

function M.isHex(s)
    return str(s):match("^#%x%x%x%x%x%x$") ~= nil
end

local function colorOr(s)
    return M.isHex(s) and s or M.FALLBACK_COLOR
end

--- Whether starting this file means mapping its tools to slots: both its
-- tools and a reporting Material Station are known (the AD5X; a single tool
-- too, since it still has to be told which slot).
function M.needsMatching(file, slots)
    return #(slots or {}) > 0 and #(file and file.tools or {}) > 0
end

--- One mapping, as the printer takes it.
function M.mapping(tool, slot)
    local material = tool.material ~= "" and tool.material or slot.material
    return { toolId = tool.id, slotId = slot.id, materialName = (material:gsub("^%s+", ""):gsub("%s+$", "")),
        toolMaterialColor = colorOr(tool.color), slotMaterialColor = colorOr(slot.color) }
end

--- A suggested mapping ({ [tool id] = slot id }) to start from, best effort:
-- per tool, among free slots with its material, the slicer's own slot, then
-- the same colour, then the first. Tools it can't place are left out.
function M.autoMatch(file, slots)
    local out, taken = {}, {}
    for __, t in ipairs(file.tools) do
        local want = M.norm(t.material)
        if want ~= "" then
            local candidates = {}
            for __, s in ipairs(slots) do
                if not s.empty and not taken[s.id] and M.norm(s.material) == want then table.insert(candidates, s) end
            end
            local chosen
            for __, s in ipairs(candidates) do if s.id == t.slot then chosen = s break end end
            if not chosen and M.norm(t.color) ~= "" then
                for __, s in ipairs(candidates) do if M.norm(s.color) == M.norm(t.color) then chosen = s break end end
            end
            chosen = chosen or candidates[1]
            if chosen then
                taken[chosen.id] = true
                out[t.id] = chosen.id
            end
        end
    end
    return out
end

--- Why a tool can't use a slot (nil when it can). chosen: { [tool id] = slot id }.
function M.slotProblem(tool, slot, chosen)
    if not slot then return _("Not in the Material Station") end
    if slot.empty then return _("Empty") end
    for tid, sid in pairs(chosen or {}) do
        if sid == slot.id and tid ~= tool.id then return T(_("Used by tool %1"), tid + 1) end
    end
    if M.norm(tool.material) ~= M.norm(slot.material) then
        return T(_("%1, not %2"), slot.material, tool.material ~= "" and tool.material or _("this material"))
    end
end

--- The mappings to send for chosen ({ [tool id] = slot id }), checked against
-- the file and the slots as the printer reports them now; nil and why when
-- they can't be sent.
function M.validate(file, slots, chosen)
    local byId = {}
    for __, s in ipairs(slots) do byId[s.id] = s end
    local out, used = {}, {}
    for __, t in ipairs(file.tools) do
        local sid = chosen[t.id]
        if not sid then return nil, T(_("Choose a slot for tool %1."), t.id + 1) end
        local s = byId[sid]
        if not s then return nil, T(_("Slot %1 isn't in the Material Station."), sid) end
        if used[sid] then return nil, T(_("Slot %1 is used by two tools."), sid) end
        used[sid] = true
        if s.empty then return nil, T(_("Slot %1 is empty. Load filament before starting this print."), sid) end
        if M.norm(t.material) ~= M.norm(s.material) then
            return nil, T(_("Tool %1 needs %2, but slot %3 has %4."), t.id + 1,
                t.material ~= "" and t.material or _("an unknown material"), sid, s.material ~= "" and s.material or _("nothing"))
        end
        table.insert(out, M.mapping(t, s))
    end
    for tid in pairs(chosen) do
        local found = false
        for __, t in ipairs(file.tools) do if t.id == tid then found = true end end
        if not found then return nil, T(_("This file has no tool %1."), tid + 1) end
    end
    return out
end

--- The mappings whose colours differ (they print, in another colour): one line each.
function M.colorWarnings(mappings)
    local out = {}
    for __, m in ipairs(mappings) do
        if M.norm(m.toolMaterialColor) ~= M.norm(m.slotMaterialColor) then
            table.insert(out, T(_("Tool %1 was sliced for %2, slot %3 holds %4."), m.toolId + 1,
                M.colorName(m.toolMaterialColor), m.slotId, M.colorName(m.slotMaterialColor)))
        end
    end
    return out
end

-- ------------------------------------------------------------------ requests

--- Whether a 5M's firmware takes the newer print request (3.1.3 and later).
function M.newFirmware(v)
    local want = { 3, 1, 3 }
    local parts = {}
    for n in str(v):gmatch("%d+") do table.insert(parts, tonumber(n)) end
    if #parts == 0 then return false end
    for k = 1, 3 do
        local cur = parts[k] or 0
        if cur > want[k] then return true end
        if cur < want[k] then return false end
    end
    return true
end

--- The body of /printGcode for a file already on the printer (without the
-- serial number and check code, which the request adds), as each model wants it.
-- mappings: from M.validate (none for a single material).
function M.printBody(i, fileName, leveling, mappings)
    mappings = mappings or {}
    local b = { fileName = fileName, levelingBeforePrint = leveling and true or false }
    if i.isC5 then
        b.flowCalibration, b.timeLapseVideo = false, false
        if #mappings > 0 then b.materialMappings = mappings end
    elseif i.isAD5X then
        b.firstLayerInspection, b.flowCalibration, b.timeLapseVideo = false, false, false
        b.useMatlStation = #mappings > 0
        b.gcodeToolCnt = #mappings
        b.materialMappings = mappings
    elseif M.newFirmware(i.firmware) then
        b.flowCalibration, b.useMatlStation, b.gcodeToolCnt, b.materialMappings = false, false, 0, {}
    end
    return b
end

--- /control's args for a filtration mode ("off", "internal", "external").
function M.filtrationArgs(mode)
    return { internal = mode == "internal" and "open" or "close", external = mode == "external" and "open" or "close" }
end

local FILTRATION_TEXT = { off = _("Off"), internal = _("Internal"), external = _("External") }
function M.filtrationText(mode) return FILTRATION_TEXT[mode] or FILTRATION_TEXT.off end

--- A check code as shown: its last two characters ("••••••12").
function M.masked(s)
    s = str(s)
    if #s <= 2 then return s ~= "" and "••" or "" end
    return string.rep("•", #s - 2) .. s:sub(-2)
end

--- An IPv4 address (four numbers 0..255).
function M.isIp(s)
    local a, b, c, d = str(s):match("^%s*(%d+)%.(%d+)%.(%d+)%.(%d+)%s*$")
    if not a then return false end
    for __, n in ipairs({ a, b, c, d }) do if tonumber(n) > 255 then return false end end
    return true
end

-- ------------------------------------------------------------------ discovery

local function be16(s, at)
    local hi, lo = s:byte(at + 1, at + 2)
    return (hi or 0) * 256 + (lo or 0)
end

local function cstr(s)
    return (s:match("^([^%z]*)") or "")
end

--- A printer's answer to the discovery broadcast: { name, ip, serial, pid,
-- model, supported }, or nil. Modern printers answer with 276 bytes (name,
-- ports, product ID, serial number); older ones with 140 (no HTTP API).
function M.parseDiscovery(buf, ip)
    if type(buf) ~= "string" then return nil end
    if #buf >= 276 then
        local pid = be16(buf, 0x88)
        local p = { name = cstr(buf:sub(1, 0x84)), ip = ip, pid = pid, serial = cstr(buf:sub(0x93, 0x92 + 128)) }
        p.supported = M.MODELS[pid] ~= nil
        p.model = M.MODELS[pid] or p.name
        return p
    elseif #buf >= 140 then
        local p = { name = cstr(buf:sub(1, 0x80)), ip = ip, pid = be16(buf, 0x88), serial = "", supported = false }
        p.model = p.name
        return p
    end
end

return M
