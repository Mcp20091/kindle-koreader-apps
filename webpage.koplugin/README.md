# Web server for KOReader

A web server on the Kindle: its web page, for a phone or computer on the same Wi-Fi (like CrossInk's): files, and the
setup and lists of the Home Assistant, To Do and Notes plugins, with a keyboard and a big screen.

**Tools > Web server > Start web server** (or a gesture: General > Toggle web server) shows the address, e.g.
`http://192.168.1.50:8080`, and a QR code. The page works while it runs; the reader stays awake meanwhile
(Tools > Web server to change that), and it stops by itself after 30 minutes nobody uses it.

## What is on it

- **Home**: battery, storage, KOReader's version, and the sections.
- **Dashboard**: a page of your own, built from parts of the other tabs.
- **Files**: the reader's storage (`/mnt/us` on a Kindle): upload (several at once, or drop them on the
  page), download, open pictures and PDFs, new folder, rename, move, copy and delete with Undo, as the
  Library app does them (reading progress, history and collections follow a book); books grouped by
  author, series or status, marked reading, on hold or finished, and their details.
- **Reading**: today, days in a row, the last 30 days and each book, from KOReader's reading statistics;
  click a day for its sessions, then edit a session's day or times or delete it (with the launcher
  installed: the same code as the Kindle's Reading statistics); reset a book; progress sync.
- **Launcher** (with the launcher): the tiles drawn as the home screen (drag into order, into a group or to
  Hidden), groups (name and icon), shortcuts, the quick buttons (drawn as on the Kindle), the weather's
  place, the widgets sleep screen's parts and its other settings.
- **Home Assistant** (with the Home Assistant plugin): addresses; **Sign in with Home Assistant** (its own
  sign-in page, two-step codes included, then back here) or a pasted long-lived token; which devices show
  and which are Quick tiles (★), with search; the order of Home's sections, Quick tiles and rooms (drag or
  arrows) and which are hidden; what asks first, update timing and the dashboard; backup and restore of
  all of it.
- **To Do** (with the To Do plugin): every list and task kept on the reader. Add tasks (due date, star,
  notes, steps), tick off, star, edit, move to another list, skip or remove a repeat, hide from the sleep
  screen, delete; new, rename, pin, hide, default and delete lists. Changes go into the plugin's queue
  and reach Microsoft To Do at its next sync (**Sync now** is here too). Lists on this Kindle (never
  synced) in their own group, made here too, and moved to To Do. CSV export of the lists you tick and
  import into the place you pick (To Do, this Kindle or one list), the plugin's options, the **app ID**
  and **signing in** (the code to enter shows here).
- **Notes** (with the Notes plugin): the notebooks, each page drawn here from its ink and saved as PNG
  (one page or all), new, rename, duplicate, delete and their order; Notes' settings, the toolbar's order;
  **OneNote's app ID and sign-in**; a link to the AI tab.
- **Crosswords** (with a Notes that has crosswords): each crossword book's puzzles with their day, state,
  ticked clues and time (open one on the Kindle, or remove it); **Get crosswords**: pick a source (and the
  Guardian's kind), tick days, and the Kindle downloads them into their book (Wi-Fi on the Kindle);
  **Import PDF, .puz or .ipuz**: a PDF of puzzles becomes a puzzle book in Crosswords, a crossword
  file goes into the Imported crosswords book; and Crossword settings.

- **Wikipedia**, **Syncthing** and **SSH** (with those plugins): saved articles, folders and devices, hosts and keys.
- **AI** (with the launcher): the AI services every app uses (key, model or addresses), which one does
  each job, Try a prompt, Test connection, and Advanced (each feature's instructions, how much is sent,
  a preview with its pictures); the same as the Kindle's Settings > AI.
- **Fonts** (with the launcher): your fonts in their own typefaces, adding files or a Google Fonts family,
  removing with Undo, the default and the font settings; the same as the Kindle's Fonts screen.
- **KOReader**: folders, the common settings, and KOReader's whole menu.
- **System**: update plugins (and undo an update), backups, logs, gestures and the password.

The sections for the other plugins use them while KOReader runs; a plugin that is not installed has no
section.

## Safety

Anyone on the same Wi-Fi can open the page while it runs (as with CrossInk's): start it when you need it.
It cannot reach files outside the storage root. On a Kindle, the plugin opens its port in the firewall
while running and closes it after.

## Install

Copy this folder to `koreader/plugins/webpage.koplugin` and restart KOReader.

## Development

```bash
luajit tests/run.lua
```

- `webserver.lua`: the HTTP server, polled by KOReader's event loop (one request at a time; spare
  connections that send nothing are set aside; uploads go straight to disk).
- `webfiles.lua`, `webbooks.lua`, `webapps.lua`, `webha.lua`, `webtodo.lua`, `webnotes.lua`, `webhome.lua`
  and the rest: each section's API (see AGENTS.md for the full list).
- `webcommon.lua`: the open KOReader screen's plugins, Microsoft's sign-in by code.
- `web/`: the page (plain HTML, CSS and JavaScript; light and dark).
- `main.lua`: the menu, starting and stopping, the address and QR code, staying awake.
