--[[--
The notebook list's folders (and folders in them), and selecting several
folders and notebooks to move, duplicate, send to OneNote or delete them
together. Mixed into the Notes plugin (main.lua).

@module koplugin.notes.folderui
]]

local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local KO = require("notesko")
local T = require("ffi/util").template

local Folders = require("notesfolders")
local Settings = require("notessettings")

local function input(title, value, ok, done)
    -- The launcher's box: the name (or the pen), Cancel and the button.
    local request = KO.request()
    if request then
        return request{ title = title, text = value or "", pen = KO.pen(), penTitle = title, penKind = "name", typing = true,
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = "check", text = ok, primary = true, fn = function(v) done(v) end },
            } }
    end
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value or "",
        buttons = { KO.compact{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            KO.writeButton(function() return dialog end, { kind = "name" }),
            { text = ok, is_enter_default = true, callback = function()
                local v = dialog:getInputText()
                UIManager:close(dialog)
                done(v)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function pages(n) return n == 1 and _("1 page") or T(_("%1 pages"), n) end

-- A folder as it reads: "Work › Clients".
local function shown(path)
    if path == "" then return _("Notes (top level)") end
    return (path:gsub("/", " › "))
end

return function(Notes)

function Notes:folderTitle()
    if self.crosswordsApp then return _("Crosswords") end
    if self.inRecent and (self.folder or "") == "" then return _("Recent") end
    if (self.folder or "") == "" then return _("Notes") end
    return shown(self.folder)
end

--- The list in the folder shown: back up, new notebook and folder, search,
-- the folders in it, then its notebooks. While selecting, every folder and
-- notebook has a box, and the first row has what to do with them.
function Notes:items()
    if self.inTrash then return self:trashItems() end
    -- The Crosswords app's list (the Crosswords plugin).
    if self.crosswordsApp and self.crosswordsItems then return self:crosswordsItems() end
    local folder = self.folder or ""
    local sel = self.selection
    local items = {}
    local all = self:notebooks()
    -- Puzzle books are in the Crosswords app when it's installed.
    if self:hasCrosswords() then
        local mine = {}
        for __, nb in ipairs(all) do
            if not nb.puzzle then table.insert(mine, nb) end
        end
        all = mine
    end
    local function count(path)
        return #self.folders:inside(path, (function()
            local ids = {}
            for __, nb in ipairs(all) do table.insert(ids, nb.id) end
            return ids
        end)())
    end
    if sel then
        local n = 0
        for __ in pairs(sel) do n = n + 1 end
        table.insert(items, { text = T(_("%1 selected: what to do…"), n), bold = true, callback = function() self:bulkActions() end })
        table.insert(items, { text = _("Done selecting"), callback = function() self:endSelection() end })
    elseif self.inRecent and folder == "" then
        -- The Recent folder: back to the list.
        table.insert(items, { text = "‹ " .. _("Notes"), bold = true, callback = function() self:openFolder("") end })
    else
        if folder ~= "" then
            local up = Folders.parent(folder)
            table.insert(items, { text = "‹ " .. (up == "" and _("Notes") or Folders.name(up)), bold = true,
                callback = function() self:openFolder(up) end })
        end
        -- Making things, then places to go, then the list's tools (Search and
        -- Sort, icons at the end of the covers' top bar).
        table.insert(items, { text = _("+ New notebook"), bold = true, callback = function() self:newNotebook() end })
        table.insert(items, { text = _("+ New folder"), icon = "folder-plus", callback = function() self:newFolder() end })
        if folder == "" then
            table.insert(items, { text = _("Today's page"), callback = function() self:todayPage() end })
        end
        -- The Crosswords app (when installed).
        if folder == "" and self:hasCrosswords() then
            table.insert(items, { text = _("Crosswords"), callback = function() self:showCrosswords() end })
        end
        if folder == "" then
            -- Your OneNote, to read (when signed in).
            local ok, signedIn = pcall(function() return self:oneNote():signedIn() end)
            if ok and signedIn then
                table.insert(items, { text = _("OneNote"), callback = function() self:browseOneNote() end })
            end
            table.insert(items, { text = _("Search"), icon = "search", callback = function() self:search() end })
        end
        -- Sort: notebooks and folders.
        local SHORT = { name = _("Name"), created = _("Created"), modified = _("Modified"), custom = _("My order") }
        table.insert(items, { text = T(_("Sort: %1"), SHORT[Settings.get("sort")] or SHORT.modified), icon = "arrow-up-down",
            callback = function() self:pickSort() end })
    end
    local function box(key) return sel and (sel[key] and "☑ " or "☐ ") or "" end
    -- The notebooks opened last, at the top of the list (not again below).
    local shownRecent = {}
    local function notebookItem(nb, key, note)
        local locked = self:isLocked(nb.id)
        local tags = {}
        if note then table.insert(tags, note) end
        if self:isPinned(nb.id) then table.insert(tags, _("Pinned")) end
        if locked then table.insert(tags, _("Locked")) end
        table.insert(tags, T(_("%1 · %2"), pages(nb.pages), os.date("%b %d", nb.modified)))
        return {
            nb = nb.id,
            modified = nb.modified,
            locked = locked or nil,
            pinned = self:isPinned(nb.id) or nil,
            recent = note ~= nil or nil,
            text = box(key) .. nb.name,
            mandatory = table.concat(tags, " · "),
            callback = function()
                if sel then self:toggleSelected(key) else self:open(nb.id) end
            end,
            hold_callback = function() if not sel then self:notebookActions(nb) end end,
        }
    end
    local recentMode = Settings.recentMode()
    if self.inRecent and folder == "" then
        -- In the Recent folder: the notebooks opened last, newest first.
        for __, nb in ipairs(self:recentOpened(all, 8)) do table.insert(items, notebookItem(nb, "n:" .. nb.id)) end
        return items
    end
    if folder == "" and not sel and recentMode == "top" then
        for __, nb in ipairs(self:recentOpened(all, 4)) do
            shownRecent[nb.id] = true
            table.insert(items, notebookItem(nb, "n:" .. nb.id, _("Recent")))
        end
    elseif folder == "" and not sel and recentMode == "folder" then
        -- A Recent folder first, showing the covers of the ones opened last.
        local recent = self:recentOpened(all, 8)
        if #recent > 0 then
            local peek = {}
            for __, nb in ipairs(recent) do
                if #peek < 4 and not self:isLocked(nb.id) then table.insert(peek, { nb = nb.id, modified = nb.modified }) end
            end
            table.insert(items, { peek = peek, recent = true, text = "▸ " .. _("Recent"),
                mandatory = #recent == 1 and _("1 notebook") or T(_("%1 notebooks"), #recent),
                callback = function() self:openRecent() end })
        end
    end
    -- Folders in the same order as the notebooks (by name for My order):
    -- created when made (else their oldest notebook), modified as their
    -- newest notebook.
    local byId = {}
    for __, nb in ipairs(all) do byId[nb.id] = nb end
    local function folderInfo(path)
        local info = { created = self.folders.created[path], modified = 0 }
        local oldest
        for __, id in ipairs(self.folders:inside(path, (function()
            local ids = {}
            for __, nb in ipairs(all) do table.insert(ids, nb.id) end
            return ids
        end)())) do
            local nb = byId[id]
            if nb then
                info.modified = math.max(info.modified, nb.modified or 0)
                if not oldest or (nb.created or 0) < oldest then oldest = nb.created or 0 end
            end
        end
        info.created = info.created or oldest or 0
        return info
    end
    -- (The Crosswords folders, once their puzzle books are left out: not shown.)
    local cwFolder = _("Crosswords")
    local function crosswordsOnly(path, n)
        return self:hasCrosswords() and n == 0 and (path == cwFolder or path:sub(1, #cwFolder + 1) == cwFolder .. "/")
    end
    for __, path in ipairs(Folders.sorted(self.folders:children(folder), Settings.get("sort"), folderInfo)) do
        local key = "f:" .. path
        local n = count(path)
        if not crosswordsOnly(path, n) then table.insert(items, {
            folder = path,
            text = box(key) .. "▸ " .. Folders.name(path),
            mandatory = n == 0 and _("Empty") or n == 1 and _("1 notebook") or T(_("%1 notebooks"), n),
            callback = function()
                if sel then self:toggleSelected(key) else self:openFolder(path) end
            end,
            hold_callback = function() if not sel then self:folderActions(path) end end,
        }) end
    end
    for __, nb in ipairs(all) do
        if self.folders:of(nb.id) == folder and not shownRecent[nb.id] then
            table.insert(items, notebookItem(nb, "n:" .. nb.id))
        end
    end
    if folder == "" and not sel then
        local n = #self.store:trashList()
        if n > 0 then
            table.insert(items, { trash = true, text = _("Trash"), mandatory = n == 1 and _("1 notebook") or T(_("%1 notebooks"), n),
                callback = function() self:openTrash() end })
        end
    end
    return items
end

-- ------------------------------------------------------------------ the trash

--- A notebook into the trash, remembering its folder.
function Notes:trashNotebook(id, folder)
    if self.store:trash(id, folder or self.folders:of(id)) then
        self.folders:forget(id)
        return true
    end
    -- It could not be moved (a full card?): it stays.
    KO.message(_("Could not move the notebook to the trash."))
    return false
end

function Notes:openTrash()
    self.inTrash = true
    self.selection = nil
    if self.menu then self.menu:switchItemTable(_("Trash"), self:items(), 1) end
end

function Notes:trashItems()
    local items = {
        { text = "‹ " .. _("Notes"), bold = true, callback = function()
            self.inTrash = false
            self:openFolder("")
        end },
    }
    local list = self.store:trashList()
    if #list > 0 then
        table.insert(items, { text = _("Empty trash"), callback = function()
            KO.confirm{
                text = T(_("Permanently delete the %1 notebooks in the trash? This can't be undone."), #list),
                ok = _("Empty trash"),
                onOk = function()
                    self.store:emptyTrash(true)
                    self:refresh()
                end,
            }
        end })
    else
        table.insert(items, { text = _("The trash is empty."), dim = true })
    end
    for __, e in ipairs(list) do
        local days = math.max(0, Folders.TRASH_DAYS - math.floor((os.time() - e.at) / 86400))
        table.insert(items, {
            trashed = e.id,
            text = e.name,
            mandatory = T(_("%1 · deleted %2"), pages(e.pages), os.date("%b %d", e.at)),
            callback = function() self:trashActions(e, days) end,
            hold_callback = function() self:trashActions(e, days) end,
        })
    end
    return items
end

function Notes:trashActions(e, days)
    local dialog
    local function act(fn) return function() UIManager:close(dialog) fn() self:refresh() end end
    dialog = KO.buttonDialog{
        title = e.name .. "\n" .. T(_("Permanently deleted in %1 days"), days),
        title_align = "center",
        buttons = {
            { { text = _("Restore"), callback = act(function()
                local folder = self.store:restore(e.id)
                if not folder then
                    return KO.message(T(_("Could not restore %1."), e.name))
                end
                if folder ~= "" then
                    self.folders:set(e.id, folder)
                    self.folders:save()
                end
                KO.toast(T(_("Restored %1"), e.name))
            end) } },
            { { text = _("Delete permanently"), callback = function()
                UIManager:close(dialog)
                KO.confirm{
                    text = T(_("Permanently delete \"%1\"? This can't be undone."), e.name),
                    danger = true,
                    ok = _("Delete"),
                    onOk = function()
                        self.store:purge(e.id)
                        self:refresh()
                    end,
                }
            end } },
            { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
        },
    }
end

function Notes:refresh()
    if self.menu then self.menu:switchItemTable(self.inTrash and _("Trash") or self:folderTitle(), self:items(), -1) end
end

function Notes:openFolder(path)
    self.inTrash = false
    self.inRecent = false
    self.folder = path or ""
    self.selection = nil
    if self.menu then self.menu:switchItemTable(self:folderTitle(), self:items(), 1) end
end

--- The Recent folder opened: the notebooks opened last.
function Notes:openRecent()
    self.inTrash = false
    self.folder = ""
    self.inRecent = true
    self.selection = nil
    if self.menu then self.menu:switchItemTable(self:folderTitle(), self:items(), 1) end
end

--- The list's Sort button: name, date created, date modified or my order
-- (notebooks and folders; kept as the sort to start with when Default sort
-- is Last used).
function Notes:pickSort()
    local opts = {}
    for __, k in ipairs(Settings.SORT_KEYS) do table.insert(opts, { k, Settings.SORT[k] }) end
    Settings.choose(_("Sort by"), opts, Settings.get("sort") or "modified", function(v)
        if not v then return end
        if v == "custom" and #(Settings.get("custom") or {}) == 0 then
            Settings.set("sort", v)
            return self:reorderNotebooks()
        end
        Settings.set("sort", v)
        self:refresh()
    end, self.menuBack)   -- (from the list's More…: Back to it)
end

function Notes:newFolder()
    input(_("New folder"), "", _("Create"), function(name)
        name = Folders.clean(name)
        if not name then return end
        self.folders:add(Folders.join(self.folder or "", name))
        self.folders:save()
        self:refresh()
    end)
end

-- A folder picked from all of them (and the top level), or a new one made in
-- the one picked. `bad(path)`: folders that can't be picked.
function Notes:pickFolder(title, bad, done, back)
    local dialog
    local buttons = {}
    local paths = self.folders:all()
    table.insert(paths, 1, "")
    for __, path in ipairs(paths) do
        if not (bad and bad(path)) then
            local depth = path == "" and 0 or select(2, path:gsub("/", "")) + 1
            table.insert(buttons, { { text = string.rep("   ", depth) .. (path == "" and _("Notes (top level)") or "▸ " .. Folders.name(path)),
                align = "left", callback = function()
                    UIManager:close(dialog)
                    done(path)
                end } })
        end
    end
    table.insert(buttons, { { text = _("New subfolder…"), callback = function()
        UIManager:close(dialog)
        input(_("New folder"), "", _("Create"), function(name)
            name = Folders.clean(name)
            if not name then return end
            local path = Folders.join(self.folder or "", name)
            self.folders:add(path)
            done(path)
        end)
    end } })
    table.insert(buttons, { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } })
    dialog = KO.buttonDialog{ title = title, title_align = "center", buttons = buttons, back = back }
end

--- Hold on a folder.
function Notes:folderActions(path)
    local dialog
    local function act(fn) return function() UIManager:close(dialog) fn() end end
    local buttons = {
        {
            { text = _("Rename"), callback = act(function() self:renameFolder(path) end) },
            { text = _("Move to…"), callback = act(function() self:moveSelection({ ["f:" .. path] = true }, function() self:folderActions(path) end) end) },
        },
        {
            { text = _("Select"), callback = act(function() self:startSelection("f:" .. path) end) },
            { text = _("Delete…"), callback = act(function() self:deleteSelection({ ["f:" .. path] = true }) end) },
        },
        { { text = _("Cover…"), callback = act(function() self:chooseFolderCover(path, function() self:folderActions(path) end) end) } },
    }
    -- Where its notebooks go in OneNote (when signed in).
    if self:oneNote():signedIn() then
        table.insert(buttons, { { text = self:oneNoteWhereText("f:" .. path) .. "…", callback = act(function()
            self:pickOneNoteTarget("f:" .. path, Folders.name(path), nil, function() self:folderActions(path) end)
        end) } })
    end
    -- A tile for it in the Apps launcher (when Apps is installed).
    local apps = self.ui and self.ui.apps
    if apps and apps.addPin then
        table.insert(buttons, { { text = _("Add to launcher"), callback = act(function()
            apps:addPin({ kind = "notefolder", id = path, name = Folders.name(path), icon = "folder" })
        end) } })
    end
    table.insert(buttons, { { text = _("Close"), callback = act(function() end) } })
    dialog = KO.buttonDialog{
        title = shown(path),
        title_align = "center",
        buttons = buttons,
    }
end

-- Icons a folder's cover can have (icons/<name>.svg).
local COVER_ICONS = {
    { "house", _("House") }, { "briefcase", _("Briefcase") }, { "book", _("Book") }, { "graduation-cap", _("School") },
    { "heart", _("Heart") }, { "star", _("Star") }, { "pencil", _("Pencil") }, { "list-todo", _("Checklist") },
    { "calendar", _("Calendar") }, { "lightbulb", _("Light bulb") }, { "music", _("Music") }, { "palette", _("Art") },
    { "code", _("Code") }, { "wrench", _("Tools") }, { "shopping-cart", _("Shopping") }, { "utensils", _("Food") },
    { "coffee", _("Coffee") }, { "dumbbell", _("Fitness") }, { "plane", _("Travel") }, { "car", _("Car") },
    { "dog", _("Pets") }, { "baby", _("Baby") }, { "sprout", _("Garden") }, { "gamepad-2", _("Games") },
}

--- A folder's cover picked: the notebooks in it (default), a plain folder,
-- an icon or one of its notebooks.
function Notes:chooseFolderCover(path, back)
    local current = self.folders:cover(path) or "default"
    local kind = current:match("^(%a+):") or current
    local function set(c)
        self.folders:setCover(path, c)
        self.folders:save()
        self:refresh()
    end
    Settings.choose(T(_("Cover of %1"), Folders.name(path)), {
        { "default", _("Automatic") },
        { "plain", _("Folder icon") },
        { "icon", _("Icon…") },
        { "nb", _("Notebook…") },
    }, kind, function(v)
        if v == nil then return end
        if v == "default" then return set(nil) end
        if v == "plain" then return set("plain") end
        if v == "icon" then
            local opts = {}
            for __, o in ipairs(COVER_ICONS) do table.insert(opts, { "icon:" .. o[1], o[2] }) end
            return Settings.choose(_("Icon"), opts, current, function(c) if c then set(c) end end,
                function() self:chooseFolderCover(path, back) end)
        end
        local opts = {}
        local list = self.store:list()
        local names = {}
        local ids = {}
        for __, e in ipairs(list) do
            names[e.id] = e.name
            table.insert(ids, e.id)
        end
        for __, id in ipairs(self.folders:inside(path, ids)) do table.insert(opts, { "nb:" .. id, names[id] }) end
        if #opts == 0 then return KO.message(_("There are no notebooks in this folder.")) end
        Settings.choose(_("Notebook"), opts, current, function(c) if c then set(c) end end,
            function() self:chooseFolderCover(path, back) end)
    end, back)
end

function Notes:renameFolder(path)
    input(_("Rename folder"), Folders.name(path), _("Save"), function(name)
        name = Folders.clean(name)
        if not name then return end
        local to = Folders.join(Folders.parent(path), name)
        if to == path then return end
        if not self.folders:rename(path, to) then
            return KO.message(_("There is already a folder with that name here."))
        end
        self:moveOneNoteTargets(path, to)
        self.folders:save()
        self:refresh()
    end)
end

-- ------------------------------------------------------------------ selecting several

function Notes:startSelection(key)
    self.selection = {}
    if key then self.selection[key] = true end
    self:refresh()
end

function Notes:endSelection()
    self.selection = nil
    self:refresh()
end

function Notes:toggleSelected(key)
    self.selection[key] = not self.selection[key] or nil
    self:refresh()
end

-- The notebooks and folders in a selection: ids, paths.
local function parts(sel)
    local ids, paths = {}, {}
    for key in pairs(sel) do
        local kind, v = key:match("^(%a):(.*)$")
        if kind == "n" then table.insert(ids, v) elseif kind == "f" then table.insert(paths, v) end
    end
    table.sort(paths)
    return ids, paths
end

function Notes:bulkActions()
    local sel = self.selection
    local ids, paths = parts(sel)
    local dialog
    local function act(fn) return function() UIManager:close(dialog) fn() end end
    local buttons = {
        {
            { text = _("Move to…"), enabled = #ids + #paths > 0, callback = act(function() self:moveSelection(sel) end) },
            { text = _("Delete…"), enabled = #ids + #paths > 0, callback = act(function() self:deleteSelection(sel) end) },
        },
        {
            { text = _("Duplicate"), enabled = #ids > 0, callback = act(function()
                for __, id in ipairs(ids) do
                    local entry = self.store:read(id)
                    if entry then
                        local copy = self.store:duplicate(id, T(_("%1 (copy)"), entry.name))
                        if copy then self.folders:set(copy.id, self.folders:of(id)) end
                    end
                end
                self.folders:save()
                self:endSelection()
            end) },
            { text = _("Send to OneNote"), enabled = #ids > 0 and self.sendToOneNote ~= nil, callback = act(function()
                for __, id in ipairs(ids) do self:sendToOneNote(id) end
                self:endSelection()
            end) },
        },
        {
            { text = _("Select all here"), callback = act(function()
                for __, item in ipairs(self:selectableHere()) do sel[item] = true end
                self:refresh()
            end) },
            { text = _("Select none"), callback = act(function()
                self.selection = {}
                self:refresh()
            end) },
        },
        { { text = _("Done selecting"), callback = act(function() self:endSelection() end) } },
    }
    dialog = KO.buttonDialog{
        title = T(_("%1 notebooks, %2 folders selected"), #ids, #paths),
        title_align = "center",
        buttons = buttons,
    }
end

-- The keys of the folders and notebooks in the folder shown.
function Notes:selectableHere()
    local out = {}
    local folder = self.folder or ""
    for __, path in ipairs(self.folders:children(folder)) do table.insert(out, "f:" .. path) end
    for __, nb in ipairs(self:notebooks()) do
        if self.folders:of(nb.id) == folder then table.insert(out, "n:" .. nb.id) end
    end
    return out
end

--- Folders and notebooks (a selection: { ["n:id"] or ["f:path"] = true })
-- into a folder picked.
function Notes:moveSelection(sel, back)
    local ids, paths = parts(sel)
    local function bad(to)
        for __, p in ipairs(paths) do
            if Folders.within(to, p) and to ~= "" or Folders.parent(p) == to and #ids == 0 and #paths == 1 then return true end
        end
        return false
    end
    self:pickFolder(T(_("Move %1 to"), #ids + #paths == 1 and (ids[1] and _("the notebook") or _("the folder"))
        or T(_("%1 items"), #ids + #paths)), bad, function(to)
        for __, id in ipairs(ids) do self.folders:set(id, to) end
        local failed = 0
        for __, p in ipairs(paths) do
            local dest = Folders.join(to, Folders.name(p))
            if dest ~= p then
                if self.folders:rename(p, dest) then self:moveOneNoteTargets(p, dest) else failed = failed + 1 end
            end
        end
        self.folders:save()
        self.selection = nil
        self:refresh()
        if failed > 0 then
            KO.message(_("A folder with the same name is already there; that folder was not moved."))
        else
            KO.toast(T(_("Moved to %1"), shown(to)))
        end
    end, back)
end

--- Folders and notebooks deleted, after asking: a folder's notebooks are
-- deleted with it, or kept (moved up to where the folder was).
function Notes:deleteSelection(sel)
    local ids, paths = parts(sel)
    local allIds = {}
    for __, nb in ipairs(self:notebooks()) do table.insert(allIds, nb.id) end
    local inFolders = {}
    for __, p in ipairs(paths) do
        for __, id in ipairs(self.folders:inside(p, allIds)) do inFolders[id] = true end
    end
    for __, id in ipairs(ids) do inFolders[id] = nil end
    local nIn = 0
    for __ in pairs(inFolders) do nIn = nIn + 1 end
    -- (As it was, for Undo: the folders, and the notebooks put in the trash.)
    local snap = self.folders:snapshot()
    local trashed = {}
    local what = {}
    if #ids > 0 then table.insert(what, #ids == 1 and _("1 notebook") or T(_("%1 notebooks"), #ids)) end
    if #paths > 0 then table.insert(what, #paths == 1 and _("1 folder") or T(_("%1 folders"), #paths)) end
    local function finish()
        self.folders:save()
        self.selection = nil
        self:refresh()
        self:offerUndo(T(_("Deleted %1"), table.concat(what, _(" and "))), trashed, snap)
    end
    local folderOf = {}
    for __, nb in ipairs(self:notebooks()) do folderOf[nb.id] = self.folders:of(nb.id) end
    local function deleteNotebooks(list)
        for __, id in ipairs(list) do
            if folderOf[id] then
                if self:trashNotebook(id, folderOf[id]) then table.insert(trashed, id) end
            else
                self.folders:forget(id)
            end
        end
    end
    local text = T(_("Delete %1? Notebooks are moved to the trash, where you can restore them for 30 days."), table.concat(what, _(" and ")))
    if nIn == 0 then
        -- Nothing to choose: at once, with Undo (asked first without it).
        if KO.canUndo() then
            deleteNotebooks(ids)
            for __, p in ipairs(paths) do self.folders:remove(p, Folders.parent(p)) end
            return finish()
        end
        return KO.confirm{
            text = text,
            danger = true,
            ok = _("Delete"),
            onOk = function()
                deleteNotebooks(ids)
                for __, p in ipairs(paths) do self.folders:remove(p, Folders.parent(p)) end
                finish()
            end,
        }
    end
    local dialog
    dialog = KO.buttonDialog{
        title = text .. "\n\n" .. (#paths == 1 and (nIn == 1 and _("The folder has a notebook in it.")
            or T(_("The folder has %1 notebooks in it."), nIn))
            or T(_("The folders have %1 notebooks in them."), nIn)),
        title_align = "center",
        buttons = {
            { { text = _("Delete folder and notebooks"), callback = function()
                UIManager:close(dialog)
                deleteNotebooks(ids)
                for __, p in ipairs(paths) do deleteNotebooks(self.folders:remove(p, nil)) end
                finish()
            end } },
            { { text = _("Delete folder only (keep notebooks)"), callback = function()
                UIManager:close(dialog)
                deleteNotebooks(ids)
                for __, p in ipairs(paths) do self.folders:remove(p, Folders.parent(p)) end
                finish()
            end } },
            { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
        },
    }
end

end
