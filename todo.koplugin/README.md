# To Do for KOReader

Microsoft To Do in [KOReader](https://koreader.rocks), made for a jailbroken Kindle Scribe (works on any
KOReader device with Wi-Fi). Its screens are drawn to scale for the Scribe's 1860 x 2480 screen (a task
row is about 12 mm tall) and scale with any other screen.

## What it does

- **With the launcher**: a **Sync To Do** quick button (how many changes wait; hold for the Sync screen), and
  Home's tiles drawn on the web page to drag into order.

- **Lists on this Kindle** (Settings > **Lists on this Kindle**, on to start with): lists kept only on the
  reader and never synced, so To Do works with no Microsoft account. They show under ON THIS KINDLE,
  repeat on their own, keep deletes to put back, and a task or a whole list can move to To Do. Turned
  off they're hidden, not deleted; signing out keeps them.

- **Home**: Today, Agenda, Starred and Calendar tiles (Search can be added), then every list with how
  many tasks are open and overdue or due today. The pinned list comes first. **+** adds a task to the
  default list. The bar at the bottom shows the changes waiting to be sent and the last sync.
- **Agenda**: overdue, today and each of the next 6 days, by reminder time. **Today** is overdue and
  today. **Starred** and every list are grouped Overdue / Today / Upcoming / No due date (a setting).
- **Tasks**: tap the box to tick a task off (tap again to undo before it is sent), tap the row to open
  it, hold it for quick actions: done, star, due today, tomorrow, skip to current or pick a date, push
  off, move to another list, delete.
- **A task's page**: rename it (tap the title), star it, set its due date, its reminder (day and time)
  and its repeat (daily, weekdays, weekly, every 2 weeks, monthly, yearly or every N days, weeks,
  months or years). For a repeating task, **Skip to current** moves it to the first day it falls on
  from today, and **Remove repeat** stops it repeating, clears the due date and keeps the old one in its
  notes (as CrossInk does). **Push off** moves the date by 7 days (hold for 1, 2, 3, 14 or 30, or set
  the number in Settings); the reminder moves with it. Steps can be ticked off, added, renamed and
  deleted; notes read and edited. **Move to list**, **Hide on sleep** and **Delete** are at the bottom.
- **Calendar**: a month with a dot for each task due a day (a hollow dot is overdue); repeating tasks
  show on the later days they fall on. Tasks that repeat every day or two are listed once instead.
  Tap a day for its tasks, hold a day to add one; swipe or use the arrows for other months.
- **Search**: titles, notes and steps.
- **Sleep screen** (optional): the date, then overdue, today and up next (or Today only, Starred, or the
  pinned list). Tasks hidden on sleep and hidden lists are left out. KOReader only draws the sleep screen
  on a Kindle without Amazon's ads ("special offers"); elsewhere the setting says so.
- **Reminders** ring on your phone: To Do keeps them, the Kindle cannot ring.

## Offline first

Tasks are kept on the reader (`koreader/settings/todo_tasks.lua`). A change shows at once and joins a
queue that is sent at the next sync, in order:

- **Sync** (the refresh icon, the Sync screen, or a gesture) sends the queue, then downloads everything.
  KOReader asks to turn Wi-Fi on if it is off.
- **Send changes right away**: when Wi-Fi is already on, changes go a few seconds after the last one.
- **Sync in the background**: every 15, 30, 60 or 120 minutes while KOReader is open and Wi-Fi is on,
  and when Wi-Fi comes on. It never turns Wi-Fi on.

The **Sync** screen (tap the bottom bar) lists the changes to send, and has **Download only** (sends
nothing), **Preview changes** (counts what To Do has new, changed or gone; changes nothing), **Reset to
To Do** (throws away the unsent changes and downloads again) and **Catch up overdue repeats** (skips every
overdue repeating task to current, after showing where each goes). A change To Do refuses (a task
deleted on the phone, say) is dropped and listed, not retried forever.

How the changes are sent: To Do has no move, so a moved task is copied to the other list (steps, notes,
repeat and reminder too) and the old one deleted. Changing a repeating task's due date directly makes To
Do split it (a copy with the old date stays), so the repeat is taken off, the date changed, and the
repeat put back from the new day. Due dates are written as midnight UTC, which To Do reads as that day
everywhere.

## Settings

**⋮ on Home** (or Sync > All settings):

- **Home**: home tiles (order, and which show), lists (order, and which show; hidden lists stay out of
  the Agenda, Calendar and sleep screen too), show hidden lists, pinned list, default list.
- **Tasks**: starred first, group lists by due date, what tapping a task does (open it, or quick
  actions), push off by N days, 24-hour clock, week starts on Sunday or Monday, confirm before deleting.
- **Screen**: **Clear ghosting** (a flashing refresh every 6 or 3 screen changes, every change, or never)
  and **Refresh screen** (also in a list's ⋮ menu). Closing a dialog, menu or the keyboard always
  flashes once.
- **Sync**: background interval, send right away, download only.
- **Sleep screen**: on or off, and what it shows.
- **Account**: sign in or out, app ID.

Hold a list on Home to open it, add to it, pin it, make it the default, hide it, rename or delete it;
**+** beside LISTS makes a new list.

Gestures (**Settings > Taps and gestures > Gesture manager > General**): To Do, To Do: Today, To Do: add a
task, To Do: sync.

## Install

1. Copy this folder to `koreader/plugins/todo.koplugin` on the device (on a Kindle:
   `/mnt/us/koreader/plugins/todo.koplugin`).
2. Put your app ID in `client_id.txt` in that folder (one line), or set it later in
   **To Do > Settings > App ID**.
3. Restart KOReader. **To Do** is in the Tools menu (the wrench).

Tasks synced by the older version are kept: they move to `todo_tasks.lua` on first start.

## Sign in

**Sign in to Microsoft To Do** shows a short code and a web address (`microsoft.com/devicelogin`, or tap
**QR code**). Enter the code on a phone or computer and sign in there; the Kindle never sees your
password. KOReader keeps the sign-in in `koreader/settings/todo.lua`; **Settings > Sign out** removes it
and the tasks kept on the reader.

The app ID is a Microsoft Entra app registration (any one used for To Do device sign-in works, such as
the one for CrossInk): **Authentication > Allow public client flows** on, API permission
`Tasks.ReadWrite`. Apps for personal accounts only are handled (the plugin retries with `/consumers`).

## Development

The logic that does not need KOReader runs in any LuaJIT or Lua 5.1+:

```bash
luajit tests/run.lua    # dates, views, repeats, calendar, the reader's copy and its queue
luajit tests/api.lua    # sign-in, Graph calls and sending each kind of change, against a fake network
```

- `tododates.lua`: due dates (days) and reminders (Unix seconds).
- `todomodel.lua`: Graph JSON into tasks; their order; Today, Agenda, Starred, groups, search, the
  calendar; repeats (how they read, where they fall next, the presets).
- `todostore.lua`: the reader's copy: the download, the queue of changes on top, and a sync.
- `todoapi.lua`: device-code sign-in, token refresh, Graph calls, and sending each queued change.
- `todoui.lua`: the drawing kit (units, fonts, icons, a full-screen page with tap zones, paging).
- `todoviews.lua`: the screens.
- `main.lua`: the plugin: navigation, dialogs, settings, syncing, the sleep screen.
- `icons/`: [Lucide](https://lucide.dev) icons (ISC license, `icons/LICENSE`), drawn black.
