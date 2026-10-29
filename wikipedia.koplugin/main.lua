--[[--
Wikipedia: search and read Wikipedia, and save articles to read without
Wi-Fi. A front page (Today's featured article, On this day; Saved; Recent),
and articles that open as EPUBs in KOReader's reader, inside the app's own
toolbar (Home, Back, Search, Contents, Save, Language, Text).

Open it from Tools > Wikipedia, a gesture (General > Wikipedia), or the Apps launcher.

@module koplugin.wikipedia
]]

local Dispatcher = require("dispatcher")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local N_ = _.ngettext
local ffiutil = require("ffi/util")
local T = ffiutil.template

local API = require("wikiapi")
local Bg = require("wikibg")
local Canvas = require("wikicanvas")
local Epub = require("wikiepub")
local M = require("wikimodel")
local Store = require("wikistore")

-- KOReader crashes when an icon button is tapped before its icon was ever
-- drawn: the tap's flash needs the icon's size (seen on the Kindle right after
-- a book opens, articles or not). Without a size the flash is skipped; the
-- tap still works. Once, for all of KOReader.
if not UIManager.wikipedia_invert_guard then
    UIManager.wikipedia_invert_guard = true
    local invert = UIManager.widgetInvert
    UIManager.widgetInvert = function(um, widget, x, y, w, h)
        if widget and not widget.dimen and not (w and h) then return end
        return invert(um, widget, x, y, w, h)
    end
end

-- Kept while KOReader runs (opening an article makes a new reader, and with it
-- a new plugin): the way back, positions to restore, the book open before.
local state = {
    back = {},          -- paths of earlier articles, or "home"
    positions = {},     -- path -> place to open it at
    after = {},         -- path -> what to do once it is open
    returnTo = nil,     -- the book open before Wikipedia
    home = nil,         -- the front page, when showing
}

local Wikipedia = WidgetContainer:extend{
    name = "wikipedia",
    is_doc_only = false,
}

function Wikipedia:init()
    Canvas.setDir(self.path)
    self.store = Store.get()
    -- A tap on one of Wikipedia's notifications after KOReader restarted.
    local PS = require("pluginshare")
    PS.notifyOpeners = PS.notifyOpeners or {}
    PS.notifyOpeners.wikipedia = function(route) self:openRoute(route) end
    -- What it is for the launcher and the web page: its tile, Settings group, web tab
    -- (apps.koplugin/appsinfo.lua).
    PS.appInfo = PS.appInfo or {}
    PS.appInfo.wikipedia = { name = _("Wikipedia"), icon = "wikipedia", dir = self.path, order = 50, group = "reading",
        explore = _("Read articles and save them for offline"),
        tiles = { { key = "wikipedia", event = "ShowWikipedia", line = function(w)
            local line = w:appsLine() or ""
            return line ~= "" and line or _("Search and save articles")
        end } },
        web = { page = "wikipedia", routes = "webwikipedia", script = "web/wikipedia.js",
            card = "Saved articles, and saving new ones to the Kindle." } }
    -- The launcher's Settings list, and its search (saved articles, by title).
    if PS.registerSettings then
        PS.registerSettings{ key = "wikipedia", name = _("Wikipedia"), icon = "wikipedia",
            open = function(name) self:currentPlugin():show("settings", name) end,
            rows = function() return require("wikihome").settingRows() end }
    end
    -- Quick buttons (the launcher's clock corner and control center): a random article, the front
    -- page's Today, and search. Tap does it; hold opens the front page.
    if PS.registerQuick then
        local function ask(fn)
            local lock = PS.lock
            if lock and lock.ask("wikipedia", fn) then return end
            fn()
        end
        local QUICK = {
            random = { name = _("Random article"), icon = "shuffle", run = function(w) w:random() end },
            today = { name = _("Today"), icon = "newspaper", run = function(w) w:show("today") end },
            search = { name = _("Search"), icon = "search", run = function(w) w:show("search") end },
        }
        PS.registerQuick{ key = "wikipedia", name = _("Wikipedia"),
            choices = function()
                local out = {}
                for __, id in ipairs({ "random", "today", "search" }) do
                    table.insert(out, { id = id, name = QUICK[id].name, icon = QUICK[id].icon })
                end
                return out
            end,
            item = function(id)
                local q = QUICK[id]
                if not q then return nil end
                return { label = q.name, icon = q.icon,
                    tap = function(done)
                        ask(function() q.run(self:currentPlugin()) end)
                        done()
                    end,
                    hold = function() ask(function() self:currentPlugin():show("today") end) end }
            end }
    end
    -- The web page's backup: the settings (saved articles stay out: they are in
    -- the Library, and can be downloaded again).
    PS.backupApps = PS.backupApps or {}
    PS.backupApps.wikipedia = { key = "wikipedia", name = _("Wikipedia"), files = { "^wikipedia%.lua$" } }
    if PS.registerSearch then
        PS.registerSearch{ key = "wikipedia", name = _("Wikipedia"), icon = "wikipedia",
            search = function(q) return self:currentPlugin():searchSaved(q) end }
    end
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    local doc = self.ui.document
    -- (any left from a crash, outside a book)
    if not doc then UIManager:nextTick(function() self:tidyHistory() end) end
    if doc and doc.file then
        local a = self.store:article(doc.file)
        if a then
            self.article = a
            -- (KOReader reads these right after the plugins start)
            if self.ui.doc_settings then self.store:giveStyle(self.ui.doc_settings) end
            self.bar = require("wikitoolbar"):new{ wiki = self, ui = self.ui, article = a }
            self.bar:attach()
        end
    end
end

function Wikipedia:onDispatcherRegisterActions()
    Dispatcher:registerAction("wikipedia_show", { category = "none", event = "ShowWikipedia", title = _("Wikipedia"), general = true })
end

function Wikipedia:addToMainMenu(menu_items)
    menu_items.wikipedia_app = {
        text = _("Wikipedia"),
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

function Wikipedia:onShowWikipedia()
    self:show()
    return true
end

function Wikipedia:onReaderReady()
    local path = self.ui.document and self.ui.document.file
    local after = path and state.after[path]
    if path then state.after[path] = nil end
    if self.bar then
        self.bar:ready(state.positions[path])
        state.positions[path] = nil
    end
    if after then UIManager:nextTick(after) end
end

-- The font, size, margins… kept for the next article whenever KOReader saves
-- the article's settings (as it closes too: after CloseDocument).
function Wikipedia:onSaveSettings()
    if self.article and self.ui.doc_settings then self.store:keepStyle(self.ui.doc_settings) end
end

function Wikipedia:onCloseDocument()
    if self.bar then self.bar:detach() end
    -- (after KOReader has noted the time in its history)
    if self.article then self:tidyHistory() end
end

--- "Show in recent books" off: the articles taken out of KOReader's history
-- (the launcher's recent books, Continue reading, History).
function Wikipedia:tidyHistory()
    if self.store:read("in_history") ~= false then return end
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory.hist then return end
    for i = #ReadHistory.hist, 1, -1 do
        local item = ReadHistory.hist[i]
        if type(item.file) == "string" and item.file:match("%.epub$") and self.store:article(item.file) then
            ReadHistory:removeItem(item, i)
        end
    end
end

-- ------------------------------------------------------------------ helpers

function Wikipedia:webPage()
    local ui = self.ui
    local web = ui and ui.webpage
    if web and type(web.openOnWeb) == "function" then return web end
end

function Wikipedia:notice(text, timeout)
    require("wikibar").notice(text, timeout)
end

function Wikipedia:cantReach()
    self:notice(_("Can't reach Wikipedia. Check the Wi-Fi and try again."))
end

--- Run `fn` when connected (KOReader asks to turn on Wi-Fi when it is off;
-- no name lookup, which can hang on flaky Wi-Fi).
function Wikipedia:online(fn)
    NetworkMgr:runWhenConnected(fn)
end

--- Ask Wikipedia in the background with `text` showing (tap it to stop):
-- done(result) when there is an answer (false: no such article); a message
-- when Wikipedia can't be reached; nothing when stopped.
function Wikipedia:fetch(text, fn, done)
    Bg.run(fn, function(r, why)
        if r == nil then
            if why ~= "stopped" then self:cantReach() end
            return
        end
        done(r)
    end, { text = text, limit = 60 })
end

--- Download an article into `path` in the background (tap the message to
-- stop); done(ok) after, with a message when it failed.
function Wikipedia:download(path, title, lang, images, done)
    Bg.run(function() return Epub.build(path, title, lang, images) end, function(ok, why)
        ok = ok == true
        if not ok then
            os.remove(path .. ".tmp")
            if why ~= "stopped" then self:notice(_("The article wasn't downloaded.")) end
        end
        done(ok)
    end, { text = T(_("Downloading “%1”…"), title) .. "\n" .. _("Tap to stop."), limit = 600 })
end

local function readerUI()
    local ReaderUI = require("apps/reader/readerui")
    return ReaderUI.instance, ReaderUI
end

--- The article open in the reader, if it is one of ours: { title, lang, saved, path }.
function Wikipedia:openArticleInfo()
    local rui = readerUI()
    local file = rui and rui.document and rui.document.file
    return file and self.store:article(file)
end

-- ------------------------------------------------------------------ the front page

-- The Apps launcher is showing (its screen, not the library or a book: they
-- have the Apps plugin too).
local function launcherShowing()
    local View = package.loaded["appsview"]
    local top = UIManager:getTopmostVisibleWidget()
    return View ~= nil and top ~= nil and getmetatable(top) == View
end

--- The Apps launcher again (leaving Wikipedia opened from it).
local function showLauncher()
    -- (the shared way, from Apps; else its own show)
    local PS = require("pluginshare")
    if PS.appsHome then return PS.appsHome() end
    local ui = require("apps/reader/readerui").instance
    if not ui then
        local FileManager = package.loaded["apps/filemanager/filemanager"]
        ui = FileManager and FileManager.instance
    end
    if ui and ui.apps and ui.apps.show then ui.apps:show() end
end

--- This plugin in the screen open now (the library's or the book's: each has one).
function Wikipedia:currentPlugin()
    local ui = require("apps/reader/readerui").instance
    if not ui then
        local FileManager = package.loaded["apps/filemanager/filemanager"]
        ui = FileManager and FileManager.instance
    end
    return ui and ui.wikipedia or self
end

--- Saved articles whose title has `q` (lower case): for the launcher's search.
function Wikipedia:searchSaved(q)
    local out = {}
    for __, a in ipairs(self.store:savedIndex()) do
        if a.lower:find(q, 1, true) then
            local path = a.path
            table.insert(out, { title = a.title, sub = a.description or _("Saved article"),
                open = function() self:currentPlugin():openFile(path, { from = "home" }) end })
            if #out >= 20 then break end
        end
    end
    return out
end

--- The front page (tab: "today", "saved", "recent" or "settings"); jump: a
-- setting's name, to open the settings at its page.
function Wikipedia:show(tab, jump, pick)
    -- App lock (the launcher's): its passcode first, when this app is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask("wikipedia", function() self:show(tab, jump, pick) end) then return end
    -- The launcher's recent apps (the switcher brings this screen back: self.screen).
    local PS = require("pluginshare")
    if PS.noteRecent then PS.noteRecent("wikipedia") end
    -- Coming in (not from an article of ours): where to go back to on leaving.
    if not state.home and not self:openArticleInfo() then state.fromLauncher = launcherShowing() end
    if state.home then UIManager:close(state.home) end
    local Home = require("wikihome")
    state.home = Home:new{ wiki = self, tab = tab or "today", jump = jump, pick = pick }
    self.screen = state.home
    UIManager:show(state.home)
end

function Wikipedia:closeHome()
    if state.home then
        UIManager:close(state.home)
        state.home = nil
    end
    self.screen = nil
end

--- Leave Wikipedia: back to the book open before it, or the library; and to
-- the Apps launcher when Wikipedia was opened from it.
function Wikipedia:closeApp()
    self:closeHome()
    state.back = {}
    local launcher = state.fromLauncher
    state.fromLauncher = nil
    local rui = readerUI()
    local file = rui and rui.document and rui.document.file
    -- An article opened from outside Wikipedia (a recent list, the library):
    -- the launcher, when there is one, is home.
    if launcher == nil then launcher = rui ~= nil and rui.apps ~= nil and rui.apps.show ~= nil end
    if file and self.store:article(file) then
        local back = state.returnTo
        state.returnTo = nil
        if back and lfs.attributes(back, "mode") == "file" then
            -- (the launcher once that book is open)
            if launcher then state.after[back] = showLauncher end
            rui:switchDocument(back)
        else
            rui:onHome()
            if launcher then UIManager:nextTick(showLauncher) end
        end
    end
end

--- ⌂ Home: the Apps launcher (leaving Wikipedia; an article open goes back
-- to the book before it, as Close does). Without Apps, Wikipedia just closes.
function Wikipedia:goLauncher()
    local rui = readerUI()
    local file = rui and rui.document and rui.document.file
    if file and self.store:article(file) then
        state.fromLauncher = true
        return self:closeApp()
    end
    self:closeHome()
    state.back, state.fromLauncher = {}, nil
    if not launcherShowing() then showLauncher() end
end

--- Today's featured feed, fetched in the background and kept for the day; done(feed or nil).
function Wikipedia:fetchToday(lang, done)
    Bg.run(function() return API.featured(lang) end, function(feed)
        if type(feed) == "table" then self.store:setToday(lang, feed) else feed = nil end
        done(feed)
    end, { limit = 45 })
end

-- ------------------------------------------------------------------ opening articles

--- Open an article by title: from the Kindle if it is there, else from Wikipedia.
-- opts.from: "home" (Back comes back to the front page) or "article" (to the article open now).
function Wikipedia:openArticle(title, lang, opts)
    opts = opts or {}
    lang = lang or self.store:lang()
    local have = self.store:find(title, lang)
    if have then return self:openCopy(have, opts) end
    self:online(function()
        self:fetch(_("Opening…"), function() return API.summary(lang, title) end, function(info)
            if info == false then return self:notice(T(_("Wikipedia has no article called “%1”."), title)) end
            local again = self.store:find(info.title, lang)
            if again then return self:openCopy(again, opts) end
            local path = self.store:cachePath(info.title, lang)
            local images = self.store:read("images")
            self:download(path, info.title, lang, images, function(ok)
                if not ok then return end
                self.store:setMeta(path, { title = info.title, lang = lang, description = info.description, images = images })
                self.store:trimCache(path)
                self:openFile(path, opts)
            end)
        end)
    end)
end

--- Open an article already on the Kindle. With Images on, an unsaved copy
-- without them is downloaded again first (when there is Wi-Fi).
function Wikipedia:openCopy(path, opts)
    local a = self.store:article(path)
    if not a or a.saved or not self.store:needsImages(path) or not NetworkMgr:isConnected() then
        return self:openFile(path, opts)
    end
    self:download(path, a.title, a.lang, true, function(ok)
        if ok then
            self.store:setMeta(path, { title = a.title, lang = a.lang, description = a.description, images = true })
        end
        -- (without the download, the copy as it was)
        self:openFile(path, opts)
    end)
end

--- Open an article file in the reader.
function Wikipedia:openFile(path, opts)
    opts = opts or {}
    local a = self.store:article(path)
    if a then
        self.store:addRecent(a.title, a.lang)
        self:unnotifySaved(path)
    end
    local rui, ReaderUI = readerUI()
    local cur = rui and rui.document and rui.document.file
    self:closeHome()
    if cur == path then return end
    if cur and self.store:article(cur) then
        if opts.from == "article" then table.insert(state.back, cur)
        elseif opts.from == "home" then table.insert(state.back, "home") end
    else
        if cur then state.returnTo = cur end
        state.back = { "home" }
    end
    while #state.back > 50 do table.remove(state.back, 1) end
    if opts.position then state.positions[path] = opts.position end
    if opts.after then state.after[path] = opts.after end
    if rui then
        rui:switchDocument(path)
    else
        ReaderUI:showReader(path)
    end
end

--- Back: the article before this one (where you left it), or the front page.
function Wikipedia:goBack()
    local prev = table.remove(state.back)
    while prev and prev ~= "home" and lfs.attributes(prev, "mode") ~= "file" do prev = table.remove(state.back) end
    if not prev or prev == "home" then return self:show() end
    self:openCopy(prev, { from = "back" })
end

function Wikipedia:canGoBack()
    return #state.back > 0
end

--- What Back says: the title of the article before, or "Home".
function Wikipedia:backLabel()
    local prev = state.back[#state.back]
    if prev and prev ~= "home" then
        local a = self.store:article(prev)
        if a then return a.title end
    end
    return _("Home")
end

function Wikipedia:random()
    local lang = self.store:lang()
    self:online(function()
        self:fetch(_("Opening…"), function() return API.random(lang) end, function(title)
            if type(title) == "string" then self:openArticle(title, lang, { from = "home" }) end
        end)
    end)
end

-- ------------------------------------------------------------------ saving

--- Save an article without opening it (from the front page or a link's preview).
function Wikipedia:saveArticle(title, lang, description, done)
    lang = lang or self.store:lang()
    if self.store:findSaved(title, lang) then return done and done(true) end
    local function finish(path, t, d, images)
        self.store:setMeta(path, { title = t, lang = lang, description = d, images = images })
        require("wikibar").toast(T(_("Saved: %1"), t))
        if done then done(true) end
    end
    local cached = self.store:findCached(title, lang)
    if cached and not self.store:needsImages(cached) then
        local path = self.store:savedPath(title, lang)
        if self.store:copy(cached, path) then
            local meta = self.store:meta(cached)
            return finish(path, title, description or meta.description, meta.images)
        end
    end
    self:online(function()
        self:fetch(_("Saving…"), function() return API.summary(lang, title) end, function(info)
            if info == false then return self:notice(T(_("Wikipedia has no article called “%1”."), title)) end
            if self.store:findSaved(info.title, lang) then return done and done(true) end
            local path = self.store:savedPath(info.title, lang)
            local images = self.store:read("images")
            self:download(path, info.title, lang, images, function(ok)
                if ok then finish(path, info.title, info.description or description, images)
                elseif done then done(false) end
            end)
        end)
    end)
end

--- Download an article on the Kindle again: the latest version, with the
-- images setting as it is now. The one being read reloads on the same page.
function Wikipedia:updateArticle(path, done)
    local a = self.store:article(path)
    if not a then return end
    self:online(function()
        local images = self.store:read("images")
        self:download(path, a.title, a.lang, images, function(ok)
            if not ok then return end
            self.store:setMeta(path, { title = a.title, lang = a.lang, description = a.description, images = images })
            require("wikibar").toast(T(_("Updated: %1"), a.title))
            local rui = readerUI()
            if rui and rui.document and rui.document.file == path then rui:reloadDocument() end
            if done then done() end
        end)
    end)
end

--- Remove a saved article from the Kindle.
--- Removed, put aside for Undo (Wikipedia:restoreSaved) for a few seconds.
-- quiet: no Undo of its own when it's the one being read (the caller has one).
function Wikipedia:removeSaved(path, quiet)
    self:unnotifySaved(path)
    local rui = readerUI()
    if rui and rui.document and rui.document.file == path and rui.wikipedia and rui.wikipedia.bar then
        -- Being read: keep reading it, as an unsaved article.
        return rui.wikipedia.bar:unsave(quiet)
    end
    return self.store:putAside(path)
end

--- Undo: the removed article back (and read in it again if it's open, unsaved, in the reader).
function Wikipedia:restoreSaved(path)
    if not self.store:restore(path) then return end
    local open, a = self:openArticleInfo(), self.store:article(path)
    if open and a and not open.saved and open.title == a.title and open.lang == a.lang then
        local rui = readerUI()
        self:openFile(path, { position = rui.rolling and rui.rolling:getBookLocation() })
    end
end

--- "Saved from the web page" taken out once the article is opened or removed.
function Wikipedia:unnotifySaved(path)
    local PS = require("pluginshare")
    local a = self.store:article(path)
    if PS.unnotify and a and a.lang then pcall(PS.unnotify, "wikipedia:save:" .. M.key(a.lang, a.title)) end
end

-- ------------------------------------------------------------------ language and settings

--- Which Wikipedia to use: a list screen of languages (and Other…, a code typed).
function Wikipedia:pickLanguage(done)
    local current = self.store:lang()
    local items = {}
    local function choose(code)
        code = code:lower():gsub("%s", "")
        if code == "" then return end
        self.store:write("lang", code)
        if done then done(code) end
    end
    for __, l in ipairs(M.LANGUAGES) do
        table.insert(items, { text = l[2], right = l[1]:upper(), current = l[1] == current,
            fn = function() choose(l[1]) end })
    end
    table.insert(items, { text = _("Other…"), fn = function()
        require("wikibar").ask{ title = _("Wikipedia language code"),
            subtitle = _("As in its address: fr for fr.wikipedia.org."), hint = "fr", text = current,
            ok = _("Set"), needsText = true, done = choose }
    end })
    self:showPick(_("Language"), items)
end

--- A list to pick from as a full screen with the title bar: items = { { text,
-- right (grey, at the right), current (ticked), fn } }; a pick goes back first.
function Wikipedia:showPick(title, items)
    if state.home then return state.home:showPick(title, items) end
    self:show("pick", nil, { title = title, items = items })
end

function Wikipedia:setToolbar(side)
    self.store:write("toolbar", side)
    self.store:write("toolbar_hidden", false)
    local rui = readerUI()
    if rui and rui.wikipedia and rui.wikipedia.bar then rui.wikipedia.bar:relayout() end
end

-- ------------------------------------------------------------------ for other plugins

--- The Apps launcher's line: "4 saved · Nixon in China".
function Wikipedia:appsLine()
    local parts = {}
    local n = #self.store:listSaved()
    if n > 0 then table.insert(parts, T(N_("1 saved", "%1 saved", n), n)) end
    local r = self.store:recent()[1]
    if r then table.insert(parts, r.title) end
    return table.concat(parts, " · ")
end

--- For the web page's Wikipedia tab.
function Wikipedia:webSaved()
    local out = {}
    for __, a in ipairs(self.store:listSaved()) do
        table.insert(out, { title = a.title, lang = a.lang, description = a.description, size = a.size,
            time = a.time, file = a.path:match("([^/]*)$"), path = a.path })
    end
    return out
end

function Wikipedia:webRecent()
    local out = {}
    for __, e in ipairs(self.store:recent()) do
        table.insert(out, { title = e.title, lang = e.lang, time = e.time,
            saved = self.store:findSaved(e.title, e.lang) ~= nil })
    end
    return out
end

-- Saves started from the web page, by key ("en:Paris"): { state = "saving" |
-- "saved" | "failed", title, message }. Kept while KOReader runs.
local webSaves = {}
local WEB_SAVE_LIMIT = 600   -- seconds: an article with many images on slow Wi-Fi

--- Save from the web page: the download runs in a child process, so the
-- Kindle stays responsive meanwhile; the page asks webSaveState until done.
-- Returns the key to ask about.
function Wikipedia:webSaveStart(title, lang)
    lang = lang or self.store:lang()
    local key = M.key(lang, title)
    local job = webSaves[key]
    if job and job.state == "saving" then return key end
    job = { state = "saving", title = title }
    webSaves[key] = job
    local store = self.store
    local images = store:read("images")
    local pid, fd = ffiutil.runInSubProcess(function(__, write_fd)
        local out
        local info = API.summary(lang, title)
        if info == nil then
            out = "ECan't reach Wikipedia"
        elseif info == false then
            out = "ENo such article"
        else
            local path = store:savedPath(info.title, lang)
            local got = images
            local ok = store:findSaved(info.title, lang) ~= nil
            local cached = not ok and store:findCached(info.title, lang)
            if cached and not store:needsImages(cached) then
                ok = store:copy(cached, path)
                got = store:meta(cached).images
            end
            ok = ok or Epub.build(path, info.title, lang, images)
            out = ok and ("K" .. require("json").encode({ title = info.title, description = info.description,
                path = path, images = got })) or "EDownload failed"
        end
        ffiutil.writeToFD(write_fd, out, true)
    end, true)
    if not pid then
        job.state, job.message = "failed", tostring(fd)
        return key
    end
    local deadline = os.time() + WEB_SAVE_LIMIT
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = not (size and size > 0) and ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() > deadline then
                ffiutil.terminateSubProcess(pid)
                job.state, job.message = "failed", "Took too long"
                return
            end
            return UIManager:scheduleIn(1, check)
        end
        local out = ffiutil.readAllFromFD(fd) or ""
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(0.5, reap) end end
            reap()
        end
        local ok, r = pcall(require("json").decode, out:sub(2))
        if out:sub(1, 1) == "K" and ok and type(r) == "table" and r.path then
            store:setMeta(r.path, { title = r.title, lang = lang, description = r.description, images = r.images })
            job.state, job.title = "saved", r.title
            self:tell(T(_("Saved from the web page: %1"), r.title), "wikipedia:save:" .. key, { saved = r.path })
        else
            job.state, job.message = "failed", out:sub(1, 1) == "E" and out:sub(2) or "Download failed"
            self:tell(T(_("Couldn't save %1 from the web page"), title), "wikipedia:save:" .. key, { tab = "saved" })
        end
    end
    UIManager:scheduleIn(1, check)
    return key
end

--- A notification in the shared list (with Apps): `route` says what a tap opens
-- ({ saved = path } an article, { tab = "saved" } the Saved list).
function Wikipedia:tell(text, key, route)
    local PS = require("pluginshare")
    if not PS.notify then return end
    pcall(PS.notify, { app = "wikipedia", name = _("Wikipedia"), icon = "wikipedia", text = text, key = key,
        route = route, open = function() self:openRoute(route) end })
end

function Wikipedia:openRoute(route)
    route = type(route) == "table" and route or {}
    if route.saved and lfs.attributes(route.saved, "mode") == "file" then
        return self:openFile(route.saved, { from = "home" })
    end
    self:show(route.tab or "saved")
end

function Wikipedia:webSaveState(key)
    return webSaves[key]
end

function Wikipedia:webRemove(file)
    if not file or file:find("/") then return false end
    local path = self.store:folder() .. "/" .. file
    if not self.store:article(path) or lfs.attributes(path, "mode") ~= "file" then return false end
    self:removeSaved(path, true)
    return true
end


return Wikipedia
