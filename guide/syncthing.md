# Syncthing

Syncthing keeps folders on the Kindle in sync with your computer or phone, directly over Wi-Fi: no account and no cloud. Put a book or a PDF in a shared folder on your computer and it shows up on the Kindle a few seconds later; change something on the Kindle and it goes back the other way.

This plugin is based on **koreader-syncthing** by jasonchoimtt (github.com/jasonchoimtt/koreader-syncthing, AGPL-3.0), with its own app, a launcher tile and a web page tab added. Syncthing itself is made by the Syncthing project (syncthing.net).

![The Syncthing app, with a folder syncing](img/syncthing/app.png)

## Opening it

- The **Syncthing** tile on the Apps launcher. Its line says what Syncthing is doing: **On · Up to date**, **On · Syncing · 3 files left**, or **Off**.
- **Settings (gear) > Network > Syncthing** in KOReader's menu.
- A gesture: **Settings > Taps and gestures > Gesture manager**, pick a gesture, then **General > Syncthing** (opens the app) or **Turn Syncthing on or off**.

The back arrow at the top left closes the app. **↻** reads the status again (it also does that by itself every few seconds while the app is open).

## Setting it up

You need Syncthing on the other device too: **syncthing.net** for a computer, or Syncthing-Fork on Android.

1. Tap **Off** at the top right of the Syncthing box to turn it **On**. The first start takes a few seconds (**Starting…**).
2. Tap **This Kindle's ID** at the bottom. The Kindle shows its ID as a QR code.
3. In Syncthing on your computer or phone, choose **Add Remote Device** and scan the code or type the ID.
4. On the Kindle, the computer shows up under **Requests**: "Desktop PC wants to connect". Tap **Accept** and give it a name (it suggests the computer's own name).
5. On the computer, share a folder with the Kindle (in the folder's **Sharing** tab, tick the Kindle).
6. On the Kindle, the folder shows up under **Requests**: "Desktop PC shares “Papers”". Tap **Accept** and check where it goes. It starts in your home folder (for example `/mnt/us/documents/Papers`), so it shows in the Library. Tap **Add**.

The folder syncs straight away.

![Requests: a new device and a shared folder](img/syncthing/requests.png)

**Ignore** on a request means Syncthing won't ask about that device or folder again. To change your mind later, use Syncthing's own web page (see the menu below).

## The app

- **The Syncthing box**: what Syncthing is doing ("Up to date", "Syncing · 2 files left", "Scanning Books", "Errors in Papers", "No devices connected"), how many devices are connected, and the Kindle's address on the Wi-Fi. **On** / **Off** starts or stops it.
- **REQUESTS**: only when a device wants to connect or shares a folder (see above).
- **FOLDERS**: each folder with its state: **Up to date**, **Syncing 42%** (with a progress bar and what's left), **Scanning**, **Paused**, or **Out of sync** (some files couldn't be synced: see **Details**). Under the name: where it is, how many files and how big, and the last file that changed. **Rescan all** looks for changes in every folder now (Syncthing also does that by itself every hour, and sooner for changes made on the Kindle).
- **DEVICES**: your other devices: **Connected** (with how much of what you share it has, such as "Connected · 100%"), **Paused**, or when it was last seen.
- **At the bottom**: **This Kindle's ID**, and when the status was last read. A long list turns pages: swipe, or tap the arrows at the bottom.

When Syncthing is off, the folders and devices still show, so you can see what will sync.

### Tapping a folder

![A folder's menu](img/syncthing/folder.png)

- **Rescan**: look for changes in this folder now.
- **Pause** / **Resume**: stop syncing this folder for now.
- **Open in Library**: the folder in KOReader's file browser.
- **Details**: where it is, its files and size on the Kindle and in all, errors, when it was last scanned, the devices it's shared with, and its folder ID.

### Tapping a device

- **Pause** / **Resume**: stop syncing with this device for now.
- **Details**: its device ID, its address and Syncthing version while connected, what it still needs, and when it was last seen.

### This Kindle's ID

![This Kindle's ID](img/syncthing/id.png)

The QR code and the full ID, to add the Kindle from Syncthing on another device. Tap anywhere to close it.

## The menu

![The menu](img/syncthing/menu.png)

- **Start with Wi-Fi**: when on, Syncthing starts by itself whenever the Kindle's Wi-Fi connects, and stops before Wi-Fi goes off. If you turn Syncthing off by hand, it stays off until Wi-Fi connects again.
- **This Kindle's ID**: as at the bottom of the screen.
- **Web GUI**: the address of Syncthing's own web page (such as `192.168.1.42:8384`), for settings that aren't in the app: folder types (Send Only, Receive Only), ignore patterns, versioning, ignored devices and folders, and more. Open it in a browser on the same Wi-Fi. The user name is `syncthing`; set a password first.
- **Web GUI password**: sets that password (Syncthing must be on).
- **Port**: the web GUI's port, 8384 unless something else uses it. Change it while Syncthing is off.
- **Help**: a short version of the setup above.

## On the web page

The web page (see the Web server chapter) has a **Syncthing** tab with the same things, handy with a keyboard:

- **Turn on** / **Turn off**, **Rescan all**, and **Start with Wi-Fi**.
- **This Kindle's ID** with **Copy**, to paste into Syncthing on your computer.
- **Requests** with **Accept** (a name for a device; for a folder, where it goes on the Kindle) and **Ignore**.
- **Folders** with their state and a progress bar while syncing, **Rescan** and **Pause** / **Resume**.
- **Devices** with their state and **Pause** / **Resume**.
- A link to Syncthing's own web page.

While Syncthing is on, the tab updates itself every 5 seconds.

## Good to know

- **Nothing syncs while the Kindle sleeps**: Wi-Fi is off then. Leave the Kindle awake (on the launcher or in a book) with Wi-Fi on while a big folder syncs.
- **Battery**: Syncthing uses some battery while it runs. **Start with Wi-Fi** keeps it off whenever Wi-Fi is off.
- **Leaving KOReader** doesn't stop Syncthing. Turn it off first if you don't want it running behind the Kindle's own home screen.
- **Same Wi-Fi**: the Kindle finds your devices on the same Wi-Fi by itself. Elsewhere it can still connect through Syncthing's relays, more slowly.
- **Files open in KOReader**: if a book changes on the computer while it is open on the Kindle, close and open it again to see the new version.
- This Syncthing app took the place of the earlier Syncthing plugin: the Kindle kept its device ID, its folders and its devices.
