--[[--
Notes' settings as full pages (as Home Assistant's): the shared title bar,
then the settings in sections, each with its value at the right (a switch for
the ones that are on or off, ›  for the ones that open a list or another
screen), as many pages as they need (the arrows at the bottom, or a swipe).

`build()` gives the rows: { heading = "…" } or { text = "Label: value",
fn = function, kind = "row" | "pick" | "open" }; a row's value is what
follows its last ": ".

@module koplugin.notes.settingspage
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Title = require("notestitle")
local UI = require("notesui")

local Screen = Device.screen

local Page = InputContainer:extend{
    title = "",
    build = nil,      -- build() -> rows
    items = nil,      -- or a plain list, as a Menu's: { text, mandatory, bold, dim, callback, hold_callback }
    titleOpts = nil,  -- home(), bell(), menu(), back() (else it closes) for the title bar
    jump = nil,       -- a row's name: opened at the page with it
    close_callback = nil,
    covers_fullscreen = true,
    flash_on_uncover = true,  -- (a full refresh when a dialog over it closes)
}

local ON, OFF = _("On"), _("Off")

function Page:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ui = UI.new()
    self.page = 1
    self.hits = {}
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        PageTap = { GestureRange:new{ ges = "tap", range = all } },
        PageSwipe = { GestureRange:new{ ges = "swipe", range = all } },
        PageHold = { GestureRange:new{ ges = "hold", range = all } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    -- The time on the title bar, once a minute.
    self.stopTick = UI.everyMinute(function() if self.shown then UIManager:setDirty(self, "ui") end end)
end

--- The rows again (after a change), the screen drawn again.
function Page:refresh()
    self.rows = nil
    UIManager:setDirty(self, "ui")
end

function Page:onShow()
    self.shown = true
    UIManager:setDirty(self, "full")
end

function Page:onPageTap(_arg, ges)
    if not (ges and ges.pos) then return true end
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if ges.pos.x >= h[1] and ges.pos.x < h[1] + h[3] and ges.pos.y >= h[2] and ges.pos.y < h[2] + h[4] then
            h[5]()
            return true
        end
    end
    return true
end

-- A held row: its hold (a list's row options); anything else held (a firm
-- pen press counts as a hold): its tap.
function Page:onPageHold(_arg, ges)
    if not (ges and ges.pos) then return true end
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if ges.pos.x >= h[1] and ges.pos.x < h[1] + h[3] and ges.pos.y >= h[2] and ges.pos.y < h[2] + h[4] then
            local fn = h[6] or h[5]
            fn()
            return true
        end
    end
    return true
end

--- ‹ Back: titleOpts.back, else the page closes.
function Page:goBack()
    local o = self.titleOpts or {}
    if o.back then o.back(self) else UIManager:close(self) end
end

--- As Menu's: a new title (nil keeps it) and list; `at` 1 goes to the first page.
function Page:switchItemTable(title, items, at)
    if title then self.title = title end
    self.items = items
    if at == 1 then self.page = 1 end
    UIManager:setDirty(self, "ui")
end

function Page:onPageSwipe(_arg, ges)
    local d = ges and ges.direction
    -- (Right from the left edge: back, as in the other apps; other swipes turn.)
    if require("notesko").fromLeftEdge(ges) then self:goBack() return true end
    if d == "west" or d == "north" then self:turn(1) elseif d == "east" or d == "south" then self:turn(-1) end
    return true
end

--- The shared notifications changed (the bell's badge).
function Page:notificationsChanged()
    UIManager:setDirty(self, function() return "ui", Geom:new{ x = 0, y = 0, w = self.w, h = self.ui:u(Title.HEIGHT) } end)
end

function Page:turn(dir)
    local to = self.page + dir
    if to < 1 or to > (self.pages or 1) then return end
    self.page = to
    UIManager:setDirty(self, "ui")
end

function Page:onClose()
    UIManager:close(self)
    return true
end

function Page:onCloseWidget()
    self.shown = false
    if self.stopTick then self.stopTick() end
    if self.close_callback then self.close_callback() end
    self.ui:free()
    UIManager:setDirty(nil, "full")
end

-- A row's label and value ("Side: Left" -> "Side", "Left").
local function split(text)
    local at
    local i = 1
    while true do
        local j = text:find(": ", i, true)
        if not j then break end
        at, i = j, j + 1
    end
    if not at then return text, nil end
    return text:sub(1, at - 1), text:sub(at + 2)
end

-- The rows in pages: { { row, y, h }, … } per page.
function Page:layout(top, bottom)
    local u = function(n) return self.ui:u(n) end
    local pages, page, y = {}, {}, top
    local rows = self.rows
    for i, r in ipairs(rows) do
        local h = r.heading and u(34) or u(36)
        -- A heading never ends a page.
        local need = h + ((r.heading and rows[i + 1] and not rows[i + 1].heading) and u(36) or 0)
        if y + need > bottom and #page > 0 then
            table.insert(pages, page)
            page, y = {}, top
        end
        table.insert(page, { r, y, h })
        y = y + h
    end
    if #page > 0 then table.insert(pages, page) end
    return pages
end

function Page:paintTo(bb, x, y)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    -- (Made each time: a list or screen opened from here may have changed them.)
    if self.build then
        -- (A row left out is false: taken out here.)
        self.rows = {}
        local built = self.build()
        for i = 1, table.maxn(built) do
            if built[i] then table.insert(self.rows, built[i]) end
        end
    else
        -- A plain list: each row its text, and its note in grey at the right.
        self.rows = {}
        for __, it in ipairs(self.items or {}) do
            table.insert(self.rows, { label = it.text or "", value = it.mandatory, bold = it.bold, dim = it.dim,
                fn = it.callback, hold = it.hold_callback, kind = "open" })
        end
    end
    self.hits = {}
    bb:paintRect(x, y, self.w, self.h, Blitbuffer.COLOR_WHITE)
    local o = self.titleOpts or {}
    local pages = self:layout(u(56), self.h - u(8))
    self.pages = #pages
    -- Opened at a row (the launcher's search found it): the page it's on.
    if self.jump then
        local Settings = require("notessettings")
        for i, p in ipairs(pages) do
            for __, item in ipairs(p) do
                local r = item[1]
                if not r.heading and Settings.rowName(r.text or r.label) == self.jump then self.page = i end
            end
        end
        self.jump = nil
    end
    if self.page > #pages then self.page = math.max(1, #pages) end
    local hits = Title.draw(ui, bb, self.w, {
        title = self.title,
        back = function() self:goBack() end,
        home = o.home and function() o.home(self) end or nil,
        status = o.status ~= false,
        refresh = function() require("notesko").refresh(self) end,
        bell = o.bell, bellCount = o.bell and require("notesko").bellCount() or nil,
        menu = o.menu and function() o.menu(self) end or nil,
        page = self.page, pages = #pages, turn = function(dir) self:turn(dir) end,
    })
    for __, h in ipairs(hits) do table.insert(self.hits, h) end
    for __, item in ipairs(pages[self.page] or {}) do
        local r, ry, rh = item[1], item[2], item[3]
        if r.heading then
            ui:drawText(bb, r.heading:upper(), u(14), ry + u(10) + u(12), 9.5, { bold = true, color = UI.GREY_TEXT })
        else
            local label, value
            if r.label then label, value = r.label, r.value else label, value = split(r.text) end
            local right
            if r.label and not r.fn then
                -- A list's row that does nothing ("Nothing found."): no ›.
                right = self.w - u(14)
                if value then
                    right = right - ui:drawText(bb, value, right, ry + math.floor(rh / 2), 11, { align = "right", color = UI.GREY_TEXT }) - u(12)
                end
            elseif r.kind ~= "pick" and not r.label and (value == ON or value == OFF) then
                -- A switch (40 by 22, as Home Assistant's).
                local sx, sy = self.w - u(54), ry + u(7)
                local on = value == ON
                ui:box(bb, sx, sy, u(40), u(22), { fill = on and UI.BLACK or UI.WHITE, border = UI.BLACK, r = u(11) })
                bb:paintCircle(sx + u(on and 29 or 11), sy + u(11), u(7), on and UI.WHITE or UI.BLACK)
                right = sx - u(10)
            else
                ui:drawIcon(bb, "chevron-right", self.w - u(26), ry + u(12), u(12))
                right = self.w - u(32)
                if value then
                    right = right - ui:drawText(bb, value, right, ry + math.floor(rh / 2), 11, { align = "right", color = UI.GREY_TEXT }) - u(12)
                end
            end
            local text = label
            local room = right - u(14) - u(8)
            if ui:textWidth(text, 12, r.bold) > room then
                while #text > 1 and ui:textWidth(text .. "…", 12, r.bold) > room do
                    text = text:sub(1, -2):gsub("[\128-\191]+$", ""):gsub("[\192-\255]$", "")
                end
                text = text .. "…"
            end
            ui:drawText(bb, text, u(14), ry + math.floor(rh / 2), 12, { bold = r.bold, color = r.dim and UI.GREY_TEXT or nil })
            bb:paintRect(u(14), ry + rh - u(1), self.w - u(28), 1, UI.MID)
            local fn = r.fn
            table.insert(self.hits, { 0, ry, self.w, rh, function() if fn then fn() end end, r.hold })
        end
    end
end

return Page
