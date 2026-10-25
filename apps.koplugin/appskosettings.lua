--[[--
KOReader's most-used settings in one place: the Common settings page (the
KOReader row in the Settings list) and the web page's KOReader tab both use
this list. Each one is KOReader's own setting, applied the way KOReader's
menu applies it, so it takes effect at once and KOReader's menu shows the
same value.

    S.items()           -- { { key, name, kind = "choice" | "switch", value, label, options = { { label, value } }, note } }
    S.fontItems()       -- the font settings, for the web page's Fonts tab (fallbacks, weight, hinting…)
    S.set(key, value)   -- applies one; returns nil, or a message to show

Settings that belong to a book (the font, its size, the status bar items) are
KOReader's defaults for books opened from now on; the open book keeps its own.
]]

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local S = {}

local function reader()
    local R = package.loaded["apps/reader/readerui"]
    return R and R.instance
end

local function currentUI()
    local r = reader()
    if r then return r end
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance
end

local function labelOf(options, value)
    for __, o in ipairs(options) do
        if o[2] == value then return o[1] end
    end
end

-- ------------------------------------------------------------------ Sleep after

--- KOReader's sleep timer (its AutoSuspend plugin), in minutes.
S.SLEEP_AFTER = { 5, 10, 15, 30, 60, 120 }

local function autosuspend()
    local ui = currentUI()
    return ui and ui.autosuspend
end

function S.sleepAfter()
    local a = autosuspend()
    return (a and a.auto_suspend_timeout_seconds) or G_reader_settings:readSetting("auto_suspend_timeout_seconds", 15 * 60)
end

function S.sleepAfterName(seconds)
    if not seconds or seconds <= 0 then return _("Never") end
    local m = math.floor(seconds / 60 + 0.5)
    if m >= 60 and m % 60 == 0 then return m == 60 and _("1 hour") or T(_("%1 hours"), m / 60) end
    return T(_("%1 min"), m)
end

--- As KOReader's own menu does, so it counts from now (on a Kindle the power
-- manager's timer follows too).
function S.setSleepAfter(seconds)
    G_reader_settings:saveSetting("auto_suspend_timeout_seconds", seconds)
    local a = autosuspend()
    if not a then return end
    a.auto_suspend_timeout_seconds = seconds
    pcall(function()
        a:_unschedule()
        a:_start()
        if a._unschedule_kindle then
            a:_unschedule_kindle()
            a:_start_kindle()
        end
    end)
end

function S.sleepOptions()
    local options, now = {}, S.sleepAfter()
    local have = false
    for __, m in ipairs(S.SLEEP_AFTER) do
        if m * 60 == now then have = true end
        table.insert(options, { S.sleepAfterName(m * 60), m * 60 })
    end
    if not have and now > 0 then table.insert(options, 1, { S.sleepAfterName(now), now }) end
    -- On a Kindle the power manager sleeps after 10 minutes without KOReader's timer: no Never there.
    if not Device:isKindle() then table.insert(options, { _("Never"), -1 }) end
    return options, now > 0 and now or -1
end

-- ------------------------------------------------------------------ the rest

local REFRESH = { { _("Never"), 0 }, { _("Every page"), 1 }, { _("Every 6 pages"), 6 }, { _("Every 12 pages"), 12 },
    { _("Every 22 pages"), 22 }, { _("Every chapter"), -1 } }

local TAP_ZONES = { { _("Default"), "default" }, { _("Left / right"), "left_right" }, { _("Top / bottom"), "top_bottom" },
    { _("Bottom / top"), "bottom_top" } }

local function rotation()
    if Device:hasGSensor() and not G_reader_settings:isTrue("input_ignore_gsensor") then return "auto" end
    local mode = Screen:getRotationMode()
    return (mode == Screen.DEVICE_ROTATED_CLOCKWISE or mode == Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE) and "landscape" or "portrait"
end

local function rotationOptions()
    local options = {}
    if Device:hasGSensor() then table.insert(options, { _("Auto-rotate"), "auto" }) end
    table.insert(options, { _("Portrait"), "portrait" })
    table.insert(options, { _("Landscape"), "landscape" })
    return options
end

local function defaultFont()
    return G_reader_settings:readSetting("cre_font") or require("document/credocument").default_font or ""
end

