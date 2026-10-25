--[[--
Stroke geometry for Notes, in plain Lua (no KOReader modules) for the tests.

A stroke: { t = tip, w = width in pixels, p = { x1, y1, x2, y2, ... }, q = {
w1, w2, ... } } in screen pixels (portrait). `t` is the tip it was drawn with
(Ink.TIPS; none for the ballpoint pen). `q`, when there, is each point's width
(from the pen's pressure) and `w` the widest; without it every point is `w`
wide. Strokes are drawn by stamping squares along each segment (as wide as
its two ends on average), so fast writing (points far apart) stays solid.
]]

local Ink = {}

--- The tips: widths of their five sizes in pixels at 300 dpi, their grey
-- (0 black .. 255 white), how much the pen's pressure changes the width (0
-- none .. 1 a light touch about a third of the full width), and whether
-- they go under the ink (the highlighter).
-- `pressure` 1 or more: the width goes from `min` of the full width (a
-- light touch) to all of it, along f ^ `exp`. `nib`: a chisel nib, wide
-- across its slant and thin along it (calligraphy).
Ink.TIPS = {
    pen = { sizes = { 2, 4, 6, 9, 13 }, grey = 0, pressure = 0.3 },
    fineliner = { sizes = { 1, 2, 3, 5, 7 }, grey = 0, pressure = 0 },
    fountain = { sizes = { 3, 5, 8, 11, 15 }, grey = 0, pressure = 1, min = 0.3, exp = 0.7 },
    calligraphy = { sizes = { 4, 7, 10, 14, 20 }, grey = 0, pressure = 0.3, nib = true },
    brush = { sizes = { 4, 8, 12, 18, 26 }, grey = 0, pressure = 1, min = 0.08, exp = 1.3 },
    marker = { sizes = { 6, 10, 14, 20, 28 }, grey = 0, pressure = 0 },
    pencil = { sizes = { 2, 3, 5, 7, 10 }, grey = 0x44, pressure = 0.15 },
    mechanical = { sizes = { 1, 2, 2, 3, 4 }, grey = 0x88, pressure = 0.1 },
    shader = { sizes = { 20, 32, 46, 60, 80 }, grey = 0xBB, pressure = 0, under = true },
    hl = { sizes = { 16, 24, 34, 46, 60 }, grey = 0xCC, pressure = 0, under = true },
}
Ink.PEN_TIPS = { "pen", "fineliner", "fountain", "calligraphy", "brush", "marker", "pencil", "mechanical", "shader" }
--- Ink shades a pen can have instead of its own: grey levels.
-- The greys are two of the Scribe's 16 grey levels (0x11 apart) or more
-- from each other, so they can be told apart: pencil 0x44, dark 0x66,
-- mechanical 0x88, light 0xAA, shader 0xBB, highlighter 0xCC.
Ink.SHADES = { dark = 0x66, light = 0xAA }
--- Grey tips' own darker and lighter shades, four grey levels or more
-- from theirs (the black tips' greys would be lighter than a pencil's).
local TIP_SHADES = {
    pencil = { dark = 0x00, light = 0x88 },
    mechanical = { dark = 0x44, light = 0xBB },
}
--- The grey a tip writes with in a shade ("default", "dark", "light"), or
-- nil for the tip's own.
function Ink.tipShade(tip, shade)
    if not shade or shade == "default" then return nil end
    local own = TIP_SHADES[tip]
    return own and own[shade] or Ink.SHADES[shade]
end
-- Shades kept in older notebooks, shown as the ones now.
local OLD_SHADES = { [0x60] = 0x66, [0xA8] = 0xAA }
Ink.NIB_ANGLE = math.rad(40)

--- A chisel nib's width for a segment going (dx, dy): thin along the nib's
-- slant, full across it.
function Ink.nibWidth(full, dx, dy)
    if dx == 0 and dy == 0 then return full end
    local a = math.atan2(dy, dx) - Ink.NIB_ANGLE
    return math.max(1, math.floor(full * (0.18 + 0.82 * math.abs(math.sin(a))) + 0.5))
end
--- Eraser radii (pixels at 300 dpi) of its five sizes.
Ink.ERASER_SIZES = { 6, 12, 18, 28, 40 }

function Ink.tipOf(stroke)
    return Ink.TIPS[stroke.t or "pen"] or Ink.TIPS.pen
end

--- A stroke's grey (0 black .. 255 white): its own shade, else its tip's.
function Ink.greyOf(stroke)
    if stroke.c then return OLD_SHADES[stroke.c] or stroke.c end
    return Ink.tipOf(stroke).grey
end

