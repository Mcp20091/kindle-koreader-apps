# To Do

Your Microsoft To Do lists on the Kindle: Today, an Agenda, Starred, a calendar and every list. Everything works without Wi-Fi; your changes are sent to To Do the next time it syncs.

![To Do's Home](img/apps/todo-home.png)

## Opening it and signing in

Open it from the launcher's **To Do** tile, **Tools > To Do**, or a gesture: **To Do**, **To Do: Today**, **New To Do task** (adds a task from anywhere) or **To Do: sync**.

The first time:

1. Tap **Sign in to Microsoft To Do**.
2. The Kindle shows a web address and a short code. On your phone or computer, open the address (or scan **QR code**) and enter the code, then sign in to Microsoft there. Your password never goes through the Kindle.
3. "Signed in to To Do", and the first sync starts.

The code box closes only with **Cancel**. If Wi-Fi drops while you sign in, it stops with "Lost the connection to Microsoft. Check Wi-Fi and try signing in again."; a code left too long says "The code ran out. Try signing in again."

> To Do needs an **App ID**: the ID of an app you register (free) at entra.microsoft.com: for personal Microsoft accounts, **Allow public client flows** set to **Yes**, and the delegated **Tasks.ReadWrite** permission (add **Notes.ReadWrite** too if Notes will share it for OneNote). Set it in Settings > **App ID**, or on the web page, before signing in; if it's missing, the sign-in says so.

## Home

- **The tiles**: **Today** (due today and overdue), **Agenda** (the next 7 days), **Starred**, **Calendar** (this month), and **Search** (off to start with; turn it on in Settings). Tap one to open it; hold one for **Open** or **Add to Apps**.
- **LISTS**: every list with its open tasks, and in bold how many are overdue or due today. The pinned list comes first. **+** next to LISTS makes a new list.
- **The round +** at the bottom right adds a task to your default list.
- **The bar at the bottom** says how many changes wait to be sent and when it last synced, such as "Everything sent · Synced 5 min ago". Tap it for the Sync screen.
- At the top: **⋮** (Settings, **Open on the web page**, Light, Night mode, Refresh screen), **sync** and **search**. **Open on the web page** starts the web server and shows a QR code for the web page's To Do tab.

### Holding a list

Hold a list on Home for:

- **Open** and **New task**
- **Pin to top**
- **Add to Apps**
- **Set as default list**
- **Hide list**: hidden lists stay out of Today, the Agenda, the calendar and the sleep screen
- **Rename** and **Delete list**

A deleted list waits under **Deleted lists** on Home until the next sync, so **Put back** can undo it.

## Lists and tasks

A list shows its tasks grouped **OVERDUE**, **TODAY**, **UPCOMING** and **NO DUE DATE** (or as one list: **⋮ > Group by due date**). Starred tasks come first within each day (**Starred first**).

![A list](img/apps/todo-list.png)

A list's (or a view's) **⋮** has **Starred first: On/Off**, **Group by due date: On/Off** (in a list), **List options…** (as holding the list), **Sync now**, **Open on the web page** (a QR code for this list on the web page), **Refresh screen** and **Settings**. On a task's page, **⋮** opens the task's quick actions.

Each task shows its due day, reminder time, repeat, steps ("2/5"), a notes mark, and a star.

- **Tap the box** to tick a task off. "Done: …" confirms it. It stays crossed out until the next sync; tap again before then to undo.
- **Tap the star** to star or unstar it.
- **Tap the task** to open it (or its quick actions; see **Tap action** in Settings).
- **Hold the task** for quick actions:
  - **Done** / **Not done**
  - **Star**
  - **Due today**
  - **Tomorrow**
  - **Pick a date…**, or **Skip to current** for a repeating task
  - **Postpone…**: by 1, 2, 3, 7, 14 or 30 days, or a date
  - **Move to list**
  - **Delete**
  - **Open**

A deleted task waits under **Deleted** at the end of its list until the next sync, with **Put back**.

## Adding a task

Tap **+** (on Home, in a list or in a view). The **Add to** box opens with the keyboard:

- **List**: which list it goes in.
- **Today**, **Tomorrow** or **Pick date**: when it's due. Tap again to clear.
- **Reminder**: a time on the due day.
- **Repeat**: **Daily**, **Weekdays**, **Weekly on (day)**, **Every 2 weeks**, **Monthly on day (n)** or **Yearly**.
- **Star**.
- **Write it**: write the task by hand in Notes instead of typing. Notes reads your writing, and any date or time you write becomes the due date and reminder.
- **Add**.

Adding from Today makes it due today; adding from Starred stars it; holding a day in the calendar makes it due that day.

### Dates in plain words

Type the date and time with the task, and To Do understands them:

- "Pay rent Friday 9am"
- "Call the vet tomorrow at 3:30pm"
- "Dentist on Oct 24"
- "Water the plants in 3 days"

Before adding, it shows what it understood: "Pay rent", **Due Fri, Oct 23 · Reminder 9 AM**. Tap **Add**, or **Keep as typed** if it guessed wrong (for example a task really called "Sun lamp").

![What To Do understood](img/apps/todo-words.png)

It understands:

- **Days**: today, tonight, tomorrow, the days of the week (Mon or Monday, this Friday, next Friday, on Friday).
- **Later**: next week (the start of next week), in 3 days, in 2 weeks.
- **Dates**: 10/24, 10/24/2026, Oct 24, October 24th, 24 Oct, Oct 24, 2026. A date that has passed means next year.
- **Times**: 9am, 9:30pm, 9 a.m., noon, midnight, or "at 17:30".
- A time alone means today, or tomorrow once that time has passed.

