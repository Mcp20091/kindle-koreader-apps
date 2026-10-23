# Web server

The web server puts a web page on the Kindle that you open on a phone or computer on the same Wi-Fi. It manages everything in this guide with a keyboard and a big screen: files, the launcher, Home Assistant, To Do, Notes and crosswords, plus updates and backups.

## Starting it

1. On the Kindle: **Tools > Web server > Start web server**, the launcher's **Web server** tile or quick button, or a gesture (**General > Toggle web server**).
2. KOReader asks to turn Wi-Fi on if it's off.
3. The Kindle shows the address, such as `http://192.168.1.50:8080`. Type it in your phone or computer's browser, or tap **QR code** and scan it with your phone (the box also has **Stop** and **Close**).

Or from an app: **⋮ > Open on the web page** in To Do, Notes, the crosswords, Home Assistant, Apps and Wikipedia starts the web server if needed and shows a QR code that opens that same place on the web page (after signing in, if there's a password).

The page works while the web server runs and the Kindle is awake.

The **Tools > Web server** menu:

- **Start web server** / **Stop web server**. While it runs, the menu's own name shows the address: **Web server: http://…**.
- **Show address**: the address and QR code again.
- **Keep Kindle awake while running**: on to start with, so it doesn't go to sleep while you use the page. If you put the Kindle to sleep yourself (the power button or the cover), the web server stops; when it wakes, a note says so. Start it again when you need it.
- **Stop after 30 minutes of inactivity**: on to start with; stops by itself when no browser has used it for half an hour.
- **Password: On / Off**: set a password (4 characters or more). Browsers then ask for it. **Remove password** takes it off.
- **Undo a plugin update**: go back to a plugin's version before its last update.
- **Port**: 8080 to start with.

It also stops when Wi-Fi is turned off.

> Anyone on your Wi-Fi can open the page while the web server runs, unless you set a password. The connection isn't encrypted, so start it when you need it and stop it after.

## The page

Tabs along the top: **Home**, **Files**, **Reading**, **Apps**, **Home Assistant**, **To Do**, **Notes**, **Crosswords**, **Wikipedia**, **Syncthing**, **SSH**, **KOReader** and **System**. A tab is greyed out when its app isn't installed. The page follows your phone or computer's light or dark mode. Lists you can order have the same controls everywhere: drag the **⠿** handle, or **⤒** (to the top), **↑**, **↓** and **⤓** (to the bottom), and **↶ Undo**.

### Signing in, and the page as an app

With a password set, the page asks for it once per browser. Leave **Stay signed in** ticked and that browser stays signed in for 90 days, even after KOReader restarts or the plugins update. Changing the password signs every browser out.

To keep the page on your phone like an app, open it and use **Add to Home Screen** (Safari's share menu, or Chrome's ⋮ menu). It gets its own Kindle icon and opens full screen.

![The page on a phone](img/apps/web-phone.png)

### Keyboard shortcuts

On a computer:

- **/** jumps to the search box.
- **1** to **9** open the first nine tabs that are on (greyed ones skipped), in order.
- **Esc** closes a box, or leaves a text field.
- **?** lists the shortcuts.

### Search

The search box at the top right searches everything at once. Type at least two letters and press Enter:

- **Notebooks**: their names, typed text and handwriting. Each result says the page, and whether it was found in handwriting or in the name.
- **To Do**: task titles, notes and steps (not tasks marked private).
- **Crosswords**: puzzle names and clues, such as "12 Across: …".

Tap a result to open it: a notebook in the Notes tab, a task's list in the To Do tab.

## Home

![Home](img/apps/web-home.png)

- **The Kindle**: its model, KOReader's version, the **Battery** and the **Storage** left.
- **On this page**: a card for each tab.
- **Kindle**: the Kindle's own controls:
  - **Light** (a slider and on or off) and **Warmth**.
  - **Night mode**.
  - **Refresh screen**.
  - **Turn off Wi-Fi** (the page stops working until Wi-Fi is back).
  - **Sleep**.
  - **Restart KOReader**.
- **Kindle screen**: **Show the screen** shows exactly what the Kindle shows right now, such as the dashboard. It's also a remote:
  - Click the picture to tap the Kindle at that spot (or choose **Click holds** to hold there instead).
  - **Swipe left**, **Swipe right**, **Swipe up** and **Swipe down** swipe across the Kindle; swipe left turns to the next page in a book.
  - **Live** takes a new picture every few seconds.
- **Send to the Kindle**: type something and send it as a task to a To Do list (the first line is the title, the rest its notes), or as **Notes: a new page**.
- **Sleep screen**: which app draws the sleep screen, and **Sleep screen updates**.

Updating plugins, backups and the password are on the **System** tab.

## Files

The Kindle's storage. It opens in the folder you looked at last (the documents folder the first time).

![Files, as a list](img/apps/web-files.png)

- **Home folder** and your favorite folders, under the folder's name: a click goes straight there. The Home folder is the one set in KOReader (or on the KOReader tab). Favorite files follow, marked ★: a click opens the file's folder with that file picked out.
- **☆ Favorites**: the star beside a folder or file adds it to your favorites (★); click again to take it off. A favorite folder is a KOReader folder shortcut, and a favorite file goes in KOReader's **Favorites** collection, so they show on the Kindle too, and stars set on the Kindle show here.
- **List** or **Covers**: the list shows names, sizes and dates; **Covers** shows each book's cover, title, author and how far you've read, like a bookshelf. Titles and covers come from KOReader; for a book it hasn't read yet, they appear a few seconds after you open the folder.
- **Sort by** name (or title), date or size, and **Filter this folder** to find a book by its name, title or author.
- **Everywhere** (or Enter in the filter box) searches every folder by name, title and author. A result opens its folder with the file picked out. **← Back to this folder** returns to the list.
- **Recent**: the newest files in every folder, such as what you just uploaded.
- **Collections**: KOReader's collections, as on the Kindle, each with its files (**✕** takes one out).
- **Storage**: the free space, and the biggest folders and files.
- **Upload to Home folder** sends books straight to the Home folder, from any folder; **Upload here** (or dropping files on the page) puts them in the folder you're in. Several files at once; a file with the same name is replaced.
- **From a link**: paste a web link to a book (or any file) and the Kindle downloads it into this folder, in the background. The page says when it's saved.
- **New folder**.
- Click a name to open it (pictures, PDFs and text open in the browser; other files download).
- Each file has **Download**, **Rename** and **Delete**. Books also have:
  - **▶ Open on the Kindle**: the Kindle opens the book straight away.
  - **✓ Mark as finished** (or **↺ Mark as reading**), as KOReader's own.
  - **ⓘ Details**: the cover, title, author, series, how far you've read, your reading time and when you last read it, pages, language and the description. From there: **Open on the Kindle**, **Highlights and notes**, **Collections…** and **Rename from details** (renames the file "Title – Author").
  - **Highlights and notes**: every highlight and note, chapter by chapter, with **Download as Markdown** or **Download as text**.
- **Drag** files onto a folder, a folder name in the path at the top, or **..** to move them there. Ticked files move together.
- Tick several and use **With selected…**: **Download** (one zip), **Move…**, **Mark as finished**, **Mark as reading**, **Add to a collection…** (ticks for each collection, or name a new one), **Rename from book details** (shows the new names first) or **Delete**.

The Kindle's library updates by itself after each change.

![Files, as Covers](img/apps/web-files-covers.png)

![A book's details](img/apps/web-book-details.png)

## Reading

From KOReader's reading statistics (the Reading statistics plugin must be on):

![Reading](img/apps/web-reading.png)

- **Today**: how long you've read today.
- **Days in a row**: your reading streak.
- **Last 7 days** and **All time**.
- **Progress sync**: for the book open on the Kindle, **Push progress from this device** and **Pull progress from other devices** (KOReader's Progress sync, such as with a CrossInk reader), and **Auto sync**. The messages show on the Kindle.
- **The last 30 days**: a bar for each day (point at one for its date and time). Click a day to see its reading, book by book, with times. Each has:
  - **Edit**: change its day, start or end. Moving keeps it as it was; an earlier end cuts the time after it (a book left open by mistake becomes the minutes you really read); a later end stretches each page's time to fit. It can't overlap other reading.
  - **Delete**: takes it out of the statistics.
- **Books**: each book you've read, with the time spent, the pages read and when you last read it. **Reset** takes all of a book's reading out of the statistics.

> On the Kindle, KOReader's **Tools > Reading statistics > Settings** has **Max read time per page**: a page left open longer than that counts only that long, so a book left open overnight doesn't add hours.

## Apps

![The launcher's tiles](img/apps/web-apps.png)

- **Tiles**: their order, and for each, **Main page** or a group, and a switch to show or hide it. Shortcuts have **✕** to remove them; groups can be renamed or deleted.
- **Add shortcut**: a Home Assistant screen or room, a To Do view or list, a notebook, a Notes folder, or a KOReader action.
- **Display**: **Layout** (**Tiles**, **Bold tiles**, **Compact**, **List**, **Icons**), **Columns**, **Clock** (**Large** or **Small**), **Dark mode**, **24-hour clock**, **At a glance**, **Quick settings** and a switch for each quick button (**Button: Wi-Fi**, **Light**, **Night mode**, **Refresh screen**, **Web server**; the Web server button is off to start with), **Recent books**, **Recent notebooks**, **Recent crosswords** and **Recent items** (**Separate rows** or **One row**).
- **Start**: **Open at startup**.
- **Wi-Fi**: **Turn off when idle**.

## Home Assistant

Inner tabs:

- **Connection**: the **Internal URL** and **External URL**; **Sign in with Home Assistant** (its own sign-in page, two-step codes included); or a pasted long-lived token.
- **Devices**: every device by room, with search and **All**, **Shown** and **Hidden** filters. Each has a box for whether it shows on the Kindle and a **★** to make it a Quick tile. **Show all** and **Hide all** act on what the filter shows.
- **Order**: Home's sections, the shortcuts, Quick tiles, rooms, the dashboard's sections, tiles and scenes, cameras, security cameras and **Sleep screen alerts** (**Add…** to pick one).
- **Routines**: make and change routines with a keyboard: a name, then steps (a device and what to do), **Run**, **Delete**.
- **Settings**: the same as on the Kindle: display (with **Clock and battery** and **Start screen**), dashboard (with **Doorbell alerts**: **Ring and motion**, **Ring only** or **Off**), **Weather**, **Wake alerts**, what asks first, camera placeholders and the update interval.
- **Backup**: **Export** saves the Home Assistant settings (not the sign-in) to a file; **Import** puts them back.

![Home Assistant's Devices](img/apps/web-ha-devices.png)

## To Do

The top says when it last synced and how many changes are waiting; **Sync now** and **Download only** are there.

![To Do](img/apps/web-todo.png)

- **Tasks**: your lists on the left (with **+ New list**, and **Rename**, **Pin**, **Hide on Kindle**, **Make default**, **Delete** for the open list). Add a task with its due date, **Starred**, and **Notes & steps**. Dates in plain words work here too: type "Pay rent Friday 9am" and the page shows what it understood before adding (**Add** or **Keep as typed**). Drag a task onto another list on the left to move it there. Tick tasks off, star them, or click one to change its title, due date, list, notes, steps and **Private** (hidden on the sleep screen and Home, and from search). **Show completed** and **Put back** for deleted ones. A repeating task shows its repeat (↻) with **Skip to current** and **Remove repeat**; repeats are set on the Kindle.
- **Settings and sign-in**: most of the Kindle's settings (the Home tiles' and lists' order, the pinned and default list, full refresh and the sleep screen's content stay on the Kindle; **Sleep screen** here is a switch, and **Postpone by** offers 1, 2, 3, 7 or 14 days), the **App ID**, and **Sign in**: the page shows the code to enter, and updates by itself when you're done.
- **Import / export**: **Export CSV** saves every task to a spreadsheet file; **Import CSV** adds tasks from one (**Download template** shows the columns: List, Title, Due, Starred, Notes, Steps).

## KOReader

KOReader's own settings, without leaving the launcher on the Kindle:

- **Folders**: the **Home** folder, the **Download folder**, the **Screenshot folder** and the other folders KOReader and its plugins keep. **Change…** opens a folder picker. **Lock home folder** keeps the library from going above the home folder.
- **Folder shortcuts**: your saved folders. **Add shortcut…** picks a folder and names it; each has **Rename** and **Remove**.
- **Sleep**: **Autosuspend**, how long the Kindle waits with nothing happening before it goes to sleep (from 5 minutes to 2 hours, or never).
- **KOReader's menu**: the same menu as on the Kindle, with its tabs (**Settings**, **Tools**, **Main** and the rest), live from KOReader. While a book is open it's the book's menu, with its own settings.
  - Switches (☐ and ☑) and choices (○ and ◉) change right from the page.
  - Tap a name with **›** to open that part of the menu; the line at the top shows where you are.
  - **⋯** does what holding the item on the Kindle does.
  - A choice that opens a dialog (a list, a slider, a time) opens it on the Kindle. The page then shows the Kindle's screen, so you can finish it with the remote.

![KOReader's folders](img/apps/web-koreader.png)

## System

- **Problems**: KOReader's crashes and freezes, read from its log, newest first. Tap one for the details. **Stopped without closing** usually means it froze and you restarted the Kindle by holding the power button. A freeze that it recovers from ("KOReader stopped answering") is only noticed while the web server runs. When KOReader ended badly, the launcher also says so the next time you open it.
- **What's installed**: each plugin's version (the date it was made) and **What changed** in its latest updates.
- **Update plugins**: **Install a zip…** installs new versions of the plugins (see Getting started). Everything in the zip is checked first; if anything is wrong, nothing changes. Under **Earlier versions kept**, **Go back** puts a plugin back as it was before its update.
- **Battery**: the level, and KOReader's battery statistics since the last charge (awake, asleep, the last charge, each with how much an hour), what is on now that uses power, and **Reset statistics**. The same as the launcher's Battery screen.
- **Health**: KOReader's memory and the Kindle's free memory, how long KOReader and the Kindle have been running, and:
  - **Detailed logging**: KOReader writes much more to its log, for tracking down a problem. It turns itself off after a day.
  - **Download a diagnostics file**: one zip with the logs, versions, problems, sleep history, memory, battery and network, to send when something goes wrong. No passwords, keys or sign-ins.
- **Network**: Wi-Fi, its signal and the Kindle's address. **Check** tries Home Assistant, Microsoft (To Do and OneNote), Wikipedia and the internet, and says which answer and how fast.
- **Sleep and wake**: each time the Kindle slept and woke (and when KOReader started), how long, and the battery at each end. A Kindle that never sleeps, or keeps waking, shows here.
- **Backup**: **Download backup** saves one zip with the settings of To Do, Notes, Home Assistant, Apps and your KOReader gestures, and all your notebooks (not Wikipedia's, Syncthing's or SSH's settings: SSH hosts and keys aren't in it). **Include keys and sign-ins** adds the sign-ins too (keep that file private). **Restore from a backup…** puts one back; KOReader restarts.
- **Automatic backups**: **Weekly backup** saves a backup on the Kindle once a week (settings and notebooks, without sign-ins), keeping the last 2, 4 or 8. **Back up now** makes one straight away; each has **Download** and **Delete**.
- **Logs**: KOReader's own log and the sleep screen updates' log. **Show the end** shows the latest lines; **Download** saves the whole file. Handy when something goes wrong, or to check that sleep screen updates are working.
- **Gestures**: what each KOReader gesture does, in the library and in a book, the same as the launcher's Gestures screen. To look at only: gestures are changed on the Kindle.
- **Password**: set, change or remove the page's password, and **Sign out**.

![Battery and Health on the System tab](img/apps/web-system.png)

## Notes, Crosswords, Wikipedia, Syncthing and SSH

The **Notes**, **Crosswords**, **Wikipedia**, **Syncthing** and **SSH** tabs are covered in their own chapters.

### Tips

- Bookmark the address on your phone: it stays the same as long as the Kindle gets the same address from your router.
- Updating plugins, restoring a backup and **Restart KOReader** restart KOReader, which stops the web server. Start it again to keep using the page.
- A password signs out every browser when you change it.
- An upload that stops getting through (a phone gone to sleep, say) is stopped with "Upload failed: the Kindle stopped responding"; upload it again.
