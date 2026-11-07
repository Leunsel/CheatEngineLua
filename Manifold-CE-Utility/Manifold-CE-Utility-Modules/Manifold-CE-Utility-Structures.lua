--[[
    Structure records.

    Turns a global structure, the kind Structure Dissect defines, into a tree
    of memory records, and removes the global structures when asked.

    The work is split in two. Plan reads the structure and produces plain
    tables: each record's description, address, type and sub-properties, and
    which records hang under which. Materialize then creates memory records
    from that plan. The split is what makes the interesting part testable
    without Cheat Engine, and it is where the 1.x version went wrong: it
    built records straight off the structure, with the address list handle
    never fetched, the selection index misaligned as soon as one structure
    had no name, string and array sizes never set, a custom type named
    nowhere, and a nested structure's pointer turned into a header that
    pointed at nothing.

    What is generated:

        Player                              address group header at the base
        ├─ [0000] — health                  +0
        ├─ [0004] — stamina                 +4
        └─ [0018] — inventory -> Inventory  +18, a pointer with one offset (0)
           ├─ [0000] — count                so its children resolve against
           └─ [0008] — items                the structure it points to

    A child structure Cheat Engine lays out inline (NestedStructure) becomes
    a header without offsets, its elements relative to the element itself.

    Only the elements labelled in Structure Dissect become records. A
    dissected structure of a few thousand bytes has an element per offset and
    almost none of them are named, so generating one record each buried the
    address list; Settings -> Include Unnamed Elements turns the rest back on.
    An unlabelled element that holds labelled ones survives as their container.

    A child's "+offset" address is relative to its parent's resolved address.
    That is how Cheat Engine's own relative addresses work, and it is why the
    root can be given "+0" and dropped under any pointer record later...

    The other direction is Update Offsets From Dump. After a game update the
    records still name the right fields but point at the old offsets. A dump
    of the class as a Markdown table knows the new ones. The two are matched
    by name, so "[00B8] — Dual Wield" finds the row "bDualWield | 0xB8" and
    takes its offset. Names are compared in lower case with everything but
    letters and digits removed, and the b in front of an Unreal bool may be
    left out. A record whose name is not in the dump is left as it is and
    named in the report, because guessing an offset is worse than keeping
    a wrong one that everybody can see.

    Generate Records From Dump starts from the same Markdown. It makes a
    header and one record per field, with the description written in words
    and the type read from the Type column. "CurrentArmorPlates | 0x0 |
    IntProperty" becomes "[0000] — Current Armor Plates", a 4 byte record at
    +0000. Those words lead back to the field, so the next dump can move the
    records it made.
]]

local Structures = {}
Structures.__index = Structures

function Structures:New(deps)
    return setmetatable({
        CE = deps.CE,
        Log = deps.Log,
        Settings = deps.Settings
    }, Structures)
end

--------------------------------------------------------
--                        Helpers                     --
--------------------------------------------------------

local function integer(value)
    local number = tonumber(value)
    if number == nil then return nil end
    return math.tointeger(number) or math.floor(number)
end

local function text(value)
    if type(value) ~= "string" or value == "" then return nil end
    return value
end

--- A boolean read through the RTTI fallback, whichever shape it arrives in.
local function flag(value)
    if value == true or value == 1 then return true end
    if type(value) == "string" then
        local lowered = value:lower()
        return lowered == "true" or lowered == "1"
    end
    return false
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- "+18" or "-8": the relative address string of an offset.
local function relative(offset)
    if offset >= 0 then return string.format("+%X", offset) end
    return string.format("-%X", -offset)
end

--- "0018" or "-0008": the offset as it appears in a description.
local function hex(offset)
    if offset >= 0 then return string.format("%04X", offset) end
    return string.format("-%04X", -offset)
end

--
--- ∑ The variable type constants, read from Cheat Engine with defines.lua's
---   values as the fallback, so a test without the globals still agrees
---   with the real thing.
--- @return table
--
function Structures:Types()
    local ce = self.CE
    return {
        Byte = ce:Constant("vtByte", 0),
        Word = ce:Constant("vtWord", 1),
        Dword = ce:Constant("vtDword", 2),
        Qword = ce:Constant("vtQword", 3),
        Single = ce:Constant("vtSingle", 4),
        Double = ce:Constant("vtDouble", 5),
        String = ce:Constant("vtString", 6),
        WideString = ce:Constant("vtWideString", 7),
        ByteArray = ce:Constant("vtByteArray", 8),
        Binary = ce:Constant("vtBinary", 9),
        Pointer = ce:Constant("vtPointer", 12),
        Custom = ce:Constant("vtCustom", 13)
    }
end

