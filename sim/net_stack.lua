-- sim/net_stack.lua
--
-- lib/net.lua: stacks on several computers joined by mock modem
-- segments (a frame reaches every other modem on the segment, copied, as
-- CC copies a message), with a clock for ARP's retries.
--
--     A 10.0.1.2 --+                         +-- B 10.0.2.5
--     C 10.0.1.3 --+-- [left] R1 [right] ----+-- R2 10.0.2.2
--     D 10.0.20.5 -+   10.0.1.1  10.0.2.1
--     (VLAN 20)        left.20: 10.0.20.1
--
-- D is on the same wire as A and C but on VLAN 20 (its own channel), and
-- R1's left modem is a trunk: left (untagged) and left.20.
-- ARP; UDP on one segment and through the router and back; ping (TTL one
-- less per router); a host that doesn't answer ARP (host unreachable); no
-- route (net unreachable, from the router); a routing loop (time
-- exceeded); a traceroute's TTLs; broadcast staying on its segment; VLANs
-- apart on one wire, joined by the router; a
-- closed port; loopback; frames for others ignored; the event hook
-- handling a frame once however many coroutines see it; the settings.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check
local N = require("net")

local CLOCK = 0
local wires = {}           -- "id:modem" -> segment name
local segments = {}        -- segment -> { { S, modem } }
local inflight = {}        -- frames on their way: { S, modem, channel, frame }
local EVENTS = {}          -- id -> events queued

local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end

