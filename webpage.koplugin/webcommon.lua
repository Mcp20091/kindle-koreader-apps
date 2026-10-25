--[[--
Shared by the web page's sections: the running KOReader screen (whose
plugins the pages work with), Microsoft's sign-in by code (To Do and
OneNote), and small helpers.
]]

local UIManager = require("ui/uimanager")

local Common = {}

--- The open KOReader screen (a book or the file browser), whose plugin instances are live.
function Common.ui()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local found = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    if found then
        Common.lost = nil
        return found
    end
    -- Switching books can leave both unset (the old screen's close clears
    -- the new one's): the one on screen, then.
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        local class = getmetatable(w)
        if w and ((ReaderUI and class == ReaderUI) or (FileManager and class == FileManager)) then return w end
    end
    -- Nothing found: what is on screen, in the log (once until found again).
    if not Common.lost then
        Common.lost = true
        local names = {}
        for __, e in ipairs(UIManager._window_stack) do table.insert(names, tostring(e.widget and (e.widget.name or e.widget.id) or "?")) end
        require("logger").warn("Web server: no library or book open; on screen:", table.concat(names, ", "))
    end
end

function Common.plugin(name)
    local ui = Common.ui()
    return ui and ui[name]
end

--- Microsoft's sign-in by code for `api` (startSignIn, pollSignIn): the code
-- and address for the browser to show, then polled on the reader until done.
-- Returns a state table { status = "waiting"|"ok"|"expired"|"error", code, url, message }.
function Common.deviceCode(api, done)
    local signIn, why = api:startSignIn()
    if not signIn then return nil, tostring(why) end
    local state = { status = "waiting", code = signIn.user_code, url = signIn.verification_uri }
    local deadline = os.time() + (tonumber(signIn.expires_in) or 900)
    local interval = tonumber(signIn.interval) or 5
    -- Each look waits on the network (and the reader with it): three slow
    -- ones in a row (the connection is gone) end it, not 15 minutes of them.
    local slow = 0
    local function poll()
        if state.cancelled then return end
        if os.time() > deadline then
            state.status = "expired"
            return
        end
        local started = os.time()
        local result, err = api:pollSignIn(signIn)
        slow = (result == "pending" and os.time() - started >= 8) and slow + 1 or 0
        if slow >= 3 then
            state.status = "error"
            state.message = "Lost the connection to Microsoft. Check Wi-Fi and try again."
            return
        end
        if result == "ok" then
            state.status = "ok"
            if done then pcall(done) end
        elseif result == "pending" or result == "slow_down" then
            if result == "slow_down" then interval = interval + 5 end
            UIManager:scheduleIn(interval, poll)
        else
            state.status = result == "expired" and "expired" or "error"
            state.message = err and tostring(err) or nil
        end
    end
    UIManager:scheduleIn(interval, poll)
    return state
end

--- Only the keys of `allowed` (key -> "boolean" / "number" / "string" / "table") from `input`.
function Common.pick(input, allowed)
    local out = {}
    for k, kind in pairs(allowed) do
        local v = input[k]
        if v ~= nil and (type(v) == kind or (kind == "any")) then out[k] = v end
    end
    return out
end

--- A table with string keys turned into a JSON object even when empty (KOReader's
-- encoder writes an empty table as an array).
function Common.set(t)
    local out = {}
    for k, v in pairs(t or {}) do
        if v then table.insert(out, k) end
    end
    table.sort(out)
    return out
end

function Common.fromList(list)
    local out = {}
    for __, k in ipairs(type(list) == "table" and list or {}) do out[k] = true end
    return out
end

-- ------------------------------------------------------------------ pop-ups on the Kindle

-- The apps' shared pop-ups (Apps' PluginShare.popup), or KOReader's own without Apps.
local function popup() return require("pluginshare").popup end

--- A notice for a moment ("Password set.").
function Common.toast(text, seconds)
    local P = popup()
    if P then return P.toast(text, seconds) end
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = seconds or 2 })
end

--- Something to read, with OK.
function Common.message(text)
    local P = popup()
    if P then return P.message(text) end
    UIManager:show(require("ui/widget/infomessage"):new{ text = text })
end

--- Ask first: { text, ok, onOk, cancel, onCancel }.
function Common.confirm(o)
    local P = popup()
    if P then return P.confirm(o) end
    UIManager:show(require("ui/widget/confirmbox"):new{ text = o.text, ok_text = o.ok, cancel_text = o.cancel,
        ok_callback = o.onOk, cancel_callback = o.onCancel })
end

--- A menu from KOReader's ButtonDialog fields ({ title, buttons }); a button that only closes is left out.
function Common.buttonDialog(o)
    local P = popup()
    if not P then
        local d = require("ui/widget/buttondialog"):new(o)
        UIManager:show(d)
        return d
    end
    local items = {}
    local strict = o.dismissable == false
    for __, row in ipairs(o.buttons or {}) do
        for __, b in ipairs(row) do
            local text = b.text or (b.text_func and b.text_func())
            if text and (strict or (text ~= "Close" and text ~= "Cancel" and text ~= require("gettext")("Close") and text ~= require("gettext")("Cancel"))) then
                table.insert(items, { text = text, enabled = b.enabled ~= false, fn = b.callback })
            end
        end
    end
    return P.menu{ title = o.title, items = items, no_close = strict, keep_open = strict, dismissable = o.dismissable }
end

return Common
