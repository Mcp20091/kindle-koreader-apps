--[[--
A group's icon: a grid of the launcher's icons; a tap picks one and goes back
to the tiles. The group keeps it as `icon` (the folder when it has none).
]]

local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Canvas = require("appscanvas")

local C = Canvas
local Icons = {}

-- The ones that make sense for a group (no arrows, battery levels or switches).
Icons.LIST = { "folder", "house", "book-open", "library", "notebook-pen", "newspaper", "list-checks", "list",
    "grid-3x3", "wikipedia", "star", "sparkles", "bot", "calendar-days", "clock", "bell", "history", "search",
    "lightbulb", "sun", "moon", "flame", "zap", "plug", "power", "fan", "thermometer", "droplets", "wind",
    "cloud-sun", "cloud-rain", "cloud-snow", "door-closed", "blinds", "lock", "key-round", "shield-check",
    "siren", "camera", "tv", "speaker", "volume-2", "play", "printer", "warehouse", "wifi", "globe",
    "folder-sync", "terminal", "settings", "layout-dashboard", "app-window", "gauge", "activity",
    "footprints", "person-standing", "hand", "eye", "triangle-alert", "circle-help", "check" }

function Icons.draw(view, c)
    local s = view.apps.settings
    local group
    for __, g in ipairs(s.groups or {}) do
        if g.id == view.iconGroup then group = g end
    end
    -- A quick buttons group (its key), instead of a tiles group.
    if view.iconQuick then
        local Model = require("appsmodel")
        if type(s.quick) ~= "table" then s.quick = require("util").tableDeepCopy(Model.quickList(s)) end
        group = Model.quickFind(s.quick, view.iconQuick)
    end
    if not group then
        view.mode = "tiles"
        return view:render()
    end
    local current = group.icon or "folder"
    local per, cell = 7, (c.W - 28) / 7
    -- Rows a little shorter than wide: all of them on one page upright.
    local rowH = math.min(cell, 80)
    local F = c:flow(64, c.H - 8, view.iconsPage or 1)
    for first = 1, #Icons.LIST, per do
        F:block(rowH, function(y)
            for i = first, math.min(first + per - 1, #Icons.LIST) do
                local name = Icons.LIST[i]
                local x = 14 + (i - first) * cell
                if name == current then c:box(x + 6, y + 4, cell - 12, rowH - 8, { r = 12, border = C.BLACK, bw = 2 }) end
                c:icon(name, x + (cell - 36) / 2, y + (rowH - 36) / 2, 36)
                c:hit(x, y, cell, rowH, function()
                    group.icon = name ~= "folder" and name or nil
                    view.apps:save()
                    -- Back where it was asked for (the quick buttons' editor), else the tiles.
                    view.mode = view.backTo == "quick" and "quick" or "tiles"
                    if view.mode == "quick" then view.backTo = nil end
                    view.iconGroup, view.iconQuick = nil, nil
                    view:refresh()
                    UIManager:setDirty(view, "full")
                end)
            end
        end)
    end
    view.pages = F:pages()
    if (view.iconsPage or 1) > view.pages then
        view.iconsPage = view.pages
        return view:render()
    end
    view:bar(c, T(_("Icon for %1"), group.name))
end

return Icons
