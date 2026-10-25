--[[--
An article made into an EPUB by KOReader's own Wikipedia code (the one behind
Save as EPUB in a Wikipedia lookup): sections become the table of contents,
citations stay as footnotes, and links point at Wikipedia articles. Images
only when the setting says so (KOReader would otherwise ask each time).
]]

local util = require("util")
local _ = require("gettext")

local Epub = {}

-- Added to KOReader's style sheet: the summary box (infobox) and its kin as
-- Wikipedia shows them, compact with plain bold labels, instead of a
-- full-size table of grey cells; lists in it on one line, as on the web.
Epub.CSS = [[

/* Wikipedia plugin: the summary box */
table.infobox, table.infobox_v2, table.infobox_v3, table.vcard, table.biography, table.sidebar, table.ib-settlement {
    font-size: 64% !important;
    border: 1px solid #999;
    border-spacing: 0;
    margin: 0.4em 0 1em 0;
    line-height: 1.25;
}
table.infobox th, table.infobox td, table.vcard th, table.vcard td, table.sidebar th, table.sidebar td {
    padding: 1px 4px !important;
    vertical-align: top;
    text-align: left;
}
table.infobox th, table.vcard th, .infobox-label {
    background-color: transparent;
    text-align: left;
    width: 32%;
}
.infobox-above, .infobox-title, table.infobox caption {
    font-size: 125%;
    font-weight: bold;
    text-align: center !important;
    background-color: #EEE;
    width: auto;
}
.infobox-header, .infobox-subheader, table.sidebar .sidebar-heading,
table.infobox th.infobox-header, table.infobox th.infobox-above, table.vcard th.infobox-header {
    text-align: center !important;
    background-color: #EEE;
    width: auto;
}
.infobox-image, .infobox-caption, .infobox-full-data {
    text-align: center !important;
}
.infobox-image img {
    width: 32% !important;
    height: auto !important;
}
.infobox-caption { font-size: 90%; }
.hlist ul, .hlist ol, .plainlist ul {
    margin: 0;
    padding: 0;
}
.hlist li {
    display: inline;
}
.hlist li:after {
    content: " · ";
}
.hlist li:last-child:after {
    content: "";
}
.plainlist li {
    list-style: none;
}

/* Wikipedia plugin: sections follow on, not each on a new page (a heading stays with its text) */
h1, h2 {
    page-break-before: auto;
    margin-top: 1.2em;
}
]]

-- KOReader's list of sections after the opening paragraph (between two thick
-- lines, on a page of its own): the toolbar's Contents does that.
function Epub.dropSectionList(html)
    return (html:gsub('<hr class="koreaderwikitocstart"/>.-<hr class="koreaderwikitocend"/>\n?', ""))
end

-- KOReader's EPUB writer, with our CSS added to the style sheet while `fn` runs.
local function withOurCss(fn)
    local Writer = require("ffi/archiver").Writer
    local add = Writer.addFileFromMemory
    Writer.addFileFromMemory = function(w, name, content, ...)
        if name == "OEBPS/stylesheet.css" and type(content) == "string" then content = content .. Epub.CSS end
        if name == "OEBPS/content.html" and type(content) == "string" then content = Epub.dropSectionList(content) end
        return add(w, name, content, ...)
    end
    local r = table.pack(pcall(fn))
    Writer.addFileFromMemory = add
    return table.unpack(r, 1, r.n)
end

--- Build without asking anything (progress shows when run under Trapper).
function Epub.build(path, title, lang, images)
    util.makePath((path:match("^(.*)/[^/]*$")))
    local W = require("ui/wikipedia")
    local keep_images = G_reader_settings:readSetting("wikipedia_epub_include_images")
    local keep_hires = G_reader_settings:readSetting("wikipedia_epub_highres_images")
    G_reader_settings:saveSetting("wikipedia_epub_include_images", images and true or false)
    G_reader_settings:saveSetting("wikipedia_epub_highres_images", false)
    local ok, res = withOurCss(function() return W:createEpub(path, title, lang, true) end)
    local function restore(key, v)
        if v == nil then G_reader_settings:delSetting(key) else G_reader_settings:saveSetting(key, v) end
    end
    restore("wikipedia_epub_include_images", keep_images)
    restore("wikipedia_epub_highres_images", keep_hires)
    if not ok then require("logger").warn("Wikipedia EPUB:", res) end
    return ok and res == true
end

return Epub
