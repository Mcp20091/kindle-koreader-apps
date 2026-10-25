--[[--
The notebook list as covers: each notebook's first page small, folders and
the trash as tiles, the list's other rows (new notebook, new folder,
search, what to do with a selection) as buttons along the top. Takes the
same items as the plain list (Menu) and answers to switchItemTable, so the
Notes plugin drives either one the same way.

A cover is drawn once and kept in notes/covers/ until the notebook changes.

@module koplugin.notes.grid
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local KO = require("notesko")
local Settings = require("notessettings")
local UI = require("notesui")

local Screen = Device.screen

local Grid = InputContainer:extend{
    title = "",
    items = nil,
    notes = nil,          -- the Notes plugin (its store, for covers)
    onSettings = nil,     -- the cog
    close_callback = nil,
    covers_fullscreen = true,
    flash_on_uncover = true,  -- (a full refresh when a dialog over it closes)
}

function Grid:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ui = UI.new()
    self.first = 1
    self.hits = {}
    self.covers = {}      -- id → { key, bb }
    self.failed = {}      -- ids whose cover could not be drawn
    -- The time and battery in the title, once a minute (while on top).
    self.stopStatus = UI.everyMinute(function()
        if UIManager:getTopmostVisibleWidget() ~= self then return end
        UIManager:setDirty(self, function() return "ui", Geom:new{ x = 0, y = 0, w = self.w, h = self.ui:u(44) } end)
    end)
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        GridTap = { GestureRange:new{ ges = "tap", range = all } },
        GridHold = { GestureRange:new{ ges = "hold", range = all } },
        GridSwipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
end

--- As Menu's: new title (nil keeps it) and rows; `at` 1 goes to the first
-- screen of them, anything else keeps the one shown.
function Grid:switchItemTable(title, items, at)
    if title then self.title = title end
    self.items = items
    if at == 1 then self.first = 1 end
    self:redraw()
end

function Grid:redraw()
    UIManager:setDirty(self, "ui")
end

-- ------------------------------------------------------------------ input

function Grid:hit(x, y, w, h, tap, hold)
    table.insert(self.hits, { x, y, w, h, tap, hold })
end

function Grid:find(ges)
    if not ges or not ges.pos then return nil end
    local x, y = ges.pos.x, ges.pos.y
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if x >= h[1] and x < h[1] + h[3] and y >= h[2] and y < h[2] + h[4] then return h end
    end
end

function Grid:onGridTap(_arg, ges)
    local h = self:find(ges)
    if h and h[5] then h[5]() end
    return true
end

function Grid:onGridHold(_arg, ges)
    local h = self:find(ges)
    -- (A button with no hold of its own: its tap. A firm pen press lasts long
    -- enough to count as a hold.)
    local fn = h and (h[6] or h[5])
    if fn then fn() end
    return true
end

function Grid:onGridSwipe(_arg, ges)
    -- (Right from the left edge: back, as in the other apps; other swipes turn.)
    if KO.fromLeftEdge(ges) then
        if self.notes then self.notes:listBack() else UIManager:close(self) end
        return true
    end
    if ges.direction == "west" or ges.direction == "north" then self:turn(1)
    elseif ges.direction == "east" or ges.direction == "south" then self:turn(-1) end
    return true
end

-- Your KOReader gestures work here too (see notesko.lua).
function Grid:onGesture(ev)
    if Settings.get("ko_gestures") ~= false and self.notes and KO.passGesture(self.notes.ui, ev, KO.notesSafe) then return true end
    return InputContainer.onGesture(self, ev)
end

function Grid:handleEvent(event)
    if InputContainer.handleEvent(self, event) then return true end
    return KO.passEvent(self.notes and self.notes.ui, event)
end

function Grid:onClose()
    UIManager:close(self)
    return true
end

function Grid:onCloseWidget()
    if self.stopStatus then self.stopStatus() self.stopStatus = nil end
    for __, c in pairs(self.covers) do if c.bb then c.bb:free() end end
    self.covers = {}
    for __, m in pairs(self.minis or {}) do if m.bb then m.bb:free() end end
    self.minis = {}
    if self.coverTask then UIManager:unschedule(self.coverTask) end
    self.ui:free()
    if self.close_callback then self.close_callback() end
    UIManager:setDirty(nil, "full")
end

-- ------------------------------------------------------------------ layout

-- The tiles (folders, notebooks, trash) and the buttons (every other row).
-- The buttons that didn't fit along the top, as a list.
function Grid:moreButtons(rest)
    local items = {}
    local notes = self.notes
    for __, it in ipairs(rest) do
        table.insert(items, { text = it.text, fn = function()
            -- (A menu it opens, as Sort's, has Back to this list.)
            if notes then notes.menuBack = function() self:moreButtons(rest) end end
            if it.callback then it.callback() end
            if notes then notes.menuBack = nil end
        end })
    end
    KO.list(_("More"), items)
end

function Grid:split()
    local tiles, buttons = {}, {}
    for __, it in ipairs(self.items or {}) do
        if it.nb or it.folder or it.peek or it.trash or it.trashed then table.insert(tiles, it) else table.insert(buttons, it) end
    end
    return tiles, buttons
end

function Grid:geometry()
    local u = function(n) return self.ui:u(n) end
    local cols = self.w > self.h and 6 or 4
    local top = u(44) + u(44)
    local foot = u(8)
    local pad = u(12)
    local cellW = math.floor((self.w - pad) / cols)
    local tw = cellW - pad
    local th = math.floor(tw * 4 / 3)
    local cellH = th + u(40)
    local rows = math.max(1, math.floor((self.h - top - foot) / cellH))
    return { cols = cols, rows = rows, top = top, foot = foot, pad = pad, cellW = cellW, cellH = cellH, tw = tw, th = th }
end

--- The shared notifications changed (the bell's badge).
function Grid:notificationsChanged()
    UIManager:setDirty(self, function() return "ui", Geom:new{ x = 0, y = 0, w = self.w, h = self.ui:u(44) } end)
end

function Grid:turn(dir)
    local g = self:geometry()
    local per = g.cols * g.rows
    local tiles = self:split()
    local first = self.first + dir * per
    if first < 1 or first > #tiles then return end
    self.first = first
    self:redraw()
end

-- A name cut to fit `maxw` pixels.
local function fit(ui, s, size, bold, maxw)
    if ui:textWidth(s, size, bold) <= maxw then return s end
    local cut = s
    while #cut > 1 and ui:textWidth(cut .. "…", size, bold) > maxw do
        cut = cut:sub(1, -2)
        while #cut > 0 and cut:byte(#cut) >= 0x80 and cut:byte(#cut) < 0xC0 do cut = cut:sub(1, -2) end
    end
    return cut .. "…"
end

-- The crossword folders (Get a crossword makes Crosswords/<source>; puzzle
-- books go in Crosswords) have a cover of their own: a crossword grid, a
-- folder's tab, and the name under it (the source's name in plain type).
local CROSSWORD_PATTERN = { "0001000", "0101010", "0000100", "1101011", "0010000", "0101010", "0001000" }
local SOURCE_CAPTIONS = { Guardian = _("The Guardian"), ["USA Today"] = _("USA Today"), Universal = _("Universal"),
    ["Washington Post"] = _("The Washington Post"), ["New Yorker"] = _("The New Yorker") }

-- What a crossword folder's cover says, or nil for any other folder.
local function crosswordCaption(path)
    local top = _("Crosswords")
    if path == top then return top:upper() end
    local name = path:match("^" .. top:gsub("%p", "%%%0") .. "/([^/]+)$")
    return name and SOURCE_CAPTIONS[name] or nil
end

local function drawCrosswordCover(bb, ui, tx, ty, tw, th, caption)
    bb:paintRect(tx, ty, tw, th, UI.WHITE)
    bb:paintBorder(tx, ty, tw, th, math.max(1, ui:u(0.8)), UI.BLACK)
    bb:paintRect(tx, ty, math.floor(tw * 0.32), math.max(3, ui:u(4)), UI.BLACK)   -- a folder's tab
    local n = #CROSSWORD_PATTERN
    local margin = math.floor(tw * 0.08)
    local cell = math.floor((tw - 2 * margin) / n)
    local size = cell * n
    local gx, gy = tx + math.floor((tw - size) / 2), ty + math.floor(tw * 0.15)
    local line = math.max(1, ui:u(0.4))
    for r, row in ipairs(CROSSWORD_PATTERN) do
        for k = 1, n do
            if row:sub(k, k) == "1" then bb:paintRect(gx + (k - 1) * cell, gy + (r - 1) * cell, cell, cell, UI.BLACK) end
        end
    end
    for i = 0, n do
        bb:paintRect(gx + i * cell, gy, line, size + line, UI.BLACK)
        bb:paintRect(gx, gy + i * cell, size + line, line, UI.BLACK)
    end
    local below = gy + size
    ui:drawText(bb, fit(ui, caption, 10, true, tw - 2 * margin), tx + math.floor(tw / 2),
        below + math.floor((ty + th - below) / 2), 10, { align = "center", bold = true })
end

-- A folder's cover (Hold a folder > Cover…): "peek" (the notebooks changed
-- last in it, small), "plain", "icon:<name>", "nb:<id>"; by default the
-- crossword one for the crossword folders, else peek.
function Grid:folderCover(path)
    local f = self.notes and self.notes.folders
    local c = f and f.cover and f:cover(path)
    if c then return c end
    if crosswordCaption(path) then return "crossword" end
    return "peek"
end

-- The notebooks a folder's cover shows ({ nb, modified } each).
function Grid:coverNotebooks(path, kind)
    local notes = self.notes
    if not (notes and notes.folders and notes.store) then return {} end
    self.listed = self.listed or notes.store:list()   -- newest first; once per paint
    local byId, ids = {}, {}
    for __, e in ipairs(self.listed) do
        byId[e.id] = e
        table.insert(ids, e.id)
    end
    if kind:match("^nb:") then
        local e = byId[kind:sub(4)]
        if e and notes.isLocked and notes:isLocked(e.id) then return {} end
        return e and { { nb = e.id, modified = e.modified } } or {}
    end
    if kind ~= "peek" then return {} end
    local out = {}
    for __, id in ipairs(notes.folders:inside(path, ids)) do
        if not (notes.isLocked and notes:isLocked(id)) then
            table.insert(out, { nb = id, modified = byId[id].modified })
            if #out == 4 then break end
        end
    end
    return out
end

-- A notebook's cover made small (w x h at most), kept while shown.
function Grid:miniCover(e, w, h)
    local key = (e.modified or 0) .. ":" .. w .. "x" .. h
    self.minis = self.minis or {}
    local m = self.minis[e.nb]
    if m and m.key == key then return m.bb end
    local c = self:cover(e)
    if not c then return nil end
    local f = math.min(w / c:getWidth(), h / c:getHeight())
    local bb = UI.scale(c, math.max(1, math.floor(c:getWidth() * f)), math.max(1, math.floor(c:getHeight() * f)))
    if m and m.bb then m.bb:free() end
    self.minis[e.nb] = { key = key, bb = bb }
    return bb
end

-- A folder's tile: its cover as chosen. True when a notebook's cover it
-- shows isn't drawn yet.
function Grid:drawFolder(bb, it, tx, ty, tw, th)
    local ui = self.ui
    -- (The Recent folder: the notebooks it shows come with it.)
    local kind = it.peek and "peek" or self:folderCover(it.folder)
    if kind == "crossword" then
        drawCrosswordCover(bb, ui, tx, ty, tw, th, crosswordCaption(it.folder))
        return false
    end
    local list = it.peek or self:coverNotebooks(it.folder, kind)
    local function frame()
        bb:paintRect(tx, ty, tw, th, Blitbuffer.Color8(0xEE))
        bb:paintBorder(tx, ty, tw, th, 1, UI.MID)
        bb:paintRect(tx, ty, math.floor(tw * 0.32), math.max(3, ui:u(4)), UI.BLACK)   -- a folder's tab
    end
    if kind:match("^icon:") then
        frame()
        local is = math.floor(tw / 2.2)
        ui:drawIcon(bb, kind:sub(6), tx + math.floor((tw - is) / 2), ty + math.floor((th - is) / 2), is)
        return false
    end
    if #list == 0 then
        bb:paintRect(tx, ty, tw, th, Blitbuffer.Color8(0xEE))
        bb:paintBorder(tx, ty, tw, th, 1, UI.MID)
        local is = math.floor(tw / 3)
        ui:drawIcon(bb, "folder", tx + math.floor((tw - is) / 2), ty + math.floor((th - is) / 2), is)
        return false
    end
    local missing = false
    if kind:match("^nb:") then
        local c = self:cover(list[1])
        if c then
            bb:paintRect(tx, ty, tw, th, UI.WHITE)
            bb:blitFrom(c, tx + math.floor((tw - c:getWidth()) / 2), ty + math.floor((th - c:getHeight()) / 2), 0, 0,
                c:getWidth(), c:getHeight())
        else
            bb:paintRect(tx, ty, tw, th, Blitbuffer.Color8(0xF2))
            missing = not self.failed[list[1].nb]
        end
        bb:paintBorder(tx, ty, tw, th, 1, UI.MID)
        bb:paintRect(tx, ty, math.floor(tw * 0.32), math.max(3, ui:u(4)), UI.BLACK)
        return missing
    end
    -- Peek inside: up to four of its notebooks, two by two.
    frame()
    local gap = ui:u(5)
    local top = math.max(3, ui:u(4)) + gap
    local qw, qh = math.floor((tw - 3 * gap) / 2), math.floor((th - top - 2 * gap) / 2)
    for i, e in ipairs(list) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local qx, qy = tx + gap + col * (qw + gap), ty + top + row * (qh + gap)
        local c = self:miniCover(e, qw, qh)
        if c then
            local cx, cy = qx + math.floor((qw - c:getWidth()) / 2), qy + math.floor((qh - c:getHeight()) / 2)
            bb:blitFrom(c, cx, cy, 0, 0, c:getWidth(), c:getHeight())
            bb:paintBorder(cx, cy, c:getWidth(), c:getHeight(), 1, UI.MID)
        else
            bb:paintRect(qx, qy, qw, qh, UI.WHITE)
            if not self.failed[e.nb] then missing = true end
        end
    end
    return missing
end

function Grid:paintTo(bb, x, y)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    self.hits = {}
    self.listed = nil
    bb:paintRect(x, y, self.w, self.h, Blitbuffer.COLOR_WHITE)
    local g = self:geometry()
    -- The shared title bar: ‹ Back, ⌂ Home, the folder, ‹ n/m ›, the clock
    -- and battery, ⟳, the bell, ⋮ (Open on the web page, Settings).
    local notes = self.notes
    local per = g.cols * g.rows
    local count = #(self:split())
    if self.first > math.max(1, count) then self.first = 1 end
    local hits, bar = require("notestitle").draw(ui, bb, self.w, {
        title = self.title,
        back = function() if notes then notes:listBack() else UIManager:close(self) end end,
        home = notes and require("pluginshare").appsHome and function() notes:goHome() end or nil,
        status = true,
        refresh = function() KO.refresh(self) end,
        bell = KO.bell(), bellCount = KO.bellCount(),
        page = math.floor((self.first - 1) / per) + 1, pages = math.max(1, math.ceil(count / per)),
        turn = function(dir) self:turn(dir) end,
        menu = function()
            if notes then notes:titleMenu({}) elseif self.onSettings then self.onSettings() end
        end,
    })
    for __, h in ipairs(hits) do self:hit(h[1], h[2], h[3], h[4], h[5]) end
    -- The list's other rows as buttons.
    local tiles, buttons = self:split()
    local bx = u(12)
    -- A button: its label, or (`icon`: Search, New folder, Sort) just an icon.
    local function width(label, bold, icon)
        return icon and u(40) or ui:textWidth(label, 10, bold) + u(20)
    end
    local function chip(label, bold, callback, hold, icon)
        local w = width(label, bold, icon)
        ui:box(bb, bx, bar + u(9), w, u(26), { fill = bold and UI.BLACK or UI.WHITE, border = UI.BLACK, r = u(13) })
        if icon then
            ui:drawIcon(bb, icon, bx + math.floor((w - u(16)) / 2), bar + u(14), u(16), bold)
        else
            ui:drawText(bb, label, bx + math.floor(w / 2), bar + u(22), 10,
                { align = "center", bold = bold, color = bold and UI.WHITE or UI.BLACK })
        end
        self:hit(bx, bar, w, u(44), callback, hold)
        bx = bx + w + u(8)
    end
    -- Those that don't fit go behind More… at the end.
    local moreW = width(_("More…"))
    local widths, total = {}, u(12)
    for i, it in ipairs(buttons) do
        widths[i] = width(it.text, it.bold, it.icon)
        total = total + widths[i] + u(8)
    end
    local room = self.w - u(12)
    if total - u(8) > room then room = room - moreW - u(8) end
    for i, it in ipairs(buttons) do
        if bx + widths[i] > room then
            local rest = {}
            for k = i, #buttons do table.insert(rest, buttons[k]) end
            chip(_("More…"), false, function() self:moreButtons(rest) end)
            break
        end
        chip(it.text, it.bold, it.callback, it.hold_callback, it.icon)
    end
    bb:paintRect(0, g.top, self.w, 2, UI.BLACK)
    -- The tiles.
    local missing = false
    for k = 0, per - 1 do
        local it = tiles[self.first + k]
        if not it then break end
        local col, row = k % g.cols, math.floor(k / g.cols)
        local tx = g.pad + col * g.cellW
        local ty = g.top + g.pad + row * g.cellH
        if it.nb and it.locked then
            -- Locked: a lock, not its first page.
            bb:paintRect(tx, ty, g.tw, g.th, Blitbuffer.Color8(0xEE))
            bb:paintBorder(tx, ty, g.tw, g.th, 1, UI.MID)
            local is = math.floor(g.tw / 3)
            ui:drawIcon(bb, "lock", tx + math.floor((g.tw - is) / 2), ty + math.floor((g.th - is) / 2), is)
        elseif it.nb then
            local c = self:cover(it)
            if c then
                bb:blitFrom(c, tx + math.floor((g.tw - c:getWidth()) / 2), ty + math.floor((g.th - c:getHeight()) / 2), 0, 0,
                    c:getWidth(), c:getHeight())
            else
                bb:paintRect(tx, ty, g.tw, g.th, Blitbuffer.Color8(0xF2))
                if not self.failed[it.nb] then missing = true end
            end
            bb:paintBorder(tx, ty, g.tw, g.th, 1, UI.MID)
        elseif it.folder or it.peek then
            if self:drawFolder(bb, it, tx, ty, g.tw, g.th) then missing = true end
        else
            bb:paintRect(tx, ty, g.tw, g.th, Blitbuffer.Color8(0xEE))
            bb:paintBorder(tx, ty, g.tw, g.th, 1, UI.MID)
            local is = math.floor(g.tw / 3)
            ui:drawIcon(bb, (it.trash or it.trashed) and "trash-2" or "folder", tx + math.floor((g.tw - is) / 2), ty + math.floor((g.th - is) / 2), is)
        end
        -- Pinned, recent: a small mark at the corner.
        if it.pinned or it.recent then
            local ms = u(16)
            local mx, my = tx + g.tw - ms - u(4), ty + u(4)
            bb:paintCircle(mx + math.floor(ms / 2), my + math.floor(ms / 2), math.floor(ms / 2) + u(3), UI.WHITE)
            ui:drawIcon(bb, it.pinned and "pin" or "clock", mx, my, ms)
        end
        local name = it.text:gsub("▸ ", "", 1)
        ui:drawText(bb, fit(ui, name, 10.5, true, g.tw), tx, ty + g.th + u(12), 10.5, { bold = true })
        if it.mandatory then
            ui:drawText(bb, fit(ui, it.mandatory, 8.5, false, g.tw), tx, ty + g.th + u(27), 8.5, { color = UI.GREY_TEXT })
        end
        self:hit(tx, ty, g.tw, g.cellH - u(4), it.callback, it.hold_callback)
    end
    if #tiles == 0 then
        ui:drawText(bb, self.notes and self.notes.inTrash and _("The trash is empty.")
            or self.notes and self.notes.crosswordsApp and _("No crosswords yet. Tap + Get a crossword.") or _("No notebooks here yet."),
            math.floor(self.w / 2), math.floor(self.h / 2), 11, { align = "center" })
    end
    -- Covers not drawn yet: one at a time after this.
    if missing and not self.coverTask then
        self.coverTask = function()
            self.coverTask = nil
            if self:makeNextCover() then self:redraw() end
        end
        UIManager:scheduleIn(0.05, self.coverTask)
    end
end

-- ------------------------------------------------------------------ covers

function Grid:coverDir()
    return self.notes.store.dir .. "/covers"
end

local function coverPath(dir, it)
    -- (_s: drawn with smooth scaling; older covers are drawn again.)
    return string.format("%s/%s_%d_s.png", dir, it.nb, it.modified or 0)
end

-- A notebook's cover, if drawn already (from its file, kept while shown).
function Grid:cover(it)
    local g = self:geometry()
    local key = (it.modified or 0) .. ":" .. g.tw
    local c = self.covers[it.nb]
    if c and c.key == key then return c.bb end
    local path = coverPath(self:coverDir(), it)
    local f = io.open(path, "rb")
    if not f then return nil end
    f:close()
    local ok, bb = pcall(require("ui/renderimage").renderImageFile, require("ui/renderimage"), path, false)
    if not ok or not bb then return nil end
    -- Fitted inside the tile, keeping the page's shape.
    local w, h = bb:getWidth(), bb:getHeight()
    local f2 = math.min(g.tw / w, g.th / h)
    if f2 < 1 then
        local s = UI.scale(bb, math.floor(w * f2), math.floor(h * f2))
        bb:free()
        bb = s
    end
    if c and c.bb then c.bb:free() end
    self.covers[it.nb] = { key = key, bb = bb }
    return bb
end

-- The first missing cover on screen drawn into its file. True when one was.
function Grid:makeNextCover()
    self.listed = nil
    local g = self:geometry()
    local tiles = self:split()
    local dir = self:coverDir()
    require("util").makePath(dir)
    for k = 0, g.cols * g.rows - 1 do
        local it = tiles[self.first + k]
        if not it then break end
        -- The notebook's own cover, or those its folder's cover shows.
        local want = (it.nb and not it.locked) and { it } or {}
        if it.folder then
            local kind = self:folderCover(it.folder)
            if kind == "peek" or kind:match("^nb:") then want = self:coverNotebooks(it.folder, kind) end
        elseif it.peek then
            want = it.peek
        end
        local todo
        for __, e in ipairs(want) do
            if not self.failed[e.nb] and not self:cover(e) then
                todo = e
                break
            end
        end
        if todo then
            it = todo
            local store = self.notes.store
            local nb = store:read(it.nb)
            if not nb then
                self.failed[it.nb] = true
                return true
            end
            -- Old covers of this notebook go.
            local lfs = require("libs/libkoreader-lfs")
            for name in lfs.dir(dir) do
                if name:find("^" .. it.nb .. "_%d+[_%a]*%.png$") then os.remove(dir .. "/" .. name) end
            end
            local Editor = require("noteseditor")
            local ok, done = pcall(Editor.pagePNG, nb, 1, coverPath(dir, it), { long = math.max(g.tw, g.th) * 2 })
            if not (ok and done) or not self:cover(it) then self.failed[it.nb] = true end
            return true
        end
    end
    return false
end

return Grid
