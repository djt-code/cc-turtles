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
--
-- Programs configure it by setting fields on T.cfg and T.diggable before
-- moving.  Everything is relative to where the turtle starts: (0,0,0)
-- facing +z, with +x to its right.

local T = {}

--------------------------------------------------------------------------
-- Configuration (override from the program)
--------------------------------------------------------------------------
T.cfg = {
    width      = 16,    -- grid size in x
    length     = 16,    -- grid size in z
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

-- Items dumpDown never throws away.
T.keep = {
    ["minecraft:coal"] = true, ["minecraft:charcoal"] = true,
    ["minecraft:coal_block"] = true, ["minecraft:lava_bucket"] = true,
    ["minecraft:blaze_rod"] = true, ["minecraft:dried_kelp_block"] = true,
}

--------------------------------------------------------------------------
-- Position tracking.  dir: 0=+z 1=+x 2=-z 3=-x
--------------------------------------------------------------------------
T.pos = { x = 0, y = 0, z = 0 }
T.dir = 0
local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local DZ = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
T.DX, T.DZ = DX, DZ

function T.turnRight() turtle.turnRight(); T.dir = (T.dir + 1) % 4 end
function T.turnLeft()  turtle.turnLeft();  T.dir = (T.dir + 3) % 4 end

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
-- Tool upgrades.  Keep the chunky upgrade on the LEFT; tools go RIGHT.
--------------------------------------------------------------------------
function T.equipTool(name, side)
    side = side or "right"
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it and it.name == name then
            local sel = turtle.getSelectedSlot()
            turtle.select(slot)
            local ok = (side == "left") and turtle.equipLeft() or turtle.equipRight()
            turtle.select(sel)
            return ok
        end
    end
    return false   -- not in inventory: assume already equipped
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
        if turtle.up() then T.pos.y = T.pos.y + 1; return true end
        turtle.attackUp(); sleep(0.3)
    end
    return false
end

function T.down()
    if T.pos.y <= -T.cfg.maxDrop then return false end
    T.ensureFuel()
    for _ = 1, 5 do
        if not clearWay(turtle.inspectDown, turtle.digDown) then return false end
        if turtle.down() then T.pos.y = T.pos.y - 1; return true end
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

-- Return to y = 0.
function T.toStartHeight()
    while T.pos.y < 0 and T.up() do end
    while T.pos.y > 0 and T.down() do end
end

--------------------------------------------------------------------------
-- Obstacle map (2D, by column) and BFS routing
--------------------------------------------------------------------------
T.blocked = {}
function T.ckey(x, z) return x .. "," .. z end
function T.markBlocked(x, z) T.blocked[T.ckey(x, z)] = true end
function T.clearBlocked() T.blocked = {} end

function T.inBounds(x, z)
    local c = T.cfg
    return x >= -c.margin and x < c.width + c.margin
       and z >= -c.margin and z < c.length + c.margin
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

--------------------------------------------------------------------------
-- Plans
--------------------------------------------------------------------------
-- Serpentine over the grid: columns along +x, rows alternating in z.
function T.serpentine(width, length)
    width, length = width or T.cfg.width, length or T.cfg.length
    local plan = {}
    for x = 0, width - 1 do
        if x % 2 == 0 then
            for z = 0, length - 1 do plan[#plan + 1] = { x = x, z = z } end
        else
            for z = length - 1, 0, -1 do plan[#plan + 1] = { x = x, z = z } end
        end
    end
    return plan
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

function T.isContainer(name)
    return name:find("chest") ~= nil or name:find("barrel") ~= nil
end

function T.containerBelow()
    local ok, data = turtle.inspectDown()
    return ok and T.isContainer(data.name)
end

-- Drop inventory into the container below.  keepCount(item) returns how
-- many of that item to keep (default: all of T.keep items, none of others).
-- Returns false if there is no container below.
function T.dumpDown(keepCount)
    if not T.containerBelow() then return false end
    local kept = {}
    for slot = 1, 16 do
        local it = turtle.getItemDetail(slot)
        if it then
            local keep
            if keepCount then
                keep = keepCount(it, kept[it.name] or 0)
            else
                keep = T.keep[it.name] and it.count or 0
            end
            kept[it.name] = (kept[it.name] or 0) + math.min(keep, it.count)
            local dropN = it.count - keep
            if dropN > 0 then
                turtle.select(slot)
                turtle.dropDown(dropN)
            end
        end
    end
    turtle.select(1)
    return true
end

return T
