-- pager.lua -- show text a screenful at a time, like less
--
--   local pager = require("pager")
--   pager.page(text)            -- a string, or a list of lines
--
-- Text that fits on the screen is just printed.  Anything longer or wider
-- opens in a viewer: every line but the bottom one shows text, the bottom
-- one says where you are.  Lines aren't wrapped; scroll sideways instead.
--
--   space, f, PgDn        a page down (the screen less one line)
--   b, PgUp               a page up
--   j, down, Enter        a line down
--   k, up                 a line up
--   d / u                 half a page down / up
--   g, Home / G, End      the top / the bottom
--   l, right / h, left    8 columns right / left
--   0 / $                 the left edge / the end of the widest line
--   q                     back to the shell (what's on screen stays)

local P = {}

local HSTEP = 8            -- columns per sideways step

-- The text as a list of lines: no carriage returns, tabs as 4 spaces.
function P.lines(text)
    local out = {}
    text = text:gsub("\r", ""):gsub("\t", "    ")
    for l in (text .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = l end
    if out[#out] == "" and #out > 1 then out[#out] = nil end    -- a final newline isn't a line
    return out
end

function P.page(src)
    local lines = type(src) == "table" and src or P.lines(src)
    local widest = 0
    for _, l in ipairs(lines) do widest = math.max(widest, #l) end

    local w, h = term.getSize()
    if #lines <= h - 1 and widest <= w then
        for _, l in ipairs(lines) do print(l) end
        return
    end

    local top, left = 1, 1
    while true do
        w, h = term.getSize()
        local view = h - 1
        local step = math.max(1, view - 1)      -- a page keeps one line of the last
        local maxTop = math.max(1, #lines - view + 1)
        local maxLeft = math.max(1, widest - w + 1)
        top = math.max(1, math.min(top, maxTop))
        left = math.max(1, math.min(left, maxLeft))

        term.setBackgroundColour(colours.black)
        term.setTextColour(colours.white)
        for r = 1, view do
            term.setCursorPos(1, r)
            term.clearLine()
            local l = lines[top + r - 1]
            if l then term.write(l:sub(left, left + w - 1)) end
        end
        local status = string.format("%d-%d/%d", top, math.min(top + view - 1, #lines), #lines)
        if maxLeft > 1 then status = status .. " col " .. left end
        if top >= maxTop then status = status .. " END" end
        status = status .. "  q:quit"
        term.setCursorPos(1, h)
        term.setBackgroundColour(colours.white)
        term.setTextColour(colours.black)
        term.clearLine()
        term.write(status:sub(1, w))
        term.setBackgroundColour(colours.black)
        term.setTextColour(colours.white)

        -- letters and space come as char events (taking the key's char
        -- event off the queue, so q doesn't reach the shell's prompt);
        -- keys with no char as key events
        local ev, k = os.pullEvent()
        if ev == "char" then
            if k == "q" or k == "Q" then break
            elseif k == " " or k == "f" then top = top + step
            elseif k == "b" then top = top - step
            elseif k == "j" then top = top + 1
            elseif k == "k" then top = top - 1
            elseif k == "d" then top = top + math.floor(view / 2)
            elseif k == "u" then top = top - math.floor(view / 2)
            elseif k == "g" then top = 1
            elseif k == "G" then top = maxTop
            elseif k == "l" then left = left + HSTEP
            elseif k == "h" then left = left - HSTEP
            elseif k == "0" then left = 1
            elseif k == "$" then left = maxLeft
            end
        elseif ev == "key" then
            if k == keys.pageDown then top = top + step
            elseif k == keys.pageUp then top = top - step
            elseif k == keys.down or k == keys.enter then top = top + 1
            elseif k == keys.up then top = top - 1
            elseif k == keys.home then top = 1
            elseif k == keys["end"] then top = maxTop
            elseif k == keys.right then left = left + HSTEP
            elseif k == keys.left then left = left - HSTEP
            end
        end
    end
    term.setCursorPos(1, h)
    term.clearLine()
end

return P
