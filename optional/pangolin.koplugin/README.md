# Pangolin for KOReader

Your [Pangolin](https://github.com/fosrl/pangolin) server on a Kindle, over its [Integration API](https://docs.pangolin.net/self-host/advanced/integration-api) and an organization API key: the same API its Home Assistant integration (ha-pangolin) uses. Unofficial: not affiliated with or endorsed by Fossorial/Pangolin.

- **At a glance**: how many sites are online, public resources healthy and clients online, and what needs attention (an offline site, a resource that's down or degraded).
- **Sites**: online or not, type, address, Newt version, exit node, data in and out, and the resources that run through each.
- **Public resources**: health, and each target's (so you see which backend is down); its sites and protection (sign-in, password, PIN, email whitelist, header auth). **Enabled**, **Require sign-in** (turning it off asks first) and **Block access**.
- **Private resources**: mode, destination, alias, ports, ICMP, sites; **Enabled**.
- **Clients** (machines and user devices): online, user, version, platform, last seen, data; **Blocked** and **Archived**.
- **Reset bandwidth** (⋮, asks first): every site's data counters back to zero.
- **Setting up**: the API URL, the key, then the organization (picked from a list with a root key, typed with an organization key).
- **With the launcher**: its tile (`ShowPangolin`, line "All online · 4 sites"), Settings, search (sites, resources, clients), a step in Set up your Kindle, quick buttons (the status, any resource on or off), Test connection (the API, then the key and organization), the backup (the key only with Include keys and sign-ins), notifications (a site or resource gone offline), and a Pangolin tab on the web page.
- **Gesture**: **Pangolin** (opens it).

Lists the key can't read are left out and say which permission they need. Nothing runs in the background: Pangolin is read while the app is open (every 30 seconds; Settings > Read every), and when the launcher's tile or a quick button shows it.

## Install

An optional app: it isn't in the main install zip. Settings > Updates > **Optional apps** on the Kindle, or unzip `kindle-pangolin.zip` (from a release) into `koreader/plugins/` and restart KOReader. It works without the launcher, with KOReader's own dialogs.

The API's field names and quirks follow the Home Assistant integration (ha-pangolin, MIT). Icons: [Lucide](https://lucide.dev) (ISC).
