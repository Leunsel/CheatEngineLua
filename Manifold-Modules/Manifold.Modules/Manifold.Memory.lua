local NAME = "Manifold.Memory.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.5"
local DESCRIPTION = "Manifold Framework Memory"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.

    ∂ v1.0.1 (2025-04-11)
        Minor comment adjustments.

    ∂ v1.0.2 (2025-12-27)
        Minor log formatting adjustments.

    ∂ v1.0.3 (2026-04-04)
        Added Signed-Flag Support to Word and Integer functions.

    ∂ v1.0.4 (2026-04-11)
        Hardened all memory helpers with type validation, safer address resolution,
        and consistent logger formatting.

    ∂ v1.0.5 (2026-04-20)
        Refactored duplicated read/write/add logic into shared operation helpers.
        Reduced repeated address resolution and centralized validation/log formatting.
]]--

Memory = {}
Memory.__index = Memory

local MODULE_PREFIX = "[Memory]"

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
    return instance
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
registerLuaFunctionHighlight('_IsNumber')

--
--- ∑ Returns true if the given value is a boolean or nil.
--- @param value any
--- @return boolean
--
function Memory:_IsOptionalBoolean(value)
    return value == nil or type(value) == "boolean"
end
registerLuaFunctionHighlight('_IsOptionalBoolean')

--
--- ∑ Formats an address as a hexadecimal string for logging.
--- @param address integer
--- @return string
--
function Memory:_FormatAddress(address)
    return string.format("0x%08X", address)
end
registerLuaFunctionHighlight('_FormatAddress')

--
--- ∑ Logs a failed read attempt with details about the type and address.
--- @param typeInfo table
--- @param address integer
--
function Memory:_LogReadFailure(typeInfo, address)
    logger:ErrorF("%s Unable to read %s at address '%s'", MODULE_PREFIX, typeInfo.label, self:_FormatAddress(address))
end
registerLuaFunctionHighlight('_LogReadFailure')

--
--- ∑ Logs a failed write attempt with details about the type, value, and address.
--- @param typeInfo table
--- @param address integer
--- @param value number
--
function Memory:_LogWriteFailure(typeInfo, address, value)
    logger:ErrorF("%s Unable to write %s " .. typeInfo.format .. " to address '%s'", MODULE_PREFIX, typeInfo.label, value, self:_FormatAddress(address))
end
registerLuaFunctionHighlight('_LogWriteFailure')

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
registerLuaFunctionHighlight('_RequireAddress')

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
registerLuaFunctionHighlight('_RequireNumber')

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
registerLuaFunctionHighlight('_RequireSignedFlag')

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
registerLuaFunctionHighlight('_ReadResolvedValue')

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
registerLuaFunctionHighlight('_WriteResolvedValue')

--
--- ∑ Safely reads a value from the specified address with type validation and logging.
--- @param address string|number
--- @param typeInfo table
--- @param signed boolean
--- @return number|nil
--
function Memory:_SafeReadValue(address, typeInfo, signed)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return nil end
    if typeInfo.supportsSigned and not self:_RequireSignedFlag(signed, "Memory") then
        return nil
    end
    local value = self:_ReadResolvedValue(resolved, typeInfo, signed)
    if not self:_IsNumber(value) then
        self:_LogReadFailure(typeInfo, resolved)
        return nil
    end
    logger:InfoF("%s Successfully read %s from address '%s': " .. typeInfo.format, MODULE_PREFIX, typeInfo.label, self:_FormatAddress(resolved), value)
    return value
end
registerLuaFunctionHighlight('_SafeReadValue')

--
--- ∑ Safely writes a value to the specified address with type validation and logging.
--- @param address string|number
--- @param value number
--- @param typeInfo table
--- @return boolean # true on success, false on failure
--
function Memory:_SafeWriteValue(address, value, typeInfo)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    local success = self:_WriteResolvedValue(resolved, value, typeInfo)
    if not success then
        self:_LogWriteFailure(typeInfo, resolved, value)
        return false
    end
    logger:InfoF("%s Successfully wrote %s " .. typeInfo.format .. " to address '%s'", MODULE_PREFIX, typeInfo.label, value, self:_FormatAddress(resolved))
    return true
end
registerLuaFunctionHighlight('_SafeWriteValue')

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
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    if typeInfo.supportsSigned and not self:_RequireSignedFlag(signed, "Memory") then
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
    logger:InfoF("%s Successfully added " .. typeInfo.format .. " to %s at address '%s'. New value: " .. typeInfo.format, MODULE_PREFIX, value, typeInfo.label, self:_FormatAddress(resolved), newValue)
    return true
end
registerLuaFunctionHighlight('_SafeAddValue')

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