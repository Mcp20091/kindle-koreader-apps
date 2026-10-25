# Home Assistant (homeassistant.koplugin): notes for coding agents

Read the top-level AGENTS.md first. It has the rules every plugin shares. This file covers only
Home Assistant.

## What it does

It controls a Home Assistant home from KOReader: lights, switches, fans, thermostats, locks, covers,
vacuums, players, cameras, scenes and scripts, room by room. It also has shortcut screens (Security,
Climate, a 3D printer and more), routines kept on the Kindle, and a nightstand dashboard.

## How it's built

- `main.lua`: the plugin. It handles signing in, updates, background jobs, keeping the Kindle awake
  for the dashboard, doorbell watching, the sleep screen and its alerts, and sharing with Apps.
- `haapi.lua`: Home Assistant's REST and WebSocket APIs (WebSocket in `hawebsocket.lua`) and the
  OAuth sign-in (or a long-lived token).
- `hatemplate.lua`: the single template Home Assistant renders on every update. It returns every
  entity, room, battery and the weather as one compact JSON (`{ v, now, e, r, d, b, w, ws }`), so an
  update is one request.
- `hamodel.lua`: plain Lua with no KOReader modules, so the tests run it. It turns the snapshot into
  entities and rooms and decides what each shows and does: icons, state text, tap actions, On now,
  shortcuts, printer and doorbell detection, and camera placeholders.
- `haview.lua` (the screens), `hacanvas.lua` (drawing in units, the short side is 620), `hasheet.lua`
  (one device's controls), `hasettings.lua` (settings, reorder, device picker, sign-in) and
  `haroutines.lua`.
- `hako.lua`: a copy of `apps.koplugin/appsko.lua` with its own header. Keep it in step.
- `placeholders/`: drawings shown until a camera's still arrives. `icons/`: Lucide SVGs.

What it saves:
- `koreader/settings/homeassistant.lua`: `prefs` (addresses, screens, Quick tiles, order, routines,
  dashboard) and the sign-in.
- `homeassistant-token.txt`: a pasted long-lived token, when one is used.
- `homeassistant-states.json`: the last snapshot, so screens show at once.
- `koreader/cache/homeassistant-camera/`: camera stills.
- `G_reader_settings`: `sleep_screen_app` and `sleep_screen_update` (shared with the other apps).

Network work never blocks KOReader's loop. `HomeAssistant:background(kind, job, done)` runs each
request in a child process (`ffiutil.runInSubProcess`) and polls its pipe every 0.15 s with
`UIManager:scheduleIn`. A job is stopped after 90 s.

The child saves nothing itself. If it refreshed the token (`CHILD_KEYS`), it sends the new values
back first and the parent saves them. Finished children are reaped.

Quiet updates (the timer, the dashboard) only run when `online()` is true. Taps go through
`NetworkMgr:runWhenOnline`.

## How it uses the shared pieces

- The bar: `Bar.draw` via `hako`, with search on Home, refresh, the bell and ⋮. ⋮ has Open on the web
  page, Add to Apps, Home Assistant notifications, Recent apps, the light, Night mode, Refresh screen
  and Settings.
- Notifications: Home Assistant's persistent notifications are copied in with the key
  `homeassistant:<notification_id>` and taken out (`PS.unnotify`) when they're dismissed there.
  `PS.notifyOpeners.homeassistant` opens the Notifications screen.
- `PS.registerSettings`, `PS.registerSearch` (devices by name or room, from the snapshot in memory)
  and `PS.registerSetup` (sign-in step, order 20), all with `key = "homeassistant"`.
- `PS.noteRecent("ha")`, or `"dashboard"` when the dashboard opens.
- Pop-ups and Undo through `KO.*`. Locks, the garage and scripts ask first (each can be switched
  off). Something turned off stays in On now for a few minutes as a quick way back.

- Quick buttons: `shareWithApps` registers `PS.registerQuick{ key = "homeassistant" }`; `quickItem(id)` gives
  the launcher a device's button (value, `steps` − and +, `media` controls, `chip` for sensors) and
  `openDevice(id)` opens its sheet (the hold). Taps go through `act`, as the tiles' do.

## Pitfalls

- **Keep the view in `self.screen`, not `self.view`.** In a book, `self.view` is KOReader's
  ReaderView.
- **Online checks:** `NetworkMgr:isConnected() ~= false`, never `isOnline()`. `isOnline` looks up a
  name on the internet and hangs the screen when Wi-Fi works but the internet doesn't. Home Assistant
  on the home network doesn't need the internet.
- **Keeping the Kindle awake** (dashboard, while charging): `stayAwake(who, on)` keeps reasons in
  `PluginShare.awake_reasons`. While any reason is set, it sets `PluginShare.pause_auto_suspend`,
  sets `PluginShare.keepalive` (only undone if this code set it) and runs
  `lipc-set-prop com.lab126.powerd preventScreenSaver 1`. Everything is reset when KOReader exits
  (`Device.exit` is wrapped once). Without `keepalive`, KOReader's sleep timer loops forever past the
  sleep time and freezes the Kindle.
- **Methods named `on…`** are treated as event handlers: only the first return value comes back
  and errors are swallowed. Use other names for helpers.
- **Printer detection** goes by words in the entity id (`PRINTER_WORDS`, minus `NOT_PRINTER` for
  proxies and containers named after the printer). Only the device with a nozzle or print progress
  counts as the printer.
- **Doorbells** pair a ring sensor with the camera on the same device, so test data needs matching
  device names.
- **Full-screen views** set `flash_on_uncover = true`, so a closed dialog leaves no ghost.
- **The sleep screen** only shows without lock-screen ads ("special offers").

## How to test

- `luajit tests/run.lua` from this folder (it uses `tests/json.lua`). Ends with `N passed, 0 failed`.
  Device ids and names in the tests are made up (`camera.front_door`, `climate.thermostat`,
  `sensor.study_3d_printer_nozzle_temperature`). Keep them generic.
- `python tests/check_input_path.py` from `apps.koplugin` covers this plugin too.
- On a computer: KOReader's Linux AppImage, extracted, with this folder (and apps.koplugin) in its
  `plugins/` folder and a separate `HOME`. Point it at a test Home Assistant (for example
  `http://192.168.1.50:8123`) or use a saved `homeassistant-states.json` made from made-up entities.
- Never create helpers, automations or anything else in a real Home Assistant to test. The plugin
  only reads states and calls services.

## Rules for this plugin

- No new gestures beyond swiping in from the left edge for Back. Other swipes turn pages.
- Never handle pen input.
- Plain wording. Say "Kindle", and use Home Assistant's own names for things (Quick tiles, scenes,
  scripts).
- No dark mode of the app's own: KOReader's night mode covers every app.
- Made-up devices, rooms and addresses in tests, docs and screenshots.

## Shared helpers

Helpers more than one app needs live in the launcher (apps.koplugin) and are reached through KOReader's PluginShare (`PS.ko`, `PS.ai`, `PS.microsoft`, `PS.registerTest`, `PS.backupApps`, `PS.statusIcons`…); see apps.koplugin/AGENTS.md. This plugin uses them when the launcher is there, and its own copies are only the fallback without it. A new helper goes into apps.koplugin, not here.
