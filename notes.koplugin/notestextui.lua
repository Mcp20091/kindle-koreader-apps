--[[--
Handwriting to text in KOReader: turning a page or a lasso selection into
text, Ask and Make PDF, drawing with the AI, searching what was read, the
text kept for each page (for search and OneNote), and Notes' jobs and
features in the AI settings. Adds these to the Notes plugin.

The AI services, their settings and the instructions each feature sends are
the launcher's (apps.koplugin/appsai.lua, through PS.ai), shared with
Crosswords and SSH: Settings > AI. Without the launcher, Notes has no AI.
]]
local DataStorage = require("datastorage")
local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Claude = require("notesclaude")
local KO = require("notesko")
local Editor = require("noteseditor")
local Settings = require("notessettings")
local Store = require("notesstore")

local Screen = Device.screen

local function info(text) KO.message(text) end

-- The launcher's AI (nil without the launcher).
local function AI() return require("pluginshare").ai end

-- Without the launcher: a client that only says why.
local NO_AI = { transcribe = function() return nil, _("The AI needs the launcher (apps.koplugin).") end }

-- Notes' jobs in Settings > AI > Which AI does each job: "read" (handwriting
-- to text, search, To Do, Check my answers), "ask" (Ask, Make PDF, crossword
-- hints), "draw". (Crosswords' hints and checks use them too.)
local JOBS = { "read", "ask", "draw" }
do
    local ai = AI()
    if ai then
        ai.registerJob{ key = "read", name = _("Reading handwriting, search, To Do"), app = "notes", order = 10 }
        ai.registerJob{ key = "ask", name = _("Ask, Make PDF and hints"), app = "notes", order = 20 }
        ai.registerJob{ key = "draw", name = _("Drawing"), app = "notes", order = 30 }
    end
end

return function(Notes)

--- A client for the AI a job uses (:transcribe(png, instructions, more)).
function Notes:claude(job)
    local ai = AI()
    return ai and ai.client(job or "read") or NO_AI
end

--- Which AI service does a job: an id of the launcher's list ("claude",
-- "gemini", "openrouter", "groq", "server" for your local AI, "custom").
function Notes:aiFor(job)
    local ai = AI()
    return ai and ai.serviceFor(job) or "claude"
end

--- A service's name as shown ("Claude", "Gemini", "Local AI"…).
function Notes:aiNameOf(id)
    local ai = AI()
    return ai and ai.name(id) or _("Claude")
end

--- The name of the AI a job uses.
function Notes:aiName(job)
    return self:aiNameOf(self:aiFor(job))
end

--- Who does Notes' jobs: one service's name, or "Mixed".
function Notes:aiAllName()
    local ai = AI()
    return ai and ai.allName(JOBS) or _("Claude")
end

--- Whether a service can be used.
function Notes:providerReady(id)
    local ai = AI()
    return ai ~= nil and ai.ready(id)
end

--- Whether any AI service is set up (without one, Notes leaves out every AI
-- button and menu item).
function Notes:anyAI()
    local ai = AI()
    return ai ~= nil and ai.any()
end

--- Whether the AI a job uses (reading, when none is given) is set up.
function Notes:claudeReady(job)
    local ai = AI()
    return ai ~= nil and ai.readyFor(job or "read")
end

--- What to set up first, for the AI a job uses (also for Crosswords).
function Notes:aiNotReadyText(job)
    local ai = AI()
    return ai and ai.notReadyText(job) or _("The AI needs the launcher (apps.koplugin).")
end

