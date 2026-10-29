# pfSense

pfSense shows your pfSense firewall on the Kindle: its health, gateways, interfaces and services, the devices on your network, DHCP and DNS entries, firewall rules, VPN, logs and packages. You can start, stop or restart a service, wake a device, turn a firewall rule on or off, change DHCP and DNS entries, and reboot or update the firewall. pfSense is a firewall and router that runs on its own computer.

It talks to the REST API package on pfSense with an API key. It isn't made by or endorsed by Netgate or the REST API package's authors.

## Installing it

pfSense is an optional app: it isn't in the main install. To add it:

1. Open the launcher's **⋮ > Settings > Updates** and tap the **Optional apps** row (the web page's **System > Updates** has the same list).
2. Tap **Install** next to **pfSense**. KOReader restarts.

Once it is installed, it is updated with every new version of the primary apps. **Remove** in the same list takes it off again.

By hand: copy `kindle-pfsense.zip` (from the release) to the Kindle, unzip it into `koreader/plugins/` and restart KOReader.

## What you need

On pfSense:

- **The REST API package** (pfSense-pkg-RESTAPI) installed. It isn't in pfSense's Package Manager: the package's website (pfrest.org) has the one command that installs it for your version of pfSense.
- **API keys allowed**: in pfSense, open **System > REST API > Settings**, tick **Key** under **Authentication methods** and save.
- **An API key**: **System > REST API > Keys > Add**. The key can do what the user who made it can do. For everything, that user needs **page-all** (the admin user has it). For less, make a user with only the REST API privileges for what you want, such as `api-v2-status-system-get` to read the system.
- **The firewall's address**: the address of its web interface, such as `https://192.168.1.1`. pfSense's own certificate is fine.

A list the key's user can't read is left out and says which privilege it needs.

Two pages need extra packages on pfSense: **Service watchdog** needs the Service Watchdog package and **Cron jobs** needs the Cron package. The page says so when one isn't installed.

## Opening it

- The **pfSense** tile on the launcher. Its line says how things are: **All up · 14 devices online**, or what is down.
- Quick buttons on the launcher (add them in **Settings > Launcher > Quick buttons > Add a button > pfSense…**, or on the web page's Launcher tab): **pfSense status** (tap reads it again), any **Firewall rules** (tap turns the rule on or off), **Wake** for a static mapping (**Wake-on-LAN**), and the other groups it offers. A hold opens pfSense.
- **Tools** in KOReader's menu > **pfSense**.
- A gesture: **Settings > Taps and gestures > Gesture manager**, pick a gesture, then **General > pfSense**.
- The launcher's **recent apps** and its **search**, which finds gateways, interfaces, services, devices, static mappings, DNS overrides and firewall rules.

The title bar is the same as in the other apps: **‹** goes back, the house goes to the launcher, the clock with an arrow shows the recent apps; at the right are the time and battery, **⟳** (reads pfSense again), the bell and **⋮**. A swipe in from the left edge goes back.

## Setting it up

The first time, the screen says **pfSense isn't set up yet.**

1. Tap **Set up**.
2. Type the **Address**, such as `https://192.168.1.1`, and tap **Next**.
3. Type the **API key** and tap **Connect**.

The Kindle reads pfSense and says **Connected to …**. If it can't, the message says why: the address can't be reached, it isn't the REST API, the key was refused (or API keys aren't allowed), or the key's user is missing a privilege.

The launcher's **Set up your Kindle** has the same step. It can be skipped and done any time later from the app.

## The app

- **The status box** at the top: **pfSense** and its version, how long it has been up, and **CPU** (with the load), **Memory**, **Disk** and **Temperature**.
- **NEEDS ATTENTION**: only when something is wrong: a gateway down or losing packets, an interface down, a service stopped, a certificate about to run out. Tap an item to open it.
- **BROWSE**: a tile for each page below. Each tile's second line says how it stands, such as **2 of 2 up** or **3 stopped**.
- **At the bottom**: when pfSense was last read.

While pfSense is open it is read every minute (change it in Settings). Nothing is read once it closes, and nothing runs in the background. The pages for the DHCP server, DNS Resolver, pf tables, watchdog, cron, NTP and SSH are read when they open.

Most lists work the same way. **Devices**, **ARP table**, **Static mappings** and **DNS overrides** have **Search** (a name, an IP or MAC address, a word of the description) and sort by **Name** or **IP address**, with **Reverse**; **Services**, **Firewall rules** and **Logs** have Search. The sort is kept, and is the same on the web page. **Devices** and **Static mappings** can show only the online (or offline) ones; **Services** only the running (or stopped) ones.

Anything that could cut you off asks first. Deleting something offers **Undo** at the bottom of the screen for a few seconds.

### Gateways and Interfaces

- **Gateways**: each one's status, latency and packet loss. Tap one for its page; **Make default** makes it the default gateway (asks first). Also here: the default gateway for IPv4 and IPv6 to pick, gateway groups, and static routes with a switch each.
- **Interfaces**: each one's status, addresses, link speed and traffic.

### Services

Each service, running or not. Tap one: **Start**, **Stop** (asks first) or **Restart**.

### Devices, ARP table and static mappings

