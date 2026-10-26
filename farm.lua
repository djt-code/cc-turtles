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
--   farm repair                                    inspect every tile once and
--                                                  fix damage, then stop
--   farm clone [repeatMinutes]                     build the saved layout HERE,
--                                                  then farm it
--   farm reset                                     return to home after a stop
--   farm reset --here                              turtle is home already (moved
--                                                  by hand): just reset position
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
--  * Learning pass: only records the layout; it changes nothing.  Flies
--    over every tile in the box.  Wheat below -> farm tile.  Air below ->
--    drops down a block to look at the ground: farmland -> farm tile;
--    water -> lane; other -> left alone.  Missing ground and bare dirt
--    could be either, so they take the kind of the strip they lie in
--    (bare dirt outside any strip is farmed).  Saved to farm.map, which
--    from then on is the farm as it SHOULD be.
--  * Farming pass: walks the layout line by line along the lanes, each
--    line from the end nearest the last, harvesting and planting crop
--    tiles and dipping to crop level over lane tiles to check the water.
--    Ground missing under a crop tile, a dry lane tile, or a block in
--    the way is damage: after the pass the turtle goes home and runs
--    repair mode before sleeping.
--  * Repair mode: rebuilds damaged tiles to match the layout.  Land: dirt,
--    till, plant.  Lane: dirt floor beneath if missing, dirt walls on
--    every side that isn't lane, then water.
--  * Clone: builds farm.map at the current position.  Phase 1 (pickaxe)
--    clears the crop level, digs lane trenches and removes stone where
--    land is wanted.  Phase 2 (hoe) fills/tills/plants land, then floors,
--    walls and waters the lanes.  Each lane is bootstrapped with two water
--    buckets at tiles 1 and 3 (tile 2 becomes a source on its own) and the
--    rest is scooped from that regenerating tile.
--  * Farming pass details: harvests wheat at age 7 and replants it, plants
--    bare farmland (tilling through the air gap if it reverted to dirt),
--    returns home, drops produce, restocks, repairs if needed, sleeps.
--  * Navigation is at a fixed cruise height (turtlelib.stepFlat) with a
--    learned obstacle map and BFS re-routing.  Position is saved to disk
--    after every move so `farm reset` can bring it home after a Ctrl+T.

local T = require("turtlelib")

local MAP_FILE = T.dataPath("farm.map")

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
local args = { ... }
local forceLearn, forceHere, doClone, doRepair = false, false, false, false
for i = #args, 1, -1 do
    if args[i] == "--here" then forceHere = true; table.remove(args, i) end
end
if args[1] == "learn" then forceLearn = true; table.remove(args, 1)
elseif args[1] == "repair" then doRepair = true; table.remove(args, 1)
elseif args[1] == "clone" then doClone = true; forceHere = true; table.remove(args, 1)
elseif args[1] == "reset" then
    if forceHere then T.setHomeHere() else T.goHome() end
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
-- Farm layout map: tiles[key] = "crop" | "water" | "other"
-- (the learning pass also uses "hole" and "dirt" until resolveLayout)
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

