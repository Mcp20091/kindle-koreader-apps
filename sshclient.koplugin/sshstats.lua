--[[--
A host's status in plain Lua (tested): one command per system prints what
SSH shows (uptime, CPU, memory, disk, temperature, IP, load, the system,
users, failed services, Docker's containers…) as `key=value` lines; here
it's read, turned into tiles and the main page's short line, and checked
against alerts. Also each system's quick commands, Docker's and services'
actions, commands with blanks ({service}), ~/.ssh/config, Wake on LAN's
packet and a folder's listing for Files.
]]

local S = {}

-- ------------------------------------------------------------------ the stats

-- Every stat: id, name, icon, a line saying what it is, on by default.
-- `systems`: where it can be read (nil: everywhere).
S.STATS = {
    { id = "uptime", name = "Uptime", icon = "clock", on = true },
    { id = "temp", name = "Temperature", icon = "thermometer", sub = "The CPU's", on = true, systems = { linux = true, bsd = true } },
    { id = "cpu", name = "CPU", icon = "cpu", sub = "Used now", on = true },
    { id = "mem", name = "Memory", icon = "memory-stick", on = true },
    { id = "disk", name = "Disk", icon = "hard-drive", sub = "The main disk", on = true },
    { id = "ip", name = "IP address", icon = "network", on = true },
    { id = "load", name = "Load", icon = "activity", sub = "1, 5 and 15 minutes", systems = { linux = true, macos = true, bsd = true } },
    { id = "sys", name = "System", icon = "info", sub = "Its name and version" },
    { id = "users", name = "Signed in", icon = "users", sub = "Users now", systems = { linux = true, macos = true, bsd = true } },
    { id = "failed", name = "Failed services", icon = "triangle-alert", sub = "systemd", systems = { linux = true } },
    { id = "services", name = "Services", icon = "server", sub = "Running, and the ones you pick", systems = { linux = true } },
    { id = "docker", name = "Docker", icon = "box", sub = "Containers running, and the list (where Docker is found)", on = true },
    { id = "swap", name = "Swap", icon = "layers", systems = { linux = true, bsd = true } },
    { id = "procs", name = "Processes", icon = "list", systems = { linux = true, bsd = true } },
}

S.byId = {}
for __, st in ipairs(S.STATS) do S.byId[st.id] = st end

--- A system's family: "linux", "macos", "windows", "bsd" (FreeBSD, pfSense,
-- TrueNAS CORE); nil (not known yet) is read as Linux.
function S.family(os_id)
    if os_id == "macos" or os_id == "windows" then return os_id end
    if os_id == "freebsd" or os_id == "pfsense" or os_id == "truenascore" then return "bsd" end
    return "linux"
end

--- Whether a stat can be read on a system.
function S.fits(st, os_id)
    return st.systems == nil or st.systems[S.family(os_id)] == true
end

