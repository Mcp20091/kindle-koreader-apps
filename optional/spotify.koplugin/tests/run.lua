-- Plain tests for spmodel and spapi (no KOReader): luajit tests/run.lua
package.path = "./?.lua;" .. package.path

-- spapi's JSON: answers by their text (the stand-in network below sends these keys).
local ANSWERS = {}
package.preload.json = function()
    local function enc(v)
        if type(v) ~= "table" then return tostring(v) end
        if #v > 0 then
            local parts = {}
            for i, x in ipairs(v) do parts[i] = enc(x) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k, x in pairs(v) do keys[#keys + 1] = k .. "=" .. enc(x) end
        table.sort(keys)
        return "{" .. table.concat(keys, ",") .. "}"
    end
    return {
        encode = enc,
        decode = function(s)
            if ANSWERS[s] == nil then error("not JSON") end
            return ANSWERS[s]
        end,
    }
end

local M = require("spmodel")
local API = require("spapi")

local passed, failed = 0, 0
local function eq(got, want, what)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- ------------------------------------------------------------------ requests and the sign-in
eq(M.query({ q = "a b", limit = 6 }), "limit=6&q=a%20b", "query")
eq(M.masked("0123456789abcdef0123456789abcdef"), "••••••••••••ef", "masked")
eq(M.cleanClientId(" 0123456789ABCDEF0123456789abcdef "), "0123456789abcdef0123456789abcdef", "client id: trimmed, lower case")
eq(M.cleanClientId("0123"), nil, "client id: too short")
eq(M.cleanClientId("0123456789abcdef0123456789abcdeg"), nil, "client id: not hex")
eq(M.base64url("\251\255\254"), "-__-", "base64url: its own letters")
eq(M.base64url("a"), "YQ", "base64url: no padding (1)")
eq(M.base64url("ab"), "YWI", "base64url: no padding (2)")
eq(M.base64url("abc"), "YWJj", "base64url: 3 bytes")
eq(#M.verifier(string.rep("x", 48)), 64, "verifier: 64 characters")
eq(M.challenge("v", function(s) return s .. "ab" end), "dmFi", "challenge: the hash, base64url")
-- (the real hash, when KOReader's sha2 is at hand: RFC 7636's example)
local okSha, sha2 = pcall(require, "ffi/sha2")
if okSha then
    local function sha256(s) return (sha2.sha256(s):gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end
    eq(M.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", sha256), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "challenge: RFC 7636")
end
local url = M.authorizeUrl("abc", "CHAL", "st1")
eq(url:match("^https://accounts%.spotify%.com/authorize%?") ~= nil, true, "authorize: the address")
eq(url:find("redirect_uri=http%3A%2F%2F127.0.0.1%3A8888%2Fcallback", 1, true) ~= nil, true, "authorize: the redirect")
eq(url:find("code_challenge=CHAL&code_challenge_method=S256", 1, true) ~= nil, true, "authorize: PKCE")
eq(url:find("user-modify-playback-state", 1, true) ~= nil, true, "authorize: the scopes")
eq(url:find("client_secret", 1, true), nil, "authorize: no secret")
eq(M.parseCallback("http://127.0.0.1:8888/callback?code=AQB_x-1&state=st1", "st1"), "AQB_x-1", "callback: the address")
eq(M.parseCallback("  127.0.0.1:8888/callback?state=st1&code=AQB%2D2  ", "st1"), "AQB-2", "callback: any order, decoded")
eq(M.parseCallback("AQB_x-1", "st1"), "AQB_x-1", "callback: the code alone")
eq(select(2, M.parseCallback("http://127.0.0.1:8888/callback?code=A&state=other", "st1")), "state", "callback: another sign-in's")
eq(select(2, M.parseCallback("http://127.0.0.1:8888/callback?error=access_denied&state=st1", "st1")), "denied", "callback: cancelled")
eq(select(2, M.parseCallback("http://127.0.0.1:8888/callback?state=st1", "st1")), "nocode", "callback: no code")
eq(select(2, M.parseCallback("", "st1")), "empty", "callback: nothing")
eq(select(2, M.parseCallback("not a code!", "st1")), "nocode", "callback: something else")

local t = M.tokens({ access_token = "A1", refresh_token = "R2", expires_in = 3600, scope = "s" }, 1000, { refresh_token = "R1" })
eq(t.refresh_token, "R2", "tokens: the new refresh token")
eq(t.expires_at, 4600, "tokens: when it runs out")
eq(M.tokens({ access_token = "A1", expires_in = 3600 }, 1000, { refresh_token = "R1" }).refresh_token, "R1", "tokens: the old refresh token kept")
eq(M.tokens({}, 1000), nil, "tokens: none")
eq(M.fresh(t, 4000), true, "fresh")
eq(M.fresh(t, 4550), false, "fresh: under a minute left")
eq(M.fresh(nil, 0), false, "fresh: none")

-- ------------------------------------------------------------------ why it failed
eq(M.whyOf(401, {}), "signin", "why: 401")
eq(M.whyOf(403, { error = { status = 403, message = "Player command failed: Premium required", reason = "PREMIUM_REQUIRED" } }), "premium", "why: no Premium")
eq(M.whyOf(404, { error = { status = 404, message = "Player command failed: No active device found", reason = "NO_ACTIVE_DEVICE" } }), "nodevice", "why: no active device")
eq(M.whyOf(404, { error = { status = 404, message = "Device not found" } }), "devicegone", "why: the device went")
eq(M.whyOf(403, { error = { status = 403, message = "Check settings on developer.spotify.com/dashboard, the user may not be registered." } }), "notlisted", "why: not on the user list")
eq(M.whyOf(403, { error = { status = 403, message = "Player command failed: Restriction violated", reason = "UNKNOWN" } }), "restricted", "why: not allowed now")
eq(M.whyOf(429, { status = 429, message = "Too many requests", reason = "QUOTA_EXCEEDED" }), "quota", "why: the quota")
eq(M.whyOf(429, nil), "busy", "why: too many")
eq(M.whyOf(503, nil), "down", "why: Spotify's trouble")
eq(M.whyOf(400, { error = { message = "Invalid context uri" } }), "Invalid context uri", "why: Spotify's words")
eq(M.whyOf(500, nil), "HTTP 500", "why: a status")
eq(M.whyToken(400, { error = "invalid_grant", error_description = "Refresh token revoked" }), "signin", "token: sign in again")
eq(M.whyToken(400, { error = "invalid_client" }), "clientid", "token: the Client ID")
eq(M.whyToken(400, { error = "invalid_request", error_description = "code_verifier was incorrect" }), "code_verifier was incorrect", "token: its words")
for __, w in ipairs({ "signin", "premium", "notlisted", "clientid", "nodevice", "devicegone", "restricted", "quota", "busy", "down",
    "notapi", "offline", "notset", "signedout", "denied", "state", "nocode", "timeout", "host not found", "certificate verify failed", "" }) do
    eq(M.whyText(w) ~= w and #M.whyText(w) > 8, true, "plain words for " .. w)
end
eq(M.whyText("Invalid context uri"), "Invalid context uri", "words: Spotify's own stay")

-- ------------------------------------------------------------------ devices
local devs = M.devices({ devices = {
    { id = "d3", name = "Old TV", type = "TV", is_active = false, is_restricted = true, volume_percent = 30 },
    { id = "d2", name = "Kitchen speaker", type = "Speaker", is_active = false, is_restricted = false, volume_percent = 40, supports_volume = true },
    { id = "d1", name = "Laptop", type = "Computer", is_active = true, is_restricted = false, volume_percent = 65, supports_volume = true },
    { id = "d4", name = "Den speaker", type = "Speaker", is_active = false, is_restricted = false, supports_volume = false },
} })
eq(devs[1].name, "Laptop", "devices: the active one first")
eq(devs[2].name .. "," .. devs[3].name, "Den speaker,Kitchen speaker", "devices: then by name")
eq(devs[4].name, "Old TV", "devices: the restricted one last")
eq(devs[4].usable, false, "devices: restricted takes no commands")
eq(devs[2].supportsVolume, false, "devices: one that sets its own volume")
eq(M.deviceIcon("Computer"), "laptop", "device icon")
eq(M.deviceIcon("Something new"), "speaker", "device icon: unknown")
eq(M.deviceLine(devs[3]), "Speaker · 40%", "device line")
eq(M.deviceLine(devs[4]), "TV · Unavailable", "device line: restricted")
eq(M.pickDevice(devs, nil).id, "d1", "pick: the active one")
local idle = M.devices({ devices = {
    { id = "d2", name = "Kitchen speaker", type = "Speaker" }, { id = "d5", name = "Phone", type = "Smartphone" },
    { id = "d3", name = "Old TV", type = "TV", is_restricted = true } } })
eq(M.pickDevice(idle, "d5").id, "d5", "pick: the one used last")
eq(select(2, M.pickDevice(idle, "gone")), "choose", "pick: several, ask")
eq(select(2, M.pickDevice(idle, "d3")), "choose", "pick: never a restricted one")
eq(M.pickDevice({ idle[1], idle[3] }, nil).id, "d2", "pick: the only usable one")
eq(select(2, M.pickDevice({ idle[3] }, nil)), "none", "pick: nothing usable")
eq(select(2, M.pickDevice({}, nil)), "none", "pick: nothing on")
eq(#M.devices(nil), 0, "devices: none")

-- devices seen before (Spotify lists one only while it's connected)
local seen, changed = M.noteSeen(nil, devs, 1000)
eq(changed, true, "seen: new devices")
eq(seen.d1.name, "Laptop", "seen: kept by id")
eq(seen.d3, nil, "seen: not a restricted one")
eq(select(2, M.noteSeen(seen, devs, 2000)), false, "seen: nothing new, nothing to save")
eq(#M.seenList(seen, devs), 0, "seen: none while they're all on")
local gone = M.seenList(seen, { devs[1] })
eq(#gone, 2, "seen: the ones not on now")
eq(gone[1].name .. "," .. gone[2].name, "Den speaker,Kitchen speaker", "seen: by name")
local many = {}
for i = 1, 15 do many[i] = { id = "m" .. i, name = "Speaker " .. i, type = "Speaker", usable = true } end
local kept = M.noteSeen({ old = { name = "Old one", type = "Speaker", time = 5 } }, many, 3000)
local n = 0
for __ in pairs(kept) do n = n + 1 end
eq(n, 12, "seen: the newest 12")
eq(kept.old, nil, "seen: the oldest dropped")
eq(#M.seenList(nil, nil), 0, "seen: nothing saved")

-- ------------------------------------------------------------------ what's playing
local NULL = function() end   -- (as JSON's null comes back: not a string, number or table)
local raw = {
    device = { id = "d1", name = "Laptop", type = "Computer", is_active = true, is_restricted = false, volume_percent = 65, supports_volume = true },
    is_playing = true, progress_ms = 62000, shuffle_state = true, repeat_state = "context",
    context = { uri = "spotify:playlist:pl1", type = "playlist" }, currently_playing_type = "track",
    item = { name = "Morning Song", uri = "spotify:track:t1", duration_ms = 187000,
        artists = { { name = "The Examples" }, { name = "Pat Doe" } },
        album = { name = "First Light", images = { { url = "https://i.scdn.co/image/ab67616d0000b273aaaa", width = 640 },
            { url = "https://i.scdn.co/image/ab67616d00001e02aaaa", width = 300 }, { url = "https://i.scdn.co/image/ab67616d00004851aaaa", width = 64 } } } },
    actions = { disallows = { skipping_prev = true, resuming = true } },
}
local p = M.player(raw, 1000)
eq(p.title, "Morning Song", "player: title")
eq(p.artist, "The Examples, Pat Doe", "player: artists")
eq(p.album, "First Light", "player: album")
eq(p.art, "https://i.scdn.co/image/ab67616d00001e02aaaa", "player: the 300 pixel picture")
eq(M.artFile(p.art), "ab67616d00001e02aaaa.jpg", "art: its file")
eq(M.artFile(""), nil, "art: none")
eq(p.shuffle, true, "player: shuffle")
eq(p["repeat"], "context", "player: repeat")
eq(p.device.volume, 65, "player: volume")
eq(p.disallows.skipping_prev, true, "player: what's not allowed")
eq(M.progressNow(p, 1010), 72000, "progress: goes on while playing")
eq(M.progressNow(p, 9999), 187000, "progress: not past the end")
eq(M.endsIn(p, 1100), 25, "ends in")
p.playing = false
eq(M.progressNow(p, 1010), 62000, "progress: stays while paused")
eq(M.endsIn(p, 1010), nil, "ends in: paused")
eq(M.player(nil), nil, "player: nothing")
eq(M.player({}), nil, "player: an empty answer")
local ad = M.player({ device = raw.device, is_playing = true, currently_playing_type = "ad", item = NULL, context = NULL, progress_ms = NULL }, 0)
eq(ad.title, "Advertisement", "player: an ad")
eq(ad.duration, 0, "player: null fields")
local ep = M.player({ device = raw.device, is_playing = true, currently_playing_type = "episode",
    item = { name = "Episode 12", uri = "spotify:episode:e1", duration_ms = 1800000, show = { name = "The Example Show" },
        images = { { url = "https://i.scdn.co/image/eeee", width = 300 } } } }, 0)
eq(ep.artist, "The Example Show", "player: an episode's show")
eq(ep.art, "https://i.scdn.co/image/eeee", "player: an episode's picture")
eq(M.time(187000), "3:07", "time")
eq(M.time(3723000), "1:02:03", "time: hours")
eq(M.time(nil), "0:00", "time: none")
eq(M.nextRepeat("off") .. M.nextRepeat("context") .. M.nextRepeat("track"), "contexttrackoff", "repeat: round")
eq(M.repeatName("track"), "Repeat one", "repeat: name")
eq(M.volumeStep(98, 5), 100, "volume: not over 100")
eq(M.volumeStep(3, -5), 0, "volume: not under 0")
eq(M.volumeStep(40, 5), 45, "volume: a step")
p.playing = true
eq(M.songLine(p), "Morning Song · The Examples, Pat Doe", "song line")
eq(M.appsLine(p, 1100, true), "Morning Song · The Examples, Pat Doe", "tile: playing, read lately")
eq(M.appsLine(p, 5000, true), "", "tile: read long ago, nothing")
eq(M.appsLine(nil, 0, false), "Not set up", "tile: not set up")
eq(M.interval(1), 5, "interval: not under 5")
eq(M.interval(nil), 10, "interval: 10 to start with")
eq(M.intervalName(60), "1 minute", "interval name")

-- ------------------------------------------------------------------ things to start
local pls = M.playlists({ { uri = "spotify:playlist:pl1", name = "Road trip", owner = { display_name = "Pat" }, items = { total = 42 } },
    NULL, { uri = "spotify:playlist:pl2", name = "", owner = {}, tracks = { total = 1 } } })
eq(#pls, 2, "playlists: empty entries left out")
eq(M.playlistLine(pls[1]), "Pat · 42 songs", "playlist line")
eq(M.playlistLine(pls[2]), "1 song", "playlist line: one song, no owner")
eq(pls[2].name, "Playlist", "playlist: no name")
eq(M.search(pls, "road")[1].uri, "spotify:playlist:pl1", "search: a playlist by name")
eq(#M.search(pls, ""), 0, "search: nothing typed")
local rec = M.recent({
    { track = { uri = "spotify:track:t1", name = "Morning Song", artists = { { name = "The Examples" } } }, context = { type = "playlist", uri = "spotify:playlist:pl1" } },
    { track = { uri = "spotify:track:t2", name = "Second Song", artists = {} }, context = { type = "artist", uri = "spotify:artist:a1" } },
    { track = { uri = "spotify:track:t1", name = "Morning Song", artists = {} }, context = NULL },
    { track = NULL },
})
eq(#rec, 2, "recent: each song once")
eq(rec[1].context, "spotify:playlist:pl1", "recent: its playlist")
eq(rec[2].context, nil, "recent: an artist isn't somewhere to go on from")
local found = M.searchResults({ tracks = { items = { { uri = "spotify:track:t1", name = "Morning Song", artists = { { name = "The Examples" } } } } },
    albums = { items = { { uri = "spotify:album:al1", name = "First Light", artists = { { name = "The Examples" } } } } },
    playlists = { items = { NULL, { uri = "spotify:playlist:pl9", name = "Morning mix", owner = { display_name = "Sam" } } } },
    artists = { items = { { uri = "spotify:artist:a1", name = "The Examples" } } } })
eq(found.count, 4, "search results: counted")
eq(found.albums[1].sub, "The Examples", "search results: an album's artist")
eq(found.playlists[1].sub, "Sam", "search results: a playlist's owner")
eq(M.searchResults(nil).count, 0, "search results: none")

-- ------------------------------------------------------------------ the API, against a stand-in network
ANSWERS['{"token"}'] = { access_token = "A2", refresh_token = "R2", expires_in = 3600, scope = "s" }
ANSWERS['{"token-same"}'] = { access_token = "A3", expires_in = 3600 }
ANSWERS['{"revoked"}'] = { error = "invalid_grant", error_description = "Refresh token revoked" }
ANSWERS['{"player"}'] = raw
ANSWERS['{"devices"}'] = { devices = { { id = "d2", name = "Kitchen speaker", type = "Speaker" } } }
ANSWERS['{"two"}'] = { devices = { { id = "d2", name = "Kitchen speaker", type = "Speaker" }, { id = "d5", name = "Phone", type = "Smartphone" } } }
ANSWERS['{"nodevice"}'] = { error = { status = 404, message = "Player command failed: No active device found", reason = "NO_ACTIVE_DEVICE" } }
ANSWERS['{"premium"}'] = { error = { status = 403, message = "Player command failed: Premium required", reason = "PREMIUM_REQUIRED" } }
ANSWERS['{"playlists"}'] = { items = { { uri = "spotify:playlist:pl1", name = "Road trip" } }, next = NULL }
ANSWERS['{"recent"}'] = { items = { { track = { uri = "spotify:track:t1", name = "Morning Song" } } } }
ANSWERS['{"search"}'] = { tracks = { items = {} } }

local sent
local function net(routes)
    sent = {}
    return function(method, address, headers, body)
        table.insert(sent, { method = method, url = address, headers = headers, body = body })
        for __, r in ipairs(routes) do
            if (not r.method or r.method == method) and address:find(r.url) and (not r.when or r.when(#sent, headers, body)) then
                return r.status or 200, r.body or ""
            end
        end
        return 404, ""
    end
end
local function store(tokens)
    local s = { tokens = tokens, sets = 0 }
    s.get = function() return s.tokens end
    s.set = function(x) s.tokens, s.sets = x, s.sets + 1 end
    return s
end
local function new(routes, tokens, now)
    local st = store(tokens)
    local slept = {}
    local api = API.new{ clientId = "cid", tokens = st, request = net(routes), now = function() return now or 1000 end,
        sleep = function(s) slept[#slept + 1] = s end }
    return api, st, slept
end
local GOOD = { access_token = "A1", refresh_token = "R1", expires_at = 5000 }

-- the sign-in
local api, st = new({ { url = "/api/token$", body = '{"token"}' } }, nil)
eq(api:exchange("CODE", "VERIFIER") ~= nil, true, "exchange: tokens")
eq(sent[1].url, "https://accounts.spotify.com/api/token", "exchange: the token address")
eq(sent[1].body, "client_id=cid&code=CODE&code_verifier=VERIFIER&grant_type=authorization_code&redirect_uri=http%3A%2F%2F127.0.0.1%3A8888%2Fcallback", "exchange: PKCE, no secret")
eq(st.tokens.refresh_token, "R2", "exchange: kept")
eq(st.tokens.expires_at, 4600, "exchange: when it runs out")

-- a fresh token is used as it is
api, st = new({ { url = "/me/player%?", body = '{"player"}' } }, GOOD)
eq(api:player().is_playing, true, "player: read")
eq(sent[1].headers.Authorization, "Bearer A1", "the token's header")
eq(sent[1].url, "https://api.spotify.com/v1/me/player?additional_types=track%2Cepisode", "player: its address")
eq(#sent, 1, "no refresh while the token is good")

-- one that ran out is refreshed first, and the new refresh token kept
api, st = new({ { url = "/api/token$", body = '{"token"}' }, { url = "/me/player/devices$", body = '{"devices"}' } },
    { access_token = "A1", refresh_token = "R1", expires_at = 1010 })
eq(#api:devices().devices, 1, "devices: read")
eq(sent[1].body, "client_id=cid&grant_type=refresh_token&refresh_token=R1", "refresh: asked first")
eq(sent[2].headers.Authorization, "Bearer A2", "refresh: the new token used")
eq(st.tokens.refresh_token, "R2", "refresh: the new refresh token kept")

-- Spotify keeps the same refresh token: it stays
api, st = new({ { url = "/api/token$", body = '{"token-same"}' } }, { access_token = "A1", refresh_token = "R1", expires_at = 0 })
eq(api:token(), "A3", "refresh: a new access token")
eq(st.tokens.refresh_token, "R1", "refresh: the old refresh token stays")

-- a 401 from the API: refreshed once, sent again
api, st = new({ { url = "/api/token$", body = '{"token"}' },
    { url = "/me/player/devices$", status = 401, when = function(__, headers) return headers.Authorization == "Bearer A1" end },
    { url = "/me/player/devices$", body = '{"devices"}' } }, GOOD)
eq(api:devices() ~= nil, true, "401: sent again with a new token")
eq(#sent, 3, "401: one refresh, one more try")

-- the sign-in is no longer good
api, st = new({ { url = "/api/token$", status = 400, body = '{"revoked"}' } }, { access_token = "A1", refresh_token = "R1", expires_at = 0 })
eq(select(2, api:player()), "signin", "revoked: sign in again")
eq(st.sets, 0, "revoked: the tokens aren't touched")
-- …unless another process used the refresh token first: its tokens are the ones
api, st = new({ { url = "/api/token$", status = 400, body = '{"revoked"}', when = function() return true end } }, { access_token = "A1", refresh_token = "R1", expires_at = 0 })
local gets = 0
st.get = function()
    gets = gets + 1
    if gets >= 3 then return { access_token = "A9", refresh_token = "R9", expires_at = 9000 } end
    return st.tokens
end
eq(api:token(), "A9", "refresh: the tokens another process kept")

eq(select(2, new({}, nil):player()), "signedout", "no tokens: signed out")
eq(select(2, new({ { url = "/me/player", status = "timeout" } }, GOOD):player()), "timeout", "the network's words")
eq(select(2, new({ { url = "/me/player", body = "<html>" } }, GOOD):player()), "notapi", "html: not the API")
eq(new({ { url = "/me/player%?", status = 204 } }, GOOD):player(), false, "204: nothing playing")

-- reading: the devices too when nothing is playing
api = new({ { url = "/me/player%?", status = 204 }, { url = "/me/player/devices$", body = '{"devices"}' } }, GOOD)
local r = api:read(false)
eq(r.player, false, "read: nothing playing")
eq(#r.devices.devices, 1, "read: the devices then")
api = new({ { url = "/me/player%?", body = '{"player"}' } }, GOOD)
eq(api:read(false).devices, nil, "read: no devices unless asked")

-- commands
api = new({ { method = "PUT", url = "/me/player/", status = 204 }, { method = "POST", url = "/me/player/", status = 204 } }, GOOD)
eq(api:pause(), true, "pause")
eq(sent[#sent].method .. " " .. sent[#sent].url, "PUT https://api.spotify.com/v1/me/player/pause", "pause: its request")
api:next()
eq(sent[#sent].method .. " " .. sent[#sent].url, "POST https://api.spotify.com/v1/me/player/next", "next")
api:previous()
eq(sent[#sent].url, "https://api.spotify.com/v1/me/player/previous", "previous")
api:seek(62000.7)
eq(sent[#sent].url, "https://api.spotify.com/v1/me/player/seek?position_ms=62000", "seek")
api:volume(45)
eq(sent[#sent].url, "https://api.spotify.com/v1/me/player/volume?volume_percent=45", "volume")
api:shuffle(true)
eq(sent[#sent].url, "https://api.spotify.com/v1/me/player/shuffle?state=true", "shuffle")
api:setRepeat("track")
eq(sent[#sent].url, "https://api.spotify.com/v1/me/player/repeat?state=track", "repeat")
api:queue("spotify:track:t1")
eq(sent[#sent].method .. " " .. sent[#sent].url, "POST https://api.spotify.com/v1/me/player/queue?uri=spotify%3Atrack%3At1", "queue")
api = new({ { method = "PUT", url = "/me/player$", status = 204 } }, GOOD)
api:transfer("d2", true)
eq(sent[1].body, "{device_ids=[d2],play=true}", "transfer: its body")

-- play on the active device: one request
api = new({ { method = "PUT", url = "/me/player/play$", status = 204 } }, GOOD)
eq(api:startAnywhere({ context_uri = "spotify:playlist:pl1" }, nil, "d2"), true, "play: on the active device")
eq(#sent, 1, "play: one request")
eq(sent[1].body, "{context_uri=spotify:playlist:pl1}", "play: what to play")

-- nothing active: playback is moved to the only device first, then play there
local slept
api, st, slept = new({
    { method = "PUT", url = "/me/player/play$", status = 404, body = '{"nodevice"}' },
    { url = "/me/player/devices$", body = '{"devices"}' },
    { method = "PUT", url = "/me/player$", status = 204 },
    { method = "PUT", url = "/me/player/play%?device_id=d2$", status = 204 },
}, GOOD)
eq(api:startAnywhere(nil, nil, nil), true, "idle device: play works")
eq(sent[3].method .. " " .. sent[3].url .. " " .. sent[3].body, "PUT https://api.spotify.com/v1/me/player {device_ids=[d2],play=false}", "idle device: transfer first")
eq(sent[4].url, "https://api.spotify.com/v1/me/player/play?device_id=d2", "idle device: then play there")
eq(#slept, 1, "idle device: a moment for it to wake")

-- it takes a second try
api = new({
    { method = "PUT", url = "/me/player$", status = 204 },
    { method = "PUT", url = "/me/player/play%?device_id=d2$", status = 404, body = '{"nodevice"}', when = function(n) return n == 2 end },
    { method = "PUT", url = "/me/player/play%?device_id=d2$", status = 204 },
}, GOOD)
eq(api:startOn("d2", nil), true, "idle device: the second try")
eq(#sent, 3, "idle device: transfer, play, play")

-- several devices and none used before: ask; the one used last: there
local two = {
    { method = "PUT", url = "/me/player/play$", status = 404, body = '{"nodevice"}' },
    { url = "/me/player/devices$", body = '{"two"}' },
    { method = "PUT", url = "/me/player$", status = 204 },
    { method = "PUT", url = "/me/player/play%?device_id=d5$", status = 204 },
}
eq(select(2, new(two, GOOD):startAnywhere(nil, nil, nil)), "choose", "several devices: ask which")
eq(new(two, GOOD):startAnywhere(nil, nil, "d5"), true, "several devices: the one used last")
eq(new(two, GOOD):startAnywhere(nil, "d5", nil), true, "several devices: the one picked")
ANSWERS['{"none"}'] = { devices = {} }
eq(select(2, new({ two[1], { url = "/me/player/devices$", body = '{"none"}' } }, GOOD):startAnywhere(nil, nil, nil)), "nodevice", "no devices")
eq(select(2, new({ { method = "PUT", url = "/me/player/play$", status = 403, body = '{"premium"}' } }, GOOD):startAnywhere(nil, nil, nil)), "premium", "no Premium")

-- lists
api = new({ { url = "/me/playlists%?", body = '{"playlists"}' }, { url = "recently%-played", body = '{"recent"}' }, { url = "/search%?", body = '{"search"}' } }, GOOD)
eq(#api:playlists(), 1, "playlists")
eq(sent[1].url, "https://api.spotify.com/v1/me/playlists?limit=50&offset=0", "playlists: its address")
eq(#api:recent(), 1, "recent")
eq(sent[2].url, "https://api.spotify.com/v1/me/player/recently-played?limit=30", "recent: its address")
api:search("morning song")
eq(sent[3].url, "https://api.spotify.com/v1/search?limit=6&q=morning%20song&type=track%2Calbum%2Cplaylist%2Cartist", "search: at most 10 of each")

-- liking, playlists' changes, the queue and the library
ANSWERS['[true]'] = { true }
ANSWERS['[false]'] = { false }
ANSWERS['{"me"}'] = { id = "pat1", display_name = "Pat" }
ANSWERS['{"queue"}'] = { currently_playing = { uri = "spotify:track:t1", name = "Morning Song" },
    queue = { { uri = "spotify:track:t2", name = "Second Song", artists = { { name = "Sam Roe" } } } } }
ANSWERS['{"saved"}'] = { items = { { added_at = "2026-11-01T10:00:00Z", track = { uri = "spotify:track:t1", name = "Morning Song",
    album = { uri = "spotify:album:al1", name = "First Light" }, artists = { { uri = "spotify:artist:a1", name = "The Examples" } } } } } }
ANSWERS['{"albums"}'] = { items = { { album = { uri = "spotify:album:al1", name = "First Light", artists = { { uri = "spotify:artist:a1", name = "The Examples" } } } } } }
ANSWERS['{"following"}'] = { artists = { items = { { uri = "spotify:artist:a2", name = "Sam Roe" }, { uri = "spotify:artist:a1", name = "The Examples" } } } }
ANSWERS['{"albumsongs"}'] = { items = { { uri = "spotify:track:t1", name = "Morning Song", artists = { { name = "The Examples" } } } } }
ANSWERS['{"artistalbums"}'] = { items = { { uri = "spotify:album:al1", name = "First Light", release_date = "2024-03-01" },
    { uri = "spotify:album:al1", name = "First Light", release_date = "2024-03-01" } } }
ANSWERS['{"badlimit"}'] = { error = { status = 400, message = "Invalid limit" } }
ANSWERS['{"scope"}'] = { error = { status = 403, message = "Insufficient client scope" } }
api = new({
    { method = "GET", url = "/me/library/contains", body = '[true]' },
    { url = "/me/library%?", status = 200 },
    { method = "POST", url = "/playlists/pl1/items$", status = 201, body = '{"token"}' },
    { method = "DELETE", url = "/playlists/pl1/items$", body = '{"token"}' },
    { url = "/me/player/queue$", body = '{"queue"}' },
    { url = "/me/tracks%?", body = '{"saved"}' },
    { url = "/me/albums%?", body = '{"albums"}' },
    { url = "/me/following%?", body = '{"following"}' },
    { url = "/albums/al1/tracks", body = '{"albumsongs"}' },
    { url = "/artists/a1/albums", body = '{"artistalbums"}' },
    { url = "/me$", body = '{"me"}' },
}, GOOD)
eq(api:liked("spotify:track:t1"), true, "liked: yes")
eq(sent[#sent].url, "https://api.spotify.com/v1/me/library/contains?uris=spotify%3Atrack%3At1", "liked: its address")
eq(api:like("spotify:track:t1", true), true, "like")
eq(sent[#sent].method .. " " .. sent[#sent].url, "PUT https://api.spotify.com/v1/me/library?uris=spotify%3Atrack%3At1", "like: saved to the library")
api:like("spotify:track:t1", false)
eq(sent[#sent].method, "DELETE", "unlike: taken out")
eq(api:addToPlaylist("pl1", "spotify:track:t1") ~= nil, true, "add to a playlist")
eq(sent[#sent].method .. " " .. sent[#sent].body, "POST {uris=[spotify:track:t1]}", "add: its body")
eq(api:removeFromPlaylist("pl1", "spotify:track:t1") ~= nil, true, "remove from a playlist")
eq(sent[#sent].method .. " " .. sent[#sent].body, "DELETE {items=[{uri=spotify:track:t1}]}", "remove: its body")
eq(api:me().id, "pat1", "who signed in")
local q = M.queue(api:queueList())
eq(q.now.title, "Morning Song", "queue: now")
eq(#q.next .. q.next[1].artist, "1Sam Roe", "queue: next")
eq(#M.queue(nil).next, 0, "queue: none")
local saved = M.songs(api:likedSongs(), M.likedContext("pat1"))
eq(saved[1].context, "spotify:user:pat1:collection", "liked songs: played from Liked Songs")
eq(saved[1].albumUri .. " " .. saved[1].artistUri, "spotify:album:al1 spotify:artist:a1", "a song knows its album and artist")
eq(M.likedContext(nil), nil, "liked songs: not without the id")
local lib = api:library()
eq(M.albums(lib.albums)[1].sub, "The Examples", "library: an album's artist")
eq(M.artistList(lib.artists)[1].name, "Sam Roe", "library: artists by name")
local songs = M.songs(api:albumSongs("al1"), "spotify:album:al1", { uri = "spotify:album:al1", name = "First Light" })
eq(songs[1].context .. " " .. songs[1].album, "spotify:album:al1 First Light", "album: its songs, played in it")
local theirs = M.albums(api:artistAlbums("a1"), true)
eq(#theirs .. theirs[1].sub, "12024", "artist: albums once each, with the year")
eq(M.liked == nil and new({ { url = "contains", body = '[false]' } }, GOOD):liked("spotify:track:t9"), false, "liked: no")
eq(select(2, new({ { url = "contains", status = 403, body = '{"scope"}' } }, GOOD):liked("spotify:track:t9")), "scope", "an older sign-in: not allowed")
-- (fewer albums asked for when Spotify refuses the number)
api = new({ { url = "limit=20", status = 400, body = '{"badlimit"}' }, { url = "limit=10", body = '{"artistalbums"}' } }, GOOD)
eq(#api:artistAlbums("a1"), 2, "artist: asked again for fewer")

-- whose playlists can be changed; what a sign-in covers
local mine = M.ownPlaylists(M.playlists({
    { uri = "spotify:playlist:p1", name = "Mine", owner = { id = "pat1", display_name = "Pat" } },
    { uri = "spotify:playlist:p2", name = "Theirs", owner = { id = "sam2", display_name = "Sam" } },
    { uri = "spotify:playlist:p3", name = "Shared", owner = { id = "sam2" }, collaborative = true } }), "pat1")
eq(#mine .. mine[1].name .. mine[2].name, "2MineShared", "own playlists: yours and the collaborative ones")
eq(#M.ownPlaylists({ { ownerId = "", collaborative = false } }, ""), 0, "own playlists: none without the id")
eq(M.id("spotify:playlist:p1"), "p1", "id of a URI")
eq(M.scopesCover(M.SCOPES), true, "scopes: a new sign-in covers it")
eq(M.scopesCover("user-read-playback-state user-modify-playback-state"), false, "scopes: an older one doesn't")
eq(M.scopesCover(nil), true, "scopes: not known")
eq(#M.whyText("scope") > 8, true, "plain words for scope")
eq(M.playerInterval(0, 10), 10, "full screen: the same as the app")
eq(M.playerInterval(30, 10), 30, "full screen: its own")
eq(M.playerInterval(nil, 15), 15, "full screen: not set")
-- a song moved in a playlist of yours
eq(table.concat({ M.reorder(1, 10) }, ","), "0,10", "reorder: the first to the end of ten")
eq(table.concat({ M.reorder(10, 1) }, ","), "9,0", "reorder: the last to the start")
eq(table.concat({ M.reorder(3, 4) }, ","), "2,4", "reorder: down one")
eq(table.concat({ M.reorder(3, 2) }, ","), "2,1", "reorder: up one")
local order = { "a", "b", "c", "d" }
eq(M.moveInList(order, 3, 1), true, "move in a list")
eq(table.concat(order), "cabd", "move: to the top")
M.moveInList(order, 1, 4)
eq(table.concat(order), "abdc", "move: to the bottom")
eq(M.moveInList(order, 2, 2), false, "move: nowhere")
eq(M.moveInList(order, 9, 1), false, "move: not in the list")
ANSWERS['{"plsongs"}'] = { items = { { item = { uri = "spotify:track:t1", name = "Morning Song" } }, { track = { uri = "spotify:track:t2", name = "Second Song" } } } }
api = new({ { method = "GET", url = "/playlists/pl1/items%?", body = '{"plsongs"}' }, { method = "PUT", url = "/playlists/pl1/items$", body = '{"token"}' } }, GOOD)
local pls1 = M.songs(api:playlistSongs("pl1"), "spotify:playlist:pl1")
eq(#pls1 .. pls1[1].title .. pls1[2].title, "2Morning SongSecond Song", "a playlist's songs (item, or track as before)")
eq(pls1[1].context, "spotify:playlist:pl1", "a playlist's songs: played in it")
eq(api:reorder("pl1", 2, 1) ~= nil, true, "reorder")
eq(sent[#sent].method .. " " .. sent[#sent].body, "PUT {insert_before=0,range_length=1,range_start=1}", "reorder: its body")

-- what a button does: the saved choice, else its own default
eq(M.buttonAction("play_tap", nil), "controls", "button: its default")
eq(M.buttonAction("note_tap", "queue"), "queue", "button: the saved choice")
eq(M.buttonAction("note_hold", "something else"), "fullscreen", "button: a choice that isn't one")
eq(M.buttonAction("no such button", nil), "none", "button: not one")
eq(M.actionName("fullscreen"), "Full screen", "action: its name")
for __, b in ipairs(M.BUTTONS) do eq(M.actionName(b.default) ~= "", true, "button " .. b.key .. ": a default that exists") end

-- the album's picture: no token goes to the picture server
api = new({ { url = "i%.scdn%.co", body = "JPEGBYTES" } }, GOOD)
local tmp = os.tmpname()
eq(api:art("https://i.scdn.co/image/aaaa", tmp), true, "art: saved")
eq(sent[1].headers.Authorization, nil, "art: no token")
local f = io.open(tmp, "rb")
eq(f and f:read("*a"), "JPEGBYTES", "art: the bytes")
if f then f:close() end
os.remove(tmp)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
