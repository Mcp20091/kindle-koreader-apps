# pfSense for KOReader

Your [pfSense](https://www.pfsense.org) firewall on a Kindle, over the [REST API package](https://pfrest.org) (pfSense-pkg-RESTAPI) and an API key. Unofficial: not affiliated with or endorsed by Netgate or the REST API package's authors.

- **At a glance**: the version, uptime, CPU, memory, disk and temperature, and what needs attention (a gateway down or losing packets, an interface down, a service stopped).
- **Gateways** and **Interfaces**: status, latency and loss; addresses, link speed and traffic.
- **Services**: running or not; **Start**, **Stop** (asks first) and **Restart**.
- **Devices**: the DHCP leases, online ones first; **Wake** (Wake-on-LAN) and **Add a static mapping** from a lease.
- **ARP table**: each entry; **Wake**, **Remove**.
- **DHCP static mappings**: by interface; **Add**, change the IP address, hostname or description, **Wake**, **Delete** (with Undo).
- **DNS host overrides** (the DNS Resolver's): **Add**, change the host, domain, addresses, aliases or description, **Delete** (with Undo).
- **Firewall rules**: by interface, each with a switch (applied at once).
- **VPN**: WireGuard peers (with the WireGuard package) and OpenVPN servers with who's connected.
- **Logs**: the system and firewall logs, newest first; firewall lines as pass or block, from and to.
- **Packages**: installed ones, with the ones that have an update first.
- **Update pfSense** and **Reboot** (⋮, both ask first).
- **With the launcher**: its tile (`ShowPfSense`, line "All up · 14 devices online"), Settings, search (gateways, interfaces, services, devices, mappings, overrides, rules), a step in Set up your Kindle, quick buttons (the status, any firewall rule on or off, Wake any static mapping), Test connection (the API, then the key), the backup (the key only with Include keys and sign-ins), notifications (a gateway, interface or service gone down), and a pfSense tab on the web page.
- **Gesture**: **pfSense** (opens it).

Lists the key's user can't read are left out and say which privilege they need. Nothing runs in the background: pfSense is read while the app is open (every minute; Settings > Read every), and when the launcher's tile or a quick button shows it.

## What you need

- **The REST API package** (pfSense-pkg-RESTAPI) installed on pfSense. It isn't in pfSense's Package Manager: its website has the one command that installs it for your pfSense version.
- **API keys allowed**: in pfSense, **System > REST API > Settings**, tick **Key** under **Authentication methods** and save.
- **An API key**: **System > REST API > Keys > Add**. The key can do what the user who made it can do. For everything, that user needs **page-all** (the admin user has it). For less, make a user with only the REST API privileges for what you want, such as `api-v2-status-system-get` to read the system.
- **The firewall's address**, such as `https://192.168.1.1` (its web interface). pfSense's own certificate is fine.

## Setting it up

1. Open **pfSense** (its tile on the launcher, or the **Tools** tab (the wrench) of KOReader's menu) and tap **Set up**.
2. Type the **Address**, such as `https://192.168.1.1`, and tap **Next**.
3. Type the **API key** and tap **Connect**.

The Kindle reads pfSense and says **Connected to …**. If it doesn't answer, the message says why: the address can't be reached, it isn't the REST API, the key was refused (or API keys aren't allowed), or the key's user is missing a privilege.

The launcher's **Set up your Kindle** has the same step.

## Install

An optional app: it isn't in the main install zip. Settings > Updates > **Optional apps** on the Kindle, or unzip `kindle-pfsense.zip` (from a release) into `koreader/plugins/` and restart KOReader. It works without the launcher, with KOReader's own dialogs.

Icons: [Lucide](https://lucide.dev) (ISC).
