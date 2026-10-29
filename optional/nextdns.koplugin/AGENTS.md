# AGENTS.md: NextDNS (optional/nextdns.koplugin)

Notes for AI coding agents working on this plugin. The shared parts of the apps (title bar, pop-ups,
notifications, launcher, guide) are in the top-level AGENTS.md; this file covers only NextDNS.

## What it is

A NextDNS profile on the Kindle, over NextDNS's API with the account's API key: today's queries and blocked
count, the domains blocked most, the query log (All, Blocked, Allowed, a device, and a search), the denylist and
allowlist (add, on or off, delete with Undo, move), the security, privacy and parental control switches, the
profile in use, and whether this Kindle goes through NextDNS. An **optional** app: it lives in `optional/`,
isn't in the main install zip, and has its own (`optional/build-zip.py`; the release makes
`kindle-nextdns.zip`). It says what it is in `PS.appInfo.nextdns` (main.lua's
`shareWithApps`): its tile, Settings group and web tab (`webnextdns.lua`, `web/nextdns.js`, here), so the
launcher and the web page show it only when it's installed, with nothing of it in their code.

## The API (what ndapi.lua speaks)

The reference is dmeiser/nextdns-mcp's `src/nextdns_mcp/nextdns-openapi.yaml` (MIT; the Kindle can't run the
MCP server itself, only the API it describes). It hasn't been tried against the real API here: only against
the stand-in in the tests and the emulator. Check these on a real account before trusting them:

- `https://api.nextdns.io`, header `X-Api-Key`. Answers `{ data, meta }`; errors `{ errors = { { code, detail } } }`.
  401 and 403: the key is bad (`"signin"`). 404: no such profile (`"notfound"`). 429 (`"busy"`). Changes
  answer 204 with nothing.
- `GET /profiles` (the picker), `GET /profiles/{id}` (name, denylist, allowlist, security, privacy,
  parentalControl in one answer), `GET /profiles/{id}/analytics/status?from=<local midnight, Unix>`
  (`{ status, queries }`), `GET …/analytics/domains?status=blocked&limit=5&from=…`.
- `GET …/analytics/devices?from=…&limit=500` (`{ id, name, model, queries }`, every page by its cursor, at
  most 10); the queries NextDNS couldn't put on a device are under the id `__UNIDENTIFIED__`.
- `GET …/logs?limit=40[&status=blocked|allowed][&search=…][&device=<id>][&cursor=…]`; the next page's cursor is
  `meta.pagination.cursor`.
- `PATCH …/security|privacy|parentalControl { field = bool }`; `POST …/denylist|allowlist { id = domain, active }`,
  `PATCH …/denylist/{domain} { active }`, `DELETE …/denylist/{domain}` (an entry's id is its domain).
- `https://test.nextdns.io` (no key!): `{ status = "ok" | "unconfigured", profile, protocol }` for the DNS of
  whoever asks, which is this Kindle since it runs in the child process.
- Left out on purpose: clearing the logs (permanent), replacing a whole list, blocklists, natives,
  parental control's services and categories, rewrites and profile settings (the website has them).

## Files

- `main.lua`: the plugin. Settings (`settings/nextdns.lua`: key, profile, profile_name; reader setting
  `nextdns_interval`), reading in the background (`fetch`, `status`), the query log (`readLogs`, `logState`) and today's devices for its filter (`devices`, kept 5 minutes),
  actions (`act`: switch, list_add, list_active, list_delete; applied to what was read at once and read
  again after), profiles, the launcher's line, every registration with the launcher (`shareWithApps`), quick
  buttons, search, and the web page's `webState()` / `webAct(name, args)`.
- `ndui.lua`: the screens (main page, Recent queries and its Devices page, Denylist/Allowlist, Protection,
  Settings, setup), and
  reading every so often while a live page is on top (`UI.poll`).
- `ndmodel.lua`: plain Lua, tested: the switches (`M.SWITCHES`, their wording), what was read as tables,
  numbers, times, the log, the Kindle's check, domains as typed (`cleanDomain`), lines, search.
- `ndapi.lua`: the requests (blocking: only in a child process). `API.new(cfg, request)`: the tests pass a
  stand-in network.
- `ndbg.lua`, `ndko.lua`, `ndpage.lua`: Pangolin's pgbg/pgko/pgpage (from FlashForge's, from SSH's), renamed.
- `ndtitle.lua`, `ndcanvas.lua`: **copies** of the launcher's `appsbar.lua` and `appscanvas.lua`. Re-copy
  them when those change; don't edit them here.
- `icons/` (Lucide, ISC), `tests/run.lua`; the user guide chapter is `guide/nextdns.md` (repository root).

## Rules

- Everything can be switched back, so nothing asks first; deleting a list entry has Undo (it comes back on
  or off as it was).
- The API key never goes in logs, the diagnostics file or `webState()` (only `M.masked`); the backup has it
  only with Include keys and sign-ins. test.nextdns.io never gets it.
- No notifications: nothing here is worth one later. The query log is read only when its page opens or
  with ⟳ (rate limits); the first page every minute while it's on top.
- Made-up data only (example.com, example.net, example.org domains, "Home", "Kids", abc123).

## Testing

```sh
luajit tests/run.lua        # ndmodel, and ndapi against a stand-in network
```

On the emulator: `dev/emu/shot.sh nextdns` (a stand-in NextDNS in the driver; see its SHOT_NEXTDNS block).
