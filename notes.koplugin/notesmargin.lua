--[[--
Writing on the pages of a book open in KOReader's reader (PDFs and other
fixed-page books): the Notes pen over the page, the ink kept with the book
(in its settings beside it) in the page's own units, so it stays in place
when you zoom, and shows whenever the page does.

Turned on with "Write on this page" (the reader's menu, or a gesture);
the editor's top button, or the gesture again, is Done.

@module koplugin.notes.margin
]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local KO = require("notesko")
local Store = require("notesstore")

local Screen = Device.screen
local KEY = "notes_margin"   -- in the book's settings: { ["page"] = { strokes in page units } }

local Margin = {}

-- A stroke from page units onto the screen: x = ox + px * z.
function Margin.toScreen(s, ox, oy, z)
    local p, out = s.p, { t = s.t, c = s.c, d = s.d, f = s.f, w = math.max(1, math.floor(s.w * z + 0.5)), p = {} }
    for i = 1, #p - 1, 2 do
        out.p[i] = math.floor(ox + p[i] * z + 0.5)
        out.p[i + 1] = math.floor(oy + p[i + 1] * z + 0.5)
    end
    if s.q then
        out.q = {}
        for i, w in ipairs(s.q) do out.q[i] = math.max(1, math.floor(w * z + 0.5)) end
    end
    return out
end

local function round2(v) return math.floor(v * 100 + 0.5) / 100 end

-- And back, in page units (to a hundredth).
function Margin.toPage(s, ox, oy, z)
    local p, out = s.p, { t = s.t, c = s.c, d = s.d, f = s.f, w = round2(s.w / z), p = {} }
    for i = 1, #p - 1, 2 do
        out.p[i] = round2((p[i] - ox) / z)
        out.p[i + 1] = round2((p[i + 1] - oy) / z)
    end
    if s.q then
        out.q = {}
        for i, w in ipairs(s.q) do out.q[i] = round2(w / z) end
    end
    return out
end

-- Where the reader shows each page now: { page, ox, oy, zoom, top, bottom }
-- (where it is on the screen, top to bottom); none for a page turned on its
-- side.
local function placements(view)
    local out = {}
    if view.page_scroll then
        local y0 = 0
        for __, st in ipairs(view.page_states or {}) do
            if (st.rotation or 0) == 0 then
                local top = y0 + st.offset.y
                table.insert(out, { st.page, st.offset.x - st.visible_area.x, top - st.visible_area.y, st.zoom,
                    top, top + st.visible_area.h })
            end
            y0 = y0 + st.visible_area.h + view.page_gap.height
        end
    elseif view.state and (view.state.rotation or 0) == 0 and view.state.page then
        local st = view.state
        table.insert(out, { st.page, st.offset.x - view.visible_area.x, st.offset.y - view.visible_area.y, st.zoom,
            st.offset.y, st.offset.y + view.visible_area.h })
    end
    return out
end

-- The page a stroke written at screen height y goes with.
local function placementAt(pls, y)
    local best, gap
    for __, pl in ipairs(pls) do
        local d = y < pl[5] and pl[5] - y or (y >= pl[6] and y - pl[6] + 1 or 0)
        if not gap or d < gap then best, gap = pl, d end
    end
    return best
end

-- The ink on the book's pages, drawn over them (a reader view module).
local Overlay = {}
Overlay.__index = Overlay

function Overlay:paintTo(bb, x, y)
    if self.hidden then return end
    local all = self.ui and self.ui.doc_settings and self.ui.doc_settings:readSetting(KEY)
    if type(all) ~= "table" or next(all) == nil then return end
    local Editor = require("noteseditor")
    local r = setmetatable({ pageRect = { 0, 0, bb:getWidth(), bb:getHeight() } }, { __index = Editor })
    for __, pl in ipairs(placements(self.view)) do
        local strokes = all[tostring(pl[1])]
        if strokes and #strokes > 0 then
            local shown = {}
            for i, s in ipairs(strokes) do shown[i] = Margin.toScreen(s, x + pl[2], y + pl[3], pl[4]) end
            r:drawStrokes(bb, shown)
        end
    end
end

return function(Notes)
    --- The ink shown over the pages of a fixed-page book open in the reader.
    function Notes:marginReady()
        local rui = self.ui
        if self.marginOverlay or not (rui and rui.document and rui.paging and rui.view and rui.view.registerViewModule) then
            return
        end
        self.marginOverlay = setmetatable({}, Overlay)
        rui.view:registerViewModule("notes_margin", self.marginOverlay)
    end

    local function info(text) KO.message(text) end

    --- Writing on the page shown (or Done, when already writing).
    function Notes:marginWrite()
        if self.marginEditor then
            if UIManager:isWidgetShown(self.marginEditor) then return self.marginEditor:close() end
            self.marginEditor = nil
        end
        local rui = self.ui
        if not (rui and rui.document and rui.paging and rui.view) then
            return info(_("Open a PDF to write on its pages."))
        end
        self:marginReady()
        local view = rui.view
        local pls = placements(view)
        if #pls == 0 then return info(_("Turn the page upright to write on it.")) end
        if not self:penReady() then return end
        local W, H = Screen:getWidth(), Screen:getHeight()
        -- The page as shown, without its ink (that is written on now).
        local bg = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
        bg:fill(Blitbuffer.COLOR_WHITE)
        self.marginOverlay.hidden = true
        local ok, why = pcall(view.paintTo, view, bg, 0, 0)
        self.marginOverlay.hidden = false
        if not ok then
            bg:free()
            return info(tostring(why))
        end
        local settings = rui.doc_settings
        local all = settings:readSetting(KEY) or {}
        -- The ink of every page on the screen (continuous view: several).
        local kept, shown = {}, {}
        for __, pl in ipairs(pls) do
            for __, s in ipairs(all[tostring(pl[1])] or {}) do
                local t = Margin.toScreen(s, pl[2], pl[3], pl[4])
                table.insert(shown, t)
                kept[t] = { pl, s }   -- unchanged strokes keep their page units exactly
            end
        end
        local title = (rui.doc_props and rui.doc_props.display_title) or _("Book")
        local nb = { id = "margin", name = title, paper = "plain", width = W, height = H,
            pages = { { id = "margin", strokes = shown } } }
        local store = {
            newPageId = Store.newPageId,
            imageDir = function() return DataStorage:getDataDir() .. "/cache" end,
            save = function(__, book)
                -- Each stroke to the page it was on, or (new) the page it starts on.
                local out = {}
                for __, pl in ipairs(pls) do out[pl] = {} end
                for __, s in ipairs(book.pages[1].strokes) do
                    local k = kept[s]
                    if k then
                        table.insert(out[k[1]], k[2])
                    else
                        local pl = placementAt(pls, s.p[2])
                        table.insert(out[pl], Margin.toPage(s, pl[2], pl[3], pl[4]))
                    end
                end
                for pl, list in pairs(out) do all[tostring(pl[1])] = #list > 0 and list or nil end
                settings:saveSetting(KEY, all)
                pcall(settings.flush, settings)
                return true
            end,
        }
        local Editor = require("noteseditor")
        local turning
        self.marginEditor = Editor:new{
            kui = rui,
            notebook = nb,
            page = 1,
            store = store,
            quiet = true,
            marginBG = bg,
            margin = {
                page = pls[1][1],
                -- The book's page turned: saved, turned, written on again.
                turn = function(dir)
                    turning = true
                    self.marginEditor:close()
                    rui:handleEvent(Event:new("GotoViewRel", dir))
                    UIManager:nextTick(function() self:marginWrite() end)
                end,
            },
            on_close = function()
                bg:free()
                self.marginEditor = nil
                if not turning then UIManager:setDirty(rui, "full") end
            end,
        }
        KO.showFull(self.marginEditor)
    end

    function Notes:onNotesMargin()
        self:marginWrite()
        return true
    end
end
