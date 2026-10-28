-- sim/mine_tunnel.lua
--
-- `mine` digging tunnels through mixed rock: ore veins running out of the
-- walls, floor and ceiling (part of one beyond the reach the turtle may
-- stray), ore inside the tunnel, a tag-only modded ore, lava in a wall and
-- inside the tunnel, gravel that falls in from above.  Checks the tunnel
-- is clear, every ore in reach is mined and none beyond it, no lava
-- touches open space, valuables end up at the start and bulk in the
-- homes, and it never moves on an empty tank.  Then homes along a longer
-- tunnel (supplies carried forward, valuables collected on the way
-- back), lit by torches in wall niches with no floor block dark enough
-- for mobs (one niche opening into a cave gets a block to stand its torch
-- on); --no-lights; a Geo Scanner (lined up with the tunnel from the scan,
-- fetching ore further out, far fewer turns, coal first when low on
-- fuel); a crevasse across the tunnel, which it bridges so a player can
-- walk the floor; a tunnel with no length that runs out of chests, then
-- `mine --resume` once more chests are added (twice: the second time a
-- home holds more valuables than fit, and the most valuable come back),
-- `mine haul` bringing the rest back, `mine reset` to the last home and
-- `--resume` from there; bedrock; running short of fuel; `mine reset` from inside a vein; and a
-- tunnel to the left and down.
local PROJ = ...
package.path = PROJ .. "/?.lua;" .. package.path

--------------------------------------------------------------------------
-- World: W[key] = block, false = air; unset = the default rock
--------------------------------------------------------------------------
local W = {}
local function T_ONE(name) return name:find("_pickaxe$") or name:find("_hoe$") or name:find("_axe$") or name:find("_shovel$") or name:find("_sword$") or name:find("bucket$") end
local function k(x, y, z) return x .. "," .. y .. "," .. z end
local ROCK = { "minecraft:stone", "minecraft:stone", "minecraft:deepslate", "minecraft:andesite",
               "minecraft:diorite", "minecraft:granite", "minecraft:tuff" }
