local NAME = "Manifold.Memory.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.1.0"
local DESCRIPTION = "Manifold Framework Memory"

--[[
    ∂ v1.1.0 (2026-08-23)
        Gained ResolvePointerPath from Manifold.Utils. It resolves an address
        and reads pointers, which is this module's goal.
        Implemented the Bootstrap handshake so this module
        can be loaded on its own or through the framework.
]]--

--
--- ∑ Per-access success logging. OFF by default: the module used to write an
---   Info line for every single read, write and add, and Manifold.Logger writes
---   the log FILE before it applies the level filter - so a script polling a
---   value each frame produced an open/write/close per frame regardless of the
---   configured level. Turn it on only while diagnosing a specific access.
--
Memory = {
    LogSuccessfulOperations = false,}
Memory.__index = Memory

local MODULE_PREFIX = "[Memory]"

--
--- ∑ Manifold.Bootstrap handshake. Uses the framework core when the cheat
---   table has loaded it, and degrades to an inert stub when it has not, so
---   this module stays loadable on its own. Identical in every module - this
---   is the one duplication the design costs, and it is irreducible: something
---   has to reach the loader before the loader exists.
--
local BOOTSTRAP = rawget(_G, "ManifoldBootstrap") or {
    Declare = function(spec) return spec end,
    Resolve = function() return true end,
    Ready   = function(_, instance) return instance end,
    Once    = function(_, fn) if type(fn) == "function" then pcall(fn) end return true end,
}

--
--- ∑ This module's identity and its dependency contract, in one place.
---     required = true -> New() refuses rather than pretending to be ready
---     runtime  = true -> documented only; never loaded here, never ordered on
--
local MODULE = BOOTSTRAP.Declare({
    class = "Memory", global = "memory",
    name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION,
    prefix = MODULE_PREFIX,
    deps = {
        { "logger", required = true },
    },
})


local TYPE_HANDLERS = {
    Byte = {
        read = readByte,
        write = writeByte,
        label = "byte value",
        format = "%d"
    },
    Word = {
        read = readSmallInteger,
        write = writeSmallInteger,
        label = "word value",
        format = "%d",
        supportsSigned = true
    },
    Integer = {
        read = readInteger,
        write = writeInteger,
        label = "integer value",
        format = "%d",
        supportsSigned = true
    },
    QWord = {
        read = readQword,
        write = writeQword,
        label = "QWord value",
        format = "%d"
    },
    Float = {
        read = readFloat,
        write = writeFloat,
        label = "float value",
        format = "%f"
    },
    Double = {
        read = readDouble,
        write = writeDouble,
        label = "double value",
        format = "%f"
    }
}

function Memory:New()
    local instance = setmetatable({}, self)
    instance.Name = NAME or "Unnamed Module"
    return BOOTSTRAP.Ready(MODULE, instance)
end
registerLuaFunctionHighlight('New')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table # {name, version, author, description}
--
function Memory:GetModuleInfo()
    return {
        name = NAME,
        version = VERSION,
        author = AUTHOR,
        description = DESCRIPTION
    }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Prints module details in a readable formatted block.
--
function Memory:PrintModuleInfo()
    local info = self:GetModuleInfo()
    if not info then
        logger:Info(MODULE_PREFIX .. " Failed to retrieve module info.")
        return
    end
    local author = type(info.author) == "table" and table.concat(info.author, ", ") or tostring(info.author)
    local description = type(info.description) == "table" and table.concat(info.description, ", ") or tostring(info.description)
    logger:Info("Module Info : " .. tostring(info.name))
    logger:Info("\tVersion:     " .. tostring(info.version))
    logger:Info("\tAuthor:      " .. author)
    logger:Info("\tDescription: " .. description .. "\n")
end
registerLuaFunctionHighlight('PrintModuleInfo')

--------------------------------------------------------
--                  Internal Helpers                  --
--------------------------------------------------------

--
--- ∑ Returns true if the given value is a finite number.
--- @param value any
--- @return boolean
--
function Memory:_IsNumber(value)
    return type(value) == "number" and value == value
end

--
--- ∑ Returns true if the given value is a boolean or nil.
--- @param value any
--- @return boolean
--
function Memory:_IsOptionalBoolean(value)
    return value == nil or type(value) == "boolean"
end

