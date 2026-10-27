-- sim/mine_tunnel.lua
--
-- `mine` digging a tunnel through mixed rock: ore veins running out of
-- the walls, floor and ceiling (part of one beyond the reach the turtle
-- may stray), ore inside the tunnel, a tag-only modded ore, lava in a
-- wall and inside the tunnel, gravel that falls in from above, and a
-- valuables chest above the start and a bulk chest below.  Checks the
-- tunnel is clear, every ore in reach is mined and none beyond it, no
-- lava touches the tunnel, valuables and bulk ended up in the right
-- chests, and with little fuel and a small inventory it makes trips home
-- and never moves on an empty tank.  Then `mine reset` from inside a vein.
local PROJ = ...
package.path = PROJ .. "/?.lua;" .. package.path

--------------------------------------------------------------------------
-- World: W[key] = block, false = air; unset = the default rock
--------------------------------------------------------------------------
local W = {}
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

local ORE_TAGS = { ["c:ores"] = true }
local function ore(name) return { name = name } end
local DROP = {
    ["minecraft:stone"] = "minecraft:cobblestone", ["minecraft:deepslate"] = "minecraft:cobbled_deepslate",
    ["minecraft:iron_ore"] = "minecraft:raw_iron", ["minecraft:diamond_ore"] = "minecraft:diamond",
    ["minecraft:coal_ore"] = "minecraft:coal", ["minecraft:deepslate_gold_ore"] = "minecraft:raw_gold",
    ["modded:tin_vein"] = "modded:raw_tin",
}
local FALLS = { ["minecraft:gravel"] = true, ["minecraft:sand"] = true }

local function setup()
    for key in pairs(W) do W[key] = nil end
    set(0, 1, 0, { name = "minecraft:chest" })      -- valuables
    set(0, -1, 0, { name = "minecraft:chest" })     -- bulk
    -- vein A: iron out of the left wall at y=1, z=4, running to x=-5
    -- (x=-5 is 5 out: beyond the reach of 4, must stay)
    for x = -1, -5, -1 do set(x, 1, 4, ore("minecraft:iron_ore")) end
    set(-2, 2, 4, ore("minecraft:iron_ore"))
    -- vein B: diamond in the ceiling, going up
    set(1, 3, 8, ore("minecraft:diamond_ore")); set(1, 4, 8, ore("minecraft:diamond_ore"))
    -- coal inside the tunnel (middle column, middle row), running out the floor? no: on its own
    set(1, 1, 6, ore("minecraft:coal_ore"))
    -- gold in the floor, two deep
    set(2, -1, 10, ore("minecraft:deepslate_gold_ore")); set(2, -2, 10, ore("minecraft:deepslate_gold_ore"))
    -- a modded ore known only by its tag, past the far end
    set(0, 0, 13, { name = "modded:tin_vein", tags = ORE_TAGS })
    -- lava: a source in the right wall, and one inside the tunnel
    set(3, 0, 3, { name = "minecraft:lava", level = 0 })
    set(1, 2, 9, { name = "minecraft:lava", level = 0 })
    -- gravel in the tunnel with more above the ceiling, which falls in
    for y = 1, 5 do set(2, y, 7, { name = "minecraft:gravel" }) end
end
local ORES = {}            -- filled after setup: where ore was, for checking
local function isOreBlock(b)
    return b and (b.name:find("_ore$") or (b.tags and b.tags["c:ores"])) and true or false
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
local chests = { top = {}, bottom = {} }
local SIZE = 27
local STACK = function() return 64 end

local function addItem(name, n)
    for s = 1, 16 do
        if inv[s] and inv[s].name == name and inv[s].count < 64 then
            local take = math.min(n, 64 - inv[s].count); inv[s].count = inv[s].count + take; n = n - take
        end
        if n == 0 then return true end
    end
    for s = 1, 16 do
        if not inv[s] then inv[s] = { name = name, count = math.min(n, 64) }; n = n - inv[s].count end
        if n == 0 then return true end
    end
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
    return true, { name = b.name, state = { level = b.level }, tags = tags }
