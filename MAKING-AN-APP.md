# Making an app

An app here is a KOReader plugin (a `name.koplugin` folder with `_meta.lua` and `main.lua`) that also
plugs into the launcher: its tile, its row in Settings, search, Set up your Kindle, notifications, quick
buttons, the backup, the connection check and a tab on the web page. It says all of that about itself at
start, so **neither the launcher (`apps.koplugin`) nor the web server (`webpage.koplugin`) changes for a new
app.** If you find yourself editing one of them for your app, something here is missing: add the hook to
the launcher once, for every app, instead.

Read [AGENTS.md](AGENTS.md) first: its design principles and rules apply to every app (the shared title
bar and pop-ups, e-ink, no network on KOReader's loop, made-up data only, the Kindle and the web page doing
the same things). This file is the checklist for wiring a new one in. The newest app, NextDNS
(`optional/nextdns.koplugin`), does all of it and is the one to copy from.

## 1. Where it lives

- **In the main install**: a folder at the top (`wikipedia.koplugin`). Everyone gets it.
- **Optional** (for things only some people need): `optional/<name>.koplugin`. The release makes its own
  zip (`kindle-<name>.zip`), Settings > Updates lists it under OPTIONAL APPS with Install, and once
  installed it updates with the rest. Nothing else may depend on it. Add its row to
  [optional/README.md](optional/README.md).

The folder's name is the plugin's name (`name = "nextdns"` in `main.lua`), and that name is the key
everywhere below. Pick one that isn't a KOReader plugin's (`sshclient`, because KOReader has `SSH`).

## 2. The files

```
nextdns.koplugin/
  _meta.lua        fullname and description (_("…")): KOReader's plugin list and the Install box show them
  main.lua         the plugin: init, its screens' entry points, and shareWithApps (step 3)
  ndmodel.lua      the logic as plain Lua (no KOReader modules), so tests/run.lua can check it
  ndapi.lua …      the rest, loaded when first used (require inside functions, not at the top)
  icons/           every icon it draws (step 4)
  webnextdns.lua   its web page routes (step 6)
  web/nextdns.js   its web page tab
  tests/run.lua    plain Lua tests: luajit tests/run.lua from the folder
  version.txt      its What changed (step 8)
  README.md, AGENTS.md (with CLAUDE.md saying "See AGENTS.md")
```

A screen copies the shared pieces from the launcher with the app's own prefix (`ndcanvas.lua`,
`ndko.lua`, `ndtitle.lua`, `ndpage.lua` are copies of `appscanvas`, `appsko`, the title bar and a paged
screen), so it works without the launcher and looks the same with it. With the launcher there, it uses
the shared pop-ups (`PS.popup`, `PS.ko`) instead of its copies.

## 3. Saying what it is: `PS.appInfo`

In `init` (NextDNS does it in `shareWithApps`), one entry on PluginShare. It's a plain table, so it works
whatever order KOReader loads the plugins in. Every field is described at the top of
[apps.koplugin/appsinfo.lua](apps.koplugin/appsinfo.lua).

```lua
local PS = require("pluginshare")
PS.appInfo = PS.appInfo or {}
PS.appInfo.nextdns = {
    name = _("NextDNS"), icon = "ban",   -- its name and icon (notifications, Set up, its tile's)
    dir = self.path,                     -- its folder: its icons/ and its web tab's files
    order = 87,                          -- its place among the apps: tiles, Settings, web tabs
    group = "optional",                  -- its Settings group (see below)
    tiles = { {
        key = "nextdns",                 -- never change it: saved layouts and hidden tiles use it
        group = "tools",                 -- the home screen's suggested group, if not the app's
        event = "ShowNextDNS",           -- what a tap sends (or open = function(plugin) … end)
        line = function(p) return p:appsLine() end,   -- the line under its name: short, from memory
    } },
    web = { page = "nextdns", routes = "webnextdns", script = "web/nextdns.js",
        card = "Your NextDNS profile: blocked queries, the query log, the lists and the protection switches." },
}
```

That entry gives it, with no other change:

- **its tile** on the home screen, with its line (`line` reads what's in memory; it never waits on the
  network);
- **its place in Settings**: the group is `home`, `reading`, `writing` or `tools` for an app in the main
  install, `optional` for an optional one (Settings' groups follow the home screen's suggested groups,
  plus Optional apps);
- **Recent apps** and the app switcher (keep the open screen on the plugin as `self.screen`);
- **gestures** over the apps: its Dispatcher actions are named `<plugin>_…` (`nextdns_show`), or list
  others in `gestures`;
- **its name and icon in the notifications** (`PS.notify{ app = "nextdns", … }`);
- **its own Button labels setting** (Settings > Launcher > Button labels);
- **its web page tab**, its card on the page's Home, and its routes (step 6);
- optionally a line in Set up's More to explore (`explore`), for an app that needs no setting up.

## 4. Icons

Each app draws its icons from its own `icons/` folder: Lucide SVGs, black (`name.svg`) and, for dark
backgrounds, white (`name-w.svg`), with `LICENSE-lucide.txt`. It needs:

