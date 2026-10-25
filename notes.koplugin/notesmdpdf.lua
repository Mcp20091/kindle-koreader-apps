--[[--
Markdown (as Claude writes it) into a PDF with real text, in plain Lua: no
KOReader modules, so the tests run it. Pages are A5 (a good size to read on
the Kindle Scribe), set in Helvetica: headings, paragraphs, bullet and
numbered lists, checkboxes, quotes, rules and simple tables (as rows).

Text is written in the PDF's WinAnsi encoding: Latin letters, accents and
common punctuation show as they are; anything else becomes "?".
]]

local MdPdf = {}

local PAGE_W, PAGE_H, MARGIN = 420, 595, 40

-- Helvetica's character widths (thousandths of the font size), 32..126.
local WIDTHS = {
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
}

-- Unicode characters WinAnsi has above 127 (besides Latin-1, which is the same).
local WINANSI = {
    [0x20AC] = 0x80, [0x201A] = 0x82, [0x0192] = 0x83, [0x201E] = 0x84, [0x2026] = 0x85, [0x2020] = 0x86,
    [0x2021] = 0x87, [0x02C6] = 0x88, [0x2030] = 0x89, [0x0160] = 0x8A, [0x2039] = 0x8B, [0x0152] = 0x8C,
    [0x017D] = 0x8E, [0x2018] = 0x91, [0x2019] = 0x92, [0x201C] = 0x93, [0x201D] = 0x94, [0x2022] = 0x95,
    [0x2013] = 0x96, [0x2014] = 0x97, [0x02DC] = 0x98, [0x2122] = 0x99, [0x0161] = 0x9A, [0x203A] = 0x9B,
    [0x0153] = 0x9C, [0x017E] = 0x9E, [0x0178] = 0x9F,
}

--- UTF-8 text in WinAnsi bytes.
function MdPdf.winAnsi(s)
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local b = s:byte(i)
        local cp, len
        if b < 0x80 then cp, len = b, 1
        elseif b >= 0xF0 then cp, len = ((b % 0x08) * 0x40000) + ((s:byte(i + 1) or 0) % 0x40) * 0x1000 + ((s:byte(i + 2) or 0) % 0x40) * 0x40 + ((s:byte(i + 3) or 0) % 0x40), 4
        elseif b >= 0xE0 then cp, len = ((b % 0x10) * 0x1000) + ((s:byte(i + 1) or 0) % 0x40) * 0x40 + ((s:byte(i + 2) or 0) % 0x40), 3
        elseif b >= 0xC0 then cp, len = ((b % 0x20) * 0x40) + ((s:byte(i + 1) or 0) % 0x40), 2
        else cp, len = 0x3F, 1 end
        local byte
        if cp < 0x80 then byte = cp
        elseif cp >= 0xA0 and cp <= 0xFF then byte = cp
        else byte = WINANSI[cp] end
        if cp == 0x2610 then table.insert(out, "[ ]")
        elseif cp == 0x2611 or cp == 0x2612 or cp == 0x2713 or cp == 0x2714 then table.insert(out, "[x]")
        else table.insert(out, string.char(byte or 0x3F)) end
        i = i + len
    end
    return table.concat(out)
end

local function width(s, size, bold)
    local w = 0
    for i = 1, #s do
        local b = s:byte(i)
        w = w + (b >= 32 and b <= 126 and WIDTHS[b - 31] or 556)
    end
    return w * size / 1000 * (bold and 1.06 or 1)
end

local function escape(s)
    return (s:gsub("[\\()]", "\\%0"):gsub("[\r\n]", " "))
end

--- For other PDF pages made here (the crosswords): the width of WinAnsi text
-- in Helvetica, and text made safe for a PDF string.
MdPdf.textWidth = width
MdPdf.escape = escape

