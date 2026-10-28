-- touch.lua -- create files, or mark them modified now (POSIX touch)
--
--   touch [-acm] [-r ref_file | -t time | -d date_time] file...
--
-- A missing file is created empty (-c: left missing, quietly); its
-- directory must already exist.  CraftOS cannot set a file's times, so
-- for an existing file touch rewrites it unchanged, which makes its
-- modification time now.  There is no access time: -a alone does
-- nothing to an existing file, and -m is the same as the default.
-- -r, -t and -d are checked but no file can be given that time: missing
-- files are still created (with the time now), existing ones left alone.
-- Directories are left alone.

local cu = require("cu").init("touch", "touch [-acm] [-r ref_file | -t time | -d date_time] file...")
local opts, files = cu.getopt({ ... }, "acmr:t:d:")
if #files == 0 then cu.usageError("missing file operand") end
-- month, day, hour, minute and second (strings) all in POSIX's ranges?
local function inRange(mo, d, h, mi, s)
    mo, d, h, mi, s = tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
    return mo and mo >= 1 and mo <= 12 and d >= 1 and d <= 31 and h <= 23 and mi <= 59 and s <= 60
end
if opts.t then
    -- [[CC]YY]MMDDhhmm[.SS]
    local digits, secs = opts.t:match("^(%d*)(.*)$")
    local md = digits:sub(-8)
    if not (#digits == 8 or #digits == 10 or #digits == 12) or not (secs == "" or secs:match("^%.%d%d$"))
        or not inRange(md:sub(1, 2), md:sub(3, 4), md:sub(5, 6), md:sub(7, 8), secs:sub(2) ~= "" and secs:sub(2) or "0") then
        cu.usageError("invalid date format '" .. opts.t .. "'")
    end
end
if opts.d then
    -- YYYY-MM-DDThh:mm:SS[.frac][Z] (a space can stand for the T)
    local mo, d, h, mi, s, rest = opts.d:match("^%d%d%d%d+%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
    if not (mo and inRange(mo, d, h, mi, s) and (rest:match("^Z?$") or rest:match("^[.,]%d+Z?$"))) then
        cu.usageError("invalid date format '" .. opts.d .. "'")
    end
end
if opts.r and not fs.exists(shell.resolve(opts.r)) then
    cu.fail(opts.r .. ": No such file or directory")
    return cu.exit()
end
-- bump the modification time of existing files?
local bump = not (opts.r or opts.t or opts.d) and (opts.m or not opts.a)

-- an fs error without its "/path: " prefix
local function why(e) return (tostring(e):gsub("^.-: ", "")) end

for _, name in ipairs(files) do
    local path = shell.resolve(name)
    if name == "" then
        cu.fail(": No such file or directory")
    elseif name:find("[/\\]$") and not fs.isDir(path) then
        -- "file/" names a directory, which can't be made here
        if fs.exists(path) then cu.fail(name .. ": Not a directory")
        elseif not opts.c then cu.fail(name .. ": No such file or directory") end
    elseif fs.isDir(path) then
        -- nothing CraftOS can change
    elseif fs.exists(path) then
        if bump then
            local f, e = io.open(path, "rb")
            local text = f and f:read("a") or ""
            if f then f:close(); f, e = io.open(path, "wb") end
            if f then f:write(text); f:close()
            else cu.fail(name .. ": " .. why(e)) end
        end
    elseif not opts.c then
        local dir = fs.getDir(path)
        if dir ~= "" and not fs.isDir(dir) then
            cu.fail(name .. ": " .. (fs.exists(dir) and "Not a directory" or "No such file or directory"))
        else
            local f, e = io.open(path, "wb")
            if f then f:close() else cu.fail(name .. ": " .. why(e)) end
        end
    end
end
return cu.exit()
