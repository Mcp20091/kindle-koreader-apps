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
            -- Optional: settings to change on the step itself, rows() -> { { title, sub, value,
            -- fn(refresh) } } (the name, its value at the right; call refresh() after a change).
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

-- The guide as a PDF, the latest release's (GitHub sends it on from there).
Setup.GUIDE_PDF_URL = "https://github.com/Mcp20091/kindle-koreader-apps/releases/latest/download/Kindle.Apps.Guide.pdf"

--- Where the downloaded guide goes: the home folder, as a book.
function Setup.guidePath()
    local home = G_reader_settings:readSetting("home_dir") or require("apps/filemanager/filemanagerutil").getDefaultDir()
    return home .. "/Kindle Apps Guide.pdf"
end

-- The download now: nil, { status = "getting" }, or { status = "failed", message }.
local guideDownload

--- Downloads the guide PDF in a child process (KOReader carries on); done() when it's over.
function Setup.downloadGuide(done)
    if guideDownload and guideDownload.status == "getting" then return end
    if NetworkMgr:isConnected() == false then
        guideDownload = { status = "failed", message = _("The Kindle isn't on Wi-Fi.") }
        return done()
    end
    local ffiutil = require("ffi/util")
    local path = Setup.guidePath()
    local part = path .. ".part"
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, err = pcall(function()
            local socketutil = require("socketutil")
            local https = require("ssl.https")
            local ltn12 = require("ltn12")
            -- (GitHub answers with a redirect to where the file is: followed by hand, a few at most.)
            local url = Setup.GUIDE_PDF_URL
            for __ = 1, 5 do
                local f = assert(io.open(part, "wb"))
                socketutil:set_timeout(20, 300)
                local okR, __, code, headers = pcall(https.request, { url = url, method = "GET", redirect = false,
                    sink = ltn12.sink.file(f), headers = { ["User-Agent"] = "KOReader" } })
                socketutil:reset_timeout()
                if not okR then error(tostring(code)) end
                if (code == 301 or code == 302 or code == 303 or code == 307 or code == 308) and headers and headers.location then
                    url = headers.location
                elseif code == 200 then
                    local check = io.open(part, "rb")
                    local head = check and check:read(5)
                    if check then check:close() end
                    if head ~= "%PDF-" then error("What came back isn't a PDF") end
                    os.remove(path)
                    assert(os.rename(part, path))
                    return
                else
                    error("GitHub answered " .. tostring(code))
                end
            end
            error("Too many redirects")
        end)
        if not ok then os.remove(part) end
        ffiutil.writeToFD(write_fd, ok and "K" or ("E" .. tostring(err)), true)
    end, true)
    if not pid then
        guideDownload = { status = "failed", message = tostring(fd) }
        return done()
    end
    guideDownload = { status = "getting" }
    local deadline = os.time() + 10 * 60
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(1, check) end
            ffiutil.terminateSubProcess(pid)
            guideDownload = { status = "failed", message = _("It took too long. Try again when Wi-Fi is better.") }
        else
            local out = (size and size > 0) and ffiutil.readAllFromFD(fd) or "EIt stopped"
            if out:sub(1, 1) == "K" then
                guideDownload = nil
            else
                guideDownload = { status = "failed", message = (out:sub(2):gsub("^.-:%d+: ", "")) }
            end
        end
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
        end
        done()
    end
    UIManager:scheduleIn(1, check)
