-- cat.lua -- show files, a screenful at a time
--
-- CraftOS has no cat (or more).  `cat <file> [file ...]` shows the files
-- one after another in the pager (pager.lua: space/PgDn a page, j/k or
-- the arrows a line, h/l sideways, q to quit); what fits on the screen is
-- just printed.  Handy for claude.log, mine.job, .turtlepos and the like.

local pager = require("pager")

local files = { ... }
if #files == 0 then
    print("Usage: cat <file> [file ...]")
    return
end

local lines = {}
for _, name in ipairs(files) do
    local path = shell.resolve(name)
    if not fs.exists(path) then printError("cat: no such file: " .. name)
    elseif fs.isDir(path) then printError("cat: " .. name .. " is a directory")
    else
        local f = fs.open(path, "r")
        local text = f.readAll()
        f.close()
        if text ~= "" then
            for _, l in ipairs(pager.lines(text)) do lines[#lines + 1] = l end
        end
    end
end
if #lines > 0 then pager.page(lines) end
