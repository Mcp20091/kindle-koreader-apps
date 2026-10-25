--[[--
Sending notebooks to OneNote over Microsoft Graph: each notebook becomes a
section of the OneNote notebook picked in the settings, each page a OneNote
page holding the page as a PNG image (OneNote makes handwriting in images
searchable). Pages already sent are updated in place when they change and
deleted when the page is. And reading OneNote: notebooks, sections, pages,
a page's HTML and handwriting (InkML), turned into text boxes, pictures and
strokes (OneNote.layout, OneNote.inkStrokes) or a page to read.

The sign-in is the device-code one the To Do plugin uses (a code entered on a
phone or computer), with the Notes.ReadWrite scope.

Network, JSON, hashing and page images are passed in, so the tests run it
without KOReader; main.lua passes KOReader's.
]]

local OneNote = {}
OneNote.__index = OneNote

local GRAPH = "https://graph.microsoft.com/v1.0"
local LOGIN = "https://login.microsoftonline.com/%s/oauth2/v2.0/"
local SCOPE = "Notes.ReadWrite offline_access"
-- What the shared Microsoft account must allow for OneNote (the launcher's PS.microsoft).
OneNote.ACCOUNT_SCOPE = "Notes.ReadWrite"
local BOUNDARY = "NotesKoreaderPart7d1c"
OneNote.IMAGE_ID = "notes-page"
OneNote.IMAGE_WIDTH = 930            -- how wide OneNote shows the page (half the Scribe's pixels)

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function form(fields)
    local parts = {}
    for k, v in pairs(fields) do table.insert(parts, urlencode(k) .. "=" .. urlencode(v)) end
    table.sort(parts)
    return table.concat(parts, "&")
end

local function escapeHtml(s)
    return (tostring(s):gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

--- options: tokens (get(key), set(key, value), save()), clientId,
-- request(method, url, headers, body) returning (status number or error
-- string, body string), json (encode, decode), now() (seconds).
function OneNote.new(options)
    local self = setmetatable({}, OneNote)
    self.tokens = options.tokens
    self.clientId = options.clientId
    self.request = options.request
    self.json = options.json
    self.now = options.now or os.time
    -- The launcher's shared Microsoft account (PS.microsoft), when there is
    -- one: it then answers the sign-in and the tokens instead of `tokens`.
    self.account = options.account
    return self
end

function OneNote:decode(body)
    if not body or body == "" then return nil end
    local ok, value = pcall(self.json.decode, body)
    if ok and type(value) == "table" then return value end
    return nil
end

-- ------------------------------------------------------------------ sign-in

--- Signed in, and (with the shared account) allowed to use OneNote.
function OneNote:signedIn()
    if self.account then return self.account.signedIn() and self.account.allowed(OneNote.ACCOUNT_SCOPE) end
    return self.tokens.get("refresh_token") ~= nil
end

--- Signed in to the shared account, but not yet for OneNote (To Do's
-- sign-in from before): signing in again covers both.
function OneNote:needsAllow()
    return self.account ~= nil and self.account.signedIn() and not self.account.allowed(OneNote.ACCOUNT_SCOPE)
end

function OneNote:signOut()
    if self.account then return self.account.signOut() end
    for __, key in ipairs({ "refresh_token", "access_token", "expires_at", "authority" }) do self.tokens.set(key, nil) end
    self.tokens.save()
end

function OneNote:postForm(authority, endpoint, fields)
    local status, body = self.request("POST", string.format(LOGIN, authority) .. endpoint,
        { ["Content-Type"] = "application/x-www-form-urlencoded" }, form(fields))
    return status, self:decode(body)
end

--- Starts a sign-in: { user_code, verification_uri, device_code, interval,
-- expires_in, authority } or nil and why. Apps for personal accounts only
-- must use /consumers (AADSTS9002331): tried when /common says so.
function OneNote:startSignIn()
    if self.account then return self.account.startSignIn() end
    if not self.clientId or self.clientId == "" then return nil, "No app ID set" end
    for __, authority in ipairs({ "common", "consumers" }) do
        local status, data = self:postForm(authority, "devicecode", { client_id = self.clientId, scope = SCOPE })
        if type(status) ~= "number" then return nil, OneNote.connectionError(status) end
        if status == 200 and data and data.device_code then
            data.authority = authority
            return data
        end
        local why = data and (data.error_description or data.error) or ("HTTP " .. status)
        if not tostring(why):find("AADSTS9002331", 1, true) then return nil, why end
    end
    return nil, "Sign-in refused"
end

function OneNote:keepTokens(data, authority)
    self.tokens.set("access_token", data.access_token)
    if data.refresh_token then self.tokens.set("refresh_token", data.refresh_token) end
    self.tokens.set("expires_at", self.now() + (tonumber(data.expires_in) or 3600))
    if authority then self.tokens.set("authority", authority) end
    self.tokens.save()
end

--- One poll of a sign-in: "ok", "pending", "slow_down", "expired" or
-- "error" (with why).
function OneNote:pollSignIn(signIn)
    if self.account then return self.account.pollSignIn(signIn) end
    local status, data = self:postForm(signIn.authority, "token", {
        grant_type = "urn:ietf:params:oauth:grant-type:device_code",
        client_id = self.clientId,
        device_code = signIn.device_code,
    })
    if type(status) ~= "number" then return "pending" end
    if status == 200 and data and data.access_token then
        self:keepTokens(data, signIn.authority)
        return "ok"
    end
    local err = data and data.error or ""
    if err == "authorization_pending" then return "pending" end
    if err == "slow_down" then return "slow_down" end
    if err == "expired_token" or err == "code_expired" then return "expired" end
    return "error", data and (data.error_description or err) or ("HTTP " .. status)
end

function OneNote:accessToken(force)
    if self.account then return self.account.accessToken(force) end
    local token = self.tokens.get("access_token")
    if not force and token and (self.tokens.get("expires_at") or 0) > self.now() + 60 then return token end
    local refresh = self.tokens.get("refresh_token")
    if not refresh then return nil, "Not signed in" end
    local status, data = self:postForm(self.tokens.get("authority") or "common", "token", {
        grant_type = "refresh_token", client_id = self.clientId, refresh_token = refresh, scope = SCOPE,
    })
    if type(status) ~= "number" then return nil, OneNote.connectionError(status) end
    if status == 200 and data and data.access_token then
        self:keepTokens(data)
        return data.access_token
    end
    if data and (data.error == "invalid_grant" or data.error == "interaction_required") then
        self:signOut()
        return nil, "Signed out by Microsoft: sign in again"
    end
    return nil, data and (data.error_description or data.error) or ("HTTP " .. status)
end

--- A Graph call: `body` a table (JSON) or { type = ..., data = ... }.
-- Returns status (or nil) and the decoded reply (or why it failed).
--- A network failure in words: a timeout ("wantread"/"timeout" from LuaSec)
-- or no connection at all.
function OneNote.connectionError(status)
    local s = tostring(status)
    if s:find("wantread") or s:find("wantwrite") or s:find("timeout") then
        return "Microsoft took too long to answer. Check Wi-Fi and try again."
    end
    return "No connection: " .. s
end

function OneNote:graph(method, path, body)
    local url = path:sub(1, 8) == "https://" and path or GRAPH .. path
    local text, kind
    if type(body) == "table" and body.data then
        text, kind = body.data, body.type
    elseif body then
        text, kind = self.json.encode(body), "application/json"
    end
    for attempt = 1, 2 do
        local token, why = self:accessToken(attempt == 2)
        if not token then return nil, why end
        local headers = { Authorization = "Bearer " .. token }
        if kind then headers["Content-Type"] = kind end
        local status, reply = self.request(method, url, headers, text)
        if type(status) ~= "number" then return nil, OneNote.connectionError(status) end
        if status ~= 401 then
            local data = self:decode(reply)
            if status >= 200 and status < 300 then return status, data end
            local err = data and data.error and (data.error.message or data.error.code)
            return status, err or ("HTTP " .. status)
        end
    end
    return 401, "Microsoft refused the sign-in"
end

-- ------------------------------------------------------------------ OneNote's notebooks and sections

--- The user's OneNote notebooks: { { id, name }... } or nil and why.
function OneNote:notebooks()
    local status, data = self:graph("GET", "/me/onenote/notebooks?$select=id,displayName&$orderby=displayName")
    if status ~= 200 then return nil, data end
    local out = {}
    for __, n in ipairs(data.value or {}) do table.insert(out, { id = n.id, name = n.displayName }) end
    return out
end

function OneNote:createNotebook(name)
    local status, data = self:graph("POST", "/me/onenote/notebooks", { displayName = name })
    if status ~= 201 and status ~= 200 then return nil, data end
    return { id = data.id, name = data.displayName }
end

--- A name OneNote takes for a section: none of ? * / : < > | & # ' % ~ \ "
-- and at most 50 characters.
function OneNote.sectionName(name)
    local s = tostring(name or ""):gsub("[%?%*/:<>|&#'%%~\\\"]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if #s > 50 then s = s:sub(1, 50):match("^(.-)%s*$") end
    if s == "" then s = "Notebook" end
    return s
end

--- The section for a notebook: the one sent to before, else one of that
-- name, else a new one. Returns its id or nil and why.
function OneNote:section(oneNoteNotebook, name, knownId)
    local status, data = self:graph("GET", "/me/onenote/notebooks/" .. oneNoteNotebook .. "/sections?$select=id,displayName")
    if status ~= 200 then return nil, data end
    local wanted = OneNote.sectionName(name)
    for __, s in ipairs(data.value or {}) do
        if s.id == knownId then return s.id end
    end
    for __, s in ipairs(data.value or {}) do
        if s.displayName == wanted then return s.id end
    end
    status, data = self:graph("POST", "/me/onenote/notebooks/" .. oneNoteNotebook .. "/sections", { displayName = wanted })
    if status ~= 201 and status ~= 200 then return nil, data end
    return data.id
end

--- Where a notebook goes (`targets`: { ["n:<id>"] or ["f:<folder>"] = { nb,
-- sec } }): its own choice, else its folder's or a folder's above
-- (`folder`, `parent(path)`), else `default` (a OneNote notebook). Returns
-- { nb, sec } or nil, and "notebook", "folder" or nil.
function OneNote.targetFor(targets, id, folder, parent, default)
    if targets["n:" .. id] then return targets["n:" .. id], "notebook" end
    while folder and folder ~= "" do
        if targets["f:" .. folder] then return targets["f:" .. folder], "folder" end
        folder = parent(folder)
    end
    return default and { nb = default } or nil, nil
end

--- `targets` with a folder's choices (its own and its subfolders') moved
-- from path `from` to `to` (renamed or moved).
function OneNote.moveTargets(targets, from, to)
    local moved = {}
    for key, t in pairs(targets) do
        local path = key:match("^f:(.*)$")
        if path and (path == from or path:sub(1, #from + 1) == from .. "/") then
            moved["f:" .. to .. path:sub(#from + 1)] = t
            targets[key] = nil
        end
    end
    for key, t in pairs(moved) do targets[key] = t end
    return targets
end

--- A section chosen by id: its id when it's still in OneNote, else nil
-- and why.
function OneNote:sectionThere(id)
    local status, data = self:graph("GET", "/me/onenote/sections/" .. id .. "?$select=id")
    if status == 200 then return id end
    if status == 404 then return nil, "The OneNote section chosen for it is gone: hold the notebook or its folder and pick another." end
    return nil, data
end

-- ------------------------------------------------------------------ pages

local function part(name, kind, data)
    return "--" .. BOUNDARY .. "\r\nContent-Disposition: form-data; name=\"" .. name .. "\"\r\nContent-Type: "
        .. kind .. "\r\n\r\n" .. data .. "\r\n"
end

local function multipart(parts)
    return { type = "multipart/form-data; boundary=" .. BOUNDARY, data = table.concat(parts) .. "--" .. BOUNDARY .. "--\r\n" }
end

OneNote.TEXT_ID = "notes-text"

-- Typed text (Claude's reading of the page) as a paragraph under the image.
function OneNote.textTag(text)
    local lines = {}
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do table.insert(lines, escapeHtml(line)) end
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    return '<p data-id="' .. OneNote.TEXT_ID .. '">' .. table.concat(lines, "<br/>") .. "</p>"
end

function OneNote.imageTag(alt)
    return string.format('<img src="name:page" data-id="%s" width="%d" alt="%s" />', OneNote.IMAGE_ID, OneNote.IMAGE_WIDTH, escapeHtml(alt))
end

--- The body that creates a page: its title, the image, and its text if any.
function OneNote.pageBody(title, png, created, text)
    local html = "<!DOCTYPE html><html><head><title>" .. escapeHtml(title) .. "</title>"
        .. (created and ('<meta name="created" content="' .. created .. '" />') or "")
        .. "</head><body>" .. OneNote.imageTag(title) .. (text and OneNote.textTag(text) or "") .. "</body></html>"
    return multipart({ part("Presentation", "text/html", html), part("page", "image/png", png) })
end

--- The body that changes a page sent before: its image, title and text
-- (`hadText`: the page has a text paragraph already).
function OneNote.updateBody(title, png, json, text, hadText)
    local commands = {
        { target = "#" .. OneNote.IMAGE_ID, action = "replace", content = OneNote.imageTag(title) },
        { target = "title", action = "replace", content = escapeHtml(title) },
    }
    if hadText then
        table.insert(commands, { target = "#" .. OneNote.TEXT_ID, action = "replace", content = OneNote.textTag(text or "") })
    elseif text then
        table.insert(commands, { target = "body", action = "append", content = OneNote.textTag(text) })
    end
    commands = json.encode(commands)
    return multipart({ part("Commands", "application/json", commands), part("page", "image/png", png) })
end

--- The body of a page made of several pictures (one per Notes page), in order.
function OneNote.pagesBody(title, pngs, created)
    local html = { "<!DOCTYPE html><html><head><title>" .. escapeHtml(title) .. "</title>"
        .. (created and ('<meta name="created" content="' .. created .. '" />') or "") .. "</head><body>" }
    local parts = {}
    for i, png in ipairs(pngs) do
        table.insert(html, string.format('<img src="name:page%d" width="%d" alt="%s" />', i, OneNote.IMAGE_WIDTH, escapeHtml(title)))
        table.insert(parts, part("page" .. i, "image/png", png))
    end
    table.insert(html, "</body></html>")
    table.insert(parts, 1, part("Presentation", "text/html", table.concat(html)))
    return multipart(parts)
end

--- A page of several pictures made in a section: its id, or nil and why.
function OneNote:createPictures(sectionId, title, pngs, created)
    local status, data = self:graph("POST", "/me/onenote/sections/" .. sectionId .. "/pages", OneNote.pagesBody(title, pngs, created))
    if status ~= 201 and status ~= 200 then return nil, data end
    return data.id
end

function OneNote:createPage(sectionId, title, png, created, text)
    local status, data = self:graph("POST", "/me/onenote/sections/" .. sectionId .. "/pages", OneNote.pageBody(title, png, created, text))
    if status ~= 201 and status ~= 200 then return nil, data end
    return data.id
end

--- true, or false and why; "gone" when the page is no longer in OneNote.
function OneNote:updatePage(pageId, title, png, text, hadText)
    local status, data = self:graph("PATCH", "/me/onenote/pages/" .. pageId .. "/content", OneNote.updateBody(title, png, self.json, text, hadText))
    if status == 204 or status == 200 then return true end
    if status == 404 then return false, "gone" end
    return false, data
end

function OneNote:deletePage(pageId)
    local status, data = self:graph("DELETE", "/me/onenote/pages/" .. pageId)
    if status == 204 or status == 404 then return true end
    return false, data
end

-- ------------------------------------------------------------------ what to send

--- What sending a notebook takes, given what was sent before (`sent`: {
-- section, pages = { [pageId] = { id, hash, n } } }) and each page's
-- current hash (`hashes[i]`): { create = { i... }, update = { i... },
-- delete = { onenoteId... } }. A page is updated when its ink or its place
-- (its title, "Page n") changed.
function OneNote.plan(nb, sent, hashes)
    local out = { create = {}, update = {}, delete = {} }
    local pages = sent and sent.pages or {}
    local present = {}
    for i, page in ipairs(nb.pages) do
        present[page.id] = true
        local was = pages[page.id]
        if not was then
            table.insert(out.create, i)
        elseif was.hash ~= hashes[i] or was.n ~= i then
            table.insert(out.update, i)
        end
    end
    local gone = {}
    for pageId, was in pairs(pages) do
        if not present[pageId] then table.insert(gone, was) end
    end
    table.sort(gone, function(a, b) return (a.n or 0) < (b.n or 0) end)
    for __, was in ipairs(gone) do table.insert(out.delete, was.id) end
    return out
end

--- Sends a notebook. `options`: oneNoteNotebook (id), sent (as for plan;
-- changed in place), hash(page) and png(index) (the page image's bytes),
-- created (ISO time), text(index) (typed text for the page, or nil: no
-- text paragraph). Returns counts { created, updated, deleted } or nil
-- and why (what was sent before the failure is kept in `sent`).
function OneNote:send(nb, options)
    local sent = options.sent
    sent.pages = sent.pages or {}
    -- A section chosen for it (still there?), else one of its own name.
    local section, why
    if options.sectionId then
        section, why = self:sectionThere(options.sectionId)
    else
        section, why = self:section(options.oneNoteNotebook, nb.name, sent.section)
    end
    if not section then return nil, why end
    if sent.section ~= section then
        -- A new section (the old one was deleted in OneNote): every page again.
        sent.section = section
        sent.pages = {}
    end
    local hashes = {}
    for i, page in ipairs(nb.pages) do hashes[i] = options.hash(page) end
    local plan = OneNote.plan(nb, sent, hashes)
    local counts = { created = 0, updated = 0, deleted = 0 }
    local function title(i) return (options.titlePrefix and (options.titlePrefix .. " – ") or "") .. "Page " .. i end
    for __, i in ipairs(plan.update) do
        local page = nb.pages[i]
        local text = options.text and options.text(i)
        local was = sent.pages[page.id]
        local ok, err = self:updatePage(was.id, title(i), options.png(i), text, was.text)
        if ok then
            sent.pages[page.id] = { id = was.id, hash = hashes[i], n = i, text = (was.text or text ~= nil) or nil }
            counts.updated = counts.updated + 1
        elseif err == "gone" then
            sent.pages[page.id] = nil
            table.insert(plan.create, i)
        else
            return nil, err
        end
    end
    table.sort(plan.create)
    for __, i in ipairs(plan.create) do
        local page = nb.pages[i]
        local text = options.text and options.text(i)
        local id, err = self:createPage(section, title(i), options.png(i), options.created, text)
        if not id then return nil, err end
        sent.pages[page.id] = { id = id, hash = hashes[i], n = i, text = text ~= nil or nil }
        counts.created = counts.created + 1
    end
    for __, pageId in ipairs(plan.delete) do
        local ok, err = self:deletePage(pageId)
        if not ok then return nil, err end
        for k, was in pairs(sent.pages) do
            if was.id == pageId then sent.pages[k] = nil end
        end
        counts.deleted = counts.deleted + 1
    end
    sent.at = self.now()
    return counts
end

-- ------------------------------------------------------------------ reading OneNote

--- A Graph GET returning the reply as it came (a page's HTML, a picture):
-- status and body, or nil/status and why.
function OneNote:fetch(path)
    local url = path:sub(1, 8) == "https://" and path or GRAPH .. path
    for attempt = 1, 2 do
        local token, why = self:accessToken(attempt == 2)
        if not token then return nil, why end
        local status, reply = self.request("GET", url, { Authorization = "Bearer " .. token }, nil)
        if type(status) ~= "number" then return nil, OneNote.connectionError(status) end
        if status ~= 401 then
            if status >= 200 and status < 300 then return status, reply end
            local data = self:decode(reply)
            return status, data and data.error and (data.error.message or data.error.code) or ("HTTP " .. status)
        end
    end
    return 401, "Microsoft refused the sign-in"
end

--- A OneNote notebook's sections, those in section groups too ("Group /
-- Section"): { { id, name }... } or nil and why.
function OneNote:sections(notebookId)
    local status, data = self:graph("GET", "/me/onenote/notebooks/" .. notebookId
        .. "/sections?$select=id,displayName&$orderby=displayName")
    if status ~= 200 then return nil, data end
    local out = {}
    for __, s in ipairs(data.value or {}) do table.insert(out, { id = s.id, name = s.displayName }) end
    status, data = self:graph("GET", "/me/onenote/notebooks/" .. notebookId
        .. "/sectionGroups?$select=id,displayName&$expand=sections($select=id,displayName)")
    if status == 200 then
        for __, g in ipairs(data.value or {}) do
            for __, s in ipairs(g.sections or {}) do
                table.insert(out, { id = s.id, name = (g.displayName or "") .. " / " .. (s.displayName or "") })
            end
        end
    end
    return out
end

--- A section's pages, changed last first: { { id, title, modified } } or
-- nil and why.
function OneNote:pages(sectionId)
    local status, data = self:graph("GET", "/me/onenote/sections/" .. sectionId
        .. "/pages?$select=id,title,lastModifiedDateTime&$orderby=lastModifiedDateTime%20desc&$top=100")
    if status ~= 200 then return nil, data end
    local out = {}
    for __, p in ipairs(data.value or {}) do
        -- (Ink in a title comes as U+FFFC, "object" marks: left out.)
        local title = tostring(p.title or ""):gsub("\239\191\188", ""):match("^%s*(.-)%s*$")
        table.insert(out, { id = p.id, title = title ~= "" and title or nil, modified = p.lastModifiedDateTime })
    end
    return out
end

--- A page's HTML and its handwriting (InkML, or nil), or nil and why.
function OneNote:pageContent(pageId)
    local status, body = self:fetch("/me/onenote/pages/" .. pageId .. "/content?includeinkML=true")
    if status ~= 200 then return nil, body end
    local parts = OneNote.multipart(body)
    if not parts then return body, nil end
    local html, ink
    for __, p in ipairs(parts) do
        if p.type:find("html", 1, true) then html = p.body
        elseif p.type:find("inkml", 1, true) then ink = p.body end
    end
    return html or body, ink
end

--- The parts of a multipart reply ({ type, body }...), or nil when it isn't one.
function OneNote.multipart(body)
    local boundary = tostring(body or ""):match("^%s*%-%-([^\r\n]+)")
    if not boundary then return nil end
    boundary = boundary:gsub("%s+$", "")
    local delim = "--" .. boundary
    local parts = {}
    local s, e = body:find(delim, 1, true)
    while s do
        if body:sub(e + 1, e + 2) == "--" then break end
        local nextS, nextE = body:find(delim, e + 1, true)
        local chunk = body:sub(e + 1, (nextS or #body + 1) - 1)
        local head, content = chunk:match("^\r?\n(.-)\r?\n\r?\n(.*)$")
        if head then
            content = content:gsub("\r?\n$", "")
            table.insert(parts, { type = (head:match("[Cc]ontent%-[Tt]ype:%s*([^\r\n;]+)") or ""):lower(), body = content })
        end
        s, e = nextS, nextE
    end
    return parts
end

local HIMETRIC = 2540 / 96    -- himetric (0.01 mm) per CSS pixel

local function attrs(tag)
    local out = {}
    for k, v in tag:gmatch('([%w:_%-]+)%s*=%s*"([^"]*)"') do out[k] = v end
    return out
end

-- An InkML trace's points (with the format's "'" and '"' differences).
local function tracePoints(text)
    local pts = {}
    local mode, last, vel = {}, {}, {}
    for point in text:gmatch("[^,]+") do
        local vals, ch = {}, 0
        for prefix, num in point:gmatch("([!'\"]?)%s*([%-%+]?%d*%.?%d+)") do
            ch = ch + 1
            if prefix ~= "" then mode[ch] = prefix end
            local m = mode[ch] or "!"
            local v = tonumber(num) or 0
            if m == "!" then
                vel[ch], last[ch] = 0, v
            elseif m == "'" then
                vel[ch] = v
                last[ch] = (last[ch] or 0) + v
            else
                vel[ch] = (vel[ch] or 0) + v
                last[ch] = (last[ch] or 0) + vel[ch]
            end
            vals[ch] = last[ch]
        end
        if vals[1] and vals[2] then table.insert(pts, vals) end
    end
    return pts
end

--- Handwriting from OneNote (InkML) as strokes in CSS pixels:
-- { { p = { x, y, ... }, w = width, grey = 0..255, hl = true for a
-- highlighter }... }.
function OneNote.inkStrokes(inkml)
    local out = {}
    if not inkml or inkml == "" then return out end
    local brushes = {}
    for tag, inner in inkml:gmatch("<inkml:brush(%s[^>]*)>(.-)</inkml:brush>") do
        local id = attrs(tag)["xml:id"]
        if id then
            local b = {}
            for prop in inner:gmatch("<inkml:brushProperty(%s[^>]*)/?>") do
                local a = attrs(prop)
                if a.name then b[a.name] = a.value end
            end
            brushes["#" .. id] = b
        end
    end
    for tag, text in inkml:gmatch("<inkml:trace(%s[^>]*)>(.-)</inkml:trace>") do
        local a = attrs(tag)
        local b = brushes[a.brushRef or ""] or {}
        local pts = tracePoints(text)
        if #pts > 0 then
            local p = {}
            for __, v in ipairs(pts) do
                table.insert(p, v[1] / HIMETRIC)
                table.insert(p, v[2] / HIMETRIC)
            end
            local grey = 0
            local hex = tostring(b.color or ""):match("^#(%x%x%x%x%x%x)")
            if hex then
                local r, g, bl = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
                grey = math.floor(0.3 * r + 0.59 * g + 0.11 * bl + 0.5)
            end
            table.insert(out, { p = p, w = math.max(0.5, (tonumber(b.width) or 53) / HIMETRIC), grey = grey,
                hl = (tonumber(b.transparency) or 0) > 0 or b.tip == "rectangle" or nil })
        end
    end
    return out
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

-- A character's UTF-8 bytes (for &#8217; and the like).
local function utf8char(n)
    if not n or n < 0 then return "" end
    if n == 160 then return " " end
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40) end
    if n < 0x10000 then
        return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
    end
    return string.char(0xF0 + math.floor(n / 0x40000), 0x80 + math.floor(n / 0x1000) % 0x40,
        0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
end

--- HTML into plain text: paragraphs and list items on their own lines, a
-- list inside a list indented.
function OneNote.htmlText(html)
    local out, depth, pos = {}, 0, 1
    html = tostring(html or "")
    while true do
        local s, e, slash, name = html:find("<(/?)([%a!][%w%-]*)[^>]*>", pos)
        -- Text between tags: its spaces and line breaks as one space (as a browser shows it).
        table.insert(out, (html:sub(pos, (s or #html + 1) - 1):gsub("%s+", " ")))
        if not s then break end
        name = name:lower()
        if name == "ul" or name == "ol" then
            depth = math.max(0, depth + (slash == "" and 1 or -1))
        elseif name == "li" and slash == "" then
            table.insert(out, "\n" .. string.rep("    ", math.max(0, depth - 1)) .. "• ")
        elseif name == "br" or (slash == "/" and (name == "p" or name == "tr" or name:match("^h%d$") or name == "cite")) then
            table.insert(out, "\n")
        elseif slash == "/" and name == "td" then
            table.insert(out, "  ")
        end
        pos = e + 1
    end
    local s = table.concat(out)
    s = s:gsub("&#[xX](%x+);", function(n) return utf8char(tonumber(n, 16)) end)
        :gsub("&#(%d+);", function(n) return utf8char(tonumber(n)) end)
        :gsub("&(%a+);", function(e) return ENTITIES[e] or ("&" .. e .. ";") end)
    s = s:gsub("[ \t]+\n", "\n"):gsub("\n +([^ •])", "\n%1"):gsub("\n%s*\n%s*\n+", "\n\n")
    -- (No "• " left alone where a list item held only a paragraph, and no
    -- blank line before a list item.)
    s = s:gsub("(•) \n+(%s*)", "%1 "):gsub("\n[ \t]*\n([ \t]*•)", "\n%1")
    return (s:match("^%s*(.-)%s*$"))
end

local function px(style, key)
    local v = style and style:match(key .. "%s*:%s*(%-?[%d%.]+)px")
    return tonumber(v)
end

--- Where things are on a OneNote page (CSS pixels): text boxes
-- { x, y, w, text, size } and pictures { x, y, w, h, src }, and its title.
function OneNote.layout(html)
    html = tostring(html or "")
    local title = OneNote.htmlText(html:match("<title>(.-)</title>") or ""):gsub("\239\191\188", "")
    local body = html:match("<body[^>]*>(.*)</body>") or html
    -- The page's own text size (OneNote's default 11 pt).
    local basePt = tonumber((html:match("<body([^>]*)>") or ""):match("font%-size%s*:%s*([%d%.]+)pt")) or 11
    local texts, images = {}, {}
    local function picture(tag, x, y)
        local a = attrs(tag)
        local style = a.style or ""
        local w = tonumber(a.width) or px(style, "width")
        local h = tonumber(a.height) or px(style, "height")
        local src = a["data-fullres-src"] or a.src
        if src and w and h then table.insert(images, { x = x, y = y, w = w, h = h, src = src }) end
        return h or 0
    end
    -- The top level's boxes (div, img) one by one, with their positions.
    local pos, flowY = 1, 0
    while true do
        local s, e, slash, name, tag = body:find("<(/?)(%a+%d?)([^>]*)>", pos)
        if not s then break end
        name = name:lower()
        if slash == "" and name == "img" then
            local style = attrs(tag).style or ""
            local x, y = px(style, "left") or 0, px(style, "top") or flowY
            flowY = math.max(flowY, y + picture(tag, x, y) + 10)
            pos = e + 1
        elseif slash == "" and (name == "div" or name == "p" or name == "ul" or name == "ol" or name == "table" or name:match("^h%d$")) then
            -- The box's inside, to its own closing tag.
            local depth, q, inner = 1, e + 1, nil
            while depth > 0 do
                local s2, e2, sl2, n2 = body:find("<(/?)(%a+%d?)[^>]*>", q)
                if not s2 then
                    inner = body:sub(e + 1)
                    q = #body + 1
                    break
                end
                if n2:lower() == name then depth = depth + (sl2 == "" and 1 or -1) end
                if depth == 0 then inner = body:sub(e + 1, s2 - 1) end
                q = e2 + 1
            end
            local style = attrs(tag).style or ""
            local x, y = px(style, "left") or 0, px(style, "top") or flowY
            local w = px(style, "width") or 624
            local whole = name == "div" and inner or ("<" .. name .. tag .. ">" .. (inner or "") .. "</" .. name .. ">")
            local text = OneNote.htmlText(whole)
            local pt = tonumber(style:match("font%-size%s*:%s*([%d%.]+)pt")) or basePt
            local size = pt * 96 / 72
            local h = 0
            if text ~= "" then
                table.insert(texts, { x = x, y = y, w = w, text = text, size = size })
                local lines = 1
                for __ in text:gmatch("\n") do lines = lines + 1 end
                h = lines * size * 1.4
            end
            -- Pictures inside the box: below its text.
            local iy = y + h
            for itag in (whole or ""):gmatch("<[Ii][Mm][Gg](%s[^>]*)>") do
                iy = iy + picture(itag, x, iy) + 8
            end
            flowY = math.max(flowY, iy + 10)
            pos = q
        else
            pos = e + 1
        end
    end
    return { title = title, texts = texts, images = images }
end

--- The page as a web page to read in KOReader: its pictures from `local`
-- (src → file name), no fixed positions (the text flows), the title on
-- top, and a note when it has handwriting.
function OneNote.readableHtml(html, localNames, hasInk)
    html = tostring(html or "")
    local title = OneNote.htmlText(html:match("<title>(.-)</title>") or "")
    local body = html:match("<body[^>]*>(.*)</body>") or html
    -- OneNote's fixed places, widths and sizes out: the reader's own text
    -- size and margins (bold, italics, colours and the like stay).
    body = body:gsub('style="([^"]*)"', function(st)
        st = st:gsub("position%s*:[^;]*;?", ""):gsub("left%s*:[^;]*;?", ""):gsub("top%s*:[^;]*;?", "")
            :gsub("width%s*:[^;]*;?", ""):gsub("font%-size%s*:[^;]*;?", ""):gsub("font%-family%s*:[^;]*;?", "")
            :gsub("margin[%-%a]*%s*:[^;]*;?", "")
        return 'style="' .. st .. '"'
    end)
    body = body:gsub("<[Ii][Mm][Gg](%s[^>]*)>", function(tag)
        local a = attrs(tag)
        local name = localNames[a["data-fullres-src"] or ""] or localNames[a.src or ""]
        if not name then return "" end
        local w = tonumber(a.width)
        return string.format('<img src="%s"%s/>', name, w and string.format(' style="max-width:100%%;width:%dpx"', w) or "")
    end)
    local note = hasInk and '<p style="border:1px solid #888;padding:0.4em"><i>This page has handwriting, which isn\'t shown here. '
        .. "In Notes, choose Download to edit to see and change it.</i></p>" or ""
    return '<!DOCTYPE html><html><head><meta charset="utf-8"/><title>' .. escapeHtml(title) .. "</title>"
        .. "<style>p { text-indent: 0; margin: 0.25em 0; } li p { margin: 0; } img { max-width: 100%; }</style></head><body>"
        .. (title ~= "" and ("<h1>" .. escapeHtml(title) .. "</h1>") or "") .. note .. body .. "</body></html>"
end

return OneNote
