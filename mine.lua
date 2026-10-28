-- mine.lua -- tunnel-mining turtle for CC:Tweaked
--
-- Needs a pickaxe (any *_pickaxe upgrade), equipped or in the inventory.
-- Any other tool is parked in the inventory while it runs and put back
-- afterwards.  Optional: Advanced Peripherals Chunky Turtle upgrade so it
-- keeps running unattended.
--
-- Usage:  mine <width> <height> [length] [--spacing N] [--no-lights] [--here]
--         mine --resume          keep digging the tunnel it stopped in (from
--                                the start, or from the last home)
--         mine ... --new         start a fresh tunnel, forgetting the old one
--         mine haul              shuttle the valuables in the homes back to
--                                the start, as many trips as it takes
--         mine reset             back to the last home it built, after a
--                                Ctrl+T or restart
--         mine reset --to-start  back to the start instead
--         mine reset --here      turtle was put back at the start by hand
--
-- width  = blocks to the RIGHT of the turtle (negative = to the LEFT)
-- height = blocks UP from the turtle (negative = DOWN)
-- length = blocks the tunnel runs ahead; leave it out to keep going until
--          the turtle can't (out of chests or fuel, a full chest, bedrock)
-- The turtle's own column and row are part of the tunnel: it stands in
-- the mouth at one bottom (or top, for negative heights) corner, and the
-- tunnel starts with the block in front of it.  `mine 3 3 32` digs a 3x3
-- tunnel 32 long, up and to the right of the turtle.
--
-- Placement: put the turtle where the tunnel's corner should start,
-- facing along it.  Put a chest directly ABOVE the start for valuables and
-- one directly BELOW it for bulk (stone, cobblestone, deepslate, dirt,
-- gravel, sand...).  Stock the top chest with fuel and with CHESTS: the
-- turtle builds a new home out of two of them every `spacing` blocks.
-- Torches in it too, and it lights the tunnel (unless --no-lights).
--
-- How it works:
--  * Homes: the tunnel is dug a segment at a time.  At the end of each
--    segment the turtle builds a home there: a chest set into the wall
--    beside its start column (valuables and supplies) and one under the
--    floor (bulk; over the ceiling for a downward tunnel).  Spacing is
--    chosen so a segment's bulk fits in its home's chest (at most 64), and
--    trips to unload or refuel only ever go back to the nearest home.
--  * Supplies move forward: building a home, the turtle carries the spare
--    chests and the fuel from the old home to the new one, as many trips
--    as it takes.  Bulk stays in the home it was mined near; valuables
--    stay in their home's chest until the end.
--  * Stopping: out of chests for the next home, not enough fuel to go on
--    and still get back, a home chest full or missing, or something it
--    can't dig through.  Then (or once the tunnel is as long as asked) it
--    walks back to the start, collecting the valuables from every home on
--    the way, the most valuable first when it can't carry them all, and
--    leaves them in the top chest at the start.  Supplies stay in the last
--    home, so `mine --resume` can carry on from there (bringing any new
--    chests and fuel from the start's top chest with it).
--  * Fuel: the tank always keeps enough to get back to the start; the
--    turtle refuels from each home's chest, and coal it mines lands there.
--  * Lanes: each segment is mined in lanes running along it, one per row
--    in the side columns and every third row (plus the top and bottom ones)
--    in the middle columns, digging the rows in between up and down.  So
--    the turtle touches every block of the walls, floor and ceiling, and
--    looks at each one.
--  * Geo Scanner (Advanced Peripherals): put one in the start's top chest
--    and the turtle takes it along and uses it: every 15 blocks along a
--    segment it swaps the scanner in for its pickaxe (a chunk controller
--    on the other side stays put), scans (radius 8, no fuel), and swaps
--    back.  It only turns to look at wall blocks the scan says are ore,
--    lava or water, and right after each scan it tunnels out to the ore it
--    found, up to SCAN_REACH (6) from the tunnel, and diamonds however far
--    out as long as the scan saw them, then goes on with the tunnel.  It
--    goes no further than the scan reached, except to follow a diamond
--    vein to its end.  Low on fuel, it fetches the coal first.  See the Geo Scanner section for how it lines the
--    scan's world directions up with the tunnel.
--  * Veins: an ore it touches (anything tagged as an ore, *_ore blocks,
--    ancient debris) is mined along with its whole vein: the turtle
--    follows it block by block, looking all round each one, up to
--    VEIN_REACH blocks out from the tunnel, never back past the start.
--  * Lava and water touching the tunnel or a vein are sealed with a bulk
--    block, and so is anything that lets them through: waterlogged blocks
--    (glow lichen, dripstone... with water in them, which look like blocks
--    but are water sources), water plants, and thin things that aren't
--    solid (lichen, vines, grass) in the walls, floor or ceiling: those are
--    dug out first.  The bulk comes from the inventory (it keeps a stack
--    for this).  Turtles take
--    no harm from lava, but lava burns any item that falls in it and
--    makes the tunnel deadly for players.  Lava or water inside the
--    tunnel is dried out (see dry): filled and dug out, and if it comes
--    back, what feeds it is sealed first.
--  * Floor: the turtle doesn't need one, but a player does.  Every block
--    under the tunnel's bottom row that's a hole (a crevasse, a cave, where
--    floor ore was), a fluid, or something not to stand on (grass, snow,
--    cobwebs, dripstone) is filled with a bulk block; a crevasse across the
--    tunnel gets a bridge.  The turtle tops its stack of bulk up from each
--    home's bulk chest, and fetches more if it runs out mid-crevasse.
--  * Lighting: with torches, it keeps every floor block of the tunnel at
--    block light 2 or more (mobs spawn at 0, since 1.18), using as few as
--    that takes: one in a niche dug into the wall at floor level every
--    19 blocks or so for a 3-wide tunnel (fewer the narrower), on both
--    walls when it's wider than 8.  In the niche the torch is out of the
--    tunnel, so the turtle never digs it up again; a niche that opens into
--    a cave gets a bulk block under it to stand the torch on.  Torches are
--    supplies: they move forward with the homes, and it keeps up to 64 on
--    board.  Lighting is optional: with no torches it just keeps mining,
--    and --no-lights turns it off (torches are then just valuables).
--  * Never digs chests, barrels, shulker boxes, spawners or ComputerCraft
--    blocks (other turtles, computers).
--  * Position is saved after every move, so `mine reset` can bring it to
--    its last home (`--home N`: home N; `--to-start`: the start) after a Ctrl+T or a server
--    restart, checking the home's chests are there when it arrives.  It runs under T.run, so a
--    Ctrl+T in the middle of a move or turn waits for it to be saved.
--    `mine reset` checks the heading against the tunnel first, and stops
--    if the way back digs through far more rock than it should.

local T = require("turtlelib")

local JOB_FILE = T.dataPath("mine.job")
local PROGRESS_FILE = T.dataPath("mine.seg")
local VEIN_REACH = 4       -- how far a vein is followed out from the tunnel
local SCAN_RADIUS = 8      -- Geo Scanner radius (free of fuel up to 8)
local SCAN_REACH = 6       -- with a scanner: how far out from the tunnel ore is fetched
local SCAN_EVERY = 15      -- blocks between scans along a segment's first lane
local ROOM = 2             -- empty slots wanted before each dig
local FILLER_KEEP = 64     -- bulk blocks kept on board for sealing...
local FILLER_KEEP_WET = 192 -- ...once it has run out drying out water
local FUEL_KEEP = 32       -- fuel items carried, so it tops up on the way instead of going home
local FUEL_WORK = 100      -- fuel for some work after a trip back out
local MAX_SPACING = 64     -- most blocks between homes

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
local args = { ... }
local forceHere = T.popFlag(args, "--here")
local resume = T.popFlag(args, "--resume")
local fresh = T.popFlag(args, "--new")
local lights = not T.popFlag(args, "--no-lights")
local spacingArg, homeArg
for i = #args - 1, 1, -1 do
    if args[i] == "--spacing" then
        spacingArg = tonumber(args[i + 1])
        table.remove(args, i + 1); table.remove(args, i)
    elseif args[i] == "--home" then
        homeArg = tonumber(args[i + 1])
        table.remove(args, i + 1); table.remove(args, i)
    end
end
local doReset = args[1] == "reset"
local toStart = T.popFlag(args, "--to-start")
local doHaul = args[1] == "haul"
local WIDTH, HEIGHT, LENGTH = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])

local function usage()
    print("Usage: mine <width> <height> [length] [--spacing N] [--no-lights] [--here]")
    print("       mine --resume | mine haul | mine reset [--home N | --to-start | --here]")
    print("width: + right / - left; height: + up / - down;")
    print("no length: dig until out of chests, fuel or room")
end
if not (doReset or resume or doHaul) and (not (WIDTH and HEIGHT) or WIDTH == 0 or HEIGHT == 0
        or (args[3] and not (LENGTH and LENGTH >= 1))) then
    usage()
    return
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

-- Bulk items go in a home's bulk chest; everything else is a valuable.
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

-- Blocks a player can't stand on (or shouldn't): a floor of these is
-- dug out and filled like a hole.
local SOFT = {}
for _, n in ipairs({ "short_grass", "grass", "tall_grass", "fern", "large_fern", "dead_bush",
        "vine", "glow_lichen", "snow", "moss_carpet", "sculk_vein", "cobweb",
        "pointed_dripstone", "hanging_roots", "cave_vines", "cave_vines_plant",
        "spore_blossom", "small_dripleaf", "big_dripleaf", "big_dripleaf_stem", "sea_pickle",
        "seagrass", "tall_seagrass", "kelp", "kelp_plant" }) do
    SOFT["minecraft:" .. n] = true
end
-- Water plants: water blocks with something growing in them.
local WATER_PLANTS = {}
for _, n in ipairs({ "seagrass", "tall_seagrass", "kelp", "kelp_plant", "bubble_column" }) do
    WATER_PLANTS["minecraft:" .. n] = true
end

-- Thin or soft things (glow lichen, vines, grass, dripstone...): not solid,
-- so in the tunnel's walls, floor or ceiling they're replaced with bulk.
local function soft(data)
    return SOFT[data.name] or (data.tags and data.tags["minecraft:replaceable"]) or false
end

