--[[--
The page you write on, with a toolbar down one edge (Settings: left or
right, foldable into a small tab) like the Kindle Scribe's own notebooks:
pen (four tips, five sizes), highlighter, eraser, lasso, undo, redo, pages,
and a menu for the page template, export and the rest.

The pen is read straight from its digitizer (notespen): palm rejection and
pressure. Ink is drawn straight into the page image and the screen, and the
screen is told to refresh the changed area at most every INK_REFRESH seconds
in the fast "a2" mode (one refresh per pen point would queue up and lag),
then once cleanly when the pen has been still for CLEAN_AFTER seconds.

The toolbar, its panels and the lasso's selection are drawn here too (not
KOReader widgets), so the pen works them the same way it writes; fingers
only work them (a resting palm does nothing).

A puzzle book (a PDF of puzzles) has a shorter toolbar: pen, eraser, lasso,
zoom, undo, redo and Done. Its zoom shows the part of the page picked once with
the pen (the grid) as large as it fits, on every page; ink written there
lands small on the page.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ffi = require("ffi")
local DataStorage = require("datastorage")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template

local Crossword = require("notescrossword")
local Ink = require("notesink")
local Store = require("notesstore")
local PDF = require("notespdf")
local Paper = require("notespaper")
local Items = require("notesitems")
local KO = require("notesko")
local Pen = require("notespen")
local Settings = require("notessettings")
local Shapes = require("notesshapes")
local UI = require("notesui")

local Screen = Device.screen

local INK_REFRESH = 0.03                  -- seconds between fast refreshes while writing
local CLEAN_AFTER = 1.2                   -- seconds of a still pen before the clean refresh
local DRAG_REFRESH = 0.12                 -- seconds between refreshes while moving a selection
local GAP_MS = 80                         -- points further apart in time are not joined
local POLL_NEAR = 0.008                   -- seconds between digitizer reads with the pen near
local POLL_AWAY = 0.05                    -- and with it away (until KOReader is seen passing pen events on)
local POLL_IDLE = 1                       -- with it away, once KOReader wakes Notes for the pen
local SAVE_AFTER = 3                      -- seconds after the last change
local HOLD_TO_SNAP = 0.5                  -- seconds of a still pen at the end of a stroke to snap it
local SHAPE_ICONS = { line = "minus", arrow = "move-up-right", rect = "square", ellipse = "circle", triangle = "triangle",
    diamond = "diamond", star = "star", table = "grid-3x3" }
local SHAPE_NAMES = { line = _("Line"), arrow = _("Arrow"), rect = _("Rectangle"), ellipse = _("Ellipse"),
    triangle = _("Triangle"), diamond = _("Diamond"), star = _("Star"), table = _("Table") }

local TIP_ICONS = { pen = "pen", fineliner = "pen-line", fountain = "pen-tool", calligraphy = "feather", brush = "paintbrush",
    marker = "brush", pencil = "pencil", mechanical = "pencil-line", shader = "spray-can" }
local TIP_NAMES = { pen = _("Ballpoint"), fineliner = _("Fineliner"), fountain = _("Fountain"), calligraphy = _("Calligraphy"),
    brush = _("Brush"), marker = _("Marker"), pencil = _("Pencil"), mechanical = _("Mech. pencil"), shader = _("Shader") }
local PAPERS = { "plain", "narrow", "margin", "wide", "grid", "dots", "isometric", "hex", "checklist", "tasks", "cornell",
    "weekly", "calendar", "music" }
-- A puzzle book's toolbar.
local PUZZLE_TOOLS = { "pen", "eraser", "lasso", "zoom", "undo", "redo", "done" }
-- A puzzle book's ⋯ menu, any of it pinnable to the toolbar under the tools
-- (setting puzzle_buttons; Crossword settings > Toolbar buttons). Those to
-- start with: PUZZLE_DEFAULT.
local PUZZLE_BUTTONS = {
    { key = "hint", label = _("Hint"), icon = "lightbulb" },
    { key = "check", label = _("Check my answers"), icon = "spell-check" },
    { key = "getcw", label = _("Get a crossword"), icon = "newspaper" },
    { key = "random", label = _("Random puzzle"), icon = "shuffle" },
    { key = "orient", label = _("Page orientation"), icon = "rotate-cw" },
    { key = "web", label = _("Open on the web page"), icon = "qr-code" },
    { key = "ask", label = _("Ask AI"), icon = "sparkles" },
    { key = "export", label = _("Export"), icon = "file-down" },
    { key = "hide", label = _("Hide page"), icon = "eye-off" },
    { key = "rename", label = _("Rename notebook"), icon = "text-cursor-input" },
    { key = "pressure", label = _("Pen pressure"), icon = "gauge" },
    { key = "light", label = _("Light"), icon = "sun" },
    { key = "night", label = _("Night mode"), icon = "moon" },
}
local PUZZLE_DEFAULT = { "hint", "check", "random" }   -- (Refresh and Settings are always at the bottom)
-- In the ⋯ menu only (at the toolbar's bottom anyway).
local PUZZLE_MENU_ONLY = {
    { key = "refresh", label = _("Refresh screen"), icon = "refresh-cw" },
    { key = "settings", label = _("Settings"), icon = "settings" },
}
local MARGIN_TOOLS = { "pen", "eraser", "lasso", "zoom", "undo", "redo" }   -- writing on a book's page
local QUICK_TOOLS = { "pen", "hl", "eraser", "lasso", "undo", "redo", "peek", "swap", "refresh" }   -- (✓ Save and Discard at the top; all four by the pad's handle too)   -- a quick note (notesquick.lua)
local SPREAD_TOOLS = { "pen", "hl", "eraser", "undo", "redo" }               -- two pages side by side
-- Tidy handwriting (notestidy.lua): what each action does; papers whose ruled lines writing is set on.
local TIDY = {
    tidy = { level = true, upright = true, size = true, space = true },
    tidy_level = { level = true }, tidy_upright = { upright = true }, tidy_size = { size = true }, tidy_space = { space = true },
}
local RULED = { narrow = true, wide = true, margin = true, checklist = true, tasks = true }
local PAPER_SHORT = { plain = _("Blank"), narrow = _("Narrow"), wide = _("Wide"), grid = _("Grid"), dots = _("Dots"),
    margin = _("Margin"), isometric = _("Isometric"), hex = _("Hexagons"), calendar = _("Month"),
    checklist = _("Checklist"), tasks = _("Tasks"), cornell = _("Cornell"), weekly = _("Week"), music = _("Music") }

-- Cut or copied ink, kept while KOReader runs (pasting into another notebook works).
local clipboard

-- Not modal: KOReader puts dialogs opened from here (settings, rename)
-- under a modal widget, out of sight.
local MORE_GAP = 7   -- between the ⋯ menu's groups, in UI units

local Editor = InputContainer:extend{
    covers_fullscreen = true,
    notebook = nil,
    store = nil,
    on_close = nil,
}
Editor.PUZZLE_BUTTONS, Editor.PUZZLE_DEFAULT = PUZZLE_BUTTONS, PUZZLE_DEFAULT

function Editor:init()
    self.w, self.h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ui = UI.new()
    self.scale = Screen:getDPI() / 300
    self.page = math.max(1, math.min(self.page or 1, #self.notebook.pages))
    self.tool = "pen"
    self.tip = Settings.get("tip")
    if not TIP_ICONS[self.tip] then self.tip = "pen" end
    self.shade = Settings.get("shade") or "default"
    self.sizes = {}
    for k, v in pairs(Settings.get("sizes")) do self.sizes[k] = v end
    -- Opened with a favorite pen when the settings say so (else the last pen).
    local start = tonumber((Settings.get("start_pen") or ""):match("^fav(%d)$"))
    local fav = start and (Settings.get("favorites") or {})[start]
    if fav and TIP_ICONS[fav.tip] then
        self.tip = fav.tip
        self.sizes[fav.tip] = fav.size
        self.shade = fav.shade or "default"
    end
    self.eraserSize = Settings.get("eraser_size")
    self.penFeel = Settings.get("pen_feel")
    self.folded = Settings.get("folded")
    -- A quick note starts with its toolbar folded: its own buttons are by the pad's handle.
    if self.quick then self.folded = true end
    self.hits = {}
    self.undo, self.redo = {}, {}
    self.page_bb = Blitbuffer.new(self.w, self.h, Blitbuffer.TYPE_BB8)
    if self.spread then
        local pw, ph = self:pageSize()
        local nb = self.notebook
        self.spread = self.w > self.h and pw < ph and not (nb.puzzle or self.margin or self.quick) and {} or nil
    end
    -- Fingers: taps work the toolbar and panels; nothing else does anything
    -- (a resting palm must not act).
    local all = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        EditorTap = { GestureRange:new{ ges = "tap", range = all } },
        EditorHold = { GestureRange:new{ ges = "hold", range = all } },
        EditorPan = { GestureRange:new{ ges = "pan", range = all } },
        EditorSwipe = { GestureRange:new{ ges = "swipe", range = all } },
        EditorPanRelease = { GestureRange:new{ ges = "pan_release", range = all } },
    }
    self:layout()
    self:renderPage()
end

function Editor:onEditorHold(_arg, ges)
    local p = ges and ges.pos
    -- Held on an AI button: "AI for this" (the launcher's), which AI and model does that job.
    local ai = require("pluginshare").ai
    if p and ai and ai.quickPick and not self.stroke then
        for i = #(self.aiHolds or {}), 1, -1 do
            local a = self.aiHolds[i]
            if p.x >= a[1] and p.x < a[1] + a[3] and p.y >= a[2] and p.y < a[2] + a[4] then
                ai.quickPick(a[5])
                return true
            end
        end
    end
    -- Held on Undo: the steps to go back to.
    local b = self.undoButton
    if b and p and p.x >= b[1] and p.x < b[1] + b[3] and p.y >= b[2] and p.y < b[2] + b[4] and #self.undo > 0
            and not self.stroke then
        self.panel = "history"
        self:repaint()
        return true
    end
    -- Held on a toolbar button (a firm pen press counts as a hold): its tap.
    local h = p and not self.stroke and self:hitAt(p.x, p.y)
    local rail = self.folded and self.ui:u(30) or self.bar_w
    local x0 = self.side == "left" and 0 or self.w - rail
    if h and h[6] == "bar" and p.x >= x0 and p.x < x0 + rail then
        self:tapAt(p.x, p.y)
    end
    return true
end
-- A finger swiped across the page turns it, up and down (up: the next page,
-- as the toolbar's down arrow) or left and right (left: the next page), as
-- the settings say; not while the pen is near or just after it was used
-- (then it is most likely a palm).
local SWIPES = {
    vertical = { north = 1, south = -1 },
    horizontal = { west = 1, east = -1 },
}
function Editor:onEditorSwipe(_arg, ges)
    if self:swipeClues(ges) then return true end
    local swipes = SWIPES[Settings.get("swipe_pages")]
    if not swipes or not ges or self.busy or self.zoomOn or self.askPad then return true end
    local dir = swipes[ges.direction]
    if not dir then return true end
    if (ges.distance or 0) < math.min(self.w, self.h) / 6 then return true end
    if self:palmLikely() then return true end
    local r = self.pageRect
    local p = ges.pos
    if p and (p.x < r[1] or p.x >= r[1] + r[3]) then return true end
    if self.margin then return self.margin.turn(dir) end
    local to = self:nextPage(dir)
    if to then self:goPage(to) end
    return true
end

-- A crossword's clues swiped (whatever Swipe to turn pages says): turned,
-- left or up to the next. True when they were.
local CLUE_SWIPES = { west = 1, north = 1, east = -1, south = -1 }
function Editor:swipeClues(ges)
    if not (ges and ges.pos and self.notebook.feed and self.on_grid) or self.busy or self.view or self.zoomOn or self.askPad then
        return false
    end
    -- (A palm doesn't swipe that far: the pen may be near, but not writing.)
    local dir = CLUE_SWIPES[ges.direction]
    if not dir or (ges.distance or 0) < math.min(self.w, self.h) / 10 or not self:penHeld() then return false end
    local g = self.on_grid(self, self.page)
    if not g then return false end
    -- On the clues: below the grid, or beside it on its side.
    local p = ges.pos
    if self.w > self.h and p.x < g[1] + g[4] * g[3] or self.w <= self.h and p.y < g[2] + g[5] * g[3] then return false end
    local to = self:cluePage(dir)
    if not to then return false end
    self:goPage(to)
    return true
end

function Editor:onEditorTap(_arg, ges)
    -- A quick note's buttons by its handle: a finger works them too (not a palm by the pen).
    if ges and ges.pos and self.quick and not self:palmLikely() then
        local pad = self.ui:u(6)
        for __, b in ipairs(self:quickButtons()) do
            if ges.pos.x >= b.x - pad and ges.pos.x < b.x + b.w + pad and ges.pos.y >= b.y - pad and ges.pos.y < b.y + b.h + pad then
                self:quickButton(b.key)
                return true
            end
        end
    end
    if ges and ges.pos then self:tapAt(ges.pos.x, ges.pos.y, true) end
    return true
end

-- The pen near the screen, or only just used, but not writing: a finger
-- tap then is your other hand (or a finger of the one holding the pen).
function Editor:penHeld()
    if self.busy then return false end
    return self.penUpAt == nil or time.to_ms(time.now() - self.penUpAt) > 400
end

-- A finger with the pen near, or just after it: a palm, most likely.
function Editor:palmLikely()
    if self.pen and self.pen.state and self.pen.state.tool ~= nil then return true end
    return self.penAt ~= nil and time.to_ms(time.now() - self.penAt) < 1500
end

-- Your KOReader gestures that can't be a resting palm (two fingers, edge
-- swipes, multiswipes) do what they do in KOReader, when it makes sense
-- here (KO.notesSafe) and the pen isn't in use.
function Editor:onGesture(ev)
    -- Two fingers tapped: Undo; held: Redo (not right after the pen, when
    -- it is most likely a palm).
    if ev and (ev.ges == "two_finger_tap" or ev.ges == "two_finger_hold") and Settings.get("finger_undo") ~= false
            and self:onTop() then
        local recent = self.penAt and time.to_ms(time.now() - self.penAt) < 500
        if not recent and not self.askPad and not self.stroke then
            if ev.ges == "two_finger_tap" then
                if #self.undo > 0 then self:doUndo() KO.toast(_("Undo")) end
            elseif #self.redo > 0 then
                self:doRedo()
                KO.toast(_("Redo"))
            end
        end
        return true
    end
    if Settings.get("ko_gestures") ~= false and self.kui and self:onTop() and not self:palmLikely()
            and KO.passGesture(self.kui, ev, KO.notesSafe) then
        return true
    end
    return InputContainer.onGesture(self, ev)
end

function Editor:handleEvent(event)
    if InputContainer.handleEvent(self, event) then return true end
    if event.handler == "onCloseWidget" or event.handler == "onShow" then return end
    return KO.passEvent(self.kui, event)
end

-- ------------------------------------------------------------------ layout

-- The toolbar's side and width, and the part of the screen ink goes on.
function Editor:layout()
    local ui = self.ui
    self.side = Settings.get("side") == "right" and "right" or "left"
    self.order = (self.spread and SPREAD_TOOLS) or (self.quick and QUICK_TOOLS) or (self.margin and MARGIN_TOOLS)
        or (self.notebook.puzzle and self:puzzleOrder()) or Settings.toolOrder()
    self.bar_w = ui:u(36)
    if self.folded then
        self.pageRect = { 0, 0, self.w, self.h }
    elseif self.side == "left" then
        self.pageRect = { self.bar_w + 2, 0, self.w - self.bar_w - 2, self.h }
    else
        self.pageRect = { 0, 0, self.w - self.bar_w - 2, self.h }
    end
    -- A quick note: only the pad takes ink, below what was on the screen (or above it: flip).
    -- quick.top is the edge between the two.
    if self.quick then
        local r = self.pageRect
        if self.quick.flip then
            self.pageRect = { r[1], 0, r[3], self.quick.top }
        else
            self.pageRect = { r[1], self.quick.top, r[3], self.h - self.quick.top }
        end
    end
    if self.spread then
        self:spreadLayout()
    elseif self.view then
        self:setView()
    end
end

-- An area kept on the page (nil when nothing is left).
function Editor:clip(area)
    local r = self.pageRect
    return Ink.clip(area, r[1] + r[3], r[2] + r[4], r[2], r[1])
end

-- ------------------------------------------------------------------ the page image

function Editor:strokes()
    return self.notebook.pages[self.page].strokes
end

-- The paper (white, and the template's lines, grid or dots) over an area,
-- the whole page by default. Lines are placed from the screen's corner, so
-- any part drawn again matches the rest.
--- The template of the page shown: its own (⋯ > Page template > This page),
-- else the notebook's.
function Editor:paper()
    local page = self.notebook.pages and self.notebook.pages[self.page]
    return page and page.paper or self.notebook.paper
end

function Editor:paintPaper(bb, area)
    local ax, ay, aw, ah = 0, 0, self.w, self.h
    if area then ax, ay, aw, ah = area[1], area[2], area[3], area[4] end
    -- A page from a PDF: the PDF page instead of paper.
    local bg = self:background()
    if bg then
        bb:blitFrom(bg, ax, ay, ax, ay, aw, ah)
        return
    end
    bb:paintRect(ax, ay, aw, ah, Blitbuffer.COLOR_WHITE)
    -- One of your own templates: its picture.
    local tpl = self:templateBB()
    if tpl then
        bb:blitFrom(tpl, ax, ay, ax, ay, aw, ah)
        return self:paintHeader(bb, area)
    end
    local r = self:clip({ ax, ay, aw, ah })
    if not r then return end
    if not self.ui then self.ui = UI.new() end
    Paper.level = Settings.get("paper_lines") or "medium"
    local page = self.notebook.pages and self.notebook.pages[self.page]
    local when = page and page.created or self.notebook.created
    -- The month calendar: days with a Journal page in black.
    local marks = self:paper() == "calendar" and self.journal_marks and self.journal_marks(when) or nil
    Paper.paint(bb, self:paper(), r[1], r[2], r[1] + r[3], r[2] + r[4], self.w, self.h, self.ui:u(36) + 2, self.ui,
        self.taskKinds, when, marks)
    self:paintHeader(bb, area)
end

-- The page header (Settings > Page header): the page's date and its number,
-- small at the top right (part of the paper: ink goes over it).
function Editor:paintHeader(bb, area)
    if not Settings.get("page_header") or self.notebook.puzzle or self.margin or self.quick then return end
    local page = self.notebook.pages and self.notebook.pages[self.page]
    if not page then return end
    if not self.ui then self.ui = UI.new() end
    local u = function(n) return self.ui:u(n) end
    local band = { self.pageRect[1], self.pageRect[2], self.pageRect[3], u(24) }
    if area and not Ink.clip({ area[1], area[2], area[3], area[4] }, band[1] + band[3], band[2] + band[4], band[2], band[1]) then
        return
    end
    local text = tostring(self.page)
    if page.created then text = (os.date("%a, %b %d, %Y", page.created):gsub(" 0", " ")) .. "  ·  " .. text end
    self.ui:drawText(bb, text, self.pageRect[1] + self.pageRect[3] - u(10), band[2] + u(12), 9,
        { align = "right", color = UI.GREY_TEXT })
end

-- ------------------------------------------------------------------ your own templates

local TEMPLATE_DIR = DataStorage:getDataDir() .. "/notes/templates"
Editor.TEMPLATE_DIR = TEMPLATE_DIR

--- Your templates: { { file, name }... } by name.
function Editor.templates()
    local out = {}
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or lfs.attributes(TEMPLATE_DIR, "mode") ~= "directory" then return out end
    for f in lfs.dir(TEMPLATE_DIR) do
        if f:match("%.png$") then table.insert(out, { file = f, name = f:gsub("%.png$", "") }) end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

-- The page-sized picture of the notebook's own template (nil for the
-- others), kept while it is the one in use.
function Editor:templateBB()
    local file = type(self:paper()) == "string" and self:paper():match("^tpl:(.+)$")
    if not file then return nil end
    local key = file .. ":" .. self.w .. "x" .. self.h
    if self.tplBB and self.tplKey == key then return self.tplBB end
    if self.tplBB then self.tplBB:free() self.tplBB = nil end
    self.tplKey = key
    if self.tplFailed == key then return nil end
    local ok, pic = pcall(require("ui/renderimage").renderImageFile, require("ui/renderimage"), TEMPLATE_DIR .. "/" .. file, false)
    if not ok or not pic then
        self.tplFailed = key
        return nil
    end
    -- Fitted on white paper, the page's size (a see-through picture shows the white).
    local bb = Blitbuffer.new(self.w, self.h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    local f = math.min(self.w / pic:getWidth(), self.h / pic:getHeight())
    local sw, sh = math.floor(pic:getWidth() * f), math.floor(pic:getHeight() * f)
    local scaled = pic:scale(sw, sh)
    if scaled:getType() == Blitbuffer.TYPE_BBRGB32 then
        bb:alphablitFrom(scaled, math.floor((self.w - sw) / 2), math.floor((self.h - sh) / 2), 0, 0, sw, sh)
    else
        bb:blitFrom(scaled, math.floor((self.w - sw) / 2), math.floor((self.h - sh) / 2), 0, 0, sw, sh)
    end
    scaled:free()
    pic:free()
    self.tplBB = bb
    return bb
end

--- A new template: this page as it looks, or a picture from the Kindle.
function Editor:newTemplate()
    local dialog
    local function named(make)
        KO.ask{ title = _("Template name"), ok = _("Save"), done = function(typed)
                    local name = typed:gsub("[/\\:*?\"<>|]", "-"):match("^%s*(.-)%s*$")
                    if name == "" then return end
                    require("util").makePath(TEMPLATE_DIR)
                    local path = TEMPLATE_DIR .. "/" .. name .. ".png"
                    local function save()
                        local ok = make(path)
                        self:forgetTemplate(name .. ".png")
                        if ok then
                            self:setPaper("tpl:" .. name .. ".png")
                            KO.toast(T(_("Template %1 saved"), name))
                        else
                            KO.message(_("Could not save the template."))
                        end
                    end
                    local f = io.open(path, "rb")
                    if not f then return save() end
                    f:close()
                    KO.confirm{
                        text = T(_("Replace the template %1? Notebooks using it get the new one."), name),
                        ok = _("Replace"),
                        onOk = save,
                    }
        end }
    end
    dialog = KO.buttonDialog{
        title = _("New template"),
        title_align = "center",
        buttons = {
            { { text = _("This page (with its writing)"), callback = function()
                UIManager:close(dialog)
                self:saveNow()
                named(function(path) return Editor.pagePNG(self.notebook, self.page, path, {}) end)
            end } },
            { { text = _("A picture…"), callback = function()
                UIManager:close(dialog)
                local start = G_reader_settings:readSetting("home_dir") or Device.home_dir or "/mnt/us/documents"
                -- (A file picked in the apps' design: notespick.lua.)
                require("notespick").show{
                    title = _("Choose a picture"),
                    path = start,
                    filter = function(file)
                        local ext = file:lower():match("%.(%a+)$")
                        return ext == "png" or ext == "jpg" or ext == "jpeg"
                    end,
                    done = function(path)
                        named(function(dest)
                            -- Kept as PNG (drawn once, the page's size).
                            local ok, pic = pcall(require("ui/renderimage").renderImageFile, require("ui/renderimage"), path, false)
                            if not ok or not pic then return false end
                            local done = pcall(pic.writePNG, pic, dest)
                            pic:free()
                            return done
                        end)
                    end,
                }
            end } },
            { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
        },
    }
end

-- A template's pictures kept here forgotten (it was saved again or deleted).
function Editor:forgetTemplate(file)
    if self.tplBB then self.tplBB:free() end
    self.tplBB, self.tplKey, self.tplFailed = nil, nil, nil
    local th = self.tplThumbs and self.tplThumbs[file]
    if th then th:free() self.tplThumbs[file] = nil end
end

function Editor:templateActions(t)
    KO.confirm{
        text = T(_("Delete the template %1? Notebooks using it go back to blank paper."), t.name),
        danger = true,
        ok = _("Delete"),
        onOk = function()
            os.remove(TEMPLATE_DIR .. "/" .. t.file)
            self:forgetTemplate(t.file)
            if self:paper() == "tpl:" .. t.file then self:setPaper("plain") else self:repaint() end
        end,
    }
end

-- The PDF page behind this page (made from a PDF), drawn once per page
-- shown and kept until another is: a blitbuffer the size of the page, or
-- nil (a page of its own, or the PDF cannot be read).
function Editor:background()
    -- On a book's page (notesmargin.lua): the page as the reader shows it.
    if self.marginBG then return self.marginBG end
    -- A quick note: the screen it was opened over, faded, and the pad.
    if self.quick then
        local key = "quick:" .. table.concat(self.pageRect, ",")
        if self.bgKey ~= key then
            self:freeBackground(true)
            self.bgBB = self.quick.background(self)
            self.bgKey = key
        end
        return self.bgBB
    end
    local nb = self.notebook
    local page = nb.pages[self.page]
    if not (page and page.bg and nb.pdfPath) or self.pdfFailed then return nil end
    local key = page.bg .. ":" .. self.w .. "x" .. self.h
    if self.bgKey == key then return self.bgBB end
    self:freeBackground(true)
    if not self:pdf() then return nil end
    self.bgBB = self.pdfDoc:render(page.bg, self.w, self.h)
    self.bgKey = key
    return self.bgBB
end

-- The notebook's PDF, opened once (nil when it cannot be read).
function Editor:pdf()
    if self.pdfDoc then return self.pdfDoc end
    if self.pdfFailed or not self.notebook.pdfPath then return nil end
    local why
    self.pdfDoc, why = PDF.open(self.notebook.pdfPath)
    if not self.pdfDoc then
        self.pdfFailed = true
        logger.warn("Notes: cannot open the notebook's PDF", self.notebook.pdfPath, why)
    end
    return self.pdfDoc
end

function Editor:freeBackground(keepDoc)
    if not keepDoc then self:freeSpread() end
    if self.bgBB then self.bgBB:free() end
    self.bgBB, self.bgKey = nil, nil
    if not keepDoc then
        if self.tplBB then self.tplBB:free() end
        self.tplBB, self.tplKey = nil, nil
        for __, t in pairs(self.tplThumbs or {}) do t:free() end
        self.tplThumbs = nil
    end
    if not keepDoc then self:freeView() end
    if not keepDoc and self.pdfDoc then
        self.pdfDoc:close()
        self.pdfDoc = nil
    end
end

local function colorOf(stroke)
    return Blitbuffer.Color8(Ink.greyOf(stroke))
end

-- Stamps of a stroke into one or two images, kept on the page.
-- A stamp (a square at x, y, s wide) into one or two images, kept on the page.
function Editor:stamper(images, color)
    local r = self.pageRect
    local left, top, right, bottom = r[1], r[2], r[1] + r[3], r[2] + r[4]
    color = color or Blitbuffer.COLOR_BLACK
    return function(x, y, s)
        local sx, sy, ex, ey = math.max(x, left), math.max(y, top), math.min(x + s, right), math.min(y + s, bottom)
        if ex > sx and ey > sy then
            for __, bb in ipairs(images) do bb:paintRect(sx, sy, ex - sx, ey - sy, color) end
        end
    end
end

function Editor:stampInto(images, stroke_w, x0, y0, x1, y1, color)
    Ink.segment(x0, y0, x1, y1, stroke_w, self:stamper(images, color))
end

-- A filled shape's inside, in its fill grey, kept on the page.
function Editor:fillStroke(images, stroke)
    local r = self.pageRect
    local left, top, right, bottom = r[1], r[2], r[1] + r[3], r[2] + r[4]
    local color = Blitbuffer.Color8(stroke.f)
    Ink.fillPolygon(stroke.p, function(y, a, b)
        if y < top or y >= bottom then return end
        a, b = math.max(a, left), math.min(b, right - 1)
        if b >= a then
            for __, bb in ipairs(images) do bb:paintRect(a, y, b - a + 1, 1, color) end
        end
    end)
end

function Editor:drawStroke(images, stroke, color)
    local p = stroke.p
    color = color or colorOf(stroke)
    if #p == 2 then
        self:stampInto(images, Ink.segmentWidth(stroke, 1), p[1], p[2], p[1], p[2], color)
        return
    end
    local on, off = Ink.dashes(stroke.d, stroke.w)
    local stamp = self:stamper(images, color)
    local done = 0
    for i = 1, #p - 3, 2 do
        local w = Ink.segmentWidth(stroke, (i + 1) / 2)
        if on then
            done = Ink.dashedSegment(p[i], p[i + 1], p[i + 2], p[i + 3], w, on, off, done, stamp)
        else
            Ink.segment(p[i], p[i + 1], p[i + 2], p[i + 3], w, stamp)
        end
    end
end

-- Strokes into an image: highlighter first (it goes under the ink), then
-- the rest; only those crossing `area` when given; none in `skip`.
function Editor:drawStrokes(bb, strokes, area, skip)
    for pass = 1, 2 do
        for __, stroke in ipairs(strokes) do
            if not (skip and skip[stroke]) then
                local draw = true
                if area then
                    local bx, by, bw, bh = Ink.box(stroke)
                    draw = bx and bx < area[1] + area[3] and bx + bw > area[1] and by < area[2] + area[4] and by + bh > area[2]
                end
                if draw then
                    -- Fills and the highlighter first (under the ink), then the ink.
                    if pass == 1 and stroke.f then self:fillStroke({ bb }, stroke) end
                    if (Ink.tipOf(stroke).under == true) == (pass == 1) then self:drawStroke({ bb }, stroke) end
                end
            end
        end
    end
end

-- The page image: paper and ink (not the selected ink, drawn over it).
function Editor:renderPage()
    if not self.page_bb then return end   -- closed (a dialog opened from it answered late)
    if self.spread then return self:renderSpread() end
    if self.view then return self:renderView() end
    -- Lines that became subtasks (or tasks again) since: their ticks move
    -- with their boxes (a lasso move, undo, redo).
    if self.taskKindsPage ~= self.page then self.taskKinds = nil end
    self.taskKindsPage = self.page
    if self.taskKinds then self:updateTaskLines(true) else self.taskKinds = self:lineKinds() end
    self:paintPaper(self.page_bb)
    self:drawTicks(self.page_bb)
    local skip = self.sel and self.sel.itemSet
    Items.draw(self.page_bb, self:pageItems(), "under", nil, skip, self:imageDir())
    self:drawStrokes(self.page_bb, self:strokes(), nil, self.sel and self.sel.set)
    Items.draw(self.page_bb, self:pageItems(), "text", nil, skip, self:imageDir())
    Items.draw(self.page_bb, self:pageItems(), "over", nil, skip, self:imageDir())
end

-- One area of the page drawn again: its paper, then the strokes that cross
-- it (drawn whole: outside the area they only cover ink already there).
function Editor:renderArea(area)
    if not self.page_bb then return nil end
    if self.view then
        -- Zoomed: the area (on the page) where the view shows it.
        area = self:clip(self:viewArea(area))
        if area then self:renderView(area) end
        return area
    end
    area = self:clip(area)
    if not area then return nil end
    self:paintPaper(self.page_bb, area)
    self:drawTicks(self.page_bb, area)
    local skip = self.sel and self.sel.itemSet
    Items.draw(self.page_bb, self:pageItems(), "under", area, skip, self:imageDir())
    self:drawStrokes(self.page_bb, self:strokes(), area, self.sel and self.sel.set)
    Items.draw(self.page_bb, self:pageItems(), "text", area, skip, self:imageDir())
    Items.draw(self.page_bb, self:pageItems(), "over", area, skip, self:imageDir())
    return area
end

-- ------------------------------------------------------------------ crosswords' clue boxes

-- The tick boxes of the clues on this page, on the screen: { { x, y, size,
-- id }... } (none when the crossword has none), kept for the page.
function Editor:clueBoxes()
    if not (self.notebook.feed and self.on_clue_boxes) then return {} end
    local key = self.page .. ":" .. self.w .. "x" .. self.h
    if not self.boxCache or self.boxCache.key ~= key then
        local ok, list = pcall(self.on_clue_boxes, self)
        self.boxCache = { key = key, list = ok and list or {} }
    end
    return self.boxCache.list
end

-- The ticked clues of this page's crossword ({ ["8A"] = true }), kept on
-- its first page.
function Editor:clueTicks()
    local first = self:puzzleFirst()
    return first and first.ticks or {}
end

-- Ticks in their clues' boxes, in `area` (all of the page when nil).
function Editor:drawTicks(bb, area)
    local ticks = self:clueTicks()
    if not next(ticks) then return end
    for __, b in ipairs(self:clueBoxes()) do
        if ticks[b[4]] and (not area or Ink.clip({ b[1], b[2], b[3], b[3] }, area[1] + area[3], area[2] + area[4], area[2], area[1])) then
            local pad = math.floor(b[3] * 0.1)
            self.ui:drawIcon(bb, "check", math.floor(b[1]) - pad, math.floor(b[2]) - pad, math.floor(b[3]) + 2 * pad)
        end
    end
end

-- A clue's box ticked (`on`), or unticked (false), or turned over (nil).
function Editor:tickClue(b, on)
    local first = self:puzzleFirst()
    if not first then return end
    first.ticks = first.ticks or {}
    if on == nil then on = not first.ticks[b[4]] end
    if (first.ticks[b[4]] or false) == on then return end
    first.ticks[b[4]] = on or nil
    if not next(first.ticks) then first.ticks = nil end
    local pad = math.ceil(b[3] * 0.2)
    local area = { math.floor(b[1]) - pad, math.floor(b[2]) - pad, math.ceil(b[3]) + 2 * pad, math.ceil(b[3]) + 2 * pad }
    self:renderArea(area)
    self:showArea(area)
    self:changed()
    -- The count at the top ("23 of 68 clues") drawn again.
    if self.countRect then self:repaint(self.countRect) end
end

-- A pen stroke on a crossword's clue boxes: a tap or a small mark in one
-- ticks it (or unticks it) and goes; a line drawn through boxes ticks
-- them and stays. True when the stroke went.
function Editor:strokeOnBoxes(stroke)
    local boxes = self:clueBoxes()
    if #boxes == 0 or (stroke.t and stroke.t == "hl") then return false end
    local bx, by, bw, bh = Ink.box(stroke)
    if not bx then return false end
    for __, b in ipairs(boxes) do
        local m = b[3] * 0.6
        if bw <= b[3] * 1.6 and bh <= b[3] * 1.6 and bx >= b[1] - m and by >= b[2] - m
                and bx + bw <= b[1] + b[3] + m and by + bh <= b[2] + b[3] + m then
            self:tickClue(b)
            self:renderArea({ bx, by, bw, bh })
            self:cleanLater({ bx, by, bw, bh })
            return true
        end
    end
    local p = stroke.p
    for __, b in ipairs(boxes) do
        for i = 1, #p - 1, 2 do
            if p[i] >= b[1] and p[i] <= b[1] + b[3] and p[i + 1] >= b[2] and p[i + 1] <= b[2] + b[3] then
                self:tickClue(b, true)
                break
            end
        end
    end
    return false
end

-- A finger tap on a crossword, as the pen's: a clue's box ticked (or
-- unticked), the clues turned, or a number's clues outlined; anywhere
-- else, the outline goes. True when it did something.
function Editor:fingerOnCrossword(x, y)
    if self.hintMode then
        self:hintTap(x, y)
        return true
    end
    for __, b in ipairs(self:clueBoxes()) do
        local m = b[3] * 0.3
        if x >= b[1] - m and x <= b[1] + b[3] + m and y >= b[2] - m and y <= b[2] + b[3] + m then
            self:tickClue(b)
            return true
        end
    end
    if self.on_clue_tap and self.on_clue_tap(self, x, y) then return true end
    if self.outline then
        self:clearOutline()
        return true
    end
    return false
end

-- "23 of 68 clues" at the top of a crossword's page with clue boxes.
function Editor:paintClueCount(bb)
    if #self:clueBoxes() == 0 then return end
    local first = self:puzzleFirst()
    if not (first and first.nclues) then return end
    local n = 0
    for __ in pairs(first.ticks or {}) do n = n + 1 end
    -- Under the day and source at the page's top right.
    local land = self.w > self.h
    local pw, ph = land and Crossword.H or Crossword.W, land and Crossword.W or Crossword.H
    local ox, oy, z = Crossword.fit(self.w, self.h, pw, ph)
    local right, mid = math.floor(ox + (pw - 14) * z), math.floor(oy + 37.5 * z)
    self.ui:drawText(bb, T(_("%1 of %2 clues"), n, first.nclues), right, mid, 9,
        { align = "right", bold = true, color = UI.GREY_TEXT })
    local u = self.ui:u(14)
    self.countRect = { right - 12 * u, mid - u, 12 * u, 2 * u }
end

-- After the page image changed: the area onto the screen, cleanly.
function Editor:showArea(area, mode)
    if not self.page_bb then return end
    area = self:clip(area)
    if not area then return end
    Screen.bb:blitFrom(self.page_bb, area[1], area[2], area[1], area[2], area[3], area[4])
    UIManager:setDirty(nil, function() return mode or "ui", Geom:new{ x = area[1], y = area[2], w = area[3], h = area[4] } end)
end

-- The editor painted again over `rect` ({x, y, w, h}; all of it by default).
function Editor:repaint(rect, mode)
    if not self.page_bb then return end
    UIManager:setDirty(self, function()
        if not rect then return mode or "ui", self.dimen end
        local r = Ink.clip(rect, self.w, self.h)
        if not r then return nil end
        return mode or "ui", Geom:new{ x = r[1], y = r[2], w = r[3], h = r[4] }
    end)
end

function Editor:paintTo(bb, x, y)
    bb:blitFrom(self.page_bb, x, y, 0, 0, self.w, self.h)
    self.hits = {}
    self.aiHolds = {}
    self.layer = "sel"
    if self.sel then self:paintSelection(bb) end
    self.layer = "paste"
    if self.pasteAt then self:paintPaste(bb) end
    if self.drawAt then self:paintDrawAt(bb) end
    self.layer = "bar"
    if self.zoomOn then self:paintZoom(bb) end
    if self.askPad then self:paintAskPad(bb) end
    self.layer = "bar"
    if (self.view and not self.spread) or self.picking then self:paintViewBar(bb) end
    if self.check and not self.view then self:paintCheck(bb) end
    if self.hintMode and not self.view then self:paintHintBanner(bb) end
    if self.notebook.feed and not self.view then self:paintClueCount(bb) end
    if self.outline and not self.view then self:paintOutline(bb) end
    if self.clueCard and not self.view then self:paintClueCard(bb) end
    self:paintToolbar(bb)
    self.layer = "panel"
    if self.panel then self:paintPanel(bb) end
    self.layer = nil
end

-- ------------------------------------------------------------------ taps on the toolbar and panels

-- A tap area, on a layer: "bar" (the toolbar), "panel", "sel" (the
-- selection's buttons) or "paste".
function Editor:hit(x, y, w, h, fn, layer)
    table.insert(self.hits, { x, y, w, h, fn, layer or self.layer or "bar" })
end

--- An AI button's place, for a hold to open "AI for this" (`key`: the AI job
-- or feature it uses).
function Editor:aiHold(x, y, w, h, key)
    self.aiHolds = self.aiHolds or {}
    table.insert(self.aiHolds, { x, y, w, h, key })
end

-- The tap area under (x, y): the last painted wins (panels over the
-- toolbar). Areas of a panel, selection or paste button closed since they
-- were painted do not count.
function Editor:hitAt(x, y)
    local live = { bar = true, panel = self.panel ~= nil, sel = self.sel ~= nil and not self.sel.dragging,
        paste = self.pasteAt ~= nil or self.drawAt ~= nil }
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if live[h[6]] and x >= h[1] and x < h[1] + h[3] and y >= h[2] and y < h[2] + h[4] then return h end
    end
end

function Editor:tapAt(x, y, finger)
    -- Pinned clues (just dragged, maybe not drawn there yet): nothing under
    -- them; their tick boxes tick.
    if not self.view and self:onClueCard(x, y) then
        self:clueCardTap(x, y)
        return
    end
    local h = self:hitAt(x, y)
    if not h and finger then
        -- On the writing strips: nothing under them.
        if self.askPad then
            local r = self:askPadRect()
            if y >= r[2] then return end
        end
        if self:inStrip(x, y) then return end
        -- A crossword's clue boxes, numbers and arrows: a finger works them
        -- with the pen held near too.
        if self:penHeld() and self.notebook.feed and not self.view and self:fingerOnCrossword(x, y) then return end
        -- A finger right after the pen, or with it near: a palm, most likely;
        -- it still closes a panel or menu that is open (that does no harm).
        if self:palmLikely() and not (self.panel or self.pasteAt or self.drawAt) then return end
    end
    if h then
        if h[5] then h[5]() end
    elseif self.placing and finger then
        self:place(x, y)
    elseif self.panel then
        self:closePanel()
    elseif self.pasteAt or self.drawAt then
        self.pasteAt, self.drawAt = nil, nil
        self:repaint()
    else
        if finger and self.notebook.feed and not self.view and self:fingerOnCrossword(x, y) then return end
        -- A link: to its page.
        for i = #self:pageItems(), 1, -1 do
            local it = self:pageItems()[i]
            if it.link then
                local bx, by, bw, bh = Items.box(it)
                if x >= bx and x < bx + bw and y >= by and y < by + bh then return self:followLink(it.link) end
            end
        end
        if self.spread then
            local k = self:spreadSlotAt(x, y)
            if not k then return end
            self:useSlot(k)
            x, y = self:toPage(x, y)
        end
        -- The month calendar: a day's number tapped opens its Journal page.
        if finger and self:paper() == "calendar" and self.on_journal_day and not self.margin then
            local page = self.notebook.pages[self.page]
            local pw, ph = self:pageSize()
            local day = Paper.calendarDayAt(x, y, pw, ph, self.ui:u(36) + 2, page.created or self.notebook.created)
            if day then
                self:commitSelection()
                self:saveNow()
                return self.on_journal_day(day)
            end
        end
        local tape = Items.at(self:pageItems(), x, y, "tape")
        if tape then
            self:toggleTape(tape)
        else
            self:toggleCheckbox(x, y)
        end
    end
end

-- Whether a stroke is a mark in a checklist box (it lies mostly within
-- one): the box is then ticked (if it was not). Returns true when so.
function Editor:markInBox(stroke)
    local paper = self:paper()
    if paper ~= "checklist" and paper ~= "tasks" or Ink.tipOf(stroke).under then return false end
    local bx, by, bw, bh = Ink.box(stroke)
    local box = Paper.boxAt(paper, bx + bw / 2, by + bh / 2, self.ui:u(36) + 2, self.h, self:lineKinds())
    if not box then return false end
    local s = box[3]
    if bw > s * 1.8 or bh > s * 1.8 then return false end
    local inside, n = 0, 0
    for i = 1, #stroke.p - 1, 2 do
        n = n + 1
        local x, y = stroke.p[i], stroke.p[i + 1]
        if x >= box[1] - s * 0.4 and x <= box[1] + s * 1.4 and y >= box[2] - s * 0.4 and y <= box[2] + s * 1.4 then inside = inside + 1 end
    end
    if inside < n * 0.7 then return false end
    for __, st in ipairs(self:strokes()) do
        if st.ck then
            local tx, ty, tw, th = Ink.box(st)
            local cx, cy = tx + tw / 2, ty + th / 2
            if cx >= box[1] and cx <= box[1] + s and cy >= box[2] and cy <= box[2] + s then return true end
        end
    end
    self:toggleCheckbox(box[1] + s / 2, box[2] + s / 2)
    return true
end

-- On the tasks paper, which lines are subtasks: { [line] = "sub" } for each
-- line whose writing starts indented (nil on other papers).
function Editor:lineKinds()
    if self:paper() ~= "tasks" then return nil end
    if not self.ui then self.ui = UI.new() end
    local left = self.ui:u(36) + 2
    local indent = Paper.indentX(left)
    local task, __, size = Paper.boxes("tasks", left)
    local minX = {}
    for __, s in ipairs(self:strokes()) do
        if not s.ck and not Ink.tipOf(s).under then
            local bx, by, bw, bh = Ink.box(s)
            -- Marks in the box column are left out (they become ticks).
            if bx and bx + bw > task + size then
                local j = Paper.lineOf("tasks", by + bh / 2)
                if j >= 0 then minX[j] = math.min(minX[j] or math.huge, bx) end
            end
        end
    end
    local kinds = {}
    for j, x in pairs(minX) do
        if x >= indent then kinds[j] = "sub" end
    end
    return kinds
end

-- After writing or erasing on the tasks paper: lines that turned into a
-- subtask (or back) get their box moved, with its tick.
function Editor:updateTaskLines(quiet)
    if self:paper() ~= "tasks" then return end
    local old = self.taskKinds or {}
    local kinds = self:lineKinds()
    self.taskKinds = kinds
    local left = self.ui:u(36) + 2
    local gap = Paper.gap("tasks")
    local changed = {}
    for j in pairs(old) do if old[j] ~= kinds[j] then changed[j] = true end end
    for j in pairs(kinds) do if old[j] ~= kinds[j] then changed[j] = true end end
    for j in pairs(changed) do
        local was = Paper.lineBox("tasks", j, left, old)
        local now = Paper.lineBox("tasks", j, left, kinds)
        local strokes = self:strokes()
        for i, st in ipairs(strokes) do
            if st.ck then
                local tx, ty, tw, th = Ink.box(st)
                local cx, cy = tx + tw / 2, ty + th / 2
                if cx >= was[1] and cx <= was[1] + was[3] and cy >= was[2] and cy <= was[2] + was[3] then
                    strokes[i] = Ink.transform(st, was[1], was[2], now[3] / was[3], now[1] - was[1], now[2] - was[2])
                    strokes[i].ck = true
                end
            end
        end
        if not quiet then
            local area = { 0, 2 * gap + (j - 1) * gap, self.w, gap + 4 }
            self:renderArea(area)
            self:cleanLater(area)
        end
    end
end

--- A tick in the checklist box at (x, y), or the tick there taken away.
-- Returns true when there is a box there.
function Editor:toggleCheckbox(x, y)
    local paper = self:paper()
    if paper ~= "checklist" and paper ~= "tasks" then return false end
    local box = Paper.boxAt(paper, x, y, self.ui:u(36) + 2, self.h, self:lineKinds())
    if not box then return false end
    local bx, by, s = box[1], box[2], box[3]
    local before = self:snapshot()
    local strokes = self:strokes()
    local removed = false
    for i = #strokes, 1, -1 do
        local st = strokes[i]
        if st.ck then
            local tx, ty, tw, th = Ink.box(st)
            local cx, cy = tx + tw / 2, ty + th / 2
            if cx >= bx and cx <= bx + s and cy >= by and cy <= by + s then
                table.remove(strokes, i)
                removed = true
            end
        end
    end
    if not removed then
        local w = math.max(3, math.floor(s / 8))
        table.insert(strokes, { ck = true, w = w, q = { w, w, w },
            p = { math.floor(bx + s * 0.18), math.floor(by + s * 0.52), math.floor(bx + s * 0.42), math.floor(by + s * 0.8),
                math.floor(bx + s * 0.88), math.floor(by + s * 0.12) } })
    end
    self:pushSnapshot(before)
    local area = { bx - 4, by - 4, s + 8, s + 8 }
    self:renderArea(area)
    self:showArea(area, "ui")
    return true
end

-- The ticks of the written lines (checklist and tasks pages): { [line] = true }.
function Editor:tickState()
    local out = {}
    for __, l in ipairs(self:writtenLines() or {}) do
        if self:boxTicked(l.line) then out[l.line] = true end
    end
    return out
end

-- After any change: a tick that came or went is told to To Do (once per change).
function Editor:checkTicks()
    if not self.on_tick then return end
    local paper = self:paper()
    if paper ~= "checklist" and paper ~= "tasks" then return end
    local now = self:tickState()
    local before = self.ticks
    self.ticks = now
    if not before or self.fromTodo then return end
    local pageId = self.notebook.pages[self.page].id
    for line in pairs(now) do
        if not before[line] then self.on_tick(self.notebook, pageId, line, true) end
    end
    for line in pairs(before) do
        if not now[line] then self.on_tick(self.notebook, pageId, line, false) end
    end
end

-- Which line (0 the first) a box (from Paper.boxAt) is on.
function Editor:boxLine(box)
    local paper, kinds = self:paper(), self:lineKinds()
    local left = self.ui:u(36) + 2
    for k = 0, 200 do
        local b = Paper.lineBox(paper, k, left, kinds)
        if b[2] > self.h then return nil end
        if b[1] == box[1] and b[2] == box[2] then return k end
    end
end

--- The lines with writing on a checklist or tasks page, top to bottom:
-- { { line, kind = "task" | "sub" }... } (nil on other papers).
function Editor:writtenLines()
    local paper = self:paper()
    if paper ~= "checklist" and paper ~= "tasks" then return nil end
    local left = self.ui:u(36) + 2
    local task, __, size = Paper.boxes(paper, left)
    local kinds = self:lineKinds() or {}
    local seen, out = {}, {}
    for __, st in ipairs(self:strokes()) do
        if not st.ck and not Ink.tipOf(st).under then
            local bx, by, bw, bh = Ink.box(st)
            if bx and bx + bw > task + size then
                local j = Paper.lineOf(paper, by + bh / 2)
                if j >= 0 and not seen[j] then
                    seen[j] = true
                    table.insert(out, { line = j, kind = kinds[j] == "sub" and "sub" or "task" })
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.line < b.line end)
    return out
end

--- Whether line k's box is ticked.
function Editor:boxTicked(k)
    local b = Paper.lineBox(self:paper(), k, self.ui:u(36) + 2, self:lineKinds())
    for __, st in ipairs(self:strokes()) do
        if st.ck then
            local tx, ty, tw, th = Ink.box(st)
            local cx, cy = tx + tw / 2, ty + th / 2
            if cx >= b[1] and cx <= b[1] + b[3] and cy >= b[2] and cy <= b[2] + b[3] then return true end
        end
    end
    return false
end

--- Line k's box ticked (or not) as To Do has it: not an undo step, and not
-- told back to To Do.
function Editor:setBoxTicked(k, on)
    if not self.page_bb or self:boxTicked(k) == on then return end
    local b = Paper.lineBox(self:paper(), k, self.ui:u(36) + 2, self:lineKinds())
    local bx, by, s = b[1], b[2], b[3]
    local strokes = self:strokes()
    if on then
        local w = math.max(3, math.floor(s / 8))
        table.insert(strokes, { ck = true, w = w, q = { w, w, w },
            p = { math.floor(bx + s * 0.18), math.floor(by + s * 0.52), math.floor(bx + s * 0.42), math.floor(by + s * 0.8),
                math.floor(bx + s * 0.88), math.floor(by + s * 0.12) } })
    else
        for i = #strokes, 1, -1 do
            local st = strokes[i]
            if st.ck then
                local tx, ty, tw, th = Ink.box(st)
                local cx, cy = tx + tw / 2, ty + th / 2
                if cx >= bx and cx <= bx + s and cy >= by and cy <= by + s then table.remove(strokes, i) end
            end
        end
    end
    self.fromTodo = true
    self:changed()
    self.fromTodo = false
    local area = { bx - 4, by - 4, s + 8, s + 8 }
    self:renderArea(area)
    self:showArea(area, "ui")
end

-- ------------------------------------------------------------------ the toolbar

function Editor:toolbarX()
    return self.side == "left" and 0 or self.w - self.bar_w
end

local function toolIcon(self, key)
    if key == "pen" then return TIP_ICONS[self.tip] end
    if Settings.ACTION[key] then return Settings.ACTION[key].icon end
    return Settings.TOOL_ICONS[key]
end

function Editor:paintToolbar(bb)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    self.buttonY = {}
    if self.folded then
        -- A tab on the edge, open on the edge's side.
        local tw, th, r = u(18), u(48), u(6)
        local ty = math.floor(self.h / 2 - th / 2)
        local tx = self.side == "left" and 0 or self.w - tw
        local bw = math.max(2, u(1.2))
        ui:box(bb, tx, ty, tw, th, { fill = UI.WHITE, border = UI.BLACK, r = r, bw = bw })
        bb:paintRect(self.side == "left" and tx or tx + tw - bw, ty + r, bw, th - 2 * r, UI.WHITE)
        local icon = self.side == "left" and "panel-left-open" or "panel-right-open"
        ui:drawIcon(bb, icon, tx + math.floor((tw - u(14)) / 2), ty + u(17), u(14))
        self:hit(self.side == "left" and 0 or self.w - u(30), ty - u(6), u(30), th + u(12), function() self:setFolded(false) end)
        return
    end
    local x0, bw = self:toolbarX(), self.bar_w
    bb:paintRect(x0, 0, bw, self.h, UI.WHITE)
    local edge = self.side == "left" and x0 + bw or x0 - 2
    bb:paintRect(edge, 0, 2, self.h, UI.BLACK)
    local favs = Settings.get("favorites") or {}
    -- Buttons closer together when they would not fit (landscape).
    -- (Home and the notebooks at the top; Refresh, the bell and Settings at the bottom.)
    local fixed = self:fixedButtons()
    local count = 2 + #self.order + #favs + 6.6 + #fixed + 1   -- (+1: the time and battery)
    local gaps = u(8) + (#favs > 0 and u(8) or 0) + u(8)
    local pitch = math.min(u(34), math.floor((self.h - gaps) / count))
    local box = math.min(u(28), pitch - u(3))
    local icon = math.min(u(18), box - u(8))
    local function button(y, name, fn, active, dim, key)
        if active then ui:box(bb, x0 + math.floor((bw - box) / 2), y, box, box, { fill = UI.BLACK, r = u(5) }) end
        ui:drawIcon(bb, name, x0 + math.floor((bw - icon) / 2), y + math.floor((box - icon) / 2), icon, active, dim)
        if key then self.buttonY[key] = y + math.floor(box / 2) end
        self:hit(x0, y - math.floor((pitch - box) / 2), bw, pitch, not dim and fn or function() end)
        -- (Held: "AI for this", for the AI's buttons.)
        local job = key == "check" and self.notebook.feed and "cw_check" or key == "ask" and "ask" or nil
        if job then self:aiHold(x0, y - math.floor((pitch - box) / 2), bw, pitch, job) end
    end
    local function sep(y)
        ui:line(bb, x0 + u(9), y, bw - u(18), 1, UI.MID)
    end
    local puzzleActs = self.notebook.puzzle and not self.spread and self:puzzleActions(true) or nil
    local y = u(4)
    -- ⌂ Home first (as in the other apps), then back to the notebooks.
    if self.on_home and not self.quick then
        button(y, "house", function() self:goHome() end)
        y = y + pitch
    end
    button(y, self.quick and "check" or "book-open", function()
        self.homeAfter = false
        self:closeAsked()
    end)
    y = y + pitch
    -- A quick note's Discard right under its ✓ Save.
    if self.quick and self.quick.discard then
        button(y, "trash-2", function() self.quick.discard(self) end, false, false, "discard")
        y = y + pitch
    end
    sep(y - u(2))
    y = y + u(4)
    for __, key in ipairs(self.order) do
        if key == "undo" then
            button(y, "undo-2", function() self:doUndo() end, self.panel == "history", #self.undo == 0, "history")
            self.undoButton = { x0, y - math.floor((pitch - box) / 2), bw, pitch }
        elseif key == "redo" then
            button(y, "redo-2", function() self:doRedo() end, false, #self.redo == 0)
        elseif key == "swap" and self.quick then
            button(y, "arrow-up-down", function() self:swapQuick() end, false, false, key)
        elseif (key == "peek" or key == "discard") and self.quick then
            -- A quick note's own: the whole screen behind it for a moment; or the note thrown away.
            local fn = self.quick[key]
            button(y, key == "peek" and "eye" or "trash-2", function() if fn then fn(self) end end, false, fn == nil, key)
        elseif key == "done" then
            button(y, "circle-check", function() self:toggleDone() end, self.notebook.pages[self.page].done == true, false, key)
        elseif key:match("^g:") then
            -- A group: its list opens; it shows the tool of it in use.
            local name = key:sub(3)
            local def = Settings.GROUPS[name] or {}
            local icon, on = def.icon or "ellipsis", self.panel == key
            for __, member in ipairs(Settings.groups()[name] or {}) do
                if Settings.TOOLS[member] and self.tool == member then icon, on = toolIcon(self, member), true end
            end
            button(y, icon, function() self:togglePanel(key) end, on, false, key)
        elseif self.notebook.puzzle and puzzleActs and puzzleActs[key] then
            local a = puzzleActs[key]
            button(y, a.icon, a.fn, a.on or false, a.dim, key)
        elseif Settings.ACTION[key] then
            local on = (key == "bookmark" and self.notebook.pages[self.page].star) or (key == "night" and KO.nightMode())
            button(y, Settings.ACTION[key].icon, function() self:runAction(key) end, on or false,
                key == "light" and not KO.hasLight())
        else
            local on = self.tool == key
            if key == "zoom" then on = self.zoomOn == true or self.view ~= nil or self.picking ~= nil end
            button(y, toolIcon(self, key), function() self:pickTool(key) end, on, false, key)
        end
        y = y + pitch
    end
    -- Favorite pens: one tap to write with them.
    if #favs > 0 then
        sep(y - u(2))
        y = y + u(4)
        for i, fav in ipairs(favs) do
            local on = self.tool == "pen" and self.tip == fav.tip and (self.sizes[fav.tip] or 2) == fav.size
                and (self.shade or "default") == (fav.shade or "default")
            button(y, TIP_ICONS[fav.tip] or "pen", function() self:useFavorite(i) end, on, false, "fav" .. i)
            -- Its size as a dot, its shade as the dot's grey.
            local r = math.max(2, math.min(u(3), math.floor(Ink.tipWidth(fav.tip, fav.size, nil, self.scale) / 3)))
            local dx = x0 + bw - u(9)
            local grey = Ink.tipShade(fav.tip, fav.shade) or (Ink.TIPS[fav.tip] or Ink.TIPS.pen).grey
            bb:paintCircle(dx, y + box - u(5), r + 1, on and UI.WHITE or UI.BLACK)
            bb:paintCircle(dx, y + box - u(5), r, Blitbuffer.Color8(grey))
            y = y + pitch
        end
    end
    -- Pages, the menu and folding at the bottom.
    local pages = #self.notebook.pages
    local puzzle = self.notebook.puzzle
    local toolsEnd = y
    -- All pages and + page can be taken off (Settings > Toolbar); in the ⋯ menu then.
    local pb = Settings.get("page_buttons") or {}
    local showPages = puzzle or self.spread or pb.pages ~= false
    local showAdd = not puzzle and pb.addpage ~= false
    local bottom = 3 + (showPages and 1 or 0) + (showAdd and 1 or 0)
    local tail = (self.quick or self.margin) and 0 or #fixed
    y = self.h - u(4) - box - ((self.quick and 0 or self.margin and 2 or puzzle and 4 or bottom) + tail) * pitch - math.floor(pitch * 0.6)
        - (tail > 0 and u(6) or 0)
    -- The fixed group at the very bottom: ⟳ Refresh, the bell, ⚙ Settings.
    local function fixedGroup(fy)
        if tail == 0 then return end
        sep(fy - u(2))
        fy = fy + u(4)
        for __, f in ipairs(fixed) do
            button(fy - u(6), f[1], f[2])
            fy = fy + pitch
        end
    end
    -- The time and battery in the room between (always: as in every app).
    self.statusRect = nil
    do
        local room = y - toolsEnd - u(6)
        if ui:drawStatusStacked(bb, x0, toolsEnd, bw, room, 8) > 0 then self.statusRect = { x0, toolsEnd, bw, room } end
    end
    local prev, nxt = self:nextPage(-1), self:nextPage(1)
    if self.quick then
        -- A quick note: one page, no page buttons.
        button(y + math.floor(pitch * 0.6), self.side == "left" and "panel-left-close" or "panel-right-close",
            function() self:setFolded(true) end, false, false, "fold")
        return
    end
    if self.margin then
        -- On a book's page: the arrows turn the book's pages.
        button(y, "chevron-up", function() self.margin.turn(-1) end)
        y = y + pitch
        ui:drawText(bb, tostring(self.margin.page), x0 + math.floor(bw / 2), y + math.floor(pitch * 0.3) - u(4), 9.5,
            { align = "center", bold = true })
        y = y + math.floor(pitch * 0.6)
        button(y - u(6), "chevron-down", function() self.margin.turn(1) end)
        y = y + pitch
        button(y - u(6), self.side == "left" and "panel-left-close" or "panel-right-close", function() self:setFolded(true) end,
            false, false, "fold")
        return
    end
    button(y, "chevron-up", function() if prev then self:goPage(prev) end end, false, not prev)
    y = y + pitch
    local star = self.notebook.pages[self.page].star and "★ " or ""
    local shown = self:pageCounter()
    if self.spread then
        local f = self.spread.first
        shown = f < pages and T("%1–%2", f, f + 1) or tostring(f)
    end
    ui:drawText(bb, star .. shown, x0 + math.floor(bw / 2), y + math.floor(pitch * 0.3) - u(4), 9.5,
        { align = "center", bold = true })
    self:hit(x0, y - u(4), bw, math.floor(pitch * 0.6), function() self:showOverview() end)
    y = y + math.floor(pitch * 0.6)
    button(y - u(6), "chevron-down", function() if nxt then self:goPage(nxt) end end, false, not nxt)
    y = y + pitch
    if showPages then
        button(y - u(6), "layout-grid", function() self:showOverview() end)
        y = y + pitch
    end
    if showAdd then
        button(y - u(6), "file-plus", function() self:addPage() end)
        y = y + pitch
    end
    button(y - u(6), "ellipsis", function() self:togglePanel("more") end, self.panel == "more", false, "more")
    y = y + pitch
    button(y - u(6), self.side == "left" and "panel-left-close" or "panel-right-close", function() self:setFolded(true) end, false, false, "fold")
    y = y + pitch
    fixedGroup(y)
end

-- The toolbar's fixed group at the bottom: { icon, fn }: Refresh, the bell
-- (when Apps' notifications are there), Settings.
function Editor:fixedButtons()
    local out = { { "refresh-cw", function() self:runAction("refresh") end } }
    if self.on_bell then table.insert(out, { "bell", function() self.on_bell(self) end }) end
    table.insert(out, { "settings", function() self:runAction("settings") end })
    return out
end

--- ⌂ Home: closed (saved, or asked when When closing is Ask), then the Apps
-- launcher.
function Editor:goHome()
    self.homeAfter = true
    self:closeAsked()
end

-- The tools of a puzzle book's toolbar, then the buttons pinned to it.
function Editor:puzzleOrder()
    local order = { unpack(PUZZLE_TOOLS) }
    local acts = self:puzzleActions(true)
    for __, key in ipairs(Settings.get("puzzle_buttons") or PUZZLE_DEFAULT) do
        if acts[key] and key ~= "refresh" and key ~= "settings" then table.insert(order, key) end
    end
    return order
end

--- A puzzle book's ⋯ menu: { key, icon, label, value, fn, on } in order,
-- "-" between groups and false for what this book hasn't; `byKey`: the
-- same as { [key] = action }.
function Editor:puzzleActions(byKey)
    local nb = self.notebook
    local page = nb.pages[self.page]
    local function close() self.panel = nil self:repaint() end
    local function act(key, value, fn, on)
        for __, b in ipairs((key == "refresh" or key == "settings") and PUZZLE_MENU_ONLY or PUZZLE_BUTTONS) do
            if b.key == key then
                local label = b.label
                if key == "getcw" or key == "ask" or key == "export" then label = label .. "…" end
                return { key = key, icon = b.icon, label = label, value = value, fn = fn, on = on }
            end
        end
    end
    local list = {
        -- Hints: reveal a letter or a word, check a word, a hint from the AI.
        nb.feed and self.on_hint and act("hint", nil, function() self:togglePanel("hint") end,
            self.panel == "hint" or self.hintMode ~= nil) or false,
        -- The AI reads the letters written in the grid; wrong ones get a dot
        -- (with an AI service set up).
        nb.feed and self.on_check and not Settings.noAI() and act("check", nil, function() close() self.on_check(self) end) or false,
        -- A book of crosswords fetched: another one from its source.
        nb.feed and nb.feed ~= "imp" and self.on_crossword and act("getcw", nil, function() close() self.on_crossword(nb.feed) end) or false,
        -- Another puzzle, picked at random (one not started, else downloaded).
        nb.feed and self.on_random and act("random", nil, function() close() self.on_random(self) end) or false,
        nb.feed and self.on_orient and act("orient", self:orientationName(), function()
            close()
            self:chooseOrientation(function(landscape, mode) self.on_orient(self, landscape, mode, true) end)
        end) or false,
        -- The web page's Crosswords section, on a phone (a QR code).
        self.on_web_crossword and act("web", nil, function() close() self.on_web_crossword(self) end) or false,
        not Settings.noAI() and act("ask", nil, function() self:runAction("ask") end) or false,
        act("export", nil, function() self:runAction("export") end),
        "-",
        act("hide", page.hide and _("On") or _("Off"), function() self:toggleHidden() end, page.hide == true),
        "-",
        act("rename", nil, function() close() self:rename() end),
        act("pressure", nb.pressure == false and _("Off") or _("On"), function()
            nb.pressure = nb.pressure == false
            self:changed()
            self:repaint()
        end),
        "-",
        KO.hasLight() and act("light", nil, function() self:runAction("light") end) or false,
        act("night", KO.nightMode() and _("On") or _("Off"), function() self:runAction("night") end, KO.nightMode()),
        act("refresh", nil, function() self:runAction("refresh") end),
        "-",
        act("settings", nil, function() self:runAction("settings") end),
    }
    if not byKey then return list end
    local out = {}
    for __, a in ipairs(list) do
        if type(a) == "table" then out[a.key] = a end
    end
    return out
end

--- An action of the ⋯ menu (Settings.ACTIONS), from the menu or its toolbar button.
function Editor:runAction(key)
    local nb = self.notebook
    if key == "bookmark" then
        self:toggleStar()
        return self:repaint()
    end
    self.panel = nil
    if key == "refresh" then return KO.refresh(self) end
    self:repaint()
    if key == "onenote" or key == "totext" or key == "ask" or key == "todo" then
        self:saveNow()
        local fn = ({ onenote = self.on_onenote, totext = self.on_text, ask = self.on_ask, todo = self.on_todo })[key]
        if fn then fn(nb, self.page, key == "todo" and self:writtenLines() or nil) end
    elseif key == "datetime" then
        self.placing = (os.date("%a, %b %d"):gsub(" 0", " ")) .. " · " .. UI.clock()
        KO.toast(_("Tap where it goes"))
    elseif key == "export" then
        self:showExport()
    elseif TIDY[key] then
        self:tidy(TIDY[key])
    elseif key == "light" then
        KO.light()
    elseif key == "night" then
        KO.toggleNightMode(self.kui)
        self:repaint()
    elseif key == "settings" then
        local changed = function() self:settingsChanged() end
        -- A crossword book: Crosswords' own settings.
        if nb.puzzle and self.on_crossword_settings then return self.on_crossword_settings(changed) end
        if self.on_settings then self.on_settings(changed) else Settings.show(changed, { kui = self.kui }) end
    end
end

function Editor:refreshToolbar()
    if self.folded then return self:repaint() end
    self:repaint({ self:toolbarX(), 0, self.bar_w + 2, self.h })
end

function Editor:setFolded(folded)
    self.folded = folded
    self.panel = nil
    self:layout()
    self:renderPage()
    self:repaint()
end

function Editor:pickTool(key)
    if key == "zoom" and self.notebook.puzzle then return self:toggleZoomView() end
    if key == "zoom" then
        -- The zoom box goes on and off; the tool stays.
        self.zoomOn = not self.zoomOn
        self.panel = nil
        return self:repaint()
    end
    if self.tool == key and key ~= "lasso" then
        return self:togglePanel(key)
    end
    if key == "lasso" and self.view then
        -- The lasso works on the whole page: the zoom goes off.
        self.view = nil
        self:freeView()
        self:renderPage()
        UIManager:setDirty(self, "full")
    end
    self:commitSelection()
    self.pasteAt = nil
    self.tool = key
    self.panel = key == "insert" and "insert" or nil
    self:repaint()
end

-- ------------------------------------------------------------------ panels

function Editor:togglePanel(kind)
    if self.panel == kind then return self:closePanel() end
    self.panel = kind
    self:repaint()
end

function Editor:closePanel()
    if not self.panel then return end
    self.panel = nil
    -- Only where the panel was, cleaned (the whole page flashed before).
    local area = self.panelArea
    self.panelArea = nil
    if area then return self:repaint(self:padded(area, self.ui:u(4)), "full") end
    self:repaint(nil, "full")
end

-- Where a panel goes: beside the toolbar, level with its button.
function Editor:panelBox(pw, ph, anchor)
    local ui = self.ui
    local x = self.side == "left" and self.bar_w + ui:u(8) or self.w - self.bar_w - ui:u(8) - pw
    local y = math.floor(anchor - ui:u(22))
    if anchor > self.h / 2 then y = math.floor(anchor + ui:u(20) - ph) end
    y = math.max(ui:u(4), math.min(self.h - ph - ui:u(4), y))
    return x, y
end

function Editor:paintPanel(bb)
    local kind, ui = self.panel, self.ui
    local u = function(n) return ui:u(n) end
    local anchor = self.buttonY and self.buttonY[kind] or u(60)
    local pw, ph = u(236), ({ pen = 286, hl = 104, eraser = 160, shapes = 208, text = 142, insert = 162 })[kind]
    if kind == "shapes" and Settings.get("shape") == "table" then ph = ph + 64 end
    if kind:match("^g:") then
        pw, ph = u(236), u(30) + #(Settings.groups()[kind:sub(3)] or {}) * u(30) + u(6)
    elseif kind == "history" then
        pw, ph = u(236), u(30) + math.min(#self.undo, self:historyRows()) * u(28) + u(6)
    elseif kind == "hint" then
        local rows, check = self:hintRows()
        pw, ph = u(256), u(36) + (#rows + (check and 1 or 0) + 1) * u(30) + u(MORE_GAP) + u(6)
    elseif kind == "more" then
        local rows, gaps = 0, 0
        for __, row in ipairs(self:moreRows()) do
            if row == "-" then gaps = gaps + 1 else rows = rows + 1 end
        end
        local fixed = u(((self.notebook.puzzle or self.spread) and 6 or 304) + gaps * MORE_GAP + 6)
        self.moreRowH = math.max(u(18), math.min(u(26), math.floor((self.h - u(8) - fixed) / math.max(1, rows))))
        pw, ph = u(244), fixed + rows * self.moreRowH
    else
        ph = u(ph)
    end
    local x, y = self:panelBox(pw, ph, anchor)
    ui:box(bb, x, y, pw, ph, { fill = UI.WHITE, border = UI.BLACK, r = u(8), bw = math.max(2, u(1.2)) })
    self:hit(x, y, pw, ph, function() end)   -- taps inside a panel never close it
    local panelArea = { x - 2, y - 2, pw + 4, ph + 4 }
    self.panelArea = panelArea
    local function changed() self:repaint(panelArea) end
    if kind == "hint" then
        self:paintHintPanel(bb, x, y, pw)
    elseif kind == "pen" then
        self:paintPenPanel(bb, x, y, pw, changed)
    elseif kind == "hl" then
        ui:drawText(bb, _("Highlighter"), x + u(10), y + u(16), 10, { bold = true })
        ui:drawText(bb, _("Goes under the ink"), x + pw - u(10), y + u(16), 8.5, { align = "right", color = UI.GREY_TEXT })
        local grey = Blitbuffer.Color8(Ink.TIPS.hl.grey)
        for i = 1, 5 do
            local cx = x + u(30) + (i - 1) * u(44)
            local hh = math.min(u(22), Ink.tipWidth("hl", i, nil, self.scale))
            if self.sizes.hl == i then ui:box(bb, cx - u(21), y + u(30), u(42), u(30), { border = UI.BLACK, r = u(5) }) end
            bb:paintRect(cx - u(16), y + u(45) - math.floor(hh / 2), u(32), hh, grey)
            self:hit(cx - u(22), y + u(28), u(44), u(34), function()
                self.sizes.hl = i
                Settings.set("sizes", self.sizes)
                changed()
            end)
        end
        ui:line(bb, x + u(8), y + u(68), pw - u(16), 1)
        local band = math.min(u(18), Ink.tipWidth("hl", self.sizes.hl or 3, nil, self.scale))
        bb:paintRect(x + u(14), y + u(86) - math.floor(band / 2), u(140), band, grey)
        ui:drawText(bb, _("Highlighted words"), x + u(18), y + u(86), 11)
    elseif kind:match("^g:") then
        self:paintGroup(bb, x, y, pw, kind:sub(3))
    elseif kind == "history" then
        self:paintHistory(bb, x, y, pw)
    elseif kind == "shapes" then
        self:paintShapes(bb, x, y, pw, changed)
    elseif kind == "text" then
        ui:drawText(bb, _("Text"), x + u(10), y + u(16), 10, { bold = true })
        ui:drawText(bb, _("Tap to type; tap a text box to edit"), x + pw - u(10), y + u(16), 8.5, { align = "right", color = UI.GREY_TEXT })
        -- Rows of choices: size, style, font, alignment.
        local function choices(sy, opts)
            local sx, sw, sh = x + u(10), pw - u(20), u(24)
            local part = math.floor(sw / #opts)
            ui:box(bb, sx, sy, sw, sh, { border = UI.BLACK, r = u(5) })
            for i, o in ipairs(opts) do
                local cx = sx + (i - 1) * part
                if o.on then ui:box(bb, cx, sy, part, sh, { fill = UI.BLACK, r = u(5) }) end
                ui:drawText(bb, o.text, cx + math.floor(part / 2), sy + math.floor(sh / 2), o.size or 10,
                    { align = "center", bold = o.on or o.bold, color = o.on and UI.WHITE or UI.BLACK })
                self:hit(cx, sy, part, sh, function() o.set() changed() end)
            end
        end
        local size = Settings.get("text_size") or "m"
        local sizes = {}
        for __, k in ipairs({ "s", "m", "l", "xl" }) do
            table.insert(sizes, { text = ({ s = _("Small"), m = _("Medium"), l = _("Large"), xl = _("Title") })[k],
                size = ({ s = 9, m = 10, l = 11, xl = 12 })[k], on = size == k, set = function() Settings.set("text_size", k) end })
        end
        choices(y + u(30), sizes)
        choices(y + u(60), {
            { text = _("Bold"), bold = true, on = Settings.get("text_bold"), set = function() Settings.set("text_bold", not Settings.get("text_bold")) end },
            { text = _("Italic"), on = Settings.get("text_italic"), set = function() Settings.set("text_italic", not Settings.get("text_italic")) end },
            { text = _("Sans"), on = not Settings.get("text_serif"), set = function() Settings.set("text_serif", false) end },
            { text = _("Serif"), on = Settings.get("text_serif"), set = function() Settings.set("text_serif", true) end },
        })
        local align = Settings.get("text_align") or "left"
        choices(y + u(90), {
            { text = _("Left"), on = align == "left", set = function() Settings.set("text_align", "left") end },
            { text = _("Centre"), on = align == "center", set = function() Settings.set("text_align", "center") end },
            { text = _("Right"), on = align == "right", set = function() Settings.set("text_align", "right") end },
        })
        ui:drawText(bb, _("Drag across to set the box's width"), x + u(10), y + u(128), 9, { color = UI.GREY_TEXT })
    elseif kind == "insert" then
        local rows = {
            { "image", _("Picture…"), function() self.panel = nil self:repaint() self:insertPicture() end },
            { "link", _("Link to a page…"), function() self.panel = nil self:repaint() self:insertLink() end },
            { "rectangle-horizontal", _("Tape: drag over what to hide"), function()
                Settings.set("insert_kind", "tape")
                self.panel = nil
                self:repaint()
            end },
            { "eye", _("Lift all tape on this page"), function() self.panel = nil self:allTape(true) end },
            { "eye-off", _("Put all tape back"), function() self.panel = nil self:allTape(false) end },
        }
        for i, row in ipairs(rows) do
            local ry = y + u(8) + (i - 1) * u(30)
            ui:drawIcon(bb, row[1], x + u(12), ry + u(6), u(16))
            ui:drawText(bb, row[2], x + u(36), ry + u(14), 10)
            self:hit(x, ry, pw, u(30), row[3])
        end
    elseif kind == "eraser" then
        ui:drawText(bb, _("Eraser"), x + u(10), y + u(16), 10, { bold = true })
        if self.pen then
            ui:drawText(bb, _("Press harder: bigger"), x + pw - u(10), y + u(16), 8.5, { align = "right", color = UI.GREY_TEXT })
        end
        for i = 1, 5 do
            local cx, cy = x + u(26) + (i - 1) * u(46), y + u(44)
            local r = math.min(u(14), math.floor(Ink.ERASER_SIZES[i] * self.scale + 0.5))
            if self.eraserSize == i then bb:paintCircle(cx, cy, u(16), UI.BLACK, math.max(2, u(1.2))) end
            bb:paintCircle(cx, cy, r, UI.BLACK, math.max(1, u(1)))
            self:hit(cx - u(22), cy - u(18), u(44), u(36), function()
                self.eraserSize = i
                Settings.set("eraser_size", i)
                changed()
            end)
        end
        ui:line(bb, x + u(8), y + u(68), pw - u(16), 1)
        local whole = Settings.get("whole_eraser")
        local sx, sy, sw, sh = x + u(10), y + u(76), pw - u(20), u(22)
        ui:box(bb, sx, sy, sw, sh, { border = UI.BLACK, r = u(5) })
        local half = math.floor(sw / 2)
        ui:box(bb, whole and sx + half or sx, sy, half, sh, { fill = UI.BLACK, r = u(5) })
        ui:drawText(bb, _("Partial"), sx + math.floor(half / 2), sy + math.floor(sh / 2), 9.5, { align = "center", bold = not whole, color = whole and UI.BLACK or UI.WHITE })
        ui:drawText(bb, _("Whole stroke"), sx + half + math.floor(half / 2), sy + math.floor(sh / 2), 9.5, { align = "center", bold = whole, color = whole and UI.WHITE or UI.BLACK })
        self:hit(sx, sy, half, sh, function() Settings.set("whole_eraser", false) changed() end)
        self:hit(sx + half, sy, half, sh, function() Settings.set("whole_eraser", true) changed() end)
        -- Highlighter only: the ink and text boxes stay.
        local hlOnly = Settings.get("eraser_hl")
        ui:box(bb, x + u(12), y + u(106), u(14), u(14), { border = UI.BLACK, r = u(3), fill = hlOnly and UI.BLACK or nil })
        if hlOnly then ui:drawIcon(bb, "check", x + u(13), y + u(107), u(12), true) end
        ui:drawText(bb, _("Highlighter only"), x + u(32), y + u(113), 10)
        self:hit(x, y + u(100), pw, u(28), function() Settings.set("eraser_hl", not hlOnly) changed() end)
        ui:line(bb, x + u(8), y + u(130), pw - u(16), 1)
        ui:drawIcon(bb, "trash-2", x + u(12), y + u(134), u(14), false, #self:strokes() == 0)
        ui:drawText(bb, _("Clear page"), x + u(32), y + u(141), 10, { color = #self:strokes() == 0 and UI.MID or UI.BLACK })
        self:hit(x, y + u(128), pw, u(28), function()
            if #self:strokes() == 0 then return end
            self.panel = nil
            self:clearPage()
        end)
    else
        self:paintMore(bb, x, y, pw)
    end
end

-- The Shapes panel: eight shapes, and rows and columns for a table.
function Editor:paintShapes(bb, x, y, pw, changed)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    local current = Settings.get("shape")
    ui:drawText(bb, _("Shapes"), x + u(10), y + u(16), 10, { bold = true })
    ui:drawText(bb, _("Drag corner to corner"), x + pw - u(10), y + u(16), 8.5, { align = "right", color = UI.GREY_TEXT })
    for i, kind in ipairs(Shapes.KINDS) do
        local bx, by = x + u(8) + ((i - 1) % 4) * u(56), y + u(28) + math.floor((i - 1) / 4) * u(46)
        local on = current == kind
        ui:box(bb, bx, by, u(52), u(42), { fill = on and UI.BLACK or UI.WHITE, border = on and UI.BLACK or UI.MID, r = u(6) })
        ui:drawIcon(bb, SHAPE_ICONS[kind], bx + u(18), by + u(5), u(16), on)
        ui:drawText(bb, SHAPE_NAMES[kind], bx + u(26), by + u(33), 8.5, { align = "center", bold = on, color = on and UI.WHITE or UI.BLACK })
        self:hit(bx, by, u(52), u(42), function()
            Settings.set("shape", kind)
            if (kind == "table") ~= (current == "table") then self:repaint() else changed() end
        end)
    end
    local ry = y + u(124)
    -- Fill and line style.
    local function choice(label, key, options, names, sy)
        ui:drawText(bb, label, x + u(10), sy + u(12), 9.5)
        local sx, sw, sh = x + u(62), pw - u(72), u(24)
        local part = math.floor(sw / #options)
        ui:box(bb, sx, sy, sw, sh, { border = UI.BLACK, r = u(5) })
        for i, opt in ipairs(options) do
            local on = (Settings.get(key) or options[1]) == opt
            local cx = sx + (i - 1) * part
            if on then ui:box(bb, cx, sy, part, sh, { fill = UI.BLACK, r = u(5) }) end
            ui:drawText(bb, names[i], cx + math.floor(part / 2), sy + math.floor(sh / 2), 9, { align = "center", bold = on, color = on and UI.WHITE or UI.BLACK })
            self:hit(cx, sy, part, sh, function() Settings.set(key, opt) changed() end)
        end
    end
    choice(_("Fill"), "shape_fill", { "none", "light", "dark" }, { _("None"), _("Light"), _("Dark") }, ry)
    choice(_("Line"), "shape_line", { "solid", "dash", "dot" }, { _("Solid"), _("Dashed"), _("Dotted") }, ry + u(30))
    ry = ry + u(64)
    if current == "table" then
        local function stepper(label, key, sy)
            ui:drawText(bb, label, x + u(10), sy + u(13), 9.5)
            local n = Settings.get(key)
            local bx = x + pw - u(10) - u(72)
            local ry = sy
            ui:box(bb, bx, ry + u(2), u(22), u(22), { border = UI.BLACK, r = u(4) })
            ui:drawText(bb, "−", bx + u(11), ry + u(13), 11, { align = "center", bold = true })
            ui:drawText(bb, tostring(n), bx + u(36), ry + u(13), 11, { align = "center", bold = true })
            ui:box(bb, bx + u(50), ry + u(2), u(22), u(22), { border = UI.BLACK, r = u(4) })
            ui:drawText(bb, "+", bx + u(61), ry + u(13), 11, { align = "center", bold = true })
            self:hit(bx - u(4), ry - u(2), u(30), u(30), function() Settings.set(key, math.max(1, n - 1)) changed() end)
            self:hit(bx + u(46), ry - u(2), u(30), u(30), function() Settings.set(key, math.min(20, n + 1)) changed() end)
        end
        stepper(_("Rows"), "table_rows", ry)
        stepper(_("Columns"), "table_cols", ry + u(30))
        ry = ry + u(64)
    end
    ui:line(bb, x + u(8), ry - u(4), pw - u(16), 1)
    ui:drawText(bb, _("Uses the pen's tip and size"), x + u(10), ry + u(8), 9, { color = UI.GREY_TEXT })
end

-- The pen's panel: nine tips, the ink's shade, five sizes, a sample stroke,
-- and saving the pen as a favorite.
function Editor:paintPenPanel(bb, x, y, pw, changed)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    for i, tip in ipairs(Ink.PEN_TIPS) do
        local bx, by = x + u(8) + ((i - 1) % 3) * u(74), y + u(8) + math.floor((i - 1) / 3) * u(40)
        local on = self.tip == tip
        ui:box(bb, bx, by, u(70), u(36), { fill = on and UI.BLACK or UI.WHITE, border = on and UI.BLACK or UI.MID, r = u(6) })
        ui:drawIcon(bb, TIP_ICONS[tip], bx + u(27), by + u(3), u(15), on)
        ui:drawText(bb, TIP_NAMES[tip], bx + u(35), by + u(28), 8, { align = "center", bold = on, color = on and UI.WHITE or UI.BLACK })
        self:hit(bx, by, u(70), u(36), function()
            self.tip = tip
            Settings.set("tip", tip)
            changed()
        end)
    end
    ui:line(bb, x + u(8), y + u(132), pw - u(16), 1)
    -- The shade: the tip's own, dark grey or light grey (not for the shader).
    local shadable = not (Ink.TIPS[self.tip] or {}).under
    local sx, sy, sw, sh = x + u(10), y + u(138), pw - u(20), u(22)
    local third = math.floor(sw / 3)
    ui:box(bb, sx, sy, sw, sh, { border = shadable and UI.BLACK or UI.MID, r = u(5) })
    for i, key in ipairs({ "default", "dark", "light" }) do
        local on = shadable and (self.shade or "default") == key
        local cx = sx + (i - 1) * third
        if on then ui:box(bb, cx, sy, third, sh, { fill = UI.BLACK, r = u(5) }) end
        local black = (Ink.TIPS[self.tip] or {}).grey == 0
        local label = ({ default = black and _("Black") or _("Normal"), dark = black and _("Dark grey") or _("Darker"),
            light = black and _("Light grey") or _("Lighter") })[key]
        ui:drawText(bb, label, cx + math.floor(third / 2), sy + math.floor(sh / 2), 9,
            { align = "center", bold = on, color = on and UI.WHITE or (shadable and UI.BLACK or UI.MID) })
        if shadable then
            self:hit(cx, sy, third, sh, function()
                self.shade = key
                Settings.set("shade", key)
                changed()
            end)
        end
    end
    ui:line(bb, x + u(8), y + u(168), pw - u(16), 1)
    self:paintSizes(bb, x, y + u(186), self.tip, changed)
    ui:line(bb, x + u(8), y + u(204), pw - u(16), 1)
    self:paintPreview(bb, x + u(16), y + u(210), pw - u(32), u(36), self.tip)
    ui:line(bb, x + u(8), y + u(252), pw - u(16), 1)
    ui:drawIcon(bb, "star", x + u(12), y + u(260), u(14))
    ui:drawText(bb, _("Add to favorites (toolbar)"), x + u(32), y + u(267), 10)
    self:hit(x, y + u(254), pw, u(28), function()
        local favs = Settings.get("favorites") or {}
        local fav = { tip = self.tip, size = self.sizes[self.tip] or 2, shade = self.shade ~= "default" and self.shade or nil }
        for __, f in ipairs(favs) do
            if f.tip == fav.tip and f.size == fav.size and f.shade == fav.shade then return end
        end
        table.insert(favs, fav)
        if #favs > 3 then table.remove(favs, 1) end
        Settings.set("favorites", favs)
        self:repaint()
    end)
end

-- A favorite pen picked on the toolbar.
function Editor:useFavorite(i)
    local fav = (Settings.get("favorites") or {})[i]
    if not fav then return end
    self:commitSelection()
    self.tool = "pen"
    self.tip = fav.tip
    self.sizes[fav.tip] = fav.size
    self.shade = fav.shade or "default"
    -- Remembered as the last pen, as one picked in the pen panel is.
    Settings.set("tip", self.tip)
    Settings.set("sizes", self.sizes)
    Settings.set("shade", self.shade)
    self.panel = nil
    self:repaint()
end

-- The grey a new stroke gets from the shade picked (nil: the tip's own).
function Editor:shadeGrey(tip)
    if not self.shade or self.shade == "default" or (Ink.TIPS[tip] or {}).under then return nil end
    return Ink.tipShade(tip, self.shade)
end


-- ------------------------------------------------------------------ text boxes, pictures, tape

local TEXT_SIZES = { s = 42, m = 54, l = 75, xl = 110 }     -- letter heights in pixels at 300 dpi
Editor.TEXT_SIZES = TEXT_SIZES

function Editor:textSize()
    return math.floor((TEXT_SIZES[Settings.get("text_size") or "m"] or 54) * self.scale + 0.5)
end

-- The look new text boxes get: the Text panel's choices.
function Editor:textStyle()
    return { bold = Settings.get("text_bold") or nil, italic = Settings.get("text_italic") or nil,
        serif = Settings.get("text_serif") or nil, align = Settings.get("text_align") }
end

-- A text box typed at (x, y), `w` wide; or `item` changed. Opens the
-- keyboard; a row of buttons sets bold, italic, the font and alignment.
function Editor:editText(item, x, y, w, style, typed)
    style = style or (item and { bold = item.bold, italic = item.italic, serif = item.serif, align = item.align }) or self:textStyle()
    local dialog
    local function done(text)
        if dialog then UIManager:close(dialog) end
        local before = self:snapshot()
        local items = self:pageItems()
        local area
        local function made(base)
            return { k = "text", x = base.x, y = base.y, w = base.w, size = base.size, text = text,
                bold = style.bold, italic = style.italic, serif = style.serif,
                align = style.align ~= "left" and style.align or nil, link = base.link }
        end
        if item then
            local bx, by, bw, bh = Items.box(item)
            area = { bx, by, bw, bh }
            for i, it in ipairs(items) do
                if it == item then
                    if text == nil or text == "" then
                        table.remove(items, i)
                    else
                        items[i] = made(item)
                        item = items[i]
                    end
                    break
                end
            end
        elseif text and text ~= "" then
            item = made({ x = x, y = y, w = w, size = self:textSize() })
            table.insert(items, item)
        else
            return
        end
        if text and text ~= "" then
            local bx, by, bw, bh = Items.box(item)
            area = Ink.union(area, { bx, by, bw, bh })
        end
        self:pushSnapshot(before)
        if area then
            self:renderArea(area)
            self:showArea(area, "ui")
        end
    end
    local alignNames = { left = _("Left"), center = _("Centre"), right = _("Right") }
    -- The launcher's box: the text (several lines, or the pen), its style as
    -- switches under it, Cancel, Delete (an existing text) and Save.
    local request = KO.request()
    if request then
        local buttons = { { icon = "x", text = _("Cancel"), cancel = true } }
        if item then table.insert(buttons, { icon = "trash-2", text = _("Delete"), fn = function() done(nil) end }) end
        table.insert(buttons, { icon = "check", text = _("Save"), primary = true, fn = function(t, box) done(box:getText()) end })
        return request{
            title = item and _("Edit text") or _("Text"),
            text = typed or (item and item.text) or "",
            lines = 5,
            typing = true,
            pen = KO.pen(), penTitle = _("Write the text"),
            sections = { { chips = {
                -- (Each label in the style it stands for.)
                { text = _("Bold"), font = { bold = true }, on = function() return style.bold == true end,
                    tap = function() style.bold = not style.bold or nil end },
                { text = _("Italic"), font = { italic = true }, on = function() return style.italic == true end,
                    tap = function() style.italic = not style.italic or nil end },
                { text = function() return style.serif and _("Serif") or _("Sans") end, on = false,
                    font = function() return { serif = style.serif == true } end,
                    tap = function() style.serif = not style.serif or nil end },
                { text = function() return alignNames[style.align or "left"] end, on = false, font = {}, tap = function()
                    style.align = ({ left = "center", center = "right", right = "left" })[style.align or "left"]
                end },
            } } },
            buttons = buttons,
        }
    end
    -- A style button: changes the style and shows the dialog again, with
    -- what was typed so far.
    local function restyle(fn)
        return function()
            local now = dialog:getInputText()
            UIManager:close(dialog)
            fn()
            self:editText(item, x, y, w, style, now)
        end
    end
    local styleRow = {
        { text = style.bold and _("✓ Bold") or _("Bold"), callback = restyle(function() style.bold = not style.bold or nil end) },
        { text = style.italic and _("✓ Italic") or _("Italic"), callback = restyle(function() style.italic = not style.italic or nil end) },
        { text = style.serif and _("Serif") or _("Sans"), callback = restyle(function() style.serif = not style.serif or nil end) },
        { text = alignNames[style.align or "left"], callback = restyle(function()
            style.align = ({ left = "center", center = "right", right = "left" })[style.align or "left"]
        end) },
    }
    -- (Four buttons, as the style row: the dividers line up.)
    local buttons = { { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end } }
    table.insert(buttons, { text = _("Paste"), callback = function()
        local clip = Device.input.getClipboardText and Device.input.getClipboardText()
        if clip and clip ~= "" then dialog:addTextToInput(clip) end
    end })
    if item then
        table.insert(buttons, { text = _("Delete"), callback = function() done(nil) end })
    else
        table.insert(buttons, { text = _("Clear"), callback = function() dialog:setInputText("") end })
    end
    table.insert(buttons, { text = _("Save"), is_enter_default = false, callback = function() done(dialog:getInputText()) end })
    dialog = InputDialog:new{
        title = item and _("Edit text") or _("Text"),
        input = typed or (item and item.text) or "",
        allow_newline = true,
        buttons = { styleRow, buttons },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- A picture from the Kindle's files, placed in the middle of the page and
-- selected (move or resize it with the lasso).
function Editor:insertPicture()
    local start = G_reader_settings:readSetting("home_dir") or Device.home_dir or "/mnt/us/documents"
    require("notespick").show{
        title = _("Choose a picture"),
        path = start,
        filter = function(file)
            local ext = file:lower():match("%.(%a+)$")
            return ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "gif" or ext == "webp" or ext == "bmp"
        end,
        done = function(path) self:placePicture(path) end,
    }
end

function Editor:placePicture(path)
    local dir = self:imageDir()
    require("util").makePath(dir)
    local ext = path:lower():match("%.(%a+)$") or "png"
    local file = string.format("img%d%03d.%s", os.time(), math.random(0, 999), ext)
    local ok, why = Store.copyFile(path, dir .. "/" .. file)
    if not ok then
        KO.message(T(_("Could not copy the picture:\n%1"), tostring(why)))
        return
    end
    local r = self.pageRect
    -- A big photo made screen-sized once (drawing it is then quick).
    Items.shrinkPicture(dir .. "/" .. file, math.max(Screen:getWidth(), Screen:getHeight()))
    local w, h = Items.pictureSize(dir .. "/" .. file, math.floor(r[3] * 0.6), math.floor(r[4] * 0.5))
    if not w then
        os.remove(dir .. "/" .. file)
        KO.message(_("Could not read the picture."))
        return
    end
    local it = { k = "image", x = r[1] + math.floor((r[3] - w) / 2), y = r[2] + math.floor((r[4] - h) / 3), w = w, h = h, file = file }
    self.tool = "lasso"
    self:addSelected({}, { it })
end

-- ------------------------------------------------------------------ links

--- A link to a page (of this notebook or another) placed on the page as an
-- underlined text box, selected to be moved; tapping it goes there.
function Editor:insertLink()
    local here = self.notebook
    local others = {}
    if self.store and self.store.list then
        for __, nb in ipairs(Store.sorted(self.store:list(), "name")) do
            if nb.id ~= here.id then table.insert(others, nb) end
        end
    end
    local dialog
    local function askPage(id, name, count)
        KO.ask{ title = T(_("Link to which page of %1 (1–%2)?"), name, count), text = "1", number = true,
            ok = _("Link"), done = function(typed)
                local n = math.max(1, math.min(count, math.floor(tonumber(typed) or 1)))
                local nb = id == here.id and here or (self.store:read(id))
                local page = nb and nb.pages[n]
                if not page then return end
                local text = "→ " .. (id == here.id and T(_("page %1"), n) or (n > 1 and T(_("%1, page %2"), name, n) or name))
                self:placeLink(id .. "|" .. page.id, text)
            end }
    end
    local buttons = { { { text = _("A page in this notebook…"), align = "left", callback = function()
        UIManager:close(dialog)
        askPage(here.id, here.name, #here.pages)
    end } } }
    for __, nb in ipairs(others) do
        table.insert(buttons, { { text = nb.name, align = "left", callback = function()
            UIManager:close(dialog)
            askPage(nb.id, nb.name, nb.pages or 1)
        end } })
    end
    table.insert(buttons, { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } })
    dialog = KO.buttonDialog{ title = _("Link to"), title_align = "center", buttons = buttons }
end

function Editor:placeLink(link, text)
    local r = self.pageRect
    local size = math.floor((TEXT_SIZES.m or 54) * self.scale + 0.5)
    local it = { k = "text", link = link, text = text, size = size, w = 10 }
    -- As wide as its words (a little more, so they stay on one line).
    it.w = math.min(r[3] - 20, Items.textWidth(it) + math.floor(size / 3))
    it.x = r[1] + math.floor((r[3] - it.w) / 2)
    it.y = r[2] + math.floor(r[4] / 3)
    self.tool = "lasso"
    self:addSelected({}, { it })
end

--- A link tapped: its page, here or in its notebook.
function Editor:followLink(link)
    local id, pageId = link:match("^(nb%d+)|(.*)$")
    if not id then return end
    if id == self.notebook.id then
        for i, page in ipairs(self.notebook.pages) do
            if page.id == pageId then return self:goPage(i) end
        end
        return KO.message(_("That page is no longer in this notebook."))
    end
    self:commitSelection()
    self:saveNow()
    if self.on_link then self.on_link(id, pageId) end
end

-- Tape lifted or put back.
function Editor:toggleTape(item)
    item.open = not item.open
    self:changed()
    local area = { item.x, item.y, item.w, item.h }
    self:renderArea(area)
    self:showArea(area, "ui")
end

function Editor:allTape(open)
    for __, it in ipairs(self:pageItems()) do
        if it.k == "tape" then it.open = open end
    end
    self:changed()
    self:renderPage()
    self:repaint()
end

-- ------------------------------------------------------------------ a request to Claude, written

--- A strip at the bottom of the page to write a request to Claude by hand;
-- `done(png, pdf)` gets a picture of it (pdf: Make PDF was tapped).
-- opts (for other uses of the strip): label, send (its button), pdf = false
-- (no Make PDF), cancel() (Cancel tapped).
function Editor:startAskPad(done, opts)
    self:commitSelection()
    self.panel = nil
    self.zoomOn = false
    self.askPad = { done = done, strokes = {}, opts = opts or {} }
    self:repaint()
end

function Editor:askPadRect()
    local r = self.pageRect
    local h = math.floor(self.h * 0.26)
    return { r[1], self.h - h, r[3], h }
end

function Editor:paintAskPad(bb)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    local r = self:askPadRect()
    bb:paintRect(r[1], r[2], r[3], r[4], UI.WHITE)
    bb:paintRect(r[1], r[2] - 2, r[3], 3, UI.BLACK)
    local opts = self.askPad.opts or {}
    ui:drawText(bb, opts.label or _("Write what the AI should do"), r[1] + u(10), r[2] + u(11), 9.5, { color = UI.GREY_TEXT })
    for __, s in ipairs(self.askPad.strokes) do
        local p = s.p
        if #p == 2 then
            Ink.segment(p[1], p[2], p[1], p[2], s.w, self:stamper({ bb }, UI.BLACK))
        else
            for i = 1, #p - 3, 2 do Ink.segment(p[i], p[i + 1], p[i + 2], p[i + 3], s.w, self:stamper({ bb }, UI.BLACK)) end
        end
    end
    local bx, bw = r[1] + r[3] - u(80), u(76)
    bb:paintRect(bx - u(4), r[2], 1, r[4], UI.MID)
    local buttons = { { opts.send or _("Ask"), function() self:sendAskPad(false) end, true } }
    if opts.pdf ~= false then table.insert(buttons, { _("Make PDF"), function() self:sendAskPad(true) end, true }) end
    table.insert(buttons, { _("Clear"), function() self.askPad.strokes = {} self:repaint(self:padded(r, 4)) end })
    table.insert(buttons, { _("Cancel"), function()
        self.askPad = nil
        self:repaint()
        if opts.cancel then opts.cancel() end
    end })
    local bh = math.floor((r[4] - u(12)) / #buttons)
    for i, b in ipairs(buttons) do
        local by = r[2] + u(6) + (i - 1) * bh
        ui:box(bb, bx, by + u(3), bw, bh - u(6), { fill = b[3] and UI.BLACK or UI.WHITE, border = UI.BLACK, r = u(6) })
        ui:drawText(bb, b[1], bx + math.floor(bw / 2), by + math.floor(bh / 2), 10, { align = "center", bold = true, color = b[3] and UI.WHITE or UI.BLACK })
        self:hit(bx, by, bw, bh, b[2])
    end
end

-- The written request as a picture, handed on.
function Editor:sendAskPad(pdf)
    local pad = self.askPad
    if not pad or #pad.strokes == 0 then return end
    local r = self:askPadRect()
    local bb = Blitbuffer.new(r[3], r[4], Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    local stamp = function(x, y, s) bb:paintRect(x - r[1], y - r[2], s, s, Blitbuffer.COLOR_BLACK) end
    for __, s in ipairs(pad.strokes) do
        local p = s.p
        if #p == 2 then
            Ink.segment(p[1], p[2], p[1], p[2], s.w, stamp)
        else
            for i = 1, #p - 3, 2 do Ink.segment(p[i], p[i + 1], p[i + 2], p[i + 3], s.w, stamp) end
        end
    end
    local path = DataStorage:getDataDir() .. "/cache/notes-request.png"
    require("util").makePath(DataStorage:getDataDir() .. "/cache")
    local ok = pcall(bb.writePNG, bb, path)
    bb:free()
    self.askPad = nil
    self:repaint()
    if not ok then return end
    local f = io.open(path, "rb")
    local png = f and f:read("*a")
    if f then f:close() end
    os.remove(path)
    if png then pad.done(png, pdf) end
end

-- ------------------------------------------------------------------ the zoom box

-- The strip where you write large (at the bottom, or where its grip was
-- dragged to), and the part of the page it writes into: strip { x, y, w, h },
-- zoom, target { x, y, w, h }.
function Editor:zoomGeometry()
    local u = function(n) return self.ui:u(n) end
    local r = self.pageRect
    local sh = math.floor(self.h * 0.28)
    -- Its place: 0 at the top of the page, 1 at the bottom of the screen.
    local f = self.stripFrac or tonumber(Settings.get("zoom_strip")) or 1
    f = math.max(0, math.min(1, f))
    local strip = { r[1], r[2] + math.floor((self.h - sh - r[2]) * f), r[3] - u(44), sh }
    local z = 2.5
    local tw, th = math.floor(strip[3] / z), math.floor(sh / z)
    local at = self.zoomAt or { r[1] + u(10), math.floor(self.h * 0.12) }
    at[1] = math.max(r[1], math.min(r[1] + r[3] - tw, at[1]))
    -- The box stays clear of the strip: above it, or below it, whichever
    -- side it is on (the other when there is no room).
    local above = { r[2], strip[2] - th - u(4) }
    local below = { strip[2] + sh + u(4), r[2] + r[4] - th }
    local zone = (at[2] + th / 2 < strip[2] + sh / 2) and above or below
    if zone[2] < zone[1] then zone = zone == above and below or above end
    if zone[2] >= zone[1] then at[2] = math.max(zone[1], math.min(zone[2], at[2])) end
    self.zoomAt = at
    return strip, z, { at[1], at[2], tw, th }
end

-- The strip's grip (dragged to move it): the top of its buttons.
function Editor:stripGrip()
    local strip = self:zoomGeometry()
    return { strip[1] + strip[3], strip[2], self.ui:u(44), math.floor(strip[4] / 4) }
end

function Editor:onStripGrip(x, y)
    if not self.zoomOn then return false end
    local g, pad = self:stripGrip(), self.ui:u(6)
    return x >= g[1] - pad and x < g[1] + g[3] + pad and y >= g[2] - pad and y < g[2] + g[4] + pad
end

-- The strip dragged: its top follows (the screen catches up a few times a second).
function Editor:dragStrip(y)
    local d = self.stripDrag
    local r = self.pageRect
    local sh = math.floor(self.h * 0.28)
    local range = math.max(1, self.h - sh - r[2])
    self.stripFrac = math.max(0, math.min(1, (y - d.dy - r[2]) / range))
    if self.stripTask then return end
    self.stripTask = function()
        self.stripTask = nil
        self:repaint(nil, "a2")
    end
    UIManager:scheduleIn(0.15, self.stripTask)
end

-- Let go: the strip stays there (for every notebook).
function Editor:dropStrip()
    if not self.stripDrag then return end
    self.stripDrag = nil
    if self.stripTask then UIManager:unschedule(self.stripTask) self.stripTask = nil end
    if self.stripFrac then Settings.set("zoom_strip", math.floor(self.stripFrac * 1000 + 0.5) / 1000) end
    self.stripFrac = nil
    self:repaint(nil, "ui")
end

-- A finger on the grip drags the strip too, and pinned clues.
function Editor:onEditorPan(_arg, ges)
    if not (ges and ges.pos) then return true end
    if not (self.stripDrag or self.cardDrag or self.quickDrag) then
        local rel = ges.relative or { x = 0, y = 0 }
        local x0, y0 = ges.pos.x - rel.x, ges.pos.y - rel.y
        if self.quick and not self:palmLikely() and math.abs(y0 - self:quickEdge()) <= self.ui:u(26) then
            -- A quick note's handle, dragged with a finger.
            self.quickDrag = { from = y0, top = self.quick.top }
        elseif self.zoomOn and self:onStripGrip(x0, y0) then
            self.stripDrag = { dy = y0 - self:zoomGeometry()[2] }
        elseif not self.view and not self:palmLikely() and self:onClueCard(x0, y0) then
            self:grabClueCard(x0, y0)
        else
            return true
        end
    end
    if self.quickDrag then
        self:dragQuick(ges.pos.y)
    elseif self.cardDrag then
        self:dragClueCard(ges.pos.x, ges.pos.y)
    else
        self:dragStrip(ges.pos.y)
    end
    return true
end

function Editor:onEditorPanRelease()
    if self.quickDrag then return self:dragQuick(nil, true) or true end
    self:dropClueCard()
    self:dropStrip()
    return true
end

function Editor:fromStrip(x, y)
    local strip, z, t = self:zoomGeometry()
    return math.floor(t[1] + (x - strip[1]) / z + 0.5), math.floor(t[2] + (y - strip[2]) / z + 0.5)
end

function Editor:inStrip(x, y)
    if not self.zoomOn then return false end
    local strip = self:zoomGeometry()
    return x >= strip[1] and x < strip[1] + strip[3] and y >= strip[2] and y < strip[2] + strip[4]
end

-- The zoom box moved on: along the line by `f` of its width, or to the
-- start of the next line.
function Editor:zoomAdvance(f)
    local __, __, t = self:zoomGeometry()
    local r = self.pageRect
    if f then
        self.zoomAt[1] = t[1] + math.floor(t[3] * f)
        if self.zoomAt[1] + t[3] <= r[1] + r[3] then return self:repaint() end
    end
    self.zoomAt[1] = r[1] + self.ui:u(10)
    self.zoomAt[2] = t[2] + math.floor(t[4] * 0.9)
    self:repaint()
end

function Editor:paintZoom(bb)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    local strip, z, t = self:zoomGeometry()
    ui:dashed(bb, t[1], t[2], t[3], t[4])
    local sx, sy, sw, sh = strip[1], strip[2], strip[3], strip[4]
    local view = self.page_bb:viewport(t[1], t[2], t[3], t[4])
    local big = view:scale(sw, sh)
    bb:blitFrom(big, sx, sy, 0, 0, sw, sh)
    big:free()
    bb:paintRect(sx, sy - 2, self.pageRect[3], 3, UI.BLACK)
    bb:paintRect(sx, sy + sh - 1, self.pageRect[3], 3, UI.BLACK)
    -- Controls on the right: the grip (drag it to move the strip), next,
    -- new line, close.
    local cx = sx + sw
    bb:paintRect(cx, sy, u(44), sh, UI.WHITE)
    bb:paintRect(cx, sy, 2, sh, UI.MID)
    local step = math.floor(sh / 4)
    ui:drawIcon(bb, "grip-vertical", cx + u(13), sy + math.floor(step / 2) - u(9), u(18))
    for i, c in ipairs({ { "chevron-right", function() self:zoomAdvance(0.75) end },
        { "corner-down-left", function() self:zoomAdvance(nil) end },
        { "x", function() self.zoomOn = false self:repaint() end } }) do
        local by = sy + i * step
        ui:drawIcon(bb, c[1], cx + u(13), by + math.floor(step / 2) - u(9), u(18))
        self:hit(cx, by, u(44), step, c[2])
    end
end

-- Ink written in the strip: into the page image where it lands, and on the
-- screen in the strip, large.
function Editor:stampZoom(width, x0, y0, x1, y1, color, sx0, sy0, sx1, sy1)
    local __, z = self:zoomGeometry()
    self:stampInto({ self.page_bb }, width, x0, y0, x1, y1, color)
    local w = math.max(1, math.floor(width * z + 0.5))
    Ink.segment(sx0, sy0, sx1, sy1, w, self:stamper({ Screen.bb }, Blitbuffer.COLOR_BLACK))
    self:markInk(sx0, sy0, sx1, sy1, w)
end

-- ------------------------------------------------------------------ puzzle books: the zoom, Done, hidden pages

-- The zoom of a puzzle book: the part of the page in nb.zbox (picked once
-- with the pen, kept for the book) as large as it fits beside the toolbar,
-- on every page. Ink stays in page pixels: a point p of the page shows at
-- vx + p * z. Ink written while zoomed lands small on the page.
function Editor:setView()
    local box = self.notebook.zbox
    if not box then
        self.view = nil
        return
    end
    local r = self.pageRect
    local pad = self.ui:u(6)
    local top = self.ui:u(44)   -- the zoom's buttons above it
    local z = math.max(1, math.min((r[3] - 2 * pad) / box[3], (r[4] - top - pad) / box[4]))
    self.view = { z = z,
        vx = math.floor(r[1] + (r[3] - box[3] * z) / 2 - box[1] * z + 0.5),
        vy = math.floor(r[2] + top - box[2] * z + 0.5) }
    self.viewCache = setmetatable({}, { __mode = "k" })
end

-- A point on the screen as a point of the page (zoomed).
function Editor:toPage(x, y)
    local v = self.view
    return math.floor((x - v.vx) / v.z + 0.5), math.floor((y - v.vy) / v.z + 0.5)
end

-- An area of the page ({ x, y, w, h }) where the zoomed view shows it.
function Editor:viewArea(area)
    local v = self.view
    local x0, y0 = math.floor(v.vx + area[1] * v.z), math.floor(v.vy + area[2] * v.z)
    return { x0, y0, math.ceil(v.vx + (area[1] + area[3]) * v.z) - x0, math.ceil(v.vy + (area[2] + area[4]) * v.z) - y0 }
end

-- The PDF page zoomed, drawn sharp once per page and zoom.
function Editor:viewBackground()
    local nb, v = self.notebook, self.view
    local page = nb.pages[self.page]
    if not (page and page.bg) or not self:pdf() then return nil end
    local key = page.bg .. ":" .. v.z .. ":" .. v.vx .. ":" .. v.vy .. ":" .. self.w .. "x" .. self.h
    if self.viewKey == key then return self.viewBB end
    self:freeView()
    self.viewBB = self.pdfDoc:renderZoomed(page.bg, self.w, self.h, v.z, v.vx, v.vy)
    self.viewKey = key
    return self.viewBB
end

function Editor:freeView()
    if self.viewBB then self.viewBB:free() end
    self.viewBB, self.viewKey = nil, nil
end

-- The zoomed view into the page image: all of it, or the screen `area`.
function Editor:renderView(area)
    if self.spread then return self:renderSpread(area) end
    local bb, v = self.page_bb, self.view
    local ax, ay, aw, ah = 0, 0, self.w, self.h
    if area then ax, ay, aw, ah = area[1], area[2], area[3], area[4] end
    local bg = self:viewBackground()
    if bg then bb:blitFrom(bg, ax, ay, ax, ay, aw, ah) else bb:paintRect(ax, ay, aw, ah, Blitbuffer.COLOR_WHITE) end
    local shown = {}
    for __, stroke in ipairs(self:strokes()) do
        local t = self.viewCache[stroke]
        if not t then
            t = Ink.transform(stroke, 0, 0, v.z, v.vx, v.vy)
            self.viewCache[stroke] = t
        end
        table.insert(shown, t)
    end
    self:drawStrokes(bb, shown, area)
end

-- Zoom on or off. The first time, the part to zoom is picked first.
function Editor:toggleZoomView()
    self.panel = nil
    if self.view or self.picking then
        self.view, self.picking = nil, nil
        self:freeView()
    else
        -- Zoomed, the pen only writes and erases: back from the lasso to the pen.
        if self.tool == "lasso" then
            self:commitSelection()
            self.tool = "pen"
        end
        if not self.notebook.zbox then return self:startPick() end
        self:setView()
    end
    self:renderPage()
    UIManager:setDirty(self, "full")
end

-- The pen drags a box around what the zoom shows (on the whole page).
function Editor:startPick()
    self.panel = nil
    self.view = nil
    self:freeView()
    self.picking = true
    self:renderPage()
    UIManager:setDirty(self, "full")
end

-- The box being dragged, on the screen only.
function Editor:previewPick()
    local p = self.picking
    local old = self.pickArea
    if old then
        local r = self:clip(old)
        if r then Screen.bb:blitFrom(self.page_bb, r[1], r[2], r[1], r[2], r[3], r[4]) end
    end
    local x, y = math.min(p.x0, p.x1), math.min(p.y0, p.y1)
    local w, h = math.abs(p.x1 - p.x0), math.abs(p.y1 - p.y0)
    self.ui:dashed(Screen.bb, x, y, math.max(1, w), math.max(1, h))
    local area = { x - 4, y - 4, w + 8, h + 8 }
    self.pickArea = area
    local both = Ink.union(old, area)
    self:markInk(both[1], both[2], both[1] + both[3], both[2] + both[4], 2)
end

function Editor:endPick()
    local p = self.picking
    self.pickArea = nil
    self:flushInk()
    local x, y = math.min(p.x0, p.x1), math.min(p.y0, p.y1)
    local w, h = math.abs(p.x1 - p.x0), math.abs(p.y1 - p.y0)
    if w < self.ui:u(60) or h < self.ui:u(60) then
        -- Too small to be meant: try again.
        self.picking = true
        KO.toast(_("Drag a bigger box around the grid."))
        return self:repaint()
    end
    self.picking = nil
    self.notebook.zbox = { x, y, w, h }
    self:changed()
    self:setView()
    self:renderPage()
    UIManager:setDirty(self, "full")
end

-- At the top while zoomed or picking: what is going on, and a button.
function Editor:paintViewBar(bb)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    local r = self.pageRect
    local label, button, fn
    if self.picking then
        label, button = _("Drag a box around the grid with the pen"), _("Cancel")
        fn = function() self:toggleZoomView() end
    else
        label, button = T(_("Zoom %1×"), string.format("%.1f", self.view.z)), _("Change area")
        fn = function() self:startPick() end
    end
    local h, gap = u(28), u(8)
    local bw = ui:textWidth(button, 10, true) + u(24)
    local lw = ui:textWidth(label, 10, false) + u(24)
    local bx = r[1] + r[3] - u(8) - bw
    local lx = bx - gap - lw
    local y = u(8)
    ui:box(bb, lx, y, lw, h, { fill = UI.WHITE, border = UI.BLACK, r = u(6), bw = math.max(2, u(1)) })
    ui:drawText(bb, label, lx + math.floor(lw / 2), y + math.floor(h / 2), 10, { align = "center" })
    ui:box(bb, bx, y, bw, h, { fill = UI.BLACK, r = u(6) })
    ui:drawText(bb, button, bx + math.floor(bw / 2), y + math.floor(h / 2), 10, { align = "center", bold = true, color = UI.WHITE })
    self:hit(bx - u(4), 0, bw + u(8), h + u(16), fn)
    self:hit(lx, 0, lw, h + u(16), function() end)
end

-- Written while zoomed: the stroke kept in page pixels, drawn on the screen
-- as large as it was written.
function Editor:viewPenDown(x, y, tool, width)
    local v = self.view
    local px, py = self:toPage(x, y)
    if tool == "eraser" then
        self.erasing = { removed = {}, changes = {}, before = self:snapshot(), x = px, y = py }
        self:eraseAlong(px, py, px, py)
        return
    end
    local w = math.max(1, math.floor(width / v.z + 0.5))
    if tool == "hl" then
        self.stroke = { t = "hl", w = w, p = { px, py }, q = { w } }
    else
        self.stroke = { t = self.tip ~= "pen" and self.tip or nil, c = self:shadeGrey(self.tip), w = w, p = { px, py }, q = { w } }
    end
    self.viewStroke = { x = x, y = y }
    if Ink.tipOf(self.stroke).under then return self:previewHighlight(x, y, x, y, width) end
    self:stampLive(width, x, y, x, y, colorOf(self.stroke))
    self:markInk(x, y, x, y, width)
end

function Editor:viewPenMove(x, y, width)
    local stroke, vs, v = self.stroke, self.viewStroke, self.view
    if not stroke then return end
    local px, py = self:toPage(x, y)
    local p = stroke.p
    if p[#p - 1] == px and p[#p] == py then return end
    if Ink.tipOf(stroke).nib then width = Ink.nibWidth(width, x - vs.x, y - vs.y) end
    local w = math.max(1, math.floor(width / v.z + 0.5))
    table.insert(p, px)
    table.insert(p, py)
    table.insert(stroke.q, w)
    if w > stroke.w then stroke.w = w end
    if Ink.tipOf(stroke).under then
        self:previewHighlight(vs.x, vs.y, x, y, width)
    else
        self:stampLive(width, vs.x, vs.y, x, y, colorOf(stroke))
        self:markInk(vs.x, vs.y, x, y, width)
    end
    vs.x, vs.y = x, y
end

function Editor:endViewStroke()
    local stroke = self.stroke
    self.stroke, self.viewStroke = nil, nil
    self:flushInk()
    if not stroke then return end
    local bx, by, bw, bh = Ink.box(stroke)
    local level = Settings.get("smooth") or 0
    if level > 0 and not Ink.tipOf(stroke).under and #stroke.p > 8 then
        stroke = Shapes.smooth(stroke, level == 1 and 2 or 4)
    end
    table.insert(self:strokes(), stroke)
    -- Drawn again from what was kept, so the clean refresh shows it as saved.
    local area = self:renderArea({ bx, by, bw, bh })
    if area then self:cleanLater(self:padded(area)) end
    self:pushUndo({ add = stroke })
    self:changed()
end

-- ------------------------------------------------------------------ two pages side by side

-- A portrait notebook with the Kindle on its side: two pages at a time,
-- like an open notebook (1–2, 3–4, …). The pen, highlighter and eraser work
-- on either page, through a view of it (as zoomed, but smaller); the other
-- tools are for one page at a time (⋯ > Two pages side by side: Off).

-- The size of the notebook's pages (portrait).
function Editor:pageSize()
    local nb = self.notebook
    local w, h = nb.width or 0, nb.height or 0
    if w <= 0 or h <= 0 then w, h = math.min(self.w, self.h), math.max(self.w, self.h) end
    return w, h
end

-- Where the two pages go on the screen, and how small.
function Editor:spreadLayout()
    local s, r = self.spread, self.pageRect
    local pw, ph = self:pageSize()
    local gap = self.ui:u(10)
    local z = math.min((r[3] - 3 * gap) / 2 / pw, (r[4] - 2 * gap) / ph)
    local sw, sh = math.floor(pw * z), math.floor(ph * z)
    local x0 = r[1] + math.floor((r[3] - 2 * sw - gap) / 2)
    local y0 = r[2] + math.floor((r[4] - sh) / 2)
    s.z = z
    s.first = self.page - (self.page - 1) % 2
    s.slots = {}
    for k = 1, 2 do s.slots[k] = { page = s.first + k - 1, x = x0 + (k - 1) * (sw + gap), y = y0, w = sw, h = sh } end
    s.cache = s.cache or setmetatable({}, { __mode = "k" })
    self:useSlot(self.page == s.first and 1 or 2)
end

-- The page (1 or 2) at (x, y) on the screen, when there is a page there.
function Editor:spreadSlotAt(x, y)
    for k, slot in ipairs(self.spread.slots) do
        if x >= slot.x and x < slot.x + slot.w and y >= slot.y and y < slot.y + slot.h
                and self.notebook.pages[slot.page] then
            return k
        end
    end
end

-- Writing on page `k` of the two: it is the page, seen through its view.
function Editor:useSlot(k)
    local s = self.spread
    local slot = s.slots[k]
    if not self.notebook.pages[slot.page] then slot = s.slots[1] end
    self.page = slot.page
    self.view = { z = s.z, vx = slot.x, vy = slot.y }
end

-- A page's paper, pictures and text boxes, small (its ink is drawn over it).
function Editor:slotBackground(slot)
    local s, nb = self.spread, self.notebook
    local page = nb.pages[slot.page]
    local parts = { page.id, page.paper or nb.paper, Settings.get("paper_lines") or "", page.bg or 0, slot.w }
    for __, it in ipairs(page.items or {}) do table.insert(parts, tostring(it)) end
    local key = table.concat(parts, ":")
    s.bgs = s.bgs or {}
    local kept = s.bgs[slot.page % 2]
    if kept and kept.key == key then return kept.bb end
    if kept then kept.bb:free() end
    local pw, ph = self:pageSize()
    local r = setmetatable({ notebook = nb, page = slot.page, w = pw, h = ph, scale = self.scale,
        pageRect = { 0, 0, pw, ph }, ui = self.ui, pdfDoc = self.pdfDoc, store = self.store }, { __index = Editor })
    local bb = Blitbuffer.new(pw, ph, Blitbuffer.TYPE_BB8)
    r:paintPaper(bb)
    for __, layer in ipairs({ "under", "text", "over" }) do Items.draw(bb, page.items or {}, layer, nil, nil, self:imageDir()) end
    local small = UI.scale(bb, slot.w, slot.h)
    bb:free()
    if r.bgBB then r.bgBB:free() end
    if r.tplBB then r.tplBB:free() end
    if r.pdfDoc and not self.pdfDoc then self.pdfDoc = r.pdfDoc end
    s.bgs[slot.page % 2] = { key = key, bb = small }
    return small
end

-- The two pages drawn (all of the screen, or the area `area`).
function Editor:renderSpread(area)
    local s, bb = self.spread, self.page_bb
    if self.page < s.first or self.page > s.first + 1 then self:spreadLayout() end
    self:useSlot(self.page == s.first and 1 or 2)
    area = area or { 0, 0, self.w, self.h }
    bb:paintRect(area[1], area[2], area[3], area[4], Blitbuffer.Color8(0xEE))
    for __, slot in ipairs(s.slots) do
        local box = Ink.clip({ slot.x - 2, slot.y - 2, slot.w + 4, slot.h + 4 }, area[1] + area[3], area[2] + area[4], area[2], area[1])
        local page = self.notebook.pages[slot.page]
        if box then
            bb:paintRect(box[1], box[2], box[3], box[4], UI.MID)
            local a = Ink.clip(box, slot.x + slot.w, slot.y + slot.h, slot.y, slot.x)
            if a and page then
                bb:blitFrom(self:slotBackground(slot), a[1], a[2], a[1] - slot.x, a[2] - slot.y, a[3], a[4])
                local shown = {}
                for __, stroke in ipairs(page.strokes) do
                    local t = s.cache[stroke]
                    if not t then
                        t = Ink.transform(stroke, 0, 0, s.z, slot.x, slot.y)
                        s.cache[stroke] = t
                    end
                    table.insert(shown, t)
                end
                self:drawStrokes(bb, shown, a)
            elseif a then
                -- No page here yet (an odd number): + adds one.
                bb:paintRect(a[1], a[2], a[3], a[4], Blitbuffer.Color8(0xF6))
            end
        end
    end
end

function Editor:freeSpread()
    for __, kept in pairs(self.spread and self.spread.bgs or {}) do kept.bb:free() end
    if self.spread then self.spread.bgs = nil end
end

-- The page that times a puzzle book's page: a crossword's first page (the
-- one upright), else the page itself.
function Editor:puzzleFirst(i)
    local nb = self.notebook
    local page = nb.pages[i or self.page]
    local key = Crossword.keyPart(page)
    if key then
        local __, first = Crossword.pageOf(nb, key, "1")
        return first or page, key
    end
    return page
end

-- The pen at work in a puzzle book: the time since the last change (up to
-- a few minutes) added to the puzzle's time, until it is done.
function Editor:puzzleActivity()
    if not self.notebook.puzzle or Settings.get("crossword_timer") == false then return end
    local first = self:puzzleFirst()
    if not first or first.done then
        self.timing = nil
        return
    end
    local now = os.time()
    local t = self.timing
    if t and t.page == first and now > t.at then
        first.secs = (first.secs or 0) + math.min(now - t.at, Crossword.TIMER_GAP)
    end
    self.timing = { page = first, at = now }
end

function Editor:toggleDone(i)
    local nb = self.notebook
    local page = nb.pages[i or self.page]
    local on = not page.done
    if on and (i or self.page) == self.page then self:puzzleActivity() end
    local key = Crossword.keyPart(page)
    if nb.feed and key then
        -- A crossword: all its pages (upright and on its side).
        Crossword.setDone(nb, key, on, os.time())
    else
        page.done = on or nil
        page.doneat = on and os.time() or nil
    end
    self.timing = nil
    self:changed()
    self:refreshToolbar()
end

-- A hidden page (a cover, the solutions) is passed over by the page
-- buttons and left out of the puzzle list's counts. A crossword's page
-- laid out for the other orientation goes with it.
function Editor:toggleHidden(i)
    local nb = self.notebook
    i = i or self.page
    local page = nb.pages[i]
    page.hide = not page.hide or nil
    local other = nb.feed and Crossword.counterpart(nb, i)
    if other then
        local __, a = Crossword.keyPart(page)
        local __, b = Crossword.keyPart(nb.pages[other])
        if a and b and (a == "L" .. b or b == "L" .. a) then nb.pages[other].hide = page.hide end
    end
    self:changed()
    self:repaint()
end

--- The toolbar's page number, "3/12". Puzzle books count the pages the
-- arrows go to (not the hidden ones, nor a crossword's pages for the other
-- orientation), and the page shown even when it is one of those.
function Editor:pageCounter()
    if not self.notebook.puzzle then return T("%1/%2", self.page, #self.notebook.pages) end
    local at, n = 0, 0
    for k in ipairs(self.notebook.pages) do
        if k == self.page or not self:passedOver(k) then
            n = n + 1
            if k <= self.page then at = n end
        end
    end
    return T("%1/%2", math.max(1, at), n)
end

-- Whether page i is passed over: a puzzle book's hidden pages, and a
-- crossword's pages laid out for the other orientation.
function Editor:passedOver(i)
    local page = self.notebook.pages[i]
    if not page or not self.notebook.puzzle then return false end
    return page.hide or (self.notebook.feed and not Crossword.inView(page, self.w > self.h)) or false
end

-- The next page that way (-1 or 1), or nil; a puzzle book's hidden pages
-- are passed over.
function Editor:nextPage(dir)
    local pages = self.notebook.pages
    if self.spread then
        local i = self.spread.first + 2 * dir
        return pages[i] and i or nil
    end
    local i = self.page + dir
    while pages[i] and self:passedOver(i) do i = i + dir end
    return pages[i] and i or nil
end

-- ------------------------------------------------------------------ pages: overview, bookmarks, copies

function Editor:showOverview()
    self:commitSelection()
    self.panel = nil
    UIManager:show(require("notesoverview"):new{ editor = self }, "full")
end

-- Page i small, `w` x `h`, kept until the page changes.
function Editor:thumbnail(i, w, h)
    local page = self.notebook.pages[i]
    if not page then return nil end
    self.thumbs = self.thumbs or {}
    self.revs = self.revs or {}
    local key = (self.revs[page.id] or 0) .. ":" .. w .. "x" .. h .. ":" .. (page.bg or 0) .. ":" .. (page.paper or self.notebook.paper) .. ":" .. (Settings.get("paper_lines") or "")
    local t = self.thumbs[page.id]
    if t and t.key == key then return t.bb end
    if t then t.bb:free() end
    if page.bg and #page.strokes == 0 and not page.items and self:pdf() then
        -- A PDF page with no writing: drawn small straight away (quicker).
        local bb = self.pdfDoc:render(page.bg, w, h)
        if bb then
            self.thumbs[page.id] = { key = key, bb = bb }
            return bb
        end
    end
    -- (Two pages side by side: the page as it is, not the screen.)
    local pw, ph = self.w, self.h
    if self.spread then pw, ph = self:pageSize() end
    local r = setmetatable({ notebook = self.notebook, page = i, w = pw, h = ph, scale = self.scale,
        pageRect = { 0, 0, pw, ph }, ui = self.ui, pdfDoc = self.pdfDoc, store = self.store,
        tplBB = not self.spread and self:templateBB() or nil, tplKey = not self.spread and self.tplKey or nil }, { __index = Editor })
    r.page_bb = Blitbuffer.new(pw, ph, Blitbuffer.TYPE_BB8)
    r:renderPage()
    local bb = UI.scale(r.page_bb, w, h)
    r.page_bb:free()
    if r.bgBB then r.bgBB:free() end
    self.thumbs[page.id] = { key = key, bb = bb }
    return bb
end

function Editor:freeThumbs()
    for __, t in pairs(self.thumbs or {}) do t.bb:free() end
    self.thumbs = {}
end

function Editor:pagesChanged(sameShown)
    self.undo, self.redo = {}, {}
    if sameShown then
        -- Pages added, copied or moved: the page on screen is unchanged, so
        -- it (and its thumbnail) need not be drawn again.
        self.dirty = true
        self.changedSinceOpen = true
        if self.saveTask then UIManager:unschedule(self.saveTask) end
        self.saveTask = function() self:saveNow() end
        UIManager:scheduleIn(SAVE_AFTER, self.saveTask)
    else
        self:changed()
        self:renderPage()
    end
    UIManager:setDirty(self, "partial")
end

function Editor:toggleStar(i)
    local page = self.notebook.pages[i or self.page]
    page.star = not page.star or nil
    self:changed()
    self:refreshToolbar()
end

function Editor:addPageAt(n)
    table.insert(self.notebook.pages, n, { id = self.store.newPageId(), created = os.time(), strokes = {} })
    if n <= self.page then self.page = self.page + 1 end
    self:pagesChanged(true)
end

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end

function Editor:copyPage(i)
    local copy = deepCopy(self.notebook.pages[i])
    copy.id = self.store.newPageId()
    copy.created = os.time()
    copy.star = nil
    table.insert(self.notebook.pages, i + 1, copy)
    if i < self.page then self.page = self.page + 1 end
    self:pagesChanged(true)
end

function Editor:movePage(i, to)
    if i == to then return end
    local pages = self.notebook.pages
    local current = pages[self.page]
    local page = table.remove(pages, i)
    table.insert(pages, to, page)
    for k, p in ipairs(pages) do
        if p == current then self.page = k end
    end
    self:pagesChanged(true)
end

-- Page i deleted: kept in the notebook's deleted pages for 30 days (to
-- restore from the page list), unless `moved` (to another notebook).
function Editor:deletePageAt(i, moved)
    local pages = self.notebook.pages
    if #pages < 2 then return end
    local current = pages[self.page]
    local page = table.remove(pages, i)
    if page and not moved then
        self.notebook.deleted = self.notebook.deleted or {}
        table.insert(self.notebook.deleted, { at = os.time(), index = i, page = page })
    end
    self.page = 1
    for k, p in ipairs(pages) do
        if p == current then self.page = k end
    end
    self.page = math.min(self.page, #pages)
    self:pagesChanged()
end

--- A deleted page (k in the notebook's deleted pages) put back where it was.
function Editor:restoreDeleted(k)
    local nb = self.notebook
    local d = nb.deleted and table.remove(nb.deleted, k)
    if not d then return end
    if #nb.deleted == 0 then nb.deleted = nil end
    local at = math.max(1, math.min(d.index or 1, #nb.pages + 1))
    table.insert(nb.pages, at, d.page)
    if at <= self.page then self.page = self.page + 1 end
    self:pagesChanged(true)
    return at
end

--- A deleted page deleted for good (k), or all of them (k nil).
function Editor:purgeDeleted(k)
    local nb = self.notebook
    if not nb.deleted then return end
    if k then table.remove(nb.deleted, k) else nb.deleted = {} end
    if #nb.deleted == 0 then nb.deleted = nil end
    self:pagesChanged(true)
end

-- The lasso selection as an image, handed to `fn` (png, name).
function Editor:selectionTo(fn)
    if not self.sel or not fn then return end
    if self.notebook.puzzle then
        -- A puzzle book: that part of the page as it shows (the printed clue
        -- or grid with the writing), not the writing alone.
        local box = self:selectionBox()
        self:commitSelection()
        self:repaint()
        local png = self:pictureOf({ crop = box })
        if png then fn(png, self.notebook.name .. " selection") end
        return
    end
    local path = DataStorage:getDataDir() .. "/cache/notes-selection.png"
    require("util").makePath(DataStorage:getDataDir() .. "/cache")
    local ok = Editor.pagePNG(self.notebook, self.page, path, { strokes = self:selectionView(), long = 1568 })
    if not ok then return end
    local f = io.open(path, "rb")
    local png = f and f:read("*a")
    if f then f:close() end
    os.remove(path)
    if png then fn(png, self.notebook.name .. " selection") end
end

-- ------------------------------------------------------------------ drawing with Claude

-- The dashed area lassoed and its "Draw here" button.
function Editor:paintDrawAt(bb)
    local ui, a = self.ui, self.drawAt
    ui:dashed(bb, a[1], a[2], a[3], a[4])
    if self.notebook.puzzle then return self:paintAskAt(bb, a) end
    local w, h = ui:u(104), ui:u(28)
    local x = math.max(0, math.min(self.w - w, a[1] + math.floor((a[3] - w) / 2)))
    local y = math.max(0, math.min(self.h - h, a[2] + math.floor((a[4] - h) / 2)))
    ui:box(bb, x, y, w, h, { fill = UI.WHITE, border = UI.BLACK, r = ui:u(14) })
    ui:drawIcon(bb, "wand-sparkles", x + ui:u(9), y + ui:u(7), ui:u(14))
    ui:drawText(bb, _("Draw here"), x + ui:u(28), y + math.floor(h / 2), 10)
    local area = a
    self:hit(x, y, w, h, function() self:areaDraw(area) end)
end

-- In a puzzle book an area lassoed (a clue, part of the grid) can be asked
-- about: its "Ask" button.
function Editor:paintAskAt(bb, a)
    local ui = self.ui
    local h = ui:u(28)
    -- Ask (the AI), and for a crossword fetched Answer (the answer from the
    -- book) and Check (the AI reads the letters written there); without an
    -- AI service set up, only Answer.
    local ai = not Settings.noAI()
    local btns = {}
    if ai then table.insert(btns, { "sparkles", _("Ask"), function(__, area) self:areaAsk(area) end, keep = true, job = "ask" }) end
    if self.notebook.feed and self.on_answer then table.insert(btns, { "eye", _("Answer"), self.on_answer }) end
    -- (Reveal: the letters of the squares circled.)
    if self.notebook.feed and self.on_reveal then table.insert(btns, { "type", _("Reveal"), self.on_reveal }) end
    if ai and self.notebook.feed and self.on_check then table.insert(btns, { "spell-check", _("Check"), self.on_check, job = "cw_check" }) end
    if #btns == 0 then return end
    local total = -ui:u(8)
    for __, m in ipairs(btns) do
        m.w = ui:textWidth(m[2], 10) + ui:u(40)
        total = total + ui:u(8) + m.w
    end
    local x = math.max(0, math.min(self.w - total, a[1] + math.floor((a[3] - total) / 2)))
    -- Just below what was lassoed (above it near the bottom), not over it.
    local y = a[2] + a[4] + ui:u(6)
    if y + h > self.h then y = math.max(0, a[2] - h - ui:u(6)) end
    for __, m in ipairs(btns) do
        ui:box(bb, x, y, m.w, h, { fill = UI.WHITE, border = UI.BLACK, r = ui:u(14) })
        ui:drawIcon(bb, m[1], x + ui:u(9), y + ui:u(7), ui:u(14))
        ui:drawText(bb, m[2], x + ui:u(28), y + math.floor(h / 2), 10)
        local fn = m[3]
        if m.job then self:aiHold(x, y, m.w, h, m.job) end
        self:hit(x, y, m.w, h, function()
            -- (Ask keeps the area for its question; the others are done with it.)
            if not m.keep then
                self.drawAt = nil
                self:repaint()
            end
            fn(self, a)
        end)
        x = x + m.w + ui:u(8)
    end
end

--- A clue found by tapping its number: its squares and its clue outlined
-- ({ x, y, w, h } on the screen) until the next stroke or page.
function Editor:showOutline(boxes)
    local old = self.outline
    self.outline = { page = self.page, boxes = boxes }
    -- Only the outlines drawn again (the last ones and these), not the whole page.
    if old and old.page == self.page then self:repaintOutline(old) end
    self:repaintOutline(self.outline)
end

--- The outlines gone (from the screen too: only where they were).
function Editor:clearOutline()
    local old = self.outline
    if not old then return end
    self.outline = nil
    if old.page == self.page then self:repaintOutline(old) end
end

-- Where an outline's boxes are on the screen, drawn again.
function Editor:repaintOutline(o)
    local t = math.max(4, self.ui:u(2)) + 2
    for __, b in ipairs(o.boxes) do self:repaint({ b[1] - t, b[2] - t, b[3] + 2 * t, b[4] + 2 * t }) end
end

function Editor:paintOutline(bb)
    local o = self.outline
    if not o or o.page ~= self.page then return end
    local t = math.max(4, self.ui:u(2))
    for __, b in ipairs(o.boxes) do
        bb:paintBorder(b[1] - t, b[2] - t, b[3] + 2 * t, b[4] + 2 * t, t, UI.BLACK)
    end
end

--- Clues pinned over the page (a number in the grid tapped, or a hint from
-- the AI): `rows`, each a line of text or { text, id (a clue's tick box:
-- "8A"), bold }, until its X is tapped; the pen or a finger drags it, and
-- its tick boxes tick their clues. It goes above `near` (where it was asked
-- for) when there's room, else below. A new one takes the place of the last.
-- `copy`: text its Copy button puts on the clipboard (an AI hint's).
function Editor:pinClue(rows, near, copy)
    local old = self.clueCard
    local area = old and old.boxes and old.page == self.page and self:padded(self:clueCardRect(), self.ui:u(6))
    self:freeClueCard()
    local list = {}
    for __, r in ipairs(rows) do table.insert(list, type(r) == "table" and r or { text = r }) end
    self.clueCard = { page = self.page, rows = list, near = near, copy = copy,
        x = not near and old and old.x or nil, y = not near and old and old.y or nil }
    -- Only where the cards are: the one it takes the place of cleaned off the
    -- screen (as after a drag), the new one drawn. (Not the whole page: KOReader
    -- merges overlapping refreshes into the stronger one, which flashed it all.)
    if area then self:repaint(area, "full") end
    self:repaint(self:padded(self:clueCardRect(), self.ui:u(4)))
end

function Editor:freeClueCard()
    local c = self.clueCard
    for __, b in ipairs(c and c.boxes or {}) do b:free() end
    self.clueCard = nil
    if self.cardTask then UIManager:unschedule(self.cardTask) self.cardTask = nil end
    self.cardDrag = nil
end

-- The card on the screen ({ x, y, w, h }), kept on the page; its X ({ x, y,
-- w, h }); its rows' tick boxes ({ { x, y, size, id }... }); and its Copy
-- button ({ x, y, w, h }, with `copy` only). As wide as its words need (up
-- to most of the page).
function Editor:clueCardRect()
    local c, ui = self.clueCard, self.ui
    local r = self.pageRect
    local pad, s, gap, tick, between = ui:u(12), ui:u(20), ui:u(10), ui:u(18), ui:u(6)
    local ticks = false
    for __, row in ipairs(c.rows) do
        if row.id then ticks = true end
    end
    local lead = ticks and tick + gap or 0
    local extra = c.copy and (s + gap) or 0
    if not c.boxes then
        local maxText = math.floor(math.min(r[3] - ui:u(24), math.max(ui:u(360), r[3] * 0.7))) - 2 * pad - lead - gap - s - extra
        local natural = 0
        for __, row in ipairs(c.rows) do natural = math.max(natural, ui:textWidth(row.text, 11, row.bold) + ui:u(4)) end
        c.textW = math.max(ui:u(120), math.min(maxText, natural))
        c.boxes = {}
        local face = require("ui/font"):getFace("cfont", math.floor(11 * ui.fontScale + 0.5))
        for __, row in ipairs(c.rows) do
            table.insert(c.boxes, require("ui/widget/textboxwidget"):new{ text = row.text, face = face, bold = row.bold, width = c.textW })
        end
    end
    local w = 2 * pad + lead + c.textW + gap + s + extra
    local h = 2 * pad - between
    for __, b in ipairs(c.boxes) do h = h + b:getSize().h + between end
    if not c.x and c.near then
        local away = ui:u(30)
        c.x = c.near[1] - math.floor(w / 2)
        c.y = c.near[2] - away - h
        if c.y < r[2] then c.y = c.near[2] + away end
    end
    c.x = c.x or r[1] + math.floor((r[3] - w) / 2)
    c.y = c.y or r[2] + r[4] - h - ui:u(70)
    c.x = math.max(r[1], math.min(r[1] + r[3] - w, c.x))
    c.y = math.max(r[2], math.min(r[2] + r[4] - h, c.y))
    local boxes, ry = {}, c.y + pad
    for i, row in ipairs(c.rows) do
        if row.id then table.insert(boxes, { c.x + pad, ry + math.max(0, math.floor((ui:u(16) - tick) / 2)), tick, row.id, i }) end
        ry = ry + c.boxes[i]:getSize().h + between
    end
    local close = { c.x + w - s - 2 * pad, c.y, s + 2 * pad, s + 2 * pad }
    -- (Copy's icon a gap after the text, a gap before the X's.)
    local copyAt = c.copy and { close[1] + pad - s - gap, c.y, s + gap, s + 2 * pad } or nil
    return { c.x, c.y, w, h }, close, boxes, copyAt
end

-- The card's text copied (its Copy button).
function Editor:copyClueCard()
    local c = self.clueCard
    if not (c and c.copy) then return end
    if Device.input.setClipboardText then Device.input.setClipboardText(c.copy) end
    KO.toast(_("Copied"))
end

function Editor:paintClueCard(bb)
    local c = self.clueCard
    if not c or c.page ~= self.page then return end
    local ui = self.ui
    local rect, close, boxes, copyAt = self:clueCardRect()
    local x, y, w, h = rect[1], rect[2], rect[3], rect[4]
    local pad, gap, between = ui:u(12), ui:u(10), ui:u(6)
    ui:box(bb, x, y, w, h, { fill = UI.WHITE, border = UI.BLACK, bw = math.max(2, ui:u(2)), r = ui:u(8) })
    local lead = #boxes > 0 and ui:u(18) + gap or 0
    local ry = y + pad
    for __, b in ipairs(c.boxes) do
        b:paintTo(bb, x + pad + lead, ry)
        ry = ry + b:getSize().h + between
    end
    -- A clue's tick box, ticked as in the list.
    local ticked = self:clueTicks()
    for __, t in ipairs(boxes) do
        bb:paintBorder(t[1], t[2], t[3], t[3], math.max(2, ui:u(1.2)), UI.BLACK)
        if ticked[t[4]] then ui:drawIcon(bb, "check", t[1] - ui:u(2), t[2] - ui:u(2), t[3] + ui:u(4)) end
    end
    ui:drawIcon(bb, "x", close[1] + pad, close[2] + pad, close[3] - 2 * pad)
    if copyAt then ui:drawIcon(bb, "copy", copyAt[1], copyAt[2] + pad, close[3] - 2 * pad) end
    -- Taps on it do nothing (the page under it is left alone), but on its X
    -- and its tick boxes.
    self:hit(x, y, w, h, nil)
    self:hit(close[1], close[2], close[3], close[4], function()
        -- (only where it was, cleaned as after a drag: not the whole page)
        local area = self:padded(rect, self.ui:u(6))
        self:freeClueCard()
        self:repaint(area, "full")
    end)
    if copyAt then self:hit(copyAt[1], copyAt[2], copyAt[3], copyAt[4], function() self:copyClueCard() end) end
    for __, t in ipairs(boxes) do
        local m = ui:u(8)
        self:hit(t[1] - m, t[2] - m, t[3] + 2 * m, t[3] + 2 * m, function() self:tickOnCard(t[4]) end)
    end
end

-- A clue ticked (or unticked) from the card: in the list too, when it's on this page.
function Editor:tickFromCard(id)
    local done = false
    for __, b in ipairs(self:clueBoxes()) do
        if b[4] == id then
            self:tickClue(b)
            done = true
        end
    end
    if not done then
        local first = self:puzzleFirst()
        if not first then return end
        first.ticks = first.ticks or {}
        first.ticks[id] = not first.ticks[id] or nil
        if not next(first.ticks) then first.ticks = nil end
        self:changed()
        if self.countRect then self:repaint(self.countRect) end
    end
    if self.clueCard then self:repaint(self:padded(self:clueCardRect(), self.ui:u(4))) end
end

-- A tick box on the card tapped: the clue ticked (or not). Once every clue on
-- it is ticked, the card goes, with Undo (the apps' undo bar) to untick the
-- last one and bring the card back.
function Editor:tickOnCard(id)
    local card = self.clueCard
    self:tickFromCard(id)
    local ticks = self:clueTicks()
    if not (card and ticks[id]) then return end
    for __, r in ipairs(card.rows) do
        if r.id and not ticks[r.id] then return end
    end
    local rows, near, copy, x, y = card.rows, card.near, card.copy, card.x, card.y
    local area = self:padded(self:clueCardRect(), self.ui:u(6))
    self:freeClueCard()
    self:repaint(area, "full")
    -- (how long Undo shows: Crossword settings > Undo after a tick; 0 is none)
    local secs = tonumber(Settings.get("crossword_undo")) or 3
    local PS = require("pluginshare")
    local okp, bar = pcall(function() return PS.popup and PS.popup.undo end)
    if okp and bar and secs > 0 then
        bar(_("Clue ticked"), function()
            self:tickFromCard(id)
            self:pinClue(rows, near, copy)
            if self.clueCard and not near then self.clueCard.x, self.clueCard.y = x, y end
            self:repaint()
        end, secs)
    end
end

-- A tap on the card (pen or finger): its tick boxes. True when it was on the card.
function Editor:clueCardTap(x, y)
    local c = self.clueCard
    if not c or c.page ~= self.page or not c.boxes then return false end
    local rect, close, boxes, copyAt = self:clueCardRect()
    local m = self.ui:u(8)
    if copyAt and x >= copyAt[1] and x < copyAt[1] + copyAt[3] and y >= copyAt[2] and y < copyAt[2] + copyAt[4] then
        self:copyClueCard()
        return true
    end
    for __, t in ipairs(boxes) do
        if x >= t[1] - m and x < t[1] + t[3] + m and y >= t[2] - m and y < t[2] + t[3] + m then
            self:tickOnCard(t[4])
            return true
        end
    end
    return x >= rect[1] and x < rect[1] + rect[3] and y >= rect[2] and y < rect[2] + rect[4]
end

-- Whether (x, y) is on the pinned clues (not their X): dragged from there.
function Editor:onClueCard(x, y)
    local c = self.clueCard
    if not c or c.page ~= self.page or not c.boxes or self.panel then return false end
    local r, close, __, copyAt = self:clueCardRect()
    local function inside(b) return x >= b[1] and x < b[1] + b[3] and y >= b[2] and y < b[2] + b[4] end
    return inside(r) and not inside(close) and not (copyAt and inside(copyAt))
end

function Editor:grabClueCard(x, y)
    local c = self.clueCard
    self.cardDrag = { dx = x - c.x, dy = y - c.y, area = self:clueCardRect(), x0 = x, y0 = y }
end

-- Dragged: it follows (the screen catches up a few times a second).
function Editor:dragClueCard(x, y)
    local c, d = self.clueCard, self.cardDrag
    if not c then return end
    local slop = self.ui:u(8)
    if not d.moved and math.abs(x - d.x0) <= slop and math.abs(y - d.y0) <= slop then return end
    d.moved = true
    c.x, c.y = x - d.dx, y - d.dy
    -- (Everywhere it went, to clean up after.)
    d.area = Ink.union(d.area, self:clueCardRect())
    if self.cardTask then return end
    self.cardTask = function()
        self.cardTask = nil
        self:repaint(nil, "a2")
    end
    UIManager:scheduleIn(0.15, self.cardTask)
end

function Editor:dropClueCard()
    local d = self.cardDrag
    if not d then return end
    self.cardDrag = nil
    if self.cardTask then UIManager:unschedule(self.cardTask) self.cardTask = nil end
    -- Not moved: a tap (its tick boxes).
    if not d.moved then return self:clueCardTap(d.x0, d.y0) end
    -- The fast drawing while dragging leaves ghosts: where it went, cleaned.
    self:repaint(self:padded(d.area, self.ui:u(8)), "full")
end

--- Check my answers' result: a dot in each square that looks wrong
-- ({ x, y, size } on the screen) and a line saying how many, over the page
-- until it changes or Clear dots.
function Editor:showCheck(marks, summary)
    self.check = { page = self.page, marks = marks, summary = summary }
    self:repaint()
end

function Editor:paintCheck(bb)
    local c = self.check
    if not c or c.page ~= self.page then
        self.check = nil
        return
    end
    local ui = self.ui
    for __, m in ipairs(c.marks) do
        local r = math.max(ui:u(4), math.floor(m[3] * 0.09))
        bb:paintCircle(math.floor(m[1] + m[3] - r * 2), math.floor(m[2] + m[3] - r * 2), r, UI.BLACK)
    end
    local clear = _("Clear dots")
    local tw = ui:textWidth(c.summary, 10, true)
    local cw = ui:textWidth(clear, 10, true)
    local w = tw + cw + ui:u(56)
    local h = ui:u(30)
    local r = self.pageRect
    local x = r[1] + math.floor((r[3] - w) / 2)
    local y = self.h - h - ui:u(12)
    ui:box(bb, x, y, w, h, { fill = UI.BLACK, border = UI.BLACK, r = ui:u(15) })
    ui:drawIcon(bb, "spell-check", x + ui:u(10), y + ui:u(7), ui:u(16), true)
    ui:drawText(bb, c.summary, x + ui:u(32), y + math.floor(h / 2), 10, { bold = true, color = UI.WHITE })
    ui:drawText(bb, clear, x + w - ui:u(12) - cw, y + math.floor(h / 2), 10, { bold = true, color = UI.WHITE })
    self:hit(x, y, w, h, function()
        self.check = nil
        self:repaint()
    end)
end

--- Typed text boxes put on the page at once (a crossword's answers shown
-- in their squares), undoable as one.
function Editor:addTypedItems(items)
    if #items == 0 then return end
    local before = self:snapshot()
    for __, it in ipairs(items) do table.insert(self:pageItems(), it) end
    self:pushSnapshot(before)
    self:renderPage()
    self:repaint()
end

-- That part of the page (print and writing) to the AI, with your question.
function Editor:areaAsk(area)
    self.drawAt = nil
    self:repaint()
    if not self.on_ask_png then return end
    local png = self:pictureOf({ crop = area })
    if png then self.on_ask_png(png, self.notebook.name .. " selection") end
end

-- A picture of part of the page for Claude: `opts` as for pagePNG; returns
-- png and the area it shows.
function Editor:pictureOf(opts)
    local path = DataStorage:getDataDir() .. "/cache/notes-draw.png"
    require("util").makePath(DataStorage:getDataDir() .. "/cache")
    opts.cropOut = {}
    opts.long = 1568
    local ok = Editor.pagePNG(self.notebook, self.page, path, opts)
    if not ok or not opts.cropOut[1] then return nil end
    local f = io.open(path, "rb")
    local png = f and f:read("*a")
    if f then f:close() end
    os.remove(path)
    return png, opts.cropOut
end

-- The lasso's Draw: Claude redraws the selection, or draws beside it.
function Editor:selectionDraw()
    if not self.sel or not self.on_draw then return end
    local sel = self.sel
    local png, area = self:pictureOf({ strokes = self:selectionView(), items = self:selectionItems() })
    if not png then return end
    self.on_draw({ png = png, w = area[3], h = area[4], empty = false }, function(svg, mode)
        return self:applyDrawing(svg, mode, area, sel)
    end)
end

-- Draw here: Claude draws in an empty area lassoed.
function Editor:areaDraw(area)
    self.drawAt = nil
    self:repaint()
    local png, crop = self:pictureOf({ crop = area })
    if not png then return end
    self.on_draw({ png = png, w = crop[3], h = crop[4], empty = true }, function(svg)
        return self:applyDrawing(svg, "draw", crop)
    end)
end

-- Claude's drawing (SVG) onto the page as ink and text boxes: in place of
-- the selection ("replace"), beside it ("beside"), or in an area ("draw").
-- One undo takes it back. Returns true or nil and why.
function Editor:applyDrawing(svg, mode, area, sel)
    local drawing, why = require("notessvg").parse(svg)
    if not drawing then return nil, why end
    if self.sel then self:commitSelection() end
    local box = { area[1], area[2], area[3], area[4] }
    local r = self.pageRect
    if mode == "beside" then
        local gap = self.ui:u(10)
        if area[1] + 2 * area[3] + gap <= r[1] + r[3] then
            box[1] = area[1] + area[3] + gap
        elseif area[2] + 2 * area[4] + gap <= r[2] + r[4] then
            box[2] = area[2] + area[4] + gap
        else
            box[1] = math.max(r[1], r[1] + r[3] - area[3])
        end
    end
    local width = Ink.tipWidth(self.tip, self.sizes[self.tip] or 2, nil, self.scale)
    local strokes, texts = require("notessvg").place(drawing, box, math.max(2, math.floor(width * 0.6)), nil)
    for __, t in ipairs(texts) do
        t.w = math.min(t.w, r[1] + r[3] - t.x)
    end
    local before = self:snapshot()
    local pageStrokes, items = self:strokes(), self:pageItems()
    if mode == "replace" and sel then
        for i = #pageStrokes, 1, -1 do
            if sel.set[pageStrokes[i]] then table.remove(pageStrokes, i) end
        end
        for i = #items, 1, -1 do
            if sel.itemSet[items[i]] then table.remove(items, i) end
        end
    end
    local first = #pageStrokes + 1
    for __, st in ipairs(strokes) do table.insert(pageStrokes, st) end
    for __, t in ipairs(texts) do table.insert(items, t) end
    self:pushSnapshot(before)
    local indexes = {}
    for i = first, #pageStrokes do table.insert(indexes, i) end
    self.tool = "lasso"
    self:select(indexes, texts)
    return true
end

-- The page, or a lasso selection, read by Claude for To Do tasks.
function Editor:selectionToTodo()
    if not self.sel or not self.on_todo_png then return end
    local strokes = self:selectionView()
    local path = DataStorage:getDataDir() .. "/cache/notes-selection.png"
    require("util").makePath(DataStorage:getDataDir() .. "/cache")
    local ok = Editor.pagePNG(self.notebook, self.page, path, { strokes = strokes, long = 1568 })
    if not ok then return end
    local f = io.open(path, "rb")
    local png = f and f:read("*a")
    if f then f:close() end
    os.remove(path)
    if png then self.on_todo_png(png) end
end

-- The five sizes of a tip as dots as wide as the ink.
function Editor:paintSizes(bb, x, cy, tip, changed)
    local ui = self.ui
    for i = 1, 5 do
        local cx = x + ui:u(28) + (i - 1) * ui:u(45)
        local r = math.max(ui:u(1), math.min(ui:u(7), math.floor(Ink.tipWidth(tip, i, nil, self.scale) * 0.7)))
        if (self.sizes[tip] or 2) == i then bb:paintCircle(cx, cy, ui:u(10), UI.BLACK, math.max(2, ui:u(1.2))) end
        bb:paintCircle(cx, cy, r, Blitbuffer.Color8(Ink.TIPS[tip].grey))
        self:hit(cx - ui:u(22), cy - ui:u(17), ui:u(44), ui:u(34), function()
            self.sizes[tip] = i
            Settings.set("sizes", self.sizes)
            changed()
        end)
    end
end

-- A sample stroke with the tip, pressing lightly to hard and back.
function Editor:paintPreview(bb, x, y, w, h, tip)
    local size = self.sizes[tip] or 2
    local color = Blitbuffer.Color8(Ink.TIPS[tip].grey)
    local steps = 60
    local lx, ly
    for i = 0, steps do
        local t = i / steps
        local px = x + math.floor(w * t)
        local py = y + math.floor(h / 2 + math.sin(t * math.pi * 5) * h * 0.32)
        local f = 0.25 + 0.75 * math.abs(math.sin(t * math.pi * 1.5))
        local width = Ink.tipWidth(tip, size, self.notebook.pressure ~= false and f or nil, self.scale)
        if lx then
            Ink.segment(lx, ly, px, py, width, function(sx, sy, s) bb:paintRect(sx, sy, s, s, color) end)
        end
        lx, ly = px, py
    end
end

-- The ⋯ menu's rows ({ icon, label, value, action }); a puzzle book's are fewer.
function Editor:moreRows()
    local nb = self.notebook
    local rows
    local linked = not nb.puzzle and self.linked_from and self.linked_from(self) or 0
    -- This notebook on the web page (a QR code to scan with a phone).
    local webRow = self.on_web and { "qr-code", _("Open on the web page"), nil, function()
        self.panel = nil
        self:commitSelection()
        self:saveNow()
        self:repaint()
        self.on_web(self)
    end } or false
    -- Two pages side by side (portrait notebooks).
    local pw, ph = self:pageSize()
    local spreadRow = not (nb.puzzle or self.margin or self.quick) and pw < ph and self.on_spread
        and { "book-open", _("Two pages side by side"), self.spread and _("On") or _("Off"), function()
            self.panel = nil
            self:commitSelection()
            self:saveNow()
            self.on_spread(self, not self.spread)
        end } or false
    if self.spread then
        rows = {
            spreadRow,
            { "star", _("Bookmark page"), nb.pages[self.page].star and _("On") or _("Off"), function() self:runAction("bookmark") end },
            "-",
            KO.hasLight() and { "sun", _("Light"), nil, function() self:runAction("light") end } or false,
            { "moon", _("Night mode"), KO.nightMode() and _("On") or _("Off"), function() self:runAction("night") end },
            { "refresh-cw", _("Refresh screen"), nil, function() self:runAction("refresh") end },
            "-",
            webRow,
            { "settings", _("Settings"), nil, function() self:runAction("settings") end },
        }
    end
    if rows then
        -- (two pages side by side)
    elseif nb.puzzle then
        rows = {}
        for __, a in ipairs(self:puzzleActions()) do
            table.insert(rows, type(a) == "table" and { a.icon, a.label, a.value, a.fn } or a)
        end
    else
        -- In groups ("-" between them): the tools taken off the toolbar, AI
        -- and sending, the page, the notebook, the screen.
        rows = self:hiddenToolRows()
        -- (The AI's three only with an AI service set up.)
        local ai = not Settings.noAI()
        for __, r in ipairs({
            ai and { "sparkles", _("Ask AI…"), nil, function() self:runAction("ask") end } or false,
            ai and { "scan-text", _("Convert page to text"), nil, function() self:runAction("totext") end } or false,
            ai and { "list-checks", _("Add page to To Do"), nil, function() self:runAction("todo") end } or false,
            { "cloud-upload", _("Send to OneNote"), self.onenote_status and self.onenote_status(nb) or nil, function() self:runAction("onenote") end },
            -- A page downloaded from OneNote: put back there in place of its original.
            self.onenote_origin and self.onenote_origin(self) and { "replace", _("Replace in OneNote"), nil, function()
                self.panel = nil
                self:repaint()
                if self.on_replace_onenote then self.on_replace_onenote(self) end
            end } or false,
            { "file-down", _("Export…"), nil, function() self:runAction("export") end },
            { "wand", _("Tidy handwriting"), nil, function() self:runAction("tidy") end },
            "-",
            { "star", _("Bookmark page"), nb.pages[self.page].star and _("On") or _("Off"), function() self:runAction("bookmark") end },
            { "calendar", _("Date and time"), nil, function() self:runAction("datetime") end },
            -- Pages with a link to this one.
            linked > 0 and { "link", _("Linked from"), tostring(linked), function()
                self.panel = nil
                self:repaint()
                self.on_linked_from(self)
            end } or false,
            { "arrow-up-down", _("Reorder pages"), nil, function() self.panel = nil self:repaint() self:reorderPages() end },
            { "file-x", _("Delete page"), nil, function() self.panel = nil self:repaint() self:deletePage() end },
            "-",
            { "text-cursor-input", _("Rename notebook"), nil, function() self.panel = nil self:repaint() self:rename() end },
            { "rotate-cw", _("Page orientation"), self:orientationName(), function()
                self.panel = nil
                self:repaint()
                self:chooseOrientation(function(__, mode)
                    self:rotate(mode)
                    self:turnNotebook()
                end)
            end },
            spreadRow,
            { "gauge", _("Pen pressure"), nb.pressure == false and _("Off") or _("On"), function()
                nb.pressure = nb.pressure == false
                self:changed()
                self:repaint()
            end },
            "-",
            KO.hasLight() and { "sun", _("Light"), nil, function() self:runAction("light") end } or false,
            { "moon", _("Night mode"), KO.nightMode() and _("On") or _("Off"), function() self:runAction("night") end },
            { "refresh-cw", _("Refresh screen"), nil, function() self:runAction("refresh") end },
            "-",
            webRow,
            { "settings", _("Settings"), nil, function() self:runAction("settings") end },
        }) do table.insert(rows, r) end
    end
    local shown = {}
    for __, row in ipairs(rows) do
        if row then table.insert(shown, row) end
    end
    return shown
end

function Editor:paintMore(bb, x, y, pw)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    local nb = self.notebook
    if nb.puzzle or self.spread then return self:paintMoreRows(bb, x, y + u(6), pw) end
    ui:drawText(bb, _("Page template"), x + u(10), y + u(14), 9.5, { bold = true })
    -- For this page only, or every page.
    local scope = self.paperScope == "page" and _("This page") or _("All pages")
    local cw = ui:textWidth(scope, 8.5) + u(18)
    local cx = x + pw - u(10) - cw
    ui:box(bb, cx, y + u(4), cw, u(20), { fill = UI.WHITE, border = UI.BLACK, r = u(10) })
    ui:drawText(bb, scope, cx + math.floor(cw / 2), y + u(14), 8.5, { align = "center" })
    self:hit(cx - u(4), y, cw + u(8), u(26), function()
        self.paperScope = self.paperScope ~= "page" and "page" or nil
        self:repaint()
    end)
    for i, kind in ipairs(PAPERS) do
        local tx, ty, tw, th = x + u(10) + ((i - 1) % 5) * u(46), y + u(24) + math.floor((i - 1) / 5) * u(64), u(36), u(46)
        local on = self:paper() == kind
        bb:paintRect(tx, ty, tw, th, UI.WHITE)
        local g = Blitbuffer.Color8(0x99)
        local function hline(ly, lx, lw) bb:paintRect(lx or tx + u(3), ly, lw or tw - u(6), 1, g) end
        local function sq(sx, sy, s) bb:paintBorder(sx, sy, s, s, 1, g) end
        if kind == "narrow" or kind == "wide" then
            local step = kind == "narrow" and u(5) or u(8)
            for ly = ty + step + u(2), ty + th - u(2), step do hline(ly) end
        elseif kind == "grid" then
            for ly = ty + u(5), ty + th - u(2), u(6) do bb:paintRect(tx + u(2), ly, tw - u(4), 1, g) end
            for lx = tx + u(5), tx + tw - u(2), u(6) do bb:paintRect(lx, ty + u(2), 1, th - u(4), g) end
        elseif kind == "dots" then
            for ly = ty + u(5), ty + th - u(3), u(6) do
                for lx = tx + u(5), tx + tw - u(3), u(6) do bb:paintRect(lx, ly, 2, 2, g) end
            end
        elseif kind == "checklist" or kind == "tasks" then
            local k = 0
            for ly = ty + u(9), ty + th - u(3), u(7) do
                hline(ly)
                if kind == "tasks" and k % 3 ~= 0 then sq(tx + u(7), ly - u(4), u(3)) else sq(tx + u(3), ly - u(4), u(3)) end
                k = k + 1
            end
        elseif kind == "cornell" then
            hline(ty + u(7))
            hline(ty + th - u(10))
            bb:paintRect(tx + u(11), ty + u(7), 1, th - u(17), g)
            for ly = ty + u(12), ty + th - u(12), u(5) do hline(ly, tx + u(13), tw - u(16)) end
        elseif kind == "weekly" then
            for k = 0, 4 do hline(ty + u(4) + k * u(10), tx + u(2), tw - u(4)) end
            bb:paintRect(tx + math.floor(tw / 2), ty + u(4), 1, u(40), g)
        elseif kind == "music" then
            for k = 0, 2 do
                for l = 0, 4 do hline(ty + u(6) + k * u(14) + l * u(2)) end
            end
        elseif kind == "margin" then
            for ly = ty + u(7), ty + th - u(2), u(5) do hline(ly) end
            bb:paintRect(tx + u(9), ty + u(2), 1, th - u(4), UI.BLACK)
        elseif kind == "isometric" then
            local k = 0
            for ly = ty + u(5), ty + th - u(3), u(5) do
                for lx = tx + u(5) + (k % 2) * u(3), tx + tw - u(3), u(6) do bb:paintRect(lx, ly, 2, 2, g) end
                k = k + 1
            end
        elseif kind == "hex" then
            for k = 0, 3 do
                for l = 0, 2 do
                    local hx, hy = tx + u(6) + l * u(11), ty + u(6) + k * u(10) + (l % 2) * u(5)
                    bb:paintBorder(hx, hy, u(7), u(7), 1, g)
                end
            end
        elseif kind == "calendar" then
            bb:paintRect(tx + u(4), ty + u(5), u(14), 2, UI.BLACK)
            for k = 0, 5 do hline(ty + u(12) + k * u(6), tx + u(3), tw - u(6)) end
            for l = 0, 4 do bb:paintRect(tx + u(3) + l * u(7.5), ty + u(12), 1, u(30), g) end
        end
        bb:paintBorder(tx, ty, tw, th, on and math.max(3, u(1.8)) or 1, on and UI.BLACK or UI.MID)
        ui:drawText(bb, PAPER_SHORT[kind], tx + math.floor(tw / 2), ty + th + u(9), 8, { align = "center", bold = on })
        self:hit(tx - u(4), ty - u(4), tw + u(8), th + u(20), function() self:setPaper(kind) end)
    end
    -- Your own templates, and + for a new one.
    ui:drawText(bb, _("Your templates"), x + u(10), y + u(228), 9.5, { bold = true })
    local mine = Editor.templates()
    local slots = math.min(#mine, 4)
    for i = 1, slots + 1 do
        local t = mine[i]
        local tx, ty, tw, th = x + u(10) + (i - 1) * u(46), y + u(238), u(36), u(46)
        bb:paintRect(tx, ty, tw, th, UI.WHITE)
        if i <= slots then
            local thumb = self:templateThumb(t, tw, th)
            if thumb then bb:blitFrom(thumb, tx, ty, 0, 0, thumb:getWidth(), thumb:getHeight()) end
            local on = self:paper() == "tpl:" .. t.file
            bb:paintBorder(tx, ty, tw, th, on and math.max(3, u(1.8)) or 1, on and UI.BLACK or UI.MID)
            local chars = require("util").splitToChars(t.name)
            local label = #chars > 7 and (table.concat(chars, "", 1, 6) .. "…") or t.name
            ui:drawText(bb, label, tx + math.floor(tw / 2), ty + th + u(9), 8, { align = "center", bold = on })
            -- Tapped again when in use: to delete it.
            self:hit(tx - u(4), ty - u(4), tw + u(8), th + u(20), function()
                if on then
                    self.panel = nil
                    self:repaint()
                    self:templateActions(t)
                else
                    self:setPaper("tpl:" .. t.file)
                end
            end)
        else
            bb:paintBorder(tx, ty, tw, th, 1, UI.MID)
            ui:drawIcon(bb, "plus", tx + math.floor((tw - u(16)) / 2), ty + math.floor((th - u(16)) / 2), u(16))
            ui:drawText(bb, _("New"), tx + math.floor(tw / 2), ty + th + u(9), 8, { align = "center" })
            self:hit(tx - u(4), ty - u(4), tw + u(8), th + u(20), function()
                self.panel = nil
                self:repaint()
                self:newTemplate()
            end)
        end
    end
    ui:line(bb, x + u(8), y + u(298), pw - u(16), 1)
    self:paintMoreRows(bb, x, y + u(304), pw)
end

-- A template's picture small, for the menu (kept while the notebook is open).
function Editor:templateThumb(t, w, h)
    self.tplThumbs = self.tplThumbs or {}
    local c = self.tplThumbs[t.file]
    if c then return c end
    local ok, pic = pcall(require("ui/renderimage").renderImageFile, require("ui/renderimage"), TEMPLATE_DIR .. "/" .. t.file, false)
    if not ok or not pic then return nil end
    local f = math.min(w / pic:getWidth(), h / pic:getHeight())
    local sw, sh = math.max(1, math.floor(pic:getWidth() * f)), math.max(1, math.floor(pic:getHeight() * f))
    local scaled = pic:scale(sw, sh)
    pic:free()
    local thumb = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BB8)
    thumb:fill(Blitbuffer.COLOR_WHITE)
    if scaled:getType() == Blitbuffer.TYPE_BBRGB32 then thumb:alphablitFrom(scaled, 0, 0, 0, 0, sw, sh) else thumb:blitFrom(scaled, 0, 0, 0, 0, sw, sh) end
    scaled:free()
    self.tplThumbs[t.file] = thumb
    return thumb
end

-- The ⋯ menu's rows from y down, a line between groups.
function Editor:paintMoreRows(bb, x, y, pw)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    local ry = y
    for __, row in ipairs(self:moreRows()) do
        if row == "-" then
            ui:line(bb, x + u(8), ry + u(3), pw - u(16), 1, UI.MID)
            ry = ry + u(MORE_GAP)
        else
            self:moreRow(bb, row, x, ry, pw)
            ry = ry + (self.moreRowH or u(26))
        end
    end
end

-- The Hint panel: what to show, then a tap on the page says where.
local HINTS = {
    { "letter", "type", _("Reveal a letter"), _("tap a square") },
    { "word", "whole-word", _("Reveal a word"), _("tap a clue or square") },
    { "check", "spell-check", _("Check a word"), _("tap a clue or square"), ai = true },
    { "ask", "sparkles", _("Ask AI for a hint"), _("tap a clue or square"), ai = true },
}

-- The Hint panel's rows: the AI's only with an AI service set up, and Check
-- my answers when the book can be checked.
function Editor:hintRows()
    local rows = {}
    for __, h in ipairs(HINTS) do
        if not (h.ai and Settings.noAI()) then table.insert(rows, h) end
    end
    return rows, self.on_check ~= nil and not Settings.noAI()
end
local HINT_BANNERS = {
    letter = _("Tap a square to reveal its letter"), word = _("Tap a clue or a square to reveal its word"),
    check = _("Tap a clue or a square to check its word"), ask = _("Tap a clue or a square for a hint"),
}

function Editor:paintHintPanel(bb, x, y, pw)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    ui:drawText(bb, _("Hint"), x + u(10), y + u(18), 10, { bold = true })
    local ry = y + u(34)
    local function row(icon, label, note, fn, job)
        local mid = ry + u(15)
        ui:drawIcon(bb, icon, x + u(10), mid - u(7), u(14))
        ui:drawText(bb, label, x + u(32), mid, 10)
        if note then ui:drawText(bb, note, x + pw - u(10), mid, 8, { align = "right", color = UI.GREY_TEXT }) end
        self:hit(x, ry, pw, u(30), fn)
        -- (Held: "AI for this", for the AI's rows.)
        if job then self:aiHold(x, ry, pw, u(30), job) end
        ry = ry + u(30)
    end
    local rows, check = self:hintRows()
    for __, h in ipairs(rows) do
        row(h[2], h[3], h[4], function() self:startHint(h[1]) end, h[1] == "ask" and "cw_hint" or h[1] == "check" and "cw_check" or nil)
    end
    -- The whole grid checked, as the toolbar's Check my answers.
    if check then
        row("spell-check", _("Check my answers"), _("the whole grid"), function()
            self.panel = nil
            self:repaint()
            self.on_check(self)
        end, "cw_check")
    end
    ui:line(bb, x + u(8), ry + u(3), pw - u(16), 1, UI.MID)
    ry = ry + u(MORE_GAP)
    row("eye", _("Show the answers page"), nil, function()
        self.panel = nil
        self:repaint()
        if self.on_hint then self.on_hint(self, "answers") end
    end)
end

--- A hint picked: the next tap on a square or clue says where (a line at
-- the bottom says so, with Cancel).
function Editor:startHint(mode)
    self.panel = nil
    self.check = nil
    self.hintMode = mode
    self:repaint()
end

function Editor:paintHintBanner(bb)
    local ui = self.ui
    local text, cancel = HINT_BANNERS[self.hintMode] or "", _("Cancel")
    local tw, cw = ui:textWidth(text, 10, true), ui:textWidth(cancel, 10, true)
    local w, h = tw + cw + ui:u(56), ui:u(30)
    local r = self.pageRect
    local x, y = r[1] + math.floor((r[3] - w) / 2), self.h - h - ui:u(12)
    ui:box(bb, x, y, w, h, { fill = UI.BLACK, border = UI.BLACK, r = ui:u(15) })
    ui:drawIcon(bb, "lightbulb", x + ui:u(10), y + ui:u(7), ui:u(16), true)
    ui:drawText(bb, text, x + ui:u(32), y + math.floor(h / 2), 10, { bold = true, color = UI.WHITE })
    ui:drawText(bb, cancel, x + w - ui:u(12) - cw, y + math.floor(h / 2), 10, { bold = true, color = UI.WHITE })
    self:hit(x, y, w, h, function()
        self.hintMode = nil
        self:repaint()
    end)
end

-- A tap (pen or finger) while a hint waits for where: true when it was
-- taken (the hint given, or a choice of word shown); else it waits on.
function Editor:hintTap(x, y)
    if not (self.hintMode and self.on_hint) then return false end
    local mode = self.hintMode
    if not self.on_hint(self, mode, x, y) then return false end
    self.hintMode = nil
    self:repaint()
    return true
end

-- One row of the ⋯ menu: { icon, label, value, action }.
function Editor:moreRow(bb, row, x, ry, pw)
    local ui, nb = self.ui, self.notebook
    local u = function(n) return ui:u(n) end
    local off = (row[1] == "file-x" and #nb.pages < 2) or (row[1] == "arrow-up-down" and #nb.pages < 2)
    local rh = self.moreRowH or u(26)
    local mid = ry + math.floor(rh / 2)
    ui:drawIcon(bb, row[1], x + u(10), mid - u(7), u(14), false, off)
    ui:drawText(bb, row[2], x + u(32), mid, 10, { color = off and UI.MID or UI.BLACK })
    if row[3] then
        local small = row[1] == "cloud-upload"
        ui:drawText(bb, row[3], x + pw - u(12), mid, small and 8.5 or 9.5, { align = "right", bold = not small, color = small and UI.GREY_TEXT or nil })
    end
    self:hit(x, ry, pw, rh, not off and row[4] or function() end)
end

function Editor:settingsChanged()
    self.penFeel = Settings.get("pen_feel")
    self:layout()
    self:renderPage()
    self:repaint()
end

-- ------------------------------------------------------------------ the lasso's selection

-- What the selection looks like now: its strokes moved and scaled.
function Editor:selectionView()
    local sel = self.sel
    if not sel.view or sel.viewKey ~= table.concat({ sel.dx, sel.dy, sel.s }, ",") then
        sel.view, sel.itemView = {}, {}
        for i, stroke in ipairs(sel.strokes) do
            sel.view[i] = Ink.transform(stroke, sel.box[1], sel.box[2], sel.s, sel.dx, sel.dy)
        end
        for i, it in ipairs(sel.items) do
            sel.itemView[i] = Items.transform(it, sel.box[1], sel.box[2], sel.s, sel.dx, sel.dy)
        end
        sel.viewKey = table.concat({ sel.dx, sel.dy, sel.s }, ",")
    end
    return sel.view
end

-- The selected items (text, pictures, tape) as they look now.
function Editor:selectionItems()
    self:selectionView()
    return self.sel.itemView
end

function Editor:selectionBox()
    local sel, pad = self.sel, self.ui:u(4)
    local b = sel.box
    return { b[1] + sel.dx - pad, b[2] + sel.dy - pad, math.floor(b[3] * sel.s) + 2 * pad, math.floor(b[4] * sel.s) + 2 * pad }
end

function Editor:selectionActions()
    local actions = {
        { "scissors", _("Cut"), function() self:copySelection() self:deleteSelection() end },
        { "copy", _("Copy"), function() self:copySelection() KO.toast(_("Copied")) end },
        { "copy-plus", _("Duplicate"), function() self:duplicateSelection() end },
        { "shapes", _("Snap shapes"), function() self:snapSelection() end },
        { "type", _("To text"), function() self:selectionToText() end, "read" },
        { "palette", _("Style"), function() self:styleSelection() end },
        { "wand", _("Tidy"), function() self:tidy(TIDY.tidy) end },
        { "list-todo", _("To To Do"), function() self:selectionToTodo() end, "read" },
        { "sparkles", _("Ask"), function() self:selectionTo(self.on_ask_png) end, "ask" },
    }
    -- A crossword fetched: the answer of what was lassoed, from the book.
    if self.notebook.feed and self.on_answer then
        table.insert(actions, { "eye", _("Answer"), function()
            local box = self:selectionBox()
            self:commitSelection()
            self:repaint()
            self.on_answer(self, box)
        end })
    end
    -- A crossword fetched: Reveal puts in the letters of the squares circled.
    if self.notebook.feed and self.on_reveal then
        table.insert(actions, { "type", _("Reveal"), function()
            local box = self:selectionBox()
            self:commitSelection()
            self:repaint()
            self.on_reveal(self, box)
        end })
    end
    table.insert(actions, { "wand-sparkles", _("Draw"), function() self:selectionDraw() end, "draw" })
    table.insert(actions, { "trash-2", _("Delete"), function() self:deleteSelection() end })
    -- No AI service set up: none of the AI's (To text, To To Do, Ask, Draw).
    if Settings.noAI() then
        local AI = { [_("To text")] = true, [_("To To Do")] = true, [_("Ask")] = true, [_("Draw")] = true }
        local kept = {}
        for __, a in ipairs(actions) do if not AI[a[2]] then table.insert(kept, a) end end
        actions = kept
    end
    return actions
end

function Editor:actionBarBox()
    local ui, b = self.ui, self:selectionBox()
    local w, h = ui:u(49 * #self:selectionActions() + 2), ui:u(40)
    local x = math.max(ui:u(4), math.min(self.w - w - ui:u(4), b[1]))
    local y = b[2] + b[4] + ui:u(10)
    if y + h > self.h - ui:u(4) then y = math.max(ui:u(4), b[2] - h - ui:u(10)) end
    return { x, y, w, h }
end

-- The selected strokes drawn once into a see-through picture (as they
-- were lassoed), so moving them only places the picture: a big selection is
-- not drawn stroke by stroke on every refresh.
function Editor:selectionImage()
    local sel = self.sel
    if sel.image ~= nil then return sel.image or nil end
    sel.image = false
    if #sel.strokes == 0 then return nil end
    local box = Ink.clip(Ink.boxOf(sel.strokes), self.w, self.h)
    if not box then return nil end
    box = { math.floor(box[1]), math.floor(box[2]), math.ceil(box[3]), math.ceil(box[4]) }
    local w, h = box[3], box[4]
    -- The ink on white, and where it is (drawing leaves a picture's
    -- see-through part alone, so the two are put together after).
    local ok, ink, mask, img = pcall(function()
        return Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8), Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8),
            Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8A)
    end)
    if not ok then return nil end
    ink:fill(Blitbuffer.COLOR_WHITE)
    mask:fill(Blitbuffer.COLOR_BLACK)
    local r = setmetatable({ pageRect = { 0, 0, w, h } }, { __index = self })
    for pass = 1, 2 do
        for __, stroke in ipairs(sel.strokes) do
            local moved = Ink.transform(stroke, 0, 0, 1, -box[1], -box[2])
            if pass == 1 and stroke.f then
                r:fillStroke({ ink }, moved)
                moved.f = 255
                r:fillStroke({ mask }, moved)
            end
            if (Ink.tipOf(stroke).under == true) == (pass == 1) then
                r:drawStroke({ ink }, moved)
                r:drawStroke({ mask }, moved, Blitbuffer.COLOR_WHITE)
            end
        end
    end
    local ip, mp, op = ffi.cast("uint8_t *", ink.data), ffi.cast("uint8_t *", mask.data), ffi.cast("uint8_t *", img.data)
    local is, ms, os_ = tonumber(ink.stride), tonumber(mask.stride), tonumber(img.stride)
    for y = 0, h - 1 do
        local i0, m0, o0 = y * is, y * ms, y * os_
        for x = 0, w - 1 do
            op[o0 + 2 * x] = ip[i0 + x]
            op[o0 + 2 * x + 1] = mp[m0 + x]
        end
    end
    ink:free()
    mask:free()
    sel.image, sel.imageAt = img, box
    return img
end

-- A selection let go: its picture freed.
local function dropSelection(sel)
    if sel and sel.image then sel.image:free() end
    if sel then sel.image = false end
end

function Editor:paintSelection(bb)
    local ui = self.ui
    local dir = self:imageDir()
    local sel = self.sel
    Items.draw(bb, self:selectionItems(), "under", nil, nil, dir)
    local img = sel.s == 1 and self:selectionImage()
    if img then
        -- Placed where it was moved to, within the page.
        local at, r = sel.imageAt, self.pageRect
        local x, y = at[1] + sel.dx, at[2] + sel.dy
        local x0, y0 = math.max(x, r[1]), math.max(y, r[2])
        local x1, y1 = math.min(x + at[3], r[1] + r[3]), math.min(y + at[4], r[2] + r[4])
        if x1 > x0 and y1 > y0 then bb:alphablitFrom(img, x0, y0, x0 - x, y0 - y, x1 - x0, y1 - y0) end
    else
        for pass = 1, 2 do
            for __, stroke in ipairs(self:selectionView()) do
                if pass == 1 and stroke.f then self:fillStroke({ bb }, stroke) end
                if (Ink.tipOf(stroke).under == true) == (pass == 1) then self:drawStroke({ bb }, stroke) end
            end
        end
    end
    Items.draw(bb, self:selectionItems(), "text", nil, nil, dir)
    Items.draw(bb, self:selectionItems(), "over", nil, nil, dir)
    local b = self:selectionBox()
    ui:dashed(bb, b[1], b[2], b[3], b[4])
    local hs = ui:u(9)
    bb:paintRect(b[1] + b[3] - math.floor(hs / 2), b[2] + b[4] - math.floor(hs / 2), hs, hs, UI.BLACK)
    if self.sel.dragging then return end
    local a = self:actionBarBox()
    ui:box(bb, a[1], a[2], a[3], a[4], { fill = UI.WHITE, border = UI.BLACK, r = ui:u(8), bw = math.max(2, ui:u(1.2)) })
    -- (Button labels off in the launcher's settings: just the icons.)
    local P = require("pluginshare").popup
    local okL, withLabels = pcall(function() return not (P and P.labels) or P.labels() end)
    withLabels = not okL or withLabels ~= false
    for i, act in ipairs(self:selectionActions()) do
        local cx = a[1] + ui:u(25) + (i - 1) * ui:u(49)
        if withLabels then
            ui:drawIcon(bb, act[1], cx - ui:u(8), a[2] + ui:u(6), ui:u(16))
            ui:drawText(bb, act[2], cx, a[2] + ui:u(31), 8, { align = "center" })
        else
            ui:drawIcon(bb, act[1], cx - ui:u(10), a[2] + ui:u(10), ui:u(20))
        end
        self:hit(cx - ui:u(24), a[2], ui:u(48), a[4], act[3])
        -- (The AI's actions, held: "AI for this", for the job in act[4].)
        if act[4] then self:aiHold(cx - ui:u(24), a[2], ui:u(48), a[4], act[4]) end
    end
end

function Editor:paintPaste(bb)
    local ui, p = self.ui, self.pasteAt
    local w, h = ui:u(70), ui:u(28)
    local x = math.max(0, math.min(self.w - w, p[1] - math.floor(w / 2)))
    local y = math.max(0, math.min(self.h - h, p[2] - h - ui:u(8)))
    ui:box(bb, x, y, w, h, { fill = UI.WHITE, border = UI.BLACK, r = ui:u(14) })
    ui:drawIcon(bb, "clipboard-paste", x + ui:u(9), y + ui:u(7), ui:u(14))
    ui:drawText(bb, _("Paste"), x + ui:u(28), y + math.floor(h / 2), 10)
    self:hit(x, y, w, h, function() self:paste(p[1], p[2]) end)
end

-- The page's items (typed text, pictures, tape).
function Editor:pageItems()
    local page = self.notebook.pages[self.page]
    page.items = page.items or {}
    return page.items
end

function Editor:imageDir()
    return self.notebook.imageDir or (self.store and self.store:imageDir()) or "."
end

-- The page's ink and items as they are now (for undo).
function Editor:snapshot()
    return { strokes = { unpack(self:strokes()) }, items = { unpack(self:pageItems()) } }
end

-- A change to the page since `before` (a snapshot), undoable as one.
function Editor:pushSnapshot(before)
    self:pushUndo({ lists = { before = before, after = self:snapshot() } })
    self:changed()
end

-- The lasso closed: the strokes (and items) it took become the selection.
function Editor:select(indexes, items)
    local strokes = self:strokes()
    local sel = { strokes = {}, set = {}, items = items or {}, itemSet = {}, s = 1, dx = 0, dy = 0 }
    for __, i in ipairs(indexes) do
        table.insert(sel.strokes, strokes[i])
        sel.set[strokes[i]] = true
    end
    local box = Ink.boxOf(sel.strokes)
    for __, it in ipairs(sel.items) do
        sel.itemSet[it] = true
        local x, y, w, h = Items.box(it)
        box = Ink.union(box, { x, y, w, h })
    end
    if not box then return end
    sel.box = box
    dropSelection(self.sel)
    self.sel = sel
    self:renderPage()
    self:repaint()
end

-- The selection's move or resize made real (and undoable), and it let go.
function Editor:commitSelection()
    local sel = self.sel
    if not sel then return end
    local view = self:selectionView()
    local itemView = sel.itemView
    dropSelection(sel)
    self.sel = nil
    if sel.dx ~= 0 or sel.dy ~= 0 or sel.s ~= 1 then
        local before = self:snapshot()
        local strokes, items = self:strokes(), self:pageItems()
        local swap = {}
        for i, stroke in ipairs(sel.strokes) do swap[stroke] = view[i] end
        for i, it in ipairs(sel.items) do swap[it] = itemView[i] end
        for i, stroke in ipairs(strokes) do
            if swap[stroke] then strokes[i] = swap[stroke] end
        end
        for i, it in ipairs(items) do
            if swap[it] then items[i] = swap[it] end
        end
        self:pushSnapshot(before)
    end
    self:renderPage()
    self:repaint()
end

-- Selected strokes and items, as they look now, into the clipboard (from
-- the selection's corner).
function Editor:copySelection()
    local b = self:selectionBox()
    local pad = self.ui:u(4)
    local ox, oy = b[1] + pad, b[2] + pad
    clipboard = { strokes = {}, items = {}, w = b[3] - 2 * pad, h = b[4] - 2 * pad }
    for __, stroke in ipairs(self:selectionView()) do
        table.insert(clipboard.strokes, Ink.transform(stroke, 0, 0, 1, -ox, -oy))
    end
    for __, it in ipairs(self:selectionItems()) do
        table.insert(clipboard.items, Items.transform(it, 0, 0, 1, -ox, -oy))
    end
    -- Typed text in it: on KOReader's clipboard too, to paste in any app's box.
    local texts = {}
    for __, it in ipairs(clipboard.items) do
        if it.k == "text" and it.text and it.text ~= "" then table.insert(texts, it.text) end
    end
    if #texts > 0 and Device.input.setClipboardText then
        clipboard.text = table.concat(texts, "\n")
        Device.input.setClipboardText(clipboard.text)
    end
    clipboard.sys = Device.input.getClipboardText and Device.input.getClipboardText() or nil
end

-- Text copied in another app since Notes' own copy (KOReader's clipboard), or nil.
function Editor:otherAppText()
    local text = Device.input.getClipboardText and Device.input.getClipboardText()
    if type(text) ~= "string" or not text:match("%S") then return nil end
    if clipboard and clipboard.sys == text then return nil end
    return text
end

-- Strokes and items added to the page (undoable) and selected.
function Editor:addSelected(new, newItems)
    local before = self:snapshot()
    local strokes, items = self:strokes(), self:pageItems()
    local first = #strokes + 1
    for __, stroke in ipairs(new) do table.insert(strokes, stroke) end
    for __, it in ipairs(newItems or {}) do table.insert(items, it) end
    self:pushSnapshot(before)
    local indexes = {}
    for i = first, #strokes do table.insert(indexes, i) end
    self:select(indexes, newItems)
end

function Editor:deleteSelection()
    local sel = self.sel
    if not sel then return end
    dropSelection(sel)
    self.sel = nil
    local before = self:snapshot()
    local strokes, items = self:strokes(), self:pageItems()
    for i = #strokes, 1, -1 do
        if sel.set[strokes[i]] then table.remove(strokes, i) end
    end
    for i = #items, 1, -1 do
        if sel.itemSet[items[i]] then table.remove(items, i) end
    end
    self:pushSnapshot(before)
    self:renderPage()
    self:repaint()
end

function Editor:duplicateSelection()
    local view = self:selectionView()
    local itemView = self.sel.itemView
    local off = self.ui:u(12)
    self:commitSelection()
    local copies, itemCopies = {}, {}
    for i, stroke in ipairs(view) do copies[i] = Ink.transform(stroke, 0, 0, 1, off, off) end
    for i, it in ipairs(itemView) do itemCopies[i] = Items.transform(it, 0, 0, 1, off, off) end
    self:addSelected(copies, itemCopies)
end

-- The clipboard, centred where the pen tapped (kept on the page).
function Editor:paste(x, y)
    self.pasteAt = nil
    -- Text copied in another app (since Notes' last copy): a text box here.
    local other = self:otherAppText()
    if other then
        local r = self.pageRect
        local w = math.floor(r[3] * 0.6)
        local style = self:textStyle()
        local item = { k = "text", x = math.max(r[1], math.min(r[1] + r[3] - w, x - math.floor(w / 2))), y = y, w = w,
            size = self:textSize(), text = other, bold = style.bold, italic = style.italic, serif = style.serif,
            align = style.align ~= "left" and style.align or nil }
        clipboard = clipboard or { strokes = {}, items = {}, w = 0, h = 0 }
        clipboard.sys = other
        return self:addSelected({}, { item })
    end
    if not clipboard then return self:repaint() end
    local r = self.pageRect
    local px = math.max(r[1], math.min(r[1] + r[3] - clipboard.w, x - math.floor(clipboard.w / 2)))
    local py = math.max(r[2], math.min(r[2] + r[4] - clipboard.h, y - math.floor(clipboard.h / 2)))
    local new, newItems = {}, {}
    for i, stroke in ipairs(clipboard.strokes) do new[i] = Ink.transform(stroke, 0, 0, 1, px, py) end
    for i, it in ipairs(clipboard.items or {}) do newItems[i] = Items.transform(it, 0, 0, 1, px, py) end
    self:addSelected(new, newItems)
end

-- A refresh of the selection while it is dragged, at most every DRAG_REFRESH.
function Editor:dragRefresh()
    if self.dragTask then return end
    self.dragTask = function()
        self.dragTask = nil
        if not self.sel then return end
        local now = self:selectionBox()
        local area = Ink.union(self.lastDragBox, now)
        self.lastDragBox = now
        local pad = self.ui:u(10)
        self:repaint({ area[1] - pad, area[2] - pad, area[3] + 2 * pad, area[4] + 2 * pad }, "a2")
    end
    UIManager:scheduleIn(DRAG_REFRESH, self.dragTask)
end

-- ------------------------------------------------------------------ pen

-- Whether the pen writes here: nothing over the editor but notices that go
-- by themselves (toasts such as "Saved ..."), which must not block the pen.
function Editor:onTop()
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w == self then return true end
        if not (w.invisible or w.toast) then return false end
    end
    return UIManager:getTopmostVisibleWidget() == self
end


-- Back on top after a dialog, menu or another screen: a full flash clears
-- what e-ink kept of it (a notice that shows for a moment does not count).
function Editor:watchCover()
    local top = UIManager:getTopmostVisibleWidget()
    if top == self then
        if self.covered then
            self.covered = false
            UIManager:setDirty(self, "full")
            -- Another editor (To Do's handwriting pad) may have taken the pen.
            if self.stylusHook and Device.input.stylus_callback ~= self.stylusHook
                    and type(Device.input.registerStylusCallback) == "function" then
                Device.input:registerStylusCallback(self.stylusHook)
            end
        end
    elseif top and not top.toast then
        self.covered = true
    end
    self.coverTask = self.coverTask or function() self:watchCover() end
    UIManager:scheduleIn(0.4, self.coverTask)
end

-- Once a minute: the time and battery on the toolbar again (not while
-- writing: a few seconds later then).
function Editor:tickStatus()
    if self.statusRetry then UIManager:unschedule(self.statusRetry) end
    self.statusRetry = nil
    local r = self.statusRect
    if not r or self.folded or not self.page_bb or not self:onTop() then return end
    if self.busy or self.stroke or self.lasso or self.erasing or self:palmLikely() then
        self.statusRetry = function() self:tickStatus() end
        UIManager:scheduleIn(5, self.statusRetry)
        return
    end
    self:repaint(r, "ui")
end

-- A touch KOReader's gestures already hold (it began while a dialog was on
-- top, and the dialog closed under it): left to them until it lifts. Taking
-- its end would leave them waiting for a lift that never comes, and then
-- fingers do nothing (until the Kindle sleeps and wakes).
local function heldByGestures(inp, slot)
    local gd = inp and inp.gesture_detector
    return gd ~= nil and type(gd.getContact) == "function" and slot and slot.slot ~= nil and gd:getContact(slot.slot) ~= nil
end

function Editor:onShow()
    Editor.openCount = (Editor.openCount or 0) + 1
    if not self.stopStatus then self.stopStatus = UI.everyMinute(function() self:tickStatus() end) end
    UIManager:setDirty(self, "full")
    if self.on_page then self.on_page(self) end
    self:watchCover()
    local input = Device.input
    local pen, why = Pen.open()
    if pen then
        self.pen = pen
        logger.info("Notes: pen from", pen.path, "X", pen.minX, pen.maxX, "Y", pen.minY, pen.maxY, "pressure", pen.maxP)
        -- KOReader's own pen handling still runs: its pen points are dropped
        -- here (kept out of gestures) unless a dialog is on top.
        if type(input.registerStylusCallback) == "function" then
            self.stylusHook = function(inp, slot)
                -- A finger (while the pen hovers) goes on to the toolbar.
                if Pen.isFinger(slot, inp.pen_slot) then return false end
                if heldByGestures(inp, slot) then return false end
                KO.penActive()
                -- KOReader sees the pen too: its events wake Notes to read
                -- the digitizer now, so with the pen away Notes needn't keep
                -- asking (it checks only now and then).
                self.penWakes = true
                self:pollSoon()
                return self:onTop()
            end
            self.prevStylus = input.stylus_callback
            input:registerStylusCallback(self.stylusHook)
        end
        self.pollTask = function() self:pollPen() end
        UIManager:scheduleIn(POLL_AWAY, self.pollTask)
    else
        logger.info("Notes: no pen digitizer (", why, "); using KOReader's stylus input")
        if type(input.registerStylusCallback) == "function" then
            self.stylusHook = function(inp, slot)
                if Pen.isFinger(slot, inp.pen_slot) then return false end
                if heldByGestures(inp, slot) then return false end
                KO.penActive()
                return self:onStylus(slot)
            end
            self.prevStylus = input.stylus_callback
            input:registerStylusCallback(self.stylusHook)
        end
    end
    return true
end

-- What the digitizer sent since the last read, onto the page. Read often
-- while the pen is near, rarely while it is away.
function Editor:pollPen()
    local pen = self.pen
    if not pen then return end
    local events = pen:read()
    if #events > 0 then self.penAt = time.now() end
    local onTop = self:onTop()
    for __, ev in ipairs(events) do
        if onTop or self.busy then self:penEvent(ev) end
        -- The pen closed the notebook (its toolbar's first button).
        if not self.pollTask then return end
    end
    local near = pen.state.tool ~= nil
    -- Still busy with a stroke or the eraser though the pen has gone (its
    -- lifting was missed): it ends now, so the screen is cleaned and the pen
    -- writes again.
    if not near and not pen.state.down and self.busy then self:penUp() end
    UIManager:scheduleIn(near and POLL_NEAR or (self.penWakes and POLL_IDLE or POLL_AWAY), self.pollTask)
end

-- The digitizer read right after KOReader's input (once, however many pen
-- events came in together).
function Editor:pollSoon()
    if self.pollQueued or not self.pollTask then return end
    self.pollQueued = true
    UIManager:nextTick(function()
        self.pollQueued = false
        if not self.pollTask then return end
        UIManager:unschedule(self.pollTask)
        self:pollPen()
    end)
end

-- The tool the pen works as: its eraser end erases; its side button does
-- what Settings say.
function Editor:toolFor(ev)
    if ev.rubber then return "eraser" end
    if ev.side then
        local b = Settings.get("side_button")
        if b == "eraser" or b == "lasso" or b == "hl" or b == "ruler" then return b end
    end
    return self.tool
end

function Editor:tipFor(tool)
    return tool == "hl" and "hl" or self.tip
end

-- A digitizer point on the screen as it is turned. The digitizer measures
-- the upright (portrait) screen; turned, the point is turned the way
-- KOReader turns touches.
function Editor:penPoint(dx, dy)
    local pen = self.pen
    local mode = Screen.getTouchRotation and Screen:getTouchRotation() or Screen:getRotationMode()
    local nw, nh = self.w, self.h
    if mode % 2 == 1 then nw, nh = self.h, self.w end
    local nx = (dx - pen.minX) * nw / (pen.maxX - pen.minX)
    local ny = (dy - pen.minY) * nh / (pen.maxY - pen.minY)
    local x, y = nx, ny
    if mode == 1 then
        x, y = self.w - ny, nx
    elseif mode == 3 then
        x, y = ny, self.h - nx
    elseif mode == 2 then
        x, y = self.w - nx, self.h - ny
    end
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

-- The Kindle turned while writing: turned the other way round in the same
-- orientation (landscape one way or the other), the page follows; from
-- portrait to landscape or back, it stays as it is (the notebook's pages
-- have one orientation: More > Page orientation changes it).
function Editor:onSetRotationMode(mode)
    local landscape = self.w > self.h
    -- Crosswords: laid out again for the way the Kindle is held.
    if mode and self.notebook.feed and self.on_orient and (mode % 2 == 1) ~= landscape then
        self:commitSelection()
        self.on_orient(self, mode % 2 == 1, mode)
        return true
    end
    local pw, ph = self:pageSize()
    if mode and self.on_spread and pw < ph and not (self.notebook.puzzle or self.margin or self.quick)
            and Settings.get("spread_turn") ~= false and (mode % 2 == 1) ~= landscape then
        self:commitSelection()
        self:saveNow()
        self.on_spread(self, mode % 2 == 1, mode)
        return true
    end
    if mode and (mode % 2 == 1) == landscape and mode ~= Screen:getRotationMode() then
        Screen:setRotationMode(mode)
        UIManager:setDirty(self, "full")
    end
    return true
end

function Editor:penEvent(ev)
    local pen = self.pen
    local x, y = self:penPoint(ev.x, ev.y)
    local f = math.max(0, math.min(1, (ev.pressure - pen.minP) / math.max(1, pen.maxP - pen.minP)))
    f = Ink.feel(f, self.penFeel)
    -- Pressing the eraser harder erases a bigger spot.
    self.eraserRadius = math.floor(Ink.ERASER_SIZES[self.eraserSize] * self.scale * (0.6 + 0.8 * f) + 0.5)
    local tool = self.penTool or self:toolFor(ev)
    local width = Ink.tipWidth(self:tipFor(tool), self.sizes[self:tipFor(tool)] or 2, self.notebook.pressure ~= false and f or nil, self.scale)
    -- Erasing still going on, but the pen writes now (its lifting was
    -- missed): the erasing ends and the writing starts.
    if self.erasing and ev.kind ~= "up" and not ev.eraser and self.penTool == "eraser" and self.tool ~= "eraser" then
        self:penUp()
        return self:penDown(x, y, self:toolFor(ev), width)
    end
    if ev.kind == "up" then
        self:penUp()
    elseif ev.kind == "restart" then
        -- Events were dropped: the stroke ends; a new one starts here.
        if self.stroke then
            local t = self.penTool
            self:endStroke()
            self:penDown(x, y, t, width)
        end
    elseif ev.kind == "down" then
        self:penDown(x, y, self:toolFor(ev), width)
    else
        self:penMove(x, y, width)
    end
end

function Editor:onStylus(slot)
    self.penAt = time.now()
    -- A menu or dialog on top: the pen works it as a finger would.
    if not self:onTop() and not self.busy then
        return false
    end
    if slot.id == -1 then
        self.lastT = nil
        self:penUp()
        return true
    end
    if slot.id == nil or not slot.x or not slot.y then return true end  -- The pen coming near.
    local x, y = slot.x, slot.y
    -- Points missing (the system dropped some while KOReader was busy): the
    -- line is not drawn across the gap; the next point starts a new one.
    local t = slot.timev
    local gap = t and self.lastT and time.to_ms(t - self.lastT) > GAP_MS
    self.lastT = t
    local tool = self.penTool or (slot.tool == 2 and "eraser" or self.tool)
    local width = Ink.tipWidth(self:tipFor(tool), self.sizes[self:tipFor(tool)] or 2, nil, self.scale)
    if self.stroke and gap then
        self:endStroke()
        self:penDown(x, y, tool, width)
    elseif not self.busy then
        self:penDown(x, y, tool, width)
    else
        self:penMove(x, y, width)
    end
    return true
end

-- The date and time (⋯ > Date and time) put where the pen or a finger tapped.
function Editor:place(x, y)
    local text = self.placing
    self.placing = nil
    local it = { k = "text", x = x, y = y, size = self:textSize(), text = text, w = 10 }
    it.w = Items.textWidth(it) + self.ui:u(6)
    local before = self:snapshot()
    table.insert(self:pageItems(), it)
    self:pushSnapshot(before)
    self:renderPage()
    self:repaint()
end

function Editor:penDown(x, y, tool, width)
    self.busy = true
    self.penTool = tool
    if self.placing and not self:hitAt(x, y) and x >= self.pageRect[1] and y >= self.pageRect[2] then
        self:place(x, y)
        self.press = { x = x, y = y, moved = true }
        return
    end
    -- The zoom strip's grip: the strip is dragged.
    if self:onStripGrip(x, y) then
        self.stripDrag = { dy = y - self:zoomGeometry()[2] }
        return
    end
    -- Pinned clues: dragged.
    if not self.view and self:onClueCard(x, y) then return self:grabClueCard(x, y) end
    -- The toolbar, a panel, the selection's buttons or the paste button:
    -- worked on lifting the pen, if it did not move far.
    if self:hitAt(x, y) or self.panel or self.pasteAt or self.drawAt then
        self.press = { x = x, y = y, moved = false }
        return
    end
    -- A quick note's buttons by the handle: worked when the pen or finger lifts on them.
    if self.quick then
        local pad = self.ui:u(6)
        for __, b in ipairs(self:quickButtons()) do
            if x >= b.x - pad and x < b.x + b.w + pad and y >= b.y - pad and y < b.y + b.h + pad then
                self.quickTap = b
                return
            end
        end
    end
    -- A quick note's top edge (its handle): dragged, the pad is taller or shorter.
    if self.quick and not self:hitAt(x, y) and math.abs(y - self:quickEdge()) <= self.ui:u(26) then
        self.quickDrag = { from = y, top = self.quick.top }
        return
    end
    -- A quick note: nothing outside the pad.
    if self.quick and (y < self.pageRect[2] or y >= self.pageRect[2] + self.pageRect[4]) then
        self.press = { x = x, y = y, moved = true }
        return
    end
    if self.askPad then
        -- Writing a request to Claude: only the strip takes ink.
        local r = self:askPadRect()
        if x >= r[1] and x < r[1] + r[3] - self.ui:u(80) and y >= r[2] + self.ui:u(20) and y < r[2] + r[4] then
            local w = math.max(2, math.floor(4 * self.scale + 0.5))
            self.padStroke = { w = w, p = { x, y } }
            self:stampInto({ Screen.bb }, w, x, y, x, y, Blitbuffer.COLOR_BLACK)
            self:markInk(x, y, x, y, w)
        else
            self.padIgnore = true
        end
        return
    end
    if self.picking then
        self.picking = { x0 = x, y0 = y, x1 = x, y1 = y }
        return
    end
    if self.spread then
        local k = self:spreadSlotAt(x, y)
        if not k then
            self.press = { x = x, y = y, moved = true }
            return
        end
        self:useSlot(k)
    end
    if self.view then
        -- Zoomed (or two pages): the pen writes, highlights or erases, nothing else.
        return self:viewPenDown(x, y, (tool == "eraser" or tool == "hl") and tool or "pen", width)
    end
    if tool ~= "lasso" then self:commitSelection() end
    if self.zoomOn and tool ~= "lasso" and tool ~= "eraser" then
        if self:inStrip(x, y) then
            -- Written in the zoom box's strip: lands small in the page.
            local strip, z = self:zoomGeometry()
            self.zoomStroke = { sx = x, sy = y, z = z, strip = strip }
            x, y = self:fromStrip(x, y)
            width = math.max(1, math.floor(width / z + 0.5))
        else
            -- On the page: the zoom box moves there.
            self.zoomMove = { x = x, y = y }
            return
        end
    end
    if tool ~= "lasso" and tool ~= "eraser" and not self.zoomStroke then
        local tape = Items.at(self:pageItems(), x, y, "tape")
        if tape then
            self.tapePress = { it = tape, x = x, y = y, moved = false }
            return
        end
    end
    if tool == "text" then
        self.texting = { x0 = x, y0 = y, x1 = x, y1 = y }
        return
    end
    if tool == "insert" then
        local w = Ink.tipWidth(self.tip, self.sizes[self.tip] or 2, nil, self.scale)
        self.shaping = { kind = "rect", tape = true, x0 = x, y0 = y, x1 = x, y1 = y, w = w }
        return
    end
    if tool == "eraser" then
        self.erasing = { removed = {}, changes = {}, before = self:snapshot(), x = x, y = y }
        self:eraseAlong(x, y, x, y)
    elseif tool == "lasso" then
        local sel = self.sel
        if sel then
            local b = self:selectionBox()
            local hs = self.ui:u(14)
            if math.abs(x - (b[1] + b[3])) <= hs and math.abs(y - (b[2] + b[4])) <= hs then
                self.drag = { kind = "resize", s = sel.s, x = x, y = y }
            elseif x >= b[1] and x < b[1] + b[3] and y >= b[2] and y < b[2] + b[4] then
                self.drag = { kind = "move", dx = sel.dx, dy = sel.dy, x = x, y = y }
            end
            if self.drag then
                sel.dragging = true
                self.lastDragBox = self:selectionBox()
                self:repaint(self:padded(self:actionBarBox()))   -- the buttons go while dragging
                return
            end
            self:commitSelection()
        end
        self.lasso = { p = { x, y } }
    elseif tool == "shapes" or tool == "ruler" then
        local kind = tool == "ruler" and "line" or Settings.get("shape")
        local w = Ink.tipWidth(self.tip, self.sizes[self.tip] or 2, nil, self.scale)
        self.shaping = { kind = kind, x0 = x, y0 = y, x1 = x, y1 = y, w = w }
        if kind == "line" or kind == "arrow" then self.shaping.x0, self.shaping.y0 = self:joinEnd(x, y) end
    elseif tool == "hl" then
        self.stroke = { t = "hl", w = width, p = { x, y }, q = { width } }
        self:previewHighlight(x, y, x, y, width)
    else
        self.stroke = { t = self.tip ~= "pen" and self.tip or nil, c = self:shadeGrey(self.tip), w = width, p = { x, y }, q = { width } }
        if Ink.tipOf(self.stroke).under then return self:previewHighlight(x, y, x, y, width) end
        self:holdLater(x, y)
        local color = colorOf(self.stroke)
        self:stampLive(width, x, y, x, y, color)
        self:markInk(x, y, x, y, width)
    end
end

function Editor:padded(area, pad)
    pad = pad or self.ui:u(4)
    return { area[1] - pad, area[2] - pad, area[3] + 2 * pad, area[4] + 2 * pad }
end

-- Ink as it is written: into the page image as it is, and onto the screen
-- in black, since the fast refresh used while writing shows black and white
-- only. Grey ink (the pencil) goes on the screen striped, every other pixel
-- row, which looks like pencil grain; the clean refresh shows the real grey.
function Editor:stampLive(width, x0, y0, x1, y1, color)
    if color:getColor8().a == 0 then
        return self:stampInto({ self.page_bb, Screen.bb }, width, x0, y0, x1, y1, color)
    end
    self:stampInto({ self.page_bb }, width, x0, y0, x1, y1, color)
    self:stampStriped(width, x0, y0, x1, y1, 2)
end

-- Black on every `every`-th pixel row along a segment, on the screen only.
function Editor:stampStriped(width, x0, y0, x1, y1, every)
    local r = self.pageRect
    local left, top, right, bottom = r[1], r[2], r[1] + r[3], r[2] + r[4]
    local black = Blitbuffer.COLOR_BLACK
    Ink.segment(x0, y0, x1, y1, width, function(x, y, s)
        local sx, ex = math.max(x, left), math.min(x + s, right)
        if ex <= sx then return end
        for row = y + (every - y % every) % every, y + s - 1, every do
            if row >= top and row < bottom then Screen.bb:paintRect(sx, row, ex - sx, 1, black) end
        end
    end)
end

-- The highlighter's grey would not show in the fast refresh either: while
-- drawing, a band as wide as the highlighter, striped every third pixel
-- row; the clean refresh draws the real grey under the ink.
function Editor:previewHighlight(x0, y0, x1, y1, width)
    width = width or (self.stroke and self.stroke.w) or 20
    self:stampStriped(width, x0, y0, x1, y1, 3)
    self:markInk(x0, y0, x1, y1, width)
end

function Editor:penMove(x, y, width)
    if self.quickTap then return end
    if self.quickDrag then return self:dragQuick(y) end
    if self.stripDrag then return self:dragStrip(y) end
    if self.cardDrag then return self:dragClueCard(x, y) end
    if self.press then
        local p, slop = self.press, self.ui:u(8)
        if math.abs(x - p.x) > slop or math.abs(y - p.y) > slop then p.moved = true end
        p.lx, p.ly = x, y
        return
    end
    if self.erasing then
        local e = self.erasing
        if self.view then x, y = self:toPage(x, y) end
        self:eraseAlong(e.x, e.y, x, y)
        e.x, e.y = x, y
        return
    end
    if self.viewStroke then return self:viewPenMove(x, y, width) end
    if type(self.picking) == "table" then
        self.picking.x1, self.picking.y1 = x, y
        return self:previewPick()
    end
    if self.snapped then return end   -- snapped while held: the rest of the stroke is ignored
    if self.padIgnore then return end
    if self.padStroke then
        local p = self.padStroke.p
        local lx, ly = p[#p - 1], p[#p]
        if lx == x and ly == y then return end
        table.insert(p, x)
        table.insert(p, y)
        self:stampInto({ Screen.bb }, self.padStroke.w, lx, ly, x, y, Blitbuffer.COLOR_BLACK)
        self:markInk(lx, ly, x, y, self.padStroke.w)
        return
    end
    if self.zoomMove then return end
    if self.tapePress then
        local p, slop = self.tapePress, self.ui:u(8)
        if math.abs(x - p.x) > slop or math.abs(y - p.y) > slop then p.moved = true end
        return
    end
    if self.texting then
        self.texting.x1, self.texting.y1 = x, y
        return
    end
    local zx, zy
    if self.zoomStroke then
        zx, zy = x, y
        x, y = self:fromStrip(x, y)
        width = math.max(1, math.floor(width / self.zoomStroke.z + 0.5))
    end
    if self.shaping then
        local sh = self.shaping
        sh.x1, sh.y1 = x, y
        if sh.kind == "line" or sh.kind == "arrow" then
            if Settings.get("level_lines") then sh.x1, sh.y1 = Shapes.lockAngle(sh.x0, sh.y0, x, y) end
            sh.x1, sh.y1 = self:joinEnd(sh.x1, sh.y1)
        end
        self:previewShape()
        return
    end
    if self.drag then
        local d, sel = self.drag, self.sel
        if d.kind == "move" then
            sel.dx, sel.dy = d.dx + x - d.x, d.dy + y - d.y
        else
            local b = sel.box
            local s = math.max((x - (b[1] + sel.dx)) / math.max(1, b[3]), (y - (b[2] + sel.dy)) / math.max(1, b[4]))
            sel.s = math.max(0.2, math.min(5, s))
        end
        self:dragRefresh()
        return
    end
    if self.lasso then
        local p = self.lasso.p
        local lx, ly = p[#p - 1], p[#p]
        if math.abs(x - lx) + math.abs(y - ly) < self.ui:u(2) then return end
        table.insert(p, x)
        table.insert(p, y)
        -- A dotted line on the screen only.
        local dot, step = math.max(2, self.ui:u(1)), self.ui:u(3)
        local n = math.max(1, math.floor(math.max(math.abs(x - lx), math.abs(y - ly)) / step))
        for i = 1, n do
            local t = i / n
            Screen.bb:paintRect(math.floor(lx + (x - lx) * t), math.floor(ly + (y - ly) * t), dot, dot, Blitbuffer.COLOR_BLACK)
        end
        self:markInk(lx, ly, x, y, dot)
        return
    end
    local stroke = self.stroke
    if not stroke then return end
    local p = stroke.p
    local lx, ly = p[#p - 1], p[#p]
    if lx == x and ly == y then return end
    if Ink.tipOf(stroke).nib then width = Ink.nibWidth(width, x - lx, y - ly) end
    if self.zoomStroke then
        table.insert(p, x)
        table.insert(p, y)
        table.insert(stroke.q, width)
        if width > stroke.w then stroke.w = width end
        local z = self.zoomStroke
        self:stampZoom(Ink.segmentWidth(stroke, #stroke.q - 1), lx, ly, x, y, colorOf(stroke), z.sx, z.sy, zx, zy)
        z.sx, z.sy = zx, zy
        return
    end
    table.insert(p, x)
    table.insert(p, y)
    table.insert(stroke.q, width)
    if width > stroke.w then stroke.w = width end
    if Ink.tipOf(stroke).under then return self:previewHighlight(lx, ly, x, y, Ink.segmentWidth(stroke, #stroke.q - 1)) end
    self:holdLater(x, y)
    local segment = Ink.segmentWidth(stroke, #stroke.q - 1)
    self:stampLive(segment, lx, ly, x, y, colorOf(stroke))
    self:markInk(lx, ly, x, y, segment)
end

function Editor:penUp()
    if self.busy then self.penUpAt = time.now() end
    self.busy = false
    self.penTool = nil
    if self.quickTap then
        local b = self.quickTap
        self.quickTap = nil
        return self:quickButton(b.key)
    end
    if self.quickDrag then return self:dragQuick(nil, true) end
    if self.stripDrag then return self:dropStrip() end
    if self.cardDrag then return self:dropClueCard() end
    if self.press then
        local p = self.press
        self.press = nil
        -- A tap that slid a little but lifted on the button it started on
        -- still counts (the pen skids on the glass more than a finger does).
        local h = p.moved and p.lx and self:hitAt(p.x, p.y)
        if not p.moved or (h and self:hitAt(p.lx, p.ly) == h) then
            self:tapAt(p.x, p.y)
        elseif not self:hitAt(p.x, p.y) and (self.panel or self.pasteAt or self.drawAt) then
            -- The pen slid a little off a tap outside a panel: it closes too.
            self:tapAt(p.x, p.y)
        end
        return
    end
    if self.erasing then
        local erasing = self.erasing
        self.erasing = nil
        self:flushInk()
        if erasing.itemsGone then
            -- Items went too: one undo brings back everything erased.
            self:pushSnapshot(erasing.before)
        elseif #erasing.changes > 0 then
            self:pushUndo({ replace = erasing.changes })
            self:changed()
        elseif #erasing.removed > 0 then
            self:pushUndo({ erase = erasing.removed })
            self:changed()
        end
        self:updateTaskLines()
        return
    end
    if self.viewStroke then return self:endViewStroke() end
    if type(self.picking) == "table" then return self:endPick() end
    if self.holdTask then
        UIManager:unschedule(self.holdTask)
        self.holdTask = nil
    end
    if self.snapped then return self:endSnapped() end
    if self.padIgnore then
        self.padIgnore = nil
        return
    end
    if self.padStroke then
        table.insert(self.askPad.strokes, self.padStroke)
        self.padStroke = nil
        self:flushInk()
        return
    end
    if self.shaping then return self:endShape() end
    if self.zoomMove then
        local m = self.zoomMove
        self.zoomMove = nil
        local __, __, t = self:zoomGeometry()
        self.zoomAt = { m.x - math.floor(t[3] / 4), m.y - math.floor(t[4] / 2) }
        return self:repaint()
    end
    if self.tapePress then
        local p = self.tapePress
        self.tapePress = nil
        if not p.moved then self:toggleTape(p.it) end
        return
    end
    if self.texting then
        local t = self.texting
        self.texting = nil
        local hit = Items.at(self:pageItems(), t.x0, t.y0, "text")
        if hit then return self:editText(hit) end
        local r = self.pageRect
        local w = math.abs(t.x1 - t.x0)
        local x = math.min(t.x0, t.x1)
        if w < self.ui:u(40) then
            x = t.x0
            w = math.min(math.floor(r[3] * 0.6), r[1] + r[3] - x - self.ui:u(8))
        end
        return self:editText(nil, x, t.y0 - math.floor(self:textSize() / 2), math.max(self.ui:u(40), w))
    end
    if self.zoomStroke then
        local z = self.zoomStroke
        self:endStroke()
        self:flushInk()
        self.zoomStroke = nil
        -- Near the strip's end: the zoom box moves on along the line.
        if z.sx > z.strip[1] + z.strip[3] * 0.82 then self:zoomAdvance(0.6) end
        return
    end
    if self.drag then
        self.drag = nil
        if self.dragTask then UIManager:unschedule(self.dragTask) self.dragTask = nil end
        self.sel.dragging = nil
        self:repaint()
        return
    end
    if self.lasso then
        local lasso = self.lasso
        self.lasso = nil
        self:flushInk()
        local p = lasso.p
        local minX, minY, maxX, maxY = p[1], p[2], p[1], p[2]
        for i = 3, #p - 1, 2 do
            minX, maxX = math.min(minX, p[i]), math.max(maxX, p[i])
            minY, maxY = math.min(minY, p[i + 1]), math.max(maxY, p[i + 1])
        end
        local area = { minX - 4, minY - 4, maxX - minX + 8, maxY - minY + 8 }
        if maxX - minX < self.ui:u(8) and maxY - minY < self.ui:u(8) then
            -- A tap: paste here (when something was cut or copied, here or as
            -- text in another app).
            self:showArea(area)
            if clipboard or self:otherAppText() then
                self.pasteAt = { p[1], p[2] }
                self:repaint()
            end
            return
        end
        local picked = Ink.lassoed(self:strokes(), p)
        local items = {}
        for __, it in ipairs(self:pageItems()) do
            local bx, by, bw, bh = Items.box(it)
            if Ink.inside(p, bx + bw / 2, by + bh / 2) then table.insert(items, it) end
        end
        if #picked > 0 or #items > 0 then
            self:select(picked, items)
        else
            self:showArea(area)
            -- An empty area: Claude can draw in it. In a puzzle book it can be
            -- asked about (one line of a clue is enough).
            local puzzle = self.notebook.puzzle
            local minW, minH = self.ui:u(puzzle and 20 or 40), self.ui:u(puzzle and 10 or 30)
            if maxX - minX > minW and maxY - minY > minH and ((self.on_draw and not Settings.noAI()) or puzzle) then
                self.drawAt = { minX, minY, maxX - minX, maxY - minY }
                self:repaint()
            end
        end
        return
    end
    self:endStroke()
    self:flushInk()
end

-- The stroke kept (and undoable); its area cleaned up once the pen is still.
function Editor:endStroke()
    if self.viewStroke then return self:endViewStroke() end
    local stroke = self.stroke
    if not stroke then return end
    self.stroke = nil
    -- A clue outlined by a tap: gone at the next stroke.
    if self.outline then self:clearOutline() end
    -- A hint waiting for where: a tap says (the dot it made goes).
    if self.hintMode then
        local tx, ty, tw, th = Ink.box(stroke)
        if tw and tw <= self.ui:u(6) + stroke.w and th <= self.ui:u(6) + stroke.w then
            self:renderArea({ tx, ty, tw, th })
            self:cleanLater({ tx, ty, tw, th })
            self:hintTap(stroke.p[1], stroke.p[2])
            return
        end
    end
    -- A crossword's clue boxes: a tap ticks one, a line through ticks them.
    if self.notebook.feed and self:strokeOnBoxes(stroke) then return end
    -- A tap on an arrow above the clues turns them; on a clue's number (or a
    -- number in the grid), the clue's squares are outlined.
    if self.notebook.feed and self.on_clue_tap then
        local tx, ty, tw, th = Ink.box(stroke)
        if tw and tw <= self.ui:u(6) + stroke.w and th <= self.ui:u(6) + stroke.w
                and self.on_clue_tap(self, stroke.p[1], stroke.p[2]) then
            self:renderArea({ tx, ty, tw, th })
            self:cleanLater({ tx, ty, tw, th })
            return
        end
    end
    -- A tap on a checklist's printed box ticks it (or unticks it): the dot
    -- the tap made goes.
    local bx, by, bw, bh = Ink.box(stroke)
    if bw and bw <= self.ui:u(6) + stroke.w and bh <= self.ui:u(6) + stroke.w and self:toggleCheckbox(stroke.p[1], stroke.p[2]) then
        self:renderArea({ bx, by, bw, bh })
        self:cleanLater({ bx, by, bw, bh })
        return
    end
    -- A mark drawn over an empty checklist box (a tick, a cross, a scribble)
    -- becomes a clean tick there; in a ticked box it is left out.
    if bw and self:markInBox(stroke) then
        self:renderArea({ bx, by, bw, bh })
        self:cleanLater({ bx, by, bw, bh })
        return
    end
    local level = Settings.get("smooth") or 0
    if level > 0 and not Ink.tipOf(stroke).under and #stroke.p > 8 then
        -- Smoothed: the stroke as drawn goes from the page image, the smooth
        -- one is drawn there (the screen shows it at the clean refresh).
        local rx, ry, rw, rh = Ink.box(stroke)
        stroke = Shapes.smooth(stroke, level == 1 and 2 or 4)
        table.insert(self:strokes(), stroke)
        self:renderArea({ rx, ry, rw, rh })
        self:cleanLater({ rx, ry, rw, rh })
        self:pushUndo({ add = stroke })
        self:changed()
        return
    end
    table.insert(self:strokes(), stroke)
    self:updateTaskLines()
    local x, y, w, h = Ink.box(stroke)
    if Ink.tipOf(stroke).under then
        -- Drawn for real (under the ink) into the page image now; the
        -- screen shows it at the clean refresh.
        self:renderArea({ x, y, w, h })
    end
    self:cleanLater({ x, y, w, h })
    self:pushUndo({ add = stroke })
    self:changed()
end

-- ------------------------------------------------------------------ shapes

-- (x, y) moved onto ink nearby (a corner or end first), when Settings say so.
function Editor:joinEnd(x, y)
    if not Settings.get("join_ends") then return x, y end
    return Shapes.snapPoint(x, y, self:strokes(), self.ui:u(8))
end

-- The shape being dragged out, as strokes.
function Editor:shapeStrokes()
    local sh = self.shaping
    local t = self.tip ~= "pen" and self.tip or nil
    if sh.tape then return Shapes.make("rect", sh.x0, sh.y0, sh.x1, sh.y1, 2, nil) end
    local out = Shapes.make(sh.kind, sh.x0, sh.y0, sh.x1, sh.y1, sh.w, t,
        { rows = Settings.get("table_rows"), cols = Settings.get("table_cols") })
    local line = Settings.get("shape_line") or "solid"
    local fill = ({ light = 0xD8, dark = 0x98 })[Settings.get("shape_fill") or "none"]
    local closed = ({ rect = true, ellipse = true, triangle = true, diamond = true, star = true })[sh.kind]
    for i, s in ipairs(out) do
        s.c = self:shadeGrey(self.tip)
        if line ~= "solid" then s.d = line end
        if fill and closed and i == 1 then s.f = fill end
    end
    return out
end

-- The outline while dragging, on the screen only: the last one taken off
-- (the page image put back there), the new one drawn thin.
function Editor:previewShape()
    local old = self.previewArea
    if old then
        local r = self:clip(old)
        if r then Screen.bb:blitFrom(self.page_bb, r[1], r[2], r[1], r[2], r[3], r[4]) end
    end
    local strokes = self:shapeStrokes()
    local area = Ink.boxOf(strokes)
    local thin = math.max(2, self.ui:u(0.7))
    for __, s in ipairs(strokes) do
        local p = s.p
        for i = 1, #p - 3, 2 do self:stampInto({ Screen.bb }, thin, p[i], p[i + 1], p[i + 2], p[i + 3], Blitbuffer.COLOR_BLACK) end
    end
    self.previewArea = area
    local both = Ink.union(old, area)
    if both then self:markInk(both[1], both[2], both[1] + both[3], both[2] + both[4], 2) end
end

-- New strokes onto the page (undoable as one), drawn for real.
function Editor:addStrokes(new, before)
    local strokes = self:strokes()
    before = before or { unpack(strokes) }
    for __, s in ipairs(new) do table.insert(strokes, s) end
    self:pushUndo({ lists = { before = before, after = { unpack(strokes) } } })
    self:changed()
end

-- The pen lifted with a shape dragged out: the shape kept.
function Editor:endShape()
    local sh = self.shaping
    local new = self:shapeStrokes()
    self.shaping = nil
    local area = Ink.union(self.previewArea, Ink.boxOf(new))
    self.previewArea = nil
    local tiny = math.abs(sh.x1 - sh.x0) < 4 and math.abs(sh.y1 - sh.y0) < 4
    if sh.tape then
        -- Tape over what was dragged across.
        if not tiny then
            local before = self:snapshot()
            table.insert(self:pageItems(), { k = "tape", x = math.min(sh.x0, sh.x1), y = math.min(sh.y0, sh.y1),
                w = math.abs(sh.x1 - sh.x0), h = math.abs(sh.y1 - sh.y0), open = false })
            self:pushSnapshot(before)
        end
    elseif not tiny then self:addStrokes(new) end
    self:flushInk()
    if area then
        self:renderArea(area)
        self:showArea(area, "ui")
    end
end

-- The pen held still on a stroke for HOLD_TO_SNAP seconds: if the stroke
-- was meant as a line, circle, ellipse, rectangle or triangle it becomes
-- a clean one. (x, y) is where the pen is; small moves keep the timer.
function Editor:holdLater(x, y)
    if not Settings.get("snap_hold") then return end
    local a = self.holdAt
    if a and math.abs(x - a[1]) + math.abs(y - a[2]) < self.ui:u(3) and self.holdTask then return end
    self.holdAt = { x, y }
    if self.holdTask then UIManager:unschedule(self.holdTask) end
    self.holdTask = function()
        self.holdTask = nil
        self:snapStroke()
    end
    UIManager:scheduleIn(HOLD_TO_SNAP, self.holdTask)
end

local function averageWidth(stroke)
    if not stroke.q or #stroke.q == 0 then return stroke.w end
    local sum = 0
    for __, w in ipairs(stroke.q) do sum = sum + w end
    return math.max(1, math.floor(sum / #stroke.q + 0.5))
end

-- The strokes a hand-drawn stroke snaps to, or nil (writing, a scribble).
function Editor:snapped_(stroke)
    local r = Shapes.recognize(stroke.p)
    if not r then return nil end
    if r.kind == "line" then
        r.x0, r.y0 = self:joinEnd(r.x0, r.y0)
        if Settings.get("level_lines") then r.x1, r.y1 = Shapes.lockAngle(r.x0, r.y0, r.x1, r.y1) end
        r.x1, r.y1 = self:joinEnd(r.x1, r.y1)
        return Shapes.make("line", r.x0, r.y0, r.x1, r.y1, averageWidth(stroke), stroke.t)
    end
    return Shapes.fromRecognized(r, averageWidth(stroke), stroke.t)
end

function Editor:snapStroke()
    local stroke = self.stroke
    if not stroke or Ink.tipOf(stroke).under then return end
    local new = self:snapped_(stroke)
    if not new then return end
    -- In the pen's shade, as written.
    for __, s in ipairs(new) do s.c = stroke.c end
    -- The rough stroke stays undoable: one undo brings it back.
    self.stroke = nil
    self.snapped = { rough = stroke, new = new }
    local strokes = self:strokes()
    table.insert(strokes, stroke)
    self:pushUndo({ add = stroke })
    local before = { unpack(strokes) }
    table.remove(strokes)
    for __, s in ipairs(new) do table.insert(strokes, s) end
    self:pushUndo({ lists = { before = before, after = { unpack(strokes) } } })
    self:changed()
    local x, y, w, h = Ink.box(stroke)
    local area = Ink.union({ x, y, w, h }, Ink.boxOf(new))
    area = self:renderArea(area)
    if area then
        Screen.bb:blitFrom(self.page_bb, area[1], area[2], area[1], area[2], area[3], area[4])
        self:markInk(area[1], area[2], area[1] + area[3], area[2] + area[4], 1)
        self:cleanLater(area)
    end
end

function Editor:endSnapped()
    self.snapped = nil
    self:flushInk()
end

-- The lasso's To text: the selected ink read by Claude.
-- The selected ink and items replaced by typed `text` where they are.
function Editor:replaceWithText(sel, text)
    if not text or not text:find("%S") then return end
    local view = sel.view or {}
    local x, y, w
    local b = Ink.boxOf(view)
    if b then x, y, w = b[1], b[2], b[3] else x, y, w = sel.box[1] + sel.dx, sel.box[2] + sel.dy, sel.box[3] end
    if self.sel == sel then self.sel = nil end
    local before = self:snapshot()
    local strokes, items = self:strokes(), self:pageItems()
    local gone = {}
    for __, s in ipairs(sel.strokes) do gone[s] = true end
    for __, s in ipairs(view) do gone[s] = true end
    for i = #strokes, 1, -1 do
        if gone[strokes[i]] then table.remove(strokes, i) end
    end
    for i = #items, 1, -1 do
        if sel.itemSet[items[i]] then table.remove(items, i) end
    end
    table.insert(items, { k = "text", x = math.floor(x), y = math.floor(y), w = math.max(self.ui:u(80), math.floor(w)),
        size = self:textSize(), text = text })
    self:pushSnapshot(before)
    self:renderPage()
    self:repaint()
end

function Editor:selectionToText()
    if not self.sel or not self.on_text_png then return end
    local sel = self.sel
    local strokes = self:selectionView()
    local path = DataStorage:getDataDir() .. "/cache/notes-selection.png"
    require("util").makePath(DataStorage:getDataDir() .. "/cache")
    local ok = Editor.pagePNG(self.notebook, self.page, path, { strokes = strokes, long = 1568 })
    if not ok then return end
    local f = io.open(path, "rb")
    local png = f and f:read("*a")
    if f then f:close() end
    os.remove(path)
    if png then
        self.on_text_png(png, self.notebook.name .. " selection", function(text) self:replaceWithText(sel, text) end)
    end
end

-- The lasso's Style: the selected ink's pen, thickness, shade and line.
local STYLE_SHADES = { "default", "dark", "light" }
function Editor:styleSelection()
    local sel = self.sel
    if not sel or #sel.strokes == 0 then return end
    local function apply(fn)
        if self.sel ~= sel then return end
        local before = self:snapshot()
        local strokes = self:strokes()
        local at = {}
        for i, s in ipairs(strokes) do at[s] = i end
        sel.set = {}
        for i, s in ipairs(sel.strokes) do
            local new = { t = s.t, c = s.c, d = s.d, f = s.f, ck = s.ck, w = s.w, p = s.p, q = s.q }
            fn(new, s)
            if at[s] then strokes[at[s]] = new end
            sel.strokes[i] = new
            sel.set[new] = true
        end
        sel.view, sel.viewKey = nil, nil
        if sel.image then sel.image:free() end
        sel.image = nil
        self:pushSnapshot(before)
        self:renderPage()
        self:repaint()
    end
    local function width(s, tip, size)
        local w = Ink.tipWidth(tip, size, nil, self.scale)
        local f = w / math.max(1, s.w)
        local q
        if s.q then
            q = {}
            for k, v in ipairs(s.q) do q[k] = math.max(1, math.floor(v * f + 0.5)) end
        end
        return w, q
    end
    local dialog
    local function rowOf(label, choices)
        local row = {}
        for __, c in ipairs(choices) do
            table.insert(row, { text = c[1], callback = function()
                UIManager:close(dialog)
                apply(c[2])
            end })
        end
        return row
    end
    local tips = {}
    for __, tip in ipairs(Ink.PEN_TIPS) do
        if tip ~= "shader" then
            table.insert(tips, { TIP_NAMES[tip], function(new, s)
                new.t = tip ~= "pen" and tip or nil
                local size = 2
                local def = Ink.TIPS[s.t or "pen"] or Ink.TIPS.pen
                for k, v in ipairs(def.sizes) do
                    if v * self.scale <= s.w + 0.5 then size = k end
                end
                new.w, new.q = width(s, tip, size)
            end })
        end
    end
    local buttons = {}
    for i = 1, #tips, 4 do
        local row = {}
        for k = i, math.min(i + 3, #tips) do table.insert(row, tips[k]) end
        table.insert(buttons, rowOf(nil, row))
    end
    local sizes = {}
    for size = 1, 5 do
        table.insert(sizes, { T(_("Thickness %1"), size), function(new, s) new.w, new.q = width(s, s.t or "pen", size) end })
    end
    table.insert(buttons, rowOf(nil, sizes))
    local shades = {}
    local shadeNames = { default = _("Black"), dark = _("Dark grey"), light = _("Light grey") }
    for __, sh in ipairs(STYLE_SHADES) do
        table.insert(shades, { shadeNames[sh], function(new) new.c = sh ~= "default" and Ink.SHADES[sh] or nil end })
    end
    table.insert(buttons, rowOf(nil, shades))
    table.insert(buttons, rowOf(nil, {
        { _("Solid"), function(new) new.d = nil end },
        { _("Dashed"), function(new) new.d = "dash" end },
        { _("Dotted"), function(new) new.d = "dot" end },
    }))
    table.insert(buttons, { { text = _("Close"), callback = function() UIManager:close(dialog) end } })
    dialog = KO.buttonDialog{ title = _("Style: pen, thickness, shade, line"), title_align = "center", buttons = buttons }
end

-- The lasso's Snap shapes: every selected stroke that was meant as a
-- shape made clean (the rest left as they are).
function Editor:snapSelection()
    local sel = self.sel
    if not sel then return end
    -- After letting go, the selected strokes are the moved copies if the
    -- selection moved, else the strokes themselves.
    local moved = sel.dx ~= 0 or sel.dy ~= 0 or sel.s ~= 1
    local view = moved and self:selectionView() or sel.strokes
    self:commitSelection()
    local strokes = self:strokes()
    local before = { unpack(strokes) }
    local index = {}
    for i, s in ipairs(strokes) do index[s] = i end
    local count = 0
    for __, s in ipairs(view) do
        local i = index[s]
        local new = i and self:snapped_(s)
        if new then
            strokes[i] = new[1]
            for k = 2, #new do table.insert(strokes, new[k]) end
            count = count + 1
        end
    end
    if count == 0 then
        KO.toast(_("No shapes to snap"))
        return
    end
    self:pushUndo({ lists = { before = before, after = { unpack(strokes) } } })
    self:changed()
    self:renderPage()
    self:repaint()
    KO.toast(T(_("Snapped %1"), count))
end

-- A clean ("ui") refresh waits for the screen's previous updates on the
-- Kindle, so it never runs while writing: once, CLEAN_AFTER seconds after
-- the pen was last on the page, for everything written since.
function Editor:cleanLater(area)
    self.cleanArea = Ink.union(self.cleanArea, area)
    if self.cleanTask then UIManager:unschedule(self.cleanTask) end
    self.cleanTask = function()
        self.cleanTask = nil
        if self.stroke or self.erasing then return self:cleanLater(nil) end
        local clean = self.cleanArea
        self.cleanArea = nil
        -- Something opened over the page since (the page list, a menu): it is
        -- drawn again in full when the page is back on top.
        if not self:onTop() then clean = nil end
        if clean then
            -- Every few pauses the clean refresh flashes, clearing the ghosts fast refreshes leave on e-ink.
            self.cleanCount = (self.cleanCount or 0) + 1
            local every = Settings.get("deghost") or 6
            local flash = self.erasedSinceClean or (every > 0 and self.cleanCount % every == 0)
            self.erasedSinceClean = false
            -- ("full": on the Scribe "flashui" doesn't clear ghosting.)
            self:showArea(clean, flash and "full" or "ui")
            if self.zoomOn then
                local strip = self:zoomGeometry()
                self:repaint({ strip[1], strip[2] - 3, self.pageRect[3], strip[4] + 6 })
            end
        end
        if self.toolbarStale then
            self.toolbarStale = false
            self:refreshToolbar()
        end
    end
    UIManager:scheduleIn(CLEAN_AFTER, self.cleanTask)
end

-- The fast refresh, at most every INK_REFRESH seconds.
function Editor:markInk(x0, y0, x1, y1, w)
    local pad = w
    local area = { math.min(x0, x1) - pad, math.min(y0, y1) - pad, math.abs(x1 - x0) + 2 * pad, math.abs(y1 - y0) + 2 * pad }
    self.inkArea = Ink.union(self.inkArea, area)
    if not self.inkScheduled then
        self.inkScheduled = true
        self.inkTask = function() self:flushInk() end
        UIManager:scheduleIn(INK_REFRESH, self.inkTask)
    end
end

function Editor:flushInk()
    if self.inkScheduled then UIManager:unschedule(self.inkTask) end
    self.inkScheduled = false
    local area = Ink.clip(self.inkArea, self.w, self.h)
    self.inkArea = nil
    -- Erasing: "fast" (it takes grey ink, a pencil's, to white; "a2" only
    -- turns black to white, so grey ink would stay until the clean refresh).
    local mode = self.inkFast and "fast" or "a2"
    self.inkFast = nil
    if area then
        UIManager:setDirty(nil, function() return mode, Geom:new{ x = area[1], y = area[2], w = area[3], h = area[4] } end)
    end
end

-- What the eraser touches at (x, y) goes: exactly the ink under it, or
-- (Eraser: Whole strokes) every stroke it touches. Returns the area changed.
function Editor:eraseAt(x, y, radius)
    local strokes = self:strokes()
    local whole = Settings.get("whole_eraser")
    local hlOnly = Settings.get("eraser_hl")
    local area
    for i = #strokes, 1, -1 do
        local stroke = strokes[i]
        if hlOnly and not Ink.isHighlight(stroke) then
            -- Highlighter only: the ink stays.
        elseif whole then
            if Ink.hits(stroke, x, y, radius) then
                table.remove(strokes, i)
                table.insert(self.erasing.removed, { index = i, stroke = stroke })
                local bx, by, bw, bh = Ink.box(stroke)
                area = Ink.union(area, { bx, by, bw, bh })
            end
        else
            local pieces = Ink.eraseCircle(stroke, x, y, radius)
            if pieces then
                table.remove(strokes, i)
                for k, piece in ipairs(pieces) do table.insert(strokes, i + k - 1, piece) end
                table.insert(self.erasing.changes, { index = i, old = stroke, new = pieces })
                local bx, by, bw, bh = Ink.box(stroke)
                area = Ink.union(area, { bx, by, bw, bh })
            end
        end
    end
    -- A crossword's ticked clue boxes it passes over are unticked.
    if self.notebook.feed and not hlOnly then
        local first = self:puzzleFirst()
        for __, b in ipairs(first and first.ticks and self:clueBoxes() or {}) do
            if first.ticks and first.ticks[b[4]] and x + radius >= b[1] and x - radius < b[1] + b[3]
                    and y + radius >= b[2] and y - radius < b[2] + b[3] then
                first.ticks[b[4]] = nil
                if not next(first.ticks) then first.ticks = nil end
                local pad = math.ceil(b[3] * 0.2)
                area = Ink.union(area, { math.floor(b[1]) - pad, math.floor(b[2]) - pad, math.ceil(b[3]) + 2 * pad, math.ceil(b[3]) + 2 * pad })
                self:changed()
                if self.countRect then self:repaint(self.countRect) end
            end
        end
    end
    -- Text boxes, pictures and tape it passes over go whole.
    local items = hlOnly and {} or self:pageItems()
    for i = #items, 1, -1 do
        local bx, by, bw, bh = Items.box(items[i])
        if x + radius >= bx and x - radius < bx + bw and y + radius >= by and y - radius < by + bh then
            table.remove(items, i)
            self.erasing.itemsGone = true
            area = Ink.union(area, { bx, by, bw, bh })
        end
    end
    return area
end

-- The eraser moved from (x0, y0) to (x1, y1): erased along the way (a fast
-- swipe leaves no unerased gaps), then that area drawn again.
function Editor:eraseAlong(x0, y0, x1, y1)
    self.erasedSinceClean = true
    local radius = self.pen and self.eraserRadius or math.floor(Ink.ERASER_SIZES[self.eraserSize] * self.scale + 0.5)
    if self.view then radius = math.max(1, math.floor(radius / self.view.z + 0.5)) end
    local dx, dy = x1 - x0, y1 - y0
    local steps = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(dy)) / math.max(1, radius / 2)))
    local area
    for i = 0, steps do
        local t = i / steps
        area = Ink.union(area, self:eraseAt(math.floor(x0 + dx * t + 0.5), math.floor(y0 + dy * t + 0.5), radius))
    end
    if area then
        area = self:renderArea(area)
        if area then
            Screen.bb:blitFrom(self.page_bb, area[1], area[2], area[1], area[2], area[3], area[4])
            self.inkArea = Ink.union(self.inkArea, area)
            self.inkFast = true
            if not self.inkScheduled then
                self.inkScheduled = true
                self.inkTask = function() self:flushInk() end
                UIManager:scheduleIn(INK_REFRESH, self.inkTask)
            end
            self:cleanLater(area)
        end
    end
end

-- ------------------------------------------------------------------ undo, pages

function Editor:pushUndo(action)
    action.page = self.page
    action.at = os.time()
    -- Undo turning on (or Redo off) shows on the toolbar; while writing that
    -- waits for the pen to be still (a clean refresh would hold up the ink).
    local buttonsChange = #self.undo == 0 or #self.redo > 0
    table.insert(self.undo, action)
    if #self.undo > 200 then table.remove(self.undo, 1) end
    self.redo = {}
    if buttonsChange then
        if self.stroke or self.erasing or self.cleanTask then
            self.toolbarStale = true
        else
            self:refreshToolbar()
        end
    end
end

local function apply(self, action, forward)
    local page = self.notebook.pages[action.page]
    local strokes = page and page.strokes
    if not strokes then return end
    if action.lists then
        local target = forward and action.lists.after or action.lists.before
        if target.strokes then
            page.strokes = { unpack(target.strokes) }
            page.items = { unpack(target.items or {}) }
        else
            page.strokes = { unpack(target) }
        end
    elseif action.replace then
        if forward then
            for __, c in ipairs(action.replace) do
                table.remove(strokes, c.index)
                for k, piece in ipairs(c.new) do table.insert(strokes, c.index + k - 1, piece) end
            end
        else
            -- Latest first: each change undone where it happened.
            for k = #action.replace, 1, -1 do
                local c = action.replace[k]
                for __ = 1, #c.new do table.remove(strokes, c.index) end
                table.insert(strokes, c.index, c.old)
            end
        end
    elseif action.add then
        if forward then
            table.insert(strokes, action.add)
        else
            for i = #strokes, 1, -1 do
                if strokes[i] == action.add then table.remove(strokes, i) break end
            end
        end
    else
        if forward then
            for __, e in ipairs(action.erase) do
                for i = #strokes, 1, -1 do
                    if strokes[i] == e.stroke then table.remove(strokes, i) break end
                end
            end
        else
            -- Back where they were, earliest first.
            for i = #action.erase, 1, -1 do
                local e = action.erase[i]
                table.insert(strokes, math.min(e.index, #strokes + 1), e.stroke)
            end
        end
    end
    if action.page ~= self.page then self.page = action.page end
    self:renderPage()
    self:changed()
end

function Editor:doUndo()
    self:commitSelection()
    local action = table.remove(self.undo)
    if not action then return end
    apply(self, action, false)
    table.insert(self.redo, action)
    self:repaint()
end

-- A toolbar group's list: its tools (tap the one in use again for its
-- options) and actions.
function Editor:paintGroup(bb, x, y, pw, name)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    local def = Settings.GROUPS[name] or {}
    ui:drawText(bb, def.label or name, x + u(10), y + u(16), 10, { bold = true })
    if name == "tidy" then
        ui:drawText(bb, self.sel and _("The selection") or _("This page"), x + pw - u(10), y + u(16), 8.5,
            { align = "right", color = UI.GREY_TEXT })
    end
    for i, key in ipairs(Settings.groups()[name] or {}) do
        local ry = y + u(30) + (i - 1) * u(30)
        local on = Settings.TOOLS[key] and self.tool == key
        if on then ui:box(bb, x + u(6), ry + u(2), pw - u(12), u(26), { fill = UI.BLACK, r = u(5) }) end
        ui:drawIcon(bb, toolIcon(self, key) or "ellipsis", x + u(12), ry + u(7), u(16), on)
        ui:drawText(bb, Settings.buttonName(key), x + u(36), ry + u(15), 10, { color = on and UI.WHITE or UI.BLACK, bold = on or nil })
        self:hit(x, ry, pw, u(30), function()
            self.panel = nil
            if Settings.TOOLS[key] then
                self:repaint()
                self:pickTool(key)
            else
                self:runAction(key)
            end
        end)
    end
end

--- Tidy handwriting (notestidy.lua): the selection's, else the page's.
-- `which`: { level, upright, size, space }. One undo puts it back.
function Editor:tidy(which)
    local only
    local sel = self.sel
    if sel then
        local moved = sel.dx ~= 0 or sel.dy ~= 0 or sel.s ~= 1
        local view = moved and self:selectionView() or sel.strokes
        self:commitSelection()
        only = {}
        for __, s in ipairs(view) do only[s] = true end
    end
    local strokes = self:strokes()
    local paper = self:paper()
    local gap = RULED[paper] and not self:background() and Paper.gap(paper) or nil
    local out, moved = require("notestidy").apply(strokes, which, {
        gap = gap,
        rule = gap and { first = 2 * gap, step = gap } or nil,
        skip = function(s) return (only ~= nil and not only[s]) or Ink.tipOf(s).under == true or s.f ~= nil or s.d ~= nil end,
    })
    if moved == 0 then return KO.toast(_("Nothing to tidy")) end
    local before = { unpack(strokes) }
    for i, s in ipairs(out) do strokes[i] = s end
    self:pushUndo({ lists = { before = before, after = { unpack(strokes) } } })
    self:changed()
    self:renderPage()
    self:repaint()
    KO.toast(moved == 1 and _("Tidied 1 word") or T(_("Tidied %1 words"), moved))
end

--- The ⋯ menu's first rows: the tools taken off the toolbar (Settings >
-- Toolbar > Toolbar buttons…), and All pages and + page when they are.
function Editor:hiddenToolRows()
    local rows = {}
    for __, key in ipairs(Settings.hiddenTools()) do
        table.insert(rows, { toolIcon(self, key) or "ellipsis", Settings.buttonName(key), self.tool == key and _("On") or nil, function()
            self.panel = nil
            self:repaint()
            self:pickTool(key)
        end })
    end
    local pb = Settings.get("page_buttons") or {}
    if pb.pages == false then
        table.insert(rows, { "layout-grid", _("All pages"), nil, function() self.panel = nil self:showOverview() end })
    end
    if pb.addpage == false then
        table.insert(rows, { "file-plus", _("Add page"), nil, function() self.panel = nil self:addPage() end })
    end
    if #rows > 0 then table.insert(rows, "-") end
    return rows
end

--- What an undo step did, in a word or two.
local function stepName(action)
    if action.add then return action.add.t == "hl" and _("Highlight") or _("Writing") end
    if action.erase or action.replace then return _("Erasing") end
    local l = action.lists
    if not l then return _("Change") end
    local function counts(t)
        if t.strokes then return #t.strokes, #(t.items or {}) end
        return #t, nil
    end
    local s0, i0 = counts(l.before)
    local s1, i1 = counts(l.after)
    if i0 and i1 and i1 > i0 then return _("Added to the page") end
    if (i0 and i1 and i1 < i0) or s1 < s0 then return _("Removed") end
    if s1 > s0 then return _("Writing") end
    return _("Moved or changed")
end

-- As many steps as fit the screen's height.
function Editor:historyRows()
    return math.max(3, math.min(14, math.floor((self.h - self.ui:u(60)) / self.ui:u(28))))
end

-- Held Undo: the last steps, newest first; tapping one undoes back to
-- before it (Redo brings them back).
function Editor:paintHistory(bb, x, y, pw)
    local ui = self.ui
    local u = function(n) return ui:u(n) end
    ui:drawText(bb, _("Undo history"), x + u(10), y + u(16), 10, { bold = true })
    ui:drawText(bb, _("Tap to go back"), x + pw - u(10), y + u(16), 8.5, { align = "right", color = UI.GREY_TEXT })
    local now = os.time()
    for k = 1, math.min(#self.undo, self:historyRows()) do
        local action = self.undo[#self.undo - k + 1]
        local ry = y + u(30) + (k - 1) * u(28)
        ui:line(bb, x + u(8), ry, pw - u(16), 1)
        local ago = action.at and now - action.at or 0
        local when = ago < 60 and _("just now") or ago < 3600 and T(_("%1 min ago"), math.floor(ago / 60))
            or T(_("%1 h ago"), math.floor(ago / 3600))
        ui:drawText(bb, stepName(action), x + u(12), ry + u(14), 10)
        ui:drawText(bb, T(_("p. %1 · %2"), action.page, when), x + pw - u(10), ry + u(14), 8.5,
            { align = "right", color = UI.GREY_TEXT })
        self:hit(x, ry, pw, u(28), function()
            self.panel = nil
            self:undoSteps(k)
        end)
    end
end

--- `n` steps undone at once (one refresh).
function Editor:undoSteps(n)
    self:commitSelection()
    for __ = 1, n do
        local action = table.remove(self.undo)
        if not action then break end
        apply(self, action, false)
        table.insert(self.redo, action)
    end
    self:repaint(nil, "full")
    KO.toast(n == 1 and _("Undid 1 step") or T(_("Undid %1 steps"), n))
end

function Editor:doRedo()
    self:commitSelection()
    local action = table.remove(self.redo)
    if not action then return end
    apply(self, action, true)
    table.insert(self.undo, action)
    self:repaint()
end

function Editor:goPage(page)
    if page < 1 or page > #self.notebook.pages or page == self.page then return end
    self:commitSelection()
    self.pasteAt = nil
    -- A crossword's next clues under the same grid: the grid's writing goes
    -- along, and only what changed is drawn again (no flash).
    local clues = self:sameGrid(self.page, page)
    self:shareGrid(self.page)
    self:saveNow()
    -- A clean refresh waiting for the last page is not needed: all of it is drawn.
    if self.cleanTask then UIManager:unschedule(self.cleanTask) self.cleanTask = nil end
    self.cleanArea = nil
    self.page = page
    self.ticks = nil
    self:renderPage()
    UIManager:setDirty(self, clues and "partial" or "full")
    if self.on_page then self.on_page(self) end
    self.ticks = self.ticks or (self.on_tick and self:tickState()) or nil
end

--- A crossword's clue page `dir` (1 or -1) from this one (under the same
-- grid), or nil.
function Editor:cluePage(dir)
    local key, part = Crossword.keyPart(self.notebook.pages[self.page])
    local prefix, n = (part or ""):match("^(L?)(%d+)$")
    if not n then return nil end
    return (Crossword.pageOf(self.notebook, key, prefix .. (tonumber(n) + dir)))
end

-- Whether pages i and j are clue pages of one crossword under the same grid.
function Editor:sameGrid(i, j)
    local pages = self.notebook.pages
    local k1, p1 = Crossword.keyPart(pages[i])
    local k2, p2 = Crossword.keyPart(pages[j])
    return k1 ~= nil and k1 == k2 and p1:match("^L?%d+$") ~= nil and p2:match("^L?%d+$") ~= nil
        and (p1:sub(1, 1) == "L") == (p2:sub(1, 1) == "L") and self.on_grid ~= nil
        and self.on_grid(self, i) ~= nil and self.on_grid(self, j) ~= nil
end

--- A crossword's grid writing on page `i` put on its other clue pages
-- (under the same grid), so it is the same on all of them. Their undo
-- steps go (they would undo the wrong strokes).
function Editor:shareGrid(i)
    if not (self.notebook.feed and self.on_grid and not self.discard) then return end
    local pages = self.notebook.pages
    local from = pages[i]
    local g = from and self.on_grid(self, i)
    if not g then return end
    local text
    for j, page in ipairs(pages) do
        if j ~= i and self:sameGrid(i, j) then
            local g2 = self.on_grid(self, j)
            text = text or Crossword.gridText(from, g)
            if Crossword.gridText(page, g2) ~= text then
                Crossword.carryGrid(from, page, g, g2)
                self.revs = self.revs or {}
                self.revs[page.id] = (self.revs[page.id] or 0) + 1
                for __, list in ipairs({ self.undo, self.redo }) do
                    for k = #list, 1, -1 do
                        if list[k].page == j then table.remove(list, k) end
                    end
                end
                self:changed()
            end
        end
    end
end

function Editor:addPage()
    self:commitSelection()
    table.insert(self.notebook.pages, self.page + 1, { id = self.store.newPageId(), created = os.time(), strokes = {} })
    self.undo, self.redo = {}, {}
    self:changed()
    self:goPage(self.page + 1)
end

-- A template for this page only, or (the default) every page.
function Editor:setPaper(kind)
    local nb = self.notebook
    if self.paperScope == "page" then
        nb.pages[self.page].paper = kind ~= nb.paper and kind or nil
    else
        nb.paper = kind
        for __, page in ipairs(nb.pages) do page.paper = nil end
    end
    self:renderPage()
    self:repaint()
    self:changed()
end

-- ------------------------------------------------------------------ the menu's actions

-- Portrait to landscape or back, for the whole notebook: the ink stays
-- where it is (from the top left corner); ink past the new edge is kept
-- and shows again when turned back.
-- The four ways round, as KOReader names them (its rotation modes).
local ORIENTATIONS = { { 0, _("Portrait") }, { 1, _("Landscape") }, { 2, _("Inverted portrait") }, { 3, _("Inverted landscape") } }

function Editor:orientationName()
    local mode = Screen:getRotationMode()
    for __, o in ipairs(ORIENTATIONS) do
        if o[1] == mode then return o[2] end
    end
    return self.w > self.h and _("Landscape") or _("Portrait")
end

-- ⋯ > Page orientation: one of the four. The other way up, the page just
-- turns; from portrait to landscape or back, `turn(landscape, mode)` lays
-- the pages out again.
function Editor:chooseOrientation(turn)
    local now = Screen:getRotationMode()
    local dialog
    local buttons = {}
    for __, o in ipairs(ORIENTATIONS) do
        table.insert(buttons, { { text = o[2], enabled = o[1] ~= now, callback = function()
            UIManager:close(dialog)
            self:commitSelection()
            if (o[1] % 2 == 1) == (self.w > self.h) then
                self:rotate(o[1])
                UIManager:setDirty(self, "full")
            else
                turn(o[1] % 2 == 1, o[1])
            end
        end } })
    end
    dialog = KO.buttonDialog{ title = _("Page orientation"), buttons = buttons }
end

-- The Kindle turned to `mode` (turned back when the notebook closes).
function Editor:rotate(mode)
    if self.on_rotate then return self.on_rotate(mode) end
    Screen:setRotationMode(mode)
end

function Editor:turnNotebook()
    self:commitSelection()
    local nb = self.notebook
    local w, h = nb.width or 0, nb.height or 0
    if w <= 0 or h <= 0 then w, h = self.w, self.h end
    nb.width, nb.height = h, w
    self.dirty = true
    self:saveNow()
    if self.on_turn then self.on_turn(nb, self.page) end
end

function Editor:clearPage()
    self:commitSelection()
    local strokes = self:strokes()
    local removed = {}
    for i, stroke in ipairs(strokes) do removed[i] = { index = i, stroke = stroke } end
    for i = #strokes, 1, -1 do strokes[i] = nil end
    self:pushUndo({ erase = removed })
    self:renderPage()
    UIManager:setDirty(self, "partial")
    self:changed()
end

-- The writing on page i taken away (the puzzle list's Clear writing).
function Editor:clearPageAt(i)
    if i == self.page then return self:clearPage() end
    local page = self.notebook.pages[i]
    page.strokes = {}
    self.revs = self.revs or {}
    self.revs[page.id] = (self.revs[page.id] or 0) + 1
    self:changed()
end

function Editor:deletePage()
    KO.confirm{
        text = T(_("Delete page %1 of %2? You can restore it from the page list for 30 days."), self.page, #self.notebook.pages),
        danger = true,
        ok = _("Delete"),
        onOk = function()
            dropSelection(self.sel)
            self.sel = nil
            if #self.notebook.pages < 2 then return end
            self:deletePageAt(self.page)
        end,
    }
end

function Editor:reorderPages()
    self:commitSelection()
    local items = {}
    for i, page in ipairs(self.notebook.pages) do
        local n = #page.strokes
        table.insert(items, {
            text = T(_("Page %1"), i) .. (i == self.page and _(" (this page)") or ""),
            key = i,
            mandatory = n == 0 and _("blank") or nil,
        })
    end
    Settings.reorder(_("Reorder pages"), items, function(keys)
        local old, pages, current = self.notebook.pages, {}, self.page
        for i, k in ipairs(keys) do
            pages[i] = old[k]
            if k == self.page then current = i end
        end
        self.notebook.pages = pages
        self.page = current
        self.undo, self.redo = {}, {}
        self:renderPage()
        self:repaint()
        self:changed()
    end)
end

function Editor:rename()
    -- Notes' Rename box (with Suggest name) when it gives one.
    if self.on_rename then return self.on_rename(self) end
    -- (The launcher's box when it's there, else KOReader's: KO.ask.)
    KO.ask{ title = _("Rename notebook"), text = self.notebook.name, ok = _("Save"), done = function(name)
        self.notebook.name = name
        self:changed()
    end }
end

-- A notebook made from a PDF as a copy of the PDF with the ink added as
-- PDF ink annotations, in koreader/notes/export/.
function Editor:exportPDF()
    self:commitSelection()
    self:saveNow()
    local util = require("util")
    local folder = DataStorage:getDataDir() .. "/notes/export"
    util.makePath(folder)
    local dest = folder .. "/" .. util.getSafeFilename(self.notebook.name) .. ".pdf"
    local msg = KO.wait(_("Writing the PDF…"))
    UIManager:forceRePaint()
    local n, why = PDF.exportWithInk(self.notebook.pdfPath, dest, self.notebook, self.w, self.h)
    UIManager:close(msg)
    if not n then
        KO.message(T(_("Could not write the PDF:\n%1"), tostring(why)))
        return
    end
    local own = 0
    for __, page in ipairs(self.notebook.pages) do
        if not page.bg and #page.strokes > 0 then own = own + 1 end
    end
    local text = T(_("Saved to\n%1"), dest)
    if own > 0 then text = text .. "\n\n" .. T(_("%1 pages added in Notes are not in the PDF: use Export all pages for them."), own) end
    KO.message(text)
end

-- Export: pictures, a PDF, text.
function Editor:showExport()
    self:commitSelection()
    self:saveNow()
    local dialog
    local function act(fn) return function() UIManager:close(dialog) fn() end end
    local buttons = {
        { { text = _("This page as a picture (PNG)"), align = "left", callback = act(function() self:export(false) end) } },
        { { text = _("All pages as pictures (PNG)"), align = "left", callback = act(function() self:export(true) end) } },
        { { text = _("The notebook as a PDF"), align = "left", callback = act(function() self:exportPagesPDF() end) } },
    }
    if self.notebook.pdf then
        table.insert(buttons, { { text = _("The PDF with my writing added (annotations)"), align = "left", callback = act(function() self:exportPDF() end) } })
    end
    if not Settings.noAI() then
        table.insert(buttons, { { text = _("This page as text (AI)"), align = "left", callback = act(function()
            self:saveNow()
            if self.on_text then self.on_text(self.notebook, self.page) end
        end) } })
        table.insert(buttons, { { text = _("The notebook as text (AI)"), align = "left", callback = act(function()
            self:saveNow()
            if self.on_text_all then self.on_text_all(self.notebook) end
        end) } })
    end
    table.insert(buttons, { { text = _("Close"), callback = act(function() end) } })
    dialog = KO.buttonDialog{
        title = T(_("Export %1\nFiles go to koreader/notes/export/"), self.notebook.name),
        title_align = "center",
        buttons = buttons,
    }
end

-- Every page as a picture in one PDF (what the page shows: paper, PDF page,
-- ink, text and pictures), in koreader/notes/export/.
--- A notebook as a PDF (each page as a picture, writing, template and PDF
-- page behind it as on the screen): its bytes, and how many pages.
function Editor.notebookPDF(notebook)
    local util = require("util")
    local w, h = notebook.width or 0, notebook.height or 0
    if w <= 0 or h <= 0 then w, h = Screen:getWidth(), Screen:getHeight() end
    local tmp = DataStorage:getDataDir() .. string.format("/cache/notes-page-%d.jpg", math.random(0, 99999))
    util.makePath(DataStorage:getDataDir() .. "/cache")
    local r = setmetatable({ notebook = notebook, page = 1, w = w, h = h, scale = Screen:getDPI() / 300,
        pageRect = { 0, 0, w, h } }, { __index = Editor })
    local pictures = {}
    local done, err = pcall(function()
        for i = 1, #notebook.pages do
            r.page = i
            r.page_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
            r:renderPage()
            local ok = pcall(r.page_bb.writeJPG, r.page_bb, tmp, 85)
            r.page_bb:free()
            r.page_bb = nil
            r:freeBackground(true)   -- the PDF stays open for the next page
            local f = ok and io.open(tmp, "rb")
            if f then
                table.insert(pictures, { jpg = f:read("*a"), w = w, h = h })
                f:close()
            end
        end
    end)
    if r.page_bb then r.page_bb:free() end
    r:freeBackground()
    if r.ui then r.ui:free() end
    os.remove(tmp)
    -- Pictures drawn for it aren't kept when no notebook is open.
    if (Editor.openCount or 0) == 0 then Items.clearCache() end
    if not done then error(err, 0) end
    return require("notesmdpdf").picturesPdf(pictures, notebook.name), #pictures
end

function Editor:exportPagesPDF()
    local util = require("util")
    local folder = DataStorage:getDataDir() .. "/notes/export"
    util.makePath(folder)
    local msg = KO.wait(_("Making the PDF…"))
    UIManager:forceRePaint()
    self:saveNow()
    local bytes, count = Editor.notebookPDF(self.notebook)
    local pictures = { n = count }
    local path = folder .. "/" .. util.getSafeFilename(self.notebook.name) .. ".pdf"
    local f = io.open(path, "wb")
    if f then
        f:write(bytes)
        f:close()
    end
    UIManager:close(msg)
    KO.message(f and T(_("Saved a %1-page PDF to\n%2"), pictures.n, path) or _("Could not save the PDF."))
end

-- Pages as PNG images in koreader/notes/export/<notebook>/.
function Editor:export(all)
    self:commitSelection()
    local util = require("util")
    local folder = DataStorage:getDataDir() .. "/notes/export/" .. util.getSafeFilename(self.notebook.name)
    util.makePath(folder)
    local current, view = self.page, self.view
    self.view = nil   -- the whole page, not the zoom
    local first, last = all and 1 or current, all and #self.notebook.pages or current
    for page = first, last do
        self.page = page
        self:renderPage()
        self.page_bb:writePNG(string.format("%s/page-%03d.png", folder, page))
    end
    self.page, self.view = current, view
    self:renderPage()
    self:repaint()
    KO.message{
        text = T(_("Saved %1 to\n%2"), all and T(_("%1 pages"), last - first + 1) or _("the page"), folder),
    }
end

--- A page of a notebook as a PNG file (paper and ink, no toolbar), for
-- OneNote and Claude. `opts.long`: at most that many pixels on the long
-- side; `opts.strokes`: only these strokes, no paper, cropped to them.
-- Returns true or nil and why.
function Editor.pagePNG(notebook, index, path, opts)
    opts = opts or {}
    local w, h = notebook.width or 0, notebook.height or 0
    if w <= 0 or h <= 0 then w, h = Screen:getWidth(), Screen:getHeight() end
    local r = setmetatable({ notebook = notebook, page = index, w = w, h = h, scale = Screen:getDPI() / 300,
        pageRect = { 0, 0, w, h } }, { __index = Editor })
    r.page_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local image = r.page_bb
    if opts.strokes then
        r.page_bb:fill(Blitbuffer.COLOR_WHITE)
        if opts.items then require("notesitems").draw(r.page_bb, opts.items, "under", nil, nil, notebook.imageDir) end
        r:drawStrokes(r.page_bb, opts.strokes)
        if opts.items then require("notesitems").draw(r.page_bb, opts.items, "text", nil, nil, notebook.imageDir) end
        local box = Ink.clip(opts.box or Ink.boxOf(opts.strokes), w, h)
        if box then
            local pad = opts.box and 0 or 20
            box = Ink.clip({ box[1] - pad, box[2] - pad, box[3] + 2 * pad, box[4] + 2 * pad }, w, h)
            image = r.page_bb:viewport(box[1], box[2], box[3], box[4])
            if opts.cropOut then for i = 1, 4 do opts.cropOut[i] = box[i] end end
        end
    else
        r:renderPage()
        local box = opts.crop and Ink.clip(opts.crop, w, h)
        if box then
            image = r.page_bb:viewport(box[1], box[2], box[3], box[4])
            if opts.cropOut then for i = 1, 4 do opts.cropOut[i] = box[i] end end
        end
    end
    local iw, ih = image:getWidth(), image:getHeight()
    local scaled
    if opts.long and math.max(iw, ih) > opts.long then
        local f = opts.long / math.max(iw, ih)
        scaled = UI.scale(image, math.floor(iw * f), math.floor(ih * f))
        image = scaled
    end
    local ok, why = pcall(image.writePNG, image, path)
    if scaled then scaled:free() end
    r:freeBackground()
    r.page_bb:free()
    if not ok then return nil, why end
    return true
end

-- ------------------------------------------------------------------ saving, closing

function Editor:changed()
    self.dirty = true
    self.changedSinceOpen = true
    self:puzzleActivity()
    self:checkTicks()
    local page = self.notebook.pages[self.page]
    if page then
        self.revs = self.revs or {}
        self.revs[page.id] = (self.revs[page.id] or 0) + 1
    end
    if self.saveTask then UIManager:unschedule(self.saveTask) end
    self.saveTask = function() self:saveNow() end
    UIManager:scheduleIn(SAVE_AFTER, self.saveTask)
end

function Editor:saveNow()
    if self.saveTask then UIManager:unschedule(self.saveTask) end
    self.saveTask = nil
    if not self.dirty or self.discard then return end
    self.dirty = false
    local ok, why = self.store:save(self.notebook)
    if not ok then
        logger.err("Notes: could not save", self.notebook.id, why)
        KO.message(T(_("Could not save the notebook:\n%1"), tostring(why)))
    end
end

--- A quick note's pad moved up or down by its top edge: what's written moves with it (as the
-- handwriting strip's does), drawn again now and then while dragging, and where it ends
-- (remembered for the next quick note, a full refresh there).
function Editor:dragQuick(y, final)
    local d = self.quickDrag
    if not d then return end
    local u = self.ui:u(1)
    local to = d.last or self.quick.top
    if y then to = math.floor(math.max(u * 60, math.min(self.h - u * 160, d.top + y - d.from))) end
    local now = time.now()
    if not final and (math.abs(to - self.quick.top) < 12 or (d.at and time.to_ms(now - d.at) < 150)) then
        d.last = to
        return
    end
    d.at, d.last = now, to
    local dy = to - self.quick.top
    if dy ~= 0 then
        -- (Flipped, the pad's top stays at the top of the screen: the ink stays where it is.)
        if not self.quick.flip then self:shiftQuickInk(dy) end
        self.quick.top = to
        self:layout()
        self:renderPage()
        self:repaint(nil, final and "full" or "ui")
    end
    if final then
        self.quickDrag = nil
        if self.quick.moved then self.quick.moved(to / self.h, self.quick.flip) end
        if dy == 0 then self:repaint(nil, "full") end
    end
end

--- A quick note's buttons by its handle: small icons in the pad's blank strip just inside the
-- edge (nothing of the picture covered), Peek and Swap to the handle's left, Discard and Save
-- (✓) to its right. { { key, icon, x, y, w, h } } (w and h: the tap area).
function Editor:quickButtons()
    -- (Off in Notes' settings > Toolbar: none; the toolbar has them.)
    if not Settings.get("quick_buttons") then return {} end
    local u = function(n) return self.ui:u(n) end
    local r = self.pageRect
    local e = self:quickEdge()
    local bw, bh, gap, hw = u(34), u(26), u(8), u(60)
    -- (Below the edge, or above it when the pad is on top.)
    local y = self.quick.flip and (e - u(2) - bh) or (e + u(2))
    local cx = r[1] + math.floor(r[3] / 2)
    local left = cx - math.floor(hw / 2) - gap
    local right = cx + math.floor(hw / 2) + gap
    return {
        { key = "peek", icon = "eye", x = left - 2 * bw - gap, y = y, w = bw, h = bh },
        { key = "swap", icon = "arrow-up-down", x = left - bw, y = y, w = bw, h = bh },
        { key = "discard", icon = "trash-2", x = right, y = y, w = bw, h = bh },
        { key = "save", icon = "check", x = right + bw + gap, y = y, w = bw, h = bh, primary = true },
    }
end

function Editor:quickButton(key)
    if key == "peek" then
        if self.quick.peek then self.quick.peek(self) end
    elseif key == "swap" then
        self:swapQuick()
    elseif key == "discard" then
        if self.quick.discard then self.quick.discard(self) end
    elseif key == "save" then
        self:closeAsked()
    end
end

-- The edge between a quick note's pad and the picture of the screen.
function Editor:quickEdge()
    local r = self.pageRect
    return self.quick.flip and r[2] + r[4] or r[2]
end

function Editor:shiftQuickInk(dy)
    for __, st in ipairs(self.notebook.pages[self.page].strokes or {}) do
        for i = 2, #st.p, 2 do st.p[i] = st.p[i] + dy end
    end
end

--- A quick note's pad to the other half: on top with the picture below, or the other way
-- round (as tall as it was; what's written moves with it; remembered for next time).
function Editor:swapQuick()
    local q = self.quick
    local edge = self.h - q.top
    if q.flip then
        self:shiftQuickInk(edge)
    else
        self:shiftQuickInk(-q.top)
    end
    q.flip, q.top = not q.flip, edge
    self:layout()
    self:renderPage()
    self:repaint(nil, "full")
    if q.moved then q.moved(q.top / self.h, q.flip) end
end

function Editor:close()
    self:commitSelection()
    UIManager:close(self)
end

-- Closed by you (its top button, Back): with When closing: Ask and changes
-- made, Save / Rename / Don't save first.
function Editor:closeAsked()
    if Settings.get("close_action") == "ask" and self.changedSinceOpen and self.on_close_ask then
        self:commitSelection()
        return self.on_close_ask(self)
    end
    self:close()
end

function Editor:onClose()
    self:closeAsked()
    return true
end

function Editor:onCloseWidget()
    Editor.openCount = math.max(0, (Editor.openCount or 1) - 1)
    if self.coverTask then UIManager:unschedule(self.coverTask) end
    local input = Device.input
    -- The pen given back to the editor underneath (To Do's pad over a notebook), else let go.
    if input.stylus_callback == self.stylusHook or not self.stylusHook then
        if self.prevStylus and type(input.registerStylusCallback) == "function" then
            input:registerStylusCallback(self.prevStylus)
        elseif input.stylus_callback and input.unregisterStylusCallback then
            input:unregisterStylusCallback()
        end
    end
    if self.holdTask then UIManager:unschedule(self.holdTask) self.holdTask = nil end
    if self.stopStatus then self.stopStatus() self.stopStatus = nil end
    if self.statusRetry then UIManager:unschedule(self.statusRetry) end
    dropSelection(self.sel)
    if self.inkScheduled then UIManager:unschedule(self.inkTask) end
    if self.cleanTask then UIManager:unschedule(self.cleanTask) end
    if self.dragTask then UIManager:unschedule(self.dragTask) end
    if self.stripTask then UIManager:unschedule(self.stripTask) end
    self:freeClueCard()
    -- KOReader's touch state started afresh (as waking the Kindle does), so
    -- no half-taken touch is left behind to make fingers do nothing.
    UIManager:nextTick(function()
        if type(Device.input.resetState) == "function" then Device.input:resetState() end
    end)
    self:shareGrid(self.page)
    if self.pollTask then UIManager:unschedule(self.pollTask) end
    self.pollTask = nil
    if self.pen then
        self.pen:close()
        self.pen = nil
    end
    self:saveNow()
    if self.page_bb then
        self.page_bb:free()
        self.page_bb = nil
    end
    self:freeBackground()
    self:freeThumbs()
    Items.clearCache()
    self.ui:free()
    UIManager:setDirty(nil, "full")
    if not self.quiet then
        local name = self.notebook.name
        KO.toast((self.discard and self.isNew and T(_("%1 not saved"), name))
            or (self.discard and T(_("Changes to %1 discarded"), name)) or T(_("Saved %1"), name))
    end
    if self.on_close then self.on_close(self) end
end

return Editor
