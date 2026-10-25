-- Plain tests for stmodel (no KOReader): luajit tests/run.lua
package.path = "./?.lua;" .. package.path

local M = require("stmodel")

local passed, failed = 0, 0
local function eq(got, want, what)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- sizes
eq(M.bytes(0), "0 B", "bytes zero")
eq(M.bytes(999), "999 B", "bytes under a KB")
eq(M.bytes(18400), "18 KB", "bytes KB")
eq(M.bytes(1800000000), "1.8 GB", "bytes GB with a decimal")
eq(M.bytes(212000000), "212 MB", "bytes MB")

-- times
eq(M.parseTime("1970-01-01T00:00:00Z"), 0, "parseTime epoch")
eq(M.parseTime("2026-10-22T13:26:40Z"), 1792675600, "parseTime UTC")
eq(M.parseTime("2026-10-22T09:26:40.123456789-04:00"), 1792675600, "parseTime offset and fraction")
eq(M.parseTime("2024-02-29T12:00:00+01:00"), 1709204400, "parseTime leap day")
eq(M.parseTime("0001-01-01T00:00:00Z"), nil, "parseTime Syncthing's zero time")
eq(M.parseTime(nil), nil, "parseTime none")
eq(M.ago(1000, 1030), "Just now", "ago just now")
eq(M.ago(1000, 1000 + 600), "10 min ago", "ago minutes")
eq(M.ago(1000, 1000 + 3 * 3600 + 5), "3 h ago", "ago hours")
local function fakeDate(f) return ({ ["%b %d"] = "Oct 01", ["%I:%M %p"] = "08:14 PM", ["%H:%M"] = "20:14" })[f] end
eq(M.ago(1000, 1000 + 86400, fakeDate), "Oct 1, 8:14 PM", "ago date, leading zeros dropped")
eq(M.ago(1000, 1000 + 86400, fakeDate, true), "Oct 1, 20:14", "ago date, 24-hour")
eq(M.clock(0, false, fakeDate), "8:14 PM", "clock 12-hour")
eq(M.clock(0, true, fakeDate), "20:14", "clock 24-hour")

eq(M.shortId("7QK3MZB-RWZ7H3M-QF2L6YD"), "7QK3MZB", "shortId")

-- folders
local f = { label = "Papers" }
eq(M.folderState({ paused = true }, { state = "syncing" }), "Paused", "folderState paused wins")
eq(M.folderState(f, { state = "idle" }), "Up to date", "folderState idle")
eq(M.folderState(f, { state = "syncing", globalBytes = 1000, inSyncBytes = 420 }), "Syncing 42%", "folderState syncing")
eq(select(2, M.folderState(f, { state = "syncing" })), true, "folderState syncing is busy")
eq(M.folderState(f, { state = "scanning" }), "Scanning", "folderState scanning")
eq(M.folderState(f, { state = "idle", needFiles = 2 }), "Out of sync", "folderState idle but needing files")
eq(M.folderState(f, { state = "idle", pullErrors = 1 }), "Out of sync", "folderState pull errors")
eq(M.folderState(f, nil), "Unknown", "folderState no status")

-- devices
eq(M.deviceState({}, { connected = true }, { completion = 100, globalBytes = 5 }), "Connected · 100%", "deviceState connected")
eq(M.deviceState({}, { connected = true }, { completion = 0, globalBytes = 0, needItems = 0 }), "Connected", "deviceState nothing shared")
eq(M.deviceState({ paused = true }, { connected = true }), "Paused", "deviceState paused")
eq(M.deviceState({}, { connected = false }, nil, 1000, 1010), "Last seen just now", "deviceState just now")
eq(M.deviceState({}, nil, nil, 1000, 1000 + 1200), "Last seen 20 min ago", "deviceState minutes")
eq(M.deviceState({}, nil, nil, nil, 0), "Never seen", "deviceState never")