end
-- gravel and sand above (x,y,z) fall into it once it's empty
local function gravity(x, y, z)
    while not get(x, y, z) do
        local above = get(x, y + 1, z)
        if not (above and FALLS[above.name]) then return end
        set(x, y, z, above); set(x, y + 1, z, nil); y = y + 1
    end
end
local function move(dx, dy, dz)
    if FUEL <= 0 then DRY = DRY + 1; return false end
    local nx, ny, nz = P.x + dx, P.y + dy, P.z + dz
    if not passable(get(nx, ny, nz)) then return false end
    P.x, P.y, P.z = nx, ny, nz; moves = moves + 1
    if TRAVELLING then                  -- a trip ends back where it started
        if P.x ~= BACK[1] or P.y ~= BACK[2] or P.z ~= BACK[3] then LEFT_SPOT = true
        elseif LEFT_SPOT then TRAVELLING = false end
    end
    FUEL = FUEL - 1; LOWEST = math.min(LOWEST, FUEL)
    return true
end
local function chestAt(x, y, z)
    if x ~= 0 or z ~= 0 then return nil end
    if y == 1 then return chests.top elseif y == -1 then return chests.bottom end
end
local function digAt(x, y, z)
    local b = get(x, y, z)
    if not b or passable(b) or b.name:find("chest") then return false end
    if b.name == "minecraft:bedrock" then return false end
    set(x, y, z, nil)
    if TRAVELLING then TRAVEL_DIGS = (TRAVEL_DIGS or 0) + 1 end
    addItem(DROP[b.name] or b.name, 1)
    gravity(x, y, z)
    return true
end
local function placeAt(x, y, z)
    local it = inv[sel]; if not it then return false end
    if not passable(get(x, y, z)) then return false end
    if it.name:find("raw_") or it.name == "minecraft:coal" or it.name == "minecraft:diamond" then return false end
    set(x, y, z, { name = it.name == "minecraft:cobblestone" and "minecraft:cobblestone" or it.name })
    it.count = it.count - 1; if it.count == 0 then inv[sel] = nil end
    return true
end
local function dropInto(c, n)
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
local function suckFrom(c, n)
    for s = 1, SIZE do
        local d = c[s]
        if d then
            n = math.min(n or 64, d.count)
            local before = d.count
            -- into the selected slot first, then wherever it fits
            local it = inv[sel]
            if it and it.name ~= d.name then
                local s2; for i = 1, 16 do if not inv[i] then s2 = i; break end end
                if not s2 then return false end
                inv[s2] = { name = d.name, count = n }
            elseif it then
                local t = math.min(n, 64 - it.count); it.count = it.count + t; n = t
            else
                inv[sel] = { name = d.name, count = n }
            end
            d.count = before - n; if d.count == 0 then c[s] = nil end
            return true
        end
    end
    return false
end
local function front() return P.x + DX[P.d], P.y, P.z + DZ[P.d] end

