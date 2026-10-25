-- Plain tests for sshmodel and sshkeys (no KOReader): luajit tests/run.lua
package.path = "./?.lua;" .. package.path

local M = require("sshmodel")
local K = require("sshkeys")

local passed, failed = 0, 0
local function eq(got, want, what)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- ------------------------------------------------------------------ base64
eq(K.base64(""), "", "base64 empty")
eq(K.base64("f"), "Zg==", "base64 1")
eq(K.base64("fo"), "Zm8=", "base64 2")
eq(K.base64("foobar"), "Zm9vYmFy", "base64 6")
eq(K.unbase64("Zm9v\nYmE="), "fooba", "unbase64 with a newline")
eq(K.unbase64("Zm9"), nil, "unbase64 bad length")
eq(K.unbase64("Zm=v"), nil, "unbase64 = in the middle")
local all = {}
for i = 0, 255 do all[#all + 1] = string.char(i) end
all = table.concat(all)
eq(K.unbase64(K.base64(all)), all, "base64 round trip of every byte")

-- ------------------------------------------------------------------ keys
local function bytes(n, seed)
    local t = {}
    for i = 1, n do t[i] = string.char((i * 7 + seed) % 256) end
    return table.concat(t)
end

-- An OpenSSH private key file around one key's private fields.
local function openssh(keytype, pubblob, fields, comment, cipher)
    local priv = "\1\2\3\4\1\2\3\4" .. K.str(keytype) .. fields .. K.str(comment or "me@pc")
    local pad = 1
    while #priv % 8 ~= 0 do
        priv = priv .. string.char(pad)
        pad = pad + 1
    end
    local data = "openssh-key-v1\0" .. K.str(cipher or "none") .. K.str(cipher and "bcrypt" or "none") .. K.str("")
        .. "\0\0\0\1" .. K.str(pubblob) .. K.str(priv)
    local b = K.base64(data)
    local lines = {}
    for i = 1, #b, 70 do lines[#lines + 1] = b:sub(i, i + 69) end
    return "-----BEGIN OPENSSH PRIVATE KEY-----\n" .. table.concat(lines, "\n") .. "\n-----END OPENSSH PRIVATE KEY-----\n"
end

local seed, pub = bytes(32, 1), bytes(32, 99)
local edpub = K.str("ssh-ed25519") .. K.str(pub)
local edfile = openssh("ssh-ed25519", edpub, K.str(pub) .. K.str(seed .. pub))
eq(K.kind(edfile), "openssh", "kind openssh")
local k = assert(K.import(edfile))
eq(k.type, "ssh-ed25519", "ed25519 type")
eq(k.dropbear, K.str("ssh-ed25519") .. K.str(seed .. pub), "ed25519 in Dropbear's format")
eq(k.public, edpub, "ed25519 public blob")
eq(k.comment, "me@pc", "ed25519 comment")
eq(K.kind(k.dropbear), "dropbear", "kind dropbear")
local again = assert(K.import(k.dropbear))
eq(again.public, edpub, "a Dropbear file imports as is")
eq(again.dropbear, k.dropbear, "a Dropbear file is kept")
eq(K.publicLine(edpub, "Kindle Scribe"), "ssh-ed25519 " .. K.base64(edpub) .. " Kindle-Scribe", "public line")
eq(K.publicLine(edpub), "ssh-ed25519 " .. K.base64(edpub), "public line, no comment")
eq(K.publicLine(K.ed25519(seed, pub).public, "x"), "ssh-ed25519 " .. K.base64(edpub) .. " x", "a made key's public line")
eq(K.ed25519(seed, pub).dropbear, k.dropbear, "a made key is in Dropbear's format")

local n, e, d, iqmp, p, q = bytes(257, 3), "\1\0\1", bytes(256, 5), bytes(128, 7), bytes(129, 9), bytes(129, 11)
local rsapub = K.str("ssh-rsa") .. K.str(e) .. K.str(n)
local rsa = assert(K.import(openssh("ssh-rsa", rsapub,
    K.str(n) .. K.str(e) .. K.str(d) .. K.str(iqmp) .. K.str(p) .. K.str(q))))
eq(rsa.dropbear, K.str("ssh-rsa") .. K.str(e) .. K.str(n) .. K.str(d) .. K.str(p) .. K.str(q), "rsa in Dropbear's order")
eq(rsa.public, rsapub, "rsa public")
eq(assert(K.readDropbear(rsa.dropbear)).public, rsapub, "rsa Dropbear file read back")

local Q, ed = "\4" .. bytes(64, 13), bytes(32, 17)
local ecpub = K.str("ecdsa-sha2-nistp256") .. K.str("nistp256") .. K.str(Q)
local ec = assert(K.import(openssh("ecdsa-sha2-nistp256", ecpub, K.str("nistp256") .. K.str(Q) .. K.str(ed))))
eq(ec.dropbear, ecpub .. K.str(ed), "ecdsa in Dropbear's format")
eq(K.typeName(ec.type), "ECDSA", "ecdsa type name")

local r1, why = K.import(openssh("ssh-ed25519", edpub, K.str(pub) .. K.str(seed .. pub), nil, "aes256-ctr"))
eq(r1, nil, "a key with a passphrase")
eq(why, "passphrase", "passphrase why")
eq(select(2, K.import("-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----")), "pem", "an old PEM key")
eq(select(2, K.import("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI me")), "public", "a .pub file")
eq(select(2, K.import("hello")), "not a key", "not a key")
eq(select(2, K.import(openssh("ssh-dss", "x", K.str("x")))), "unsupported", "a DSA key")

-- ------------------------------------------------------------------ data
local data = M.normalize(nil)
eq(#data.commands, #M.DEFAULT_COMMANDS, "a new install gets the command list")
eq(data.commands[1].name, "Uptime", "the first command")
eq(type(data.commands[1].id), "string", "commands get ids")
local d2 = M.normalize({ builtInVersion = M.BUILTIN_VERSION, commands = { { id = "c1", name = "a", cmd = "x" }, { id = "c1", cmd = "y" }, { cmd = "  " } },
    hosts = { { id = "h1", address = "pi", user = "pi", auth = "bogus", recent = { "a", 3 } }, "junk" } })
eq(#d2.commands, 2, "a blank command is dropped")
eq(d2.commands[1].id ~= d2.commands[2].id, true, "a repeated id gets a new one")
eq(#d2.hosts, 1, "junk hosts dropped")
eq(d2.hosts[1].auth, "key", "an unknown sign-in becomes key")
eq(d2.hosts[1].port, 22, "port 22 by default")
eq(#d2.hosts[1].recent, 1, "recent keeps strings")

eq(M.checkHost({ address = "", user = "pi", port = 22 }), "Enter the address.", "check address")
eq(M.checkHost({ address = "-oProxyCommand=x", user = "pi", port = 22 }), "The address can't start with -.", "check option address")
eq(M.checkHost({ address = "a b", user = "pi", port = 22 }), "The address can't have spaces.", "check spaces")
eq(M.checkHost({ address = "nas", user = "", port = 22 }), "Enter the user name.", "check user")
eq(M.checkHost({ address = "nas", user = "-l", port = 22 }), "Check the user name.", "check option user")
eq(M.checkHost({ address = "nas", user = "me", port = 70000 }), "The port is a number from 1 to 65535.", "check port")
eq(M.checkHost({ address = "nas", user = "me", port = "2222" }), nil, "a good host")
eq(M.hostLabel({ address = "nas", user = "me", port = 2222 }), "me@nas:2222", "label with port")
eq(M.hostLabel({ address = "nas", user = "me", port = 22 }), "me@nas", "label port 22")
eq(M.hostName({ name = " ", address = "nas" }), "nas", "name falls back to address")

local h = { recent = {} }
for i = 1, 12 do M.addRecent(h, "cmd" .. i) end
M.addRecent(h, "cmd5")
eq(#h.recent, 10, "recent keeps 10")
eq(h.recent[1], "cmd5", "recent newest first")
eq(h.recent[2], "cmd12", "recent then the others")
local seen5 = 0
for __, r in ipairs(h.recent) do if r == "cmd5" then seen5 = seen5 + 1 end end
eq(seen5, 1, "recent once each")

local list = { "a", "b", "c" }
eq(M.move(list, 1, -1), 1, "move up at the top")
eq(M.move(list, 1, 1), 2, "move down")
eq(table.concat(list), "bac", "moved")

-- web page / Kindle changes
local w = M.normalize({})
w.keys = { { id = "k1", name = "Kindle key", type = "ssh-ed25519", public = "ssh-ed25519 AAAA" } }
local r, err = M.act(w, "saveHost", { name = "Pi", address = "192.168.1.20", user = "pi", auth = "key" })
eq(r, nil, "a key host needs a key")
eq(err, "Choose a key.", "key why")
r = assert(M.act(w, "saveHost", { name = "Pi", address = " 192.168.1.20 ", user = "pi", port = "22", auth = "key", key = "k1" }))
local pi = M.host(w, r.id)
eq(pi.address, "192.168.1.20", "address trimmed")
eq(pi.port, 22, "port a number")
r = assert(M.act(w, "saveHost", { name = "NAS", address = "nas", user = "admin", auth = "password", password = "s3cret" }))
local nasid = r.id
eq(M.host(w, nasid).password, "s3cret", "password saved")
assert(M.act(w, "saveHost", { id = nasid, name = "NAS box" }))
eq(M.host(w, nasid).password, "s3cret", "password kept when left out")
eq(M.host(w, nasid).name, "NAS box", "renamed")
local st = M.webState(w)
eq(st.hosts[2].password, nil, "web state has no passwords")
eq(st.hosts[2].hasPassword, true, "web state says one is saved")
eq(w.hosts[2].password, "s3cret", "web state doesn't change the data")
local saved, pws = M.splitPasswords(w)
eq(saved.hosts[2].password, nil, "saved data has no passwords")
eq(pws[nasid], "s3cret", "passwords by host id")
eq(w.hosts[2].password, "s3cret", "split doesn't change the data")
eq(saved.commands, w.commands, "split keeps the rest")
local back = M.mergePasswords(M.normalize(saved), pws)
eq(M.host(back, nasid).password, "s3cret", "passwords merged back")
eq(M.host(M.mergePasswords(M.normalize(select(1, M.splitPasswords(w))), nil), nasid).password, nil, "no passwords file: none")
assert(M.act(w, "saveHost", { id = nasid, password = "" }))
eq(M.host(w, nasid).password, nil, "an empty password removes it")
eq(select(2, M.act(w, "saveHost", { id = "nope" })), "No such host.", "save unknown host")
eq(select(2, M.act(w, "saveHost", { id = nasid, port = "x" })), "The port is a number from 1 to 65535.", "save checks the host")
eq(M.host(w, nasid).port, 22, "a refused save changes nothing")
assert(M.act(w, "saveHostCommands", { id = pi.id, list = { { name = "Temp", cmd = "vcgencmd measure_temp" }, { cmd = "" } } }))
eq(#pi.commands, 1, "host commands saved, blank dropped")
local ids, labels = M.gestureChoices(w)
eq(ids[1], pi.id .. "/" .. pi.commands[1].id, "gesture id")
eq(labels[1], "Pi: Temp", "gesture label")
local gh, gc = M.hostCommand(w, ids[1])
eq(gh, pi, "gesture finds the host")
eq(gc.cmd, "vcgencmd measure_temp", "gesture finds the command")
eq(M.hostCommand(w, "x/y"), nil, "gesture of a deleted command")
assert(M.act(w, "saveCommands", { list = { { name = "Up", cmd = "uptime" } } }))
eq(#w.commands, 1, "command list replaced")
eq(M.act(w, "addBuiltIn", {}).added, #M.DEFAULT_COMMANDS - 1, "built-in commands added back (Uptime was there)")
eq(M.addBuiltIn(w), 0, "added once")
assert(M.act(w, "saveCommands", { list = { { name = "Up", cmd = "uptime" } } }))
eq(table.concat(M.hostsUsingKey(w, "k1"), ","), "Pi", "hosts using a key")
assert(M.act(w, "renameKey", { id = "k1", name = " PC key " }))
eq(w.keys[1].name, "PC key", "key renamed")
assert(M.act(w, "deleteHost", { id = nasid }))
eq(#w.hosts, 1, "host deleted")
eq(M.appsLine(w), "1 host", "apps line one")
eq(M.appsLine(M.normalize({})), "No hosts", "apps line none")
eq(select(2, M.act(w, "bogus", {})), "Unknown action.", "unknown action")

-- ------------------------------------------------------------------ systems
eq(M.detectOS('PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\nNAME="Debian GNU/Linux"\nID=debian\n'), "debian", "detect Debian")
eq(M.detectOS('NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\n'), "debian", "detect Ubuntu")
eq(M.detectOS('ID=debian\nVERSION_CODENAME=bookworm\nRaspberry Pi 4 Model B Rev 1.4\0'), "raspberrypi", "detect a Raspberry Pi by its model")
eq(M.detectOS('NAME="Arch Linux"\nID=arch\n'), "arch", "detect Arch")
eq(M.detectOS('NAME="EndeavourOS"\nID="endeavouros"\nID_LIKE="arch"\n'), "arch", "detect EndeavourOS")
eq(M.detectOS('NAME="Rocky Linux"\nID="rocky"\nID_LIKE="rhel centos fedora"\n'), "fedora", "detect Rocky")
eq(M.detectOS('NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\n'), "opensuse", "detect openSUSE")
eq(M.detectOS('ID=alpine\n'), "alpine", "detect Alpine")
eq(M.detectOS('ID=nixos\n'), "linux", "an unknown Linux")
eq(M.detectOS('ID=somethinglike\nID_LIKE="ubuntu debian"\n'), "debian", "detect by ID_LIKE")
eq(M.detectOS("Darwin\n"), "macos", "detect macOS")
eq(M.detectOS("\r\nMicrosoft Windows [Version 10.0.26100.1]\r\n"), "windows", "detect Windows")
eq(M.detectOS(""), nil, "nothing detected")
eq(M.hostOS({ os = "auto", detected = "arch" }), "arch", "host os detected")
eq(M.hostOS({ os = "windows", detected = "arch" }), "windows", "host os set by hand wins")
eq(M.hostOS({ os = "auto" }), nil, "host os not known yet")
eq(M.fits({ os = "linux" }, "arch"), true, "any Linux fits Arch")
eq(M.fits({ os = "linux" }, "windows"), false, "any Linux doesn't fit Windows")
eq(M.fits({ os = "debian" }, "raspberrypi"), true, "Debian commands fit a Raspberry Pi")
eq(M.fits({ os = "arch" }, "debian"), false, "Arch doesn't fit Debian")
eq(M.fits({}, "windows"), true, "any system fits")
eq(M.fits({ os = "arch" }, nil), true, "an unknown system shows everything")
local fl = { { cmd = "uptime" }, { cmd = "pacman -Qe", os = "arch" }, { cmd = "my-backup.sh", os = "arch" }, { cmd = "systeminfo", os = "windows" } }
eq(#M.filter(fl, "all"), 4, "filter all")
eq(#M.filter(fl, "arch"), 3, "filter Arch")
eq(#M.filter(fl, "custom"), 1, "filter custom: not built in")
eq(M.filter(fl, "custom")[1].cmd, "my-backup.sh", "the custom one")
eq(M.filterName("custom"), "Custom", "filter name")
eq(M.osName("linux"), "Any Linux", "os name")
local hasApt, hasYay = false, false
for __, c in ipairs(M.DEFAULT_COMMANDS) do
    if c.cmd == "sudo apt update" then hasApt = true end
    if c.cmd:find("^yay ") then hasYay = true end
end
eq(hasApt and hasYay, true, "apt update and yay are built in")
-- an older list (version 1): systems added to its built-ins, new built-ins added once, kept edits
local old = M.normalize({ commands = { { id = "c1", name = "Arch: updates", cmd = "checkupdates" }, { id = "c2", name = "Mine", cmd = "my.sh" } },
    hosts = { { id = "h1", address = "pi", user = "pi" } } })
eq(old.commands[1].os, "arch", "an old built-in gets its system")
eq(old.commands[2].os, nil, "a custom one keeps no system")
local n = 0
for __, c in ipairs(old.commands) do if c.cmd == "sudo apt update" then n = n + 1 end end
eq(n, 1, "a new built-in added")
eq(old.builtInVersion, M.BUILTIN_VERSION, "list version raised")
eq(#M.normalize(old).commands, #old.commands, "added only once")
eq(old.hosts[1].os, "auto", "a host detects its system by default")
local sh = M.normalize({})
sh.keys = { { id = "k1", name = "k", type = "ssh-ed25519", public = "x" } }
local r2 = assert(M.act(sh, "saveHost", { address = "a", user = "u", auth = "key", key = "k1" }))
local hh = M.host(sh, r2.id)
eq(hh.os, "auto", "new host auto")
hh.detected = "arch"
assert(M.act(sh, "saveHost", { id = hh.id, name = "x" }))
eq(hh.detected, "arch", "detected kept on other changes")
assert(M.act(sh, "saveHost", { id = hh.id, os = "windows" }))
eq(M.hostOS(hh), "windows", "system set by hand")
assert(M.act(sh, "saveHost", { id = hh.id, os = "auto" }))
eq(hh.detected, nil, "back to auto: detected again")
assert(M.act(sh, "saveCommands", { list = { { name = "a", cmd = "x", os = "arch" }, { name = "b", cmd = "y", os = "bogus" } } }))
eq(sh.commands[1].os, "arch", "a command's system saved")
eq(sh.commands[2].os, nil, "an unknown system dropped")

-- ------------------------------------------------------------------ dbclient
local host = { address = "nas", user = "o'brien", port = 2222 }
eq(M.shellLine(M.dbclientArgs("./dbclient", host, { cmd = "df -h", keyFile = "/k/k1" })),
    "'./dbclient' '-T' '-o' 'BatchMode=yes' '-i' '/k/k1' '-K' '30' '-p' '2222' '-l' 'o'\\''brien' 'nas' 'df -h'",
    "run line")
eq(table.concat(M.dbclientArgs("db", host, { probe = true, trust = true, keyFile = "k" }), " "),
    "db -T -y -o BatchMode=yes -o PasswordAuthentication=no -K 30 -p 2222 -l o'brien nas true", "trust probe")
eq(table.concat(M.dbclientArgs("db", host, { pty = true }), " "), "db -t -K 30 -p 2222 -l o'brien nas", "session")

eq(M.stripAnsi("\27[1;32mok\27[0m done"), "ok done", "strip colours")
eq(M.stripAnsi("a\r\nb"), "a\nb", "strip CRLF")
eq(M.stripAnsi("10%\r50%\r100%\nend"), "100%\nend", "a redrawn line keeps the last")
eq(M.stripAnsi("ab\8c"), "ac", "backspace")
eq(M.stripAnsi("\27]0;title\7x"), "x", "window title")

local p = M.parseRun("hello\nworld\n")
eq(p.problem, nil, "a plain run")
eq(p.output, "hello\nworld", "plain output")
p = M.parseRun("\nHost '192.168.1.20' is not in the trusted hosts file.\n(ssh-ed25519 fingerprint SHA256:CMC5VJH2sUxQg9FlYYbTdKfVOxg3zelJmx127uqckpQ)\n\n/mnt/us/koreader/dbclient: Connection to pi@192.168.1.20:22 exited: Didn't validate host key\n")
eq(p.problem, "unknown_host", "unknown host")
eq(p.keytype, "ssh-ed25519", "unknown host key type")
eq(p.fingerprint, "SHA256:CMC5VJH2sUxQg9FlYYbTdKfVOxg3zelJmx127uqckpQ", "unknown host fingerprint")
p = M.parseRun("\nHost '127.0.0.1' key accepted unconditionally.\n(ssh-ed25519 fingerprint SHA256:abc)\n\n./dbclient: Connection to pi@127.0.0.1:2299 exited: No auth methods could be used.\n")
eq(p.accepted, true, "trusted")
eq(p.fingerprint, "SHA256:abc", "trusted fingerprint")
p = M.parseRun("\n./dbclient: Connection to pi@127.0.0.1:2299 exited: \n\nssh-ed25519 host key mismatch for 127.0.0.1 !\nFingerprint is SHA256:new\nExpected SHA256:old\nIf you know that the host key is correct you can\nremove the bad entry from ~/.ssh/known_hosts\n")
eq(p.problem, "changed_host", "changed host")
eq(p.fingerprint, "SHA256:new", "changed host new")
eq(p.expected, "SHA256:old", "changed host old")
eq(p.output, "", "changed host no output")
p = M.parseRun("\n/x/dbclient: Connection to pi@127.0.0.1:2299 exited: No auth methods could be used.\n")
eq(p.problem, "signin", "sign-in failed")
p = M.parseRun("\n./dbclient: Connection to pi@127.0.0.1:2298 exited: Connect failed: Connection refused\n")
eq(p.problem, "connect", "can't connect")
eq(p.message, "Connection refused", "can't connect why")
p = M.parseRun("Login for pi@nas\nLogin for pi@nas\n\n./dbclient: Connection to pi@nas:22 exited: No auth methods could be used.\n")
eq(p.output, "", "password tries aren't output")
eq(p.problem, "signin", "wrong password")
p = M.parseRun("Login for pi@nas\nLogin for pi@nas\n\n./dbclient: Connection to pi@nas:22 exited: Remote closed the connection\n")
eq(p.problem, "signin", "wrong passwords, then the device hung up")
p = M.parseRun("ls: cannot access 'x': No such file or directory\n")
eq(p.problem, nil, "the command's own error is output")
eq(p.output, "ls: cannot access 'x': No such file or directory", "its text kept")
p = M.parseRun("going down\n\n./dbclient: Connection to pi@nas:22 exited: Remote closed the connection\n")
eq(p.problem, nil, "the device closing (a reboot) isn't a problem")
eq(p.output, "going down", "output before it closed")

-- known_hosts
local kh = "192.168.1.20 ssh-ed25519 AAAA1\nnas,10.0.0.2 ssh-rsa AAAA2\n[pi.lan]:2222 ssh-ed25519 AAAA3\n# 1.2.3.4 x y\n"
eq(M.knownHas(kh, "192.168.1.20"), true, "known plain")
eq(M.knownHas(kh, "10.0.0.2"), true, "known in a list")
eq(M.knownHas(kh, "pi.lan"), true, "known with a port")
eq(M.knownHas(kh, "1.2.3.4"), false, "a comment isn't known")
eq(M.knownHas(kh, "192.168.1.2"), false, "not a prefix")
local left, gone = M.knownRemove(kh, "nas")
eq(gone, 1, "removed one")
eq(M.knownHas(left, "nas"), false, "removed")
eq(M.knownHas(left, "192.168.1.20"), true, "others kept")

local t, cut = M.tail("line1\nline2\nline3\n", 9)
eq(t, "line3\n", "tail from a line start")
eq(cut, true, "tail cut")
eq(select(2, M.tail("short", 9)), false, "tail not cut")

-- AI: secrets blanked before sending
local function red(s, sec) return (M.redact(s, sec)) end
eq(red("a\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA\n-----END OPENSSH PRIVATE KEY-----\nz"), "a\n[hidden private key]\nz", "private key block")
eq(red("x -----BEGIN RSA PRIVATE KEY-----\nMIIE"), "x [hidden private key]", "cut-off key block")
eq(red("DB_PASSWORD=hunter22 next"), "DB_PASSWORD=[hidden] next", "name=value")
eq(red('{"api_key": "abc123", "n": 1}'), '{"api_key": "[hidden]", "n": 1}', "json value")
eq(red("Token: xyz"), "Token: [hidden]", "any case")
eq(red("Accepted password for pi from 10.0.0.2"), "Accepted password for pi from 10.0.0.2", "a log line stays")
eq(red("curl https://bob:s3cr3t@example.com/x"), "curl https://bob:[hidden]@example.com/x", "URL password")
eq(red("Authorization: Bearer abc.def-123"), "Authorization: Bearer [hidden]", "bearer")
eq(red("key ghp_abcdef123456 and sk-ABCDEFGHIJKLMNOP"), "key [hidden] and [hidden]", "token formats")
eq(red("desk-organizer-thingy-long"), "desk-organizer-thingy-long", "no token in a word")
eq(red("login with mypass99 ok", { "mypass99" }), "login with [hidden] ok", "saved password")
eq(select(2, M.redact("nothing here")), 0, "nothing blanked")
-- what goes with a request
local many = {}
for i = 1, 250 do many[i] = "line " .. i end
local part, pcut = M.aiPart(table.concat(many, "\n"), "lines")
eq(pcut, true, "long output cut")
eq(part:match("^[^\n]+"), "line 51", "the last 200 lines")
eq(select(2, M.aiPart("short\n", "lines")), false, "short not cut")
eq(M.aiOutputText("cat .env", "\27[31mTOKEN=abc\27[0m\n", "lines"), "Command: cat .env\n\nOutput:\nTOKEN=[hidden]\n", "output text blanked, no colour")
local fu = M.aiFollowUp("FIRST", { { answer = "A1", question = "no" }, { answer = "A2", question = "it says password=x" } })
eq(fu, "FIRST\n\nYour answer:\nA1\n\nMy follow-up:\nno\n\nYour answer:\nA2\n\nMy follow-up:\nit says password=[hidden]", "follow-up")
-- commands in an answer
local cmds, shown = M.aiCommands("The disk is full.\nCOMMAND: df -h\n**Command:** `du -sh /var/log/*`\nDone.")
eq(#cmds, 2, "two commands")
eq(cmds[2], "du -sh /var/log/*", "backticks off")
eq(shown, "The disk is full.\n$ df -h\n$ du -sh /var/log/*\nDone.", "shown with $")
local c2 = M.aiCommands("Try this:\n```bash\nsudo systemctl restart nginx\n```")
eq(c2[1], "sudo systemctl restart nginx", "from a code block")
eq(#M.aiCommands("No command needed."), 0, "none")
local st1 = M.aiSessionText("pi$ cat .env\nTOKEN=abc\npi$ ", { { question = "what is it", answer = "A1" } }, "and now?", "short")
eq(st1, "The terminal now:\npi$ cat .env\nTOKEN=[hidden]\npi$ \n\nMy question:\nwhat is it\n\nYour answer:\nA1\n\nMy question:\nand now?", "session text")
local many2 = {}
for i = 1, 30 do many2[i] = "row" .. i end
local st2 = M.aiSessionText(table.concat(many2, "\n"), {}, "what is it?", "all", nil, "row29 password=x")
eq(st2:match("^[^\n]+\n[^\n]+"), "The part of the terminal I'm asking about:\nrow29 password=[hidden]", "selection first, blanked")
eq(st2:find("row10\n", 1, true), nil, "only the last 20 lines around it")
eq(st2:find("row11\n", 1, true) ~= nil, true, "the last 20 lines")
local sixty = {}
for i = 1, 60 do sixty[i] = "l" .. i end
eq(M.aiPart(table.concat(sixty, "\n"), "short"):match("^[^\n]+"), "l11", "short: the last 50 lines")
eq(M.lastLines("a\nb\nc\nd  \n\n", 2), "c\nd", "last lines")
eq(M.lastLines("", 3), "", "last lines of nothing")
local tu, ta, tp = M.parseTarget(" pi@192.168.1.20 ")
eq(tu .. "|" .. ta .. "|" .. tp, "pi|192.168.1.20|22", "target")
tu, ta, tp = M.parseTarget("admin@nas.local:2222")
eq(ta .. "|" .. tp, "nas.local|2222", "target with port")
tu, ta, tp = M.parseTarget("me@[fe80::1]:22")
eq(ta, "fe80::1", "target IPv6")
eq(select(2, M.parseTarget("192.168.1.20")), "Type it as user@address, for example pi@192.168.1.20.", "target needs a user")
eq(M.usesSudo("sudo apt update"), true, "sudo")
eq(M.usesSudo("ls && sudo -n true"), true, "sudo later")
eq(M.usesSudo("pseudocode"), false, "no sudo in a word")
eq(M.sudoNeedsPassword("sudo: a terminal is required to read the password; either use the -S option"), true, "sudo terminal")
eq(M.sudoNeedsPassword("sudo: a password is required"), true, "sudo -n")
eq(M.sudoNeedsPassword("done"), false, "no sudo problem")
local ad = M.normalize({})
local n0 = #ad.commands
assert(M.act(ad, "addCommand", { name = " Big ", cmd = "du -sh *" }))
eq(#ad.commands, n0 + 1, "added to the command list")
eq(ad.commands[#ad.commands].name, "Big", "name trimmed")
eq(select(2, M.act(ad, "addCommand", { id = "nope", cmd = "x" })), "No such host.", "add on unknown host")
eq(select(2, M.act(ad, "addCommand", { cmd = " " })), "The command is empty.", "add empty")

-- history
local hd = M.normalize({})
assert(M.act(hd, "saveHost", { name = "NAS", address = "nas", user = "a", auth = "ask" }))
local nid = hd.hosts[1].id
M.addHistory(hd, nid, "df -h", 100)
M.addHistory(hd, nid, "uptime", 200)
M.addHistory(hd, nid, " ", 300)
eq(#hd.history, 2, "history kept, blanks not")
eq(hd.history[1].cmd, "uptime", "newest first")
eq(#M.searchHistory(hd, "DF"), 1, "history search, any case")
eq(#M.searchHistory(hd, "nas"), 2, "history search by host name")
for i = 1, M.HISTORY_MAX + 5 do M.addHistory(hd, nid, "c" .. i) end
eq(#hd.history, M.HISTORY_MAX, "history capped")

-- ------------------------------------------------------------------ stats (sshstats)
local Stt = require("sshstats")
local raw = Stt.parse([[os=Linux
uptime=277200
load=0.12 0.30 0.25
cpu1=cpu  100 0 100 800 0 0 0 0
cpu2=cpu  110 0 110 820 0 0 0 0
mem=4000000 2800000
swap=0 0
disk=30000000 18000000 /
temp=52123
iface=eth0
ip=192.168.1.20
mac=DC:A6:32:01:02:03
sys=Debian GNU/Linux 12 (bookworm)
kernel=6.1.0
users=1
procs=180
svc_running=42
failed=nginx.service
svc=pihole-FTL|active
docker_ok=1
ct=jellyfin|running|Up 12 days|jellyfin/jellyfin
ct=nextcloud|exited|Exited (1) 2 hours ago|nextcloud]])
local v = Stt.values(raw)
eq(v.uptime, 277200, "uptime seconds")
eq(Stt.duration(v.uptime), "3 days 5 h", "uptime shown")
eq(v.cpu, 50, "cpu from two /proc/stat lines")
eq(v.mem.used, 1200000, "memory used")
eq(Stt.size(v.mem.total), "3.8 GB", "memory size")
eq(math.floor(v.temp), 52, "temperature from millidegrees")
eq(v.mac, "dc:a6:32:01:02:03", "mac lower case")
eq(v.failed[1], "nginx", "failed service without .service")
eq(v.pinned[1].state, "active", "a pinned service's state")
eq(#v.docker.list, 2, "docker containers")
eq(Stt.tile("docker", v).value, "1 of 2 running", "docker tile")
eq(Stt.tile("disk", v).label, "Disk /", "disk tile names the mount")
eq(Stt.tile("temp", { }).value, "Not available", "a stat not read")
eq(Stt.short(v, { "uptime", "temp", "cpu" }), "up 3 days · 52 °C", "main page line: two stats")
eq(v.swap, nil, "no swap: none shown")
local al = Stt.check(v, { disk = 50, temp = 70, failed = true, stopped = true })
eq(#al, 3, "alerts raised: disk, failed, stopped")
eq(al[1].text, "Disk full: 60 % (over 50 %)", "disk alert text")
eq(al[2].text, "A service failed: nginx", "failed alert names it")
eq(#Stt.check(v, {}), 0, "no limits, no alerts")
local dn = Stt.values(Stt.parse("docker_ok=denied"))
eq(Stt.tile("docker", dn).value, "Needs sudo", "docker needs sudo")
-- shown stats and quick commands
eq(table.concat(Stt.shown({ os = "debian" }), ","), "uptime,temp,cpu,mem,disk,ip,docker", "default stats")
eq(table.concat(Stt.shown({ os = "windows" }), ","), "uptime,cpu,mem,disk,ip,docker", "no temperature on Windows")
eq(table.concat(Stt.shown({ os = "debian", stats = { temp = false, docker = true } }), ","), "uptime,cpu,mem,disk,ip,docker", "own choice")
local q = Stt.quickShown({ os = "raspberrypi" }, false)
eq(q[1].cmd, "sudo apt update", "Raspberry Pi gets Debian's")
eq(q[#q].id, "shutdown", "then any Linux's")
local qd = Stt.quickShown({ os = "debian" }, true)
eq(qd[#qd].id, "d_prune", "Docker's when it's there")
local qo = Stt.quickShown({ os = "arch", quick = { "upgrade", "cmd:uptime|Up" } }, false)
eq(#qo, 2, "own quick list")
eq(qo[2].name, "Up", "a custom quick command")
-- the stats command
eq(Stt.command("debian", { "nginx" }):find("systemctl is-active 'nginx'", 1, true) ~= nil, true, "pinned services read")
eq(Stt.command("debian", { "bad;rm" }):find("bad;rm", 1, true), nil, "odd names left out")
eq(Stt.command("windows"):match("^powershell %-NoProfile %-NonInteractive %-EncodedCommand ") ~= nil, true, "Windows: encoded PowerShell")
-- services, blanks, ssh config, wol, files
local svcs = Stt.parseServices("  nginx.service loaded failed failed A web server\n● cron.service loaded active running Regular jobs\n")
eq(#svcs, 2, "services listed")
eq(svcs[2].name .. "|" .. svcs[2].sub, "cron|running", "a service's state")
eq(table.concat(Stt.blanks("sudo systemctl restart {service} && echo {service} {x}"), ","), "service,x", "blanks, each once")
eq(Stt.fill("restart {service}", { service = "nginx" }), "restart nginx", "blanks filled")
local cfg = Stt.parseSshConfig([[
Host *
  User me
Host nas nas.lan
  HostName 192.168.1.5
  Port 2222
Host pi
  HostName raspberrypi.local
  User pi
  IdentityFile ~/.ssh/id_ed25519
Host *.example.com
  User x
]])
eq(#cfg, 2, "two hosts, patterns skipped")
eq(cfg[1].name .. "|" .. cfg[1].address .. "|" .. cfg[1].user .. "|" .. cfg[1].port, "nas|192.168.1.5|me|2222", "host with defaults")
eq(cfg[2].user, "pi", "own user")
local pkt = Stt.magicPacket("DC:A6:32:01:02:03")
eq(#pkt, 102, "magic packet size")
eq(pkt:sub(7, 12), "\220\166\50\1\2\3", "magic packet's address")
eq(Stt.magicPacket("nope"), nil, "not a MAC")
local ls = Stt.parseList("PWD=/srv/files\nf\t120\tnotes.txt\nd\t0\tbooks\nf\t9\t.bashrc\n")
eq(ls.pwd, "/srv/files", "listing's folder")
eq(ls.items[1].name, "books", "folders first")
eq(ls.items[2].name, ".bashrc", "then files by name")
eq(select(2, Stt.parseList("ERR=cd")), "cd", "can't open the folder")
eq(Stt.parent("/srv/files/books"), "/srv/files", "parent")
eq(Stt.parent("/home"), "/", "parent of a top folder")
eq(Stt.isBook("x.EPUB"), true, "a book")
-- custom sensors
local sensors = {
    { id = "s1", name = "Pool", cmd = "echo 34.50", kind = "number", unit = "°C" },
    { id = "s2", name = "Backup", cmd = "test -f /x", kind = "ok" },
    { id = "s3", name = "Used", cmd = "echo 62", kind = "percent" },
}
local lines = Stt.sensorLines(sensors)
eq(lines:find('echo "cs_s1=$( { echo 34.50 ; } 2>/dev/null | head -n 1)"', 1, true) ~= nil, true, "a sensor's line")
eq(lines:find("if { test -f /x ; } >/dev/null 2>&1; then echo cs_s2=1; else echo cs_s2=0; fi", 1, true) ~= nil, true, "an OK sensor's line")
eq(Stt.command("debian", {}, sensors):find("cs_s3", 1, true) ~= nil, true, "sensors in the stats command")
eq(Stt.command("windows", {}, sensors):find("cs_", 1, true), nil, "none on Windows")
local cv = Stt.values(Stt.parse("cs_s1=34.50\ncs_s2=0\ncs_s3=62\n"))
eq(Stt.sensorTile(sensors[1], cv).value, "34.5 °C", "number sensor")
eq(Stt.sensorTile(sensors[2], cv).value, "Failing", "OK sensor failing")
eq(Stt.sensorTile(sensors[3], cv).bar, 0.62, "percent sensor's bar")
eq(Stt.tileOf("cs_s3", cv, sensors).value, "62 %", "a sensor's tile by its id")
eq(Stt.sensorTile({ id = "s9", name = "X", cmd = "x", kind = "text" }, cv).value, "Not available", "a sensor not read")
eq(table.concat(Stt.shown({ os = "debian", sensors = sensors, stats = { cs_s2 = false } }), ","), "uptime,temp,cpu,mem,disk,ip,docker,cs_s1,cs_s3", "sensors shown")
local ca = Stt.check(cv, { cs_s1 = 30, cs_s2 = true }, sensors)
eq(#ca, 2, "sensor alerts")
eq(ca[1].text, "Pool: 34.50 (over 30)", "number sensor alert")
eq(ca[2].text, "Backup: failing", "OK sensor alert")
-- custom alerts
local cav = Stt.values(Stt.parse("load=4.50 1 1\nip=192.168.1.50\ncs_s2=0\nusers=0\n"))
local custom = {
    { id = 1, what = "load", op = "gt", value = "4" },
    { id = 2, what = "ip", op = "ne", value = "192.168.1.20" },
    { id = 3, what = "cs_s2", op = "eq", value = "Failing" },
    { id = 4, what = "users", op = "gt", value = "0" },
    { id = 5, what = "temp", op = "gt", value = "70" },
}
local cr = Stt.checkCustom(cav, custom, sensors)
eq(#cr, 3, "custom alerts raised: load, ip, backup")
eq(cr[1].text, "Load (1 minute) above 4", "custom alert text")
eq(cr[2].id, "ca_2", "custom alert id")
eq(cr[3].text, "Backup is Failing", "custom alert on an OK sensor")
eq(Stt.customRaised(custom[5], cav, sensors), nil, "not readable: nothing")
eq(Stt.customRaised({ what = "ip", op = "has", value = "168.1" }, cav), true, "contains")
eq(Stt.alertText({ what = "cs_s1", op = "lt", value = "20" }, sensors), "Pool below 20 °C", "a sensor's unit in the text")
-- the custom lines really run in sh
local f = io.popen("sh -c " .. M.quote(Stt.sensorLines(sensors)) .. " 2>&1")
local got = f:read("*a")
f:close()
eq(got, "cs_s1=34.50\ncs_s2=0\ncs_s3=62\n", "sensor lines run")
-- FreeBSD and pfSense
eq(M.detectOS("FreeBSD\n"), "freebsd", "detect FreeBSD by uname")
eq(M.detectOS('NAME=FreeBSD\nID=freebsd\n'), "freebsd", "detect FreeBSD by os-release")
eq(M.detectOS('NAME=FreeBSD\nID=freebsd\npfSense\nFreeBSD\n'), "pfsense", "detect pfSense by /etc/platform")
eq(M.detectOS("FreeBSD\npfSense 2.7.2-RELEASE"), "pfsense", "detect pfSense in the status")
eq(M.fits({ os = "linux" }, "pfsense"), false, "Linux commands don't fit pfSense")
eq(M.fits({ os = "linux" }, "freebsd"), false, "or FreeBSD")
eq(M.fits({ os = "freebsd" }, "pfsense"), false, "FreeBSD's pkg commands don't fit pfSense")
eq(Stt.family("pfsense"), "bsd", "pfSense's family")
eq(Stt.fits(Stt.byId.load, "freebsd"), true, "load on FreeBSD")
eq(Stt.fits(Stt.byId.failed, "pfsense"), false, "no systemd on pfSense")
local pq = Stt.quickFor("pfsense")
eq(pq[1].id .. "," .. pq[#pq - 2].id .. "," .. pq[#pq].id, "pending,top,shutdown", "pfSense's quick commands, the BSD ones, then Reboot and Shut down")
eq(pq[2].session, true, "pfSense's upgrade runs in a live session")
local bc = Stt.command("freebsd", nil, sensors)
eq(bc:sub(1, 6), "sh -c ", "sent to sh")
-- (its script is sh: check it parses)
local f2 = io.popen(bc:gsub("^sh %-c ", "sh -n -c ") .. " 2>&1; echo rc=$?")
eq(f2:read("*a"), "rc=0\n", "the BSD script parses in sh")
f2:close()
local bv = Stt.values(Stt.parse("os=FreeBSD\ncpu1=cpu 100 0 50 850 0 0\ncpu2=cpu 110 0 60 930 0 0\nmem=4096000 3072000\nswap=2097152 2097152\ntemp=48.0\nsys=pfSense 2.7.2-RELEASE\n"))
eq(bv.cpu, 20, "CPU from kern.cp_time")
eq(bv.mem.used, 1024000, "memory used")
eq(bv.temp, 48, "temperature")
eq(bv.swap.used, 0, "swap")
-- (not known yet: the Linux script runs, and its first line spots pfSense)
local lf = io.popen("sh -n -c " .. M.quote(Stt.command(nil)) .. " 2>&1; echo rc=$?")
eq(lf:read("*a"), "rc=0\n", "the Linux script parses in sh")
lf:close()
eq(M.detectOS("FreeBSD pfSense\n"), "pfsense", "pfSense from the Linux script's os line")
-- TrueNAS, Proxmox, ReadyNAS
eq(M.detectOS('TrueNAS\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\nID=debian\n'), "truenas", "detect TrueNAS before its Debian")
eq(M.detectOS("FreeBSD  TrueNAS\nFreeBSD 13.1"), "truenascore", "detect TrueNAS CORE")
eq(M.detectOS('Proxmox\nID=debian\n'), "proxmox", "detect Proxmox")
eq(M.detectOS("Linux   ReadyNAS\nDebian GNU/Linux 8 (jessie)"), "readynas", "detect ReadyNAS")
eq(M.REFINED.proxmox and not M.REFINED.debian, true, "a mark takes over Debian, not the other way")
eq(Stt.family("truenascore"), "bsd", "TrueNAS CORE is FreeBSD")
eq(M.fits({ os = "linux" }, "truenas"), true, "Linux commands fit TrueNAS")
eq(M.fits({ os = "debian" }, "proxmox"), false, "Debian's apt ones don't fit Proxmox (its own)")
local px = Stt.quickFor("proxmox")
local pxc = {}
for __, q in ipairs(px) do pxc[q.id] = q.cmd end
eq(pxc.reboot, "reboot", "Proxmox: Linux's without sudo")
eq(pxc.vms, "qm list", "Proxmox's own")
local tn = Stt.quickFor("truenas")
eq(tn[1].id .. "," .. tn[#tn].cmd, "pools,sudo shutdown -h now", "TrueNAS: its own, then Linux's with sudo")
eq(Stt.quickFor("truenascore")[#Stt.quickFor("truenascore")].id, "shutdown", "TrueNAS CORE: power last")
local rq = Stt.quickFor("readynas")
eq(rq[1].id .. "," .. rq[4].cmd, "raid,df -h -x tmpfs -x devtmpfs", "ReadyNAS: its own, then Linux's")
-- (the detection command still parses in sh)
local df = io.popen("sh -n -c " .. M.quote(M.DETECT_CMD) .. " 2>&1; echo rc=$?")
eq(df:read("*a"), "rc=0\n", "the detection command parses")
df:close()
local lf2 = io.popen("sh -n -c " .. M.quote(Stt.command(nil)) .. " 2>&1; echo rc=$?")
eq(lf2:read("*a"), "rc=0\n", "the Linux script still parses")
lf2:close()

-- TrueNAS SCALE, Proxmox and ReadyNAS: their lines read
local nraw = Stt.parse(table.concat({
    "nas_ok=1", "app=plex|RUNNING", "app=nextcloud|STOPPED",
    "share=Media|/mnt/tank/media|on", "share=Old|/mnt/tank/old|off",
    "rsync=3|/mnt/tank/photos|backup.lan|on|0 3 * * *|SUCCESS",
}, "\n"))
local nv = Stt.values(nraw)
eq(#nv.truenas.apps .. "," .. Stt.upCount(nv.truenas.apps), "2,1", "TrueNAS: apps, one running")
eq(nv.truenas.shares[2].on, false, "TrueNAS: a share turned off")
eq(nv.truenas.rsync[1].schedule .. "|" .. nv.truenas.rsync[1].last, "0 3 * * *|SUCCESS", "TrueNAS: an rsync task's schedule and last run")
eq(Stt.tile("truenas", nv).value, "1 of 2 apps running", "TrueNAS: its card")
eq(Stt.values(Stt.parse("nas_ok=denied")).truenas.denied, true, "TrueNAS: needs sudo")
local pv = Stt.values(Stt.parse(table.concat({
    "pve_ok=1", "vm=101|lxc|pihole|running", "vm=100|qemu|ubuntu|stopped",
    "pst=local-zfs|zfspool|1099511627776|274877906944|on",
    "bjob=backup-1a2b|sun 01:00|on|pbs|all", "bk=1761350400|OK|", "bk=1761264000|job errors|101",
}, "\n")))
eq(pv.proxmox.guests[1].id .. pv.proxmox.guests[1].kind .. "," .. Stt.upCount(pv.proxmox.guests), "100qemu,1", "Proxmox: guests by id, one running")
eq(math.floor(pv.proxmox.storage[1].used * 100 / pv.proxmox.storage[1].total), 25, "Proxmox: storage used")
eq(pv.proxmox.jobs[1].which .. "|" .. pv.proxmox.backups[2].status, "all|job errors", "Proxmox: a backup job, a failed backup")
eq(Stt.tile("proxmox", pv).value, "1 of 2 running", "Proxmox: its card")
eq(#Stt.values(Stt.parse("share=Documents|/data/Documents|on")).shares, 1, "ReadyNAS: its shares")
eq(Stt.proxmoxGuest("lxc", "101", "shutdown"), "pct shutdown 101", "Proxmox: a container's command")
eq(Stt.proxmoxGuest("qemu", "1; rm", "start"), nil, "Proxmox: nothing odd in a command")
eq(Stt.truenasApp("plex", "start"), "sudo midclt call -j app.start plex", "TrueNAS: an app's command")
-- (only on their own systems: no TrueNAS card on a plain Debian)
local deb, tns = { os = "debian" }, { os = "truenas" }
local function has(h, id) for __, x in ipairs(Stt.shown(h, true)) do if x == id then return true end end return false end
eq(tostring(has(deb, "truenas")) .. tostring(has(tns, "truenas")) .. tostring(has(tns, "proxmox")), "falsetruefalse", "the cards only on their systems")

-- Pools and disks, snapshots, Proxmox's node, updates, Raspberry Pi, pfSense, the printer
local mv = Stt.values(Stt.parse(table.concat({
    "nas_ok=1",
    "pool=tank|4398046511104|1099511627776|ONLINE|scrub repaired 0B in 01:02:03 with 0 errors on Sun Oct 19",
    "pool=fast|1099511627776|0|DEGRADED|",
    "tdisk=sda|WDC WD40|4000787030016|tank", "dtemp=sda|34",
    "snap=2|tank/photos|0 0 * * *|on|FINISHED", "repl=1|to backup|off|SUCCESS|1761350400",
    "sd=sdb|Samsung SSD|PASSED|31",
    "upd=12", "pkgmgr=apt", "cache=204800", "jerr=3", "jline=first", "jline=last one", "jsize=48.0M",
    "pi_thr=0x50005", "pi_camera=1", "pi_i2c=0",
    "moon={\"result\": {\"status\": {\"print_stats\": {\"state\": \"printing\", \"filename\": \"cube.gcode\", \"print_duration\": 600.5},"
        .. " \"display_status\": {\"progress\": 0.42, \"message\": null}, \"extruder\": {\"temperature\": 219.8, \"target\": 220.0},"
        .. " \"heater_bed\": {\"temperature\": 59.9, \"target\": 60.0}}}}",
}, "\n")))
eq(#mv.pools .. mv.pools[1].health .. math.floor(mv.pools[1].used * 100 / mv.pools[1].total), "2ONLINE25", "pools: health and space")
eq(#mv.disks .. "," .. mv.disks[1].temp .. "," .. mv.disks[2].health, "2,34,OK", "disks: TrueNAS's temperature, smartctl's health")
eq(mv.truenas.snaps[1].dataset .. "," .. tostring(mv.truenas.repl[1].on) .. "," .. mv.truenas.repl[1].at, "tank/photos,false,1761350400", "TrueNAS: snapshot and replication tasks")
eq(mv.upkeep.updates .. mv.upkeep.manager .. mv.upkeep.errors .. #mv.upkeep.lines .. mv.upkeep.journal, "12apt3249152", "updates and logs")
eq(table.concat(mv.pi.throttled.now, ",") .. "|" .. table.concat(mv.pi.throttled.past, ",") .. "|" .. tostring(mv.pi.opts.camera) .. tostring(mv.pi.opts.i2c),
    "Low voltage,Throttled|Low voltage,Throttled|falsetrue", "Raspberry Pi: throttling and its options (0 is on)")
eq(mv.printer.state .. "," .. mv.printer.file .. "," .. mv.printer.progress .. "," .. mv.printer.nozzle .. "," .. mv.printer.bedTarget,
    "printing,cube.gcode,0.42,219.8,60", "the printer from Moonraker")
eq(Stt.tile("pools", mv), nil, "a section has no card")
eq(Stt.piSet("i2c", true) .. "|" .. tostring(Stt.piSet("rm -rf", true)), "sudo raspi-config nonint do_i2c 0|nil", "Raspberry Pi: an option's command")
eq(Stt.truenasSnapshot("2") .. "|" .. tostring(Stt.printerCmd("explode")), "sudo midclt call pool.snapshottask.run 2|nil", "commands: snapshot, nothing odd")
local pmx = Stt.values(Stt.parse("pve_ok=1\npnode=0.123|4294967296|17179869184|pve-manager/8.2.4/abc\npcl=cluster|home|1|2\npcl=node|pve1|1|\npcl=node|pve2|0|\nptask=1761350400|vzdump|job errors|101"))
eq(pmx.proxmox.node.cpu .. "," .. pmx.proxmox.cluster.name .. tostring(pmx.proxmox.cluster.quorate) .. "," .. #pmx.proxmox.nodes .. "," .. pmx.proxmox.failed[1].guest,
    "12,hometrue,2,101", "Proxmox: node, cluster, failed tasks")
local pfv = Stt.values(Stt.parse("pf_states=842\npf_dhcp=17\ngw=WAN_DHCP|online|1.2ms|0.0%\npif=igb0|1048576|2048\nvpn=WireGuard|1\nvpn=OpenVPN|0"))
eq(pfv.pfsense.states .. "," .. pfv.pfsense.dhcp .. "," .. pfv.pfsense.gateways[1].status .. "," .. pfv.pfsense.ifaces[1].inb .. "," .. #pfv.pfsense.vpns,
    "842,17,online,1024,2", "pfSense: states, leases, gateways, interfaces, VPNs")
eq(tostring(has({ os = "pfsense" }, "pfsense")) .. tostring(has(deb, "pfsense")) .. tostring(has({ os = "raspberrypi" }, "pi")), "truefalsetrue", "sections only on their systems")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
