--[[
    The editor's view of a Cheat Engine variable type.

    Cheat Engine stores a record's type twice over. The member Type is the
    integer of the TVariableType enum and VarType is the same value read back
    as its name, so a module that wants one of them has to know about the
    other. This file is the only place that knows the mapping, and every tag,
    label and parse of a type goes through it.

    The list below is the editor list and not the enum. vtAll, vtGrouped and
    vtByteArrays are scan types whose byte size is zero, a record of that type
    reads as an empty string, and offering them would only make broken records.
    vtUnicodeString and vtPointer are missing for a different reason. Cheat
    Engine normalises both of them on write, a unicode string becomes a string
    with the unicode flag on and a pointer becomes the pointer sized integer
    shown as hexadecimal, so neither value is ever read back from a record and
    neither belongs in the read path.

    A group header is not a type at all. It is the IsGroupHeader flag, which is
    why the group tag sits beside the list rather than inside it.

    Nothing here touches Cheat Engine. Every function takes a Records node,
    which is a plain table, so the whole file runs in the test suite with no
    Cheat Engine anywhere near it.
]]

local Types = {}

--
--- ∑ The editor list, in the order Cheat Engine's own type dialog shows it.
---   Every entry is treated as frozen. Nothing writes into one.
--
Types.List = {
    { Key = "Byte",          VarType = "vtByte",          Type = 0,  Label = "Byte",                  Tag = "1B"  },
    { Key = "Word",          VarType = "vtWord",          Type = 1,  Label = "2 Bytes",               Tag = "2B"  },
    { Key = "Dword",         VarType = "vtDword",         Type = 2,  Label = "4 Bytes",               Tag = "4B"  },
    { Key = "Qword",         VarType = "vtQword",         Type = 3,  Label = "8 Bytes",               Tag = "8B"  },
    { Key = "Single",        VarType = "vtSingle",        Type = 4,  Label = "Float",                 Tag = "F"   },
    { Key = "Double",        VarType = "vtDouble",        Type = 5,  Label = "Double",                Tag = "D"   },
    { Key = "String",        VarType = "vtString",        Type = 6,  Label = "String",                Tag = "STR" },
    { Key = "ByteArray",     VarType = "vtByteArray",     Type = 8,  Label = "Array of Bytes",        Tag = "AOB" },
    { Key = "Binary",        VarType = "vtBinary",        Type = 9,  Label = "Binary",                Tag = "BIN" },
    { Key = "AutoAssembler", VarType = "vtAutoAssembler", Type = 11, Label = "Auto Assembler Script", Tag = "AA"  },
    { Key = "Custom",        VarType = "vtCustom",        Type = 13, Label = "Custom",                Tag = "CUS" }
}

--- What a group header draws in the type column. A group header carries a type
--- as well and it means nothing, so this wins over it.
Types.GroupTag = "GRP"

--- What a string record draws while its unicode flag is on. Cheat Engine
--- stores it as a plain string, so the flag is the only thing that tells them
--- apart.
Types.UnicodeTag = "WSTR"

--- What a record whose type this file does not know draws. A table written by
--- a plugin can hold one, and the tree still has to show a row for it.
Types.UnknownTag = "?"

--- The label for a record that is a group header, for the places that show a
--- type name rather than a tag.
Types.GroupLabel = "Group header"

--- The label for a type this file does not know.
Types.UnknownLabel = "Unknown"

Types.ByKey, Types.ByVarType, Types.ByType = {}, {}, {}

for _, entry in ipairs(Types.List) do
    Types.ByKey[entry.Key] = entry
    Types.ByVarType[entry.VarType] = entry
    Types.ByType[entry.Type] = entry
end

--------------------------------------------------------
--                  The parse table                   --
--------------------------------------------------------

--- Everything Parse accepts, lowered. The key, the label, the tag and the
--- enum name of every entry land here, plus the few words a person types
--- instead of them.
local PARSE = {}

