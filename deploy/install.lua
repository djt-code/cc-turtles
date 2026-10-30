-- install.lua -- run ccnix (this repo) at every boot from a checkout, then reboot
--
-- Usage (from wherever the repo was cloned):
--   cc-turtles/deploy/install [--ccsh] [--net] [--router] [--init] [--autostart <app>] [--no-reboot]
--
-- Writes two lines into /startup.lua, the first at the top and the last
-- at the bottom (or, if /startup is a directory, into /startup/00-ccnix.lua
-- and /startup/zz-ccnix.lua, which run first and last):
--
--   shell.run("<repo>/deploy/boot.lua")
--   shell.run("<repo>/deploy/boot.lua", "--end")
--
-- deploy/boot.lua is what the ccnix mod's ROM runs at boot, and does the
-- same from a checkout: bin/ (and turtle/ or pc/) on the path, help/ on
-- the help path, `ls` ours, the network up while net.boot is on; and,
-- with `--end`, what doesn't return: init (init.boot), or the autostart
-- (ccnix.autostart), then ccsh (ccsh.login).  The first line goes
-- first so a startup program that never returns (autocompost, say)
-- doesn't keep it from running; `--end` goes last so the rest of startup
-- runs first (a job that never returns means no ccsh until you stop it
-- with Ctrl+T).  Lines an earlier install wrote (every line naming
-- <repo>/ or /cc-turtles/) and its files (/startup/00-cc-turtles.lua,
-- zx-init.lua, zy-autostart.lua, zz-ccsh.lua, zz-craftix.lua) go; your
-- own lines stay.  Running install again changes nothing.
--
-- The options set the settings boot reads: --ccsh ccsh.login (`set
-- ccsh.login false` stops it; exit leaves it for the stock prompt), --net
-- net.boot (`ip up` at boot), --router that and net.forward, --init
-- init.boot (`help init`), --autostart <app> ccnix.autostart (on a
-- turtle mine, farm, mow or autocompost, which turtle/autostart resumes
-- after a reboot; on a computer router, pc/router's status screen; it's
-- --router too; `set ccnix.autostart ""` turns it off).
-- --no-reboot runs boot in this shell instead of rebooting.
--
-- This file lives in deploy/, which isn't on the path itself; deploy/setup
-- fetches the repo and runs it in one go.  On a server with ccnix in ROM
-- (the ccnix mod) boot runs from /rom/autorun already, so install, run
-- from there, only sets the settings.

local noReboot, login, autostart, netBoot, router, initBoot = false, false, nil, false, false, false
local AUTOSTART = turtle and { mine = true, farm = true, mow = true, autocompost = true } or { router = true }
local CHOICES = turtle and "mine|farm|mow|autocompost" or "router"
local args = { ... }
local i = 1
while i <= #args do
    local a = args[i]
    if a == "--no-reboot" then noReboot = true
    elseif a == "--ccsh" then login = true
    elseif a == "--net" then netBoot = true
    elseif a == "--router" then netBoot, router = true, true
    elseif a == "--init" then initBoot = true
    elseif a == "--autostart" and AUTOSTART[args[i + 1]] then
        autostart = args[i + 1]
        if autostart == "router" then netBoot, router = true, true end
        i = i + 1
    else
        print("Usage: install [--ccsh] [--net] [--router] [--init] [--autostart " .. CHOICES .. "] [--no-reboot]")
        if a == "--autostart" then print("(--autostart on a " .. (turtle and "turtle" or "computer") .. ": " .. CHOICES .. ")") end
        return
    end
    i = i + 1
end

-- the repo is the directory above this one
local repo = "/" .. fs.getDir(fs.getDir(shell.getRunningProgram()))
local romMode = fs.exists("/rom/ccnix/.manifest") and (repo == "/rom/ccnix" or repo == "/ccnix")
local boot = repo .. "/deploy/boot.lua"
local first = string.format('shell.run("%s")', boot)
local last = string.format('shell.run("%s", "--end")', boot)

local function read(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    local s = f.readAll()
    f.close()
    return s
end

local function write(path, s)
    local f = fs.open(path, "w")
    if not f then printError("Can't write " .. path); error("", 0) end
    f.write(s)
    f.close()
end

-- a startup file's lines less an earlier install's: ours, or any from
-- before (the path lines, the shell's, the autostart's) name the repo
local function kept(path)
    local lines = {}
    for line in ((read(path) or "") .. "\n"):gmatch("(.-)\n") do
        if not (line:find(repo .. "/", 1, true) or line:find("/cc-turtles/", 1, true)) then lines[#lines + 1] = line end
    end
    if lines[#lines] == "" then lines[#lines] = nil end         -- (the file's own last newline)
    return lines
end

if not romMode then
    local target
    if fs.isDir("/startup") then
        target = "/startup/00-ccnix.lua"
        for _, old in ipairs({ "00-cc-turtles", "zx-init", "zy-autostart", "zz-ccsh", "zz-craftix" }) do
            if fs.exists("/startup/" .. old .. ".lua") then fs.delete("/startup/" .. old .. ".lua") end
        end
        if read(target) == first .. "\n" and read("/startup/zz-ccnix.lua") == last .. "\n" then
            print(target .. " and zz-ccnix.lua run " .. boot .. " already.")
        else
            write(target, first .. "\n")
            write("/startup/zz-ccnix.lua", last .. "\n")
            print("Put " .. boot .. " in " .. target .. " and, with --end, /startup/zz-ccnix.lua.")
        end
    else
        target = "/startup.lua"
        local lines = kept(target)
        table.insert(lines, 1, first)
        lines[#lines + 1] = last
        local text = table.concat(lines, "\n") .. "\n"
        if text == read(target) then
            print(target .. " runs " .. boot .. " already.")
        else
            write(target, text)
            print("Put " .. boot .. " first in " .. target .. ", and with --end last.")
        end
    end
end
if login then
    settings.set("ccsh.login", true)
    settings.save()
    print("ccsh starts at boot.")
end
if netBoot then
    settings.set("net.boot", true)
    if router then settings.set("net.forward", true) end
    settings.save()
    print("The network comes up at boot" .. (router and ", forwarding (a router)" or "") .. ": `help network` says how to set it up.")
end
if initBoot then
    settings.set("init.boot", true)
    settings.save()
    print("init starts at boot: `help init`; ps, kill and service work then.")
end
if autostart then
    settings.set("ccnix.autostart", autostart)
    settings.save()
    print("At boot this " .. (turtle and "turtle" or "computer") .. " runs " .. autostart
        .. (turtle and ": `help autostart` says how." or " (its status screen; q leaves it, routing goes on)."))
end

if noReboot then
    -- this shell gets it now; others after a reboot
    if not romMode then shell.run(boot) end
    print(romMode and "Not rebooting: the settings take effect at the next boot."
        or "Not rebooting: on the path in this shell now, everywhere after a reboot.")
    if login then print("Type ccsh to start it now.") end
    return
end
print("Rebooting in 3 seconds (Ctrl+T to cancel)...")
sleep(3)
os.reboot()
