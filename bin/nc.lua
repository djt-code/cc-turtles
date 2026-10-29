-- nc.lua -- send and receive UDP datagrams (netcat, UDP only)
--
--   nc -u [-v] [-p port] [-w seconds] host port      send each line typed (or piped in)
--   nc -u -l [-v] port                               print what comes to port
--
-- Sending: each line of standard input goes to host:port as a datagram
-- (from -p port, else any free one); what comes back to that port is
-- printed meanwhile, and for -w (1) seconds after the input ends (Ctrl+T
-- at the keyboard).  Listening (-l): every datagram that comes to port is
-- printed, until Ctrl+T.  -v puts "from address:port" first.  A datagram
-- that's a string prints as it is; anything else (a table) serialised.
-- -u is required (there's no TCP).  The network must be up (`ip up`).

package.path = "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;" .. package.path  -- lib/ is beside bin/
local cu = require("cu").init("nc", "nc -u [-v] [-p port] [-w seconds] host port | nc -u -l [-v] port")
local net = require("net")
local opts, operands = cu.getopt({ ... }, "ulvp:w:")
if not opts.u then cu.usageError("only UDP: give -u") end

local function show(data, from, port)
    if opts.v then io.write(string.format("from %s:%s: ", tostring(from), tostring(port))) end
    local s = type(data) == "string" and data or textutils.serialise(data, { compact = true })
    io.write(s, s:sub(-1) == "\n" and "" or "\n")
end

local S, why = net.stack()
if not S then cu.fail(why, 2); return cu.exit() end

if opts.l then
    local port = tonumber(operands[1] or opts.p)
    if not port or #operands > 1 then cu.usageError() end
    local sock, err = net.udp(port)
    if not sock then cu.fail(err, 2); return cu.exit() end
    local ok, e = pcall(function()
        while true do
            local data, from, p = sock:receive()
            if data ~= nil then show(data, from, p) end
        end
    end)
    sock:close()
    if not ok and e ~= "Terminated" then error(e, 0) end
    return cu.exit()
end

if #operands ~= 2 then cu.usageError() end
local host, port = operands[1], tonumber(operands[2])
if not port then cu.usageError("bad port " .. operands[2]) end
if not net.resolve(host) then cu.fail("unknown host " .. host, 2); return cu.exit() end
local sock, err = net.udp(opts.p and tonumber(opts.p))
if not sock then cu.fail(err, 2); return cu.exit() end
local wait = tonumber(opts.w or 1) or 1
local ok, e = pcall(parallel.waitForAny,
    function()
        for line in cu.lines({}) do
            local sent, why2 = sock:send(host, port, line)
            if not sent then cu.fail(why2) end
        end
        sleep(wait)
    end,
    function()
        while true do
            local data, from, p = sock:receive()
            if data ~= nil then show(data, from, p) end
        end
    end)
sock:close()
if not ok and e ~= "Terminated" then error(e, 0) end
return cu.exit()
