--[[--
PROBE (log only, to be removed once a Kindle has answered): is the pen's side
button seen as held by Pen.held (EVIOCGKEY) when a selection is made in a book?
It changes nothing. To remove it: delete this file, its line in
noteshandnote.lua's highlight menu, Notes:handProbeCheck there, and the
"Notes: pen button check (test)" menu item in main.lua.

The line in KOReader's crash.log:
    Notes probe: side button held=true|false tool=pen|rubber|none touching=true|false (<when>) <device>
]]

local Probe = {}

--- The pen's buttons now, logged with `when` (what asked). Returns the line and what was read.
function Probe.log(when)
    local held, why = require("notespen").held()
    local line
    if held then
        line = string.format("Notes probe: side button held=%s tool=%s touching=%s (%s) %s",
            tostring(held.side), held.tool or "none", tostring(held.touching), when, held.path)
    else
        line = string.format("Notes probe: cannot ask the pen (%s) (%s)", tostring(why), when)
    end
    require("logger").warn(line)
    return line, held
end

return Probe
