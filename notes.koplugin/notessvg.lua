--[[--
Drawings from Claude (SVG) into ink, in plain Lua (no KOReader modules) for
the tests. Only what line art needs is read: line, polyline, polygon, rect,
circle, ellipse, path (M L H V C S Q T A Z, absolute and relative) and text,
with stroke-width, fill (grey or none), stroke-dasharray, and translate or
scale on groups and shapes. Anything else is left out.

Svg.parse(text) gives { w, h (the viewBox), lines = { { p = { x1, y1, ... },
closed, width, fill (grey or nil), dashed } }, texts = { { x, y, size, text
} } } in the SVG's own coordinates; Svg.place() maps them into a box on the
page as strokes and text boxes.
]]

local Svg = {}

local function num(s, default)
    return tonumber(s and s:match("^%s*([-+]?[%d%.]+[eE]?[-+]?%d*)")) or default
end

-- Attributes of a tag: { name = value }.
local function attrs(tag)
    local out = {}
    for k, v in tag:gmatch('([%w%-:]+)%s*=%s*"([^"]*)"') do out[k] = v end
    for k, v in tag:gmatch("([%w%-:]+)%s*=%s*'([^']*)'") do out[k] = out[k] or v end
    -- style="stroke-width:3; fill:none"
    if out.style then
        for k, v in out.style:gmatch("([%w%-]+)%s*:%s*([^;]+)") do out[k] = out[k] or v:match("^%s*(.-)%s*$") end
    end
    return out
end

-- A transform as { a, b, c, d, e, f } (x' = a x + c y + e, y' = b x + d y + f).
local function transform(s)
    local m = { 1, 0, 0, 1, 0, 0 }
    if not s then return m end
    local function mul(n)
        m = { m[1] * n[1] + m[3] * n[2], m[2] * n[1] + m[4] * n[2], m[1] * n[3] + m[3] * n[4], m[2] * n[3] + m[4] * n[4],
            m[1] * n[5] + m[3] * n[6] + m[5], m[2] * n[5] + m[4] * n[6] + m[6] }
    end
    for name, args in s:gmatch("(%a+)%s*%(([^)]*)%)") do
        local v = {}
        for x in args:gmatch("[-+]?[%d%.]+[eE]?[-+]?%d*") do table.insert(v, tonumber(x)) end
        if name == "translate" then mul({ 1, 0, 0, 1, v[1] or 0, v[2] or 0 })
        elseif name == "scale" then mul({ v[1] or 1, 0, 0, v[2] or v[1] or 1, 0, 0 })
        elseif name == "matrix" and #v == 6 then mul(v)
        elseif name == "rotate" and v[1] then
            local a = math.rad(v[1])
            local cx, cy = v[2] or 0, v[3] or 0
            mul({ 1, 0, 0, 1, cx, cy })
            mul({ math.cos(a), math.sin(a), -math.sin(a), math.cos(a), 0, 0 })
            mul({ 1, 0, 0, 1, -cx, -cy })
        end
    end
    return m
end

local function combine(m, n)
    return { m[1] * n[1] + m[3] * n[2], m[2] * n[1] + m[4] * n[2], m[1] * n[3] + m[3] * n[4], m[2] * n[3] + m[4] * n[4],
        m[1] * n[5] + m[3] * n[6] + m[5], m[2] * n[5] + m[4] * n[6] + m[6] }
end

local function apply(m, x, y)
    return m[1] * x + m[3] * y + m[5], m[2] * x + m[4] * y + m[6]
end

