-- net.lua -- a small layered network stack over ComputerCraft modems
--
--   local net = require("net")
--   local s = net.stack()                  -- the running one (`ip up` starts it)
--   local sock = net.udp()                 -- a UDP socket, any free port
--   sock:send("10.0.2.5", 7, "hello")
--   local data, from, port = sock:receive(5)
--
-- Layers, as on Ethernet and IPv4, kept small:
--
--  * Link (layer 2): an interface is a modem (wired or wireless, named as
--    a peripheral: "back", "modem_0") and a channel, like an Ethernet
--    segment.  "back" sends and listens on net.CHANNEL (4040), untagged;
--    "back.20" is VLAN 20 on the same modem, channel 4040 + 20: each
--    channel is its own segment (and broadcast domain) on the shared wire,
--    so one modem can carry several networks, a router's trunk.  VLANs
--    1-4094.  A frame is { ccnet = 1, dst = MAC, src = MAC, type = "arp" |
--    "ip", data = ... }; a MAC is "<computer id>:<interface>" ("12:back.20"),
--    the broadcast MAC "*".  A frame for another MAC is ignored.
--  * ARP: who has 10.0.1.5?  A request is broadcast; the owner answers
--    with its MAC.  Answers are kept ARP_TTL seconds.  Packets wait while
--    an address is asked for (ARP_TRIES requests, a second apart), then
--    are dropped as "host unreachable".
--  * IP (layer 3): addresses "a.b.c.d" with a prefix length ("10.0.1.5/24"),
--    a packet { src, dst, ttl, proto = "icmp" | "udp", data, id }.  Routes:
--    each interface's own network, and static ones ("10.0.2.0/24 via
--    10.0.1.1"; "default" is 0.0.0.0/0); the longest prefix wins.  A host
--    takes packets for its addresses, 127.x.x.x, 255.255.255.255 and its
--    networks' broadcast addresses; a router (forward = true) passes the
--    rest on, one less TTL.
--  * ICMP: echo and echo reply (ping), destination unreachable (no route:
--    "net"; no ARP answer: "host"; no socket: "port") and time exceeded
--    (TTL ran out: traceroute uses it).  Never an error about an error.
--  * UDP (layer 4): { sport, dport, data }; data is any value a modem can
--    carry (strings, numbers, tables).  Sockets queue what comes in.
--
-- ComputerCraft has no background programs on a plain computer, so the
-- running stack lives in _G.ccnet and handles the network as events pass:
-- net.hook() wraps os.pullEventRaw, which every program's os.pullEvent,
-- sleep, read and parallel go through.  It answers ARP and ping, forwards,
-- and fills sockets whenever anything on the computer is waiting for an
-- event, which is nearly always.  A program that computes for a long time
-- without waiting holds it up (CC queues up to 256 events meanwhile).

local N = {}
N.CHANNEL = 4040
N.BROADCAST = "*"
N.TTL = 64
N.ALL = 4294967295              -- 255.255.255.255
local ARP_TTL = 300
local ARP_RETRY, ARP_TRIES = 1, 3
local QUEUE_MAX = 32            -- packets waiting on one ARP answer
local SOCKET_MAX = 64           -- datagrams a socket holds unread
local EPHEMERAL = 49152

--------------------------------------------------------------------------
-- Addresses
--------------------------------------------------------------------------
function N.parseIP(s)
    if type(s) == "number" then return s end
    if type(s) ~= "string" then return nil end
    local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

function N.ipString(n)
    if type(n) ~= "number" then return tostring(n) end
    local d = n % 256; n = (n - d) / 256
    local c = n % 256; n = (n - c) / 256
    local b = n % 256
    local a = (n - b) / 256
    return string.format("%d.%d.%d.%d", a, b, c, d)
end

-- "10.0.1.5/24" -> ip, 24 ("default" is 0.0.0.0/0; no /len: 32).
function N.parseCIDR(s)
    if s == "default" then return 0, 0 end
    local ip, len = tostring(s):match("^([%d%.]+)/(%d+)$")
    if not ip then ip, len = s, "32" end
    ip, len = N.parseIP(ip), tonumber(len)
    if not ip or not len or len > 32 then return nil end
    return ip, len
end

-- An interface name's modem and channel: "back" -> "back", 4040;
-- "back.20" -> "back", 4060 (VLAN 20).  nil for a bad VLAN.
function N.link(name)
    local modem, vlan = name:match("^(.-)%.(%d+)$")
    if not modem then return name, N.CHANNEL, nil end
    vlan = tonumber(vlan)
    if vlan < 1 or vlan > 4094 then return nil end
    return modem, N.CHANNEL + vlan, vlan
