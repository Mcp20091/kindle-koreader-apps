# AGENTS.md: syncthing.koplugin

Notes for AI coding agents working on this plugin. The shared parts of these KOReader apps (title bar, pop-ups,
notifications, settings, search, wording) are in the top-level AGENTS.md of the apps collection; this file covers
only what is true of Syncthing.

## What it is

A KOReader plugin that runs [Syncthing](https://syncthing.net) on a jailbroken Kindle: a full-screen app (on/off,
requests to accept, folders, devices, this Kindle's ID as a QR code), a line for the launcher's tile (apps.koplugin), and calls
for the web page's Syncthing tab. Based on koreader-syncthing by jasonchoimtt (AGPL-3.0); keep `COPYING` and the
credit in README.md and ../guide/syncthing.md.

## Files

- `main.lua`: the plugin. Start/stop, Start with Wi-Fi (`onNetworkConnected` / `onNetworkDisconnecting`), the
  status read in the background (`fetch`, `status`), actions (`act`), notifications, the launcher line
  (`appsLine`), the web page calls (`webState`, `act`), and the registrations with Apps.
- `stview.lua`: the app screen and its settings page, drawn on a canvas in 620-unit page coordinates.
- `stapi.lua`: Syncthing's REST API (`snapshot` reads everything the screens show; small calls for actions).
- `stmodel.lua`: plain Lua, no KOReader: states and lines in words, sizes, times, config.xml parsing. Tested.
- `stidbox.lua`: this Kindle's ID as a QR code, in a box drawn like the launcher's pop-ups (Copy, Done).
- `stcanvas.lua`: the drawing surface (the same as Apps' and Wikipedia's).
- `stko.lua`: the menu and pop-up helpers. With the launcher, the generic ones (list, choose, buttonDialog,
  confirm, toast, wait, undo, fromLeftEdge) come from its `PS.ko`; the copies here are the fallback without it.
  Syncthing's own: `message`, `menu`, `twentyFour`, night mode, `flashOnUncover`.
- `start-syncthing`: shell script that makes the config the first time, writes `device-id`, and starts
  `syncthing serve` in the background with its PID in `/tmp/syncthing_koreader.pid`.
- `tools/fetch-syncthing.sh [folder] [arm|amd64]`: downloads the pinned Syncthing release from GitHub and checks
  its SHA-256. The 25 MB `syncthing` program is not in git (`.gitignore`); it ships in the install zip.
- `cacert.pem` (from upstream), `icons/` (Lucide, ISC), `tests/run.lua`, `docs/` (user guide chapter and screenshots).

## Data it keeps

- `koreader/settings/syncthing/`: Syncthing's own `config.xml` (folders, devices, GUI API key), keys, database,
  `logs`, and `device-id`. The same folder as upstream, so this plugin takes over an upstream install (keep the
  folder name `syncthing.koplugin` too).
- `G_reader_settings`: `syncthing_port` (default "8384"), `syncthing_with_wifi` (Start with Wi-Fi; falls back to
  upstream's `syncthing_autostart`), `syncthing_notified` (notification keys already sent, so a restart doesn't
  send them again). The home folder (`home_dir`) is where accepted folders go by default.

## How it runs

- KOReader talks to Syncthing at `http://127.0.0.1:<port>/rest/...` with the `X-API-Key` from config.xml.
- Nothing waits on Syncthing in KOReader's main loop: every REST call runs in a child process
  (`ffiutil.runInSubProcess`, see `job()` in main.lua) and comes back through a timer. Start runs the script in the
  background and waits for the API with timers; stop sends TERM, then KILL after about 3 s, also on timers.
- Status is read only when something shows it: every 5 s while the app is the top widget, at most every 20 s for
  the launcher line, every 3 s for the web page. No other periodic timers.
- The launcher is told to redraw only when its line text changes.
- `webState()` and `act(name, args)` are the web page's API (webpage.koplugin's websyncthing.lua and
  web/syncthing.js; its Dashboard tab calls `App.pages.syncthing.status(s)` and `requests(s)`). Keep their shapes.

## Shared pieces (when the launcher, apps.koplugin, is installed; check each `PS.*` exists)

- Title bar as apps.koplugin's appsbar.lua: ‹ back, ⌂ (`PS.appsHome`), recent apps (`PS.showSwitcher`), title;
  time and battery with ▾ (tap: `PS.showControlCenter`), ⟳, 🔔 (`PS.showNotifications`, badge
  `PS.notifyCount`), ⋮ with Settings last. Page count in the bar.
