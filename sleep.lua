-- sleep.lua -- wait a while (POSIX sleep)
--
--   sleep time
--
-- Waits `time` seconds.  Decimals are allowed (sleep 0.5); CraftOS counts
-- time in ticks, so the wait is rounded up to the next 0.05 s.  Ctrl+T
-- stops it early.

local cu = require("cu").init("sleep", "sleep time")
local _, ops = cu.getopt({ ... }, "")
if #ops ~= 1 then cu.usageError(#ops < 1 and "missing operand" or "extra operand") end
local t = ops[1]
if not (t:match("^%d+%.?%d*$") or t:match("^%.%d+$")) then
    cu.usageError("invalid time interval '" .. t .. "'")
end
sleep(tonumber(t))
return cu.exit()
