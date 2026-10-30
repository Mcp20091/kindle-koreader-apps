--[[--
Handwritten notes on highlights, in a book open in KOReader's reader.

"Write a note" in the highlight menu (for selected text, and for a tapped
highlight) opens the quick note's pad over the book. The ink is kept in the
book's settings (`notes_handnotes`, by the highlight's datetime, not its index,
which shifts) as strokes in the pad's own units, so it doesn't depend on the page
layout or the font. The highlight carries a short text note, "Handwritten note",
so KOReader's note mark shows in the margin and its counts and lists include it;
tapping the mark opens the pad with the ink.

Holding the pen's side button while selecting text makes the highlight at once
and opens its pad: the digitizer is asked once (Pen.held) when the highlight menu
is made, never on a timer and never in the input path. Not proven on a Kindle
yet: noteshandprobe.lua logs what the button reads (to be removed with it).

The first part is plain Lua (tested); calling the module with Notes adds the
KOReader side.
]]

local Hand = {}

Hand.KEY = "notes_handnotes"   -- in the book's settings: { [datetime] = { w, strokes } }

--- The highlight's text note while it has handwriting.
function Hand.marker(gettext)
    return gettext and gettext("Handwritten note") or "Handwritten note"
end

--- The pad's strokes as kept: y from the pad's top `dy`, whole numbers; `w` the pad's width.
function Hand.record(strokes, dy, w)
    local out = {}
    for i, s in ipairs(strokes) do
        local c = { t = s.t, c = s.c, d = s.d, f = s.f, w = s.w, p = {} }
        for j = 1, #s.p - 1, 2 do
            c.p[j] = math.floor(s.p[j] + 0.5)
            c.p[j + 1] = math.floor(s.p[j + 1] - dy + 0.5)
        end
        if s.q then
            c.q = {}
            for k, q in ipairs(s.q) do c.q[k] = q end
        end
        out[i] = c
    end
    return { w = w, strokes = out }
end

--- A kept note on a pad `w` wide whose top is `dy`: scaled when the width differs.
function Hand.toPad(rec, dy, w)
    local z = (rec.w and rec.w > 0) and w / rec.w or 1
    local out = {}
    for i, s in ipairs(rec.strokes or {}) do
        local c = { t = s.t, c = s.c, d = s.d, f = s.f, w = math.max(1, math.floor(s.w * z + 0.5)), p = {} }
        for j = 1, #s.p - 1, 2 do
            c.p[j] = math.floor(s.p[j] * z + 0.5)
            c.p[j + 1] = math.floor(s.p[j + 1] * z + dy + 0.5)
        end
        if s.q then
            c.q = {}
            for k, q in ipairs(s.q) do c.q[k] = math.max(1, math.floor(q * z + 0.5)) end
        end
        out[i] = c
    end
    return out
end

--- The index of the highlight with this datetime, or nil.
function Hand.indexOf(annotations, datetime)
    for i, a in ipairs(annotations or {}) do
        if a.datetime == datetime then return i end
    end
end

