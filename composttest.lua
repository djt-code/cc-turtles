-- composttest.lua -- how fast can a turtle feed a composter?
--
-- Put the turtle directly on top of a composter that has a hopper under
-- it (the hopper takes the bone meal out), with seeds in the turtle.  It
-- drops them in one at a time (dropDown only ever takes one) until it has
-- none left, retrying every tick while the composter is full, then prints
-- the timings.
--
-- Usage: composttest [item]      (default: wheat_seeds)

local ITEM = ... or "wheat_seeds"
if not ITEM:find(":") then ITEM = "minecraft:" .. ITEM end
local STALL = 10           -- seconds without an accepted drop before giving up

local function now() return os.epoch("utc") / 1000 end

local function composterLevel()
    local ok, d = turtle.inspectDown()
    if ok and d.name == "minecraft:composter" then return d.state.level end
end

local function selectItem()
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and it.name == ITEM then turtle.select(s); return true end
    end
    return false
end

if not composterLevel() then error("No composter directly below the turtle", 0) end
if not selectItem() then error("No " .. ITEM .. " in the turtle", 0) end
local total = 0
for s = 1, 16 do
    local it = turtle.getItemDetail(s)
    if it and it.name == ITEM then total = total + it.count end
end
print(string.format("Feeding %d %s, starting at level %d", total, ITEM, composterLevel()))

local start = now()
local dropped, refused, cycles, waited = 0, 0, 0, 0
local lastOk, waitStart = start, nil
while selectItem() do
    if turtle.dropDown(1) then
        dropped = dropped + 1
        lastOk = now()
        if waitStart then waited = waited + (lastOk - waitStart); waitStart = nil end
    else
        refused = refused + 1
        if not waitStart then
            waitStart = now()
            cycles = cycles + 1
            print(string.format("  %d dropped, %.2fs: composter full (level %s), waiting",
                dropped, waitStart - start, tostring(composterLevel())))
        end
        if now() - lastOk > STALL then
            print("No drop accepted for " .. STALL .. "s; stopping. Is the hopper full or missing?")
            break
        end
        sleep(0.05)
    end
end
local elapsed = now() - start
if waitStart then waited = waited + (now() - waitStart) end

print(string.format("Dropped %d in %.2fs: %.1f items/s overall", dropped, elapsed,
    dropped / math.max(elapsed, 0.001)))
print(string.format("Feeding only: %.2fs, %.1f items/s (%.3fs per drop)",
    elapsed - waited, dropped / math.max(elapsed - waited, 0.001),
    (elapsed - waited) / math.max(dropped, 1)))
print(string.format("Waited on a full composter %d times, %.2fs total (%.2fs each); %d refused drops",
    cycles, waited, waited / math.max(cycles, 1), refused))
print(string.format("Ends at level %s", tostring(composterLevel())))