-- Holding water without being water: a waterlogged block (glow lichen,
-- dripstone, roots... with water in it: as good as a water source, but it
-- doesn't look like one) or a water plant.
local function waterIn(data)
    return WATER_PLANTS[data.name] or (data.state and data.state.waterlogged == true) or false
end

-- Supplies: what homes are built from, fuel and torches.  They travel
-- forward.
local CHEST_ITEMS = { ["minecraft:chest"] = true, ["minecraft:barrel"] = true }
local TORCHES = { ["minecraft:torch"] = true, ["minecraft:soul_torch"] = true }
-- The Advanced Peripherals Geo Scanner: kept on board, never unloaded.
local function isScanner(name) return name:find("geo_scanner") ~= nil end
local function isSupply(name) return CHEST_ITEMS[name] or T.fuel[name] or (lights and TORCHES[name]) end

-- What's worth carrying back first when the turtle can't carry it all.
-- Anything not listed: 40 if it looks like an ore's drop, else 10.
local VALUE = {
    ["minecraft:netherite_scrap"] = 100, ["minecraft:ancient_debris"] = 100,
    ["minecraft:diamond"] = 90, ["minecraft:emerald"] = 80, ["minecraft:raw_gold"] = 60,
    ["minecraft:gold_nugget"] = 30, ["minecraft:amethyst_shard"] = 35,
    ["minecraft:lapis_lazuli"] = 45, ["minecraft:raw_iron"] = 50, ["minecraft:raw_copper"] = 25,
    ["minecraft:redstone"] = 30, ["minecraft:quartz"] = 30,
}
local function value(name)
    if VALUE[name] then return VALUE[name] end
    if name:find("raw_") or name:find("ore") or name:find("gem") then return 40 end
    return 10
end

T.cfg.maxHeight, T.cfg.maxDrop = 1000, 1000    -- the tunnel sets the limits
T.diggable = { [LAVA] = true, [WATER] = true }  -- move into fluids (digging them does nothing)

--------------------------------------------------------------------------
-- Tunnel geometry: x in X0..X1, y in Y0..Y1, z in 1..LENGTH; homes every
-- SPACING blocks along it.
--------------------------------------------------------------------------
local X0, X1, Y0, Y1, SPACING, WALL
local segEnd = 0           -- last block of the segment being mined

-- Lighting.  Since 1.18 mobs spawn only at block light 0; a torch is 14
-- and light drops by 1 a block, so a floor block within 13 of a torch is
-- safe.  Torches go in niches dug into the wall at floor level (out of
-- the tunnel, so the turtle never digs them up again), every torchEvery
-- blocks, and on both walls when the tunnel is too wide to light from
-- one.  LIGHT_REACH leaves a margin: every floor block gets light 2.
local LIGHT_REACH = 12
local TORCH_KEEP = lights and 64 or 0    -- torches carried (--no-lights: none)
local torchEvery, torchWalls, torchAlong

local function setBox()
    X0, X1 = math.min(0, WIDTH - T.sgn(WIDTH)), math.max(0, WIDTH - T.sgn(WIDTH))
    Y0, Y1 = math.min(0, HEIGHT - T.sgn(HEIGHT)), math.max(0, HEIGHT - T.sgn(HEIGHT))
    LENGTH = LENGTH or math.huge
    -- a segment's bulk fits in one chest, with room to spare
    SPACING = SPACING or spacingArg
        or math.max(8, math.min(MAX_SPACING, math.floor(27 * 64 * 0.75 / math.abs(WIDTH * HEIGHT))))
    WALL = WIDTH > 0 and 3 or 1             -- the wall beside the start column
    -- how far along z a torch may be from the darkest floor block: one
    -- wall reaches across the width; two walls meet in the middle
    local w = math.abs(WIDTH)
    local along = LIGHT_REACH - w           -- 1 into the niche, w - 1 across
    torchWalls = 1
    if along < 3 then
        torchWalls = 2
        along = math.max(0, LIGHT_REACH - 1 - math.floor((w - 1) / 2))
    end
    torchEvery, torchAlong = 2 * along + 1, along
end

-- Is z where a torch goes?  Every torchEvery blocks, the first lighting
-- the tunnel's mouth; one that would land on a home's wall chest moves
-- one block on.  The last block of a tunnel that ends too far past the
-- last of those (or before the first) gets one too.
local function torchAt(z)
    local first = torchAlong + 1
    local function due(n) return n >= 1 and (n - first) % torchEvery == 0 end
    if due(z) and z % SPACING ~= 0 then return true end
    if due(z - 1) and (z - 1) % SPACING == 0 then return true end
    if z == LENGTH then
        local last = z >= first and z - (z - first) % torchEvery or nil
        return not last or z - last > torchAlong
    end
    return false
end

local function inBox(p)
    return p.x >= X0 and p.x <= X1 and p.y >= Y0 and p.y <= Y1 and p.z >= 1 and p.z <= LENGTH
end

-- How far a block is outside the tunnel dug so far (0: in it).
local function outside(p)
    local dx = math.max(X0 - p.x, 0, p.x - X1)
    local dy = math.max(Y0 - p.y, 0, p.y - Y1)
    local dz = math.max(0, p.z - math.min(LENGTH, segEnd))
    return math.max(dx, dy, dz)
end

local hasScanner = false   -- a Geo Scanner on board: ore is fetched from further out

-- Within reach of the tunnel dug so far (VEIN_REACH; SCAN_REACH with a
-- scanner), and not back past its start.
-- While ore a scan found is being fetched: the spot in the tunnel the
-- scan was taken from.  The turtle goes no further from it than the
-- scan reached (SCAN_RADIUS, along each axis).
local bound

local function inScan(p)
    return not bound or math.max(math.abs(p.x - bound.x), math.abs(p.y - bound.y),
        math.abs(p.z - bound.z)) <= SCAN_RADIUS
end

local function inReach(p)
    return p.z >= 1 and outside(p) <= (hasScanner and SCAN_REACH or VEIN_REACH) and inScan(p)
end

-- Diamonds a scan shows are mined however far out, as long as they're in
-- the scan.
local function isDiamond(name) return name:find("diamond") ~= nil end

--------------------------------------------------------------------------
-- Homes.  Home 0 is the start: valuables chest above, bulk below.  Home
-- k sits at z = k * SPACING in the start column, top row 0: valuables and
-- supplies in a chest in the wall, bulk in one under the floor (over the
-- ceiling, for a tunnel going down).
--------------------------------------------------------------------------
local function homeAt(k)
    if k == 0 then return { k = 0, x = 0, y = 0, z = 0, face = 0, val = "top", bulk = "bottom" } end
    return { k = k, x = 0, y = 0, z = k * SPACING, face = WALL, val = "front",
             bulk = HEIGHT > 0 and "bottom" or "top" }
end
local home = nil          -- the home the turtle works from
local lastHome = 0         -- the furthest home built (the supplies are there)

-- The job, saved so `mine --resume` and `mine reset` know the tunnel.
local function saveJob(state)
    local f = fs.open(JOB_FILE, "w")
    f.write(string.format("%d %d %d %d %d %s", WIDTH, HEIGHT,
        LENGTH == math.huge and 0 or LENGTH, SPACING, lastHome, state))
    f.close()
end

-- How far the segment being dug has got, so `mine --resume` carries on
-- from there instead of going over it all again: the home it's dug from,
-- the lane it's on, and the last block of that lane it finished.
local function saveProgress(lane, z)
    local f = fs.open(PROGRESS_FILE, "w")
    f.write(string.format("%d %d %d", home.k, lane, z))
    f.close()
end

local function loadProgress()
    if not fs.exists(PROGRESS_FILE) then return nil end
    local f = fs.open(PROGRESS_FILE, "r")
    local k, lane, z = (f.readAll() or ""):match("(%d+) (%d+) (-?%d+)")
    f.close()
    if not k then return nil end
    return { k = tonumber(k), lane = tonumber(lane), z = tonumber(z) }
end

local function clearProgress()
    if fs.exists(PROGRESS_FILE) then fs.delete(PROGRESS_FILE) end
end

local function loadJob()
    if not fs.exists(JOB_FILE) then return nil end
    local f = fs.open(JOB_FILE, "r")
    local w, h, l, s, k, state = (f.readAll() or ""):match("(-?%d+) (-?%d+) (-?%d+) (%d+) (%d+) (%a+)")
    f.close()
    if not w then return nil end
    return { width = tonumber(w), height = tonumber(h), length = tonumber(l) ~= 0 and tonumber(l) or nil,
             spacing = tonumber(s), homes = tonumber(k), state = state }
end

--------------------------------------------------------------------------
-- Directions: turtlelib's six (0..3 as T.dir, 0 = +z ahead, 1 = +x
-- right, plus "up" and "down"), and its sides for chests ("front",
-- "top", "bottom").
--------------------------------------------------------------------------
local DELTA, OPP = T.DELTA, T.OPP
local neighbour, key, here, dist = T.neighbour, T.posKey, T.here, T.dist
local look, digDir, placeDir, moveDir = T.look, T.digDir, T.placeDir, T.moveDir
local turnsTo, eachAround, dirTo, stepToward = T.turnsTo, T.eachAround, T.dirTo, T.stepToward
local dropSide, containerOn = T.dropSide, T.containerOn

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------
local opened = {}          -- key(p) = true: known to be air (dug or visited)
local trail = {}           -- directions moved out of the tunnel into a vein
local inTrip = false
local fuelGoal = 0
local fillerKeep = FILLER_KEEP  -- FILLER_KEEP_WET once water has used it up
local stats = { veins = 0, ore = 0, sealed = 0, filled = 0, torches = 0, homes = 0, fetched = 0, wet = 0 }
-- From the Geo Scanner (see there): the world direction of the tunnel's +z
-- once lined up, this segment's blocks touching the tunnel ("rock",
-- "ore", "fluid" or "air"), and its ore further out.
local facing
local known, targets = {}, {}
-- And, for following veins without turning to look: where this
-- segment's scans were taken, and the ore and fluid they saw.
local scanFrom, scanned = {}, {}
-- What this segment's scans say is at p: "ore" or "fluid", "clear" (a
-- scan covered it and saw neither), or nil (none covered it).
local function scanSays(p)
    local k = scanned[key(p)]
    if k then return k end
    for _, o in ipairs(scanFrom) do
        if math.max(math.abs(p.x - o.x), math.abs(p.y - o.y), math.abs(p.z - o.z)) <= SCAN_RADIUS then
            return "clear"
        end
    end
end
local pickaxe              -- the pickaxe mined with (found at the start)

-- Stop the job: unwinds to the top, which walks back to the start.
local function stop(reason) error({ stop = reason }, 0) end

-- Fuel to get to the current home (back down the vein, then along the
-- tunnel) and from there back to the start: the tank never holds less.
function T.homeCost()
    return math.abs(T.pos.x - home.x) + math.abs(T.pos.y - home.y) + math.abs(T.pos.z - home.z)
        + 2 * #trail + 2 + home.z
end

--------------------------------------------------------------------------
-- Moving and digging
--------------------------------------------------------------------------
local trip                 -- defined below

