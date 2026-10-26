-- sim/farm_clone.lua
--
-- Learn a 7x16 farm with two lanes, wipe it back to grass and run
-- `farm clone`.  Reports moves, buckets scooped and poured, and any lane
-- tile that didn't end up a water source.  Models vanilla infinite water.
--
-- Minimal CC:Tweaked world + turtle mock for exercising farm.lua.
-- Turtle starts at (0,0,0) facing +z; farmland at y=-2, crops at y=-1.
local PROJ = ...
package.path = PROJ .. "/?.lua;" .. package.path

local W = {}                         -- world["x,y,z"] = { name=, age= }
local function k(x, y, z) return x .. "," .. y .. "," .. z end
function W.get(x, y, z) return W[k(x, y, z)] end
function W.set(x, y, z, b) W[k(x, y, z)] = b end

local WIDTH, LENGTH, LANE_X = 7, 16, 3
LANES = { [3] = true, [6] = true }
local PLANT = { ["minecraft:wheat_seeds"] = "minecraft:wheat", ["minecraft:carrot"] = "minecraft:carrots",
                ["minecraft:potato"] = "minecraft:potatoes", ["minecraft:beetroot_seeds"] = "minecraft:beetroots" }
local RIPE = { ["minecraft:wheat"] = 7, ["minecraft:carrots"] = 7, ["minecraft:potatoes"] = 7, ["minecraft:beetroots"] = 3 }
local DROPS = { ["minecraft:wheat"] = { "minecraft:wheat", "minecraft:wheat_seeds" },
                ["minecraft:carrots"] = { "minecraft:carrot", "minecraft:carrot" },
                ["minecraft:potatoes"] = { "minecraft:potato", "minecraft:potato" },
                ["minecraft:beetroots"] = { "minecraft:beetroot", "minecraft:beetroot_seeds" } }
COLCROP = { [1] = "minecraft:wheat", [2] = "minecraft:wheat", [4] = "minecraft:wheat", [5] = "minecraft:wheat", [7] = "minecraft:wheat" }
local function build()
    for key in pairs(W) do if type(W[key]) == "table" then W[key] = nil end end
    W.set(0, -1, 0, { name = "minecraft:chest" })
    for x = 0, WIDTH + 1 do
        for z = 0, LENGTH + 1 do
            W.set(x, -3, z, { name = "minecraft:dirt" })
            local inside = x >= 1 and x <= WIDTH and z >= 1 and z <= LENGTH
            if not inside then
                if not (x == 0 and z == 0) then W.set(x, -2, z, { name = "minecraft:grass_block" }) end
            elseif LANES[x] then
                W.set(x, -2, z, { name = "minecraft:water" })
            else
                W.set(x, -2, z, { name = "minecraft:farmland" })
                local c = COLCROP[x]
                W.set(x, -1, z, { name = c, age = (x + z) % 2 == 0 and RIPE[c] or 1 })
            end
        end
    end
end

local P = { x = 0, y = 0, z = 0, d = 0 }
-- vanilla infinite water: an empty cell with a solid floor and two source
-- neighbours becomes a source (only the farm's lane level matters here)
function FLUIDS()
    local changed = true
    while changed do
        changed = false
        for x = 0, WIDTH + 1 do for z = 0, LENGTH + 1 do
            if not W.get(x, -2, z) and W.get(x, -3, z) then
                local n = 0
                for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                    local b = W.get(x + d[1], -2, z + d[2])
                    if b and b.name == "minecraft:water" and not b.level then n = n + 1 end
                end
                if n >= 2 then W.set(x, -2, z, { name = "minecraft:water" }); changed = true end
            end
        end end
    end
end
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = 1, 0, -1, 0 }
local moves = 0
local inv, sel = {}, 1
EQ = { right = "minecraft:diamond_hoe" }
local chest = {}