turtle = {
    forward = function() return move(DX[P.d], 0, DZ[P.d]) end,
    back = function() return move(-DX[P.d], 0, -DZ[P.d]) end,
    up = function() return move(0, 1, 0) end,
    down = function() return move(0, -1, 0) end,
    turnRight = function() P.d = (P.d + 1) % 4; turns = turns + 1; return true end,
    turnLeft = function() P.d = (P.d + 3) % 4; turns = turns + 1; return true end,
    inspect = function() return inspectAt(front()) end,
    inspectUp = function() return inspectAt(P.x, P.y + 1, P.z) end,
    inspectDown = function() return inspectAt(P.x, P.y - 1, P.z) end,
    detect = function() return not passable(get(front())) end,
    detectUp = function() return not passable(get(P.x, P.y + 1, P.z)) end,
    detectDown = function() return not passable(get(P.x, P.y - 1, P.z)) end,
    dig = function() return digAt(front()) end,
    digUp = function() return digAt(P.x, P.y + 1, P.z) end,
    digDown = function() return digAt(P.x, P.y - 1, P.z) end,
    place = function() return placeAt(front()) end,
    placeUp = function() return placeAt(P.x, P.y + 1, P.z) end,
    placeDown = function() return placeAt(P.x, P.y - 1, P.z) end,
    attack = function() return false end, attackUp = function() return false end, attackDown = function() return false end,
    select = function(s) sel = s; return true end,
    getSelectedSlot = function() return sel end,
    getItemCount = function(s) return inv[s or sel] and inv[s or sel].count or 0 end,
    getItemDetail = function(s) local it = inv[s or sel]; return it and { name = it.name, count = it.count } end,
    dropUp = function(n) local c = chestAt(P.x, P.y + 1, P.z); if not c then error("dropped on the ground") end; return dropInto(c, n) end,
    dropDown = function(n) local c = chestAt(P.x, P.y - 1, P.z); if not c then error("dropped on the ground") end; return dropInto(c, n) end,
    drop = function() error("dropped on the ground") end,
    suckUp = function(n) local c = chestAt(P.x, P.y + 1, P.z); return c and suckFrom(c, n) or false end,
    suckDown = function(n) local c = chestAt(P.x, P.y - 1, P.z); return c and suckFrom(c, n) or false end,
    suck = function() return false end,
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
    getEquippedLeft = function() return nil end,
    getEquippedRight = function() return { name = "minecraft:diamond_pickaxe" } end,
}
peripheral = {
    wrap = function(side)
        local c = side == "top" and chestAt(P.x, P.y + 1, P.z) or side == "bottom" and chestAt(P.x, P.y - 1, P.z)
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
}

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
WAITS = 0
os.startTimer = function() return 1 end
os.pullEvent = function()
    WAITS = WAITS + 1
    if WAITS > 20 then error("waited for fuel forever") end
    -- the "player" puts coal in the valuables chest
    for s = 1, SIZE do if not chests.top[s] then chests.top[s] = { name = "minecraft:coal", count = 32 }; break end end
    return "turtle_inventory"
end

