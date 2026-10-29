-- claude.lua -- let Claude drive the turtle
--
-- Talks to the Claude API (Anthropic) from the turtle over HTTP and gives
-- the model one tool that matters: `lua`, which runs the Lua it writes on
-- the turtle, with the turtle API and turtlelib (T) in scope.  You give
-- it a goal; it works at it, call by call, says what it did, and asks
-- when it isn't sure.
--
-- Usage:
--   claude [goal words...] [--model id] [--effort low|medium|high]
--          [--steps N] [--confirm]
--
--   claude dig a 3 by 3 tunnel 20 blocks ahead and come back
--   claude                      asks for the goal
--
--   --steps N    at most N tool calls per goal (default 60), then it's
--                told to stop and sum up
--   --confirm    show each piece of code and ask before running it
--
-- When it stops, type the next thing to do (it keeps the conversation),
-- or press Enter on an empty line to quit.  Ctrl+T stops it (under T.run,
-- so the saved position stays right).
--
-- Reading back: when more comes out than the screen holds, it opens in
-- the pager (lib/pager.lua) at the first line you haven't seen before it
-- asks you anything: the mouse wheel, arrows or space to scroll, q to
-- get to the prompt.  At an empty prompt, the wheel up (or PgUp) opens
-- the whole session.
--
-- Setup:
--   * put an API key in `claude.key` next to this program (`edit
--     claude.key`, paste the key, save).  Make it a key of its own with a
--     spending limit: anything on a computer's disk can be read by whoever
--     can open the turtle or the server's save folder.  The file is in
--     .gitignore, and `git pull` never touches untracked files.
--   * the server's CC:Tweaked config must allow HTTP to api.anthropic.com
--     (the same `http.rules` allow-list that lets `git` reach your host).
--
-- What it costs: every round trip (one tool call) sends the whole
-- conversation, so a long job is many calls; the system prompt and tools
-- are marked for prompt caching.  The totals are printed when a goal ends.
--
-- Position: it picks up turtlelib's saved position (.turtlepos) if there
-- is one, so `home` still works afterwards; otherwise here is (0,0,0)
-- facing +z.

local T = require("turtlelib")
-- the pager is in lib/, beside turtle/; without it the output just scrolls
if shell and shell.getRunningProgram then
    package.path = "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;" .. package.path
end
local okPager, pager = pcall(require, "pager")
if not (okPager and type(pager) == "table" and pager.page) then pager = nil end

local API_URL = "https://api.anthropic.com/v1/messages"
local API_VERSION = "2026-10-21"
local KEY_FILE = T.dataPath("claude.key")
local LOG_FILE = T.dataPath("claude.log")
local MAX_TOKENS = 8192         -- a reply is a short note and some code
local MAX_OUTPUT = 6000         -- characters of a tool's output sent back
local RETRIES = 4               -- on rate limits, overload and outages
local HTTP_TIMEOUT = 60         -- seconds to wait for a reply: CC allows at most 60

--------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------
local args = { ... }
local MODEL, EFFORT, MAX_STEPS = "claude-opus-5-5", "medium", 60
local CONFIRM = T.popFlag(args, "--confirm")
local function popValue(flag)
    for i = 1, #args - 1 do
        if args[i] == flag then
            local v = args[i + 1]
            table.remove(args, i); table.remove(args, i)
            return v
        end
    end
end
MODEL = popValue("--model") or MODEL
EFFORT = popValue("--effort") or EFFORT
local stepsArg = popValue("--steps")
MAX_STEPS = stepsArg and tonumber(stepsArg) or MAX_STEPS
local goal = table.concat(args, " ")

--------------------------------------------------------------------------
-- The key
--------------------------------------------------------------------------
local function readKey()
    if not fs.exists(KEY_FILE) then return nil end
    local f = fs.open(KEY_FILE, "r")
    local key = (f.readLine() or ""):match("^%s*(.-)%s*$")
    f.close()
    return key ~= "" and key or nil
