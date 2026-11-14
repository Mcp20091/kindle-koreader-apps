--[[--
Spotify as words and tables, in plain Lua for the tests: the sign-in's
addresses and codes (Authorization Code with PKCE), what's playing and the
devices as the Web API gives them, playlists, recently played songs and
search results, why something failed, times, the launcher's line and search.

The API's shapes (Spotify's Web API reference):
* GET /me/player: { device = { id, name, type, volume_percent, supports_volume,
  is_active, is_restricted }, is_playing, progress_ms, shuffle_state,
  repeat_state ("off", "context", "track"), context = { uri, type },
  currently_playing_type ("track", "episode", "ad"), item = { name, uri,
  duration_ms, artists = { { name } }, album = { name, images = { { url,
  width } } } }, actions = { disallows = { … } } }; 204 with nothing when
  nothing is playing anywhere;
* GET /me/player/devices: { devices = { … } };
* errors: { error = { status, message, reason } } (reason on player errors:
  NO_ACTIVE_DEVICE, PREMIUM_REQUIRED…); a 429 over the quota has
  { reason = "QUOTA_EXCEEDED" };
* the token address answers { access_token, expires_in, refresh_token, scope },
  or { error = "invalid_grant", error_description }.
]]

local M = {}

-- Gettext when inside KOReader; the words themselves in the tests.
local ok, gettext = pcall(require, "gettext")
local _ = ok and gettext or function(s) return s end
local function T(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end
M.T = T

M.API = "https://api.spotify.com/v1"
M.ACCOUNTS = "https://accounts.spotify.com"
-- Where Spotify sends the browser after the sign-in. Nothing listens there: the address
-- itself (with its code) is what the Kindle needs. Spotify takes http only for 127.0.0.1.
M.REDIRECT = "http://127.0.0.1:8888/callback"
-- What the sign-in asks for: reading and controlling playback (the remote), the recently
-- played songs (Recent) and the account's playlists (Playlists).
M.SCOPES = "user-read-playback-state user-modify-playback-state user-read-currently-playing "
    .. "user-read-recently-played playlist-read-private playlist-read-collaborative "
    -- liking a song and the library (Liked Songs, albums, artists); adding to and removing from playlists
    .. "user-library-read user-library-modify user-follow-read playlist-modify-public playlist-modify-private"

--- Whether a sign-in (its scope, as Spotify answered it) covers everything asked for now: one
-- made before a feature was added doesn't, and has to be made again for it.
function M.scopesCover(scope)
    if type(scope) ~= "string" or scope == "" then return true end   -- (not known: taken as fine)
    local have = {}
    for s in scope:gmatch("%S+") do have[s] = true end
    for s in M.SCOPES:gmatch("%S+") do
        if not have[s] then return false end
    end
    return true
end
M.SEARCH_LIMIT = 6      -- of each kind (Spotify allows at most 10)
M.RECENT_LIMIT = 30
M.PLAYLIST_PAGE = 50
M.PLAYLIST_PAGES = 4    -- at most 200 playlists
-- Spotify's DJ, as a playlist to start (a trial: Spotify has no API for DJ; this is the hidden
-- playlist its own apps play, as other remotes use it, and it may not start DJ on every device).
M.DJ = "spotify:playlist:37i9dQZF1EYkqdzj48dyYq"

