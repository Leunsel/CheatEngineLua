--[[
    The output parts.

    Shape and case follow GH SigMaker v2.0 exactly, so a signature made here
    drops into anything that already consumed that tool's output:

        Address of signature = SouthPark_TFBW.exe + 0x0D762ED9
        "\x48\x8B\x00\x00\x00\x66\xC1\xE8\x00\x66\x8B", "xx???xxx?xx"
        "48 8B ? ? ? 66 C1 E8 ? 66 8B"

    Hex is uppercase throughout and the module offset is zero filled to eight
    digits. A masked byte is written as \x00 in the code string and as a single
    "?" in the IDA one. Cheat Engine's scanner accepts both "?" and "??", so
    the pattern is usable exactly as printed.

    Which of those lines actually reaches the clipboard is a setting. All three
    together are what the old tool produced and what a C++ project wants. Day
    to day the only useful one is the bare pattern, ready to paste into a scan.
    The Output setting names the parts it wants, in order, as a comma separated
    list of four names:

        aob     48 8D 4D F0 E8 ? ? ? ?              bare, the default
        aobq    "48 8D 4D F0 E8 ? ? ? ?"            quoted, as the old tool wrote it
        code    "\x48\x8D...", "xxxx?"              the C string and its mask
        header  Address of signature = game.exe + 0x00003E64

    So "aob" is the default and "header,code,aobq" reproduces GH SigMaker.
]]

local Format = {}

--
--- ∑ "Address of signature = module.exe + 0x0D762ED9", or the bare address
---   when the signature was not made inside a module.
--- @param signature table
--- @return string
--
function Format.Header(signature)
    if signature.Module and signature.Offset then
        return string.format("Address of signature = %s + 0x%08X",
            signature.Module.Name, signature.Offset)
    end
    return string.format("Address of signature = 0x%08X", signature.Address)
end

--- "\x48\x8B\x00". A masked byte is written as a zero byte.
function Format.Code(signature)
    local parts = {}
    for index, entry in ipairs(signature.Entries) do
        parts[index] = string.format("\\x%02X", entry.Masked and 0 or entry.Byte)
    end
    return table.concat(parts)
end

--- "xx???xxx?xx"
function Format.Mask(signature)
    local parts = {}
    for index, entry in ipairs(signature.Entries) do
        parts[index] = entry.Masked and "?" or "x"
    end
    return table.concat(parts)
end

--- "48 8B ? ? ? 66 C1 E8 ? 66 8B"
function Format.IDA(signature)
    local parts = {}
    for index, entry in ipairs(signature.Entries) do
        parts[index] = entry.Masked and "?" or string.format("%02X", entry.Byte)
    end
    return table.concat(parts, " ")
end

--- The named output parts, each rendering one line.
Format.Parts = {
    header = function(signature) return Format.Header(signature) end,
    code = function(signature)
        return string.format('"%s", "%s"', Format.Code(signature), Format.Mask(signature))
    end,
    aob = function(signature) return Format.IDA(signature) end,
    aobq = function(signature) return string.format('"%s"', Format.IDA(signature)) end
}

--
--- ∑ Builds the clipboard text from a comma separated list of part names.
---   An unknown name is reported rather than silently dropped. A list that
---   names nothing usable falls back to the bare pattern, because copying an
---   empty string would look like the tool had done nothing at all.
--- @param signature table
--- @param spec string|nil # "aob", "header,code,aobq", ...
--- @return string, string|nil # The text, and the first unknown part name.
--
function Format.Compose(signature, spec)
    local lines, unknown = {}, nil
    for name in tostring(spec or "aob"):gmatch("[^,%s]+") do
        local part = Format.Parts[name:lower()]
        if part then
            lines[#lines + 1] = part(signature)
        else
            unknown = unknown or name
        end
    end
    if #lines == 0 then lines[1] = Format.IDA(signature) end
    return table.concat(lines, "\n"), unknown
end

--
--- ∑ Everything, in the shape GH SigMaker wrote it.
--- @param signature table
--- @return string
--
function Format.All(signature)
    return (Format.Compose(signature, "header,code,aobq"))
end

--
--- ∑ The rows for a log block, so the console shows what was made without
---   the user having to paste the clipboard somewhere.
--- @param signature table
--- @return table
--
function Format.Rows(signature)
    local kinds = { displacement = 0, branch = 0, immediate = 0, structure = 0 }
    local masked = 0
    for _, entry in ipairs(signature.Entries) do
        kinds[entry.Kind] = (kinds[entry.Kind] or 0) + 1
        if entry.Masked then masked = masked + 1 end
    end
    return {
        { "Address", signature.Module
            and string.format("%s + 0x%X", signature.Module.Name, signature.Offset)
            or string.format("0x%X", signature.Address) },
        { "Pattern", Format.IDA(signature) },
        { "Mask", Format.Mask(signature) },
        { "Bytes", string.format("%d, %d wildcarded", #signature.Entries, masked) },
        { "Instructions", tostring(signature.Instructions) },
        { "Unique in", signature.Scope == "module" and signature.Module
            and signature.Module.Name or "the whole process" },
        kinds.displacement > 0 and { "Displacements", tostring(kinds.displacement) } or false,
        kinds.branch > 0 and { "Branch targets", tostring(kinds.branch) } or false,
        kinds.immediate > 0 and { "Immediates", tostring(kinds.immediate) } or false,
        signature.CrossedFunctionEnd
            and { "Warning", string.format("reaches past the function end at %X",
                signature.CrossedFunctionEnd) } or false,
        (signature.Notes and #signature.Notes > 0)
            and { "Notes", table.concat(signature.Notes, "; ") } or false
    }
end

return Format
