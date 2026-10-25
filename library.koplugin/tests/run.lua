-- Plain tests for librarymodel's helpers (no KOReader): luajit tests/run.lua
package.path = "./?.lua;" .. package.path

local M = require("librarymodel")

local passed, failed = 0, 0
local function eq(got, want, what)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- ------------------------------------------------------------------ names
eq(M.ext("Moby-Dick.EPUB"), "epub", "ext upper case")
eq(M.ext("noext"), "", "ext none")
eq(M.format("a.pdf"), "PDF", "format")
eq(M.format("README"), nil, "format none")

local a = M.splitAuthors("Jane Austen\nCharlotte Brontë")
eq(#a, 2, "two authors on two lines")
eq(a[2], "Charlotte Brontë", "second author")
a = M.splitAuthors("H. G. Wells; Arthur Conan Doyle")
eq(#a, 2, "authors split at ;")
eq(a[1], "H. G. Wells", "first of ; list")
eq(#M.splitAuthors(nil), 0, "no authors")
eq(#M.splitAuthors("  \n "), 0, "blank authors")

eq(M.authorKey("H. G. Wells"), "wells, h. g.", "last name first")
eq(M.authorKey("Austen, Jane"), "austen, jane", "already Surname, Name")
eq(M.authorKey("Plato"), "plato", "one name")
eq(M.authorKey("Martin Luther King Jr."), "king, martin luther jr.", "Jr. stays with the last name")
eq(M.authorKey("Jane Austen") < M.authorKey("Charles Dickens"), true, "Austen before Dickens")

eq(M.titleKey("The Time Machine"), "time machine", "The dropped")
eq(M.titleKey("A Study in Scarlet"), "study in scarlet", "A dropped")
eq(M.titleKey("An Essay"), "essay", "An dropped")
eq(M.titleKey("Anne of Green Gables"), "anne of green gables", "An only as a word")

-- ------------------------------------------------------------------ sizes, times
eq(M.size(500), "500 bytes", "bytes")
eq(M.size(380 * 1024), "380 kB", "kB")
eq(M.size(1.3 * 1024 * 1024), "1.3 MB", "MB with a decimal")
eq(M.size(42 * 1024 * 1024), "42 MB", "MB whole")
eq(M.size(3 * 1024 * 1024 * 1024), "3.0 GB", "GB")

eq(M.duration(20), "under a minute", "under a minute")
eq(M.duration(45 * 60), "45 min", "minutes")
eq(M.duration(2 * 3600 + 12 * 60), "2 h 12 min", "hours and minutes")
eq(M.duration(3 * 3600), "3 h", "whole hours")

local now = os.time{ year = 2026, month = 10, day = 25, hour = 20, min = 0 }
eq(M.when(os.time{ year = 2026, month = 10, day = 25, hour = 19, min = 43 }, now), "Today, 7:43 PM", "today")
eq(M.when(os.time{ year = 2026, month = 10, day = 25, hour = 9, min = 5 }, now, true), "Today, 09:05", "today 24-hour")
eq(M.when(os.time{ year = 2026, month = 10, day = 24, hour = 22, min = 0 }, now), "Yesterday, 10:00 PM", "yesterday")
eq(M.when(os.time{ year = 2026, month = 10, day = 19, hour = 12 }, now), "Oct 19", "this year")
eq(M.when(os.time{ year = 2025, month = 3, day = 2, hour = 12 }, now), "Mar 2, 2025", "another year")
eq(M.when(nil, now), nil, "no time")
eq(M.date(os.time{ year = 2026, month = 10, day = 12, hour = 12 }), "Oct 12, 2026", "date")

-- ------------------------------------------------------------------ EPUB metadata
local container = [[<?xml version="1.0"?><container><rootfiles>
  <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]]
eq(M.opfPath(container), "OEBPS/content.opf", "OPF path from container.xml")
eq(M.opfPath(nil), nil, "no container")

local opf = [[<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
  <dc:title>A Study in Scarlet</dc:title>
  <dc:publisher>Ward, Lock &amp; Co.</dc:publisher>
  <dc:date opf:event="modification">2024-01-02</dc:date>
  <dc:date opf:event="publication">1887-11-01</dc:date>
  <dc:subject>Detective fiction</dc:subject>
  <dc:subject>London (England) -- Fiction</dc:subject>
  <dc:identifier opf:scheme="ISBN">978-0-00-000000-2</dc:identifier>
  <meta name="calibre:series" content="Sherlock Holmes"/>
  <meta name="calibre:series_index" content="1"/>
</metadata></package>]]
local o = M.parseOpf(opf)
eq(o.publisher, "Ward, Lock & Co.", "publisher unescaped")
eq(o.published, "1887", "the publication date's year, not the modification's")
eq(o.subjects, "Detective fiction, London (England) -- Fiction", "subjects")
eq(o.isbn, "9780000000002", "ISBN without dashes")
eq(o.series, "Sherlock Holmes", "Calibre's series")
eq(o.series_index, 1, "Calibre's series index")

o = M.parseOpf([[<metadata><dc:date>0101-01-01T00:00:00+00:00</dc:date><dc:identifier>urn:uuid:1234</dc:identifier></metadata>]])
eq(o.published, nil, "an unknown date (0101) left out")
eq(o.isbn, nil, "a uuid is not an ISBN")
o = M.parseOpf([[<metadata><dc:date>Spring 1999</dc:date><dc:identifier>urn:isbn:0306406152</dc:identifier></metadata>]])
eq(o.published, "Spring 1999", "a date that isn't one, as written")
eq(o.isbn, "0306406152", "an ISBN-10 from urn:isbn")
eq(next(M.parseOpf(nil)), nil, "no OPF")

-- ------------------------------------------------------------------ names for files
local n = M.niceNames("moby.epub", "Moby-Dick", "Herman Melville")
eq(n[1], "Moby-Dick – Herman Melville.epub", "title and author")
eq(n[2], "Moby-Dick.epub", "title only")
n = M.niceNames("x.pdf", "What: a/b?", nil)
eq(n[1], "What a b.pdf", "unsafe characters out")
eq(#M.niceNames("Emma.epub", "Emma", nil), 0, "already its name")
eq(#M.niceNames("a.epub", nil, "Someone"), 0, "no title, no names")

local taken = { ["Book.epub"] = true, ["Book (2).epub"] = true }
eq(M.freeName("Book.epub", function(x) return taken[x] end), "Book (3).epub", "a free name")
eq(M.freeName("New.epub", function(x) return taken[x] end), "New.epub", "already free")
eq(M.freeName("Folder", function(x) return x == "Folder" end), "Folder (2)", "a folder's free name")

-- ------------------------------------------------------------------ sorting
local books = {
    { name = "b.epub", title = "The Time Machine", authors = "H. G. Wells", added = 30, size = 300, read = 5, p = 0.18 },
    { name = "a.epub", title = "Emma", authors = "Jane Austen", added = 10, size = 900, read = 9, p = nil },
    { name = "c.epub", title = "A Study in Scarlet", authors = "Arthur Conan Doyle", added = 20, size = 380, read = nil, p = 0.42 },
}
local get = {
    title = function(b) return b.title end,
    authors = function(b) return b.authors end,
    progress = function(b) return b.p end,
    lastRead = function(b) return b.read end,
}
local function names(list) local t = {} for i, b in ipairs(list) do t[i] = b.name end return table.concat(t, " ") end
eq(names(M.sortBooks(books, "title", get)), "a.epub c.epub b.epub", "by title (The/A dropped)")
eq(names(M.sortBooks(books, "author", get)), "a.epub c.epub b.epub", "by author's last name")
eq(names(M.sortBooks(books, "read", get)), "a.epub b.epub c.epub", "recently read first, never read last")
eq(names(M.sortBooks(books, "added", get)), "b.epub c.epub a.epub", "recently added first")
eq(names(M.sortBooks(books, "size", get)), "a.epub c.epub b.epub", "biggest first")
eq(names(M.sortBooks(books, "name", get)), "a.epub b.epub c.epub", "by file name")
eq(names(M.sortBooks(books, "progress", get)), "c.epub b.epub a.epub", "furthest read first")

-- ------------------------------------------------------------------ Find details online (made-up answers)
local O = require("libraryonline")
eq(O.isbn("978-0-14-143932-7"), "9780141439327", "ISBN-13 with dashes")
eq(O.isbn("urn:isbn:0141439327"), "0141439327", "urn:isbn")
eq(O.isbn("ISBN 014143932x"), "014143932X", "ISBN-10 with x")
eq(O.isbn("12345"), nil, "not an ISBN")
eq(O.isbn("9990141439327"), nil, "13 digits not starting 978/979")

local q = O.queryOf({ title = "Kidnapped: Being Memoirs of the Adventures (Illustrated)", authors = "Robert Louis Stevenson\nSomeone Else" })
eq(q.title, "Kidnapped", "query title without subtitle and brackets")
eq(q.author, "Robert Louis Stevenson", "query first author")
eq(O.queryOf({ title = "X", isbn = "978-0-14-143932-7" }).isbn, "9780141439327", "query by ISBN first")
eq(O.queryFromText(" 0141439327 ").isbn, "0141439327", "typed ISBN")
eq(O.queryFromText("kidnapped stevenson").text, "kidnapped stevenson", "typed words")
eq(O.queryText({ title = "Kidnapped", author = "Robert Louis Stevenson" }), "Kidnapped Robert Louis Stevenson", "query as words")
local urls = O.urls({ title = "Kidnapped", author = "R. L. Stevenson" })
eq(urls.ol:match("title=([^&]+)"), "Kidnapped", "Open Library title")
eq(urls.ol:match("author=([^&]+)"), "R.+L.+Stevenson", "Open Library author escaped")
eq(urls.google:match("q=([^&]+)"), "intitle:Kidnapped+inauthor:R.+L.+Stevenson", "Google query")
eq(O.urls({ isbn = "0141439327" }).ol:match("q=([^&]+)"), "isbn:0141439327", "ISBN query")

local t, s, n = O.splitTitle("The Harbour Lights (Lantern Coast, #2)")
eq(t, "The Harbour Lights", "title without series")
eq(s, "Lantern Coast", "series from brackets")
eq(n, 2, "number from brackets")
t, s, n = O.splitTitle("Salt Roads", "Lantern Coast, Book 3")
eq(s .. " " .. n, "Lantern Coast 3", "series from subtitle")
t, s = O.splitTitle("Notes (Revised Edition)")
eq(t .. tostring(s), "Notes (Revised Edition)nil", "brackets that aren't a series stay")

eq(O.plainText("<p>One &amp; two.</p><p>Three<br>four</p>"), "One & two.\n\nThree\nfour", "HTML to text")
eq(O.plainText("A story.\r\n\r\n----------\r\nAlso in: [Collected](https://x)"), "A story.", "Open Library's other editions cut")
eq(O.plainText("See [the map](https://example.org/m)."), "See the map.", "links as text")

local ol = O.olMatches({ docs = {
    { key = "/works/OL1W", title = "Kidnapped", author_name = { "Robert Louis Stevenson" }, first_publish_year = 1886,
      publisher = { "Someone" }, subject = { "Accessible book", "Adventure stories", "Scotland", "Protected DAISY", "nyt:x=1" },
      number_of_pages_median = 262, cover_i = 123, isbn = { "0141439327" },
      editions = { docs = { { publisher = { "Cassell & Company" }, number_of_pages = 288, language = { "eng" }, isbn = { "0141439327", "9780141439327" }, cover_i = 456 } } } },
    { title = "Kidnapped and Catriona", author_name = { "Robert Louis Stevenson" } },
} }, "title")
eq(#ol, 2, "two Open Library matches")
eq(ol[1].publisher, "Cassell & Company", "the edition's publisher first")
eq(ol[1].published, "1886", "first published")
eq(ol[1].pages, 288, "the edition's pages")
eq(ol[1].subjects, "Adventure stories, Scotland", "subjects without Open Library's tags")
eq(ol[1].language, "en", "eng → en")
eq(ol[1].isbn, "9780141439327", "ISBN-13 preferred")
eq(ol[1].cover, "https://covers.openlibrary.org/b/id/456-L.jpg?default=false", "the edition's cover")
eq(ol[2].cover, nil, "no cover")

local g = O.googleMatches({ items = { { volumeInfo = { title = "Kidnapped", subtitle = "David Balfour, Book 1", authors = { "R. L. Stevenson" },
    publisher = "\"Puffin\"", publishedDate = "1994-05-01", pageCount = 0, categories = { "Fiction / Action & Adventure" },
    description = "<p>Sold by his uncle&#39;s plan.</p>", language = "en",
    industryIdentifiers = { { type = "ISBN_10", identifier = "0140366962" } },
    imageLinks = { thumbnail = "http://books.google.com/books/content?id=x&printsec=frontcover&img=1&zoom=1&edge=curl" } } } } }, "title")
eq(g[1].series .. " " .. g[1].seriesIndex, "David Balfour 1", "Google series from the subtitle")
eq(g[1].publisher, "Puffin", "quotes off the publisher")
eq(g[1].published, "1994", "year")
eq(g[1].pages, nil, "no page count when 0")
eq(g[1].subjects, "Fiction, Action & Adventure", "categories split")
eq(g[1].description, "Sold by his uncle's plan.", "description as text")
eq(g[1].cover, "https://books.google.com/books/content?id=x&printsec=frontcover&img=1&zoom=1", "cover over https, no curl")
eq(g[1].complete, true, "Google's match needs nothing more")

local ranked = O.rank({ { title = "Kidnapped and Catriona" }, { title = "Kidnapped" } }, "Kidnapped")
eq(ranked[1].title, "Kidnapped", "the same title first")

local rows, same = O.compare(
    { title = "Kidnapped", authors = "Robert Louis Stevenson", language = "English", subjects = "Fiction" },
    { title = "Kidnapped", authors = "Robert Louis Stevenson", language = "en", series = "David Balfour", seriesIndex = 1,
      published = "1886", publisher = "Cassell & Company", pages = 288, subjects = "Adventure stories, Scotland", description = "Sold." },
    function(c) return c == "en" and "English" or c end)
local keys = {}
for __, r in ipairs(rows) do table.insert(keys, r.key .. (r.tick and "+" or "-")) end
eq(table.concat(keys, " "), "series+ published+ publisher+ pages+ subjects- description+", "rows: ticked where the book has none")
eq(table.concat(same, ", "), "title, authors, language", "the same in both")
eq(rows[1].found, "David Balfour · Book 1", "series shown with its number")
eq(rows[4].found, "288 pages", "print length shown")
eq(rows[5].now, "Fiction", "what the book has")
rows = O.compare({ title = "Kidnapped" }, { title = "Kidnapped", authors = "R. L. Stevenson" })
eq(#rows, 0, "authors offered only when the book has other ones")

local p = O.props({ series = "David Balfour", seriesIndex = 1, subjects = "Adventure stories, Scotland", pages = 288, publisher = "Cassell" },
    { series = true, subjects = true, pages = true, publisher = true, title = false })
eq(p.series .. p.series_index, "David Balfour1", "series and index")
eq(p.keywords, "Adventure stories\nScotland", "subjects as KOReader's keywords")
eq(p.print_pages, 288, "print length")
eq(p.publisher, "Cassell", "publisher")
eq(p.title, nil, "unticked not saved")

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
