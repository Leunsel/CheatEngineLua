--[[
    The other direction: a signature comes in, an address comes out.

    Manifold-SigMaker-Pattern says what a pasted text means. This module
    decides what to do with it, and that is where the policy lives:

    A PATTERN THAT IS TOO SHORT is refused. Cheat Engine's scanner builds the
    complete result list before a caller can look at any of it, so a scan for
    two fixed bytes allocates millions of entries and takes the interface with
    it for as long as that lasts. The threshold is a setting, and the reason
    says how to lower it, because a deliberate two byte scan of a tiny process
    is a legitimate thing to want.

    THE SEARCH STARTS IN EXECUTABLE MEMORY. That is where code is, a signature
    from this tool describes code, and restricting the scan is what keeps it
    quick in a process with a gigabyte of heap. A signature that describes
    data finds nothing there, so a scan that comes back empty is widened to
    all memory once before it reports failure. Both halves are reported, so
    "not found" never hides which memory was actually searched.

    A HIT COUNT IS NOT A RESULT LIST. The scanner is asked for the addresses
    up to MaxResults, and the total it found regardless. A pattern with 40000
    matches then reports the 40000 rather than pretending there were 100.

    Nothing here opens a window or moves the memory view. Scan answers what is
    there, and Manifold-SigMaker-Host is what does something with it.
]]

local Pattern = require("Manifold-SigMaker-Pattern")

local Find = {}
Find.__index = Find

function Find:New(deps)
    return setmetatable({
        CE = deps.CE,
        Log = deps.Log,
        Settings = deps.Settings
    }, Find)
end

--------------------------------------------------------
--                       Scanning                     --
--------------------------------------------------------

--
--- ∑ Reads a pasted signature and scans the attached process for it.
--- @param text string
--- @return table|nil, string|nil # { Pattern, Addresses, Count, Total,
---         Truncated, Protection, Widened, Elapsed } or nil and a reason.
--
function Find:Scan(text)
    local ce, settings = self.CE, self.Settings
    local parsed, reason = Pattern.Parse(text)
    if not parsed then return nil, reason end

    local minimum = tonumber(settings.Find.MinFixedBytes) or 0
    if parsed.Fixed < minimum then
        -- No full stop at the end. Every caller writes one after the reason.
        return nil, string.format(
            "the pattern has %d fixed byte(s) and %d are needed. A pattern that short matches " ..
            "in thousands of places, and Cheat Engine builds every one of them before the " ..
            "first can be read. ManifoldSigMaker:SetFindMinimum(%d) allows it anyway",
            parsed.Fixed, minimum, math.max(parsed.Fixed, 1))
    end
    if not ce:ProcessOpen() then return nil, "no process is attached" end

    local limit = tonumber(settings.Find.MaxResults)
    if limit and limit < 1 then limit = nil end
    local protection = settings.Find.Protection or ""
    local started = os.clock()

    local result, scanError = ce:ScanMatches(parsed.Pattern,
        { Protection = protection, Limit = limit })
    if not result then return nil, scanError end

    local widened = false
    if result.Count == 0 and settings.Find.Fallback and protection ~= "" then
        widened, protection = true, ""
        local second, secondError = ce:ScanMatches(parsed.Pattern,
            { Protection = protection, Limit = limit })
        if not second then return nil, secondError end
        result = second
    end

    return {
        Pattern = parsed,
        Addresses = result.Addresses,
        Count = result.Count,
        Total = result.Total,
        Truncated = result.Truncated,
        Protection = protection,
        Widened = widened,
        Elapsed = os.clock() - started
    }
end

--------------------------------------------------------
--                      Reporting                     --
--------------------------------------------------------

--- How many hits are listed in a log block before it says "and N more".
Find.ListedInBlock = 25

--- Where memory with these flags was searched, in words.
function Find.Where(protection)
    if protection == nil or protection == "" then return "all memory" end
    if protection == "+X" then return "executable memory" end
    return "memory matching " .. tostring(protection)
end

--
--- ∑ How one hit is written, both in the picker and in the log.
--- @param address number
--- @return string
--
function Find:Name(address)
    local hex = string.format("%X", address)
    local name = self.CE:AddressName(address)
    if name == hex then return hex end
    return string.format("%s  (%s)", name, hex)
end

--- The lines the picker offers, in the order the scanner found them.
function Find:Lines(result)
    local lines = {}
    for index, address in ipairs(result.Addresses) do
        lines[index] = string.format("%d.  %s", index, self:Name(address))
    end
    return lines
end

--
--- ∑ The rows of the log block for a finished scan.
--- @param result table
--- @return table
--
function Find:Rows(result)
    local parsed = result.Pattern
    local composition = string.format("%d, %d wildcarded", parsed.Tokens, parsed.Wildcards)
    if parsed.Partial > 0 then
        composition = composition .. string.format(", %d half wildcarded", parsed.Partial)
    end

    local hits
    if result.Total > result.Count then
        hits = string.format("%d, showing the first %d", result.Total, result.Count)
    else
        hits = tostring(result.Count)
    end

    local rows = {
        { "Pattern", parsed.Pattern },
        { "Bytes", composition },
        { "Searched", Find.Where(result.Protection) },
        result.Widened and { "Widened", "nothing matched in executable memory, so the scan "
            .. "was repeated over all of it" } or false,
        { "Hits", hits },
        { "Time", string.format("%.2f s", result.Elapsed) }
    }
    for _, note in ipairs(parsed.Notes or {}) do
        rows[#rows + 1] = { "Note", note }
    end
    if result.Count > 0 then rows[#rows + 1] = "" end
    for index, address in ipairs(result.Addresses) do
        if index > Find.ListedInBlock then
            rows[#rows + 1] = string.format("... and %d more",
                result.Count - Find.ListedInBlock)
            break
        end
        rows[#rows + 1] = string.format("%d.  %s", index, self:Name(address))
    end
    return rows
end

--
--- ∑ Why a scan that worked found nothing, in one sentence that says where
---   it looked.
--- @param result table
--- @return string
--
function Find:NothingFound(result)
    if result.Widened then
        return "the pattern matches nowhere in this process, in executable memory or outside it"
    end
    return string.format("the pattern matches nowhere in %s", Find.Where(result.Protection))
end

return Find
