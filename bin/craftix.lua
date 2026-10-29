-- craftix.lua -- Craftix, a small POSIX-style shell for CraftOS
--
--   craftix                               an interactive shell
--   craftix -c 'commands' [name [arg...]] run one command line
--   craftix script [arg...]               run a file of commands
--
-- Craftix runs inside the stock CraftOS shell and has it find and run the
-- programs (the same path, aliases and directory; cd, alias and set work
-- as they always do).  What it adds:
--
--   a | b | c             pipes.  Each command runs to its end, then the
--                         next reads what it wrote: nothing streams, so
--                         `a | head` still runs all of a.
--   < f   > f   >> f      redirects; also 2> f, 2>> f, 2>&1, >&2, n>&-.
--                         /dev/null works for reading and writing.
--   a ; b   a && b   a || b   ! a      and a newline is a ;
--   'single' "double" \x  quoting; # starts a comment.  A line ending in
--                         \, |, &&, || or inside quotes goes on to the next.
--   X=value $X ${X} ${X:-default} $? $# $1..$9 $@ "$@" $* $$ $0
--                         variables.  $PATH is the shell's path (setting
--                         it changes the path) and $PWD its directory.
--                         CraftOS has no environment, so programs can't
--                         see variables and X=1 cmd ignores the X=1.
--   *  ?  [abc]  [!a-z]   globs; a name starting with a dot only matches
--                         an explicit dot, and the fileserver's member disks
--                         (/disk, /disk2... with /jbod mounted) only a
--                         pattern that starts with a plain character
--                         (disk*, not *).
--                         No match leaves the word as is.
--   $(cmd)  `cmd`         command substitution.
--   builtins              exit [n], :, true, false, read [-r] name...,
--                         shift [n], unset name..., export name=value...,
--                         . file
--
-- Not yet: if/while/for/case, functions, & (background), ( subshells ),
-- here-documents, $(( arithmetic )), ~.
--
-- Leave with exit, or by holding Ctrl+T at the prompt.  Ctrl+T while a
-- command runs stops it, and the rest of the line, with status 130.
--
-- A script can start with #!/cc-turtles/bin/craftix (the stock shell honours
-- the #! line), or run as `craftix script`.
--
-- Programs see a pipe or a file as io.input() and io.output().  print,
-- write, term.write and printError are redirected too, so stock programs
-- can be piped: `ls | grep lua`.  ls lays its names out in columns as it
-- would on screen, so `ls | wc -l` counts rows, not files.  Full-screen
-- programs (edit, paint) need the screen: don't pipe them.  While a
-- command runs, _G.POSIX_SH is set (echo leaves > to the shell then).

local args = { ... }

-- What a command gets when nothing is redirected: this shell's own.
local real = {
    term = term.current(), input = io.input(), output = io.output(), stderr = io.stderr,
    write = _G.write, printError = _G.printError, read = _G.read,
}
local kb = io.stdin._handle          -- the keyboard: its readLine is read()
real.kb = kb.readLine
local ioMeta = getmetatable(io.stdout)
local function handle(h) return setmetatable({ _handle = h }, ioMeta) end

local TTY = {}                       -- an fd that is left as it is
local vars, pos, arg0 = {}, {}, "craftix"
local status = 0                     -- $?
local subStatus = nil                -- the last $(...)'s status
local exiting = false                -- exit ran
local interrupted = false            -- Ctrl+T stopped a command: skip the rest
local defaultOut = nil               -- where commands write, inside $(...)

local function join(...)
    local t = table.pack(...)
    for i = 1, t.n do t[i] = tostring(t[i]) end
    return table.concat(t, "\t", 1, t.n)
end

-- fn(...) drawing on the real screen, from a command whose output is
-- captured (reading the keyboard, an error message).
local function withReal(fn, ...)
    local t, w = term.redirect(real.term), _G.write
    _G.write = real.write
    local r = table.pack(pcall(fn, ...))
    _G.write = w
    term.redirect(t)
    if not r[1] then error(r[2], 0) end
    return table.unpack(r, 2, r.n)
end

