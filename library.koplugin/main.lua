--[[--
Library: books and folders in one place, in the apps' design, with KOReader
as the backend (its Cover browser's titles and covers, each book's settings,
its history, collections, reading statistics and file operations). Books open
in KOReader's reader, and Back from a book comes back here.

It takes the place of KOReader's file browser: when that browser would be
on top (after a book closes, at start), the Library shows over it instead,
unless another app is showing or the user chose "Browse books with: KOReader's
file browser" (Library settings). ⋮ > KOReader file browser is always there.

Shared with the other apps (when the launcher is installed): PS.library
(open, openFolder, isBrowser), its settings in the launcher's Settings list,
its books in the launcher's search, its settings file in the web page's backup.

@module koplugin.library
]]

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local state = { trashChecked = false }

local Library = WidgetContainer:extend{
    name = "library",
    is_doc_only = false,
}

-- The screens, loaded on first use (only registering happens at start).
local function V()
    local m = require("libraryviews")
    m.plugin = m.plugin or state.plugin
    return m
end

function Library:init()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    require("libraryko").flashOnUncover()
    local PS = require("pluginshare")
    local S = require("librarysettings")
    state.plugin = self
    local views = package.loaded["libraryviews"]
    if views then
        views.plugin = self
        if views.screen and not views.screen.closed then self.screen = views.screen end
    end

    PS.library = {
        --- The Library on top (where it was left).
        open = function() V().open(self) end,
        --- The Library at a book's folder.
        openFolder = function(file)
            local dir = file and (file:match("^(.*)/[^/]+$") or file)
            V().open(self, { kind = "folder", path = dir or require("librarymodel").home(), tab = "folders" })
        end,
        --- A book's page.
        openBook = function(file)
            V().open(self, { kind = "book", path = file, tab = "home" })
        end,
        --- A book's page found by its title (and authors), as the reading statistics know it;
        -- the Library's Home when it isn't there.
        openTitle = function(title, authors)
            local path = require("librarymodel").findTitle(title, authors)
            if path then return V().open(self, { kind = "book", path = path, tab = "home" }) end
            V().open(self)
            require("libraryko").toast(_("That book isn't in the Home folder"))
        end,
        --- Whether the Library is where books are browsed (Library settings > Browse books with).
        isBrowser = function() return S.isBrowser() end,
        settings = function(name) V().settings(name) end,
    }
    if PS.registerSettings then
        PS.registerSettings{ key = "library", name = _("Library"), icon = "library", open = function(name) V().settings(name) end,
            rows = function() return V().settingNames() end }
    end
    -- What it is for the launcher (apps.koplugin/appsinfo.lua): no tile of its own (the
    -- launcher's Library tile opens it), its Settings row in Reading, no gestures over the apps.
    PS.appInfo = PS.appInfo or {}
    PS.appInfo.library = { name = _("Library"), icon = "library", dir = self.path, order = 45, group = "reading", gestures = {} }
    if PS.registerSearch then
        PS.registerSearch{ key = "library", name = _("Library"), icon = "library", search = function(q) return Library.search(self, q) end }
    end
    -- A step in the launcher's Set up your Kindle: the Library or KOReader's file browser.
    if PS.registerSetup then
        PS.registerSetup{ key = "library", order = 15, icon = "library", title = _("Library"),
            text = _("Browse your books with the Library: covers or a list, what you're reading, authors, series and collections, and your folders. Books still open in KOReader's reader. Or keep KOReader's own file browser."),
            done = function() return S.get("browser") ~= nil end,
            action = _("Choose"),
            skipped = _("The Library is used. Library settings > Browse books with switches to KOReader's file browser."),
            run = function()
                require("libraryko").choose(_("Browse books with"), {
                    { label = _("The Library"), value = "library" },
                    { label = _("KOReader's file browser"), value = "koreader" },
                }, S.get("browser", "library"), function(val) S.set("browser", val) end)
            end }
        -- Then books from elsewhere: an FTP or WebDAV server, and the online catalogs.
        PS.registerSetup{ key = "libraryservers", order = 16, icon = "cloud", title = _("Book servers and catalogs"),
            text = _("Open books from an FTP or WebDAV server (a NAS or computer at home), or download free books from online catalogs such as Project Gutenberg. They're on the Library's Home and under Folders."),
            done = function()
                local ok, R = pcall(require, "libraryservers")
                return ok and #R.servers() > 0
            end,
            -- (only with the Library: KOReader's file browser has its own Cloud storage)
            when = function() return S.isBrowser() end,
            action = _("Add a server"),
            skipped = _("Add one any time: Library > Folders > Add a server. The catalogs are there too."),
            run = function() V().editServer() end }
    end
    PS.backupApps = PS.backupApps or {}
    PS.backupApps.library = { key = "library", name = _("Library"), files = { "^library%.lua$" } }

    if not state.trashChecked then
        -- (files left in the trash by a KOReader that stopped while Undo showed: gone now)
        state.trashChecked = true
        local trash = require("datastorage"):getDataDir() .. "/cache/library-trash"
        if require("libs/libkoreader-lfs").attributes(trash, "mode") == "directory" then
            UIManager:scheduleIn(5, function() pcall(require("librarymodel").emptyTrash) end)
        end
    end

    if self.ui.document then
        -- A book opened (from anywhere): the Library is the place to come back to again.
        PS.library_aside = nil
        PS.library_book = nil
    else
        self:standIn()
    end
end

--- Over KOReader's file browser when it is the one on top (after a book, at start).
function Library:standIn()
    local S = require("librarysettings")
    if not S.isBrowser() then return end
    local fm = self.ui
    UIManager:scheduleIn(0.5, function()
        local PS = require("pluginshare")
        if PS.library_aside then return end
        local FileManager = package.loaded["apps/filemanager/filemanager"]
        if not (FileManager and FileManager.instance == fm) then return end
        -- (only when nothing else is over it, other than notices that go by
        -- themselves: another app, the launcher or a dialog stay on top)
        local stack = UIManager._window_stack or {}
        for i = #stack, 1, -1 do
            local w = stack[i].widget
            if w == fm then break end
            if not (w.toast or w.timeout) then return end
        end
        V().open(self)
    end)
end

function Library:onDispatcherRegisterActions()
    Dispatcher:registerAction("library_show", { category = "none", event = "ShowLibrary", title = _("Library"), general = true })
end

function Library:addToMainMenu(menu_items)
    -- (The reader's menu has a "filemanager" tab; the file browser's doesn't, and a hint to a
    -- menu that isn't there crashes KOReader's menu: its first tab there.)
    menu_items.library_app = {
        text = _("Library"),
        sorting_hint = self.ui and self.ui.document and "filemanager" or "filemanager_settings",
        callback = function() V().open(self) end,
    }
end

function Library:onShowLibrary()
    V().open(self)
    return true
end

--- The launcher's search (q in lower case): collections, and (once the Library
-- has been opened, so from memory) authors and series. The launcher finds the
-- books themselves.
function Library.search(plugin, q)
    local M = require("librarymodel")
    local out = {}
    if #q < 2 then return out end
    local function has(s) return type(s) == "string" and s:lower():find(q, 1, true) ~= nil end
    for __, c in ipairs(M.collections()) do
        if #out < 20 and has(c.label) then
            table.insert(out, { title = c.label, sub = #c.files == 1 and _("Collection · 1 book") or require("ffi/util").template(_("Collection · %1 books"), #c.files),
                icon = "library", open = function() V().open(plugin, { kind = "collection", name = c.name, label = c.label, tab = "collections" }) end })
        end
    end
    if not M.state.books then return out end
    for __, a in ipairs(M.authorList()) do
        if #out < 20 and has(a.name) then
            table.insert(out, { title = a.name, sub = #a.books == 1 and _("Author · 1 book") or require("ffi/util").template(_("Author · %1 books"), #a.books),
                icon = "user", open = function() V().open(plugin, { kind = "author", name = a.name, tab = "authors" }) end })
        end
    end
    local seen = {}
    for __, b in ipairs(M.books()) do
        local s = M.series(b)
        if s and not seen[s] and #out < 20 and has(s) then
            seen[s] = true
            table.insert(out, { title = s, sub = _("Series"), icon = "layers",
                open = function() V().open(plugin, { kind = "series", name = s, tab = "home" }) end })
        end
    end
    return out
end

return Library
