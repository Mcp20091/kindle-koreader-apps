--[[--
Quick note: a writing pad over whatever is on the screen (a book, a menu,
To Do), from a gesture (General > Notes: quick note). What is written goes
on a new page of the Quick Notes notebook (made the first time; once called Inbox); the top button
(✓) is Done. Nothing written: nothing kept.

@module koplugin.notes.quick
]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local KO = require("notesko")
local Paper = require("notespaper")
local Settings = require("notessettings")
local Store = require("notesstore")
local UI = require("notesui")

local Screen = Device.screen

local Quick = {}
Quick.TOP = 0.42   -- the pad starts this far down the screen

--- A stroke from the pad onto the Quick Notes page: moved up by `dy`, scaled by
-- `z` (a landscape pad on a portrait page), `top` from the page's top.
function Quick.toPage(s, dy, z, top)
    local out = { t = s.t, c = s.c, d = s.d, f = s.f, w = math.max(1, math.floor(s.w * z + 0.5)), p = {} }
    for i = 1, #s.p - 1, 2 do
        out.p[i] = math.floor(s.p[i] * z + 0.5)
        out.p[i + 1] = math.floor((s.p[i + 1] - dy) * z + top + 0.5)
    end
    if s.q then
        out.q = {}
        for i, w in ipairs(s.q) do out.q[i] = math.max(1, math.floor(w * z + 0.5)) end
    end
    return out
end

--- Peek: the screen the quick note was opened over, as it was, full screen; any touch goes back.
function Quick.peek(bb, back)
    local InputContainer = require("ui/widget/container/inputcontainer")
    local GestureRange = require("ui/gesturerange")
    local Geom = require("ui/geometry")
    local W, H = Screen:getWidth(), Screen:getHeight()
    local all = Geom:new{ x = 0, y = 0, w = W, h = H }
    local view = InputContainer:new{ dimen = all, covers_fullscreen = true }
    view.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = all } },
        Hold = { GestureRange:new{ ges = "hold", range = all } },
        Swipe = { GestureRange:new{ ges = "swipe", range = all } } }
    function view:paintTo(target, x, y) target:blitFrom(bb, x, y, 0, 0, W, H) end
    local function close()
        UIManager:close(view, "full")
        if back then back() end
        return true
    end
    view.onTap, view.onHold, view.onSwipe = close, close, close
    UIManager:show(view, "full")
    require("notesko").toast(_("Tap to go back to your note"), 2)
end

