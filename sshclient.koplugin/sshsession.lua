--[[--
A live session: dbclient in a pseudo-terminal, shown in a terminal window
with KOReader's keyboard. The screen is KOReader's own terminal text
(terminputtext.lua from its Terminal plugin: VT52 and some VT100), so
prompts and line-by-line programs work; full-screen ones (top, nano) don't
draw well. Commands pastes a saved command where you type.

How the pty is opened and read follows KOReader's Terminal plugin
(AGPL-3.0); here the program in it is dbclient, not a local shell.
]]

local Device = require("device")
local Font = require("ui/font")
local GestureRange = require("ui/gesturerange")
local InputDialog = require("ui/widget/inputdialog")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local buffer = require("string.buffer")
local ffi = require("ffi")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local C = ffi.C
require("ffi/posix_h")

local Dark = require("sshdark")
local KO = require("sshko")
local M = require("sshmodel")

local CHUNK_SIZE = 80 * 40
local KEY_FONT = 22   -- the keys row's labels: the on-screen keyboard's size

local Session = {}
Session.__index = Session

--- KOReader's terminal text widget, from its Terminal plugin; nil when that
-- plugin isn't there.
local function termInputText()
    if Session.TermInputText ~= nil then return Session.TermInputText or nil end
    local DataStorage = require("datastorage")
    for __, p in ipairs({ "plugins/terminal.koplugin/terminputtext.lua",
        DataStorage:getDataDir() .. "/plugins/terminal.koplugin/terminputtext.lua" }) do
        local ok, cls = pcall(dofile, p)
        if ok and type(cls) == "table" then
            Session.TermInputText = cls
            return cls
        end
    end
    Session.TermInputText = false
end

--- Opens a session to host (ready: trusted, with its password or key).
-- plugin gives the commands for Commands. cmd (optional): typed in (with
-- Enter) once the device answers, as if you typed it.
function Session.open(plugin, host, password, cmd)
    local TermInputText = termInputText()
    if not TermInputText then
        return KO.message(_("Live sessions need KOReader's Terminal emulator plugin."))
    end
    local self = setmetatable({ plugin = plugin, host = host, password = password, ctrl = false, pending = cmd }, Session)
    self.face = Font:getFace("smallinfont", G_reader_settings:readSetting("terminal_font_size", 14))
    self.chunk = buffer.new(CHUNK_SIZE)
    self.dialog = self:makeDialog(TermInputText)
    self.input = self.dialog._input_widget
    -- (hold, or hold and drag: a selection, copied; see selectable)
    self:selectable()
    local bar = ScrollTextWidget.scroll_bar_width + ScrollTextWidget.text_scroll_span
    local cw = TextWidget:new{ text = " ", face = self.face }:getSize().w
    self.cols = math.floor((self.input.width - bar) / cw)
    self.rows = math.floor(self.input.height / self.input:getLineHeight())
    if not self:spawn() then
        return KO.message(_("Can't start the session."))
    end
    self.input:resize(self.rows, self.cols)
    Dark.enter()
    UIManager:show(self.dialog)
    Session.current = self
    plugin.screen = self.dialog
    self.refresh_time = 1 / 32
    UIManager:scheduleIn(0.25, self.refresh, self)
    self.dialog:onShowKeyboard(true)
    return self
end

