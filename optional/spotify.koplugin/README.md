# Spotify Remote for KOReader

A remote control for [Spotify](https://www.spotify.com) on a Kindle, over Spotify's Web API. The music plays on a Spotify Connect device (a phone, a computer, a speaker); nothing plays on the Kindle. Unofficial: not affiliated with or endorsed by Spotify.

- **What's playing**: the song, its artist and album, the album's picture, and how far it is. Tap along the bar to jump.
- **The remote**: Shuffle, Previous, Play or Pause, Next, Repeat (off, all, one), and the volume.
- **The song**: Like, Add to playlist (your own playlists, with Undo), Remove from this playlist, Open album, Open artist: tap the song, or hold one in a list.
- **Full screen**: the album's picture large with the same buttons; its own refresh time, or the app's.
- **Queue**: what comes next.
- **Library**: Liked Songs, your saved albums and followed artists; album and artist pages. Select several songs to queue, add to a playlist or like at once.
- **Devices**: the devices that are on, the active one marked, the ones that take no commands greyed out. Tap one to move the music there. With nothing playing, Play starts on the device used last; with several on and none used before, it asks which.
- **Playlists, Recent, Search**: start a playlist, a recently played song, or a song, album, playlist or artist you search for. Hold a song to add it to the queue.
- **With the launcher**: its tile (`ShowSpotify`, line "Song · Artist" while it plays), Settings, search (your playlists), a step in Set up your Kindle, quick buttons (Play or pause, Previous, Next), Test connection, the backup (the sign-in only with Include keys and sign-ins), and a Spotify Remote tab on the web page.
- **Gestures**: **Spotify Remote** (opens it), **Spotify Remote: play or pause**, **Spotify Remote: next**, **Spotify Remote: previous**.

Spotify is read only while the app is open (every 10 seconds; Settings > Read every; and when a song ends). Nothing is read once it closes, and nothing runs in the background.

## Requirements

- **Spotify Premium.** Spotify's API controls playback only for Premium accounts.
- **An app of your own in [Spotify's developer dashboard](https://developer.spotify.com/dashboard)** (free). Create an app, give it the redirect URI `http://127.0.0.1:8888/callback`, tick **Web API**, and copy its **Client ID**. Spotify keeps such an app in development mode: its owner needs Premium, and up to 5 Spotify accounts can use it, each added under the app's **User Management**.
- **A phone or computer** to sign in on once.

## Setting up

1. On the Kindle's web page, open the **Spotify Remote** tab, paste the Client ID and **Save**.
2. **Sign in**. Spotify's page opens; sign in and agree.
3. The browser then shows an error for an address starting with `http://127.0.0.1:8888`. That's expected: nothing is at that address. Copy the whole address, paste it on the Spotify Remote tab and **Finish**.

It can be done on the Kindle too (**Set up**): type the Client ID, scan the QR code with a phone to sign in, and enter the address the phone ends on.

The sign-in is Authorization Code with PKCE: there's no client secret, and the tokens stay on the Kindle (`koreader/settings/spotify_tokens.lua`), sent only to Spotify.

## Install

An optional app: it isn't in the main install zip. Settings > Updates > **Optional apps** on the Kindle, or unzip `kindle-spotify.zip` (from a release) into `koreader/plugins/` and restart KOReader. It works without the launcher, with KOReader's own dialogs.

Icons: [Lucide](https://lucide.dev) (ISC).
