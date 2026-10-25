# Home Assistant for KOReader

Control your home from [KOReader](https://koreader.rocks) on a Kindle (made on a Kindle Scribe; any
KOReader 2026.07+ device should work): lights, switches, fans, thermostats, locks, garage doors, vacuums,
players, cameras, scenes and scripts, room by room, plus a dashboard for the nightstand.

- **Open it**: Tools > Home Assistant, or a gesture (Settings > Taps and gestures > Gesture manager >
  General > Home Assistant / Home Assistant dashboard).
- **Home**: weather and the inside temperature, an status bar (unlocked doors, an open garage, open
  doors and windows, batteries under 20%), what is on now with **Turn all off**, Quick tiles and the rooms.
- **Tiles**: tap to switch; hold for the controls (brightness and colour temperature, fan speed, presets
  and oscillation, thermostat mode, set temperature and fan, cover position, vacuum start/pause/dock,
  player controls and source). Locks, the garage and scripts ask first (each can be turned off).
- **Shortcuts** at the top of Home: Lights, Climate, Switches, Sensors, Cameras, Media, Scenes, Dashboard,
  Security (and Doors, Vacuums, Weather, Activity, Batteries, 3D printer): each opens everything of that
  kind. Pick which show and their order in Settings > Shortcuts (or on the Web server plugin's web page).
- **Security**: the status bar, every lock and door with its button (and **Lock all**), every camera, and
  door, window, motion and alarm sensors. **Climate**: thermostats with their set point (− and +), fans
  and each room's temperature and humidity. **Weather**: now and the days ahead. **Activity**: what
  changed, newest first. **Batteries**: every battery, lowest first. **3D printer**: its camera, the print
  (progress, file, time left, layers), pause, resume and cancel, temperatures and the rest.
- **Sensors**: temperature, humidity, doors, windows, leaks and smoke in your rooms show in each room and
  under Sensors (batteries, motion and the like can be shown in Settings > Devices). A leak, smoke or a
  device's problem that turns on goes in the status bar.
- **Cameras**: a still from each (tap for a new one, hold for full screen), greyscale for e-ink. Until it
  comes, a drawing stands in: a doorway, a garage, a room or a 3D printer, by the camera's name, or the one
  you pick (hold the camera).
- **Rooms** follow Home Assistant's floors (each floor's rooms in its order), unless you order them.
- **Dashboard**, in one of five styles: **Clock and info** (clock, weather and tomorrow's, the status
  bar, each room's temperature, a camera, Quick tiles), **Security** (up to four cameras, the locks and
  doors with their buttons), **Info cards** (big numbers: weather, inside, doors, locks, garage, lights,
  vacuums, the lowest battery), **Camera** (one big picture) or **Clock only**. It updates every few minutes and keeps the Kindle awake
  while it charges (or always, or never).
- **Looks** (Settings > Screens): tiles as **Cards**, **Big tiles**, a **List** (a switch or a button
  such as Unlock, Open or Start on each row) or **Minimal**; **Dark mode** on, off or for the dashboard
  only (camera pictures stay as they are).
- **Settings** (the gear): addresses, account, the start screen, the order of Home's sections, Quick tiles
  and rooms (pick a row up, move it with the arrows, hide it with the eye), the devices in each room, which
  devices show at all, what asks first, update timing and the dashboard.

Long screens turn pages (swipe, or the arrows by the title) instead of scrolling.
The ⋯ at the top right has KOReader's Light, Night mode and Refresh screen; your KOReader gestures
(two fingers, edge swipes, multiswipes, pinches) work on these screens too.

**Quick buttons**: with the launcher, any device can be one of its quick buttons (under the clock and
in the control center in every app): a light or fan with − and +, the thermostat's set point, a
speaker's ⏮ ⏯ ⏭, mute and volume, switches, locks, scripts and scenes, or a sensor's reading. Hold one
for the device here.

## Signing in

The first time, sign in with your Home Assistant username and password, as on the phone app (a two-step
code is asked for next if your account has one). Or use a long-lived token (Home Assistant > Profile >
Security): put it in `koreader/settings/homeassistant-token.txt` over USB and pick **Use a long-lived
token**.

Give a **home address** (e.g. `http://homeassistant.local:8123`) and, if you have one, an **away
address**. The home address is tried first (briefly); the one that answered is tried first next time.
If a proxy's sign-in page answers instead of Home Assistant (single sign-on in front of it), the plugin
says so: use an address that reaches Home Assistant itself.

The tokens are kept in `koreader/settings/homeassistant.lua`. **Sign out** in Settings also removes the
sign-in from Home Assistant.

## Which devices show

Everything Home Assistant has in those domains, by room (Home Assistant's areas), except switches that are
a device's own settings: a switch named apart from its device (its LED, firmware updates, motion
detection, do not disturb...) or on a device that is a camera, lock, player and so on. Settings > Devices
shows or hides anything; hold a tile and pick **Hide** to hide one there.

## How it talks to Home Assistant

One template (`hatemplate.lua`) is rendered by Home Assistant (`POST /api/template`) for each update:
every entity the plugin can show, with only the attributes it uses, every battery, a 3D printer's sensors
and buttons, each room's temperature and humidity, open doors, low batteries and the weather. Switching calls the service (`POST /api/services/...`) and shows
the new state at once; the real one follows a moment later. Pictures come from `/api/camera_proxy`.

Updates, switching, pictures (three at a time) and the forecast run in a child process, so the screen
keeps answering taps however long Home Assistant or a camera takes; leaving a screen stops its pictures.

The last states are kept (`koreader/settings/homeassistant-states.json`), so the screens open without
Wi-Fi. While open, the plugin updates every minute when the Kindle is online; it never turns Wi-Fi on for
that (tapping refresh or a tile does, as KOReader asks).

## Install

Copy this folder to `koreader/plugins/homeassistant.koplugin` and restart KOReader.

## Development

```bash
luajit tests/run.lua    # entities, rooms, summaries, taps, orders, sign-in, addresses, tokens
```

- `hamodel.lua`: the snapshot as entities and rooms; what each shows and does when tapped; summaries.
- `haapi.lua`: sign-in (login flow, two-step codes, tokens), home and away addresses, the calls.
- `hatemplate.lua`: the template Home Assistant renders.
- `hacanvas.lua`: drawing in page units (620 across), tap areas, page-turning flow.
- `haview.lua`: the screens; `hasheet.lua`: an entity's controls; `hasettings.lua`: settings, reordering,
  devices, sign-in dialogs.
- `main.lua`: the menu entry, updates, keeping the dashboard awake, pictures, the kept states.

Icons are [Lucide](https://lucide.dev) (ISC licence, `icons/LICENSE-lucide.txt`), in black and white
copies for light and dark tiles.
