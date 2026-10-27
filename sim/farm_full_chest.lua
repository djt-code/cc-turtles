-- sim/farm_full_chest.lua
--
-- Inventory and chest limits: a turtle stuffed with coal, a chest with
-- room for only a few stacks, then a chest that is already full.  Nothing
-- should spill on the ground; the turtle waits for room instead.
--
-- Minimal CC:Tweaked world + turtle mock for exercising farm.lua.
-- Turtle starts at (0,0,0) facing +z; farmland at y=-2, crops at y=-1.
local PROJ = ...
package.path = PROJ .. "/?.lua;" .. package.path

local W = {}                         -- world["x,y,z"] = { name=, age= }
local function T_ONE(name) return name:find("_pickaxe$") or name:find("_hoe$") or name:find("_axe$") or name:find("_shovel$") or name:find("_sword$") or name:find("bucket$") end
local function k(x, y, z) return x .. "," .. y .. "," .. z end
function W.get(x, y, z) return W[k(x, y, z)] end
function W.set(x, y, z, b) W[k(x, y, z)] = b end

local WIDTH, LENGTH, LANE_X = 5, 6, 3
local PLANT = { ["minecraft:wheat_seeds"] = "minecraft:wheat", ["minecraft:carrot"] = "minecraft:carrots",
                ["minecraft:potato"] = "minecraft:potatoes", ["minecraft:beetroot_seeds"] = "minecraft:beetroots" }
local RIPE = { ["minecraft:wheat"] = 7, ["minecraft:carrots"] = 7, ["minecraft:potatoes"] = 7, ["minecraft:beetroots"] = 3 }
local DROPS = { ["minecraft:wheat"] = { "minecraft:wheat", "minecraft:wheat_seeds" },
                ["minecraft:carrots"] = { "minecraft:carrot", "minecraft:carrot" },
                ["minecraft:potatoes"] = { "minecraft:potato", "minecraft:potato" },
                ["minecraft:beetroots"] = { "minecraft:beetroot", "minecraft:beetroot_seeds" } }
COLCROP = { [1] = "minecraft:wheat", [2] = "minecraft:wheat", [4] = "cane", [5] = "minecraft:beetroots" }
CANE = "minecraft:sugar_cane"
LOST = 0
local function caneAbove(x, y, z)       -- cutting at y: blocks above pop off as items
    y = y + 1
    while W.get(x, y, z) and W.get(x, y, z).name == CANE do W.set(x, y, z, nil); LOST = LOST + 1; y = y + 1 end
end
local function waterBeside(x, y, z)
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local b = W.get(x + d[1], y, z + d[2])
        if b and b.name == "minecraft:water" and not b.level then return true end
    end
    return false
end
local function build()
    for key in pairs(W) do if type(W[key]) == "table" then W[key] = nil end end
    W.set(0, -1, 0, { name = "minecraft:chest" })
    for x = 0, WIDTH + 1 do
        for z = 0, LENGTH + 1 do
            W.set(x, -3, z, { name = "minecraft:dirt" })
            local inside = x >= 1 and x <= WIDTH and z >= 1 and z <= LENGTH
            if not inside then
                if not (x == 0 and z == 0) then W.set(x, -2, z, { name = "minecraft:grass_block" }) end
            elseif x == LANE_X then
                W.set(x, -2, z, { name = "minecraft:water" })
            elseif COLCROP[x] == "cane" then
                W.set(x, -2, z, { name = "minecraft:sand" })
                for h = 1, (z % 3) + 1 do W.set(x, -2 + h, z, { name = CANE }) end
            else
                W.set(x, -2, z, { name = "minecraft:farmland" })
                local c = COLCROP[x]
                W.set(x, -1, z, { name = c, age = (x + z) % 2 == 0 and RIPE[c] or 1 })
            end
        end
    end
end

