-- boot.lua -- ccnix at boot, on a server whose computers have it in ROM
--
-- The ccnix mod puts this repo's programs in every computer's ROM, at
-- /rom/ccnix, and runs this from /rom/autorun at each boot: no install.
--
-- Two layers.  /rom/ccnix is the server's copy (what the mod shipped, or
-- the server's own git checkout).  /ccnix is this computer's updates over
-- it: `ccnix update` pulls the latest with git and keeps only the files
-- that differ from the ROM's, so it costs a few files of disk, not the
-- whole repo.  Each program, library and help page comes from /ccnix if
-- it's there, else from the ROM.  Updates made against another ROM (the
-- server's copy has changed since) are left out until `ccnix update` does
-- them again, as they could pair a program with another version's
-- library.  The updates' own boot.lua takes over from the ROM's, so a fix
-- to this file arrives the same way.
--
-- It puts bin/ (and turtle/ on a turtle, pc/ on a computer) on the shell's
-- path after CraftOS's own, help/ on the help path, ls on ccnix's ls (an
-- alias, as CraftOS's is: `alias ls list` brings that back), and brings
-- the network up while net.boot is on.  Programs find their libraries
-- through _G.ccnix.
--
-- What doesn't return goes at the end of startup: with init.boot,
-- ccsh.login or cc-turtles.autostart set, this runs the rest of startup
-- itself (the other autoruns, the motd, the computer's startup files),
-- then init (which runs the rest as processes), or else the autostart,
-- then ccsh, then a CraftOS shell; when that shell exits the computer
-- shuts down, as it would have anyway.
--
-- A computer with an install from before ccnix (/cc-turtles, which its
-- own startup lines run) is left to it: deploy/setup moves it over.

local ROM, OVER = "/rom/ccnix", "/ccnix"
local unjson = textutils.unserialiseJSON or textutils.unserializeJSON

if fs.exists("/cc-turtles/.gitlite") then return end

local function readJSON(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r")
    local text = f.readAll()
    f.close()
    local ok, v = pcall(unjson, text or "")
    return ok and type(v) == "table" and v or nil
end

local manifest = readJSON(ROM .. "/.manifest") or {}
local state = readJSON(OVER .. "/.gitlite")
-- the updates are used if they were made against this ROM (or are a whole
-- checkout, made with no ROM under it)
local current = state ~= nil and (state.lower == nil or state.lowerCommit == manifest.commit)

if current and shell.getRunningProgram():sub(1, 4) == "rom/" and fs.exists(OVER .. "/deploy/boot.lua") then
    return shell.run(OVER .. "/deploy/boot.lua")
end

local roots = current and { OVER, ROM } or { ROM }
local function find(path)
    for _, r in ipairs(roots) do
        local p = r .. "/" .. path
        if fs.exists(p) then return p end
    end
end
local lib = {}
for _, d in ipairs({ "lib", "turtle" }) do               -- (turtlelib is in turtle/)
    for _, r in ipairs(roots) do lib[#lib + 1] = r .. "/" .. d .. "/?.lua;" end
end
_G.ccnix = { find = find, lib = table.concat(lib) }
local stale = state ~= nil and not current

if settings.get("craftix.login") ~= nil then            -- (the setting from when ccsh was Craftix)
    if settings.get("ccsh.login") == nil then settings.set("ccsh.login", settings.get("craftix.login")) end
    settings.unset("craftix.login")
    settings.save()
end

local function addTo(path, dir)
    if (":" .. path .. ":"):find(":" .. dir .. ":", 1, true) then return path end
    return path .. ":" .. dir
end
local path, helpPath = shell.path(), help.path()
for _, d in ipairs({ "bin", turtle and "turtle" or "pc" }) do
    for _, r in ipairs(roots) do path = addTo(path, r .. "/" .. d) end
end
for _, r in ipairs(roots) do helpPath = addTo(helpPath, r .. "/help") end
shell.setPath(path)
help.setPath(helpPath)
local ls = find("bin/ls.lua")
if ls then shell.setAlias("ls", ls) end
if stale then
    print("ccnix: this computer's updates were made for another ROM; `ccnix update` brings them back")
end

if settings.get("net.boot") and find("bin/ip.lua") then shell.run(find("bin/ip.lua"), "up") end

-- The end of startup, if anything there doesn't return
local auto = settings.get("cc-turtles.autostart", "")
local autostart = auto ~= "" and (turtle and find("turtle/autostart.lua")
    or (not turtle and auto == "router" and find("pc/router.lua"))) or nil
local init = settings.get("init.boot") and find("bin/init.lua") or nil
local login = settings.get("ccsh.login") and find("bin/ccsh.lua") or nil
if not (init or autostart or login) then return end

-- what /rom/startup.lua does after its autoruns, which it won't get to
for _, name in ipairs(fs.list("/rom/autorun")) do
    local p = "/rom/autorun/" .. name
    if name > "ccnix.lua" and name:sub(1, 1) ~= "." and not fs.isDir(p) then shell.run(p) end
end
if settings.get("motd.enable") then shell.run("/rom/programs/motd") end
local function findStartups(base)
    local found
    local node = "/" .. fs.combine(base, "startup")
    local program = shell.resolveProgram(node)
    if program then found = { program } end
    if fs.isDir(node) then
        found = found or {}
        for _, name in ipairs(fs.list(node)) do
            local p = "/" .. fs.combine(node, name)
            if not fs.isDir(p) then found[#found + 1] = p end
        end
    end
    return found
end
local startups
if settings.get("shell.allow_startup") then startups = findStartups("/") end
if settings.get("shell.allow_disk_startup") then
    for _, side in ipairs(peripheral.getNames()) do
        if disk.isPresent(side) and disk.hasData(side) then
            local found = findStartups(disk.getMountPath(side))
            if found then startups = found; break end
        end
    end
end
for _, p in ipairs(startups or {}) do shell.run(p) end

if init then
    shell.run(init, "--boot")                           -- (the autostart and ccsh are its)
else
    if autostart then shell.run(autostart) end
    if login then shell.run(login) end
    shell.run("/rom/programs/shell.lua")
end
os.shutdown()