-- Make room before a dig: when a slot has filled or emptied since the
-- last look (a new stack started, maybe one that could have joined
-- another, or a gap opened ahead of a part stack), tidy the inventory;
-- then a trip home if fewer than ROOM slots are free.
local freeBefore = 0
local function room()
    local free = T.freeSlots()
    if free ~= freeBefore or free < ROOM then
        T.tidyInventory()
        free = T.freeSlots()
    end
    freeBefore = free
    if not inTrip and free < ROOM then trip("Inventory nearly full") end
end

local function isSource(data)
    return (FLUID[data.name] and data.state and tonumber(data.state.level) == 0) or waterIn(data)
end

-- Fluid, or anything that lets it through: what the tunnel's walls, floor
-- and ceiling mustn't have in them.
local function leaky(data)
    return FLUID[data.name] or waterIn(data) or soft(data)
end

local seal

local digLimit             -- `mine reset`: blocks it may dig on the way back (nil: any)
local repairing = false    -- going over tunnel dug before: any water in it is getting in from somewhere
local wetAt, wetLevel      -- the block it last moved into through water or lava, and its level
local dry                  -- defined below
local plugs = {}           -- key -> position: dug tunnel blocks it filled again (see dry)

-- Step one block in direction d, digging what's there (falling gravel
-- and sand included).  In the tunnel, lava or water there (or let in by
-- the dig) is dried out first (see dry), so none is left behind.  False
-- if it can't: a protected or unbreakable block, or something that won't
-- move out of the way.
local cutOff, stem         -- defined below
local function go(d)
    local n = neighbour(d)
    local inside = inBox(n) and not digLimit
    local wet = false
    for _ = 1, 30 do
        room()                     -- first: a trip changes what's there
        -- through tunnel dug before (going over it, or on a trip), flowing
        -- water ahead is getting in somewhere: wade in (the turtle pushes
        -- it out of the block) rather than step in and out again to dry
        -- it, and follow it from there.  Where it's digging through wet
        -- ground, it dries each block (sources next to it are filled as
        -- it goes).
        local wade = repairing or inTrip
        local ok, data = look(d)
        if ok and inside and (isSource(data) or (FLUID[data.name] and not wade)) then
            dry(d)
            ok, data = look(d)
        end
        if ok and inside and wade and FLUID[data.name] and not wet then
            wet = data
            stats.wet = stats.wet + 1
        end
        if ok and not FLUID[data.name] then
            if protected(data.name) then return false, data.name end
            if digLimit then
                if digLimit <= 0 then error({ lost = true }, 0) end
                digLimit = digLimit - 1
            end
            if not digDir(d) then return false, data.name end
            local okw, w = look(d)         -- the dig let water in
            if inside and okw and FLUID[w.name] then
                if isSource(w) then dry(d) else wet = w; stats.wet = stats.wet + 1 end
            end
        end
        local into = wet or (ok and FLUID[data.name] and data)
        if moveDir(d) then
            wetAt, wetLevel = nil, nil
            if into then
                wetAt = key(T.pos)
                wetLevel = type(into) == "table" and tonumber(into.state and into.state.level) or 1
            end
            opened[key(T.pos)] = true
            plugs[key(T.pos)] = nil
            -- in it, the turtle keeps fluid out of the block: seal what
            -- let it in before it spreads, from here, or follow it to
            -- where it comes in
            -- (through tunnel dug before, only where that's outside the
            -- tunnel: above, below, and a wall beside it, no turning to
            -- look into the tunnel; where it's digging, all round, for the
            -- sources next to it too)
            if wet then
                local cut = 0
                eachAround(OPP[d], function(e)
                    if (not wade or e == "up" or e == "down" or not inBox(neighbour(e))) and cutOff(e) then
                        cut = cut + 1
                    end
                end)
                local level = tonumber(wet.state and wet.state.level) or 0
                if cut == 0 and level > 0 then stem(level) end
            end
            return true
        end
    end
    return false, "something in the way"
end

-- Step back the way it came in direction d: backwards, facing d (no
-- turning round), unless facing the other way is fewer turns.
local function retreat(d)
    if d ~= "up" and d ~= "down" and turnsTo(d) <= turnsTo(OPP[d]) then
        T.face(d)
        if T.back() then return true end
    end
    return go(OPP[d])
end

-- Put a bulk block in direction d (into air or a fluid; with nothing to
-- place it against, a turtle places it against itself).
local function putFiller(d)
    if not T.selectItem(function(n) return FILLER[n] end) then return false end
    local ok = placeDir(d)
    turtle.select(1)
    return ok
end

-- Seal lava or water in direction d with a bulk block.
function seal(d)
    local okb, b = look(d)
    if okb and not FLUID[b.name] and (soft(b) or waterIn(b)) and not protected(b.name) then digDir(d) end
    local ok = putFiller(d)
    if ok then
        stats.sealed = stats.sealed + 1
        opened[key(neighbour(d))] = nil
    end
    return ok
end

-- After stepping back out of a block in direction d: if water or lava
-- has got into it, seal it, so the way out isn't a channel into the
-- tunnel (only if it can look without turning).
local function sealBehind(d)
    if d ~= "up" and d ~= "down" and T.dir ~= d then return end
    local ok, data = look(d)
    if ok and FLUID[data.name] then seal(d) end
end

-- Seal the fluid in direction e if it feeds the tunnel: any outside it,
-- a source inside it (a filling, dug out again later).  True if sealed.
function cutOff(e)
    local m = neighbour(e)
    local ok, data = look(e)
    if not (ok and leaky(data) and (isSource(data) or not inBox(m))) then return false, ok and data end
    local was = opened[key(m)]
    if not seal(e) then return false end
    if inBox(m) and (was or repairing) then plugs[key(m)] = m end
    return true
end

-- Water and lava in the tunnel.  A source can't just be dug out: water
-- flows back into an open block from any water beside or above it, a
-- block with two sources beside it becomes a source itself, and a turtle
-- that moves into a source leaves it behind when it moves on.  So the
-- turtle fills a source with a bulk block and digs it out.  If a fluid
-- comes back, something next to that block feeds it (water from above,
-- an aquifer): it steps in, seals the lava and water touching it outside
-- the tunnel, and fills the sources touching it inside, steps back, and
-- tries again.  Those fillings in the tunnel are dug out again in their
-- turn (ahead, by the lanes; behind, at the end of the segment), by when
-- what fed them is sealed.  Flowing water nothing feeds drains away.
-- How strong flowing water or lava is: 0 for a source or falling (level 8
-- and up), else its level (1 next to a source, weaker further on).
local function strength(data)
    local level = tonumber(data.state and data.state.level) or 0
    return level >= 8 and 0 or level
end

