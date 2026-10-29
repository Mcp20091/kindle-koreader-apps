--[[--
Notes: handwritten notebooks in KOReader.

Tools > Notes (or a gesture: General > Notes) lists the notebooks; tap one
to write in it, hold one to rename, duplicate or delete it; the cog opens
the settings. Notebooks live in koreader/notes/.

@module koplugin.notes
]]

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen
local Crossword = require("notescrossword")
local Editor = require("noteseditor")
local KO = require("notesko")
local Settings = require("notessettings")
local Store = require("notesstore")

local Notes = WidgetContainer:extend{
    name = "notes",
    is_doc_only = false,
}
require("notesonenoteui")(Notes)
require("notestextui")(Notes)
require("notesfolderui")(Notes)
require("notestodolink")(Notes)
require("notesmargin")(Notes)
require("notesclose")(Notes)
require("noteslock")(Notes)
require("notesonenoteview")(Notes)
-- (The Crosswords plugin adds its parts when installed, see hasCrosswords:
-- puzzle books are then its own app and left out of the list.)
require("notesfind")(Notes)
require("notesquick")(Notes)

local function listFiles(dir)
    local lfs = require("libs/libkoreader-lfs")
    local out = {}
    if lfs.attributes(dir, "mode") ~= "directory" then return out end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then table.insert(out, name) end
    end
    return out
end

function Notes:init()
    -- A full refresh when a dialog over Notes' screens closes (as the other apps').
    KO.flashOnUncover()
    -- No AI service set up: the AI's buttons and menu items are left out.
    Settings.noAI = function() return not self:anyAI() end
    -- Notes in Apps' Settings, Search and Set up your Kindle (notesshare).
    require("notesshare").install(self)
    -- OneNote on the launcher's one Microsoft account (its old sign-in handed over once).
    pcall(self.useMicrosoftAccount, self)
    -- The sort to start with (Settings > Notebook list > Default sort).
    local start = Settings.get("sort_default")
    if start and start ~= "last" and Settings.SORT[start] then Settings.set("sort", start) end
    local dir = DataStorage:getDataDir() .. "/notes"
    require("util").makePath(dir)
    self.store = Store.new{ dir = dir, list = listFiles, stat = function(path)
        return require("libs/libkoreader-lfs").attributes(path)
    end, mkdir = function(path) require("util").makePath(path) end }
    -- A notebook saved from anywhere but its kept copy (the web page, To Do's
    -- ticks, a crossword, text sent in): that copy is stale, even when saved
    -- in the same second it was closed.
    local save = self.store.save
    self.store.save = function(store, nb, ...)
        local k = self.kept and nb and self.kept[nb.id]
        if k and k.notebook ~= nb then self.kept[nb.id] = nil end
        local ok, why = save(store, nb, ...)
        -- Its links, for Linked from.
        if ok then pcall(self.noteLinks, self, nb) end
        return ok, why
    end
    -- Notebooks in the trash longer than 30 days go for good.
    pcall(self.store.emptyTrash, self.store)
    self.folders = require("notesfolders").open(dir .. "/folders.lua")
    -- To Do (started after Notes) has its ids followed for the links.
    UIManager:nextTick(function() pcall(self.hookTodo, self) end)
    self.folder = ""
    Dispatcher:registerAction("notes_show", { category = "none", event = "ShowNotes", title = _("Notes"), general = true })
    Dispatcher:registerAction("notes_today", { category = "none", event = "NotesToday", title = _("Notes: today's page"), general = true })
    Dispatcher:registerAction("notes_quick", { category = "none", event = "NotesQuickNote", title = _("Notes: quick note"),
        general = true })
    Dispatcher:registerAction("notes_margin", { category = "none", event = "NotesMargin",
        title = _("Notes: write on this page"), reader = true })
    self.ui.menu:registerToMainMenu(self)
end

-- A book open: its pages' ink shown (PDFs and other fixed-page books).
function Notes:onReaderReady()
    pcall(self.marginReady, self)
end

function Notes:addToMainMenu(menu_items)
    menu_items.notes = {
        text = _("Notes"),
        sorting_hint = "tools",
        callback = function() self:showStart() end,
    }
    if self.ui.paging then
        menu_items.notes_margin = {
            text = _("Write on this page"),
            sorting_hint = "tools",
            callback = function() self:marginWrite() end,
        }
    end
end

function Notes:onShowNotes()
    self:showStart()
    return true
end

function Notes:onNotesToday()
    self:todayPage()
    return true
end