--- Whether the highlight has handwriting in `all` (the book's notes_handnotes).
function Hand.has(all, annotation)
    local rec = type(all) == "table" and annotation and annotation.datetime and all[annotation.datetime]
    return type(rec) == "table" and #(rec.strokes or {}) > 0
end

--- `all` without the notes of highlights that are gone; and how many are left.
function Hand.prune(all, annotations)
    local alive = {}
    for __, a in ipairs(annotations or {}) do
        if a.datetime then alive[a.datetime] = true end
    end
    local out, n = {}, 0
    for dt, rec in pairs(all or {}) do
        if alive[dt] then
            out[dt] = rec
            n = n + 1
        end
    end
    return out, n
end

-- ------------------------------------------------------------------ KOReader's side

return setmetatable(Hand, { __call = function(__, Notes)
    local Blitbuffer = require("ffi/blitbuffer")
    local DataStorage = require("datastorage")
    local Device = require("device")
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    local _ = require("gettext")

    local KO = require("notesko")
    local Settings = require("notessettings")
    local Store = require("notesstore")
    local UI = require("notesui")
    local Screen = Device.screen

    --- In a book: "Write a note" in the highlight menu, and the note mark of a handwritten note
    -- opening its pad. Once per reader.
    function Notes:handNoteReady()
        local rui = self.ui
        local hl = rui and rui.highlight
        if self.handNoteHooked == rui or not (hl and hl.addToHighlightDialog and rui.annotation) then return end
        self.handNoteHooked = rui
        hl:addToHighlightDialog("12_notes_hand", function(this, index)
            -- (PROBE, log only: the pen's buttons as the menu is made.)
            pcall(function() require("noteshandprobe").log(index and "highlight menu, tapped highlight" or "highlight menu, new selection") end)
            -- The side button held as the text was selected: the highlight is made at once and its
            -- pad opens (left empty, it stays a plain highlight).
            if not index and Settings.get("pen_highlight") ~= false then
                local ok, held = pcall(require("notespen").held)
                if ok and held and held.side then
                    UIManager:nextTick(function()
                        this:showHighlightPrompt(function(i) if i then self:handNote(i) end end)
                    end)
                end
            end
            return {
                text = _("Write a note"),
                enabled = Device:isTouchDevice(),
                callback = function()
                    if index then
                        UIManager:close(this.highlight_dialog)
                        this.highlight_dialog = nil
                        self:handNote(index)
                    else
                        -- (Saves the highlight first, as KOReader's own Add note does.)
                        this:showHighlightPrompt(function(i) if i then self:handNote(i) end end)
                    end
                end,
            }
        end)
        -- The note mark in the margin: the pad for a handwritten note, KOReader's viewer for a typed one.
        local shown = hl.showHighlightNoteOrDialog
        hl.showHighlightNoteOrDialog = function(this, index, ...)
            local a = rui.annotation.annotations[index]
            local all = rui.doc_settings and rui.doc_settings:readSetting(Hand.KEY)
            if a and a.note == Hand.marker(_) and Hand.has(all, a) then return self:handNote(index) end
            return shown(this, index, ...)
        end
    end

    --- The pad for highlight `index`'s note, over the book, with its ink. Saved: kept in the book's
    -- settings and the highlight marked; saved with no ink: the handwritten note taken away.
    function Notes:handNote(index)
        local rui = self.ui
        local anno = rui and rui.annotation and rui.annotation.annotations[index]
        if not (anno and anno.datetime) then return end
        if not self:penReady() then return end
        local settings = rui.doc_settings
        local datetime = anno.datetime
        local W, H = Screen:getWidth(), Screen:getHeight()
        UIManager:forceRePaint()
        local shot = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
        shot:blitFrom(Screen.bb, 0, 0, 0, 0, W, H)
        local plain = shot:copy()   -- (as it was, for Peek)
        shot:lightenRect(0, 0, W, H, 0.6)
        local ui = UI.new()
        local top = math.floor(H * 0.5)
        local rec = (settings:readSetting(Hand.KEY) or {})[datetime]
        local nb = { id = "handnote", name = _("Write a note"), paper = "plain", width = W, height = H,
            pages = { { id = "handnote", strokes = rec and Hand.toPad(rec, top, W) or {} } } }
        local discarded = false
        local store = {
            newPageId = Store.newPageId,
            imageDir = function() return DataStorage:getDataDir() .. "/cache" end,
            save = function(__, book)
                if discarded then return true end
                local list = rui.annotation.annotations
                -- (Found again by its datetime: the list may have changed while the pad was open.)
                local i = Hand.indexOf(list, datetime)
                local a = i and list[i]
                if not a then return true end
                local all = settings:readSetting(Hand.KEY) or {}
                local strokes = book.pages[1].strokes
                local hadNote = a.note ~= nil
                if #strokes > 0 then
                    local dy = self.handEditor and self.handEditor.pageRect[2] or top
                    all[datetime] = Hand.record(strokes, dy, W)
                    a.note = Hand.marker(_)
                else
                    all[datetime] = nil
                    if a.note == Hand.marker(_) then a.note = nil end
                end
                all = Hand.prune(all, list)
                settings:saveSetting(Hand.KEY, next(all) and all or nil)
                pcall(settings.flush, settings)
                rui:handleEvent(Event:new("AnnotationsModified",
                    { a, nb_highlights_added = 1, nb_notes_added = (a.note and 1 or 0) - (hadNote and 1 or 0) }))
                return true
            end,
        }
        self.handEditor = require("noteseditor"):new{
            kui = rui,
            notebook = nb,
            page = 1,
            store = store,
            quiet = true,
            quick = { top = top, flip = false,
                background = function(ed) return Notes.Quick.padBackground(shot, ed, ui) end,
                moved = function() end,
                peek = function(ed) Notes.Quick.peek(plain, function() UIManager:setDirty(ed, "full") end) end,
                -- Discard: this time's ink thrown away, the note as it was.
                discard = function(ed) discarded = true ed:close() end },
            on_close = function()
                shot:free()
                plain:free()
                ui:free()
                self.handEditor = nil
                UIManager:setDirty("all", "full")
            end,
        }
        KO.showFull(self.handEditor)
    end

    --- PROBE (goes with noteshandprobe.lua): the pen's buttons 4 s after the tap, so the pen can
    -- be brought near with its side button held; shown and logged.
    function Notes:handProbeCheck()
        KO.toast(_("Hold the pen's side button near the screen now…"), 3)
        UIManager:scheduleIn(4, function()
            local ok, line = pcall(function() return require("noteshandprobe").log("menu check") end)
            KO.message(ok and line or tostring(line))
        end)
    end
end })
