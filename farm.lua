-- farm.lua -- wheat farming turtle for CC:Tweaked
--
-- Needs a diamond hoe, equipped or in the inventory.  Any other tool
-- (e.g. a pickaxe on the other side) is parked in the inventory while the
-- program runs so the hoe is the only tool and digDown() always tills.
-- Optional: Advanced Peripherals Chunky Turtle upgrade for unattended use.
--
-- Usage:
--   farm <width> <length> [repeatMinutes]         first run: explore + farm
--   farm [repeatMinutes]                           later runs: saved layout
--   farm learn <width> <length> [repeatMinutes]    re-explore the farm
--   farm reset                                     return to home after a stop
--   farm ... --here                                accept current spot as home
--
-- width  = tiles to the RIGHT of the turtle (negative = to the LEFT)
-- length = tiles AHEAD of the turtle (negative = BEHIND)
-- Both are counted OUT from the turtle: its own row and column are not part
-- of the farm, so the box is x = 1..width, z = 1..length.
-- repeatMinutes defaults to 20; 0 = single pass.
--
-- Placement: put the turtle diagonally outside one corner of the farm,
-- hovering TWO blocks above the farmland (one block above the crop tops).
-- Put the output chest/barrel directly below the start position (up to 3
-- blocks down) and keep wheat seeds in it; the turtle restocks from it.
--
-- How it works:
--  * Learning pass: flies over every tile in the box.  Wheat below ->
--    farm tile.  Air below -> drops down a block to look at the ground:
--    farmland -> plant; dirt/grass -> till with the hoe, then plant;
--    water/other -> recorded and left alone; missing ground -> "hole".
--    Layout saved to farm.map.
--  * Repair: holes are fixed according to the strip they lie in.  In a
--    land strip: dirt, till, plant.  In a water lane: dirt floor beneath
--    if missing, dirt walls on the open cross-lane sides, then water from
--    a bucket refilled at a lane tile with 2+ water neighbours.  Keep dirt
--    and a bucket (or water buckets) in the chest.
--  * Farming pass: visits only farm tiles, harvests wheat at age 7 and
--    replants it, plants bare farmland, returns home, drops wheat and
--    surplus seeds into the chest, tops seeds back up, and sleeps.
--  * Navigation is at a fixed cruise height (turtlelib.stepFlat) with a
--    learned obstacle map and BFS re-routing.  Position is saved to disk
--    after every move so `farm reset` can bring it home after a Ctrl+T.

local T = require("turtlelib")

local MAP_FILE = T.dataPath("farm.map")

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
local args = { ... }
local forceLearn, forceHere = false, false
for i = #args, 1, -1 do
    if args[i] == "--here" then forceHere = true; table.remove(args, i) end
end
if args[1] == "learn" then forceLearn = true; table.remove(args, 1) end

if args[1] == "reset" then
    T.goHome()
    return
end

local WIDTH, LENGTH, REPEAT
if #args >= 2 then
    WIDTH, LENGTH, REPEAT = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
else
    REPEAT = tonumber(args[1])
end
if REPEAT == nil then REPEAT = 20 end   -- minutes; 0 = single pass

local CRUISE_MOVES_PER_TILE = 1.2
local MAX_SEEDS = 256           -- never carry more than this many seeds

local CROP = "minecraft:wheat"
local SEED = "minecraft:wheat_seeds"
local DIRT = "minecraft:dirt"           -- used to fill holes in land strips
local TILLABLE = {
    ["minecraft:dirt"] = true, ["minecraft:grass_block"] = true,
    ["minecraft:coarse_dirt"] = true, ["minecraft:dirt_path"] = true,
    ["minecraft:rooted_dirt"] = true,
}

T.step = T.stepFlat
T.mode = "flat"
T.diggable = {}            -- never dig while moving; only via workCrop/learnTile

--------------------------------------------------------------------------
-- Farm layout map: tiles[key] = "crop" | "water" | "other"
--------------------------------------------------------------------------
local tiles = {}

local function saveMap()
    local f = fs.open(MAP_FILE, "w")
    f.writeLine(WIDTH .. " " .. LENGTH)
    for k, t in pairs(tiles) do f.writeLine(k .. " " .. t) end
    f.close()
end

