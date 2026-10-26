-- farm.lua -- crop farming turtle for CC:Tweaked (wheat, carrots,
-- potatoes, beetroot and sugar cane; any mix of them on one farm)
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
-- blocks down).  Keep in the chest: what each crop is planted with (wheat
-- or beetroot seeds, carrots, potatoes, sugar cane), dirt, and a bucket or
-- two (water buckets for clone); the turtle restocks from it.
--
-- How it works:
--  * Learning pass: only records the layout; it changes nothing.  Flies
--    over every tile in the box.  Wheat below -> farm tile.  Air below ->
--    drops down a block to look at the ground: farmland -> farm tile;
--    water -> lane; other -> left alone.  Missing ground and bare dirt
--    could be either, so they take the kind of the strip they lie in
--    (bare dirt outside any strip is farmed).  Saved to farm.map, which
--    from then on is the farm as it SHOULD be.
--  * Farming pass: serpentines over the crop tiles only, line by line
--    along the lanes, each line from the end nearest the last, lanes
--    skipped.  Untilled dirt is tilled and planted on the way.  Ground
--    missing under a crop tile, or a block in the way, is damage: after
--    the pass the turtle goes home and runs a full repair pass.
--  * Full repair pass (also `farm repair`, and once after clone):
--    inspects every crop tile and dips to crop level over every lane
--    tile to check its water, then rebuilds damaged tiles to match the
--    layout.  Land: dirt, till, plant.  Lane: dirt floor beneath if
--    missing, dirt walls on every side that isn't lane, then water.
--    After learning there's no inspection: learning saw every tile, so
--    just the gaps it found (missing ground, lane water that isn't a
--    source) are rebuilt, and only if there are any.
--  * Clone: builds farm.map at the current position.  Phase 1 (pickaxe)
--    clears the crop level, digs lane trenches and removes stone where
--    land is wanted.  Phase 2 (hoe) fills/tills/plants land, then floors,
--    walls and waters the lanes.  Each lane is bootstrapped with two water
--    buckets at tiles 1 and 3 (tile 2 becomes a source on its own) and the
--    rest is scooped from that regenerating tile.
--  * Crops: learning notes which crop grows on each tile; bare farmland
--    gets the crop most of its strip grows.  The farming pass harvests
--    each crop when ripe (age 7; beetroot 3) and replants the crop the
--    plan wants there (a different crop found growing is harvested when
--    ripe and replaced), plants
--    bare farmland (tilling through the air gap if it reverted to dirt),
--    returns home, drops produce, restocks, repairs if needed, sleeps.
--  * Sugar cane: grows on dirt, sand, moss, mud and the like, beside a
--    water source, up to 3 high from cruise height upwards, so on a farm
--    with cane the turtle travels at CANE_TRAVEL_Y (learning always does).
--    Cane is worked from one above cruise height: a third block is cut on
--    the way in and the second from above, so every cut block lands in
--    the inventory; the bottom block is never cut, since that is what
--    regrows.  A missing bottom block is replanted with cane; if it won't
--    take (no ground, or no water beside it) that's damage, and the full
--    repair pass rebuilds the lane first, then the cane.
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

-- Crops grown on farmland: block -> item that plants it, age when ripe.
local CROPS = {
    ["minecraft:wheat"]     = { seed = "minecraft:wheat_seeds",    ripe = 7, name = "wheat" },
    ["minecraft:carrots"]   = { seed = "minecraft:carrot",         ripe = 7, name = "carrots" },
    ["minecraft:potatoes"]  = { seed = "minecraft:potato",         ripe = 7, name = "potatoes" },
    ["minecraft:beetroots"] = { seed = "minecraft:beetroot_seeds", ripe = 3, name = "beetroot" },
}
local DEFAULT_CROP = "minecraft:wheat"   -- for a farm with nothing growing yet

-- Sugar cane is planted with the item itself, on any of these grounds, and
-- only takes with a water source beside the ground block.  Its bottom block
-- is never cut: that is the part that regrows.
local CANE = "minecraft:sugar_cane"      -- the block and the item
local CANE_GROUND = {
    ["minecraft:dirt"] = true, ["minecraft:grass_block"] = true,
    ["minecraft:coarse_dirt"] = true, ["minecraft:podzol"] = true,
    ["minecraft:rooted_dirt"] = true, ["minecraft:mycelium"] = true,
    ["minecraft:moss_block"] = true, ["minecraft:mud"] = true,
    ["minecraft:muddy_mangrove_roots"] = true, ["minecraft:sand"] = true,
    ["minecraft:red_sand"] = true, ["minecraft:suspicious_sand"] = true,
}
local CANE_TRAVEL_Y = 2    -- travel height over a farm with cane: above 3-high cane

