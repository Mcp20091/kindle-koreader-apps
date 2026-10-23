# Apps (the launcher)

Apps is a full screen of big tiles, one for each app and for anything else you pin there. Each tile has a line saying what is going on in it, such as "2 today · 1 overdue" on To Do or "6 on · All doors locked" on Home Assistant. Tap a tile to open it. The app opens on top of the launcher, so closing the app brings you back.

![The launcher: clock, the At a glance line, quick buttons, recent books and tiles](img/apps/launcher.png)

## Opening Apps

- **KOReader's menu**: **Tools > Apps**.
- **A gesture**: **Settings > Taps and gestures > Gesture manager**, pick a gesture, then **General > Apps**.
- **At startup**: Apps settings > **Open at startup** opens it each time KOReader starts.

Opening Apps when it is already showing just refreshes it.

To leave Apps, open **Library** or a book, or tap **Exit KOReader**. Back also closes it.

## The top of the screen

- **The clock** and the date. The clock updates every minute while the launcher is showing. Settings has a **24-hour clock** option.
- **The battery**, filled to its charge (a lightning bolt while charging), and its percentage.
- **Wi-Fi**: on or **Off**.
- **⋮** has **Open on the web page**, **Restart KOReader** (after asking), **Help**, **Light** (on a Kindle with a front light), **Night mode** and **Refresh screen**.
- **The gear** opens the launcher's settings.

### At a glance

The line under the clock shows three things when they are available. Tap any of them to go there.

- **The weather** from Home Assistant: the temperature, the conditions and today's high and low, such as "59° Clear · 64° / 48°". Tap it for Home Assistant's Weather screen.
- **What's next** (the clock icon): your next Home Assistant calendar event, or else the next To Do reminder in the next day and a half, with its time. Tap it for To Do's Today.
- **Tasks due** from To Do: "3 due" (overdue tasks count too) or "Nothing due". Tap it for To Do's Today.

Turn the line off in settings: **At a glance**.

### Quick settings buttons

A row of buttons under the clock:

- **Wi-Fi**: turns Wi-Fi on or off. Filled black when on.
- **Light**: KOReader's front light dialog (only on a Kindle with a front light).
- **Night mode**: white text on black. Filled when on.
- **Refresh**: a full, flashing refresh that clears e-ink ghosting.
- **Web server**: starts or stops the web server. Filled when it is running. Off by default.

Settings > **Quick settings** opens a list: **Quick settings: On** (or **Off**) turns the whole row on or off, and a tick shows each button (**Refresh** is called **Refresh screen** there). While a button shows, the tile with the same name leaves the main page, so you don't have both.

> Turned on its side, the launcher puts the At a glance line and the buttons on one line.

### Recent books

**RECENT BOOKS** shows the last books you read (three across, five on its side), with the cover when KOReader has one, the title and how far you are: a progress bar and "42% read", **Finished** or **Not started**.

