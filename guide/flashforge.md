# FlashForge

FlashForge shows your FlashForge 3D printer on the Kindle: the print and how far along it is, the temperatures, buttons to pause, resume or cancel, the light, the air filter, a picture from the printer's camera, and starting one of its recent files. The Kindle talks to the printer directly over the Wi-Fi: no account, no cloud and no Home Assistant.

It works with the **Adventurer 5M**, **Adventurer 5M Pro**, **AD5X**, **Creator 5** and **Creator 5 Pro**. Older printers (Adventurer 3 and 4) have no network interface it can use.

## Installing it

FlashForge is an optional app: it isn't in the main install. To add it:

1. Open the launcher's **⋮ > Settings > Updates** and tap the **Optional apps** row (the web page's **System > Updates** has the same list).
2. Tap **Install** next to **FlashForge**. KOReader restarts.

Once it is installed, it is updated with every new version of the primary apps. **Remove** in the same list takes it off again.

By hand: copy `kindle-flashforge.zip` (from the release) to the Kindle, unzip it into `koreader/plugins/` and restart KOReader.

## What you need

- The printer and the Kindle on the same Wi-Fi.
- **LAN-only mode** turned on at the printer's own screen: **Settings > Network > LAN-only mode**. Note the **check code** it shows.
- The printer's **serial number**: on its screen under **Settings > About**. Type the **SN** at the start too.

## Opening it