local function typeLabel(types, vartype, bytes)
    if vartype == types.Byte then return "Byte" end
    if vartype == types.Word then return "2 Bytes" end
    if vartype == types.Dword then return "4 Bytes" end
    if vartype == types.Qword then return "8 Bytes" end
    if vartype == types.Single then return "Float" end
    if vartype == types.Double then return "Double" end
    if vartype == types.String then return string.format("String[%d]", bytes) end
    if vartype == types.WideString then return string.format("Unicode String[%d]", bytes // 2) end
    if vartype == types.ByteArray then return string.format("Bytes[%d]", bytes) end
    if vartype == types.Binary then return "Binary" end
    if vartype == types.Pointer then return "Pointer" end
    if vartype == types.Custom then return "Custom" end
    return "Type " .. tostring(vartype)
end

--- The name of a structure, or nil when it has none.
function Structures:NameOf(structure)
    return text(self.CE:Get(structure, "Name"))
end

--------------------------------------------------------
--                       Selection                    --
--------------------------------------------------------

--
--- ∑ Every global structure, named or not, in Cheat Engine's order.
--- @return table, string|nil # { { Index, Name, Structure } }, or a reason.
--
function Structures:List()
    local count, err = self.CE:Call("getStructureCount")
    if type(count) ~= "number" then
        return {}, err or "getStructureCount returned nothing"
    end
    local entries = {}
    for index = 0, count - 1 do
        local structure = self.CE:Call("getStructure", index)
        if structure then
            entries[#entries + 1] = {
                Index = index,
                Name = self:NameOf(structure),
                Structure = structure
            }
        end
    end
    return entries
end

local function labelOf(entry)
    return entry.Name or string.format("(unnamed structure #%d)", entry.Index)
end

--
--- ∑ Lets the user pick a structure. The list index maps back through a
---   table built alongside it, so an unnamed structure in the middle of the
---   list no longer shifts every choice after it by one.
--- @return table|nil, string|nil # The entry, nil on cancel; a reason when
---         nothing could be offered.
--
function Structures:Select()
    local entries, err = self:List()
    if err then return nil, err end
    if #entries == 0 then return nil, "there are no global structures to choose from" end
    if not self.CE:Has("showSelectionList") then return nil, "showSelectionList is not available" end
    local list = self.CE:Call("createStringList")
    if not list then return nil, "createStringList is not available" end
    local shown = {}
    for _, entry in ipairs(entries) do
        local added = pcall(function() list.add(labelOf(entry)) end)
        if added then shown[#shown + 1] = entry end
    end
    local show = rawget(_G, "showSelectionList")
    local ok, index = self.CE:RunInMain(function()
        return show("Generate Structure Records", "Choose a structure", list, false)
    end)
    pcall(function() list.destroy() end)
    if not ok then return nil, "showSelectionList failed: " .. tostring(index) end
    if type(index) ~= "number" or index < 0 then return nil end
    return shown[index + 1]
end

--
--- ∑ The base address an open Structure Dissect window shows for this
---   structure, so the dialog offers the address the user is already
---   looking at. Structures are matched by name: Cheat Engine hands out a
---   fresh userdata per access, so identity is not something to compare.
--- @param structure userdata
--- @return string|nil
--
function Structures:SuggestBase(structure)
    local name = self:NameOf(structure)
    if not name then return nil end
    local forms = self.CE:Call("enumStructureForms")
    if type(forms) ~= "table" then return nil end
    for _, form in ipairs(forms) do
        local ok, address = pcall(function()
            local main = form.MainStruct
            if main == nil or main.Name ~= name then return nil end
            if (tonumber(form.ColumnCount) or 0) < 1 then return nil end
            return form.Column[0].AddressText
        end)
        if ok and type(address) == "string" and trim(address) ~= "" then
            return trim(address)
        end
    end
    return nil
end

--------------------------------------------------------
--                        Planning                    --
--------------------------------------------------------

--
--- ∑ The description of one element's record.
--- @param rel number # Offset relative to the record's parent.
--- @param name string|nil
--- @param vartype number|nil
--- @param bytes number
--- @param context table
--- @return string
--
function Structures:Describe(rel, name, vartype, bytes, context)
    local label = name or typeLabel(context.Types, vartype, bytes)
    if self.Settings.Structures.OffsetInDescription then
        return string.format("[%s] — %s", hex(rel), label)
    end
    return label
end

--- A pointer shown as a value: pointer-sized, hexadecimal.
function Structures:PointerValue(node, context)
    node.Type = context.Is64 and context.Types.Qword or context.Types.Dword
    node.ShowAsHex = true
end

--
--- ∑ Sets a node's type and the sub-properties that type needs. Strings and
---   byte arrays carry their length in the element's Bytesize; a memory
---   record without it would show one character or one byte.
--- @param node table
--- @param element userdata
--- @param vartype number|nil
--- @param bytes number
--- @param context table
--
function Structures:ApplyType(node, element, vartype, bytes, context)
    local types = context.Types
    if vartype == types.String then
        node.Type = types.String
        node.String = { Size = math.max(1, bytes), Unicode = false }
    elseif vartype == types.WideString then
        node.Type = types.String
        node.String = { Size = math.max(1, bytes // 2), Unicode = true }
    elseif vartype == types.ByteArray then
        node.Type = types.ByteArray
        node.Aob = { Size = math.max(1, bytes) }
    elseif vartype == types.Binary then
        node.Type = types.Binary
        node.Binary = { Startbit = 0, Size = math.max(1, math.min(bytes * 8, 32)) }
    elseif vartype == types.Custom then
        -- celua.txt documents no custom type on a structure element, but the
        -- element's CustomType object is reachable through the same RTTI path
        -- that serves Bytesize, and its name is what a memory record's
        -- CustomTypeName wants. Without one the bytes are kept as an array
        -- rather than guessed into a numeric type that would show nonsense.
        local customType = self.CE:Get(element, "CustomType")
        local customName = customType and text(self.CE:Get(customType, "name")) or nil
        if customName then
            node.Type = types.Custom
            node.CustomTypeName = customName
        else
            node.Type = types.ByteArray
            node.Aob = { Size = math.max(1, bytes) }
            node.Note = "custom type without a name, kept as bytes"
        end
    elseif vartype == types.Byte or vartype == types.Word or vartype == types.Dword
        or vartype == types.Qword or vartype == types.Single or vartype == types.Double then
        node.Type = vartype
    else
        node.Type = types.ByteArray
        node.Aob = { Size = math.max(1, bytes) }
        node.Note = "unknown type " .. tostring(vartype) .. ", kept as bytes"
    end
end

--
--- ∑ One element of a structure. Element[] is the documented array
---   property, getElement the documented method; a build may expose one
---   more reliably than the other.
--- @param structure userdata
--- @param index number
--- @return userdata|nil
--
function Structures:ElementAt(structure, index)
    local ok, element = pcall(function() return structure.Element[index] end)
    if ok and element ~= nil then return element end
    ok, element = pcall(function() return structure.getElement(index) end)
    if ok and element ~= nil then return element end
    return nil
end

--
--- ∑ Plans the record for one element and, for a pointer to a known
---   structure, the records under it.
--- @param element userdata
--- @param name string|nil
--- @param start number # Offset inside the structure that its parent's
---        pointer targets (ChildStructStart), 0 at the top level.
--- @param path table # Names of the structures on the way here, for cycles.
--- @param depth number # Nesting level below the root, 0 for the root's own elements.
--- @param context table
--- @return table
--
function Structures:PlanElement(element, name, start, path, depth, context)
    local ce = self.CE
    local types, settings = context.Types, self.Settings.Structures
    local offset = integer(ce:Get(element, "Offset")) or 0
    local rel = offset - start
    local vartype = integer(ce:Get(element, "Vartype"))
    local bytes = integer(ce:Get(element, "Bytesize")) or 0
    local display = ce:Get(element, "DisplayMethod")
    local node = {
        Address = relative(rel),
        Description = self:Describe(rel, name, vartype, bytes, context),
        Color = settings.ElementColor,
        Named = name ~= nil,
        Kind = "value",
        Children = {}
    }

    if vartype == types.Pointer then
        node.Kind = "pointer"
        local child = ce:Get(element, "ChildStruct")
        if child ~= nil then
            local childName = self:NameOf(child)
            local target = childName or "structure"
            local key = childName or tostring(child)
            -- Cheat Engine 7.5 can lay a child structure out inline at the
            -- element's offset instead of behind a pointer (NestedStructure).
            -- Then there is nothing to dereference, and the children are
            -- relative to the element itself.
            local inline = flag(ce:Get(element, "NestedStructure"))
            local blocked = (depth >= settings.MaxDepth and "depth limit") or (path[key] and "cycle") or nil
            if blocked then
                node.Truncated = true
                if inline then
                    node.Header = true
                    node.Type = types.Byte
                    node.Color = settings.PointerColor
                    node.Description = node.Description .. " -> " .. target .. " (inline, " .. blocked .. ")"
                else
                    self:PointerValue(node, context)
                    node.Description = node.Description .. " -> " .. target .. " (" .. blocked .. ")"
                end
            else
                node.Header = true
                node.Type = types.Byte
                node.Color = settings.PointerColor
                local start = 0
                if inline then
                    node.Kind = "inline"
                    node.Description = node.Description .. " -> " .. target .. " (inline)"
                else
                    node.Kind = "nested"
                    node.Offsets = { 0 }
                    node.Description = node.Description .. " -> " .. target
                    start = integer(ce:Get(element, "ChildStructStart")) or 0
                end
                path[key] = true
                self:PlanElements(child, node, start, path, depth + 1, context)
                path[key] = nil
            end
        else
            self:PointerValue(node, context)
        end
    else
        self:ApplyType(node, element, vartype, bytes, context)
    end

    if display == "dtHexadecimal" then
        node.ShowAsHex = true
    elseif display == "dtSignedInteger" then
        node.ShowAsSigned = true
    end
    return node
end

--
--- ∑ Plans the records for every element of a structure under one parent
---   node.
--- @param structure userdata
--- @param parent table
--- @param start number
--- @param path table
--- @param depth number # Nesting level below the root, 0 for the root's own elements.
--- @param context table
--
function Structures:PlanElements(structure, parent, start, path, depth, context)
    local count = integer(self.CE:Get(structure, "Count")) or 0
    for index = 0, count - 1 do
        local element = self:ElementAt(structure, index)
        if element then
            local name = text(self.CE:Get(element, "Name"))
            parent.Children[#parent.Children + 1] =
                self:PlanElement(element, name, start, path, depth, context)
        end
    end
end

--
--- ∑ Drops every node that was not labelled in Structure Dissect, keeping an
---   unlabelled one only when something labelled hangs under it. Naming a
---   field inside an unlabelled pointer must not lose it.
--- @param node table
--- @return boolean # Whether anything survived under this node.
--
local function prune(node)
    local kept = {}
    for _, child in ipairs(node.Children) do
        local hasLabelled = prune(child)
        if child.Named or hasLabelled then kept[#kept + 1] = child end
    end
    node.Children = kept
    return #kept > 0
end

--
--- ∑ Counts what a finished tree contains. Done after pruning rather than
---   during planning, so the summary describes the records that are actually
---   created and not the ones that were considered.
--- @param node table
--- @param stats table
--
local function tally(node, stats)
    for _, child in ipairs(node.Children) do
        stats.Records = stats.Records + 1
        if not child.Named then stats.Unnamed = stats.Unnamed + 1 end
        if child.Note then stats.Kept = stats.Kept + 1 end
        if child.Kind ~= "value" then stats.Pointers = stats.Pointers + 1 end
        if child.Kind == "nested" then stats.Nested = stats.Nested + 1 end
        if child.Kind == "inline" then stats.Inline = stats.Inline + 1 end
        if child.Truncated then stats.Truncated = stats.Truncated + 1 end
        tally(child, stats)
    end
end

local function newStats()
    return { Records = 1, Pointers = 0, Nested = 0, Inline = 0,
             Skipped = 0, Truncated = 0, Unnamed = 0, Kept = 0 }
end

--
--- ∑ The whole plan for one structure: plain tables, no memory records yet.
--- @param structure userdata
--- @param base string # The root's address.
--- @return table, table # The root node, and counts of what was planned.
--
function Structures:Plan(structure, base)
    local context = {
        Types = self:Types(),
        Is64 = self.CE:Call("targetIs64Bit") == true
    }
    local name = self:NameOf(structure) or "Structure"
    local root = {
        Description = name,
        Address = base,
        Header = true,
        Type = context.Types.Byte,
        Color = self.Settings.Structures.HeaderColor,
        Named = true,
        Kind = "root",
        Children = {}
    }
    self:PlanElements(structure, root, 0, { [name] = true }, 0, context)

    local planned = newStats()
    tally(root, planned)
    if not self.Settings.Structures.IncludeUnnamed then prune(root) end
    local stats = newStats()
    tally(root, stats)
    stats.Skipped = planned.Records - stats.Records
    return root, stats
end

--------------------------------------------------------
--                     Materializing                  --
--------------------------------------------------------

--
--- ∑ Creates the memory records a plan describes. The type is set before
---   the sub-properties that only exist for that type, and the record is
---   attached to its parent before its relative address is written.
--- @param plan table
--- @param addressList userdata
--- @param parent userdata|nil # The record the root goes under, nil for the top.
--- @return userdata|nil, number, string|nil # The root record, how many
---         records were created, and the error that stopped it, if any.
--
function Structures:Materialize(plan, addressList, parent)
    local created = 0
    local function build(node, parent)
        local ok, record = pcall(function() return addressList.createMemoryRecord() end)
        if not ok or record == nil then
            return nil, "createMemoryRecord failed: " .. tostring(record)
        end
        local applied, err = pcall(function()
            record.Description = node.Description
            if parent then record.appendToEntry(parent) end
            record.Type = node.Type
            if node.CustomTypeName then record.CustomTypeName = node.CustomTypeName end
            if node.String then
                record.String.Size = node.String.Size
                record.String.Unicode = node.String.Unicode
            end
            if node.Aob then record.Aob.Size = node.Aob.Size end
            if node.Binary then
                record.Binary.Startbit = node.Binary.Startbit
                record.Binary.Size = node.Binary.Size
            end
            record.Address = node.Address
            if node.Offsets then
                record.OffsetCount = #node.Offsets
                for index, offset in ipairs(node.Offsets) do
                    record.Offset[index - 1] = offset
                end
            end
            if node.Header then record.IsAddressGroupHeader = true end
            if node.Collapsed ~= nil then record.Collapsed = node.Collapsed end
            if node.ShowAsHex then record.ShowAsHex = true end
            if node.ShowAsSigned then record.ShowAsSigned = true end
            if node.Color then record.Color = node.Color end
        end)
        if not applied then
            return record, "setting up '" .. tostring(node.Description) .. "' failed: " .. tostring(err)
        end
        created = created + 1
        for _, child in ipairs(node.Children) do
            local _, childErr = build(child, record)
            if childErr then return record, childErr end
        end
        return record
    end
    local root, err = build(plan, parent)
    return root, created, err
end

--------------------------------------------------------
--                        Actions                     --
--------------------------------------------------------

--
--- ∑ The menu action: choose a structure, choose a base, build the records.
--- @return boolean, userdata|nil # Whether records were created, and the root.
--
function Structures:Generate()
    local log = self.Log
    local entry, reason = self:Select()
    if not entry then
        if reason then
            log:Warning("Generate structure records: " .. reason .. ".")
        else
            log:Info("Generate structure records: cancelled.")
        end
        return false
    end
    local structure, name = entry.Structure, labelOf(entry)
    local suggested = self:SuggestBase(structure) or self.Settings.Structures.DefaultBase
    local base, inputErr = self.CE:Input("Generate Structure Records",
        "Base address for '" .. name .. "'.\n\n" ..
        "An address, a symbol or a pointer path. Keep +0 for a relative block " ..
        "that can be dropped under any pointer record.",
        suggested)
    if base == nil then
        if inputErr then
            log:Error("Generate structure records: " .. inputErr .. ".")
        else
            log:Info("Generate structure records: cancelled.")
        end
        return false
    end
    base = trim(base)
    if base == "" then base = self.Settings.Structures.DefaultBase end

    local addressList = self.CE:AddressList()
    if not addressList then
        log:Error("Generate structure records: the address list is not available.")
        return false
    end
    local plan, stats = self:Plan(structure, base)
    if #plan.Children == 0 then
        if stats.Skipped > 0 then
            log:Warning(log:Block("Generate structure records: nothing to create", {
                { "Structure", name },
                { "Elements", tostring(stats.Skipped) },
                { "Labelled", "0" },
                "",
                "Only labelled elements become records. Name the fields you want in",
                "Structure Dissect, or switch on Settings -> Include Unnamed Elements",
                "to generate one record per element."
            }))
        else
            log:Warning(string.format("Generate structure records: '%s' has no elements.", name))
        end
        return false
    end

    local root, created, buildErr
    local ok, runErr = self.CE:RunInMain(function()
        root, created, buildErr = self:Materialize(plan, addressList)
    end)
    if not ok then
        log:Error("Generate structure records failed: " .. tostring(runErr))
        return false
    end
    if root then pcall(function() addressList.setSelectedRecord(root) end) end
    self.CE:Repaint()
    if buildErr then
        log:Error(string.format("Generate structure records: stopped after %d of %d records. %s",
            created or 0, stats.Records, buildErr))
        return false
    end
    log:Info(log:Block("Structure records generated", {
        { "Structure", name },
        { "Base", base },
        { "Records", tostring(created) },
        stats.Pointers > 0 and { "Pointers", tostring(stats.Pointers) } or false,
        stats.Nested > 0 and { "Nested structures", tostring(stats.Nested) } or false,
        stats.Inline > 0 and { "Inline structures", tostring(stats.Inline) } or false,
        stats.Unnamed > 0 and { "Unlabelled containers", tostring(stats.Unnamed) } or false,
        stats.Skipped > 0 and { "Unlabelled, skipped", tostring(stats.Skipped) } or false,
        stats.Kept > 0 and { "Kept as bytes", tostring(stats.Kept) } or false,
        stats.Truncated > 0 and { "Not expanded", stats.Truncated .. " (depth limit or cycle)" } or false
    }))
    return true, root
end

--
--- ∑ Removes every global structure. Backwards, so an index stays valid
---   after the one above it is gone.
--- @return boolean
--
function Structures:RemoveAll()
    local log = self.Log
    local count, err = self.CE:Call("getStructureCount")
    if type(count) ~= "number" then
        log:Error("Remove all structures: " .. tostring(err or "getStructureCount returned nothing") .. ".")
        return false
    end
    if count == 0 then
        log:Info("Remove all structures: there are none.")
        return false
    end
    if self.Settings.ConfirmDestructiveActions then
        local yes, reason = self.CE:Confirm("Remove all global structures?", count)
        if not yes then
            log:Info("Remove all structures: " .. (reason and ("blocked, " .. reason) or "cancelled") .. ".")
            return false
        end
    end
    local removed, failed = 0, 0
    for index = count - 1, 0, -1 do
        local structure = self.CE:Call("getStructure", index)
        if structure then
            local ok = pcall(function() structure.removeFromGlobalStructureList() end)
            if ok then removed = removed + 1 else failed = failed + 1 end
        else
            failed = failed + 1
        end
    end
    self.CE:Repaint()
    if failed > 0 then
        log:Warning(string.format("Removed %d structure(s); %d could not be removed.", removed, failed))
    else
        log:Info(string.format("Removed %d structure(s).", removed))
    end
    return failed == 0
end

--------------------------------------------------------
--                  Offsets from a dump               --
--------------------------------------------------------

--- How many names a dialog lists before it says how many more there are.
local NAMES_IN_DIALOG = 10

--- What a Blueprint variable carries after its name. A number and a GUID,
--- which no description repeats.
local GUID_SUFFIX = "_%d+_" .. string.rep("%x", 32) .. "$"

--- The header words a dump's name column goes by.
local NAME_HEADERS = { field = true, name = true, property = true, member = true }

--- A name brought down to lower case letters and digits. This is where
--- "Dual Wield" and "DualWield" become the same thing.
local function keyOf(value)
    return (tostring(value or ""):lower():gsub("[^%w]", ""))
end

--- The name part of a description. The offset in brackets in front and the
--- arrow Generate Structure Records adds behind a pointer are not part of it.
local function nameOfRecord(description)
    local name = tostring(description or "")
    name = name:gsub("^%s*%[%-?%x+%]", "")
    name = name:gsub("%s+%->.*$", "")
    name = trim(name)
    for _, dash in ipairs({ "—", "–", "-", ":" }) do
        if name:sub(1, #dash) == dash then
            name = trim(name:sub(#dash + 1))
            break
        end
    end
    return name
end

--- "+00B8" as its value and the number of digits it was written with, so the
--- new offset goes back in the same shape. Nil for anything that is not a
--- relative address.
local function parseRelative(address)
    local sign, digits = tostring(address or ""):match("^%s*([%+%-])%s*(%x+)%s*$")
    if not sign then return nil end
    local value = tonumber(digits, 16)
    if sign == "-" then value = -value end
    return value, #digits
end

local function writeRelative(offset, width)
    local sign = offset < 0 and "-" or "+"
    return sign .. string.format("%0" .. width .. "X", math.abs(offset))
end

--
--- ∑ The description with the offset in its brackets moved along. Only when
---   the brackets state the old offset, so a description that says something
---   else in front is not rewritten behind its owner's back.
--- @param description string
--- @param old number
--- @param new number
--- @return string|nil # Nil when the description stays as it is.
--
local function moveDescription(description, old, new)
    local sign, digits = description:match("^%s*%[(%-?)(%x+)%]")
    if not digits then return nil end
    local stated = tonumber(digits, 16)
    if sign == "-" then stated = -stated end
    if stated ~= old then return nil end
    local text = (new < 0 and "-" or "") .. string.format("%0" .. #digits .. "X", math.abs(new))
    return (description:gsub("%[%-?%x+%]", "[" .. text .. "]", 1))
end

--- The cells of one Markdown table row, or nil for a line that is not one.
local function cellsOf(line)
    local body = line:match("^%s*|(.*)$")
    if not body then return nil end
    body = body:gsub("|%s*$", "")
    local cells = {}
    for cell in (body .. "|"):gmatch("(.-)|") do
        cells[#cells + 1] = trim((cell:gsub("`", "")))
    end
    return cells
end

--- An offset cell. Hexadecimal with or without 0x, the way Cheat Engine
--- writes offsets everywhere else.
local function parseOffset(cell)
    local digits = cell:match("^0[xX](%x+)$") or cell:match("^(%x+)$")
    if not digits then return nil end
    return tonumber(digits, 16)
end

--- A size cell. Dumps write sizes in decimal, so 40 is forty bytes, and only
--- a 0x in front makes it hexadecimal.
local function parseSize(cell)
    local digits = cell:match("^0[xX](%x+)$")
    if digits then return tonumber(digits, 16) end
    if cell:match("^%d+$") then return tonumber(cell) end
    return nil
end

--
--- ∑ Reads the fields out of a Markdown dump. Every table with a name column
---   and an Offset column counts. A class pasted together with its parent
---   classes therefore gives one layout, which is what a record list under
---   one object needs. Type and Size are read too when the table has them,
---   and the first heading is the dump's title.
--- @param markdown string
--- @return table, string|nil # { { Name, Offset, Type, Size } } in the order
---         of the dump, and the title.
--
function Structures.ParseDump(markdown)
    local fields, title = {}, nil
    local columns = nil
    for line in (tostring(markdown or "") .. "\n"):gmatch("(.-)\r?\n") do
        local cells = cellsOf(line)
        if not cells then
            columns = nil
            local heading = line:match("^%s*#+%s+(.-)%s*$")
            if not title and heading then title = text((heading:gsub("`", ""))) end
        elseif not columns then
            local found = {}
            for index, cell in ipairs(cells) do
                local word = cell:lower()
                if NAME_HEADERS[word] and not found.Name then found.Name = index end
                if word == "offset" then found.Offset = index end
                if word == "type" then found.Type = index end
                if word == "size" then found.Size = index end
            end
            if found.Name and found.Offset then columns = found end
        else
            local name = cells[columns.Name]
            local offset = parseOffset(cells[columns.Offset] or "")
            if name and name ~= "" and offset then
                fields[#fields + 1] = {
                    Name = name,
                    Offset = offset,
                    Type = columns.Type and text(cells[columns.Type]) or nil,
                    Size = columns.Size and parseSize(cells[columns.Size] or "") or nil
                }
            end
        end
    end
    return fields, title
end

--
--- ∑ The dumped fields by name. A field answers to its own name and, when it
---   is an Unreal bool, to the name without the b. Its own name always wins
---   over that shorter one. A name two fields share at different offsets
---   cannot say which one a record meant, so it is kept apart as ambiguous.
--- @param fields table
--- @return table, table # Field by key, and the keys that are ambiguous.
--
local function indexFields(fields)
    local byKey, ambiguous, own = {}, {}, {}
    local function add(key, field)
        if key == "" then return end
        local known = byKey[key]
        if known == nil then
            byKey[key] = field
        elseif known.Offset ~= field.Offset then
            ambiguous[key] = true
        end
    end
    for _, field in ipairs(fields) do
        local key = keyOf((field.Name:gsub(GUID_SUFFIX, "")))
        own[key] = true
        add(key, field)
    end
    for _, field in ipairs(fields) do
        local plain = field.Name:gsub(GUID_SUFFIX, "")
        if plain:match("^b%u") then
            local key = keyOf(plain:sub(2))
            if not own[key] then add(key, field) end
        end
    end
    return byKey, ambiguous
end

--
--- ∑ The records an update works on. A selected group gives its direct
---   children, because their offsets are the ones into the object the group
---   resolves to. Anything deeper hangs under a pointer into another object
---   and is left alone. A selected record without children is taken as it is.
--- @param addressList userdata
--- @return table # Records in address list order, each once.
--
function Structures:OffsetTargets(addressList)
    local ce = self.CE
    local selected = {}
    local ok, result = pcall(function() return addressList.getSelectedRecords() end)
    if ok and type(result) == "table" then
        for _, record in pairs(result) do selected[#selected + 1] = record end
    end
    if #selected == 0 then
        local record = ce:Get(addressList, "SelectedRecord")
        if record ~= nil then selected[1] = record end
    end
    table.sort(selected, function(a, b)
        return (integer(ce:Get(a, "Index")) or 0) < (integer(ce:Get(b, "Index")) or 0)
    end)

    local targets, seen = {}, {}
    local function take(record)
        local key = ce:Get(record, "ID") or record
        if seen[key] then return end
        seen[key] = true
        targets[#targets + 1] = record
    end
    for _, record in ipairs(selected) do
        local count = integer(ce:Get(record, "Count")) or 0
        if count > 0 then
            for index = 0, count - 1 do
                local okChild, child = pcall(function() return record.Child[index] end)
                if okChild and child ~= nil then take(child) end
            end
        else
            take(record)
        end
    end
    return targets
end

--
--- ∑ Works out what an update would change without changing anything.
--- @param records table
--- @param fields table # What ParseDump returned.
--- @return table # { Moved, Unchanged, Missing, Ambiguous, Skipped }, each a
---         list of { Record, Name, Address } with Field, New and Description on
---         the moved ones.
--
function Structures:PlanOffsets(records, fields)
    local byKey, ambiguous = indexFields(fields)
    local plan = { Moved = {}, Unchanged = {}, Missing = {}, Ambiguous = {}, Skipped = {} }
    for _, record in ipairs(records) do
        local description = tostring(self.CE:Get(record, "Description") or "")
        local address = tostring(self.CE:Get(record, "Address") or "")
        local name = nameOfRecord(description)
        local entry = { Record = record, Name = name ~= "" and name or description, Address = address }
        local old, width = parseRelative(address)
        local key = keyOf(name)
        local field = byKey[key]
        if old == nil or key == "" then
            plan.Skipped[#plan.Skipped + 1] = entry
        elseif ambiguous[key] then
            plan.Ambiguous[#plan.Ambiguous + 1] = entry
        elseif field == nil then
            plan.Missing[#plan.Missing + 1] = entry
        elseif field.Offset == old then
            plan.Unchanged[#plan.Unchanged + 1] = entry
        else
            entry.Field = field.Name
            entry.New = writeRelative(field.Offset, width)
            entry.Description = moveDescription(description, old, field.Offset)
            plan.Moved[#plan.Moved + 1] = entry
        end
    end
    return plan
end

--
--- ∑ Writes the planned offsets. Setting a record's address can drop its
---   pointer offsets, so a record that has some gets them back right after.
---   The count goes first and then each offset as text, which keeps a symbol
---   in an offset intact. Only the indices the record reported are touched.
--- @param moved table # plan.Moved
--- @return number, table # How many were written, and { { entry, reason } }.
--
function Structures:ApplyOffsets(moved)
    local applied, failures = 0, {}
    for _, entry in ipairs(moved) do
        local record = entry.Record
        local ok, err = pcall(function()
            local count = integer(record.OffsetCount) or 0
            local offsets = {}
            for index = 0, count - 1 do offsets[index] = record.OffsetText[index] end
            record.Address = entry.New
            if count > 0 then
                record.OffsetCount = count
                for index = 0, count - 1 do record.OffsetText[index] = offsets[index] end
            end
            if entry.Description then record.Description = entry.Description end
        end)
        if ok then
            applied = applied + 1
        else
            failures[#failures + 1] = { entry, tostring(err) }
        end
    end
    return applied, failures
end

local function namesOf(entries, limit)
    local names = {}
    for index, entry in ipairs(entries) do
        if limit and index > limit then
            names[#names + 1] = string.format("and %d more", #entries - limit)
            break
        end
        names[#names + 1] = entry.Name
    end
    return table.concat(names, ", ")
end

--
--- ∑ The rows that describe a plan, shared by the report and the case where
---   there is nothing to move.
--- @param plan table
--- @param fieldCount number
--- @return table
--
local function planRows(plan, fieldCount)
    local total = #plan.Moved + #plan.Unchanged + #plan.Missing + #plan.Ambiguous + #plan.Skipped
    return {
        { "Fields in dump", tostring(fieldCount) },
        { "Records", tostring(total) },
        { "Moved", tostring(#plan.Moved) },
        #plan.Unchanged > 0 and { "Already right", tostring(#plan.Unchanged) } or false,
        #plan.Missing > 0 and { "Not in dump", namesOf(plan.Missing) } or false,
        #plan.Ambiguous > 0 and { "Ambiguous", namesOf(plan.Ambiguous) } or false,
        #plan.Skipped > 0 and { "No relative address", namesOf(plan.Skipped) } or false
    }
end

--
--- ∑ The dump both dump actions work from. A caller can hand the Markdown in,
---   otherwise it is read from the clipboard. Says why when there is nothing
---   usable, so the actions only have to stop.
--- @param markdown string|nil
--- @param label string # The action, for the log line.
--- @return table|nil, string|nil # The fields and the title, or nil.
--
function Structures:ReadDump(markdown, label)
    local log = self.Log
    if markdown == nil then
        local clipboard, err = self.CE:Call("readFromClipboard")
        if type(clipboard) ~= "string" then
            log:Error(label .. ": " .. tostring(err or "the clipboard holds no text") .. ".")
            return nil
        end
        markdown = clipboard
    end
    local fields, title = Structures.ParseDump(markdown)
    if #fields == 0 then
        log:Warning(log:Block(label .. ": the dump has no fields", {
            "Copy a Markdown table with a name column and an Offset column first,",
            "for example a row like | bDualWield | 0xB8 | BoolProperty | 1 |."
        }))
        return nil
    end
    return fields, title
end

--
--- ∑ The menu action. Moves the selected records onto the offsets of a
---   Markdown dump. The dump is read from the clipboard unless a caller hands
---   the text in.
--- @param text string|nil
--- @return boolean, table|nil # Whether records were moved, and the plan.
--
function Structures:UpdateOffsets(text)
    local log = self.Log
    local label = "Update offsets from dump"
    local addressList = self.CE:AddressList()
    if not addressList then
        log:Error(label .. ": the address list is not available.")
        return false
    end
    local records = self:OffsetTargets(addressList)
    if #records == 0 then
        log:Warning(label .. ": select the group or the records to update first.")
        return false
    end
    local fields = self:ReadDump(text, label)
    if not fields then return false end

    local plan = self:PlanOffsets(records, fields)
    if #plan.Moved == 0 then
        log:Info(log:Block(label .. ": nothing to move", planRows(plan, #fields)))
        return false, plan
    end
    if self.Settings.ConfirmDestructiveActions then
        local notes = {}
        if #plan.Unchanged > 0 then
            notes[#notes + 1] = string.format("%d already match the dump.", #plan.Unchanged)
        end
        local untouched = {}
        for _, list in ipairs({ plan.Missing, plan.Ambiguous, plan.Skipped }) do
            for _, entry in ipairs(list) do untouched[#untouched + 1] = entry end
        end
        if #untouched > 0 then
            notes[#notes + 1] = string.format("%d stay as they are: %s",
                #untouched, namesOf(untouched, NAMES_IN_DIALOG))
        end
        local yes, reason = self.CE:Confirm("Move the selected records to the offsets in the dump?",
            #plan.Moved, table.concat(notes, "\n"))
        if not yes then
            log:Info(label .. ": " .. (reason and ("blocked, " .. reason) or "cancelled") .. ".")
            return false, plan
        end
    end

    local applied, failures
    local ok, runErr = self.CE:RunInMain(function()
        applied, failures = self:ApplyOffsets(plan.Moved)
    end)
    if not ok then
        log:Error(label .. " failed: " .. tostring(runErr))
        return false, plan
    end
    self.CE:Repaint()

    local rows = planRows(plan, #fields)
    rows[#rows + 1] = ""
    for _, entry in ipairs(plan.Moved) do
        rows[#rows + 1] = { entry.Name, string.format("%s -> %s  (%s)", entry.Address, entry.New, entry.Field) }
    end
    for _, failure in ipairs(failures) do
        rows[#rows + 1] = { "Failed", failure[1].Name .. ", " .. failure[2] }
    end
    local title = #failures > 0
        and string.format("Offsets updated from dump, %d of %d", applied, #plan.Moved)
        or "Offsets updated from dump"
    if #failures > 0 then
        log:Warning(log:Block(title, rows))
    else
        log:Info(log:Block(title, rows))
    end
    return applied > 0, plan
end

--------------------------------------------------------
--                  Records from a dump               --
--------------------------------------------------------

--- What Cheat Engine type an Unreal property kind is read as.
local PROPERTY_KINDS = {
    BoolProperty = "Byte", ByteProperty = "Byte", Int8Property = "Byte",
    Int16Property = "Word", UInt16Property = "Word",
    IntProperty = "Dword", UInt32Property = "Dword",
    Int64Property = "Qword", UInt64Property = "Qword",
    FloatProperty = "Single", DoubleProperty = "Double",
    StrProperty = "String"
}

--- What a type the table does not know is read as, by its size. An enum is
--- one byte, an object reference eight, and both read fine this way.
local SIZE_KINDS = { [1] = "Byte", [2] = "Word", [4] = "Dword", [8] = "Pointer" }

--
--- ∑ A dumped name as the words a person reads. "CurrentArmorPlates" becomes
---   "Current Armor Plates", "bDualWield" becomes "Dual Wield" and
---   "AimingFOVMultiplier" becomes "Aiming FOV Multiplier". The words still
---   lead keyOf back to the field, so a record made from them can be moved by
---   the next dump.
--- @param name string
--- @return string
--
local function wordsOf(name)
    local plain = tostring(name or ""):gsub(GUID_SUFFIX, "")
    if plain:match("^b%u") then plain = plain:sub(2) end
    plain = plain:gsub("_", " ")
    plain = plain:gsub("(%l)(%u)", "%1 %2")
    plain = plain:gsub("(%u)(%u%l)", "%1 %2")
    return trim((plain:gsub("%s+", " ")))
end

Structures.WordsOf = wordsOf

--
--- ∑ The record for one dumped field. Known property kinds get their own
---   type. Anything else is read by its size, and what has no size Cheat
---   Engine can read as one value, a struct of twelve bytes for example, is
---   kept as bytes of that length rather than guessed into numbers.
--- @param field table
--- @param context table
--- @return table
--
function Structures:DumpNode(field, context)
    local types, settings = context.Types, self.Settings.Structures
    local kind = PROPERTY_KINDS[field.Type or ""] or SIZE_KINDS[field.Size or 0]
    local words = wordsOf(field.Name)
    local node = {
        Address = writeRelative(field.Offset, 4),
        Description = self:Describe(field.Offset, words, nil, 0, context),
        Named = true,
        Kind = "value",
        Children = {}
    }
    if kind == "Single" or kind == "Double" then
        node.Type = types[kind]
        node.Color = settings.FloatColor
    elseif kind == "String" then
        -- An FString holds a pointer to its characters, so the record follows it.
        node.Type = types.String
        node.String = { Size = settings.DumpStringLength, Unicode = true }
        node.Offsets = { 0 }
        node.Color = settings.StringColor
    elseif kind == "Pointer" then
        node.Type = types.Qword
        node.ShowAsHex = true
        node.Color = settings.ElementColor
    elseif kind then
        node.Type = types[kind]
        node.Color = settings.IntegerColor
    else
        node.Type = types.ByteArray
        node.Aob = { Size = math.max(1, field.Size or 1) }
        node.Note = "kept as bytes"
        node.Color = settings.ElementColor
    end
    return node
end

--
--- ∑ The whole plan for a dump. A header at the base and one record per field
---   in offset order. A field pasted twice is made once. The header takes the
---   offset into its description when the base is one, the way its children
---   carry theirs.
--- @param fields table
--- @param title string
--- @param base string
--- @return table, table # The root node, and { Records, Strings, Kept }.
--
function Structures:PlanDump(fields, title, base)
    local context = { Types = self:Types() }
    local settings = self.Settings.Structures
    local offset = parseRelative(base)
    local root = {
        Description = offset and self:Describe(offset, title, nil, 0, context) or title,
        Address = base,
        Header = true,
        Type = context.Types.Byte,
        -- A dumped class is a block inside an object, the same as an inline
        -- structure in Generate Structure Records, so it takes that colour.
        Color = settings.PointerColor,
        Named = true,
        Kind = "root",
        Children = {}
    }
    local ordered = {}
    for index, field in ipairs(fields) do ordered[index] = { Field = field, Index = index } end
    table.sort(ordered, function(a, b)
        if a.Field.Offset ~= b.Field.Offset then return a.Field.Offset < b.Field.Offset end
        return a.Index < b.Index
    end)
    local stats, seen = { Records = 1, Strings = 0, Kept = 0 }, {}
    for _, item in ipairs(ordered) do
        local field = item.Field
        local key = field.Name .. "@" .. field.Offset
        if not seen[key] then
            seen[key] = true
            local node = self:DumpNode(field, context)
            root.Children[#root.Children + 1] = node
            stats.Records = stats.Records + 1
            if node.String then stats.Strings = stats.Strings + 1 end
            if node.Note then stats.Kept = stats.Kept + 1 end
        end
    end
    return root, stats
end

--
--- ∑ The menu action. Builds a record group from a Markdown dump. A relative
---   base like +00FC puts the group inside the selected record, because only
---   there does the offset mean anything. Any other base starts a group at the
---   top of the table.
--- @param markdown string|nil # Nil reads the clipboard.
--- @return boolean, userdata|nil # Whether records were created, and the header.
--
function Structures:GenerateFromDump(markdown)
    local log = self.Log
    local label = "Generate records from dump"
    local fields, heading = self:ReadDump(markdown, label)
    if not fields then return false end
    local addressList = self.CE:AddressList()
    if not addressList then
        log:Error(label .. ": the address list is not available.")
        return false
    end
    local title = wordsOf(heading or "")
    if title == "" then title = "Structure" end

    local base, inputErr = self.CE:Input("Generate Records From Dump",
        "Base address for '" .. title .. "'.\n\n" ..
        "An address, a symbol or a pointer path. A relative offset such as +00FC " ..
        "places the records inside the selected record.",
        self.Settings.Structures.DefaultBase)
    if base == nil then
        if inputErr then
            log:Error(label .. ": " .. inputErr .. ".")
        else
            log:Info(label .. ": cancelled.")
        end
        return false
    end
    base = trim(base)
    if base == "" then base = self.Settings.Structures.DefaultBase end

    local parent = nil
    if parseRelative(base) then parent = self.CE:Get(addressList, "SelectedRecord") end
    local plan, stats = self:PlanDump(fields, title, base)

    local root, created, buildErr
    local ok, runErr = self.CE:RunInMain(function()
        root, created, buildErr = self:Materialize(plan, addressList, parent)
    end)
    if not ok then
        log:Error(label .. " failed: " .. tostring(runErr))
        return false
    end
    if root then pcall(function() addressList.setSelectedRecord(root) end) end
    self.CE:Repaint()
    if buildErr then
        log:Error(string.format("%s: stopped after %d of %d records. %s",
            label, created or 0, stats.Records, buildErr))
        return false
    end
    log:Info(log:Block("Records generated from dump", {
        { "Title", title },
        { "Base", base },
        { "Under", parent and tostring(self.CE:Get(parent, "Description")) or "the top of the table" },
        { "Records", tostring(created) },
        stats.Strings > 0 and { "Strings", tostring(stats.Strings) } or false,
        stats.Kept > 0 and { "Kept as bytes", tostring(stats.Kept) } or false
    }))
    return true, root
end

return Structures
