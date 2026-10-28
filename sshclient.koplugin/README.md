# SSH for KOReader

Connect from a Kindle to your other devices (PCs, a NAS, a Raspberry Pi) and run commands, with KOReader's own SSH client (`dbclient`, Dropbear's, which ships with KOReader for Kindle and Kobo).

- **Hosts**: name, address, user, port; sign in with a key, a saved password, or a password asked each time. Add, edit, copy, reorder, delete (long-press).
- **Keys**: create an Ed25519 key on the Kindle (KOReader's libcrypto), or import one (OpenSSH or Dropbear format: Ed25519, RSA, ECDSA, without a passphrase); show and copy the public key for `authorized_keys`.
- **Host keys**: the first connection shows the fingerprint and asks **Trust this host?**; a changed key is refused with **Trust new key** to accept it.
- **Run a command**: runs in a child process (KOReader stays responsive; Stop; 5-minute limit), output in a monospace page without colour codes, with Copy all, Run again, Find, and long-press to copy a word or a part.
- **Saved commands** per host (one tap), **recent commands** (last 10), and a **command list** for any host with 50+ built-in commands (any Linux, Docker, ZFS, Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine, Flatpak, Snap, Raspberry Pi, Windows, macOS). **Commands** pastes one (or the clipboard) into the command box or a live session. Long-press: Run, Edit and run, Edit, Copy, Copy to a host, Copy text, Move, Delete.
- **A host's page** (`sshscreens.lua`, on `sshpage.lua`, drawn as the other apps): Status tiles (uptime, temperature, CPU, memory, disk, IP and more, per host, per system: sh for Linux, macOS and FreeBSD/pfSense, PowerShell for Windows; `sshstats.lua`), Run a command, Live session, Write with AI, Quick commands per system (update, upgrade, clean up, disk, reboot…; your own with an icon), Docker (containers, start/stop/logs, pull, up, clean up), Services (systemd), Saved commands, Recent, Files (browse, edit in the Kindle's text editor with sudo save, read, copy to the Kindle), Stats and alerts.
- **Custom sensors** (a command and what it gives: a number, a percent, text, OK or failing), **alerts** (disk, memory, CPU, temperature, failed services, stopped containers) and **custom alerts** (any stat: above, below, is, isn't, contains), as notifications (`PS.notify`).
- **Checks** (`sshnet.lua`): each host's status every few minutes (all hosts, or per host), only on Wi-Fi already and only for hosts that ask nothing; the online dot (a TCP connection to its port); **Wake on LAN**.
- **The SSH page**: hosts with their online dot and two stats, groups (chips), History (searchable, every host), SSH settings.
- **Commands with blanks** (`{service}`, `{container}`), filled from the host.
- **Live session**: dbclient in a pseudo-terminal, shown with KOReader's terminal text widget (from its Terminal plugin: VT52 and some VT100), with the shared bar, Tab, Esc, Ctrl, Ctrl-C, ⇧ ⇩, Keys (named keys and combinations, nano's and vi's too), Commands, Edit (a file in the Kindle's editor), and hold-and-drag to select and copy.
- **Run on several hosts**: one command on the ticked hosts at once, one page with each host's part.
- **AI help** (with the launcher's AI, Settings > AI): a chat in the live session that sees what the terminal shows (Ask, typed or handwritten; Ask AI on a selected part of the terminal; Run after a confirm, or Paste on the prompt line without Enter), Explain and Summarize output, Write a command for the host's system, Ask more. Suggested commands have Run (asks first, with a warning; in the live session it came from, or a live session or once from elsewhere), Edit and Save; secrets are blanked before sending (`M.redact`). SSH's job can use any AI service, local or public.
- **Systems**: each host's system (Debian/Ubuntu, Raspberry Pi OS, Fedora/RHEL, Arch, openSUSE, Alpine, other Linux, Windows, macOS, FreeBSD, pfSense, TrueNAS, TrueNAS CORE, Proxmox VE, ReadyNAS OS), set by hand or detected on the first connection (`/etc/os-release`, `/etc/platform`, `uname`, `ver`). Each command has a system too (or any Linux, or any system); **Show** filters the lists by the host's system, All, Custom (not built in) or a system.
- **The shared title bar** (as the other apps, drawn by a copy of apps.koplugin's appsbar/appscanvas): ‹ Back (the top page: to the launcher), ⌂ Home, the title, the clock and battery, ⟳, 🔔 Notifications, ⋮ (SSH's pages, Recent apps, Light, Night mode, Refresh screen). A full refresh when a dialog over a page closes (`flash_on_uncover`). A swipe right from the left edge goes back (`KO.fromLeftEdge`); other swipes turn pages. Deleting a host, command or key has Undo (`PS.popup.undo`; without Apps it asks first). The clock ticks once a minute only while its page is on top.
- **Dark terminal**: the live session's moon/sun key turns live sessions and command output white on black (KOReader's night mode while they're open; the lists keep the normal look). It's remembered. **SSH settings** (⋮, or the launcher's Settings > SSH): Check hosts, Stats under each host, Dark terminal, AI settings.
- **With Apps** (all through PluginShare, each call checked): hosts and saved commands in its search (`PS.registerSearch`), recent apps (`PS.noteRecent("ssh")`, the top page as `plugin.screen`), Recent apps in ⋮ and the control center from the clock (the shared bar), and the apps' pop-ups (`KO.list/choose/confirm/toast`, `PS.popup` when Apps is there, KOReader's own otherwise).
- **Notifications**: a command that took a minute or more ("Command finished on NAS: …"); tapping it shows the output (after a restart, the host's page).
- **Launcher**: event `ShowSSH` opens it; `ui.sshclient:appsLine()` gives "3 hosts". Icon: `terminal`. Quick buttons: a saved command, or a host's Status.
- **Gestures**: **SSH** (opens it) and **SSH: run a saved command** (a choice of every host's saved commands).
- **Web page**: an SSH tab (`webssh.lua`, `web/ssh.js`, here; the web server loads them) calls `ui.sshclient:webState()` and `ui.sshclient:act(name, args)`: hosts with passwords (never sent back), each host's commands, the command list, key upload, paste and creation, AI help (`aiStart` / `aiResult`) and Import ~/.ssh/config (`importConfig`).

## Install

Copy this folder to `koreader/plugins/sshclient.koplugin` and restart KOReader. **Not** `ssh.koplugin`: KOReader already has `SSH.koplugin` (its SSH server), and on the Kindle's storage the two names are the same folder.

Everything it keeps is in `koreader/settings`: `sshclient.json` (hosts, commands, the key list), `sshclient_passwords.json` (saved passwords), and in `sshclient/`: `keys/` (private keys in Dropbear's format, and `.pub` files) and `.ssh/known_hosts` (dbclient runs with HOME there). None of it is in the plugin folder. The web page's backup has the hosts, commands and trusted host keys; passwords and private keys only with Include keys and sign-ins.

## How it runs

Every connection is `dbclient` in BatchMode, so it never waits for typing: a password goes in `DROPBEAR_PASSWORD` (not on the command line), a key with `-i`. Before the first connection to a host, a probe (`-o PasswordAuthentication=no`, no key) reads the host key; **Trust** runs it once more with `-y`, which saves it, and checks the saved fingerprint is the one shown. dbclient's own messages are read to tell "can't sign in", "can't connect" and "the host key changed" from the command's output. Output goes to a file in `cache/sshclient`, so a stopped command still shows what it printed (the last 200 KB).

## User guide

`docs/guide-ssh.md` is this plugin's chapter of the Kindle apps guide (built by `apps.koplugin/docs/guide/build.py`); its screenshots are in `docs/img`, from the KOReader emulator.

## Development

```bash
luajit tests/run.lua
```

`main.lua` (the plugin: menu, gestures, launcher line, web page calls, the notifications opener), `sshui.lua` (the screens: KOReader's lists and dialogs), `sshbar.lua` (the shared title bar on them; `sshtitle.lua` and `sshcanvas.lua` are copies of apps.koplugin's appsbar.lua and appscanvas.lua), `sshko.lua` (the ⋮ menu, the refresh hook), `sshrun.lua` (connecting: Wi-Fi, passwords, trusting hosts, running commands, the output page), `sshsession.lua` (live sessions), `sshbg.lua` (child processes), `sshstore.lua` (files, dbclient, key generation), `sshdark.lua` (the dark terminal), and the plain-Lua, tested parts: `sshmodel.lua` (data, the built-in commands, systems and filters, dbclient's command line and messages, known_hosts, colour codes, the web page's changes) and `sshkeys.lua` (base64, OpenSSH and Dropbear key formats, public key lines).

In the KOReader emulator on a PC, a `dbclient` in PATH or in KOReader's folder is used (for example Debian's `dropbear-bin`).

Licence: AGPL-3.0 (see COPYING). The live session follows KOReader's Terminal plugin (AGPL-3.0) and uses its terminal text widget.