- The **FlashForge** tile on the launcher. Its line says what the printer is doing: **Printing 42% · 1 h 5 min left**, or **Ready**.
- Three quick buttons on the launcher (add them in **Settings > Launcher > Quick buttons > Add a button > FlashForge…**, or on the web page's Launcher tab): **Printer status** (tap reads the printer again), **Pause or resume** and **Printer light**. A hold opens FlashForge.
- **Tools** in KOReader's menu > **FlashForge**.
- A gesture: **Settings > Taps and gestures > Gesture manager**, pick a gesture, then **General > FlashForge** (opens it) or **FlashForge: light on or off**.
- The launcher's **recent apps** and its **search**, which finds the printer and its recent files by name.

The title bar is the same as in the other apps: **‹** goes back, the house goes to the launcher, the clock with an arrow shows the recent apps; at the right are the time and battery, **⟳** (reads the printer again), the bell and **⋮**. A swipe in from the left edge goes back.

## Setting it up

The first time, the screen says **No printer set up yet.**

1. Tap **Find printers**. The Kindle looks for printers on the Wi-Fi and lists them under **Printers on this Wi-Fi**.
2. Tap yours. If none shows (**No printers found. Is it on, with LAN-only mode on?**), tap **Enter by hand** instead and type the printer's **IP address**, such as `192.168.1.50` (on the printer: **Settings > Network**).
3. Type the **Serial number** and then the **Check code**.

The Kindle reads the printer and says **Connected to …**. If it can't, the message says why: the printer doesn't answer, the Wi-Fi is off, or the printer refused the serial number or check code (check them in **Settings**).

The launcher's **Set up your Kindle** has the same step (**FlashForge printer**). It can be skipped and done any time later from the app.

## The app

- **The print box** at the top: the printer's state (**Printing 42% · 1 h 5 min left**, **Paused**, **Heating**, **Ready**…), and while it prints or just finished, the file's picture and name, a progress bar, the layer (**Layer 120 of 300**), how long it has printed and when it will be done (**done at 14:30**). An error shows its code (**Error code 5**), and the Creator 5 Pro says when its door is open.
- **Buttons** under it, shown when they apply:
  - **Pause** and **Resume**.
  - **Cancel**: asks **Cancel print?** first, because a cancelled print can't be resumed. **Keep printing** goes back.
  - **Clear**: after a print, tell the printer the plate is clear so it is ready for the next one.
  - **Light**: on or off.
  - **Filter**: the air filter (the 5M Pro and Creator 5 Pro): **Off**, **Internal (filters the air inside)** or **External (vents the air out)**.
  - **Camera**.
- **TEMPERATURES**: the **Nozzle** (**Tool 1**, **Tool 2**… on the Creator 5), the **Bed**, and the **Chamber** when the printer has a heated one.
- **PRINT**: while printing, the **Speed**, the **Cooling fan** and the **Filament** used so far out of the total.
- **MATERIAL STATION** (AD5X and Creator 5): each **Slot** with its material and colour (in words and as a grey swatch), **Empty** for one with nothing in it, and **In use** for the slot printing now.
- **MORE**: **Recent files**, **Camera** and **Details**.
- **At the bottom**: when the printer was last read (**Updated 14:02**), or **Not answering · last read 14:02**, and the printer's address.

While FlashForge is open the printer is read every 10 seconds (change it in Settings). Nothing is read once it closes, and nothing runs in the background.

### Recent files

**Recent files** lists the printer's ten latest files, each with its print time. Tap one to see its picture and what it needs (**MATERIAL** or **MATERIALS**, with the weight of each), then **Start print**.

- **Level the bed first**: a switch on that page, **Every print, until turned off**; the same switch is in Settings.
- On the **AD5X**, the file's materials are matched to the Material Station's slots first. The Kindle suggests a match and checks it: each material in a slot, no slot used twice, no empty slot, and the same material in the slot as in the file. Tap **Match materials** to change a slot. A different colour only warns you (**The colours differ (it still prints):**).
- Before it starts, the Kindle asks **Start printing … on …?**. **Start** begins the print.
- It can't start while the printer is busy, or before you tap **Clear** on the last print.
- The **Creator 5** says **Local job management is not available on this printer.** It doesn't tell the Kindle which materials a stored file uses, so start prints from FlashForge's own app or the printer's screen.

### Camera

**Camera** takes one picture from the printer's camera. To spare the battery it is one picture at a time: tap **Take again**, or **⟳**, for a new one.

### Details

**Details** lists the printer's **Name**, **Model**, **IP address**, **Serial number** (hidden except for its end), **Firmware**, **Nozzle** size, **Filament**, **Free space**, **Door**, **Error code**, and under **LIFETIME** its total **Printing time** and **Filament used**.

## The menu

The **⋮** menu has:

- **Find printers**, as in setting it up.
- **Details**.
- **Help**: a short version of this chapter's setup.
- **Recent apps**, **Light**, **Night mode** and **Refresh screen**, as in the other apps.
- **Settings**, always last.

## Settings

The same page opens from the launcher's **Settings** list, under **Optional apps > FlashForge**.

- **DISPLAY**
  - **Read every**: how often the printer is read while FlashForge is open, from 5 seconds to 5 minutes.
- **PRINTING**
  - **Level the bed first**: before each print started from the Kindle.
  - **Always show the light button**: for a printer that says it has no light but has one.
- **PRINTER**
  - **Printer**: the one set up; tap to find printers again.
  - **IP address**, **Serial number** and **Check code**. The last two show only their end.
  - **Test connection**: asks the printer and says what it answered.
  - **Remove printer**: forgets the printer. **Undo** at the bottom of the screen takes it back for a few seconds.

## Notifications and the backup

FlashForge adds two notifications to the bell, so you see them from the other apps: **Print finished** (with the file's name) and **Printer error** (with its code). Each goes when the next print starts or the printer is ready again. Tap one to open FlashForge.

The web page's backup (**System**) includes the printer and the settings; the serial number and check code only if you tick **Include keys and sign-ins**.

## On the web page

The web page (see the Web server chapter) has a **FlashForge** tab:

- The printer's state and progress, with **Pause**, **Resume**, **Cancel print** (asks first) and **Clear**.
- The temperatures, a **Light** switch and, on the printers that have one, the **Air filter**.
- The **Material Station**'s slots.
- **Settings**: **Read every**, **Level the bed first**, and the **IP address**, **Serial number** and **Check code**, with **Save** and **Test connection**.

Starting a print and the camera are on the Kindle only. The tab updates itself while the printer is read.

## Good to know

- **Same Wi-Fi**: the printer has to be reachable from the Kindle. If it isn't found, check LAN-only mode is on and that the printer and the Kindle are on the same network.
- **Nothing leaves your network**: the Kindle sends the serial number and check code only to the printer.
- **When it is read**: only while FlashForge is open, or when the launcher's tile or a quick button shows it. A print that finishes while the Kindle sleeps shows up the next time one of those reads the printer.
- The printer's matching rules for the AD5X follow the Home Assistant integration for FlashForge printers (ff-5mp-hass, MIT).
