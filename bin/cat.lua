-- cat.lua -- concatenate files to standard output (POSIX cat)
--
--   cat [-u] [file...]
--
-- Writes each file in turn, byte for byte; "-" or no files at all reads
-- standard input (from the keyboard: hold Ctrl+T to end it).  A file that
-- can't be read is reported and skipped, and cat exits 1 at the end.
-- -u (unbuffered) is accepted: output is never buffered here anyway.
-- To read a long file a screenful at a time, use more.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("cat", "cat [-u] [file...]")
local _, files = cu.getopt({ ... }, "u")

cu.each(files, function(h)
    if h == io.stdin then
        -- the keyboard: echo each line as it is typed
        for l in function() return cu.readLine(h, true) end do io.write(l) end
    else
        io.write(cu.readAll(h))
    end
end)
return cu.exit()
