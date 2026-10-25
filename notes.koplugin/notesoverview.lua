--[[--
All the pages of a notebook as thumbnails: tap one to go to it, hold one
to bookmark, copy, move or delete it. "Bookmarked" shows only bookmarked
pages. "Select" picks several, to do one thing to them all (bookmark,
move, copy or move to another notebook, delete; in a puzzle book mark
done, hide, clear).

In a puzzle book it is the puzzle list: each page Done (marked so),
Started (written on) or not, shown by All, Not started, Started, Done and
Hidden; hold a page to mark it done, clear its writing or hide it.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local KO = require("notesko")
local T = require("ffi/util").template

local Crossword = require("notescrossword")
local Settings = require("notessettings")
local UI = require("notesui")
local Store = require("notesstore")

local Screen = Device.screen

local Overview = InputContainer:extend{
    editor = nil,
    covers_fullscreen = true,
}

function Overview:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ui = UI.new()
    self.starredOnly = false
    self.puzzle = self.editor.notebook.puzzle
    self.feed = self.editor.notebook.feed   -- crosswords fetched: listed by their day
    self.filter = "all"
    self.cols = (self.w > self.h or self.puzzle) and 4 or 3
    self.rows = self.w > self.h and 2 or 3
    -- Opened at the current page.
    local at = 1
    for k, i in ipairs(self:pages()) do
        if i <= self.editor.page then at = k end
    end
    self.first = math.floor((at - 1) / (self.cols * self.rows)) * self.cols * self.rows + 1
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        OverviewTap = { GestureRange:new{ ges = "tap", range = all } },
        OverviewHold = { GestureRange:new{ ges = "hold", range = all } },
        OverviewSwipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    self.hits = {}
    self.selected = nil   -- while selecting: { [page index] = true }
end

-- A puzzle book's page: "done", "started" (written on) or "new".
function Overview.status(page)
    if page.done then return "done" end
    if #page.strokes > 0 then return "started" end
    return "new"
end

-- The status of page i: a crossword's over all its pages.
function Overview:statusOf(i)
    local nb = self.editor.notebook
    local key = self.feed and Crossword.keyPart(nb.pages[i])
    if key then return Crossword.state(nb, key) end
    return Overview.status(nb.pages[i])
end

function Overview:pages(filter)
    local out = {}
    filter = filter or self.filter
    local landscape = self.editor.w > self.editor.h
    for i, page in ipairs(self.editor.notebook.pages) do
        local show
        if self.puzzle then
            if filter == "hidden" then show = page.hide
            else show = not page.hide and (filter == "all" or self:statusOf(i) == filter) end
        else
            show = not self.starredOnly or page.star
        end
        -- A crossword fetched: listed once, by its first page (its clues'
        -- next page left out; its answers page is under Hidden), the pages
        -- laid out for this orientation.
        if show and self.feed and page.pz and not page.hide and not page.pz:match(":L?1$") then show = false end
        if show and self.feed and not Crossword.inView(page, landscape) then show = false end
        if show then table.insert(out, i) end
    end
    if self.feed then
        -- Newest first (or oldest first), a puzzle's pages together.
        local oldest = Settings.get("crossword_oldest_first")
        local pages = self.editor.notebook.pages
        local function day(i) return Crossword.dayOfPage(pages[i]) or 0 end
        table.sort(out, function(a, b)
            local da, db = day(a), day(b)
            if da ~= db then
                if oldest then return da < db end
                return da > db
            end
            return a < b
        end)
    end
    return out
end

-- Today, as days since 1970 (for crosswords' dates).
function Overview:today()
    local t = os.date("*t")
    return Crossword.daysFrom(t.year, t.month, t.day)
end

--- The newest puzzle not started yet (a crossword book), or the next one
-- after the current page (another puzzle book): its page, or nil.
function Overview:nextUnstarted()
    local pages = self.editor.notebook.pages
    local landscape = self.editor.w > self.editor.h
    local function fresh(i)
        local page = pages[i]
        return not page.hide and self:statusOf(i) == "new" and (not page.pz or page.pz:match(":L?1$"))
            and (not self.feed or Crossword.inView(page, landscape))
    end
    if self.feed then
        local best, bestDay
        for i in ipairs(pages) do
            local d = Crossword.dayOfPage(pages[i]) or 0
            if fresh(i) and (not best or d > bestDay) then best, bestDay = i, d end
        end
        return best
    end
    local n = #pages
    for k = 1, n do
        local i = (self.editor.page + k - 1) % n + 1
        if fresh(i) then return i end
    end
end

function Overview:hit(x, y, w, h, tap, hold)
    table.insert(self.hits, { x, y, w, h, tap, hold })
end

function Overview:find(ges)
    if not ges or not ges.pos then return nil end
    local x, y = ges.pos.x, ges.pos.y
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if x >= h[1] and x < h[1] + h[3] and y >= h[2] and y < h[2] + h[4] then return h end
    end
end

function Overview:onOverviewTap(_arg, ges)
    local h = self:find(ges)
    if h and h[5] then h[5]() end
    return true
end

function Overview:onOverviewHold(_arg, ges)
    local h = self:find(ges)
    -- (A button with no hold of its own: its tap, as a firm pen press is a hold.)
    local fn = h and (h[6] or h[5])
    if fn then fn() end
    return true
end

function Overview:onOverviewSwipe(_arg, ges)
    if ges.direction == "west" then self:turn(1) elseif ges.direction == "east" then self:turn(-1) end
    return true
end

function Overview:turn(dir)
    local per = self.cols * self.rows
    local n = #self:pages()
    local first = self.first + dir * per
    if first < 1 or first > n then return end
    self.first = first
    self:redraw()
end

function Overview:redraw()
    UIManager:setDirty(self, "ui")
end

function Overview:paintTo(bb, x, y)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    self.hits = {}
    bb:paintRect(x, y, self.w, self.h, Blitbuffer.COLOR_WHITE)
    local list = self:pages()
    local n = #list
    if self.first > math.max(1, n) then self.first = 1 end
    -- Title bar.
    local bar = u(44)
    if self.selected then
        bar = self:paintSelectBar(bb)
    elseif self.puzzle then
        bar = self:paintPuzzleBar(bb)
    else
        -- The apps' title bar: ‹ back to the page, ⌂, Recent apps, the
        -- title; its own buttons: Bookmarked (only those), Select, the pages
        -- deleted (when there are some, with how many); the clock, the bell.
        local ed = self.editor
        local nDel = ed.notebook.deleted and #ed.notebook.deleted or 0
        local buttons = {
            { "star", function()
                self.starredOnly = not self.starredOnly
                self.first = 1
                self:redraw()
            end },
            { "list-checks", function()
                self.selected = {}
                self:redraw()
            end },
        }
        if nDel > 0 then table.insert(buttons, { "trash-2", function() self:showDeleted() end, nDel }) end
        local title = self.starredOnly and T(_("Bookmarked · %1"), n) or T(_("%1 · %2 pages"), ed.notebook.name or "", n)
        local hits
        hits, bar = require("notestitle").draw(ui, bb, self.w, {
            title = title,
            back = function() UIManager:close(self) end,
            home = (ed.on_home and not ed.quick) and function()
                UIManager:close(self)
                ed:goHome()
            end or nil,
            buttons = buttons,
            status = true,
            bell = KO.bell(), bellCount = KO.bell() and KO.bellCount() or nil,
        })
        for __, h in ipairs(hits) do self:hit(h[1], h[2], h[3], h[4], h[5]) end
    end
    -- The grid.
    local foot = u(44)
    local pad = u(12)
    local cellW = math.floor((self.w - pad) / self.cols)
    local cellH = math.floor((self.h - bar - foot - pad) / self.rows)
    local ed = self.editor
    local ratio = ed.h / ed.w
    local tw = cellW - pad
    local th = math.floor(tw * ratio)
    -- Puzzles: two lines under each (its name, then how it stands).
    local under = self.puzzle and u(36) or u(24)
    if th > cellH - under then
        th = cellH - under
        tw = math.floor(th / ratio)
    end
    if n == 0 then
        local empty = self.puzzle and ({ all = _("Every page is hidden."), new = _("No puzzles left to start."),
            started = _("No puzzles started."), done = _("No puzzles done yet."),
            hidden = _("No hidden pages.") })[self.filter] or _("No bookmarked pages. Hold a page to bookmark it.")
        ui:drawText(bb, empty, math.floor(self.w / 2), math.floor(self.h / 2), 11, { align = "center" })
    end
    local per = self.cols * self.rows
    for k = 0, per - 1 do
        local i = list[self.first + k]
        if not i then break end
        local col, row = k % self.cols, math.floor(k / self.cols)
        local tx = pad + col * cellW + math.floor((cellW - pad - tw) / 2)
        local ty = bar + pad + row * cellH
        local thumb = ed:thumbnail(i, tw, th)
        if thumb then bb:blitFrom(thumb, tx, ty, 0, 0, thumb:getWidth(), thumb:getHeight()) end
        local current = i == ed.page
        bb:paintBorder(tx, ty, tw, th, current and math.max(4, u(2)) or 1, current and UI.BLACK or UI.MID)
        local page = ed.notebook.pages[i]
        if self.puzzle then
            local st = self:statusOf(i)
            local r = u(11)
            local cx, cy = tx + tw - r - u(4), ty + r + u(4)
            if st == "done" then
                bb:paintCircle(cx, cy, r, UI.BLACK)
                ui:drawIcon(bb, "check", cx - u(7), cy - u(7), u(14), true)
            elseif st == "started" then
                bb:paintCircle(cx, cy, r, UI.WHITE)
                bb:paintCircle(cx, cy, r, UI.BLACK, math.max(2, u(1)))
                ui:drawIcon(bb, "pen", cx - u(6), cy - u(6), u(12))
            end
            -- A crossword fetched: its day ("Wed 21 Oct", "Quick · Wed 21 Oct",
            -- "… · answers"); then how it stands, and its time.
            local name = Crossword.pageLabel(page, self:today()) or T(_("Page %1"), i)
            local first = ed:puzzleFirst(i)
            local secs = first and first.secs
            local how = ({ done = _("Done"), started = _("Started") })[st] or _("Not started")
            if secs and secs >= 60 and st ~= "new" then
                how = st == "done" and T(_("Done · %1"), Crossword.duration(secs)) or T(_("Started · %1 so far"), Crossword.duration(secs))
            end
            -- Clue boxes ticked: how many of how many.
            local ticked = 0
            for __ in pairs(first and first.ticks or {}) do ticked = ticked + 1 end
            if st == "started" and ticked > 0 and first.nclues then
                how = T(_("%1 of %2 clues"), ticked, first.nclues) .. (secs and secs >= 60 and (" · " .. Crossword.duration(secs)) or "")
            end
            local hints = first and first.hints
            if hints and st ~= "new" then how = how .. " · " .. (hints == 1 and _("1 hint") or T(_("%1 hints"), hints)) end
            ui:drawText(bb, name, tx + math.floor(tw / 2), ty + th + u(11), 9.5, { align = "center", bold = current or st ~= "new" })
            ui:drawText(bb, how, tx + math.floor(tw / 2), ty + th + u(25), 9, { align = "center", color = UI.GREY_TEXT })
        else
            ui:drawText(bb, (page.star and "★ " or "") .. tostring(i), tx + math.floor(tw / 2), ty + th + u(11), 10,
                { align = "center", bold = current })
        end
        if self.selected then
            local on = self.selected[i]
            local r = u(11)
            local cx, cy = tx + r + u(4), ty + r + u(4)
            bb:paintCircle(cx, cy, r, on and UI.BLACK or UI.WHITE)
            bb:paintCircle(cx, cy, r, UI.BLACK, math.max(2, u(1)))
            if on then ui:drawIcon(bb, "check", cx - u(7), cy - u(7), u(14), true) end
            self:hit(tx, ty, tw, th + u(22), function()
                self.selected[i] = not on or nil
                self:redraw()
            end)
        else
            self:hit(tx, ty, tw, th + under - u(2), function()
                UIManager:close(self)
                ed:goPage(i)
            end, function() if self.puzzle then self:puzzleActions(i) else self:pageActions(i) end end)
        end
    end
    -- Paging and adding a page.
    local fy = self.h - foot
    bb:paintRect(0, fy, self.w, 1, UI.MID)
    local pagesOf = math.max(1, math.ceil(n / per))
    local at = math.floor((self.first - 1) / per) + 1
    ui:drawText(bb, T(_("%1 of %2"), at, pagesOf), math.floor(self.w / 2), fy + math.floor(foot / 2), 11, { align = "center" })
    ui:drawIcon(bb, "chevron-left", u(60), fy + u(13), u(18), false, at <= 1)
    ui:drawIcon(bb, "chevron-right", self.w - u(78), fy + u(13), u(18), false, at >= pagesOf)
    self:hit(u(30), fy, u(80), foot, function() self:turn(-1) end)
    self:hit(self.w - u(110), fy, u(80), foot, function() self:turn(1) end)
    if self.puzzle or self.selected then return end
    ui:drawIcon(bb, "file-plus", u(14), fy + u(13), u(18))
    self:hit(0, fy, u(46), foot, function()
        ed:addPageAt(#ed.notebook.pages + 1)
        self.first = math.floor((#ed.notebook.pages - 1) / per) * per + 1
        self:redraw()
    end)
end

-- The puzzle list's title bar: the apps' bar (‹ back to the puzzle, ⌂,
-- Recent apps, the book's name; Stats and Select; the clock, the bell),
-- then a row with Next unstarted and the order, and a row of filters with
-- their counts. Returns its height.
function Overview:paintPuzzleBar(bb)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    local ed = self.editor
    local buttons = {}
    -- Days in a row, done this week and month, times by source.
    if self.feed and ed.on_stats then table.insert(buttons, { "chart-column", function() ed.on_stats() end }) end
    table.insert(buttons, { "list-checks", function()
        self.selected = {}
        self:redraw()
    end })
    local hits, top = require("notestitle").draw(ui, bb, self.w, {
        title = ed.notebook.name or "",
        back = function() UIManager:close(self) end,
        home = (ed.on_home and not ed.quick) and function()
            UIManager:close(self)
            ed:goHome()
        end or nil,
        buttons = buttons,
        status = true,
        bell = KO.bell(), bellCount = KO.bell() and KO.bellCount() or nil,
    })
    for __, hh in ipairs(hits) do self:hit(hh[1], hh[2], hh[3], hh[4], hh[5]) end
    -- Next unstarted, and (crosswords fetched) the order.
    local h = u(26)
    local x, y = u(12), top + u(9)
    local function chip(label, dark, fn)
        local w = ui:textWidth(label, 10, dark) + u(24)
        ui:box(bb, x, y, w, h, { fill = dark and UI.BLACK or UI.WHITE, border = UI.BLACK, r = u(13) })
        ui:drawText(bb, label, x + math.floor(w / 2), y + math.floor(h / 2), 10,
            { align = "center", bold = dark, color = dark and UI.WHITE or UI.BLACK })
        self:hit(x, top, w, h + u(18), fn)
        x = x + w + u(8)
    end
    chip(_("Next unstarted"), true, function()
        local i = self:nextUnstarted()
        if not i then
            KO.message(_("Every puzzle has been started."))
            return
        end
        UIManager:close(self)
        ed:goPage(i)
    end)
    if self.feed then
        local oldest = Settings.get("crossword_oldest_first")
        chip(oldest and _("Oldest first") or _("Newest first"), false, function()
            Settings.set("crossword_oldest_first", not oldest or nil)
            self.first = 1
            self:redraw()
        end)
    end
    top = top + h + u(18)
    bb:paintRect(0, top, self.w, 1, UI.MID)
    local chips = {
        { "all", _("All") }, { "new", _("Not started") }, { "started", _("Started") }, { "done", _("Done") },
    }
    if #self:pages("hidden") > 0 then table.insert(chips, { "hidden", _("Hidden") }) end
    x, y = u(12), top + u(9)
    for __, c in ipairs(chips) do
        local on = self.filter == c[1]
        local label = T("%1 (%2)", c[2], #self:pages(c[1]))
        local w = ui:textWidth(label, 10, on) + u(22)
        ui:box(bb, x, y, w, h, { fill = on and UI.BLACK or UI.WHITE, border = UI.BLACK, r = u(13) })
        ui:drawText(bb, label, x + math.floor(w / 2), y + math.floor(h / 2), 10,
            { align = "center", bold = on, color = on and UI.WHITE or UI.BLACK })
        self:hit(x, top, w, h + u(18), function()
            self.filter = c[1]
            self.first = 1
            self:redraw()
        end)
        x = x + w + u(8)
    end
    local bar = top + h + u(18)
    bb:paintRect(0, bar, self.w, 2, UI.BLACK)
    return bar
end

-- The "Select" chip, ending at x.
function Overview:selectChip(bb, right)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    local w = ui:textWidth(_("Select"), 10) + u(26)
    local x = right - w
    ui:box(bb, x, u(9), w, u(26), { fill = UI.WHITE, border = UI.BLACK, r = u(13) })
    ui:drawText(bb, _("Select"), x + math.floor(w / 2), u(22), 10, { align = "center" })
    self:hit(x, 0, w, u(44), function()
        self.selected = {}
        self:redraw()
    end)
    return x
end

-- "Deleted (n)": the pages deleted in the last 30 days, to restore.
function Overview:deletedChip(bb, right)
    local ed = self.editor
    local n = ed.notebook.deleted and #ed.notebook.deleted or 0
    if n == 0 then return right end
    local ui = self.ui
    local u = function(k) return ui:u(k) end
    local label = T(_("Deleted (%1)"), n)
    local w = ui:textWidth(label, 10) + u(26)
    local x = right - w
    ui:box(bb, x, u(9), w, u(26), { fill = UI.WHITE, border = UI.BLACK, r = u(13) })
    ui:drawText(bb, label, x + math.floor(w / 2), u(22), 10, { align = "center" })
    self:hit(x, 0, w, u(44), function() self:showDeleted() end)
    return x
end

function Overview:showDeleted()
    local ed = self.editor
    local list = ed.notebook.deleted or {}
    local dialog
    local buttons = {}
    for k = #list, 1, -1 do
        local d = list[k]
        local blank = #(d.page.strokes or {}) == 0 and not (d.page.items and #d.page.items > 0)
        table.insert(buttons, { { text = T(_("Page %1 · deleted %2"), d.index, os.date("%b %d", d.at))
                .. (blank and (" · " .. _("blank")) or ""), align = "left", callback = function()
            UIManager:close(dialog)
            local again
            again = KO.buttonDialog{
                title = T(_("Page %1 · deleted %2"), d.index, os.date("%b %d", d.at)),
                title_align = "center",
                buttons = {
                    { { text = _("Restore"), callback = function()
                        UIManager:close(again)
                        local at = ed:restoreDeleted(k)
                        if at then
                            local per = self.cols * self.rows
                            self.first = math.floor((at - 1) / per) * per + 1
                            require("notesko").toast(T(_("Restored as page %1"), at))
                        end
                        self:redraw()
                    end } },
                    { { text = _("Delete permanently"), callback = function()
                        UIManager:close(again)
                        ed:purgeDeleted(k)
                        self:redraw()
                    end } },
                    { { text = _("Cancel"), callback = function() UIManager:close(again) end } },
                },
            }
        end } })
    end
    table.insert(buttons, { { text = _("Empty"), callback = function()
        UIManager:close(dialog)
        self:confirm(T(_("Permanently delete the %1 deleted pages? This can't be undone."), #list), _("Delete"), function()
            ed:purgeDeleted(nil)
            self:redraw()
        end)
    end }, { text = _("Close"), callback = function() UIManager:close(dialog) end } })
    dialog = KO.buttonDialog{ title = _("Deleted pages (kept 30 days)"), title_align = "center", buttons = buttons }
end

function Overview:selectedList()
    local out = {}
    for i in pairs(self.selected or {}) do table.insert(out, i) end
    table.sort(out)
    return out
end

-- While selecting: how many, What to do… and Done. Returns its height.
function Overview:paintSelectBar(bb)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    local bar = u(44)
    local n = #self:selectedList()
    ui:drawText(bb, n == 1 and _("1 page selected") or T(_("%1 pages selected"), n), u(14), math.floor(bar / 2), 13, { bold = true })
    local x = self.w - u(12)
    for __, b in ipairs({ { _("Done"), function()
        self.selected = nil
        self:redraw()
    end, false }, { _("What to do…"), function() self:bulkActions() end, true } }) do
        local w = ui:textWidth(b[1], 10, b[3]) + u(26)
        x = x - w
        ui:box(bb, x, u(9), w, u(26), { fill = b[3] and UI.BLACK or UI.WHITE, border = UI.BLACK, r = u(13) })
        ui:drawText(bb, b[1], x + math.floor(w / 2), u(22), 10, { align = "center", bold = b[3], color = b[3] and UI.WHITE or UI.BLACK })
        self:hit(x, 0, w, bar, b[2])
        x = x - u(8)
    end
    bb:paintRect(0, bar, self.w, 2, UI.BLACK)
    return bar
end

-- A copy of a page for another notebook (a new id; a PDF page's background
-- stays behind, it belongs to this notebook's PDF).
local function copyOf(page)
    local text = Store.serialize({ id = "x", name = "x", pages = { page } })
    local nb = Store.parse(text)
    local copy = nb and nb.pages[1]
    if not copy then return nil end
    copy.id = Store.newPageId()
    copy.bg = nil
    return copy
end

-- What to do to the pages selected.
function Overview:bulkActions()
    local ed = self.editor
    local pages = ed.notebook.pages
    local list = self:selectedList()
    local dialog
    local function act(fn) return function()
        UIManager:close(dialog)
        fn()
        self:redraw()
    end end
    local function all(field)
        for __, i in ipairs(list) do
            if not pages[i][field] then return false end
        end
        return #list > 0
    end
    local any = #list > 0
    local buttons = {}
    if self.puzzle then
        table.insert(buttons, {
            { text = all("done") and _("Mark as not done") or _("Mark as done"), enabled = any, callback = act(function()
                local on = not all("done")
                for __, i in ipairs(list) do
                    if (pages[i].done or false) ~= on then ed:toggleDone(i) end
                end
            end) },
            { text = all("hide") and _("Show") or _("Hide"), enabled = any, callback = act(function()
                local on = not all("hide")
                for __, i in ipairs(list) do
                    if (pages[i].hide or false) ~= on then ed:toggleHidden(i) end
                end
                self.selected = {}
                ed:changed()
                ed:refreshToolbar()
            end) },
        })
        table.insert(buttons, { { text = _("Clear writing…"), enabled = any, callback = function()
            UIManager:close(dialog)
            self:confirm(T(_("Clear the writing on %1 pages? This cannot be undone."), #list), _("Clear"), function()
                for __, i in ipairs(list) do ed:clearPageAt(i) end
            end)
        end } })
    else
        table.insert(buttons, {
            { text = all("star") and _("Remove bookmarks") or _("Bookmark"), enabled = any, callback = act(function()
                local on = not all("star")
                for __, i in ipairs(list) do pages[i].star = on or nil end
                ed:changed()
                ed:refreshToolbar()
            end) },
            { text = _("Move to position…"), enabled = any, callback = function()
                UIManager:close(dialog)
                self:moveSelected(list)
            end },
        })
        table.insert(buttons, {
            { text = _("Copy to notebook…"), enabled = any, callback = function()
                UIManager:close(dialog)
                self:toNotebook(list, false, function() self:bulkActions() end)
            end },
            { text = _("Move to notebook…"), enabled = any, callback = function()
                UIManager:close(dialog)
                self:toNotebook(list, true, function() self:bulkActions() end)
            end },
        })
        table.insert(buttons, { { text = _("Delete…"), enabled = any and #list < #pages, callback = function()
            UIManager:close(dialog)
            self:confirm(T(_("Delete %1 pages? You can restore them for 30 days."), #list), _("Delete"), function()
                for k = #list, 1, -1 do ed:deletePageAt(list[k]) end
                self.selected = {}
            end)
        end } })
    end
    table.insert(buttons, {
        { text = _("Select all"), callback = act(function()
            for __, i in ipairs(self:pages()) do self.selected[i] = true end
        end) },
        { text = _("Select none"), callback = act(function() self.selected = {} end) },
    })
    table.insert(buttons, { { text = _("Done selecting"), callback = act(function() self.selected = nil end) } })
    dialog = KO.buttonDialog{
        title = #list == 1 and _("1 page selected") or T(_("%1 pages selected"), #list),
        title_align = "center",
        buttons = buttons,
    }
end

function Overview:confirm(text, ok, fn)
    KO.confirm{
        text = text,
        ok = ok,
        onOk = function()
            fn()
            self:redraw()
        end,
    }
end

-- The pages selected moved together to a position (in their order).
function Overview:moveSelected(list)
    local ed = self.editor
    local pages = ed.notebook.pages
    KO.ask{ title = T(_("Move %1 pages to position (1–%2)"), #list, #pages - #list + 1), text = tostring(list[1]),
        number = true, ok = _("Move"), done = function(typed)
                local to = tonumber(typed)
                if not to then return end
                local current = pages[ed.page]
                local moving, rest = {}, {}
                local picked = {}
                for __, i in ipairs(list) do picked[i] = true table.insert(moving, pages[i]) end
                for i, page in ipairs(pages) do
                    if not picked[i] then table.insert(rest, page) end
                end
                to = math.max(1, math.min(#rest + 1, math.floor(to)))
                for k, page in ipairs(moving) do table.insert(rest, to + k - 1, page) end
                for i = 1, #pages do pages[i] = rest[i] end
                self.selected = {}
                for k = 1, #moving do self.selected[to + k - 1] = true end
                for i, page in ipairs(pages) do
                    if page == current then ed.page = i end
                end
                ed:pagesChanged()
                self:redraw()
    end }
end

-- The pages selected copied (or moved) to the end of another notebook.
function Overview:toNotebook(list, move, back)
    local ed = self.editor
    local store = ed.store
    if not store then return end
    local here = ed.notebook.id
    local others = {}
    for __, nb in ipairs(Store.sorted(store:list(), "name")) do
        if nb.id ~= here then table.insert(others, nb) end
    end
    local dialog
    local buttons = {}
    for __, nb in ipairs(others) do
        table.insert(buttons, { { text = nb.name, align = "left", callback = function()
            UIManager:close(dialog)
            local target, why = store:read(nb.id)
            if not target then
                return KO.message(tostring(why))
            end
            local pages = ed.notebook.pages
            for __, i in ipairs(list) do
                local copy = copyOf(pages[i])
                if copy then table.insert(target.pages, copy) end
            end
            local saved, why2 = store:save(target)
            if not saved then
                return KO.message(T(_("Could not save %1:\n%2"), nb.name, tostring(why2)))
            end
            if move then
                for k = #list, 1, -1 do
                    if #pages > 1 then ed:deletePageAt(list[k], true) else pages[1].strokes, pages[1].items = {}, nil ed:pagesChanged() end
                end
            end
            ed:saveNow()
            self.selected = {}
            require("notesko").toast(T(move and _("Moved %1 pages to %2") or _("Copied %1 pages to %2"), #list, nb.name))
            self:redraw()
        end } })
    end
    if #others == 0 then
        table.insert(buttons, { { text = _("No other notebooks yet."), enabled = false } })
    end
    table.insert(buttons, { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } })
    dialog = KO.buttonDialog{
        title = T(move and _("Move %1 pages to") or _("Copy %1 pages to"), #list),
        title_align = "center",
        buttons = buttons,
        back = back,
    }
end

-- What can be done to a puzzle book's page i (hold).
function Overview:puzzleActions(i)
    local ed = self.editor
    local page = ed.notebook.pages[i]
    local dialog
    local function act(fn) return function() UIManager:close(dialog) fn() self:redraw() end end
    local key = (page.pz or ""):match("^(.-):")
    local removable = self.feed and key and ed.on_remove_puzzle
    dialog = KO.buttonDialog{
        title = Crossword.pageLabel(page, self:today()) or T(_("Page %1"), i),
        title_align = "center",
        buttons = (function(rows)
            local out = {}
            for k = 1, table.maxn(rows) do
                if rows[k] then table.insert(out, rows[k]) end
            end
            return out
        end)({
            { { text = page.done and _("Mark as not done") or _("Mark as done"), callback = act(function() ed:toggleDone(i) end) } },
            { { text = page.hide and _("Show page") or _("Hide page"), callback = act(function() ed:toggleHidden(i) end) } },
            -- The time it took, put right (left open by mistake): in minutes.
            { { text = _("Edit time…"), callback = function()
                UIManager:close(dialog)
                self:editTime(i)
            end } },
            { { text = _("Clear writing"), enabled = #page.strokes > 0, callback = function()
                UIManager:close(dialog)
                KO.confirm{
                    text = T(_("Clear the writing on page %1? This cannot be undone."), i),
                    ok = _("Clear"),
                    onOk = function()
                        ed:clearPageAt(i)
                        self:redraw()
                    end,
                }
            end } },
            removable and { { text = _("Remove puzzle"), callback = function()
                UIManager:close(dialog)
                local function remove()
                    UIManager:close(self)
                    ed.on_remove_puzzle(ed.notebook, key)
                end
                -- At once, with Undo (Crosswords); asked first without Apps (no Undo there).
                if KO.canUndo() then return remove() end
                KO.confirm{
                    text = T(_("Remove %1 from this book? Its pages, answers and writing are deleted."),
                        Crossword.pageLabel(page, self:today()) or key),
                    danger = true,
                    ok = _("Remove"),
                    onOk = remove,
                }
            end } } or nil,
            { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        }),
    }
end

--- A puzzle's time (as the timer has it) put right by hand, in minutes.
function Overview:editTime(i)
    local ed = self.editor
    local first = ed:puzzleFirst(i)
    KO.ask{ title = _("Edit time"), subtitle = _("Minutes spent on this puzzle"), number = true,
        text = tostring(math.floor((first.secs or 0) / 60 + 0.5)), ok = _("Save"), done = function(typed)
            local minutes = tonumber(typed)
            if not minutes or minutes < 0 then return end
            ed.timing = nil
            first.secs = math.floor(minutes * 60 + 0.5)
            ed:changed()
            self:redraw()
        end }
end

-- What can be done to page i (hold).
function Overview:pageActions(i)
    local ed = self.editor
    local page = ed.notebook.pages[i]
    local dialog
    local function act(fn) return function() UIManager:close(dialog) fn() self:redraw() end end
    dialog = KO.buttonDialog{
        title = T(_("Page %1"), i),
        title_align = "center",
        buttons = {
            {
                { text = page.star and _("Remove bookmark") or _("Bookmark"), callback = act(function() ed:toggleStar(i) end) },
                { text = _("Copy page"), callback = act(function() ed:copyPage(i) end) },
            },
            {
                { text = _("Move to…"), callback = function()
                    UIManager:close(dialog)
                    self:moveDialog(i)
                end },
                { text = _("Delete page"), enabled = #ed.notebook.pages > 1, callback = act(function() ed:deletePageAt(i) end) },
            },
            { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        },
    }
end

function Overview:moveDialog(i)
    local ed = self.editor
    KO.ask{ title = T(_("Move page %1 to position (1–%2)"), i, #ed.notebook.pages), text = tostring(i), number = true,
        ok = _("Move"), done = function(typed)
            local to = tonumber(typed)
            if to then
                ed:movePage(i, math.max(1, math.min(#ed.notebook.pages, math.floor(to))))
                self:redraw()
            end
        end }
end

function Overview:onCloseWidget()
    self.ui:free()
    UIManager:setDirty(nil, "full")
end

return Overview
