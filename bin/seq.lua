-- seq.lua -- print a sequence of numbers (as GNU's seq; not in POSIX)
--
--   seq [-w] [-s sep] [-f format] [first [increment]] last
--
-- Prints the numbers from first (1) to last, increment (1) apart, one a
-- line: `seq 3` is 1 2 3, `seq 0 5 20` 0 5 10 15 20, `seq 5 -1 1` counts
-- down.  Decimals and negative numbers work (`seq -1 0.5 1`); the numbers
-- are printed with as many decimal places as first or increment has.
-- Nothing is printed if last comes before first.
--   -s sep     between the numbers instead of a newline (one still ends
--              the line).  \t, \n and \\ in it are a tab, a newline and a
--              backslash (GNU's seq leaves that to the shell).
--   -w         the same width for all: leading zeros (seq -w 8 10: 08 09 10)
--   -f format  each number through a printf floating-point format, such as
--              %.2f, %g or %05.1f (one %e, %f or %g, and %% for a %)
-- Exit status 1 for a bad number, a zero increment or bad options.

package.path = (ccnix and ccnix.lib or "/" .. fs.getDir(fs.getDir(shell.getRunningProgram())) .. "/lib/?.lua;") .. package.path  -- ccnix's lib/, or the one beside bin/
local cu = require("cu").init("seq", "seq [-w] [-s sep] [-f format] [first [increment]] last")

-- Options come first; a negative number ends them (seq -2 2).
local args = { ... }
local opts, ops, i = {}, {}, 1
while args[i] do
    local a = args[i]
    if a == "--" then i = i + 1; break end
    if a:sub(1, 1) ~= "-" or a == "-" or a:match("^%-[%d%.]") then break end
    local c, rest = a:sub(2, 2), a:sub(3)
    if c == "w" and rest == "" then
        opts.w = true
    elseif c == "s" or c == "f" then
        if rest == "" then
            i = i + 1
            rest = args[i]
            if not rest then cu.usageError("option requires an argument -- " .. c, 1) end
        end
        opts[c] = rest
    else
        cu.usageError("invalid option -- " .. c, 1)
    end
    i = i + 1
end
for k = i, #args do ops[#ops + 1] = args[k] end
if #ops == 0 then cu.usageError("missing operand", 1) end
if #ops > 3 then cu.usageError("extra operand '" .. ops[4] .. "'", 1) end
if opts.w and opts.f then cu.usageError("-f and -w can't go together", 1) end

-- a number, and its decimal places
local function number(s)
    local mant, exp = s:match("^([+-]?%d*%.?%d*)[eE]([+-]?%d+)$")
    mant = mant or s
    local v = (mant:match("%d") and mant:match("^[+-]?%d*%.?%d*$")) and tonumber(s)
    if not v or v ~= v or v == math.huge or v == -math.huge then
        cu.fail("invalid floating point argument: '" .. s .. "'")
        cu.exit()
    end
    local places = #(mant:match("%.(%d*)$") or "") - (tonumber(exp) or 0)
    return v, math.max(0, places)
end

local first, step, last = 1, 1, nil
local p1, p2 = 0, 0
if #ops == 1 then last = number(ops[1])
elseif #ops == 2 then first, p1 = number(ops[1]); last = number(ops[2])
else first, p1 = number(ops[1]); step, p2 = number(ops[2]); last = number(ops[3]) end
if step == 0 then cu.fail("invalid Zero increment value: '" .. ops[2] .. "'"); return cu.exit() end

local format = opts.f
if format then
    local probe = format:gsub("%%%%", "")
    local _, convs = probe:gsub("%%[-+ #0]*%d*%.?%d*[eEfgG]", "")
    local _, all = probe:gsub("%%", "")
    if convs ~= 1 or all ~= 1 then
        cu.fail("format '" .. format .. "' needs exactly one %e, %f or %g")
        return cu.exit()
    end
end
local places = math.max(p1, p2)
local function show(v)
    if format then return string.format(format, v) end
    local s = string.format("%." .. places .. "f", v)
    if s:match("^%-0%.?0*$") then s = s:sub(2) end            -- (no "-0")
    return s
end
local width = opts.w and math.max(#show(first), #show(last)) or 0
local function padded(v)
    local s = show(v)
    if #s >= width then return s end
    local sign, digits = s:match("^(%-?)(.*)$")
    return sign .. ("0"):rep(width - #s) .. digits
end

local sep = opts.s and opts.s:gsub("\\(.)", { t = "\t", n = "\n", ["\\"] = "\\" }) or "\n"
-- first + k * step, not a running sum, so no error creeps in
local slack = math.abs(step) * 1e-9
local n = 0
while true do
    local v = first + n * step
    if (step > 0 and v > last + slack) or (step < 0 and v < last - slack) then break end
    if n > 0 then io.write(sep) end
    io.write(padded(v))
    n = n + 1
    if n % 1000 == 0 then os.queueEvent("seq"); os.pullEvent("seq") end
end
if n > 0 then io.write("\n") end
return cu.exit()
