-- Plain Lua tests: `luajit tests/run.lua` from the plugin folder.
package.path = "./?.lua;" .. package.path
package.preload["ui/event"] = function() return { new = function(_, name) return { name = name } end } end
package.preload["logger"] = function() return { warn = function() end, err = function() end } end
package.preload["socket"] = function() return {} end
local Server = require("webserver")

local failed, passed = 0, 0
local function check(name, got, want)
    if got == want then passed = passed + 1 else
        failed = failed + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    end
end

local q = Server.parseQuery("path=%2Fdocuments%2FMy+Books&name=a%26b.epub&empty=&flag")
check("decoded path", q.path, "/documents/My Books")
check("escaped ampersand", q.name, "a&b.epub")
check("empty value", q.empty, "")
check("bare key", q.flag, "")
check("epub type", Server.typeOf("Book.EPUB"), "application/epub+zip")
check("unknown type", Server.typeOf("x.weird"), "application/octet-stream")
check("unescape", Server.unescape("a%20b+c"), "a b c")

-- Copy to: a taken name gets " (2)", as on the Kindle.
for __, m in ipairs({ "datastorage", "device", "libs/libkoreader-lfs", "ffi/util", "ui/uimanager" }) do
    package.preload[m] = function() return {} end
end
local Files = require("webfiles")
local taken = { ["Emma.epub"] = true, ["Emma (2).epub"] = true, ["Notes"] = true }
local function exists(n) return taken[n] end
check("free name", Files.freeName("Dracula.epub", exists), "Dracula.epub")
check("taken name", Files.freeName("Emma.epub", exists), "Emma (3).epub")
check("taken folder", Files.freeName("Notes", exists), "Notes (2)")

-- A book's details from its EPUB's package file.
local opf = require("weblibrary").parseOpf([[<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:title>The Harbour</dc:title><dc:publisher>Quay &amp; Sons</dc:publisher>
  <dc:date opf:event="modification">2020-01-01</dc:date><dc:date opf:event="publication">1897-05-26</dc:date>
  <dc:subject>Fiction</dc:subject><dc:subject>Sea stories</dc:subject>
  <dc:identifier opf:scheme="ISBN">978-0-00-000000-2</dc:identifier></metadata></package>]])
check("publisher", opf.publisher, "Quay & Sons")
check("published", opf.published, "1897")
check("subjects", opf.subjects, "Fiction, Sea stories")
check("isbn", opf.isbn, "9780000000002")

-- HTTPS: the name the address is shown at for a certificate of yours.
local Tls = require("webtls")
check("host from names", Tls.hostOf({ "localhost", "192.168.1.50", "kindle.home.arpa" }), "kindle.home.arpa")
check("wildcard skipped", Tls.hostOf({ "*.example.lan", "reader.example.lan" }), "reader.example.lan")
check("addresses only", Tls.hostOf({ "localhost", "127.0.0.1", "192.168.1.50", "fe80::1" }), nil)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
