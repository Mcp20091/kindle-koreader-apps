# Apps (apps.koplugin): notes for coding agents

Read the top-level AGENTS.md first. It has the rules every plugin shares. This file covers only Apps.

The user sees it as **Launcher**: its title, the Tools menu entry, the gesture action, and the
**Launcher** and **Edit home screen** rows in Settings. The code, the folder, the settings keys and the
PluginShare names keep `apps` (`apps.koplugin`, `PS.appsHome`), so installs and settings carry over.
In text the user reads, write "the launcher", never "Apps".

## What it does

Apps is a full-screen launcher for KOReader: big tiles for the other apps, the book you're reading,
the library, the weather and what's next. It also provides the pieces every app shares: the bar at
the top, notifications, the Settings list, search, the setup walkthrough, Recent apps, the control
center, pop-ups and Undo. It adds the title bar over books and the library, and a widgets sleep screen.

## How it's built

- `main.lua`: the plugin. Its menu entries and gesture actions, opening at start, the AutoSuspend guard,
  and the PluginShare calls (see below).
- `appsview.lua`: the launcher screen and its modes (`tiles`, `hub`, `page`, `switcher`, search).
  It also draws the widgets sleep screen (its parts in `View.widgetOrder`: the `sleep_widgets_order` setting, the
  web page's order; `sleep_widgets` turns each off).
- `appsinfo.lua`: what each app says about itself (`PS.appInfo`: tiles, order, groups, gestures,
  notifications' names, Button labels, web tab), read by the model, the Settings list, the switcher,
  the notifications, the pop-ups and the shared menus. No app is named in the launcher's lists:
  `Model.TILES` has `{ apps = true }` where the apps' tiles go.
- `appsmodel.lua`: tiles, their order and their lines. Plain Lua with no KOReader modules, so the
  tests can run it.
- `appscanvas.lua`: drawing in units. The short side of the screen is 620 units, so on a Kindle
  Scribe one unit is 3 px. A `Flow` places blocks down the page and starts a new page instead of
  scrolling. Tap and hold areas are kept alongside what's drawn.
- **The rules for every app** (design principles, wording, what a new app needs, the shared UI) are in the combined repo's AGENTS.md (kindle-koreader-apps); follow them here and in every plugin.
- **Shared helpers live in the launcher.** Anything more than one app needs is written once in apps.koplugin and published on KOReader's PluginShare: menus and pop-ups (`PS.ko`, with `back` for menus opened from a menu), the title bar's clock corner (`PS.statusIcons`), notifications, the Settings list, search, setup steps, quick buttons, connection tests (`PS.registerTest`), AI (`PS.ai`), the Microsoft account (`PS.microsoft`), QR codes (`PS.showQR{ text, caption, onClose }`, full screen with a caption and Close), backups (`PS.backupApps`) and fonts. An app uses those when they're there. Its own copy, if it has one, is only the fallback for when the launcher isn't installed, and hands over to the shared one when it is (todo.koplugin/todoko.lua's wrapper at its end). A new app starts from the shared pieces, and a new helper goes into apps.koplugin first, never into one app only.
- **Pop-ups, text boxes and buttons: one design, with icons.** When the launcher is there, an app's own
  boxes use its pop-ups, not KOReader's dialogs: typing goes in `PS.popup.request` (the text box with a
  pen at its end for handwriting, examples as rows, choices as tiles, Enter as the main button), an
  answer or other text to read in `PS.popup.read` (in pages), menus, choices and confirms in
  `PS.popup.menu/choose/confirm`. Buttons are an icon over a one- or two-word label, at most five in a
  row, the main one black, each as wide as one of five (never stretched to fill the row) and the row
  lined up on the right with the main button last; the same action has the same icon everywhere (`x` Cancel, `check` Done or
  Save, `copy` Copy, `download` Save a file, `send` Answer or Send, `search` Search, `sparkles` an AI
  suggestion, `pencil` write by hand, `plus` Create). Labels say what happens ("Answer", "Beside",
  "Replace"), never something vague ("Write it", "Ask", "OK" where a verb fits). KOReader's InputDialog,
  TextViewer and ButtonDialog are only the fallback without the launcher, with even button rows. New UI
  is shown as a mockup first and built once the user picks. An app's own icon-button rows (not drawn by
  appspopup's iconButtons: Notes' lasso bar, the handwriting strip) follow Settings > Launcher > Button
  labels too: `PS.popup.labels()` false draws just the icons. A switch that stands for a font style
  (Bold, Italic, Serif) shows its label in that style (`chips = { { font = { bold, italic, serif } } }`).
- Shared pieces: `appsbar.lua`, `appsnotify.lua`, `appspopup.lua`, `appsko.lua`, `appshub.lua`
  (Settings), `appssearch.lua`, `appssetup.lua`, `appsswitcher.lua` (Recent apps), `appscontrol.lua`
  (control center), `appsmicrosoft.lua` (the one Microsoft account, `PS.microsoft`: App ID, sign-in, tokens
  in settings/microsoft.lua, Settings > Microsoft), `appstest.lua` (connection tests: `PS.registerTest`, each app's Test connection,
  the Connection check screen, mode `conntest`), `appsreaderbar.lua` (the bar over a book or the library), `appsfooter.lua`
  (a book's status bar in the apps' style), `appsundo.lua` (Undo a plugin update, here too so it
  works when the web server is what broke).
- `appskosettings.lua`: KOReader's most-used settings (Sleep after, full refresh, rotation, tap zones,
  invert, font and size for new books, status bar, progress sync), each applied as KOReader's menu does.
  It's the Settings > KOReader page, and the web server's KOReader tab uses it too.
