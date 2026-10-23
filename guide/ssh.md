# SSH

SSH connects the Kindle to your other devices (a PC, a NAS, a Raspberry Pi) so you can run commands on them and read what they print. Save a device once, with a key or a password, then run a saved command with one tap, type your own, or open a live session.

It uses KOReader's own SSH program (`dbclient`, which comes with KOReader for Kindle). Everything is kept on the Kindle in KOReader's settings folder (`koreader/settings/sshclient`).

![SSH: the saved hosts](img/ssh/main.png)

## Opening it

- The **SSH** tile on the Apps launcher. Its line says how many hosts are saved.
- **Settings (gear) > Network > SSH** in KOReader's menu.
- A gesture: **Settings > Taps and gestures > Gesture manager**, pick a gesture, then **General > SSH** (opens it) or **SSH: run a saved command** (pick which; it runs straight away and shows the output).

The ✕ at the top right closes a page.

## Adding a host

1. Tap **Add host**.
2. Fill in **Name** (anything, for example "Raspberry Pi"), **Address** (its IP address or name, for example `192.168.1.20` or `nas.local`), **User** (your user name on that device) and **Port** (22 unless you changed it). Tap **Next**.
3. Choose how to sign in:
   - **Key**: a key on the Kindle (see Keys below). The safest choice, and you never type a password.
   - **Password**: saved on the Kindle, in KOReader's settings folder.
   - **Ask for password**: the Kindle asks every time you connect.

The device needs an SSH server: on Linux and a Raspberry Pi it is usually there (`sudo apt install openssh-server`); on Windows, add **OpenSSH Server** in **Settings > System > Optional features**; on a Mac, turn on **Remote Login** in **System Settings > General > Sharing**.

You can also add and edit hosts on the web page (see below), which is easier with a computer keyboard.

## Trusting a host

The first time the Kindle connects to a host, it shows the host's key fingerprint and asks **Trust this host?** Tap **Trust**. The Kindle remembers the key, and next time it connects without asking.

![Trust this host?](img/ssh/trust.png)

If a host's key changes later (it was reinstalled, or got a new address), the Kindle says **The host key of … has changed** and doesn't connect. If you know why it changed, tap **Trust new key**. If you don't, tap **Cancel**: someone could be pretending to be your device.

**Edit host > Forget host key** removes a saved key, so the Kindle asks again next time.

## A host's page

Tap a host to open its page.

