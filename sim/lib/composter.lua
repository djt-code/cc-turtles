-- sim/lib/composter.lua -- a turtle sitting on a composter, for
-- autocompost.lua: the composter fills by chance with what's compostable,
-- turns to bone meal when full and is emptied by the hopper under it; a
-- chest in front takes the rejects, if there is one.  The turtle never
-- moves, so there's no world: just its inventory and the clock, in ticks
-- (an inspect or a drop takes one, a sleep its length).
--
--     local C = require("composter")
--     C.HAS_CHEST = true
--     C.inv = { { name = "minecraft:wheat_seeds", count = 64 } }
--     C.run()                      -- until the program waits for new items
--
-- Knobs: C.HAS_CHEST (a chest in front), C.HOPPER_STOPS_AT (the hopper
-- under the composter stops taking bone meal at this tick: it backs up),
-- C.GIVE_UP_AT (a sleep past this tick ends the run with "STUCK").
-- Counters: C.tick, C.bonemeal (out of the hopper), C.front (what went in
-- the chest), C.level (the composter's).

local M = require("mock")
local C = M.state()
C.print = M.realPrint

local CHANCE = { ["minecraft:wheat_seeds"] = 0.3, ["minecraft:carrot"] = 0.65 }
C.HAS_CHEST = true
C.HOPPER_STOPS_AT = nil
C.tick, C.bonemeal, C.front = 0, 0, {}
local comp = { level = 0, ripeAt = nil }
local rng = 12345
local function rand() rng = (rng * 1103515245 + 12345) % 2147483648; return rng / 2147483648 end

-- The world moves on n ticks: a full composter ripens, the hopper empties it.
local function advance(n)
    for _ = 1, n do
        C.tick = C.tick + 1
        if comp.level == 7 and comp.ripeAt and C.tick >= comp.ripeAt then comp.level = 8 end
        if comp.level == 8 and C.tick % 8 == 0 and not (C.HOPPER_STOPS_AT and C.tick >= C.HOPPER_STOPS_AT) then
            comp.level = 0
            C.bonemeal = C.bonemeal + 1
        end
    end
end
function C.level() return comp.level end

turtle = M.merge(M.inventoryApi(C), {
    inspectDown = function()
        advance(1)
        return true, { name = "minecraft:composter", state = { level = comp.level } }
    end,
    dropDown = function()
        advance(1)
        local it = C.inv[C.sel]
        if not it or not CHANCE[it.name] or comp.level >= 7 then return false end
        M.useSel(C)
        if rand() < CHANCE[it.name] then
            comp.level = comp.level + 1
            if comp.level == 7 then comp.ripeAt = C.tick + 20 end
        end
        return true
    end,
    drop = function()
        local it = C.inv[C.sel]
        if not it then return false end
        C.front[#C.front + 1] = it
        C.inv[C.sel] = nil
        return true
    end,
})
peripheral = {
    wrap = function(side)
        if side == "front" and C.HAS_CHEST then return { list = function() return {} end } end
    end,
}
sleep = function(t)
    if C.GIVE_UP_AT and C.tick > C.GIVE_UP_AT then error("STUCK", 0) end
    advance(math.max(1, math.floor((t or 0) * 20 + 0.5)))
end
os.epoch = function() return C.tick * 50 end
-- the program waiting for its inventory to change is where a run ends
os.pullEvent = function() error("IDLE", 0) end

-- Run autocompost.lua until it waits, and report: what stopped it, the
-- time it took, the bone meal, what's left in the turtle and the chest.
function C.run(proj)
    local ok, err = pcall(assert(loadfile(proj .. "/turtle/autocompost.lua")))
    print("stopped: " .. tostring(err))
    local left = {}
    for s = 1, 16 do if C.inv[s] then left[#left + 1] = C.inv[s].count .. " " .. C.inv[s].name end end
    local fr = {}
    for _, it in ipairs(C.front) do fr[#fr + 1] = it.count .. " " .. it.name end
    print(string.format("ticks=%d (%.1fs)  bone meal out of hopper=%d  composter level=%d",
        C.tick, C.tick / 20, C.bonemeal, comp.level))
    print("left in turtle: " .. (#left > 0 and table.concat(left, ", ") or "nothing"))
    print("in front chest: " .. (#fr > 0 and table.concat(fr, ", ") or "nothing"))
    return ok, err
end

return C