--------------------------------------------------------------------------
-- Streams: where a command's output goes when it isn't the screen
--------------------------------------------------------------------------
-- A stream over out(text): S.raw(s) writes s (write and io.write end up
-- here), S.handle is it as an io handle, S.term a terminal that turns
-- cursor moves into text: what's drawn on a line goes out when the line
-- ends, moving down a row is a newline, and nothing wraps.
local function stream(out, onClose)
    local S = {}
    local cur, base, x, y = "", 0, 1, 1  -- cur: drawn, not yet out, from column base + 1
    local function flush()
        if cur ~= "" then out(cur); base = base + #cur; cur = "" end
    end
    function S.raw(s)
        s = tostring(s)
        flush()
        out(s)
        local _, nl = s:gsub("\n", "")
        if nl > 0 then y = y + nl; base = #s:match("[^\n]*$") else base = base + #s end
        x = base + 1
        return nl
    end
    S.flush = flush
    S.handle = handle({ write = S.raw, flush = flush })
    function S.close() flush(); if onClose then onClose() end end

    local w = real.term.getSize()
    local fg, bg, blink = colours.white, colours.black, false
    local t = {}
    function t.write(s)
        s = tostring(s)
        local at = x - 1 - base
        x = x + #s
        if at < 0 then s, at = s:sub(1 - at), 0 end     -- over what's already out: lost
        if #cur < at then cur = cur .. (" "):rep(at - #cur) end
        cur = cur:sub(1, at) .. s .. cur:sub(at + #s + 1)
    end
    function t.blit(s) t.write(s) end
    function t.setCursorPos(nx, ny)
        nx, ny = math.floor(nx), math.floor(ny)
        if ny > y then flush(); out(("\n"):rep(ny - y)); y, base = ny, 0 end
        x = nx
    end
    function t.getCursorPos() return x, y end
    function t.getSize() return w, 10000 end     -- tall, so paged output never stops to ask
    function t.scroll(n) if n > 0 then flush(); out(("\n"):rep(n)); base = 0 end end
    function t.clear() end
    function t.clearLine() cur = "" end
    function t.setCursorBlink(b) blink = b end
    function t.getCursorBlink() return blink end
    function t.isColour() return real.term.isColour() end
    function t.setTextColour(c) fg = c end
    function t.getTextColour() return fg end
    function t.setBackgroundColour(c) bg = c end
    function t.getBackgroundColour() return bg end
    t.isColor, t.setTextColor, t.getTextColor = t.isColour, t.setTextColour, t.getTextColour
    t.setBackgroundColor, t.getBackgroundColor = t.setBackgroundColour, t.getBackgroundColour
    for k, v in pairs(term.native()) do
        if type(v) == "function" and t[k] == nil then
            t[k] = (k:match("^get") or k:match("^is")) and function(...) return real.term[k](...) end
                or function() end
        end
    end
    S.term = t
    return S
end

-- A stream collected in memory; S.text() is everything written.
local function buffer()
    local parts = {}
    local S = stream(function(s) parts[#parts + 1] = s end)
    function S.text() S.flush(); return table.concat(parts) end
    return S
end

-- An io handle reading the string `data`.
local function reader(data)
    local p = 1
    return handle({
        readLine = function(keep)
            if p > #data then return nil end
            local e = data:find("\n", p, true) or #data
            local l = data:sub(p, (keep or data:sub(e, e) ~= "\n") and e or e - 1)
            p = e + 1
            return l
        end,
        readAll = function() local s = data:sub(p); p = #data + 1; return s end,
        read = function(n)
            if p > #data then return nil end
            local s = data:sub(p, p + (n or 1) - 1)
            p = p + #s
            return s
        end,
        close = function() end,
    })
end

local function readFile(name)
    local path = shell.resolve(name)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "rb")
    if not f then return nil end
    local s = f.readAll() or ""
    f.close()
    return s
end

--------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------
-- A word is a list of parts: { t = "lit", s, q } (q: quoted), { t = "var",
-- name, def, q } or { t = "cmd", src, q }.  A syntax error is raised as
-- { msg, more }; more means the line could still be finished.
local function bad(msg, more) error({ msg = msg, more = more }, 0) end

-- The ")" that closes the "(" just before position i.
local function closer(src, i)
    local depth = 1
    while i <= #src do
        local c = src:sub(i, i)
        if c == "\\" then i = i + 1
        elseif c == "'" then i = src:find("'", i + 1, true) or bad("unterminated '", true)
        elseif c == '"' then
            i = i + 1
            while src:sub(i, i) ~= '"' do
                if i > #src then bad('unterminated "', true) end
                if src:sub(i, i) == "\\" then i = i + 1 end
                i = i + 1
            end
        elseif c == "(" then depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then return i end
        end
        i = i + 1
    end
    bad("unterminated $(", true)
end

local OPS2 = { ["&&"] = true, ["||"] = true, [">>"] = true, [">&"] = true, ["<&"] = true, [">|"] = true }
local OPS1 = { ["|"] = true, [";"] = true, ["&"] = true, ["<"] = true, [">"] = true, ["("] = true, [")"] = true }

-- Tokens: { parts = word } or { op = "|", fd = n (2>), nl = true (a newline) }.
local function lex(src)
    local toks, parts = {}, nil
    local i, n = 1, #src
    local function part(p)
        parts = parts or {}
        local last = parts[#parts]
        if p.t == "lit" and last and last.t == "lit" and last.q == p.q then last.s = last.s .. p.s
        else parts[#parts + 1] = p end
    end
    local function lit(s, q) part({ t = "lit", s = s, q = q }) end
    local function finish()
        if parts then toks[#toks + 1] = { parts = parts }; parts = nil end
    end
    -- the $ at i; returns where it ends
    local function dollar(q)
        local c = src:sub(i + 1, i + 1)
        if c == "(" then
            if src:sub(i + 2, i + 2) == "(" then bad("$(( )) arithmetic isn't supported") end
            local e = closer(src, i + 2)
            part({ t = "cmd", src = src:sub(i + 2, e - 1), q = q })
            return e + 1
        elseif c == "{" then
            local e = src:find("}", i + 2, true) or bad("unterminated ${", true)
            local inner = src:sub(i + 2, e - 1)
            local name, def = inner:match("^([%a_][%w_]*)(.*)$")
            if not name then name, def = inner:match("^([%d%?#@%*%$])(.*)$") end
            if not name or (def ~= "" and def:sub(1, 2) ~= ":-") then bad("bad substitution ${" .. inner .. "}") end
            part({ t = "var", name = name, def = def ~= "" and def:sub(3) or nil, q = q })
            return e + 1
        end
        local name = src:match("^[%a_][%w_]*", i + 1) or src:match("^[%d%?#@%*%$]", i + 1)
        if not name then lit("$", q); return i + 1 end
        part({ t = "var", name = name, q = q })
        return i + 1 + #name
    end
    local function backtick(q)
        local e = i + 1
        while src:sub(e, e) ~= "`" do
            if e > n then bad("unterminated `", true) end
            if src:sub(e, e) == "\\" then e = e + 1 end
            e = e + 1
        end
        part({ t = "cmd", src = (src:sub(i + 1, e - 1):gsub("\\([`\\$])", "%1")), q = q })
        return e + 1
    end

    while i <= n do
        local c = src:sub(i, i)
        if c == " " or c == "\t" then finish(); i = i + 1
        elseif c == "\n" then finish(); toks[#toks + 1] = { op = ";", nl = true }; i = i + 1
        elseif c == "#" and not parts then i = src:find("\n", i, true) or n + 1
        elseif c == "\\" then
            if i == n then bad("", true) end            -- the line goes on
            if src:sub(i + 1, i + 1) ~= "\n" then lit(src:sub(i + 1, i + 1), true) end
            i = i + 2
        elseif c == "'" then
            local e = src:find("'", i + 1, true) or bad("unterminated '", true)
            lit(src:sub(i + 1, e - 1), true)
            i = e + 1
        elseif c == '"' then
            lit("", true)                               -- "" is still a word
            i = i + 1
            while true do
                local d = src:sub(i, i)
                if d == "" then bad('unterminated "', true)
                elseif d == '"' then i = i + 1; break
                elseif d == "\\" and src:sub(i + 1, i + 1):match('[%$`"\\\n]') then
                    if src:sub(i + 1, i + 1) ~= "\n" then lit(src:sub(i + 1, i + 1), true) end
                    i = i + 2
                elseif d == "$" then i = dollar(true)
                elseif d == "`" then i = backtick(true)
                else lit(d, true); i = i + 1 end
            end
        elseif c == "$" then i = dollar(false)
        elseif c == "`" then i = backtick(false)
        else
            local op = OPS2[src:sub(i, i + 1)] and src:sub(i, i + 1) or OPS1[c] and c
            if op then
                local fd
                if op:find("^[<>]") and parts and #parts == 1 and parts[1].t == "lit" and not parts[1].q
                    and parts[1].s:match("^%d$") then
                    fd, parts = tonumber(parts[1].s), nil
                end
                finish()
                toks[#toks + 1] = { op = op, fd = fd }
                i = i + #op
            else
                lit(c, false)
                i = i + 1
            end
        end
    end
    finish()
    return toks
end

local REDIR = { ["<"] = true, [">"] = true, [">>"] = true, [">|"] = true, [">&"] = true, ["<&"] = true }

-- A list of and-or lists: { { pipe = p }, { conn = "&&", pipe = p }, ... },
-- a pipeline { neg, cmds }, a command { words, assigns, redirs }.
local function parse(src)
    local toks = lex(src)
    local i = 1
    local function op(...)
        local t = toks[i]
        if t and t.op then
            for _, o in ipairs({ ... }) do if t.op == o then return o end end
        end
    end
    local function newlines() while toks[i] and toks[i].nl do i = i + 1 end end
    local function unexpected()
        local t = toks[i]
        if not t then bad("unexpected end of line", true) end
        if t.op == "(" or t.op == ")" then bad("( ) subshells aren't supported") end
        if t.op == "&" then bad("& (background jobs) isn't supported") end
        bad("unexpected " .. (t.nl and "newline" or t.op))
    end
    local function command()
        local cmd = { words = {}, assigns = {}, redirs = {} }
        while toks[i] do
            local t = toks[i]
            if t.parts then
                local p1, name, rest = t.parts[1], nil, nil
                if #cmd.words == 0 and p1.t == "lit" and not p1.q then name, rest = p1.s:match("^([%a_][%w_]*)=(.*)$") end
                if name then
                    local value = { { t = "lit", s = rest, q = false } }
                    for k = 2, #t.parts do value[#value + 1] = t.parts[k] end
                    cmd.assigns[#cmd.assigns + 1] = { name = name, value = value }
                else
                    cmd.words[#cmd.words + 1] = t.parts
                end
                i = i + 1
            elseif REDIR[t.op] then
                local target = toks[i + 1]
                if not target then bad("missing file name after " .. t.op) end
                if not target.parts then i = i + 1; unexpected() end
                cmd.redirs[#cmd.redirs + 1] = { fd = t.fd or (t.op:sub(1, 1) == "<" and 0 or 1), op = t.op,
                                                target = target.parts }
                i = i + 2
            else
                break
            end
        end
        if #cmd.words + #cmd.assigns + #cmd.redirs == 0 then unexpected() end
        return cmd
    end
    local function pipeline()
        local p = { cmds = {} }
        local t = toks[i]
        if t and t.parts and #t.parts == 1 and t.parts[1].t == "lit" and not t.parts[1].q and t.parts[1].s == "!" then
            p.neg = true
            i = i + 1
        end
        while true do
            p.cmds[#p.cmds + 1] = command()
            if not op("|") then break end
            i = i + 1
            newlines()
        end
        return p
    end
    local list = {}
    while toks[i] do
        if op(";") then
            i = i + 1
        else
            local ao = { { pipe = pipeline() } }
            while op("&&", "||") do
                local o = op("&&", "||")
                i = i + 1
                newlines()
                ao[#ao + 1] = { conn = o, pipe = pipeline() }
            end
            list[#list + 1] = ao
            if toks[i] then
                if op(";") then i = i + 1 else unexpected() end
            end
        end
    end
    return list
end

--------------------------------------------------------------------------
-- Expansion
--------------------------------------------------------------------------
local runSource

local function getVar(name)
    if name == "?" then return tostring(status)
    elseif name == "#" then return tostring(#pos)
    elseif name == "$" then return tostring(os.getComputerID())
    elseif name == "0" then return arg0
    elseif name:match("^%d$") then return pos[tonumber(name)] or ""
    elseif name == "@" or name == "*" then return pos, true
    elseif name == "PATH" then return shell.path()
    elseif name == "PWD" then return "/" .. shell.dir()
    end
    return vars[name] or ""
end

local function setVar(name, v)
    if name == "PATH" then shell.setPath(v)
    elseif name ~= "PWD" then vars[name] = v end
end

-- What $(src) writes, trailing newlines dropped.
local function substitute(src)
    local buf = buffer()
    local out, ex = defaultOut, exiting
    defaultOut = buf
    runSource(src)
    defaultOut, exiting = out, ex
    subStatus = status
    return (buf.text():gsub("\n+$", ""))
end

-- The fields a word expands to, each { chars, magic }: magic marks the
-- unquoted characters, the ones a glob can use.  Unquoted expansions are
-- split at blanks; "$@" is a field per argument.  whole: one string, no
-- splitting (assignments and redirect targets).
local function fields(parts, whole)
    local out, cur = {}, nil
    local function new() cur = { chars = {}, magic = {}, keep = false } end
    local function add(s, q)
        if q then cur.keep = true end
        for ch in s:gmatch(".") do
            cur.chars[#cur.chars + 1] = ch
            cur.magic[#cur.magic + 1] = not q
            cur.keep = true
        end
    end
    local function cut()
        if cur.keep then out[#out + 1] = cur end
        new()
    end
    new()
    for _, p in ipairs(parts) do
        if p.t == "lit" then
            add(p.s, p.q)
        else
            local v, list
            if p.t == "cmd" then
                v = substitute(p.src)
            else
                v, list = getVar(p.name)
                if p.def and v == "" then v = p.def end
            end
            if list and p.q and p.name == "@" and not whole then
                for k, a in ipairs(v) do
                    add(a, true)
                    if k < #v then cut() end
                end
            else
                if list then v = table.concat(v, " ") end
                if p.q or whole then
                    add(v, true)
                else
                    local k = 1
                    while true do
                        local a, b = v:find("[ \t\n]+", k)
                        add(v:sub(k, (a or 0) - 1), false)
                        if not a then break end
                        cut()
                        k = b + 1
                    end
                end
            end
        end
    end
    cut()
    if whole then return out[1] and table.concat(out[1].chars) or "" end
    return out
end

-- A Lua pattern for one path segment of a glob, or nil if it has no
-- wildcards.
local function globPattern(chars, magic)
    local pat, wild, k = { "^" }, false, 1
    while k <= #chars do
        local c = chars[k]
        if magic[k] and c == "*" then pat[#pat + 1] = ".*"; wild = true
        elseif magic[k] and c == "?" then pat[#pat + 1] = "."; wild = true
        elseif magic[k] and c == "[" then
            local j = k + 1
            local neg = chars[j] == "!" or chars[j] == "^"
            if neg then j = j + 1 end
            local e = chars[j] == "]" and j + 1 or j
            while chars[e] and chars[e] ~= "]" do e = e + 1 end
            if chars[e] then
                local cls = { neg and "[^" or "[" }
                for m = j, e - 1 do
                    local d = chars[m]
                    cls[#cls + 1] = (d == "-" and m > j and m < e - 1) and "-" or d:match("%w") and d or "%" .. d
                end
                pat[#pat + 1] = table.concat(cls) .. "]"
                wild = true
                k = e
            else
                pat[#pat + 1] = "%["
            end
        else
            pat[#pat + 1] = c:match("%w") and c or "%" .. c
        end
        k = k + 1
    end
    if not wild then return nil end
    return table.concat(pat) .. "$"
end

-- The paths a field matches as a glob, sorted; nil if it isn't one or
-- matches nothing.
local function glob(f)
    local segs, cur = {}, { chars = {}, magic = {} }
    for k, c in ipairs(f.chars) do
        if c == "/" then
            segs[#segs + 1] = cur
            cur = { chars = {}, magic = {} }
        else
            cur.chars[#cur.chars + 1] = c
            cur.magic[#cur.magic + 1] = f.magic[k]
        end
    end
    segs[#segs + 1] = cur
    local any = false
    for _, s in ipairs(segs) do
        s.name = table.concat(s.chars)
        s.pat = globPattern(s.chars, s.magic)
        any = any or s.pat ~= nil
    end
    if not any then return nil end

    local abs = f.chars[1] == "/"
    local found = { { shown = abs and "/" or "", path = abs and "" or shell.dir() } }
    for idx, s in ipairs(segs) do
        local nxt = {}
        if s.name == "" then
            if idx == #segs and idx > 1 then        -- a trailing /: directories only
                for _, e in ipairs(found) do
                    if fs.isDir(e.path) then nxt[#nxt + 1] = { shown = e.shown .. "/", path = e.path } end
                end
            else
                nxt = found
            end
        else
            for _, e in ipairs(found) do
                local sep = (e.shown == "" or e.shown:sub(-1) == "/") and "" or "/"
                if s.pat then
                    if fs.isDir(e.path) then
                        -- the fileserver's pool: its disks' mounts are hidden too, unless
                        -- the pattern starts with a plain character
                        local pool = fs.jbodPool
                        local wildFirst = s.magic[1] and (s.chars[1] == "*" or s.chars[1] == "?" or s.chars[1] == "[")
                        for _, n in ipairs(fs.list(e.path)) do
                            if n:match(s.pat) and (n:sub(1, 1) ~= "." or s.name:sub(1, 1) == ".")
                                    and not (pool and wildFirst and pool.isMember(fs.combine(e.path, n))) then
                                nxt[#nxt + 1] = { shown = e.shown .. sep .. n, path = fs.combine(e.path, n) }
                            end
                        end
                    end
                else
                    local p = fs.combine(e.path, s.name)
                    if fs.exists(p) then nxt[#nxt + 1] = { shown = e.shown .. sep .. s.name, path = p } end
                end
            end
        end
        found = nxt
    end
    if #found == 0 then return nil end
    local out = {}
    for k, e in ipairs(found) do out[k] = e.shown end
    table.sort(out)
    return out
end

--------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------
-- Install a command's terminal, io and printing functions; what they
-- were is returned for leave.
local function enter(ctx)
    local o = {
        term = term.redirect(ctx.term), input = io.input(), output = io.output(), stderr = io.stderr,
        write = _G.write, printError = _G.printError, read = _G.read, kb = kb.readLine, sh = _G.POSIX_SH,
    }
    io.input(ctx.input)
    io.output(ctx.output)
    io.stderr = ctx.stderr
    _G.write, _G.printError, _G.read, kb.readLine = ctx.write, ctx.printError, ctx.read, ctx.kb
    _G.POSIX_SH = "craftix"
    return o
end

-- Keep what the command changed for its next turn, put the shell's back.
local function leave(ctx, o)
    ctx.term, ctx.input, ctx.output, ctx.write = term.current(), io.input(), io.output(), _G.write
    term.redirect(o.term)
    io.input(o.input)
    io.output(o.output)
    io.stderr = o.stderr
    _G.write, _G.printError, _G.read, kb.readLine, _G.POSIX_SH = o.write, o.printError, o.read, o.kb, o.sh
end

-- Run fn(...) as a coroutine, its context installed only while it runs
-- (other multishell tabs keep theirs), until it ends.  Returns what it
-- returned and whether Ctrl+T reached it.
local function drive(ctx, fn, ...)
    local co = coroutine.create(fn)
    local ev, terminated = table.pack(...), false
    while true do
        local o = enter(ctx)
        local r = table.pack(coroutine.resume(co, table.unpack(ev, 1, ev.n)))
        leave(ctx, o)
        if coroutine.status(co) == "dead" then
            if not r[1] then printError(tostring(r[2])); return false, terminated end
            return r[2], terminated
        end
        local filter = r[2]
        repeat ev = table.pack(os.pullEventRaw()) until filter == nil or ev[1] == filter or ev[1] == "terminate"
        if ev[1] == "terminate" then terminated = true end
    end
end

-- A message for fd 2 (a stream, or the screen).
local function report(fd2, s)
    if fd2 ~= TTY and fd2.raw then fd2.raw(s .. "\n") else printError(s) end
end

local builtins = {}
builtins[":"] = function() return 0 end
builtins["true"] = builtins[":"]
builtins["false"] = function() return 1 end
function builtins.exit(a, b)
    local n = a[2] and tonumber(a[2])
    if a[2] and not (n and n == math.floor(n)) then b.err("exit: " .. a[2] .. ": numeric argument required"); n = 2 end
    exiting = true
    return n or status
end
function builtins.unset(a)
    for k = 2, #a do vars[a[k]] = nil end
    return 0
end
function builtins.export(a)
    for k = 2, #a do
        local name, v = a[k]:match("^([%a_][%w_]*)=(.*)$")
        if name then setVar(name, v) end
    end
    return 0
end
function builtins.shift(a, b)
    local n = tonumber(a[2] or "1")
    if not n or n < 0 or n > #pos then b.err("shift: can't shift that many"); return 1 end
    for _ = 1, n do table.remove(pos, 1) end
    return 0
end
function builtins.read(a, b)
    local names = {}
    for k = (a[2] == "-r") and 3 or 2, #a do names[#names + 1] = a[k] end
    if #names == 0 then names[1] = "REPLY" end
    local line = b.readLine()
    if not line then
        for _, nm in ipairs(names) do setVar(nm, "") end
        return 1
    end
    local rest = line:match("^[ \t]*(.-)[ \t]*$")
    for k, nm in ipairs(names) do
        if k == #names then
            setVar(nm, rest)
        else
            local w, r = rest:match("^(%S*)[ \t]*(.*)$")
            setVar(nm, w)
            rest = r
        end
    end
    return 0
end
builtins["."] = function(a, b)
    if not a[2] then b.err(".: needs a file name"); return 2 end
    local text = readFile(a[2])
    if not text then b.err(".: " .. a[2] .. ": not found"); return 1 end
    runSource(text)
    return status
end

-- Run one command: inText is what the pipe before it wrote (nil: none),
-- out the pipe after it (nil: the shell's output).  Returns its status.
local function runCommand(cmd, inText, out)
    local fd = { [0] = inText and { data = inText } or TTY, [1] = out or defaultOut or TTY, [2] = TTY }
    local opened = {}
    local function done(st)
        for _, s in ipairs(opened) do s.close() end
        return st
    end

    subStatus = nil
    local argv = {}
    for _, w in ipairs(cmd.words) do
        for _, f in ipairs(fields(w)) do
            local g = glob(f)
            if g then
                for _, s in ipairs(g) do argv[#argv + 1] = s end
            else
                argv[#argv + 1] = table.concat(f.chars)
            end
        end
    end

    for _, r in ipairs(cmd.redirs) do
        local name = fields(r.target, true)
        if r.op == ">&" or r.op == "<&" then
            local n = tonumber(name)
            if name == "-" then fd[r.fd] = r.op == "<&" and { data = "" } or stream(function() end)
            elseif n and fd[n] then fd[r.fd] = fd[n]
            else report(fd[2], "craftix: " .. name .. ": bad file descriptor"); return done(1) end
        elseif r.op == "<" then
            local text = name == "/dev/null" and "" or readFile(name)
            if not text then report(fd[2], "craftix: " .. name .. ": No such file or directory"); return done(1) end
            fd[r.fd] = { data = text }
        elseif name == "/dev/null" then
            fd[r.fd] = stream(function() end)
        else
            local path = shell.resolve(name)
            local f = not fs.isDir(path) and fs.open(path, r.op == ">>" and "ab" or "wb")
            if not f then report(fd[2], "craftix: " .. name .. ": can't create"); return done(1) end
            local s = stream(function(x) f.write(x) end, function() f.close() end)
            opened[#opened + 1] = s
            fd[r.fd] = s
        end
    end

    if #argv == 0 then
        for _, a in ipairs(cmd.assigns) do setVar(a.name, fields(a.value, true)) end
        return done(subStatus or 0)
    end

    local input = fd[0] == TTY and real.input or reader(type(fd[0].data) == "string" and fd[0].data or "")
    local builtin = builtins[argv[1]]
    if builtin then
        return done(builtin(argv, {
            err = function(s) report(fd[2], "craftix: " .. s) end,
            readLine = function()
                if input ~= io.stdin then return input:read("l") end
                local ok, l = pcall(real.read)
                return ok and l or nil
            end,
        }))
    end
    if not shell.resolveProgram(argv[1]) then
        report(fd[2], "craftix: " .. argv[1] .. ": not found")
        return done(127)
    end

    local outS = fd[1] ~= TTY and fd[1].raw and fd[1] or nil
    local errS = fd[2] ~= TTY and fd[2].raw and fd[2] or nil
    local ctx = { input = input, kb = real.kb }
    if outS then
        ctx.term, ctx.output, ctx.write = outS.term, outS.handle, outS.raw
        ctx.kb = function(...) return withReal(real.kb, ...) end
    else
        ctx.term, ctx.output, ctx.write = real.term, real.output, real.write
    end
    if errS then
        ctx.stderr = errS.handle
        ctx.printError = function(...) errS.raw(join(...) .. "\n") end
    elseif outS then
        ctx.stderr = handle({ write = function(s) withReal(function() real.stderr:write(s) end) end })
        ctx.printError = function(...) return withReal(real.printError, ...) end
    else
        ctx.stderr, ctx.printError = real.stderr, real.printError
    end
    if fd[0] ~= TTY then ctx.read = function() return input:read("l") end
    elseif outS then ctx.read = function(...) return withReal(real.read, ...) end
    else ctx.read = real.read end

    _G.POSIX_STATUS = nil
    local ok, terminated = drive(ctx, shell.execute, table.unpack(argv))
    local st = _G.POSIX_STATUS
    if terminated and not ok and (st == nil or st == 0) then
        interrupted = true
        st = 130
    elseif st == nil or (st == 0 and not ok) then
        st = ok and 0 or 1
    end
    return done(st)
end

local function runPipeline(p)
    local data, st = nil, 0
    for k, cmd in ipairs(p.cmds) do
        local out = k < #p.cmds and buffer() or nil
        st = runCommand(cmd, data, out)
        data = out and out.text()
        if interrupted or exiting then break end
    end
    if p.neg then st = st == 0 and 1 or 0 end
    status = st
end

local function runList(list)
    for _, ao in ipairs(list) do
        for k, item in ipairs(ao) do
            if k == 1 or (item.conn == "&&") == (status == 0) then runPipeline(item.pipe) end
            if interrupted or exiting then return end
        end
    end
end

-- Parse and run src; a syntax error is reported, status 2.
function runSource(src)
    local ok, list = pcall(parse, src)
    if not ok then
        if type(list) ~= "table" then error(list, 0) end
        printError("craftix: syntax error: " .. (list.msg ~= "" and list.msg or "unexpected end of line"))
        status = 2
        return
    end
    runList(list)
end

--------------------------------------------------------------------------
-- The prompt
--------------------------------------------------------------------------
-- Tab completion: the stock shell's, for the command after the last |, ;
-- or &.
local function complete(line)
    local start, q = 1, nil
    for k = 1, #line do
        local c = line:sub(k, k)
        if q then
            if c == q then q = nil end
        elseif c == "'" or c == '"' then q = c
        elseif c == "|" or c == ";" or c == "&" then start = k + 1 end
    end
    local tail = line:sub(start):gsub("^%s+", "")
    if tail == "" or not shell.complete then return nil end
    return shell.complete(tail)
end

-- A line typed at the prompt `text`, or nil for Ctrl+T.
local function prompt(text, hist)
    if term.isColour() then term.setTextColour(colours.yellow) end
    write(text)
    term.setTextColour(colours.white)
    local useComplete = not settings or settings.get("shell.autocomplete", true)
    local ok, line = pcall(read, nil, hist, useComplete and complete or nil)
    if ok then return line end
    if line == "Terminated" then return nil end
    error(line, 0)
end

local function interactive()
    local hist = {}
    print("Craftix: exit, or hold Ctrl+T, to leave")
    while not exiting do
        local line = prompt("/" .. shell.dir() .. "$ ", hist)
        if line and line:match("%S") and hist[#hist] ~= line then hist[#hist + 1] = line end
        local list, err
        while line do
            local ok, r = pcall(parse, line)
            if ok then list = r; break end
            if type(r) ~= "table" then error(r, 0) end
            if not r.more then err = r.msg; break end
            local nxt = prompt("> ", {})
            line = nxt and line .. "\n" .. nxt
        end
        if not line then print(); break end
        interrupted = false
        if err then
            printError("craftix: syntax error: " .. err)
            status = 2
        else
            local ok, e = pcall(runList, list)
            if not ok then printError("craftix: " .. tostring(e)); status = 1 end
        end
    end
end

if args[1] == "-c" then
    if not args[2] then
        printError("usage: craftix [-c command [name [arg...]] | script [arg...]]")
        status = 2
    else
        -- The stock shell splits words at spaces and keeps single quotes,
        -- so `craftix -c 'echo a; b'` typed there arrives as "'echo",
        -- "a;", "b'": join the pieces up to the closing quote and drop the
        -- quotes, as a POSIX shell would have.
        local src, k = args[2], 3
        local ok, e = pcall(parse, src)
        if not ok and type(e) == "table" and e.more and src:sub(1, 1) == "'" then
            while not (#src > 1 and src:sub(-1) == "'") and args[k] do
                src, k = src .. " " .. args[k], k + 1
            end
            if #src > 1 and src:sub(-1) == "'" then src = src:sub(2, -2) end
        end
        arg0 = args[k] or "craftix"
        for j = k + 1, #args do pos[#pos + 1] = args[j] end
        runSource(src)
    end
elseif args[1] then
    local text = readFile(args[1])
    if not text then
        printError("craftix: " .. args[1] .. ": can't open")
        status = 127
    else
        arg0 = args[1]
        for k = 2, #args do pos[#pos + 1] = args[k] end
        runSource(text)
    end
else
    interactive()
end

_G.POSIX_STATUS = status
if status ~= 0 then error("", 0) end