-- the summary line
local function folder(label, state, extra)
    local st = { state = state }
    for k, v in pairs(extra or {}) do st[k] = v end
    return { folder = { label = label }, status = st }
end
eq(M.summary(nil), "Starting…", "summary before the first status")
eq(M.summary({ folders = { folder("Books", "idle") }, deviceCount = 1, connected = 1 }), "Up to date", "summary idle")
eq(M.summary({ folders = { folder("Books", "idle"), folder("Papers", "syncing", { needFiles = 3 }) }, deviceCount = 1, connected = 1 }),
    "Syncing · 3 files left", "summary syncing")
eq(M.summary({ folders = { folder("Papers", "syncing", { needFiles = 1 }) } }), "Syncing · 1 file left", "summary one file")
eq(M.summary({ folders = { folder("Books", "scanning") } }), "Scanning Books", "summary scanning")
eq(M.summary({ folders = { folder("Books", "error") } }), "Errors in Books", "summary errors")
eq(M.summary({ folders = { { folder = { label = "A", paused = true } } } }), "All folders paused", "summary all paused")
eq(M.summary({ folders = { folder("Books", "idle") }, deviceCount = 2, connected = 0 }), "No devices connected", "summary nobody connected")
eq(M.summary({ folders = {}, deviceCount = 0 }), "No folders yet", "summary nothing set up")
eq(M.appsLine(false), "Off", "appsLine off")
eq(M.appsLine(true, { folders = { folder("Books", "idle") } }), "On · Up to date", "appsLine on")
eq(M.devicesLine(1, 2), "1 of 2 connected", "devicesLine")

-- config.xml
local xml = [[
<configuration version="51">
    <folder id="abcd-1234" label="Books" path="/mnt/us/documents/Books" type="sendreceive">
        <device id="AAAAAAA-BBB" introducedBy=""></device>
        <device id="MYIDXXX-YYY" introducedBy=""></device>
        <paused>false</paused>
    </folder>
    <folder id="efgh" label="Tom &amp; Jerry" path="/mnt/us/documents/TJ">
        <paused>true</paused>
    </folder>
    <device id="MYIDXXX-YYY" name="kindle" compression="metadata">
        <address>dynamic</address>
        <paused>false</paused>
    </device>
    <device id="AAAAAAA-BBB" name="Desktop PC" compression="metadata">
        <address>dynamic</address>
        <paused>true</paused>
    </device>
    <gui enabled="true" tls="false">
        <address>0.0.0.0:8384</address>
        <user>syncthing</user>
        <apikey>KEY123abc</apikey>
    </gui>
    <defaults>
        <folder id="" label="" path="~"><paused>false</paused></folder>
        <device id="" compression="metadata"><paused>false</paused></device>
    </defaults>
</configuration>]]
local cfg = M.parseConfig(xml, "MYIDXXX-YYY")
eq(cfg.apikey, "KEY123abc", "parseConfig apikey")
eq(#cfg.folders, 2, "parseConfig folders, defaults left out")
eq(cfg.folders[1].label, "Books", "parseConfig folder label")
eq(cfg.folders[1].paused, false, "parseConfig folder not paused")
eq(cfg.folders[2].label, "Tom & Jerry", "parseConfig label unescaped")
eq(cfg.folders[2].paused, true, "parseConfig folder paused")
eq(#cfg.devices, 1, "parseConfig devices: this Kindle and folder members left out")
eq(cfg.devices[1].name, "Desktop PC", "parseConfig device name")
eq(cfg.devices[1].paused, true, "parseConfig device paused")

eq(M.folderPath("/mnt/us/documents/", "Comics"), "/mnt/us/documents/Comics", "folderPath")
eq(M.folderPath("/mnt/us/documents", "A/B"), "/mnt/us/documents/A_B", "folderPath slash replaced")
eq(M.folderPath(nil, ".."), "/Sync", "folderPath no home, odd label")

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
