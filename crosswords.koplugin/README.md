# Crosswords for KOReader

Crosswords from the Guardian (Quick, Cryptic, Quiptic, Prize), USA Today, Universal, the Washington Post
(Sundays) and the New Yorker, and puzzle books from PDFs, .puz and .ipuz files, solved with the pen on a
Kindle Scribe in KOReader.

It needs the **Notes** plugin (notes.koplugin): the puzzles are written on with Notes' pen and kept as
Notes notebooks. Without Notes, Crosswords says so when opened.

- Open it from **Tools > Crosswords**, the launcher's tile, or a gesture (**General > Crosswords**).
  **Today's crossword** is a gesture of its own.
- How to use it: [docs/guide-crosswords.md](docs/guide-crosswords.md) (a chapter of the Kindle apps
  guide).
- How the sources work, and how to fix or add one: [docs/crosswords.md](docs/crosswords.md).

## Files

- `main.lua`: the plugin (menu entry, gestures, the launcher's settings and search), and adding
  `crosswordsui.lua` to Notes.
- `crosswordsui.lua`: everything you see that's about crosswords: the Crosswords list, Get a crossword,
  Today's crossword, automatic downloads, Crossword settings, hints, Check my answers, stats, imports, and
  what the web page and the launcher ask for.
- `crosswordspuz.lua`: .puz and .ipuz files; plain Lua.
- The layout, sources and parsers (`notescrossword.lua`) are in Notes, because Notes' editor draws the
  puzzle pages.

Tests: `luajit tests/run.lua` from this folder, with notes.koplugin beside it.

Crosswords was part of notes.koplugin until 2026-10-24; its earlier history is in that repository.

The puzzles are fetched for your own use on the reader.
