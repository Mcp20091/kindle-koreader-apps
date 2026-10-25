--[[--
The app around an article open in KOReader's reader: a toolbar down the left
(like Notes) or across the top, in place of KOReader's status bar; the
Contents panel; a preview when a link to another article is tapped; Save and
Back. The page itself is KOReader's, so fonts, highlights, the dictionary and
footnotes (the article's sources) work as in any book.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local API = require("wikiapi")
local Canvas = require("wikicanvas")
local WBar = require("wikibar")
local M = require("wikimodel")

local Screen = Device.screen
local C = Canvas

local TB = 40       -- the toolbar's width (left) or height (top), in page units
local TAB = 34      -- the tab left when the toolbar is hidden

local Bar = {}
Bar.__index = Bar

function Bar:new(o)
    return setmetatable(o, Bar)
end

function Bar:store() return self.wiki.store end
function Bar:side() return self:store():read("toolbar") == "top" and "top" or "left" end
function Bar:hidden() return self:store():read("toolbar_hidden") == true end

local function unit() return math.min(Screen:getWidth(), Screen:getHeight()) / 620 end

--- Room the toolbar takes from the page, in pixels: left, top.
function Bar:room()
    if self:hidden() then return 0, 0 end
    local px = math.floor(TB * unit() + 0.5)
    if self:side() == "top" then return 0, px end
    return px, 0
end

-- KOReader's own taps there (the menus, turning the page, highlighting) give way to the toolbar.
local OVERRIDES = {
    "readermenu_tap", "readermenu_ext_tap", "readerconfigmenu_tap", "readerconfigmenu_ext_tap",
    "tap_forward", "tap_backward", "readerhighlight_tap", "readerhighlight_tap_select_mode", "tap_link",
    "readerfooter_tap", "tap_top_left_corner", "tap_top_right_corner", "tap_left_bottom_corner",
    "tap_right_bottom_corner",
}
local HOLD_OVERRIDES = { "readerhighlight_hold", "readerfooter_hold" }

function Bar:attach()
    local ui = self.ui
    local bar = self
    -- The page's margins make room for the toolbar (KOReader's own margins stay as set).
    local ts = ui.typeset
    local setMargins = ts.onSetPageMargins
    ts.onSetPageMargins = function(this, m, cb)
        local l, t = bar:room()
        local scale = Screen:scaleBySize(1000) / 1000
        local b = m[4]
        -- (KOReader keeps the hidden status bar's room at the bottom: the page has it instead)
        local footer = this.view.footer
        if bar.footerOff and footer and not footer.reclaim_height then
            b = math.max(0, b - footer:getHeight() / scale)
        end
        return setMargins(this, { m[1] + l / scale, m[2] + t / scale, m[3], b }, cb)
    end
    -- Links to other articles open here.
    local link = ui.link
    local external = link.onGoToExternalLink
    link.onGoToExternalLink = function(this, url)
        if bar:followLink(url) then return true end
        return external(this, url)
    end
    ui.view:registerViewModule("wikipedia_toolbar", self)
    local all = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }
    ui:registerTouchZones({
        { id = "wikipedia_toolbar_tap", ges = "tap", screen_zone = all, overrides = OVERRIDES,
          handler = function(ges) return bar:onTap(ges) end },
        { id = "wikipedia_toolbar_hold", ges = "hold", screen_zone = all, overrides = HOLD_OVERRIDES,
          handler = function(ges) return bar:onHold(ges) end },
        -- In from the left edge: back to the article before (or Wikipedia's front page).
        { id = "wikipedia_edge_back", ges = "swipe", screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 0.1, ratio_h = 1 },
          overrides = { "apps_edge_back", "paging_swipe", "rolling_swipe" },
          handler = function(ges)
              if ges.direction ~= "east" or bar.closed then return end
              bar.wiki:goBack()
              return true
          end },
    })
end

function Bar:ready(position)
    local footer = self.ui.view.footer
    if footer and footer.applyFooterMode then
        footer:applyFooterMode(0)
        self.footerOff = true
    end
    self:applyMargins()
    if position then self.ui:handleEvent(Event:new("GotoXPointer", position, position)) end
end

function Bar:detach()
    self.closed = true
end

function Bar:applyMargins()
    local ts = self.ui.typeset
    if ts and ts.unscaled_margins then
        self.ui:handleEvent(Event:new("SetPageMargins", ts.unscaled_margins))
    end
end

--- The toolbar moved, or was hidden or shown.
function Bar:relayout()
    self:applyMargins()
    self:repaint()
end

function Bar:repaint()
    UIManager:setDirty(self.ui.dialog, "ui")
end

-- ------------------------------------------------------------------ drawing

function Bar:pageLabel()
    local doc = self.ui.document
    local ok, page = pcall(function() return doc:getCurrentPage() end)
    local pages = doc:getPageCount()
    return T("%1/%2", ok and page or 1, pages), ok and page or 1, pages
end

function Bar:render()
    local c = Canvas.new(Screen:getWidth(), Screen:getHeight(), false)
    self.canvas = c
    if self:hidden() then
        local icon = self:side() == "top" and "panel-top-open" or "panel-left-open"
        c:box(0, 0, TAB, TAB, { r = 6, fill = C.WHITE, border = C.BLACK, bw = 1.2 })
        c:icon(icon, 7, 7, 20)
        c:hit(0, 0, TAB + 10, TAB + 10, function() self:show() end)
        return c
    end
    local saved = self.article.saved
    local buttons = {
        { "house", function() self.wiki:goLauncher() end },
        { "arrow-left", function() self.wiki:goBack() end },
        false,
        { "search", function() self.wiki:show("search") end },
        { "table-of-contents", function() self:contents() end, "toc" },
        { saved and "bookmark-check" or "bookmark", function() self:toggleSave() end, saved and "saved" },
        false,
        { "languages", function() self:languages() end },
        { "type", function() self.ui:handleEvent(Event:new("ShowConfigMenu")) end },
    }
    if self:side() == "top" then
        c:rect(0, 0, c.W, TB, C.WHITE)
        c:hline(0, TB, c.W, C.BLACK, 1.2)
        local x = 10
        local function btn(b)
            if not b then
                c:rect(x + 2, 12, 1, TB - 24, C.MID)
                x = x + 10
                return
            end
            local on = b[3] and (b[3] == "saved" or self.active == b[3])
            if on then c:box(x, 5, 32, 30, { r = 6, fill = C.FILL }) end
            c:icon(b[1], x + 5, 9, 22, on)
            c:hit(x - 4, 0, 40, TB, b[2])
            x = x + 40
        end
        for __, b in ipairs(buttons) do btn(b) end
        btn(false)
        btn({ "ellipsis", function() self:more() end })
        btn({ "panel-top-close", function() self:hide() end })
        local label = self:pageLabel()
        local lw = c:width(label, 12, true)
        local rx = c.W - 10
        c:icon("chevron-right", rx - 24, 8, 24)
        c:hit(rx - 32, 0, 36, TB, function() self:turn(1) end)
        c:text(rx - 30, 26, label, 12, { bold = true, align = "end" })
        c:icon("chevron-left", rx - 34 - lw - 26, 8, 24)
        c:hit(rx - 34 - lw - 32, 0, 36, TB, function() self:turn(-1) end)
        return c
    end
    c:rect(0, 0, TB, c.H, C.WHITE)
    c:rect(TB, 0, 1.2, c.H, C.BLACK)
    local y = 10
    local function btn(b)
        if not b then
            c:rect(11, y - 5, TB - 22, 1, C.MID)
            y = y + 6
            return
        end
        local on = b[3] and (b[3] == "saved" or self.active == b[3])
        if on then c:box(5, y - 5, 30, 30, { r = 6, fill = C.FILL }) end
        c:icon(b[1], 10, y, 20, on)
        c:hit(0, y - 9, TB, 38, b[2])
        y = y + 38
    end
    for __, b in ipairs(buttons) do btn(b) end
    y = c.H - 5 * 38 - 18
    btn({ "chevron-up", function() self:turn(-1) end })
    c:text(TB / 2, y + 4, (self:pageLabel()), 9, { bold = true, align = "middle", maxw = TB - 2 })
    y = y + 20
    btn({ "chevron-down", function() self:turn(1) end })
    btn({ "ellipsis", function() self:more() end })
    btn({ "panel-left-close", function() self:hide() end })
    return c
end

function Bar:paintTo(bb, x, y)
    if self.closed then return end
    local c = self:render()
    c:paint(bb, x, y)
end

function Bar:onTap(ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit then
        if hit.tap then hit.tap() end
        return true
    end
end

-- (a firm pen press is a hold: a button's own hold, or its tap)
function Bar:onHold(ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit then
        local fn = hit.hold or hit.tap
        if fn then fn() end
        return true
    end
end

-- ------------------------------------------------------------------ actions

function Bar:turn(delta)
    self.ui:handleEvent(Event:new("GotoViewRel", delta))
end

function Bar:hide()
    self:store():write("toolbar_hidden", true)
    self:relayout()
end

function Bar:show()
    self:store():write("toolbar_hidden", false)
    self:relayout()
end

function Bar:more()
    local items = { { text = _("Wikipedia home"), fn = function() self.wiki:show() end } }
    local web = self.wiki:webPage()
    if web then
        table.insert(items, { text = _("Open on the web page"), fn = function() web:openOnWeb("wikipedia") end })
    end
    table.insert(items, { text = _("Update"), fn = function() self.wiki:updateArticle(self.article.path) end })
    table.insert(items, { text = _("Wikipedia settings"), fn = function() self.wiki:show("settings") end })
    table.insert(items, { text = _("KOReader menu"), fn = function() self.ui:handleEvent(Event:new("ShowMenu")) end })
    table.insert(items, { text = _("Close Wikipedia"), fn = function() self.wiki:closeApp() end })
    WBar.list(self.article.title, items)
end

-- Save keeps the article in the Wikipedia folder; reading goes on in the saved copy, on the same page.
function Bar:toggleSave()
    if self.article.saved then
        if WBar.canUndo() then return self:unsave() end
        WBar.confirm{
            text = _("Remove this article from the Kindle?"),
            ok = _("Remove"),
            cancel = _("Cancel"),
            danger = true,
            onOk = function() self:unsave() end,
        }
        return
    end
    local a = self.article
    local store = self:store()
    local path = store:savedPath(a.title, a.lang)
    if not store:copy(a.path, path) then
        return self.wiki:notice(_("The article couldn't be saved. Is the Kindle's storage full?"))
    end
    store:setMeta(path, { title = a.title, lang = a.lang, description = a.description or store:meta(a.path).description,
        images = store:meta(a.path).images })
    local position = self.ui.rolling and self.ui.rolling:getBookLocation()
    self.wiki:openFile(path, { position = position, after = function()
        WBar.toast(_("Saved on this Kindle"))
    end })
end

--- No longer saved: reading goes on in a copy in the cache, and the saved one goes.
function Bar:unsave(quiet)
    local a = self.article
    local store = self:store()
    local wiki = self.wiki
    local path = store:cachePath(a.title, a.lang)
    if not store:copy(a.path, path) then return false end
    store:setMeta(path, { title = a.title, lang = a.lang, description = a.description, images = store:meta(a.path).images })
    local position = self.ui.rolling and self.ui.rolling:getBookLocation()
    local saved = a.path
    wiki:unnotifySaved(saved)
    wiki:openFile(path, { position = position, after = function()
        if not store:putAside(saved) or quiet then return end
        if not WBar.undo(_("Removed from this Kindle"), function() wiki:restoreSaved(saved) end) then
            WBar.toast(_("Removed from this Kindle"))
        end
    end })
    return true
end

function Bar:languages()
    local a = self.article
    self.wiki:online(function() self.wiki:fetch(_("Looking up languages…"), function() return API.languages(a.lang, a.title) end, function(list)
        if #list == 0 then return self.wiki:notice(_("This article is only in this language.")) end
        local items = {}
        for __, l in ipairs(list) do
            table.insert(items, { text = l.name, right = l.title, fn = function()
                self.wiki:openArticle(l.title, l.lang, { from = "article" })
            end })
        end
        self.wiki:showPick(_("Read in another language"), items)
    end) end)
end

-- ------------------------------------------------------------------ links

function Bar:followLink(url)
    local lang, title = M.fromUrl(url)
    if not lang then return false end
    local store = self:store()
    local have = store:find(title, lang)
    if have then
        self.wiki:openCopy(have, { from = "article" })
    elseif store:read("link_tap") == "open" then
        self.wiki:openArticle(title, lang, { from = "article" })
    else
        self:preview(title, lang)
    end
    return true
end

local Panel -- the Contents panel and the link preview: drawn on the canvas, over the page

function Bar:preview(title, lang)
    self.wiki:online(function() self.wiki:fetch(_("Opening…"), function() return API.summary(lang, title) end, function(info)
        if info == false then return self.wiki:notice(T(_("Wikipedia has no article called “%1”."), title)) end
        -- (its own refresh: otherwise only where "Opening…" was is redrawn on e-ink)
        local panel = Panel:new{ bar = self, kind = "preview", info = info, lang = lang }
        UIManager:show(panel, "ui", panel.box)
    end) end)
end

function Bar:contents()
    local toc = self.ui.toc
    if toc and toc.fillToc then toc:fillToc() end
    if not toc or not toc.toc or #toc.toc == 0 then
        return self.wiki:notice(_("This article has no sections."))
    end
    self.active = "toc"
    self:repaint()
    local panel = Panel:new{ bar = self, kind = "toc" }
    UIManager:show(panel, "ui", panel.box)
end

-- ------------------------------------------------------------------ panels

Panel = InputContainer:extend{
    bar = nil,
    kind = "toc",   -- or "preview"
}

function Panel:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } },
        Hold = { GestureRange:new{ ges = "hold", range = all } },
    }
    self.page = 1
    self:render()
    -- Touches arriving as it shows (the rest of the tap that opened it) are
    -- dropped, so they don't close it again (a tap outside it closes it).
    Device.input:inhibitInputUntil(true)
end

function Panel:close()
    UIManager:close(self)
    if self.kind == "toc" then
        self.bar.active = nil
        self.bar:repaint()
    end
    UIManager:setDirty(self.bar.ui.dialog, "ui")
end

function Panel:onClose()
    self:close()
    return true
end

function Panel:onTap(_, ges)
    local hit = self.canvas:find(ges.pos.x, ges.pos.y)
    if hit then
        if hit.tap then hit.tap() end
    elseif not self.box:contains(ges.pos) then
        self:close()
    end
    return true
end

-- (a firm pen press is a hold: the same as a tap)
function Panel:onHold(_, ges)
    local hit = self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and hit.hold then
        hit.hold()
        return true
    end
    return self:onTap(_, ges)
end

function Panel:onSwipe(_, ges)
    if WBar.fromLeftEdge(ges) then return self:onClose() end
    if self.kind ~= "toc" then return true end
    local d = ges.direction
    self:turn((d == "west" or d == "north") and 1 or (d == "east" or d == "south") and -1 or 0)
    return true
end

function Panel:turn(delta)
    local n = math.max(1, math.min(self.pages or 1, self.page + delta))
    if n ~= self.page then
        self.page = n
        self:render()
        UIManager:setDirty(self, "ui")
    end
end

function Panel:paintTo(bb, x, y)
    local b = self.box
    -- (only the panel: the page and the toolbar stay around it)
    bb:paintRect(x + b.x, y + b.y, b.w, b.h, Blitbuffer.COLOR_WHITE)
    self.canvas:paint(bb, x, y)
end

function Panel:render()
    local c = Canvas.new(self.w, self.h, false)
    self.canvas = c
    if self.kind == "preview" then self:drawPreview(c) else self:drawToc(c) end
end

function Panel:setBox(c, x, y, w, h)
    self.box = Geom:new{ x = c:X(x) - 2, y = c:X(y) - 2, w = c:X(w) + c:X(6), h = c:X(h) + c:X(6) }
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
end

function Panel:drawToc(c)
    local bar = self.bar
    local ui = bar.ui
    local left = (not bar:hidden() and bar:side() == "left") and TB or 0
    local top = (not bar:hidden() and bar:side() == "top") and TB or 0
    local pw = math.min(c.W - left, 420)
    self:setBox(c, left, top, pw, c.H - top)
    c:rect(left + pw, top, 1.6, c.H - top, C.BLACK)
    c:text(left + 18, top + 34, _("Contents"), 18, { bold = true })
    c:icon("x", left + pw - 36, top + 14, 22)
    c:hit(left + pw - 50, top, 50, 52, function() self:close() end)
    c:hline(left, top + 52, pw, C.BLACK, 1.2)
    local entries = ui.toc.toc
    local cur = ui.toc:getTocIndexByPage(ui.document:getCurrentPage())
    local rows = math.floor((c.H - top - 52 - 50) / 46)
    self.pages = math.max(1, math.ceil(#entries / rows))
    if cur and not self.placed then
        self.placed = true
        self.page = math.floor((cur - 1) / rows) + 1
    end
    local y = top + 52
    for i = (self.page - 1) * rows + 1, math.min(#entries, self.page * rows) do
        local e = entries[i]
        local depth = math.max(0, (e.depth or 1) - 1)
        local x = left + 18 + math.min(depth, 4) * 20
        local here = i == cur
        if here then c:rect(left + 2, y + 4, 4, 38, C.BLACK) end
        local pageText = tostring(e.page or "")
        c:text(x, y + 29, M.stripHtml(e.title or ""), 14.5, { bold = here, maxw = left + pw - x - 50 })
        c:text(left + pw - 16, y + 29, pageText, 13, { color = C.GREY, align = "end" })
        c:hit(left, y, pw, 46, function()
            self:close()
            ui.link:addCurrentLocationToStack()
            if e.xpointer then
                ui:handleEvent(Event:new("GotoXPointer", e.xpointer, e.xpointer))
            else
                ui:handleEvent(Event:new("GotoPage", e.page))
            end
        end)
        y = y + 46
        c:hline(left + 16, y, pw - 32, C.LINE)
    end
    if self.pages > 1 then
        local cx, by = left + pw / 2, c.H - 18
        -- (as the launcher's pop-ups turn pages: ‹ 1/3 ›)
        local label = self.page .. "/" .. self.pages
        local lw = 140
        c:icon("chevron-left", cx - lw / 2, by - 14, 18)
        c:text(cx, by, label, 11, { align = "middle", color = C.GREY })
        c:icon("chevron-right", cx + lw / 2 - 18, by - 14, 18)
        c:hit(cx - lw / 2 - 20, by - 30, lw / 2 + 20, 44, function() self:turn(-1) end)
        c:hit(cx, by - 30, lw / 2 + 20, 44, function() self:turn(1) end)
    end
end

function Panel:drawPreview(c)
    local info, lang, bar = self.info, self.lang, self.bar
    local bw = c.W - 80
    local lines = c:wrap(info.extract or "", 13.5, bw - 40, { serif = true, max = 9 })
    local bh = 94 + #lines * 20 + 10 + 84
    local bx, by = 40, math.max(60, (c.H - bh) / 2)
    self:setBox(c, bx, by, bw, bh)
    c:box(bx + 4, by + 4, bw, bh, { r = 10, fill = C.BLACK })
    c:box(bx, by, bw, bh, { r = 10, fill = C.WHITE, border = C.BLACK, bw = 1.6 })
    c:text(bx + 20, by + 34, info.title, 18, { bold = true, maxw = bw - 70 })
    c:icon("x", bx + bw - 36, by + 14, 22)
    c:hit(bx + bw - 50, by, 50, 50, function() self:close() end)
    if info.description then c:text(bx + 20, by + 54, info.description, 12.5, { color = C.GREY, maxw = bw - 40 }) end
    c:hline(bx, by + 68, bw, C.BLACK, 1)
    for i, l in ipairs(lines) do c:text(bx + 20, by + 94 + (i - 1) * 20, l, 13.5, { serif = true }) end
    local saved = bar:store():findSaved(info.title, lang)
    WBar.iconButtons(c, bx, by + bh - 84, bw, {
        { icon = "copy", text = _("Copy"), fn = function()
            WBar.copy(info.title .. "\n\n" .. (info.extract or ""))
        end },
        { icon = saved and "bookmark-check" or "bookmark", text = saved and _("Saved") or _("Save"), enabled = not saved,
            fn = function()
                self:close()
                bar.wiki:saveArticle(info.title, lang, info.description)
            end },
        { icon = "book-open", text = _("Open"), primary = true, fn = function()
            self:close()
            bar.wiki:openArticle(info.title, lang, { from = "article" })
        end },
    }, function(b) b.fn() end)
end

return Bar
