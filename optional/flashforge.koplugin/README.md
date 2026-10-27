# FlashForge for KOReader

Your FlashForge 3D printer on a Kindle, straight over the Wi-Fi: the printer's own LAN API (port 8898, the serial number and check code from its LAN-only mode), the one the [Home Assistant integration](https://github.com/GhostTypes/ff-5mp-hass) and FlashForge's desktop app use. No Home Assistant or cloud needed.

For the **Adventurer 5M**, **Adventurer 5M Pro**, **AD5X**, **Creator 5** and **Creator 5 Pro**. Older printers (Adventurer 3 and 4) have no HTTP API.

- **The print**: its picture (the file's thumbnail), state, progress bar, layer, time left and when it's done, how long it has printed; the error code; the door (Creator 5 Pro).
- **Buttons**: Pause, Resume, Cancel (asks first), Clear (the plate, after a print), Light, Filter (Off, Internal, External: 5M Pro and Creator 5 Pro), Camera.
- **Temperatures**: nozzle (each tool on the Creator 5), bed, heated chamber when there is one. While printing: speed, cooling fan, filament used.
- **Material Station** (AD5X, Creator 5): each slot's material and colour (in words, and as a grey swatch), the one in use.
- **Recent files**: the printer's ten latest, with print time, weight and materials (AD5X), and **Start print**. On the AD5X the file's materials are matched to the slots first (suggested, then checked as FlashForge's desktop app checks them: every tool mapped once, one tool per slot, no empty slot, the same material; a different colour only warns). On the Creator 5 it says *Local job management is not available on this printer.*, as the Home Assistant card does: the printer doesn't say which materials a stored file uses.
- **Camera**: one picture at a time (the first frame of its MJPEG stream), taken again with a tap.
- **Details**: model, firmware, address, nozzle, free space, lifetime printing time and filament.
- **Finding the printer**: a UDP broadcast on the Wi-Fi (the Kindle's firewall opened for the answers meanwhile), or its IP address by hand; then the serial number and check code.
- **With the launcher**: its tile (`ShowFlashForge`, line "Printing 42% · 1 h 5 min left"), Settings, search (the printer, the recent files), a step in Set up your Kindle, quick buttons (status, pause or resume, the light), Test connection, the backup (the serial number and check code only with Include keys and sign-ins), notifications (print finished, printer error), and a FlashForge tab on the web page.
- **Gestures**: **FlashForge** (opens it) and **FlashForge: light on or off**.

Nothing runs in the background: the printer is read while FlashForge is open (every 10 seconds; Settings > Read every), and when the launcher's tile or a quick button shows it.

## Install

An optional app: it isn't in the main install zip. Copy this folder to `koreader/plugins/flashforge.koplugin` (or unzip `flashforge.koplugin.zip` into `koreader/plugins/`) and restart KOReader. It works without the launcher, with KOReader's own dialogs.

The matching rules and per-model print requests are ported from the Home Assistant integration's `job.py` (ff-5mp-hass, MIT). Icons: [Lucide](https://lucide.dev) (ISC).
