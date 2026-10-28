--[[--
The Fonts screen (the launcher's "fonts" mode), in three tabs along the top,
each with its own pages (view.fontsTab):
- Your fonts: each name drawn in its own typeface (tap one: Set as default
  for new books, or Remove an added one, with Undo).
- Get more: every Google Fonts family (appsgooglefonts.lua) with search,
  a category (Suggested first: good reading fonts), popular first, A–Z or
  newest; Get fetches one (appsfonts.lua's Fonts.google), and a name that
  isn't in the list can be got by name.
- Settings: KOReader's font settings (the font and size for new books,
  fallbacks, the book's own fonts, weight, hinting, kerning).
The work is appsfonts.lua and appsgooglefonts.lua, which the web page's Fonts
tab uses too. Books see added or removed fonts after KOReader restarts.
]]

local Font = require("ui/font")
local RenderText = require("ui/rendertext")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("appscanvas")
local KO = require("appsko")

local C = Canvas
local View = {}

View.TABS = {
    { "mine", _("Your fonts") },
    { "get", _("Get more") },
    { "settings", _("Settings") },
}

-- The settings tab's groups: { heading, keys, note }.
local GROUPS = {
    { _("NEW BOOKS"), { "font", "font_size", "weight", "embedded" }, _("A book you've already opened keeps its own.") },
    { _("FALLBACK FONTS"), { "fallback", "more_fallbacks" } },
    { _("ADVANCED"), { "hinting", "kerning" } },
}

-- A face for drawing a name in its own font (nil when it can't be read).
local faces = {}
local function faceOf(path, px)
    local key = path .. "@" .. px
    if faces[key] == nil then
        local ok, f = pcall(function()
            local scale = require("device").screen:scaleBySize(1000) / 1000
            return Font:getFace(path, px / scale)
        end)
        faces[key] = ok and f or false
    end
    return faces[key] or nil
end

-- Text in a given face (the canvas's own text is Noto Sans only).
local function textIn(c, face, x, y, s, maxw)
    local px, py = c:X(x), c:X(y)
    local maxpx = maxw and c:X(maxw)
    if maxpx and RenderText:sizeUtf8Text(0, 1e5, face, s, true, false).x > maxpx then
        s = RenderText:truncateTextByWidth(s, face, maxpx, true, false)
    end
    table.insert(c.ops, function(bb, ox, oy) RenderText:renderUtf8Text(bb, ox + px, oy + py, face, s, true, false, c:col(C.BLACK)) end)
end

-- After fonts were added or taken out: books need a restart to see them.
local function changed(view)
    view.fontsChanged = true
    view.fontsData = nil
    view:refresh()
end

local function data(view)
    if not view.fontsData then
        local ok, list = pcall(function() return require("appsfonts").list() end)
        view.fontsData = ok and list or { families = {} }
    end
    return view.fontsData
end

-- Each tab keeps its own page; fontsPage is the one on show (the title bar's pager turns it).
local function showTab(view, tab)
    if tab == (view.fontsTab or "mine") then return end
    view.fontsPages = view.fontsPages or {}
    view.fontsPages[view.fontsTab or "mine"] = view.fontsPage
    view.fontsTab = tab
    view.fontsPage = view.fontsPages[tab] or 1
    view:refresh()
end

-- A font's menu: Set as default for new books, Remove (an added one).
local function fontMenu(view, fam)
    local Fonts = require("appsfonts")
    local items = {
        { text = fam.default and _("Default for new books ✓") or _("Set as default for new books"), fn = function()
            if not fam.default then
                -- With Undo: a firm press of the pen can pick this by mistake.
                local before = data(view).default
                Fonts.setDefault(fam.name)
                view.fontsData = nil
                view:refresh()
                KO.undo(T(_("New books open in %1"), fam.name), before and function()
                    Fonts.setDefault(before)
                    view.fontsData = nil
                    view:refresh()
                end)
            end
        end },
    }
    if fam.added then
        table.insert(items, { text = _("Remove"), fn = function()
            local tokens = {}
            for __, f in ipairs(fam.faces) do
                if f.added then
                    local token = Fonts.remove(f.id)
                    if token then table.insert(tokens, token) end
                end
            end
            changed(view)
            KO.undo(T(_("Removed %1"), fam.name), function()
                for __, token in ipairs(tokens) do Fonts.undo(token) end
                changed(view)
            end)
        end })
    end
    KO.list(fam.name, items)
end

-- Gets a family from Google Fonts in the background.
local function get(view, family)
    local why = require("appsfonts").google(family, function(state)
        if state.status == "done" then
            KO.toast(T(_("Got %1"), state.family))
            changed(view)
        else
            KO.message(state.message or _("Couldn't get it."))
            view:refresh()
        end
    end)
    if why then return KO.message(why) end
    view:refresh()
end

-- One of KOReader's font settings: a switch, or a choice from a list.
local function setting(view, item)
    local S = require("appskosettings")
    local function apply(v)
        local msg = S.set(item.key, v)
        if msg then KO.toast(msg) end
        view.fontsData = nil
        view:refresh()
    end
    if item.kind == "switch" then return apply(not item.value) end
    local options = {}
    for __, o in ipairs(item.options or {}) do table.insert(options, { label = o[1], value = o[2] }) end
    KO.choose(item.name, options, item.value, apply)
end

-- The three tabs: the one on show filled.
local function tabs(view, c, y)
    local tab = view.fontsTab or "mine"
    local x, w = 14, (c.W - 28) / #View.TABS
    c:box(x, y, c.W - 28, 40, { r = 8, border = C.BLACK, bw = 1.6 })
    for i, t in ipairs(View.TABS) do
        local tx = x + (i - 1) * w
        local on = t[1] == tab
        if on then c:box(tx, y, w, 40, { r = 8, fill = C.FILL }) end
        if i > 1 and not on and View.TABS[i - 1][1] ~= tab then c:box(tx, y + 6, 1.4, 28, { fill = C.BLACK }) end
        c:text(tx + w / 2, y + 27, t[2], 12, { align = "middle", bold = on, color = on and C.ON_FILL or C.BLACK, maxw = w - 8 })
        c:hit(tx, y - 4, w, 48, function() showTab(view, t[1]) end)
    end
end

-- Your fonts: each in its own typeface.
local function drawMine(view, c, F)
    local d = data(view)
    local Fonts = require("appsfonts")
    -- Books see changes after a restart.
    if view.fontsChanged then
        F:block(64, function(y)
            c:box(14, y + 8, c.W - 28, 50, { r = 8, border = C.BLACK, bw = 1.4 })
            c:text(28, y + 39, _("Books see the change after KOReader restarts."), 12, { maxw = c.W - 170 })
            local label = _("Restart")
            local bw = c:width(label, 12) + 32
            c:box(c.W - 24 - bw, y + 16, bw, 34, { r = 17, fill = C.FILL })
            c:text(c.W - 24 - bw / 2, y + 38, label, 12, { align = "middle", color = C.ON_FILL, bold = true })
            c:hit(c.W - 30 - bw, y + 8, bw + 12, 50, function() require("appsview").restart() end)
        end)
    end
    -- The font new books open in, on every page (the list may have it on another).
    local default
    for __, fam in ipairs(d.families or {}) do if fam.default then default = fam end end
    local function defaultRow(y)
        c:box(14, y + 6, c.W - 28, 62, { r = 8, border = C.BLACK, bw = 1.4 })
        c:text(28, y + 26, _("NEW BOOKS OPEN IN"), 9.5, { bold = true, color = C.GREY })
        local name = default and default.name or d.default or ""
        local path = default and default.faces[1] and Fonts.byId and Fonts.byId[default.faces[1].id]
        local face = path and faceOf(path, c:X(17))
        if face then textIn(c, face, 28, y + 56, name, c.W - 90)
        else c:text(28, y + 56, name, 14, { maxw = c.W - 90 }) end
        c:icon("chevron-right", c.W - 44, y + 29, 16)
        if default then c:hit(14, y + 6, c.W - 28, 62, function() fontMenu(view, default) end) end
    end
    defaultRow(100)
    F:block(30, function(y)
        c:text(14, y + 20, _("Tap a font to make it the default for new books, or to remove one you added."), 10.5, { color = C.GREY, maxw = c.W - 28 })
    end)
    for __, fam in ipairs(d.families or {}) do
        F:block(52, function(y)
            local path = fam.faces[1] and Fonts.byId and Fonts.byId[fam.faces[1].id]
            local face = path and faceOf(path, c:X(17))
            local right = fam.default and _("Default") or (fam.added and _("Added") or "")
            local rw = c:width(right, 10.5, fam.default) + 12
            if face then textIn(c, face, 14, y + 32, fam.name, c.W - 64 - rw)
            else c:text(14, y + 32, fam.name, 14, { maxw = c.W - 64 - rw }) end
            if fam.default then
                c:icon("check", c.W - 14 - rw - 6, y + 17, 16)
                c:text(c.W - 14, y + 30, right, 10.5, { align = "end", bold = true })
            else
                c:text(c.W - 14, y + 30, right, 10.5, { align = "end", color = C.GREY })
            end
            c:hline(14, y + 52, c.W - 28)
            c:hit(0, y, c.W, 52, function() fontMenu(view, fam) end)
        end)
    end
end

-- Settings: KOReader's font settings, in groups.
local function drawSettings(view, c, F)
    local byKey = {}
    for __, item in ipairs(data(view).settings or {}) do byKey[item.key] = item end
    for __, group in ipairs(GROUPS) do
        F:block(group[3] and 52 or 36, function(y)
            c:text(14, y + 26, group[1], 9.5, { bold = true, color = C.GREY })
            if group[3] then c:text(14, y + 44, group[3], 9.5, { color = C.GREY, maxw = c.W - 28 }) end
        end, 60)
        for __, key in ipairs(group[2]) do
            local item = byKey[key]
            if item then
                local h = item.note and 56 or 44
                F:block(h, function(y)
                    c:text(14, y + 28, item.name, 12.5, { maxw = c.W * 0.6 })
                    if item.kind == "switch" then
                        c:box(c.W - 66, y + 12, 52, 26, { r = 13, fill = item.value and C.FILL or nil, border = C.BLACK, bw = 1.4 })
                        c:circle(item.value and (c.W - 27) or (c.W - 53), y + 25, 9, item.value and C.ON_FILL or C.BLACK)
                    else
                        c:text(c.W - 30, y + 28, item.label or "", 11.5, { align = "end", color = C.GREY, maxw = c.W * 0.32 })
                        c:icon("chevron-right", c.W - 28, y + 17, 14)
                    end
                    if item.note then c:text(14, y + 48, item.note, 9.5, { color = C.GREY, maxw = c.W - 28 }) end
                    c:hline(14, y + h, c.W - 28)
                    c:hit(0, y, c.W, h, function() setting(view, item) end)
                end)
            end
        end
    end
end

-- ------------------------------------------------------------------ Get more

local CHIPS = { { "suggested", _("Suggested") }, { "all", _("All") } }
for __, cat in ipairs(require("appsgooglefonts").CATEGORIES) do table.insert(CHIPS, { cat[1], cat[2] }) end

-- The list's chip, sort or search changed: back to its first page.
local function browse(view, field, value)
    view["fontsGet" .. field] = value
    view.fontsPage = 1
    view:refresh()
end

-- Fetches the list again (⟳ on the Get more tab, or the first time).
local function updateList(view)
    local why = require("appsgooglefonts").update(function(state)
        if state.status == "failed" then KO.message(state.message or _("Couldn't get the list.")) end
        if view.mode == "fonts" then view:refresh() end
    end)
    if why then return KO.message(why) end
    view:refresh()
end

local function askSearch(view)
    KO.askText{ title = _("Search Google Fonts"), hint = _("A family name, such as Lora"), text = view.fontsGetQ,
        ok = _("Search"), okIcon = "search", kind = "name", done = function(q) browse(view, "Q", q ~= "" and q or nil) end }
end

-- 1951 → "1,951".
local function thousands(n)
    local s = tostring(n)
    return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function shortDate(t)
    return (os.date("%b %d", t):gsub(" 0", " "))
end

-- Search box, category chips and the sort and list line: on every page.
local function getHeader(view, c, y, gs, getting)
    local q = view.fontsGetQ
    c:box(14, y, c.W - 28, 40, { r = 8, border = C.BLACK, bw = 1.4 })
    c:icon("search", 26, y + 11, 18)
    local hint = gs.count > 0 and T(_("Search %1 families"), thousands(gs.count)) or _("Search Google Fonts")
    c:text(54, y + 26, q or hint, 12, { color = q and C.BLACK or C.GREY, maxw = c.W - 120, bold = q ~= nil })
    c:hit(14, y - 4, c.W - 70, 48, function() askSearch(view) end)
    if q then
        c:icon("x", c.W - 46, y + 11, 18)
        c:hit(c.W - 60, y - 4, 46, 48, function() browse(view, "Q", nil) end)
    end
    -- Chips (in rows, as many as fit).
    local cat = view.fontsGetCat or "suggested"
    local x, cy = 14, y + 50
    for __, chip in ipairs(CHIPS) do
        local w = c:width(chip[2], 11) + 22
        if x + w > c.W - 14 then x, cy = 14, cy + 36 end
        local on = chip[1] == cat
        c:box(x, cy, w, 30, { r = 15, fill = on and C.FILL or nil, border = C.BLACK, bw = 1.3 })
        c:text(x + w / 2, cy + 20, chip[2], 11, { align = "middle", bold = on, color = on and C.ON_FILL or C.BLACK })
        c:hit(x - 2, cy - 3, w + 4, 36, function() browse(view, "Cat", chip[1]) end)
        x = x + w + 6
    end
    -- Sort (not for the suggestions) and the list's date with ⟳.
    local ly = cy + 40
    local G = require("appsgooglefonts")
    if cat ~= "suggested" or q then
        local sort = view.fontsGetSort or "popular"
        local label
        for __, s in ipairs(G.SORTS) do if s[1] == sort then label = s[2] end end
        local w = c:width(label, 11) + 8
        c:text(14, ly + 20, label, 11, { color = C.GREY })
        c:icon("chevron-down", 14 + w, ly + 8, 14)
        c:hit(8, ly, w + 40, 32, function()
            local options = {}
            for __, s in ipairs(G.SORTS) do table.insert(options, { label = s[2], value = s[1] }) end
            KO.choose(_("Sort"), options, sort, function(v) browse(view, "Sort", v) end)
        end)
    end
    local status = getting and T(_("Getting %1…"), getting)
        or gs.status == "getting" and _("Getting the list…")
        or gs.at and T(_("List from %1"), shortDate(gs.at))
        or nil
    if status then
        local sw = c:width(status, 10.5)
        local refresh = gs.status ~= "getting" and gs.at and not getting
        c:text(c.W - 14 - (refresh and 26 or 0), ly + 20, status, 10.5, { align = "end", color = C.GREY })
        if refresh then
            c:icon("refresh-cw", c.W - 32, ly + 8, 16)
            c:hit(c.W - 30 - sw, ly, sw + 30, 32, function() updateList(view) end)
        end
    end
    return ly + 34
end

local function drawGet(view, c, gTop)
    local G = require("appsgooglefonts")
    -- The list is fetched when there's none or it's a month old.
    G.ensure(function() if view.mode == "fonts" then view:refresh() end end)
    local gs = G.state()
    local g = require("appsfonts").googleState()
    local getting = g and g.status == "getting" and g.family
    local top = getHeader(view, c, gTop, gs, getting)
    local F = c:flow(top, c.H - 8, view.fontsPage or 1)
    local have = {}
    for __, fam in ipairs(data(view).families or {}) do have[fam.name:lower()] = true end
    local cat = view.fontsGetCat or "suggested"
    local q = view.fontsGetQ
    local function tapGet(name)
        if getting then return KO.toast(T(_("Still getting %1"), getting)) end
        get(view, name)
    end
    local function row(name, detail, bold)
        F:block(58, function(y)
            c:text(14, y + 26, name, 13, { bold = bold ~= false, maxw = c.W - 130 })
            if detail and detail ~= "" then c:text(14, y + 48, detail, 10.5, { color = C.GREY, maxw = c.W - 130 }) end
            local state = have[name:lower()] and _("Installed") or (getting == name and _("Getting…")) or nil
            if state then
                c:text(c.W - 14, y + 36, state, 11, { align = "end", color = C.GREY })
            else
                local label = _("Get")
                local bw = c:width(label, 12) + 36
                c:box(c.W - 14 - bw, y + 14, bw, 34, { r = 17, border = C.BLACK, bw = 1.4 })
                c:text(c.W - 14 - bw / 2, y + 36, label, 12, { align = "middle" })
                c:hit(c.W - 24 - bw, y, bw + 24, 58, function() tapGet(name) end)
            end
            c:hline(14, y + 58, c.W - 28)
        end)
    end
    local r = G.query{ q = q, cat = cat, sort = view.fontsGetSort }
    -- A name that isn't in the list: get it by name anyway.
    if q and not r.exact then row(q, _("Get it by its name from Google Fonts"), true) end
    if r.total == 0 and not (cat == "suggested" and not q) then
        F:block(64, function(y)
            local text
            if gs.status == "getting" then text = _("Getting the list of every family from Google Fonts…")
            elseif gs.count == 0 then text = gs.message or _("The list of every family comes from Google Fonts, over Wi-Fi.")
            else text = q and T(_("Nothing in the list matches “%1”."), q) or _("No families here.") end
            c:text(14, y + 30, text, 11.5, { color = C.GREY, maxw = c.W - 28 })
            if gs.count == 0 and gs.status ~= "getting" then
                local label = _("Get the list")
                local bw = c:width(label, 12) + 36
                c:box(14, y + 40, bw, 34, { r = 17, border = C.BLACK, bw = 1.4 })
                c:text(14 + bw / 2, y + 62, label, 12, { align = "middle" })
                c:hit(10, y + 36, bw + 8, 42, function() updateList(view) end)
            end
        end)
    end
    for __, e in ipairs(r.items) do
        local detail = e.category and (e.category .. " · " .. e.styles) or nil
        if e.note then detail = detail and (detail .. " · " .. e.note) or e.note end
        row(e.name, detail)
    end
    return F
end

function View.draw(view, c)
    local tab = view.fontsTab or "mine"
    -- The list of every family is only kept while it's browsed.
    if tab ~= "get" then require("appsgooglefonts").drop() end
    tabs(view, c, 60)
    local F
    if tab == "get" then F = drawGet(view, c, 110)
    else
        -- (Your fonts: the default's box above the list, on every page.)
        F = c:flow(tab == "mine" and 172 or 106, c.H - 8, view.fontsPage or 1)
        if tab == "settings" then drawSettings(view, c, F) else drawMine(view, c, F) end
    end
    view.pages = F:pages()
    if (view.fontsPage or 1) > view.pages then
        view.fontsPage = view.pages
        return view:render()
    end
    view:bar(c, _("Fonts"))
end

return View
