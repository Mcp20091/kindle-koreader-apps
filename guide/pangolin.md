# Pangolin

Pangolin shows your Pangolin server on the Kindle: how many sites are online, how each public resource is doing, and your private resources and clients. You can turn resources on or off, require sign-in or block access to a public resource, block or archive a client, and reset the sites' data counters. Pangolin is a self-hosted server that makes your services reachable from outside your home.

It talks to Pangolin's Integration API with an organization API key. It isn't made by or endorsed by Pangolin's authors.

## Installing it

Pangolin is an optional app: it isn't in the main install. To add it:

1. Open the launcher's **⋮ > Settings > Updates** and tap the **Optional apps** row (the web page's **System > Updates** has the same list).
2. Tap **Install** next to **Pangolin**. KOReader restarts.

Once it is installed, it is updated with every new version of the primary apps. **Remove** in the same list takes it off again.

By hand: copy `kindle-pangolin.zip` (from the release) to the Kindle, unzip it into `koreader/plugins/` and restart KOReader.

## What you need

- **Pangolin's Integration API** turned on (`enable_integration_api` in Pangolin's `config.yml`) and reachable from the Kindle's Wi-Fi, at an address such as `https://api.example.com`.
- **An organization API key**: in Pangolin's dashboard, the organization's **Settings > API Keys**. It looks like `id.secret`. Give it the permissions for what you want to see and change:
  - **List Sites** and **Get Organization** at least.
  - **List Resources**, **List Site Resources** and **List Clients** to see public resources, private resources and clients.
  - The **Update**, **Block** and **Archive** permissions to change them.
- **The organization's ID**: it is in the dashboard's address, after the `/`.

A list the key can't read is left out and says which permission it needs; give the key that permission in the dashboard, then tap **⟳**.

## Opening it

