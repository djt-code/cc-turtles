-- turtlelib.lua -- shared helpers for the cc-turtles programs
--
-- Usage in a program (same directory):
--     local T = require("turtlelib")
--
-- Provides:
--   * dead-reckoned position/heading (T.pos, T.dir, T.face)
--   * fuel management that refuels from inventory mid-task (T.ensureFuel)
--   * low-level moves that only dig blocks listed in T.diggable
--   * a learned 2D obstacle map with BFS routing (T.goTo)
--   * two column-stepping strategies: flat (fixed height) and terrain
--     (climb steps, follow the ground, refuse crevasses)
--   * inventory helpers, tool hot-swapping, serpentine plan generation
--   * chest-below helpers: dump with a keep policy, count, restock,
--     merge part stacks
--
-- Programs configure it by setting fields on T.cfg and T.diggable before
-- moving.  Everything is relative to where the turtle starts: (0,0,0)
-- facing +z, with +x to its right.

local T = {}

--------------------------------------------------------------------------
-- Configuration (override from the program)
--------------------------------------------------------------------------
T.cfg = {
    width      = 16,    -- tiles to the RIGHT of the start (negative = LEFT)
    length     = 16,    -- tiles AHEAD of the start (negative = BEHIND)
                        -- the start tile itself is outside the grid: x in 1..w, z in 1..l
    margin     = 1,     -- columns outside the grid usable for detours
    maxReplans = 10,    -- BFS re-plans per target before giving up
    lowFuel    = 50,    -- top up from inventory below this
    topupFuel  = 1000,  -- ...to about this level
    maxClimb   = 3,     -- terrain stepping: max climb per column
    maxDrop    = 12,    -- max blocks below start level
    maxHeight  = 16,    -- max blocks above start level
}

-- Block names the move functions are allowed to dig through.
T.diggable = {}

-- Fuel items.
T.fuel = {
    ["minecraft:coal"] = true, ["minecraft:charcoal"] = true,
    ["minecraft:coal_block"] = true, ["minecraft:lava_bucket"] = true,
    ["minecraft:blaze_rod"] = true, ["minecraft:dried_kelp_block"] = true,
}

-- Items dumpDown never throws away by default: fuel and torches.
T.keep = { ["minecraft:torch"] = true }
for name in pairs(T.fuel) do T.keep[name] = true end

--------------------------------------------------------------------------
-- Position tracking.  dir: 0=+z 1=+x 2=-z 3=-x
--------------------------------------------------------------------------
T.pos = { x = 0, y = 0, z = 0 }
T.dir = 0
local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local DZ = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
T.DX, T.DZ = DX, DZ

--------------------------------------------------------------------------
-- Position persistence.  Every successful move/turn is written to a small
-- file next to the program, so after Ctrl+T or a reboot `home` / `reset`
-- can still find the way back to the start.
--------------------------------------------------------------------------
T.mode = "flat"            -- "flat" or "terrain": which stepper to use going home

-- Path for a data file kept next to the running program.
function T.dataPath(name)
    local prog = shell and shell.getRunningProgram and shell.getRunningProgram() or ""
    return fs.combine(fs.getDir(prog), name)
end

local POS_FILE = ".turtlepos"

function T.savePos()
    local f = fs.open(T.dataPath(POS_FILE), "w")
    if not f then return end
    f.write(string.format("%d %d %d %d %s", T.pos.x, T.pos.y, T.pos.z, T.dir, T.mode))
    f.close()
end

-- Returns the saved position table or nil.
function T.loadPos()
    local p = T.dataPath(POS_FILE)
    if not fs.exists(p) then return nil end
    local f = fs.open(p, "r")
    local line = f.readAll() or ""
    f.close()
    local x, y, z, d, mode = line:match("(-?%d+) (-?%d+) (-?%d+) (%d) (%a+)")
    if not x then return nil end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z), dir = tonumber(d), mode = mode }
end

function T.clearPos()
    local p = T.dataPath(POS_FILE)
    if fs.exists(p) then fs.delete(p) end
end

