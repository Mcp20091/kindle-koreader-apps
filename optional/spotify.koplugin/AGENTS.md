# AGENTS.md: Spotify Remote (optional/spotify.koplugin)

Notes for AI coding agents working on this plugin. The shared parts of the apps (title bar, pop-ups,
notifications, launcher, guide) are in the top-level AGENTS.md; this file covers only Spotify Remote (shown to the user under that name, so nobody takes it for a player; the plugin, its files and its keys are `spotify`).

## What it is

A remote control for Spotify over its Web API: what's playing, play and pause, next and previous, seek, volume,
shuffle and repeat, the Spotify Connect devices that are on (a tap transfers playback), and things to start (the
account's playlists, recently played songs, a search). The Kindle plays nothing. An **optional** app: it lives in
`optional/`, isn't in the main install zip, and has its own (`optional/build-zip.py`; the release makes
`kindle-spotify.zip`). It says what it is in `PS.appInfo.spotify` (main.lua's `shareWithApps`).

## The API (what spapi.lua speaks)

Written from Spotify's Web API reference and its 2026 changelogs. **It hasn't been tried against the real API**:
only against the stand-in in the tests and on the emulator. Check these on a real Premium account first.

- **Sign-in: Authorization Code with PKCE**, no client secret. The user makes their own app in Spotify's developer
  dashboard and gives its Client ID. `GET accounts.spotify.com/authorize?client_id&response_type=code&redirect_uri&
  code_challenge_method=S256&code_challenge&scope&state`, then `POST accounts.spotify.com/api/token`
  (`grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `code_verifier`), and
  `grant_type=refresh_token` for a new access token (an hour each). A refresh may answer a **new refresh token**,
  which replaces the old one.
- **The redirect URI is `http://127.0.0.1:8888/callback`** and nothing listens there. Spotify takes http only for
  the loopback addresses 127.0.0.1 and [::1] (not `localhost`, not the Kindle's own address), and the Kindle has no
  browser. So the browser of a phone or computer ends on an address that doesn't load, and the user pastes that
  address (it holds the code) into the web page's Spotify Remote tab or the Kindle. `spmodel.parseCallback` takes the
  address or the code alone and checks `state`.
- **Scopes**: `user-read-playback-state user-modify-playback-state user-read-currently-playing` (the remote),
  `user-read-recently-played` (Recent), `playlist-read-private playlist-read-collaborative` (Playlists),
  `user-library-read user-library-modify user-follow-read` (Like, Library),
  `playlist-modify-public playlist-modify-private` (adding to and removing from playlists). A sign-in made
  before a scope was added doesn't cover it: `spmodel.scopesCover` against the tokens' scope, and the first page
  shows **Sign in again**; a 403 naming the scope is "scope".
- **Reading**: `GET /me/player?additional_types=track,episode` (204 with nothing: nothing is playing anywhere),
  `GET /me/player/devices`.
- **Commands**: `PUT /me/player { device_ids = { id }, play }` (transfer), `PUT /me/player/play[?device_id=]`
  (no body: go on; `{ context_uri, offset = { uri } }` or `{ uris }`), `PUT …/pause`, `POST …/next`,
  `POST …/previous`, `PUT …/seek?position_ms=`, `PUT …/volume?volume_percent=`, `PUT …/shuffle?state=`,
  `PUT …/repeat?state=off|context|track`, `POST …/queue?uri=`. A PUT or POST without a body needs
  `Content-Length: 0`.
- **Idle devices**: play answers 404 `NO_ACTIVE_DEVICE` until playback is transferred. `API:startAnywhere` plays;
  on that answer it reads the devices, picks one (`spmodel.pickDevice`: the active one, the one used last, the only
  usable one; else "choose" and the UI asks), transfers with `play = false`, waits a moment and plays with
  `device_id` (twice at most). Devices with `is_restricted` take no commands: shown greyed out, never picked.
- **The library and playlists (the February 2026 endpoints)**: `GET /me/library/contains?uris=` (an array of
  booleans), `PUT` and `DELETE /me/library?uris=` (comma-separated URIs in the query, at most 40: songs to Liked
  Songs, albums to the library), `POST /playlists/{id}/items { uris = { … } }` (201),
  `DELETE /playlists/{id}/items { items = { { uri } } }`, `GET /me/player/queue` (`{ currently_playing, queue }`),
  `GET /me/tracks?limit=50&offset=` (Liked Songs, two pages), `GET /me/albums?limit=50`,
  `GET /me/following?type=artist&limit=50`, `GET /albums/{id}/tracks?limit=50`,
  `GET /artists/{id}/albums?include_groups=album,single&limit=20` (asked again with 10 when the number is
  refused), `GET /me` (the id: whose playlists can be changed). Liked Songs plays as the context
  `spotify:user:<id>:collection` (not in the reference; a trial like DJ).
- **A playlist's songs and their order**: `GET /playlists/{id}/items?limit=50&offset=` (four pages; only for
  playlists the user owns or collaborates on; each entry holds its song as `item`), and
  `PUT /playlists/{id}/items { range_start, insert_before, range_length = 1 }` to move one (`spmodel.reorder`
  from places counted from 1). The move is made in the list at hand at once (`moveInList`).
- **Not in the API**: reordering or removing what's in the queue; hiding or disliking a song; DJ's own controls; devices that aren't connected.
- **Lists**: `GET /me/playlists?limit=50&offset=` (at most 4 pages), `GET /me/player/recently-played?limit=30`,
  `GET /search?q=&type=track,album,playlist,artist&limit=6`.
- **Errors**: `{ error = { status, message, reason } }`. 401: refresh once and send again, then "signin". 403 with
  `PREMIUM_REQUIRED`: "premium"; 403 naming the dashboard or "registered": "notlisted" (the account isn't on the
  app's user list); other 403: "restricted". 429 with `reason = "QUOTA_EXCEEDED"`: "quota", else "busy".
  The token address: `invalid_grant` is "signin", `invalid_client` "clientid". Plain words: `spmodel.whyText`.
- **Development mode (as of November 2026)**: the app's owner needs Premium; up to 5 users, each on the app's
  user list; up to 25 Client IDs per developer, sharing one quota; `GET /search` gives at most 10 of each kind;
  `GET /me` no longer says `product`, so Premium is only known from a command's 403; a playlist's songs can only be
  listed for playlists the user owns (not used here: a playlist is started by its URI). These change: read
  Spotify's changelog before relying on any of them.

## Files

- `main.lua`: the plugin. Settings (`settings/spotify.lua`: client_id, device, device_name; reader settings
  `spotify_interval`, `spotify_volume_step`, `spotify_art`), the tokens (`settings/spotify_tokens.lua`), the
  requests' queue (`job`: one child at a time), reading (`fetch`), commands (`act`, `setVolume`), lists, the
  sign-in (`signInUrl`, `finishSignIn`, `signOut`), every registration with the launcher (`shareWithApps`), quick
  buttons, gestures, and the web page's `webState()` / `webAct(name, args)`.
- `spui.lua`: the screens, and reading while a live page is on top (`UI.poll`, `UI.songEnd`). Song lists
  are `songsPage` (rows with a hold menu, `UI.songMenu`, and Select for several at once, the `list-checks` button in the title bar: a bare tick wasn't taken for it). Starting
  something leaves the page open; every list page's title bar has play or pause (a tap: the player's buttons above the list; a hold: play or pause; `UI.withControls`, also in the
  menu) and the music note (a tap: the first page; a hold: the full screen): `UI.remote`; the full screen
  (`UI.player`) is the first page's rows down to its first heading, under the picture, read every
  `spotify_player_interval` seconds (0: the app's).
- `spmodel.lua`: plain Lua, tested: PKCE, the callback, tokens, why something failed and its words, devices,
  what's playing, times, playlists, recent, search results, the launcher's line.
- `spapi.lua`: the requests (blocking: only in a child process). `API.new{ clientId, tokens, request, now, sleep }`:
  the tests pass a stand-in network.
- `sppage.lua`: FlashForge's ffpage with its own items: `playing` (the card), `controls` (the remote's buttons),
  `volume`.
- `spbg.lua`, `spko.lua`: NextDNS's ndbg/ndko, renamed.
- `sptitle.lua`, `spcanvas.lua`: **copies** of the launcher's `appsbar.lua` and `appscanvas.lua`. Re-copy them
  when those change; don't edit them here.
- `webspotify.lua`, `web/spotify.js`: the web page's routes and tab.
- `icons/` (Lucide, ISC), `tests/run.lua`; the user guide chapter is `guide/spotify.md` (repository root).

## Rules

- **Nothing is read while the app is closed.** `UI.poll` reads only while a live page (the first page, Devices) is
  on top and the Kindle isn't showing its sleep screen, and stops when the pages close. The launcher's tile and
  the quick buttons show what's in memory and never ask Spotify. The web page's tab makes the Kindle read only
  while that tab is open (`webState`). A quick button or gesture sends one command when tapped.
- **The tokens are in their own file, and a child process writes it.** A refresh happens in a child, and Spotify
  may replace the refresh token: the child keeps it in `spotify_tokens.lua`, and nothing of it stays in the
  parent's memory (each job reads the file). `main.lua`'s queue runs one job at a time so two never refresh at
  once; the connection test is its own child, so `API:refresh` takes the tokens another process kept when its
  own refresh token is refused.
- The tokens never go in logs, the diagnostics file or `webState()`; the backup has them only with Include keys
  and sign-ins (`secret_files`). The Client ID shows only its end.
- **A device tap never starts music by itself.** Transfer sends `play` as it is now: playing music goes on
  there; with nothing playing the device only becomes the active one (and the one used last). Tried on a
  real phone with `play = true`: it started playing at once, which wasn't wanted.
- **DJ (a trial: take it out if it doesn't work).** Spotify has no API for its DJ. The **DJ** tile plays
  `spmodel.DJ`, the hidden playlist Spotify's own apps play for it, as any playlist is started. From other
  remotes' reports: it starts DJ on some devices, plays songs without the voice on others, or nothing.
- **Seen before (a trial: take it out if it doesn't work).** `GET /me/player/devices` lists a device only
  while it's connected to Spotify, so idle speakers (Amazon Echo and the like) are missing, though Spotify's
  own app finds them on the Wi-Fi. The devices seen are kept (`seen` in `settings/spotify.lua`, the newest 12;
  `spmodel.noteSeen`, `seenList`) and Devices lists the ones not on now, to send a transfer to anyway. Whether
  Spotify takes a transfer to a device with no session isn't known yet.
- **What a tap and a hold do is the user's to set.** The title bar's play or pause and music note on list
  pages, and the album's picture on the first page, each take one of `spmodel.BUTTON_ACTIONS` for tap and for
  hold (`spmodel.BUTTONS`: keys and defaults; reader settings `spotify_button_<key>`; Settings > BUTTONS, and the
  web page). A new button with a hold of its own goes in that list. `spotify_stay`: lists stay open after Play.
- Sign out has Undo (the tokens come back). Nothing else needs a confirm.
- One notification: "Sign in to Spotify again." (`spotify:signin`), taken out by the next sign-in.
- The album's picture: Spotify's 300 pixel JPEG, fetched once per album in the reading child, kept in
  `koreader/cache/spotify/` (the newest 20), drawn only with **Album art** on.
- Made-up data only ("Morning Song", "The Examples", "Living room speaker", "Pat").

## Testing

```sh
luajit tests/run.lua        # spmodel, and spapi against a stand-in network
```

On the emulator: a driver that sets `require("spapi").http` to a stand-in before the app opens (the child
processes inherit it; what commands change has to live in a file, since each request is its own process).
