--[[--
Notes in the apps' shared places (the Apps plugin, through PluginShare;
nothing happens without it): Settings in one place, Search, OneNote's
connection test and Recent apps. (The AI's setup step and test are the
launcher's own.)

@module koplugin.notes.share
]]

local _ = require("gettext")
local T = require("ffi/util").template

local Share = {}

local function PS() return require("pluginshare") end

--- Notes' parts registered (once, from Notes:init).
function Share.install(notes)
    -- (For what is registered before Notes starts: Preview in Settings > AI > Advanced.)
    Share.notes = notes
    local ps = PS()
    -- What it is for the launcher and the web page: its tile, Settings group, web tab
    -- (apps.koplugin/appsinfo.lua).
    ps.appInfo = ps.appInfo or {}
    ps.appInfo.notes = { name = _("Notes"), icon = "notebook-pen", order = 30, group = "writing",
        explore = _("Handwritten notebooks"),
        tiles = { { key = "notes", event = "ShowNotes", line = function(n) return Share.appsLine(n) end } },
        web = { page = "notes", routes = "webnotes", script = "web/notes.js", dir = notes.path,
            card = "Notebooks in their folders, settings, OneNote and AI." } }
    if ps.registerSettings then
        -- (settings: each of them by name, for the launcher's search.)
        ps.registerSettings{ key = "notes", name = _("Notes"), icon = "notebook-pen",
            open = function(name) notes:showSettings(nil, false, name) end,
            settings = function() return notes:settingsNames() end }
    end
    if ps.registerSearch then
        ps.registerSearch{ key = "notes", name = _("Notebooks"), icon = "notebook-pen",
            search = function(q) return Share.search(notes, q) end }
    end
    if ps.registerTest then
        -- (The AI services have their own: the launcher's "ai".)
        ps.registerTest{ key = "notes", name = _("OneNote"),
            configured = function()
                local ok, api = pcall(notes.oneNote, notes)
                return ok and api ~= nil and api:signedIn()
            end,
            run = function(Test) return Share.tests(notes, Test) end }
    end
end

--- Test connection (Apps' test engine, in a child process): OneNote
-- (Microsoft's sign-in, then OneNote itself). Cheap calls only.
function Share.tests(notes, Test)
    local out = {}
    -- What an answer means.
    local function check()
        return function(status, body)
            if status == 200 then return true, _("Working") end
            if status == 401 or status == 403 then return false, _("The sign-in was refused: sign in again") end
            if status == 429 then return false, _("Too many requests") end
            local ok, data = pcall(require("json").decode, tostring(body or ""))
            local err = ok and type(data) == "table" and data.error
            local msg = type(err) == "table" and err.message or (type(err) == "string" and err) or nil
            return false, msg and ("HTTP " .. status .. ": " .. tostring(msg)) or ("HTTP " .. status)
        end
    end
    -- OneNote.
    local okA, api = pcall(notes.oneNote, notes)
    -- (Only once signed in: an App ID alone, from To Do, isn't OneNote set up.)
    if okA and api and api:signedIn() then
        local token, why
        if api.account then
            -- The one Microsoft account: its sign-in is tried in the launcher's
            -- "microsoft" test; here only OneNote. (In the test's child: a token
            -- it gets isn't kept.)
            api.account.store().save = function() end
            token, why = api:accessToken(true)
            if not token then
                table.insert(out, { name = _("OneNote"), detail = "graph.microsoft.com", ok = false, why = tostring(why), raw = tostring(why) })
            end
        else
            api.tokens.save = function() end
            local socket = require("socket")
            local t0 = socket.gettime()
            token, why = api:accessToken(true)
            table.insert(out, { name = _("Microsoft sign-in"), detail = "login.microsoftonline.com", ok = token ~= nil,
                ms = math.floor((socket.gettime() - t0) * 1000), why = token and _("Working") or tostring(why), raw = not token and tostring(why) or nil })
        end
        if token then
            table.insert(out, Test.http{ name = _("OneNote"), url = "https://graph.microsoft.com/v1.0/me/onenote/notebooks?$top=1",
                headers = { Authorization = "Bearer " .. token }, check = check() })
        end
    end
    return out
end

--- Test connection for Notes (Apps' test screen), when Apps is there.
function Share.showTest()
    local ps = PS()
    if ps.showConnectionTest then ps.showConnectionTest("notes") end
end

--- Whether Apps can test connections.
function Share.canTest()
    return PS().showConnectionTest ~= nil
end

--- Search's results for `q` (lower case), from what is in memory only (no
-- notebook read): notebook names (the store's index), then pages whose
-- typed text or handwriting Notes' own search has seen; at most 20.
function Share.search(notes, q)
    local out = {}
    if not (notes.store and q and q ~= "") then return out end
    local skipPuzzles = notes:hasCrosswords()
    local function locked(id)
        local ok, yes = pcall(notes.isLocked, notes, id)
        return ok and yes
    end
    local index = notes.store.index or {}
    for id, e in pairs(index) do
        if #out >= 20 then break end
        if e.name and not (skipPuzzles and e.puzzle) and not locked(id) and e.name:lower():find(q, 1, true) then
            table.insert(out, { title = e.name, sub = _("Notebook"), icon = "notebook-pen",
                open = function() notes:open(id) end })
        end
    end
    -- Pages: typed text and handwriting, where Notes has them in memory already.
    local kept = notes.texts and (notes.texts:readSetting("pages") or {}) or {}
    for id, c in pairs(notes.searchCache or {}) do
        local e = index[id]
        if not (e and skipPuzzles and e.puzzle) and not locked(id) then
            local read = kept[id] or {}
            for i, page in ipairs(c.pages or {}) do
                if #out >= 20 then return out end
                local text = page.typed ~= "" and page.typed:lower():find(q, 1, true) and page.typed
                if not text and page.hash then
                    local k = read[page.id]
                    text = k and k.hash == page.hash and k.text and k.text:lower():find(q, 1, true) and k.text or nil
                end
                if text then
                    local at = text:lower():find(q, 1, true)
                    table.insert(out, { title = c.name, icon = "notebook-pen",
                        sub = T(_("Page %1 · %2"), i, notes.Find.snippet(text, at, #q)),
                        open = function() notes:open(id, i) end })
                end
            end
        end
    end
    return out
end

--- Notes opened (by any route): first in Recent apps.
function Share.opened()
    local ps = PS()
    if ps.noteRecent then pcall(ps.noteRecent, "notes") end
end

--- The launcher's tile line: "12 notebooks · last: Ideas" (the newest notebook's name read
-- from the start of its file, without loading it).
function Share.appsLine(notes)
    local dir = notes.store and notes.store.dir
    local lfs = require("libs/libkoreader-lfs")
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then return "" end
    local count, newest, newestTime = 0, nil, -1
    for name in lfs.dir(dir) do
        if name:match("^nb%d+%.lua$") then
            count = count + 1
            local t = lfs.attributes(dir .. "/" .. name, "modification") or 0
            if t > newestTime then newest, newestTime = name, t end
        end
    end
    if count == 0 then return _("No notebooks yet") end
    local title
    local f = io.open(dir .. "/" .. newest, "r")
    if f then
        local head = f:read(2048) or ""
        f:close()
        local quoted = head:match('name=("[^"\\]*")') or head:match("name=(%b\"\")")
        if quoted then
            local fn = loadstring("return " .. quoted)
            if fn then
                setfenv(fn, {})
                local ok, v = pcall(fn)
                if ok and type(v) == "string" then title = v end
            end
        end
    end
    return title and T(_("%1 notebooks \u{00B7} last: %2"), count, title) or T(_("%1 notebooks"), count)
end

return Share
