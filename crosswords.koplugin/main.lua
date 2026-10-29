--[[--
Crosswords: the Guardian's, USA Today's, Universal's, the Washington Post's
and the New Yorker's crosswords, and puzzle books (PDFs, .puz and .ipuz
files), solved with the pen.

Tools > Crosswords (or a gesture: General > Crosswords) lists the puzzle
books; Today's crossword (a gesture, or the launcher's tile) opens the newest.
The puzzles are written on with Notes' pen and kept as Notes notebooks, so
Notes has to be installed too: this plugin adds the crossword parts to it
(crosswordsui.lua) and Notes leaves the puzzle books out of its own list.

@module koplugin.crosswords
]]

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Crosswords = WidgetContainer:extend{
    name = "crosswords",
    is_doc_only = false,
}

-- Notes' plugin (as KOReader loaded it), with the crossword parts added the
-- first time; nil without Notes.
local function notesPlugin()
    local ok, PluginLoader = pcall(require, "pluginloader")
    for __, p in ipairs(ok and PluginLoader.enabled_plugins or {}) do
        if p.name == "notes" then
            if not p.crosswordTap then require("crosswordsui")(p) end
            return p
        end
    end
end

function Crosswords:init()
    local ok, err = pcall(notesPlugin)
    if not ok then require("logger").warn("Crosswords: could not add to Notes:", err) end
    Dispatcher:registerAction("crosswords_show", { category = "none", event = "ShowCrosswords", title = _("Crosswords"),
        general = true })
    -- (The name it had in Notes, so a gesture set up then still works.)
    Dispatcher:registerAction("notes_crossword", { category = "none", event = "TodaysCrossword", title = _("Today's crossword"),
        general = true })
    self.ui.menu:registerToMainMenu(self)
    -- The launcher's Settings list and search (when the launcher is installed).
    local PS = require("pluginshare")
    -- What it is for the launcher and the web page: its tiles, Settings group, web tab
    -- (apps.koplugin/appsinfo.lua).
    PS.appInfo = PS.appInfo or {}
    PS.appInfo.crosswords = { name = _("Crosswords"), icon = "newspaper", dir = self.path, order = 40, group = "writing",
        explore = _("Daily crosswords to solve with the pen"),
        tiles = { { key = "crosswords", icon = "grid-3x3", event = "ShowCrosswords",
            line = function(c) return c:appsLine() end } },
        web = { page = "crosswords", routes = "webcrosswords", script = "web/crosswords.js",
            card = "Puzzle books, and getting new crosswords." } }
    if PS.registerSettings then
        PS.registerSettings{ key = "crosswords", name = _("Crosswords"), icon = "newspaper", open = function()
            local notes = self:notes()
            if notes then notes:crosswordSettings() end
        end,
        -- Each setting by name, for the launcher's search (they all fit on one page).
        settings = function()
            local notes = self.ui.notes
            if not (notes and notes.crosswordSettings) then return {} end
            local out = {}
            for __, r in ipairs(notes:crosswordSettings(nil, true) or {}) do
                local name = r.text and (r.text:match("^(.-):") or r.text)
                if name then
                    table.insert(out, { name = name, where = _("Crossword settings"), open = function() notes:crosswordSettings() end })
                end
            end
            return out
        end }
    end
    -- Test connection (the launcher's appstest.lua): a light request to each
    -- source this Kindle gets puzzles from.
    if PS.registerTest then
        PS.registerTest{ key = "crosswords", name = _("Crosswords"),
            configured = function()
                local notes = self.ui.notes
                return notes ~= nil and notes.crosswordsSourcesUsed ~= nil and notes:crosswordsSourcesUsed() ~= nil
            end,
            run = function(Test)
                local notes = self.ui.notes
                if not (notes and notes.crosswordsTestRows) then return {} end
                return notes:crosswordsTestRows(Test)
            end }
    end
    -- A launcher quick button: a random puzzle (listed under Crossword… when adding a button).
    if PS.registerQuick then
        PS.registerQuick{ key = "notes", name = _("Crossword"),
            choices = function() return { { id = "random", name = _("Random puzzle"), icon = "shuffle" } } end,
            item = function()
                local notes = self.ui.notes
                if not (notes and notes.randomPuzzle) then return nil end
                return { label = _("Random puzzle"), icon = "shuffle",
                    tap = function(done)
                        done()
                        notes:randomPuzzle()
                    end,
                    hold = function() self:show() end }
            end }
    end
    if PS.registerSearch then
        PS.registerSearch{ key = "crosswords", name = _("Crosswords"), icon = "newspaper", search = function(q)
            local notes = self.ui.notes
            return notes and notes.crosswordsSearch and notes:crosswordsSearch(q) or {}
        end }
    end
end

--- Notes, with the crossword parts; nil (and why, shown) without it.
function Crosswords:notes()
    local notes = self.ui.notes
    if notes and notes.crosswordTap then return notes end
    local text = _("Crosswords needs the Notes plugin. Turn it on in Plugin management, or install it.")
    -- (The apps' message when the launcher has it, else KOReader's.)
    local P = require("pluginshare").popup
    local ok, show = pcall(function() return P and P.message end)
    if ok and show then return show{ text = text } end
    UIManager:show(InfoMessage:new{ text = text })
end

function Crosswords:addToMainMenu(menu_items)
    menu_items.crosswords = {
        text = _("Crosswords"),
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

--- The puzzle books, as their own app.
function Crosswords:show()
    local notes = self:notes()
    if notes then notes:showCrosswords() end
end

function Crosswords:onShowCrosswords()
    self:show()
    return true
end

function Crosswords:onTodaysCrossword()
    local notes = self:notes()
    if notes then notes:todaysCrossword() end
    return true
end

--- The launcher's tile line: today's puzzle, "Guardian · Wed 21 Oct · Started", or
-- "Not downloaded yet".
function Crosswords:appsLine()
    local notes = self.ui.notes
    if not (notes and notes.todaysCrosswordInfo) then return "" end
    local info = notes:todaysCrosswordInfo() or {}
    local parts = { info.name }
    if not info.have then
        table.insert(parts, _("Not downloaded yet"))
    else
        if info.day then table.insert(parts, os.date("!%a %d %b", info.day * 86400)) end
        local states = { new = _("New"), started = _("Started"), done = _("Done") }
        table.insert(parts, states[info.state])
    end
    return table.concat(parts, " \u{00B7} ")
end

return Crosswords
