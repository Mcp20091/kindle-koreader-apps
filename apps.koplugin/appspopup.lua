--[[--
The pop-ups the apps share, in the look of their title bar and settings: a
white box with a black border and rounded corners, a bold title, rows 44
tall with a line between, NotoSans.

    local Popup = require("appspopup")    -- (another plugin: pcall it; Apps may not be installed)
    Popup.menu{ title = "Kitchen", items = {
        { text = "Open", fn = function() ... end },
        { text = "Add to launcher", fn = ..., enabled = false },
        { text = "Dark", fn = ..., checked = true },      -- ✓ before it
        { text = "Delete", fn = ..., danger = true },
    } }                                    -- a tap outside or Close closes it
    Popup.confirm{ title = "Sign out", text = "Sign out of Home Assistant?",
        ok = "Sign out", cancel = "Cancel", danger = true, onOk = fn, onCancel = fn }
    Popup.message{ title = "Synced", text = "3 changes sent." }   -- to read, with OK
    Popup.toast("Saved")                   -- a moment at the bottom, then gone
    Popup.undo("Task deleted", fn)         -- with Undo, about 6 s (fn puts it back)
    local w = Popup.wait("Syncing…")       -- until w:close()
    Popup.wait("Getting puzzles…", { cancel = fn })   -- with Cancel (only it stops the wait)

Also in PluginShare (PS.popup.menu / confirm / toast / wait) for plugins that
don't want to require it. Every pop-up closes with a full refresh of where
it was (e-ink keeps a ghost of it otherwise).
]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Canvas = require("appscanvas")

local Screen = Device.screen
local C = Canvas

local Popup = {}

local ROW = 44

-- ------------------------------------------------------------------ the widget

local Box = InputContainer:extend{
    is_shared_popup = true,
    kind = "menu",        -- "menu", "confirm", "toast" or "wait"
    title = nil,
    items = nil,          -- menu: { { text, fn, enabled, checked, danger } }
    text = nil,           -- confirm, toast, wait
    ok = nil, cancel = nil, danger = false, onOk = nil, onCancel = nil,
    page = 1,
}

function Box:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    if self.kind == "toast" then self.toast = true end
    -- KOReader's keyboard is a modal window, kept above everything shown after it, and it can come
    -- back while a box is open (SSH's live session after Run command, say): a tap it doesn't take
    -- goes on to the "always active" windows, top first, so the box gets its own taps (and not the
    -- terminal under it).
    if self.kind ~= "toast" and self.kind ~= "undo" then self.is_always_active = true end
    if self.kind == "undo" then
        -- Only its Undo answers (see Box:handleEvent); any other touch goes on to the screen under it.
        self.no_uncover_flash = true
    elseif self.kind ~= "toast" and (self.kind ~= "wait" or self.onCancel) then
        local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = all } },
            Hold = { GestureRange:new{ ges = "hold", range = all } },
            Swipe = { GestureRange:new{ ges = "swipe", range = all } },
            -- (Dragging the box by its title bar: a finger's pan, or the pen held then moved.)
            Pan = { GestureRange:new{ ges = "pan", range = all } },
            PanRelease = { GestureRange:new{ ges = "pan_release", range = all } },
            HoldPan = { GestureRange:new{ ges = "hold_pan", range = all } },
            HoldRelease = { GestureRange:new{ ges = "hold_release", range = all } },
        }
    end
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    self:render()
end

--- The Undo bar: a tap on Undo is its own; every other touch (taps, holds, swipes) goes to
-- the widget under it, so the screen keeps working while the bar shows.
function Box:handleEvent(event)
    if self.kind == "undo" and event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        if ges and ges.ges == "tap" and ges.pos and self.canvas then
            local hit = self.canvas:find(ges.pos.x, ges.pos.y)
            if hit and hit.tap then hit.tap() return true end
        end
        local stack, below = UIManager._window_stack or {}, false
        for i = #stack, 1, -1 do
            local w = stack[i].widget
            if below and not w.toast then return w:handleEvent(event) end
            if w == self then below = true end
        end
        return false
    end
    return InputContainer.handleEvent(self, event)
end

