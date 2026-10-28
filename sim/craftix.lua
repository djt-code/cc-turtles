-- sim/craftix.lua
--
-- Craftix, the POSIX-style shell, on a shellworld turtle: quoting and
-- variables, pipes, redirects, && || ! ;, globs, $(...), builtins, how
-- print/term.write/printError output is captured, a command that waits
-- for events (its io swapped in only while it runs), Ctrl+T, the prompt
-- and scripts.
local PROJ = ...
package.path = PROJ .. "/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local SW = require("shellworld")
local check = M.check

local W = SW.new(PROJ)
for _, u in ipairs({ "printf", "sort", "head", "tr", "cat", "wc", "grep", "echo", "more" }) do W:install(u) end

-- small programs to run under the shell
local HELPERS = {
    -- its arguments, each in [ ]
    args = [[local t = {} for i, a in ipairs({ ... }) do t[i] = "[" .. a .. "]" end io.write(table.concat(t), "\n")]],
    -- the ways a stock program writes
    pr = [[print("one") term.write("two") print() io.write("three\n") write("four") print(" five")]],
    perr = [[print("out") printError("bad")]],
    -- textutils.tabulate's way: columns by cursor position
    cols = [[local _, y = term.getCursorPos() term.setCursorPos(1, y) term.write("aa")
             term.setCursorPos(10, y) term.write("bb") print() term.write("cc") print()]],
    -- waits for an event, writing before and after
    yld = [[io.write("a\n") local _, v = os.pullEvent("x") io.write("b " .. tostring(v) .. "\n")]],
    waitT = [[os.pullEvent("never")]],
    ask = [[local l = read() print("got " .. tostring(l))]],
    crash = [[error("boom")]],
}
for name, src in pairs(HELPERS) do W:file("cc-turtles/" .. name .. ".lua", src) end

local function sh(line, opts) return W:run("craftix", "-c", line, opts or {}) end
local function show(s) return (tostring(s):gsub("\n", "|")) end

-- 1. quoting, variables, field splitting
local r = sh([[X=val; args 'a  b' "c $X" d\ e "" '$X' "\$X" "it's"]])
check("quotes: single literal, double expands, \\ escapes, \"\" an empty word",
    r.out == "[a  b][c val][d e][][$X][$X][it's]\n", show(r.out))
r = sh([[X='p  q'; args $X "$X" ${X}; E=; args $E "$E" x; args ${NOPE:-dflt} "${NOPE:-two words}"]])
check("unquoted expansions split, quoted ones don't; empty vanishes unless quoted; ${X:-default}",
    r.out == "[p][q][p  q][p][q]\n[][x]\n[dflt][two words]\n", show(r.out))
r = sh([[a=1 b=2; echo $a$b; export E=5; echo $E; unset E; echo "[$E]"]])
check("assignments, export, unset", r.out == "12\n5\n[]\n", show(r.out))
r = sh([[echo a # not this
echo b |
  tr b c]])
check("# comments; a newline ends a command; a line ending in | goes on", r.out == "a\nc\n", show(r.out))

-- 2. pipes
r = sh([[printf 'b\na\nc\n' | sort | head -n 2]])
check("a three-stage pipe", r.out == "a\nb\n" and r.status == 0, show(r.out))
r = sh([[pr | cat]])
check("print, term.write, io.write and write all go down the pipe, in order",
    r.out == "one\ntwo\nthree\nfour five\n", show(r.out))
r = sh([[cols | cat]])
check("cursor-placed columns come out as text", r.out == "aa       bb\ncc\n", show(r.out))
W:file("m.txt", "hi\n")
r = sh([[more nope m.txt | cat; grep zzz m.txt; echo $?]])
check("more in a pipe copies like cat; a utility's status is $?",
    r.out == "hi\n1\n" and r.err[1] == "more: nope: No such file or directory", show(r.out) .. " " .. show(r.err[1]))

-- 3. redirects
r = sh([[echo hi > f.txt; echo there >> f.txt; cat < f.txt]])
check("> writes, >> appends, < reads", r.out == "hi\nthere\n" and W:read("f.txt") == "hi\nthere\n", show(r.out))
r = sh([[cat nope 2> err.txt; echo $?]])
check("2> takes the error message", r.out == "1\n" and #r.err == 0
    and W:read("err.txt") == "cat: nope: No such file or directory\n", show(W:read("err.txt")))
