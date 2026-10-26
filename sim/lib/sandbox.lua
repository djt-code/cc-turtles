-- sim/lib/sandbox.lua -- run a simulator on a CC computer without letting
-- its mocks loose on the real one.  Shared by runsim.lua and watchsim.lua.
--
-- Each simulator replaces turtle, fs, peripheral, sleep, os.pullEvent and
-- so on with its own mocks, so it runs in a sandbox: a private global
-- table (with its own copy of `os`) that the program under test is loaded
-- into as well, through the sandbox's own loadfile and require.  CC stops a
-- program that runs for more than a few seconds without yielding, so calls
-- into the mocked APIs yield briefly about once a second.

local realFs, realOs = fs, os
local M = {}

-- Yield to the computer if a second has passed since the last time.
local lastYield = realOs.clock()
function M.breathe()
    if realOs.clock() - lastYield >= 1 then
        realOs.queueEvent("sandbox")
        realOs.pullEvent("sandbox")
        lastYield = realOs.clock()
    end
end

-- Mocked APIs a simulator installs as globals: their functions get a
-- breathe() in front and the onCall hook after.
local WRAP = { turtle = true, peripheral = true, fs = true, disk = true, redstone = true }

local function join(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    return table.concat(parts, " ")
end

-- A fresh sandbox.  opts:
--   print(line)          the sandbox's print (required)
--   onCall(api, name)    after every call into a mocked API
--   onLoad(path, args)   when the simulator runs a program it loaded
--   onPrint(line)        every line through a print the simulator installs
--                        itself (the program's own output, as it happens)
function M.new(opts)
    -- The sandbox's own versions of globals live in `base`, behind env's
    -- __index, so a simulator assigning one (print, say) still goes
    -- through __newindex below.
    local env, base = {}, {}
    local osCopy = {}
    for k, v in pairs(realOs) do osCopy[k] = v end
    osCopy.getenv = function() return nil end
    env.os = osCopy
    base.print = function(...) return opts.print(join(...)) end
    env.loadfile = function(path, mode, e)
        local chunk, err = loadfile(path, mode, e or env)
        if not (chunk and opts.onLoad) then return chunk, err end
        return function(...) opts.onLoad(path, { ... }); return chunk(...) end
    end
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
    local function wrapped(api, name, f)
        return function(...)
            M.breathe()
            if not opts.onCall then return f(...) end
            local r = table.pack(f(...))
            opts.onCall(api, name)
            return table.unpack(r, 1, r.n)
        end
    end
    setmetatable(env, {
        __index = function(_, k)
            local v = base[k]
            if v == nil then v = _G[k] end
            return v
        end,
        __newindex = function(t, k, v)
            if WRAP[k] and type(v) == "table" then
                for fk, fv in pairs(v) do
                    if type(fv) == "function" then v[fk] = wrapped(k, fk, fv) end
                end
            elseif k == "sleep" and type(v) == "function" then
                v = wrapped(nil, k, v)
            elseif k == "print" and type(v) == "function" and opts.onPrint then
                local inner = v
                v = function(...) opts.onPrint(join(...)); return inner(...) end
            end
            rawset(t, k, v)
        end,
    })
    return env
end

-- Run the simulator at `path` in `env`, handing it the repo root.
function M.run(path, root, env)
    local chunk, err = loadfile(path, nil, env)
    if not chunk then return false, err end
    return pcall(chunk, root)
end

-- Simulator names in `dir`: its .lua files, less the tools.
local TOOLS = { runsim = true, watchsim = true }
function M.list(dir)
    local names = {}
    for _, f in ipairs(realFs.list(dir)) do
        local name = f:match("^(.+)%.lua$")
        if name and not TOOLS[name] then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

return M
