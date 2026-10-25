--[[--
Network work in a child process, so KOReader stays responsive while Wikipedia
answers (or doesn't, on flaky Wi-Fi). A message shows meanwhile; tapping it
stops the work. The result comes back as JSON: plain tables, strings, numbers
and booleans.
]]

local JSON = require("json")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")

local Bg = {}

--- Run fn() in a child process; done(result) after, or done(nil, why) when it
-- failed, took longer than opts.limit seconds (default 60) or was stopped
-- ("stopped"). opts.text: the message shown meanwhile (none without it).
function Bg.run(fn, done, opts)
    opts = opts or {}
    local pid, fd = ffiutil.runInSubProcess(function(__, write_fd)
        local ok, r = pcall(fn)
        local out
        local enc, s = pcall(JSON.encode, ok and { v = r } or { e = tostring(r) })
        out = enc and s or JSON.encode({ e = "bad result" })
        ffiutil.writeToFD(write_fd, out, true)
    end, true)
    if not pid then return done(nil, tostring(fd)) end

    local finished = false
    local msg
    local function finish(r, why)
        if finished then return end
        finished = true
        if msg then msg.close() end
        done(r, why)
    end
    local function reap()
        if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(0.5, reap) end
    end
    local function stop(why)
        if finished then return end
        ffiutil.terminateSubProcess(pid)
        reap()
        finish(nil, why)
    end
    if opts.text then
        -- (the shared wait box: a tap on it stops the work, but not a touch in its first second)
        msg = require("wikibar").wait(opts.text, function() stop("stopped") end)
    end

    local deadline = os.time() + (opts.limit or 60)
    local function check()
        if finished then return end
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = not (size and size > 0) and ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() > deadline then return stop("timeout") end
            return UIManager:scheduleIn(0.2, check)
        end
        local out = ffiutil.readAllFromFD(fd) or ""
        if not exited then reap() end
        local ok, t = pcall(JSON.decode, out)
        if not ok or type(t) ~= "table" then return finish(nil, "no answer") end
        if t.e then
            logger.warn("Wikipedia:", t.e)
            return finish(nil, t.e)
        end
        -- (JSON keeps no nil: a missing v is nil, false stays false)
        finish(t.v, t.v == nil and "nothing" or nil)
    end
    UIManager:scheduleIn(0.1, check)
end

return Bg
