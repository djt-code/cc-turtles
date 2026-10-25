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
--    water/other -> recorded and left alone.  Layout saved to farm.map.
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
    end
    T.up()
    if kind == "crop" then plantDown() end
    return kind
end

--------------------------------------------------------------------------
-- Home chest: dump produce, restock seeds
--------------------------------------------------------------------------
local function keepPolicy(item, alreadyKept)
    if item.name == SEED then return math.max(0, seedTarget() - alreadyKept) end
    if T.keep[item.name] then return item.count end
    return 0
end

-- Pull seeds out of the chest below until we hold seedTarget().
-- suckDown() takes from the chest's first occupied slot regardless of what
-- it is, so anything that isn't seeds (or fuel) is set aside and dropped
-- back once we're done.
local function restockSeeds()
    local target = seedTarget()
    if T.countItem(SEED) >= target then return end

    -- If the chest can be wrapped, check it actually has seeds first.
    local chest = peripheral and peripheral.wrap("bottom")
    if chest and chest.list then
        local any = false
        for _, it in pairs(chest.list()) do
            if it.name == SEED then any = true; break end
        end
        if not any then
            print("Chest has no wheat seeds to restock from.")
            return
        end
    end

    local junk = {}
    for _ = 1, 54 do                              -- a double chest's worth
        if T.countItem(SEED) >= target then break end
        local before = {}
        for s = 1, 16 do before[s] = turtle.getItemCount(s) end
        local freeSlots = 0
        for s = 1, 16 do if before[s] == 0 then freeSlots = freeSlots + 1 end end
        if freeSlots <= 1 then break end          -- keep one slot free for tool swaps
        if not turtle.suckDown(64) then break end -- chest empty
        for s = 1, 16 do
            if turtle.getItemCount(s) > before[s] then
                local it = turtle.getItemDetail(s)
                if it and it.name ~= SEED and not T.keep[it.name] then junk[#junk + 1] = s end
                break
            end
        end
    end
    for _, s in ipairs(junk) do
        turtle.select(s)
        turtle.dropDown()
    end
    turtle.select(1)
    print(string.format("Seeds on board: %d (target %d)", T.countItem(SEED), target))
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
        restockSeeds()
    else
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
        if T.inventoryFull() or T.countItem(SEED) == 0 then dumpAtHome() end
    end
    saveMap()
    print(string.format("Layout saved: %d crop, %d water, %d other",
        counts.crop, counts.water, counts.other))
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
end)

restoreTools()
if not ok then error(err, 0) end