function STACK(name) return (name == "minecraft:water_bucket") and 1 or (name == "minecraft:bucket") and 16 or 64 end
local function addItem(name, n)
    local max = (name == "minecraft:water_bucket") and 1 or (name == "minecraft:bucket") and 16 or 64
    for s = 1, 16 do
        if inv[s] and inv[s].name == name and inv[s].count < max then
            local take = math.min(n, max - inv[s].count); inv[s].count = inv[s].count + take; n = n - take
        end
        if n == 0 then return true end
    end
    for s = 1, 16 do
        if not inv[s] then inv[s] = { name = name, count = math.min(n, max) }; n = n - inv[s].count end
        if n == 0 then return true end
    end
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
    dig = function() return false end, digUp = function() return false end,
    digDown = function()
        local b = W.get(P.x, P.y - 1, P.z)
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
        if it.name == "minecraft:bone_meal" then
            if not (b and RIPE[b.name]) or b.age >= RIPE[b.name] then return false end
            if b.name == "minecraft:beetroots" then
                if math.random(4) > 1 then b.age = b.age + 1 end
            else
                b.age = math.min(RIPE[b.name], b.age + math.random(2, 5))
            end
            useSel(); MEAL = (MEAL or 0) + 1
            return true
        elseif PLANT[it.name] then
            local g = W.get(x, y - 1, z)
            if not b and g and g.name == "minecraft:farmland" then
                W.set(x, y, z, { name = PLANT[it.name], age = 0 }); useSel(); return true
            end
            return false
        elseif it.name == "minecraft:dirt" then
            if passable(b) then W.set(x, y, z, { name = "minecraft:dirt" }); useSel(); return true end
        elseif it.name == "minecraft:water_bucket" then
            if passable(b) then W.set(x, y, z, { name = "minecraft:water" }); inv[sel] = { name = "minecraft:bucket", count = 1 }; POURS = (POURS or 0) + 1; FIRSTPOUR = FIRSTPOUR or moves; LASTPOUR = moves; FLUIDS(); return true end
        elseif it.name == "minecraft:bucket" then
            if b and b.name == "minecraft:water" and not b.level then
                if not regen(x, y, z) then W.set(x, y, z, nil) end
                SCOOPS = (SCOOPS or 0) + 1
                -- the filled bucket replaces a lone empty one, else needs a slot
                if inv[sel].count == 1 then inv[sel] = { name = "minecraft:water_bucket", count = 1 }; return true end
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
    suckDown = function(n)
        if not (P.x == 0 and P.z == 0 and P.y == 0) then return false end
        local slot
        for s = 1, 27 do if chest[s] then slot = s; break end end
        if not slot then return false end
        local c = chest[slot]
        n = math.min(n or 64, c.count)
        -- CC stores starting at the selected slot, merging or filling the first that fits
        local left = n
        for i = 0, 15 do
            local s = (sel - 1 + i) % 16 + 1
            local it = inv[s]
            local max = STACK(c.name)
            if not it then local take = math.min(left, max); inv[s] = { name = c.name, count = take }; left = left - take
            elseif it.name == c.name and it.count < max then
                local take = math.min(left, max - it.count); it.count = it.count + take; left = left - take
            end
            if left == 0 then break end
        end
        local moved = n - left
        if moved == 0 then return false end
        c.count = c.count - moved; if c.count == 0 then chest[slot] = nil end
        return true
    end,
    drop = function(n)
        local it = inv[sel]; if not it then return false end
        local b = W.get(P.x + DX[P.d], P.y, P.z + DZ[P.d])
        if not (b and b.name == "minecraft:hopper") then return false end
        local room = 320 - HOPPER
        n = math.min(n or it.count, it.count, room)
        if n <= 0 then return false end
        HOPPER = HOPPER + n; HOPPED[it.name] = (HOPPED[it.name] or 0) + n
        it.count = it.count - n; if it.count == 0 then inv[sel] = nil end
        return true
    end,
    dropDown = function(n)
        local it = inv[sel]; if not it then return false end
        n = math.min(n or it.count, it.count)
        local left = n
        for s = 1, 27 do
            local c = chest[s]
            if not c then chest[s] = { name = it.name, count = left }; left = 0
            elseif c.name == it.name and c.count < 64 then
                local take = math.min(left, 64 - c.count); c.count = c.count + take; left = left - take
            end
            if left == 0 then break end
        end
        it.count = it.count - (n - left); if it.count == 0 then inv[sel] = nil end
        return left < n
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
peripheral = { wrap = function(side)
    if side == "back" then
        local b = W.get(P.x - DX[P.d], P.y, P.z - DZ[P.d])
        if not (b and b.name == "minecraft:hopper") then return nil end
        return { size = function() return 5 end,
                 list = function() local t = {}; for i = 1, math.ceil(HOPPER / 64) do t[i] = { name = "x", count = 64 } end; return t end }
    end
    return {
        size = function() return 27 end,
        getItemDetail = function(slot) local c = chest[slot]; return c and { name = c.name, count = c.count, maxCount = STACK(c.name) } end,
        list = function() local t = {}; for s = 1, 27 do if chest[s] then t[s] = { name = chest[s].name, count = chest[s].count } end end; return t end,
        pushItems = function(to, from, limit, toSlot)
            assert(to == "bottom", "push to " .. tostring(to))
            local c = chest[from]; if not c then return 0 end
            local d = chest[toSlot]
            if d and d.name ~= c.name then return 0 end
            local n = math.min(limit or 64, c.count, STACK(c.name) - (d and d.count or 0))
            if d then d.count = d.count + n else chest[toSlot] = { name = c.name, count = n } end
            c.count = c.count - n; if c.count == 0 then chest[from] = nil end
            PUSHES = (PUSHES or 0) + 1
            return n
        end,
    } end, getName = function() return "bottom" end }
