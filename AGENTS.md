# Notes for AI coding agents

KOReader plugins (Lua) for a jailbroken Kindle Scribe. Together they work like one small system inside KOReader: the Launcher (apps.koplugin; shown to the user as "Launcher"), and apps that share one title bar, one notifications list, one settings design and one pop-up look. Each plugin folder has its own `AGENTS.md` with what's specific to it; this file covers what they share.

## Not a Kindle Scribe?

Everything here was built and tested only on a **Kindle Scribe (1st generation)**: a 1860 x 2480 screen at 300 dpi, with a pen. If the user wants it on another device, **stop and ask them first**:

1. Which device (for a Kindle: KOReader > Help > About, or the model on the box; for example "Kindle Paperwhite 11th generation").
2. Whether it has a pen.
3. Its screen size and dpi, if they know (otherwise look them up from the model and say what you found).
4. Their KOReader version (Notes needs 2026.07 or later).
5. Which apps they want. For a device without a pen, offer the choices below for Notes and Crosswords.

Then go through this list. Each line is Scribe-specific, with where it lives and what to do elsewhere.

| What | Where | On another device |
|---|---|---|
| The pen read straight from its digitizer (the input device named "WacomDigitizer"), not through KOReader's touch, so writing keeps up | `notes.koplugin/notespen.lua` (`Pen.findDevice`), `apps.koplugin/appspen.lua` (a copy) | Another pen: check its name in `/proc/bus/input/devices` and pass it. No pen: Notes falls back to KOReader's stylus input, which a finger isn't; see the choices below. |
| Palm rejection: a finger touching while the pen is near, or just after it, is a resting palm (it can't write or turn pages) | `notes.koplugin/noteseditor.lua` (`palmLikely`, the stylus hook) | No pen: nothing to reject; leave it. |
| A firm pen press arrives as a hold (longer than KOReader's 0.5 s), so a hold with no action of its own works as a tap | every screen's hit handling (`(hit.hold or hit.tap)`), Buttons with `hold_callback = callback` | Harmless without a pen; leave it. |
| Handwriting input: a strip to write text by hand in text boxes, read by the user's AI (`PS.handwriting.available()`: an AI that reads handwriting is set up) | `apps.koplugin/appshandwrite.lua` (`PS.handwriting`) | No pen: it takes KOReader's stylus input, else plain touches, so a finger writes in it; the on-screen keyboard stays in every box. Nothing to change. |
| Notes and quick notes: handwritten notebooks | `notes.koplugin/` | No pen: see the choices below. |
| Crosswords: puzzles are Notes pages, answers written by hand | `crosswords.koplugin/` (needs Notes) | No pen: see the choices below. |
| E-ink refresh: on the Scribe (a MediaTek Kindle) only a "full" refresh clears ghosting, so screens refresh "full" where others would "flashui" | `KO.showFull`, `flash_on_uncover`, the screens' `setDirty` calls | Other Kindles: the same code works; if screens flash more than needed, "flashui" may be enough there. |
| Layouts in units of the screen: one unit is the shorter side / 620 (3 px on the Scribe) | `apps.koplugin/appscanvas.lua` and each app's canvas | Scales by itself; look at every screen at the device's size in the emulator for anything cramped. |
| The emulator at the Scribe's size | the Testing section, each plugin's AGENTS.md (`EMULATE_READER_W/H/DPI`) | Use the device's width, height and dpi. |
| The guide PDF at the Scribe's page size, and written for it (the pen, its screen) | `apps.koplugin/docs/guide/build.py` (`PAGE`), `guide/` | Set `PAGE` to the device's screen; reword or drop the pen parts. |
| Updates come from this repo | Settings > Updates > Repository (`apps.koplugin/appsupdate.lua`, `DEFAULT_REPO`) | In a fork, set `DEFAULT_REPO` to it (or the user sets Update from), or this repo's releases overwrite their changes. |

The rest (the power manager, the sleep cover, lipc, the firewall, Syncthing's 32-bit ARM program) is the same on the Kindles KOReader runs on. As anywhere here, prove device behaviour with a log-only probe on the device before building on it.

**Choices for a device without a pen** (offer them; build only what the user picks):

- **Leave out Notes and Crosswords** (minutes): don't install the two folders. The launcher hides tiles of plugins that aren't there, and Crosswords needs Notes anyway.
- **Notes as typed notes** (an afternoon): Notes already has typed text boxes on a page (`notestextui.lua`). Make a new note open a text box with the on-screen keyboard, and hide the pen tools from the toolbar (`Settings.toolOrder` in `notessettings.lua`). Keep existing notebooks readable.
- **Crosswords by typing** (a real project): a tap on a square selects it and the word it's in, the on-screen keyboard types a letter into each square in turn, and checking compares the typed letters instead of reading handwriting. The grid comes from `notescrossword.lua` (`Crossword.squaresOf`, `Crossword.squareAt`); the answers are in the puzzle.

When it's done, build the zip the way the README says and keep the changes on a branch of the user's fork, so later updates from here can be merged.

## Layout

(A new app: [MAKING-AN-APP.md](MAKING-AN-APP.md).)

```
apps.koplugin/          the launcher, and the shared pieces every app uses (through PluginShare)
homeassistant.koplugin  todo.koplugin  notes.koplugin  crosswords.koplugin (needs Notes)
wikipedia.koplugin  syncthing.koplugin  sshclient.koplugin  webpage.koplugin (the web server)
library.koplugin        books and folders (stands in for KOReader's file browser; the reader stays KOReader's)
optional/               apps not everyone needs, not in the main install zip: each folder and its own
                        zip (build-zip.py). flashforge.koplugin: a FlashForge 3D printer over the Wi-Fi;
                        pangolin.koplugin: a Pangolin server's sites, resources and clients (its Integration API);
                        nextdns.koplugin: a NextDNS profile (its API: blocked queries, the log, lists, switches)
guide/                  the user guide: one Markdown chapter per app, img/, build.py, chapters.txt
Kindle Apps Guide.pdf   the guide, built from guide/
```

A plugin folder is what gets copied to `koreader/plugins/` on the Kindle. An optional app (in `optional/`) follows every rule here; the launcher and the web page show it only when it's installed (it says what it is in `PS.appInfo`, below), and nothing else may depend on it. `sshclient.koplugin` has that name because KOReader ships its own `SSH.koplugin` (an SSH server).

## Design principles

- **One system, not nine plugins.** Every app looks and behaves the same: the same title bar, settings pages, pop-ups, notifications, Undo and Back. A new screen copies the shared pieces instead of inventing its own. If something is useful in one app (a notification, search, a settings entry), wire it into the shared piece so every app gets it.
- **Every screen, every app** (the user asked for this everywhere; SSH's AGENTS.md "Design (every screen)" shows it done):
  - **The apps' title bar on every full screen**: ‹ Back, ⌂ Home, recent apps, the title, the clock and battery, ⟳, 🔔 and ⋮ (`appsbar.lua`). KOReader's own full-screen dialogs count too (fullscreen InputDialog editors, a terminal): swap the bar in for their TitleBar and dress them again each time KOReader rebuilds them (the keyboard shown or hidden), as ssh.koplugin's `sshbar.lua` `Bar.swapInto` / `Bar.dialogClass` do. No screen keeps KOReader's plain title.
  - **Buttons are `PS.popup.iconButtons` rows; text boxes are `PS.popup.request`; pages to read are `PS.popup.read`.** KOReader's dialogs only as the fallback without the launcher.
  - **Copy and paste wherever text is typed or read**: the request box's hold menu (Paste, Copy all, Clear), KOReader's hold menu in an editor (Copy, Select, Paste), hold-and-drag selection on read-only text.
  - **A mockup first** for any visible change, unless the user says to skip it.
- **E-ink first.** Screens are drawn for a 300 dpi greyscale page that refreshes slowly: black and white, large tap areas, no animation, few redraws. After anything that leaves a ghost (a pop-up closing, a layout change), do a full refresh. Prefer pages with page arrows over scrolling.
- **Battery and memory are scarce.** Nothing polls in the background, nothing keeps the Kindle awake unless the user asked (the web server, the dashboard while charging), and new code loads only when first used. Measure memory and start-up time when adding something big.
- **Fewer gestures, more buttons.** The user's one gesture is a swipe in from the left edge for Back. Everything else is a visible button or menu item. Hidden actions (hold menus) also need a visible way in (⋮, or a hint line).
- **Undo over confirm.** Delete at once with "Deleted · Undo"; confirm only what can't be put back.
- **Works offline, syncs later.** To Do, Notes and Wikipedia keep their data on the Kindle and sync in the background; a missing network is a normal state, not an error. Messages say what happened and what to do, in plain words.
- **One setting per idea.** No app-own dark mode (KOReader's Night mode is the one), no duplicated settings across apps; every app's settings are reachable from the launcher's Settings list.
- **The user picks; build what was picked.** When proposing several options, build only the chosen ones. Visible design changes get a quick mockup first unless the user says to skip it.
- **The guide is part of the change.** A visible change updates its guide chapter and screenshots (made-up data only) in the same commit series.

## The rules every change follows

- **Plain wording.** Standard app phrasing, sentence case, say "Kindle". No narration ("the reader asks…") and no made-up labels.
- **One name per idea, everywhere.** The same thing has the same words in every app and on the web page: **Internal URL** and **External URL** (Home Assistant and the local AI), **Move up**/**Move down**, **Back**, **Test connection**. A label names the thing (External URL), not a situation (not "Away from home").
- **No product names as labels.** A label says what it is (External URL, API key); products the user might use (Pangolin, LiteLLM, Tailscale) appear only as examples in descriptions and the guide.
- **A label must look like what it is.** A switch's name reads as a setting, not as a heading for what's below it ("Under the clock" was read as a title: it became **Show on the home screen**). A heading looks like a heading (grey capitals), and a list split into parts says what each part means.
- **Tap does it, hold shows more.** A button's tap does the obvious thing without a pop-up (the web server button just turns it on or off); details and choices are on hold.
- **A hold on a button with no hold of its own works as a tap.** A firm press of the pen lasts longer than KOReader's 0.5 s and arrives as a hold, so every screen's hold handler falls back to the tap (`(hit.hold or hit.tap)()`), title bars included, and KOReader Buttons without a `hold_callback` get `hold_callback = callback`.
- **Pop-ups only as wide as what's in them** (the shared box sizes itself; buttons keep their size). A panel at the bottom (the handwriting strip, the Undo bar) passes taps above it to the box under it.
- **Something running shows it.** Anything left running (the web server) has an ongoing notification (`PS.notify{ ongoing = true }`) and its icon in every app's clock corner, until it stops.
- **The Kindle and the web page do the same things.** A setting or action added on one is added on the other, in the same words. On the web page a service named in a description is a link (`App.link`); on the Kindle it stays plain text (no browser there).
- **No personal data anywhere**: code, comments, tests, fixtures, docs and screenshots use made-up values only (example addresses such as 192.168.1.50, paths such as `/mnt/us/documents`, invented names and devices). The same goes for everything else that reaches GitHub: commit messages, branch names, pull requests, comments and release notes (see "Branches, commits and pull requests").
- **Never slow the pen.** Nothing of ours runs in the input path of the Notes and Crosswords drawing areas. `apps.koplugin/tests/check_input_path.py` checks that no plugin replaces a function of KOReader's input path.
- **Never block KOReader's loop.** Everything runs on one UIManager loop. Network or slow work goes to a child process (`ffiutil.runInSubProcess`, poll with `getNonBlockingReadSize` and `isSubProcessDone`, with a deadline, then `terminateSubProcess`), like To Do's sync.
- **Each app works without the others**, except Crosswords, which needs Notes. Every shared call is guarded: `if PS.notify then … end`.
- **Secrets stay put.** Keys, passwords and sign-ins go in a backup only with **Include keys and sign-ins**, never into logs or the diagnostics file, and are blanked (along with key blocks and tokens in text) before anything is sent to an AI.
- **AI only suggests.** Whatever the AI proposes (a command, a task, a name) is shown first, with Edit, and runs only when the user taps it, with a warning where it matters. Every AI feature registers with `PS.ai.registerFeature` so its wording and what it sends show in AI settings > Advanced (Preview what's sent).
- **A new app follows [MAKING-AN-APP.md](MAKING-AN-APP.md).** It says what it is in `PS.appInfo` (its tiles, Settings group, gestures, notifications, web tab: `apps.koplugin/appsinfo.lua` has every field), so the launcher and the web server don't change for it, and it has the full set: Settings, search, a setup step, its part of the backup, a connection test where it connects to something, quick buttons where it has quick things, its own icons, a web page tab and its guide. What's left in the launcher by name is what only it does with an app's data: pins (Pin to home screen) and the web page's Dashboard parts.

## The shared UI

The launcher provides these through `local PS = require("pluginshare")`. Reference code is in `apps.koplugin`: `appsbar.lua` (the title bar), `appsnotify.lua`, `appspopup.lua`, `appsko.lua` (helpers other plugins copy: `KO.menu/list/choose/confirm/toast/wait/undo`, `KO.flashOnUncover`, `KO.fromLeftEdge`), `appscontrol.lua`, `appshub.lua`, `appssearch.lua`, `appssetup.lua`, `appsswitcher.lua`.

- **Title bar** (44 units tall; sizes are in units of `min(w, h) / 620`), Lucide icons at 18:
  - left: ‹ back (on an app's first screen it returns to the launcher), ⌂ to the launcher, then Recent apps;
  - the title;
  - right: the app's own buttons, the clock and battery with ▾ (one tap area that opens the drop-down panel, `PS.showControlCenter()`), ⟳ (reload and a full refresh), 🔔 with the unread count, and ⋮ (the app's extras, Recent apps, Light, Night mode, Refresh screen, Settings always last).
  - Without the launcher (apps.koplugin) installed, ⌂, Recent apps and 🔔 are left out.
- **Notifications:** `PS.notify{ app, text, key, open, route, name, icon }`, `PS.unnotify(key)`, `PS.notifyCount()`, `PS.showNotifications()`, `PS.notifyOpeners[app] = function(route, entry)` (opens one after a restart). Use one key per thing and take it out when what it's about is done. For things to see later, not every success.
- **Settings:** full-page and paged in one design (`homeassistant.koplugin/hasettings.lua` is the reference): UPPER CASE grey headings, 36-unit rows, the value or a switch on the right, DISPLAY first and account last. Register with `PS.registerSettings{ key, name, icon, open }` so the launcher's Settings list shows it. `PS.settingsPage{ title, rows }` draws one for an app without its own.
- **Search:** `PS.registerSearch{ key, name, icon, search = function(q) … end }`. It answers from memory, fast, with no network.
- **Set up your Kindle:** `PS.registerSetup{ key, order, title, text, done, action, run }`. Every step can be skipped.
- **Recent apps:** `PS.noteRecent(tileKey)` when the app opens. Keep the open screen on the plugin (`self.screen`) so the switcher can bring it back.
- **Pop-ups:** the shared look for menus, choices, confirms, toasts, waits (with Cancel) and Undo (`PS.popup.*` or the `KO.*` helpers). A menu opened from another menu shows **Back** instead of Close and returns to the one before (`KO.list(title, items, back)`, `KO.choose(..., back)`); the Back key does the same. A message runs its onOk however it's closed.
- **Pop-ups, text boxes and buttons: one design, with icons.** When the launcher is there, an app's own boxes use its pop-ups, not KOReader's dialogs:
  - typing goes in `PS.popup.request`: the text box with a pen at its end for handwriting, examples as rows, choices as tiles, Enter as the main button (`KO.askText` in apps.koplugin/appsko.lua for a plain one-line box);
  - an answer or other text to read goes in `PS.popup.read`, in pages;
  - menus, choices and confirms go in `PS.popup.menu/choose/confirm`.

  Buttons are an icon over a one- or two-word label, at most five in a row, with the main one black. Each is as wide as one of five in a row, never stretched to fill it, and the row lines up on the right with the main button last. The same action has the same icon everywhere: `x` Cancel, `check` Done or Save, `copy` Copy, `download` Save a file, `send` Answer or Send, `search` Search, `sparkles` an AI suggestion, `pencil` write by hand, `plus` Create. Labels say what happens ("Answer", "Beside", "Replace"), never something vague ("Write it", "Ask", or "OK" where a verb fits). KOReader's InputDialog, TextViewer and ButtonDialog are only the fallback without the launcher, and then the "Button rows line up" rule applies. New UI is shown as a mockup first and built once the user picks.
- **Button rows line up.** In KOReader's TextViewer, ButtonDialog and InputDialog, every row of buttons has the same number of buttons, so the dividers line up, with short labels ("Save", not "Save as command"). TextViewer adds its own Find | ⇱ | ⇲ | Close row under yours: set `add_default_buttons = false` and end your own row with copy, ⇱ (`id = "top"`, `viewer.scroll_widget:scrollToTop()`), ⇲ (`id = "bottom"`, `scrollToBottom()`) and Close (`viewer:onClose()`); the ids keep them greyed out at the ends. Drop Find where the text is short. Many choices go into even rows of 2 or 3 (To Do's new task), not rows of 1, 3 and 2.
- **Undo instead of confirms:** delete at once and offer Undo for about 6 s (`KO.undo(text, fn)`). Confirm only what can't be put back.
- **Swipes:** a swipe in from the leftmost 10% of the screen is Back, everywhere. Other horizontal swipes turn pages, and a plain swipe right on the first page does nothing. No other new gestures.
- **E-ink:** set `flash_on_uncover = true` on full-screen widgets (with `KO.flashOnUncover()` installed once) for a full refresh when a pop-up over them closes. Use a "full" update when the layout changes.
- **Night mode:** KOReader's own, the one setting. No app has a dark mode of its own; the SSH terminal is the one exception ("Dark terminal").
- **Quick buttons:** `PS.registerQuick{ key, name, choices = fn() -> { { id, name, icon, group } }, item = fn(id) -> { label, icon, on, value, tap(done), hold, steps = { minus, plus }, media = { ... }, chip } }` puts an app's buttons under the launcher's clock and in the control center (`apps.koplugin/appsquick.lua`). Tap does the quick thing and calls `done()`; hold opens what's behind it. Home Assistant, To Do, Syncthing and SSH register theirs.
- **Connection tests:** `PS.registerTest{ key, name, configured = fn() -> bool, run = fn(Test) -> { { name, detail, ok, why, raw, ms } } }` (`apps.koplugin/appstest.lua`). `run` goes in a child process, so blocking requests are fine; give one row per thing tried, each address on its own (home and away, each AI service, each host), and use `Test.http{ name, url, detail, headers, check }` and `Test.why(err)` for plain-words reasons. Each app's settings shows **Test connection** (`PS.showConnectionTest(key)`), the web page's tab a button (`App.connectionTest(key)` in `web/app.js`), and Settings > Launcher > **Connection check** and the web page's System tab test the ones you tick. Failures go to the log and the last results to the diagnostics file.
- **Microsoft account:** one App ID and one sign-in for every app that uses Microsoft (`apps.koplugin/appsmicrosoft.lua`, `PS.microsoft`). An app calls `PS.microsoft.use{ key, name, scope, signedIn, signedOut }` (its scope joins the one sign-in), gets tokens with `PS.microsoft.accessToken(force)`, checks `PS.microsoft.allowed(scope)`, and shows one **Microsoft account** row that opens `PS.microsoft.showSettings()`. An app's own older sign-in is handed over once with `PS.microsoft.adopt{...}`. The web page's card is `App.microsoftCard()`.
- **Backups:** each app puts its part in `PS.backupApps.<key> = { key, name, files = { patterns in koreader/settings }, dirs, reader_keys, secret_files, secret_keys = { [file] = { keys } }, secret_dirs }` (a plain table, so load order doesn't matter). The web page's backup (`webpage.koplugin/webbackup.lua`) zips every registered part and restores only into registered places; secrets go in only with **Include keys and sign-ins**.
- **The clock corner:** every app's title bar draws `PS.statusIcons()` (what's running now, from ongoing notifications, such as the web server's globe) just left of its clock. Ongoing notifications: `PS.notify{ ongoing = true, key, ... }` and `PS.unnotify(key)`.
- **Setup steps:** `PS.registerSetup` takes `skipped` (what you get without it) and `help` (short steps and a QR code of the guide in the public repo, `Setup.GUIDE_URL`).
- **Visual editors on the web page:** what the Kindle lays out (tiles, quick buttons, Home Assistant's Home, the widgets sleep screen, To Do's Home tiles, Notes' toolbar) is drawn as it looks there, to drag into order; `App.visualZones` in `webpage.koplugin/web/app.js`. Every one also has a tap menu (Move up, Move down, To...), since drag and drop doesn't work on phones.
- **Shared helpers live in the launcher.** Anything more than one app needs is written once in apps.koplugin and published on KOReader's PluginShare: menus and pop-ups (`PS.ko`, with `back` for menus opened from a menu), the title bar's clock corner (`PS.statusIcons`), notifications, the Settings list, search, setup steps, quick buttons, connection tests (`PS.registerTest`), AI (`PS.ai`), the Microsoft account (`PS.microsoft`), backups (`PS.backupApps`) and fonts. An app uses those when they're there. Its own copy, if it has one, is only the fallback for when the launcher isn't installed, and hands over to the shared one when it is (todo.koplugin/todoko.lua's wrapper at its end). A new app starts from the shared pieces, and a new helper goes into apps.koplugin first, never into one app only.
- **One copy of shared logic:** when the Kindle and the web page do the same thing, the code lives once and both call it (reading sessions: `apps.koplugin/appssessions.lua`, used by Reading statistics and the web page's Reading tab; group icons: `appsicons.lua`'s list).
- **Standard wording:** say what everyone else says ("Move up", "Move down", "Delete", "Reset statistics"), not invented phrases.

## Resources

- Load lazily: require big modules on first use, and only register through PluginShare at init.
- No new periodic timers. Clocks tick once a minute only while their screen is on top, and nothing runs while the Kindle sleeps.
- Anything per page turn (the book status bar) must be as cheap as KOReader's own footer.
- Sleep screens draw only from data already in memory or cache: no network at suspend.

## KOReader and Kindle pitfalls

- Use `self.screen` (or another name), never `self.view`, for a plugin's own widget: ReaderUI injects `self.view` into plugins.
- Plugin methods whose names start with "on" are event handlers: KOReader calls them in a sandbox that keeps only the first return value and swallows errors. Don't name helpers `onSomething`.
- `NetworkMgr:isOnline()` does a DNS lookup that can hang; use `NetworkMgr:isConnected()`.
- The Kindle's power manager ignores `PluginShare.pause_auto_suspend`. To keep it awake, use `lipc-set-prop com.lab126.powerd preventScreenSaver 1`, shared through `PluginShare.awake_reasons` (see `stayAwake` in the web server and Home Assistant), and also set `PluginShare.keepalive`. Without that flag, KOReader's AutoSuspend reschedules its Kindle timer check for "now" forever and freezes. The launcher also guards that check (`Apps.guardAutoSuspend`).
- While the Kindle is kept awake, closing the cover doesn't put it to sleep. That's expected.
- Kindles block incoming connections: open the port in the firewall while a server runs, and close it after.
- Closing a dialog over a full-screen widget leaves a ghost on e-ink: see `flash_on_uncover` above.

## Bugs we've hit (don't bring them back)

Each of these shipped once. The fix is in the code; the note is so a later change doesn't undo it.

- **Crash after waking with a book open.** Plugins stored their screen as `self.view`, which ReaderUI overwrites with its own view. Use `self.screen`.
- **KOReader frozen after the Kindle slept (web server on).** The Kindle's power manager ignores KOReader's `pause_auto_suspend`, so the Kindle slept with the server mid-transfer and KOReader hung. Fixes: keep it awake with `preventScreenSaver` while the server runs, stop the server on suspend, give up sends after two time-outs, handle one request per loop pass, and limit header and body reads. A watchdog script reports a stuck loop.
- **KOReader frozen after waking (no touch, light on).** AutoSuspend's Kindle timer check rescheduled itself for "now" forever when the Kindle had stayed awake past the sleep time. Fixes: set `PluginShare.keepalive` whenever we keep the Kindle awake, and the launcher's `guardAutoSuspend` turns that case into a check a minute later.
- **Freezes from the network on the UI loop.** `NetworkMgr:isOnline()` does a DNS lookup that can hang; To Do's sync and downloads used to run on the loop. Use `isConnected()`, and run network work in a child process with a deadline.
- **Only the pen worked after leaving a crossword.** Notes' pen hook took the end of a touch KOReader's gesture detector had seen start, so it waited for a lift that never came. The hook now leaves such touches to KOReader, and closing a book resets touch state.
- **Errors that vanished.** Plugin methods named `on…` (even `oneNote…`) are event handlers that KOReader wraps: only the first return value survives and errors are swallowed. Don't start helper names with "on".
- **Ghosts on e-ink after a pop-up closed.** Use `flash_on_uncover` with the shared close hook; a layout change needs a "full" refresh, not "ui".
- **A stray "null" on the web page.** `element.append(a, null)` turns `null` into text. Filter out empty parts before appending.
- **A stray tap closed a waiting box** (a download in progress). Waiting boxes ignore taps; only Cancel or Back stops them.
- **Garbled symbols in Lua strings** after editing with a script: Python escapes like `"\xE2…"` in a script's own source turned into mojibake. Write UI text as real UTF-8, and grep after scripted edits.
- **An icon missing from an app's own icons/** showed as a grey box (Pangolin's Recent apps button: its copy of the title bar draws "history", and it had neither that nor the fallback "star"). Each app draws only from its own icons/; when it copies a module from another app, it copies the icons that module draws too, and always the fallback "star" (and "star-w" when it has white icons). `dev/icons.py` (in `dev/check.sh`) checks it.
- **A symbol missing from the Kindle's fonts** showed as a box. KOReader's UI fonts lack many symbols: use the bundled Lucide icons instead of Unicode symbols in the UI, and check any new glyph.
- **Tests left behind** after a feature changed (a new launcher tile broke the tile-order tests). Update the expected values in the same change.
- **Notes for coding agents on the Kindle.** AGENTS.md, CLAUDE.md and the docs, tests and tools folders ended up in the install zip when a plugin folder was copied whole. The install folder and the zip hold only what runs on the Kindle; build the zip with the one script that leaves those out.
- **Personal data in screenshots and test fixtures** (real device names, task titles, paths). Screenshots and fixtures use made-up data; the privacy check (`tools/privacy_check.py`) blocks real values.

## Branches, commits and pull requests

This repo is public, and so is everything sent to GitHub: files, commit messages, branch names, pull requests and their comments, release notes and pictures. Deleting it later doesn't take it back (forks and caches keep it), so nothing personal goes in at all.

- **One branch per task**, merged into `main` through a pull request.
- **Turn on the privacy check once per clone**: `git config core.hooksPath .githooks`. Its hooks run `tools/privacy_check.py` on what's staged (pre-commit), on the commit message (commit-msg) and on every commit a push sends, with its author and the branch name (pre-push). GitHub's Privacy workflow checks pushes and pull requests again, a pull request's title and description too.
- **Never get around it** (no `--no-verify`). If it flags a made-up example, add that to the allowed examples in the script; if it flags something real, change it to a made-up value.
- **Check text before it goes up**: a pull request's title and description, a comment or release notes go through `python tools/privacy_check.py --text -` (on stdin) first.
- **Commit by path** (`git add <files>`), never `git add -A` or `git commit -a`, and look at `git diff --cached` before committing. Files that stay on the PC are never staged: `*.local.*`, `todo.koplugin/client_id.txt`, `notes.koplugin/notes_defaults.lua`, `.env` (`.gitignore` has them, and the check blocks them).
- **Commits are made under the account's GitHub noreply address** (`git config user.email`), never a personal one.
- **Pictures** use made-up data only, carry no metadata (the check blocks EXIF and PNG text chunks) and are looked at by eye before committing: the check lists them.
- **On the user's PC the check also knows the user's own values**, read from files that never go into git (`private-words.local.txt` in the main checkout: a word per line, or `re:` and a regular expression). Never copy those values anywhere else, a test or a commit message included.
- **If something personal was pushed**, stop and tell the user before anything else; a new commit that removes it leaves it in the history.

## Testing

- Each plugin has `tests/run.lua`, plain Lua, run with KOReader's LuaJIT from the plugin folder: `luajit tests/run.lua`.
- The KOReader emulator (the Linux AppImage, extracted) runs the plugins on a PC: link the plugin folders into its `plugins/` and start it with `EMULATE_READER_W=1240 EMULATE_READER_H=1654 EMULATE_READER_DPI=200` for the Scribe's shape. `SDL_VIDEODRIVER=offscreen` with `Screen:shot()` takes screenshots.
- A test release (to install on the Kindle before a real one): `bash tools/test-release.sh [notes.md]` from a branch other than main. It runs the tests, pushes the branch, tags the next `vX.Y.Z-testN` and waits for GitHub to build it as a pre-release, which only shows under Settings > Updates > Select version, with Show test versions on.
- Behaviour that only exists on a Kindle (power manager, sleep cover, lipc, firewall) can't be tested on the emulator: prove it on the device with a log-only probe before building on it.

## The guide

One chapter per app in `guide/`, written as instructions in the guide's plain style, with screenshots from made-up data only. `guide/chapters.txt` sets the order and `guide/build.py` makes the PDF for the Scribe's page size (see the README). When an app's UI changes, update its chapter and screenshots in the same change.
