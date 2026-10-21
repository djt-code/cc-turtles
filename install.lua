-- install.lua -- fetch the cc-turtles programs onto a turtle
--
-- One-liner on the turtle (requires http enabled on the server):
--   wget run https://raw.githubusercontent.com/mepholic/cc-turtles/main/install.lua
--
-- Re-run it any time to update.  Pass a branch name to install from a
-- branch:  install dev

local branch = ({ ... })[1] or "main"
local BASE = "https://raw.githubusercontent.com/mepholic/cc-turtles/" .. branch .. "/"
local FILES = { "turtlelib.lua", "mow.lua", "farm.lua", "install.lua" }

if not http then
    print("HTTP is disabled on this server; copy the files in manually.")
    return
end

for _, name in ipairs(FILES) do
    local res = http.get(BASE .. name)
    if not res then
        print("Failed to fetch " .. name)
    else
        local f = fs.open(name, "w")
        f.write(res.readAll())
        f.close()
        res.close()
        print("Installed " .. name)
    end
end
