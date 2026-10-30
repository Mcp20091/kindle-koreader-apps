# Syncthing for KOReader

Keeps folders on the Kindle in sync with your computer or phone, peer to peer over Wi-Fi, with [Syncthing](https://syncthing.net). Based on [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing) by jasonchoimtt (AGPL-3.0), with its own full-screen app, a tile on the launcher and a tab on the web page.

- **The app**: on/off (a switch), what Syncthing is doing ("Up to date", "Syncing · 3 files left"), how many devices are connected, and the Kindle's address.
  - **Requests**: a new device that wants to connect, or a folder a device shares. **Accept** (name the device, or pick the folder on the Kindle; it starts in the home folder) or **Ignore** (Syncthing won't ask again).
  - **Folders**: each with its state (Up to date, Syncing 42% with a progress bar, Scanning, Paused, Out of sync), path, files and size, and the last file that changed. Tap one for **Rescan**, **Pause**/**Resume**, **Open in Library** and **Details**. **Rescan all** rescans every folder.
  - **Devices**: Connected (with how far it is in sync), Paused, or when it was last seen. Tap one for **Pause**/**Resume** and **Details**.
  - **This Kindle's ID** (at the bottom): the ID as a QR code, to add the Kindle from Syncthing on a phone or computer.
  - While open it reads the status every 5 seconds and redraws only when something shown changed. When Syncthing is off, the folders and devices still show (from its config).
- **Title bar** (shared by the apps): back and home (both to the launcher), the time and battery, refresh, the bell (the launcher's notifications), **⋮**. New requests, folders with errors, folders stuck syncing and conflicting files are sent to those notifications and taken away when handled (`PS.notify` / `PS.unnotify` from pluginshare, when the launcher, apps.koplugin, is installed).
- **⋮ menu**: **This Kindle's ID**, **Web GUI** (Syncthing's own web page address, for settings not in the app), **Help**, **Recent apps**, **Light**, **Night mode**, **Refresh screen**, and **Settings** (a full page, as in Home Assistant): **Start with Wi-Fi** (starts when Wi-Fi connects, stops before it goes off; the upstream plugin's "Start with KOReader" carries over), **Password** for the web GUI (user name `syncthing`), **Port** (8384; change it while off).
- **Launcher**: a Syncthing tile on the launcher with "On · Up to date", "On · Syncing · 3 files left" or "Off". `ui.syncthing:appsLine()` gives the line; the event `ShowSyncthing` opens the app.
- **Web page**: a Syncthing tab (webpage.koplugin) with the same: on/off, requests to accept or ignore, folders with Rescan and Pause, devices, and this Kindle's ID to copy. `ui.syncthing:webState()` and `ui.syncthing:act(name, args)` are what it calls.
- **With the launcher** (apps.koplugin): a quick button (tap: on/off, hold: the app; `PS.registerQuick`), Syncthing's settings in the launcher's Settings list, its folders in the launcher's search, a pairing step in Set up your Kindle, the recent apps (`PS.registerSettings`, `registerSearch`, `registerSetup`, `noteRecent`; Recent apps in ⋮), the recent apps button next to ⌂, the control center from a tap on the time and battery (▾), and the apps' pop-ups (`stko.lua`: appspopup, KOReader's own without the launcher; Ignore with Undo). A swipe right from the left edge goes back; other swipes turn pages.
- **Backup** (the web page's System tab): the `syncthing_*` settings always; `settings/syncthing` (config, this Kindle's keys, the database) only with Include keys and sign-ins (`PS.backupApps.syncthing`).
- **Gestures**: Syncthing (opens the app) and Turn Syncthing on or off (the upstream plugin's action, so gestures made for it keep working).

Nothing syncs while the Kindle sleeps: Wi-Fi is off then.

## Install

1. Put `syncthing` (the Syncthing program for 32-bit ARM Linux) in this folder: `tools/fetch-syncthing.sh` downloads Syncthing v2.1.7 from its GitHub releases and checks its SHA-256 (the repo has it already, 25 MB; `tools/update-syncthing.sh` moves it to a newer release).
2. Copy the folder to `koreader/plugins/syncthing.koplugin` (it replaces the upstream plugin of the same name) and restart KOReader.

It keeps the upstream plugin's settings (`koreader/settings/syncthing`: the Kindle's device ID, folders and devices) and port.

## How it runs

`start-syncthing` creates Syncthing's config the first time (a random web GUI password, so the web GUI stays closed until you set one), writes the device ID to `settings/syncthing/device-id`, and starts `syncthing serve` in the background with its PID in `/tmp/syncthing_koreader.pid`. On a Kindle it opens the firewall for the GUI port, 22000 (sync) and 21027 (finding devices on the Wi-Fi) while running. KOReader talks to Syncthing's REST API on `127.0.0.1:<port>` with the API key from `config.xml`.

## User guide

`docs/guide.md` is this plugin's chapter of the Kindle apps guide (built by `apps.koplugin/docs/guide/build.py`); its screenshots are in `docs/img`, from the KOReader emulator.

## Development

```bash
luajit tests/run.lua
```

`main.lua` (starting and stopping, Start with Wi-Fi, the launcher and web page calls; every call to Syncthing runs in a child process, so KOReader never waits on it), `stview.lua` (the app and its dialogs), `stapi.lua` (Syncthing's REST API), `stmodel.lua` (plain Lua, tested: states, the summary line, sizes, times, config.xml), `stcanvas.lua` (drawing in page units, as in Apps and Wikipedia). To try it in the KOReader emulator on a PC, `tools/fetch-syncthing.sh . amd64`.

## Licence

AGPL-3.0 (see `COPYING`), as the upstream plugin. `cacert.pem` is Mozilla's CA bundle (from upstream). Icons are [Lucide](https://lucide.dev) (ISC licence, `icons/LICENSE-lucide.txt`). Syncthing itself is MPL-2.0.
