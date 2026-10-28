-- setup.lua -- put cc-turtles on a turtle or computer in one go
--
--   wget run https://raw.githubusercontent.com/djt-code/cc-turtles/main/deploy/setup.lua
--
-- with any of: --craftix (start Craftix at boot), --no-reboot, --all
-- (clone everything, sim/ too), --skip <dir> (leave out more).
--
-- It fetches the latest git, then clones the repo into /cc-turtles, or
-- pulls it if it's there already, and runs deploy/install to put the
-- programs on the path.  A clone leaves out what the device doesn't run
-- (sim/, and pc/ on a turtle or turtle/ on a computer): see bin/git.lua.
-- Run it again any time to update; it's also the way out of a clone that
-- filled the disk part way: what that left in the folders a clone leaves
-- out is deleted, the rest is kept and finished.  An old bootstrap copy of
-- git at /git.lua is removed, since the repo has its own in bin/.

local REPO = "https://github.com/djt-code/cc-turtles"
local RAW = "https://raw.githubusercontent.com/djt-code/cc-turtles/main/"
local DIR = "/cc-turtles"
local GIT = "/.setup-git.lua"

local cloneArgs, installArgs = {}, {}
local args = { ... }
local i = 1
while i <= #args do
    local a = args[i]
    if a == "--craftix" or a == "--no-reboot" then installArgs[#installArgs + 1] = a
    elseif a == "--all" then cloneArgs[#cloneArgs + 1] = a
    elseif a == "--skip" and args[i + 1] then
        cloneArgs[#cloneArgs + 1] = a
        cloneArgs[#cloneArgs + 1] = args[i + 1]
        i = i + 1
    else
        print("Usage: setup [--craftix] [--no-reboot] [--all] [--skip dir]...")
        return
    end
    i = i + 1
end

local function die(msg)
    printError(msg)
    if fs.exists(GIT) then fs.delete(GIT) end
    error("", 0)
end

if not http then die("HTTP is disabled on this server.") end

-- the latest git, wherever the repo is at
local h, err = http.get(RAW .. "bin/git.lua")
if not h then die("Can't fetch git: " .. tostring(err)) end
local f = fs.open(GIT, "w")
f.write(h.readAll())
f.close()
h.close()

local ok
if fs.exists(fs.combine(DIR, ".gitlite")) then
    print("Updating " .. DIR)
    ok = shell.run(GIT, "pull", DIR)
else
    if fs.exists(DIR) then
        -- a clone that never finished: drop what it got in the folders a
        -- clone now leaves out, keep the rest (clone overwrites it)
        local all = false
        for _, a in ipairs(cloneArgs) do all = all or a == "--all" end
        if not all then
            for _, d in ipairs({ "sim", turtle and "pc" or "turtle" }) do
                local p = fs.combine(DIR, d)
                if fs.exists(p) then print("Removing " .. p); fs.delete(p) end
            end
        end
    end
    print("Cloning into " .. DIR)
    ok = shell.run(GIT, "clone", REPO, DIR, table.unpack(cloneArgs))
end
fs.delete(GIT)
if not ok then die("git stopped; fix what it says and run setup again.") end

-- the README used to fetch git to /git.lua: that copy is out of date now
if fs.exists("/git.lua") and not fs.isDir("/git.lua") then
    local g = fs.open("/git.lua", "r")
    local head = g.readLine() or ""
    g.close()
    if head:find("minimal git client", 1, true) then
        fs.delete("/git.lua")
        print("Removed the old /git.lua (git is in " .. DIR .. "/bin now)")
    end
end

shell.run(fs.combine(DIR, "deploy/install"), table.unpack(installArgs))
