--[[--
AI help, with the launcher's AI (PS.ai, Settings > AI): Explain and
Summarize a command's output, Write a command from a description, and Ask
more about the same output. (The live session's AI chat is sshaichat.lua;
its feature, "session", is registered here with the others.)

Nothing runs by itself: a suggested command has Run (which asks first),
Edit (the command box) and Save (as a saved command). Run offers a live
session (so sudo can ask for its password there) or a run once. The AI never
types anything itself: only your tap and the confirm do. Obvious secrets are blanked before anything is sent
(M.redact, with the saved passwords). SSH's job ("ssh") is in Settings > AI
> Which AI does each job (any service: your local AI or a public one), and
each feature in Advanced (its wording, Reset, Preview). Without an AI set
up, the AI buttons don't show.
]]

local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local KO = require("sshko")
local M = require("sshmodel")

local A = {}

A.JOB = "ssh"

-- Before a suggested command runs.
A.RISK = _("AI suggestions can be wrong. Run this only if you understand what it does. You run it at your own risk.")

local function PS() return require("pluginshare") end

-- (the launcher's AI, or nil without it)
local function ai() return PS().ai end

local AMOUNT_LINES = { "lines", _("The last 200 lines") }
local AMOUNT_ALL = { "all", _("All of it (up to 30 KB)") }
local ABOUT_OUTPUT = "Below is what a command printed over SSH on a computer running %s (the command first, when known). "
    .. "Secrets in it are blanked as [hidden]. "
local COMMAND_LINES = " Answer in plain text (no tables). Put each command you suggest on a line of its own that starts "
    .. "with COMMAND: (at most 3; none when no command is needed).\n\n"

-- Each feature as Settings > AI > Advanced shows it: intro (fixed), words
-- (yours to change), format (fixed: the answer's form SSH reads).
A.FEATURES = {
    explain = { key = "ssh_explain", name = _("SSH: Explain output"), job = A.JOB, app = "sshclient",
        intro = ABOUT_OUTPUT,
        words = "Explain briefly what it means. If something went wrong, say why and what to try next. "
            .. "Keep it short: it is read on an e-ink Kindle.",
        format = COMMAND_LINES,
        amounts = { AMOUNT_LINES, AMOUNT_ALL }, args = { "Debian/Ubuntu" },
        without = _("With the command and its output (secrets blanked).") },
    summary = { key = "ssh_summary", name = _("SSH: Summarize output"), job = A.JOB, app = "sshclient",
        intro = ABOUT_OUTPUT,
        words = "Summarize it down to what matters: problems and warnings first, then a short overview of the rest. "
            .. "Keep it short: it is read on an e-ink Kindle.",
        format = COMMAND_LINES,
        amounts = { AMOUNT_ALL, AMOUNT_LINES }, args = { "Debian/Ubuntu" },
        without = _("With the command and its output (secrets blanked).") },
    write = { key = "ssh_write", name = _("SSH: Write a command"), job = A.JOB, app = "sshclient",
        intro = "Write a shell command for a computer running %s that I reach over SSH. It runs without a terminal, "
            .. "so no prompts or full-screen programs. ",
        words = "Prefer a safe, read-only command; if it changes anything, say so. Say in one or two sentences what it does.",
        format = " Put the command on a line of its own that starts with COMMAND: (one command; a second only when "
            .. "there is a real alternative). What I want: ",
        args = { "Debian/Ubuntu" },
        without = _("With your description (secrets blanked).") },
    -- the live session's AI chat (sshaichat.lua): each question with what the
    -- terminal shows and the conversation so far
    session = { key = "ssh_session", name = _("SSH: Live session chat"), job = A.JOB, app = "sshclient",
        intro = "I'm in a live SSH session (a terminal) on a computer running %s. Below is what the terminal shows now "
            .. "(secrets in it are blanked as [hidden]), then our conversation so far and my question. ",
        words = "Answer briefly and plainly: it is read on an e-ink Kindle. When a command helps, suggest it; "
            .. "prefer safe ones, and say when one changes something.",
        format = " Answer in plain text (no tables). Put each command you suggest on a line of its own that starts "
            .. "with COMMAND: (at most 3; none when no command is needed). I type a command in myself.\n\n",
        amounts = { { "short", _("The last 50 lines") }, AMOUNT_LINES, AMOUNT_ALL }, args = { "Debian/Ubuntu" },
        without = _("With what the terminal shows (secrets blanked) and the conversation so far.") },
}

A.ORDER = { "explain", "summary", "write", "session" }

--- SSH's job and features in Settings > AI (only kept in lists: works
-- whichever plugin loads first).
function A.register()
    local P = PS()
    local job = { key = A.JOB, name = _("SSH: explain output, write commands"), app = "sshclient", order = 60 }
    if P.ai and P.ai.registerJob then
        P.ai.registerJob(job)
        for __, k in ipairs(A.ORDER) do P.ai.registerFeature(A.FEATURES[k]) end
        return
    end
    P.aiJobs, P.aiFeatures = P.aiJobs or {}, P.aiFeatures or {}
    P.aiJobs[A.JOB] = job
    for __, k in ipairs(A.ORDER) do
        local f, there = A.FEATURES[k], false
        for __, x in ipairs(P.aiFeatures) do there = there or x.key == f.key end
        if not there then table.insert(P.aiFeatures, f) end
    end
end

--- Whether to show the AI buttons: an AI service is set up.
function A.available()
    local x = ai()
    return x ~= nil and x.configured ~= nil and x.configured() == true
end

--- A host's system for the instructions.
function A.system(host)
    local id = host and M.hostOS(host)
    if id == "linux" then return "Linux" end
    if id then return M.osName(id) end
    return host and "an unknown system (probably Linux)" or "several systems"
end

--- The saved passwords (blanked wherever they show).
function A.secrets(plugin)
    local out = {}
    for __, h in ipairs(plugin.store.data.hosts) do
        if type(h.password) == "string" and h.password ~= "" then out[#out + 1] = h.password end
    end
    return out
end

--- How much of the output a feature sends ("lines" or "all").
function A.amount(kind)
    local x = ai()
    return x and x.amount and x.amount(A.FEATURES[kind].key) or "lines"
end

--- Sends text for a feature; done(answer), or a problem shown and then
-- failed() (optional). `system`: the intro's value.
function A.ask(kind, system, text, done, failed)
    local x = ai()
    if not x then return KO.message(_("The AI needs the Apps launcher (apps.koplugin)."), nil, failed) end
    if not x.readyFor(A.JOB) then
        return KO.confirm{ text = x.notReadyText(A.JOB), ok = _("AI settings"),
            onOk = function() x.showSettings() end, onCancel = failed }
    end
    x.ask(A.FEATURES[kind].key, { text = text, wait = _("Asking…"), args = { system } }, function(answer, why)
        if not answer or not answer:match("%S") then
            return KO.message(why and tostring(why) or _("No answer came."), _("AI"), failed)
        end
        done(answer)
    end)
end

-- ------------------------------------------------------------------ the answer

local function hostName(h) return M.hostName(h) end

--- One of the suggested commands: the only one, or picked from a list.
local function pickCommand(cmds, cb)
    if #cmds == 1 then return cb(cmds[1]) end
    local items = {}
    for __, c in ipairs(cmds) do items[#items + 1] = { text = c, fn = function() cb(c) end } end
    KO.list(_("Which command?"), items)
end

--- The host to run on: the one it came from, or picked.
local function pickHost(plugin, ctx, cb)
    if ctx.host then return cb(ctx.host) end
    local items = {}
    for __, h in ipairs(ctx.hosts or plugin.store.data.hosts) do
        items[#items + 1] = { text = hostName(h), fn = function() cb(h) end }
    end
    if #items == 0 then return KO.message(_("Add a host first.")) end
    KO.list(_("Run on a host"), items)
end

--- The AI's answer, with Ask more and Copy all, and Run, Edit and Save as
-- command when it suggests commands. ctx: { host, hosts, title, system,
-- onClose }; kind: the feature; first: what was sent first; turns: the
-- follow-ups so far ({ answer, question }).
function A.showAnswer(plugin, ctx, kind, first, turns, answer)
    local Run = require("sshrun")
    local UI = require("sshui")
    local cmds, shown = M.aiCommands(answer)
    local viewer
    local replaced = false
    local function run(cmd)
        pickHost(plugin, ctx, function(h)
            -- In a live session (it can answer sudo's password) or once (the
            -- output page); with sudo, the live session first.
            local live = { text = _("Run in a live session"), fn = function()
                KO.confirm{ title = T(_("Run on %1 in a live session?"), hostName(h)), ok = _("Run"),
                    text = cmd .. "\n\n" .. A.RISK, onOk = function() UI.session(plugin, h, cmd) end }
            end }
            local sudo = M.usesSudo(cmd)
            local once = { text = sudo and _("Run once (needs passwordless sudo)") or _("Run once"), fn = function()
                KO.confirm{ title = T(_("Run on %1?"), hostName(h)), ok = _("Run"),
                    text = cmd .. "\n\n" .. A.RISK, onOk = function() Run.command(plugin, h, cmd) end }
            end }
            KO.list(T(_("Run on %1"), hostName(h)), sudo and { live, once } or { once, live })
        end)
    end
    local function edit(cmd)
        pickHost(plugin, ctx, function(h)
            UI.runDialog(plugin, h, cmd, function(c) Run.command(plugin, h, c) end)
        end)
    end
    local function save(cmd)
        -- on its host (one of its saved commands), or in the command list (a
        -- custom command for every host)
        local function to(h)
            UI.editCommand({ name = "", cmd = cmd }, function(__, name, c, os_id)
                local list = h and h.commands or plugin.store.data.commands
                table.insert(list, { id = M.newId(plugin.store.data, "c"), name = name, cmd = c, os = os_id })
                plugin:saved()
                if h then UI.refreshHost(plugin, h) end
                KO.toast(h and T(_("Saved on %1."), hostName(h)) or _("Saved in the command list."))
            end, false, _("Save as command"))
        end
        local items = {}
        if ctx.host then
            items[#items + 1] = { text = T(_("On %1"), hostName(ctx.host)), fn = function() to(ctx.host) end }
        end
        items[#items + 1] = { text = _("In the command list (every host)"), fn = function() to(nil) end }
        if #items == 1 then return to(nil) end
        KO.list(_("Save as command"), items)
    end
    local closeAnswer
    local function followUp(q)
        local next_turns = {}
        for i, t in ipairs(turns or {}) do next_turns[i] = t end
        next_turns[#next_turns + 1] = { answer = answer, question = q }
        A.ask(kind, ctx.system, M.aiFollowUp(first, next_turns, A.secrets(plugin)), function(a)
            replaced = true
            closeAnswer()
            A.showAnswer(plugin, ctx, kind, first, next_turns, a)
        end)
    end
    local function askMore()
        A.textBox{ title = _("Ask more"), hint = _("That didn't work; it says…"), aiJob = A.FEATURES[kind].key, send = followUp }
    end
    local function copyAll()
        require("device").input.setClipboardText(shown)
        KO.toast(_("Copied."))
    end
    local x = ai()
    local text = shown .. "\n\n" .. T(_("(Answered by %1. Check a command before you run it.)"), x and x.jobName(A.JOB) or _("AI"))
    -- The launcher's page: in pages, one row of icon buttons; they leave
    -- the answer open under what they open (Done closes it).
    local read = KO.read()
    if read then
        local buttons
        if #cmds > 0 then
            buttons = {
                { icon = "terminal", text = _("Run"), primary = true, keep = true, fn = function() pickCommand(cmds, run) end },
                { icon = "pencil", text = _("Edit"), keep = true, fn = function() pickCommand(cmds, edit) end },
                { icon = "download", text = _("Save"), keep = true, fn = function() pickCommand(cmds, save) end },
                { icon = "send", text = _("Ask more"), keep = true, aiJob = A.FEATURES[kind].key, fn = askMore },
                { icon = "copy", text = _("Copy all"), keep = true, fn = copyAll },
            }
        else
            buttons = {
                { icon = "send", text = _("Ask more"), keep = true, aiJob = A.FEATURES[kind].key, fn = askMore },
                { icon = "copy", text = _("Copy all"), keep = true, fn = copyAll },
                { icon = "check", text = _("Done"), primary = true },
            }
        end
        local box = read{ title = ctx.title, text = text, buttons = buttons, onCancel = function()
            if not replaced and ctx.onClose then ctx.onClose() end
        end }
        closeAnswer = function() if box and box.close then box:close() end end
        return
    end
    -- KOReader's TextViewer: rows of the same number of buttons, so they line
    -- up (instead of its own row under ours); Find isn't needed in a short answer.
    local ask = { text = _("Ask more"), callback = askMore }
    local copy = { text = _("Copy all"), callback = copyAll }
    local top = { text = "⇱", id = "top", callback = function() viewer.scroll_widget:scrollToTop() end }
    local bottom = { text = "⇲", id = "bottom", callback = function() viewer.scroll_widget:scrollToBottom() end }
    local close = { text = _("Close"), callback = function() viewer:onClose() end }
    local rows
    if #cmds > 0 then
        rows = {
            { { text = _("Run"), callback = function() pickCommand(cmds, run) end },
                { text = _("Edit"), callback = function() pickCommand(cmds, edit) end },
                { text = _("Save"), callback = function() pickCommand(cmds, save) end },
                ask },
            { copy, top, bottom, close },
        }
    else
        rows = { { ask, copy, top, bottom, close } }
    end
    viewer = TextViewer:new{
        title = ctx.title,
        text = text,
        add_default_buttons = false,
        buttons_table = rows,
        close_callback = function()
            if not replaced and ctx.onClose then ctx.onClose() end
        end,
    }
    closeAnswer = function() viewer:onClose() end
    UIManager:show(viewer)
end

--- A question box: the launcher's (a pen for handwriting; examples), or
-- KOReader's with Write it. o: { title, subtitle, hint, examples, send(text),
-- cancel() }.
function A.textBox(o)
    local request = KO.request()
    if request then
        local items = {}
        for __, e in ipairs(o.examples or {}) do items[#items + 1] = { text = e, fn = function(box) box:setText(e) end } end
        return request{ title = o.title, subtitle = o.subtitle, hint = o.hint, pen = KO.pen(), penTitle = o.title,
            penKind = "text", typing = true,
            sections = #items > 0 and { { heading = _("EXAMPLES"), items = items } } or nil,
            buttons = {
                { icon = "x", text = _("Cancel"), cancel = true },
                { icon = "send", text = _("Answer"), primary = true, needsText = true, aiJob = o.aiJob, fn = function(t) o.send(t) end },
            },
            onCancel = o.cancel }
    end
    local dialog
    local row = {
        { text = _("Cancel"), id = "close", callback = function()
            UIManager:close(dialog)
            if o.cancel then o.cancel() end
        end },
        { text = _("Answer"), is_enter_default = true, callback = function()
            local q = dialog:getInputText()
            if not q:match("%S") then return end
            UIManager:close(dialog)
            o.send(q)
        end },
    }
    KO.withWrite(row, function() return dialog end, "text")
    dialog = InputDialog:new{ title = o.title, input = "", input_hint = o.hint, description = o.subtitle, buttons = { row } }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ------------------------------------------------------------------ the features

--- Explain ("explain") or Summarize ("summary") output. ctx: { host, hosts,
-- cmd, output, onClose }.
function A.output(plugin, kind, ctx)
    ctx.system = ctx.system or A.system(ctx.host)
    ctx.title = kind == "summary" and _("Summary") or _("Explanation")
    local first = M.aiOutputText(ctx.cmd, ctx.output, A.amount(kind), A.secrets(plugin))
    A.ask(kind, ctx.system, first, function(answer)
        A.showAnswer(plugin, ctx, kind, first, {}, answer)
    end, ctx.onClose)
end

--- Write a command: what you want, typed or written; the AI's command to
-- run, edit or save. ctx: { host, onClose }.
function A.write(plugin, ctx)
    ctx.system = ctx.system or A.system(ctx.host)
    ctx.title = _("Suggested command")
    A.textBox{
        title = _("Write a command"),
        subtitle = ctx.host and T(_("For %1 (%2)."), hostName(ctx.host), ctx.system) or nil,
        hint = _("Show the 10 largest folders in /var"),
        aiJob = "ssh_write",
        examples = { _("How do I check disk space?"), _("Show the 10 largest folders in /var"),
            _("Which services failed to start?") },
        send = function(want)
            local first = (M.redact(want, A.secrets(plugin)))
            A.ask("write", ctx.system, first, function(answer)
                A.showAnswer(plugin, ctx, "write", first, {}, answer)
            end, ctx.onClose)
        end,
        cancel = ctx.onClose,
    }
end

return A
