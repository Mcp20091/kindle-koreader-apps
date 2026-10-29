--[[--
The Library's screens, one full-screen page whose content changes:

  Home         Continue reading, Recent, the shelves (Reading, To read,
               Finished, On hold, Authors, Series, Collections), folders
  All, Reading, To read, Finished   books as covers or a list, sorted and grouped
  Authors      every author → an author's books
  Collections  KOReader's collections → a collection's books
  Folders      the Home folder and below: folders, books, other files
  a book       its cover, progress, status, reading statistics, what the
               book says about itself, its file; Continue
  Search, Select (bulk Delete, Status, Collection, Copy to, Move to) and the
  folder picker for Move to and Copy to.

The chips across the top switch between the first ones (each a "tab");
anything opened from them goes on a stack that Back walks down. Where it
was left is kept while KOReader runs (and the tab and folder across starts).
]]

local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local Covers = require("librarycovers")
local KO = require("libraryko")
local M = require("librarymodel")
local Page = require("librarypage")
local S = require("librarysettings")

local V = {}

-- Where the Library is: { tab, stack = { view, ... }, select = { [path] = true } or nil }.
local nav = { tab = nil, stack = {}, select = nil }
V.nav = nav

local TABS = {
    { key = "home", text = _("Home") },
    { key = "all", text = _("All") },
    { key = "reading", text = _("Reading") },
    { key = "toread", text = _("To read") },
    { key = "finished", text = _("Finished") },
    { key = "authors", text = _("Authors") },
    { key = "collections", text = _("Collections") },
    { key = "folders", text = _("Folders") },
}

local SHELF_TITLES = { all = _("All books"), reading = _("Reading"), toread = _("To read"), finished = _("Finished"),
    onhold = _("On hold"), recent = _("Recent") }

local SORTS = {
    { label = _("Recently read"), value = "read" },
    { label = _("Recently added"), value = "added" },
    { label = _("Title"), value = "title" },
    { label = _("Author"), value = "author" },
    { label = _("Progress"), value = "progress" },
    { label = _("File name"), value = "name" },
    { label = _("Size"), value = "size" },
}

local function sortName(v)
    for __, s in ipairs(SORTS) do if s.value == v then return s.label end end
    if v == "order" then return _("Collection order") end
    return v
end

local function groupName(v)
    for __, g in ipairs(M.GROUPS) do if g[1] == v then return _(g[2]) end end
    return v
end

local function plural(n, one, many) return n == 1 and one or T(many, n) end

