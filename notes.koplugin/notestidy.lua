--[[--
Tidying handwriting, in plain Lua (no KOReader modules) for the tests: the
writing kept as yours, only moved, tilted and sized.

Strokes are put in lines (by height on the page) and words (strokes close
together along a line). Then, as asked:

- upright: each word's slant (from its near-upright pen moves) taken out;
- level: each line's tilt taken out and its words set on one baseline (the
  ruled line under them, when there is one close);
- size: words much bigger or smaller than the rest of their line brought
  closer to it;
- space: the gaps between a line's words made even.

Highlighter strokes, filled or dashed shapes and big drawings are left as
they are.

@module koplugin.notes.tidy
]]

local Tidy = {}

local function round(v) return math.floor(v + 0.5) end

-- (A copy by hand: unpack has a limit, and a stroke can have thousands of points.)
local function copy(list)
    local t = {}
    for i = 1, #list do t[i] = list[i] end
    return t
end

local function median(list)
    if #list == 0 then return nil end
    local t = copy(list)
    table.sort(t)
    local n = #t
    return n % 2 == 1 and t[(n + 1) / 2] or (t[n / 2] + t[n / 2 + 1]) / 2
end

-- The value `f` (0..1) of the way up a list of numbers.
local function pct(list, f)
    local t = copy(list)
    table.sort(t)
    return t[math.max(1, math.min(#t, math.ceil(#t * f)))]
end

local function bounds(p)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #p - 1, 2 do
        local x, y = p[i], p[i + 1]
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    return x0, y0, x1, y1
end

-- A word's points (all its strokes'), y only or x and y.
local function wordYs(word, pts)
    local ys = {}
    for __, k in ipairs(word.strokes) do
        local p = pts[k]
        for i = 2, #p, 2 do table.insert(ys, p[i]) end
    end
    return ys
end

local function wordBounds(word, pts)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for __, k in ipairs(word.strokes) do
        local a, b, c, d = bounds(pts[k])
        x0, y0, x1, y1 = math.min(x0, a), math.min(y0, b), math.max(x1, c), math.max(y1, d)
    end
    return x0, y0, x1, y1
end

-- Every point of a word moved by `fn(x, y)` -> x, y.
local function each(word, pts, fn)
    for __, k in ipairs(word.strokes) do
        local p = pts[k]
        for i = 1, #p - 1, 2 do p[i], p[i + 1] = fn(p[i], p[i + 1]) end
    end
end

-- Where the writing sits on its line: most of a word's points are above it
-- (descenders below).
local function baseline(word, pts) return pct(wordYs(word, pts), 0.86) end
local function coreTop(word, pts) return pct(wordYs(word, pts), 0.3) end

--- A word's slant: how far its near-upright pen moves lean (dx per dy;
-- negative leans right, as "/"), and how much there was to go on.
function Tidy.slant(word, pts)
    local sum, weight = 0, 0
    for __, k in ipairs(word.strokes) do
        local p = pts[k]
        for i = 1, #p - 3, 2 do
            local dx, dy = p[i + 2] - p[i], p[i + 3] - p[i + 1]
            local len = math.sqrt(dx * dx + dy * dy)
            if len >= 2 and math.abs(dy) >= math.abs(dx) then
                local t = dx / dy
                sum = sum + t * len
                weight = weight + len
            end
        end
    end
    if weight == 0 then return 0, 0 end
    return sum / weight, weight
end

--- The strokes (indexes into `strokes`) in lines of words: { { words = { {
-- strokes = { k, … } }, … }, size = n }, … }, top to bottom, left to right.
-- `size`: the line's writing height (most of its strokes'), what the steps
-- measure by. `skip(s)`: strokes left out.
function Tidy.lines(strokes, skip, gap)
    local items, heights = {}, {}
    for k, s in ipairs(strokes) do
        if not skip(s) and #s.p >= 2 then
            local x0, y0, x1, y1 = bounds(s.p)
            table.insert(items, { k = k, x0 = x0, y0 = y0, x1 = x1, y1 = y1, cy = (y0 + y1) / 2 })
            table.insert(heights, y1 - y0)
        end
    end
    if #items == 0 then return {}, 0 end
    local h = math.max(4, median(heights))
    -- Big drawings stay as they are. (A tall narrow stroke is a letter
    -- reaching into the lines above and below, as an f or a long g, unless
    -- it spans more than three lines.)
    local keep = {}
    local tall = math.max(4 * h, (gap or 0) * 1.6)
    for __, it in ipairs(items) do
        local ih, iw = it.y1 - it.y0, it.x1 - it.x0
        if ih <= tall or (iw < 0.6 * ih and ih <= 1.8 * tall) then table.insert(keep, it) end
    end
    -- Lines followed left to right through the strokes of usual height, so
    -- writing that drifts up or down stays one line. Then the rest go with
    -- the line whose writing is nearest along it: dots and small marks, and
    -- tall strokes (an f or a g reaching into the next line, a capital),
    -- whose middle can be nearer the next line than their own.
    local spacing = gap and gap > 0 and gap or 2.2 * h
    local reach = spacing * 0.6
    local usual, other = {}, {}
    for __, it in ipairs(keep) do
        local ih = it.y1 - it.y0
        table.insert((ih >= 0.35 * h and ih <= 1.8 * h) and usual or other, it)
    end
    table.sort(usual, function(a, b) return a.x0 < b.x0 end)
    local lines = {}
    -- Where a line's writing is expected at `x`: where it last was, carried
    -- on along its slope so far (writing climbing or falling steeply).
    local function expected(l, x)
        return l.cy + l.slope * (x - l.x)
    end
    local function nearest(it)
        local best, bestD
        local x = (it.x0 + it.x1) / 2
        for __, l in ipairs(lines) do
            local d = math.abs(it.cy - expected(l, x))
            if d <= reach and (not bestD or d < bestD) then best, bestD = l, d end
        end
        return best
    end
    for __, it in ipairs(usual) do
        local x = (it.x0 + it.x1) / 2
        local line = nearest(it)
        if not line then
            line = { items = {}, cy = it.cy, x = x, slope = 0 }
            table.insert(lines, line)
        elseif x - line.x > h then
            local s = (it.cy - line.cy) / (x - line.x)
            line.slope = 0.6 * line.slope + 0.4 * math.max(-0.35, math.min(0.35, s))
        end
        table.insert(line.items, it)
        -- (Following the writing as it drifts.)
        line.cy = 0.25 * expected(line, x) + 0.75 * it.cy
        line.x = x
    end
    table.sort(other, function(a, b) return (a.y1 - a.y0) > (b.y1 - b.y0) end)
    for __, it in ipairs(other) do
        local line, bestD = nil, nil
        for __, l in ipairs(lines) do
            -- How far from the line's writing nearest along it.
            local d
            for __, o in ipairs(l.items) do
                local dx = math.max(0, o.x0 - it.x1, it.x0 - o.x1)
                local dd = math.abs(it.cy - o.cy) + dx * 0.5
                if not d or dd < d then d = dd end
            end
            if d and d <= spacing and (not bestD or d < bestD) then line, bestD = l, d end
        end
        if not line then
            line = { items = {}, cy = it.cy }
            table.insert(lines, line)
        end
        table.insert(line.items, it)
    end
    for __, l in ipairs(lines) do
        local sum, hs = 0, {}
        for __, it in ipairs(l.items) do
            sum = sum + it.cy
            local ih = it.y1 - it.y0
            if ih >= 0.35 * h then table.insert(hs, ih) end
        end
        l.mean = sum / #l.items
        l.size = math.max(4, median(hs) or h)
    end
    table.sort(lines, function(a, b) return a.mean < b.mean end)
    -- Words: strokes close together along the line.
    local out = {}
    for __, l in ipairs(lines) do
        table.sort(l.items, function(a, b) return a.x0 < b.x0 end)
        local join = Tidy.wordGap(l.items, l.size)
        local words, word = {}, nil
        for __, it in ipairs(l.items) do
            if not word or it.x0 > word.x1 + join then
                word = { strokes = {}, x1 = it.x1 }
                table.insert(words, word)
            end
            table.insert(word.strokes, it.k)
            if it.x1 > word.x1 then word.x1 = it.x1 end
        end
        table.insert(out, { words = words, size = l.size })
    end
    return out, h
