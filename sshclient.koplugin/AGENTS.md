# AGENTS.md: SSH (sshclient.koplugin)

Notes for AI coding agents working on this plugin. The shared parts of the
apps (title bar, pop-ups, notifications, launcher, guide) are described in the
top-level AGENTS.md of the apps; this file covers only SSH.

## What it is

An SSH client for KOReader on a Kindle: saved hosts (key or password), a host
key trusted the first time, commands run in the background with their output,
saved and built-in commands to run or paste, a live session, and one command
on several hosts. It uses KOReader's own `dbclient` (Dropbear's client, which
ships with KOReader for Kindle as `koreader/dbclient`).

It installs as **`sshclient.koplugin`**, never `ssh.koplugin`: KOReader ships
`SSH.koplugin` (its SSH server), and the Kindle's storage is case-insensitive,
so the two would be one folder. For the same reason its data lives in
`settings/sshclient`, not `settings/ssh`. The plugin's `name` is `sshclient`
(`ui.sshclient`).

## Design (every screen)

SSH looks and behaves like the other apps (To Do, Home Assistant, Notes). The
user asked for this to hold everywhere, so check every new screen against it:

- **The apps' title bar on every full screen**: ‹ Back, ⌂ Home, recent apps,
  the title, the clock and battery (▾), ⟳, 🔔 and ⋮ (`sshtitle.lua`, a copy
  of the launcher's appsbar). SSH's pages (`sshpage.lua`), the output page
  (`sshoutput.lua`) and the AI chat draw it themselves; KOReader's own
  full-screen dialogs (the live session, the text editor) get it in place of
  their title with `Bar.swapInto` / `Bar.dialogClass()` (`sshbar.lua`), which
  dresses them again each time KOReader lays them out anew (the keyboard
  shown or hidden). No screen keeps KOReader's plain title.
- **Pages drawn as the other apps'** (`sshpage` items): grey capital
  headings (bands), rows with an icon and a grey second line, settings rows
  with a value and › or a switch, tiles, stat tiles, quick buttons, filter
  chips, notes; pages turn with swipes or ‹ n/m › in the bar; a status line
  can end the page. Not KOReader's Menu.
- **Buttons**: the launcher's icon row (`PS.popup.iconButtons`, through
  `sshbuttons.lua`; its copy only without the launcher): an icon over a
  short label, as wide as one of five, lined up on the right, the main one
  black and last. Labels say what happens; the same action has the same icon
  in every app. KOReader's text buttons only without the launcher, in rows
  of the same count.
- **Boxes**: text boxes are `PS.popup.request` (a pen for handwriting
  where words or commands go; numbers and passwords too), pages to read are
  `PS.popup.read`; KOReader's dialogs only without the launcher.
- **Text can be copied and pasted** wherever it's typed or read: the request
  boxes' hold menu (Paste, Copy all, Clear), the editor's (KOReader's: Copy,
  Select, Paste), the terminal's hold-and-drag (`Session:selectable`), the
  output page's long-press.
- **A mockup first** for any visible change (at the Kindle's real
  proportions), and build what the user picked.

## Files

- `main.lua`: the plugin. Menu entry, gestures (`sshclient_show`, and
  `sshclient_run` with the argument `"<host id>/<command id>"`, event
  `RunSSHCommand`), the launcher's event `ShowSSH` and line `appsLine()`
  ("3 hosts"), the web page calls `webState()` and `act(name, args)`, search,
  and the notifications opener.
- `sshpage.lua`: SSH's full-screen page (the items are described in it); it
  keeps the calls Menu had (`switchItemTable`, `item_table`, `close_callback`).
- `sshui.lua`: the dialogs and the older screens (Keys, Command list, Edit
  host, Run on several hosts, the command picker) on sshpage, long-press
  menus, Undo, filters, editing hosts, commands and keys. `UI.h` hands its
  helpers to sshscreens.
- `sshscreens.lua`: the SSH page and a host's page (Status, Quick commands,
  Docker, Services, Saved commands, Recent, Files), Stats and alerts (custom
  sensors and custom alerts), Quick commands, Docker, Services, Files (and the
  text editor: `Screens.editFile` / `writeFile`, sudo through `sudo -S`),
  History, SSH settings, commands with blanks (`fillBlanks`).
- `sshstats.lua`: plain Lua, tested: each system's stats command (sh for
  Linux and macOS, `sh -c` for FreeBSD and pfSense, encoded PowerShell for
  Windows), reading its `key=value`
  answer, tiles and the short line, alerts and custom alerts, custom sensors,
  quick commands per system, Docker's and services' commands, blanks,
  `~/.ssh/config`, Wake on LAN's packet, a folder's listing.
