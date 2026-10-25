--[[--
Notes' settings (kept in KOReader's settings under "notes") and the dialog
that changes them, shared by the notebook list and the editor.
]]
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local KO = require("notesko")

local Settings = {}

local DEFAULTS = {
    side = "left",                       -- the toolbar's edge
    order = { "pen", "hl", "eraser", "lasso", "shapes", "text", "insert", "zoom", "undo", "redo", "g:tidy" },
    -- Toolbar groups: one button for several tools or actions (Settings.GROUPS).
    groups = { add = { "shapes", "text", "insert" }, tidy = { "tidy", "tidy_level", "tidy_upright", "tidy_size", "tidy_space" } },
    folded = false,                      -- open notebooks with the toolbar folded away
    quick_buttons = true,                -- a quick note's Peek, Swap, Discard and Save by its handle
    side_button = "eraser",              -- what the pen's side button does: eraser, lasso, hl, ruler, none
    whole_eraser = false,                -- the eraser takes whole strokes
    eraser_hl = false,                   -- the eraser takes only highlighter (and shader) strokes
    pen_feel = "normal",                 -- how hard to press for a wide line: soft, normal, firm
    spread = {},                         -- portrait notebooks shown two pages side by side ({ [id] = true })
    spread_turn = true,                  -- turning the Kindle on its side shows two pages (and back, one)
    paper = "narrow",                    -- template for new notebooks
    pressure = true,                     -- pen pressure in new notebooks
    sort = "modified",                   -- notebook list: modified, name, created, custom
    custom = {},                         -- notebook ids in the user's order
    sort_default = "last",               -- the sort Notes starts with: last (the one used last) or one of sort's
    tip = "pen",                         -- the pen tip last used
    sizes = { pen = 2, fountain = 2, marker = 2, pencil = 2, hl = 3 },
    eraser_size = 3,
    shape = "rect",                      -- the Shapes tool's shape
    table_rows = 3,
    table_cols = 3,
    snap_hold = true,                    -- hold the pen still at the end of a stroke: a clean shape
    level_lines = true,                  -- lines near level, upright or 45 degrees made exactly so
    join_ends = true,                    -- ends of lines and arrows join ink nearby
    smooth = 0,                          -- smoothing of handwriting: 0 off, 1 light, 2 strong
    deghost = 6,                         -- a flashing refresh every this many pauses in writing (0: never)
    buttons = {},                        -- actions with a toolbar button (Settings.ACTIONS; Refresh and Settings are always there)
    hidden = {},                         -- tools and groups taken off the toolbar (in the ⋯ menu's Tools instead)
    page_buttons = { pages = true, addpage = true },   -- All pages and + page at the toolbar's bottom
    swipe_pages = "vertical",            -- a finger swipe turns the page: vertical, horizontal or off
    status = true,                       -- the time and battery on Notes' screens
    paper_lines = "medium",              -- how dark templates are: light, medium, dark
    show_recent = true,                  -- (older: false turned Recent notebooks off)
    recent_mode = "folder",              -- the notebooks opened last: "folder" (a Recent folder), "top" (atop the list), "off"
    pinned = {},                         -- notebooks pinned to the top (ids)
    page_header = false,                 -- the date and page number at the top of each page
    finger_undo = true,                  -- two fingers: tap to undo, hold to redo
    close_action = "auto",               -- closing a notebook: "auto" saves, "ask" asks (Save, Rename, Don't save)
    suggest_names = false,               -- the AI suggests a name for notebooks still named by date
    name_date = "off",                   -- the date added to names you give: off, before, after
    zoom_strip = 1,                      -- where the zoom strip is: 0 the top of the page, 1 the bottom
    ko_gestures = true,                  -- your KOReader gestures (two fingers, edge swipes, multiswipes) for the light, refresh, Wi-Fi, … work in Notes
}

Settings.TOOLS = {
    pen = _("Pen"), hl = _("Highlighter"), eraser = _("Eraser"), lasso = _("Lasso"), shapes = _("Shapes"),
    text = _("Text"), insert = _("Insert (picture, tape)"), zoom = _("Zoom window"), undo = _("Undo"), redo = _("Redo"),
}
-- The tools' toolbar icons (the pen's follows its tip on the Kindle).
Settings.TOOL_ICONS = { pen = "pen", hl = "highlighter", eraser = "eraser", lasso = "lasso-select", shapes = "shapes",
    text = "type", insert = "image", zoom = "zoom-in", undo = "undo-2", redo = "redo-2" }
-- Actions that can have a toolbar button (they are in the ⋯ menu too).
Settings.ACTIONS = {
    { key = "onenote", label = _("Send to OneNote"), icon = "cloud-upload" },
    { key = "ask", label = _("Ask AI"), icon = "sparkles" },
    { key = "totext", label = _("Convert page to text"), icon = "scan-text" },
    { key = "todo", label = _("Add page to To Do"), icon = "list-checks" },
    { key = "bookmark", label = _("Bookmark page"), icon = "star" },
    { key = "datetime", label = _("Date and time"), icon = "calendar" },
    { key = "export", label = _("Export"), icon = "file-down" },
    { key = "tidy", label = _("Tidy handwriting"), icon = "wand" },
    { key = "tidy_level", label = _("Level lines"), icon = "baseline" },
    { key = "tidy_upright", label = _("Upright letters"), icon = "italic" },
    { key = "tidy_size", label = _("Even size"), icon = "a-large-small" },
    { key = "tidy_space", label = _("Even spacing"), icon = "space" },
    { key = "light", label = _("Light"), icon = "sun" },
    { key = "night", label = _("Night mode"), icon = "moon" },
    { key = "refresh", label = _("Refresh screen"), icon = "refresh-cw" },
    { key = "settings", label = _("Settings"), icon = "settings" },
}
Settings.ACTION = {}
for __, a in ipairs(Settings.ACTIONS) do Settings.ACTION[a.key] = a end
-- Always at the toolbar's bottom (not in Toolbar buttons…).
Settings.FIXED = { refresh = true, settings = true }

--- How the notebooks opened last show in the list: "folder", "top" or "off".
function Settings.recentMode()
    local all = G_reader_settings:readSetting("notes") or {}
    if all.recent_mode == nil and all.show_recent == false then return "off" end
    local m = Settings.get("recent_mode")
    return (m == "top" or m == "off") and m or "folder"
end

--- Toolbar groups: a button whose list holds several tools or actions.
Settings.GROUPS = {
    add = { label = _("Add"), icon = "square-plus" },
    tidy = { label = _("Tidy"), icon = "wand" },
}
Settings.GROUP_ORDER = { "add", "tidy" }

--- The groups with something in them: { [name] = { key, … } }.
--- With no AI service set up, everything that needs one is left out of the
-- toolbar, its groups and its menus (Notes sets this; true = no AI).
Settings.noAI = function() return false end
Settings.AI_ACTION = { ask = true, totext = true, todo = true }

--- Whether a toolbar action can show now (an AI one only with an AI set up).
function Settings.actionShown(key)
    return not (Settings.AI_ACTION[key] and Settings.noAI())
end

function Settings.groups()
    local out = {}
    for name, keys in pairs(Settings.get("groups") or {}) do
        if Settings.GROUPS[name] then
            local list = {}
            for __, key in ipairs(keys) do
                if Settings.TOOLS[key] or (Settings.ACTION[key] and Settings.actionShown(key)) then table.insert(list, key) end
            end
            if #list > 0 then out[name] = list end
        end
    end
    return out
end

-- What a toolbar key is called: a tool, an action or a group.
function Settings.buttonName(key)
    local g = type(key) == "string" and key:match("^g:(.+)$")
    if g and Settings.GROUPS[g] then return T(_("%1 (group)"), Settings.GROUPS[g].label) end
    return Settings.TOOLS[key] or (Settings.ACTION[key] and Settings.ACTION[key].label) or key
end

Settings.PAPER_NAMES = {
    plain = _("Blank"), narrow = _("Narrow ruled"), wide = _("Wide ruled"), grid = _("Grid"), dots = _("Dots"),
    checklist = _("Checklist"), tasks = _("Tasks and subtasks"), cornell = _("Cornell notes"), weekly = _("Week planner"),
    music = _("Music staves"), margin = _("Ruled with margin"), isometric = _("Isometric dots"), hex = _("Hexagons"),
    calendar = _("Month calendar"),
}
local SIDE_BUTTON = { eraser = _("Eraser"), lasso = _("Lasso"), hl = _("Highlighter"), ruler = _("Ruler (straight lines)"), none = _("Nothing") }
local SMOOTH = { [0] = _("Off"), _("Light"), _("Strong") }
local DEGHOST = { [6] = _("Every 6 pauses"), [3] = _("Every 3 pauses"), [1] = _("Every pause"), [0] = _("Never") }
local SWIPE = { vertical = _("Swipe up and down"), horizontal = _("Swipe left and right"), off = _("Off") }
local SORT = { modified = _("Date modified"), name = _("Name"), created = _("Date created"), custom = _("My order") }
Settings.SORT = SORT
Settings.SORT_KEYS = { "name", "created", "modified", "custom" }
local SORT_DEFAULT = { last = _("Last used"), name = _("Name"), created = _("Date created"), modified = _("Date modified"),
    custom = _("My order") }
local CLOSE = { auto = _("Save automatically"), ask = _("Ask") }
local LINES = { light = _("Light"), medium = _("Medium"), dark = _("Dark") }
local FEEL = { soft = _("Soft"), normal = _("Normal"), firm = _("Firm") }
local RECENT = { folder = _("As a folder"), top = _("At the top"), off = _("Off") }
local NAME_DATE = { off = _("Off"), before = _("Before the name"), after = _("After the name") }

-- Your own starting values (your AI server's address, say), from
-- notes_defaults.lua beside this file when there is one (it is not in the
-- repository): return { server_home = "http://…:11434", ... }.
do
    local dir = (debug.getinfo(1, "S").source or ""):match("^@(.*/)") or ""
    local ok, mine = pcall(dofile, dir .. "notes_defaults.lua")
    if ok and type(mine) == "table" then
        for k, v in pairs(mine) do DEFAULTS[k] = v end
    end
end

local function all()
    local t = G_reader_settings:readSetting("notes")
    if type(t) ~= "table" then
        t = {}
        -- Before these settings: the eraser's one switch.
        if G_reader_settings:isTrue("notes_whole_stroke_eraser") then t.whole_eraser = true end
        G_reader_settings:saveSetting("notes", t)
    end
    return t
end

function Settings.get(key)
    local value = all()[key]
    if value == nil then return DEFAULTS[key] end
    return value
end

function Settings.set(key, value)
    local t = all()
    t[key] = value
    G_reader_settings:saveSetting("notes", t)
end

--- The toolbar's tools in the user's order (new tools added at the end).
--- The toolbar's buttons in order: every tool, and the actions you added.
function Settings.toolOrder()
    local out, seen = {}, {}
    local added = {}
    for __, key in ipairs(Settings.get("buttons") or {}) do
        if Settings.ACTION[key] and not Settings.FIXED[key] and Settings.actionShown(key) then added[key] = true end
    end
    -- A tool or action in a group: the group's button where it would be.
    local groups, inGroup = Settings.groups(), {}
    for name, keys in pairs(groups) do
        for __, key in ipairs(keys) do inGroup[key] = name end
    end
    local hidden = {}
    for __, key in ipairs(Settings.get("hidden") or {}) do hidden[key] = true end
    local function put(key)
        if inGroup[key] then key = "g:" .. inGroup[key] end
        if hidden[key] then return end
        if not seen[key] then
            table.insert(out, key)
            seen[key] = true
        end
    end
    local function valid(key)
        local g = key:match("^g:(.+)$")
        if g then return groups[g] ~= nil end
        return Settings.TOOLS[key] or added[key] or inGroup[key]
    end
    for __, key in ipairs(Settings.get("order")) do
        if valid(key) then put(key) end
    end
    for __, key in ipairs(DEFAULTS.order) do
        if valid(key) then put(key) end
    end
    for __, name in ipairs(Settings.GROUP_ORDER) do
        if groups[name] then put("g:" .. name) end
    end
    for __, a in ipairs(Settings.ACTIONS) do
        if added[a.key] then put(a.key) end
    end
    return out
end

--- The tools and groups taken off the toolbar (they are in the ⋯ menu's
-- Tools): { key, … } in toolbar order, groups as their tools.
function Settings.hiddenTools()
    local hidden = {}
    for __, key in ipairs(Settings.get("hidden") or {}) do hidden[key] = true end
    local groups, inGroup = Settings.groups(), {}
    for name, keys in pairs(groups) do
        for __, key in ipairs(keys) do inGroup[key] = name end
    end
    local out, seen = {}, {}
    local function add(key)
        if not seen[key] then
            seen[key] = true
            table.insert(out, key)
        end
    end
    local order = {}
    for __, key in ipairs(Settings.get("order") or {}) do table.insert(order, key) end
    for __, key in ipairs(DEFAULTS.order) do table.insert(order, key) end
    for __, key in ipairs(order) do
        local g = key:match("^g:(.+)$")
        if g and hidden[key] then
            for __, k in ipairs(groups[g] or {}) do add(k) end
        elseif Settings.TOOLS[key] and (hidden[key] or (inGroup[key] and hidden["g:" .. inGroup[key]])) then
            add(key)
        end
    end
    return out
end

--- Settings > Toolbar > Toolbar buttons…: every button the toolbar can
-- have, in its order, to move (the arrows) and to show or hide (the eye).
-- Tools and groups hidden go to the ⋯ menu's Tools; actions are in the ⋯
-- menu anyway.
function Settings.editToolbar(changed)
    local groups, inGroup = Settings.groups(), {}
    for name, keys in pairs(groups) do
        for __, key in ipairs(keys) do inGroup[key] = name end
    end
    -- The rows: what is on the toolbar (`onBar`, in order), then the rest.
    local function listOf(onBar)
        local items, listed = {}, {}
        local function add(key, shown)
            if listed[key] then return end
            listed[key] = true
            table.insert(items, { key = key, text = Settings.buttonName(key), shown = shown })
        end
        for __, key in ipairs(onBar) do add(key, true) end
        for __, key in ipairs(DEFAULTS.order) do
            if Settings.TOOLS[key] and not inGroup[key] then add(key, false) end
        end
        for __, name in ipairs(Settings.GROUP_ORDER) do
            if groups[name] then add("g:" .. name, false) end
        end
        for __, a in ipairs(Settings.ACTIONS) do
            if not inGroup[a.key] and not Settings.FIXED[a.key] and Settings.actionShown(a.key) then add(a.key, false) end
        end
        return items
    end
    -- The toolbar as it starts: the tools in their order (grouped ones as
    -- their group) and Refresh screen.
    local start, seen = {}, {}
    for __, key in ipairs(DEFAULTS.order) do
        local k = inGroup[key] and ("g:" .. inGroup[key]) or key
        if not seen[k] and (Settings.TOOLS[k] or (k:match("^g:") and groups[k:sub(3)])) then
            seen[k] = true
            table.insert(start, k)
        end
    end
    for __, key in ipairs(DEFAULTS.buttons) do
        if not inGroup[key] and not Settings.FIXED[key] then table.insert(start, key) end
    end
    require("ui/uimanager"):show(require("notesreorder"):new{ title = _("Toolbar buttons"), items = listOf(Settings.toolOrder()),
        defaults = listOf(start), done = function(keys, shown)
        local order, hid, buttons = {}, {}, {}
        for __, key in ipairs(keys) do
            table.insert(order, key)
            if Settings.ACTION[key] then
                if shown[key] then table.insert(buttons, key) end
            elseif not shown[key] then
                table.insert(hid, key)
            end
        end
        Settings.set("order", order)
        Settings.set("hidden", hid)
        Settings.set("buttons", buttons)
        if changed then changed() end
    end }, "full")
end

--- Settings > Toolbar > Groups: what is in each group. Taking something out
-- puts it on the toolbar on its own (an action as a toolbar button).
function Settings.editGroups(changed)
    local dialog
    local rows = {}
    local groups = Settings.get("groups") or {}
    for __, name in ipairs(Settings.GROUP_ORDER) do
        local names = {}
        for __, key in ipairs(groups[name] or {}) do table.insert(names, Settings.buttonName(key)) end
        table.insert(rows, { { text = Settings.GROUPS[name].label .. ": " .. (#names > 0 and table.concat(names, ", ") or _("empty")),
            align = "left", callback = function()
                UIManager:close(dialog)
                Settings.editGroup(name, function()
                    if changed then changed() end
                    Settings.editGroups(changed)
                end)
            end } })
    end
    table.insert(rows, { { text = _("Close"), callback = function() UIManager:close(dialog) end } })
    dialog = KO.buttonDialog{ title = _("Toolbar groups\n\nA group is one toolbar button that opens a list."),
        title_align = "center", buttons = rows }
end

function Settings.editGroup(name, done)
    local dialog
    local all = Settings.get("groups") or {}
    local keys = all[name] or {}
    local inThis, inOther = {}, {}
    for __, k in ipairs(keys) do inThis[k] = true end
    for other, list in pairs(all) do
        if other ~= name then for __, k in ipairs(list) do inOther[k] = Settings.GROUPS[other] and Settings.GROUPS[other].label end end
    end
    local function toggle(key)
        local groups = {}
        for g, list in pairs(all) do groups[g] = { unpack(list) } end
        local list = groups[name] or {}
        if inThis[key] then
            for i = #list, 1, -1 do if list[i] == key then table.remove(list, i) end end
            -- Out of the group: on the toolbar by itself.
            if Settings.ACTION[key] then
                local buttons = Settings.get("buttons") or {}
                local has = false
                for __, b in ipairs(buttons) do if b == key then has = true end end
                if not has then table.insert(buttons, key) Settings.set("buttons", buttons) end
            end
        else
            -- In one group at a time.
            for g, other in pairs(groups) do
                if g ~= name then for i = #other, 1, -1 do if other[i] == key then table.remove(other, i) end end end
            end
            table.insert(list, key)
        end
        groups[name] = list
        Settings.set("groups", groups)
    end
    local rows = {}
    local candidates = {}
    for __, key in ipairs(DEFAULTS.order) do if Settings.TOOLS[key] then table.insert(candidates, key) end end
    for __, a in ipairs(Settings.ACTIONS) do table.insert(candidates, a.key) end
    for __, key in ipairs(candidates) do
        local note = inOther[key] and not inThis[key] and ("  (" .. T(_("in %1"), inOther[key]) .. ")") or ""
        local text = inThis[key] and T(_("Remove %1"), Settings.buttonName(key)) or T(_("Add %1"), Settings.buttonName(key))
        table.insert(rows, { { text = text .. note, align = "left", bold = inThis[key] or nil, callback = function()
            UIManager:close(dialog)
            toggle(key)
            Settings.editGroup(name, done)
        end } })
    end
    table.insert(rows, { { text = _("Back"), callback = function()
        UIManager:close(dialog)
        if done then done() end
    end } })
    dialog = KO.buttonDialog{ title = T(_("In the %1 group"), Settings.GROUPS[name].label), title_align = "center", buttons = rows }
end

-- Actions with a toolbar button: pick them (and then drag them in the order).
function Settings.pickButtons(done)
    local dialog
    local on = {}
    for __, key in ipairs(Settings.get("buttons") or {}) do on[key] = true end
    local buttons = {}
    for __, a in ipairs(Settings.ACTIONS) do
        table.insert(buttons, { { text = (on[a.key] and "✓  " or "      ") .. a.label, align = "left", callback = function()
            on[a.key] = not on[a.key]
            local keys = {}
            for __, b in ipairs(Settings.ACTIONS) do
                if on[b.key] then table.insert(keys, b.key) end
            end
            Settings.set("buttons", keys)
            UIManager:close(dialog)
            Settings.pickButtons(done)
        end } })
    end
    table.insert(buttons, { { text = _("Done"), callback = function()
        UIManager:close(dialog)
        if done then done() end
    end } })
    dialog = KO.buttonDialog{
        title = _("Toolbar buttons\n\nAdd actions from the ⋯ menu to the toolbar. Toolbar order puts them where you want."),
        title_align = "center",
        buttons = buttons,
    }
end

--- A list to pick one of `options` ({ value, label }...) from, the current
-- one ticked. `done(value)` gets the pick, or nil when it closes without one.
function Settings.choose(title, options, current, done, back)
    -- (The apps' pop-up: notesko. `back()`: Back to the menu it came from.)
    local list = {}
    for __, o in ipairs(options) do table.insert(list, { label = o[2], value = o[1] }) end
    require("notesko").choose(title, list, current, done, back)
end

local function options(keys, names)
    local out = {}
    for __, k in ipairs(keys) do table.insert(out, { k, names[k] }) end
    return out
end

--- Things in `items` ({ text = ..., key = ... }) put in order by the user;
-- `done(keys)` gets the new order.
function Settings.reorder(title, items, done)
    -- (items with `shown` get an eye; done(keys, shown).)
    -- Notes' own reorder screen (to the top, up, down, to the bottom, Undo).
    UIManager:show(require("notesreorder"):new{ title = title, items = items, done = done }, "full")
end

-- A heading between groups of settings.
function Settings.heading(text)
    return { { text = text, enabled = false, align = "left", font_bold = true } }
end

--- The settings, full pages (notessettingspage), in sections. `changed()`
-- runs after any change; `extra` adds to them: { list = { { text, fn }... }
-- (notebook list), connections = { ... }, top = { rows first }, kui =
-- KOReader's library or book (night mode), title = the title bar's home(),
-- bell(), bellCount(), menu() }.
function Settings.show(changed, extra)
    extra = extra or {}
    local KO = require("notesko")
    local page
    local function again() if page then page:refresh() end end
    local function done()
        if changed then changed() end
        again()
    end
    local function build()
    -- A setting changed in place (the page shows its new value).
    local function row(text, fn)
        return { text = text, kind = "row", fn = function()
            fn()
            done()
        end }
    end
    -- Opens something else (over the settings; they show again when it closes).
    local function open(text, fn)
        return { text = text, kind = "open", fn = fn }
    end
    local function onOff(v) return v and _("On") or _("Off") end
    -- A setting with more than two values: a list to pick from.
    local function pick(text, title, opts, key, default)
        return { text = text, kind = "pick", fn = function()
            local current = Settings.get(key)
            if current == nil then current = default end
            Settings.choose(title, opts, current, function(v)
                if v ~= nil then
                    Settings.set(key, v)
                    done()
                end
            end)
        end }
    end
    local function heading(text) return { heading = text } end
    local buttons = {}
    local function add(r) table.insert(buttons, r) end

    -- (Light, Night mode and Refresh screen are in ⋮ on the title bar.)
    add(heading(_("Display")))
    add(pick(T(_("Full refresh: %1"), DEGHOST[Settings.get("deghost")] or DEGHOST[6]), _("Full refresh"),
        options({ 6, 3, 1, 0 }, DEGHOST), "deghost", 6))
    add(row(T(_("Page header (date and page number): %1"), onOff(Settings.get("page_header"))), function()
        Settings.set("page_header", not Settings.get("page_header"))
    end))
    add(pick(T(_("Template lines: %1"), LINES[Settings.get("paper_lines")] or LINES.medium), _("Template lines"),
        options({ "light", "medium", "dark" }, LINES), "paper_lines", "medium"))
    add(row(T(_("KOReader gestures (two fingers, edge swipes): %1"), onOff(Settings.get("ko_gestures") ~= false)), function()
        Settings.set("ko_gestures", Settings.get("ko_gestures") == false)
    end))

    add(heading(_("Toolbar")))
    add(row(T(_("Side: %1"), Settings.get("side") == "left" and _("Left") or _("Right")), function()
        Settings.set("side", Settings.get("side") == "left" and "right" or "left")
    end))
    add(open(_("Toolbar buttons…"), function()
        Settings.editToolbar(function() if changed then changed() end end)
    end))
    do
        local pb = Settings.get("page_buttons") or {}
        add(row(T(_("All pages button: %1"), onOff(pb.pages ~= false)), function()
            pb.pages = pb.pages == false
            Settings.set("page_buttons", pb)
        end))
        add(row(T(_("Add page button: %1"), onOff(pb.addpage ~= false)), function()
            pb.addpage = pb.addpage == false
            Settings.set("page_buttons", pb)
        end))
    end
    add(open(_("Groups…"), function()
        Settings.editGroups(function() if changed then changed() end end)
    end))
    add(row(T(_("Start with toolbar hidden: %1"), onOff(Settings.get("folded"))), function()
        Settings.set("folded", not Settings.get("folded"))
    end))
    add(row(T(_("Quick note buttons by the handle: %1"), onOff(Settings.get("quick_buttons"))), function()
        Settings.set("quick_buttons", not Settings.get("quick_buttons"))
    end))

    add(heading(_("Writing")))
    add(pick(T(_("Pen side button: %1"), SIDE_BUTTON[Settings.get("side_button")] or SIDE_BUTTON.eraser), _("Pen side button"),
        options({ "eraser", "lasso", "hl", "ruler", "none" }, SIDE_BUTTON), "side_button", "eraser"))
    add(pick(T(_("Turn pages with a finger: %1"), SWIPE[Settings.get("swipe_pages")] or SWIPE.off), _("Turn pages with a finger"),
        options({ "vertical", "horizontal", "off" }, SWIPE), "swipe_pages", "vertical"))
    add(row(T(_("Eraser: %1"), Settings.get("whole_eraser") and _("Whole stroke") or _("Partial")), function()
        Settings.set("whole_eraser", not Settings.get("whole_eraser"))
    end))
    add(row(T(_("Eraser: highlighter only: %1"), onOff(Settings.get("eraser_hl"))), function()
        Settings.set("eraser_hl", not Settings.get("eraser_hl"))
    end))
    add(pick(T(_("Pen pressure: %1"), FEEL[Settings.get("pen_feel")] or FEEL.normal), _("Pen pressure"),
        options({ "soft", "normal", "firm" }, FEEL), "pen_feel", "normal"))
    add(row(T(_("Two pages when turned on its side: %1"), onOff(Settings.get("spread_turn") ~= false)), function()
        Settings.set("spread_turn", Settings.get("spread_turn") == false)
    end))
    add(pick(T(_("Stroke smoothing: %1"), SMOOTH[Settings.get("smooth")] or SMOOTH[0]), _("Stroke smoothing"),
        options({ 0, 1, 2 }, SMOOTH), "smooth", 0))
    local favs = Settings.get("favorites") or {}
    local startNames = { last = _("Last used") }
    local startKeys = { "last" }
    for i = 1, #favs do
        startNames["fav" .. i] = T(_("Favorite %1"), i)
        table.insert(startKeys, "fav" .. i)
    end
    add(pick(T(_("Starting pen: %1"), startNames[Settings.get("start_pen") or "last"] or startNames.last),
        _("Starting pen"), options(startKeys, startNames), "start_pen", "last"))
    add(row(T(_("Favorite pens: %1 (tap to clear)"), #(Settings.get("favorites") or {})), function()
        Settings.set("favorites", {})
    end))
    add(row(T(_("Two-finger tap to undo (hold to redo): %1"), onOff(Settings.get("finger_undo") ~= false)), function()
        Settings.set("finger_undo", Settings.get("finger_undo") == false)
    end))
    add(pick(T(_("When closing: %1"), CLOSE[Settings.get("close_action")] or CLOSE.auto), _("When closing a notebook"),
        options({ "auto", "ask" }, CLOSE), "close_action", "auto"))

    add(heading(_("Shapes")))
    add(row(T(_("Shape recognition (hold the pen): %1"), onOff(Settings.get("snap_hold"))), function()
        Settings.set("snap_hold", not Settings.get("snap_hold"))
    end))
    add(row(T(_("Snap lines to 0°, 45°, 90°: %1"), onOff(Settings.get("level_lines"))), function()
        Settings.set("level_lines", not Settings.get("level_lines"))
    end))
    add(row(T(_("Snap line ends to ink: %1"), onOff(Settings.get("join_ends"))), function()
        Settings.set("join_ends", not Settings.get("join_ends"))
    end))

    add(heading(_("New notebooks")))
    add(pick(T(_("Template: %1"), Settings.PAPER_NAMES[Settings.get("paper")] or Settings.PAPER_NAMES.narrow),
        _("Template for new notebooks"),
        options({ "plain", "narrow", "margin", "wide", "grid", "dots", "isometric", "hex", "checklist", "tasks", "cornell",
            "weekly", "calendar", "music" }, Settings.PAPER_NAMES),
        "paper", "narrow"))
    add(row(T(_("Pen pressure: %1"), onOff(Settings.get("pressure"))), function()
        Settings.set("pressure", not Settings.get("pressure"))
    end))
    add(pick(T(_("Add the date to names: %1"), NAME_DATE[Settings.get("name_date")] or NAME_DATE.off),
        _("Add the date to names"), options({ "off", "before", "after" }, NAME_DATE), "name_date", "off"))
    if not Settings.noAI() then add(row(T(_("Suggest names (AI): %1"), onOff(Settings.get("suggest_names"))), function()
        Settings.set("suggest_names", not Settings.get("suggest_names"))
    end)) end

    add(heading(_("Notebook list")))
    add(pick(T(_("Sort by: %1"), SORT[Settings.get("sort")] or SORT.modified), _("Sort notebooks by"),
        options(Settings.SORT_KEYS, SORT), "sort", "modified"))
    add(pick(T(_("Default sort: %1"), SORT_DEFAULT[Settings.get("sort_default")] or SORT_DEFAULT.last), _("Default sort"),
        options({ "last", "name", "created", "modified", "custom" }, SORT_DEFAULT), "sort_default", "last"))
    add(pick(T(_("Recent notebooks: %1"), RECENT[Settings.recentMode()]), _("Recent notebooks"),
        options({ "folder", "top", "off" }, RECENT), "recent_mode", "folder"))
    add(row(T(_("Open the last notebook when Notes opens: %1"), onOff(Settings.get("open_last"))), function()
        Settings.set("open_last", not Settings.get("open_last"))
    end))
    for __, e in ipairs(extra.list or {}) do add(open(e[1], e[2])) end

    -- The connections last.
    if extra.top or extra.connections then
        add(heading(_("Integrations")))
        -- The caller's rows (AI for everything): { label (text, or a function giving it), fn, open, when }.
        for __, e in ipairs(extra.top or {}) do
            if not e.when or e.when() then
                add((e.open and open or row)(type(e[1]) == "function" and e[1]() or e[1], e[2]))
            end
        end
        for __, e in ipairs(extra.connections or {}) do
            if not e.when or e.when() then add(open(e[1], e[2])) end
        end
    end

    return buttons
    end
    -- (Only the rows, for the launcher's search to find each setting by name.)
    if extra.rowsOnly then return build() end
    page = require("notessettingspage"):new{ title = _("Notes settings"), build = build, titleOpts = extra.title,
        jump = extra.jump }
    UIManager:show(page)
    return page
end

--- A row's name without its value ("Sort by: Modified" -> "Sort by").
function Settings.rowName(text)
    text = tostring(text or "")
    return (text:match("^(.-): ") or text):gsub("…$", "")
end

return Settings
