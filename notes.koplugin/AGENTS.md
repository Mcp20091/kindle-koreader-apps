# Notes (notes.koplugin): notes for AI coding agents

Read the top-level AGENTS.md first: it covers the shared pieces (title bar, pop-ups,
notifications, settings hub, search, Recent apps, Undo) that every app here uses. This file
is only what is true of Notes.

## What it is

Handwritten notebooks for KOReader on a Kindle Scribe: the pen writes, fingers work the
buttons. Notebooks in folders, search, tidy handwriting, PDFs as notebooks, OneNote sending
and browsing, AI (the launcher's services: Claude, Gemini, a local AI…) to read handwriting and answer.

## How it is built

- `main.lua`: the plugin (`Notes`), opening and closing notebooks, the notebook list,
  settings wiring, ⌂/⋮/Back. Feature mixins add methods to `Notes`: `notesfolderui`,
  `notestextui` (AI features, To Do, settings sub-pages, `listPage`), `notesonenoteui`/`notesonenoteview`,
  `notesfind` (search, links), `noteslock`, `notesclose`, `notesquick`, `notestodolink`.
- `noteseditor.lua`: the drawing screen (toolbar, panels, pages, lasso, zoom). Big; edit with care.
- `notespen.lua`: reads the pen straight from the digitizer (evdev), not through KOReader's touch.
  `Pen.held()` asks the digitizer once which buttons are held (EVIOCGKEY), outside the event stream.
- `noteshandnote.lua`: handwritten notes on highlights in KOReader's reader ("Write a note" in the
  highlight menu, the quick note's pad, `Quick.padBackground`). Ink in the book's settings
  (`notes_handnotes`, keyed by the highlight's datetime, in the pad's units); the highlight's note is
  "Handwritten note", so KOReader's note mark opens the pad. The side button held while selecting
  makes the highlight at once (`pen_highlight`, on, no settings row yet); not proven on a Kindle, so
  `noteshandprobe.lua` and the "Notes: pen button check (test)" menu item log what the pen reads (remove
  them once it's proven). Nothing of it is in the input path.
- `notesink.lua`, `notesshapes.lua`, `notestidy.lua`, `notespaper.lua`, `notesitems.lua`:
  plain Lua (no KOReader modules), unit-tested.
- `notesstore.lua`: one Lua file per notebook, `koreader/notes/<id>.lua`, read back in an empty
  environment; `index.lua` (summaries), `trash/` (`trash.lua`), `folders.lua` (notesfolders).
  The notebook format is at the top of notesstore.lua; strokes are `{ t, w, p, q }` with `p` a
  flat list of numbers.
- Settings: `G_reader_settings` key `"notes"`, through `notessettings.lua` (`Settings.get/set`,
  `DEFAULTS`). Side files in KOReader's settings folder: `notes_text.lua` (text read from pages), `notes_onenote.lua`, `notes_todo.lua`. An untracked
  `notes_defaults.lua` beside main.lua can preset settings; never commit one.
- `notessettingspage.lua`: the full-page settings and plain lists (rows, switches, paging) in
  the shared design. `notestitle.lua`: Notes' copy of the shared title bar (every full screen of
  Notes has it: the list, settings, All pages, the file picker; the writing screen has its side
  toolbar instead). `notespick.lua`: picking a file (From a PDF…, a picture) as a list page with the
  bar, instead of KOReader's PathChooser.
- `notesko.lua`: KOReader glue and the shared pop-ups (`KO.list/choose/confirm/message/toast/
  wait/undo/buttonDialog`), falling back to KOReader's own widgets when Apps isn't installed.
- `notesshare.lua`: registration with Apps (settings, search, OneNote's connection test, Recent apps).
- The AI is the launcher's (`apps.koplugin/appsai.lua`, `PS.ai`; Settings > AI): services, keys
  (`ai_secrets.lua`), which service does each job, and each feature's instructions. `notestextui`
  registers Notes' jobs (`read`, `ask`, `draw`) and features (`PS.ai.registerJob/registerFeature`) and
  keeps `Notes:claude(job)`, `claudeReady`, `aiName`, `aiInstructions`, `handwritingSettings`,
  `Notes.addAiFeature`… as thin wrappers (Crosswords calls them). `notesclaude.lua` has only Notes'
  prompts (reading, to-do items) and `parseTasks`. Without the launcher (`PS.ai` nil) there is no AI.
  The launcher moved Notes' old AI settings and `notes_secrets.lua` keys over once.
- Background work: `notesbg.lua` (`Bg.run(job, done)`) runs network jobs in a child process
  (`ffiutil.runInSubProcess`) and returns the result as Lua data. Automatic things (OneNote
  sending, suggested names, PDF building for the web page) never block KOReader's loop. The
  user asked for waiting boxes, not background work, for AI they start (Ask, Convert, hints).
- OneNote's sign-in: the launcher's one Microsoft account when it's there (`PS.microsoft`, Settings >
  Microsoft). `Notes:useMicrosoftAccount` (at init) hands notes_onenote.lua's old tokens over once (or
  drops them when the account has its own) and registers OneNote's scope; `OneNote.new{ account }` then
  asks it for tokens, and `needsAllow()` is "signed in for To Do only: sign in again". Without the
  launcher, notes_onenote.lua keeps OneNote's own tokens as before.