- `sshnet.lua`: what runs quietly in the background (only hosts that need
  nothing asked: `Net.quiet`): a host's status and its alerts, the online
  check (a TCP connection to the SSH port), Wake on LAN, the checks every
  few minutes (`Net.start`, on Wi-Fi already, never turning it on).
- `sshrun.lua`: connecting (Wi-Fi, password, trusting a host, detecting its
  system), running commands, the output page, several hosts at once.
- `sshsession.lua`: the live session (a pty running dbclient).
- `sshbg.lua`: a job in a child process with a Stop box.
- `sshstore.lua`: files on the Kindle, finding dbclient, making an Ed25519 key.
- `sshdark.lua`: the dark terminal (white on black for sessions and output only).
- `sshai.lua`: AI help with the launcher's AI (`PS.ai`): Explain / Summarize
  output (the output page), Write a command (a host's page), Ask more, and the
  answer page (Run asks first with `A.RISK`, Edit, Save; the buttons in rows of
  four that line up). Run offers Run in a live session (`UI.session(plugin, host,
  cmd)`: opens one or reuses the open one, the command typed once the device
  answers) or Run once (sudo first: live session). A one-off run that sudo
  stopped (`M.sudoNeedsPassword`) offers the live session. Registers job `ssh` (no `only`: any
  service, local or public) and features `ssh_explain`, `ssh_summary`,
  `ssh_write`, `ssh_session`. Hidden without an AI (`A.available()`).
- `sshaichat.lua`: the live session's AI chat (its AI key): a page of its own,
  the session's last lines in a strip at the top (`stripChanged`, from
  `Session:refresh`, at most once a second), then the conversation. Each
  question sends `M.aiSessionText` (the terminal's last part, the turns so
  far, the question; redacted). Questions from Ask (`PS.popup.request`, with
  the pen when `PS.handwriting` is there; KOReader's InputDialog otherwise),
  from holding the AI key (the box from the terminal), and from Ask AI on a
  selection (`Session:selectable`: hold or hold-and-drag with KOReader's highlight, since the terminal takes no taps for its own Select; copied at once; the part
  goes first, with the terminal's last 20 lines). Commands: Run (confirm with
  `A.RISK`, then `Session:typeLine`, with Enter), Paste
  (`Session:transmit(cmd)`, without Enter), Edit (then Run or Paste), Save. Its foot is `sshbuttons.lua`.
  One chat per session (`Session.chat`), ended with the session; nothing is
  stored.
- `sshbar.lua`: the shared title bar as a `custom_title_bar` for `Menu`.
- `sshko.lua`: the ⋮ menu, pop-up wrappers (`KO.list/choose/confirm/toast/
  message/wait/undo`), the left-edge swipe, the refresh-on-uncover hook, and
  `KO.request()` / `KO.read()` (the launcher's text box and read page, nil
  without it), `KO.pen()` (handwriting can be read), `KO.withWrite(row, …)`.
- Text boxes and pages: with the launcher, SSH's are its shared ones
  (`PS.popup.request` with icon buttons and, for commands, names and AI
  questions, the pen; `PS.popup.read` for the AI's answers, a key's page and
  a selection). KOReader's InputDialog / TextViewer only without it, and for
  numbers and passwords (the port, a password), in even rows with Write it
  where the pen would be. Add host is one box, `user@address[:port]`
  (`M.parseTarget`).
- `sshbuttons.lua`: the foot of SSH's own full pages (‹ n/m › and a row of
  icon buttons: as wide as one of five, on the right, the main one last). With
  the launcher it is `PS.popup.iconButtons` on the launcher's `appscanvas`;
  the copy of it here is only the fallback without the launcher.
- `sshoutput.lua`: the output page with the launcher (monospace
  ScrollTextWidget in pages, long-press copy, Find, the foot); KOReader's
  TextViewer without it (`Run.show`).
- `sshtitle.lua`, `sshcanvas.lua`: **copies** of the launcher's `appsbar.lua` and
  `appscanvas.lua`. Re-copy them when those change; don't edit them here.
- Plain Lua, tested: `sshmodel.lua` (data, built-in commands, systems and
  filters, dbclient's command line and messages, known_hosts, colour codes, the
  web page's changes; for the AI: `M.redact` (secrets blanked), `M.aiPart`,
  `M.aiOutputText`, `M.aiFollowUp`, `M.aiCommands` (COMMAND: lines)) and `sshkeys.lua` (base64, OpenSSH and Dropbear key
  formats, public key lines).
- The web page's SSH tab is here (`webssh.lua`, `web/ssh.js`, served by the web server as
  `PS.appInfo.sshclient.web` says) and only calls `webState()` / `act()`, and for AI help
  `aiStart(args)` / `aiResult(key)` (`plugin.lastOutput`: the last output page).

