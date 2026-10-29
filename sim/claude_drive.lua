-- sim/claude_drive.lua
--
-- claude.lua against a scripted API: the "model" is a list of canned
-- replies, so the loop, the tool results it sends back, the Lua sandbox,
-- retries, refusals, the step budget, --confirm and the key check are all
-- checked without a network or a token spent.  The world is the mine's
-- rock.
local PROJ = ...
package.path = PROJ .. "/turtle/?.lua;" .. PROJ .. "/sim/lib/?.lua;" .. package.path
local M = require("mock")
local Mine = require("mineworld")
local P = Mine.P
local check = Mine.check

textutils = M.textutilsApi()
local HTTP = M.httpApi()
http = HTTP.api
local answers = M.consoleApi(Mine, {})
local run = M.runner(Mine, PROJ .. "/turtle/claude.lua", {
    stats = function() return "moves: " .. Mine.moves .. ", turns: " .. Mine.turns .. ", API calls: " .. #HTTP.requests end,
})

-- Canned replies, as the API sends them.
local ids = 0
local function toolUse(name, input)
    ids = ids + 1
    return { type = "tool_use", id = "toolu_" .. ids, name = name, input = input }
end
local function text(s) return { type = "text", text = s } end
local function reply(blocks, stop, extra)
    local r = { id = "msg_1", type = "message", role = "assistant", model = "claude-opus-5-5",
                content = blocks, stop_reason = stop or "end_turn",
                usage = { input_tokens = 100, output_tokens = 20, cache_read_input_tokens = 50 } }
    for k, v in pairs(extra or {}) do r[k] = v end
    return { code = 200, body = r }
end
local function thinking() return { type = "thinking", thinking = "", signature = "sig" } end

