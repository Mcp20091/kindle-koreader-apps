--[[--
The title bar shared with the other apps, for Notes' full screens (the
notebook list, settings): ‹ Back and ⌂ Home on the left, then the title,
then on the right the screen's own buttons, the clock and battery,
⟳ Refresh, the bell (when there are notifications to show) and ⋮, whose
menu ends with Settings.

@module koplugin.notes.title
]]

local UI = require("notesui")

local Title = {}

Title.HEIGHT = 44   -- in UI units

--- Draws the bar on `bb` (`w` wide) and returns its tap areas as { x, y,
-- w, h, fn }. `opts`: title, back(), home(), buttons ({ icon, fn } to the
-- right of the title), status (the clock and battery), refresh(), bell()
-- (nil: no bell), bellCount, menu(), page and pages (n/m with arrows, as
-- Home Assistant's), turn(dir).
function Title.draw(ui, bb, w, opts)
    local u = function(n) return ui:u(n) end
    local bar = u(Title.HEIGHT)
    local hits = {}
    local function hit(x, y, hw, hh, fn) if fn then table.insert(hits, { x, y, hw, hh, fn }) end end
    bb:paintRect(0, 0, w, bar, UI.WHITE)
    bb:paintRect(0, bar - u(1), w, u(1), UI.BLACK)
    -- Left: back, home.
    local left = u(12)
    if opts.back then
        ui:drawIcon(bb, "chevron-left", left, u(13), u(18))
        hit(0, 0, u(40), bar, opts.back)
        left = left + u(32)
    end
    if opts.home then
        ui:drawIcon(bb, "house", left, u(13), u(18))
        hit(left - u(6), 0, u(38), bar, opts.home)
        left = left + u(36)
    end
    -- Recent apps (Apps' switcher), right after ⌂.
    local PS = require("pluginshare")
    if opts.home and PS.showSwitcher then
        ui:drawIcon(bb, "history", left, u(13), u(18))
        hit(left - u(6), 0, u(36), bar, function() PS.showSwitcher() end)
        left = left + u(36)
    end
    -- Right, from the edge: ⋮, the bell, ⟳, the clock and battery, own buttons.
    local right = w - u(14)
    local function button(icon, fn, badge)
        right = right - u(18)
        ui:drawIcon(bb, icon, right, u(13), u(18))
        if badge and badge > 0 then
            local n = tostring(badge)
            local bw = math.max(u(14), ui:textWidth(n, 8, true) + u(6))
            ui:box(bb, right + u(11), u(7), bw, u(14), { fill = UI.BLACK, r = u(7) })
            ui:drawText(bb, n, right + u(11) + math.floor(bw / 2), u(14), 8, { align = "center", bold = true, color = UI.WHITE })
        end
        hit(right - u(8), 0, u(34), bar, fn)
        right = right - u(16)
    end
    if opts.menu then button("ellipsis-vertical", opts.menu) end
    if opts.bell then button("bell", opts.bell, opts.bellCount) end
    if opts.refresh then button("refresh-cw", opts.refresh) end
    if opts.status then
        -- The time, the battery and ▾: a tap opens Apps' control center
        -- (light, Wi-Fi, night mode…); ▾ only when there is one.
        local cc = PS.showControlCenter and function() PS.showControlCenter() end or nil
        local chev = cc and u(14) or 0
        if cc then ui:drawIcon(bb, "chevron-down", right - u(12), u(16), u(12)) end
        local sw = ui:drawStatus(bb, right - u(4) - chev, math.floor(bar / 2), 10)
        hit(right - u(10) - sw - chev, 0, sw + chev + u(12), bar, cc)
        right = right - u(4) - chev - sw - u(8)
        -- What's running now (the web server's globe…), as every app's clock corner shows it.
        for __, icon in ipairs(PS.statusIcons and PS.statusIcons() or {}) do
            right = right - u(15)
            ui:drawIcon(bb, icon, right, math.floor(bar / 2) - u(7), u(15))
            right = right - u(8)
        end
    end
    -- (A third value: a count shown on it, as the bell's.)
    for __, b in ipairs(opts.buttons or {}) do button(b[1], b[2], b[3]) end
    -- More than one page: ‹ n/m › (the arrows turn).
    if opts.pages and opts.pages > 1 and opts.turn then
        local label = opts.page .. "/" .. opts.pages
        local lw = ui:textWidth(label, 11) + u(40)
        right = right - lw - u(4)
        ui:drawIcon(bb, "chevron-left", right + u(2), u(15), u(14), false, opts.page <= 1)
        ui:drawText(bb, label, right + math.floor(lw / 2), math.floor(bar / 2), 11, { align = "center", color = UI.GREY_TEXT })
        ui:drawIcon(bb, "chevron-right", right + lw - u(16), u(15), u(14), false, opts.page >= opts.pages)
        local half = math.floor(lw / 2)
        hit(right - u(6), 0, half + u(6), bar, function() opts.turn(-1) end)
        hit(right + half, 0, half + u(6), bar, function() opts.turn(1) end)
        right = right - u(8)
    end
    -- The title (15 bold, as the other apps'), cut to fit.
    local title = opts.title or ""
    local room = right - left - u(8)
    local size = 15
    local s = title
    if ui:textWidth(s, size, true) > room then
        while #s > 1 and ui:textWidth(s .. "…", size, true) > room do
            s = s:sub(1, -2):gsub("[\128-\191]+$", ""):gsub("[\192-\255]$", "")
        end
        s = s .. "…"
    end
    ui:drawText(bb, s, left, math.floor(bar / 2), size, { bold = true })
    return hits, bar
end

return Title
