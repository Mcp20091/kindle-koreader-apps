--[[--
Handwriting input for every app: a strip at the bottom of the screen to write
in with the pen (or a finger), read by the AI into text for a text box. The
apps reach it through PluginShare (set up in main.lua):

    PS.handwriting.available()      -- an AI that reads handwriting is set up
    PS.handwriting.write({ title, hint, kind = "text" | "task" | "command" | "name", multiline },
        function(text, extra) ... end)   -- text nil: closed, or nothing read
        -- (kind "task": extra = { due = "YYYY-MM-DD", remind = { date, minute } })
    PS.handwriting.button(function() return dialog end, opts)   -- a Write it
        -- button for a KOReader InputDialog: what was written goes into it

The pen is read from its digitizer (appspen.lua) when there is one, else
through KOReader's stylus callback, else as touches (a finger, the emulator's
mouse). What is written is sent as a picture with the instructions of
"Handwriting input" (Settings > AI > Advanced), in a child process.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("appscanvas")

local Screen = Device.screen
local C = Canvas

local HW = {}

-- What each kind adds to the instructions (fixed: the answer's form).
local KIND = {
    text = "",
    name = " It is a short name or title.",
    command = " It is a command for a Linux shell: keep every character, space and symbol exactly (no curly quotes).",
}
local TASK = [[ It is one to-do item. Today is %s. When a date or time is written with it ("Fri", "tomorrow", "10/25", "3pm", "remind 9am Thu"), take it out of the title. Reply with JSON only: {"title":"...","due":"YYYY-MM-DD" or null,"remind":"YYYY-MM-DDTHH:MM" or null}. A time on its own is a reminder on the due date (today when there is none).]]

-- ------------------------------------------------------------------ the strip

local Pad = InputContainer:extend{
    title = nil,
    done = nil,      -- fn(png) or fn(nil) when cancelled
}

local PEN_W = 4      -- the line's width, in pixels at 300 dpi

function Pad:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local ph = math.floor(self.h * 0.3)
    -- Where it was last moved to (its top, as a share of the screen), else at the bottom.
    local top = G_reader_settings:readSetting("apps_handwrite_top")
    local y = type(top) == "number" and math.floor(top * self.h) or (self.h - ph)
    self.strip = { x = 0, y = math.max(0, math.min(self.h - ph, y)), w = self.w, h = ph }
    self.handle = math.floor(ph * 0.12)     -- the band on top to drag it by
    self.bw = math.floor(math.min(self.w, self.h) * 0.16)     -- the buttons' column
    self.bb = Blitbuffer.new(self.w, ph, Blitbuffer.TYPE_BB8)
    self.strokes = {}
    self.width = math.max(2, math.floor(PEN_W * Screen:getDPI() / 300 + 0.5))
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    -- (Touches: a finger, or the pen where KOReader hands it over as one.)
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = all } },
        Touch = { GestureRange:new{ ges = "touch", range = all } },
        Pan = { GestureRange:new{ ges = "pan", range = all } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = all } },
        Hold = { GestureRange:new{ ges = "hold", range = all } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    self:drawStrip()
end

-- The buttons: Cancel, Clear, Done (the main one), as the shared pop-ups' (icon over label).
function Pad:buttons()
    local s, bw = self.strip, self.bw
    local x = s.w - bw
    local list = {
        { icon = "x", text = _("Cancel"), fn = function() self:finish(false) end },
        { icon = "rotate-ccw", text = _("Clear"), fn = function() self:clear() end },
        { icon = "check", text = _("Done"), primary = true, fn = function() self:finish(true) end },
    }
    local gap = math.floor(s.h * 0.03)
    local bh = math.floor((s.h - gap * (#list + 1)) / #list)
    local out = {}
    for i, b in ipairs(list) do
        b.x, b.y, b.w, b.h = x + gap, gap + (i - 1) * (bh + gap), bw - 2 * gap, bh
        table.insert(out, b)
    end
    return out
end

-- The strip without the writing: white, a line on top, the hint, the buttons.
function Pad:drawStrip()
    local bb, s = self.bb, self.strip
    bb:fill(Blitbuffer.COLOR_WHITE)
    bb:paintRect(0, 0, s.w, math.max(2, math.floor(s.h / 140)), Blitbuffer.COLOR_BLACK)
    bb:paintRect(0, s.h - math.max(2, math.floor(s.h / 140)), s.w, math.max(2, math.floor(s.h / 140)), Blitbuffer.COLOR_BLACK)
    bb:paintRect(s.w - self.bw, 0, 1, s.h, Blitbuffer.COLOR_GRAY)
    -- (Drawn with the launcher's canvas, at the strip's size.)
    local c = Canvas.new(s.w, s.h, false)
    -- (The screen's units, not the strip's: sizes as in every pop-up.)
    c.u = math.min(self.w, self.h) / 620
    c.W, c.H = s.w / c.u, s.h / c.u
    -- The handle (drag it to move the strip up or down), then what to write.
    local hw = (s.w - self.bw) / c.u
    c:box(hw / 2 - 30, self.handle / c.u / 2 - 3, 60, 6, { r = 3, fill = C.MID })
    c:text(14, self.handle / c.u + 20, self.title or _("Write here"), 11, { color = C.GREY })
    -- (Button labels off in the launcher's settings: just the icons.)
    local withLabels = require("appspopup").labels()
    for __, b in ipairs(self:buttons()) do
        local bx, by, bw2, bh = b.x / c.u, b.y / c.u, b.w / c.u, b.h / c.u
        c:box(bx, by, bw2, bh, { r = 12, fill = b.primary and C.FILL or C.WHITE, border = C.BLACK, bw = 1.2 })
        if withLabels then
            c:icon(b.icon, bx + bw2 / 2 - 11, by + bh / 2 - 20, 22, b.primary)
            c:text(bx + bw2 / 2, by + bh / 2 + 22, b.text, 10.5, { bold = true, align = "middle", maxw = bw2 - 6,
                color = b.primary and C.ON_FILL or C.BLACK })
        else
            c:icon(b.icon, bx + bw2 / 2 - 13, by + bh / 2 - 13, 26, b.primary)
        end
    end
    c:paint(bb, 0, 0)
    c:release()
    for __, st in ipairs(self.strokes) do self:drawStroke(st, 1) end
end

function Pad:stamp(x, y)
    local half = math.floor(self.width / 2)
    self.bb:paintRect(x - half, y - half - self.strip.y, self.width, self.width, Blitbuffer.COLOR_BLACK)
end

-- A stroke's segments from point `from` on (screen coordinates).
function Pad:drawStroke(st, from)
    local p = st.p
    if #p == 2 then return self:stamp(p[1], p[2]) end
    for i = math.max(1, from), #p - 3, 2 do
        local x0, y0, x1, y1 = p[i], p[i + 1], p[i + 2], p[i + 3]
        local dx, dy = x1 - x0, y1 - y0
        local steps = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(dy)) / math.max(1, self.width / 2)))
        for k = 0, steps do
            local t = k / steps
            self:stamp(math.floor(x0 + dx * t + 0.5), math.floor(y0 + dy * t + 0.5))
        end
    end
end

function Pad:paintTo(bb, x, y)
    local s = self.strip
    bb:blitFrom(self.bb, x + s.x, y + s.y, 0, 0, s.w, s.h)
end

function Pad:inWriting(x, y)
    local s = self.strip
    return y >= s.y + self.handle and y < s.y + s.h and x < s.w - self.bw
end

function Pad:inStrip(x, y)
    local s = self.strip
    return y >= s.y and y < s.y + s.h
end

-- The window under the strip (the box it writes into), past toasts.
function Pad:below()
    local stack, found = UIManager._window_stack or {}, false
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if found and not w.toast then return w end
        if w == self then found = true end
    end
end

local function shown(w)
    for __, e in ipairs(UIManager._window_stack or {}) do
        if e.widget == w then return true end
    end
    return false
end

-- Taps and touches off the strip (the pen's too) go to the box under it, so its
-- buttons and text work while the strip is up. When that box closes (its OK,
-- Cancel…), the strip goes with it.
function Pad:handleEvent(event)
    if event.handler == "onGesture" and not (self.stroke or self.drag or self.pressed) then
        local ges = event.args and event.args[1]
        local p = ges and ges.pos
        if p and not self:inStrip(p.x, p.y) then
            local w = self:below()
            if not w then return true end
            local r = w:handleEvent(event)
            UIManager:nextTick(function()
                if not self.closed and not shown(w) then self:finish(false) end
            end)
            return r
        end
    end
    return InputContainer.handleEvent(self, event)
end

function Pad:onHandle(x, y)
    local s = self.strip
    return y >= s.y and y < s.y + self.handle and x < s.w - self.bw
end

-- The button whose part of the column (x, y) is in: the whole column counts,
-- gaps and edges too, so a pen tap near a button still works it.
function Pad:buttonAt(x, y)
    local s = self.strip
    if x < s.w - self.bw or y < s.y or y >= s.y + s.h then return nil end
    local list = self:buttons()
    local i = math.min(#list, math.floor((y - s.y) / (s.h / #list)) + 1)
    return list[i]
end

-- A button worked (once: a pen tap may also come as a finger's tap).
function Pad:fire(b)
    local now = require("socket").gettime()
    if self.firedAt and now - self.firedAt < 0.4 then return end
    self.firedAt = now
    self.stroke, self.pressed = nil, nil
    b.fn()
end

-- The pen (or a finger): down, move, up, in screen coordinates. The pen
-- works a button as soon as it touches it; a finger on its tap (a hold on
-- Done: AI for this).
function Pad:down(x, y, pen)
    local b = self:buttonAt(x, y)
    if b then
        if pen then return self:fire(b) end
        self.pressed = b
        return
    end
    if self:onHandle(x, y) then
        self.drag = { from = y, top = self.strip.y }
        return
    end
    if not self:inWriting(x, y) then return end
    self.stroke = { p = { x, y } }
    table.insert(self.strokes, self.stroke)
    self:stamp(x, y)
    self:refresh(x, y, x, y)
end

function Pad:move(x, y)
    if self.drag then return self:dragTo(y) end
    local st = self.stroke
    if not st then return end
    y = math.max(self.strip.y + self.handle, y)
    x = math.min(self.strip.w - self.bw - 1, x)
    local p = st.p
    local lx, ly = p[#p - 1], p[#p]
    if math.abs(x - lx) + math.abs(y - ly) < 2 then return end
    table.insert(p, x)
    table.insert(p, y)
    self:drawStroke(st, #p - 3)
    self:refresh(lx, ly, x, y)
end

function Pad:up(x, y)
    if self.drag then
        if y then self:dragTo(y, true) end
        self.drag = nil
        -- (Remembered for next time.)
        G_reader_settings:saveSetting("apps_handwrite_top", self.strip.y / self.h)
        -- (A clean picture where it ends: e-ink leaves ghosts of the steps on the way.)
        UIManager:setDirty("all", "full")
    elseif self.stroke then
        self.stroke = nil
    elseif self.pressed then
        local b = self.pressed
        self.pressed = nil
        if x and y and self:buttonAt(x, y) == b then self:fire(b) end
    end
end

-- The strip moved with the handle (what was written moves with it), drawn
-- again now and then while dragging, and where it ends.
function Pad:dragTo(y, final)
    local d = self.drag
    local s = self.strip
    local to = math.max(0, math.min(self.h - s.h, d.top + y - d.from))
    local now = require("socket").gettime()
    if not final and (math.abs(to - s.y) < 12 or (d.at and now - d.at < 0.15)) then return end
    d.at = now
    local dy = to - s.y
    if dy == 0 then return end
    local before = Geom:new(s)
    for __, st in ipairs(self.strokes) do
        for i = 2, #st.p, 2 do st.p[i] = st.p[i] + dy end
    end
    s.y = to
    self:drawStrip()
    UIManager:setDirty("all", "ui", before:combine(Geom:new(s)))
end

-- Only what was just drawn, fast (as Notes draws ink).
function Pad:refresh(x0, y0, x1, y1)
    local pad = self.width + 4
    local x, y = math.min(x0, x1) - pad, math.min(y0, y1) - pad
    UIManager:setDirty(self, "fast", Geom:new{ x = x, y = y, w = math.abs(x1 - x0) + 2 * pad, h = math.abs(y1 - y0) + 2 * pad })
end

function Pad:clear()
    self.strokes, self.stroke = {}, nil
    self:drawStrip()
    UIManager:setDirty(self, "ui", Geom:new(self.strip))
end

--- Done (with what was written) or Cancel.
function Pad:finish(ok)
    if self.closed then return end
    if ok and #self.strokes == 0 then return end
    local png = ok and self:png() or nil
    self.closed = true
    UIManager:close(self, "full", Geom:new(self.strip))
    if self.done then self.done(png) end
end

-- What was written as a PNG: only its own area (and a margin), white behind.
function Pad:png()
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for __, st in ipairs(self.strokes) do
        for i = 1, #st.p, 2 do
            minX, maxX = math.min(minX, st.p[i]), math.max(maxX, st.p[i])
            minY, maxY = math.min(minY, st.p[i + 1]), math.max(maxY, st.p[i + 1])
        end
    end
    local m = 24
    local s = self.strip
    local x0, y0 = math.max(0, minX - m), math.max(0, minY - s.y - m)
    local x1, y1 = math.min(s.w - self.bw, maxX + m), math.min(s.h, maxY - s.y + m)
    local w, h = math.max(8, x1 - x0), math.max(8, y1 - y0)
    local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    out:fill(Blitbuffer.COLOR_WHITE)
    -- (Only the ink: the strip's own drawing is left out.)
    local ink = Blitbuffer.new(s.w, s.h, Blitbuffer.TYPE_BB8)
    ink:fill(Blitbuffer.COLOR_WHITE)
    local keep = self.bb
    self.bb = ink
    for __, st in ipairs(self.strokes) do self:drawStroke(st, 1) end
    self.bb = keep
    out:blitFrom(ink, 0, 0, x0, y0, w, h)
    ink:free()
    local dir = require("datastorage"):getDataDir() .. "/cache"
    require("util").makePath(dir)
    local path = dir .. "/handwriting-input.png"
    local ok = pcall(out.writePNG, out, path)
    out:free()
    if not ok then return nil end
    local f = io.open(path, "rb")
    local bytes = f and f:read("*a")
    if f then f:close() end
    os.remove(path)
    return bytes
end

-- Touches (a finger; the pen when it comes this way).
function Pad:onTouch(_, ges) if not self.penReader then self:down(ges.pos.x, ges.pos.y) end return true end
function Pad:onPan(_, ges)
    if self.penReader then return true end
    if not self.stroke and not self.pressed and not self.drag then self:down(ges.pos.x, ges.pos.y) end
    self:move(ges.pos.x, ges.pos.y)
    return true
end
function Pad:onPanRelease(_, ges) if not self.penReader then self:up(ges.pos.x, ges.pos.y) end return true end
function Pad:onHoldRelease(_, ges) if not self.penReader then self:up(ges.pos.x, ges.pos.y) end return true end
function Pad:onHold(_, ges)
    -- A finger held on Done: AI for this (the service and model that read it).
    local b = ges and ges.pos and self:buttonAt(ges.pos.x, ges.pos.y)
    if b and b.primary then
        self.pressed = nil
        local ai = require("pluginshare").ai
        if ai and ai.quickPick then ai.quickPick("handwriting") end
    end
    return true
end
function Pad:onSwipe(_, ges)
    if not self.penReader and self.stroke then self:move(ges.pos.x, ges.pos.y) self:up() end
    return true
end
function Pad:onTap(_, ges)
    -- A finger's tap on a button (the pen's come from its digitizer).
    local b = self:buttonAt(ges.pos.x, ges.pos.y)
    if b then
        self:fire(b)
    elseif not self.penReader then
        self:up(ges.pos.x, ges.pos.y)
    end
    return true
end
function Pad:onClose() self:finish(false) return true end

-- ------------------------------------------------------------------ the pen

-- A digitizer point on the screen as it is turned (as Notes' editor does).
function Pad:penPoint(dx, dy)
    local pen = self.penReader
    local mode = Screen.getTouchRotation and Screen:getTouchRotation() or Screen:getRotationMode()
    local nw, nh = self.w, self.h
    if mode % 2 == 1 then nw, nh = self.h, self.w end
    local nx = (dx - pen.minX) * nw / (pen.maxX - pen.minX)
    local ny = (dy - pen.minY) * nh / (pen.maxY - pen.minY)
    local x, y = nx, ny
    if mode == 1 then x, y = self.w - ny, nx
    elseif mode == 3 then x, y = ny, self.h - nx
    elseif mode == 2 then x, y = self.w - nx, self.h - ny end
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

function Pad:poll()
    local pen = self.penReader
    if not pen or self.closed then return end
    for __, ev in ipairs(pen:read()) do
        local x, y = self:penPoint(ev.x or 0, ev.y or 0)
        if ev.kind == "down" or ev.kind == "restart" then
            if self.stroke then self:up() end
            self:down(x, y, true)
        elseif ev.kind == "move" then
            self:move(x, y)
        elseif ev.kind == "up" then
            self:up(x, y)
        end
        if self.closed then return end
    end
    UIManager:scheduleIn(pen.state.tool ~= nil and 0.01 or 0.05, self.pollTask)
end

function Pad:onShow()
    local input = Device.input
    local Pen = require("appspen")
    local pen = Pen.open()
    if pen then
        self.penReader = pen
        self.pollTask = function() self:poll() end
        UIManager:scheduleIn(0.01, self.pollTask)
    end
    -- KOReader's own pen events: kept from the screens under the strip
    -- (with the digitizer read here) or drawn with (without it).
    if type(input.registerStylusCallback) == "function" then
        self.prevStylus = input.stylus_callback
        self.stylusHook = function(inp, slot)
            if Pen.isFinger(slot, inp.pen_slot) then return false end
            if UIManager:getTopmostVisibleWidget() ~= self then return false end
            -- (Writing is use: KOReader's dimmer and sleep timer told, once a second at most;
            -- these pen events are kept from its gestures, so it wouldn't see them.)
            local now = os.time()
            if now ~= self.activeAt and UIManager.event_hook then
                self.activeAt = now
                UIManager.event_hook:execute("InputEvent")
            end
            -- A pen touch that starts off the strip is KOReader's (a tap on the box above).
            if slot.id == -1 then
                local off = self.penOff
                self.penOff = nil
                if off then return false end
            elseif self.penOff then
                return false
            elseif slot.x and slot.y and not (self.stroke or self.drag or self.pressed) and not self:inStrip(slot.x, slot.y) then
                self.penOff = true
                return false
            end
            if self.penReader then return true end
            if slot.id == -1 then self:up(self.lastX, self.lastY) return true end
            if not slot.x or not slot.y then return true end
            self.lastX, self.lastY = slot.x, slot.y
            if not self.stroke and not self.pressed and not self.drag then self:down(slot.x, slot.y, true) else self:move(slot.x, slot.y) end
            return true
        end
        input:registerStylusCallback(self.stylusHook)
    end
    UIManager:setDirty(self, "ui", Geom:new(self.strip))
end

function Pad:onCloseWidget()
    self.closed = true
    if self.pollTask then UIManager:unschedule(self.pollTask) end
    if self.penReader then self.penReader:close() self.penReader = nil end
    local input = Device.input
    if self.stylusHook and input.stylus_callback == self.stylusHook then
        if self.prevStylus then input:registerStylusCallback(self.prevStylus) else input.stylus_callback = nil end
    end
    if self.bb then self.bb:free() self.bb = nil end
end

-- ------------------------------------------------------------------ the calls

local function AI() return require("appsai") end

--- Whether handwriting can be read: an AI service for reading handwriting is set up.
function HW.available()
    local ok, ready = pcall(function() return AI().readyFor("read") end)
    return ok and ready == true
end

-- A task's JSON answer: title, and its due date and reminder ({ date, minute }).
function HW.parseTask(text)
    local body = tostring(text or ""):match("^```%w*%s*(.-)%s*```$") or text or ""
    body = body:match("{.*}") or body
    local ok, t = pcall(require("json").decode, body)
    if not ok or type(t) ~= "table" or type(t.title) ~= "string" then return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")), nil end
    local extra = {}
    if type(t.due) == "string" then extra.due = t.due:match("^%s*(%d%d%d%d%-%d%d%-%d%d)") end
    if type(t.remind) == "string" then
        local date, h, m = t.remind:match("^%s*(%d%d%d%d%-%d%d%-%d%d)[T ]?(%d?%d?):?(%d?%d?)")
        if date then
            local hour, min = tonumber(h), tonumber(m)
            if not hour or hour > 23 or (min and min > 59) then hour, min = 9, 0 end
            extra.remind = { date = date, minute = hour * 60 + (min or 0) }
        end
    end
    return t.title:match("^%s*(.-)%s*$"), (extra.due or extra.remind) and extra or nil
end

--- The strip, then what was written read by the AI: done(text, extra), or
-- done(nil) when it was closed or nothing could be read (said so).
function HW.write(opts, done)
    opts = opts or {}
    local KO = require("appsko")
    if not HW.available() then
        AI().showSettings(AI().notReadyText("read"))
        return done(nil)
    end
    UIManager:show(Pad:new{ title = opts.title or opts.hint, done = function(png)
        if not png then return done(nil) end
        local kind = opts.kind or "text"
        local extra = kind == "task" and string.format(TASK, os.date("%A %Y-%m-%d")) or (KIND[kind] or "")
        if opts.multiline then extra = extra .. " Keep the line breaks." end
        local prompt = (AI().instructions("handwriting") or "") .. extra
        local client = AI().client("read")
        require("ui/network/manager"):runWhenOnline(function()
            local cancelled = false
            local box = KO.wait(_("Reading your writing…"), { cancel = function() cancelled = true done(nil) end })
            AI().background(function()
                local text, why = client:transcribe(png, prompt)
                return { text = text, why = why and tostring(why) or nil }
            end, function(r, err)
                if cancelled then return end
                if box and box.close then box:close() end
                local text = r and r.text
                if not text or not text:match("%S") then
                    KO.message(T(_("Could not read it:\n%1"), tostring(r and r.why or err or _("Nothing was read."))))
                    return done(nil)
                end
                if kind == "task" then return done(HW.parseTask(text)) end
                text = text:gsub("^%s+", ""):gsub("%s+$", "")
                if not opts.multiline then text = text:gsub("%s*\n%s*", " ") end
                done(text)
            end, 120)
        end)
    end })
end

--- A Write it button for a KOReader InputDialog: the keyboard closes, the
-- strip opens, and what was written goes into the dialog's text (after
-- what is there), the keyboard back. getDialog() -> the dialog.
function HW.button(getDialog, opts)
    return { text = (opts and opts.label) or _("Write it"), callback = function()
        local d = getDialog()
        if not d then return end
        if d.onCloseKeyboard then d:onCloseKeyboard() end
        HW.write(opts, function(text)
            if text and d.getInputText and d.setInputText then
                local now = d:getInputText() or ""
                d:setInputText(now:match("%S") and (now:gsub("%s+$", "") .. " " .. text) or text)
            end
            -- (Not when the dialog was closed while the strip was up.)
            if d.onShowKeyboard and shown(d) then UIManager:nextTick(function() d:onShowKeyboard() end) end
        end)
    end }
end

HW.Pad = Pad

return HW
