"""Count local variables as CC: Tweaked's Lua (Cobalt) limits them.

Standard Lua allows 200 active locals in each function.  Cobalt counts
the locals still in scope in every enclosing function too, so a function
nested in a chunk with many top-level locals hits "function at line N has
more than 200 local variables" though it has few of its own.  lupa (and
so the simulators) never sees that.  peak(src) walks the source's scopes
and returns the most locals in scope at once and a line: the first where
there were more than 200 (where CC reports it), else where the most were.
Checked against mine.lua at 3e54989..a4f381e: CC failed at line 1859,
and so does this.

A for loop counts 3 hidden control variables plus its own, as Lua 5.1/5.2
(which Cobalt follows) has them.
"""
import re

LIMIT = 200
TOKEN = re.compile(r"""
    (?P<nl>\n)
  | (?P<ws>[ \t\r]+)
  | (?P<comment>--\[(?P<ceq>=*)\[.*?\](?P=ceq)\]|--[^\n]*)
  | (?P<long>\[(?P<leq>=*)\[.*?\](?P=leq)\])
  | (?P<str>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')
  | (?P<name>[A-Za-z_]\w*)
  | (?P<num>0[xX][0-9a-fA-F.]+(?:[pP][+-]?\d+)?|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)
  | (?P<op>\.\.\.|\.\.|==|~=|<=|>=|::|[^\s\w])
""", re.S | re.X)


def tokens(src):
    line, pos = 1, 0
    while pos < len(src):
        m = TOKEN.match(src, pos)
        if not m:
            raise ValueError("can't read line %d" % line)
        kind, text = m.lastgroup, m.group()
        if kind in ("comment", "long", "str", "nl"):
            if kind == "long":
                yield "str", text, line
            elif kind == "str":
                yield kind, text, line
            line += text.count("\n")
        elif kind == "ceq" or kind == "leq":
            pass
        elif kind != "ws":
            yield ("op" if kind == "op" else kind), text, line
        pos = m.end()


def peak(src):
    toks = list(tokens(src))
    stack = [0]            # locals declared in each open block, outermost first
    best, where, over = 0, 0, None
    pending_do = 0         # `do`s that belong to a for/while, not a new block
    i = 0

    def add(n, line):
        nonlocal best, where, over
        stack[-1] += n
        total = sum(stack)
        if total > best:
            best, where = total, line
        if total > LIMIT and over is None:
            over = line

    def params(j):
        # from the "(" at j: the parameter names; returns (count, index after ")")
        n = 0
        while toks[j][1] != ")":
            if toks[j][0] == "name" or toks[j][1] == "...":
                n += toks[j][0] == "name"
            j += 1
        return n, j + 1

    while i < len(toks):
        kind, text, line = toks[i]
        if kind != "name":
            i += 1
            continue
        if text == "local" and toks[i + 1][1] == "function":
            add(1, line)                      # the name, then the function
            i += 1
            continue
        if text == "local":
            j, n = i + 1, 0
            while True:
                if toks[j][0] == "name":
                    n += 1
                    j += 1
                    if j < len(toks) and toks[j][1] == "<":      # <const>/<close>
                        j += 3
                if toks[j][1] == ",":
                    j += 1
                    continue
                break
            add(n, line)
            i = j
        elif text == "function":
            j = i + 1
            selfp = 0
            while toks[j][1] != "(":
                if toks[j][1] == ":":
                    selfp = 1
                j += 1
            n, j = params(j)
            stack.append(0)
            add(n + selfp, line)
            i = j
        elif text == "for":
            j, names = i + 1, 0
            while toks[j][1] not in ("=", "in"):
                names += toks[j][0] == "name"
                j += 1
            stack.append(0)
            add(3 + names, line)
            pending_do += 1
            i = j
        elif text == "while":
            stack.append(0)
            pending_do += 1
            i += 1
        elif text == "do":
            if pending_do:
                pending_do -= 1
            else:
                stack.append(0)
            i += 1
        elif text in ("if", "repeat"):
            stack.append(0)
            i += 1
        elif text in ("elseif", "else"):
            stack[-1] = 0
            i += 1
        elif text in ("end", "until"):
            stack.pop()
            i += 1
        else:
            i += 1
    return best, over or where