--- KOReader's fonts for books (crengine's list; loading it starts crengine if no book did yet).
function S.fontOptions()
    local ok, faces = pcall(function()
        local cre = require("document/credocument"):engineInit()
        return cre.getFontFaces()
    end)
    local options = {}
    if ok and type(faces) == "table" then
        table.sort(faces, function(a, b) return a:lower() < b:lower() end)
        for __, f in ipairs(faces) do table.insert(options, { f, f }) end
    end
    local now = defaultFont()
    if now ~= "" and not labelOf(options, now) then table.insert(options, 1, { now, now }) end
    return options
end

local function fontSize()
    return G_reader_settings:readSetting("copt_font_size") or G_defaults:readSetting("DCREREADER_CONFIG_DEFAULT_FONT_SIZE") or 22
end

local function fontSizeOptions()
    local options = {}
    for __, n in ipairs(G_defaults:readSetting("DCREREADER_CONFIG_FONT_SIZES") or { 12, 16, 20, 22, 24, 26, 28, 30, 34, 38, 44 }) do
        table.insert(options, { tostring(n), n })
    end
    if not labelOf(options, fontSize()) then table.insert(options, { tostring(fontSize()), fontSize() }) end
    return options
end

local function footerOn()
    local r = reader()
    local footer = r and r.view and r.view.footer
    if footer and footer.mode then return footer.mode ~= 0 end
    return (G_reader_settings:readSetting("reader_footer_mode") or 1) ~= 0
end

local function kosyncInstalled()
    local disabled = G_reader_settings:readSetting("plugins_disabled")
    if type(disabled) == "table" and disabled.kosync then return false end
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(require("datastorage"):getDataDir() .. "/plugins/kosync.koplugin", "mode") == "directory"
        or lfs.attributes("plugins/kosync.koplugin", "mode") == "directory"
end

local function kosync()
    local s = G_reader_settings:readSetting("kosync")
    return type(s) == "table" and s or {}
end

--- The list, with each one's value now.
function S.items()
    local out = {}
    local sleepOptions, sleepNow = S.sleepOptions()
    table.insert(out, { key = "sleep_after", name = _("Sleep after"), kind = "choice", value = sleepNow,
        label = S.sleepAfterName(sleepNow), options = sleepOptions,
        note = _("How long the Kindle waits, untouched, before it goes to sleep.") })
    local refresh = UIManager:getRefreshRate()
    table.insert(out, { key = "refresh", name = _("Full refresh"), kind = "choice", value = refresh,
        label = labelOf(REFRESH, refresh) or T(_("Every %1 pages"), refresh), options = REFRESH,
        note = _("While reading: how often the page flashes clean.") })
    local rot = rotation()
    local rotOptions = rotationOptions()
    table.insert(out, { key = "rotation", name = _("Rotation"), kind = "choice", value = rot, label = labelOf(rotOptions, rot), options = rotOptions })
    local zones = G_reader_settings:readSetting("page_turns_tap_zones", "default")
    table.insert(out, { key = "tap_zones", name = _("Page turn tap zones"), kind = "choice", value = zones,
        label = labelOf(TAP_ZONES, zones) or zones, options = TAP_ZONES })
    local r = reader()
    local inverse = r and r.view and r.view.inverse_reading_order
    if inverse == nil then inverse = G_reader_settings:isTrue("inverse_reading_order") end
    table.insert(out, { key = "invert", name = _("Invert page turns"), kind = "switch", value = inverse == true,
        note = _("Swaps the next and previous page sides, for left-handed reading or right-to-left books.") })
    local font = defaultFont()
    table.insert(out, { key = "font", name = _("Font for new books"), kind = "choice", value = font, label = font,
        note = _("The open book keeps its own.") })
    local size = fontSize()
    table.insert(out, { key = "font_size", name = _("Font size for new books"), kind = "choice", value = size,
        label = tostring(size), options = fontSizeOptions() })
    table.insert(out, { key = "status_bar", name = _("Status bar in books"), kind = "switch", value = footerOn() })
    if kosyncInstalled() then
        local k = kosync()
        local signed = k.username ~= nil and k.userkey ~= nil
        table.insert(out, { key = "kosync", name = _("Progress sync"), kind = "switch", value = k.auto_sync == true,
            note = signed and _("Keeps your place in sync with KOReader on your other devices.")
                or _("Needs a sync account: KOReader's menu > Tools > Progress sync.") })
    end
    return out
end

