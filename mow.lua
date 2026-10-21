-- mow.lua -- lawn-mowing turtle for CC:Tweaked
--
-- Needs: diamond pickaxe (equipped, or in the inventory to be hot-swapped
-- onto the right side).  Optional: Advanced Peripherals Chunky Turtle
-- upgrade on the LEFT side so it keeps running unattended.
--
-- Usage:  mow <width> <length> [repeatMinutes]
--
-- Place the turtle at one corner of the lawn, on the ground at grass level,
-- facing along the LENGTH axis, with the lawn extending to its RIGHT.
-- Optional chest/barrel directly below the start position for seeds.
--
-- How it works:
--  * The mow plan is a precomputed serpentine list of (x,z) columns.
--  * Terrain is handled locally (turtlelib.stepTerrain): climb steps up
--    to maxClimb, sink onto the ground, refuse crevasses.
--  * Columns that can't be entered are recorded and routed around (BFS).
--  * Unreachable columns are retried at the end while progress is made.

local T = require("turtlelib")

local args   = { ... }
local WIDTH  = tonumber(args[1]) or 16
local LENGTH = tonumber(args[2]) or 16
local REPEAT = tonumber(args[3])          -- minutes between passes; nil = once
local MIN_FUEL = WIDTH * LENGTH + WIDTH + LENGTH + 150

T.cfg.width, T.cfg.length = WIDTH, LENGTH
T.cfg.maxClimb, T.cfg.maxDrop, T.cfg.maxHeight = 3, 12, 16
T.step = T.stepTerrain

-- Blocks we are allowed to cut.  Anything else is terrain / an obstacle.
T.diggable = {
    ["minecraft:short_grass"] = true,    -- 1.20.3+
    ["minecraft:grass"]       = true,    -- older name for short grass
    ["minecraft:tall_grass"]  = true,
    ["minecraft:fern"]        = true,
    ["minecraft:large_fern"]  = true,
    ["minecraft:dead_bush"]   = true,
}

T.equipTool("minecraft:diamond_pickaxe")

--------------------------------------------------------------------------
local function goToAndSettle(tx, tz)
    if not T.goTo(tx, tz) then return false end
    T.settle()
    return true
end

local function mowTiles(tiles)
    local skipped = {}
    for i, t in ipairs(tiles) do
        if not goToAndSettle(t.x, t.z) then
            print(string.format("Can't reach (%d,%d), skipping", t.x, t.z))
            skipped[#skipped + 1] = t
        end
        if i % 50 == 0 then
            print(string.format("%d/%d tiles, y=%d, fuel %s", i, #tiles, T.pos.y,
                tostring(turtle.getFuelLevel())))
        end
    end
    return skipped
end

--------------------------------------------------------------------------
local plan = T.serpentine(WIDTH, LENGTH)
print(string.format("Mowing %dx%d (%d tiles). Fuel: %s", WIDTH, LENGTH, #plan,
    tostring(turtle.getFuelLevel())))

while true do
    T.requireFuel(MIN_FUEL)
    T.clearBlocked()
    T.settle()

    local skipped = mowTiles(plan)
    -- Skipped tiles (e.g. a pocket behind a crevasse) are retried using the
    -- obstacle map built during the pass, until a round makes no progress.
    while #skipped > 0 do
        print("Retrying " .. #skipped .. " skipped tiles")
        local remaining = mowTiles(skipped)
        if #remaining >= #skipped then skipped = remaining; break end
        skipped = remaining
    end
    if #skipped > 0 then
        print("Gave up on " .. #skipped .. " tiles:")
        for _, t in ipairs(skipped) do io.write(string.format("(%d,%d) ", t.x, t.z)) end
        print()
    end

    if not goToAndSettle(0, 0) then
        print("Couldn't get home; at " .. T.posString())
    end
    T.face(0)
    T.dumpDown()
    print("Pass complete. Fuel left: " .. tostring(turtle.getFuelLevel()))

    if not REPEAT then break end
    print("Sleeping " .. REPEAT .. " min (Ctrl+T to stop)")
    sleep(REPEAT * 60)
end
