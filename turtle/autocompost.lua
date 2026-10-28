-- autocompost.lua -- a turtle that sits on a composter and composts
-- everything compostable you give it
--
-- Put the turtle directly on top of a composter, with a hopper under the
-- composter to take the bone meal out.  Fill the turtle with anything: it
-- drops each compostable item in one at a time (dropDown only ever takes
-- one), waits while the composter is full, and sleeps until its inventory
-- changes when there's nothing left to compost.  It never moves.
--
-- What's compostable is learned, not listed, so modded items work too: an
-- item the composter refuses while it isn't full is not compostable.
-- Those go into a chest in front of the turtle if there is one, otherwise
-- they stay in the turtle.
--
-- Usage: autocompost
-- To start it at boot:  echo "shell.run('autocompost')" >> /startup.lua

local STALL = 10           -- seconds full before asking about the hopper

local function now() return os.epoch("utc") / 1000 end

-- Level of the composter below (0-8), or nil if there isn't one.
local function level()
    local ok, d = turtle.inspectDown()
    if ok and d.name == "minecraft:composter" then return d.state.level end
end

-- Is there an inventory in front to put rejects in?
local function rejectChest()
    local p = peripheral.wrap("front")
    return p ~= nil and p.list ~= nil
end

if not level() then error("No composter directly below the turtle", 0) end

local rejected = {}        -- item names the composter won't take
local composted, fills = 0, 0
local reported = 0         -- `composted` when we last printed a summary
local fullSince, warned = nil, false

-- First slot holding something not known to be uncompostable.
local function nextSlot()
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and not rejected[it.name] then return s, it.name end
    end
end

-- Put known rejects into the chest in front, if there is one.
local function moveRejects()
    if not rejectChest() then return end
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and rejected[it.name] then
            turtle.select(s)
            turtle.drop()
        end
    end
end

local function reject(name)
    rejected[name] = true
    print(name .. " isn't compostable; " ..
        (rejectChest() and "putting it in the chest in front." or "leaving it in the turtle."))
    moveRejects()
end

print("Composting into the composter below (level " .. level() .. "). Ctrl+T to stop.")
while true do
    local slot, name = nextSlot()
    if not slot then
        if composted > reported then
            print(string.format("Composted %d items, about %d bone meal so far. Waiting for more.",
                composted, fills))
            reported = composted
        end
        os.pullEvent("turtle_inventory")
    else
        turtle.select(slot)
        if turtle.dropDown(1) then
            composted = composted + 1
            fullSince, warned = nil, false
        else
            local lv = level()
            if not lv then error("The composter below is gone", 0) end
            if lv >= 7 then
                -- full: it turns to bone meal, then the hopper empties it
                if not fullSince then fullSince = now(); fills = fills + 1 end
                if not warned and now() - fullSince > STALL then
                    warned = true
                    print("The composter has been full for " .. STALL ..
                        "s. Is the hopper below it full or missing?")
                end
                sleep(0.05)
            elseif turtle.dropDown(1) then
                composted = composted + 1       -- it had just been emptied
                fullSince, warned = nil, false
            else
                reject(name)
            end
        end
    end
end
