--[[
    Growing a signature until it is unique.

    One instruction is appended per round. Its operand bytes are masked by the
    decoder, and the pattern is then scanned. The signature is done as soon as
    exactly one match remains. The trailing wildcards are trimmed at that
    point. A signature that ends in a wildcard is longer than it needs to be,
    and the bytes behind those wildcards were never what made it unique.

    There are two bounds here that the original tool had no equivalent for. One
    is a maximum number of instructions, the other a maximum length. Without
    them a bad address walks on until the scan range runs out, and every round
    of that walk is a full scan of the module.
]]

local Signature = {}
Signature.__index = Signature

function Signature:New(deps)
    return setmetatable({
        CE = deps.CE,
        Log = deps.Log,
        Settings = deps.Settings,
        Decoder = deps.Decoder
    }, Signature)
end

--
--- ∑ The IDA style pattern of a byte and mask pair, which is also what Cheat
---   Engine's scanner takes. CE accepts both "?" and "??". The wider one is
---   written here because it keeps every token two characters wide.
--- @param entries table # { { Byte, Masked } }
--- @return string
--
function Signature.Pattern(entries)
    local parts = {}
    for index, entry in ipairs(entries) do
        parts[index] = entry.Masked and "??" or string.format("%02X", entry.Byte)
    end
    return table.concat(parts, " ")
end

--- Drops trailing wildcards. They cannot contribute to uniqueness.
function Signature.Trim(entries)
    while #entries > 0 and entries[#entries].Masked do
        table.remove(entries)
    end
    return entries
end

--
--- ∑ Builds a signature for one address.
--- @param address number
--- @return table|nil, string|nil # { Address, Module, Offset, Entries,
---         Pattern, Instructions, Matches } or nil and a reason.
--
function Signature:Make(address)
    local ce, settings = self.CE, self.Settings
    if type(address) ~= "number" or address == 0 then
        return nil, "no address was given"
    end
    if not ce:ProcessOpen() then
        return nil, "no process is attached"
    end

    local module = ce:ModuleAt(address)
    local range = nil
    if settings.Scope == "module" then
        if not module then
            return nil, string.format(
                "%X is not inside a module, so a module-scoped scan has nothing to search. " ..
                "Switch the scope to 'process' for this address.", address)
        end
        range = { Base = module.Base, Size = module.Size }
    end

    local entries, cursor, instructions, notes = {}, address, 0, {}
    local crossed = nil
    while true do
        if instructions >= settings.MaxInstructions then
            return nil, string.format(
                "no unique signature within %d instructions", settings.MaxInstructions)
        end
        if #entries >= settings.MaxBytes then
            return nil, string.format("no unique signature within %d bytes", settings.MaxBytes)
        end

        local size = ce:InstructionSize(cursor)
        if not size or size < 1 then
            return nil, string.format("could not disassemble %X", cursor)
        end
        local bytes, readErr = ce:ReadBytes(cursor, size)
        if not bytes then return nil, readErr end

        local classified, classNote, base = self.Decoder:Classify(cursor, bytes)
        if classNote then
            notes[#notes + 1] = classNote
            self.Log:Debug("Signature: " .. classNote .. ".")
        end
        for _, entry in ipairs(classified) do entries[#entries + 1] = entry end

        local ended = base and self.Decoder.IsTerminator(base.Opcode)
        cursor = cursor + size
        instructions = instructions + 1

        -- A pattern that is nothing but wildcards matches everywhere, and a
        -- very short one matches almost everywhere. Neither is worth a scan.
        local probe = {}
        for index, entry in ipairs(entries) do probe[index] = entry end
        Signature.Trim(probe)
        if #probe >= settings.MinPatternBytes then
            local pattern = Signature.Pattern(probe)
            local matches, scanErr = ce:CountMatches(pattern, range, 2, settings.ScanProtection)
            if not matches then return nil, scanErr end
            if matches == 1 then
                Signature.Trim(entries)
                return {
                    Address = address,
                    Module = module,
                    Offset = module and (address - module.Base) or nil,
                    Entries = entries,
                    Pattern = Signature.Pattern(entries),
                    Instructions = instructions,
                    Matches = matches,
                    Scope = settings.Scope,
                    Notes = notes,
                    CrossedFunctionEnd = crossed
                }
            end
            if matches == 0 then
                -- The address itself must match. Zero means the memory moved
                -- under us or the scan could not reach it.
                return nil, "the pattern matches nothing, not even the address it came from"
            end
        end

        -- The instruction just consumed ended the function. Anything further
        -- belongs to whatever the linker put next.
        if ended and not crossed then
            if settings.StopAtFunctionEnd then
                return nil, string.format(
                    "no unique signature before the function ends at %X. The bytes after it " ..
                    "belong to another function; switch StopAtFunctionEnd off to use them anyway.",
                    cursor - size)
            end
            crossed = cursor
            local note = string.format(
                "the function ends at %X and the signature continues past it, so it also " ..
                "describes the code that happens to follow", cursor - size)
            notes[#notes + 1] = note
            self.Log:Warning("Signature: " .. note .. ".")
        end
    end
end

return Signature