local P = { x = 0, y = 0, z = 0, d = 0 }
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }
local moves = 0
local inv, sel = {}, 1
EQ = { right = "minecraft:diamond_hoe" }
local chest = {}

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
    if n > 0 then SPILLED = (SPILLED or 0) + n end
    return n == 0
end
local function useSel() local it = inv[sel]; it.count = it.count - 1; if it.count == 0 then inv[sel] = nil end end
local function passable(b) return b == nil or b.name == "minecraft:water" end
local function inspectAt(x, y, z)
    local b = W.get(x, y, z)
    if not b then return false end
    return true, { name = b.name, state = { age = b.age, level = b.level or (b.name == "minecraft:water" and 0 or nil) } }
end

local function move(dx, dy, dz)
    local nx, ny, nz = P.x + dx, P.y + dy, P.z + dz
    if not passable(W.get(nx, ny, nz)) then return false end
    P.x, P.y, P.z = nx, ny, nz; moves = moves + 1
    return true
end

-- Water at (x,y,z) is a source that refills if it has 2+ source neighbours.
local function regen(x, y, z)
    local n = 0
    for d = 0, 3 do
        local b = W.get(x + DX[d], y, z + DZ[d])
        if b and b.name == "minecraft:water" and not b.level then n = n + 1 end
    end
    return n >= 2
end

