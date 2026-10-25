--[[--
The Library's full screen: the shared title bar (librarybar), then a page of
items drawn as the other apps draw theirs (SSH's sshpage, To Do's views), in
pages (swipe, or ‹ n/m › in the bar), with an optional row of buttons and a
status line at the foot.

Items (each optional field as it says):
  { band = "READING", right = "3", tap, hold, menu }    a grey heading (menu: a ⋮ for what the group can do)
  { text, sub, icon, right, chevron, tap, hold, tick }   a row (tick: true/false in Select)
  { book = b, sub, right, bar, tap, hold, tick }         a book: a small cover, its title and a second line
  { covers = { b, ... }, sub = fn(b), bar = fn(b), tap = fn(b), hold = fn(b), ticks = { [path] = true } | nil }
  { chips = { { text, on, fn } } }                       the views across the top
  { stat = "Name", value, tap }                          a name and its value (a book's page)
  { setting = "Name", value, tap } { toggle = bool, text, sub, tap }
  { top = details, book = b }                            a book's page: cover, title, progress, status
  { found = match, book = b, coverTick, tapCover, lines } Find details online: both covers, what was found
  { pick = "Name", value, now, tick, long, tap }         a detail found, to save or not
  { continue = b, sub }                                  the last book, big (Home)
  { strip = { b, ... }, tap, hold }                      a row of small covers (Home's Recent)
  { para = "…" } { note = "…" } { message = "…" } { gap = units }
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Screen = Device.screen

local Canvas = require("librarycanvas")
local Bar = require("librarybar")
local Covers = require("librarycovers")
local KO = require("libraryko")
local Model = require("librarymodel")
local C = Canvas

-- (gettext with a template)
local function T_(s, ...)
    return require("ffi/util").template(_(s), ...)
end

Canvas.setDir((debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."))

local Page = InputContainer:extend{
    covers_fullscreen = true,
    flash_on_uncover = true,
    -- set by the views: title, subtitle, items (a list) or items_fn, bar_buttons,
    -- buttons (the foot row), status = fn() -> left, right, tap; back, menu, refresh
}

-- ------------------------------------------------------------------ drawing helpers

local function chevron(c, y, h)
    c:icon("chevron-right", c.W - 26, y + h / 2 - 6, 12)
end

local function tickBox(c, x, y, on)
    c:icon(on and "square-check" or "square", x, y, 18)
end

local function progressBar(c, x, y, w, frac, h)
    h = h or 6
    c:box(x, y, w, h, { r = h / 2, border = C.BLACK, bw = 1 })
    if frac and frac > 0 then c:box(x, y, math.max(h, w * math.min(1, frac)), h, { r = h / 2, fill = C.FILL }) end
end
Page.progressBar = progressBar

--- A book's cover at (x, y), w × h units: its picture, or a plain one with its title.
function Page.cover(page, c, b, x, y, w, h)
    local px, ph = c:X(w), c:X(h)
    local bb = Covers.get(b, px, ph)
    if bb then
        local bw, bh = bb:getWidth() / c.u, bb:getHeight() / c.u
        -- (fitted inside, at the bottom: covers line up along their bottoms)
        local ox, oy = x + (w - bw) / 2, y + h - bh
        c:image(bb, ox, oy)
        c:box(ox, oy, bw, bh, { border = C.BLACK, bw = 0.8 })
        return
    end
    Covers.want(b, page and function() page:redraw() end)
    c:box(x, y, w, h, { r = 2, fill = C.WHITE, border = C.BLACK, bw = 1 })
    if w >= 50 then
        local size = math.max(7.5, math.min(13, w / 9))
        local lines = c:wrap(Model.title(b), size, w - 14, 5)
        for i, l in ipairs(lines) do c:text(x + w / 2, y + 12 + size * 1.3 * i, l, size, { bold = true, align = "middle", maxw = w - 10 }) end
        local a = Model.firstAuthor(b)
        if a then c:text(x + w / 2, y + h - 10, a, size * 0.75, { align = "middle", color = C.GREY, maxw = w - 10 }) end
    else
        c:icon("book", x + w / 2 - 8, y + h / 2 - 8, 16)
    end
end

-- ------------------------------------------------------------------ the items

local draw = {}

function draw.band(page, c, F, it)
    F:block(24, function(y)
        c:rect(0, y + 2, c.W, 22, C.PALE)
        c:text(14, y + 17, it.band, 9.5, { bold = true, color = C.GREY, maxw = c.W - 120 })
        local rx = c.W - 14
        if it.menu then
            c:icon("ellipsis-vertical", c.W - 26, y + 7, 12)
            rx = c.W - 32
        end
        if it.right then c:text(rx, y + 17, it.right, 9.5, { align = "end", color = C.GREY }) end
        if it.tap or it.hold then c:hit(0, y, c.W, 26, it.tap or it.hold, it.hold) end
    end, it.keep or 46)
end

function draw.row(page, c, F, it)
    local h = (it.sub and it.sub ~= "") and 46 or 38
    F:block(h, function(y)
        local x = 14
        if it.tick ~= nil then
            tickBox(c, 14, y + h / 2 - 9, it.tick)
            x = 44
        end
        if it.icon then
            c:icon(it.icon, x, y + h / 2 - 9, 18)
            x = x + 28
        end
        local rx = it.chevron and c.W - 32 or c.W - 14
        local rw = 0
        if it.right and it.right ~= "" then
            rw = math.min(c:width(it.right, 10.5) + 10, 220)
            c:text(rx, y + (h > 40 and 20 or 24), it.right, 10.5, { align = "end", color = C.GREY, maxw = 210 })
        end
        local color = it.enabled == false and C.MID or C.BLACK
        if it.sub and it.sub ~= "" then
            c:text(x, y + 20, it.text or "", 12.5, { maxw = rx - x - rw - 6, color = color, bold = it.bold })
            c:text(x, y + 37, it.sub, 10, { maxw = rx - x - 6, color = C.GREY })
        else
            c:text(x, y + 24, it.text or "", 12.5, { maxw = rx - x - rw - 6, color = color, bold = it.bold })
        end
        if it.chevron then chevron(c, y, h) end
        c:hline(x, y + h, c.W - x)
        if it.enabled ~= false and (it.tap or it.hold) then c:hit(0, y, c.W, h, it.tap or it.hold, it.hold) end
    end)
end

function draw.book(page, c, F, it)
    local h = 64
    local b = it.book
    F:block(h, function(y)
        local x = 14
        if it.tick ~= nil then
            tickBox(c, 14, y + h / 2 - 9, it.tick)
            x = 44
        end
        Page.cover(page, c, b, x, y + 7, 34, 50)
        local tx = x + 48
        local rx = c.W - 32
        local rw = 0
        if it.right then
            rw = math.min(c:width(it.right, 10.5) + 10, 160)
            c:text(rx, y + 23, it.right, 10.5, { align = "end", color = C.GREY, maxw = 150 })
        end
        c:text(tx, y + 23, it.text or Model.title(b), 12.5, { maxw = rx - tx - rw - 6 })
        if it.sub then c:text(tx, y + 41, it.sub, 10, { color = C.GREY, maxw = rx - tx - 6 }) end
        if it.right2 then c:text(rx, y + 41, it.right2, 10, { align = "end", color = C.GREY, maxw = 150 }) end
        if it.bar then progressBar(c, tx, y + 49, 150, it.bar, 5) end
        chevron(c, y, h)
        c:hline(tx, y + h, c.W - tx)
        c:hit(0, y, c.W, h, it.tap, it.hold)
    end)
end

function draw.covers(page, c, F, it)
    local cols = it.cols or 5
    local gap = 12
    local cw = (c.W - 28 - gap * (cols - 1)) / cols
    local ch = cw * 1.5
    local list = it.covers
    for i = 1, #list, cols do
        F:block(ch + 52, function(y)
            for k = 0, cols - 1 do
                local b = list[i + k]
                if b then
                    local x = 14 + k * (cw + gap)
                    Page.cover(page, c, b, x, y + 6, cw, ch)
                    local ty = y + 6 + ch
                    c:text(x, ty + 16, Model.title(b), 11, { bold = true, maxw = cw })
                    local frac = it.bar and it.bar(b)
                    if frac then
                        progressBar(c, x, ty + 25, cw * 0.62, frac, 5)
                        c:text(x + cw, ty + 31, math.floor(frac * 100 + 0.5) .. "%", 9.5, { align = "end", color = C.GREY })
                    elseif it.sub then
                        c:text(x, ty + 32, it.sub(b) or "", 10, { color = C.GREY, maxw = cw })
                    end
                    if it.ticks then
                        -- (Select: a tick on the cover's corner)
                        local on = it.ticks[b.path] and true or false
                        c:box(x + 4, y + 10, 26, 26, { r = 4, fill = C.WHITE })
                        tickBox(c, x + 8, y + 14, on)
                    end
                    c:hit(x - gap / 2, y, cw + gap, ch + 50, function() it.tap(b) end, it.hold and function() it.hold(b) end)
                end
            end
        end)
    end
end

function draw.strip(page, c, F, it)
    local n, gap = 6, 12
    local cw = (c.W - 28 - gap * (n - 1)) / n
    local ch = cw * 1.5
    F:block(ch + 34, function(y)
        for i = 1, math.min(n, #it.strip) do
            local b = it.strip[i]
            local x = 14 + (i - 1) * (cw + gap)
            Page.cover(page, c, b, x, y + 6, cw, ch)
            c:text(x, y + ch + 22, Model.stateText(b.path), 9.5, { color = C.GREY, maxw = cw })
            c:hit(x - gap / 2, y, cw + gap, ch + 30, function() it.tap(b) end, it.hold and function() it.hold(b) end)
        end
    end)
end

function draw.continue(page, c, F, it)
    local b = it.continue
    F:block(160, function(y)
        Page.cover(page, c, b, 14, y + 10, 92, 138)
        local x = 122
        c:text(x, y + 30, _("CONTINUE READING"), 9.5, { bold = true, color = C.GREY })
        c:text(x, y + 54, Model.title(b), 17, { bold = true, maxw = c.W - x - 14 })
        local a = Model.authors(b)
        if a then c:text(x, y + 74, (a:gsub("\n", ", ")), 12, { color = C.GREY, maxw = c.W - x - 14 }) end
        local p = Model.progress(b.path)
        progressBar(c, x, y + 90, c.W - x - 150, p or 0, 8)
        if it.sub then c:text(x, y + 116, it.sub, 10.5, { color = C.GREY, maxw = c.W - x - 150 }) end
        local bw = 118
        c:box(c.W - 14 - bw, y + 84, bw, 34, { r = 17, fill = C.FILL })
        c:icon("book-open", c.W - 14 - bw + 18, y + 92, 18, true)
        c:text(c.W - 14 - bw + 44, y + 106, _("Continue"), 12, { bold = true, color = C.ON_FILL })
        c:hit(0, y, c.W, 160, it.tap, it.hold)
    end)
end

function draw.chips(page, c, F, it)
    F:block(36, function(y)
        local x = 14
        for __, ch in ipairs(it.chips) do
            local w = c:width(ch.text, 10.5, ch.on) + 20
            if x + w > c.W - 8 then break end
            c:box(x, y + 6, w, 24, { r = 12, fill = ch.on and C.FILL or C.WHITE, border = C.BLACK, bw = 1.1 })
            c:text(x + w / 2, y + 22, ch.text, 10.5, { bold = ch.on, align = "middle", color = ch.on and C.ON_FILL or C.BLACK })
            c:hit(x - 3, y + 2, w + 6, 32, ch.fn, ch.hold)
            x = x + w + 6
        end
    end)
end

function draw.stat(page, c, F, it)
    F:block(32, function(y)
        c:text(14, y + 21, it.stat, 12, { maxw = 260 })
        local rx = it.tap and c.W - 32 or c.W - 14
        if it.value then c:text(rx, y + 21, it.value, 11.5, { align = "end", color = C.GREY, maxw = c.W - 300 }) end
        if it.tap then chevron(c, y, 32) end
        c:hline(14, y + 32, c.W - 14)
        if it.tap then c:hit(0, y, c.W, 32, it.tap) end
    end)
end

function draw.setting(page, c, F, it)
    local h = it.hint and 46 or 36
    F:block(h, function(y)
        c:text(14, y + 23, it.setting or "", 12, { maxw = 330 })
        if it.hint then c:text(14, y + 39, it.hint, 9.5, { color = C.GREY, maxw = c.W - 70 }) end
        if it.value and it.value ~= "" then c:text(c.W - 32, y + 23, it.value, 11, { align = "end", color = C.GREY, maxw = 250 }) end
        chevron(c, y, 36)
        c:hline(14, y + h, c.W - 14)
        if it.tap then c:hit(0, y, c.W, h, it.tap) end
    end)
end

function draw.toggle(page, c, F, it)
    local h = (it.sub and it.sub ~= "") and 46 or 36
    F:block(h, function(y)
        c:text(14, y + (h > 40 and 20 or 23), it.text or "", 12, { maxw = c.W - 94 })
        if it.sub and it.sub ~= "" then c:text(14, y + 37, it.sub, 10, { color = C.GREY, maxw = c.W - 94 }) end
        local on = it.toggle
        local x, ty = c.W - 54, y + h / 2 - 11
        c:box(x, ty, 40, 22, { r = 11, fill = on and C.FILL or C.WHITE, border = C.BLACK, bw = 1.2 })
        c:circle(on and x + 29 or x + 11, ty + 11, 7, on and C.WHITE or C.BLACK)
        c:hline(14, y + h, c.W - 14)
        if it.tap then c:hit(0, y, c.W, h, it.tap) end
    end)
end

function draw.top(page, c, F, it)
    local d, b = it.top, it.book
    F:block(196, function(y)
        Page.cover(page, c, b, 14, y + 8, 128, 182)
        local x, w = 158, c.W - 172
        local lines = c:wrap(d.title or "", 18, w, 2)
        local ty = y + 30
        for __, l in ipairs(lines) do
            c:text(x, ty, l, 18, { bold = true, maxw = w })
            ty = ty + 22
        end
        if d.authors then
            c:text(x, ty, (d.authors:gsub("\n", ", ")), 12.5, { color = C.GREY, maxw = w })
            ty = ty + 18
        end
        if d.series then
            c:text(x, ty, d.series .. (d.seriesIndex and (" · " .. T_("Book %1", Page.num(d.seriesIndex))) or ""), 11.5, { bold = true, maxw = w })
            ty = ty + 17
        end
        local facts = {}
        if d.format then table.insert(facts, d.format) end
        if d.size then table.insert(facts, Model.size(d.size)) end
        if d.pages then table.insert(facts, T_("%1 pages", d.pages)) end
        c:text(x, ty, table.concat(facts, " · "), 10.5, { color = C.GREY, maxw = w })
        ty = ty + 12
        progressBar(c, x, ty, w, d.progress or 0, 10)
        ty = ty + 28
        local left
        if d.status == "complete" then left = _("Finished")
        elseif d.progress then
            local pct = math.floor(d.progress * 100 + 0.5)
            left = d.pages and T_("%1% · page %2 of %3", pct, math.max(1, math.floor(d.progress * d.pages + 0.5)), d.pages) or (pct .. "%")
        else left = _("Not started") end
        c:text(x, ty, left, 11.5)
        if d.left then c:text(c.W - 14, ty, d.left, 11.5, { bold = true, align = "end" }) end
        ty = ty + 12
        -- The status: a tap sets it (To read only while never opened).
        local cx = x
        for __, s in ipairs(it.statuses or {}) do
            local on = s.value == d.status
            local cw = c:width(s.text, 10.5, on) + (on and 40 or 22)
            if cx + cw > c.W - 10 then break end
            c:box(cx, ty, cw, 26, { r = 13, fill = on and C.FILL or C.WHITE, border = C.BLACK, bw = 1.1 })
            if on then
                c:icon("check", cx + 9, ty + 5, 15, true)
                c:text(cx + 28, ty + 18, s.text, 10.5, { bold = true, color = C.ON_FILL })
            else
                c:text(cx + cw / 2, ty + 18, s.text, 10.5, { align = "middle" })
            end
            if s.fn then c:hit(cx - 3, ty - 4, cw + 6, 34, s.fn) end
            cx = cx + cw + 6
        end
        local extra = {}
        if #d.collections > 0 then table.insert(extra, T_("In %1", table.concat(d.collections, ", "))) end
        if (d.highlights or 0) > 0 then table.insert(extra, d.highlights == 1 and _("1 highlight") or T_("%1 highlights", d.highlights)) end
        if (d.notes or 0) > 0 then table.insert(extra, d.notes == 1 and _("1 note") or T_("%1 notes", d.notes)) end
        if #extra > 0 then c:text(x, ty + 44, table.concat(extra, " · "), 10, { color = C.GREY, maxw = w }) end
    end)
end

-- Find details online: the book's cover beside the one found (a tick: save it), and what was found.
function draw.found(page, c, F, it)
    local f = it.found
    F:block(196, function(y)
        Page.cover(page, c, it.book, 14, y + 8, 96, 144)
        c:text(62, y + 172, _("In the book"), 10, { align = "middle", color = C.GREY, maxw = 100 })
        local x = 124
        if f.coverFile then
            local bb = Covers.file(f.coverFile, c:X(96), c:X(144))
            if bb then
                local bw, bh = bb:getWidth() / c.u, bb:getHeight() / c.u
                local ox, oy = x + (96 - bw) / 2, y + 8 + 144 - bh
                c:image(bb, ox, oy)
                c:box(ox, oy, bw, bh, { border = C.BLACK, bw = 0.8 })
            end
            tickBox(c, x + 2, y + 158, it.coverTick)
            c:text(x + 26, y + 172, _("New cover"), 11, { maxw = 90 })
            c:hit(x - 4, y, 104, 186, it.tapCover)
            x = 238
        end
        local w = c.W - x - 14
        local ty = y + 30
        for __, l in ipairs(c:wrap(f.title or "", 17, w, 2)) do
            c:text(x, ty, l, 17, { bold = true, maxw = w })
            ty = ty + 21
        end
        if f.authors then
            c:text(x, ty, (f.authors:gsub("\n", ", ")), 12, { color = C.GREY, maxw = w })
            ty = ty + 24
        end
        for __, l in ipairs(it.lines or {}) do
            for __, part in ipairs(c:wrap(l, 10.5, w, 3)) do
                c:text(x, ty, part, 10.5, { color = C.GREY, maxw = w })
                ty = ty + 16
            end
            ty = ty + 4
        end
    end)
end

-- A detail to save or not: its tick, its name, what was found (right, or a
-- paragraph when long) and what the book has under it.
function draw.pick(page, c, F, it)
    local lines = it.long and c:wrap(it.value or "", 11, c.W - 174, 4) or nil
    local h = lines and (30 + 16 * #lines) or 50
    F:block(h, function(y)
        tickBox(c, 14, y + 12, it.tick)
        c:text(44, y + 25, it.pick, 12.5, { maxw = 110 })
        if lines then
            for i, l in ipairs(lines) do c:text(160, y + 9 + 16 * i, l, 11, { maxw = c.W - 174 }) end
            c:text(160, y + h - 8, it.now, 10, { color = C.GREY, maxw = c.W - 174 })
        else
            c:text(c.W - 14, y + 22, it.value or "", 11.5, { bold = true, align = "end", maxw = c.W - 170 })
            c:text(c.W - 14, y + 40, it.now or "", 10, { align = "end", color = C.GREY, maxw = c.W - 170 })
        end
        c:hline(44, y + h, c.W - 44)
        if it.tap then c:hit(0, y, c.W, h, it.tap) end
    end)
end

function draw.para(page, c, F, it)
    local lines = c:wrap(it.para, 11.5, c.W - 28, it.max or 12)
    for i, l in ipairs(lines) do
        F:block(18, function(y) c:text(14, y + 14, l, 11.5) end)
        if i == 1 then F:gap(0) end
    end
    F:gap(8)
end

function draw.note(page, c, F, it)
    local lines = c:wrap(it.note, 10, c.W - 28, 6)
    F:block(10 + 15 * #lines, function(y)
        for i, l in ipairs(lines) do c:text(14, y + 4 + 15 * i, l, 10, { color = C.GREY }) end
    end)
end

function draw.message(page, c, F, it)
    F:block(80, function(y)
        local lines = c:wrap(it.message, 12, c.W - 60, 3)
        for i, l in ipairs(lines) do c:text(c.W / 2, y + 26 + 18 * i, l, 12, { align = "middle", color = C.MID }) end
    end)
end

local function kindOf(it)
    if it.band then return "band" end
    if it.covers then return "covers" end
    if it.strip then return "strip" end
    if it.continue then return "continue" end
    if it.chips then return "chips" end
    if it.stat then return "stat" end
    if it.top then return "top" end
    if it.found then return "found" end
    if it.pick then return "pick" end
    if it.book then return "book" end
    if it.setting then return "setting" end
    if it.toggle ~= nil then return "toggle" end
    if it.para then return "para" end
    if it.note then return "note" end
    if it.message then return "message" end
    if it.gap then return "gap" end
    return "row"
end

function Page.num(n)
    n = tonumber(n)
    if not n then return "" end
    if n == math.floor(n) then return tostring(math.floor(n)) end
    return tostring(n)
end

-- ------------------------------------------------------------------ the buttons at the foot

-- The launcher's button row (PS.popup.iconButtons), or this copy without it.
local function iconButtons(c, x, y, bw, buttons, act)
    local P = require("pluginshare").popup
    local shared = P and P.iconButtons
    if shared then return shared(c, x, y, bw, buttons, act) end
    local gap = 10
    local n = math.max(1, #buttons)
    local w = math.min((bw - 36 - gap * (n - 1)) / n, (bw - 36 - gap * 4) / 5)
    local bx = x + bw - 18 - (n * w + gap * (n - 1))
    for __, b in ipairs(buttons) do
        c:box(bx, y + 10, w, 56, { r = 14, fill = b.primary and C.FILL or C.WHITE, border = C.BLACK, bw = 1.2 })
        if b.icon then c:icon(b.icon, bx + w / 2 - 11, y + 17, 22, b.primary) end
        c:text(bx + w / 2, b.icon and (y + 58) or (y + 44), b.text or "", 10.5, { bold = true, align = "middle", maxw = w - 8,
            color = b.primary and C.ON_FILL or C.BLACK })
        c:hit(bx, y + 6, w, 64, function() act(b) end)
        bx = bx + w + gap
    end
end

-- ------------------------------------------------------------------ the page

function Page:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local all = function() return self.dimen end
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = all } },
        Hold = { GestureRange:new{ ges = "hold", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    self.page = self.page or 1
    self:render()
end

function Page:render()
    if self.canvas then self.canvas:release() end
    local c = Canvas.new(self.w, self.h, false)
    self.canvas = c
    if self.build then self.build(self) end
    local foot = (self.status and 30 or 0) + (self.buttons and #self.buttons > 0 and 80 or 0)
    local F = c:flow(Bar.H + 4, c.H - 6 - foot, self.page)
    for __, it in ipairs(self.items or {}) do
        local k = kindOf(it)
        if k == "gap" then F:gap(it.gap) else draw[k](self, c, F, it) end
    end
    self.pages = F:pages()
    if self.page > self.pages then
        self.page = self.pages
        return self:render()
    end
    local y = c.H
    if self.status then
        local left, right, tap = self.status()
        y = c.H - 30
        c:rect(0, y, c.W, 30, C.WHITE)
        c:hline(0, y, c.W, C.BLACK, 1)
        if left then c:text(14, y + 20, left, 10, { maxw = c.W / 2 - 20 }) end
        if right then c:text(c.W - 14, y + 20, right, 10, { align = "end", color = C.GREY, maxw = c.W / 2 - 20 }) end
        if tap then c:hit(0, y, c.W, 30, tap) end
    end
    if self.buttons and #self.buttons > 0 then
        y = y - 80
        c:rect(0, y, c.W, 80, C.WHITE)
        c:hline(0, y, c.W, C.BLACK, 1)
        iconButtons(c, 0, y, c.W, self.buttons, function(b) if b.fn then b.fn() end end)
    end
    local PS = require("pluginshare")
    Bar.draw(c, {
        title = self.title,
        subtitle = self.subtitle,
        back = function() self:goBack() end,
        home = PS.appsHome and function() self:goHome() end or nil,
        buttons = self.bar_buttons,
        pager = { page = self.page, pages = self.pages, turn = function(d) self:turn(d) end },
        clock = true,
        refresh = function() self:refreshPage() end,
        bell = PS.showNotifications and function() PS.showNotifications() end or nil,
        menu = self.menu and function() self.menu(self) end or nil,
    })
end

function Page:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.w, self.h, Blitbuffer.COLOR_WHITE)
    if self.canvas then self.canvas:paint(bb, x, y) end
    if not self.ticking then self:tick() end
end

--- The clock: drawn again each minute while this page is on top.
function Page:tick()
    self.ticking = true
    self.tickTask = function()
        self.ticking = false
        if UIManager:getTopmostVisibleWidget() ~= self then return end
        self:render()
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.w, h = self.canvas:X(Bar.H) })
        self:tick()
    end
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), self.tickTask)
end

function Page:redraw(mode)
    if self.closed then return end
    self:render()
    UIManager:setDirty(self, mode or "ui")
end

function Page:notificationsChanged() self:redraw() end

function Page:turn(d)
    local n = math.max(1, math.min(self.pages or 1, self.page + d))
    if n == self.page then return end
    self.page = n
    if self.onTurn then self.onTurn(self) end
    self:redraw("full")
end

function Page:refreshPage()
    if self.refresh then self.refresh(self) end
    self:redraw("full")
end

function Page:onTap(__, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y)
    if hit and hit.tap then hit.tap() end
    return true
end

function Page:onHold(__, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y)
    if hit then
        if hit.hold then hit.hold() elseif hit.tap then hit.tap() end
    end
    return true
end

function Page:onSwipe(__, ges)
    local d = ges.direction
    if d == "northeast" or d == "northwest" or d == "southeast" or d == "southwest" then
        UIManager:setDirty(self, "full")
        return true
    end
    if KO.fromLeftEdge(ges) then self:goBack() return true end
    if d == "west" or d == "north" then self:turn(1)
    elseif d == "east" or d == "south" then self:turn(-1) end
    return true
end

function Page:goBack()
    if self.back then return self.back(self) end
    self:onClose()
end

function Page:goHome()
    if self.home then return self.home(self) end
    self:onClose()
    KO.home()
end

function Page:onClose()
    if self.closed then return true end
    UIManager:close(self, "full")
    return true
end
Page.onCloseAllMenus = Page.onClose

function Page:onCloseWidget()
    self.closed = true
    if self.tickTask then UIManager:unschedule(self.tickTask) end
    self.ticking = true
    if self.canvas then self.canvas:release() end
    if self.close_callback then self.close_callback(self) end
end

-- (the test driver's: a row tapped, as KOReader's Menu has it)
function Page:tapItem(i)
    local it = self.items and self.items[i]
    if it and it.tap then it.tap() end
end

return Page
