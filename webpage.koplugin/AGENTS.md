# Web server (webpage.koplugin): notes for coding agents

Read the top-level AGENTS.md first. It has the rules every plugin shares. This file covers only the
web server.

## What it does

A small web server on the Kindle. A phone or computer on the same Wi-Fi opens its page (for example
`http://192.168.1.50:8080`) to manage files, books, reading statistics, KOReader's settings, plugin
updates, backups and every app's setup, with a keyboard and a big screen.

## How it's built

- `main.lua`: the plugin. It handles start and stop, the QR code, Stop after 30 minutes unused,
  keeping the Kindle awake, the heartbeat, its menu, and sharing with Apps. One server serves all of
  KOReader: the plugin is made again for each book and for the file browser, but the server isn't.
- `webserver.lua`: the HTTP server. `server:route(method, pattern, handler, stream)`. `req` has
  `method`, `path`, `query`, `headers`, `body`, `json()` and `read(n)`. `res` has `json`, `text`,
  `file`, `redirect` and `status`. Request bodies are read whole up to a limit. Uploads stream
  straight to disk.
- One module per tab or area, each adding its `/api/...` routes:
  - Core: `webhome`, `webfiles`, `weblibrary`, `webbooks`, `webkoreader`, `websystem`, `webdiag`,
    `webplugins`, `webbackup`, `webauth`, `webdash`, `websearch`, `webapps`, `webfonts` (the routes; the work is the launcher's `appsfonts.lua`. The Fonts tab,
    `web/fonts.js`: list, upload, remove with Undo, default font, Google Fonts in a child process).
    `webai` (the AI tab, `web/ai.js`: the routes `/api/ai…`; the work is the launcher's `appsai.lua`:
    services, keys, jobs, Try a prompt in a child process, Advanced and its preview).
  - Each app's tab is in the app's own folder, not here: its routes module and `web/<tab>.js`
    (`homeassistant.koplugin/webha.lua` and `web/ha.js`, To Do's `webtodo`, Notes' `webnotes`,
    Crosswords' `webcrosswords`, Wikipedia's `webwikipedia`, Syncthing's `websyncthing`, SSH's
    `webssh`, the optional FlashForge's `webflashforge` and Pangolin's `webpangolin`). The app says so in
    `PS.appInfo.<plugin>.web` (`apps.koplugin/appsinfo.lua`); `webcommon.webApps()` reads it (without
    the launcher), `main.lua` loads each routes module, `/static/app/<plugin>/<file>` serves the app's
    `web/` folder, and `/api/home`'s `apps` lists the tabs: `App.addApps` in `web/app.js` puts their links
    after the Launcher's and loads their scripts before the first page. `plugins` is the launcher and
    every app that registers. A new app needs no change here.
  - `webservers` (the Files tab's Servers and catalogs card, `web/servers.js`:
    the Library's FTP, WebDAV and OPDS lists and download folder; `library.koplugin/libraryweb.lua` does
    the work; Test runs in a child process and is polled; passwords never come back).
  - `webbooks` fixes reading sessions (`/api/reading/day`, `/forget`, `/edit`) through the
    launcher's `appssessions.lua`, the same code as the Kindle's Reading statistics; without the
    launcher those three answer that it's needed.
  - The visual editors (the launcher's tiles and quick buttons, Home Assistant's Home, the widgets sleep
    screen, To Do's Home tiles) use `App.visualZones` in `web/app.js`: zones of items drawn as on the
    Kindle, HTML5 drag and drop for a mouse, and a tap menu (Move up, Move down, To a zone) for phones,
    where drag and drop doesn't work. Save routes: `/api/apps/tiles` (`layout`), `/api/apps/quick`,
    `/api/apps/settings` (`sleep_widgets`, `sleep_widgets_order`), `/api/ha/prefs`, `/api/todo/tiles`.
  - `webapps` serves the launcher's group icons (`/api/apps/icons`, the SVGs from apps' `icons/` with
    `currentColor`) for the Launcher tab's icon picker.
  - `webcommon` is shared: the running KOReader screen, and Microsoft's sign-in by code for To Do
    and OneNote.
