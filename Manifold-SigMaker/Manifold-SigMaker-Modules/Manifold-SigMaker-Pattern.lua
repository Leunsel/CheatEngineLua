--[[
    Reading a signature back in.

    The Signature module writes patterns. This one reads them, and it has to
    read every shape this tool and its neighbours hand out, because the text
    that arrives has usually been through a clipboard, a forum post or a
    header file first.

    What it accepts:

        48 8B 4C 24 ? 48 83 EC 28           the bare pattern, aob
        "48 8B 4C 24 ?? 48 83 EC 28"        quoted, aobq
        "\x48\x8B\x4C\x24\x00", "xxxx?"     the C string and its mask, code
        \x48\x8B\x4C\x24\x00                a C string on its own
        { 0x48, 0x8B, 0x4C, 0x24, 0x00 }    a C array
        488B4C2408                          one unbroken run of hex

    A header line above the pattern is dropped, so the whole of what
    "Manifold: Copy Signature" put on the clipboard can be pasted straight
    back in, whichever output parts it was set to, and so can a signature from
    anywhere else.

    Two details decide how a text is read.

    A MASK is only meaningful next to a C string. "\x00" means a wildcard in
    "xxxx?" and a real zero byte without it, and nothing in the string itself
    says which. A C string that arrives without a mask is therefore read
    literally, and the zero bytes in it are reported as a note rather than
    guessed at.

    A NIBBLE WILDCARD, written "4?" or "?8", is passed through untouched.
    Cheat Engine's scanner understands half a byte, so dropping it or widening
    it to a whole byte would both change the search. It counts as a wildcard
    when the fixed length of a pattern is judged, because half a byte of
    certainty is not what that judgement is about.

    Nothing here scans, and nothing here decides whether a pattern is worth
    scanning for. This module answers what the text says. Whether a pattern
    with two fixed bytes in it should be handed to a scanner at all is a
    policy question, and it is answered in Manifold-SigMaker-Find.
]]

local Pattern = {}

Pattern.Wildcard = "??"

--- The lines a pasted signature carries around with it. None of them is part
--- of the pattern, and all of them contain hex that would be read as bytes.
local IGNORED_LINES = {
    "^%s*Address of signature",   -- the header this tool writes
    "^%s*//",
    "^%s*%-%-",
    "^%s*#",
    "^%s*;"
}

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isIgnored(line)
    for _, form in ipairs(IGNORED_LINES) do
        if line:find(form) then return true end
    end
    return false
end

