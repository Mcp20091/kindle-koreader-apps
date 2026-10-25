--[[--
The live session's AI chat (the session's AI key): a page of its own with,
at the top, the session's last lines as they come, then the conversation.
Each question goes with what the terminal shows now (its last part, secrets
blanked) and the conversation so far, so "Why did that fail?" or "What
next?" needs nothing copied.

Questions come from Ask (the launcher's request box: typed, or written by
hand), from holding the session's AI key (the box at once), and from Ask AI
on a selection of the terminal's text (that part, with the terminal's last
lines around it). Their answers go into this chat.

A suggested command has Run (after "Run in this session?" with the risk
warning, typed in with Enter, so sudo asks for its password in the
session), Paste (on the prompt line without Enter: you check it and press
Enter), Edit (change it, then Run or Paste) and Save (on the host).
Nothing is typed without your tap. ✕ or Back goes back to the session; the
conversation lasts as long as the session and isn't kept after it.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local Foot = require("sshbuttons")
local KO = require("sshko")
local M = require("sshmodel")

-- (sshai, loaded when first used)
local function A() return require("sshai") end

-- How many of the session's lines the strip shows.
local STRIP_LINES = 3

-- The quick questions, before anything is asked.
local EXPLAIN = "Explain what the terminal shows. If something went wrong, say why and what to try next."
local SUMMARIZE = "Summarize what the terminal shows, down to what matters."

local Chat = InputContainer:extend{
    session = nil,
    covers_fullscreen = true,
}

--- The chat of a session (made once; it lasts as long as the session).
function Chat.of(session)
    if not session.chat then session.chat = Chat:new{ session = session, turns = {} } end
    return session.chat
end

