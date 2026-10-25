# Kindle apps for KOReader

A set of KOReader plugins that turn a jailbroken Kindle Scribe into a small system of its own: a launcher, a library for your books, Home Assistant, Microsoft To Do, handwritten notes, crosswords, Wikipedia, Syncthing, SSH, and a web server for running it all from a phone or computer's browser. Every app shares one title bar, one notifications list, one settings design and one look for pop-ups.

> **Made almost entirely by AI.** The code, the guide and its screenshots were written by Claude (through Claude Code), with a person choosing what to build, testing it on a Kindle and reporting bugs. See [How this came about](#how-this-came-about).

![The launcher on the Kindle, and the Kindle's web server page on a computer](media/overview.png)

## How this came about

It started as a way to get Home Assistant and Microsoft To Do onto my Kindle. As I kept going, I saw that people build their own interfaces on top of KOReader, saw the potential in that, and it grew into the set of apps here.

Almost all of it (the code, the guide and its screenshots) was written by AI: Claude, through Claude Code. My part was the direction: what to build, picking between designs, testing on the Kindle, and finding bugs and sending them back to be fixed. Many of the design choices came out of that back and forth, and a good share of the best ones were the AI's own.

## The apps

| Folder | App |
|---|---|
| `apps.koplugin` | **Launcher**: the home screen, Reading statistics, Weather, Fonts, and the pieces every app shares. |
| `library.koplugin` | **Library**: your books and folders, in place of KOReader's file browser. |
| `homeassistant.koplugin` | **Home Assistant**: your lights, locks, cameras and the rest, and a Dashboard tile. |
| `todo.koplugin` | **To Do**: Microsoft To Do, or lists kept on the Kindle only. |
| `notes.koplugin` | **Notes**: handwritten notebooks for the pen. |
| `crosswords.koplugin` | **Crosswords**: daily crosswords solved with the pen. Needs Notes. |
| `wikipedia.koplugin` | **Wikipedia**: read articles, and save them for offline. |
| `syncthing.koplugin` | **Syncthing**: folders in sync with your computer and phone. |
| `sshclient.koplugin` | **SSH**: run commands on your other devices. |
| `webpage.koplugin` | **Web server**: the Kindle from a phone or computer on the same Wi-Fi. |

Each app works on its own, except Crosswords, which needs Notes. The launcher ties them together: without it, the others still work, without the shared ⌂ button, notifications and settings list. No account or service is required: each one you skip only turns off what needs it (see [If you skip it](guide/setup.md#if-you-skip-it)).

## Features

Tap an app to see what it does. Each one links to its chapter of the guide.

<details>
<summary><b>Launcher</b>: the home screen, and the pieces every app shares</summary>
<br>
<img src="guide/img/apps/launcher.png" width="300" alt="The launcher"> <img src="guide/img/apps/apps-stats.png" width="300" alt="Reading statistics">

- Big tiles with a live line each ("2 today · 1 overdue", "62° Clear"), in groups with their own icons, plus shortcuts to any Home Assistant room, To Do list, notebook or KOReader action.
- At a glance under the clock: the weather, what's next and the tasks due. Quick buttons for Wi-Fi, the light, night mode and a refresh.
- **Reading statistics**: today, the last 7 and 30 days, streaks, when you read by hour and weekday, and every book with its percent, time left at your pace and its sessions (fix or delete one).
- **Weather**: Home Assistant's, or a free forecast with no account: now, US alerts, the next 24 hours and 7 days.
- **Fonts**: your fonts drawn in their own typefaces, good reading fonts from Google Fonts with one tap, and the font settings.
- **Quick buttons** under the clock and in the control center (every app): Wi-Fi, the light, New task, New note, Continue reading, the weather, Home Assistant devices with − and + or a speaker's controls, sensor readings, To Do lists, KOReader actions and more, in groups. Tap does it; hold opens what's behind it. A visual editor in the web server.
- One title bar, notifications, Recent apps, a drop-down control panel, search across every app (settings too), Undo, and one Settings list for everything, with its own tile.
- Make the home screen yours: suggested groups (Reading, Home, Writing, Tools…), groups sorted A–Z or by hand, and a saved copy of the home screen to go back to.
- Paste between apps, in any box.
- Set up your Kindle: a skippable walkthrough that says what you get without each service. Open it again later for a list of what's done, and set up the rest.
- A widgets sleep screen, and the same title bar over books and the library.

[The launcher chapter](guide/apps.md)
</details>

<details>
<summary><b>Library</b>: your books and folders</summary>
<br>
<img src="guide/img/library/home.png" width="300" alt="The Library's Home"> <img src="guide/img/library/book.png" width="300" alt="A book's page">

- Continue reading, recent books, Reading, To read, Finished and On hold, authors, series and collections, as covers or a list.
- Sort and group by author, series, status, format, language or folder.
- A page for each book: how far you are, the time left at your pace, its highlights and its details. **Find details online** fills in what's missing from Open Library or Google Books.
- Your folders, with Move, Copy, Rename and Delete (with Undo), and Select for many at once.
- Uses KOReader's own records, so progress, highlights and collections stay the same. KOReader's file browser is one tap away, or can stay the default.

[The Library chapter](guide/library.md)
</details>

<details>
<summary><b>Home Assistant</b>: your home on the Kindle</summary>
<br>
<img src="guide/img/apps/ha-home.png" width="300" alt="Home Assistant's Home"> <img src="guide/img/apps/ha-dashboard.png" width="300" alt="The dashboard">

- Lights, switches, fans, the thermostat, locks, the garage, vacuums, speakers, TVs, scenes and scripts, room by room.
- Quick tiles for what you use most, and On now to turn off what's left on.
- Cameras, with a snapshot sent to a Notes page.
- A **Dashboard** (its own tile on the launcher, for a nightstand or a wall) in five styles, and alerts on the sleep screen.
- Sign in with your Home Assistant user name and password, or a token. Nothing changes in Home Assistant.

[The Home Assistant chapter](guide/homeassistant.md)
</details>

<details>
<summary><b>To Do</b>: Microsoft To Do, or lists on the Kindle only</summary>
<br>
<img src="guide/img/apps/todo-home.png" width="300" alt="To Do's Home"> <img src="guide/img/apps/todo-task.png" width="300" alt="A task">

- Today, Agenda, Starred, a calendar and every list.
- Due dates, reminders, repeats, steps and notes. Type dates in plain words ("Pay rent Friday 9am").
- Works without Wi-Fi: changes wait and sync in the background.
- Works without an account too, with lists kept on the Kindle that you can move to To Do later.
- A sleep screen with today's tasks.

[The To Do chapter](guide/todo.md)
</details>

<details>
<summary><b>Notes</b>: handwritten notebooks for the pen</summary>
<br>
<img src="guide/img/notes/notes-writing.png" width="300" alt="Writing in Notes"> <img src="guide/img/notes/notes-list.png" width="300" alt="The notebook list">

- Ruled, grid, dotted or blank pages, or a PDF's pages. Notebooks in folders, locked notebooks, a trash, and Today's page.
- A pen with pressure, a highlighter, an eraser, shapes, the lasso, text boxes, pictures, tape and links.
- Tidy handwriting, a zoom window for small writing, two pages side by side, and writing on a book's pages.
- Search your notebooks, export them, and sync with OneNote, choosing the OneNote notebook and section for each notebook or folder.
- AI features with your choice of Claude, Gemini, OpenRouter, Groq or your own Ollama: handwriting to text, Ask, and more. Their buttons stay hidden until you set one up.

[The Notes chapter](guide/notes.md)
</details>

<details>
<summary><b>Crosswords</b>: daily puzzles solved with the pen</summary>
<br>
<img src="guide/img/crosswords/cw-solve.png" width="300" alt="Solving a crossword"> <img src="guide/img/crosswords/cw-home.png" width="300" alt="The puzzle books">

- Daily crosswords from five newspapers, fetched by themselves or on demand.
- Write the answers in the squares with the pen, as on paper, and tick off clues.
- Reveal for the squares you circle and the answers page; with an AI service set up, hints and Check my answers too.
- Import a PDF of puzzles or a .puz or .ipuz file.
- A timer and landscape. Needs Notes.

[The Crosswords chapter](guide/crosswords.md)
</details>

<details>
<summary><b>Wikipedia</b>: read and save articles</summary>
<br>
<img src="guide/img/wikipedia/front-page.png" width="300" alt="Wikipedia's front page"> <img src="guide/img/wikipedia/article.png" width="300" alt="An article">

- Search, today's front page, and articles that open in KOReader's reader (your font, highlights and dictionary).
- Save articles as EPUBs to read without Wi-Fi.
- Link previews and the sources, from the toolbar.

[The Wikipedia chapter](guide/wikipedia.md)
</details>

<details>
<summary><b>Syncthing</b>: folders in sync with your computer and phone</summary>
<br>
<img src="guide/img/syncthing/app.png" width="300" alt="Syncthing">

- Keeps folders on the Kindle in sync over Wi-Fi: no account and no cloud.
- Folders, devices and requests to accept, with the Kindle's ID as a QR code.

[The Syncthing chapter](guide/syncthing.md)
</details>

<details>
<summary><b>SSH</b>: run commands on your other devices</summary>
<br>
<img src="guide/img/ssh/main.png" width="300" alt="SSH hosts"> <img src="guide/img/ssh/output.png" width="300" alt="A command's output">

- Save a PC, NAS or Raspberry Pi once, with a key or a password. It knows Linux, Windows, macOS, FreeBSD, pfSense, TrueNAS, Proxmox and ReadyNAS, and shows commands that fit each.
- Run a saved command with one tap, type your own, or open a live session. Run one on several hosts at once.
- Each host's status and stats with alerts, its Docker containers and services, and its files (edit them on the Kindle, or copy them to it).
- Wake a PC or NAS that's off, with Wake on LAN.
- With an AI set up: explain an output or error, summarize long logs, and write a command from a description.

[The SSH chapter](guide/ssh.md)
</details>

<details>
<summary><b>Web server</b>: the Kindle from your phone or computer</summary>
<br>
<img src="guide/img/apps/web-home.png" width="600" alt="The web page">

- Open it by scanning a QR code on the Kindle.
- Upload, download and organize books and files, with covers, as the Library shows them.
- Visual editors: the launcher's tiles drawn as its home screen, the quick buttons, Home Assistant's Home, the widgets sleep screen and To Do's Home tiles. Drag with a mouse, or tap for a menu on a phone.
- Reading statistics, and fixing reading sessions.
- Every app's settings and lists with a keyboard: To Do, Notes, Home Assistant, the launcher, Wikipedia, Syncthing and SSH.
- A Dashboard of your own, a remote for the Kindle's screen, and typing into the box open on the Kindle, or sending it a task or a note.
- KOReader's common settings and fonts, plugin updates without the USB cable, backups, and the tabs in your own order.
- Diagnostics: crashes, battery, memory, network checks, sleep history, logs, and one file to send when something goes wrong.
- Only reachable from devices on your own Wi-Fi network (not from the internet), and only while you have it running. Set a password for it in **Set up your Kindle**.

[The web server chapter](guide/webserver.md)
</details>

<details>
<summary><b>AI</b>: optional, with the service you pick</summary>
<br>
<img src="guide/img/apps/ai.png" width="300" alt="Settings > AI"> <img src="guide/img/apps/ai-local.png" width="300" alt="A local AI's page">

- Claude, Gemini, OpenRouter, Groq, your own AI (Ollama, LM Studio) or any OpenAI-compatible service. Set up once, used by every app.
- **Notes**: handwriting to text, Ask about your pages, Make PDF and help with drawing.
- **Crosswords**: hints, and Check my answers.
- **SSH**: explain an output or error, summarize long logs, write a command from a description, and a chat beside a live session.
- **Handwriting recognition** in the apps' text boxes: write with the pen and the AI turns it into text.
- A different service or model for each job (free Gemini for handwriting, Claude for Ask), and a hold on any AI button to switch it on the spot.
- Model lists straight from each service, so new models show up without an update, and how much you have left, for the services that say.
- Test it, Try a prompt, and a preview of exactly what's sent, with each feature's instructions in your own words.
- Nothing shows until a service is set up. Free tiers work; your own AI keeps everything at home.

[The AI chapter](guide/ai.md)
</details>

## The guide

**[Kindle Apps Guide.pdf](Kindle%20Apps%20Guide.pdf)** is the whole user guide, laid out for the Kindle Scribe's screen. Copy it to the Kindle and open it in KOReader. To read it here instead, start at the guide's [contents page](guide/README.md): every chapter, with its screenshots.

## Installing

You need a Kindle Scribe with a jailbreak and KOReader. The [Kindle Modding jailbreak wizard](https://kindlemodding.org/jailbreak-wizard.html) finds the right jailbreak for your Kindle and its software version, and links to installing KOReader. This project isn't made by or affiliated with Kindle Modding or KOReader, and jailbreaking is at your own risk. Kindle is a trademark of Amazon; this project isn't affiliated with or endorsed by Amazon.

### Installing the zip

1. On this repo's [Releases](../../releases) page, download **kindle-plugins.zip** from the latest release, and unzip it on your computer. Inside is one folder per app (`apps.koplugin`, `todo.koplugin` and so on).
2. Connect the Kindle to the computer with its USB cable. It shows up as a drive.
3. Copy the contents of the zip into `koreader/plugins/` on the Kindle; if a folder of the same name is already there, replace it. (To install only some, keep `apps.koplugin`, the launcher, for the home screen and the shared pieces, and take Notes along with Crosswords.)
4. Eject the Kindle, then restart KOReader: in KOReader's menu, the last tab (**☰**) > **Exit** > **Restart KOReader**.

### Getting started

1. Open the launcher: in KOReader's menu, **Tools > Launcher**.
2. Set up your Kindle starts by itself the first time (later: the **Settings** tile > **Set up your Kindle**). It walks through Wi-Fi, the weather, each service, your home screen, how to browse your books and the web server's password, and says what you get without each one. Every step can be skipped and done later.
3. To have the launcher come up every time, turn on **Settings > Launcher > Open at startup**.

From then on the **⌂** button in the bar at the top brings you back to the launcher from any app, the library or a book. The guide's **Getting started** chapter has the rest.

### Updating

Later versions install without the cable: start the web server (**Tools > Web server > Start web server**, or **Web server** in the control center), open the address it shows on a phone or computer, and on the **System** tab, under **Update plugins**, tap **Install a zip…** and pick the new **kindle-plugins.zip**. Everything in it is checked first, and **Go back** puts a plugin back as it was. Copying the folders over USB again works too.

Some apps connect to other services and need a one-time setup, and every one of them is optional. The guide's **[Setting up the services](guide/setup.md)** chapter has the steps, and what you get without each:
- **Microsoft To Do and OneNote:** needed only to sync with Microsoft. It takes a free Microsoft app registration (an App ID); a personal Microsoft account needs a free Azure account first, for the directory to register it in. Without it, To Do keeps its lists on the Kindle and Notes keeps its notebooks on the Kindle.
- **Home Assistant:** its address, then sign in or use a long-lived token. Nothing changes in Home Assistant.
- **AI (handwriting recognition, Notes, Crosswords and SSH):** a key from Gemini or Groq (both have free tiers), OpenRouter or Claude, the address of your own Ollama, or any OpenAI-compatible service.
- **Syncthing:** the Syncthing program comes with the zip. Pair the Kindle with your computer or phone in the Syncthing app.
- **SSH:** an SSH server on the computer you connect to.
- **Nothing to set up:** the Library, Weather (a free forecast with no account), Wikipedia and the crossword sources.

## What it connects to

Everything is kept on the Kindle. Below is everything that reaches outside it, and nothing connects until you use it or set it up.

**Connections you set up.** Set them up in **Set up your Kindle**, in the launcher's **Settings**, or with the Kindle's web server (its page in a browser on your phone or computer). Without them, the apps that use them (To Do's and Notes' sync, Home Assistant, the AI features, Syncthing, SSH) have nothing to connect to; the rest work as before.

| Connects to | For | Set up in |
|---|---|---|
| Microsoft | To Do and OneNote sync | Set up your Kindle, or Settings > Microsoft |
| Home Assistant (your local and/or remote instance) | The Home Assistant app, the **Dashboard** tile, and the launcher's Home Assistant and weather lines | Set up your Kindle, or Settings > Home Assistant |
| Claude, Gemini, Groq or OpenRouter (with your API key), your own AI on your network (Ollama, LM Studio), or any OpenAI-compatible service | Handwriting recognition, and the AI features in Notes, Crosswords and SSH | Set up your Kindle, or Settings > AI |
| Your Syncthing devices | Syncthing | Set up your Kindle, or the Syncthing app |
| Your SSH hosts | SSH | SSH's **Add host** |

**Built in.** Nothing to set up; these connect when you use the feature.

| Connects to | For | When |
|---|---|---|
| Wikipedia | The Wikipedia app | You open it, search or read an article |
| The Guardian, USA Today, Universal, Washington Post and New Yorker | Downloading crosswords | Crosswords fetches puzzles |
| Open-Meteo and the US National Weather Service | The weather, as an alternative if you'd rather not use Home Assistant's or don't have it set up (no account; pick a place in Settings > Launcher > Weather) | The weather is on |
| Open Library and Google Books | The Library's **Find details online** | You tap it |
| Google | Google Fonts, and the internet connection test | You get a font, or run a connection check |

## Building the guide PDF

```bash
pip install reportlab pillow
python guide/build.py "Kindle Apps Guide.pdf" --fonts FONTS_FOLDER
```

The fonts folder needs NotoSans-Regular, -Bold, -Italic and -BoldItalic and DroidSansMono (all in KOReader's `fonts` folder), plus Segoe UI Symbol (`seguisym.ttf`) for symbols.

## Reporting problems

Open an [issue](../../issues) here. If something went wrong on the Kindle, start the web server, open the **System** tab and tap **Download a diagnostics file**: one zip with the logs, versions, problems, sleep history, memory, battery and network. It has no passwords, keys or sign-ins, but look it over before you attach it: the logs can show your Kindle's address on your network and the apps and services you use.

## For developers

See [AGENTS.md](AGENTS.md) for how the plugins fit together, the shared UI rules and how to test. Each plugin folder has its own `AGENTS.md` too.

## Licence

AGPL-3.0, the same as KOReader; see [LICENSE](LICENSE). The Syncthing plugin is based on [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing) by jasonchoimtt. The guide's [Credits](guide/credits.md) list everything else these apps use.
