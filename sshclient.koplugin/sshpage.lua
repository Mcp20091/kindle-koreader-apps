--[[--
SSH's full-screen pages, drawn as the other apps draw theirs (Home Assistant's
haview, To Do's views): the shared title bar (sshtitle), grey capital
headings, rows with an icon and a second line, settings rows with switches,
tiles, stat tiles and quick buttons, and the page counter in the title bar
(swipe, or ‹ n/m ›). A status line can end the page.

It keeps the calls SSH's screens make (KOReader's Menu had them): a page is
made with `{ title, subtitle, item_table, items_fn, close_callback, top,
bar_buttons, status }` and changed with `switchItemTable(title, items, page)`.

Items (each optional field as it says):
  { band = "HOSTS", right = "3" }                      a heading
  { text, sub, icon, mono, right | mandatory, chevron, dot = "on" | "off",
    callback, hold_callback }                          a row (sub: second line; mono: it in a fixed font)
  { setting = true, text, value, hint, callback }      a settings row (value and ›)
  { toggle = true | false, text, sub, icon, callback } a settings row with a switch
  { tiles = { { icon, text, sub, primary, fn, hold } }, cols }
  { stats = { { icon, label, value, sub, bar } }, cols }   bar: 0..1
  { quick = { { icon, text, sub, fn, hold } }, cols }
  { chips = { { text, on, fn } } }                     filters
  { note = "…" }  { line = "…", mono }  { message = "…" }  { gap = units }
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local Canvas = require("sshcanvas")
local Bar = require("sshtitle")
local KO = require("sshko")
local C = Canvas

Canvas.setDir((debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."))

local Page = InputContainer:extend{
    covers_fullscreen = true,
    flash_on_uncover = true,   -- a full refresh when a dialog over it closes (KO.flashOnUncover)
    title = "",
    subtitle = nil,
    item_table = nil,
    items_fn = nil,
    close_callback = nil,
    top = false,
    bar_buttons = nil,
    status = nil,              -- fn() -> left, right, tap: the line at the foot
}

local function UI() return require("sshui") end

-- ------------------------------------------------------------------ drawing helpers

local monoFaces = {}

--- Text in the terminal's fixed font (commands, addresses), baseline at y.
function Page.mono(c, x, y, s, size, opts)
    opts = opts or {}
    if not s or s == "" then return 0 end
    local px = c:X(size)
    local f = monoFaces[px]
    if not f then
        f = Font:getFace("smallinfont", px / (Screen:scaleBySize(1000) / 1000))
        monoFaces[px] = f
    end
    if opts.maxw then
        local maxpx = c:X(opts.maxw)
        if RenderText:sizeUtf8Text(0, Screen:getWidth() * 4, f, s, true, false).x > maxpx then
            s = RenderText:truncateTextByWidth(s, f, maxpx, true, false)
        end
    end
    local w = RenderText:sizeUtf8Text(0, Screen:getWidth() * 4, f, s, true, false).x
    local ix, iy = c:X(x), c:X(y)
    if opts.align == "end" then ix = ix - w end
    local color = c:col(opts.color or C.BLACK)
    table.insert(c.ops, function(bb, ox, oy) RenderText:renderUtf8Text(bb, ox + ix, oy + iy, f, s, true, false, color) end)
    return w / c.u
end

--- A switch, as in every app's settings: 40 by 22, black with the knob at the right when on.
local function toggle(c, x, y, on)
    c:box(x, y, 40, 22, { r = 11, fill = on and C.FILL or C.WHITE, border = C.BLACK, bw = 1.2 })
    c:circle(on and x + 29 or x + 11, y + 11, 7, on and C.WHITE or C.BLACK)
end
Page.toggle = toggle

local function chevron(c, y, h)
    c:icon("chevron-right", c.W - 26, y + h / 2 - 6, 12)
end

-- ------------------------------------------------------------------ the items

local draw = {}

function draw.band(c, F, it)
    F:block(24, function(y)
        c:rect(0, y + 2, c.W, 22, C.PALE)
        c:text(14, y + 17, it.band, 9.5, { bold = true, color = C.GREY })
        if it.right then c:text(c.W - 14, y + 17, it.right, 9.5, { align = "end", color = C.GREY }) end
        if it.callback then c:hit(0, y, c.W, 24, it.callback) end
    end, 46)
end

function draw.row(c, F, it)
    local h = (it.sub and it.sub ~= "") and 46 or 38
    F:block(h, function(y)
        local x = 14
        if it.icon then
            c:icon(it.icon, 14, y + h / 2 - 9, 18)
            x = 42
            -- reachable (filled) or not (a ring), at the icon's corner
            if it.dot == "on" then c:circle(32, y + h / 2 + 8, 4.5, C.FILL)
            elseif it.dot == "off" then c:circle(32, y + h / 2 + 8, 4.5, C.WHITE) c:circle(32, y + h / 2 + 8, 4.5, C.BLACK, 1.2) end
        end
        local right = it.right or it.mandatory
        local rx = it.chevron and c.W - 32 or c.W - 14
        local rw = 0
        if right and right ~= "" then
            rw = c:width(right, 10.5) + 10
            c:text(rx, y + (h > 40 and 20 or 24), right, 10.5, { align = "end", color = C.GREY, maxw = 240 })
        end
        local tw = rx - x - math.min(rw, 250) - 6
        local color = it.enabled == false and C.MID or C.BLACK
        if it.sub and it.sub ~= "" then
            c:text(x, y + 20, it.text or "", 12.5, { maxw = tw, color = color, bold = it.bold })
            if it.mono then Page.mono(c, x, y + 37, it.sub, 10, { maxw = rx - x - 6, color = C.GREY })
            else c:text(x, y + 37, it.sub, 10, { maxw = rx - x - 6, color = C.GREY }) end
        elseif it.monoText then
            Page.mono(c, x, y + 24, it.text or "", 11.5, { maxw = tw, color = color })
        else
            c:text(x, y + 24, it.text or "", 12.5, { maxw = tw, color = color, bold = it.bold })
        end
        if it.chevron then chevron(c, y, h) end
        c:hline(x, y + h, c.W - x)
        if it.enabled ~= false and (it.callback or it.hold_callback) then
            c:hit(0, y, c.W, h, it.callback or it.hold_callback, it.hold_callback)
        end
    end)
end

function draw.setting(c, F, it)
    local h = it.hint and 46 or 36
    F:block(h, function(y)
        c:text(14, y + 23, it.text or "", 12, { maxw = 330, color = it.enabled == false and C.MID or C.BLACK })
        if it.hint then c:text(14, y + 39, it.hint, 9.5, { color = C.GREY, maxw = c.W - 70 }) end
        local value = it.value or it.mandatory
        if value and value ~= "" then c:text(c.W - 32, y + 23, value, 11, { align = "end", color = C.GREY, maxw = 250 }) end
        if it.callback then chevron(c, y, 36) end
        c:hline(14, y + h, c.W - 14)
        if it.callback then c:hit(0, y, c.W, h, it.callback, it.hold_callback) end
    end)
end

function draw.toggle(c, F, it)
    local h = (it.sub and it.sub ~= "") and 46 or 36
    F:block(h, function(y)
        local x = 14
        if it.icon then
            c:icon(it.icon, 14, y + h / 2 - 9, 18)
            x = 42
        end
        c:text(x, y + (h > 40 and 20 or 23), it.text or "", 12, { maxw = c.W - x - 80 })
        if it.sub and it.sub ~= "" then c:text(x, y + 37, it.sub, 10, { color = C.GREY, maxw = c.W - x - 80 }) end
        toggle(c, c.W - 54, y + h / 2 - 11, it.toggle)
        c:hline(x, y + h, c.W - x)
        if it.callback then c:hit(0, y, c.W, h, it.callback, it.hold_callback) end
    end)
end

function draw.tiles(c, F, it)
    local cols, h, gap = it.cols or 3, it.h or 58, 8
    local w = (c.W - 28 - (cols - 1) * gap) / cols
    for i = 1, #it.tiles, cols do
        F:block(h + gap, function(y)
            for k = 0, cols - 1 do
                local t = it.tiles[i + k]
                if t then
                    local x = 14 + k * (w + gap)
                    local on = t.primary
                    c:box(x, y + 4, w, h, { r = 10, fill = on and C.FILL or C.WHITE, border = C.BLACK, bw = 1.2 })
                    -- The icon beside the name, the line under it: room to breathe at the card's height
                    -- (as tall as the stats above).
                    local tx = t.icon and 34 or 10
                    if t.icon then c:icon(t.icon, x + 10, y + 15, 17, on) end
                    c:text(x + tx, y + 29, t.text or "", 11.5, { bold = true, maxw = w - tx - 8, color = on and C.ON_FILL or C.BLACK })
                    if t.sub then c:text(x + 10, y + 50, t.sub, 9.5, { maxw = w - 18, color = on and C.ON_FILL_DIM or C.GREY }) end
                    c:hit(x, y + 4, w, h, t.fn, t.hold)
                end
            end
        end)
    end
end

function draw.stats(c, F, it)
    local cols, h, gap = it.cols or 3, 58, 8
    local w = (c.W - 28 - (cols - 1) * gap) / cols
    for i = 1, #it.stats, cols do
        F:block(h + gap, function(y)
            for k = 0, cols - 1 do
                local s = it.stats[i + k]
                if s then
                    local x = 14 + k * (w + gap)
                    c:box(x, y + 4, w, h, { r = 10, border = C.BLACK, bw = 1.2 })
                    if s.icon then c:icon(s.icon, x + 9, y + 11, 13) end
                    c:text(x + (s.icon and 26 or 9), y + 22, s.label or "", 9.5, { color = C.GREY, maxw = w - 34 })
                    local vy = y + 41
                    if s.mono then Page.mono(c, x + 9, vy, s.value or "", 11.5, { maxw = w - 16 })
                    else c:text(x + 9, vy, s.value or "", 13, { bold = true, maxw = w - 16, color = s.dim and C.MID or C.BLACK }) end
                    if s.bar then
                        local bw = w - 18
                        c:box(x + 9, y + 47, bw, 6, { r = 3, border = C.BLACK, bw = 1 })
                        local fill = math.max(0, math.min(1, s.bar)) * bw
                        if fill > 1 then c:box(x + 9, y + 47, fill, 6, { r = 3, fill = C.FILL }) end
                    elseif s.sub then
                        c:text(x + 9, y + 55, s.sub, 9, { color = C.GREY, maxw = w - 16 })
                    end
                    if s.fn or s.hold then c:hit(x, y + 4, w, h, s.fn, s.hold) end
                end
            end
        end)
    end
end

function draw.quick(c, F, it)
    local cols, h, gap = it.cols or 5, 58, 8
    local w = (c.W - 28 - (cols - 1) * gap) / cols
    for i = 1, #it.quick, cols do
        F:block(h + gap, function(y)
            for k = 0, cols - 1 do
                local q = it.quick[i + k]
                if q then
                    local x = 14 + k * (w + gap)
                    c:box(x, y + 4, w, h, { r = 10, border = C.BLACK, bw = 1.2 })
                    if q.icon then c:icon(q.icon, x + w / 2 - 9, y + 11, 18) end
                    c:text(x + w / 2, y + 43, q.text or "", 10.5, { bold = true, align = "middle", maxw = w - 8 })
                    if q.sub then c:text(x + w / 2, y + 56, q.sub, 9, { align = "middle", color = C.GREY, maxw = w - 8 }) end
                    c:hit(x, y + 4, w, h, q.fn, q.hold)
                end
            end
        end)
    end
end

function draw.chips(c, F, it)
    F:block(36, function(y)
        local x = 14
        for __, ch in ipairs(it.chips) do
            local w = c:width(ch.text, 10.5, ch.on) + 24
            if x + w > c.W - 14 then break end
            c:box(x, y + 6, w, 24, { r = 12, fill = ch.on and C.FILL or C.WHITE, border = C.BLACK, bw = 1.1 })
            c:text(x + w / 2, y + 22, ch.text, 10.5, { bold = ch.on, align = "middle", color = ch.on and C.ON_FILL or C.BLACK })
            c:hit(x, y + 2, w, 32, ch.fn, ch.hold)
            x = x + w + 8
        end
    end)
end

function draw.note(c, F, it)
    local lines = c:wrap(it.note, 10, c.W - 28, 6)
    F:block(10 + 15 * #lines, function(y)
        for i, l in ipairs(lines) do c:text(14, y + 4 + 15 * i, l, 10, { color = C.GREY }) end
    end)
end

function draw.line(c, F, it)
    F:block(28, function(y)
        if it.mono then Page.mono(c, 14, y + 19, it.line, 10.5, { maxw = c.W - 28, color = C.GREY })
        else c:text(14, y + 19, it.line, 10.5, { color = C.GREY, maxw = c.W - 28 }) end
        if it.callback then c:hit(0, y, c.W, 28, it.callback) end
    end)
end

function draw.message(c, F, it)
    F:block(70, function(y)
        c:text(c.W / 2, y + 40, it.message, 12, { align = "middle", color = C.MID, maxw = c.W - 40 })
    end)
end

local function kindOf(it)
    if it.band then return "band" end
    if it.tiles then return "tiles" end
    if it.stats then return "stats" end
    if it.quick then return "quick" end
    if it.chips then return "chips" end
    if it.note then return "note" end
    if it.line then return "line" end
    if it.message then return "message" end
    if it.toggle ~= nil then return "toggle" end
    if it.setting then return "setting" end
    if it.gap then return "gap" end
    return "row"
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
    self.page = 1
    self.item_table = self.item_table or (self.items_fn and self.items_fn()) or {}
    self:render()
    table.insert(UI().pages, self)
    UI().noteScreen()
end

function Page:render()
    if self.canvas then self.canvas:release() end
    local c = Canvas.new(self.w, self.h)
    c.turn = function(d) self:turn(d) end
    self.canvas = c
    local foot = self.status and 30 or 0
    local F = c:flow(Bar.H + 4, c.H - 6 - foot, self.page)
    for __, it in ipairs(self.item_table or {}) do
        local k = kindOf(it)
        if k == "gap" then F:gap(it.gap) else draw[k](c, F, it) end
    end
    self.pages = F:pages()
    if self.page > self.pages then
        self.page = self.pages
        return self:render()
    end
    if self.status then
        local left, right, tap = self.status()
        local y = c.H - 30
        c:rect(0, y, c.W, 30, C.WHITE)
        c:hline(0, y, c.W, C.BLACK, 1)
        if left then c:text(14, y + 20, left, 10, { maxw = c.W / 2 - 20 }) end
        if right then c:text(c.W - 14, y + 20, right, 10, { align = "end", color = C.GREY, maxw = c.W / 2 - 20 }) end
        if tap then c:hit(0, y, c.W, 30, tap) end
    end
    Bar.draw(c, {
        title = self.title,
        subtitle = self.subtitle,
        back = function() self:goBack() end,
        home = require("pluginshare").appsHome and function() UI().home() end or nil,
        buttons = self.bar_buttons,
        pager = { page = self.page, pages = self.pages, turn = function(d) self:turn(d) end },
        clock = true,
        refresh = function() self:refreshPage() end,
        bell = require("pluginshare").showNotifications and function() require("pluginshare").showNotifications() end or nil,
        menu = function() UI().more() end,
    })
end

function Page:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.w, self.h, Blitbuffer.COLOR_WHITE)
    if self.canvas then self.canvas:paint(bb, x, y) end
    -- (back on top: the clock ticks again)
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
    self:render()
    UIManager:setDirty(self, mode or "ui")
end

function Page:notificationsChanged() self:redraw() end

function Page:turn(d)
    local n = math.max(1, math.min(self.pages or 1, self.page + d))
    if n == self.page then return end
    self.page = n
    self:redraw("full")
end

--- The items again; page: -1 keeps the page, a number goes to it.
function Page:switchItemTable(title, items, page)
    if title then self.title = title end
    self.item_table = items or self.item_table
    if page and page > 0 then self.page = page end
    self:redraw()
end

--- ⟳: the items made again, with a full e-ink refresh.
function Page:refreshPage()
    if self.on_refresh then self.on_refresh() end
    if self.items_fn then self.item_table = self.items_fn() end
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

--- ‹ Back (and the Back key): one page back; from the top page, the launcher.
function Page:goBack()
    self:onClose()
    if self.top then UI().launcher() end
end

function Page:onClose()
    UIManager:close(self, "full")
    return true
end
-- (Home: every SSH page closes)
Page.onCloseAllMenus = Page.onClose

function Page:onCloseWidget()
    if self.tickTask then UIManager:unschedule(self.tickTask) end
    self.ticking = true   -- (no tick once closed)
    if self.canvas then self.canvas:release() end
    local pages = UI().pages
    for i, p in ipairs(pages) do
        if p == self then
            table.remove(pages, i)
            break
        end
    end
    UI().noteScreen()
    if self.close_callback then self.close_callback() end
end

-- (the test driver's: a row tapped or held, as Menu had them)
function Page:onMenuSelect(item) if item.callback then item.callback() end return true end
function Page:onMenuHold(item) if item.hold_callback then item.hold_callback() end return true end

return Page
