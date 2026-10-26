-- runsim.lua -- run the offline simulators on a ComputerCraft computer
--
-- Usage:
--   sim/runsim                 every simulator, then a summary
--   sim/runsim farm_clone ...  just these (".lua" optional)
--   sim/runsim --list          what there is
--
-- Each simulator runs in a sandbox (sim/lib/sandbox.lua), so its mocks
-- never touch the real computer.  Full output goes to sim/logs/<name>.log
-- next to this script; the screen shows it as it runs.  Ctrl+T stops
-- everything.  To watch one play out on a monitor, see watchsim.lua.

local realFs, realPrint = fs, print
local here = realFs.getDir(shell.getRunningProgram())
local root = realFs.getDir(here)
local logDir = realFs.combine(here, "logs")
local S = dofile(realFs.combine(here, "lib/sandbox.lua"))

local function runOne(name)
    local path = realFs.combine(here, name .. ".lua")
    if not realFs.exists(path) then
        printError("No simulator " .. name)
        return "missing"
    end
    if not realFs.exists(logDir) then realFs.makeDir(logDir) end
    local logFile = realFs.open(realFs.combine(logDir, name .. ".log"), "w")
    local failed = false
    local function show(line)
        logFile.writeLine(line)
        if line:find("   ERROR:", 1, true) then failed = true end
        return realPrint(line)
    end
    realPrint("######## " .. name)
    local ok, err = S.run(path, root, S.new({ print = show }))
    if not ok then show("   ERROR: " .. tostring(err)) end
    logFile.close()
    return (ok and not failed) and "ok" or "ERROR"
end

local args = { ... }
if args[1] == "--list" then
    for _, name in ipairs(S.list(here)) do realPrint(name) end
    return
end
local names = {}
for _, a in ipairs(args) do names[#names + 1] = (a:gsub("%.lua$", "")) end
if #names == 0 then names = S.list(here) end

local results = {}
for _, name in ipairs(names) do results[#results + 1] = { name, runOne(name) } end
if #results > 1 then
    realPrint("######## summary")
    for _, r in ipairs(results) do realPrint(string.format("%-8s %s", r[2], r[1])) end
end
realPrint("Full output in " .. logDir)
