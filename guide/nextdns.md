# NextDNS

NextDNS shows your NextDNS profile on the Kindle: how many queries there were today and how many were blocked, the domains blocked most, the query log, the denylist and allowlist, and the switches for security, privacy and parental control. NextDNS is a DNS service that blocks ads, trackers and unsafe sites for every device that uses it.

It talks to NextDNS's API with your account's API key. It isn't made by or endorsed by NextDNS.

## Installing it

NextDNS is an optional app: it isn't in the main install. To add it:

1. Open the launcher's **⋮ > Settings > Updates** and tap the **Optional apps** row (the web page's **System > Updates** has the same list).
2. Tap **Install** next to **NextDNS**. KOReader restarts.

Once it is installed, it is updated with every new version of the primary apps. **Remove** in the same list takes it off again.

By hand: copy `kindle-nextdns.zip` (from the release) to the Kindle, unzip it into `koreader/plugins/` and restart KOReader.

## What you need

- **A NextDNS account** with at least one profile. If it has none, make one on NextDNS's website.
- **The account's API key**: on NextDNS's website, open **Account** and find **API** at the bottom.

## Opening it

- The **NextDNS** tile on the launcher. Its line shows today's count: **1,872 blocked today · 15%**.
- Quick buttons on the launcher (add them in **Settings > Launcher > Quick buttons > Add a button > NextDNS…**, or on the web page's Launcher tab): **Blocked today** (tap reads it again) and any of the **Protection** switches, to turn it on or off. A hold opens NextDNS.
- **Tools** in KOReader's menu > **NextDNS**.
- A gesture: **Settings > Taps and gestures > Gesture manager**, pick a gesture, then **General > NextDNS**.
- The launcher's **recent apps** and its **search**, which finds list entries, the top blocked domains and the switches.

The title bar is the same as in the other apps: **‹** goes back, the house goes to the launcher, the clock with an arrow shows the recent apps; at the right are the time and battery, **⟳** (reads NextDNS again), the bell and **⋮**. A swipe in from the left edge goes back.

## Setting it up

The first time, the screen says **NextDNS isn't set up yet.**

1. Tap **Set up**.
2. Type the **API key** and tap **Next**.
3. If the account has one profile, it is picked for you. With more, pick one from the list.

The Kindle reads NextDNS and says **Connected to …**. If it can't, the message says why: NextDNS can't be reached from this Wi-Fi, it refused the API key, or it doesn't know the profile (pick it again in Settings). If NextDNS says **too many requests for now**, try again in a minute.

The launcher's **Set up your Kindle** has the same step. It can be skipped and done any time later from the app.

## The app

- **Profile** at the top: the profile shown. Tap it to pick another of the account's profiles (also in **⋮ > Profile**).
- **TODAY**: the number of **Queries** (and how many were **allowed by your lists**), and **Blocked** with its share of all queries and a bar.
- **BLOCKED MOST**: the domains blocked most today, with how many queries each. Tap one for a menu (see below).
- **THIS KINDLE**: whether the Kindle's own DNS goes through NextDNS, and with which profile: **Using NextDNS · this profile**, **Using NextDNS · profile abc123**, or **Not using NextDNS**. Tap it to check again.
- **BROWSE**:
  - **Recent queries**
  - **Protection** (how many switches are on, such as **9 of 15 on**)
  - **Denylist**
  - **Allowlist**
- **At the bottom**: when NextDNS was last read (**Updated 14:02**).

While NextDNS is open it is read every minute (change it in Settings). Nothing is read once it closes, and nothing runs in the background.

### Tapping a domain

In **BLOCKED MOST** and in the query log, tapping a domain opens a menu:

- **Block (add to the denylist)**, or **Take off the denylist** when it is already there.
- **Allow (add to the allowlist)**, or **Take off the allowlist** when it is already there.
- **Search the queries for it**.

### Recent queries

The query log, newest first, each with its domain, the device, the time and the reason (such as `Laptop · 14:35 · Ads & trackers`), and **Blocked** or **Allowed**. At the top, rows of choices:

- **All**, **Blocked** or **Allowed**: which queries to show.
- **All devices**, or one device's name. Tap it to pick a device from a page of today's devices, busiest first; **Find a device** searches them by part of the name, such as `laptop`.
- A search: type a domain or part of one, such as `example`. The search then shows as `“example” · Clear`; tap it to clear.

Tap a query to block or allow its domain. **Show more** reads older queries. The log is read when its page opens, and again with **⟳**.

### Protection

Switches for the account's profile, in three groups, each applied at once:

- **SECURITY**: **Threat intelligence feeds**, **AI threat detection**, **Safe browsing list**, **Block cryptojacking**, **DNS rebinding protection**, **Look-alike domain protection**, **Typosquatting protection**, **Block generated domains**, **Block newly registered domains**, **Block dynamic DNS hostnames**, **Block parked domains** and **Block child sexual abuse material**.
- **PRIVACY**: **Block disguised trackers** and **Allow affiliate links**.
- **PARENTAL CONTROL**: **Safe search**, **Restricted video mode** and **Block bypass methods**.

The rest (blocklists, native tracking, the services and categories of parental control) is on NextDNS's website.

### Denylist and allowlist

Two lists of domains: the **Denylist** is always blocked, with all its subdomains, such as `example.com`; the **Allowlist** is never blocked.

- Each domain has a switch that turns it off without deleting it.
- **+** adds a domain. Type it, such as `example.com`.
- Hold a domain to delete it (**Undo** at the bottom of the screen takes it back for a few seconds), or to move it to the other list.

## The menu

The **⋮** menu has:

- **Profile**: pick another of the account's profiles.
- **Help**: a short version of this chapter.
- **Recent apps**, **Light**, **Night mode** and **Refresh screen**, as in the other apps.
- **Settings**, always last.

## Settings

The same page opens from the launcher's **Settings** list, under **Optional apps > NextDNS**.

- **DISPLAY**
  - **Read every**: how often NextDNS is read while the app is open, from 30 seconds to 10 minutes.
- **CONNECTION**
  - **API key**: shows only its end.
  - **Profile**: the one shown; tap to pick another.
  - **Test connection**: checks the key, the profile and this Kindle.
  - **Remove connection**: forgets the key and the profile. **Undo** at the bottom of the screen takes it back for a few seconds.

The web page's backup (**System**) includes these settings; the key only if you tick **Include keys and sign-ins**.

## On the web page

The web page (see the Web server chapter) has a **NextDNS** tab:

- The summary: today's queries and blocked ones, whether this Kindle uses NextDNS, and **Refresh**.
- **Blocked most today**, each domain with **Block** and **Allow**.
- **Recent queries** with a search box (**Search**, **Clear**, **Refresh**) and **Show more**.
- The **Denylist** and **Allowlist**, with a switch, a move button and a delete for each, and a box to add a domain.
- **Protection**: the same switches as on the Kindle.
- **Settings**: **Read every**, the **API key** and the **Profile**, with **Save** and **Test connection**.

## Good to know

- **The key stays on the Kindle** and is only sent to NextDNS.
- **This Kindle** tells you whether the Kindle's own traffic goes through NextDNS. If it says **Not using NextDNS**, setting the Kindle (or your router) to use NextDNS is done in NextDNS's setup, not here.
- Changes take effect on NextDNS at once, for every device that uses the profile.
- Nothing is read while the Kindle sleeps or NextDNS is closed.
