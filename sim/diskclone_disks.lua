-- sim/diskclone_disks.lua
--
-- diskclone.lua with a mock drive and dispenser: a mix of blank,
-- labelled and non-empty disks with and without --force, a disk too small
-- for the directory, a disk already in the drive at start, an empty
-- dispenser, and a source directory with no LABEL file.
--
-- Mock CC computer + drive + dispenser for diskclone.lua.
local PROJ = ...
local MIN = 500

-- virtual filesystem: dirs are tables, files are strings
local root = { src = { LABEL = "Farm Kit\nsecond line\n", ["farm.lua"] = string.rep("x", 3000),
                       lib = { ["turtlelib.lua"] = string.rep("y", 2000) }, ["startup.lua"] = "print('hi')" } }
local drive = { disk = nil }        -- disk in the drive: { label, tree, cap, floppy }

local function split(p) local t = {}; for s in p:gmatch("[^/]+") do t[#t + 1] = s end; return t end
local function node(p)
    local parts = split(p)
    local cur = root
    for i, s in ipairs(parts) do
        if i == 1 and s == "disk" then
            if not (drive.disk and drive.disk.floppy) then return nil end
            cur = drive.disk.tree
        else
            if type(cur) ~= "table" then return nil end
            cur = cur[s]
            if cur == nil then return nil end
        end
    end
    return cur
end
local function parentOf(p)
    local parts = split(p); local name = table.remove(parts)
    return node(table.concat(parts, "/")), name, parts[1]
end
local function used(t)
    local n = 0
    for _, v in pairs(t) do
        if type(v) == "table" then n = n + MIN + used(v) else n = n + math.max(#v, MIN) end
    end
    return n
end
local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local c = {}; for k, x in pairs(v) do c[k] = deepcopy(x) end; return c
end

fs = {
    combine = function(a, b) if a == "" then return b end; return a .. "/" .. b end,
    exists = function(p) return node(p) ~= nil end,
    isDir = function(p) return type(node(p)) == "table" end,
    list = function(p)
        local n = node(p); assert(type(n) == "table", "not a dir: " .. p)
        local t = {}; for k in pairs(n) do t[#t + 1] = k end; table.sort(t); return t
    end,
    getSize = function(p) local n = node(p); return type(n) == "string" and #n or 0 end,
    delete = function(p) local par, name = parentOf(p); if par then par[name] = nil end end,
    getFreeSpace = function(p)
        if p:match("^disk") then return drive.disk.cap - used(drive.disk.tree) end
        return 1e6
    end,
    copy = function(a, b)
        local src = node(a); assert(src ~= nil, "no such file " .. a)
        local par, name, top = parentOf(b)
        assert(par and par[name] == nil, "destination exists " .. b)
        par[name] = deepcopy(src)
        if top == "disk" and used(drive.disk.tree) > drive.disk.cap then
            par[name] = nil; error("Out of space")
        end
    end,
    open = function(p, mode)
        local data = node(p); local pos = 1
        return { readLine = function()
                    if pos > #data then return nil end
                    local e = data:find("\n", pos) or #data + 1
                    local l = data:sub(pos, e - 1); pos = e + 1; return l
                 end,
                 close = function() end }
    end,
}
shell = { resolve = function(p) return p end }
peripheral = { getType = function(side) return side == "bottom" and "drive" or nil end }

-- dispenser queue; ejected disks land in `out`
local queue, out, events, timers, pulses = {}, {}, {}, 0, 0
local rsOn = false
redstone = {
    setOutput = function(side, on)
        assert(side == "back")
        if on and not rsOn then
            pulses = pulses + 1
            local d = table.remove(queue, 1)
            if d then drive.disk = d; events[#events + 1] = { "disk", "bottom" } end
        end
        rsOn = on
    end,
}
disk = {
    isPresent = function() return drive.disk ~= nil end,
    hasData = function() return drive.disk ~= nil and drive.disk.floppy end,
    getMountPath = function() return "disk" end,
    getLabel = function() return drive.disk.label end,
    setLabel = function(_, l) drive.disk.label = l end,
    eject = function() out[#out + 1] = drive.disk; drive.disk = nil; events[#events + 1] = { "disk_eject", "bottom" } end,
}
os.startTimer = function() timers = timers + 1; events[#events + 1] = { "timer", timers }; return timers end
os.pullEvent = function()
    local e = table.remove(events, 1)
    if not e then error("no events left (would hang)") end
    return e[1], e[2]
end
sleep = function() end
printError = function(m) print("ERR: " .. m) end

local function floppy(label, tree, cap) return { label = label, tree = tree or {}, cap = cap or 125000, floppy = true } end

local function run(...)
    print("== diskclone " .. table.concat({ ... }, " "))
    local ok, err = pcall(assert(loadfile(PROJ .. "/diskclone.lua")), ...)
    if not ok and err ~= "" then print("   error: " .. tostring(err)) end
    for i, d in ipairs(out) do
        local files = d.floppy and table.concat(fs_list_tree(d.tree), " ") or "-"
        print(string.format("   out %d: label=%s files=%s", i, tostring(d.label), files))
    end
    print(string.format("   pulses=%d left in dispenser=%d rs=%s", pulses, #queue, tostring(rsOn)))
end
function fs_list_tree(t, pre)
    local r = {}
    local keys = {}; for k in pairs(t) do keys[#keys + 1] = k end; table.sort(keys)
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) == "table" then for _, s in ipairs(fs_list_tree(v, (pre or "") .. k .. "/")) do r[#r + 1] = s end
        else r[#r + 1] = (pre or "") .. k .. "(" .. #v .. ")" end
    end
    return r
end

-- 1. mixed stack, no --force
queue = { floppy(), floppy("Old Label"), floppy(nil, { junk = "abc" }), { floppy = false }, floppy() }
run("src")

-- 2. same mix with --force, limited to 3 written
out, pulses, queue = {}, 0, { floppy("Old Label"), floppy(nil, { junk = "abc" }), floppy(), floppy(), floppy() }
run("src", "3", "--force")

-- 3. a disk too small for the directory
out, pulses, queue = {}, 0, { floppy(nil, nil, 4000), floppy() }
run("src")

-- 4. a disk already sitting in the drive at start, then empty dispenser
out, pulses, queue = {}, 0, {}
drive.disk = floppy()
run("src")

-- 5. bad input: no LABEL
root.nolabel = { a = "x" }
out, pulses = {}, 0
run("nolabel")
