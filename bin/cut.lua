-- cut.lua -- write selected parts of each line (POSIX cut)
--
--   cut -b list [-n] [file...]
--   cut -c list [file...]
--   cut -f list [-d delim] [-s] [file...]
--
-- list is numbers and ranges separated by commas: 3, 2-5, -4 (1 to 4) or
-- 6- (6 to the end), counting from 1.  The parts come out in line order,
-- each once, whatever order the list gives them in.
--   -b  bytes; -c characters (the same thing in CraftOS); -n is accepted
--   -f  fields separated by delim (a tab unless -d says otherwise); they
--       are written with the same delimiter between them.  A line with no
--       delimiter is written whole, unless -s, which drops it.
-- With no files, or for "-", standard input is read.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("cut", "cut -b list [-n] | -c list | -f list [-d delim] [-s] [file...]")
local opts, files = cu.getopt({ ... }, "b:c:d:f:ns")

local n = (opts.b and 1 or 0) + (opts.c and 1 or 0) + (opts.f and 1 or 0)
if n ~= 1 then cu.usageError("give exactly one of -b, -c and -f") end
if not opts.f and (opts.d or opts.s) then cu.usageError("-d and -s need -f") end
local delim = opts.d or "\t"
if #delim ~= 1 then cu.usageError("the delimiter must be one character") end

-- the list as ranges { from, to } (to = huge for "n-")
local ranges = {}
local spec = opts.b or opts.c or opts.f
for part in spec:gmatch("[^, \t]+") do
    local a, b = part:match("^(%d*)%-(%d*)$")
    if not a then a = part:match("^%d+$"); b = a end
    if not a or a .. b == "" then cu.usageError("bad list: " .. spec) end
    a, b = tonumber(a ~= "" and a or "1"), tonumber(b ~= "" and b or nil) or math.huge
    if a < 1 or b < a then cu.usageError("bad list: " .. spec) end
    ranges[#ranges + 1] = { a, b }
end
if #ranges == 0 then cu.usageError("bad list: " .. spec) end

local function wanted(i)
    for _, r in ipairs(ranges) do if i >= r[1] and i <= r[2] then return true end end
    return false
end

local done = 0     -- lines since the last yield
for l in cu.lines(files) do
    -- yield now and then so a big file can't run "too long without yielding"
    done = done + 1
    if done % 1000 == 0 then os.queueEvent("cut_yield"); os.pullEvent("cut_yield") end
    local t = {}
    if opts.f then
        if not l:find(delim, 1, true) then
            if not opts.s then io.write(l, "\n") end
        else
            local i = 0
            for f in (l .. delim):gmatch("(.-)" .. delim:gsub("%p", "%%%0")) do
                i = i + 1
                if wanted(i) then t[#t + 1] = f end
            end
            io.write(table.concat(t, delim), "\n")
        end
    else
        for i = 1, #l do if wanted(i) then t[#t + 1] = l:sub(i, i) end end
        io.write(table.concat(t), "\n")
    end
end
return cu.exit()
