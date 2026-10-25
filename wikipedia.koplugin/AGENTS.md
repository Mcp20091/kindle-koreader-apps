# Notes for AI coding agents: Wikipedia

What the plugins share (rules, the title bar, PluginShare, pop-ups, the guide) is in the top-level `AGENTS.md` of the plugins' repository. This file covers only what's specific to Wikipedia.

## What it does

Lets you search and read Wikipedia on a Kindle in KOReader, and save articles to read offline. Each article is an EPUB built with KOReader's own Wikipedia code. It opens in KOReader's reader with Wikipedia's toolbar, so fonts, highlights and the dictionary work as in any book. It has its own front page (Today, Saved, Recent), search, settings and a tab on the web page.

## Files

| File | What's in it |
|---|---|
| `main.lua` | The plugin: opening articles, Back, saving and removing, the launcher hooks, the web page's routes, and the module-level `state` |
| `wikihome.lua` | The full-screen front page: Today, Saved and Recent, search results, events, settings |
| `wikitoolbar.lua` | The toolbar in the reader (left or top), the Contents and link-preview panels, link taps |
| `wikibar.lua` | The shared title bar drawn on Wikipedia's canvas (a copy of `appsbar.lua`'s draw), the ⋮ menu, wrappers for the shared pop-ups |
| `wikibg.lua` | `Bg.run(fn, done, opts)`: runs network work in a child process |
| `wikiapi.lua` | Wikipedia's API (search, summary, random, languages, the featured feed) |
| `wikiepub.lua` | Builds an EPUB through KOReader's `ui/wikipedia` `createEpub`, plus our CSS (infobox, section flow) |
| `wikistore.lua` | Settings, saved and cached files, metadata, recent, today, the reading style kept between articles |
| `wikimodel.lua` | Plain Lua with no KOReader: file names, URLs, the feed, languages. Covered by `tests/run.lua` |
| `wikicanvas.lua` | Draws in page units (620 wide), as Apps does |

## Data it keeps

