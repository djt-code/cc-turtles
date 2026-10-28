-- false.lua -- do nothing, unsuccessfully (POSIX false)
--
--   false
--
-- Ignores its arguments and exits 1: the stock shell's shell.run returns
-- false and nothing is printed.  Kept free of cu.lua; it ends the way
-- cu.exit(1) does.

_G.POSIX_STATUS = 1
error("", 0)
