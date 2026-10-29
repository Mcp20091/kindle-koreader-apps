--[[--
Notes on the web page (needs the Notes plugin): the notebooks in their
folders (new, rename, move, delete; several at once), each page's
ink sent to the browser to be drawn there (and saved as PNG), new, rename,
duplicate, delete and their order, Notes' settings (toolbar order too),
and OneNote's app ID, sign-in and sending. (The AI services are the
launcher's: the AI tab, webai.lua.)
]]

local Common = require("webcommon")
local Device = require("device")

local Web = {}

local SETTINGS = {
    side = "string", folded = "boolean", quick_buttons = "boolean", side_button = "string", whole_eraser = "boolean", paper = "string",
    pressure = "boolean", sort = "string", snap_hold = "boolean", level_lines = "boolean", join_ends = "boolean",
    smooth = "number", order = "table", custom = "table",
    buttons = "table", favorites = "table", deghost = "number", ko_gestures = "boolean", light_swipes = "boolean",
    close_action = "string", suggest_names = "boolean", paper_lines = "string",
    eraser_hl = "boolean", pen_feel = "string", spread_turn = "boolean", name_date = "string", sort_default = "string", recent_mode = "string", show_recent = "boolean", hidden = "table", page_buttons = "table",
    onenote_auto = "boolean", onenote_picked_only = "boolean", onenote_text = "boolean",
    todo_dates = "boolean",
    page_header = "boolean", swipe_pages = "string", start_pen = "string", finger_undo = "boolean", open_last = "boolean",
    groups = "table",
}

local signIn  -- OneNote's sign-in under way

local function notes()
    local n = Common.plugin("notes")
    if n and n.store then return n end
end

-- A notebook id from the browser: only ever a notebook's own file name.
local function validId(id)
    return type(id) == "string" and id:match("^nb%d+$") ~= nil
end