- `web/`: the page, plain HTML, CSS and JS with no build step. `index.html`, `app.js` (tabs,
  helpers, the apps' tabs added at start, `App.showCode` for a sign-in code), one `.js` per own tab, `login.html` and `manifest.webmanifest`.
- `watchdog.sh`: while the server runs, it notes in `crash.log` where KOReader is stuck if the
  heartbeat file isn't written for 30 s.

The apps' tabs (in their own folders) use this plugin's `webcommon` and `web/app.js` (`App.*`,
`h`): keep those stable, and change a tab together with its app.

What it saves:
- `koreader/settings/webpage-https-{key,cert}.pem` (the Kindle's own certificate) and
  `webpage-https-own-{key,cert}.pem` (yours): in a backup only with Include keys and sign-ins. `G_reader_settings` `webpage_https`
  and `webpage_https_own`.
- `koreader/settings/webpage.lua`: the port, the options and the password as a salted hash (never
  the password). Kept sessions are stored as hashes.
- `G_reader_settings`: `webpage`, `web_dashboard` (the Dashboard tab's parts) and
  `webpage_autobackup`.
- `koreader/backups/`: automatic backups. `plugins/.backup/<name>.koplugin`: the plugin a zip
  update replaced, for Undo a plugin update.
- Diagnostics in the settings folder: `sleep_history.txt` and the battery and memory samples.

KOReader's loop is never blocked. The server is added with `UIManager:insertZMQ`, so UIManager polls
it between input events. `Server:waitEvent()` checks the sockets with `socket.select(…, 0)` and
handles one request at a time: read, answer, close. A handler must answer quickly: long work goes to the
plugin that owns it (To Do's sync, for example, runs in To Do's own background job).

## How it uses the shared pieces

- `PS.registerSettings{ key = "webpage", … }` opens the settings as an Apps page (`PS.settingsPage`):
  on or off, the address, Keep the Kindle awake, Stop after 30 minutes unused, the port, HTTPS and its
  certificate, the password and Undo a plugin update.
- `PS.registerSetup` adds the web page password step (order 70).
- The control center's Web server button and the launcher's tile start and stop it.
- The Dashboard tab reuses each tab's own calls.

## Pitfalls

- **Keeping the Kindle awake** while the server runs works the same way as in Home Assistant:
  reasons in `PluginShare.awake_reasons`, `PluginShare.pause_auto_suspend`, `PluginShare.keepalive`
  (only undone if this code set it) and `lipc-set-prop com.lab126.powerd preventScreenSaver`. Reset
  everything on stop and on exit. Without `keepalive`, KOReader's sleep timer freezes the Kindle
  past the sleep time.
- **Plugin updates:** a zip is checked fully before anything is replaced: every folder needs
  `_meta.lua` and `main.lua`, and every Lua file must compile. Files the user keeps in a plugin
  folder (`client_id.txt`, `notes_defaults.lua`) carry over. KOReader restarts afterwards.
- **Restoring a backup** restarts KOReader. The plugins keep their settings in memory and would
  write the old ones back otherwise. Sign-ins and keys are left out of a backup unless asked for.
- **The password** keeps casual visitors out; without HTTPS the page isn't encrypted. A wrong
  password delays the next try, but never by blocking the loop.
- **HTTPS** (`webtls.lua`, optional, off to start with): LuaSec wraps each accepted connection.
  `waitEvent` peeks at the first byte (`recv` with `MSG_PEEK`): a TLS hello is wrapped and its
  handshake moved on a step per pass (`dohandshake` with timeout 0, never waited for); plain HTTP gets
  a 302 to `https://` (not 301, and no HSTS, so turning HTTPS off works at once). A request already
  read inside LuaSec shows as `dirty()`, not in `select`. LuaSec connections have no `getpeername`:
  the address is taken before wrapping. The Kindle's own certificate is made with KOReader's
  libcrypto (LibreSSL, `libs/libcrypto.so.N`) through ffi; yours is pasted or uploaded on System > HTTPS
  and checked first. A certificate that can't be used leaves the server on HTTP with a message, never
  stopped: the Kindle's menu is the way out. Keys go in a backup only with Include keys and sign-ins. `dev/emu/shot.sh https` drives it.
- **Methods named `on…`** are treated as event handlers: only the first return value comes back
  and errors are swallowed.
- **Online checks:** `NetworkMgr:isConnected()`, not `isOnline()`.
- **Moving, renaming, copying and deleting files** go through `webfiles.lua` (`Files.moveTo`, `copyTo`,
  `trash`), never a plain `os.rename` or remove: they do it KOReader's way, so a book's settings, history
  and collections follow. With the Library app installed they call its own `librarymodel.lua` (`moveTo`,
  `copyTo`, `trash`, `untrash`, `purgeTrash`); the copy in `webfiles.lua` is only the fallback without it:
  change both together. Read ReadCollection before the move (its `_read` drops missing files). Delete
  moves into the Library's trash folder (`cache/library-trash`; the fallback's are `web-*`) and is purged
  when the page's Undo goes, after a minute, or at the next start. Books are the Library's `BOOK_EXT`.

## How to test

- `luajit tests/run.lua` from this folder (the HTTP parsing and routing, with KOReader's modules
  stubbed). Ends with `N passed, 0 failed`.
- `python tests/check_input_path.py` from `apps.koplugin` covers this plugin too.
- On a computer: KOReader's Linux AppImage, extracted, with this folder (and the plugins whose tabs
  you test) in its `plugins/` folder and a separate `HOME`. Start the server from Tools > Web server
  and open `http://127.0.0.1:8080` in a browser.

## Rules for this plugin

- Plain wording in standard app phrasing. Say "Kindle".
- Example addresses use documentation or private ranges (`192.168.1.50`, `nas.local`), never real
  ones.
- Made-up files, books, tasks and devices in tests, docs and screenshots.

## Shared helpers

Helpers more than one app needs live in the launcher (apps.koplugin) and are reached through KOReader's PluginShare (`PS.ko`, `PS.ai`, `PS.microsoft`, `PS.registerTest`, `PS.backupApps`, `PS.statusIcons`…); see apps.koplugin/AGENTS.md. This plugin uses them when the launcher is there, and its own copies are only the fallback without it. A new helper goes into apps.koplugin, not here.
