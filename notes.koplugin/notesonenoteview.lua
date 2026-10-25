--[[--
Reading OneNote on the Kindle: your OneNote notebooks, their sections and
pages; a page opens to read in KOReader (its typed text, lists, tables and
pictures). A page with handwriting can be downloaded to edit: it becomes
pages of a Notes notebook named after the OneNote notebook with "(OneNote)"
added, the handwriting as ink, the typed text as text boxes, the pictures
as pictures. OneNote isn't changed; sending the copy to OneNote makes new
pages there.

@module koplugin.notes.onenoteview
]]

local DataStorage = require("datastorage")
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local KO = require("notesko")
local T = require("ffi/util").template

local OneNote = require("notesonenote")
local Settings = require("notessettings")
local Store = require("notesstore")

local Screen = Device.screen

local function info(text) KO.message(text) end

local function busy(text)
    local msg = KO.wait(text)
    UIManager:forceRePaint()
    return msg
end

-- "2026-10-21T15:42:00Z" as "Oct 21, 2026".
local function day(iso)
    local y, m, d = tostring(iso or ""):match("^(%d+)%-(%d+)%-(%d+)")
    if not y then return nil end
    return (os.date("%b %d, %Y", os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })):gsub(" 0", " "))
end

-- A file name from an id (OneNote's have ! and other characters).
local function safe(s)
    return (tostring(s):gsub("[^%w%-]", "_"))
end

return function(Notes)
    -- ------------------------------------------------------------------ browsing

    --- OneNote's notebooks, sections and pages, to read or download.
    function Notes:browseOneNote()
        local api = self:oneNote()
        if not api.clientId then return info(_("Set the app ID first (Notes settings > OneNote > App ID).")) end
        if not api:signedIn() then return self:oneNoteSignIn(function() self:browseOneNote() end) end
        NetworkMgr:runWhenOnline(function()
            local msg = busy(_("Loading OneNote…"))
            local list, why = api:notebooks()
            UIManager:close(msg)
            if not list then return info(T(_("Could not reach OneNote:\n%1"), tostring(why))) end
            self.oneNoteTrail = {}
            local items = {}
            for __, nb in ipairs(list) do
                table.insert(items, { text = nb.name, callback = function() self:listOneNoteSections(nb) end })
            end
            if #items == 0 then table.insert(items, { text = _("No OneNote notebooks"), callback = function() end }) end
            self:showOneNoteList(_("OneNote"), items)
        end)
    end

    -- The browsing list: one full page, its rows switched (‹ goes back up,
    -- and closes it at the top).
    function Notes:showOneNoteList(title, items, back)
        if self.oneNoteMenu then
            self.oneNoteMenu.titleOpts.back = back
            self.oneNoteMenu:switchItemTable(title, items, 1)
            return
        end
        self.oneNoteMenu = self:listPage(title, items, back)
        self.oneNoteMenu.close_callback = function() self.oneNoteMenu = nil end
    end

    function Notes:listOneNoteSections(nb)
        local api = self:oneNote()
        NetworkMgr:runWhenOnline(function()
            local msg = busy(_("Loading OneNote…"))
            local list, why = api:sections(nb.id)
            UIManager:close(msg)
            if not list then return info(T(_("Could not reach OneNote:\n%1"), tostring(why))) end
            local items = {}
            for __, sec in ipairs(list) do
                table.insert(items, { text = sec.name, callback = function() self:listOneNotePages(nb, sec) end })
            end
            if #items == 0 then table.insert(items, { text = _("No sections"), callback = function() end }) end
            self:showOneNoteList(nb.name, items, function() self:browseOneNote() end)
        end)
    end

    function Notes:listOneNotePages(nb, sec)
        local api = self:oneNote()
        NetworkMgr:runWhenOnline(function()
            local msg = busy(_("Loading OneNote…"))
            local list, why = api:pages(sec.id)
            UIManager:close(msg)
            if not list then return info(T(_("Could not reach OneNote:\n%1"), tostring(why))) end
            local copies = Settings.get("onenote_copies") or {}
            local items = {}
            for __, pg in ipairs(list) do
                local copied = copies[pg.id] and self.store:read(copies[pg.id].nb) and true
                table.insert(items, {
                    text = pg.title or _("Untitled page"),
                    mandatory = (copied and (_("In Notes") .. " · ") or "") .. (day(pg.modified) or ""),
                    callback = function() self:openOneNotePage(nb, sec, pg) end,
                })
            end
            if #items == 0 then table.insert(items, { text = _("No pages"), callback = function() end }) end
            self:showOneNoteList(nb.name .. " › " .. sec.name, items, function() self:listOneNoteSections(nb) end)
        end)
    end

    -- ------------------------------------------------------------------ a page

    function Notes:openOneNotePage(nb, sec, pg)
        local api = self:oneNote()
        NetworkMgr:runWhenOnline(function()
            local msg = busy(_("Opening the page…"))
            local html, ink = api:pageContent(pg.id)
            UIManager:close(msg)
            if not html then return info(T(_("Could not open the page:\n%1"), tostring(ink))) end
            local strokes = OneNote.inkStrokes(ink)
            local copy = (Settings.get("onenote_copies") or {})[pg.id]
            if copy and not self.store:read(copy.nb) then copy = nil end
            local title = pg.title or _("Untitled page")
            if #strokes > 0 then
                title = title .. "\n\n" .. _("This page has handwriting. To see and edit it, download a copy to Notes. "
                    .. "OneNote isn't changed; when you send the copy to OneNote, it goes there as new pages.")
            end
            local dialog
            local function act(fn) return function() UIManager:close(dialog) fn() end end
            local buttons = {
                { { text = _("Open"), callback = act(function() self:readOneNotePage(pg, html, #strokes > 0) end) } },
            }
            if copy then
                table.insert(buttons, { { text = _("Open copy in Notes"), callback = act(function()
                    self:closeOneNote()
                    self:open(copy.nb, self:pageIndexOf(copy.nb, copy.page))
                end) } })
            end
            table.insert(buttons, { { text = copy and _("Download again") or _("Download to edit"), callback = act(function()
                self:downloadOneNotePage(nb, sec, pg, html, strokes)
            end) } })
            table.insert(buttons, { { text = _("Cancel"), callback = act(function() end) } })
            dialog = KO.buttonDialog{ title = title, title_align = "center", buttons = buttons }
        end)
    end

    function Notes:closeOneNote()
        if self.oneNoteMenu then UIManager:close(self.oneNoteMenu) end
        self.oneNoteMenu = nil
    end

    function Notes:pageIndexOf(id, pageId)
        local nb = self.store:read(id)
        for i, p in ipairs(nb and nb.pages or {}) do
            if p.id == pageId then return i end
        end
        return 1
    end

    -- The page's pictures saved in `dir`: { [their address] = file name }.
    local function savePictures(api, images, dir)
        local names = {}
        for i, img in ipairs(images) do
            if not names[img.src] then
                local status, bytes = api:fetch(img.src)
                if status == 200 and bytes and #bytes > 0 then
                    local ext = bytes:sub(1, 4) == "\137PNG" and "png" or (bytes:sub(1, 2) == "\255\216" and "jpg")
                        or (bytes:sub(1, 3) == "GIF" and "gif") or "png"
                    local name = string.format("img%d.%s", i, ext)
                    local f = io.open(dir .. "/" .. name, "wb")
                    if f then
                        f:write(bytes)
                        f:close()
                        names[img.src] = name
                    end
                end
            end
        end
        return names
    end

    --- The page to read in KOReader (as a web page, its pictures with it).
    function Notes:readOneNotePage(pg, html, hasInk)
        local api = self:oneNote()
        local dir = DataStorage:getDataDir() .. "/cache/onenote/" .. safe(pg.id)
        require("util").makePath(dir)
        local msg = busy(_("Opening the page…"))
        local layout = OneNote.layout(html)
        local names = savePictures(api, layout.images, dir)
        local path = dir .. "/" .. safe((pg.title or "page"):sub(1, 40)) .. ".html"
        local f = io.open(path, "wb")
        UIManager:close(msg)
        if not f then return info(_("Could not save the page.")) end
        f:write(OneNote.readableHtml(html, names, hasInk))
        f:close()
        -- Not a book: the launcher's reading statistics leave it out (known as the statistics know a
        -- file, by its partial MD5).
        local okM, md5 = pcall(require("util").partialMD5, path)
        if okM and md5 then
            local skip = G_reader_settings:readSetting("apps_stats_skip_md5") or {}
            table.insert(skip, md5)
            while #skip > 300 do table.remove(skip, 1) end
            G_reader_settings:saveSetting("apps_stats_skip_md5", skip)
        end
        self:closeOneNote()
        if self.menu then UIManager:close(self.menu) end
        KO.openBook(path)
    end

    -- ------------------------------------------------------------------ a copy to edit

    --- The page as pages of "<notebook> (OneNote)" in Notes: handwriting as
    -- ink, typed text as text boxes, pictures as pictures; then opened.
    function Notes:downloadOneNotePage(oneNb, sec, pg, html, strokes)
        local api = self:oneNote()
        NetworkMgr:runWhenOnline(function()
            local msg = busy(_("Downloading the page…"))
            local ok, where, why = pcall(self.copyOneNotePage, self, api, oneNb, pg, html, strokes, sec)
            UIManager:close(msg)
            if not ok then return info(T(_("Could not download the page:\n%1"), tostring(where))) end
            if not where then return info(T(_("Could not download the page:\n%1"), tostring(why))) end
            self:closeOneNote()
            self:open(where.nb, where.index)
        end)
    end

    function Notes:copyOneNotePage(api, oneNb, pg, html, strokes, sec)
        local store = self.store
        -- The notebook the copies go in, one per OneNote notebook.
        local books = Settings.get("onenote_copy_books") or {}
        local nb = books[oneNb.id] and store:read(books[oneNb.id])
        if not nb then
            local why
            nb, why = store:create(T(_("%1 (OneNote)"), oneNb.name), Screen:getWidth(), Screen:getHeight(), "plain")
            if not nb then return nil, why end
            books[oneNb.id] = nb.id
            Settings.set("onenote_copy_books", books)
        end
        local ed = self.editor
        local open = ed and UIManager:isWidgetShown(ed) and ed.notebook.id == nb.id and ed or nil
        if open then nb = open.notebook end
        local W, H = nb.width or Screen:getWidth(), nb.height or Screen:getHeight()
        local u = Screen:getDPI() / 100
        local left, right, top, bottom = math.floor(48 * u), math.floor(24 * u), math.floor(24 * u), math.floor(24 * u)
        local layout = OneNote.layout(html)
        -- Where everything is (CSS pixels), to fit the page's width.
        local minX, minY, maxX = math.huge, math.huge, 0
        local function see(x, y, x2)
            minX, minY, maxX = math.min(minX, x), math.min(minY, y), math.max(maxX, x2)
        end
        for __, t in ipairs(layout.texts) do see(t.x, t.y, t.x + t.w) end
        for __, im in ipairs(layout.images) do see(im.x, im.y, im.x + im.w) end
        for __, s in ipairs(strokes) do
            for i = 1, #s.p - 1, 2 do see(s.p[i], s.p[i + 1], s.p[i]) end
        end
        if minX == math.huge then minX, minY, maxX = 0, 0, 1 end
        local s = math.max(0.6, math.min(2.5, (W - left - right) / math.max(1, maxX - minX)))
        local Items = require("notesitems")
        local Editor = require("noteseditor")
        -- The title on top.
        local pages = {}
        local function pageAt(k)
            while #pages < k do table.insert(pages, { id = Store.newPageId(), created = os.time(), strokes = {}, items = {} }) end
            return pages[k]
        end
        local y0 = top
        local title = pg.title or layout.title
        if title and title:find("%S") then
            local size = math.floor((Editor.TEXT_SIZES.l or 75) * Screen:getDPI() / 300 + 0.5)
            local it = { k = "text", x = left, y = top, w = W - left - right, size = size, bold = true, text = title }
            table.insert(pageAt(1).items, it)
            local __, __, __, hgt = Items.box(it)
            y0 = top + hgt + math.floor(size * 0.6)
        end
        local avail = H - bottom
        -- A point of the OneNote page on the Notes pages: page number and x, y.
        local function place(cx, cy)
            local y = y0 + (cy - minY) * s
            local k = 1
            while y >= avail do
                y = y - (avail - top)
                k = k + 1
            end
            return k, left + math.floor((cx - minX) * s + 0.5), math.floor(y + 0.5)
        end
        -- Typed text: as text boxes, carried on to the next page when long.
        for __, t in ipairs(layout.texts) do
            local k, x, y = place(t.x, t.y)
            local size = math.max(20, math.floor(t.size * s * 1.15 + 0.5))
            local w = math.max(math.floor(u * 80), math.floor(t.w * s))
            local rest = t.text
            while rest and rest ~= "" do
                local room = avail - y
                local lines, fit = {}, nil
                for line in (rest .. "\n"):gmatch("(.-)\n") do table.insert(lines, line) end
                -- As many lines as fit here.
                local n = #lines
                while n > 0 do
                    local piece = table.concat(lines, "\n", 1, n)
                    local __, __, __, hgt = Items.box({ k = "text", x = x, y = y, w = w, size = size, text = piece })
                    if hgt <= room then
                        fit = n
                        break
                    end
                    n = n - 1
                end
                if not fit then
                    if y <= top then fit = 1 else fit = 0 end
                end
                if fit > 0 then
                    table.insert(pageAt(k).items, { k = "text", x = x, y = y, w = w, size = size,
                        text = table.concat(lines, "\n", 1, fit) })
                end
                rest = fit < #lines and table.concat(lines, "\n", fit + 1) or nil
                k, y = k + 1, top
            end
        end
        -- Pictures.
        local dir = store:imageDir()
        require("util").makePath(dir)
        for __, im in ipairs(layout.images) do
            local status, bytes = api:fetch(im.src)
            if status == 200 and bytes and #bytes > 0 then
                local ext = bytes:sub(1, 4) == "\137PNG" and "png" or "jpg"
                local file = string.format("img%d%03d.%s", os.time(), math.random(0, 999), ext)
                local f = io.open(dir .. "/" .. file, "wb")
                if f then
                    f:write(bytes)
                    f:close()
                    local k, x, y = place(im.x, im.y)
                    local w = math.min(W - left - right, math.floor(im.w * s))
                    local h = math.floor(im.h * w / math.max(1, im.w))
                    table.insert(pageAt(k).items, { k = "image", x = x, y = y, w = w, h = h, file = file })
                end
            end
        end
        -- Handwriting: each stroke on the page where it starts.
        for __, st in ipairs(strokes) do
            local k, x0, y0s = place(st.p[1], st.p[2])
            local dy = y0s - math.floor(y0 + (st.p[2] - minY) * s + 0.5)
            local p = {}
            for i = 1, #st.p - 1, 2 do
                table.insert(p, left + math.floor((st.p[i] - minX) * s + 0.5))
                table.insert(p, math.floor(y0 + (st.p[i + 1] - minY) * s + 0.5) + dy)
            end
            local grey = st.grey or 0
            local c = grey > 0x22 and math.min(0xCC, math.floor(grey / 0x11 + 0.5) * 0x11) or nil
            table.insert(pageAt(k).strokes, { t = st.hl and "hl" or nil, c = not st.hl and c or nil,
                w = math.max(1, math.floor(st.w * s + 0.5)), p = p })
        end
        if #pages == 0 then pageAt(1) end
        for __, page in ipairs(pages) do
            if #page.items == 0 then page.items = nil end
        end
        -- Into the notebook: an empty first page (a new notebook) is used.
        local first = nb.pages[1]
        local reuse = #nb.pages == 1 and #first.strokes == 0 and not (first.items and #first.items > 0)
        local at = reuse and 1 or #nb.pages + 1
        if reuse then table.remove(nb.pages, 1) end
        for __, page in ipairs(pages) do table.insert(nb.pages, page) end
        if open then
            open:pagesChanged(not reuse)
            open:saveNow()
        else
            local saved, why = store:save(nb)
            if not saved then return nil, why end
        end
        -- Which OneNote page these pages are a copy of (for Replace in OneNote).
        local copies = Settings.get("onenote_copies") or {}
        local ids = {}
        for __, page in ipairs(pages) do table.insert(ids, page.id) end
        copies[pg.id] = { nb = nb.id, page = pages[1].id, pages = ids, section = sec and sec.id, title = pg.title,
            created = tostring(html):match('<meta name="created" content="([^"]+)"') }
        Settings.set("onenote_copies", copies)
        self:refresh()
        return { nb = nb.id, index = at }
    end

    -- ------------------------------------------------------------------ replacing the page in OneNote

    --- The OneNote page that page `pageId` of notebook `nbId` is a copy of:
    -- its id and record, or nil.
    function Notes:originInOneNote(nbId, pageId)
        local foundId, found
        for id, rec in pairs(Settings.get("onenote_copies") or {}) do
            if not foundId and rec.nb == nbId and rec.section then
                for __, p in ipairs(rec.pages or { rec.page }) do
                    if p == pageId then
                        foundId, found = id, rec
                        break
                    end
                end
            end
        end
        return foundId, found
    end

    --- ⋯ > Replace in OneNote: the OneNote page this copy came from
    -- replaced by it (as pictures of its pages; OneNote can't take
    -- handwriting from apps). Asked first.
    function Notes:replaceInOneNote(ed)
        local nb = ed.notebook
        local oneId, c = self:originInOneNote(nb.id, nb.pages[ed.page].id)
        if not oneId then return end
        local title = c.title or nb.name
        KO.confirm{
            text = T(_("Replace \"%1\" in OneNote with this version?\n\nIts handwriting goes to OneNote as a picture (you can still write over it there). The page as it is in OneNote now is replaced."), title),
            ok = _("Replace"),
            onOk = function()
                ed:saveNow()
                local api = self:oneNote()
                if not api:signedIn() then return self:oneNoteSignIn() end
                NetworkMgr:runWhenOnline(function()
                    local msg = busy(_("Sending to OneNote…"))
                    local ok, newId, why = pcall(function()
                        local fresh = self.store:read(nb.id) or nb
                        local Editor = require("noteseditor")
                        local tmp = DataStorage:getDataDir() .. "/cache/notes-onenote-replace.png"
                        require("util").makePath(DataStorage:getDataDir() .. "/cache")
                        local pngs = {}
                        for i, page in ipairs(fresh.pages) do
                            for __, p in ipairs(c.pages or { c.page }) do
                                if p == page.id then
                                    Editor.pagePNG(fresh, i, tmp)
                                    local f = io.open(tmp, "rb")
                                    if f then
                                        table.insert(pngs, f:read("*a"))
                                        f:close()
                                    end
                                end
                            end
                        end
                        os.remove(tmp)
                        if #pngs == 0 then return nil, _("The pages aren't in this notebook any more.") end
                        -- The new page first; the old one goes only once it's there.
                        local id, err = api:createPictures(c.section, title, pngs, c.created)
                        if not id then return nil, err end
                        api:deletePage(oneId)
                        return id
                    end)
                    UIManager:close(msg)
                    if not ok then return info(T(_("Could not replace the page:\n%1"), tostring(newId))) end
                    if not newId then return info(T(_("Could not replace the page:\n%1"), tostring(why))) end
                    local copies = Settings.get("onenote_copies") or {}
                    copies[oneId] = nil
                    copies[newId] = c
                    Settings.set("onenote_copies", copies)
                    require("notesko").toast(T(_("Replaced in OneNote: %1"), title))
                end)
            end,
        }
    end
end