- **Tap** a book to open it.
- **Hold** a book for:
  - **Open**
  - **Mark as finished** (or **Mark as reading**)
  - **Remove from history**
  - **Open its folder** (the library, at the book's folder)

Turn the row off in settings: **Recent books**.

### Recent notebooks and crosswords

With Notes installed, two more rows can show under the books:

- **RECENT NOTEBOOKS**: the notebooks you used last, with their first page and when they were edited. A locked notebook shows a lock instead of its page. Tap one to open it; hold it for **Open**, **Add to Apps** or **Remove from recent**.
- **RECENT CROSSWORDS**: the puzzles you worked on last, with the grid as you've filled it so far, and "23 of 78 clues" with a bar (or **New** or **Done**). Tap one to go straight to that puzzle; hold it for **Open** or **Remove from recent**.

**Remove from recent** takes a notebook or crossword off its row until you write in it again (or solve more clues). To bring one back sooner, open settings > **Removed from recent** (it shows only once something has been removed, with how many) and pick it, or **Show all**.

Turn each row off in settings: **Recent notebooks** and **Recent crosswords**. Rows that fit together share a line (one book beside two notebooks, say), to leave room for tiles. **Recent items** > **One row** shows just the newest book, notebook and crossword side by side, in a single row. The **Small** clock and the **Compact** layout give more room too.

## The tiles

- **Continue reading**: the last book and how far in. Tap to open it.
- **Library**: KOReader's file browser.
- **Reading time**: how long you've read today and how many days in a row you've read, such as "25 min today · 4 days in a row". Tap to open your last book. It uses KOReader's reading statistics, so the Reading statistics plugin must be on.
- **Home Assistant** and **Dashboard**: see the Home Assistant chapter.
- **To Do**: "2 today · 1 overdue", or what's coming this week.
- **Notes**: how many notebooks, and the last one you wrote in.
- **Today's crossword**: the newest crossword from the source you used last, and whether it is new, started or done. Tap to open it (it is downloaded first when needed).
- **Wikipedia**: how many articles are saved and the last one read. Tap to open Wikipedia.
- **Syncthing**: "On · Up to date", "On · Syncing · 3 files left" or "Off". Tap to open Syncthing.
- **SSH**: how many hosts are saved, such as "3 hosts". Tap to open SSH.
- **Web server**: "On" and its address, or "Off · Tap to start".
- **Gestures**: what each KOReader gesture does (see below).
- **Battery**: the battery level and how fast it's going, such as "71% · 3.0% an hour awake", or "71% · Charging". Tap for the Battery screen (see below).
- **KOReader settings**: KOReader's own menu, opened at its Settings (gear) tab: Device (including **Autosuspend timeout**), Screen, Network, Taps and gestures and the rest.
- **Wi-Fi**: on, off or connected. Tap to switch.
- **Light** and **Night mode**: as the quick buttons.
- **Exit KOReader**: back to the Kindle's home screen, after asking.
- **Restart KOReader**: closes KOReader and opens it again, after asking. Hidden to start with; show it in Settings (the eye) if you want a tile. It's always in the **⋮** menu too.

A tile only shows when its app is installed. More tiles than fit turn pages: swipe left or right, or tap the arrows at the bottom.

If KOReader crashed or stopped answering the last time it ran, the launcher says so (with the time) the first time it opens. The web page's **System** tab (**Problems**) has the details.

### Holding a tile

Hold any tile for:

- **Move earlier** and **Move later**
- **Move to a group…**
- **Hide** (or **Remove** for a shortcut)
- **Settings**

### Groups

A group is a tile that opens a page of its own, like a folder on a phone.

1. Hold a tile and choose **Move to a group…**.
2. Choose **New group…** and give it a name, or pick an existing group.
3. The group's tile shows a folder and how many tiles are in it. Tap it to open its page.

To leave a group's page, tap its name at the top, press Back, or swipe right on its first page. To take a tile out of a group, hold it and choose **Move to a group… > Main page**. Hold a group's tile to **Rename group** or **Delete group** (its tiles go back to the main page).

### Shortcuts

A shortcut is a tile that goes straight to one place. In Apps settings, at the end of the tile list, tap **Add shortcut**:

- **Home Assistant screen or room**: Home, the Dashboard, any of its screens (Security, Climate, Weather…) or a room. Its line shows that place's summary, such as "Inside 70° · 40%".
- **To Do view or list**: Today, Agenda, Starred, Calendar, Search, or one of your lists.
- **Notebook**: a Notes notebook, with when it was last edited.
- **Notes folder**: a folder of notebooks.
- **Crossword**: one newspaper's newest crossword.
- **KOReader action**: anything a gesture can do that needs no setting, such as **Calibre: Connect** or **Push progress from this device**. Pick a group (General, Device, Screen and lights, File browser, Book) and then the action. It runs when you tap the tile, just like the gesture. Book actions need a book open.

Home Assistant, To Do and Notes can add shortcuts themselves: their **⋮** menu has **Add to Apps** on the screen you're looking at.

To remove a shortcut, hold it and choose **Remove**, or tap its **x** in settings.

## The Battery screen

The **Battery** tile opens KOReader's own battery statistics, shown plainly. It needs KOReader's **Battery statistics** plugin, which is on unless you've turned it off:

- The level, and about how long it will last awake at the rate you've been using it.
- **SINCE THE LAST CHARGE**: how much went while **Awake** and while **Asleep**, how long each, and how much an hour; **In all** for both.
- **THE LAST CHARGE**: how much it charged, in how long.
- **ON NOW**: what is on that uses power: Wi-Fi, the front light, the web server, Syncthing, the Home Assistant dashboard keeping the screen on, anything keeping the Kindle awake.
- **Reset statistics** starts counting again.

KOReader can only tell awake from asleep, not which app used what. To see what costs most, reset, use the Kindle one way for a while (say Syncthing on, or the web server running), and look again.

## The Gestures screen

The **Gestures** tile lists every KOReader gesture that does something, with what it does, in KOReader's own words. For example, "⇐ → Folder shortcuts" under **TWO-FINGER SWIPE**. It's handy for finding a gesture that fires by accident.

![The Gestures screen](img/apps/gestures.png)

- **In the library** and **In a book** switch between the two sets of gestures.
- **Tap a gesture** to change it in KOReader's own menu for it: choose another action, **Pass through** (do nothing here) or **Nothing**. Changes take effect at once.
- **Gesture manager** opens KOReader's whole gesture menu, to set up new gestures.

You can only change the set you are in: the library's while in the library, a book's while reading. The other set is shown for reference.

## Settings

Tap the gear.

![Apps settings](img/apps/apps-settings.png)

### Tiles

Every tile is listed, hidden ones greyed and grouped ones with their group's name.

- **The arrows** move a tile to the top, up one, down one or to the bottom.
- **The eye** shows or hides it.
- **The x** removes a shortcut or deletes a group.
- **Undo** at the top puts back the last move (tap again for the one before).
- **Add shortcut** is at the end of the list.

### Display

- **Layout**: **Tiles** (outlined), **Bold tiles** (filled black), **Compact** (small tiles, just the icon and name, so many fit on a page), **List** (a row each; two columns on its side) or **Icons** (like a phone; smaller when that fits two rows).
- **Clock**: **Large**, or **Small** (the time and date on one line, leaving more room for tiles). On its side the clock is always the one-line kind.
- **Recent items**: **Separate rows** (books, notebooks and crosswords each in a row, sharing lines when they fit) or **One row** (the newest of each).
- **Columns**: 1, 2 or 3 tiles across (two more when turned on its side).
- **Dark mode**: a black launcher.
- **24-hour clock**.
- **At a glance**, **Quick settings** and **Recent books**: the three rows under the clock.
- **Night mode**, **Light** and **Refresh screen**: KOReader's own.
- **Sleep screen** and **Sleep screen updates**: see "The sleep screen" in Getting started.
- **Undo a plugin update**: lists the plugins that have an earlier version, each as "name (before <date>)". Pick one and confirm with **Go back**; KOReader restarts. With none to undo it says "No plugin has an earlier version to go back to."

![The List layout](img/apps/launcher-list.png)

### Start

- **Open at startup**: Apps opens when KOReader starts.

### Wi-Fi

- **Turn off when idle**: **Off**, or after 5, 15 or 30 minutes with no network use. Downloads, syncing and Home Assistant's updates count as use. It never turns Wi-Fi off while the web server is on, and time asleep doesn't count. A notice says when it happens.

## The Apps sleep screen

With **Sleep screen** set to **Apps summary**, the sleeping Kindle shows:

- The date, "Sleeping since 3:05 PM" and the battery (with the charging sign on the charger).
- The weather with today's high and low.
- **NEXT**: the next event or reminder.
- **TODAY**: today's and overdue tasks, with boxes.

## Gestures on the launcher

- **Swipe** left or right to turn pages (also up or down).
- **Swipe diagonally** for a full refresh.
- Your own KOReader gestures that aren't taps work here too, for the light, night mode, a refresh, Wi-Fi, a screenshot and the apps.

### Tips

- Hold anything that has no menu of its own and it acts like a tap.
- The screen flashes clean every few changes and whenever you come back from another app or a dialog.
- Shortcuts to a To Do list or a Home Assistant room show that place's own line, so the launcher becomes a small dashboard.
