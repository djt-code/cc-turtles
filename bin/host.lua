-- host.lua -- ask DNS for a name's addresses, or an address's name
--
--   host [-t type] name [server]
--
-- A name's addresses (its A records), or an address's name (the PTR
-- record at d.c.b.a.in-addr.arpa), with the aliases (CNAMEs) on the way.
-- -t asks for A, CNAME or PTR records instead.  The DNS servers asked
-- are net.dns's (`ip dns`), primary then secondary, or server alone.
-- DNS only, as the real host does it: names from `ip host` aren't looked
-- at (ping, nc and the rest look at both: lib/netdb).  Exit status 1 if
-- there's no such name or record, 2 for trouble (no servers, none
-- answered, the network isn't up).

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("host", "host [-t type] name [server]")
local net = require("net")
local netdb = require("netdb")
local opts, operands = cu.getopt({ ... }, "t:")
if #operands < 1 or #operands > 2 then cu.usageError() end
local name, server = operands[1], operands[2]
if server and not net.parseIP(server) then cu.usageError("bad server address " .. server) end
local qtype = opts.t and opts.t:upper()
if net.parseIP(name) then
    local a, b, c, d = net.ipString(net.parseIP(name)):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    name = d .. "." .. c .. "." .. b .. "." .. a .. ".in-addr.arpa"
    qtype = qtype or "PTR"
end
qtype = qtype or "A"

local answers, why, kind = netdb.res_query(name, qtype, server and { server })
if not answers then
    if kind == "NXDOMAIN" then
        io.write("Host ", name, " not found: 3(NXDOMAIN)\n")
        return cu.exit(1)
    end
    cu.fail(why, 2)
    return cu.exit()
end
local said = 0
for _, rr in ipairs(answers) do
    local what = rr.type == "A" and " has address " .. rr.data
        or rr.type == "CNAME" and " is an alias for " .. rr.data .. "."
        or rr.type == "PTR" and " domain name pointer " .. rr.data .. "."
    if what then
        io.write(rr.name, what, "\n")
        said = said + 1
    end
end
if said == 0 then
    io.write(name, " has no ", qtype, " record\n")
    return cu.exit(1)
end
return cu.exit()
