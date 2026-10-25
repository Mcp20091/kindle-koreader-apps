--[[--
Shapes for Notes, in plain Lua (no KOReader modules) for the tests: drawing
them (as ordinary strokes, so the eraser and lasso work on them), telling
what a hand-drawn stroke was meant to be, straightening lines to level,
joining their ends to ink nearby, and smoothing shaky strokes.

Points are flat lists { x1, y1, x2, y2, ... } in screen pixels.
]]

local Shapes = {}

Shapes.KINDS = { "line", "arrow", "rect", "ellipse", "triangle", "diamond", "star", "table" }

local function stroke(points, w, t)
    local q = {}
    for i = 1, #points / 2 do q[i] = w end
    return { t = t, w = w, p = points, q = q }
end

local function round(v) return math.floor(v + 0.5) end

-- A closed outline through corners { x1, y1, ... } (back to the first).
local function closed(corners)
    local p = {}
    for i = 1, #corners do p[i] = round(corners[i]) end
    table.insert(p, round(corners[1]))
    table.insert(p, round(corners[2]))
    return p
end

function Shapes.ellipsePoints(cx, cy, rx, ry, steps)
    steps = steps or math.max(24, math.min(120, math.floor((rx + ry) / 4)))
    local p = {}
    for i = 0, steps do
        local a = 2 * math.pi * i / steps
        table.insert(p, round(cx + rx * math.cos(a)))
        table.insert(p, round(cy + ry * math.sin(a)))
    end
    return p
end

--- The strokes of a shape. Line and arrow go from (x0, y0) to (x1, y1);
-- the others fill the box with those corners. `opts`: rows, cols (table).
function Shapes.make(kind, x0, y0, x1, y1, w, t, opts)
    opts = opts or {}
    local left, top = math.min(x0, x1), math.min(y0, y1)
    local right, bottom = math.max(x0, x1), math.max(y0, y1)
    local cx, cy = (left + right) / 2, (top + bottom) / 2
    if kind == "line" then
        return { stroke({ round(x0), round(y0), round(x1), round(y1) }, w, t) }
    elseif kind == "arrow" then
        local dx, dy = x1 - x0, y1 - y0
        local len = math.max(1, math.sqrt(dx * dx + dy * dy))
        local head = math.min(len * 0.35, math.max(14, w * 6))
        local ux, uy = dx / len, dy / len
        local function barb(sign)
            local a = math.rad(28) * sign
            local bx = ux * math.cos(a) - uy * math.sin(a)
            local by = ux * math.sin(a) + uy * math.cos(a)
            return round(x1 - bx * head), round(y1 - by * head)
        end
        local lx, ly = barb(1)
        local rx, ry = barb(-1)
        return {
            stroke({ round(x0), round(y0), round(x1), round(y1) }, w, t),
            stroke({ lx, ly, round(x1), round(y1), rx, ry }, w, t),
        }
    elseif kind == "rect" then
        return { stroke(closed({ left, top, right, top, right, bottom, left, bottom }), w, t) }
    elseif kind == "ellipse" then
        return { stroke(Shapes.ellipsePoints(cx, cy, (right - left) / 2, (bottom - top) / 2), w, t) }
    elseif kind == "triangle" then
        return { stroke(closed({ cx, top, right, bottom, left, bottom }), w, t) }
    elseif kind == "diamond" then
        return { stroke(closed({ cx, top, right, cy, cx, bottom, left, cy }), w, t) }
    elseif kind == "star" then
        local rx, ry = (right - left) / 2, (bottom - top) / 2
        local pts = {}
        for i = 0, 9 do
            local a = -math.pi / 2 + i * math.pi / 5
            local f = i % 2 == 0 and 1 or 0.42
            table.insert(pts, cx + rx * f * math.cos(a))
            table.insert(pts, cy + ry * f * math.sin(a))
        end
        return { stroke(closed(pts), w, t) }
    elseif kind == "table" then
        local rows, cols = math.max(1, opts.rows or 3), math.max(1, opts.cols or 3)
        local out = { stroke(closed({ left, top, right, top, right, bottom, left, bottom }), w, t) }
        for r = 1, rows - 1 do
            local y = round(top + (bottom - top) * r / rows)
            table.insert(out, stroke({ round(left), y, round(right), y }, w, t))
        end
        for c = 1, cols - 1 do
            local x = round(left + (right - left) * c / cols)
            table.insert(out, stroke({ x, round(top), x, round(bottom) }, w, t))
        end
        return out
    end
    return {}
end

-- ------------------------------------------------------------------ level lines

