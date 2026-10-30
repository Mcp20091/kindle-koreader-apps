# AGENTS.md: Crosswords for KOReader

Notes for AI coding agents working on this plugin. The shared pieces of the KOReader apps (title bar,
notifications, settings, search, pop-ups, Undo, Recent apps, gestures) are described in the top-level
AGENTS.md of the apps; this file covers only Crosswords.

## What it is

Crosswords downloads puzzles (the Guardian's Quick, Cryptic, Quiptic and Prize; USA Today; Universal; the
Washington Post on Sundays; the New Yorker on weekdays), lays them out as pages for the Kindle and lets
you solve them with the pen. It also imports PDFs of puzzles and .puz/.ipuz files.

It needs the **Notes** plugin (notes.koplugin). The puzzle books are Notes notebooks, written on with
Notes' editor and kept by Notes' store. The AI (Claude, Gemini, OpenRouter, Groq, a local or a custom AI) is the launcher's
(apps.koplugin, Settings > AI); Crosswords reaches it through Notes' wrappers: `self:claude(job)`,
`self:aiName(job)`, `self:aiNotReadyText(job)`, `self:aiInstructions(key)` and `Notes.addAiFeature`
(the launcher's `PS.ai` is the direct API). Without Notes, Crosswords only says it needs it.

## How it's built

- `main.lua`: the plugin. At init it finds Notes' plugin class in KOReader's
  `PluginLoader.enabled_plugins` and adds `crosswordsui.lua`'s functions to it, so they run as
  `Notes:…` with Notes' store, editor and AI. It registers the menu entry, the gestures
  (`crosswords_show`, and `notes_crossword` for Today's crossword: that id is kept so gestures set up
  before the split still work) and the launcher's settings and search.
- `crosswordsui.lua`: everything about crosswords that you see: the Crosswords list (Notes' notebook
  list with `crosswordsApp` set: `Notes:showCrosswords`, `Notes:crosswordsItems`), Get a crossword,
  Today's crossword, automatic downloads, Crossword settings, hints, Check my answers, stats, imports,
  removing puzzles, and the calls the web page and the launcher use.
- `crosswordspuz.lua`: .puz and .ipuz files into the puzzle shape; plain Lua.
- In **Notes**: `notescrossword.lua` (the sources' addresses and parsers, the page layout upright and
  on its side, the books' PDFs, puzzle state, stats, the AI prompts and the spoiler check) stays there
  because Notes' editor, page list and covers draw the puzzle pages. Notes guards every call into
  Crosswords with `Notes:hasCrosswords()`.
- `docs/crosswords.md`: how each source works, how to fix one that breaks, how to add one. Read it before
  touching downloads or parsers. `../guide/crosswords.md`: the user guide chapter.

### Data

- A source's book is a Notes notebook with `puzzle = true` and `feed = "<source>"`; each page has `pz`
  (which puzzle page it shows, e.g. `"quick/17616:1"`). A puzzle's first page keeps `secs`, `done`,
  `ticks` and `nclues`. Writing is stored per page, so it survives the book's PDF being made again.
- The raw replies from the sites are kept in `koreader/notes/crosswords/` (one file per puzzle) and
  parsed again when a book is laid out again.
- Settings live in Notes' settings, all prefixed `crossword_`: `crossword_books` (source → book id),
  `crossword_today`, `crossword_source`, `crossword_kind`, `crossword_auto` (sources fetched
  automatically) and `crossword_auto_at`, `crossword_clues` (`"large"` or unset), `crossword_boxes`, `crossword_swap` (grid and clues swapped: a book's `lay` then has `+s`, and when that changes `Crossword.moveGrids` moves the writing in each grid with it),
  `crossword_card`, `crossword_find`, `crossword_timer`, `crossword_finished`, `crossword_recent`;
  plus `puzzle_buttons` (the toolbar's pinned buttons). Don't rename them: existing books depend on them.

### Downloads and the AI never block KOReader

- Every network call runs in a child process (`inBackground`: `ffiutil.runInSubProcess`, the result as
  JSON over a pipe, polled every 0.2 s, given up after a time limit). `Notes:download(text, job, done,
  limit, onCancel)` wraps it with a wait box that only its **Cancel** stops; after Cancel the result is
  dropped and `onCancel` runs (clear any busy flag there).
- Network requests ask for Wi-Fi the way KOReader does (`NetworkMgr:runWhenOnline`) and never turn it on
  for the automatic downloads.
- AI hints and checks send a cropped picture and a prompt through the launcher's AI (via Notes), in the background.

### AI prompt rules

- A hint never gives the answer. `Crossword.hintPrompt` escalates over repeated hints for the same clue;
  `Crossword.spoils` checks the reply, asks once more, then shows nothing rather than a spoiler.
- Prompts talk about the clue and its answer only: never which of the user's letters look right or
  wrong, never the picture or the handwriting, never "I can't read it".
- Small local models get cryptic wordplay wrong; the prompt tells them to hint at the meaning instead of
  guessing. Claude does much better there.
- Check my answers only reports which squares look wrong (dots); the right letters stay on the Kindle.

## Shared helpers

Helpers more than one app needs live in the launcher (apps.koplugin) and are reached through KOReader's
PluginShare (`PS.ko`, `PS.ai`, `PS.microsoft`, `PS.registerTest`, `PS.backupApps`, `PS.statusIcons`…); see
apps.koplugin/AGENTS.md. This plugin uses them when the launcher is there, and its own copies are only the
fallback without it (KOReader's own pop-ups, for example). Some it reaches through Notes, which wraps them
(the AI, `KO.*`). A new helper goes into apps.koplugin, not here.

## Shared pieces, as Crosswords uses them

- **Title bar, list, settings page:** Notes' (`notestitle`, `notesgrid`, `notessettingspage`), so they
  follow the shared design when Notes does. Crosswords keeps the open list as `ui.crosswords.screen`.
- **Notifications:** key `"crosswords:new"` for automatic downloads; taken out with `PS.unnotify` when a
  downloaded crossword is opened. `PS.notifyOpeners.crosswords` opens one after a restart.
- **Settings and search:** `PS.registerSettings{ key = "crosswords" }` (opens Crossword settings) and
  `PS.registerSearch{ key = "crosswords" }`, answered from memory (each book's puzzles cached, a book
  read again only when it changed). Register at init only.
- **Pop-ups:** Notes' `KO.list/choose/buttonDialog/toast/wait`, and `PS.popup.message`,
  `PS.popup.wait(text, { cancel })` and `PS.popup.undo` when the launcher has them, with KOReader's own
  widgets as the fallback.
- **Undo:** removing a puzzle keeps the book as it was and the puzzle's reply file, and the undo bar puts
  both back. Deleting a whole book is Notes' notebook delete (its own Undo).
- **Recent apps:** `PS.noteRecent("crosswords")`, the launcher tile's key.

## Pitfalls

- **Pen and touch:** never add work to pen input or hook input in the drawing area: no code may run
  while the pen draws. Finger taps in a puzzle (tick boxes, numbers, clue arrows) are handled by Notes'
  editor; it ignores fingers only while the pen writes. Leaving a puzzle once left KOReader's gesture
  detector holding a half-finished finger contact, so only the pen worked until lock and unlock; the
  editor now resets the input state when it closes. Test finger taps after leaving a puzzle.
- **KOReader sandboxes plugin methods whose names start with `on`:** only the first return value comes
  back and errors are swallowed. Don't name helpers `on…`.
- **Gestures go to the top widget only.** `Dispatcher` sends an action to whatever is on top; test
  Today's crossword from the library, not over a pop-up.
- **Publishers' formats change.** The Guardian's list comes from a series page, Universal needs a long
  token in its address, the Washington Post's Sunday puzzle only exists from May 2025, the New Yorker takes
  two requests. When one breaks, follow "When a source breaks" in `docs/crosswords.md` (xword-dl's
  downloaders show the current addresses). Avoid sources behind the AmuseLabs player: they scramble.
- **Busy flags and Cancel:** anything that sets a flag before `Notes:download` must clear it in
  `onCancel` too, or it stays set until KOReader restarts.
- **Python edit scripts:** writing Lua through a shell heredoc can turn `"\n"` escapes into real
  newlines; check strings after any scripted edit.

## Testing

- Plain tests: `luajit tests/run.lua` from this folder, with notes.koplugin beside it (the tests load
  `notescrossword` from `../notes.koplugin`). Notes' own `tests/run.lua` covers the parsers, layout and
  books.
- Emulator: KOReader's emulator with notes.koplugin and crosswords.koplugin in its `plugins/` folder
  (the launcher, apps.koplugin, and the Web page plugin too, for the tiles, pop-ups and web tab), a screen of 1860×2480 at
  300 dpi like the Scribe, and the network for real downloads. A small driver plugin can call
  `ui.crosswords:show()`, `ui.notes:fetchCrossword("quick", 17616)`, `ui.notes:getCrossword("usa")`
  and take screenshots. The pen opener is stubbed out on the emulator.
- For AI features, point Notes' local AI at an Ollama address of your own (for example
  `http://192.168.1.50:11434`); the first request after Ollama has been idle is slow while it loads.

## Rules

- Never make pen input slower or add anything to its path.
- Plain, standard wording in the UI and docs; say "Kindle".
- Screenshots use made-up data only (puzzle content is fine): no names, addresses, keys or devices.
- No personal data in code, tests or docs: example values only.
- Keep `../guide/crosswords.md` in step with what the UI does.