--- A colour as a grey (0 black .. 255 white), nil for none.
function Svg.grey(c)
    if not c or c == "" or c == "none" or c == "transparent" then return nil end
    c = c:lower()
    local named = { black = 0, white = 255, gray = 128, grey = 128, darkgray = 169, darkgrey = 169, lightgray = 211,
        lightgrey = 211, silver = 192, dimgray = 105, dimgrey = 105, gainsboro = 220, whitesmoke = 245 }
    if named[c] then return named[c] end
    local r, g, b = c:match("^#(%x%x)(%x%x)(%x%x)")
    if not r then
        r, g, b = c:match("^#(%x)(%x)(%x)$")
        if r then r, g, b = r .. r, g .. g, b .. b end
    end
    if r then return math.floor(0.3 * tonumber(r, 16) + 0.59 * tonumber(g, 16) + 0.11 * tonumber(b, 16) + 0.5) end
    local rr, gg, bb = c:match("rgb%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
    if rr then return math.floor(0.3 * rr + 0.59 * gg + 0.11 * bb + 0.5) end
    return 0
end

-- Points along a cubic Bezier curve (not the start).
local function cubic(out, x0, y0, x1, y1, x2, y2, x3, y3)
    for i = 1, 12 do
        local t = i / 12
        local u = 1 - t
        table.insert(out, u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3)
        table.insert(out, u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3)
    end
end

local function quad(out, x0, y0, x1, y1, x2, y2)
    for i = 1, 10 do
        local t = i / 10
        local u = 1 - t
        table.insert(out, u * u * x0 + 2 * u * t * x1 + t * t * x2)
        table.insert(out, u * u * y0 + 2 * u * t * y1 + t * t * y2)
    end
end

-- An elliptical arc (SVG's endpoint form) as points (not the start).
local function arc(out, x1, y1, rx, ry, phi, large, sweep, x2, y2)
    rx, ry = math.abs(rx), math.abs(ry)
    if rx == 0 or ry == 0 then
        table.insert(out, x2)
        table.insert(out, y2)
        return
    end
    local cp, sp = math.cos(math.rad(phi)), math.sin(math.rad(phi))
    local dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    local x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    local lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lambda > 1 then
        rx, ry = rx * math.sqrt(lambda), ry * math.sqrt(lambda)
    end
    local num_ = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    local den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    local coef = math.sqrt(math.max(0, num_ / den)) * ((large == sweep) and -1 or 1)
    local cxp, cyp = coef * rx * y1p / ry, -coef * ry * x1p / rx
    local cx, cy = cp * cxp - sp * cyp + (x1 + x2) / 2, sp * cxp + cp * cyp + (y1 + y2) / 2
    local function angle(ux, uy, vx, vy)
        local a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    end
    local t1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    local dt = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if sweep == 0 and dt > 0 then dt = dt - 2 * math.pi elseif sweep == 1 and dt < 0 then dt = dt + 2 * math.pi end
    local n = math.max(4, math.ceil(math.abs(dt) / (math.pi / 12)))
    for i = 1, n do
        local t = t1 + dt * i / n
        local ex, ey = rx * math.cos(t), ry * math.sin(t)
        table.insert(out, cp * ex - sp * ey + cx)
        table.insert(out, sp * ex + cp * ey + cy)
    end
end

-- A path's `d` as pieces: { { p = {...}, closed } }.
local function path(d)
    local tokens = {}
    for cmd, args in d:gmatch("([MmLlHhVvCcSsQqTtAaZz])([^MmLlHhVvCcSsQqTtAaZz]*)") do
        local v = {}
        for x in args:gmatch("[-+]?%d*%.?%d+[eE]?[-+]?%d*") do table.insert(v, tonumber(x)) end
        table.insert(tokens, { cmd, v })
    end
    local pieces, cur = {}, nil
    local x, y, sx, sy = 0, 0, 0, 0
    local lcx, lcy, lqx, lqy   -- last control points (for S and T)
    local function start(px, py)
        cur = { p = { px, py } }
        table.insert(pieces, cur)
        sx, sy = px, py
    end
    local function to(px, py)
        if not cur then start(x, y) end
        table.insert(cur.p, px)
        table.insert(cur.p, py)
    end
    for _, tk in ipairs(tokens) do
        local c, v = tk[1], tk[2]
        local rel = c:lower() == c
        local C = c:upper()
        local i = 1
        repeat
            local ox, oy = rel and x or 0, rel and y or 0
            local prevC = C
            if C == "M" then
                x, y = v[i] + ox, v[i + 1] + oy
                start(x, y)
                i = i + 2
                C = "L"     -- more pairs after M are lines
            elseif C == "L" then
                x, y = v[i] + ox, v[i + 1] + oy
                to(x, y)
                i = i + 2
            elseif C == "H" then
                x = v[i] + (rel and x or 0)
                to(x, y)
                i = i + 1
            elseif C == "V" then
                y = v[i] + (rel and y or 0)
                to(x, y)
                i = i + 1
            elseif C == "C" then
                local x1, y1, x2, y2, ex, ey = v[i] + ox, v[i + 1] + oy, v[i + 2] + ox, v[i + 3] + oy, v[i + 4] + ox, v[i + 5] + oy
                if not cur then start(x, y) end
                cubic(cur.p, x, y, x1, y1, x2, y2, ex, ey)
                lcx, lcy = x2, y2
                x, y = ex, ey
                i = i + 6
            elseif C == "S" then
                local x1, y1 = lcx and (2 * x - lcx) or x, lcy and (2 * y - lcy) or y
                local x2, y2, ex, ey = v[i] + ox, v[i + 1] + oy, v[i + 2] + ox, v[i + 3] + oy
                if not cur then start(x, y) end
                cubic(cur.p, x, y, x1, y1, x2, y2, ex, ey)
                lcx, lcy = x2, y2
                x, y = ex, ey
                i = i + 4
            elseif C == "Q" then
                local x1, y1, ex, ey = v[i] + ox, v[i + 1] + oy, v[i + 2] + ox, v[i + 3] + oy
                if not cur then start(x, y) end
                quad(cur.p, x, y, x1, y1, ex, ey)
                lqx, lqy = x1, y1
                x, y = ex, ey
                i = i + 4
            elseif C == "T" then
                local x1, y1 = lqx and (2 * x - lqx) or x, lqy and (2 * y - lqy) or y
                local ex, ey = v[i] + ox, v[i + 1] + oy
                if not cur then start(x, y) end
                quad(cur.p, x, y, x1, y1, ex, ey)
                lqx, lqy = x1, y1
                x, y = ex, ey
                i = i + 2
            elseif C == "A" then
                local ex, ey = v[i + 5] + ox, v[i + 6] + oy
                if not cur then start(x, y) end
                arc(cur.p, x, y, v[i], v[i + 1], v[i + 2], v[i + 3], v[i + 4], ex, ey)
                x, y = ex, ey
                i = i + 7
            elseif C == "Z" then
                if cur then
                    to(sx, sy)
                    cur.closed = true
                    cur = nil
                end
                x, y = sx, sy
            end
            if prevC ~= "C" and prevC ~= "S" then lcx, lcy = nil, nil end
            if prevC ~= "Q" and prevC ~= "T" then lqx, lqy = nil, nil end
        until C == "Z" or i > #v or v[i] == nil
    end
    return pieces
end

local function ellipse(cx, cy, rx, ry)
    local p = {}
    local n = math.max(24, math.min(96, math.floor((rx + ry) / 3)))
    for i = 0, n do
        local a = 2 * math.pi * i / n
        table.insert(p, cx + rx * math.cos(a))
        table.insert(p, cy + ry * math.sin(a))
    end
    return p
end

local function unescape(s)
    return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&#(%d+);", function(n)
        n = tonumber(n)
        return n < 128 and string.char(n) or ""
    end):gsub("&amp;", "&"))