--
--- ∑ Formats an address as a hexadecimal string for logging.
--- @param address integer
--- @return string
--
function Memory:_FormatAddress(address)
    if type(address) ~= "number" then return tostring(address) end
    -- "0x%08X" truncates nothing, but it pads to eight digits and then prints a
    -- 12-digit x64 address unpadded next to eight-digit ones, so nothing lines
    -- up in the log. Pick the width from the value.
    if address > 0xFFFFFFFF then
        return string.format("0x%016X", address)
    end
    return string.format("0x%08X", address)
end

--
--- ∑ Logs a failed read attempt with details about the type and address.
--- @param typeInfo table
--- @param address integer
--
function Memory:_LogReadFailure(typeInfo, address)
    logger:ErrorF("%s Unable to read %s at address '%s'", MODULE_PREFIX, typeInfo.label, self:_FormatAddress(address))
end

--
--- ∑ Logs a failed write attempt with details about the type, value, and address.
--- @param typeInfo table
--- @param address integer
--- @param value number
--
function Memory:_LogWriteFailure(typeInfo, address, value)
    logger:ErrorF("%s Unable to write %s " .. typeInfo.format .. " to address '%s'", MODULE_PREFIX, typeInfo.label, value, self:_FormatAddress(address))
end

--
--- ∑ Resolves a symbol, module name, or numeric address to a usable address value.
---   If a number is passed, it is returned unchanged.
---   If a string is passed, it is resolved via getAddressSafe().
---   On failure, returns nil.
--- @param addressOrSymbol string|number
--- @param isLocal boolean
--- @return integer|nil
--
function Memory:SafeGetAddress(addressOrSymbol, isLocal)
    if addressOrSymbol == nil then
        logger:Error(MODULE_PREFIX .. " SafeGetAddress failed: addressOrSymbol is nil")
        return nil
    end
    if not self:_IsOptionalBoolean(isLocal) then
        logger:Error(MODULE_PREFIX .. " SafeGetAddress failed: isLocal must be a boolean or nil")
        return nil
    end
    local valueType = type(addressOrSymbol)
    if valueType == "number" then
        if addressOrSymbol < 0 then
            logger:ErrorF("%s SafeGetAddress failed: invalid numeric address %d", MODULE_PREFIX, addressOrSymbol)
            return nil
        end
        return addressOrSymbol
    end
    if valueType ~= "string" then
        logger:Error(MODULE_PREFIX .. " SafeGetAddress failed: expected string or number, got " .. valueType)
        return nil
    end
    if addressOrSymbol == "" then
        logger:Error(MODULE_PREFIX .. " SafeGetAddress failed: symbol name is empty")
        return nil
    end
    local address = getAddressSafe(addressOrSymbol, isLocal == true)
    if not self:_IsNumber(address) then
        logger:Error(MODULE_PREFIX .. " Unable to find address for symbol: " .. tostring(addressOrSymbol))
        return nil
    end
    return address
end
registerLuaFunctionHighlight('SafeGetAddress')

