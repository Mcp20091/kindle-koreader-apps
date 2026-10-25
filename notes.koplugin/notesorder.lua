--[[--
Moving one thing in an ordered list (the reorder screen's arrows). Plain
Lua, for the tests.

@module koplugin.notes.order
]]

local Order = {}

--- `keys` with `key` moved by `delta` places (clamped to the ends: a big
-- delta is "to the top" or "to the bottom"). A new list; nil when it
-- didn't move.
function Order.move(keys, key, delta)
    local at
    for i, k in ipairs(keys) do
        if k == key then at = i end
    end
    if not at then return nil end
    local to = math.max(1, math.min(#keys, at + delta))
    if to == at then return nil end
    local out = {}
    for i, k in ipairs(keys) do out[i] = k end
    table.remove(out, at)
    table.insert(out, to, key)
    return out
end

return Order
