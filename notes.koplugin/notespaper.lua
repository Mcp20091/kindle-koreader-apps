--[[--
The paper under the ink: blank, ruled (narrow, wide), grid, dots, and the
planning templates: checklist (a box at the start of each line), tasks (a
task box and an indented subtask box on each line), Cornell notes, a week
planner and music staves; ruled with a margin, isometric dots, hexagons and
a month calendar.

Everything is placed from the screen's top left corner (not from where the
toolbar happens to be), so ink stays on the same lines whichever way the
toolbar is set.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local _ = require("gettext")

local Ink = require("notesink")

local Screen = Device.screen

local Paper = {}

-- How dark the templates are (Settings > Screen > Template lines): the
-- lines' grey and width, the marks' (boxes, frames, staves) and the dots'.
-- Light is the first look (1-pixel pale lines, faint on e-ink).
Paper.LEVELS = {
    light = { line = 0xC0, mark = 0x90, dot = 0x80, wide = false, dotSize = 1 },
    medium = { line = 0x98, mark = 0x70, dot = 0x60, wide = true, dotSize = 1.4 },
    dark = { line = 0x60, mark = 0x40, dot = 0x30, wide = true, dotSize = 1.7 },
}
Paper.level = "medium"

local LINE, MARK, DOT, LW, DOT_SIZE

-- The level's greys and line width, for the paint about to happen.
local function useLevel()
    local l = Paper.LEVELS[Paper.level] or Paper.LEVELS.medium
    LINE, MARK, DOT = Blitbuffer.Color8(l.line), Blitbuffer.Color8(l.mark), Blitbuffer.Color8(l.dot)
    LW = l.wide and math.max(1, math.floor(Screen:getDPI() / 150 + 0.5)) or 1
    DOT_SIZE = math.max(2, math.floor(Screen:getDPI() / 100 * l.dotSize + 0.5))
end
useLevel()

--- Spacing in pixels of a paper's lines (or grid).
function Paper.gap(paper)
    local mm = Screen:getDPI() / 25.4
    local g = ({ narrow = 7.1, wide = 8.7, grid = 5, dots = 5, checklist = 8.7, tasks = 8.7, cornell = 7.1, margin = 7.1,
        isometric = 6, hex = 5 })[paper] or 7.1
    return math.floor(g * mm + 0.5)
end

--- Where a checklist line's boxes are: the box's x for the task (and the
-- subtask on the tasks paper) and its size. `left`: where writing starts.
function Paper.boxes(paper, left)
    local gap = Paper.gap(paper)
    local size = math.floor(gap * 0.52)
    local task = left + math.floor(gap * 0.5)
    return task, task + math.floor(gap * 0.85), size
end

-- Horizontal lines `gap` apart from `first`, inside x0..x1, y0..y1 (LW
-- thick, clipped to the area).
local function lines(bb, x0, y0, x1, y1, first, gap, color)
    for y = first, y1 - 1, gap do
        local sy, ey = math.max(y, y0), math.min(y + LW, y1)
        if ey > sy then bb:paintRect(x0, sy, x1 - x0, ey - sy, color or LINE) end
    end
end

local function box(bb, x, y, size, x0, y0, x1, y1)
    -- An outlined square, clipped to the area being drawn.
    local function rect(rx, ry, rw, rh)
        local sx, sy, ex, ey = math.max(rx, x0), math.max(ry, y0), math.min(rx + rw, x1), math.min(ry + rh, y1)
        if ex > sx and ey > sy then bb:paintRect(sx, sy, ex - sx, ey - sy, MARK) end
    end
    local t = math.max(2, math.floor(size / 12))
    rect(x, y, size, t)
    rect(x, y + size - t, size, t)
    rect(x, y, t, size)
    rect(x + size - t, y, t, size)
end

--- The checklist box at (x, y) on `paper` (checklist or tasks), as { x, y,
-- size }, or nil; a little room around a box counts as on it.
function Paper.boxAt(paper, x, y, left, h, kinds)
    local gap = Paper.gap(paper)
    local slop = math.floor(Paper.gap(paper) * 0.52 * 0.35)
    local k = 0
    for line = 2 * gap, h - 1, gap do
        local b = Paper.lineBox(paper, k, left, kinds)
        if y >= b[2] - slop and y <= b[2] + b[3] + slop and x >= b[1] - slop and x <= b[1] + b[3] + slop then return b end
        k = k + 1
    end
    return nil
end

--- The box of line `k` (0 the first): { x, y, size }. On the tasks paper a
-- line is a task (box at the margin) unless `kinds[k]` is "sub" (the
-- writing starts indented): a smaller box, indented.
function Paper.lineBox(paper, k, left, kinds)
    local gap = Paper.gap(paper)
    local task, sub, size = Paper.boxes(paper, left)
    local by = 2 * gap + k * gap - size - math.floor(gap * 0.18)
    if paper == "tasks" and kinds and kinds[k] == "sub" then
        return { sub, by + math.floor(size * 0.15), math.floor(size * 0.8) }
    end
    return { task, by, size }
end

--- Which line (0 the first) writing at height y is on.
function Paper.lineOf(paper, y)
    local gap = Paper.gap(paper)
    return math.ceil((y - 2 * gap) / gap)
end

--- Where writing has to start for a line of the tasks paper to be a subtask.
function Paper.indentX(left)
    local task = Paper.boxes("tasks", left)
    return task + math.floor(Paper.gap("tasks") * 1.05)
end

-- One repeat of the hexagon grid (flat-topped hexagons `s` across a side):
-- 3s wide, s·√3 high, kept for its size and level.
local hexTiles = {}
local function hexTile(s)
    local key = s .. ":" .. Paper.level
    if hexTiles[key] then return hexTiles[key] end
    local tw, th = 3 * s, math.floor(s * math.sqrt(3) + 0.5)
    local bb = Blitbuffer.new(tw, th, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    local stamp = function(x, y, sz) bb:paintRect(x, y, sz, sz, LINE) end
    local hh = th / 2
    for i = -1, 2 do
        for j = -1, 1 do
            local cx = i * 1.5 * s
            local cy = j * th + ((i % 2 == 1) and hh or 0)
            local pts = { { cx - s, cy }, { cx - s / 2, cy - hh }, { cx + s / 2, cy - hh }, { cx + s, cy }, { cx + s / 2, cy + hh }, { cx - s / 2, cy + hh } }
            for k = 1, 6 do
                local a, b = pts[k], pts[k % 6 + 1]
                Ink.segment(math.floor(a[1] + 0.5), math.floor(a[2] + 0.5), math.floor(b[1] + 0.5), math.floor(b[2] + 0.5), LW, stamp)
            end
        end
    end
    hexTiles[key] = bb
    return bb
end

--- The month calendar's layout on a page `w` x `h` whose writing starts at
-- `left`, for the month of `when`: the grid's corner (gx, gy), a cell's size
-- (cw, ch), rows, the column of the 1st (Monday 0), the days in the month,
-- the 1st's time, the title's and the weekday names' heights.
function Paper.calendar(w, h, left, when)
    local gap = Paper.gap("calendar")
    local t = os.date("*t", when or os.time())
    local first = os.time({ year = t.year, month = t.month, day = 1, hour = 12 })
    local days = os.date("*t", os.time({ year = t.year, month = t.month + 1, day = 0, hour = 12 })).day
    local startCol = (os.date("*t", first).wday + 5) % 7   -- Monday first
    local top = math.floor(Paper.gap("wide") * 2.2)
    local head = math.floor(Paper.gap("wide") * 0.9)
    local cw = math.floor((w - left - gap) / 7)
    local rows = math.ceil((startCol + days) / 7)
    local ch = math.floor((h - top - head - gap) / rows)
    return { gap = gap, gx = left + math.floor(gap / 2), gy = top + head, cw = cw, ch = ch, rows = rows,
        startCol = startCol, days = days, first = first, top = top, head = head, year = t.year, month = t.month }
end

--- The day whose number was tapped at (x, y) on the month calendar (its
-- cell's top-left corner, a finger's width): its time (noon), or nil.
function Paper.calendarDayAt(x, y, w, h, left, when)
    local c = Paper.calendar(w, h, left, when)
    local reach = math.min(math.floor(c.gap * 1.4), c.cw, c.ch)
    local col, row = math.floor((x - c.gx) / c.cw), math.floor((y - c.gy) / c.ch)
    if col < 0 or col > 6 or row < 0 or row >= c.rows then return nil end
    if x - c.gx - col * c.cw > reach or y - c.gy - row * c.ch > reach then return nil end
    local d = row * 7 + col - c.startCol + 1
    if d < 1 or d > c.days then return nil end
    return os.time({ year = c.year, month = c.month, day = d, hour = 12 })
end

--- Paints `paper` over the area x0, y0 .. x1, y1 of `bb`, a page `w` x `h`
-- whose writing starts at `left`. `ui` draws text (the week planner, the
-- calendar); `when` is the page's date (the calendar's month); `marks`: days
-- of that month with a Journal page (their numbers in black).
function Paper.paint(bb, paper, x0, y0, x1, y1, w, h, left, ui, kinds, when, marks)
    if paper == "plain" or not paper then return end
    useLevel()
    local gap = Paper.gap(paper)
    if paper == "narrow" or paper == "wide" then
        lines(bb, x0, y0, x1, y1, 2 * gap, gap)
    elseif paper == "margin" then
        -- Ruled, with a margin line down the left (as school paper).
        lines(bb, x0, y0, x1, y1, 2 * gap, gap)
        local mx = left + math.floor(gap * 2.6)
        local sx, ex = math.max(mx, x0), math.min(mx + LW + 1, x1)
        if ex > sx then bb:paintRect(sx, y0, ex - sx, y1 - y0, MARK) end
    elseif paper == "isometric" then
        -- Dots in triangles (for 3D drawings and diagrams).
        local rowH = math.floor(gap * math.sqrt(3) / 2 + 0.5)
        local k = 0
        for y = gap, y1 - 1, rowH do
            local off = (k % 2 == 1) and math.floor(gap / 2) or 0
            if y >= y0 then
                for x = gap + off, x1 - 1, gap do
                    if x >= x0 then bb:paintRect(x, y, DOT_SIZE, DOT_SIZE, DOT) end
                end
            end
            k = k + 1
        end
    elseif paper == "hex" then
        local tile = hexTile(gap)
        local tw, th = tile:getWidth(), tile:getHeight()
        for ty = math.floor(y0 / th) * th, y1 - 1, th do
            for tx = math.floor(x0 / tw) * tw, x1 - 1, tw do
                local sx, sy = math.max(tx, x0), math.max(ty, y0)
                local ex, ey = math.min(tx + tw, x1), math.min(ty + th, y1)
                if ex > sx and ey > sy then bb:blitFrom(tile, sx, sy, sx - tx, sy - ty, ex - sx, ey - sy) end
            end
        end
    elseif paper == "calendar" then
        -- The page's month: its name, the days of the week and a box a day.
        local c = Paper.calendar(w, h, left, when)
        local first, days, startCol, top, head, cw, rows, ch = c.first, c.days, c.startCol, c.top, c.head, c.cw, c.rows, c.ch
        local gx, gy = c.gx, c.gy
        local function rect(rx, ry, rw, rh)
            local sx, sy, ex, ey = math.max(rx, x0), math.max(ry, y0), math.min(rx + rw, x1), math.min(ry + rh, y1)
            if ex > sx and ey > sy then bb:paintRect(sx, sy, ex - sx, ey - sy, MARK) end
        end
        for r = 0, rows do rect(gx, gy + r * ch, 7 * cw, 2) end
        for c = 0, 7 do rect(gx + c * cw, gy, 2, rows * ch) end
        if ui then
            if top >= y0 - gap and top - gap < y1 then
                ui:drawText(bb, os.date("%B %Y", first), gx, math.floor(top / 2) + math.floor(gap / 2), 14, { bold = true })
            end
            local names = { _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat"), _("Sun") }
            if gy >= y0 and top < y1 then
                for c = 0, 6 do
                    ui:drawText(bb, names[c + 1], gx + c * cw + math.floor(cw / 2), top + math.floor(head / 2), 9,
                        { align = "center", color = Blitbuffer.Color8(0x55) })
                end
            end
            for d = 1, days do
                local cell = startCol + d - 1
                local cx, cy = gx + (cell % 7) * cw, gy + math.floor(cell / 7) * ch
                if cy + gap >= y0 and cy < y1 then
                    local on = marks and marks[d]
                    ui:drawText(bb, tostring(d), cx + math.floor(gap * 0.35), cy + math.floor(gap * 0.5), 9,
                        { color = on and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(0x55), bold = on or nil })
                end
            end
        end
    elseif paper == "grid" then
        lines(bb, x0, y0, x1, y1, gap, gap)
        for x = gap, x1 - 1, gap do
            local sx, ex = math.max(x, x0), math.min(x + LW, x1)
            if ex > sx then bb:paintRect(sx, y0, ex - sx, y1 - y0, LINE) end
        end
    elseif paper == "dots" then
        local dot = DOT_SIZE
        for y = gap, y1 - 1, gap do
            for x = gap, x1 - 1, gap do
                if y >= y0 and x >= x0 then bb:paintRect(x, y, dot, dot, DOT) end
            end
        end
    elseif paper == "checklist" or paper == "tasks" then
        lines(bb, x0, y0, x1, y1, 2 * gap, gap)
        -- A box at the start of each line; on the tasks paper an indented,
        -- smaller one where the writing starts indented (a subtask).
        local k = 0
        for y = 2 * gap, h - 1, gap do
            local b = Paper.lineBox(paper, k, left, kinds)
            if b[2] + b[3] >= y0 and b[2] < y1 then box(bb, b[1], b[2], b[3], x0, y0, x1, y1) end
            k = k + 1
        end
    elseif paper == "cornell" then
        -- A title band, a cue column on the left, notes on the right, and a
        -- summary at the bottom.
        local head, foot = 2 * gap, h - math.floor(h * 0.18)
        local cue = left + math.floor((w - left) * 0.3)
        lines(bb, x0, math.max(y0, head + gap), x1, math.min(y1, foot), head + gap, gap)
        if head >= y0 and head < y1 then bb:paintRect(x0, head, x1 - x0, 2, MARK) end
        if foot >= y0 and foot < y1 then bb:paintRect(x0, foot, x1 - x0, 2, MARK) end
        if cue >= x0 and cue < x1 then
            local sy, ey = math.max(y0, head), math.min(y1, foot)
            if ey > sy then bb:paintRect(cue, sy, 2, ey - sy, MARK) end
        end
    elseif paper == "weekly" then
        -- Seven days and notes, two columns of four.
        local top = math.floor(Paper.gap("wide") * 1.5)
        local cw, ch = math.floor((w - left) / 2), math.floor((h - top) / 4)
        local names = { _("Monday"), _("Tuesday"), _("Wednesday"), _("Thursday"), _("Friday"), _("Saturday"), _("Sunday"), _("Notes") }
        for i = 0, 7 do
            local cx, cy = left + (i % 2) * cw, top + math.floor(i / 2) * ch
            local function rect(rx, ry, rw, rh)
                local sx, sy, ex, ey = math.max(rx, x0), math.max(ry, y0), math.min(rx + rw, x1), math.min(ry + rh, y1)
                if ex > sx and ey > sy then bb:paintRect(sx, sy, ex - sx, ey - sy, MARK) end
            end
            rect(cx, cy, cw, 2)
            rect(cx, cy, 2, ch)
            if ui and cy + gap >= y0 and cy < y1 then
                ui:drawText(bb, names[i + 1], cx + gap / 2, cy + math.floor(gap * 0.6), 9, { color = Blitbuffer.Color8(0x70) })
            end
        end
        local sy, ey = math.max(y0, top), math.min(y1, top + 4 * ch)
        if left + 2 * cw - 2 >= x0 and ey > sy then bb:paintRect(left + 2 * cw - 2, sy, 2, ey - sy, MARK) end
        if top + 4 * ch >= y0 and top + 4 * ch < y1 then bb:paintRect(math.max(x0, left), top + 4 * ch - 2, 2 * cw, 2, MARK) end
    elseif paper == "music" then
        -- Staves of five lines.
        local mm = Screen:getDPI() / 25.4
        local s = math.floor(2.2 * mm + 0.5)
        local between = math.floor(13 * mm + 0.5)
        for top = math.floor(12 * mm), h - 5 * s, 4 * s + between do
            for k = 0, 4 do
                local y = top + k * s
                local sy, ey = math.max(y, y0), math.min(y + LW, y1)
                if ey > sy then bb:paintRect(math.max(x0, left + s), sy, math.min(x1, w - s) - math.max(x0, left + s), ey - sy, MARK) end
            end
        end
    end
end

return Paper