-- Call at the start of a job: the turtle is at home, facing forward.
-- If a saved position says otherwise, returns it instead of resetting so
-- the program can warn the user.
function T.startAtHome(force)
    local saved = T.loadPos()
    if saved and not force and (saved.x ~= 0 or saved.y ~= 0 or saved.z ~= 0 or saved.dir ~= 0) then
        return saved
    end
    T.pos.x, T.pos.y, T.pos.z, T.dir = 0, 0, 0, 0
    T.savePos()
    return nil
end

function T.turnRight() turtle.turnRight(); T.dir = (T.dir + 1) % 4; T.savePos() end
function T.turnLeft()  turtle.turnLeft();  T.dir = (T.dir + 3) % 4; T.savePos() end

function T.face(d)
    if T.dir == d then return end
    if (T.dir + 1) % 4 == d then T.turnRight()
    elseif (T.dir + 3) % 4 == d then T.turnLeft()
    else T.turnRight(); T.turnRight() end
end

-- Face toward an adjacent column.
function T.faceToward(x, z)
    local dx, dz = x - T.pos.x, z - T.pos.z
    if dz == 1 then T.face(0) elseif dx == 1 then T.face(1)
    elseif dz == -1 then T.face(2) else T.face(3) end
end

function T.posString()
    return string.format("(%d,%d,%d)", T.pos.x, T.pos.y, T.pos.z)
end

--------------------------------------------------------------------------
-- Fuel
--------------------------------------------------------------------------
function T.refuelTo(target)
    if turtle.getFuelLevel() == "unlimited" then return true end
    if turtle.getFuelLevel() >= target then return true end
    local sel = turtle.getSelectedSlot()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            if turtle.refuel(0) then
                while turtle.getFuelLevel() < target and turtle.refuel(1) do end
            end
        end
        if turtle.getFuelLevel() >= target then break end
    end
    turtle.select(sel)
    return turtle.getFuelLevel() >= target
end

-- Called before every move.  Waits for the user if truly out of fuel.
function T.ensureFuel()
    if turtle.getFuelLevel() == "unlimited" then return end
    if turtle.getFuelLevel() >= T.cfg.lowFuel then return end
    while not T.refuelTo(T.cfg.topupFuel) and turtle.getFuelLevel() < T.cfg.lowFuel do
        print("Out of fuel at " .. T.posString() .. ". Add fuel, then press a key.")
        os.pullEvent("key")
    end
end

-- Fuel in tank plus fuel value of everything in the inventory.
-- Burns one item of each fuel type to learn its value.
function T.totalFuelAvailable()
    if turtle.getFuelLevel() == "unlimited" then return math.huge end
    local total = turtle.getFuelLevel()
    local sel = turtle.getSelectedSlot()
    for slot = 1, 16 do
        local n = turtle.getItemCount(slot)
        if n > 0 then
            turtle.select(slot)
            if turtle.refuel(0) then
                local before = turtle.getFuelLevel()
                if turtle.refuel(1) then
                    total = total + (turtle.getFuelLevel() - before) * n
                end
            end
        end
    end
    turtle.select(sel)
    return total
end

-- Block until at least `needed` fuel is available (tank + inventory),
-- filling the tank up to `needed` from inventory first.
function T.requireFuel(needed)
    while true do
        T.refuelTo(needed)
        if T.totalFuelAvailable() >= needed then return end
        print(string.format("Need ~%d fuel on board; have %s. Add fuel, then press a key.",
            needed, tostring(turtle.getFuelLevel())))
        os.pullEvent("key")
    end
end

--------------------------------------------------------------------------
-- Tool upgrades
--
-- turtle.dig() with no side tries the LEFT tool first and only falls back
-- to the right if that fails.  With a pickaxe and a hoe both equipped, a
-- left-hand pickaxe will happily break the dirt the hoe was meant to till.
-- So rather than guess sides, usePrimaryTool() makes the program's tool
-- the ONLY tool equipped: any other tool is parked in the inventory for
-- the duration and restored afterwards.  Non-tool upgrades (chunky,
-- modem, ...) are never touched.
--------------------------------------------------------------------------
local TOOL_SUFFIXES = { "_pickaxe$", "_hoe$", "_shovel$", "_axe$", "_sword$" }