--- The stats a host shows: its own choice, or those on by default.
function S.shown(host)
    local out = {}
    local mine = type(host.stats) == "table" and host.stats or nil
    for __, st in ipairs(S.STATS) do
        local on
        if mine and mine[st.id] ~= nil then on = mine[st.id] else on = st.on == true end
        if on and S.fits(st, host.os ~= "auto" and host.os or host.detected) then out[#out + 1] = st.id end
    end
    -- then its custom sensors ("cs_<id>", on unless turned off)
    for __, cs in ipairs(type(host.sensors) == "table" and host.sensors or {}) do
        local id = "cs_" .. tostring(cs.id)
        if not (mine and mine[id] == false) then out[#out + 1] = id end
    end
    return out
end

-- ------------------------------------------------------------------ custom sensors

-- What a custom sensor's command gives: its first line, as a number (with
-- a unit), a percent (a bar), text, or OK / failing (whether it succeeds).
S.SENSOR_KINDS = {
    { id = "number", name = "A number", sub = "With a unit, such as 34 °C or 12 GB" },
    { id = "percent", name = "A percent", sub = "With a bar, such as 62 %" },
    { id = "text", name = "Text", sub = "The first line it prints" },
    { id = "ok", name = "OK or failing", sub = "Whether it succeeds (its exit status)" },
}

--- The lines that read a host's custom sensors (POSIX sh).
function S.sensorLines(sensors)
    local out = {}
    for __, cs in ipairs(sensors or {}) do
        local id, cmd = tostring(cs.id or ""), tostring(cs.cmd or ""):gsub("[\r\n]+", " ")
        if id:match("^%w+$") and cmd:match("%S") then
            if cs.kind == "ok" then
                out[#out + 1] = "if { " .. cmd .. " ; } >/dev/null 2>&1; then echo cs_" .. id .. "=1; else echo cs_" .. id .. "=0; fi"
            else
                out[#out + 1] = "echo \"cs_" .. id .. "=$( { " .. cmd .. " ; } 2>/dev/null | head -n 1)\""
            end
        end
    end
    return table.concat(out, "\n")
end

--- A custom sensor's tile from what it printed.
function S.sensorTile(cs, v)
    local val = v.custom and v.custom[tostring(cs.id)]
    local t = { icon = cs.icon or "gauge", label = (cs.name or "") ~= "" and cs.name or cs.cmd }
    if val == nil or (val == "" and cs.kind ~= "ok") then
        t.value, t.dim = "Not available", true
        return t
    end
    local n = tonumber(tostring(val):match("^%s*(-?[%d%.]+)"))
    if cs.kind == "ok" then
        t.value = val == "1" and "OK" or "Failing"
        t.sub = cs.cmd
    elseif cs.kind == "percent" and n then
        t.value, t.bar = (string.format("%.1f", n):gsub("%.0$", "")) .. " %", n / 100
    elseif cs.kind == "number" and n then
        local s = string.format("%.2f", n):gsub("0+$", ""):gsub("%.$", "")
        t.value = s .. ((cs.unit or "") ~= "" and (" " .. cs.unit) or "")
    else
        t.value = val
    end
    return t
end

--- The tile of a shown stat id: its own, or a custom sensor's.
function S.tileOf(id, v, sensors)
    local sid = tostring(id):match("^cs_(.+)$")
    if not sid then return S.tile(id, v) end
    for __, cs in ipairs(sensors or {}) do
        if tostring(cs.id) == sid then return S.sensorTile(cs, v) end
    end
end

-- (POSIX sh; BusyBox too)
local LINUX = [[
export LC_ALL=C
echo os=$(uname -s) $(cat /etc/platform 2>/dev/null) $(command -v midclt >/dev/null 2>&1 && echo TrueNAS) $(command -v pveversion >/dev/null 2>&1 && echo Proxmox) $([ -d /frontview ] && echo ReadyNAS)
[ -r /proc/uptime ] && echo uptime=$(cut -d. -f1 /proc/uptime)
[ -r /proc/loadavg ] && echo "load=$(cut -d' ' -f1-3 /proc/loadavg)"
if [ -r /proc/stat ]; then echo "cpu1=$(head -1 /proc/stat)"; sleep 1; echo "cpu2=$(head -1 /proc/stat)"; fi
[ -r /proc/meminfo ] && awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^MemFree:/{f=$2}/^SwapTotal:/{st=$2}/^SwapFree:/{sf=$2}END{if(a=="")a=f;print "mem="t" "a;print "swap="st" "sf}' /proc/meminfo
df -Pk / 2>/dev/null | awk 'NR==2{print "disk="$2" "$3" "$6}'
for z in /sys/class/thermal/thermal_zone*/temp; do [ -r "$z" ] && { echo temp=$(cat "$z"); break; }; done
dev=$(ip route 2>/dev/null | awk '/^default/{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')
if [ -n "$dev" ]; then echo iface=$dev; echo ip=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1); echo mac=$(cat /sys/class/net/$dev/address 2>/dev/null); else echo ip=$(hostname -I 2>/dev/null | awk '{print $1}'); fi
[ -r /etc/os-release ] && echo "sys=$(. /etc/os-release; echo "$PRETTY_NAME")"
command -v pveversion >/dev/null 2>&1 && echo "sys=Proxmox VE $(pveversion | cut -d/ -f2)"
[ -d /frontview ] && [ -r /etc/os_version ] && echo "sys=ReadyNAS OS $(cat /etc/os_version)"
echo kernel=$(uname -r)
echo users=$(who 2>/dev/null | wc -l)
echo procs=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
if command -v systemctl >/dev/null 2>&1; then
echo svc_running=$(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | wc -l)
systemctl list-units --type=service --state=failed --no-legend --plain 2>/dev/null | awk '{print "failed="$1}'
@PINNED@
fi
if command -v docker >/dev/null 2>&1; then
if out=$(docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}|{{.Image}}' 2>&1); then echo docker_ok=1; [ -n "$out" ] && echo "$out" | sed 's/^/ct=/'; else echo docker_ok=denied; fi
fi
]]

local MACOS = [[
export LC_ALL=C
echo os=Darwin
b=$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/'); echo uptime=$(( $(date +%s) - b ))
echo "load=$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1" "$2" "$3}')"
echo cpuidle=$(top -l 2 -n 0 2>/dev/null | awk '/CPU usage/{v=$7}END{print v}' | tr -d '%')
ps=$(sysctl -n hw.pagesize); echo "mem=$(( $(sysctl -n hw.memsize) / 1024 )) $(vm_stat | awk -v p=$ps '/Pages free/{f=$3}/Pages inactive/{i=$3}/Pages speculative/{s=$3}END{gsub(/\./,"",f);gsub(/\./,"",i);gsub(/\./,"",s);print int((f+i+s)*p/1024)}')"
df -Pk / 2>/dev/null | awk 'NR==2{print "disk="$2" "$3" "$6}'
dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
[ -n "$dev" ] && { echo iface=$dev; echo ip=$(ipconfig getifaddr $dev 2>/dev/null); echo mac=$(ifconfig $dev 2>/dev/null | awk '/ether/{print $2}'); }
echo "sys=$(sw_vers -productName) $(sw_vers -productVersion)"
echo kernel=$(uname -r)
echo users=$(who | wc -l)
if command -v docker >/dev/null 2>&1; then
if out=$(docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}|{{.Image}}' 2>&1); then echo docker_ok=1; [ -n "$out" ] && echo "$out" | sed 's/^/ct=/'; else echo docker_ok=denied; fi
fi
]]

-- (FreeBSD and pfSense: sent to sh, as root's shell may be csh or pfSense's
-- menu. kern.cp_time is user nice sys intr idle: put as Linux's /proc/stat.)
local BSD = [[
export LC_ALL=C
echo os=$(uname -s) $(command -v midclt >/dev/null 2>&1 && echo TrueNAS)
b=$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/'); echo uptime=$(( $(date +%s) - b ))
echo "load=$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1" "$2" "$3}')"
echo "cpu1=$(sysctl -n kern.cp_time | awk '{print "cpu "$1" "$2" "$3" "$5" 0 "$4}')"; sleep 1; echo "cpu2=$(sysctl -n kern.cp_time | awk '{print "cpu "$1" "$2" "$3" "$5" 0 "$4}')"
ps=$(sysctl -n hw.pagesize); f=$(sysctl -n vm.stats.vm.v_free_count); i=$(sysctl -n vm.stats.vm.v_inactive_count); echo "mem=$(( $(sysctl -n hw.physmem) / 1024 )) $(( (f + i) * ps / 1024 ))"
swapinfo -k 2>/dev/null | awk 'NR>1{t=$2;f=$4}END{if(t!="")print "swap="t" "f}'
df -Pk / 2>/dev/null | awk 'NR==2{print "disk="$2" "$3" "$6}'
t=$(sysctl -n dev.cpu.0.temperature 2>/dev/null || sysctl -n hw.acpi.thermal.tz0.temperature 2>/dev/null); [ -n "$t" ] && echo temp=$(echo "$t" | tr -d 'C')
dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
[ -n "$dev" ] && { echo iface=$dev; echo ip=$(ifconfig $dev 2>/dev/null | awk '/inet /{print $2; exit}'); echo mac=$(ifconfig $dev 2>/dev/null | awk '/ether/{print $2; exit}'); }
if [ -r /etc/platform ] && [ -r /etc/version ]; then echo "sys=$(cat /etc/platform) $(cat /etc/version)"; else echo "sys=FreeBSD $(freebsd-version 2>/dev/null || uname -r)"; fi
echo kernel=$(uname -r)
echo users=$(who | wc -l)
echo procs=$(( $(ps ax | wc -l) - 1 ))
]]

-- (PowerShell: Windows' OpenSSH runs cmd.exe, so it goes as -EncodedCommand)
local WINDOWS = [[
$o = Get-CimInstance Win32_OperatingSystem
"uptime=" + [int]((Get-Date) - $o.LastBootUpTime).TotalSeconds
"mem=" + $o.TotalVisibleMemorySize + " " + $o.FreePhysicalMemory
"cpu=" + [int](Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
"disk=" + [int64]($d.Size / 1024) + " " + [int64](($d.Size - $d.FreeSpace) / 1024) + " C:"
$a = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
if ($a) { "iface=" + $a.Name; "mac=" + ($a.MacAddress -replace '-', ':'); "ip=" + (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 | Select-Object -First 1).IPAddress }
"sys=" + $o.Caption + " " + $o.Version
if (Get-Command docker -ErrorAction SilentlyContinue) { "docker_ok=1"; docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}|{{.Image}}' | ForEach-Object { "ct=" + $_ } }
]]

local base64 = require("sshkeys").base64


--- PowerShell's -EncodedCommand: the script in UTF-16LE, base64.
function S.encodedPowerShell(script)
    local u = script:gsub(".", function(ch) return ch .. "\0" end)
    return "powershell -NoProfile -NonInteractive -EncodedCommand " .. base64(u)
end

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

--- The command that prints a host's stats; pinned: service names to read;
-- sensors: its custom sensors (not on Windows).
function S.command(os_id, pinned, sensors)
    local fam = S.family(os_id)
    if fam == "windows" then return S.encodedPowerShell(WINDOWS) end
    if fam == "macos" then return MACOS .. S.sensorLines(sensors) .. "\n" end
    if fam == "bsd" then return "sh -c " .. shq(BSD .. S.sensorLines(sensors) .. "\n") end
    local lines = {}
    for __, name in ipairs(pinned or {}) do
        if tostring(name):match("^[%w@%._%-]+$") then
            lines[#lines + 1] = "echo \"svc=" .. name .. "|$(systemctl is-active " .. shq(name) .. " 2>/dev/null)\""
        end
    end
    return (LINUX:gsub("@PINNED@", function() return table.concat(lines, "\n") end)) .. S.sensorLines(sensors) .. "\n"
end

--- What a stats command printed, as raw values (failed, ct and svc are lists).
function S.parse(text)
    local raw = { failed = {}, ct = {}, svc = {} }
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then
            if k == "failed" or k == "ct" or k == "svc" then
                if v ~= "" then table.insert(raw[k], v) end
            else
                raw[k] = v
            end
        end
    end
    return raw
end

local function num(s) return tonumber(s) end

-- CPU use between two /proc/stat lines ("cpu user nice system idle iowait …").
local function cpuPercent(a, b)
    local function fields(l)
        local t = {}
        for n in tostring(l or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local x, y = fields(a), fields(b)
    if #x < 4 or #y < 4 then return nil end
    local tx, ty = 0, 0
    for i = 1, math.min(#x, 8) do tx = tx + x[i] end
    for i = 1, math.min(#y, 8) do ty = ty + y[i] end
    local idle = (y[4] + (y[5] or 0)) - (x[4] + (x[5] or 0))
    local total = ty - tx
    if total <= 0 then return nil end
    return math.max(0, math.min(100, math.floor((1 - idle / total) * 100 + 0.5)))
end
S.cpuPercent = cpuPercent

--- The values SSH shows, from raw ones: numbers in plain units (seconds,
-- percent, kB, °C).
function S.values(raw)
    local v = {}
    v.uptime = num(raw.uptime)
    v.load = raw.load and raw.load ~= "" and raw.load or nil
    v.cpu = num(raw.cpu) or cpuPercent(raw.cpu1, raw.cpu2)
    if not v.cpu and num(raw.cpuidle) then v.cpu = math.floor(100 - num(raw.cpuidle) + 0.5) end
    local mt, ma = tostring(raw.mem or ""):match("^(%d+)%s+(%d+)")
    if mt then v.mem = { total = tonumber(mt), used = tonumber(mt) - tonumber(ma) } end
    local st, sf = tostring(raw.swap or ""):match("^(%d+)%s+(%d+)")
    if st and tonumber(st) > 0 then v.swap = { total = tonumber(st), used = tonumber(st) - tonumber(sf) } end
    local dt, du, dm = tostring(raw.disk or ""):match("^(%d+)%s+(%d+)%s+(.+)$")
    if dt then v.disk = { total = tonumber(dt), used = tonumber(du), mount = dm } end
    local t = num(raw.temp)
    if t then v.temp = t > 1000 and t / 1000 or t end
    v.ip = raw.ip ~= "" and raw.ip or nil
    v.iface = raw.iface ~= "" and raw.iface or nil
    v.mac = raw.mac and raw.mac:match("^%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x$") and raw.mac:lower():gsub("%-", ":") or nil
    v.sys = raw.sys ~= "" and raw.sys or nil
    v.kernel = raw.kernel ~= "" and raw.kernel or nil
    v.users = num(raw.users)
    v.procs = num(raw.procs)
    if raw.svc_running then v.running = num(raw.svc_running) end
    v.failed = {}
    for __, f in ipairs(raw.failed) do v.failed[#v.failed + 1] = (f:gsub("%.service$", "")) end
    if raw.svc_running then v.hasSystemd = true end
    v.pinned = {}
    for __, s in ipairs(raw.svc) do
        local name, state = s:match("^([^|]+)|(.*)$")
        if name then v.pinned[#v.pinned + 1] = { name = name, state = state ~= "" and state or "unknown" } end
    end
    v.custom = {}
    for k, x in pairs(raw) do
        local id = type(k) == "string" and k:match("^cs_(.+)$")
        if id then v.custom[id] = x end
    end
    if raw.docker_ok == "1" then
        v.docker = { ok = true, list = {} }
        for __, c in ipairs(raw.ct) do
            local name, state, status, image = c:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
            if name then v.docker.list[#v.docker.list + 1] = { name = name, state = state, status = status, image = image } end
        end
    elseif raw.docker_ok == "denied" then
        v.docker = { ok = false, denied = true, list = {} }
    end
    return v
end

-- ------------------------------------------------------------------ showing them

--- "3.8 GB", "512 MB" from kB.
function S.size(kb)
    if not kb then return "?" end
    local units = { "kB", "MB", "GB", "TB", "PB" }
    local n, i = kb, 1
    while n >= 1024 and i < #units do n, i = n / 1024, i + 1 end
    if n >= 100 or i == 1 then return string.format("%d %s", math.floor(n + 0.5), units[i]) end
    return (string.format("%.1f", n):gsub("%.0$", "")) .. " " .. units[i]
end

--- "3 days 4 h", "5 h 12 min", "12 min" from seconds.
function S.duration(s)
    if not s then return "?" end
    local d, h, m = math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60)
    if d > 0 then return string.format("%d %s %d h", d, d == 1 and "day" or "days", h) end
    if h > 0 then return string.format("%d h %d min", h, m) end
    return string.format("%d min", m)
end

local function running(list)
    local n = 0
    for __, c in ipairs(list) do if c.state == "running" then n = n + 1 end end
    return n
end
S.running = running

--- A stat's tile: { icon, label, value, sub, bar, mono, dim }, or a "Not
-- available" one when it couldn't be read.
function S.tile(id, v)
    local st = S.byId[id]
    if not st then return nil end
    local t = { icon = st.icon, label = st.name }
    local function na() t.value, t.dim = "Not available", true return t end
    if id == "uptime" then
        if not v.uptime then return na() end
        t.value = S.duration(v.uptime)
    elseif id == "temp" then
        if not v.temp then return na() end
        t.value = string.format("%d °C", math.floor(v.temp + 0.5))
        t.sub = st.sub
    elseif id == "cpu" then
        if not v.cpu then return na() end
        t.value, t.bar = v.cpu .. " %", v.cpu / 100
    elseif id == "mem" then
        if not v.mem then return na() end
        t.value, t.bar = S.size(v.mem.used) .. " / " .. S.size(v.mem.total), v.mem.used / math.max(1, v.mem.total)
    elseif id == "swap" then
        if not v.swap then return na() end
        t.value, t.bar = S.size(v.swap.used) .. " / " .. S.size(v.swap.total), v.swap.used / math.max(1, v.swap.total)
    elseif id == "disk" then
        if not v.disk then return na() end
        t.label = "Disk " .. v.disk.mount
        t.value, t.bar = S.size(v.disk.used) .. " / " .. S.size(v.disk.total), v.disk.used / math.max(1, v.disk.total)
    elseif id == "ip" then
        if not v.ip then return na() end
        t.value, t.mono, t.sub = v.ip, true, v.iface
    elseif id == "load" then
        if not v.load then return na() end
        t.value, t.sub = v.load, st.sub
    elseif id == "sys" then
        if not v.sys then return na() end
        t.value, t.sub = v.sys, v.kernel
    elseif id == "users" then
        if not v.users then return na() end
        t.value = tostring(v.users)
    elseif id == "procs" then
        if not v.procs then return na() end
        t.value = tostring(v.procs)
    elseif id == "failed" then
        if not v.hasSystemd then return na() end
        t.value = #v.failed == 0 and "None" or tostring(#v.failed)
        t.sub = v.failed[1]
    elseif id == "services" then
        if not v.running then return na() end
        t.value = v.running .. " running"
        if #v.failed > 0 then t.sub = #v.failed .. " failed" end
    elseif id == "docker" then
        if not v.docker then return na() end
        if v.docker.denied then t.value, t.sub = "Needs sudo", "docker ps"
        else t.value = string.format("%d of %d running", running(v.docker.list), #v.docker.list) end
    end
    return t
end

--- The main page's short line from a host's first stats: "up 3 days · 52 °C".
function S.short(v, ids, n)
    local out = {}
    for __, id in ipairs(ids) do
        if #out >= (n or 2) then break end
        local s
        if id == "uptime" and v.uptime then s = "up " .. S.duration(v.uptime):gsub(" %d+ h$", ""):gsub(" %d+ min$", "")
        elseif id == "temp" and v.temp then s = string.format("%d °C", math.floor(v.temp + 0.5))
        elseif id == "cpu" and v.cpu then s = "CPU " .. v.cpu .. " %"
        elseif id == "mem" and v.mem then s = "RAM " .. math.floor(v.mem.used * 100 / math.max(1, v.mem.total) + 0.5) .. " %"
        elseif id == "disk" and v.disk then s = "disk " .. math.floor(v.disk.used * 100 / math.max(1, v.disk.total) + 0.5) .. " %"
        elseif id == "docker" and v.docker and v.docker.ok then s = running(v.docker.list) .. "/" .. #v.docker.list .. " running"
        elseif id == "failed" and v.hasSystemd and #v.failed > 0 then s = #v.failed .. " failed"
        elseif id == "load" and v.load then s = "load " .. v.load:match("^%S+") end
        if s then out[#out + 1] = s end
    end
    return table.concat(out, " · ")
end

-- ------------------------------------------------------------------ alerts

-- What can raise an alert: a limit above which it does (percent, °C), or a
-- yes/no (any failed service, any stopped container).
S.ALERTS = {
    { id = "disk", name = "Disk full", unit = "%", default = 90, read = function(v) return v.disk and v.disk.used * 100 / math.max(1, v.disk.total) end },
    { id = "mem", name = "Memory used", unit = "%", default = 90, read = function(v) return v.mem and v.mem.used * 100 / math.max(1, v.mem.total) end },
    { id = "cpu", name = "CPU busy", unit = "%", default = 90, read = function(v) return v.cpu end },
    { id = "temp", name = "Temperature", unit = "°C", default = 70, read = function(v) return v.temp end },
    { id = "failed", name = "A service failed", yesno = true, read = function(v) return v.hasSystemd and #v.failed > 0 and #v.failed or nil end },
    { id = "stopped", name = "A container stopped", yesno = true, read = function(v)
        if not (v.docker and v.docker.ok) then return nil end
        local n = #v.docker.list - running(v.docker.list)
        return n > 0 and n or nil
    end },
}

--- Which alerts are raised now: { { id, text } } for limits = { [id] = value
-- (a number, or true for yes/no ones) }; custom sensors' as "cs_<id>".
function S.check(v, limits, sensors)
    local out = {}
    for __, cs in ipairs(sensors or {}) do
        local id = "cs_" .. tostring(cs.id)
        local limit = limits and limits[id]
        local val = v.custom and v.custom[tostring(cs.id)]
        local name = (cs.name or "") ~= "" and cs.name or cs.cmd
        if limit and val then
            if cs.kind == "ok" then
                if val == "0" then out[#out + 1] = { id = id, text = name .. ": failing" } end
            else
                local n = tonumber(tostring(val):match("^%s*(-?[%d%.]+)"))
                if n and type(limit) == "number" and n > limit then
                    out[#out + 1] = { id = id, text = string.format("%s: %s (over %s)", name, val, tostring(limit)) }
                end
            end
        end
    end
    for __, a in ipairs(S.ALERTS) do
        local limit = limits and limits[a.id]
        if limit then
            local now = a.read(v)
            if a.yesno then
                if now then
                    local what = a.id == "failed" and table.concat(v.failed, ", ")
                        or (function()
                            local names = {}
                            for __, c in ipairs(v.docker.list) do if c.state ~= "running" then names[#names + 1] = c.name end end
                            return table.concat(names, ", ")
                        end)()
                    out[#out + 1] = { id = a.id, text = a.name .. ": " .. what }
                end
            elseif now and type(limit) == "number" and now > limit then
                out[#out + 1] = { id = a.id, text = string.format("%s: %d %s (over %d %s)", a.name, math.floor(now + 0.5), a.unit, limit, a.unit) }
            end
        end
    end
    return out
end

-- ------------------------------------------------------------------ custom alerts

-- What a custom alert can watch: a number (and its unit) or text, read from
-- the values (custom sensors are added by S.watchable).
S.WATCH = {
    { id = "cpu", name = "CPU", unit = "%", read = function(v) return v.cpu end },
    { id = "mem", name = "Memory used", unit = "%", read = function(v) return v.mem and v.mem.used * 100 / math.max(1, v.mem.total) end },
    { id = "disk", name = "Disk used", unit = "%", read = function(v) return v.disk and v.disk.used * 100 / math.max(1, v.disk.total) end },
    { id = "temp", name = "Temperature", unit = "°C", read = function(v) return v.temp end },
    { id = "load", name = "Load (1 minute)", read = function(v) return v.load and tonumber(v.load:match("^%S+")) end },
    { id = "uptime", name = "Uptime", unit = "hours", read = function(v) return v.uptime and v.uptime / 3600 end },
    { id = "users", name = "Signed in", read = function(v) return v.users end },
    { id = "procs", name = "Processes", read = function(v) return v.procs end },
    { id = "swap", name = "Swap used", unit = "%", read = function(v) return v.swap and v.swap.used * 100 / math.max(1, v.swap.total) end },
    { id = "failed", name = "Failed services", read = function(v) return v.hasSystemd and #v.failed or nil end },
    { id = "running", name = "Containers running", read = function(v) return v.docker and v.docker.ok and running(v.docker.list) or nil end },
    { id = "ip", name = "IP address", text = true, read = function(v) return v.ip end },
    { id = "sys", name = "System", text = true, read = function(v) return v.sys end },
}

-- The tests: above, below, is, isn't, contains.
S.OPS = {
    { id = "gt", name = "above" }, { id = "lt", name = "below" }, { id = "eq", name = "is" },
    { id = "ne", name = "isn't" }, { id = "has", name = "contains" },
}

--- What can be watched on a host: S.WATCH, then its custom sensors.
function S.watchable(sensors)
    local out = {}
    for __, w in ipairs(S.WATCH) do out[#out + 1] = w end
    for __, cs in ipairs(sensors or {}) do
        local id = tostring(cs.id)
        out[#out + 1] = { id = "cs_" .. id, name = (cs.name or "") ~= "" and cs.name or cs.cmd,
            unit = cs.kind == "number" and cs.unit or (cs.kind == "percent" and "%" or nil),
            text = cs.kind == "text" or cs.kind == "ok",
            read = function(v)
                local x = v.custom and v.custom[id]
                if x == nil then return nil end
                if cs.kind == "ok" then return x == "1" and "OK" or "Failing" end
                if cs.kind == "text" then return x end
                return tonumber(tostring(x):match("^%s*(-?[%d%.]+)"))
            end }
    end
    return out
end

local function opName(op)
    for __, o in ipairs(S.OPS) do if o.id == op then return o.name end end
    return op
end

--- A custom alert in words: "Load (1 minute) above 4".
function S.alertText(a, sensors)
    local w
    for __, x in ipairs(S.watchable(sensors)) do if x.id == a.what then w = x end end
    local name = w and w.name or a.what
    local unit = w and w.unit and not w.text and (" " .. w.unit) or ""
    return string.format("%s %s %s%s", name, opName(a.op), tostring(a.value), unit)
end

--- Whether a custom alert is raised by these values (nil: not readable).
function S.customRaised(a, v, sensors)
    local w
    for __, x in ipairs(S.watchable(sensors)) do if x.id == a.what then w = x end end
    if not w then return nil end
    local now = w.read(v)
    if now == nil then return nil end
    local want = a.value
    if a.op == "has" then return tostring(now):lower():find(tostring(want):lower(), 1, true) ~= nil end
    local n, m = tonumber(now), tonumber(want)
    if a.op == "gt" then return n ~= nil and m ~= nil and n > m end
    if a.op == "lt" then return n ~= nil and m ~= nil and n < m end
    local same
    if n and m then same = math.abs(n - m) < 1e-9 else same = tostring(now):lower() == tostring(want):lower() end
    if a.op == "eq" then return same end
    if a.op == "ne" then return not same end
    return nil
end

--- The custom alerts raised now: { { id = "ca_<id>", text } }.
function S.checkCustom(v, list, sensors)
    local out = {}
    for __, a in ipairs(list or {}) do
        if S.customRaised(a, v, sensors) then
            out[#out + 1] = { id = "ca_" .. tostring(a.id), text = S.alertText(a, sensors) }
        end
    end
    return out
end

-- ------------------------------------------------------------------ quick commands

-- id, name, icon, sub (a short reminder of what it runs), cmd, ask (asks
-- first: reboot, shut down).
S.QUICK = {
    debian = {
        { id = "update", name = "Update", icon = "refresh-cw", sub = "apt update", cmd = "sudo apt update" },
        { id = "upgrade", name = "Upgrade", icon = "circle-arrow-up", sub = "apt upgrade", cmd = "sudo apt upgrade -y" },
        { id = "full", name = "Full upgrade", icon = "layers", sub = "full-upgrade", cmd = "sudo apt full-upgrade -y" },
        { id = "clean", name = "Clean up", icon = "trash-2", sub = "autoremove", cmd = "sudo apt autoremove -y && sudo apt clean" },
        { id = "pending", name = "Updates?", icon = "list-checks", sub = "upgradable", cmd = "apt list --upgradable 2>/dev/null" },
        { id = "install", name = "Install", icon = "package", sub = "apt install", cmd = "sudo apt install -y {package}", off = true },
    },
    fedora = {
        { id = "update", name = "Check", icon = "refresh-cw", sub = "dnf check-update", cmd = "dnf check-update" },
        { id = "upgrade", name = "Upgrade", icon = "circle-arrow-up", sub = "dnf upgrade", cmd = "sudo dnf upgrade -y" },
        { id = "clean", name = "Clean up", icon = "trash-2", sub = "autoremove", cmd = "sudo dnf autoremove -y && sudo dnf clean all" },
        { id = "restart", name = "Restart?", icon = "rotate-cw", sub = "needs-restarting", cmd = "sudo dnf needs-restarting -r" },
        { id = "install", name = "Install", icon = "package", sub = "dnf install", cmd = "sudo dnf install -y {package}", off = true },
    },
    arch = {
        { id = "upgrade", name = "Upgrade", icon = "circle-arrow-up", sub = "pacman -Syu", cmd = "sudo pacman -Syu --noconfirm" },
        { id = "aur", name = "AUR too", icon = "layers", sub = "yay -Syu", cmd = "yay -Syu --noconfirm" },
        { id = "pending", name = "Updates?", icon = "list-checks", sub = "checkupdates", cmd = "checkupdates" },
        { id = "clean", name = "Clean up", icon = "trash-2", sub = "orphans, cache", cmd = "sudo pacman -Rns --noconfirm $(pacman -Qtdq); sudo paccache -r" },
    },
    opensuse = {
        { id = "update", name = "Refresh", icon = "refresh-cw", sub = "zypper refresh", cmd = "sudo zypper refresh" },
        { id = "upgrade", name = "Upgrade", icon = "circle-arrow-up", sub = "zypper update", cmd = "sudo zypper -n update" },
        { id = "full", name = "Dist upgrade", icon = "layers", sub = "zypper dup", cmd = "sudo zypper -n dup" },
    },
    alpine = {
        { id = "update", name = "Update", icon = "refresh-cw", sub = "apk update", cmd = "sudo apk update" },
        { id = "upgrade", name = "Upgrade", icon = "circle-arrow-up", sub = "apk upgrade", cmd = "sudo apk upgrade" },
    },
    linux = {
        { id = "disk", name = "Disk space", icon = "hard-drive", sub = "df -h", cmd = "df -h -x tmpfs -x devtmpfs" },
        { id = "big", name = "Big folders", icon = "folder", sub = "du, top 10", cmd = "sudo du -xh / --max-depth=2 2>/dev/null | sort -h | tail -10" },
        { id = "failed", name = "Failed", icon = "triangle-alert", sub = "services", cmd = "systemctl --failed --no-pager" },
        { id = "reboot", name = "Reboot", icon = "rotate-cw", sub = "asks first", cmd = "sudo reboot", ask = true },
        { id = "shutdown", name = "Shut down", icon = "power", sub = "asks first", cmd = "sudo shutdown -h now", ask = true },
    },
    macos = {
        { id = "updates", name = "Updates?", icon = "list-checks", sub = "softwareupdate", cmd = "softwareupdate -l" },
        { id = "brew", name = "Homebrew", icon = "circle-arrow-up", sub = "brew upgrade", cmd = "brew update && brew upgrade" },
        { id = "disk", name = "Disk space", icon = "hard-drive", sub = "df -h", cmd = "df -h /" },
        { id = "reboot", name = "Restart", icon = "rotate-cw", sub = "asks first", cmd = "sudo shutdown -r now", ask = true },
        { id = "shutdown", name = "Shut down", icon = "power", sub = "asks first", cmd = "sudo shutdown -h now", ask = true },
    },
    windows = {
        { id = "updates", name = "Upgrades", icon = "circle-arrow-up", sub = "winget", cmd = "winget upgrade" },
        { id = "disk", name = "Disk space", icon = "hard-drive", sub = "C:", cmd = "powershell -NoProfile -Command \"Get-PSDrive -PSProvider FileSystem\"" },
        { id = "reboot", name = "Restart", icon = "rotate-cw", sub = "asks first", cmd = "shutdown /r /t 0", ask = true },
        { id = "shutdown", name = "Shut down", icon = "power", sub = "asks first", cmd = "shutdown /s /t 0", ask = true },
    },
    freebsd = {
        { id = "update", name = "System", icon = "refresh-cw", sub = "freebsd-update", cmd = "sudo freebsd-update fetch install" },
        { id = "upgrade", name = "Packages", icon = "circle-arrow-up", sub = "pkg upgrade", cmd = "sudo pkg upgrade -y" },
        { id = "pending", name = "Updates?", icon = "list-checks", sub = "pkg upgrade -n", cmd = "pkg upgrade -n" },
        { id = "clean", name = "Clean up", icon = "trash-2", sub = "pkg autoremove", cmd = "sudo pkg autoremove -y && sudo pkg clean -y" },
        { id = "install", name = "Install", icon = "package", sub = "pkg install", cmd = "sudo pkg install -y {package}", off = true },
        { id = "services", name = "Services", icon = "server", sub = "service -e", cmd = "service -e" },
        { id = "reboot", name = "Reboot", icon = "rotate-cw", sub = "asks first", cmd = "sudo shutdown -r now", ask = true },
        { id = "shutdown", name = "Shut down", icon = "power", sub = "asks first", cmd = "sudo shutdown -p now", ask = true },
    },
    -- (signed in as admin or root: no sudo. An upgrade can take a while and
    -- restarts it, so it runs in a live session.)
    pfsense = {
        { id = "pending", name = "Updates?", icon = "list-checks", sub = "pfSense-upgrade -c", cmd = "pfSense-upgrade -c" },
        { id = "upgrade", name = "Upgrade", icon = "circle-arrow-up", sub = "asks first", cmd = "pfSense-upgrade -y", ask = true, session = true },
        { id = "info", name = "Firewall", icon = "activity", sub = "pfctl -si", cmd = "pfctl -si" },
        { id = "rules", name = "Rules", icon = "list", sub = "pfctl -sr", cmd = "pfctl -sr" },
        { id = "reload", name = "Reload rules", icon = "refresh-cw", sub = "filter_configure", cmd = "/etc/rc.filter_configure" },
        { id = "webgui", name = "Web GUI", icon = "globe", sub = "restart it", cmd = "/etc/rc.restart_webgui" },
        { id = "routes", name = "Routes", icon = "arrow-right-left", sub = "netstat -rn", cmd = "netstat -rn" },
        { id = "reboot", name = "Reboot", icon = "rotate-cw", sub = "asks first", cmd = "shutdown -r now", ask = true },
        { id = "shutdown", name = "Shut down", icon = "power", sub = "asks first", cmd = "shutdown -p now", ask = true },
    },
    -- (TrueNAS: signed in as admin, with sudo; the middleware's commands
    -- need it)
    truenas = {
        { id = "pools", name = "Pools", icon = "hard-drive", sub = "zpool status -x", cmd = "zpool status -x" },
        { id = "space", name = "Pool space", icon = "gauge", sub = "zpool list", cmd = "zpool list" },
        { id = "datasets", name = "Datasets", icon = "folder", sub = "zfs list", cmd = "zfs list -o name,used,avail,mountpoint" },
        { id = "alerts", name = "Alerts", icon = "bell", sub = "TrueNAS's", cmd = "sudo midclt call alert.list | python3 -c \"import json,sys; [print(a['formatted']) for a in json.load(sys.stdin)]\"" },
        { id = "scrub", name = "Scrub", icon = "refresh-cw", sub = "asks first", cmd = "sudo zpool scrub {pool}", ask = true, off = true },
    },
    -- (TrueNAS CORE: FreeBSD, signed in as root)
    truenascore = {
        { id = "pools", name = "Pools", icon = "hard-drive", sub = "zpool status -x", cmd = "zpool status -x" },
        { id = "space", name = "Pool space", icon = "gauge", sub = "zpool list", cmd = "zpool list" },
        { id = "datasets", name = "Datasets", icon = "folder", sub = "zfs list", cmd = "zfs list -o name,used,avail,mountpoint" },
        { id = "alerts", name = "Alerts", icon = "bell", sub = "TrueNAS's", cmd = "midclt call alert.list | python3 -c \"import json,sys; [print(a['formatted']) for a in json.load(sys.stdin)]\"" },
        { id = "reboot", name = "Reboot", icon = "rotate-cw", sub = "asks first", cmd = "shutdown -r now", ask = true },
        { id = "shutdown", name = "Shut down", icon = "power", sub = "asks first", cmd = "shutdown -p now", ask = true },
    },
    -- (Proxmox VE: Debian, signed in as root; an upgrade can ask about
    -- config files, so it runs in a live session)
    proxmox = {
        { id = "update", name = "Update", icon = "refresh-cw", sub = "apt update", cmd = "apt update" },
        { id = "pending", name = "Updates?", icon = "list-checks", sub = "upgradable", cmd = "apt list --upgradable 2>/dev/null" },
        { id = "upgrade", name = "Upgrade", icon = "circle-arrow-up", sub = "dist-upgrade", cmd = "apt update && apt dist-upgrade", session = true },
        { id = "vms", name = "VMs", icon = "monitor", sub = "qm list", cmd = "qm list" },
        { id = "cts", name = "Containers", icon = "box", sub = "pct list", cmd = "pct list" },
        { id = "storage", name = "Storage", icon = "hard-drive", sub = "pvesm status", cmd = "pvesm status" },
        { id = "vmstart", name = "Start VM", icon = "play", sub = "qm start", cmd = "qm start {vmid}", off = true },
        { id = "vmstop", name = "Stop VM", icon = "circle-stop", sub = "qm shutdown", cmd = "qm shutdown {vmid}", ask = true, off = true },
        { id = "version", name = "Version", icon = "info", sub = "pveversion", cmd = "pveversion -v" },
    },
    -- (ReadyNAS OS 6: Debian with md RAID and btrfs, signed in as root;
    -- updates come from its web page)
    readynas = {
        { id = "raid", name = "RAID", icon = "layers", sub = "/proc/mdstat", cmd = "cat /proc/mdstat" },
        { id = "volumes", name = "Volumes", icon = "hard-drive", sub = "btrfs show", cmd = "btrfs filesystem show" },
        { id = "smart", name = "Disk health", icon = "triangle-alert", sub = "smartctl -H", cmd = "for d in /dev/sd?; do echo \"$d: $(smartctl -H $d | grep -i result)\"; done" },
    },
    -- FreeBSD and pfSense
    bsd = {
        { id = "disk", name = "Disk space", icon = "hard-drive", sub = "df -h", cmd = "df -h" },
        { id = "ports", name = "Ports", icon = "network", sub = "sockstat -4l", cmd = "sockstat -4l" },
        { id = "top", name = "Top", icon = "cpu", sub = "top 15", cmd = "top -b 15" },
    },
}

-- Systems you sign in to as root, without sudo.
S.AS_ROOT = { proxmox = true, readynas = true }

-- Docker's, when the host has it.
S.DOCKER_QUICK = {
    { id = "d_ps", name = "Containers", icon = "list", sub = "docker ps -a", cmd = "docker ps -a" },
    { id = "d_pull", name = "Pull all", icon = "download", sub = "compose pull", cmd = "cd {folder} && docker compose pull" },
    { id = "d_up", name = "Up again", icon = "play", sub = "compose up -d", cmd = "cd {folder} && docker compose up -d" },
    { id = "d_stats", name = "Usage", icon = "chart-column", sub = "docker stats", cmd = "docker stats --no-stream" },
    { id = "d_prune", name = "Clean up", icon = "trash-2", sub = "system prune", cmd = "docker system prune -f", ask = true },
}

--- The quick commands a system offers, in order: its own, then any Linux
-- one (on Linux), then Docker's when `docker` (the host has it).
function S.quickFor(os_id, docker)
    local fam = S.family(os_id)
    local out = {}
    local function add(list) for __, q in ipairs(list or {}) do out[#out + 1] = q end end
    if fam == "linux" then
        local own = os_id == "raspberrypi" and "debian" or os_id
        add(S.QUICK[own])
        if S.AS_ROOT[os_id] then
            -- (signed in as root, without sudo: the Linux ones without it)
            for __, q in ipairs(S.QUICK.linux) do
                local c = {}
                for k, x in pairs(q) do c[k] = x end
                c.cmd = q.cmd:gsub("sudo ", "")
                out[#out + 1] = c
            end
        else
            add(S.QUICK.linux)
        end
    elseif fam == "bsd" then
        -- its own, the BSD ones, then its Reboot and Shut down
        local own, power = {}, {}
        for __, q in ipairs(S.QUICK[os_id] or {}) do
            table.insert((q.id == "reboot" or q.id == "shutdown") and power or own, q)
        end
        add(own)
        add(S.QUICK.bsd)
        add(power)
    else
        add(S.QUICK[fam])
    end
    if docker then add(S.DOCKER_QUICK) end
    return out
end

--- The quick commands a host shows: its own order and choice (ids), or
-- those not `off` by default; with sudo ones as Docker needs.
function S.quickShown(host, docker)
    local all = S.quickFor(host.os ~= "auto" and host.os or host.detected, docker)
    local byId = {}
    for __, q in ipairs(all) do byId[q.id] = q end
    local out = {}
    if type(host.quick) == "table" then
        for __, id in ipairs(host.quick) do
            if byId[id] then out[#out + 1] = byId[id] end
            -- (a custom one: "cmd:<the command>|<name>")
            local cmd, name = tostring(id):match("^cmd:(.*)|(.*)$")
            if cmd then
                local icon = type(host.quickIcons) == "table" and host.quickIcons[id] or "terminal"
                out[#out + 1] = { id = id, name = name ~= "" and name or cmd, icon = icon, sub = cmd:sub(1, 14), cmd = cmd }
            end
        end
        return out
    end
    for __, q in ipairs(all) do if not q.off then out[#out + 1] = q end end
    return out
end

--- Docker's actions on a container; sudo when Docker needs it.
function S.dockerCommand(name, action, sudo)
    local pre = sudo and "sudo " or ""
    local n = shq(name)
    if action == "logs" then return pre .. "docker logs --tail 100 " .. n .. " 2>&1" end
    if action == "shell" then return pre .. "docker exec -it " .. n .. " sh -c 'command -v bash >/dev/null && exec bash || exec sh'" end
    return pre .. "docker " .. action .. " " .. n
end

--- A service's actions (sudo for the ones that change it).
function S.serviceCommand(name, action)
    local n = shq(name)
    if action == "logs" then return "journalctl -u " .. n .. " -n 100 --no-pager" end
    if action == "status" then return "systemctl status " .. n .. " --no-pager" end
    return "sudo systemctl " .. action .. " " .. n
end

--- Every service, for the Services page: name, active, sub, description.
S.SERVICES_CMD = "systemctl list-units --type=service --all --no-legend --plain --no-pager 2>/dev/null"

function S.parseServices(text)
    local out = {}
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        -- (a failed one starts with ●, several bytes in UTF-8)
        line = line:gsub("^%s*\226\151\143", "")
        local unit, load, active, sub, desc = line:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*(.*)$")
        if unit and unit:match("%.service$") then
            out[#out + 1] = { name = unit:gsub("%.service$", ""), load = load, active = active, sub = sub, desc = desc }
        end
    end
    return out
end

-- ------------------------------------------------------------------ commands with blanks

--- The blanks in a command, in order, each once: "{service}" → "service".
function S.blanks(cmd)
    local out, seen = {}, {}
    for name in tostring(cmd or ""):gmatch("{([%w_%- ]+)}") do
        if not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    return out
end

--- The command with its blanks filled in (values by name).
function S.fill(cmd, values)
    return (tostring(cmd):gsub("{([%w_%- ]+)}", function(name) return values[name] or ("{" .. name .. "}") end))
end

-- ------------------------------------------------------------------ ~/.ssh/config

--- The hosts in an OpenSSH config file's text: { { name, address, user, port,
-- identity } }. Patterns (* ?) and Match blocks are skipped.
function S.parseSshConfig(text)
    local hosts, cur = {}, nil
    local defaults = {}
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
        line = line:gsub("#.*$", ""):match("^%s*(.-)%s*$")
        local key, value = line:match("^(%S+)%s*=?%s*(.-)$")
        if key and value ~= "" then
            key = key:lower()
            value = value:gsub('^"(.*)"$', "%1")
            if key == "host" then
                cur = nil
                for name in value:gmatch("%S+") do
                    if not name:find("[%*%?!]") then
                        cur = { name = name }
                        hosts[#hosts + 1] = cur
                        break
                    end
                end
                if not cur and value:match("^%*$") then cur = defaults end
            elseif key == "match" then
                cur = nil
            elseif cur then
                if key == "hostname" then cur.address = value
                elseif key == "user" then cur.user = value
                elseif key == "port" then cur.port = tonumber(value)
                elseif key == "identityfile" then cur.identity = value end
            end
        end
    end
    for __, h in ipairs(hosts) do
        h.address = h.address or h.name
        h.user = h.user or defaults.user
        h.port = h.port or defaults.port or 22
    end
    return hosts
end

-- ------------------------------------------------------------------ Wake on LAN

--- The magic packet for a MAC address (6 × 0xFF, then the address 16
-- times), or nil when it isn't one.
function S.magicPacket(mac)
    local hex = tostring(mac or ""):gsub("[:%-%.]", "")
    if not hex:match("^%x+$") or #hex ~= 12 then return nil end
    local bytes = hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
    return string.rep("\255", 6) .. string.rep(bytes, 16)
end

-- ------------------------------------------------------------------ Files

--- The command listing a folder: "d|f<TAB>size<TAB>name" lines (POSIX sh).
function S.listCommand(dir)
    return "cd " .. shq(dir) .. " 2>/dev/null || { echo 'ERR=cd'; exit; }; echo \"PWD=$(pwd)\"; "
        .. "for f in * .[!.]*; do [ -e \"$f\" ] || [ -L \"$f\" ] || continue; "
        .. "if [ -d \"$f\" ]; then printf 'd\\t0\\t%s\\n' \"$f\"; else printf 'f\\t%s\\t%s\\n' \"$(wc -c < \"$f\" 2>/dev/null | tr -d ' ')\" \"$f\"; fi; done"
end

--- A listing: { pwd, items = { { name, dir, size } } } (folders first, by
-- name), or nil, why.
function S.parseList(text)
    local pwd, items = nil, {}
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        if line == "ERR=cd" then return nil, "cd" end
        local p = line:match("^PWD=(.*)$")
        if p then pwd = p end
        local kind, size, name = line:match("^([df])\t(%d*)\t(.+)$")
        if kind then items[#items + 1] = { name = name, dir = kind == "d", size = tonumber(size) } end
    end
    if not pwd then return nil, "nothing" end
    table.sort(items, function(a, b)
        if a.dir ~= b.dir then return a.dir end
        return a.name:lower() < b.name:lower()
    end)
    return { pwd = pwd, items = items }
end

--- A path one folder up.
function S.parent(path)
    if path == "/" or path == "" then return "/" end
    local p = path:gsub("/+$", ""):match("^(.*)/[^/]*$")
    return (p == nil or p == "") and "/" or p
end

function S.join(dir, name)
    return (dir:gsub("/+$", "")) .. "/" .. name
end

--- Whether a file looks like text to read (by its name).
local TEXT = { txt = true, log = true, conf = true, cfg = true, ini = true, md = true, json = true, yml = true, yaml = true,
    sh = true, py = true, lua = true, xml = true, csv = true, toml = true, service = true, env = true, list = true }
function S.isText(name)
    local ext = tostring(name):match("%.([%w]+)$")
    return ext == nil or TEXT[ext:lower()] == true
end

-- Files a Kindle reads (copied to the books folder).
local BOOKS = { epub = true, pdf = true, mobi = true, azw3 = true, azw = true, cbz = true, cbr = true, djvu = true, fb2 = true, txt = true }
function S.isBook(name)
    local ext = tostring(name):match("%.([%w]+)$")
    return ext ~= nil and BOOKS[ext:lower()] == true
end

return S
