--[[--
Gestures: every gesture that does something, in the library or in a book,
with what it does, in KOReader's own words (the Gesture manager's names and
the actions' titles). Tap one to change it in KOReader's own menu for it;
the button at the top opens the whole Gesture manager. KOReader keeps the
gestures and saves them; nothing here writes them.
]]

local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("appscanvas")

local C = Canvas
local Gestures = {}

-- The order of KOReader's own overview (Gesture manager > Gesture overview).
local SECTIONS = { "tap_corner", "hold_corner", "one_finger_swipe", "double_tap", "two_finger_tap",
    "two_finger_swipe", "spread_and_pinch", "two_finger_rotation" }

--- The Gestures plugin's names: section_titles, section_items, gestures_list
-- (kept local in it, so read from its functions).
local function names(g)
    local out = {}
    for __, key in ipairs({ "addToMainMenu", "onShowGestureOverview", "gestureTitleFunc" }) do
        local fn = g[key]
        if type(fn) ~= "function" then fn = function() end end
        for i = 1, 80 do
            local name, value = debug.getupvalue(fn, i)
            if not name then break end
            if out[name] == nil then out[name] = value end
        end
    end
    return out
end

--- What a gesture does: "Folder shortcuts", "Light, Night mode" or
-- "QuickMenu: a, b, c"; nil when nothing.
function Gestures.actions(gest)
    if type(gest) ~= "table" then return nil end
    local Dispatcher = require("dispatcher")
    local list = {}
    for item, v in Dispatcher.iter_func(gest) do
        if type(item) == "number" then item = v end
        if item ~= "settings" and gest[item] ~= nil then
            local name = Dispatcher:getNameFromItem(item, gest)
            -- An action only there with a book open: its title from when it was seen.
            if name == _("Unknown item") then name = require("appsactions").bookTitle(item) or item end
            table.insert(list, name)
        end
    end
    if #list == 0 then return nil end
    local text = table.concat(list, ", ")
    if gest.settings and gest.settings.show_as_quickmenu then text = T(_("QuickMenu: %1"), text) end
    return text
end

--- The gestures that do something in `mode` ("gesture_fm" or
-- "gesture_reader"): { { title, rows = { { ges, name, actions } } } }.
function Gestures.sections(g, mode)
    local N = names(g)
    local list = N.gestures_list or {}
    local data = g.data and g.data[mode] or {}
    local out = {}
    local function add(id, items)
        local rows = {}
        for __, ges in ipairs(items or {}) do
            if type(ges) == "table" then ges = ges[1] end
            local text = Gestures.actions(data[ges])
            if text then
                local name = list[ges]
                if not name or name == "" then name = g:friendlyMultiswipeName(ges) end
                table.insert(rows, { ges = ges, name = name, actions = text })
            end
        end
        if #rows > 0 then
            table.insert(out, { title = N.section_titles and N.section_titles[id] or id, rows = rows })
        end
    end
    for __, id in ipairs(SECTIONS) do
        local multitouch = id:match("^two_finger") or id == "spread_and_pinch"
        if (id ~= "double_tap" or mode == "gesture_reader") and (not multitouch or g.has_multitouch) then
            add(id, N.section_items and N.section_items[id])
        end
    end
    if g.multiswipes_enabled then
        add("multiswipes", g:genMultiswipeMenu(true))
        local custom = {}
        for ges in pairs(g.custom_multiswipes or {}) do table.insert(custom, ges) end
        table.sort(custom)
        add("custom_multiswipes", custom)
    end
    return out
end

--- KOReader's own menu (as its main menu shows it), on its own: one page of
-- `items`; then done() when it closes.
local function showMenu(items, done)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local TouchMenu = require("ui/widget/touchmenu")
    local Screen = require("device").screen
    local container = CenterContainer:new{ covers_header = true, ignore = "height", dimen = Screen:getSize() }
    items.icon = "appbar.settings"
    local menu = TouchMenu:new{ width = Screen:getWidth(), last_index = 1, tab_item_table = { items }, show_parent = container }
    menu.close_callback = function()
        UIManager:close(container)
        if done then done() end
    end
    container[1] = menu
    UIManager:show(container)