function T.isTool(name)
    if not name then return false end
    for _, pat in ipairs(TOOL_SUFFIXES) do
        if name:find(pat) then return true end
    end
    return false
end

local function findEmptySlot()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then return slot end
    end
end

local function findItemSlot(name)
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and it.name == name then return slot end
    end
end

local function equipSide(side)
    if side == "left" then return turtle.equipLeft() else return turtle.equipRight() end
end

-- Name of the item equipped on `side`, or nil.  Uses getEquippedLeft/Right
-- (CC:Tweaked 1.110+); older versions are probed by swapping through an
-- empty slot, which needs one free slot.
function T.equipped(side)
    if turtle.getEquippedLeft then
        local it
        if side == "left" then it = turtle.getEquippedLeft() else it = turtle.getEquippedRight() end
        return it and it.name or nil
    end
    local empty = findEmptySlot()
    if not empty then error("Need one empty inventory slot to inspect tool upgrades", 0) end
    local sel = turtle.getSelectedSlot()
    turtle.select(empty)
    local name
    if equipSide(side) then
        local it = turtle.getItemDetail(empty)
        name = it and it.name
        equipSide(side)                   -- put it straight back
    end
    turtle.select(sel)
    return name
end

-- Equip `name` from the inventory if it isn't already, unequip any OTHER
-- tool into the inventory, and return a function that restores the
-- original arrangement.  Errors if the tool is nowhere on the turtle.
function T.usePrimaryTool(name)
    local before = { left = T.equipped("left"), right = T.equipped("right") }
    local sel = turtle.getSelectedSlot()
    local freed

    for _, side in ipairs({ "left", "right" }) do
        local item = before[side]
        if item and item ~= name and T.isTool(item) then
            local empty = findEmptySlot()
            if not empty then error("Need an empty inventory slot to unequip the " .. item, 0) end
            turtle.select(empty)
            equipSide(side)
            freed = freed or side
        end
    end

    if before.left ~= name and before.right ~= name then
        local slot = findItemSlot(name)
        if not slot then
            turtle.select(sel)
            error(name .. " is neither equipped nor in the inventory", 0)
        end
        local side = freed
            or (before.right == nil and "right")
            or (before.left == nil and "left")
        if not side then
            turtle.select(sel)
            error("Both sides hold non-tool upgrades; no room to equip " .. name, 0)
        end
        turtle.select(slot)
        equipSide(side)
    end
    turtle.select(sel)

    return function()
        local cur = turtle.getSelectedSlot()
        for _, side in ipairs({ "left", "right" }) do
            local want = before[side]
            if T.equipped(side) ~= want then
                local slot = want and findItemSlot(want) or findEmptySlot()
                if slot then turtle.select(slot); equipSide(side) end
            end
        end
        turtle.select(cur)
    end
end

-- Run fn with `name` as the only equipped tool, restoring the original
-- tools afterwards even if fn errors (the error is re-thrown).
function T.withTool(name, fn)
    local restore = T.usePrimaryTool(name)
    local ok, err = pcall(fn)
    restore()
    if not ok then error(err, 0) end
end

-- Back-compat: equip `name` onto `side` from the inventory, if present.
function T.equipTool(name, side)
    local slot = findItemSlot(name)
    if not slot then return false end
    local sel = turtle.getSelectedSlot()
    turtle.select(slot)
    local ok = equipSide(side or "right")
    turtle.select(sel)
    return ok
end

--------------------------------------------------------------------------
-- Low-level moves.  Each keeps T.pos in sync, cuts through T.diggable
-- blocks, attacks mobs, and returns false if blocked by anything else.
--------------------------------------------------------------------------
local function clearWay(inspect, dig)
    local ok, data = inspect()
    if not ok then return true end
    if T.diggable[data.name] then dig(); return true end
    return false
end

