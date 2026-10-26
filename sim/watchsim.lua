-- watchsim.lua -- play a farm simulator out on a monitor, move by move
--
-- Usage:
--   sim/watchsim                    list the simulators it can show
--   sim/watchsim <name> [monitor]   e.g. sim/watchsim farm_clone
--
-- Needs an Advanced Computer (or turtle) with the repo and an Advanced
-- Monitor, at least 3 blocks wide by 2 tall, attached to it directly or
-- through wired modems; give the monitor's name when there's more than
-- one.  The monitor shows:
--   * top-down view of the farm (+z up, +x right), the turtle in yellow
--   * side view: a slice through the turtle's column x (z across, y up)
--   * the turtle's moves, position, facing and fuel, and the farm's own
--     messages as it prints them
-- The computer's screen shows the simulator's report.
--
-- Keys on the computer (or tap the monitor to pause/resume):
--   space   pause / resume          right   one move, while paused
--   up      faster                  down    slower
--   f       skip to the end of this farm run
--   q       quit

local realFs, realOs, realPrint = fs, os, print
local here = realFs.getDir(shell.getRunningProgram())
local root = realFs.getDir(here)
local S = dofile(realFs.combine(here, "lib/sandbox.lua"))

local args = { ... }
if not args[1] then
    print("Usage: watchsim <name> [monitor]   (farm simulators only)")
    for _, n in ipairs(S.list(here)) do
        if n:find("^farm_") then print("  " .. n) end
    end
    return
end
local name = args[1]:gsub("%.lua$", "")
local path = realFs.combine(here, name .. ".lua")
if not realFs.exists(path) then printError("No simulator " .. name); return end
do
    local f = realFs.open(path, "r")
    local src = f.readAll()
    f.close()
    if not src:find("SIM_WORLD", 1, true) then
        printError(name .. " has no world to show; watchsim shows the farm_* simulators.")
        return
    end
end
local mon = args[2] and peripheral.wrap(args[2]) or peripheral.find("monitor")
if not mon then printError("No monitor found. Attach an Advanced Monitor (3x2 blocks or more)."); return end
if not mon.isColor() then print("This monitor has no colour: use an Advanced Monitor for a readable view.") end
mon.setTextScale(0.5)

--------------------------------------------------------------------------
-- What each block looks like: two characters, text colour, background
-- (blit colour codes: 0 white, 1 orange, 3 light blue, 4 yellow, 5 lime,
-- 7 gray, 8 light gray, b blue, c brown, d green, f black)
--------------------------------------------------------------------------
local CROP = {
    ["minecraft:wheat"] = { "w", 7 }, ["minecraft:carrots"] = { "c", 7 },
    ["minecraft:potatoes"] = { "p", 7 }, ["minecraft:beetroots"] = { "b", 3 },
}
local function glyph(b)
    if not b then return "  ", "0", "f" end
    local n = b.name
    if n == "minecraft:water" then
        if b.level then return "~" .. (b.level % 10), "b", "3" end   -- flowing
        return "~~", "3", "b"                                         -- source
    end
    local crop = CROP[n]
    if crop then
        local age = b.age or 0
        return crop[1] .. age, "f", age >= crop[2] and "5" or "d"     -- lime once ripe
    end
    if n == "minecraft:farmland" then return "::", "1", "c" end
    if n == "minecraft:dirt" then return "  ", "c", "c" end
    if n == "minecraft:grass_block" then return "  ", "d", "d" end
    if n == "minecraft:sand" then return "..", "4", "0" end
    if n == "minecraft:sugar_cane" then return "||", "d", "5" end
    if n:find("chest") then return "[]", "f", "1" end
    if n == "minecraft:hopper" then return "\\/", "0", "7" end
    if n:find("stone") or n:find("cobble") then return "##", "8", "7" end
    return n:gsub("^.-:", ""):sub(1, 2), "f", "8"
end
local TOP_ARROW = { [0] = "^^", ">>", "vv", "<<" }      -- +z is up the screen
local SIDE_ARROW = { [0] = ">>", "+x", "<<", "-x" }     -- +z is to the right
local Y_TOP, Y_BOTTOM = 3, -3                           -- side view's height range

