-- git.lua -- minimal git client for CC:Tweaked
--
-- Clones and pulls a single branch over HTTP using the hosting server's
-- REST API (Forgejo/Gitea or GitHub) instead of the git wire protocol, so
-- there are no packfiles to decode.  Tracks the commit and blob SHAs of
-- what it checked out in .gitlite, and on pull only downloads blobs whose
-- SHA changed, deletes tracked files removed upstream, and never touches
-- untracked files.
--
-- Usage:
--   git clone <url> [dir] [-b <branch>] [--token <token>]
--   git pull   [dir]
--   git status [dir]
--   git log    [dir] [-n <count>]
--
--   <url> is the repo's web URL, with or without .git:
--     https://git.example.com/me/cc-turtles
--     https://github.com/mepholic/cc-turtles.git
--
-- Bootstrap onto a turtle:
--   wget https://git.example.com/me/cc-turtles/raw/branch/main/git.lua git
--   git clone https://git.example.com/me/cc-turtles
--
-- --token is only needed for private repos (Forgejo access token or
-- GitHub PAT); it is saved in .gitlite so pull can reuse it.

local STATE_FILE = ".gitlite"

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------
local function die(msg)
    printError(msg)
    error("", 0)
end

local function encodeSegment(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function encodePath(path)
    local out = {}
    for seg in path:gmatch("[^/]+") do out[#out + 1] = encodeSegment(seg) end
    return table.concat(out, "/")
end

local unjson = textutils.unserialiseJSON or textutils.unserializeJSON
local tojson = textutils.serialiseJSON or textutils.serializeJSON

local function request(url, headers, binary)
    local h, err, failed = http.get({ url = url, headers = headers, binary = binary })
    if not h then
        local code = failed and failed.getResponseCode and failed.getResponseCode()
        if failed and failed.close then failed.close() end
        die(string.format("GET %s failed: %s%s", url, tostring(err),
            code and (" (HTTP " .. code .. ")") or ""))
    end
    local body = h.readAll()
    h.close()
    return body
end

local function requestJSON(url, headers)
    local body = request(url, headers, false)
    local obj, err = unjson(body)
    if obj == nil then die("Bad JSON from " .. url .. ": " .. tostring(err)) end
    return obj
end

local function readState(dir)
    local p = fs.combine(dir, STATE_FILE)
    if not fs.exists(p) then return nil end
    local f = fs.open(p, "r")
    local s = unjson(f.readAll())
    f.close()
    return s
end

local function writeState(dir, state)
    local f = fs.open(fs.combine(dir, STATE_FILE), "w")
    f.write(tojson(state))
    f.close()
end

local function writeFile(path, data)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local f = fs.open(path, "wb")
    f.write(data)
    f.close()
end

-- Remove now-empty directories left behind by deleted files.
local function pruneDirs(dir, path)
    local parent = fs.getDir(path)
    while parent ~= "" and parent ~= dir and fs.isDir(parent)
          and #fs.list(parent) == 0 do
        fs.delete(parent)
        parent = fs.getDir(parent)
    end
end

--------------------------------------------------------------------------
-- Remote adapters: Forgejo/Gitea (default) and GitHub
--------------------------------------------------------------------------
local function makeRemote(url, token)
    local scheme, host, owner, repo = url:match("^(https?)://([^/]+)/([^/]+)/([^/?#]+)")
    if not repo then die("Can't parse repo URL: " .. url) end
    repo = repo:gsub("%.git$", "")
    local R = { url = scheme .. "://" .. host .. "/" .. owner .. "/" .. repo,
                host = host, owner = owner, repo = repo, headers = {} }

    if host == "github.com" or host == "www.github.com" then
        R.kind = "github"
        R.api  = "https://api.github.com/repos/" .. owner .. "/" .. repo
        R.headers["Accept"] = "application/vnd.github+json"
        R.headers["User-Agent"] = "cc-tweaked-git"
        if token then R.headers["Authorization"] = "Bearer " .. token end
        R.branchSha = function(j) return j.commit.sha end
        R.treeUrl = function(sha, page)
            return R.api .. "/git/trees/" .. sha .. "?recursive=1"
        end
        R.rawUrl = function(sha, path)
            return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo
                   .. "/" .. sha .. "/" .. encodePath(path)
        end
        R.logUrl = function(branch, n)
            return R.api .. "/commits?sha=" .. encodeSegment(branch) .. "&per_page=" .. n
        end
    else
        R.kind = "forgejo"
        R.api  = scheme .. "://" .. host .. "/api/v1/repos/" .. owner .. "/" .. repo
        if token then R.headers["Authorization"] = "token " .. token end
        R.branchSha = function(j) return j.commit.id end
        R.treeUrl = function(sha, page)
            return R.api .. "/git/trees/" .. sha .. "?recursive=true&per_page=1000&page=" .. page
        end
        R.rawUrl = function(sha, path)
            return R.api .. "/raw/" .. encodePath(path) .. "?ref=" .. sha
        end
        R.logUrl = function(branch, n)
            return R.api .. "/commits?sha=" .. encodeSegment(branch) .. "&limit=" .. n .. "&stat=false"
        end
    end

    function R.defaultBranch()
        return requestJSON(R.api, R.headers).default_branch
    end

    function R.headCommit(branch)
        local j = requestJSON(R.api .. "/branches/" .. encodeSegment(branch), R.headers)
        return R.branchSha(j)
    end

    -- Returns { [path] = blobSha } for every file in the tree.
    function R.tree(sha)
        local files, count, page = {}, 0, 1
        while true do
            local j = requestJSON(R.treeUrl(sha, page), R.headers)
            local entries = j.tree or {}
            for _, e in ipairs(entries) do
                if e.type == "blob" then files[e.path] = e.sha end
            end
            count = count + #entries
            if j.truncated == true and R.kind == "github" then
                die("Repository tree too large for the GitHub API (truncated).")
            end
            local total = j.total_count
            if not total or count >= total or #entries == 0 then break end
            page = page + 1
        end
        return files
    end

    -- Recent commits on a branch: { {sha, message, author, date}, ... }
    function R.log(branch, n)
        local list = requestJSON(R.logUrl(branch, n), R.headers)
        local out = {}
        for _, c in ipairs(list) do
            local cm = c.commit or {}
            local au = cm.author or {}
            out[#out + 1] = { sha = c.sha, message = cm.message or "",
                              author = au.name or "?", date = au.date or "" }
        end
        return out
    end

    function R.blob(sha, path)
        return request(R.rawUrl(sha, path), R.headers, true)
    end

    return R
end

--------------------------------------------------------------------------
-- Checkout: bring `dir` from state.files to the tree at `commit`
--------------------------------------------------------------------------
local function checkout(R, dir, state, commit)
    local remote = R.tree(commit)
    local have = state.files or {}
    local fetched, deleted = 0, 0

    for path, sha in pairs(remote) do
        if have[path] ~= sha or not fs.exists(fs.combine(dir, path)) then
            print("  " .. path)
            writeFile(fs.combine(dir, path), R.blob(commit, path))
            fetched = fetched + 1
        end
    end
    for path in pairs(have) do
        if not remote[path] then
            local p = fs.combine(dir, path)
            if fs.exists(p) then fs.delete(p); pruneDirs(dir, p) end
            deleted = deleted + 1
        end
    end

    state.files, state.commit = remote, commit
    writeState(dir, state)
    return fetched, deleted
end

--------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------
local function parseArgs(list)
    local pos, opts = {}, {}
    local i = 1
    while i <= #list do
        local a = list[i]
        if a == "-b" or a == "--branch" then opts.branch = list[i + 1]; i = i + 1
        elseif a == "--token" then opts.token = list[i + 1]; i = i + 1
        elseif a == "-n" then opts.count = tonumber(list[i + 1]); i = i + 1
        else pos[#pos + 1] = a end
        i = i + 1
    end
    return pos, opts
end

local function cmdClone(pos, opts)
    local url = pos[1] or die("Usage: git clone <url> [dir] [-b branch] [--token t]")
    local R = makeRemote(url, opts.token)
    local dir = shell.resolve(pos[2] or R.repo)
    if fs.exists(fs.combine(dir, STATE_FILE)) then
        die(dir .. " already contains a checkout; use `git pull`.")
    end
    local branch = opts.branch or R.defaultBranch()
    local commit = R.headCommit(branch)
    print(string.format("Cloning %s (%s @ %s) into %s", R.url, branch, commit:sub(1, 7), dir))
    fs.makeDir(dir)
    local state = { url = R.url, branch = branch, token = opts.token, files = {} }
    local n = checkout(R, dir, state, commit)
    print(string.format("Done: %d files.", n))
end

local function openCheckout(pos)
    local dir = shell.resolve(pos[1] or ".")
    local state = readState(dir)
    if not state then die("No " .. STATE_FILE .. " in " .. dir .. " (not a checkout).") end
    return dir, state, makeRemote(state.url, state.token)
end

local function cmdPull(pos)
    local dir, state, R = openCheckout(pos)
    local commit = R.headCommit(state.branch)
    if commit == state.commit then
        print("Already up to date (" .. commit:sub(1, 7) .. ").")
        return
    end
    print(string.format("Updating %s..%s on %s",
        (state.commit or ""):sub(1, 7), commit:sub(1, 7), state.branch))
    local fetched, deleted = checkout(R, dir, state, commit)
    print(string.format("Done: %d files updated, %d deleted.", fetched, deleted))
end

local function cmdStatus(pos)
    local dir, state, R = openCheckout(pos)
    local n = 0
    for _ in pairs(state.files or {}) do n = n + 1 end
    print("Remote:  " .. state.url)
    print("Branch:  " .. state.branch)
    print("Commit:  " .. (state.commit or "none"))
    print("Files:   " .. n .. " tracked")
    local ok, head = pcall(R.headCommit, state.branch)
    if ok then
        print(head == state.commit and "Up to date with remote."
              or ("Remote is at " .. head:sub(1, 7) .. "; run `git pull`."))
    end
end

local function cmdLog(pos, opts)
    local dir, state, R = openCheckout(pos)
    local n = opts.count or 10
    local commits = R.log(state.branch, n)
    for _, c in ipairs(commits) do
        local marker = (c.sha == state.commit) and "*" or " "
        local subject = c.message:match("^[^\n]*")
        print(string.format("%s%s %s", marker, c.sha:sub(1, 7), subject))
        print(string.format("   %s  %s", c.author, c.date:sub(1, 10)))
    end
    if #commits == 0 then print("No commits.") end
    print("(* = checked out)")
end

--------------------------------------------------------------------------
local pos, opts = parseArgs({ ... })
local cmd = table.remove(pos, 1)

if not http then die("HTTP is disabled on this server.") end

if cmd == "clone" then cmdClone(pos, opts)
elseif cmd == "pull" then cmdPull(pos)
elseif cmd == "status" then cmdStatus(pos)
elseif cmd == "log" then cmdLog(pos, opts)
else
    print("Usage:")
    print("  git clone <url> [dir] [-b branch] [--token t]")
    print("  git pull [dir]")
    print("  git status [dir]")
    print("  git log [dir] [-n count]")
end