local function get(x, y, z)
    local b = W[k(x, y, z)]
    if b ~= nil then return b or nil end
    if z < 1 then return nil end                    -- open space behind the tunnel face
    return { name = ROCK[(x * 31 + y * 17 + z * 13) % #ROCK + 1] }
end
local function set(x, y, z, b) W[k(x, y, z)] = b or false end
local function chest(items) return { name = "minecraft:chest", inv = items or {} } end

local ORE_TAGS = { ["c:ores"] = true }
local function ore(name) return { name = name } end
local DROP = {
    ["minecraft:stone"] = "minecraft:cobblestone", ["minecraft:deepslate"] = "minecraft:cobbled_deepslate",
    ["minecraft:iron_ore"] = "minecraft:raw_iron", ["minecraft:diamond_ore"] = "minecraft:diamond",
    ["minecraft:coal_ore"] = "minecraft:coal", ["minecraft:deepslate_gold_ore"] = "minecraft:raw_gold",
    ["minecraft:emerald_ore"] = "minecraft:emerald", ["modded:tin_vein"] = "modded:raw_tin",
}
local FALLS = { ["minecraft:gravel"] = true, ["minecraft:sand"] = true }

-- The start (chests above and below), with the top one stocked.
local function setup(stock)
    for key in pairs(W) do W[key] = nil end
    set(0, 1, 0, chest(stock))                      -- valuables and supplies
    set(0, -1, 0, chest())                          -- bulk
end
-- Ore, lava and gravel for the first tunnel (3x3, x 0..2, y 0..2).
local function features()
    -- vein A: iron out of the left wall at y=1, z=4, running to x=-5
    -- (x=-5 is 5 out: beyond the reach of 4, must stay)
    for x = -1, -5, -1 do set(x, 1, 4, ore("minecraft:iron_ore")) end
    set(-2, 2, 4, ore("minecraft:iron_ore"))
    -- vein B: diamond in the ceiling, going up
    set(1, 3, 8, ore("minecraft:diamond_ore")); set(1, 4, 8, ore("minecraft:diamond_ore"))
    -- coal inside the tunnel (middle column, middle row), on its own
    set(1, 1, 6, ore("minecraft:coal_ore"))
    -- gold in the floor, two deep
    set(2, -1, 10, ore("minecraft:deepslate_gold_ore")); set(2, -2, 10, ore("minecraft:deepslate_gold_ore"))
    -- a modded ore known only by its tag, in the far end's face
    set(0, 0, 13, { name = "modded:tin_vein", tags = ORE_TAGS })
    -- lava: a source in the right wall, and one inside the tunnel
    set(3, 0, 3, { name = "minecraft:lava", level = 0 })
    set(1, 2, 9, { name = "minecraft:lava", level = 0 })
    -- gravel in the tunnel with more above the ceiling, which falls in
    for y = 1, 5 do set(2, y, 7, { name = "minecraft:gravel" }) end
end
local ORES = {}            -- where ore was, for checking
local function isOreBlock(b)
    return b and (b.name:find("_ore$") or (b.tags and b.tags["c:ores"])) and true or false
end
local function remember()
    ORES = {}
    for key, b in pairs(W) do
        if b and isOreBlock(b) then
            local x, y, z = key:match("(-?%d+),(-?%d+),(-?%d+)")
            ORES[#ORES + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
        end
    end
end

--------------------------------------------------------------------------
-- Turtle
--------------------------------------------------------------------------
local P = { x = 0, y = 0, z = 0, d = 0 }
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }
local moves, turns = 0, 0
local inv, sel = {}, 1
FUEL, LOWEST, DRY = 0, 0, 0
local FUEL_VALUE = { ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80 }
local SIZE = 27

-- As CC:Tweaked stores what a turtle picks up: into the first slot,
-- counting on from the selected one, that is empty or holds the same item
-- (so an empty slot ahead of a part stack starts a second stack).
-- SPLIT counts the pickups that started a new stack though a part stack
-- of the item was there to join.
local function addItem(name, n)
    local part = false
    for s = 1, 16 do if inv[s] and inv[s].name == name and inv[s].count < 64 then part = true end end
    for i = 0, 15 do
        local s = (sel - 1 + i) % 16 + 1
        local it = inv[s]
        if not it then
            if part then SPLIT = (SPLIT or 0) + 1 end
            inv[s] = { name = name, count = math.min(n, 64) }; n = n - inv[s].count
        elseif it.name == name and it.count < 64 then
            local take = math.min(n, 64 - it.count); it.count = it.count + take; n = n - take
        end
        if n == 0 then break end
    end
    if n == 0 then return true end
    SPILLED = (SPILLED or 0) + n
    return false
end
local function passable(b) return b == nil or b.name == "minecraft:lava" or b.name == "minecraft:water" end
local function inspectAt(x, y, z)
    local b = get(x, y, z)
    if not b then return false, "No block to inspect" end
    local tags = {}
    if b.tags then for t in pairs(b.tags) do tags[t] = true end end
    if b.name:find("_ore$") then tags["c:ores"] = true end
    return true, { name = b.name, state = { level = b.level, waterlogged = b.waterlogged }, tags = tags }
end
-- gravel and sand above (x,y,z) fall into it once it's empty
local function gravity(x, y, z)
    while not get(x, y, z) do
        local above = get(x, y + 1, z)
        if not (above and FALLS[above.name]) then return end
        set(x, y, z, above); set(x, y + 1, z, nil); y = y + 1
    end
end
-- Water, roughly as Minecraft runs it: an open block (not the turtle's)
-- beside or under water fills: a source if two sources sit beside it on
-- something solid or a source, falling water under water, flowing water
-- beside water that isn't spent; flowing water nothing feeds drains away.
-- It takes time: water reacts to a change next to it 5 ticks on, and
-- each turtle move, turn, dig or place takes 8.  A turtle moving into flowing water pushes it out;
-- one moving into a source is waterlogged and leaves the source behind
-- when it moves on.  Torches the water reaches are washed away.
local WATER_NAME = "minecraft:water"
local function isWater(b) return b and b.name == WATER_NAME end
-- Water a block holds, as a level: 0 for a source (a waterlogged block is
-- one), nil for none.
local function wlevel(b)
    if not b then return nil end
    if b.waterlogged then return 0 end
    if b.name == WATER_NAME then return b.level end
end
local function waterFor(x, y, z)
    local sources, feed = 0, nil
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local b = get(x + d[1], y, z + d[2])
        local lv = wlevel(b)
        if lv then
            if lv == 0 then sources = sources + 1 end
            local l = lv >= 8 and 0 or lv
            if l < 7 then feed = math.min(feed or 99, l + 1) end
        end
    end
    local below = get(x, y - 1, z)
    if sources >= 2 and below and (below.name ~= WATER_NAME or below.level == 0)
            and below.name ~= "minecraft:lava" then
        return { name = WATER_NAME, level = 0 }
    end
    if wlevel(get(x, y + 1, z)) then return { name = WATER_NAME, level = 8 } end
    if feed then return { name = WATER_NAME, level = feed } end
    return nil
end
local pending = {}         -- key -> { due tick, x, y, z }: water blocks due a tick
local clock = 0            -- ticks
local SIDES6 = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
local function due(a, b, c, t)
    if not wlevel(get(a, b, c)) then return end
    local key = k(a, b, c)
    local q = pending[key]
    if not q or q[1] > t then pending[key] = { t, a, b, c } end
end
-- Something changed at (x,y,z) now: the water there and next to it ticks
-- 5 ticks on.
local function flow(x, y, z)
    due(x, y, z, clock + 5)
    for _, d in ipairs(SIDES6) do due(x + d[1], y + d[2], z + d[3], clock + 5) end
end
-- The open block (not the turtle's) at (a,b,c) gets the water due it.
local function fillAt(a, b, c, t)
    local cur = get(a, b, c)
    local torch = cur and cur.name == "minecraft:torch"
    if c < 1 or (a == P.x and b == P.y and c == P.z) or not (cur == nil or torch) then return end
    local new = waterFor(a, b, c)
    if not new then return end
    if torch then WASHED = (WASHED or 0) + 1 end    -- water washes a torch away
    -- INGRESS: water getting into the tunnel (BOX) where it's open, past
    -- the block just dug (which the turtle moves into, pushing it out)
    if BOX and a >= BOX[1] and a <= BOX[2] and b >= BOX[3] and b <= BOX[4]
            and k(a, b, c) ~= LAST_DUG then
        INGRESS = (INGRESS or 0) + 1
    end
    set(a, b, c, new)
    due(a, b, c, t + 5)
end
-- Let `ticks` pass (a turtle action's 8 by default).  A water block that
-- ticks drains if nothing feeds it (or changes level), and spreads into the
-- open blocks next to it, which tick 5 ticks later.
local function waterStep(ticks)
    clock = clock + (ticks or 8)
    for _ = 1, 100000 do
        local first
        for key, q in pairs(pending) do      -- the earliest; ties by place, so runs repeat
            if q[1] <= clock and (not first or q[1] < first[1] or (q[1] == first[1] and key < first[5])) then
                first = q
                q[5] = key
            end
        end
        if not first then return end
        local t, a, b, c = first[1], first[2], first[3], first[4]
        pending[k(a, b, c)] = nil
        local cur = get(a, b, c)
        if wlevel(cur) and not (a == P.x and b == P.y and c == P.z) then
            if wlevel(cur) ~= 0 then
                local new = waterFor(a, b, c)
                if (new and new.level) ~= cur.level then
                    set(a, b, c, new)
                    for _, d in ipairs(SIDES6) do due(a + d[1], b + d[2], c + d[3], t + 5) end
                end
            end
            if wlevel(get(a, b, c)) then
                for _, d in ipairs(SIDES6) do fillAt(a + d[1], b + d[2], c + d[3], t) end
            end
        end
    end
end
-- Let the water settle (at the end of a run).
local function settleWater()
    for _ = 1, 400 do
        if next(pending) == nil then return end
        waterStep(5)
    end
end

local function move(dx, dy, dz)
    if FUEL <= 0 then DRY = DRY + 1; return false end
    local nx, ny, nz = P.x + dx, P.y + dy, P.z + dz
    if not passable(get(nx, ny, nz)) then return false end
    if ONMOVE then ONMOVE(P.x, P.y, P.z, nx, ny, nz) end
    local ox, oy, oz = P.x, P.y, P.z
    P.x, P.y, P.z = nx, ny, nz; moves = moves + 1
    if WATERY then
        local b = get(nx, ny, nz)
        if isWater(b) and b.level ~= 0 then set(nx, ny, nz, nil) end   -- pushed out
        flow(ox, oy, oz)
        waterStep()
    end
    FUEL = FUEL - 1; LOWEST = math.min(LOWEST, FUEL)
    if TRAVELLING then                  -- a trip ends back where it started
        if P.x ~= BACK[1] or P.y ~= BACK[2] or P.z ~= BACK[3] then LEFT_SPOT = true
        elseif LEFT_SPOT then TRAVELLING = false end
    end
    return true
end
local function chestAt(x, y, z)
    local b = get(x, y, z)
    return b and b.inv
end
local function digAt(x, y, z)
    if STOP_AT_DIG and (DIGS or 0) >= STOP_AT_DIG then    -- as if Ctrl+T
        STOP_AT_DIG = nil
        STOPPED_HERE = true
        error("Terminated", 0)
    end
    local b = get(x, y, z)
    if not b or passable(b) or b.inv or b.name == "minecraft:bedrock" then return false end
    set(x, y, z, b.waterlogged and { name = WATER_NAME, level = 0 } or nil)
    LAST_DUG = k(x, y, z)
    if TRAVELLING then TRAVEL_DIGS = (TRAVEL_DIGS or 0) + 1 end
    DIGS = (DIGS or 0) + 1
    if b.name ~= "minecraft:glow_lichen" then addItem(DROP[b.name] or b.name, 1) end   -- (lichen needs shears)
    gravity(x, y, z)
    if WATERY then flow(x, y, z); waterStep() end
    return true
end
local function solid(b) return b and not passable(b) and b.name ~= "minecraft:torch" end
-- `behind`: the block beyond the target, which a torch can hang on.
local function placeAt(x, y, z, behind)
    local it = inv[sel]; if not it then return false end
    if not passable(get(x, y, z)) then return false end
    if it.name == "minecraft:torch" and not (solid(get(x, y - 1, z)) or (behind and solid(get(behind[1], behind[2], behind[3])))) then
        return false
    end
    if it.name:find("raw_") or FUEL_VALUE[it.name] or it.name == "minecraft:diamond"
        or it.name == "minecraft:emerald" then return false end
    if it.name == "minecraft:chest" then set(x, y, z, chest())
    else set(x, y, z, { name = it.name }) end
    it.count = it.count - 1; if it.count == 0 then inv[sel] = nil end
    PLACED = (PLACED or 0) + 1
    if WATERY then flow(x, y, z); waterStep() end
    return true
end
local function dropInto(c, n)
    if not c then error("dropped on the ground") end
    local it = inv[sel]; if not it then return false end
    n = math.min(n or it.count, it.count)
    local left = n
    for s = 1, SIZE do
        local d = c[s]
        if d and d.name == it.name and d.count < 64 then
            local t = math.min(left, 64 - d.count); d.count = d.count + t; left = left - t
        end
    end
    for s = 1, SIZE do
        if left == 0 then break end
        if not c[s] then c[s] = { name = it.name, count = math.min(left, 64) }; left = left - c[s].count end
    end
    local moved = n - left
    it.count = it.count - moved; if it.count == 0 then inv[sel] = nil end
    return moved > 0
end
-- Take up to n from the container's first stack: into the selected slot
-- first, then any slot holding the same item, then empty ones (as CC does).
local function suckFrom(c, n)
    if not c then return false end
    for s = 1, SIZE do
        local d = c[s]
        if d then
            local want = math.min(n or 64, d.count)
            local left = want
            local order = { sel }
            for i = 1, 16 do if i ~= sel then order[#order + 1] = i end end
            for pass = 1, 2 do
                for _, i in ipairs(order) do
                    local it = inv[i]
                    if left > 0 and it and it.name == d.name and it.count < 64 then
                        local t = math.min(left, 64 - it.count); it.count = it.count + t; left = left - t
                    elseif left > 0 and not it and (pass == 2 or i == sel) then
                        inv[i] = { name = d.name, count = math.min(left, 64) }; left = left - inv[i].count
                    end
                end
            end
            local took = want - left
            d.count = d.count - took; if d.count == 0 then c[s] = nil end
            return took > 0
        end
    end
    return false
end
local function front() return P.x + DX[P.d], P.y, P.z + DZ[P.d] end

-- Upgrades on each side; equipping swaps the selected slot with one.
EQ = { right = "minecraft:diamond_pickaxe" }
SCANNER = "advancedperipherals:geo_scanner"
SCAN_TURN = 0
-- (as in game, a freshly equipped scanner may not show up as a
-- peripheral at once: here not until it's been asked for once)
function equip(side)
    local it = inv[sel]
    inv[sel] = EQ[side] and { name = EQ[side], count = 1 } or nil
    EQ[side] = it and it.name
    if EQ[side] == SCANNER then ATTACHING = side end
    return true
end
-- The Geo Scanner: every block that isn't air within the radius (the
-- turtle itself included), at offsets along the WORLD's axes.  The sim's
-- world is turned so the tunnel's +z runs east: world x = the tunnel's
-- z, world z = its x.
SCANS = 0
local function geoScanner()
    return {
        scanBlocks = function(r)                -- `scan` in AP's docs; this on the user's server
            SCANS = SCANS + 1
            local out = {}
            for tx = -r, r do for ty = -r, r do for tz = -r, r do
                local b = (tx == 0 and ty == 0 and tz == 0) and { name = "computercraft:turtle_normal" }
                    or get(P.x + tx, P.y + ty, P.z + tz)
                if b then
                    local tags = {}
                    if b.tags then for t in pairs(b.tags) do tags[#tags + 1] = t end end
                    if b.name:find("_ore$") then tags[#tags + 1] = "c:ores" end
                    -- as AP 0.8.2a gives them: offsets along the world's axes, as
                    -- decimals, and right/up/forward from the turtle's real facing;
                    -- the variant gives world coordinates and no r/u/f
                    if WORLD_COORDS then
                        out[#out + 1] = { x = tz + 1000, y = ty + 1000, z = tx + 1000, name = b.name, tags = tags }
                    else
                        out[#out + 1] = { x = tz + 0.0, y = ty + 0.0, z = tx + 0.0, name = b.name, tags = tags,
                            state = { waterlogged = b.waterlogged, level = b.level },
                            -- SCAN_TURN: a scanner whose idea of forward is turned
                            f = tx * DX[(P.d + SCAN_TURN) % 4] + tz * DZ[(P.d + SCAN_TURN) % 4] + 0.0, u = ty + 0.0,
                            r = tx * DX[(P.d + SCAN_TURN + 1) % 4] + tz * DZ[(P.d + SCAN_TURN + 1) % 4] + 0.0 }
                    end
                end
            end end end
            return out
        end,
        cost = function() return 0 end,
    }
end
local function above() return P.x, P.y + 1, P.z end
local function below() return P.x, P.y - 1, P.z end

-- what watchsim.lua draws: the world and the turtle, and the slices of a
-- mine to show (x and y take in the tunnels and their veins; z runs along
-- them, the view following the turtle)
SIM_WORLD = { W = { get = get }, P = P, moves = function() return moves end,
              view = { x = { -5, 7 }, y = { -5, 7 }, z = { -1, 70 } } }

turtle = {
    forward = function() return move(DX[P.d], 0, DZ[P.d]) end,
    back = function() return move(-DX[P.d], 0, -DZ[P.d]) end,
    up = function() return move(0, 1, 0) end,
    down = function() return move(0, -1, 0) end,
    turnRight = function() P.d = (P.d + 1) % 4; turns = turns + 1; if WATERY then waterStep() end; return true end,
    turnLeft = function() P.d = (P.d + 3) % 4; turns = turns + 1; if WATERY then waterStep() end; return true end,
    inspect = function() return inspectAt(front()) end,
    inspectUp = function() return inspectAt(above()) end,
    inspectDown = function() return inspectAt(below()) end,
    detect = function() return not passable(get(front())) end,
    detectUp = function() return not passable(get(above())) end,
    detectDown = function() return not passable(get(below())) end,
    dig = function() return digAt(front()) end,
    digUp = function() return digAt(above()) end,
    digDown = function() return digAt(below()) end,
    place = function()
        local x, y, z = front()
        return placeAt(x, y, z, { x + DX[P.d], y, z + DZ[P.d] })
    end,
    placeUp = function() return placeAt(above()) end,
    placeDown = function() return placeAt(below()) end,
    attack = function() return false end, attackUp = function() return false end, attackDown = function() return false end,
    select = function(s) sel = s; return true end,
    getSelectedSlot = function() return sel end,
    getItemCount = function(s) return inv[s or sel] and inv[s or sel].count or 0 end,
    getItemDetail = function(s) local it = inv[s or sel]; return it and { name = it.name, count = it.count } end,
    -- as in the game: room left in the stack, and moving items between slots
    getItemSpace = function(s) local it = inv[s or sel]; return it and (T_ONE(it.name) and 1 or 64) - it.count or 64 end,
    transferTo = function(to, n)
        local it, dst = inv[sel], inv[to]
        if not it or to == sel then return false end
        if dst and dst.name ~= it.name then return false end
        local max = (T_ONE(it.name) and 1 or 64)
        local k = math.min(n or it.count, it.count, max - (dst and dst.count or 0))
        if k <= 0 then return false end
        inv[to] = { name = it.name, count = (dst and dst.count or 0) + k }
        it.count = it.count - k
        if it.count == 0 then inv[sel] = nil end
        return true
    end,
    drop = function(n) return dropInto(chestAt(front()), n) end,
    dropUp = function(n) return dropInto(chestAt(above()), n) end,
    dropDown = function(n) return dropInto(chestAt(below()), n) end,
    suck = function(n) return suckFrom(chestAt(front()), n) end,
    suckUp = function(n) return suckFrom(chestAt(above()), n) end,
    suckDown = function(n) return suckFrom(chestAt(below()), n) end,
    refuel = function(n)
        local it = inv[sel]; if not it or not FUEL_VALUE[it.name] then return false end
        n = n or it.count
        for _ = 1, n do
            if not inv[sel] then break end
            FUEL = FUEL + FUEL_VALUE[it.name]
            it.count = it.count - 1; if it.count == 0 then inv[sel] = nil end
        end
        return true
    end,
    getFuelLevel = function() return FUEL end,
    getFuelLimit = function() return 20000 end,
    getEquippedLeft = function() return EQ.left and { name = EQ.left } end,
    getEquippedRight = function() return EQ.right and { name = EQ.right } end,
    equipLeft = function() return equip("left") end,
    equipRight = function() return equip("right") end,
}
peripheral = {
    wrap = function(side)
        if (side == "left" or side == "right") then
            if ATTACHING == side then ATTACHING = nil; return nil end
            return EQ[side] == SCANNER and geoScanner() or nil
        end
        local c
        if side == "front" then c = chestAt(front())
        elseif side == "top" then c = chestAt(above())
        elseif side == "bottom" then c = chestAt(below()) end
        if not c then return nil end
        return {
            size = function() return SIZE end,
            list = function() local t = {}; for s = 1, SIZE do if c[s] then t[s] = { name = c[s].name, count = c[s].count } end end; return t end,
            getItemDetail = function(s) local d = c[s]; return d and { name = d.name, count = d.count, maxCount = 64 } end,
            pushItems = function(to, from, limit, toSlot)
                local d = c[from]; if not d then return 0 end
                local t = c[toSlot]
                if t and t.name ~= d.name then return 0 end
                local n = math.min(limit or 64, d.count, 64 - (t and t.count or 0))
                if t then t.count = t.count + n else c[toSlot] = { name = d.name, count = n } end
                d.count = d.count - n; if d.count == 0 then c[from] = nil end
                return n
            end,
            _side = side,
        }
    end,
    getName = function(p) return p._side end,
    getType = function(side) return (side == "left" or side == "right") and EQ[side] == SCANNER and "geo_scanner" or nil end,
}
-- methods by name, as CC has them: through wrap, as the scanner shows up
peripheral.getMethods = function(side)
    local p = peripheral.wrap(side)
    if not p then return nil end
    local m = {}
    for name, f in pairs(p) do if type(f) == "function" then m[#m + 1] = name end end
    return m
end
peripheral.call = function(side, name, ...)
    local p = peripheral.wrap(side)
    if not (p and p[name]) then error("No such method " .. name, 0) end
    return p[name](...)
end

local files = {}
fs = {
    combine = function(a, b) return (a == "" and b) or (a .. "/" .. b) end,
    getDir = function() return "" end,
    exists = function(p) return files[p] ~= nil end,
    delete = function(p) files[p] = nil end,
    open = function(p, mode)
        if mode == "w" then
            local buf = {}
            return { write = function(s) buf[#buf + 1] = s end,
                     writeLine = function(s) buf[#buf + 1] = s .. "\n" end,
                     close = function() files[p] = table.concat(buf) end }
        end
        local data = files[p]; if not data then return nil end
        return { readAll = function() return data end, readLine = function() return nil end, close = function() end }
    end,
}
shell = { getRunningProgram = function() return "mine.lua" end }
sleep = function() end
os.startTimer = function() return 1 end
os.pullEvent = function() error("waited for an event: the turtle should never wait here") end

local log = {}
local realPrint = print
print = function(...)
    local t = {}; for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
    local line = table.concat(t, " ")
    local bx, by, bz = line:match("at %((-?%d+),(-?%d+),(-?%d+)%): back to home")
    if bx then TRAVELLING, LEFT_SPOT, BACK = true, false, { tonumber(bx), tonumber(by), tonumber(bz) } end
    log[#log + 1] = line
end

local function run(...)
    log, moves, turns, SPLIT, DIGS = {}, 0, 0, 0, 0
    package.loaded.turtlelib = nil
    local chunk = assert(loadfile(PROJ .. "/mine.lua"))
    local ok, err = pcall(chunk, ...)
    if WATERY then settleWater() end
    realPrint("== mine " .. table.concat({ ... }, " ") .. "  (moves: " .. moves .. ", turns: " .. turns .. ", digs: " .. DIGS .. ", split stacks: " .. SPLIT .. ")")
    for _, l in ipairs(log) do
        if not l:find("^Segment ") then realPrint("   " .. l) end
    end
    if not ok and STOPPED_HERE and err == "Terminated" then realPrint("   (stopped, as if by Ctrl+T)")
    elseif not ok then realPrint("   ERROR: " .. tostring(err)) end
    STOPPED_HERE = nil
    realPrint(string.format("   ends at (%d,%d,%d) facing %d", P.x, P.y, P.z, P.d))
end
local function logHas(pat)
    for _, l in ipairs(log) do if l:find(pat) then return true end end
    return false
end

local function check(label, ok, detail)
    realPrint(string.format("   %s %s%s", ok and "ok   " or "ERROR:", label, detail and ("  (" .. detail .. ")") or ""))
end

local function contents(c)
    local n, order = {}, {}
    for s = 1, SIZE do
        local d = c and c[s]
        if d then
            if not n[d.name] then n[d.name] = 0; order[#order + 1] = d.name end
            n[d.name] = n[d.name] + d.count
        end
    end
    table.sort(order)
    local parts = {}
    for _, name in ipairs(order) do parts[#parts + 1] = n[name] .. " " .. name:gsub("^%a+:", "") end
    return table.concat(parts, ", "), n
end
local BULKY = { cobblestone = true, cobbled_deepslate = true, andesite = true, diorite = true,
                granite = true, tuff = true, gravel = true }
local SUPPLY = { chest = true, coal = true, torch = true }

local function startAt() P.x, P.y, P.z, P.d = 0, 0, 0, 0 end
local function atStart() return P.x == 0 and P.y == 0 and P.z == 0 and P.d == 0 end
local function stock(chests, coal, torches)
    local t = {}
    if torches then t[#t + 1] = { name = "minecraft:torch", count = torches } end
    for _ = 1, math.floor(chests / 64) do t[#t + 1] = { name = "minecraft:chest", count = 64 } end
    if chests % 64 > 0 then t[#t + 1] = { name = "minecraft:chest", count = chests % 64 } end
    while coal > 0 do t[#t + 1] = { name = "minecraft:coal", count = math.min(64, coal) }; coal = coal - 64 end
    return t
end

-- How many blocks are left in the tunnel x0..x1, y0..y1, z1..z2.
local function leftIn(x0, x1, y0, y1, z1, z2)
    local n = 0
    for x = x0, x1 do for y = y0, y1 do for z = z1, z2 do
        if get(x, y, z) then n = n + 1 end
    end end end
    return n
end

-- Holes in the floor y = fy under x0..x1, z1..z2: blocks a player can't
-- stand on (air, fluid).
local function floorHoles(x0, x1, fy, z1, z2)
    local holes = {}
    for x = x0, x1 do for z = z1, z2 do
        local b = get(x, fy, z)
        if not b or passable(b) then holes[#holes + 1] = k(x, fy, z) end
    end end
    return holes
end
local function checkFloor(x0, x1, fy, z1, z2)
    local holes = floorHoles(x0, x1, fy, z1, z2)
    check("floor solid all along", #holes == 0, #holes .. " holes" .. (#holes > 0 and (": " .. table.concat(holes, " ", 1, math.min(#holes, 6))) or ""))
end

-- Block light on the tunnel's floor-level blocks x0..x1, y = fy + 1,
-- z1..z2: flood from every torch through open space (14 at the torch, one
-- less each block).  Mobs spawn at 0; the darkest is reported.
local function checkLight(x0, x1, fy, z1, z2)
    local light, queue, head = {}, {}, 1
    for key, b in pairs(W) do
        if b and b.name == "minecraft:torch" then
            light[key] = 14
            local x, y, z = key:match("(-?%d+),(-?%d+),(-?%d+)")
            queue[#queue + 1] = { tonumber(x), tonumber(y), tonumber(z) }
        end
    end
    while queue[head] do
        local c = queue[head]; head = head + 1
        local l = light[k(c[1], c[2], c[3])]
        if l > 1 then
            for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
                local x, y, z = c[1] + d[1], c[2] + d[2], c[3] + d[3]
                local key = k(x, y, z)
                if not get(x, y, z) and (light[key] or 0) < l - 1 then
                    light[key] = l - 1
                    queue[#queue + 1] = { x, y, z }
                end
            end
        end
    end
    local darkest, where = 99, ""
    for x = x0, x1 do for z = z1, z2 do
        local l = light[k(x, fy + 1, z)] or 0
        if l < darkest then darkest, where = l, k(x, fy + 1, z) end
    end end
    check("no floor block dark enough for mobs", darkest >= 1, "darkest " .. darkest .. " at " .. where)
    return darkest
end

local function checkOres()
    local mined, kept, wrong = 0, 0, {}
    for _, o in ipairs(ORES) do
        local reach = math.max(-o.x, o.x - 2, 0) <= 4 and math.max(-o.y, o.y - 2, 0) <= 4
        local gone = not isOreBlock(get(o.x, o.y, o.z))
        if reach and gone then mined = mined + 1
        elseif not reach and not gone then kept = kept + 1
        else wrong[#wrong + 1] = k(o.x, o.y, o.z) .. (gone and " mined" or " left") end
    end
    check("ore in reach mined, beyond reach left", #wrong == 0,
        mined .. " mined, " .. kept .. " left beyond reach" .. (#wrong > 0 and ("; wrong: " .. table.concat(wrong, " ")) or ""))
end

local function checkLava(L)
    local hot = 0
    for x = -6, 8 do for y = -6, 8 do for z = 1, L + 5 do
        local b = get(x, y, z)
        if b and b.name == "minecraft:lava" then
            for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
                if not get(x + d[1], y + d[2], z + d[3]) then hot = hot + 1 end
            end
        end
    end end end
    check("no lava touching open space", hot == 0, hot .. " open faces")
end

-- The start chests: valuables on top (and supplies), bulk below.
local function checkStart()
    local top, tn = contents(chestAt(0, 1, 0))
    local bottom, bn = contents(chestAt(0, -1, 0))
    realPrint("   start top:    " .. top)
    realPrint("   start bottom: " .. bottom)
    local misplaced = {}
    for name in pairs(tn) do if BULKY[name:gsub("^%a+:", "")] then misplaced[#misplaced + 1] = name .. " on top" end end
    for name in pairs(bn) do if not BULKY[name:gsub("^%a+:", "")] then misplaced[#misplaced + 1] = name .. " below" end end
    check("valuables on top, bulk below at the start", #misplaced == 0, table.concat(misplaced, ", "))
    return tn
end

-- Homes every `sp` blocks, for a tunnel up and right: a wall chest at
-- x=-1 and a floor chest at y=-1.  Supplies only in the last home, no
-- valuables left in any, only bulk in the floor chests.
local function checkHomes(sp, count)
    local bad = {}
    for h = 1, count do
        local z = h * sp
        local wall, floor = chestAt(-1, 0, z), chestAt(0, -1, z)
        if not (wall and floor) then bad[#bad + 1] = "home " .. h .. " missing a chest"
        else
            local _, wn = contents(wall)
            for name in pairs(wn) do
                local short = name:gsub("^%a+:", "")
                if h < count and SUPPLY[short] then bad[#bad + 1] = short .. " left in home " .. h end
                if not SUPPLY[short] then bad[#bad + 1] = short .. " not brought back from home " .. h end
            end
            local _, fn = contents(floor)
            for name in pairs(fn) do
                if not BULKY[name:gsub("^%a+:", "")] then bad[#bad + 1] = name .. " in home " .. h .. "'s bulk chest" end
            end
        end
    end
    if chestAt(-1, 0, (count + 1) * sp) then bad[#bad + 1] = "a home past the last one" end
    check(count .. " homes, supplies only in the last, valuables brought back", #bad == 0, table.concat(bad, "; "))
    if count > 0 then realPrint("   last home: " .. (contents(chestAt(-1, 0, count * sp)))) end
end

local function jobState() return (files["mine.job"] or ""):match("(%a+)$") end

-- 1. a 12x3x3 tunnel, no homes (12 is under the spacing)
setup(stock(4, 64)); features(); remember()
startAt(); inv, files = {}, {}
FUEL, LOWEST, DRY, SPILLED = 1000, 1000, 0, 0
run("3", "3", "12")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 12) == 0, leftIn(0, 2, 0, 2, 1, 12) .. " blocks left")
checkOres(); checkLava(12); checkStart()
checkFloor(0, 2, -1, 1, 12)                         -- the gold ore was in it, at (2,-1,10)
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
check("nothing spilled", (SPILLED or 0) == 0, tostring(SPILLED or 0))
check("job done", jobState() == "done", tostring(jobState()))

-- 2. 50 long with homes every 16: supplies go forward, valuables come back
setup(stock(8, 128, 64)); features()
set(-1, 1, 20, ore("minecraft:diamond_ore"))       -- in the wall near home 1
set(3, 0, 40, ore("minecraft:emerald_ore"))        -- in the wall near home 2
set(-2, 0, 10, nil); set(-1, -1, 10, nil)          -- a cave behind and under the niche at z=10
remember()
startAt(); inv, files = {}, {}
FUEL, LOWEST, DRY, SPILLED, TRAVEL_DIGS = 200, 200, 0, 0, 0
run("3", "3", "50", "--spacing", "16")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 50) == 0, leftIn(0, 2, 0, 2, 1, 50) .. " blocks left")
check("what it picked up joined its stack (it keeps its slots tidy)", SPLIT <= 2,
    SPLIT .. " pickups started a second part stack")
checkOres(); checkLava(50); checkFloor(0, 2, -1, 1, 50)
local tn = checkStart()
check("diamonds and emerald brought back", (tn["minecraft:diamond"] or 0) == 3 and (tn["minecraft:emerald"] or 0) == 1,
    (tn["minecraft:diamond"] or 0) .. " diamond, " .. (tn["minecraft:emerald"] or 0) .. " emerald")
checkHomes(16, 3)
checkLight(0, 2, -1, 1, 50)
local niches = {}
for z = 1, 50 do
    local b = get(-1, 0, z)
    if b and b.name == "minecraft:torch" then niches[#niches + 1] = z end
end
check("torches in wall niches every 19, none on a home", table.concat(niches, ",") == "10,29,49",
    "at z=" .. table.concat(niches, ","))
check("the niche over the cave got a block to stand the torch on", get(-1, -1, 10) ~= nil,
    tostring((get(-1, -1, 10) or {}).name))
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
check("nothing spilled", (SPILLED or 0) == 0, tostring(SPILLED or 0))
check("dug nothing on trips home and back", (TRAVEL_DIGS or 0) == 0, tostring(TRAVEL_DIGS or 0) .. " blocks")
check("job done", jobState() == "done", tostring(jobState()))

-- 3. no length, homes every 8, 5 chests: two homes, then out of chests
setup(stock(5, 64))
startAt(); inv, files = {}, {}
FUEL, LOWEST, DRY, SPILLED = 100, 100, 0, 0
run("2", "2", "--spacing", "8")
check("stopped: out of chests", logHas("Out of chests"))
check("tunnel dug to z=24", leftIn(0, 1, 0, 1, 1, 24) == 0 and get(0, 0, 25) ~= nil, leftIn(0, 1, 0, 1, 1, 24) .. " blocks left")
checkHomes(8, 2)
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
check("job can be resumed", jobState() == "active", tostring(jobState()))

-- 4. four more chests in the start chest: `mine --resume` takes them out
--    to home 2 and carries on, two more homes
for _, it in ipairs(stock(4, 0)) do table.insert(chestAt(0, 1, 0), it) end
startAt()
run("--resume")
check("resumed from home 2", logHas("Back at home 2"))
check("stopped: out of chests again", logHas("Out of chests"))
check("tunnel dug to z=40", leftIn(0, 1, 0, 1, 1, 40) == 0, leftIn(0, 1, 0, 1, 1, 40) .. " blocks left")
checkHomes(8, 4)
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)

-- 4b. home 1 holds more than the turtle can carry: 10 stacks of string,
--     6 of raw iron and 2 of diamonds.  With two more chests it builds one
--     more home, then on the way back brings the diamonds and the iron and
--     as much string as fits, and says what it left
local h1 = chestAt(-1, 0, 8)
for i = 1, 10 do table.insert(h1, { name = "minecraft:string", count = 64 }) end
for i = 1, 6 do table.insert(h1, { name = "minecraft:raw_iron", count = 64 }) end
for i = 1, 2 do table.insert(h1, { name = "minecraft:diamond", count = 64 }) end
for _, it in ipairs(stock(2, 0)) do table.insert(chestAt(0, 1, 0), it) end
startAt()
run("--resume")
local _, got = contents(chestAt(0, 1, 0))
check("brought back every diamond and all the iron", (got["minecraft:diamond"] or 0) == 128 and (got["minecraft:raw_iron"] or 0) == 384,
    (got["minecraft:diamond"] or 0) .. " diamond, " .. (got["minecraft:raw_iron"] or 0) .. " raw iron, "
    .. (got["minecraft:string"] or 0) .. " string")
check("said what it left in home 1", logHas("No room to bring back %d+ items from home 1"))
check("back at the start", atStart())

-- 4c. `mine haul`: out to the last home (5) and back collecting, as many
--     trips as it takes, until home 1's string is all at the start
FUEL = 500
run("haul")
local _, got2 = contents(chestAt(0, 1, 0))
local _, h1left = contents(chestAt(-1, 0, 8))
check("hauled the rest of home 1's string back", (got2["minecraft:string"] or 0) == 640 and not h1left["minecraft:string"],
    (got2["minecraft:string"] or 0) .. " string at the start")
check("said everything's at the start", logHas("All the valuables are at the start"))
check("left the supplies in the last home", (select(2, contents(chestAt(-1, 0, 40)))["minecraft:coal"] or 0) > 0)
check("back at the start", atStart())

-- 4d. stopped between homes 4 and 5: `mine reset` goes on to home 5 (the
--     last), and `mine --resume` carries on from there, not the start
P.x, P.y, P.z, P.d = 1, 1, 36, 0
files[".turtlepos"] = "1 1 36 0 flat"
run("reset")
check("reset to home 5 (z=40), facing its wall", P.x == 0 and P.y == 0 and P.z == 40 and P.d == 3)
for _, it in ipairs(stock(2, 0)) do table.insert(chestAt(-1, 0, 40), it) end   -- two more chests, out there
run("--resume")
check("resumed from home 5, not the start", not logHas("Back at home") and logHas("Built home 6"))
check("tunnel dug to z=48", leftIn(0, 1, 0, 1, 1, 48) == 0, leftIn(0, 1, 0, 1, 1, 48) .. " blocks left")
check("back at the start", atStart())

-- 5. bedrock across the tunnel at z=13: stops there and comes back
setup(stock(10, 64))
for x = 0, 1 do for y = 0, 1 do set(x, y, 13, { name = "minecraft:bedrock" }) end end
startAt(); inv, files = {}, {}
FUEL, DRY = 100, 0
run("2", "2", "--spacing", "8", "--new")
check("stopped at the bedrock", logHas("Can't get through at %(%d,%d,12%) %(minecraft:bedrock%)"))
check("back at the start", atStart())

-- 6. only a little fuel: stops while it can still get back
setup(stock(10, 6))
startAt(); inv, files = {}, {}
FUEL, LOWEST, DRY = 0, math.huge, 0                -- empty: all it has is 6 coal
run("3", "3", "--spacing", "16")
check("stopped: not enough fuel", logHas("Not enough fuel"))
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
check("got back with its margin of 30 left", LOWEST >= 30, "lowest after a move " .. LOWEST)

-- 6b. a crevasse 11 blocks across cuts through the tunnel, 20 deep and
--     open above: the turtle bridges it with bulk so a player can walk
--     across, and a cave pocket under the floor further on is filled too
setup(stock(6, 64))
for x = -6, 8 do for y = -20, 10 do for z = 20, 30 do set(x, y, z, nil) end end end
for x = 0, 2 do set(x, -1, 34, nil); set(x, -2, 34, nil) end
startAt(); inv, files = {}, {}
FUEL, DRY = 1000, 0
run("3", "3", "36", "--spacing", "16")
checkFloor(0, 2, -1, 1, 36)
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)

-- 7. stopped inside a vein (a server restart): `mine reset` digs back to
--    the tunnel and goes home
files["mine.job"] = "3 3 12 64 0 active"
P.x, P.y, P.z, P.d = -3, 1, 4, 3
files[".turtlepos"] = "-3 1 4 3 flat"
FUEL = 500
run("reset")
check("reset from a vein got home", atStart())

-- 8. a tunnel to the left and down: `mine -2 -2 6`
setup(stock(4, 64, 8)); features()
startAt(); inv, files = {}, {}
FUEL, DRY = 1000, 0
run("-2", "-2", "6")
checkLight(-1, 0, -2, 1, 6)
check("left-and-down tunnel clear", leftIn(-1, 0, -1, 0, 1, 6) == 0, leftIn(-1, 0, -1, 0, 1, 6) .. " blocks left")
checkFloor(-1, 0, -2, 1, 6)
check("nothing dug right of or above it", get(1, 0, 3) ~= nil and get(0, 1, 3) ~= nil)
check("back at the start", atStart())

-- 9. a tunnel 10 wide is too wide to light from one wall: torches on both
setup(stock(4, 64, 16))
startAt(); inv, files = {}, {}
FUEL, DRY = 2000, 0
run("10", "2", "30")
checkLight(0, 9, -1, 1, 30)
local left, right = 0, 0
for z = 1, 30 do
    if (get(-1, 0, z) or {}).name == "minecraft:torch" then left = left + 1 end
    if (get(10, 0, z) or {}).name == "minecraft:torch" then right = right + 1 end
end
check("torches on both walls", left > 0 and left == right, left .. " left, " .. right .. " right")
check("back at the start", atStart())

-- 10. --no-lights: torches in the chest, but it leaves them there and
--     says nothing about lighting
setup(stock(4, 64, 16))
startAt(); inv, files = {}, {}
FUEL, DRY = 1000, 0
run("3", "3", "20", "--no-lights")
local placed = 0
for x = -2, 4 do for z = 1, 20 do
    if (get(x, 0, z) or {}).name == "minecraft:torch" then placed = placed + 1 end
end end
local _, top = contents(chestAt(0, 1, 0))
check("no torches placed, all 16 still in the chest", placed == 0 and (top["minecraft:torch"] or 0) == 16,
    placed .. " placed, " .. (top["minecraft:torch"] or 0) .. " in the chest")
check("nothing said about lighting", not logHas("torch"))
check("back at the start", atStart())

-- 11. a Geo Scanner in the start chest (and a chunk controller on the
--     other side): the turtle swaps it in to scan, lines the scan up with
--     the tunnel, and fetches ore that doesn't touch the walls, up to 6
--     out, diamonds as far as a scan reaches and their veins on from
--     there however far they go; it turns
--     far less than the same tunnel without one
local function scanWorld(withScanner)
    local st = stock(4, 64)
    if withScanner then st[#st + 1] = { name = SCANNER, count = 1 } end
    setup(st)
    set(-1, 1, 5, ore("minecraft:iron_ore"))                   -- touching the left wall
    set(-5, 1, 12, ore("minecraft:deepslate_gold_ore")); set(-5, 2, 12, ore("minecraft:deepslate_gold_ore"))
    set(7, 0, 20, ore("minecraft:coal_ore")); set(8, 0, 20, ore("minecraft:coal_ore"))
    set(-9, 1, 25, ore("minecraft:diamond_ore"))               -- 9 out: no scan reaches it
    set(-8, 1, 22, ore("minecraft:deepslate_diamond_ore"))     -- 8 out: the edge of a scan
    set(-9, 1, 22, ore("minecraft:deepslate_diamond_ore"))     -- its vein goes on past the scan
    set(-10, 1, 22, ore("minecraft:deepslate_diamond_ore"))
    set(-10, 2, 22, ore("minecraft:deepslate_diamond_ore"))
    set(-8, 1, 8, ore("minecraft:deepslate_gold_ore"))         -- 8 out, not diamond: too far
    set(3, 1, 15, { name = "minecraft:lava", level = 0 })       -- in the right wall
    set(-1, 0, 18, nil); set(-2, 0, 18, nil)                    -- a cave opening in the left wall
    startAt(); inv, files = {}, {}
    EQ = { left = "advancedperipherals:chunk_controller", right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, SCANS = 2000, 0, 0
    run("3", "3", "30")
    return turns
end
local without = scanWorld(false)
WORLD_COORDS = true                     -- a scanner that gives world coordinates
scanWorld(true)
check("made sense of a scan in world coordinates, with no r/u/f (lined up from what's dug)",
    logHas("lined up") and not logHas("Geo scanner:"))
WORLD_COORDS = false
local withIt = scanWorld(true)
local function oreGone(x, y, z) return not isOreBlock(get(x, y, z)) end
check("lined the scan up with the tunnel", logHas("lined up"), SCANS .. " scans")
check("waited for the scanner to show up after equipping it", not logHas("Geo scanner:"))
check("iron touching the wall mined", oreGone(-1, 1, 5))
check("gold 5 out and coal 5-6 out fetched", oreGone(-5, 1, 12) and oreGone(-5, 2, 12) and oreGone(7, 0, 20) and oreGone(8, 0, 20))
check("diamond 9 out left", not oreGone(-9, 1, 25))
check("diamond 8 out (in the scan) mined, and its vein followed on past the scan",
    oreGone(-8, 1, 22) and oreGone(-9, 1, 22) and oreGone(-10, 1, 22) and oreGone(-10, 2, 22))
check("gold 8 out left (only diamonds go past 6)", not oreGone(-8, 1, 8))
checkLava(30)
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 30) == 0, leftIn(0, 2, 0, 2, 1, 30) .. " blocks left")
checkFloor(0, 2, -1, 1, 30)
check("far fewer turns with the scanner", withIt < without * 0.6, withIt .. " turns, " .. without .. " without")
check("chunk controller still on, pickaxe back", EQ.left == "advancedperipherals:chunk_controller" and EQ.right == "minecraft:diamond_pickaxe")
local _, top = contents(chestAt(0, 1, 0))
check("scanner back in the start chest", (top[SCANNER] or 0) == 1)
check("back at the start", atStart())

-- 11c. a field of small deposits off the left wall, all in one scan:
--      it goes from one to the next where that's shorter than going back
--      to the tunnel in between, and picked-up items join their stacks
setup({ { name = SCANNER, count = 1 }, { name = "minecraft:chest", count = 4 }, { name = "minecraft:coal", count = 64 } })
local FIELD = { { -4, 1, 6 }, { -5, 1, 8 }, { -4, 0, 10 }, { -6, 2, 11 }, { -5, 1, 13 }, { -3, 2, 14 }, { -6, 0, 15 } }
for _, o in ipairs(FIELD) do set(o[1], o[2], o[3], ore("minecraft:iron_ore")) end
startAt(); inv, files = {}, {}
EQ = { right = "minecraft:diamond_pickaxe" }
FUEL, DRY, SCANS = 2000, 0, 0
local entries = 0
ONMOVE = function(x, y, z, nx, ny, nz)
    if x < 0 and nx >= 0 and nz >= 1 then entries = entries + 1 end
end
run("3", "3", "16")
ONMOVE = nil
local all = true
for _, o in ipairs(FIELD) do all = all and oreGone(o[1], o[2], o[3]) end
check("mined every deposit in the field", all)
check("went back into the tunnel from the field at most twice", entries <= 2, entries .. " times")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 16) == 0, leftIn(0, 2, 0, 2, 1, 16) .. " blocks left")
checkFloor(0, 2, -1, 1, 16)
check("back at the start", atStart())

-- 11d. water: the tunnel runs through an underground lake (its own
--      blocks water sources, with more round them) and then under a lake
--      above its ceiling.  Water flows back into what it digs, so it
--      fills the sources and seals what feeds them, and leaves a dry
--      tunnel that no water gets into, without going round in circles.
--      With a scanner, the water in what it dug doesn't make it think its
--      heading is off; with a little fuel in the tank and coal in the
--      chest, the coal it carries keeps it from going home to refuel
setup(stock(4, 64))
table.insert(chestAt(0, 1, 0), { name = SCANNER, count = 1 })
for x = -3, 5 do for y = -2, 4 do for z = 8, 13 do set(x, y, z, { name = "minecraft:water", level = 0 }) end end end
for x = -2, 4 do for y = 3, 5 do for z = 18, 23 do set(x, y, z, { name = "minecraft:water", level = 0 }) end end end
for x = -3, 5 do for z = 7, 24 do set(x, 6, z, { name = "minecraft:stone" }) end end
for _, it in ipairs({ { name = "minecraft:cobblestone", count = 64 }, { name = "minecraft:cobblestone", count = 64 } }) do
    table.insert(chestAt(0, -1, 0), it)                 -- bulk to seal with
end
startAt(); inv, files = {}, {}
EQ = { right = "minecraft:diamond_pickaxe" }
FUEL, DRY, PLACED, SCANS = 300, 0, 0, 0
WATERY = true
run("3", "3", "30")
WATERY = false
check("scanned, and never thought its heading was off", SCANS > 0 and not logHas("heading looks off"), SCANS .. " scans")
check("no trips home to refuel (it carries coal)", not logHas("Low on fuel"))
local wetIn, wetOpen = 0, 0
for x = -4, 6 do for y = -3, 6 do for z = 1, 31 do
    local b = get(x, y, z)
    if isWater(b) then
        if x >= 0 and x <= 2 and y >= 0 and y <= 2 then wetIn = wetIn + 1 end
        for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
            if not get(x + d[1], y + d[2], z + d[3]) then wetOpen = wetOpen + 1 end
        end
    end
end end end
check("no water left in the tunnel", wetIn == 0, wetIn .. " blocks")
check("no water touching open space (sealed off)", wetOpen == 0, wetOpen .. " open faces")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 30) == 0, leftIn(0, 2, 0, 2, 1, 30) .. " blocks left")
checkFloor(0, 2, -1, 1, 30)
check("didn't go round in circles placing blocks", PLACED < 400, PLACED .. " blocks placed")
check("finished", logHas("^Done"))
check("back at the start", atStart())

-- 11e. a scan whose forward is really the turtle's right (as if its
--      heading were off): it says so and stops trusting scans
setup({ { name = SCANNER, count = 1 }, { name = "minecraft:chest", count = 4 }, { name = "minecraft:coal", count = 64 } })
startAt(); inv, files = {}, {}
EQ = { right = "minecraft:diamond_pickaxe" }
FUEL, DRY, SCANS = 2000, 0, 0
SCAN_TURN = 1
run("3", "3", "30")
SCAN_TURN = 0
check("a scan turned from its heading: said so, and skipped it", logHas("heading looks off"))
check("still dug the tunnel, by hand", leftIn(0, 2, 0, 2, 1, 30) == 0)
check("back at the start", atStart())

-- 11f. tunnelling past water in the walls (an aquifer right of it, at
--      every height) with torches: it never opens a block that touches
--      the water without standing in it, so water hardly gets in, and no
--      torch is washed away; with and without a scanner
local function wetWalls(withScanner)
    setup(stock(4, 64, 64))
    if withScanner then table.insert(chestAt(0, 1, 0), { name = SCANNER, count = 1 }) end
    table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 })
    for x = 3, 6 do for y = -1, 3 do for z = 6, 30 do set(x, y, z, { name = "minecraft:water", level = 0 }) end end end
    for x = -1, 7 do for z = 5, 31 do set(x, 4, z, { name = "minecraft:stone" }); set(x, -2, z, { name = "minecraft:stone" }) end end
    startAt(); inv, files = {}, {}
    EQ = { right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, PLACED, SCANS, WASHED, INGRESS = 3000, 0, 0, 0, 0, 0
    WATERY, BOX = true, { 0, 2, 0, 2 }
    run("3", "3", "36")
    WATERY, BOX = false, nil
    local wetIn = 0
    for x = 0, 2 do for y = 0, 2 do for z = 1, 36 do if isWater(get(x, y, z)) then wetIn = wetIn + 1 end end end end
    local torches = 0
    for x = -1, 3 do for z = 1, 36 do if (get(x, 0, z) or {}).name == "minecraft:torch" then torches = torches + 1 end end end
    check("no water got into the tunnel past the block being dug", INGRESS <= 3,
        INGRESS .. " times water flowed into an open tunnel block")
    check("no torch washed away", WASHED == 0 and torches >= 2, WASHED .. " washed away, " .. torches .. " up")
    check("no water left in the tunnel", wetIn == 0, wetIn .. " blocks")
    check("tunnel clear", leftIn(0, 2, 0, 2, 1, 36) == 0, leftIn(0, 2, 0, 2, 1, 36) .. " blocks left")
    check("back at the start", atStart())
end
wetWalls(false)
wetWalls(true)

-- 11g. glow lichen in the walls and ceiling, waterlogged, with water
--      behind it: it looks like a block, but it's a water source.  The
--      turtle replaces it with a bulk block (dry lichen too, as it isn't
--      solid), so no water gets in; with and without a scanner
local function lichenWorld(withScanner)
    setup(stock(4, 64, 64))
    if withScanner then table.insert(chestAt(0, 1, 0), { name = SCANNER, count = 1 }) end
    table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 })
    local LICHEN = { name = "minecraft:glow_lichen", waterlogged = true }
    set(3, 1, 10, LICHEN); set(4, 1, 10, { name = "minecraft:water", level = 0 })
    set(4, 0, 10, { name = "minecraft:water", level = 0 }); set(4, 2, 10, { name = "minecraft:water", level = 0 })
    set(-1, 0, 16, { name = "minecraft:glow_lichen", waterlogged = true })     -- in the left wall at floor level
    set(1, 3, 22, { name = "minecraft:glow_lichen", waterlogged = true })      -- in the ceiling, water above
    set(1, 4, 22, { name = "minecraft:water", level = 0 }); set(1, 5, 22, { name = "minecraft:water", level = 0 })
    set(3, 0, 26, { name = "minecraft:glow_lichen" })                          -- dry, in the right wall
    startAt(); inv, files = {}, {}
    EQ = { right = "minecraft:diamond_pickaxe" }
    FUEL, DRY, WASHED, INGRESS, SCANS = 3000, 0, 0, 0, 0
    WATERY, BOX = true, { 0, 2, 0, 2 }
    run("3", "3", "30")
    WATERY, BOX = false, nil
    local wet, lichen = 0, 0
    for x = -2, 4 do for y = -1, 3 do for z = 1, 30 do
        local b = get(x, y, z)
        local touching = (x == -1 or x == 3 or y == -1 or y == 3) and (x >= -1 and x <= 3 and y >= -1 and y <= 3)
        if x >= 0 and x <= 2 and y >= 0 and y <= 2 and isWater(b) then wet = wet + 1 end
        if touching and b and b.name == "minecraft:glow_lichen" then lichen = lichen + 1 end
    end end end
    check("no lichen left in the walls, floor or ceiling", lichen == 0, lichen .. " left")
    check("no water got into the tunnel past the block being dug, and none's in it",
        INGRESS <= 3 and wet == 0, INGRESS .. " times water flowed in, " .. wet .. " blocks wet")
    check("no torch washed away", WASHED == 0)
    check("tunnel clear", leftIn(0, 2, 0, 2, 1, 30) == 0, leftIn(0, 2, 0, 2, 1, 30) .. " blocks left")
    check("back at the start", atStart())
end
lichenWorld(false)
lichenWorld(true)

-- 12. low on fuel with a scanner: the only fuel is coal 5 out from the
--     tunnel, which it goes for as soon as a scan finds it, and burns
setup({ { name = SCANNER, count = 1 }, { name = "minecraft:chest", count = 4 } })
for x = -5, -6, -1 do for y = 0, 1 do set(x, y, 10, ore("minecraft:coal_ore")) end end
startAt(); inv, files = {}, {}
EQ = { right = "minecraft:diamond_pickaxe" }
FUEL, LOWEST, DRY = 250, math.huge, 0
run("3", "3", "40")
check("went for the coal when low", logHas("going for the coal"))
check("mined all 4 coal ore", oreGone(-5, 0, 10) and oreGone(-6, 0, 10) and oreGone(-5, 1, 10) and oreGone(-6, 1, 10))
check("finished the tunnel on it", logHas("^Done"), logHas("Stopped") and "stopped" or "")
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
check("back at the start", atStart())

-- 13. `mine reset` when the saved heading is wrong (a turn the program
--     never recorded): by a wall in a finished part of the tunnel it sees
--     which way it really faces, and gets home
local function dugTunnel()
    setup(stock(4, 64))
    for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do set(x, y, z, nil) end end end
    for _, z in ipairs({ 16, 32 }) do set(-1, 0, z, chest()); set(0, -1, z, chest()) end
    files = { ["mine.job"] = "3 3 0 16 2 active" }    -- homes at 16 and 32: dug to 32
    inv = {}
    EQ = { right = "minecraft:diamond_pickaxe" }
    FUEL, DRY = 500, 0
end
dugTunnel()
P.x, P.y, P.z, P.d = 0, 1, 20, 1                      -- really faces +x ...
files[".turtlepos"] = "0 1 20 0 flat"                 -- ... saved as facing ahead
local before = leftIn(-3, 5, -3, 5, 1, 41)
run("reset")
check("saw it really faces right, and corrected it", logHas("really faces 1, not 0"))
check("went to the last home (z=32), facing its wall", P.x == 0 and P.y == 0 and P.z == 32 and P.d == 3)
check("dug nothing on the way", leftIn(-3, 5, -3, 5, 1, 41) == before)
-- 13b. the same with --to-start: all the way back to the start
dugTunnel()
P.x, P.y, P.z, P.d = 0, 1, 20, 1
files[".turtlepos"] = "0 1 20 0 flat"
run("reset", "--to-start")
check("--to-start went to the start", atStart())
-- 13c. the last home (2, z=32) flooded: `mine reset --home 1` takes it
--      back a home, and `mine --resume` carries on from there, going over
--      the flooded segment again, drying it out and sealing it, on past
--      home 2 (there already: not built again) to the end
dugTunnel()
files["mine.job"] = "3 3 40 16 2 active"
for x = -2, 4 do for y = -1, 4 do for z = 22, 36 do
    if not chestAt(x, y, z) then set(x, y, z, { name = "minecraft:water", level = 0 }) end
end end end
for x = -2, 4 do for z = 21, 37 do set(x, 5, z, { name = "minecraft:stone" }) end end
for _, it in ipairs(stock(2, 64)) do table.insert(chestAt(-1, 0, 32), it) end     -- the supplies, out there
for _ = 1, 3 do table.insert(chestAt(0, -1, 16), { name = "minecraft:cobblestone", count = 64 }) end
P.x, P.y, P.z, P.d = 0, 0, 32, 3
set(0, 0, 32, nil)
files[".turtlepos"] = "0 0 32 3 flat"
FUEL = 3000
run("reset", "--home", "1")
FUEL = 400                              -- low: the fuel is out in home 2
check("reset --home 1 went back to home 1 (z=16), facing its wall", P.x == 0 and P.y == 0 and P.z == 16 and P.d == 3)
run("reset", "--home", "3")
check("there's no home 3: said so", logHas("no home 3"))
WATERY, PLACED = true, 0
run("--resume")
WATERY = false
check("resumed from home 1, and went on to home 2 without building it again",
    logHas("On to home 2") and not logHas("Built home 2"))
local wetIn, wetOpen = 0, 0
for x = -3, 5 do for y = -2, 6 do for z = 1, 41 do
    local b = get(x, y, z)
    if isWater(b) then
        if x >= 0 and x <= 2 and y >= 0 and y <= 2 then wetIn = wetIn + 1 end
        for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
            if not get(x + d[1], y + d[2], z + d[3]) then wetOpen = wetOpen + 1 end
        end
    end
end end end
check("no water left in the tunnel", wetIn == 0, wetIn .. " blocks")
check("no water touching open space (sealed off)", wetOpen == 0, wetOpen .. " open faces")
check("tunnel dug to the end", leftIn(0, 2, 0, 2, 1, 40) == 0, leftIn(0, 2, 0, 2, 1, 40) .. " blocks left")
check("home 2's chests still there", chestAt(-1, 0, 32) and chestAt(0, -1, 32))
check("fetched fuel from home 2 first, and carried some: no trips home to refuel",
    logHas("Fetching fuel from home 2") and not logHas("Low on fuel"))
check("finished", logHas("^Done"))
check("back at the start", atStart())
-- 13d. resumed at home 1 with water standing in the tunnel behind it
--      (flood water spreads back along the floor) and a scanner on board:
--      scans show the water where it dug, which is no sign its heading's off
dugTunnel()
files["mine.job"] = "3 3 40 16 2 active"
for x = 0, 2 do for y = 0, 2 do for z = 10, 16 do
    if not (x == 0 and y == 0 and z == 16) then set(x, y, z, { name = "minecraft:water", level = 0 }) end
end end end
for _, it in ipairs(stock(2, 64)) do table.insert(chestAt(-1, 0, 16), it) end
P.x, P.y, P.z, P.d = 0, 0, 16, 3
files[".turtlepos"] = "0 0 16 3 flat"
inv = { { name = SCANNER, count = 1 } }
FUEL, SCANS = 3000, 0
run("--resume")
check("scanned, and the water behind didn't make it think its heading was off",
    SCANS > 0 and not logHas("heading looks off"), SCANS .. " scans")
check("finished", logHas("^Done"))
-- 13e. a source in the right wall at floor level near home 2, its water
--      spread along the tunnel floor: walking out to home 2 (resumed from
--      the start) it follows the flow back to where it comes in and seals it
dugTunnel()
files["mine.job"] = "3 3 40 16 2 active"
for _, it in ipairs(stock(2, 64)) do table.insert(chestAt(0, 1, 0), it) end
table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 })
set(3, 0, 26, { name = "minecraft:water", level = 0 })
WATERY = true
flow(3, 0, 26)
settleWater()
local spread = 0
for x = 0, 2 do for z = 1, 40 do if isWater(get(x, 0, z)) then spread = spread + 1 end end end
startAt()
files[".turtlepos"] = "0 0 0 0 flat"
FUEL = 3000
run("--resume")
WATERY = false
local left = 0
for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do if isWater(get(x, y, z)) then left = left + 1 end end end end
check("followed the flow to the wall and sealed it: no water in the tunnel",
    spread > 5 and left == 0 and not isWater(get(3, 0, 26)), spread .. " floor blocks wet before, " .. left .. " after")
check("finished", logHas("^Done"))

-- 13g. dug already, with waterlogged glow lichen in the right wall at
--      floor level near z=24, its water spread along the floor: `mine
--      reset --home 1` and `mine --resume` go over the segment, follow
--      the water to the lichen and replace it, without going back and
--      forth over it
dugTunnel()
files["mine.job"] = "3 3 40 16 2 active"
for _, it in ipairs(stock(2, 64)) do table.insert(chestAt(-1, 0, 32), it) end
for _ = 1, 2 do table.insert(chestAt(0, -1, 16), { name = "minecraft:cobblestone", count = 64 }) end
set(3, 0, 24, { name = "minecraft:glow_lichen", waterlogged = true })
WATERY = true
flow(3, 0, 24)
settleWater()
P.x, P.y, P.z, P.d = 0, 0, 32, 3
files[".turtlepos"] = "0 0 32 3 flat"
FUEL = 3000
run("reset", "--home", "1")
run("--resume")
WATERY = false
local wetLeft = 0
for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do if isWater(get(x, y, z)) then wetLeft = wetLeft + 1 end end end end
check("followed the water to the lichen and replaced it", wetLeft == 0 and (get(3, 0, 24) or {}).name ~= "minecraft:glow_lichen",
    wetLeft .. " tunnel blocks wet")
LICHEN_MOVES, LICHEN_TURNS = moves, turns
check("finished", logHas("^Done"))

-- 13h. dug already, with waterlogged lichen in the ceiling at the far end
--      of the segment (z=31), its water falling and spreading back along
--      the floor: going over the segment it wades through the water and
--      follows it to the lichen, rather than stepping back and forth
dugTunnel()
files["mine.job"] = "3 3 40 16 2 active"
for _, it in ipairs(stock(2, 64)) do table.insert(chestAt(-1, 0, 32), it) end
for _ = 1, 2 do table.insert(chestAt(0, -1, 16), { name = "minecraft:cobblestone", count = 64 }) end
set(1, 3, 31, { name = "minecraft:glow_lichen", waterlogged = true })
WATERY = true
flow(1, 3, 31)
settleWater()
local spreadH = 0
for x = 0, 2 do for z = 1, 40 do if isWater(get(x, 0, z)) then spreadH = spreadH + 1 end end end
P.x, P.y, P.z, P.d = 0, 0, 32, 3
files[".turtlepos"] = "0 0 32 3 flat"
FUEL = 3000
run("reset", "--home", "1")
run("--resume")
WATERY = false
local wetH = 0
for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do if isWater(get(x, y, z)) then wetH = wetH + 1 end end end end
check("followed the water to the lichen in the ceiling and replaced it",
    spreadH > 5 and wetH == 0 and (get(1, 3, 31) or {}).name ~= "minecraft:glow_lichen",
    spreadH .. " floor blocks wet before, " .. wetH .. " after")
check("finished", logHas("^Done"))

-- 13f. stopped (Ctrl+T) partway through a segment; then a hole opens in
--      the ceiling over what's dug, with water above, which pours in and
--      spreads (washing torches away).  `mine reset` and `mine --resume`:
--      it carries on from where it stopped (from its log of the segment,
--      not going over the lanes it finished), and on the way along the
--      bottom of what it dug it follows the water up to the hole and
--      seals it, and puts the torches back
local function holeWorld()
    setup(stock(4, 64, 64))
    for _ = 1, 3 do table.insert(chestAt(0, -1, 0), { name = "minecraft:cobblestone", count = 64 }) end
    startAt(); inv, files = {}, {}
    EQ = { right = "minecraft:diamond_pickaxe" }
    FUEL, DRY = 3000, 0
end
holeWorld()
run("3", "3", "40")
local fullTurns = turns
-- stopped and resumed with no water about: about the turns of the whole
-- tunnel between the two runs (it doesn't go over the finished lanes again)
holeWorld()
STOP_AT_DIG = 200
run("3", "3", "40")
STOP_AT_DIG = nil
local firstTurns = turns
run("reset")
run("--resume")
check("stopped and resumed: about the turns of the whole tunnel, not more",
    firstTurns + turns < fullTurns * 1.25, firstTurns .. " + " .. turns .. " turns, " .. fullTurns .. " in one go")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 40) == 0, leftIn(0, 2, 0, 2, 1, 40) .. " blocks left")
holeWorld()
STOP_AT_DIG = 200
run("3", "3", "40")
STOP_AT_DIG = nil
for x = -1, 3 do for z = 5, 11 do set(x, 4, z, { name = "minecraft:stone" }) end end
set(1, 3, 8, { name = "minecraft:water", level = 0 })   -- the hole, water standing in it
set(1, 4, 8, { name = "minecraft:water", level = 0 })
WATERY, WASHED = true, 0
flow(1, 3, 8)
settleWater()
local wetBefore = 0
for x = 0, 2 do for z = 1, 40 do if isWater(get(x, 0, z)) then wetBefore = wetBefore + 1 end end end
run("reset")
WASHED = 0
run("--resume")
WATERY = false
local wetAfter = 0
for x = 0, 2 do for y = 0, 2 do for z = 1, 40 do if isWater(get(x, y, z)) then wetAfter = wetAfter + 1 end end end end
check("carried on from its log of the segment", logHas("Carrying on with lane"))
check("found the water from the ceiling, followed it up and sealed the hole",
    wetBefore > 3 and wetAfter == 0 and not isWater(get(1, 3, 8)),
    wetBefore .. " floor blocks wet before, " .. wetAfter .. " tunnel blocks after")
local torches = 0
for x = -1, 3 do for z = 1, 40 do if (get(x, 0, z) or {}).name == "minecraft:torch" then torches = torches + 1 end end end
check("no torch washed away after the resume, and they're all up", WASHED == 0 and torches >= 2,
    WASHED .. " washed away, " .. torches .. " up")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 40) == 0, leftIn(0, 2, 0, 2, 1, 40) .. " blocks left")
check("back at the start", atStart())

-- 14. in the middle of a 3-wide tunnel every way is open, so it can't
--     tell: it goes by the (wrong) saved heading, but stops, finding no
--     home chests where it ends up (or digging through far more rock than
--     the way back could take)
dugTunnel()
P.x, P.y, P.z, P.d = 1, 1, 20, 1
files[".turtlepos"] = "1 1 20 0 flat"
before = leftIn(-20, 20, -3, 5, 1, 41)
run("reset")
local dug = before - leftIn(-20, 20, -3, 5, 1, 41)
check("stopped, saying its position or heading must be wrong", logHas("position or heading must be wrong"))
check("dug no more than its limit (12)", dug <= 12, dug .. " blocks")
