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
-- back); a tunnel with no length that runs out of chests, then
-- `mine --resume` once more chests are added (twice: the second time a
-- home holds more valuables than fit, and the most valuable come back);
-- bedrock; running short of fuel; `mine reset` from inside a vein; and a
-- tunnel to the left and down.
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
    local b = get(x, y, z)
    if not b or passable(b) or b.inv or b.name == "minecraft:bedrock" then return false end
    set(x, y, z, nil)
    if TRAVELLING then TRAVEL_DIGS = (TRAVEL_DIGS or 0) + 1 end
    addItem(DROP[b.name] or b.name, 1)
    gravity(x, y, z)
    return true
end
local function placeAt(x, y, z)
    local it = inv[sel]; if not it then return false end
    if not passable(get(x, y, z)) then return false end
    if it.name:find("raw_") or FUEL_VALUE[it.name] or it.name == "minecraft:diamond"
        or it.name == "minecraft:emerald" then return false end
    if it.name == "minecraft:chest" then set(x, y, z, chest())
    else set(x, y, z, { name = it.name }) end
    it.count = it.count - 1; if it.count == 0 then inv[sel] = nil end
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
local function above() return P.x, P.y + 1, P.z end
local function below() return P.x, P.y - 1, P.z end

turtle = {
    forward = function() return move(DX[P.d], 0, DZ[P.d]) end,
    back = function() return move(-DX[P.d], 0, -DZ[P.d]) end,
    up = function() return move(0, 1, 0) end,
    down = function() return move(0, -1, 0) end,
    turnRight = function() P.d = (P.d + 1) % 4; turns = turns + 1; return true end,
    turnLeft = function() P.d = (P.d + 3) % 4; turns = turns + 1; return true end,
    inspect = function() return inspectAt(front()) end,
    inspectUp = function() return inspectAt(above()) end,
    inspectDown = function() return inspectAt(below()) end,
    detect = function() return not passable(get(front())) end,
    detectUp = function() return not passable(get(above())) end,
    detectDown = function() return not passable(get(below())) end,
    dig = function() return digAt(front()) end,
    digUp = function() return digAt(above()) end,
    digDown = function() return digAt(below()) end,
    place = function() return placeAt(front()) end,
    placeUp = function() return placeAt(above()) end,
    placeDown = function() return placeAt(below()) end,
    attack = function() return false end, attackUp = function() return false end, attackDown = function() return false end,
    select = function(s) sel = s; return true end,
    getSelectedSlot = function() return sel end,
    getItemCount = function(s) return inv[s or sel] and inv[s or sel].count or 0 end,
    getItemDetail = function(s) local it = inv[s or sel]; return it and { name = it.name, count = it.count } end,
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
    getEquippedLeft = function() return nil end,
    getEquippedRight = function() return { name = "minecraft:diamond_pickaxe" } end,
}
peripheral = {
    wrap = function(side)
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
    log, moves, turns = {}, 0, 0
    package.loaded.turtlelib = nil
    local chunk = assert(loadfile(PROJ .. "/mine.lua"))
    local ok, err = pcall(chunk, ...)
    realPrint("== mine " .. table.concat({ ... }, " ") .. "  (moves: " .. moves .. ", turns: " .. turns .. ")")
    for _, l in ipairs(log) do
        if not l:find("^Segment ") then realPrint("   " .. l) end
    end
    if not ok then realPrint("   ERROR: " .. tostring(err)) end
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
local SUPPLY = { chest = true, coal = true }

local function startAt() P.x, P.y, P.z, P.d = 0, 0, 0, 0 end
local function atStart() return P.x == 0 and P.y == 0 and P.z == 0 and P.d == 0 end
local function stock(chests, coal)
    local t = {}
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
check("back at the start", atStart())
check("never moved on an empty tank", DRY == 0, "tried " .. DRY)
check("nothing spilled", (SPILLED or 0) == 0, tostring(SPILLED or 0))
check("job done", jobState() == "done", tostring(jobState()))

-- 2. 50 long with homes every 16: supplies go forward, valuables come back
setup(stock(8, 128)); features()
set(-1, 1, 20, ore("minecraft:diamond_ore"))       -- in the wall near home 1
set(3, 0, 40, ore("minecraft:emerald_ore"))        -- in the wall near home 2
remember()
startAt(); inv, files = {}, {}
FUEL, LOWEST, DRY, SPILLED, TRAVEL_DIGS = 200, 200, 0, 0, 0
run("3", "3", "50", "--spacing", "16")
check("tunnel clear", leftIn(0, 2, 0, 2, 1, 50) == 0, leftIn(0, 2, 0, 2, 1, 50) .. " blocks left")
checkOres(); checkLava(50)
local tn = checkStart()
check("diamonds and emerald brought back", (tn["minecraft:diamond"] or 0) == 3 and (tn["minecraft:emerald"] or 0) == 1,
    (tn["minecraft:diamond"] or 0) .. " diamond, " .. (tn["minecraft:emerald"] or 0) .. " emerald")
checkHomes(16, 3)
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

-- 7. stopped inside a vein (a server restart): `mine reset` digs back to
--    the tunnel and goes home
files["mine.job"] = "3 3 12 64 0 active"
P.x, P.y, P.z, P.d = -3, 1, 4, 3
files[".turtlepos"] = "-3 1 4 3 flat"
FUEL = 500
run("reset")
check("reset from a vein got home", atStart())

-- 8. a tunnel to the left and down: `mine -2 -2 6`
setup(stock(4, 64)); features()
startAt(); inv, files = {}, {}
FUEL, DRY = 1000, 0
run("-2", "-2", "6")
check("left-and-down tunnel clear", leftIn(-1, 0, -1, 0, 1, 6) == 0, leftIn(-1, 0, -1, 0, 1, 6) .. " blocks left")
check("nothing dug right of or above it", get(1, 0, 3) ~= nil and get(0, 1, 3) ~= nil)
check("back at the start", atStart())