local stacks = {}
local function computer(id, forward)
    local S
    S = N.new({
        id = id, forward = forward, clock = function() return CLOCK end,
        queue = function(...) table.insert(EVENTS[id], table.pack(...)) end,
        transmit = function(ifc, frame)          -- to every other modem on the wire, on its channel
            for _, m in ipairs(segments[wires[id .. ":" .. ifc.modem]] or {}) do
                if not (m[1] == S and m[2] == ifc.modem) then
                    inflight[#inflight + 1] = { m[1], m[2], ifc.channel, copy(frame) }
                end
            end
        end,
    })
    EVENTS[id] = {}
    stacks[#stacks + 1] = S
    return S
end
local function plug(S, iface, cidr, seg)
    assert(S.addInterface(iface, cidr))
    local modem = N.link(iface)
    if wires[S.id .. ":" .. modem] then return end      -- (another VLAN on a modem plugged in already)
    wires[S.id .. ":" .. modem] = seg
    segments[seg] = segments[seg] or {}
    table.insert(segments[seg], { S, modem })
end
-- deliver everything on the wires; then `seconds` pass, ticking
local function run(seconds)
    local guard = 0
    local function drain()
        while #inflight > 0 do
            guard = guard + 1
            assert(guard < 100000, "frames going round for ever")
            local f = table.remove(inflight, 1)
            f[1].receive(f[2], f[3], f[4])
        end
    end
    drain()
    for _ = 1, math.floor((seconds or 0) / 0.5) do
        CLOCK = CLOCK + 0.5
        for _, S in ipairs(stacks) do S.tick() end
        drain()
    end
end
local function events(id, name)
    local out = {}
    for _, e in ipairs(EVENTS[id]) do if e[1] == name then out[#out + 1] = e end end
    return out
end
local function clear() for id in pairs(EVENTS) do EVENTS[id] = {} end end

local A, C, B, D = computer(1), computer(3), computer(2), computer(4)
local R1, R2 = computer(10, true), computer(11, true)
plug(A, "back", "10.0.1.2/24", "lanA")
plug(C, "top", "10.0.1.3/24", "lanA")
plug(D, "back.20", "10.0.20.5/24", "lanA")
plug(R1, "left", "10.0.1.1/24", "lanA")
plug(R1, "left.20", "10.0.20.1/24", "lanA")
plug(R1, "right", "10.0.2.1/24", "lanB")
plug(B, "back", "10.0.2.5/24", "lanB")
plug(R2, "modem_0", "10.0.2.2/24", "lanB")
assert(A.addRoute("default", "10.0.1.1"))
assert(C.addRoute("default", "10.0.1.1"))
assert(B.addRoute("default", "10.0.2.1"))
assert(R2.addRoute("default", "10.0.2.1"))
assert(D.addRoute("default", "10.0.20.1"))
assert(R1.addRoute("10.9.0.0/16", "10.0.2.2"))          -- R2 sends it back: a loop

--------------------------------------------------------------------------
check("addresses: parsed and printed back", N.ipString(N.parseIP("10.0.1.2")) == "10.0.1.2"
    and N.parseIP("10.0.1.256") == nil and select(2, N.parseCIDR("default")) == 0)
check("routes: the longest prefix wins", A.route(N.parseIP("10.0.1.9")).len == 24
    and A.route(N.parseIP("10.5.5.5")).len == 0 and A.route(N.parseIP("10.5.5.5")).gw == N.parseIP("10.0.1.1"))

-- 1. one segment: ARP, then the datagram
local pa = A.udpOpen(5000)
local pc = C.udpOpen(7)
A.udpSend(pa, "10.0.1.3", 7, "hello C")
run()
local d = C.udpTake(7)
check("UDP to a host on the same segment: ARP, then delivered",
    d and d.data == "hello C" and d.src == "10.0.1.2" and d.sport == 5000 and #events(3, "net_udp") == 1)
check("each side learned the other's MAC", A.arp.back[N.parseIP("10.0.1.3")].mac == "3:top"
    and C.arp.top[N.parseIP("10.0.1.2")].mac == "1:back")
local r1rx = R1.ifaces.left.rx
A.udpSend(pa, "10.0.1.3", 7, "again")
run()
check("a frame for another computer's MAC: the router ignores it (only ARP broadcasts reach it)",
    R1.ifaces.left.rx == r1rx and C.udpTake(7).data == "again")

-- 2. through the router, and the answer back
local pb = B.udpOpen(53)
A.udpSend(pa, "10.0.2.5", 53, { q = "table data" })
run()
d = B.udpTake(53)
check("UDP through the router (tables carried too)", d and type(d.data) == "table" and d.data.q == "table data"
    and d.src == "10.0.1.2")
B.udpSend(pb, d.src, d.sport, "answer")
run()
d = A.udpTake(pa)
check("and the answer back", d and d.data == "answer" and d.src == "10.0.2.5" and d.sport == 53)
check("the router forwarded both", R1.counters.forwarded == 2, tostring(R1.counters.forwarded))

-- 3. ping
clear()
A.echo("10.0.2.5", 77, 1)
run()
local e = events(1, "net_icmp")[1]
check("ping through the router: a reply, TTL one less", e and e[2] == "reply" and e[3] == "10.0.2.5"
    and e[4] == 77 and e[5] == 1 and e[6] == N.TTL - 1, e and table.concat({ tostring(e[2]), tostring(e[6]) }, " "))

-- 4. nobody at 10.0.1.99: ARP asks three times, then host unreachable
clear()
A.echo("10.0.1.99", 78, 1)
run(4)
e = events(1, "net_icmp")[1]
check("no ARP answer: three requests, then host unreachable", e and e[2] == "unreachable" and e[4] == "host"
    and e[5].id == 78, e and tostring(e[4]))

-- 5. no route at the router: net unreachable, from it
clear()
A.echo("172.16.0.1", 79, 1)
run()
e = events(1, "net_icmp")[1]
check("no route at the router: net unreachable from 10.0.1.1", e and e[2] == "unreachable" and e[3] == "10.0.1.1"
    and e[4] == "net" and e[5].seq == 1)

-- 6. a routing loop: R1 -> R2 -> R1 ... until the TTL runs out
clear()
A.echo("10.9.0.1", 80, 1)
run()
e = events(1, "net_icmp")[1]
check("a routing loop: time exceeded, from one of the routers", e and e[2] == "timeexceeded"
    and (e[3] == "10.0.2.1" or e[3] == "10.0.2.2" or e[3] == "10.0.1.1") and e[5].id == 80, e and tostring(e[3]))

-- 7. traceroute's TTLs: 1 dies at the router, 2 gets there
clear()
A.echo("10.0.2.5", 81, 1, 1)
A.echo("10.0.2.5", 81, 2, 2)
run()
local ev = events(1, "net_icmp")
check("TTL 1: time exceeded from the router; TTL 2: the reply",
    #ev == 2 and ev[1][2] == "timeexceeded" and ev[1][3] == "10.0.1.1" and ev[1][5].seq == 1
        and ev[2][2] == "reply" and ev[2][3] == "10.0.2.5" and ev[2][5] == 2)

-- 8. broadcast stays on its segment
local pc9, pb9 = C.udpOpen(9), B.udpOpen(9)
A.udpSend(pa, "255.255.255.255", 9, "anyone?")
A.udpSend(pa, "10.0.1.255", 9, "this net?")
run()
check("broadcast: on the segment (C gets both), not through the router (B none)",
    C.udpTake(9).data == "anyone?" and C.udpTake(9).data == "this net?" and B.udpTake(9) == nil)

-- 8b. VLANs: D is on the same wire, on VLAN 20
local m, ch, v = N.link("back.20")
check("an interface name's modem, channel and VLAN", m == "back" and ch == N.CHANNEL + 20 and v == 20
    and N.link("back") == "back" and select(2, N.link("back")) == N.CHANNEL and N.link("back.5000") == nil)
local pd9 = D.udpOpen(9)
A.udpSend(pa, "255.255.255.255", 9, "untagged")
run()
check("VLAN 20 doesn't hear the untagged network's broadcast, on the same wire", D.udpTake(9) == nil)
clear()
D.echo("10.0.1.2", 90, 1)
run()
e = events(4, "net_icmp")[1]
check("but reaches it through the router's trunk (left.20 -> left): a reply, TTL one less",
    e and e[2] == "reply" and e[3] == "10.0.1.2" and e[6] == N.TTL - 1, e and tostring(e[2]))
check("the router's two interfaces on one modem: one MAC each", R1.ifaces["left.20"].mac == "10:left.20"
    and R1.ifaces.left.mac == "10:left")

-- 9. a closed port
clear()
A.udpSend(pa, "10.0.2.5", 4444, "x")
run()
e = events(1, "net_icmp")[1]
check("a closed port: port unreachable from the host", e and e[2] == "unreachable" and e[3] == "10.0.2.5"
    and e[4] == "port" and e[5].dport == 4444)

-- 10. loopback, and a port in use
local lo = A.udpOpen(6000)
A.udpSend(pa, "127.0.0.1", 6000, "me")
A.udpSend(pa, "10.0.1.2", 6000, "me too")
check("loopback and its own address: delivered straight", A.udpTake(lo).data == "me" and A.udpTake(lo).data == "me too")
check("a port in use can't be opened twice", A.udpOpen(6000) == nil and A.udpOpen() >= 49152)
check("a computer with no route there: sendIP says so",
    select(2, computer(99).sendIP("10.0.0.1", "udp", {})):find("no route") ~= nil)

-- 11. the hook: a frame handled once, however many coroutines see it
local H = computer(20)
plug(H, "back", "10.0.1.20/24", "lanA")
local handled = 0
local realHandle = H.handleFrame
H.handleFrame = function(...) handled = handled + 1; return realHandle(...) end
local timers = 0
local fakeOs = { pullEventRaw = function(f) return coroutine.yield(f) end,
                 startTimer = function() timers = timers + 1; return timers end }
N.hook(H, fakeOs)
local got = {}
local function waiter(tag)
    return coroutine.create(function()
        local ev = fakeOs.pullEventRaw("custom")
        got[#got + 1] = tag .. ":" .. ev
    end)
end
local c1, c2 = waiter("one"), waiter("two")
coroutine.resume(c1); coroutine.resume(c2)
local frame = { ccnet = 1, dst = N.BROADCAST, src = "1:back", type = "arp",
                data = { op = "request", sha = "1:back", spa = N.parseIP("10.0.1.2"), tpa = N.parseIP("10.0.1.20") } }
coroutine.resume(c1, "modem_message", "back", N.CHANNEL, N.CHANNEL, frame, 3)
coroutine.resume(c2, "modem_message", "back", N.CHANNEL, N.CHANNEL, frame, 3)
check("hooked: a frame two coroutines see is handled once, and neither returns for it",
    handled == 1 and #got == 0, handled .. " times")
coroutine.resume(c1, "modem_message", "back", 99, 99, { ccnet = 1 }, 3)
coroutine.resume(c1, "modem_message", "back", N.CHANNEL + 20, N.CHANNEL + 20, { ccnet = 1 }, 3)
check("a message on another channel (or a VLAN it isn't on) isn't the stack's", handled == 1)
coroutine.resume(c1, "custom"); coroutine.resume(c2, "custom")
check("the event they wait for still reaches them", #got == 2)
H.unhook()
check("unhooked: os.pullEventRaw as it was", fakeOs.pullEventRaw ~= nil and handled == 1)

-- 12. the settings
local store = {
    ["net.if.back"] = "10.0.1.2/24", ["net.if.modem_0"] = "192.168.5.1/24", ["net.if.back.30"] = "10.0.30.1/24",
    ["net.forward"] = true,
    ["net.routes"] = "10.0.2.0/24 via 10.0.1.1, default via 192.168.5.254 dev modem_0",
    ["net.hosts"] = "router=10.0.1.1, b = 10.0.2.5",
}
local cfg = N.config({ get = function(k) return store[k] end,
    getNames = function() local t = {} for k in pairs(store) do t[#t + 1] = k end return t end })
check("settings: interfaces (VLANs too), routes (dev too), forwarding, hosts",
    cfg.ifaces.back == "10.0.1.2/24" and cfg.ifaces.modem_0 == "192.168.5.1/24" and cfg.forward
        and cfg.ifaces["back.30"] == "10.0.30.1/24"
        and #cfg.routes == 2 and cfg.routes[2].net == "default" and cfg.routes[2].iface == "modem_0"
        and cfg.hosts.router == "10.0.1.1" and cfg.hosts.b == "10.0.2.5")
