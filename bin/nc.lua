-- nc.lua -- netcat: TCP connections and UDP datagrams over the network stack
--
--   nc [-v] [-w seconds] host port          connect (TCP); typed lines go, what comes is printed
--   nc -l [-v] [-p port | port]             wait for one connection, then the same
--   nc -u [-v] [-p port] [-w seconds] host port      send each line as a UDP datagram
--   nc -u -l [-v] port                               print the datagrams that come to port
--
-- TCP (the default): each line of standard input goes down the connection
-- with "\n" after it, and whatever comes back is printed as it arrives.
-- When the input ends (Ctrl+T at the keyboard), nc closes its half and
-- prints on until the other side closes; with -w, at most that many
-- seconds more.  It also ends when the other side closes.  -l listens on
-- port for one connection.  -v says who connected, and how it ended.
-- Carriage returns before a newline aren't printed to the screen.
--
-- UDP (-u): lines go as datagrams to host:port (from -p port, else any
-- free one); what comes back to that port is printed meanwhile, and for
-- -w (1) seconds after the input ends.  -l prints every datagram that
-- comes to port until Ctrl+T.  -v puts "from address:port" first.  A
-- datagram that's a string prints as it is; anything else (a table)
-- serialised.
-- The network must be up (`ip up`).  Exit status 1 if the connection
-- couldn't be made or broke.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("nc",
    "nc [-v] [-w seconds] host port | nc -l [-v] [-p port | port] | nc -u [-v] [-p port] [-w seconds] host port | nc -u -l [-v] port")
local net = require("net")
local opts, operands = cu.getopt({ ... }, "ulvp:w:")

local S, why = net.stack()
if not S then cu.fail(why, 2); return cu.exit() end
local wait = opts.w and tonumber(opts.w)
if opts.w and not wait then cu.usageError("bad -w " .. opts.w) end

-- Run fn, taking Ctrl+T (here, after the input) as the end.
local function guarded(fn, ...)
    local ok, e = pcall(fn, ...)
    if not ok and e ~= "Terminated" then error(e, 0) end
end

--------------------------------------------------------------------------
-- UDP
--------------------------------------------------------------------------
if opts.u then
    local function show(data, from, port)
        if opts.v then io.write(string.format("from %s:%s: ", tostring(from), tostring(port))) end
        local s = type(data) == "string" and data or textutils.serialise(data, { compact = true })
        io.write(s, s:sub(-1) == "\n" and "" or "\n")
    end
    local function printing(sock)
        while true do
            local data, from, p = sock:receive()
            if data ~= nil then show(data, from, p) end
        end
    end

    if opts.l then
        local port = tonumber(operands[1] or opts.p)
        if not port or #operands > 1 then cu.usageError() end
        local sock, err = net.udp(port)
        if not sock then cu.fail(err, 2); return cu.exit() end
        guarded(printing, sock)
        sock:close()
        return cu.exit()
    end

    if #operands ~= 2 then cu.usageError() end
    local host, port = operands[1], tonumber(operands[2])
    if not port then cu.usageError("bad port " .. operands[2]) end
    if not net.resolve(host) then cu.fail("unknown host " .. host, 2); return cu.exit() end
    local sock, err = net.udp(opts.p and tonumber(opts.p))
    if not sock then cu.fail(err, 2); return cu.exit() end
    guarded(parallel.waitForAny,
        function()
            for line in cu.lines({}) do
                local sent, why2 = sock:send(host, port, line)
                if not sent then cu.fail(why2) end
            end
            sleep(wait or 1)
        end,
        function() printing(sock) end)
    sock:close()
    return cu.exit()
end

--------------------------------------------------------------------------
-- TCP
--------------------------------------------------------------------------
local conn
if opts.l then
    local port = tonumber(operands[1] or opts.p)
    if not port or #operands > 1 then cu.usageError() end
    local l, err = net.listen(port)
    if not l then cu.fail(err, 2); return cu.exit() end
    guarded(function() conn = l:accept() end)
    l:close()
    if not conn then return cu.exit() end
    if opts.v then
        local ip, p = conn:remote()
        printError("connection from " .. ip .. ":" .. p)
    end
else
    if #operands ~= 2 then cu.usageError() end
    local host, port = operands[1], tonumber(operands[2])
    if not port then cu.usageError("bad port " .. operands[2]) end
    local err
    conn, err = net.connect(host, port)
    if not conn then cu.fail(host .. " " .. port .. ": " .. err); return cu.exit() end
    if opts.v then printError("connected to " .. host .. " " .. port) end
end

local screen = cu.isTerminal()
local broke
guarded(parallel.waitForAny,
    function()
        for line in cu.lines({}) do
            if not conn:send(line .. "\n") then return end
        end
        conn:close()
        if wait then sleep(wait) else while true do os.pullEvent("never") end end
    end,
    function()
        while true do
            local s, e = conn:read()
            if not s then
                if e ~= "closed" then broke = e end
                return
            end
            io.write(screen and s:gsub("\r\n", "\n") or s)
        end
    end)
local state = conn:state()
if state ~= "CLOSED" then conn:close() end
if broke then cu.fail(broke) elseif opts.v then printError("closed") end
return cu.exit()
