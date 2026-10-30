-- sim/boot_install.lua
--
-- How ccnix gets on the path at boot, in a shellworld: deploy/boot.lua
-- under a fake /rom/ccnix (the ccnix mod's ROM, with its .manifest and
-- /rom/autorun/ccnix.lua), with no updates, with updates made for this
-- ROM (/ccnix wins, and its own boot.lua takes over), for another ROM
-- (left out), and a whole checkout at /ccnix; what runs at the end of
-- startup (ip up with net.boot; the autoruns after ccnix's, the motd and
-- the startup files, then init alone, or the autostart, ccsh and the
-- stock shell, then shutdown), on a computer and a turtle; the
-- craftix.login shim; an install from before ccnix (/cc-turtles) left
-- alone; install in ROM mode setting the settings only.  Then, with no
-- ROM, deploy/install's startup lines run one by one, and the files of a
-- /startup folder in turn: the same path, help path, alias and order for
-- a checkout.
--
-- The programs that wouldn't return (ccsh, init, the autostarts) and ip
-- are noted in RAN and not run; everything else runs for real.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check
local json = M.json
local function show(s) return (tostring(s):gsub("\n", "|")) end

-- settings and help, as boot and install see them (real globals)
local STORE = {}
settings = {
    get = function(k, d) local v = STORE[k]; if v == nil then return d end return v end,
    set = function(k, v) STORE[k] = v end, unset = function(k) STORE[k] = nil end, save = function() end,
}
local HELP
help = { path = function() return HELP end, setPath = function(p) HELP = p end }
textutils = textutils or M.textutilsApi()
turtle = nil

local function repoFile(path)
    local f = assert(io.open(PROJ .. "/" .. path, "rb"))
    local text = f:read("a")
    f:close()
    return text
end

-- CraftOS's path on a computer, as it is when the autoruns go
local BASE = ".:/rom/programs:/rom/programs/http"
local COMMIT = "1111111111111111111111111111111111111111"
-- what the ROM holds of the repo (the mod puts it all there; this is
-- what boot, ls and the checks touch)
local ROM_FILES = { "bin/ls.lua", "bin/ip.lua", "bin/ccsh.lua", "bin/init.lua", "bin/ccnix.lua", "lib/cu.lua",
                    "turtle/autostart.lua", "pc/router.lua", "help/ls.txt", "deploy/boot.lua", "deploy/install.lua" }
local STUB = { ["bin/ip.lua"] = true, ["bin/ccsh.lua"] = true, ["bin/init.lua"] = true,
               ["turtle/autostart.lua"] = true, ["pc/router.lua"] = true }
local RAN = {}

local function reset(W)
    W.shell.setPath(BASE)
    W.aliases.ls = "list"
    HELP = "/rom/help"
    RAN = {}
    _G.ccnix = nil
end