- `appsactions.lua` (KOReader's own Dispatcher actions as tiles), `appsgestures.lua` (the Gestures
  screen), `appsbattery.lua` (the Battery screen, from KOReader's battery statistics),
  `appsstats.lua` (the Reading statistics screens, modes `stats` and `statsbook`, read from
  KOReader's statistics.sqlite3) and `appsicons.lua` (the icon grid for a group; `Icons.LIST` is
  also what the web page offers).
- `appsquick.lua`: quick buttons. The list is setting `quick` (`Model.quickList`; built-ins `{ b }`,
  shortcuts `{ pin }`, groups `{ group, name, items }`); `Quick.item` gives each its label, icon, on,
  tap(done) and hold. `drawRow` (two rows, then More) for the launcher, `drawAll` for the control
  center (appscontrol.lua), `drawEditor` (mode `quick`). The web page saves the list through
  `/api/apps/quick`.
- `appsqr.lua`: a QR code full screen with a caption under it and Close (`PS.showQR`).
- AI for this (`PS.ai.quickPick(jobOrFeatureKey)`): the service and a model for that one job. Give every AI button in the shared boxes `aiJob = key` (a hold opens it), and call it from a hold on your own AI buttons.
- `appshandwrite.lua` and `appspen.lua`: handwriting input for every app's text boxes (`PS.handwriting`).
- `appsfonts.lua` (fonts: list, add, remove with Undo, default, Google Fonts in a child process; the
  web page's Fonts tab calls it too) and `appsfontsview.lua` (the Fonts screen, mode `fonts`, in three tabs: `view.fontsTab` mine, get, settings, each with its own page), and `appsgooglefonts.lua` (every Google Fonts family to browse: its catalogue fetched in a child process and kept short in the cache, then searched in memory; the web page uses it too).
- `appsai.lua` (AI for every app: the services, their keys in `ai_secrets.lua` and settings in
  `G_reader_settings` "apps_ai", which service does each job, each feature's instructions, Try a prompt,
  Test connection's "ai", `AI.ask` in a child process; moved once from Notes' settings and
  `notes_secrets.lua`), `appsaiclient.lua` (the requests: Claude's Messages API and the OpenAI chat API;
  plain Lua, tested) and `appsaiview.lua` (Settings > AI and its pages, drawn with `PS.settingsPage`; a
  page's `back` opens the page it came from). The web page's AI tab (`webai.lua`) calls appsai too.
- Tiles with `offByDefault` (Gestures, Battery, KOReader settings, Restart) start hidden and are in
  Settings (`PS.registerSettings`, opened with `backTo` so Back returns there) and search. The
  `defaults_2` step in `Apps:init` keeps an existing launcher's tiles as they were.
- `appsweather.lua`: the Weather tile and screen (mode `weather`), and `Weather.now()` for At a
  glance and the widgets sleep screen, from Home Assistant or Open-Meteo (settings `weather`,
  `weather_place`, `weather_units`). Open-Meteo (and US alerts from api.weather.gov, which wants a
  User-Agent) is fetched in a child process every 30 min while Wi-Fi is on, kept in
  `koreader/settings/apps_weather.lua`.
- `appssessions.lua`: reading sessions (a book read with no break over 10 minutes): list, edit,
  delete, reset and put back (Undo). The web page's Reading tab calls it too, so the Kindle and the
  page change the statistics the same way. Plain SQL on `page_stat_data`; keep it free of UI.
- Icons: Lucide SVGs in `icons/`, each with a `-w` (white) copy for black backgrounds.

What it saves:
- `G_reader_settings` key `apps`: tiles, layout and options. Also `apps_recent`, `apps_lines`,
  `apps_setup_done` and `apps_bar_tip_shown`.
- `koreader/settings/notifications.lua`: the notifications, at most 100.
- It reads KOReader's `statistics.sqlite3` (reading time) and `bookinfo_cache.sqlite3` (search), and
  never writes to either.

It does no network work of its own. Book search runs in a child process
(`ffiutil.runInSubProcess`), and the parent polls its pipe with `UIManager:scheduleIn`. The other
apps' results come straight from memory, so the screen never waits.

At KOReader's start, `main.lua` only puts small tables and functions into PluginShare. Each module
is `require`d the first time it's used. Keep it that way: the start time and the idle Lua memory
are watched.

## What it provides (PluginShare)

Plugins load in alphabetical order, so Apps is first. Other plugins must still check
(`if PS.notify then`) because Apps may not be installed. `local PS = require("pluginshare")`:

- `PS.notify{ app, text, key, route, open, time, name, icon }`: adds a notification. A notification
  with the same `key` replaces the old one. `route` is saved, and after a restart a tap calls
  `PS.notifyOpeners[app](route, entry)`.
  `PS.notifyPopups[app] = { has = fn(route), show = fn(route, entry) }` (optional): a tap in the list
  shows the app's own pop-up over it (To Do's reminder: Snooze, Open, Done) and the entry stays until
  that pop-up calls `PS.unnotify`; a hold then opens it (the opener) instead of the Open/Remove menu.
  `PS.unnotify(key)`, `PS.notifyCount()`, `PS.showNotifications()`, and `PS.notifications()`
  (a copy, for an app that cleans up its own).
- `ongoing = true` (with a `key`): one that stays while something runs (the web server): first in
  the list, its icon by the clock in the launcher and the shared bar, not counted or cleared, kept
  in memory only; `PS.unnotify(key)` when it stops. `PS.notifyOngoing()` lists them.
- Pop-up menus one level down (`KO.list(title, items, back)`, `Popup.menu{ back }`): Back instead of
  Close, back to the menu before.
  Keys are `<app>:<what>`, for example `todo:remind:<id>` and `homeassistant:<id>`.
- `PS.registerSettings{ key, name, icon, open, rows }` adds a row to Settings. `PS.showSettings(key)`.
  For the launcher's search to find each setting, give `rows = fn()` (the settings' rows, `{ name, … }`
  each, headings skipped) and make `open(name)` open the settings at the page with that row
  (`PS.settingsPage{ jump = name }` does it), or `settings = fn() -> { { name, where, open } }`.
  `PS.settingsPage{ title, rows = function() return { { heading = "…" }, { "Name", value, fn },
  { "Name", value, pick = function() return options, current, set end } } end }` shows a settings
  page drawn by Apps.
- `PS.registerSearch{ key, name, icon, search = function(q) return { { title, sub, open } } end }`.
  The search must be fast and come from memory. `PS.showSearch()`.
- `PS.registerSetup{ key, order, icon, title, text, done, action, run, help }` adds a step to Set up
  your Kindle. `help = { button, title, steps = { … }, after, guide }` adds a "How to…" page: the
  short steps, numbered, and a QR code of `Setup.GUIDE_URL .. guide` (the public repo's guide folder;
  change it there if the repo moves). `PS.showSetup()`.
- App lock (`appslock.lua`): every app with a tile in `PS.appInfo` is listed (`Lock.apps`; a
  `PS.lockApps.<key> = { key, name, plugin }` entry adds one by hand). `PS.lock.ask(key, fn)` (true:
  the passcode is up, return; fn runs once it's right) at the top of an app's show; `PS.lock.run(key,
  fn)` runs fn now or after the passcode. The core is plain Lua, tested (`Lock.new{ store, now, hash,
  random }`); the keypad is `Popup.keypad` in appspopup.lua, or the password box; Settings > Launcher >
  App lock is `Lock.rows`; the cover at sleep shows at wake when there's a sleep screen (on a Kindle
  it's drawn before the Suspend event). The launcher guards tiles, Recent apps (appsswitcher),
  notifications (appsnotify), search (appssearch), quick buttons (appsquick), its Settings screens
  (`View:lockSettings`) and `PS.showSettings`. `tests/check_app_lock.py` checks every app asks.
- `PS.noteRecent(key)` puts an app first in Recent apps (call it when the app opens).
  `PS.showSwitcher()`.
- `PS.showControlCenter(koMenu)`, `PS.appsHome()` (the ⌂ button), `PS.appsView()`.
- `PS.showSleepSettings()`: the launcher's settings at Sleep. The sleep screen is chosen there for every
  app, so an app's own settings link there instead of repeating it.
- `PS.ai` (appsai.lua; registering only adds to lists, the rest loads appsai when first used):
  - `PS.ai.registerJob{ key, name, app, order, only = { service ids }, default }`: a line of Which AI
    does each job (Notes: `read`, `ask`, `draw`). `only` limits its services (`{ "server" }`: local AI only).
  - `PS.ai.registerFeature{ key, name, app, job, intro, words, format, amounts, request, args, preview,
    without }`: an entry of Advanced. Instructions = intro (fixed, `string.format`ed with the call's
    values) .. words (the default wording, which the user may change) .. format (fixed: the answer's form
    the app reads). `amounts = { { value, label } }`; `request = false` when nothing follows; `args` for
    Preview; `preview()` -> `{ pngs, where }`; `without`: Preview's line with no pictures.
  - `PS.ai.ask(feature, { text, images = { png, … }, wait = "Asking…", args }, done(text | nil, why))`:
    the feature's instructions, then `text`, to the job's service, in a child process (Wi-Fi turned on
    first; a waiting box with `wait`). `PS.ai.instructions(key, ...)`, `PS.ai.client(job)`
    (`:transcribe(png, text, more)`, blocking), `PS.ai.configured()`, `PS.ai.readyFor(job)`,
    `PS.ai.notReadyText(job)`, `PS.ai.jobName(job)`, `PS.ai.showSettings(note)`, `PS.ai.showService(id)`.
- `PS.handwriting` (appshandwrite.lua, with appspen.lua: the pen read from its digitizer, a copy of
  Notes' notespen.lua): a strip at the bottom of the screen to write in (pen, else KOReader's stylus
  callback, else touches), read by the AI ("Handwriting input" in Advanced, job `read`).
  `PS.handwriting.available()`, `PS.handwriting.write({ title, kind = "text" | "task" | "command" |
  "name", multiline }, done(text | nil, extra))` (task: extra = { due, remind = { date, minute } }),
  `PS.handwriting.button(function() return dialog end, opts)`: a Write it button for an InputDialog
  (keep the row's button count even). `PS.popup.request{ pen = true }` uses it for its pen.
- `PS.popup.menu/confirm/message/toast/wait/undo/choose`, and `request` / `read` (Ask-style boxes): the shared pop-ups (`appspopup.lua`;
  the options are documented above each function).

The shared modules:
- `appsbar.lua`: `Bar.draw(c, opts)` draws the bar: `title`, `back`, `home`, `recent`, `buttons`,
  `pager`, `clock`, `status` (▾ for the control center), `refresh`, `bell`, `menu`, `subtitle`.
- `appsko.lua`: KOReader glue. It has `KO.menu/list/choose/confirm/message/toast/wait/undo` (these
  go to the shared pop-ups), `KO.showFull`, `KO.passGesture` (your KOReader gestures over the apps),
  `KO.fromLeftEdge(ges)`, `KO.flashOnUncover()`, `KO.twentyFour()` and the light and night-mode helpers.
  `KO.twentyFour()` reads KOReader's own `twelve_hour_clock`: every clock follows that one setting.
  `homeassistant.koplugin/hako.lua` and `todo.koplugin/todoko.lua` are copies of it with their own
  header. When you change `appsko.lua`, copy everything below the header into both.

## Pitfalls

- **AutoSuspend on a Kindle.** KOReader's sleep timer resets the power manager's timer (t1) every
  4 minutes. If its check runs after the sleep time while the Kindle is awake, it reschedules itself
  for "now" forever and KOReader freezes. `Apps.guardAutoSuspend` moves that check a minute later.
- **Keeping the Kindle awake** (Keep awake in the control center): set `PluginShare.keepalive = true`
  (only undo it if you set it) and run
  `lipc-set-prop com.lab126.powerd preventScreenSaver 1`. Reset both when you're done and when
  KOReader exits. One without the other either freezes the Kindle or lets it sleep anyway.
- **`flash_on_uncover`.** A full-screen widget with `flash_on_uncover = true` gets a full refresh
  when a dialog over it closes, so no ghost of the dialog stays on e-ink. `KO.flashOnUncover()` hooks
  `UIManager.close` once. Toasts and widgets with `no_uncover_flash` don't trigger it.
- **Methods named `on…`.** KOReader treats plugin methods whose names start with `on` as event
  handlers. Called that way, only the first return value comes back and errors are swallowed. Don't
  give helpers such names.
- **Wi-Fi checks.** Use `NetworkMgr:isConnected()`, not `isOnline()`. `isOnline` looks up a name on
  the internet and can hang the screen when Wi-Fi works but the internet doesn't.
- **The sleep screen** only shows when the Kindle has no lock-screen ads ("special offers").
- **The title bar in a book** is a widget over ReaderUI. Never keep your own widget in `self.view`:
  in a book that field is KOReader's ReaderView.

## How to test

- `luajit tests/run.lua` from this folder. Any LuaJIT works, including the one in KOReader's
  AppImage (`squashfs-root/usr/lib/koreader/luajit`). Ends with `N passed, 0 failed`.
- `python tests/check_input_path.py`, with the other plugins in folders next to this one. It fails
  when Apps, Home Assistant, To Do or the web server replace a function in KOReader's input path
  (Input, the gesture detector, UIManager's event handling, InputContainer), and it lists every
  KOReader function they replace.
- On a computer: KOReader's Linux AppImage, extracted (`--appimage-extract`). Put the plugin folders
  in its `plugins/` folder and run it with its own `HOME`, so its settings stay separate. Use
  made-up data only.

## Rules for this plugin

- No new gestures. Swiping in from the left edge (`KO.fromLeftEdge`) is Back, other swipes turn
  pages, and nothing happens on the first page. Never handle pen input or anything Notes or
  Crosswords draw with.
- Plain wording in standard app phrasing. Say "Kindle". Don't narrate ("the reader asks…") and don't
  coin labels.
- No dark mode of the app's own: KOReader's night mode covers every app.
- For anything that can be put back, use Undo (`PS.popup.undo`) instead of a "Delete?" question.
- One pop-up style everywhere: go through `KO.*` or `PS.popup.*`, never a bare KOReader dialog.
- Made-up data in tests, docs and screenshots.