local SEEDS = { CANE }                   -- planting items, sorted
for _, c in pairs(CROPS) do SEEDS[#SEEDS + 1] = c.seed end
table.sort(SEEDS)
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
-- Farm layout map: tiles[key] = "crop" | "cane" | "water" | "other", and
-- for crop tiles crops[key] = the crop block planned there.
-- (the learning pass also uses "hole" and "dirt" until resolveLayout)
--------------------------------------------------------------------------
local tiles = {}
local crops = {}
local wet = {}             -- tiles that actually hold water right now
local pendingFills = {}    -- holes (or clone targets) still to build

local function keyXZ(k)
    local x, z = k:match("(-?%d+),(-?%d+)")
    return tonumber(x), tonumber(z)
end

-- The crop planned for a tile (maps saved before crops were tracked: wheat).
local function cropAt(k) return crops[k] or DEFAULT_CROP end

local function saveMap()
    local f = fs.open(MAP_FILE, "w")
    f.writeLine(WIDTH .. " " .. LENGTH)
    for k, t in pairs(tiles) do
        f.writeLine(k .. " " .. t .. (crops[k] and (" " .. crops[k]) or ""))
    end
    f.close()
end

local function loadMap()
    if not fs.exists(MAP_FILE) then return false end
    local f = fs.open(MAP_FILE, "r")
    local w, l = (f.readLine() or ""):match("(-?%d+) (-?%d+)")
    if not w then f.close(); return false end
    WIDTH, LENGTH = tonumber(w), tonumber(l)
    tiles, crops = {}, {}
    for line in f.readLine do
        local k, t, c = line:match("^(%S+) (%S+) ?(%S*)")
        if k then
            tiles[k] = t
            if c ~= "" and CROPS[c] then crops[k] = c end
        end
    end
    f.close()
    return true
end

local function countKind(kind)
    local n = 0
    for _, k in pairs(tiles) do if k == kind then n = n + 1 end end
    return n
end

-- "12 wheat, 6 carrots": what the layout grows.
local function cropSummary()
    local n, order = {}, {}
    for k, kind in pairs(tiles) do
        if kind == "crop" then
            local c = cropAt(k)
            if not n[c] then n[c] = 0; order[#order + 1] = c end
            n[c] = n[c] + 1
        end
    end
    table.sort(order)
    local parts = {}
    for _, c in ipairs(order) do parts[#parts + 1] = n[c] .. " " .. CROPS[c].name end
    local cane = countKind("cane")
    if cane > 0 then parts[#parts + 1] = cane .. " sugar cane" end
    return #parts > 0 and table.concat(parts, ", ") or "no crops"
end

-- How many of planting item `seed` we want on board: one per tile it
-- grows on plus a margin, capped.  Zero for crops the farm doesn't grow.
local function seedTarget(seed)
    local n = 0
    if seed == CANE then
        n = countKind("cane")
    else
        for k, kind in pairs(tiles) do
            if kind == "crop" and CROPS[cropAt(k)].seed == seed then n = n + 1 end
        end
    end
    return n == 0 and 0 or math.min(MAX_SEEDS, n + 16)
end

-- Is a planting item the farm needs completely missing from the inventory?
local function lacksSeeds()
    for _, seed in ipairs(SEEDS) do
        if seedTarget(seed) > 0 and T.countItem(seed) == 0 then return true end
    end
    return false
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

local function plantDown(seed)
    if not T.selectItem(seed) then return false end
    return turtle.placeDown()
end

local function placeDirtDown()
    return T.selectItem(DIRT) and turtle.placeDown()
end

-- Height for getting around: cruise height, or CANE_TRAVEL_Y over a farm
-- with sugar cane, which grows into cruise height.
local travelY = 0

-- Climb or sink to height y in the current column.
local function toY(y)
    while T.pos.y < y and T.up() do end
    while T.pos.y > y and T.down() do end
    return T.pos.y == y
end

-- Travel to (tx,tz) at travel height, then sink to cruise height.
local function goToCruise(tx, tz)
    toY(travelY)
    return T.goTo(tx, tz) and toY(0)
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
-- `crop` is the crop the plan wants here; a different crop found growing
-- is left to ripen, then harvested and replaced with the planned one.
-- harvest = false only plants (repair mode's inspection).
-- Returns: harvested | growing | planted | empty | noseeds | damaged | blocked
-- (damaged: no farmland or dirt to plant on; blocked: something in the way)
local function workCrop(harvest, crop)
    local seed = CROPS[crop].seed
    local name, d = below()
    local here = CROPS[name]
    if here then
        local age = d.state and tonumber(d.state.age)
        if harvest and age and age >= here.ripe then
            turtle.digDown()                 -- hoe on a crop: breaks it
            plantDown(seed)
            return "harvested"
        end
        return "growing"
    elseif name == "air" then
        if plantDown(seed) then return "planted" end
        if T.countItem(seed) == 0 then return "noseeds" end
        turtle.digDown()                     -- till through the gap
        if plantDown(seed) then return "planted" end
        return "damaged"
    elseif TILLABLE[name] or name == FARMLAND then
        warnLow()
        if TILLABLE[name] then turtle.digDown() end
        if not T.up() then return "blocked" end
        local r = plantDown(seed) and "planted" or (T.countItem(seed) == 0 and "noseeds" or "empty")
        T.down()
        return r
    end
    return "blocked"
end

-- Work a cane tile from one above cruise height (see visit).  The block
-- below is the cane's second block: cut it, never the bottom one, which
-- regrows.  With no second block, drop down to look at the bottom one and
-- plant it if it's missing.  A planting that fails with cane on board
-- means no ground, or no water next to it: damage.
-- Returns: harvested | growing | planted | noseeds | damaged | blocked
local function workCane(harvest)
    local name = below()
    if name == CANE then
        if harvest then turtle.digDown(); return "harvested" end
        return "growing"
    end
    if name ~= "air" or not T.down() then return "blocked" end
    name = below()
    local r = "blocked"
    if name == CANE then r = "growing"
    elseif name == "air" then
        if plantDown(CANE) then r = "planted"
        elseif T.countItem(CANE) == 0 then r = "noseeds"
        else r = "damaged" end
    end
    T.up()
    return r
end

-- Classify the tile below during the learning pass, without changing it.
-- Starts at travel height and comes down, since cane may stand up to it.
-- crop | cane | water | dirt | hole | other  (dirt and hole: see
-- resolveLayout), plus the crop block for a tile with a crop growing on it,
-- plus true for a gap the farming pass won't fix by itself: missing
-- ground, or lane water that isn't a source.
local function learnTile()
    while T.pos.y > 0 do
        local name = below()
        if name == CANE then return "cane" end
        if name ~= "air" or not T.down() then return "other" end
    end
    local name = below()
    if CROPS[name] then return "crop", name end
    if name == CANE then return "cane" end
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
    elseif CANE_GROUND[g] then kind = "cane"      -- sand, mud...: only cane grows there
    elseif g == "air" then kind = "hole"
    end
    local gap = kind == "hole" or (kind == "water" and not sourceBelow())
    T.up()
    return kind, nil, gap
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
    local target = seedTarget(item.name)
    if target > 0 then return math.max(0, target - alreadyKept) end
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
        for _, seed in ipairs(SEEDS) do
            restockItem(seed, seedTarget(seed), (seed:gsub("^minecraft:", ""):gsub("_", " ")))
        end
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
-- Farms are strips of farmland or cane separated by water lanes.  A learned gap
-- (missing ground, bare dirt) takes the kind of the line it lies in;
-- repair and clone rebuild tiles to match the map.  Lanes are built
-- floor+walls first, then watered.
--------------------------------------------------------------------------
local function lineTally(filter)
    local t = { crop = 0, cane = 0, water = 0, other = 0 }
    for k, kind in pairs(tiles) do
        if t[kind] then                      -- gaps don't count
            local x, z = keyXZ(k)
            if filter(x, z) then t[kind] = t[kind] + 1 end
        end
    end
    return t
end

-- The kind a line of tiles is a strip of: crop, cane or water (or nil).
local function classifyLine(t)
    local land = t.crop + t.cane
    if t.water == 0 and land > 0 and land >= t.other then
        return t.cane > t.crop and "cane" or "crop"
    end
    if land == 0 and t.water > 0 and t.water >= t.other then return "water" end
    return nil
end

-- Lane axis of a water tile: "z" if its column is water, else "x".
local function laneAxis(x, z)
    local col = lineTally(function(px, pz) return px == x and pz ~= z end)
    if col.water > 0 and col.crop + col.cane == 0 then return "z" end
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
            settled[k] = want or ((kind == "dirt") and "crop" or "other")
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

-- Give every crop tile learned with nothing growing on it (bare farmland,
-- settled gaps) the crop most of its strip grows, else the crop most of
-- the farm grows, else wheat.  Returns the number of tiles assigned.
local function assignCrops()
    local function majority(filter)
        local n, best = {}, nil
        for k, c in pairs(crops) do
            local x, z = keyXZ(k)
            if filter(x, z) then
                n[c] = (n[c] or 0) + 1
                if not best or n[c] > n[best] or (n[c] == n[best] and c < best) then best = c end
            end
        end
        return best
    end
    local alongX = farmAxis() == "x"
    local farmWide = majority(function() return true end)
    local assigned = {}
    for k, kind in pairs(tiles) do
        if kind == "crop" and not crops[k] then
            local x, z = keyXZ(k)
            assigned[k] = majority(function(px, pz)
                if alongX then return pz == z else return px == x end
            end) or farmWide or DEFAULT_CROP
        end
    end
    local count = 0
    for k, c in pairs(assigned) do crops[k] = c; count = count + 1 end
    return count
end

-- Repair planning: rebuild each damaged tile as the layout says.
-- What each kind of tile is rebuilt as.
local BUILD = { crop = "land", cane = "cane", water = "water" }

local function planRepair(damaged)
    pendingFills = {}
    for _, t in ipairs(damaged) do
        local kind = tiles[T.ckey(t.x, t.z)]
        pendingFills[#pendingFills + 1] = {
            x = t.x, z = t.z, want = BUILD[kind],
            axis = (kind == "water") and laneAxis(t.x, t.z) or nil,
        }
    end
    sortFills(pendingFills)
    return #pendingFills
end

-- Clone planning: every mapped tile is a target.
local function planClone()
    pendingFills = {}
    for k, kind in pairs(tiles) do
        if BUILD[kind] then
            local x, z = keyXZ(k)
            pendingFills[#pendingFills + 1] = {
                x = x, z = z, want = BUILD[kind],
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

local newGround = {}       -- crop/cane tiles that got a dirt wall; plant them

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
                    if T.selectItem(DIRT) and turtle.place() then
                        local nkind = tiles[T.ckey(nx, nz)]
                        if nkind == "crop" or nkind == "cane" then
                            newGround[#newGround + 1] = { x = nx, z = nz, kind = nkind }
                        end
                    else
                        ok = false
                    end
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
-- Make (x,z) farmland with its planned crop on it.  Handles air (needs
-- dirt), water (dirt replaces it), tillable ground and existing farmland.
local function buildLand(t)
    if not (goToCruise(t.x, t.z) and T.down()) then return false end
    local g = below()
    if g == "air" or g == WATER then
        if placeDirtDown() then g = DIRT end
    end
    if TILLABLE[g] then turtle.digDown(); g = FARMLAND end
    T.up()
    if g ~= FARMLAND then return false end
    plantDown(CROPS[cropAt(T.ckey(t.x, t.z))].seed)
    return true
end

-- Make (x,z) cane ground with sugar cane planted on it.  Runs after the
-- lanes are rebuilt, since cane only takes with water beside it.
local function buildCane(t)
    if not (goToCruise(t.x, t.z) and T.down()) then return false end
    local g = below()
    if g == "air" or g == WATER then
        if placeDirtDown() then g = DIRT end
    end
    T.up()
    if not CANE_GROUND[g] then return false end
    return plantDown(CANE) or below() == CANE
end

-- Work through pendingFills: land first (so lane walls exist), then lanes,
-- then cane (which needs the water).
local function buildPending(label)
    if #pendingFills == 0 then return end
    local land, water, cane = {}, {}, {}
    for _, t in ipairs(pendingFills) do
        if t.want == "land" then land[#land + 1] = t
        elseif t.want == "cane" then cane[#cane + 1] = t
        else water[#water + 1] = t end
    end
    -- two buckets to start a lane from scratch, one to top up from a source
    wantWaterBuckets = (#water == 0 and 0) or (regenTile() and 1 or 2)
    if T.countItem(DIRT) < dirtNeeded() or lacksSeeds()
       or T.countItem(WATER_BUCKET) + T.countItem(BUCKET) < wantWaterBuckets then
        dumpAtHome()
    end
    if T.countItem(DIRT) == 0 then
        print(#pendingFills .. " tiles to " .. label .. " but no dirt in chest or inventory.")
        return
    end
    print(string.format("%s: %d land, %d water, %d cane tiles (%d dirt on board)",
        label, #land, #water, #cane, T.countItem(DIRT)))

    local remaining = {}
    for _, t in ipairs(land) do
        if T.countItem(DIRT) == 0 then dumpAtHome() end
        if not buildLand(t) then remaining[#remaining + 1] = t end
    end
    for _, t in ipairs(buildLanes(water)) do remaining[#remaining + 1] = t end
    for _, t in ipairs(cane) do
        if T.countItem(DIRT) == 0 then dumpAtHome() end
        if not buildCane(t) then remaining[#remaining + 1] = t end
    end
    -- a lane wall on a crop or cane tile is new ground: plant it now (from
    -- cruise height, through the air gap) instead of next pass
    for _, t in ipairs(newGround) do
        if goToCruise(t.x, t.z) then
            if t.kind == "cane" then plantDown(CANE)
            else workCrop(false, cropAt(T.ckey(t.x, t.z))) end
        end
    end
    newGround = {}
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
        if BUILD[kind] and goToCruise(t.x, t.z) then
            local c = below()
            if c ~= "air" and not CROPS[c] and c ~= CANE then turtle.digDown() end  -- crop level
            if T.down() then
                local g = below()
                if kind == "water" then
                    if sourceBelow() then wet[T.ckey(t.x, t.z)] = true
                    elseif g ~= "air" and g ~= WATER then turtle.digDown() end  -- trench
                elseif kind == "cane" then
                    if g ~= "air" and g ~= WATER and not CANE_GROUND[g] then
                        turtle.digDown()                               -- stone etc.
                    end
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
    tiles, crops, wet = {}, {}, {}
    travelY = CANE_TRAVEL_Y              -- cane could be anywhere until we know
    local counts = { crop = 0, cane = 0, water = 0, other = 0, hole = 0, dirt = 0 }
    local plan = T.serpentine(WIDTH, LENGTH)
    local gaps = {}
    for i, t in ipairs(plan) do
        local kind, crop, gap = "other", nil, false
        toY(travelY)
        if T.goTo(t.x, t.z) then kind, crop, gap = learnTile() end
        local k = T.ckey(t.x, t.z)
        tiles[k], crops[k] = kind, crop
        if kind == "water" and not gap then wet[k] = true end
        if gap then gaps[#gaps + 1] = { x = t.x, z = t.z } end
        counts[kind] = counts[kind] + 1
        if i % 50 == 0 then
            print(string.format("%d/%d scanned, %d crop tiles", i, #plan, counts.crop))
        end
        if T.inventoryFull() then dumpAtHome() end
    end
    local settled = resolveLayout()
    local guessed = assignCrops()
    saveMap()
    travelY = countKind("cane") > 0 and CANE_TRAVEL_Y or 0
    print(string.format("Layout saved: %d crop, %d cane, %d water, %d other (%d gaps settled from their strips)",
        countKind("crop"), countKind("cane"), countKind("water"), countKind("other"), settled))
    print(string.format("Crops: %s (%d bare tiles given their strip's crop)", cropSummary(), guessed))
    -- gaps that settled into the farm (a hole outside any strip stays "other")
    local toFix = {}
    for _, t in ipairs(gaps) do
        if BUILD[tiles[T.ckey(t.x, t.z)]] then toFix[#toFix + 1] = t end
    end
    return toFix
end

-- Visiting order for a pass: every crop and cane tile (and lane tile, with lanes),
-- one line at a time along the lanes, each line entered from the end
-- nearest the previous line's last tile, so no line is flown back over
-- empty and lines with nothing to visit are skipped.
local function passOrder(lanes)
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
            if kind == "crop" or kind == "cane" or (lanes and kind == "water") then
                line[#line + 1] = { x = x, z = z, j = j }
            end
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

-- Height each kind of tile is worked from: crops from cruise height, lanes
-- from crop level (to see the water), cane from one above cruise height
-- (above its bottom two blocks).
local WORK_Y = { crop = 0, water = -1, cane = 1 }

-- Get to tile t at its working height.  Between neighbouring tiles worked
-- from the same height the turtle moves straight across; otherwise it
-- goes by travel height.  A third block of cane in the way is cut (that's
-- harvest, and it lands in the inventory).
local function visit(t, kind)
    local y = WORK_Y[kind]
    if T.pos.y == y and math.abs(t.x - T.pos.x) + math.abs(t.z - T.pos.z) == 1 then
        T.faceToward(t.x, t.z)
        if kind == "cane" then
            local ok, d = turtle.inspect()
            if ok and d.name == CANE then turtle.dig() end
        end
        if T.forward() then return true end
    end
    if kind ~= "cane" then return goToCruise(t.x, t.z) end
    toY(travelY)
    if not T.goTo(t.x, t.z) then return false end
    while T.pos.y > y do
        if below() == CANE then turtle.digDown() end
        if not T.down() then return false end
    end
    return true
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

-- One sweep over the farm.  The farming pass (harvest, no lanes) visits
-- crop tiles only; the repair inspection (no harvest, lanes) also checks
-- every lane tile.  Bare farmland and untilled dirt are planted either
-- way; that isn't damage.  Returns the damaged tiles (ground or water
-- missing, or something in the way).
local function farmPass(harvest, lanes)
    local plan = passOrder(lanes)
    local stats = { harvested = 0, planted = 0, growing = 0, empty = 0, lane = 0,
                    damaged = 0, dry = 0, blocked = 0, noseeds = 0 }
    local damaged, skipped, triedRestock, bare = {}, 0, {}, {}
    for i, t in ipairs(plan) do
        local k = T.ckey(t.x, t.z)
        local kind = tiles[k]
        if visit(t, kind) then
            local r
            if kind == "water" then
                r = checkLane(t)
            else
                local work, seed
                if kind == "cane" then
                    work, seed = function() return workCane(harvest) end, CANE
                else
                    local crop = cropAt(k)
                    work, seed = function() return workCrop(harvest, crop) end, CROPS[crop].seed
                end
                r = work()
                if r == "noseeds" and not triedRestock[seed] then
                    dumpAtHome()
                    triedRestock[seed] = true
                    if visit(t, kind) then r = work() end
                end
                if r == "noseeds" then bare[seed] = (bare[seed] or 0) + 1 end
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
    toY(travelY)
    print(string.format("Harvested %d, planted %d, growing %d, empty %d, unreachable %d",
        stats.harvested, stats.planted, stats.growing, stats.empty, skipped))
    if #damaged > 0 then
        print(string.format("Damage: %d crop/cane tiles won't plant, %d lane tiles not a source, %d blocked",
            stats.damaged, stats.dry, stats.blocked))
    end
    for seed, n in pairs(bare) do
        print(string.format("Out of %s: %d tiles left bare. Put some in the chest.",
            (seed:gsub("^minecraft:", ""):gsub("_", " ")), n))
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

-- Full repair pass: inspect every crop and lane tile (nothing harvested),
-- then rebuild whatever is damaged.  Starts and ends at home.
local function fullRepair()
    print("Full repair pass: inspecting every tile")
    local damaged = farmPass(false, true)
    dumpAtHome()
    if #damaged > 0 then repair(damaged) else print("No damage found.") end
end

--------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------
local haveMap = (not forceLearn) and loadMap()
if haveMap and resolveLayout() + assignCrops() > 0 then saveMap() end   -- older maps
if haveMap and countKind("cane") > 0 then travelY = CANE_TRAVEL_Y end
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
              + 2 * countKind("cane")                 -- dropping down to check cane
              + math.abs(WIDTH) + math.abs(LENGTH) + 150)

if haveMap and not doClone then
    for k, kind in pairs(tiles) do if kind == "water" then wet[k] = true end end
end

local restoreTools = T.usePrimaryTool(HOE)

local ok, err = pcall(function()
    T.clearBlocked()
    inventoryLine("On board")
    if haveMap then print("Farm plan: " .. cropSummary()) end
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
            local gaps = learnPass()
            dumpAtHome()
            -- learning saw every tile, so only its gaps need fixing
            if #gaps > 0 then
                T.clearBlocked()
                repair(gaps)
            end
        end
    end
    -- a cloned layout gets checked lanes and all once
    if doRepair or doClone then
        T.clearBlocked()
        fullRepair()
    end
    if doRepair then
        inventoryLine("Kept on board")
        return
    end
    while true do
        T.clearBlocked()
        local damaged = farmPass(true, false)
        dumpAtHome()
        if #damaged > 0 then
            -- missing ground: check the whole farm, lanes included
            T.clearBlocked()
            fullRepair()
        end
        print("Pass complete. Fuel: " .. tostring(turtle.getFuelLevel()))
        inventoryLine("Kept on board")
        if REPEAT <= 0 then break end
        print("Sleeping " .. REPEAT .. " min (Ctrl+T to stop)")
        sleep(REPEAT * 60)
    end
end)

restoreTools()
if not ok then error(err, 0) end
