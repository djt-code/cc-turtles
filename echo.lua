-- echo.lua -- print its arguments, or write them to a file
--
-- CraftOS has no echo, and its shell has no redirects, so echo does them
-- itself:
--   echo hello there               prints "hello there"
--   echo some text > notes.txt     writes the file (replacing it)
--   echo more text >> notes.txt    adds a line to the end
--
-- The shell splits words on spaces and strips double quotes, so a quoted
-- phrase becomes one argument and its quotes are gone.  Use single quotes
-- for Lua strings:  echo shell.run('autocompost') > /startup.lua

local words, out, mode = {}, nil, nil
local args = { ... }
local i = 1
while i <= #args do
    local a = args[i]
    local op, rest = a:match("^(>>?)(.*)$")
    if op then
        mode = op == ">>" and "a" or "w"
        if rest ~= "" then out = rest
        else i = i + 1; out = args[i] end
        if not out then printError("echo: " .. op .. " needs a file name"); return end
    else
        words[#words + 1] = a
    end
    i = i + 1
end

local text = table.concat(words, " ")
if not out then print(text); return end
local path = shell.resolve(out)
if fs.isDir(path) then printError("echo: " .. out .. " is a directory"); return end
local f = fs.open(path, mode)
if not f then printError("echo: can't write " .. out); return end
f.write(text .. "\n")
f.close()
