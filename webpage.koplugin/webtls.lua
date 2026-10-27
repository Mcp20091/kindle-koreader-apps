--[[--
HTTPS for the web server: the certificate it serves and the TLS context the
server wraps each connection in (LuaSec, which KOReader ships).

Two kinds of certificate, each in its own files in koreader/settings:
- the Kindle's own: an EC P-256 key, signed by itself, made here with KOReader's
  crypto library (LibreSSL) through ffi. No browser knows it: each warns once
  (Advanced > Proceed), then the page is encrypted. It lasts DAYS days and is made
  again at start once fewer than RENEW are left.
- yours: a certificate and key pasted or uploaded on the web page (System > HTTPS),
  checked before it's kept (they match, no passphrase, not ended). It is never
  replaced here: once it ends, HTTPS doesn't start and the server runs on HTTP.
  The address shown is then at the name it was issued for (Tls.hostOf).

Both certificates and their keys go in a backup only with Include keys and sign-ins
(webbackup.lua); without, a restored Kindle makes its own and yours is pasted again. No HSTS: turning HTTPS off (on the Kindle, Tools >
Web server) must leave the page reachable over HTTP again.
]]

local DataStorage = require("datastorage")
local ffi = require("ffi")

local Tls = {}

Tls.DAYS = 397    -- the longest any browser accepts for a server certificate
Tls.RENEW = 30    -- the Kindle's own made again at start with fewer days than this left

--- The key's and certificate's files: yours (`own`) or the Kindle's own.
function Tls.paths(own)
    local base = DataStorage:getSettingsDir() .. (own and "/webpage-https-own-" or "/webpage-https-")
    return base .. "key.pem", base .. "cert.pem"
end

local cdefs = [[
typedef struct evp_pkey_st EVP_PKEY;
typedef struct ec_key_st EC_KEY;
typedef struct x509_st X509;
typedef struct X509_name_st X509_NAME;
typedef struct asn1_string_st ASN1_INTEGER;
typedef struct asn1_string_st ASN1_TIME;
typedef struct bio_st BIO;
typedef struct env_md_st EVP_MD;
typedef struct X509_extension_st X509_EXTENSION;
EC_KEY *EC_KEY_new_by_curve_name(int nid);
void EC_KEY_set_asn1_flag(EC_KEY *key, int flag);
int EC_KEY_generate_key(EC_KEY *key);
void EC_KEY_free(EC_KEY *key);
EVP_PKEY *EVP_PKEY_new(void);
int EVP_PKEY_assign(EVP_PKEY *pkey, int type, void *key);
void EVP_PKEY_free(EVP_PKEY *pkey);
X509 *X509_new(void);
void X509_free(X509 *x);
int X509_set_version(X509 *x, long version);
ASN1_INTEGER *X509_get_serialNumber(X509 *x);
int ASN1_INTEGER_set(ASN1_INTEGER *a, long v);
ASN1_TIME *X509_gmtime_adj(ASN1_TIME *s, long adj);
ASN1_TIME *X509_getm_notBefore(const X509 *x);
ASN1_TIME *X509_getm_notAfter(const X509 *x);
const ASN1_TIME *X509_get0_notAfter(const X509 *x);
int ASN1_TIME_diff(int *pday, int *psec, const ASN1_TIME *from, const ASN1_TIME *to);
int X509_set_pubkey(X509 *x, EVP_PKEY *pkey);
X509_NAME *X509_get_subject_name(const X509 *x);
int X509_set_issuer_name(X509 *x, X509_NAME *name);
int X509_NAME_add_entry_by_txt(X509_NAME *name, const char *field, int type, const unsigned char *bytes, int len, int loc, int set);
X509_EXTENSION *X509V3_EXT_conf_nid(void *conf, void *ctx, int nid, const char *value);
int X509_add_ext(X509 *x, X509_EXTENSION *ex, int loc);
void X509_EXTENSION_free(X509_EXTENSION *ex);
const EVP_MD *EVP_sha256(void);
int X509_sign(X509 *x, EVP_PKEY *pkey, const EVP_MD *md);
int X509_check_private_key(const X509 *x, const EVP_PKEY *pkey);
BIO *BIO_new_file(const char *filename, const char *mode);
BIO *BIO_new_mem_buf(const void *buf, int len);
int BIO_free(BIO *a);
int PEM_write_bio_PrivateKey(BIO *bp, EVP_PKEY *x, const void *enc, unsigned char *kstr, int klen, void *cb, void *u);
int PEM_write_bio_X509(BIO *bp, X509 *x);
X509 *PEM_read_bio_X509(BIO *bp, X509 **x, void *cb, void *u);
EVP_PKEY *PEM_read_bio_PrivateKey(BIO *bp, EVP_PKEY **x, void *cb, void *u);
]]

local NID_P256, NID_EC = 415, 408
local NID_BASIC, NID_KEY_USAGE, NID_EXT_KEY_USAGE, NID_ALT_NAME = 87, 83, 126, 85
local MBSTRING_ASC = 0x1001