- **Settings:** `<settings dir>/wikipedia.lua` (LuaSettings), behind one shared `Store.get()`. The plugin is created again for every book and the library; the store is not. Keys:
  - `lang`, `images`, `toolbar` (`left`/`top`), `toolbar_hidden`, `link_tap` (`preview`/`open`)
  - `folder` (where articles are saved; nil means the Library's `Wikipedia` folder)
  - `keep_recent`, `in_history`, `saved_sort` (`newest`/`title`), `sections` (the front page)
  - `meta`: by file name, `{ title, lang, description, images }`
  - `recent`, `today` (the day's feed, by date and language), `style` (reading settings carried to the next article)
- **Saved articles:** EPUBs in the save folder, named like KOReader names its own: `Nixon in China.EN.epub` (see `wikimodel.fileTitle`). They show in the Library too.
- **Unsaved articles:** the same naming in `<cache dir>/wikipedia/`, trimmed to the last 20.
- **Backup** (the web page's, `PS.backupApps.wikipedia`): only `wikipedia.lua`. Saved articles are in the Library and can be downloaded again. `Store:write` reads the file again if it changed on disk (a restore), so the copy in memory doesn't overwrite it.
- **Removed with Undo:** renamed to `….epub.removed` beside the file for about 8 s, then deleted. Leftovers are swept by `listSaved`.

## Network and EPUBs

- All network work runs in a child process (`ffiutil.runInSubProcess`), returns JSON over a pipe and is polled every 0.2 s (`wikibg.lua`). The main loop never waits on the network.
- A shared wait box shows meanwhile, and a tap stops the work. A tap in its first second is ignored, because the rest of the tap that started it would stop it otherwise.
- Time limits: 60 s by default, 45 s for Today, 600 s for a download.
- Saves started from the web page run in their own child process and report through a notification.
- `wikiepub.lua` calls KOReader's `createEpub`. To add our CSS and HTML, it briefly wraps `Archiver.Writer.addFileFromMemory`. With Images off, it builds without images, and `meta.images` records which. With Images on, an unsaved copy built without images is downloaded again (`needsImages`).
- Before going online: `NetworkMgr:runWhenConnected` / `isConnected`. Never `isOnline`: it does a DNS lookup on the main loop and freezes the Kindle on bad Wi-Fi.

## Shared helpers

Helpers more than one app needs live in the launcher (apps.koplugin) and are reached through KOReader's PluginShare (`PS.ko`, `PS.ai`, `PS.microsoft`, `PS.registerTest`, `PS.backupApps`, `PS.statusIcons`…); see apps.koplugin/AGENTS.md. This plugin uses them when the launcher is there, and its own copies are only the fallback without it. A new helper goes into apps.koplugin, not here.

## Shared pieces it uses

All of these are optional, checked with `if PS.x then`. Without Apps, Wikipedia falls back to KOReader's own widgets.

- **Title bar** (`wikibar.lua`):
  - ‹ and ⌂ (`PS.appsHome`), Recent apps (`PS.showSwitcher`)
  - the clock, battery and ▾ open `PS.showControlCenter`
  - ⟳, 🔔 (`PS.showNotifications`, badge from `PS.notifyCount`), ⋮ with Settings last
- **Notifications:**
  - `PS.notify{ app = "wikipedia", key = "wikipedia:save:<lang:title>", route = { saved = path } }`
  - `PS.notifyOpeners.wikipedia(route)` opens a route after a restart
  - `PS.unnotify(key)` runs when that article is opened or removed
- **Settings:** `PS.registerSettings{ key = "wikipedia", open = fn(name), rows = fn() }`: `rows` (`Home.settingRows`, kept in step with `drawSettings`) lets the launcher's search find each setting, and `open(name)` shows the settings page with that row. **Search:** `PS.registerSearch` (saved articles, from an in-memory index). **Recent apps:** `PS.noteRecent("wikipedia")` when the front page shows.
- **Pop-ups:** `PS.popup.menu` / `confirm` / `choose` / `toast` / `wait` / `undo`, through `wikibar.lua` (`Bar.list`, `Bar.confirm`, `Bar.notice`, `Bar.wait`, `Bar.undo`).
  - Remove has no confirm when Undo is available; without Apps it asks first.
  - The two long language lists stay KOReader's `Menu`, and typing stays `InputDialog`.
- **Buttons:** `Bar.iconButtons` draws the launcher's button row (appspopup's `iconButtons`: icon over label, as wide as one of five, lined up on the right, the main one black) and follows its Button labels setting. With the launcher it hands over to `PS.popup.iconButtons` (which draws in this canvas's colours); this copy draws only without the launcher. `enabled = false` greys a button out in both.
- **Full screens:** lists (the language, another language's article) and the Save to folder are Wikipedia's own screens with the title bar (`Wikipedia:showPick`, Home's `pick` and `folder` tabs), not KOReader's Menu or PathChooser.
- **Copy:** `Bar.copy(text)` (clipboard and a toast): the link preview's Copy, and holding a search result or an event.
- **Swipes:** a swipe east that starts in the leftmost 10% is Back (`Bar.fromLeftEdge`); other swipes turn pages, and page 1 does nothing. In an article, a touch zone `wikipedia_edge_back` overrides Apps' `apps_edge_back`, so Back goes to the article before.
- **Night mode** is KOReader's; there is no dark setting here.

## Reader hooks (an article open in ReaderUI)

- `init`: if the document is one of ours (`store:article(path)`), it calls `store:giveStyle(doc_settings)` before KOReader reads the settings, then attaches the toolbar.
- The toolbar is a view module (`registerViewModule`) plus full-screen tap and hold touch zones with `overrides`. Both are set on the instance, never on the class.
- On the instance it wraps:
  - `ui.typeset.onSetPageMargins`: makes room for the toolbar, minus the hidden footer's height
  - `ui.link.onGoToExternalLink`: Wikipedia links open as articles or a preview
- `onReaderReady`:
  - runs `state.after[path]`, used to open a pop-up after a document switch
  - restores `state.positions[path]`
  - `applyFooterMode(0)`
- `onSaveSettings`: `store:keepStyle`. Not `onCloseDocument`: on close KOReader saves after CloseDocument, so the last font size would be lost.
- `onCloseDocument`: detaches the toolbar and, if `in_history` is false, removes articles from ReadHistory. That runs after KOReader updated `hist[1]`'s time, so another book's time isn't bumped.
- Module-level `state` in `main.lua` (back stack, positions, `returnTo`, `fromLauncher`) survives `switchDocument`. Plugin instances don't.

## Pitfalls (things that look wrong but are right)

- **Relative data dir:** on a Kindle the data dir can be `.`, while ReadHistory stores real paths. Compare with `ffiutil.realpath` (`store:article`, `cacheDir`).
- **"Is the launcher showing?"** is checked with `getmetatable(top) == package.loaded["appsview"]`. A field such as `.apps` matches the reader and the library too, since they host the Apps plugin.
- **Refreshes:** show a panel over the page with its own refresh (`UIManager:show(panel, "ui", panel.box)`). Otherwise e-ink only redraws where the closing wait box was, and the panel stays invisible.
- **Stray touches:** panels call `Device.input:inhibitInputUntil(true)` so the rest of the opening tap doesn't close them.
- **Early taps:** an `IconButton` tapped before its first paint crashes in `widgetInvert`. `main.lua` guards it (`UIManager.wikipedia_invert_guard`).
- **"on" prefix:** methods named `on…` are event handlers in KOReader; their errors are swallowed and only the first return value comes back. Don't name helpers that way.
- **Section breaks:** `Epub.CSS` sets `h1,h2 { page-break-before: auto }` on purpose, so sections flow instead of each starting a page. `dropSectionList` removes KOReader's own section list from the HTML.
- **Toolbar hidden?** `toolbar_hidden` is global, not per article.

## Testing

- Plain Lua tests (no KOReader needed), from this folder:

  ```bash
  luajit tests/run.lua
  ```

- Everything else is checked in KOReader's emulator (Linux SDL build):
  - link this folder into its `plugins/` (and Apps' for the shared pieces)
  - run headless with `SDL_VIDEODRIVER=offscreen` at the Scribe's size: `EMULATE_READER_W=1860 EMULATE_READER_H=2480 EMULATE_READER_DPI=300`
  - drive it with a small throwaway plugin that schedules steps (`UIManager:scheduleIn`), calls `ui.wikipedia` methods or sends `Gesture` events, and saves `Device.screen:shot(path)`
  - print markers and grep the log for them and for `Traceback`
- Test with Apps and without it: every shared call has a fallback.
- Network steps need Wi-Fi in the emulator (it's the host's). For Today, a saved feed JSON can be passed to `store:setToday` instead.
- Guide screenshots (`docs/img/`) come from the emulator at 1240×1654 (DPI 200), with public articles only. The save folder is set to `/mnt/us/documents/Wikipedia` for the settings shot.

## Rules

- Plain wording: standard app phrasing, sentence case, "Kindle", no narration and no coined labels. Review new labels as a set with the existing ones.
- Made-up or public data only in code, tests, docs and screenshots. No personal names, devices, addresses, hostnames, keys or personal paths; use example values.
- Keep `../guide/wikipedia.md` and its screenshots current when the UI changes.
- `tests/` and `docs/` aren't copied to the Kindle.
