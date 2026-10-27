-- sim/autocompost_with_chest.lua
--
-- autocompost.lua on a composter with a chest in front: composts what it
-- can and rejects the rest (cobblestone) into the chest.
--
-- Mock turtle on a composter with a hopper under it, for autocompost.lua.
local PROJ = ...
local CHANCE = { ["minecraft:wheat_seeds"] = 0.3, ["minecraft:carrot"] = 0.65 }
local inv, sel = {}, 1
local comp = { level = 0, ripeAt = nil }
local tick, bonemeal, front = 0, 0, {}
local rng = 12345
local function T_ONE(name) return name:find("_pickaxe$") or name:find("_hoe$") or name:find("_axe$") or name:find("_shovel$") or name:find("_sword$") or name:find("bucket$") end
local function rand() rng = (rng * 1103515245 + 12345) % 2147483648; return rng / 2147483648 end
local HAS_CHEST = true

local function advance(n)               -- the world moves on n ticks
    for _ = 1, n do
        tick = tick + 1
        if comp.level == 7 and comp.ripeAt and tick >= comp.ripeAt then comp.level = 8 end
        if comp.level == 8 and tick % 8 == 0 then comp.level = 0; bonemeal = bonemeal + 1 end
    end
end

turtle = {
    select = function(s) sel = s; return true end,
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
    inspectDown = function() advance(1); return true, { name = "minecraft:composter", state = { level = comp.level } } end,
    dropDown = function(n)
        advance(1)
        local it = inv[sel]
        if not it or not CHANCE[it.name] or comp.level >= 7 then return false end
        it.count = it.count - 1; if it.count == 0 then inv[sel] = nil end
        if rand() < CHANCE[it.name] then
            comp.level = comp.level + 1
            if comp.level == 7 then comp.ripeAt = tick + 20 end
        end
        return true
    end,
    drop = function()
        local it = inv[sel]; if not it then return false end
        front[#front + 1] = it; inv[sel] = nil; return true
    end,
}
peripheral = { wrap = function(side) if side == "front" and HAS_CHEST then return { list = function() return {} end } end end }
sleep = function(t) advance(math.max(1, math.floor((t or 0) * 20 + 0.5))) end
os.epoch = function() return tick * 50 end
local idle = 0
os.pullEvent = function(ev)
    idle = idle + 1
    error("IDLE", 0)
end

inv = { { name = "minecraft:wheat_seeds", count = 64 }, { name = "minecraft:cobblestone", count = 10 },
        { name = "minecraft:carrot", count = 20 }, nil, { name = "minecraft:wheat_seeds", count = 64 } }
local ok, err = pcall(assert(loadfile(PROJ .. "/autocompost.lua")))
print("stopped: " .. tostring(err))
local left = {}
for s = 1, 16 do if inv[s] then left[#left + 1] = inv[s].count .. " " .. inv[s].name end end
local fr = {}
for _, it in ipairs(front) do fr[#fr + 1] = it.count .. " " .. it.name end
print(string.format("ticks=%d (%.1fs)  bone meal out of hopper=%d  composter level=%d",
    tick, tick / 20, bonemeal, comp.level))
print("left in turtle: " .. (#left > 0 and table.concat(left, ", ") or "nothing"))
print("in front chest: " .. (#fr > 0 and table.concat(fr, ", ") or "nothing"))