- The **Pangolin** tile on the launcher. Its line says how things are: **All online · 4 sites**, or what is down.
- Quick buttons on the launcher (add them in **Settings > Launcher > Quick buttons > Add a button > Pangolin…**, or on the web page's Launcher tab): **Pangolin status** (tap reads Pangolin again) and any public or private resource, to turn it on or off. A hold opens Pangolin.
- **Tools** in KOReader's menu > **Pangolin**.
- A gesture: **Settings > Taps and gestures > Gesture manager**, pick a gesture, then **General > Pangolin**.
- The launcher's **recent apps** and its **search**, which finds sites, resources and clients by name.

The title bar is the same as in the other apps: **‹** goes back, the house goes to the launcher, the clock with an arrow shows the recent apps; at the right are the time and battery, **⟳** (reads Pangolin again), the bell and **⋮**. A swipe in from the left edge goes back.

## Setting it up

The first time, the screen says **Pangolin isn't set up yet.**

1. Tap **Set up**.
2. Type the **API URL**, such as `https://api.example.com`, and tap **Next**. (The Kindle adds `/v1` itself.)
3. Type the **API key** and tap **Next**.
4. Pick the **Organization** from the list. With an organization key the Kindle can't list organizations, so it asks you to type the **Organization ID** instead.

The Kindle reads Pangolin and says **Connected to …**. If it can't, the message says why: the address can't be reached or doesn't answer as Pangolin's Integration API, the connection was refused (is the API turned on?), the key was refused, or the key can't read the organization.

The launcher's **Set up your Kindle** has the same step. It can be skipped and done any time later from the app.

## The app

- **The status box** at the top: for example **4 of 4 sites online**, **6 of 6 public resources healthy** and **3 of 3 clients online**.
- **NEEDS ATTENTION**: only when something is wrong: **1 site offline**, **1 resource down**, **1 degraded**. Tap an item to open it.
- **BROWSE**:
  - **Sites**
  - **Public resources**
  - **Private resources**
  - **Clients**
- **At the bottom**: when Pangolin was last read (**Updated 14:02**), or **Not answering · last read 14:02**.

While Pangolin is open it is read every 30 seconds (change it in Settings). Nothing is read once it closes, and nothing runs in the background.

### Sites

Each site shows whether it is online. Tap one for its page:

- **SITE**: **Status** (**Online** or **Offline**), **Type**, **Address**, **Newt version**, **Exit node** and **Identifier**.
- **DATA**: **Data in** and **Data out**.
- **RESOURCES**: the resources that run through this site.

### Public resources

The resources people reach from outside. Each shows its health (**Healthy**, **Degraded**, **Offline**) and its address. Tap one for its page:

- **RESOURCE**: **Enabled** (a switch), **Health**, **Address** and **Protocol**.
- **ACCESS**:
  - **Require sign-in**: Pangolin's sign-in page before the resource. Turning it off asks **Turn off sign-in?** first, because anyone who knows the address can then reach it unless it has a password, PIN or other protection.
  - **Block access**: turns every visitor away without disabling the resource.
  - **Protection**: what protects it (sign-in, **Password**, **PIN**, **Email whitelist**, **Header auth**).
- **TARGETS**: each backend with its own health, so you see which one is down (**Disabled** or **No health check** when it has none).
- **SITES**: the sites it runs through.

### Private resources

Resources that only clients on your private network can reach. Tap one: **Enabled** (a switch), **Mode**, **Destination**, **Alias**, **Alias address**, **TCP ports**, **UDP ports**, **Ping (ICMP)** (**Allowed** or **Blocked**) and its **SITES**.

### Clients

Machines and user devices. Tap one:

- **CLIENT**: **Status**, **Kind** (**Machine** or **User device**), **User**, **Version**, **Platform**, **Device**, **Last seen**, **Data in** and **Data out**.
- **ACCESS**: **Blocked** (it can't connect until unblocked) and **Archived** (put away; it can't connect while archived), each a switch.

## The menu

The **⋮** menu has:

- **Reset bandwidth**: every site's data in and out goes back to zero. It asks **Reset bandwidth?** first, because the counts can't be put back.
- **Details**: the **Organization**, **Organization ID**, **API URL** and **API key** (only its ID is shown), and the **COUNTS** of sites, resources and clients with the **Data through the sites**.
- **Help**: a short version of what you need.
- **Recent apps**, **Light**, **Night mode** and **Refresh screen**, as in the other apps.
- **Settings**, always last.

## Settings

The same page opens from the launcher's **Settings** list, under **Optional apps > Pangolin**.

- **DISPLAY**
  - **Read every**: how often Pangolin is read while the app is open, from 10 seconds to 5 minutes.
- **NOTIFICATIONS**
  - **Sites and resources going offline**: a notification in the bell, seen while Pangolin is read; it goes when they are back. Tap it to open Pangolin.
- **CONNECTION**
  - **API URL**, **API key** and **Organization**. The key shows only its end.
  - **Test connection**: checks the API, then the key and the organization.
  - **Remove connection**: forgets the address, key and organization. **Undo** at the bottom of the screen takes it back for a few seconds.

The web page's backup (**System**) includes these settings; the key only if you tick **Include keys and sign-ins**.

## On the web page

The web page (see the Web server chapter) has a **Pangolin** tab:

- The status, with **Refresh** and **Reset bandwidth** (asks first).
- **Sites**, **Public resources**, **Private resources** and **Clients**, with a switch each: **Require sign-in** and **Enabled** for public resources, **Enabled** for private ones, **Blocked** and **Archived** for clients.
- **Settings**: **Read every**, the notification switch, and the **API URL**, **API key** and **Organization ID**, with **Save** and **Test connection**.

## Good to know

- **The key stays on the Kindle** and is only sent to your Pangolin server.
- **Turn off sign-in** carefully: a public resource without it is open to anyone who knows its address, unless it has another protection.
- **Reset bandwidth** can't be undone.
- Nothing is read while the Kindle sleeps or Pangolin is closed, so a site that goes offline then shows up the next time the launcher's tile, a quick button or the app reads Pangolin.
