# Wikipedia for KOReader

Search and read Wikipedia on the Kindle, and save articles to read without Wi-Fi.

- **Front page**: a search box and **Random**, then three tabs:
  - **Today**: today's featured article (**Read** or **Save** it there) and On this day (tap an event for its article; **All events**). **In the news** and **Most read yesterday** can be turned on in the settings. Today is kept for the day, so it shows again without Wi-Fi.
  - **Saved**: the articles on the Kindle, newest first or by title. Hold one for **Open**, **Update** (download it again), **Open on the web page** and **Remove**; **Select** removes several.
  - **Recent**: what you opened, by day, with the page you got to.
- **Reading**: an article opens in KOReader's reader as an EPUB (KOReader's own Wikipedia EPUB code), with your font, size and margins (carried from one article to the next), highlights and the dictionary. The article's sections are its table of contents, and its sources are footnotes: tap a [1] to see it.
- **The toolbar** (on the left like Notes, or across the top: Settings > Toolbar) takes the place of KOReader's status bar: Home (the launcher), Back (the article before, where you left it), Search, Contents, Save (filled when saved; tap again to remove), Language (the article in another language), Text (KOReader's font settings), page up and down with the page, More (Wikipedia home, Update, Open on the web page, Wikipedia settings, KOReader menu, Close Wikipedia) and Hide toolbar (a small tab in the corner brings it back).
- **Links**: tapping a link to another article shows a short preview with **Save** and **Open** (Settings > Tap a link > Open skips it). A link to an article on the Kindle opens straight away.
- **Saved articles** are EPUBs in the Wikipedia folder of the Library (`Nixon in China.EN.epub`, named as KOReader names its own), so they open without Wi-Fi and show in the Library. Articles read without saving are kept a while in KOReader's cache (for Back and Recent).
- **The title bar** (as in every app): back and the house (the launcher) on the left; the language, time, battery, Refresh and ⋮ (Open on the web page, Settings) on the right.
- **Settings** (⋮ > Settings): Language, Images (off is faster and smaller; with Images on, an unsaved article read before without them is downloaded again when opened, and Update brings them to any article), Toolbar, Tap a link, Save to, the front page's sections, Keep recent, Clear recent, Show in recent books (off: articles stay out of KOReader's history and the launcher's recent books), Open on the web page.
- **The web page** (webpage.koplugin) has a Wikipedia tab: the saved articles (download the EPUB, remove), search and save an article to the Kindle, and what was read recently.

**Open it**: Tools > Wikipedia, a gesture (Settings > Taps and gestures > Gesture manager > a gesture > General > Wikipedia), or the launcher (apps.koplugin; event `ShowWikipedia`; `ui.wikipedia:appsLine()` gives its line, e.g. "4 saved · Nixon in China").

## Install

Copy this folder to `koreader/plugins/wikipedia.koplugin` and restart KOReader.

## Development

```bash
luajit tests/run.lua
```

`main.lua` (opening, saving, Back, the launcher and web page), `wikihome.lua` (the front page, search and settings), `wikitoolbar.lua` (the toolbar, Contents and the link preview in the reader), `wikistore.lua` (settings, saved and cached files, recent, today), `wikiapi.lua` (Wikipedia's API), `wikiepub.lua` (KOReader's EPUB builder), `wikimodel.lua` (plain Lua, tested), `wikicanvas.lua` (drawing in page units, as in apps.koplugin). Icons are [Lucide](https://lucide.dev) (ISC licence, `icons/LICENSE-lucide.txt`).