-- Every id in a list valid (nil when one isn't).
local function validIds(list)
    if type(list) ~= "table" then return {} end
    for __, id in ipairs(list) do
        if not validId(id) then return nil end
    end
    return list
end

-- A folder path from the browser: its names cleaned, "" for none.
local function cleanPath(p)
    local Folders = require("notesfolders")
    local out = {}
    for part in tostring(p or ""):gmatch("[^/]+") do
        local name = Folders.clean(part)
        if name then table.insert(out, name) end
    end
    return table.concat(out, "/")
end

-- A notebook deleted: into Notes' trash when it has one. False when it
-- couldn't be.
local function trash(n, id, folder)
    if n.trashNotebook and n.store.trash then return n:trashNotebook(id, folder) end
    n.store:delete(id)
    if n.folders then n.folders:forget(id) end
    return true
end

local function refresh(n)
    if n.refresh then pcall(n.refresh, n) end
end

-- Whether a notebook is locked with a PIN on the Kindle (its pages aren't
-- shown or changed here).
local function locked(n, id)
    return n.isLocked and n:isLocked(id) or false
end

-- Whether a notebook is open on the Kindle now (its pages are then the
-- Kindle's to change).
local function openThere(n, id)
    local ed = n.editor
    return ed and ed.notebook and ed.notebook.id == id and require("ui/uimanager"):isWidgetShown(ed)
end

function Web.state(n)
    local Settings = require("notessettings")
    local Store = require("notesstore")
    local list = Store.sorted(n.store:list(), Settings.get("sort"), Settings.get("custom"))
    if n.folders then
        for __, nb in ipairs(list) do nb.folder = n.folders:of(nb.id) end
    end
    for __, nb in ipairs(list) do nb.locked = locked(n, nb.id) or nil end
    local settings = {}
    for k in pairs(SETTINGS) do settings[k] = Settings.get(k) end
    settings.favorites = #(Settings.get("favorites") or {})
    local out = { installed = true, notebooks = list, settings = settings, tools = Settings.TOOLS, papers = Settings.PAPER_NAMES,
        hasFolders = n.folders ~= nil,
        actions = Settings.ACTIONS, folders = n.folders and n.folders:all() or {},
        -- The toolbar as it is (groups in it), and the groups' names.
        toolbar = Settings.toolOrder and Settings.toolOrder() or nil,
        groups = Settings.groups and Settings.groups() or nil,
        groupNames = Settings.GROUPS and (function()
            local t = {}
            for k, g in pairs(Settings.GROUPS) do t[k] = g.label end
            return t
        end)() or nil,
        -- For the toolbar editor: the groups as saved (with members the
        -- Kindle hides now), the groups' order, every button's icon, and
        -- the actions that can show (no AI ones without an AI service).
        groupsSaved = Settings.get("groups"),
        groupOrder = Settings.GROUP_ORDER,
        icons = (function()
            local t = {}
            for k, v in pairs(Settings.TOOL_ICONS or {}) do t[k] = v end
            for __, a in ipairs(Settings.ACTIONS or {}) do t[a.key] = a.icon end
            for k, g in pairs(Settings.GROUPS or {}) do t["g:" .. k] = g.icon end
            return t
        end)(),
        actionsShown = Settings.actionShown and (function()
            local t = {}
            for __, a in ipairs(Settings.ACTIONS or {}) do t[a.key] = Settings.actionShown(a.key) or nil end
            return t
        end)() or nil,
        trash = n.store.trashList and n.store:trashList() or nil }
    if n.oneNote then
        local ok, one = pcall(n.oneNote, n)
        if ok and one then
            -- shared: on the launcher's one Microsoft account (its card, App.microsoftCard).
            out.onenote = { clientId = one.clientId or "", ownClientId = Settings.get("onenote_client_id") or "",
                signedIn = one:signedIn(), shared = one.account ~= nil or nil,
                needsAllow = one.needsAllow and one:needsAllow() or nil }
        end
    end
    -- Whether an AI service is set up (the launcher's), for the rows that need one.
    local ok, any = pcall(function() return require("pluginshare").ai.any() end)
    out.aiSetUp = ok and any or false
    return out
end

-- Notebooks' PDFs being made: { [id] = { path, pid, fd, done, err } }.
local pdfJobs = {}

local function pdfPath(id, modified)
    return require("datastorage"):getDataDir() .. "/cache/notes-web-" .. id .. "-" .. tostring(modified or 0) .. ".pdf"
end

-- A notebook's PDF made in a child process into `path` (older ones of the
-- notebook removed first).
local function startPdf(n, id, path)
    local dir = require("datastorage"):getDataDir() .. "/cache"
    require("util").makePath(dir)
    local lfs = require("libs/libkoreader-lfs")
    for name in lfs.dir(dir) do
        if name:find("^notes%-web%-" .. id .. "%-") then os.remove(dir .. "/" .. name) end
    end
    local ffiutil = require("ffi/util")
    local UIManager = require("ui/uimanager")
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, why = pcall(function()
            local nb = n.store:read(id)
            if not nb then error("No such notebook", 0) end
            local bytes = require("noteseditor").notebookPDF(nb)
            local f = io.open(path .. ".part", "wb")
            if not f then error("Couldn't write the PDF", 0) end
            f:write(bytes)
            f:close()
            os.rename(path .. ".part", path)
        end)
        ffiutil.writeToFD(write_fd, ok and "ok" or tostring(why), true)
    end, true)
    if not pid then
        pdfJobs[id] = { path = path, done = true, err = "Couldn't start making the PDF" }
        return
    end
    local job = { path = path, pid = pid, fd = fd }
    pdfJobs[id] = job
    local deadline = os.time() + 15 * 60
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(1, check) end
            ffiutil.terminateSubProcess(pid)
        end
        local out = (size and size > 0) and ffiutil.readAllFromFD(fd) or "stopped"
        job.done = true
        if out ~= "ok" then
            job.err = out
            os.remove(path .. ".part")
            require("logger").warn("Notes: web PDF failed:", out)
        elseif pdfJobs[id] == job then
            pdfJobs[id] = nil
        end
        if not exited then
            local function reap() if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end end
            reap()
        end
    end
    UIManager:scheduleIn(1, check)
end

function Web.routes(server)
    -- Notes' own icons (Lucide SVGs, drawn in the text colour): ?names=a,b.
    server:route("GET", "^/api/notes/icons$", function(req, res)
        local n = notes()
        if not n or not n.path then return res:error(404, "The Notes plugin isn't installed") end
        local out = {}
        for name in tostring(req.query.names or ""):gmatch("[%w%-]+") do
            local f = io.open(n.path .. "/icons/" .. name .. ".svg", "rb")
            if f then
                out[name] = f:read("*a"):gsub('stroke="#000000"', 'stroke="currentColor"')
                f:close()
            end
        end
        res:json({ icons = out })
    end)

    server:route("GET", "^/api/notes$", function(req, res)
        local n = notes()
        if not n then return res:json({ installed = false }) end
        res:json(Web.state(n))
    end)

    -- A notebook's pages and ink: { name, paper, width, height, dpi, tips, pages = { { strokes, text } } }.
    server:route("GET", "^/api/notes/notebook$", function(req, res)
        local n = notes()
        if not n then return res:error(404, "The Notes plugin isn't installed") end
        if not validId(req.query.id) then return res:error(404, "No such notebook") end
        if locked(n, req.query.id) then return res:error(403, "This notebook is locked on the Kindle") end
        local nb = n.store:read(req.query.id)
        if not nb then return res:error(404, "No such notebook") end
        local Ink = require("notesink")
        local tips = {}
        for name, tip in pairs(Ink.TIPS or {}) do tips[name] = { grey = tip.grey or 0, under = tip.under or false } end
        local pages = {}
        for __, page in ipairs(nb.pages) do
            local strokes = {}
            for __, s in ipairs(page.strokes or {}) do
                table.insert(strokes, { t = s.t or "pen", w = s.w, p = s.p, q = s.q, c = s.c, f = s.f and true or nil })
            end
            -- Typed text boxes (pictures and tape as their boxes).
            local items = {}
            for __, it in ipairs(page.items or {}) do
                if it.k == "text" then
                    table.insert(items, { k = "text", x = it.x, y = it.y, w = it.w, size = it.size, text = it.text,
                        bold = it.bold, italic = it.italic, serif = it.serif, align = it.align, link = it.link and true or nil })
                elseif it.k == "image" or it.k == "tape" then
                    table.insert(items, { k = it.k, x = it.x, y = it.y, w = it.w, h = it.h, open = it.open })
                end
            end
            table.insert(pages, { strokes = strokes, items = items, star = page.star == true, pdf = page.bg ~= nil })
        end
        res:json({ id = nb.id, name = nb.name, paper = nb.paper, width = nb.width, height = nb.height,
            dpi = Device.screen:getDPI(), tips = tips, pages = pages, pdf = nb.pdf ~= nil })
    end)

    -- { op = "new" | "rename" | "duplicate" | "delete" | "order", id, name, paper, ids }.
    server:route("POST", "^/api/notes/notebook$", function(req, res)
        local n = notes()
        if not n then return res:error(404, "The Notes plugin isn't installed") end
        local Settings = require("notessettings")
        local b, store = req.json(), n.store
        if b.op == "new" then
            local name = (b.name or ""):match("^%s*(.-)%s*$")
            if name == "" then return res:error(400, "A notebook needs a name") end
            local nb = store:create(name, Device.screen:getWidth(), Device.screen:getHeight(), b.paper or Settings.get("paper"))
            if not nb then return res:error(500, "Couldn't make the notebook") end
            if Settings.get("pressure") == false then nb.pressure = false end
            store:save(nb)
            local folder = cleanPath(b.folder)
            if n.folders and folder ~= "" then
                n.folders:set(nb.id, folder)
                n.folders:save()
            end
        elseif b.op == "rename" then
            if not validId(b.id) or type(b.name) ~= "string" or b.name == "" then return res:error(400, "No such notebook") end
            -- The Kindle saves what it has open: renamed there instead.
            if openThere(n, b.id) then return res:error(409, "Close that notebook on the Kindle first") end
            local nb = store:read(b.id)
            if not nb then return res:error(400, "No such notebook") end
            nb.name = b.name
            store:save(nb)
        elseif b.op == "duplicate" then
            if not validId(b.id) then return res:error(400, "No such notebook") end
            local copy = store:duplicate(b.id, type(b.name) == "string" and b.name or "Copy")
            if not copy then return res:error(400, "Couldn't duplicate the notebook") end
            if n.folders then
                n.folders:set(copy.id, n.folders:of(b.id))
                n.folders:save()
            end
        elseif b.op == "delete" then
            if not validId(b.id) or not store:summary(b.id) then return res:error(404, "No such notebook") end
            if openThere(n, b.id) then return res:error(409, "Close that notebook on the Kindle first") end
            if not trash(n, b.id) then return res:error(500, "Couldn't move the notebook to the trash") end
            if n.folders then n.folders:save() end
        elseif b.op == "order" and validIds(b.ids) then
            Settings.set("custom", b.ids)
            Settings.set("sort", "custom")
        else
            return res:error(400, "Unknown change")
        end
        refresh(n)
        res:json({ ok = true })
    end)

    -- Folders, and several folders and notebooks at once:
    -- { op = "new", path } | { op = "rename", path, to } | { op = "move", ids, paths, to }
    -- | { op = "duplicate", ids } | { op = "delete", ids, paths, keep }.
    server:route("POST", "^/api/notes/folders$", function(req, res)
        local n = notes()
        if not n or not n.folders then return res:error(404, "This version of Notes has no folders") end
        local Folders = require("notesfolders")
        local b, fo = req.json(), n.folders
        local ids = validIds(b.ids)
        if not ids then return res:error(400, "No such notebook") end
        local paths = {}
        for __, p in ipairs(type(b.paths) == "table" and b.paths or {}) do
            p = cleanPath(p)
            if p ~= "" then table.insert(paths, p) end
        end
        local function clean(p)
            local out = {}
            for part in tostring(p or ""):gmatch("[^/]+") do
                local name = Folders.clean(part)
                if name then table.insert(out, name) end
            end
            return table.concat(out, "/")
        end
        if b.op == "new" then
            local path = clean(b.path)
            if path == "" then return res:error(400, "A folder needs a name") end
            fo:add(path)
        elseif b.op == "rename" then
            local to = clean(b.to)
            if to == "" or not fo:rename(b.path or "", to) then
                return res:error(400, "There is already a folder with that name there")
            end
        elseif b.op == "move" then
            local to = clean(b.to)
            for __, id in ipairs(ids) do fo:set(id, to) end
            for __, p in ipairs(paths) do
                local dest = Folders.join(to, Folders.name(p))
                if dest ~= p and not fo:rename(p, dest) then
                    fo:save()
                    refresh(n)
                    return res:error(400, "A folder with the same name is already there: " .. Folders.name(p))
                end
            end
        elseif b.op == "duplicate" then
            for __, id in ipairs(ids) do
                local nb = n.store:read(id)
                local copy = nb and n.store:duplicate(id, nb.name .. " (copy)")
                if copy then fo:set(copy.id, fo:of(id)) end
            end
        elseif b.op == "delete" then
            -- Each notebook keeps its folder in the trash (to go back to).
            local folderOf, all = {}, {}
            for __, nb in ipairs(n.store:list()) do
                folderOf[nb.id] = fo:of(nb.id)
                table.insert(all, nb.id)
            end
            -- What goes, worked out first: none of it may be open on the Kindle.
            local gone = {}
            for __, id in ipairs(ids) do table.insert(gone, id) end
            if not b.keep then
                for __, p in ipairs(paths) do
                    for __, id in ipairs(fo:inside(p, all)) do table.insert(gone, id) end
                end
            end
            for __, id in ipairs(gone) do
                if openThere(n, id) then return res:error(409, "Close that notebook on the Kindle first") end
            end
            for __, p in ipairs(paths) do fo:remove(p, b.keep and Folders.parent(p) or nil) end
            for __, id in ipairs(gone) do trash(n, id, folderOf[id]) end
        else
            return res:error(400, "Unknown folder action")
        end
        fo:save()
        refresh(n)
        res:json({ ok = true })
    end)

    -- A notebook as a PDF. Drawing every page takes a while on a big book, so
    -- it is made in a child process (the Kindle keeps answering) and kept for
    -- as long as the notebook is unchanged: ?check=1 says whether it's ready
    -- ({ ready, error }), without it the PDF is downloaded once it is (until
    -- then, a page that looks again every two seconds).
    server:route("GET", "^/api/notes/pdf$", function(req, res)
        local n = notes()
        if not n then return res:error(404, "The Notes plugin isn't installed") end
        local Editor = require("noteseditor")
        if not Editor.notebookPDF then return res:error(404, "This version of Notes can't make PDFs here") end
        local id = req.query.id
        if not validId(id) then return res:error(404, "No such notebook") end
        if locked(n, id) then return res:error(403, "This notebook is locked on the Kindle") end
        local entry
        for __, e in ipairs(n.store:list()) do
            if e.id == id then entry = e end
        end
        if not entry then return res:error(404, "No such notebook") end
        local path = pdfPath(id, entry.modified)
        local job = pdfJobs[id]
        local f = not (job and job.path == path and not job.done) and io.open(path, "rb")
        if f then
            f:close()
            if req.query.check then return res:json({ ready = true }) end
            return res:file(path, (entry.name:gsub("[/\\:*?\"<>|]", "_")) .. ".pdf")
        end
        if job and job.path == path and job.err then
            local why = job.err
            pdfJobs[id] = nil
            if req.query.check then return res:json({ ready = false, error = why }) end
            return res:error(500, "Couldn't make the PDF: " .. why)
        end
        if not (job and job.path == path) then startPdf(n, id, path) end
        if req.query.check then return res:json({ ready = false }) end
        res:send("<!DOCTYPE html><meta charset=utf-8><meta http-equiv=refresh content=2>"
            .. "<body style=\"font-family:sans-serif;padding:2em\">Making the PDF on the Kindle\226\128\166</body>",
            "text/html; charset=utf-8")
    end)

    -- A PDF uploaded as a new notebook to write on (or a puzzle book):
    -- ?name=…&puzzle=1&folder=…, the PDF as the body.
    server:route("PUT", "^/api/notes/pdf$", function(req, res)
        -- The body is read whatever happens (so the browser sees the answer).
        local dir = require("datastorage"):getDataDir() .. "/cache"
        require("util").makePath(dir)
        local tmp = dir .. "/notes-upload.pdf"
        local f = io.open(tmp, "wb")
        local got, wrote = 0, f ~= nil
        while true do
            local chunk = req:read(64 * 1024)
            if not chunk then break end
            if f and not f:write(chunk) then wrote = false end
            got = got + #chunk
        end
        if f then f:close() end
        local function fail(code, text)
            os.remove(tmp)
            return res:error(code, text)
        end
        local n = notes()
        if not n or not n.store.createFromPDF then return fail(404, "This version of Notes can't take PDFs here") end
        if not wrote then return fail(500, "Couldn't save the upload (is the Kindle full?)") end
        if got ~= req.length or got == 0 then return fail(400, "The upload was interrupted") end
        local ok, nb, count = pcall(function()
            local PDF = require("notespdf")
            local pages, pw, ph = PDF.pageCount(tmp)
            if not pages then return nil end
            -- Landscape pages make a landscape notebook (as on the Kindle).
            local w, h = Device.screen:getWidth(), Device.screen:getHeight()
            if (w > h) ~= ((pw or 0) > (ph or 0)) then w, h = h, w end
            local name = (req.query.name or ""):gsub("%.[Pp][Dd][Ff]$", ""):match("^%s*(.-)%s*$")
            if name == "" then name = "PDF" end
            return n.store:createFromPDF(name, tmp, pages, w, h, req.query.puzzle == "1"), pages
        end)
        os.remove(tmp)
        if not ok or not nb then return res:error(400, "That isn't a PDF Notes can read") end
        local folder = cleanPath(req.query.folder)
        if n.folders and folder ~= "" then
            n.folders:set(nb.id, folder)
            n.folders:save()
        end
        refresh(n)
        res:json({ ok = true, id = nb.id, pages = count })
    end, true)

    -- A picture (PNG or JPG) put on a new page at the end of a notebook:
    -- ?id=<notebook>&name=<file name>, the picture as the body.
    server:route("PUT", "^/api/notes/image$", function(req, res)
        local dir = require("datastorage"):getDataDir() .. "/cache"
        require("util").makePath(dir)
        local ext = (req.query.name or ""):lower():match("%.(%a+)$") or "png"
        if ext == "jpeg" then ext = "jpg" end
        local tmp = dir .. "/notes-upload." .. ext
        local f = io.open(tmp, "wb")
        local got, wrote = 0, f ~= nil
        while true do
            local chunk = req:read(64 * 1024)
            if not chunk then break end
            if f and not f:write(chunk) then wrote = false end
            got = got + #chunk
        end
        if f then f:close() end
        local function fail(code, text)
            os.remove(tmp)
            return res:error(code, text)
        end
        local n = notes()
        if not n or not n.addImagePage then return fail(404, "This version of Notes can't take pictures here") end
        if ext ~= "png" and ext ~= "jpg" then return fail(400, "Only PNG and JPG pictures can be added") end
        if not wrote then return fail(500, "Couldn't save the upload (is the Kindle full?)") end
        if got ~= req.length or got == 0 then return fail(400, "The upload was interrupted") end
        local id = req.query.id
        if id and id ~= "" and not validId(id) then return fail(404, "No such notebook") end
        local ok, where, why = pcall(n.addImagePage, n, tmp, { notebook = (id ~= "" and id) or nil })
        os.remove(tmp)
        if not ok then return res:error(500, tostring(where)) end
        if not where then return res:error(400, tostring(why)) end
        res:json({ ok = true, where = where })
    end, true)

    -- The trash: { op = "restore" | "purge", id } | { op = "empty" }.
    server:route("POST", "^/api/notes/trash$", function(req, res)
        local n = notes()
        if not n or not n.store.trashList then return res:error(404, "This version of Notes has no trash") end
        local b = req.json()
        if (b.op == "restore" or b.op == "purge") and not validId(b.id) then return res:error(404, "No such notebook") end
        if b.op == "restore" then
            local folder = n.store:restore(b.id or "")
            if not folder then return res:error(400, "Couldn't restore the notebook") end
            if folder ~= "" and n.folders then
                n.folders:set(b.id, folder)
                n.folders:save()
            end
        elseif b.op == "purge" then
            n.store:purge(b.id or "")
        elseif b.op == "empty" then
            n.store:emptyTrash(true)
        else
            return res:error(400, "Unknown trash action")
        end
        refresh(n)
        res:json({ ok = true })
    end)

    -- Several pages of a notebook: { id, op = "delete" | "star" | "unstar", pages = { page numbers } }.
    server:route("POST", "^/api/notes/pages$", function(req, res)
        local n = notes()
        if not n then return res:error(404, "The Notes plugin isn't installed") end
        local b = req.json()
        if not validId(b.id) then return res:error(404, "No such notebook") end
        if locked(n, b.id) then return res:error(403, "This notebook is locked on the Kindle") end
        if openThere(n, b.id) then return res:error(409, "Close that notebook on the Kindle first") end
        local nb = n.store:read(b.id or "")
        if not nb then return res:error(404, "No such notebook") end
        local list = {}
        for __, i in ipairs(type(b.pages) == "table" and b.pages or {}) do
            i = tonumber(i)
            if i and nb.pages[i] then table.insert(list, i) end
        end
        table.sort(list)
        if b.op == "delete" then
            if #list >= #nb.pages then return res:error(400, "A notebook keeps at least one page") end
            -- Kept for 30 days like the Kindle's (Editor:deletePageAt), to restore there.
            nb.deleted = nb.deleted or {}
            for k = #list, 1, -1 do
                local page = table.remove(nb.pages, list[k])
                table.insert(nb.deleted, { at = os.time(), index = list[k], page = page })
            end
        elseif b.op == "star" or b.op == "unstar" then
            for __, i in ipairs(list) do nb.pages[i].star = b.op == "star" or nil end
        else
            return res:error(400, "Unknown page action")
        end
        n.store:save(nb)
        refresh(n)
        res:json({ ok = true })
    end)

    -- Search: typed text, notebook names and handwriting read before (Notes'
    -- own search, no AI; locked notebooks left out): [{ nb, name, page, snippet, kind }].
    server:route("GET", "^/api/notes/search$", function(req, res)
        local n = notes()
        if not n then return res:error(404, "The Notes plugin isn't installed") end
        if not n.findText then return res:json({}) end
        local q = (req.query.q or ""):match("^%s*(.-)%s*$")
        if #q < 2 then return res:json({}) end
        local ok, found = pcall(n.findText, n, q, 50)
        if not ok then return res:error(500, tostring(found)) end
        local out = {}
        for i, r in ipairs(found) do
            out[i] = { nb = r.nb, name = r.name, page = r.kind ~= "name" and r.page or nil, snippet = r.snippet, kind = r.kind }
        end
        res:json(out)
    end)

    server:route("POST", "^/api/notes/settings$", function(req, res)
        local n = notes()
        if not n then return res:error(404, "The Notes plugin isn't installed") end
        local Settings = require("notessettings")
        for k, v in pairs(Common.pick(req.json(), SETTINGS)) do
            if v == "" then v = nil end  -- an emptied name
            if k == "favorites" then v = {} end  -- only clearing them
            Settings.set(k, v)
        end
        refresh(n)
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/notes/onenote/clientid$", function(req, res)
        local n = notes()
        if not n or not n.oneNote then return res:error(404, "The Notes plugin isn't installed") end
        local id = (req.json().id or ""):match("^%s*(.-)%s*$")
        require("notessettings").set("onenote_client_id", id ~= "" and id or nil)
        n:oneNote()
        res:json({ ok = true })
    end)

    server:route("POST", "^/api/notes/onenote/signin$", function(req, res)
        local n = notes()
        if not n or not n.oneNote then return res:error(404, "The Notes plugin isn't installed") end
        local one = n:oneNote()
        if not one.clientId then return res:error(400, "Set the app ID first") end
        if signIn then signIn.cancelled = true end
        local state, why = Common.deviceCode(one)
        if not state then return res:error(502, "Can't reach Microsoft: " .. why) end
        signIn = state
        res:json(state)
    end)

    server:route("GET", "^/api/notes/onenote/signin$", function(req, res)
        res:json(signIn or { status = "none" })
    end)

    server:route("POST", "^/api/notes/onenote/signout$", function(req, res)
        local n = notes()
        if not n or not n.oneNote then return res:error(404, "The Notes plugin isn't installed") end
        n:oneNote():signOut()
        res:json({ ok = true })
    end)
end

return Web