return function(Notes)
    Notes.Quick = Quick

    --- The Quick Notes notebook (made the first time).
    function Notes:inbox()
        local id = Settings.get("inbox_id")
        local nb = id and self.store:read(id)
        if nb then
            -- (It was named Inbox before: renamed, unless the user named it themselves.)
            if nb.name == "Inbox" or nb.name == _("Inbox") then
                nb.name = _("Quick Notes")
                self.store:save(nb)
            end
            return nb
        end
        nb = self.store:create(_("Quick Notes"), Screen:getWidth(), Screen:getHeight(), Settings.get("paper") or "narrow")
        if nb then Settings.set("inbox_id", nb.id) end
        return nb
    end

    --- Open the pad (or, open already, Done).
    function Notes:quickNote()
        if self.quickEditor then
            if UIManager:isWidgetShown(self.quickEditor) then return self.quickEditor:close() end
            self.quickEditor = nil
        end
        if not self:penReady() then return end
        local open = self.editor and UIManager:isWidgetShown(self.editor) and self.editor.notebook
        if open and open.id == Settings.get("inbox_id") then
            return KO.message(_("Quick Notes is open: write in it here."))
        end
        local W, H = Screen:getWidth(), Screen:getHeight()
        -- What is on the screen now, faded, above the pad: drawn first, so a panel that just
        -- closed (the control center's New note) isn't in it.
        UIManager:forceRePaint()
        local shot = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
        shot:blitFrom(Screen.bb, 0, 0, 0, 0, W, H)
        -- (As it was, for Peek.)
        local plain = shot:copy()
        shot:lightenRect(0, 0, W, H, 0.6)
        local ui = UI.new()
        local inboxPage, inboxId   -- the page made for this note, once there is ink
        local discarded = false
        local function bgFor(ed)
            local r = ed.pageRect
            local bg = shot:copy()
            bg:paintRect(r[1], r[2], r[3], r[4], Blitbuffer.COLOR_WHITE)
            Paper.level = Settings.get("paper_lines") or "medium"
            Paper.paint(bg, "narrow", r[1], r[2] + ui:u(10), r[1] + r[3], r[2] + r[4], W, H, r[1])
            -- The edge between the pad and the picture (above the pad, or below it when flipped),
            -- and its handle: drag it to make the pad taller or shorter.
            local hw, hh = ui:u(60), ui:u(7)
            local hx = r[1] + math.floor((r[3] - hw) / 2)
            if ed.quick.flip then
                local e = r[2] + r[4]
                bg:paintRect(r[1], e, r[3], 3, Blitbuffer.COLOR_BLACK)
                ui:box(bg, hx, e + ui:u(11), hw, hh, { fill = UI.MID, r = math.floor(hh / 2) })
            else
                bg:paintRect(r[1], r[2] - 3, r[3], 3, Blitbuffer.COLOR_BLACK)
                ui:box(bg, hx, r[2] - ui:u(18), hw, hh, { fill = UI.MID, r = math.floor(hh / 2) })
            end
            return bg
        end
        local nb = { id = "quick", name = _("Quick note"), paper = "plain", width = W, height = H,
            pages = { { id = "quick", strokes = {} } } }
        local store = {
            newPageId = Store.newPageId,
            imageDir = function() return DataStorage:getDataDir() .. "/cache" end,
            save = function(__, book)
                if discarded then return true end
                local strokes = book.pages[1].strokes
                if #strokes == 0 and not inboxPage then return true end
                local inbox = inboxId and self.store:read(inboxId) or self:inbox()
                if not inbox then return false end
                inboxId = inbox.id
                local page
                for __, p in ipairs(inbox.pages) do
                    if p.id == inboxPage then page = p end
                end
                if not page then
                    -- A new page (the first one, while blank).
                    local first = inbox.pages[1]
                    if #inbox.pages == 1 and #first.strokes == 0 and not (first.items and #first.items > 0) then
                        page = first
                    else
                        page = { id = Store.newPageId(), strokes = {} }
                        table.insert(inbox.pages, page)
                    end
                    page.created = os.time()
                    local u = Screen:getDPI() / 100
                    page.items = { { k = "text", x = math.floor(48 * u), y = math.floor(14 * u),
                        w = math.floor((inbox.width or W) * 0.7), size = math.floor(54 * Screen:getDPI() / 300 + 0.5),
                        bold = true, text = os.date("%A, %B %d, %H:%M") } }
                    inboxPage = page.id
                end
                local ed = self.quickEditor
                local dy = ed and ed.pageRect[2] or math.floor(H * Quick.TOP)
                local z = math.min(1, (inbox.width or W) / W)
                local top = math.floor(48 * Screen:getDPI() / 100)
                page.strokes = {}
                for i, s in ipairs(strokes) do page.strokes[i] = Quick.toPage(s, dy, z, top) end
                local ok, why = self.store:save(inbox)
                if ok then self:refresh() end
                return ok, why
            end,
        }
        local Editor = require("noteseditor")
        self.quickEditor = Editor:new{
            kui = self.ui,
            notebook = nb,
            page = 1,
            store = store,
            quiet = true,
            quick = { top = math.floor(H * (Settings.get("quick_top") or Quick.TOP)), background = bgFor,
                flip = Settings.get("quick_flip") == true,
                -- The edge dragged, or the pad swapped to the other half: so next time too.
                moved = function(frac, flip)
                    Settings.set("quick_top", frac)
                    Settings.set("quick_flip", flip and true or nil)
                end,
                -- Peek: the screen as it was, whole, until a tap.
                peek = function(ed) Quick.peek(plain, function() UIManager:setDirty(ed, "full") end) end,
                -- Discard: nothing kept (the Quick Notes page taken out if it was made).
                discard = function(ed)
                    KO.confirm{ text = _("Discard this quick note?"), ok = _("Discard"), danger = true, onOk = function()
                        discarded = true
                        if inboxPage and inboxId then
                            local inbox = self.store:read(inboxId)
                            if inbox then
                                for i, p in ipairs(inbox.pages) do
                                    if p.id == inboxPage then
                                        if #inbox.pages > 1 then table.remove(inbox.pages, i) else p.strokes, p.items = {}, nil end
                                        break
                                    end
                                end
                                self.store:save(inbox)
                                self:refresh()
                            end
                        end
                        inboxPage = nil
                        ed:close()
                    end }
                end },
            on_close = function()
                shot:free()
                plain:free()
                ui:free()
                self.quickEditor = nil
                if inboxPage then
                    require("notesko").toast(T(_("Saved in %1"), _("Quick Notes")))
                end
                UIManager:setDirty("all", "full")
            end,
        }
        KO.showFull(self.quickEditor)
    end

    function Notes:onNotesQuickNote()
        self:quickNote()
        return true
    end
end
