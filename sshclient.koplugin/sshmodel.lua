--[[--
The SSH app's data and rules in plain Lua (tested): hosts, their saved
commands and recent commands, the command list, keys; dbclient's command line,
and reading what it printed (a host to trust, a changed host key, sign-in
failed, can't connect); known_hosts; colour codes out of output; the web
page's changes.

The data (settings/sshclient.json; the saved passwords in
settings/sshclient_passwords.json, { [host id] = password }):
  hosts = { { id, name, address, user, port, auth = "key" | "password" | "ask",
              key = key id, password, os = "auto" | an M.OSES id, detected,
              commands = { { id, name, cmd } }, recent = { cmd, … } } }
  commands = { { id, name, cmd, os } }  -- the command list, for every host
  builtInVersion
  keys = { { id, name, type, public = "ssh-ed25519 AAAA… name" } }
  nextId
]]

local M = {}

M.RECENT_MAX = 10
M.OUTPUT_MAX = 200 * 1024

-- The systems a host can run, for picking the commands that fit it. A
-- command's os is one of these ids, "linux" (any Linux), or nil (any system).
M.OSES = {
    { id = "debian", name = "Debian/Ubuntu" },
    { id = "raspberrypi", name = "Raspberry Pi OS" },
    { id = "fedora", name = "Fedora/RHEL" },
    { id = "arch", name = "Arch" },
    { id = "opensuse", name = "openSUSE" },
    { id = "alpine", name = "Alpine" },
    { id = "linux", name = "Other Linux" },
    { id = "windows", name = "Windows" },
    { id = "macos", name = "macOS" },
    { id = "freebsd", name = "FreeBSD" },
    { id = "pfsense", name = "pfSense" },
    { id = "truenas", name = "TrueNAS" },
    { id = "truenascore", name = "TrueNAS CORE" },
    { id = "proxmox", name = "Proxmox VE" },
    { id = "readynas", name = "ReadyNAS OS" },
}

-- Not Linux: "linux" commands don't fit these.
local NOT_LINUX = { windows = true, macos = true, freebsd = true, pfsense = true, truenascore = true }

-- Systems found by a mark of their own (TrueNAS's midclt, Proxmox's
-- pveversion, ReadyNAS's /frontview, pfSense's /etc/platform): they take over
-- a host first detected as Debian or FreeBSD.
M.REFINED = { truenas = true, truenascore = true, pfsense = true, proxmox = true, readynas = true }

-- Raised when built-in commands are added: an older list gets the new ones
-- (those with since = this version) once.
M.BUILTIN_VERSION = 4

-- The command list to start with (editable on the Kindle and the web page).
-- Commands with sudo ask for a password on most systems: use them in a live
-- session, or on a device with passwordless sudo.
M.DEFAULT_COMMANDS = {
    -- any Linux
    { name = "Uptime", cmd = "uptime" },
    { name = "System info", cmd = "uname -a; cat /etc/os-release", os = "linux" },
    { name = "Disk space", cmd = "df -h" },
    { name = "Memory", cmd = "free -h", os = "linux" },
    { name = "Top processes (CPU)", cmd = "ps aux --sort=-%cpu | head -n 15", os = "linux" },
    { name = "Top processes (memory)", cmd = "ps aux --sort=-%mem | head -n 15", os = "linux" },
    { name = "Largest folders here", cmd = "du -xh --max-depth=1 . 2>/dev/null | sort -rh | head -n 15", os = "linux" },
    { name = "Network addresses", cmd = "ip -brief address", os = "linux" },
    { name = "Listening ports", cmd = "ss -tuln", os = "linux" },
    { name = "Logged-in users", cmd = "who" },
    { name = "Temperature", cmd = "cat /sys/class/thermal/thermal_zone*/temp", os = "linux" },
    { name = "Failed services", cmd = "systemctl --failed", os = "linux" },
    { name = "Service status", cmd = "systemctl status --no-pager ", os = "linux" },
    { name = "Restart a service", cmd = "sudo systemctl restart ", os = "linux" },
    { name = "Recent errors", cmd = "journalctl -p err -b -n 30 --no-pager", os = "linux" },
    { name = "Restart", cmd = "sudo reboot", os = "linux" },
    { name = "Shut down", cmd = "sudo shutdown -h now", os = "linux" },
    -- Docker and ZFS (TrueNAS and others)
    { name = "Docker: containers", cmd = "docker ps --format 'table {{.Names}}\t{{.Status}}'", os = "linux" },
    { name = "Docker: all containers", cmd = "docker ps -a --format 'table {{.Names}}\t{{.Status}}'", os = "linux" },
    { name = "Docker: disk use", cmd = "docker system df", os = "linux" },
    { name = "Docker Compose: status", cmd = "docker compose ps", os = "linux" },
    { name = "Docker Compose: update", cmd = "docker compose pull && docker compose up -d", os = "linux" },
    { name = "ZFS: pool status", cmd = "zpool status", os = "linux" },
    { name = "ZFS: pool space", cmd = "zpool list", os = "linux" },
    -- Debian, Ubuntu, Raspberry Pi OS
    { name = "Debian/Ubuntu: apt update", cmd = "sudo apt update", os = "debian", since = 2 },
    { name = "Debian/Ubuntu: updates", cmd = "apt list --upgradable 2>/dev/null", os = "debian" },
    { name = "Debian/Ubuntu: update and upgrade", cmd = "sudo apt update && sudo apt full-upgrade -y", os = "debian" },
    { name = "Debian/Ubuntu: install a package", cmd = "sudo apt install -y ", os = "debian", since = 2 },
    { name = "Debian/Ubuntu: search packages", cmd = "apt search ", os = "debian", since = 2 },
    { name = "Debian/Ubuntu: clean up", cmd = "sudo apt autoremove -y && sudo apt clean", os = "debian" },
    { name = "Debian/Ubuntu: restart needed?", cmd = "cat /var/run/reboot-required 2>/dev/null || echo 'No restart needed'", os = "debian" },
    -- Fedora, RHEL, Rocky, Alma, CentOS
    { name = "Fedora/RHEL: updates", cmd = "dnf check-update", os = "fedora" },
    { name = "Fedora/RHEL: upgrade", cmd = "sudo dnf upgrade -y", os = "fedora" },
    { name = "Fedora/RHEL: clean up", cmd = "sudo dnf autoremove -y && sudo dnf clean all", os = "fedora" },
    { name = "Fedora/RHEL: restart needed?", cmd = "dnf needs-restarting -r", os = "fedora" },
    -- Arch, Manjaro, EndeavourOS (yay: the AUR helper, where it's installed)
    { name = "Arch: updates", cmd = "checkupdates", os = "arch" },
    { name = "Arch: sync package lists", cmd = "sudo pacman -Sy", os = "arch", since = 2 },
    { name = "Arch: upgrade", cmd = "sudo pacman -Syu --noconfirm", os = "arch" },
    { name = "Arch: install a package", cmd = "sudo pacman -S --noconfirm ", os = "arch", since = 2 },
    { name = "Arch: search packages", cmd = "pacman -Ss ", os = "arch", since = 2 },
    { name = "Arch: package info", cmd = "pacman -Qi ", os = "arch", since = 2 },
    { name = "Arch: explicitly installed", cmd = "pacman -Qe", os = "arch", since = 2 },
    { name = "Arch: orphan packages", cmd = "pacman -Qdt", os = "arch" },
    { name = "Arch: clean package cache", cmd = "sudo paccache -r", os = "arch" },
    { name = "Arch: yay updates (with AUR)", cmd = "yay -Qu", os = "arch", since = 2 },
    { name = "Arch: yay upgrade (with AUR)", cmd = "yay -Syu --noconfirm", os = "arch", since = 2 },
    { name = "Arch: yay search (with AUR)", cmd = "yay -Ss ", os = "arch", since = 2 },
    { name = "Arch: yay clean cache", cmd = "yay -Sc --noconfirm", os = "arch", since = 2 },
    -- openSUSE, Alpine
    { name = "openSUSE: updates", cmd = "zypper list-updates", os = "opensuse" },
    { name = "openSUSE: upgrade", cmd = "sudo zypper --non-interactive update", os = "opensuse" },
    { name = "Alpine: updates", cmd = "apk list --upgradable", os = "alpine" },
    { name = "Alpine: upgrade", cmd = "sudo apk upgrade", os = "alpine" },
    -- Flatpak, Snap
    { name = "Flatpak: update", cmd = "flatpak update -y", os = "linux" },
    { name = "Snap: update", cmd = "sudo snap refresh", os = "linux" },
    -- Raspberry Pi
    { name = "Raspberry Pi: temperature", cmd = "vcgencmd measure_temp", os = "raspberrypi" },
    { name = "Raspberry Pi: throttling", cmd = "vcgencmd get_throttled", os = "raspberrypi" },
    -- Windows (OpenSSH Server)
    { name = "Windows: system info", cmd = "systeminfo", os = "windows" },
    { name = "Windows: running programs", cmd = "tasklist", os = "windows" },
    { name = "Windows: disk space", cmd = "wmic logicaldisk get caption,freespace,size", os = "windows" },
    { name = "Windows: restart", cmd = "shutdown /r /t 0", os = "windows" },
    { name = "Windows: shut down", cmd = "shutdown /s /t 0", os = "windows" },
    -- macOS
    { name = "macOS: updates", cmd = "softwareupdate -l", os = "macos" },
    { name = "macOS: battery", cmd = "pmset -g batt", os = "macos" },
    { name = "macOS: restart", cmd = "sudo shutdown -r now", os = "macos", since = 2 },
    -- FreeBSD
    { name = "FreeBSD: packages to upgrade", cmd = "pkg upgrade -n", os = "freebsd", since = 3 },
    { name = "FreeBSD: upgrade packages", cmd = "sudo pkg upgrade -y", os = "freebsd", since = 3 },
    { name = "FreeBSD: system updates", cmd = "sudo freebsd-update fetch install", os = "freebsd", since = 3 },
    { name = "FreeBSD: enabled services", cmd = "service -e", os = "freebsd", since = 3 },
    { name = "FreeBSD: listening ports", cmd = "sockstat -4l", os = "freebsd", since = 3 },
    { name = "FreeBSD: memory", cmd = "top -b -d 1 | head -n 6", os = "freebsd", since = 3 },
    { name = "FreeBSD: restart", cmd = "sudo shutdown -r now", os = "freebsd", since = 3 },
    -- pfSense (FreeBSD; signed in as admin or root, so no sudo)
    { name = "pfSense: check for updates", cmd = "pfSense-upgrade -c", os = "pfsense", since = 3 },
    { name = "pfSense: firewall info", cmd = "pfctl -si", os = "pfsense", since = 3 },
    { name = "pfSense: firewall rules", cmd = "pfctl -sr", os = "pfsense", since = 3 },
    { name = "pfSense: states", cmd = "pfctl -ss | head -n 50", os = "pfsense", since = 3 },
    { name = "pfSense: routes", cmd = "netstat -rn", os = "pfsense", since = 3 },
    { name = "pfSense: interfaces", cmd = "ifconfig -a", os = "pfsense", since = 3 },
    { name = "pfSense: listening ports", cmd = "sockstat -4l", os = "pfsense", since = 3 },
    { name = "pfSense: reload the firewall rules", cmd = "/etc/rc.filter_configure", os = "pfsense", since = 3 },
    { name = "pfSense: restart the web interface", cmd = "/etc/rc.restart_webgui", os = "pfsense", since = 3 },
    { name = "pfSense: restart", cmd = "shutdown -r now", os = "pfsense", since = 3 },
    -- TrueNAS (SCALE: Debian, admin with sudo), TrueNAS CORE (FreeBSD, root)
    { name = "TrueNAS: pool status", cmd = "zpool status", os = "truenas", since = 4 },
    { name = "TrueNAS: datasets", cmd = "zfs list -o name,used,avail,mountpoint", os = "truenas", since = 4 },
    { name = "TrueNAS: snapshots", cmd = "zfs list -t snapshot -o name,used,creation", os = "truenas", since = 4 },
    { name = "TrueNAS: alerts", cmd = "sudo midclt call alert.list | python3 -c \"import json,sys; [print(a['formatted']) for a in json.load(sys.stdin)]\"", os = "truenas", since = 4 },
    { name = "TrueNAS: start a scrub", cmd = "sudo zpool scrub ", os = "truenas", since = 4 },
    { name = "TrueNAS CORE: pool status", cmd = "zpool status", os = "truenascore", since = 4 },
    { name = "TrueNAS CORE: datasets", cmd = "zfs list -o name,used,avail,mountpoint", os = "truenascore", since = 4 },
    { name = "TrueNAS CORE: alerts", cmd = "midclt call alert.list | python3 -c \"import json,sys; [print(a['formatted']) for a in json.load(sys.stdin)]\"", os = "truenascore", since = 4 },
    -- Proxmox VE (root)
    { name = "Proxmox: version", cmd = "pveversion -v", os = "proxmox", since = 4 },
    { name = "Proxmox: VMs", cmd = "qm list", os = "proxmox", since = 4 },
    { name = "Proxmox: containers", cmd = "pct list", os = "proxmox", since = 4 },
    { name = "Proxmox: storage", cmd = "pvesm status", os = "proxmox", since = 4 },
    { name = "Proxmox: cluster", cmd = "pvecm status", os = "proxmox", since = 4 },
    { name = "Proxmox: start a VM", cmd = "qm start ", os = "proxmox", since = 4 },
    { name = "Proxmox: shut down a VM", cmd = "qm shutdown ", os = "proxmox", since = 4 },
    { name = "Proxmox: update and upgrade", cmd = "apt update && apt dist-upgrade", os = "proxmox", since = 4 },
    -- ReadyNAS OS (root)
    { name = "ReadyNAS: RAID status", cmd = "cat /proc/mdstat", os = "readynas", since = 4 },
    { name = "ReadyNAS: volumes", cmd = "btrfs filesystem show", os = "readynas", since = 4 },
    { name = "ReadyNAS: volume space", cmd = "btrfs filesystem df ", os = "readynas", since = 4 },
}

-- Run once on a host whose system is detected: Linux prints /etc/os-release
-- (and a Raspberry Pi its model, pfSense its /etc/platform), a Mac "Darwin",
-- FreeBSD "FreeBSD", Windows (cmd) its version. First, a NAS's or
-- hypervisor's mark (cmd skips those: its && chain fails until ver).
M.DETECT_CMD = "command -v midclt >/dev/null 2>&1 && echo TrueNAS; command -v pveversion >/dev/null 2>&1 && echo Proxmox; [ -d /frontview ] && echo ReadyNAS; "
    .. "cat /etc/os-release 2>/dev/null && cat /proc/device-tree/model 2>/dev/null || cat /etc/platform 2>/dev/null; uname -s 2>/dev/null || ver"

local OS_OF_ID = {
    debian = "debian", ubuntu = "debian", linuxmint = "debian", pop = "debian", elementary = "debian",
    kali = "debian", raspbian = "raspberrypi",
    fedora = "fedora", rhel = "fedora", centos = "fedora", rocky = "fedora", almalinux = "fedora", ol = "fedora",
    amzn = "fedora", nobara = "fedora",
    arch = "arch", manjaro = "arch", endeavouros = "arch", garuda = "arch", cachyos = "arch", artix = "arch",
    opensuse = "opensuse", ["opensuse-leap"] = "opensuse", ["opensuse-tumbleweed"] = "opensuse", suse = "opensuse",
    sles = "opensuse",
    alpine = "alpine",
    freebsd = "freebsd",
}

--- The system in what M.DETECT_CMD printed: an M.OSES id, or nil.
function M.detectOS(text)
    text = tostring(text or "")
    if text:find("Raspberry Pi", 1, true) then return "raspberrypi" end
    -- (pfSense: /etc/platform; its os-release, when it has one, says FreeBSD)
    if text:find("pfSense", 1, true) then return "pfsense" end
    -- (TrueNAS: its midclt; SCALE's os-release says Debian, CORE is FreeBSD)
    if text:find("TrueNAS", 1, true) then
        return text:find("FreeBSD", 1, true) and "truenascore" or "truenas"
    end
    if text:find("Proxmox", 1, true) then return "proxmox" end
    if text:find("ReadyNAS", 1, true) then return "readynas" end
    local id = text:match("\nID=\"?([%w%-%._]+)") or text:match("^ID=\"?([%w%-%._]+)")
    local like = text:match("\nID_LIKE=\"?([^\"\n]+)") or ""
    if id then
        id = id:lower()
        if OS_OF_ID[id] then return OS_OF_ID[id] end
        for w in like:lower():gmatch("%S+") do
            if OS_OF_ID[w] then return OS_OF_ID[w] end
        end
        return "linux"
    end
    if text:find("Darwin", 1, true) then return "macos" end
    if text:find("Microsoft Windows", 1, true) then return "windows" end
    if text:find("FreeBSD", 1, true) then return "freebsd" end
    if text:find("Linux", 1, true) then return "linux" end
    return nil
end

function M.osName(id)
    if id == nil then return "Any system" end
    if id == "linux" then return "Any Linux" end
    for __, o in ipairs(M.OSES) do
        if o.id == id then return o.name end
    end
    return id
end

local OS_IDS = { linux = true }
for __, o in ipairs(M.OSES) do OS_IDS[o.id] = true end

--- A host's system: set by hand, or detected ("auto", the default); nil
-- when not known yet.
function M.hostOS(h)
    if h.os and h.os ~= "auto" then return h.os end
    return h.detected
end

--- Whether a command (os: nil any system, "linux" any Linux, or one system)
-- fits a system (nil: not known, so everything fits).
function M.fits(c, os)
    if os == nil or c.os == nil or c.os == os then return true end
    if c.os == "linux" then return not NOT_LINUX[os] end
    -- Raspberry Pi OS is Debian
    if c.os == "debian" and os == "raspberrypi" then return true end
    return false
end

local BUILTIN = {}
for __, c in ipairs(M.DEFAULT_COMMANDS) do BUILTIN[c.cmd] = c end

--- Whether a command is one of the built-in ones (by its command).
function M.isBuiltIn(c) return BUILTIN[c.cmd] ~= nil end

--- The commands a filter shows: "all", "custom" (your own: not built in),
-- or a system's id (the commands that fit it).
function M.filter(list, f)
    local out = {}
    for __, c in ipairs(list) do
        local ok
        if f == nil or f == "all" then
            ok = true
        elseif f == "custom" then
            ok = not M.isBuiltIn(c)
        else
            ok = M.fits(c, f)
        end
        if ok then out[#out + 1] = c end
    end
    return out
end

--- A filter's name: "All", "Custom", "Debian/Ubuntu".
function M.filterName(f)
    if f == nil or f == "all" then return "All" end
    if f == "custom" then return "Custom" end
    return M.osName(f)
end

M.AUTHS = { "key", "password", "ask" }

-- ------------------------------------------------------------------ data

function M.newId(data, prefix)
    data.nextId = (tonumber(data.nextId) or 1)
    local id = prefix .. data.nextId
    data.nextId = data.nextId + 1
    return id
end

local function cleanCommands(data, list)
    local out = {}
    for __, c in ipairs(type(list) == "table" and list or {}) do
        if type(c) == "table" and type(c.cmd) == "string" and c.cmd:match("%S") then
            out[#out + 1] = { id = type(c.id) == "string" and c.id or M.newId(data, "c"),
                name = type(c.name) == "string" and c.name or "", cmd = c.cmd,
                os = OS_IDS[c.os] and c.os or nil }
        end
    end
    return out
end

--- Fills in what's missing (a new install gets the command list), so the
-- rest can count on every field.
function M.normalize(data)
    if type(data) ~= "table" then data = {} end
    data.nextId = tonumber(data.nextId) or 1
    -- New ids come after every id already there (some may be typed by hand).
    local function after(list)
        for __, x in ipairs(type(list) == "table" and list or {}) do
            local n = type(x) == "table" and tonumber(tostring(x.id):match("^%a(%d+)$"))
            if n and n >= data.nextId then data.nextId = n + 1 end
            if type(x) == "table" and x.commands then after(x.commands) end
        end
    end
    after(data.hosts)
    after(data.keys)
    after(data.commands)
    if type(data.hosts) ~= "table" then data.hosts = {} end
    if type(data.keys) ~= "table" then data.keys = {} end
    if type(data.commands) ~= "table" then
        data.commands = {}
        for __, c in ipairs(M.DEFAULT_COMMANDS) do
            data.commands[#data.commands + 1] = { name = c.name, cmd = c.cmd, os = c.os }
        end
        data.builtInVersion = M.BUILTIN_VERSION
    end
    data.commands = cleanCommands(data, data.commands)
    -- An older list: the built-in commands get their system, and the ones
    -- added since are added once.
    local v = tonumber(data.builtInVersion) or 1
    if v < M.BUILTIN_VERSION then
        local have = {}
        for __, c in ipairs(data.commands) do
            local b = BUILTIN[c.cmd]
            if b and c.os == nil then c.os = b.os end
            have[c.cmd] = true
        end
        for __, c in ipairs(M.DEFAULT_COMMANDS) do
            if (c.since or 1) > v and not have[c.cmd] then
                data.commands[#data.commands + 1] = { name = c.name, cmd = c.cmd, os = c.os }
            end
        end
        data.builtInVersion = M.BUILTIN_VERSION
    end
    -- Ids are unique: a host or command copied by hand gets a new one.
    local seen = {}
    local function fresh(item, prefix)
        if type(item.id) ~= "string" or seen[item.id] then item.id = M.newId(data, prefix) end
        seen[item.id] = true
    end
    for __, c in ipairs(data.commands) do fresh(c, "c") end
    local hosts = {}
    for __, h in ipairs(data.hosts) do
        if type(h) == "table" then
            fresh(h, "h")
            h.name = type(h.name) == "string" and h.name or ""
            h.address = type(h.address) == "string" and h.address or ""
            h.user = type(h.user) == "string" and h.user or ""
            h.port = tonumber(h.port) or 22
            if h.auth ~= "key" and h.auth ~= "password" and h.auth ~= "ask" then h.auth = "key" end
            if not OS_IDS[h.os] then h.os = "auto" end
            if not OS_IDS[h.detected] then h.detected = nil end
            h.commands = cleanCommands(data, h.commands)
            for __, c in ipairs(h.commands) do fresh(c, "c") end
            local recent = {}
            for __, r in ipairs(type(h.recent) == "table" and h.recent or {}) do
                if type(r) == "string" then recent[#recent + 1] = r end
            end
            h.recent = recent
            hosts[#hosts + 1] = h
        end
    end
    data.hosts = hosts
    local keys = {}
    for __, k in ipairs(data.keys) do
        if type(k) == "table" then
            fresh(k, "k")
            keys[#keys + 1] = k
        end
    end
    data.keys = keys
    return data
end

local function find(list, id)
    for i, x in ipairs(list) do
        if x.id == id then return x, i end
    end
end

function M.host(data, id) return find(data.hosts, id) end
function M.key(data, id) return find(data.keys, id) end

--- A saved command of a host, by "<host id>/<command id>".
function M.hostCommand(data, ref)
    local hid, cid = tostring(ref or ""):match("^([^/]+)/(.+)$")
    local h = hid and M.host(data, hid)
    if not h then return nil end
    local c = find(h.commands, cid)
    if c then return h, c end
end

--- Why a host can't be saved, or nil.
function M.checkHost(h)
    if not h.address or not h.address:match("%S") then return "Enter the address." end
    if h.address:find("%s") then return "The address can't have spaces." end
    if h.address:sub(1, 1) == "-" then return "The address can't start with -." end
    if not h.user or not h.user:match("%S") then return "Enter the user name." end
    if h.user:find("%s") or h.user:sub(1, 1) == "-" then return "Check the user name." end
    local port = tonumber(h.port)
    if not port or port < 1 or port > 65535 or port % 1 ~= 0 then return "The port is a number from 1 to 65535." end
    return nil
end

--- The host's name, or its address when it has none.
function M.hostName(h)
    if h.name and h.name:match("%S") then return h.name end
    return h.address or ""
end

--- "pi@192.168.1.20", with ":2222" when the port isn't 22.
function M.hostLabel(h)
    local s = (h.user or "") .. "@" .. (h.address or "")
    if tonumber(h.port) and tonumber(h.port) ~= 22 then s = s .. ":" .. h.port end
    return s
end

--- A command's name, or the command itself when it has none.
function M.commandName(c)
    if c.name and c.name:match("%S") then return c.name end
    return c.cmd or ""
end

--- Puts cmd at the top of the host's recent commands (once, the newest 10).
function M.addRecent(h, cmd)
    if not cmd or not cmd:match("%S") then return end
    local recent = { cmd }
    for __, r in ipairs(h.recent or {}) do
        if r ~= cmd and #recent < M.RECENT_MAX then recent[#recent + 1] = r end
    end
    h.recent = recent
end

-- How many runs History keeps (every host).
M.HISTORY_MAX = 300

--- A run kept in History (newest first): { host (id), cmd, at }.
function M.addHistory(data, host_id, cmd, at)
    if not cmd or not cmd:match("%S") then return end
    data.history = type(data.history) == "table" and data.history or {}
    table.insert(data.history, 1, { host = host_id, cmd = cmd, at = at or os.time() })
    while #data.history > M.HISTORY_MAX do table.remove(data.history) end
end

--- History's runs whose command or host name has `q` (any case); all
-- without q.
function M.searchHistory(data, q)
    local out = {}
    q = q and q:lower() or ""
    for __, r in ipairs(type(data.history) == "table" and data.history or {}) do
        local h = M.host(data, r.host)
        if q == "" or r.cmd:lower():find(q, 1, true) or (h and M.hostName(h):lower():find(q, 1, true)) then
            out[#out + 1] = r
        end
    end
    return out
end

--- Adds the built-in commands missing from the command list (by their
-- command); returns how many were added.
function M.addBuiltIn(data)
    local have = {}
    for __, c in ipairs(data.commands) do have[c.cmd] = true end
    local n = 0
    for __, c in ipairs(M.DEFAULT_COMMANDS) do
        if not have[c.cmd] then
            data.commands[#data.commands + 1] = { id = M.newId(data, "c"), name = c.name, cmd = c.cmd, os = c.os }
            n = n + 1
        end
    end
    return n
end

--- Moves item i of a list up (-1) or down (+1); returns its new place.
function M.move(list, i, dir)
    local j = i + dir
    if j < 1 or j > #list then return i end
    list[i], list[j] = list[j], list[i]
    return j
end

--- Hosts that use a key, by key id (to say a key is in use before deleting).
function M.hostsUsingKey(data, kid)
    local out = {}
    for __, h in ipairs(data.hosts) do
        if h.auth == "key" and h.key == kid then out[#out + 1] = M.hostName(h) end
    end
    return out
end

--- The Apps launcher's line: "3 hosts", "1 host", "No hosts".
function M.appsLine(data)
    local n = #data.hosts
    if n == 0 then return "No hosts" end
    return n == 1 and "1 host" or n .. " hosts"
end

--- Every how many minutes (0: off) a host is checked: its own, or every
-- host's (`all`: nil is 15).
function M.checkEvery(host, all)
    if host.check ~= nil then return host.check end
    if all == nil then return 15 end
    return all
end

--- In how many seconds the next check is due (0: now), or nil when none
-- can be: checks off, no hosts, every host paused or not one that can be
-- read without asking (canCheck(host), optional). A failed read waits its
-- turn like a good one.
function M.nextCheckIn(hosts, all, now, canCheck)
    local soonest
    for __, h in ipairs(hosts or {}) do
        local every = M.checkEvery(h, all)
        if every and every > 0 and not h.paused and (not canCheck or canCheck(h)) then
            local since = math.max(h.last and h.last.at or 0, h.failedAt or 0)
            local left = math.max(0, since + every * 60 - now)
            if not soonest or left < soonest then soonest = left end
        end
    end
    return soonest
end

--- The gesture action's choices: ids "<host id>/<command id>" and labels
-- "Pi: Uptime".
function M.gestureChoices(data)
    local ids, labels = {}, {}
    for __, h in ipairs(data.hosts) do
        for __, c in ipairs(h.commands) do
            ids[#ids + 1] = h.id .. "/" .. c.id
            labels[#labels + 1] = M.hostName(h) .. ": " .. M.commandName(c)
        end
    end
    return ids, labels
end

-- ------------------------------------------------------------------ dbclient

function M.quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- dbclient's arguments for a host: opts.cmd (a command to run; none for a
-- shell), opts.pty (a terminal, for a live session), opts.keyFile,
-- opts.trust (accept and save an unknown host key), opts.probe (only to read
-- the host key: no sign-in).
function M.dbclientArgs(dbclient, h, opts)
    opts = opts or {}
    local a = { dbclient, opts.pty and "-t" or "-T" }
    if opts.trust then a[#a + 1] = "-y" end
    if not opts.pty then
        a[#a + 1] = "-o"
        a[#a + 1] = "BatchMode=yes"
    end
    if opts.probe then
        a[#a + 1] = "-o"
        a[#a + 1] = "PasswordAuthentication=no"
    end
    if opts.keyFile and not opts.probe then
        a[#a + 1] = "-i"
        a[#a + 1] = opts.keyFile
    end
    -- Keepalive: a session on a link that went away ends instead of waiting.
    a[#a + 1] = "-K"
    a[#a + 1] = "30"
    a[#a + 1] = "-p"
    a[#a + 1] = tostring(tonumber(h.port) or 22)
    a[#a + 1] = "-l"
    a[#a + 1] = h.user
    a[#a + 1] = h.address
    if opts.probe then
        a[#a + 1] = "true"
    elseif opts.cmd then
        a[#a + 1] = opts.cmd
    end
    return a
end

function M.shellLine(args)
    local q = {}
    for i, s in ipairs(args) do q[i] = M.quote(s) end
    return table.concat(q, " ")
end

--- Removes colour and cursor codes, backspaces and carriage returns (a line
-- redrawn with \r keeps what was drawn last).
function M.stripAnsi(s)
    s = s:gsub("\27%][^\7\27]*\7", ""):gsub("\27%][^\7\27]*\27\\", "")
    s = s:gsub("\27%[[%d;?]*[ -/]*[@-~]", ""):gsub("\27[()][%w]", ""):gsub("\27[%w=>]", "")
    s = s:gsub("\r\n", "\n")
    s = s:gsub("[^\n]*\r", "")
    local prev
    repeat
        prev = s
        s = s:gsub("[^\8\n]\8", "", 1)
    until s == prev
    s = s:gsub("\8", "")
    return s
end

--- Reads what dbclient printed (with the command's own output): { output,
-- problem, … }. problem is nil (it ran), "unknown_host" (keytype,
-- fingerprint), "changed_host" (fingerprint, expected), "signin", "connect"
-- (message) or "other" (message).
function M.parseRun(text)
    text = text or ""
    local r = {}
    local unknown_fp
    local kept = {}
    local skip_rest = false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local mine = line:match("^%S*dbclient: (.*)$")
        if skip_rest then
            -- the lines after a host key warning are dbclient's too
            local fp = line:match("^Fingerprint is (%S+)")
            if fp then r.fingerprint = fp end
            local ex = line:match("^Expected (%S+)")
            if ex then r.expected = ex end
        elseif line:match("is not in the trusted hosts file") then
            r.problem = "unknown_host"
        elseif line:match("^%(%S+ fingerprint %S+%)$") then
            r.keytype, unknown_fp = line:match("^%((%S+) fingerprint (%S+)%)$")
        elseif line:match("host key mismatch for") then
            r.problem = "changed_host"
            skip_rest = true
        elseif line:match("^Login for %S+@%S+$") then
            -- dbclient's line before each password try
            r.tries = (r.tries or 0) + 1
        elseif line:match("key accepted unconditionally") then
            r.accepted = true
        elseif mine then
            local why = mine:match("exited: (.*)$") or mine:match("^Exited: (.*)$") or mine
            r.message = why
        else
            kept[#kept + 1] = line
        end
    end
    if r.problem == "unknown_host" or r.accepted then r.fingerprint = unknown_fp end
    -- the trailing blank lines dbclient puts before its own messages
    while #kept > 0 and kept[#kept] == "" do kept[#kept] = nil end
    r.output = M.stripAnsi(table.concat(kept, "\n"))
    if not r.problem and r.message and r.message ~= "" then
        local m = r.message
        if m:find("No auth methods") or m:find("[Pp]assword") or m:find("auth") then
            r.problem = "signin"
        elseif m:find("Connect failed") or m:find("[Rr]efused") or m:find("route") or m:find("timed out")
            or m:find("resolve") or m:find("not known") or m:find("unreachable") then
            r.problem = "connect"
            r.message = m:gsub("^Connect failed: ", "")
        elseif r.tries and #kept == 0 then
            r.problem = "signin" -- the device hung up after wrong passwords
        elseif m:find("Remote closed") or m:find("[Dd]isconnect") then
            r.problem = nil -- the device closed the connection (a reboot)
        else
            r.problem = "other"
        end
    end
    return r
end

-- ------------------------------------------------------------------ known_hosts

local function hostField(line)
    if line:match("^%s*#") then return nil end
    return line:match("^%s*(%S+)%s+%S+%s+%S+")
end

local function fieldHas(field, host)
    for name in field:gmatch("[^,]+") do
        if name == host or name:match("^%[(.-)%]:%d+$") == host then return true end
    end
    return false
end

--- Whether known_hosts' text has a key for this address.
function M.knownHas(text, host)
    for line in (text or ""):gmatch("[^\n]+") do
        local f = hostField(line)
        if f and fieldHas(f, host) then return true end
    end
    return false
end

--- known_hosts' text without this address's lines; and how many went.
function M.knownRemove(text, host)
    local out, n = {}, 0
    for line in (text or ""):gmatch("[^\n]+") do
        local f = hostField(line)
        if f and fieldHas(f, host) then
            n = n + 1
        else
            out[#out + 1] = line
        end
    end
    return #out > 0 and table.concat(out, "\n") .. "\n" or "", n
end

--- The last `max` bytes of text, from a line start; and whether it was cut.
function M.tail(text, max)
    max = max or M.OUTPUT_MAX
    if #text <= max then return text, false end
    local s = text:sub(-max)
    local nl = s:find("\n")
    if nl then s = s:sub(nl + 1) end
    return s, true
end

-- ------------------------------------------------------------------ AI

-- Names before a value that is blanked ("password: x", "API_TOKEN=x",
-- "secret": "x"); lower case.
local SECRET_NAMES = { "password", "passwd", "passphrase", "secret", "token", "api_key", "apikey", "api-key",
    "access_key", "private_key", "credential", "auth_key", "session_key" }
-- Token formats blanked wherever they are.
local SECRET_TOKENS = {
    "%f[%w]gh[pousr]_[%w]+", "%f[%w]github_pat_[%w_]+", "%f[%w]glpat%-[%w_%-]+", "%f[%w]xox[abprs]%-[%w%-]+",
    "%f[%w]sk%-[%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-]*",
    "%f[%w]AKIA[%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d]",
    "%f[%w]eyJ[%w_%-]+%.[%w_%-]+%.[%w_%-]+",
}

--- Text with obvious secrets blanked as [hidden], before it goes to an AI:
-- private key blocks, values after password/token/secret names, Bearer and
-- Basic sign-ins, passwords in URLs, well-known token formats, and the
-- literal strings in `secrets` (the saved passwords). Returns text, count.
function M.redact(text, secrets)
    text = tostring(text or "")
    local n = 0
    local function count(s, k)
        n = n + (k or 0)
        return s
    end
    -- whole private key blocks
    text = count(text:gsub("%-%-%-%-%-BEGIN [%u%d ]*PRIVATE KEY%-%-%-%-%-.-%-%-%-%-%-END [%u%d ]*PRIVATE KEY%-%-%-%-%-",
        "[hidden private key]"))
    -- (a block cut off at the end of the text)
    text = count(text:gsub("%-%-%-%-%-BEGIN [%u%d ]*PRIVATE KEY%-%-%-%-%-.*$", "[hidden private key]"))
    -- the saved passwords, wherever they show
    for __, s in ipairs(secrets or {}) do
        if type(s) == "string" and #s >= 3 then
            local at = 1
            while true do
                local a, b = text:find(s, at, true)
                if not a then break end
                text = text:sub(1, a - 1) .. "[hidden]" .. text:sub(b + 1)
                n = n + 1
                at = a + 8
            end
        end
    end
    -- user:password@ in URLs
    text = count(text:gsub("(%a[%w+.%-]*://[^/%s:@]+):[^/%s@]+@", "%1:[hidden]@"))
    -- Authorization headers and the like
    text = count(text:gsub("([Bb]earer%s+)[%w%-%._~+/]+=*", "%1[hidden]"))
    text = count(text:gsub("([Bb]asic%s+)[%w+/]+=*", "%1[hidden]"))
    for __, p in ipairs(SECRET_TOKENS) do text = count(text:gsub(p, "[hidden]")) end
    -- name = value, name: value (line by line; names in any case)
    local out = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local low = line:lower()
        for __, name in ipairs(SECRET_NAMES) do
            local at = 1
            while true do
                local a, b = low:find(name, at, true)
                if not a then break end
                -- the rest of the name, then = or : (with quotes and spaces around)
                local __, sep = low:find("^[%w_%.%-]*[\"']?%s*[:=]+%s*[\"']?", b + 1)
                local value = sep and line:match("^[^%s\"',;]+", sep + 1)
                if value and value ~= "[hidden]" and value ~= "[hidden]@" then
                    line = line:sub(1, sep) .. "[hidden]" .. line:sub(sep + #value + 1)
                    low = line:lower()
                    n = n + 1
                end
                at = (sep or b) + 1
            end
        end
        out[#out + 1] = line
    end
    return table.concat(out, "\n"), n
end

--- "user@address" or "user@address:port" (as ssh takes it): user, address,
-- port (22 when not given), or nil, why.
function M.parseTarget(s)
    s = tostring(s or ""):match("^%s*(.-)%s*$")
    local user, rest = s:match("^([^@%s]+)@(%S+)$")
    if not user then return nil, "Type it as user@address, for example pi@192.168.1.20." end
    local address, port = rest:match("^%[(.+)%]:(%d+)$")
    if not address then address, port = rest:match("^([^:]+):(%d+)$") end
    if not address then address = rest end
    port = tonumber(port) or 22
    return user, address, port
end

--- Whether a command uses sudo (which asks for a password on most systems).
function M.usesSudo(cmd)
    return tostring(cmd or ""):find("%f[%w]sudo%f[%W]") ~= nil
end

--- Whether a run's output says sudo wanted a password it couldn't ask for
-- (a run without a terminal).
function M.sudoNeedsPassword(text)
    text = tostring(text or "")
    return text:find("sudo: a terminal is required", 1, true) ~= nil
        or text:find("sudo: a password is required", 1, true) ~= nil
        or text:find("no tty present", 1, true) ~= nil
        or text:find("sudo: no askpass program", 1, true) ~= nil
end

-- How much output goes to the AI (the last part: errors are usually there).
M.AI_LINES = 200
M.AI_MAX = 30 * 1024

--- The last part of output for the AI: "lines" (the last AI_LINES lines) or
-- "all" (up to AI_MAX bytes); and whether it was cut.
function M.aiPart(text, amount)
    text = tostring(text or "")
    local cut = false
    if amount ~= "all" then
        -- ("short": the last 50 lines, about what a screen shows)
        local max = amount == "short" and 50 or M.AI_LINES
        local lines = {}
        for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
        if lines[#lines] == "" then lines[#lines] = nil end
        if #lines > max then
            text = table.concat(lines, "\n", #lines - max + 1)
            cut = true
        end
    end
    local t, c = M.tail(text, M.AI_MAX)
    return t, cut or c
end

--- The part of a request about a command: the command and its output,
-- blanked (M.redact with the saved passwords).
function M.aiOutputText(cmd, output, amount, secrets)
    local part, cut = M.aiPart(M.stripAnsi(tostring(output or "")), amount)
    local text = (cmd and cmd ~= "" and ("Command: " .. cmd .. "\n\n") or "")
        .. (cut and "Output (only the last part):\n" or "Output:\n") .. part
    return (M.redact(text, secrets))
end

--- A follow-up: what was sent first, then each answer and the question
-- after it (turns = { { answer, question } }, the last one the new
-- question), the questions blanked.
function M.aiFollowUp(first, turns, secrets)
    local parts = { first }
    for __, t in ipairs(turns or {}) do
        if type(t) == "table" then
            if t.answer then parts[#parts + 1] = "\n\nYour answer:\n" .. tostring(t.answer) end
            if t.question then parts[#parts + 1] = "\n\nMy follow-up:\n" .. (M.redact(tostring(t.question), secrets)) end
        end
    end
    return table.concat(parts)
end

--- A question in a live session's AI chat: what the terminal shows now
-- (its last part, blanked), the conversation so far (turns = { { question,
-- answer } }) and the new question (blanked). selection (optional): the
-- part asked about, first, with only the terminal's last 20 lines around it.
function M.aiSessionText(screen, turns, question, amount, secrets, selection)
    local text = M.stripAnsi(tostring(screen or ""))
    local part, cut
    if selection then
        local lines = {}
        for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
        if lines[#lines] == "" then lines[#lines] = nil end
        cut = #lines > 20
        part = table.concat(lines, "\n", math.max(1, #lines - 19))
    else
        part, cut = M.aiPart(text, amount)
    end
    local parts = {}
    if selection then parts[#parts + 1] = "The part of the terminal I'm asking about:\n" .. M.stripAnsi(tostring(selection)) .. "\n\n" end
    parts[#parts + 1] = (cut and "The terminal now (its last part):\n" or "The terminal now:\n") .. part
    for __, t in ipairs(turns or {}) do
        if type(t) == "table" and t.question then
            parts[#parts + 1] = "\n\nMy question:\n" .. tostring(t.question)
            if t.answer then parts[#parts + 1] = "\n\nYour answer:\n" .. tostring(t.answer) end
        end
    end
    parts[#parts + 1] = "\n\nMy question:\n" .. tostring(question or "")
    return (M.redact(table.concat(parts), secrets))
end

--- The last `n` non-empty lines of a terminal's text (for a strip showing it).
function M.lastLines(text, n)
    local lines = {}
    for line in (M.stripAnsi(tostring(text or "")) .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = (line:gsub("%s+$", "")) end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    local from = math.max(1, #lines - (n or 3) + 1)
    return table.concat(lines, "\n", from)
end

--- The commands an answer suggests (lines "COMMAND: …"; without those,
-- the lines of its first ``` block), at most 5, and the answer to show
-- (those lines as "$ …", no ``` lines).
function M.aiCommands(answer)
    answer = tostring(answer or "")
    local cmds, seen, shown = {}, {}, {}
    local function add(c)
        c = c:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^`+", ""):gsub("`+$", ""):gsub("^%$%s+", "")
        if c ~= "" and not seen[c] and #cmds < 5 then
            seen[c] = true
            cmds[#cmds + 1] = c
        end
        return c
    end
    for line in (answer .. "\n"):gmatch("(.-)\n") do
        local c = line:match("^%s*%**[Cc][Oo][Mm][Mm][Aa][Nn][Dd]%**%s*:%**%s*(.+)$")
        if c then
            shown[#shown + 1] = "$ " .. add(c)
        else
            shown[#shown + 1] = line
        end
    end
    if #cmds == 0 then
        local block = answer:match("```[%w_%-]*\n(.-)```")
        if block then
            for line in block:gmatch("[^\n]+") do add(line) end
        end
    end
    local text = table.concat(shown, "\n"):gsub("```[%w_%-]*\n?", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return cmds, text
end

-- ------------------------------------------------------------------ web page

--- What the web page shows: everything but passwords (hasPassword says
-- whether one is saved).
function M.webState(data)
    local hosts = {}
    for __, h in ipairs(data.hosts) do
        local c = {}
        for k, v in pairs(h) do
            if k ~= "password" and k ~= "pin" then c[k] = v end
        end
        c.hasPassword = type(h.password) == "string" and h.password ~= ""
        c.hasPin = h.pin ~= nil
        hosts[#hosts + 1] = c
    end
    -- the command list with which are built in (for the page's Custom filter)
    local commands = {}
    for i, c in ipairs(data.commands) do
        commands[i] = { id = c.id, name = c.name, cmd = c.cmd, os = c.os, builtIn = M.isBuiltIn(c) }
    end
    return { hosts = hosts, commands = commands, keys = data.keys, oses = M.OSES }
end

--- For saving: the data without passwords, and the passwords by host id (in
-- a file of their own, so a backup can leave them out).
function M.splitPasswords(data)
    local out, pw = {}, {}
    for k, v in pairs(data) do out[k] = v end
    out.hosts = {}
    for i, h in ipairs(data.hosts or {}) do
        local c = {}
        for k, v in pairs(h) do
            if k ~= "password" then c[k] = v end
        end
        if type(h.password) == "string" and h.password ~= "" and h.id then pw[h.id] = h.password end
        out.hosts[i] = c
    end
    return out, pw
end

--- The saved passwords back on their hosts (a password left in the data
-- from before stays when there is none in pw).
function M.mergePasswords(data, pw)
    if type(pw) ~= "table" then return data end
    for __, h in ipairs(data.hosts or {}) do
        if type(pw[h.id]) == "string" then h.password = pw[h.id] end
    end
    return data
end

local function hostFrom(args, h)
    h = h or {}
    for __, k in ipairs({ "name", "address", "user" }) do
        if args[k] ~= nil then h[k] = tostring(args[k]):match("^%s*(.-)%s*$") end
    end
    if args.port ~= nil then h.port = tonumber(args.port) or args.port end
    if args.auth ~= nil then h.auth = args.auth end
    if args.os ~= nil then
        -- a change of system by hand: detect again when it's set back to auto
        if args.os ~= h.os then h.detected = nil end
        h.os = (OS_IDS[args.os] or args.os == "auto") and args.os or "auto"
    end
    if args.key ~= nil then h.key = args.key ~= "" and args.key or nil end
    -- a password left out (nil) stays as it was; "" removes it
    if args.password ~= nil then h.password = args.password ~= "" and tostring(args.password) or nil end
    return h
end

local function trim(x) return (tostring(x or ""):match("^%s*(.-)%s*$")) end

--- Groups from the page: a list, or "Home, Servers" (nil: none).
local function cleanGroups(g)
    local out, seen = {}, {}
    local function add(n)
        n = trim(n)
        if n ~= "" and not seen[n] then
            seen[n] = true
            out[#out + 1] = n
        end
    end
    if type(g) == "table" then
        for __, n in ipairs(g) do add(n) end
    else
        for n in (tostring(g or "") .. ","):gmatch("([^,]*),") do add(n) end
    end
    return #out > 0 and out or nil
end

--- The simple settings of a host (groups, mac, check, readOnOpen) from the
-- page's args, each in a table of one (nil is a value: it removes the
-- setting); or nil, why when one is wrong. They are all checked before any is kept.
local function hostExtras(args)
    local out = {}
    if args.groups ~= nil then out.groups = { cleanGroups(args.groups) } end
    if args.mac ~= nil then
        local mac = trim(args.mac)
        if mac ~= "" and not require("sshstats").magicPacket(mac) then
            return nil, "That isn't a MAC address (like dc:a6:32:01:02:03)."
        end
        out.mac = { mac ~= "" and mac:lower() or nil }
    end
    if args.check ~= nil then
        local n = tonumber(args.check)
        if not n then return nil, "Choose how often to check it." end
        -- (below 0: like every host)
        out.check = { n >= 0 and n or nil }
    end
    if args.readOnOpen ~= nil then
        out.readOnOpen = {}
        if args.readOnOpen == false then out.readOnOpen[1] = false end
    end
    return out
end

--- A host's stats choice, custom sensors and alerts from the page, checked
-- and cleaned: { stats, sensors, alerts, customAlerts } or nil, why.
-- args: { stats = { [id] = bool }, sensors = { { id?, name, cmd, kind, unit } },
-- alerts = { [id] = limit | true }, customAlerts = { { id?, what, op, value } } }.
local function cleanStats(args)
    local S = require("sshstats")
    local sensors, byId = {}, {}
    local list = type(args.sensors) == "table" and args.sensors or {}
    local n = 0
    for __, c in ipairs(list) do
        local k = tonumber(tostring(c.id or ""):match("^s(%d+)$"))
        if k and k > n then n = k end
    end
    for __, c in ipairs(list) do
        local cmd = tostring(c.cmd or ""):gsub("[\r\n]+", " ")
        if not cmd:match("%S") then return nil, "A custom sensor needs a command." end
        local kind
        for __, k in ipairs(S.SENSOR_KINDS) do if k.id == c.kind then kind = k.id end end
        if not kind then return nil, "Choose what the sensor gives." end
        local id = tostring(c.id or "")
        if not id:match("^s%d+$") or byId[id] then
            n = n + 1
            id = "s" .. n
        end
        local e = { id = id, name = trim(c.name), cmd = cmd, kind = kind }
        if kind == "number" and trim(c.unit) ~= "" then e.unit = trim(c.unit) end
        byId[id] = e
        sensors[#sensors + 1] = e
    end
    local stats = {}
    for id, on in pairs(type(args.stats) == "table" and args.stats or {}) do
        id = tostring(id)
        local cs = id:match("^cs_(.+)$")
        if (S.byId[id] or (cs and byId[cs])) and type(on) == "boolean" then stats[id] = on end
    end
    local alerts = {}
    for id, v in pairs(type(args.alerts) == "table" and args.alerts or {}) do
        id = tostring(id)
        local a
        for __, x in ipairs(S.ALERTS) do if x.id == id then a = x end end
        local cs = id:match("^cs_(.+)$")
        if a then
            if a.yesno then
                if v == true then alerts[id] = true end
            elseif tonumber(v) and tonumber(v) > 0 then
                alerts[id] = tonumber(v)
            end
        elseif cs and byId[cs] then
            if byId[cs].kind == "ok" then
                if v == true then alerts[id] = true end
            elseif byId[cs].kind ~= "text" and tonumber(v) then
                alerts[id] = tonumber(v)
            end
        end
    end
    local custom, top, seen = {}, 0, {}
    local mine = type(args.customAlerts) == "table" and args.customAlerts or {}
    for __, a in ipairs(mine) do top = math.max(top, tonumber(a.id) or 0) end
    local watch = {}
    for __, w in ipairs(S.watchable(sensors)) do watch[w.id] = w end
    for __, a in ipairs(mine) do
        local w = watch[tostring(a.what)]
        if not w then return nil, "A custom alert watches something that isn't there." end
        local op
        for __, o in ipairs(S.OPS) do if o.id == a.op then op = o.id end end
        if not op then return nil, "Choose a test for the alert." end
        local value = trim(a.value)
        if value == "" then return nil, "A custom alert needs a value." end
        if (op == "gt" or op == "lt") and not tonumber(value) then return nil, "Above and below need a number." end
        local id = tonumber(a.id)
        if not id or seen[id] then
            top = top + 1
            id = top
        end
        seen[id] = true
        custom[#custom + 1] = { id = id, what = w.id, op = op, value = tonumber(value) or value }
    end
    return { stats = stats, sensors = sensors, alerts = alerts, customAlerts = custom }
end

--- A host's quick commands from the page: ids from the system's list, or
-- "cmd:<command>|<name>" of its own; none given: the usual ones.
-- Returns { quick, icons } or nil, why.
local function cleanQuick(host, args)
    if args.quick == nil or args.quick == false then return {} end
    if type(args.quick) ~= "table" then return nil, "Choose the quick commands." end
    local S = require("sshstats")
    local d = host.last and host.last.v and host.last.v.docker
    local known = {}
    for __, q in ipairs(S.quickFor(host.os ~= "auto" and host.os or host.detected, d and d.ok)) do known[q.id] = true end
    local quick, icons = {}, {}
    local given = type(args.quickIcons) == "table" and args.quickIcons or {}
    for __, id in ipairs(args.quick) do
        id = tostring(id)
        local cmd = id:match("^cmd:(.*)|.*$")
        if known[id] then
            quick[#quick + 1] = id
        elseif cmd and cmd:match("%S") and not id:find("[\r\n]") then
            quick[#quick + 1] = id
            if type(given[id]) == "string" and given[id]:match("^[%w%-]+$") then icons[id] = given[id] end
        end
    end
    return { quick = quick, icons = next(icons) and icons or nil }
end

--- Changes from the web page (or the Kindle) to the data, in place: name is
-- saveHost { id?, name, address, user, port, auth, key, password?, groups, mac,
-- check (below 0: like every host), readOnOpen }, saveHostStats { id, stats,
-- sensors, alerts, customAlerts }, saveHostQuick { id, quick (false: the usual ones), quickIcons },
-- deleteHost { id }, saveCommands { list }, saveHostCommands { id, list },
-- addBuiltIn {} (the built-in commands missing from the list), renameKey { id, name }.
-- Returns a result table (saveHost: { id }) or nil, why.
function M.act(data, name, args)
    args = type(args) == "table" and args or {}
    if name == "saveHost" then
        local h = args.id and M.host(data, args.id)
        if args.id and not h then return nil, "No such host." end
        local new = hostFrom(args, h and {
            name = h.name, address = h.address, user = h.user, port = h.port, auth = h.auth,
            key = h.key, password = h.password, os = h.os, detected = h.detected } or { port = 22, auth = "key", os = "auto" })
        if new.auth ~= "key" and new.auth ~= "password" and new.auth ~= "ask" then return nil, "Choose how to sign in." end
        if new.auth == "key" and not (new.key and M.key(data, new.key)) then return nil, "Choose a key." end
        local why = M.checkHost(new)
        if why then return nil, why end
        local extras, ewhy = hostExtras(args)
        if not extras then return nil, ewhy end
        new.port = tonumber(new.port)
        if not h then
            h = { id = M.newId(data, "h"), commands = {}, recent = {} }
            data.hosts[#data.hosts + 1] = h
        end
        for __, k in ipairs({ "name", "address", "user", "port", "auth", "key", "password", "os", "detected" }) do h[k] = new[k] end
        for k, v in pairs(extras) do h[k] = v[1] end
        return { id = h.id }
    elseif name == "saveHostStats" then
        local h = M.host(data, args.id)
        if not h then return nil, "No such host." end
        local c, why = cleanStats(args)
        if not c then return nil, why end
        h.stats, h.sensors, h.alerts, h.customAlerts = c.stats, c.sensors, c.alerts, c.customAlerts
        -- (an alert that's gone isn't raised any more)
        if type(h.raised) == "table" then
            local live = {}
            for id in pairs(c.alerts) do live[id] = true end
            for __, a in ipairs(c.customAlerts) do live["ca_" .. a.id] = true end
            for id in pairs(h.raised) do if not live[id] then h.raised[id] = nil end end
        end
        return {}
    elseif name == "saveHostQuick" then
        local h = M.host(data, args.id)
        if not h then return nil, "No such host." end
        local c, why = cleanQuick(h, args)
        if not c then return nil, why end
        h.quick, h.quickIcons = c.quick, c.icons
        return {}
    elseif name == "deleteHost" then
        local __, i = M.host(data, args.id)
        if not i then return nil, "No such host." end
        table.remove(data.hosts, i)
        return {}
    elseif name == "saveCommands" then
        data.commands = cleanCommands(data, args.list)
        return {}
    elseif name == "saveHostCommands" then
        local h = M.host(data, args.id)
        if not h then return nil, "No such host." end
        h.commands = cleanCommands(data, args.list)
        return {}
    elseif name == "addCommand" then
        -- one command, on a host (id) or in the command list (no id)
        local h = args.id and args.id ~= "" and M.host(data, args.id)
        if args.id and args.id ~= "" and not h then return nil, "No such host." end
        local cmd = tostring(args.cmd or "")
        if not cmd:match("%S") then return nil, "The command is empty." end
        local list = h and h.commands or data.commands
        local c = { id = M.newId(data, "c"), name = tostring(args.name or ""):match("^%s*(.-)%s*$"), cmd = cmd }
        list[#list + 1] = c
        return { id = c.id }
    elseif name == "addBuiltIn" then
        return { added = M.addBuiltIn(data) }
    elseif name == "renameKey" then
        local k = M.key(data, args.id)
        if not k then return nil, "No such key." end
        local n = tostring(args.name or ""):match("^%s*(.-)%s*$")
        if n == "" then return nil, "Enter a name." end
        k.name = n
        return {}
    end
    return nil, "Unknown action."
end

-- ------------------------------------------------------------------ PIN

--- A host's PIN as kept (a salted SHA-256, never the digits).
function M.pinHash(host, pin)
    local text = "sshclient-pin:" .. tostring(host.id) .. ":" .. tostring(pin)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.sha256 then return "s2:" .. sha2.sha256(text) end
    local okm, md5 = pcall(require, "ffi/MD5")
    if okm and md5 then return "m5:" .. md5.sum(text) end
    -- (outside KOReader, as in the tests: a plain string hash)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    return string.format("dj:%08x", h)
end

--- A PIN of 4 to 8 digits.
function M.pinOk(pin) return tostring(pin or ""):match("^%d%d%d%d%d?%d?%d?%d?$") ~= nil end

--- Whether a host needs its PIN now: it has one and wasn't opened with it in
-- the last 5 minutes (opened = M.unlocked[id], set by M.unlock).
M.unlocked = {}
M.PIN_KEEP = 5 * 60
function M.needsPin(host, now)
    if not (host and host.pin) then return false end
    local at = M.unlocked[host.id]
    return not (at and (now or os.time()) - at < M.PIN_KEEP)
end
function M.unlock(host, pin, now)
    if host.pin and M.pinHash(host, pin) == host.pin then
        M.unlocked[host.id] = now or os.time()
        return true
    end
    return false
end

return M
