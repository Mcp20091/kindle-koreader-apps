--[[--
The Library's FTP and WebDAV screens (libraryservers is what's behind them):

  SERVERS      in Folders (the Home folder) and on Home: each server, Add a server
  a server     its folders and books (`server` view); a tap downloads a book to
               the download folder and opens it, a hold has Download, Copy to…
  Add a server / Edit   settings rows (`serveredit` view): Type, Name, Address,
               Port, User, Password, Starting folder; Test and Save
  the folder picker     servers at the top of the Home folder, so Copy to… and
               Move to… put books on a server; Copy to… from a server downloads

Added onto the views table (V) by libraryviews.
]]

local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local KO = require("libraryko")
local M = require("librarymodel")
local R = require("libraryservers")
local Cat = require("libraryopds")

return function(V)

local nav = V.nav
local function top() return nav.stack[#nav.stack] end
local function plural(n, one, many) return n == 1 and one or T(many, n) end

local function icon(s) return s.type == "ftp" and "server" or "globe" end
local function trimmed(s) return type(s) == "string" and (s:match("^%s*(.-)%s*$")) or "" end

local function online(fn)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.runWhenOnline then NetworkMgr:runWhenOnline(fn) else fn() end
end

-- ------------------------------------------------------------------ the SERVERS rows

--- SERVERS for a page's items: each server (tap: its folders, hold: its menu) and, with `add`, Add a server.
function V.serverItems(items, add)
    local list = R.servers()
    local catalogs = Cat.available() and Cat.catalogs() or {}
    if #list == 0 and #catalogs == 0 and not add then return end
    table.insert(items, { band = #catalogs > 0 and _("SERVERS AND CATALOGS") or _("SERVERS") })
    for __, s in ipairs(list) do
        table.insert(items, { icon = icon(s), text = R.name(s), sub = R.label(s), chevron = true,
            tap = function() V.openServer(s) end, hold = function() V.serverMenu(s) end })
    end
    if #catalogs > 0 then
        local names = {}
        for i = 1, math.min(2, #catalogs) do table.insert(names, catalogs[i].title) end
        local sub = table.concat(names, ", ")
        if #catalogs > 2 then sub = T(_("%1 and %2 more"), sub, #catalogs - 2) end
        table.insert(items, { icon = "rss", text = _("Catalogs"), sub = sub, right = tostring(#catalogs), chevron = true,
            tap = function() V.push({ kind = "catalogs" }) end })
    end
    if add then
        table.insert(items, { icon = "plus", text = _("Add a server"), sub = _("FTP or WebDAV"), tap = function() V.editServer() end })
    end
end

function V.openServer(s)
    V.push({ kind = "server", server = s, path = R.folder(s.url) })
end

function V.serverMenu(s)
    KO.list(R.name(s), {
        { text = _("Open"), fn = function() V.openServer(s) end },
        { text = _("Edit"), fn = function() V.editServer(s) end },
        { text = _("Open the download folder"), fn = function()
            local d = R.downloadDir()
            if lfs.attributes(d, "mode") ~= "directory" then require("util").makePath(d) end
            V.push({ kind = "folder", path = d })
        end },
        { text = _("Delete"), fn = function() V.deleteServer(s) end },
    })
end

function V.deleteServer(s)
    local function go()
        local gone = R.remove(s.index)
        V.show()
        local what = T(_("Deleted “%1”"), R.name(s))
        if KO.canUndo() then
            KO.undo(what, function()
                R.restore(gone, s.index)
                V.show()
            end)
        else
            KO.toast(what)
        end
    end
    if KO.canUndo() then return go() end
    KO.confirm{ title = T(_("Delete %1?"), R.name(s)), text = _("Only the server is removed from this list, nothing on it."),
        ok = _("Delete"), danger = true, onOk = go }
end

-- ------------------------------------------------------------------ a server's folder

-- Lists v.path on v.server in the background, then draws the page again.
local function load(v)
    if v.loading then return end
    v.loading = true
    v.err = nil
    online(function()
        v.handle = R.run(function() return R.listing(v.server, v.path) end, function(res)
            v.loading, v.handle = false, nil
            if res and res.list then v.list = res.list else v.err = res and res.why or "no answer" end
            if top() == v then V.show() end
        end, 60)
    end)
end

-- The file a server's book becomes in `dir` (the download folder when nil).
local function localFile(e, dir) return (dir or R.downloadDir()) .. "/" .. e.name end

local function here(e)
    return lfs.attributes(localFile(e), "mode") == "file"
end

function V.view_server(page, v)
    local s = v.server
    local start = R.folder(s.url)
    page.title = v.path == start and R.name(s) or R.basename(v.path)
    page.subtitle = R.name(s) .. " · " .. (v.path ~= "" and v.path or "/")
    page.refresh_view = function() v.list, v.err = nil, nil end
    local items = page.items
    local parent = R.parent(v.path, start)
    if parent and not nav.select then
        table.insert(items, { icon = "folder-up", text = _("Up one folder"), tap = function()
            v.path, v.list, v.err = parent, nil, nil
            V.show(true)
        end })
    end
    if not v.list then
        if v.err then
            table.insert(items, { message = v.err == "530" and T(_("%1 didn't accept the user and password."), R.name(s))
                or v.err == "550" and T(_("%1 has no folder %2."), R.name(s), v.path)
                or T(_("Couldn't open %1. Check the address, the user and password, and Wi-Fi."), R.name(s)) })
            page.buttons = {
                { icon = "pencil", text = _("Edit"), fn = function() V.editServer(s) end },
                { icon = "refresh-cw", text = _("Try again"), primary = true, fn = function()
                    v.err = nil
                    load(v)
                    V.show()
                end },
            }
        else
            table.insert(items, { message = _("Opening…") })
            load(v)
        end
        page.status = function() return R.label(s) end
        return
    end
    local dirs, books, total = {}, {}, 0
    for __, e in ipairs(v.list) do
        if e.dir then table.insert(dirs, e) else table.insert(books, e) total = total + (e.size or 0) end
    end
    page.bar_buttons = { { "square-check", function()
        nav.select = {}
        nav.selectAll = function() return books end
        V.show()
    end } }
    nav.selectAll = function() return books end
    if #dirs > 0 and not nav.select then
        table.insert(items, { band = _("FOLDERS"), right = tostring(#dirs) })
        for __, d in ipairs(dirs) do
            table.insert(items, { icon = "folder", text = d.name, chevron = true, tap = function()
                V.push({ kind = "server", server = s, path = R.folder(d.path) })
            end })
        end
    end
    if #books > 0 then
        table.insert(items, { band = _("BOOKS"), right = tostring(#books) })
        for __, e in ipairs(books) do
            local sub = M.format(e.name) or ""
            if e.mtime then sub = sub .. (sub ~= "" and " · " or "") .. (M.when(e.mtime) or "") end
            local on = here(e)
            table.insert(items, { icon = M.ext(e.name) == "pdf" and "file-text" or "book", text = e.name, sub = sub,
                right = e.size and M.size(e.size) or nil, right2 = on and _("On this Kindle") or nil,
                tick = nav.select and nav.select[e.path] == true or nil,
                tap = function()
                    if nav.select then
                        if nav.select[e.path] then nav.select[e.path] = nil else nav.select[e.path] = true end
                        return V.show()
                    end
                    if on then return V.openBook(localFile(e)) end
                    V.download(s, { e }, nil, true)
                end,
                hold = function() V.remoteMenu(s, e) end })
        end
    end
    if #dirs + #books == 0 then table.insert(items, { message = _("This folder is empty.") }) end
    page.status = function()
        local parts = {}
        if #dirs > 0 then table.insert(parts, plural(#dirs, _("1 folder"), _("%1 folders"))) end
        table.insert(parts, plural(#books, _("1 book"), _("%1 books")))
        if total > 0 then table.insert(parts, M.size(total)) end
        return table.concat(parts, " · "), T(_("Downloads go to: %1"), R.basename(R.downloadDir()))
    end
    if nav.select then
        local n = 0
        for __ in pairs(nav.select) do n = n + 1 end
        local function picked()
            local out = {}
            for __, e in ipairs(books) do if nav.select[e.path] then table.insert(out, e) end end
            return out
        end
        page.title = n == 0 and _("Select") or plural(n, _("1 selected"), _("%1 selected"))
        page.subtitle = nil
        page.bar_buttons = { { "check", function()
            local every = n > 0 and n >= #books
            nav.select = {}
            if not every then for __, e in ipairs(books) do nav.select[e.path] = true end end
            V.show()
        end } }
        local function need(fn)
            return function()
                local list = picked()
                if #list == 0 then return KO.toast(_("Tick some first")) end
                fn(list)
            end
        end
        page.buttons = {
            { icon = "copy", text = _("Copy to"), fn = need(function(list) V.pickFolder("download", list, R.downloadDir(), s) end) },
            { icon = "check", text = _("Download"), primary = true, fn = need(function(list)
                nav.select = nil
                V.download(s, list)
            end) },
        }
        page.status = nil
    end
end

--- Hold a server's book.
function V.remoteMenu(s, e)
    local items = {}
    if here(e) then
        table.insert(items, { text = _("Open"), fn = function() V.openBook(localFile(e)) end })
    else
        table.insert(items, { text = _("Download and open"), fn = function() V.download(s, { e }, nil, true) end })
        table.insert(items, { text = _("Download"), fn = function() V.download(s, { e }) end })
    end
    table.insert(items, { text = _("Copy to…"), fn = function() V.pickFolder("download", { e }, R.downloadDir(), s) end })
    KO.list(e.name, items)
end

--- Downloads `list` into `dir` (the download folder when nil), one at a time;
-- with `open`, opens the one book after. `source`: a server (its books: { name,
-- path }) or fetch(e, part) for anything else (run in the child process).
function V.download(source, list, dir, open)
    local fetch = type(source) == "function" and source or function(e, part) return R.download(source, e.path, part) end
    dir = dir or R.downloadDir()
    if lfs.attributes(dir, "mode") ~= "directory" then require("util").makePath(dir) end
    local i, done, failed = 0, {}, {}
    local function finish()
        M.forget()
        if nav.select then nav.select = nil end
        V.show()
        if #failed > 0 then return KO.message(table.concat(failed, "\n"), _("Not copied")) end
        if open and #done == 1 then return V.openBook(done[1]) end
        if #done > 0 then KO.toast(T(_("Copied to %1"), R.basename(dir))) end
    end
    local function nextOne()
        i = i + 1
        local e = list[i]
        if not e then return finish() end
        local dest = dir .. "/" .. e.name
        if lfs.attributes(dest, "mode") then
            if open and #list == 1 then table.insert(done, dest) else table.insert(failed, e.name .. _(" (already there)")) end
            return nextOne()
        end
        local part = dest .. ".part"
        local text = T(_("Downloading %1…"), e.name)
        if #list > 1 then text = T(_("Downloading %1 of %2…"), i, #list) end
        local handle
        local wait = KO.wait(text, { cancel = function()
            if handle then handle.cancel() end
            os.remove(part)
            finish()
        end })
        handle = R.run(function() return fetch(e, part) end, function(ok)
            if wait then wait:close() end
            if handle and handle.cancelled then return end
            if ok and lfs.attributes(part, "mode") == "file" and os.rename(part, dest) then
                table.insert(done, dest)
            else
                os.remove(part)
                table.insert(failed, e.name)
            end
            nextOne()
        end, 1800)
    end
    online(nextOne)
end

-- ------------------------------------------------------------------ Add a server, Edit

--- Add a server (s nil) or change one: settings rows, Test, Save.
function V.editServer(s)
    local d = { type = "ftp", name = "", address = "", username = "", password = "", url = "" }
    if s then
        for k in pairs(d) do d[k] = s[k] or d[k] end
        d.index = s.index
    end
    d.address, d.port = R.splitPort(d.address)
    V.push({ kind = "serveredit", draft = d, editing = s ~= nil })
end

local function draftServer(d)
    return { index = d.index, type = d.type, name = d.name ~= "" and d.name or nil, address = R.normalize(d.type, d.address, d.port),
        username = d.username, password = d.password, url = R.folder(d.url) }
end

function V.view_serveredit(page, v)
    local d = v.draft
    page.title = v.editing and _("Edit server") or _("Add a server")
    local items = page.items
    local function ask(title, key, o)
        o = o or {}
        KO.ask{ title = title, subtitle = o.sub, text = d[key], hint = o.hint, password = o.password, number = o.number, ok = _("Done"),
            empty = true, done = function(text)
                d[key] = text
                V.show()
            end }
    end
    table.insert(items, { band = _("SERVER") })
    table.insert(items, { setting = _("Type"), value = R.TYPES[d.type], tap = function()
        KO.choose(_("Type"), { { label = "FTP", value = "ftp" }, { label = "WebDAV", value = "webdav" } }, d.type, function(val)
            d.type = val
            V.show()
        end)
    end })
    table.insert(items, { setting = _("Name"), value = d.name ~= "" and d.name or R.name(draftServer(d)),
        tap = function() ask(_("Name"), "name", { hint = _("Home NAS") }) end })
    local addrHint = d.type == "ftp" and "ftp://192.168.1.20" or "https://dav.example.org/remote.php/webdav"
    table.insert(items, { setting = _("Address"), value = d.address ~= "" and d.address or _("Not set"),
        tap = function() ask(_("Address"), "address", { hint = addrHint,
            sub = d.type == "ftp" and _("An address such as ftp://192.168.1.20, or a name") or _("The full address, with https:// or http://") }) end })
    table.insert(items, { setting = _("Port"), value = tostring(d.port or R.defaultPort(d.type, d.address)),
        tap = function() ask(_("Port"), "port", { number = true, hint = tostring(R.defaultPort(d.type, d.address)) }) end })
    table.insert(items, { setting = _("User"), value = d.username ~= "" and d.username or _("None"),
        tap = function() ask(_("User"), "username", { sub = _("Empty for anonymous") }) end })
    table.insert(items, { setting = _("Password"), value = d.password ~= "" and string.rep("•", 8) or _("None"),
        tap = function() ask(_("Password"), "password", { password = true }) end })
    table.insert(items, { setting = _("Starting folder"), value = R.folder(d.url) ~= "" and R.folder(d.url) or "/",
        tap = function() ask(_("Starting folder"), "url", { hint = "/Books" }) end })
    table.insert(items, { note = _("The same list as KOReader's Cloud storage: a server added here is there too, and the other way round.") })
    local function ready()
        if R.splitPort(d.address) == "" then
            KO.toast(_("Type the address first"))
            return false
        end
        return true
    end
    page.buttons = {
        { icon = "x", text = _("Cancel"), fn = function() V.back() end },
        { icon = "refresh-cw", text = _("Test"), fn = function()
            if not ready() then return end
            local test = draftServer(d)
            online(function()
                local handle
                local wait = KO.wait(T(_("Connecting to %1…"), R.name(test)), { cancel = function() if handle then handle.cancel() end end })
                handle = R.run(function() return R.listing(test, test.url) end, function(got)
                    if wait then wait:close() end
                    if handle and handle.cancelled then return end
                    local res = got and got.list
                    if got and got.why == "530" then
                        return KO.message(_("Check the user and password."), T(_("%1 didn't accept the user and password"), R.name(test)))
                    end
                    if not res then
                        return KO.message(_("Check the address, the port, the user and password, and Wi-Fi, and that the server is on."),
                            T(_("Couldn't connect to %1"), R.name(test)))
                    end
                    local nd, nb = 0, 0
                    for __, e in ipairs(res) do if e.dir then nd = nd + 1 else nb = nb + 1 end end
                    KO.toast(T(_("Connected: %1, %2"), plural(nd, _("1 folder"), _("%1 folders")), plural(nb, _("1 book"), _("%1 books"))), 3)
                end, 60)
            end)
        end },
        { icon = "check", text = _("Save"), primary = true, fn = function()
            if not ready() then return end
            local saved = draftServer(d)
            saved.index = R.save(saved)
            table.remove(nav.stack)
            -- (a server's folders open with the old one: with the new one now)
            for __, view in ipairs(nav.stack) do
                if view.kind == "server" and view.server.index == saved.index then
                    view.server, view.list, view.err = saved, nil, nil
                end
            end
            V.show()
            KO.toast(v.editing and _("Server saved") or _("Server added"))
        end },
    }
end

-- ------------------------------------------------------------------ OPDS catalogs

function V.view_catalogs(page, v)
    page.title = _("Catalogs")
    page.bar_buttons = { { "plus", function() V.editCatalog() end } }
    local list = Cat.catalogs()
    for __, c in ipairs(list) do
        table.insert(page.items, { icon = "rss", text = c.title or Cat.host(c.url), sub = Cat.label(c), chevron = true,
            tap = function() V.openCatalog(c) end, hold = function() V.catalogMenu(c) end })
    end
    if #list == 0 then table.insert(page.items, { message = _("No catalogs yet. + adds one.") }) end
    table.insert(page.items, { note = _("The same list as KOReader's OPDS catalog: a catalog added here is there too, and the other way round.") })
    page.status = function() return plural(#list, _("1 catalog"), _("%1 catalogs")), T(_("Downloads go to: %1"), R.basename(R.downloadDir())) end
end

function V.openCatalog(c)
    V.push({ kind = "opds", catalog = c, url = c.url, name = c.title or Cat.host(c.url) })
end

function V.catalogMenu(c)
    KO.list(c.title or Cat.host(c.url), {
        { text = _("Open"), fn = function() V.openCatalog(c) end },
        { text = _("Edit"), fn = function() V.editCatalog(c) end },
        { text = _("Delete"), fn = function()
            local gone = Cat.remove(c.index)
            V.show()
            local what = T(_("Deleted “%1”"), c.title or Cat.host(c.url))
            if KO.canUndo() then KO.undo(what, function() Cat.restore(gone, c.index) V.show() end) else KO.toast(what) end
        end },
    })
end

--- Add a catalog (c nil) or change one: Name, Address, User, Password; the suggested ones not in the list.
function V.editCatalog(c)
    local d = { title = "", url = "", username = "", password = "" }
    if c then
        for k in pairs(d) do d[k] = c[k] or d[k] end
        d.index = c.index
    end
    V.push({ kind = "catalogedit", draft = d, editing = c ~= nil })
end

function V.view_catalogedit(page, v)
    local d = v.draft
    page.title = v.editing and _("Edit catalog") or _("Add a catalog")
    local items = page.items
    local function ask(title, key, o)
        o = o or {}
        KO.ask{ title = title, subtitle = o.sub, text = d[key], hint = o.hint, password = o.password, ok = _("Done"), empty = true,
            done = function(text)
                d[key] = text
                V.show()
            end }
    end
    table.insert(items, { band = _("CATALOG") })
    table.insert(items, { setting = _("Name"), value = d.title ~= "" and d.title or (d.url ~= "" and Cat.host(d.url) or _("Not set")),
        tap = function() ask(_("Name"), "title", { hint = _("My library") }) end })
    table.insert(items, { setting = _("Address"), value = d.url ~= "" and d.url or _("Not set"),
        tap = function() ask(_("Address"), "url", { hint = "https://example.org/opds", sub = _("The catalog's OPDS address") }) end })
    table.insert(items, { setting = _("User"), value = d.username ~= "" and d.username or _("None"),
        tap = function() ask(_("User"), "username", { sub = _("Only for a catalog that asks for one, such as Calibre's") }) end })
    table.insert(items, { setting = _("Password"), value = d.password ~= "" and string.rep("•", 8) or _("None"),
        tap = function() ask(_("Password"), "password", { password = true }) end })
    if not v.editing then
        local missing = Cat.missing(Cat.catalogs())
        if #missing > 0 then
            table.insert(items, { band = _("ADD ONE OF THESE") })
            for __, s in ipairs(missing) do
                table.insert(items, { icon = "plus", text = s.title, sub = s.about, tap = function()
                    Cat.save({ title = s.title, url = s.url })
                    table.remove(nav.stack)
                    V.show()
                    KO.toast(T(_("Added %1"), s.title))
                end })
            end
        end
    end
    page.buttons = {
        { icon = "x", text = _("Cancel"), fn = function() V.back() end },
        { icon = "check", text = _("Save"), primary = true, fn = function()
            if trimmed(d.url) == "" then return KO.toast(_("Type the address first")) end
            local url = Cat.normalize(d.url)
            Cat.save({ index = d.index, title = trimmed(d.title) ~= "" and trimmed(d.title) or Cat.host(url), url = url,
                username = d.username, password = d.password })
            table.remove(nav.stack)
            V.show()
            KO.toast(v.editing and _("Catalog saved") or _("Catalog added"))
        end },
    }
end

-- The file a catalog's book becomes (in the download folder, or wherever it's copied).
local function catalogFile(e, f) return Cat.fileName(e.title, e.author, f.ext) end

-- Fetches a catalog page in the background (v.page), or the next one onto it (`more`).
local function loadCatalog(v, url, more)
    if v.loading then return end
    v.loading = true
    online(function()
        R.run(function() return Cat.page(v.catalog, url) end, function(res)
            v.loading = false
            if res then
                if more and v.page then
                    for __, e in ipairs(res.entries) do table.insert(v.page.entries, e) end
                    v.page.next = res.next
                else
                    v.page = res
                end
            elseif more then
                KO.toast(_("Couldn't load more"))
            else
                v.err = true
            end
            if top() == v then V.show() end
        end, 90)
    end)
end

local function catalogFetch(c)
    return function(it, part) return Cat.download(c, it.href, part) end
end

local function downloadBook(v, e, f, dir, open)
    V.download(catalogFetch(v.catalog), { { name = catalogFile(e, f), href = f.href } }, dir, open)
end

function V.view_opds(page, v)
    local c = v.catalog
    local cname = c.title or Cat.host(c.url)
    page.title = v.name
    page.subtitle = v.url ~= c.url and cname or Cat.host(c.url)
    local items = page.items
    if not v.page then
        if v.err then
            table.insert(items, { message = T(_("Couldn't open %1. Check the address and Wi-Fi."), cname) })
            page.buttons = {
                { icon = "pencil", text = _("Edit"), fn = function() V.editCatalog(c) end },
                { icon = "refresh-cw", text = _("Try again"), primary = true, fn = function()
                    v.err = nil
                    loadCatalog(v, v.url)
                    V.show()
                end },
            }
        else
            table.insert(items, { message = _("Opening…") })
            loadCatalog(v, v.url)
        end
        return
    end
    local p = v.page
    if p.search then
        page.bar_buttons = { { "search", function()
            KO.ask{ title = T(_("Search %1"), cname), hint = _("Title or author"), ok = _("Search"), okIcon = "search", typing = true,
                done = function(q) V.push({ kind = "opds", catalog = c, url = Cat.searchUrl(p.search, q), name = "“" .. q .. "”" }) end }
        end } }
    end
    local dl = R.downloadDir()
    local books, sections = 0, 0
    for __, e in ipairs(p.entries) do
        if e.formats then
            books = books + 1
            local f = e.formats[1]
            local file = dl .. "/" .. catalogFile(e, f)
            local here = lfs.attributes(file, "mode") == "file"
            local exts = {}
            for i = 1, math.min(3, #e.formats) do
                local x = e.formats[i].ext:upper()
                if exts[#exts] ~= x then table.insert(exts, x) end
            end
            table.insert(items, { icon = f.ext == "pdf" and "file-text" or "book", text = e.title,
                sub = e.author ~= "Unknown Author" and e.author or nil, right = table.concat(exts, " · "),
                right2 = here and _("On this Kindle") or nil,
                tap = function()
                    if here then return V.openBook(file) end
                    downloadBook(v, e, f, nil, true)
                end,
                hold = function() V.catalogBookMenu(v, e) end })
        else
            sections = sections + 1
            table.insert(items, { icon = "folder", text = e.title, sub = e.about and e.about:match("^[^\n]+") or nil, chevron = true,
                tap = function() V.push({ kind = "opds", catalog = c, url = e.url, name = e.title }) end })
        end
    end
    if #p.entries == 0 then table.insert(items, { message = _("Nothing here.") }) end
    if p.next then
        table.insert(items, { icon = "plus", text = v.loading and _("Loading…") or _("Load more"), tap = function()
            loadCatalog(v, p.next, true)
            V.show()
        end })
    end
    page.status = function()
        local left = (books > 0 or sections == 0) and plural(books, _("1 book"), _("%1 books")) or plural(sections, _("1 section"), _("%1 sections"))
        if p.next then left = T(_("%1 so far"), left) end
        return left, T(_("Downloads go to: %1"), R.basename(dl))
    end
end

--- Hold a catalog's book: download it, in another format, Copy to…, what it's about.
function V.catalogBookMenu(v, e)
    local f = e.formats[1]
    local list = {
        { text = _("Download and open"), fn = function() downloadBook(v, e, f, nil, true) end },
        { text = _("Download"), fn = function() downloadBook(v, e, f) end },
    }
    if #e.formats > 1 then
        table.insert(list, { text = _("Download as…"), fn = function()
            local opts = {}
            for __, x in ipairs(e.formats) do
                table.insert(opts, { text = x.ext:upper() .. ((x.title and x.title ~= "") and (" · " .. x.title) or ""),
                    fn = function() downloadBook(v, e, x) end })
            end
            KO.list(e.title, opts, function() V.catalogBookMenu(v, e) end)
        end })
    end
    table.insert(list, { text = _("Copy to…"), fn = function()
        V.pickFolder("download", { { name = catalogFile(e, f), href = f.href } }, R.downloadDir(), catalogFetch(v.catalog))
    end })
    if e.about then table.insert(list, { text = _("About this book"), fn = function() KO.message(e.about, e.title) end }) end
    KO.list(e.title, list)
end

-- ------------------------------------------------------------------ the folder picker on a server

--- The folder picker inside a server (v.server, v.rpath): its folders, then Copy here / Move here.
function V.view_pickServer(page, v)
    local s = v.server
    local start = R.folder(s.url)
    local n = #v.paths
    page.title = v.mode == "move" and plural(n, _("Move 1 item"), _("Move %1 items")) or plural(n, _("Copy 1 item"), _("Copy %1 items"))
    page.subtitle = R.name(s) .. " · " .. (v.rpath ~= "" and v.rpath or "/")
    page.refresh_view = function() v.rlist, v.err = nil, nil end
    local items = page.items
    table.insert(items, { icon = "folder-up", text = _("Up one folder"), tap = function()
        local parent = R.parent(v.rpath, start)
        if parent then v.rpath = parent else v.server = nil end
        v.rlist, v.err = nil, nil
        V.show(true)
    end })
    if not v.rlist then
        if v.err then
            table.insert(items, { message = T(_("Couldn't open %1. Check the address, the user and password, and Wi-Fi."), R.name(s)) })
        else
            table.insert(items, { message = _("Opening…") })
            if not v.loading then
                v.loading = true
                local at = v.rpath
                online(function()
                    R.run(function() return R.listing(s, at) end, function(res)
                        v.loading = false
                        if v.server ~= s or v.rpath ~= at then return end
                        if res and res.list then v.rlist = res.list else v.err = res and res.why or "no answer" end
                        if top() == v then V.show() end
                    end, 60)
                end)
            end
        end
    else
        local nd = 0
        for __, e in ipairs(v.rlist) do
            if e.dir then
                nd = nd + 1
                table.insert(items, { icon = "folder", text = e.name, chevron = true, tap = function()
                    v.rpath, v.rlist, v.err = R.folder(e.path), nil, nil
                    V.show(true)
                end })
            end
        end
        if nd == 0 then table.insert(items, { note = _("No folders in here.") }) end
    end
    page.buttons = {
        { icon = "x", text = _("Cancel"), fn = function() V.back() end },
        { icon = v.mode == "move" and "folder-input" or "copy", text = v.mode == "move" and _("Move here") or _("Copy here"), primary = true,
            fn = function()
                if not v.rlist then return KO.toast(_("Wait for the folder to open")) end
                V.upload(v)
            end },
    }
end

--- Copy here / Move here on a server: the files uploaded one at a time; a move
-- then deletes them here, with Undo.
function V.upload(v)
    local s, dir = v.server, v.rpath
    local there = {}
    for __, e in ipairs(v.rlist or {}) do there[e.name] = true end
    local files, failed = {}, {}
    for __, p in ipairs(v.paths) do
        local name = p:match("[^/]+$")
        if lfs.attributes(p, "mode") ~= "file" then table.insert(failed, name .. _(" (a folder)"))
        elseif there[name] then table.insert(failed, name .. _(" (already there)"))
        else table.insert(files, p) end
    end
    local done = {}
    local i = 0
    local function finish()
        table.remove(nav.stack)
        nav.select = nil
        local where = R.name(s)
        if v.mode == "move" and #done > 0 then
            local t = M.trash(done)
            M.forget()
            V.show()
            if t then
                local what = T(_("Moved to %1"), where)
                if KO.canUndo() then
                    KO.undo(what, function() M.untrash(t) M.forget() V.show() end, function() M.purgeTrash(t) end)
                else
                    M.purgeTrash(t)
                    KO.toast(what)
                end
            end
        else
            V.show()
            if #done > 0 and #failed == 0 then KO.toast(T(_("Copied to %1"), where)) end
        end
        if #failed > 0 then KO.message(table.concat(failed, "\n"), v.mode == "move" and _("Not moved") or _("Not copied")) end
    end
    local function nextOne()
        i = i + 1
        local p = files[i]
        if not p then return finish() end
        local text = #files > 1 and T(_("Copying %1 of %2 to %3…"), i, #files, R.name(s)) or T(_("Copying %1 to %2…"), p:match("[^/]+$"), R.name(s))
        local handle
        local wait = KO.wait(text, { cancel = function()
            if handle then handle.cancel() end
            i = #files
            finish()
        end })
        handle = R.run(function() return R.upload(s, dir, p) end, function(ok)
            if wait then wait:close() end
            if handle and handle.cancelled then return end
            if ok then table.insert(done, p) else table.insert(failed, p:match("[^/]+$")) end
            nextOne()
        end, 1800)
    end
    if #files == 0 then return finish() end
    online(nextOne)
end

end
