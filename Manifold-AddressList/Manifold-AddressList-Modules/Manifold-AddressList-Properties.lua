--[[
    Every property of a memory record this window can show or change, in one
    schema, plus the readers and writers for the four things that are too big
    for a grid row, which are the pointer chain, the script, the drop-down list
    and the hotkeys.

    A definition says what a property is called, which category it belongs to,
    which editor it takes, whether it applies to a record at all, whether undo
    can put it back and what a person is told when they hover it. The grid and
    the inspector read the schema and know nothing about memory records, and
    this file knows nothing about drawing. That is the whole split.

    Cheat Engine facts this file is built on, because most of them cost a write
    that looks like it worked.
      * Type is an integer and a string written to it becomes vtByte without a
        word. VarType reads the enum NAME back. So a type change writes the
        integer and reads the name back to check it.
      * Cheat Engine range checks nothing on Type, so the integer only ever
        comes out of the type list.
      * Writing Address clears the pointer offsets, which is why the pointer
        page owns the base of a pointer record and the Address row goes read
        only on one.
      * Offset and OffsetText raise an access violation outside the offset
        count, and no pcall survives that, so the count is read first and every
        index is checked in Lua.
      * Script reads nothing on a record that is not an Auto Assembler script
        and a write to it is dropped, so the type has to be right first.
      * One unknown element makes a whole Options write fail without a word,
        and the two hide children flags exclude each other only against the set
        the record already has. So an option write rewrites the whole set,
        reads it back, and the change list comes out of what came back.
      * The two freeze direction flags exclude each other. Turning one on turns
        the other off and turning one off puts nothing back, so a write reads
        the partner before and after and hands back whatever moved. Without
        that, undo would write the flag back and leave a record with both of
        them off, which is a state Cheat Engine never puts it in.
      * Setting Active runs a script, and it is quietly ignored when the value
        is already that, when the record is still processing, and when the
        script failed to assemble. Active is always read back.
      * IsReadable is only set when Cheat Engine reads the value, so a row that
        never read one reports every record as unreadable. Reading that row
        reads the value first, which is what the hint tells a person.
      * Writing a read-only member lands raw on that one wrapper and the record
        never hears about it, so nothing here writes one.
      * Colours are BGR integers and the default is a system colour, so a
        record colour is never compared against black.

    Nothing here raises. Every function comes back with a value and a reason, or
    with ok and a reason, and the reason is a sentence a person can read.
]]

local Types = require("Manifold-AddressList-Types")

local Properties = {}
Properties.__index = Properties

--- The two type integers this file has to know by heart. A string decides
--- whether the unicode flag is worth reading and a script decides whether a
--- script may be written at all. Every other type question goes through the
--- type list.
local TYPE_STRING, TYPE_SCRIPT = 6, 11

--- Cheat Engine's own value for a record with no colour of its own, and the
--- other value it accepts and stores as that one.
local DEFAULT_COLOR, DEFAULT_COLOR_ALT = 0x80000008, 0x20000000

--- The two sentences a failed write comes back with. One says Cheat Engine
--- refused the call, the other says it took the call and kept the old value.
local WRITE_FAILED = "Cheat Engine refused the write."
local NOT_ACCEPTED = "Cheat Engine did not accept the value."

--- What a record with no colour of its own reads as, and what a person is told
--- instead of a hash and six digits.
local DEFAULT_COLOR_TEXT = "Default"

--
--- ∑ The one value that means the selected records do not agree.
---   It is a table, so nothing a record can hold is ever equal to it.
--
Properties.MIXED = setmetatable({}, { __tostring = function() return "<mixed>" end })

--- The categories, in the order the inspector shows them.
Properties.Categories = { "Identity", "Location", "Type", "State", "Group", "Advanced" }

--- The option flags in the order Cheat Engine declares them, which is the
--- order a set reads back in. A written set is joined in this same order so a
--- read back can be compared straight.
Properties.Options = {
    "moHideChildren", "moActivateChildrenAsWell", "moDeactivateChildrenAsWell",
    "moRecursiveSetValue", "moAllowManualCollapseAndExpand",
    "moManualExpandCollapse", "moAlwaysHideChildren"
}

local OPTION_KNOWN = {}
for _, name in ipairs(Properties.Options) do OPTION_KNOWN[name] = true end

--- The hotkey actions, with the number Cheat Engine wants on creation and the
--- name it reads back. The label is what a person sees.
Properties.HotkeyActions = {
    { Number = 0, Name = "mrhToggleActivation", Label = "Toggle activation" },
    { Number = 1, Name = "mrhToggleActivationAllowIncrease", Label = "Toggle activation and allow increase" },
    { Number = 2, Name = "mrhToggleActivationAllowDecrease", Label = "Toggle activation and allow decrease" },
    { Number = 3, Name = "mrhActivate", Label = "Activate" },
    { Number = 4, Name = "mrhDeactivate", Label = "Deactivate" },
    { Number = 5, Name = "mrhSetValue", Label = "Set value" },
    { Number = 6, Name = "mrhIncreaseValue", Label = "Increase value" },
    { Number = 7, Name = "mrhDecreaseValue", Label = "Decrease value" }
}

local ACTION_BY_NAME, ACTION_BY_NUMBER = {}, {}
for _, action in ipairs(Properties.HotkeyActions) do
    ACTION_BY_NAME[action.Name] = action
    ACTION_BY_NUMBER[action.Number] = action
end

--
--- ∑ The four hotkey fields this window edits, in the order the page shows
---   them, and the editor each one takes.
---
---   These are the only values a hotkey change's Key may carry, so the window's
---   applier and the Hotkeys page read them from here rather than each keeping
---   a list of their own. The key combination is deliberately not one of them.
---   Changing it means destroying the hotkey and making a new one, which loses
---   the id every change is keyed by, and Cheat Engine leaves the trailing keys
---   of the old combination behind when the new one is shorter.
--
Properties.HotkeyFields = { "Value", "Description", "Action", "OnlyWhileDown" }

Properties.HotkeyFieldKinds = {
    Value = "text", Description = "text", Action = "action", OnlyWhileDown = "bool"
}

--- Whether a change of kind hotkey names a field a hotkey really has.
function Properties.IsHotkeyField(key)
    return Properties.HotkeyFieldKinds[key] ~= nil
end

--------------------------------------------------------
--                   Small helpers                    --
--------------------------------------------------------

local function integer(value)
    local number = tonumber(value)
    if number == nil then return nil end
    return math.tointeger(number) or math.floor(number)
end

local function trim(text)
    return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Drops the file and line a Lua error carries, so a reason reads as a
--- sentence instead of as a stack trace.
local function reasonOf(err)
    local text = tostring(err or "")
    return trim((text:gsub("^.-%.lua:%d+:%s*", "")))
end

local function defaultColor()
    local value = rawget(_G, "clWindowText")
    if type(value) == "number" then return value end
    return DEFAULT_COLOR
end

local function isDefaultColor(value)
    return value == nil or value == defaultColor()
        or value == DEFAULT_COLOR or value == DEFAULT_COLOR_ALT
end

--- One guarded write. Cheat Engine swallows a failed setter, so the caller
--- reads the value back rather than trusting this.
local function write(mr, key, value)
    return pcall(function() mr[key] = value end)
end

--- One guarded write into a sub object such as String or Binary.
local function writeSub(mr, group, key, value)
    return pcall(function() mr[group][key] = value end)
end