--- Drops the lines that are not part of the pattern.
local function usefulLines(text)
    local kept = {}
    for line in (text .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
        if not isIgnored(line) then kept[#kept + 1] = line end
    end
    return table.concat(kept, "\n")
end

--------------------------------------------------------
--                        Tokens                      --
--------------------------------------------------------

--- A token is one of these three. Fixed carries a byte, Wildcard carries
--- nothing, and Partial carries the two characters as written, because half
--- of it is a real nibble the scanner will match on.
local function fixed(byte) return { Kind = "fixed", Byte = byte } end
local function wildcard() return { Kind = "wildcard" } end
local function partial(text) return { Kind = "partial", Text = text:upper() } end

local function isWildcardChar(character)
    return character == "?" or character == "*" or character == "."
end

--
--- ∑ Reads one whitespace separated token into one or more pattern tokens.
--- @param token string
--- @return table|nil, string|nil # The tokens, or nil and a reason.
--
local function readToken(token)
    -- 0x48 and 48h are the same byte written the way two other tools write it.
    token = token:gsub("^0[xX]", ""):gsub("[hH]$", "")
    if token == "" then return {} end

    local allWild = true
    for index = 1, #token do
        if not isWildcardChar(token:sub(index, index)) then allWild = false break end
    end
    if allWild then
        -- "?" and "??" are both one byte. "? ?" is two, and that is a
        -- different token each time.
        return { wildcard() }
    end

    if #token == 2 then
        local high, low = token:sub(1, 1), token:sub(2, 2)
        local highWild, lowWild = isWildcardChar(high), isWildcardChar(low)
        if highWild or lowWild then
            if not (highWild or high:match("%x")) or not (lowWild or low:match("%x")) then
                return nil, string.format("'%s' is not a byte", token)
            end
            return { partial((highWild and "?" or high) .. (lowWild and "?" or low)) }
        end
    end

    if not token:match("^%x+$") then
        return nil, string.format("'%s' is not a byte", token)
    end
    if #token % 2 ~= 0 then
        return nil, string.format("'%s' has an odd number of hex digits", token)
    end
    -- One unbroken run, "488B4C", is how a hex editor and half the tools out
    -- there write the same thing.
    local out = {}
    for pair in token:gmatch("%x%x") do out[#out + 1] = fixed(tonumber(pair, 16)) end
    return out
end

--------------------------------------------------------
--                     The shapes                     --
--------------------------------------------------------

--
--- ∑ The C string and its mask, which is what the "code" output part writes.
--- @param text string
--- @return table|nil, string|nil # The tokens, nil when the shape is not
---         there at all, or nil and a reason when it is there and broken.
--
local function readCodeAndMask(text)
    local code, mask = text:match('"(\\[xX].-)"%s*,%s*"([^"]*)"')
    if not code then return nil end
    if mask == "" or mask:find("[^xX%?%.%*]") then
        return nil, "the mask may only be made of x and ?"
    end
    local bytes = {}
    for pair in code:gmatch("\\[xX](%x%x)") do bytes[#bytes + 1] = tonumber(pair, 16) end
    if #bytes == 0 then return nil end
    if #bytes ~= #mask then
        return nil, string.format(
            "the byte string is %d byte(s) long and the mask is %d character(s) long",
            #bytes, #mask)
    end
    local tokens = {}
    for index, byte in ipairs(bytes) do
        local character = mask:sub(index, index)
        tokens[index] = isWildcardChar(character) and wildcard() or fixed(byte)
    end
    return tokens
end

--
--- ∑ A C string on its own, with no mask to say what its zero bytes mean.
--- @param text string
--- @return table|nil, table|nil # The tokens, and the notes they earned.
--
local function readCodeOnly(text)
    local bytes = {}
    for pair in text:gmatch("\\[xX](%x%x)") do bytes[#bytes + 1] = tonumber(pair, 16) end
    if #bytes == 0 then return nil end
    local tokens, zeroes = {}, 0
    for index, byte in ipairs(bytes) do
        tokens[index] = fixed(byte)
        if byte == 0 then zeroes = zeroes + 1 end
    end
    local notes = {}
    if zeroes > 0 then
        notes[1] = string.format(
            "the byte string came without a mask, so its %d zero byte(s) were read as real " ..
            "zeroes and not as wildcards", zeroes)
    end
    return tokens, notes
end

--------------------------------------------------------
--                        Parsing                     --
--------------------------------------------------------

--
--- ∑ Reads whatever was pasted and hands back a pattern Cheat Engine's
---   scanner understands.
--- @param text string
--- @return table|nil, string|nil # { Pattern, Tokens, Fixed, Wildcards,
---         Partial, Source, Notes } or nil and a reason.
--
function Pattern.Parse(text)
    text = tostring(text or "")
    if trim(text) == "" then return nil, "nothing was given" end
    local body = usefulLines(text)
    local notes, source = {}, "aob"

    local tokens, reason = readCodeAndMask(body)
    if tokens then
        source = "code"
    else
        if reason then return nil, reason end
        local codeTokens, codeNotes = readCodeOnly(body)
        if codeTokens then
            tokens, source = codeTokens, "code"
            for _, note in ipairs(codeNotes or {}) do notes[#notes + 1] = note end
        end
    end

    if not tokens then
        -- Everything that is punctuation in one of the array forms and has no
        -- meaning in a pattern.
        local plain = body:gsub("[%{%}%[%]%(%),;\"']", " ")
        tokens = {}
        for token in plain:gmatch("%S+") do
            local read, tokenReason = readToken(token)
            if not read then return nil, tokenReason end
            for _, entry in ipairs(read) do tokens[#tokens + 1] = entry end
        end
    end

    if #tokens == 0 then return nil, "nothing in there reads as a signature" end

    local parts, counts = {}, { fixed = 0, wildcard = 0, partial = 0 }
    for index, token in ipairs(tokens) do
        counts[token.Kind] = counts[token.Kind] + 1
        if token.Kind == "fixed" then
            parts[index] = string.format("%02X", token.Byte)
        elseif token.Kind == "partial" then
            parts[index] = token.Text
        else
            parts[index] = Pattern.Wildcard
        end
    end
    if counts.fixed == 0 and counts.partial == 0 then
        return nil, "the pattern is nothing but wildcards"
    end

    -- A leading wildcard is legal and sometimes deliberate, but the address a
    -- scan reports is the start of the pattern, so it is not the address the
    -- signature was made for.
    if tokens[1].Kind ~= "fixed" then
        notes[#notes + 1] = "the pattern starts with a wildcard, so a hit points at the " ..
            "wildcard and not at the first known byte"
    end

    return {
        Pattern = table.concat(parts, " "),
        Tokens = #tokens,
        Fixed = counts.fixed,
        Wildcards = counts.wildcard,
        Partial = counts.partial,
        Source = source,
        Notes = notes
    }
end

--
--- ∑ Whether a text reads as a signature at all. This is what decides if the
---   clipboard is worth offering as the default in the prompt.
--- @param text string
--- @return boolean
--
function Pattern.Looks(text)
    local parsed = Pattern.Parse(text)
    return parsed ~= nil and parsed.Fixed > 0
end

return Pattern
