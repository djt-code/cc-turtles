-- install.lua -- put cc-turtles on the shell's search path, then reboot
--
-- Usage (from wherever the repo was cloned):
--   cc-turtles/deploy/install [--craftix] [--net] [--router] [--autostart <app>] [--no-reboot]
--
-- Adds lines to the top of /startup.lua (or, if /startup is a directory,
-- writes /startup/00-cc-turtles.lua, which runs first) that add the
-- repo's bin/ (cat, echo, git, craftix and the rest) to the shell's path
-- at boot, and turtle/ (mine, farm, ...) on a turtle or pc/ (diskclone)
-- on a computer, so they run from any directory, and help/ to the help
-- path, so `help mine` works, and makes `ls` run bin/ls (CraftOS's ls is
-- an alias for list, and aliases win over the path, so ours is an alias
-- too; `alias ls list` brings the old one back until the next boot), and
-- brings the network up (`ip up`) while the setting net.boot is on:
-- --net turns that on, --router too and forwarding (net.forward) with it.
-- lib/ holds modules the programs require,
-- not programs, so it stays off the path.  The lines go first so a
-- startup program that never returns (autocompost, say) doesn't keep them
-- from running.  Running install again changes nothing; run it again
-- after the 2026-10-28 move into bin/ and turtle/ and it swaps the old
-- line (the repo's top folder) for the new ones.  This file lives in
-- deploy/, which isn't on the path itself; deploy/setup fetches the repo
-- and runs it in one go.
--
-- At the end of startup go, in this order:
--  * the autostart (/startup/zy-autostart.lua with a startup folder): what
--    the setting cc-turtles.autostart names.  On a turtle turtle/autostart
--    runs it, resuming its job after a reboot (mine, farm, mow or
--    autocompost); on a computer, router (pc/router: the network up,
--    forwarding, and its status screen).  --autostart <app> sets it (and
--    --autostart router is --router too); `set cc-turtles.autostart ""`
--    turns it off.
--  * Craftix, the POSIX-style shell (/startup/zz-craftix.lua), while the
--    setting craftix.login is on; --craftix adds it and turns that on.
--    Leaving Craftix (exit) gives the stock prompt; to stop it starting,
--    `set craftix.login false`.
-- Last, so the rest of startup runs first; a job that never returns
-- means no Craftix until you stop it with Ctrl+T.

local noReboot, login, autostart, netBoot, router = false, false, nil, false, false
local AUTOSTART = turtle and { mine = true, farm = true, mow = true, autocompost = true } or { router = true }
local CHOICES = turtle and "mine|farm|mow|autocompost" or "router"
local args = { ... }
local i = 1
while i <= #args do
    local a = args[i]
    if a == "--no-reboot" then noReboot = true
    elseif a == "--craftix" then login = true
    elseif a == "--net" then netBoot = true
    elseif a == "--router" then netBoot, router = true, true
    elseif a == "--autostart" and AUTOSTART[args[i + 1]] then
        autostart = args[i + 1]
        if autostart == "router" then netBoot, router = true, true end
        i = i + 1
    else
        print("Usage: install [--craftix] [--net] [--router] [--autostart " .. CHOICES .. "] [--no-reboot]")
        if a == "--autostart" then print("(--autostart on a " .. (turtle and "turtle" or "computer") .. ": " .. CHOICES .. ")") end
        return
    end
    i = i + 1
end

-- the repo is the directory above this one
local repo = "/" .. fs.getDir(fs.getDir(shell.getRunningProgram()))
local function pathLine(dir)
    return string.format(
        "if not (':' .. shell.path() .. ':'):find(':%s:', 1, true) then shell.setPath(shell.path() .. ':%s') end",
        dir, dir)
end
local function loginLineFor(prog)
    return string.format('if settings.get("craftix.login") then shell.run("%s") end', prog)
end
local dirs = { repo .. "/bin", repo .. (turtle and "/turtle" or "/pc") }
local lines = {}
for i, d in ipairs(dirs) do lines[i] = pathLine(d) end
lines[#lines + 1] = string.format(
    "if not (':' .. help.path() .. ':'):find(':%s/help:', 1, true) then help.setPath(help.path() .. ':%s/help') end",
    repo, repo)
-- our ls (with -a, -l, -h...) over CraftOS's, which is an alias for list:
-- aliases come before the path, so it has to be one too
lines[#lines + 1] = string.format(
    'if fs.exists("%s/bin/ls.lua") and fs.exists("%s/lib/cu.lua") then shell.setAlias("ls", "%s/bin/ls.lua") end',
    repo, repo, repo)
-- the network, while net.boot is on (ip up returns at once: see lib/net.lua)
lines[#lines + 1] = string.format(
    'if settings.get("net.boot") and fs.exists("%s/bin/ip.lua") then shell.run("%s/bin/ip", "up") end', repo, repo)
local block = table.concat(lines, "\n") .. "\n"
local loginLine = loginLineFor(repo .. "/bin/craftix")
local turtleAutoLine = string.format(
    'if settings.get("cc-turtles.autostart", "") ~= "" and fs.exists("%s/turtle/autostart.lua") then shell.run("%s/turtle/autostart") end',
    repo, repo)
local computerAutoLine = string.format(
    'if settings.get("cc-turtles.autostart", "") == "router" and fs.exists("%s/pc/router.lua") then shell.run("%s/pc/router") end',
    repo, repo)
local autoLine = turtle and turtleAutoLine or computerAutoLine
-- what earlier installs wrote, when the programs were in the repo's top folder
local stale = { pathLine(repo), loginLineFor(repo .. "/craftix") }

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

-- text less every whole line in `drop`
local function without(text, drop)
    for _, l in ipairs(drop) do
        local s, e = text:find(l .. "\n", 1, true)
        while s do
            text = text:sub(1, s - 1) .. text:sub(e + 1)
            s, e = text:find(l .. "\n", 1, true)
        end
    end
    return text
end

local folder = fs.isDir("/startup")
local target, rest, current
if folder then
    target = "/startup/00-cc-turtles.lua"
    current = read(target) or ""
    rest = ""                                   -- ours alone: (re)written whole
else
    target = "/startup.lua"
    current = read(target) or ""
    rest = without(without(current, lines), { stale[1] })
end

-- `lines` holds the path and help lines; an earlier install's has the
-- path lines alone, so drop what's left of those too
local pathOnly = {}
for i = 1, #dirs do pathOnly[i] = lines[i] end
rest = without(rest, pathOnly)
if block .. rest == current then
    print(target .. " already puts " .. table.concat(dirs, " and ") .. " on the path.")
else
    write(target, block .. rest)
    print("Put " .. table.concat(dirs, " and ") .. " on the path, and help/ on the help path, in " .. target .. ".")
end

-- The end of startup: the autostart (a turtle), then Craftix
local wasLogin, hadAuto
if folder then
    local function put(path, line, want)
        local had = (read(path) or ""):find(line, 1, true) ~= nil
        if want and not had then write(path, line .. "\n") end
        return had
    end
    local old = read("/startup/zz-craftix.lua") or ""
    wasLogin = old:find(loginLine, 1, true) ~= nil or old:find(stale[2], 1, true) ~= nil
    if old:find(stale[2], 1, true) then fs.delete("/startup/zz-craftix.lua") end
    hadAuto = put("/startup/zy-autostart.lua", autoLine, true)
    put("/startup/zz-craftix.lua", loginLine, login or wasLogin)
else
    local text = read(target) or ""
    wasLogin = text:find(loginLine .. "\n", 1, true) ~= nil or text:find(stale[2] .. "\n", 1, true) ~= nil
    hadAuto = text:find(autoLine .. "\n", 1, true) ~= nil
    local body = without(text, { loginLine, stale[2], turtleAutoLine, computerAutoLine })
    local tail = autoLine .. "\n" .. ((login or wasLogin) and (loginLine .. "\n") or "")
    local new = body .. ((body == "" or body:sub(-1) == "\n" or tail == "") and "" or "\n") .. tail
    if new ~= text then write(target, new) end
end
if turtle and not hadAuto then print("The autostart is in startup (it runs what cc-turtles.autostart names).") end
if login and not wasLogin then print("Craftix starts at boot.") end
if login then
    settings.set("craftix.login", true)
    settings.save()
end
if netBoot then
    settings.set("net.boot", true)
    if router then settings.set("net.forward", true) end
    settings.save()
    print("The network comes up at boot" .. (router and ", forwarding (a router)" or "") .. ": `help network` says how to set it up.")
end
if autostart then
    settings.set("cc-turtles.autostart", autostart)
    settings.save()
    print("At boot this " .. (turtle and "turtle" or "computer") .. " runs " .. autostart
        .. (turtle and ": `help autostart` says how." or " (its status screen; q leaves it, routing goes on)."))
end

if noReboot then
    -- this shell gets it now; others after a reboot
    load(block, "=startup", "t", { shell = shell, help = help, fs = fs, settings = settings })()
    print("Not rebooting: on the path in this shell now, everywhere after a reboot.")
    if login then print("Type craftix to start it now.") end
    return
end
print("Rebooting in 3 seconds (Ctrl+T to cancel)...")
sleep(3)
os.reboot()
