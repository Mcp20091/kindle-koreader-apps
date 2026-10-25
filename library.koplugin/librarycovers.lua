--[[--
Covers for the Library's pages: the Cover browser's cached cover, scaled to
the size drawn and kept for the pages shown (a few dozen at most, freed when
the Library closes). Books it hasn't read yet are read in the background (its
own child process); the page is drawn again when they're done.
]]

local UIManager = require("ui/uimanager")

local Model = require("librarymodel")

local Covers = {}

local cache, order = {}, {}   -- key -> blitbuffer (false: none), oldest first
local MAX = 48
local queued, waiting = {}, {}
local poll

local function free(key)
    local bb = cache[key]
    if bb then bb:free() end
    cache[key] = nil
end

--- The cover of book b at w × h pixels (fitted inside, its proportions kept), or nil.
function Covers.get(b, w, h)
    local key = b.path .. "@" .. w .. "x" .. h
    local got = cache[key]
    if got ~= nil then return got or nil end
    local bim = Model.bim()
    local bb
    if bim then
        local ok, info = pcall(bim.getBookInfo, bim, b.path, true)
        local src = ok and type(info) == "table" and info.cover_bb or nil
        if src then
            local sw, sh = src:getWidth(), src:getHeight()
            local k = math.min(w / sw, h / sh)
            local tw, th = math.max(1, math.floor(sw * k + 0.5)), math.max(1, math.floor(sh * k + 0.5))
            local RenderImage = require("ui/renderimage")
            local okS, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, src, tw, th, true)
            if okS and scaled then
                bb = scaled
                if scaled ~= src then src:free() end
            else
                bb = src
            end
        end
    end
    cache[key] = bb or false
    table.insert(order, key)
    while #order > MAX do free(table.remove(order, 1)) end
    return bb
end

--- A picture file (a cover found online) at w × h pixels, fitted inside, or nil.
function Covers.file(file, w, h)
    local key = "file:" .. file .. "@" .. w .. "x" .. h
    local got = cache[key]
    if got ~= nil then return got or nil end
    local RenderImage = require("ui/renderimage")
    local ok, src = pcall(RenderImage.renderImageFile, RenderImage, file, false)
    local bb
    if ok and src then
        local sw, sh = src:getWidth(), src:getHeight()
        local k = math.min(w / sw, h / sh)
        local okS, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, src,
            math.max(1, math.floor(sw * k + 0.5)), math.max(1, math.floor(sh * k + 0.5)), true)
        bb = okS and scaled or src
    end
    cache[key] = bb or false
    table.insert(order, key)
    while #order > MAX do free(table.remove(order, 1)) end
    return bb
end

--- A book's covers kept, dropped (its cover changed).
function Covers.forget(path)
    local prefix = path .. "@"
    for i = #order, 1, -1 do
        if order[i]:sub(1, #prefix) == prefix then
            free(order[i])
            table.remove(order, i)
        end
    end
end

--- All covers kept, freed (the Library closed).
function Covers.release()
    for key in pairs(cache) do free(key) end
    cache, order = {}, {}
end

--- A book the Cover browser hasn't read: read in the background; redraw() when done.
function Covers.want(b, redraw)
    if queued[b.path] then return end
    if Model.info(b.path) then return end
    local bim = Model.bim()
    if not bim then return end
    queued[b.path] = true
    table.insert(waiting, b.path)
    Covers.redraw = redraw
    if not poll then
        poll = true
        -- (on the next tick: a page asks for its covers as it is drawn, then they go together)
        UIManager:nextTick(function() Covers.start() end)
    end
end

-- Size the cache keeps covers at: big enough for a book's page.
local function specs()
    local Screen = require("device").screen
    local u = math.min(Screen:getWidth(), Screen:getHeight()) / 620
    return { max_cover_w = math.floor(140 * u), max_cover_h = math.floor(210 * u) }
end

function Covers.start()
    local bim = Model.bim()
    if not bim or #waiting == 0 then poll = nil return end
    local files = {}
    local sp = specs()
    for __, p in ipairs(waiting) do table.insert(files, { filepath = p, cover_specs = sp }) end
    local list = waiting
    waiting = {}
    local ok = pcall(bim.extractInBackground, bim, files)
    if not ok then poll = nil return end
    local tries = 0
    local function check()
        tries = tries + 1
        local busy = false
        pcall(function() busy = bim:isExtractingInBackground() end)
        if busy and tries < 120 then
            UIManager:scheduleIn(1.5, check)
            return
        end
        for __, p in ipairs(list) do
            queued[p] = nil
            Model.forget(p)
            -- (the covers drawn as missing are looked for again)
            for key in pairs(cache) do
                if key:sub(1, #p + 1) == p .. "@" and cache[key] == false then cache[key] = nil end
            end
        end
        poll = nil
        if #waiting > 0 then
            poll = true
            UIManager:nextTick(function() Covers.start() end)
        end
        if Covers.redraw then Covers.redraw() end
    end
    UIManager:scheduleIn(1.5, check)
end

--- Stops reading covers (the Library closed).
function Covers.stop()
    waiting = {}
    Covers.redraw = nil
end

return Covers
