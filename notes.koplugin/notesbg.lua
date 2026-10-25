--[[--
Work done in a child process, so KOReader keeps answering while it waits on
the network (a slow upload, poor Wi-Fi just after waking, a name lookup that
never answers). The child saves nothing: what it did comes back as a table of
plain values (dumped as Lua), for KOReader to keep.

@module koplugin.notes.bg
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local Bg = {}

--- `job()` run in a child process; its result (a table) goes to
-- done(result), or done(nil, why) when it failed or took longer than `limit`
-- seconds (300).
function Bg.run(job, done, limit)
    local ffiutil = require("ffi/util")
    local pid, fd = ffiutil.runInSubProcess(function(__, write_fd)
        local ok, result = pcall(job)
        local okd, out = pcall(require("dump"), ok and { ok = result } or { err = tostring(result) })
        ffiutil.writeToFD(write_fd, okd and out or '{ err = "failed" }', true)
    end, true)
    if not pid then return done(nil, tostring(fd)) end
    local deadline = os.time() + (limit or 300)
    local function reap()
        if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, reap) end
    end
    local function check()
        local size = ffiutil.getNonBlockingReadSize(fd)
        local exited = ffiutil.isSubProcessDone(pid)
        if not (size and size > 0) and not exited then
            if os.time() < deadline then return UIManager:scheduleIn(0.3, check) end
            logger.warn("Notes: stopped work in the background that took too long")
            ffiutil.terminateSubProcess(pid)
            reap()
            return done(nil, "It took too long.")
        end
        local raw = (size and size > 0) and ffiutil.readAllFromFD(fd) or ""
        if not exited then reap() end
        local fn = raw ~= "" and (loadstring or load)("return " .. raw)
        if fn and setfenv then setfenv(fn, {}) end
        local ok, r = pcall(fn or error)
        if ok and type(r) == "table" and r.ok ~= nil then return done(r.ok) end
        done(nil, ok and type(r) == "table" and r.err or "It stopped without an answer.")
    end
    UIManager:scheduleIn(0.3, check)
end

return Bg
