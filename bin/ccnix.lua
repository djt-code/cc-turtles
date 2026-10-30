-- ccnix.lua -- this computer's ccnix: where it comes from, and updates
--
--   ccnix            what the ROM has (its commit), and this computer's
--                    updates over it, if any
--   ccnix update     the latest from the ROM's repo into /ccnix with git,
--                    keeping only the files that differ from the ROM's;
--                    reboot to use them (all of them: until then, programs
--                    already found keep the ROM's)
--   ccnix reset      drop the updates: back to the ROM (files of your own
--                    in /ccnix, a turtle's job files, stay)
--
-- The ccnix mod puts this repo in every computer's ROM, at /rom/ccnix;
-- deploy/boot.lua says how the two layers go together.  When the ROM is
-- newer than the repo's branch, an update keeps nothing: the ROM is it.
-- The server's admin updates the ROM itself (see the mod's README).  On a
-- server without the mod, ccnix is a checkout of its own
-- (deploy/setup clones it into /cc-turtles), and update is a git pull of
-- that.

local ROM, OVER, CHECKOUT = "/rom/ccnix", "/ccnix", "/cc-turtles"
local unjson = textutils.unserialiseJSON or textutils.unserializeJSON
local args = { ... }

local function readJSON(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r")
    local text = f.readAll()
    f.close()
    local ok, v = pcall(unjson, text or "")
    return ok and type(v) == "table" and v or nil
end

local function die(msg)
    printError("ccnix: " .. msg)
    error("", 0)
end

local manifest = readJSON(ROM .. "/.manifest")
local state = readJSON(OVER .. "/.gitlite")
local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end
local function when(t)
    return t and os.date("!%Y-%m-%d %H:%M", t) .. " UTC" or "?"
end

-- The program at a repo path: this computer's updates first, then the
-- ROM's, or (no ccnix in ROM) the one in this program's own checkout
local function find(path)
    if ccnix and ccnix.find then return ccnix.find(path) end
    for _, r in ipairs({ OVER, ROM, "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) }) do
        if fs.exists(r .. "/" .. path) then return r .. "/" .. path end
    end
end

local cmd = args[1]
if cmd == nil or cmd == "status" then
    if manifest then
        print(string.format("ROM: %s %s at %s (%s)", manifest.url or "?", manifest.branch or "?",
            (manifest.commit or "?"):sub(1, 7), when(manifest.date)))
        print("  " .. count(manifest.files) .. " files, from " .. (manifest.source or "the mod"))
    else
        print("No ccnix in ROM here (a server without the mod).")
    end
    if not state then
        print(manifest and "Updates: none (ccnix update fetches any)"
            or (fs.exists(CHECKOUT .. "/.gitlite") and "ccnix is a checkout of its own here: " .. CHECKOUT
                or "No ccnix here: deploy/setup installs it."))
    elseif state.lower == nil then
        print(string.format("%s: a whole checkout at %s, %d files", OVER, (state.commit or "?"):sub(1, 7), count(state.files)))
    else
        local inUse = manifest and state.lowerCommit == manifest.commit
        print(string.format("Updates: %d files at %s, %s", count(state.files), (state.commit or "?"):sub(1, 7),
            inUse and "in use" or "made for another ROM: ccnix update"))
    end
    if fs.exists("/cc-turtles/.gitlite") then
        print("An install from before ccnix runs this computer (/cc-turtles); deploy/setup moves it over.")
    end

elseif cmd == "update" then
    local git = find("bin/git.lua") or die("no git")
    local only = { "bin/", "lib/", "help/", "deploy/", turtle and "turtle/" or "pc/" }
    local opts = {}
    for _, p in ipairs(only) do opts[#opts + 1] = "--only"; opts[#opts + 1] = p end
    local ok
    if not manifest then
        if not fs.exists(CHECKOUT .. "/.gitlite") then die("no ccnix in ROM, and no checkout at " .. CHECKOUT .. ": deploy/setup makes one") end
        ok = shell.run(git, "pull", CHECKOUT)
    elseif state then
        ok = shell.run(git, "pull", OVER, "--lower", ROM, table.unpack(opts))
    else
        ok = shell.run(git, "clone", manifest.url, OVER, "-b", manifest.branch, "--lower", ROM, table.unpack(opts))
    end
    if not ok then die("git stopped; run it again when what it said is fixed") end
    print("Reboot to use the updates.")

elseif cmd == "reset" then
    if not state then print("No updates here."); return end
    if state.lower == nil then die(OVER .. " is a whole checkout, not updates over a ROM: delete it yourself if you mean to") end
    for path in pairs(state.files or {}) do
        local p = OVER .. "/" .. path
        if fs.exists(p) then fs.delete(p) end
        local dir = fs.getDir(p)
        while dir ~= "" and dir ~= fs.combine(OVER, "") and fs.isDir(dir) and #fs.list(dir) == 0 do
            fs.delete(dir)
            dir = fs.getDir(dir)
        end
    end
    fs.delete(OVER .. "/.gitlite")
    print("Back to the ROM's: reboot to use it.")

else
    print("Usage: ccnix [status | update | reset]")
end