end

--- The drawing in an SVG, or nil and why.
function Svg.parse(text)
    -- A whole SVG, or (an answer cut short) as much of one as there is: the
    -- last, unfinished tag is left out.
    local svg = text:match("<svg.-</svg>")
    if not svg then
        local start = text:match("<svg.*")
        if start then svg = start:gsub("<[^>]*$", "") .. "</svg>" end
    end
    if not svg then return nil, "no drawing in the answer" end
    local root = attrs(svg:match("<svg(.-)>") or "")
    local vb = {}
    for x in (root.viewBox or ""):gmatch("[-+]?[%d%.]+") do table.insert(vb, tonumber(x)) end
    local out = { x = vb[1] or 0, y = vb[2] or 0, w = vb[3] or num(root.width, 100), h = vb[4] or num(root.height, 100), lines = {}, texts = {} }
    -- Groups: their transform and style pass to what they hold.
    local stack = { { m = { 1, 0, 0, 1, 0, 0 }, a = {} } }
    local function inherit(a)
        local top = stack[#stack]
        local merged = {}
        for k, v in pairs(top.a) do merged[k] = v end
        for k, v in pairs(a) do merged[k] = v end
        return merged, combine(top.m, transform(a.transform))
    end
    local function addLine(points, closed, a, m)
        local p = {}
        for i = 1, #points - 1, 2 do
            local px, py = apply(m, points[i], points[i + 1])
            table.insert(p, px)
            table.insert(p, py)
        end
        if #p < 2 then return end
        local fill = nil
        if closed then fill = Svg.grey(a.fill == nil and "black" or a.fill) end
        local stroke = a.stroke
        local scale = math.sqrt(math.abs(m[1] * m[4] - m[2] * m[3]))
        if stroke == "none" and not fill then return end
        table.insert(out.lines, {
            p = p,
            closed = closed or false,
            width = num(a["stroke-width"], 2) * scale,
            fill = fill ~= nil and fill < 250 and fill or nil,
            grey = stroke ~= "none" and Svg.grey(stroke or "black") or nil,
            dashed = a["stroke-dasharray"] and a["stroke-dasharray"] ~= "none" or nil,
            noStroke = stroke == "none" or nil,
        })
    end
    local pos = 1
    while true do
        local s, e, tag = svg:find("<(.-)>", pos)
        if not s then break end
        pos = e + 1
        local name = tag:match("^/?([%w:]+)")
        local closing = tag:sub(1, 1) == "/"
        local selfClosing = tag:sub(-1) == "/"
        if name == "g" or name == "a" then
            if closing then
                if #stack > 1 then table.remove(stack) end
            elseif not selfClosing then
                local a, m = inherit(attrs(tag))
                a.transform = nil
                table.insert(stack, { m = m, a = a })
            end
        elseif not closing and name ~= "svg" then
            local a, m = inherit(attrs(tag))
            -- A shape with no fill set is filled black in SVG; for line art a
            -- shape with a stroke but no fill is taken as an outline.
            if a.fill == nil and a.stroke and a.stroke ~= "none" then a.fill = "none" end
            if name == "line" then
                addLine({ num(a.x1, 0), num(a.y1, 0), num(a.x2, 0), num(a.y2, 0) }, false, a, m)
            elseif name == "polyline" or name == "polygon" then
                local pts = {}
                for x in (a.points or ""):gmatch("[-+]?%d*%.?%d+[eE]?[-+]?%d*") do table.insert(pts, tonumber(x)) end
                if name == "polygon" and #pts >= 4 then
                    table.insert(pts, pts[1])
                    table.insert(pts, pts[2])
                end
                addLine(pts, name == "polygon", a, m)
            elseif name == "rect" then
                local x, y, w, h = num(a.x, 0), num(a.y, 0), num(a.width, 0), num(a.height, 0)
                addLine({ x, y, x + w, y, x + w, y + h, x, y + h, x, y }, true, a, m)
            elseif name == "circle" then
                local r = num(a.r, 0)
                addLine(ellipse(num(a.cx, 0), num(a.cy, 0), r, r), true, a, m)
            elseif name == "ellipse" then
                addLine(ellipse(num(a.cx, 0), num(a.cy, 0), num(a.rx, 0), num(a.ry, 0)), true, a, m)
            elseif name == "path" and a.d then
                for _, piece in ipairs(path(a.d)) do addLine(piece.p, piece.closed, a, m) end
            elseif name == "text" and not selfClosing then
                local close = svg:find("</text>", pos, true)
                local inner = close and svg:sub(pos, close - 1) or ""
                inner = unescape(inner:gsub("<[^>]*>", ""):gsub("%s+", " ")):match("^%s*(.-)%s*$")
                if inner ~= "" then
                    local x, y = apply(m, num(a.x, 0), num(a.y, 0))
                    local scale = math.sqrt(math.abs(m[1] * m[4] - m[2] * m[3]))
                    table.insert(out.texts, { x = x, y = y, size = num(a["font-size"], 16) * scale, text = inner,
                        anchor = a["text-anchor"] })
                end
                if close then pos = close + 7 end
            end
        end
    end
    if #out.lines == 0 and #out.texts == 0 then return nil, "the drawing was empty" end
    return out
end

--- The drawing fitted into the box { x, y, w, h } on the page (keeping its
-- shape, centred): strokes (tip `t`, at least `minWidth` wide) and text
-- boxes. `textHeight(size)`: a text size in pixels from SVG units scaled.
function Svg.place(drawing, box, minWidth, t)
    local s = math.min(box[3] / drawing.w, box[4] / drawing.h)
    local ox = box[1] + (box[3] - drawing.w * s) / 2 - drawing.x * s
    local oy = box[2] + (box[4] - drawing.h * s) / 2 - drawing.y * s
    local strokes, texts = {}, {}
    for _, l in ipairs(drawing.lines) do
        local p = {}
        for i = 1, #l.p - 1, 2 do
            table.insert(p, math.floor(ox + l.p[i] * s + 0.5))
            table.insert(p, math.floor(oy + l.p[i + 1] * s + 0.5))
        end
        local w = math.max(minWidth or 2, math.floor(l.width * s + 0.5))
        local q = {}
        for i = 1, #p / 2 do q[i] = w end
        local stroke = { t = t, w = w, p = p, q = q }
        if l.grey and l.grey > 20 then stroke.c = math.min(0xC0, l.grey) end
        if l.dashed then stroke.d = "dash" end
        if l.fill then stroke.f = math.max(0x60, l.fill) end
        if l.noStroke then
            -- A filled shape without an outline: the outline in the fill's grey.
            stroke.c = stroke.f or 0x80
            stroke.w = 1
            for i = 1, #q do q[i] = 1 end
        end
        table.insert(strokes, stroke)
    end
    for _, tx in ipairs(drawing.texts) do
        local size = math.max(28, math.floor(tx.size * s + 0.5))
        local width = math.floor(#tx.text * size * 0.6) + size
        local x = ox + tx.x * s
        if tx.anchor == "middle" then x = x - width / 2 elseif tx.anchor == "end" then x = x - width end
        table.insert(texts, { k = "text", x = math.floor(x + 0.5), y = math.floor(oy + tx.y * s - size * 0.95 + 0.5),
            w = width, size = size, text = tx.text,
            align = (tx.anchor == "middle" and "center") or (tx.anchor == "end" and "right") or nil })
    end
    return strokes, texts
end

return Svg