--- (x1, y1) moved so the line from (x0, y0) is exactly level, upright or
-- at 45 degrees when it is within `tolerance` degrees of one.
function Shapes.lockAngle(x0, y0, x1, y1, tolerance)
    tolerance = tolerance or 6
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return x1, y1 end
    local angle = math.deg(math.atan2(dy, dx))
    local nearest = math.floor(angle / 45 + 0.5) * 45
    if math.abs(angle - nearest) > tolerance then return x1, y1 end
    local a = math.rad(nearest)
    return round(x0 + len * math.cos(a)), round(y0 + len * math.sin(a))
end

-- ------------------------------------------------------------------ joining ends

local function nearestOnStroke(s, x, y)
    local p = s.p
    local best, bx, by
    if #p == 2 then
        return (p[1] - x) ^ 2 + (p[2] - y) ^ 2, p[1], p[2]
    end
    for i = 1, #p - 3, 2 do
        local ax, ay, cx, cy = p[i], p[i + 1], p[i + 2], p[i + 3]
        local dx, dy = cx - ax, cy - ay
        local len2 = dx * dx + dy * dy
        local t = 0
        if len2 > 0 then t = math.max(0, math.min(1, ((x - ax) * dx + (y - ay) * dy) / len2)) end
        local px, py = ax + dx * t, ay + dy * t
        -- Corners and ends pull harder than the middle of a side.
        local d = (px - x) ^ 2 + (py - y) ^ 2
        for __, c in ipairs({ { ax, ay }, { cx, cy } }) do
            local dc = (c[1] - x) ^ 2 + (c[2] - y) ^ 2
            if dc <= d * 4 then d, px, py = dc, c[1], c[2] end
        end
        if not best or d < best then best, bx, by = d, px, py end
    end
    return best, bx, by
end

--- The point of `others` (strokes) nearest (x, y) within `radius`, or
-- (x, y) itself.
function Shapes.snapPoint(x, y, others, radius)
    local best, bx, by = radius * radius, nil, nil
    for __, s in ipairs(others or {}) do
        local d, px, py = nearestOnStroke(s, x, y)
        if d and d <= best then best, bx, by = d, px, py end
    end
    if bx then return round(bx), round(by) end
    return x, y
end

-- ------------------------------------------------------------------ what a stroke was meant to be

