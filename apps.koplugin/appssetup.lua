--[[--
Set up your Kindle: a walkthrough on first start (only while nothing is set
up yet), one page per step: Wi-Fi, Home Assistant, To Do, Notes' AI,
Syncthing, the web server's password. Every step has Skip; the first page
has Don't show again. Settings > Set up your Kindle runs it again.

Apps add their step through PluginShare:

    local PS = require("pluginshare")
    if PS.registerSetup then
        PS.registerSetup{ key = "todo", order = 30, icon = "list-checks",
            title = "To Do", text = "Your Microsoft To Do lists on the Kindle…",
            done = function() return signedIn end,     -- shows "Done" and Next
            action = "Sign in", run = function() ... end,
            -- Optional: what happens without it ("If you skip it: …"), on the step and the summary.
            skipped = "To Do keeps lists on this Kindle only.",
            -- Optional: a list under the text, items() -> { { icon, title, text } }; info = true for
            -- a page to read only (no Done line, not in the summary).
            -- Optional: a picture under the text (a PNG's path), as large as the page leaves room for.
            image = "/path/to/picture.png",
            -- Optional: a "How to get one" page, the short steps and a QR code of
            -- the guide's page (a path in the public repo's guide/ folder).
            help = { button = "How to get an App ID", title = "Getting an App ID",
                steps = { "Sign in at portal.azure.com…", ... }, guide = "setup.md#microsoft-to-do-and-onenote" } }
    end
]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Bar = require("appsbar")
local Canvas = require("appscanvas")
local KO = require("appsko")

local Screen = Device.screen
local C = Canvas

local Setup = {}

-- Where the guide lives (the public repo): QR codes on help pages point here.
Setup.GUIDE_URL = "https://github.com/Mcp20091/kindle-koreader-apps/blob/main/guide/"

-- (Kept in PluginShare: apps register at start, before this module is loaded.)
local PS0 = require("pluginshare")
PS0.setupSteps = PS0.setupSteps or {}
local registry = PS0.setupSteps

function Setup.register(e)
    if type(e) == "table" and e.key and e.title then registry[e.key] = e end
end

function Setup.steps()
    local list = {}
    for __, e in pairs(registry) do table.insert(list, e) end
    table.sort(list, function(a, b) return (a.order or 50) < (b.order or 50) end)
    return list
end

local function done(e)
    local ok, v = pcall(function() return e.done and e.done() end)
    return ok and v == true
end

--- Nothing set up yet (Wi-Fi aside): the walkthrough may show at start.
function Setup.nothingSetUp()
    local any = false
    for __, e in ipairs(Setup.steps()) do
        if e.key ~= "wifi" then
            any = true
            if done(e) then return false end
        end
    end
    return any
end

-- ------------------------------------------------------------------ the screen

local Screen_ = InputContainer:extend{
    covers_fullscreen = true,
    flash_on_uncover = true,
    step = 0,     -- 0: welcome; 1..n: a step; n + 1: all set
}

local shown

function Screen_:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = all } },
        -- (A hold as a tap: a firm press of the pen lasts long enough to be a hold.)
        Hold = { GestureRange:new{ ges = "hold", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    self.steps = Setup.steps()
    -- Run again after it was finished or turned off: the summary, each step a tap away.
    if self.step == 0 and G_reader_settings:isTrue("apps_setup_done") then
        self.step, self.again = #self.steps + 1, true
    end
    self:render()
end

-- A step's picture (`image`: a PNG's path), read once at a given size: { bb, w, h } in pixels.
local pictures = {}
local function picture(path, maxW, maxH)
    local key = path .. ":" .. maxW .. "x" .. maxH
    if pictures[key] == nil then
        local RenderImage = require("ui/renderimage")
        local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false)
        pictures[key] = false
        if ok and bb then
            local k = math.min(maxW / bb:getWidth(), maxH / bb:getHeight(), 1)
            local w, h = math.floor(bb:getWidth() * k), math.floor(bb:getHeight() * k)
            local scaled = RenderImage:scaleBlitBuffer(bb, w, h, true)
            if scaled then pictures[key] = { bb = scaled, w = w, h = h } end
        end
    end
    return pictures[key] or nil
end

local function button(c, x, y, w, label, filled, fn)
    c:box(x, y, w, 46, { r = 23, fill = filled and C.FILL or nil, border = C.BLACK, bw = 1.4 })
    c:text(x + w / 2, y + 29, label, 13, { bold = true, align = "middle", color = filled and C.ON_FILL or C.BLACK, maxw = w - 20 })
    c:hit(x, y, w, 46, fn)
end