function Chat:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:isTouchDevice() then
        self.ges_events = {
            Swipe = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

function Chat:screenText() return table.concat(self.session.input.charlist or {}) end

--- The conversation as shown: each question, then its answer (commands as "$ …").
function Chat:convText()
    if #self.turns == 0 then
        return _("Ask about what the session shows: why something failed, what to do next, or a command for a job. "
            .. "Each question goes with what the terminal shows now (passwords, keys and tokens in it are blanked) "
            .. "and the conversation so far.")
    end
    local out = {}
    for __, t in ipairs(self.turns) do
        out[#out + 1] = T(_("You: %1"), t.label or t.question)
        if t.shown then out[#out + 1] = t.shown end
    end
    out[#out + 1] = A().RISK
    return table.concat(out, "\n\n")
end

--- The commands the last answer suggests.
function Chat:commands()
    local last = self.turns[#self.turns]
    return last and last.cmds or {}
end

function Chat:build()
    local w, h = self.dimen.w, self.dimen.h
    local pad = Size.padding.large
    -- the apps' title bar (‹ back to the terminal, ⌂, recent apps, the clock, ⟳, 🔔, ⋮)
    local title = require("sshbar"):new{
        title = T(_("AI · %1"), M.hostName(self.session.host)),
        on_back = function() self:back() end,
        on_home = function()
            self:back()
            require("sshui").home()
        end,
        on_refresh = function() UIManager:setDirty(self, "full") end,
        on_menu = function() require("sshui").more() end,
    }
    -- (the page is built again after each answer: the last bar's clock stops)
    if self.bar then self.bar:stop() end
    self.bar = title
    title:tick(self)
    -- the session's last lines, kept up to date (stripChanged)
    self.strip_text = TextBoxWidget:new{
        text = M.lastLines(self:screenText(), STRIP_LINES),
        -- (the terminal's own font, so its lines are the terminal's)
        face = self.session.face,
        width = w - 2 * pad - 2 * Size.padding.default - 2 * Size.border.thin,
        height = self.session.input:getLineHeight() * STRIP_LINES,
    }
    self.strip = FrameContainer:new{
        bordersize = Size.border.thin, radius = Size.radius.default, padding = Size.padding.default,
        margin = 0, self.strip_text,
    }
    -- The foot: ‹ n/m › and one row of icon buttons (sshbuttons), the main one last.
    local cmds = self:commands()
    local buttons
    if #cmds > 0 then
        buttons = {
            { icon = "send", text = _("Ask more"), aiJob = "ssh_session", fn = function() self:askBox{} end },
            { icon = "download", text = _("Save"), fn = function() self:pick(function(c) self:save(c) end) end },
            { icon = "pencil", text = _("Edit"), fn = function() self:pick(function(c) self:edit(c) end) end },
            { icon = "arrow-down-to-line", text = _("Paste"), fn = function() self:pick(function(c) self:typeIt(c) end) end },
            { icon = "terminal", text = _("Run"), primary = true, fn = function() self:pick(function(c) self:run(c) end) end },
        }
    else
        buttons = {
            { icon = "settings", text = _("AI settings"), fn = function()
                local ai = require("pluginshare").ai
                if ai then ai.showSettings() end
            end },
            { icon = "circle-help", text = _("How do I…"), aiJob = "ssh_session", fn = function() self:askBox{ hint = _("How do I check disk space?") } end },
            { icon = "file-text", text = _("Summarize"), aiJob = "ssh_session", fn = function() self:ask(SUMMARIZE, _("Summarize the screen")) end },
            { icon = "sparkles", text = _("Explain"), aiJob = "ssh_session", fn = function() self:ask(EXPLAIN, _("Explain the screen")) end },
            { icon = "send", text = #self.turns > 0 and _("Ask more") or _("Ask AI"), primary = true, aiJob = "ssh_session",
                fn = function() self:askBox{} end },
        }
    end
    self.foot = Foot:new{ width = w, buttons = buttons, show_parent = self, turn = function(d) self:turn(d) end }
    local gap = Size.padding.default
    local conv_h = h - title:getHeight() - self.strip:getSize().h - self.foot:getSize().h - 3 * gap
    self.conv = ScrollTextWidget:new{
        text = self:convText(),
        face = Font:getFace("x_smallinfofont"),
        width = w - 2 * pad,
        height = conv_h,
        dialog = self,
        scroll_callback = function() self:pageChanged() end,
    }
    self[1] = FrameContainer:new{
        width = w, height = h, background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0,
        VerticalGroup:new{
            align = "center",
            title,
            VerticalSpan:new{ width = gap },
            self.strip,
            VerticalSpan:new{ width = gap },
            self.conv,
            VerticalSpan:new{ width = gap },
            self.foot,
        },
    }
    self:pageChanged()
end

--- The conversation's page in ‹ n/m ›.
function Chat:pageChanged()
    if self.foot and self.conv then self.foot:setPage(Foot.pageOf(self.conv)) end
end

function Chat:turn(d)
    self.conv:scrollText(d)
    self:pageChanged()
end

--- Shows the chat over the session (its keyboard closed).
function Chat:show()
    self.session.dialog:onCloseKeyboard()
    self.shown = true
    self:build()
    UIManager:show(self, "full")
end

--- ✕ or Back: back to the session (the conversation stays).
function Chat:back()
    self.shown = false
    UIManager:close(self, "full")
    self.session.dialog:onShowKeyboard()
    UIManager:setDirty(self.session.dialog, "ui")
end

function Chat:onClose()
    self:back()
    return true
end

--- The session printed something: the strip shows its last lines (a second
-- later at most, so a stream of output redraws it once a second).
function Chat:stripChanged()
    if not self.shown or self.strip_task then return end
    self.strip_task = function()
        self.strip_task = nil
        if not self.shown then return end
        local text = M.lastLines(self:screenText(), STRIP_LINES)
        if text == self.strip_text.text then return end
        self.strip_text:setText(text)
        UIManager:setDirty(self, "ui", self.strip.dimen)
    end
    UIManager:scheduleIn(1, self.strip_task)
end

function Chat:onSwipe(__, ges)
    if self.conv and self.conv.dimen and ges.pos:intersectWith(self.conv.dimen) then
        if ges.direction == "west" or ges.direction == "north" then
            self:turn(1)
            return true
        elseif ges.direction == "east" or ges.direction == "south" then
            self:turn(-1)
            return true
        end
    end
    if KO.fromLeftEdge(ges) then
        self:back()
        return true
    end
end

--- Sends a question (with the screen and the conversation); `label`: how
-- it shows in the conversation (the quick questions' short name);
-- selection: the part of the terminal asked about. The answer shows in the
-- chat (opened for it when it isn't).
function Chat:ask(question, label, selection)
    local Ai = A()
    local plugin = self.session.plugin
    local text = M.aiSessionText(self:screenText(), self.turns, question, Ai.amount("session"), Ai.secrets(plugin), selection)
    Ai.ask("session", Ai.system(self.session.host), text, function(answer)
        local cmds, shown = M.aiCommands(answer)
        -- (label: how a quick question shows in the conversation)
        self.turns[#self.turns + 1] = { question = question, label = label, answer = answer, shown = shown, cmds = cmds }
        if self.shown then self:refresh(true) else self:show() end
    end, function()
        -- (a problem was shown: back to where the question came from)
        if not self.shown then self.session.dialog:onShowKeyboard() end
    end)
end

--- The page again (after an answer, at its end).
function Chat:refresh(to_end)
    if not self.shown then return end
    self:build()
    if to_end then self.conv:scrollToBottom() end
    UIManager:setDirty(self, "ui")
end

-- The examples in the request box.
local EXAMPLES = { _("Why did that fail?"), _("What should I do next?"), _("How do I check disk space?") }
local ABOUT_SELECTION = { _("What does this mean?"), _("Why did this fail?"), _("How do I fix it?") }

--- Ask AI: the launcher's request box (type, or write by hand), or
-- KOReader's without it. o: { hint, selection (the part asked about) }.
-- From the terminal (the chat not shown), its keyboard comes back on Cancel.
function Chat:askBox(o)
    local from_terminal = not self.shown
    if from_terminal then self.session.dialog:onCloseKeyboard() end
    local function cancelled()
        if from_terminal then self.session.dialog:onShowKeyboard() end
    end
    local about = o.selection and M.lastLines(o.selection, 1):sub(1, 60)
    local function send(q)
        self:ask(q, about and T(_("About “%1”: %2"), about, q) or nil, o.selection)
    end
    local request = KO.request()
    if request then
        local items = {}
        for __, e in ipairs(o.selection and ABOUT_SELECTION or EXAMPLES) do
            items[#items + 1] = { text = e, fn = function(box) box:setText(e) end }
        end
        return request{
            title = _("Ask AI"),
            subtitle = about and T(_("About: %1"), about) or _("About what the session shows"),
            hint = o.hint or _("Type a question, or write it"),
            pen = KO.pen(),
            penTitle = _("Write your question"),
            sections = { { heading = _("EXAMPLES"), items = items } },
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = "send", text = _("Answer"), primary = true, needsText = true, aiJob = "ssh_session", fn = function(t) send(t) end },
            },
            onCancel = cancelled,
        }
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Ask AI"),
        description = about and T(_("About: %1"), about) or nil,
        input = "",
        input_hint = o.hint or _("Why did that fail?"),
        buttons = { KO.withWrite({
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
                cancelled()
            end },
            { text = _("Answer"), is_enter_default = true, callback = function()
                local q = dialog:getInputText()
                if not q:match("%S") then return end
                UIManager:close(dialog)
                send(q)
            end },
        }, function() return dialog end, "text") },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- One of the last answer's commands: the only one, or picked.
function Chat:pick(cb)
    local cmds = self:commands()
    if #cmds == 1 then return cb(cmds[1]) end
    local items = {}
    for __, c in ipairs(cmds) do items[#items + 1] = { text = c, fn = function() cb(c) end } end
    KO.list(_("Which command?"), items)
end

--- Paste: on the session's prompt line, without Enter; back to the
-- session to check it and press Enter.
function Chat:typeIt(cmd)
    self:back()
    self.session:transmit(cmd)
end

--- Run: asks first (with the risk warning), then types it in with Enter,
-- back in the session (where sudo can ask for its password).
function Chat:run(cmd)
    KO.confirm{ title = _("Run in this session?"), ok = _("Run"), text = cmd .. "\n\n" .. A().RISK,
        onOk = function()
            self:back()
            self.session:typeLine(cmd)
        end }
end

--- Edit: change the command first, then Run it (your own now: no second
-- question) or Paste.
function Chat:edit(cmd)
    local function run(c)
        self:back()
        self.session:typeLine(c)
    end
    local request = KO.request()
    if request then
        return request{ title = _("Edit command"), text = cmd, pen = KO.pen(), penTitle = _("Write the command"),
            penKind = "command", typing = true, buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = "arrow-down-to-line", text = _("Paste"), needsText = true, fn = function(c) self:typeIt(c) end },
                { icon = "terminal", text = _("Run"), primary = true, needsText = true, fn = run },
            } }
    end
    local dialog
    local row = {
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
        { text = _("Paste"), callback = function()
            local c = dialog:getInputText()
            if not c:match("%S") then return end
            UIManager:close(dialog)
            self:typeIt(c)
        end },
        { text = _("Run"), is_enter_default = true, callback = function()
            local c = dialog:getInputText()
            if not c:match("%S") then return end
            UIManager:close(dialog)
            run(c)
        end },
    }
    KO.withWrite(row, function() return dialog end, "command")
    dialog = InputDialog:new{
        title = _("Edit command"),
        input = cmd,
        input_face = Font:getFace("smallinfont", 20),
        allow_newline = false,
        buttons = { row },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Save: one of the host's saved commands.
function Chat:save(cmd)
    local plugin, host = self.session.plugin, self.session.host
    local UI = require("sshui")
    UI.editCommand({ name = "", cmd = cmd }, function(__, name, c, os_id)
        table.insert(host.commands, { id = M.newId(plugin.store.data, "c"), name = name, cmd = c, os = os_id })
        plugin:saved()
        UI.refreshHost(plugin, host)
        KO.toast(T(_("Saved on %1."), M.hostName(host)))
    end, false, _("Save as command"))
end

--- The session ended: so does the conversation.
function Chat:closeAll()
    if self.shown then
        self.shown = false
        UIManager:close(self)
    end
    self.turns = {}
end

return Chat
