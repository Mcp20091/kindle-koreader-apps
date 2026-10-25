--[[--
Closing a notebook and naming notebooks: the "When closing" setting (save
automatically, or ask: Save, Rename…, Don't save), names made from the date
and time, and names suggested by the AI from the notebook's first written
page (in the Rename box, and after closing a notebook still named by date
when "Suggest names (AI)" is on).

@module koplugin.notes.close
]]

local DataStorage = require("datastorage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local KO = require("notesko")
local T = require("ffi/util").template

local Settings = require("notessettings")
local Store = require("notesstore")
local UI = require("notesui")

local NAME_PROMPT = "This image is a page from my handwritten notebook on a Kindle Scribe. "
    .. "Reply with a short title for the notebook (2 to 6 words) that says what it is about, "
    .. "in the language it is written in. Reply with the title only: no quotes, no punctuation at the end."

local function info(text) KO.message(text) end

return function(Notes)
    --- A new notebook's name when none is typed: the date and time, e.g.
    -- "Oct 21, 2:47 PM" (12 or 24 hours, as KOReader is set).
    function Notes.defaultName()
        return (os.date("%b %d"):gsub(" 0", " ")) .. ", " .. UI.clock()
    end

    --- A name you gave with the date added (Settings > New notebooks > Add
    -- the date to names): "Oct 21 – Meeting" or "Meeting – Oct 21". `when`:
    -- the notebook's date (now for a new one).
    function Notes.datedName(name, when)
        local how = Settings.get("name_date")
        if how ~= "before" and how ~= "after" then return name end
        local date = (os.date("%b %d", when or os.time()):gsub(" 0", " "))
        if name:find(date, 1, true) then return name end
        return how == "before" and (date .. " – " .. name) or (name .. " – " .. date)
    end

    --- Whether a notebook still has a name made for it (the date and time,
    -- or the older "Notes Oct 21").
    function Notes.isDefaultName(name)
        name = tostring(name or "")
        return name:match("^%a%a%a %d%d?, %d%d?:%d%d") ~= nil or name:match("^Notes %a%a%a %d%d$") ~= nil
    end

    -- The first page with writing on it, as a PNG (nil when nothing is written).
    local function firstPagePNG(nb)
        for i, page in ipairs(nb.pages or {}) do
            if #(page.strokes or {}) > 0 or (page.items and #page.items > 0) then
                local tmp = DataStorage:getDataDir() .. "/cache/notes-name.png"
                require("util").makePath(DataStorage:getDataDir() .. "/cache")
                local ok = pcall(require("noteseditor").pagePNG, nb, i, tmp, { long = 1568 })
                local f = ok and io.open(tmp, "rb")
                local png = f and f:read("*a")
                if f then f:close() end
                os.remove(tmp)
                return png
            end
        end
    end

    --- A name for the notebook from the AI (read from its first written
    -- page), or nil and why. Asks now: Wi-Fi must be on.
    function Notes:suggestNameNow(nb)
        local png = firstPagePNG(nb)
        if not png then return nil, _("Nothing is written in this notebook yet.") end
        local ok, text, why = pcall(function() return self:claude("read"):transcribe(png, NAME_PROMPT) end)
        if not ok then return nil, tostring(text) end
        if not text then return nil, why end
        local name = tostring(text):match("^%s*([^\n]+)") or ""
        name = name:gsub("^[#%*\"'“”‘’%s]+", ""):gsub("[\"'“”‘’%*%.%s]+$", "")
        if name == "" then return nil, _("No name came back.") end
        return name:sub(1, 80)
    end

    --- The Rename box: `nb` (a notebook) renamed with `done(name)`; its
    -- "Suggest name" button asks the AI.
    function Notes:renameDialog(nb, done, title)
        local function save(name)
            if name == "" then return end
            -- Named for the first time: with the date, when the settings say so.
            if Notes.isDefaultName(nb.name) and not Notes.isDefaultName(name) then
                name = Notes.datedName(name, nb.created)
            end
            done(name)
        end
        -- The launcher's box: the name (or the pen), Cancel, Suggest (the AI) and Save.
        local request = KO.request()
        if request then
            local buttons = { { icon = "x", text = _("Cancel"), cancel = true } }
            if self:anyAI() then
                table.insert(buttons, { icon = "sparkles", text = _("Suggest"), keep = true, aiJob = "read", fn = function(__, box)
                    if not self:claudeReady("read") then return info(self:aiNotReadyText("read")) end
                    box:stopTyping()
                    NetworkMgr:runWhenOnline(function()
                        local msg = KO.wait(_("Suggesting a name…"))
                        UIManager:forceRePaint()
                        local name, why = self:suggestNameNow(nb)
                        if msg and msg.close then msg:close() else UIManager:close(msg) end
                        if not name then return info(T(_("Couldn't suggest a name:\n%1"), tostring(why))) end
                        box:setText(name)
                    end)
                end })
            end
            table.insert(buttons, { icon = "check", text = _("Save"), primary = true, needsText = true, fn = function(name) save(name) end })
            return request{ title = title or _("Rename notebook"), text = nb.name, pen = KO.pen(), penTitle = _("Write the name"),
                penKind = "name", typing = true, buttons = buttons }
        end
        local dialog
        dialog = InputDialog:new{
            title = title or _("Rename notebook"),
            input = nb.name,
            buttons = { KO.compact{
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                KO.writeButton(function() return dialog end, { kind = "name" }),
                self:anyAI() and { text = _("Suggest"), callback = function()
                    if not self:claudeReady("read") then return info(self:aiNotReadyText("read")) end
                    NetworkMgr:runWhenOnline(function()
                        local msg = KO.wait(_("Suggesting a name…"))
                        UIManager:forceRePaint()
                        local name, why = self:suggestNameNow(nb)
                        UIManager:close(msg)
                        if not name then return info(T(_("Couldn't suggest a name:\n%1"), tostring(why))) end
                        dialog:setInputText(name)
                    end)
                end },
                { text = _("Save"), is_enter_default = true, callback = function()
                    local name = dialog:getInputText()
                    UIManager:close(dialog)
                    if name == "" then return end
                    -- Named for the first time: with the date, when the settings say so.
                    if Notes.isDefaultName(nb.name) and not Notes.isDefaultName(name) then
                        name = Notes.datedName(name, nb.created)
                    end
                    done(name)
                end },
            } },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    --- Closing a notebook with changes, when "When closing" is Ask.
    function Notes:askOnClose(ed)
        -- (Closed without a choice: the notebook stays open, and ⌂ no longer waits.)
        KO.list(T(_("Save changes to \"%1\"?"), ed.notebook.name), {
            { text = _("Save"), fn = function() ed:close() end },
            { text = _("Rename…"), fn = function()
                self:renameDialog(ed.notebook, function(name)
                    ed.notebook.name = name
                    ed:changed()
                    ed:close()
                end)
            end },
            { text = _("Don't save"), danger = true, fn = function() self:discardChanges(ed) end },
        }, function() ed.homeAfter = false end)
    end

    --- The notebook closed as it was when opened (a new one removed).
    function Notes:discardChanges(ed)
        local id, opened, new = ed.notebook.id, ed.openedText, ed.isNew
        ed.discard = true
        ed:close()
        if self.kept then self.kept[id] = nil end
        if new then
            self.store:delete(id)
            self.folders:forget(id)
            self.folders:save()
        elseif opened then
            local nb = Store.parse(opened)
            if nb then
                local ok, why = self.store:save(nb)
                if not ok then info(T(_("Could not undo the changes:\n%1"), tostring(why))) end
            end
        end
        self:refresh()
    end

    --- After a notebook still named by date is closed: the AI's name for it,
    -- offered (Suggest names (AI) on, AI set up, Wi-Fi on).
    function Notes:offerName(id)
        if not Settings.get("suggest_names") or not self:claudeReady("read") or not NetworkMgr:isOnline() then return end
        local nb = self.store:read(id)
        if not nb or not Notes.isDefaultName(nb.name) then return end
        -- Asked in the background (KOReader goes on); offered when it answers.
        require("notesbg").run(function() return { name = self:suggestNameNow(nb) } end, function(r)
            local name = r and r.name
            if name then name = Notes.datedName(name, nb.created) end
            local fresh = self.store:read(id)
            if not name or not fresh or fresh.name ~= nb.name or name == nb.name then return end
            self:offerNameNow(id, nb, name)
        end, 120)
    end

    function Notes:offerNameNow(id, nb, name)
        KO.confirm{
            text = T(_("Rename \"%1\" to \"%2\"?"), nb.name, name),
            ok = _("Rename"),
            cancel = _("Keep"),
            onOk = function()
                local fresh = self.store:read(id)
                if not fresh then return end
                fresh.name = name
                self.store:save(fresh)
                self:refresh()
            end,
        }
    end
end
