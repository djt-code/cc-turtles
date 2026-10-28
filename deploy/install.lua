-- install.lua -- put cc-turtles on the shell's search path, then reboot
--
-- Usage (from wherever the repo was cloned):
--   cc-turtles/deploy/install [--craftix] [--no-reboot]
--
-- Adds lines to the top of /startup.lua (or, if /startup is a directory,
-- writes /startup/00-cc-turtles.lua, which runs first) that add the
-- repo's bin/ (cat, echo, git, craftix and the rest) to the shell's path
-- at boot, and turtle/ (mine, farm, ...) on a turtle or pc/ (diskclone)
-- on a computer, so they run from any directory.  lib/ holds modules the
-- programs require, not programs, so it stays off the path.  The lines go
-- first so a startup program that never returns (autocompost, say)
-- doesn't keep them from running.  Running install again changes
-- nothing; run it again after the 2026-10-28 move into bin/ and turtle/
-- and it swaps the old line (the repo's top folder) for the new ones.
-- This file lives in deploy/, which isn't on the path itself; deploy/setup
-- fetches the repo and runs it in one go.
--
-- --craftix also starts Craftix, the POSIX-style shell, at boot: a line at
-- the end of /startup.lua (or /startup/zz-craftix.lua) runs it while the
-- setting craftix.login is on, and install turns that on.  It goes last,
-- so the rest of startup runs first (and one that never returns means no
-- Craftix).  Leaving Craftix (exit) gives the stock prompt; to stop it
-- starting, `set craftix.login false` there.

local noReboot, login = false, false
for _, a in ipairs({ ... }) do
    if a == "--no-reboot" then noReboot = true
    elseif a == "--craftix" then login = true
    else print("Usage: install [--craftix] [--no-reboot]"); return end
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
local block = table.concat(lines, "\n") .. "\n"
local loginLine = loginLineFor(repo .. "/bin/craftix")
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

local target, rest, current
if fs.isDir("/startup") then
    target = "/startup/00-cc-turtles.lua"
    current = read(target) or ""
    rest = ""                                   -- ours alone: (re)written whole
else
    target = "/startup.lua"
    current = read(target) or ""
    rest = without(without(current, lines), { stale[1] })
end

if block .. rest == current then
    print(target .. " already puts " .. table.concat(dirs, " and ") .. " on the path.")
else
    write(target, block .. rest)
    print("Put " .. table.concat(dirs, " and ") .. " on the path in " .. target .. ".")
end

-- Craftix at boot: with --craftix, or when an earlier install's line runs
-- it from where it used to be
local loginTarget = fs.isDir("/startup") and "/startup/zz-craftix.lua" or "/startup.lua"
local text = read(loginTarget) or ""
local moved = text:find(stale[2] .. "\n", 1, true) ~= nil
text = without(text, { stale[2] })
if text:find(loginLine, 1, true) then
    if moved then write(loginTarget, text) end
    if login then print(loginTarget .. " already starts Craftix.") end
elseif login or moved then
    if loginTarget == "/startup.lua" then
        write(loginTarget, text .. ((text == "" or text:sub(-1) == "\n") and "" or "\n") .. loginLine .. "\n")
    else
        write(loginTarget, loginLine .. "\n")
    end
    print("Craftix starts at boot from " .. loginTarget .. ".")
end
if login then
    settings.set("craftix.login", true)
    settings.save()
end

if noReboot then
    -- this shell gets it now; others after a reboot
    load(block, "=startup", "t", { shell = shell })()
    print("Not rebooting: on the path in this shell now, everywhere after a reboot.")
    if login then print("Type craftix to start it now.") end
    return
end
print("Rebooting in 3 seconds (Ctrl+T to cancel)...")
sleep(3)
os.reboot()
