--[[--
Connections in a child process, so KOReader stays responsive while a device
answers (or does not, on flaky Wi-Fi). A message shows meanwhile; its Stop
stops the work. The result comes back as JSON: plain tables, strings, numbers
and booleans.
]]

local JSON = require("json")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")
local time = require("ui/time")

local KO = require("ndko")

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
        if msg then
            msg.close()
            msg = nil
        end
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
        -- Stop (or a tap, on KOReader's own message) stops the work; but a touch
        -- in its first second is the rest of the tap that started it (the pen,
        -- a lingering finger), so the message comes back.
        local function showMessage()
            local shown = time.now()
            msg = KO.wait(opts.text, function()
                msg = nil
                if finished then return end
                if time.to_s(time.since(shown)) < 1 then
                    logger.info("NextDNS: a touch as the message showed, not taken as Stop")
                    return UIManager:nextTick(function() if not finished then showMessage() end end)
                end
                logger.info("NextDNS: stopped by a tap:", opts.text)
                stop("stopped")
            end)
        end
        showMessage()
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
            logger.warn("NextDNS:", t.e)
            return finish(nil, t.e)
        end
        -- (JSON keeps no nil: a missing v is nil, false stays false)
        finish(t.v, t.v == nil and "nothing" or nil)
    end
    UIManager:scheduleIn(0.1, check)
end

return Bg
