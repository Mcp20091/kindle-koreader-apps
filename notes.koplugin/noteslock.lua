--[[--
Pinned and recent notebooks, and notebooks locked with a PIN.

Pinned notebooks come first in their folder; the notebooks opened last
show at the top of the notebook list (Recent). A locked notebook asks for
its PIN when opened (not again for two minutes), shows a lock instead of
its cover, and is left out of search, OneNote's automatic sending and the
web page. The PIN is kept as a hash in Notes' settings, not in the
notebook.

@module koplugin.notes.lock
]]

local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local KO = require("notesko")

local Settings = require("notessettings")

local UNLOCKED_FOR = 120   -- seconds a notebook stays open to you after its PIN

local function info(text) KO.message(text) end

local function hash(id, pin)
    return require("ffi/sha2").sha256("notes:" .. id .. ":" .. pin)
end

return function(Notes)
    -- ------------------------------------------------------------------ pinned

    function Notes:isPinned(id)
        for __, p in ipairs(Settings.get("pinned") or {}) do
            if p == id then return true end
        end
        return false
    end

    function Notes:setPinned(id, on)
        local out = {}
        for __, p in ipairs(Settings.get("pinned") or {}) do
            if p ~= id then table.insert(out, p) end
        end
        if on then table.insert(out, 1, id) end
        Settings.set("pinned", out)
    end

    --- Notebooks with the pinned ones first (in the order pinned, newest first).
    function Notes.pinnedFirst(list)
        local pinned = Settings.get("pinned") or {}
        if #pinned == 0 then return list end
        local rank = {}
        for i, id in ipairs(pinned) do rank[id] = i end
        local first, rest = {}, {}
        for __, nb in ipairs(list) do
            if rank[nb.id] then table.insert(first, nb) else table.insert(rest, nb) end
        end
        table.sort(first, function(a, b) return rank[a.id] < rank[b.id] end)
        for __, nb in ipairs(rest) do table.insert(first, nb) end
        return first
    end

    -- ------------------------------------------------------------------ recent

    --- A notebook opened: first in Recent.
    function Notes:noteOpened(id)
        local out = { id }
        for __, r in ipairs(Settings.get("recent") or {}) do
            if r ~= id and #out < 8 then table.insert(out, r) end
        end
        Settings.set("recent", out)
        -- When, for the launcher's Recent notebooks (opened or changed last).
        local at = Settings.get("opened_at") or {}
        at[id] = os.time()
        local keep = {}
        for __, r in ipairs(out) do keep[r] = at[r] end
        Settings.set("opened_at", keep)
    end

    --- The notebooks opened last (list entries, up to `n`), still there.
    function Notes:recentOpened(all, n)
        local byId = {}
        for __, nb in ipairs(all) do byId[nb.id] = nb end
        local out = {}
        for __, id in ipairs(Settings.get("recent") or {}) do
            if byId[id] then table.insert(out, byId[id]) end
            if #out == n then break end
        end
        return out
    end

    --- For the Apps launcher's Recent notebooks: the notebooks opened or
    -- changed last, newest first, at most `limit` (not puzzle books or the
    -- trash): { id, name, modified, pages, locked, cover } (cover: a small
    -- picture of the first page, nil while it isn't drawn yet, and for a
    -- locked notebook). Quick: the list's own index; missing covers are drawn
    -- afterwards, one at a time.
    function Notes:recentNotebooks(limit)
        limit = limit or 6
        local at = Settings.get("opened_at") or {}
        local list = {}
        for __, e in ipairs(self.store:list()) do
            table.insert(list, { e = e, t = math.max(at[e.id] or 0, e.modified or 0) })
        end
        table.sort(list, function(a, b) return a.t > b.t end)
        local dir = self.store.dir .. "/covers"
        local out, missing = {}, {}
        for __, c in ipairs(list) do
            if #out >= limit then break end
            local e = c.e
            if not self:isPuzzleBook(e.id) then
                local locked = self:isLocked(e.id) or nil
                local cover
                if not locked then
                    cover = string.format("%s/%s_%d_s.png", dir, e.id, e.modified or 0)
                    local f = io.open(cover, "rb")
                    if f then f:close() else
                        table.insert(missing, e)
                        cover = nil
                    end
                end
                table.insert(out, { id = e.id, name = e.name, modified = e.modified, pages = e.pages, locked = locked,
                    cover = cover })
            end
        end
        if #missing > 0 then self:drawCoversLater(missing) end
        return out
    end

    -- Whether a notebook is a puzzle book (from the start of its file; kept).
    function Notes:isPuzzleBook(id)
        self.puzzleIds = self.puzzleIds or {}
        local known = self.puzzleIds[id]
        if known ~= nil then return known end
        local f = io.open(self.store:path(id), "rb")
        local head = f and f:read(4096) or ""
        if f then f:close() end
        local puzzle = (head:match("^return {(.-),pages={") or ""):find("puzzle=true", 1, true) ~= nil
        self.puzzleIds[id] = puzzle
        return puzzle
    end

    -- Covers not drawn yet, drawn one at a time after the launcher has asked
    -- (the notebook list's covers: the same files).
    function Notes:drawCoversLater(entries)
        if self.coversQueued then return end
        self.coversQueued = true
        local dir = self.store.dir .. "/covers"
        local k = 0
        local function step()
            k = k + 1
            local e = entries[k]
            if not e then
                self.coversQueued = nil
                return
            end
            pcall(function()
                local nb = self.store:read(e.id)
                if not nb then return end
                require("util").makePath(dir)
                local lfs = require("libs/libkoreader-lfs")
                for name in lfs.dir(dir) do
                    if name:find("^" .. e.id .. "_%d+[_%a]*%.png$") then os.remove(dir .. "/" .. name) end
                end
                require("noteseditor").pagePNG(nb, 1, string.format("%s/%s_%d_s.png", dir, e.id, e.modified or 0), { long = 600 })
            end)
            UIManager:scheduleIn(0.2, step)
        end
        UIManager:scheduleIn(0.5, step)
    end

    -- ------------------------------------------------------------------ locked

    function Notes:isLocked(id)
        return (Settings.get("locks") or {})[id] ~= nil
    end

    -- A PIN typed: `done(pin)` (nil on Cancel).
    local function askPIN(title, done)
        local request = KO.request()
        if request then
            -- (The launcher's box: the PIN as dots, the numbers' keyboard.)
            return request{ title = title, number = true, password = true, typing = true, onCancel = function() done(nil) end,
                buttons = {
                    { icon = "x", text = _("Cancel"), cancel = true },
                    { icon = "check", text = _("OK"), primary = true, needsText = true, fn = function(pin) done(pin) end },
                } }
        end
        local dialog
        dialog = InputDialog:new{
            title = title,
            input = "",
            input_type = "number",
            text_type = "password",
            buttons = { {
                { text = _("Cancel"), id = "close", callback = function()
                    UIManager:close(dialog)
                    done(nil)
                end },
                { text = _("OK"), is_enter_default = true, callback = function()
                    local pin = dialog:getInputText()
                    UIManager:close(dialog)
                    done(pin)
                end },
            } },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    --- `fn()` once the notebook's PIN is right (straight away when it isn't
    -- locked or was unlocked a moment ago).
    function Notes:unlockThen(id, fn)
        local h = (Settings.get("locks") or {})[id]
        if not h then return fn() end
        self.unlockedAt = self.unlockedAt or {}
        if self.unlockedAt[id] and os.time() - self.unlockedAt[id] < UNLOCKED_FOR then return fn() end
        askPIN(_("PIN"), function(pin)
            if not pin then return end
            if hash(id, pin) ~= h then return info(_("Wrong PIN.")) end
            self.unlockedAt[id] = os.time()
            fn()
        end)
    end

    --- Hold a notebook > Lock…: a PIN set (typed twice).
    function Notes:lockNotebook(entry)
        askPIN(_("New PIN (4 digits or more)"), function(pin)
            if not pin then return end
            if #pin < 4 then return info(_("Use at least 4 digits.")) end
            askPIN(_("Type the PIN again"), function(again)
                if not again then return end
                if again ~= pin then return info(_("The PINs don't match. The notebook isn't locked.")) end
                local locks = Settings.get("locks") or {}
                locks[entry.id] = hash(entry.id, pin)
                Settings.set("locks", locks)
                self.unlockedAt = self.unlockedAt or {}
                self.unlockedAt[entry.id] = nil
                self:refresh()
                info(_("Locked. You'll need the PIN to open it. If you forget it, the notebook can't be opened."))
            end)
        end)
    end

    --- Hold a notebook > Remove lock (with its PIN).
    function Notes:unlockNotebook(entry)
        self.unlockedAt = self.unlockedAt or {}
        self.unlockedAt[entry.id] = nil
        self:unlockThen(entry.id, function()
            local locks = Settings.get("locks") or {}
            locks[entry.id] = nil
            Settings.set("locks", locks)
            self:refresh()
        end)
    end
end