function Session:spawn()
    local ptmx = C.open("/dev/ptmx", bit.bor(C.O_RDWR, C.O_NONBLOCK, C.O_CLOEXEC))
    if ptmx == -1 then
        logger.err("SSH: can't open /dev/ptmx:", ffi.string(C.strerror(ffi.errno())))
        return false
    end
    if C.grantpt(ptmx) ~= 0 or C.unlockpt(ptmx) ~= 0 then
        C.close(ptmx)
        return false
    end
    local name = C.ptsname(ptmx)
    if name == nil then
        C.close(ptmx)
        return false
    end
    local slave = ffi.string(name)
    local store = self.plugin.store
    local key = self.host.auth == "key" and self.host.key and store:keyFile(self.host.key) or nil
    local args = M.dbclientArgs(store:dbclient(), self.host, { pty = true, keyFile = key })
    -- everything the child needs, made before fork
    local argv = ffi.new("char*[?]", #args + 1)
    local keep = {}
    for i, a in ipairs(args) do
        keep[i] = ffi.new("char[?]", #a + 1, a)
        argv[i - 1] = keep[i]
    end
    argv[#args] = nil
    local stty = T("stty cols %1 rows %2 2>/dev/null", self.cols, self.rows)

    local pid = C.fork()
    if pid < 0 then
        C.close(ptmx)
        return false
    elseif pid == 0 then
        C.close(ptmx)
        C.setsid()
        local pts = C.open(slave, C.O_RDWR)
        if pts == -1 then os.exit(1) end
        C.dup2(pts, 0)
        C.dup2(pts, 1)
        C.dup2(pts, 2)
        C.close(pts)
        if not Device:isAndroid() then os.execute(stty) end
        C.setenv("TERM", "vt52", 1)
        C.setenv("HOME", store.dir, 1)
        C.unsetenv("SSH_AUTH_SOCK")
        if self.password then
            C.setenv("DROPBEAR_PASSWORD", self.password, 1)
        else
            C.unsetenv("DROPBEAR_PASSWORD")
        end
        C.execvp(argv[0], argv)
        io.stdout:write("Can't start dbclient.\n")
        os.exit(1)
    end
    self.ptmx = ptmx
    self.pid = pid
    self.open = true
    keep = nil -- luacheck: ignore
    return true
end

function Session:receive()
    local ptr = self.chunk:reset():ref()
    local free = CHUNK_SIZE
    repeat
        local count = tonumber(C.read(self.ptmx, ptr, free))
        if count <= 0 then break end
        ptr = ptr + count
        free = free - count
    until free == 0
    return self.chunk:commit(CHUNK_SIZE - free):get()
end

--- Whether dbclient is still running (and collects it once it ended).
function Session:alive()
    if not self.pid then return false end
    local status = ffi.new("int[1]")
    local r = C.waitpid(self.pid, status, C.WNOHANG)
    if r == self.pid or r == -1 then
        self.pid = nil
        return false
    end
    return true
end

function Session:refresh()
    if not self.open then return end
    local text = self:receive()
    if text ~= "" then
        if self.pending and M.hostOS(self.host) == "pfsense" then
            -- pfSense signs admin and root in to its console menu: 8 is its
            -- shell; the command goes in at the shell's prompt (…/root: )
            self.seen = ((self.seen or "") .. text):sub(-500)
            if self.seen:find("Enter an option:%s*$") then
                self.seen = ""
                UIManager:scheduleIn(0.3, function() self:transmit("8\r") end)
            elseif self.seen:find("[#%$:]%s*$") then
                local cmd = self.pending
                self.pending, self.seen = nil, nil
                UIManager:scheduleIn(0.3, function() self:typeLine(cmd) end)
            end
        elseif self.pending then
            -- the command to type, once the device has answered
            local cmd = self.pending
            self.pending = nil
            UIManager:scheduleIn(0.5, function() self:typeLine(cmd) end)
        end
        self.input:interpretAnsiSeq(text)
        if self.chat then self.chat:stripChanged() end
        -- nano started: this terminal can't draw it well (once a session)
        if not self.nanoHint and text:find("GNU nano", 1, true) then
            self.nanoHint = true
            KO.toast(_("nano doesn't draw well in this terminal. Edit (at the bottom) opens a file in the Kindle's editor; Keys has nano's keys."), 8)
        end
        self.input:trimBuffer(self.buffer_size or 2 * 40 * 80 * 10)
        self.refresh_time = 1 / 32
    else
        if not self:alive() then return self:ended() end
        -- slower while nothing comes (up to every 5 seconds)
        self.refresh_time = math.min(5, self.refresh_time < 1 and self.refresh_time * 2 or self.refresh_time * 1.1)
    end
    UIManager:scheduleIn(self.refresh_time, self.refresh, self)
end

function Session:transmit(chars)
    if not self.open then return end
    C.write(self.ptmx, chars, #chars)
    self.refresh_time = 1 / 32
    UIManager:unschedule(self.refresh)
    UIManager:scheduleIn(self.refresh_time, self.refresh, self)
end

--- A command typed in and sent with Enter, as if you typed it (after you
-- tapped Run: never by itself).
function Session:typeLine(cmd)
    if not self.open then return end
    self:transmit(cmd .. "\r")
end

--- This session on top again (what is over it closes), with the keyboard.
function Session:toFront()
    for __ = 1, 10 do
        local top = UIManager:getTopmostVisibleWidget()
        if not top or top == self.dialog then break end
        UIManager:close(top)
    end
    self.dialog:onShowKeyboard()
    UIManager:setDirty(self.dialog, "ui")
end

--- dbclient ended (exit, or the connection went): say so where you type.
function Session:ended()
    self.open = false
    if self.ptmx then
        C.close(self.ptmx)
        self.ptmx = nil
    end
    self.input:addChars("\n" .. _("[Session ended]") .. "\n", true)
end

function Session:close()
    if Session.current == self then Session.current = nil end
    -- (the AI chat ends with the session)
    if self.chat then
        self.chat:closeAll()
        self.chat = nil
    end
    if self.plugin.screen == self.dialog then require("sshui").noteScreen() end
    UIManager:unschedule(self.refresh)
    if self.open then
        self.open = false
        if self.pid then
            C.kill(self.pid, 15)
            local status = ffi.new("int[1]")
            for __ = 1, 20 do
                if C.waitpid(self.pid, status, C.WNOHANG) ~= 0 then break end
                C.usleep(50000)
            end
            if C.waitpid(self.pid, status, C.WNOHANG) == 0 then
                C.kill(self.pid, 9)
                C.waitpid(self.pid, status, 0)
            end
            self.pid = nil
        end
        if self.ptmx then
            C.close(self.ptmx)
            self.ptmx = nil
        end
    end
    UIManager:close(self.dialog)
    Dark.leave()
end

--- Commands: the host's saved commands, its recent ones and the command
-- list; the one tapped is pasted where you type (Enter runs it).
function Session:pickCommand()
    local UI = require("sshui")
    self.dialog:onCloseKeyboard()
    UI.pickCommand(self.plugin, self.host, function(cmd)
        if cmd then self:transmit(cmd) end
        self.dialog:onShowKeyboard()
        UIManager:setDirty(self.dialog, "ui")
    end)
end

--- AI (with an AI set up): the session's AI chat (sshaichat), which sees
-- what the terminal shows. Its commands are typed in only with Type it, and
-- never with Enter.
function Session:aiMenu()
    require("sshaichat").of(self):show()
end

--- Selecting in the terminal: hold on a word (it's selected), or hold and
-- drag over a part. KOReader's own Select mode can't work here (the terminal
-- takes no taps to place the cursor), so the hold selects instead, with
-- KOReader's highlight. The part is copied to the clipboard at once, then
-- shown with Paste, Copy all and, with an AI, Ask AI.
function Session:selectable()
    local input = self.input
    -- (the terminal makes its text widget again as output comes)
    local function textWidget()
        local t = input.text_widget
        return t and (t.text_widget or t)
    end
    input.onHoldTextBox = function(__, __, ges)
        local tw = textWidget()
        if tw and tw.onHoldStartText then tw:onHoldStartText(nil, ges) end
        return true
    end
    input.ges_events.HoldPanTextBox = { GestureRange:new{ ges = "hold_pan", range = function() return input.dimen end } }
    input.onHoldPanTextBox = function(__, __, ges)
        local tw = textWidget()
        if tw and tw.onHoldPanText then tw:onHoldPanText(nil, ges) end
        return true
    end
    input.onHoldReleaseTextBox = function(__, __, ges)
        local tw = textWidget()
        if not (tw and tw.onHoldReleaseText) then return true end
        tw:onHoldReleaseText(function(text)
            if tw.clearHighlight and tw:clearHighlight() then tw:redrawHighlight() end
            if not text or not text:match("%S") then return end
            Device.input.setClipboardText(text)
            self:selectionDialog(text)
        end, ges)
        return true
    end
end

--- What was selected (already copied): Paste (at the prompt, without
-- Enter), Copy all (the whole screen), Copy and, with an AI, Ask AI.
function Session:selectionDialog(txt)
    local ai = require("sshai").available()
    local function paste()
        local clip = Device.input.getClipboardText() or ""
        if clip ~= "" then self:transmit(clip) end
    end
    local function copyAll()
        Device.input.setClipboardText(table.concat(self.input.charlist or {}))
        KO.toast(_("Copied."))
    end
    -- The launcher's page (the keyboard hides while it shows), or KOReader's.
    local read = KO.read()
    if read then
        self.dialog:onCloseKeyboard()
        local function back() self.dialog:onShowKeyboard() end
        local buttons = {
            { icon = "arrow-down-to-line", text = _("Paste"), fn = function()
                paste()
                back()
            end },
            { icon = "copy", text = _("Copy all"), fn = function()
                copyAll()
                back()
            end },
            { icon = "check", text = _("Done"), primary = not ai, fn = back },
        }
        if ai then
            buttons[#buttons + 1] = { icon = "sparkles", text = _("Ask AI"), primary = true, aiJob = "ssh_session", fn = function()
                require("sshaichat").of(self):askBox{ selection = txt }
            end }
        end
        return read{ title = _("Copied"), subtitle = _("Selected text, now on the clipboard"), text = txt,
            buttons = buttons, onCancel = back }
    end
    KO.toast(_("Copied."))
    local viewer
    local row = {
        { text = _("Paste"), callback = function()
            UIManager:close(viewer)
            paste()
        end },
        { text = _("Copy all"), callback = function()
            UIManager:close(viewer)
            copyAll()
        end },
    }
    if ai then
        row[#row + 1] = { text = _("Ask AI"), callback = function()
            UIManager:close(viewer)
            require("sshaichat").of(self):askBox{ selection = txt }
        end }
    end
    viewer = require("ui/widget/textviewer"):new{
        title = _("Copied"),
        show_menu = false,
        text = txt,
        text_type = "code",
        width = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.8),
        height = math.floor(math.max(Device.screen:getWidth(), Device.screen:getHeight()) * 0.4),
        justified = false,
        modal = true,
        stop_events_propagation = true,
        buttons_table = { row },
    }
    UIManager:show(viewer)
end

-- The keys and key combinations of Keys, named for what they do (the
-- arrows as the terminal, a VT52, sends them).
local function ctrl(ch) return string.char(ch:upper():byte() - 64) end
local ESC = string.char(27)
Session.KEYS = {
    { _("Stop what's running (Ctrl-C)"), ctrl("c") },
    { _("Log out, or end the input (Ctrl-D)"), ctrl("d") },
    { _("Pause it (Ctrl-Z); fg goes on"), ctrl("z") },
    { _("Clear the screen (Ctrl-L)"), ctrl("l") },
    { _("Search earlier commands (Ctrl-R)"), ctrl("r") },
    { _("↑  The command before"), ESC .. "A" },
    { _("↓  The command after"), ESC .. "B" },
    { _("←  Left"), ESC .. "D" },
    { _("→  Right"), ESC .. "C" },
    { _("Start of the line (Ctrl-A)"), ctrl("a") },
    { _("End of the line (Ctrl-E)"), ctrl("e") },
    { _("Delete the line (Ctrl-U)"), ctrl("u") },
    { _("Quit a pager: less, man (q)"), "q" },
    { _("nano: Save (Ctrl-O, then Enter)"), ctrl("o") },
    { _("nano: Exit (Ctrl-X)"), ctrl("x") },
    { _("nano: Find (Ctrl-W)"), ctrl("w") },
    { _("nano: Cut the line (Ctrl-K)"), ctrl("k") },
    { _("nano: Paste (Ctrl-U)"), ctrl("u") },
    { _("vi: Save and quit (Esc :wq)"), ESC .. ":wq\r" },
    { _("vi: Quit without saving (Esc :q!)"), ESC .. ":q!\r" },
}

--- Keys: a key or combination, by what it does; sent at once.
function Session:keysMenu()
    self.dialog:onCloseKeyboard()
    local function back()
        self.dialog:onShowKeyboard()
        UIManager:setDirty(self.dialog, "ui")
    end
    local items = {}
    for __, k in ipairs(Session.KEYS) do
        items[#items + 1] = { text = k[1], fn = function()
            self:transmit(k[2])
            back()
        end }
    end
    items[#items + 1] = { text = Dark.isOn() and _("Dark terminal: On") or _("Dark terminal: Off"), fn = function()
        self:toggleDark()
        back()
    end }
    KO.list(_("Keys"), items, back)
end

--- Edit: a file on this host in the Kindle's editor (Save writes it back,
-- with sudo when it needs it), instead of nano, which this terminal can't
-- draw well.
function Session:editFile()
    self.dialog:onCloseKeyboard()
    local function back()
        self.dialog:onShowKeyboard()
        UIManager:setDirty(self.dialog, "ui")
    end
    local Screens = require("sshscreens")
    local function open(path)
        Screens.editFile(self.plugin, self.host, path, self.password or false, nil, back)
    end
    local request = KO.request()
    if request then
        return request{ title = _("Edit a file"), subtitle = M.hostName(self.host), hint = "/etc/hosts",
            text = self.lastEdited or "", typing = true, buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = "folder", text = _("Files"), fn = function()
                    Screens.files(self.plugin, self.host)
                end },
                { icon = "pencil", text = _("Edit"), primary = true, needsText = true, fn = function(path)
                    self.lastEdited = path
                    open(path)
                end },
            }, onCancel = back }
    end
    require("sshui").h.ask(_("Edit a file"), self.lastEdited or "", function(path)
        if not path:match("%S") then return back() end
        self.lastEdited = path
        open(path)
    end, { ok = _("Edit") })
end

--- Ctrl held for the next key (tap it again to let go): the button shows
-- black while held.
function Session:setCtrl(on)
    self.ctrl = on
    local btn = self.dialog and self.dialog.button_table and self.dialog.button_table:getButtonById("ctrl")
    if not btn then return end
    -- (after the tap's own flash, which ends with the button white again)
    UIManager:scheduleIn(0.3, function()
        btn.frame.invert = self.ctrl
        UIManager:setDirty(self.dialog, "ui", btn.dimen)
    end)
end

--- Dark terminal on or off (the same as SSH settings' Dark terminal), at once:
-- the last entry in Keys.
function Session:toggleDark()
    Dark.set(not Dark.isOn())
    UIManager:setDirty("all", "full")
end

--- ✕: Disconnect? (closes at once when it has ended)
function Session:askDisconnect(after)
    if not self.open then
        self:close()
        if after then after() end
        return
    end
    -- The keyboard goes while asking: it stays above other dialogs, and
    -- taps on them reach the buttons under it.
    self.dialog:onCloseKeyboard()
    local function back() self.dialog:onShowKeyboard() end
    KO.confirm{
        text = _("Disconnect?"),
        ok = _("Disconnect"),
        onOk = function()
            self:close()
            if after then after() end
        end,
        onCancel = back,
    }
end

function Session:makeDialog(TermInputText)
    local dialog
    -- The keys, as one more row of the keyboard (plain labels, the keyboard's font), right
    -- above it.
    local keys = {
        { text = "↹", callback = function() self:transmit("\009") end },
        { text = _("Esc"), callback = function() self:transmit("\027") end },
        { text = _("Ctrl"), id = "ctrl", callback = function() self:setCtrl(not self.ctrl) end },
        { text = _("Ctrl-C"), callback = function()
            self:transmit("\003")
            if self.ptmx then C.tcflush(self.ptmx, C.TCIFLUSH) end
        end },
        { text = "↑", callback = function() self.input:upLine() end,
            hold_callback = function() self.input:scrollUp() end },
        { text = "↓", callback = function() self.input:downLine() end,
            hold_callback = function() self.input:scrollDown() end },
    }
    -- (a firm pen press lasts long enough to be a hold: it taps too)
    for __, b in ipairs(keys) do
        if not b.hold_callback then b.hold_callback = b.callback end
        b.font_face, b.font_size, b.font_bold = "infont", KEY_FONT, false
    end
    -- What opens something: the apps' icon buttons, between the terminal and the keys.
    local actions = {
        { icon = "keyboard", text = _("Keys"), fn = function() self:keysMenu() end },
        { icon = "terminal", text = _("Commands"), fn = function() self:pickCommand() end },
        { icon = "pencil", text = _("Edit"), fn = function() self:editFile() end },
    }
    if require("sshai").available() then
        -- tap: the AI chat; hold: AI for this (which service and model the chat uses)
        actions[#actions + 1] = { icon = "sparkles", text = _("AI"), aiJob = "ssh_session", fn = function() self:aiMenu() end }
    else
        actions[#actions + 1] = { icon = "clipboard-paste", text = _("Paste"), fn = function()
            local clip = Device.input.getClipboardText() or ""
            if clip ~= "" then self:transmit(clip) end
        end }
    end
    actions[#actions + 1] = { icon = "x", text = _("Disconnect"), fn = function() self:askDisconnect() end }
    -- KOReader's dialog with the apps' title bar (‹ and ⌂ ask Disconnect? first)
    dialog = require("sshbar").dialogClass():new{
        bar_opts = {
            on_back = function() self:askDisconnect() end,
            on_home = function() self:askDisconnect(function() require("sshui").home() end) end,
            on_refresh = function() UIManager:setDirty("all", "full") end,
            on_menu = function() require("sshui").more() end,
        },
        title = T(_("%1 (%2)"), M.hostName(self.host), M.hostLabel(self.host)),
        input = "",
        input_face = self.face,
        para_direction_rtl = false,
        input_type = "string",
        allow_newline = false,
        cursor_at_end = true,
        fullscreen = true,
        -- the terminal as big as it can be: a thin border, and no gaps around it
        condensed = true,
        input_margin = Size.margin.default,
        input_padding = Size.padding.default,
        inputtext_class = TermInputText:extend{ bordersize = Size.border.default },
        buttons = { keys },
        del_word_callback = function() self:transmit("\023") end,
        enter_callback = function() self:transmit("\r") end,
        strike_callback = function(chars)
            if self.ctrl and #chars == 1 then
                local n = chars:upper():byte() - ("A"):byte() + 1
                if n >= 0 then chars = string.char(n) end
                self:setCtrl(false)
            end
            if chars == "\n" then chars = "\r" end
            self:transmit(chars)
        end,
    }
    -- (KOReader's dialog makes the terminal shorter for it, and keeps it when it lays
    -- itself out again with the keyboard shown or hidden)
    local u = math.min(Device.screen:getWidth(), Device.screen:getHeight()) / 620
    dialog:addWidget(require("sshbuttons"):new{ width = dialog.width, bare = true,
        height = math.floor(76 * u + 0.5), show_parent = dialog, buttons = actions })
    return dialog
end

return Session