function T.up()
    if T.pos.y >= T.cfg.maxHeight then return false end
    T.ensureFuel()
    for _ = 1, 5 do
        if not clearWay(turtle.inspectUp, turtle.digUp) then return false end
        if turtle.up() then T.pos.y = T.pos.y + 1; T.savePos(); return true end
        turtle.attackUp(); sleep(0.3)
    end
    return false
end

function T.down()
    if T.pos.y <= -T.cfg.maxDrop then return false end
    T.ensureFuel()
    for _ = 1, 5 do
        if not clearWay(turtle.inspectDown, turtle.digDown) then return false end
        if turtle.down() then T.pos.y = T.pos.y - 1; T.savePos(); return true end
        turtle.attackDown(); sleep(0.3)
    end
    return false
end

function T.forward()
    T.ensureFuel()
    for _ = 1, 5 do
        if not clearWay(turtle.inspect, turtle.dig) then return false end
        if turtle.forward() then
            T.pos.x = T.pos.x + DX[T.dir]; T.pos.z = T.pos.z + DZ[T.dir]
            T.savePos()
            return true
        end
        turtle.attack(); sleep(0.3)
    end
    return false
end

-- Sink until resting on something solid.
function T.settle()
    while T.down() do end
end

-- Climb or sink to height y in the current column.
function T.toY(y)
    while T.pos.y < y and T.up() do end
    while T.pos.y > y and T.down() do end
    return T.pos.y == y
end

-- Return to y = 0.
function T.toStartHeight()
    T.toY(0)
end

-- What is directly below: a block name (or "air"), plus inspect details.
function T.below()
    local ok, d = turtle.inspectDown()
    if not ok then return "air" end
    return d.name, d
end

--------------------------------------------------------------------------
-- Obstacle map (2D, by column) and BFS routing
--------------------------------------------------------------------------
T.blocked = {}
function T.ckey(x, z) return x .. "," .. z end

-- Inverse of ckey: the x, z a key was made from.
function T.keyXZ(k)
    local x, z = k:match("(-?%d+),(-?%d+)")
    return tonumber(x), tonumber(z)
end
function T.markBlocked(x, z) T.blocked[T.ckey(x, z)] = true end
function T.clearBlocked() T.blocked = {} end

-- Sign and magnitude of a dimension: sgn(-20) -> -1, 20
local function sgn(n) if n < 0 then return -1, -n else return 1, n end end
T.sgn = sgn

function T.inBounds(x, z)
    local c = T.cfg
    local sx, w = sgn(c.width)
    local sz, l = sgn(c.length)
    local u, v = x * sx, z * sz           -- grid coords: 1..w, 1..l inside
    return u >= 1 - c.margin and u <= w + c.margin
       and v >= 1 - c.margin and v <= l + c.margin
end

local NEIGH = { { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } }

