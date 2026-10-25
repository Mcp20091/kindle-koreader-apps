--[[--
The Fonts screen (the launcher's "fonts" mode): Get more fonts at the top (its
own page, mode "fontsget": any Google Fonts family by name, and good reading
fonts with one tap); your fonts, each name drawn in its own typeface (tap one:
Set as default for new books, or Remove an added one, with Undo); and
KOReader's font settings (fallback, the book's own fonts, weight, hinting,
kerning). The work is appsfonts.lua, which the web page's Fonts tab uses
too. Books see added or removed fonts after KOReader restarts.
]]

local Font = require("ui/font")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("appscanvas")
local KO = require("appsko")

local C = Canvas
local View = {}

-- Good reading fonts on Google Fonts: { family, what it's like }.
View.GET = {
    { "Literata", _("Made for e-books (Google Play Books' font)") },
    { "Merriweather", _("A sturdy serif for screens") },
    { "Lora", _("A calligraphic serif, good for novels") },
    { "EB Garamond", _("The classic book face") },
    { "Crimson Pro", _("An elegant old-style serif") },
    { "Source Serif 4", _("A clear, modern serif") },
    { "Alegreya", _("A lively serif for long reading") },
    { "Bitter", _("A slab serif, clear at small sizes") },
    { "Atkinson Hyperlegible", _("A sans made for low vision") },
    { "Lexend", _("A sans made for easier reading") },
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

-- A font's menu: Set as default for new books, Remove (an added one).
local function fontMenu(view, fam)
    local Fonts = require("appsfonts")
    local items = {
        { text = fam.default and _("Default for new books ✓") or _("Set as default for new books"), fn = function()
            if not fam.default then
                Fonts.setDefault(fam.name)
                view.fontsData = nil
                view:refresh()
                KO.toast(T(_("New books open in %1"), fam.name))
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

function View.draw(view, c)
    local d = data(view)
    local Fonts = require("appsfonts")
    local g = Fonts.googleState()
    local getting = g and g.status == "getting" and g.family
    local F = c:flow(56, c.H - 8, view.fontsPage or 1)
    local function heading(text)
        F:block(36, function(y) c:text(14, y + 26, text, 9.5, { bold = true, color = C.GREY }) end, 60)
    end
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
    -- Getting more: its own page.
    F:block(76, function(y)
        c:box(14, y + 10, c.W - 28, 58, { r = 10, border = C.BLACK, bw = 2 })
        c:icon("arrow-down-to-line", 30, y + 28, 22)
        c:text(66, y + 34, _("Get more fonts"), 13, { bold = true })
        c:text(66, y + 54, getting and T(_("Getting %1…"), getting) or _("Free from Google Fonts, over Wi-Fi"), 10.5, { color = C.GREY, maxw = c.W - 130 })
        c:icon("chevron-right", c.W - 44, y + 31, 16)
        c:hit(14, y + 6, c.W - 28, 66, function()
            view.mode, view.fontsgetPage = "fontsget", 1
            view:refresh()
        end)
    end)
    heading(_("YOUR FONTS"))
    for __, fam in ipairs(d.families or {}) do
        F:block(52, function(y)
            local path = fam.faces[1] and Fonts.byId and Fonts.byId[fam.faces[1].id]
            local face = path and faceOf(path, c:X(17))
            local right = fam.default and _("Default") or (fam.added and _("Added") or "")
            local rw = c:width(right, 10.5) + 12
            if face then textIn(c, face, 14, y + 32, fam.name, c.W - 42 - rw)
            else c:text(14, y + 32, fam.name, 14, { maxw = c.W - 42 - rw }) end
            c:text(c.W - 14, y + 30, right, 10.5, { align = "end", color = C.GREY, bold = fam.default })
            c:hline(14, y + 52, c.W - 28)
            c:hit(0, y, c.W, 52, function() fontMenu(view, fam) end)
        end)
    end
    -- KOReader's font settings (the font for new books is set above, by tapping a font).
    heading(_("FONT SETTINGS"))
    for __, item in ipairs(d.settings or {}) do
        if item.key ~= "font" then
            F:block(item.note and 56 or 44, function(y)
                c:text(14, y + 28, item.name, 12.5, { maxw = c.W * 0.6 })
                if item.kind == "switch" then
                    c:box(c.W - 66, y + 12, 52, 26, { r = 13, fill = item.value and C.FILL or nil, border = C.BLACK, bw = 1.4 })
                    c:circle(item.value and (c.W - 27) or (c.W - 53), y + 25, 9, item.value and C.ON_FILL or C.BLACK)
                else
                    c:text(c.W - 30, y + 28, item.label or "", 11.5, { align = "end", color = C.GREY, maxw = c.W * 0.32 })
                    c:icon("chevron-right", c.W - 28, y + 17, 14)
                end
                if item.note then c:text(14, y + 48, item.note, 9.5, { color = C.GREY, maxw = c.W - 28 }) end
                local h = item.note and 56 or 44
                c:hline(14, y + h, c.W - 28)
                c:hit(0, y, c.W, h, function() setting(view, item) end)
            end)
        end
    end
    view.pages = F:pages()
    if (view.fontsPage or 1) > view.pages then
        view.fontsPage = view.pages
        return view:render()
    end
    view:bar(c, _("Fonts"))
end

--- Any family by name: the keyboard, then the Kindle gets it.
local function askFamily(view)
    KO.askText{ title = _("Get a font from Google Fonts"), hint = _("A family name, such as Lora"),
        ok = _("Get"), okIcon = "download", kind = "name", needsText = true, done = function(name) get(view, name) end }
end

--- The Get fonts page (mode "fontsget"): a family by name, then the suggestions.
function View.drawGet(view, c)
    local d = data(view)
    local g = require("appsfonts").googleState()
    local getting = g and g.status == "getting" and g.family
    local have = {}
    for __, fam in ipairs(d.families or {}) do have[fam.name:lower()] = true end
    local F = c:flow(56, c.H - 8, view.fontsgetPage or 1)
    F:block(30, function(y)
        c:text(14, y + 22, _("Free from Google Fonts, over Wi-Fi. Books see new fonts after KOReader restarts."), 10.5, { color = C.GREY, maxw = c.W - 28 })
    end)
    -- Any family: looks like a search box; a tap opens the keyboard.
    F:block(56, function(y)
        c:box(14, y + 8, c.W - 28, 40, { r = 8, border = C.BLACK, bw = 1.4 })
        c:icon("search", 26, y + 19, 18)
        c:text(54, y + 34, getting and T(_("Getting %1…"), getting) or _("Any Google Fonts family, such as Lora"), 12,
            { color = getting and C.BLACK or C.GREY, maxw = c.W - 90 })
        c:hit(14, y + 4, c.W - 28, 48, function()
            if getting then return KO.toast(T(_("Still getting %1"), getting)) end
            askFamily(view)
        end)
    end)
    F:block(36, function(y) c:text(14, y + 26, _("SUGGESTIONS"), 9.5, { bold = true, color = C.GREY }) end, 60)
    for __, e in ipairs(View.GET) do
        F:block(58, function(y)
            c:text(14, y + 26, e[1], 13, { bold = true })
            c:text(14, y + 48, e[2], 10.5, { color = C.GREY, maxw = c.W - 150 })
            local state = have[e[1]:lower()] and _("Installed") or (getting == e[1] and _("Getting…")) or nil
            if state then
                c:text(c.W - 14, y + 36, state, 11, { align = "end", color = C.GREY })
            else
                local label = _("Get")
                local bw = c:width(label, 12) + 36
                c:box(c.W - 14 - bw, y + 14, bw, 34, { r = 17, border = C.BLACK, bw = 1.4 })
                c:text(c.W - 14 - bw / 2, y + 36, label, 12, { align = "middle" })
                c:hit(c.W - 24 - bw, y, bw + 24, 58, function()
                    if getting then return KO.toast(T(_("Still getting %1"), getting)) end
                    get(view, e[1])
                end)
            end
            c:hline(14, y + 58, c.W - 28)
        end)
    end
    view.pages = F:pages()
    if (view.fontsgetPage or 1) > view.pages then
        view.fontsgetPage = view.pages
        return view:render()
    end
    view:bar(c, _("Get fonts"))
end

return View
