--[[--
A file from the Kindle, picked in the apps' design (instead of KOReader's own
file chooser): a full page with the shared title bar, the folders first,
then the files `filter` keeps; a folder opens, ‹ goes up a folder (from the
first one, it closes). Notes uses it for From a PDF…, a template from a
picture and Insert picture.

    require("notespick").show{ title = _("Choose a PDF"), path = start,
        filter = function(name) return name:lower():match("%.pdf$") end,
        done = function(path) ... end }
]]

local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local Pick = {}

-- A folder's folders and the files kept, sorted by name (hidden ones left out).
local function listing(dir, filter)
    local dirs, files = {}, {}
    local ok, iter, obj = pcall(lfs.dir, dir)
    if not ok then return dirs, files end
    for name in iter, obj do
        if name ~= "." and name ~= ".." and not name:match("^%.") then
            local mode = lfs.attributes(dir .. "/" .. name, "mode")
            if mode == "directory" then table.insert(dirs, name)
            elseif mode == "file" and filter(name) then table.insert(files, name) end
        end
    end
    local function byName(a, b) return a:lower() < b:lower() end
    table.sort(dirs, byName)
    table.sort(files, byName)
    return dirs, files
end

--- o: { title, path (where to start), filter(name) -> keep, done(path) }.
function Pick.show(o)
    local start = (o.path or "/mnt/us/documents"):gsub("/+$", "")
    local dir = start
    local page
    local function items()
        local dirs, files = listing(dir, o.filter or function() return true end)
        local out = {}
        for __, d in ipairs(dirs) do
            -- (A folder: its name and a /, as the Kindle's file lists show them.)
            table.insert(out, { text = d .. "/", bold = true, callback = function()
                dir = dir .. "/" .. d
                page:switchItemTable(nil, items(), 1)
                page.title = T("%1 · %2", o.title, d)
            end })
        end
        for __, f in ipairs(files) do
            table.insert(out, { text = f, callback = function()
                UIManager:close(page)
                o.done(dir .. "/" .. f)
            end })
        end
        if #out == 0 then table.insert(out, { text = _("Nothing to pick here."), dim = true }) end
        return out
    end
    page = require("notessettingspage"):new{
        title = o.title,
        items = items(),
        titleOpts = {
            bell = require("notesko").bell(),
            -- ‹ Back: up a folder; from where it started, closed.
            back = function()
                if dir == start or not dir:find("/") then return UIManager:close(page) end
                dir = dir:match("^(.*)/[^/]+$")
                page.title = dir == start and o.title or T("%1 · %2", o.title, dir:match("([^/]+)$"))
                page:switchItemTable(nil, items(), 1)
            end,
        },
    }
    UIManager:show(page)
    return page
end

return Pick