-- (JSON's null comes back as a value of its own: anything not a plain string or number is nothing)
local function str(v)
    if type(v) == "string" then return v end
    if type(v) == "number" then return tostring(v) end
    return ""
end
M.str = str

local function num(v) return tonumber(v) or 0 end
local function list(v) return type(v) == "table" and v or {} end
local function tbl(v) return type(v) == "table" and v or {} end

function M.trim(s) return (str(s):gsub("^%s+", ""):gsub("%s+$", "")) end

-- ------------------------------------------------------------------ requests

function M.urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

function M.urldecode(s)
    return (tostring(s):gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- Query parameters in a stable order: "limit=5&q=a%20b".
function M.query(params)
    local keys = {}
    for k in pairs(params or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for __, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. M.urlencode(params[k]) end
    return table.concat(parts, "&")
end

--- "••••••3f": a Client ID with only its last two characters showing.
function M.masked(s)
    s = str(s)
    if #s <= 2 then return s ~= "" and "••" or "" end
    return string.rep("•", math.min(#s - 2, 12)) .. s:sub(-2)
end

--- A Client ID as typed or pasted: its 32 letters and digits, or nil.
function M.cleanClientId(s)
    s = M.trim(s):lower()
    if #s == 32 and not s:find("[^0-9a-f]") then return s end
    return nil
end

-- ------------------------------------------------------------------ the sign-in (PKCE)

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

--- Bytes as base64url with no padding (what PKCE wants).
function M.base64url(bytes)
    local out = {}
    for i = 1, #bytes, 3 do
        local a, b, c = bytes:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "") .. (c and B64:sub(c4 + 1, c4 + 1) or "")
    end
    return table.concat(out)
end

--- The code verifier from random bytes (48 make 64 characters), and its challenge:
-- sha256(bytes) gives the 32 bytes of the hash.
function M.verifier(random) return M.base64url(random) end
function M.challenge(verifier, sha256) return M.base64url(sha256(verifier)) end

--- The address to sign in at.
function M.authorizeUrl(clientId, challenge, state)
    return M.ACCOUNTS .. "/authorize?" .. M.query({
        client_id = clientId, response_type = "code", redirect_uri = M.REDIRECT,
        code_challenge_method = "S256", code_challenge = challenge, scope = M.SCOPES, state = state,
    })
end

--- The code from what was pasted after the sign-in: the whole address the browser ended on
-- ("http://127.0.0.1:8888/callback?code=…&state=…"), or the code alone. state: the one sent.
-- Returns the code, or nil and why ("empty", "denied", "state", "nocode").
function M.parseCallback(text, state)
    text = M.trim(text)
    if text == "" then return nil, "empty" end
    if not text:find("[?&=]") then
        if text:find("[^%w%-_]") then return nil, "nocode" end
        return text
    end
    local q = text:match("%?(.*)$") or text
    q = q:gsub("#.*$", "")
    local args = {}
    for k, v in q:gmatch("([^&=]+)=([^&]*)") do args[k] = M.urldecode(v) end
    if args.error then return nil, "denied" end
    if not args.code or args.code == "" then return nil, "nocode" end
    if state and args.state and args.state ~= state then return nil, "state" end
    return args.code
end

--- The tokens to keep from the token address's answer: { access_token, refresh_token (the
-- new one, else the one used), expires_at, scope }. now: seconds.
function M.tokens(answer, now, old)
    answer, old = tbl(answer), tbl(old)
    local access = str(answer.access_token)
    if access == "" then return nil end
    local refresh = str(answer.refresh_token)
    if refresh == "" then refresh = str(old.refresh_token) end
    local scope = str(answer.scope)
    return { access_token = access, refresh_token = refresh ~= "" and refresh or nil,
        expires_at = now + math.max(60, num(answer.expires_in)), scope = scope ~= "" and scope or old.scope }
end

--- Whether the access token is still good for a while (a minute to spare).
function M.fresh(tokens, now)
    return type(tokens) == "table" and str(tokens.access_token) ~= "" and num(tokens.expires_at) - 60 > now
end

-- ------------------------------------------------------------------ why it failed

--- Why a request failed, from its status and its answer (a table, or nil): "signin" (the
-- token was refused), "premium", "notlisted" (the account isn't on the app's user list),
-- "nodevice", "devicegone", "restricted" (not allowed right now: an ad, the end of the
-- queue), "quota", "busy", "down", or Spotify's own words.
function M.whyOf(status, answer)
    local e = tbl(tbl(answer).error)
    local reason = str(e.reason ~= nil and e.reason or tbl(answer).reason)
    local message = str(e.message)
    local low = message:lower()
    if status == 401 then return "signin" end
    if reason == "PREMIUM_REQUIRED" or low:find("premium", 1, true) then return "premium" end
    if reason == "NO_ACTIVE_DEVICE" then return "nodevice" end
    if status == 404 and low:find("device", 1, true) then
        return low:find("no active", 1, true) and "nodevice" or "devicegone"
    end
    if status == 403 and (low:find("registered", 1, true) or low:find("developer dashboard", 1, true)) then
        return "notlisted"
    end
    if status == 403 and low:find("scope", 1, true) then return "scope" end
    if status == 403 then return "restricted" end
    if status == 429 then return reason == "QUOTA_EXCEEDED" and "quota" or "busy" end
    if status == 502 or status == 503 or status == 504 then return "down" end
    if message ~= "" then return message end
    return "HTTP " .. tostring(status)
end

--- Why the token address refused: "signin" (the sign-in is no longer good), "clientid".
function M.whyToken(status, answer)
    local e = str(tbl(answer).error)
    if e == "invalid_grant" then return "signin" end
    if e == "invalid_client" or e == "unauthorized_client" then return "clientid" end
    if status == 429 then return "busy" end
    if status >= 500 then return "down" end
    local d = str(tbl(answer).error_description)
    return d ~= "" and d or (e ~= "" and e or "HTTP " .. tostring(status))
end

--- Why something failed, in plain words.
function M.whyText(why)
    local s = tostring(why or "")
    if s == "signin" then return _("Sign in to Spotify again.") end
    if s == "premium" then return _("Spotify Premium is needed to control playback.") end
    if s == "scope" then return _("Sign in to Spotify again to allow this.") end
    if s == "notyours" then return _("You can only change your own playlists.") end
    if s == "notlisted" then return _("This Spotify account isn't on your app's user list. Add it in Spotify's developer dashboard.") end
    if s == "clientid" then return _("Spotify doesn't know that Client ID. Check it in Settings.") end
    if s == "nodevice" then return _("No Spotify device is on. Open Spotify on a phone, computer or speaker.") end
    if s == "devicegone" then return _("That device is no longer on.") end
    if s == "restricted" then return _("Spotify doesn't allow that right now.") end
    if s == "quota" then return _("Spotify's limit for your app is used up for now. Try again later.") end
    if s == "busy" then return _("Spotify asked to wait: too many requests for now. Try again in a minute.") end
    if s == "down" then return _("Spotify is having trouble. Try again in a minute.") end
    if s == "notapi" then return _("Spotify didn't answer as expected.") end
    if s == "offline" then return _("Not on Wi-Fi.") end
    if s == "notset" then return _("Spotify Remote isn't set up yet.") end
    if s == "signedout" then return _("Not signed in to Spotify.") end
    if s == "denied" then return _("The sign-in was cancelled.") end
    if s == "state" then return _("That address is from another sign-in. Start again.") end
    if s == "nocode" or s == "empty" then return _("Paste the whole address the browser ended on. It starts with http://127.0.0.1.") end
    if s:find("timeout") or s:find("timed out") then return _("Spotify didn't answer in time.") end
    if s:find("host not found") or s:find("unreachable") or s:find("No route") or s:find("resolve") then
        return _("Spotify can't be reached from this Wi-Fi.")
    end
    if s:find("certificate") or s:find("handshake") or s:find("ssl") then return _("The secure connection failed (its certificate).") end
    if s == "" or s == "nil" or s == "no answer" or s == "nothing" then return _("Spotify didn't answer.") end
    return s
end

-- ------------------------------------------------------------------ devices

local DEVICE_ICONS = { computer = "laptop", smartphone = "smartphone", tablet = "tablet", speaker = "speaker",
    tv = "tv", avr = "speaker", stb = "tv", audiodongle = "speaker", gameconsole = "gamepad-2",
    castvideo = "tv", castaudio = "speaker", automobile = "car" }
local DEVICE_NAMES = { computer = _("Computer"), smartphone = _("Phone"), tablet = _("Tablet"), speaker = _("Speaker"),
    tv = _("TV"), avr = _("Receiver"), stb = _("TV box"), audiodongle = _("Speaker"), gameconsole = _("Game console"),
    castvideo = _("TV"), castaudio = _("Speaker"), automobile = _("Car") }

function M.deviceIcon(kind) return DEVICE_ICONS[str(kind):lower()] or "speaker" end
function M.deviceKind(kind) return DEVICE_NAMES[str(kind):lower()] or str(kind) end

local function device(d)
    d = tbl(d)
    local id = str(d.id)
    local restricted = d.is_restricted == true
    local volume = type(d.volume_percent) == "number" and d.volume_percent or nil
    return { id = id, name = str(d.name) ~= "" and str(d.name) or _("Device"), type = str(d.type),
        active = d.is_active == true, restricted = restricted, volume = volume,
        supportsVolume = d.supports_volume ~= false and volume ~= nil,
        -- (restricted: Spotify takes no commands for it; no id: it can't be named in one)
        usable = id ~= "" and not restricted }
end

--- The devices as the API gives them: the one playing first, then those that take commands by
-- name, then the ones that don't.
function M.devices(raw)
    local out = {}
    for __, d in ipairs(list(tbl(raw).devices or raw)) do
        if type(d) == "table" then out[#out + 1] = device(d) end
    end
    local function rank(d) return d.active and 0 or (d.usable and 1 or 2) end
    table.sort(out, function(a, b)
        if rank(a) ~= rank(b) then return rank(a) < rank(b) end
        if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
        return a.id < b.id
    end)
    return out
end

--- A device's second line: "Speaker · 40%", "Phone · Unavailable".
function M.deviceLine(d)
    local parts = { M.deviceKind(d.type) }
    if not d.usable then parts[#parts + 1] = _("Unavailable")
    elseif d.volume then parts[#parts + 1] = T(_("%1%"), d.volume) end
    return table.concat(parts, " · ")
end

--- The device to start playing on when none is active: the one used last (preferred, an id)
-- when it's on, else the only one that takes commands. Returns it; or nil and "none" (nothing
-- usable is on) or "choose" (several: ask).
function M.pickDevice(devices, preferred)
    local usable = {}
    for __, d in ipairs(devices or {}) do
        if d.usable then
            if d.active or (preferred and d.id == preferred) then return d end
            usable[#usable + 1] = d
        end
    end
    if #usable == 0 then return nil, "none" end
    if #usable == 1 then return usable[1] end
    return nil, "choose"
end

function M.findDevice(devices, id)
    for __, d in ipairs(devices or {}) do if d.id == id then return d end end
end

M.SEEN_MAX = 12

--- The devices seen before ({ [id] = { name, type, time } }) with the ones on now added (those
-- that take commands); the newest SEEN_MAX kept. Returns the table, and whether it changed
-- (a new device or another name: when it was seen alone isn't worth saving).
function M.noteSeen(seen, devices, now)
    local out, changed = {}, false
    for id, s in pairs(type(seen) == "table" and seen or {}) do
        if type(s) == "table" then out[id] = { name = str(s.name), type = str(s.type), time = num(s.time) } end
    end
    for __, d in ipairs(devices or {}) do
        if d.usable then
            local old = out[d.id]
            if not old or old.name ~= d.name or old.type ~= d.type then changed = true end
            out[d.id] = { name = d.name, type = d.type, time = now }
        end
    end
    local ids = {}
    for id in pairs(out) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b)
        if out[a].time ~= out[b].time then return out[a].time > out[b].time end
        return a < b
    end)
    for i = M.SEEN_MAX + 1, #ids do
        out[ids[i]] = nil
        changed = true
    end
    return out, changed
end

--- The devices seen before that aren't on now, by name: { { id, name, type } }.
function M.seenList(seen, devices)
    local out = {}
    for id, s in pairs(type(seen) == "table" and seen or {}) do
        if type(s) == "table" and not M.findDevice(devices, id) then
            out[#out + 1] = { id = id, name = str(s.name) ~= "" and str(s.name) or _("Device"), type = str(s.type) }
        end
    end
    table.sort(out, function(a, b)
        if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
        return a.id < b.id
    end)
    return out
end

-- ------------------------------------------------------------------ what's playing

local function artists(v)
    local names = {}
    for __, a in ipairs(list(v)) do
        local n = str(tbl(a).name)
        if n ~= "" then names[#names + 1] = n end
    end
    return table.concat(names, ", ")
end

--- The picture nearest to want pixels wide (Spotify lists 640, 300 and 64), or "".
function M.image(images, want)
    local best, bestGap
    for __, im in ipairs(list(images)) do
        local url = str(tbl(im).url)
        if url ~= "" then
            local gap = math.abs(num(im.width) - want)
            if not best or gap < bestGap then best, bestGap = url, gap end
        end
    end
    return best or ""
end

--- A file name for a picture's address: its last part, letters and digits only.
function M.artFile(url)
    local name = str(url):match("([%w]+)[^/]*$")
    if not name or name == "" then return nil end
    return name:sub(-40) .. ".jpg"
end

--- What's playing, from GET /me/player's answer (nil when it answered nothing: nothing is
-- playing anywhere). at: when it was read (seconds).
function M.player(raw, at)
    if type(raw) ~= "table" or (raw.device == nil and raw.item == nil) then return nil end
    local item = tbl(raw.item)
    local kind = str(raw.currently_playing_type)
    local show = tbl(item.show)
    local album = tbl(item.album)
    local p = {
        at = at or 0,
        playing = raw.is_playing == true,
        kind = kind ~= "" and kind or "track",
        title = str(item.name),
        artist = kind == "episode" and str(show.name) or artists(item.artists),
        album = kind == "episode" and "" or str(album.name),
        art = M.image(kind == "episode" and (item.images or show.images) or album.images, 300),
        uri = str(item.uri),
        albumUri = kind == "episode" and "" or str(album.uri),
        artistUri = kind == "episode" and "" or str(tbl(list(item.artists)[1]).uri),
        artistName = kind == "episode" and "" or str(tbl(list(item.artists)[1]).name),
        duration = num(item.duration_ms),
        progress = num(raw.progress_ms),
        shuffle = raw.shuffle_state == true,
        ["repeat"] = ({ context = "context", track = "track" })[str(raw.repeat_state)] or "off",
        context = str(tbl(raw.context).uri),
        device = raw.device ~= nil and device(raw.device) or nil,
        disallows = {},
    }
    for k, v in pairs(tbl(tbl(raw.actions).disallows)) do if v == true then p.disallows[k] = true end end
    if p.kind == "ad" and p.title == "" then p.title = _("Advertisement") end
    return p
end

--- How far the song is now (ms): what was read, plus the time since when it's playing.
function M.progressNow(p, now)
    if not p then return 0 end
    local ms = p.progress
    if p.playing then ms = ms + math.max(0, (now - p.at)) * 1000 end
    if p.duration > 0 then ms = math.min(ms, p.duration) end
    return math.max(0, ms)
end

--- Seconds until the song ends (nil when paused or its length isn't known).
function M.endsIn(p, now)
    if not p or not p.playing or p.duration <= 0 then return nil end
    return math.max(0, (p.duration - M.progressNow(p, now)) / 1000)
end

--- "3:07", "1:02:03".
function M.time(ms)
    local s = math.floor(math.max(0, num(ms)) / 1000)
    local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s % 60) end
    return string.format("%d:%02d", m, s % 60)
end

local REPEAT_NEXT = { off = "context", context = "track", track = "off" }
function M.nextRepeat(mode) return REPEAT_NEXT[mode] or "context" end
function M.repeatName(mode)
    if mode == "context" then return _("Repeat all") end
    if mode == "track" then return _("Repeat one") end
    return _("Repeat off")
end

--- A volume from 0 to 100, a step up or down.
function M.volumeStep(volume, by)
    return math.max(0, math.min(100, math.floor(num(volume) + by + 0.5)))
end

--- "Song · Artist".
function M.songLine(p)
    if not p or p.title == "" then return "" end
    return p.artist ~= "" and (p.title .. " · " .. p.artist) or p.title
end

--- The launcher tile's line, from memory: the song when it was read in the last few minutes
-- and is playing, else nothing (the tile never asks Spotify).
function M.appsLine(p, now, signedIn)
    if not signedIn then return _("Not set up") end
    if p and p.playing and now - p.at < 300 then return M.songLine(p) end
    return ""
end

-- ------------------------------------------------------------------ things to start

--- The account's playlists: { { uri, name, owner, total } } (Spotify can list empty entries).
function M.playlists(items)
    local out = {}
    for __, pl in ipairs(list(items)) do
        if type(pl) == "table" and str(pl.uri) ~= "" then
            local count = tbl(pl.items).total or tbl(pl.tracks).total
            out[#out + 1] = { uri = str(pl.uri), name = str(pl.name) ~= "" and str(pl.name) or _("Playlist"),
                owner = str(tbl(pl.owner).display_name), ownerId = str(tbl(pl.owner).id),
                collaborative = pl.collaborative == true, total = type(count) == "number" and count or nil }
        end
    end
    return out
end

--- A playlist's second line: "Pat · 42 songs".
function M.playlistLine(pl)
    local parts = {}
    if pl.owner ~= "" then parts[#parts + 1] = pl.owner end
    if pl.total then parts[#parts + 1] = pl.total == 1 and _("1 song") or T(_("%1 songs"), pl.total) end
    return table.concat(parts, " · ")
end

local function track(t)
    t = tbl(t)
    if str(t.uri) == "" then return nil end
    local first = tbl(list(t.artists)[1])
    return { uri = str(t.uri), title = str(t.name), artist = artists(t.artists), album = str(tbl(t.album).name),
        albumUri = str(tbl(t.album).uri), artistUri = str(first.uri), artistName = str(first.name),
        duration = num(t.duration_ms) }
end

--- A song moved in a playlist, as Spotify's reorder wants it: from and to are its place now
-- and after (1 is the first). Returns range_start and insert_before (both counted from 0).
function M.reorder(from, to)
    return from - 1, to > from and to or to - 1
end

--- The same move made in a list (in place). Returns whether anything moved.
function M.moveInList(list, from, to)
    if type(list) ~= "table" or from == to or from < 1 or to < 1 or from > #list or to > #list then return false end
    table.insert(list, to, table.remove(list, from))
    return true
end

--- "spotify:playlist:abc" -> "abc" (the last part of a URI).
function M.id(uri) return str(uri):match("([^:]+)$") or "" end

--- The playlists that can be changed: the user's own (me: their id) and the collaborative ones.
function M.ownPlaylists(playlists, me)
    local out = {}
    for __, pl in ipairs(playlists or {}) do
        if pl.collaborative or (me and me ~= "" and pl.ownerId == me) then out[#out + 1] = pl end
    end
    return out
end

function M.findPlaylist(playlists, uri)
    for __, pl in ipairs(playlists or {}) do if pl.uri == uri then return pl end end
end

--- Liked Songs as something to play: "spotify:user:<id>:collection" (nil without the id).
function M.likedContext(me)
    if not me or me == "" then return nil end
    return "spotify:user:" .. me .. ":collection"
end

--- Songs from a list of { track = … } (Liked Songs) or of tracks (an album's): each with
-- context (where Play goes on from), when given. An album's songs don't say their album: album
-- ({ uri, name }) fills it in.
function M.songs(items, context, album)
    local out = {}
    for __, it in ipairs(list(items)) do
        -- (a playlist's entries hold their song as `item`, older answers as `track`)
        local inner = type(it) == "table" and (it.item ~= nil and it.item or it.track) or nil
        local t = track(inner ~= nil and inner or it)
        if t then
            t.context = context
            if album and t.albumUri == "" then t.albumUri, t.album = album.uri, album.name end
            out[#out + 1] = t
        end
    end
    return out
end

--- Albums from a list of { album = … } (saved albums) or of albums (an artist's):
-- { { uri, name, sub } } (sub: the artist, or the year for an artist's own).
function M.albums(items, byYear)
    local out, seen = {}, {}
    for __, it in ipairs(list(items)) do
        local a = tbl(type(it) == "table" and it.album ~= nil and it.album or it)
        local uri = str(a.uri)
        if uri ~= "" and not seen[uri] then
            seen[uri] = true
            local first = tbl(list(a.artists)[1])
            out[#out + 1] = { uri = uri, name = str(a.name), sub = byYear and str(a.release_date):sub(1, 4) or artists(a.artists),
                artistUri = str(first.uri), artistName = str(first.name) }
        end
    end
    return out
end

--- Followed artists from GET /me/following's answer: { { uri, name } }, by name.
function M.artistList(raw)
    local out = {}
    for __, a in ipairs(list(tbl(tbl(raw).artists).items)) do
        if type(a) == "table" and str(a.uri) ~= "" then out[#out + 1] = { uri = str(a.uri), name = str(a.name) } end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

--- The queue from GET /me/player/queue's answer: { now = song or nil, next = { songs } }.
function M.queue(raw)
    raw = tbl(raw)
    return { now = track(raw.currently_playing), next = M.songs(raw.queue) }
end

--- Recently played songs, newest first, each once: { { uri, title, artist, context } }
-- (context: the album or playlist it was played from, to go on from there).
function M.recent(items)
    local out, seen = {}, {}
    for __, it in ipairs(list(items)) do
        local t = track(tbl(it).track)
        if t and not seen[t.uri] then
            seen[t.uri] = true
            local c = tbl(tbl(it).context)
            local kind = str(c.type)
            if (kind == "album" or kind == "playlist") and str(c.uri) ~= "" then t.context = str(c.uri) end
            out[#out + 1] = t
        end
    end
    return out
end

--- Search results: { tracks = { { uri, title, artist } }, albums = { { uri, name, sub } },
-- playlists = …, artists = … } (empty entries left out).
function M.searchResults(raw)
    raw = tbl(raw)
    local out = { tracks = {}, albums = {}, playlists = {}, artists = {} }
    for __, t in ipairs(list(tbl(raw.tracks).items)) do
        local x = track(t)
        if x then out.tracks[#out.tracks + 1] = x end
    end
    for __, a in ipairs(list(tbl(raw.albums).items)) do
        if type(a) == "table" and str(a.uri) ~= "" then
            local first = tbl(list(a.artists)[1])
            out.albums[#out.albums + 1] = { uri = str(a.uri), name = str(a.name), sub = artists(a.artists),
                artistUri = str(first.uri), artistName = str(first.name) }
        end
    end
    for __, pl in ipairs(M.playlists(tbl(raw.playlists).items)) do
        out.playlists[#out.playlists + 1] = { uri = pl.uri, name = pl.name, sub = pl.owner }
    end
    for __, a in ipairs(list(tbl(raw.artists).items)) do
        if type(a) == "table" and str(a.uri) ~= "" then
            out.artists[#out.artists + 1] = { uri = str(a.uri), name = str(a.name), sub = "" }
        end
    end
    out.count = #out.tracks + #out.albums + #out.playlists + #out.artists
    return out
end

--- The launcher's search (q in lower case) over the playlists as last read.
function M.search(playlists, q)
    local out = {}
    if not q or q == "" then return out end
    for __, pl in ipairs(playlists or {}) do
        if pl.name:lower():find(q, 1, true) then
            out[#out + 1] = { title = pl.name, sub = _("Playlist"), uri = pl.uri }
            if #out >= 8 then break end
        end
    end
    return out
end

-- ------------------------------------------------------------------ requirements

--- The requirements and Spotify's limits, in the same words on the Kindle (Help) and the web page:
-- { needs = { … }, limits = { … } }.
function M.needs()
    return {
        needs = {
            _("Spotify Premium. Spotify only lets Premium accounts control playback."),
            _("A Spotify device that's on: a phone, computer or speaker. Nothing plays on the Kindle."),
            T(_("An app of your own in Spotify's developer dashboard (developer.spotify.com). It's free. Give it the redirect URI %1 and tick Web API."), M.REDIRECT),
            _("That app's Client ID. There's no password, secret or API key to enter."),
            _("A phone or computer to sign in on, once."),
        },
        limits = {
            _("Your app works for up to 5 Spotify accounts. Add each one under User Management in the dashboard. The account that made the app needs Premium too."),
            _("Spotify lists a device only while it's connected, so an idle speaker can be missing."),
            _("Spotify limits how often an app may ask. If that's reached, wait a little."),
            _("These are Spotify's rules as of November 2026. Spotify can change them."),
        },
    }
end

--- The same as one text to read: Help starts with it.
function M.needsText()
    local n = M.needs()
    local lines = { _("REQUIREMENTS") }
    for __, s in ipairs(n.needs) do lines[#lines + 1] = "• " .. s end
    lines[#lines + 1] = ""
    lines[#lines + 1] = _("LIMITS")
    for __, s in ipairs(n.limits) do lines[#lines + 1] = "• " .. s end
    return table.concat(lines, "\n")
end

-- ------------------------------------------------------------------ settings

-- What a button can do (the title bar's play or pause and music note on a list's page, the
-- album's picture on the first page), in the order Settings lists them.
M.BUTTON_ACTIONS = {
    { id = "toggle", name = _("Play or pause") },
    { id = "controls", name = _("Show player controls") },
    { id = "player", name = _("Go to the player") },
    { id = "fullscreen", name = _("Full screen") },
    { id = "next", name = _("Next") },
    { id = "previous", name = _("Previous") },
    { id = "queue", name = _("Queue") },
    { id = "menu", name = _("Song menu") },
    { id = "none", name = _("Nothing") },
}
-- The buttons that can be set, what each does to start with, and its name in Settings.
M.BUTTONS = {
    { key = "play_tap", default = "controls", name = _("Play or pause: tap") },
    { key = "play_hold", default = "toggle", name = _("Play or pause: hold") },
    { key = "note_tap", default = "player", name = _("Music note: tap") },
    { key = "note_hold", default = "fullscreen", name = _("Music note: hold") },
    { key = "art_tap", default = "fullscreen", name = _("Album art: tap") },
    { key = "art_hold", default = "menu", name = _("Album art: hold") },
}

function M.actionName(id)
    for __, a in ipairs(M.BUTTON_ACTIONS) do if a.id == id then return a.name end end
    return ""
end

--- What a button does: the saved choice when it's one of the actions, else its own default.
function M.buttonAction(key, saved)
    for __, a in ipairs(M.BUTTON_ACTIONS) do if a.id == saved then return saved end end
    for __, b in ipairs(M.BUTTONS) do if b.key == key then return b.default end end
    return "none"
end

M.INTERVALS = { 5, 10, 15, 30, 60 }
M.INTERVAL = 10
M.VOLUME_STEPS = { 2, 5, 10 }
M.VOLUME_STEP = 5

function M.interval(v)
    v = tonumber(v) or M.INTERVAL
    return math.max(5, math.min(60, math.floor(v)))
end

--- How often the full screen is read: its own number of seconds, or the app's (0 or nothing).
function M.playerInterval(v, app)
    v = tonumber(v) or 0
    if v <= 0 then return app end
    return M.interval(v)
end

function M.intervalName(s)
    if s < 60 then return T(_("%1 seconds"), s) end
    return _("1 minute")
end

return M
