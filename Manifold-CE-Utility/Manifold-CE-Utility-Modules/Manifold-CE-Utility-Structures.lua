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
    root can be given "+0" and dropped under any pointer record later.
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
--- @return userdata|nil, number, string|nil # The root record, how many
---         records were created, and the error that stopped it, if any.
--
function Structures:Materialize(plan, addressList)
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
    local root, err = build(plan, nil)
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

return Structures