--- Today's page in the Journal notebook, made when it isn't there yet (a
-- new page with the date at the top; the Journal's first page while it is
-- still blank). The notebook is made the first time. `when`: another day
-- (a time in it), from the month calendar; its page goes among the others
-- in date order.
function Notes:todayPage(when)
    -- App lock (the launcher's): its passcode first, when this app is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask("notes", function() self:todayPage(when) end) then return end
    -- The notebook open is saved and closed first (it may be the Journal).
    self:closeEditor()
    local store = self.store
    local id = Settings.get("journal_id")
    local nb = id and store:read(id)
    local Screen = Device.screen
    if not nb then
        nb = store:create(_("Journal"), Screen:getWidth(), Screen:getHeight(), Settings.get("paper") or "narrow")
        if not nb then return end
        Settings.set("journal_id", nb.id)
        Settings.set("journal_days", {})
        self:refresh()
    end
    local day = os.date("%Y-%m-%d", when)
    local days = Settings.get("journal_days") or {}
    local index
    for i, page in ipairs(nb.pages) do
        if page.id == days[day] then index = i end
    end
    if not index then
        local used = {}
        for __, pid in pairs(days) do used[pid] = true end
        local first = nb.pages[1]
        if #nb.pages == 1 and not used[first.id] and #first.strokes == 0 and not (first.items and #first.items > 0) then
            index = 1
        else
            -- After the last page of an earlier day (at the end for today).
            index = #nb.pages + 1
            if when then
                local dayOf = {}
                for d, pid in pairs(days) do dayOf[pid] = d end
                for i, page in ipairs(nb.pages) do
                    if dayOf[page.id] and dayOf[page.id] > day then
                        index = i
                        break
                    end
                end
            end
            table.insert(nb.pages, index, { id = Store.newPageId(), created = when or os.time(), strokes = {} })
        end
        local page = nb.pages[index]
        local u = Screen:getDPI() / 100
        page.items = page.items or {}
        table.insert(page.items, { k = "text", x = math.floor(48 * u), y = math.floor(14 * u), w = math.floor(Screen:getWidth() * 0.7),
            size = math.floor(75 * Screen:getDPI() / 300 + 0.5), bold = true, text = os.date("%A, %B %d", when) })
        days[day] = page.id
        Settings.set("journal_days", days)
        store:save(nb)
    end
    self.kept = self.kept and (function(k) k[nb.id] = nil return k end)(self.kept)
    self:open(nb.id, index)
end

--- Days of the month of `when` with a Journal page: { [day] = true }.
function Notes:journalMarks(when)
    local month = os.date("%Y-%m-", when)
    local out = {}
    for d in pairs(Settings.get("journal_days") or {}) do
        if d:sub(1, #month) == month then out[tonumber(d:sub(-2))] = true end
    end
    return out
end

-- Text split into pieces that each fit `fits` (whole paragraphs where they
-- can, else whole words; a word too long for a page goes on one anyway).
local function splitToFit(text, fits)
    local pieces, cur = {}, nil
    local function add(part, sep)
        if part == "" and not cur then return true end   -- no blank lines at a page's top
        local try = cur and (cur .. sep .. part) or part
        if fits(try) then
            cur = try
            return true
        end
        if cur then
            table.insert(pieces, cur)
            cur = nil
            if fits(part) then
                cur = part
                return true
            end
        end
        return false
    end
    for para in (text .. "\n"):gmatch("(.-)\n") do
        if not add(para, "\n") then
            -- A paragraph longer than a page: word by word.
            local first = true
            for word in para:gmatch("%S+") do
                if not add(word, first and "" or " ") then cur = word end
                first = false
            end
        end
    end
    if cur and cur:find("%S") then table.insert(pieces, cur) end
    return pieces
end

--- Notebooks to pick from (Home Assistant's Send to Notes, the web page):
-- { { id, name }... }, newest first, locked ones left out.
function Notes:notebookChoices()
    local out = {}
    for __, nb in ipairs(self:notebooks()) do
        if not self:isLocked(nb.id) and not nb.puzzle then table.insert(out, { id = nb.id, name = nb.name }) end
    end
    return out
end

--- A picture (a PNG or JPG file on the Kindle) on a new page at the end of
-- a notebook: opts.notebook (an id; else "From the web page"), opts.title
-- (typed above it). The file is copied. Returns where it went, or nil and why.
function Notes:addImagePage(path, opts)
    opts = opts or {}
    local store = self.store
    local nb
    if opts.notebook then
        if self:isLocked(opts.notebook) then return nil, _("That notebook is locked") end
        nb = store:read(opts.notebook)
        if not nb then return nil, _("No such notebook") end
    else
        local id = Settings.get("web_notebook")
        nb = id and store:read(id)
        if not nb then
            local why
            nb, why = store:create(_("From the web page"), Screen:getWidth(), Screen:getHeight(), "plain")
            if not nb then return nil, why end
            Settings.set("web_notebook", nb.id)
        end
    end
    local ed = self.editor
    local open = ed and UIManager:isWidgetShown(ed) and ed.notebook.id == nb.id and ed or nil
    if open then nb = open.notebook end
    -- The picture into the notebooks' pictures.
    local dir = store:imageDir()
    require("util").makePath(dir)
    local ext = tostring(path):lower():match("%.(%a+)$") or "png"
    if ext == "jpeg" then ext = "jpg" end
    if ext ~= "png" and ext ~= "jpg" then return nil, _("Only PNG and JPG pictures can be added") end
    local file = string.format("img%d%03d.%s", os.time(), math.random(0, 999), ext)
    local ok, why = Store.copyFile(path, dir .. "/" .. file)
    if not ok then return nil, why end
    local W, H = nb.width or Screen:getWidth(), nb.height or Screen:getHeight()
    local u = Screen:getDPI() / 100
    local x, top, margin = math.floor(48 * u), math.floor(24 * u), math.floor(24 * u)
    local items = {}
    local y = top
    local title = opts.title and tostring(opts.title):match("^%s*(.-)%s*$") or ""
    if title ~= "" then
        local size = math.floor((Editor.TEXT_SIZES.m or 54) * Screen:getDPI() / 300 + 0.5)
        table.insert(items, { k = "text", x = x, y = y, w = W - x - margin, size = size, bold = true, text = title })
        y = y + math.floor(size * 1.8)
    end
    local Items = require("notesitems")
    -- A big photo made screen-sized once (drawing it is then quick).
    Items.shrinkPicture(dir .. "/" .. file, math.max(Screen:getWidth(), Screen:getHeight()))
    local w, h = Items.pictureSize(dir .. "/" .. file, 1e9, 1e9)
    if not w then
        os.remove(dir .. "/" .. file)
        return nil, _("Could not read the picture.")
    end
    -- As large as fits the page (a small camera picture is made bigger, up to 3 times).
    local f = math.min(3, (W - x - margin) / w, (H - y - margin) / h)
    w, h = math.max(1, math.floor(w * f)), math.max(1, math.floor(h * f))
    table.insert(items, { k = "image", x = x + math.floor((W - x - margin - w) / 2), y = y, w = w, h = h, file = file })
    -- An empty first page (a new notebook) is used, not left blank.
    local first = nb.pages[1]
    local reuse = #nb.pages == 1 and #first.strokes == 0 and not (first.items and #first.items > 0)
    if reuse then first.items = items else table.insert(nb.pages, { id = Store.newPageId(), created = os.time(), strokes = {}, items = items }) end
    local at = reuse and 1 or #nb.pages
    if open then
        open:pagesChanged(not reuse)
        open:saveNow()
    else
        local saved, why2 = store:save(nb)
        if not saved then return nil, why2 end
    end
    self:refresh()
    return T(_("%1, page %2"), nb.name, at)
end

--- Text sent from the web page: typed on new pages at the end of the
-- notebook "From the web page" (made when missing). Returns where it went,
-- or nil and why.
function Notes:addTextPage(text)
    text = tostring(text or ""):gsub("\r\n?", "\n"):sub(1, 60000):match("^%s*(.-)%s*$")
    if not text:find("%S") then return nil, _("Nothing to add") end
    local store = self.store
    local id = Settings.get("web_notebook")
    local nb = id and store:read(id)
    if not nb then
        local why
        nb, why = store:create(_("From the web page"), Screen:getWidth(), Screen:getHeight(), "plain")
        if not nb then return nil, why end
        Settings.set("web_notebook", nb.id)
    end
    -- The notebook open now: the pages go into it there (its next save
    -- would otherwise put back the copy without them).
    local ed = self.editor
    local open = ed and UIManager:isWidgetShown(ed) and ed.notebook.id == nb.id and ed or nil
    if open then nb = open.notebook end
    local W, H = nb.width or Screen:getWidth(), nb.height or Screen:getHeight()
    local u = Screen:getDPI() / 100
    local x, top, bottom = math.floor(48 * u), math.floor(24 * u), math.floor(24 * u)
    local base = { k = "text", x = x, y = top, w = W - x - math.floor(24 * u),
        size = math.floor((Editor.TEXT_SIZES[Settings.get("text_size") or "m"] or 54) * Screen:getDPI() / 300 + 0.5) }
    local Items = require("notesitems")
    local function fits(s)
        local __, __, __, h = Items.box({ k = "text", x = base.x, y = base.y, w = base.w, size = base.size, text = s })
        return top + h <= H - bottom
    end
    local pieces = splitToFit(text, fits)
    -- An empty first page (a new notebook) is used, not left blank.
    local first = nb.pages[1]
    local reuse = #nb.pages == 1 and #first.strokes == 0 and not (first.items and #first.items > 0)
    local at = reuse and 1 or #nb.pages + 1
    for i, piece in ipairs(pieces) do
        local item = { k = "text", x = base.x, y = base.y, w = base.w, size = base.size, text = piece }
        if i == 1 and reuse then
            first.items = { item }
        else
            table.insert(nb.pages, { id = Store.newPageId(), created = os.time(), strokes = {}, items = { item } })
        end
    end
    if open then
        open:pagesChanged(not reuse)
        open:saveNow()
    else
        local ok, why = store:save(nb)
        if not ok then return nil, why end
    end
    self:refresh()
    if #pieces > 1 then return T(_("%1, pages %2–%3"), nb.name, at, at + #pieces - 1) end
    return T(_("%1, page %2"), nb.name, at)
end

--- Notes opened (menu, gesture, Apps): the list, and the last notebook on
-- top of it when the settings say so.
function Notes:showStart()
    -- App lock (the launcher's): its passcode first, when this app is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask("notes", function() self:showStart() end) then return end
    self:closeEditor()
    self.crosswordsApp = nil
    self:show()
    local id = Settings.get("open_last") and Settings.get("last_notebook")
    if id and self.store:summary(id) then self:open(id) end
end

-- The pen comes through KOReader's stylus API (KOReader 2026.07 or later).
function Notes:penReady()
    if type(Device.input.registerStylusCallback) ~= "function" then
        KO.message(_("Notes needs a newer KOReader (2026.07 or later) for the pen."))
        return false
    end
    return true
end

function Notes:show()
    -- App lock (the launcher's): its passcode first, when Notes (or Crosswords) is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask(self.crosswordsApp and "crosswords" or "notes", function() self:show() end) then return end
    if self.menu then UIManager:close(self.menu) end
    self.inTrash, self.selection = false, nil
    -- New crosswords from the sources picked, when Wi-Fi is on, and finished
    -- ones tidied (the Crosswords plugin, when installed).
    UIManager:scheduleIn(1, function()
        -- (Only for the Crosswords list: Notes' own leaves crosswords alone.)
        if not self.crosswordsApp then return end
        pcall(self.tidyCrosswords, self)
        if self.autoCrosswords then self:autoCrosswords() end
    end)
    if Settings.get("list_view") ~= "list" then
        -- Covers (notesgrid.lua), driven like the list.
        self.menu = require("notesgrid"):new{
            notes = self,
            title = self.inTrash and _("Trash") or self:folderTitle(),
            items = self:items(),
            onSettings = function() self:showSettings() end,
            close_callback = function() self.menu = nil end,
        }
        KO.showFull(self.menu)
        self:shown(self.menu)
        return
    end
    -- A list: rows in the shared design (notessettingspage), with the title bar.
    self.menu = require("notessettingspage"):new{
        title = self.inTrash and _("Trash") or self:folderTitle(),
        items = self:items(),
        titleOpts = {
            home = require("pluginshare").appsHome and function() self:goHome() end or nil,
            bell = KO.bell(),
            menu = function() self:titleMenu({}) end,
            back = function() self:listBack() end,
            status = true,
        },
        close_callback = function() self.menu = nil end,
    }
    -- Your KOReader gestures work here too (see notesko.lua).
    local menu = self.menu
    local onGesture, handleEvent = menu.onGesture, menu.handleEvent
    function menu.onGesture(m, ev)
        if Settings.get("ko_gestures") ~= false and KO.passGesture(self.ui, ev, KO.notesSafe) then return true end
        return onGesture(m, ev)
    end
    function menu.handleEvent(m, event)
        if handleEvent(m, event) then return true end
        return KO.passEvent(self.ui, event)
    end
    KO.showFull(self.menu)
    self:shown(self.menu)
end

--- A screen of Notes' on top: Notes first in Apps' recent apps, and the
-- screen kept (self.screen) for Apps' switcher to bring back. (Not the
-- Crosswords app's: it is its own.)
function Notes:shown(widget)
    if self.crosswordsApp then return end
    self.screen = widget
    require("notesshare").opened()
end

-- The settings, with the notebook list's, OneNote's and the AI's.
--- Notes' settings; `jump` (a row's name): at the page with it.
function Notes:showSettings(changed, fromEditor, jump)
    self.settingsPage = Settings.show(changed or function() self:refresh() end, self:settingsExtra(fromEditor, jump))
    self:shown(self.settingsPage)
end

--- Each of Notes' settings by name, for the launcher's search:
-- { { name, open } } (opened at its page).
function Notes:settingsNames()
    local out, seen = {}, {}
    local ok, rows = pcall(Settings.show, nil, (function()
        local e = self:settingsExtra(false)
        e.rowsOnly = true
        return e
    end)())
    for __, r in ipairs(ok and type(rows) == "table" and rows or {}) do
        if r and not r.heading and (r.text or r.label) then
            local name = Settings.rowName(r.text or r.label)
            if name ~= "" and not seen[name] then
                seen[name] = true
                table.insert(out, { name = name, open = function() self:showSettings(nil, false, name) end })
            end
        end
    end
    return out
end

-- What Notes' settings page holds besides Settings' own rows.
function Notes:settingsExtra(fromEditor, jump)
    local list = { { _("Reorder notebooks…"), function() self:reorderNotebooks() end } }
    if not fromEditor then
        table.insert(list, 1, { T(_("Show notebooks as: %1"), Settings.get("list_view") == "list" and _("List") or _("Covers")), function()
            Settings.set("list_view", Settings.get("list_view") == "list" and "covers" or "list")
            self:show()
        end })
    end
    -- One tap: every AI feature to Claude, or to your local AI.
    -- AI for every job, picked from the list of AI services; with none set
    -- up, the one AI row left: "AI services: Not set up" (to set one up).
    local top = { { function()
        if not self:anyAI() then return T(_("AI services: %1"), _("Not set up")) end
        return T(_("AI: %1"), self:aiAllName())
    end, function()
        if not self:anyAI() then return self:handwritingSettings() end
        self:switchAllAI(function() if self.settingsPage then self.settingsPage:refresh() end end)
    end } }
    -- Reading handwriting (with an AI set up).
    table.insert(top, { function()
        return T(_("Dates written beside tasks (To Do): %1"), Settings.get("todo_dates") ~= false and _("Read") or _("Ignored"))
    end, function()
        Settings.set("todo_dates", Settings.get("todo_dates") == false)
        if self.settingsPage then self.settingsPage:refresh() end
    end, when = function() return self:anyAI() end })
    -- (Its count reads every notebook: shown once it runs, not here.)
    table.insert(top, { _("Read all pages now"), function() self:readAllPages() end, open = true,
        when = function() return self:anyAI() end })
    return {
        jump = jump,
        kui = self.ui,
        list = list,
        top = top,
        -- The shared title bar: ⌂ Home, ⋮ (Open on the web page).
        title = {
            home = require("pluginshare").appsHome and function() self:goHome() end or nil,
            bell = KO.bell(),
            menu = function(page) self:titleMenu({}, true) end,
        },
        connections = {
            { _("OneNote…"), function() self:oneNoteSettings() end },
            -- (Settings > AI, the launcher's: shared with Crosswords and SSH.)
            { _("AI settings…"), function() self:handwritingSettings() end,
                when = function() return require("pluginshare").ai ~= nil end },
        },
    }
end

--- ⌂ Home (the title bar, the toolbar): Notes closed, what is open saved,
-- and the Apps launcher shown (without it, KOReader's library or book).
function Notes:goHome()
    if self.quickEditor then pcall(self.quickEditor.close, self.quickEditor) end
    self:closeEditor()
    for __, w in ipairs({ self.settingsPage, self.oneNoteMenu, self.menu }) do
        if w and UIManager:isWidgetShown(w) then UIManager:close(w) end
    end
    self.settingsPage, self.menu, self.crosswordsApp = nil, nil, nil
    UIManager:nextTick(function()
        if KO.home() then return end
        local apps = self.ui and self.ui.apps
        if apps and apps.show then apps:show() end
    end)
end

--- ⋮ on the title bar: `items` ({ text, fn }) first, then Open on the web
-- page and, last, Settings (not on the settings themselves).
function Notes:titleMenu(items, onSettings)
    -- (The Crosswords app's list: its own.)
    if self.crosswordsApp and self.crosswordTitleMenu and not onSettings then return self:crosswordTitleMenu(true) end
    local rows = {}
    local function add(text, fn) table.insert(rows, { text = text, fn = fn }) end
    for __, it in ipairs(items or {}) do add(it[1], it[2]) end
    local web = self:webPage()
    if web then add(_("Open on the web page"), function() web:openOnWeb("notes") end) end
    -- The apps opened lately (Apps).
    local PS = require("pluginshare")
    if PS.showSwitcher then add(_("Recent apps"), function() PS.showSwitcher() end) end
    if KO.hasLight() then add(_("Light"), function() KO.light() end) end
    add(KO.nightMode() and _("Night mode: On") or _("Night mode: Off"), function() KO.toggleNightMode(self.ui) end)
    add(_("Refresh screen"), function() KO.refresh() end)
    if not onSettings then add(_("Settings"), function() self:showSettings() end) end
    KO.list(nil, rows)
end

--- Whether the Crosswords plugin is installed (it adds crosswordTap and
-- the rest of its parts to Notes).
function Notes:hasCrosswords()
    return self.crosswordTap ~= nil
end

--- ‹ Back on the notebook list: up a folder (or out of Recent or the
-- trash), else Notes closed (and the Apps launcher shown, when there).
function Notes:listBack()
    if self.crosswordsApp then return self:goHome() end
    if self.inTrash or self.inRecent then return self:openFolder("") end
    local folder = self.folder or ""
    if folder ~= "" then return self:openFolder(require("notesfolders").parent(folder)) end
    self:goHome()
end

--- The Web server plugin, when it can show a page as a QR code (nil if not).
function Notes:webPage()
    local web = self.ui and self.ui.webpage
    if web and type(web.openOnWeb) == "function" then return web end
end

function Notes:notebooks()
    return Notes.pinnedFirst(Store.sorted(self.store:list(), Settings.get("sort"), Settings.get("custom")))
end

-- The notebooks put in order by hand (the list then keeps that order).
function Notes:reorderNotebooks()
    local items = {}
    for __, nb in ipairs(self:notebooks()) do table.insert(items, { text = nb.name, key = nb.id }) end
    Settings.reorder(_("Reorder notebooks"), items, function(ids)
        Settings.set("custom", ids)
        Settings.set("sort", "custom")
        self:refresh()
    end)
end

-- A notebook closed: the page it was on (to open it there next time), and
-- its undo (kept while KOReader runs, for the last two notebooks closed).
function Notes:keepClosed(ed)
    local id = ed.notebook.id
    local pages = Settings.get("last_pages") or {}
    pages[id] = ed.page
    Settings.set("last_pages", pages)
    Settings.set("last_notebook", id)
    self.kept = self.kept or {}
    self.keptOrder = self.keptOrder or {}
    self.kept[id] = { notebook = ed.notebook, modified = ed.notebook.modified, undo = ed.undo, redo = ed.redo }
    for i = #self.keptOrder, 1, -1 do
        if self.keptOrder[i] == id then table.remove(self.keptOrder, i) end
    end
    table.insert(self.keptOrder, id)
    while #self.keptOrder > 2 do
        self.kept[table.remove(self.keptOrder, 1)] = nil
    end
end

-- A new notebook into the folder shown.
function Notes:putInFolder(id)
    if (self.folder or "") ~= "" then
        self.folders:set(id, self.folder)
        self.folders:save()
    end
end

-- The Kindle turned to the notebook's orientation (landscape notebooks
-- landscape, the others portrait) while it is open; turned back after.
function Notes:turnFor(notebook)
    local w, h = notebook.width or 0, notebook.height or 0
    -- Two pages side by side: on its side.
    local landscape = w > h or (Settings.get("spread") or {})[notebook.id] == true
    local mode = Screen:getRotationMode()
    if (mode % 2 == 1) == landscape then return end
    if self.rotationBefore == nil then self.rotationBefore = mode end
    Screen:setRotationMode(landscape and 1 or 0)
end

-- The Kindle turned to `mode` while a notebook is open; turned back after.
function Notes:rotateTo(mode)
    if self.rotationBefore == nil then self.rotationBefore = Screen:getRotationMode() end
    Screen:setRotationMode(mode)
end

function Notes:restoreRotation()
    if self.rotationBefore == nil then return end
    Screen:setRotationMode(self.rotationBefore)
    self.rotationBefore = nil
    UIManager:setDirty(nil, "full")
end

--- The notebook open on screen closed (saved), when there is one.
function Notes:closeEditor()
    local ed = self.editor
    if ed and UIManager:isWidgetShown(ed) then ed:close() end
    self.editor = nil
end

function Notes:open(id, page)
    -- App lock (the launcher's): its passcode first, when Notes (or Crosswords) is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask(self.crosswordsApp and "crosswords" or "notes", function() self:open(id, page) end) then return end
    if not self:penReady() then return end
    -- Locked: its PIN first.
    if self:isLocked(id) and not self.pinOK then
        return self:unlockThen(id, function()
            self.pinOK = true
            self:open(id, page)
            self.pinOK = nil
        end)
    end
    self:noteOpened(id)
    -- Already open: to the page. Another one open: closed first (saved), so
    -- two never hold the same notebook.
    local ed = self.editor
    if ed and UIManager:isWidgetShown(ed) then
        if ed.notebook.id == id then
            local nb = ed.notebook
            if page and nb.feed and nb.pages[page] and not Crossword.inView(nb.pages[page], ed.w > ed.h) then
                page = Crossword.counterpart(nb, page) or page
            end
            if page then ed:goPage(page) end
            return
        end
        self:closeEditor()
    end
    local notebook, why = self.store:read(id)
    if not notebook then
        KO.message(T(_("Could not open the notebook:\n%1"), tostring(why)))
        return
    end
    if notebook.newIds then
        self.store:save(notebook)
        notebook.newIds = nil
    end
    -- Crosswords laid out as the settings say now (older books get their
    -- landscape pages); the page asked for found again if that moved it.
    if notebook.feed and self.prepareCrosswordBook then
        local pz = page and notebook.pages[page] and notebook.pages[page].pz
        notebook = self:prepareCrosswordBook(notebook)
        if pz and (notebook.pages[page] or {}).pz ~= pz then
            for i, pg in ipairs(notebook.pages) do
                if pg.pz == pz then page = i end
            end
        end
    end
    -- Closed a moment ago and unchanged since: the same notebook, with its undo.
    local kept = self.kept and self.kept[id]
    if kept and kept.modified == notebook.modified then notebook = kept.notebook else kept = nil end
    -- Opened at the page it was left on.
    if not page then page = (Settings.get("last_pages") or {})[id] end
    -- Crosswords: that page as laid out for the book's orientation.
    if notebook.feed and page and notebook.pages[page]
            and not Crossword.inView(notebook.pages[page], (notebook.width or 0) > (notebook.height or 0)) then
        page = Crossword.counterpart(notebook, page) or page
    end
    self:turnFor(notebook)
    local cw = self:hasCrosswords()
    self.editor = Editor:new{
        kui = self.ui,
        notebook = notebook,
        page = page,
        store = self.store,
        spread = (Settings.get("spread") or {})[id] == true,
        on_spread = function(ed, on, mode)
            local spread = Settings.get("spread") or {}
            spread[id] = on or nil
            Settings.set("spread", spread)
            -- Opened again, turned.
            local at = ed.page
            self.turning = true
            UIManager:close(self.editor)
            self.turning = false
            self:restoreRotation()
            -- Turned by hand: the way it is held.
            if mode then Screen:setRotationMode(mode) end
            self:open(id, at)
        end,
        on_close = function(ed)
            -- ⌂ Home: on to the Apps launcher once closed.
            if ed and ed.homeAfter then UIManager:nextTick(function() self:goHome() end) end
            if ed and not ed.discard then pcall(self.noteCrosswordSeen, self, ed, true) end
            if ed and not ed.discard then self:keepClosed(ed) end
            if ed and self.editor == ed then self.editor = nil end
            if self.turning then return end
            self:restoreRotation()
            self:refresh()
            if ed and ed.discard then return end
            self:autoSendNotebook(id)
            -- Still named by date: the AI's name offered (Suggest names (AI)).
            UIManager:nextTick(function() pcall(self.offerName, self, id) end)
        end,
        on_close_ask = function(ed) self:askOnClose(ed) end,
        onenote_origin = function(ed) return self:originInOneNote(ed.notebook.id, ed.notebook.pages[ed.page].id) ~= nil end,
        on_replace_onenote = function(ed) self:replaceInOneNote(ed) end,
        on_journal_day = function(when) self:todayPage(when) end,
        on_home = require("pluginshare").appsHome and function() end or nil,   -- (⌂ Home on the toolbar: see on_close)
        on_bell = KO.bell(),
        -- ⋯ > Open on the web page: this notebook there, as a QR code.
        on_web = self:webPage() and function(ed) self:webPage():openOnWeb("notes?nb=" .. ed.notebook.id) end or nil,
        journal_marks = function(when) return self:journalMarks(when) end,
        linked_from = function(ed) return #self:linksTo(ed.notebook.id, ed.notebook.pages[ed.page].id) end,
        on_linked_from = function(ed) self:showLinkedFrom(ed) end,
        on_rename = function(ed)
            self:renameDialog(ed.notebook, function(name)
                ed.notebook.name = name
                ed:changed()
            end)
        end,
        on_turn = function(nb, at)
            -- Opened again in its new orientation.
            self.turning = true
            UIManager:close(self.editor)
            self.turning = false
            self:open(nb.id, at)
        end,
        on_onenote = function(nb) self:sendToOneNote(nb.id) end,
        on_settings = function(changed) self:showSettings(changed, true) end,
        on_link = function(target, pageId)
            local nb = self.store:read(target)
            if not nb then
                return KO.message(_("The linked notebook is no longer there (deleted or in the trash)."))
            end
            local at = 1
            for i, page in ipairs(nb.pages) do
                if page.id == pageId then at = i end
            end
            -- This notebook closes, the other opens at the page.
            local from = self.editor and self.editor.notebook.id
            self.turning = true
            UIManager:close(self.editor)
            self.turning = false
            self:restoreRotation()
            if from then self:autoSendNotebook(from) end
            self:open(target, at)
        end,
        on_text = function(nb, index) self:convertPage(nb.id, index) end,
        on_text_all = function(nb) self:exportNotebookText(nb.id) end,
        on_text_png = function(png, name, replace) self:convertImage(png, name, replace) end,
        on_todo = function(nb, index, lines) self:pageToTodo(nb.id, index, lines) end,
        on_tick = function(nb, pageId, line, on) pcall(self.onPageTick, self, nb, pageId, line, on) end,
        on_page = function(ed)
            pcall(self.syncPageTicks, self, ed)
            pcall(self.noteCrosswordSeen, self, ed)
        end,
        on_todo_png = function(png) self:addToTodo(png) end,
        on_ask = function(nb, index) self:askAboutPage(nb.id, index) end,
        on_ask_png = function(png, name) self:askClaude(png, name) end,
        on_draw = function(what, apply) self:drawWithClaude(what, apply) end,
        -- (Crosswords: from the Crosswords plugin, when installed.)
        on_crossword = cw and function(src) self:getCrossword(src) end or nil,
        on_answer = cw and function(ed, area) self:crosswordAnswer(ed, area) end or nil,
        on_reveal = cw and self.crosswordReveal and function(ed, area) self:crosswordReveal(ed, area) end or nil,
        on_check = cw and function(ed, area) self:checkCrossword(ed, area) end or nil,
        on_clue_boxes = cw and function(ed) return self:crosswordBoxes(ed) end or nil,
        on_clue_tap = cw and function(ed, x, y) return self:crosswordTap(ed, x, y) end or nil,
        on_hint = cw and function(ed, mode, x, y) return self:crosswordHint(ed, mode, x, y) end or nil,
        on_crossword_settings = cw and function(changed) self:crosswordSettings(changed) end or nil,
        on_grid = cw and function(ed, i) return self:crosswordGridAt(ed.notebook, i, ed.w, ed.h) end or nil,
        on_web_crossword = cw and self:crosswordsOnWebReady() and function(ed) self:crosswordsOnWeb(ed) end or nil,
        on_stats = cw and function() self:showCrosswordStats() end or nil,
        on_remove_puzzle = cw and function(nb, key) self:removeCrossword(nb.id, key) end or nil,
        -- Crosswords turned: opened again with the pages for that orientation
        -- (`mode`: the way the Kindle is held, turned by hand or `chosen` in
        -- ⋯ > Page orientation, when it's turned back on closing).
        on_orient = function(ed, landscape, mode, chosen)
            local nb = ed.notebook
            local w, h = nb.width or ed.w, nb.height or ed.h
            if (w > h) ~= landscape then nb.width, nb.height = h, w end
            local at = Crossword.counterpart(nb, ed.page) or ed.page
            -- What's written in the grid goes with it (from the page shown to
            -- the puzzle's other clue pages first).
            ed:shareGrid(ed.page)
            local key = Crossword.keyPart(nb.pages[ed.page])
            if key and (ed.w > ed.h) ~= landscape then pcall(self.carryCrosswordGrid, self, nb, key, landscape, ed.h, ed.w) end
            ed.dirty = true
            ed:saveNow()
            self.turning = true
            UIManager:close(self.editor)
            self.turning = false
            if chosen then
                self:rotateTo(mode)
            else
                self:restoreRotation()
                if mode then Screen:setRotationMode(mode) end
            end
            self:open(nb.id, at)
        end,
        on_rotate = function(mode) self:rotateTo(mode) end,
        onenote_status = function(nb) return self:oneNoteStatus(nb) end,
    }
    if kept then self.editor.undo, self.editor.redo = kept.undo, kept.redo end
    -- As opened, for "Don't save" (When closing: Ask).
    if Settings.get("close_action") == "ask" then self.editor.openedText = Store.serialize(notebook) end
    KO.showFull(self.editor)
    self:shown(self.editor)
    pcall(self.noteCrosswordSeen, self, self.editor)
end

--- A new notebook (in the folder shown), opened.
function Notes:createNotebook(name, paper)
    if not name or name == "" then name = Notes.defaultName() else name = Notes.datedName(name) end
    local nb, why = self.store:create(name, Screen:getWidth(), Screen:getHeight(), paper)
    if nb and not Settings.get("pressure") then
        nb.pressure = false
        self.store:save(nb)
    end
    if not nb then
        KO.message(T(_("Could not create the notebook:\n%1"), tostring(why)))
        return
    end
    self:putInFolder(nb.id)
    self:refresh()
    self:open(nb.id)
    -- New: "Don't save" removes it.
    if self.editor and self.editor.notebook.id == nb.id then self.editor.isNew = true end
end

-- Your own templates, to start a notebook named `name` with one.
function Notes:pickTemplate(name)
    local pick
    local rows = {}
    for __, t in ipairs(Editor.templates()) do
        table.insert(rows, { { text = t.name, align = "left", callback = function()
            UIManager:close(pick)
            self:createNotebook(name, "tpl:" .. t.file)
        end } })
    end
    table.insert(rows, { { text = _("Cancel"), callback = function() UIManager:close(pick) end } })
    pick = KO.buttonDialog{ title = _("Your templates"), title_align = "center", buttons = rows }
end

function Notes:newNotebook()
    local default = Settings.get("paper")
    -- The launcher's pop-up: the name (or the pen to write it), the papers
    -- as tiles to pick one, your template or a PDF, Cancel and Create.
    local P = require("pluginshare").popup
    if P and P.request then
        local paper = default or "narrow"
        local items = {}
        if #Editor.templates() > 0 then
            table.insert(items, { text = _("Your template…"), fn = function(box)
                local name = box:getText()
                box:close()
                self:pickTemplate(name)
            end })
        end
        table.insert(items, { text = _("From a PDF…"), fn = function(box)
            box:close()
            self:pickPDF()
        end })
        local tiles = {}
        for __, p in ipairs({ { "plain", _("Blank") }, { "narrow", _("Narrow") }, { "wide", _("Wide") }, { "grid", _("Grid") }, { "dots", _("Dots") } }) do
            table.insert(tiles, { value = p[1], text = p[2], pattern = p[1] })
        end
        P.request{
            title = _("New notebook"),
            hint = Notes.defaultName(),
            pen = KO.pen(),
            penTitle = _("Write the name"), penKind = "name",
            sections = {
                { heading = _("PAPER"), tiles = tiles, value = paper, pick = function(v) paper = v end },
                { items = items },
            },
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = "plus", text = _("Create"), primary = true, fn = function(name) self:createNotebook(name, paper) end },
            },
        }
        return
    end
    local dialog
    local function create(paper)
        local name = dialog:getInputText()
        UIManager:close(dialog)
        self:createNotebook(name, paper)
    end
    dialog = InputDialog:new{
        title = _("New notebook"),
        input = "",
        input_hint = Notes.defaultName(),
        -- (Two rows of five, or three of three without Write it: the dividers line up.)
        buttons = (function()
            local papers = {
                { text = _("Blank"), callback = function() create("plain") end },
                { text = _("Narrow"), callback = function() create("narrow") end },
                { text = _("Wide"), callback = function() create("wide") end },
                { text = _("Grid"), callback = function() create("grid") end },
                { text = _("Dots"), callback = function() create("dots") end },
            }
            local template = { text = _("Template…"), enabled = #Editor.templates() > 0, callback = function()
                local name = dialog:getInputText()
                UIManager:close(dialog)
                self:pickTemplate(name)
            end }
            local pdf = { text = _("From PDF…"), callback = function()
                UIManager:close(dialog)
                self:pickPDF()
            end }
            local cancel = { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end }
            -- (On the default paper; the other buttons each pick one.)
            local ok = { text = _("Create"), is_enter_default = true, callback = function() create(default) end }
            local write = KO.writeButton(function() return dialog end, { kind = "name" })
            if write then return { papers, { template, pdf, write, cancel, ok } } end
            return { { papers[1], papers[2], papers[3] }, { papers[4], papers[5], template }, { pdf, cancel, ok } }
        end)(),
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- A PDF picked in the Kindle's files becomes a notebook to write on (a
-- puzzle book with `puzzle`).
function Notes:pickPDF(puzzle)
    local start = G_reader_settings:readSetting("home_dir") or (Device.home_dir) or "/mnt/us/documents"
    -- (A file picked in the apps' design: notespick.lua.)
    require("notespick").show{
        title = puzzle and _("Choose puzzles") or _("Choose a PDF"),
        path = start,
        filter = function(file)
            local f = file:lower()
            return f:match("%.pdf$") ~= nil or (puzzle and (f:match("%.puz$") or f:match("%.ipuz$")) ~= nil) or false
        end,
        done = function(path)
            -- A crossword file: laid out like the crosswords got from the web.
            if path:lower():match("%.i?puz$") and self.importCrosswordFile then return self:importCrosswordFile(path) end
            self:importPDF(path, puzzle)
        end,
    }
end

--- A PDF made a notebook (a puzzle book with `puzzle`) and opened; `quiet`
-- (the web page): not opened, nothing shown, the notebook returned (or nil
-- and why); `name`: its name (else the file's).
function Notes:importPDF(path, puzzle, quiet, name)
    local PDF = require("notespdf")
    local count, pw, ph = PDF.pageCount(path)
    if not count then
        if quiet then return nil, pw end
        KO.message(T(_("Could not open the PDF:\n%1"), tostring(pw)))
        return
    end
    -- Landscape pages make a landscape notebook.
    local w, h = Screen:getWidth(), Screen:getHeight()
    local landscape = (pw or 0) > (ph or 0)
    if (w > h) ~= landscape then w, h = h, w end
    name = name or path:match("([^/]+)$"):gsub("%.[Pp][Dd][Ff]$", "")
    local nb, why = self.store:createFromPDF(name, path, count, w, h, puzzle)
    if not nb then
        if quiet then return nil, why end
        KO.message(T(_("Could not make the notebook:\n%1"), tostring(why)))
        return
    end
    if puzzle then
        -- Puzzle books in the Crosswords folder, beside the crosswords got from the web.
        self.folders:set(nb.id, _("Crosswords"))
        self.folders:save()
    else
        self:putInFolder(nb.id)
    end
    self:refresh()
    if quiet then return nb end
    self:open(nb.id)
end

function Notes:notebookActions(entry)
    local dialog
    local function act(fn) return function() UIManager:close(dialog) fn() end end
    local buttons = {
        {
            { text = _("Rename"), callback = act(function() self:renameNotebook(entry) end) },
            { text = _("Duplicate"), callback = act(function()
                local copy = self.store:duplicate(entry.id, T(_("%1 (copy)"), entry.name))
                if copy then
                    self.folders:set(copy.id, self.folders:of(entry.id))
                    self.folders:save()
                    self:refresh()
                end
            end) },
            { text = _("Delete"), callback = act(function() self:deleteNotebook(entry) end) },
        },
        {
            { text = _("Move to…"), callback = act(function() self:moveSelection({ ["n:" .. entry.id] = true }, function() self:notebookActions(entry) end) end) },
            { text = _("Select"), callback = act(function() self:startSelection("n:" .. entry.id) end) },
        },
        {
            { text = self:isPinned(entry.id) and _("Unpin") or _("Pin to top"), callback = act(function()
                self:setPinned(entry.id, not self:isPinned(entry.id))
                self:refresh()
            end) },
            { text = self:isLocked(entry.id) and _("Remove lock") or _("Lock…"), callback = act(function()
                if self:isLocked(entry.id) then self:unlockNotebook(entry) else self:lockNotebook(entry) end
            end) },
        },
        { { text = _("Send to OneNote now"), callback = act(function() self:sendToOneNote(entry.id) end) } },
    }
    -- Where it goes in OneNote (when signed in): the default, or a notebook and section.
    if self:oneNote():signedIn() then
        table.insert(buttons, { { text = self:oneNoteWhereText("n:" .. entry.id) .. "…", callback = act(function()
            self:pickOneNoteTarget("n:" .. entry.id, entry.name, nil, function() self:notebookActions(entry) end)
        end) } })
    end
    -- A tile for it in the Apps launcher (when Apps is installed).
    local apps = self.ui and self.ui.apps
    if apps and apps.addPin then
        table.insert(buttons, { { text = _("Add to launcher"), callback = act(function()
            apps:addPin({ kind = "note", id = entry.id, name = entry.name, icon = "notebook-pen" })
        end) } })
    end
    if Settings.get("onenote_picked_only") then
        table.insert(buttons, { { text = self:pickedForOneNote(entry.id) and _("Sent to OneNote by itself: yes") or _("Sent to OneNote by itself: no"),
            callback = act(function() self:setPickedForOneNote(entry.id, not self:pickedForOneNote(entry.id)) end) } })
    end
    table.insert(buttons, { { text = _("Close"), callback = act(function() end) } })
    dialog = KO.buttonDialog{ title = entry.name, title_align = "center", buttons = buttons }
end

function Notes:renameNotebook(entry)
    local nb = self.store:read(entry.id)
    if not nb then return end
    self:renameDialog(nb, function(name)
        local fresh = self.store:read(entry.id)
        if not fresh then return end
        fresh.name = name
        self.store:save(fresh)
        self:refresh()
    end)
end

--- A notebook to the trash at once, with Undo for a few seconds (and the
-- trash for 30 days); asked first without Apps (no Undo there).
function Notes:deleteNotebook(entry)
    local function go()
        local snap = self.folders:snapshot()
        if not self:trashNotebook(entry.id) then return end
        self.folders:save()
        self:refresh()
        self:offerUndo(T(_("Moved \"%1\" to the trash"), entry.name), { entry.id }, snap)
    end
    if KO.canUndo() then return go() end
    KO.confirm{
        text = T(_("Move \"%1\" (%2) to the trash? You can restore it for 30 days."), entry.name,
            entry.pages == 1 and _("1 page") or T(_("%1 pages"), entry.pages)),
        danger = true,
        ok = _("Delete"),
        onOk = go,
    }
end

--- After a delete: Undo puts the notebooks (`ids`, in the trash) back and
-- the folders as they were (`snap`).
function Notes:offerUndo(text, ids, snap)
    KO.undo(text, function()
        for __, id in ipairs(ids) do self.store:restore(id) end
        self.folders:restore(snap)
        self.folders:save()
        self:refresh()
    end)
end

return Notes
