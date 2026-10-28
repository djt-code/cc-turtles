-- strings.lua -- find printable strings in files (POSIX strings)
--
--   strings [-a] [-t d|o|x] [-n number] [file...]
--
-- Writes every run of at least 4 (or -n number) printable characters
-- (space to ~) found in the files, one per line.  -t puts the run's byte
-- offset from the start of its file in front, in decimal, octal or hex,
-- followed by a space.  Whole files are always scanned, so -a changes
-- nothing.  "-" or no files reads standard input.

local cu = require("cu").init("strings", "strings [-a] [-t format] [-n number] [file...]")
local opts, files = cu.getopt({ ... }, "an:t:")

local min = 4
if opts.n then
    min = cu.int(opts.n)
    if not min or min < 1 then cu.usageError("invalid minimum string length: " .. opts.n) end
end
local fmt = nil
if opts.t then
    fmt = ({ d = "%d ", o = "%o ", x = "%x " })[opts.t]
    if not fmt then cu.usageError("invalid radix: " .. opts.t) end
end

cu.each(files, function(h)
    local s = cu.readAll(h)
    local p, runs = 1, 0
    while true do
        local a, b = s:find("[ -~]+", p)
        if not a then break end
        -- a big file takes a while: yield now and then, or CC stops us
        runs = runs + 1
        if runs % 1000 == 0 then os.queueEvent("strings"); os.pullEvent("strings") end
        if b - a + 1 >= min then
            if fmt then io.write(string.format(fmt, a - 1)) end
            io.write(s:sub(a, b), "\n")
        end
        p = b + 1
    end
end)
return cu.exit()
