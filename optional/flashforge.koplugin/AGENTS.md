# AGENTS.md: FlashForge (optional/flashforge.koplugin)

Notes for AI coding agents working on this plugin. The shared parts of the apps (title bar, pop-ups,
notifications, launcher, guide) are in the top-level AGENTS.md; this file covers only FlashForge.

## What it is

A FlashForge 3D printer on the Kindle, over the printer's own LAN HTTP API (no Home Assistant): the print,
temperatures, pause/resume/cancel/clear, light, filtration, a camera picture, the Material Station, and
starting one of the printer's recent files with material matching on the AD5X. An **optional** app: it lives
in `optional/`, isn't in the main install zip, and has its own (`optional/build-zip.py`). The launcher shows
its tile only when it's installed (`plugin = "flashforge"` in appsmodel's TILES).

## The printer's API (what ffapi.lua speaks)

- `POST http://<ip>:8898/<endpoint>` with JSON `{ serialNumber, checkCode, … }`. Answers `{ code = 0, … }`
  (some firmware: 200); a wrong serial number or check code answers with another code (→ `"signin"`).
  Some printers send `Content-Type: appliation/json`: the body is read whatever the header says.
- `/detail` → `{ detail = { … } }`: everything the screens show (ffmodel.info reads it). `/product` →
  `{ product = { lightCtrlState, … } }`: read once per run, only for whether there is a light.
- `/control` `{ payload = { cmd, args } }`: `jobCtl_cmd { jobID = "", action = pause|continue|cancel }`,
  `lightControl_cmd { status = open|close }`, `circulateCtl_cmd { internal, external = open|close }`,
  `stateCtrl_cmd { action = "setClearPlatform" }`.
- `/gcodeList` (ten latest files; only the AD5X sends `gcodeListDetail` with per-tool materials),
  `/gcodeThumb { fileName }` → base64 PNG, `/printGcode` (body per model: `M.printBody`).
- Camera: `http://<ip>:8080/?action=stream` (or `cameraStreamUrl` from /detail), MJPEG; the first JPEG
  (FFD8…FFD9) is cut out of the stream.
- Discovery: an empty UDP datagram to 255.255.255.255:48899 (and 8899, 19000, multicast 225.0.0.9);
  modern printers answer with 276 bytes: name (0x00), product ID (0x88, the same numbers as `pid`),
  serial number (0x92). Answers come to port 18007, opened in the Kindle's firewall while listening.
- Models by `pid` (never by the user's printer name): 35 Adventurer 5M, 36 5M Pro, 38 AD5X, 40 Creator 5,
  41 Creator 5 Pro. Filtration, TVOC and the door by model; the chamber when `chamberTemp` is reported
  (a Creator 5 without one says -108).
- The reference is the Python library `flashforge-python-api` (ff-5mp-api-py) and the Home Assistant
  integration `ff-5mp-hass`, whose `job.py` the matching rules here are ported from. Change both sides of a
  rule together and add a test.

## Files

- `main.lua`: the plugin. Settings (`settings/flashforge.lua`: ip, serial, code, name, model), reading the
  printer in the background (`fetch`, `status`), actions (`act`), files, thumbnails, the camera, discovery,
  notifications, the launcher's line (`appsLine`), every registration with the launcher (`shareWithApps`),
  quick buttons, search, and the web page's `webState()` / `webAct(name, args)`.
- `ffui.lua`: the screens (main page, Recent files, a file, Match materials, Camera, Details, Settings,
  Find printers), and reading every few seconds while a FlashForge page is on top (`UI.poll`; pages with
  `live`). `UI.refreshAll()` redraws the top page only when what it shows changed.
- `ffpage.lua`: FlashForge's full pages (from SSH's sshpage.lua), plus `picture` (a PNG or JPEG fitted
  to the width), `job` (the print: a picture beside its lines and bar) and rows with a `swatch` (a grey).
- `ffmodel.lua`: plain Lua, tested: /detail as a table, states and texts, times, colours in words and as
  greys, the recent files, the matching rules (`needsMatching`, `autoMatch`, `slotProblem`, `validate`,
  `colorWarnings`), the print request per model (`printBody`), discovery answers.
- `ffapi.lua`: the requests (blocking: only in a child process), base64, the camera, discovery.
- `ffbg.lua`: a job in a child process (SSH's sshbg.lua).
- `ffko.lua`: the ⋮ menu and pop-up wrappers (SSH's sshko.lua; `PS.ko` when the launcher is there).
- `fftitle.lua`, `ffcanvas.lua`: **copies** of the launcher's `appsbar.lua` and `appscanvas.lua`. Re-copy
  them when those change; don't edit them here.
- `icons/` (Lucide, ISC), `tests/run.lua`, `docs/guide.md` (the user guide chapter).

## How it runs

- Nothing in the background. The printer is read while a FlashForge page is on top (Settings > Read every,
  10 s by default, 5 to 300), when the launcher draws the tile (at most once a minute) and when a quick
  button shows. Only on Wi-Fi already (`NetworkMgr:isConnected()`); it never turns Wi-Fi on.
- Every request runs in a child process (`ffbg.run`) with a deadline; KOReader's loop only polls.
- Pictures go to `koreader/cache/flashforge/`: thumbnails by file name (read once), camera pictures as a
  new file each time (the page keeps pictures by path), the one before removed. ffpage frees its pictures
  when the last FlashForge page closes.
- Notifications: one key, `flashforge:job`: "Print finished: …" (seen going from a print to finished) and
  "Printer error …"; it goes when the next print starts or the printer is ready again.

## Rules

- Cancel asks first (it can't be put back); everything else just does it.
- Starting a print is refused while the printer is busy or the plate isn't cleared (as the printer would).
- The Creator 5 has no Start print here (the same message as the Home Assistant card): it doesn't report a
  stored file's materials, so its tools can't be matched to slots. Don't infer them.
- Made-up data only (192.168.1.50, "Workshop", SN0000000001). The serial number and check code never go in
  logs, the diagnostics file or `webState()`; the backup has them only with Include keys and sign-ins.

## Testing

```sh
luajit tests/run.lua        # plain-Lua tests of ffmodel (and base64)
```

On the emulator, without a printer: point the IP address at a small local server answering `/detail` with
a made-up payload. On a Kindle: Find printers needs the printer on the same Wi-Fi with LAN-only mode on.