--
--- ∑ Follows a pointer chain from a base address or symbol.
---   Moved here from Manifold.Utils in Memory 1.1.0, on what it touches rather
---   than on its name: it resolves an address and it reads pointers, which are
---   the two things this module owns, and it touches no Utils config field, no
---   AddressList and no CE UI object. A pointer chain is their composition.
---
---   Three things it does that the original did not:
---
---     * A NULL POINTER MID-CHAIN IS A FAILURE, not an address. The original
---       computed `0 + offset` and carried on, so an object the game has not
---       allocated yet produced a plausible-looking low address. A caller that
---       then wrote to it corrupted whatever happens to live there. This is the
---       single most valuable change: an unallocated pointer is the normal case
---       in a game, not an exceptional one.
---     * ON FAILURE IT PRINTS THE CHAIN IT WALKED, so "which hop broke" is
---       answerable from one log line instead of a bisect. On success it logs
---       nothing at all.
---     * It forwards isLocal to SafeGetAddress, which has always accepted it.
---
---   Returns ONE value deliberately. A second return - the step trace - would
---   leak into every multi-value context the way a bare gsub does, and the
---   trace is only interesting when the walk fails, where it is logged.
--- @param baseAddress string|number # base address or symbol
--- @param offsets table # list of integer offsets, applied in order
--- @param isLocal boolean|nil # resolve the symbol in Cheat Engine's own space
--- @return number|nil # the resolved address, or nil with the reason logged
--
function Memory:ResolvePointerPath(baseAddress, offsets, isLocal)
    if type(baseAddress) ~= "string" and type(baseAddress) ~= "number" then
        logger:ErrorF("%s ResolvePointerPath: base address must be a string or number, got %s",
                      MODULE_PREFIX, type(baseAddress))
        return nil
    end
    if type(offsets) ~= "table" then
        logger:ErrorF("%s ResolvePointerPath: offsets must be a table, got %s",
                      MODULE_PREFIX, type(offsets))
        return nil
    end
    if not self:_IsOptionalBoolean(isLocal) then
        logger:ErrorF("%s ResolvePointerPath: isLocal must be a boolean or nil, got %s",
                      MODULE_PREFIX, type(isLocal))
        return nil
    end

    local address = self:SafeGetAddress(baseAddress, isLocal)
    if not address then
        logger:ErrorF("%s ResolvePointerPath: base '%s' could not be resolved.",
                      MODULE_PREFIX, tostring(baseAddress))
        return nil
    end

    -- The walk so far, rendered only if something goes wrong.
    local trace = { self:_FormatAddress(address) }
    local function walked()
        return table.concat(trace, " -> ")
    end

    for index = 1, #offsets do
        local offset = offsets[index]
        if not self:_IsNumber(offset) or offset ~= math.floor(offset) then
            logger:ErrorF("%s ResolvePointerPath: offset %d must be an integer, got %s.",
                          MODULE_PREFIX, index, tostring(offset))
            return nil
        end

        local value = readPointer(address)
        if not self:_IsNumber(value) then
            logger:ErrorF("%s ResolvePointerPath: could not read a pointer at hop %d of %d. Walked: %s",
                          MODULE_PREFIX, index, #offsets, walked())
            return nil
        end
        if value == 0 then
            -- The original added the offset to zero and kept going, handing back
            -- a low garbage address that looked resolved.
            logger:ErrorF("%s ResolvePointerPath: null pointer at hop %d of %d - the target is not allocated yet. Walked: %s",
                          MODULE_PREFIX, index, #offsets, walked())
            return nil
        end

        address = value + offset
        trace[#trace + 1] = self:_FormatAddress(address)
    end

    return address
end
registerLuaFunctionHighlight('ResolvePointerPath')

--
--- ∑ Resolves and validates an address input for memory operations.
--- @param address string|number
--- @param functionName string
--- @return integer|nil
--
function Memory:_RequireAddress(address, functionName)
    local resolved = self:SafeGetAddress(address)
    if not self:_IsNumber(resolved) then
        logger:Error("[" .. tostring(functionName) .. "] Invalid address")
        return nil
    end
    return resolved
end

--
--- ∑ Validates that a numeric value is present.
--- @param value any
--- @param functionName string
--- @param paramName string
--- @return boolean
--
function Memory:_RequireNumber(value, functionName, paramName)
    if not self:_IsNumber(value) then
        logger:Error("[" .. tostring(functionName) .. "] " .. tostring(paramName) .. " must be a number")
        return false
    end
    return true
end

--
--- ∑ Validates an optional signed flag.
--- @param signed any
--- @param functionName string
--- @return boolean
--
function Memory:_RequireSignedFlag(signed, functionName)
    if not self:_IsOptionalBoolean(signed) then
        logger:Error("[" .. tostring(functionName) .. "] signed must be a boolean or nil")
        return false
    end
    return true
end

--
--- ∑ Reads a value from memory using the appropriate type handler, with optional signed support.
--- @param address integer
--- @param typeInfo table
--- @param signed boolean
--- @return number|nil
--
function Memory:_ReadResolvedValue(address, typeInfo, signed)
    if typeInfo.supportsSigned then
        return typeInfo.read(address, signed == true)
    end
    return typeInfo.read(address)
end

--
--- ∑ Writes a value to memory using the appropriate type handler.
--- @param address integer
--- @param value number
--- @param typeInfo table
--- @return boolean
--
function Memory:_WriteResolvedValue(address, value, typeInfo)
    return typeInfo.write(address, value)
end

--
--- ∑ Safely reads a value from the specified address with type validation and logging.
--- @param address string|number
--- @param typeInfo table
--- @param signed boolean
--- @return number|nil
--
function Memory:_SafeReadValue(address, typeInfo, signed)
    local resolved = self:_RequireAddress(address, "SafeRead")
    if not resolved then return nil end
    if typeInfo.supportsSigned and not self:_RequireSignedFlag(signed, "SafeRead") then
        return nil
    end
    local value = self:_ReadResolvedValue(resolved, typeInfo, signed)
    if not self:_IsNumber(value) then
        self:_LogReadFailure(typeInfo, resolved)
        return nil
    end
    if self.LogSuccessfulOperations then
        logger:DebugF("%s Read %s from '%s': " .. typeInfo.format,
                      MODULE_PREFIX, typeInfo.label, self:_FormatAddress(resolved), value)
    end
    return value
end

--
--- ∑ Safely writes a value to the specified address with type validation and logging.
--- @param address string|number
--- @param value number
--- @param typeInfo table
--- @return boolean # true on success, false on failure
--
function Memory:_SafeWriteValue(address, value, typeInfo)
    local resolved = self:_RequireAddress(address, "SafeWrite")
    if not resolved then return false end
    if not self:_RequireNumber(value, "SafeWrite", "value") then return false end
    local success = self:_WriteResolvedValue(resolved, value, typeInfo)
    if not success then
        self:_LogWriteFailure(typeInfo, resolved, value)
        return false
    end
    if self.LogSuccessfulOperations then
        logger:DebugF("%s Wrote %s " .. typeInfo.format .. " to '%s'",
                      MODULE_PREFIX, typeInfo.label, value, self:_FormatAddress(resolved))
    end
    return true
end

--
--- ∑ Safely adds a value to the current value at the specified address.
---   This reads the current value, adds the specified amount, and writes it back.
--- @param address string|number
--- @param value number
--- @param typeInfo table
--- @param signed boolean
--- @return boolean # true on success, false on failure
--
function Memory:_SafeAddValue(address, value, typeInfo, signed)
    local resolved = self:_RequireAddress(address, "SafeAdd")
    if not resolved then return false end
    if not self:_RequireNumber(value, "SafeAdd", "value") then return false end
    if typeInfo.supportsSigned and not self:_RequireSignedFlag(signed, "SafeAdd") then
        return false
    end
    local currentValue = self:_ReadResolvedValue(resolved, typeInfo, signed)
    if not self:_IsNumber(currentValue) then
        logger:ErrorF("%s Unable to add %s due to read failure at address '%s'", MODULE_PREFIX, typeInfo.label, self:_FormatAddress(resolved))
        return false
    end
    local newValue = currentValue + value
    local success = self:_WriteResolvedValue(resolved, newValue, typeInfo)
    if not success then
        logger:ErrorF("%s Unable to write new %s to address '%s'", MODULE_PREFIX, typeInfo.label, self:_FormatAddress(resolved))
        return false
    end
    if self.LogSuccessfulOperations then
        logger:DebugF("%s Added " .. typeInfo.format .. " to %s at '%s', now " .. typeInfo.format,
                      MODULE_PREFIX, value, typeInfo.label, self:_FormatAddress(resolved), newValue)
    end
    return true
end

--
--- ∑ Registers safe read/write/add functions for a specific type based on provided type information.
---   This dynamically creates functions like SafeReadByte, SafeWriteByte, SafeAddByte, etc.
--- @param typeName string
--
local function _registerTypedOperations(typeName)
    local typeInfo = TYPE_HANDLERS[typeName]
    local readName = "SafeRead" .. typeName
    local writeName = "SafeWrite" .. typeName
    local addName = "SafeAdd" .. typeName
    Memory[readName] = function(self, address, signed)
        return self:_SafeReadValue(address, typeInfo, signed)
    end
    registerLuaFunctionHighlight(readName)
    Memory[writeName] = function(self, address, value)
        return self:_SafeWriteValue(address, value, typeInfo)
    end
    registerLuaFunctionHighlight(writeName)
    Memory[addName] = function(self, address, value, signed)
        return self:_SafeAddValue(address, value, typeInfo, signed)
    end
    registerLuaFunctionHighlight(addName)
end

for _, typeName in ipairs({"Byte", "Word", "Integer", "QWord", "Float", "Double"}) do
    _registerTypedOperations(typeName)
end

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Memory