-- A computer before its autoruns; with a ROM, ccnix in it as the mod
-- puts it: the files, the .manifest and the autorun that runs boot.
local function world(withRom)
    local W = SW.new(PROJ)
    for k in pairs(STORE) do STORE[k] = nil end
    reset(W)
    W:dir("rom/autorun")
    local osRun = W.osRun
    function W.osRun(self, path, args, env)
        RAN[#RAN + 1] = path .. (#args > 0 and (" " .. table.concat(args, " ")) or "")
        local rel = path:match("^rom/ccnix/(.*)$") or path:match("^ccnix/(.*)$") or path:match("^cc%-turtles/(.*)$")
        if rel and STUB[rel] then return true end
        return osRun(self, path, args, env)
    end
    if withRom then
        local files = {}
        for _, p in ipairs(ROM_FILES) do
            W:file("rom/ccnix/" .. p, repoFile(p))
            files[p] = "blob-" .. p                     -- (a blob sha in the real one)
        end
        W:file("rom/ccnix/.manifest", json.encode({ url = "https://github.com/djt-code/ccnix", branch = "main",
            commit = COMMIT, date = 1793000000, source = "the mod", files = files }))
        W:file("rom/autorun/ccnix.lua", 'shell.run("/rom/ccnix/deploy/boot.lua")   -- ccnix: see that file\n')
    end
    return W
end
-- the updates' .gitlite, as git --lower writes it (lowerCommit: the ROM they were made for)
local function overlay(W, lowerCommit, files)
    W:file("ccnix/.gitlite", json.encode({ url = "https://github.com/djt-code/ccnix", branch = "main",
        commit = "2222222222222222222222222222222222222222", lower = "/rom/ccnix", lowerCommit = lowerCommit, files = files }))
end
-- what the autorun's shell.run ends in
local function boot(W)
    reset(W)
    return W:session({}, function() return W:osRun("rom/autorun/ccnix.lua", {}) end)
end
local function ran() return table.concat(RAN, ", ") end
local function state(W) return W.path .. " | " .. HELP .. " | ls=" .. tostring(W.aliases.ls) end
local function want(root)
    return BASE .. ":" .. root .. "/bin:" .. root .. "/pc | /rom/help:" .. root .. "/help | ls=" .. root .. "/bin/ls.lua"
end

--------------------------------------------------------------------------
-- (a) ROM mode
--------------------------------------------------------------------------
local W = world(true)
local r = boot(W)
check("ROM mode: the ROM's bin/ and pc/ on the path after CraftOS's, help/ on the help path, ls its own",
    state(W) == want("/rom/ccnix"), state(W))
check("_G.ccnix: find gives the ROM's copy (nil for what isn't there), lib the ROM's lib/ and turtle/",
    ccnix ~= nil and ccnix.find("bin/ls.lua") == "/rom/ccnix/bin/ls.lua" and ccnix.find("bin/none.lua") == nil
        and ccnix.lib == "/rom/ccnix/lib/?.lua;/rom/ccnix/turtle/?.lua;", ccnix and ccnix.lib)
check("nothing set for the end of startup: boot returns, CraftOS's startup goes on",
    ran() == "rom/autorun/ccnix.lua, rom/ccnix/deploy/boot.lua" and r.errText == "", ran() .. show(r.errText))
r = W:session({}, function() return W.shell.run("ls", "/rom/ccnix") end)
check("ls at the prompt is ccnix's, its library found through ccnix.lib",
    r.ok and r.out:find("bin") and r.out:find("deploy") and r.errText == "", show(r.out) .. show(r.errText))

-- updates made for this ROM: their copies first, both roots on the path
W = world(true)
W:file("ccnix/bin/ls.lua", repoFile("bin/ls.lua") .. "-- updated\n")
overlay(W, COMMIT, { ["bin/ls.lua"] = "blob-2" })
r = boot(W)
check("updates made for this ROM: /ccnix's copy first, then the ROM's; lib lists /ccnix first, dir by dir",
    ccnix.find("bin/ls.lua") == "/ccnix/bin/ls.lua" and ccnix.find("bin/ip.lua") == "/rom/ccnix/bin/ip.lua"
        and ccnix.lib == "/ccnix/lib/?.lua;/rom/ccnix/lib/?.lua;/ccnix/turtle/?.lua;/rom/ccnix/turtle/?.lua;", ccnix.lib)
check("both on the path and the help path, /ccnix first; ls is the update",
    state(W) == BASE .. ":/ccnix/bin:/rom/ccnix/bin:/ccnix/pc:/rom/ccnix/pc | /rom/help:/ccnix/help:/rom/ccnix/help | ls=/ccnix/bin/ls.lua"
        and r.out == "", state(W) .. show(r.out))
W:file("ccnix/deploy/boot.lua", repoFile("deploy/boot.lua"))
overlay(W, COMMIT, { ["bin/ls.lua"] = "blob-2", ["deploy/boot.lua"] = "blob-3" })
local before = state(W)
r = boot(W)
check("with an updated boot.lua among them, the ROM's hands over to it, to the same end",
    ran() == "rom/autorun/ccnix.lua, rom/ccnix/deploy/boot.lua, ccnix/deploy/boot.lua" and state(W) == before, ran())

-- updates made for another ROM: left out, and said so
W = world(true)
W:file("ccnix/bin/ls.lua", "-- stale\n")
W:file("ccnix/deploy/boot.lua", "error('the stale boot ran')\n")
overlay(W, "0000000000000000000000000000000000000000", { ["bin/ls.lua"] = "blob-2", ["deploy/boot.lua"] = "blob-3" })
r = boot(W)
check("updates made for another ROM: the ROM alone (its boot too), and a line saying `ccnix update` brings them back",
    state(W) == want("/rom/ccnix") and ccnix.lib == "/rom/ccnix/lib/?.lua;/rom/ccnix/turtle/?.lua;"
        and ran() == "rom/autorun/ccnix.lua, rom/ccnix/deploy/boot.lua"
        and r.out:find("made for another ROM; `ccnix update`", 1, true) and r.errText == "", show(r.out) .. show(r.errText))

-- a whole checkout at /ccnix (no ROM under it when it was made): used
W = world(true)
W:file("ccnix/bin/ls.lua", "-- mine\n")
W:file("ccnix/.gitlite", json.encode({ url = "https://github.com/djt-code/ccnix", branch = "main",
    commit = "3333333333333333333333333333333333333333", files = { ["bin/ls.lua"] = "blob-4" } }))
r = boot(W)
check("a whole checkout at /ccnix, made with no ROM under it: used whatever the ROM's commit",
    ccnix.find("bin/ls.lua") == "/ccnix/bin/ls.lua" and W.aliases.ls == "/ccnix/bin/ls.lua" and r.out == "", show(r.out))

--------------------------------------------------------------------------
-- (b) the settings, and the end of startup
--------------------------------------------------------------------------
W = world(true)
STORE["net.boot"] = true
r = boot(W)
check("net.boot: ip up, the ROM's ip, once the path is set", ran() == "rom/autorun/ccnix.lua, rom/ccnix/deploy/boot.lua, rom/ccnix/bin/ip.lua up", ran())

local END = "rom/autorun/ccnix.lua, rom/ccnix/deploy/boot.lua, "
W = world(true)
W:file("rom/autorun/aa-before.lua", "")                 -- (CraftOS ran this one before ccnix's)
W:file("rom/autorun/zz-after.lua", "")
W:file("startup.lua", "")
STORE["ccsh.login"], STORE["motd.enable"], STORE["shell.allow_startup"] = true, true, true
r = boot(W)
check("ccsh.login: the autoruns after ccnix's, the motd and startup.lua (the rest of CraftOS's startup), then ccsh, the stock shell, and shutdown",
    ran() == END .. "rom/autorun/zz-after.lua, rom/programs/motd.lua, startup.lua, rom/ccnix/bin/ccsh.lua, rom/programs/shell.lua"
        and r.errText == "os.shutdown called\n", ran() .. " " .. show(r.errText))

W = world(true)
W:dir("startup")
W:file("startup/00-a.lua", "")
W:file("startup/zz-b.lua", "")
STORE["init.boot"], STORE["ccsh.login"], STORE["cc-turtles.autostart"] = true, true, "router"
STORE["shell.allow_startup"] = true
r = boot(W)
check("init.boot (with ccsh.login and an autostart set too): a /startup folder's files in order, then init --boot alone; the autostart and ccsh are its",
    ran() == END .. "startup/00-a.lua, startup/zz-b.lua, rom/ccnix/bin/init.lua --boot" and r.errText == "os.shutdown called\n",
    ran() .. " " .. show(r.errText))

W = world(true)
STORE["ccsh.login"], STORE["cc-turtles.autostart"] = true, "router"
r = boot(W)
check("no init: cc-turtles.autostart router on a computer runs pc/router, then ccsh, then the stock shell",
    ran() == END .. "rom/ccnix/pc/router.lua, rom/ccnix/bin/ccsh.lua, rom/programs/shell.lua", ran())
STORE["cc-turtles.autostart"] = "mine"
r = boot(W)
check("an autostart that isn't router does nothing on a computer (with no ccsh.login, nothing at all)",
    ran() == END .. "rom/ccnix/bin/ccsh.lua, rom/programs/shell.lua", ran())

turtle = {}
W = world(true)
STORE["cc-turtles.autostart"] = "mine"
r = boot(W)
check("a turtle: turtle/ on the path in place of pc/, and turtle/autostart runs what the setting names, then the stock shell",
    W.path == BASE .. ":/rom/ccnix/bin:/rom/ccnix/turtle"
        and ran() == END .. "rom/ccnix/turtle/autostart.lua, rom/programs/shell.lua", W.path .. " " .. ran())
turtle = nil

W = world(true)
STORE["craftix.login"] = true
r = boot(W)
check("craftix.login (ccsh's old name) becomes ccsh.login, and ccsh runs",
    STORE["ccsh.login"] == true and STORE["craftix.login"] == nil and ran() == END .. "rom/ccnix/bin/ccsh.lua, rom/programs/shell.lua",
    ran())

--------------------------------------------------------------------------
-- (c) an install from before ccnix
--------------------------------------------------------------------------
W = world(true)
W:file("cc-turtles/.gitlite", json.encode({ commit = "4444444444444444444444444444444444444444", files = {} }))
STORE["ccsh.login"] = true
r = boot(W)
check("/cc-turtles/.gitlite (an install from before ccnix, its own startup lines): boot steps aside; nothing on the path, no _G.ccnix, nothing run",
    state(W) == BASE .. " | /rom/help | ls=list" and _G.ccnix == nil
        and ran() == "rom/autorun/ccnix.lua, rom/ccnix/deploy/boot.lua" and r.out == "" and r.errText == "", state(W) .. show(r.out))

-- install run in ROM mode: the settings alone, no startup lines
W = world(true)
r = W:session({}, function() return W:osRun("rom/ccnix/deploy/install.lua", { "--ccsh", "--net", "--no-reboot" }) end)
check("install from the ROM: sets ccsh.login and net.boot, writes no startup file, says the settings take effect at the next boot",
    STORE["ccsh.login"] == true and STORE["net.boot"] == true and not W.fs.exists("/startup.lua") and not W.fs.exists("/startup")
        and r.out:find("the settings take effect at the next boot", 1, true), show(r.out) .. show(r.errText))

--------------------------------------------------------------------------
-- (d) no ROM: install's startup lines, run as CraftOS would
--------------------------------------------------------------------------
W = world(false)
W:file("cc-turtles/deploy/install.lua", repoFile("deploy/install.lua"))
for _, p in ipairs({ "ls", "cu", "ip", "ccsh" }) do W:install(p) end
r = W:session({}, function() return W:osRun("cc-turtles/deploy/install.lua", { "--ccsh", "--net", "--no-reboot" }) end)
check("install --ccsh --net --no-reboot on a checkout: the lines in /startup.lua, the settings set, and this shell gets the path (ip up ran)",
    r.ok and STORE["ccsh.login"] == true and STORE["net.boot"] == true and W:read("startup.lua") ~= nil
        and state(W) == want("/cc-turtles") and ran() == "cc-turtles/deploy/install.lua --ccsh --net --no-reboot, cc-turtles/bin/ip.lua up",
    show(r.out) .. show(r.errText) .. " " .. ran())
reset(W)
local failed = {}
r = W:session({}, function()
    local env = W:env("startup.lua", {})
    for line in (W:read("startup.lua") or ""):gmatch("[^\n]+") do
        local fn, e = load(line, "=startup", "t", env)
        local ok, err = false, e
        if fn then ok, err = pcall(fn) end
        if not ok then failed[#failed + 1] = line .. ": " .. tostring(err) end
    end
    return true
end)
check("its lines, run one by one at boot: each runs", #failed == 0, table.concat(failed, "|"))
check("and leave what boot leaves in ROM mode, for the checkout: path, help path, ls, ip up, then ccsh",
    state(W) == want("/cc-turtles") and ran() == "cc-turtles/bin/ip.lua up, cc-turtles/bin/ccsh.lua", state(W) .. " " .. ran())

-- with a /startup folder: install's own file first, the end of startup
-- in files of its own, run in the folder's order
W = world(false)
W:file("cc-turtles/deploy/install.lua", repoFile("deploy/install.lua"))
for _, p in ipairs({ "ls", "cu", "ip", "ccsh", "init", "router" }) do W:install(p) end
W:dir("startup")
r = W:session({}, function()
    return W:osRun("cc-turtles/deploy/install.lua", { "--init", "--autostart", "router", "--ccsh", "--no-reboot" })
end)
local names = W.fs.list("/startup")
check("install with a /startup folder: its path file first, then init, the autostart and ccsh, each a file of its own",
    r.ok and table.concat(names, " ") == "00-cc-turtles.lua zx-init.lua zy-autostart.lua zz-ccsh.lua"
        and STORE["init.boot"] == true and STORE["cc-turtles.autostart"] == "router" and STORE["net.forward"] == true,
    table.concat(names, " ") .. show(r.errText))
reset(W)
r = W:session({}, function()
    for _, name in ipairs(names) do W:osRun("startup/" .. name, {}) end
    return true
end)
check("run in turn: the path and ip up, init --boot (which wouldn't return), the router, ccsh: boot's order",
    state(W) == want("/cc-turtles") and ran() == "startup/00-cc-turtles.lua, cc-turtles/bin/ip.lua up, startup/zx-init.lua, "
        .. "cc-turtles/bin/init.lua --boot, startup/zy-autostart.lua, cc-turtles/pc/router.lua, startup/zz-ccsh.lua, cc-turtles/bin/ccsh.lua",
    state(W) .. " " .. ran())