CLOCK = 0
os.clock = function() return CLOCK end
STOP_AT = nil
sleep = function(t)
    t = t or 0
    CLOCK = CLOCK + t
    HOPPER = math.max(0, HOPPER - 2.5 * t)          -- the composter drains it
    if STOP_AT and CLOCK > STOP_AT then error("STOP", 0) end
end
os.pullEvent = function() error("blocked waiting for a key") end

local log = {}
local realPrint = print
print = function(...) local t = {}; for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end; log[#log + 1] = table.concat(t, " ") end

local function stock()
    if MIXED then
        chest = { { name = "minecraft:wheat_seeds", count = 64 }, { name = "minecraft:dirt", count = 64 },
                  { name = "minecraft:carrot", count = 64 }, { name = "minecraft:beetroot_seeds", count = 64 },
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
    local S = { ["minecraft:farmland"] = "F", ["minecraft:water"] = "~", ["minecraft:dirt"] = "d" }
    for z = LENGTH, 1, -1 do
        local g, c = {}, {}
        for x = 1, WIDTH do
            local b = W.get(x, -2, z); g[#g + 1] = b and (S[b.name] or "?") or " "
            local w = W.get(x, -1, z)
            local L = { ["minecraft:wheat"] = "w", ["minecraft:carrots"] = "c", ["minecraft:potatoes"] = "p", ["minecraft:beetroots"] = "b" }
            c[#c + 1] = w and (L[w.name] or "?") or "."
        end
        realPrint("   z=" .. z .. "  " .. table.concat(g) .. "   " .. table.concat(c))
    end
end

MIXED = true
HOPPER, HOPPED = 0, {}
local function chestTotals()
    local c = {}; for s = 1, 27 do local it = chest[s]; if it then c[it.name] = (c[it.name] or 0) + it.count end end
    local cs = {}; for n, v in pairs(c) do cs[#cs + 1] = v .. " " .. n:gsub("minecraft:", "") end
    table.sort(cs); return table.concat(cs, ", ")
end
local function hopped()
    local cs = {}; for n, v in pairs(HOPPED) do cs[#cs + 1] = v .. " " .. n:gsub("minecraft:", "") end
    table.sort(cs); return table.concat(cs, ", ")
end
build()
W.set(0, 0, -1, { name = "minecraft:hopper" })      -- directly behind home
chest = {}
for i = 1, 6 do chest[#chest + 1] = { name = "minecraft:wheat", count = 64 } end
for i = 1, 3 do chest[#chest + 1] = { name = "minecraft:bone_meal", count = 64 } end
for i = 1, 6 do chest[#chest + 1] = { name = "minecraft:wheat_seeds", count = 64 } end
chest[#chest + 1] = { name = "minecraft:dirt", count = 64 }
for i = 1, 3 do chest[#chest + 1] = { name = "minecraft:carrot", count = 64 } end
for i = 1, 2 do chest[#chest + 1] = { name = "minecraft:beetroot_seeds", count = 64 } end
math.randomseed(42)
local function lanesOk()
    local bad = 0
    for x in pairs(LANES) do for z = 1, LENGTH do
        local b = W.get(x, -2, z)
        if not (b and b.name == "minecraft:water" and not b.level) then bad = bad + 1 end
    end end
    local crops = 0
    for x = 1, WIDTH do for z = 1, LENGTH do
        local b = W.get(x, -1, z); if b and RIPE[b.name] then crops = crops + 1 end
    end end
    return bad, crops
end
chest = {}
chest[1] = { name = "minecraft:wheat_seeds", count = 64 }
chest[2] = { name = "minecraft:wheat_seeds", count = 64 }
chest[3] = { name = "minecraft:dirt", count = 64 }
chest[4] = { name = "minecraft:water_bucket", count = 1 }
chest[5] = { name = "minecraft:water_bucket", count = 1 }
chest[6] = { name = "minecraft:bucket", count = 4 }
inv = { { name = "minecraft:diamond_pickaxe", count = 1 } }
run("7", "16", "0")
-- wipe the farm back to grass, keep the dirt floor
for x = 1, WIDTH do for z = 1, LENGTH do
    W.set(x, -2, z, { name = "minecraft:grass_block" }); W.set(x, -1, z, nil)
end end
SCOOPS, POURS, FIRSTPOUR, LASTPOUR = 0, 0, nil, nil
run("clone", "0")
local bad, crops = lanesOk()
realPrint(string.format("WATER PHASE: %d moves from first to last pour", (LASTPOUR or 0) - (FIRSTPOUR or 0)))
realPrint(string.format("CLONE: moves=%d scoops=%d pours=%d bad lane tiles=%d crops=%d spilled=%s",
    moves, SCOOPS, POURS or 0, bad, crops, tostring(SPILLED or 0)))
