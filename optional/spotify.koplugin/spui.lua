--[[--
Spotify's screens, drawn as the other apps' pages (sppage):
  Spotify     what's playing (the album's picture, the song, its artist and
              album, how far it is), the remote's buttons (shuffle, previous,
              play or pause, next, repeat), the volume, the device it plays
              on, and Playlists, Recent and Search
  Devices     the devices that are on: the active one marked, the ones that
              take no commands greyed out; a tap moves playback there
  Playlists   your playlists; a tap plays one
  Recent      recently played songs; a tap plays one, a hold adds it to the queue
  Search      songs, albums, playlists and artists
  Settings    the album's picture, how often it's read, the volume's step, the
              Client ID and the sign-in
While the first page or Devices is on top, Spotify is read every few seconds
(Settings > Read every) and when the song ends; nothing is read once the app
closes.
]]

local Device = require("device")
local Event = require("ui/event")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local KO = require("spko")
local M = require("spmodel")

local UI = {}

-- The pages open now, oldest first (Home closes them all).
UI.pages = {}

local function Page() return require("sppage") end
local function PS() return require("pluginshare") end
local function twentyFour() return not G_reader_settings:isTrue("twelve_hour_clock") end

local function clock(t)
    return os.date(twentyFour() and "%H:%M" or "%I:%M %p", t)
end

