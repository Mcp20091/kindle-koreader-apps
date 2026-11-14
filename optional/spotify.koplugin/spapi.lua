--[[--
Spotify's Web API (https://api.spotify.com/v1) and its sign-in
(https://accounts.spotify.com): JSON over HTTPS with the access token sent as
`Authorization: Bearer`. The sign-in is Authorization Code with PKCE: no
client secret, a code traded for an access token (good for an hour) and a
refresh token, which gets a new access token, and may itself be replaced
each time (the new one is kept).

Everything here blocks: it runs in a child process (spbg.lua), never on
KOReader's loop. The tokens are read from and written to their own store
(`tokens.get()`, `tokens.set(t)`: a file, so a child can keep a refreshed
token and the next child finds it).

Why something failed: spmodel's `whyOf` and `whyToken` ("signin", "premium",
"nodevice", "notlisted", "quota", "busy"…), "signedout" (no tokens), "notapi",
or the network's own words ("timeout", "connection refused"…).
]]

local JSON = require("json")

local M = require("spmodel")

local API = {}
API.__index = API

--- o: { clientId, tokens = { get, set }, request = (method, url, headers, body, timeout) ->
-- status or error, body (KOReader's socket.http by default; the tests pass their own),
-- now() (seconds), sleep(seconds) }.
function API.new(o)
    return setmetatable({ clientId = o.clientId, tokens = o.tokens, send = o.request or API.http,
        now = o.now or os.time, sleep = o.sleep or API.sleep }, API)
end

--- KOReader's network: (status or error, body). HTTPS through KOReader's luasec.
function API.http(method, url, headers, body, timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    local request = { url = url, method = method, headers = headers or {}, sink = ltn12.sink.table(sink) }
    if body then
        request.source = ltn12.source.string(body)
        request.headers["Content-Length"] = tostring(#body)
    elseif method ~= "GET" then
        -- (Spotify refuses a PUT or POST without a length)
        request.headers["Content-Length"] = "0"
    end
    timeout = timeout or 15
    socketutil:set_timeout(math.min(timeout, 8), timeout)
    local ok, code = pcall(function() return socket.skip(1, http.request(request)) end)
    socketutil:reset_timeout()
    if not ok then code = tostring(code) end
    return code, table.concat(sink)
end

function API.sleep(seconds)
    require("socket").sleep(seconds)
end

local function decode(text)
    if type(text) ~= "string" or text == "" then return nil end
    local ok, t = pcall(JSON.decode, text)
    return ok and type(t) == "table" and t or nil
end

-- ------------------------------------------------------------------ tokens

--- One request to the token address: the tokens kept, or nil and why.
function API:tokenRequest(fields, old)
    fields.client_id = self.clientId or ""
    local status, text = self.send("POST", M.ACCOUNTS .. "/api/token",
        { ["Content-Type"] = "application/x-www-form-urlencoded", Accept = "application/json" }, M.query(fields), 20)
    if type(status) ~= "number" then return nil, tostring(status or "no answer") end
    local t = decode(text)
    if status ~= 200 then return nil, M.whyToken(status, t) end
    local tokens = M.tokens(t, self.now(), old)
    if not tokens then return nil, "notapi" end
    self.tokens.set(tokens)
    return tokens
end

--- The sign-in's code traded for tokens (verifier: the one its challenge was made from).
function API:exchange(code, verifier)
    return self:tokenRequest({ grant_type = "authorization_code", code = code, redirect_uri = M.REDIRECT,
        code_verifier = verifier })
end

--- A new access token from the refresh token. When Spotify refuses it, another process may
-- have used it first: then the tokens it kept are the ones.
function API:refresh()
    local old = self.tokens.get()
    if type(old) ~= "table" or M.str(old.refresh_token) == "" then return nil, "signedout" end
    local tokens, why = self:tokenRequest({ grant_type = "refresh_token", refresh_token = old.refresh_token }, old)
    if tokens then return tokens end
    if why == "signin" then
        local now = self.tokens.get()
        if type(now) == "table" and now.refresh_token ~= old.refresh_token and M.fresh(now, self.now()) then return now end
    end
    return nil, why
end

--- The access token, refreshed when it's about to run out (or with force).
function API:token(force)
    local t = self.tokens.get()
    if type(t) ~= "table" or M.str(t.refresh_token) == "" then return nil, "signedout" end
    if not force and M.fresh(t, self.now()) then return t.access_token end
    local fresh, why = self:refresh()
    if not fresh then return nil, why end
    return fresh.access_token
end

-- ------------------------------------------------------------------ requests

local function looksLikeHtml(s)
    if type(s) ~= "string" then return false end
    local head = s:sub(1, 200):lower()
    return head:find("<!doctype html", 1, true) ~= nil or head:find("<html", 1, true) ~= nil
end

--- One request to path (after /v1): the answer as a table (true when there's none), or nil
-- and why. A refused token is refreshed once and the request sent again.
function API:request(method, path, params, body, timeout)
    local url = M.API .. path
    local q = params and M.query(params) or ""
    if q ~= "" then url = url .. "?" .. q end
    local data = body and JSON.encode(body) or nil
    local status, text
    for attempt = 1, 2 do
        local token, why = self:token(attempt == 2)
        if not token then return nil, why end
        local headers = { Authorization = "Bearer " .. token, Accept = "application/json" }
        if data then headers["Content-Type"] = "application/json" end
        status, text = self.send(method, url, headers, data, timeout)
        if status ~= 401 then break end
    end
    if type(status) ~= "number" then return nil, tostring(status or "no answer") end
    if status >= 200 and status < 300 then
        if (text or "") == "" then return true end
        local t = decode(text)
        -- (some commands answer 200 with a few words that aren't JSON)
        if not t then
            if looksLikeHtml(text) then return nil, "notapi" end
            return true
        end
        return t
    end
    if looksLikeHtml(text) then return nil, "notapi" end
    return nil, M.whyOf(status, decode(text))
end

-- ------------------------------------------------------------------ reading

--- What's playing (the API's answer; false when nothing is playing anywhere), or nil and why.
function API:player()
    local r, why = self:request("GET", "/me/player", { additional_types = "track,episode" })
    if not r then return nil, why end
    if r == true then return false end
    return r
end

--- The devices that are on: the API's { devices = { … } }, or nil and why.
function API:devices()
    return self:request("GET", "/me/player/devices")
end

--- What a page shows: { player (false: nothing playing), devices (when asked for, or when
-- nothing is playing) }, or nil and why.
function API:read(withDevices)
    local p, why = self:player()
    if p == nil then return nil, why end
    local out = { player = p }
    if withDevices or p == false then
        local d
        d, why = self:devices()
        if not d then return nil, why end
        out.devices = d
    end
    return out
end

--- The account's playlists (every page, at most 200): the API's items, or nil and why.
function API:playlists()
    local out = {}
    for page = 0, M.PLAYLIST_PAGES - 1 do
        local r, why = self:request("GET", "/me/playlists", { limit = M.PLAYLIST_PAGE, offset = page * M.PLAYLIST_PAGE })
        if not r then return nil, why end
        local items = type(r) == "table" and type(r.items) == "table" and r.items or {}
        for __, x in ipairs(items) do out[#out + 1] = x end
        if #items < M.PLAYLIST_PAGE or r.next == nil or type(r.next) ~= "string" then break end
    end
    return out
end

--- Recently played songs: the API's items, or nil and why.
function API:recent()
    local r, why = self:request("GET", "/me/player/recently-played", { limit = M.RECENT_LIMIT })
    if not r then return nil, why end
    return type(r) == "table" and type(r.items) == "table" and r.items or {}
end

--- A search for songs, albums, playlists and artists: the API's answer, or nil and why.
function API:search(q)
    return self:request("GET", "/search", { q = q, type = "track,album,playlist,artist", limit = M.SEARCH_LIMIT })
end

--- Who signed in: the API's { id, display_name }, or nil and why.
function API:me()
    return self:request("GET", "/me")
end

--- Whether a song (or album…) is in the library: true or false, or nil and why.
function API:liked(uri)
    local r, why = self:request("GET", "/me/library/contains", { uris = uri })
    if not r then return nil, why end
    return type(r) == "table" and r[1] == true
end

--- A song (or album…) saved to the library, or taken out of it.
function API:like(uri, on)
    if type(uri) == "table" then uri = table.concat(uri, ",") end   -- (several: at most 40)
    return self:request(on and "PUT" or "DELETE", "/me/library", { uris = uri })
end

--- A song added at the end of a playlist (id: the playlist's), or taken out of it.
function API:addToPlaylist(id, uri)
    return self:request("POST", "/playlists/" .. id .. "/items", nil, { uris = type(uri) == "table" and uri or { uri } })
end

function API:removeFromPlaylist(id, uri)
    local items = {}
    for __, u in ipairs(type(uri) == "table" and uri or { uri }) do items[#items + 1] = { uri = u } end
    return self:request("DELETE", "/playlists/" .. id .. "/items", nil, { items = items })
end

--- A playlist's songs (the first 200; Spotify lists them only for your own and collaborative
-- playlists): the API's entries, or nil and why.
function API:playlistSongs(id)
    local out = {}
    for page = 0, 3 do
        local items, why = self:page("/playlists/" .. id .. "/items", { limit = 50, offset = page * 50 })
        if not items then return nil, why end
        for __, x in ipairs(items) do out[#out + 1] = x end
        if #items < 50 then break end
    end
    return out
end

--- A song moved in a playlist: from and to are its place now and after (1 is the first).
function API:reorder(id, from, to)
    local start, before = M.reorder(from, to)
    return self:request("PUT", "/playlists/" .. id .. "/items", nil, { range_start = start, insert_before = before, range_length = 1 })
end

--- What plays next: the API's { currently_playing, queue }, or nil and why.
function API:queueList()
    return self:request("GET", "/me/player/queue")
end

--- One page of a list: its items (or nil and why). pick: the field of the answer that holds
-- the paging object (nil: the answer itself).
function API:page(path, params, pick)
    local r, why = self:request("GET", path, params)
    if not r then return nil, why end
    local p = type(r) == "table" and (pick and r[pick] or r) or {}
    return type(p) == "table" and type(p.items) == "table" and p.items or {}
end

--- Liked Songs, newest first (the first 100): the API's { track } items, or nil and why.
function API:likedSongs()
    local out = {}
    for page = 0, 1 do
        local items, why = self:page("/me/tracks", { limit = 50, offset = page * 50 })
        if not items then return nil, why end
        for __, x in ipairs(items) do out[#out + 1] = x end
        if #items < 50 then break end
    end
    return out
end

--- The library to browse: { albums = saved albums ({ album } items), artists = the followed
-- artists (the API's answer) }, or nil and why.
function API:library()
    local albums, why = self:page("/me/albums", { limit = 50 })
    if not albums then return nil, why end
    local artists
    artists, why = self:request("GET", "/me/following", { type = "artist", limit = 50 })
    if not artists then return nil, why end
    return { albums = albums, artists = artists }
end

--- An album's songs (the first 50): the API's tracks, or nil and why.
function API:albumSongs(id)
    return self:page("/albums/" .. id .. "/tracks", { limit = 50 })
end

--- An artist's albums and singles: the API's albums, or nil and why. (Fewer at a time when
-- Spotify refuses the number asked for.)
function API:artistAlbums(id)
    local items, why = self:page("/artists/" .. id .. "/albums", { include_groups = "album,single", limit = 20 })
    if not items and tostring(why):lower():find("limit", 1, true) then
        items, why = self:page("/artists/" .. id .. "/albums", { include_groups = "album,single", limit = 10 })
    end
    return items, why
end

--- A picture saved to path: true, or nil and why. (No token: it's Spotify's picture server.)
function API:art(url, path)
    local status, bytes = self.send("GET", url, {}, nil, 12)
    if type(status) ~= "number" then return nil, tostring(status or "no answer") end
    if status ~= 200 or (bytes or "") == "" then return nil, "HTTP " .. tostring(status) end
    local f = io.open(path, "wb")
    if not f then return nil, "can't write" end
    f:write(bytes)
    f:close()
    return true
end

-- ------------------------------------------------------------------ commands

local function onDevice(id) return id and id ~= "" and { device_id = id } or nil end

--- Playback moved to a device (it starts playing there with play).
function API:transfer(id, play)
    return self:request("PUT", "/me/player", nil, { device_ids = { id }, play = play == true })
end

--- Play: what's paused goes on (no body), or body starts something:
-- { context_uri, offset = { uri } } or { uris = { … } }. device: an id, or nil for the active one.
function API:play(device, body)
    return self:request("PUT", "/me/player/play", onDevice(device), body)
end

--- Play on a device that may be idle: Spotify answers "no active device" for one until
-- playback is moved to it, so that comes first, then play (again once more: a device takes a
-- moment to wake).
function API:startOn(device, body)
    local ok, why = self:transfer(device, false)
    if not ok then return nil, why end
    for attempt = 1, 2 do
        self.sleep(attempt == 1 and 0.8 or 1.5)
        ok, why = self:play(device, body)
        if ok or (why ~= "nodevice" and why ~= "devicegone") then return ok, why end
    end
    return nil, why
end

--- Play, wherever it can: on device when one is named; else on the active one; and when none
-- is active, on the one used last (preferred, an id) or the only one that's on. Several on and
-- none of them preferred: nil and "choose".
function API:startAnywhere(body, device, preferred)
    if device and device ~= "" then return self:startOn(device, body) end
    local ok, why = self:play(nil, body)
    if ok or why ~= "nodevice" then return ok, why end
    local raw
    raw, why = self:devices()
    if not raw then return nil, why end
    local d, pick = M.pickDevice(M.devices(raw), preferred)
    if not d then return nil, pick == "choose" and "choose" or "nodevice" end
    return self:startOn(d.id, body)
end

function API:pause() return self:request("PUT", "/me/player/pause") end
function API:next() return self:request("POST", "/me/player/next") end
function API:previous() return self:request("POST", "/me/player/previous") end
function API:seek(ms) return self:request("PUT", "/me/player/seek", { position_ms = math.floor(ms) }) end
function API:volume(percent) return self:request("PUT", "/me/player/volume", { volume_percent = math.floor(percent) }) end
function API:shuffle(on) return self:request("PUT", "/me/player/shuffle", { state = on and "true" or "false" }) end
--- mode: "off", "context" (all) or "track" (one).
function API:setRepeat(mode) return self:request("PUT", "/me/player/repeat", { state = mode }) end
function API:queue(uri) return self:request("POST", "/me/player/queue", { uri = uri }) end

return API