-- ------------------------------------------------------------------ fonts (the web page's Fonts tab)

-- crengine's own defaults for these (creoptions.lua), when no default was set.
local WEIGHTS = { { "−1", -1 }, { "−½", -0.5 }, { "0", 0 }, { "+½", 0.5 }, { "+1", 1 }, { "+1½", 1.5 }, { "+3", 3 } }
local HINTING = { { _("Off"), 0 }, { _("Native"), 1 }, { _("Auto"), 2 } }
local KERNING = { { _("Off"), 0 }, { _("Fast"), 1 }, { _("Good"), 2 }, { _("Best"), 3 } }

local function copt(name, default)
    local v = G_reader_settings:readSetting("copt_" .. name)
    if v == nil then return default end
    return v
end

--- The first fallback font: the one picked, else crengine's first.
local function fallbackFont()
    return G_reader_settings:readSetting("fallback_font") or (require("document/credocument").fallback_fonts or {})[1] or ""
end

--- KOReader's font settings: the font and size for new books, the fallback
-- fonts (for every book), and the book defaults for embedded fonts, weight,
-- hinting and kerning. `advanced` marks the last two.
function S.fontItems()
    local fonts = S.fontOptions()
    local out = {}
    table.insert(out, { key = "font", name = _("Font for new books"), kind = "choice", value = defaultFont(), label = defaultFont(), options = fonts })
    local size = fontSize()
    table.insert(out, { key = "font_size", name = _("Font size for new books"), kind = "choice", value = size, label = tostring(size), options = fontSizeOptions() })
    local fb = fallbackFont()
    table.insert(out, { key = "fallback", name = _("Fallback font"), kind = "choice", value = fb, label = fb, options = fonts,
        note = _("For characters the book's font doesn't have (Chinese, Japanese, symbols…). In every book, also the open one.") })
    table.insert(out, { key = "more_fallbacks", name = _("Use more fallback fonts"), kind = "switch",
        value = G_reader_settings:nilOrTrue("additional_fallback_fonts"),
        note = _("After the one above, KOReader's own list, for the widest coverage of languages.") })
    local embedded = copt("embedded_fonts", 1) == 1
    table.insert(out, { key = "embedded", name = _("Use the book's own fonts"), kind = "switch", value = embedded,
        note = _("Fonts that come inside a book, when it has any.") })
    local weight = copt("font_base_weight", 0)
    table.insert(out, { key = "weight", name = _("Font weight"), kind = "choice", value = weight, label = labelOf(WEIGHTS, weight) or tostring(weight),
        options = WEIGHTS, note = _("Thinner (−) or bolder (+) text.") })
    local hinting = copt("font_hinting", 2)
    table.insert(out, { key = "hinting", name = _("Hinting"), kind = "choice", value = hinting, label = labelOf(HINTING, hinting), options = HINTING, advanced = true })
    local kerning = copt("font_kerning", 3)
    table.insert(out, { key = "kerning", name = _("Kerning"), kind = "choice", value = kerning, label = labelOf(KERNING, kerning), options = KERNING, advanced = true })
    return out
end

--- Applies one. Returns nil, or a message to show.
function S.set(key, value)
    if key == "sleep_after" then
        S.setSleepAfter(tonumber(value))
    elseif key == "refresh" then
        -- As KOReader's menu (SetBothRefreshRates): the same for day and night.
        local n = tonumber(value)
        UIManager:setRefreshRate(n, n)
    elseif key == "rotation" then
        if value == "auto" then
            G_reader_settings:makeFalse("input_ignore_gsensor")
            Device:toggleGSensor(true)
        else
            -- Locked: the accelerometer ignored, and the same rotation in books and the library.
            G_reader_settings:makeTrue("input_ignore_gsensor")
            Device:toggleGSensor(false)
            G_reader_settings:makeTrue("lock_rotation")
            local mode = value == "landscape" and Screen.DEVICE_ROTATED_CLOCKWISE or Screen.DEVICE_ROTATED_UPRIGHT
            if Screen:getRotationMode() ~= mode then UIManager:broadcastEvent(Event:new("SetRotationMode", mode)) end
        end
    elseif key == "tap_zones" then
        G_reader_settings:saveSetting("page_turns_tap_zones", value)
        local r = reader()
        if r and r.view and r.view.setupTouchZones then r.view:setupTouchZones() end
    elseif key == "invert" then
        -- KOReader's default for new books, and the open book too.
        local on = value == true or value == "true"
        G_reader_settings:saveSetting("inverse_reading_order", on)
        local r = reader()
        if r and r.view and r.view.onToggleReadingOrder and (r.view.inverse_reading_order == true) ~= on then
            r.view:onToggleReadingOrder()
        end
    elseif key == "font" then
        if type(value) == "string" and value ~= "" then G_reader_settings:saveSetting("cre_font", value) end
    elseif key == "font_size" then
        local n = tonumber(value)
        if n then G_reader_settings:saveSetting("copt_font_size", n) end
    elseif key == "fallback" or key == "more_fallbacks" then
        -- As KOReader's font menu: saved, and the open book's fallbacks set up again.
        if key == "fallback" then
            if type(value) ~= "string" or value == "" then return end
            G_reader_settings:saveSetting("fallback_font", value)
        else
            G_reader_settings:saveSetting("additional_fallback_fonts", value == true or value == "true")
        end
        local r = reader()
        if r and r.document and r.document.setupFallbackFontFaces then
            r.document:setupFallbackFontFaces()
            r:handleEvent(Event:new("UpdatePos"))
        end
    elseif key == "embedded" then
        -- The default for new books, as the bottom menu's "Set as default" saves it.
        G_reader_settings:saveSetting("copt_embedded_fonts", (value == true or value == "true") and 1 or 0)
    elseif key == "weight" or key == "hinting" or key == "kerning" then
        local n = tonumber(value)
        local name = ({ weight = "font_base_weight", hinting = "font_hinting", kerning = "font_kerning" })[key]
        if n then G_reader_settings:saveSetting("copt_" .. name, n) end
    elseif key == "status_bar" then
        local on = value == true or value == "true"
        local r = reader()
        local footer = r and r.view and r.view.footer
        if footer and footer.onToggleFooterMode then
            -- KOReader's own toggle (it saves reader_footer_mode for the next book too).
            if (footer.mode ~= 0) ~= on then footer:onToggleFooterMode() end
        else
            G_reader_settings:saveSetting("reader_footer_mode", on and 1 or 0)
        end
    elseif key == "kosync" then
        local on = value == true or value == "true"
        local r = reader()
        if r and r.kosync and r.kosync.onKOSyncToggleAutoSync then
            -- The open book's KOSync, as its menu does (it fetches or sends the position now).
            if (r.kosync.settings.auto_sync == true) ~= on then r.kosync:onKOSyncToggleAutoSync(nil, true) end
            return
        end
        if on and Device:hasSeamlessWifiToggle() and G_reader_settings:readSetting("wifi_enable_action") ~= "turn_on" then
            return _("To turn on Progress sync, first set KOReader's Network > Action when Wi-Fi is off to Turn on.")
        end
        local k = kosync()
        k.auto_sync = on
        G_reader_settings:saveSetting("kosync", k)
    end
    G_reader_settings:flush()
end

-- ------------------------------------------------------------------ the page on the Kindle

--- The Common settings page's rows (appshub's settings page), KOReader's full menu last.
function S.rows(openMenu)
    local rows = { { heading = _("COMMON SETTINGS") } }
    for __, it in ipairs(S.items()) do
        if it.kind == "switch" then
            table.insert(rows, { it.name, it.value, function()
                local msg = S.set(it.key, not it.value)
                if msg then require("appsko").message(msg) end
            end })
        else
            table.insert(rows, { it.name, it.label or "", pick = function()
                local options = it.key == "font" and S.fontOptions() or it.options
                return options, it.value, function(v)
                    local msg = S.set(it.key, v)
                    if msg then require("appsko").message(msg) end
                end
            end })
        end
    end
    table.insert(rows, { heading = _("EVERYTHING ELSE") })
    -- Which items the status bar shows: KOReader's own menu, which only a book has.
    local r = reader()
    table.insert(rows, { _("Status bar items"), r and _("KOReader's menu") or _("In a book"), function()
        if r then return S.openStatusBarMenu(r) end
        require("appsko").message(_("Open a book, then come back here: the status bar's items are chosen in KOReader's menu, which a book has."))
    end })
    table.insert(rows, { _("Open KOReader's full menu"), "", openMenu })
    return rows
end

--- In a book: KOReader's own Status bar menu (its items, presets and the rest).
function S.openStatusBarMenu(r)
    local menu = r and r.menu
    if not (menu and menu.onShowMenu) then return end
    if menu.tab_item_table == nil and menu.setUpdateItemTable then menu:setUpdateItemTable() end
    local want = _("Status bar")
    for i, tab in ipairs(menu.tab_item_table or {}) do
        for __, item in ipairs(tab) do
            if type(item) == "table" and item.text == want then
                menu:onShowMenu(i)
                local tm = menu.menu_container and menu.menu_container[1]
                if tm and tm.onMenuSelect then tm:onMenuSelect(item) end
                return
            end
        end
    end
    menu:onShowMenu()
end

return S