--- The Apps launcher (when it's installed).
function UI.launcher()
    if KO.home() then return end
    local plugin = UI.plugin
    if plugin and plugin.ui and plugin.ui.apps then plugin.ui:handleEvent(Event:new("ShowApps")) end
end

--- Home: every Spotify page closes, then the launcher.
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

--- ⋮ on every page: Devices, Search, Help; then Recent apps, Light, Night mode, Refresh
-- screen and Settings last.
function UI.more()
    local plugin = UI.plugin
    if not plugin then return end
    local extra = {}
    if plugin:configured() then
        table.insert(extra, { _("Full screen"), function() UI.player(plugin) end })
        table.insert(extra, { UI.controlsOn and _("Hide player controls") or _("Show player controls"), UI.togglePlayerControls })
        table.insert(extra, { _("Devices"), function() UI.devices(plugin) end })
        table.insert(extra, { _("Queue"), function() UI.queue(plugin) end })
        table.insert(extra, { _("Library"), function() UI.library(plugin) end })
        table.insert(extra, { _("Search"), function() UI.askSearch(plugin) end })
    end
    table.insert(extra, { _("Help"), function() UI.help() end })
    KO.menu(plugin.ui, extra, function() UI.settings(plugin) end)
end

-- A short signature of a page's items, so a read that changed nothing shown doesn't redraw.
local function signature(items)
    local parts = {}
    local function add(v) if v ~= nil then parts[#parts + 1] = tostring(v) end end
    for __, it in ipairs(items or {}) do
        add(it.band) add(it.text) add(it.sub) add(it.value) add(it.right) add(it.note) add(it.message)
        add(it.toggle) add(it.dot) add(it.enabled) add(it.icon) add(it.picture)
        local p = it.playing
        if p then add(p.picture) add(p.title) add(p.artist) add(p.album) add(p.left) add(p.right) end
        if it.volume then add(it.volume.value) add(it.volume.text) end
        for __, k in ipairs({ "tiles", "chips", "controls" }) do
            for __, x in ipairs(it[k] or {}) do add(x.text) add(x.sub) add(x.icon) add(x.on) add(x.enabled) add(x.primary) end
        end
    end
    return table.concat(parts, "\n")
end

-- The title bar's buttons as a signature (the play or pause one changes).
local function buttonsSig(buttons)
    local parts = {}
    for __, b in ipairs(buttons or {}) do parts[#parts + 1] = tostring(b[1]) end
    return "\n" .. table.concat(parts, ",")
end

--- The pages again from what was read: each makes its items again; only the
-- one on top is redrawn, and only when something it shows changed.
function UI.refreshAll()
    local top = UIManager:getTopmostVisibleWidget()
    for __, p in ipairs(UI.pages) do
        if p.items_fn then
            local items = p.items_fn()
            if p.buttons_fn then p.bar_buttons = p.buttons_fn() end
            local sig = signature(items) .. buttonsSig(p.bar_buttons)
            if sig ~= p.sig then
                p.sig = sig
                p.item_table = items
                if p == top then p:redraw() else p:render() end
            end
        end
    end
    if UI.plugin then UI.songEnd(UI.plugin) end
end

--- A page: items, or a function making them (then ⟳ and each read make them again).
-- opts.live: Spotify is read every so often while it's on top.
local function page(title, items, opts)
    opts = opts or {}
    local fn = type(items) == "function" and items or nil
    -- (buttons: a list, or a function making it again with each read)
    local bfn = type(opts.buttons) == "function" and opts.buttons or nil
    local buttons = opts.buttons
    if bfn then buttons = bfn() end
    local p = Page():new{ title = title, subtitle = opts.subtitle, item_table = fn and fn() or items, items_fn = fn,
        top = opts.top, status = opts.status, on_refresh = opts.on_refresh, bar_buttons = buttons }
    p.buttons_fn = bfn
    p.sig = signature(p.item_table) .. buttonsSig(p.bar_buttons)
    p.live = opts.live
    UIManager:show(p)
    return p
end

-- ------------------------------------------------------------------ boxes

--- One line of text: cb(text) on Save. opts: { description, ok, okIcon }.
local function ask(title, value, cb, opts)
    opts = opts or {}
    local request = KO.request()
    if request then
        return request{ title = title, subtitle = opts.description, text = value or "", typing = true,
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = opts.okIcon or "check", text = opts.ok or _("Save"), primary = true, fn = function(v) cb(v) end },
            } }
    end
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value or "",
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

--- A command, with a short message when it didn't work. Several devices on and none playing:
-- Devices opens to pick the one, and the command goes there. after(): once it worked.
local function command(plugin, name, args, okText, after)
    plugin:act(name, args, function(ok, text, why)
        if ok then
            if okText then KO.toast(okText) end
            if after then after() end
            -- (Settings > After starting something: the list stays, or the player comes back)
            if name == "play" and not plugin:staysAfterPlay() then
                for k = #UI.pages, 2, -1 do UI.pages[k]:onClose() end
            end
        elseif why == "choose" then
            UI.devices(plugin, { name = name, args = args, okText = okText, after = after })
        else
            KO.toast(text, 4)
        end
    end)
end
UI.command = command

-- ------------------------------------------------------------------ reading while open

local function livePage()
    local top = UIManager:getTopmostVisibleWidget()
    for __, p in ipairs(UI.pages) do
        if p == top and p.live then return p end
    end
end

--- Every so often while one of Spotify's live pages is on top (and the Kindle is awake):
-- Spotify again. It stops by itself once the app's pages are closed.
function UI.poll(plugin)
    if UI.polling then return end
    UI.polling = true
    local function tick()
        if #UI.pages == 0 then
            UI.polling = false
            return
        end
        local p = livePage()
        if p and not Device.screen_saver_mode then plugin:fetch(nil, { devices = p.devicesPage }) end
        -- (the full screen has its own interval, or the app's)
        UIManager:scheduleIn((p and p.fullScreen) and plugin:playerInterval() or plugin:interval(), tick)
    end
    UIManager:scheduleIn(plugin:interval(), tick)
end

--- The song ends before the next read: one read just after it, for the next song.
function UI.songEnd(plugin)
    if UI.endTask then
        UIManager:unschedule(UI.endTask)
        UI.endTask = nil
    end
    local left = M.endsIn(plugin:player() or nil, os.time())
    if not left or left <= 0 or left >= plugin:interval() or #UI.pages == 0 then return end
    UI.endTask = function()
        UI.endTask = nil
        if livePage() and not Device.screen_saver_mode then plugin:fetch() end
    end
    UIManager:scheduleIn(left + 1.5, UI.endTask)
end

--- The line at the foot: when it was read, or that it isn't answering.
local function status(plugin)
    local when = plugin:readTime()
    if plugin:lastWhy() and when > 0 then return T(_("Not answering · last read %1"), clock(when)) end
    if plugin:reading() and when == 0 then return _("Reading…") end
    if when > 0 then return T(_("Updated %1"), clock(when)) end
end

-- ------------------------------------------------------------------ the main page

--- What the page shows before Spotify can be asked or has answered: a message and what to
-- do about it; nil once there is something to show.
local function notReady(plugin)
    local t = {}
    if not plugin:clientId() then
        t[#t + 1] = { message = _("Spotify Remote isn't set up yet.") }
        t[#t + 1] = { tiles = {
            { icon = "key-round", text = _("Set up"), sub = _("Client ID and sign-in"), primary = true, fn = function() UI.setup(plugin) end },
            { icon = "info", text = _("Help"), sub = _("Requirements"), fn = function() UI.help() end },
        }, cols = 2 }
        return t
    end
    local why = plugin:lastWhy()
    if not plugin:signedIn() or (why == "signin" and plugin:player() == nil) then
        t[#t + 1] = { message = plugin:signedIn() and M.whyText("signin") or _("Not signed in to Spotify.") }
        t[#t + 1] = { tiles = {
            { icon = "log-in", text = _("Sign in"), primary = true, fn = function() UI.signIn(plugin) end },
            { icon = "info", text = _("Help"), sub = _("Requirements"), fn = function() UI.help() end },
        }, cols = 2 }
        return t
    end
    if plugin:player() ~= nil then return nil end
    t[#t + 1] = { message = why and M.whyText(why) or _("Reading Spotify…") }
    if why then
        t[#t + 1] = { tiles = {
            { icon = "refresh-cw", text = _("Try again"), primary = true, fn = function() plugin:fetch(nil, { devices = true }) end },
            { icon = "sliders-horizontal", text = _("Settings"), fn = function() UI.settings(plugin) end },
        }, cols = 2 }
    end
    return t
end

function UI.mainItems(plugin)
    local early = notReady(plugin)
    if early then return early end
    local t = {}
    local p = plugin:player() or nil
    local now = os.time()
    local art = plugin:showArt()

    -- What's playing.
    if p then
        local at = M.progressNow(p, now)
        -- (the picture's file; nil: its place, until it's fetched; false: none, without Album art)
        local picture = plugin:artPath(p)
        if not art then picture = false end
        t[#t + 1] = { playing = {
            picture = picture,
            title = p.title ~= "" and p.title or _("Nothing playing"), artist = p.artist, album = p.album,
            bar = p.duration > 0 and at / p.duration or nil,
            left = (p.playing and "" or (_("Paused") .. " · ")) .. M.time(at),
            right = p.duration > 0 and M.time(p.duration) or nil,
            seek = (p.duration > 0 and not p.disallows.seeking) and function(part)
                command(plugin, "seek", { ms = math.floor(p.duration * part) })
            end or nil,
            fn = p.uri ~= "" and function() UI.songMenu(plugin, UI.playingSong(plugin)) end or nil,
            pictureFn = UI.buttonFn(plugin, "art_tap"), pictureHold = UI.buttonFn(plugin, "art_hold"),
        } }
    else
        local none = { title = _("Nothing playing"),
            artist = plugin.store:readSetting("device_name") and T(_("Play starts on %1"), plugin.store:readSetting("device_name")) or nil }
        -- (no picture's place without Album art)
        if not art then none.picture = false end
        t[#t + 1] = { playing = none }
    end

    -- The remote.
    local d = p and p.disallows or {}
    local mode = p and p["repeat"] or "off"
    t[#t + 1] = { controls = {
        { icon = "shuffle", text = _("Shuffle"), on = p and p.shuffle, enabled = p ~= nil and not d.toggling_shuffle,
            fn = function() command(plugin, "shuffle", { on = not p.shuffle }) end },
        { icon = "skip-back", text = _("Previous"), enabled = p ~= nil and not d.skipping_prev,
            fn = function() command(plugin, "previous") end },
        { icon = (p and p.playing) and "pause" or "play", text = (p and p.playing) and _("Pause") or _("Play"), primary = true,
            fn = function() command(plugin, "toggle", {}) end },
        { icon = "skip-forward", text = _("Next"), enabled = p ~= nil and not d.skipping_next,
            fn = function() command(plugin, "next") end },
        { icon = mode == "track" and "repeat-1" or "repeat", text = M.repeatName(mode), on = mode ~= "off",
            enabled = p ~= nil and not d.toggling_repeat_context,
            fn = function() command(plugin, "repeat", { mode = M.nextRepeat(mode) }) end },
    } }

    -- The volume (some devices set their own only).
    local dev = p and p.device
    local volume = dev and dev.supportsVolume and dev.volume or nil
    local by = plugin:volumeBy()
    t[#t + 1] = { volume = { value = volume, text = volume and T(_("%1%"), volume) or "",
        minus = function() plugin:setVolume(M.volumeStep(volume, -by), UI.volumeDone) end,
        plus = function() plugin:setVolume(M.volumeStep(volume, by), UI.volumeDone) end,
        set = function(percent) plugin:setVolume(percent, UI.volumeDone) end } }

    -- The song's own buttons (a song, not an episode or an advertisement).
    if p and p.uri:match("^spotify:track:") then
        local liked = plugin:liked()
        t[#t + 1] = { tiles = {
            { icon = "heart", text = liked and _("Liked") or _("Like"), primary = liked == true,
                fn = function() UI.like(plugin, UI.playingSong(plugin), not liked) end },
            { icon = "list-plus", text = _("Add to playlist"), fn = function() UI.addTo(plugin, UI.playingSong(plugin)) end },
            { icon = "list", text = _("Queue"), fn = function() UI.queue(plugin) end },
        }, cols = 3, h = 44 }
    end
    -- (a sign-in made before Like, Library and the playlists' changes were added doesn't cover them)
    if not plugin:scopesOk() then
        t[#t + 1] = { text = _("Sign in again"), sub = _("For Like, Library and adding to playlists"), icon = "log-in", chevron = true,
            callback = function() UI.signIn(plugin) end }
    end

    if plugin:lastWhy() then t[#t + 1] = { note = M.whyText(plugin:lastWhy()) } end

    t[#t + 1] = { band = dev and _("PLAYING ON") or _("DEVICES") }
    if dev then
        t[#t + 1] = { text = dev.name, sub = M.deviceKind(dev.type), icon = M.deviceIcon(dev.type), chevron = true,
            callback = function() UI.devices(plugin) end }
    else
        local on = 0
        for __, x in ipairs(plugin:devices() or {}) do if x.usable then on = on + 1 end end
        t[#t + 1] = { text = on == 0 and _("None on") or (on == 1 and _("1 on") or T(_("%1 on"), on)),
            icon = "speaker", chevron = true, callback = function() UI.devices(plugin) end }
    end

    t[#t + 1] = { band = _("PLAY") }
    t[#t + 1] = { tiles = {
        { icon = "list", text = _("Playlists"), fn = function() UI.playlists(plugin) end },
        { icon = "library", text = _("Library"), fn = function() UI.library(plugin) end },
        { icon = "clock", text = _("Recent"), fn = function() UI.recent(plugin) end },
        { icon = "search", text = _("Search"), fn = function() UI.askSearch(plugin) end },
        { icon = "music", text = _("DJ"), fn = function() command(plugin, "play", { context = M.DJ }, _("Starting DJ")) end },
    }, cols = 5, h = 44 }
    return t
end

--- The full screen's rows: the album's picture large, then the song, the remote's buttons, the
-- volume and the song's own buttons (the first page's, down to its first heading).
function UI.playerItems(plugin)
    local early = notReady(plugin)
    if early then return early end
    local t = {}
    for __, it in ipairs(UI.mainItems(plugin)) do
        if it.band then break end
        if it.playing then
            if plugin:showArt() then
                t[#t + 1] = { picture = plugin:artPath() or "", h = 400, fn = function() UI.closePlayer() end }
            end
            it.playing.picture, it.playing.pictureFn = false, nil
        end
        t[#t + 1] = it
    end
    return t
end

--- What's playing, full screen. It's read as often as Settings > Full screen: read every says.
function UI.player(plugin)
    for __, p in ipairs(UI.pages) do
        if p.fullScreen then return end
    end
    local p = page(_("Now playing"), function() return UI.playerItems(plugin) end,
        { live = true, on_refresh = function() plugin:fetch(nil, { devices = true }) end })
    p.fullScreen = true
    plugin:fetch()
end

function UI.closePlayer()
    for k = #UI.pages, 1, -1 do
        if UI.pages[k].fullScreen then UI.pages[k]:onClose() end
    end
end

function UI.volumeDone(ok, text)
    if not ok then KO.toast(text, 4) end
end

--- Spotify's first page; page "settings": its settings over it.
function UI.show(plugin, which)
    UI.plugin = plugin
    if PS().noteRecent then pcall(PS().noteRecent, "spotify") end
    -- (already open: back to its first page)
    if UI.pages[1] and UI.pages[1].isMain then
        for k = #UI.pages, 2, -1 do UI.pages[k]:onClose() end
    else
        local p = page(_("Spotify Remote"), function() return UI.mainItems(plugin) end,
            { top = true, live = true, status = function() return status(plugin) end,
              on_refresh = function() plugin:fetch(nil, { devices = true }) end })
        p.isMain = true
        pcall(plugin.pruneArt)
    end
    plugin:fetch(nil, { devices = true })
    UI.poll(plugin)
    if which == "settings" then UI.settings(plugin) end
end

-- ------------------------------------------------------------------ devices

function UI.deviceItems(plugin, pick)
    local early = notReady(plugin)
    if early then return early end
    local list = plugin:devices()
    local t = {}
    if not list then
        t[#t + 1] = { message = plugin:lastWhy() and M.whyText(plugin:lastWhy()) or _("Reading the devices…") }
        return t
    end
    if #list == 0 then
        t[#t + 1] = { message = _("No Spotify device is on.") }
        t[#t + 1] = { note = _("Open Spotify on a phone, computer or speaker.") }
    else
        t[#t + 1] = { band = _("DEVICES"), right = tostring(#list) }
    end
    for __, d in ipairs(list) do
        t[#t + 1] = { text = d.name, sub = M.deviceKind(d.type) .. ((d.usable and d.volume) and (" · " .. T(_("%1%"), d.volume)) or ""),
            icon = M.deviceIcon(d.type), bold = d.active, enabled = d.usable,
            right = d.active and _("Active") or (not d.usable and _("Unavailable") or nil),
            dot = d.active and "on" or nil,
            callback = function() pick(d) end }
    end
    -- Devices used before that Spotify doesn't list now (it lists one only while it's
    -- connected: an idle speaker drops off). A tap tries it anyway.
    local seen = plugin:seenDevices()
    if #seen > 0 then
        t[#t + 1] = { band = _("SEEN BEFORE") }
        for __, d in ipairs(seen) do
            t[#t + 1] = { text = d.name, sub = M.deviceKind(d.type), icon = M.deviceIcon(d.type), right = _("Not on"),
                callback = function() pick(d) end,
                hold_callback = function()
                    KO.list(d.name, {
                        { text = _("Try it"), fn = function() pick(d) end },
                        { text = _("Forget"), fn = function()
                            local old = plugin:forgetDevice(d.id)
                            KO.undo(T(_("%1 forgotten"), d.name), function() plugin:rememberDevice(d.id, old) end)
                        end },
                    })
                end }
        end
        t[#t + 1] = { note = _("A tap tries one anyway. Hold one to forget it.") }
    end
    return t
end

--- The devices that are on. A tap moves playback to one. pending ({ name, args, okText,
-- after }): a command waiting for a device; it goes to the one picked.
function UI.devices(plugin, pending)
    local p
    local function pick(d)
        if pending then
            local args = pending.args or {}
            args.device = d.id
            if p then p:onClose() end
            return command(plugin, pending.name, args, pending.okText, pending.after)
        end
        if d.active then return end
        local playing = plugin:player() and plugin:player().playing
        command(plugin, "transfer", { device = d.id }, T(playing and _("Playing on %1") or _("Play starts on %1"), d.name))
    end
    p = page(pending and _("Play on") or _("Devices"), function() return UI.deviceItems(plugin, pick) end,
        { live = true, status = function() return status(plugin) end,
          on_refresh = function() plugin:fetch(nil, { devices = true }) end })
    p.devicesPage = true
    plugin:fetch(nil, { devices = true })
end

-- ------------------------------------------------------------------ playlists, recent, search

--- A list page that's read once when it opens (and with ⟳): read(done, force) gives the list
-- or nil and why; rows(list) its items.
--- One of the things a button can do (spmodel.BUTTON_ACTIONS).
function UI.doAction(plugin, id)
    if id == "toggle" then return command(plugin, "toggle", {}) end
    if id == "next" or id == "previous" then return command(plugin, id) end
    if id == "controls" then return UI.togglePlayerControls() end
    if id == "player" then
        UI.closePlayer()
        for k = #UI.pages, 2, -1 do UI.pages[k]:onClose() end
        return
    end
    if id == "fullscreen" then return UI.player(plugin) end
    if id == "queue" then return UI.queue(plugin) end
    if id == "menu" then return UI.songMenu(plugin, UI.playingSong(plugin)) end
end

--- What a button does when it's tapped or held (key: spmodel.BUTTONS'), as Settings > BUTTONS
-- has it; nil for Nothing (a hold then does what the tap does, as everywhere).
function UI.buttonFn(plugin, key)
    local id = plugin:button(key)
    if id == "none" then return nil end
    return function() UI.doAction(plugin, id) end
end

--- The player's buttons shown above a list or not (a hold on play or pause in the title bar,
-- or the menu's Player controls): they stay as you go from list to list.
function UI.togglePlayerControls()
    UI.controlsOn = not UI.controlsOn
    UI.refreshAll()
end

--- The remote in a page's title bar, so the music can be handled without leaving a list: play
-- or pause (to start with, a tap: the player's buttons above the list, or away again; a hold: play or pause), and the music note,
-- back to the player (a hold: the full screen). extra: the page's own buttons, after them.
function UI.remote(plugin, extra)
    local p = plugin:player()
    local out = {
        { (p and p.playing) and "pause" or "play", UI.buttonFn(plugin, "play_tap"), UI.buttonFn(plugin, "play_hold") },
        { "music", UI.buttonFn(plugin, "note_tap"), UI.buttonFn(plugin, "note_hold") },
    }
    for __, b in ipairs(extra or {}) do out[#out + 1] = b end
    return out
end

--- A list's rows with the player's buttons above them, when they're shown: the song (a tap:
-- what can be done with it), then Previous, Play or Pause, Next, Like and Add to playlist.
function UI.withControls(plugin, items)
    if not UI.controlsOn then return items end
    local p = plugin:player() or nil
    local d = p and p.disallows or {}
    local song = p and p.uri:match("^spotify:track:") ~= nil
    local liked = plugin:liked()
    local t = { { band = _("NOW PLAYING"), right = _("Hide"), callback = UI.togglePlayerControls } }
    t[#t + 1] = { text = (p and p.title ~= "") and p.title or _("Nothing playing"), sub = p and p.artist or nil, icon = "music",
        callback = (p and p.uri ~= "") and function() UI.songMenu(plugin, UI.playingSong(plugin)) end or nil }
    t[#t + 1] = { controls = {
        { icon = "skip-back", text = _("Previous"), enabled = p ~= nil and not d.skipping_prev,
            fn = function() command(plugin, "previous") end },
        { icon = (p and p.playing) and "pause" or "play", text = (p and p.playing) and _("Pause") or _("Play"), primary = true,
            fn = function() command(plugin, "toggle", {}) end },
        { icon = "skip-forward", text = _("Next"), enabled = p ~= nil and not d.skipping_next,
            fn = function() command(plugin, "next") end },
        { icon = "heart", text = liked and _("Liked") or _("Like"), on = liked == true, enabled = song,
            fn = function() UI.like(plugin, UI.playingSong(plugin), not liked) end },
        { icon = "list-plus", text = _("Add to playlist"), enabled = song,
            fn = function() UI.addTo(plugin, UI.playingSong(plugin)) end },
    } }
    for __, it in ipairs(items) do t[#t + 1] = it end
    return t
end

local function listPage(plugin, title, read, rows, buttons)
    local list, why
    local p
    local function items()
        if not list then return UI.withControls(plugin, { { message = why and M.whyText(why) or _("Reading…") } }) end
        return UI.withControls(plugin, rows(list, function() if p then p:onClose() end end))
    end
    local function got(l, w)
        list, why = l, w
        UI.refreshAll()
    end
    p = page(title, items, { buttons = function() return UI.remote(plugin, buttons) end,
        on_refresh = function() read(got, true) end })
    read(got)
    return p
end

local songsPage   -- (a page of songs with Select: defined below)

function UI.playlists(plugin)
    listPage(plugin, _("Playlists"), function(done, force) plugin:playlists(done, force, true) end, function(list, close)
        local t = {}
        if #list == 0 then return { { message = _("No playlists yet.") } } end
        for __, pl in ipairs(list) do
            t[#t + 1] = { text = pl.name, sub = M.playlistLine(pl), icon = "list", chevron = true,
                callback = function() UI.playlist(plugin, pl) end,
                hold_callback = function() UI.contextMenu(plugin, "playlist", pl) end }
        end
        return t
    end)
end

--- A playlist: Play, and its songs when it's one of yours (Spotify lists no others'). A hold on
-- one of its songs also has Move up, Move down, Move to top, Move to bottom and Remove.
function UI.playlist(plugin, pl)
    local own = plugin:ownsPlaylist(pl.uri)
    songsPage(plugin, pl.name ~= "" and pl.name or _("Playlist"), function(done, force)
        if not own then return done({}) end
        plugin:list("playlist", pl, done, force)
    end, function(list)
        -- (each song knows its place, for the moves)
        for i, s in ipairs(list) do s.playlist, s.index, s.count = pl.uri, i, #list end
        return { { tiles = { { icon = "play", text = _("Play"), primary = true, fn = function()
            command(plugin, "play", { context = pl.uri }, T(_("Playing %1"), pl.name))
        end } }, cols = 2, h = 44 } }
    end, own and _("No songs.") or _("Spotify lists the songs of your own playlists only."))
end

--- A song's row: a tap plays it (in its album or playlist, when it has one), a hold shows
-- Play and Add to queue.
local function songRow(plugin, s, close)
    local function play() command(plugin, "play", { context = s.context, track = s.uri }, T(_("Playing %1"), s.title)) end
    return { text = s.title, sub = s.artist, icon = "music", callback = play,
        hold_callback = function() UI.songMenu(plugin, s, play) end }
end

--- Back to the first page (after something was started from a page some way in).
local function toMain()
    for k = #UI.pages, 2, -1 do UI.pages[k]:onClose() end
end

--- A page of songs with Select in the title bar (the list with ticks): rows are then ticked, and Add to
-- queue, Add to playlist and Like are for all the ticked ones. read(done, force) gives the
-- songs; head(list) the rows above them (Play…); empty: the message without any.
function songsPage(plugin, title, read, head, empty, close)
    local sel = { on = false, picked = {}, n = 0 }
    local function redo() UI.refreshAll() end
    local function leave()
        sel.on, sel.picked, sel.n = false, {}, 0
        redo()
    end
    return listPage(plugin, title, read, function(list)
        if #list == 0 then
            local none = head and head(list) or {}
            none[#none + 1] = { message = empty }
            return none
        end
        local t = {}
        if not sel.on then
            for __, it in ipairs(head and head(list) or {}) do t[#t + 1] = it end
            for __, s in ipairs(list) do t[#t + 1] = songRow(plugin, s, close) end
            return t
        end
        local function picked()
            local uris = {}
            for __, s in ipairs(list) do if sel.picked[s.uri] then uris[#uris + 1] = s.uri end end
            return uris
        end
        local function with(fn)
            return function()
                local uris = picked()
                if #uris == 0 then return KO.toast(_("Nothing selected")) end
                fn(uris)
            end
        end
        t[#t + 1] = { tiles = {
            { icon = "list", text = _("Add to queue"), fn = with(function(uris)
                command(plugin, "queue", { uris = uris }, #uris == 1 and _("Added to the queue") or T(_("%1 added to the queue"), #uris))
                leave()
            end) },
            { icon = "list-plus", text = _("Add to playlist"), fn = with(function(uris)
                UI.addTo(plugin, { uris = uris })
                leave()
            end) },
            { icon = "heart", text = _("Like"), fn = with(function(uris)
                command(plugin, "like", { uris = uris, on = true }, _("Added to Liked Songs"))
                leave()
            end) },
            { icon = "x", text = _("Done"), fn = leave },
        }, cols = 4, h = 44 }
        -- Select all, Select none, Invert selection: want(s) says whether a song is ticked after.
        local function set(want)
            local before = sel.picked
            sel.picked, sel.n = {}, 0
            for __, s in ipairs(list) do
                if want(before[s.uri] == true) and not sel.picked[s.uri] then sel.picked[s.uri], sel.n = true, sel.n + 1 end
            end
            redo()
        end
        t[#t + 1] = { chips = {
            { text = _("Select all"), fn = function() set(function() return true end) end },
            { text = _("Select none"), fn = function() set(function() return false end) end },
            { text = _("Invert selection"), fn = function() set(function(on) return not on end) end },
        } }
        t[#t + 1] = { band = sel.n == 1 and _("1 SELECTED") or T(_("%1 SELECTED"), sel.n) }
        for __, s in ipairs(list) do
            local on = sel.picked[s.uri] == true
            t[#t + 1] = { text = s.title, sub = s.artist, icon = on and "check" or "music", bold = on,
                right = on and _("Selected") or nil, callback = function()
                    sel.picked[s.uri] = not on or nil
                    sel.n = sel.n + (on and -1 or 1)
                    redo()
                end }
        end
        return t
    end, { { "list-checks", function()
        if sel.on then return leave() end
        sel.on = true
        redo()
    end } })
end

--- A whole album (all its songs) added to the queue or to a playlist. songs: its songs when
-- they're at hand (its page); read otherwise.
function UI.albumTo(plugin, a, where, songs)
    local function go(list)
        local uris = {}
        for __, s in ipairs(list) do uris[#uris + 1] = s.uri end
        if #uris == 0 then return KO.toast(_("No songs.")) end
        if where == "queue" then
            return command(plugin, "queue", { uris = uris }, T(_("%1 added to the queue"), a.name))
        end
        UI.addTo(plugin, { uris = uris })
    end
    if songs then return go(songs) end
    plugin:list("album", a, function(list, why)
        if not list then return KO.toast(M.whyText(why), 4) end
        go(list)
    end)
end

--- What can be done with an album or an artist (a hold on its row): Play, Open, and for an
-- album its artist and Add to library.
function UI.contextMenu(plugin, kind, x)
    local items = { { text = _("Play"), fn = function() command(plugin, "play", { context = x.uri }, T(_("Playing %1"), x.name)) end } }
    if kind == "playlist" then
        items[#items + 1] = { text = _("Open playlist"), fn = function() UI.playlist(plugin, x) end }
    elseif kind == "album" then
        items[#items + 1] = { text = _("Open album"), fn = function() UI.album(plugin, x) end }
        if x.artistUri and x.artistUri ~= "" then
            items[#items + 1] = { text = _("Open artist"), fn = function() UI.artist(plugin, { uri = x.artistUri, name = x.artistName }) end }
        end
        items[#items + 1] = { text = _("Add to queue"), fn = function() UI.albumTo(plugin, x, "queue") end }
        items[#items + 1] = { text = _("Add to playlist"), fn = function() UI.albumTo(plugin, x, "playlist") end }
        items[#items + 1] = { text = _("Add to library"), fn = function()
            command(plugin, "like", { uri = x.uri, on = true }, T(_("%1 added to your library"), x.name))
        end }
    else
        items[#items + 1] = { text = _("Open artist"), fn = function() UI.artist(plugin, x) end }
    end
    KO.list(x.name, items)
end

--- The song playing, as the lists' songs are: { uri, title, artist, album, albumUri, artistUri,
-- artistName, playlist (the playlist it plays from, when it's one of yours) }.
function UI.playingSong(plugin)
    local p = plugin:player()
    if not p then return nil end
    return { uri = p.uri, title = p.title, artist = p.artist, album = p.album, albumUri = p.albumUri,
        artistUri = p.artistUri, artistName = p.artistName, playing = true,
        playlist = plugin:ownsPlaylist(p.context) and p.context or nil }
end

--- A song liked (saved to Liked Songs) or not.
function UI.like(plugin, s, on)
    if not s then return end
    command(plugin, "like", { uri = s.uri, on = on }, on and _("Added to Liked Songs") or _("Removed from Liked Songs"))
end

--- What can be done with a song: Play (play: how, for one in a list), Add to queue, Like, Add
-- to playlist, Open album, Open artist; for the one playing from a playlist of yours, Remove
-- from this playlist.
function UI.songMenu(plugin, s, play)
    if not s then return end
    local items = {}
    if play then items[#items + 1] = { text = _("Play"), fn = play } end
    if not s.playing then
        items[#items + 1] = { text = _("Add to queue"), fn = function() command(plugin, "queue", { uri = s.uri }, _("Added to the queue")) end }
    end
    if s.uri:match("^spotify:track:") then
        local liked
        if s.playing then liked = plugin:liked() end
        items[#items + 1] = { text = liked and _("Remove from Liked Songs") or _("Like"), fn = function() UI.like(plugin, s, not liked) end }
        items[#items + 1] = { text = _("Add to playlist"), fn = function() UI.addTo(plugin, s) end }
    end
    if s.playlist and s.index and s.count and s.count > 1 then
        local function move(to, text)
            return function() command(plugin, "move", { playlist = s.playlist, from = s.index, to = to }, text) end
        end
        if s.index > 1 then
            items[#items + 1] = { text = _("Move up"), fn = move(s.index - 1, _("Moved up")) }
            items[#items + 1] = { text = _("Move to top"), fn = move(1, _("Moved to the top")) }
        end
        if s.index < s.count then
            items[#items + 1] = { text = _("Move down"), fn = move(s.index + 1, _("Moved down")) }
            items[#items + 1] = { text = _("Move to bottom"), fn = move(s.count, _("Moved to the bottom")) }
        end
    end
    if s.playlist then
        items[#items + 1] = { text = _("Remove from this playlist"), fn = function()
            command(plugin, "removefrom", { playlist = s.playlist, uri = s.uri })
            KO.undo(T(_("%1 removed"), s.title), function() command(plugin, "addto", { playlist = s.playlist, uri = s.uri }) end)
        end }
    end
    if s.albumUri and s.albumUri ~= "" then
        items[#items + 1] = { text = _("Open album"), fn = function() UI.album(plugin, { uri = s.albumUri, name = s.album }) end }
    end
    if s.artistUri and s.artistUri ~= "" then
        items[#items + 1] = { text = _("Open artist"), fn = function() UI.artist(plugin, { uri = s.artistUri, name = s.artistName }) end }
    end
    KO.list(s.title, items)
end

--- A song added to one of your playlists, picked from a page of them; Undo takes it out again.
function UI.addTo(plugin, s)
    if not s then return end
    listPage(plugin, _("Add to playlist"), function(done) plugin:ownPlaylists(done, true) end, function(list, close)
        if #list == 0 then return { { message = _("No playlists of your own yet.") } } end
        local t = {}
        for __, pl in ipairs(list) do
            t[#t + 1] = { text = pl.name, sub = M.playlistLine(pl), icon = "list-plus", callback = function()
                close()
                plugin:act("addto", { playlist = pl.uri, uri = s.uri, uris = s.uris }, function(ok, text)
                    if not ok then return KO.toast(text, 4) end
                    KO.undo(T(_("Added to %1"), pl.name), function()
                        command(plugin, "removefrom", { playlist = pl.uri, uri = s.uri, uris = s.uris })
                    end)
                end)
            end }
        end
        return t
    end)
end

--- An album: Play, and its songs. a: { uri, name, artistUri, artistName }.
function UI.album(plugin, a)
    songsPage(plugin, a.name ~= "" and a.name or _("Album"), function(done, force) plugin:list("album", a, done, force) end, function(list)
        local tiles = { { icon = "play", text = _("Play"), primary = true, fn = function()
            command(plugin, "play", { context = a.uri }, T(_("Playing %1"), a.name))
        end } }
        if a.artistUri and a.artistUri ~= "" then
            tiles[#tiles + 1] = { icon = "user", text = a.artistName, fn = function() UI.artist(plugin, { uri = a.artistUri, name = a.artistName }) end }
        end
        -- (the whole album: all its songs)
        tiles[#tiles + 1] = { icon = "list", text = _("Add to queue"), fn = function() UI.albumTo(plugin, a, "queue", list) end }
        tiles[#tiles + 1] = { icon = "list-plus", text = _("Add to playlist"), fn = function() UI.albumTo(plugin, a, "playlist", list) end }
        return { { tiles = tiles, cols = 2, h = 44 } }
    end, _("No songs."), toMain)
end

--- An artist: Play, and their albums. a: { uri, name }.
function UI.artist(plugin, a)
    listPage(plugin, a.name ~= "" and a.name or _("Artist"), function(done, force) plugin:list("artist", a, done, force) end, function(list)
        local t = { { tiles = { { icon = "play", text = _("Play"), primary = true, fn = function()
            command(plugin, "play", { context = a.uri }, T(_("Playing %1"), a.name))
        end } }, cols = 2, h = 44 } }
        if #list > 0 then t[#t + 1] = { band = _("ALBUMS") } end
        for __, x in ipairs(list) do
            local album = { uri = x.uri, name = x.name, artistUri = a.uri, artistName = a.name }
            t[#t + 1] = { text = x.name, sub = x.sub ~= "" and x.sub or nil, icon = "music", chevron = true,
                callback = function() UI.album(plugin, album) end,
                hold_callback = function() UI.contextMenu(plugin, "album", album) end }
        end
        return t
    end)
end

--- Liked Songs: Play all, and the songs (the newest 100).
function UI.likedSongs(plugin)
    songsPage(plugin, _("Liked Songs"), function(done, force) plugin:list("liked", nil, done, force) end, function()
        local all = M.likedContext(plugin:me())
        if not all then return {} end
        return { { tiles = { { icon = "play", text = _("Play"), primary = true, fn = function()
            command(plugin, "play", { context = all }, T(_("Playing %1"), _("Liked Songs")))
        end } }, cols = 2, h = 44 } }
    end, _("No liked songs yet."), toMain)
end

--- The library: Liked Songs, your playlists, your saved albums and the artists you follow, with
-- All, Playlists, Albums and Artists at the top to show one kind only.
function UI.library(plugin)
    local show = "all"
    local function pick(kind)
        return function()
            if show == kind then return end
            show = kind
            UI.refreshAll()
        end
    end
    -- (the playlists are read with the page, when they aren't known yet)
    if not plugin:knownPlaylists() then plugin:playlists(function() UI.refreshAll() end, false, true) end
    listPage(plugin, _("Library"), function(done, force)
        if force then plugin:playlists(function() end, true, true) end
        plugin:list("library", nil, done, force)
    end, function(lib)
        local playlists = plugin:knownPlaylists() or {}
        local t = { { chips = {
            { text = _("All"), on = show == "all", fn = pick("all") },
            { text = _("Playlists"), on = show == "playlists", fn = pick("playlists") },
            { text = _("Albums"), on = show == "albums", fn = pick("albums") },
            { text = _("Artists"), on = show == "artists", fn = pick("artists") },
        } } }
        local function shown(kind) return show == "all" or show == kind end
        if show == "all" then
            t[#t + 1] = { text = _("Liked Songs"), icon = "heart", chevron = true, callback = function() UI.likedSongs(plugin) end }
        end
        if shown("playlists") and #playlists > 0 then
            t[#t + 1] = { band = _("PLAYLISTS"), right = tostring(#playlists) }
            for __, pl in ipairs(playlists) do
                t[#t + 1] = { text = pl.name, sub = M.playlistLine(pl), icon = "list", chevron = true,
                    callback = function() UI.playlist(plugin, pl) end,
                    hold_callback = function() UI.contextMenu(plugin, "playlist", pl) end }
            end
        end
        if shown("albums") and #lib.albums > 0 then
            t[#t + 1] = { band = _("ALBUMS"), right = tostring(#lib.albums) }
            for __, x in ipairs(lib.albums) do
                t[#t + 1] = { text = x.name, sub = x.sub ~= "" and x.sub or nil, icon = "music", chevron = true,
                    callback = function() UI.album(plugin, x) end,
                    hold_callback = function() UI.contextMenu(plugin, "album", x) end }
            end
        end
        if shown("artists") and #lib.artists > 0 then
            t[#t + 1] = { band = _("ARTISTS"), right = tostring(#lib.artists) }
            for __, x in ipairs(lib.artists) do
                t[#t + 1] = { text = x.name, icon = "user", chevron = true, callback = function() UI.artist(plugin, x) end,
                    hold_callback = function() UI.contextMenu(plugin, "artist", x) end }
            end
        end
        if show ~= "all" and #t == 1 then
            t[#t + 1] = { message = show == "playlists" and _("No playlists yet.") or (show == "albums" and _("No albums yet.") or _("No artists yet.")) }
        end
        return t
    end)
end

--- The queue: what's playing and what comes next (read each time it opens).
function UI.queue(plugin)
    listPage(plugin, _("Queue"), function(done) plugin:list("queue", nil, done, true) end, function(q)
        local t = {}
        if q.now then
            t[#t + 1] = { band = _("NOW PLAYING") }
            t[#t + 1] = { text = q.now.title, sub = q.now.artist, icon = "music", bold = true,
                hold_callback = function() UI.songMenu(plugin, q.now) end }
        end
        if #q.next == 0 then
            t[#t + 1] = { message = _("Nothing comes next.") }
            return t
        end
        t[#t + 1] = { band = _("NEXT"), right = tostring(#q.next) }
        for __, s in ipairs(q.next) do
            t[#t + 1] = { text = s.title, sub = s.artist, icon = "music", hold_callback = function() UI.songMenu(plugin, s) end }
        end
        return t
    end)
end

function UI.recent(plugin)
    songsPage(plugin, _("Recent"), function(done, force) plugin:recent(done, force, true) end, nil,
        _("Nothing played lately."), function() for k = #UI.pages, 2, -1 do UI.pages[k]:onClose() end end)
end

function UI.searchItems(plugin, close)
    local S = plugin:searchState()
    if S.reading then return { { message = _("Searching…") } } end
    if S.why then return { { message = M.whyText(S.why) } } end
    local r = S.results
    if not r then return { { message = _("Search for a song, album, playlist or artist.") } } end
    if r.count == 0 then return { { message = T(_("Nothing found for “%1”."), S.q) } } end
    local t = {}
    if #r.tracks > 0 then
        t[#t + 1] = { band = _("SONGS") }
        for __, s in ipairs(r.tracks) do t[#t + 1] = songRow(plugin, s, close) end
    end
    for __, kind in ipairs({ { "albums", _("ALBUMS"), "music" }, { "playlists", _("PLAYLISTS"), "list" }, { "artists", _("ARTISTS"), "user" } }) do
        local found = r[kind[1]]
        if #found > 0 then
            t[#t + 1] = { band = kind[2] }
            for __, x in ipairs(found) do
                t[#t + 1] = { text = x.name, sub = x.sub ~= "" and x.sub or nil, icon = kind[3],
                    chevron = true,
                    hold_callback = function() UI.contextMenu(plugin, kind[1]:sub(1, -2), x) end,
                    callback = function()
                        if kind[1] == "albums" then return UI.album(plugin, x) end
                        if kind[1] == "artists" then return UI.artist(plugin, x) end
                        UI.playlist(plugin, x)
                    end }
            end
        end
    end
    return t
end

--- What to search for; then the results' page (the one open, when it is).
function UI.askSearch(plugin)
    ask(_("Search Spotify"), plugin:searchState().q, function(v)
        local q = M.trim(v)
        if q == "" then return end
        local open
        for __, p in ipairs(UI.pages) do if p.searchPage then open = p end end
        if not open then
            local p
            p = page(_("Search"), function() return UI.withControls(plugin, UI.searchItems(plugin, function() if p then p:onClose() end end)) end,
                { buttons = function() return UI.remote(plugin, { { "search", function() UI.askSearch(plugin) end } }) end,
                  on_refresh = function() plugin:search(plugin:searchState().q, nil, true) end })
            p.searchPage = true
        end
        plugin:search(q, function() UI.refreshAll() end, true)
        UI.refreshAll()
    end, { ok = _("Search"), okIcon = "search" })
end

-- ------------------------------------------------------------------ setting up

--- The Client ID, typed or pasted: then(id) once it's saved.
local function askClientId(plugin, after)
    ask(_("Client ID"), "", function(v)
        local id = M.cleanClientId(v)
        if not id then return KO.toast(_("A Client ID is 32 letters and digits."), 4) end
        plugin:setClientId(id)
        if after then after() end
    end, { ok = _("Next"), okIcon = "chevron-right",
        description = _("From your app in Spotify's developer dashboard. The Spotify Remote tab of the Kindle's web page takes it too.") })
end

--- The address the browser ended on, pasted or typed; then the sign-in is finished.
local function askAddress(plugin)
    ask(_("Address after signing in"), "", function(v)
        plugin:finishSignIn(v, function(ok, text)
            if not ok then return KO.message(text, _("Not signed in")) end
            KO.toast(_("Signed in to Spotify"))
            if #UI.pages == 0 then UI.show(plugin) else UI.refreshAll() end
        end)
    end, { ok = _("Sign in"), okIcon = "log-in", description = _("It starts with http://127.0.0.1:8888/callback") })
end

--- Signing in: Spotify's sign-in page opens in a browser on a phone or computer (there's
-- none here), which ends on an address that holds the code; that address comes back here.
function UI.signIn(plugin)
    if not plugin:clientId() then return UI.setup(plugin) end
    local url, why = plugin:signInUrl(true)
    if not url then return KO.toast(M.whyText(why), 4) end
    local text = _([[Spotify's sign-in needs a browser, so it's done on a phone or computer.

On the Kindle's web page, the Spotify Remote tab does it for you: Sign in there, and paste the address you end on.

Or here:
1. Tap QR code and scan it with a phone.
2. Sign in to Spotify and agree.
3. The browser then shows an error for an address that starts with http://127.0.0.1:8888. That's expected: copy that whole address.
4. Tap Enter address and put it in.]])
    local function qr()
        if PS().showQR then
            PS().showQR{ text = url, caption = _("Scan to sign in to Spotify"), showText = false, onClose = function() UI.signIn(plugin) end }
        else
            KO.message(url, _("Open this address"))
        end
    end
    local read = KO.read()
    if read then
        return read{ title = _("Sign in to Spotify"), text = text, buttons = {
            { icon = "x", text = _("Cancel") },
            { icon = "qr-code", text = _("QR code"), fn = qr },
            { icon = "pencil", text = _("Enter address"), primary = true, fn = function() askAddress(plugin) end },
        } }
    end
    KO.list(_("Sign in to Spotify"), {
        { text = _("QR code"), fn = qr },
        { text = _("Enter address"), fn = function() askAddress(plugin) end },
    })
end

--- Setting up: the Client ID, then the sign-in.
function UI.setup(plugin)
    if plugin:clientId() then return UI.signIn(plugin) end
    askClientId(plugin, function() UI.signIn(plugin) end)
end

-- ------------------------------------------------------------------ settings

--- The settings rows: DISPLAY first, the account last.
function UI.settingsItems(plugin, redo)
    local id = plugin:clientId()
    local t = {}
    t[#t + 1] = { band = _("DISPLAY") }
    t[#t + 1] = { toggle = plugin:showArt(), text = _("Album art"), callback = function()
        G_reader_settings:saveSetting("spotify_art", not plugin:showArt())
        redo()
        plugin:fetch()
    end }
    t[#t + 1] = { setting = true, text = _("Read every"), value = M.intervalName(plugin:interval()),
        hint = _("While Spotify Remote is open."),
        callback = function()
            local options = {}
            for __, s in ipairs(M.INTERVALS) do table.insert(options, { label = M.intervalName(s), value = s }) end
            KO.choose(_("Read every"), options, plugin:interval(), function(s)
                G_reader_settings:saveSetting("spotify_interval", s)
                redo()
            end)
        end }
    t[#t + 1] = { setting = true, text = _("Full screen: read every"),
        value = plugin:playerEvery() == 0 and _("Same as the app") or M.intervalName(plugin:playerInterval()),
        callback = function()
            local options = { { label = _("Same as the app"), value = 0 } }
            for __, s in ipairs(M.INTERVALS) do table.insert(options, { label = M.intervalName(s), value = s }) end
            KO.choose(_("Full screen: read every"), options, plugin:playerEvery(), function(s)
                G_reader_settings:saveSetting("spotify_player_interval", s)
                redo()
            end)
        end }
    t[#t + 1] = { band = _("BUTTONS") }
    for __, b in ipairs(M.BUTTONS) do
        t[#t + 1] = { setting = true, text = b.name, value = M.actionName(plugin:button(b.key)), callback = function()
            local options = {}
            for __, a in ipairs(M.BUTTON_ACTIONS) do table.insert(options, { label = a.name, value = a.id }) end
            KO.choose(b.name, options, plugin:button(b.key), function(id)
                G_reader_settings:saveSetting("spotify_button_" .. b.key, id)
                redo()
                UI.refreshAll()
            end)
        end }
    end
    t[#t + 1] = { toggle = plugin:staysAfterPlay(), text = _("Stay on the list after Play"), callback = function()
        G_reader_settings:saveSetting("spotify_stay", not plugin:staysAfterPlay())
        redo()
    end }
    t[#t + 1] = { band = _("PLAYBACK") }
    t[#t + 1] = { setting = true, text = _("Volume step"), value = T(_("%1%"), plugin:volumeBy()), callback = function()
        local options = {}
        for __, s in ipairs(M.VOLUME_STEPS) do table.insert(options, { label = T(_("%1%"), s), value = s }) end
        KO.choose(_("Volume step"), options, plugin:volumeBy(), function(s)
            G_reader_settings:saveSetting("spotify_volume_step", s)
            redo()
            UI.refreshAll()
        end)
    end }
    t[#t + 1] = { band = _("ACCOUNT") }
    t[#t + 1] = { setting = true, text = _("Client ID"), value = id and M.masked(id) or _("Not set"), callback = function()
        askClientId(plugin, function()
            redo()
            UI.signIn(plugin)
        end)
    end }
    if id then
        t[#t + 1] = { setting = true, text = _("Redirect URI"), value = M.REDIRECT }
    end
    if plugin:signedIn() then
        if PS().showConnectionTest then
            t[#t + 1] = { setting = true, text = _("Test connection"), callback = function() PS().showConnectionTest("spotify") end }
        end
        t[#t + 1] = { setting = true, text = _("Sign out"), callback = function()
            local tokens = plugin:signOut()
            redo()
            KO.undo(_("Signed out"), function()
                plugin:signInAgain(tokens)
                redo()
            end)
        end }
    elseif id then
        t[#t + 1] = { setting = true, text = _("Sign in"), callback = function() UI.signIn(plugin) end }
    else
        t[#t + 1] = { setting = true, text = _("Set up"), callback = function() UI.setup(plugin) end }
    end
    return t
end

function UI.settings(plugin)
    local p
    local function redo()
        p.item_table = UI.settingsItems(plugin, redo)
        p:redraw()
    end
    p = page(_("Spotify Remote settings"), function() return UI.settingsItems(plugin, function() redo() end) end)
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
    local text = _([[A remote for Spotify. The music plays on a Spotify device (a phone, a computer, a speaker), not on the Kindle.

The first page shows what's playing, with Shuffle, Previous, Play or Pause, Next and Repeat, and the volume. Tap along the song's bar to jump to that part.

Devices lists the devices that are on. Tap one to move the music there. A greyed-out one can't be controlled from here.

Playlists, Library, Recent, Search and DJ start something. Starting it leaves the page open: the title bar there has play or pause, and the music note, which goes back to the player. Tap play or pause there for the player's buttons above the list (hold it to play or pause); hold the music note for the full screen.

Tap the song on the first page, or hold a song, album or artist in a list, for more: Add to queue, Like, Add to playlist, Open album, Open artist. In a list of songs, the list with ticks in the title bar selects several at once.

Tap the album's picture for the full screen.

Spotify is read only while this app is open. Nothing runs in the background.]])
    -- (the requirements and Spotify's limits first: the same list as on the web page)
    text = M.needsText() .. "\n\n" .. text
    if read then
        return read{ title = _("Spotify Remote"), text = text, buttons = { { icon = "check", text = _("Done"), primary = true } } }
    end
    KO.message(text, _("Spotify Remote"))
end

return UI