end

--- How far apart strokes must be to be separate words, for one line's
-- strokes (sorted by their left edge; `h`: the line's writing height). Its
-- gaps fall into the small ones between letters (a capital lifted off
-- before the rest, a dot) and the large ones between words: split where the
-- two groups are most apart (on a log scale, so "twice as wide" counts the
-- same for small and big writing). Lines with no clear split take 0.45 of
-- the writing's height.
function Tidy.wordGap(items, h)
    local gaps, right = {}, nil
    for __, it in ipairs(items) do
        if right then
            local g = it.x0 - right
            if g > 0 then table.insert(gaps, g) end
        end
        right = right and math.max(right, it.x1) or it.x1
    end
    local plain = 0.45 * h
    if #gaps < 2 then return plain end
    table.sort(gaps)
    -- (Gaps under a sixth of the writing's height all count as letters
    -- touching: their exact width says nothing.)
    local logs = {}
    for i, g in ipairs(gaps) do logs[i] = math.log(math.max(g, 0.15 * h, 2)) end
    local n, total = #logs, 0
    for __, v in ipairs(logs) do total = total + v end
    local best, at, sumLeft = 0, nil, 0
    for i = 1, n - 1 do
        sumLeft = sumLeft + logs[i]
        local m1, m2 = sumLeft / i, (total - sumLeft) / (n - i)
        -- Between the groups: the more apart and the more even in number, the better.
        local score = i * (n - i) * (m2 - m1) ^ 2
        -- A word gap is at least a quarter of the writing's height, and a
        -- gap inside a word under 0.8 of it.
        if gaps[i + 1] >= 0.25 * h and gaps[i] <= 0.8 * h and score > best then best, at = score, i end
    end
    if at then
        local small, large = 0, 0
        for i = 1, at do small = small + logs[i] end
        for i = at + 1, n do large = large + logs[i] end
        -- The word gaps clearly wider than the letter gaps: on average 1.7 times.
        if math.exp(large / (n - at) - small / at) >= 1.7 then
            return (gaps[at] + gaps[at + 1]) / 2
        end
    end
    return plain
end

--- `strokes` tidied as `which` says ({ upright, level, size, space } true
-- or not). `opts`: `skip(s)` (strokes left as they are), `rule` ({ first,
-- step }: the ruled lines' heights, to set writing on) and `gap` (the
-- ruled lines' spacing). Returns a new list (tidied strokes are new
-- tables; others the same) and how many words moved.
function Tidy.apply(strokes, which, opts)
    opts = opts or {}
    local skip = opts.skip or function() return false end
    local lines, h = Tidy.lines(strokes, skip, opts.gap)
    local pts = {}
    for __, l in ipairs(lines) do
        for __, w in ipairs(l.words) do
            for __, k in ipairs(w.strokes) do pts[k] = copy(strokes[k].p) end
        end
    end
    for __, l in ipairs(lines) do
        local words = l.words
        local size = l.size or h
        -- Marks: dashes, commas, dots and underlines on their own (flat or
        -- tiny). They aren't writing to measure lines by: they move with the
        -- word next to them.
        for __, w in ipairs(words) do
            local x0, y0, x1, y1 = wordBounds(w, pts)
            local wh, ww = y1 - y0, x1 - x0
            -- Flat (a dash, an underline), or small and narrow (a dot, a
            -- comma); a small word is wider than that.
            w.mark = wh < 0.25 * size or (ww < 0.5 * size and wh < 0.6 * size)
        end
        local function neighbour(i)
            local best, bestD
            for j, o in ipairs(words) do
                if not o.mark and j ~= i then
                    local d = math.abs(j - i)
                    if not bestD or d < bestD then best, bestD = o, d end
                end
            end
            return best
        end
        -- Upright: each word's lean taken out (around its baseline); words
        -- with little to go on take the line's.
        if which.upright then
            local leans = {}
            for __, w in ipairs(words) do
                w.t, w.tw = Tidy.slant(w, pts)
                if w.tw >= 3 * size then table.insert(leans, w.t) end
            end
            local lineLean = median(leans) or 0
            for __, w in ipairs(words) do
                local t = w.tw >= 3 * size and w.t or lineLean
                t = math.max(-1, math.min(1, t))
                if not w.mark and math.abs(t) > 0.05 then
                    local base = baseline(w, pts)
                    each(w, pts, function(x, y) return x - t * (y - base), y end)
                end
            end
        end
        -- Level: the line's tilt taken out (when there are three words or
        -- more to tell a tilt from words written a little up or down), then
        -- every word on one baseline.
        local writing = {}
        for __, w in ipairs(words) do if not w.mark then table.insert(writing, w) end end
        if which.level and #writing > 0 then
            local xs, bs = {}, {}
            for __, w in ipairs(writing) do
                local x0, __, x1 = wordBounds(w, pts)
                table.insert(xs, (x0 + x1) / 2)
                table.insert(bs, baseline(w, pts))
            end
            local m = 0
            if #writing >= 3 then
                local mx, my = 0, 0
                for i = 1, #xs do mx, my = mx + xs[i], my + bs[i] end
                mx, my = mx / #xs, my / #xs
                local num, den = 0, 0
                for i = 1, #xs do
                    num = num + (xs[i] - mx) * (bs[i] - my)
                    den = den + (xs[i] - mx) ^ 2
                end
                if den > 0 then m = math.max(-0.3, math.min(0.3, num / den)) end
            end
            local a = -math.atan(m)
            local ca, sa = math.cos(a), math.sin(a)
            for i, w in ipairs(writing) do
                if m ~= 0 then
                    local cx, cy = xs[i], bs[i]
                    each(w, pts, function(x, y)
                        local dx, dy = x - cx, y - cy
                        return cx + dx * ca - dy * sa, cy + dx * sa + dy * ca
                    end)
                end
            end
            local bases = {}
            for __, w in ipairs(writing) do
                w.base = baseline(w, pts)
                table.insert(bases, w.base)
            end
            local target = median(bases)
            -- On the ruled line under it, when one is close.
            local rule = opts.rule
            if rule and rule.step > 0 then
                local k = math.floor((target - rule.first) / rule.step + 0.5)
                local y = rule.first + k * rule.step
                if math.abs(y - target) <= rule.step * 0.35 then target = y end
            end
            for __, w in ipairs(writing) do w.dy = target - w.base end
            for i, w in ipairs(words) do
                local dy = w.dy
                if w.mark then
                    local o = neighbour(i)
                    dy = o and o.dy or 0
                end
                if dy and dy ~= 0 then each(w, pts, function(x, y) return x, y + dy end) end
            end
        end
        -- Size: words far from the line's usual height brought closer to it.
        if which.size and #writing >= 2 then
            local cores = {}
            for __, w in ipairs(writing) do
                w.base = baseline(w, pts)
                w.core = math.max(1, w.base - coreTop(w, pts))
                table.insert(cores, w.core)
            end
            local usual = median(cores)
            -- (A word made wider or narrower moves the words after it along,
            -- so the gaps stay as they were; marks only move along.)
            local shift = 0
            for __, w in ipairs(words) do
                if shift ~= 0 then
                    local dx = shift
                    each(w, pts, function(x, y) return x + dx, y end)
                end
                if not w.mark then
                    local f = math.max(0.75, math.min(1.4, usual / w.core))
                    if math.abs(f - 1) > 0.08 then
                        local x0, __, x1 = wordBounds(w, pts)
                        local bx, by = x0, w.base
                        each(w, pts, function(x, y) return bx + (x - bx) * f, by + (y - by) * f end)
                        shift = shift + (x1 - x0) * (f - 1)
                    end
                end
            end
        end
        -- Space: even gaps between the words (the first stays where it is).
        -- A mark keeps its own gap (a comma stays by its word).
        if which.space and #writing >= 3 then
            local boxes, gaps = {}, {}
            for i, w in ipairs(words) do
                local x0, __, x1 = wordBounds(w, pts)
                boxes[i] = { x0, x1 }
                if i > 1 and not w.mark and not words[i - 1].mark then table.insert(gaps, x0 - boxes[i - 1][2]) end
            end
            local even = math.max(0.6 * size, math.min(1.6 * size, median(gaps) or size))
            local at = boxes[1][2]
            for i = 2, #words do
                local want = (words[i].mark or words[i - 1].mark) and (boxes[i][1] - boxes[i - 1][2]) or even
                local dx = at + want - boxes[i][1]
                if math.abs(dx) >= 1 then
                    each(words[i], pts, function(x, y) return x + dx, y end)
                end
                at = boxes[i][2] + dx
            end
        end
    end
    -- New strokes where points moved.
    local out, moved = {}, 0
    local changed = {}
    for k, s in ipairs(strokes) do
        local p = pts[k]
        if p then
            local np, diff = {}, false
            for i = 1, #p do
                np[i] = round(p[i])
                if np[i] ~= s.p[i] then diff = true end
            end
            if diff then
                local new = {}
                for key, v in pairs(s) do new[key] = v end
                new.p = np
                out[k] = new
                changed[k] = true
            else
                out[k] = s
            end
        else
            out[k] = s
        end
    end
    for __, l in ipairs(lines) do
        for __, w in ipairs(l.words) do
            for __, k in ipairs(w.strokes) do
                if changed[k] then moved = moved + 1 break end
            end
        end
    end
    return out, moved
end

return Tidy
