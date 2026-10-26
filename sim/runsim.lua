-- runsim.lua -- run the offline simulators on a ComputerCraft computer
--
-- Usage:
--   sim/runsim                 every simulator, then a summary
--   sim/runsim farm_clone ...  just these (".lua" optional)
--   sim/runsim --list          what there is
--
-- Each simulator replaces turtle, fs, peripheral, sleep, os.pullEvent and
-- so on with its own mocks, so it runs in a sandbox: a private global
-- table (with its own copy of `os`) that the program under test is loaded
-- into as well, through the sandbox's own loadfile and require.  The real
-- computer is left alone.  CC stops a program that runs for more than a
-- few seconds without yielding, so calls into the mocked APIs yield
-- briefly about once a second.
--
-- Full output goes to sim/logs/<name>.log next to this script; the screen
-- shows it as it runs.  Ctrl+T stops everything.

local realFs, realOs, realPrint = fs, os, print
local here = realFs.getDir(shell.getRunningProgram())
local root = realFs.getDir(here)
local logDir = realFs.combine(here, "logs")

local function list()
    local names = {}
    for _, f in ipairs(realFs.list(here)) do
        local name = f:match("^(.+)%.lua$")
        if name and name ~= "runsim" then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

-- Yield to the computer if a second has passed since the last time.
local lastYield = realOs.clock()
local function breathe()
    if realOs.clock() - lastYield >= 1 then
        realOs.queueEvent("runsim")
        realOs.pullEvent("runsim")
        lastYield = realOs.clock()
    end
end

-- Mocked APIs a simulator installs as globals: their functions get a
-- breathe() in front.
local WRAP = { turtle = true, peripheral = true, fs = true, disk = true, redstone = true }
local function wrapped(f)
    return function(...) breathe(); return f(...) end
end

local function sandbox(logFile, status)
    local env = {}
    local osCopy = {}
    for k, v in pairs(realOs) do osCopy[k] = v end
    osCopy.getenv = function() return nil end
    env.os = osCopy
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        local line = table.concat(parts, " ")
        logFile.writeLine(line)
        if line:find("   ERROR:", 1, true) then status.error = true end
        return realPrint(line)
    end
    env.loadfile = function(path, mode, e) return loadfile(path, mode, e or env) end
    env.dofile = function(path) return assert(env.loadfile(path))() end
    env.package = { path = "?.lua", loaded = {} }
    env.require = function(name)
        if env.package.loaded[name] ~= nil then return env.package.loaded[name] end
        for pattern in env.package.path:gmatch("[^;]+") do
            local path = pattern:gsub("%?", (name:gsub("%.", "/")))
            if realFs.exists(path) and not realFs.isDir(path) then
                local chunk = assert(loadfile(path, nil, env))
                local result = chunk(name)
                if result == nil then result = true end
                env.package.loaded[name] = result
                return result
            end
        end
        error("module '" .. name .. "' not found", 2)
    end
    setmetatable(env, {
        __index = _G,
        __newindex = function(t, k, v)
            if WRAP[k] and type(v) == "table" then
                for fk, fv in pairs(v) do
                    if type(fv) == "function" then v[fk] = wrapped(fv) end
                end
            elseif k == "sleep" and type(v) == "function" then
                v = wrapped(v)
            end
            rawset(t, k, v)
        end,
    })
    return env
end

local function runOne(name)
    local path = realFs.combine(here, name .. ".lua")
    if not realFs.exists(path) then
        printError("No simulator " .. name)
        return "missing"
    end
    if not realFs.exists(logDir) then realFs.makeDir(logDir) end
    local logFile = realFs.open(realFs.combine(logDir, name .. ".log"), "w")
    local status = {}
    local env = sandbox(logFile, status)
    realPrint("######## " .. name)
    local chunk, err = loadfile(path, nil, env)
    local ok = chunk ~= nil
    if ok then ok, err = pcall(chunk, root) end
    if not ok then env.print("   ERROR: " .. tostring(err)) end
    logFile.close()
    return (ok and not status.error) and "ok" or "ERROR"
end

local args = { ... }
if args[1] == "--list" then
    for _, name in ipairs(list()) do realPrint(name) end
    return
end
local names = {}
for _, a in ipairs(args) do names[#names + 1] = (a:gsub("%.lua$", "")) end
if #names == 0 then names = list() end

local results = {}
for _, name in ipairs(names) do results[#results + 1] = { name, runOne(name) } end
if #results > 1 then
    realPrint("######## summary")
    for _, r in ipairs(results) do realPrint(string.format("%-8s %s", r[2], r[1])) end
end
realPrint("Full output in " .. logDir)
