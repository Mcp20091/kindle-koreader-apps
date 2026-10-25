--[[--
The SSH app's files on the Kindle, all in KOReader's settings folder, never
in the plugin folder:
  sshclient.json            hosts, commands, the key list
  sshclient_passwords.json  the saved passwords, { [host id] = password }
  sshclient/keys/<id>       each private key, in Dropbear's format (only this Kindle reads it)
  sshclient/keys/<id>.pub   its public key line
  sshclient/.ssh/known_hosts  the trusted host keys (dbclient runs with HOME here)
(Before, all of it was in sshclient/data.json; it moves once.) The web page's
backup takes the first and the host keys; passwords and private keys only
with Include keys and sign-ins (PS.backupApps.sshclient, in main.lua).
Also where dbclient is, and making a new Ed25519 key with KOReader's libcrypto.
]]

local DataStorage = require("datastorage")
local JSON = require("json")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local K = require("sshkeys")
local M = require("sshmodel")

local Store = {}
Store.__index = Store

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- Writes a file through a temporary one, so a full disk or a crash never
-- leaves half a file; mode "600" makes it readable by this user only.
local function writeFile(path, s, private)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    local ok, werr = f:write(s)
    f:close()
    if not ok then
        os.remove(tmp)
        return nil, werr
    end
    if private then os.execute("chmod 600 '" .. tmp:gsub("'", "'\\''") .. "' 2>/dev/null") end
    local rok, rerr = os.rename(tmp, path)
    if not rok then return nil, rerr end
    return true
end

Store.readFile = readFile
Store.writeFile = writeFile

function Store.new(plugin_path)
    local self = setmetatable({}, Store)
    self.plugin_path = plugin_path
    self.dir = DataStorage:getSettingsDir() .. "/sshclient"
    self.file = DataStorage:getSettingsDir() .. "/sshclient.json"
    self.pwfile = DataStorage:getSettingsDir() .. "/sshclient_passwords.json"
    self.keydir = self.dir .. "/keys"
    self.known = self.dir .. "/.ssh/known_hosts"
    self.cache = DataStorage:getDataDir() .. "/cache/sshclient"
    for __, d in ipairs({ self.dir, self.keydir, self.dir .. "/.ssh", DataStorage:getDataDir() .. "/cache", self.cache }) do
        if lfs.attributes(d, "mode") ~= "directory" then lfs.mkdir(d) end
    end
    os.execute("chmod 700 '" .. self.keydir:gsub("'", "'\\''") .. "' 2>/dev/null")
    self:load()
    return self
end

-- A JSON file's table; one that can't be read is kept as <name>.bad.
local function readJSON(path)
    local s = readFile(path)
    if not s or s == "" then return nil, s == nil end
    local ok, t = pcall(JSON.decode, s)
    if ok and type(t) == "table" then return t end
    logger.warn("SSH: " .. path .. " can't be read, kept as .bad")
    os.rename(path, path .. ".bad")
    return nil
end

function Store:load()
    local old = self.dir .. "/data.json"
    if lfs.attributes(self.file, "mode") ~= "file" and lfs.attributes(old, "mode") == "file" then
        -- the one file from before: split in two (the passwords on their own)
        self.data = M.normalize(readJSON(old))
        if self:save() then os.remove(old) end
        return
    end
    local t, missing = readJSON(self.file)
    self.data = M.mergePasswords(M.normalize(t), readJSON(self.pwfile))
    if missing then self:save() end
end

function Store:save()
    local data, pw = M.splitPasswords(self.data)
    local ok, s = pcall(JSON.encode, data)
    local pok, ps = pcall(JSON.encode, pw)
    if not ok or not pok then
        logger.warn("SSH: can't save:", ok and ps or s)
        return false
    end
    -- (an empty table is written as [] by some JSON libraries: either reads back)
    local wok, err = writeFile(self.pwfile, ps, true)
    if wok then wok, err = writeFile(self.file, s, true) end
    if not wok then logger.warn("SSH: can't save:", err) end
    return wok
end

-- ------------------------------------------------------------------ dbclient

--- KOReader's dbclient (it ships with KOReader for Kindle and Kobo), or nil.
function Store:dbclient()
    local candidates = {
        lfs.currentdir() .. "/dbclient",
        DataStorage:getDataDir() .. "/dbclient",
        self.plugin_path .. "/dbclient",
    }
    for __, p in ipairs(candidates) do
        if lfs.attributes(p, "mode") == "file" then return p end
    end
    local f = io.popen("command -v dbclient 2>/dev/null")
    if f then
        local p = f:read("*l")
        f:close()
        if p and p ~= "" then return p end
    end
