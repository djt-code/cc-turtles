-- cat.lua -- print files, a screenful at a time
--
-- CraftOS has no cat (or more).  `cat <file> [file ...]` prints each file
-- in turn, waiting for a key whenever the screen fills, like `git log`.
-- Handy for claude.log, mine.job, .turtlepos and the like.

local files = { ... }
if #files == 0 then
    print("Usage: cat <file> [file ...]")
    return
end

local text = {}
for _, name in ipairs(files) do
    local path = shell.resolve(name)
    if not fs.exists(path) then printError("cat: no such file: " .. name)
    elseif fs.isDir(path) then printError("cat: " .. name .. " is a directory")
    else
        local f = fs.open(path, "r")
        text[#text + 1] = (f.readAll():gsub("\r", ""):gsub("\n$", ""))
        f.close()
    end
end
if #text > 0 then textutils.pagedPrint(table.concat(text, "\n")) end