--- Settings > AI (the launcher's); `note` (optional): why it opened.
function Notes:handwritingSettings(note)
    local ai = AI()
    if not ai then return info(_("The AI needs the launcher (apps.koplugin).")) end
    ai.showSettings(note)
end

--- One AI service's page (Settings > AI > the service).
function Notes:providerSettings(id)
    local ai = AI()
    if ai then ai.showService(id) end
end

--- Every one of Notes' jobs to one service, picked from the list; one not
-- set up yet opens its page.
function Notes:switchAllAI(done)
    local ai = AI()
    if not ai then return end
    local all = self:aiAllName() ~= _("Mixed") and self:aiFor(JOBS[1]) or nil
    local options = {}
    for __, p in ipairs(ai.PROVIDERS) do
        local label = _(p.name)
        if not ai.ready(p.id) then label = T(_("%1 (not set up)"), label) end
        table.insert(options, { label = label, value = p.id })
    end
    KO.choose(_("AI for every job"), options, all, function(id)
        if not id then return end
        for __, j in ipairs(JOBS) do ai.setServiceFor(j, id) end
        if done then done() end
        if not ai.ready(id) then UIManager:nextTick(function() ai.showService(id) end) end
    end)
end

-- ------------------------------------------------------------------ the text kept for each page

function Notes:textFile()
    if not self.texts then
        self.texts = LuaSettings:open(DataStorage:getSettingsDir() .. "/notes_text.lua")
    end
    return self.texts
end

local function md5(s) return require("ffi/sha2").md5(s) end

--- The kept text of a page if it is still what the page shows, else nil.
function Notes:keptText(nb, page)
    local all = self:textFile():readSetting("pages") or {}
    local kept = all[nb.id] and all[nb.id][page.id]
    if kept and kept.hash == md5(Store.pageText(page, "")) then return kept.text end
    return nil
end

function Notes:keepText(nb, page, text)
    local file = self:textFile()
    local all = file:readSetting("pages") or {}
    all[nb.id] = all[nb.id] or {}
    all[nb.id][page.id] = { hash = md5(Store.pageText(page, "")), text = text, at = os.time() }
    file:saveSetting("pages", all)
    file:flush()
end

-- A page image small enough for Claude (it reads up to about 1568 pixels on
-- the long side; more is only slower to send).
local function pagePNG(nb, i)
    local tmp = DataStorage:getDataDir() .. "/cache/notes-read.png"
    require("util").makePath(DataStorage:getDataDir() .. "/cache")
    local ok, why = Editor.pagePNG(nb, i, tmp, { long = 1568 })
    if not ok then return nil, why end
    local f = io.open(tmp, "rb")
    local data = f and f:read("*a")
    if f then f:close() end
    os.remove(tmp)
    return data
end

--- The text of page i (kept, or read now: needs the network). Returns the
-- text or nil and why.
function Notes:pageTextNow(nb, i)
    local page = nb.pages[i]
    if #page.strokes == 0 then return "" end
    local kept = self:keptText(nb, page)
    if kept then return kept end
    local png, why = pagePNG(nb, i)
    if not png then return nil, why end
    local text
    -- (Read handwriting's instructions; with the page before, as Advanced says.)
    local more, note = self:aiMorePages("read", nb, i)
    text, why = self:claude("read"):transcribe(png,
        self:aiInstructions("read") .. (note and ("\n" .. note .. " Transcribe only the first image.") or ""),
        #more > 0 and more or nil)
    if not text then return nil, why end
    if nb.newIds then self.store:save(nb) nb.newIds = nil end   -- page ids must stay
    self:keepText(nb, page, text)
    return text
end

-- ------------------------------------------------------------------ showing text

-- A text saved as Markdown in koreader/notes/export/ (and where, said).
local function saveText(text, saveName)
    local util = require("util")
    local folder = DataStorage:getDataDir() .. "/notes/export"
    util.makePath(folder)
    local path = folder .. "/" .. util.getSafeFilename(saveName) .. ".md"
    local f = io.open(path, "w")
    if f then
        f:write(text, "\n")
        f:close()
        info(T(_("Saved to\n%1"), path))
    end
end

function Notes:showText(title, text, saveName, replace)
    -- The launcher's pop-up, as the apps' others: Copy, Save, (Replace) and Done.
    local P = require("pluginshare").popup
    if P and P.read then
        local buttons = { { icon = "copy", text = _("Copy"), keep = true, fn = function()
            Device.input.setClipboardText(text)
            KO.toast(_("Copied"))
        end } }
        if saveName then
            table.insert(buttons, { icon = "download", text = _("Save"), keep = true, fn = function() saveText(text, saveName) end })
        end
        if replace and text ~= "" then
            -- The lasso's To text: the handwriting swapped for this text, where it was.
            table.insert(buttons, { icon = "arrow-right-left", text = _("Replace"), fn = function() replace(text) end })
        end
        table.insert(buttons, { icon = "check", text = _("Done"), primary = true })
        P.read{ title = title, text = text ~= "" and text or _("(No writing found.)"), buttons = buttons }
        return
    end
    local viewer
    local row = {}
    if replace and text ~= "" then
        -- The lasso's To text: the handwriting swapped for this text, where it was.
        table.insert(row, { text = _("Replace"), callback = function()
            UIManager:close(viewer)
            replace(text)
        end })
    end
    table.insert(row, { text = _("Copy"), callback = function()
        Device.input.setClipboardText(text)
        KO.toast(_("Copied"))
    end })
    if saveName then table.insert(row, { text = _("Save"), callback = function() saveText(text, saveName) end }) end
    if not (replace and text ~= "") then
        table.insert(row, { id = "top", text = "⇱", callback = function() viewer.scroll_widget:scrollToTop() end })
        table.insert(row, { id = "bottom", text = "⇲", callback = function() viewer.scroll_widget:scrollToBottom() end })
    end
    table.insert(row, { text = _("Close"), callback = function() viewer:onClose() end })
    viewer = TextViewer:new{
        title = title,
        text = text ~= "" and text or _("(No writing found.)"),
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.8),
        -- (One row, its own: TextViewer's Find row left out, so the dividers line up.)
        add_default_buttons = false,
        buttons_table = { row },
    }
    UIManager:show(viewer)
end

local function notReady(self, feature) return self:aiNotReadyText(feature) end

local function withClaude(self, fn, feature)
    if not self:claudeReady(feature or "read") then
        return self:handwritingSettings(notReady(self, feature or "read"))
    end
    NetworkMgr:runWhenOnline(fn)
end

local function busy(text)
    local msg = KO.wait(text)
    UIManager:forceRePaint()
    return msg
end

--- A notebook's page as text (the editor's menu).
function Notes:convertPage(id, index)
    withClaude(self, function()
        local nb, why = self.store:read(id)
        if not nb then return info(tostring(why)) end
        local msg = busy(_("Reading your handwriting…"))
        local text
        text, why = self:pageTextNow(nb, index)
        UIManager:close(msg)
        if not text then return info(T(_("Could not read the page:\n%1"), tostring(why))) end
        self:showText(T(_("%1 · Page %2"), nb.name, index), text, T("%1 page %2", nb.name, index))
    end)
end

--- A lasso selection's image as text (not kept).
function Notes:convertImage(png, name, replace)
    withClaude(self, function()
        local msg = busy(_("Reading your handwriting…"))
        local text, why = self:claude("read"):transcribe(png, self:aiInstructions("read"))
        UIManager:close(msg)
        if not text then return info(T(_("Could not read the selection:\n%1"), tostring(why))) end
        self:showText(_("Selection"), text, name, replace)
    end)
end

-- ------------------------------------------------------------------ asking Claude anything

--- Claude asked to do what the user types with an image (a page or a
-- lasso selection); the answer shown to copy or save.
function Notes:askClaude(png, name, morePages)
    if not self:claudeReady("ask") then
        return self:handwritingSettings(notReady(self, "ask"))
    end
    local recent = Settings.get("claude_recent") or {}
    local dialog
    -- The request (typed, or a picture of it written by hand) sent with the
    -- note; the answer shown, or made into a PDF.
    local function run(prompt, written, pdf)
        -- Ask's or Make PDF's instructions (AI settings > Advanced), then the
        -- request; the other pages its amount sends (from a page, not a lasso).
        local key = pdf and "pdf" or "ask"
        local more, note = {}, nil
        if morePages then more, note = morePages(key) end
        local text = self:aiInstructions(key)
        if written then
            text = text .. _("my request is written by hand in the last image: read it and do it.")
            table.insert(more, written)
        else
            text = text .. prompt
        end
        if note then text = text .. "\n(" .. (note:gsub("^%s+", "")) .. ")" end
        NetworkMgr:runWhenOnline(function()
            local msg = busy(pdf and _("Making the PDF…") or _("Asking the AI…"))
            local answer, why = self:claude("ask"):transcribe(png, text, #more > 0 and more or nil)
            UIManager:close(msg)
            if not answer then return info(T(_("The AI could not answer:\n%1"), tostring(why))) end
            if pdf then
                self:savePDF(answer, name or "Note")
            else
                self:showText(prompt or _("Your written request"), answer, name and (name .. " - answer") or "AI answer")
            end
        end)
    end
    local function ask(prompt, pdf)
        prompt = (prompt or ""):match("^%s*(.-)%s*$")
        if prompt == "" then return end
        if dialog then UIManager:close(dialog) end
        -- The last five prompts, newest first, for one tap next time.
        local keep = { prompt }
        for __, p in ipairs(recent) do
            if p ~= prompt and #keep < 5 then table.insert(keep, p) end
        end
        Settings.set("claude_recent", keep)
        run(prompt, nil, pdf)
    end
    -- Examples to start from (ones used recently left out).
    local examples = {
        _("Summarize this"), _("Tidy this into an outline"),
        _("Write this up as an email"), _("Make a to-do list from this"),
        _("Check my maths"), _("Explain this simply"),
        _("Find the key dates and names"), _("Suggest what I missed"),
    }
    local function handwrite()
        if not (self.editor and self.editor.startAskPad) then return end
        self.editor:startAskPad(function(written, pdf) run(nil, written, pdf) end)
    end
    -- The launcher's pop-up, as the apps' others: the request (or the pen to
    -- write it), recent and example requests, Cancel, Make PDF and Answer.
    local P = require("pluginshare").popup
    if P and P.request then
        local function rows(list)
            local out = {}
            for __, p in ipairs(list) do
                table.insert(out, { text = p, fn = function(box) box:close() ask(p) end })
            end
            return out
        end
        local seen0, others = {}, {}
        for __, p in ipairs(recent) do seen0[p] = true end
        for __, p in ipairs(examples) do if not seen0[p] then table.insert(others, p) end end
        P.request{
            title = _("Ask AI"),
            subtitle = morePages and _("About this page") or _("About what you selected"),
            hint = _("Type a request, or write it"),
            -- (The launcher's handwriting input: the writing read into the box.)
            pen = require("pluginshare").handwriting and true or handwrite,
            penTitle = _("Write your request"),
            sections = {
                { heading = _("RECENT"), items = rows(recent) },
                { heading = _("EXAMPLES"), items = rows(others) },
            },
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                -- (aiJob: hold the button for AI for this: the service and model it uses.)
                { icon = "file-text", text = _("Make PDF"), needsText = true, aiJob = "pdf", fn = function(t) ask(t, true) end },
                { icon = "send", text = _("Answer"), primary = true, needsText = true, aiJob = "ask", fn = function(t) ask(t) end },
            },
        }
        return
    end
    -- (Without the launcher: one row of buttons, the recent and example
    -- requests behind Examples, so the rows' dividers line up.)
    local function pickExample()
        local items, seen = {}, {}
        for __, p in ipairs(recent) do
            seen[p] = true
            table.insert(items, { text = p, fn = function() ask(p) end })
        end
        for __, p in ipairs(examples) do
            if not seen[p] then table.insert(items, { text = p, fn = function() ask(p) end }) end
        end
        KO.list(_("Examples"), items)
    end
    local buttons = { {
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
        { text = _("Examples"), callback = pickExample },
        { text = _("Write it"), callback = function()
            UIManager:close(dialog)
            handwrite()
        end },
        { text = _("PDF"), callback = function() ask(dialog:getInputText(), true) end },
        { text = _("Answer"), is_enter_default = true, callback = function() ask(dialog:getInputText()) end },
    } }
    dialog = InputDialog:new{
        title = _("Ask AI about this"),
        input = "",
        input_hint = _("Type a request, or tap Write it to write it by hand"),
        allow_newline = false,
        buttons = buttons,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Claude's document (Markdown) as a PDF in koreader/notes/export/, then
-- offered to read, or to write on as a new notebook.
function Notes:savePDF(markdown, name)
    local MdPdf = require("notesmdpdf")
    local util = require("util")
    local folder = DataStorage:getDataDir() .. "/notes/export"
    util.makePath(folder)
    local base = util.getSafeFilename(name):gsub("%.pdf$", "")
    local path = folder .. "/" .. base .. ".pdf"
    local n = 2
    while io.open(path, "rb") do
        path = string.format("%s/%s (%d).pdf", folder, base, n)
        n = n + 1
    end
    local title = markdown:match("^%s*#%s+([^\n]+)") or name
    local bytes, pages = MdPdf.render(markdown, title)
    local f = io.open(path, "wb")
    if not f then return info(_("Could not save the PDF.")) end
    f:write(bytes)
    f:close()
    local dialog
    dialog = KO.buttonDialog{
        title = T(_("Saved a %1-page PDF to\n%2"), pages, path),
        title_align = "center",
        buttons = {
            {
                { text = _("Open it"), callback = function()
                    UIManager:close(dialog)
                    if self.editor then self.editor:close() end
                    if self.menu then UIManager:close(self.menu) end
                    KO.openBook(path)
                end },
                { text = _("Write on it"), callback = function()
                    UIManager:close(dialog)
                    if self.editor then self.editor:close() end
                    self:importPDF(path)
                end },
            },
            { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        },
    }
end

function Notes:askAboutPage(id, index)
    local nb, why = self.store:read(id)
    if not nb then return info(tostring(why)) end
    local png
    png, why = pagePNG(nb, index)
    if not png then return info(tostring(why)) end
    self:askClaude(png, T("%1 page %2", nb.name, index), function(key) return self:aiMorePages(key, nb, index) end)
end

-- ------------------------------------------------------------------ what each AI feature sends

-- Each AI feature's instructions in three parts: what it is (fixed), how to
-- do it (your wording: Settings > AI > Advanced, with Reset) and the form the
-- answer must take (fixed, so editing can't break the feature); and how
-- much of the notebook goes with it. Crosswords adds its own
-- (Notes.addAiFeature). `amounts`: { { value, label } }, the first the default.
local AMOUNT_PAGE = { "page", _("This page") }
local AMOUNT_PREV = { "prev", _("This page and the one before") }
local AMOUNT_ALL = { "all", _("The whole notebook (up to 10 pages)") }
local FEATURES = {
    { key = "read", name = _("Read handwriting"),
        intro = Claude.READ_INTRO .. "\n", words = Claude.READ_WORDS, format = "\n" .. Claude.READ_FORMAT,
        amounts = { AMOUNT_PAGE, AMOUNT_PREV }, request = false, job = "read" },
    { key = "ask", name = _("Ask"),
        intro = "This image is from my handwritten notebook on a Kindle Scribe (a whole page, or a part of one I selected). ",
        words = "Answer in plain text (simple Markdown at most); the answer is shown on an e-ink screen.",
        format = " My request: ",
        amounts = { AMOUNT_PAGE, AMOUNT_PREV, AMOUNT_ALL }, job = "ask" },
    { key = "pdf", name = _("Make PDF"),
        intro = "This image is from my handwritten notebook on a Kindle Scribe (a whole page, or a part of one I selected). ",
        words = "Make it into a clean, well organised document, applying what I ask below.",
        format = " Reply with the document only, in Markdown (# headings, paragraphs, - lists, - [ ] checkboxes, > quotes, | tables |), "
            .. "with nothing before or after it. What I ask: ",
        amounts = { AMOUNT_PAGE, AMOUNT_PREV, AMOUNT_ALL }, job = "ask" },
    { key = "draw", name = _("Drawing help"),
        intro = "The image is part of a page of my handwritten notebook on an e-ink Kindle Scribe (black, white and greys). "
            .. "It is %d x %d units, one unit per screen pixel (about 12 per millimetre): a line of handwriting is about 70 units tall. "
            .. "%s Reply with one SVG only and nothing else, starting <svg viewBox=\"0 0 %d %d\">. "
            .. "Use only line, polyline, polygon, rect, circle, ellipse, path and text elements; black strokes (stroke=\"black\", "
            .. "stroke-width 4 to 8); fills only \"none\" or a light grey such as #dddddd; no images, gradients, CSS, filters or fonts; "
            .. "text only for short labels (font-size 40 to 70). ",
        words = "Keep it clean line art that reads well on e-ink.",
        format = " My request: ", job = "draw",
        -- (Preview: a part of the page as big as the whole screen's width.)
        args = { 1240, 600, "Your SVG goes next to the image, at the same size.", 1240, 600 } },
}

--- Notes' AI features in Settings > AI > Advanced (the launcher's), and
-- Crosswords' through Notes.addAiFeature: what each sends, as the launcher
-- keeps it (Notes:aiInstructions and the others below just ask it).
local function registerFeature(def)
    local ai = AI()
    if not ai then return end
    def.app = def.app or "notes"
    -- Preview: the notebook open last (Crosswords' puzzle too, as a notebook).
    def.preview = def.preview or function(key)
        local notes = require("notesshare").notes
        return notes and notes:aiPreviewPictures(key) or nil
    end
    def.without = def.without or _("With a picture of the page (or the part you lasso).")
    ai.registerFeature(def)
end

for __, f in ipairs(FEATURES) do registerFeature(f) end

--- Another plugin's AI feature in Advanced (Crosswords' hints and checks):
-- { key, name, job, intro, words, format, amounts }. Its instructions then
-- come from Notes:aiInstructions(key).
function Notes.addAiFeature(def)
    registerFeature(def)
end

--- A feature's wording: yours, or its default.
function Notes:aiWords(key)
    local ai = AI()
    return ai and ai.words(key) or ""
end

--- Your wording for a feature (nil: back to the default).
function Notes:setAiWords(key, text)
    local ai = AI()
    if ai then ai.setWords(key, text) end
end

--- How much a feature sends: one of its amounts' values.
function Notes:aiAmount(key)
    local ai = AI()
    return ai and ai.amount(key) or "page"
end

function Notes:setAiAmount(key, value)
    local ai = AI()
    if ai then ai.setAmount(key, value) end
end

--- A feature's instructions, as sent: its intro, your wording, its format
-- (then, for Ask and the others, the request). `...`: the intro's values
-- (drawing's size).
function Notes:aiInstructions(key, ...)
    local ai = AI()
    return ai and ai.instructions(key, ...) or nil
end

--- Settings > AI > Advanced.
function Notes:aiAdvanced()
    local ai = AI()
    if ai then ai.showAdvanced() end
end

--- The other pages sent with page `i` of `nb` for a feature, as its amount
-- says: { png, … } (the page before, or the rest of the notebook, up to 10
-- pages in all), and a sentence telling the AI what they are.
function Notes:aiMorePages(key, nb, i)
    local amount = self:aiAmount(key)
    local more, note = {}, nil
    if amount == "prev" and i > 1 then
        local png = pagePNG(nb, i - 1)
        if png then table.insert(more, png) end
        note = " The next image is the page before it, for context."
    elseif amount == "all" then
        for k = 1, #nb.pages do
            if k ~= i and #more < 9 then
                local png = pagePNG(nb, k)
                if png then table.insert(more, png) end
            end
        end
        if #more > 0 then note = " The next images are the notebook's other pages, in order, for context." end
    end
    return more, note
end

-- ------------------------------------------------------------------ Preview (Settings > AI > Advanced)

--- The picture(s) a feature would send now, for Preview: the notebook open
-- last, its current page (and what the amount adds). { pngs, where } or nil.
function Notes:aiPreviewPictures(key)
    local list = self:recentNotebooks(1)
    local entry = list and list[1]
    local nb = entry and not self:isLocked(entry.id) and self.store:read(entry.id)
    if not nb or #nb.pages == 0 then return nil end
    local i = math.max(1, math.min(#nb.pages, (Settings.get("last_pages") or {})[entry.id] or 1))
    local first = pagePNG(nb, i)
    if not first then return nil end
    local pngs = { first }
    if key ~= "draw" then
        local more = self:aiMorePages(key, nb, i)
        for __, p in ipairs(more) do table.insert(pngs, p) end
    end
    return { pngs = pngs, where = T(_("%1, page %2"), nb.name, i) }
end

-- ------------------------------------------------------------------ pages of Notes' settings

--- A settings page of Notes' (AI, local AI, OneNote) shown, or (open
-- already) drawn again: `self[field]` keeps it, so a change comes back to it.
function Notes:settingsSubPage(field, title, build)
    local page = self[field]
    if page and UIManager:isWidgetShown(page) then
        page:refresh()
        return page
    end
    page = require("notessettingspage"):new{
        title = title,
        build = build,
        titleOpts = {
            home = require("pluginshare").appsHome and function() self:goHome() end or nil,
            bell = KO.bell(),
            menu = function() self:titleMenu({}) end,
        },
    }
    self[field] = page
    UIManager:show(page)
    return page
end

--- A list of Notes' (search results, OneNote, Linked from) as a full page
-- with the shared title bar: `items` as a Menu's ({ text, mandatory, bold,
-- dim, callback, hold_callback }); `back()` (optional) for ‹, else it closes.
function Notes:listPage(title, items, back)
    local page = require("notessettingspage"):new{
        title = title,
        items = items,
        titleOpts = {
            home = require("pluginshare").appsHome and function() self:goHome() end or nil,
            bell = KO.bell(),
            menu = function() self:titleMenu({}) end,
            back = back,
        },
    }
    UIManager:show(page)
    return page
end

-- ------------------------------------------------------------------ drawing with Claude

-- Where the drawing goes (in the drawing help's instructions).
local DRAW_WHERE = {
    replace = "Your SVG replaces what is in the image, at the same place and size: keep its layout and content where my request does not change them.",
    beside = "Your SVG goes next to the image, at the same size.",
    draw = "The area is empty apart from the paper's lines or dots; your SVG is drawn into it.",
}

--- Claude asked to draw: in place of a lasso selection, beside it, or in an
-- empty area lassoed. `what`: { png, w, h, empty }; `apply(svg, mode)`
-- puts the drawing on the page (true, or nil and why).
function Notes:drawWithClaude(what, apply)
    if not self:claudeReady("draw") then
        return self:handwritingSettings(notReady(self, "draw"))
    end
    local dialog
    local function run(prompt, written, mode)
        local text = self:aiInstructions("draw", what.w, what.h, DRAW_WHERE[mode], what.w, what.h)
            .. (written and _("it is written by hand in the second image: read it and do it.") or prompt)
        NetworkMgr:runWhenOnline(function()
            local msg = busy(_("Drawing…"))
            local answer, why = self:claude("draw"):transcribe(what.png, text, written and { written } or nil)
            UIManager:close(msg)
            if not answer then return info(T(_("The AI could not draw it:\n%1"), tostring(why))) end
            local ok
            ok, why = apply(answer, mode)
            if not ok then info(T(_("The drawing could not be used:\n%1"), tostring(why))) end
        end)
    end
    local function go(prompt, mode)
        prompt = (prompt or ""):match("^%s*(.-)%s*$")
        if prompt == "" then return end
        if dialog then UIManager:close(dialog) end
        run(prompt, nil, mode)
    end
    local P = require("pluginshare").popup
    if P and P.request then
        -- The launcher's pop-up: the request (or the pen to write it) and
        -- examples; Beside or Replace with a selection, Draw in an empty area.
        local items = {}
        for __, p in ipairs(what.empty and {
            _("Draw a simple flowchart outline"), _("Draw a 7-day habit tracker"),
            _("Draw a big title box"), _("Draw arrows to the right"),
        } or {
            _("Redraw this neatly"), _("Make this a flowchart"), _("Turn this into a table"),
            _("Make a bar chart of these numbers"), _("Straighten the lines and boxes"), _("Label the parts"),
        }) do
            -- (In an empty area there's one thing to do with it: draw it.)
            table.insert(items, { text = p, fn = function(box)
                if what.empty then box:close() go(p, "draw") else box:setText(p) end
            end })
        end
        local buttons = { { icon = "x", text = _("Cancel"), cancel = true } }
        if what.empty then
            table.insert(buttons, { icon = "shapes-chart", text = _("Draw"), primary = true, needsText = true, aiJob = "draw",
                fn = function(t) go(t, "draw") end })
        else
            table.insert(buttons, { icon = "columns-2", text = _("Beside"), needsText = true, aiJob = "draw",
                fn = function(t) go(t, "beside") end })
            table.insert(buttons, { icon = "arrow-right-left", text = _("Replace"), primary = true, needsText = true, aiJob = "draw",
                fn = function(t) go(t, "replace") end })
        end
        P.request{
            title = _("Draw with AI"),
            subtitle = what.empty and _("In the empty space you selected") or _("With what you selected"),
            hint = _("Type what to draw, or write it"),
            penTitle = _("Write what to draw"),
            pen = require("pluginshare").handwriting and true or function()
                if not (self.editor and self.editor.startAskPad) then return end
                self.editor:startAskPad(function(png) run(nil, png, what.empty and "draw" or "replace") end)
            end,
            sections = { { heading = _("EXAMPLES"), items = items } },
            rows = 4,
            buttons = buttons,
        }
        return
    end
    local examples = what.empty and {
        _("Draw a simple flowchart outline"), _("Draw a 7-day habit tracker"),
        _("Draw a big title box"), _("Draw arrows to the right"),
    } or {
        _("Redraw this neatly"), _("Make this a flowchart"),
        _("Turn this into a table"), _("Make a bar chart of these numbers"),
        _("Straighten the lines and boxes"), _("Label the parts"),
    }
    local function written(mode)
        return function()
            UIManager:close(dialog)
            if not (self.editor and self.editor.startAskPad) then return end
            self.editor:startAskPad(function(png) run(nil, png, mode) end)
        end
    end
    -- (Without the launcher: one row of buttons, the examples behind
    -- Examples, so the rows' dividers line up.)
    local function pickExample()
        local items = {}
        for __, p in ipairs(examples) do
            table.insert(items, { text = p, fn = function() dialog:setInputText(p) end })
        end
        KO.list(_("Examples"), items)
    end
    local last = {
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
        { text = _("Examples"), callback = pickExample },
    }
    if what.empty then
        table.insert(last, { text = _("Write it"), callback = written("draw") })
        table.insert(last, { text = _("Draw"), is_enter_default = true, callback = function() go(dialog:getInputText(), "draw") end })
    else
        table.insert(last, { text = _("Write it"), callback = written("replace") })
        table.insert(last, { text = _("Beside"), callback = function() go(dialog:getInputText(), "beside") end })
        table.insert(last, { text = _("Replace"), is_enter_default = true, callback = function() go(dialog:getInputText(), "replace") end })
    end
    local buttons = { last }
    dialog = InputDialog:new{
        title = what.empty and _("What should the AI draw here?") or _("What should the AI do with this?"),
        input = "",
        input_hint = _("Type what to draw, or tap Write it"),
        buttons = buttons,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ------------------------------------------------------------------ to To Do

-- The To Do plugin running beside Notes, or nil.
function Notes:todo()
    local todo = self.ui and self.ui.todo
    if todo and todo.store and todo.orderedLists then return todo end
    return nil
end

--- Something written by hand, read by the AI, for another plugin (To Do's
-- "Write it"): a blank page opens with a writing strip; `done(text, dates,
-- tasks)` gets what was written (the first to-do item's title, its dates
-- { due = "YYYY-MM-DD", remind = { date, minute } } or nil, and every item
-- read), or nil when cancelled. opts: title (the strip's label).
function Notes:handwrite(opts, done)
    opts = opts or {}
    -- The launcher's handwriting input when it's there (a task: its title,
    -- and the due date and reminder written with it).
    local hw = require("pluginshare").handwriting
    if hw then
        return hw.write({ title = opts.title, kind = "task" }, function(text, extra) done(text, extra) end)
    end
    if not self:penReady() then return done(nil) end
    if not self:claudeReady("read") then
        self:handwritingSettings(_("Set up the AI first (reading handwriting)."))
        return done(nil)
    end
    local Editor = require("noteseditor")
    local dir = DataStorage:getDataDir() .. "/cache/notes-handwrite"
    require("util").makePath(dir)
    local store = Store.new{ dir = dir, list = function() return {} end }
    local Screen = require("device").screen
    local nb = store:create(_("Handwriting"), Screen:getWidth(), Screen:getHeight(), "plain")
    if not nb then return done(nil) end
    local finished = false
    local function finish(...)
        if finished then return end
        finished = true
        done(...)
    end
    local editor
    editor = Editor:new{
        kui = self.ui,
        notebook = nb,
        store = store,
        quiet = true,
        on_close = function()
            store:delete(nb.id)
            -- Closed without writing (the toolbar's first button): nothing.
            if not finished then UIManager:nextTick(function() finish(nil) end) end
        end,
    }
    self.handwriteEditor = editor
    UIManager:show(editor)
    UIManager:nextTick(function()
        editor:startAskPad(function(png)
            -- The pad closes; the answer (or nil) always goes back, even when
            -- Wi-Fi isn't turned on or the reading fails.
            local reading = false
            editor.on_close = function() store:delete(nb.id) end
            editor:close()
            local function read()
                if finished then return end
                reading = true
                local msg = busy(_("Reading…"))
                local dates = Settings.get("todo_dates") ~= false
                local ok, tasks, why = pcall(function()
                    return Claude.tasks(self:claude("read"), png, dates and os.date("%A %Y-%m-%d") or nil)
                end)
                UIManager:close(msg)
                if not ok then tasks, why = nil, tasks end
                if not tasks or #tasks == 0 then
                    if why then info(T(_("Could not read it:\n%1"), tostring(why))) end
                    return finish(nil)
                end
                local t = tasks[1]
                finish(t.title, (t.due or t.remind) and { due = t.due, remind = t.remind } or nil, tasks)
            end
            if NetworkMgr:isConnected() then return read() end
            NetworkMgr:runWhenOnline(read)
            -- Wi-Fi declined (or never came): back with nothing after a while.
            UIManager:scheduleIn(45, function() if not reading then finish(nil) end end)
        end, { label = opts.title or _("Write it here"), send = _("Done"), pdf = false,
            cancel = function() editor:close() end })
    end)
end

--- A notebook's page read by Claude for to-do items, then added to To Do.
function Notes:pageToTodo(id, index, lines)
    local nb, why = self.store:read(id)
    if not nb then return info(tostring(why)) end
    local png
    png, why = pagePNG(nb, index)
    if not png then return info(tostring(why)) end
    -- The tasks remember the page (and its lines, for the ticks).
    self:addToTodo(png, { nb = nb.id, page = nb.pages[index].id, name = nb.name, paper = nb.pages[index].paper or nb.paper, lines = lines })
end

--- The to-do items in an image (a page or a lasso selection), read by
-- Claude, shown, and added to a To Do list as tasks with steps.
function Notes:addToTodo(png, ctx)
    local todo = self:todo()
    if not todo then return info(_("The To Do plugin is needed for this. Install it and sign in to To Do.")) end
    withClaude(self, function()
        local msg = busy(_("Reading the tasks…"))
        local dates = Settings.get("todo_dates") ~= false
        local tasks, why = Claude.tasks(self:claude("read"), png, dates and os.date("%A %Y-%m-%d") or nil)
        UIManager:close(msg)
        if not tasks then return info(T(_("Could not read the tasks:\n%1"), tostring(why))) end
        if #tasks == 0 then return info(_("No to-do items found.")) end
        -- The dates read, as To Do keeps them: due as a day, the reminder as a day and minute.
        local Dates = require("tododates")
        for __, t in ipairs(tasks) do
            t.dueDay = t.due and Dates.parse(t.due)
            if t.remind then
                local day = Dates.parse(t.remind.date)
                if day then t.remindAt = { day = day, minute = t.remind.minute } end
            end
        end
        tasks.ctx = ctx
        self:confirmTodo(todo, tasks, todo:defaultListId())
    end)
end

-- A task's dates as they read: "Due Fri 10/24 · Reminder 9 AM Thu 10/23".
local function datesText(t)
    local Dates = require("tododates")
    local parts = {}
    if t.dueDay then table.insert(parts, T(_("Due %1"), Dates.short(t.dueDay))) end
    if t.remindAt then
        table.insert(parts, T(_("Reminder %1 %2"), Dates.clock(t.remindAt.minute), Dates.short(t.remindAt.day)))
    end
    return table.concat(parts, " · ")
end

function Notes:confirmTodo(todo, tasks, listId)
    local lists = todo:orderedLists()
    local list
    for __, l in ipairs(lists) do
        if l.id == listId then list = l end
    end
    list = list or lists[1]
    if not list then return info(_("To Do has no lists yet. Sync To Do first.")) end
    local steps = 0
    for __, t in ipairs(tasks) do steps = steps + #t.steps end
    local dialog
    local again = function() self:confirmTodo(todo, tasks, list.id) end
    -- Each task: tap it for its dates.
    local buttons = {}
    for i, t in ipairs(tasks) do
        local parts = { (t.done and "☑ " or "☐ ") .. t.title }
        if #t.steps > 0 then table.insert(parts, #t.steps == 1 and _("1 step") or T(_("%1 steps"), #t.steps)) end
        local when = datesText(t)
        if when ~= "" then table.insert(parts, when) end
        table.insert(buttons, { { text = table.concat(parts, " · "), align = "left", font_bold = false, callback = function()
            UIManager:close(dialog)
            self:todoTask(todo, tasks, i, again)
        end } })
    end
    table.insert(buttons, { { text = T(_("List: %1"), list.name or list.title or "?"), callback = function()
        UIManager:close(dialog)
        local opts = {}
        for __, l in ipairs(lists) do table.insert(opts, { l.id, l.name or l.title or "?" }) end
        Settings.choose(_("Add to list"), opts, list.id, function(id)
            self:confirmTodo(todo, tasks, id or list.id)
        end, function() self:confirmTodo(todo, tasks, list.id) end)
    end } })
    table.insert(buttons, {
        { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
        { text = _("Add"), callback = function()
            UIManager:close(dialog)
            self:addTasks(todo, list.id, tasks)
        end },
    })
    dialog = KO.buttonDialog{
        title = T(_("Add to To Do: %1, %2\nTap a task to tick or untick it and its steps, or set its dates."),
            #tasks == 1 and _("1 task") or T(_("%1 tasks"), #tasks), steps == 1 and _("1 step") or T(_("%1 steps"), steps)),
        title_align = "center",
        buttons = buttons,
    }
end

-- A task before it is added: its tick and its steps' ticks (the AI may have
-- read a box wrong), its due date and reminder (set by hand, or the ones
-- read changed).
function Notes:todoTask(todo, tasks, i, back)
    local t = tasks[i]
    local today = todo:today()
    local Dates = require("tododates")
    local dialog
    local function row(text, fn)
        return { { text = text, align = "left", callback = function()
            UIManager:close(dialog)
            fn()
        end } }
    end
    local again = function() self:todoTask(todo, tasks, i, back) end
    local function box(done) return done and "☑  " or "☐  " end
    local buttons = {
        row(box(t.done) .. _("Done"), function()
            t.done = not t.done
            again()
        end),
    }
    if #t.steps > 0 then
        table.insert(buttons, Settings.heading(_("Steps")))
        for __, st in ipairs(t.steps) do
            table.insert(buttons, row(box(st.done) .. st.title, function()
                st.done = not st.done
                again()
            end))
        end
    end
    table.insert(buttons, Settings.heading(_("Dates")))
    for __, r in ipairs({
        row(T(_("Due date: %1"), t.dueDay and Dates.long(t.dueDay) or _("None")), function()
            todo:pickDate(t.dueDay or today, _("Due date"), function(day)
                -- The reminder moves with the due date, by as many days.
                if t.remindAt and t.dueDay then t.remindAt.day = t.remindAt.day + (day - t.dueDay) end
                t.dueDay = day
                again()
            end)
        end),
        row(T(_("Reminder: %1"), t.remindAt and (Dates.clock(t.remindAt.minute) .. ", " .. Dates.long(t.remindAt.day)) or _("None")),
            function()
                local minute = t.remindAt and t.remindAt.minute
                todo:pickDate(t.remindAt and t.remindAt.day or t.dueDay or today, _("Reminder day"), function(day)
                    todo:pickTime(minute, _("Reminder time"), function(m)
                        t.remindAt = { day = day, minute = m }
                        again()
                    end)
                end)
            end),
    }) do table.insert(buttons, r) end
    if t.dueDay or t.remindAt then
        table.insert(buttons, row(_("Clear the dates"), function()
            t.dueDay, t.remindAt = nil, nil
            again()
        end))
    end
    if #tasks > 1 then
        table.insert(buttons, row(_("Same dates for every task"), function()
            for __, other in ipairs(tasks) do
                other.dueDay = t.dueDay
                other.remindAt = t.remindAt and { day = t.remindAt.day, minute = t.remindAt.minute } or nil
            end
            back()
        end))
    end
    table.insert(buttons, { { text = _("Back"), callback = function() UIManager:close(dialog) back() end } })
    dialog = KO.buttonDialog{ title = t.title, title_align = "center", buttons = buttons }
end

function Notes:addTasks(todo, listId, tasks)
    local store = todo.store
    local added = 0
    local ids = {}
    for __, t in ipairs(tasks) do
        local fields = { title = t.title, due = t.dueDay }
        if t.remindAt then fields.remindAt = todo:moment(t.remindAt.day, t.remindAt.minute) end
        local id = store:addTask(listId, fields)
        if id then
            added = added + 1
            local steps = {}
            for __, st in ipairs(t.steps) do
                local sid = store:addStep(listId, id, st.title)
                table.insert(steps, sid or false)
                if sid and st.done then store:toggleStep(listId, id, sid) end
            end
            if t.done then store:toggleDone(listId, id) end
            table.insert(ids, { task = id, steps = steps })
        else
            ids.missing = true
        end
    end
    if not ids.missing then pcall(self.recordTodoLinks, self, tasks.ctx, listId, tasks, ids) end
    pcall(todo.changed, todo)
    KO.toast(T(_("Added %1 tasks to To Do"), added))
end

--- A whole notebook as one text file (Markdown, a heading a page) in
-- koreader/notes/export/: pages read before are kept; the rest are read by
-- Claude first.
function Notes:exportNotebookText(id)
    local nb, why = self.store:read(id)
    if not nb then return info(tostring(why)) end
    local unread = 0
    for __, page in ipairs(nb.pages) do
        if #page.strokes > 0 and not self:keptText(nb, page) then unread = unread + 1 end
    end
    local function save()
        local parts = { "# " .. nb.name, "" }
        for i, page in ipairs(nb.pages) do
            local text = #page.strokes == 0 and "" or (self:keptText(nb, page) or _("(not read)"))
            local typed = {}
            for __, it in ipairs(page.items or {}) do
                if it.k == "text" then table.insert(typed, it.text) end
            end
            if text ~= "" or #typed > 0 then
                table.insert(parts, T(_("## Page %1"), i))
                table.insert(parts, "")
                if #typed > 0 then
                    table.insert(parts, table.concat(typed, "\n\n"))
                    table.insert(parts, "")
                end
                if text ~= "" then
                    table.insert(parts, text)
                    table.insert(parts, "")
                end
            end
        end
        local util = require("util")
        local folder = DataStorage:getDataDir() .. "/notes/export"
        util.makePath(folder)
        local path = folder .. "/" .. util.getSafeFilename(nb.name) .. ".md"
        local f = io.open(path, "w")
        if not f then return info(_("Could not save the text.")) end
        local all = table.concat(parts, "\n")
        f:write(all)
        f:close()
        self:showText(nb.name, all, nil)
        KO.toast(T(_("Saved to %1"), path))
    end
    if unread == 0 then return save() end
    withClaude(self, function()
        local msg = busy(T(_("Reading %1 pages…"), unread))
        local function step(i)
            if i > #nb.pages then
                UIManager:close(msg)
                return save()
            end
            local page = nb.pages[i]
            if #page.strokes > 0 and not self:keptText(nb, page) then
                local text, err = self:pageTextNow(nb, i)
                if not text then
                    UIManager:close(msg)
                    return info(T(_("Could not read page %1:\n%2"), i, tostring(err)))
                end
            end
            UIManager:scheduleIn(0.1, function() step(i + 1) end)
        end
        step(1)
    end)
end

-- ------------------------------------------------------------------ search

-- Pages not read yet (or changed since), over all notebooks.
function Notes:unreadPages()
    local out = {}
    for __, entry in ipairs(self.store:list()) do
        local nb = self.store:read(entry.id)
        if nb then
            for i, page in ipairs(nb.pages) do
                if #page.strokes > 0 and not self:keptText(nb, page) then table.insert(out, { nb = nb, i = i }) end
            end
        end
    end
    return out
end

function Notes:readAllPages()
    local todo = self:unreadPages()
    if #todo == 0 then return info(_("Every page has been read.")) end
    withClaude(self, function()
        local msg = busy(T(_("Reading %1 pages…"), #todo))
        local n, failed = 0, nil
        local function step()
            n = n + 1
            local item = todo[n]
            if not item then
                UIManager:close(msg)
                KO.toast(T(_("Read %1 pages"), #todo))
                return
            end
            local text, why = self:pageTextNow(item.nb, item.i)
            if not text then
                failed = why
                UIManager:close(msg)
                logger.warn("Notes: reading a page failed", why)
                return info(T(_("Stopped after %1 pages:\n%2"), n - 1, tostring(failed)))
            end
            UIManager:scheduleIn(0.1, step)
        end
        step()
    end)
end

function Notes:search()
    local dialog
    -- The launcher's box: what to look for (or the pen), Cancel and Search.
    local request = KO.request()
    if request then
        return request{ title = _("Search notebooks"), text = self.lastSearch or "",
            hint = _("Words in names, text or handwriting"), pen = KO.pen(), penTitle = _("Write what to look for"),
            typing = true,
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = "search", text = _("Search"), primary = true, needsText = true, fn = function(q)
                    self.lastSearch = q
                    self:showResults(q)
                end },
            } }
    end
    dialog = InputDialog:new{
        title = _("Search notebooks"),
        input = self.lastSearch or "",
        buttons = { KO.compact{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            KO.writeButton(function() return dialog end, { kind = "name" }),
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = dialog:getInputText():match("^%s*(.-)%s*$")
                UIManager:close(dialog)
                if q ~= "" then
                    self.lastSearch = q
                    self:showResults(q)
                end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Notes:showResults(q)
    -- Typed text and handwriting read before: found at once, no AI.
    local items = {}
    local KIND = { typed = _("text"), handwriting = _("handwriting"), name = _("name") }
    for __, r in ipairs(self:findText(q)) do
        table.insert(items, {
            text = r.snippet,
            mandatory = r.kind == "name" and KIND.name or T(_("%1 · p. %2"), r.name, r.page),
            callback = function() self:open(r.nb, r.page) end,
        })
    end
    local unread = self:anyAI() and #self:unreadPages() or 0
    if unread > 0 then
        table.insert(items, { text = unread == 1 and _("1 page not read yet: read it with AI")
            or T(_("%1 pages not read yet: read them with AI"), unread), bold = true,
            callback = function() self:readAllPages() end })
    end
    if #items == 0 then table.insert(items, { text = _("Nothing found."), dim = true }) end
    local page
    -- (A result opens over the list closed.)
    for __, it in ipairs(items) do
        local fn = it.callback
        if fn then it.callback = function() UIManager:close(page) fn() end end
    end
    page = self:listPage(T(_("\"%1\""), q), items)
end

end