- Notifications (`PS.notify` / `PS.unnotify`), one key per thing: `syncthing:req:dev:<device id>`,
  `syncthing:req:folder:<folder id>:<from device id>`, `syncthing:err:<folder id>`. Taken away when the request
  is accepted or ignored, or the error clears. `PS.notifyOpeners.syncthing` opens the app.
- `PS.registerSettings{ key = "syncthing" }` (opens the settings page; back returns to the launcher),
  `PS.registerSearch` (folders by name or path, from memory only), `PS.registerSetup` (order 50: pairing),
  `PS.noteRecent("syncthing")`; the open screen is the plugin's `.view`.
- Pop-ups through stko.lua (`KO.menu`, `KO.list`, `KO.confirm`, `KO.message`, `KO.toast`, `KO.undo`): the
  launcher's pop-ups when it is there, KOReader's own otherwise. Text input stays KOReader's InputDialog.
- Backup: `PS.backupApps.syncthing` (settings keys always; `settings/syncthing` only with keys and sign-ins;
  `beforeRestore` stops Syncthing and waits). Status icons by the clock: `PS.statusIcons()`.

## Shared helpers

Helpers more than one app needs live in the launcher (apps.koplugin) and are reached through KOReader's PluginShare
(`PS.ko`, `PS.ai`, `PS.microsoft`, `PS.registerTest`, `PS.backupApps`, `PS.statusIcons`…); see apps.koplugin/AGENTS.md.
This plugin uses them when the launcher is there, and its own copies are only the fallback without it (except
`KO.message`, whose boxes with an action keep Close next to it). A new helper goes into apps.koplugin, not here.
- Swipes: a swipe right that starts at the left edge is back; other swipes turn pages.
- Buttons on Syncthing's own canvas (On/Off, Accept/Ignore, the ID box) are `KO.iconButtons`, drawn as the
  launcher's `Popup.iconButtons`; text to read is `KO.read` (the launcher's reading page, with Copy).

## Pitfalls

- Kindle firewall: on start, `iptables` holes for the GUI port (TCP), 22000 (TCP and UDP, sync) and 21027 (UDP,
  local discovery); removed on stop. Without them other devices can't connect. Kobo needs `ifconfig lo up`.
- `syncthing serve` runs a monitor process that starts the real one: stop with `pkill -P <pid>` and `kill <pid>`.
- Leaving KOReader does not stop Syncthing (as upstream). Start with Wi-Fi stops it before Wi-Fi goes off.
- The first start makes keys and the config with a random GUI password (the web GUI stays closed until a password
  is set); it takes a few seconds on a Kindle, hence "Starting…".
- KOReader's json is LuaJSON: an empty Lua table encodes as `{}`. Lists Syncthing expects as `[]` must go through
  `require("json").util.InitArray(t)` when they may be empty.
- Never give a full-screen widget a field or method named `toast`: UIManager stacks it as a toast and new pop-ups
  go under it.
- Plugin methods whose names start with "on" are wrapped as event handlers (first return value only, errors
  swallowed): don't name helpers `on…`.
- Popup.message runs its action however the box closes; for an action, KO.message uses Close plus the action.
- Things that look wrong but are right: a folder that is "idle" but still needs files shows "Out of sync"; a
  connected device with nothing shared yet shows "Connected" without a percentage; Ignore has no confirm (Undo
  un-ignores).

## Testing

- Unit tests (plain LuaJIT, no KOReader): `luajit tests/run.lua` from the plugin folder.
- In the KOReader emulator (the Linux AppImage, extracted): link this folder into its `plugins/` as
  `syncthing.koplugin`, run `tools/fetch-syncthing.sh . amd64` for a PC build of Syncthing, and run KOReader with
  its own HOME and `EMULATE_READER_W=1860 EMULATE_READER_H=2480 EMULATE_READER_DPI=300`. A second Syncthing on
  the same PC (another `--home`, GUI on 127.0.0.1:8385, listening on 22001) stands in for a computer: add the
  emulator's device ID to it with the address `tcp://127.0.0.1:22000` and share a folder to get requests.
- Check new UI in the emulator with screenshots before committing; also run the apps' own tests if you change
  anything shared.

## Rules

- Plain, standard wording ("Turn on", "Up to date", "Can't reach…"); say "Kindle".
- Made-up data only in code, tests, docs and screenshots: generic device names ("Desktop PC", "Phone", "Work
  laptop"), example IDs (`AAAAAAA-BBBBBBB-…`), example addresses (192.168.1.42), Kindle paths
  (`/mnt/us/documents/...`). No real names, emails, device IDs, hostnames, addresses or personal paths.
- Keep the AGPL-3.0 licence and the upstream credit.
