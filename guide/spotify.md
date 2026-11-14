# Spotify Remote

Spotify Remote is a remote control for Spotify on the Kindle: it shows what's playing and lets you play and pause, skip, set the volume, pick the device, and start a playlist, a recent song or something you search for. The music plays on a Spotify device (a phone, a computer, a speaker). Nothing plays on the Kindle.

It talks to Spotify's Web API. It isn't made by or endorsed by Spotify.

## Installing it

Spotify Remote is an optional app: it isn't in the main install. To add it:

1. Open the launcher's **⋮ > Settings > Updates** and tap the **Optional apps** row (the web page's **System > Updates** has the same list).
2. Tap **Install** next to **Spotify Remote**. KOReader restarts.

Once it is installed, it is updated with every new version of the primary apps. **Remove** in the same list takes it off again.

By hand: copy `kindle-spotify.zip` (from the release) to the Kindle, unzip it into `koreader/plugins/` and restart KOReader.

## Requirements

- **Spotify Premium.** Spotify lets only Premium accounts control playback this way.
- **An app of your own in Spotify's developer dashboard** (developer.spotify.com, free, signed in with your Spotify account):
  1. **Create app**. Any name and description will do.
  2. Under **Redirect URIs**, add `http://127.0.0.1:8888/callback`.
  3. Tick **Web API** and save.
  4. Copy the app's **Client ID**.
- **A phone or computer** to sign in on, once.

Spotify keeps an app like this in development mode: the account that made it needs Premium, and up to 5 Spotify accounts can use it. To let another account use it, add that account under the app's **User Management**.

## Opening it