- OneNote: where a notebook goes is its own choice, else its folder's (or a folder above), else the
  default notebook (`onenote_targets` keyed "n:<id>" / "f:<path>", `OneNote.targetFor`; folder renames
  move them with `OneNote.moveTargets`). Only pages Notes sent (kept in notes_onenote.lua "sent") are
  ever updated or deleted, so a shared section is safe.

## Shared helpers

Helpers more than one app needs live in the launcher (apps.koplugin) and are reached through KOReader's
PluginShare (`PS.ko`, `PS.ai`, `PS.microsoft`, `PS.registerTest`, `PS.backupApps`, `PS.statusIcons`…); see
apps.koplugin/AGENTS.md. This plugin uses them when the launcher is there, and its own copies are only the
fallback without it. A new helper goes into apps.koplugin, not here.

## Pop-ups, text boxes and buttons

Notes' own boxes follow the launcher's design (apps.koplugin/AGENTS.md): with the launcher, typing goes in
`PS.popup.request` (a pen at the end of the box, examples as rows, the papers as tiles, icon buttons),
answers in `PS.popup.read`; the main button is black, labels say what happens, the same action has the
same icon in every app. Examples: Ask and Draw with AI and the answer (notestextui.lua), New notebook
(main.lua), Rename (notesclose.lua), folder names (notesfolderui.lua), Search. KOReader's InputDialog and
TextViewer are only the fallback without the launcher, with the same number of buttons in every row.
New UI is shown to the user as a mockup first.

## Shared pieces, as Notes uses them

- Title bar on the notebook list and every settings/list page; ⌂ and the bell only when Apps
  is there (`PS.appsHome`, `PS.showNotifications`). The drawing screen has no bar: its toolbar
  has ⌂ first and ⟳ / bell / ⚙ fixed at the bottom (`Editor:fixedButtons`).
- Back: a swipe that starts at the left edge (`KO.fromLeftEdge`), only on list/settings pages.
- Undo after deleting notebooks and folders (`Notes:offerUndo`, `Folders:snapshot/restore`);
  without Apps there is no Undo, so it asks first.
- Search registered with Apps answers from memory only (the store's index and pages Notes'
  own search has cached); never read notebooks from that path.
- Notes posts no notifications of its own today. If you add one, give it one key per thing
  (`notes:<what>:<id>`) and take it out when it's done.
- `Notes:shown(widget)` keeps `self.screen` for Recent apps; it skips Crosswords' mode.

## What Crosswords relies on

Crosswords (crosswords.koplugin) adds methods to `Notes` at runtime and uses Notes' editor,
store, covers grid, settings page and `notescrossword.lua` (page layout, parsers, state).
Puzzle books are notebooks with `puzzle = true`. Guard Crosswords calls with
`Notes:hasCrosswords()`; without it, puzzle books open as plain notebooks. Changing the editor,
the store format or notesgrid can break Crosswords: tell its maintainers.

## Pitfalls

- KOReader sandboxes plugin methods whose names start with `on` (it treats them as event
  handlers): only the first return value comes back and errors vanish. That includes the
  existing `oneNote…` methods, so they return one value and report failures themselves. Don't
  name a new method `on…` unless it is an event handler.
- Pen input: never add work, hooks or logging to the pen path (notespen, the editor's stroke
  code). The digitizer can drop events (SYN_DROPPED); notespen resyncs with EVIOCGKEY and
  EVIOCGABS. A resting palm must never write or turn pages.
- E-ink: on the Scribe only a "full" refresh clears ghosting; "a2" can't take grey to white,
  "fast" can. Screens set `flash_on_uncover = true` (KO.flashOnUncover).
- Writing Lua from Python scripts mangles `\n` and `\128`-style escapes; edit those lines
  directly and grep for control bytes afterwards.
- `Store:list()` stats every notebook file; don't call it per keystroke or per gesture.
- Things that look wrong but are right: the editor passes two-finger and edge gestures to
  KOReader's Gestures plugin (`KO.passGesture`) on purpose; `notesko` wraps
  `Dispatcher.execute` / `UIManager.broadcastEvent` / `UIManager.close` once, shared with the
  other apps (guard flags `apps_*`).

## How to test

- Unit tests: from the plugin folder, `luajit tests/run.lua` (KOReader's luajit works); all must pass.
- Syntax: `luajit -e 'assert(loadfile("main.lua"))'` for each changed file.
- Emulator: a KOReader AppImage (2026.07+) on Linux or WSL, with this folder (and
  apps.koplugin for the shared pieces) linked into its `plugins/`. Run with
  `EMULATE_READER_W=1860 EMULATE_READER_H=2480 EMULATE_READER_DPI=300` and a fresh HOME whose
  `settings.reader.lua` has `quickstart_shown_version = 99999999999999` and
  `color_rendering = false`. There is no pen there: set `require("notespen").findDevice` to
  return nil and drive the editor from a small driver plugin (penDown/penMove/penUp).
- Screenshots: `Device.screen:shot(path)` from a driver plugin; override `Device.hasKeys`
  and `hasKeyboard` to false so lists show no key letters.

## Rules

- Never add latency to pen input.
- Plain, standard wording; say "Kindle". Settings in sentence case.
- Screenshots and examples use made-up data only (e.g. "Garden project", 192.168.1.50,
  /mnt/us/documents). No personal data in code, comments, tests or docs: no names, devices,
  addresses, keys, real notebook or task titles.
- Keep ../guide/notes.md in step with the UI when you change it.
