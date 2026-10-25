--[[--
SSH key files in plain Lua (tested): base64, the SSH wire format, reading
OpenSSH private keys (`-----BEGIN OPENSSH PRIVATE KEY-----`, no passphrase)
and writing them in Dropbear's own format, which is the only one KOReader's
dbclient reads. Also the public key line ("ssh-ed25519 AAAA… name") of a
Dropbear key, for the device's authorized_keys.

Ed25519, RSA and ECDSA (nistp256/384/521) keys are handled.
]]

local bit = require("bit")

local K = {}

-- ------------------------------------------------------------------ base64

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, 64 do B64_INDEX[B64:byte(i)] = i - 1 end

function K.base64(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = bit.bor(bit.lshift(a, 16), bit.lshift(b or 0, 8), c or 0)
        local q = {
            B64:sub(bit.rshift(n, 18) + 1, bit.rshift(n, 18) + 1),
            B64:sub(bit.band(bit.rshift(n, 12), 63) + 1, bit.band(bit.rshift(n, 12), 63) + 1),
            b and B64:sub(bit.band(bit.rshift(n, 6), 63) + 1, bit.band(bit.rshift(n, 6), 63) + 1) or "=",
            c and B64:sub(bit.band(n, 63) + 1, bit.band(n, 63) + 1) or "=",
        }
        out[#out + 1] = table.concat(q)
    end
    return table.concat(out)
end

--- Decodes base64 (whitespace is skipped); nil when it isn't base64.
function K.unbase64(s)
    s = s:gsub("%s", "")
    if #s % 4 ~= 0 then return nil end
    local out = {}
    for i = 1, #s, 4 do
        local n, pad = 0, 0
        for j = 0, 3 do
            local ch = s:byte(i + j)
            local v
            if ch == 61 then -- "="
                v, pad = 0, pad + 1
            else
                if pad > 0 then return nil end
                v = B64_INDEX[ch]
                if not v then return nil end
            end
            n = bit.bor(bit.lshift(n, 6), v)
        end
        local bytes = string.char(bit.band(bit.rshift(n, 16), 255), bit.band(bit.rshift(n, 8), 255), bit.band(n, 255))
        out[#out + 1] = bytes:sub(1, 3 - pad)
    end
    return table.concat(out)
end

-- ------------------------------------------------------------------ wire format

local function u32(n)
    return string.char(bit.band(bit.rshift(n, 24), 255), bit.band(bit.rshift(n, 16), 255),
        bit.band(bit.rshift(n, 8), 255), bit.band(n, 255))
end

--- An SSH "string": its length (4 bytes) and the bytes.
function K.str(s) return u32(#s) .. s end

--- A reader over SSH wire data: r:u32(), r:str(); nil past the end.
function K.reader(data)
    local pos = 1
    local r = {}
    function r.u32()
        if pos + 3 > #data then return nil end
        local a, b, c, d = data:byte(pos, pos + 3)
        pos = pos + 4
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    function r.str()
        local n = r.u32()
        if not n or pos + n - 1 > #data then return nil end
        local s = data:sub(pos, pos + n - 1)
        pos = pos + n
        return s
    end
    function r.rest() return data:sub(pos) end
    return r
end

-- ------------------------------------------------------------------ key files

local OPENSSH_BEGIN = "-----BEGIN OPENSSH PRIVATE KEY-----"
local OPENSSH_END = "-----END OPENSSH PRIVATE KEY-----"

local ECDSA_CURVES = { ["ecdsa-sha2-nistp256"] = "nistp256", ["ecdsa-sha2-nistp384"] = "nistp384",
    ["ecdsa-sha2-nistp521"] = "nistp521" }

--- What kind of key file this text is: "openssh", "dropbear", "pem" (an
-- older PEM key: BEGIN RSA/EC/DSA PRIVATE KEY), "public" (a .pub file) or nil.
function K.kind(text)
    if type(text) ~= "string" then return nil end
    if text:find(OPENSSH_BEGIN, 1, true) then return "openssh" end
    if text:find("-----BEGIN [%u ]*PRIVATE KEY-----") then return "pem" end
    if text:match("^%s*ssh%-%S+ AAAA") or text:match("^%s*ecdsa%-%S+ AAAA") then return "public" end
    local r = K.reader(text)
    local t = r.str()
    if t and (t == "ssh-ed25519" or t == "ssh-rsa" or ECDSA_CURVES[t]) then return "dropbear" end
    return nil
end

--- Reads a Dropbear private key: { type, public = the public key blob } or
-- nil, why.
function K.readDropbear(data)
    local r = K.reader(data)
    local t = r.str()
    if t == "ssh-ed25519" then
        local kp = r.str()
        if not kp or #kp ~= 64 then return nil, "bad key" end
        return { type = t, public = K.str(t) .. K.str(kp:sub(33, 64)) }
    elseif t == "ssh-rsa" then
        local e, n = r.str(), r.str()
        local d, p, q = r.str(), r.str(), r.str()
        if not (e and n and d and p and q) then return nil, "bad key" end
        return { type = t, public = K.str(t) .. K.str(e) .. K.str(n) }
    elseif t and ECDSA_CURVES[t] then
        local curve, Q, d = r.str(), r.str(), r.str()
        if curve ~= ECDSA_CURVES[t] or not Q or not d then return nil, "bad key" end
        return { type = t, public = K.str(t) .. K.str(curve) .. K.str(Q) }
    end
    return nil, "not a key"
end

--- Reads an OpenSSH private key file's text into Dropbear's format:
-- { type, dropbear = the file's bytes, public = the public key blob,
-- comment } or nil, why ("passphrase", "unsupported", "bad key").
function K.fromOpenSSH(text)
    local a = text:find(OPENSSH_BEGIN, 1, true)
    local b = text:find(OPENSSH_END, 1, true)
    if not a or not b then return nil, "bad key" end
    local data = K.unbase64(text:sub(a + #OPENSSH_BEGIN, b - 1))
    if not data then return nil, "bad key" end
    local magic = "openssh-key-v1\0"
    if data:sub(1, #magic) ~= magic then return nil, "bad key" end
    local r = K.reader(data:sub(#magic + 1))
    local cipher, kdf = r.str(), r.str()
    r.str() -- kdf options
    local nkeys = r.u32()
    if not cipher or not kdf or not nkeys then return nil, "bad key" end
    if cipher ~= "none" or kdf ~= "none" then return nil, "passphrase" end
    if nkeys ~= 1 then return nil, "unsupported" end
    r.str() -- the public key
    local priv = r.str()
    if not priv then return nil, "bad key" end
    local p = K.reader(priv)
    local c1, c2 = p.u32(), p.u32()
    if not c1 or c1 ~= c2 then return nil, "bad key" end
    local t = p.str()
    local out
    if t == "ssh-ed25519" then
        local pub, kp = p.str(), p.str()
        if not pub or not kp or #pub ~= 32 or #kp ~= 64 then return nil, "bad key" end
        -- Both keep the 32-byte seed then the public key.
        out = { type = t, dropbear = K.str(t) .. K.str(kp), public = K.str(t) .. K.str(pub) }
    elseif t == "ssh-rsa" then
        local n, e, d, iqmp, pp, q = p.str(), p.str(), p.str(), p.str(), p.str(), p.str()
        if not (n and e and d and iqmp and pp and q) then return nil, "bad key" end
        out = { type = t, dropbear = K.str(t) .. K.str(e) .. K.str(n) .. K.str(d) .. K.str(pp) .. K.str(q),
            public = K.str(t) .. K.str(e) .. K.str(n) }
    elseif t and ECDSA_CURVES[t] then
        local curve, Q, d = p.str(), p.str(), p.str()
        if curve ~= ECDSA_CURVES[t] or not Q or not d then return nil, "bad key" end
        out = { type = t, dropbear = K.str(t) .. K.str(curve) .. K.str(Q) .. K.str(d),
            public = K.str(t) .. K.str(curve) .. K.str(Q) }
    else
        return nil, "unsupported"
    end
    out.comment = p.str()
    return out
end

--- Any private key file's text (OpenSSH or Dropbear) into Dropbear's format,
-- as K.fromOpenSSH; why is also "pem" (an older format) or "public" (the
-- .pub file, not the private key).
function K.import(text)
    local kind = K.kind(text)
    if kind == "openssh" then return K.fromOpenSSH(text) end
    if kind == "dropbear" then
        local k, why = K.readDropbear(text)
        if not k then return nil, why end
        k.dropbear = text
        return k
    end
    if kind == "pem" or kind == "public" then return nil, kind end
    return nil, "not a key"
end

--- An Ed25519 key in Dropbear's format from its 32-byte seed and public key.
function K.ed25519(seed, pub)
    local t = "ssh-ed25519"
    return { type = t, dropbear = K.str(t) .. K.str(seed .. pub), public = K.str(t) .. K.str(pub) }
end

--- The line for authorized_keys: "ssh-ed25519 AAAA… comment".
function K.publicLine(blob, comment)
    local t = K.reader(blob).str() or "ssh-ed25519"
    local line = t .. " " .. K.base64(blob)
    comment = comment and tostring(comment):gsub("%s+", "-") or ""
    if comment ~= "" then line = line .. " " .. comment end
    return line
end

--- A short name for a key type: "Ed25519", "RSA", "ECDSA".
function K.typeName(t)
    if t == "ssh-ed25519" then return "Ed25519" end
    if t == "ssh-rsa" then return "RSA" end
    if t and ECDSA_CURVES[t] then return "ECDSA" end
    return t or "?"
end

return K
