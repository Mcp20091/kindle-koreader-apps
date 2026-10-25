-- A small JSON encoder and decoder for the tests (KOReader has its own).
local json = {}

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function isArray(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n == #t
end

function json.encode(v)
    local kind = type(v)
    if kind == "nil" or kind == "function" then return "null" end
    if kind == "boolean" then return tostring(v) end
    if kind == "number" then return string.format("%.14g", v) end
    if kind == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c) return escapes[c] or string.format("\\u%04x", c:byte()) end) .. '"'
    end
    local parts = {}
    if next(v) ~= nil and isArray(v) or next(v) == nil then
        for _, item in ipairs(v) do table.insert(parts, json.encode(item)) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do table.insert(keys, k) end
    table.sort(keys)
    for _, k in ipairs(keys) do table.insert(parts, json.encode(tostring(k)) .. ":" .. json.encode(v[k])) end
    return "{" .. table.concat(parts, ",") .. "}"
end

function json.decode(s)
    local pos = 1
    local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
    local value
    local function str()
        local out = {}
        pos = pos + 1
        while true do
            local c = s:sub(pos, pos)
            if c == '"' then pos = pos + 1 break end
            if c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if e == "u" then
                    local code = tonumber(s:sub(pos + 2, pos + 5), 16)
                    if code < 0x80 then table.insert(out, string.char(code))
                    elseif code < 0x800 then table.insert(out, string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64))
                    else table.insert(out, string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)) end
                    pos = pos + 6
                else
                    table.insert(out, map[e] or e)
                    pos = pos + 2
                end
            else
                table.insert(out, c)
                pos = pos + 1
            end
        end
        return table.concat(out)
    end
    function value()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            local t = {}
            pos = pos + 1
            ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
            while true do
                ws()
                local k = str()
                ws()
                pos = pos + 1  -- :
                t[k] = value()
                ws()
                local sep = s:sub(pos, pos)
                pos = pos + 1
                if sep == "}" then return t end
            end
        elseif c == "[" then
            local t = {}
            pos = pos + 1
            ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
            while true do
                table.insert(t, value())
                ws()
                local sep = s:sub(pos, pos)
                pos = pos + 1
                if sep == "]" then return t end
            end
        elseif c == '"' then
            return str()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            pos = pos + #num
            return tonumber(num)
        end
    end
    return value()
end

return json
