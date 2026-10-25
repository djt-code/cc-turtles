-- farm.lua -- wheat farming turtle for CC:Tweaked
--
-- Needs a diamond hoe (and a diamond pickaxe for `clone`), equipped or in
-- the inventory.  The program makes the tool it needs the only tool
-- equipped and parks the other in the inventory, so digDown() with the hoe
-- always tills.  Optional: Advanced Peripherals Chunky Turtle upgrade.
--
-- Usage:
--   farm <width> <length> [repeatMinutes]         first run: explore + farm
--   farm [repeatMinutes]                           later runs: saved layout
--   farm learn <width> <length> [repeatMinutes]    re-explore the farm
--   farm clone [repeatMinutes]                     build the saved layout HERE,
--                                                  then farm it
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
-- blocks down).  Keep in the chest: wheat seeds, dirt, and a bucket or two
-- (water buckets for clone); the turtle restocks from it.
--
-- How it works:
--  * Learning pass: flies over every tile in the box.  Wheat below ->
--    farm tile.  Air below -> drops down a block to look at the ground:
--    farmland -> plant; dirt/grass -> till with the hoe, then plant;
--    water -> lane; missing ground -> "hole"; other -> left alone.
--    Layout saved to farm.map.
--  * Repair: holes are fixed according to the strip they lie in.  In a
--    land strip: dirt, till, plant.  In a water lane: dirt floor beneath
--    if missing, dirt walls on every side that isn't lane, then water.
--  * Clone: builds farm.map at the current position.  Phase 1 (pickaxe)
--    clears the crop level, digs lane trenches and removes stone where
--    land is wanted.  Phase 2 (hoe) fills/tills/plants land, then floors,
--    walls and waters the lanes.  Each lane is bootstrapped with two water
--    buckets at tiles 1 and 3 (tile 2 becomes a source on its own) and the
--    rest is scooped from that regenerating tile.
--  * Farming pass: visits only farm tiles, harvests wheat at age 7 and
--    replants it, plants bare farmland (tilling through the air gap if it
--    reverted to dirt), returns home, drops produce, restocks, sleeps.
--  * Navigation is at a fixed cruise height (turtlelib.stepFlat) with a
--    learned obstacle map and BFS re-routing.  Position is saved to disk
--    after every move so `farm reset` can bring it home after a Ctrl+T.

local T = require("turtlelib")

local MAP_FILE = T.dataPath("farm.map")

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
local args = { ... }
local forceLearn, forceHere, doClone = false, false, false
for i = #args, 1, -1 do
    if args[i] == "--here" then forceHere = true; table.remove(args, i) end
end
if args[1] == "learn" then forceLearn = true; table.remove(args, 1)
elseif args[1] == "clone" then doClone = true; forceHere = true; table.remove(args, 1)
elseif args[1] == "reset" then T.goHome(); return end

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
local DIRT = "minecraft:dirt"
local WATER = "minecraft:water"
local FARMLAND = "minecraft:farmland"
local BUCKET, WATER_BUCKET = "minecraft:bucket", "minecraft:water_bucket"
local HOE, PICKAXE = "minecraft:diamond_hoe", "minecraft:diamond_pickaxe"
local TILLABLE = {
    ["minecraft:dirt"] = true, ["minecraft:grass_block"] = true,
    ["minecraft:coarse_dirt"] = true, ["minecraft:dirt_path"] = true,
    ["minecraft:rooted_dirt"] = true,
}

T.step = T.stepFlat
T.mode = "flat"
T.diggable = {}            -- never dig while moving

--------------------------------------------------------------------------
-- Farm layout map: tiles[key] = "crop" | "water" | "hole" | "other"
--------------------------------------------------------------------------
local tiles = {}
local wet = {}             -- tiles that actually hold water right now
local pendingFills = {}    -- holes (or clone targets) still to build

local function keyXZ(k)
    local x, z = k:match("(-?%d+),(-?%d+)")
    return tonumber(x), tonumber(z)
end

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

