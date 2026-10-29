-- sim/proc.lua
--
-- lib/proc.lua, init's kernel, over a fake os, terminal, window API and
-- settings: processes started at once and as events come; the keyboard
-- to the console only, other events to all, by each one's filter;
-- inject; signals (TERM as a terminate event, KILL, 0, init refused);
-- each process's own terminal and environment, in place only while it
-- runs; ps; proc_exit and wait; services: started from the settings,
-- started again after they end (1 s, 2 s, 4 s...), not with restart =
-- "no", stopped (Ctrl+T, then KILL after 3 s), what they showed.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check
local P = require("proc")

-- the fake world
local events, timers, nextTimer, CLOCK = {}, {}, 0, 1000000
local fakeOs = {}
fakeOs.pullEventRaw = function(f)
    if coroutine.isyieldable() then return coroutine.yield(f) end
    return table.unpack(table.remove(events, 1) or { "none" })
end
fakeOs.pullEvent = function(f)
    local ev = table.pack(fakeOs.pullEventRaw(f))
    if ev[1] == "terminate" then error("Terminated", 0) end
    return table.unpack(ev, 1, ev.n)
end
fakeOs.queueEvent = function(...) events[#events + 1] = table.pack(...) end
fakeOs.startTimer = function(s) nextTimer = nextTimer + 1; timers[nextTimer] = CLOCK + s * 1000; return nextTimer end
fakeOs.epoch = function() return CLOCK end
local COMMANDS = {}
fakeOs.run = function(env, path, cmd)
    local fn = COMMANDS[cmd or "shell"]
    if not fn then error("no command " .. tostring(cmd)) end
    fn(env)
    return true
end
-- time passes: the timers due fire, in order
local function pass(seconds)
    CLOCK = CLOCK + seconds * 1000
    local due = {}
    for id, at in pairs(timers) do if at <= CLOCK then due[#due + 1] = id end end
    table.sort(due)
    for _, id in ipairs(due) do timers[id] = nil; events[#events + 1] = table.pack("timer", id) end
end

local current = { name = "native" }
local fakeTerm = {
    redirect = function(t) local old = current; current = t; return old end,
    current = function() return current end,
}
local native = { getSize = function() return 20, 5 end, isColour = function() return true end,
    getPaletteColour = function() return 0, 0, 0 end }
local fakeWindow = { create = function(parent, x, y, w, h)
    local rows = {}
    for r = 1, h do rows[r] = (" "):rep(w) end
    local cx, cy = 1, 1
    local win = { parent = parent, rows = rows }
    function win.getSize() return w, h end
    function win.getLine(r) return rows[r] end
    function win.write(s)
        rows[cy] = (rows[cy]:sub(1, cx - 1) .. s .. rows[cy]:sub(cx + #s)):sub(1, w)
        cx = cx + #s
    end
    function win.newline() cy = math.min(h, cy + 1); cx = 1 end
    return win
end }
local STORE = {}
local fakeSettings = {
    get = function(k) return STORE[k] end,
    getNames = function() local t = {} for k in pairs(STORE) do t[#t + 1] = k end table.sort(t) return t end,
}

local K = P.new({ native = native, osT = fakeOs, term = fakeTerm, window = fakeWindow, settings = fakeSettings,
    env = { BASE = "yes" } })
-- drain: hand every queued event on, as init's loop does
local function drain()
    for _ = 1, 1000 do
        if not events[1] then return end
        K.dispatch(table.remove(events, 1))
    end
end

-- 1. processes and events
local log = {}
local consoleTerm = fakeWindow.create(native, 1, 1, 20, 5)
local con = K.spawn({ fn = function()
    while true do
        local ev = table.pack(fakeOs.pullEventRaw())
        log[#log + 1] = "con:" .. ev[1] .. ":" .. tostring(ev[2])
        if ev[1] == "char" and ev[2] == "q" then return end
    end
end, name = "con", term = consoleTerm, tty = "con" })
K.console = con
local during = {}
local bg = K.spawn({ fn = function()
    during.term = fakeTerm.current()
    during.env = fakeOs.getenv("BASE")
    fakeOs.setenv("MINE", "1")
    while true do
        local _, v = fakeOs.pullEvent("tick")
        log[#log + 1] = "bg:tick:" .. tostring(v)
    end
end, name = "bg" })
check("spawned outside a process: started at once, in its own (hidden) terminal and environment",
    during.term == K.procs[bg].term and during.term ~= consoleTerm and during.env == "yes"
        and current.name == "native" and rawget(fakeOs, "getenv") == nil)
check("the environment: its own copy (setenv stays in it)", K.procs[bg].env.MINE == "1" and K.env.MINE == nil)
fakeOs.queueEvent("char", "a")
fakeOs.queueEvent("tick", 1)
fakeOs.queueEvent("other", 2)
drain()
check("the keyboard to the console alone; other events to everyone, as each one's filter lets them",
    table.concat(log, " ") == "con:char:a con:tick:1 bg:tick:1 con:other:2", table.concat(log, " "))
log = {}
K.inject(bg, "tick", "direct")
K.inject(bg, "char", "z")
check("inject: one process only, and still only what it waits for", table.concat(log, " ") == "bg:tick:direct",
    table.concat(log, " "))

-- 2. spawned from inside a process: started on the next turn, inheriting the env
local child
log = {}
local parent = K.spawn({ fn = function()
    fakeOs.setenv("FROM", "parent")
    child = K.spawn({ fn = function()
        log[#log + 1] = "child:" .. tostring(fakeOs.getenv("FROM"))
        fakeOs.pullEvent("never")
    end, name = "child" })
    log[#log + 1] = "parent spawned"
    fakeOs.pullEvent("never")
end, name = "parent" })
drain()
check("spawned from a process: after it yields; the parent's environment, its parent its ID",
    table.concat(log, " ") == "parent spawned child:parent" and K.procs[child].ppid == parent, table.concat(log, " "))

-- 3. ps
local ps = K.ps()
local names = {}
for _, p in ipairs(ps) do names[#names + 1] = p.pid .. ":" .. p.name .. ":" .. p.tty .. ":" .. p.state end
check("ps: init first, then the rest oldest first, with tty and state",
    table.concat(names, " ") == "1:init:?:S 2:con:con:S 3:bg:?:S 4:parent:?:S 5:child:?:S", table.concat(names, " "))

-- 4. signals
local ended = {}
K.procs[child].onExit = function(p) ended[#ended + 1] = p.pid .. ":" .. tostring(p.err) end
check("kill 0: it's there", K.kill(child, 0) == true)
K.kill(child, "TERM")
drain()
check("TERM: a terminate event, which ends it (Terminated)", K.procs[child] == nil and ended[1] == child .. ":Terminated",
    tostring(ended[1]))
K.kill(parent, 9)
check("KILL (9): gone at once", K.procs[parent] == nil and K.exited[parent].err == "killed")
local last = events[#events]
check("each end is a proc_exit event", last[1] == "proc_exit" and last[2] == parent and last[3] == "killed")
local ok, why = K.kill(1)
local ok2, why2 = K.kill(99)
check("init can't be signalled; no such process", not ok and why == "init can't be signalled"
    and not ok2 and why2 == "no such process")
drain()
fakeOs.queueEvent("char", "q")
drain()
check("the console ends when its program does", K.procs[con] == nil)
K.console = nil

-- 5. services
STORE["service.web.cmd"] = "web"
STORE["service.web.enabled"] = true
STORE["service.once.cmd"] = "once"
STORE["service.once.restart"] = "no"
local runs = 0
COMMANDS.web = function()
    runs = runs + 1
    fakeTerm.current().write("web run " .. runs)
    fakeOs.pullEvent("never")
end
COMMANDS.once = function() end
K.startServices()
local st = K.serviceStatus()
check("services: from the settings, sorted; the enabled one started at boot, the other not",
    #st == 2 and st[1].name == "once" and st[1].state == "-" and st[2].name == "web" and st[2].state == "running"
        and st[2].enabled and runs == 1)
local pid1 = K.services.web.pid
K.kill(pid1, "TERM")
drain()
check("it ends: restarting, not yet back", K.services.web.state == "restarting" and runs == 1)
pass(1); drain()
check("back after 1 s, a new process", K.services.web.state == "running" and runs == 2 and K.services.web.pid ~= pid1)
K.kill(K.services.web.pid, "TERM"); drain()
pass(1); drain()
check("ending again soon after: 2 s this time", runs == 2)
pass(1); drain()
check("(there it is)", runs == 3 and K.services.web.restarts == 2, runs)
st = K.serviceStatus()
check("status: what it showed last, its process, restarts", st[2].lines[1] == "web run 3" and st[2].pid == K.services.web.pid
    and st[2].restarts == 2 and st[2].last == "failed: Terminated", tostring(st[2].last))
COMMANDS.web = function() while true do fakeOs.pullEventRaw("never") end end   -- (now one that ignores Ctrl+T)
K.kill(K.services.web.pid, "KILL")
pass(4); drain()
local pid = K.services.web.pid
check("started again after a KILL too", K.services.web.state == "running" and K.procs[pid] ~= nil)
K.serviceStop("web")
drain()
check("stop: Ctrl+T first; one that ignores it is still there", K.procs[pid] ~= nil and K.services.web.state == "running")
pass(3); drain()
check("... and killed 3 s later, stopped, not started again", K.procs[pid] == nil and K.services.web.state == "stopped")
pass(60); drain()
check("(still stopped)", K.services.web.state == "stopped")
check("start", K.serviceStart("web") and K.services.web.state == "running")
local again, err = K.serviceStart("web")
check("start again: it's already running", not again and err == "web is already running")
K.serviceStart("once")
drain()
check("restart = no: left ended", K.services.once.state == "exited" and K.services.once.last == "ended")
local none, e2 = K.serviceStart("nope")
check("an unknown service", not none and e2:find("no such service"))
local w = K.services.web.pid
K.api.restart("web")
pass(4); drain()
check("restart: stopped (Ctrl+T ignored: killed), then started anew",
    K.services.web.state == "running" and K.services.web.pid ~= w and K.procs[w] == nil)

-- 6. proc.wait, from a process
local result
local short = K.spawn({ fn = function() fakeOs.pullEvent("go") end, name = "short" })
K.spawn({ fn = function() result = table.pack(K.api.wait(short)) end, name = "waiter" })
drain()
fakeOs.queueEvent("go")
drain()
check("proc.wait: true once it has ended", result and result[1] == true)
check("after: no environment left on os, the terminal as it was", rawget(fakeOs, "getenv") == nil and current.name == "native")
