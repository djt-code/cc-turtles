-- farm.lua -- wheat farming turtle for CC:Tweaked
--
-- Needs: diamond hoe (equipped, or in the inventory to be hot-swapped onto
-- the right side).  Recommended: Advanced Peripherals Chunky Turtle
-- upgrade on the LEFT side so it keeps running unattended.
--
-- Usage:
--   farm <width> <length> [repeatMinutes]         first run: explore + farm
--   farm [repeatMinutes]                           later runs: saved layout
--   farm learn <width> <length> [repeatMinutes]    re-explore the farm
--
-- Placement: put the turtle at one corner of the farm's bounding box,
-- hovering TWO blocks above the farmland (one block above the crop tops),
-- facing along the LENGTH axis with the farm to its RIGHT.  Put the output
-- chest/barrel directly below the start position (up to 3 blocks down).
-- Keep some wheat seeds in the inventory for the first planting.
--
-- How it works:
--  * Learning pass: flies over every tile in the box.  Wheat below ->
--    farm tile.  Air below -> drops down a block to look at the ground:
--    farmland -> plant; dirt/grass -> till with the hoe, then plant;
--    water/other -> recorded and left alone.  Layout saved to farm.map.
--  * Farming pass: visits only farm tiles, harvests wheat at age 7 and
--    replants it, plants bare farmland, returns home, drops wheat and
--    surplus seeds into the chest, and sleeps.
--  * Navigation is at a fixed cruise height (turtlelib.stepFlat) with a
--    learned obstacle map and BFS re-routing.

local T = require("turtlelib")

local MAP_FILE = "farm.map"

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
local args = { ... }
local forceLearn = false
if args[1] == "learn" then forceLearn = true; table.remove(args, 1) end

local WIDTH, LENGTH, REPEAT
if #args >= 2 then
    WIDTH, LENGTH, REPEAT = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
else
    REPEAT = tonumber(args[1])
end
if REPEAT == nil then REPEAT = 20 end   -- minutes; 0 = single pass

local CRUISE_MOVES_PER_TILE = 1.2
local SEED_RESERVE = 128      -- seeds to keep on board after dumping

local CROP = "minecraft:wheat"
local SEED = "minecraft:wheat_seeds"
local TILLABLE = {
    ["minecraft:dirt"] = true, ["minecraft:grass_block"] = true,
    ["minecraft:coarse_dirt"] = true, ["minecraft:dirt_path"] = true,
    ["minecraft:rooted_dirt"] = true,
}

T.step = T.stepFlat
T.diggable = {}            -- never dig while moving; only via workCrop/learnTile
T.equipTool("minecraft:diamond_hoe")

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
    local w, l = f.readLine():match("(%d+) (%d+)")
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

-- Harvest if ripe and replant.
local function workCrop()
    local ok, data = turtle.inspectDown()
    if ok and data.name == CROP then
        if data.state and data.state.age == 7 then
            turtle.digDown()
            plantDown()
            return "harvested"
        end
        return "growing"
    elseif not ok then
        if plantDown() then return "planted" end
        -- couldn't plant: farmland may have reverted to dirt.  Check.
        if T.down() then
            local ok2, d2 = turtle.inspectDown()
            if ok2 and TILLABLE[d2.name] then turtle.digDown() end   -- hoe tills
            T.up()
            if plantDown() then return "planted" end
        end
        return "empty"
    end
    return "blocked"
end

-- Classify (and fix up) the tile below during the learning pass.
local function learnTile()
    local ok, data = turtle.inspectDown()
    if ok then
        if data.name == CROP then return "crop" end
        return "other"            -- something solid at crop level
    end
    if not T.down() then return "other" end
    local kind = "other"
    local ok2, d2 = turtle.inspectDown()
    if ok2 then
        if d2.name == "minecraft:farmland" then
            kind = "crop"
        elseif TILLABLE[d2.name] then
            if turtle.digDown() then kind = "crop" end   -- tilled it
        elseif d2.name == "minecraft:water" then
            kind = "water"
        end
    end
    T.up()
    if kind == "crop" then plantDown() end
    return kind
end

--------------------------------------------------------------------------
-- Home / output chest
--------------------------------------------------------------------------
local function keepPolicy(item, alreadyKept)
    if item.name == SEED then return math.max(0, SEED_RESERVE - alreadyKept) end
    if T.keep[item.name] then return item.count end
    return 0
end

local function dumpAtHome()
    goToCruise(0, 0)
    T.face(0)
    for _ = 1, 3 do
        if T.containerBelow() then break end
        if turtle.detectDown() or not T.down() then break end
    end
    if not T.dumpDown(keepPolicy) then
        print("No chest found below home; keeping items.")
    end
    T.toStartHeight()
end

--------------------------------------------------------------------------
-- Passes
--------------------------------------------------------------------------
local function learnPass()
    print(string.format("Learning layout: %dx%d", WIDTH, LENGTH))
    tiles = {}
    local counts = { crop = 0, water = 0, other = 0 }
    local plan = T.serpentine(WIDTH, LENGTH)
    for i, t in ipairs(plan) do
        local kind = "other"
        if goToCruise(t.x, t.z) then kind = learnTile() end
        tiles[T.ckey(t.x, t.z)] = kind
        counts[kind] = counts[kind] + 1
        if i % 50 == 0 then
            print(string.format("%d/%d scanned, %d crop tiles", i, #plan, counts.crop))
        end
        if T.inventoryFull() then dumpAtHome() end
    end
    saveMap()
    print(string.format("Layout saved: %d crop, %d water, %d other",
        counts.crop, counts.water, counts.other))
end

local function farmPass()
    local plan = cropTiles()
    local stats = { harvested = 0, planted = 0, growing = 0, empty = 0, blocked = 0 }
    local skipped = 0
    for i, t in ipairs(plan) do
        if goToCruise(t.x, t.z) then
            local r = workCrop()
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
    if stats.empty > 0 and T.countItem(SEED) == 0 then
        print("Out of seeds: " .. stats.empty .. " tiles left bare.")
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

T.cfg.width, T.cfg.length = WIDTH, LENGTH
T.requireFuel(math.floor(WIDTH * LENGTH * CRUISE_MOVES_PER_TILE) + WIDTH + LENGTH + 150)

T.clearBlocked()
if not haveMap then
    learnPass()
    dumpAtHome()
end

while true do
    T.clearBlocked()
    farmPass()
    dumpAtHome()
    print("Pass complete. Fuel: " .. tostring(turtle.getFuelLevel()) ..
        ", seeds: " .. T.countItem(SEED))
    if REPEAT <= 0 then break end
    print("Sleeping " .. REPEAT .. " min (Ctrl+T to stop)")
    sleep(REPEAT * 60)
end