local function tilesOfKind(kind)
    local list = {}
    for _, t in ipairs(T.serpentine(WIDTH, LENGTH)) do
        if tiles[T.ckey(t.x, t.z)] == kind then list[#list + 1] = t end
    end
    return list
end

local function countKind(kind)
    local n = 0
    for _, k in pairs(tiles) do if k == kind then n = n + 1 end end
    return n
end

-- How many seeds we want on board: enough to plant every crop tile (or the
-- whole box before the layout is known), capped.
local function seedTarget()
    local n = countKind("crop")
    if n == 0 then n = math.abs(WIDTH * LENGTH) end
    return math.min(MAX_SEEDS, n + 16)
end

--------------------------------------------------------------------------
-- Tile primitives (all start and end at cruise height)
--------------------------------------------------------------------------
-- What is directly below: a block name, or "air".
local function below()
    local ok, d = turtle.inspectDown()
    if not ok then return "air" end
    return d.name, d
end

local function plantDown()
    if not T.selectItem(SEED) then return false end
    return turtle.placeDown()
end

local function placeDirtDown()
    return T.selectItem(DIRT) and turtle.placeDown()
end

local function goToCruise(tx, tz)
    T.toStartHeight()
    return T.goTo(tx, tz)
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
        turtle.digDown()                     -- till through the gap
        if plantDown() then return "planted" end
        return "empty"
    elseif TILLABLE[name] or name == FARMLAND then
        warnLow()
        if TILLABLE[name] then turtle.digDown() end
        if not T.up() then return "blocked" end
        local r = plantDown() and "planted" or (T.countItem(SEED) == 0 and "noseeds" or "empty")
        T.down()
        return r
    end
    return "blocked"
end

-- Classify (and fix up) the tile below during the learning pass.
-- crop | water | hole | other
local function learnTile()
    local name = below()
    if name == CROP then return "crop" end
    if name == WATER then return "water" end
    if TILLABLE[name] or name == FARMLAND then
        warnLow()
        if TILLABLE[name] then turtle.digDown() end
        if T.up() then plantDown(); T.down() end
        return "crop"
    end
    if name ~= "air" then return "other" end
    if not T.down() then return "other" end
    local g = below()
    local kind = "other"
    if g == FARMLAND then kind = "crop"
    elseif TILLABLE[g] then if turtle.digDown() then kind = "crop" end
    elseif g == WATER then kind = "water"
    elseif g == "air" then kind = "hole"
    end
    T.up()
    if kind == "crop" then plantDown() end
    return kind
end

--------------------------------------------------------------------------
-- Home chest: dump produce, restock seeds / dirt / buckets
--------------------------------------------------------------------------
local function dirtNeeded()
    local n = 0
    for _, f in ipairs(pendingFills) do n = n + (f.want == "water" and 4 or 1) end
    return math.min(n, 192)
end

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
-- once we're done (other restock items and fuel are kept).
local WANTED = { [SEED] = true, [DIRT] = true, [BUCKET] = true, [WATER_BUCKET] = true }
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
                if it and not WANTED[it.name] and not T.keep[it.name] then junk[#junk + 1] = s end
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

local wantWaterBuckets = 0     -- set by the lane builder before visiting home

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
        if wantWaterBuckets > 0 then
            restockItem(WATER_BUCKET, wantWaterBuckets, "Water buckets")
            if T.countItem(WATER_BUCKET) + T.countItem(BUCKET) < wantWaterBuckets then
                restockItem(BUCKET, wantWaterBuckets - T.countItem(WATER_BUCKET), "Buckets")
            end
        end
    else
        print("No chest found below home; keeping items.")
    end
    T.toStartHeight()
end

--------------------------------------------------------------------------
-- Strips and lanes
--
-- Farms are strips of farmland separated by water lanes.  A hole (missing
-- ground block) is repaired to match the line it lies in; a clone builds
-- every tile of the map.  Lanes are built floor+walls first, then watered.
--------------------------------------------------------------------------
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

-- Lane axis of a water tile: "z" if its column is water, else "x".
local function laneAxis(x, z)
    local col = lineTally(function(px, pz) return px == x and pz ~= z end)
    if col.water > 0 and col.crop == 0 then return "z" end
    return "x"
end

local function sortFills(list)
    table.sort(list, function(a, b)
        if a.x ~= b.x then return math.abs(a.x) < math.abs(b.x) end
        return math.abs(a.z) < math.abs(b.z)
    end)
end

-- Repair planning: decide what each hole should become.
local function planFills()
    pendingFills = {}
    for k, kind in pairs(tiles) do
        if kind == "hole" then
            local x, z = keyXZ(k)
            local col = classifyLine(lineTally(function(px, pz) return px == x and pz ~= z end))
            local row = classifyLine(lineTally(function(px, pz) return pz == z and px ~= x end))
            local want, axis
            if col then want, axis = col, "z" elseif row then want, axis = row, "x" end
            if want then pendingFills[#pendingFills + 1] = { x = x, z = z, want = want, axis = axis } end
        end
    end
    sortFills(pendingFills)
    return #pendingFills
end

-- Clone planning: every mapped tile is a target.
local function planClone()
    pendingFills = {}
    for k, kind in pairs(tiles) do
        if kind == "crop" or kind == "water" then
            local x, z = keyXZ(k)
            pendingFills[#pendingFills + 1] = {
                x = x, z = z, want = (kind == "crop") and "land" or "water",
                axis = (kind == "water") and laneAxis(x, z) or nil,
            }
        end
    end
    sortFills(pendingFills)
    return #pendingFills
end

-- Does the map say (x,z) is lane?  Used to decide where walls go.
local function isLane(x, z) return tiles[T.ckey(x, z)] == "water" end

----------------------------------------------------------------- water --
local function regenTile()
    local best
    for k in pairs(wet) do
        local x, z = keyXZ(k)
        local n = 0
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            if wet[T.ckey(x + d[1], z + d[2])] then n = n + 1 end
        end
        if n >= 2 and (not best or math.abs(x) + math.abs(z) < math.abs(best.x) + math.abs(best.z)) then
            best = { x = x, z = z }
        end
    end
    return best
end

-- Hold at least n water buckets: scoop from a regenerating lane tile with
-- empty buckets, else fetch water buckets / buckets from the chest.
local function ensureWater(n)
    local function scoop()
        while T.countItem(WATER_BUCKET) < n and T.countItem(BUCKET) > 0 do
            local r = regenTile()
            if not r then return end
            local before = T.countItem(WATER_BUCKET)
            if goToCruise(r.x, r.z) and T.down() then
                if below() == WATER and T.selectItem(BUCKET) then turtle.placeDown() end
                T.up()
            end
            if T.countItem(WATER_BUCKET) == before then wet[T.ckey(r.x, r.z)] = nil; return end
        end
    end
    scoop()
    if T.countItem(WATER_BUCKET) < n then
        wantWaterBuckets = n
        dumpAtHome()
        scoop()
    end
    return T.countItem(WATER_BUCKET) >= n
end

-- Prepare a lane tile: ground level clear, dirt floor beneath, dirt walls on
-- every side the map doesn't call lane.  Ends at cruise height.
local function prepLane(t)
    if not (goToCruise(t.x, t.z) and T.down()) then return false end
    local g = below()
    if g == WATER then wet[T.ckey(t.x, t.z)] = true; T.up(); return true end
    if g ~= "air" then T.up(); return false end          -- needs the pickaxe phase
    if not T.down() then T.up(); return false end        -- now inside the trench
    local ok = true
    if below() == "air" then ok = placeDirtDown() end
    if ok then
        for d = 0, 3 do
            local nx, nz = t.x + T.DX[d], t.z + T.DZ[d]
            if not isLane(nx, nz) then
                T.face(d)
                if not turtle.detect() then
                    if not (T.selectItem(DIRT) and turtle.place()) then ok = false end
                end
            end
        end
    end
    T.up(); T.up()
    return ok
end

-- Pour one bucket at a prepared lane tile.
local function waterLane(t)
    if not (goToCruise(t.x, t.z) and T.down()) then return false end
    local ok = false
    if below() == WATER then ok = true
    elseif below() == "air" and T.selectItem(WATER_BUCKET) then ok = turtle.placeDown() end
    T.up()
    if ok then wet[T.ckey(t.x, t.z)] = true end
    return ok
end

-- Group water targets into lanes (same axis + same line), sorted along the lane.
local function groupLanes(list)
    local lanes, order = {}, {}
    for _, t in ipairs(list) do
        local id = (t.axis == "z") and ("z" .. t.x) or ("x" .. t.z)
        if not lanes[id] then lanes[id] = {}; order[#order + 1] = id end
        table.insert(lanes[id], t)
    end
    for _, id in ipairs(order) do
        table.sort(lanes[id], function(a, b)
            if a.axis == "z" then return math.abs(a.z) < math.abs(b.z) end
            return math.abs(a.x) < math.abs(b.x)
        end)
    end
    return lanes, order
end

-- Build all pending water tiles.  Returns list of the ones not completed.
local function buildLanes(list)
    local remaining = {}
    local lanes, order = groupLanes(list)
    for _, id in ipairs(order) do
        local lane = lanes[id]
        -- 1. floors and walls for the whole lane first
        local prepped = {}
        for _, t in ipairs(lane) do
            if prepLane(t) then prepped[#prepped + 1] = t else remaining[#remaining + 1] = t end
        end
        -- 2. water.  Need a regenerating source; bootstrap one if there is none.
        local todo = {}
        for _, t in ipairs(prepped) do if not wet[T.ckey(t.x, t.z)] then todo[#todo + 1] = t end end
        if #todo > 0 and not regenTile() then
            if #todo >= 3 and ensureWater(2) then
                if waterLane(todo[1]) and waterLane(todo[3]) then
                    sleep(1)                                -- let tile 2 become a source
                    local mid = todo[2]
                    if goToCruise(mid.x, mid.z) and T.down() then
                        if below() == WATER then wet[T.ckey(mid.x, mid.z)] = true end
                        T.up()
                    end
                    if not wet[T.ckey(mid.x, mid.z)] then waterLane(mid) end
                end
            end
        end
        for _, t in ipairs(todo) do
            if not wet[T.ckey(t.x, t.z)] then
                if ensureWater(1) and waterLane(t) then
                    -- done
                else
                    remaining[#remaining + 1] = t
                end
            end
        end
    end
    return remaining
end

------------------------------------------------------------------ land --
-- Make (x,z) farmland with wheat on it.  Handles air (needs dirt), water
-- (dirt replaces it), tillable ground and existing farmland.
local function buildLand(t)
    if not (goToCruise(t.x, t.z) and T.down()) then return false end
    local g = below()
    if g == "air" or g == WATER then
        if placeDirtDown() then g = DIRT end
    end
    if TILLABLE[g] then turtle.digDown(); g = FARMLAND end
    T.up()
    if g ~= FARMLAND then return false end
    plantDown()
    return true
end

-- Work through pendingFills: land first (so lane walls exist), then lanes.
local function buildPending(label)
    if #pendingFills == 0 then return end
    local land, water = {}, {}
    for _, t in ipairs(pendingFills) do
        if t.want == "land" then land[#land + 1] = t else water[#water + 1] = t end
    end
    wantWaterBuckets = (#water > 0) and 2 or 0
    if T.countItem(DIRT) < dirtNeeded() or T.countItem(SEED) == 0 then dumpAtHome() end
    if T.countItem(DIRT) == 0 then
        print(#pendingFills .. " tiles to " .. label .. " but no dirt in chest or inventory.")
        return
    end
    print(string.format("%s: %d land, %d water tiles (%d dirt on board)",
        label, #land, #water, T.countItem(DIRT)))

    local remaining = {}
    for _, t in ipairs(land) do
        if T.countItem(DIRT) == 0 then dumpAtHome() end
        if buildLand(t) then tiles[T.ckey(t.x, t.z)] = "crop"
        else remaining[#remaining + 1] = t end
    end
    for _, t in ipairs(buildLanes(water)) do remaining[#remaining + 1] = t end
    for _, t in ipairs(water) do
        if wet[T.ckey(t.x, t.z)] then tiles[T.ckey(t.x, t.z)] = "water" end
    end
    pendingFills = remaining
    wantWaterBuckets = 0
    saveMap()
    print(string.format("%s done: %d tiles still open.", label, #remaining))
end

--------------------------------------------------------------------------
-- Clone phase 1 (pickaxe): clear crop level, trench lanes, remove stone.
--------------------------------------------------------------------------
local function clonePrepare()
    local restore = T.usePrimaryTool(PICKAXE)
    print("Clone phase 1: clearing and trenching with the pickaxe")
    local plan = T.serpentine(WIDTH, LENGTH)
    for i, t in ipairs(plan) do
        local kind = tiles[T.ckey(t.x, t.z)]
        if (kind == "crop" or kind == "water") and goToCruise(t.x, t.z) then
            local c = below()
            if c ~= "air" and c ~= CROP then turtle.digDown() end     -- clear crop level
            if T.down() then
                local g = below()
                if kind == "water" then
                    if g == WATER then wet[T.ckey(t.x, t.z)] = true
                    elseif g ~= "air" then turtle.digDown() end        -- trench
                else
                    if g ~= "air" and g ~= WATER and g ~= FARMLAND and not TILLABLE[g] then
                        turtle.digDown()                               -- stone etc.
                    end
                end
                T.up()
            end
        end
        if i % 50 == 0 then print(string.format("%d/%d cleared", i, #plan)) end
        if T.inventoryFull() then dumpAtHome() end
    end
    restore()
end

--------------------------------------------------------------------------
-- Passes
--------------------------------------------------------------------------
local function learnPass()
    print(string.format("Learning layout: %dx%d", WIDTH, LENGTH))
    tiles, wet = {}, {}
    local counts = { crop = 0, water = 0, other = 0, hole = 0 }
    local plan = T.serpentine(WIDTH, LENGTH)
    for i, t in ipairs(plan) do
        local kind = "other"
        if goToCruise(t.x, t.z) then kind = learnTile() end
        tiles[T.ckey(t.x, t.z)] = kind
        if kind == "water" then wet[T.ckey(t.x, t.z)] = true end
        counts[kind] = counts[kind] + 1
        if i % 50 == 0 then
            print(string.format("%d/%d scanned, %d crop tiles", i, #plan, counts.crop))
        end
        if T.inventoryFull() or T.countItem(SEED) == 0 then dumpAtHome() end
    end
    saveMap()
    print(string.format("Layout saved: %d crop, %d water, %d other, %d holes",
        counts.crop, counts.water, counts.other, counts.hole))
    if planFills() > 0 then
        print(#pendingFills .. " holes lie in land or water strips and will be repaired.")
        buildPending("Repair")
    end
end

local function farmPass()
    local plan = tilesOfKind("crop")
    local stats = { harvested = 0, planted = 0, growing = 0, empty = 0,
                    blocked = 0, noseeds = 0 }
    local skipped, triedRestock = 0, false
    for i, t in ipairs(plan) do
        if goToCruise(t.x, t.z) then
            local r = workCrop()
            if r == "noseeds" and not triedRestock then
                dumpAtHome()
                triedRestock = true
                if goToCruise(t.x, t.z) then r = workCrop() end
            end
            stats[r] = stats[r] + 1
        else
            skipped = skipped + 1
        end
        if i % 50 == 0 then
            print(string.format("%d/%d tiles, fuel %s", i, #plan, tostring(turtle.getFuelLevel())))
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
if doClone and not haveMap then
    print("No saved layout to clone. Learn a farm first.")
    return
end
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
local perTile = doClone and 5 or CRUISE_MOVES_PER_TILE
T.requireFuel(math.floor(math.abs(WIDTH * LENGTH) * perTile)
              + math.abs(WIDTH) + math.abs(LENGTH) + 150)

if haveMap and not doClone then
    for k, kind in pairs(tiles) do if kind == "water" then wet[k] = true end end
end

local restoreTools = T.usePrimaryTool(HOE)

local ok, err = pcall(function()
    T.clearBlocked()
    if doClone then
        print(string.format("Cloning saved %dx%d layout here (%d crop, %d water tiles)",
            WIDTH, LENGTH, countKind("crop"), countKind("water")))
        planClone()
        dumpAtHome()
        clonePrepare()
        buildPending("Clone")
    else
        dumpAtHome()
        if not haveMap then
            learnPass()
            dumpAtHome()
        end
        planFills()
    end
    while true do
        T.clearBlocked()
        if #pendingFills > 0 then buildPending(doClone and "Clone" or "Repair") end
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
