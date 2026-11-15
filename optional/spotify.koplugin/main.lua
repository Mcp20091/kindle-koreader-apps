--[[--
Spotify: a remote control for Spotify on the Kindle, over Spotify's Web API.
What's playing (the song, its artist and album, the album's picture, how far
it is), play and pause, next and previous, volume, shuffle and repeat; the
devices that are on, to move playback to one; and something to start: your
playlists, recently played songs, and a search. Nothing plays on the Kindle:
the music plays on a Spotify Connect device (a phone, a computer, a speaker).

Spotify is read only while the app is open (every few seconds, and when a
song ends); nothing is read once it closes, and nothing runs in the
background.

Also: the launcher's tile line (appsLine, event ShowSpotify), its settings,
search, setup step, quick buttons, connection test and backup, gestures,
and calls for the web page (webState, webAct).

@module koplugin.spotify
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local M = require("spmodel")

-- Kept while KOReader runs (each book and the library get a new plugin).
local state = {
    player = nil,      -- what's playing as last read (spmodel.player); false: nothing anywhere
    time = 0,          -- when
    tried = 0,         -- when it was last asked (answered or not)
    why = nil,         -- why the last read failed (nil: it worked)
    reading = false,
    waiting = {},
    devices = nil,     -- the devices that are on (spmodel.devices), and when they were read
    devicesTime = 0,
    line = nil,        -- the launcher's line as last shown
    signedIn = nil,    -- whether there are tokens (nil: not looked yet)
    scope = nil,       -- what the sign-in covers (the tokens' scope)
    liked = {},        -- { uri, on }: whether the song playing is in Liked Songs (on nil: not known)
    lists = {},        -- lists read on request, by key: { items, time } (Spotify:list)
    signIn = nil,      -- a sign-in under way: { verifier, state, url }
    playlists = nil, playlistsTime = 0,
    recent = nil, recentTime = 0,
    search = { q = "", results = nil, why = nil, reading = false },
    queue = {}, running = false,   -- the requests waiting, one at a time
}

local Spotify = WidgetContainer:extend{
    name = "spotify",
    is_doc_only = false,
}

-- The Spotify plugin of the open library or book.
local function current()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    return ui and ui.spotify
end
Spotify.current = current

-- The tokens, in a file of their own: a child process keeps a refreshed token there, and the
-- next request reads it from there (nothing of it stays in memory here).
local function tokenFile() return DataStorage:getSettingsDir() .. "/spotify_tokens.lua" end
local Tokens = {
    get = function()
        if lfs.attributes(tokenFile(), "mode") ~= "file" then return nil end
        local t = LuaSettings:open(tokenFile()):readSetting("tokens")
        return type(t) == "table" and t or nil
    end,
    set = function(t)
        local s = LuaSettings:open(tokenFile())
        if t then s:saveSetting("tokens", t) else s:delSetting("tokens") end
        s:flush()
    end,
}

function Spotify:init()
    self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/spotify.lua")
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    require("spko").flashOnUncover()
    require("spui").plugin = self
    self:shareWithApps()
end

function Spotify:onDispatcherRegisterActions()
    Dispatcher:registerAction("spotify_show", { category = "none", event = "ShowSpotify", title = _("Spotify Remote"), general = true })
    Dispatcher:registerAction("spotify_toggle", { category = "none", event = "SpotifyCommand", arg = "toggle", title = _("Spotify Remote: play or pause"), general = true })
    Dispatcher:registerAction("spotify_next", { category = "none", event = "SpotifyCommand", arg = "next", title = _("Spotify Remote: next"), general = true })
    Dispatcher:registerAction("spotify_previous", { category = "none", event = "SpotifyCommand", arg = "previous", title = _("Spotify Remote: previous"), general = true, separator = true })
end

function Spotify:addToMainMenu(menu_items)
    menu_items.spotify = {
        text = _("Spotify Remote"),
        sorting_hint = "tools",
        callback = function() self:show() end,
    }
end

function Spotify:onShowSpotify()
    self:show()
    return true
end

--- A gesture's command (play or pause, next, previous): done without opening the app.
function Spotify:onSpotifyCommand(name)
    self:quickCommand(name)
    return true
end

function Spotify:show(page)
    -- App lock (the launcher's): its passcode first, when this app is locked.
    local lock = require("pluginshare").lock
    if lock and lock.ask("spotify", function() self:show(page) end) then return end
    return require("spui").show(self, page)
end

--- A command from a gesture or a quick button: a short message says what happened or why not.
function Spotify:quickCommand(name, done)
    local ko = require("spko")
    local function run()
        self:act(name, {}, function(ok, text, why)
            if not ok then
                if why == "choose" then
                    self:show()
                    require("spui").devices(self)
                else
                    ko.toast(text, 4)
                end
            end
            if done then done() end
        end)
    end
    local lock = require("pluginshare").lock
    if lock and lock.run then return lock.run("spotify", run) end
    run()
end

-- ------------------------------------------------------------------ the account's settings

function Spotify:clientId()
    local id = self.store:readSetting("client_id")
    return type(id) == "string" and id ~= "" and id or nil
end

--- The Client ID changed: saved, the sign-in under it forgotten.
function Spotify:setClientId(id)
    if id == self:clientId() then return end
    if id then self.store:saveSetting("client_id", id) else self.store:delSetting("client_id") end
    self.store:flush()
    self:signOut()
end

function Spotify:signedIn()
    if state.signedIn == nil then
        local t = Tokens.get()
        state.signedIn = t ~= nil and M.str(t.refresh_token) ~= ""
        state.scope = t and t.scope or nil
    end
    return state.signedIn
end

--- Whether the sign-in covers everything the app does now (one made before a feature was added
-- doesn't: signing in again does).
function Spotify:scopesOk()
    return not self:signedIn() or M.scopesCover(state.scope)
end

--- Who signed in (their Spotify id, once read): whose playlists can be changed.
function Spotify:me() return self.store:readSetting("user_id") end

--- Whether the song playing is in Liked Songs (nil: not known).
function Spotify:liked()
    local p = state.player
    if p and p.uri ~= "" and state.liked.uri == p.uri then return state.liked.on end
end

function Spotify:configured()
    return self:clientId() ~= nil and self:signedIn()
end

--- How often the open app reads Spotify (seconds, 5 to 60).
function Spotify:interval()
    return M.interval(G_reader_settings:readSetting("spotify_interval"))
end

--- How often the full screen is read: its own setting, or the same as the app (0).
function Spotify:playerEvery()
    return math.max(0, math.floor(tonumber(G_reader_settings:readSetting("spotify_player_interval")) or 0))
end

function Spotify:playerInterval()
    return M.playerInterval(self:playerEvery(), self:interval())
end

--- What a button does (key: spmodel.BUTTONS'; the action's id).
function Spotify:button(key)
    return M.buttonAction(key, G_reader_settings:readSetting("spotify_button_" .. key))
end

--- After something is started from a list: the list stays (true, to start with), or the first
-- page comes back.
function Spotify:staysAfterPlay()
    return G_reader_settings:nilOrTrue("spotify_stay")
end

function Spotify:volumeBy()
    local v = tonumber(G_reader_settings:readSetting("spotify_volume_step")) or M.VOLUME_STEP
    return math.max(1, math.min(25, v))
end

function Spotify:showArt()
    return G_reader_settings:nilOrTrue("spotify_art")
end

function Spotify:whyText(why) return M.whyText(why) end

-- ------------------------------------------------------------------ requests, one at a time

function Spotify:api()
    return require("spapi").new{ clientId = self:clientId(), tokens = Tokens }
end

--- The sign-in is no longer good: a notification says so until it's signed in again.
function Spotify:noteWhy(why)
    if why ~= "signin" then return end
    local PS = require("pluginshare")
    if PS.notify then
        pcall(PS.notify, { app = "spotify", key = "spotify:signin", text = M.whyText("signin"), route = "settings" })
    end
end

function Spotify:pump()
    if state.running or #state.queue == 0 then return end
    state.running = true
    local job = table.remove(state.queue, 1)
    local api = self:api()
    require("spbg").run(function()
        local r, why = job.fn(api)
        if r == nil then return { why = tostring(why or "no answer") } end
        return { r = r }
    end, function(res, why)
        state.running = false
        local r = res and res.r
        if r == nil then
            why = (res and res.why) or why or "no answer"
            self:noteWhy(why)
        else
            why = nil
        end
        local ok, err = pcall(job.done, r, why)
        if not ok then logger.warn("Spotify:", err) end
        self:pump()
    end, job.opts)
end

--- fn(api) run in a child process, after the ones before it; then done(result) or
-- done(nil, why). opts: { limit, text } (spbg.run's).
function Spotify:job(fn, done, opts)
    table.insert(state.queue, { fn = fn, done = done, opts = opts or { limit = 30 } })
    self:pump()
end

--- What can't be asked right now: "notset", "signedout" or "offline" (nil: go ahead).
function Spotify:blocked()
    if not self:clientId() then return "notset" end
    if not self:signedIn() then return "signedout" end
    if not NetworkMgr:isConnected() then return "offline" end
end

-- ------------------------------------------------------------------ reading Spotify

local function artDir() return DataStorage:getDataDir() .. "/cache/spotify" end

--- The album's picture of what's playing, when it's been fetched (a file), else nil.
function Spotify:artPath(p)
    p = p or state.player
    if not p or p.art == "" or not self:showArt() then return nil end
    local name = M.artFile(p.art)
    local path = name and (artDir() .. "/" .. name)
    if path and lfs.attributes(path, "mode") == "file" then return path end
end

-- The pictures kept: the newest 20.
local function pruneArt()
    local dir = artDir()
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local files = {}
    for name in lfs.dir(dir) do
        if name:match("%.jpg$") then
            files[#files + 1] = { path = dir .. "/" .. name, time = lfs.attributes(dir .. "/" .. name, "modification") or 0 }
        end
    end
    if #files <= 20 then return end
    table.sort(files, function(a, b) return a.time > b.time end)
    for i = 21, #files do os.remove(files[i].path) end
end
Spotify.pruneArt = pruneArt

--- Read what's playing (and the devices, when asked or not read for a minute) in the
-- background; done(player) when it's in (false: nothing playing; nil and why when it didn't
-- answer). One read at a time. opts: { devices = true }.
function Spotify:fetch(done, opts)
    opts = opts or {}
    if done then table.insert(state.waiting, done) end
    if state.reading then
        if opts.devices then state.wantDevices = true end
        return
    end
    local function finish(p, why)
        local waiting = state.waiting
        state.waiting = {}
        for __, f in ipairs(waiting) do pcall(f, p, why) end
    end
    local blocked = self:blocked()
    if blocked then
        if blocked == "offline" then state.why = "offline" end
        self:changed()
        return finish(nil, blocked)
    end
    state.reading, state.tried = true, os.time()
    local withDevices = opts.devices or state.wantDevices or state.devices == nil or os.time() - state.devicesTime > 60
    state.wantDevices = nil
    local art = self:showArt() and artDir() or nil
    local likedUri, needMe = state.liked.uri, not self:me()
    self:job(function(api)
        local r, why = api:read(withDevices)
        if not r then return nil, why end
        -- (whether the song is in Liked Songs, once per song; who signed in, once)
        local uri = type(r.player) == "table" and type(r.player.item) == "table" and r.player.item.uri
        if type(uri) == "string" and uri ~= likedUri and uri:match("^spotify:track:") then
            r.liked = { uri = uri, on = api:liked(uri) }
        end
        if needMe then
            local me = api:me()
            if type(me) == "table" and type(me.id) == "string" then r.me = me.id end
        end
        -- (the album's picture, once per album: about 20 KB)
        local p = art and r.player and M.player(r.player, 0)
        local name = p and p.art ~= "" and M.artFile(p.art)
        if name and lfs.attributes(art .. "/" .. name, "mode") ~= "file" then
            require("util").makePath(art)
            api:art(p.art, art .. "/" .. name)
        end
        return r
    end, function(r, why)
        state.reading = false
        if r then
            local now = os.time()
            state.player = r.player and M.player(r.player, now) or false
            state.time, state.why = now, nil
            if r.liked then state.liked = r.liked end
            if r.me then
                self.store:saveSetting("user_id", r.me)
                self.store:flush()
            end
            if r.devices then
                state.devices, state.devicesTime = M.devices(r.devices), now
                -- (remembered: Spotify lists a device only while it's connected, so an idle
                -- speaker drops off; Devices shows it under Seen before, to try it anyway)
                local seen, changed = M.noteSeen(self.store:readSetting("seen"), state.devices, now)
                if changed then
                    self.store:saveSetting("seen", seen)
                    self.store:flush()
                end
            end
            -- (the device used last: where Play starts when nothing is active)
            local d = state.player and state.player.device
            if d and d.usable and d.id ~= self.store:readSetting("device") then
                self.store:saveSetting("device", d.id)
                self.store:saveSetting("device_name", d.name)
                self.store:flush()
            end
            self:changed()
            return finish(state.player)
        end
        state.why = why
        logger.info("Spotify: no answer:", why)
        self:changed()
        finish(nil, why)
    end, { limit = 25 })
end

--- The devices seen before that aren't on now ({ { id, name, type } }), and one of them forgotten.
function Spotify:seenDevices()
    return M.seenList(self.store:readSetting("seen"), state.devices)
end

function Spotify:forgetDevice(id)
    local seen = self.store:readSetting("seen")
    if type(seen) ~= "table" or not seen[id] then return end
    local old = seen[id]
    seen[id] = nil
    self.store:saveSetting("seen", seen)
    self.store:flush()
    self:changed()
    return old
end

function Spotify:rememberDevice(id, entry)
    local seen = self.store:readSetting("seen")
    if type(seen) ~= "table" then seen = {} end
    seen[id] = entry
    self.store:saveSetting("seen", seen)
    self.store:flush()
    self:changed()
end

function Spotify:player() return state.player end
function Spotify:devices() return state.devices end
function Spotify:readTime() return state.time end
function Spotify:lastWhy() return state.why end
function Spotify:reading() return state.reading end

--- Redraw what shows Spotify: the app's pages, or the launcher when its line changed.
function Spotify:changed()
    local UI = require("spui")
    if #UI.pages > 0 then UI.refreshAll() end
    local line = self:appsLine()
    if line == state.line then return end
    state.line = line
    local apps = self.ui and self.ui.apps
    if apps and apps.changed then pcall(apps.changed, apps) end
end

--- The launcher tile's line, from memory (the tile never asks Spotify): "Song · Artist".
function Spotify:appsLine()
    return M.appsLine(state.player, os.time(), self:configured())
end

-- ------------------------------------------------------------------ commands

-- What each command does in the child, and the change it makes to what was read, at once
-- (the next read confirms it).
local ACTIONS = {
    toggle = { run = function(api, a)
            if a.pause then return api:pause() end
            return api:startAnywhere(nil, a.device, a.preferred)
        end,
        apply = function(p, a, now)
            p.progress, p.at = M.progressNow(p, now), now
            p.playing = not a.pause
        end },
    play = { run = function(api, a)
            local body = a.context and { context_uri = a.context, offset = a.track and { uri = a.track } or nil }
                or { uris = { a.track } }
            local ok, why = api:startAnywhere(body, a.device, a.preferred)
            -- (a song that's no longer in its album or playlist: the song alone)
            if not ok and a.context and a.track and why ~= "choose" and why ~= "nodevice" and why ~= "premium"
                and why ~= "signin" and why ~= "signedout" then
                return api:startAnywhere({ uris = { a.track } }, a.device, a.preferred)
            end
            return ok, why
        end },
    next = { run = function(api) return api:next() end },
    previous = { run = function(api) return api:previous() end },
    seek = { run = function(api, a) return api:seek(a.ms) end,
        apply = function(p, a, now) p.progress, p.at = a.ms, now end },
    volume = { run = function(api, a) return api:volume(a.percent) end,
        apply = function(p, a) if p.device then p.device.volume = a.percent end end },
    shuffle = { run = function(api, a) return api:shuffle(a.on) end,
        apply = function(p, a) p.shuffle = a.on end },
    ["repeat"] = { run = function(api, a) return api:setRepeat(a.mode) end,
        apply = function(p, a) p["repeat"] = a.mode end },
    -- (the music goes on there when it was playing; a device picked while nothing plays only
    -- becomes the one Play starts on: it doesn't start by itself)
    transfer = { run = function(api, a) return api:transfer(a.device, a.play) end },
    -- (several songs: uris in place of uri; the queue takes them one at a time)
    queue = { run = function(api, a)
        for __, uri in ipairs(a.uris or { a.uri }) do
            local ok, why = api:queue(uri)
            if not ok then return nil, why end
        end
        return true
    end },
    -- (note: the change to what's known besides what's playing, at once; undo: when it failed)
    like = { run = function(api, a) return api:like(a.uris or a.uri, a.on) end,
        note = function(a) if state.liked.uri == a.uri then state.liked.on = a.on end end,
        undo = function(a) if state.liked.uri == a.uri then state.liked.on = not a.on end end },
    addto = { run = function(api, a) return api:addToPlaylist(M.id(a.playlist), a.uris or a.uri) end },
    removefrom = { run = function(api, a) return api:removeFromPlaylist(M.id(a.playlist), a.uris or a.uri) end },
    -- (a song moved in a playlist: from and to, counted from 1; moved in the list at hand at once)
    move = { run = function(api, a) return api:reorder(M.id(a.playlist), a.from, a.to) end,
        note = function(a)
            local have = state.lists["playlist:" .. a.playlist]
            if have then M.moveInList(have.items, a.from, a.to) end
        end,
        undo = function(a) state.lists["playlist:" .. a.playlist] = nil end },
}
Spotify.ACTIONS = ACTIONS

--- Do a command in the background; then done(ok, text, why) (text: why it failed, in plain
-- words; why "choose": several devices are on and none is playing, so one must be picked,
-- then the command sent again with args.device) and Spotify read again.
-- args: toggle {}; play { context (an album's, playlist's or artist's URI), track (a song's
-- URI) }; seek { ms }; volume { percent }; shuffle { on }; repeat { mode }; transfer { device };
-- queue { uri }; any that starts playing: { device } (an id) to start it there.
function Spotify:act(name, args, done, opts)
    local a = ACTIONS[name]
    args = args or {}
    if not a then return done and done(false, "Unknown command") end
    local blocked = self:blocked()
    if blocked then return done and done(false, M.whyText(blocked), blocked) end
    local p = state.player
    if name == "toggle" then args.pause = p and p.playing or false end
    if name == "transfer" then
        args.play = p and p.playing or false
        -- (and it's the device used last from here on)
        local d = M.findDevice(state.devices, args.device) or M.findDevice(self:seenDevices(), args.device)
        self.store:saveSetting("device", args.device)
        if d then self.store:saveSetting("device_name", d.name) end
        self.store:flush()
    end
    args.preferred = self.store:readSetting("device")
    if a.note then
        a.note(args)
        self:changed()
    end
    if p and a.apply then
        a.apply(p, args, os.time())
        self:changed()
    end
    self:job(function(api)
        local ok, why = a.run(api, args)
        if not ok then return nil, why or "refused" end
        return true
    end, function(ok, why)
        local text
        if not ok then
            logger.info("Spotify:", name, why)
            text = M.whyText(why)
            if a.undo then
                a.undo(args)
                self:changed()
            end
        end
        -- (what a list showed is no longer so)
        if ok and name == "like" then state.lists["liked:"] = nil end
        if ok and (name == "addto" or name == "removefrom") then state.lists["playlist:" .. M.str(args.playlist)] = nil end
        -- (read again: confirms the change, or puts back what it couldn't do; Spotify takes
        -- a moment to say so)
        UIManager:scheduleIn(ok and 1 or 0, function() self:fetch(nil, { devices = name == "transfer" or not ok }) end)
        if done then done(ok == true, text, why) end
    end, { limit = 25, text = opts and opts.text })
end

--- The volume, set a moment after the last tap (several taps make one request).
function Spotify:setVolume(percent, done)
    percent = math.max(0, math.min(100, math.floor(percent)))
    local p = state.player
    if p and p.device then
        p.device.volume = percent
        self:changed()
    end
    if state.volumeTask then UIManager:unschedule(state.volumeTask) end
    state.volumeTask = function()
        state.volumeTask = nil
        self:act("volume", { percent = percent }, done)
    end
    UIManager:scheduleIn(0.5, state.volumeTask)
end

-- ------------------------------------------------------------------ things to start

--- The account's playlists: done(list) or done(nil, why). Kept for 10 minutes (again sooner
-- with force); quiet: no waiting message.
function Spotify:playlists(done, force, quiet)
    if state.playlists and not force and os.time() - state.playlistsTime < 600 then return done(state.playlists) end
    local blocked = self:blocked()
    if blocked then return done(nil, blocked) end
    self:job(function(api) return api:playlists() end, function(items, why)
        if items then
            state.playlists, state.playlistsTime = M.playlists(items), os.time()
            return done(state.playlists)
        end
        done(nil, why)
    end, { limit = 40, text = not quiet and _("Reading your playlists…") or nil })
end

--- Recently played songs: done(list) or done(nil, why). Kept for a minute.
function Spotify:recent(done, force, quiet)
    if state.recent and not force and os.time() - state.recentTime < 60 then return done(state.recent) end
    local blocked = self:blocked()
    if blocked then return done(nil, blocked) end
    self:job(function(api) return api:recent() end, function(items, why)
        if items then
            state.recent, state.recentTime = M.recent(items), os.time()
            return done(state.recent)
        end
        done(nil, why)
    end, { limit = 25, text = not quiet and _("Reading…") or nil })
end

function Spotify:knownPlaylists() return state.playlists end

--- The playlists that can be added to (your own and the collaborative ones): done(list) or
-- done(nil, why).
function Spotify:ownPlaylists(done, quiet)
    self:playlists(function(list, why)
        if not list then return done(nil, why) end
        done(M.ownPlaylists(list, self:me()))
    end, false, quiet)
end

--- Whether a playlist (its URI) is one that can be changed, as far as is known.
function Spotify:ownsPlaylist(uri)
    local pl = M.findPlaylist(state.playlists, uri)
    return pl ~= nil and (pl.collaborative or (self:me() ~= nil and pl.ownerId == self:me()))
end

-- Lists read on request: how each is read (in the child) and made (here), and how long it's kept.
local LISTS = {
    liked = { ttl = 300, read = function(api) return api:likedSongs() end,
        make = function(self, r) return M.songs(r, M.likedContext(self:me())) end },
    library = { ttl = 600, read = function(api) return api:library() end,
        make = function(__, r) return { albums = M.albums(r.albums), artists = M.artistList(r.artists) } end },
    album = { ttl = 600, read = function(api, arg) return api:albumSongs(M.id(arg.uri)) end,
        make = function(__, r, arg) return M.songs(r, arg.uri, arg) end },
    artist = { ttl = 600, read = function(api, arg) return api:artistAlbums(M.id(arg.uri)) end,
        make = function(__, r) return M.albums(r, true) end },
    playlist = { ttl = 300, read = function(api, arg) return api:playlistSongs(M.id(arg.uri)) end,
        make = function(__, r, arg) return M.songs(r, arg.uri) end },
    queue = { ttl = 0, read = function(api) return api:queueList() end,
        make = function(__, r) return M.queue(r) end },
}

--- A list read in the background: done(items) or done(nil, why). kind: "liked" (Liked Songs),
-- "library" ({ albums, artists }), "album" and "artist" (arg: { uri, name }), "queue"
-- ({ now, next }). Kept for a while (again sooner with force).
function Spotify:list(kind, arg, done, force)
    local L = LISTS[kind]
    if not L then return done(nil, "Unknown list") end
    arg = arg or {}
    local key = kind .. ":" .. M.str(arg.uri)
    local have = state.lists[key]
    if have and not force and os.time() - have.time < L.ttl then return done(have.items) end
    local blocked = self:blocked()
    if blocked then return done(nil, blocked) end
    self:job(function(api) return L.read(api, arg) end, function(r, why)
        if r == nil then return done(nil, why) end
        local items = L.make(self, r, arg)
        state.lists[key] = { items = items, time = os.time() }
        self:changed()
        done(items)
    end, { limit = 30 })
end

function Spotify:knownList(kind, uri)
    local have = state.lists[kind .. ":" .. M.str(uri)]
    return have and have.items
end
function Spotify:knownRecent() return state.recent end
function Spotify:searchState() return state.search end

--- A search: done() when its results (or why not) are in searchState().
function Spotify:search(q, done, quiet)
    local S = state.search
    S.q, S.results, S.why = q, nil, nil
    local blocked = self:blocked()
    if blocked then
        S.why = blocked
        return done and done()
    end
    S.reading = true
    self:job(function(api) return api:search(q) end, function(r, why)
        S.reading = false
        if S.q == q then
            if r then S.results = M.searchResults(r) else S.why = why end
        end
        self:changed()
        if done then done() end
    end, { limit = 25, text = not quiet and _("Searching…") or nil })
end

-- ------------------------------------------------------------------ signing in

local function randomBytes(n)
    local f = io.open("/dev/urandom", "rb")
    local s = f and f:read(n)
    if f then f:close() end
    if s and #s == n then return s end
    local t = {}
    math.randomseed(os.time() + math.floor(os.clock() * 1000000))
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

local function sha256(s)
    local hex = require("ffi/sha2").sha256(s)
    return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

--- A sign-in started (or the one under way): the address to open in a browser, or nil and why.
function Spotify:signInUrl(again)
    local id = self:clientId()
    if not id then return nil, "notset" end
    if again or not state.signIn or state.signIn.clientId ~= id then
        local verifier = M.verifier(randomBytes(48))
        local st = M.base64url(randomBytes(12))
        state.signIn = { clientId = id, verifier = verifier, state = st,
            url = M.authorizeUrl(id, M.challenge(verifier, sha256), st) }
    end
    return state.signIn.url
end

--- The sign-in finished with what the browser ended on (the address with its code):
-- done(ok, text).
function Spotify:finishSignIn(text, done, quiet)
    local S = state.signIn
    if not S then return done(false, _("Start the sign-in again.")) end
    local code, why = M.parseCallback(text, S.state)
    if not code then return done(false, M.whyText(why)) end
    if not NetworkMgr:isConnected() then return done(false, M.whyText("offline")) end
    self:job(function(api)
        local t, w = api:exchange(code, S.verifier)
        if not t then return nil, w end
        return true
    end, function(ok, w)
        if not ok then
            -- (a code works once, and only for a few minutes)
            if w == "signin" then return done(false, _("That code has been used or is too old. Start the sign-in again.")) end
            return done(false, M.whyText(w))
        end
        state.signIn, state.signedIn, state.why = nil, nil, nil
        self:signedIn()   -- (and what it covers, read again)
        local PS = require("pluginshare")
        if PS.unnotify then pcall(PS.unnotify, "spotify:signin") end
        self:changed()
        self:fetch(nil, { devices = true })
        done(true)
    end, { limit = 30, text = not quiet and _("Signing in…") or nil })
end

--- Signed out: the tokens taken off the Kindle. Returns them (for Undo: signInAgain).
function Spotify:signOut()
    local old = Tokens.get()
    Tokens.set(nil)
    state.signedIn, state.signIn = false, nil
    state.player, state.devices, state.why, state.time = nil, nil, nil, 0
    state.playlists, state.recent, state.search.results = nil, nil, nil
    state.liked, state.lists, state.scope = {}, {}, nil
    self.store:delSetting("user_id")
    self.store:flush()
    self:changed()
    return old
end

function Spotify:signInAgain(tokens)
    if type(tokens) ~= "table" then return end
    Tokens.set(tokens)
    state.signedIn = nil
    self:signedIn()
    self:changed()
    self:fetch(nil, { devices = true })
end

-- ------------------------------------------------------------------ the launcher

function Spotify:shareWithApps()
    local PS = require("pluginshare")
    -- What it is for the launcher and the web page: its tile (only there while it's installed:
    -- an optional app), Settings group (Optional apps; its tile in the suggested Tools group), web tab
    -- (apps.koplugin/appsinfo.lua).
    PS.appInfo = PS.appInfo or {}
    PS.appInfo.spotify = { name = _("Spotify Remote"), icon = "music", dir = self.path, order = 89, group = "optional",
        -- "Song · Artist" while it plays.
        tiles = { { key = "spotify", group = "tools", event = "ShowSpotify", line = function(p) return p:appsLine() end } },
        gestures = { "spotify_show", "spotify_toggle", "spotify_next", "spotify_previous" },
        web = { page = "spotify", routes = "webspotify", script = "web/spotify.js",
            card = "A remote for Spotify: what's playing, play and pause, volume, the devices, and your playlists." } }
    PS.notifyOpeners = PS.notifyOpeners or {}
    PS.notifyOpeners.spotify = function(route)
        local p = current()
        if p then p:show(route == "settings" and "settings" or nil) end
    end
    -- The web page's backup: the settings and the Client ID; the sign-in only with
    -- Include keys and sign-ins.
    PS.backupApps = PS.backupApps or {}
    PS.backupApps.spotify = { key = "spotify", name = _("Spotify Remote"),
        files = { "^spotify%.lua$" },
        reader_keys = { "^spotify_" },
        secret_files = { "spotify_tokens.lua" } }
    if PS.registerSettings then
        PS.registerSettings{ key = "spotify", name = _("Spotify Remote"), icon = "music",
            open = function() local p = current() if p then p:show("settings") end end,
            rows = function()
                local p = current()
                return p and require("spui").searchRows(p) or {}
            end }
    end
    if PS.registerSearch then
        PS.registerSearch{ key = "spotify", name = _("Spotify Remote"), icon = "music", search = function(q)
            local p = current()
            return p and p:appsSearch(q) or {}
        end }
    end
    if PS.registerSetup then
        PS.registerSetup{ key = "spotify", order = 60, icon = "music", title = _("Spotify Remote"),
            text = _("A remote for Spotify: what's playing, play and pause, volume, the devices, and your playlists."),
            done = function() local p = current() return p ~= nil and p:configured() end,
            doneText = _("Signed in to Spotify"), action = _("Set up"),
            skipped = _("Nothing else needs it. Set it up any time from the Spotify Remote app."),
            help = { button = _("Requirements"), title = _("Connecting to Spotify"),
                steps = {
                    _("Spotify Premium."),
                    _("An app of your own in Spotify's developer dashboard (developer.spotify.com), with the redirect URI http://127.0.0.1:8888/callback and Web API ticked."),
                    _("Its Client ID, and a phone or computer to sign in on."),
                },
                after = _("The sign-in stays on the Kindle and is only sent to Spotify."),
                guide = "spotify.md" },
            run = function() local p = current() if p then require("spui").setup(p) end end }
    end
    if PS.registerTest then
        PS.registerTest{ key = "spotify", name = _("Spotify Remote"),
            configured = function() local p = current() return p ~= nil and p:configured() end,
            run = function(Test)
                local p = current()
                local api = require("spapi").new{ clientId = p and p:clientId(), tokens = Tokens }
                local socket = require("socket")
                local rows = {}
                local function timed(name, detail, fn)
                    local started = socket.gettime()
                    local r, why = fn()
                    local row = { name = name, detail = detail, ok = r ~= nil, ms = math.floor((socket.gettime() - started) * 1000) }
                    if r == nil then row.raw, row.why = tostring(why), M.whyText(why) end
                    table.insert(rows, row)
                    return r, row
                end
                local token = timed(_("Sign-in"), "accounts.spotify.com", function() return api:token(true) end)
                if token then
                    local d, row = timed(_("Devices"), "api.spotify.com", function() return api:devices() end)
                    if d then
                        local n = #M.devices(d)
                        row.why = n == 1 and _("1 device on") or T(_("%1 devices on"), n)
                    end
                end
                return rows
            end }
    end
    if PS.registerQuick then
        PS.registerQuick{ key = "spotify", name = _("Spotify Remote"),
            choices = function()
                return {
                    { id = "toggle", name = _("Play or pause"), icon = "play", group = _("Spotify Remote") },
                    { id = "previous", name = _("Previous"), icon = "skip-back", group = _("Spotify Remote") },
                    { id = "next", name = _("Next"), icon = "skip-forward", group = _("Spotify Remote") },
                }
            end,
            item = function(id)
                local p = current()
                return p and p:quickItem(id)
            end }
    end
end

--- A quick button: play or pause, previous, next (a hold opens the app).
function Spotify:quickItem(id)
    if not self:configured() then return nil end
    local p = state.player
    local fresh = p and os.time() - p.at < 300
    local names = { toggle = (fresh and p.playing) and _("Pause") or _("Play"), previous = _("Previous"), next = _("Next") }
    local icons = { toggle = (fresh and p.playing) and "pause" or "play", previous = "skip-back", next = "skip-forward" }
    if not names[id] then return nil end
    return { label = names[id], icon = icons[id],
        value = id == "toggle" and fresh and p.title ~= "" and p.title or nil,
        tap = function(done) self:quickCommand(id, done) end,
        hold = function() self:show() end }
end

--- The launcher's search (q in lower case): the playlists as last read, and the app itself.
function Spotify:appsSearch(q)
    local out = {}
    if not q or q == "" then return out end
    if ("spotify"):find(q, 1, true) then
        table.insert(out, { title = _("Spotify Remote"), sub = M.songLine(state.player), open = function() self:show() end })
    end
    for __, hit in ipairs(M.search(state.playlists, q)) do
        table.insert(out, { title = hit.title, sub = hit.sub, open = function()
            self:show()
            require("spui").playlists(self)
        end })
    end
    return out
end

-- ------------------------------------------------------------------ the web page

--- What the web page's Spotify Remote tab shows (no tokens). Spotify is read when the page asks and
-- what's here is older than the app's interval: only while that tab is open.
function Spotify:webState()
    local configured = self:configured()
    if configured and not state.reading and os.time() - math.max(state.time, state.tried) >= self:interval()
        and NetworkMgr:isConnected() then
        self:fetch()
    end
    local id = self:clientId()
    local out = { configured = configured, hasClientId = id ~= nil, clientIdHint = id and M.masked(id) or nil,
        signedIn = self:signedIn(), redirect = M.REDIRECT, signingIn = state.signIn ~= nil,
        interval = self:interval(), playerInterval = self:playerEvery(), art = self:showArt(), volumeStep = self:volumeBy(),
        read = state.time > 0 and state.time or nil, reading = state.reading,
        why = state.why and M.whyText(state.why) or nil }
    local p = state.player
    if p then
        local now = os.time()
        out.player = { playing = p.playing, title = p.title, artist = p.artist, album = p.album,
            picture = self:showArt() and p.art ~= "" and p.art or nil,
            progress = M.progressNow(p, now), duration = p.duration,
            progressText = M.time(M.progressNow(p, now)), durationText = M.time(p.duration),
            shuffle = p.shuffle, ["repeat"] = p["repeat"], repeatName = M.repeatName(p["repeat"]),
            device = p.device and p.device.name or nil, volume = p.device and p.device.volume or nil,
            canVolume = p.device and p.device.supportsVolume or false,
            uri = p.uri, liked = self:liked(), canLike = p.uri:match("^spotify:track:") ~= nil,
            album = p.album, albumUri = p.albumUri ~= "" and p.albumUri or nil,
            artistUri = p.artistUri ~= "" and p.artistUri or nil, artistName = p.artistName,
            context = p.context ~= "" and p.context or nil,
            canRemove = p.context ~= "" and self:ownsPlaylist(p.context) }
    elseif p == false then
        out.nothing = true
    end
    if state.devices then
        out.devices = {}
        for __, d in ipairs(state.devices) do
            table.insert(out.devices, { id = d.id, name = d.name, line = M.deviceLine(d), active = d.active, usable = d.usable })
        end
    end
    out.needs = M.needs()
    out.stay = self:staysAfterPlay()
    out.buttons, out.actions = {}, {}
    for __, b in ipairs(M.BUTTONS) do table.insert(out.buttons, { key = b.key, name = b.name, action = self:button(b.key) }) end
    for __, a in ipairs(M.BUTTON_ACTIONS) do table.insert(out.actions, { id = a.id, name = a.name }) end
    out.signInAgain = not self:scopesOk()
    out.liked = M.likedContext(self:me())
    out.queue = self:knownList("queue")
    out.library = self:knownList("library")
    out.likedSongs = self:knownList("liked")
    out.opened = state.webOpened
    if state.playlists then
        out.own = {}
        for __, pl in ipairs(M.ownPlaylists(state.playlists, self:me())) do
            table.insert(out.own, { uri = pl.uri, name = pl.name })
        end
    end
    out.dj = M.DJ
    out.seen = {}
    for __, d in ipairs(self:seenDevices()) do
        table.insert(out.seen, { id = d.id, name = d.name, line = M.deviceKind(d.type) })
    end
    out.playlists = state.playlists
    if state.playlists then
        out.playlists = {}
        for __, pl in ipairs(state.playlists) do
            table.insert(out.playlists, { uri = pl.uri, name = pl.name, line = M.playlistLine(pl) })
        end
    end
    out.recent = state.recent
    local S = state.search
    out.search = { q = S.q, reading = S.reading, why = S.why and M.whyText(S.why) or nil, results = S.results }
    -- (once each: why the page's last command failed, and how its sign-in ended)
    out.failed, out.signInResult = state.webWhy, state.signInResult
    state.webWhy, state.signInResult = nil, nil
    return out
end

--- The web page's actions. Commands (each started in the background: the page reads the state
-- again after): toggle, next, previous, seek { ms }, volume { percent }, shuffle { on },
-- repeat { mode }, transfer { device }, play { context, track, device }, queue { uri };
-- refresh, playlists, recent, search { q }; settings { clientId, interval, art, volumeStep };
-- signin (returns the address to open), finish { address }, signout.
-- Returns true (or a table for the page), or false and why.
function Spotify:webAct(name, args)
    args = type(args) == "table" and args or {}
    if name == "settings" then
        if args.clientId ~= nil and args.clientId ~= "" then
            local id = M.cleanClientId(args.clientId)
            if not id then return false, _("A Client ID is 32 letters and digits.") end
            self:setClientId(id)
        end
        if tonumber(args.interval) then G_reader_settings:saveSetting("spotify_interval", M.interval(args.interval)) end
        if tonumber(args.playerInterval) then
            local v = tonumber(args.playerInterval)
            G_reader_settings:saveSetting("spotify_player_interval", v <= 0 and 0 or M.interval(v))
        end
        if tonumber(args.volumeStep) then
            G_reader_settings:saveSetting("spotify_volume_step", math.max(1, math.min(25, math.floor(tonumber(args.volumeStep)))))
        end
        if args.art ~= nil then G_reader_settings:saveSetting("spotify_art", args.art == true) end
        if args.stay ~= nil then G_reader_settings:saveSetting("spotify_stay", args.stay == true) end
        if type(args.button) == "string" then
            for __, b in ipairs(M.BUTTONS) do
                if b.key == args.button then
                    G_reader_settings:saveSetting("spotify_button_" .. b.key, M.buttonAction(b.key, tostring(args.action)))
                end
            end
        end
        self:changed()
        return true
    end
    if name == "signin" then
        local url, why = self:signInUrl(true)
        if not url then return false, M.whyText(why) end
        return { url = url }
    end
    if name == "finish" then
        local result = { pending = true }
        self:finishSignIn(tostring(args.address or ""), function(ok, text)
            result.pending, result.ok, result.text = nil, ok, text
            state.signInResult = { ok = ok, text = text }
        end, true)
        if result.pending then return true end
        if not result.ok then return false, result.text end
        return true
    end
    if name == "signout" then
        self:signOut()
        return true
    end
    if name == "forget" then
        self:forgetDevice(M.str(args.device))
        return true
    end
    local blocked = self:blocked()
    if blocked then return false, M.whyText(blocked) end
    if name == "refresh" then
        self:fetch(nil, { devices = true })
        return true
    end
    if name == "playlists" then
        self:playlists(function() end, args.force == true, true)
        return true
    end
    if name == "recent" then
        self:recent(function() end, args.force == true, true)
        return true
    end
    if name == "search" then
        local q = M.trim(args.q)
        if q == "" then
            state.search.q, state.search.results, state.search.why = "", nil, nil
            return true
        end
        self:search(q, nil, true)
        return true
    end
    if name == "list" then
        local kind = tostring(args.kind or "")
        if kind ~= "queue" and kind ~= "library" and kind ~= "liked" then return false, "Which list?" end
        self:list(kind, nil, function() end, args.force == true)
        return true
    end
    -- (an album's songs or an artist's albums, for the page to show: { kind, uri, name, items })
    if name == "open" then
        local kind, uri = tostring(args.kind or ""), M.str(args.uri)
        if (kind ~= "album" and kind ~= "artist" and kind ~= "playlist") or not uri:match("^spotify:" .. kind .. ":") then return false, "Open what?" end
        if kind == "playlist" and not self:ownsPlaylist(uri) then return false, M.whyText("notyours") end
        local arg = { uri = uri, name = M.str(args.name) }
        state.webOpened = { kind = kind, uri = uri, name = arg.name, own = kind == "playlist" }
        self:list(kind, arg, function(items, why)
            if state.webOpened and state.webOpened.uri == uri then
                state.webOpened.items, state.webOpened.why = items, why and M.whyText(why) or nil
            end
        end)
        return true
    end
    if name == "close" then
        state.webOpened = nil
        return true
    end
    if not ACTIONS[name] then return false, "Unknown action" end
    local a = {}
    if name == "seek" then
        a.ms = tonumber(args.ms)
        if not a.ms then return false, "Where to?" end
    elseif name == "volume" then
        a.percent = tonumber(args.percent)
        if not a.percent then return false, "How loud?" end
        a.percent = math.max(0, math.min(100, math.floor(a.percent)))
    elseif name == "shuffle" then
        a.on = args.on == true
    elseif name == "repeat" then
        a.mode = ({ off = "off", context = "context", track = "track" })[tostring(args.mode)]
        if not a.mode then return false, "Which repeat?" end
    elseif name == "transfer" then
        a.device = M.str(args.device)
        if a.device == "" then return false, "Which device?" end
    elseif name == "queue" then
        a.uri = M.str(args.uri)
        if not a.uri:match("^spotify:") then return false, "Which song?" end
    elseif name == "like" then
        a.uri, a.on = M.str(args.uri), args.on == true
        if not a.uri:match("^spotify:track:") then return false, "Which song?" end
    elseif name == "move" then
        a.playlist, a.from, a.to = M.str(args.playlist), tonumber(args.from), tonumber(args.to)
        if not a.from or not a.to or a.from < 1 or a.to < 1 then return false, "Move where?" end
        if not self:ownsPlaylist(a.playlist) then return false, M.whyText("notyours") end
        a.from, a.to = math.floor(a.from), math.floor(a.to)
    elseif name == "addto" or name == "removefrom" then
        a.uri, a.playlist = M.str(args.uri), M.str(args.playlist)
        if not a.uri:match("^spotify:") then return false, "Which song?" end
        if not a.playlist:match("^spotify:playlist:") then return false, "Which playlist?" end
        if not self:ownsPlaylist(a.playlist) then return false, M.whyText("notyours") end
    elseif name == "play" then
        a.context = M.str(args.context) ~= "" and M.str(args.context) or nil
        a.track = M.str(args.track) ~= "" and M.str(args.track) or nil
        if not a.context and not a.track then return false, "Play what?" end
    end
    if (name == "play" or name == "toggle") and M.str(args.device) ~= "" then a.device = M.str(args.device) end
    state.webWhy = nil
    self:act(name, a, function(ok, text, why)
        -- (the page shows why its last command failed; "choose": it asks for the device)
        state.webWhy = not ok and { text = text, choose = why == "choose", name = name, args = a } or nil
    end)
    return true
end

return Spotify