end

local function netOf(ip, len)
    if len <= 0 then return 0 end
    local size = 2 ^ (32 - len)
    return math.floor(ip / size) * size
end
local function broadcastOf(ip, len) return netOf(ip, len) + 2 ^ (32 - len) - 1 end
N.netOf, N.broadcastOf = netOf, broadcastOf

function N.cidrString(ip, len) return N.ipString(ip) .. "/" .. len end

--------------------------------------------------------------------------
-- The stack
--------------------------------------------------------------------------
-- opts: id (the computer's), transmit(ifc, frame) (ifc.modem, ifc.channel),
-- queue(event, ...)
-- (os.queueEvent), clock() (seconds), forward (a router), log(msg).
function N.new(opts)
    local S = {
        id = opts.id, forward = opts.forward or false,
        ifaces = {}, links = {}, routes = {}, arp = {}, pending = {}, sockets = {},
        counters = { rx = 0, tx = 0, forwarded = 0, dropped = 0, arpAsked = 0 },
        log = {},
    }
    local clock = opts.clock or os.clock
    local transmit = opts.transmit
    local queue = opts.queue or os.queueEvent
    local nextId, nextPort = 0, EPHEMERAL
    S.wantTick = function() end         -- the hook asks for a tick soon

    local function note(msg)
        S.log[#S.log + 1] = msg
        if #S.log > 50 then table.remove(S.log, 1) end
        if opts.log then opts.log(msg) end
    end
    S.note = note

    ----------------------------------------------------------------------
    -- Configuration
    ----------------------------------------------------------------------
    local function rebuildConnected()
        local keep = {}
        for _, r in ipairs(S.routes) do if not r.connected then keep[#keep + 1] = r end end
        for _, ifc in pairs(S.ifaces) do
            keep[#keep + 1] = { net = netOf(ifc.ip, ifc.len), len = ifc.len, iface = ifc.name, connected = true }
        end
        S.routes = keep
    end

    function S.addInterface(name, cidr)
        local ip, len = N.parseCIDR(cidr)
        if not ip then return false, "bad address " .. tostring(cidr) end
        local modem, channel, vlan = N.link(name)
        if not modem then return false, "bad VLAN in " .. name .. " (1-4094)" end
        if S.ifaces[name] then S.links[S.ifaces[name].modem .. "|" .. S.ifaces[name].channel] = nil end
        S.ifaces[name] = { name = name, ip = ip, len = len, mac = S.id .. ":" .. name, rx = 0, tx = 0,
                           modem = modem, channel = channel, vlan = vlan }
        S.links[modem .. "|" .. channel] = name
        S.arp[name] = S.arp[name] or {}
        rebuildConnected()
        return true
    end

    function S.removeInterface(name)
        local ifc = S.ifaces[name]
        if ifc then S.links[ifc.modem .. "|" .. ifc.channel] = nil end
        S.ifaces[name] = nil
        S.arp[name] = nil
        local keep = {}
        for _, r in ipairs(S.routes) do if r.iface ~= name then keep[#keep + 1] = r end end
        S.routes = keep
        rebuildConnected()
    end

    -- A static route: cidr via gw (the interface whose network has gw, or
    -- `iface`).
    function S.addRoute(cidr, gw, iface)
        local net, len = N.parseCIDR(cidr)
        if not net then return false, "bad network " .. tostring(cidr) end
        local g = gw and N.parseIP(gw)
        if gw and not g then return false, "bad gateway " .. tostring(gw) end
        if not iface and g then
            for _, ifc in pairs(S.ifaces) do
                if netOf(g, ifc.len) == netOf(ifc.ip, ifc.len) then iface = ifc.name end
            end
        end
        if not iface or not S.ifaces[iface] then
            return false, "no interface on " .. (gw and ("the gateway's network (" .. gw .. ")") or "that network")
        end
        S.deleteRoute(cidr)
        S.routes[#S.routes + 1] = { net = netOf(net, len), len = len, gw = g, iface = iface }
        return true
    end

    function S.deleteRoute(cidr)
        local net, len = N.parseCIDR(cidr)
        if not net then return false end
        local keep, gone = {}, false
        for _, r in ipairs(S.routes) do
            if not r.connected and r.net == netOf(net, len) and r.len == len then gone = true
            else keep[#keep + 1] = r end
        end
        S.routes = keep
        return gone
    end

    -- The route to dst: the longest prefix that holds it.
    function S.route(dst)
        local best
        for _, r in ipairs(S.routes) do
            if netOf(dst, r.len) == r.net and (not best or r.len > best.len) and S.ifaces[r.iface] then best = r end
        end
        return best
    end

    local function isMine(ip)
        if math.floor(ip / 16777216) == 127 then return true end
        for _, ifc in pairs(S.ifaces) do if ifc.ip == ip then return true end end
        return false
    end
    S.isMine = isMine

    ----------------------------------------------------------------------
    -- Link
    ----------------------------------------------------------------------
    local function sendFrame(ifc, dst, kind, data)
        ifc.tx = ifc.tx + 1
        S.counters.tx = S.counters.tx + 1
        transmit(ifc, { ccnet = 1, dst = dst, src = ifc.mac, type = kind, data = data })
    end

    local function arpAsk(p)
        local ifc = S.ifaces[p.iface]
        if not ifc then return end
        p.tries, p.next = p.tries + 1, clock() + ARP_RETRY
        S.counters.arpAsked = S.counters.arpAsked + 1
        sendFrame(ifc, N.BROADCAST, "arp", { op = "request", sha = ifc.mac, spa = ifc.ip, tpa = p.ip })
        S.wantTick()
    end

    -- Learn ip -> mac on an interface, and send what was waiting for it.
    local function learn(ifc, ip, mac)
        S.arp[ifc.name][ip] = { mac = mac, expires = clock() + ARP_TTL }
        local key = ifc.name .. "|" .. ip
        local p = S.pending[key]
        if p then
            S.pending[key] = nil
            for _, q in ipairs(p.packets) do sendFrame(ifc, mac, "ip", q.pkt) end
        end
    end

    local icmpError                 -- (below)

    -- Send pkt out of route r's interface: to the gateway or, on the
    -- interface's own network, straight to dst (asking ARP first).
    local function output(pkt, r, mine)
        local ifc = S.ifaces[r.iface]
        if pkt.dst == N.ALL or pkt.dst == broadcastOf(ifc.ip, ifc.len) then
            return sendFrame(ifc, N.BROADCAST, "ip", pkt)
        end
        local hop = r.gw or pkt.dst
        local e = S.arp[ifc.name][hop]
        if e and e.expires > clock() then return sendFrame(ifc, e.mac, "ip", pkt) end
        local key = ifc.name .. "|" .. hop
        local p = S.pending[key]
        if not p then
            p = { iface = ifc.name, ip = hop, packets = {}, tries = 0, next = 0 }
            S.pending[key] = p
        end
        if #p.packets < QUEUE_MAX then p.packets[#p.packets + 1] = { pkt = pkt, mine = mine }
        else S.counters.dropped = S.counters.dropped + 1 end
        if p.tries == 0 then arpAsk(p) end
    end

    ----------------------------------------------------------------------
    -- IP out
    ----------------------------------------------------------------------
    local deliver                   -- (below)

    -- Send data to dst (an address, as a string or number).  True, or
    -- false and why (no route).  An ARP that gets no answer comes back
    -- later as a net_unreachable event.
    function S.sendIP(dst, proto, data, ttl)
        dst = N.parseIP(dst)
        if not dst then return false, "bad address" end
        nextId = nextId + 1
        if isMine(dst) then
            deliver({ src = dst, dst = dst, ttl = ttl or N.TTL, proto = proto, data = data, id = nextId }, "lo")
            return true
        end
        if dst == N.ALL then
            local any = false
            for _, ifc in pairs(S.ifaces) do
                sendFrame(ifc, N.BROADCAST, "ip",
                    { src = ifc.ip, dst = dst, ttl = ttl or N.TTL, proto = proto, data = data, id = nextId })
                any = true
            end
            return any, not any and "no interfaces" or nil
        end
        local r = S.route(dst)
        if not r then return false, "no route to " .. N.ipString(dst) end
        local ifc = S.ifaces[r.iface]
        output({ src = ifc.ip, dst = dst, ttl = ttl or N.TTL, proto = proto, data = data, id = nextId }, r, true)
        return true
    end

    -- An ICMP error about pkt, to its sender (or, if this computer sent
    -- it, an event for the program that did).
    icmpError = function(pkt, kind, code, mine)
        if pkt.proto == "icmp" and type(pkt.data) == "table" and pkt.data.type ~= "echo" then return end
        local d = type(pkt.data) == "table" and pkt.data or {}
        local orig = { src = pkt.src, dst = pkt.dst, proto = pkt.proto, id = d.id, seq = d.seq,
                       sport = d.sport, dport = d.dport }
        if mine or isMine(pkt.src) then
            queue("net_icmp", kind, N.ipString(pkt.dst), code, orig)
            return
        end
        S.sendIP(pkt.src, "icmp", { type = kind, code = code, orig = orig })
    end

    ----------------------------------------------------------------------
    -- In
    ----------------------------------------------------------------------
    local function udpIn(pkt, iface)
        local d = pkt.data
        if type(d) ~= "table" or type(d.dport) ~= "number" then return end
        local sock = S.sockets[d.dport]
        if not sock then
            if pkt.dst ~= N.ALL and isMine(pkt.dst) then icmpError(pkt, "unreachable", "port") end
            return
        end
        if #sock.queue >= SOCKET_MAX then S.counters.dropped = S.counters.dropped + 1; return end
        sock.queue[#sock.queue + 1] = { data = d.data, src = N.ipString(pkt.src), sport = d.sport, iface = iface }
        queue("net_udp", d.dport)
    end

    deliver = function(pkt, iface)
        if pkt.proto == "icmp" and type(pkt.data) == "table" then
            local d = pkt.data
            if d.type == "echo" then
                if pkt.dst ~= N.ALL then S.sendIP(pkt.src, "icmp", { type = "reply", id = d.id, seq = d.seq, data = d.data }) end
            elseif d.type == "reply" then
                queue("net_icmp", "reply", N.ipString(pkt.src), d.id, d.seq, pkt.ttl)
            elseif d.type == "unreachable" or d.type == "timeexceeded" then
                queue("net_icmp", d.type, N.ipString(pkt.src), d.code, d.orig or {})
            end
        elseif pkt.proto == "udp" then
            udpIn(pkt, iface)
        end
    end

    local function ipIn(ifc, pkt)
        if type(pkt) ~= "table" or type(pkt.src) ~= "number" or type(pkt.dst) ~= "number"
            or type(pkt.ttl) ~= "number" then return end
        if pkt.dst == N.ALL or isMine(pkt.dst) or pkt.dst == broadcastOf(ifc.ip, ifc.len) then
            return deliver(pkt, ifc.name)
        end
        if not S.forward then return end
        if pkt.ttl <= 1 then
            S.counters.dropped = S.counters.dropped + 1
            return icmpError(pkt, "timeexceeded", "ttl")
        end
        local r = S.route(pkt.dst)
        if not r then
            S.counters.dropped = S.counters.dropped + 1
            return icmpError(pkt, "unreachable", "net")
        end
        local copy = {}
        for k, v in pairs(pkt) do copy[k] = v end
        copy.ttl = pkt.ttl - 1
        S.counters.forwarded = S.counters.forwarded + 1
        output(copy, r, false)
    end

    local function arpIn(ifc, a)
        if type(a) ~= "table" or type(a.spa) ~= "number" or type(a.sha) ~= "string" then return end
        local known = S.arp[ifc.name][a.spa]
        if a.tpa == ifc.ip then
            learn(ifc, a.spa, a.sha)
            if a.op == "request" then
                sendFrame(ifc, a.sha, "arp", { op = "reply", sha = ifc.mac, spa = ifc.ip, tha = a.sha, tpa = a.spa })
            end
        elseif known then
            learn(ifc, a.spa, a.sha)        -- (it moved: keep up)
        end
    end

    -- A frame from interface `iface`.
    function S.handleFrame(iface, f)
        if type(f) ~= "table" or f.ccnet ~= 1 then return end
        local ifc = S.ifaces[iface]
        if not ifc or f.src == ifc.mac then return end
        if f.dst ~= ifc.mac and f.dst ~= N.BROADCAST then return end
        ifc.rx = ifc.rx + 1
        S.counters.rx = S.counters.rx + 1
        if f.type == "arp" then arpIn(ifc, f.data)
        elseif f.type == "ip" then ipIn(ifc, f.data) end
    end

    -- A modem_message: the interface that's modem `side` on `channel`
    -- takes it (none: not the stack's).  True if it was the stack's.
    function S.receive(side, channel, f)
        local name = S.links[side .. "|" .. tostring(channel)]
        if not name then return false end
        S.handleFrame(name, f)
        return true
    end

    -- ARP retries and expiry; true while something is still waiting.
    function S.tick()
        local now = clock()
        for key, p in pairs(S.pending) do
            if now >= p.next then
                if p.tries >= ARP_TRIES then
                    S.pending[key] = nil
                    note("no ARP answer from " .. N.ipString(p.ip) .. " on " .. p.iface)
                    for _, q in ipairs(p.packets) do
                        S.counters.dropped = S.counters.dropped + 1
                        icmpError(q.pkt, "unreachable", "host", q.mine)
                    end
                else
                    arpAsk(p)
                end
            end
        end
        for _, cache in pairs(S.arp) do
            for ip, e in pairs(cache) do if e.expires <= now then cache[ip] = nil end end
        end
        return next(S.pending) ~= nil
    end

    ----------------------------------------------------------------------
    -- UDP sockets and ping
    ----------------------------------------------------------------------
    function S.udpOpen(port)
        if port then
            if S.sockets[port] then return nil, "port " .. port .. " is in use" end
        else
            for _ = 1, 16384 do
                nextPort = nextPort >= 65535 and EPHEMERAL or nextPort + 1
                if not S.sockets[nextPort] then port = nextPort; break end
            end
            if not port then return nil, "no free port" end
        end
        S.sockets[port] = { queue = {} }
        return port
    end
    function S.udpClose(port) S.sockets[port] = nil end
    function S.udpSend(sport, dst, dport, data)
        return S.sendIP(dst, "udp", { sport = sport, dport = dport, data = data })
    end
    function S.udpTake(port)
        local sock = S.sockets[port]
        if sock and sock.queue[1] then return table.remove(sock.queue, 1) end
    end

    function S.echo(dst, id, seq, ttl)
        return S.sendIP(dst, "icmp", { type = "echo", id = id, seq = seq }, ttl)
    end

    return S
end

--------------------------------------------------------------------------
-- Running it: the hook over os.pullEventRaw
--------------------------------------------------------------------------
-- Install S into `osT` (os): every event any program waits for passes it
-- first.  A modem_message is handled once however many coroutines see it
-- (parallel hands each the same event).  Returns an uninstall function.
function N.hook(S, osT)
    local raw = osT.pullEventRaw
    local seen = setmetatable({}, { __mode = "k" })
    local timer
    S.wantTick = function() if not timer then timer = osT.startTimer(0.5) end end
    local function handle(ev, a, b, c, d)
        if S.dead then return end           -- (taken down, but something hooked on top of it)
        if ev == "modem_message" then
            if type(d) == "table" and not seen[d] and S.links[tostring(a) .. "|" .. tostring(b)] then
                seen[d] = true
                S.receive(a, b, d)
            end
        elseif ev == "timer" and a == timer then
            timer = nil
            if S.tick() then S.wantTick() end
        end
    end
    local function pull(filter)
        while true do
            local ev = table.pack(raw())
            local ok, err = pcall(handle, table.unpack(ev, 1, ev.n))
            if not ok then S.note("net: " .. tostring(err)) end
            if filter == nil or ev[1] == filter or ev[1] == "terminate" then return table.unpack(ev, 1, ev.n) end
        end
    end
    osT.pullEventRaw = pull
    S.unhook = function() if osT.pullEventRaw == pull then osT.pullEventRaw = raw end end
    return S.unhook
end

--------------------------------------------------------------------------
-- Configuration, kept in CraftOS's settings
--------------------------------------------------------------------------
-- net.if.<iface> = "10.0.1.5/24"; net.routes = "10.0.2.0/24 via 10.0.1.1,
-- default via 10.0.1.1"; net.forward = true on a router; net.hosts =
-- "router=10.0.1.1, b=10.0.2.5".
function N.config(st)
    st = st or settings
    local cfg = { ifaces = {}, routes = {}, forward = st.get("net.forward") == true, hosts = {} }
    for _, name in ipairs(st.getNames()) do
        local iface = name:match("^net%.if%.(.+)$")
        if iface and st.get(name) and st.get(name) ~= "" then cfg.ifaces[iface] = st.get(name) end
    end
    for item in tostring(st.get("net.routes") or ""):gmatch("[^,]+") do
        local net, gw, dev = item:match("^%s*(%S+)%s+via%s+(%S+)%s*(.-)%s*$")
        if net then cfg.routes[#cfg.routes + 1] = { net = net, gw = gw, iface = dev:match("^dev%s+(%S+)$") } end
    end
    for item in tostring(st.get("net.hosts") or ""):gmatch("[^,]+") do
        local name, ip = item:match("^%s*([^=%s]+)%s*=%s*(%S+)%s*$")
        if name then cfg.hosts[name] = ip end
    end
    return cfg
end

-- A stack set up as cfg says, on this computer's modems.
function N.fromConfig(cfg, env)
    env = env or {}
    local per = env.peripheral or peripheral
    local S = N.new({
        id = env.id or os.getComputerID(), forward = cfg.forward, clock = env.clock,
        queue = env.queue, log = env.log,
        transmit = function(ifc, frame) per.call(ifc.modem, "transmit", ifc.channel, ifc.channel, frame) end,
    })
    local problems = {}
    for iface, cidr in pairs(cfg.ifaces) do
        local modem, channel = N.link(iface)
        if not modem then
            problems[#problems + 1] = iface .. ": bad VLAN (1-4094)"
        elseif per.getType(modem) ~= "modem" then
            problems[#problems + 1] = iface .. ": no modem called " .. modem
        else
            per.call(modem, "open", channel)
            local ok, err = S.addInterface(iface, cidr)
            if not ok then problems[#problems + 1] = iface .. ": " .. err end
        end
    end
    for _, r in ipairs(cfg.routes) do
        local ok, err = S.addRoute(r.net, r.gw, r.iface)
        if not ok then problems[#problems + 1] = r.net .. " via " .. r.gw .. ": " .. err end
    end
    S.hosts = cfg.hosts
    return S, problems
end

-- Bring the network up as the settings say (again, if it's up already:
-- the old stack is unhooked first).  Returns the stack and a list of
-- problems with the configuration.
function N.up()
    N.down()
    local S, problems = N.fromConfig(N.config())
    N.hook(S, os)
    _G.ccnet = S
    return S, problems
end

-- Take it down.
function N.down()
    local S = _G.ccnet
    if not S then return false end
    S.dead = true
    if S.unhook then S.unhook() end
    for _, ifc in pairs(S.ifaces) do pcall(peripheral.call, ifc.modem, "close", ifc.channel) end
    _G.ccnet = nil
    return true
end

--------------------------------------------------------------------------
-- For programs
--------------------------------------------------------------------------
-- The running stack, or nil and why.
function N.stack()
    if _G.ccnet then return _G.ccnet end
    return nil, "the network isn't up: run `ip up`"
end

-- An address from a name in net.hosts, or the address itself.
function N.resolve(name)
    if N.parseIP(name) then return N.parseIP(name) end
    local S = _G.ccnet
    local h = S and S.hosts and S.hosts[name]
    return h and N.parseIP(h) or nil
end

-- Wait up to `timeout` seconds (nil: for ever) for an event `name` that
-- `want(...)` accepts; its values, or nil on timeout.
function N.await(name, want, timeout)
    local timer = timeout and os.startTimer(timeout)
    while true do
        local ev = table.pack(os.pullEvent())
        if ev[1] == name and (not want or want(table.unpack(ev, 2, ev.n))) then
            if timer then os.cancelTimer(timer) end
            return table.unpack(ev, 2, ev.n)
        elseif ev[1] == "timer" and ev[2] == timer then
            return nil
        end
    end
end

-- A UDP socket on `port` (nil: any free one).
local Socket = {}
Socket.__index = Socket
function N.udp(port)
    local S, why = N.stack()
    if not S then return nil, why end
    local p, err = S.udpOpen(port)
    if not p then return nil, err end
    return setmetatable({ port = p, S = S }, Socket)
end
function Socket:send(host, port, data)
    local dst = N.resolve(host)
    if not dst then return false, "unknown host " .. tostring(host) end
    return self.S.udpSend(self.port, dst, port, data)
end
-- The next datagram's data, sender's address and port; nil on timeout.
function Socket:receive(timeout)
    local deadline = timeout and os.clock() + timeout
    while true do
        local d = self.S.udpTake(self.port)
        if d then return d.data, d.src, d.sport end
        -- (an event can be for a datagram already taken: wait on)
        local left = deadline and deadline - os.clock()
        if left and left <= 0 then return nil end
        if not N.await("net_udp", function(port) return port == self.port end, left) then return nil end
    end
end
function Socket:close() self.S.udpClose(self.port) end

return N