-- KOReader's libcrypto (libs/libcrypto.so.N; N changes with KOReader's versions).
local C
local function crypto()
    if C then return C end
    pcall(ffi.cdef, cdefs)
    pcall(require, "ffi/loadlib")
    local versions = {}
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs.attributes("libs", "mode") == "directory" then
        for f in lfs.dir("libs") do
            local v = f:match("^libcrypto%.so%.(%d+)$")
            if v then table.insert(versions, v) end
        end
    end
    local load = ffi.loadlib or function(n, v) return ffi.load("libs/lib" .. n .. ".so." .. v) end
    for __, v in ipairs(versions) do
        local okl, lib = pcall(load, "crypto", v)
        if okl then C = lib return C end
    end
    local okl, lib = pcall(ffi.load, "crypto")
    if okl then C = lib return C end
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

-- The first certificate in PEM text, as an X509 (freed by the caller), or nil.
local function readCert(L, pem)
    local b = L.BIO_new_mem_buf(pem, #pem)
    if b == nil then return nil end
    local x = L.PEM_read_bio_X509(b, nil, nil, nil)
    L.BIO_free(b)
    if x ~= nil then return x end
end

-- Whole days left (negative once ended) and the seconds left, or nil.
local function daysLeftOf(L, x)
    local day, sec = ffi.new("int[1]"), ffi.new("int[1]")
    if L.ASN1_TIME_diff(day, sec, nil, L.X509_get0_notAfter(x)) ~= 1 then return nil end
    local left = day[0] * 86400 + sec[0]
    return math.floor(left / 86400), left
end

-- The names a certificate is for (its subject alternative names), from LuaSec's x509.
local function namesOf(pem)
    local ok, x509 = pcall(require, "ssl.x509")
    if not ok then return {} end
    local okc, cert = pcall(x509.load, pem)
    if not okc or not cert then return {} end
    local names = {}
    local alt = (cert:extensions() or {})["2.5.29.17"] or {}
    for __, kind in ipairs({ "dNSName", "iPAddress" }) do
        for __, v in ipairs(alt[kind] or {}) do table.insert(names, v) end
    end
    return names
end

--- What the certificate is (yours, `own`, or the Kindle's own): { daysLeft, until (2027-11-27),
-- names } or nil when there's none, or it can't be read.
function Tls.info(own)
    local L = crypto()
    local __, certPath = Tls.paths(own)
    local pem = readFile(certPath)
    if not L or not pem then return nil end
    local x = readCert(L, pem)
    if not x then return nil end
    local left, secs = daysLeftOf(L, x)
    L.X509_free(x)
    if not left then return nil end
    return { daysLeft = left, ["until"] = os.date("%Y-%m-%d", os.time() + secs), names = namesOf(pem) }
end

--- Makes the Kindle's own key and certificate, for `ip` (its address now) and
-- localhost. Returns true, or nil and why.
function Tls.make(ip)
    local L = crypto()
    if not L then return nil, "KOReader's crypto library wasn't found" end
    local keyPath, certPath = Tls.paths(false)
    local ec = L.EC_KEY_new_by_curve_name(NID_P256)
    if ec == nil then return nil, "no P-256 key" end
    L.EC_KEY_set_asn1_flag(ec, 1)
    if L.EC_KEY_generate_key(ec) ~= 1 then
        L.EC_KEY_free(ec)
        return nil, "the key couldn't be made"
    end
    local pkey = L.EVP_PKEY_new()
    L.EVP_PKEY_assign(pkey, NID_EC, ec)   -- (the key frees the EC key with it)
    local x = L.X509_new()
    local why
    local function step(ok, what) if not why and not ok then why = what end end
    step(L.X509_set_version(x, 2) == 1, "version")
    math.randomseed(os.time())
    step(L.ASN1_INTEGER_set(L.X509_get_serialNumber(x), math.random(1, 2147483646)) == 1, "serial")
    step(L.X509_gmtime_adj(L.X509_getm_notBefore(x), -86400) ~= nil, "start date")
    step(L.X509_gmtime_adj(L.X509_getm_notAfter(x), Tls.DAYS * 86400) ~= nil, "end date")
    step(L.X509_set_pubkey(x, pkey) == 1, "public key")
    local name = L.X509_get_subject_name(x)
    step(L.X509_NAME_add_entry_by_txt(name, "O", MBSTRING_ASC, "KOReader web server", -1, -1, 0) == 1, "name")
    step(L.X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, ip or "localhost", -1, -1, 0) == 1, "name")
    step(L.X509_set_issuer_name(x, name) == 1, "issuer")
    local alt = "DNS:localhost,IP:127.0.0.1"
    if ip and ip:match("^%d+%.%d+%.%d+%.%d+$") then alt = alt .. ",IP:" .. ip end
    for __, e in ipairs({ { NID_BASIC, "critical,CA:FALSE" }, { NID_KEY_USAGE, "critical,digitalSignature" },
            { NID_EXT_KEY_USAGE, "serverAuth" }, { NID_ALT_NAME, alt } }) do
        local ext = L.X509V3_EXT_conf_nid(nil, nil, e[1], e[2])
        step(ext ~= nil, "extension " .. e[2])
        if ext ~= nil then
            step(L.X509_add_ext(x, ext, -1) == 1, "extension")
            L.X509_EXTENSION_free(ext)
        end
    end
    step(L.X509_sign(x, pkey, L.EVP_sha256()) > 0, "signature")
    if not why then
        -- The key's file made first and closed to others where the file system allows it.
        os.remove(keyPath)
        writeFile(keyPath, "")
        os.execute(string.format("chmod 600 '%s' 2>/dev/null", keyPath))
        local b = L.BIO_new_file(keyPath, "w")
        step(b ~= nil and L.PEM_write_bio_PrivateKey(b, pkey, nil, nil, 0, nil, nil) == 1, "writing the key")
        if b ~= nil then L.BIO_free(b) end
        b = L.BIO_new_file(certPath, "w")
        step(b ~= nil and L.PEM_write_bio_X509(b, x) == 1, "writing the certificate")
        if b ~= nil then L.BIO_free(b) end
    end
    L.X509_free(x)
    L.EVP_PKEY_free(pkey)
    if why then return nil, "the certificate couldn't be made (" .. why .. ")" end
    return true
