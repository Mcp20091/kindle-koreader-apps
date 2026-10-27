# AGENTS.md: Pangolin (optional/pangolin.koplugin)

Notes for AI coding agents working on this plugin. The shared parts of the apps (title bar, pop-ups,
notifications, launcher, guide) are in the top-level AGENTS.md; this file covers only Pangolin.

## What it is

A Pangolin server's organization on the Kindle, over Pangolin's Integration API with an API key (no Home
Assistant): sites, public resources (health per target), private resources, clients, and the switches the
Home Assistant integration has (resource enabled, sign-in, block access; private resource enabled; client
blocked and archived; reset bandwidth). An **optional** app: it lives in `optional/`, isn't in the main install
zip, and has its own (`optional/build-zip.py`; the release makes `kindle-pangolin.zip`). The launcher shows its
tile only when it's installed (`plugin = "pangolin"` in appsmodel's TILES).

## The API (what pgapi.lua speaks)

The reference is the Home Assistant integration **ha-pangolin** (`custom_components/pangolin/api.py` and its
AGENTS.md "Pangolin API facts", checked there against `fosrl/pangolin/server/routers/**`). Change both sides
together when Pangolin changes.

- Base URL `<url>/v1` (the user types `https://api.example.com`; `pgmodel.cleanUrl` drops a typed `/v1`).
  `Authorization: Bearer <apiKeyId>.<secret>`. Answers are `{ data, success, error, message, status }`.
- 401: the key is bad (`"signin"`). 403: the key lacks the permission (`"forbidden"`; the caller names the
  permission: `ACTIONS[name].perm` in main.lua). 404 (`"notfound"`). An HTML answer is `"notapi"`.
- `GET /v1/` needs no key (the health check, `ping`). `GET /orgs` only for root keys (setup falls back to
  typing the org ID on 403/404). `GET /org/{org}` checks the key and org.
- Lists page with `page`/`pageSize` and `data.pagination.total`: `/org/{org}/sites` (`sites`),
  `/resources` (`resources`), `/private-resources` (`siteResources`), `/clients` (`clients`) and
  `/user-devices` (`devices`), the last two with `status=active,blocked,archived[,pending,denied]` (otherwise
  blocked and archived ones are hidden). A 403/404 on the optional lists skips them (`skipped`), never fails
  the read.
- Changes: `POST /resource/{id}` `{ enabled | sso | blockAccess }`, `POST /private-resource/{id}`
  `{ enabled }` (older: `/site-resource/{id}`), `POST /client/{id}/block|unblock|archive|unarchive`,
  `POST /org/{org}/reset-bandwidth`. `blockAccess` isn't in the list: `GET /resource/{id}` (Get Resource),
  read once per run when a resource's page opens.
- Left out on purpose: site restart (API keys get 404 on current Pangolin), client delete (permanent),
  maintenance mode (Enterprise only, silently dropped elsewhere), key management (root keys only).

## Files

- `main.lua`: the plugin. Settings (`settings/pangolin.lua`: url, key, org, org_name; reader settings
  `pangolin_interval`, `pangolin_notify`), reading in the background (`fetch`, `status`), actions (`act`, with
  the change applied to what was read at once and a read after), resource details, setup's org list and check,
  notifications, the launcher's line, every registration with the launcher (`shareWithApps`), quick buttons,
  search, and the web page's `webState()` / `webAct(name, args)`.
- `pgui.lua`: the screens (main page, Sites, a site, Public resources, a resource, Private resources, Clients,
  a client, Details, Settings, setup), and reading every so often while a live page is on top (`UI.poll`).
- `pgmodel.lua`: plain Lua, tested: the lists as tables, health, sizes, lines, counts, attention, the
  launcher's line, notifications between two reads (`changes`), search.
- `pgapi.lua`: the requests (blocking: only in a child process). `API.new(cfg, request)`: the tests pass a
  stand-in network.
- `pgbg.lua`, `pgko.lua`, `pgpage.lua`: FlashForge's ffbg/ffko/ffpage (themselves from SSH's), renamed.
- `pgtitle.lua`, `pgcanvas.lua`: **copies** of the launcher's `appsbar.lua` and `appscanvas.lua`. Re-copy
  them when those change; don't edit them here.
- `icons/` (Lucide, ISC), `tests/run.lua`, `docs/guide.md` (the user guide chapter).

## Rules

- Turning sign-in off and Reset bandwidth ask first; everything else just does it (and can be switched back).
- The API key never goes in logs, the diagnostics file or `webState()` (only its ID); the backup has it only
  with Include keys and sign-ins.
- Made-up data only (api.example.com, "Home lab", "Workshop", 192.168.1.x).

## Testing

```sh
luajit tests/run.lua        # pgmodel, and pgapi against a stand-in network
```

On the emulator: `dev/emu/shot.sh pangolin` (a fake Pangolin in the driver; see its SHOT_PANGOLIN block).