- The **Spotify Remote** tile on the launcher. While a song plays and the app was open lately, its line shows it: **Morning Song · The Examples**.
- Quick buttons on the launcher (add them in **Settings > Launcher > Quick buttons > Add a button > Spotify Remote…**, or on the web page's Launcher tab): **Play or pause**, **Previous** and **Next**. A hold opens Spotify Remote.
- **Tools** in KOReader's menu > **Spotify Remote**.
- A gesture: **Settings > Taps and gestures > Gesture manager**, pick a gesture, then **General > Spotify Remote**, **Spotify Remote: play or pause**, **Spotify Remote: next** or **Spotify Remote: previous**.
- The launcher's **recent apps** and its **search**, which finds your playlists.

The title bar is the same as in the other apps: **‹** goes back, the house goes to the launcher, the clock with an arrow shows the recent apps; at the right are the time and battery, **⟳** (reads Spotify again), the bell and **⋮**. A swipe in from the left edge goes back.

## Setting it up

Spotify's sign-in needs a browser, so it is done on a phone or computer. The easiest way is the Kindle's web page (see the Web server chapter):

1. Open its **Spotify Remote** tab, paste the **Client ID** and click **Save**.
2. Click **Sign in**. Spotify's page opens in a new tab: sign in and agree.
3. The browser then shows an error for an address that starts with `http://127.0.0.1:8888`. That's expected: nothing is at that address. Copy the whole address from the address bar.
4. Back on the Spotify Remote tab, paste it and click **Finish**.

On the Kindle itself, the first time the screen says **Spotify Remote isn't set up yet.**

1. Tap **Set up**, type the **Client ID** and tap **Next**.
2. Tap **QR code** and scan it with a phone. Sign in to Spotify and agree.
3. The phone's browser shows an error for an address that starts with `http://127.0.0.1:8888`. Copy that whole address.
4. On the Kindle, tap **Enter address** and put it in. The address is long: pasting it on the web page is easier.

If it doesn't work, the message says why: the address is from another sign-in, the code has been used or is too old (start again: a code works once, for a few minutes), or Spotify doesn't know the Client ID.

The launcher's **Set up your Kindle** has the same step. It can be skipped and done any time later from the app.

## The app

- **At the top**: tap the album's picture for the full screen (see below), or the song for what can be done with it (see "A song's menu"). The card shows the album's picture, the song, its artist and album, and a bar showing how far the song is, with the time played and its length. Tap along the bar to jump to that part. **Paused** shows before the time while it's paused.
- **The buttons**: **Shuffle**, **Previous**, **Play** or **Pause**, **Next**, and repeat, which goes from **Repeat off** to **Repeat all** to **Repeat one**. Shuffle and repeat have a thick border while they're on. A button is greyed out when Spotify doesn't allow it right now.
- **The volume**: **−** and **+**, and a bar to tap along. It is greyed out for a device that only sets its own volume.
- **Like**, **Add to playlist** and **Queue**, for the song that's playing. **Like** saves it to Liked Songs and then reads **Liked**; tap it again to take it out. **Add to playlist** lists your own playlists; **Undo** at the bottom of the screen takes the song out again. **Queue** shows what comes next.
- **PLAYING ON**: the device the music plays on. Tap it for **Devices**.
- **PLAY**: **Playlists**, **Library**, **Recent**, **Search** and **DJ**.
- **At the bottom**: when Spotify was last read (**Updated 14:02**).

When nothing is playing anywhere, the screen says **Nothing playing**. **Play** then goes on with what you played last, on the device used last. If several devices are on and none was used from the Kindle before, it asks which (**Play on**).

While Spotify Remote is open, Spotify is read every 10 seconds (change it in Settings), and once more just after a song ends. Nothing is read once it closes, and nothing runs in the background.

### Full screen

Tap the album's picture (or **⋮ > Full screen**) for a page with the picture large, the song, the same buttons and the volume. Tap the picture or **‹** to go back. It is read as often as **Settings > Full screen: read every** says: the same as the rest of the app to start with, or its own number of seconds.

### A song's menu

Tap the song on the first page, or hold a song in any list:

- **Play** and **Add to queue** (for a song in a list).
- **Like**, or **Remove from Liked Songs** for the one playing when it's liked.
- **Add to playlist**.
- **Remove from this playlist**, for the song playing from a playlist of your own. **Undo** puts it back, at the end.
- **Open album** and **Open artist**.

### Devices

The Spotify devices that are on: the one playing first, marked **Active**. Tap another to move the music there. While nothing is playing, a tap doesn't start the music: it makes that device the one **Play** starts on. A greyed-out device marked **Unavailable** can't be controlled from here (Spotify says so for some speakers and TVs).

**SEEN BEFORE** lists devices that were on earlier and aren't now. Spotify only lists a device while it's connected, so a speaker that has been idle drops off the list, even though Spotify's own app still shows it. Tap one to try it anyway; if Spotify can't reach it, the message says **That device is no longer on.** Hold one to forget it.

If the list is empty, open Spotify on a phone, computer or speaker, then tap **⟳**.

### Playlists, Recent and Search

- **Playlists**: your playlists. Tap one to open it: **Play**, and its songs when the playlist is yours (Spotify lists no one else's). Hold a song there for **Move up**, **Move down**, **Move to top**, **Move to bottom** and **Remove from this playlist**, along with the rest of a song's menu. Hold a playlist for **Play** and **Open playlist**.
- **Recent**: songs played lately. Tap one to play it, in the album or playlist it was played from.
- **Library**: **Liked Songs** (the newest 100), your **PLAYLISTS**, your saved **ALBUMS** and the **ARTISTS** you follow. **All**, **Playlists**, **Albums** and **Artists** at the top show one kind only. An album opens its page: **Play**, its artist, **Add to queue** and **Add to playlist** for the whole album, and its songs. An artist opens theirs: **Play**, and their albums. Hold an album or an artist for **Play**, **Open album**, **Open artist** and, for an album, **Add to queue**, **Add to playlist** and **Add to library**.
- **Search**: type a song, album, playlist or artist. The results are in groups: **SONGS**, **ALBUMS**, **PLAYLISTS** and **ARTISTS**. Tap a song or a playlist to play it; an album or an artist opens its page. The magnifying glass in the title bar searches again.
- **DJ**: starts Spotify's DJ, where your account and the device have it. On some devices it plays songs without the DJ's voice.

**Several songs at once**: in Recent, Liked Songs, an album's page and a playlist of yours, tap the list with ticks in the title bar. Tap songs to select them, or use **Select all**, **Select none** and **Invert selection**; then **Add to queue**, **Add to playlist** or **Like**. **Done** leaves it.

Starting something from one of these pages leaves the page open. Its title bar has two buttons, so the music can be handled without going back:

- **Play or pause**. Tap it to show the player's buttons above the list: the song (tap it for its menu), **Previous**, **Play** or **Pause**, **Next**, **Like** and **Add to playlist**. They stay as you go from list to list; tap it again, or tap **Hide**, to put them away. **⋮ > Show player controls** does the same. Hold it to play or pause.
- **The music note** goes back to the first page. Hold it for the full screen.

## The menu

The **⋮** menu has:

- **Full screen**, **Devices**, **Queue**, **Library** and **Search**.
- **Help**: the requirements, Spotify's limits, and a short version of this chapter. The web page's tab has the same **Requirements**.
- **Recent apps**, **Light**, **Night mode** and **Refresh screen**, as in the other apps.
- **Settings**, always last.

## Settings

The same page opens from the launcher's **Settings** list, under **Optional apps > Spotify Remote**.

- **DISPLAY**
  - **Album art**: the album's picture on the first page. Each picture is fetched once (about 20 KB) and the newest 20 are kept.
  - **Read every**: how often Spotify is read while the app is open, from 5 seconds to 1 minute.
  - **Full screen: read every**: **Same as the app**, or its own time from 5 seconds to 1 minute.
- **BUTTONS**: what a tap and a hold do, each picked from **Play or pause**, **Show player controls**, **Go to the player**, **Full screen**, **Next**, **Previous**, **Queue**, **Song menu** and **Nothing**:
  - **Play or pause: tap** and **hold**, and **Music note: tap** and **hold**: the two buttons in a list's title bar.
  - **Album art: tap** and **hold**: the picture on the first page.
  - **Stay on the list after Play**: on to start with. Off: starting something goes back to the first page.
- **PLAYBACK**
  - **Volume step**: how much **−** and **+** change the volume: 2%, 5% or 10%.
- **ACCOUNT**
  - **Client ID**: shows only its end. Changing it signs you out.
  - **Redirect URI**: the address to give your app in Spotify's dashboard.
  - **Sign in**, or once signed in:
  - **Test connection**: checks the sign-in and that Spotify answers.
  - **Sign out**: takes the sign-in off the Kindle. **Undo** at the bottom of the screen takes it back for a few seconds.

The web page's backup (**System**) includes these settings; the sign-in only if you tick **Include keys and sign-ins**.

## On the web page

The web page (see the Web server chapter) has a **Spotify Remote** tab:

- What's playing, with the album's picture, a bar to drag, the same five buttons and the volume.
- **Like**, **Add to playlist**, **Open album**, **Open artist** and, for a playlist of your own, **Remove from this playlist**.
- **Devices**, each with **Play here**, and **Refresh**.
- **Queue** and **Library** (**Show** reads them): Liked Songs, your albums and artists, each with **Open** and **Play**.
- **Play**: a search box, **Your playlists** and **Recent**, each with **Play** (songs also **Add to queue**).
- **Settings**: **Album art**, **Read every**, **Volume step**, the **Client ID**, **Sign in** or **Sign out**, and **Test connection**.

While this tab is open, the Kindle reads Spotify as often as **Read every** says, even with the app closed on the Kindle. Close the tab and it stops.

## Good to know

- **The sign-in stays on the Kindle** and is only sent to Spotify. There is no password on the Kindle: Spotify gives it a key that you can take back any time under **Apps** in your Spotify account.
- **Spotify Premium is needed to control playback.** shows when the account isn't Premium.
- **This Spotify account isn't on your app's user list.** means the account that signed in isn't the one that made the app in the dashboard: add it under the app's **User Management**.
- **No Spotify device is on.** Open Spotify on a phone, computer or speaker. A device shows up a few seconds after Spotify opens on it, and some speakers drop off the list when they've been idle for a while.
- **Sign in to Spotify again.** The sign-in is no longer good (you took it back, or it wasn't used for a long time). A notification says so until you sign in.
- **Sign in again**, on the first page: the sign-in was made before Like, Library and adding to playlists were there, and doesn't cover them. Signing in once more does.
- **You can only change your own playlists.** Songs can be added to playlists you made, or ones marked collaborative.
- Hiding a song or saying you don't like it can't be done from here: Spotify doesn't offer it to remotes.
- **Spotify doesn't allow that right now.** Some things can't be done at times: skipping during an advertisement, or Previous on the first song.
- What the Kindle shows can be a few seconds behind: it's read every 10 seconds, not all the time, to go easy on the battery and the Wi-Fi.
- Nothing is read while the Kindle sleeps or Spotify Remote is closed.