local function loadMap()
    if not fs.exists(MAP_FILE) then return false end
    local f = fs.open(MAP_FILE, "r")
    local w, l = (f.readLine() or ""):match("(-?%d+) (-?%d+)")
    if not w then f.close(); return false end
    WIDTH, LENGTH = tonumber(w), tonumber(l)
    tiles = {}
    for line in f.readLine do
        local k, t = line:match("(%S+) (%S+)")
        if k then tiles[k] = t end
    end
    f.close()
    return true
end

local function cropTiles()
    local list = {}
    for _, t in ipairs(T.serpentine(WIDTH, LENGTH)) do
        if tiles[T.ckey(t.x, t.z)] == "crop" then list[#list + 1] = t end
    end
    return list
end

-- How many seeds we want on board: enough to plant every crop tile (or the
-- whole box before the layout is known), capped.
local function seedTarget()
    local n = 0
    for _, kind in pairs(tiles) do if kind == "crop" then n = n + 1 end end
    if n == 0 then n = math.abs(WIDTH * LENGTH) end
    return math.min(MAX_SEEDS, n + 16)
end

--------------------------------------------------------------------------
-- Tile actions (all called at cruise height)
--------------------------------------------------------------------------
local function plantDown()
    if not T.selectItem(SEED) then return false end
    return turtle.placeDown()
end

local function goToCruise(tx, tz)
    T.toStartHeight()
    return T.goTo(tx, tz)
end

-- What is directly below: a block name, or "air".
local function below()
    local ok, d = turtle.inspectDown()
    if not ok then return "air" end
    return d.name, d
end

local warnedLow = false
local function warnLow()
    if not warnedLow then
        warnedLow = true
        print("Note: ground is directly below cruise height; the turtle is one block")
        print("lower than ideal and will bob up to plant. Start it one higher next time.")
    end
end

-- The turtle cruises one block above the crop tops, i.e. two above the
-- farmland.  CC:Tweaked lets a hoe till THROUGH one block of air below the
-- turtle (TurtleTool.useTool), so bare dirt can be tilled from cruise height
-- with a plain digDown(); seeds also place through that gap onto farmland.
-- Returns: harvested | growing | planted | empty | noseeds | blocked
local function workCrop()
    local name, d = below()
    if name == CROP then
        if d.state and tonumber(d.state.age) == 7 then
            turtle.digDown()                 -- hoe on wheat: breaks it
            plantDown()
            return "harvested"
        end
        return "growing"
    elseif name == "air" then
        if plantDown() then return "planted" end
        if T.countItem(SEED) == 0 then return "noseeds" end
        -- Not farmland under the gap: till it (hoe reaches through the air)
        turtle.digDown()
        if plantDown() then return "planted" end
        return "empty"
    elseif TILLABLE[name] or name == "minecraft:farmland" then
        -- Ground is directly below us: we are one block low for this tile.
        warnLow()
        if TILLABLE[name] then turtle.digDown() end        -- till it
        if not T.up() then return "blocked" end
        local r = plantDown() and "planted" or (T.countItem(SEED) == 0 and "noseeds" or "empty")
        T.down()
        return r
    end
    return "blocked"
end

-- Classify (and fix up) the tile below during the learning pass.
-- crop | water | other
local function learnTile()
    local name = below()
    if name == CROP then return "crop" end
    if name == "minecraft:water" then return "water" end
    if TILLABLE[name] or name == "minecraft:farmland" then
        warnLow()
        if TILLABLE[name] then turtle.digDown() end
        if T.up() then plantDown(); T.down() end
        return "crop"
    end
    if name ~= "air" then return "other" end
    -- Air at crop level: step down to see the ground.
    if not T.down() then return "other" end
    local g = below()
    local kind = "other"
    if g == "minecraft:farmland" then kind = "crop"
    elseif TILLABLE[g] then if turtle.digDown() then kind = "crop" end
    elseif g == "minecraft:water" then kind = "water"
    elseif g == "air" then kind = "hole"              -- ground block missing
    end
    T.up()
    if kind == "crop" then plantDown() end
    return kind
end

--------------------------------------------------------------------------
-- Home chest: dump produce, restock seeds
--------------------------------------------------------------------------
-- Holes recorded in the map that still need repairing (see Strips below).
local pendingFills = {}
local dirtNeeded                     -- defined with the strip logic
local BUCKET, WATER_BUCKET = "minecraft:bucket", "minecraft:water_bucket"

local function keepPolicy(item, alreadyKept)
    if item.name == SEED then return math.max(0, seedTarget() - alreadyKept) end
    if item.name == DIRT then return math.max(0, dirtNeeded() - alreadyKept) end
    if item.name == BUCKET or item.name == WATER_BUCKET then return item.count end
    if T.keep[item.name] then return item.count end
    return 0
end

-- Pull `name` out of the chest below until we hold `target` of it.
-- suckDown() takes from the chest's first occupied slot regardless of what
-- it is, so anything else that comes out is set aside and dropped back
-- once we're done (fuel and the other restock item are kept).
local warnedEmpty = {}
local function restockItem(name, target, label)
    if target <= 0 or T.countItem(name) >= target then return end

    local chest = peripheral and peripheral.wrap("bottom")
    if chest and chest.list then
        local any = false
        for _, it in pairs(chest.list()) do
            if it.name == name then any = true; break end
        end
        if not any then
            if not warnedEmpty[name] then
                warnedEmpty[name] = true
                print("Chest has no " .. label:lower() .. " to restock from.")
            end
            return
        end
        warnedEmpty[name] = nil
    end

    local wanted = { [SEED] = true, [DIRT] = true, [BUCKET] = true, [WATER_BUCKET] = true }
    local junk = {}
    for _ = 1, 54 do                              -- a double chest's worth
        if T.countItem(name) >= target then break end
        local before = {}
        for s = 1, 16 do before[s] = turtle.getItemCount(s) end
        local freeSlots = 0
        for s = 1, 16 do if before[s] == 0 then freeSlots = freeSlots + 1 end end
        if freeSlots <= 1 then break end          -- keep one slot free for tool swaps
        if not turtle.suckDown(64) then break end -- chest empty
        for s = 1, 16 do
            if turtle.getItemCount(s) > before[s] then
                local it = turtle.getItemDetail(s)
                if it and not wanted[it.name] and not T.keep[it.name] then junk[#junk + 1] = s end
                break
            end
        end
    end
    for _, s in ipairs(junk) do
        turtle.select(s)
        turtle.dropDown()
    end
    turtle.select(1)
    print(string.format("%s on board: %d (target %d)", label, T.countItem(name), target))
end

local function dumpAtHome()
    goToCruise(0, 0)
    T.face(0)
    for _ = 1, 3 do
        if T.containerBelow() then break end
        if turtle.detectDown() or not T.down() then break end
    end
    if T.containerBelow() then
        T.dumpDown(keepPolicy)
        restockItem(SEED, seedTarget(), "Seeds")
        restockItem(DIRT, dirtNeeded(), "Dirt")
    else
        print("No chest found below home; keeping items.")
    end
    T.toStartHeight()
end

--------------------------------------------------------------------------
-- Strips.  Farms are usually strips of farmland separated by water lanes.
-- A hole (missing ground block) is repaired according to the line it lies
-- in: if the other tiles along its column or row are land (and none are
-- water) it gets dirt + tilling; if they are water (and none are land) it
-- gets a dirt floor beneath, dirt walls on the two cross-lane sides where
-- they are open, and a water block.  Water comes from a bucket, refilled
-- at a lane tile with two or more water neighbours so the source regrows.
--------------------------------------------------------------------------
local function keyXZ(k)
    local x, z = k:match("(-?%d+),(-?%d+)")
    return tonumber(x), tonumber(z)
end

-- Tally kinds along a line (excluding holes).
local function lineTally(filter)
    local t = { crop = 0, water = 0, other = 0 }
    for k, kind in pairs(tiles) do
        if kind ~= "hole" then
            local x, z = keyXZ(k)
            if filter(x, z) then t[kind] = t[kind] + 1 end
        end
    end
    return t
end

local function classifyLine(t)
    if t.water == 0 and t.crop > 0 and t.crop >= t.other then return "land" end
    if t.crop == 0 and t.water > 0 and t.water >= t.other then return "water" end
    return nil
end

-- Decide what each hole should become.  Columns (same x) are checked
-- first since lanes usually run along the length axis; rows second.
local function planFills()
    pendingFills = {}
    for k, kind in pairs(tiles) do
        if kind == "hole" then
            local x, z = keyXZ(k)
            local col = classifyLine(lineTally(function(px, pz) return px == x and pz ~= z end))
            local row = classifyLine(lineTally(function(px, pz) return pz == z and px ~= x end))
            local want, axis
            if col then want, axis = col, "z"            -- line runs along z
            elseif row then want, axis = row, "x" end
            if want then
                pendingFills[#pendingFills + 1] = { x = x, z = z, want = want, axis = axis }
            end
        end
    end
    table.sort(pendingFills, function(a, b)
        if a.x ~= b.x then return math.abs(a.x) < math.abs(b.x) end
        return math.abs(a.z) < math.abs(b.z)
    end)
    return #pendingFills
end

function dirtNeeded()
    local n = 0
    for _, f in ipairs(pendingFills) do n = n + (f.want == "water" and 3 or 1) end
    return n
end

-- Make sure we hold a water bucket.  Tries the chest first (water buckets
-- or an empty bucket), then refills an empty bucket from a regenerating
-- lane tile.
local function ensureWater()
    if T.countItem(WATER_BUCKET) > 0 then return true end
    if T.countItem(BUCKET) == 0 then
        dumpAtHome()
        restockItem(WATER_BUCKET, 1, "Water bucket")
        if T.countItem(WATER_BUCKET) > 0 then return true end
        restockItem(BUCKET, 1, "Bucket")
        if T.countItem(BUCKET) == 0 then return false end
    end
    -- find a water tile with >= 2 water neighbours (infinite source)
    local best
    for k, kind in pairs(tiles) do
        if kind == "water" then
            local x, z = keyXZ(k)
            local n = 0
            for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                if tiles[T.ckey(x + d[1], z + d[2])] == "water" then n = n + 1 end
            end
            if n >= 2 and (not best or math.abs(x) + math.abs(z) < math.abs(best.x) + math.abs(best.z)) then
                best = { x = x, z = z }
            end
        end
    end
    if not best then
        print("No regenerating water tile to refill the bucket from.")
        return false
    end
    if goToCruise(best.x, best.z) and T.down() then
        if T.selectItem(BUCKET) then turtle.placeDown() end     -- scoop
        T.up()
    end
    return T.countItem(WATER_BUCKET) > 0
end

local function placeDirtDown()
    return T.selectItem(DIRT) and turtle.placeDown()
end

-- Repair one land hole: dirt into the ground position, till, plant.
local function fillLand(t)
    if not (goToCruise(t.x, t.z) and T.down()) then return false end
    local ok = false
    local g = below()
    if g == "air" then
        if T.countItem(DIRT) > 0 and placeDirtDown() then g = DIRT end
    end
    if TILLABLE[g] then turtle.digDown(); g = "minecraft:farmland" end
    if g == "minecraft:farmland" then ok = true end
    T.up()
    if ok then plantDown() end
    return ok
end

-- Repair one water-lane hole: floor beneath, walls across the lane, water.
local function fillWater(t)
    if not ensureWater() then return false end
    if not (goToCruise(t.x, t.z) and T.down()) then return false end
    if below() ~= "air" then                 -- something already at ground level
        T.up(); return false
    end
    if not T.down() then T.up(); return false end       -- now inside the hole
    local ok = true
    if below() == "air" then                            -- floor missing
        if not placeDirtDown() then ok = false end
    end
    if ok then
        -- walls on the two sides perpendicular to the lane
        local dirs = (t.axis == "z") and { 1, 3 } or { 0, 2 }
        for _, d in ipairs(dirs) do
            T.face(d)
            if not turtle.detect() and T.countItem(DIRT) > 0 then
                T.selectItem(DIRT); turtle.place()
            end
        end
    end
    T.up()                                              -- back to crop level
    if ok then
        T.selectItem(WATER_BUCKET)
        ok = turtle.placeDown()
    end
    T.up()
    return ok
end

local function fillHoles()
    if #pendingFills == 0 then return end
    if T.countItem(DIRT) < dirtNeeded() then dumpAtHome() end   -- restocks dirt
    if T.countItem(DIRT) == 0 then
        print(#pendingFills .. " holes to fill but no dirt in chest or inventory.")
        return
    end
    print(string.format("Repairing %d holes (%d dirt on board)", #pendingFills, T.countItem(DIRT)))
    local remaining, land, water = {}, 0, 0
    for _, t in ipairs(pendingFills) do
        local done
        if t.want == "land" then
            done = fillLand(t)
            if done then land = land + 1 end
        else
            done = fillWater(t)
            if done then water = water + 1 end
        end
        if done then tiles[T.ckey(t.x, t.z)] = (t.want == "land") and "crop" or "water"
        else remaining[#remaining + 1] = t end
    end
    pendingFills = remaining
    saveMap()
    print(string.format("Filled %d land and %d water holes; %d still open.", land, water, #remaining))
end

--------------------------------------------------------------------------
-- Passes
--------------------------------------------------------------------------
local function learnPass()
    print(string.format("Learning layout: %dx%d", WIDTH, LENGTH))
    tiles = {}
    local counts = { crop = 0, water = 0, other = 0, hole = 0 }
    local plan = T.serpentine(WIDTH, LENGTH)
    for i, t in ipairs(plan) do
        local kind = "other"
        if goToCruise(t.x, t.z) then kind = learnTile() end
        tiles[T.ckey(t.x, t.z)] = kind
        counts[kind] = counts[kind] + 1
        if i % 50 == 0 then
            print(string.format("%d/%d scanned, %d crop tiles", i, #plan, counts.crop))
        end
        if T.inventoryFull() or T.countItem(SEED) == 0 then dumpAtHome() end
    end
    saveMap()
    print(string.format("Layout saved: %d crop, %d water, %d other, %d holes",
        counts.crop, counts.water, counts.other, counts.hole))
    local n = planFills()
    if n > 0 then
        print(n .. " holes lie in land or water strips and will be repaired.")
        fillHoles()
    end
end

local function farmPass()
    local plan = cropTiles()
    local stats = { harvested = 0, planted = 0, growing = 0, empty = 0,
                    blocked = 0, noseeds = 0 }
    local skipped, triedRestock = 0, false
    for i, t in ipairs(plan) do
        if goToCruise(t.x, t.z) then
            local r = workCrop()
            if r == "noseeds" and not triedRestock then
                dumpAtHome()                      -- restocks seeds
                triedRestock = true
                if goToCruise(t.x, t.z) then r = workCrop() end
            end
            stats[r] = stats[r] + 1
        else
            skipped = skipped + 1
        end
        if i % 50 == 0 then
            print(string.format("%d/%d tiles, fuel %s", i, #plan,
                tostring(turtle.getFuelLevel())))
        end
        if T.inventoryFull() then dumpAtHome() end
    end
    print(string.format("Harvested %d, planted %d, growing %d, empty %d, unreachable %d",
        stats.harvested, stats.planted, stats.growing, stats.empty, skipped))
    if stats.noseeds > 0 then
        print("Out of seeds: " .. stats.noseeds .. " tiles left bare. Put seeds in the chest.")
    end
end

--------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------
local haveMap = (not forceLearn) and loadMap()
if not haveMap and not (WIDTH and LENGTH) then
    print("No saved layout. Usage: farm <width> <length> [repeatMinutes]")
    return
end
if forceLearn and not (WIDTH and LENGTH) then
    print("Usage: farm learn <width> <length> [repeatMinutes]")
    return
end

local stale = T.startAtHome(forceHere)
if stale then
    print(string.format("Turtle may not be at home: last saved position (%d,%d,%d).",
        stale.x, stale.y, stale.z))
    print("Run `farm reset` to send it home, or add --here to use this spot as home.")
    return
end

T.cfg.width, T.cfg.length = WIDTH, LENGTH
T.requireFuel(math.floor(math.abs(WIDTH * LENGTH) * CRUISE_MOVES_PER_TILE)
              + math.abs(WIDTH) + math.abs(LENGTH) + 150)

local restoreTools = T.usePrimaryTool("minecraft:diamond_hoe")

local ok, err = pcall(function()
    T.clearBlocked()
    dumpAtHome()                      -- stock up on seeds before starting
    if not haveMap then
        learnPass()
        dumpAtHome()
    end
    planFills()
    while true do
        T.clearBlocked()
        if #pendingFills > 0 then fillHoles() end
        farmPass()
        dumpAtHome()
        print("Pass complete. Fuel: " .. tostring(turtle.getFuelLevel()) ..
            ", seeds: " .. T.countItem(SEED))
        if REPEAT <= 0 then break end
        print("Sleeping " .. REPEAT .. " min (Ctrl+T to stop)")
        sleep(REPEAT * 60)
    end
end)

restoreTools()
if not ok then error(err, 0) end
