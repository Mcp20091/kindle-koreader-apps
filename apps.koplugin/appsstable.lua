--[[--
Stable lists: after a change made in place (a task ticked or starred, a device
switched, a book's status), a list that sorts its rows keeps every row where it
was, each up to date, until the screen is left or refreshed. Plain Lua, no
KOReader modules; published as PS.stable (main.lua).

`state` is any table that lives as long as the screen (its view):
- mark(state): the next draws keep the rows where they are.
- clear(state): the next draw sorts again (leaving, Back, Refresh screen, Sync
  now, an item added or removed).
- order(state, sections, opts): the sections to draw, { { ..., entries = {...} } }.
  opts: `on` (false: always as sorted, and the mark is dropped), `id(entry)`
  (default entry.id), `fresh(entry)` (the entry up to date, or nil when it's
  gone; default the entry as it was), `name` (which list, when a screen has
  several; default 1).
- list(state, entries, opts): the same for a plain list.
]]

local Stable = {}

function Stable.mark(state)
    if type(state) == "table" then state.stable_keep = true end
end

function Stable.clear(state)
    if type(state) == "table" then
        state.stable_keep = nil
        state.stable_layout = nil
    end
end

--- The sections to draw: as sorted, or (marked, with a layout from the last
-- draw) that layout with each entry up to date, gone ones dropped, and new
-- ones after the rest. Whatever is returned is the layout next time.
function Stable.order(state, sections, opts)
    opts = opts or {}
    if type(state) ~= "table" then return sections end
    local name = opts.name or 1
    if opts.on == false then
        Stable.clear(state)
        return sections
    end
    local id = opts.id or function(e) return e.id end
    local fresh = opts.fresh or function(e) return e end
    state.stable_layout = state.stable_layout or {}
    local before = state.stable_layout[name]
    if not (state.stable_keep and before) then
        state.stable_layout[name] = sections
        return sections
    end
    local out, seen = {}, {}
    for __, sec in ipairs(before) do
        local copy = {}
        for k, v in pairs(sec) do copy[k] = v end
        copy.entries = {}
        for __, e in ipairs(sec.entries or {}) do
            local now = fresh(e)
            if now ~= nil then
                seen[id(now)] = true
                table.insert(copy.entries, now)
            end
        end
        if #copy.entries > 0 then table.insert(out, copy) end
    end
    -- New items: after the rest, each in a copy of the section it's in now.
    for __, sec in ipairs(sections) do
        local copy
        for __, e in ipairs(sec.entries or {}) do
            if not seen[id(e)] then
                seen[id(e)] = true
                if not copy then
                    copy = {}
                    for k, v in pairs(sec) do copy[k] = v end
                    copy.entries = {}
                    table.insert(out, copy)
                end
                table.insert(copy.entries, e)
            end
        end
    end
    state.stable_layout[name] = out
    return out
end

--- Stable.order for a plain list of entries.
function Stable.list(state, entries, opts)
    local out = {}
    for __, sec in ipairs(Stable.order(state, { { entries = entries } }, opts)) do
        for __, e in ipairs(sec.entries) do table.insert(out, e) end
    end
    return out
end

return Stable
