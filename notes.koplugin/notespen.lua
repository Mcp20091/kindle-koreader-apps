--[[--
The pen, read straight from its digitizer (on the Kindle Scribe the
"WacomDigitizer" input device), not through KOReader's touch handling: a
resting palm on the touch panel then cannot mix with the pen, and pressure
comes along.

The digitizer reports X, Y and pressure in its own units (Scribe: X 0-15624,
Y 0-20832, pressure 0-4095), with BTN_TOOL_PEN or BTN_TOOL_RUBBER (the
eraser end) while near, BTN_TOUCH while touching and BTN_STYLUS for the side
button. Its axes are the screen's (measured: screen = digitizer * screen /
range, to under a pixel).

Pen.parse is plain Lua (tested); Pen.open and Pen:read need KOReader's ffi.
]]

local Pen = {}
Pen.__index = Pen

local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local SYN_REPORT, SYN_DROPPED = 0, 3
local ABS_X, ABS_Y, ABS_PRESSURE = 0, 1, 24
local BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH, BTN_STYLUS = 320, 321, 330, 331

--- A parser's state: what the pen is doing between reports.
function Pen.newState()
    return { x = nil, y = nil, pressure = 0, tool = nil, touching = false, side = false, down = false }
end

--- One digitizer event into `state`. On a report (SYN_REPORT) returns what
-- happened, in digitizer units: { kind = "down"|"move"|"up", x, y, pressure,
-- eraser (rubber or side), rubber (the eraser end), side (the side button
-- held), time } or nil. `time` is the event's time in milliseconds.
function Pen.parse(state, evType, code, value, time)
    if evType == EV_ABS then
        if code == ABS_X then state.x = value
        elseif code == ABS_Y then state.y = value
        elseif code == ABS_PRESSURE then state.pressure = value end
        return nil
    end
    if evType == EV_KEY then
        -- (The pen or the eraser end taken away: no tool, unless the other one came.)
        if code == BTN_TOOL_PEN then
            if value ~= 0 then state.tool = "pen" elseif state.tool == "pen" then state.tool = nil end
        elseif code == BTN_TOOL_RUBBER then
            if value ~= 0 then state.tool = "rubber" elseif state.tool == "rubber" then state.tool = nil end
        elseif code == BTN_TOUCH then state.touching = value ~= 0
        elseif code == BTN_STYLUS then state.side = value ~= 0 end
        return nil
    end
    if evType ~= EV_SYN then return nil end
    if code == SYN_DROPPED then
        -- The kernel dropped events: whatever was being drawn ends here.
        state.dropped = true
        return nil
    end
    if code ~= SYN_REPORT then return nil end
    local touching = state.touching and state.tool ~= nil and state.x ~= nil and state.y ~= nil
    local out
    if touching and (not state.down or state.dropped) then
        out = { kind = state.down and "restart" or "down" }
        state.down = true
    elseif touching then
        out = { kind = "move" }
    elseif state.down then
        state.down = false
        out = { kind = "up" }
    end
    state.dropped = false
    if not out then return nil end
    out.x, out.y, out.pressure, out.time = state.x, state.y, state.pressure, time
    out.rubber = state.tool == "rubber"
    out.side = state.side
    out.eraser = out.rubber or out.side
    return out
end

-- ------------------------------------------------------------------ the device (KOReader)

--- The digitizer's event file from /proc/bus/input/devices, or nil.
function Pen.findDevice(name)
    local file = io.open("/proc/bus/input/devices", "r")
    if not file then return nil end
    local current, path
    for line in file:lines() do
        current = line:match('^N: Name="(.*)"') or current
        local handler = line:match("^H: Handlers=.-(event%d+)")
        if handler and current == (name or "WacomDigitizer") and not path then path = "/dev/input/" .. handler end
    end
    file:close()
    return path
end

--- Opens the digitizer for reading (not grabbing it: the system keeps it).
-- Returns a reader, or nil and why.
function Pen.open(path)
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil, "no ffi" end
    local bit = require("bit")
    local C = ffi.C
    pcall(require, "ffi/posix_h")
    pcall(require, "ffi/linux_input_h")
    pcall(ffi.cdef, "struct notes_absinfo { int32_t value, minimum, maximum, fuzz, flat, resolution; };")
    path = path or Pen.findDevice()
    if not path then return nil, "no pen digitizer" end
    local fd = C.open(path, bit.bor(C.O_RDONLY, C.O_NONBLOCK))
    if fd < 0 then return nil, "cannot open " .. path end
    local self = setmetatable({}, Pen)
    self.ffi, self.C, self.fd, self.path = ffi, C, fd, path
    self.size = ffi.sizeof("struct input_event")
    self.buf = ffi.new("struct input_event[128]")
    self.state = Pen.newState()
    -- Ranges (EVIOCGABS = _IOR('E', 0x40 + axis, 24 bytes)).
    local function range(axis, fallback)
        local info = ffi.new("struct notes_absinfo")
        local okIoctl, rc = pcall(C.ioctl, fd, bit.tobit(0x80184540 + axis), info)
        if okIoctl and rc >= 0 and info.maximum > info.minimum then return info.minimum, info.maximum end
        return 0, fallback
    end
    self.minX, self.maxX = range(ABS_X, 15624)
    self.minY, self.maxY = range(ABS_Y, 20832)
    self.minP, self.maxP = range(ABS_PRESSURE, 4095)
    return self
