-- Plain tests for ffmodel (no KOReader): luajit tests/run.lua
package.path = "./?.lua;" .. package.path

local M = require("ffmodel")

local passed, failed = 0, 0
local function eq(got, want, what)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- states (the Creator 5 Pro's "pause" is paused too)
eq(M.state("printing"), "printing", "state printing")
eq(M.state("PAUSE"), "paused", "state pause")
eq(M.state("paused"), "paused", "state paused")
eq(M.state("calibrate_doing"), "calibrating", "state calibrating")
eq(M.state("downloading"), "busy", "state downloading is busy")
eq(M.state("something new"), "unknown", "state unknown")
eq(M.state(nil), "unknown", "state none")
eq(M.canPause("printing"), true, "pause while printing")
eq(M.canPause("paused"), false, "no pause while paused")
eq(M.canResume("paused"), true, "resume while paused")
eq(M.active("ready"), false, "ready isn't a print")
eq(M.canClear("completed"), true, "clear after a print")

-- times and temperatures
eq(M.duration(30), "Under a minute", "duration short")
eq(M.duration(720), "12 min", "duration minutes")
eq(M.duration(3600), "1 h", "duration an hour")
eq(M.duration(3900), "1 h 5 min", "duration hours and minutes")
eq(M.temp({ cur = 211.6, set = 220 }), "212 / 220 °C", "temp with target")
eq(M.temp({ cur = 24, set = 0 }), "24 °C", "temp without target")
eq(M.percent(0.424), "42%", "percent")
local function fakeDate(f) return ({ ["%I:%M %p"] = "02:35 PM", ["%H:%M"] = "14:35" })[f] end
eq(M.clock(0, false, fakeDate), "2:35 PM", "clock 12-hour")
eq(M.clock(0, true, fakeDate), "14:35", "clock 24-hour")

-- /detail
local d = {
    name = "Workshop", pid = 38, status = "printing", printProgress = 0.42, printLayer = 120, targetPrintLayer = 300,
    estimatedTime = 3900, printDuration = 2400, printFileName = "Benchy.3mf", rightTemp = 219.8, rightTargetTemp = 220,
    platTemp = 55, platTargetTemp = 55, chamberTemp = -108, lightStatus = "open", errorCode = "0",
    firmwareVersion = "1.1.7", ipAddr = "192.168.1.50",
    matlStationInfo = { currentSlot = 2, slotCnt = 4, slotInfos = {
        { slotId = 2, hasFilament = true, materialName = "PLA", materialColor = "#FFFFFF" },
        { slotId = 1, hasFilament = true, materialName = "PLA", materialColor = "#FF0000" },
        { slotId = 3, hasFilament = false, materialName = "", materialColor = "" },
        { slotId = 5, hasFilament = true, materialName = "PLA", materialColor = "#000000" },
    } },
}
local i = M.info(d)
eq(i.model, "AD5X", "info model from pid")
eq(i.isAD5X, true, "info AD5X")
eq(i.isC5, false, "info not a Creator 5")
eq(i.state, "printing", "info state")
eq(i.chamber, nil, "info no chamber (-108)")
eq(i.light, true, "info light")
eq(i.error, nil, "info error 0 is none")
eq(#i.slots, 3, "info slots 1 to 4 only")
eq(i.slots[1].id, 1, "info slots in order")
eq(i.slots[3].empty, true, "info empty slot")
eq(i.hasStation, true, "info has a station")
eq(i.hasFiltration, false, "info AD5X has no filtration")
eq(M.summary(i), "Printing · 42%", "summary printing")
eq(M.appsLine(i, true), "Printing 42% · 1 h 5 min left", "appsLine printing")
eq(M.appsLine(nil, true), "Open to read the printer", "appsLine not read")
eq(M.appsLine(nil, false), "No printer set up", "appsLine not set up")
local lines = M.jobLines(i, 0, true, fakeDate)
eq(lines[1], "Layer 120 of 300", "jobLines layers")
eq(lines[2], "1 h 5 min left · done at 14:35", "jobLines left and done at")
eq(lines[3], "Printing for 40 min", "jobLines printing for")
i.state = "paused"
eq(M.jobLines(i, 0, true, fakeDate)[2], "1 h 5 min left", "jobLines no done-at while paused")
eq(M.summary(i), "Paused · 42%", "summary paused")

local c5 = M.info({ pid = 41, status = "pause", nozzleTemps = { 200, 0 }, nozzleTargetTemps = { 210 }, chamberTemp = 35,
    chamberTargetTemp = 40, doorStatus = "open", errorCode = "E0012", tvoc = 3, internalFanStatus = "open" })
eq(c5.isC5Pro, true, "info Creator 5 Pro")
eq(c5.state, "paused", "info C5 pause")
eq(#c5.tools, 2, "info per-tool temps")
eq(c5.tools[2].set, 0, "info missing target is 0")
eq(M.temp(c5.chamber), "35 / 40 °C", "info chamber")
eq(c5.door, true, "info door open")
eq(c5.error, "E0012", "info error code")
eq(c5.filtration, "internal", "info filtration")
eq(c5.hasFiltration, true, "info C5 Pro filtration")
eq(c5.name, "Creator 5 Pro", "info name falls back to the model")
c5.state = "error"
eq(M.summary(c5), "Error E0012", "summary error")
eq(M.info({ name = "Adventurer 5M Pro" }).isPro, true, "info Pro by name without pid")

-- colours
eq(M.colorName("#FF0000"), "Red", "colorName red")
eq(M.colorName("#FFFFFF"), "White", "colorName white")
eq(M.colorName("#101010"), "Black", "colorName black")
eq(M.colorName("nope"), "", "colorName not a colour")
eq(M.grey("#FFFFFF"), 255, "grey white")
eq(M.grey("#000000"), 0, "grey black")
eq(M.slotText({ material = "PLA", color = "#FF0000" }), "PLA · Red", "slotText")
eq(M.slotText({ empty = true }), "Empty", "slotText empty")

-- files
local files = M.files({ gcodeListDetail = {
    { gcodeFileName = "Box.3mf", printingTime = 4800, totalFilamentWeight = 35.2, gcodeToolCnt = 2, gcodeToolDatas = {
        { toolId = 0, materialName = "PLA", materialColor = "#FF0000", slotId = 1, filamentWeight = 20 },
        { toolId = 1, materialName = "PLA", materialColor = "#FFFFFF", slotId = 2, filamentWeight = 15 },
    } },
    { gcodeFileName = "Clip.gcode", printingTime = 0 },
} })
eq(#files, 2, "files detail")
eq(files[1].tools[2].color, "#FFFFFF", "files tools")
eq(files[2].time, nil, "files no time")
eq(M.fileLine(files[1]), "1 h 20 min · 35 g · 2 materials", "fileLine")
local bare = M.files({ gcodeList = { "A.gcode", "B.3mf" } })
eq(#bare, 2, "files bare names")
eq(bare[1].known, false, "files bare names unknown tools")
eq(#M.files(nil), 0, "files none")

-- matching
local slots = M.slots(d.matlStationInfo)
eq(M.needsMatching(files[1], slots), true, "needsMatching with tools and slots")
eq(M.needsMatching(bare[1], slots), false, "needsMatching without tools")
eq(M.needsMatching(files[1], {}), false, "needsMatching without a station")
local auto = M.autoMatch(files[1], slots)
eq(auto[0], 1, "autoMatch the slicer's slot")
eq(auto[1], 2, "autoMatch second tool")
local swapped = { tools = { { id = 0, material = "PLA", color = "#FFFFFF", slot = 4 } } }
eq(M.autoMatch(swapped, slots)[0], 2, "autoMatch by colour")
local petg = { tools = { { id = 0, material = "PETG", color = "", slot = 1 } } }
eq(M.autoMatch(petg, slots)[0], nil, "autoMatch no such material")
local ok, why = M.validate(files[1], slots, auto)
eq(ok and #ok, 2, "validate good")
eq(ok and ok[1].materialName, "PLA", "validate material name")
eq(ok and ok[1].slotMaterialColor, "#FF0000", "validate colour from the slot")
ok, why = M.validate(files[1], slots, { [0] = 1 })
eq(ok, nil, "validate missing tool")
eq(why, "Choose a slot for tool 2.", "validate missing tool why")
ok, why = M.validate(files[1], slots, { [0] = 1, [1] = 1 })
eq(why, "Slot 1 is used by two tools.", "validate slot twice")
ok, why = M.validate(files[1], slots, { [0] = 1, [1] = 3 })
eq(why, "Slot 3 is empty. Load filament before starting this print.", "validate empty slot")
ok, why = M.validate(petg, slots, { [0] = 1 })
eq(why, "Tool 1 needs PETG, but slot 1 has PLA.", "validate wrong material")
ok, why = M.validate(files[1], slots, { [0] = 1, [1] = 2, [5] = 4 })
eq(ok, nil, "validate extra tool")
eq(M.slotProblem(files[1].tools[2], slots[1], { [0] = 1 }), "Used by tool 1", "slotProblem taken")
eq(M.slotProblem(petg.tools[1], slots[1], {}), "PLA, not PETG", "slotProblem material")
eq(M.slotProblem(files[1].tools[1], slots[1], {}), nil, "slotProblem fine")
local warn = M.colorWarnings(M.validate(swapped, slots, { [0] = 1 }) or {})
eq(warn[1], "Tool 1 was sliced for White, slot 1 holds Red.", "colorWarnings")
eq(#M.colorWarnings(M.validate(files[1], slots, auto)), 0, "colorWarnings none")
local m = M.mapping({ id = 0, material = " PLA ", color = "bad" }, { id = 1, material = "PLA", color = "" })
eq(m.materialName, "PLA", "mapping trims")
eq(m.toolMaterialColor, "#808080", "mapping fallback colour")

-- print requests
eq(M.newFirmware("3.1.3"), true, "newFirmware equal")
eq(M.newFirmware("3.2.0"), true, "newFirmware newer")
eq(M.newFirmware("2.7.9"), false, "newFirmware older")
eq(M.newFirmware(""), false, "newFirmware unknown")
local b = M.printBody(M.info({ pid = 35, firmwareVersion = "3.1.5" }), "A.gcode", true)
eq(b.useMatlStation, false, "printBody 5M new")
eq(b.levelingBeforePrint, true, "printBody leveling")
b = M.printBody(M.info({ pid = 35, firmwareVersion = "2.7.0" }), "A.gcode", false)
eq(b.useMatlStation, nil, "printBody 5M old")
b = M.printBody(i, "Box.3mf", false, M.validate(files[1], slots, auto))
eq(b.useMatlStation, true, "printBody AD5X multi")
eq(b.gcodeToolCnt, 2, "printBody AD5X tool count")
b = M.printBody(i, "Clip.gcode", false)
eq(b.useMatlStation, false, "printBody AD5X single")
b = M.printBody(c5, "X.3mf", false)
eq(b.materialMappings, nil, "printBody C5 without mappings")
eq(b.useMatlStation, nil, "printBody C5 sends no station flag")

-- small things
eq(M.filtrationArgs("external").external, "open", "filtration external")
eq(M.filtrationArgs("off").internal, "close", "filtration off")
eq(M.masked("12345678"), "••••••78", "masked")
eq(M.isIp("192.168.1.50"), true, "isIp")
eq(M.isIp("192.168.1.256"), false, "isIp too big")
eq(M.isIp("printer.local"), false, "isIp a name")

-- discovery
local function answer(name, pid, serial)
    local buf = name .. string.rep("\0", 0x84 - #name)
    buf = buf .. "\0\0" .. "\0\0" .. string.char(math.floor(pid / 256), pid % 256)
    buf = buf .. string.rep("\0", 0x92 - #buf) .. serial
    return buf .. string.rep("\0", 276 - #buf)
end
local p = M.parseDiscovery(answer("Workshop", 38, "SN0000000001"), "192.168.1.50")
eq(p.name, "Workshop", "discovery name")
eq(p.serial, "SN0000000001", "discovery serial")
eq(p.model, "AD5X", "discovery model")
eq(p.supported, true, "discovery supported")
eq(M.parseDiscovery(string.rep("\0", 140), "192.168.1.10").supported, false, "discovery older printer")
eq(M.parseDiscovery("short", "192.168.1.42"), nil, "discovery too short")

-- base64 (thumbnails), without KOReader
package.preload.json = function() return {} end
local API = require("ffapi")
eq(API.unbase64("SGVsbG8="), "Hello", "unbase64")
eq(API.unbase64("iVBORw0K\nGgo="), "\137PNG\r\n\26\n", "unbase64 PNG start, with a line break")

print(passed .. " passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