r = sh([[cat nope 2>&1 | tr a-z A-Z]])
check("2>&1 sends errors down the pipe", r.out == "CAT: NOPE: NO SUCH FILE OR DIRECTORY\n" and #r.err == 0, show(r.out))
r = sh([[cat nope > o1.txt 2>&1; cat nope 2>&1 > o2.txt]])
check(">f 2>&1 puts both in f; 2>&1 >f leaves errors on the screen",
    W:read("o1.txt") == "cat: nope: No such file or directory\n" and W:read("o2.txt") == "" and #r.err == 1,
    show(W:read("o1.txt")) .. " / " .. show(W:read("o2.txt")))
r = sh([[perr | cat]])
check("printError stays on the screen when only stdout is piped", r.out == "out\n" and r.err[1] == "bad", show(r.out))
r = sh([[perr 2>&1 | cat; perr 2> e.txt]])
check("printError follows 2>&1 and 2>", r.out == "out\nbad\nout\n" and W:read("e.txt") == "bad\n" and #r.err == 0,
    show(r.out))
r = sh([[cat nope 2>/dev/null; echo x > /dev/null; cat < /dev/null; echo done]])
check("/dev/null swallows output and reads as empty", r.out == "done\n" and #r.err == 0, show(r.out))
r = sh([[echo x > /rom/x; echo $?; cat < nope; echo $?]])
check("a file that can't be made or read: the shell says so, status 1, command not run",
    r.out == "1\n1\n" and r.err[1] == "craftix: /rom/x: can't create"
    and r.err[2] == "craftix: nope: No such file or directory", show(r.out) .. " " .. table.concat(r.err, "|"))
r = sh([[echo '>' x; echo hi '>' f2.txt]])
check("a quoted > is just text to echo under craftix", r.out == "> x\nhi > f2.txt\n" and W:read("f2.txt") == nil,
    show(r.out))

-- 4. && || ! ; and status
r = sh([[false || echo yes; true && echo ok; false && echo no; false; echo $?; ! false; echo $?; ! true; echo $?;
false && echo a || echo b]])
check("&&, ||, !, $?", r.out == "yes\nok\n1\n0\n1\nb\n", show(r.out))
r = sh([[nosuch; echo $?]])
check("a missing program: not found, 127", r.out == "127\n" and r.err[1] == "craftix: nosuch: not found",
    show(r.out) .. " " .. show(r.err[1]))
r = sh([[crash; echo $?]])
check("a program that errors: its message, status 1", r.out == "1\n" and (r.err[1] or ""):find("boom") ~= nil,
    show(r.err[1]))
r = sh([[echo a; exit 3; echo b]])
check("exit n ends the shell with status n", r.out == "a\n" and r.status == 3, show(r.out) .. " " .. r.status)
r = sh([[false; exit]])
check("exit alone keeps the last status", r.status == 1)

-- 5. globs
W:file("g/a1.txt", "") W:file("g/a2.txt", "") W:file("g/b.txt", "") W:file("g/.hid.txt", "") W:file("g/sub/c.txt", "")
r = sh([[args *.txt; args a?.txt; args [ab]1.txt; args [!a]*; args .*; args z*]], { cwd = "g" })
check("* ? [..] [!..], dot files only by a dot, no match left as is",
    r.out == "[a1.txt][a2.txt][b.txt]\n[a1.txt][a2.txt]\n[a1.txt]\n[b.txt][sub]\n[.hid.txt]\n[z*]\n", show(r.out))
r = sh([[args */*.txt; args /g/a*; args */; args '*.txt' "*.txt" \*.txt; X='a*'; args $X "$X"]], { cwd = "g" })
check("globs across directories, absolute, trailing /; quoted ones literal; unquoted $X globs",
    r.out == "[sub/c.txt]\n[/g/a1.txt][/g/a2.txt]\n[sub/]\n[*.txt][*.txt][*.txt]\n[a1.txt][a2.txt][a*]\n", show(r.out))
W.shell.setDir("")

-- 6. command substitution
r = sh([[echo $(echo hi | tr a-z A-Z); args "$(printf 'a\n\n')" `printf b`; echo $(echo $(echo deep))]])
check("$(...) and `...`, trailing newlines dropped, nested", r.out == "HI\n[a][b]\ndeep\n", show(r.out))
r = sh([[X=$(printf 'x y'); args $X "$X"; X=$(false); echo $?; echo $(exit 3) after; echo still]])
check("substitutions split unless quoted; X=$(false) is status 1; exit inside one ends just it",
    r.out == "[x][y][x y]\n1\nafter\nstill\n", show(r.out))

-- 7. builtins
r = sh([[printf 'a b  c \n' | read x y; echo "$x/$y"; read v < f.txt; echo $v; read q < /dev/null; echo $?]])
check("read splits a line into names, the last gets the rest; 1 at the end",
    r.out == "a/b  c\nhi\n1\n", show(r.out))
r = sh([[echo $PATH; PATH=$PATH:/x; echo $PATH]])
local p0 = ".:/rom/programs:/rom/programs/http:/rom/programs/turtle:/cc-turtles"
check("$PATH is the shell's path, and setting it sets that", r.out == p0 .. "\n" .. p0 .. ":/x\n" and W.path == p0 .. ":/x",
    show(r.out))
W.path = p0
W:file("lib.sh", "LIBV=from-lib\n")
r = sh([[. lib.sh; echo $LIBV]])
check(". runs a file in this shell", r.out == "from-lib\n", show(r.out))

-- 8. syntax errors
local function synErr(line, want)
    local rr = sh(line)
    return rr.status == 2 and rr.err[1] == "craftix: syntax error: " .. want, show(rr.err[1])
end
check("echo | : unexpected end of line, status 2", synErr("echo |", "unexpected end of line"))
check("true && : unexpected end of line", synErr("true &&", "unexpected end of line"))
check("& is refused", synErr("sleep 1 &", "& (background jobs) isn't supported"))
check("( ) is refused", synErr("(echo)", "( ) subshells aren't supported"))
check("an open quote", synErr("echo 'x", "unterminated '"))
check("> with no file", synErr("echo >", "missing file name after >"))
check("$(( )) is refused", synErr("echo $((1+1))", "$(( )) arithmetic isn't supported"))

-- 9. a command that waits for events: its io only while it runs
W.yieldEvents = true
local during = {}
r = sh([[yld | cat]], { events = { { "y" }, { "x", 7 } },
    onPull = function(w)
        during[#during + 1] = w.io.output() == w.io.stdout and _G.write == w.g.write and term.current() == term.native()
            and _G.POSIX_SH == nil
    end })
check("it gets its event (others skipped) and its output stays in order", r.out == "a\nb 7\n", show(r.out))
check("while it waits, the shell's own io, write and terminal are back", #during >= 1 and during[1] == true
    and during[#during] == true)
r = sh([[waitT; echo after]], { events = { { "terminate" } } })
check("Ctrl+T stops the command and the rest of the line, status 130",
    r.out == "" and r.status == 130 and r.err[1] == "Terminated", show(r.out) .. " " .. r.status)
r = W:run("craftix", { stdin = "waitT; echo no\necho $?\n", events = { { "terminate" } } })
check("and the prompt carries on, $? 130", r.out:find("/$ 130\n", 1, true) ~= nil and not r.out:find("no\n", 1, true),
    show(r.out))
W.yieldEvents = false

-- 10. the prompt
r = W:run("craftix", { stdin = "echo one\necho 'two\nthree'\nexit 4\necho never\n" })
check("prompts, a quote carried to a second line, exit n",
    r.out:find("/$ one\n", 1, true) ~= nil and r.out:find("> two\nthree\n", 1, true) ~= nil and r.status == 4
    and not r.out:find("never"), show(r.out))
r = W:run("craftix", { stdin = "echo x\n" })
check("Ctrl+T at the prompt leaves, status 0", r.status == 0 and r.out:find("x\n", 1, true) ~= nil, show(r.out))
r = W:run("craftix", { stdin = "ask | cat\ntyped\n" })
check("a command reading the keyboard while its output is piped", r.out:find("got typed\n", 1, true) ~= nil, show(r.out))

-- 11. scripts
W:file("s.sh", "#!/cc-turtles/craftix\n# a script\necho \"$0 $# $1\"\nargs \"$@\"\nshift\nargs $*\nexit 5\n")
r = W:run("craftix", "s.sh", "a b", "c")
check("a script: $0 $# $1 \"$@\" shift $*, exit", r.out == "s.sh 2 a b\n[a b][c]\n[c]\n" and r.status == 5,
    show(r.out))
r = W:run("craftix", "-c", [[args "$0" "$@"]], "me", "x", "y z")
check("-c with a name and arguments", r.out == "[me][x][y z]\n", show(r.out))
-- what the stock shell passes for: craftix -c 'args $0 $1; exit' nm one
r = W:run("craftix", "-c", "'args", "$0", "$1;", "exit'", "nm", "one")
check("-c from the stock shell: a single-quoted command split at spaces is joined back",
    r.out == "[nm][one]\n" and r.status == 0, show(r.out))

-- 12. nothing left behind
check("after: the screen, io, printing globals and POSIX_SH are as they were",
    term.current() == term.native() and W.io.output() == W.io.stdout and W.io.input() == W.io.stdin
    and rawget(_G, "write") == nil and _G.POSIX_SH == nil)
r = W:run("echo", "a", ">", "z.txt")
check("echo on its own still does > (no shell to)", W:read("z.txt") == "a\n")