- **every icon it draws**, including those a copied module draws (the title bar's `history` for Recent
  apps, `ellipsis-vertical`, `chevron-right`, the battery's). An icon it lacks shows the fallback;
- **the fallback, `star` (and `star-w`)**, so a missing one is a star, not a grey box;
- **its own icon** (the one in `appInfo`), and those of its quick buttons. The launcher draws the tile and
  the quick buttons; when it hasn't an icon itself it takes the app's from `dir/icons/`, so these don't
  have to be added to the launcher.

KOReader's UI fonts lack many symbols: use an icon, never a Unicode symbol, in the UI.

## 5. The rest of the full set

Each is a call on PluginShare, guarded so the app works without the launcher (`if PS.registerSettings then
… end`). The details of each are in AGENTS.md's "The shared UI".

- **Settings** (needed): `PS.registerSettings{ key = "nextdns", name, icon, open = function(jump) … end,
  rows = function() … end }`. The key is the plugin's name. `open` shows its settings page, in the shared
  design (`homeassistant.koplugin/hasettings.lua` is the reference; `PS.settingsPage{ title, rows }` draws
  one for an app without its own); `rows` (or `settings`) lets the launcher's search find each setting.
- **Search**: `PS.registerSearch{ key, name, icon, search = function(q) … end }`, from memory, fast.
- **Set up your Kindle**: `PS.registerSetup{ key, order, icon, title, text, done, doneText, action, run,
  skipped, help }`, a step for what it needs set up (an account, an address); `skipped` says what you get
  without it.
- **Backup**: `PS.backupApps.<plugin> = { key, name, files, reader_keys, secret_keys, … }`: its settings
  files, and its keys and passwords only as secrets (they go in only with Include keys and sign-ins).
- **Connection check**, when it connects to something: `PS.registerTest{ key, name, configured, run }`, one
  row per address, run in a child process. Its settings show **Test connection**.
- **Notifications**, for things to see later (not every success): `PS.notify{ app = "<plugin>", key, text,
  open, route }` and `PS.unnotify(key)`; `PS.notifyOpeners.<plugin> = function(route) … end` opens one
  after a restart. Something left running has an ongoing one (`ongoing = true`), which puts its icon in
  every app's clock corner.
- **Quick buttons** (optional): for an app with something worth one tap: a switch (NextDNS's protection
  switches, Syncthing on or off), a status to glance at (SSH's hosts, NextDNS's blocked today), an action
  (an SSH command). `PS.registerQuick{ key, name, choices = fn() -> { { id, name, icon, group } },
  item = fn(id) -> { label, icon, on, value, tap(done), hold } }`. They show under the launcher's clock
  and in the control center, wherever the user adds them: a tap does the quick thing and calls `done()`,
  a hold opens the app there. An app with nothing quick has none.
- **AI**, if it asks one: `PS.ai.registerFeature` (AGENTS.md: AI only suggests).

## 6. The web page

The web page shows a tab for every app that has `web` in its entry; the web server has nothing of it.

- **Routes** (`webnextdns.lua`, in the app's folder): `routes(server)` with `GET /api/<app>` (the state,
  `{ installed = false }` without the plugin) and `POST /api/<app>/act` (`{ name, args }`). They only pass
  things on to the plugin (`Common.plugin("nextdns"):webState()`, `:webAct()`): the work stays in the
  plugin, so the Kindle and the page do it the same way. Slow work goes to a child process; a route can
  answer at once with `pending` and the page ask again (as the updater's do).
- **The tab** (`web/nextdns.js`): `App.pages.<page> = { async render(main) { … } }`, using the page's
  helpers (`h`, `App.api`, `App.setting`, `App.toggle`, `App.confirm`, `App.toast`; `web/app.js`). It's
  served from the app's folder (`/static/app/<plugin>/<file>`) and loaded before the first page.
- **Its settings on the page are its own.** Settings on the Kindle come from `registerSettings`; the page
  shows only what its tab draws. Every setting and action on one is on the other, with the same words
  (AGENTS.md: the Kindle and the web page do the same things): add it to both, and to `webState`/`webAct`.

## 7. The guide and the docs

- For an app in the main install, a chapter in the guide (`guide/`, listed in `guide/chapters.txt`), as the
  others are written: instructions in plain words, screenshots from made-up data only.
- For an optional app, its `README.md` is its guide (what it does, what it needs, setting it up), and
  `guide/apps.md` names it among the optional apps under Settings > Updates.
- Its `AGENTS.md`: how it works, the API it speaks, what's been tried on a real device and what hasn't.

## 8. Before it goes out

- `luajit tests/run.lua` in its folder, and every other plugin's tests still pass (the launcher's tile
  tests list the apps in order: add yours to the stand-in apps at the top of `apps.koplugin/tests/run.lua`).
- **version.txt**: the date and time on the first line, then a line per change, newest first, at most five
  (`Oct 27  NextDNS: …`). The web page's What changed shows them; add a line to every plugin a commit
  touches.
- Try it in the emulator, and on a Kindle what only a Kindle does (the power manager, the sleep cover,
  lipc, the firewall).
- A test release first (`bash tools/test-release.sh`, from a branch: a pre-release that only shows in
  Settings > Updates > Select version, with Show test versions on), then the release.
