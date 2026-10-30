-- more.lua -- show files a screenful at a time (POSIX more, a subset)
--
--   more [-cs] [-u] [file...]
--
-- Shows the files ("-" or none: standard input) in the pager (pager.lua:
-- space/PgDn a page, j/k or the arrows a line, h/l sideways, q to quit);
-- what fits on the screen is just printed.  With more than one file each
-- starts with its name between lines of colons.  -s squeezes runs of
-- blank lines into one; -c and -u are accepted (the pager always redraws
-- the whole screen and shows no underlining).  When the output isn't the
-- screen, more copies its input like cat.  A file that can't be read is
-- reported and skipped (exit status 1).
--
-- Not supported: -e, -i, -n number, -p command, -t tagstring, and more's
-- own commands (/ search, :n, v and so on); the pager's keys stand in.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("more", "more [-cs] [-u] [file...]")
local pager = require("pager")
local opts, files = cu.getopt({ ... }, "csu")

-- the text of one input, squeezed with -s
local function text(h)
    local s = cu.readAll(h)
    if opts.s then
        s = s:gsub("\n\n\n+", "\n\n"):gsub("^\n\n+", "\n")
    end
    return s
end

if not cu.isTerminal() then
    cu.each(files, function(h) io.write(text(h)) end)
    return cu.exit()
end

local parts = {}
cu.each(files, function(h, name)
    if #files > 1 then parts[#parts + 1] = "::::::::::::::\n" .. name .. "\n::::::::::::::\n" end
    local s = text(h)
    if s ~= "" and s:sub(-1) ~= "\n" then s = s .. "\n" end
    parts[#parts + 1] = s
end)
local all = table.concat(parts)
if all ~= "" then pager.page(all) end
return cu.exit()