end

--- The pen's state read again from the digitizer (after events were
-- dropped, the lifting of the pen may have been among them). True when it
-- could be read.
function Pen:resync()
    local bit = require("bit")
    local keys = self.ffi.new("uint8_t[96]")
    local ok, rc = pcall(self.C.ioctl, self.fd, bit.tobit(0x80604518), keys)   -- EVIOCGKEY(96)
    if not ok or rc < 0 then return false end
    local function on(code) return bit.band(keys[math.floor(code / 8)], bit.lshift(1, code % 8)) ~= 0 end
    local st = self.state
    st.tool = on(BTN_TOOL_RUBBER) and "rubber" or (on(BTN_TOOL_PEN) and "pen" or nil)
    st.touching = on(BTN_TOUCH)
    st.side = on(BTN_STYLUS)
    for axis, key in pairs({ [ABS_X] = "x", [ABS_Y] = "y", [ABS_PRESSURE] = "pressure" }) do
        local info = self.ffi.new("struct notes_absinfo")
        local okA, rcA = pcall(self.C.ioctl, self.fd, bit.tobit(0x80184540 + axis), info)
        if okA and rcA >= 0 then st[key] = info.value end
    end
    return true
end

--- Everything the digitizer has sent since the last read, as parsed
-- events (in digitizer units). When the system dropped events (KOReader
-- busy, a palm on the screen), the pen's state is read again, and a lift
-- that was dropped still comes as "up".
function Pen:read()
    local out = {}
    local dropped = false
    for _ = 1, 64 do
        local n = tonumber(self.C.read(self.fd, self.buf, self.size * 128))
        if not n or n <= 0 then break end
        for i = 0, math.floor(n / self.size) - 1 do
            local ev = self.buf[i]
            local time = tonumber(ev.time.tv_sec) * 1000 + math.floor(tonumber(ev.time.tv_usec) / 1000)
            if tonumber(ev.type) == EV_SYN and tonumber(ev.code) == SYN_DROPPED then dropped = true end
            local event = Pen.parse(self.state, tonumber(ev.type), tonumber(ev.code), tonumber(ev.value), time)
            if event then table.insert(out, event) end
        end
    end
    if dropped then
        local st = self.state
        local wasDown = st.down
        if self:resync() then
            st.dropped = false
            local touching = st.touching and st.tool ~= nil
            if wasDown and not touching then
                st.down = false
                table.insert(out, { kind = "up", x = st.x, y = st.y, pressure = st.pressure, rubber = st.tool == "rubber",
                    side = st.side, eraser = st.tool == "rubber" or st.side })
            end
        end
        self.drops = (self.drops or 0) + 1
        require("logger").info("Notes: pen events were dropped; pen read again", self.drops, wasDown and "(was down)" or "")
    end
    return out
end

function Pen:close()
    if self.fd and self.fd >= 0 then self.C.close(self.fd) end
    self.fd = nil
end

--- The pen's buttons as they are now, asked of the digitizer once (EVIOCGKEY):
-- { side, tool = "pen"|"rubber"|nil, touching, path }, or nil and why. The device is
-- opened for this one question and closed again; no events are read, so the writing
-- path isn't touched. (A selection made in a book: noteshandnote.lua.)
function Pen.held(path)
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil, "no ffi" end
    local bit = require("bit")
    pcall(require, "ffi/posix_h")
    local C = ffi.C
    path = path or Pen.findDevice()
    if not path then return nil, "no pen digitizer" end
    local fd = C.open(path, bit.bor(C.O_RDONLY, C.O_NONBLOCK))
    if fd < 0 then return nil, "cannot open " .. path end
    local keys = ffi.new("uint8_t[96]")
    local okIoctl, rc = pcall(C.ioctl, fd, bit.tobit(0x80604518), keys)   -- EVIOCGKEY(96)
    C.close(fd)
    if not okIoctl or rc < 0 then return nil, "cannot ask " .. path end
    local function on(code) return bit.band(keys[math.floor(code / 8)], bit.lshift(1, code % 8)) ~= 0 end
    return { side = on(BTN_STYLUS), tool = on(BTN_TOOL_RUBBER) and "rubber" or (on(BTN_TOOL_PEN) and "pen" or nil),
        touching = on(BTN_TOUCH), path = path }
end

--- Whether a touch KOReader hands over as the pen's is a finger. While the
-- pen hovers, KOReader files a finger touching the screen in the pen's slot;
-- the pen's own contact has the pen slot's number as its id, a finger has
-- the touch panel's tracking id.
function Pen.isFinger(slot, penSlot)
    local id = slot and slot.id
    return id ~= nil and id ~= -1 and penSlot ~= nil and id ~= penSlot
end

return Pen
