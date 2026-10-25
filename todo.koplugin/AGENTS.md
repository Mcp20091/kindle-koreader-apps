# To Do (todo.koplugin): notes for coding agents

Read the top-level AGENTS.md first. It has the rules every plugin shares. This file covers only To Do.

## What it does

Microsoft To Do on a Kindle: lists, tasks, steps, notes, due dates, reminders and repeats, a calendar,
search and a sleep screen. It works offline: changes wait in a queue and go to Microsoft Graph at the
next sync.

## How it's built

- `main.lua`: the plugin. It handles settings, sync, reminders, the dialogs (date, time, repeat, move)
  and sharing with Apps.
- `todoapi.lua`: Microsoft Graph. Device-code sign-in (`startSignIn`, `pollSignIn`), token refresh,
  paging, lists and tasks. Personal accounts may need `/consumers` instead of `/common`
  (AADSTS9002331).
- Lists on this Kindle: ids `local:N`, kept in the store's `data.locals` (and `localTrash`, the last
  30 deletes). Their changes are applied at once and never queued or sent; `Store:push` routes them.
  A repeating one makes its next task in `toggleLocalDone`. `moveAcross` and `moveListToTodo` move to
  To Do (queued as new there). Option `local_lists` (on) shows them; `Todo:usable()` is "signed in or
  local lists on". Sign-out keeps `locals`.
- Quick button: `PS.registerQuick{ key = "todo" }` gives the launcher Sync To Do (see apps.koplugin's
  `appsquick.lua`). The web page's `/api/todo/tiles` saves Home's tiles (`tiles` setting).
- `todostore.lua`: the local copy and the queue. Each change (`addTask`, `toggleDone`, `setDue`, `move`,
  `delete` and so on) is applied to the local lists at once and queued for Graph. `delete` and
  `deleteList` return the operation so Undo can put it back.
- `todomodel.lua` and `tododates.lua`: plain Lua with no KOReader modules. They hold the tasks and
  views (Today, Agenda, Starred, lists, the calendar, search) and repeats. A due date is a day number
  (days since 1970-01-01). A reminder is Unix seconds (UTC).
- `todoui.lua` (drawing kit in units, the short side is 620) and `todoviews.lua` (every screen and
  the sleep screen).
- `todoko.lua`: a copy of `apps.koplugin/appsko.lua` with its own header. Keep it in step.

What it saves:
- `koreader/settings/todo.lua`: options and the sign-in tokens.
- `koreader/settings/todo_tasks.lua`: the lists, the tasks and the queue (`queue`, `qseq`).
- `client_id.txt` next to `main.lua`: the user's Azure app ID, if one isn't set in Settings. It's in
  `.gitignore`: never commit one.

Sync never blocks KOReader's loop. `Todo:syncInBackground` sends the queue and downloads the lists
in a child process (`ffiutil.runInSubProcess`). The parent polls the pipe with
`UIManager:scheduleIn` and merges the result. Each queued change has a number (`qid`), so changes
made on the Kindle during a sync are kept.

Reminders are checked every minute while KOReader runs (`reminderTick`), looking back up to two
hours after a sleep. The Kindle can't wake itself for a reminder.

## How it uses the shared pieces

- The bar via `todoko`: search, refresh (Sync now), the bell and ⋮. ⋮ has Sync now, Open on the web
  page, Recent apps, the light, Night mode, Refresh screen and Settings.
- Notifications:
  - `todo:remind:<task id>` for a reminder. It's removed when the task is done, deleted, or moved to
    another day or time (`pruneReminderNotes`).
  - `todo:sync` for a sync problem. It's removed after a good sync.
  - `PS.notifyOpeners.todo(route)` opens the task.
- `PS.registerSettings`, `PS.registerSearch` (titles, notes and steps, from memory) and
  `PS.registerSetup` (app ID and sign-in, order 30), all with `key = "todo"`. `PS.noteRecent("todo")`.
- Undo after a task or list is deleted (`KO.undo`). The deleted task also stays under **Deleted**
  with **Put back** until the next sync.
- The web server changes tasks through this plugin's store, so changes made there are queued the
  same way.

## Pitfalls

- **Graph and `$select`:** task queries that use `$select` can come back wrong or fail. Ask for the
  whole task.
- **Repeating tasks:** changing a repeating task's due date makes Graph split it. Skip to current
  sends the repeat again from the new day. Remove repeat clears the due date and keeps the old one
  in the notes.
- **A task under the wrong list** gives an error rather than a 404. Look a task up in its own list.
- **Methods named `on…`** are treated as event handlers: only the first return value comes back
  and errors are swallowed. Use other names for helpers.
- **Online checks:** `NetworkMgr:isConnected()`, not `isOnline()`.
- **Full-screen pages** set `flash_on_uncover = true`.
- **The sleep screen** only shows without lock-screen ads ("special offers").

## How to test

- `luajit tests/run.lua` (model, dates, store) and `luajit tests/api.lua` (Graph calls against a
  fake `request`) from this folder. Both end with `N passed, 0 failed`. Task titles are made up
  ("Call the dentist", "Water the plants"). Keep them that way.
- `python tests/check_input_path.py` from `apps.koplugin` covers this plugin too.
- On a computer: KOReader's Linux AppImage, extracted, with this folder (and apps.koplugin) in its
  `plugins/` folder and a separate `HOME`. Fill `todo_tasks.lua` with made-up lists rather than
  signing in to a real account.

## Rules for this plugin

- No new gestures beyond swiping in from the left edge for Back. Other swipes turn pages (on the
  calendar, its months).
- Never handle pen input.
- Plain wording. Say "Kindle".
- No dark mode of the app's own.
- Made-up tasks and lists in tests, docs and screenshots.

## Shared helpers

Helpers more than one app needs live in the launcher (apps.koplugin) and are reached through KOReader's PluginShare (`PS.ko`, `PS.ai`, `PS.microsoft`, `PS.registerTest`, `PS.backupApps`, `PS.statusIcons`…); see apps.koplugin/AGENTS.md. This plugin uses them when the launcher is there, and its own copies are only the fallback without it. A new helper goes into apps.koplugin, not here.
