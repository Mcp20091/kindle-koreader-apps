# Notes for AI coding agents: Library (library.koplugin)

The Library app: books and folders in one place, in the apps' design, with KOReader as the backend. It takes the place of KOReader's file browser as where books are browsed; KOReader's reader stays. The rules every app follows are in the shared AGENTS.md (kindle-koreader-apps-review); this file has what's specific to the Library.

## Design (every screen)

- **The apps' title bar on every page** (`librarybar.lua`, a copy of the launcher's appsbar): ‹, ⌂, Recent apps, the title (a folder's place under it), the page's own buttons, the clock and battery ▾, ⟳ (the books walked again, covers read again, a full refresh), 🔔 and ⋮.
- **Pages drawn as the other apps'** (`librarypage.lua`): grey capital headings, rows with an icon and a grey second line, book rows with a small cover, cover grids (five across), chips, settings rows, stat rows; pages turn with swipes or ‹ n/m ›; a status line ends the page; a row of the launcher's icon buttons at the foot where there are actions (a book's page, Select, the folder picker).
- **Pop-ups**: the launcher's (`PS.popup` through `libraryko.lua`): menus, choices, confirms, toasts, the text box (`KO.ask`: Rename, New folder, New collection, Search, with the pen) and Undo. KOReader's own only without the launcher.
- **Undo over confirm**: Delete moves into a trash folder at once and offers Undo; it goes for good when the bar goes (`M.trash`, `M.untrash`, `M.purgeTrash`; leftovers at the next start, `M.emptyTrash`). Only Reset reading progress asks first. Without the launcher's Undo, Delete asks first.
- **A mockup first** for visible changes: `C:\repos\mockups\library_mockup_gen.py` (the one the user picked: Home plus chips, both).

## Files

- `main.lua`: the plugin: `PS.library` (open, openFolder, openBook, openTitle, isBrowser, settings), Settings and search entries, the setup step, the backup part, the gesture action, and **standing in** for KOReader's file browser (`Library:standIn`).
- `libraryviews.lua`: every screen (Home, the chip tabs, authors, series, collections, folders, the folder picker, Select, a book's page, Find details online's found and matches pages, search, sort and group, ⋮, settings) and what their buttons do.
- `librarymodel.lua`: the books and files, from KOReader's records; plain helpers at the top (tests/run.lua).
- `librarycovers.lua`: covers from the Cover browser's cache, scaled and kept (48 at most), and books it hasn't read sent to its background reading.
- `librarypage.lua`: the full-screen page and its items. `librarycanvas.lua`, `librarybar.lua`: copies of the launcher's appscanvas and appsbar.
- `libraryko.lua`: the shared pop-ups, with KOReader's as the fallback (as sshko.lua).
- `librarysettings.lua`: `settings/library.lua` (view, sort and group per page, hidden, browser, start, last).
- `libraryservers.lua`: FTP and WebDAV servers (plain helpers at the top, tests/run.lua): KOReader's Cloud storage list, its providers' network code, the download folder.
- `libraryopds.lua`: OPDS catalogs (plain helpers at the top, tests/run.lua): KOReader's OPDS list, its OPDS browser's feed code, the six suggested catalogs.
- `libraryserverviews.lua`: the servers' and catalogs' screens (added onto libraryviews' V): SERVERS AND CATALOGS rows, a server's folder, Add a server, the catalogs, a catalog's page, the folder picker on a server, downloads and uploads.
- `libraryweb.lua`: the web page's Servers and catalogs card (webpage.koplugin's `webservers.lua` passes its calls on).
- `libraryonline.lua`: Find details online: Open Library and Google Books (plain helpers at the top, tests/run.lua), the lookups in a child process, Save and Undo into KOReader's custom metadata and cover.

## KOReader as the backend

- **Books**: every file under KOReader's Home folder with a book's extension (`M.BOOK_EXT`; text files, web pages and pictures are "other files", still openable), one walk kept while KOReader runs (`M.books`; 20,000 entries and 4 s at most, `M.state.partial` past that). ⟳ and any file change walk again.
- **Titles, authors, series, descriptions, covers**: the Cover browser's `BookInfoManager` (`require("bookinfomanager")`; loaded from its folder when that plugin is off). A book it hasn't read: `BIM:extractInBackground` (its own child process), polled every 1.5 s only while that runs, then the page redraws.
- **Status and progress**: KOReader's `BookList` cache (`getBookStatus`, `getBookInfo`), the open book's own settings while it's open; changed with `filemanagerutil.saveSummary` and `BookList.setBookInfoCacheProperty`, as KOReader's own buttons do. "To read" is `new` (never opened): there is no way back to it once opened, so its chip shows only then.
- **History**: `ReadHistory.hist`. **Collections**: `ReadCollection` (Favorites is `default_collection_name`). **Favorite folders**: KOReader's `folder_shortcuts`.
- **Reading statistics**: the statistics plugin's database, read only, found by the book's partial MD5 (first read, days, pace, time). Its page is the launcher's (`showMode("statsbook")`), and the launcher's page links back with `PS.library.openTitle`.
- **Publisher, date, subjects, ISBN**: the EPUB's OPF, read with `ffi/archiver` when a book's page opens (entries must be listed with `iterate()` before `extractToMemory` finds them).
- **Find details online** (`libraryonline.lua`, the `found` and `matches` views): Open Library's `search.json` (by `q=isbn:`, else `title=`/`author=`, with `editions.*` fields for the best edition's publisher and pages), its work's JSON for the description, `covers.openlibrary.org` (`?default=false`: a 404, not a blank picture); Google Books' `volumes?q=` only when Open Library has nothing (its keyless quota is often used up: a 429 is treated as nothing found, not an error). No key, no account; Goodreads has no API since 2020. The network runs in `ffiutil.runInSubProcess` (polled every 0.3 s, 60 s at most, Cancel kills it); `NetworkMgr:runWhenOnline` first. Saved on Save only, as KOReader's Book information > Set custom metadata does: `custom_props` in `custom_metadata.lua` (KOReader's keys: title, authors, series, series_index, language, keywords, description; the Library's beside them: publisher, published, print_pages) with `doc_props` (the book's own, for KOReader's Reset) when the file is new, and `DocSettings:flushCustomCover`. Then the Cover browser's running reading stopped and its row deleted, `InvalidateMetadataCache` and `BookMetadataChanged` broadcast, an open book's `doc_props` updated. Undo writes back the files as they were (`O.restore`). `M.details` puts the custom props over the Cover browser's and the OPF's; while the Cover browser reads the book again, `M.known` shows KOReader's way of combining them (`extendProps` of the book's own props), so the page doesn't lose its title and author meanwhile.
- **Moving, renaming, copying, deleting**: as FileManager does (`mv`/`cp` binaries, `DocSettings.updateLocation`, `ReadHistory:updateItem(s)ByPath`, `ReadCollection:updateItem(sByPath)`, folder shortcuts), plus the Cover browser's row moved with the file (`moveInfo`) so its cover isn't read again.
- **Opening a book**: `ReaderUI:showReader` (or `switchDocument` over an open book); KOReader's file browser closes as it opens. Back in the book (`ui:onHome`) brings the file browser back, and the Library stands in over it.

## Servers and catalogs (FTP, WebDAV, OPDS)

- **The lists are KOReader's**: `settings/cloudstorage.lua` (`cs_servers`: name, type ftp/webdav, address, username, password, url = starting folder; Dropbox ones left alone) and `settings/opds.lua` (`servers`: title, url, username, password). When the Cloud storage or OPDS plugin runs, its instance (`ui.cloudstorage`, `ui.opds`) holds the list in memory: it is written through there (`updated = true`, flush), so it doesn't write its old copy back over ours. The six suggested catalogs are added once when missing (`opds_added` in the Library's settings), matched by host, so KOReader's own Gutenberg or Internet Archive address counts.
- **The network is KOReader's code**, always in a child process (`R.run` = `O.run`): the Cloud storage plugin's providers (`ui.cloudstorage.providers[type]`, else `dofile` of `plugins/cloudstorage.koplugin/providers/*.lua`; `.base` set to the server in the child only), the older `apps/cloudstorage` modules as a fallback; the OPDS plugin's `opdsbrowser` (`genItemTableFromURL`, `getFiletype`, `downloadFile`) on an object whose metatable is its class, with `UIManager.show` silenced in the child.
- **FTP folders are listed with MLSD through `socket.ftp`** (`R.parseMlsd`, by the `type=` fact): KOReader's lister takes a folder that MLSD gives a size (pyftpdlib, many servers) for a file. A 530 (login) or 550 (no folder) answer ends there; a server without MLSD falls back to the provider's NLST. Only the first return value comes back from a child: return one table (`R.listing`).
- Downloads go to `name.part`, renamed when done (Cancel removes it). An address's port: the Port field, else one typed in the address (`R.normalize`).
- Tested on the emulator against local made-up servers (pyftpdlib on 2121, WsgiDAV on 8088 with basic auth, a static OPDS feed with search and a next page), and Standard Ebooks' real catalog.

## Standing in for KOReader's file browser

Each time a FileManager is made (after a book closes, at start), `Library:standIn` waits 0.5 s and shows the Library over it when: Library settings > Browse books with is the Library, `PS.library_aside` isn't set (⋮ > KOReader file browser sets it until a book is opened), and nothing but notices that go by themselves (`toast`, `timeout`) is over the file browser. So another app (Wikipedia going back to its article, the launcher shown over it, a dialog) is never covered.

## Pitfalls (learned the hard way)

- **Read KOReader's collections before a move, not after.** `ReadCollection:_read` drops entries whose file is missing, so reading them after `mv` loses the book from its collections before `updateItem` can move it.
- **`x and y or nil` is not a three-way choice**: with y false it gives nil (Select's empty boxes didn't show). Write it out.
- **A `nil` in a table of buttons ends it for `ipairs`** (the launcher's book menu): insert conditionally.
- **Python edit scripts turn `"\n"` into a real line break** inside Lua strings; grep after scripted edits.
- **A child process's tables aren't the parent's**: what a stub records inside `O.run` (a fork) never reaches the driver; write it to a file.
- **The Cover browser reading a book in the background can write it back after it was deleted**: stop its jobs (`terminateBackgroundJobs`) before `deleteBookInfo` when a book's details change, as `extractInBackground` itself does.
- **Bar space**: four buttons plus ‹ n/m › leave the title a few letters; shelves keep three (Select is in ⋮).

## Testing

- `luajit tests/run.lua` from this folder: the model's helpers (names, authors' last names, titles' sort keys, sizes, dates, OPF parsing, file names, sorting) and Find details online's (ISBNs, queries, Open Library's and Google's answers, series from titles, what is compared and saved), on made-up answers.
- Find details online in the emulator: the driver replaces `O.get` with made-up answers (no real lookups) and goes through More, the wait, what was found, Other matches, Search again, Save (the custom files, KOReader's Book information, the page), Undo, Select (nothing found, Skip, Save, Undo for all) and no connection.
- The emulator, with made-up books only: a driver plugin seeds progress, statuses, history, collections, highlights and reading statistics for generated EPUBs and PDFs (public-domain titles, invented text), then goes through every screen with checks (moves, Undo, renames, collections following, the stand-in after a book) and screenshots. Paths are shown relative to the Home folder, so the emulator's own paths stay out of the shots.

Measured on the emulator (2026-10-25, 18 books): the Lua heap 12.13 MB before the Library opens, 12.72 MB with Home open (+0.59 MB); covers are blitbuffers outside the Lua heap, 48 kept at most and freed when the Library closes. At KOReader's start only the registering runs (`main.lua`); the screens load when first opened.

## Rules

- Each app works without the others: without the launcher, KOReader's dialogs and no ⌂/🔔/Recent apps; without the Library, the launcher's Library tile, Open its folder and Back from a book go to KOReader's file browser.
- No personal data in code, tests, screenshots or the guide.
