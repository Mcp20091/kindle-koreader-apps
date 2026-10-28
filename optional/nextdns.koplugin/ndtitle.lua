--[[--
(A copy of apps.koplugin's appsbar.lua. Re-copy it when that changes.)

The title bar the apps share ("an OS inside KOReader"): Apps' own screens
draw it with this; Home Assistant and To Do draw the same bar with their own
canvas.

    ‹  ⌂  Title         [the app's buttons]  12:45  ▭ 80%   ⟳   🔔   ⋮

- ‹ Back: one screen back; on an app's top page, to Apps.
- ⌂ Home: always to Apps.
- The title.
- At the right, in this order: the app's own buttons (search, +, …), the
  clock and battery, ⟳ Refresh (the data again, and a full e-ink refresh),
  🔔 Notifications (a badge counts the unread ones), ⋮ the menu (Light,
  Night mode, Refresh screen, ending with Settings).

44 units tall; Lucide icons 18 units, 34 apart.
]]

local Device = require("device")
local Canvas = require("ndcanvas")

local Bar = {}

Bar.H = 44

--- The unread notifications (0 without the service).
function Bar.unread()
    local PS = require("pluginshare")
    local ok, n = pcall(function() return PS.notifyCount and PS.notifyCount() or 0 end)
    return ok and tonumber(n) or 0
end

--- The bell at x (its top at y), with a badge of how many are unread.
function Bar.bell(c, x, y, n)
    local C = Canvas
    c:icon("bell", x, y, 18)
    if n and n > 0 then
        local s = n > 99 and "99+" or tostring(n)
        local bw = math.max(14, c:width(s, 8, true) + 6)
        c:box(x + 10, y - 6, bw, 14, { r = 7, fill = C.FILL })
        c:text(x + 10 + bw / 2, y + 5, s, 8, { bold = true, align = "middle", color = C.ON_FILL })
    end
end

--- The Kindle's battery: percent (nil when unknown) and whether it's charging.
local function battery()
    local powerd = Device:getPowerDevice()
    local ok, pct = pcall(function() return powerd:getCapacity() end)
    local ok2, charging = pcall(function() return powerd:isCharging() end)
    return ok and tonumber(pct) or nil, ok2 and charging == true
end

--- The time and battery ending at x, their middle at cy. Returns how wide.
-- The clock: KOReader's own setting, the same in every app.
function Bar.status(c, x, cy, twentyFour, caret)
    if twentyFour == nil then twentyFour = not G_reader_settings:isTrue("twelve_hour_clock") end
    local C = Canvas
    local size = 11
    local right = x
    -- ▾: a tap here drops down the control center.
    if caret then
        c:icon("chevron-down", x - 12, cy - 6, 12)
        x = x - 16
    end
    local pct, charging = battery()
    if pct then
        local tw = c:width(pct .. "%", size)
        c:text(x, cy + size * 0.36, pct .. "%", size, { align = "end" })
        x = x - tw - 3 - 18
        c:icon(charging and "battery-charging" or "battery", x, cy - 9, 18)
        if not charging and pct > 0 then
            -- Filled as far as charged (inside Lucide's outline: 3..17 by 7..17 of 24).
            local k = 18 / 24
            c:box(x + 4.5 * k, cy - 9 + 8.5 * k, 11 * k * math.min(100, pct) / 100, 7 * k, { fill = C.BLACK })
        end
        x = x - 10
    end
    -- What's running now (an ongoing notification: the web server…): its icon.
    local PS = require("pluginshare")
    for __, icon in ipairs(PS.statusIcons and PS.statusIcons() or {}) do
        c:icon(icon, x - 16, cy - 8, 16)
        x = x - 16 - 8
    end
    local now = os.date("*t")
    local clock
    if twentyFour then
        clock = string.format("%02d:%02d", now.hour, now.min)
    else
        clock = string.format("%d:%02d %s", (now.hour + 11) % 12 + 1, now.min, now.hour < 12 and "AM" or "PM")
    end
    c:text(x, cy + size * 0.36, clock, size, { bold = true, align = "end" })
    x = x - c:width(clock, size, true)
    return right - x
end

--- Draws the bar. opts:
--   title,
--   back = fn (‹; nil: none), home = fn (⌂; nil: none),
--   buttons = { { icon, fn }, ... } (the app's own, left to right),
--   pager = { page, pages, turn = fn(delta) } (when more than one page),
--   clock = true (the time and battery; 12- or 24-hour as KOReader is set),
--   refresh = fn (⟳), bell = fn (🔔), menu = fn (⋮),
--   subtitle = a small grey line under the title (a book's chapter and page),
--   recent = fn (the recent apps, next to ⌂; by default Apps' switcher when
--   there is a ⌂; false: none), status = fn (a tap on the time and battery,
--   ▾; by default the control center).
function Bar.draw(c, opts)
    local C = Canvas
    -- (A hold works a button as a tap does: a firm press of the pen lasts long
    -- enough to be a hold.)
    local function hit(x, y, w, h, tap, hold) c:hit(x, y, w, h, tap, hold or tap) end
    c:rect(0, 0, c.W, Bar.H, C.WHITE)
    c:hline(0, Bar.H, c.W, C.BLACK, 2)
    local x = 14
    if opts.back then
        c:icon("chevron-left", 12, 13, 18)
        hit(0, 0, 40, Bar.H, opts.back)
        x = 42
    end
    if opts.home then
        c:icon("house", x + 2, 13, 18)
        hit(x - 4, 0, 34, Bar.H, opts.home)
        x = x + 36
    end
    -- Recent apps (Apps' switcher), next to ⌂.
    local recent = opts.recent
    if recent == nil and opts.home and require("pluginshare").showSwitcher then
        recent = function() require("pluginshare").showSwitcher() end
    end
    if recent then
        c:icon("history", x + 2, 13, 18)
        hit(x - 4, 0, 34, Bar.H, recent)
        x = x + 36
    end
    -- From the right: ⋮, 🔔, ⟳, the clock and battery, the app's buttons, the pages.
    local right = c.W - 32
    if opts.menu then
        c:icon("ellipsis-vertical", right, 13, 18)
        hit(right - 8, 0, 40, Bar.H, opts.menu)
        right = right - 34
    end
    if opts.bell then
        Bar.bell(c, right, 13, Bar.unread())
        hit(right - 8, 0, 34, Bar.H, opts.bell)
        right = right - 34
    end
    if opts.refresh then
        c:icon("refresh-cw", right, 13, 18)
        hit(right - 8, 0, 34, Bar.H, opts.refresh)
        right = right - 34
    end
    right = right + 18   -- (the right edge of what is left)
    if opts.clock then
        -- A tap on the time and battery (▾): the control center (light, Wi-Fi, night mode…).
        local cc = opts.status or (require("pluginshare").showControlCenter and function() require("pluginshare").showControlCenter() end)
        local sw = Bar.status(c, right - 14, 22, nil, cc ~= nil)
        if cc then hit(right - 20 - sw, 0, sw + 12, Bar.H, cc) end
        right = right - 14 - sw
    end
    local buttons = opts.buttons or {}
    for i = #buttons, 1, -1 do
        local b = buttons[i]
        right = right - 34
        c:icon(b[1], right + 8, 13, 18)
        hit(right, 0, 34, Bar.H, b[2], b[3])
    end
    local p = opts.pager
    if p and (p.pages or 1) > 1 then
        local label = p.page .. "/" .. p.pages
        local lw = c:width(label, 11) + 40
        right = right - lw - 4
        c:icon("chevron-left", right + 2, 15, 14)
        c:text(right + lw / 2, 27, label, 11, { align = "middle", color = C.GREY })
        c:icon("chevron-right", right + lw - 16, 15, 14)
        hit(right - 6, 0, lw / 2 + 6, Bar.H, function() p.turn(-1) end)
        hit(right + lw / 2, 0, lw / 2 + 6, Bar.H, function() p.turn(1) end)
    end
    if opts.subtitle and opts.subtitle ~= "" then
        c:text(x, 20, opts.title or "", 13, { bold = true, maxw = math.max(40, right - x - 8) })
        c:text(x, 36, opts.subtitle, 9.5, { color = C.GREY, maxw = math.max(40, right - x - 8) })
    else
        c:text(x, 28, opts.title or "", 15, { bold = true, maxw = math.max(40, right - x - 8) })
    end
end

--- ⌂: Apps on top, whatever was opened over it closed.
function Bar.home()
    local PS = require("pluginshare")
    if PS.appsHome then return PS.appsHome() end
end

return Bar
