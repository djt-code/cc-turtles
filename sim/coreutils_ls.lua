-- sim/coreutils_ls.lua
--
-- ls in a shellworld: hidden files (left out, -a, -A), the long format
-- with and without -h, the order (-t, -S, -r), -d, -F, -R, columns to the
-- screen and one per line into a pipe, a missing operand (status 2), and
-- `ls` at the prompt running ours once install's alias is set.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check

local W = SW.new(PROJ)
local function show(s) return (tostring(s):gsub("\n", "|")) end
local function lines(s)
    local t = {}
    for l in s:gmatch("([^\n]*)\n") do t[#t + 1] = l end
    return t
end

W:dir("d/sub")
W:file("d/a.txt", "hello\n")
W:advance(60)
W:file("d/.hidden", "x")
W:advance(60)
W:file("d/big.bin", string.rep("x", 5000))
W:file("d/sub/inner", "y")

local r = W:run("ls", "d")
check("no options: the visible names in columns, sorted", r.status == 0 and r.out == "a.txt  big.bin  sub\n", show(r.out))
r = W:run("ls", "-a", "d")
check("-a: hidden files, and . and ..", r.out == ".  ..  .hidden  a.txt  big.bin  sub\n", show(r.out))
r = W:run("ls", "-A", "d")
check("-A: hidden files, not . and ..", r.out == ".hidden  a.txt  big.bin  sub\n", show(r.out))

r = W:run("ls", "-l", "d")
local l = lines(r.out)
check("-l: a total in kilobytes, then mode, size, time and name",
    l[1] == "total 5" and l[2]:match("^%-rw%-r%-%-r%-%-    6 %a%a%a [ %d]%d %d%d:%d%d a%.txt$")
        and l[3]:match("^%-rw%-r%-%-r%-%- 5000 .* big%.bin$") and l[4]:match("^drwxr%-xr%-x    0 .* sub$") and #l == 4,
    show(r.out))
r = W:run("ls", "-lah", "d")
l = lines(r.out)
check("-lah: hidden files and sizes like 4.9K",
    l[1] == "total 4.9K" and l[2]:match(" %.$") and l[3]:match(" %.%.$") and l[4]:match("^%-rw%-r%-%-r%-%-    1 .* %.hidden$")
        and l[6]:match("^%-rw%-r%-%-r%-%- 4%.9K .* big%.bin$") and #l == 7, show(r.out))
r = W:run("ls", "-l", "rom/programs")
check("-l on /rom: read-only, no w", lines(r.out)[2]:match("^%-r%-%-r%-%-r%-%- "), show(r.out))

r = W:run("ls", "-t", "-1", "d")
check("-t: newest first (a tie by name)", r.out == "big.bin\na.txt\nsub\n", show(r.out))
r = W:run("ls", "-S1", "d")
check("-S: largest first", lines(r.out)[1] == "big.bin" and lines(r.out)[2] == "a.txt", show(r.out))
r = W:run("ls", "-r1", "d")
check("-r: reversed", r.out == "sub\nbig.bin\na.txt\n", show(r.out))
r = W:run("ls", "-F", "d")
check("-F: directories marked /", r.out == "a.txt  big.bin  sub/\n", show(r.out))
r = W:run("ls", "-d", "d", "d/a.txt")
check("-d: directory operands as themselves", r.out == "d  d/a.txt\n", show(r.out))
r = W:run("ls", "d/a.txt", "d/sub")
check("files first, then each directory under a header", r.out == "d/a.txt\n\nd/sub:\ninner\n", show(r.out))
r = W:run("ls", "-R", "d")
check("-R: subdirectories too", r.out == "d:\na.txt  big.bin  sub\n\nd/sub:\ninner\n", show(r.out))

r = W:run("ls", "d", { pipeOut = true })
check("into a pipe: one per line", r.out == "a.txt\nbig.bin\nsub\n", show(r.out))
W:dir("many")
for i = 1, 30 do W:file(string.format("many/file%02d.lua", i), "") end
r = W:run("ls", "many")
l = lines(r.out)
local widest = 0
for _, x in ipairs(l) do widest = math.max(widest, #x) end
check("many names: in columns down the screen, as many as fit",
    #l < 30 and #l > 1 and widest <= 51 and l[1]:match("^file01%.lua  file") and l[2]:match("^file02%.lua"),
    #l .. " rows, widest " .. widest .. ": " .. show(r.out))

r = W:run("ls", "nope", "d/sub")
check("a missing operand: said, the rest listed (under a header, as GNU does), status 2",
    r.status == 2 and r.err[1] == "ls: cannot access 'nope': No such file or directory" and r.out == "d/sub:\ninner\n",
    show(r.out) .. " / " .. tostring(r.err[1]))
r = W:run("ls", "-z")
check("a bad option: usage error 2", r.status == 2 and r.err[1] == "ls: illegal option -- z")

r = W:sh("ls -a d")
check("at the prompt, before install: CraftOS's ls (an alias for list)", not r.out:find(".hidden", 1, true))
W.shell.setAlias("ls", "/ccnix/bin/ls.lua")              -- what install's startup line does
r = W:sh("ls -a d")
check("with install's alias: ours, hidden files and all", r.out == ".  ..  .hidden  a.txt  big.bin  sub\n", show(r.out))

-- with the fileserver's pool mounted: its member disks' mounts are hidden
-- like dot files, from ls and from ccsh's globs
local J = require("jbod")
W:dir("disk"); W:dir("disk2"); W:dir("dusty")
W:file("disk/a.txt", "a")
J.install(W.fs, { mount = "jbod", clock = function() return 0 end,
    drives = function() return { { name = "drive_0", root = "disk" }, { name = "drive_1", root = "disk2" } } end })
W.fs.jbodPool.add("drive_0")                         -- (disk has a file: added by hand)
r = W:run("ls", "/")
check("pool mounted: ls / leaves out the member disks, shows jbod",
    not r.out:find("disk") and r.out:find("jbod") and r.out:find("dusty"), show(r.out))
r = W:run("ls", "-a", "/")
check("ls -a / shows them", r.out:find("disk%s") ~= nil and r.out:find("disk2") ~= nil, show(r.out))
r = W:run("ls", "-1", "/jbod")
check("their files are in /jbod", r.out == "a.txt\n", show(r.out))
W:install("echo")
r = W:run("ccsh", "-c", "echo *")
check("ccsh: * leaves them out", not r.out:find("disk") and r.out:find("dusty") and r.out:find("jbod"), show(r.out))
r = W:run("ccsh", "-c", "echo d*")
check("and d* matches them, as .* does dot files", r.out == "d disk disk2 dusty\n", show(r.out))

-- a pool mounted by an older jbod.lua (before a git pull: no isMember):
-- ls and ccsh carry on, showing the disks
local isMember = W.fs.jbodPool.isMember
W.fs.jbodPool.isMember = nil
r = W:run("ls", "/")
local r2 = W:run("ccsh", "-c", "echo *")
check("an older pool (no isMember): ls and ccsh work, disks shown",
    r.status == 0 and r.out:find("disk2") and r2.out:find("disk2"), show(r.out) .. " / " .. show(r2.out))
W.fs.jbodPool.isMember = isMember
