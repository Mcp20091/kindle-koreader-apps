--[[--
Dark terminal: white on black while a live session or a command's output
is open, with KOReader's own night mode; it goes back when the last of them
closes. SSH's lists keep the normal look (and follow KOReader's
Night mode, as every app). KOReader's Night mode setting isn't changed, and
when it is already on nothing happens.
]]

local Device = require("device")
local UIManager = require("ui/uimanager")

local Dark = { count = 0, ours = false }

local SETTING = "sshclient_dark_mode"

function Dark.isOn() return G_reader_settings:isTrue(SETTING) end

local function flip(night)
    Device.screen:toggleNightMode()
    -- (as KOReader's own Night mode does for a book underneath)
    local ui = require("apps/reader/readerui").instance
    if ui and ui.document and ui.document.provider == "crengine" then
        ui.document:resetCallCache()
        if ui.highlight then ui.highlight:setSelectionColor() end
    end
    UIManager:ToggleNightMode(night)
    UIManager:setDirty("all", "full")
end

local function apply()
    if Dark.count > 0 and Dark.isOn() and not Device.screen.night_mode then
        flip(true)
        Dark.ours = true
    elseif (Dark.count == 0 or not Dark.isOn()) and Dark.ours then
        Dark.ours = false
        if Device.screen.night_mode then flip(false) end
    end
end

--- A screen of SSH opens.
function Dark.enter()
    Dark.count = Dark.count + 1
    apply()
end

--- A screen of SSH closed.
function Dark.leave()
    if Dark.count > 0 then Dark.count = Dark.count - 1 end
    apply()
end

--- KOReader's Night mode is about to change: SSH's own dark mode lets go
-- first (the screen as it was), so the two don't undo each other.
function Dark.release()
    if Dark.ours then
        Dark.ours = false
        if Device.screen.night_mode then flip(false) end
    end
end

function Dark.set(on)
    G_reader_settings:saveSetting(SETTING, on and true or false)
    apply()
end

return Dark
