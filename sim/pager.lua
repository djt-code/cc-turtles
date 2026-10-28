-- sim/pager.lua
--
-- pager.lua (and more, which uses it) on the turtle's 39 x 13 screen, with
-- scripted key presses: what each key does to the view, the status line,
-- sideways scrolling without wrapping, and q giving the keyboard back.
local PROJ = ...
package.path = PROJ .. "/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check

local S = M.state()
local T = M.termApi(39, 13)
M.capturePrint(S)
local pager = require("pager")

-- 40 lines, line 5 of them 100 wide
local LONG = ""
for i = 1, 10 do LONG = LONG .. string.rep(tostring(i % 10), 10) end
local text = {}
for i = 1, 40 do text[i] = string.format("line %02d", i) .. (i == 5 and (" " .. LONG) or "") end

-- Page `lines` with these key presses (then q), and return the view after
-- each one: { top = first line shown, row1 = its text, status = ... }.
local function press(lines, ...)
    local seen = {}
    local evs = { ... }
    for _, e in ipairs(evs) do T.events[#T.events + 1] = e end
    T.events[#T.events + 1] = { "char", "q" }
    T.events[#T.events + 1] = { "char", "MARK" }     -- must still be there after q
    local pull = os.pullEvent
    os.pullEvent = function()
        seen[#seen + 1] = { row1 = T.text(1), row5 = T.rows[5], status = T.text(13), inv = T.inverse[13] }
        return pull()
    end
    pager.page(lines)
    os.pullEvent = pull
    local left = T.events[1]
    T.events = {}
    return seen, left
end
local function topOf(v) return tonumber(v.row1:match("^line (%d+)")) end

-- 1. what fits is just printed: no viewer, no keys taken
S.log = {}
T.events = { { "char", "MARK" } }
pager.page("one\r\ntwo\tthree\n")
check("short text printed as it is (CR dropped, tab as spaces)",
    S.log[1] == "one" and S.log[2] == "two    three" and #S.log == 2, table.concat(S.log, "|"))
check("and no key waited for", #T.events == 1)
T.events = {}

-- 2. paging: 12 lines of text, the 13th the status line
local v, left = press(text)
check("shows lines 1-12 and the status line", topOf(v[1]) == 1 and T.text(12):find("^line 12") ~= nil
    and v[1].status:find("1%-12/40") ~= nil and v[1].inv, v[1].status)
check("q quits, and leaves the next key for the shell", left and left[2] == "MARK")
check("status line cleared on the way out", T.text(13) == "")

v = press(text, { "char", " " }, { "key", keys.pageDown }, { "char", "f" }, { "char", "b" }, { "key", keys.pageUp })
check("space, PgDn and f go 11 lines down; b and PgUp 11 up",
    topOf(v[2]) == 12 and topOf(v[3]) == 23 and topOf(v[4]) == 29 and topOf(v[5]) == 18 and topOf(v[6]) == 7,
    topOf(v[2]) .. " " .. topOf(v[3]) .. " " .. topOf(v[4]) .. " " .. topOf(v[5]) .. " " .. topOf(v[6]))
check("can't page past the end (the last screen is lines 29-40) and says END", v[4].status:find("29%-40/40 col 1 END") ~= nil, v[4].status)

v = press(text, { "char", "j" }, { "key", keys.down }, { "key", keys.enter }, { "char", "k" }, { "key", keys.up }, { "key", keys.up })
check("j, down and Enter a line down; k and up a line up, not above the top",
    topOf(v[2]) == 2 and topOf(v[3]) == 3 and topOf(v[4]) == 4 and topOf(v[5]) == 3 and topOf(v[6]) == 2 and topOf(v[7]) == 1)

v = press(text, { "char", "G" }, { "char", "g" }, { "key", keys["end"] }, { "key", keys.home }, { "char", "d" }, { "char", "u" })
check("G/End to the bottom, g/Home to the top, d/u half a page",
    topOf(v[2]) == 29 and topOf(v[3]) == 1 and topOf(v[4]) == 29 and topOf(v[5]) == 1 and topOf(v[6]) == 7 and topOf(v[7]) == 1)

-- 3. sideways: line 5 is 108 wide; nothing wraps
v = press(text, { "char", "l" }, { "key", keys.right }, { "char", "$" }, { "char", "h" }, { "key", keys.left }, { "char", "0" }, { "char", "h" })
local full = text[5]
local function shows(i, from) return v[i].row5 == full:sub(from, from + 38) end
check("not wrapped: line 5 fills its row and line 6 is on the next", T.rows[5] and #v[1].row5 == 39 and shows(1, 1))
check("l and right 8 columns right, $ to the end of the widest line",
    shows(2, 9) and shows(3, 17) and shows(4, #full - 38) and v[2].status:find("col 9") ~= nil)
check("h and left 8 back, 0 to the left edge, not past it",
    shows(5, #full - 46) and shows(6, #full - 54) and shows(7, 1) and shows(8, 1))

-- 4. more: files one after another in the pager (cat just copies them)
local SW = require("shellworld")
local W = SW.new(PROJ)
W:file("a.txt", "first\n")
local b = ""
for i = 1, 30 do b = b .. "b" .. i .. "\n" end
W:file("b.txt", b)
local atQ
local r = W:run("more", "a.txt", "nope", "b.txt", { events = { { "char", "G" }, { "char", "q" } },
    onPull = function(w) if #w.T.events == 1 then atQ = w.T.text(13) end end })
-- 3 header lines + "first" + 3 header lines + 30 lines = 37
check("more pages the files together, each under its name",
    W.T.text(1) == "b19" and W.T.text(12) == "b30" and atQ:find("26%-37/37") ~= nil, atQ)
check("and names a file that isn't there, exit status 1",
    r.err[1] == "more: nope: No such file or directory" and r.status == 1, r.err[1])
r = W:run("more", "a.txt")
check("a short file is just printed", r.out == "first\n" and r.status == 0, (r.out:gsub("\n", "|")))
r = W:run("more", "a.txt", "b.txt", { pipeOut = true })
check("not to the screen: copied like cat", r.out == "first\n" .. b and #r.events == 0)
r = W:run("cat", "a.txt", "nope", "b.txt")
check("cat copies the files with no paging", r.out == "first\n" .. b and r.status == 1
    and r.err[1] == "cat: nope: No such file or directory")