end

--- KOReader's menu for one gesture (the same as Gesture manager > ... > it).
function Gestures.edit(g, ges, done)
    showMenu(g:genMenu(ges), done)
end

--- KOReader's whole Gesture manager.
function Gestures.manager(g, done)
    local items = {}
    g:addToMainMenu(items)
    local gm = items.gesture_manager
    if gm then showMenu(gm.sub_item_table, done) end
end

--- The screen, in the launcher (view.mode "gestures").
function Gestures.draw(view, c)
    local ui = view:ui()
    local g = ui and ui.gestures
    local current = g and g.ges_mode or "gesture_fm"
    local mode = view.gesturesMode or current
    local here = mode == current
    local F = c:flow(98, c.H - 8, view.gesturesPage)
    local function back() view:refresh() end
    if not g then
        F:block(40, function(y) c:text(14, y + 26, _("KOReader's Gestures plugin is turned off."), 12, { color = C.GREY }) end)
    else
        -- The Gesture manager, and which set: in the library or in a book.
        F:block(56, function(y)
            -- The Gesture manager (KOReader's whole menu), as an outlined button.
            local label = _("Gesture manager")
            local bw = c:width(label, 12) + 60
            c:box(14, y + 8, bw, 36, { r = 18, border = C.BLACK, bw = 1.4 })
            c:icon("hand", 30, y + 17, 18)
            c:text(56, y + 31, label, 12)
            c:hit(14, y + 2, bw, 48, function() Gestures.manager(g, back) end)
            local tabs = { { "gesture_fm", _("In the library") }, { "gesture_reader", _("In a book") } }
            local x = c.W - 14
            for i = #tabs, 1, -1 do
                local t = tabs[i]
                local w = c:width(t[2], 11.5) + 28
                x = x - w
                local on = mode == t[1]
                c:box(x, y + 10, w, 32, { r = 16, fill = on and C.FILL or nil, border = C.BLACK, bw = 1.2 })
                c:text(x + w / 2, y + 31, t[2], 11.5, { align = "middle", color = on and C.ON_FILL or C.BLACK })
                c:hit(x, y + 4, w, 44, function()
                    view.gesturesMode, view.gesturesPage = t[1], 1
                    view:refresh()
                end)
                x = x - 8
            end
        end)
        local sections = Gestures.sections(g, mode)
        if #sections == 0 then
            F:block(40, function(y) c:text(14, y + 26, _("No gestures are set."), 12, { color = C.GREY }) end)
        end
        for __, s in ipairs(sections) do
            F:block(34, function(y) c:text(14, y + 24, s.title:upper(), 9.5, { bold = true, color = C.GREY }) end, 44)
            for __, r in ipairs(s.rows) do
                F:block(44, function(y)
                    local nw = c:text(14, y + 28, r.name, 12.5, { maxw = c.W * 0.4 }) or 0
                    c:text(14 + nw + 10, y + 28, "\u{2192}  " .. r.actions, 12.5, { color = C.GREY, maxw = c.W - nw - 24 - (here and 40 or 14) })
                    if here then
                        c:icon("chevron-right", c.W - 32, y + 13, 18)
                        c:hit(0, y, c.W, 44, function() Gestures.edit(g, r.ges, back) end)
                    end
                    c:hline(14, y + 44, c.W - 28)
                end)
            end
        end
    end
    view.pages = F:pages()
    if view.gesturesPage > view.pages then
        view.gesturesPage = view.pages
        return view:render()
    end
    -- The title bar last (over the flow's top).
    view:bar(c, _("Gestures"))
    local hint = here and _("What each gesture does. Tap one to change it.")
        or (mode == "gesture_reader" and _("To change these, open a book first.") or _("To change these, close the book first."))
    c:text(14, 74, hint, 10.5, { color = C.GREY, maxw = c.W - 28 })
end

return Gestures
