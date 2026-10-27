-- mine.lua -- tunnel-mining turtle for CC:Tweaked
--
-- Needs a pickaxe (any *_pickaxe upgrade), equipped or in the inventory.
-- Any other tool is parked in the inventory while it runs and put back
-- afterwards.  Optional: Advanced Peripherals Chunky Turtle upgrade so it
-- keeps running unattended.
--
-- Usage:  mine <length> <width> <height> [--here]
--         mine reset            return to the start after a stop
--         mine reset --here     turtle was put back by hand: reset position
--
-- length = blocks the tunnel runs ahead of the turtle
-- width  = blocks to the RIGHT of the turtle (negative = to the LEFT)
-- height = blocks UP from the turtle (negative = DOWN)
-- The turtle's own column and row are part of the tunnel: it stands in
-- the mouth at one bottom (or top, for negative heights) corner, and the
-- tunnel starts with the block in front of it.  `mine 32 3 3` digs a 3x3
-- tunnel 32 long, up and to the right of the turtle.
--
-- Placement: put the turtle where the tunnel's corner should start,
-- facing along it.  Put a chest/barrel directly ABOVE the start for
-- valuables and one directly BELOW it for bulk (stone, cobblestone,
-- deepslate, dirt, gravel, sand...).  Put fuel in the valuables chest;
-- coal the turtle mines lands there too and fuels it as well.
--
-- How it works:
--  * Lanes: the tunnel is mined in lanes running along its length, one
--    per row in the side columns and every third row (plus the top and
--    bottom ones) in the middle columns, digging the rows in between up
--    and down.  So the turtle touches every block of the walls, floor,
--    ceiling and far end, and looks at each one.
--  * Veins: an ore it touches (anything tagged as an ore, *_ore blocks,
--    ancient debris) is mined along with its whole vein: the turtle
--    follows it block by block, looking all round each one, up to
--    VEIN_REACH blocks out from the tunnel, never back past the start.
--  * Lava and water touching the tunnel or a vein are sealed with a bulk
--    block from the inventory (it keeps a stack for this).  Turtles take
--    no harm from lava, but lava burns any item that falls in it and
--    makes the tunnel deadly for players.  Lava or water inside the
--    tunnel is filled and dug out.
--  * Room and fuel: before a dig with fewer than ROOM empty slots, or a
--    move that would leave too little fuel to get home, the turtle goes
--    home, sorts what it carries into the two chests, refuels from the
--    valuables chest (waiting there if there's no fuel), then returns to
--    the same spot, back up the vein if it was in one.
--  * Never digs chests, barrels, shulker boxes, spawners or ComputerCraft
--    blocks (other turtles, computers).  An unbreakable block (bedrock) in
--    the tunnel ends the job: the turtle goes home and says where.
--  * Position is saved after every move, so `mine reset` can bring it
--    home after a Ctrl+T or a server restart.

local T = require("turtlelib")

local JOB_FILE = T.dataPath("mine.job")
local VEIN_REACH = 4       -- how far a vein is followed out from the tunnel
local ROOM = 2             -- empty slots wanted before each dig
local FILLER_KEEP = 64     -- bulk blocks kept on board for sealing
local FUEL_WORK = 100      -- fuel for some work after a trip back out
local VALUABLE_SIDE, BULK_SIDE = "top", "bottom"

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
local args = { ... }
local forceHere = T.popFlag(args, "--here")
local doReset = args[1] == "reset"
local LENGTH, WIDTH, HEIGHT
if not doReset then
    LENGTH, WIDTH, HEIGHT = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not (LENGTH and WIDTH and HEIGHT) or LENGTH < 1 or WIDTH == 0 or HEIGHT == 0 then
        print("Usage: mine <length> <width> <height> [--here]")
        print("       mine reset [--here]")
        print("width: + right / - left; height: + up / - down")
        return
    end
end

--------------------------------------------------------------------------
-- Blocks and items
--------------------------------------------------------------------------
local LAVA, WATER = "minecraft:lava", "minecraft:water"
local FLUID = { [LAVA] = true, [WATER] = true }
local ORE_EXTRA = { ["minecraft:ancient_debris"] = true }

local function isOre(data)
    if data.name:find("_ore$") or ORE_EXTRA[data.name] then return true end
    for tag in pairs(data.tags or {}) do
        if tag == "c:ores" or tag == "forge:ores" or tag:find("_ores$") then return true end
    end
    return false
end

-- Blocks never to dig: storage, spawners and ComputerCraft blocks.
local function protected(name)
    return name:find("chest") or name:find("barrel") or name:find("shulker")
        or name:find("spawner") or name:find("^computercraft:")
end

-- Bulk items go in the bottom chest; everything else is a valuable.
local BULK = {}
for _, n in ipairs({ "cobblestone", "cobbled_deepslate", "stone", "deepslate", "dirt",
        "coarse_dirt", "rooted_dirt", "gravel", "sand", "red_sand", "sandstone",
        "red_sandstone", "andesite", "diorite", "granite", "tuff", "calcite",
        "dripstone_block", "pointed_dripstone", "netherrack", "blackstone", "basalt",
        "smooth_basalt", "soul_sand", "soul_soil", "end_stone", "flint", "mud",
        "clay", "moss_block", "terracotta", "magma_block" }) do
    BULK["minecraft:" .. n] = true
end
local BULK_TAGS = {
    ["c:stones"] = true, ["forge:stone"] = true, ["c:cobblestones"] = true,
    ["forge:cobblestone"] = true, ["minecraft:stone_tool_materials"] = true,
    ["minecraft:stone_crafting_materials"] = true, ["minecraft:dirt"] = true,
    ["c:gravels"] = true, ["forge:gravel"] = true, ["c:sands"] = true,
    ["forge:sand"] = true, ["minecraft:sand"] = true,
}
local function isBulk(it)
    if BULK[it.name] then return true end
    for tag in pairs(it.tags or {}) do
        if BULK_TAGS[tag] then return true end
    end
    return false
end

-- Bulk blocks that can seal lava and water (solid, and they don't fall).
local FILLER = {}
for _, n in ipairs({ "cobblestone", "cobbled_deepslate", "netherrack", "dirt", "andesite",
        "diorite", "granite", "tuff", "calcite", "blackstone", "basalt", "end_stone",
        "stone", "deepslate" }) do
    FILLER["minecraft:" .. n] = true
end

T.cfg.maxHeight, T.cfg.maxDrop = 1000, 1000    -- the tunnel sets the limits
T.diggable = { [LAVA] = true, [WATER] = true }  -- move into fluids (digging them does nothing)

--------------------------------------------------------------------------
-- Tunnel geometry: x in X0..X1, y in Y0..Y1, z in 1..LENGTH
--------------------------------------------------------------------------
local X0, X1, Y0, Y1

local function setBox()
    X0, X1 = math.min(0, WIDTH - T.sgn(WIDTH)), math.max(0, WIDTH - T.sgn(WIDTH))
    Y0, Y1 = math.min(0, HEIGHT - T.sgn(HEIGHT)), math.max(0, HEIGHT - T.sgn(HEIGHT))
end

local function inBox(p)
    return p.x >= X0 and p.x <= X1 and p.y >= Y0 and p.y <= Y1 and p.z >= 1 and p.z <= LENGTH
end

-- Within VEIN_REACH of the tunnel, and not back past its start.
local function inReach(p)
    if p.z < 1 then return false end
    local dx = math.max(X0 - p.x, 0, p.x - X1)
    local dy = math.max(Y0 - p.y, 0, p.y - Y1)
    local dz = math.max(0, p.z - LENGTH)
    return math.max(dx, dy, dz) <= VEIN_REACH
end

local function saveJob()
    local f = fs.open(JOB_FILE, "w")
    f.write(LENGTH .. " " .. WIDTH .. " " .. HEIGHT)
    f.close()
end

local function loadJob()
    if not fs.exists(JOB_FILE) then return false end
    local f = fs.open(JOB_FILE, "r")
    local l, w, h = (f.readAll() or ""):match("(-?%d+) (-?%d+) (-?%d+)")
    f.close()
    if not l then return false end
    LENGTH, WIDTH, HEIGHT = tonumber(l), tonumber(w), tonumber(h)
    return true
end

--------------------------------------------------------------------------
-- Directions: 0..3 as turtlelib's T.dir (0 = +z ahead, 1 = +x right),
-- plus "up" and "down".
--------------------------------------------------------------------------
local DELTA = {
    [0] = { 0, 0, 1 }, [1] = { 1, 0, 0 }, [2] = { 0, 0, -1 }, [3] = { -1, 0, 0 },
    up = { 0, 1, 0 }, down = { 0, -1, 0 },
}
local OPP = { [0] = 2, [1] = 3, [2] = 0, [3] = 1, up = "down", down = "up" }

local function neighbour(d)
    local v = DELTA[d]
    return { x = T.pos.x + v[1], y = T.pos.y + v[2], z = T.pos.z + v[3] }
end

local function key(p) return p.x .. "," .. p.y .. "," .. p.z end

local function look(d)
    if d == "up" then return turtle.inspectUp() end
    if d == "down" then return turtle.inspectDown() end
    T.face(d)
    return turtle.inspect()
end

local function digDir(d)
    if d == "up" then return turtle.digUp() end
    if d == "down" then return turtle.digDown() end
    T.face(d)
    return turtle.dig()
end

local function placeDir(d)
    if d == "up" then return turtle.placeUp() end
    if d == "down" then return turtle.placeDown() end
    T.face(d)
    return turtle.place()
end

local function moveDir(d)
    if d == "up" then return T.up() end
    if d == "down" then return T.down() end
    T.face(d)
    return T.forward()
end

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------
local opened = {}          -- key(p) = true: known to be air (dug or visited)
local trail = {}           -- directions moved out of the tunnel into a vein
local inTrip = false
local fuelGoal = 0
local stats = { veins = 0, ore = 0, sealed = 0 }
local stuck                -- why the job stopped early, if it did

-- Fuel home: back down the vein, then along the tunnel.
function T.homeCost()
    return math.abs(T.pos.x) + math.abs(T.pos.y) + math.abs(T.pos.z) + 2 * #trail + 2
end

--------------------------------------------------------------------------
-- Moving and digging
--------------------------------------------------------------------------
local trip                 -- defined below

-- Make room before a dig: a trip home if fewer than ROOM slots are free.
local function room()
    if not inTrip and T.freeSlots() < ROOM then trip("Inventory nearly full") end
end

local function isSource(data)
    return FLUID[data.name] and data.state and tonumber(data.state.level) == 0
end

local seal

-- Step one block in direction d, digging what's there (falling gravel
-- and sand included); a lava or water source in the tunnel is filled and
-- dug out first, so none is left behind.  False if it can't: a protected
-- or unbreakable block, or something that won't move out of the way.
local function go(d)
    for _ = 1, 30 do
        room()                     -- first: a trip changes what's there
        local ok, data = look(d)
        if ok and isSource(data) and inBox(neighbour(d)) and seal(d) then
            ok, data = look(d)
        end
        if ok and not FLUID[data.name] then
            if protected(data.name) then return false, data.name end
            if not digDir(d) then return false, data.name end
        end
        if moveDir(d) then
            opened[key(T.pos)] = true
            return true
        end
    end
    return false, "something in the way"
end

local function selectFiller()
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and FILLER[it.name] then turtle.select(s); return true end
    end
    return false
end

-- Seal lava or water in direction d with a bulk block.
function seal(d)
    if not selectFiller() then return false end
    local ok = placeDir(d)
    turtle.select(1)
    if ok then stats.sealed = stats.sealed + 1 end
    return ok
end

local mineVein

-- Clear the tunnel block in direction d without moving into it: dig it
-- out (again while gravel keeps falling), follow it if it's ore, or fill
-- and dig out a fluid source.
local function clearCell(d)
    local n = neighbour(d)
    for _ = 1, 30 do
        room()                     -- first: a trip changes what's there
        local ok, data = look(d)
        if not ok then break end
        if isOre(data) then mineVein(d); break end
        if FLUID[data.name] and not (isSource(data) and seal(d)) then break end
        if protected(data.name) then return end
        if not digDir(d) then return end
    end
    opened[key(n)] = true
end

-- Look at the block in direction d outside the tunnel: follow ore, seal
-- fluids.
local function examine(d)
    local n = neighbour(d)
    if opened[key(n)] or not inReach(n) then return end
    local ok, data = look(d)
    if not ok then opened[key(n)] = true
    elseif isOre(data) then mineVein(d)
    elseif FLUID[data.name] then seal(d)
    end
end

-- Directions to look round a block, the cheapest turns first.
local function around()
    local f = T.dir
    return { "up", "down", f, (f + 1) % 4, (f + 3) % 4, (f + 2) % 4 }
end

-- The block in direction d is ore: dig into it, look all round, follow
-- any more ore, then come back.
function mineVein(d)
    if #trail == 0 then stats.veins = stats.veins + 1 end
    if not go(d) then return end
    stats.ore = stats.ore + 1
    trail[#trail + 1] = d
    for _, e in ipairs(around()) do
        local m = neighbour(e)
        if not opened[key(m)] and inReach(m) then
            local ok, data = look(e)
            if not ok then opened[key(m)] = true
            elseif isOre(data) then mineVein(e)
            elseif FLUID[data.name] then seal(e)
            end
        end
    end
    go(OPP[d])
    trail[#trail] = nil
end

--------------------------------------------------------------------------
-- Getting around inside the tunnel, through blocks already dug (a trip
-- home is made with a nearly full inventory): over to `via`, a finished
-- lane, if the turtle's own lane isn't dug back to the first slice yet;
-- back to the first slice; along its row to the start's column (columns
-- are finished in order), down that column (finished first) to the start's
-- row, then out.  Going back out reverses that.
--------------------------------------------------------------------------
local via                  -- the lane before, while the turtle's lane runs back toward the start
local function alongAxis(axis, target)
    while T.pos[axis] ~= target do
        local up = T.pos[axis] < target
        local d
        if axis == "x" then d = up and 1 or 3
        elseif axis == "y" then d = up and "up" or "down"
        else d = up and 0 or 2 end
        local ok, what = go(d)
        if not ok then return false, what end
    end
    return true
end

local function tunnelHome()
    if via and T.pos.z >= 1 then
        alongAxis("y", via.y)
        alongAxis("x", via.x)
    end
    if T.pos.z > 1 then alongAxis("z", 1) end
    alongAxis("x", 0)
    alongAxis("y", 0)
    alongAxis("z", 0)
    T.face(0)
    return T.pos.x == 0 and T.pos.y == 0 and T.pos.z == 0
end

local function tunnelTo(p)
    if T.pos.z < 1 then alongAxis("z", 1) end
    local lane = via or p
    alongAxis("y", lane.y)
    alongAxis("x", lane.x)
    alongAxis("z", p.z)
    alongAxis("x", p.x)
    alongAxis("y", p.y)
end

--------------------------------------------------------------------------
-- Home: the two chests
--------------------------------------------------------------------------
local function containerOn(side)
    local ok, data
    if side == "top" then ok, data = turtle.inspectUp() else ok, data = turtle.inspectDown() end
    return ok and T.isContainer(data.name)
end

-- Sort the inventory into the chests: bulk below, valuables above,
-- keeping tools and a stack of filler.  Waits while a chest is full or
-- missing (nothing is ever dropped on the ground).
local function unload()
    local warned = false
    while not (containerOn("top") and containerOn("bottom")) do
        if not warned then
            warned = true
            print("A chest is missing: needs one above (valuables) and one below (bulk). Waiting.")
        end
        sleep(10)
    end
    warned = false
    while true do
        local full, kept = {}, 0
        for s = 1, 16 do
            local it = turtle.getItemDetail(s, true)
            if it and not T.isTool(it.name) then
                local keep = 0
                if FILLER[it.name] and kept < FILLER_KEEP then
                    keep = math.min(it.count, FILLER_KEEP - kept)
                    kept = kept + keep
                end
                if it.count > keep then
                    local bulk = isBulk(it)
                    turtle.select(s)
                    if bulk then turtle.dropDown(it.count - keep) else turtle.dropUp(it.count - keep) end
                    if turtle.getItemCount(s) > keep then full[bulk and "bulk" or "valuables"] = true end
                end
            end
        end
        turtle.select(1)
        if not (full.bulk or full.valuables) then break end
        if not warned then
            warned = true
            print("The " .. (full.valuables and "valuables (top)" or "bulk (bottom)")
                .. " chest is full; waiting for room.")
        end
        sleep(30)
    end
    if warned then print("Chest has room again; carrying on.") end
    T.compactContainer(VALUABLE_SIDE)
end

-- Wait at home until the tank holds `enough`, refuelling from the
-- inventory and the valuables chest whenever something changes.
local function waitForFuel(enough)
    local level = turtle.getFuelLevel()
    if level == "unlimited" or level >= enough then return end
    print(string.format("Need %d fuel, have %d: put fuel (coal, charcoal, lava...) in the top chest or the turtle.",
        enough, level))
    while turtle.getFuelLevel() < enough do
        local timer = os.startTimer(10)
        repeat
            local ev, id = os.pullEvent()
        until (ev == "timer" and id == timer) or ev == "turtle_inventory" or ev == "key"
        T.refuelTo(math.max(enough, fuelGoal))
        if turtle.getFuelLevel() < enough then T.refuelFrom(VALUABLE_SIDE, math.max(enough, fuelGoal)) end
    end
    print("Fuel: " .. turtle.getFuelLevel())
end

local function refuel()
    if turtle.getFuelLevel() == "unlimited" then return end
    T.refuelFrom(VALUABLE_SIDE, fuelGoal)
end

-- Go home, unload and refuel, and come back to this exact spot and
-- facing (up the vein too, if in one).
function trip(why)
    if inTrip then return end
    inTrip = true
    local back = { x = T.pos.x, y = T.pos.y, z = T.pos.z }
    local facing = T.dir
    local path = {}
    for i, d in ipairs(trail) do path[i] = d end
    print(string.format("%s at %s: going home.", why, T.posString()))
    for i = #path, 1, -1 do go(OPP[path[i]]) end
    local spot = { x = T.pos.x, y = T.pos.y, z = T.pos.z }
    if not tunnelHome() then
        inTrip = false
        error("Couldn't get home from " .. T.posString(), 0)
    end
    unload()
    refuel()
    local away = math.abs(spot.x) + math.abs(spot.y) + math.abs(spot.z) + #path
    waitForFuel(2 * away + T.cfg.fuelMargin + FUEL_WORK)
    tunnelTo(spot)
    for _, d in ipairs(path) do go(d) end
    T.face(facing)
    if T.pos.x ~= back.x or T.pos.y ~= back.y or T.pos.z ~= back.z then
        print("Couldn't get back to (" .. key(back) .. "); carrying on from " .. T.posString())
    end
    inTrip = false
end

--------------------------------------------------------------------------
-- Lanes
--------------------------------------------------------------------------
-- Rows a middle column runs lanes in: every third, plus the last, so each
-- row is a lane or next to one and the top and bottom rows are lanes.
local function coverRows(n)
    local rows = {}
    for r = 0, n - 2, 3 do rows[#rows + 1] = r end
    if rows[#rows] ~= n - 1 then rows[#rows + 1] = n - 1 end
    return rows
end

local function planLanes()
    local xs, xn = T.sgn(WIDTH)
    local ys, yn = T.sgn(HEIGHT)
    local lanes = {}
    for c = 0, xn - 1 do
        local rows
        if c == 0 or c == xn - 1 then
            rows = {}
            for r = 0, yn - 1 do rows[#rows + 1] = r end
        else
            rows = coverRows(yn)
        end
        if c % 2 == 1 then                          -- serpentine through the rows
            local rev = {}
            for i = #rows, 1, -1 do rev[#rev + 1] = rows[i] end
            rows = rev
        end
        for _, r in ipairs(rows) do lanes[#lanes + 1] = { x = c * xs, y = r * ys } end
    end
    return lanes
end

-- At a lane block: clear the tunnel blocks above and below, and look at
-- every block outside the tunnel that this one touches.
local function scanHere()
    for _, d in ipairs({ "up", "down" }) do
        local n = neighbour(d)
        if not opened[key(n)] then
            if inBox(n) then clearCell(d) else examine(d) end
        end
    end
    for _, d in ipairs({ 1, 3, 0 }) do
        local n = neighbour(d)
        if not inBox(n) then examine(d) end
    end
end

local function mineTunnel()
    local lanes = planLanes()
    for i, lane in ipairs(lanes) do
        local ahead = i % 2 == 1
        local z1, z2, dz = 1, LENGTH, 1
        if not ahead then z1, z2, dz = LENGTH, 1, -1 end
        print(string.format("Lane %d/%d (x=%d, y=%d), fuel %s", i, #lanes, lane.x, lane.y,
            tostring(turtle.getFuelLevel())))
        local ok, what
        if i == 1 then ok, what = alongAxis("z", 1)
        else
            via = lanes[i - 1]             -- finished: the way home meanwhile
            ok, what = alongAxis("y", lane.y)
            if ok then ok, what = alongAxis("x", lane.x) end
        end
        if ahead then via = nil end        -- this lane is dug back to the start
        for z = z1, z2, dz do
            if not ok then break end
            scanHere()
            if z ~= z2 then ok, what = go(ahead and 0 or 2) end
        end
        if not ok then
            stuck = string.format("Can't get through at %s (%s).", T.posString(), tostring(what))
            return
        end
    end
end

-- The pickaxe to mine with: one equipped, else one in the inventory.
local function findPickaxe()
    for _, side in ipairs({ "left", "right" }) do
        local name = T.equipped(side)
        if name and name:find("_pickaxe$") then return name end
    end
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and it.name:find("_pickaxe$") then return it.name end
    end
end

--------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------
if doReset and forceHere then T.setHomeHere(); return end
local pickaxe = findPickaxe()
if not pickaxe then print("Needs a pickaxe, equipped or in the inventory."); return end

if doReset then
    if not loadJob() then print("No saved job; nothing to go back along."); return end
    setBox()
    local saved = T.loadPos()
    if not saved then print("No saved position; the turtle hasn't moved since its last job."); return end
    T.pos.x, T.pos.y, T.pos.z, T.dir = saved.x, saved.y, saved.z, saved.dir
    print(string.format("Last position %s facing %d. Heading home.", T.posString(), T.dir))
    inTrip = true                       -- no trips: just get home
    T.withTool(pickaxe, function()
        -- out of a vein first: straight back to the nearest tunnel block
        if not inBox(T.pos) and T.pos.z >= 1 then
            alongAxis("y", math.max(Y0, math.min(Y1, T.pos.y)))
            alongAxis("x", math.max(X0, math.min(X1, T.pos.x)))
            alongAxis("z", math.max(1, math.min(LENGTH, T.pos.z)))
        end
        if tunnelHome() then print("Home.") else print("Couldn't reach home; stopped at " .. T.posString()) end
    end)
    return
end

if not T.requireHome(forceHere, "mine") then return end
if not (containerOn("top") and containerOn("bottom")) then
    print("Needs a chest above the turtle (valuables) and one below it (bulk).")
    return
end
setBox()
saveJob()

local lanes = #planLanes()
fuelGoal = lanes * LENGTH + 2 * (LENGTH + math.abs(WIDTH) + math.abs(HEIGHT)) + 300
unload()
refuel()
waitForFuel(T.cfg.fuelMargin + FUEL_WORK)
if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < fuelGoal then
    print(string.format("Fuel %d of the ~%d the tunnel takes; will come home to refuel as needed.",
        turtle.getFuelLevel(), fuelGoal))
end
T.fuelTrip = function() trip("Low on fuel") end

print(string.format("Mining a %dx%d tunnel %d long: %d lanes.", math.abs(WIDTH), math.abs(HEIGHT), LENGTH, lanes))
T.withTool(pickaxe, function()
    mineTunnel()
    T.fuelTrip = nil
    inTrip = true
    tunnelHome()
    unload()
    inTrip = false
end)
print(string.format("Done: %d veins (%d ore blocks), %d fluid blocks sealed.",
    stats.veins, stats.ore, stats.sealed))
if stuck then print(stuck) end