local function dist(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

local function pointLineDistance(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0 then return dist(px, py, ax, ay) end
    return math.abs(dy * px - dx * py + bx * ay - by * ax) / len
end

--- The points kept by Ramer-Douglas-Peucker with tolerance `eps`: indexes
-- (1-based, of points) of the corners.
local function simplify(p, first, last, eps, keep)
    local maxD, index = 0, nil
    local ax, ay, bx, by = p[2 * first - 1], p[2 * first], p[2 * last - 1], p[2 * last]
    for i = first + 1, last - 1 do
        local d = pointLineDistance(p[2 * i - 1], p[2 * i], ax, ay, bx, by)
        if d > maxD then maxD, index = d, i end
    end
    if index and maxD > eps then
        simplify(p, first, index, eps, keep)
        keep[index] = true
        simplify(p, index, last, eps, keep)
    end
end

local function corners(p, eps)
    local n = #p / 2
    local keep = { [1] = true, [n] = true }
    simplify(p, 1, n, eps, keep)
    local out = {}
    for i = 1, n do
        if keep[i] then table.insert(out, i) end
    end
    return out
end

local function box(p)
    local minX, minY, maxX, maxY = p[1], p[2], p[1], p[2]
    for i = 3, #p - 1, 2 do
        minX, maxX = math.min(minX, p[i]), math.max(maxX, p[i])
        minY, maxY = math.min(minY, p[i + 1]), math.max(maxY, p[i + 1])
    end
    return minX, minY, maxX, maxY
end

local function pathLength(p)
    local len = 0
    for i = 3, #p - 1, 2 do len = len + dist(p[i - 2], p[i - 1], p[i], p[i + 1]) end
    return len
end

--- What a hand-drawn stroke's points were meant to be: { kind = "line",
-- x0, y0, x1, y1 } | { kind = "ellipse", cx, cy, rx, ry } | { kind =
-- "rect", left, top, right, bottom } | { kind = "polygon", points = {...} }
-- (a triangle or a tilted four-sided shape), or nil (writing, a scribble).
function Shapes.recognize(p)
    local n = #p / 2
    if n < 2 then return nil end
    local minX, minY, maxX, maxY = box(p)
    local w, h = maxX - minX, maxY - minY
    local size = math.max(w, h)
    if size < 30 then return nil end
    local length = pathLength(p)
    local x0, y0, x1, y1 = p[1], p[2], p[#p - 1], p[#p]
    local chord = dist(x0, y0, x1, y1)
    -- A line: the path barely longer than the straight way.
    if chord > 0 and length / chord < 1.08 then
        local worst = 0
        for i = 1, n do worst = math.max(worst, pointLineDistance(p[2 * i - 1], p[2 * i], x0, y0, x1, y1)) end
        if worst < math.max(6, chord * 0.05) then return { kind = "line", x0 = x0, y0 = y0, x1 = x1, y1 = y1 } end
        return nil
    end
    -- Closed shapes: the ends meet (near enough), the path goes round once.
    if chord > math.max(25, length * 0.18) or length > (w + h) * 2 * 1.6 then return nil end
    local eps = size * 0.09
    local c = corners(p, eps)
    -- The corners round the shape (the last kept point is where it began),
    -- without points where the outline hardly turns (a start mid-side).
    local pts = {}
    for i = 1, #c - 1 do
        table.insert(pts, p[2 * c[i] - 1])
        table.insert(pts, p[2 * c[i]])
    end
    -- Dropped one at a time, the least turn first: points where the outline
    -- hardly turns, and one of two points close together (a corner drawn
    -- round, kept twice).
    local close = size * 0.15
    while #pts / 2 > 3 do
        local m = #pts / 2
        local drop, least
        for i = 1, m do
            local a, b = (i - 2) % m + 1, i % m + 1
            local ax, ay = pts[2 * i - 1] - pts[2 * a - 1], pts[2 * i] - pts[2 * a]
            local bx, by = pts[2 * b - 1] - pts[2 * i - 1], pts[2 * b] - pts[2 * i]
            local turn = math.abs(math.deg(math.atan2(ax * by - ay * bx, ax * bx + ay * by)))
            local near = math.sqrt(ax * ax + ay * ay) < close or math.sqrt(bx * bx + by * by) < close
            if (turn < 30 or near) and (not least or turn < least) then drop, least = i, turn end
        end
        if not drop then break end
        table.remove(pts, 2 * drop)
        table.remove(pts, 2 * drop - 1)
    end
    local k = #pts / 2
    if k == 3 or k == 4 then
        if k == 4 then
            -- Square to the page when its sides are near level and upright.
            local level = true
            for i = 1, 4 do
                local j = i % 4 + 1
                local dx, dy = pts[2 * j - 1] - pts[2 * i - 1], pts[2 * j] - pts[2 * i]
                local a = math.deg(math.atan2(math.abs(dy), math.abs(dx)))
                if a > 12 and a < 78 then level = false end
            end
            if level then return { kind = "rect", left = minX, top = minY, right = maxX, bottom = maxY } end
        end
        return { kind = "polygon", points = pts }
    end
    -- An ellipse: every point near the ellipse in the stroke's box.
    local cx, cy, rx, ry = (minX + maxX) / 2, (minY + maxY) / 2, w / 2, h / 2
    if rx < 5 or ry < 5 then return nil end
    local err = 0
    for i = 1, n do
        local v = math.sqrt(((p[2 * i - 1] - cx) / rx) ^ 2 + ((p[2 * i] - cy) / ry) ^ 2)
        err = err + math.abs(v - 1)
    end
    if err / n < 0.12 then
        if math.abs(rx - ry) < math.max(rx, ry) * 0.12 then rx = (rx + ry) / 2 ry = rx end   -- a circle
        return { kind = "ellipse", cx = cx, cy = cy, rx = rx, ry = ry }
    end
    return nil
end

--- The clean strokes for what recognize() found, `w` wide, tip `t`.
function Shapes.fromRecognized(r, w, t)
    if r.kind == "line" then
        local x1, y1 = Shapes.lockAngle(r.x0, r.y0, r.x1, r.y1)
        return Shapes.make("line", r.x0, r.y0, x1, y1, w, t)
    elseif r.kind == "rect" then
        return Shapes.make("rect", r.left, r.top, r.right, r.bottom, w, t)
    elseif r.kind == "ellipse" then
        return { stroke(Shapes.ellipsePoints(r.cx, r.cy, r.rx, r.ry), w, t) }
    else
        return { stroke(closed(r.points), w, t) }
    end
end

-- ------------------------------------------------------------------ smoothing

--- A stroke with its points (and widths) evened out: each the average of
-- its neighbours `radius` either side, ends kept. A copy.
function Shapes.smooth(s, radius)
    local p, q = s.p, s.q
    local n = #p / 2
    if radius < 1 or n < 3 then return s end
    -- (Its shade and line kept: only the points change.)
    local out = { t = s.t, c = s.c, d = s.d, f = s.f, w = s.w, p = {}, q = q and {} or nil }
    for i = 1, n do
        local a, b = math.max(1, i - radius), math.min(n, i + radius)
        if i == 1 or i == n then a, b = i, i end
        local sx, sy, sw = 0, 0, 0
        for k = a, b do
            sx, sy = sx + p[2 * k - 1], sy + p[2 * k]
            if q then sw = sw + q[k] end
        end
        local count = b - a + 1
        out.p[2 * i - 1], out.p[2 * i] = round(sx / count), round(sy / count)
        if q then out.q[i] = math.max(1, round(sw / count)) end
    end
    return out
end

return Shapes