--- Inline Markdown as runs of text with their style: { { text, bold,
-- italic }... }. **bold**, __bold__, *italic*, _italic_, ***both***,
-- `code` and [links](...) (their text); the marks themselves go.
function MdPdf.runs(s)
    s = s:gsub("%[([^%]]+)%]%(([^)]+)%)", "%1"):gsub("`([^`]+)`", "%1"):gsub("~~(.-)~~", "%1")
    local out = {}
    local bold, italic = false, false
    local buf = {}
    local function flush()
        if #buf > 0 then
            table.insert(out, { text = table.concat(buf), bold = bold, italic = italic })
            buf = {}
        end
    end
    local i, n = 1, #s
    while i <= n do
        local c = s:sub(i, i)
        local prev, nxt3 = s:sub(i - 1, i - 1), s:sub(i, i + 2)
        if nxt3 == "***" or nxt3 == "___" then
            flush()
            bold, italic = not bold, not italic
            i = i + 3
        elseif s:sub(i, i + 1) == "**" or s:sub(i, i + 1) == "__" then
            flush()
            bold = not bold
            i = i + 2
        elseif (c == "*" or c == "_") and (italic or (s:sub(i + 1, i + 1):match("%S") and not prev:match("%w"))) then
            -- A single mark opens italics before a word and closes after one
            -- (snake_case and 2*3 stay as they are).
            local closes = italic and prev:match("%S") and not s:sub(i + 1, i + 1):match("%w")
            if italic and not closes then
                table.insert(buf, c)
            else
                flush()
                italic = not italic
            end
            i = i + 1
        else
            table.insert(buf, c)
            i = i + 1
        end
    end
    flush()
    return out
end

local FONT = { [false] = { [false] = "F1", [true] = "F3" }, [true] = { [false] = "F2", [true] = "F4" } }