local function readSub(ce, mr, group, key)
    local holder = ce:Get(mr, group)
    if holder == nil then return nil end
    return ce:Get(holder, key)
end

--------------------------------------------------------
--             What a property applies to             --
--------------------------------------------------------

local function isGroup(node) return node ~= nil and node.IsGroupHeader == true end

--- A plain group header has no address and no type worth showing. An address
--- group header does, because Cheat Engine gives it both.
local function isPlainGroup(node)
    return isGroup(node) and node.IsAddressGroupHeader ~= true
end

local function isScript(node) return node ~= nil and node.Type == TYPE_SCRIPT end

local function isPointer(node)
    return node ~= nil and (tonumber(node.OffsetCount) or 0) > 0
end

--- A record that holds a value, which is everything that is neither a header
--- nor a script.
local function isValue(node)
    return node ~= nil and not isGroup(node) and not isScript(node)
end

local function typeIs(node, key)
    local entry = Types.For(node)
    return entry ~= nil and entry.Key == key
end

--- The types Cheat Engine shows as hexadecimal or as signed. Both settings
--- only mean something on a whole number.
local INTEGER_KEYS = { Byte = true, Word = true, Dword = true, Qword = true }

local function isInteger(node)
    local entry = Types.For(node)
    return entry ~= nil and INTEGER_KEYS[entry.Key] == true
end

--------------------------------------------------------
--           Reading and writing one field            --
--------------------------------------------------------

local function boolGet(key)
    return function(props, mr) return props.CE:Get(mr, key) == true end
end

local function textGet(key)
    return function(props, mr)
        local value = props.CE:Get(mr, key)
        if value == nil then return "" end
        return tostring(value)
    end
end

local function numberGet(key)
    return function(props, mr) return integer(props.CE:Get(mr, key)) end
end

local function subGet(group, key)
    return function(props, mr) return readSub(props.CE, mr, group, key) end
end

local function subBoolGet(group, key)
    return function(props, mr) return readSub(props.CE, mr, group, key) == true end
end

local function subNumberGet(group, key)
    return function(props, mr) return integer(readSub(props.CE, mr, group, key)) end
end

--- Writes one member and reads it back, which is the only way to tell a write
--- Cheat Engine took from one it dropped.
local function simpleSet(key, coerce)
    return function(props, mr, value)
        local wanted = value
        if coerce ~= nil then wanted = coerce(value) end
        if not write(mr, key, wanted) then return false, WRITE_FAILED end
        if props.CE:Get(mr, key) ~= wanted then return false, NOT_ACCEPTED end
        return true
    end
end

local function subSet(group, key, coerce)
    return function(props, mr, value)
        local wanted = value
        if coerce ~= nil then wanted = coerce(value) end
        if not writeSub(mr, group, key, wanted) then return false, WRITE_FAILED end
        if readSub(props.CE, mr, group, key) ~= wanted then return false, NOT_ACCEPTED end
        return true
    end
end

local function asBool(value) return value == true end
local function asText(value) return tostring(value == nil and "" or value) end
local function asNumber(value) return integer(value) or 0 end

local function readOnlySet(props, mr, value)
    return false, "This value cannot be edited here."
end

--
--- ∑ Writes one of the two freeze direction flags and reports what the other
---   one did, because Cheat Engine keeps at least one of the pair off.
---
---   Cheat Engine's own setter turns the partner off whenever this flag goes
---   on, and turning this flag off again puts nothing back. So the partner is
---   read before the write and again after it, and a move comes back as an
---   extra change. Undo replays those in reverse, which puts the pair back the
---   way it was instead of leaving both of them off.
--- @param key string # The flag this row writes.
--- @param partner string # The flag Cheat Engine turns off with it.
--- @param partnerLabel string # What the partner is called in the sentence.
--- @return function
--
local function directionSet(key, partner, partnerLabel)
    return function(props, mr, value)
        local ce = props.CE
        local wanted = value == true
        local before = ce:Get(mr, partner) == true
        if not write(mr, key, wanted) then return false, WRITE_FAILED end
        if (ce:Get(mr, key) == true) ~= wanted then return false, NOT_ACCEPTED end
        local after = ce:Get(mr, partner) == true
        if after == before then return true end
        return true, nil, {
            Message = "Cheat Engine also changed the " .. partnerLabel .. " flag.",
            Changes = { {
                ID = integer(ce:Get(mr, "ID")), Key = partner, Old = before, New = after
            } }
        }
    end
end

--------------------------------------------------------
--                  The option rows                   --
--------------------------------------------------------

--
--- ∑ Turns the set string Cheat Engine reads back into a set of flag names.
--- @param text string|nil
--- @return table
--
function Properties.ParseOptions(text)
    local set = {}
    if type(text) ~= "string" then return set end
    for name in text:gmatch("[%a%d_]+") do
        if OPTION_KNOWN[name] then set[name] = true end
    end
    return set
end