function Box:render()
    if self.canvas then self.canvas:release() end
    local c = Canvas.new(self.w, self.h, false)
    self.canvas = c
    local wide = self.kind == "request" or self.kind == "read" or self.kind == "pictures"
    local bw = math.min(c.W - (wide and 40 or 60), self.kind == "toast" and 420 or (wide and 540 or 460))
    if self.kind == "undo" then
        -- A dark bar at the bottom: what was done, and Undo.
        local label = self.undo_text or _("Undo")
        local uw = c:width(label, 12, true) + 32
        local tw = math.min(bw - uw - 40, c:width(self.text or "", 12))
        local w = tw + uw + 44
        local h = 52
        local x, y = (c.W - w) / 2, c.H - h - 70
        c:box(x, y, w, h, { r = h / 2, fill = C.BLACK })
        c:text(x + 22, y + 31, self.text or "", 12, { color = C.WHITE, maxw = tw + 1 })
        local ux = x + w - uw - 10
        c:box(ux, y + 8, uw, h - 16, { r = (h - 16) / 2, fill = C.WHITE })
        c:text(ux + uw / 2, y + 31, label, 12, { bold = true, align = "middle" })
        c:hit(ux - 6, y, uw + 16, h, function() self:answer(true) end)
        self.rect = { x, y, w, h }
        return
    end
    if self.kind == "toast" then
        local lines = c:wrap(self.text or "", 12, bw - 40, 3)
        local h = 20 + 20 * #lines
        local tw = 0
        for __, l in ipairs(lines) do tw = math.max(tw, c:width(l, 12, true)) end
        local w = math.min(bw, tw + 44)
        local x, y = (c.W - w) / 2, c.H - h - 70
        c:box(x, y, w, h, { r = h < 50 and h / 2 or 14, fill = C.BLACK })
        for i, l in ipairs(lines) do c:text(c.W / 2, y + 4 + 20 * i, l, 12, { bold = true, align = "middle", color = C.WHITE }) end
        self.rect = { x, y, w, h }
        return
    end
    -- (Menus, read boxes and questions only as wide as what's in them.)
    if self.kind == "menu" or self.kind == "read" or self.kind == "confirm" or self.kind == "message" then
        bw = self:fitWidth(c, bw)
    end
    local x = (c.W - bw) / 2
    local blocks = {}   -- { h, draw(y) }
    local function add(h, draw) table.insert(blocks, { h = h, draw = draw }) end
    if self.title and self.title ~= "" then
        local lines = c:wrap(self.title, 14, bw - 36, 10)
        -- (A line under the title, smaller and grey: what it is about.)
        local sub = self.subtitle and self.subtitle ~= "" and 18 or 0
        add(18 + 22 * #lines + sub, function(y)
            -- A handle: the title bar drags the box (as the handwriting strip's band does).
            c:box(x + bw / 2 - 22, y + 9, 44, 5, { r = 2.5, fill = C.MID })
            for i, l in ipairs(lines) do c:text(x + 18, y + 6 + 22 * i, l, 14, { bold = true }) end
            if sub > 0 then c:text(x + 18, y + 8 + 22 * #lines + 12, self.subtitle, 11, { color = C.GREY, maxw = bw - 36 }) end
            c:hline(x, y + 18 + 22 * #lines + sub - 1, bw, C.BLACK, 1.5)
        end)
    end
    if self.kind == "request" then
        self:renderRequest(c, x, bw, add)
    elseif self.kind == "read" then
        self:renderRead(c, x, bw, add, blocks[1] and blocks[1].h or 0)
    elseif self.kind == "pictures" then
        -- Choices as small pictures (what each looks like), a few across, each named under it;
        -- the current one framed thick, with a tick. A tap picks.
        local opts = self.options or {}
        local cols, gap = self.cols, 12
        local tw = (bw - 36 - gap * (cols - 1)) / cols
        local th = 0
        for __, o in ipairs(opts) do if o.image then th = math.max(th, o.image:getHeight() / c.u) end end
        for r = 1, math.ceil(#opts / cols) do
            add(th + 48, function(y)
                for k = 1, cols do
                    local o = opts[(r - 1) * cols + k]
                    if o then
                        local x0 = x + 18 + (k - 1) * (tw + gap)
                        local on = o.value == self.current
                        if o.image then
                            local iw, ih = o.image:getWidth() / c.u, o.image:getHeight() / c.u
                            local ix = x0 + (tw - iw) / 2
                            c:box(ix - 2, y + 8, iw + 4, ih + 4, { border = C.BLACK, bw = on and 3 or 1 })
                            c:image(o.image, ix, y + 10)
                        end
                        local label = o.label or ""
                        if on then
                            local lw = c:width(label, 12, true)
                            c:icon("check", x0 + tw / 2 - lw / 2 - 20, y + th + 22, 16)
                        end
                        c:text(x0 + tw / 2, y + th + 36, label, 12, { bold = on, align = "middle", maxw = tw })
                        c:hit(x0, y, tw, th + 48, function() self:pick({ fn = function() if self.onPick then self.onPick(o.value) end end }) end)
                    end
                end
            end)
        end
        add(ROW, function(y)
            local label = self.back and _("Back") or _("Close")
            c:text(x + bw / 2, y + 28, label, 12.5, { bold = true, align = "middle" })
            c:hit(x, y, bw, ROW, function() self:goBack() end)
        end)
    elseif self.kind == "menu" then
        local items = self.items or {}
        -- As many rows as fit; more turn pages (‹ 1/2 › at the bottom).
        local fit = math.max(3, math.floor((c.H - 220 - (blocks[1] and blocks[1].h or 0)) / ROW))
        local pages = math.max(1, math.ceil(#items / fit))
        self.page = math.max(1, math.min(self.page, pages))
        self.pages = pages
        for i = (self.page - 1) * fit + 1, math.min(#items, self.page * fit) do
            local it = items[i]
            add(ROW, function(y)
                local off = it.enabled == false
                local tx = x + 18
                if it.checked then
                    c:icon("check", x + 16, y + 13, 18)
                    tx = x + 44
                end
                c:text(tx, y + 28, it.text or "", 12.5, { bold = it.bold, maxw = bw - (tx - x) - 18,
                    color = off and C.MID or (it.danger and C.BLACK or C.BLACK) })
                c:hline(x + 14, y + ROW - 1, bw - 28)
                if not off then c:hit(x, y, bw, ROW, function() self:pick(it) end) end
            end)
        end
        if pages > 1 then
            add(ROW, function(y)
                local label = self.page .. "/" .. pages
                c:icon("chevron-left", x + bw / 2 - 70, y + 13, 18)
                c:text(x + bw / 2, y + 28, label, 11, { align = "middle", color = C.GREY })
                c:icon("chevron-right", x + bw / 2 + 52, y + 13, 18)
                c:hit(x, y, bw / 2, ROW, function() self:turn(-1) end)
                c:hit(x + bw / 2, y, bw / 2, ROW, function() self:turn(1) end)
                c:hline(x + 14, y + ROW - 1, bw - 28)
            end)
        end
        if not self.no_close then
            add(ROW, function(y)
                local label = self.back and _("Back") or self.close_text or _("Close")
                c:text(x + bw / 2, y + 28, label, 12.5, { bold = true, align = "middle" })
                c:hit(x, y, bw, ROW, function() self:goBack() end)
            end)
        end
    else
        local lines = c:wrap(self.text or "", 12, bw - 36, self.lines or 16)
        add(16 + 20 * #lines, function(y)
            for i, l in ipairs(lines) do c:text(x + 18, y + 2 + 20 * i, l, 12) end
        end)
        if self.kind == "confirm" then
            add(64, function(y)
                local gap, bh = 10, 40
                local half = (bw - 36 - gap) / 2
                local bx = x + 18
                c:box(bx, y + 10, half, bh, { r = bh / 2, border = C.BLACK, bw = 1.2 })
                c:text(bx + half / 2, y + 35, self.cancel or _("Cancel"), 12, { bold = true, align = "middle", maxw = half - 16 })
                c:hit(bx, y, half, 60, function() self:answer(false) end)
                bx = bx + half + gap
                c:box(bx, y + 10, half, bh, { r = bh / 2, fill = C.FILL, border = C.BLACK, bw = 1.2 })
                c:text(bx + half / 2, y + 35, self.ok or _("OK"), 12, { bold = true, align = "middle", color = C.ON_FILL, maxw = half - 16 })
                c:hit(bx, y, half, 60, function() self:answer(true) end)
            end)
        elseif self.kind == "wait" and self.onCancel then
            -- A wait that can be stopped: only its Cancel does it.
            add(64, function(y)
                local bw2 = bw - 36
                c:box(x + 18, y + 10, bw2, 40, { r = 20, border = C.BLACK, bw = 1.2 })
                c:text(x + 18 + bw2 / 2, y + 35, self.cancel or _("Cancel"), 12, { bold = true, align = "middle", maxw = bw2 - 16 })
                c:hit(x + 18, y, bw2, 60, function() self:answer(false) end)
            end)
        elseif self.kind == "message" then
            -- One button: OK (a tap outside closes it too).
            add(64, function(y)
                local bw2 = bw - 36
                c:box(x + 18, y + 10, bw2, 40, { r = 20, fill = C.FILL, border = C.BLACK, bw = 1.2 })
                c:text(x + 18 + bw2 / 2, y + 35, self.ok or _("OK"), 12, { bold = true, align = "middle", color = C.ON_FILL, maxw = bw2 - 16 })
                c:hit(x + 18, y, bw2, 60, function() self:answer(true) end)
            end)
        else
            add(10, function() end)
        end
    end
    local total = 0
    for __, b in ipairs(blocks) do total = total + b.h end
    -- (While typing, at the top: the keyboard takes the bottom of the screen.)
    local y = self.typing and 24 or math.max(40, (c.H - total) / 2)
    -- Moved by dragging its title bar (as the handwriting strip is by its band); kept on the screen.
    if self.dragX or self.dragY then
        -- (Never into KOReader's keyboard: it draws only its keys, so a box under it shows through,
        -- and what the box leaves behind there isn't drawn over.)
        local bottom = c.H
        for __, e in ipairs(UIManager._window_stack or {}) do
            local w = e.widget
            if w.name == "VirtualKeyboard" and w.dimen and w.dimen.y and w.dimen.y > 0 then bottom = math.min(bottom, w.dimen.y / c.u) end
        end
        x = math.max(0, math.min(c.W - bw - 7, x + (self.dragX or 0)))
        y = math.max(0, math.min(bottom - total - 7, y + (self.dragY or 0)))
    end
    self.titleRect = { x, y, bw, (self.title and self.title ~= "") and blocks[1].h or 30 }
    self.top = y
    c:box(x + 5, y + 5, bw, total, { r = 12, fill = C.MID })
    c:box(x, y, bw, total, { r = 12, fill = C.WHITE, border = C.BLACK, bw = 2 })
    self.rect = { x - 2, y - 2, bw + 9, total + 9 }
    -- Taps inside the box but on nothing do nothing (not "outside").
    c:hit(x, y, bw, total, function() end)
    for __, b in ipairs(blocks) do
        b.draw(y)
        y = y + b.h
    end
end

--- Where the box is, in pixels (what is refreshed).
function Box:region()
    local c, r = self.canvas, self.rect
    return Geom:new{ x = c:X(r[1]), y = c:X(r[2]), w = c:X(r[3]), h = c:X(r[4]) }
end

function Box:paintTo(bb, x, y)
    if self.canvas then self.canvas:paint(bb, x, y) end
    -- A request's text field: KOReader's own, over the box where it is drawn.
    local f, r = self.field, self.fieldRect
    if f and r and self.canvas then
        local c = self.canvas
        local fh = f:getSize().h
        local top = (self.lines or 1) > 1 and c:X(4) or math.floor((c:X(r[4]) - fh) / 2)
        f:paintTo(bb, x + c:X(r[1]), y + c:X(r[2]) + top)
    end
end

-- ------------------------------------------------------------------ request and read

-- The apps whose Button labels can differ from the launcher's: { key (the tile's), plugin, name }.
Popup.LABEL_APPS = {
    { key = "apps", name = "Launcher" },
    { key = "ha", plugin = "homeassistant", name = "Home Assistant" },
    { key = "todo", plugin = "todo", name = "To Do" },
    { key = "notes", plugin = "notes", name = "Notes" },
    { key = "crosswords", plugin = "crosswords", name = "Crosswords" },
    { key = "wikipedia", plugin = "wikipedia", name = "Wikipedia" },
    { key = "syncthing", plugin = "syncthing", name = "Syncthing" },
    { key = "ssh", plugin = "sshclient", name = "SSH" },
}

--- The app whose screen is under the pop-ups now (a key of LABEL_APPS), or nil over
-- KOReader's library or a book: the top full-screen widget, matched against the
-- launcher and each app's open screen (as the switcher finds them).
function Popup.currentApp()
    local PS = require("pluginshare")
    local stack = UIManager._window_stack or {}
    local top
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w and not w.is_shared_popup and (w.covers_fullscreen or w.covers_full_screen) then top = w break end
    end
    if not top then return nil end
    if PS.appsView and PS.appsView() == top then return "apps" end
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    if not ui then return nil end
    for __, a in ipairs(Popup.LABEL_APPS) do
        local p = a.plugin and ui[a.plugin]
        if type(p) == "table" then
            for __, field in ipairs({ "screen", "page", "view", "widget" }) do
                if p[field] == top then return a.key end
            end
        end
    end
end

--- An app's own Button labels: nil (Default: as for every app), true or false.
-- From a choice's value ("on", "off", anything else: Default).
function Popup.labelsValue(v)
    if v == "on" then return true end
    if v == "off" then return false end
    return nil
end
function Popup.labelsOf(app) return (G_reader_settings:readSetting("apps_button_labels_by_app") or {})[app] end
function Popup.setLabelsOf(app, value)
    local all = G_reader_settings:readSetting("apps_button_labels_by_app") or {}
    all[app] = value
    G_reader_settings:saveSetting("apps_button_labels_by_app", next(all) and all or nil)
end

-- Whether the shared buttons show their labels: Settings > Launcher > Button labels (in
-- KOReader's settings, so every app's pop-ups follow it), unless that page sets the app
-- under the pop-up On or Off. A button with no icon keeps its label.
local function labels()
    local app = Popup.currentApp()
    local own = app and Popup.labelsOf(app)
    if own ~= nil then return own end
    return G_reader_settings:readSetting("apps_button_labels") ~= false
end
Popup.labels = labels

-- A row of buttons, each an icon over a short label, the main one black:
-- { icon, text, primary }; act(b) when tapped. 76 tall. Each is as wide as one of
-- five in a row (a row of two doesn't stretch), lined up on the right. Without
-- labels: just the icons, in squares.
local function iconButtons(c, x, y, bw, buttons, act)
    -- The colours of the canvas it's drawn on (another app's canvas has its own: Wikipedia's,
    -- Syncthing's), so any app can draw these buttons on its screen.
    local K = c.FILL and c or C
    local gap = 10
    local n = math.max(1, #buttons)
    -- (In a box narrower than a wide one, still a wide box's size.)
    local w = math.min((bw - 36 - gap * (n - 1)) / n, (math.max(bw, 540) - 36 - gap * 4) / 5)
    local withLabels = labels()
    local allIcons = true
    for __, b in ipairs(buttons) do if not b.icon then allIcons = false end end
    if not withLabels and allIcons then w = math.min(w, 56) end
    local bx = x + bw - 18 - (n * w + gap * (n - 1))
    for __, b in ipairs(buttons) do
        -- (enabled = false: greyed, no fill, not tappable, such as Save on what's saved already.)
        local off = b.enabled == false
        local primary = b.primary and not off
        c:box(bx, y + 10, w, 56, { r = 14, fill = primary and K.FILL or K.WHITE, border = off and (K.MID or K.BLACK) or K.BLACK, bw = 1.2 })
        if b.icon and not withLabels then
            c:icon(b.icon, bx + w / 2 - 12, y + 26, 24, primary)
        else
            if b.icon then c:icon(b.icon, bx + w / 2 - 11, y + 17, 22, primary) end
            c:text(bx + w / 2, b.icon and (y + 58) or (y + 44), b.text or "", 10.5, { bold = true, align = "middle", maxw = w - 8,
                color = primary and K.ON_FILL or (off and (K.MID or K.BLACK)) or K.BLACK })
        end
        if not off then
            -- A button that uses AI (aiJob: its job or feature): hold it for AI for this (service, model).
            c:hit(bx, y + 6, w, 64, function() act(b) end, b.aiJob and function()
                local ai = require("pluginshare").ai
                if ai and ai.quickPick then ai.quickPick(b.aiJob) end
            end or nil)
        end
        bx = bx + w + gap
    end
end
--- The same row for an app's own screen (SSH's output page, say): one design everywhere.
Popup.iconButtons = iconButtons

--- A request: its text field (and pen), the sections' rows, the buttons.
-- A button's width in iconButtons: one of five across a wide box.
local BUTTON_W = (540 - 36 - 10 * 4) / 5

--- The box's width for what it holds (its title, lines, rows and buttons), from
-- 300 up to `most`.
function Box:fitWidth(c, most)
    local need = 0
    local function fit(text, size, bold, pad)
        if text and text ~= "" then need = math.max(need, c:width(text, size, bold) + (pad or 36)) end
    end
    fit(self.title, 14, true)
    fit(self.subtitle, 11)
    if self.kind == "menu" then
        for __, it in ipairs(self.items or {}) do fit(it.text, 12.5, it.bold, it.checked and 62 or 36) end
        fit(self.back and _("Back") or self.close_text or _("Close"), 12.5, true)
    else
        for line in tostring(self.text or ""):gmatch("[^\n]+") do fit(line, 12) end
    end
    if self.kind == "read" then
        local n = #(self.buttons or {})
        need = math.max(need, 36 + n * BUTTON_W + 10 * math.max(0, n - 1))
    elseif self.kind == "confirm" then
        local half = math.max(110, c:width(self.cancel or _("Cancel"), 12, true) + 32, c:width(self.ok or _("OK"), 12, true) + 32)
        need = math.max(need, 36 + 10 + 2 * half)
    elseif self.kind == "message" then
        need = math.max(need, 36 + math.max(160, c:width(self.ok or _("OK"), 12, true) + 32))
    end
    return math.max(math.min(300, most), math.min(most, math.ceil(need)))
end

function Box:renderRequest(c, x, bw, add)
    -- The field: KOReader's text box over it (see paintTo), a pen at its end.
    -- (Several lines, `lines`: taller, the text from the top.)
    local fh = (self.lines or 1) > 1 and (16 + 22 * self.lines) or 40
    add(fh + 18, function(y)
        local fx, fw = x + 18, bw - 36
        c:box(fx, y + 10, fw, fh, { r = 8, border = C.BLACK, bw = 1.2 })
        local penw = self.pen and 44 or 0
        if self.pen then
            c:box(fx + fw - penw, y + 10, 1.2, fh, { fill = C.BLACK })
            c:icon("pencil", fx + fw - penw + 12, y + 10 + fh / 2 - 10, 20)
            -- (Hold the pen: AI for this, which AI reads the handwriting.)
            c:hit(fx + fw - penw, y + 6, penw, fh + 8, function() self:penTap() end, function()
                local ai = require("pluginshare").ai
                if ai and ai.quickPick then ai.quickPick("read") end
            end)
        end
        self.fieldRect = { fx + 8, y + 12, fw - penw - 16, fh - 4 }
        -- (Hold the text: Paste, Copy all, Clear.)
        c:hit(fx, y + 6, fw - penw, fh + 8, function() self:startTyping() end, function() self:textMenu() end)
    end)
    -- On/off switches under the field (a text's Bold, Italic…): { chips =
    -- { { text, on, tap(box) } } } (text and on may be functions).
    for __, s in ipairs(self.sections or {}) do
        if s.chips then self:renderChips(c, x, bw, add, s) end
    end
    -- While typing only the field and the buttons (the keyboard is below).
    if not self.typing then
        local shown, limit = 0, self.showAll and 999 or (self.rows or 6)
        local hidden = 0
        for __, s in ipairs(self.sections or {}) do
            local items = s.items or {}
            if s.chips then
                -- (Drawn under the field, above.)
            elseif s.tiles then
                self:renderTiles(c, x, bw, add, s)
            elseif #items > 0 and shown < limit then
                if s.heading then
                    add(28, function(y) c:text(x + 18, y + 22, s.heading, 9.5, { bold = true, color = C.GREY }) end)
                end
                for __, it in ipairs(items) do
                    if shown < limit then
                        shown = shown + 1
                        add(40, function(y)
                            c:text(x + 18, y + 26, it.text or "", 12, { maxw = bw - 36 })
                            c:hline(x + 14, y + 39, bw - 28)
                            c:hit(x, y, bw, 40, function() if it.fn then it.fn(self) end end)
                        end)
                    else
                        hidden = hidden + 1
                    end
                end
            else
                hidden = hidden + #items
            end
        end
        if hidden > 0 then
            add(40, function(y)
                c:text(x + 18, y + 26, self.moreText or _("More examples…"), 12, { color = C.GREY })
                c:hit(x, y, bw, 40, function()
                    self.showAll = true
                    self:redraw()
                end)
            end)
        end
    end
    add(80, function(y) iconButtons(c, x, y, bw, self.buttons or {}, function(b) self:press(b) end) end)
end

-- A tile's little picture: paper (plain, narrow, wide, grid, dots).
local function pattern(c, x, y, w, h, kind)
    if kind == "narrow" or kind == "wide" then
        local step = kind == "narrow" and 6 or 10
        for ly = y + step, y + h - 2, step do c:hline(x + 2, ly, w - 4, C.GREY) end
    elseif kind == "grid" then
        for ly = y + 6, y + h - 2, 6 do c:hline(x + 2, ly, w - 4, C.LIGHT) end
        for lx = x + 6, x + w - 2, 6 do c:box(lx, y + 2, 0.6, h - 4, { fill = C.LIGHT }) end
    elseif kind == "dots" then
        for ly = y + 6, y + h - 2, 6 do
            for lx = x + 6, x + w - 2, 6 do c:box(lx - 0.6, ly - 0.6, 1.2, 1.2, { fill = C.GREY }) end
        end
    end
end

--- A row of on/off switches, drawn as rounded labels (black when on).
function Box:renderChips(c, x, bw, add, s)
    local function val(v) if type(v) == "function" then return v() end return v end
    add(46, function(y)
        local cx = x + 18
        for __, ch in ipairs(s.chips) do
            local label = tostring(val(ch.text) or "")
            local on = val(ch.on) == true
            -- (font = { bold, italic, serif }: the label in the style it stands for.)
            local f = val(ch.font) or { bold = true }
            local w = c:width(label, 11, f.bold, f.italic, f.serif) + 28
            c:box(cx, y + 8, w, 32, { r = 16, fill = on and C.FILL or C.WHITE, border = C.BLACK, bw = 1.2 })
            c:text(cx + w / 2, y + 29, label, 11, { bold = f.bold, italic = f.italic, serif = f.serif, align = "middle",
                color = on and C.ON_FILL or C.BLACK })
            c:hit(cx, y + 4, w, 40, function()
                if ch.tap then ch.tap(self) end
                self:redraw()
            end)
            cx = cx + w + 8
        end
    end)
end

--- A row of tiles to choose one of: { heading, tiles = { { text, value,
-- pattern } }, value (the chosen one), pick(value, box) }.
function Box:renderTiles(c, x, bw, add, s)
    if s.heading then
        add(28, function(y) c:text(x + 18, y + 22, s.heading, 9.5, { bold = true, color = C.GREY }) end)
    end
    local n = math.max(1, #s.tiles)
    local gap = 8
    local tw = (bw - 36 - gap * (n - 1)) / n
    add(84, function(y)
        local tx = x + 18
        for __, t in ipairs(s.tiles) do
            local on = t.value == s.value
            c:box(tx, y + 4, tw, 74, { r = 8, fill = C.WHITE, border = C.BLACK, bw = on and 3 or 1.2 })
            pattern(c, tx + 8, y + 10, tw - 16, 40, t.pattern)
            c:text(tx + tw / 2, y + 70, t.text or "", 10.5, { bold = on, align = "middle", maxw = tw - 6 })
            c:hit(tx, y, tw, 82, function()
                s.value = t.value
                if s.pick then s.pick(t.value, self) end
                self:redraw()
            end)
            tx = tx + tw + gap
        end
    end)
end

--- Text to read: as many lines as fit, ‹ n/m › for the rest, the buttons.
function Box:renderRead(c, x, bw, add, titleH)
    local all = self.allLines or c:wrap(self.text or "", 12, bw - 36, 100000)
    self.allLines = all
    local fit = math.max(4, math.floor((c.H - 80 - titleH - 80 - 44 - 24) / 20))
    local pages = math.max(1, math.ceil(#all / fit))
    self.page = math.max(1, math.min(self.page, pages))
    self.pages = pages
    -- Every page as tall as the first, so the box stays put while turning.
    local rows = math.min(fit, #all)
    add(16 + 20 * rows, function(y)
        local first = (self.page - 1) * fit
        for i = 1, rows do
            local l = all[first + i]
            if l then c:text(x + 18, y + 4 + 20 * i, l, 12) end
        end
    end)
    if pages > 1 then
        add(44, function(y)
            c:icon("chevron-left", x + bw / 2 - 70, y + 13, 18)
            c:text(x + bw / 2, y + 28, self.page .. "/" .. pages, 11, { align = "middle", color = C.GREY })
            c:icon("chevron-right", x + bw / 2 + 52, y + 13, 18)
            c:hit(x, y, bw / 2, 44, function() self:turn(-1) end)
            c:hit(x + bw / 2, y, bw / 2, 44, function() self:turn(1) end)
        end)
    end
    add(80, function(y) iconButtons(c, x, y, bw, self.buttons or {}, function(b) self:press(b) end) end)
end

--- Drawn again (its size may change), with the place it was refreshed too.
function Box:redraw()
    local before = self:region()
    self:render()
    -- (What was under a bigger box drawn again too.)
    UIManager:setDirty("all", "ui", before:combine(self:region()))
end

--- The request's text, as typed.
function Box:getText()
    return self.field and self.field:getText() or ""
end

function Box:setText(text)
    if self.field then self.field:setText(text or "") end
    self:redraw()
end

--- Hold on the text: Paste what was copied (from a book, the SSH terminal, another box), Copy
-- all of it, or Clear it. KOReader's clipboard, so it goes between apps.
function Box:textMenu()
    local input = Device.input
    local clip = input and input.getClipboardText and input.getClipboardText() or ""
    local text = self:getText()
    local items = {}
    if clip ~= "" then
        local short = clip:gsub("%s+", " ")
        -- (Cut at 40 bytes, then back to a whole character: no half of a UTF-8 one.)
        if #short > 40 then
            short = short:sub(1, 40)
            while #short > 0 and short:byte(#short) >= 0x80 and short:byte(#short) < 0xC0 do short = short:sub(1, -2) end
            if #short > 0 and short:byte(#short) >= 0xC0 then short = short:sub(1, -2) end
            short = short .. "…"
        end
        table.insert(items, { text = require("ffi/util").template(_("Paste: %1"), short), fn = function()
            -- (At the cursor, as typing would.)
            if self.field.addChars then self.field:addChars(clip) else self.field:setText(text .. clip) end
            self:redraw()
        end })
    end
    if text ~= "" then
        table.insert(items, { text = _("Copy all"), fn = function()
            if input and input.setClipboardText then input.setClipboardText(text) end
        end })
        table.insert(items, { text = _("Clear"), fn = function() self:setText("") end })
    end
    if #items == 0 then return self:startTyping() end
    Popup.menu{ title = _("Text"), items = items }
end

-- The keyboard: up while typing, the box at the top above it.
function Box:startTyping()
    if not self.field or self.typing then return end
    self.typing = true
    self:redraw()
    self.field:onShowKeyboard()
end

function Box:stopTyping()
    if not self.typing then return end
    self.typing = false
    if self.field then self.field:onCloseKeyboard() end
end

function Box:penTap()
    self:stopTyping()
    -- The launcher's handwriting input (pen = true): the box stays (at the
    -- top, above the strip) and what was written goes into its text.
    if self.pen == true then
        self.typing = true
        self:redraw()
        require("appshandwrite").write({ title = self.penTitle, kind = self.penKind }, function(text)
            if self.closed then return end
            self.typing = false
            if text and self.field then
                local now = self.field:getText() or ""
                self.field:setText(now:match("%S") and (now:gsub("%s+$", "") .. " " .. text) or text)
            end
            self:redraw()
        end)
        return
    end
    self:close()
    if self.pen then self.pen() end
end

--- A button: Cancel (`cancel`) closes it; one that needs text (`needsText`)
-- starts typing when there is none; `keep` leaves the box open. fn(text, box).
function Box:press(b)
    local text = self.kind == "read" and (self.text or "") or self:getText():match("^%s*(.-)%s*$")
    if b.needsText and text == "" then return self:startTyping() end
    if not b.keep then
        self:stopTyping()
        self:close()
    end
    if b.cancel then
        if self.onCancel then self.onCancel() end
        return
    end
    if b.fn then b.fn(text, self) end
end

function Box:turn(d)
    self.page = self.page + d
    local before = self:region()
    self:render()
    local after = self:region()
    UIManager:setDirty(self, "ui", before:combine(after))
end

function Box:pick(it)
    -- (A menu that stays open: its buttons close it themselves.)
    if not self.keep_open then self:close() end
    if it.fn then it.fn() end
end

function Box:answer(yes)
    self:close()
    if yes then
        if self.onOk then self.onOk() end
    elseif self.onCancel then
        self.onCancel()
    end
end

function Box:onTap(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if self.kind == "undo" then
        if hit and hit.tap then hit.tap() return true end
        return false
    end
    if hit and hit.tap then hit.tap()
    elseif self.dismissable == false or self.kind == "wait" then return true
    -- (A request or text closed by a tap outside: as its Cancel.)
    elseif self.kind == "request" or self.kind == "read" then
        self:stopTyping()
        self:close()
        if self.onCancel then self.onCancel() end
    -- (A message closed any way runs its onOk, as OK does: its onCancel is onOk.)
    elseif self.kind == "confirm" or self.kind == "message" then self:answer(false)
    else self:close() end
    return true
end

function Box:onHold(_, ges)
    -- (Held on the title bar: the start of a drag with the pen, if it moves.)
    if ges and ges.pos and self:inTitle(ges.pos) then
        self.holdStart = ges.pos
        return true
    end
    -- (A hold of its own, such as AI for this on an AI button; else as a tap.)
    local hit = self.canvas and ges and ges.pos and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and hit.hold then hit.hold() return true end
    return self:onTap(_, ges)
end

-- ------------------------------------------------------------------ dragging

function Box:inTitle(pos)
    local c, r = self.canvas, self.titleRect
    if not (c and r and pos) then return false end
    local x, y = pos.x / c.u, pos.y / c.u
    return x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4]
end

function Box:startDrag(pos)
    self.drag = { px = pos.x, py = pos.y, x0 = self.dragX or 0, y0 = self.dragY or 0, dx = 0, dy = 0 }
    -- KOReader's keyboard steps aside while dragging: it's above the box, so it would take the
    -- touch where the finger lets go (a key typed), and the box mustn't go under it.
    for __, e in ipairs(UIManager._window_stack or {}) do
        local w = e.widget
        if w.name == "VirtualKeyboard" and w.inputbox and w.inputbox.onCloseKeyboard then
            self.drag.keyboard = w.inputbox
            pcall(w.inputbox.onCloseKeyboard, w.inputbox)
        end
    end
end

-- The box where the finger is now: drawn again now and then (every 12 pixels and 0.15 s at
-- most, as e-ink can), and where it ends.
function Box:dragTo(pos, final)
    local d, c = self.drag, self.canvas
    if not (d and c and pos) then return end
    local dx, dy = (pos.x - d.px) / c.u, (pos.y - d.py) / c.u
    local now = require("socket").gettime()
    if not final and ((math.abs(dx - d.dx) + math.abs(dy - d.dy)) * c.u < 12 or (d.at and now - d.at < 0.15)) then return end
    d.at, d.dx, d.dy = now, dx, dy
    self.dragX, self.dragY = d.x0 + dx, d.y0 + dy
    self:redraw()
end

function Box:endDrag(pos)
    if not self.drag then return false end
    self:dragTo(pos, true)
    local input = self.drag.keyboard
    self.drag = nil
    if input then
        -- Back, and the box drawn again above it if it's where the keyboard goes.
        pcall(input.onShowKeyboard, input)
        self:redraw()
    end
    -- (A clean picture where it ends: e-ink leaves ghosts of the steps on the way.)
    UIManager:setDirty("all", "full")
    return true
end

function Box:onPan(_, ges)
    if not self.drag then
        local start = ges.start_pos or ges.pos
        if not self:inTitle(start) then return true end
        self:startDrag(start)
    end
    self:dragTo(ges.pos)
    return true
end

function Box:onPanRelease(_, ges)
    self:endDrag(ges and ges.pos)
    return true
end

function Box:onHoldPan(_, ges)
    if not self.drag then
        if not (self.holdStart and self:inTitle(self.holdStart)) then return true end
        self:startDrag(self.holdStart)
    end
    self:dragTo(ges.pos)
    return true
end

function Box:onHoldRelease(_, ges)
    self.holdStart = nil
    self:endDrag(ges and ges.pos)
    return true
end

function Box:onSwipe(_, ges)
    -- A quick flick on the title bar: the box moves by as much.
    if ges.end_pos and self:inTitle(ges.pos) then
        self:startDrag(ges.pos)
        self:endDrag(ges.end_pos)
        return true
    end
    if (self.kind == "menu" or self.kind == "read") and (self.pages or 1) > 1 then
        if ges.direction == "west" or ges.direction == "north" then self:turn(1) return true end
        if ges.direction == "east" or ges.direction == "south" then self:turn(-1) return true end
    end
    return true
end

function Box:onClose()
    if self.dismissable == false then return true end
    -- (Back on a wait with Cancel is its Cancel; on a plain wait, nothing.)
    if self.kind == "wait" then
        if self.onCancel then self:answer(false) end
        return true
    end
    if self.kind == "confirm" or self.kind == "message" then self:answer(false)
    elseif self.kind == "request" or self.kind == "read" then
        -- (Back while typing: the keyboard goes; then the box, as Cancel.)
        if self.typing then
            self:stopTyping()
            self:redraw()
            return true
        end
        self:close()
        if self.onCancel then self.onCancel() end
    else self:goBack() end
    return true
end

--- Close, or (a menu one level down) back to the menu it came from.
function Box:goBack()
    self:close()
    if self.back then self.back() end
end

function Box:close()
    if self.closed then return end
    self.closed = true
    if self.timer then UIManager:unschedule(self.timer) end
    UIManager:close(self, "full", self:region())
end

function Box:onCloseWidget()
    if self.canvas then self.canvas:release() end
    -- (A pictures box's pictures are its own.)
    for __, o in ipairs(self.kind == "pictures" and self.options or {}) do
        if o.image then o.image:free() o.image = nil end
    end
    -- The keyboard that stepped aside for this box: back once whatever the box led to is shown.
    if self.keyboardBack then
        local back = self.keyboardBack
        self.keyboardBack = nil
        UIManager:nextTick(function()
            -- (Not while another box from it is up, such as the model list after Model: that one
            -- takes it over when it closes.)
            for __, e in ipairs(UIManager._window_stack or {}) do
                if e.widget.is_shared_popup and e.widget ~= self and not e.widget.closed and e.widget.kind ~= "toast" then
                    e.widget.keyboardBack = e.widget.keyboardBack or back
                    return
                end
            end
            back()
        end)
    end
    if self.field then
        self.typing = false
        pcall(self.field.onCloseKeyboard, self.field)
        pcall(self.field.onCloseWidget, self.field)
    end
end

-- KOReader keeps its keyboard above every other window, so a box opened while it's up (a hold on
-- an AI button in SSH's live session, say) would be under it: it steps aside while the box is
-- open and comes back after, if its text box is still there. (A request box has its own.)
--- Puts KOReader's keyboard aside (for a window shown over it); returns a function that brings
-- it back if the window its text box is in is still open, or nil when there was none.
function Popup.keyboardAside()
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w.name == "VirtualKeyboard" and w.inputbox and w.inputbox.onCloseKeyboard then
            local input = w.inputbox
            -- (The window the text box is in: the keyboard comes back only while that's open.)
            local owner = i > 1 and stack[i - 1].widget or nil
            pcall(input.onCloseKeyboard, input)
            return function()
                local open = false
                for __, e in ipairs(UIManager._window_stack or {}) do if e.widget == owner then open = true end end
                if open then pcall(input.onShowKeyboard, input) end
            end
        end
    end
end

local function keyboardAside(box)
    if box.kind == "request" or box.kind == "toast" or box.kind == "undo" or box.kind == "wait" then return end
    box.keyboardBack = Popup.keyboardAside()
end

local function show(box)
    keyboardAside(box)
    UIManager:show(box, box.kind == "toast" and "fast" or "ui", box:region())
    return box
end

-- ------------------------------------------------------------------ the calls

--- o: { title, items, close = "Close" (its own text), no_close (no Close
-- row), keep_open (a pick doesn't close it), dismissable = false (only its
-- buttons close it), back = fn (one level down: Back instead of Close,
-- and it and the Back key call fn, which shows the menu before) }.
function Popup.menu(o)
    return show(Box:new{ kind = "menu", title = o.title, items = o.items or {}, close_text = o.close,
        no_close = o.no_close, keep_open = o.keep_open, dismissable = o.dismissable, back = o.back })
end

--- A choice shown as pictures of each option: { title, options = { { label, value,
-- picture = fn(width in pixels) -> a blitbuffer (it's the box's to free) } }, current,
-- onPick = fn(value), back = fn (Back instead of Close), cols (2 or 3; by how many) }.
function Popup.pictures(o)
    local opts = o.options or {}
    local cols = o.cols or (#opts <= 2 and 2 or 3)
    -- (The box's width as Box:render works it out, so each picture is made the right size.)
    local u = math.min(Screen:getWidth(), Screen:getHeight()) / 620
    local bw = math.min(Screen:getWidth() / u - 40, 540)
    local px = math.floor((bw - 36 - 12 * (cols - 1)) / cols * u) - 4 * math.ceil(u)
    for __, opt in ipairs(opts) do
        if opt.picture and not opt.image then
            local ok, img = pcall(opt.picture, px)
            if ok then opt.image = img end
        end
    end
    return show(Box:new{ kind = "pictures", title = o.title, options = opts, current = o.current,
        onPick = o.onPick, back = o.back, cols = cols })
end

--- Something to read (a result, a problem): { title, text, ok, onOk }, with OK.
function Popup.message(o)
    if type(o) == "string" then o = { text = o } end
    return show(Box:new{ kind = "message", title = o.title, text = o.text, ok = o.ok, onOk = o.onOk, onCancel = o.onOk, lines = o.lines })
end

function Popup.confirm(o)
    return show(Box:new{ kind = "confirm", title = o.title, text = o.text, ok = o.ok, cancel = o.cancel,
        danger = o.danger, onOk = o.onOk, onCancel = o.onCancel })
end

function Popup.toast(text, seconds)
    local box = Box:new{ kind = "toast", text = text }
    show(box)
    box.timer = function() box:close() end
    UIManager:scheduleIn(seconds or 2, box.timer)
    return box
end

--- A box while something runs; :close() it when done. With a cancel
-- (Popup.wait(text, { cancel = fn }) or Popup.wait{ text = …, onCancel = fn }),
-- a Cancel button under the text stops it: the box closes and fn runs. Taps
-- elsewhere do nothing.
--- After something was removed: a bar at the bottom with what happened and
-- Undo, for about 6 seconds; Undo calls onUndo. Taps elsewhere go on as usual.
--   Popup.undo("Task deleted", function() ... put it back ... end)
function Popup.undo(text, onUndo, seconds)
    local box = Box:new{ kind = "undo", text = text, onOk = onUndo }
    show(box)
    box.timer = function() box:close() end
    UIManager:scheduleIn(seconds or 6, box.timer)
    return box
end

function Popup.wait(text, opts)
    local o = type(text) == "table" and text or { text = text }
    opts = opts or {}
    local onCancel = o.onCancel or o.cancel_fn or opts.cancel or opts.onCancel
    return show(Box:new{ kind = "wait", text = o.text, onCancel = onCancel, cancel = o.cancelText or opts.cancelText })
end

--- A request to type (or, with `pen`, to write by hand): { title, subtitle,
-- hint, text, sections = { { heading, items = { { text, fn(box) } } } },
-- rows (how many rows show before More examples…), pen = true (a pen at the
-- field's end: the launcher's handwriting input, read into the field;
-- penTitle, penKind) or fn (the box closes and fn runs), buttons = { { icon, text,
-- primary, needsText, keep, cancel, aiJob (hold: AI for this), enabled = false (greyed), fn(text, box) } }, onCancel, number,
-- password, typing (the keyboard up at once), lines (a text of several
-- lines: the field that tall) }. The keyboard's Enter is the primary button
-- (a new line with `lines`). sections may hold { chips = { { text, on,
-- tap(box), font = { bold, italic, serif } } } }: on/off switches under the
-- field, each label in its font when given. box:getText(), box:setText(t).
function Popup.request(o)
    -- is_always_active: its keyboard is the top widget, and a tap the keyboard doesn't take only
    -- goes on to such widgets (as KOReader's InputDialog has it); without it the buttons don't answer.
    local box = Box:new{ kind = "request", is_always_active = true, title = o.title, subtitle = o.subtitle, sections = o.sections,
        rows = o.rows, pen = o.pen, penTitle = o.penTitle, penKind = o.penKind, buttons = o.buttons, lines = o.lines,
        onCancel = o.onCancel, moreText = o.more }
    local Font = require("ui/font")
    local c = box.canvas
    box.field = require("ui/widget/inputtext"):new{
        text = o.text or "",
        hint = o.hint or "",
        -- (A number: the keyboard's numbers; a password: dots.)
        input_type = o.number and "number" or nil,
        text_type = o.password and "password" or nil,
        width = c:X(box.fieldRect and box.fieldRect[3] or 400),
        -- (The size of the rows' text, 12 units, as the canvas draws it.)
        face = Font:getFace("NotoSans-Regular.ttf", c:X(12) / (Screen:scaleBySize(1000) / 1000)),
        parent = box,
        -- (Several lines: it scrolls, and Enter is a new line.)
        scroll = (o.lines or 1) > 1,
        height = (o.lines or 1) > 1 and c:X(22 * o.lines) or nil,
        allow_newline = (o.lines or 1) > 1 or nil,
        focused = true,
        bordersize = 0,
        padding = 0,
        margin = 0,
        enter_callback = (o.lines or 1) <= 1 and function()
            for __, b in ipairs(box.buttons or {}) do
                if b.primary then return box:press(b) end
            end
        end or nil,
    }
    -- The keyboard's own hide key: the whole box back under it.
    local kb = box.field.keyboard
    if kb and kb.hideKeyboard then
        local hide = kb.hideKeyboard
        kb.hideKeyboard = function(k, ...)
            local r = hide(k, ...)
            if box.typing and not box.closed then
                box.typing = false
                box:redraw()
            end
            return r
        end
    end
    show(box)
    if o.typing then box:startTyping() end
    return box
end

--- Text to read, in pages: { title, subtitle, text, buttons = { { icon,
-- text, primary, keep, fn(text, box) } }, onCancel }.
function Popup.read(o)
    return show(Box:new{ kind = "read", title = o.title, subtitle = o.subtitle, text = o.text,
        buttons = o.buttons, onCancel = o.onCancel })
end

--- A choice from options ({ label, value } or { text, value }), the current one ticked.
function Popup.choose(title, options, current, done)
    local items = {}
    for __, o in ipairs(options) do
        local v = o.value
        if v == nil then v = o[2] end
        table.insert(items, { text = o.label or o.text or o[1], checked = v == current, fn = function() done(v) end })
    end
    return Popup.menu{ title = title, items = items }
end

return Popup
