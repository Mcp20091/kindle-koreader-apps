# NextDNS for KOReader

Your [NextDNS](https://nextdns.io) profile on a Kindle, over NextDNS's API and your account's API key. Unofficial: not affiliated with or endorsed by NextDNS.

- **Today**: how many queries there were and how many were blocked (with the share), and the domains blocked most. Tap a domain to block or allow it.
- **This Kindle**: whether the Kindle's own DNS goes through NextDNS, and with which profile (test.nextdns.io).
- **Recent queries**: the query log, all of it or only the blocked or allowed queries, and a search. Tap a query to block or allow its domain.
- **Denylist and allowlist**: each domain with a switch to turn it off without deleting it; **+** adds one; hold one to delete it (with Undo) or move it to the other list.
- **Protection**: the security switches (threat intelligence feeds, AI threat detection, newly registered domains, parked domains…), the privacy ones (disguised trackers, affiliate links) and parental control's (safe search, restricted video mode, block bypass methods).
- **Profile**: pick another of the account's profiles (⋮ > Profile).
- **Setting up**: the API key, then the profile (picked for you when there's one).
- **With the launcher**: its tile (`ShowNextDNS`, line "1,872 blocked today · 15%"), Settings, search (list entries, top blocked domains, switches), a step in Set up your Kindle, quick buttons (today's blocked count, and any protection switch on or off), Test connection (the key, the profile, this Kindle), the backup (the key only with Include keys and sign-ins), and a NextDNS tab on the web page.
- **Gesture**: **NextDNS** (opens it).

Nothing runs in the background: NextDNS is read while the app is open (every minute; Settings > Read every), and when the launcher's tile or a quick button shows it. The query log is read when its page opens, and with ⟳.

## Install

An optional app: it isn't in the main install zip. Settings > Updates > **Optional apps** on the Kindle, or unzip `kindle-nextdns.zip` (from a release) into `koreader/plugins/` and restart KOReader. It works without the launcher, with KOReader's own dialogs.

The API's paths and fields follow NextDNS's API as described by [nextdns-mcp](https://github.com/dmeiser/nextdns-mcp) (MIT), used only as a reference. Icons: [Lucide](https://lucide.dev) (ISC).