--
--- ∑ Joins a set of flag names into the string the setter takes, in the order
---   Cheat Engine declares them, so a read back compares straight.
--- @param set table|nil
--- @return string
--
function Properties.JoinOptions(set)
    local parts = {}
    for _, name in ipairs(Properties.Options) do
        if set ~= nil and set[name] then parts[#parts + 1] = name end
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

--- The flag one option row carries.
local function optionFlag(key) return key:match("^Options%.(.+)$") end

local function optionGet(key)
    local flag = optionFlag(key)
    return function(props, mr)
        return Properties.ParseOptions(props.CE:Get(mr, "Options"))[flag] == true
    end
end

--
--- ∑ Writes one option flag by rewriting the whole set and reading it back.
---
---   The two hide children flags drop each other only when the record already
---   holds the other one, so what a write does to the rest of the set cannot be
---   worked out beforehand. Whatever else moved comes back as extra changes, so
---   undo can put the whole set back the way it was.
--- @param key string
--- @return function
--
local function optionSet(key)
    local flag = optionFlag(key)
    return function(props, mr, value)
        local ce = props.CE
        local before = Properties.ParseOptions(ce:Get(mr, "Options"))
        local wanted = {}
        for name in pairs(before) do wanted[name] = true end
        wanted[flag] = value == true or nil
        if not write(mr, "Options", Properties.JoinOptions(wanted)) then
            return false, WRITE_FAILED
        end
        local after = Properties.ParseOptions(ce:Get(mr, "Options"))
        if (after[flag] == true) ~= (value == true) then return false, NOT_ACCEPTED end
        local id = integer(ce:Get(mr, "ID"))
        local changes, names = {}, {}
        for _, name in ipairs(Properties.Options) do
            if name ~= flag and (before[name] == true) ~= (after[name] == true) then
                changes[#changes + 1] = {
                    ID = id, Key = "Options." .. name,
                    Old = before[name] == true, New = after[name] == true
                }
                names[#names + 1] = name
            end
        end
        if #changes == 0 then return true end
        return true, nil, {
            Message = "Cheat Engine also changed " .. table.concat(names, " and ") .. ".",
            Changes = changes
        }
    end
end

--------------------------------------------------------
--                       Colour                       --
--------------------------------------------------------

--
--- ∑ The hash and six digits form of a Cheat Engine colour.
---
---   Cheat Engine stores a colour with the red channel in the low byte, and
---   people read colours the other way round, so the bytes are swapped here and
---   nowhere else.
--- @param bgr number
--- @return string
--
function Properties.BgrToHex(bgr)
    local value = integer(bgr) or 0
    value = value & 0xFFFFFF
    return string.format("#%02X%02X%02X", value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF)
end

--
--- ∑ The Cheat Engine colour behind what a person typed.
--- @param text string|number
--- @return number|nil
--- @return string|nil
--
function Properties.HexToBgr(text)
    if type(text) == "number" then return integer(text) end
    if type(text) ~= "string" then return nil, "Type a colour as hash RRGGBB." end
    local clean = trim(text)
    if clean == "" or clean:lower() == "default" then return defaultColor() end
    local digits = clean:match("^#(%x%x%x%x%x%x)$") or clean:match("^(%x%x%x%x%x%x)$")
    if digits == nil then return nil, "Type a colour as hash RRGGBB." end
    local red = tonumber(digits:sub(1, 2), 16)
    local green = tonumber(digits:sub(3, 4), 16)
    local blue = tonumber(digits:sub(5, 6), 16)
    return (blue << 16) | (green << 8) | red
end

--------------------------------------------------------
--            Parsing what a person typed             --
--------------------------------------------------------

--- Decimal, or hexadecimal behind 0x or a dollar sign, which are the two forms
--- Cheat Engine itself takes.
local function parseNumber(text)
    if type(text) == "number" then return integer(text) end
    if type(text) ~= "string" then return nil, "Type a number." end
    local clean = trim(text)
    if clean == "" then return nil, "Type a number." end
    local hex = clean:match("^0[xX](%x+)$") or clean:match("^%$(%x+)$")
    if hex ~= nil then return tonumber(hex, 16) end
    local number = tonumber(clean)
    if number == nil then return nil, "'" .. clean .. "' is not a number." end
    return integer(number)
end

local TRUE_WORDS = { ["true"] = true, ["1"] = true, yes = true, on = true }
local FALSE_WORDS = { ["false"] = true, ["0"] = true, no = true, off = true }

local function parseBool(text)
    if type(text) == "boolean" then return text end
    local clean = trim(tostring(text)):lower()
    if TRUE_WORDS[clean] then return true end
    if FALSE_WORDS[clean] then return false end
    return nil, "Type yes or no."
end

--------------------------------------------------------
--                     The schema                     --
--------------------------------------------------------

--
--- ∑ Every property, in the order the inspector lists them.
---
---   Editor says which editor a row takes. Applies says whether the row is
---   shown at all for a record. ReadOnlyFor says whether it is shown without an
---   editor, which is how the base of a pointer stays owned by the pointer page
---   alone. Undoable says whether the commit funnel may hand the change to the
---   journal. Prime is a read that has to run before the row's own read means
---   anything, which only IsReadable needs.
--
Properties.List = {
    -- Identity ---------------------------------------------------------------
    {
        Key = "ID", Category = "Identity", Label = "ID", Editor = "readonly",
        Bulk = false, Undoable = false,
        Hint = "The number Cheat Engine gives the record. Everything in this window is keyed by it.",
        Get = numberGet("ID"), Set = readOnlySet
    },
    {
        Key = "Description", Category = "Identity", Label = "Description", Editor = "text",
        Undoable = true, Bulk = true,
        Hint = "The name shown in the list. Drop-down links and value maths look records up by it.",
        Get = textGet("Description"), Set = simpleSet("Description", asText)
    },
    {
        Key = "Color", Category = "Identity", Label = "Colour", Editor = "color",
        Undoable = true, Bulk = true,
        Hint = "The colour of the row in Cheat Engine and here. Default follows the theme.",
        Get = numberGet("Color"),
        Format = function(props, value)
            if isDefaultColor(value) then return DEFAULT_COLOR_TEXT end
            return Properties.BgrToHex(value)
        end,
        Parse = function(props, text) return Properties.HexToBgr(text) end,
        Set = function(props, mr, value)
            local wanted = value
            if type(wanted) == "string" then
                local parsed, err = Properties.HexToBgr(wanted)
                if parsed == nil then return false, err end
                wanted = parsed
            end
            wanted = integer(wanted)
            if wanted == nil then return false, "Type a colour as hash RRGGBB." end
            if not write(mr, "Color", wanted) then return false, WRITE_FAILED end
            local back = integer(props.CE:Get(mr, "Color"))
            -- Cheat Engine stores its own two ways of saying no colour as one,
            -- so both count as the value that was asked for.
            if back == wanted then return true end
            if isDefaultColor(wanted) and isDefaultColor(back) then return true end
            return false, NOT_ACCEPTED
        end
    },
    {
        Key = "DontSave", Category = "Identity", Label = "Do not save", Editor = "bool",
        Undoable = true, Bulk = true,
        Hint = "The record and its children are left out when the Cheat Table is saved.",
        Get = boolGet("DontSave"), Set = simpleSet("DontSave", asBool)
    },

    -- Location ---------------------------------------------------------------
    {
        Key = "Address", Category = "Location", Label = "Address", Editor = "text",
        Undoable = true, Bulk = true,
        Applies = function(node) return not isPlainGroup(node) end,
        ReadOnlyFor = isPointer,
        ReadOnlyHint = "Edit the base on the Pointer page (Ctrl+P).",
        Hint = "The address, a module name plus an offset, or a symbol.",
        Get = textGet("Address"),
        Set = function(props, mr, value, node)
            if isPointer(node) then
                return false, "Edit the base on the Pointer page (Ctrl+P)."
            end
            local text = trim(tostring(value == nil and "" or value))
            if text == "" then return false, "Type an address." end
            if not write(mr, "Address", text) then return false, WRITE_FAILED end
            -- Cheat Engine tidies an address up as it interprets it, so the
            -- text that reads back is allowed to differ from the text typed.
            if props.CE:Get(mr, "Address") == nil then return false, NOT_ACCEPTED end
            return true
        end
    },
    {
        Key = "AddressString", Category = "Location", Label = "Shown as", Editor = "readonly",
        Undoable = false, Bulk = true,
        Applies = function(node) return not isPlainGroup(node) end,
        Hint = "The address exactly as Cheat Engine draws it in the list.",
        Get = textGet("AddressString"), Set = readOnlySet
    },
    {
        Key = "CurrentAddress", Category = "Location", Label = "Resolves to", Editor = "readonly",
        Undoable = false, Bulk = true,
        Applies = function(node) return not isPlainGroup(node) end,
        Hint = "Where the address points right now. Cheat Engine reads the pointer chain again for this.",
        Get = numberGet("CurrentAddress"),
        Format = function(props, value)
            local number = integer(value)
            if number == nil or number == 0 then return "??" end
            return string.format("%X", number)
        end,
        Set = readOnlySet
    },
    {
        Key = "OffsetCount", Category = "Location", Label = "Offsets", Editor = "readonly",
        Undoable = false, Bulk = true,
        Applies = function(node) return not isPlainGroup(node) end,
        Hint = "How many levels the pointer chain has. Edit them on the Pointer page.",
        Get = numberGet("OffsetCount"),
        Format = function(props, value)
            local number = integer(value) or 0
            if number == 0 then return "Not a pointer" end
            if number == 1 then return "1 level, edit on the Pointer page" end
            return number .. " levels, edit on the Pointer page"
        end,
        Set = readOnlySet
    },

    -- Type -------------------------------------------------------------------
    {
        Key = "VarType", Category = "Type", Label = "Type", Editor = "enum",
        Undoable = true, Bulk = true,
        Applies = function(node) return not isPlainGroup(node) end,
        Hint = "What the bytes at the address mean. An active record is deactivated first.",
        Choices = function(props)
            local out = {}
            for _, entry in ipairs(Types.List) do
                out[#out + 1] = { Value = entry.VarType, Label = entry.Label }
            end
            return out
        end,
        Get = textGet("VarType"),
        Format = function(props, value)
            local entry = Types.ByVarType[value]
            if entry == nil then return tostring(value or "") end
            return entry.Label
        end,
        Parse = function(props, text)
            local entry = Types.Parse(text)
            if entry == nil then return nil, "That is not a type this window can set." end
            return entry.VarType
        end,
        Set = function(props, mr, value, node)
            local entry = value
            if type(entry) == "string" then
                entry = Types.ByVarType[entry] or Types.Parse(entry)
            elseif type(entry) == "number" then
                entry = Types.ByType[entry]
            end
            if type(entry) ~= "table" or entry.Type == nil then
                return false, "That is not a type this window can set."
            end
            if isPlainGroup(node) then return false, "A group header has no type." end
            local note = nil
            if props.CE:Get(mr, "Active") == true then
                if isScript(node) then
                    return false, "The script is active. Deactivate it before changing its type."
                end
                write(mr, "Active", false)
                if props.CE:Get(mr, "Active") == true then
                    return false, "The record is active and Cheat Engine would not deactivate it."
                end
                note = { Message = "The record was deactivated first, the way Cheat Engine's own type dialog does." }
            end
            -- The integer goes in and the name comes back, because a string
            -- written to Type would quietly become a byte.
            if not write(mr, "Type", entry.Type) then return false, WRITE_FAILED end
            if props.CE:Get(mr, "VarType") ~= entry.VarType then return false, NOT_ACCEPTED end
            return true, nil, note
        end
    },
    {
        Key = "String.Size", Category = "Type", Label = "Length", Editor = "number",
        Undoable = true, Bulk = true, Min = 1,
        Applies = function(node) return typeIs(node, "String") end,
        Hint = "How many characters Cheat Engine reads.",
        Get = subNumberGet("String", "Size"), Set = subSet("String", "Size", asNumber)
    },
    {
        Key = "String.Unicode", Category = "Type", Label = "Unicode", Editor = "bool",
        Undoable = true, Bulk = true,
        Applies = function(node) return typeIs(node, "String") end,
        Hint = "Two bytes per character. Turning this on turns the code page off.",
        Get = subBoolGet("String", "Unicode"),
        Set = function(props, mr, value)
            local before = readSub(props.CE, mr, "String", "Codepage") == true
            if not writeSub(mr, "String", "Unicode", value == true) then
                return false, WRITE_FAILED
            end
            if (readSub(props.CE, mr, "String", "Unicode") == true) ~= (value == true) then
                return false, NOT_ACCEPTED
            end
            local after = readSub(props.CE, mr, "String", "Codepage") == true
            if after == before then return true end
            return true, nil, {
                Message = "Cheat Engine also changed the code page flag.",
                Changes = { {
                    ID = integer(props.CE:Get(mr, "ID")), Key = "String.Codepage",
                    Old = before, New = after
                } }
            }
        end
    },
    {
        Key = "String.Codepage", Category = "Type", Label = "Codepage", Editor = "bool",
        Undoable = true, Bulk = true,
        Applies = function(node) return typeIs(node, "String") end,
        Hint = "Read the text through the process code page. Turning this on turns unicode off.",
        Get = subBoolGet("String", "Codepage"),
        Set = function(props, mr, value)
            local before = readSub(props.CE, mr, "String", "Unicode") == true
            if not writeSub(mr, "String", "Codepage", value == true) then
                return false, WRITE_FAILED
            end
            if (readSub(props.CE, mr, "String", "Codepage") == true) ~= (value == true) then
                return false, NOT_ACCEPTED
            end
            local after = readSub(props.CE, mr, "String", "Unicode") == true
            if after == before then return true end
            return true, nil, {
                Message = "Cheat Engine also changed the unicode flag.",
                Changes = { {
                    ID = integer(props.CE:Get(mr, "ID")), Key = "String.Unicode",
                    Old = before, New = after
                } }
            }
        end
    },
    {
        Key = "Binary.Startbit", Category = "Type", Label = "Start bit", Editor = "number",
        Undoable = true, Bulk = true, Min = 0, Max = 7,
        Applies = function(node) return typeIs(node, "Binary") end,
        Hint = "The first bit of the field, counted from the low bit of the byte.",
        Get = subNumberGet("Binary", "Startbit"), Set = subSet("Binary", "Startbit", asNumber)
    },
    {
        Key = "Binary.Size", Category = "Type", Label = "Bit count", Editor = "number",
        Undoable = true, Bulk = true, Min = 1,
        Applies = function(node) return typeIs(node, "Binary") end,
        Hint = "How many bits the field is wide.",
        Get = subNumberGet("Binary", "Size"), Set = subSet("Binary", "Size", asNumber)
    },
    {
        Key = "Aob.Size", Category = "Type", Label = "Byte count", Editor = "number",
        Undoable = true, Bulk = true, Min = 1,
        Applies = function(node) return typeIs(node, "ByteArray") end,
        Hint = "How many bytes the array holds.",
        Get = subNumberGet("Aob", "Size"), Set = subSet("Aob", "Size", asNumber)
    },
    {
        Key = "CustomTypeName", Category = "Type", Label = "Custom type", Editor = "text",
        Undoable = true, Bulk = true,
        Applies = function(node) return typeIs(node, "Custom") end,
        Hint = "The name of the custom type, exactly as Cheat Engine registered it.",
        Get = textGet("CustomTypeName"), Set = simpleSet("CustomTypeName", asText)
    },
    {
        Key = "ShowAsHex", Category = "Type", Label = "Hexadecimal", Editor = "bool",
        Undoable = true, Bulk = true,
        Applies = function(node) return isInteger(node) or typeIs(node, "Binary") end,
        Hint = "Show and take the value as hexadecimal.",
        Get = boolGet("ShowAsHex"), Set = simpleSet("ShowAsHex", asBool)
    },
    {
        Key = "ShowAsSigned", Category = "Type", Label = "Signed", Editor = "bool",
        Undoable = true, Bulk = true,
        Applies = isInteger,
        Hint = "Read the high bit as a minus sign rather than as a large number.",
        Get = boolGet("ShowAsSigned"), Set = simpleSet("ShowAsSigned", asBool)
    },

    -- State ------------------------------------------------------------------
    {
        Key = "Active", Category = "State", Label = "Active", Editor = "bool",
        Undoable = false, Bulk = true, Danger = "Runs the script",
        DangerFor = function(node)
            if isScript(node) then return "Runs the script" end
            return "Freezes the value"
        end,
        Hint = "Activating an Auto Assembler record runs its script. Undo cannot take that back.",
        Get = boolGet("Active"),
        Set = function(props, mr, value)
            local ce, wanted = props.CE, value == true
            if ce:Get(mr, "AsyncProcessing") == true then
                return false, "The script is still running. Wait for it to finish."
            end
            if not write(mr, "Active", wanted) then return false, WRITE_FAILED end
            if (ce:Get(mr, "Active") == true) == wanted then return true end
            if ce:Get(mr, "AsyncProcessing") == true then
                return true, nil, {
                    Message = "The script runs in the background. The record follows when it finishes.",
                    Pending = true
                }
            end
            if ce:Get(mr, "LastAAExecutionFailed") == true then
                local why = ce:Get(mr, "LastAAExecutionFailedReason")
                if type(why) == "string" and why ~= "" and why ~= "Unknown" then
                    return false, "The script failed. " .. why
                end
                return false, "The script failed."
            end
            return false, NOT_ACCEPTED
        end
    },
    {
        Key = "Value", Category = "State", Label = "Value", Editor = "text",
        Undoable = false, Bulk = true, Danger = "Writes process memory",
        Applies = isValue,
        Hint = "Writes straight into the process. Undo cannot take that back.",
        Get = textGet("Value"),
        Set = function(props, mr, value)
            local text = tostring(value == nil and "" or value)
            local ok, err = pcall(function() mr.Value = text end)
            if not ok then return false, "Cheat Engine refused the value. " .. reasonOf(err) end
            return true
        end
    },
    {
        Key = "AllowIncrease", Category = "State", Label = "Allow increase", Editor = "bool",
        Undoable = true, Bulk = true,
        Applies = function(node) return isValue(node) end,
        Hint = "While frozen, let the value grow but never shrink. Turning this on turns allow decrease off.",
        Get = boolGet("AllowIncrease"),
        Set = directionSet("AllowIncrease", "AllowDecrease", "allow decrease")
    },
    {
        Key = "AllowDecrease", Category = "State", Label = "Allow decrease", Editor = "bool",
        Undoable = true, Bulk = true,
        Applies = function(node) return isValue(node) end,
        Hint = "While frozen, let the value shrink but never grow. Turning this on turns allow increase off.",
        Get = boolGet("AllowDecrease"),
        Set = directionSet("AllowDecrease", "AllowIncrease", "allow increase")
    },
    {
        Key = "Async", Category = "State", Label = "Async", Editor = "bool",
        Undoable = true, Bulk = true,
        Applies = isScript,
        Hint = "Run the script on its own thread. Activation returns before the script is done.",
        Get = boolGet("Async"), Set = simpleSet("Async", asBool)
    },

    -- Group ------------------------------------------------------------------
    {
        Key = "IsGroupHeader", Category = "Group", Label = "Group header", Editor = "bool",
        Undoable = true, Bulk = true,
        Hint = "A header holds other records and shows no value of its own.",
        Get = boolGet("IsGroupHeader"), Set = simpleSet("IsGroupHeader", asBool)
    },
    {
        Key = "Options.moHideChildren", Category = "Group", Label = "Hide children while inactive",
        Editor = "bool", Undoable = true, Bulk = true,
        Hint = "Collapse the children while the record is off. Cheat Engine drops always hide children for this.",
        Get = optionGet("Options.moHideChildren"), Set = optionSet("Options.moHideChildren")
    },
    {
        Key = "Options.moAlwaysHideChildren", Category = "Group", Label = "Always hide children",
        Editor = "bool", Undoable = true, Bulk = true,
        Hint = "Keep the children collapsed whatever the record does. This drops hide children while inactive.",
        Get = optionGet("Options.moAlwaysHideChildren"), Set = optionSet("Options.moAlwaysHideChildren")
    },
    {
        Key = "Options.moActivateChildrenAsWell", Category = "Group", Label = "Activate children too",
        Editor = "bool", Undoable = true, Bulk = true,
        Hint = "Activating this record activates every child after it.",
        Get = optionGet("Options.moActivateChildrenAsWell"), Set = optionSet("Options.moActivateChildrenAsWell")
    },
    {
        Key = "Options.moDeactivateChildrenAsWell", Category = "Group", Label = "Deactivate children too",
        Editor = "bool", Undoable = true, Bulk = true,
        Hint = "Deactivating this record deactivates every child first and waits for them.",
        Get = optionGet("Options.moDeactivateChildrenAsWell"), Set = optionSet("Options.moDeactivateChildrenAsWell")
    },
    {
        Key = "Options.moRecursiveSetValue", Category = "Group", Label = "Set value on children",
        Editor = "bool", Undoable = true, Bulk = true,
        Hint = "Writing a value here writes it to every child as well.",
        Get = optionGet("Options.moRecursiveSetValue"), Set = optionSet("Options.moRecursiveSetValue")
    },
    {
        Key = "Options.moAllowManualCollapseAndExpand", Category = "Group",
        Label = "Allow manual collapse", Editor = "bool", Undoable = true, Bulk = true,
        Hint = "Let a person collapse and expand the record even while it hides its children.",
        Get = optionGet("Options.moAllowManualCollapseAndExpand"),
        Set = optionSet("Options.moAllowManualCollapseAndExpand")
    },
    {
        Key = "Options.moManualExpandCollapse", Category = "Group",
        Label = "Manual expand and collapse", Editor = "bool", Undoable = true, Bulk = true,
        Hint = "Cheat Engine leaves the collapsed state alone and only a person changes it.",
        Get = optionGet("Options.moManualExpandCollapse"),
        Set = optionSet("Options.moManualExpandCollapse")
    },

    -- Advanced ---------------------------------------------------------------
    {
        Key = "HotkeyCount", Category = "Advanced", Label = "Hotkeys", Editor = "readonly",
        Undoable = false, Bulk = true,
        Hint = "How many hotkeys the record carries. The Hotkeys page lists them.",
        Get = numberGet("HotkeyCount"), Set = readOnlySet
    },
    -- The two drop-down rows have no Applies, so they show on every record, a
    -- group header included. A header can carry a list and can be linked, and
    -- a header that holds a list is a common place for other records to link
    -- theirs to, even though its own Value reads empty.
    {
        Key = "DropDownCount", Category = "Advanced", Label = "Drop-down entries", Editor = "readonly",
        Undoable = false, Bulk = true,
        Hint = "How many entries the drop-down list holds, through the link when it has one.",
        Get = numberGet("DropDownCount"), Set = readOnlySet
    },
    {
        Key = "DropDownLinkedMemrec", Category = "Advanced", Label = "Drop-down linked to",
        Editor = "readonly", Undoable = false, Bulk = true,
        Hint = "The description of the record this one borrows its drop-down list from.",
        Get = textGet("DropDownLinkedMemrec"), Set = readOnlySet
    },
    {
        Key = "LastAAExecutionFailedReason", Category = "Advanced", Label = "Last script error",
        Editor = "readonly", Undoable = false, Bulk = true,
        Applies = isScript,
        Hint = "Why the last run of this script failed. Cheat Engine often only says Unknown.",
        Get = textGet("LastAAExecutionFailedReason"), Set = readOnlySet
    },
    {
        Key = "IsReadable", Category = "Advanced", Label = "Readable", Editor = "readonly",
        Undoable = false, Bulk = true,
        Applies = isValue,
        Hint = "Cheat Engine sets this when it reads the value.",
        -- Cheat Engine only touches this flag inside its own value read, so a
        -- record nobody read yet reports as unreadable whatever the address
        -- does. Reading the value first is the only way to make the row true.
        Prime = function(props, mr) return props.CE:Get(mr, "Value") end,
        Get = boolGet("IsReadable"), Set = readOnlySet
    }
}

Properties.ByKey = {}
for _, def in ipairs(Properties.List) do Properties.ByKey[def.Key] = def end

--------------------------------------------------------
--                     The class                      --
--------------------------------------------------------

--
--- ∑ One Properties service per window. It holds no record and no state, so a
---   page may keep it for as long as it likes.
--- @param services table # CE, Types and Log.
--- @return table
--
function Properties:New(services)
    return setmetatable({
        CE = services and services.CE,
        Types = (services and services.Types) or Types,
        Log = services and services.Log
    }, Properties)
end

--
--- ∑ The few fields the schema asks about, read off a record.
---
---   A page usually has a Records node already and passes it. This is for the
---   callers that only have the record, and it reads seven members rather than
---   the twenty a full detail pass reads.
--- @param mr userdata
--- @return table
--
function Properties:NodeOf(mr)
    local ce = self.CE
    if mr == nil or ce == nil then return {} end
    local node = {
        ID = integer(ce:Get(mr, "ID")),
        Type = integer(ce:Get(mr, "Type")),
        VarType = ce:Get(mr, "VarType"),
        IsGroupHeader = ce:Get(mr, "IsGroupHeader") == true,
        IsAddressGroupHeader = ce:Get(mr, "IsAddressGroupHeader") == true,
        OffsetCount = integer(ce:Get(mr, "OffsetCount")) or 0,
        Active = ce:Get(mr, "Active") == true,
        Children = {}
    }
    if node.Type == TYPE_STRING then
        node.Unicode = readSub(ce, mr, "String", "Unicode") == true
    end
    return node
end

--
--- ∑ Whether a property means anything for one record.
--- @param def table
--- @param mr userdata|nil
--- @param node table|nil # A Records node, read off the record when not given.
--- @return boolean
--
function Properties:Applies(def, mr, node)
    if def == nil then return false end
    if def.Applies == nil then return true end
    local subject = node
    if subject == nil then subject = self:NodeOf(mr) end
    local ok, result = pcall(def.Applies, subject)
    return ok and result == true
end

--- Whether the row is shown without an editor. The base of a pointer is the
--- one case, because the pointer page owns it.
function Properties:ReadOnly(def, node)
    if def == nil then return true end
    if def.Editor == "readonly" then return true end
    if def.ReadOnlyFor == nil then return false end
    local ok, result = pcall(def.ReadOnlyFor, node)
    return ok and result == true
end

--- The sentence shown while the row is hovered, which says why a row cannot be
--- edited when that is the interesting part.
function Properties:HintFor(def, node)
    if def == nil then return "" end
    if def.ReadOnlyHint ~= nil and def.ReadOnlyFor ~= nil then
        local ok, result = pcall(def.ReadOnlyFor, node)
        if ok and result == true then return def.ReadOnlyHint end
    end
    return def.Hint or ""
end

--- What the row warns about for this record, which is not the same for a
--- script as for a plain value.
function Properties:DangerFor(def, node)
    if def == nil then return nil end
    if def.DangerFor ~= nil then
        local ok, result = pcall(def.DangerFor, node)
        if ok then return result end
    end
    return def.Danger
end

--------------------------------------------------------
--                      Reading                       --
--------------------------------------------------------

--
--- ∑ One property off one record.
---
---   A definition may carry a Prime, which is a read that has to happen before
---   the real one means anything. IsReadable is the only one, because Cheat
---   Engine sets that flag inside its own value read and nowhere else, so a row
---   that never read a value would call every record unreadable.
--- @param mr userdata
--- @param key string
--- @return any # The value, or nil and a reason.
--- @return string|nil
--
function Properties:Read(mr, key)
    local def = Properties.ByKey[key]
    if def == nil then return nil, "There is no property called " .. tostring(key) .. "." end
    if mr == nil then return nil, "The record is gone." end
    if def.Prime ~= nil then pcall(def.Prime, self, mr) end
    local ok, value = pcall(def.Get, self, mr)
    if not ok then return nil, "Cheat Engine did not return the value." end
    return value
end

--
--- ∑ The value every record in the selection agrees on.
---
---   The nodes list is worth passing. The snapshot already carries everything
---   Applies asks about, so a page that hands the nodes over turns eight
---   Cheat Engine reads per record and per property into none.
--- @param mrs table # A list of memory records.
--- @param key string
--- @param nodes table|nil # The Records node of each record, in the same order.
--- @return any # The value, the MIXED sentinel, or nil when the property does
---         not apply to every record.
--
function Properties:Common(mrs, key, nodes)
    local def = Properties.ByKey[key]
    if def == nil or type(mrs) ~= "table" or #mrs == 0 then return nil end
    local value, first = nil, true
    for index, mr in ipairs(mrs) do
        if not self:Applies(def, mr, nodes and nodes[index]) then return nil end
        local current = self:Read(mr, key)
        if first then value, first = current, false
        elseif current ~= value then return Properties.MIXED end
    end
    return value
end

--------------------------------------------------------
--                      Writing                       --
--------------------------------------------------------

--
--- ∑ Writes one property and reports what Cheat Engine really did.
---
---   The third return is a note. It carries a sentence for the status line and,
---   when Cheat Engine moved something else of its own accord, the extra
---   changes that undo needs to put the record back.
--- @param mr userdata
--- @param key string
--- @param value any
--- @return boolean
--- @return string|nil # The reason it did not happen.
--- @return table|nil # Message, Changes and Pending.
--
function Properties:Write(mr, key, value)
    local def = Properties.ByKey[key]
    if def == nil then return false, "There is no property called " .. tostring(key) .. "." end
    if mr == nil then return false, "The record is gone." end
    local node = self:NodeOf(mr)
    if not self:Applies(def, mr, node) then
        return false, "That property does not apply to this record."
    end
    if self:ReadOnly(def, node) then
        return false, def.ReadOnlyHint or "This value cannot be edited here."
    end
    local ok, result, reason, note = pcall(def.Set, self, mr, value, node)
    if not ok then return false, reasonOf(result) end
    if result ~= true then return false, reason or NOT_ACCEPTED end
    return true, nil, note
end

--
--- ∑ What writing one value to a whole selection would change.
---
---   Only the records whose value really differs come back as changes, so a
---   bulk edit of fourteen records where three already agree pushes eleven
---   changes and undo puts back exactly those eleven.
--- @param mrs table
--- @param key string
--- @param value any
--- @param nodes table|nil # The Records node of each record, in the same order.
--- @return table # Changes of ID, Key, Old and New.
--- @return table # Skips of ID and Reason.
--
function Properties:Plan(mrs, key, value, nodes)
    local changes, skipped = {}, {}
    local def = Properties.ByKey[key]
    if def == nil or type(mrs) ~= "table" then return changes, skipped end
    local many = #mrs > 1
    for index, mr in ipairs(mrs) do
        local node = (nodes and nodes[index]) or self:NodeOf(mr)
        local id = node.ID or integer(self.CE and self.CE:Get(mr, "ID"))
        if many and def.Bulk == false then
            skipped[#skipped + 1] =
                { ID = id, Reason = "This property is changed on one record at a time." }
        elseif not self:Applies(def, mr, node) then
            skipped[#skipped + 1] =
                { ID = id, Reason = "That property does not apply to this record." }
        elseif self:ReadOnly(def, node) then
            skipped[#skipped + 1] =
                { ID = id, Reason = def.ReadOnlyHint or "This value cannot be edited here." }
        else
            local old, err = self:Read(mr, key)
            if err ~= nil then
                skipped[#skipped + 1] = { ID = id, Reason = err }
            elseif old ~= value then
                changes[#changes + 1] = { ID = id, Key = key, Old = old, New = value }
            end
        end
    end
    return changes, skipped
end

--------------------------------------------------------
--                Text in and text out                --
--------------------------------------------------------

--
--- ∑ The display text of one value.
--- @param key string
--- @param value any
--- @return string
--
function Properties:Format(key, value)
    if value == Properties.MIXED then return "<mixed>" end
    local def = Properties.ByKey[key]
    if def ~= nil and def.Format ~= nil then
        local ok, text = pcall(def.Format, self, value)
        if ok and text ~= nil then return tostring(text) end
    end
    if value == nil then return "" end
    if type(value) == "boolean" then return value and "Yes" or "No" end
    return tostring(value)
end

--
--- ∑ The value behind what a person typed, or a sentence saying why it is not
---   one.
--- @param key string
--- @param text string
--- @return any
--- @return string|nil
--
function Properties:Parse(key, text)
    local def = Properties.ByKey[key]
    if def == nil then return nil, "There is no property called " .. tostring(key) .. "." end
    if def.Editor == "readonly" then return nil, "This value cannot be edited here." end
    if def.Parse ~= nil then
        local ok, value, err = pcall(def.Parse, self, text)
        if not ok then return nil, "That is not a value this property takes." end
        if value == nil then return nil, err or "That is not a value this property takes." end
        return value
    end
    if def.Editor == "bool" then return parseBool(text) end
    if def.Editor == "number" then
        local number, err = parseNumber(text)
        if number == nil then return nil, err end
        if def.Min ~= nil and number < def.Min then
            return nil, "The smallest value is " .. def.Min .. "."
        end
        if def.Max ~= nil and number > def.Max then
            return nil, "The largest value is " .. def.Max .. "."
        end
        return number
    end
    if def.Editor == "enum" then
        local wanted = trim(tostring(text)):lower()
        for _, choice in ipairs(self:Choices(def)) do
            if tostring(choice.Value):lower() == wanted
                or tostring(choice.Label):lower() == wanted then
                return choice.Value
            end
        end
        return nil, "That is not one of the choices."
    end
    if text == nil then return "" end
    return tostring(text)
end

--- The choices of an enum row, or an empty list for every other row.
function Properties:Choices(def)
    if def == nil or def.Choices == nil then return {} end
    local ok, list = pcall(def.Choices, self)
    if ok and type(list) == "table" then return list end
    return {}
end

--------------------------------------------------------
--                 The pointer chain                  --
--------------------------------------------------------

--- One offset text, bounds checked in Lua because Cheat Engine faults on an
--- index it does not have and no pcall catches that.
local function offsetTextAt(ce, mr, index, count)
    if index < 0 or index >= count then return nil end
    local holder = ce:Get(mr, "OffsetText")
    if holder == nil then return nil end
    return ce:Get(holder, index)
end

--
--- ∑ The pointer chain of one record, in Cheat Engine's own order.
---
---   Offsets one is Cheat Engine's Offset zero, which is the offset applied
---   LAST. The pointer page turns that round for the screen, because a person
---   reads a chain in the order it is walked.
--- @param mr userdata
--- @return table # Base and Offsets.
--
function Properties:ReadPointer(mr)
    local out = { Base = "", Offsets = {} }
    local ce = self.CE
    if mr == nil or ce == nil then return out end
    local base = ce:Get(mr, "Address")
    out.Base = base == nil and "" or tostring(base)
    local count = integer(ce:Get(mr, "OffsetCount")) or 0
    for index = 0, count - 1 do
        local text = offsetTextAt(ce, mr, index, count)
        out.Offsets[index + 1] = text == nil and "0" or tostring(text)
    end
    return out
end

--
--- ∑ Writes a whole pointer chain.
---
---   The order is forced. Writing the address clears the offsets, so the base
---   goes first, then the count, then every offset text, and the record is
---   reinterpreted at the end so the chain is walked once with the new values.
--- @param mr userdata
--- @param pointer table # Base and Offsets, Offsets one being Cheat Engine's zero.
--- @return boolean
--- @return string|nil
--
function Properties:WritePointer(mr, pointer)
    local ce = self.CE
    if mr == nil or ce == nil then return false, "The record is gone." end
    if type(pointer) ~= "table" then return false, "There is no pointer to write." end
    local base = trim(tostring(pointer.Base == nil and "" or pointer.Base))
    if base == "" then return false, "Type a base address." end
    local offsets = {}
    for index, text in ipairs(pointer.Offsets or {}) do
        if type(text) ~= "string" and type(text) ~= "number" then
            return false, "Offset " .. index .. " is not a number."
        end
        local clean = trim(tostring(text))
        if clean == "" then return false, "Offset " .. index .. " is empty." end
        offsets[index] = clean
    end

    if not write(mr, "Address", base) then return false, WRITE_FAILED end
    if not write(mr, "OffsetCount", #offsets) then return false, WRITE_FAILED end
    local count = integer(ce:Get(mr, "OffsetCount")) or 0
    if count ~= #offsets then return false, "Cheat Engine did not accept the offset count." end
    for index = 1, #offsets do
        local ok = pcall(function() mr.OffsetText[index - 1] = offsets[index] end)
        if not ok then return false, "Cheat Engine refused offset " .. index .. "." end
    end
    pcall(function() mr.reinterpret() end)
    for index = 1, #offsets do
        local back = offsetTextAt(ce, mr, index - 1, count)
        if back == nil then return false, "Cheat Engine dropped offset " .. index .. "." end
    end
    return true
end

--------------------------------------------------------
--                     The script                     --
--------------------------------------------------------

--- The script of an Auto Assembler record, and nothing at all for any other
--- record because Cheat Engine keeps no script list on one.
function Properties:ReadScript(mr)
    local ce = self.CE
    if mr == nil or ce == nil then return nil end
    local script = ce:Get(mr, "Script")
    if type(script) ~= "string" then return nil end
    return script
end

--
--- ∑ Writes the script of an Auto Assembler record.
---
---   A write to any other record is dropped by Cheat Engine without a word,
---   because the list it would go into does not exist until the type is right.
---   So this refuses instead, and the page says what to do about it.
--- @param mr userdata
--- @param text string
--- @return boolean
--- @return string|nil
--
function Properties:WriteScript(mr, text)
    local ce = self.CE
    if mr == nil or ce == nil then return false, "The record is gone." end
    if integer(ce:Get(mr, "Type")) ~= TYPE_SCRIPT then
        return false, "The record is not an Auto Assembler script. Change its type first."
    end
    local wanted = tostring(text == nil and "" or text)
    if not write(mr, "Script", wanted) then return false, WRITE_FAILED end
    local back = ce:Get(mr, "Script")
    if type(back) ~= "string" then return false, NOT_ACCEPTED end
    -- Cheat Engine keeps the script in a string list, and a string list puts a
    -- line break after the last line, so only the lines are compared.
    if trim(back) ~= trim(wanted) then return false, NOT_ACCEPTED end
    return true
end

--------------------------------------------------------
--                 The drop-down list                 --
--------------------------------------------------------

--- A string list reads back with a line break after every line, the last one
--- included, and an editor should not show that.
local function listText(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("\r\n", "\n"):gsub("\n+$", ""))
end

--
--- ∑ The drop-down list of one record and the four flags around it.
---
---   The flag getters follow the link while the record is linked, so what comes
---   back is what Cheat Engine would use and not always what this record holds.
---   A group header is read like any other record, because it can carry a list
---   and be linked although its own Value reads empty.
--- @param mr userdata
--- @return table
--
function Properties:ReadDropDown(mr)
    local out = {
        Text = "", ReadOnly = false, DescriptionOnly = false,
        DisplayAsItem = false, Linked = false, LinkedMemrec = ""
    }
    local ce = self.CE
    if mr == nil or ce == nil then return out end
    local list = ce:Get(mr, "DropDownList")
    if list ~= nil then out.Text = listText(ce:Get(list, "Text")) end
    out.ReadOnly = ce:Get(mr, "DropDownReadOnly") == true
    out.DescriptionOnly = ce:Get(mr, "DropDownDescriptionOnly") == true
    out.DisplayAsItem = ce:Get(mr, "DisplayAsDropDownListItem") == true
    out.Linked = ce:Get(mr, "DropDownLinked") == true
    local linked = ce:Get(mr, "DropDownLinkedMemrec")
    out.LinkedMemrec = linked == nil and "" or tostring(linked)
    return out
end

--
--- ∑ Writes the drop-down list and its flags.
---
---   The link goes last, because the flag getters follow it and a read back
---   through a link would compare this record's flags against another record's.
---   A group header takes the write like any other record.
--- @param mr userdata
--- @param dropdown table
--- @return boolean
--- @return string|nil
--
function Properties:WriteDropDown(mr, dropdown)
    local ce = self.CE
    if mr == nil or ce == nil then return false, "The record is gone." end
    if type(dropdown) ~= "table" then return false, "There is no list to write." end
    if dropdown.Text ~= nil then
        local list = ce:Get(mr, "DropDownList")
        if list == nil then return false, "Cheat Engine gave no drop-down list." end
        local wanted = tostring(dropdown.Text)
        if not pcall(function() list.Text = wanted end) then return false, WRITE_FAILED end
        if listText(ce:Get(list, "Text")) ~= listText(wanted) then return false, NOT_ACCEPTED end
    end
    if dropdown.ReadOnly ~= nil then
        if not write(mr, "DropDownReadOnly", dropdown.ReadOnly == true) then
            return false, WRITE_FAILED
        end
    end
    if dropdown.DescriptionOnly ~= nil then
        if not write(mr, "DropDownDescriptionOnly", dropdown.DescriptionOnly == true) then
            return false, WRITE_FAILED
        end
    end
    if dropdown.DisplayAsItem ~= nil then
        if not write(mr, "DisplayAsDropDownListItem", dropdown.DisplayAsItem == true) then
            return false, WRITE_FAILED
        end
    end
    if dropdown.LinkedMemrec ~= nil then
        if not write(mr, "DropDownLinkedMemrec", tostring(dropdown.LinkedMemrec)) then
            return false, WRITE_FAILED
        end
    end
    if dropdown.Linked ~= nil then
        if not write(mr, "DropDownLinked", dropdown.Linked == true) then
            return false, WRITE_FAILED
        end
        if (ce:Get(mr, "DropDownLinked") == true) ~= (dropdown.Linked == true) then
            return false, NOT_ACCEPTED
        end
    end
    if ce:Get(mr, "DropDownLinked") ~= true then
        if dropdown.ReadOnly ~= nil
            and (ce:Get(mr, "DropDownReadOnly") == true) ~= (dropdown.ReadOnly == true) then
            return false, NOT_ACCEPTED
        end
        if dropdown.DescriptionOnly ~= nil
            and (ce:Get(mr, "DropDownDescriptionOnly") == true) ~= (dropdown.DescriptionOnly == true) then
            return false, NOT_ACCEPTED
        end
        if dropdown.DisplayAsItem ~= nil
            and (ce:Get(mr, "DisplayAsDropDownListItem") == true) ~= (dropdown.DisplayAsItem == true) then
            return false, NOT_ACCEPTED
        end
    end
    return true
end

--------------------------------------------------------
--                      Hotkeys                       --
--------------------------------------------------------

--- The hotkey object with that id, read through the record so no wrapper is
--- ever kept between two operations.
local function hotkeyByID(ce, mr, id)
    local count = integer(ce:Get(mr, "HotkeyCount")) or 0
    local holder = ce:Get(mr, "Hotkey")
    if holder == nil then return nil end
    for index = 0, count - 1 do
        local hotkey = ce:Get(holder, index)
        if hotkey ~= nil and integer(ce:Get(hotkey, "ID")) == id then return hotkey end
    end
    return nil
end

--
--- ∑ Every hotkey on one record, in the order Cheat Engine keeps them.
---
---   Action reads back as its name, so the number is looked up rather than
---   read, and it is the number createHotkey would want.
--- @param mr userdata
--- @return table
--
function Properties:ReadHotkeys(mr)
    local out = {}
    local ce = self.CE
    if mr == nil or ce == nil then return out end
    local count = integer(ce:Get(mr, "HotkeyCount")) or 0
    local holder = ce:Get(mr, "Hotkey")
    if holder == nil then return out end
    for index = 0, count - 1 do
        local hotkey = ce:Get(holder, index)
        if hotkey ~= nil then
            local keys = {}
            local list = ce:Get(hotkey, "Keys")
            if type(list) == "table" then
                for position, key in ipairs(list) do keys[position] = key end
            end
            local name = ce:Get(hotkey, "Action")
            local action = ACTION_BY_NAME[name]
            local text = ce:Get(hotkey, "HotkeyString")
            out[#out + 1] = {
                ID = integer(ce:Get(hotkey, "ID")),
                Keys = keys,
                KeysText = type(text) == "string" and text or "",
                Action = name,
                ActionNumber = action and action.Number or nil,
                ActionLabel = action and action.Label or tostring(name or ""),
                Value = ce:Get(hotkey, "Value") or "",
                Description = ce:Get(hotkey, "Description") or "",
                OnlyWhileDown = ce:Get(hotkey, "OnlyWhileDown") == true,
                Active = ce:Get(hotkey, "Active") == true
            }
        end
    end
    return out
end

--- The editor each writable hotkey field takes, named once at the top of the
--- file so the page and the window applier read the same list.
local HOTKEY_FIELDS = Properties.HotkeyFieldKinds

--
--- ∑ Writes one field of one hotkey.
--- @param mr userdata
--- @param hotkeyID number
--- @param key string # Value, Description, Action or OnlyWhileDown.
--- @param value any
--- @return boolean
--- @return string|nil
--
function Properties:WriteHotkey(mr, hotkeyID, key, value)
    local ce = self.CE
    if mr == nil or ce == nil then return false, "The record is gone." end
    local kind = HOTKEY_FIELDS[key]
    if kind == nil then return false, "A hotkey has no field called " .. tostring(key) .. "." end
    local hotkey = hotkeyByID(ce, mr, hotkeyID)
    if hotkey == nil then return false, "The hotkey is gone." end
    local wanted = value
    if kind == "bool" then wanted = value == true
    elseif kind == "text" then wanted = tostring(value == nil and "" or value)
    else
        local action = nil
        if type(value) == "number" then action = ACTION_BY_NUMBER[value]
        else action = ACTION_BY_NAME[tostring(value)] end
        if action == nil then return false, "That is not a hotkey action." end
        wanted = action.Number
    end
    if not pcall(function() hotkey[key] = wanted end) then return false, WRITE_FAILED end
    local back = ce:Get(hotkey, key)
    if kind == "action" then
        local action = ACTION_BY_NUMBER[wanted]
        if action == nil or back ~= action.Name then return false, NOT_ACCEPTED end
        return true
    end
    if kind == "bool" then
        if (back == true) ~= wanted then return false, NOT_ACCEPTED end
        return true
    end
    if tostring(back) ~= wanted then return false, NOT_ACCEPTED end
    return true
end

return Properties