-- The tool results in the user turn of request n: { [tool_use_id] = block }.
local function resultsIn(n)
    local req = HTTP.requests[n]
    if not req then return {}, { content = {} } end
    local msgs = req.body.messages
    local last = msgs[#msgs]
    local out = {}
    if type(last.content) == "table" then
        for _, b in ipairs(last.content) do
            if b.type == "tool_result" then out[b.tool_use_id] = b end
        end
    end
    return out, last
end

local function fresh(answersList)
    Mine.setup(Mine.stock(0, 0))
    Mine.startAt()
    Mine.inv, Mine.files = {}, { ["claude.key"] = "sk-test-key\n" }
    HTTP.queue, HTTP.requests, ids = {}, {}, 0
    for i = #answers, 1, -1 do answers[i] = nil end
    for _, a in ipairs(answersList or {}) do answers[#answers + 1] = a end
    EQ = { right = "minecraft:diamond_pickaxe" }
    FUEL, DIGS = 1000, 0
end

-- 1. a goal that takes a status call and one piece of code: the request
--    is well formed, the results go back, the turtle ends where the code
--    put it, and the final note is printed
fresh({ "" })
HTTP.queue = {
    reply({ thinking(), text("Let me look first."), toolUse("status", {}) }, "tool_use"),
    reply({ thinking(), toolUse("lua", { code = [[
for _ = 1, 2 do turtle.dig(); T.forward() end
T.turnRight(); turtle.dig(); T.forward()
print("moved")
return T.posString(), T.dir]] }) }, "tool_use"),
    reply({ text("Done: the turtle is at (1,0,2) facing +x.") }, "end_turn"),
}
run("go", "two", "forward", "and", "one", "right")
local r1 = HTTP.requests[1]
check("posted to the Messages API with the key and version headers",
    r1 and r1.url == "https://api.anthropic.com/v1/messages" and r1.headers["x-api-key"] == "sk-test-key"
        and r1.headers["anthropic-version"] ~= nil, r1 and tostring(r1.url))
check("the request names the model, effort, cached system prompt and the three tools",
    r1 and r1.body.model == "claude-opus-5-5" and r1.body.output_config.effort == "medium"
        and r1.body.system[1].cache_control.type == "ephemeral"
        and #r1.body.tools == 3 and r1.body.tools[1].name == "lua" and r1.body.tools[1].input_schema.required[1] == "code")
check("the goal is the first user message", r1 and r1.body.messages[1].role == "user"
    and r1.body.messages[1].content == "go two forward and one right")
local res2 = resultsIn(2)
check("status went back as a tool result with the turtle's position",
    res2.toolu_1 and tostring(res2.toolu_1.content):find("at %(0,0,0%) facing 0") and res2.toolu_1.is_error == nil,
    res2.toolu_1 and res2.toolu_1.content)
check("the assistant turn went back as it came (thinking block included)",
    HTTP.requests[2].body.messages[2].role == "assistant" and HTTP.requests[2].body.messages[2].content[1].type == "thinking"
        and HTTP.requests[2].body.messages[2].content[1].signature == "sig")
local res3 = resultsIn(3)
check("the code's print and return values came back",
    res3.toolu_2 and res3.toolu_2.content == "moved\n-> (1,0,2)\n-> 1", res3.toolu_2 and res3.toolu_2.content)
check("the turtle moved as the code said", P.x == 1 and P.y == 0 and P.z == 2 and P.d == 1, string.format("(%d,%d,%d) facing %d", P.x, P.y, P.z, P.d))
check("three API calls, then it stopped at end_turn and waited for the next goal", #HTTP.requests == 3)
check("the final note was printed", Mine.logHas("^Done: the turtle is at"))
check("the token totals were printed", Mine.logHas("tokens in"))
check("the code was logged to claude.log", (Mine.files["claude.log"] or ""):find("T.turnRight") ~= nil)

-- 2. the sandbox: fs is out of reach, a syntax error and a runtime error
--    come back as error results, tables are serialised, definitions
--    persist between calls
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "return fs.list('/')" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return (" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "function twice(n) return 2 * n end; return { a = twice(2) }" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "return twice(5), http, shell" }) }, "tool_use"),
    reply({ text("Checked.") }, "end_turn"),
}
run("poke at the sandbox")
local e1 = resultsIn(2).toolu_1
check("fs isn't there: an error result", e1 and e1.is_error == true and tostring(e1.content):find("error:") and tostring(e1.content):find("fs"),
    e1 and e1.content)
local e2 = resultsIn(3).toolu_2
check("a syntax error is an error result", e2 and e2.is_error == true and tostring(e2.content):find("syntax"), e2 and e2.content)
local e3 = resultsIn(4).toolu_3
check("a returned table is serialised", e3 and e3.content == "-> {a=4}" and e3.is_error == nil, e3 and e3.content)
local e4 = resultsIn(5).toolu_4
check("a function defined in one call is there in the next; http and shell aren't",
    e4 and e4.content == "-> 10\n-> nil\n-> nil", e4 and e4.content)

-- 3. an overloaded API is retried; a refusal is reported and stops the goal
fresh({ "" })
HTTP.queue = {
    { code = 529, body = { type = "error", error = { type = "overloaded_error", message = "Overloaded" } } },
    { fail = "Could not connect" },
    reply({}, "refusal", { stop_details = { type = "refusal", category = "cyber", explanation = "Not this." } }),
}
run("something it won't do")
check("retried after the 529 and the failed connection", #HTTP.requests == 3 and Mine.logHas("trying again"))
check("the refusal was reported with its category", Mine.logHas("Claude declined %(cyber%)"))

-- 3b. an error the API won't recover from stops the goal with its message
fresh({ "" })
HTTP.queue = {
    { code = 400, body = { type = "error", error = { type = "invalid_request_error", message = "bad request" } } },
}
run("anything")
check("a 400 isn't retried and its message is shown", #HTTP.requests == 1 and Mine.logHas("HTTP 400.*bad request"))

-- 4. the step budget: with --steps 2 the third tool call isn't run, and
--    the model is told to stop
fresh({ "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "turtle.dig(); T.forward(); return 1" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "turtle.dig(); T.forward(); return 2" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "turtle.dig(); T.forward(); return 3" }) }, "tool_use"),
    reply({ text("Stopping.") }, "end_turn"),
}
run("dig forever", "--steps", "2")
local _, budgetTurn = resultsIn(3)
local told = false
for _, b in ipairs(budgetTurn.content) do if b.type == "text" and b.text:find("tool call 2 of the 2") then told = true end end
check("told to stop after the second call", told)
local over = resultsIn(4).toolu_3
check("the third call wasn't run and came back as an error", over and over.is_error == true and tostring(over.content):find("budget"), over and over.content)
check("only two steps were taken", Mine.moves == 2 and P.z == 2, Mine.moves .. " moves")

-- 5. --confirm: the code is shown and run only on a "y"
fresh({ "n", "y", "" })
HTTP.queue = {
    reply({ toolUse("lua", { code = "turtle.dig(); return 'dug'" }) }, "tool_use"),
    reply({ toolUse("lua", { code = "turtle.dig(); return 'dug'" }) }, "tool_use"),
    reply({ text("Done.") }, "end_turn"),
}
run("dig once", "--confirm")
local c1 = resultsIn(2).toolu_1
local c2 = resultsIn(3).toolu_2
check("declined code isn't run and the model is told", c1 and c1.is_error == true and tostring(c1.content):find("declined") and DIGS == 1, c1 and c1.content)
check("accepted code runs", c2 and c2.content == "-> dug", c2 and c2.content)

-- 6. ask_user hands the question to the keyboard
fresh({ "left", "" })
HTTP.queue = {
    reply({ toolUse("ask_user", { question = "Which way?" }) }, "tool_use"),
    reply({ text("Going left.") }, "end_turn"),
}
run("turn somewhere")
local a1 = resultsIn(2).toolu_1
check("the answer went back", a1 and a1.content == "left", a1 and a1.content)
check("the question was shown", Mine.logHas("Claude asks: Which way%?"))

-- 7. a second goal keeps the conversation
fresh({ "and now back", "" })
HTTP.queue = {
    reply({ text("Ready.") }, "end_turn"),
    reply({ text("Back.") }, "end_turn"),
}
run("say ready")
check("the second goal's request carries the whole conversation",
    #HTTP.requests == 2 and #HTTP.requests[2].body.messages == 3 and HTTP.requests[2].body.messages[3].content == "and now back")

-- 8. no key: says so and does nothing
fresh({})
Mine.files = {}
run("anything")
check("without a key it says where to put one, and calls nothing", Mine.logHas("No API key") and #HTTP.requests == 0)

-- 9. the pager: what's longer than the screen opens in it before the next
--    prompt, at the first line not yet seen; what fits doesn't
package.path = PROJ .. "/lib/?.lua;" .. package.path
local Tm = M.termApi(39, 13)
fresh({ "more please", "" })
local long = {}
for i = 1, 30 do long[i] = "note line " .. i end
HTTP.queue = {
    reply({ text("Ready.") }, "end_turn"),
    reply({ text(table.concat(long, "\n")) }, "end_turn"),
}
local opened = {}
Tm.events = { { "char", "q" }, { "char", "MARK" } }
local pull = os.pullEvent
os.pullEvent = function(...) opened[#opened + 1] = Tm.text(1); return pull(...) end
run("say ready")
os.pullEvent = pull
check("a short reply: no pager at its prompt; a long one opens at its first line",
    #opened == 1 and opened[1] == "note line 1", table.concat(opened, " | "))
check("q gives the prompt back, the next key left for it", Tm.events[1] and Tm.events[1][2] == "MARK")
check("everything still printed as before", Mine.logHas("note line 30") and Mine.logHas("^Ready%.$"))
term, Tm = nil, nil
