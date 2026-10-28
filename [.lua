-- [.lua -- the "[ expression ]" form of test: runs test.lua from this folder
--
--   [ expression ]
--
-- See test.lua.  The last argument must be "]".  CraftOS allows "[" in a
-- file name and its shell finds "[" on the path like any other program.

local here = fs.getDir(shell.getRunningProgram())
local fn, err = loadfile("/" .. fs.combine(here, "test.lua"), nil, _ENV)
if not fn then printError("[: " .. err); _G.POSIX_STATUS = 2; error("", 0) end
return fn(...)
