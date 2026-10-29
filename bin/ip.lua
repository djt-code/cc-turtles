-- ip.lua -- set up and look at the network (lib/net.lua)
--
--   ip                               the interfaces, routes and whether it's up
--   ip up | ip down                  start or stop the network on this computer
--   ip boot                          start it at every boot (a line in startup)
--   ip link                          the modems there are, and which are set up
--   ip addr                          the interfaces' addresses and counts
--   ip addr add <iface> <addr/len>   give an interface an address
--   ip addr del <iface>
--   ip route                         the routing table
--   ip route add <net/len|default> via <gw> [dev <iface>]
--   ip route del <net/len|default>
--   ip neigh                         the ARP cache: addresses and their MACs
--   ip forward [on|off]              route between interfaces (a router)
--   ip host [<name> <addr>]          names for addresses (ping router)
--
-- An interface is a modem by its peripheral name ("back", "modem_0"), or a
-- VLAN on one: "back.20" is VLAN 20 on the back modem, its own network on
-- the same wire.  What's set is kept in settings (net.if.<iface>,
-- net.routes, net.forward, net.hosts) and applies at once if the network
-- is up.  The network runs alongside everything else once `ip up` has
-- started it: see lib/net.lua.  `help network` walks through setting up
-- two networks and a router.

package.path = "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;" .. package.path  -- lib/ is beside bin/
local cu = require("cu").init("ip", "ip [up|down|boot|link|addr|route|neigh|forward|host] ...")
local net = require("net")
local args = { ... }

local function out(...) io.write(...) io.write("\n") end
local function save() settings.save() end