The same works when you rename a task: **Rename and set date** or **Keep as typed**.

## A task's page

![A task's page](img/apps/todo-task.png)

- **The box** ticks it off; **the star** stars it.
- **The title**: tap to rename it.
- **Due**: **Today**, **Tomorrow**, **Next week**, **Pick a date…** or **No due date**. Changing the due date moves the reminder with it. Hold to clear.
- **Reminder**: a time on the due day, or **Another day…**, or **No reminder**. Reminders ring on your phone (To Do keeps them), and also on the Kindle while KOReader is open (Settings > **Reminder alerts**).
- **Repeat**: the presets, or **Custom…** (every 1 to 99 days, weeks, months or years), or **Remove repeat**.
- **Skip to current** (a repeating task): moves it to the first day it falls on from today.
- **Postpone**: by your usual number of days. Hold it to choose.
- **Due today**.
- **Remove repeat**: it stops repeating, its due date is cleared, and a note with the old date is added.
- **Open in Notes**: when the task was made from a Notes page, this goes back to that page.
- **STEPS**: tap a step's circle to tick it; tap the step to rename or delete it; **Add step**.
- **NOTES**: tap to read and edit the task's notes.
- At the bottom: **Move to list**, **Hide on sleep** (keeps this task off the sleep screen) and **Delete**.

## Today, Agenda, Starred, Calendar, Search

- **Today**: what's overdue and what's due today.
- **Agenda**: overdue, today, then each of the next 6 days, by reminder time.
- **Starred**: starred tasks from every list.
- **Calendar**: the month, with a dot for each task due that day (a hollow dot is overdue). Repeating tasks show on the days they will fall on; tasks that repeat every day or two are listed once instead. Tap a day for its tasks; hold a day to add a task due then. Swipe or use the arrows for other months.
- **Search**: titles, notes and steps in every list, including done tasks.

## Split view

Turned on its side, To Do can show a column on the left with Home's tiles and lists, and the open list or view on the right (Settings > **Split view (landscape)**). Tap something in the column to open it on the right.

## Syncing

Every change shows at once on the Kindle and waits to be sent. Syncing sends the waiting changes, in order, then downloads everything. It runs in the background, so you can keep reading and tapping while it works; changes you make meanwhile go in the next sync.

- **Sync**: the sync icon, the Sync screen, or the gesture. KOReader asks to turn Wi-Fi on if it's off. "Syncing To Do…" shows while it works.
- **Background sync**: every 15, 30 (to start with), 60 or 120 minutes while KOReader is open and Wi-Fi is already on, and when Wi-Fi comes on if the last sync is older than that or changes are waiting. It never turns Wi-Fi on.
- **Sync changes immediately**: when Wi-Fi is on, changes go a few seconds after you make them.
- A sync asked for while another runs follows it. One that gets no answer for 5 minutes stops with "To Do took too long to answer"; your changes stay waiting for the next.

The **Sync screen** (tap the bar at the bottom) lists the **CHANGES TO SEND**, and has:

- **Sync now**
- **Download only**: downloads without sending.
- **Preview changes**: says what To Do has new, changed or done since the last sync, without changing anything.
- **Reset to To Do**: throws away the Kindle's unsent changes and downloads To Do's copy again.
- **Catch up overdue repeats**: moves every overdue repeating task to its next day from today, after showing where each goes.

If To Do refuses a change (say, a task already deleted on your phone), it's left out and listed, not retried forever.

## The sleep screen

With **Sleep screen** set to **To Do tasks**, the sleeping Kindle shows the day and date, how many are due and overdue, and the tasks. **Sleep screen content** chooses:

- **Today + Up next**: overdue, today and the next days.
- **Today**: overdue and today.
- **Starred**.
- **Pinned list**.

Done tasks, tasks hidden on sleep and hidden lists are left out.

## Settings

**⋮ > Settings** on Home.

### Home

- **Home tiles** and **Lists**: order them and choose which show. Tap one, then the arrows (to top, up, down, to bottom); the eye shows or hides it; **Undo** puts back the last move.
- **Show hidden lists**, **Pinned list** and **Default list**.

### Tasks

- **Starred on top**.
- **Group by due date**.
- **Tap action**: **Open task** or **Quick actions**.
- **Postpone by**: the usual number of days (1 to 60).
- **Confirm before deleting**.
- **Reminder alerts**: reminders pop up on the Kindle while KOReader is open, with **Done** and **Open**. Ones missed in the last two hours (while asleep) show when it wakes.

### Display

- **Night mode**, **Light** and **Refresh screen**.
- **Full refresh**: how often the screen flashes clean (every 6 or 3 changes, every change, or never).
- **Clock and battery**, **Split view (landscape)** and **24-hour clock**.
- **Week starts on**: **Sunday** or **Monday** (also where "next week" starts).

### Sync, sleep screen and account

- **Background sync**, **Sync changes immediately** and **Download only**.
- **Sleep screen**, **Sleep screen content** and **Sleep screen updates**.
- **Sign out** (also removes the tasks kept on the Kindle and any unsent changes) and **App ID**.

### Tips

- The **Flagged emails** list from Outlook shows in Starred and its own list, but stays out of Today, the Agenda and the calendar.
- Hold a Home tile and choose **Add to Apps** to put Today or a list on the launcher, with its own count.
- The web page's To Do tab has the same lists with a keyboard, plus CSV import and export.
- Your KOReader gestures for the light, warmth, refresh, night mode, Wi-Fi and a screenshot, and the other apps' actions (Apps, Notes, Home Assistant, Web server, Wikipedia, Syncthing, SSH), work on To Do's screens too. Library and book actions don't.
