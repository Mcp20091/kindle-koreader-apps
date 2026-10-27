-- Plain tests for pgmodel and pgapi (no KOReader): luajit tests/run.lua
package.path = "./?.lua;" .. package.path

-- pgapi's JSON: answers by their text (the stand-in network below sends these keys).
local ANSWERS = {}
package.preload.json = function()
    return {
        encode = function(t)
            local keys = {}
            for k, v in pairs(t) do keys[#keys + 1] = k .. "=" .. tostring(v) end
            table.sort(keys)
            return "{" .. table.concat(keys, ",") .. "}"
        end,
        decode = function(s)
            if ANSWERS[s] == nil then error("not JSON") end
            return ANSWERS[s]
        end,
    }
end

local M = require("pgmodel")
local API = require("pgapi")

local passed, failed = 0, 0
local function eq(got, want, what)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- the address and key
eq(M.cleanUrl(" api.example.com "), "https://api.example.com", "url: https added")
eq(M.cleanUrl("https://api.example.com/v1/"), "https://api.example.com", "url: /v1 taken off")
eq(M.cleanUrl("http://192.168.1.50:3003"), "http://192.168.1.50:3003", "url: http kept")
eq(M.cleanUrl("  "), nil, "url: empty")
eq(M.apiBase("api.example.com"), "https://api.example.com/v1", "api base")
eq(M.keyId("abc123.s3cretvalue"), "abc123", "key id")
eq(M.keyId("nodot"), nil, "key without id")
eq(M.masked("abcdef"), "••••ef", "masked")
eq(M.query({ pageSize = 100, page = 1, status = "active,blocked" }), "page=1&pageSize=100&status=active%2Cblocked", "query")

-- health and sizes
eq(M.health("unhealthy"), "offline", "health: older word")
eq(M.health("degraded"), "degraded", "health degraded")
eq(M.health(nil), "unknown", "health none")
eq(M.healthText("healthy"), "Healthy", "health text")
eq(M.size(0.42), "420 KB", "size KB")
eq(M.size(12.34), "12.3 MB", "size MB")
eq(M.size(1234), "1.2 GB", "size GB")
eq(M.ago(1000, 1030), "Just now", "ago now")
eq(M.ago(1000, 1000 + 300), "5 min ago", "ago minutes")
eq(M.ago(1000, 1000 + 7300), "2 h ago", "ago hours")
eq(M.ago(1000, 1000 + 86400 * 3), "3 days ago", "ago days")
local function fakeDate(f) return ({ ["%I:%M %p"] = "02:35 PM", ["%H:%M"] = "14:35" })[f] end
eq(M.clock(0, false, fakeDate), "2:35 PM", "clock 12-hour")
eq(M.clock(0, true, fakeDate), "14:35", "clock 24-hour")

-- the lists (null as JSON's own value: not a string or number)
local NULL = function() end
local raw = {
    org = { orgId = "home", name = "Home lab" },
    sites = {
        { siteId = 2, name = "Workshop", niceId = "workshop", online = true, type = "newt", address = "10.0.0.2",
          newtVersion = "1.5.0", exitNodeName = "Exit 1", megabytesIn = 12.5, megabytesOut = 3 },
        { siteId = 1, name = "cabin", niceId = "cabin", online = false, type = "newt", status = "approved" },
        { siteId = 3, name = "New site", online = false, type = "newt", status = "pending" },
    },
    resources = {
        { resourceId = 10, name = "Photos", fullDomain = "photos.example.com", enabled = true, health = "healthy",
          sso = 1, whitelist = 0, passwordId = NULL, pincodeId = 4, headerAuthId = NULL,
          targets = { { targetId = 1, siteName = "Workshop", ip = "192.168.1.20", port = 8080, enabled = true,
                        hcEnabled = true, healthStatus = "healthy" } },
          sites = { { siteName = "Workshop", online = true } } },
        { resourceId = 11, name = "Wiki", fullDomain = "wiki.example.com", enabled = true, health = "unhealthy",
          sso = 0, targets = {}, sites = { { siteName = "cabin", online = false } } },
        { resourceId = 12, name = "Old", fullDomain = "old.example.com", enabled = false, health = "offline", sso = 0 },
        { resourceId = 13, name = "Media", enabled = true, health = "degraded", sso = 1 },
    },
    private = {
        { siteResourceId = 5, name = "NAS", mode = "host", destination = "192.168.1.42", enabled = true,
          siteNames = { "Workshop" }, siteOnlines = { true }, disableIcmp = false, tcpPortRangeString = "445" },
    },
    machines = { { clientId = 7, name = "backup-box", online = true, blocked = false, archived = false } },
    devices = {
        { clientId = 8, name = "Pat's laptop", online = false, username = "pat", olmVersion = "1.2.0", lastSeen = 1000 },
        { clientId = 9, name = "Old phone", online = false, archived = true },
    },
    skipped = {},
}
local d = M.data(raw)
eq(d.orgName, "Home lab", "org name")
eq(d.sites[1].name, "cabin", "sites by name, any case")
eq(d.sites[3].name, "Workshop", "sites by name, last")
eq(d.sites[3].newt, "1.5.0", "site newt version")
eq(M.siteLine(d.sites[3]), "Newt · 10.0.0.2", "site line")
eq(M.siteLine(d.sites[2]), "Waiting for approval · Newt", "site line pending")
local photos = M.find(d, "resource", 10)
eq(photos.sso, true, "sso as a number is on")
eq(photos.password, false, "null password is off")
eq(photos.pin, true, "pincode id is on")
eq(photos.whitelist, false, "whitelist 0 is off")
eq(M.protection(photos), "Sign-in, PIN", "protection in words")
eq(M.protection(M.find(d, "resource", 11)), "None", "no protection")
eq(photos.targets[1].target, "192.168.1.20:8080", "target host and port")
eq(M.find(d, "resource", 11).health, "offline", "unhealthy is offline")
eq(M.resourceLine(photos), "photos.example.com · Healthy", "resource line")
eq(M.resourceLine(M.find(d, "resource", 12)), "old.example.com · Disabled", "resource line disabled")
eq(M.find(d, "resource", 13).name, "Media", "resource without a domain keeps its name")
local nas = M.find(d, "private", 5)
eq(M.privateLine(nas), "Host · 192.168.1.42", "private line")
eq(nas.icmp, true, "icmp allowed")
eq(nas.sites[1].online, true, "private resource's site online")
eq(d.clients[1].name, "backup-box", "clients: online first")
eq(d.clients[3].name, "Old phone", "clients: archived last")
eq(M.clientLine(d.clients[2]), "User device · pat · Offline", "client line")
eq(M.clientLine(d.clients[3]), "User device · Archived", "client line archived")
eq(M.find(d, "client", 8).lastSeen, 1000, "last seen")

-- the organization at a glance
local c = M.counts(d)
eq(c.sitesOnline .. "/" .. c.sites, "1/3", "sites online")
eq(c.resourcesDown, 1, "a disabled resource isn't down")
eq(c.resourcesDegraded, 1, "degraded")
eq(c.clients, 2, "archived clients not counted")
eq(c.clientsOnline, 1, "clients online")
eq(M.summary(d), "1 site offline · 1 resource down · 1 degraded", "summary (a pending site isn't offline)")
local att = M.attention(d)
eq(#att, 3, "attention: the offline site, the down and the degraded resource")
eq(att[1].kind .. ":" .. att[1].item.name, "site:cabin", "attention: sites first")
eq(att[3].why, "Resource degraded", "attention: degraded last")
eq(M.appsLine(nil, false), "Not set up", "line: not set up")
eq(M.appsLine(nil, true), "Open to read Pangolin", "line: not read")
eq(M.appsLine(d, true), "1 site offline · 1 resource down · 1 degraded", "line: problems")
local fine = M.data({ sites = { { siteId = 1, name = "A", online = true }, { siteId = 2, name = "B", online = true } } })
eq(M.appsLine(fine, true), "All online · 2 sites", "line: all online")
eq(M.data({}).skipped.resources, nil, "nothing skipped")
eq(M.data({ skipped = { resources = "forbidden" } }).skipped.resources, "forbidden", "skipped kept")

-- notifications: going offline, and back
local function org(siteOnline, health, enabled)
    return M.data({ sites = { { siteId = 1, name = "Workshop", online = siteOnline } },
        resources = { { resourceId = 10, name = "Photos", enabled = enabled ~= false, health = health } } })
end
eq(#M.changes(nil, org(false, "offline")).add, 0, "first read says nothing")
local ch = M.changes(org(true, "healthy"), org(false, "offline"))
eq(#ch.add, 2, "site and resource gone offline")
eq(ch.add[1].key, "pangolin:site:1", "site key")
eq(ch.add[1].text, "Site offline: Workshop", "site text")
eq(ch.add[2].text, "Resource offline: Photos", "resource text")
eq(#M.changes(org(false, "offline"), org(false, "offline")).add, 0, "still offline: nothing new")
ch = M.changes(org(false, "offline"), org(true, "healthy"))
eq(table.concat(ch.remove, ","), "pangolin:site:1,pangolin:resource:10", "back online: notifications go")
eq(#M.changes(org(true, "healthy", false), org(true, "offline", false)).add, 0, "a disabled resource isn't news")
eq(#M.changes(org(true, "healthy"), org(true, "degraded")).add, 0, "degraded isn't offline")

-- search
local hits = M.search(d, "example")
eq(#hits, 3, "search by domain")
eq(M.search(d, "pat")[1].item.id, 8, "search clients by user")
eq(M.search(d, "192.168.1.42")[1].kind, "private", "search private by destination")
eq(#M.search(d, ""), 0, "empty search")

-- the API: what each answer means (a stand-in network)
local sent = {}
local function net(answers)
    return function(method, url, headers, body)
        table.insert(sent, { method = method, url = url, headers = headers, body = body })
        for pat, a in pairs(answers) do
            if url:find(pat) then return a[1], a[2] end
        end
        return "connection refused", ""
    end
end
ANSWERS['{"orgok"}'] = { data = { org = { orgId = "home", name = "Home lab" } }, success = true }
ANSWERS['{"sites1"}'] = { data = { sites = { { siteId = 1 }, { siteId = 2 } }, pagination = { total = 3 } }, success = true }
ANSWERS['{"sites2"}'] = { data = { sites = { { siteId = 3 } }, pagination = { total = 3 } }, success = true }
ANSWERS['{"bad"}'] = { error = true, success = false, message = "Resource not editable" }
ANSWERS['{"ok"}'] = { data = NULL, success = true }
ANSWERS['{"healthy"}'] = { message = "Healthy" }
local api = API.new({ url = "api.example.com", key = "abc.secret", org = "home" }, net({
    ["/org/home$"] = { 200, '{"orgok"}' },
    ["/org/home/sites%?page=1&"] = { 200, '{"sites1"}' },
    ["/org/home/sites%?page=2&"] = { 200, '{"sites2"}' },
    ["/org/home/resources"] = { 403, "" },
    ["/org/home/private%-resources"] = { 404, "" },
    ["/org/home/clients"] = { 200, '{"ok"}' },
    ["/org/home/user%-devices"] = { 404, "" },
    ["/resource/10$"] = { 400, '{"bad"}' },
    ["/v1/$"] = { 200, '{"healthy"}' },
}))
local o = api:organization()
eq(o and o.name, "Home lab", "organization read")
eq(sent[1].headers.Authorization, "Bearer abc.secret", "key as a bearer token")
eq(sent[1].url, "https://api.example.com/v1/org/home", "the address with /v1")
local all = api:readAll()
eq(all and #all.sites, 3, "every page of a list")
eq(all and all.skipped.resources, "forbidden", "a list the key can't read is skipped")
eq(all and all.skipped.private, "notfound", "a list this Pangolin doesn't have is skipped")
eq(all and all.skipped.devices, nil, "no user devices on an older Pangolin isn't missing")
local okU, whyU = api:updateResource(10, { enabled = false })
eq(okU, nil, "a refused change")
eq(whyU, "Resource not editable", "Pangolin's message")
eq(api:ping(), true, "health check")
local function one(status, body)
    return API.new({ url = "api.example.com", key = "k", org = "home" }, function() return status, body end)
end
eq(select(2, one(401, ""):organization()), "signin", "401 is the key")
eq(select(2, one(403, ""):organization()), "forbidden", "403 is a permission")
eq(select(2, one(200, "<!DOCTYPE html><html>"):organization()), "notapi", "a web page isn't the API")
eq(select(2, one("timeout", nil):organization()), "timeout", "the network's words")
eq(select(2, one(403, ""):readAll()), "forbidden", "can't read the organization")
local sitesNo = API.new({ url = "x", key = "k", org = "home" }, net({ ["/org/home$"] = { 200, '{"orgok"}' }, ["/sites"] = { 403, "" } }))
eq(select(2, sitesNo:readAll()), "forbidden:List Sites", "sites need List Sites")
eq(select(2, one(404, "<html>"):ping()), "notapi", "ping: not the API")

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