end

-- ------------------------------------------------------------------ keys

function Store:keyFile(kid) return self.keydir .. "/" .. kid end

--- Saves a key (from sshkeys: type, dropbear, public) under a name; returns
-- its entry in the key list.
function Store:addKey(name, key)
    local id = M.newId(self.data, "k")
    local line = K.publicLine(key.public, name)
    local ok, err = writeFile(self:keyFile(id), key.dropbear, true)
    if not ok then return nil, err end
    writeFile(self:keyFile(id) .. ".pub", line .. "\n")
    local entry = { id = id, name = name, type = key.type, public = line }
    table.insert(self.data.keys, entry)
    self:save()
    return entry
end

function Store:deleteKey(kid)
    local k, i = M.key(self.data, kid)
    if not k then return false end
    table.remove(self.data.keys, i)
    os.remove(self:keyFile(kid))
    os.remove(self:keyFile(kid) .. ".pub")
    self:save()
    return true
end

--- A new Ed25519 key from libcrypto (LibreSSL in KOReader): sshkeys' table,
-- or nil, why.
function Store.generateEd25519()
    local ok, crypto = pcall(ffi.loadlib, "crypto", "57")
    if not ok then return nil, "libcrypto: " .. tostring(crypto) end
    pcall(ffi.cdef, [[
        typedef struct evp_pkey_st EVP_PKEY;
        typedef struct evp_pkey_ctx_st EVP_PKEY_CTX;
        typedef struct engine_st ENGINE;
        int OBJ_txt2nid(const char *s);
        EVP_PKEY_CTX *EVP_PKEY_CTX_new_id(int id, ENGINE *e);
        int EVP_PKEY_keygen_init(EVP_PKEY_CTX *ctx);
        int EVP_PKEY_keygen(EVP_PKEY_CTX *ctx, EVP_PKEY **ppkey);
        void EVP_PKEY_CTX_free(EVP_PKEY_CTX *ctx);
        void EVP_PKEY_free(EVP_PKEY *pkey);
        int EVP_PKEY_get_raw_private_key(const EVP_PKEY *pkey, unsigned char *priv, size_t *len);
        int EVP_PKEY_get_raw_public_key(const EVP_PKEY *pkey, unsigned char *pub, size_t *len);
    ]])
    -- by its OID: LibreSSL names it "Ed25519", OpenSSL "ED25519"
    local nid = crypto.OBJ_txt2nid("1.3.101.112")
    if nid <= 0 then return nil, "no Ed25519 in libcrypto" end
    local ctx = crypto.EVP_PKEY_CTX_new_id(nid, nil)
    if ctx == nil then return nil, "EVP_PKEY_CTX_new_id" end
    local pkey = ffi.new("EVP_PKEY*[1]")
    local result, why
    if crypto.EVP_PKEY_keygen_init(ctx) == 1 and crypto.EVP_PKEY_keygen(ctx, pkey) == 1 then
        local seed, pub = ffi.new("unsigned char[32]"), ffi.new("unsigned char[32]")
        local n1, n2 = ffi.new("size_t[1]", 32), ffi.new("size_t[1]", 32)
        if crypto.EVP_PKEY_get_raw_private_key(pkey[0], seed, n1) == 1
            and crypto.EVP_PKEY_get_raw_public_key(pkey[0], pub, n2) == 1
            and n1[0] == 32 and n2[0] == 32 then
            result = K.ed25519(ffi.string(seed, 32), ffi.string(pub, 32))
        else
            why = "EVP_PKEY_get_raw_private_key"
        end
        ffi.fill(seed, 32)
        crypto.EVP_PKEY_free(pkey[0])
    else
        why = "EVP_PKEY_keygen"
    end
    crypto.EVP_PKEY_CTX_free(ctx)
    return result, why
end

-- ------------------------------------------------------------------ known_hosts

function Store:knownText() return readFile(self.known) or "" end

function Store:isKnown(address) return M.knownHas(self:knownText(), address) end

--- Forgets a host's key (after it changed, or when the host is deleted).
function Store:forget(address)
    local text, n = M.knownRemove(self:knownText(), address)
    if n > 0 then writeFile(self.known, text) end
    return n
end

return Store
