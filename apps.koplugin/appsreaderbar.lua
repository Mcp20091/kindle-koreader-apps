--[[--
The apps' title bar in a book and in KOReader's library, so they feel like
the other apps: a tap at the top of the page (where KOReader opens its menu)
shows the shared bar (appsbar.lua) over the top of the page.

    ‹  ⌂  The book's title                12:45 PM ▭ 80%  ⟳  🔔  ⋮
          Chapter 3 · Page 41 of 230

- ‹ back to where the book was opened from: Apps (the launcher, Recent apps,
  search) or the library; in the library, up a folder. ⌂ Apps.
- ⟳ a full refresh of the page; 🔔 the notifications of every app.
- ⋮ KOReader's own menu, the book's most used parts (contents, bookmarks,
  go to a page, search, text and layout), the light, night mode, a screen
  refresh, and Settings last (KOReader's menu at its settings).
- A tap anywhere else closes it (with a full refresh of where it was); a
  swipe down from the top still opens KOReader's menu.

Apps settings: "Apps bar in books" and "Apps bar in the library" (on to
start with). Off: KOReader's own tap, as before.
]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Bar = require("appsbar")
local Canvas = require("appscanvas")
local KO = require("appsko")

local Screen = Device.screen

local RB = {}

--- Whether a setting of Apps (`book_bar`, `library_bar`) is on (on unless turned off).
function RB.on(key)
    local s = G_reader_settings:readSetting("apps")
    return not (type(s) == "table" and s[key] == false)
end


-- ------------------------------------------------------------------ the bar over the page

local Overlay = InputContainer:extend{
    opts = nil,       -- for Bar.draw: title, subtitle, back, home, refresh, bell, menu
    on_swipe = nil,   -- a swipe down from the top: KOReader's menu
}

function Overlay:init()
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

function Overlay:render()
    if self.canvas then self.canvas:release() end
    local c = Canvas.new(self.w, self.h, false)
    self.canvas = c
    -- Each action closes the bar first, then does its part.
    local opts = {}
    for k, v in pairs(self.opts) do
        opts[k] = type(v) == "function" and function() self:close() v() end or v
    end
    opts.clock = true
    Bar.draw(c, opts)
    self.barH = c:X(Bar.H) + 2
end

--- Where the bar is (what is refreshed when it shows and goes).
function Overlay:region()
    return Geom:new{ x = 0, y = 0, w = self.w, h = self.barH }
end

function Overlay:paintTo(bb, x, y)
    if self.canvas then self.canvas:paint(bb, x, y) end
end

function Overlay:onTap(_, ges)
    local hit = ges.pos.y <= self.barH and self.canvas and self.canvas:find(ges.pos.x, ges.pos.y)
    if hit and hit.tap then hit.tap() else self:close() end
    return true
end

function Overlay:onHold(_, ges)
    if ges.pos.y > self.barH then self:close() return true end
    -- (On the bar: as a tap. A firm press of the pen lasts long enough to be a hold.)
    return self:onTap(_, ges)
end

function Overlay:onSwipe(_, ges)
    self:close()
    -- In from the left edge: Back (where the book came from, or up a folder).
    if KO.fromLeftEdge(ges) and self.opts.back then self.opts.back() return true end
    if ges.direction == "south" and ges.pos.y <= self.barH * 2 and self.on_swipe then self.on_swipe(ges) end
    return true
end

-- Back (the Kindle's key) closes it.
function Overlay:onClose()
    self:close()
    return true
end

function Overlay:close()
    if self.closed then return end
    self.closed = true
    -- E-ink keeps a ghost of the bar otherwise: where it was, flashed clean.
    UIManager:close(self, "full", self:region())
end

function Overlay:onCloseWidget()
    if self.canvas then self.canvas:release() end
end

local function show(opts, onSwipe)
    local o = Overlay:new{ opts = opts, on_swipe = onSwipe }
    UIManager:show(o, "ui", o:region())
    return o
end

-- ------------------------------------------------------------------ in a book

--- The menu tab with this icon ("appbar.settings"), or nil.
local function tabOf(menu, icon)
    if menu.tab_item_table == nil and menu.setUpdateItemTable then menu:setUpdateItemTable() end
    for i, tab in ipairs(menu.tab_item_table or {}) do
        if tab.icon == icon then return i end
    end
end

--- The book's title, and its chapter and page.
function RB.bookText(ui)
    local doc = ui.document
    local props = ui.doc_props or {}
    local title = props.display_title or props.title
    if not title or title == "" then title = (doc and doc.file or ""):match("([^/]+)$") or _("Book") end
    local sub = {}
    local okP, page = pcall(function() return ui:getCurrentPage() end)
    local okT, total = pcall(function() return doc:getPageCount() end)
    if okP and page then
        local okC, chapter = pcall(function() return ui.toc and ui.toc:getTocTitleByPage(page) end)
        if okC and chapter and chapter ~= "" then table.insert(sub, chapter) end
        table.insert(sub, okT and total and T(_("Page %1 of %2"), page, total) or T(_("Page %1"), page))
    end
    return title, table.concat(sub, "  \u{00B7}  ")
end

function RB.showBook(menu, ges, original)
    local ui = menu.ui
    local PS = require("pluginshare")
    local title, sub = RB.bookText(ui)
    local function koMenu() original(menu, ges) end
    show({
        title = title, subtitle = sub,
        status = PS.showControlCenter and function() PS.showControlCenter(koMenu) end or nil,
        back = function() RB.back(ui) end,
        home = PS.appsHome and function() PS.appsHome() end or nil,
        refresh = function() UIManager:setDirty("all", "full") end,
        bell = PS.showNotifications and function() PS.showNotifications() end or nil,
        menu = function()
            local function send(name) return function() ui:handleEvent(Event:new(name)) end end
            KO.menu(ui, nil, {
                { _("KOReader menu"), koMenu },
                { _("Table of contents"), send("ShowToc") },
                { _("Bookmarks"), send("ShowBookmark") },
                { _("Go to page"), send("ShowGotoDialog") },
                { _("Search"), send("ShowFulltextSearchInput") },
                { _("Text and layout"), send("ShowConfigMenu") },
            }, function() menu:onShowMenu(tabOf(menu, "appbar.settings")) end)
        end,
    }, function(g) if menu.onSwipeShowMenu then menu:onSwipeShowMenu(g) end end)
end

-- ------------------------------------------------------------------ in the library

function RB.showLibrary(menu, ges, original)
    local fm = menu.ui
    local fc = fm and fm.file_chooser
    local PS = require("pluginshare")
    local path = fc and fc.path or ""
    local parent = path:match("^(.+)/[^/]+$")
    show({
        -- (with the Library app, this is KOReader's own file browser: named so)
        title = PS.library and _("File browser") or _("Library"),
        subtitle = path,
        status = PS.showControlCenter and function() PS.showControlCenter(function() original(menu, ges) end) end or nil,
        back = parent and function() fc:changeToPath(parent, path) end or nil,
        home = PS.appsHome and function() PS.appsHome() end or nil,
        refresh = function()
            if fm.onRefresh then fm:onRefresh() end
            UIManager:setDirty("all", "full")
        end,
        bell = PS.showNotifications and function() PS.showNotifications() end or nil,
        menu = function()
            KO.menu(fm, nil, {
                { _("KOReader menu"), function() original(menu, ges) end },
                { _("Home folder"), function() if fm.onHome then fm:onHome() end end },
                PS.library and { _("Library"), function() PS.library.open() end } or nil,
            }, function() menu:onShowMenu(tabOf(menu, "appbar.settings")) end)
        end,
    }, function(g) if menu.onSwipeShowMenu then menu:onSwipeShowMenu(g) end end)
end

-- ------------------------------------------------------------------ the tap at the top

--- KOReader's tap at the top of a book (ReaderMenu) and of the library
-- (FileManagerMenu), taken over once while the setting is on.
--- Opens a book from Apps, so Back in it comes back to Apps (a book already
-- open stays as it is, and now comes back to Apps too).
function RB.openBook(file)
    local ReaderUI = require("apps/reader/readerui")
    local open = ReaderUI.instance
    if open and open.document and open.document.file == file then
        open.apps_back_to_apps = true
        return
    end
    require("pluginshare").apps_book = file
    ReaderUI:showReader(file)
end

--- A book coming up: did Apps open it? (Kept on the book's ReaderUI, so it
-- goes when the book closes.)
function RB.cameFrom(ui)
    local PS = require("pluginshare")
    if ui and ui.document and PS.apps_book and PS.apps_book == ui.document.file then
        ui.apps_back_to_apps = true
    end
    PS.apps_book = nil
end

--- Back in a book (to Apps when Apps opened it, else the library) or in the
-- library (up a folder).
function RB.back(ui)
    local PS = require("pluginshare")
    if ui.document and ui.apps_back_to_apps and PS.appsHome then return PS.appsHome() end
    if ui.document and ui.onHome then return ui:onHome() end
    local fc = ui.file_chooser
    local path = fc and fc.path
    local parent = path and path:match("^(.+)/[^/]+$")
    if parent then fc:changeToPath(parent, path) end
end

--- In a book and the library, with the Apps bar on: a swipe in from the left
-- edge (its leftmost tenth) is Back, as in every app. Only that swipe: the
-- rest of the screen turns pages as before (a touch zone of the book or
-- library, matched like KOReader's own; nothing else in the input path).
function RB.edgeBack(ui)
    if not ui or ui.apps_edge_back then return end
    ui.apps_edge_back = true
    local key = ui.document and "book_bar" or "library_bar"
    ui:registerTouchZones({ {
        id = "apps_edge_back",
        ges = "swipe",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 0.1, ratio_h = 1 },
        overrides = { "paging_swipe", "rolling_swipe" },
        handler = function(ges)
            if ges.direction ~= "east" or not RB.on(key) then return end
            RB.back(ui)
            return true
        end,
    } })
end

--- The first book opened with the Apps bar on: a tip, once.
function RB.tipOnce(ui)
    if not (ui and ui.document) or not RB.on("book_bar") or G_reader_settings:isTrue("apps_bar_tip_shown") then return end
    G_reader_settings:makeTrue("apps_bar_tip_shown")
    UIManager:scheduleIn(1.5, function() KO.toast(_("Tap the top of the page for the apps bar"), 5) end)
end

function RB.install()
    if RB.installed then return end
    RB.installed = true
    local function hook(module, key, showFn)
        local ok, M = pcall(require, module)
        if not ok or not M or not M.onTapShowMenu then return end
        local original = M.onTapShowMenu
        M.onTapShowMenu = function(menu, ges)
            if menu.activation_menu ~= "swipe" and RB.on(key) then
                local okS, err = pcall(showFn, menu, ges, original)
                if okS then return true end
                logger.warn("Apps bar:", err)
            end
            return original(menu, ges)
        end
    end
    hook("apps/reader/modules/readermenu", "book_bar", RB.showBook)
    hook("apps/filemanager/filemanagermenu", "library_bar", RB.showLibrary)
end


return RB
