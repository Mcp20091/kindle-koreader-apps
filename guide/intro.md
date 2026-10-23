# Getting started

This guide covers these plugins for KOReader on a Kindle Scribe:

- **Apps**: a launcher with big tiles for everything else, the weather, what's next and your recent books.
- **Home Assistant**: your lights, locks, thermostat, cameras and more, plus a nightstand dashboard.
- **To Do**: your Microsoft To Do lists and tasks, also when Wi-Fi is off.
- **Notes**: handwritten notebooks for the pen.
- **Crosswords**: puzzle books in Notes, from several newspapers, solved with the pen.
- **Wikipedia**: look up and read Wikipedia articles, and save them to read offline.
- **Syncthing**: keeps folders on the Kindle in sync with your computer or phone over Wi-Fi.
- **SSH**: run commands on your other devices (a PC, a NAS, a Raspberry Pi) and read what they print, or open a live session.
- **Web server**: a web page on the Kindle for your phone or computer, to manage all of the above with a keyboard.

Smaller things the plugins add, and where to find them:

- **Reading time and statistics**: the launcher's **Reading time** tile, and the web page's **Reading** tab (today, days in a row, each book; fix or delete a reading session; progress sync).
- **Battery**: the launcher's **Battery** tile, and the **Battery** card on the web page's **System** tab: how fast it goes awake and asleep, and what is on that uses power.
- **KOReader's own settings**: the launcher's **KOReader settings** tile, and the web page's **KOReader** tab (folders, when the Kindle sleeps, and KOReader's whole menu).
- **Restart KOReader**: the launcher's **⋮** menu (or a tile you can show).
- **When something goes wrong**: the web page's **System** tab: crashes and freezes (**Problems**), memory, a network check, when the Kindle slept and woke, detailed logging, and a diagnostics file to send. The launcher also says when KOReader crashed or froze the last time.
- **Files and books from a browser**: the web page's **Files** tab: upload (or get a file from a link), search every folder, favorites and collections, a book's details and its highlights.

Each chapter starts with how to open the app and then goes screen by screen. Names in **bold** are what you see on the Kindle's screen.

## Finding your way around

All the apps follow the same habits:

- **‹** at the top left goes back. On the first screen it closes the app.
- **⋮** at the top right has the app's menu: usually the light, night mode, a screen refresh and the app's own actions. **Open on the web page** starts the web server and shows a QR code: scan it with your phone to open the same place there (in a To Do list, that list), handy for typing a lot.
- The **gear** opens the app's settings.
- Long screens turn pages instead of scrolling: swipe left or right, or tap the arrows next to the page number.
- **Hold** something (a tile, a task, a notebook, a book) for more choices.
- The clock and battery are at the top of each app's screen (each app's settings can turn them off).

> Your KOReader gestures still work inside these apps: two-finger swipes, edge swipes, multiswipes and pinches. Only the gestures that make sense there run (the light, night mode, a refresh, Wi-Fi, a screenshot and the apps' own actions).

## Opening the apps

There are three ways:

- **The launcher**: open **Apps** and tap a tile. It can open by itself when KOReader starts (Apps settings > **Open at startup**).
- **KOReader's menu**: the **Tools** tab (the wrench) has **Apps**, **Home Assistant**, **To Do**, **Notes**, **Wikipedia** and **Web server**; **Syncthing** and **SSH** are under **Settings (gear) > Network**.
- **A gesture**: KOReader's **Settings > Taps and gestures > Gesture manager**, pick a gesture, then **General**. Each app has its actions there, such as **Apps**, **Home Assistant dashboard**, **To Do: add a task** or **Notes: today's page**.

## The sleep screen

When the Kindle sleeps, it can show one of the apps instead of KOReader's own sleep screen. Choose in Apps settings, To Do settings or Home Assistant settings (it is the same setting everywhere):

- **To Do tasks**: today's date with overdue tasks, today's and what's next.
- **Home Assistant**: a summary of the home.
- **Apps summary**: the date, battery, weather, what's next and today's tasks.
- **KOReader's own**: KOReader's usual sleep screen.

**Sleep screen updates** (Off, every 15 or 30 minutes, every hour) wakes the Kindle briefly to draw the sleep screen again, so the time and tasks stay current. Each wake uses a little battery.

Home Assistant can also add **Sleep screen alerts** to any of these sleep screens: a box at the bottom listing a door left unlocked, a leak or a temperature you chose.

> KOReader can only draw the sleep screen when Amazon's lock-screen ads ("special offers") are off. With ads on, the setting says so.

## Updating the plugins

New versions come as one file, **kindle-plugins.zip**. To install it:

1. On the Kindle, start the web server: **Tools > Web server > Start web server**.
2. On your phone or computer, open the address it shows.
3. On the **Home** tab, under **Update plugins**, tap **Install a zip…** and pick kindle-plugins.zip.

KOReader restarts with the new versions. Your settings, sign-ins and notebooks stay as they are.

If an update causes a problem, you can go back to the version before it:

- In Apps settings, tap **Undo a plugin update**.
- Or in KOReader's menu: **Tools > Web server > Undo a plugin update**.
- Or on the web page's Home tab: **Go back**.