-- Shortest column path from the current position to (tx,tz), or nil.
function T.bfs(tx, tz)
    local parent = { [T.ckey(T.pos.x, T.pos.z)] = false }
    local queue, head = { { T.pos.x, T.pos.z } }, 1
    while head <= #queue do
        local n = queue[head]; head = head + 1
        local x, z = n[1], n[2]
        if x == tx and z == tz then
            local path, k, node = {}, T.ckey(x, z), n
            while parent[k] do
                table.insert(path, 1, { x = node[1], z = node[2] })
                node = parent[k]; k = T.ckey(node[1], node[2])
            end
            return path
        end
        for _, d in ipairs(NEIGH) do
            local nx, nz = x + d[1], z + d[2]
            local nk = T.ckey(nx, nz)
            if T.inBounds(nx, nz) and parent[nk] == nil and not T.blocked[nk] then
                parent[nk] = n
                queue[#queue + 1] = { nx, nz }
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- Column-stepping strategies.  Each moves one column in the current
-- facing and returns true, or marks that column blocked and returns false.
--------------------------------------------------------------------------

-- Flat: stay at the current height.
function T.stepFlat()
    local nx, nz = T.pos.x + DX[T.dir], T.pos.z + DZ[T.dir]
    if T.forward() then return true end
    T.markBlocked(nx, nz)
    return false
end

-- Terrain: climb up to maxClimb to get in, then sink onto the ground.
-- A drop deeper than maxClimb is a crevasse: back out and mark it.
function T.stepTerrain()
    local startY, startDir = T.pos.y, T.dir
    local nx, nz = T.pos.x + DX[T.dir], T.pos.z + DZ[T.dir]
    local climb = T.cfg.maxClimb
    while true do
        if T.forward() then
            while T.pos.y > startY - climb and T.down() do end
            if turtle.detectDown() then return true end
            -- crevasse: climb back, retreat, record the hole
            while T.pos.y < startY and T.up() do end
            T.face((startDir + 2) % 4)
            T.forward()
            T.face(startDir)
            T.settle()
            T.markBlocked(nx, nz)
            return false
        end
        if T.pos.y - startY >= climb or not T.up() then
            while T.pos.y > startY and T.down() do end
            T.markBlocked(nx, nz)
            return false
        end
    end
end

-- Active stepping strategy; programs set this.
T.step = T.stepFlat

-- Navigate to column (tx,tz) with BFS + re-planning.
function T.goTo(tx, tz)
    for _ = 1, T.cfg.maxReplans do
        if T.pos.x == tx and T.pos.z == tz then return true end
        local path = T.bfs(tx, tz)
        if not path then return false end
        local ok = true
        for _, n in ipairs(path) do
            T.faceToward(n.x, n.z)
            if not T.step() then ok = false; break end   -- obstacle learned
        end
        if ok then return true end
    end
    return false
end

-- Return to the start from wherever the saved position says we are.
-- Used by the `reset` subcommands and home.lua.  Returns true if home.
function T.goHome()
    local saved = T.loadPos()
    if not saved then
        print("No saved position; the turtle has not moved since its last job, or is already home.")
        return true
    end
    T.pos.x, T.pos.y, T.pos.z, T.dir = saved.x, saved.y, saved.z, saved.dir
    T.mode = saved.mode or "flat"
    T.step = (T.mode == "terrain") and T.stepTerrain or T.stepFlat
    T.clearBlocked()
    print(string.format("Last position %s facing %d (%s). Heading home.", T.posString(), T.dir, T.mode))

    if T.mode == "flat" then T.toStartHeight() end
    local ok = T.goTo(0, 0)
    if T.mode == "flat" then T.toStartHeight() else T.settle() end
    T.face(0)
    if ok and T.pos.x == 0 and T.pos.z == 0 then
        print("Home.")
        T.pos.y = 0
        T.savePos()
        return true
    end
    print("Couldn't reach home; stopped at " .. T.posString())
    return false
end

-- `reset --here`: the turtle was put back by hand, so accept where it is
-- (facing forward) as home without moving.
function T.setHomeHere()
    T.startAtHome(true)
    print("Home set to the current position.")
end

-- Start a job: startAtHome, but when the saved position says the turtle
-- is elsewhere, print the standard warning (naming the program's reset
-- command) and return false so the program can stop.
function T.requireHome(force, prog)
    local stale = T.startAtHome(force)
    if not stale then return true end
    print(string.format("Turtle may not be at home: last saved position (%d,%d,%d).",
        stale.x, stale.y, stale.z))
    print("Run `" .. prog .. " reset` to send it home, or add --here to use this spot as home.")
    return false
end

-- Remove every occurrence of `flag` from an argument list; true if found.
function T.popFlag(args, flag)
    local found = false
    for i = #args, 1, -1 do
        if args[i] == flag then found = true; table.remove(args, i) end
    end
    return found
end

--------------------------------------------------------------------------
-- Plans
--------------------------------------------------------------------------
-- Serpentine over the grid: columns along x, rows alternating in z.
-- Tiles are counted OUT from the start: x = 1..w, z = 1..l (signed), so
-- the start tile (0,0) is never part of the plan.
function T.serpentine(width, length)
    width, length = width or T.cfg.width, length or T.cfg.length
    local sx, w = sgn(width)
    local sz, l = sgn(length)
    local plan = {}
    for i = 1, w do
        if i % 2 == 1 then
            for j = 1, l do plan[#plan + 1] = { x = i * sx, z = j * sz } end
        else
            for j = l, 1, -1 do plan[#plan + 1] = { x = i * sx, z = j * sz } end
        end
    end
    return plan
end

-- Positions for light sources so that every tile of the grid is within
-- taxicab distance `radius` of one.  Uses the diamond lattice generated by
-- (r, r+1) and (r+1, -r), which tiles the plane with L1 balls exactly, and
-- clamps lattice points that fall outside the grid onto its edge (which can
-- only shorten their distance to tiles inside).  Returns a set keyed by
-- T.ckey plus an ordered list.
-- Computed on a 0-based grid, then shifted to the 1-based, signed grid
-- the plan uses; the start tile (0,0) is outside it and never gets a torch.
function T.lightLattice(radius, width, length)
    width, length = width or T.cfg.width, length or T.cfg.length
    local sx, sz
    sx, width = sgn(width)
    sz, length = sgn(length)
    local r = radius
    local set, list = {}, {}
    local K = math.ceil((width + length) / r) + 2
    for a = -K, K do
        for b = -K, K do
            local x = a * r + b * (r + 1) + 1
            local z = a * (r + 1) - b * r + 1
            -- L1 distance from the point to the rectangle
            local dx = math.max(0, -x, x - (width - 1))
            local dz = math.max(0, -z, z - (length - 1))
            if dx + dz <= r then
                local cx = math.max(0, math.min(width - 1, x))
                local cz = math.max(0, math.min(length - 1, z))
                cx, cz = (cx + 1) * sx, (cz + 1) * sz
                local k = T.ckey(cx, cz)
                if not set[k] then
                    set[k] = true
                    list[#list + 1] = { x = cx, z = cz }
                end
            end
        end
    end
    return set, list
end

--------------------------------------------------------------------------
-- Inventory
--------------------------------------------------------------------------
function T.selectItem(name)
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and it.name == name then turtle.select(slot); return true end
    end
    return false
end

function T.countItem(name)
    local n = 0
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and it.name == name then n = n + it.count end
    end
    return n
end

function T.inventoryFull()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then return false end
    end
    return true
end

function T.freeSlots()
    local n = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then n = n + 1 end
    end
    return n
end

function T.isContainer(name)
    return name:find("chest") ~= nil or name:find("barrel") ~= nil
end

function T.containerBelow()
    local ok, data = turtle.inspectDown()
    return ok and T.isContainer(data.name)
end

-- What a dump would drop: a list of { slot, n }.  keepCount(item, kept)
-- returns how many of that item to keep (default: all of T.keep items,
-- none of others).
local function dumpPlan(keepCount)
    local plan, kept = {}, {}
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it then
            local keep
            if T.isTool(it.name) then
                keep = it.count                   -- never dump a parked tool
            elseif keepCount then
                keep = keepCount(it, kept[it.name] or 0)
            else
                keep = T.keep[it.name] and it.count or 0
            end
            kept[it.name] = (kept[it.name] or 0) + math.min(keep, it.count)
            if it.count > keep then plan[#plan + 1] = { slot = slot, n = it.count - keep } end
        end
    end
    return plan
end

-- Would dumpDown(keepCount) get rid of anything?
function T.wouldDump(keepCount)
    return #dumpPlan(keepCount) > 0
end

-- Drop inventory into the container below.  Returns false if there is no
-- container below; otherwise true and how many items didn't fit (the
-- container is full).
function T.dumpDown(keepCount)
    if not T.containerBelow() then return false end
    local left = 0
    for _, d in ipairs(dumpPlan(keepCount)) do
        local before = turtle.getItemCount(d.slot)
        turtle.select(d.slot)
        turtle.dropDown(d.n)
        left = left + d.n - (before - turtle.getItemCount(d.slot))
    end
    turtle.select(1)
    return true, left
end

-- dumpDown, but while the container is full, stop and wait for room,
-- checking every `interval` seconds.  Returns false if there is no
-- container below.
function T.dumpDownWait(keepCount, interval)
    local ok, left = T.dumpDown(keepCount)
    if not ok then return false end
    if left > 0 then
        print(string.format("Chest is full (%d items didn't fit); waiting for room.", left))
        repeat
            sleep(interval or 30)
            ok, left = T.dumpDown(keepCount)
        until not ok or left == 0
        print("Chest has room again; carrying on.")
    end
    return true
end

-- Print one line listing what the turtle is carrying.
function T.inventoryLine(label)
    local counts, order = {}, {}
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it then
            local name = it.name:gsub("^minecraft:", "")
            if not counts[name] then order[#order + 1] = name; counts[name] = 0 end
            counts[name] = counts[name] + it.count
        end
    end
    local parts = {}
    for _, name in ipairs(order) do parts[#parts + 1] = counts[name] .. " " .. name end
    print(label .. ": " .. (#parts > 0 and table.concat(parts, ", ") or "nothing"))
end

-- Make sure at least `need` slots are free before working a tile whose
-- drops must not spill: if short, and dumping with keepCount would free
-- something, call goDump() (the program's trip to its chest).  Prints
-- `warning` once if still short, and stops making trips that free
-- nothing (no chest) until slots open up again.
local warnedRoom, dumpFreesNothing = false, false
function T.ensureRoom(need, keepCount, goDump, warning)
    if T.freeSlots() >= need then dumpFreesNothing = false; return true end
    if not dumpFreesNothing and T.wouldDump(keepCount) then
        local before = T.freeSlots()
        goDump()
        if T.freeSlots() >= need then return true end
        if T.freeSlots() <= before then dumpFreesNothing = true end
    end
    if warning and not warnedRoom then
        warnedRoom = true
        print(warning)
    end
    return false
end

--------------------------------------------------------------------------
-- A container as a peripheral on one of the turtle's three interaction
-- sides ("front", "top" or "bottom", the CC:Tweaked names for turtle.suck/
-- drop/inspect and their Up/Down variants): counting, tidying, restocking.
-- Everything degrades gracefully when it can't be wrapped (restocking
-- falls back to blind sucking).
--------------------------------------------------------------------------

-- The turtle.suck/drop/inspect triple for a given side.
local function sideFuncs(side)
    if side == "front" then return turtle.suck, turtle.drop, turtle.inspect end
    if side == "top" then return turtle.suckUp, turtle.dropUp, turtle.inspectUp end
    if side == "bottom" then return turtle.suckDown, turtle.dropDown, turtle.inspectDown end
    error("Unknown turtle side (want front/top/bottom): " .. tostring(side), 0)
end

-- How many `name` the container on `side` holds, or nil if it can't be read.
function T.countContainer(side, name)
    local chest = peripheral and peripheral.wrap(side)
    if not (chest and chest.list) then return nil end
    local n = 0
    for _, it in pairs(chest.list()) do
        if it.name == name then n = n + it.count end
    end
    return n
end

-- Merge part stacks of the same item in the container on `side`, so
-- everything sits in as few slots as it can.  Hoppers and the turtle's
-- own partial takes leave small stacks scattered about.  Uses the
-- container's pushItems, filling the earliest part stack from the latest.
function T.compactContainer(side)
    local chest = peripheral and peripheral.wrap(side)
    if not (chest and chest.list and chest.pushItems and chest.getItemDetail) then return end
    local self = peripheral.getName(chest)
    pcall(function()
        local groups = {}
        for slot, it in pairs(chest.list()) do
            local key = it.name .. "|" .. (it.nbt or "")
            groups[key] = groups[key] or {}
            table.insert(groups[key], { slot = slot, count = it.count })
        end
        for _, g in pairs(groups) do
            if #g > 1 then
                local max = (chest.getItemDetail(g[1].slot) or {}).maxCount or 64
                local part = {}
                for _, s in ipairs(g) do
                    if s.count < max then part[#part + 1] = s end
                end
                table.sort(part, function(a, b) return a.slot < b.slot end)
                local i, j = 1, #part
                while i < j do
                    local n = chest.pushItems(self, part[j].slot,
                        math.min(max - part[i].count, part[j].count), part[i].slot)
                    if n == 0 then break end
                    part[i].count, part[j].count = part[i].count + n, part[j].count - n
                    if part[j].count == 0 then j = j - 1 end
                    if part[i].count >= max then i = i + 1 end
                end
            end
        end
    end)
end

-- Move a stack of `name` into the container's first slot, where sucking
-- from it takes from.  Whatever is in slot 1 goes to an empty slot, or,
-- with the container full, into an empty turtle slot that is returned so
-- the caller can put it back.  Returns found, held.
local function frontStack(chest, name)
    local items = chest.list()
    local from
    for slot, it in pairs(items) do
        if it.name == name and (not from or slot < from) then from = slot end
    end
    if not from then return false end
    if from == 1 then return true end
    local self = peripheral.getName(chest)
    local held
    if items[1] then
        local empty
        for s = 2, chest.size() do
            if not items[s] then empty = s; break end
        end
        if empty then
            chest.pushItems(self, 1, 64, empty)
        else
            held = findEmptySlot()
            if not held then return false end
            turtle.select(held)
            turtle.suckDown(64)
        end
    end
    return chest.pushItems(self, from, 64, 1) > 0, held
end

-- Pull `name` out of the container on `side` until we hold `target` of
-- it.  Sucking from a side always takes from the container's first
-- occupied slot regardless of what it is, so with a readable container
-- the wanted stack is moved to the front first (frontStack) and exactly
-- what's needed is taken.  Otherwise anything else that comes out is set
-- aside and dropped back once we're done (fuel is kept).  opts: label
-- (for messages), quiet (report nothing), room (free slots to leave
-- untouched, default 1).
local restockWarned = {}
function T.restockFrom(side, name, target, opts)
    opts = opts or {}
    local room = opts.room or 1
    local label = opts.label or name
    local suck, drop = sideFuncs(side)
    if target <= 0 or T.countItem(name) >= target then return end

    local chest = peripheral and peripheral.wrap(side)
    if chest and chest.list then
        local any = false
        for _, it in pairs(chest.list()) do
            if it.name == name then any = true; break end
        end
        if not any then
            local key = side .. "|" .. name
            if not opts.quiet and not restockWarned[key] then
                restockWarned[key] = true
                print("Nothing on the " .. side .. " to restock " .. label:lower() .. " from.")
            end
            return
        end
        restockWarned[side .. "|" .. name] = nil
    end

    local fronted = chest and chest.pushItems and chest.size and pcall(function()
        while T.countItem(name) < target and T.freeSlots() > room do
            local found, held = frontStack(chest, name)
            if not found then break end
            turtle.select(1)
            local got = suck(math.min(64, target - T.countItem(name)))
            if held then turtle.select(held); drop() end
            if not got then break end
        end
    end)

    local junk = {}
    for _ = 1, 54 do                              -- a double chest's worth
        if fronted or T.countItem(name) >= target then break end
        local before = {}
        for s = 1, 16 do before[s] = turtle.getItemCount(s) end
        if T.freeSlots() <= room then break end   -- leave room for drops and tool swaps
        if not suck(64) then break end            -- container empty
        for s = 1, 16 do
            local got = turtle.getItemCount(s) - before[s]
            if got > 0 then
                local it = turtle.getItemDetail(s)
                if it and it.name ~= name and not T.fuel[it.name] then
                    junk[#junk + 1] = { slot = s, n = got }   -- only what came out
                end
            end
        end
    end
    for _, j in ipairs(junk) do
        turtle.select(j.slot)
        drop(j.n)
    end
    -- whole stacks come out, so hand back anything over the target
    local extra = T.countItem(name) - target
    for s = 16, 1, -1 do
        if extra <= 0 then break end
        local it = turtle.getItemDetail(s)
        if it and it.name == name then
            local n = math.min(extra, it.count)
            turtle.select(s)
            drop(n)
            extra = extra - n
        end
    end
    turtle.select(1)
    if not opts.quiet then
        print(string.format("%s on board: %d (target %d)", label, T.countItem(name), target))
    end
end

return T
