-- setup.lua -- put cc-turtles on a turtle or computer in one go
--
--   wget run https://raw.githubusercontent.com/djt-code/cc-turtles/main/deploy/setup.lua [app...]
--
-- Apps (any number; none means everything for this kind of device):
--   mine farm mow autocompost claude   turtle programs (with turtlelib,
--                                      home and autostart)
--   coreutils                          cat, grep, ls-style utilities...
--   craftix                            the POSIX-style shell, started at boot
--   diskclone                          for a computer with a disk drive
--   fileserver                         its disk drives as one folder, /jbod
--   net                                the network: ip, ping, traceroute, nc
--   router                             the network, and routing between networks
-- git and deploy/ always come; so do the help files of what you pick.
--
-- Options: --autostart <app> (a turtle runs it at every boot: resumes its
-- job, or starts one from the settings; see turtle/autostart.lua),
-- --craftix (Craftix at boot without naming it), --no-reboot, --all
-- (everything, sim/ too), --skip <dir> (leave out more).
--
--   setup mine --autostart mine        a miner that carries on after reboots
--   setup farm coreutils craftix       a farmer you can also use as a shell
--
-- It fetches the latest git, then clones the repo into /cc-turtles, or
-- pulls it if it's there already, and runs deploy/install to put the
-- programs on the path.  A clone leaves out what the device doesn't run
-- (sim/, and pc/ on a turtle or turtle/ on a computer): see bin/git.lua.
-- Run it again any time to update (naming apps again changes what's
-- there; naming none keeps the choice); it's also the way out of a clone that
-- filled the disk part way: what that left in the folders a clone leaves
-- out, and Lua files in the top folder from before bin/ and turtle/, are
-- deleted; the rest is kept and finished.  (A pull deletes moved files
-- itself; the git from before did that only after fetching everything,
-- so a pull that filled the disk left both copies.  setup's pull, with
-- the new git, clears them.)  git runs from memory, so a full disk is no
-- bar to starting.  An old bootstrap copy of git at /git.lua is removed,
-- since the repo has its own in bin/.

local REPO = "https://github.com/djt-code/cc-turtles"
local RAW = "https://raw.githubusercontent.com/djt-code/cc-turtles/main/"
local DIR = "/cc-turtles"

-- What each app needs.  A path ending in / is a whole folder.
local TURTLE = { "turtle/turtlelib.lua", "turtle/home.lua", "turtle/autostart.lua" }
local APPS = {
    mine = { "turtle/mine.lua", TURTLE },
    farm = { "turtle/farm.lua", TURTLE },
    mow = { "turtle/mow.lua", TURTLE },
    autocompost = { "turtle/autocompost.lua", TURTLE },
    claude = { "turtle/claude.lua", TURTLE },
    coreutils = { "bin/", "lib/" },
    craftix = { "bin/craftix.lua" },
    diskclone = { "pc/diskclone.lua" },
    fileserver = { "pc/fileserver.lua", "lib/jbod.lua" },
    net = { "bin/ip.lua", "bin/ping.lua", "bin/traceroute.lua", "bin/nc.lua", "lib/net.lua", "lib/cu.lua",
            "help/network.txt" },
    router = { "pc/router.lua", "bin/ip.lua", "bin/ping.lua", "bin/traceroute.lua", "bin/nc.lua", "lib/net.lua",
               "lib/cu.lua", "help/network.txt" },
}
local ALWAYS = { "bin/git.lua", "lib/pager.lua", "deploy/", "help/cc-turtles.txt" }
local AUTOSTART = { mine = true, farm = true, mow = true, autocompost = true }

local cloneArgs, installArgs, apps = {}, {}, {}
local autostart
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
    elseif a == "--autostart" and AUTOSTART[args[i + 1]] then
        autostart = args[i + 1]
        i = i + 1
    elseif APPS[a] then
        apps[#apps + 1] = a
    else
        print("Usage: setup [app...] [--autostart app] [--craftix] [--no-reboot] [--all] [--skip dir]...")
        local names = {}
        for name in pairs(APPS) do names[#names + 1] = name end
        table.sort(names)
        print("Apps: " .. table.concat(names, " "))
        print("--autostart: mine, farm, mow or autocompost")
        return
    end
    i = i + 1
end
if autostart and not turtle then print("--autostart is for turtles."); return end
if autostart and #apps > 0 then
    local named = false
    for _, a in ipairs(apps) do named = named or a == autostart end
    if not named then apps[#apps + 1] = autostart end
end
if autostart then
    installArgs[#installArgs + 1] = "--autostart"
    installArgs[#installArgs + 1] = autostart
end

-- The paths the named apps need, with their help files, as --only options
local function paths()
    local seen, out = {}, {}
    local function add(p)
        if seen[p] then return end
        seen[p] = true
        out[#out + 1] = "--only"
        out[#out + 1] = p
        local name = p:match("([^/]+)%.lua$")
        if name and p:sub(1, 4) ~= "lib/" then add("help/" .. name .. ".txt") end
        if p == "bin/" then add("help/") end
    end
    local function addAll(list)
        for _, p in ipairs(list) do
            if type(p) == "table" then addAll(p) else add(p) end
        end
    end
    addAll(ALWAYS)
    for _, a in ipairs(apps) do
        addAll(APPS[a])
        if a == "craftix" then installArgs[#installArgs + 1] = "--craftix" end
    end
    return out
end
if #apps > 0 then
    for _, o in ipairs(paths()) do cloneArgs[#cloneArgs + 1] = o end
end

local function die(msg)
    printError(msg)
    error("", 0)
end

if not http then die("HTTP is disabled on this server.") end

-- the latest git, wherever the repo is at, kept in memory: the disk may
-- be full
local h, err = http.get(RAW .. "bin/git.lua")
if not h then die("Can't fetch git: " .. tostring(err)) end
local gitFn, loadErr = load(h.readAll(), "@git", "t", _ENV)
h.close()
if not gitFn then die("Can't load git: " .. tostring(loadErr)) end
local function git(...)
    local ok, e = pcall(gitFn, ...)
    if not ok and e ~= "" then printError(tostring(e)) end      -- "": git said why
    return ok
end

local ok
if fs.exists(fs.combine(DIR, ".gitlite")) then
    print("Updating " .. DIR)
    ok = git("pull", DIR, table.unpack(cloneArgs))
else
    if fs.exists(DIR) then
        -- a clone that never finished: drop what it got in the folders a
        -- clone now leaves out, keep the rest (clone overwrites it).  Lua
        -- files in the top folder are left from before bin/ and turtle/
        -- and nothing records them, so they'd never go: delete them too
        -- (a job's files there aren't .lua, and turtlelib moves them).
        for _, name in ipairs(fs.list(DIR)) do
            local p = fs.combine(DIR, name)
            if name:match("%.lua$") and not fs.isDir(p) then print("Removing " .. p); fs.delete(p) end
        end
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
    ok = git("clone", REPO, DIR, table.unpack(cloneArgs))
end
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
