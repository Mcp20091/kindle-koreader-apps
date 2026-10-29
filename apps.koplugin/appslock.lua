--[[--
App lock: one passcode (digits, on a keypad) or password (the keyboard) for the
apps you tick in Settings > Launcher > App lock. Every app asks it before it
opens, however it's opened (a tile, Recent apps, the Tools menu, a gesture, a
notification, search, a quick button). Every app with a tile in its PS.appInfo
entry (appsinfo.lua) can be locked; it asks where it opens, by its first tile's
key or its plugin's name:

    function SSH:show()
        local lock = require("pluginshare").lock
        if lock and lock.ask("ssh", function() self:show() end) then return end
        ...
    end

An app with no tile, or whose tile only switches something (the web server),
isn't listed; `lock = false` in its entry leaves one out too. (PS.lockApps.<key>
= { key, name, plugin } still adds one by hand.)

`ask` returns true when it put up the passcode (the app returns; `fn` runs once
it's right), else false (not locked, or unlocked already). Once right, every
locked app stays unlocked until the Kindle sleeps (or for the time chosen);
at sleep a locked app on the screen is covered by the passcode, so waking the
Kindle doesn't show it. After 3 wrong tries the next waits 30 seconds.

Kept in koreader/settings/apps_lock.lua as a salted hash, never the passcode,
and never logged. A backup has it only with Include keys and sign-ins. This
keeps people who pick up the Kindle out; it isn't encryption (the files are
still on the Kindle).

The core (Lock.new) is plain Lua, so the tests run it.
]]

local _ = require("gettext")

local Lock = {}

local ROUNDS = 2000
local TRIES = 3        -- wrong tries before a wait
local WAIT = 30        -- seconds

