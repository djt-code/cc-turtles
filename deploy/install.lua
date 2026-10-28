-- install.lua -- put cc-turtles on the shell's search path, then reboot
--
-- Usage (from wherever the repo was cloned):
--   cc-turtles/deploy/install [--craftix] [--no-reboot]
--
-- Adds a line to the top of /startup.lua (or, if /startup is a directory,
-- writes /startup/00-cc-turtles.lua, which runs first) that adds the
-- repo's directory to the shell's path at boot, so `mine`, `cat`, `echo`
-- and the rest run from any directory.  The line goes first so a startup
-- program that never returns (autocompost, say) doesn't keep it from
-- running.  Running install again changes nothing.  This file lives in
-- deploy/, which isn't on the path itself.
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
local line = string.format(
    "if not (':' .. shell.path() .. ':'):find(':%s:', 1, true) then shell.setPath(shell.path() .. ':%s') end",
    repo, repo)
local loginLine = string.format('if settings.get("craftix.login") then shell.run("%s/craftix") end', repo)

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

local target, old
if fs.isDir("/startup") then
    target = "/startup/00-cc-turtles.lua"
    old = nil                                   -- ours alone: (re)written whole
else
    target = "/startup.lua"
    old = read(target)
end

if (read(target) or ""):find(line, 1, true) then
    print(target .. " already puts " .. repo .. " on the path.")
else
    write(target, line .. "\n" .. (old or ""))
    print("Added " .. repo .. " to the path in " .. target .. ".")
end

if login then
    local loginTarget = fs.isDir("/startup") and "/startup/zz-craftix.lua" or "/startup.lua"
    local text = read(loginTarget) or ""
    if text:find(loginLine, 1, true) then
        print(loginTarget .. " already starts Craftix.")
    else
        if loginTarget == "/startup.lua" then
            write(loginTarget, text .. ((text == "" or text:sub(-1) == "\n") and "" or "\n") .. loginLine .. "\n")
        else
            write(loginTarget, loginLine .. "\n")
        end
        print("Craftix starts at boot from " .. loginTarget .. ".")
    end
    settings.set("craftix.login", true)
    settings.save()
end

if noReboot then
    -- this shell gets it now; others after a reboot
    load(line, "=startup", "t", { shell = shell })()
    print("Not rebooting: on the path in this shell now, everywhere after a reboot.")
    if login then print("Type craftix to start it now.") end
    return
end
print("Rebooting in 3 seconds (Ctrl+T to cancel)...")
sleep(3)
os.reboot()