-- the routes setting, as a list of { net, gw, iface }
local function savedRoutes() return net.config().routes end
local function saveRoutes(list)
    local t = {}
    for _, r in ipairs(list) do t[#t + 1] = r.net .. " via " .. r.gw .. (r.iface and (" dev " .. r.iface) or "") end
    settings.set("net.routes", table.concat(t, ", "))
    save()
end

local function showAddr(S)
    if S then
        local names = {}
        for k in pairs(S.ifaces) do names[#names + 1] = k end
        table.sort(names)
        for _, name in ipairs(names) do
            local i = S.ifaces[name]
            out(string.format("%-12s %-18s %-14s rx %d tx %d%s", name, net.cidrString(i.ip, i.len), i.mac, i.rx, i.tx,
                i.vlan and (" (vlan " .. i.vlan .. ")") or ""))
        end
    else
        local cfg = net.config()
        local names = {}
        for k in pairs(cfg.ifaces) do names[#names + 1] = k end
        table.sort(names)
        for _, name in ipairs(names) do out(string.format("%-12s %-18s (not up)", name, cfg.ifaces[name])) end
        if #names == 0 then out("no interfaces: ip addr add <iface> <addr/len>  (ip link lists the modems)") end
    end
end

local function showRoutes(S)
    if S then
        local list = {}
        for _, r in ipairs(S.routes) do list[#list + 1] = r end
        table.sort(list, function(a, b) if a.len ~= b.len then return a.len > b.len end return a.net < b.net end)
        for _, r in ipairs(list) do
            local dest = r.len == 0 and "default" or net.cidrString(r.net, r.len)
            out(string.format("%-18s %s dev %s", dest, r.gw and ("via " .. net.ipString(r.gw)) or "direct", r.iface))
        end
    else
        for _, r in ipairs(savedRoutes()) do
            out(string.format("%-18s via %s%s (not up)", r.net, r.gw, r.iface and (" dev " .. r.iface) or ""))
        end
    end
end

local S = net.stack()
local cmd, sub = args[1], args[2]

if cmd == nil then
    out(S and ("up" .. (S.forward and ", forwarding" or "")) or "down (ip up starts it)")
    showAddr(S)
    showRoutes(S)
elseif cmd == "up" then
    local S2, problems = net.up()
    for _, p in ipairs(problems) do cu.err(p) end
    local n = 0
    for _ in pairs(S2.ifaces) do n = n + 1 end
    out(string.format("up: %d interface%s%s", n, n == 1 and "" or "s", S2.forward and ", forwarding" or ""))
    if #problems > 0 then cu.exit(1) end
elseif cmd == "down" then
    out(net.down() and "down" or "it wasn't up")
elseif cmd == "boot" then
    local line = string.format('shell.run("/%s up")', (shell.getRunningProgram():gsub("%.lua$", "")))
    local target = fs.isDir("/startup") and "/startup/05-net.lua" or "/startup.lua"
    local text = ""
    if fs.exists(target) then local f = fs.open(target, "r"); text = f.readAll() or ""; f.close() end
    if text:find(line, 1, true) then out(target .. " starts it already")
    else
        local f = fs.open(target, "w")
        f.write(line .. "\n" .. text)              -- first: it returns at once
        f.close()
        out("the network starts at boot (" .. target .. ")")
    end
elseif cmd == "link" then
    local cfg = net.config()
    local used, names = {}, {}
    for name in pairs(cfg.ifaces) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local modem = net.link(name)
        if modem then used[modem] = (used[modem] and (used[modem] .. " ") or "") .. name end
    end
    local any = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            any = true
            local wireless = peripheral.call(name, "isWireless")
            out(string.format("%-12s %-9s %s", name, wireless and "wireless" or "wired", used[name] or "(not set up)"))
        end
    end
    if not any then out("no modems") end
elseif cmd == "addr" and (sub == nil or sub == "show") then
    showAddr(S)
elseif cmd == "addr" and sub == "add" and args[3] and args[4] then
    local iface, cidr = args[3], args[4]
    if not net.link(iface) then cu.usageError("bad VLAN in " .. iface .. " (1-4094)") end
    if not net.parseCIDR(cidr) or not cidr:find("/") then cu.usageError("give the address with its prefix: 10.0.1.5/24") end
    settings.set("net.if." .. iface, cidr)
    save()
    if S then
        local modem, channel = net.link(iface)
        if peripheral.getType(modem) ~= "modem" then cu.fail("no modem called " .. modem .. " (saved anyway)")
        else peripheral.call(modem, "open", channel); S.addInterface(iface, cidr) end
    end
    out(iface .. " " .. cidr)
elseif cmd == "addr" and sub == "del" and args[3] then
    settings.unset("net.if." .. args[3])
    save()
    if S and S.ifaces[args[3]] then
        local i = S.ifaces[args[3]]
        S.removeInterface(args[3])
        pcall(peripheral.call, i.modem, "close", i.channel)
    end
    out(args[3] .. " removed")
elseif cmd == "route" and (sub == nil or sub == "show") then
    showRoutes(S)
elseif cmd == "route" and sub == "add" and args[3] and args[4] == "via" and args[5] then
    local r = { net = args[3], gw = args[5], iface = args[6] == "dev" and args[7] or nil }
    if not net.parseCIDR(r.net) then cu.usageError("bad network " .. r.net) end
    if not net.parseIP(r.gw) then cu.usageError("bad gateway " .. r.gw) end
    if S then
        local ok, err = S.addRoute(r.net, r.gw, r.iface)
        if not ok then cu.fail(err); return cu.exit() end
    end
    local list = {}
    for _, x in ipairs(savedRoutes()) do if x.net ~= r.net then list[#list + 1] = x end end
    list[#list + 1] = r
    saveRoutes(list)
    out(r.net .. " via " .. r.gw)
elseif cmd == "route" and sub == "del" and args[3] then
    local list, gone = {}, false
    for _, x in ipairs(savedRoutes()) do if x.net ~= args[3] then list[#list + 1] = x else gone = true end end
    saveRoutes(list)
    if S then gone = S.deleteRoute(args[3]) or gone end
    if not gone then cu.fail("no route " .. args[3]) end
elseif cmd == "neigh" then
    if not S then cu.fail("the network isn't up"); return cu.exit() end
    local any = false
    for iface, cache in pairs(S.arp) do
        for ip, e in pairs(cache) do
            any = true
            out(string.format("%-16s %-14s dev %s", net.ipString(ip), e.mac, iface))
        end
    end
    if not any then out("(empty)") end
elseif cmd == "forward" then
    if sub == "on" or sub == "off" then
        settings.set("net.forward", sub == "on")
        save()
        if S then S.forward = sub == "on" end
    end
    out("forwarding " .. ((settings.get("net.forward") == true) and "on" or "off"))
elseif cmd == "host" then
    local hosts = net.config().hosts
    if sub and args[3] then
        if not net.parseIP(args[3]) then cu.usageError("bad address " .. args[3]) end
        hosts[sub] = args[3]
        local t = {}
        for k, v in pairs(hosts) do t[#t + 1] = k .. "=" .. v end
        table.sort(t)
        settings.set("net.hosts", table.concat(t, ", "))
        save()
        if S then S.hosts = hosts end
    end
    local names = {}
    for k in pairs(hosts) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do out(string.format("%-16s %s", k, hosts[k])) end
else
    cu.usageError()
end
return cu.exit()
