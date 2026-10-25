--[[--
OneNote in KOReader: signing in, the OneNote settings, picking the OneNote
notebook, and sending (by hand from the editor's menu or the settings, or by
itself when Wi-Fi is on). Adds these to the Notes plugin.
]]
local DataStorage = require("datastorage")
local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local KO = require("notesko")
local T = require("ffi/util").template

local Editor = require("noteseditor")
local Folders = require("notesfolders")
local OneNote = require("notesonenote")
local Settings = require("notessettings")
local Store = require("notesstore")

local Screen = Device.screen

-- KOReader's network, for notesonenote.
local function httpRequest(method, url, headers, body, timeouts)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    local request = { url = url, method = method, headers = headers or {}, sink = ltn12.sink.table(sink) }
    if body then
        request.source = ltn12.source.string(body)
        request.headers["Content-Length"] = tostring(#body)
    end
    if timeouts then
        socketutil:set_timeout(timeouts[1], timeouts[2])
    elseif body and #body > 20000 then
        socketutil:set_timeout(45, 180)
    else
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    local code = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if type(code) ~= "number" then logger.warn("Notes OneNote:", method, (url:gsub("%?.*", "")), code) end
    return code, table.concat(sink)
end

local function info(text) KO.message(text) end
local function busy(text)
    local msg = KO.wait(text)
    UIManager:forceRePaint()
    return msg
end
local function notify(text) KO.toast(text) end

local function ago(t)
    if not t then return _("Not sent") end
    local minutes = math.floor((os.time() - t) / 60)
    if minutes < 1 then return _("Sent just now") end
    if minutes < 60 then return T(_("Sent %1 min ago"), minutes) end
    if minutes < 48 * 60 then return T(_("Sent %1 h ago"), math.floor(minutes / 60)) end
    return T(_("Sent %1"), os.date("%b %d", t))
end

return function(Notes)

Notes.httpRequest = httpRequest

-- The OneNote file: sign-in tokens, and what was sent of each notebook.
function Notes:oneNoteFile()
    if not self.onenoteFile then
        self.onenoteFile = LuaSettings:open(DataStorage:getSettingsDir() .. "/notes_onenote.lua")
    end
    return self.onenoteFile
end

-- The app ID: set in Notes' OneNote settings, else the To Do plugin's (its
-- settings, then its client_id.txt).
function Notes:oneNoteClientId()
    local id = Settings.get("onenote_client_id")
    if id and id ~= "" then return id end
    local todo = LuaSettings:open(DataStorage:getSettingsDir() .. "/todo.lua"):readSetting("client_id")
    if todo and todo ~= "" then return todo end
    local dir = (self.path or ""):gsub("[^/]+$", "")
    local file = io.open(dir .. "todo.koplugin/client_id.txt", "r")
    if not file then return nil end
    id = file:read("*l")
    file:close()
    return id and id:match("^%s*(.-)%s*$") or nil
end

-- The launcher's shared Microsoft account (Settings > Microsoft), or nil
-- (without the launcher: OneNote's own sign-in, as before).
local function msAccount() return require("pluginshare").microsoft end

--- OneNote on the shared Microsoft account (once, from Notes:init): its own
-- sign-in from before handed over when the account has none (else dropped:
-- signing in again there covers OneNote too), and its part of the sign-in.
function Notes:useMicrosoftAccount()
    local ms = msAccount()
    if not ms then return end
    local file = self:oneNoteFile()
    local own = Settings.get("onenote_client_id")
    if file:readSetting("refresh_token") then
        local taken = ms.adopt{ clientId = own or self:oneNoteClientId(), scope = "Notes.ReadWrite offline_access",
            tokens = { refresh_token = file:readSetting("refresh_token"), access_token = file:readSetting("access_token"),
                expires_at = file:readSetting("expires_at"), authority = file:readSetting("authority") } }
        if taken or ms.signedIn() then
            for __, k in ipairs({ "refresh_token", "access_token", "expires_at", "authority" }) do file:delSetting(k) end
            file:flush()
        end
    elseif own and not ms.clientId() then
        ms.adopt{ clientId = own }
    end
    local function again()
        if self.oneNotePage and UIManager:isWidgetShown(self.oneNotePage) then self:oneNoteSettings() end
    end
    ms.use{ key = "notes", name = _("Notes (OneNote)"), scope = OneNote.ACCOUNT_SCOPE, signedIn = again, signedOut = again }
end

function Notes:oneNote()
    local file = self:oneNoteFile()
    if not self.onenote then
        self.onenote = OneNote.new{
            tokens = {
                get = function(key) return file:readSetting(key) end,
                set = function(key, value)
                    if value == nil then file:delSetting(key) else file:saveSetting(key, value) end
                end,
                save = function() file:flush() end,
            },
            request = httpRequest,
            json = require("json"),
            account = msAccount(),
        }
    end
    local ms = self.onenote.account
    self.onenote.clientId = ms and ms.clientId() or self:oneNoteClientId()
    return self.onenote
end

function Notes:sentOf(id)
    local all = self:oneNoteFile():readSetting("sent") or {}
    return all[id]
end

function Notes:oneNoteStatus(nb)
    local sent = self:sentOf(nb.id)
    return ago(sent and sent.at)
end

-- ------------------------------------------------------------------ settings

--- OneNote's settings (a full page).
function Notes:oneNoteSettings()
    local function row(label, value, fn, kind)
        return { text = value and (label .. ": " .. value) or label, kind = kind or "pick", fn = fn }
    end
    self:settingsSubPage("oneNotePage", _("OneNote"), function()
        local api = self:oneNote()
        local target = Settings.get("onenote_notebook")
        local client = api.clientId
        local ms = api.account
        -- With the launcher: the one Microsoft account (Settings > Microsoft).
        local account = ms and row(_("Microsoft account"),
            api:needsAllow() and _("Sign in again to allow OneNote") or (ms.signedIn() and (ms.account() or _("Signed in"))) or _("Not signed in"),
            function() ms.showSettings() end)
            or row(_("Microsoft account"), api:signedIn() and _("Signed in") or _("Sign in"), function()
                if api:signedIn() then self:oneNoteSignOut() else self:oneNoteSignIn() end
            end)
        return {
            { heading = _("Account") },
            account,
            row(_("OneNote notebook"), target and target.name or _("Pick one"), function() self:pickOneNoteNotebook() end),
            -- (Microsoft's sign-in and OneNote tried: the launcher's connection test.)
            api:signedIn() and require("notesshare").canTest() and row(_("Test connection"), nil, function()
                require("notesshare").showTest()
            end, "open") or false,
            { heading = _("Sending") },
            row(_("Send automatically when Wi-Fi is on"), Settings.get("onenote_auto") and _("On") or _("Off"), function()
                Settings.set("onenote_auto", not Settings.get("onenote_auto"))
                self:oneNoteSettings()
            end, "row"),
            row(_("Notebooks sent"), Settings.get("onenote_picked_only") and _("Ones I pick") or _("All"), function()
                Settings.set("onenote_picked_only", not Settings.get("onenote_picked_only"))
                if Settings.get("onenote_picked_only") then
                    info(_("Hold a notebook in the list to choose whether it goes to OneNote."))
                end
                self:oneNoteSettings()
            end),
            self:anyAI() and row(_("Typed text of each page (read by AI)"), Settings.get("onenote_text") and _("On") or _("Off"), function()
                Settings.set("onenote_text", not Settings.get("onenote_text"))
                self:oneNoteSettings()
            end, "row"),
            row(_("Send all now"), nil, function() self:sendAllToOneNote(false) end, "open"),
            { heading = _("Reading") },
            row(_("Browse OneNote"), nil, function() self:browseOneNote() end, "open"),
            -- (The App ID: Settings > Microsoft's, with the launcher.)
            not ms and { heading = _("Advanced") } or false,
            not ms and row(_("App ID"), client and (client:sub(1, 8) .. "…") or _("Not set"), function() self:editOneNoteClientId() end) or false,
        }
    end)
end

function Notes:editOneNoteClientId()
    local ms = msAccount()
    if ms then return ms.showSettings() end
    local dialog
    dialog = InputDialog:new{
        title = _("App ID (Microsoft Entra application ID)"),
        input = Settings.get("onenote_client_id") or "",
        input_hint = self:oneNoteClientId() or "",
        description = _("Empty: the To Do plugin's app ID."),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
                self:oneNoteSettings()
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local id = dialog:getInputText():match("^%s*(.-)%s*$")
                UIManager:close(dialog)
                Settings.set("onenote_client_id", id ~= "" and id or nil)
                self:oneNoteSettings()
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ------------------------------------------------------------------ sign-in

function Notes:oneNoteSignIn(after)
    local api = self:oneNote()
    local function signedIn()
        if after then after() elseif not Settings.get("onenote_notebook") then self:pickOneNoteNotebook() else self:oneNoteSettings() end
    end
    -- The one Microsoft account: its sign-in asks for To Do's and OneNote's parts at once.
    local ms = api.account
    if ms then
        if api:needsAllow() then
            return KO.message{ title = _("Sign in again to allow OneNote"),
                text = _("This Kindle is signed in to Microsoft for To Do only. Sign in again in Settings > Microsoft: one sign-in covers To Do and OneNote."),
                onOk = function() ms.showSettings() end }
        end
        if not ms.clientId() then return ms.showSettings() end
        return ms.signIn(signedIn)
    end
    if not api.clientId then
        info(_("Set the app ID first (Notes settings > OneNote > App ID)."))
        return
    end
    NetworkMgr:runWhenOnline(function()
        local signIn, why = api:startSignIn()
        if not signIn then return info(T(_("Could not reach Microsoft:\n%1"), tostring(why))) end
        local cancelled, done = false, false
        local dialog
        -- The code to enter, with QR code and Cancel (it comes back when the
        -- QR code closes, until signed in).
        local function showCode()
            dialog = KO.confirm{
                title = _("Sign in to OneNote"),
                text = T(_("On a phone or computer, open\n\n%1\n\nand enter\n\n%2"), signIn.verification_uri, signIn.user_code),
                ok = _("QR code"),
                cancel = _("Cancel"),
                onOk = function()
                    -- The launcher's QR page (a caption saying what to do), else KOReader's.
                    local showQR = require("pluginshare").showQR
                    if showQR then
                        showQR{ text = signIn.verification_uri,
                            caption = T(_("Scan to open the sign-in page, then enter %1"), signIn.user_code),
                            -- (Closed: the code box again, until signed in.)
                            onClose = function()
                                if not (cancelled or done) then UIManager:nextTick(showCode) end
                            end }
                        return
                    end
                    UIManager:show(require("ui/widget/qrmessage"):new{
                        text = signIn.verification_uri,
                        width = Screen:getWidth(),
                        height = Screen:getHeight(),
                        dismiss_callback = function()
                            if not (cancelled or done) then showCode() end
                        end,
                    })
                end,
                onCancel = function() cancelled = true end,
            }
        end
        showCode()
        local interval = tonumber(signIn.interval) or 5
        local deadline = os.time() + (tonumber(signIn.expires_in) or 900)
        local function poll()
            if cancelled then return end
            if os.time() > deadline then
                done = true
                if dialog then UIManager:close(dialog) end
                return info(_("The code ran out. Try signing in again."))
            end
            local result, err = api:pollSignIn(signIn)
            if result == "ok" then
                done = true
                if dialog then UIManager:close(dialog) end
                notify(_("Signed in to OneNote"))
                if after then after() elseif not Settings.get("onenote_notebook") then self:pickOneNoteNotebook() else self:oneNoteSettings() end
            elseif result == "pending" or result == "slow_down" then
                if result == "slow_down" then interval = interval + 5 end
                UIManager:scheduleIn(interval, poll)
            else
                done = true
                if dialog then UIManager:close(dialog) end
                info(T(_("Could not sign in:\n%1"), tostring(err or _("The code ran out"))))
            end
        end
        UIManager:scheduleIn(interval, poll)
    end)
end

function Notes:oneNoteSignOut()
    -- (The one Microsoft account is signed out of in Settings > Microsoft.)
    local ms = self:oneNote().account
    if ms then return ms.showSettings() end
    KO.confirm{
        text = _("Sign out of OneNote?\n\nPages already sent stay in OneNote."),
        danger = true,
        ok = _("Sign out"),
        onOk = function()
            self:oneNote():signOut()
            self:oneNoteSettings()
        end,
        onCancel = function() self:oneNoteSettings() end,
    }
end

-- ------------------------------------------------------------------ the OneNote notebook

function Notes:pickOneNoteNotebook()
    local api = self:oneNote()
    if not api:signedIn() then return self:oneNoteSignIn(function() self:pickOneNoteNotebook() end) end
    NetworkMgr:runWhenOnline(function()
        local list, why = api:notebooks()
        if not list then return info(T(_("Could not read your OneNote notebooks:\n%1"), tostring(why))) end
        local dialog
        local current = Settings.get("onenote_notebook")
        local buttons = {}
        for __, n in ipairs(list) do
            table.insert(buttons, { { text = (current and current.id == n.id and "✓ " or "") .. n.name, align = "left", callback = function()
                UIManager:close(dialog)
                Settings.set("onenote_notebook", { id = n.id, name = n.name })
                self:oneNoteSettings()
            end } })
        end
        table.insert(buttons, { { text = _("New notebook…"), callback = function()
            UIManager:close(dialog)
            self:newOneNoteNotebook()
        end } })
        table.insert(buttons, { { text = _("Cancel"), callback = function()
            UIManager:close(dialog)
            self:oneNoteSettings()
        end } })
        dialog = KO.buttonDialog{
            title = _("Send notebooks to this OneNote notebook\n(each becomes a section)"),
            title_align = "center",
            buttons = buttons,
        }
    end)
end

function Notes:newOneNoteNotebook()
    KO.ask{ title = _("New OneNote notebook"), text = "Kindle Scribe", ok = _("Create"), icon = "plus",
        onCancel = function() self:pickOneNoteNotebook() end,
        done = function(name)
            NetworkMgr:runWhenOnline(function()
                local n, why = self:oneNote():createNotebook(name)
                if not n then return info(T(_("Could not create the notebook:\n%1"), tostring(why))) end
                Settings.set("onenote_notebook", n)
                self:oneNoteSettings()
            end)
        end }
end

-- ------------------------------------------------------------------ where each notebook goes

-- Where notebooks go in OneNote, chosen by holding a notebook or a folder:
-- Settings "onenote_targets" = { ["n:<id>"] or ["f:<folder>"] = { nb = { id,
-- name }, sec = { id, name } or nil } }. Without `sec` each notebook gets a
-- section of its own name in that OneNote notebook (as with the default).

--- Where a notebook goes: its own choice, else its folder's (or a folder
-- above), else the default OneNote notebook. Returns the target ({ nb, sec })
-- or nil, and what it came from ("notebook", "folder" or nil).
function Notes:oneNoteTarget(id)
    return OneNote.targetFor(Settings.get("onenote_targets") or {}, id, self.folders and self.folders:of(id),
        Folders.parent, Settings.get("onenote_notebook"))
end

--- A target as shown: "Work › Meetings", or "Work (a section each)".
function Notes:oneNoteTargetName(t)
    if not t then return _("Not set") end
    if t.sec then return t.nb.name .. " › " .. t.sec.name end
    return T(_("%1 (a section each)"), t.nb.name)
end

--- The hold menu's row: where a notebook ("n:<id>") or a folder ("f:<path>")
-- goes in OneNote.
function Notes:oneNoteWhereText(key)
    local all = Settings.get("onenote_targets") or {}
    local t = all[key]
    if t then return T(_("OneNote: %1"), self:oneNoteTargetName(t)) end
    if key:sub(1, 2) == "n:" then
        local inherited, from = self:oneNoteTarget(key:sub(3))
        if from == "folder" then return T(_("OneNote: %1 (from its folder)"), self:oneNoteTargetName(inherited)) end
    end
    return T(_("OneNote: %1"), _("Default"))
end

local function setTarget(key, t)
    local all = Settings.get("onenote_targets") or {}
    all[key] = t
    Settings.set("onenote_targets", all)
end

--- A folder renamed or moved: its choices (and its subfolders') go with it.
function Notes:moveOneNoteTargets(from, to)
    local all = Settings.get("onenote_targets")
    if not all then return end
    Settings.set("onenote_targets", OneNote.moveTargets(all, from, to))
end

--- Where a notebook ("n:<id>") or a folder ("f:<path>") goes in OneNote:
-- the default, or a OneNote notebook and then a section (one there, a new
-- one, or one of each notebook's own name). `name`: the notebook's or
-- folder's, for new sections. `done()` after a choice.
function Notes:pickOneNoteTarget(key, name, done, back)
    local api = self:oneNote()
    if not api:signedIn() then return self:oneNoteSignIn(function() self:pickOneNoteTarget(key, name, done) end) end
    local folder = key:sub(1, 2) == "f:"
    local function chosen(t)
        setTarget(key, t)
        if done then done() end
        KO.toast(t and T(_("Goes to OneNote: %1"), self:oneNoteTargetName(t)) or _("Goes to the default OneNote notebook"))
    end
    local function sections(nb)
        NetworkMgr:runWhenOnline(function()
            local msg = busy(_("Loading OneNote…"))
            local list, why = api:sections(nb.id)
            UIManager:close(msg)
            if not list then return info(T(_("Could not reach OneNote:\n%1"), tostring(why))) end
            local items = {
                { text = folder and _("A section for each notebook (its name)") or T(_("A section named \"%1\""), name),
                    fn = function() chosen({ nb = nb }) end },
            }
            for __, s in ipairs(list) do
                table.insert(items, { text = s.name, fn = function() chosen({ nb = nb, sec = s }) end })
            end
            table.insert(items, { text = _("New section…"), fn = function()
                KO.ask{ title = T(_("New section in %1"), nb.name), text = name, ok = _("Create"), icon = "plus",
                    done = function(sname)
                        NetworkMgr:runWhenOnline(function()
                            local id, err = api:section(nb.id, sname)
                            if not id then return info(T(_("Could not create the section:\n%1"), tostring(err))) end
                            chosen({ nb = nb, sec = { id = id, name = OneNote.sectionName(sname) } })
                        end)
                    end }
            end })
            KO.list(T(_("Where in %1"), nb.name), items, nil, nil, function() self:pickOneNoteTarget(key, name, done, back) end)
        end)
    end
    NetworkMgr:runWhenOnline(function()
        local msg = busy(_("Loading OneNote…"))
        local list, why = api:notebooks()
        UIManager:close(msg)
        if not list then return info(T(_("Could not read your OneNote notebooks:\n%1"), tostring(why))) end
        local default = Settings.get("onenote_notebook")
        local current = (Settings.get("onenote_targets") or {})[key]
        local items = {
            { text = default and T(_("Default (%1)"), default.name) or _("Default"), checked = current == nil,
                fn = function() chosen(nil) end },
        }
        for __, n in ipairs(list) do
            table.insert(items, { text = n.name, checked = current ~= nil and current.nb.id == n.id,
                fn = function() sections({ id = n.id, name = n.name }) end })
        end
        KO.list(T(_("Send \"%1\" to"), name), items, nil, nil, back)
    end)
end

-- ------------------------------------------------------------------ sending

function Notes:pickedForOneNote(id)
    if not Settings.get("onenote_picked_only") then return true end
    local picked = self:oneNoteFile():readSetting("picked") or {}
    return picked[id] == true
end

function Notes:setPickedForOneNote(id, on)
    local file = self:oneNoteFile()
    local picked = file:readSetting("picked") or {}
    picked[id] = on or nil
    file:saveSetting("picked", picked)
    file:flush()
end

-- Ready to send: signed in and a OneNote notebook picked. Otherwise (not
-- quiet) walks the user there.
function Notes:oneNoteReady(quiet)
    local api = self:oneNote()
    if not api:signedIn() then
        if not quiet then self:oneNoteSignIn() end
        return false
    end
    if not Settings.get("onenote_notebook") then
        if not quiet then self:pickOneNoteNotebook() end
        return false
    end
    return true
end

-- One notebook to OneNote; returns counts or nil and why.
function Notes:sendNotebookNow(id)
    local nb, why = self.store:read(id)
    if not nb then return nil, why end
    if nb.newIds then self.store:save(nb) end   -- page ids must stay as sent
    local file = self:oneNoteFile()
    local all = file:readSetting("sent") or {}
    local sent = all[id] or {}
    local sha2 = require("ffi/sha2")
    local tmp = DataStorage:getDataDir() .. "/cache/notes-onenote.png"
    require("util").makePath(DataStorage:getDataDir() .. "/cache")
    -- With typed text on, Claude's reading of each page goes under it (a
    -- page that cannot be read now goes without; it is read next time).
    local withText = Settings.get("onenote_text") and self.claudeReady and self:claudeReady()
    -- Where it goes: its own choice, its folder's, or the default.
    local target = self:oneNoteTarget(id)
    if not target then return nil, _("Pick a OneNote notebook first (Notes settings > OneNote).") end
    local counts, err = self:oneNote():send(nb, {
        oneNoteNotebook = target.nb.id,
        -- (A section chosen: shared, so its pages carry the notebook's name.)
        sectionId = target.sec and target.sec.id or nil,
        titlePrefix = target.sec and nb.name or nil,
        sent = sent,
        hash = function(page)
            local h = sha2.md5(Store.pageText(page, page.paper or nb.paper))
            if withText then h = h .. (self:keptText(nb, page) and "+t" or "+?") end
            return h
        end,
        text = withText and function(i)
            local text = self:pageTextNow(nb, i)
            return text
        end or nil,
        png = function(i)
            Editor.pagePNG(nb, i, tmp)
            local f = io.open(tmp, "rb")
            local data = f and f:read("*a") or ""
            if f then f:close() end
            return data
        end,
        created = os.date("!%Y-%m-%dT%H:%M:%SZ", nb.created or os.time()),
    })
    os.remove(tmp)
    -- What went is kept even when something failed part way.
    all[id] = sent
    file:saveSetting("sent", all)
    file:flush()
    return counts, err
end

local function summary(counts)
    local n = counts.created + counts.updated + counts.deleted
    if n == 0 then return _("Nothing changed") end
    return T(_("%1 new, %2 changed, %3 removed"), counts.created, counts.updated, counts.deleted)
end

local TOKEN_KEYS = { "refresh_token", "access_token", "expires_at", "authority" }

--- Notebooks sent to OneNote in a child process (notesbg), so KOReader keeps
-- answering however slow the network is (just after waking, say). The
-- child saves nothing: what went, a renewed sign-in and pages' text read on
-- the way come back and are kept here. One send at a time; notebooks asked
-- for meanwhile go after it. done(total, why).
function Notes:sendInBackground(ids, done)
    if self.oneNoteSending then
        for __, id in ipairs(ids) do table.insert(self.oneNoteSending.next, id) end
        return
    end
    local job = { next = {} }
    self.oneNoteSending = job
    -- Page ids made now, here (the child writes no notebooks).
    for __, id in ipairs(ids) do
        local nb = self.store:read(id)
        if nb and nb.newIds then self.store:save(nb) end
    end
    local file, texts = self:oneNoteFile(), self:textFile()
    require("notesbg").run(function()
        file.flush = function() end
        texts.flush = function() end
        self.store.save = function() return true end
        local total, why = { created = 0, updated = 0, deleted = 0 }, nil
        for __, id in ipairs(ids) do
            local ok, counts, err = pcall(self.sendNotebookNow, self, id)
            if not ok or not counts then
                why = tostring(ok and err or counts)
                break
            end
            for k, v in pairs(counts) do total[k] = total[k] + v end
        end
        local out = { total = total, why = why, tokens = {}, sent = {}, texts = {} }
        for __, k in ipairs(TOKEN_KEYS) do out.tokens[k] = file:readSetting(k) or false end
        local all, read = file:readSetting("sent") or {}, texts:readSetting("pages") or {}
        for __, id in ipairs(ids) do
            out.sent[id] = all[id] or false
            out.texts[id] = read[id] or false
        end
        return out
    end, function(r, err)
        if r then
            -- A renewed sign-in kept (not after signing out meanwhile).
            if file:readSetting("refresh_token") then
                for k, v in pairs(r.tokens or {}) do
                    if v == false then file:delSetting(k) else file:saveSetting(k, v) end
                end
            end
            local all = file:readSetting("sent") or {}
            for id, sent in pairs(r.sent or {}) do
                if sent then all[id] = sent end
            end
            file:saveSetting("sent", all)
            file:flush()
            -- Pages read on the way (the newer reading of a page wins).
            local read = texts:readSetting("pages") or {}
            for id, pages in pairs(r.texts or {}) do
                if pages then
                    read[id] = read[id] or {}
                    for pid, e in pairs(pages) do
                        local mine = read[id][pid]
                        if not mine or (mine.at or 0) < (e.at or 0) then read[id][pid] = e end
                    end
                end
            end
            texts:saveSetting("pages", read)
            texts:flush()
        end
        self.oneNoteSending = nil
        self:refresh()
        done(r and r.total, r and r.why or err)
        if #job.next > 0 then
            local more = {}
            for __, id in ipairs(job.next) do table.insert(more, id) end
            self:sendInBackground(more, function(total, why)
                if why then logger.warn("Notes: OneNote send failed", why) end
            end)
        end
    end, 15 * 60)
end

--- Sends one notebook (the editor's menu). Quiet: no questions, no
-- message unless it went wrong. In the background (KOReader goes on).
function Notes:sendToOneNote(id, quiet)
    if not self:oneNoteReady(quiet) then return end
    local function go()
        if not quiet then notify(_("Sending to OneNote…")) end
        self:sendInBackground({ id }, function(counts, why)
            if counts and not why then
                if not quiet or counts.created + counts.updated + counts.deleted > 0 then notify(T(_("OneNote: %1"), summary(counts))) end
            else
                logger.warn("Notes: OneNote send failed", why)
                if quiet then notify(_("OneNote: could not send")) else info(T(_("Could not send to OneNote:\n%1"), tostring(why))) end
            end
        end)
    end
    if quiet then
        if NetworkMgr:isOnline() then go() end
    else
        NetworkMgr:runWhenOnline(go)
    end
end

--- Every notebook (or the picked ones) to OneNote, in the background.
function Notes:sendAllToOneNote(quiet)
    if not self:oneNoteReady(quiet) then return end
    local function go()
        local ids = {}
        for __, nb in ipairs(self.store:list()) do
            if self:pickedForOneNote(nb.id) and not (quiet and self:isLocked(nb.id)) then table.insert(ids, nb.id) end
        end
        if #ids == 0 then return end
        if not quiet then notify(T(_("Sending %1 notebooks to OneNote…"), #ids)) end
        self:sendInBackground(ids, function(total, why)
            if why then
                logger.warn("Notes: OneNote send failed", why)
                if quiet then notify(_("OneNote: could not send")) else info(T(_("Could not send to OneNote:\n%1"), tostring(why))) end
            elseif total and (not quiet or total.created + total.updated + total.deleted > 0) then
                notify(T(_("OneNote: %1"), summary(total)))
            end
        end)
    end
    if quiet then
        if NetworkMgr:isOnline() then go() end
    else
        NetworkMgr:runWhenOnline(go)
    end
end

-- Sending by itself: after closing a notebook, and when Wi-Fi comes on.
function Notes:autoSendNotebook(id)
    if not Settings.get("onenote_auto") or not self:pickedForOneNote(id) or self:isLocked(id) then return end
    UIManager:scheduleIn(1, function() self:sendToOneNote(id, true) end)
end

function Notes:onNetworkConnected()
    if not Settings.get("onenote_auto") then return end
    if self.autoTask then UIManager:unschedule(self.autoTask) end
    self.autoTask = function()
        self.autoTask = nil
        self:sendAllToOneNote(true)
    end
    UIManager:scheduleIn(15, self.autoTask)
end

end