-- What can be locked: { key (its first tile's), keys (all its tiles'), name, plugin (its
-- plugin's name: its open screen is found there) }, from each app's PS.appInfo entry (and any
-- PS.lockApps entry), by name, then the launcher's Settings (where the apps' keys and sign-ins are).
function Lock.apps(info)
    local PS = package.loaded["pluginshare"] or require("pluginshare")
    local list, seen = {}, {}
    for __, a in ipairs(require("appsinfo").list(info)) do
        local e = a.entry
        local first = type(e.tiles) == "table" and e.tiles[1]
        if e.lock ~= false and type(first) == "table" and first.key and not first.switches then
            local keys = {}
            for __, t in ipairs(e.tiles) do if type(t) == "table" and t.key then keys[t.key] = true end end
            list[#list + 1] = { key = first.key, keys = keys, plugin = a.plugin, name = e.name or a.plugin }
            seen[first.key] = true
        end
    end
    for __, a in pairs(PS.lockApps or {}) do
        if type(a) == "table" and a.key and a.name and not seen[a.key] then list[#list + 1] = a end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    list[#list + 1] = { key = "settings", name = _("Settings") }
    return list
end

-- How long it stays unlocked: until the Kindle sleeps, or minutes (sleep locks it too).
Lock.STAYS = { "sleep", 5, 15, 60 }
function Lock.stayName(v)
    if v == 5 then return _("5 minutes") end
    if v == 15 then return _("15 minutes") end
    if v == 60 then return _("1 hour") end
    return _("Until the Kindle sleeps")
end

function Lock.appOf(key)
    for __, a in ipairs(Lock.apps()) do
        if a.key == key or a.plugin == key or (a.keys and a.keys[key]) then return a end
    end
end

-- ------------------------------------------------------------------ the core (plain Lua)

local Core = {}
Core.__index = Core

--- o: { store = { get(k), set(k, v), save() }, now = fn() -> seconds, hash = fn(salt, secret), random = fn() -> salt }.
function Lock.new(o)
    return setmetatable({ store = o.store, now = o.now or os.time, hash = o.hash, random = o.random,
        fails = 0, waitUntil = nil, unlockedAt = nil }, Core)
end

function Core:isSet() return self.store.get("hash") ~= nil end
--- "passcode" (digits) or "password".
function Core:kind() return self.store.get("kind") == "password" and "password" or "passcode" end
--- A passcode's length (the keypad checks at its last digit).
function Core:digits() return self:kind() == "passcode" and self.store.get("digits") or nil end
function Core:stay() return self.store.get("stay") or "sleep" end
function Core:setStay(v)
    self.store.set("stay", v ~= "sleep" and v or nil)
    self.store.save()
end

function Core:apps() return self.store.get("apps") or {} end
function Core:isLocked(key)
    local a = Lock.appOf(key)
    return self:isSet() and a ~= nil and self:apps()[a.key] == true
end
function Core:setLocked(key, on)
    local apps = self:apps()
    apps[key] = on and true or nil
    self.store.set("apps", next(apps) and apps or nil)
    self.store.save()
end
function Core:countLocked()
    local n = 0
    for __, a in ipairs(Lock.apps()) do if self:apps()[a.key] then n = n + 1 end end
    return n
end

--- Unlocked now: right since the Kindle last slept (and within the time chosen).
function Core:isOpen()
    if not self.unlockedAt then return false end
    local stay = self:stay()
    if type(stay) == "number" and self.now() - self.unlockedAt >= stay * 60 then
        self.unlockedAt = nil
        return false
    end
    return true
end
--- Asks before opening `key`: locked, and not unlocked now.
function Core:needs(key) return self:isLocked(key) and not self:isOpen() end
function Core:relock() self.unlockedAt = nil end

--- Whether `secret` would do: a passcode is 4 to 8 digits, a password 4 characters or more.
-- Returns true, or the reason in plain words.
function Lock.valid(kind, secret)
    secret = secret or ""
    if kind == "passcode" then
        if not secret:match("^%d+$") or #secret < 4 or #secret > 8 then return _("Use 4 to 8 digits.") end
    elseif #secret < 4 then
        return _("Use at least 4 characters.")
    end
    return true
end

function Core:set(kind, secret)
    if Lock.valid(kind, secret) ~= true then return false end
    local salt = self.random()
    self.store.set("kind", kind)
    self.store.set("salt", salt)
    self.store.set("hash", self.hash(salt, secret))
    self.store.set("digits", kind == "passcode" and #secret or nil)
    self.store.save()
    self.unlockedAt, self.fails, self.waitUntil = self.now(), 0, nil
    return true
end

--- Takes the passcode away (the apps ticked stay ticked, for when there's one again).
function Core:clear()
    for __, k in ipairs({ "kind", "salt", "hash", "digits" }) do self.store.set(k, nil) end
    self.store.save()
    self.unlockedAt = nil
end

--- Seconds before another try may be made (after 3 wrong), or 0.
function Core:waitLeft()
    if not self.waitUntil then return 0 end
    local left = self.waitUntil - self.now()
    if left <= 0 then self.waitUntil = nil return 0 end
    return left
end

--- Tries `secret`: true (unlocked), or false and why: "wrong" or "wait" (with the seconds left).
function Core:try(secret)
    local ok, why, left = self:check(secret)
    if ok then self.unlockedAt = self.now() end
    return ok, why, left
end

--- Whether `secret` is right, without unlocking (the web page's changes): wrong tries count
-- and wait as on the Kindle.
function Core:check(secret)
    local left = self:waitLeft()
    if left > 0 then return false, "wait", left end
    if self:isSet() and self.hash(self.store.get("salt"), secret or "") == self.store.get("hash") then
        self.fails = 0
        return true
    end
    self.fails = self.fails + 1
    if self.fails >= TRIES then
        self.fails, self.waitUntil = 0, self.now() + WAIT
        return false, "wait", WAIT
    end
    return false, "wrong"
end

--- The line under the keypad (or the password box) for a wrong try.
function Lock.why(kind, why, left)
    if why == "wait" then
        local T = require("ffi/util").template
        return T(_("Try again in %1 seconds."), math.ceil(left or WAIT))
    end
    return kind == "password" and _("Wrong password. Try again.") or _("Wrong passcode. Try again.")
end

-- ------------------------------------------------------------------ on the Kindle

local the   -- the one lock, made when first used

local function hash(salt, secret)
    local sha = require("ffi/sha2")
    local h = salt .. "\0" .. secret
    for __ = 1, ROUNDS do h = sha.sha256(salt .. h) end
    return h
end

local function random()
    local f = io.open("/dev/urandom", "rb")
    local bytes = f and f:read(16)
    if f then f:close() end
    local out = {}
    for i = 1, 16 do out[i] = string.format("%02x", bytes and bytes:byte(i) or math.random(0, 255)) end
    return table.concat(out)
end

function Lock.get()
    if the then return the end
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local file = LuaSettings:open(DataStorage:getSettingsDir() .. "/apps_lock.lua")
    the = Lock.new{ hash = hash, random = random, store = {
        get = function(k) return file:readSetting(k) end,
        set = function(k, v) if v == nil then file:delSetting(k) else file:saveSetting(k, v) end end,
        save = function() file:flush() end,
    } }
    return the
end

--- The words for this lock: "passcode" or "password".
local function word(l)
    return l:kind() == "password" and _("password") or _("passcode")
end

--- Asks for the passcode (or password): { title, subtitle, onOk, onCancel, cover }.
function Lock.prompt(o)
    local l = Lock.get()
    local Popup = require("appspopup")
    local kind = l:kind()
    local function first()
        local left = l:waitLeft()
        return left > 0 and Lock.why(kind, "wait", left) or nil
    end
    if kind == "passcode" then
        return Popup.keypad{ title = o.title, subtitle = o.subtitle or _("Enter your passcode"), digits = l:digits(),
            note = first(), cover = o.cover, onCancel = o.onCancel,
            check = function(code)
                local ok, why, left = l:try(code)
                return ok or Lock.why(kind, why, left)
            end,
            onOk = function() if o.onOk then o.onOk() end end }
    end
    local box
    box = Popup.request{ title = o.title, subtitle = first() or o.subtitle or _("Enter your password"),
        password = true, typing = true, width = 380, cover = o.cover, onCancel = o.onCancel,
        buttons = {
            { icon = "x", text = _("Cancel"), cancel = true },
            { icon = "lock-open", text = _("Unlock"), primary = true, needsText = true, keep = true, fn = function(text, b)
                local ok, why, left = l:try(text)
                if ok then
                    b:stopTyping()
                    b:close()
                    if o.onOk then o.onOk() end
                    return
                end
                b.subtitle = Lock.why(kind, why, left)
                b:setText("")
                b:redraw()
            end },
        } }
    return box
end

--- Before opening a locked app: true when the passcode is up (fn runs once it's right).
-- (Should the lock itself fail, the app opens: logged, never a dead app.)
function Lock.ask(key, fn)
    local ok, asked = pcall(function()
        local l = Lock.get()
        if not l:needs(key) then return false end
        local a = Lock.appOf(key)
        local T = require("ffi/util").template
        Lock.prompt{ title = T(_("%1 is locked"), a.name), onOk = fn }
        return true
    end)
    if not ok then require("logger").warn("App lock:", asked) return false end
    return asked
end

--- Runs fn now, or once the passcode is right (a quick button of a locked app, say).
function Lock.run(key, fn)
    if not Lock.ask(key, fn) then fn() end
end

--- The Kindle going to sleep: locked again. A locked app on the screen is covered by the
-- passcode (Cancel goes to the launcher), so waking it doesn't show the app: at once when
-- nothing else shows while it sleeps (no sleep screen: the cover is what shows), else when it
-- wakes (on a Kindle the sleep screen is shown before this, and the cover would go over it).
function Lock.suspend()
    local l = Lock.get()
    if not l:isSet() then return end
    l:relock()
    local Screensaver = package.loaded["ui/screensaver"]
    if Screensaver and Screensaver.screensaver_widget then
        Lock.coverAtWake = true
        return
    end
    Lock.cover()
end

--- Awake again: the cover, when it waited for the sleep screen to go.
function Lock.resume()
    if not Lock.coverAtWake then return end
    Lock.coverAtWake = nil
    Lock.cover()
end

function Lock.cover()
    local UIManager = require("ui/uimanager")
    -- (Already covered, or asking: once is enough.)
    for __, e in ipairs(UIManager._window_stack or {}) do
        if e.widget.kind == "keypad" or (e.widget.is_shared_popup and e.widget.cover) then return end
    end
    local key = Lock.onScreen()
    if not key then return end
    local a = Lock.appOf(key)
    local T = require("ffi/util").template
    Lock.prompt{ title = T(_("%1 is locked"), a.name), cover = true,
        onCancel = function()
            local PS = require("pluginshare")
            if PS.appsHome then PS.appsHome() end
        end }
end

--- The locked app whose screen is shown now (anywhere in the window stack), or nil.
function Lock.onScreen()
    local l = Lock.get()
    local UIManager = require("ui/uimanager")
    local PS = require("pluginshare")
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    local shown = {}
    for __, e in ipairs(UIManager._window_stack or {}) do shown[e.widget] = true end
    -- The launcher's Settings screens.
    local view = PS.appsView and PS.appsView()
    if l:isLocked("settings") and view and shown[view] and view.mode ~= "tiles" and view.mode ~= "switcher" then return "settings" end
    for __, a in ipairs(Lock.apps()) do
        local p = a.plugin and ui and ui[a.plugin]
        if l:isLocked(a.key) and type(p) == "table" then
            for __, field in ipairs({ "screen", "page", "view", "widget" }) do
                local w = p[field]
                if type(w) == "table" and shown[w] and w ~= (ui and ui.view) then return a.key end
            end
        end
    end
end

-- ------------------------------------------------------------------ setting it

--- A new passcode or password: the kind, then it twice. done() after.
function Lock.choose(done)
    local l = Lock.get()
    local Popup = require("appspopup")
    local function saved(kind, secret)
        l:set(kind, secret)
        Popup.toast(kind == "password" and _("Password set.") or _("Passcode set."), 2)
        if done then done() end
    end
    local function passcode()
        Popup.keypad{ title = _("New passcode"), subtitle = _("4 to 8 digits"), doneText = _("Next"),
            check = function() return true end,
            onOk = function(code)
                Popup.keypad{ title = _("New passcode"), subtitle = _("Enter it again"), digits = #code,
                    check = function(again) return again == code or _("They don't match. Try again.") end,
                    onOk = function() saved("passcode", code) end }
            end }
    end
    local function password()
        Popup.request{ title = _("New password"), subtitle = _("At least 4 characters"), password = true, typing = true, width = 380,
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = "check", text = _("Next"), primary = true, needsText = true, keep = true, fn = function(text, b)
                    local ok = Lock.valid("password", text)
                    if ok ~= true then
                        b.subtitle = ok
                        b:redraw()
                        return
                    end
                    b:stopTyping()
                    b:close()
                    Popup.request{ title = _("New password"), subtitle = _("Enter it again"), password = true, typing = true, width = 380,
                        buttons = {
                            { icon = "x", text = _("Cancel"), cancel = true },
                            { icon = "check", text = _("Save"), primary = true, needsText = true, keep = true, fn = function(again, b2)
                                if again ~= text then
                                    b2.subtitle = _("They don't match. Try again.")
                                    b2:setText("")
                                    b2:redraw()
                                    return
                                end
                                b2:stopTyping()
                                b2:close()
                                saved("password", text)
                            end },
                        } }
                end },
            } }
    end
    Popup.menu{ title = _("Lock with"), items = {
        { text = _("Passcode (digits)"), fn = passcode },
        { text = _("Password"), fn = password },
    } }
end

--- Settings > Launcher > App lock, as settings rows (PS.settingsPage). Opening it asks first.
function Lock.rows()
    local l = Lock.get()
    local Popup = require("appspopup")
    local rows = { { heading = l:isSet() and l:kind() == "password" and _("PASSWORD") or _("PASSCODE") } }
    local function refreshed(refresh) return function() if refresh then refresh() end end end
    if not l:isSet() then
        rows[#rows + 1] = { _("Passcode"), _("Off"), function(refresh) Lock.choose(refreshed(refresh)) end }
    else
        rows[#rows + 1] = { l:kind() == "password" and _("Password") or _("Passcode"), _("On · Change"),
            function(refresh) Lock.choose(refreshed(refresh)) end }
        rows[#rows + 1] = { _("Stay unlocked"), Lock.stayName(l:stay()), pick = function()
            local options = {}
            for __, v in ipairs(Lock.STAYS) do options[#options + 1] = { Lock.stayName(v), v } end
            return options, l:stay(), function(v) l:setStay(v) end
        end }
        rows[#rows + 1] = { l:kind() == "password" and _("Turn off password") or _("Turn off passcode"), "", function(refresh)
            Popup.confirm{ title = _("Turn off"), text = _("Every app opens without asking. The apps ticked stay ticked for when you set one again."),
                ok = _("Turn off"), onOk = function() l:clear() if refresh then refresh() end end }
        end }
    end
    rows[#rows + 1] = { heading = _("LOCKED APPS") }
    local PS = require("pluginshare")
    -- (The apps installed: each registered itself in PS.lockApps.)
    for __, a in ipairs(Lock.apps()) do
        rows[#rows + 1] = { a.name, l:apps()[a.key] == true, function() l:setLocked(a.key, not l:apps()[a.key]) end }
    end
    -- The web page reaches every app's data over Wi-Fi: its own password keeps that shut.
    local okWeb, Auth = pcall(require, "webauth")
    if okWeb and Auth then
        rows[#rows + 1] = { heading = _("WEB PAGE") }
        rows[#rows + 1] = { _("Web page password"), Auth.isSet() and _("On") or _("Off"), function()
            if PS.showSettings then PS.showSettings("webpage") end
        end }
    end
    return rows
end

--- Opens Settings > Launcher > App lock (after the passcode, if there is one).
function Lock.showSettings(jump)
    local PS = require("pluginshare")
    local function open()
        PS.settingsPage{ title = _("App lock"), jump = jump, rows = Lock.rows }
    end
    local l = Lock.get()
    if l:isSet() and not l:isOpen() then
        return Lock.prompt{ title = _("App lock"), onOk = open }
    end
    open()
end

return Lock
