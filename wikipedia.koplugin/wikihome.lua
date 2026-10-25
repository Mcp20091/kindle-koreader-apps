--[[--
Wikipedia's own screens, over whatever is open: the front page with its three
tabs (Today: the featured article, On this day and, if chosen, In the news
and Most read; Saved; Recent), the search results, all of On this day, and
the settings. Long lists turn pages (swipe, or the arrows at the bottom).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local Bar = require("wikibar")
local Canvas = require("wikicanvas")
local M = require("wikimodel")

local Screen = Device.screen
local C = Canvas

-- Not modal: dialogs (menus, the keyboard) have to show on top of it.
local Home = InputContainer:extend{
    covers_fullscreen = true,
    flash_on_uncover = true,  -- a full refresh when a dialog over it closes
    wiki = nil,     -- the plugin (main.lua)
    tab = "today",  -- today, saved, recent; or search, events, settings
}

function Home:init()
    require("wikibar").flashOnUncover()
    self.store = self.wiki.store
    self.page = 1
    self.history = {}
    self.selected = nil
    self:relayout()
    if self.tab == "search" then
        self.tab = "today"
        UIManager:nextTick(function() self:askSearch() end)
    elseif self.tab == "settings" or self.tab == "pick" then
        -- (from an article's toolbar: back goes back to the article)
        self.closeOnBack = true
    end
end

function Home:relayout()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = all } },
        Hold = { GestureRange:new{ ges = "hold", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    self:render()
end

function Home:paintTo(bb, x, y)
    if self.w ~= Screen:getWidth() or self.h ~= Screen:getHeight() then self:relayout() end
    bb:paintRect(x, y, self.w, self.h, Blitbuffer.COLOR_WHITE)
    if self.canvas then self.canvas:paint(bb, x, y) end
end

function Home:refresh(full)
    self:render()
    UIManager:setDirty(self, full and "full" or "ui")
end

--- Show another screen (`to`), remembering this one for the back arrow.
function Home:go(to, keep)
    if not keep then table.insert(self.history, { tab = self.tab, page = self.page }) end
    self.tab, self.page, self.selected = to, 1, nil
    self:refresh(true)
end

function Home:back()
    if self.selected then
        self.selected = nil
        return self:refresh()
    end
    local prev = table.remove(self.history)
    if prev then
        self.tab, self.page = prev.tab, prev.page
        return self:refresh(true)
    end
    if self.closeOnBack then return self.wiki:closeHome() end
    -- (the top page: back to the launcher, as in every app)
    self.wiki:goLauncher()
end

function Home:onClose()
    self:back()
    return true
end

--- A notification came in while this is on top: the bell's count drawn again.
function Home:notificationsChanged()
    self:refresh()
end

-- ------------------------------------------------------------------ gestures

function Home:onTap(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and hit.tap then hit.tap() end
    return true
end

function Home:onHold(_, ges)
    local hit = self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit then (hit.hold or hit.tap or function() end)() end
    return true
end

function Home:onSwipe(_, ges)
    local d = ges.direction
    -- (in from the left edge: Back, as in every app)
    if Bar.fromLeftEdge(ges) then return self:back() or true end
    if d == "west" or d == "north" then self:turn(1)
    elseif d == "east" or d == "south" then self:turn(-1)
    else UIManager:setDirty(self, "full") end
    return true
end

function Home:turn(delta)
    local n = math.max(1, math.min(self.pages or 1, self.page + delta))
    if n == self.page then return end
    self.page = n
    self:refresh(true)
end

-- ------------------------------------------------------------------ drawing helpers

local function pill(c, x, y, w, h, label, on, icon, size)
    size = size or 13
    c:box(x, y, w, h, { r = h / 2, fill = on and C.FILL or nil, border = C.BLACK, bw = 1.2 })
    local tw = c:width(label, size, true) + (icon and 22 or 0)
    local sx = x + (w - tw) / 2
    if icon then
        c:icon(icon, sx, y + (h - 16) / 2, 16, on)
        sx = sx + 22
    end
    c:text(sx, y + h / 2 + size * 0.36, label, size, { bold = true, color = on and C.ON_FILL or C.BLACK })
end

--- The title bar (the one all the apps share: wikibar.lua) for this screen;
-- drawn last, once the screen knows how many pages it has.
function Home:header(c, title, lang)
    self.barTitle, self.barLang = title, lang
end

function Home:drawBar(c)
    local buttons = {}
    if self.barLang then
        table.insert(buttons, { label = self.store:lang():upper(), function() self:pickLanguage() end })
    end
    Bar.draw(c, {
        title = self.barTitle,
        back = function() self:back() end,
        home = Bar.hasHome() and function() self.wiki:goLauncher() end or nil,
        buttons = buttons,
        pager = { page = self.page, pages = self.pages or 1, turn = function(d) self:turn(d) end },
        refresh = function() self:reload() end,
        bell = Bar.hasBell() and function() Bar.showNotifications() end or nil,
        menu = function() self:menu() end,
    })
end

--- ⋮: Open on the web page, Light, Night mode, Refresh screen; Settings last.
function Home:menu()
    local extra = {}
    local web = self.wiki:webPage()
    if web then table.insert(extra, { _("Open on the web page"), function() web:openOnWeb("wikipedia") end }) end
    Bar.menu(self.wiki.ui, self, extra, self.tab ~= "settings" and function() self:go("settings") end or nil)
end

--- ⟳: the screen drawn again with a full e-ink refresh; Today fetched again too.
function Home:reload()
    self:refresh(true)
    if self.tab == "today" and NetworkMgr:isConnected() then
        self.loading = false
        self:loadToday()
    end
end

function Home:searchBar(c, y, text)
    local w = c.W - 32 - 122
    c:box(16, y, w, 42, { r = 21, border = C.BLACK, bw = 1.3 })
    c:icon("search", 30, y + 11, 20)
    if text then
        c:text(58, y + 27, text, 15, { maxw = w - 56 })
    else
        c:text(58, y + 27, _("Search Wikipedia"), 15, { color = C.MID, maxw = w - 56 })
    end
    c:hit(16, y, w, 42, function() self:askSearch(text) end)
    pill(c, c.W - 16 - 112, y, 112, 42, _("Random"), false, "shuffle", 14)
    c:hit(c.W - 16 - 112, y, 112, 42, function() self.wiki:random() end)
end

function Home:tabs(c, y)
    local saved = self.savedList or self.store:listSaved()
    local list = {
        { "today", _("Today") },
        { "saved", #saved > 0 and T(_("Saved (%1)"), #saved) or _("Saved") },
        { "recent", _("Recent") },
    }
    local x = 16
    for __, t in ipairs(list) do
        local w = c:width(t[2], 13.5, true) + 34
        pill(c, x, y, w, 32, t[2], self.tab == t[1], nil, 13.5)
        local key = t[1]
        c:hit(x, y - 6, w, 44, function()
            if self.tab ~= key then
                self.tab, self.page, self.selected, self.history = key, 1, nil, {}
                self:refresh(true)
            end
        end)
        x = x + w + 8
    end
end

function Home:sectionTitle(c, y, label, right)
    c:text(16, y, label, 15, { bold = true })
    if right then c:text(c.W - 16, y, right, 12, { color = C.GREY, align = "end" }) end
end

-- ------------------------------------------------------------------ render

function Home:render()
    if self.canvas then self.canvas:release() end
    local c = Canvas.new(self.w, self.h, false)
    c.turn = function(d) self:turn(d) end
    self.canvas = c
    self.savedList = nil
    -- (each screen says how many pages it has; settings has one)
    self.pages = 1
    if self.tab == "settings" then
        self:drawSettings(c)
        -- (opened at a setting, from the launcher's search: its page)
        local want = self.jump and self.rowPages[self.jump]
        self.jump = nil
        if want and want ~= self.page then
            self.page = want
            return self:render()
        end
    elseif self.tab == "search" then
        self:drawSearch(c)
    elseif self.tab == "pick" then
        self:drawPick(c)
    elseif self.tab == "folder" then
        self:drawFolder(c)
    elseif self.tab == "events" then
        self:drawEvents(c)
    else
        self.savedList = self.store:listSaved()
        self:header(c, _("Wikipedia"), true)
        self:searchBar(c, 56)
        self:tabs(c, 112)
        if self.tab == "saved" then self:drawSaved(c, 164)
        elseif self.tab == "recent" then self:drawRecent(c, 164)
        else self:drawToday(c, 164) end
    end
    self:drawBar(c)
end

-- ------------------------------------------------------------------ Today

local function dateLabel()
    return (os.date("%B %d"):gsub(" 0", " "))
end

function Home:loadToday()
    if self.loading then return end
    self.loading = true
    self.loadError = nil
    self:refresh()
    self.wiki:fetchToday(self.store:lang(), function(feed)
        self.loading = false
        if not feed then self.loadError = true end
        if UIManager:isWidgetShown(self) then self:refresh() end
    end)
end

function Home:drawToday(c, top)
    local lang = self.store:lang()
    local feed = self.store:today(lang)
    local sections = self.store:read("sections")
    local bottom = c.H - 8
    local flow = c:flow(top, bottom, self.page)
    if not feed then
        if self.loading then
            flow:block(80, function(y) c:text(c.W / 2, y + 40, _("Loading today's articles…"), 14, { align = "middle", color = C.GREY }) end)
        elseif not NetworkMgr:isConnected() or self.loadError then
            self:offlineCard(c, flow)
            self:savedBlock(c, flow)
        else
            flow:block(80, function(y) c:text(c.W / 2, y + 40, _("Loading today's articles…"), 14, { align = "middle", color = C.GREY }) end)
            UIManager:nextTick(function() self:loadToday() end)
        end
        self.pages = flow:pages()
        return
    end
    local any = false
    if sections.featured and feed.featured then
        any = true
        local f = feed.featured
        local lines = c:wrap(f.extract or "", 13, c.W - 64, { serif = true, max = 5 })
        local h = 104 + #lines * 18.5 + 76
        flow:block(h + 26, function(y)
            self:sectionTitle(c, y + 12, _("Today's featured article"), os.date("%a %b %d"):gsub(" 0", " "))
            local by = y + 24
            c:box(16, by, c.W - 32, h, { r = 10, border = C.BLACK, bw = 1.2 })
            c:text(32, by + 32, f.title, 20, { bold = true, maxw = c.W - 64 })
            if f.description then c:text(32, by + 52, f.description, 12.5, { color = C.GREY, maxw = c.W - 64 }) end
            for i, l in ipairs(lines) do c:text(32, by + 78 + (i - 1) * 18.5, l, 13, { serif = true }) end
            c:hit(16, by, c.W - 32, h - 76, function() self.wiki:openArticle(f.title, lang, { from = "home" }) end)
            local saved = self.store:findSaved(f.title, lang)
            Bar.iconButtons(c, 16, by + h - 80, c.W - 32, {
                { icon = saved and "bookmark-check" or "bookmark", text = saved and _("Saved") or _("Save"), enabled = not saved,
                    fn = function() self.wiki:saveArticle(f.title, lang, f.description, function() self:refresh() end) end },
                { icon = "book-open", text = _("Read"), primary = true,
                    fn = function() self.wiki:openArticle(f.title, lang, { from = "home" }) end },
            }, function(b) b.fn() end)
        end)
        flow:gap(18)
    end
    if sections.onthisday and #feed.onthisday > 0 then
        any = true
        flow:block(30, function(y) self:sectionTitle(c, y + 18, _("On this day"), dateLabel()) end, 60)
        for i = 1, math.min(5, #feed.onthisday) do
            self:eventRow(c, flow, feed.onthisday[i], lang, i < math.min(5, #feed.onthisday))
        end
        if #feed.onthisday > 5 then
            flow:block(40, function(y)
                local label = T(_("All %1 events"), #feed.onthisday) .. "  ›"
                c:text(c.W / 2, y + 26, label, 13, { bold = true, align = "middle" })
                c:hit(c.W / 2 - 120, y, 240, 40, function() self:go("events") end)
            end)
        end
        flow:gap(14)
    end
    if sections.news and #feed.news > 0 then
        any = true
        flow:block(30, function(y) self:sectionTitle(c, y + 18, _("In the news")) end, 60)
        for i, n in ipairs(feed.news) do
            self:storyRow(c, flow, n, lang, i < #feed.news)
        end
        flow:gap(14)
    end
    if sections.mostread and #feed.mostread > 0 then
        any = true
        flow:block(30, function(y) self:sectionTitle(c, y + 18, _("Most read yesterday")) end, 60)
        for i = 1, math.min(10, #feed.mostread) do
            local p = feed.mostread[i]
            flow:block(58, function(y)
                c:text(16, y + 24, i .. ".", 14, { bold = true, color = C.GREY })
                c:text(46, y + 24, p.title, 15.5, { bold = true, maxw = c.W - 90 })
                if p.description then c:text(46, y + 44, p.description, 12.5, { color = C.GREY, maxw = c.W - 90 }) end
                c:icon("chevron-right", c.W - 34, y + 18, 18)
                c:hline(46, y + 57, c.W - 62, C.LINE)
                c:hit(0, y, c.W, 58, function() self.wiki:openArticle(p.title, lang, { from = "home" }) end)
            end)
        end
    end
    if not any then
        flow:block(80, function(y)
            c:para(32, y + 30, _("Wikipedia doesn't publish a featured article or On this day in this language. Search, Random, Saved and Recent all work."),
                13.5, c.W - 64, 20, { color = C.GREY })
        end)
    end
    self.pages = flow:pages()
end

--- Tap an event (or a story) to read its article; with more than one, choose.
function Home:chooseArticle(text, pages, lang)
    if #pages == 0 then return end
    if #pages == 1 then return self.wiki:openArticle(pages[1].title, lang, { from = "home" }) end
    local items = {}
    for __, p in ipairs(pages) do
        table.insert(items, { text = p.title, fn = function() self.wiki:openArticle(p.title, lang, { from = "home" }) end })
    end
    Bar.list(text, items)
end

function Home:eventRow(c, flow, e, lang, rule)
    local lines = c:wrap(e.text, 13, c.W - 32 - 56 - 30, { max = 3 })
    local h = 14 + #lines * 18
    flow:block(h + 8, function(y)
        c:text(16, y + 22, e.year and tostring(e.year) or "", 13, { bold = true })
        for i, l in ipairs(lines) do c:text(72, y + 22 + (i - 1) * 18, l, 13) end
        c:icon("chevron-right", c.W - 34, y + 10, 18)
        if rule then c:hline(72, y + h + 3, c.W - 88, C.LINE) end
        c:hit(0, y, c.W, h + 8, function() self:chooseArticle(e.text, e.pages, lang) end, function()
            Bar.list(tostring(e.year or ""), {
                { text = _("Read"), fn = function() self:chooseArticle(e.text, e.pages, lang) end },
                { text = _("Copy"), fn = function() Bar.copy((e.year and (e.year .. ": ") or "") .. e.text) end },
            })
        end)
    end)
end

function Home:storyRow(c, flow, n, lang, rule)
    local lines = c:wrap(n.text, 13, c.W - 32 - 30, { max = 4 })
    local h = 14 + #lines * 18
    flow:block(h + 8, function(y)
        for i, l in ipairs(lines) do c:text(16, y + 22 + (i - 1) * 18, l, 13) end
        c:icon("chevron-right", c.W - 34, y + 10, 18)
        if rule then c:hline(16, y + h + 3, c.W - 32, C.LINE) end
        c:hit(0, y, c.W, h + 8, function() self:chooseArticle(n.text, n.pages, lang) end, function()
            Bar.list(nil, {
                { text = _("Read"), fn = function() self:chooseArticle(n.text, n.pages, lang) end },
                { text = _("Copy"), fn = function() Bar.copy(n.text) end },
            })
        end)
    end)
end

function Home:offlineCard(c, flow)
    flow:block(196, function(y)
        c:box(16, y + 6, c.W - 32, 180, { r = 10, border = C.BLACK, bw = 1.2 })
        c:icon("wifi-off", c.W / 2 - 16, y + 24, 32)
        local title = self.loadError and NetworkMgr:isConnected() and _("Can't reach Wikipedia") or _("No Wi-Fi")
        c:text(c.W / 2, y + 82, title, 17, { bold = true, align = "middle" })
        c:text(c.W / 2, y + 104, _("Turn on Wi-Fi for Today, Search and Random."), 13, { color = C.GREY, align = "middle", maxw = c.W - 64 })
        local label = NetworkMgr:isConnected() and _("Try again") or _("Turn on Wi-Fi")
        Bar.iconButtons(c, 16, y + 106, c.W - 32, { { icon = "wifi", text = label, primary = true } }, function()
            NetworkMgr:runWhenConnected(function() self:loadToday() end)
        end)
    end)
    flow:gap(20)
end

function Home:savedBlock(c, flow)
    local list = self.savedList or self.store:listSaved()
    if #list == 0 then return end
    flow:block(30, function(y) self:sectionTitle(c, y + 18, _("Saved on this Kindle"), _("Open without Wi-Fi")) end, 68)
    for __, a in ipairs(list) do self:savedRow(c, flow, a) end
end

-- ------------------------------------------------------------------ all events

function Home:drawEvents(c)
    self:header(c, _("On this day") .. " · " .. dateLabel())
    local lang = self.store:lang()
    local feed = self.store:today(lang)
    local flow = c:flow(56, c.H - 8, self.page)
    local list = feed and feed.onthisday or {}
    for i, e in ipairs(list) do self:eventRow(c, flow, e, lang, i < #list) end
    self.pages = flow:pages()
end

-- ------------------------------------------------------------------ Saved

function Home:savedRow(c, flow, a)
    flow:block(68, function(y)
        local sel = self.selected
        if sel then
            local on = sel[a.path]
            c:box(16, y + 18, 22, 22, { r = 4, fill = on and C.FILL or nil, border = C.BLACK, bw = 1.4 })
            if on then c:icon("check", 18, y + 20, 18, true) end
        else
            c:icon("bookmark-check", 16, y + 16, 20)
        end
        local right = M.dayLabel(a.time)
        right = right == "Today" and _("Today") or right == "Yesterday" and _("Yesterday") or right
        local rw = math.max(c:width(right, 12), c:width(M.sizeLabel(a.size), 12)) + 12
        c:text(48, y + 30, a.title, 16.5, { bold = true, maxw = c.W - 64 - rw })
        if a.description then c:text(48, y + 51, a.description, 12.5, { color = C.GREY, maxw = c.W - 64 - rw }) end
        c:text(c.W - 16, y + 30, right, 12, { color = C.GREY, align = "end" })
        c:text(c.W - 16, y + 51, M.sizeLabel(a.size), 12, { color = C.GREY, align = "end" })
        c:hline(16, y + 67, c.W - 32, C.LINE)
        c:hit(0, y, c.W, 68, function()
            if self.selected then
                self.selected[a.path] = not self.selected[a.path] or nil
                self:refresh()
            else
                self.wiki:openFile(a.path, { from = "home" })
            end
        end, function()
            if not self.selected then self:savedMenu(a) end
        end)
    end)
end

function Home:drawSaved(c, top)
    local list = self.savedList
    local bottom = c.H - 90
    local flow = c:flow(top, bottom, self.page)
    if #list == 0 then
        flow:block(120, function(y)
            c:para(32, y + 40, _("No saved articles yet. Tap Save on an article to keep it on this Kindle; saved articles open without Wi-Fi."),
                14, c.W - 64, 21, { color = C.GREY })
        end)
        self.pages = flow:pages()
        return
    end
    flow:block(24, function(y)
        local info = T(N_("1 article", "%1 articles", #list), #list) .. " · " .. M.sizeLabel(self.store:savedSize(list)) .. " · " .. _("on this Kindle")
        c:text(16, y + 10, info, 12.5, { color = C.GREY })
        local sort = self.store:read("saved_sort") == "title" and _("By title") or _("Newest first")
        c:text(c.W - 16, y + 10, sort .. " ▾", 12.5, { bold = true, align = "end" })
        c:hit(c.W - 160, y - 10, 160, 36, function()
            self.store:write("saved_sort", self.store:read("saved_sort") == "title" and "newest" or "title")
            self:refresh()
        end)
    end)
    for __, a in ipairs(list) do self:savedRow(c, flow, a) end
    if flow:pages() == 1 then
        flow:block(60, function(y)
            c:text(c.W / 2, y + 30, _("Saved articles open without Wi-Fi."), 12.5, { color = C.GREY, align = "middle" })
            c:text(c.W / 2, y + 50, _("They are EPUBs in the Wikipedia folder, so they also show in the Library."), 12.5,
                { color = C.GREY, align = "middle", maxw = c.W - 32 })
        end)
    end
    self.pages = flow:pages()
    -- Select (several to remove at once)
    local y = c.H - 84
    if self.selected then
        local n = 0
        for __ in pairs(self.selected) do n = n + 1 end
        Bar.iconButtons(c, 0, y, c.W, {
            { icon = "x", text = _("Cancel"), fn = function() self.selected = nil; self:refresh() end },
            { icon = "trash-2", text = n > 0 and T(_("Remove (%1)"), n) or _("Remove"), primary = true, enabled = n > 0,
                fn = function() self:removeSelected() end },
        }, function(b) b.fn() end)
    elseif #list > 0 then
        Bar.iconButtons(c, 0, y, c.W, { { icon = "square-check", text = _("Select") } }, function()
            self.selected = {}
            self:refresh()
        end)
    end
end

function Home:savedMenu(a)
    local items = {
        { text = _("Open"), fn = function() self.wiki:openFile(a.path, { from = "home" }) end },
        { text = _("Update"), fn = function() self.wiki:updateArticle(a.path, function() self:refresh() end) end },
    }
    if self.wiki:webPage() then
        table.insert(items, { text = _("Open on the web page"), fn = function() self.wiki:webPage():openOnWeb("wikipedia") end })
    end
    table.insert(items, { text = _("Remove"), danger = true, fn = function() self:remove({ a.path }) end })
    Bar.list(a.title, items)
end

--- Removed at once with Undo (Apps); without Apps, asked first.
function Home:remove(paths)
    local function go()
        local done = {}
        for __, p in ipairs(paths) do
            if self.wiki:removeSaved(p, true) then table.insert(done, p) end
        end
        self.selected = nil
        self:refresh()
        if #done == 0 then return end
        Bar.undo(#done == 1 and _("Article removed") or T(_("%1 articles removed"), #done), function()
            for __, p in ipairs(done) do self.wiki:restoreSaved(p) end
            self:refresh()
        end)
    end
    if Bar.canUndo() then return go() end
    Bar.confirm{
        text = #paths == 1 and _("Remove this article from the Kindle?")
            or T(_("Remove %1 articles from the Kindle?"), #paths),
        ok = _("Remove"),
        cancel = _("Cancel"),
        danger = true,
        onOk = go,
    }
end

function Home:removeSelected()
    local paths = {}
    for p in pairs(self.selected or {}) do table.insert(paths, p) end
    self:remove(paths)
end

-- ------------------------------------------------------------------ Recent

local function clock(t)
    if G_reader_settings:isTrue("twelve_hour_clock") then
        return (os.date("%I:%M %p", t):gsub("^0", ""))
    end
    return os.date("%H:%M", t)
end

function Home:drawRecent(c, top)
    local list = self.store:recent()
    local flow = c:flow(top, c.H - 90, self.page)
    if #list == 0 then
        flow:block(100, function(y)
            c:para(32, y + 40, _("Articles you open show here."), 14, c.W - 64, 21, { color = C.GREY })
        end)
        self.pages = flow:pages()
        return
    end
    local day
    for __, e in ipairs(list) do
        local d = M.dayLabel(e.time)
        if d ~= day then
            day = d
            local label = d == "Today" and _("Today") or d == "Yesterday" and _("Yesterday") or d
            flow:block(26, function(y) c:text(16, y + 18, label, 13, { bold = true, color = C.GREY }) end, 58)
        end
        local path = self.store:find(e.title, e.lang)
        local saved = path and self.store:findSaved(e.title, e.lang)
        local where
        local pg, pages = self.store:progress(path)
        if pg then where = T(_("Page %1 of %2"), pg, pages) end
        if e.lang ~= self.store:lang() then where = (where and where .. " · " or "") .. M.languageName(e.lang) end
        flow:block(58, function(y)
            c:text(16, y + 26, e.title, 16, { bold = true, maxw = c.W - 110 })
            if where then c:text(16, y + 46, where, 12.5, { color = C.GREY, maxw = c.W - 110 }) end
            c:text(c.W - 16, y + 26, clock(e.time), 12, { color = C.GREY, align = "end" })
            if saved then c:icon("bookmark-check", c.W - 34, y + 33, 18) end
            c:hline(16, y + 57, c.W - 32, C.LINE)
            c:hit(0, y, c.W, 58, function()
                self.wiki:openArticle(e.title, e.lang, { from = "home" })
            end, function()
                Bar.list(e.title, { { text = _("Remove from Recent"), fn = function()
                    self.store:removeRecent(e.title, e.lang)
                    self:refresh()
                end } })
            end)
        end)
    end
    self.pages = flow:pages()
    if #list > 0 then
        Bar.iconButtons(c, 0, c.H - 84, c.W, { { icon = "trash-2", text = _("Clear recent") } }, function()
            self:confirmClearRecent()
        end)
    end
end

function Home:confirmClearRecent()
    Bar.confirm{
        text = _("Clear the list of recent articles?"),
        ok = _("Clear"),
        cancel = _("Cancel"),
        onOk = function()
            self.store:clearRecent()
            self:refresh()
        end,
    }
end

-- ------------------------------------------------------------------ search

function Home:askSearch(text)
    Bar.ask{ title = _("Search Wikipedia"), text = text or self.query or "", hint = _("Words to look for"),
        ok = _("Search"), okIcon = "search", needsText = true, done = function(q) self:search(q) end }
end

function Home:search(q)
    local lang = self.store:lang()
    self.wiki:online(function()
        self.wiki:fetch(_("Searching…"), function() return require("wikiapi").search(lang, q) end, function(results)
            self.query, self.results = q, results
            if self.tab == "search" then
                self.page = 1
                self:refresh(true)
            else
                self:go("search")
            end
        end)
    end)
end

function Home:drawSearch(c)
    self:header(c, _("Wikipedia"), true)
    self:searchBar(c, 56, self.query)
    local results = self.results or {}
    local flow = c:flow(112, c.H - 8, self.page)
    flow:block(20, function(y)
        c:text(16, y + 8, T(_("Results for “%1”"), self.query or ""), 12.5, { color = C.GREY, maxw = c.W - 32 })
    end)
    if #results == 0 then
        flow:block(60, function(y) c:text(16, y + 36, _("No articles found."), 14, { color = C.GREY }) end)
    end
    local lang = self.store:lang()
    for __, r in ipairs(results) do
        flow:block(58, function(y)
            c:text(16, y + 24, r.title, 16, { bold = true, maxw = c.W - 70 })
            if r.description then c:text(16, y + 44, r.description, 12.5, { color = C.GREY, maxw = c.W - 70 }) end
            c:icon("chevron-right", c.W - 34, y + 20, 18)
            c:hline(16, y + 57, c.W - 32, C.LINE)
            c:hit(0, y, c.W, 58, function() self.wiki:openArticle(r.title, lang, { from = "home" }) end, function()
                Bar.list(r.title, {
                    { text = _("Open"), fn = function() self.wiki:openArticle(r.title, lang, { from = "home" }) end },
                    { text = _("Copy"), fn = function() Bar.copy(r.title .. (r.description and ("\n" .. r.description) or "")) end },
                })
            end)
        end)
    end
    self.pages = flow:pages()
end

-- ------------------------------------------------------------------ language

function Home:pickLanguage(done)
    self.wiki:pickLanguage(function()
        self.results = nil
        if self.tab == "search" then self.tab, self.history = "today", {} end
        self:refresh(true)
        if done then done() end
    end)
end

-- ------------------------------------------------------------------ settings

-- An on/off switch (40 by 22): black with the knob at the right when on.
local function switch(c, x, y, on)
    c:box(x, y, 40, 22, { r = 11, fill = on and C.FILL or nil, border = C.BLACK, bw = 1.3 })
    c:circle(on and x + 29 or x + 11, y + 11, 7, on and C.WHITE or C.BLACK)
end

--- A choice: the options, ✓ before the current one (the shared pop-up).
local choose = Bar.choose

-- The end of a folder's path when all of it doesn't fit: "…/documents/Wikipedia".
local function shortPath(c, path, maxw)
    if c:width(path, 11) <= maxw then return path end
    local tail = path:match("([^/]+/[^/]+)$") or path:match("([^/]+)$") or path
    return "…/" .. tail
end

--- The settings' rows by name, for the launcher's search (headings left out; in
-- step with drawSettings, whose rows say which page they're on).
function Home.settingRows()
    local out = {}
    for __, name in ipairs({ _("Toolbar"), _("Images"), _("Language"), _("Tap a link"), _("Save to"),
        _("Today's featured article"), _("On this day"), _("In the news"), _("Most read yesterday"),
        _("Keep recent"), _("Clear recent"), _("Show in recent books") }) do
        table.insert(out, { name })
    end
    return out
end

function Home:drawSettings(c)
    local s = self.store
    self:header(c, _("Wikipedia settings"))
    local F = c:flow(56, c.H - 8, self.page)
    self.rowPages = {}
    local function head(name)
        F:gap(10)
        F:block(24, function(y) c:text(14, y + 16, name, 9.5, { bold = true, color = C.GREY }) end, 36)
    end
    local function row(name, value, fn)
        F:block(36, function(y)
            c:text(14, y + 23, name, 12, { maxw = 330 })
            if type(value) == "boolean" then
                switch(c, c.W - 54, y + 7, value)
            else
                c:text(c.W - 32, y + 23, value or "", 11, { align = "end", color = C.GREY, maxw = 250 })
                c:icon("chevron-right", c.W - 26, y + 12, 12)
            end
            c:hline(14, y + 35, c.W - 14, C.LINE)
            c:hit(0, y, c.W, 36, fn)
        end)
        self.rowPages[name] = F.page
    end
    local function saved() self:refresh() end

    head(_("DISPLAY"))
    local side = s:read("toolbar") == "top" and "top" or "left"
    local sides = { { value = "left", label = _("Left") }, { value = "top", label = _("Top") } }
    row(_("Toolbar"), side == "top" and _("Top") or _("Left"), function()
        choose(_("Toolbar"), sides, side, function(v) self.wiki:setToolbar(v); saved() end)
    end)
    row(_("Images"), s:read("images") == true, function() s:write("images", not s:read("images")); saved() end)

    head(_("ARTICLES"))
    row(_("Language"), M.languageName(s:lang()), function() self:pickLanguage() end)
    local tap = s:read("link_tap") == "open" and "open" or "preview"
    local taps = { { value = "preview", label = _("Preview") }, { value = "open", label = _("Open") } }
    row(_("Tap a link"), tap == "open" and _("Open") or _("Preview"), function()
        choose(_("Tap a link"), taps, tap, function(v) s:write("link_tap", v); saved() end)
    end)
    row(_("Save to"), shortPath(c, s:folder(), 250), function() self:pickFolder() end)

    head(_("FRONT PAGE"))
    local sections = s:read("sections")
    for __, it in ipairs({ { "featured", _("Today's featured article") }, { "onthisday", _("On this day") },
        { "news", _("In the news") }, { "mostread", _("Most read yesterday") } }) do
        row(it[2], sections[it[1]] == true, function()
            sections[it[1]] = not sections[it[1]]
            s:write("sections", sections)
            saved()
        end)
    end

    head(_("RECENT"))
    local keep = s:read("keep_recent")
    local keeps = {}
    for __, n in ipairs({ 25, 50, 100, 200 }) do table.insert(keeps, { value = n, label = T(_("%1 articles"), n) }) end
    row(_("Keep recent"), T(_("%1 articles"), keep), function()
        choose(_("Keep recent"), keeps, keep, function(v) s:write("keep_recent", v); saved() end)
    end)
    row(_("Clear recent"), "", function() self:confirmClearRecent() end)
    row(_("Show in recent books"), s:read("in_history") ~= false, function()
        s:write("in_history", s:read("in_history") == false)
        self.wiki:tidyHistory()
        saved()
    end)
    self.pages = F:pages()
end

-- ------------------------------------------------------------------ a list to pick from

--- A full-screen list (the language, another language's article): Wikipedia:showPick.
function Home:showPick(title, items)
    self.pick = { title = title, items = items }
    self:go("pick")
end

function Home:drawPick(c)
    local p = self.pick or { items = {} }
    self:header(c, p.title)
    local flow = c:flow(56, c.H - 8, self.page)
    for __, it in ipairs(p.items) do
        flow:block(48, function(y)
            if it.current then c:icon("check", 16, y + 15, 18) end
            c:text(46, y + 30, it.text, 14, { bold = it.current, maxw = c.W - 46 - (it.right and 270 or 16) })
            if it.right then c:text(c.W - 16, y + 30, it.right, 12, { color = C.GREY, align = "end", maxw = 250 }) end
            c:hline(16, y + 47, c.W - 32, C.LINE)
            c:hit(0, y, c.W, 48, function()
                self:back()
                if it.fn then it.fn() end
            end)
        end)
    end
    self.pages = flow:pages()
end

-- ------------------------------------------------------------------ Save to: a folder

function Home:pickFolder()
    local lfs = require("libs/libkoreader-lfs")
    local start = self.store:folder()
    if lfs.attributes(start, "mode") ~= "directory" then start = start:match("^(.+)/[^/]*$") or "/" end
    self.folderPath = start
    self:go("folder")
end

function Home:drawFolder(c)
    local lfs = require("libs/libkoreader-lfs")
    local path = self.folderPath or "/"
    self:header(c, _("Save to"))
    local flow = c:flow(56, c.H - 90, self.page)
    flow:block(46, function(y)
        c:icon("folder", 16, y + 14, 18)
        c:text(46, y + 29, shortPath(c, path, c.W - 62), 12.5, { bold = true })
        c:hline(0, y + 45, c.W, C.BLACK, 1)
    end)
    local function row(icon, name, target)
        flow:block(48, function(y)
            c:icon(icon, 16, y + 15, 18)
            c:text(46, y + 30, name, 14, { maxw = c.W - 62 })
            c:hline(16, y + 47, c.W - 32, C.LINE)
            c:hit(0, y, c.W, 48, function()
                self.folderPath, self.page = target, 1
                self:refresh()
            end)
        end)
    end
    local parent = path:match("^(.+)/[^/]+$") or (path ~= "/" and "/" or nil)
    if parent then row("arrow-up", _("Up a folder"), parent) end
    local names = {}
    pcall(function()
        for name in lfs.dir(path) do
            if not name:match("^%.") and not name:match("%.sdr$")
                    and lfs.attributes(path .. "/" .. name, "mode") == "directory" then
                table.insert(names, name)
            end
        end
    end)
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    local base = path == "/" and "" or path
    for __, name in ipairs(names) do row("folder", name, base .. "/" .. name) end
    self.pages = flow:pages()
    Bar.iconButtons(c, 0, c.H - 84, c.W, {
        { icon = "x", text = _("Cancel"), fn = function() self:back() end },
        { icon = "check", text = _("Use this folder"), primary = true, fn = function()
            self.store:write("folder", path)
            self:back()
        end },
    }, function(b) b.fn() end)
end

return Home