## Data on the Kindle

A host also keeps: `last = { at, v }` (its last status, sshstats' values),
`mac`, `groups`, `stats` (`[stat id] = true | false`, custom sensors as
`cs_<id>`), `sensors` (`{ id, name, cmd, kind, unit }`), `alerts`
(`[id] = limit | true`), `customAlerts` (`{ id, what, op, value }`),
`raised` (the alerts notified now), `quick` (ids, own ones as
`"cmd:<command>|<name>"`) and `quickIcons`, `compose` (Docker's compose
folder), `services` (pinned services), `check` (minutes; nil: every host's),
`readOnOpen`. The data: `history` (`{ host, cmd, at }`, newest first, 300),
`check_every` (minutes, 15 by default; 0: off), `main_stats`.

All in `koreader/settings/`, never in the plugin folder:

- `sshclient.json`: `hosts` (name, address, user, port, `auth` = key | password |
  ask, `key`, `password`, `os` = "auto" or a system id, `detected`, `commands`,
  `recent`), `commands` (the command list, each with an optional `os`), `keys`
  (id, name, type, public line), `nextId`, `builtInVersion`. Saved
  passwords aren't in it: they are in `sshclient_passwords.json`
  (`{ [host id] = password }`), joined on load, split on save
  (`M.splitPasswords` / `M.mergePasswords`). An older `sshclient/data.json`
  (all in one) is split once.
- `sshclient/keys/<id>` (private key, **Dropbear format**) and `keys/<id>.pub`.
- `sshclient/.ssh/known_hosts`: dbclient runs with `HOME` set to `sshclient/`.
- The web page's backup (`PS.backupApps.sshclient` in `main.lua`): `sshclient.json`,
  known_hosts and `sshclient_dark_mode`; passwords and `keys/` only with Include
  keys and sign-ins. Keep secrets out of `files`/`dirs` when adding files.
- Run output goes to `koreader/cache/sshclient/` (so a stopped run still shows
  what it printed; the last 200 KB).
- One KOReader setting: `sshclient_dark_mode` (the dark terminal).

## How it runs

- Every connection is dbclient with `-o BatchMode=yes` (it must never wait for
  typing) and `-T` for runs (`-t` only in the live session).
- A password goes in the `DROPBEAR_PASSWORD` environment variable, set in the
  child process; never put it on the command line.
- Runs happen in a child process (`ffiutil.runInSubProcess`); KOReader's loop
  only polls. Stop kills the child's process group, which also ends dbclient.
- First connection to a host: a probe with `-o PasswordAuthentication=no` and
  no key reads the host key; the user confirms the fingerprint; a second probe
  with `-y` saves it, and the saved fingerprint is checked against the one shown.
- dbclient's own messages are parsed (`M.parseRun`) to tell "unknown host",
  "host key changed", "can't sign in" and "can't connect" from the output.
- System detection runs once per host set to "auto", after trust:
  `M.DETECT_CMD` works in sh and in Windows cmd (`||`, no `;`).
- The live session forks, opens a pty, and execs dbclient with `TERM=vt52`. The
  screen is KOReader's Terminal plugin's `terminputtext.lua`, loaded with
  `dofile` (no Terminal plugin: no live session).

## Shared helpers

Helpers more than one app needs live in the launcher (apps.koplugin) and are reached through KOReader's PluginShare (`PS.ko`, `PS.ai`, `PS.microsoft`, `PS.registerTest`, `PS.backupApps`, `PS.statusIcons`…); see apps.koplugin/AGENTS.md. This plugin uses them when the launcher is there, and its own copies are only the fallback without it. A new helper goes into apps.koplugin, not here.

`sshko.lua` ends with a wrapper: `list`, `choose`, `confirm`, `toast`, `undo` and `fromLeftEdge` come from `PS.ko` when it's there, and `message` / `wait` go to `PS.ko`'s through small adapters (SSH calls them as `message(text, title, onOk)` and `wait(text, on_stop)`). The rest of `sshko.lua` is SSH's own.

## Shared pieces it uses

- The title bar (‹, ⌂, recent apps, clock and battery with ▾, ⟳, 🔔, ⋮). ⌂, 🔔
  and recent apps only when `PS.appsHome` / `PS.showNotifications` /
  `PS.showSwitcher` exist.
- Notifications: a command that ran a minute or more, key
  `"sshclient:done:<host id>"`, one per host; removed when that host's next
  output opens or the notification is opened. `PS.notifyOpeners.sshclient`
  opens the host's page.
- Search: `PS.registerSearch{ key = "sshclient" }`, from memory only.
- Quick buttons: `PS.registerQuick{ key = "sshclient" }`. The choices are every host's saved
  commands, id `"<host id>/<command id>"`, grouped by host. A tap runs the command as the app
  does (`Run.command`), a hold opens the host's page, and `item()` returns nil when it's gone.
- Recent apps: `PS.noteRecent("ssh")`; the top page is kept in `plugin.screen`.
- App lock: `PS.lock.ask("ssh", ...)` in `SSH:show` and the gesture's
  `onRunSSHCommand`. SSH's own app PIN (`data.app_pin`) is only the fallback without the launcher:
  with it, `UI.adoptAppPin` hands it over (SSH ticked when a passcode is set there; else the PIN
  becomes the passcode the first time it's typed). Hosts' own PINs stay SSH's (`M.needsPin`).
  ⋮ > Lock now locks both.
- Pop-ups through `sshko.lua`, which uses `PS.popup` and falls back to
  KOReader's widgets without the launcher.
- Undo after deleting a host, a command or a key (`PS.popup.undo`). Without it,
  a delete asks first.
- No settings page: the dark terminal is the live session's moon/sun key.
- AI buttons carry `aiJob` (a feature key: ssh_explain, ssh_summary,
  ssh_write, ssh_session): a hold opens `PS.ai.quickPick` (AI for this). The
  live session's AI key does it from its hold_callback.
- AI: `PS.ai` (the launcher's appsai). Everything sent goes through
  `M.redact` with the saved passwords first; nothing runs or is typed into a
  session without a tap, and Run asks first.

## Pitfalls (learned the hard way)

- dbclient can't read OpenSSH-format private keys. Imports are converted to
  Dropbear's format in `sshkeys.lua`; keys with a passphrase and old PEM keys
  are refused with a hint.
- There is no `dropbearkey`. New keys come from KOReader's LibreSSL
  (`ffi.loadlib("crypto", "57")`). Look Ed25519 up by its OID `1.3.101.112`:
  LibreSSL calls it "Ed25519", OpenSSL "ED25519".
- With a wrong password, dbclient retries ("Login for user@host" lines) until
  the server hangs up. That is parsed as "can't sign in", and those lines are
  dropped from the output.
- dbclient's known_hosts entries have no port, so two hosts at one address share
  an entry.
- Commands with `sudo` can't ask for a password in a run (no pty). That's
  expected: the guide says to use the live session for them.
- Full-screen programs (top, nano) don't draw in the live session. It's a
  simple VT52 terminal.
- KOReader's on-screen keyboard stays above other windows. Close it before
  showing a pop-up over the live session, or taps land on the keys underneath.
- KOReader's `Button` only finds icons by name in its own folders. The
  moon/sun key swaps the button's image file for the plugin's Lucide SVG.
- `Menu` calls `close_callback` after every tap; `List` overrides
  `onMenuSelect` so it only runs on close.
- Plugin methods whose names start with "on" are wrapped by KOReader (first
  return value only, errors swallowed). Use "on" only for event handlers.
- The built-in commands are matched by their command text (`M.isBuiltIn`).
  Changing a built-in's text turns users' old copies into custom ones. Add new
  built-ins with `since = <next version>` and raise `M.BUILTIN_VERSION`, so
  existing lists get them once.

Looks wrong, but is right:

- A swipe right on a list's first page does nothing (only the left-edge swipe
  is Back).
- The waiting box ignores a touch in its first second: it is the rest of the tap
  that opened it.
- `webState()` never returns passwords (only `hasPassword`).

## Testing

```sh
luajit tests/run.lua        # plain-Lua tests of sshmodel and sshkeys
```

KOReader's own `luajit` works too. In the KOReader emulator on a PC:

- The desktop build has no dbclient. Extract a distribution's `dropbear-bin`
  package (no root needed) and put a small wrapper script named `dbclient` in
  KOReader's folder or on PATH, setting `LD_LIBRARY_PATH` for its libraries.
- Run a local test SSH server on a high port, for example a small Python
  `asyncssh` server with a made-up user (`pi` / `test123`) and an
  `authorized_keys` file, and add hosts at `127.0.0.1:2299`.
- Use throwaway keys (`ssh-keygen -t ed25519 -N "" -f test_key`) to check
  imports. Never use or commit a real key.
- Give the emulator its own HOME, so its known_hosts and data don't mix with
  anyone else's.

## Rules

- Plain, standard wording; say "Kindle".
- Made-up data only in code, tests, docs and screenshots: example hosts
  ("Raspberry Pi", "NAS"), example addresses (`192.168.1.20`, `nas.local`,
  `127.0.0.1`), generated test keys.
- No real keys, passwords, hostnames, addresses or personal paths anywhere in
  the repo. Secrets stay on the Kindle in KOReader's settings folder.
- Keep the guide chapter `../guide/ssh.md` up to date with every visible change.