-- what watchsim.lua draws: the world, the turtle and the farm's size
SIM_WORLD = { W = W, P = P, width = WIDTH, length = LENGTH, moves = function() return moves end }
turtle = {
    forward = function() return move(DX[P.d], 0, DZ[P.d]) end,
    back = function() return move(-DX[P.d], 0, -DZ[P.d]) end,
    up = function() return move(0, 1, 0) end,
    down = function() return move(0, -1, 0) end,
    turnRight = function() P.d = (P.d + 1) % 4; return true end,
    turnLeft = function() P.d = (P.d + 3) % 4; return true end,
    inspect = function() return inspectAt(P.x + DX[P.d], P.y, P.z + DZ[P.d]) end,
    inspectUp = function() return inspectAt(P.x, P.y + 1, P.z) end,
    inspectDown = function() return inspectAt(P.x, P.y - 1, P.z) end,
    detect = function() return W.get(P.x + DX[P.d], P.y, P.z + DZ[P.d]) ~= nil end,
    detectDown = function() return W.get(P.x, P.y - 1, P.z) ~= nil end,
    dig = function()
        local x, z = P.x + DX[P.d], P.z + DZ[P.d]
        local b = W.get(x, P.y, z)
        if b and b.name == CANE then W.set(x, P.y, z, nil); caneAbove(x, P.y, z); addItem(CANE, 1); return true end
        return false
    end, digUp = function() return false end,
    digDown = function()
        local b = W.get(P.x, P.y - 1, P.z)
        if b and b.name == CANE then
            W.set(P.x, P.y - 1, P.z, nil); caneAbove(P.x, P.y - 1, P.z); addItem(CANE, 1); return true
        end
        if EQ.right == "minecraft:diamond_pickaxe" or EQ.left == "minecraft:diamond_pickaxe" then
            if not b or b.name == "minecraft:water" then return false end
            W.set(P.x, P.y - 1, P.z, nil); addItem(b.name == "minecraft:farmland" and "minecraft:dirt" or b.name, 1)
            return true
        end
        if b and RIPE[b.name] then
            W.set(P.x, P.y - 1, P.z, nil)
            local d = DROPS[b.name]
            if b.age >= RIPE[b.name] then addItem(d[1], 1) end
            addItem(d[2], 1)
            return true
        end
        local ty = P.y - 1
        if not b then ty = P.y - 2; b = W.get(P.x, ty, P.z) end   -- through the gap
        local TILL = { ["minecraft:dirt"] = true, ["minecraft:grass_block"] = true }
        if b and TILL[b.name] then W.set(P.x, ty, P.z, { name = "minecraft:farmland" }); return true end
        return false
    end,
    placeDown = function()
        local it = inv[sel]; if not it then return false end
        local x, y, z = P.x, P.y - 1, P.z
        local b = W.get(x, y, z)
        if it.name == CANE then
            local g = W.get(x, y - 1, z)
            local GROUND = { ["minecraft:sand"] = true, ["minecraft:dirt"] = true, ["minecraft:grass_block"] = true }
            if not b and g and GROUND[g.name] and waterBeside(x, y - 1, z) then
                W.set(x, y, z, { name = CANE }); useSel(); return true
            end
            return false
        elseif PLANT[it.name] then
            local g = W.get(x, y - 1, z)
            if not b and g and g.name == "minecraft:farmland" then
                W.set(x, y, z, { name = PLANT[it.name], age = 0 }); useSel(); return true
            end
            return false
        elseif it.name == "minecraft:dirt" then
            if passable(b) then W.set(x, y, z, { name = "minecraft:dirt" }); useSel(); return true end
        elseif it.name == "minecraft:water_bucket" then
            if passable(b) then W.set(x, y, z, { name = "minecraft:water" }); inv[sel] = { name = "minecraft:bucket", count = 1 }; return true end
        elseif it.name == "minecraft:bucket" then
            if b and b.name == "minecraft:water" and not b.level then
                if not regen(x, y, z) then W.set(x, y, z, nil) end
                useSel(); addItem("minecraft:water_bucket", 1); return true
            end
        end
        return false
    end,
    place = function()
        local it = inv[sel]; if not it or it.name ~= "minecraft:dirt" then return false end
        local x, z = P.x + DX[P.d], P.z + DZ[P.d]
        if passable(W.get(x, P.y, z)) then W.set(x, P.y, z, { name = "minecraft:dirt" }); useSel(); return true end
        return false
    end,
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
    suckDown = function(n)
        if not (P.x == 0 and P.z == 0 and P.y == 0) then return false end
        local c = chest[1]; if not c then return false end; n = math.min(n or 64, c.count); c.count = c.count - n; if c.count == 0 then table.remove(chest, 1) end; c = { name = c.name, count = n }
        addItem(c.name, c.count); return true
    end,
    dropDown = function(n)
        local it = inv[sel]; if not it then return false end
        n = math.min(n or it.count, it.count)
        if CHEST_CAP and #chest >= CHEST_CAP then return false end   -- one stack per slot, simplified
        chest[#chest + 1] = { name = it.name, count = n }
        it.count = it.count - n; if it.count == 0 then inv[sel] = nil end
        return true
    end,
    refuel = function() return false end,
    getFuelLevel = function() return "unlimited" end,
    equipLeft = function() local it = inv[sel]; inv[sel] = EQ.left and { name = EQ.left, count = 1 } or nil; EQ.left = it and it.name; return true end,
    equipRight = function() local it = inv[sel]; inv[sel] = EQ.right and { name = EQ.right, count = 1 } or nil; EQ.right = it and it.name; return true end,
    getEquippedLeft = function() return EQ.left and { name = EQ.left } end,
    getEquippedRight = function() return EQ.right and { name = EQ.right } end,
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
        local pos = 1
        return { readAll = function() return data end,
                 readLine = function()
                     if pos > #data then return nil end
                     local e = data:find("\n", pos) or #data + 1
                     local l = data:sub(pos, e - 1); pos = e + 1; return l
                 end,
                 close = function() end }
    end,
}
shell = { getRunningProgram = function() return "farm.lua" end }
peripheral = { wrap = function() return { list = function()
    local t = {}; for i, c in ipairs(chest) do t[i] = c end; return t end } end }
SLEEPS = 0
sleep = function(t)
    if t and t >= 30 then
        SLEEPS = SLEEPS + 1
        if SLEEPS == 2 then chest = {}; print("  [player empties the chest]") end
    end
end
os.pullEvent = function() error("blocked waiting for a key") end

local log = {}
local realPrint = print
print = function(...) local t = {}; for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end; log[#log + 1] = table.concat(t, " ") end

local function stock()
    if MIXED then
        chest = { { name = "minecraft:wheat_seeds", count = 64 }, { name = "minecraft:dirt", count = 64 },
                  { name = CANE, count = 16 }, { name = "minecraft:beetroot_seeds", count = 64 },
                  { name = "minecraft:water_bucket", count = 1 } }
        return
    end
    if NO_WATER_BUCKETS then
        chest = { { name = "minecraft:wheat_seeds", count = 64 }, { name = "minecraft:dirt", count = 64 } }
        return
    end
    chest = { { name = "minecraft:wheat_seeds", count = 64 }, { name = "minecraft:dirt", count = 64 },
              { name = "minecraft:water_bucket", count = 1 }, { name = "minecraft:water_bucket", count = 1 } }
end

local function run(...)
    log, moves = {}, 0
    package.loaded.turtlelib = nil
    local chunk = assert(loadfile(PROJ .. "/farm.lua"))
    local ok, err = pcall(chunk, ...)
    realPrint("== farm " .. table.concat({ ... }, " ") .. "  (moves: " .. moves .. ")")
    for _, l in ipairs(log) do realPrint("   " .. l) end
    if not ok then realPrint("   ERROR: " .. tostring(err)) end
    realPrint(string.format("   ends at (%d,%d,%d) facing %d", P.x, P.y, P.z, P.d))
end

local function show(label)
    realPrint("-- " .. label .. ": y=-2 / y=-1 by row z (x=1.." .. WIDTH .. ")")
    local S = { ["minecraft:farmland"] = "F", ["minecraft:water"] = "~", ["minecraft:dirt"] = "d", ["minecraft:sand"] = "s" }
    for z = LENGTH, 1, -1 do
        local g, c = {}, {}
        for x = 1, WIDTH do
            local b = W.get(x, -2, z); g[#g + 1] = b and (S[b.name] or "?") or " "
            local w = W.get(x, -1, z)
            local L = { ["minecraft:wheat"] = "w", ["minecraft:carrots"] = "c", ["minecraft:potatoes"] = "p", ["minecraft:beetroots"] = "b", [CANE] = "|" }
            c[#c + 1] = w and (L[w.name] or "?") or "."
        end
        realPrint("   z=" .. z .. "  " .. table.concat(g) .. "   " .. table.concat(c))
    end
end

MIXED = true
-- F1. learn the farm (no limits), then everything ripe
build(); stock()
run("5", "6", "0")
for x = 1, WIDTH do for z = 1, LENGTH do local b = W.get(x, -1, z); if b and RIPE[b.name] then b.age = RIPE[b.name] end end end
for z = 1, LENGTH do for h = 1, 3 do W.set(4, -2 + h, z, { name = CANE }) end end
-- F2. 11 slots of coal (kept as fuel), and a chest with room for only a few more stacks
inv = {}
for s = 1, 11 do inv[s] = { name = "minecraft:coal", count = 64 } end
stock()
CHEST_CAP = #chest + 3
SPILLED = 0
run("0")
realPrint("   spilled on the ground: " .. SPILLED .. "   waits: " .. SLEEPS)
-- F3. same, but the chest is already full
for x = 1, WIDTH do for z = 1, LENGTH do local b = W.get(x, -1, z); if b and RIPE[b.name] then b.age = RIPE[b.name] end end end
for z = 1, LENGTH do for h = 1, 3 do W.set(4, -2 + h, z, { name = CANE }) end end
inv = {}
for s = 1, 11 do inv[s] = { name = "minecraft:coal", count = 64 } end
stock()
CHEST_CAP = #chest
SPILLED, SLEEPS = 0, 0
run("0")
realPrint("   spilled on the ground: " .. SPILLED .. "   waits: " .. SLEEPS)