-- Styled words in lines at most `max` wide: { { { word, font }... }... }.
-- `force`: a style for all of it ("bold" for headings, "italic" quotes).
local function wrapRuns(s, size, max, force)
    local words = {}
    for _, run in ipairs(MdPdf.runs(s)) do
        local b = run.bold or force == "bold"
        local it = run.italic or force == "italic"
        local text = MdPdf.winAnsi(run.text)
        -- A run starting mid-word joins the word before it.
        local glue = text:sub(1, 1):match("%S") ~= nil and #words > 0 and not words[#words].endSpace
        local first = true
        for space, word, trail in text:gmatch("(%s*)(%S+)(%s*)") do
            local w = { word = word, bold = b, font = FONT[b][it], endSpace = trail ~= "" }
            if first and glue and space == "" then w.glue = true end
            table.insert(words, w)
            first = false
        end
        if #words > 0 and text:match("%s$") then words[#words].endSpace = true end
    end
    local lines, line, lineW = {}, {}, 0
    for _, w in ipairs(words) do
        local ww = width(w.word, size, w.bold)
        local sp = (#line > 0 and not w.glue) and width(" ", size) or 0
        if #line > 0 and lineW + sp + ww > max and not w.glue then
            table.insert(lines, line)
            line, lineW, sp = {}, 0, 0
        end
        -- A word longer than a line is cut.
        while ww > max do
            local cut = #w.word
            while cut > 1 and width(w.word:sub(1, cut), size, w.bold) > max do cut = cut - 1 end
            table.insert(line, { text = w.word:sub(1, cut), font = w.font })
            table.insert(lines, line)
            line, lineW = {}, 0
            w = { word = w.word:sub(cut + 1), bold = w.bold, font = w.font }
            ww = width(w.word, size, w.bold)
        end
        table.insert(line, { text = (sp > 0 and " " or "") .. w.word, font = w.font })
        lineW = lineW + sp + ww
    end
    if #line > 0 or #lines == 0 then table.insert(lines, line) end
    return lines
end

--- A PDF (the file's bytes) of `markdown`. `title`: the document's title.
function MdPdf.render(markdown, title)
    local pages = {}
    local ops, y
    local function newPage()
        ops = {}
        table.insert(pages, ops)
        y = PAGE_H - MARGIN
    end
    newPage()
    local function need(h)
        if y - h < MARGIN then newPage() end
    end
    local function text(x, s, size, font)
        table.insert(ops, string.format("BT /%s %g Tf %.2f %.2f Td (%s) Tj ET", font, size, x, y, escape(s)))
    end
    local function block(s, size, font, indent, before, after, lead)
        local force = font == "F2" and "bold" or (font == "F3" and "italic") or nil
        local x = MARGIN + (indent or 0)
        y = y - (before or 0)
        local lines = wrapRuns(s, size, PAGE_W - MARGIN - x, force)
        for i, l in ipairs(lines) do
            need(size * 1.3)
            y = y - size * 1.3
            if i == 1 and lead then lead(x, y, size) end
            -- One text object per line, the font changing with the style.
            local parts, current, buf = { string.format("BT %.2f %.2f Td", x, y) }, nil, {}
            local function flush()
                if #buf > 0 then table.insert(parts, "(" .. escape(table.concat(buf)) .. ") Tj") end
                buf = {}
            end
            for _, piece in ipairs(l) do
                if piece.font ~= current then
                    flush()
                    table.insert(parts, string.format("/%s %g Tf", piece.font, size))
                    current = piece.font
                end
                table.insert(buf, piece.text)
            end
            flush()
            table.insert(parts, "ET")
            table.insert(ops, table.concat(parts, " "))
        end
        y = y - (after or 0)
    end
    local base = 11
    for raw in (markdown .. "\n"):gmatch("(.-)\r?\n") do
        local line = raw:gsub("%s+$", "")
        local spaces = #(line:match("^(%s*)"))
        local level = math.floor(spaces / 2)
        local s = line:gsub("^%s+", "")
        if s == "" then
            y = y - base * 0.6
        elseif s:match("^#%s") then
            block(s:gsub("^#+%s*", ""), 18, "F2", 0, 10, 4)
        elseif s:match("^##%s") then
            block(s:gsub("^#+%s*", ""), 14, "F2", 0, 8, 2)
        elseif s:match("^###+%s") then
            block(s:gsub("^#+%s*", ""), 12, "F2", 0, 6, 1)
        elseif s:match("^[-*_][-*_][-*_]+$") then
            need(12)
            y = y - 6
            table.insert(ops, string.format("0.6 G 0.8 w %d %.2f m %d %.2f l S 0 G", MARGIN, y, PAGE_W - MARGIN, y))
            y = y - 6
        elseif s:match("^[-*+]%s+%[[ xX]%]%s") then
            local done = s:match("^[-*+]%s+%[([xX])%]") ~= nil
            local body = s:gsub("^[-*+]%s+%[[ xX]%]%s*", "")
            local indent = 12 + level * 16
            block(body, base, "F1", indent + 14, 1, 1, function(x, ly, size)
                local bx, bs = x - 14, size * 0.75
                table.insert(ops, string.format("0.8 w %.2f %.2f %.2f %.2f re S", bx, ly - 1, bs, bs))
                if done then
                    table.insert(ops, string.format("1.2 w %.2f %.2f m %.2f %.2f l %.2f %.2f l S", bx + 1.5, ly + bs * 0.45, bx + bs * 0.4, ly + 1,
                        bx + bs + 1, ly + bs + 1))
                end
            end)
        elseif s:match("^[-*+]%s") then
            local indent = 12 + level * 16
            block(s:gsub("^[-*+]%s+", ""), base, "F1", indent + 10, 1, 1, function(x, ly, size)
                text(x - 10, "\149", size, "F1")
            end)
        elseif s:match("^%d+[.)]%s") then
            local n = s:match("^(%d+[.)])")
            local indent = 12 + level * 16
            block(s:gsub("^%d+[.)]%s+", ""), base, "F1", indent + 16, 1, 1, function(x, ly, size)
                text(x - 16, n, size, "F1")
            end)
        elseif s:match("^>") then
            local top = y
            block(s:gsub("^>%s*", ""), base, "F3", 14, 2, 2)
            table.insert(ops, string.format("0.6 G 2 w %d %.2f m %d %.2f l S 0 G", MARGIN + 4, math.min(top, PAGE_H - MARGIN), MARGIN + 4, y + 2))
        elseif s:match("^|") then
            if not s:match("^|[%s:|-]+|?$") then
                local cells = {}
                for cell in s:gmatch("|([^|]*)") do
                    cell = cell:match("^%s*(.-)%s*$")
                    if cell ~= "" then table.insert(cells, cell) end
                end
                block(table.concat(cells, "    "), base, "F1", 0, 1, 1)
            end
        else
            block(s, base, "F1", 0, 1, 1)
        end
    end
    -- The file: catalog, page tree, three fonts, then each page and its content.
    local objects = {}
    local function add(body)
        table.insert(objects, body)
        return #objects
    end
    add("<< /Type /Catalog /Pages 2 0 R >>")
    add("PAGES")
    for _, name in ipairs({ "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique" }) do
        add("<< /Type /Font /Subtype /Type1 /BaseFont /" .. name .. " /Encoding /WinAnsiEncoding >>")
    end
    local kids = {}
    for _, p in ipairs(pages) do
        local stream = table.concat(p, "\n")
        local content = add(string.format("<< /Length %d >>\nstream\n%s\nendstream", #stream, stream))
        local page = add(string.format("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] "
            .. "/Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R /F4 6 0 R >> >> /Contents %d 0 R >>", PAGE_W, PAGE_H, content))
        table.insert(kids, page .. " 0 R")
    end
    objects[2] = string.format("<< /Type /Pages /Kids [%s] /Count %d >>", table.concat(kids, " "), #kids)
    local info = add(string.format("<< /Title (%s) /Producer (Notes for KOReader) >>", escape(MdPdf.winAnsi(title or "Notes"))))
    local out = { "%PDF-1.4\n%\226\227\207\211\n" }
    local offsets = {}
    local size = #out[1]
    for i, body in ipairs(objects) do
        offsets[i] = size
        local chunk = string.format("%d 0 obj\n%s\nendobj\n", i, body)
        table.insert(out, chunk)
        size = size + #chunk
    end
    local xref = { string.format("xref\n0 %d\n0000000000 65535 f \n", #objects + 1) }
    for i = 1, #objects do table.insert(xref, string.format("%010d 00000 n \n", offsets[i])) end
    table.insert(out, table.concat(xref))
    table.insert(out, string.format("trailer\n<< /Size %d /Root 1 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n", #objects + 1, info, size))
    return table.concat(out), #pages
end

--- How many colour components a JPEG has (1 grey, 3 colour), from its
-- frame header; nil when it is not a JPEG.
function MdPdf.jpegComponents(jpg)
    if jpg:sub(1, 2) ~= "\255\216" then return nil end
    local i = 3
    while i < #jpg do
        if jpg:byte(i) ~= 0xFF then return nil end
        local marker = jpg:byte(i + 1)
        local len = jpg:byte(i + 2) * 256 + jpg:byte(i + 3)
        if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
            return jpg:byte(i + 9)
        end
        i = i + 2 + len
    end
    return nil
end

--- A PDF of pictures (JPEG files' bytes), one a page: { { jpg, w, h }... }
-- (w, h: the picture's pixels). Pages are A5 wide, as tall as the picture
-- needs. Returns the PDF's bytes.
function MdPdf.picturesPdf(pictures, title)
    local objects = {}
    local function add(body)
        table.insert(objects, body)
        return #objects
    end
    add("<< /Type /Catalog /Pages 2 0 R >>")
    add("PAGES")
    local kids = {}
    for _, pic in ipairs(pictures) do
        local pw = PAGE_W
        local ph = math.floor(PAGE_W * pic.h / pic.w + 0.5)
        local space = MdPdf.jpegComponents(pic.jpg) == 1 and "/DeviceGray" or "/DeviceRGB"
        local img = add(string.format("<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace %s "
            .. "/BitsPerComponent 8 /Filter /DCTDecode /Length %d >>\nstream\n%s\nendstream", pic.w, pic.h, space, #pic.jpg, pic.jpg))
        local stream = string.format("q %d 0 0 %d 0 0 cm /Im0 Do Q", pw, ph)
        local content = add(string.format("<< /Length %d >>\nstream\n%s\nendstream", #stream, stream))
        local page = add(string.format("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] /Resources << /XObject << /Im0 %d 0 R >> >> "
            .. "/Contents %d 0 R >>", pw, ph, img, content))
        table.insert(kids, page .. " 0 R")
    end
    objects[2] = string.format("<< /Type /Pages /Kids [%s] /Count %d >>", table.concat(kids, " "), #kids)
    local info = add(string.format("<< /Title (%s) /Producer (Notes for KOReader) >>", escape(MdPdf.winAnsi(title or "Notes"))))
    local out = { "%PDF-1.4\n%\226\227\207\211\n" }
    local offsets, size = {}, #out[1]
    for i, body in ipairs(objects) do
        offsets[i] = size
        local chunk = string.format("%d 0 obj\n%s\nendobj\n", i, body)
        table.insert(out, chunk)
        size = size + #chunk
    end
    local xref = { string.format("xref\n0 %d\n0000000000 65535 f \n", #objects + 1) }
    for i = 1, #objects do table.insert(xref, string.format("%010d 00000 n \n", offsets[i])) end
    table.insert(out, table.concat(xref))
    table.insert(out, string.format("trailer\n<< /Size %d /Root 1 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n", #objects + 1, info, size))
    return table.concat(out)
end

return MdPdf