- **Devices**: the DHCP leases, online ones first. Tap one for its page:
  - **Wake** sends Wake-on-LAN to it.
  - **Add a static mapping** keeps its address for it.
  - **Add to an alias** adds it to one of the firewall's address lists.
  - Its connections through the firewall (see Connections below).
- **ARP table**: each entry, with **Wake**, **Add a static mapping** and **Remove**.
- **Static mappings**: the DHCP static mappings, by interface. **Add** one; tap one to change its **IP address**, hostname or description, **Wake** it, or **Delete** it.
- **DNS overrides**: the DNS Resolver's host overrides. **Add** one; tap one to change its host, domain, addresses, aliases or description, or **Delete** it.

### Firewall rules, Aliases, NAT and Connections

- **Firewall rules**: by interface, each with a switch, applied at once.
- **Aliases**: the address, network and port lists the rules use. Add or remove an entry.
- **NAT**: port forwards, outbound mappings and 1:1 NAT, each with a switch, and the outbound NAT mode.
- **Connections**: type a device's address to see its connections through the firewall now. **Close all** closes them, so a new block works at once.
- **Ping**: ping an address from pfSense itself (also in **⋮** and on a device's page).

### VPN, Certificates and Config history

- **VPN**: WireGuard peers with a switch each and how they are doing; OpenVPN servers with who is connected (**Disconnect**), OpenVPN clients and IPsec tunnels.
- **Certificates**: when each one runs out. One within 14 days goes under **NEEDS ATTENTION** and sends a notification. **Renew now** renews an ACME (Let's Encrypt) one.
- **Config history**: the recent changes to pfSense's configuration, who made them and when.

### DHCP server, DNS Resolver and pf tables

- **DHCP server**: each interface's server on or off (asks first when turning it off), its range, DNS servers, gateway, domain and lease times, with address pools and custom options to add or delete.
- **DNS Resolver**: on or off (asks first when off), DNSSEC, the forwarding mode, and the names it takes from DHCP leases, static mappings and OpenVPN clients.
- **pf tables**: the block lists that packages such as pfBlockerNG or Snort fill, and the aliases' tables. **Look up** an address to see the tables it is in. **Empty** a table (asks first); the REST API can't take one address out of a table, only all of them.

### Service watchdog, Cron jobs, NTP and SSH

- **Service watchdog**: the services pfSense starts again when they stop. Watch another, switch its notifications, or stop watching one.
- **Cron jobs**: add one, change when it runs or what it runs, or delete it.
- **NTP and SSH**: the NTP server on or off and its time servers; the SSH server on or off and its port.

### Logs and Packages

- **Logs**: the System, Firewall, DHCP, Authentication, OpenVPN and REST API logs, newest first. Firewall lines show as pass or block, from and to.
- **Packages**: the installed ones, with the ones that have an update first. **Install** one from the list pfSense's package server has, or **Remove** one; both ask first. Updating a package isn't something the REST API can do: use pfSense's own web interface.

## The menu

The **⋮** menu has:

- **Ping**.
- **Update pfSense**: pfSense looks for a newer version, installs it and restarts by itself. The network is down meanwhile, sometimes for several minutes. It asks first.
- **Reboot**: asks first. The Kindle's own Wi-Fi goes down too if it goes through this firewall.
- **Details**: the connection and the counts.
- **Help**: a short version of what you need.
- **Recent apps**, **Light**, **Night mode** and **Refresh screen**, as in the other apps.
- **Settings**, always last.

## Settings

The same page opens from the launcher's **Settings** list, under **Optional apps > pfSense**.

- **DISPLAY**
  - **Read every**: how often pfSense is read while the app is open, from 15 seconds to 5 minutes.
- **NOTIFICATIONS**
  - **Gateways, interfaces and services going down**: a notification in the bell, seen while pfSense is read; it goes when they are back. Tap it to open pfSense.
- **CONNECTION**
  - **Address** and **API key**. The key shows only its end.
  - **Test connection**: checks the API, then the key.
  - **Remove connection**: forgets the address and key. **Undo** at the bottom of the screen takes it back for a few seconds.

The web page's backup (**System**) includes these settings; the key only if you tick **Include keys and sign-ins**.

## On the web page

The web page (see the Web server chapter) has a **pfSense** tab:

- The status, with **Refresh**.
- **Gateways and interfaces** (and **Static routes**), **Services**, **Devices (DHCP leases)**, **DHCP static mappings**, **DNS host overrides**, **Firewall rules**, **Aliases**, **NAT**, **WireGuard peers** and **Certificates**, with the same switches and buttons as on the Kindle, and a search and sort on the lists that have one.
- **DHCP server**, **DNS Resolver**, **pf tables**, **Packages**, and the **Service watchdog**, **Cron jobs**, **NTP (time)** and **SSH** cards, which are read when you press **Read** on their card.
- **System**: **Update pfSense** and **Reboot** (both ask first).
- **Settings**: **Read every**, the notification switch, and the **Address** and **API key**, with **Save** and **Test connection**.

The logs, config history, connections and ping are on the Kindle only.

## Good to know

- **The key stays on the Kindle** and is only sent to your firewall.
- **Reboot and update take the network down.** If the Kindle's Wi-Fi goes through the firewall, the Kindle disconnects too. Wait a few minutes.
- **Turning off the DHCP server or DNS Resolver** can cut devices off; it asks first.
- **A key with fewer privileges** shows fewer pages, each saying which privilege it needs.
