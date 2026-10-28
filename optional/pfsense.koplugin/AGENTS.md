# AGENTS.md: pfSense (optional/pfsense.koplugin)

Notes for AI coding agents working on this plugin. The shared parts of the apps (title bar, pop-ups,
notifications, launcher, guide) are in the top-level AGENTS.md; this file covers only pfSense.

## What it is

A pfSense firewall on the Kindle, over the **REST API package** (pfSense-pkg-RESTAPI, "pfrest", v2) with an
API key: the system's health, gateways, interfaces, services (start, stop, restart), DHCP leases and the ARP
table (Wake-on-LAN), DHCP static mappings and DNS Resolver host overrides (add, change, delete), firewall rules
on or off, WireGuard and OpenVPN status, the system and firewall logs, packages with updates (install, remove),
reboot and pfSense's own update; the DHCP server's and DNS Resolver's settings, pf tables, the service watchdog,
cron jobs, NTP and SSH. An **optional** app: it lives in `optional/`, isn't in the main install zip, and has its
own (`optional/build-zip.py`; the release makes `kindle-pfsense.zip`). The launcher shows its tile only when
it's installed, from what it says about itself (`PS.appInfo.pfsense` in `shareWithApps`: its tile, Settings
group, web tab; see MAKING-AN-APP.md).

## The API (what pfsapi.lua speaks)

The reference is pfrest's OpenAPI document (the firewall's `/api/v2/documentation`, or pfrest.org). Change
pfsapi.lua and its tests together when it changes.

- Base URL `<url>/api/v2` (the user types `https://192.168.1.1`; `pfsmodel.cleanUrl` drops a typed `/api/v2`).
  `X-API-Key: <key>` (pfrest's KeyAuth; it must be ticked in System > REST API > Settings > Authentication
  methods, where only BasicAuth is on to start with). pfSense's own certificate is self-signed: KOReader's
  luasec doesn't check it.
