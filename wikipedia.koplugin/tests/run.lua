-- Plain tests for wikimodel (no KOReader): luajit tests/run.lua
package.path = "./?.lua;" .. package.path

local M = require("wikimodel")

local passed, failed = 0, 0
local function eq(got, want, what)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- file names
local t, l = M.fileTitle("Nixon in China.EN.epub")
eq(t, "Nixon in China", "fileTitle title")
eq(l, "en", "fileTitle lang")
t, l = M.fileTitle("Some book.epub")
eq(t, nil, "fileTitle not an article")
t, l = M.fileTitle("Ville.ZH-YUE.epub")
eq(l, "zh-yue", "fileTitle lang with a dash")
eq(M.fileTitle("lower.en.epub"), nil, "fileTitle lower-case lang is not ours")

-- links
l, t = M.fromUrl("https://en.wikipedia.org/wiki/John_Adams_(composer)")
eq(l, "en", "fromUrl lang")
eq(t, "John Adams (composer)", "fromUrl title")
l, t = M.fromUrl("https://fr.wikipedia.org/wiki/H%C3%B4tel_de_Ville#Histoire")
eq(t, "Hôtel de Ville", "fromUrl decoded, anchor dropped")
l, t = M.fromUrl("https://en.m.wikipedia.org/wiki/Paris")
eq(t, "Paris", "fromUrl mobile")
eq(M.fromUrl("https://en.wikipedia.org/wiki/File:Nixon.jpg"), nil, "fromUrl file page")
eq(M.fromUrl("https://en.wikipedia.org/wiki/Category:Operas"), nil, "fromUrl category")
eq(M.fromUrl("https://www.earbox.com/nixon-in-china/"), nil, "fromUrl other site")
l, t = M.fromUrl("https://en.wikipedia.org/wiki/Star_Wars:_Episode_IV")
eq(t, "Star Wars: Episode IV", "fromUrl title with a colon")

-- recent
local list = M.addRecent({}, { title = "A", lang = "en", time = 1 }, 3)
list = M.addRecent(list, { title = "B", lang = "en", time = 2 }, 3)
list = M.addRecent(list, { title = "A", lang = "en", time = 3 }, 3)
eq(#list, 2, "addRecent no duplicates")
eq(list[1].title, "A", "addRecent newest first")
list = M.addRecent(list, { title = "C", lang = "en", time = 4 }, 3)
list = M.addRecent(list, { title = "D", lang = "en", time = 5 }, 3)
eq(#list, 3, "addRecent keeps at most `keep`")
eq(list[3].title, "A", "addRecent drops the oldest")

-- html
eq(M.stripHtml('<!--Oct 17-->The <a href="./X">Hôtel</a> &amp; <b>more</b>'), "The Hôtel & more", "stripHtml")
eq(M.stripHtml("caf&#233;"), "café", "stripHtml numeric entity")

-- the feed
local feed = M.parseFeed({
    tfa = { normalizedtitle = "1986–87 Gillingham F.C. season", description = "English football club season", extract = "During…" },
    onthisday = { { year = 1987, text = "John Adams' opera Nixon in China premiered.",
        pages = { { titles = { normalized = "John Adams (composer)" } }, { titles = { normalized = "Nixon in China" } } } } },
    news = { { story = "<!--x-->The <a>BIPM</a> votes.", links = { { titles = { normalized = "BIPM" } } } } },
    mostread = { articles = { { titles = { normalized = "Main Page" } }, { titles = { normalized = "Special:Search" } },
        { titles = { normalized = "Jailer 2" }, description = "2026 film", views = 5 } } },
})
eq(feed.featured.title, "1986–87 Gillingham F.C. season", "feed featured")
eq(#feed.onthisday[1].pages, 2, "feed on this day pages")
eq(feed.onthisday[1].year, 1987, "feed year")
eq(feed.news[1].text, "The BIPM votes.", "feed news text")
eq(#feed.mostread, 1, "feed most read skips special pages")
eq(M.parseFeed({}).featured, nil, "feed without a featured article")

-- labels
eq(M.sizeLabel(1572864), "1.5 MB", "sizeLabel MB")
eq(M.sizeLabel(52000), "51 KB", "sizeLabel KB")
local now = os.time{ year = 2026, month = 10, day = 22, hour = 12 }
eq(M.dayLabel(now - 3600, now), "Today", "dayLabel today")
eq(M.dayLabel(now - 86400, now), "Yesterday", "dayLabel yesterday")
eq(M.dayLabel(now - 10 * 86400, now), "Oct 12", "dayLabel date")
eq(M.languageName("de"), "Deutsch", "languageName")
eq(M.key("EN", "Paris"), "en:Paris", "key")

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
