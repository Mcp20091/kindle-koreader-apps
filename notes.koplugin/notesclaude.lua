--[[--
Notes' instructions for the AI: reading handwriting (in three parts: what it
is, the wording you can change in Settings > AI > Advanced, the answer's
form), and listing the to-do items on a page (with the dates written beside
them), read back as tasks. The requests themselves are the launcher's
(apps.koplugin/appsaiclient.lua, through PS.ai).

Plain Lua, so the tests run it without KOReader.
]]

local Claude = {}

-- Reading handwriting: what it is (fixed), how to write it (your wording,
-- Settings > AI > Advanced) and what to reply with (fixed).
Claude.READ_INTRO = "This is a page from a handwritten notebook. Transcribe the handwriting into plain text."
Claude.READ_WORDS = [[- Keep the writer's line breaks and order. Use Markdown only where the page clearly has it: headings, bullet or numbered lists, checkboxes ("- [ ]" / "- [x]"), tables.
- Write a word you cannot read as [?]; keep what you can read of it, like "Ord[?]".
- Mention drawings, diagrams and shapes briefly in square brackets, e.g. [drawing: box with an arrow to "Budget"].
- Ignore ruled lines, grid lines and dots of the paper.]]
Claude.READ_FORMAT = "Reply with the transcription only, nothing before or after it. If there is no writing, reply with an empty line."
Claude.PROMPT = Claude.READ_INTRO .. "\n" .. Claude.READ_WORDS .. "\n" .. Claude.READ_FORMAT

Claude.TASKS_PROMPT = [[This is handwriting from a notebook page (or part of one). List the to-do items on it.
- On a checklist page each line starts with a printed box; on a tasks page a line with a box at the margin is a task and a line with a smaller, indented box is a subtask (a step) of the task above it.
- On other pages, lines that read like things to do are tasks; lines indented under one, or under a heading that is itself a task, are its steps.
- A box with a tick, cross or fill, or a line struck through, is done.
- Leave out headings, dates and notes that are not things to do. Keep the writer's wording; fix only obvious misreadings.
Reply with JSON only, no other text: {"tasks":[{"title":"...","done":false,"steps":[{"title":"...","done":false}]}]}
If there are no to-do items, reply {"tasks":[]}.]]

-- Added to TASKS_PROMPT when dates written beside the items are wanted.
Claude.DATES_PROMPT = [[Dates: today is %s. When a date or time is written beside or under a task or step (e.g. "Fri", "tomorrow", "10/25", "due Mon", "3pm", "remind 9am Thu", a bell or clock drawn by it), take it out of the title and give it in the task:
- "due": the due date, "YYYY-MM-DD".
- "remind": a reminder, "YYYY-MM-DDTHH:MM" (24-hour clock). A time on its own is a reminder on the due date (today when there is none).
A date with a time ("Fri 9am") is both: due that day, reminder at that time. With "remind" or a bell written, it is only a reminder.
A date for a step goes to its task. Leave both out when nothing is written. Dates are in the future unless the writing clearly says otherwise.
Example: {"tasks":[{"title":"Call the vet","done":false,"due":"2026-10-24","remind":"2026-10-24T09:00","steps":[]}]}]]

--- The to-do items in a page image: { { title, done, steps = { { title,
-- done }... } }... }, or nil and why.
-- `today` ("Wednesday 2026-10-21"): dates written beside the items are read
-- too (task.due "YYYY-MM-DD", task.remind { date = "YYYY-MM-DD", minute }).
-- `client`: the launcher's (PS.ai.client("read")).
function Claude.tasks(client, png, today)
    local prompt = Claude.TASKS_PROMPT
    if today then prompt = prompt .. "\n" .. Claude.DATES_PROMPT:format(today) end
    local text, why = client:transcribe(png, prompt)
    if not text then return nil, why end
    return Claude.parseTasks(text, require("json"))
end

--- Claude's JSON answer as tasks (anything not a task left out).
function Claude.parseTasks(text, json)
    local body = text:match("^```%w*%s*(.-)%s*```$") or text
    body = body:match("{.*}") or body
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" or type(data.tasks) ~= "table" then
        return nil, "Claude's answer could not be read as tasks."
    end
    local out = {}
    for _, t in ipairs(data.tasks) do
        if type(t) == "table" and type(t.title) == "string" and t.title:match("%S") then
            local task = { title = t.title:match("^%s*(.-)%s*$"), done = t.done == true, steps = {} }
            if type(t.due) == "string" then task.due = t.due:match("^%s*(%d%d%d%d%-%d%d%-%d%d)") end
            if type(t.remind) == "string" then
                local date, h, m = t.remind:match("^%s*(%d%d%d%d%-%d%d%-%d%d)[T ]?(%d?%d?):?(%d?%d?)")
                if date then
                    local hour, min = tonumber(h), tonumber(m)
                    if not hour or hour > 23 or (min and min > 59) then hour, min = 9, 0 end
                    task.remind = { date = date, minute = hour * 60 + (min or 0) }
                end
            end
            for _, st in ipairs(type(t.steps) == "table" and t.steps or {}) do
                if type(st) == "table" and type(st.title) == "string" and st.title:match("%S") then
                    table.insert(task.steps, { title = st.title:match("^%s*(.-)%s*$"), done = st.done == true })
                end
            end
            table.insert(out, task)
        end
    end
    return out
end

return Claude