function Screen_:render()
    if self.canvas then self.canvas:release() end
    local c = Canvas.new(self.w, self.h, false)
    self.canvas = c
    local n = #self.steps
    local cx = c.W / 2
    local y = Bar.H + 70
    local bottom = c.H - 90
    local function paragraph(text)
        for __, l in ipairs(c:wrap(text, 13, c.W - 120, 12)) do
            c:text(60, y, l, 13)
            y = y + 22
        end
    end
    if self.helpFor then
        return self:renderHelp(c)
    end
    if self.step == 0 then
        c:icon("sparkles", cx - 24, y, 48)
        y = y + 100
        c:text(cx, y, _("Set up your Kindle"), 22, { bold = true, align = "middle" })
        y = y + 44
        paragraph(T(_("A few steps connect the apps: Wi-Fi, then %1. Skip any of them; you can do each later in its app's settings, or run this again from Settings > Set up your Kindle."),
            (function()
                local names = {}
                for __, e in ipairs(self.steps) do if e.key ~= "wifi" then table.insert(names, e.title) end end
                return table.concat(names, ", ")
            end)()))
        button(c, 60, bottom - 60, c.W - 120, _("Start"), true, function() self:go(1) end)
        button(c, 60, bottom, (c.W - 132) / 2, _("Skip"), false, function() self:finish(false) end)
        button(c, 72 + (c.W - 132) / 2, bottom, (c.W - 132) / 2, _("Don't show again"), false, function() self:finish(true) end)
    elseif self.step > n then
        c:icon("check", cx - 24, y, 48)
        y = y + 100
        c:text(cx, y, self.again and _("Set up your Kindle") or _("All set"), 22, { bold = true, align = "middle" })
        y = y + 30
        c:text(cx, y, _("Tap one to set it up or change it."), 11.5, { align = "middle", color = C.GREY })
        y = y + 40
        -- What a skipped one means, under it, only while everything fits above the buttons
        -- (each step's own page says it too).
        local need = 0
        for __, e in ipairs(self.steps) do if e.info then need = need - 34 end end
        for __, e in ipairs(self.steps) do
            need = need + 34
            if not done(e) and e.skipped then need = need + 6 + 18 * #c:wrap(e.skipped, 10.5, c.W - 152, 2) end
        end
        local explain = y + need < bottom - 80
        for i, e in ipairs(self.steps) do
          if not e.info then
            local ok = done(e)
            local top = y - 26
            c:icon(ok and "check" or "minus", 60, y - 16, 20)
            c:text(92, y, e.title, 13, { bold = ok })
            c:text(c.W - 82, y, ok and _("Done") or _("Not set up"), 12, { align = "end", color = C.GREY })
            c:icon("chevron-right", c.W - 76, y - 14, 16)
            y = y + 34
            -- What a skipped one means.
            if explain and not ok and e.skipped then
                for __, l in ipairs(c:wrap(e.skipped, 10.5, c.W - 152, 2)) do
                    c:text(92, y - 10, l, 10.5, { color = C.GREY })
                    y = y + 18
                end
                y = y + 6
            end
            -- (Its step, then back here.)
            c:hit(50, top, c.W - 100, y - top - 4, function() self.fromSummary = true self:go(i) end)
          end
        end
        button(c, 60, bottom - 60, c.W - 120, _("Go through every step"), false, function() self.fromSummary = false self:go(1) end)
        button(c, 60, bottom, c.W - 120, _("Done"), true, function() self:finish(true) end)
    else
        local e = self.steps[self.step]
        local ok = done(e)
        c:icon(e.icon or "settings", cx - 24, y, 48)
        y = y + 100
        c:text(cx, y, e.title, 22, { bold = true, align = "middle" })
        y = y + 44
        paragraph(e.text or "")
        -- A list (items(): { { icon, title, text } }): what's there without setting up, say.
        if e.items then
            local ok, list = pcall(e.items)
            y = y + 6
            for __, it in ipairs(ok and list or {}) do
                c:icon(it.icon or "check", 60, y - 4, 26)
                c:text(102, y + 12, it.title or "", 13, { bold = true })
                c:text(102, y + 34, it.text or "", 11, { color = C.GREY, maxw = c.W - 162 })
                y = y + 56
            end
        end
        -- A picture of it (the web page, say), framed, as wide as the text.
        if e.image then
            local p = picture(e.image, c:X(c.W - 120), c:X(math.max(120, bottom - y - 230)))
            if p then
                local w, h = p.w / c.u, p.h / c.u
                local x = (c.W - w) / 2
                y = y + 8
                c:image(p.bb, x, y)
                c:box(x - 1, y - 1, w + 2, h + 2, { border = C.MID, bw = 1 })
                y = y + h + 8
            end
        end
        y = y + 10
        -- (A page to read, info = true: no Done or Not set up.)
        if not e.info then
            c:text(60, y, ok and (e.doneText or _("Done")) or (e.notDoneText or _("Not set up yet")), 12, { bold = true, color = ok and C.BLACK or C.GREY })
            y = y + 32
        end
        if not ok and e.skipped then
            for __, l in ipairs(c:wrap(T(_("If you skip it: %1"), e.skipped), 11.5, c.W - 120, 4)) do
                c:text(60, y, l, 11.5, { color = C.GREY })
                y = y + 20
            end
            y = y + 8
        end
        y = y + 8
        if e.run then
            button(c, 60, y, c.W - 120, e.action or _("Set up"), not ok, function()
                local okR, err = pcall(e.run)
                if not okR then require("logger").warn("Setup:", e.key, err) end
            end)
            y = y + 62
        end
        if type(e.help) == "table" then
            button(c, 60, y, c.W - 120, e.help.button or _("How to set it up"), false, function()
                self.helpFor = e
                self:render()
                UIManager:setDirty(self, "full")
            end)
        end
        button(c, 60, bottom, (c.W - 132) / 2, _("Back"), false, function() self:go(self.fromSummary and #self.steps + 1 or self.step - 1) end)
        -- (Opened from the summary: back to it.)
        local nextStep = self.fromSummary and #self.steps + 1 or self.step + 1
        button(c, 72 + (c.W - 132) / 2, bottom, (c.W - 132) / 2, self.fromSummary and _("Done") or (ok and _("Next") or _("Skip")), ok,
            function() self:go(nextStep) end)
    end
    -- Page dots.
    if self.step >= 1 and self.step <= n then
        local dx = cx - (n - 1) * 9
        for i = 1, n do c:circle(dx + (i - 1) * 18, c.H - 30, 4, i == self.step and C.BLACK or C.LIGHT) end
    end
    Bar.draw(c, {
        title = _("Set up your Kindle"),
        subtitle = (self.step >= 1 and self.step <= n) and T(_("Step %1 of %2"), self.step, n) or nil,
        back = function() if self.step > 0 then self:go(self.step - 1) else self:finish(false) end end,
        clock = true,
        menu = function()
            KO.list(nil, { { text = _("Skip setup"), fn = function() self:finish(false) end },
                { text = _("Don't show again"), fn = function() self:finish(true) end } })
        end,
    })
end

--- A step's "How to get one": its short steps, numbered, then a QR code of the guide's page.
function Screen_:renderHelp(c)
    local e = self.helpFor
    local h = e.help
    local y = Bar.H + 50
    c:text(60, y, h.title or e.title, 20, { bold = true, maxw = c.W - 120 })
    y = y + 40
    for i, step in ipairs(h.steps or {}) do
        c:text(60, y, i .. ".", 12.5, { bold = true })
        for __, l in ipairs(c:wrap(step, 12.5, c.W - 150, 6)) do
            c:text(90, y, l, 12.5)
            y = y + 21
        end
        y = y + 8
    end
    if h.after then
        for __, l in ipairs(c:wrap(h.after, 11.5, c.W - 120, 6)) do
            c:text(60, y, l, 11.5, { color = C.GREY })
            y = y + 20
        end
    end
    local bottom = c.H - 90
    if h.guide then
        -- The QR code, as big as fits above Back (at most 200 units).
        local size = math.min(200, bottom - y - 70)
        if size >= 90 then
            local okQ, qr = pcall(function()
                return require("ui/widget/qrwidget"):new{ text = Setup.GUIDE_URL .. h.guide, width = c:X(size), height = c:X(size) }
            end)
            if okQ and qr and qr.image then
                local px = qr.image:getWidth() / c.u
                c:text(c.W / 2, y + 22, _("The full steps in the guide, on your phone:"), 11.5, { align = "middle", color = C.GREY })
                c:image(qr.image, c.W / 2 - px / 2, y + 36)
            end
        end
    end
    button(c, 60, bottom, c.W - 120, _("Back"), true, function()
        self.helpFor = nil
        self:render()
        UIManager:setDirty(self, "full")
    end)
    Bar.draw(c, {
        title = _("Set up your Kindle"),
        subtitle = e.title,
        back = function()
            self.helpFor = nil
            self:render()
            UIManager:setDirty(self, "full")
        end,
        clock = true,
    })
end

function Screen_:go(step)
    self.helpFor = nil
    self.step = math.max(0, math.min(#self.steps + 1, step))
    self:render()
    UIManager:setDirty(self, "full")
end

function Screen_:finish(never)
    if never then G_reader_settings:makeTrue("apps_setup_done") end
    UIManager:close(self)
end

-- Drawn again each time it shows (after a sign-in over it, the step says Done): no timer.
function Screen_:paintTo(bb, x, y)
    self:render()
    bb:paintRect(x, y, self.w, self.h, C.WHITE)
    if self.canvas then self.canvas:paint(bb, x, y) end
end

function Screen_:onTap(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and hit.tap then hit.tap() end
    return true
end

function Screen_:onHold(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and (hit.hold or hit.tap) then (hit.hold or hit.tap)() end
    return true
end

-- Left: the next step; right (or in from the left edge, Back): the one before.
function Screen_:onSwipe(_, ges)
    if ges.direction == "west" then self:go(self.step + 1)
    elseif ges.direction == "east" and self.step > 0 then self:go(self.step - 1) end
    return true
end

function Screen_:onClose()
    if self.helpFor then
        self.helpFor = nil
        self:render()
        UIManager:setDirty(self, "full")
        return true
    end
    self:finish(false)
    return true
end

function Screen_:onCloseWidget()
    self.closed = true
    if self.canvas then self.canvas:release() end
    if shown == self then shown = nil end
    UIManager:setDirty(nil, "full")
end

function Setup.show()
    if shown then return end
    KO.flashOnUncover()
    shown = Screen_:new{}
    KO.showFull(shown)
end


return Setup
