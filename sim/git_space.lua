-- sim/git_space.lua
--
-- bin/git.lua against a mock GitHub and a small disk: a clone leaves out
-- sim/ and the other device's folder (and keeps everything with --all);
-- a disk that fills stops the clone with what it got saved, and `git
-- pull` finishes it once there's room; a checkout from before the device
-- rule loses sim/ on its next pull; and files that move between folders
-- need no room for two copies, as deletions go first (the git from before
-- fetched everything first, so moving the whole repo into bin/ and turtle/
-- filled the disk and left both copies).  --only takes just the paths
-- named, and a pull with new options changes what's kept.
local PROJ = ...
package.path = PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local json = M.json
local realPrint = print

local function check(label, cond, got)
    realPrint(string.format("   %s %s%s", cond and "ok   " or "ERROR:", label, got and ("  (" .. tostring(got) .. ")") or ""))
end

-- the remote: commits of { [path] = text }; a blob's sha is its path and text
local COMMITS, HEAD
local function sha(path, text) return (path .. ":" .. #text .. ":" .. text:sub(1, 8)):gsub("[^%w]", "_") end
local API = "https://api.github.com/repos/me/cc-turtles"
local RAW = "https://raw.githubusercontent.com/me/cc-turtles/"
local fetched
http = {
    get = function(req)
        local url = type(req) == "table" and req.url or req
        local body
        if url == API then body = json.encode({ default_branch = "main" })
        elseif url == API .. "/branches/main" then body = json.encode({ commit = { sha = HEAD } })
        elseif url:sub(1, #API + 11) == API .. "/git/trees/" then
            local c = url:sub(#API + 12):match("^[^?]+")
            local tree = {}
            for path, text in pairs(COMMITS[c]) do tree[#tree + 1] = { path = path, type = "blob", sha = sha(path, text) } end
            table.sort(tree, function(a, b) return a.path < b.path end)
            body = json.encode({ tree = tree, truncated = false })
        elseif url:sub(1, #RAW) == RAW then
            local c, path = url:sub(#RAW + 1):match("^([^/]+)/(.+)$")
            body = COMMITS[c][path]
            fetched[#fetched + 1] = path
        end
        if not body then return nil, "404" end
        return { readAll = function() return body end, close = function() end }
    end,
}
textutils = M.textutilsApi()

-- the disk: files under "", a capacity in bytes; as in CC a file takes
-- at least 500
local files, CAP = {}, 0
local function size(t) return math.max(#t, 500) end
local function used() local n = 0; for _, t in pairs(files) do n = n + size(t) end; return n end
local function under(d, p) return d == "" or p:sub(1, #d + 1) == d .. "/" end
fs = {
    combine = function(a, b)
        local p = (a == "" and b) or (b == "" and a) or (a .. "/" .. b)
        return (p:gsub("^/+", ""))
    end,
    getDir = function(p) return p:match("^(.*)/[^/]*$") or "" end,
    exists = function(p)
        p = p:gsub("^/+", "")
        if files[p] then return true end
        for k in pairs(files) do if under(p, k) then return true end end
        return false
    end,
    isDir = function(p) return files[p] == nil and fs.exists(p) end,
    list = function(p)
        local t, seen = {}, {}
        for k in pairs(files) do
            if under(p, k) then
                local n = k:sub(#p + 2):match("^[^/]+")
                if not seen[n] then seen[n] = true; t[#t + 1] = n end
            end
        end
        return t
    end,
    makeDir = function() end,
    getFreeSpace = function() return CAP - used() end,
    getSize = function(p) return #(files[p] or "") end,
    delete = function(p)
        p = p:gsub("^/+", "")
        for k in pairs(files) do if k == p or under(p, k) then files[k] = nil end end
    end,
    open = function(p, mode)
        p = p:gsub("^/+", "")
        if mode == "w" or mode == "wb" then
            local buf = {}
            return { write = function(s) buf[#buf + 1] = s end,
                     close = function()
                         local text = table.concat(buf)
                         if size(text) - (files[p] and size(files[p]) or 0) > CAP - used() then error("Out of space", 0) end
                         files[p] = text
                     end }
        end
        local data = files[p]
        if not data then return nil end
        return { readAll = function() return data end, close = function() end }
    end,
}
shell = { resolve = function(p) return (p:gsub("^/+", "")) end, getRunningProgram = function() return "cc-turtles/bin/git.lua" end }
printError = function(s) realPrint("   ! " .. s) end

local out
local function git(...)
    out, fetched = {}, {}
    print = function(...)
        local t = {}
        for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end
        out[#out + 1] = table.concat(t, " ")
    end
    local ok, err = pcall(assert(loadfile(PROJ .. "/bin/git.lua")), ...)
    print = realPrint
    return ok, err
end
local function said(s)
    for _, l in ipairs(out) do if l:find(s, 1, true) then return true end end
    return false
end
local function state() return json.decode(files["cc-turtles/.gitlite"] or "null") end
local function has(p) return files["cc-turtles/" .. p] ~= nil end

local REPO = {
    ["README.md"] = string.rep("r", 1000),
    ["bin/git.lua"] = string.rep("g", 2000), ["bin/cat.lua"] = string.rep("c", 1000),
    ["lib/cu.lua"] = string.rep("u", 1000),
    ["turtle/mine.lua"] = string.rep("m", 3000), ["pc/diskclone.lua"] = string.rep("d", 1000),
    ["sim/mine_tunnel.lua"] = string.rep("s", 20000), ["sim/lib/mock.lua"] = string.rep("k", 10000),
}

realPrint("== a turtle clones: sim/ and pc/ left out")
COMMITS, HEAD, files, CAP, turtle = { c1 = REPO }, "c1", {}, 50000, {}
local ok, err = git("clone", "https://github.com/me/cc-turtles", "/cc-turtles")
check("the clone finished", ok and said("Done: 5 files."), err)
check("sim/ and pc/ aren't on the disk", not has("sim/mine_tunnel.lua") and not has("pc/diskclone.lua")
    and has("turtle/mine.lua") and has("bin/git.lua"))
check("the rule is kept in .gitlite", state().skip and table.concat(state().skip, ",") == "sim,pc")
check("it says what it left out", said("Leaving out sim/, pc/"))

realPrint("== a computer clones: sim/ and turtle/ left out; --all keeps everything")
files, turtle = {}, nil
git("clone", "https://github.com/me/cc-turtles", "/cc-turtles")
check("a computer gets pc/ and not turtle/", has("pc/diskclone.lua") and not has("turtle/mine.lua") and not has("sim/lib/mock.lua"))
files = {}
git("clone", "https://github.com/me/cc-turtles", "/cc-turtles", "--all")
check("--all gets sim/ too", has("sim/lib/mock.lua") and has("turtle/mine.lua") and #state().skip == 0)
files = {}
git("clone", "https://github.com/me/cc-turtles", "/cc-turtles", "--skip", "lib/")
check("--skip adds to the device's rule", not has("lib/cu.lua") and not has("sim/lib/mock.lua")
    and table.concat(state().skip, ",") == "sim,turtle,lib")

realPrint("== the disk fills during a clone, then there's room")
files, CAP, turtle = { ["junk.txt"] = string.rep("j", 4000) }, 11000, {}
ok, err = git("clone", "https://github.com/me/cc-turtles", "/cc-turtles")
check("it stops with a clear message", not ok, err)
check(".gitlite keeps what it got, with no commit", state() and state().commit == nil and next(state().files) ~= nil)
local before = 0
for _ in pairs(state().files) do before = before + 1 end
files["junk.txt"] = nil
ok = git("pull", "/cc-turtles")
check("git pull finishes it", ok and has("turtle/mine.lua") and has("README.md") and state().commit == "c1",
    #fetched .. " fetched, " .. before .. " kept")
check("fetching only what was missing", #fetched == 5 - before)

realPrint("== a checkout from before the device rule")
local old = {}
for p, t in pairs(REPO) do files["cc-turtles/" .. p] = t end
for p, t in pairs(REPO) do old[p] = sha(p, t) end
files["cc-turtles/.gitlite"] = json.encode({ url = "https://github.com/me/cc-turtles", branch = "main", commit = "c1", files = old })
CAP = 100000
ok = git("pull", "/cc-turtles")
check("its next pull drops sim/ and pc/, even with no new commit", ok and not has("sim/mine_tunnel.lua")
    and not has("pc/diskclone.lua") and has("turtle/mine.lua") and said("from now on"))
check("and fetches nothing it had", #fetched == 0, #fetched)

realPrint("== files move between folders on a nearly full disk")
local moved = {}
for p, t in pairs(REPO) do moved[p] = t end
moved["turtle/mine.lua"], moved["bin/mine.lua"] = nil, REPO["turtle/mine.lua"]
COMMITS.c2, HEAD = moved, "c2"
CAP = used() + 1500
ok = git("pull", "/cc-turtles")
check("the pull fits: the old copy goes before the new one comes", ok and has("bin/mine.lua") and not has("turtle/mine.lua"))

realPrint("== the whole repo moves into a folder, on a disk with room for a few files more")
local OLDL, NEWL = {}, {}
for i = 1, 6 do
    OLDL["p" .. i .. ".lua"] = string.rep("o" .. i, 1000)
    NEWL["bin/p" .. i .. ".lua"] = OLDL["p" .. i .. ".lua"]
end
COMMITS, HEAD, files, CAP = { o1 = OLDL, n1 = NEWL }, "o1", {}, 100000
git("clone", "https://github.com/me/cc-turtles", "/cc-turtles")
HEAD, CAP = "n1", used() + 5000
ok = git("pull", "/cc-turtles")
local top, bin = 0, 0
for k in pairs(files) do
    if k:match("^cc%-turtles/p%d") then top = top + 1 elseif k:match("^cc%-turtles/bin/") then bin = bin + 1 end
end
check("every file is in bin/ and none is left at the top", ok and top == 0 and bin == 6,
    top .. " at the top, " .. bin .. " in bin/")

realPrint("== --only: just the files and folders named; a pull changes the choice")
COMMITS, HEAD, files, CAP, turtle = { c1 = REPO }, "c1", {}, 100000, {}
ok = git("clone", "https://github.com/me/cc-turtles", "/cc-turtles", "--only", "turtle/mine.lua", "--only", "bin/")
check("only turtle/mine.lua and bin/", ok and has("turtle/mine.lua") and has("bin/cat.lua") and has("bin/git.lua")
    and not has("lib/cu.lua") and not has("README.md"))
ok = git("pull", "/cc-turtles", "--only", "lib/", "--only", "bin/git.lua")
check("pull --only swaps the choice: what's no longer wanted goes, the new comes", ok and has("lib/cu.lua")
    and has("bin/git.lua") and not has("bin/cat.lua") and not has("turtle/mine.lua"))
ok = git("pull", "/cc-turtles")
check("a plain pull keeps the choice", ok and has("lib/cu.lua") and not has("bin/cat.lua") and #fetched == 0)
turtle = nil
ok = git("pull", "/cc-turtles", "--only", "sim/", "--only", "turtle/mine.lua")
check("on a computer, --only sim/ and a turtle program: fetched though the device rule leaves them out",
    ok and has("sim/lib/mock.lua") and has("turtle/mine.lua") and not has("lib/cu.lua"))
ok = git("pull", "/cc-turtles", "--only", "sim/", "--skip", "sim/lib")
check("a --skip given as well still leaves its folder out", ok and has("sim/mine_tunnel.lua") and not has("sim/lib/mock.lua"))
turtle = {}
ok = git("pull", "/cc-turtles", "--all")
check("pull --all brings everything back, sim/ too", ok and has("sim/lib/mock.lua") and has("pc/diskclone.lua")
    and has("bin/cat.lua"))