-- The turtle is in flowing water (or lava) of the given level that nothing
-- beside it feeds: it comes from further off, along the tunnel.  Follow it
-- upstream through the tunnel (up, if it's falling; else to stronger
-- water beside it), as far as water spreads and falls, to where it comes
-- in from outside, seal that, and come back.  A source in the tunnel is left
-- for drying out when it's reached.  True if it sealed something.
local unfed = {}           -- key: true, flowing water found here with nothing beside it feeding it; "traced"
local function stopFlow(level)
    local path, sealed = {}, false
    unfed[key(T.pos)] = "traced"
    if not T.hasFuel(T.homeCost() + T.cfg.fuelMargin + 40) then return false end
    for _ = 1, 24 do
        local up, upLevel, source = nil, nil, false
        -- look the fewest turns away first (up, down, ahead), and once it
        -- knows the way upstream, don't turn to look any further
        local todo = {}
        for _, e in ipairs({ "up", "down", 0, 1, 2, 3 }) do
            if e ~= (path[#path] and OPP[path[#path]]) then todo[#todo + 1] = e end   -- not back downstream
        end
        while #todo > 0 and not (sealed or source) do
            local best = 1
            for i = 2, #todo do
                if turnsTo(todo[i]) < turnsTo(todo[best]) then best = i end
            end
            if up and turnsTo(todo[best]) > 0 then break end
            local e = table.remove(todo, best)
            local m = neighbour(e)
            local ok, data = look(e)
            if ok and (FLUID[data.name] or waterIn(data)) then
                if not inBox(m) then
                    if seal(e) then sealed = true end
                elseif isSource(data) then
                    -- going over tunnel dug before, it's water getting in: fill it
                    if repairing and cutOff(e) then sealed = true else source = true end
                else
                    local s = (e == "up" and level >= 8) and -1 or strength(data)
                    if s < (level >= 8 and 0 or level) and (not upLevel or s < upLevel) then
                        up, upLevel = e, s
                    end
                end
            end
        end
        if sealed or source or not up then break end
        local ok, data = look(up)
        level = ok and tonumber(data.state and data.state.level) or 0
        if not moveDir(up) then break end
        path[#path + 1] = up
        unfed[key(T.pos)] = "traced"
    end
    for i = #path, 1, -1 do moveDir(OPP[path[i]]) end
    return sealed
end

-- The turtle is in flowing water (level `level`) with nothing beside it
-- to cut off.  Falling water always has something above feeding it, and
-- water in tunnel dug before (repairing) is getting in from somewhere:
-- those are followed to where they come in.  Other water, in tunnel it's
-- digging, is from what it's digging through (left over and draining, or
-- from sources the lanes will reach).  Once it has sealed where water came
-- in, it gives what's left a moment to drain, so it doesn't go chasing
-- that.  True if it sealed it.
function stem(level)
    local k = key(T.pos)
    local sealed = false
    if (level >= 8 or repairing) and unfed[k] == nil and stopFlow(level) then
        sealed = true
        sleep(3)
    end
    unfed[k] = unfed[k] or true
    return sealed
end

local warnedWet = false
function dry(d)
    for _ = 1, 4 do
        local ok, data = look(d)
        if not (ok and FLUID[data.name]) then return true end
        stats.wet = stats.wet + 1
        if not T.selectItem(function(n) return FILLER[n] end) then
            fillerKeep = FILLER_KEEP_WET   -- wet ground: carry more from now on
            trip("Out of blocks to seal water with")
            ok, data = look(d)
            if not (ok and FLUID[data.name]) then return true end
        end
        turtle.select(1)
        if isSource(data) then
            if not seal(d) then break end
            digDir(d)
            ok, data = look(d)
            if not (ok and FLUID[data.name]) then return true end
        end
        -- something feeds it: step in and cut it off, or, with nothing
        -- beside it to cut off, follow the flow to where it comes in
        local level = tonumber(data.state and data.state.level) or 0
        if not moveDir(d) then break end
        local cut = 0
        eachAround(OPP[d], function(e)
            if cutOff(e) then cut = cut + 1 end
        end)
        if cut == 0 and level > 0 and stem(level) then cut = 1 end
        local backed = false
        if d ~= "up" and d ~= "down" then T.face(d); backed = T.back() end
        if not backed then moveDir(OPP[d]) end
        if cut == 0 then return true end   -- nothing feeds it: it drains away
    end
    if not warnedWet then
        warnedWet = true
        print("Couldn't stop the water at " .. T.posString() .. " (out of bulk blocks?); working through it.")
    end
    return false
end

-- The tunnel's floor: the blocks under its bottom row.
local function isFloor(p)
    return p.y == Y0 - 1 and p.x >= X0 and p.x <= X1 and p.z >= 1 and p.z <= LENGTH
end

-- Make the floor block in direction d something a player can walk on:
-- fill a hole (a crevasse, a cave, where floor ore was) or a fluid with a
-- bulk block, digging out grass, cobwebs and the like first.  Out of
-- bulk blocks, it fetches more from its home.
local warnedFloor = false
local function fill(d)
    local ok, data = look(d)
    if ok and not leaky(data) then return true end
    if ok and not FLUID[data.name] then room(); digDir(d) end
    if not T.selectItem(function(n) return FILLER[n] end) then trip("Out of blocks to fill the floor") end
    if putFiller(d) then
        stats.filled = stats.filled + 1
        return true
    end
    if not warnedFloor then
        warnedFloor = true
        print("Couldn't fill a hole in the floor at (" .. key(neighbour(d)) .. "); no bulk blocks left.")
    end
    return false
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
        if FLUID[data.name] then
            if digLimit then break end
            dry(d)
            ok, data = look(d)
            if not ok or FLUID[data.name] then break end
        end
        if protected(data.name) then return end
        if not digDir(d) then return end
    end
    plugs[key(n)] = nil
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
    elseif leaky(data) then seal(d)
    end
end

-- The block in direction d is ore: dig into it, look all round, follow
-- any more ore, then come back.  Ore is followed within reach (and
-- within the scan, fetching what one found); diamond further: anywhere
-- a scan saw, and from a diamond block on to the next however far out,
-- so a diamond vein is followed to its end.
function mineVein(d)
    local ok0, data0 = look(d)
    local diamond = ok0 and isDiamond(data0.name)
    if #trail == 0 then stats.veins = stats.veins + 1 end
    if not go(d) then return end
    stats.ore = stats.ore + 1
    trail[#trail + 1] = d
    -- Look round, the fewest turns away first; not where a scan saw
    -- neither ore nor fluid (no turning to look at plain rock).
    local todo = { "up", "down", 0, 1, 2, 3 }
    local wet = false
    while true do
        local best, near
        for i, e in ipairs(todo) do
            local m = neighbour(e)
            local n = inReach(m)
            local fluid = scanSays(m) == "fluid"
            if not opened[key(m)] and (fluid or n or (m.z >= 1 and (diamond or (bound and inScan(m)))))
                    and scanSays(m) ~= "clear" and (not best or turnsTo(e) < turnsTo(todo[best])) then
                best, near = i, n
            end
        end
        if not best then break end
        local e = table.remove(todo, best)
        local ok, data = look(e)
        if not ok then opened[key(neighbour(e))] = true
        elseif isOre(data) and (near or isDiamond(data.name)) then mineVein(e)
        elseif FLUID[data.name] or waterIn(data) then seal(e); wet = true
        end
    end
    local here = { x = T.pos.x, y = T.pos.y, z = T.pos.z }
    retreat(d)
    trail[#trail] = nil
    if wet then sealBehind(d) end
    if isFloor(here) then fill(d) end      -- ore out of the floor: fill the hole
end

--------------------------------------------------------------------------
-- Getting around inside the tunnel, through blocks already dug (a trip
-- home is made with a nearly full inventory): over to `via`, a finished
-- lane, if the turtle's own lane isn't dug back to the segment's first
-- slice yet; back to that slice; along its row to the start column
-- (columns are finished in order), up or down it (finished first) to row
-- 0, then back along the start column to the home.  Going back out
-- reverses that.
--------------------------------------------------------------------------
local via                  -- the lane before, while the turtle's lane runs back toward the home

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
    local first = home.z + 1
    if T.pos.z >= first then
        if via then
            alongAxis("y", via.y)
            alongAxis("x", via.x)
        end
        alongAxis("z", first)
    end
    alongAxis("x", 0)
    alongAxis("y", 0)
    alongAxis("z", home.z)
    T.face(home.face)
    return T.at(home)
end

local function tunnelTo(p)
    if T.pos.z < home.z + 1 then alongAxis("z", home.z + 1) end
    local lane = via or p
    alongAxis("y", lane.y)
    alongAxis("x", lane.x)
    alongAxis("z", p.z)
    alongAxis("x", p.x)
    alongAxis("y", p.y)
end

--------------------------------------------------------------------------
-- At a home
--------------------------------------------------------------------------
-- How many of each item the chest on `side` holds (none if it can't be read).
local function chestCounts(side) return T.containerCounts(side) or {} end

-- Top up what the turtle works with from the home's chests: a stack of
-- filler from the bulk chest (floors and seals), torches from the
-- valuables chest.
local function restockKit()
    for _, want in ipairs({ { side = home.bulk, set = FILLER, keep = fillerKeep },
                            { side = home.val, set = TORCHES, keep = TORCH_KEEP },
                            { side = home.val, set = T.fuel, keep = FUEL_KEEP } }) do
        local test = function(n) return want.set[n] end
        local counts = chestCounts(want.side)
        for _, name in ipairs(T.sortedKeys(counts)) do
            local n = counts[name]
            local have = T.countItem(test)
            if have >= want.keep then break end
            if want.set[name] then
                T.restockFrom(want.side, name, T.countItem(name) + math.min(n, want.keep - have),
                    { quiet = true, room = ROOM })
            end
        end
    end
end

-- Put what the turtle carries in the home's chests: bulk in the bulk
-- chest, the rest (supplies included) in the valuables chest, keeping
-- tools, a stack of filler and its torches; then restock those.  `only`
-- limits it to "bulk", or makes it "everything".  Returns true if
-- everything fit.
local function unload(only)
    if not (containerOn(home.val) and containerOn(home.bulk)) then return false, "missing" end
    local fits, kept, torches, fuel = true, 0, 0, 0
    for s = 1, 16 do
        local it = turtle.getItemDetail(s, true)
        if it and not T.isTool(it.name) then
            local keep = 0
            if FILLER[it.name] and kept < fillerKeep and only ~= "everything" then
                keep = math.min(it.count, fillerKeep - kept)
                kept = kept + keep
            elseif TORCHES[it.name] and torches < TORCH_KEEP and only ~= "everything" then
                keep = math.min(it.count, TORCH_KEEP - torches)
                torches = torches + keep
            elseif T.fuel[it.name] and fuel < FUEL_KEEP and only ~= "everything" then
                keep = math.min(it.count, FUEL_KEEP - fuel)
                fuel = fuel + keep
            elseif isScanner(it.name) and only ~= "everything" then
                keep = it.count
            end
            local bulk = isBulk(it)
            if it.count > keep and (bulk or only == nil or only == "everything") then
                turtle.select(s)
                dropSide(bulk and home.bulk or home.val, it.count - keep)
                if turtle.getItemCount(s) > keep then fits = false end
            end
        end
    end
    T.tidyInventory()
    if home.val ~= "front" or home.face == T.dir then T.compactContainer(home.val) end
    if only == nil then restockKit() end
    return fits, "full"
end

-- unload, or stop the job if a chest is missing or full.
local function unloadOrStop()
    local ok, why = unload()
    if not ok then
        stop(string.format("The %s at home %d (z=%d) is %s.",
            why == "missing" and "chests" or "chest", home.k, home.z, why))
    end
end

local function refuel() T.refuelFrom(home.val, fuelGoal + home.z) end

-- Enough fuel to do some work and still get back to the start?
local function fuelToGoOn(extra)
    return T.hasFuel(home.z + T.cfg.fuelMargin + (extra or FUEL_WORK))
end

-- Go home, unload and refuel, and come back to this exact spot and
-- facing (up the vein too, if in one).
function trip(why)
    if inTrip then return end
    inTrip = true
    local back, facing = here(), T.dir
    local path = trail
    print(string.format("%s at %s: back to home %d.", why, T.posString(), home.k))
    for i = #path, 1, -1 do retreat(path[i]) end
    trail = {}                     -- out of the vein (also if the job stops here)
    local spot = here()
    if not tunnelHome() then stop("Couldn't get back to home " .. home.k .. " from " .. T.posString()) end
    unloadOrStop()
    refuel()
    if not fuelToGoOn() then stop("Not enough fuel left to go on and still get back.") end
    tunnelTo(spot)
    for _, d in ipairs(path) do go(d) end
    trail = path
    T.face(facing)
    if not T.at(back) then
        print("Couldn't get back to (" .. key(back) .. "); carrying on from " .. T.posString())
    end
    inTrip = false
end

-- Take supplies (chests and fuel) from the home's valuables chest while
-- there's room.  Returns how many it took, and whether any are left.
local function takeSupplies()
    local took = 0
    local counts = chestCounts(home.val)
    for _, name in ipairs(T.sortedKeys(counts)) do
        local n = counts[name]
        if isSupply(name) then
            local before = T.countItem(name)
            T.restockFrom(home.val, name, before + n, { quiet = true, room = 1 })
            took = took + T.countItem(name) - before
        end
    end
    for name in pairs(chestCounts(home.val)) do
        if isSupply(name) then return took, true end
    end
    return took, false
end

-- Put the supplies the turtle carries in the valuables chest in front.
local function leaveSupplies()
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and isSupply(it.name) then
            turtle.select(s)
            turtle.drop()
        end
    end
    turtle.select(1)
end

-- Dig out the block on side `d` (outside the tunnel) and put a chest there.
local function placeChest(d)
    for _ = 1, 10 do
        local ok, data = look(d)
        if not ok then break end
        if protected(data.name) then return T.isContainer(data.name) end
        if FLUID[data.name] then
            dry(d)
            ok, data = look(d)
            if not ok or FLUID[data.name] then break end
        end
        if not digDir(d) then return false end
    end
    if not T.selectItem(function(n) return CHEST_ITEMS[n] end) then return false end
    local ok = placeDir(d)
    turtle.select(1)
    return ok
end

-- A chest can't be opened with a solid block on top.  The valuables chest
-- is in the wall by the home's bottom row, so clear the block above it,
-- from the tunnel row above the home, drying out any water that lets in.
-- (Not in a tunnel 1 high, or going down: the bulk chest is above the
-- home there.)  The turtle starts and ends at the home, facing the chest.
local function roomAboveChest(h)
    if h.k == 0 or Y1 < 1 or not inBox({ x = 0, y = 1, z = h.z }) then return end
    if not go("up") then return end
    T.face(h.face)
    for _ = 1, 10 do                       -- (again while gravel falls into it)
        local ok, data = look(h.face)
        if not ok then break end
        if FLUID[data.name] or waterIn(data) then dry(h.face); break end
        if protected(data.name) or not digDir(h.face) then break end
        local okw, w = look(h.face)        -- the dig let water in
        if okw and FLUID[w.name] then dry(h.face); break end
    end
    go("down")
    T.face(h.face)
end

-- The segment is done: build the next home at its end and move the
-- supplies there from this one.  The turtle starts and ends at a home.
local function advance()
    local next = homeAt(home.k + 1)
    local exists = next.k <= lastHome  -- going over the tunnel again (resumed from an earlier home)
    local have = T.countItem("minecraft:chest") + T.countItem("minecraft:barrel")
    for name, n in pairs(chestCounts(home.val)) do
        if CHEST_ITEMS[name] then have = have + n end
    end
    if have < 2 and not exists then stop("Out of chests to build the next home (needs 2).") end
    -- onto a home that's there already, the supplies (fuel among them) are
    -- there: only the fuel to get there is needed
    if not fuelToGoOn(next.z - home.z + (exists and 0 or 4 * SPACING)) then
        stop("Not enough fuel to build the next home and still get back.")
    end
    inTrip = true                  -- no unloading trips while carrying supplies
    local built = false
    while true do
        local took, more = takeSupplies()
        alongAxis("z", next.z)
        if not built then
            if not (placeChest(next.face) and placeChest(T.sideDir(next.bulk))) then
                stop(string.format("Couldn't build home %d at z=%d.", next.k, next.z))
            end
            built = true
        end
        roomAboveChest(next)               -- (homes built before this get it too)
        T.face(next.face)
        leaveSupplies()
        if not more then break end
        if took == 0 then
            print("Can't carry the rest of the supplies (no room); leaving them in home " .. home.k .. ".")
            break
        end
        if not fuelToGoOn(2 * (next.z - home.z) + next.z) then
            print("Not enough fuel to fetch the rest of the supplies; leaving them in home " .. home.k .. ".")
            break
        end
        alongAxis("z", home.z)     -- back for the rest
        T.face(home.face)
    end
    home = next
    if exists then
        print(string.format("On to home %d at z=%d.", home.k, home.z))
    else
        lastHome = home.k
        stats.homes = stats.homes + 1
        saveJob("active")
        clearProgress()
        print(string.format("Built home %d at z=%d.", home.k, home.z))
    end
    refuel()
    restockKit()                   -- the torches went in with the supplies
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

-- At a lane block: clear the tunnel blocks above and below, look at every
-- block outside the tunnel that this one touches, and make sure the floor
-- under it is solid.
local laneAt = {}          -- "x,y" of this segment's lanes
local function scanHere()
    for _, d in ipairs({ "up", "down" }) do
        local n = neighbour(d)
        if not opened[key(n)] then
            -- a lane block (every block touching the walls, floor or
            -- ceiling is one) is left for when the turtle is in it, so it
            -- can seal what's beyond before fluid gets in
            if inBox(n) then
                if not laneAt[n.x .. "," .. n.y] then clearCell(d) end
            else examine(d) end
        end
        if isFloor(n) then fill(d) end    -- something to walk on
    end
    for _, d in ipairs({ 1, 3, 0 }) do
        local n = neighbour(d)
        local k = known[key(n)]
        -- turning to look is only worth it for what the scanner hasn't
        -- seen, or says is ore, lava or water
        if not inBox(n) and (not k or k == "ore" or k == "fluid") then examine(d) end
    end
end

-- The niche in direction d has nothing to hang a torch on or stand it on
-- (it opens into a cave): step into it, put a bulk block under it, and
-- step back.
local function supportNiche(d)
    if not go(d) then return false end
    trail[#trail + 1] = d                  -- out of the tunnel, as in a vein
    local ok, data = look("down")
    local put = false
    if not ok or FLUID[data.name] or SOFT[data.name] then
        if ok and SOFT[data.name] then digDir("down") end
        put = putFiller("down")
    end
    retreat(d)
    trail[#trail] = nil
    return put
end

-- Light the tunnel from here, if this is a floor-level block by a wall
-- and z is where a torch goes: dig a niche in the wall and put a torch
-- in it, against the block behind or on the one below (one put there if
-- there's neither).  No torches, or --no-lights: it just keeps mining.
local warnedTorch = false
local function lightHere()
    if not lights or T.pos.y ~= Y0 or not torchAt(T.pos.z) then return end
    local d
    if T.pos.x == 0 then d = WALL
    elseif torchWalls == 2 and T.pos.x == (WIDTH > 0 and X1 or X0) then d = (WALL + 2) % 4
    else return end
    local function isTorch(n) return TORCHES[n] end
    if T.countItem(isTorch) == 0 then
        if not warnedTorch then
            warnedTorch = true
            if stats.torches == 0 then
                print("No torches: the tunnel isn't being lit (put some in the start's top chest).")
            else
                print(string.format("Out of torches at z=%d: the tunnel is dark from here.", T.pos.z))
            end
        end
        return
    end
    for _ = 1, 10 do                       -- the niche (again while gravel falls into it)
        room()
        local ok, data = look(d)
        if not ok then break end
        if TORCHES[data.name] or protected(data.name) then return end
        if FLUID[data.name] then
            dry(d)
            ok, data = look(d)
            if not ok or FLUID[data.name] then break end
        end
        if not digDir(d) then return end
    end
    -- it came into this block through water: that would wash the torch
    -- away, so stop it first (and leave the torch out if it can't)
    if wetAt == key(T.pos) then
        if not stopFlow(math.max(1, wetLevel or 1)) then
            print("Water's flowing at " .. T.posString() .. "; no torch there for now.")
            return
        end
        wetAt = nil
        sleep(2)                           -- what's left drains away
    end
    -- lava or water a scan saw next to the niche would get in and put the
    -- torch out: step in and seal it first
    local niche, wet = neighbour(d), false
    for _, v in pairs(DELTA) do
        local m = { x = niche.x + v[1], y = niche.y + v[2], z = niche.z + v[3] }
        if not (m.x == T.pos.x and m.y == T.pos.y and m.z == T.pos.z) and scanSays(m) == "fluid" then wet = true end
    end
    if wet and go(d) then
        eachAround(OPP[d], cutOff)
        retreat(d)
    end
    local placed = T.selectItem(isTorch) and placeDir(d)
    if not placed and supportNiche(d) then placed = T.selectItem(isTorch) and placeDir(d) end
    if placed then
        stats.torches = stats.torches + 1
    else
        print("Couldn't place a torch at " .. T.posString() .. "; carrying on.")
    end
    turtle.select(1)
end

--------------------------------------------------------------------------
-- Geo Scanner (Advanced Peripherals), when there's one on board.  A scan
-- lists every block that isn't air within SCAN_RADIUS, at offsets along
-- the world's axes, which the turtle doesn't know: it lines them up with
-- the tunnel by finding the one way round that puts none of them where it
-- knows there's air (what it has dug).  From then on it knows what's in
-- the walls without turning to look at them, and where ore lies further
-- out: right after each scan it tunnels out to what that scan found, up to
-- SCAN_REACH from the tunnel (diamonds however far, as long as the scan
-- saw them), mines it, and goes on with the tunnel; it goes no further
-- than the scan reached from where it was taken, except to follow a
-- diamond vein to its end.  Low on fuel, it fetches the coal first, and
-- burns it.
--------------------------------------------------------------------------
local warnedScan = false

-- Swap the scanner in for the pickaxe (the other side keeps its chunk
-- controller or whatever it has), scan, and swap back.  If it's
-- equipped already, just scan.
local function scanBlocks()
    local side, slot
    for _, sd in ipairs({ "left", "right" }) do
        local name = T.equipped(sd)
        if name and isScanner(name) then side = sd end
    end
    local equip
    if not side then
        for s = 1, 16 do
            local it = turtle.getItemDetail(s)
            if it and isScanner(it.name) then slot = s; break end
        end
        if not slot then return nil, "no scanner on board" end
        side = (T.equipped("left") == pickaxe and "left") or (T.equipped("right") == pickaxe and "right")
        if not side then return nil, "no pickaxe equipped to swap it with" end
        equip = side == "left" and turtle.equipLeft or turtle.equipRight
        turtle.select(slot)
        if not equip() then turtle.select(1); return nil, "couldn't equip it" end
    end
    -- once equipped, the scanner can take a moment to show up as a
    -- peripheral: ask again until its scan method does (called by name,
    -- not through a wrapped table)
    -- The method is scan in Advanced Peripherals' docs, scanBlocks in
    -- some versions: whichever this one has.
    local methods, method
    local function canScan()
        methods = peripheral.getMethods(side) or {}
        for _, m in ipairs(methods) do
            if m == "scanBlocks" or (m == "scan" and not method) then method = m end
        end
        return method ~= nil
    end
    local found = false
    for _ = 1, 20 do
        found = canScan()
        if found then break end
        sleep(0.1)
    end
    local blocks, err
    if found then
        for _ = 1, 3 do
            local ok, a, b = pcall(peripheral.call, side, method, SCAN_RADIUS)
            if ok then blocks, err = a, b else err = a end
            if blocks then break end
            sleep(1)                       -- the scanner's cooldown
        end
    else
        err = string.format("the %s side has a %s but no scan method (its methods: %s)",
            side, tostring(peripheral.getType(side)), #methods > 0 and table.concat(methods, ", ") or "none")
    end
    if equip then
        turtle.select(slot)
        equip()                            -- the pickaxe back
        turtle.select(1)
    end
    return blocks, err
end

-- A scan's blocks at offsets from the turtle: as they come, or, if they
-- come as world coordinates (any further off than the scan reaches),
-- less the turtle's own (the one turtle in the scan).  nil and why if
-- they can't be made sense of.
local function relative(blocks)
    local first = blocks[1]
    if first and not (type(first.x) == "number" and type(first.y) == "number"
            and type(first.z) == "number" and type(first.name) == "string") then
        local keys = {}
        for k in pairs(first) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        return nil, "scan entries aren't {x, y, z, name, tags} (they have: " .. table.concat(keys, ", ") .. ")"
    end
    -- whole numbers (they come as 3.0, which "3.0" .. keys wouldn't match),
    -- with the turtle-relative r, u, f (right, up, forward) when given
    local function round(v) return v and math.floor(v + 0.5) end
    local whole = {}
    for _, e in ipairs(blocks) do
        whole[#whole + 1] = { x = round(e.x), y = round(e.y), z = round(e.z), name = e.name, tags = e.tags,
                              r = round(e.r), u = round(e.u), f = round(e.f) }
    end
    blocks = whole
    local far = false
    for _, e in ipairs(blocks) do
        if math.abs(e.x) > SCAN_RADIUS or math.abs(e.y) > SCAN_RADIUS or math.abs(e.z) > SCAN_RADIUS then
            far = true
            break
        end
    end
    if not far then return blocks end
    local me
    for _, e in ipairs(blocks) do
        if e.name:find("^computercraft:turtle") then
            if me then return nil, "scan gives world coordinates, and there's more than one turtle in range" end
            me = e
        end
    end
    if not me then return nil, "scan gives world coordinates, and the turtle can't find itself in them" end
    local out = {}
    for _, e in ipairs(blocks) do
        out[#out + 1] = { x = e.x - me.x, y = e.y - me.y, z = e.z - me.z, name = e.name, tags = e.tags,
                          r = e.r, u = e.u, f = e.f }
    end
    return out
end

-- Tags as a set, whichever way round they come.
local function tagSet(list)
    local t = {}
    for k, v in pairs(list or {}) do
        if type(k) == "number" then t[v] = true else t[k] = true end
    end
    return t
end

-- Where a scanned block is in the tunnel's coordinates, if the tunnel's
-- +z points along world direction f (its +x is f turned right).
local function toTunnel(f, e)
    local rx, rz = -f.z, f.x
    return { x = T.pos.x + e.x * rx + e.z * rz, y = T.pos.y + e.y, z = T.pos.z + e.x * f.x + e.z * f.z }
end

local function knownAir(p)
    return opened[key(p)] or (inBox(p) and p.z <= home.z)
end

-- The one way round the scan fits what's been dug, or nil if it can't
-- tell yet (too little dug, or caves everywhere).
local WORLD_DIRS = { { x = 0, z = 1 }, { x = 1, z = 0 }, { x = 0, z = -1 }, { x = -1, z = 0 } }
local function lineUp(blocks)
    local best, bestHits, nextHits = nil, math.huge, math.huge
    for _, f in ipairs(WORLD_DIRS) do
        local hits = 0
        for _, e in ipairs(blocks) do
            if (e.x ~= 0 or e.y ~= 0 or e.z ~= 0) and not FLUID[e.name] and knownAir(toTunnel(f, e)) then
                hits = hits + 1
            end
        end
        if hits < bestHits then best, nextHits, bestHits = f, bestHits, hits
        elseif hits < nextHits then nextHits = hits end
    end
    if bestHits <= 1 and nextHits >= bestHits + 4 then return best end
end

-- File a scan: the blocks touching the tunnel's walls, floor and ceiling
-- (absent ones are air), and ore further out for this segment.
local scans = 0
local function record(blocks, z1, z2, toCell)
    local seen = {}
    scans = scans + 1
    local from = { x = T.pos.x, y = T.pos.y, z = T.pos.z }
    scanFrom[#scanFrom + 1] = from
    for _, e in ipairs(blocks) do
        local p = toCell(e)
        local k = key(p)
        seen[k] = true
        local data = { name = e.name, tags = tagSet(e.tags), state = e.state }
        local kind = isOre(data) and "ore" or (leaky(data) and "fluid") or "rock"
        if kind ~= "rock" then scanned[k] = kind end
        local out = outside(p)
        if out == 1 then known[k] = kind end
        local zTop = z2 == LENGTH and z2 + SCAN_REACH or z2
        if kind == "ore" and out >= 1 and p.z >= z1 and p.z <= zTop and not opened[k]
                and (inReach(p) or isDiamond(e.name)) then
            targets[k] = { x = p.x, y = p.y, z = p.z, coal = e.name:find("coal") ~= nil,
                           from = from, scan = scans }
        end
    end
    -- the blocks touching the tunnel that the scan saw no block in: air
    local function air(x, y, z)
        if math.abs(x - T.pos.x) > SCAN_RADIUS or math.abs(y - T.pos.y) > SCAN_RADIUS then return end
        local k = key({ x = x, y = y, z = z })
        if not seen[k] then known[k] = "air" end
    end
    for z = math.max(z1, T.pos.z - SCAN_RADIUS), math.min(z2, T.pos.z + SCAN_RADIUS) do
        for y = Y0, Y1 do air(X0 - 1, y, z); air(X1 + 1, y, z) end
        for x = X0, X1 do air(x, Y0 - 1, z); air(x, Y1 + 1, z) end
    end
end

local function fuelLow() return not T.hasFuel(home.z + fuelGoal / 2) end

-- Fetch ore found by the scanner, `which` picking it (nil: all, which
-- mops up any a stop for room or fuel left).  It goes from each deposit
-- to the nearest one left (coal first when fuel is low), by whichever is
-- shorter: back part of the way it came and digging on from there, or
-- back to the tunnel and along it (through what's dug, or dug now: it's
-- tunnel) to the block nearest it.  Ore met on the way is mined too;
-- lava and water are sealed; floor it dug through is filled on the way
-- back.  It gives up on what it can't dig to, and ends where it started.
local function fetchTargets(which)
    local list = {}
    for _, t in pairs(targets) do
        if not opened[key(t)] and (not which or which(t)) then list[#list + 1] = t end
    end
    if #list == 0 then return end
    table.sort(list, function(a, b) return key(a) < key(b) end)   -- ties the same every run
    local start, base = here(), #trail
    -- where it has been since leaving the tunnel: way[i] after trail[base + i]
    local way = { [0] = start }
    local function out() return #trail - base end
    local function stepBack()
        local d, from = trail[#trail], here()
        retreat(d)
        trail[#trail] = nil
        way[out() + 1] = nil
        sealBehind(d)
        if isFloor(from) then fill(d) end
    end
    local function nearest(t)
        return { x = math.max(X0, math.min(X1, t.x)), y = math.max(Y0, math.min(Y1, t.y)),
                 z = math.max(1, math.min(segEnd, t.z)) }
    end
    -- the cheapest way to t, as how far back along the way to go first (0:
    -- to the tunnel, and along it); digging costs twice a step through
    -- what's dug
    local function plan(t)
        local q = nearest(t)
        local cost, at = out() + dist(way[0], q) + 2 * dist(q, t), 0
        for i = 1, out() do
            local c = out() - i + 2 * dist(way[i], t)
            if c < cost then cost, at = c, i end
        end
        return cost, at
    end
    local left = {}
    for _, t in ipairs(list) do left[#left + 1] = t end
    while true do
        local coal = fuelLow()
        local pick, pickCost, pickAt
        for i, t in ipairs(left) do
            if not opened[key(t)] then
                local c, at = plan(t)
                if coal and t.coal then c = c - 1000 end
                if not pick or c < pickCost then pick, pickCost, pickAt = i, c, at end
            end
        end
        if not pick then break end
        local t = table.remove(left, pick)
        while out() > pickAt do stepBack() end
        if pickAt == 0 then
            local q = nearest(t)
            alongAxis("z", q.z); alongAxis("x", q.x); alongAxis("y", q.y)
            way = { [0] = here() }
        end
        bound = t.from
        local ore = stats.ore
        for _ = 1, 3 * SCAN_RADIUS do
            if opened[key(t)] then break end
            if dist(T.pos, t) <= 1 then
                local ok, data = look(dirTo(t))
                if ok and isOre(data) then mineVein(dirTo(t)) end
                break
            end
            local d = stepToward(t)
            local ok, data = look(d)
            if ok and isOre(data) then mineVein(d)
            elseif ok and FLUID[data.name] and not seal(d) then break end
            if not go(d) then break end
            trail[#trail + 1] = d
            way[out()] = here()
            eachAround(OPP[d], function(e)
                if scanSays(neighbour(e)) == "fluid" then cutOff(e) end
            end)
        end
        bound = nil
        if stats.ore > ore then stats.fetched = stats.fetched + 1 end
        if t.coal and fuelLow() then T.refuelTo(home.z + fuelGoal) end
    end
    while out() > 0 do stepBack() end
    for _, t in ipairs(list) do targets[key(t)] = nil end
    alongAxis("y", start.y); alongAxis("x", start.x); alongAxis("z", start.z)
end

-- Scan from here (on the segment's first lane) and file what it finds;
-- low on fuel, go for the coal in it now.
local function scanNow(z1, z2)
    local blocks, err = scanBlocks()
    if blocks then blocks, err = relative(blocks) end
    if not blocks then
        if not warnedScan then
            warnedScan = true
            print("Geo scanner: " .. tostring(err) .. "; checking the walls by hand until it works.")
        end
        return
    end
    if warnedScan then
        warnedScan = false
        print("Geo scanner working again.")
    end
    local toCell
    if blocks[1] and blocks[1].f and blocks[1].r and blocks[1].u then
        -- right, up, forward from the turtle (Advanced Peripherals 0.8):
        -- straight into tunnel coordinates by its heading.  If that puts
        -- blocks where it knows it has dug, and some other heading would
        -- fit far better, its heading is off: skip it.  (A few blocks
        -- where it dug are no sign: gravel falls, and water and lava,
        -- which don't count, flow in.)
        local function cellsFor(dir)
            local ahead, right = DELTA[dir], DELTA[(dir + 1) % 4]
            return function(e)
                return { x = T.pos.x + e.f * ahead[1] + e.r * right[1], y = T.pos.y + e.u,
                         z = T.pos.z + e.f * ahead[3] + e.r * right[3] }
            end
        end
        local function hitsFor(cell)
            local hits = 0
            for _, e in ipairs(blocks) do
                if (e.r ~= 0 or e.u ~= 0 or e.f ~= 0) and not FLUID[e.name] and knownAir(cell(e)) then
                    hits = hits + 1
                end
            end
            return hits
        end
        toCell = cellsFor(T.dir)
        local hits, other = hitsFor(toCell), math.huge
        if hits >= 4 then
            for k = 1, 3 do other = math.min(other, hitsFor(cellsFor((T.dir + k) % 4))) end
        end
        if hits >= 4 and other * 2 < hits then
            if not warnedScan then
                warnedScan = true
                print("Geo scanner: the scan puts blocks where it has dug, so its heading looks off; skipping scans.")
            end
            return
        end
        if not facing then
            facing = true
            print("Geo scanner lined up with the tunnel.")
        end
    else
        -- world axes only: line them up with the tunnel from what's dug
        if not facing then
            facing = lineUp(blocks)
            if not facing then return end      -- try again further on
            print("Geo scanner lined up with the tunnel.")
        end
        toCell = function(e) return toTunnel(facing, e) end
    end
    record(blocks, z1, z2, toCell)
    -- collect what this scan found (coal first, low on fuel), then go on
    -- with the tunnel
    local this = scans
    if fuelLow() then
        for _, t in pairs(targets) do
            if t.coal and t.scan == this then
                print(string.format("Low on fuel (%s): going for the coal the scanner found first.",
                    tostring(turtle.getFuelLevel())))
                break
            end
        end
    end
    fetchTargets(function(t) return t.scan == this end)
end

-- Tunnel blocks filled to cut water off behind the lanes: dig them out,
-- now what fed them is sealed (nearest first, a few rounds, as digging one
-- out can mean filling another).
local function unplug()
    for _ = 1, 4 do
        local list = {}
        for _, q in pairs(plugs) do list[#list + 1] = q end
        if #list == 0 then break end
        table.sort(list, function(a, b)
            local da, db = dist(a, T.pos), dist(b, T.pos)
            if da ~= db then return da < db end
            return key(a) < key(b)             -- ties the same every run
        end)
        for _, q in ipairs(list) do
            if plugs[key(q)] then
                alongAxis("z", q.z); alongAxis("x", q.x); alongAxis("y", q.y)
                plugs[key(q)] = nil
            end
        end
    end
    plugs = {}
end

-- Go over part of the tunnel dug before, from the home, for water getting
-- in: first along the floor of the middle of every three columns (water in
-- the tunnel ends up on the floor and spreads across it, so it reaches
-- one of them; if the middle one's floor isn't dug yet, another of the
-- three that is), checking the floor too, then, if that found any, along
-- all its other lanes.  Water it finds is getting in,
-- so it follows it to where it comes in and seals that (see dry); torches
-- washed away are put back.  Nothing else is looked at again.  `done`
-- picks the lanes dug before (nil: all).
local function repair(z1, z2, done)
    local lanes = planLanes()
    repairing = true
    local function walk(pick)
        local n = 0
        for i, lane in ipairs(lanes) do
            if (not done or done(i)) and pick(lane) then
                local from, to = z1, z2
                if n % 2 == 1 then from, to = z2, z1 end
                n = n + 1
                alongAxis("z", from); alongAxis("x", lane.x); alongAxis("y", lane.y)
                local dz = to >= from and 1 or -1
                for z = from, to, dz do
                    if isFloor(neighbour("down")) then fill("down") end   -- the floor too (no turning)
                    lightHere()
                    if z ~= to then go(dz > 0 and 0 or 2) end
                end
            end
        end
    end
    local xs, xn = T.sgn(WIDTH)
    local floorDug = {}                    -- x of the columns whose bottom lane is dug
    for i, lane in ipairs(lanes) do
        if lane.y == Y0 and (not done or done(i)) then floorDug[lane.x] = true end
    end
    local middle = {}
    for g = 0, xn - 1, 3 do                -- each three columns: the middle, else a side
        for _, c in ipairs({ g + 1, g, g + 2 }) do
            if c <= xn - 1 and floorDug[c * xs] then middle[c * xs] = true; break end
        end
    end
    local function first(lane) return lane.y == Y0 and middle[lane.x] end
    local before = stats.wet
    walk(first)
    if stats.wet > before then walk(function(lane) return not first(lane) end) end
    unplug()
    repairing = false
    tunnelHome()
end

-- Go over a segment dug already (resumed from an earlier home than the
-- last), fixing where water gets in.
local function repairSegment(z1, z2)
    print(string.format("Going over z=%d..%d (dug already) for water getting in.", z1, z2))
    repair(z1, z2)
end

-- Mine the segment from z1 to z2, starting and ending at the home.
-- `from`: how far it got before (resuming): its finished lanes are gone
-- over only for water getting in, and it carries on from there.
local function mineSegment(z1, z2, from)
    local lanes = planLanes()
    laneAt = {}
    for _, lane in ipairs(lanes) do laneAt[lane.x .. "," .. lane.y] = true end
    print(string.format("Segment z=%d..%d from home %d: %d lanes, fuel %s.", z1, z2, home.k, #lanes,
        tostring(turtle.getFuelLevel())))
    known, targets, scanFrom, scanned = {}, {}, {}, {}
    local lastScan = nil
    local startLane, startZ = 1, nil
    if from then
        startLane, startZ = from.lane, from.z
        -- what it finished: dug (open), and gone over only for water
        for i, lane in ipairs(lanes) do
            local ahead = i % 2 == 1
            for z = z1, z2 do
                if i < startLane or (i == startLane and (ahead and z <= startZ or not ahead and z >= startZ)) then
                    opened[key({ x = lane.x, y = lane.y, z = z })] = true
                end
            end
        end
        print(string.format("Carrying on with lane %d of %d at z=%d.", math.min(startLane, #lanes), #lanes, startZ))
        repair(z1, z2, function(i) return i < startLane end)
    end
    for i, lane in ipairs(lanes) do
        if i >= startLane then
            local ahead = i % 2 == 1
            local first, to, dz = z1, z2, 1
            if not ahead then first, to, dz = z2, z1, -1 end
            local ok, what = true, nil
            if i == startLane and from then
                -- back out to where it stopped, through what's dug
                via = i > 1 and lanes[i - 1] or nil
                if startZ then first = startZ end
                tunnelTo({ x = lane.x, y = lane.y, z = first })
            elseif i == 1 then ok, what = alongAxis("z", z1)
            else
                via = lanes[i - 1]         -- finished: the way home meanwhile
                ok, what = alongAxis("y", lane.y)
                if ok then ok, what = alongAxis("x", lane.x) end
            end
            if ahead then via = nil end    -- this lane is dug back to the segment's start
            -- scans are taken along the first lane it digs (and the next,
            -- if it carried on partway along that one)
            local scanLane = i == startLane or (from and i == startLane + 1)
            for z = first, to, dz do
                if not ok then break end
                if hasScanner and scanLane and ((z - z1) % SCAN_EVERY == math.floor(SCAN_EVERY / 2)
                        or (z == z2 and (not lastScan or math.abs(z - lastScan) > SCAN_RADIUS))) then
                    scanNow(z1, z2)
                    lastScan = z
                end
                scanHere()
                lightHere()
                saveProgress(i, z)
                if z ~= to then ok, what = go(ahead and 0 or 2) end
            end
            if not ok then stop(string.format("Can't get through at %s (%s).", T.posString(), tostring(what))) end
        end
    end
    via = nil
    saveProgress(#lanes + 1, z2)
    unplug()
    fetchTargets()                         -- the scanner's ore further out
    tunnelHome()
end

--------------------------------------------------------------------------
-- The way back: collect the valuables from every home, most valuable
-- first when there's no room for them all, and leave them at the start.
--------------------------------------------------------------------------
local leftBehind = {}      -- home number -> items left in it

-- The lowest-valued thing carried that's worth less than `than`.
local function cheapestSlot(than)
    local slot, low
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and not T.isTool(it.name) and not isSupply(it.name) and not isScanner(it.name) then
            local v = isBulk(it) and 0 or value(it.name)
            if v < than and (not low or v < low) then slot, low = s, v end
        end
    end
    return slot
end

local function collect(side)
    local counts = chestCounts(side)
    local names = {}
    for name in pairs(counts) do
        if not isSupply(name) then names[#names + 1] = name end
    end
    table.sort(names, function(a, b)
        if value(a) ~= value(b) then return value(a) > value(b) end
        return a < b
    end)
    for _, name in ipairs(names) do
        while (chestCounts(side)[name] or 0) > 0 do
            if T.freeSlots() == 0 then
                local s = cheapestSlot(value(name))
                if not s then break end
                turtle.select(s)
                if not dropSide(side) then break end   -- swap it for something better
            end
            local before = T.countItem(name)
            T.restockFrom(side, name, before + chestCounts(side)[name], { quiet = true, room = 0 })
            if T.countItem(name) == before then break end
        end
    end
    turtle.select(1)
    local left = 0
    for name, n in pairs(chestCounts(side)) do
        if not isSupply(name) then left = left + n end
    end
    return left
end

-- From the home the turtle is at, walk back to the start collecting the
-- valuables from every home on the way, and leave them at the start.
-- True if it got there and the start's chests took everything.
local function walkBackCollecting()
    leftBehind = {}
    unload("bulk")
    print("Walking back to the start, collecting valuables.")
    for k = home.k, 1, -1 do
        local h = homeAt(k)
        alongAxis("x", 0); alongAxis("y", 0)
        alongAxis("z", h.z)
        T.face(h.face)
        if containerOn("front") then
            local left = collect("front")
            if left > 0 then leftBehind[k] = left end
        end
    end
    alongAxis("x", 0); alongAxis("y", 0)
    alongAxis("z", 0)
    T.face(0)
    home = homeAt(0)
    local ok = unload("everything")
    if not ok then print("The chests at the start are full or missing: the rest is still in the turtle.") end
    return ok and T.pos.x == 0 and T.pos.y == 0 and T.pos.z == 0
end

local function returnToStart()
    inTrip, T.fuelTrip, bound = true, nil, nil
    T.cfg.lowFuel = 1                       -- the tank was kept for this
    for i = #trail, 1, -1 do retreat(trail[i]) end
    trail = {}
    tunnelHome()
    return walkBackCollecting()
end

-- `mine haul`: shuttle the valuables in the homes back to the start,
-- walking out to the last home and back collecting, as many trips as it
-- takes (the most valuable come first), refuelling at the start.
-- Supplies stay where they are, for `mine --resume`.
local function haul()
    inTrip, T.fuelTrip = true, nil
    T.cfg.lowFuel = 1                       -- each trip's fuel is checked first
    local last = homeAt(lastHome)
    for _ = 1, 20 do
        if home.k == 0 then
            local need = 2 * last.z + T.cfg.fuelMargin + FUEL_WORK
            if not T.hasFuel(need) then T.refuelFrom("top", need) end
            if not T.hasFuel(need) then
                print(string.format("A trip out to home %d and back takes %d fuel; it has %d. Put fuel in the top chest.",
                    last.k, need, turtle.getFuelLevel()))
                return
            end
            print(string.format("Out to home %d (z=%d).", last.k, last.z))
            alongAxis("z", 1); alongAxis("z", last.z)
            T.face(last.face)
            home = last
        end
        if not walkBackCollecting() then return end
        if next(leftBehind) == nil then
            print("All the valuables are at the start.")
            return
        end
    end
end

--------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------
local function useJob(job)
    WIDTH, HEIGHT, LENGTH, SPACING = job.width, job.height, job.length, job.spacing
    setBox()
end

-- `mine reset` trusts the saved position but checks the heading first:
-- it looks all round (turning on the spot is safe whichever way it
-- really faces) and keeps the way round that fits what it knows of the
-- tunnel here: the finished segments are dug (air), the walls solid.
-- Returns the heading, or nil if it can't tell (it then keeps the saved
-- one; the dig limit catches it if that's wrong).
local function checkHeading(dugTo)
    local solid = {}
    for a = 0, 3 do                        -- a quarter turns right of the way it faces
        local ok, data = turtle.inspect()
        solid[a] = ok and not FLUID[data.name]
        turtle.turnRight()
    end
    local function expect(t)
        local v = DELTA[t]
        local n = { x = T.pos.x + v[1], y = T.pos.y, z = T.pos.z + v[3] }
        if n.z < 1 then return nil end
        if inBox(n) then return n.z <= dugTo and "air" or nil end
        return "solid"
    end
    local score, best = {}, nil
    for h = 0, 3 do                        -- if it really faces tunnel direction h
        local strong, weak = 0, 0
        for a = 0, 3 do
            local e = expect((h + a) % 4)
            if e == "air" and solid[a] then strong = strong + 1 end
            if e == "solid" and not solid[a] then weak = weak + 1 end   -- a cave, a vein
        end
        score[h] = strong * 10 + weak
        if not best or score[h] < score[best] then best = h end
    end
    for h = 0, 3 do
        if h ~= best and score[h] == score[best] then return nil end
    end
    if score[best] >= 10 then return nil end
    return best
end

local function main()
if doReset and forceHere then T.setHomeHere(); return end
pickaxe = T.findTool("_pickaxe$")      -- one equipped, else one in the inventory
if not pickaxe then print("Needs a pickaxe, equipped or in the inventory."); return end
local job = loadJob()

if doReset then
    if not job then print("No saved job; nothing to go back along."); return end
    useJob(job)
    home = homeAt(0)
    segEnd = LENGTH
    local saved = T.loadPos()
    if not saved then print("No saved position; the turtle hasn't moved since its last job."); return end
    T.pos.x, T.pos.y, T.pos.z, T.dir = saved.x, saved.y, saved.z, saved.dir
    -- where to: the last home it built, the one asked for (--home N), or
    -- the start (asked for, no homes yet, or it's at the start already)
    local target = homeAt(job.homes)
    if homeArg then
        if homeArg ~= math.floor(homeArg) or homeArg < 0 or homeArg > job.homes then
            print(string.format("There's no home %s: they go from 0 (the start) to %d.", tostring(homeArg), job.homes))
            return
        end
        target = homeAt(homeArg)
    elseif toStart or saved.z <= 0 then target = homeAt(0) end
    if T.at(target) then
        T.face(target.face)
        print(target.k == 0 and "At the start already." or ("At home " .. target.k .. " already."))
        return
    end
    print(string.format("Last position %s facing %d. Heading back to %s.", T.posString(), T.dir,
        target.k == 0 and "the start" or string.format("home %d (z=%d)", target.k, target.z)))
    inTrip = true                       -- no trips: just get back
    local h = checkHeading(job.homes * SPACING)
    if h and h ~= T.dir then
        print(string.format("It really faces %d, not %d (the tunnel says so): going by that.", h, T.dir))
        T.dir = h
        T.savePos()
    end
    -- the way back digs at most out of a vein and across the segment it
    -- was in; much more than that and its position or heading is wrong
    digLimit = outside(T.pos) + (X1 - X0) + (Y1 - Y0) + 8
    local ok, err = pcall(T.withTool, pickaxe, function()
        -- out of a vein first: straight back to the nearest tunnel block
        if not inBox(T.pos) and T.pos.z >= 1 then
            alongAxis("y", math.max(Y0, math.min(Y1, T.pos.y)))
            alongAxis("x", math.max(X0, math.min(X1, T.pos.x)))
            alongAxis("z", math.max(1, math.min(LENGTH, T.pos.z)))
        end
        alongAxis("x", 0); alongAxis("y", 0); alongAxis("z", target.z)
        T.face(target.face)
    end)
    digLimit = nil
    -- there means its chests are there
    local there = ok and T.pos.x == 0 and T.pos.y == 0 and T.pos.z == target.z
    if there then
        if target.k == 0 then there = containerOn("top") and containerOn("bottom")
        else there = containerOn("front") and containerOn(target.bulk) end
    end
    if not ok or not there then
        if not ok and (type(err) ~= "table" or not err.lost) then error(err, 0) end
        print(not ok and "It's digging through far more rock than the way back should take, so its saved"
            or "There are no home chests where it ended up, so its saved")
        print("position or heading must be wrong (it thinks it's at " .. T.posString() .. "). Stopped.")
        print("Pick it up, put it back at the start facing down the tunnel, and run `mine reset --here`.")
        return
    end
    if T.pos.x == 0 and T.pos.y == 0 and T.pos.z == target.z then
        if target.k == 0 then print("At the start.")
        else
            print(string.format("At home %d (z=%d). `mine --resume` carries on from here%s;", target.k, target.z,
                target.k < job.homes and " (going over the tunnel to the last home again, drying out any water)" or ""))
            print("`mine haul` brings the valuables back to the start.")
        end
    else
        print("Couldn't get there; stopped at " .. T.posString())
    end
    return
end

-- Where a run starts: at the start, or (resuming or hauling) at the home
-- `mine reset` left it at (the last, or one asked for with --home).  nil
-- (having said why) if neither.
local function startingHome(fromLast)
    local saved = T.loadPos()
    local last
    if fromLast and saved and saved.x == 0 and saved.y == 0 and saved.z > 0 and saved.z % SPACING == 0
            and saved.z / SPACING <= lastHome then
        last = homeAt(math.floor(saved.z / SPACING))
    end
    if last then
        T.pos.x, T.pos.y, T.pos.z, T.dir = 0, 0, last.z, saved.dir
        T.face(last.face)
        if not (containerOn("front") and containerOn(last.bulk)) then
            print("Home " .. last.k .. "'s chests are missing.")
            return nil
        end
        return last
    end
    if not T.requireHome(forceHere, "mine") then return nil end
    if not (containerOn("top") and containerOn("bottom")) then
        print("Needs a chest above the turtle (valuables) and one below it (bulk).")
        return nil
    end
    return homeAt(0)
end

if doHaul then
    if not (job and job.homes > 0) then print("No homes yet: everything is at the start already."); return end
    useJob(job)
    lastHome = job.homes
    segEnd = LENGTH
    home = startingHome(true)
    if not home then return end
    T.withTool(pickaxe, haul)
    for _, k in ipairs(T.sortedKeys(leftBehind)) do
        print(string.format("Still %d items in home %d (z=%d).", leftBehind[k], k, homeAt(k).z))
    end
    return
end

if resume then
    if not (job and job.state == "active") then print("No stopped tunnel to resume."); return end
    useJob(job)
    lastHome = job.homes
elseif job and job.state == "active" and job.homes > 0 and not fresh then
    print(string.format("A %dx%d tunnel with %d homes was stopped here.", job.width, job.height, job.homes))
    print("Run `mine --resume` to keep digging it, or add --new to start a fresh tunnel.")
    return
else
    setBox()
end

home = startingHome(resume)
if not home then return end
local lanes = #planLanes()
fuelGoal = lanes * SPACING + 4 * SPACING + 300
saveJob("active")

local stopped
T.withTool(pickaxe, function()
    local ok, err = pcall(function()
        unloadOrStop()
        refuel()
        if not fuelToGoOn() then stop("Not enough fuel to start: put fuel in the top chest.") end
        roomAboveChest(home)               -- a home built before chests got room above them
        -- a Geo Scanner in the top chest (or on board): use it
        for name in pairs(chestCounts("top")) do
            if isScanner(name) and T.countItem(isScanner) == 0 then
                T.restockFrom("top", name, 1, { quiet = true, room = 1 })
            end
        end
        hasScanner = T.countItem(isScanner) > 0 or (T.equipped("left") or ""):find("geo_scanner") ~= nil
            or (T.equipped("right") or ""):find("geo_scanner") ~= nil
        if hasScanner then
            print("Geo scanner on board: scanning instead of checking every wall block.")
        end
        T.fuelTrip = function() trip("Low on fuel") end
        print(string.format("Mining a %dx%d tunnel, %s, homes every %d blocks.", math.abs(WIDTH),
            math.abs(HEIGHT), LENGTH == math.huge and "as long as it can" or (LENGTH .. " long"), SPACING))
        -- resuming from the start: carry its new supplies out to the last home
        if resume and job.homes > 0 and home.k == 0 then
            local last = homeAt(job.homes)
            if not fuelToGoOn(2 * last.z) then stop("Not enough fuel to get back out to home " .. last.k .. ".") end
            inTrip, repairing = true, true  -- through tunnel dug before: water there is getting in
            takeSupplies()
            alongAxis("z", 1); alongAxis("z", last.z)
            repairing = false
            T.face(last.face)
            if not (containerOn("front") and containerOn(last.bulk)) then
                stop("Home " .. last.k .. "'s chests are missing.")
            end
            home = last
            lastHome = last.k
            leaveSupplies()
            refuel()
            restockKit()
            inTrip = false
            print(string.format("Back at home %d (z=%d).", home.k, home.z))
        end
        -- resuming from an earlier home: the supplies (fuel among them) are
        -- in the last one, so fill up and take some fuel there first
        if resume and home.k > 0 and home.k < job.homes and not T.hasFuel(fuelGoal + home.z) then
            local here, last = home, homeAt(job.homes)
            if not fuelToGoOn(2 * (last.z - here.z)) then
                stop("Not enough fuel to fetch more from home " .. last.k .. ": put some in home " .. here.k .. ".")
            end
            print(string.format("Fetching fuel from home %d (z=%d) first.", last.k, last.z))
            inTrip, repairing = true, true
            alongAxis("z", last.z)
            repairing = false
            T.face(last.face)
            if containerOn("front") then
                home = last
                refuel()
                restockKit()
                home = here
            end
            alongAxis("z", here.z)
            T.face(here.face)
            inTrip = false
        end
        if not resume then clearProgress() end
        local progress = resume and loadProgress()
        if not (progress and progress.k == lastHome) then progress = nil end
        while home.z < LENGTH do
            segEnd = math.min(home.z + SPACING, LENGTH)
            if home.k < lastHome then
                repairSegment(home.z + 1, segEnd)
            else
                mineSegment(home.z + 1, segEnd, progress)
                progress = nil
            end
            unloadOrStop()
            refuel()
            if segEnd >= LENGTH then break end
            advance()
        end
    end)
    T.fuelTrip = nil
    inTrip = false
    if not ok then
        if err == "Terminated" then error(err, 0) end
        stopped = type(err) == "table" and err.stop or tostring(err)
        print("Stopping: " .. stopped)
    end
    returnToStart()
end)
saveJob(stopped and "active" or "done")
if not stopped then clearProgress() end
print(string.format("%s: %d homes built, %d veins (%d ore blocks), %d fluid blocks sealed, %d floor holes filled%s%s.",
    stopped and "Stopped" or "Done", stats.homes, stats.veins, stats.ore, stats.sealed, stats.filled,
    lights and (", " .. stats.torches .. " torches placed") or "",
    hasScanner and (", " .. stats.fetched .. " deposits fetched from further out") or ""))
for _, k in ipairs(T.sortedKeys(leftBehind)) do
    print(string.format("No room to bring back %d items from home %d (z=%d).", leftBehind[k], k, homeAt(k).z))
end
if stopped then print("Stopped because: " .. stopped .. " `mine --resume` carries on.") end
end

-- Under T.run, Ctrl+T never leaves the saved position or heading wrong.
T.run(main)