local log = {}
local realPrint = print
print = function(...)
    local t = {}; for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
    local line = table.concat(t, " ")
    local bx, by, bz = line:match("at %((-?%d+),(-?%d+),(-?%d+)%): going home")
    if bx then TRAVELLING, LEFT_SPOT, BACK = true, false, { tonumber(bx), tonumber(by), tonumber(bz) } end
    log[#log + 1] = line
end

local function run(...)
    log, moves, turns = {}, 0, 0
    package.loaded.turtlelib = nil
    local chunk = assert(loadfile(PROJ .. "/mine.lua"))
    local ok, err = pcall(chunk, ...)
    realPrint("== mine " .. table.concat({ ... }, " ") .. "  (moves: " .. moves .. ", turns: " .. turns .. ")")
    TRIPS = 0
    for _, l in ipairs(log) do
        if not l:find("^Lane ") then realPrint("   " .. l) end
        if l:find("going home") then TRIPS = TRIPS + 1 end
    end
    if not ok then realPrint("   ERROR: " .. tostring(err)) end
    realPrint(string.format("   ends at (%d,%d,%d) facing %d", P.x, P.y, P.z, P.d))
end

local function check(label, ok, detail)
    realPrint(string.format("   %s %s%s", ok and "ok   " or "ERROR:", label, detail and ("  (" .. detail .. ")") or ""))
end

local function contents(c)
    local n, order = {}, {}
    for s = 1, SIZE do
        local d = c[s]
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

-- Checks after mining an L x 3 x 3 tunnel (x 0..2, y 0..2).
local function checkTunnel(L)
    local left = 0
    for x = 0, 2 do for y = 0, 2 do for z = 1, L do
        if get(x, y, z) then left = left + 1 end
    end end end
    check("tunnel clear", left == 0, left .. " blocks left in it")
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
    -- no lava next to any open block in the tunnel or a vein
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
    local top, tn = contents(chests.top)
    local bottom, bn = contents(chests.bottom)
    realPrint("   top (valuables): " .. top)
    realPrint("   bottom (bulk):   " .. bottom)
    local BULKY = { cobblestone = true, cobbled_deepslate = true, andesite = true, diorite = true,
                    granite = true, tuff = true, gravel = true }
    local misplaced = {}
    for name in pairs(tn) do if BULKY[name:gsub("^%a+:", "")] then misplaced[#misplaced + 1] = name .. " on top" end end
    for name in pairs(bn) do if not BULKY[name:gsub("^%a+:", "")] then misplaced[#misplaced + 1] = name .. " below" end end
    check("valuables on top, bulk below", #misplaced == 0, table.concat(misplaced, ", "))
    check("home facing ahead", P.x == 0 and P.y == 0 and P.z == 0 and P.d == 0)
    check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
    check("nothing spilled", (SPILLED or 0) == 0, tostring(SPILLED or 0))
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

-- 1. a 12x3x3 tunnel with plenty of fuel and room
setup(); remember()
P.x, P.y, P.z, P.d = 0, 0, 0, 0
inv = {}
chests = { top = { { name = "minecraft:coal", count = 64 } }, bottom = {} }
FUEL, LOWEST, DRY = 1000, 1000, 0
run("12", "3", "3")
checkTunnel(12)

-- 2. the same tunnel, 60 long, starting with 60 fuel and no coal anywhere:
--    the player adds coal while it waits; and lots of kinds of rock, so the
--    inventory fills and it goes home to unload
setup(); remember()
P.x, P.y, P.z, P.d = 0, 0, 0, 0
inv, files = {}, {}
chests = { top = {}, bottom = {} }
FUEL, LOWEST, DRY, WAITS, SPILLED, TRAVEL_DIGS = 140, 140, 0, 0, 0, 0
run("60", "3", "3")
checkTunnel(60)
local full, low = 0, 0
for _, l in ipairs(log) do
    if l:find("Inventory nearly full") then full = full + 1 end
    if l:find("Low on fuel") then low = low + 1 end
end
check("dug nothing on the way home and back", (TRAVEL_DIGS or 0) == 0, tostring(TRAVEL_DIGS or 0) .. " blocks")
check("went home to unload and to refuel", full > 0 and low > 0,
    full .. " to unload, " .. low .. " to refuel, " .. WAITS .. " waits for fuel, lowest fuel " .. LOWEST)

-- 3. stopped inside a vein (a server restart): `mine reset` digs back to
--    the tunnel and goes home
P.x, P.y, P.z, P.d = -3, 1, 4, 3
files[".turtlepos"] = "-3 1 4 3 flat"
run("reset")
check("reset from a vein got home", P.x == 0 and P.y == 0 and P.z == 0 and P.d == 0)

-- 4. a tunnel to the left and down: `mine 6 -2 -2`
setup()
P.x, P.y, P.z, P.d = 0, 0, 0, 0
inv, files = {}, {}
chests = { top = {}, bottom = {} }
FUEL, DRY = 1000, 0
run("6", "-2", "-2")
local left = 0
for x = -1, 0 do for y = -1, 0 do for z = 1, 6 do if get(x, y, z) then left = left + 1 end end end end
check("left-and-down tunnel clear", left == 0, left .. " blocks left")
check("nothing dug right of or above it", get(1, 0, 3) ~= nil and get(0, 1, 3) ~= nil)
check("home facing ahead", P.x == 0 and P.y == 0 and P.z == 0 and P.d == 0)