--------------------------------------------------------------------------
-- Layout: top view left, side view right with status and messages under
-- it; or, on a narrow monitor, everything stacked.
--------------------------------------------------------------------------
-- Monitor size in characters at text scale 0.5 for a given size in blocks
-- (CC:Tweaked's own formula), and the blocks needed for a size in chars.
local function charsFor(bw, bh)
    return math.floor((bw - 0.3125) * 64 / 3 + 0.5), math.floor((bh - 0.3125) * 64 / 4.5 + 0.5)
end
local function blocksFor(cols, rows)
    local bw, bh = 1, 1
    while select(1, charsFor(bw, 1)) < cols do bw = bw + 1 end
    while select(2, charsFor(1, bh)) < rows do bh = bh + 1 end
    return bw, bh
end

local L                 -- the layout, worked out once the world is known
local function layout(world)
    local mw, mh = mon.getSize()
    local topW, topH = 2 * (world.width + 2), world.length + 3
    local sideW, sideH = 2 * (world.length + 3), Y_TOP - Y_BOTTOM + 1
    local MIN_TEXT = 6              -- status lines plus a few messages
    -- side by side
    local w = topW + 1 + sideW
    local h = 1 + math.max(1 + topH, 1 + sideH + MIN_TEXT)
    if w <= mw and h <= mh then
        return { top = { 1, 3 }, side = { topW + 2, 3 }, text = { topW + 2, 3 + sideH + 1 },
                 textW = mw - topW - 1, textH = mh - (3 + sideH), topW = topW, topH = topH,
                 sideW = sideW, sideH = sideH }
    end
    -- stacked
    local sw = math.max(topW, sideW)
    local sh = 1 + 1 + topH + 1 + sideH + MIN_TEXT
    if sw <= mw and sh <= mh then
        return { top = { 1, 3 }, side = { 1, 3 + topH + 1 }, text = { 1, 3 + topH + 1 + sideH },
                 textW = mw, textH = mh - (2 + topH + 1 + sideH), topW = topW, topH = topH,
                 sideW = sideW, sideH = sideH }
    end
    local bw, bh = blocksFor(w, h)
    error(string.format("Monitor too small for %s: %dx%d characters, needs %dx%d. " ..
        "Build an Advanced Monitor at least %d wide x %d tall.", name, mw, mh, w, h, bw, bh), 0)
end

local function put(x, y, text, fg, bg)
    mon.setCursorPos(x, y)
    mon.blit(text, fg, bg)
end
local function line(x, y, w, s, fg, bg)
    s = (s .. string.rep(" ", w)):sub(1, w)
    put(x, y, s, string.rep(fg or "0", w), string.rep(bg or "f", w))
end

--------------------------------------------------------------------------
-- State shown besides the world
--------------------------------------------------------------------------
local env
local SPEEDS = { 0, 0.05, 0.1, 0.2, 0.5, 1 }   -- seconds per move (0: as fast as it draws)
local speed = 3
local paused, skipping, quitting = false, false, false
local fatal                     -- why it stopped, when that wasn't the user
local runNo, runLabel, lastAction = 0, "", ""
local messages = {}
local function message(s)
    messages[#messages + 1] = s
    if #messages > 60 then table.remove(messages, 1) end
end

local function header(note)
    local mw = mon.getSize()
    line(1, 1, mw, string.format(" %s  run %d: %s%s", name, runNo, runLabel, note or ""), "f", "8")
end

local function status(world)
    local x, y = L.text[1], L.text[2]
    local P = world.P
    local fuel = rawget(env, "FUEL")
    line(x, y, L.textW, string.format("move %d  at (%d,%d,%d) facing %s", world.moves(),
        P.x, P.y, P.z, ({ [0] = "+z", "+x", "-z", "-x" })[P.d]), "4", "f")
    line(x, y + 1, L.textW, string.format("%s%s  %s", fuel and ("fuel " .. fuel .. "  ") or "",
        paused and "PAUSED" or (SPEEDS[speed] .. "s/move"), lastAction), "8", "f")
    local rows = L.textH - 2
    for i = 1, rows do
        local m = messages[#messages - rows + i]
        line(x, y + 1 + i, L.textW, m or "", "0", "f")
    end
end

local function draw(world)
    if not L then
        L = layout(world)
        mon.setBackgroundColor(colors.black)
        mon.clear()
    end
    local W, P = world.W, world.P
    header()
    -- top-down: the highest block in each column
    line(L.top[1], L.top[2] - 1, L.topW, "top  +z^ +x>", "8", "f")
    for row = 0, L.topH - 1 do
        local z = world.length + 1 - row
        local t, f, b = {}, {}, {}
        for x = 0, world.width + 1 do
            local s, fg, bg
            if x == P.x and z == P.z then
                s, fg, bg = TOP_ARROW[P.d], "f", "4"
            else
                local blk
                for y = Y_TOP, Y_BOTTOM - 1, -1 do
                    blk = W.get(x, y, z)
                    if blk then break end
                end
                s, fg, bg = glyph(blk)
            end
            t[#t + 1] = s; f[#f + 1] = fg .. fg; b[#b + 1] = bg .. bg
        end
        put(L.top[1], L.top[2] + row, table.concat(t), table.concat(f), table.concat(b))
    end
    -- side: the slice x = turtle's x
    line(L.side[1], L.side[2] - 1, L.sideW, "side x=" .. P.x .. "  +z> y^", "8", "f")
    for row = 0, L.sideH - 1 do
        local y = Y_TOP - row
        local t, f, b = {}, {}, {}
        for z = -1, world.length + 1 do
            local s, fg, bg
            if z == P.z and y == P.y then
                s, fg, bg = SIDE_ARROW[P.d], "f", "4"
            else
                s, fg, bg = glyph(W.get(P.x, y, z))
            end
            t[#t + 1] = s; f[#f + 1] = fg .. fg; b[#b + 1] = bg .. bg
        end
        put(L.side[1], L.side[2] + row, table.concat(t), table.concat(f), table.concat(b))
    end
    status(world)
end

--------------------------------------------------------------------------
-- Pacing and keys
--------------------------------------------------------------------------
local QUIT = "watchsim: quit"
local function handle(ev, p1)
    if ev == "terminate" or (ev == "key" and p1 == keys.q) then
        quitting = true
    elseif ev == "key" then
        if p1 == keys.space then paused = not paused
        elseif p1 == keys.up then speed = math.max(1, speed - 1)
        elseif p1 == keys.down then speed = math.min(#SPEEDS, speed + 1)
        elseif p1 == keys.f then skipping = true
        elseif p1 == keys.right and paused then return "step" end
    elseif ev == "monitor_touch" then
        paused = not paused
    end
end

local function pace(world)
    while true do
        local timer
        if paused then
            -- wait for a key
        elseif SPEEDS[speed] > 0 then
            timer = realOs.startTimer(SPEEDS[speed])
        else
            realOs.queueEvent("watchsim")
        end
        local ev, p1 = realOs.pullEventRaw()
        if (ev == "timer" and p1 == timer) or ev == "watchsim" then
            if not paused then return end
        else
            local wasPaused = paused
            local r = handle(ev, p1)
            if quitting then error(QUIT, 0) end
            if skipping or r == "step" then return end
            if paused ~= wasPaused or ev == "key" then status(world) end
        end
    end
end

-- Moves and block changes are what's worth a frame.
local STEP = {
    forward = true, back = true, up = true, down = true, turnLeft = true, turnRight = true,
    dig = true, digUp = true, digDown = true, place = true, placeUp = true, placeDown = true,
}

env = S.new({
    print = function(s)
        if not s:find("^%s") and not s:find("^%-%-") then message(s) end
        return realPrint(s)
    end,
    onPrint = message,
    onLoad = function(p, a)
        runNo = runNo + 1
        runLabel = realFs.getName(p):gsub("%.lua$", "") .. " " .. table.concat(a, " ")
        skipping = false
        message("== " .. runLabel)
    end,
    onCall = function(api, fname)
        if quitting then error(QUIT, 0) end
        if api ~= "turtle" or not STEP[fname] then return end
        lastAction = fname
        if skipping then return end
        local world = rawget(env, "SIM_WORLD")
        local ok, err = pcall(draw, world)
        if not ok then fatal = err end
        -- the program's own pcalls would swallow the error: stop for good
        if fatal then quitting = true; error(QUIT, 0) end
        pace(world)
    end,
})

print("Watching " .. name .. " on the monitor.")
print("space pause, right step, up/down speed, f skip run, q quit")
local ok, err = S.run(path, root, env)
local world = rawget(env, "SIM_WORLD")
if fatal then
    printError(fatal)
elseif quitting then
    print("Stopped.")
elseif not ok then
    printError(err)
elseif world and L then
    lastAction = "finished"
    draw(world)
    header("  (finished)")
    print("Finished. Press any key.")
    realOs.pullEvent("key")
end
mon.setBackgroundColor(colors.black)
mon.clear()
