# Launcher for KOReader

A launcher: a full screen of big tiles, each with a line of what is going on.

- **Continue reading** (the last book, and how far in), **Library** (the file browser).
- **Weather** (now and today's high and low): Home Assistant's weather screen, or without it Open-Meteo's
  free forecast for a place you pick (no account): now, US weather alerts, the next 24 hours and 7 days.
  It also feeds At a glance and the widgets sleep screen. Settings > Launcher > WEATHER picks the source.
- **Fonts**: your fonts drawn in their own typefaces (set the default, remove added ones with Undo), Get more
  fonts (any Google Fonts family by name, or a suggested reading font with one tap), and KOReader's font settings.
- **AI** (Settings > AI): the AI services Notes, Crosswords and SSH use (Claude, Gemini, OpenRouter, Groq,
  your local AI on its Internal or External URL, Custom), which one does each job, Try a prompt and Test it on each,
  and Advanced: each AI feature's instructions (yours, with Reset), how much is sent and a preview.
- **Handwriting recognition**: a Write it button (or a pen) on the apps' text boxes opens a strip at
  the bottom of the screen; what you write there is read by the AI into the box.
- **Reading statistics** (today and the days in a row): today, the last 7 and 30 days, the streak now and
  the longest, when you read (by hour and weekday), and every book with how far along it is and the time
  left at your pace. A book's page has its pace, days, dates and each reading session: edit a session's
  day or times, delete it, or reset the book, each with Undo. **Calendar** opens KOReader's calendar.
- **Home Assistant** (what is on, the attention bar) and its **Dashboard** (weather, inside temperature;
  the tile shows once Home Assistant is set up).
- **To Do** (due today, overdue), **Notes** (notebooks, the last one), **Web server** (on and its address,
  or tap to start), **Wi-Fi** (tap to turn it on or off), **Exit KOReader** (back to the Kindle, after
  asking).

Tiles for plugins that are not installed do not show. An app opens on top of the launcher, so closing it
comes back here. The clock and the lines are updated each minute while the launcher is showing.
The ⋮ at the top right has KOReader's Light, Night mode and Refresh screen, and Settings; your KOReader
gestures (two fingers, edge swipes, multiswipes, pinches) work on the launcher too.

**Open it**: Tools > Launcher, a gesture (Settings > Taps and gestures > Gesture manager > a gesture > General
> Launcher), or have it open when KOReader starts (Settings > Launcher > Open at startup).

**Shortcuts**: Settings > Edit home screen > **Add shortcut** puts any Home Assistant screen or room (Security, Climate, Weather,
the Kitchen...), a To Do list, a notebook or a crossword source (the newest crossword from USA Today,
Guardian Quick...) on the launcher as a tile of its own, with its own line ("1 today", "Inside 70°",
"Edited Oct 20", "Wed 21 Oct · Started"); tap it to go straight there (a crossword is downloaded first
when it isn't in its book yet). Hold it (or the x in Edit home screen) to
remove it. More tiles than fit turn pages (swipe, or the arrows at the bottom).

**Groups**: hold a tile > **Move to a group…** to put tiles on a page of their own behind one tile; hold
the group for **Rename group**, **Change icon** (a grid of icons) or **Delete group**. Hold any tile for
**Move up** and **Move down**.

**Quick buttons** under the clock (two rows, then More, which opens the control center with all of
them): Wi-Fi, the light, night mode, New task, New note, Continue reading, the weather, a To Do list,
a Home Assistant screen, a KOReader action and more, in groups if you like. Tap does the quick thing;
hold opens what's behind it. Settings > Quick buttons (or the web page) picks and orders them.

Gestures, Battery and KOReader settings start hidden on a new install (they're in Settings and
search); **Edit home screen** shows them. Search also finds every app and Settings page by name.

**Settings** (⋮ > Settings): **Edit home screen** to move, hide or group tiles (or hold a tile), and
**Launcher** for the rest: the layout (**Tiles**, **Bold tiles**, **Compact**, a **List** or **Icons** like
a phone), 1–3 tiles across, the clock, the title bar in books and the library, **Sleep after** (KOReader's
sleep timer), the sleep screen and opening at start.

## Install

Copy this folder to `koreader/plugins/apps.koplugin` and restart KOReader.

## Development

```bash
luajit tests/run.lua
```

`appsmodel.lua` (the tiles and their order), `appsview.lua` (the launcher and the arrange screen),
`appscanvas.lua` (drawing in page units), `main.lua` (menu, gesture, opening at start). Icons are
[Lucide](https://lucide.dev) (ISC licence, `icons/LICENSE-lucide.txt`).