end

--- Checks your certificate and key (PEM text, pasted or from files; the certificate
-- may be followed by its chain) and keeps them. Returns the info, or nil and why.
function Tls.saveOwn(certPem, keyPem)
    local L = crypto()
    if not L then return nil, "KOReader's crypto library wasn't found" end
    certPem, keyPem = tostring(certPem or ""), tostring(keyPem or "")
    if not certPem:find("-----BEGIN CERTIFICATE-----", 1, true) then
        return nil, "The certificate isn't in PEM form (-----BEGIN CERTIFICATE-----)."
    end
    if not keyPem:find("-----BEGIN [%u ]*PRIVATE KEY-----") then
        return nil, "The key isn't in PEM form (-----BEGIN PRIVATE KEY-----)."
    end
    if keyPem:find("ENCRYPTED", 1, true) then
        return nil, "The key has a passphrase. Use one without (openssl pkey -in key.pem -out plain.pem)."
    end
    local x = readCert(L, certPem)
    if not x then return nil, "The certificate couldn't be read." end
    local b = L.BIO_new_mem_buf(keyPem, #keyPem)
    local pkey = b ~= nil and L.PEM_read_bio_PrivateKey(b, nil, nil, ffi.cast("void *", "")) or nil
    if b ~= nil then L.BIO_free(b) end
    local why
    if pkey == nil then
        why = "The key couldn't be read."
    elseif L.X509_check_private_key(x, pkey) ~= 1 then
        why = "The key isn't the certificate's."
    else
        local left = daysLeftOf(L, x)
        if not left or left < 0 then why = "The certificate has ended." end
    end
    if pkey ~= nil then L.EVP_PKEY_free(pkey) end
    L.X509_free(x)
    if why then return nil, why end
    local keyPath, certPath = Tls.paths(true)
    os.remove(keyPath)
    writeFile(keyPath, "")
    os.execute(string.format("chmod 600 '%s' 2>/dev/null", keyPath))
    if not (writeFile(keyPath, keyPem) and writeFile(certPath, certPem)) then
        return nil, "The files couldn't be written in koreader/settings."
    end
    return Tls.info(true)
end

--- The name to show the address at for a certificate's `names`: the first that is
-- a whole host name (not localhost, an address or a wildcard), or nil.
function Tls.hostOf(names)
    for __, n in ipairs(names or {}) do
        if n ~= "localhost" and not n:find("*", 1, true) and n:find("%a") and not n:find(":") then return n end
    end
end

--- Forgets your certificate and key.
function Tls.forgetOwn()
    local keyPath, certPath = Tls.paths(true)
    os.remove(keyPath)
    os.remove(certPath)
end

--- The TLS context to serve with: yours when `own`, else the Kindle's own (made
-- first when there's none, or it ends within RENEW days). Returns the context and
-- whether a new certificate was made, or nil and why.
function Tls.context(own, ip)
    local okssl, ssl = pcall(require, "ssl")
    if not okssl then return nil, "KOReader's TLS library (LuaSec) wasn't found" end
    local keyPath, certPath = Tls.paths(own)
    local info = Tls.info(own)
    local made = false
    if own then
        if not info then return nil, "your certificate can't be read: paste or upload it again" end
        if info.daysLeft < 0 then return nil, "your certificate ended on " .. info["until"] end
    else
        if not info or info.daysLeft < Tls.RENEW or not readFile(keyPath) then
            local ok, why = Tls.make(ip)
            if not ok then return nil, why end
            made = true
        end
    end
    -- (password: a key with one is refused, never asked for on a terminal that isn't there.)
    local ctx, err = ssl.newcontext{
        mode = "server", protocol = "any", key = keyPath, certificate = certPath, password = "",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
    }
    if not ctx then return nil, tostring(err) end
    return ctx, made
end

return Tls
