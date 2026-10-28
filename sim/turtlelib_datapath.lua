-- sim/turtlelib_datapath.lua
--
-- T.dataPath after the programs moved into turtle/: a data file left in
-- the repo's top folder by an older copy (a job half done) is moved down
-- next to the program, so `--resume` and `reset` still find it.  Nothing
-- else is moved: not a file that's already in turtle/, and not files
-- beside a program anywhere else.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. package.path

local files, prog = {}, ""
fs = {
    combine = function(a, b) return (a == "" and b) or (a .. "/" .. b) end,
    getDir = function(p) return p == "" and ".." or (p:match("^(.*)/[^/]*$") or "") end,
    exists = function(p) return files[p] ~= nil end,
    move = function(a, b) files[b], files[a] = files[a], nil end,
}
shell = { getRunningProgram = function() return prog end }
local T = require("turtlelib")

local function check(label, cond, got)
    print(string.format("   %s %s%s", cond and "ok   " or "ERROR:", label, got and ("  (" .. got .. ")") or ""))
end

files, prog = { ["cc-turtles/mine.seg"] = "12 64" }, "cc-turtles/turtle/mine.lua"
local p = T.dataPath("mine.seg")
check("a file in the top folder is moved into turtle/", p == "cc-turtles/turtle/mine.seg"
    and files[p] == "12 64" and files["cc-turtles/mine.seg"] == nil, p)

files = { ["cc-turtles/.turtlepos"] = "old", ["cc-turtles/turtle/.turtlepos"] = "new" }
p = T.dataPath(".turtlepos")
check("one already in turtle/ wins; the old one is left", files[p] == "new"
    and files["cc-turtles/.turtlepos"] == "old", p)

files, prog = { ["farm.map"] = "x" }, "disk/farm.lua"
p = T.dataPath("farm.map")
check("a program outside turtle/ moves nothing", p == "disk/farm.map" and files["farm.map"] == "x", p)

files, prog = {}, "farm.lua"
p = T.dataPath("farm.map")
check("a program at the root: beside it, as before", p == "farm.map", p)