end

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
    if self.guideOpen then
        return self:renderGuide(c)
    end
    local function guideButton(at)
        button(c, 60, at, c.W - 120, _("Read the user guide"), false, function()
            self.guideOpen = true
            self:render()
            UIManager:setDirty(self, "full")
        end)
    end
    if self.step == 0 then
        c:icon("sparkles", cx - 24, y, 48)
        y = y + 100
        c:text(cx, y, _("Set up your Kindle"), 22, { bold = true, align = "middle" })
        y = y + 44
        paragraph(T(_("A few steps connect the apps: Wi-Fi, then %1. Skip any of them; you can do each later in its app's settings, or run this again from Settings > Set up your Kindle."),
            (function()
                local names = {}
                for __, e in ipairs(self.steps) do if e.key ~= "wifi" and not e.info then table.insert(names, e.title) end end
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
        local explain = y + need < bottom - 140
        for i, e in ipairs(self.steps) do
          local shown = not e.when or (select(2, pcall(e.when)) ~= false)
          if not e.info and shown then
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
        if y <= bottom - 130 then guideButton(bottom - 120) end
        button(c, 60, bottom - 60, c.W - 120, _("Start over"), false, function() self.fromSummary = false self:go(1) end)
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
                -- (Its line wraps once when it's long.)
                local lines = c:wrap(it.text or "", 11, c.W - 162, 2)
                for i, l in ipairs(lines) do c:text(102, y + 34 + 17 * (i - 1), l, 11, { color = C.GREY }) end
                y = y + 56 + 17 * math.max(0, #lines - 1)
            end
        end
        -- Settings to change right on the step (rows(): { { title, value, fn(refresh) } }), as the
        -- launcher's Settings pages: the name, its value at the right; a tap changes it.
        if e.rows then
            local ok, list = pcall(e.rows)
            y = y + 4
            for __, r in ipairs(ok and list or {}) do
              -- ({ heading = "…" }: a grey header over the rows after it, as Settings pages have.)
              if r.heading then
                c:text(60, y + 30, r.heading, 9.5, { bold = true, color = C.GREY })
                y = y + 38
              else
                local top = y
                -- (sub: a grey line under the name, what the setting is.)
                local h = r.sub and 62 or 44
                local valueW = r.value and r.value ~= "" and c:width(r.value, 12) + 12 or 0
                c:text(60, y + 27, r.title or "", 13, { maxw = c.W - 160 - valueW })
                if r.sub then c:text(60, y + 48, r.sub, 10.5, { color = C.GREY, maxw = c.W - 150 }) end
                if r.value and r.value ~= "" then c:text(c.W - 82, y + 27, r.value, 12, { align = "end", color = C.GREY }) end
                c:icon("chevron-right", c.W - 76, y + 13, 16)
                c:hline(60, y + h - 1, c.W - 120)
                c:hit(50, top, c.W - 100, h, function()
                    local okR, err = pcall(r.fn, function()
                        if self.canvas then
                            self:render()
                            UIManager:setDirty(self, "ui")
                        end
                    end)
                    if not okR then require("logger").warn("Setup:", e.key, err) end
                end)
                y = y + h
              end
            end
            y = y + 10
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
            -- (notDoneText: a word of the step's own, or a function for one that changes.)
            local notDone = type(e.notDoneText) == "function" and e.notDoneText() or e.notDoneText
            c:text(60, y, ok and (e.doneText or _("Done")) or (notDone or _("Not set up yet")), 12, { bold = true, color = ok and C.BLACK or C.GREY })
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

--- The guide: a QR code of it online, and its PDF downloaded to this Kindle (then opened).
function Screen_:renderGuide(c)
    local y = Bar.H + 50
    local function back()
        self.guideOpen = false
        self:render()
        UIManager:setDirty(self, "full")
    end
    c:text(60, y, _("User guide"), 20, { bold = true })
    y = y + 36
    for __, l in ipairs(c:wrap(_("Every app, step by step, with pictures. Read it on your phone, or put the PDF on this Kindle to read here."), 12.5, c.W - 120, 4)) do
        c:text(60, y, l, 12.5)
        y = y + 21
    end
    y = y + 16
    local bottom = c.H - 90
    local size = math.min(220, bottom - y - 200)
    if size >= 90 then
        local okQ, qr = pcall(function()
            return require("ui/widget/qrwidget"):new{ text = Setup.GUIDE_URL, width = c:X(size), height = c:X(size) }
        end)
        if okQ and qr and qr.image then
            local px = qr.image:getWidth() / c.u
            c:text(c.W / 2, y + 10, _("Scan to read it on your phone:"), 11.5, { align = "middle", color = C.GREY })
            c:image(qr.image, c.W / 2 - px / 2, y + 24)
            y = y + 24 + px + 20
        end
    end
    local path = Setup.guidePath()
    local have = require("libs/libkoreader-lfs").attributes(path, "mode") == "file"
    local state = guideDownload
    if state and state.status == "getting" then
        button(c, 60, y, c.W - 120, _("Downloading the guide…"), false, function() end)
    elseif have then
        button(c, 60, y, c.W - 120, _("Open the guide on this Kindle"), true, function()
            self:finish(false)
            require("appsreaderbar").openBook(path)
        end)
    else
        button(c, 60, y, c.W - 120, _("Download the PDF to this Kindle"), true, function()
            Setup.downloadGuide(function() if self.guideOpen and not self.closed then self:render() UIManager:setDirty(self, "ui") end end)
            self:render()
            UIManager:setDirty(self, "ui")
        end)
    end
    y = y + 60
    if state and state.status == "failed" then
        for __, l in ipairs(c:wrap(T(_("Couldn't download it: %1"), state.message or ""), 11.5, c.W - 120, 3)) do
            c:text(60, y, l, 11.5, { color = C.GREY })
            y = y + 20
        end
    elseif have then
        c:text(60, y, T(_("Saved as %1, with your books."), "Kindle Apps Guide.pdf"), 11.5, { color = C.GREY, maxw = c.W - 120 })
    else
        c:text(60, y, _("About 10 MB, over Wi-Fi. It goes with your books."), 11.5, { color = C.GREY, maxw = c.W - 120 })
    end
    button(c, 60, bottom, c.W - 120, _("Back"), false, back)
    Bar.draw(c, { title = _("Set up your Kindle"), subtitle = _("User guide"), back = back, clock = true })
end

function Screen_:go(step)
    self.guideOpen = false
    self.helpFor = nil
    -- (a step with `when` that says no now, such as the Library's servers with KOReader's
    -- file browser picked, is passed over in the way it was going)
    local dir = step < (self.step or 0) and -1 or 1
    local function off(i)
        local e = self.steps[i]
        if not (e and e.when) then return false end
        local ok, yes = pcall(e.when)
        return ok and yes == false
    end
    while off(step) do step = step + dir end
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

--- Draws the step on screen again (a step whose rows came in later, such as Updates').
function Setup.redraw()
    if shown and shown.canvas then
        shown:render()
        UIManager:setDirty(shown, "ui")
    end
end

function Setup.show()
    if shown then return end
    KO.flashOnUncover()
    shown = Screen_:new{}
    KO.showFull(shown)
end


return Setup
