--[[--
FlashForge's screens, drawn as the other apps' pages (ffpage):
  FlashForge     the print (picture, state, progress, time left), its
                 buttons (Pause, Resume, Cancel, Clear, Light, Filter,
                 Camera), temperatures, the Material Station, and Recent
                 files, Camera and Details
  Recent files   the printer's ten latest; a file: its picture and
                 materials, Start print (and matching its materials to the
                 Material Station's slots on the AD5X)
  Camera         one picture, taken again with ⟳ or Take again
  Details        the model, firmware, address and lifetime counts
  Settings       how often it's read, levelling, the printer's address,
                 serial number and check code
  Find printers  the printers on this Wi-Fi, or one entered by hand
While a FlashForge page is on top, the printer is read every few seconds
(Settings > Read every); nothing is read once it closes.
]]

local Device = require("device")
local Event = require("ui/event")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local KO = require("ffko")
local M = require("ffmodel")

local UI = {}

-- The pages open now, oldest first (Home closes them all).
UI.pages = {}

local function Page() return require("ffpage") end
local function PS() return require("pluginshare") end
local function twentyFour() return not G_reader_settings:isTrue("twelve_hour_clock") end

--- The Apps launcher (when it's installed).
function UI.launcher()
    if KO.home() then return end
    local plugin = UI.plugin
    if plugin and plugin.ui and plugin.ui.apps then plugin.ui:handleEvent(Event:new("ShowApps")) end
end

--- Home: every FlashForge page closes, then the launcher.
function UI.home()
    local pages = {}
    for i, p in ipairs(UI.pages) do pages[i] = p end
    for i = #pages, 1, -1 do pages[i]:onCloseAllMenus() end
    UI.launcher()
end

--- The page on top, as the plugin's `screen` (the launcher's recent apps bring it back).
function UI.noteScreen()
    if UI.plugin then UI.plugin.screen = UI.pages[#UI.pages] end
end

--- ⋮ on every page: Find printers, Details, Help; then Recent apps, Light,
-- Night mode, Refresh screen and Settings last.
function UI.more()
    local plugin = UI.plugin
    if not plugin then return end
    KO.menu(plugin.ui, {
        { _("Find printers"), function() UI.find(plugin) end },
        { _("Details"), function() UI.details(plugin) end },
        { _("Help"), function() UI.help() end },
    }, function() UI.settings(plugin) end)
end

-- A short signature of a page's items, so a read that changed nothing shown doesn't redraw.
local function signature(items)
    local parts = {}
    local function add(v) if v ~= nil then parts[#parts + 1] = tostring(v) end end
    local function each(t)
        for __, it in ipairs(t or {}) do
            add(it.band) add(it.text) add(it.sub) add(it.value) add(it.right) add(it.note) add(it.message) add(it.picture)
            add(it.toggle) add(it.swatch)
            if it.job then
                add(it.job.state) add(it.job.title) add(it.job.picture) add(table.concat(it.job.lines or {}, "|"))
                add(it.job.bar and math.floor(it.job.bar * 100))
            end
            for __, k in ipairs({ "tiles", "stats", "quick" }) do
                for __, x in ipairs(it[k] or {}) do add(x.text) add(x.sub) add(x.value) add(x.label) add(x.primary) end
            end
        end
    end
    each(items)
    return table.concat(parts, "\n")
end

--- The pages again from what was read: each makes its items again; only the
-- one on top is redrawn, and only when something it shows changed.
function UI.refreshAll()
    local top = UIManager:getTopmostVisibleWidget()
    for __, p in ipairs(UI.pages) do
        if p.items_fn then
            local items = p.items_fn()
            local sig = signature(items)
            if sig ~= p.sig then
                p.sig = sig
                p.item_table = items
                if p == top then p:redraw() else p:render() end
            end
        end
    end
end

--- A page: items, or a function making them (then ⟳ and each read make them again).
local function page(title, items, opts)
    opts = opts or {}
    local fn = type(items) == "function" and items or nil
    local p = Page():new{ title = title, subtitle = opts.subtitle, item_table = fn and fn() or items, items_fn = fn,
        top = opts.top, status = opts.status, on_refresh = opts.on_refresh, bar_buttons = opts.buttons }
    p.sig = signature(p.item_table)
    UIManager:show(p)
    return p
end

-- ------------------------------------------------------------------ boxes

--- One line of text: cb(text) on Save. opts: { number, password, description, ok }.
local function ask(title, value, cb, opts)
    opts = opts or {}
    local request = KO.request()
    if request then
        return request{ title = title, subtitle = opts.description, text = value or "", number = opts.number,
            password = opts.password, typing = true,
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = opts.okIcon or "check", text = opts.ok or _("Save"), primary = true, fn = function(v) cb(v) end },
            } }
    end
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value or "",
        input_type = opts.number and "number" or nil,
        text_type = opts.password and "password" or nil,
        description = opts.description,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = opts.ok or _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText()
                UIManager:close(dialog)
                cb(v)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Whether a page is still open (an answer can come after it closed).
local function alive(p)
    for __, q in ipairs(UI.pages) do if q == p then return true end end
    return false
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function failed(plugin, why) KO.toast(plugin:whyText(why), 4) end

-- ------------------------------------------------------------------ reading while open

--- Every few seconds while one of FlashForge's pages is on top: the printer again.
function UI.poll(plugin)
    if UI.polling then return end
    UI.polling = true
    local function tick()
        if #UI.pages == 0 then
            UI.polling = false
            return
        end
        local top = UIManager:getTopmostVisibleWidget()
        for __, p in ipairs(UI.pages) do
            if p == top and p.live then
                plugin:fetch()
                break
            end
        end
        UIManager:scheduleIn(plugin:interval(), tick)
    end
    UIManager:scheduleIn(plugin:interval(), tick)
end

-- ------------------------------------------------------------------ the main page

-- The current print's picture: read once per file name; the page is redrawn when it's in.
local thumbs = {}
local function printPicture(plugin, file)
    if not file or file == "" then return nil end
    local t = thumbs[file]
    if t == nil then
        thumbs[file] = false
        plugin:thumbnail(file, function(path)
            thumbs[file] = path or ""
            if path then UI.refreshAll() end
        end)
        return nil
    end
    return t ~= false and t ~= "" and t or nil
end

--- The buttons under the print: what can be done now.
local function controls(plugin, i)
    local q = {}
    local st = i.state
    if M.canPause(st) then
        table.insert(q, { icon = "pause", text = _("Pause"), fn = function()
            plugin:act("pause", {}, function(ok, why) if not ok then failed(plugin, why) end end, { text = _("Pausing…") })
        end })
    elseif M.canResume(st) then
        table.insert(q, { icon = "play", text = _("Resume"), fn = function()
            plugin:act("resume", {}, function(ok, why) if not ok then failed(plugin, why) end end, { text = _("Resuming…") })
        end })
    end
    if M.active(st) then
        table.insert(q, { icon = "x", text = _("Cancel"), fn = function() UI.cancel(plugin) end })
    end
    if M.canClear(st) then
        table.insert(q, { icon = "circle-check", text = _("Clear"), fn = function()
            plugin:act("clear", {}, function(ok, why)
                if ok then KO.toast(_("Ready for the next print")) else failed(plugin, why) end
            end)
        end })
    end
    if plugin:hasLight() then
        table.insert(q, { icon = "lightbulb", text = _("Light"), sub = i.light and _("On") or _("Off"), fn = function()
            plugin:act("light", { on = not i.light }, function(ok, why) if not ok then failed(plugin, why) end end)
        end })
    end
    if i.hasFiltration then
        table.insert(q, { icon = "fan", text = _("Filter"), sub = M.filtrationText(i.filtration), fn = function()
            UI.filtration(plugin, i)
        end })
    end
    if i.camera then
        table.insert(q, { icon = "camera", text = _("Camera"), fn = function() UI.camera(plugin) end })
    end
    return q
end

function UI.mainItems(plugin)
    local t = {}
    if not plugin:configured() then
        t[#t + 1] = { message = _("No printer set up yet.") }
        t[#t + 1] = { note = _("Turn on LAN-only mode on the printer (Settings > Network) and note the check code it shows. Then find it on this Wi-Fi, or enter its address by hand.") }
        t[#t + 1] = { gap = 10 }
        t[#t + 1] = { tiles = {
            { icon = "search", text = _("Find printers"), sub = _("On this Wi-Fi"), primary = true, fn = function() UI.find(plugin) end },
            { icon = "pencil", text = _("Enter by hand"), sub = _("IP address"), fn = function() UI.manual(plugin) end },
        }, cols = 2 }
        return t
    end
    local i = plugin:info()
    if not i then
        local why = plugin:lastWhy()
        t[#t + 1] = { message = why and plugin:whyText(why) or _("Reading the printer…") }
        if why then
            t[#t + 1] = { tiles = {
                { icon = "refresh-cw", text = _("Try again"), primary = true, fn = function() plugin:fetch() end },
                { icon = "sliders-horizontal", text = _("Settings"), fn = function() UI.settings(plugin) end },
            }, cols = 2 }
        end
        return t
    end
    local job = { state = M.summary(i) }
    if M.active(i.state) or i.state == "completed" or i.state == "cancelled" then
        job.title = i.file
        job.picture = printPicture(plugin, i.file) or ""
        job.lines = M.jobLines(i, os.time(), twentyFour())
        if M.active(i.state) then job.bar = i.progress end
    else
        job.lines = { i.model }
    end
    if i.error then table.insert(job.lines, T(_("Error code %1"), i.error)) end
    if i.door and i.hasDoor then table.insert(job.lines, _("The door is open")) end
    t[#t + 1] = { job = job }
    local q = controls(plugin, i)
    if #q > 0 then t[#t + 1] = { quick = q, cols = 5 } end

    t[#t + 1] = { band = _("TEMPERATURES") }
    local stats = {}
    if #i.tools > 1 then
        for k, tool in ipairs(i.tools) do
            table.insert(stats, { icon = "flame", label = T(_("Tool %1"), k), value = M.temp(tool) })
        end
    else
        table.insert(stats, { icon = "flame", label = _("Nozzle"), value = M.temp(i.nozzle) })
    end
    table.insert(stats, { icon = "thermometer", label = _("Bed"), value = M.temp(i.bed) })
    if i.chamber then table.insert(stats, { icon = "thermometer", label = _("Chamber"), value = M.temp(i.chamber) }) end
    t[#t + 1] = { stats = stats, cols = 3 }

    if M.active(i.state) then
        t[#t + 1] = { band = _("PRINT") }
        local p = {
            { icon = "gauge", label = _("Speed"), value = T("%1%", math.floor(i.speed + 0.5)) },
            { icon = "fan", label = _("Cooling fan"), value = T("%1%", math.floor(i.coolingFan + 0.5)) },
        }
        if i.weight > 0 then
            table.insert(p, { icon = "layers", label = _("Filament"),
                value = T(_("%1 g"), math.floor(i.weight * i.progress + 0.5)) .. " / " .. T(_("%1 g"), math.floor(i.weight + 0.5)) })
        elseif i.filament ~= "" then
            table.insert(p, { icon = "layers", label = _("Filament"), value = i.filament })
        end
        t[#t + 1] = { stats = p, cols = 3 }
    end

    if #i.slots > 0 then
        t[#t + 1] = { band = _("MATERIAL STATION") }
        for __, s in ipairs(i.slots) do
            t[#t + 1] = { text = T(_("Slot %1"), s.id), sub = s.empty and _("Empty") or M.slotText(s),
                swatch = not s.empty and M.grey(s.color) or nil, icon = s.empty and "circle-dashed" or nil,
                right = s.id == i.currentSlot and _("In use") or nil }
        end
    end

    t[#t + 1] = { band = _("MORE") }
    t[#t + 1] = { tiles = {
        { icon = "file", text = _("Recent files"), sub = _("Start a print"), fn = function() UI.files(plugin) end },
        { icon = "camera", text = _("Camera"), sub = i.camera and _("A picture") or _("None reported"), fn = function() UI.camera(plugin) end },
        { icon = "info", text = _("Details"), sub = i.firmware ~= "" and T(_("Firmware %1"), i.firmware) or i.model,
            fn = function() UI.details(plugin) end },
    }, cols = 3 }
    return t
end

--- The line at the foot: when it was read; the address.
local function mainStatus(plugin)
    local when = plugin:readTime()
    local left
    if plugin:reading() and when == 0 then left = _("Reading…")
    elseif when > 0 then left = T(_("Updated %1"), M.clock(when, twentyFour())) end
    if plugin:lastWhy() and when > 0 then left = T(_("Not answering · last read %1"), M.clock(when, twentyFour())) end
    return left, plugin:cfg().ip
end

--- FlashForge's first page; page "settings": its settings over it.
function UI.show(plugin, which)
    UI.plugin = plugin
    if PS().noteRecent then pcall(PS().noteRecent, "flashforge") end
    -- (already open: back to its first page)
    if UI.pages[1] and UI.pages[1].isMain then
        for k = #UI.pages, 2, -1 do UI.pages[k]:onClose() end
    else
        local p = page(plugin:printerName(), function() return UI.mainItems(plugin) end,
            { top = true, status = function() return mainStatus(plugin) end,
              on_refresh = function() plugin:fetch() end })
        p.isMain, p.live = true, true
        p.items_fn = function()
            p.title = plugin:printerName()
            return UI.mainItems(plugin)
        end
    end
    plugin:fetch()
    UI.poll(plugin)
    if which == "settings" then UI.settings(plugin) end
end

-- ------------------------------------------------------------------ controls

function UI.cancel(plugin)
    local i = plugin:info()
    KO.confirm{ title = _("Cancel print?"),
        text = T(_("%1 stops and can't be resumed."), (i and i.file ~= "" and i.file) or _("The print")),
        ok = _("Cancel print"), cancel = _("Keep printing"), danger = true,
        onOk = function()
            plugin:act("cancel", {}, function(ok, why)
                if ok then KO.toast(_("Print cancelled")) else failed(plugin, why) end
            end, { text = _("Cancelling…") })
        end }
end

function UI.filtration(plugin, i)
    KO.choose(_("Air filter"), {
        { label = _("Off"), value = "off" },
        { label = _("Internal (filters the air inside)"), value = "internal" },
        { label = _("External (vents the air out)"), value = "external" },
    }, i.filtration, function(mode)
        plugin:act("filtration", { mode = mode }, function(ok, why) if not ok then failed(plugin, why) end end)
    end)
end

-- ------------------------------------------------------------------ the camera

function UI.camera(plugin)
    local shot, why
    local p
    local function items()
        local t = {}
        t[#t + 1] = { picture = shot or "", h = 420, empty = why and plugin:whyText(why) or _("Taking a picture…") }
        t[#t + 1] = { note = _("One picture at a time, to keep the Kindle's battery: tap Take again or ⟳ for a new one.") }
        t[#t + 1] = { tiles = { { icon = "camera", text = _("Take again"), primary = true, fn = function() p.take() end } }, cols = 3 }
        return t
    end
    p = page(_("Camera"), items, { status = function()
        return shot and T(_("Taken %1"), M.clock(os.time(), twentyFour())) or nil, plugin:printerName()
    end })
    function p.take()
        plugin:snapshot(function(path, err)
            if not alive(p) then return end
            shot, why = path, err
            if not path then shot = nil end
            p.item_table = items()
            p:redraw("full")
        end)
    end
    p.on_refresh = function() p.take() end
    p.take()
end

-- ------------------------------------------------------------------ details

function UI.details(plugin)
    local function items()
        local i = plugin:info()
        local c = plugin:cfg()
        local t = {}
        local function row(name, value) if value and value ~= "" then t[#t + 1] = { setting = true, text = name, value = value } end end
        t[#t + 1] = { band = _("PRINTER") }
        row(_("Name"), plugin:printerName())
        row(_("Model"), (i and i.model) or c.model)
        row(_("IP address"), c.ip)
        row(_("Serial number"), c.serial and M.masked(c.serial) or nil)
        if i then
            row(_("Firmware"), i.firmware)
            row(_("Nozzle"), i.nozzleSize)
            row(_("Filament"), i.filament)
            row(_("Free space"), i.disk and T(_("%1 GB"), string.format("%.1f", i.disk)) or nil)
            if i.tvoc then row(_("Air quality (TVOC)"), tostring(i.tvoc)) end
            if i.hasDoor then row(_("Door"), i.door and _("Open") or _("Closed")) end
            row(_("Error code"), i.error or _("None"))
            row(_("Status from the printer"), i.status)
            t[#t + 1] = { band = _("LIFETIME") }
            row(_("Printing time"), M.lifetime(i.totalMinutes))
            row(_("Filament used"), T(_("%1 m"), string.format("%.1f", i.totalFilament)))
        else
            t[#t + 1] = { note = _("The rest shows once the printer has been read.") }
        end
        return t
    end
    page(_("Details"), items)
end

-- ------------------------------------------------------------------ files and printing

--- Recent files (read when opened, and with ⟳).
function UI.files(plugin)
    local i = plugin:info()
    local list, why
    local p
    local function items()
        local t = {}
        local info = plugin:info()
        if info and info.isC5 then
            -- The Creator 5 starts a stored file, but doesn't say which materials it uses, so
            -- its tools can't be matched to the right slots: as the Home Assistant card, no list.
            t[#t + 1] = { message = _("Local job management is not available on this printer.") }
            t[#t + 1] = { note = _("The Creator 5 doesn't report which materials a stored file uses, so a print started from here could use whatever is loaded in each slot. Start prints from FlashForge's own app or the printer's screen.") }
            return t
        end
        if not list then
            t[#t + 1] = { message = why and plugin:whyText(why) or _("Reading the printer's files…") }
            return t
        end
        t[#t + 1] = { band = _("RECENT FILES"), right = tostring(#list) }
        if #list == 0 then t[#t + 1] = { message = _("No files on the printer yet.") } end
        for __, f in ipairs(list) do
            local sub = M.fileLine(f)
            t[#t + 1] = { icon = "file", text = f.name, sub = sub ~= "" and sub or nil, chevron = true,
                callback = function() UI.file(plugin, f) end }
        end
        t[#t + 1] = { note = _("The printer lists its ten most recent files.") }
        return t
    end
    local function read()
        if i and i.isC5 then return end
        plugin:readFiles(function(l, w)
            if not alive(p) then return end
            list, why = l, w
            p.item_table = items()
            p:redraw()
        end)
    end
    p = page(_("Recent files"), items, { on_refresh = read })
    read()
end

--- Why a print can't start now (the printer busy), or nil.
local function busy(plugin)
    local i = plugin:info()
    if not i then return _("The printer hasn't been read yet.") end
    if M.active(i.state) or i.state == "busy" or i.state == "calibrating" then
        return T(_("The printer is busy: %1."), M.stateText(i.state))
    end
    if M.canClear(i.state) then return _("Clear the plate first (Clear on the printer's page).") end
end

--- Start the print: body from ffmodel.printBody; a confirm first.
local function start(plugin, f, mappings, warnings)
    local i = plugin:info()
    local text = T(_("Start printing %1 on %2?"), f.name, plugin:printerName())
    if plugin:leveling() then text = text .. "\n\n" .. _("The bed is levelled first.") end
    if warnings and #warnings > 0 then
        text = text .. "\n\n" .. _("The colours differ (it still prints):") .. "\n" .. table.concat(warnings, "\n")
    end
    KO.confirm{ title = _("Start print"), text = text, ok = _("Start"), cancel = _("Cancel"),
        onOk = function()
            plugin:act("print", { body = M.printBody(i, f.name, plugin:leveling(), mappings) }, function(ok, why)
                if ok then
                    KO.toast(_("Print started"))
                    -- (back to the printer's page, to watch it)
                    for k = #UI.pages, 2, -1 do UI.pages[k]:onClose() end
                else
                    failed(plugin, why)
                end
            end, { text = _("Starting the print…") })
        end }
end

--- A file: its picture, its materials, and Start print.
function UI.file(plugin, f)
    local thumb
    local p
    local function items()
        local t = {}
        t[#t + 1] = { picture = thumb or "", h = 260, empty = thumb == false and _("No picture") or _("Reading its picture…") }
        local line = M.fileLine(f)
        if line ~= "" then t[#t + 1] = { line = line } end
        if #f.tools > 0 then
            t[#t + 1] = { band = #f.tools == 1 and _("MATERIAL") or _("MATERIALS") }
            for __, tool in ipairs(f.tools) do
                local c = M.colorName(tool.color)
                t[#t + 1] = { text = T(_("Tool %1 · %2"), tool.id + 1, tool.material ~= "" and tool.material or _("Unknown")),
                    sub = c ~= "" and c or nil, swatch = M.grey(tool.color),
                    right = tool.weight > 0 and T(_("%1 g"), math.floor(tool.weight + 0.5)) or nil }
            end
        end
        t[#t + 1] = { band = _("PRINTING") }
        t[#t + 1] = { toggle = plugin:leveling(), text = _("Level the bed first"), sub = _("Every print, until turned off"),
            callback = function()
                G_reader_settings:saveSetting("flashforge_leveling", not plugin:leveling())
                p.item_table = items()
                p:redraw()
            end }
        t[#t + 1] = { gap = 8 }
        t[#t + 1] = { tiles = { { icon = "play", text = _("Start print"), primary = true, fn = function() UI.startFile(plugin, f) end } },
            cols = 3 }
        return t
    end
    p = page(f.name, items)
    plugin:thumbnail(f.name, function(path)
        if not alive(p) then return end
        thumb = path or false
        p.item_table = items()
        p:redraw()
    end)
end

--- Start print: matching first when the file's materials and the Material Station are known.
function UI.startFile(plugin, f)
    local why = busy(plugin)
    if why then return KO.message(why, _("Start print")) end
    local i = plugin:info()
    if i.isC5 then return KO.message(_("Local job management is not available on this printer."), _("Start print")) end
    if M.needsMatching(f, i.slots) then return UI.match(plugin, f) end
    start(plugin, f)
end

--- Matching the file's materials to the Material Station's slots (the AD5X):
-- each tool's slot, suggested to start with; a slot that can't be used says why.
function UI.match(plugin, f)
    local i = plugin:info()
    local chosen = M.autoMatch(f, i.slots)
    local p
    local function slotById(id)
        for __, s in ipairs(plugin:info().slots) do if s.id == id then return s end end
    end
    local function items()
        local t = {}
        t[#t + 1] = { note = _("Choose the Material Station slot for each of the file's materials. The materials must match; a different colour still prints.") }
        t[#t + 1] = { band = _("MATERIALS") }
        for __, tool in ipairs(f.tools) do
            local s = chosen[tool.id] and slotById(chosen[tool.id])
            local c = M.colorName(tool.color)
            t[#t + 1] = { text = T(_("Tool %1 · %2"), tool.id + 1, tool.material ~= "" and tool.material or _("Unknown")) .. (c ~= "" and (" · " .. c) or ""),
                sub = s and T(_("Slot %1 · %2"), s.id, M.slotText(s)) or _("Choose a slot"),
                swatch = M.grey(tool.color), chevron = true, bold = s == nil,
                callback = function() UI.pickSlot(plugin, tool, chosen, function() p.item_table = items() p:redraw() end) end }
        end
        t[#t + 1] = { gap = 8 }
        t[#t + 1] = { tiles = { { icon = "play", text = _("Start print"), primary = true, fn = function()
            local mappings, bad = M.validate(f, plugin:info().slots, chosen)
            if not mappings then return KO.message(bad, _("Start print")) end
            start(plugin, f, mappings, M.colorWarnings(mappings))
        end } }, cols = 3 }
        return t
    end
    p = page(_("Match materials"), items, { subtitle = f.name })
end

function UI.pickSlot(plugin, tool, chosen, done)
    local list = {}
    for __, s in ipairs(plugin:info().slots) do
        local problem = M.slotProblem(tool, s, chosen)
        table.insert(list, { text = T(_("Slot %1 · %2"), s.id, M.slotText(s)) .. (problem and ("  (" .. problem .. ")") or ""),
            enabled = problem == nil, checked = chosen[tool.id] == s.id,
            fn = function()
                chosen[tool.id] = s.id
                done()
            end })
    end
    KO.list(T(_("Tool %1 · %2"), tool.id + 1, tool.material), list)
end

-- ------------------------------------------------------------------ setting up the printer

--- After the printer's settings changed: read it, and say whether it answered.
local function check(plugin)
    plugin:fetch(function(i, why)
        if i then
            KO.toast(T(_("Connected to %1"), i.name))
        else
            KO.message(plugin:whyText(why), _("The printer didn't answer"))
        end
    end)
end

--- The check code (and the serial number when it isn't known), then saved and read.
local function askCode(plugin, p)
    local function code(serial)
        ask(_("Check code"), "", function(v)
            v = trim(v)
            if v == "" then return KO.toast(_("Enter the check code")) end
            plugin:setCfg({ ip = p.ip, serial = serial, code = v, name = p.name ~= "" and p.name or false, model = p.model or false })
            if #UI.pages == 0 then UI.show(plugin) end
            check(plugin)
        end, { description = _("On the printer: Settings > Network > LAN-only mode shows it."), ok = _("Connect"), okIcon = "check" })
    end
    if p.serial and p.serial ~= "" then return code(p.serial) end
    ask(_("Serial number"), plugin:cfg().serial or "", function(v)
        v = trim(v)
        if v == "" then return KO.toast(_("Enter the serial number")) end
        code(v)
    end, { description = _("On the printer: Settings > About. Include the SN at the start."), ok = _("Next"), okIcon = "chevron-right" })
end

--- Find printers on this Wi-Fi, then pick one.
function UI.find(plugin)
    plugin:discover(function(list, why)
        if not list then return failed(plugin, why) end
        local items = {}
        for __, p in ipairs(list) do
            table.insert(items, { text = p.supported and T("%1 · %2 · %3", p.name, p.model, p.ip)
                    or T(_("%1 · %2 (no LAN API)"), p.name, p.ip),
                enabled = p.supported, fn = function() askCode(plugin, p) end })
        end
        table.insert(items, { text = _("Enter by hand…"), fn = function() UI.manual(plugin) end })
        if #list == 0 then
            return KO.list(_("No printers found. Is it on, with LAN-only mode on?"), items)
        end
        KO.list(_("Printers on this Wi-Fi"), items)
    end)
end

--- The printer's IP address by hand, then its serial number and check code.
function UI.manual(plugin)
    ask(_("IP address"), plugin:cfg().ip or "", function(v)
        v = trim(v)
        if not M.isIp(v) then return KO.toast(_("Enter the printer's IP address, such as 192.168.1.50")) end
        askCode(plugin, { ip = v, name = "" })
    end, { description = _("On the printer: Settings > Network shows it."), ok = _("Next"), okIcon = "chevron-right" })
end

-- ------------------------------------------------------------------ settings

local EVERY = { 5, 10, 15, 30, 60, 120, 300 }

local function everyName(s)
    if s < 60 then return T(_("%1 seconds"), s) end
    if s == 60 then return _("1 minute") end
    return T(_("%1 minutes"), s / 60)
end

--- The settings rows: DISPLAY first, the printer's connection last.
function UI.settingsItems(plugin, redo)
    local c = plugin:cfg()
    local t = {}
    t[#t + 1] = { band = _("DISPLAY") }
    t[#t + 1] = { setting = true, text = _("Read every"), value = everyName(plugin:interval()),
        hint = _("While FlashForge is open. Nothing is read once it closes."),
        callback = function()
            local options = {}
            for __, s in ipairs(EVERY) do table.insert(options, { label = everyName(s), value = s }) end
            KO.choose(_("Read every"), options, plugin:interval(), function(s)
                G_reader_settings:saveSetting("flashforge_interval", s)
                redo()
            end)
        end }
    t[#t + 1] = { band = _("PRINTING") }
    t[#t + 1] = { toggle = plugin:leveling(), text = _("Level the bed first"), sub = _("Before each print started from the Kindle"),
        callback = function()
            G_reader_settings:saveSetting("flashforge_leveling", not plugin:leveling())
            redo()
        end }
    t[#t + 1] = { toggle = G_reader_settings:isTrue("flashforge_light_always"), text = _("Always show the light button"),
        sub = _("For a printer that says it has no light"),
        callback = function()
            G_reader_settings:flipNilOrFalse("flashforge_light_always")
            redo()
            UI.refreshAll()
        end }
    t[#t + 1] = { band = _("PRINTER") }
    t[#t + 1] = { setting = true, text = _("Printer"), value = plugin:configured() and plugin:printerName() or _("Not set up"),
        hint = _("Find printers on this Wi-Fi"), callback = function() UI.find(plugin) end }
    t[#t + 1] = { setting = true, text = _("IP address"), value = c.ip or _("Not set"), callback = function()
        ask(_("IP address"), c.ip or "", function(v)
            v = trim(v)
            if not M.isIp(v) then return KO.toast(_("Enter the printer's IP address, such as 192.168.1.50")) end
            plugin:setCfg({ ip = v })
            redo()
            if plugin:configured() then check(plugin) end
        end, { description = _("On the printer: Settings > Network shows it.") })
    end }
    t[#t + 1] = { setting = true, text = _("Serial number"), value = c.serial and M.masked(c.serial) or _("Not set"), callback = function()
        ask(_("Serial number"), c.serial or "", function(v)
            v = trim(v)
            if v == "" then return end
            plugin:setCfg({ serial = v })
            redo()
            if plugin:configured() then check(plugin) end
        end, { description = _("On the printer: Settings > About. Include the SN at the start.") })
    end }
    t[#t + 1] = { setting = true, text = _("Check code"), value = c.code and M.masked(c.code) or _("Not set"), callback = function()
        ask(_("Check code"), "", function(v)
            v = trim(v)
            if v == "" then return end
            plugin:setCfg({ code = v })
            redo()
            if plugin:configured() then check(plugin) end
        end, { description = _("On the printer: Settings > Network > LAN-only mode shows it.") })
    end }
    if plugin:configured() and PS().showConnectionTest then
        t[#t + 1] = { setting = true, text = _("Test connection"), callback = function() PS().showConnectionTest("flashforge") end }
    end
    if plugin:configured() then
        t[#t + 1] = { setting = true, text = _("Remove printer"), callback = function()
            local before = plugin:cfg()
            plugin:setCfg({ ip = false, serial = false, code = false, name = false, model = false })
            redo()
            KO.undo(_("Printer removed"), function()
                plugin:setCfg(before)
                redo()
            end)
        end }
    end
    return t
end

function UI.settings(plugin)
    local p
    local function redo()
        p.item_table = UI.settingsItems(plugin, redo)
        p:redraw()
    end
    p = page(_("FlashForge settings"), UI.settingsItems(plugin, function() redo() end))
end

--- The settings' names, for the launcher's search.
function UI.searchRows(plugin)
    local out = {}
    for __, r in ipairs(UI.settingsItems(plugin, function() end)) do
        if r.text then table.insert(out, { r.text }) end
    end
    return out
end

function UI.help()
    local read = KO.read()
    local text = _([[Shows your FlashForge printer on the Kindle, straight over the Wi-Fi: the print, its progress and time left, the temperatures, and buttons to pause, resume or cancel it, switch the light, set the air filter and take a picture with the camera.

Recent files starts one of the printer's ten latest files. On the AD5X you match the file's materials to the Material Station's slots first.

The printer needs LAN-only mode on (Settings > Network on its screen). The Kindle needs its serial number and check code.

The printer is read while FlashForge is open, and when the launcher shows its tile or a quick button. Nothing runs in the background.]])
    if read then
        return read{ title = _("FlashForge"), text = text, buttons = { { icon = "check", text = _("Done"), primary = true } } }
    end
    KO.message(text, _("FlashForge"))
end

return UI