-- Is the block below a water SOURCE?  Lanes are all sources; flowing
-- water (level > 0) counts as damage and gets a bucket poured into it.
local function sourceBelow()
    local name, d = below()
    return name == WATER and not (d.state and (tonumber(d.state.level) or 0) > 0)
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
-- harvest = false only plants (repair mode's inspection).
-- Returns: harvested | growing | planted | empty | noseeds | damaged | blocked
-- (damaged: no farmland or dirt to plant on; blocked: something in the way)
local function workCrop(harvest)
    local name, d = below()
    if name == CROP then
        if harvest and d.state and tonumber(d.state.age) == 7 then
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
        return "damaged"
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

-- Classify the tile below during the learning pass, without changing it.
-- crop | water | dirt | hole | other  (dirt and hole: see resolveLayout)
local function learnTile()
    local name = below()
    if name == CROP then return "crop" end
    if name == WATER then return "water" end
    if name == FARMLAND then warnLow(); return "crop" end
    if TILLABLE[name] then warnLow(); return "dirt" end
    if name ~= "air" then return "other" end
    if not T.down() then return "other" end
    local g = below()
    local kind = "other"
    if g == FARMLAND then kind = "crop"
    elseif TILLABLE[g] then kind = "dirt"
    elseif g == WATER then kind = "water"
    elseif g == "air" then kind = "hole"
    end
    T.up()
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

local wantWaterBuckets = 0     -- buckets the lane builder needs on board

-- What stays on board at every visit home: seeds for a pass, fuel, the
-- tools, and dirt and buckets only while a repair needs them.  Everything
-- else goes into the chest.
local function keepPolicy(item, alreadyKept)
    if item.name == SEED then return math.max(0, seedTarget() - alreadyKept) end
    if item.name == DIRT then return math.max(0, dirtNeeded() - alreadyKept) end
    if item.name == WATER_BUCKET then return math.max(0, wantWaterBuckets - alreadyKept) end
    if item.name == BUCKET then
        local filled = math.min(T.countItem(WATER_BUCKET), wantWaterBuckets)
        return math.max(0, wantWaterBuckets - filled - alreadyKept)
    end
    if T.fuel[item.name] then return item.count end
    return 0
end

-- One line listing what the turtle is carrying.
local function inventoryLine(label)
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

-- Pull `name` out of the chest below until we hold `target` of it.
-- suckDown() takes from the chest's first occupied slot regardless of what
-- it is, so anything else that comes out is set aside and dropped back
-- once we're done (fuel is kept).
local warnedEmpty = {}
local function restockItem(name, target, label, quiet)
    if target <= 0 or T.countItem(name) >= target then return end

    local chest = peripheral and peripheral.wrap("bottom")
    if chest and chest.list then
        local any = false
        for _, it in pairs(chest.list()) do
            if it.name == name then any = true; break end
        end
        if not any then
            if not quiet and not warnedEmpty[name] then
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
        turtle.dropDown(j.n)
    end
    -- whole stacks come out, so hand back anything over the target
    local extra = T.countItem(name) - target
    for s = 16, 1, -1 do
        if extra <= 0 then break end
        local it = turtle.getItemDetail(s)
        if it and it.name == name then
            local n = math.min(extra, it.count)
            turtle.select(s)
            turtle.dropDown(n)
            extra = extra - n
        end
    end
    turtle.select(1)
    print(string.format("%s on board: %d (target %d)", label, T.countItem(name), target))
end

local regenTile                -- defined with the lanes below

-- Buckets for lane work: wantWaterBuckets of them.  Empty ones will do
-- when a lane tile can refill them; otherwise full ones are fetched first.
local warnedBuckets = false
local function restockBuckets()
    local want = wantWaterBuckets
    if want <= 0 then return end
    local canScoop = regenTile() ~= nil
    if not canScoop then restockItem(WATER_BUCKET, want, "Water buckets", true) end
    if T.countItem(WATER_BUCKET) + T.countItem(BUCKET) < want then
        restockItem(BUCKET, want - T.countItem(WATER_BUCKET), "Buckets", true)
    end
    if T.countItem(WATER_BUCKET) + T.countItem(BUCKET) < want then
        restockItem(WATER_BUCKET, want - T.countItem(BUCKET), "Water buckets", true)
    end
    local full, empty = T.countItem(WATER_BUCKET), T.countItem(BUCKET)
    if (full + empty < want or (not canScoop and full < want)) and not warnedBuckets then
        warnedBuckets = true
        print(string.format("Lane work wants %d %s; on board: %d water, %d empty (none in chest).",
            want, canScoop and "buckets" or "water buckets", full, empty))
    end
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
        restockBuckets()
    else
        print("No chest found below home; keeping items.")
    end
    T.toStartHeight()
end

--------------------------------------------------------------------------
-- Strips and lanes
--
-- Farms are strips of farmland separated by water lanes.  A learned gap
-- (missing ground, bare dirt) takes the kind of the line it lies in;
-- repair and clone rebuild tiles to match the map.  Lanes are built
-- floor+walls first, then watered.
--------------------------------------------------------------------------
local function lineTally(filter)
    local t = { crop = 0, water = 0, other = 0 }
    for k, kind in pairs(tiles) do
        if t[kind] then                      -- gaps don't count
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

-- Settle the learning pass's gaps into the layout: a hole or bare dirt
-- takes the kind of the strip it lies in.  Bare dirt outside any strip is
-- farmed; a hole outside any strip is left alone.  Returns the number of
-- gaps settled.
local function resolveLayout()
    local settled = {}
    for k, kind in pairs(tiles) do
        if kind == "hole" or kind == "dirt" then
            local x, z = keyXZ(k)
            local want = classifyLine(lineTally(function(px, pz) return px == x and pz ~= z end))
                      or classifyLine(lineTally(function(px, pz) return pz == z and px ~= x end))
            if want == "land" then settled[k] = "crop"
            elseif want == "water" then settled[k] = "water"
            else settled[k] = (kind == "dirt") and "crop" or "other" end
        end
    end
    local n = 0
    for k, kind in pairs(settled) do tiles[k] = kind; n = n + 1 end
    return n
end

-- Direction the farm's lanes run, "x" or "z" ("z" if it has none).
local function farmAxis()
    for k, kind in pairs(tiles) do
        if kind == "water" then return laneAxis(keyXZ(k)) end
    end
    return "z"
end

-- Repair planning: rebuild each damaged tile as the layout says.
local function planRepair(damaged)
    pendingFills = {}
    for _, t in ipairs(damaged) do
        local lane = tiles[T.ckey(t.x, t.z)] == "water"
        pendingFills[#pendingFills + 1] = {
            x = t.x, z = t.z, want = lane and "water" or "land",
            axis = lane and laneAxis(t.x, t.z) or nil,
        }
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
function regenTile()
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

-- Would there be a regenerating tile with addK filled and removeK emptied?
local function regenIf(addK, removeK)
    local a, r = wet[addK], wet[removeK]
    wet[addK], wet[removeK] = true, nil
    local ok = regenTile() ~= nil
    wet[addK], wet[removeK] = a, r
    return ok
end

-- Fill one empty bucket at (x,z).  True if it worked.
local function scoopAt(x, z)
    local before = T.countItem(WATER_BUCKET)
    if goToCruise(x, z) and T.down() then
        if sourceBelow() and T.selectItem(BUCKET) then turtle.placeDown() end
        T.up()
    end
    return T.countItem(WATER_BUCKET) > before
end

local borrowed = {}        -- lane sources emptied to start a refilling tile

-- Hold at least n water buckets: scoop from a regenerating lane tile with
-- empty buckets, else fetch water buckets / buckets from the chest.  With
-- a target and no regenerating tile, water is moved from one of the
-- farm's own sources to the target when that creates one; the source it
-- came from goes on `borrowed` to be refilled afterwards.
local function ensureWater(n, target)
    local function scoop()
        while T.countItem(WATER_BUCKET) < n and T.countItem(BUCKET) > 0 do
            local r = regenTile()
            if not r then return end
            if not scoopAt(r.x, r.z) then wet[T.ckey(r.x, r.z)] = nil; return end
        end
    end
    scoop()
    if T.countItem(WATER_BUCKET) < n and target and T.countItem(BUCKET) > 0 and not regenTile() then
        local tk, best = T.ckey(target.x, target.z), nil
        for k in pairs(wet) do
            if k ~= tk and regenIf(tk, k) then
                local x, z = keyXZ(k)
                local d = math.abs(x - target.x) + math.abs(z - target.z)
                if not best or d < best.d then best = { x = x, z = z, d = d } end
            end
        end
        if best and scoopAt(best.x, best.z) then
            wet[T.ckey(best.x, best.z)] = nil
            borrowed[#borrowed + 1] = { x = best.x, z = best.z, want = "water" }
        end
    end
    if T.countItem(WATER_BUCKET) < n then
        wantWaterBuckets = math.max(wantWaterBuckets, n)
        dumpAtHome()
        scoop()
    end
    return T.countItem(WATER_BUCKET) >= n
end

-- Prepare a lane tile: ground level clear, dirt floor beneath, dirt walls on
-- every side the map doesn't call lane.  Ends at cruise height.  Returns
-- true when ready for water, "mine" when a block fills the lane or sits
-- above it (see mineLanes), or false.
local function prepLane(t)
    if not goToCruise(t.x, t.z) then return false end
    if not T.down() then return "mine" end               -- something above the lane
    local k = T.ckey(t.x, t.z)
    local g = below()
    if sourceBelow() then wet[k] = true; T.up(); return true end
    wet[k] = nil
    if g == WATER then T.up(); return true end           -- flowing: needs a bucket
    if g ~= "air" then T.up(); return "mine" end         -- dirt etc. in the lane
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

-- Dig out whatever fills these lane tiles, and anything sitting above
-- them, with the pickaxe (the hoe would only till dirt).  Returns the
-- tiles it cleared.
local function mineLanes(list)
    if T.countItem(PICKAXE) == 0 then
        print(#list .. " lane tiles are filled in; give the turtle a diamond pickaxe to dig them out.")
        return {}
    end
    local restore = T.usePrimaryTool(PICKAXE)
    local cleared = {}
    for _, t in ipairs(list) do
        if goToCruise(t.x, t.z) then
            if turtle.detectDown() then turtle.digDown() end      -- crop level
            if T.down() then
                local g = below()
                if g ~= "air" and g ~= WATER then turtle.digDown(); g = below() end
                if g == "air" or g == WATER then cleared[#cleared + 1] = t end
                T.up()
            end
        end
        if T.inventoryFull() then dumpAtHome() end
    end
    restore()
    return cleared
end

-- Pour one bucket at a prepared lane tile.  Pouring into flowing water
-- turns it into a source.
local function waterLane(t)
    if not (goToCruise(t.x, t.z) and T.down()) then return false end
    local ok = false
    local g = below()
    if sourceBelow() then ok = true
    elseif (g == "air" or g == WATER) and T.selectItem(WATER_BUCKET) then ok = turtle.placeDown() end
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
        -- 1. floors and walls for the whole lane first, digging out any
        --    filled-in tiles with the pickaxe in one go
        local status, toMine = {}, {}
        for _, t in ipairs(lane) do
            status[t] = prepLane(t)
            if status[t] == "mine" then toMine[#toMine + 1] = t end
        end
        if #toMine > 0 then
            for _, t in ipairs(mineLanes(toMine)) do status[t] = prepLane(t) end
        end
        local prepped = {}
        for _, t in ipairs(lane) do
            if status[t] == true then prepped[#prepped + 1] = t else remaining[#remaining + 1] = t end
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
                        if sourceBelow() then wet[T.ckey(mid.x, mid.z)] = true end
                        T.up()
                    end
                    if not wet[T.ckey(mid.x, mid.z)] then waterLane(mid) end
                end
            end
        end
        for _, t in ipairs(todo) do
            if not wet[T.ckey(t.x, t.z)] then
                if ensureWater(1, t) and waterLane(t) then
                    -- done
                else
                    remaining[#remaining + 1] = t
                end
            end
        end
        for _, t in ipairs(borrowed) do
            if not (ensureWater(1) and waterLane(t)) then remaining[#remaining + 1] = t end
        end
        borrowed = {}
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
    -- two buckets to start a lane from scratch, one to top up from a source
    wantWaterBuckets = (#water == 0 and 0) or (regenTile() and 1 or 2)
    if T.countItem(DIRT) < dirtNeeded() or T.countItem(SEED) == 0
       or T.countItem(WATER_BUCKET) + T.countItem(BUCKET) < wantWaterBuckets then
        dumpAtHome()
    end
    if T.countItem(DIRT) == 0 then
        print(#pendingFills .. " tiles to " .. label .. " but no dirt in chest or inventory.")
        return
    end
    print(string.format("%s: %d land, %d water tiles (%d dirt on board)",
        label, #land, #water, T.countItem(DIRT)))

    local remaining = {}
    for _, t in ipairs(land) do
        if T.countItem(DIRT) == 0 then dumpAtHome() end
        if not buildLand(t) then remaining[#remaining + 1] = t end
    end
    for _, t in ipairs(buildLanes(water)) do remaining[#remaining + 1] = t end
    pendingFills = remaining
    wantWaterBuckets = 0
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
                    if sourceBelow() then wet[T.ckey(t.x, t.z)] = true
                    elseif g ~= "air" and g ~= WATER then turtle.digDown() end  -- trench
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
    local counts = { crop = 0, water = 0, other = 0, hole = 0, dirt = 0 }
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
        if T.inventoryFull() then dumpAtHome() end
    end
    local settled = resolveLayout()
    saveMap()
    print(string.format("Layout saved: %d crop, %d water, %d other (%d gaps settled from their strips)",
        countKind("crop"), countKind("water"), countKind("other"), settled))
end

-- Visiting order for a farming pass: every crop and lane tile, one line
-- at a time along the lanes, each line entered from the end nearest the
-- previous line's last tile, so no line is flown back over empty.
local function passOrder()
    local alongX = farmAxis() == "x"
    local sx, w = T.sgn(WIDTH)
    local sz, l = T.sgn(LENGTH)
    local lines, span = alongX and l or w, alongX and w or l
    local order, lastJ = {}, 0           -- home sits at j = 0
    for i = 1, lines do
        local line = {}
        for j = 1, span do
            local x, z
            if alongX then x, z = j * sx, i * sz else x, z = i * sx, j * sz end
            local kind = tiles[T.ckey(x, z)]
            if kind == "crop" or kind == "water" then line[#line + 1] = { x = x, z = z, j = j } end
        end
        if #line > 0 then
            local a, b, step = 1, #line, 1
            if math.abs(line[#line].j - lastJ) < math.abs(line[1].j - lastJ) then
                a, b, step = #line, 1, -1
            end
            for n = a, b, step do order[#order + 1] = line[n] end
            lastJ = line[b].j
        end
    end
    return order
end

-- Get over tile t.  Lane tiles are inspected from crop level (one down),
-- and the turtle stays down from one lane tile to the next.
local function visit(t, kind)
    if kind == "water" and T.pos.y == -1
       and math.abs(t.x - T.pos.x) + math.abs(t.z - T.pos.z) == 1 then
        T.faceToward(t.x, t.z)
        if T.forward() then return true end
    end
    return goToCruise(t.x, t.z)
end

-- Is the water still there?  Called over a lane tile at cruise height or
-- already down at crop level.  Returns lane | dry | blocked; dry covers
-- no water, flowing water and a block filling the lane.
local function checkLane(t)
    local k = T.ckey(t.x, t.z)
    if T.pos.y == 0 and not T.down() then wet[k] = nil; return "blocked" end
    if sourceBelow() then wet[k] = true; return "lane" end
    wet[k] = nil
    return "dry"
end

-- One sweep over the farm.  harvest = false is repair mode's inspection:
-- nothing is harvested, but bare farmland is still planted.  Returns the
-- damaged tiles (ground or water missing, or something in the way).
local function farmPass(harvest)
    local plan = passOrder()
    local stats = { harvested = 0, planted = 0, growing = 0, empty = 0, lane = 0,
                    damaged = 0, dry = 0, blocked = 0, noseeds = 0 }
    local damaged, skipped, triedRestock = {}, 0, false
    for i, t in ipairs(plan) do
        local kind = tiles[T.ckey(t.x, t.z)]
        if visit(t, kind) then
            local r
            if kind == "water" then
                r = checkLane(t)
            else
                r = workCrop(harvest)
                if r == "noseeds" and not triedRestock then
                    dumpAtHome()
                    triedRestock = true
                    if goToCruise(t.x, t.z) then r = workCrop(harvest) end
                end
            end
            stats[r] = stats[r] + 1
            if r == "damaged" or r == "dry" or r == "blocked" then damaged[#damaged + 1] = t end
        else
            skipped = skipped + 1
        end
        if i % 50 == 0 then
            print(string.format("%d/%d tiles, fuel %s", i, #plan, tostring(turtle.getFuelLevel())))
        end
        if T.inventoryFull() then dumpAtHome() end
    end
    T.toStartHeight()
    print(string.format("Harvested %d, planted %d, growing %d, empty %d, unreachable %d",
        stats.harvested, stats.planted, stats.growing, stats.empty, skipped))
    if #damaged > 0 then
        print(string.format("Damage: %d crop tiles without ground, %d lane tiles not a source, %d blocked",
            stats.damaged, stats.dry, stats.blocked))
    end
    if stats.noseeds > 0 then
        print("Out of seeds: " .. stats.noseeds .. " tiles left bare. Put seeds in the chest.")
    end
    return damaged
end

-- Repair mode: rebuild the damaged tiles to match the layout.  Starts and
-- ends at home.
local function repair(damaged)
    print(#damaged .. " damaged tiles: repairing.")
    planRepair(damaged)
    buildPending("Repair")
    for n, t in ipairs(pendingFills) do
        if n > 8 then print("  ...and " .. (#pendingFills - 8) .. " more"); break end
        print(string.format("  still open: (%d,%d) %s", t.x, t.z, t.want))
    end
    pendingFills = {}                    -- the next pass finds them again
    dumpAtHome()
end

--------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------
local haveMap = (not forceLearn) and loadMap()
if haveMap and resolveLayout() > 0 then saveMap() end   -- maps saved with holes
if (doClone or doRepair) and not haveMap then
    print("No saved layout to " .. (doClone and "clone" or "repair") .. ". Learn a farm first.")
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
              + 2 * countKind("water")                -- worst case: a dip per lane tile
              + math.abs(WIDTH) + math.abs(LENGTH) + 150)

if haveMap and not doClone then
    for k, kind in pairs(tiles) do if kind == "water" then wet[k] = true end end
end

local restoreTools = T.usePrimaryTool(HOE)

local ok, err = pcall(function()
    T.clearBlocked()
    inventoryLine("On board")
    if doClone then
        print(string.format("Cloning saved %dx%d layout here (%d crop, %d water tiles)",
            WIDTH, LENGTH, countKind("crop"), countKind("water")))
        planClone()
        dumpAtHome()
        clonePrepare()
        buildPending("Clone")
        pendingFills = {}                -- the first pass finds what's left
    else
        dumpAtHome()
        inventoryLine("Kept on board")
        if not haveMap then
            learnPass()
            dumpAtHome()
        end
    end
    if doRepair then
        print("Repair mode: inspecting every tile")
        local damaged = farmPass(false)
        dumpAtHome()
        if #damaged > 0 then repair(damaged) else print("No damage found.") end
        inventoryLine("Kept on board")
        return
    end
    while true do
        T.clearBlocked()
        local damaged = farmPass(true)
        dumpAtHome()
        if #damaged > 0 then
            T.clearBlocked()
            repair(damaged)
        end
        print("Pass complete. Fuel: " .. tostring(turtle.getFuelLevel()) ..
            ", seeds: " .. T.countItem(SEED))
        inventoryLine("Kept on board")
        if REPEAT <= 0 then break end
        print("Sleeping " .. REPEAT .. " min (Ctrl+T to stop)")
        sleep(REPEAT * 60)
    end
end)

restoreTools()
if not ok then error(err, 0) end
