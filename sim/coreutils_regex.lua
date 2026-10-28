-- sim/coreutils_regex.lua
--
-- regex.lua, the POSIX regular expressions behind grep (and later sed and
-- expr): BRE and ERE syntax, bracket expressions, anchors, repetition,
-- groups, back-references, case folding, leftmost-longest find and the
-- errors for malformed patterns.
local PROJ = ...
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local check = M.check
local regex = require("regex")

-- does pattern p (BRE, or ERE with "E" in flags; "i" folds case) match s?
local function t(p, s, flags, whole)
    flags = flags or ""
    local re, err = regex.compile(p, { ere = flags:find("E") ~= nil, icase = flags:find("i") ~= nil })
    if not re then return "error: " .. err end
    return re:test(s, whole)
end
-- the leftmost-longest match as "start-stop", or "none"
local function f(p, s, flags, init)
    local re = assert(regex.compile(p, { ere = (flags or ""):find("E") ~= nil }))
    local a, b, caps = re:find(s, init)
    if not a then return "none" end
    local out = a .. "-" .. b
    for _, c in ipairs(caps) do out = out .. "," .. tostring(c) end
    return out
end
-- check that every case gives the expected answer
local function all(name, cases)
    local bad = {}
    for _, c in ipairs(cases) do
        local got = t(c[1], c[2], c[4], c[5])
        if got ~= c[3] then bad[#bad + 1] = c[1] .. " ~ " .. c[2] .. " -> " .. tostring(got) end
    end
    check(name, #bad == 0, table.concat(bad, "; "))
end

all("literals and .", {
    { "abc", "xxabcxx", true }, { "abc", "abx", false }, { "a.c", "a-c", true },
    { "a.c", "ac", false }, { "", "anything", true }, { "", "", true },
    { "a+b", "a+b", true }, { "a?b", "a?b", true }, { "a|b", "a|b", true },
    { "a(b)", "a(b)", true }, { "a{2}", "a{2}", true },
})
all("bracket expressions", {
    { "[abc]", "xbx", true }, { "[abc]", "xyz", false }, { "[^abc]", "abc", false },
    { "[^abc]", "abd", true }, { "[a-c]x", "bx", true }, { "[a-c]x", "dx", false },
    { "[]a]", "]", true }, { "[^]a]", "]", false }, { "[a-]", "-", true },
    { "[[:digit:]][[:alpha:]]", "x9z", true }, { "[[:digit:]]", "abc", false },
    { "[[:space:]]", "a b", true }, { "[[:upper:]]", "abc", false },
    { "[[:upper:][:digit:]]", "ab3", true }, { "[[.-.]]", "-", true }, { "[[=a=]]", "a", true },
    { "[\\]", "\\", true }, { "[.]", "a", false }, { "[*]", "*", true },
})
all("anchors", {
    { "^abc", "abcd", true }, { "^abc", "xabc", false }, { "abc$", "xabc", true },
    { "abc$", "abcx", false }, { "^$", "", true }, { "^$", "x", false },
    { "a^b", "a^b", true }, { "a$b", "a$b", true }, { "^*a", "*a", true },
    { "^a|^b", "b", true, "E" }, { "(^a)", "a", true, "E" }, { "x$|y", "y", true, "E" },
    { "\\(^a\\)", "a", true }, { "\\(a$\\)", "a", true },
})
all("BRE repetition", {
    { "ab*c", "ac", true }, { "ab*c", "abbbc", true }, { "*a", "*a", true },
    { "\\(*a\\)", "*a", true }, { "a\\{2\\}", "aa", true }, { "a\\{2\\}", "a", false },
    { "^a\\{2,\\}$", "aaaa", true }, { "^a\\{2,3\\}$", "aaaa", false }, { "^a\\{,2\\}$", "a", "error: invalid interval" },
    { "^\\(ab\\)*$", "ababab", true }, { "^\\(ab\\)*$", "ababa", false },
    { "^\\(ab\\)\\{2\\}$", "abab", true }, { "a+", "aa", false }, { "a+", "a+", true },
})
all("ERE repetition, groups and alternation", {
    { "^ab+c$", "abbc", true, "E" }, { "^ab+c$", "ac", false, "E" }, { "^ab?c$", "ac", true, "E" },
    { "^ab?c$", "abbc", false, "E" }, { "^a{3}$", "aaa", true, "E" }, { "^a{1,2}$", "aaa", false, "E" },
    { "^(ab|cd)+$", "abcdab", true, "E" }, { "^(ab|cd)+$", "abc", false, "E" },
    { "cat|dog", "hotdog", true, "E" }, { "^(cat|dog)$", "cats", false, "E" },
    { "^(a*)*$", "aaa", true, "E" }, { "^(a*)+b$", "b", true, "E" }, { "^(|a)b$", "ab", true, "E" },
    { "a{", "a{", true, "E" }, { "a\\+", "a+", true, "E" }, { "\\(", "(", true, "E" },
    { "^(a){0}b$", "b", true, "E" }, { "^([0-9]+\\.)+[0-9]+$", "1.21.1", true, "E" },
})
all("back-references", {
    { "\\(a*\\)b\\1", "aabaa", true }, { "^\\(ab*\\)c\\1$", "abbcabb", true },
    { "^\\(ab*\\)c\\1$", "abbcab", false }, { "^(.)(.).?\\2\\1$", "abba", true, "E" },
    { "^(.)(.).?\\2\\1$", "abca", false, "E" },
})
all("case folding and whole lines", {
    { "hello", "Say HELLO", true, "i" }, { "[a-c]", "B", true, "i" }, { "[^a]", "A", false, "i" },
    { "\\(a\\)\\1", "aA", true, "i" }, { "[[:lower:]]", "X", true, "i" }, { "abc", "ABC", false },
    { "ab*", "abb", true, "", true }, { "ab*", "abbc", false, "", true }, { "b", "abc", false, "", true },
    { "a|ab", "ab", true, "E", true },
})

check("find: leftmost, then longest", f("b*c|bbbc*", "abbbcc", "E") == "2-6", f("b*c|bbbc*", "abbbcc", "E"))
check("find: alternatives give the longest", f("a|ab|abc", "xabcd", "E") == "2-4")
check("find: captures", f("\\(a*\\)\\(b*\\)", "aabbbc") == "1-5,aa,bbb")
check("find: a group that took no part is false", f("(a)|b", "b", "E") == "1-1,false")
check("find: empty match at the start", f("x*", "abc") == "1-0")
check("find: from init", f("a", "abca", "", 2) == "4-4")
check("find: ^ only at the start", f("^a", "aa", "", 2) == "none")
check("find: no match", f("z", "abc") == "none")

local function err(p, ere)
    local re, e = regex.compile(p, { ere = ere })
    return re == nil and e or "compiled"
end
check("error: unbalanced [", err("[abc") == "brackets ([ ]) not balanced", err("[abc"))
check("error: unbalanced ( in ERE", err("(ab", true) == "parentheses not balanced")
check("error: unbalanced \\( in BRE", err("\\(ab") == "parentheses not balanced")
check("error: stray \\) in BRE", err("ab\\)") == "unmatched \\)")
check("error: bad class", err("[[:nope:]]") == "invalid character class")
check("error: backwards range", err("[z-a]") == "invalid range end")
check("error: bad interval", err("a\\{3,1\\}") == "invalid interval" and err("a{2", true) == "braces not balanced")
check("error: back-reference to no group", err("\\1") == "invalid back reference")
check("error: trailing backslash", err("ab\\") == "trailing backslash")
check("unmatched ) in ERE is a literal", t(")", "a)", "E") == true)

-- the search skips start positions by the first byte: it must not skip real ones
all("first-byte skipping", {
    { "(ab|cd)e", "xxcde", true, "E" }, { "(ab|c*)e", "xxe", true, "E" }, { "(a|)b", "xb", true, "E" },
    { "\\(x\\)\\{0,1\\}y", "zy", true }, { "[^a]b", "aab", false }, { "[^a]b", "acb", true },
    { "Hello", "say hELLO", true, "i" }, { "a+b", "ccaab", true, "E" }, { "^*x", "y*x", false },
    { "$", "abc", true }, { "a\\{0\\}b", "xb", true }, { ".x", "ax", true },
})
check("find skips ahead to the next possible start", f("(ab|cd)+", "xxabcdx", "E") == "3-6,cd")
check("find with init past every start", f("b", "abc", "", 4) == "none")

-- a long line must not exhaust the stack
local long = string.rep("ab", 3000) .. "c"
check("long line: .* and groups", t("^.*c$", long) == true and t("^(ab)*c$", long, "E") == true)
