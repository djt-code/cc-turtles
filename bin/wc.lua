-- wc.lua -- count lines, words and bytes (POSIX wc)
--
--   wc [-c|-m] [-lw] [file...]
--
-- For each file (standard input if there are none, or for "-") writes the
-- counts asked for, always in the order lines, words, bytes, then the file
-- name, separated by single spaces.  No options means -lwc.  With more than
-- one file a "total" line follows.  A word is a run of characters that
-- aren't spaces, tabs or newlines.  -m counts characters, which in
-- CraftOS's one-byte character set is the same as -c.  A file that can't
-- be read is reported and wc exits 1 at the end.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("wc", "wc [-c|-m] [-lw] [file...]")
local opts, files = cu.getopt({ ... }, "clmw")
if not (opts.c or opts.l or opts.m or opts.w) then opts.l, opts.w, opts.c = true, true, true end

local total = { 0, 0, 0 }

local function report(n, name)
    local t = {}
    if opts.l then t[#t + 1] = tostring(n[1]) end
    if opts.w then t[#t + 1] = tostring(n[2]) end
    if opts.c or opts.m then t[#t + 1] = tostring(n[3]) end
    if name then t[#t + 1] = name end
    io.write(table.concat(t, " "), "\n")
end

cu.each(files, function(h, name)
    local s = cu.readAll(h)
    -- gsub counts its matches in one call, with no Lua loop to time out
    local n = { select(2, s:gsub("\n", "")), select(2, s:gsub("[^ \t\n\r\v\f]+", "")), #s }
    for i = 1, 3 do total[i] = total[i] + n[i] end
    report(n, #files > 0 and name or nil)
end)
if #files > 1 then report(total, "total") end
return cu.exit()