![A host's page](img/ssh/host.png)

- **Run a command**: type a command and tap **Run**. **Commands** pastes one from your lists (see below), and **Save** keeps the command on this host for one-tap use.
- **Live session**: an interactive shell on the device (see below).
- The host's **saved commands**: tap one to run it.
- **Recent commands**: the last 10 commands you ran on this host. Tap to run again.
- **Add saved command** and **Edit host** (name, address, user, port, sign-in, password, **Forget host key**, **Delete host**).

## Running a command

While a command runs, the Kindle shows **Running on …**; tap the message to stop it. Commands stop by themselves after 5 minutes. The Kindle keeps working meanwhile: the connection runs in the background.

The output opens in a page with a monospace font. Colour codes are removed. If the command failed, the end says why: **Exit status 1**, **Can't sign in** (check the user name, password or key), or **Can't connect** (check the address, and that the device is on).

![The output of a command](img/ssh/output.png)

- **Copy all** copies the whole output to KOReader's clipboard.
- Long-press a word to copy it, or long-press and drag to copy a part.
- **Run again** runs the same command again.
- **Find** searches the output; **⇱** and **⇲** jump to the top and bottom.

Commands that use `sudo` usually ask for a password, which a command run this way can't answer. Use them in a live session, or set up passwordless sudo on the device.

## Commands

**Commands** in the command box (and in a live session) lists, in order:

![Commands to paste](img/ssh/commands.png)

- **Paste**: what's on KOReader's clipboard (from **Copy text**, **Copy all** or elsewhere in KOReader).
- This host's saved commands, then its recent commands.
- The **Command list**: commands for any host.

Tapping one pastes it where you type, so you can change it before you run it.

### The command list

**Command list** (on the SSH page) comes with over 50 built-in commands:

- **Any Linux**: Uptime, System info, Disk space, Memory, Top processes (CPU and memory), Largest folders here, Network addresses, Listening ports, Logged-in users, Temperature, Failed services, Service status, Restart a service, Recent errors, Restart, Shut down.
- **Docker** (containers, disk use, Compose status and update) and **ZFS** (pool status and space, for TrueNAS and others).
- **Debian/Ubuntu**, **Fedora/RHEL**, **Arch**, **openSUSE** and **Alpine**: updates, upgrade, clean up, and "restart needed?".
- **Flatpak** and **Snap** updates, **Raspberry Pi** temperature and throttling.
- **Windows** (system info, running programs, disk space, restart, shut down) and **macOS** (updates, battery).

Tap a command to edit it. **Add command** adds your own. **Restore built-in commands** puts back any built-in ones you deleted.

## Long-press menus

Long-press almost anything for more:

![Long-press on a command](img/ssh/hold-command.png)

- **A command** (in a host's saved commands, or in the command list): **Run** and **Edit and run** (opens it in the command box) on a host's command, **Run on a host** (choose the host; it opens in its command box) on the command list's, then **Edit**, **Copy** (a copy below it, to change first), **Copy to a host** (into a host's saved commands, to change first), **Copy text**, **Move up**, **Move down**, **Delete**.
- **A host** (on the SSH page): **Run a command**, **Live session**, **Edit host**, **Copy host** (a copy with its saved commands, opened to change), **Copy address**, **Move up**, **Move down**, **Delete host**.
- **A recent command**: **Run**, **Edit and run**, **Save as command**, **Copy text**, **Remove from recent**.
- **A key**: **Show public key**, **Copy public key**, **Rename**, **Delete**.

![Long-press on a host](img/ssh/hold-host.png)

## Live session

**Live session** opens a shell on the device, like a terminal on a computer. Type with KOReader's keyboard; Enter sends the line.

![A live session](img/ssh/session.png)

- **↹** (Tab, to complete names), **Esc**, **Ctrl** (then a letter, for example Ctrl then D), **Ctrl-C** (stops what's running).
- **⇧** and **⇩** move up and down the screen; hold them to scroll.
- **Commands** pastes a command (or the clipboard).
- Long-press the screen for KOReader's clipboard menu: **Copy all**, **Copy line**, **Copy word**, **Select** (tap the start and the end) and **Paste**.
- **✕** asks **Disconnect?** (the keyboard hides while it asks, and comes back on **Cancel**). Typing `exit` also ends the session (**[Session ended]**).

Programs that draw the whole screen (top, nano, htop) don't draw well on the Kindle: it is a simple terminal. Use `top -bn1 | head -20` instead of `top`, for example.

## Run on several hosts

**Run on several hosts** (on the SSH page): tick the hosts (✓), tap **Run a command**, and type or paste the command. It runs on all of them at once, and the output page has a part for each host.

![One command on two hosts](img/ssh/several.png)

## Keys

A key lets the Kindle sign in without a password. **Keys** (on the SSH page) lists them.

![Keys](img/ssh/keys.png)

- **Create key** makes a new Ed25519 key on the Kindle. The page that opens shows its **public key** (one line starting with `ssh-ed25519`).
- **Import key file** uses a key you already have: copy the private key file (for example `id_ed25519` from your computer's `.ssh` folder) to the Kindle over USB, then pick it. The Kindle keeps its own copy and offers to delete the file you copied. Ed25519, RSA and ECDSA keys work. A key with a passphrase doesn't: remove the passphrase from a copy first (`ssh-keygen -p -N "" -f copy` on the computer).

To use a key with a device, add its public key to `~/.ssh/authorized_keys` on that device. The easiest way is the web page: **Copy public key**, then on the device run `nano ~/.ssh/authorized_keys`, paste it on a new line, and save. Each key's public key is also in `koreader/settings/sshclient/keys/<key>.pub`. On Windows, use `C:\Users\<you>\.ssh\authorized_keys`, or `C:\ProgramData\ssh\administrators_authorized_keys` for an administrator.

![A key's public key](img/ssh/key.png)

## Dark mode

**Dark mode** (at the bottom of the SSH page) shows SSH white on black. It applies while SSH is open (the list, output pages and live sessions), and the screen goes back to normal when you close SSH. If KOReader's Night mode is already on, nothing changes.

## On the web page

The web page (Web server) has an **SSH** tab, handy for setting things up with a computer keyboard:

- **Hosts**: **Add host** and **Edit** (name, address, user, port, sign in with a key, a saved password, or asking each time; **Forget host key**, **Delete host**). A saved password is sent to the Kindle but never shown again. **Commands** edits a host's saved commands: **Add command**, **Add from command list** (a copy to change), ⧉ (copy), ↑ ↓ (move) and ✕ (remove).
- **Keys**: **Upload key file** (a private key from the computer), **Paste key** (paste the private key's text, including its BEGIN and END lines), **Create key** (made on the Kindle; its public key is copied for you), **Show** (the public key, hidden until you ask), **Copy public key**, **Rename**, **Delete**. Private keys are never shown or sent to the page.
- **Command list**: edit, copy, reorder and remove commands, **Save**, and **Restore built-in commands**.

Commands run on the Kindle, not from the web page.

## Good to know

- The Kindle needs Wi-Fi to connect; it turns Wi-Fi on if it's off. Devices at home are reached on your home Wi-Fi; outside, only devices you can reach from the internet (for example over a VPN).
- Nothing runs while the Kindle sleeps.
- Passwords and private keys stay on the Kindle, in `koreader/settings/sshclient`. Anyone with your Kindle and a USB cable can read them, so prefer keys, and use a key just for the Kindle that you can remove from `authorized_keys` if you lose it.