--- Pen pressure as felt: "soft" gives a wide line with a light touch,
-- "firm" needs a harder press, "normal" leaves it as the pen reads it.
local FEEL = { soft = 0.6, firm = 1.6 }
function Ink.feel(f, how)
    local e = FEEL[how]
    if not e or not f then return f end
    return math.max(0, math.min(1, f)) ^ e
end

--- Under the ink (the highlighter, the shader).
function Ink.isHighlight(stroke)
    return Ink.tipOf(stroke).under == true
end

--- A tip's width at `size` (1..5) for a pen pressure fraction `f` (0..1,
-- nil without pressure), scaled by `scale` (the screen's dpi / 300).
function Ink.tipWidth(tip, size, f, scale)
    local def = Ink.TIPS[tip] or Ink.TIPS.pen
    local full = def.sizes[math.max(1, math.min(5, size))] * (scale or 1)
    if not f or def.pressure == 0 then return math.max(1, math.floor(full + 0.5)) end
    if def.pressure >= 1 then
        local min, exp = def.min or 0.3, def.exp or 0.7
        return math.max(1, math.floor(full * (min + (1 - min) * math.max(0, math.min(1, f)) ^ exp) + 0.5))
    end
    return math.max(1, math.floor(full * (1 - def.pressure + def.pressure * math.max(0, math.min(1, f))) + 0.5))
end

--- Calls `stamp(x, y, size)` (top-left corner) along the segment from
-- (x0, y0) to (x1, y1) for a pen `width` wide, about every half width.
function Ink.segment(x0, y0, x1, y1, width, stamp)
    local half = math.floor(width / 2)
    local dx, dy = x1 - x0, y1 - y0
    local length = math.max(math.abs(dx), math.abs(dy))
    local step = math.max(1, math.floor(width / 2))
    local steps = math.max(1, math.ceil(length / step))
    for i = 0, steps do
        local t = i / steps
        stamp(math.floor(x0 + dx * t + 0.5) - half, math.floor(y0 + dy * t + 0.5) - half, width)
    end
end

--- The width of the segment from point `k` to point `k + 1` (1-based).
function Ink.segmentWidth(stroke, k)
    local q = stroke.q
    if not q or not q[k] then return stroke.w end
    return math.max(1, math.floor((q[k] + (q[k + 1] or q[k])) / 2 + 0.5))
end

--- Calls `stamp` along a segment like Ink.segment, but only on the "on"
-- parts of a dash pattern: `on` and `off` lengths in pixels, `done` how far
-- along the stroke the segment starts. Returns how far along it ends.
function Ink.dashedSegment(x0, y0, x1, y1, width, on, off, done, stamp)
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0 then
        if done % (on + off) < on then Ink.segment(x0, y0, x0, y0, width, stamp) end
        return done
    end
    local step = math.max(1, width / 2)
    local t = 0
    while t <= len do
        if (done + t) % (on + off) < on then
            local f = t / len
            local half = math.floor(width / 2)
            stamp(math.floor(x0 + dx * f + 0.5) - half, math.floor(y0 + dy * f + 0.5) - half, width)
        end
        t = t + step
    end
    return done + len
end

--- The dash pattern of a stroke `width` wide: on, off (nil: solid).
function Ink.dashes(style, width)
    if style == "dash" then return width * 4 + 6, width * 3 + 6 end
    if style == "dot" then return 1, width * 2.5 + 4 end
    return nil
end

--- Rows of a filled polygon { x1, y1, ... }: calls fill(y, x0, x1) for each
-- pixel row inside it (even-odd rule).
function Ink.fillPolygon(p, fill)
    local n = #p / 2
    if n < 3 then return end
    local minY, maxY = p[2], p[2]
    for i = 2, n do minY, maxY = math.min(minY, p[2 * i]), math.max(maxY, p[2 * i]) end
    for y = math.floor(minY), math.ceil(maxY) do
        local cy = y + 0.5
        local xs = {}
        local j = n
        for i = 1, n do
            local xi, yi, xj, yj = p[2 * i - 1], p[2 * i], p[2 * j - 1], p[2 * j]
            if (yi > cy) ~= (yj > cy) then table.insert(xs, xi + (cy - yi) * (xj - xi) / (yj - yi)) end
            j = i
        end
        table.sort(xs)
        for k = 1, #xs - 1, 2 do
            local a, b = math.ceil(xs[k] - 0.5), math.floor(xs[k + 1] - 0.5)
            if b >= a then fill(y, a, b) end
        end
    end
end

--- Every stamp of a stroke.
function Ink.stroke(stroke, stamp)
    local p = stroke.p
    if #p < 2 then return end
    if #p == 2 then
        Ink.segment(p[1], p[2], p[1], p[2], Ink.segmentWidth(stroke, 1), stamp)
        return
    end
    for i = 1, #p - 3, 2 do
        Ink.segment(p[i], p[i + 1], p[i + 2], p[i + 3], Ink.segmentWidth(stroke, (i + 1) / 2), stamp)
    end
end

--- A pen pressure (0..max) as a width: a light touch about a third of the
-- full width, growing gently (most writing is light to medium).
function Ink.pressureWidth(full, pressure, max)
    if not pressure or not max or max <= 0 then return full end
    local f = math.max(0, math.min(1, pressure / max))
    return math.max(1, math.floor(full * (0.3 + 0.7 * f ^ 0.7) + 0.5))
end

--- The area a stroke covers: x, y, w, h (nil for an empty stroke).
function Ink.box(stroke)
    local p = stroke.p
    if #p < 2 then return nil end
    local minX, minY, maxX, maxY = p[1], p[2], p[1], p[2]
    for i = 3, #p - 1, 2 do
        if p[i] < minX then minX = p[i] elseif p[i] > maxX then maxX = p[i] end
        if p[i + 1] < minY then minY = p[i + 1] elseif p[i + 1] > maxY then maxY = p[i + 1] end
    end
    local pad = math.ceil(stroke.w / 2) + 1
    return minX - pad, minY - pad, maxX - minX + 2 * pad, maxY - minY + 2 * pad
end

--- Whether the eraser at (x, y), `radius` across, touches the stroke: near
-- any of its points or the line between two of them.
function Ink.hits(stroke, x, y, radius)
    local bx, by, bw, bh = Ink.box(stroke)
    if not bx then return false end
    local reach = radius + stroke.w / 2
    if x < bx - reach or x > bx + bw + reach or y < by - reach or y > by + bh + reach then return false end
    local p = stroke.p
    local reach2 = reach * reach
    if #p == 2 then
        return (p[1] - x) ^ 2 + (p[2] - y) ^ 2 <= reach2
    end
    for i = 1, #p - 3, 2 do
        local ax, ay, cx, cy = p[i], p[i + 1], p[i + 2], p[i + 3]
        local dx, dy = cx - ax, cy - ay
        local len2 = dx * dx + dy * dy
        local t = 0
        if len2 > 0 then t = math.max(0, math.min(1, ((x - ax) * dx + (y - ay) * dy) / len2)) end
        local px, py = ax + dx * t, ay + dy * t
        if (px - x) ^ 2 + (py - y) ^ 2 <= reach2 then return true end
    end
    return false
end

--- Erasing exactly what the eraser covers: the parts of `stroke` within
-- `radius` of (x, y) taken out. Returns nil when the eraser misses the
-- stroke, else the pieces left (strokes, maybe none). Long segments are
-- filled in with points first, so a line drawn fast (two points far apart)
-- is cut where the eraser crosses it, not removed whole.
function Ink.eraseCircle(stroke, x, y, radius)
    if not Ink.hits(stroke, x, y, radius) then return nil end
    local p, q = stroke.p, stroke.q
    local count = #p / 2
    local function widthAt(k) return q and q[k] or stroke.w end
    -- Every point, with points added along long segments (about 2 px apart).
    local xs, ys, ws = {}, {}, {}
    for k = 1, count do
        local px, py, pw = p[2 * k - 1], p[2 * k], widthAt(k)
        if k > 1 then
            local ax, ay, aw = p[2 * k - 3], p[2 * k - 2], widthAt(k - 1)
            local steps = math.floor(math.max(math.abs(px - ax), math.abs(py - ay)) / 2)
            for s = 1, steps - 1 do
                local t = s / steps
                table.insert(xs, math.floor(ax + (px - ax) * t + 0.5))
                table.insert(ys, math.floor(ay + (py - ay) * t + 0.5))
                table.insert(ws, math.floor(aw + (pw - aw) * t + 0.5))
            end
        end
        table.insert(xs, px)
        table.insert(ys, py)
        table.insert(ws, pw)
    end
    -- Runs of points the eraser does not reach become the pieces.
    local pieces, run = {}, nil
    local function finish()
        if run and #run.q >= 2 then table.insert(pieces, run) end
        run = nil
    end
    for i = 1, #xs do
        local reach = radius + ws[i] / 2
        if (xs[i] - x) ^ 2 + (ys[i] - y) ^ 2 <= reach * reach then
            finish()
        else
            if not run then run = { t = stroke.t, c = stroke.c, d = stroke.d, w = 0, p = {}, q = {} } end
            table.insert(run.p, xs[i])
            table.insert(run.p, ys[i])
            table.insert(run.q, ws[i])
            if ws[i] > run.w then run.w = ws[i] end
        end
    end
    finish()
    return pieces
end

--- Whether (x, y) is inside the polygon { x1, y1, x2, y2, ... } (closed).
function Ink.inside(poly, x, y)
    local n = #poly / 2
    local inside = false
    local j = n
    for i = 1, n do
        local xi, yi, xj, yj = poly[2 * i - 1], poly[2 * i], poly[2 * j - 1], poly[2 * j]
        if (yi > y) ~= (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi then inside = not inside end
        j = i
    end
    return inside
end

--- Ink.inside for many points and one polygon (a lasso): where each row of
-- pixels crosses its edges is worked out once, so a point is checked
-- against those few crossings, not every edge. The same answers.
function Ink.insideTest(poly)
    local n = #poly / 2
    local rows = {}
    local j = n
    for i = 1, n do
        local xi, yi, xj, yj = poly[2 * i - 1], poly[2 * i], poly[2 * j - 1], poly[2 * j]
        if yi ~= yj then
            -- The rows this edge crosses: (yi > y) ~= (yj > y).
            for y = math.ceil(math.min(yi, yj)), math.ceil(math.max(yi, yj)) - 1 do
                local xs = rows[y]
                if not xs then
                    xs = {}
                    rows[y] = xs
                end
                xs[#xs + 1] = (xj - xi) * (y - yi) / (yj - yi) + xi
            end
        end
        j = i
    end
    return function(x, y)
        if y ~= math.floor(y) then return Ink.inside(poly, x, y) end
        local xs = rows[y]
        if not xs then return false end
        local inside = false
        for k = 1, #xs do
            if x < xs[k] then inside = not inside end
        end
        return inside
    end
end

--- The strokes a lasso (a polygon) takes: those with at least half their
-- points inside it. Returns their indexes, in order.
function Ink.lassoed(strokes, poly)
    local out = {}
    if #poly < 6 then return out end
    local minX, minY, maxX, maxY = poly[1], poly[2], poly[1], poly[2]
    for i = 3, #poly - 1, 2 do
        minX, maxX = math.min(minX, poly[i]), math.max(maxX, poly[i])
        minY, maxY = math.min(minY, poly[i + 1]), math.max(maxY, poly[i + 1])
    end
    local inside = Ink.insideTest(poly)
    for k, stroke in ipairs(strokes) do
        local p = stroke.p
        local count, hits = #p / 2, 0
        for i = 1, #p - 1, 2 do
            local x, y = p[i], p[i + 1]
            if x >= minX and x <= maxX and y >= minY and y <= maxY and inside(x, y) then hits = hits + 1 end
        end
        if count > 0 and hits * 2 >= count then table.insert(out, k) end
    end
    return out
end

--- A copy of `stroke` scaled by `s` around (ox, oy), then moved by (dx, dy).
function Ink.transform(stroke, ox, oy, s, dx, dy)
    local p, out = stroke.p, { t = stroke.t, c = stroke.c, d = stroke.d, f = stroke.f, w = math.max(1, math.floor(stroke.w * s + 0.5)), p = {} }
    for i = 1, #p - 1, 2 do
        out.p[i] = math.floor(ox + (p[i] - ox) * s + dx + 0.5)
        out.p[i + 1] = math.floor(oy + (p[i + 1] - oy) * s + dy + 0.5)
    end
    if stroke.q then
        out.q = {}
        for i, w in ipairs(stroke.q) do out.q[i] = math.max(1, math.floor(w * s + 0.5)) end
    end
    return out
end

--- The area several strokes cover (x, y, w, h list), or nil.
function Ink.boxOf(strokes)
    local area
    for __, stroke in ipairs(strokes) do
        local x, y, w, h = Ink.box(stroke)
        if x then area = Ink.union(area, { x, y, w, h }) end
    end
    return area
end

--- The union of two areas (x, y, w, h), either may be nil.
function Ink.union(a, b)
    if not a then return b end
    if not b then return a end
    local x = math.min(a[1], b[1])
    local y = math.min(a[2], b[2])
    local x2 = math.max(a[1] + a[3], b[1] + b[3])
    local y2 = math.max(a[2] + a[4], b[2] + b[4])
    return { x, y, x2 - x, y2 - y }
end

--- An area kept inside the screen (nil when nothing is left): w x h, and
-- below `top` and right of `left` when given.
function Ink.clip(area, w, h, top, left)
    if not area then return nil end
    local x = math.max(left or 0, area[1])
    local y = math.max(top or 0, area[2])
    local x2 = math.min(w, area[1] + area[3])
    local y2 = math.min(h, area[2] + area[4])
    if x2 <= x or y2 <= y then return nil end
    return { x, y, x2 - x, y2 - y }
end

return Ink