end

local KEY = readKey()
if not KEY then
    print("No API key: put one in " .. KEY_FILE .. " (edit " .. KEY_FILE .. ", paste it, save).")
    return
end
if not http then print("HTTP is disabled on this server."); return end

--------------------------------------------------------------------------
-- What the model is told
--------------------------------------------------------------------------
local SYSTEM = [[
You are driving a ComputerCraft (CC:Tweaked) turtle in Minecraft, from inside the turtle. You act by calling the `lua` tool with Lua code (Lua 5.2 as CC runs it), which runs on the turtle; what it prints and returns comes back to you. Nothing happens unless you call a tool.

Coordinates are the turtle's own, dead-reckoned by the turtlelib library `T`: it started at (0,0,0) facing +z (heading 0); +x is to its right (heading 1), -z is heading 2, -x is heading 3; y is up. T.pos = {x, y, z} and T.dir are where it thinks it is, and stay right only if you move and turn through T: T.forward(), T.back(), T.up(), T.down(), T.turnLeft(), T.turnRight(), T.face(d), T.moveDir(d) (d a heading, "up" or "down"), T.toY(y), T.goTo(x, z) (routes to a column at the current height, learning obstacles). Never call turtle.forward/back/up/down/turnLeft/turnRight yourself: T.pos would be wrong from then on. T.forward() and the others only dig blocks listed in T.diggable (empty to start): to dig, call turtle.dig(), turtle.digUp() or turtle.digDown() first, or set T.diggable["minecraft:stone"] = true for what it may dig on the way. Moves cost one fuel each; T.refuelTo(n) burns fuel items from the inventory.

Also useful: T.look(d) / T.digDir(d) / T.placeDir(d) (inspect, dig, place in a direction, facing it first); turtle.inspect(), turtle.inspectUp(), turtle.inspectDown() -> ok, {name=..., state=...}; turtle.detect/detectUp/detectDown(); turtle.select(slot), turtle.getItemDetail(slot), turtle.getItemCount(slot); T.selectItem(name), T.countItem(name), T.freeSlots(), T.tidyInventory(); turtle.place/placeUp/placeDown(), turtle.drop/dropUp/dropDown(n), turtle.suck/suckUp/suckDown(n); turtle.getFuelLevel(); peripheral.wrap("left"/"right"/"front"/"top"/"bottom"); sleep(seconds); T.posString().

Each tool call is a slow network round trip, so do several steps per call: write loops, check results in the code, and return or print what you learn, briefly. Variables and functions you define persist between calls. Call `status` to see where the turtle is, what's around it and what it carries. Never dig or break chests, barrels, hoppers or computers, and don't break blocks you weren't asked to. If the task is unclear or risky, call ask_user. When done (or stuck), stop and say what you did and where the turtle is; say plainly if something failed.]]

local TOOLS = {
    {
        name = "lua",
        description = "Run Lua on the turtle. The code runs as a chunk with turtle, T (turtlelib), peripheral, os, textutils, math, string, table and sleep in scope; print output and return values come back to you (tables are serialised). Errors come back as an error result. Definitions persist between calls.",
        input_schema = {
            type = "object",
            properties = { code = { type = "string", description = "The Lua code to run." } },
            required = { "code" },
        },
    },
    {
        name = "status",
        description = "Where the turtle is (position, heading), its fuel, what's in front, above and below it, and what it carries.",
        input_schema = { type = "object", properties = {} },
    },
    {
        name = "ask_user",
        description = "Ask the person at the turtle a question and wait for the answer.",
        input_schema = {
            type = "object",
            properties = { question = { type = "string" } },
            required = { "question" },
        },
    },
}

--------------------------------------------------------------------------
-- The screen: what's shown is kept, to read back in the pager
--------------------------------------------------------------------------
local SCROLLBACK = 3000         -- lines kept
local shown = {}                -- the lines shown this session
local seen = 0                  -- how many of them were out at the last prompt
local screenPrint = print

local function keep(text)
    for l in (text .. "\n"):gmatch("([^\n]*)\n") do shown[#shown + 1] = l end
    if #shown > SCROLLBACK + 500 then
        local cut, t = #shown - SCROLLBACK, {}
        for i = cut + 1, #shown do t[#t + 1] = shown[i] end
        shown, seen = t, math.max(0, seen - cut)
    end
end

-- everything printed goes through here: claude's notes, the code, what
-- the code and turtlelib print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    keep(table.concat(parts, " "))
    return screenPrint(...)
end

-- If more came out since the last prompt than fits above it, show it in
-- the pager from its first line.  After the pager, the screen shows the
-- end of the session again, above the prompt.
local function view(opts)
    opts.wrap, opts.always = true, true
    pager.page(shown, opts)
    local w, h = term.getSize()
    local tail = {}
    for i = math.max(1, #shown - h + 2), #shown do tail[#tail + 1] = shown[i] end
    local rows = pager.wrap(tail, w)
    for r = 1, h do
        term.setCursorPos(1, r)
        term.clearLine()
        local l = r < h and rows[#rows - (h - 1) + r]
        if l then term.write(l) end
    end
    term.setCursorPos(1, h)
end

local function catchUp()
    if not (pager and term) then return end
    local w, h = term.getSize()
    local new = {}
    for i = seen + 1, #shown do new[#new + 1] = shown[i] end
    if #pager.wrap(new, w) > h - 1 then view({ from = seen + 1 }) end
end

-- read(), except that the wheel up or PgUp before anything is typed
-- comes back as `back`.
local function readLine()
    if not (pager and term and parallel) then return read() or "" end
    local line, back, typed
    parallel.waitForAny(
        function() line = read() end,
        function()
            while true do
                local ev, a = os.pullEvent()
                if ev == "char" or ev == "paste" then typed = true
                elseif not typed and ev == "mouse_scroll" and a < 0 then
                    back = 3                -- as far as a notch goes in the pager
                    return
                elseif not typed and ev == "key" and a == keys.pageUp then
                    back = select(2, term.getSize()) - 2      -- a page
                    return
                end
            end
        end)
    return line or "", back
end

-- Ask for a line after `label`, the pager first if need be.
local function ask(label)
    catchUp()
    while true do
        write(label)
        local line, back = readLine()
        if not back then
            keep(label .. line)
            seen = #shown
            return line
        end
        term.setCursorBlink(false)
        view({ from = math.huge, up = back })
    end
end

--------------------------------------------------------------------------
-- The tools
--------------------------------------------------------------------------
local function log(line)
    local f = fs.open(LOG_FILE, "a")
    if f then f.writeLine(line); f.close() end
end

local function clip(s)
    if #s <= MAX_OUTPUT then return s end
    local half = math.floor(MAX_OUTPUT / 2)
    return s:sub(1, half) .. "\n... (" .. (#s - MAX_OUTPUT) .. " characters left out) ...\n" .. s:sub(-half)
end

local function show(v)
    if type(v) == "table" then
        local ok, s = pcall(textutils.serialise, v, { compact = true, allow_repetitions = true })
        return ok and s or tostring(v)
    end
    return tostring(v)
end

-- What the code may use: the turtle, the library, the world's peripherals
-- and the plain Lua bits.  Not fs, http, shell or io, so a slip can't
-- read the key or rewrite the programs.
local API = {
    turtle = turtle, T = T, peripheral = peripheral, os = os, textutils = textutils,
    math = math, string = string, table = table, sleep = sleep,
    pairs = pairs, ipairs = ipairs, next = next, select = select, type = type,
    tostring = tostring, tonumber = tonumber, unpack = unpack or table.unpack,
    pcall = pcall, error = error, assert = assert,
}
local env = setmetatable({}, { __index = API })

local function runLua(code)
    local out = {}
    local realPrint = print
    local function capture(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        local line = table.concat(parts, " ")
        realPrint(line)
        out[#out + 1] = line
    end
    env.print = capture
    print = capture                    -- what turtlelib says, too
    local chunk, err = load(code, "=claude", "t", env)
    local ok, results
    if not chunk then
        ok, err = false, "syntax: " .. tostring(err)
    else
        results = table.pack(pcall(chunk))
        ok = results[1]
        if not ok then err = results[2] end
    end
    print = realPrint
    if ok then
        for i = 2, results.n do out[#out + 1] = "-> " .. show(results[i]) end
    else
        if err == "Terminated" then error(err, 0) end
        out[#out + 1] = "error: " .. tostring(err)
    end
    local text = table.concat(out, "\n")
    if text == "" then text = "(no output)" end
    return clip(text), not ok
end

local function status()
    local function at(inspect)
        local ok, d = inspect()
        return ok and d.name or "air"
    end
    local items = {}
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it then items[#items + 1] = string.format("%d: %d %s", s, it.count, it.name) end
    end
    return string.format("at %s facing %d (0=+z 1=+x 2=-z 3=-x), fuel %s\nfront: %s  above: %s  below: %s\nslots: %s\nselected slot %d",
        T.posString(), T.dir, tostring(turtle.getFuelLevel()),
        at(turtle.inspect), at(turtle.inspectUp), at(turtle.inspectDown),
        #items > 0 and table.concat(items, ", ") or "empty", turtle.getSelectedSlot()), false
end

local function askUser(question)
    print("Claude asks: " .. tostring(question))
    return ask("> "), false
end

local function runTool(name, input)
    input = input or {}
    if name == "lua" then
        local code = tostring(input.code or "")
        print("--- lua")
        print(code)
        log("lua:\n" .. code)
        if CONFIRM then
            local a = ask("Run it? [y/N] ")
            if not a:lower():find("^y") then
                print("--- not run")
                return "The user declined to run this code.", true
            end
        end
        print("---")
        local out, isErr = runLua(code)
        log((isErr and "error:\n" or "result:\n") .. out)
        return out, isErr
    elseif name == "status" then
        return status()
    elseif name == "ask_user" then
        return askUser(input.question)
    end
    return "No such tool: " .. tostring(name), true
end

--------------------------------------------------------------------------
-- The API
--------------------------------------------------------------------------
local messages = {}
local usage = { input = 0, output = 0, cached = 0 }

local function body()
    return textutils.serialiseJSON({
        model = MODEL,
        max_tokens = MAX_TOKENS,
        system = { { type = "text", text = SYSTEM, cache_control = { type = "ephemeral" } } },
        tools = TOOLS,
        messages = messages,
        output_config = { effort = EFFORT },
        -- a refusal by the safety classifiers is retried on a fallback
        -- model server-side (see the API docs: server-side fallback)
        fallbacks = "default",
    }, { allow_repetitions = true })
end

local HEADERS = {
    ["Content-Type"] = "application/json",
    ["x-api-key"] = KEY,
    ["anthropic-version"] = API_VERSION,
    ["anthropic-beta"] = "server-side-fallback-2026-07-01",
}

-- Send the conversation; the reply as a table, or nil and why.  Rate
-- limits, overloads and outages are retried with a growing wait.
local function request()
    local wait = 2
    for attempt = 1, RETRIES + 1 do
        local h, err, failed = http.post({ url = API_URL, headers = HEADERS, body = body(), timeout = HTTP_TIMEOUT })
        local code, text
        if h then
            code, text = h.getResponseCode(), h.readAll()
            h.close()
        elseif failed then
            code, text = failed.getResponseCode(), failed.readAll()
            if failed.close then failed.close() end
        end
        if code == 200 then
            local reply = textutils.unserialiseJSON(text)
            if reply then return reply end
            return nil, "Couldn't read the reply: " .. tostring(text):sub(1, 200)
        end
        local detail = tostring(err or "")
        if text then
            local e = textutils.unserialiseJSON(text)
            detail = e and e.error and (e.error.type .. ": " .. tostring(e.error.message)) or text:sub(1, 200)
        end
        local again = code == 429 or code == 500 or code == 502 or code == 503 or code == 529 or (not code)
        if not again or attempt > RETRIES then
            return nil, string.format("API request failed%s: %s", code and (" (HTTP " .. code .. ")") or "", detail)
        end
        print(string.format("API: %s; trying again in %ds.", detail, wait))
        sleep(wait)
        wait = wait * 2
    end
end

local function count(reply)
    local u = reply.usage or {}
    usage.input = usage.input + (u.input_tokens or 0)
    usage.output = usage.output + (u.output_tokens or 0)
    usage.cached = usage.cached + (u.cache_read_input_tokens or 0)
end

-- Work at `goal` until the model stops: run its tool calls and send the
-- results back, call after call, up to MAX_STEPS of them.
local function converse(goal)
    messages[#messages + 1] = { role = "user", content = goal }
    log("goal: " .. goal)
    local steps, overBudget, cutOff = 0, false, false
    while true do
        local reply, err = request()
        if not reply then
            print(err)
            messages[#messages] = nil    -- the turn it never answered
            return false
        end
        count(reply)
        messages[#messages + 1] = { role = "assistant", content = reply.content }
        for _, b in ipairs(reply.content) do
            if b.type == "text" and b.text ~= "" then print(b.text); log("claude: " .. b.text) end
        end
        if reply.stop_reason == "tool_use" then
            local results = {}
            for _, b in ipairs(reply.content) do
                if b.type == "tool_use" then
                    local out, isErr
                    if overBudget then
                        out, isErr = "The step budget is used up: stop, and say what you did.", true
                    else
                        steps = steps + 1
                        out, isErr = runTool(b.name, b.input)
                    end
                    results[#results + 1] = { type = "tool_result", tool_use_id = b.id, content = out, is_error = isErr or nil }
                end
            end
            if steps >= MAX_STEPS and not overBudget then
                overBudget = true
                results[#results + 1] = { type = "text",
                    text = string.format("That was tool call %d of the %d allowed for this goal: stop here and say what you did.", steps, MAX_STEPS) }
            end
            messages[#messages + 1] = { role = "user", content = results }
        elseif reply.stop_reason == "max_tokens" and not cutOff then
            cutOff = true
            messages[#messages + 1] = { role = "user", content = "Your reply was cut off; carry on, more briefly." }
        elseif reply.stop_reason == "refusal" then
            local d = reply.stop_details or {}
            print("Claude declined (" .. tostring(d.category or "refusal") .. "): " .. tostring(d.explanation or ""))
            return false
        else
            return true
        end
    end
end

--------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------
local function main()
    local saved = T.loadPos()
    if saved then
        T.pos.x, T.pos.y, T.pos.z, T.dir, T.mode = saved.x, saved.y, saved.z, saved.dir, saved.mode or "flat"
    else
        T.startAtHome(true)
    end
    print(string.format("Claude at the controls (%s, effort %s). Turtle at %s facing %d, fuel %s.",
        MODEL, EFFORT, T.posString(), T.dir, tostring(turtle.getFuelLevel())))
    if goal == "" then
        goal = ask("Goal: ")
    end
    while goal ~= "" do
        local before = { input = usage.input, output = usage.output, cached = usage.cached }
        converse(goal)
        print(string.format("[%d tokens in (%d from cache), %d out; %d in all]",
            usage.input - before.input, usage.cached - before.cached, usage.output - before.output,
            usage.input + usage.output))
        goal = ask("> ")
    end
end

local ok, err = pcall(T.run, main)
print = screenPrint
if not ok then error(err, 0) end
