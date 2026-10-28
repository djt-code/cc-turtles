-- pwd.lua -- print the working directory (POSIX pwd)
--
--   pwd [-L|-P]
--
-- Writes the shell's current directory as an absolute path ("/" at the
-- root).  CraftOS has no symbolic links, so -L and -P give the same path.

local cu = require("cu").init("pwd", "pwd [-L|-P]")
local _, ops = cu.getopt({ ... }, "LP")
if #ops > 0 then cu.usageError("too many arguments") end
io.write("/" .. shell.dir() .. "\n")
return cu.exit()