for _, entry in ipairs(Types.List) do
    PARSE[entry.Key:lower()] = entry
    PARSE[entry.Label:lower()] = entry
    PARSE[entry.Tag:lower()] = entry
    PARSE[entry.VarType:lower()] = entry
end

PARSE["script"] = Types.ByKey.AutoAssembler
PARSE["auto assembler"] = Types.ByKey.AutoAssembler
PARSE["array of byte"] = Types.ByKey.ByteArray
PARSE["4 byte"] = Types.ByKey.Dword
PARSE["8 byte"] = Types.ByKey.Qword
PARSE["2 byte"] = Types.ByKey.Word

--------------------------------------------------------
--                   Reading a node                   --
--------------------------------------------------------

--
--- ∑ The entry for one record, by its integer type first and its enum name
---   second.
---
---   The integer is the cheaper and the more reliable of the two, because the
---   name only exists on a node whose detail was read. A node holding a type
---   this list does not carry, such as a scan type, gets nothing back.
--- @param node table|nil # A Records node, or anything with Type and VarType.
--- @return table|nil # The entry, or nil when the type is not an editor type.
--
function Types.For(node)
    if type(node) ~= "table" then return nil end
    local entry = Types.ByType[node.Type]
    if entry ~= nil then return entry end
    return Types.ByVarType[node.VarType]
end

--
--- ∑ The short tag the tree draws in the type column.
---
---   A plain group header wins over everything, because its type is noise. An
---   address group header does carry a real type and an address, so it falls
---   through to the type tag the way any other record does.
--- @param node table|nil
--- @return string
--
function Types.TagFor(node)
    if type(node) ~= "table" then return Types.UnknownTag end
    if node.IsGroupHeader == true and node.IsAddressGroupHeader ~= true then
        return Types.GroupTag
    end
    local entry = Types.For(node)
    if entry == nil then return Types.UnknownTag end
    local tag = entry.Tag
    if entry.Key == "String" and node.Unicode == true then tag = Types.UnicodeTag end
    if Types.IsPointer(node) then return "P" .. tag end
    return tag
end

--
--- ∑ The long name of a record's type, the one the inspector and the export
---   show.
--- @param node table|nil
--- @return string
--
function Types.LabelFor(node)
    if type(node) ~= "table" then return Types.UnknownLabel end
    if node.IsGroupHeader == true and node.IsAddressGroupHeader ~= true then
        return Types.GroupLabel
    end
    local entry = Types.For(node)
    if entry == nil then return Types.UnknownLabel end
    if entry.Key == "String" and node.Unicode == true then return "Unicode String" end
    return entry.Label
end

--------------------------------------------------------
--                  Reading a person                  --
--------------------------------------------------------

--
--- ∑ The entry behind whatever a person typed, so the filter takes type aa as
---   happily as type 4 bytes or type vtDword.
---
---   Case and the spaces around the word do not matter. Anything else does,
---   because guessing at a half typed type name would filter the tree to
---   something the person did not ask for.
--- @param text string|nil
--- @return table|nil
--
function Types.Parse(text)
    if type(text) ~= "string" then return nil end
    local clean = text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "):lower()
    if clean == "" then return nil end
    return PARSE[clean]
end

--------------------------------------------------------
--                     Questions                      --
--------------------------------------------------------

--- True when the record runs a script, which is the one type whose activation
--- executes code.
function Types.IsScript(node)
    local entry = Types.For(node)
    return entry ~= nil and entry.Key == "AutoAssembler"
end

--- True when the record is a header rather than a value.
function Types.IsGroup(node)
    return type(node) == "table" and node.IsGroupHeader == true
end

--- True when the record reads its address through a pointer chain. Offsets are
--- what make a pointer, there is no pointer type stored on a record.
function Types.IsPointer(node)
    if type(node) ~= "table" then return false end
    local count = tonumber(node.OffsetCount) or 0
    return count > 0
end

return Types