local function top() return nav.stack[#nav.stack] end

-- ------------------------------------------------------------------ opening and closing

--- The Library on top, where it was left (or `view`).
function V.open(plugin, view)
    V.plugin = plugin or V.plugin
    local PS = require("pluginshare")
    if PS.noteRecent then pcall(PS.noteRecent, "library") end
    if view then
        nav.stack = { view }
        nav.tab = view.tab or nav.tab
        nav.select = nil
    elseif #nav.stack == 0 then
        local start = S.get("start", "home")
        local last = S.get("last") or {}
        if start == "last" and last.tab then
            nav.tab = last.tab
            nav.stack = { V.tabView(last.tab) }
            if last.tab == "folders" and last.folder and lfs.attributes(last.folder, "mode") == "directory" then
                nav.stack[1] = { kind = "folder", path = last.folder, tab = "folders" }
            end
        else
            nav.tab = "home"
            nav.stack = { V.tabView("home") }
        end
    end
    if V.screen and not V.screen.closed then
        V.show()
        UIManager:setDirty(V.screen, "full")
        return V.screen
    end
    KO.flashOnUncover()
    V.screen = Page:new{
        build = function(page) V.build(page) end,
        back = function() V.back() end,
        home = function() V.goHome() end,
        menu = function() V.more() end,
        refresh = function()
            M.forget()
            Covers.release()
            local v = top()
            if v then v.list, v.rlist, v.err, v.page = nil, nil, nil, nil end
        end,
        close_callback = function(page)
            if V.screen == page then V.screen = nil end
            if V.plugin and V.plugin.screen == page then V.plugin.screen = nil end
            Covers.stop()
            Covers.release()
        end,
    }
    if V.plugin then V.plugin.screen = V.screen end
    UIManager:show(V.screen, "full")
    return V.screen
end

function V.close()
    if V.screen and not V.screen.closed then V.screen:onClose() end
end

--- Draw the view on top again (page 1 when `fresh`).
function V.show(fresh)
    local s = V.screen
    if not s or s.closed then return end
    if fresh then s.page = 1 end
    s:redraw("full")
end

function V.tabView(key)
    if key == "home" then return { kind = "home", tab = "home" } end
    if key == "authors" then return { kind = "authors", tab = "authors" } end
    if key == "collections" then return { kind = "collections", tab = "collections" } end
    if key == "folders" then return { kind = "folder", path = M.home(), tab = "folders" } end
    return { kind = "shelf", shelf = key, tab = key }
end

local function remember()
    local v = nav.stack[1]
    S.set("last", { tab = nav.tab, folder = v and v.kind == "folder" and (top().kind == "folder" and top().path or v.path) or nil })
end

function V.switchTab(key)
    nav.tab = key
    nav.stack = { V.tabView(key) }
    nav.select = nil
    remember()
    V.show(true)
end

function V.push(view)
    view.tab = nav.tab
    -- (the page it was on, for Back)
    local cur = top()
    if cur and V.screen then cur.page = V.screen.page end
    table.insert(nav.stack, view)
    nav.select = nil
    if view.kind == "folder" then remember() end
    V.show(true)
end

--- Back: Select off; one view back; a tab back to Home; Home to the launcher (or
-- KOReader's file browser without it).
function V.back()
    if nav.select then
        nav.select = nil
        return V.show()
    end
    -- (Find details online: Back from its first page ends it, as Cancel)
    local cur = top()
    if cur and cur.run then
        local below = nav.stack[#nav.stack - 1]
        if not (below and below.run == cur.run) then return V.stopRun(cur.run) end
    end
    if #nav.stack > 1 then
        table.remove(nav.stack)
        local v = top()
        if V.screen then V.screen.page = v.page or 1 end
        remember()
        return V.show()
    end
    local v = top()
    if v and v.kind == "folder" and v.path ~= M.home() then
        -- (Folders opened elsewhere: up a folder, to the Home folder at most)
        local parent = v.path:match("^(.*)/[^/]+$")
        if parent and parent ~= "" and #parent >= #M.home() then
            nav.stack[1] = { kind = "folder", path = parent, tab = "folders" }
            remember()
            return V.show(true)
        end
    end
    if nav.tab ~= "home" then return V.switchTab("home") end
    V.close()
    KO.home()
end

function V.goHome()
    nav.select = nil
    V.close()
    KO.home()
end

-- ------------------------------------------------------------------ the page drawn

function V.build(page)
    local v = top()
    if not v then return end
    page.title, page.subtitle, page.bar_buttons, page.buttons, page.status = nil, nil, nil, nil, nil
    local fn = V["view_" .. v.kind]
    page.items = {}
    if fn then fn(page, v) end
    if nav.select and v.kind ~= "server" then V.selectBar(page, v) end
end

local function chips(items)
    local out = {}
    for __, t in ipairs(TABS) do
        table.insert(out, { text = t.text, on = nav.tab == t.key, fn = function()
            if nav.tab == t.key and #nav.stack == 1 then return end
            V.switchTab(t.key)
        end })
    end
    table.insert(items, { chips = out })
end

local function showCovers() return S.get("view", "covers") == "covers" end

local function layoutButton()
    return { showCovers() and "list" or "layout-grid", function()
        S.set("view", showCovers() and "list" or "covers")
        V.show(true)
    end }
end

local function searchButton() return { "search", function() V.askSearch() end } end

local function selectButton(listFn)
    -- (also what ⋮ > Select and Select all tick)
    nav.selectAll = listFn
    return { "square-check", function()
        nav.select = {}
        nav.selectAll = listFn
        V.show()
    end }
end

-- The ways a list can be sorted and grouped (one per page: "shelf:all", "author", …).
local function sortKeyOf(v)
    if v.kind == "shelf" then return "shelf:" .. v.shelf end
    return v.kind
end

local DEFAULT_SORT = { ["shelf:recent"] = "read", ["shelf:all"] = "title", ["shelf:reading"] = "read", ["shelf:toread"] = "added",
    ["shelf:finished"] = "read", ["shelf:onhold"] = "read", author = "title", series = "series", collection = "order", folder = "name" }

local function sortOf(v) return S.of("sort", sortKeyOf(v), DEFAULT_SORT[sortKeyOf(v)] or "title") end
local function groupOf(v) return S.of("group", sortKeyOf(v), "none") end

local function sortButton(v, noGroup)
    return { "arrow-up-down", function() V.sortMenu(v, noGroup) end }
end

function V.sortMenu(v, noGroup)
    local key = sortKeyOf(v)
    local items = {
        { text = T(_("Sort by: %1"), sortName(sortOf(v))), fn = function()
            local opts = {}
            if v.kind == "collection" then table.insert(opts, { label = _("Collection order"), value = "order" }) end
            if v.kind == "series" then table.insert(opts, { label = _("Series order"), value = "series" }) end
            for __, s in ipairs(SORTS) do table.insert(opts, s) end
            KO.choose(_("Sort by"), opts, sortOf(v), function(val)
                S.setOf("sort", key, val)
                V.show(true)
            end, function() V.sortMenu(v, noGroup) end)
        end },
    }
    if not noGroup then
        table.insert(items, { text = T(_("Group by: %1"), groupName(groupOf(v))), fn = function()
            local opts = {}
            for __, g in ipairs(M.GROUPS) do table.insert(opts, { label = _(g[2]), value = g[1] }) end
            KO.choose(_("Group by"), opts, groupOf(v), function(val)
                S.setOf("group", key, val)
                V.show(true)
            end, function() V.sortMenu(v, noGroup) end)
        end })
    end
    table.insert(items, { text = _("Covers"), checked = showCovers(), fn = function() S.set("view", "covers") V.show(true) end })
    table.insert(items, { text = _("List"), checked = not showCovers(), fn = function() S.set("view", "list") V.show(true) end })
    KO.list(_("Sort and group"), items)
end

local function sorted(list, v)
    local how = sortOf(v)
    if how == "order" or how == "series" then return list end
    return M.sort(list, how)
end

-- ------------------------------------------------------------------ books on a page

local function toggleSelect(path)
    if nav.select[path] then nav.select[path] = nil else nav.select[path] = true end
    V.show()
end

--- What a tap on a book does: in Select, tick it; else its page (or open it, `open`).
local function tapBook(b, open)
    if nav.select then return toggleSelect(b.path) end
    if open then return V.openBook(b.path) end
    V.push({ kind = "book", path = b.path })
end

local function barOf(b)
    local s = M.status(b.path)
    if s == "reading" or s == "abandoned" then return M.progress(b.path) or 0 end
end

-- In Select: true or false (ticked or not); nil out of it.
local function ticked(path)
    if not nav.select then return nil end
    return nav.select[path] == true
end

--- A list of books, in groups when grouped: covers or rows.
local function addBooks(items, list, v, opts)
    opts = opts or {}
    local groups = M.group(list, opts.noGroup and "none" or groupOf(v))
    for __, g in ipairs(groups) do
        if g.label then
            -- (the heading stays on the page with its first row of covers)
            table.insert(items, { band = g.label:upper(), right = tostring(#g.books), menu = true, keep = showCovers() and 220 or 70,
                tap = function() V.groupMenu(g) end })
        elseif opts.band then
            table.insert(items, { band = opts.band, right = plural(#list, _("1 book"), _("%1 books")) })
        end
        if #g.books == 0 then
            table.insert(items, { message = opts.empty or _("No books here.") })
        elseif showCovers() then
            table.insert(items, { covers = g.books, ticks = nav.select,
                sub = function(b) return M.stateText(b.path) end, bar = barOf,
                tap = function(b) tapBook(b, opts.openOnTap) end,
                hold = function(b) V.bookMenu(b) end })
        else
            for __, b in ipairs(g.books) do
                local a = M.authors(b)
                local line = (a and (a:gsub("\n", ", ")) .. " · " or "") .. M.stateText(b.path)
                table.insert(items, { book = b, sub = line, bar = barOf(b),
                    tick = ticked(b.path),
                    tap = function() tapBook(b, opts.openOnTap) end, hold = function() V.bookMenu(b) end })
            end
        end
    end
    if #list == 0 and #groups == 1 and not groups[1].label and not opts.band then
        table.insert(items, { message = opts.empty or _("No books here.") })
    end
end

--- A group's heading tapped: Select these, Make a collection, its own page.
function V.groupMenu(g)
    local paths = {}
    for __, b in ipairs(g.books) do table.insert(paths, b.path) end
    local items = {
        { text = _("Select these"), fn = function()
            nav.select = nav.select or {}
            for __, p in ipairs(paths) do nav.select[p] = true end
            V.show()
        end },
        { text = _("Make a collection"), fn = function()
            KO.ask{ title = _("Make a collection"), subtitle = plural(#paths, _("Of 1 book"), _("Of %1 books")),
                text = g.label, ok = _("Make"), okIcon = "plus", done = function(name)
                    M.collect(paths, name, true)
                    KO.toast(T(_("Made “%1”"), name))
                    V.show()
                end }
        end },
    }
    if g.kind == "author" then table.insert(items, { text = T(_("Open %1"), g.label), fn = function() V.push({ kind = "author", name = g.value }) end }) end
    if g.kind == "series" then table.insert(items, { text = T(_("Open %1"), g.label), fn = function() V.push({ kind = "series", name = g.value }) end }) end
    if g.kind == "folder" then table.insert(items, { text = _("Open the folder"), fn = function() V.push({ kind = "folder", path = g.value }) end }) end
    KO.list(g.label, items)
end

-- ------------------------------------------------------------------ Home

function V.view_home(page, v)
    page.title = _("Library")
    page.bar_buttons = { searchButton() }
    local items = page.items
    chips(items)
    local books = M.books()
    local recent = M.recent(7)
    local last = recent[1]
    if last then
        local sub = M.stateText(last.path)
        local st = M.stats(last.path)
        local p = M.progress(last.path)
        local pages = M.pages(last)
        if p and pages then sub = T(_("%1% · page %2 of %3"), math.floor(p * 100 + 0.5), math.max(1, math.floor(p * pages + 0.5)), pages) end
        if st and st.pace and p and pages then
            local left = (pages * (1 - p)) / st.pace * 3600
            if left > 60 then sub = sub .. " · " .. T(_("About %1 left"), M.duration(left)) end
        end
        table.insert(items, { continue = last, sub = sub, tap = function() V.openBook(last.path) end, hold = function() V.bookMenu(last) end })
    end
    if #recent > 1 then
        table.insert(items, { band = _("RECENT"), right = _("See all"), tap = function() V.push({ kind = "shelf", shelf = "recent" }) end })
        local strip = {}
        for i = 2, #recent do table.insert(strip, recent[i]) end
        table.insert(items, { strip = strip, tap = function(b) V.push({ kind = "book", path = b.path }) end, hold = function(b) V.bookMenu(b) end })
    end
    -- Servers and catalogs, then the folders: above the books (on the first page), or after
    -- them (Library settings > Home starts with).
    local function places()
        V.serverItems(items)
        table.insert(items, { band = _("FOLDERS") })
        local home = M.home()
        table.insert(items, { icon = "folder", text = _("Home folder"), sub = M.folderSummary(home), chevron = true,
            tap = function() V.switchTab("folders") end })
        for __, f in ipairs(M.shortcuts()) do
            if f.path ~= home then
                table.insert(items, { icon = "folder-heart", text = f.name, sub = M.shortPath(f.path), chevron = true,
                    tap = function() V.push({ kind = "folder", path = f.path }) end })
            end
        end
    end
    local placesFirst = S.get("home_first", "places") == "places"
    if placesFirst then places() end
    table.insert(items, { band = _("BOOKS"), right = plural(#books, _("1 book"), _("%1 books")) })
    local function titles(list)
        local t = {}
        for i = 1, math.min(3, #list) do table.insert(t, M.title(list[i])) end
        local s = table.concat(t, ", ")
        if #list > 3 then s = T(_("%1 and %2 more"), s, #list - 3) end
        return s
    end
    local shelves = {
        { "reading", "book-open", _("Reading") },
        { "toread", "bookmark", _("To read") },
        { "finished", "check", _("Finished") },
        { "onhold", "pause", _("On hold") },
    }
    for __, s in ipairs(shelves) do
        local list = M.sort(M.shelf(s[1]), "read")
        if #list > 0 or s[1] ~= "onhold" then
            table.insert(items, { icon = s[2], text = s[3], sub = #list > 0 and titles(list) or _("None yet"), right = tostring(#list), chevron = true,
                tap = function() if s[1] == "onhold" then V.push({ kind = "shelf", shelf = "onhold" }) else V.switchTab(s[1]) end end })
        end
    end
    local authors = M.authorList()
    table.insert(items, { icon = "users", text = _("Authors"), sub = plural(#authors, _("1 author"), _("%1 authors")), chevron = true,
        tap = function() V.switchTab("authors") end })
    local series = {}
    for __, b in ipairs(books) do
        local s = M.series(b)
        if s and not series[s] then series[s] = true table.insert(series, s) end
    end
    if #series > 0 then
        table.sort(series, function(a, b) return M.titleKey(a) < M.titleKey(b) end)
        table.insert(items, { icon = "layers", text = _("Series"), sub = table.concat(series, ", ", 1, math.min(3, #series)), right = tostring(#series),
            chevron = true, tap = function() V.push({ kind = "serieslist" }) end })
    end
    local colls = M.collections()
    local names = {}
    for i = 1, math.min(3, #colls) do table.insert(names, colls[i].label) end
    table.insert(items, { icon = "library", text = _("Collections"), sub = #colls > 0 and table.concat(names, ", ") or _("None yet"), chevron = true,
        tap = function() V.switchTab("collections") end })
    if not placesFirst then places() end
    local pdfs = 0
    for __, b in ipairs(books) do if M.ext(b.name) == "pdf" then pdfs = pdfs + 1 end end
    page.status = function()
        local left = plural(#books, _("1 book"), _("%1 books"))
        if pdfs > 0 then left = left .. " · " .. plural(pdfs, _("1 PDF"), _("%1 PDFs")) end
        local right
        if last then
            local when = M.lastRead(last.path)
            right = T(_("Last read: %1"), M.title(last)) .. (when and (", " .. (M.when(when) or "")) or "")
        end
        return left, right
    end
end

-- ------------------------------------------------------------------ shelves

function V.view_shelf(page, v)
    local shelf = v.shelf
    local list
    if shelf == "recent" then list = M.recent(200) else list = M.shelf(shelf) end
    list = sorted(list, v)
    page.title = shelf == "all" and _("Library") or SHELF_TITLES[shelf]
    page.bar_buttons = { searchButton(), sortButton(v), layoutButton() }
    nav.selectAll = function() return list end
    local isTab = nav.stack[1] == v
    if isTab then chips(page.items) end
    local empty = ({ reading = _("Nothing being read. Books you open show here."), toread = _("Every book has been opened."),
        finished = _("No finished books yet."), onhold = _("No books on hold."), recent = _("No books read yet."),
        all = T(_("No books in %1 yet. Copy some there (USB, the web page or Syncthing)."), M.home()) })[shelf]
    addBooks(page.items, list, v, { empty = empty, band = groupOf(v) == "none" and (SHELF_TITLES[shelf]):upper() or nil })
    page.status = function()
        return plural(#list, _("1 book"), _("%1 books")) .. " · " .. T(_("sorted by %1"), sortName(sortOf(v)):lower()),
            M.state.partial and _("Some folders weren't read (too many files)") or nil
    end
end

-- ------------------------------------------------------------------ authors and series

function V.view_authors(page, v)
    page.title = _("Authors")
    page.bar_buttons = { searchButton() }
    chips(page.items)
    local authors = M.authorList()
    table.insert(page.items, { band = _("AUTHORS"), right = tostring(#authors) })
    if #authors == 0 then table.insert(page.items, { message = _("No authors yet: the Cover browser reads them from the books.") }) end
    for __, a in ipairs(authors) do
        local counts = { reading = 0, complete = 0, new = 0, abandoned = 0 }
        for __, b in ipairs(a.books) do
            local s = M.status(b.path)
            counts[s] = (counts[s] or 0) + 1
        end
        local parts = {}
        if counts.reading > 0 then table.insert(parts, T(_("%1 reading"), counts.reading)) end
        if counts.complete > 0 then table.insert(parts, T(_("%1 finished"), counts.complete)) end
        if counts.new > 0 then table.insert(parts, T(_("%1 to read"), counts.new)) end
        if counts.abandoned > 0 then table.insert(parts, T(_("%1 on hold"), counts.abandoned)) end
        table.insert(page.items, { icon = "user", text = a.name, sub = table.concat(parts, " · "),
            right = plural(#a.books, _("1 book"), _("%1 books")), chevron = true,
            tap = function() V.push({ kind = "author", name = a.name }) end })
    end
    page.status = function() return plural(#authors, _("1 author"), _("%1 authors")) .. " · " .. _("by last name") end
end

function V.view_author(page, v)
    local list, name = M.byAuthor(v.name)
    list = sorted(list, v)
    page.title = name
    page.bar_buttons = { sortButton(v), layoutButton(), selectButton(function() return list end) }
    nav.selectAll = function() return list end
    addBooks(page.items, list, v, { band = groupOf(v) == "none" and _("BOOKS") or nil })
    page.status = function() return plural(#list, _("1 book"), _("%1 books")) .. " · " .. T(_("sorted by %1"), sortName(sortOf(v)):lower()) end
end

function V.view_serieslist(page, v)
    page.title = _("Series")
    local by = {}
    local names = {}
    for __, b in ipairs(M.books()) do
        local s = M.series(b)
        if s then
            if not by[s] then by[s] = {} table.insert(names, s) end
            table.insert(by[s], b)
        end
    end
    table.sort(names, function(a, b) return M.titleKey(a) < M.titleKey(b) end)
    table.insert(page.items, { band = _("SERIES"), right = tostring(#names) })
    for __, s in ipairs(names) do
        local a = M.firstAuthor(by[s][1])
        table.insert(page.items, { icon = "layers", text = s, sub = a, right = plural(#by[s], _("1 book"), _("%1 books")), chevron = true,
            tap = function() V.push({ kind = "series", name = s }) end })
    end
    page.status = function() return plural(#names, _("1 series"), _("%1 series")) end
end

function V.view_series(page, v)
    local list = sorted(M.seriesBooks(v.name), v)
    page.title = v.name
    page.bar_buttons = { sortButton(v, true), layoutButton(), selectButton(function() return list end) }
    addBooks(page.items, list, v, { band = _("BOOKS"), noGroup = true })
    page.status = function() return plural(#list, _("1 book"), _("%1 books")) end
end

-- ------------------------------------------------------------------ collections

function V.view_collections(page, v)
    page.title = _("Collections")
    page.bar_buttons = { { "plus", function() V.newCollection() end } }
    chips(page.items)
    local colls = M.collections()
    table.insert(page.items, { band = _("COLLECTIONS"), right = tostring(#colls) })
    for __, c in ipairs(colls) do
        local books = M.collectionBooks(c.name)
        local t = {}
        for i = 1, math.min(3, #books) do table.insert(t, M.title(books[i])) end
        local sub = table.concat(t, ", ")
        if #books > 3 then sub = T(_("%1 and %2 more"), sub, #books - 3) end
        local fav = c.name == M.favoritesName()
        table.insert(page.items, { icon = fav and "star" or "library", text = c.label, sub = #books > 0 and sub or _("Empty"),
            right = plural(#books, _("1 book"), _("%1 books")), chevron = true,
            tap = function() V.push({ kind = "collection", name = c.name, label = c.label }) end,
            hold = function() V.collectionMenu(c) end })
    end
    table.insert(page.items, { note = _("KOReader's collections: the same ones as in KOReader and on the web page. Hold one to rename or delete it. To make one from a group of books, group them (the sort button, Group by), then tap the group's heading.") })
    page.status = function() return plural(#colls, _("1 collection"), _("%1 collections")) end
end

function V.view_collection(page, v)
    local list = M.collectionBooks(v.name)
    list = sorted(list, v)
    page.title = v.label or v.name
    page.bar_buttons = { sortButton(v), layoutButton(), selectButton(function() return list end) }
    addBooks(page.items, list, v, { band = groupOf(v) == "none" and _("BOOKS") or nil,
        empty = _("Nothing in it yet. Hold a book, then Add to a collection.") })
    page.status = function() return plural(#list, _("1 book"), _("%1 books")) end
end

function V.newCollection(paths, after)
    KO.ask{ title = _("New collection"), hint = _("Name"), ok = _("Make"), okIcon = "plus", done = function(name)
        if M.rc() and M.rc().coll[name] then return KO.toast(T(_("There's already a collection called “%1”"), name)) end
        M.collect(paths or {}, name, true)
        if after then after(name) else V.show() end
    end }
end

function V.collectionMenu(c)
    local fav = c.name == M.favoritesName()
    local items = {
        { text = _("Open"), fn = function() V.push({ kind = "collection", name = c.name, label = c.label }) end },
        { text = _("Rename"), enabled = not fav, fn = function()
            KO.ask{ title = _("Rename"), text = c.name, ok = _("Rename"), done = function(name)
                M.renameCollection(c.name, name)
                V.show()
            end }
        end },
        { text = _("Delete"), enabled = not fav, fn = function()
            local keep = M.removeCollection(c.name)
            V.show()
            if keep then KO.undo(T(_("Deleted “%1”"), c.label), function()
                M.restoreCollection(c.name, keep)
                V.show()
            end) end
        end },
    }
    KO.list(c.label, items)
end

-- ------------------------------------------------------------------ folders

local function inside(path, root) return path == root or path:sub(1, #root + 1) == root .. "/" end

function V.view_folder(page, v)
    local dir = v.path
    local home = M.home()
    local f = M.folder(dir)
    local name = dir == home and _("Folders") or (dir:match("[^/]+$") or dir)
    page.title = name
    page.subtitle = M.shortPath(dir)
    local everything = {}
    for __, d in ipairs(f.dirs) do table.insert(everything, d) end
    for __, b in ipairs(f.books) do table.insert(everything, b) end
    for __, b in ipairs(f.files) do table.insert(everything, b) end
    page.bar_buttons = { searchButton(), sortButton(v, true), { "folder-plus", function() V.newFolder(dir) end },
        selectButton(function() return everything end) }
    local items = page.items
    local isTab = nav.stack[1] == v and dir == home
    if isTab then chips(items) end
    local parent = dir:match("^(.*)/[^/]+$")
    local locked = G_reader_settings:isTrue("lock_home_folder") and dir == home
    if parent and parent ~= "" and not locked and not nav.select then
        table.insert(items, { icon = "folder-up", text = _("Up one folder"), tap = function()
            if #nav.stack > 1 then
                -- (opened from elsewhere: this view becomes its parent)
                top().path = parent
                V.show(true)
            else
                nav.stack[1] = { kind = "folder", path = parent, tab = "folders" }
                remember()
                V.show(true)
            end
        end })
    end
    local function sel(p)
        if not nav.select then return nil end
        return nav.select[p] == true
    end
    if dir == home and not nav.select then V.serverItems(items, true) end
    if #f.dirs > 0 then
        table.insert(items, { band = _("FOLDERS"), right = tostring(#f.dirs) })
        for __, d in ipairs(f.dirs) do
            table.insert(items, { icon = "folder", text = d.name, sub = M.folderSummary(d.path), chevron = not nav.select, tick = sel(d.path),
                tap = function()
                    if nav.select then return toggleSelect(d.path) end
                    if #nav.stack > 1 then V.push({ kind = "folder", path = d.path })
                    else
                        nav.stack[1] = { kind = "folder", path = d.path, tab = "folders" }
                        remember()
                        V.show(true)
                    end
                end, hold = function() V.folderMenu(d) end })
        end
    end
    local books = M.sort(f.books, sortOf(v))
    if #books > 0 then
        table.insert(items, { band = _("BOOKS"), right = tostring(#books) })
        for __, b in ipairs(books) do
            local title = M.title(b)
            local a = M.firstAuthor(b)
            local bare = b.name:gsub("%.[^.]+$", "")
            local second = (title ~= bare or a) and (title .. (a and (" · " .. a) or "")) or M.format(b.name)
            table.insert(items, { book = b, text = b.name, sub = second, right = M.size(b.size), right2 = M.stateText(b.path), tick = sel(b.path),
                tap = function() if nav.select then toggleSelect(b.path) else V.openBook(b.path) end end,
                hold = function() V.bookMenu(b) end })
        end
    end
    local files = M.sort(f.files, sortOf(v) == "size" and "size" or "name")
    if #files > 0 then
        table.insert(items, { band = _("OTHER FILES"), right = tostring(#files) })
        for __, b in ipairs(files) do
            local low = b.name:lower()
            local isImage = low:match("%.png$") or low:match("%.jpe?g$") or low:match("%.gif$") or low:match("%.webp$")
            table.insert(items, { icon = isImage and "image" or "file-text",
                text = b.name, sub = M.size(b.size) .. " · " .. (M.when(b.mtime) or ""), tick = sel(b.path),
                tap = function() if nav.select then toggleSelect(b.path) else V.fileMenu(b) end end, hold = function() V.fileMenu(b) end })
        end
    end
    if #f.dirs + #books + #files == 0 then table.insert(items, { message = _("This folder is empty.") }) end
    local total = 0
    for __, b in ipairs(f.books) do total = total + (b.size or 0) end
    for __, b in ipairs(f.files) do total = total + (b.size or 0) end
    page.status = function()
        local parts = {}
        if #f.dirs > 0 then table.insert(parts, plural(#f.dirs, _("1 folder"), _("%1 folders"))) end
        local nf = #f.books + #f.files
        if nf > 0 or #f.dirs == 0 then table.insert(parts, plural(nf, _("1 file"), _("%1 files"))) end
        if nf > 0 then table.insert(parts, M.size(total)) end
        return table.concat(parts, " · "), T(_("Sorted by %1"), sortName(sortOf(v)):lower())
    end
end

function V.newFolder(dir, after)
    KO.ask{ title = _("New folder"), hint = _("Name"), ok = _("Make"), okIcon = "folder-plus", done = function(name)
        if name:find("/") then return KO.toast(_("A folder's name can't have a /")) end
        local to, why = M.newFolder(dir, name)
        if not to then return KO.toast(why == "exists" and T(_("“%1” is already there"), name) or _("Couldn't make the folder")) end
        if after then after(to) else V.show() end
    end }
end

function V.folderMenu(d)
    local shortcuts = G_reader_settings:readSetting("folder_shortcuts") or {}
    local isShortcut = shortcuts[d.path] ~= nil
    KO.list(d.name, {
        { text = _("Open"), fn = function() V.push({ kind = "folder", path = d.path }) end },
        { text = isShortcut and _("Remove from favorite folders") or _("Add to favorite folders"), fn = function()
            local s = G_reader_settings:readSetting("folder_shortcuts") or {}
            if isShortcut then s[d.path] = nil else s[d.path] = { text = d.name, time = os.time() } end
            G_reader_settings:saveSetting("folder_shortcuts", s)
            KO.toast(isShortcut and _("Removed from favorite folders") or _("Added to favorite folders"))
            V.show()
        end },
        { text = _("Move to…"), fn = function() V.pickFolder("move", { d.path }) end },
        { text = _("Copy to…"), fn = function() V.pickFolder("copy", { d.path }) end },
        { text = _("Rename"), fn = function() V.rename(d.path, true) end },
        { text = _("Set as Home folder"), fn = function()
            G_reader_settings:saveSetting("home_dir", d.path)
            M.forget()
            KO.toast(_("Home folder set"))
            V.show()
        end },
        { text = _("Delete"), fn = function() V.delete({ d.path }) end },
    })
end

function V.fileMenu(b)
    KO.list(b.name, {
        { text = _("Open"), enabled = M.canOpen(b.name), fn = function() V.openBook(b.path) end },
        { text = _("Move to…"), fn = function() V.pickFolder("move", { b.path }) end },
        { text = _("Copy to…"), fn = function() V.pickFolder("copy", { b.path }) end },
        { text = _("Rename"), fn = function() V.rename(b.path) end },
        { text = _("Delete"), fn = function() V.delete({ b.path }) end },
    })
end

-- ------------------------------------------------------------------ the folder picker

--- Move to… / Copy to…: folders only, then Move here (Copy here).
-- (mode "download": paths are a server's books, `server` the server; "choose":
-- the download folder, no paths)
function V.pickFolder(mode, paths, start, server)
    local from = type(paths[1]) == "string" and paths[1]:match("^(.*)/[^/]+$")
    V.push({ kind = "pick", mode = mode, paths = paths, path = start or from or M.home(), from = server })
end

function V.view_pick(page, v)
    if v.server then return V.view_pickServer(page, v) end
    local n = #v.paths
    page.title = v.mode == "move" and plural(n, _("Move 1 item"), _("Move %1 items")) or v.mode == "choose" and _("Download folder")
        or plural(n, _("Copy 1 item"), _("Copy %1 items"))
    page.subtitle = M.shortPath(v.path)
    local f = M.folder(v.path)
    local parent = v.path:match("^(.*)/[^/]+$")
    local moving = {}
    if v.mode == "copy" or v.mode == "move" then
        for __, p in ipairs(v.paths) do moving[p] = true end
    end
    local locked = G_reader_settings:isTrue("lock_home_folder") and v.path == M.home()
    if parent and parent ~= "" and not locked then
        table.insert(page.items, { icon = "folder-up", text = _("Up one folder"), tap = function()
            v.path = parent
            V.show(true)
        end })
    end
    -- (books from here can go onto a server)
    local servers = (v.mode == "copy" or v.mode == "move") and v.path == M.home() and require("libraryservers").servers() or {}
    if #servers > 0 then
        local R = require("libraryservers")
        table.insert(page.items, { band = _("SERVERS") })
        for __, s in ipairs(servers) do
            table.insert(page.items, { icon = s.type == "ftp" and "server" or "globe", text = R.name(s), sub = R.label(s), chevron = true,
                tap = function()
                    v.server, v.rpath, v.rlist, v.err = s, R.folder(s.url), nil, nil
                    V.show(true)
                end })
        end
        table.insert(page.items, { band = _("FOLDERS") })
    end
    for __, d in ipairs(f.dirs) do
        -- (a folder can't go inside itself)
        local own = false
        for p in pairs(moving) do if inside(d.path, p) then own = true end end
        if not own then
            table.insert(page.items, { icon = "folder", text = d.name, sub = M.folderSummary(d.path), chevron = true, tap = function()
                v.path = d.path
                V.show(true)
            end })
        end
    end
    if #f.dirs == 0 then table.insert(page.items, { note = _("No folders in here.") }) end
    page.buttons = {
        { icon = "folder-plus", text = _("New folder"), fn = function()
            V.newFolder(v.path, function(to) v.path = to V.show(true) end)
        end },
        { icon = "x", text = _("Cancel"), fn = function() V.back() end },
        { icon = v.mode == "move" and "folder-input" or v.mode == "choose" and "check" or "copy",
            text = v.mode == "move" and _("Move here") or v.mode == "choose" and _("Choose here") or _("Copy here"), primary = true,
            fn = function() V.doPick(v) end },
    }
end

function V.doPick(v)
    if v.mode == "download" or v.mode == "choose" then
        table.remove(nav.stack)
        nav.select = nil
        if v.mode == "choose" then
            require("libraryservers").setDownloadDir(v.path)
            V.show()
            return KO.toast(T(_("Downloads go to %1"), v.path:match("[^/]+$") or v.path))
        end
        return V.download(v.from, v.paths, v.path)
    end
    local done, failed, same = 0, {}, 0
    for __, p in ipairs(v.paths) do
        local dir = p:match("^(.*)/[^/]+$")
        if v.mode == "move" and dir == v.path then
            same = same + 1
        else
            local to, why
            if v.mode == "move" then to, why = M.moveTo(p, v.path) else to, why = M.copyTo(p, v.path) end
            if to then done = done + 1 else table.insert(failed, (p:match("[^/]+$") or p) .. (why == "exists" and _(" (already there)") or "")) end
        end
    end
    table.remove(nav.stack)
    nav.select = nil
    M.forget()
    V.show()
    local name = v.path:match("[^/]+$") or v.path
    if #failed > 0 then
        KO.message(table.concat(failed, "\n"), v.mode == "move" and _("Not moved") or _("Not copied"))
    elseif done > 0 then
        KO.toast(v.mode == "move" and T(_("Moved to %1"), name) or T(_("Copied to %1"), name))
    end
end

-- ------------------------------------------------------------------ Select

function V.selectBar(page, v)
    local n = 0
    for __ in pairs(nav.select) do n = n + 1 end
    page.title = n == 0 and _("Select") or plural(n, _("1 selected"), _("%1 selected"))
    page.subtitle = nil
    page.bar_buttons = { { "check", function()
        local all = nav.selectAll and nav.selectAll() or {}
        local every = n > 0 and n >= #all
        nav.select = {}
        if not every then for __, b in ipairs(all) do nav.select[b.path] = true end end
        V.show()
    end } }
    local function paths()
        local out = {}
        for p in pairs(nav.select) do table.insert(out, p) end
        table.sort(out)
        return out
    end
    local function need(fn)
        return function()
            local list = paths()
            if #list == 0 then return KO.toast(_("Tick some first")) end
            fn(list)
        end
    end
    page.buttons = {
        { icon = "trash-2", text = _("Delete"), fn = need(function(list) V.delete(list) end) },
        { icon = "check", text = _("Status"), fn = need(function(list) V.statusMenu(list) end) },
        { icon = "library", text = _("Collection"), fn = need(function(list) V.collectMenu(list) end) },
        { icon = "ellipsis-vertical", text = _("More"), fn = need(function(list)
            KO.list(plural(#list, _("1 selected"), _("%1 selected")), {
                { text = _("Copy to…"), fn = function() V.pickFolder("copy", list) end },
                { text = _("Find details online"), fn = function() V.findDetails(list) end },
            })
        end) },
        { icon = "folder-input", text = _("Move to"), primary = true, fn = need(function(list) V.pickFolder("move", list) end) },
    }
    page.status = nil
end

-- ------------------------------------------------------------------ changing books

local function booksOnly(list)
    local out = {}
    for __, p in ipairs(list) do if lfs.attributes(p, "mode") == "file" and M.isBook(p) then table.insert(out, p) end end
    return out
end

function V.statusMenu(list, back)
    list = booksOnly(list)
    if #list == 0 then return KO.toast(_("None of those are books")) end
    local function set(status)
        for __, p in ipairs(list) do M.setStatus(p, status) end
        nav.select = nil
        V.show()
        KO.toast(plural(#list, T(_("Marked as %1"), M.STATUS_NAMES[status]:lower()), T(_("%1 marked as %2"), #list, M.STATUS_NAMES[status]:lower())))
    end
    local one = #list == 1 and M.status(list[1]) or nil
    KO.list(_("Status"), {
        { text = _("Reading"), checked = one == "reading", fn = function() set("reading") end },
        { text = _("On hold"), checked = one == "abandoned", fn = function() set("abandoned") end },
        { text = _("Finished"), checked = one == "complete", fn = function() set("complete") end },
        { text = _("Reset reading progress…"), fn = function()
            KO.confirm{ title = _("Reset reading progress?"), text = plural(#list, _("The book starts from the beginning again. Its highlights and notes stay."),
                _("%1 books start from the beginning again. Their highlights and notes stay.")),
                ok = _("Reset"), danger = true, onOk = function()
                    for __, p in ipairs(list) do M.resetProgress(p) end
                    nav.select = nil
                    V.show()
                end }
        end },
    }, back)
end

--- Into a collection (or a new one), or out of one they're all in.
function V.collectMenu(list, back)
    list = booksOnly(list)
    if #list == 0 then return KO.toast(_("None of those are books")) end
    local items = {}
    for __, c in ipairs(M.collections()) do
        local all = true
        for __, p in ipairs(list) do if not M.inCollection(p, c.name) then all = false break end end
        table.insert(items, { text = c.label, checked = all, fn = function()
            M.collect(list, c.name, not all)
            nav.select = nil
            V.show()
            KO.toast(all and T(_("Taken out of %1"), c.label) or T(_("Added to %1"), c.label))
        end })
    end
    table.insert(items, { text = _("New collection…"), fn = function()
        V.newCollection(list, function(name)
            nav.select = nil
            V.show()
            KO.toast(T(_("Added to %1"), name))
        end)
    end })
    KO.list(_("Collection"), items, back)
end

--- Delete at once, with Undo (without the launcher's Undo: asked first).
function V.delete(list)
    local function go()
        local t = M.trash(list)
        nav.select = nil
        M.forget()
        -- (a book's page that was just deleted: back from it)
        local v = top()
        if v and v.kind == "book" then
            for __, p in ipairs(list) do if p == v.path then table.remove(nav.stack) break end end
        end
        V.show()
        if not t then return KO.toast(_("Couldn't delete it")) end
        local what = #t.moved == 1 and T(_("Deleted “%1”"), t.moved[1].from:match("[^/]+$")) or T(_("Deleted %1 items"), #t.moved)
        if KO.canUndo() then
            KO.undo(what, function()
                M.untrash(t)
                M.forget()
                V.show()
            end, function() M.purgeTrash(t) end)
        else
            M.purgeTrash(t)
            KO.toast(what)
        end
    end
    if KO.canUndo() then return go() end
    KO.confirm{ title = _("Delete?"), text = plural(#list, _("This can't be undone."), _("%1 items. This can't be undone.")), ok = _("Delete"),
        danger = true, onOk = go }
end

function V.rename(path, isDir)
    local name = path:match("[^/]+$")
    local rows = {}
    if not isDir and M.isBook(name) then
        local b = M.book(path) or { path = path, name = name }
        local bare = name:gsub("%.[^.]+$", "")
        local title = M.title(b)
        for __, n in ipairs(M.niceNames(name, title ~= bare and title or nil, M.authors(b))) do
            table.insert(rows, { text = n })
        end
    end
    KO.ask{ title = _("Rename"), text = name, rows = rows, rowsTitle = _("FROM THE BOOK"), ok = _("Rename"), done = function(new)
        if new == name then return end
        if new:find("/") then return KO.toast(_("A name can't have a /")) end
        local to, why = M.rename(path, new)
        if not to then return KO.toast(why == "exists" and T(_("“%1” is already there"), new) or _("Couldn't rename it")) end
        local v = top()
        if v and v.kind == "book" and v.path == path then v.path = to end
        M.forget()
        V.show()
    end }
end

-- ------------------------------------------------------------------ a book

function V.bookMenu(b)
    local path = b.path
    local fav = M.isFavorite(path)
    local items = {
        { text = _("Open"), fn = function() V.openBook(path) end },
        { text = _("Book details"), fn = function() V.push({ kind = "book", path = path }) end },
        { text = _("Status…"), fn = function() V.statusMenu({ path }, function() V.bookMenu(b) end) end },
        { text = fav and _("Remove from Favorites") or _("Add to Favorites"), fn = function()
            M.collect({ path }, M.favoritesName(), not fav)
            KO.toast(fav and _("Removed from Favorites") or _("Added to Favorites"))
            V.show()
        end },
        { text = _("Add to a collection…"), fn = function() V.collectMenu({ path }, function() V.bookMenu(b) end) end },
        { text = _("Find details online"), fn = function() V.findDetails({ path }) end },
    }
    if M.ext(path) == "pdf" and V.notes() then
        table.insert(items, { text = _("Write on it in Notes"), fn = function() V.writeInNotes(path) end })
    end
    table.insert(items, { text = _("Open its folder"), fn = function() V.push({ kind = "folder", path = b.dir or path:match("^(.*)/") }) end })
    table.insert(items, { text = _("Move to…"), fn = function() V.pickFolder("move", { path }) end })
    table.insert(items, { text = _("Copy to…"), fn = function() V.pickFolder("copy", { path }) end })
    table.insert(items, { text = _("Rename"), fn = function() V.rename(path) end })
    table.insert(items, { text = _("Delete"), fn = function() V.delete({ path }) end })
    KO.list(M.title(b), items)
end

-- Notes (notes.koplugin), when it's there: it makes a notebook from a PDF to write on.
function V.notes()
    local ui = V.plugin and V.plugin.ui
    local n = ui and ui.notes
    if n and type(n.importPDF) == "function" then return n end
end

function V.writeInNotes(path)
    local n = V.notes()
    if not n then return end
    V.close()
    n:importPDF(path)
end

local STATUS_CHIPS = {
    { value = "new", text = _("To read") }, { value = "reading", text = _("Reading") },
    { value = "abandoned", text = _("On hold") }, { value = "complete", text = _("Finished") },
}

function V.view_book(page, v)
    local b = M.book(v.path)
    if not b then
        local a = lfs.attributes(v.path)
        if not a then
            page.title = _("Book")
            table.insert(page.items, { message = _("This book isn't there any more.") })
            return
        end
        b = { path = v.path, name = v.path:match("[^/]+$"), dir = v.path:match("^(.*)/"), size = a.size, mtime = a.modification, added = a.change }
    end
    local d = M.details(b)
    page.title = d.title
    page.bar_buttons = { { d.favorite and "star-fill" or "star", function()
        M.collect({ b.path }, M.favoritesName(), not d.favorite)
        KO.toast(d.favorite and _("Removed from Favorites") or _("Added to Favorites"))
        V.show()
    end } }
    local st = d.stats
    if st and st.pace and d.progress and d.pages and d.status ~= "complete" then
        local left = (d.pages * (1 - d.progress)) / st.pace * 3600
        if left > 60 then d.left = T(_("About %1 left"), M.duration(left)) end
    end
    local statuses = {}
    for __, s in ipairs(STATUS_CHIPS) do
        -- (To read only while it has never been opened: KOReader has no way back to it)
        if s.value ~= "new" or d.status == "new" then
            table.insert(statuses, { value = s.value, text = s.text, fn = s.value ~= "new" and function()
                M.setStatus(b.path, s.value)
                V.show()
            end or nil })
        end
    end
    local items = page.items
    table.insert(items, { top = d, book = b, statuses = statuses })
    table.insert(items, { gap = 8 })
    local reading = {}
    local function add(list, name, value, tap) if value and value ~= "" then table.insert(list, { stat = name, value = value, tap = tap }) end end
    local statsPage = st and V.statsPage(st.id)
    add(reading, _("First read"), st and M.date(st.first))
    add(reading, _("Last read"), M.when(d.lastRead))
    add(reading, _("Time reading"), st and st.seconds > 0 and M.duration(st.seconds) or nil, statsPage)
    add(reading, _("Days reading it"), st and st.days > 0 and tostring(st.days) or nil, statsPage)
    add(reading, _("Pace"), st and st.pace and T(_("%1 pages an hour"), st.pace) or nil)
    add(reading, _("Pages read"), st and st.read > 0 and (d.pages and T(_("%1 of %2"), st.read, d.pages) or tostring(st.read)) or nil)
    if (d.highlights or 0) + (d.notes or 0) > 0 then
        add(reading, _("Highlights and notes"), T("%1 · %2", d.highlights, d.notes), function() V.highlights(b) end)
    end
    if #reading > 0 then
        table.insert(items, { band = _("READING") })
        for __, r in ipairs(reading) do table.insert(items, r) end
    end
    local book = {}
    add(book, _("Series"), d.series and (d.series .. (d.seriesIndex and (" · " .. T(_("Book %1"), Page.num(d.seriesIndex))) or "")) or nil,
        d.series and function() V.push({ kind = "series", name = d.series }) end or nil)
    add(book, _("Authors"), d.authors and (d.authors:gsub("\n", ", ")) or nil, d.authors and function()
        V.push({ kind = "author", name = M.splitAuthors(d.authors)[1] })
    end or nil)
    add(book, _("Published"), d.published)
    add(book, _("Publisher"), d.publisher)
    add(book, _("Language"), d.language)
    add(book, _("Pages"), d.pages and tostring(d.pages) or nil)
    add(book, _("Print length"), d.printPages and T(_("%1 pages"), d.printPages) or nil)
    add(book, _("Subjects"), d.subjects)
    add(book, _("ISBN"), d.isbn)
    if #book > 0 then
        table.insert(items, { band = _("BOOK") })
        for __, r in ipairs(book) do table.insert(items, r) end
    end
    if d.description then
        table.insert(items, { band = _("DESCRIPTION") })
        table.insert(items, { gap = 6 })
        table.insert(items, { para = d.description, max = 14 })
    end
    table.insert(items, { band = _("FILE") })
    add(items, _("Name"), d.name)
    add(items, _("Format"), d.format)
    add(items, _("Size"), M.size(d.size))
    add(items, _("Added"), M.date(d.added))
    add(items, _("Folder"), M.shortPath(d.dir), function()
        V.push({ kind = "folder", path = d.dir })
    end)
    add(items, _("Collections"), #d.collections > 0 and table.concat(d.collections, ", ") or _("None"), function() V.collectMenu({ b.path }) end)
    page.buttons = {
        { icon = "trash-2", text = _("Delete"), fn = function() V.delete({ b.path }) end },
        { icon = "pencil", text = _("Rename"), fn = function() V.rename(b.path) end },
        { icon = "folder-input", text = _("Move to"), fn = function() V.pickFolder("move", { b.path }) end },
        { icon = "ellipsis-vertical", text = _("More"), fn = function() V.bookMore(b) end },
        { icon = "book-open", text = d.status == "new" and _("Open") or _("Continue"), primary = true, fn = function() V.openBook(b.path) end },
    }
end

function V.bookMore(b)
    local path = b.path
    local items = {
        { text = _("Highlights and notes"), fn = function() V.highlights(b) end },
    }
    local st = M.stats(path)
    local sp = st and V.statsPage(st.id)
    if sp then table.insert(items, { text = _("Reading statistics"), fn = sp }) end
    table.insert(items, { text = _("Add to a collection…"), fn = function() V.collectMenu({ path }, function() V.bookMore(b) end) end })
    table.insert(items, { text = _("Find details online"), fn = function() V.findDetails({ path }) end })
    if M.ext(path) == "pdf" and V.notes() then
        table.insert(items, { text = _("Write on it in Notes"), fn = function() V.writeInNotes(path) end })
    end
    table.insert(items, { text = _("Open its folder"), fn = function() V.push({ kind = "folder", path = b.dir or path:match("^(.*)/") }) end })
    table.insert(items, { text = _("Copy to…"), fn = function() V.pickFolder("copy", { path }) end })
    table.insert(items, { text = _("Reset reading progress…"), fn = function()
        KO.confirm{ title = _("Reset reading progress?"), text = _("The book starts from the beginning again. Its highlights and notes stay."),
            ok = _("Reset"), danger = true, onOk = function() M.resetProgress(path) V.show() end }
    end })
    KO.list(M.title(b), items)
end

-- ------------------------------------------------------------------ find details online

-- One run: { paths, i (the book now), q (what was typed), matches, snaps (what
-- Save changed, for Undo), handle (the lookup running) }. Its pages carry it
-- (view.run), so Back and the next book take them off the stack together.

local function online() return require("libraryonline") end

local function runBook(run)
    local path = run.paths[run.i]
    return M.book(path) or { path = path, name = path:match("[^/]+$"), dir = path:match("^(.*)/") }
end

local function dropRun(run)
    while #nav.stack > 1 and top().run == run do table.remove(nav.stack) end
end

--- Finds details online for books, one at a time, each shown first; saved only on Save.
function V.findDetails(paths)
    local list = booksOnly(paths)
    if #list == 0 then return KO.toast(_("Tick some books first")) end
    local run = { paths = list, i = 1, snaps = {} }
    local function go() V.lookUp(run) end
    -- (Wi-Fi off: KOReader asks to turn it on first)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.runWhenOnline then NetworkMgr:runWhenOnline(go) else go() end
end

--- Looks the run's book up: by what was typed, else its ISBN, or its title and author.
function V.lookUp(run)
    local O = online()
    local b = runBook(run)
    local d = M.details(b)
    local q = run.q or O.queryOf(d)
    local info = M.info(b.path)
    local lang = info and type(info.language) == "string" and info.language:lower():match("^(%a%a)") or nil
    local many = #run.paths > 1
    local wait = KO.wait(many and T(_("Finding details online… %1 of %2"), run.i, #run.paths) or _("Finding details online…"), { cancel = function()
        if run.handle then run.handle.cancel() end
        V.stopRun(run)
    end })
    run.handle = O.run(function() return O.find(q, d.title, lang, O.dir()) end, function(res)
        run.handle = nil
        if wait then wait:close() end
        if run.ended then return end
        local other = many and _("Skip") or _("Close")
        if not res or res.offline then
            return KO.confirm{ title = _("Couldn't connect"), text = _("Couldn't reach Open Library or Google Books. Check Wi-Fi and try again."),
                ok = _("Try again"), cancel = other, onOk = function() V.lookUp(run) end, onCancel = function() V.nextBook(run) end }
        end
        if #res.matches == 0 then
            local what = q.isbn and T(_("ISBN %1"), q.isbn) or ("“" .. O.queryText(q) .. "”")
            return KO.confirm{ title = _("Nothing found"),
                text = T(_("Open Library and Google Books have nothing for %1. Try other words, or an ISBN."), what),
                ok = _("Search again"), cancel = other, onOk = function() V.searchAgain(run) end, onCancel = function() V.nextBook(run) end }
        end
        run.matches = res.matches
        dropRun(run)
        local m = res.matches[1]
        -- (straight to it when it's surely the book; a choice when a search found several others)
        if q.isbn or #res.matches == 1 or O.norm(m.title) == O.norm(d.title) then
            V.push({ kind = "found", run = run, m = m })
        else
            V.push({ kind = "matches", run = run })
        end
    end)
end

--- The next book (or the end): Save, Skip, Close.
function V.nextBook(run)
    run.i = run.i + 1
    run.q, run.matches = nil, nil
    if run.i <= #run.paths and not run.ended then
        dropRun(run)
        V.show()
        return V.lookUp(run)
    end
    V.endRun(run)
end

--- Cancel, Stop and Back: the run ends here (what was saved stays, with Undo).
function V.stopRun(run)
    if run.handle then run.handle.cancel() run.handle = nil end
    V.endRun(run)
end

function V.endRun(run)
    if run.ended then return end
    run.ended = true
    dropRun(run)
    online().cleanup()
    V.show()
    local n = #run.snaps
    if n == 0 then return end
    local text = #run.paths == 1 and run.savedText or plural(n, _("Saved details for 1 book"), _("Saved details for %1 books"))
    KO.undo(text, function()
        for i = n, 1, -1 do online().restore(run.snaps[i]) end
        V.show()
    end)
end

function V.searchAgain(run)
    local O = online()
    local q = run.q or O.queryOf(M.details(runBook(run)))
    KO.ask{ title = _("Search again"), subtitle = _("Title and author, or an ISBN"), text = O.queryText(q),
        hint = _("Title and author, or an ISBN"), ok = _("Search"), okIcon = "search", done = function(text)
            run.q = O.queryFromText(text)
            -- (after the box has gone)
            UIManager:nextTick(function() V.lookUp(run) end)
        end }
end

--- A match from the list: its description and cover fetched first when not yet.
function V.pickMatch(run, m)
    if m.complete then return V.push({ kind = "found", run = run, m = m }) end
    local O = online()
    local wait = KO.wait(_("Getting its details…"), { cancel = function()
        if run.handle then run.handle.cancel() run.handle = nil end
    end })
    run.handle = O.run(function() return O.complete(m, O.dir()) end, function(res)
        run.handle = nil
        if wait then wait:close() end
        if type(res) == "table" then for k, val in pairs(res) do m[k] = val end end
        m.complete = true
        if not run.ended then V.push({ kind = "found", run = run, m = m }) end
    end)
end

-- The buttons both pages start with: Cancel (Stop and Skip for several books).
local function runButtons(run)
    if #run.paths > 1 then
        return {
            { icon = "x", text = _("Stop"), fn = function() V.stopRun(run) end },
            { icon = "chevron-right", text = _("Skip"), fn = function() V.nextBook(run) end },
        }
    end
    return { { icon = "x", text = _("Cancel"), fn = function() V.stopRun(run) end } }
end

--- What was found beside what the book has, each with a tick; Save saves what is ticked.
function V.view_found(page, v)
    local O = online()
    local run, m = v.run, v.m
    local b = runBook(run)
    local d = M.details(b)
    local many = #run.paths > 1
    page.title = many and T(_("Details found · %1 of %2"), run.i, #run.paths) or _("Details found")
    page.subtitle = T(_("%1 · from %2"), d.title, m.source)
    -- (the book's print length where KOReader has its pages on screen)
    local mine = setmetatable({ pages = d.printPages }, { __index = d })
    local rows, same = O.compare(mine, m, M.languageName)
    if not v.ticks then
        v.ticks = {}
        for __, r in ipairs(rows) do v.ticks[r.key] = r.tick end
        v.coverTick = m.coverFile ~= nil
    end
    local lines = {}
    local how = ({ isbn = _("Found by ISBN"), title = _("Found by title and author"), text = _("Found by what you typed") })[m.how]
    if how then table.insert(lines, how) end
    local list = run.matches or {}
    local pos = 1
    for i, x in ipairs(list) do if x == m then pos = i end end
    if #list > 1 then table.insert(lines, pos == 1 and T(_("First of %1 matches"), #list) or T(_("%1 of %2 matches"), pos, #list)) end
    if #same > 0 then table.insert(lines, T(_("Same as the book: %1."), table.concat(same, ", "))) end
    table.insert(page.items, { found = m, book = b, coverTick = v.coverTick, lines = lines, tapCover = function()
        v.coverTick = not v.coverTick
        V.show()
    end })
    if #rows > 0 then
        table.insert(page.items, { band = _("TICK WHAT TO SAVE"), right = _("Found · in the book") })
        for __, r in ipairs(rows) do
            local now
            if not r.now then now = _("Not in the book")
            elseif r.long then now = _("The book has another one")
            else now = T(_("In the book: %1"), r.now) end
            table.insert(page.items, { pick = r.name, value = r.found, now = now, long = r.long, tick = v.ticks[r.key], tap = function()
                v.ticks[r.key] = not v.ticks[r.key]
                V.show()
            end })
        end
    elseif not m.coverFile then
        table.insert(page.items, { message = _("Nothing new: the book has all of this already.") })
    end
    local function save()
        local ticked, count = {}, 0
        for k, on in pairs(v.ticks) do
            if on then
                ticked[k] = true
                count = count + 1
            end
        end
        local cover = v.coverTick and m.coverFile or nil
        if cover then count = count + 1 end
        if count == 0 then return KO.toast(_("Tick something to save first")) end
        table.insert(run.snaps, O.save(b.path, m, ticked, cover))
        run.savedText = count == 1 and T(_("Saved 1 detail from %1"), m.source) or T(_("Saved %1 details from %2"), count, m.source)
        V.nextBook(run)
    end
    page.buttons = runButtons(run)
    if #list > 1 then
        table.insert(page.buttons, { icon = "list", text = _("Other matches"), fn = function()
            local below = nav.stack[#nav.stack - 1]
            if below and below.run == run and below.kind == "matches" then V.back() else V.push({ kind = "matches", run = run }) end
        end })
    end
    table.insert(page.buttons, { icon = "search", text = _("Search again"), fn = function() V.searchAgain(run) end })
    table.insert(page.buttons, { icon = "check", text = _("Save"), primary = true, fn = save })
end

--- Several matches: each with its author, year, publisher and where it was found.
function V.view_matches(page, v)
    local run = v.run
    local b = runBook(run)
    local list = run.matches or {}
    local many = #run.paths > 1
    page.title = many and T(_("Which book is it? · %1 of %2"), run.i, #run.paths) or _("Which book is it?")
    page.subtitle = #list == 1 and T(_("1 match for %1"), M.title(b)) or T(_("%1 matches for %2"), #list, M.title(b))
    table.insert(page.items, { band = _("MATCHES"), right = tostring(#list) })
    for __, m in ipairs(list) do
        local facts = {}
        if m.authors then table.insert(facts, (m.authors:match("^[^\n]+"))) end
        if m.published then table.insert(facts, m.published) end
        if m.publisher then table.insert(facts, m.publisher) end
        table.insert(page.items, { icon = "book", text = m.title, sub = table.concat(facts, " · "), right = m.source, chevron = true,
            tap = function() V.pickMatch(run, m) end })
    end
    table.insert(page.items, { gap = 6 })
    table.insert(page.items, { note = _("Tap one to see its details. Search again to change the words.") })
    page.buttons = runButtons(run)
    table.insert(page.buttons, { icon = "search", text = _("Search again"), fn = function() V.searchAgain(run) end })
end

--- The launcher's Reading statistics page for a book (nil without the launcher).
function V.statsPage(id)
    local PS = require("pluginshare")
    local apps = PS.appsApps and PS.appsApps()
    if not (id and apps and apps.showMode) then return nil end
    return function()
        apps:showMode("statsbook", function(view) view.statsBook = id end)
    end
end

--- A book's highlights and notes, to read (the launcher's page of text; KOReader's TextViewer without it).
function V.highlights(b)
    local r = package.loaded["apps/reader/readerui"] and package.loaded["apps/reader/readerui"].instance
    local anns
    if r and r.document and r.document.file == b.path and r.annotation then anns = r.annotation.annotations end
    if not anns then
        local DS = require("docsettings")
        anns = DS:hasSidecarFile(b.path) and DS:open(b.path):readSetting("annotations") or {}
    end
    local parts = {}
    for __, a in ipairs(anns) do
        if (a.text and a.text ~= "") or (a.note and a.note ~= "") then
            local head = {}
            if a.chapter and a.chapter ~= "" then table.insert(head, a.chapter) end
            if a.pageno then table.insert(head, T(_("page %1"), a.pageno)) end
            local s = #head > 0 and (table.concat(head, " · ") .. "\n") or ""
            if a.text and a.text ~= "" then s = s .. "“" .. a.text .. "”" end
            if a.note and a.note ~= "" then s = s .. "\n" .. T(_("Note: %1"), a.note) end
            table.insert(parts, s)
        end
    end
    local text = #parts > 0 and table.concat(parts, "\n\n") or _("No highlights or notes yet. In the book, hold a word and drag to select, then Highlight or Note.")
    local P = KO.popup()
    if P and P.read then
        return P.read{ title = M.title(b), subtitle = _("Highlights and notes"), text = text, buttons = {
            { icon = "x", text = _("Close"), cancel = true },
            { icon = "book-open", text = _("Open"), primary = true, fn = function() V.openBook(b.path) end },
        } }
    end
    UIManager:show(require("ui/widget/textviewer"):new{ title = M.title(b), text = text })
end

--- Opens a book in KOReader's reader; Back in it comes back here.
function V.openBook(path)
    V.close()
    local PS = require("pluginshare")
    PS.library_book = path
    local ReaderUI = require("apps/reader/readerui")
    local r = ReaderUI.instance
    if r and r.document then
        if r.document.file ~= path then r:switchDocument(path) end
        return
    end
    -- (KOReader's file browser closes as the book opens, as when a book is opened there)
    UIManager:nextTick(function() ReaderUI:showReader(path) end)
end

-- ------------------------------------------------------------------ search

function V.askSearch()
    KO.ask{ title = _("Search the library"), subtitle = _("Titles, authors, series, collections and file names"), hint = _("Search"),
        ok = _("Search"), okIcon = "search", typing = true, done = function(q)
            V.push({ kind = "search", q = q })
        end }
end

function V.view_search(page, v)
    local res = M.search(v.q)
    page.title = "“" .. v.q .. "”"
    page.bar_buttons = { searchButton() }
    local items = page.items
    if #res.books > 0 then
        table.insert(items, { band = _("BOOKS"), right = tostring(#res.books) })
        for __, b in ipairs(res.books) do
            local a = M.authors(b)
            table.insert(items, { book = b, sub = (a and (a:gsub("\n", ", ")) .. " · " or "") .. M.stateText(b.path), bar = barOf(b),
                tap = function() V.push({ kind = "book", path = b.path }) end, hold = function() V.bookMenu(b) end })
        end
    end
    if #res.authors > 0 then
        table.insert(items, { band = _("AUTHORS"), right = tostring(#res.authors) })
        for __, a in ipairs(res.authors) do
            table.insert(items, { icon = "user", text = a.name, sub = plural(#a.books, _("1 book"), _("%1 books")), chevron = true,
                tap = function() V.push({ kind = "author", name = a.name }) end })
        end
    end
    if #res.collections > 0 then
        table.insert(items, { band = _("COLLECTIONS"), right = tostring(#res.collections) })
        for __, c in ipairs(res.collections) do
            table.insert(items, { icon = "library", text = c.label, sub = plural(#c.files, _("1 book"), _("%1 books")), chevron = true,
                tap = function() V.push({ kind = "collection", name = c.name, label = c.label }) end })
        end
    end
    if #res.files > 0 then
        table.insert(items, { band = _("FILES"), right = tostring(#res.files) })
        for __, f in ipairs(res.files) do
            table.insert(items, { icon = f.isDir and "folder" or "file-text", text = f.name, sub = M.shortPath(f.dir) .. (f.size and (" · " .. M.size(f.size)) or ""),
                chevron = true, tap = function()
                    if f.isDir then V.push({ kind = "folder", path = f.path }) else V.push({ kind = "folder", path = f.dir }) end
                end })
        end
    end
    local n = #res.books + #res.authors + #res.collections + #res.files
    if n == 0 then table.insert(items, { message = T(_("Nothing matches “%1”."), v.q) }) end
    page.status = function() return plural(n, _("1 result"), _("%1 results")) end
end

-- ------------------------------------------------------------------ ⋮ and settings

function V.more()
    local v = top()
    local extra = {}
    if v and (v.kind == "shelf" or v.kind == "author" or v.kind == "collection" or v.kind == "series" or v.kind == "folder") then
        table.insert(extra, { _("Covers"), function() S.set("view", "covers") V.show(true) end, showCovers() })
        table.insert(extra, { _("List"), function() S.set("view", "list") V.show(true) end, not showCovers() })
        table.insert(extra, { _("Select"), function() nav.select = {} V.show() end })
    end
    table.insert(extra, { _("Home folder"), function() V.switchTab("folders") end })
    table.insert(extra, { _("Show hidden files"), function()
        S.set("hidden", not S.get("hidden", false))
        M.forget()
        V.show(true)
    end, S.get("hidden", false) })
    table.insert(extra, { _("KOReader file browser"), function() V.toKOReader() end })
    KO.menu(V.plugin and V.plugin.ui, extra, function() V.settings() end)
end

--- KOReader's own file browser (the Library steps aside until a book is opened from it again).
function V.toKOReader()
    local PS = require("pluginshare")
    PS.library_aside = true
    local dir = top() and top().kind == "folder" and top().path or nil
    V.close()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        if dir then FileManager.instance.file_chooser:changeToPath(dir) end
        return
    end
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local r = ReaderUI and ReaderUI.instance
    if r then
        r:onClose()
        r:showFileManager(dir and (dir .. "/") or nil)
    else
        FileManager:showFiles(dir)
    end
end

--- The Library's settings (also from the launcher's Settings list).
function V.settings(jump)
    local page
    local function rows()
        local items = {}
        table.insert(items, { band = _("DISPLAY") })
        table.insert(items, { setting = _("Show books as"), value = showCovers() and _("Covers") or _("List"), tap = function()
            KO.choose(_("Show books as"), { { label = _("Covers"), value = "covers" }, { label = _("List"), value = "list" } }, S.get("view", "covers"),
                function(val) S.set("view", val) page:redraw() end)
        end })
        table.insert(items, { setting = _("Open on"), value = S.get("start", "home") == "last" and _("Where you left off") or _("Home"), tap = function()
            KO.choose(_("Open on"), { { label = _("Home"), value = "home" }, { label = _("Where you left off"), value = "last" } }, S.get("start", "home"),
                function(val) S.set("start", val) page:redraw() end)
        end })
        table.insert(items, { setting = _("Home starts with"), value = S.get("home_first", "places") == "places" and _("Servers and folders") or _("Books"),
            hint = _("What comes first on Home, after Continue reading and Recent"), tap = function()
                KO.choose(_("Home starts with"), { { label = _("Servers and folders"), value = "places" }, { label = _("Books"), value = "books" } },
                    S.get("home_first", "places"), function(val) S.set("home_first", val) page:redraw() end)
            end })
        table.insert(items, { band = _("FOLDERS") })
        table.insert(items, { toggle = S.get("hidden", false) == true, text = _("Show hidden files"), sub = _("Names starting with a dot"), tap = function()
            S.set("hidden", not S.get("hidden", false))
            M.forget()
            page:redraw()
        end })
        table.insert(items, { setting = _("Home folder"), value = M.home(), tap = function()
            V.close()
            page:onClose()
            V.open(V.plugin, { kind = "folder", path = M.home(), tab = "folders" })
            KO.toast(_("Hold a folder, then Set as Home folder"), 3)
        end })
        table.insert(items, { band = _("SERVERS") })
        table.insert(items, { setting = _("Download folder"), value = M.shortPath(require("libraryservers").downloadDir()),
            hint = _("Where books from FTP and WebDAV servers go"), tap = function()
                page:onClose()
                V.open(V.plugin, { kind = "folder", path = M.home(), tab = "folders" })
                local d = require("libraryservers").downloadDir()
                V.pickFolder("choose", {}, lfs.attributes(d, "mode") == "directory" and d or M.home())
            end })
        table.insert(items, { band = _("KOREADER") })
        table.insert(items, { setting = _("Browse books with"), value = S.isBrowser() and _("Library") or _("KOReader's file browser"),
            hint = _("What Back from a book and the launcher's Library open"), tap = function()
                KO.choose(_("Browse books with"), { { label = _("Library"), value = "library" }, { label = _("KOReader's file browser"), value = "koreader" } },
                    S.get("browser", "library"), function(val) S.set("browser", val) page:redraw() end)
            end })
        table.insert(items, { note = _("KOReader's own file browser is always in the menu: KOReader file browser. Covers and titles come from KOReader's Cover browser plugin, reading time from its Reading statistics plugin.") })
        return items
    end
    page = Page:new{
        build = function(p)
            p.title = _("Library settings")
            p.items = rows()
        end,
        menu = function() KO.menu(V.plugin and V.plugin.ui, {}, nil) end,
    }
    -- From the launcher's search: the page the row is on.
    if jump and page.rowPages and page.rowPages[jump] and page.rowPages[jump] ~= page.page then
        page.page = page.rowPages[jump]
        page:render()
    end
    UIManager:show(page, "full")
    return page
end

--- The settings' names, for the launcher's search (in step with V.settings).
function V.settingNames()
    local out = {}
    for __, name in ipairs({ _("Show books as"), _("Open on"), _("Home starts with"), _("Show hidden files"),
        _("Home folder"), _("Download folder"), _("Browse books with") }) do
        table.insert(out, { name })
    end
    return out
end

require("libraryserverviews")(V)

return V
