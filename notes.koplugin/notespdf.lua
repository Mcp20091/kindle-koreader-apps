--[[--
PDFs to write on: a notebook made from a PDF has its pages as backgrounds
(rendered with KOReader's MuPDF), and can be exported as a copy of the PDF
with the ink added as PDF ink annotations, which other PDF apps show and
can edit.

A PDF page is fitted to the whole screen, centred; ink is in screen
pixels, so `fit` gives where the page lies (and so how ink maps onto it).
]]

local Blitbuffer = require("ffi/blitbuffer")
local DrawContext = require("ffi/drawcontext")
local logger = require("logger")

local Ink = require("notesink")

local PDF = {}

local function open(path)
    local ok, doc = pcall(function() return require("ffi/mupdf").openDocument(path) end)
    if not ok then return nil, doc end
    return doc
end

--- The number of pages of a PDF, or nil and why.
function PDF.pageCount(path)
    local doc, why = open(path)
    if not doc then return nil, why end
    local n = doc:getPages()
    local w, h = 0, 0
    local ok, page = pcall(doc.openPage, doc, 1)
    if ok and page then
        w, h = page:getSize(DrawContext.new(0, 1.0))
        page:close()
    end
    doc:close()
    return n, w, h
end

-- Where a page `pw` x `ph` (points) lies on a `w` x `h` screen: x, y,
-- zoom (pixels per point).
local function fit(pw, ph, w, h)
    local zoom = math.min(w / pw, h / ph)
    return math.floor((w - pw * zoom) / 2), math.floor((h - ph * zoom) / 2), zoom
end

--- A PDF opened for drawing pages again and again (the editor keeps one
-- while a notebook is open). close() when done.
function PDF.open(path)
    local doc, why = open(path)
    if not doc then return nil, why end
    return setmetatable({ doc = doc, path = path }, { __index = PDF })
end

function PDF:close()
    if self.doc then self.doc:close() end
    self.doc = nil
end

--- Page `n` drawn on white, `w` x `h`: a new blitbuffer, or nil and why.
function PDF:render(n, w, h)
    local ok, result = pcall(function()
        local page = self.doc:openPage(n)
        local pw, ph = page:getSize(DrawContext.new(0, 1.0))
        local x, y, zoom = fit(pw, ph, w, h)
        local rendered = page:draw_new(DrawContext.new(0, zoom), math.floor(pw * zoom), math.floor(ph * zoom), 0, 0)
        page:close()
        local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        bb:fill(Blitbuffer.COLOR_WHITE)
        bb:blitFrom(rendered, x, y, 0, 0, rendered:getWidth(), rendered:getHeight())
        rendered:free()
        return bb
    end)
    if not ok then
        logger.warn("Notes: could not draw PDF page", n, result)
        return nil, result
    end
    return result
end

--- Page `n` as a zoomed view shows it, `w` x `h`: the page as `render` fits
-- it, each of its pixels p at vx + p * z (and vy + p * z), drawn sharp at
-- that size. Only what is on screen is drawn. A new blitbuffer, or nil
-- and why.
function PDF:renderZoomed(n, w, h, z, vx, vy)
    local ok, result = pcall(function()
        local page = self.doc:openPage(n)
        local pw, ph = page:getSize(DrawContext.new(0, 1.0))
        local fx, fy, f0 = fit(pw, ph, w, h)
        local zoom = f0 * z
        -- Where the page's corner lands on the screen.
        local ax, ay = math.floor(vx + fx * z), math.floor(vy + fy * z)
        local ox, oy = math.max(0, -ax), math.max(0, -ay)
        local rw = math.min(math.floor(pw * zoom), w - ax) - ox
        local rh = math.min(math.floor(ph * zoom), h - ay) - oy
        local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        bb:fill(Blitbuffer.COLOR_WHITE)
        if rw > 0 and rh > 0 then
            local rendered = page:draw_new(DrawContext.new(0, zoom), rw, rh, ox, oy)
            bb:blitFrom(rendered, ax + ox, ay + oy, 0, 0, rw, rh)
            rendered:free()
        end
        page:close()
        return bb
    end)
    if not ok then
        logger.warn("Notes: could not draw PDF page zoomed", n, result)
        return nil, result
    end
    return result
end

--- The notebook as a copy of its PDF with the ink as ink annotations,
-- written to `dest`. Pages added in Notes (not from the PDF) are left out.
-- `w`, `h`: the notebook's page size in pixels. Returns the number of
-- pages with ink, or nil and why.
function PDF.exportWithInk(src, dest, nb, w, h)
    local doc, why = open(src)
    if not doc then return nil, why end
    local ok, result = pcall(function()
        local inked = 0
        for _, page in ipairs(nb.pages) do
            if page.bg and #page.strokes > 0 then
                local p = doc:openPage(page.bg)
                local pw, ph = p:getSize(DrawContext.new(0, 1.0))
                local ox, oy, zoom = fit(pw, ph, w, h)
                for _, stroke in ipairs(page.strokes) do
                    local points = {}
                    for i = 1, #stroke.p - 1, 2 do
                        table.insert(points, { x = (stroke.p[i] - ox) / zoom, y = (stroke.p[i + 1] - oy) / zoom })
                    end
                    if #points == 1 then table.insert(points, { x = points[1].x + 0.1, y = points[1].y }) end
                    local tip = Ink.tipOf(stroke)
                    local width = 0
                    for _, q in ipairs(stroke.q or { stroke.w }) do width = width + q end
                    width = width / #(stroke.q or { stroke.w }) / zoom
                    local grey = tip.grey
                    p:addInkAnnotation({ points }, { r = grey, g = grey, b = grey }, width, tip.under and 0.45 or 1.0)
                end
                p:close()
                inked = inked + 1
            end
        end
        doc:writeDocument(dest)
        return inked
    end)
    doc:close()
    if not ok then return nil, result end
    return result
end

return PDF
