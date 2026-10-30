-- sim/net_tools.lua
--
-- ip, ping, traceroute and nc in a shellworld, against stacks (lib/net.lua)
-- joined by mock wires that answer at once:
--
--     this computer 10.0.1.2 --- [left] R 10.0.1.1 | 10.0.2.1 [right] --- B 10.0.2.5
--
-- ip: interfaces, routes, forwarding and hosts kept in settings, shown
-- down and up, `ip up` and `ip down`; ping (replies, TTL, summary, an
-- unknown host, the network down); traceroute (the router, then the
-- host); nc -l printing datagrams.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local N = require("net")
local check = M.check

local W = SW.new(PROJ)
local function show(s) return (tostring(s):gsub("\n", "|")) end

-- settings and modems, as the programs see them (real globals)
local STORE = {}
settings = {
    get = function(k) return STORE[k] end, set = function(k, v) STORE[k] = v end,
    unset = function(k) STORE[k] = nil end, save = function() end,
    getNames = function() local t = {} for k in pairs(STORE) do t[#t + 1] = k end table.sort(t) return t end,
}
local OPENED = {}
peripheral = {
    getNames = function() return { "back", "top" } end,
    getType = function(n) return (n == "back" or n == "top") and "modem" or nil end,
    call = function(n, m, a)
        if m == "open" then OPENED[n .. ":" .. a] = true end
        if m == "close" then OPENED[n .. ":" .. a] = nil end
        if m == "isWireless" then return n == "top" end
    end,
}
os.getComputerID = os.getComputerID or function() return 1 end
textutils = textutils or M.textutilsApi()

--------------------------------------------------------------------------
-- ip with the network down: what's set
--------------------------------------------------------------------------
local r = W:run("ip")
check("ip, nothing set: down, and how to start", r.out:find("down") and r.out:find("ip addr add"), show(r.out))
r = W:run("ip", "addr", "add", "back", "10.0.1.2/24")
local r2 = W:run("ip", "addr", "add", "back.20", "10.0.20.2/24")
check("ip addr add: kept in settings (a VLAN too)", STORE["net.if.back"] == "10.0.1.2/24"
    and STORE["net.if.back.20"] == "10.0.20.2/24" and r.status == 0 and r2.status == 0)
r = W:run("ip", "addr", "add", "back", "10.0.1.2")
check("an address without its prefix: a usage error", r.status == 2, show(r.errText))
W:run("ip", "route", "add", "default", "via", "10.0.1.1")
W:run("ip", "route", "add", "10.0.9.0/24", "via", "10.0.1.7")
W:run("ip", "route", "del", "10.0.9.0/24")
check("ip route add/del: kept in settings", STORE["net.routes"] == "default via 10.0.1.1", tostring(STORE["net.routes"]))
W:run("ip", "host", "b", "10.0.2.5")
check("ip host: a name kept", tostring(STORE["net.hosts"]):find("b=10.0.2.5") ~= nil)
r = W:run("ip", "link")
check("ip link: the modems, wired or wireless, and what's set on them",
    r.out:find("back%s+wired%s+back back.20") and r.out:find("top%s+wireless%s+%(not set up%)"), show(r.out))
r = W:run("ip", "route")
check("ip route while down: the saved routes", r.out:find("default%s+via 10%.0%.1%.1 %(not up%)"), show(r.out))

--------------------------------------------------------------------------
-- ip up / down
--------------------------------------------------------------------------
r = W:run("ip", "up")
check("ip up: two interfaces, the channels opened (VLAN 20: 4060)", r.out:find("up: 2 interfaces")
    and OPENED["back:4040"] and OPENED["back:4060"] and _G.ccnet ~= nil, show(r.out) .. show(r.errText))
r = W:run("ip")
check("ip: up, the interfaces and routes", r.out:find("^up") and r.out:find("back%s+10%.0%.1%.2/24%s+1:back")
    and r.out:find("back%.20.*vlan 20") and r.out:find("default%s+via 10%.0%.1%.1 dev back"), show(r.out))
r = W:run("ip", "down")
check("ip down: channels closed", r.out:find("down") and not OPENED["back:4040"] and _G.ccnet == nil)
r = W:run("ping", "10.0.1.1")
check("ping with the network down: says so, status 2", r.status == 2 and r.errText:find("ip up"), show(r.errText))

--------------------------------------------------------------------------
-- stacks on mock wires that answer at once
--------------------------------------------------------------------------
local segments, wires = {}, {}
local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end
local function computer(id, forward, queue)
    local S
    S = N.new({ id = id, forward = forward, clock = function() return W.clock end,
        queue = queue or function() end,
        transmit = function(ifc, frame)
            for _, m in ipairs(segments[wires[id .. ":" .. ifc.modem]] or {}) do
                if not (m[1] == S and m[2] == ifc.modem) then m[1].receive(m[2], ifc.channel, copy(frame)) end
            end
        end })
    return S
end
local function plug(S, iface, cidr, seg)
    assert(S.addInterface(iface, cidr))
    wires[S.id .. ":" .. iface] = seg
    segments[seg] = segments[seg] or {}
    table.insert(segments[seg], { S, iface })
end
local ME = computer(1, false, function(...) W.os.queueEvent(...) end)
local R, B = computer(10, true), computer(2)
plug(ME, "back", "10.0.1.2/24", "lan1")
plug(R, "left", "10.0.1.1/24", "lan1")
plug(R, "right", "10.0.2.1/24", "lan2")
plug(B, "back", "10.0.2.5/24", "lan2")
assert(ME.addRoute("default", "10.0.1.1"))
assert(B.addRoute("default", "10.0.2.1"))
_G.ccnet = ME                       -- (b is `ip host`'s, above)

r = W:run("ping", "-c", "2", "b")
check("ping by name, through the router: 2 replies, TTL 63, the summary",
    r.status == 0 and r.out:find("PING b %(10%.0%.2%.5%)") and select(2, r.out:gsub("reply from 10%.0%.2%.5", "")) == 2
        and r.out:find("ttl=63") and r.out:find("2 sent, 2 received, 0%% lost"), show(r.out))
r = W:run("ping", "-c", "1", "-t", "1", "10.0.2.5")
check("ping -t 1: time exceeded at the router, status 1", r.status == 1
    and r.out:find("from 10%.0%.1%.1: seq=1 time to live exceeded") and r.out:find("1 sent, 0 received"), show(r.out))
r = W:run("ping", "-c", "1", "172.16.0.9")
check("ping where the router has no route: net unreachable from it", r.status == 1
    and r.out:find("from 10%.0%.1%.1: seq=1 destination net unreachable"), show(r.out))
r = W:run("ping", "nowhere")
check("ping an unknown name: status 2", r.status == 2 and r.errText:find("nowhere: Name or service not known"),
    show(r.errText))

r = W:run("traceroute", "-q", "1", "b")
local lines = {}
for l in r.out:gmatch("[^\n]+") do lines[#lines + 1] = l end
check("traceroute: the router, then the host (by its name from ip host)",
    r.status == 0 and #lines == 3 and lines[2]:find("^ 1%s+10%.0%.1%.1  ") and lines[3]:find("^ 2%s+b %(10%.0%.2%.5%)"),
    show(r.out))
r = W:run("traceroute", "-q", "1", "172.16.0.9")
check("traceroute to a network nobody routes: !N at the router", r.status == 1 and r.out:find("10%.0%.1%.1.*!N"),
    show(r.out))

-- nc -l: what B sends to port 7 here, printed (until Ctrl+T)
local pb = B.udpOpen(1234)
local function sendLater() B.udpSend(pb, "10.0.1.2", 7, "hello"); B.udpSend(pb, "10.0.1.2", 7, { n = 1 }) end
r = W:run("nc", "-u", "-l", "-v", "7", {        -- (B sends once nc waits; then Ctrl+T)
    onPull = function(w)
        if sendLater then
            local f = sendLater
            sendLater = nil
            f()
            w.T.events[#w.T.events + 1] = { "terminate" }
        end
    end,
    events = {} })
check("nc -u -l -v: each datagram, with who sent it, a table serialised",
    r.out:find("from 10%.0%.2%.5:1234: hello") and r.out:find("from 10%.0%.2%.5:1234: {n=1,?}")
        and not r.out:find("nil"), show(r.out) .. show(r.errText))
check("and the port is free again after", ME.sockets[7] == nil)
-- nc over TCP.  parallel as CraftOS has it, over the world's os
local parallelWas = parallel
parallel = { waitForAny = function(...)
    local cos, filters = {}, {}
    for i, f in ipairs({ ... }) do cos[i] = coroutine.create(f) end
    local ev = { n = 0 }
    while true do
        for i, co in ipairs(cos) do
            if filters[i] == nil or filters[i] == ev[1] or ev[1] == "terminate" then
                local ok, f = coroutine.resume(co, table.unpack(ev, 1, ev.n))
                if not ok then error(f, 0) end
                if coroutine.status(co) == "dead" then return i end
                filters[i] = f
            end
        end
        ev = table.pack(W.os.pullEventRaw())
    end
end }
W.yieldEvents = true
assert(B.tcpListen(7))
local cb, heard
r = W:run("nc", "10.0.2.5", "7", { stdin = "hi\n", events = {},
    onPull = function()
        cb = cb or B.tcpAccept(7)
        if cb and not heard and cb.peerFin then         -- (nc has sent its line and closed its half)
            heard = B.tcpRead(cb)
            B.tcpSend(cb, "pong\r\n")
            B.tcpClose(cb)
        end
    end })
check("nc host port (TCP): the line goes, the answer is printed (no \\r), both sides close",
    heard == "hi\n" and r.out == "pong\n" and r.status == 0 and cb.state == "CLOSED", show(r.out) .. show(r.errText))
B.tcpUnlisten(7)
local cl
r = W:run("nc", "-l", "-v", "8", { events = {},
    onPull = function()
        if not cl then
            cl = B.tcpConnect("10.0.1.2", 8)
            B.tcpSend(cl, "from b\n")
            B.tcpClose(cl)
        end
    end })
check("nc -l -v port: one connection, who it's from, what it sent, then the end",
    r.out == "from b\n" and r.status == 0 and r.err[1] == "connection from 10.0.2.5:" .. cl.lport
        and r.err[2] == "closed" and ME.listeners[8] == nil, show(r.out) .. show(r.errText))
r = W:run("nc", "10.0.2.5", "99", { events = {} })
check("nc to a port nobody listens on: connection refused, status 1",
    r.status == 1 and r.err[1] == "nc: 10.0.2.5 99: connection refused", show(r.errText))
W.yieldEvents = false
parallel = parallelWas
_G.ccnet = nil

--------------------------------------------------------------------------
-- deploy/install --router on a computer: the network up at boot,
-- forwarding on, and with --autostart router the router's screen at boot
--------------------------------------------------------------------------
for _, f in ipairs({ "install", "boot" }) do
    local hf = assert(io.open(PROJ .. "/deploy/" .. f .. ".lua", "rb"))
    W:file("ccnix/deploy/" .. f .. ".lua", hf:read("a"))
    hf:close()
end
W:install("ip")
help = help or { path = function() return "/rom/help" end, setPath = function() end }
local turtleWas = turtle
turtle = nil
STORE["net.boot"], STORE["net.forward"] = nil, nil
r = W:session({}, function() return W:osRun("ccnix/deploy/install.lua", { "--autostart", "router", "--no-reboot" }) end)
local startup = W:read("startup.lua") or ""
check("install --autostart router on a computer: net.boot and forwarding on, the router at boot; startup runs boot.lua first and `--end` last",
    STORE["net.boot"] == true and STORE["net.forward"] == true and STORE["ccnix.autostart"] == "router"
        and startup == 'shell.run("/ccnix/deploy/boot.lua")\nshell.run("/ccnix/deploy/boot.lua", "--end")\n',
    show(startup) .. show(r.out) .. show(r.errText))
check("and, not rebooting, the network came up in this shell (forwarding)", _G.ccnet ~= nil and _G.ccnet.forward == true,
    show(r.out))
r = W:session({}, function() return W:osRun("ccnix/deploy/install.lua", { "--no-reboot" }) end)
check("install again: the same startup", W:read("startup.lua") == startup, show(W:read("startup.lua")))
r = W:run("ip", "boot", "off")
check("ip boot off: net.boot off", STORE["net.boot"] == false and r.out:find("doesn't start"))
r = W:run("ip", "boot")
check("ip boot: on again, and no line of its own (install's is there)", STORE["net.boot"] == true
    and W:read("startup.lua") == startup)
N.down()
turtle = turtleWas