- Answers are `{ code, status, response_id, message, data }`. 401 `"signin"`, 403 `"forbidden"` (the key's
  user lacks the privilege, named `api-v2-<path>-<method>`, or `page-all`), 404 `"notfound"`, 424 `"missing"`
  (a package the endpoint needs, such as WireGuard, isn't installed). An HTML answer is `"notapi"` (the web
  interface's login page). `ping` reads `/system/version` without a key: its JSON 401 is an answer.
- Lists page with `limit`/`offset` (`API:all`, 200 at a time) and sort with `sort_by`/`sort_order`
  (`SORT_DESC` for the newest log lines first).
- **An object's `id` is its place in its list**, so it moves when one before it goes. Every change reads the
  object first and checks it's the one meant (`"changed"` when not): a rule by its `tracker`, a static mapping
  by its MAC (`parent_id` is the DHCP server's interface, such as `lan`), a host override by host and domain,
  an ARP entry by its address, a service by its internal name (its id looked up from the list).
- Changes that don't apply by themselves are applied after: `POST /firewall/apply` (rules),
  `/services/dhcp_server/apply` (static mappings), `/services/dns_resolver/apply` (host overrides).
- Reading: `readAll{ status, lists }`. The status (system, version, hostname, gateways, interfaces, services)
  every read; the lists (leases, arp, rules, statics, overrides, peers, ovpn) on the first read, while a page
  showing one is on top, and on ⟳ (`pfsmodel.merge` keeps them between). Packages (slow: pfSense asks its
  package server) and logs are read only when their page opens.
- Logs (`M.LOGS`: system, firewall, dhcp, auth, openvpn, packages/restapi) come whole (`limit=0`): a log
  line's `id` is only its place in the file and the API refuses `sort_by=id` ("must be a valid field"), so
  `pfsmodel.newest` keeps the last 100, newest first (or as they are, if they came newest first).
- Interfaces: some versions say `enable = false` for interfaces that are on; one that's up or has an
  address counts as on.
- Aliases (`PATCH /firewall/alias` with the whole `address` and `detail` lists), NAT rules (`PATCH` with `disabled`),
  static routes and the default gateway (then `POST /routing/apply`), WireGuard peers (`enabled`, then
  `/vpn/wireguard/apply`): each checked first as above (an alias by its name, a NAT rule by `API.NAT[kind].sig`, a
  route by network and gateway, a peer by its public key, an OpenVPN connection by its name and address).
- Firewall states (a device's connections) are read and closed by query, never all of them:
  `source__startswith=<ip>:` and `destination__startswith=<ip>:` (the colon keeps .5 from matching .50).
- Certificates come with their private key (`prv`) and certificate (`crt`): `API.LISTS.certs.keep` keeps only
  the name and dates, in the child process, so neither reaches the plugin, the web page or a log.
- Read only when asked: packages, logs, a device's connections, ping, config history, pf tables, and the
  settings pages (`API:config(name)`, `API.CONFIG`: watchdog, cron, ntp, ssh, dhcp, dnsres; main.lua keeps each
  in `state.config`, read again when its page opens and after each change there).
- Packages: `GET /system/package/available` (what can be installed), `POST /system/package {name}` (slow:
  pfSense downloads it; 300 s), `DELETE /system/package?id=` (its place in the installed list, checked by its
  name first).
- pf tables: `GET /diagnostics/tables` (the entries stay in the child: a block list can have thousands; the
  plugin gets each table's name and count, or for a lookup the matching entries, `API.inEntry` taking a
  network as containing its addresses). `GET /diagnostics/table?id=<name>` (the first 500), `DELETE` the same
  **empties the whole table**: the API has no call that takes out one entry (and the command prompt is left
  out), so the pages say so.
- Settings pages: service watchdogs (checked by the service's name), cron jobs (by all their fields: minute…
  command, `API.CRON`), NTP's settings (its `serverauthkey` stays in the child) and time servers (by the
  server; ntpd restarted after, since the list doesn't apply by itself), SSH (`PATCH /services/ssh`), the DHCP
  servers (`/services/dhcp_servers`, each one's id its interface; their static mappings stay in the child),
  address pools (by their range) and custom options (by number and value) with `parent_id`, then
  `/services/dhcp_server/apply`; the DNS Resolver's settings (`PATCH`, then `/services/dns_resolver/apply`).
- Left out on purpose: updating a package (the API has no such call), user management, the command prompt,
  halt.

## Files

- `main.lua`: the plugin. Settings (`settings/pfsense.lua`: url, key, name; reader settings
  `pfsense_interval`, `pfsense_notify`), reading in the background (`fetch`, `status`, `packages`, `log`),
  actions (`act`, with the change applied to what was read at once and a read after; reboot and update don't
  read again), setup's check, notifications, the launcher's line, every registration with the launcher
  (`shareWithApps`), quick buttons (status, a rule on or off by tracker, Wake a static mapping), search, and
  the web page's `webState()` / `webAct(name, args)`.
- `pfsui.lua`: the screens (main page, Gateways, Interfaces, Services, Devices, ARP table, Static mappings,
  DNS host overrides, Firewall rules, VPN, Logs, Packages and Install, DHCP server, DNS Resolver, pf tables,
  Service watchdog, Cron jobs, NTP and SSH, Details, Settings, setup), and reading every so often while a live
  page is on top (`UI.poll`).
- `pfsmodel.lua`: plain Lua, tested: the lists as tables, words for states, sizes, lines, counts, attention,
  the launcher's line, notifications between two reads (`changes`), search, the lists' sort and search
  (`sorted`, `filter`, `matches`; the sort is the reader setting `pfsense_sort`, shared with the web page), log lines (`logLine`,
  `filterLine` for pfSense's filterlog CSV).
- `pfsapi.lua`: the requests (blocking: only in a child process). `API.new(cfg, request)`: the tests pass a
  stand-in network.
- `pfsbg.lua`, `pfsko.lua`, `pfspage.lua`: Pangolin's pgbg/pgko/pgpage (themselves from FlashForge's and
  SSH's), renamed.
- `pfstitle.lua`, `pfscanvas.lua`: **copies** of the launcher's `appsbar.lua` and `appscanvas.lua`. Re-copy
  them when those change; don't edit them here.
- `icons/` (Lucide, ISC; every icon it draws, `router` for the app, `star` for the fallback), `tests/run.lua`,
  `version.txt` (its What changed), `README.md` (its guide: what it does, what it needs, setting it up).
- `webpfsense.lua`, `web/pfsense.js`: its web page tab (routes and the tab, in this folder: the web server has nothing of it).

## Rules

- Stopping a service, Reboot and Update ask first; so do installing or removing a package, emptying a pf
  table, and turning off a DHCP server, the DNS Resolver, NTP or SSH. Deleting a static mapping, host override,
  pool, custom option, cron job or time server, and no longer watching a service, have Undo (it adds it again);
  everything else just does it.
- The API key never goes in logs, the diagnostics file or `webState()`; the backup has it only with Include
  keys and sign-ins.
- Made-up data only (192.168.1.x from the export's allowed examples, home.example.com, aa:bb:cc:dd:ee:0x).

## Testing

```sh
luajit tests/run.lua        # pfsmodel, and pfsapi against a stand-in network
```

Tried on the emulator against a stand-in REST API (made-up data), not yet against a real pfSense or on a Kindle.
The second batch (packages to install and remove, pf tables, the settings pages) has its tests and was run with
stand-ins for KOReader's widgets, not yet in the emulator: its fields are the OpenAPI document's.
