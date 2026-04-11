local NAME = "Manifold.Memory.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.4"
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
]]--

Memory = {}
Memory.__index = Memory

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
        logger:Info("[Memory] Failed to retrieve module info.")
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
        logger:Error("[Memory] SafeGetAddress failed: addressOrSymbol is nil")
        return nil
    end
    if not self:_IsOptionalBoolean(isLocal) then
        logger:Error("[Memory] SafeGetAddress failed: isLocal must be a boolean or nil")
        return nil
    end
    local valueType = type(addressOrSymbol)
    if valueType == "number" then
        if addressOrSymbol < 0 then
            logger:ErrorF("[Memory] SafeGetAddress failed: invalid numeric address %d", addressOrSymbol)
            return nil
        end
        return addressOrSymbol
    end
    if valueType ~= "string" then
        logger:Error("[Memory] SafeGetAddress failed: expected string or number, got " .. valueType)
        return nil
    end
    if addressOrSymbol == "" then
        logger:Error("[Memory] SafeGetAddress failed: symbol name is empty")
        return nil
    end
    local address = getAddressSafe(addressOrSymbol, isLocal == true)
    if not self:_IsNumber(address) then
        logger:Error("[Memory] Unable to find address for symbol: " .. tostring(addressOrSymbol))
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

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
--- SafeReadByte
--- ∑ Reads a byte from the given address.
---   If the read is successful, it returns the byte value; otherwise, it returns nil.
--- @param address string|number # The memory address or symbol to read from.
--- @return integer|nil # The byte value read from the address, or nil if the read fails.
--
function Memory:SafeReadByte(address)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return nil end
    local value = readByte(resolved)
    if not self:_IsNumber(value) then
        logger:ErrorF("[Memory] Unable to read byte value at address '0x%08X'", resolved)
        return nil
    end
    logger:InfoF("[Memory] Successfully read byte value from address '0x%08X': %d", resolved, value)
    return value
end
registerLuaFunctionHighlight('SafeReadByte')

--
--- SafeWriteByte
--- ∑ Writes a byte to the specified address.
---   Returns true if the write is successful, otherwise false.
--- @param address string|number # The memory address or symbol to write to.
--- @param value integer # The byte value to write.
--- @return boolean
--
function Memory:SafeWriteByte(address, value)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    local success = writeByte(resolved, value)
    if not success then
        logger:ErrorF("[Memory] Unable to write byte value %d to address '0x%08X'", value, resolved)
        return false
    end
    logger:InfoF("[Memory] Successfully wrote byte value %d to address '0x%08X'", value, resolved)
    return true
end
registerLuaFunctionHighlight('SafeWriteByte')

--
--- SafeAddByte
--- ∑ Adds a value to the current byte value at the given address.
---   If the read and write operations are successful, returns true; otherwise, returns false.
--- @param address string|number # The memory address or symbol to modify.
--- @param value integer # The value to add to the current byte value.
--- @return boolean
--
function Memory:SafeAddByte(address, value)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    local currentValue = self:SafeReadByte(resolved)
    if not self:_IsNumber(currentValue) then
        logger:ErrorF("[Memory] Unable to add byte value due to read failure at address '0x%08X'", resolved)
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteByte(resolved, newValue)
    if not success then
        logger:ErrorF("[Memory] Unable to write new byte value to address '0x%08X'", resolved)
        return false
    end
    logger:InfoF("[Memory] Successfully added %d to byte value at address '0x%08X'. New value: %d", value, resolved, newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddByte')

--
--- SafeReadWord
--- ∑ Reads a 2-byte value from the specified address.
---   If successful, returns the word value; otherwise, returns nil.
--- @param address string|number # The memory address or symbol to read from.
--- @param signed boolean # Optional flag. If true, reads as signed integer.
--- @return integer|nil
--
function Memory:SafeReadWord(address, signed)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return nil end
    if not self:_RequireSignedFlag(signed, "Memory") then return nil end
    local value = readSmallInteger(resolved, signed == true)
    if not self:_IsNumber(value) then
        logger:ErrorF("[Memory] Unable to read word value at address '0x%08X'", resolved)
        return nil
    end
    logger:InfoF("[Memory] Successfully read word value from address '0x%08X': %d", resolved, value)
    return value
end
registerLuaFunctionHighlight('SafeReadWord')

--
--- SafeWriteWord
--- ∑ Writes a 2-byte value to the specified address.
---   Returns true if the write is successful, otherwise false.
--- @param address string|number # The memory address or symbol to write to.
--- @param value integer # The word value to write.
--- @return boolean
--
function Memory:SafeWriteWord(address, value)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    local success = writeSmallInteger(resolved, value)
    if not success then
        logger:ErrorF("[Memory] Unable to write word value %d to address '0x%08X'", value, resolved)
        return false
    end
    logger:InfoF("[Memory] Successfully wrote word value %d to address '0x%08X'", value, resolved)
    return true
end
registerLuaFunctionHighlight('SafeWriteWord')

--
--- SafeAddWord
--- ∑ Adds a value to the current 2-byte value at the specified address.
---   Returns true if the operation succeeds, otherwise false.
--- @param address string|number # The memory address or symbol to modify.
--- @param value integer # The value to add.
--- @param signed boolean # Optional flag. If true, reads as signed integer.
--- @return boolean
--
function Memory:SafeAddWord(address, value, signed)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    if not self:_RequireSignedFlag(signed, "Memory") then return false end
    local currentValue = self:SafeReadWord(resolved, signed)
    if not self:_IsNumber(currentValue) then
        logger:ErrorF("[Memory] Unable to add word value due to read failure at address '0x%08X'", resolved)
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteWord(resolved, newValue)
    if not success then
        logger:ErrorF("[Memory] Unable to write new word value to address '0x%08X'", resolved)
        return false
    end
    logger:InfoF("[Memory] Successfully added %d to word value at address '0x%08X'. New value: %d", value, resolved, newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddWord')

--
--- SafeReadInteger
--- ∑ Reads a 4-byte integer from the specified address.
---   Returns the integer value if the read is successful; otherwise, returns nil.
--- @param address string|number # The memory address or symbol to read from.
--- @param signed boolean # Optional flag. If true, reads as signed integer.
--- @return integer|nil
--
function Memory:SafeReadInteger(address, signed)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return nil end
    if not self:_RequireSignedFlag(signed, "Memory") then return nil end
    local value = readInteger(resolved, signed == true)
    if not self:_IsNumber(value) then
        logger:ErrorF("[Memory] Unable to read integer value at address '0x%08X'", resolved)
        return nil
    end
    logger:InfoF("[Memory] Successfully read integer value from address '0x%08X': %d", resolved, value)
    return value
end
registerLuaFunctionHighlight('SafeReadInteger')

--
--- SafeWriteInteger
--- ∑ Writes a 4-byte integer to the specified address.
---   Returns true if the write is successful; otherwise, false.
--- @param address string|number # The memory address or symbol to write to.
--- @param value integer # The integer value to write.
--- @return boolean
--
function Memory:SafeWriteInteger(address, value)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    local success = writeInteger(resolved, value)
    if not success then
        logger:ErrorF("[Memory] Unable to write integer value %d to address '0x%08X'", value, resolved)
        return false
    end
    logger:InfoF("[Memory] Successfully wrote integer value %d to address '0x%08X'", value, resolved)
    return true
end
registerLuaFunctionHighlight('SafeWriteInteger')

--
--- SafeAddInteger
--- ∑ Adds a value to the current integer value at the specified address.
---   Returns true if the operation succeeds, otherwise false.
--- @param address string|number # The memory address or symbol to modify.
--- @param value integer # The value to add.
--- @param signed boolean # Optional flag. If true, reads as signed integer.
--- @return boolean
--
function Memory:SafeAddInteger(address, value, signed)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    if not self:_RequireSignedFlag(signed, "Memory") then return false end
    local currentValue = self:SafeReadInteger(resolved, signed)
    if not self:_IsNumber(currentValue) then
        logger:ErrorF("[Memory] Unable to add integer value due to read failure at address '0x%08X'", resolved)
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteInteger(resolved, newValue)
    if not success then
        logger:ErrorF("[Memory] Unable to write new integer value to address '0x%08X'", resolved)
        return false
    end
    logger:InfoF("[Memory] Successfully added %d to integer value at address '0x%08X'. New value: %d", value, resolved, newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddInteger')

--
--- SafeReadQWord
--- ∑ Reads an 8-byte QWord value from the specified address.
---   Returns the value if successful, otherwise returns nil.
--- @param address string|number # The memory address or symbol to read from.
--- @return integer|nil
--
function Memory:SafeReadQWord(address)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return nil end
    local value = readQword(resolved)
    if not self:_IsNumber(value) then
        logger:ErrorF("[Memory] Unable to read QWord from address '0x%08X'", resolved)
        return nil
    end
    logger:InfoF("[Memory] Successfully read QWord value %d from address '0x%08X'", value, resolved)
    return value
end
registerLuaFunctionHighlight('SafeReadQWord')

--
--- SafeWriteQWord
--- ∑ Writes an 8-byte QWord value to the specified address.
---   Returns true if the write is successful, otherwise false.
--- @param address string|number # The memory address or symbol to write to.
--- @param value integer # The QWord value to write.
--- @return boolean
--
function Memory:SafeWriteQWord(address, value)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    local success = writeQword(resolved, value)
    if not success then
        logger:ErrorF("[Memory] Unable to write QWord value %d to address '0x%08X'", value, resolved)
        return false
    end
    logger:InfoF("[Memory] Successfully wrote QWord value %d to address '0x%08X'", value, resolved)
    return true
end
registerLuaFunctionHighlight('SafeWriteQWord')

--
--- SafeAddQWord
--- ∑ Adds a value to the current QWord value at the specified address.
---   Returns true if the operation succeeds, otherwise false.
--- @param address string|number # The memory address or symbol to modify.
--- @param value integer # The value to add.
--- @return boolean
--
function Memory:SafeAddQWord(address, value)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    local currentValue = self:SafeReadQWord(resolved)
    if not self:_IsNumber(currentValue) then
        logger:ErrorF("[Memory] Unable to add QWord value due to read failure at address '0x%08X'", resolved)
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteQWord(resolved, newValue)
    if not success then
        logger:ErrorF("[Memory] Unable to write new QWord value to address '0x%08X'", resolved)
        return false
    end
    logger:InfoF("[Memory] Successfully added %d to QWord value at address '0x%08X'. New value: %d", value, resolved, newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddQWord')

--
--- SafeReadFloat
--- ∑ Reads a float value from the specified memory address.
---   If the read is successful, it returns the float value; otherwise, it returns nil.
--- @param address string|number # The memory address or symbol to read from.
--- @return float|nil
--
function Memory:SafeReadFloat(address)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return nil end
    local value = readFloat(resolved)
    if not self:_IsNumber(value) then
        logger:ErrorF("[Memory] Unable to read float value at address '0x%08X'", resolved)
        return nil
    end
    logger:InfoF("[Memory] Successfully read float value from address '0x%08X': %f", resolved, value)
    return value
end
registerLuaFunctionHighlight('SafeReadFloat')

--
--- SafeWriteFloat
--- ∑ Writes a float value to the specified memory address.
---   Returns true if the write operation succeeds, otherwise false.
--- @param address string|number # The memory address or symbol to write to.
--- @param value float # The float value to write to the address.
--- @return boolean
--
function Memory:SafeWriteFloat(address, value)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    local success = writeFloat(resolved, value)
    if not success then
        logger:ErrorF("[Memory] Unable to write float value %f to address '0x%08X'", value, resolved)
        return false
    end
    logger:InfoF("[Memory] Successfully wrote float value %f to address '0x%08X'", value, resolved)
    return true
end
registerLuaFunctionHighlight('SafeWriteFloat')

--
--- SafeAddFloat
--- ∑ Adds a value to the current float value at the specified address.
---   If the read and write operations are successful, returns true; otherwise, false.
--- @param address string|number # The memory address or symbol to modify.
--- @param value float # The value to add to the current float value.
--- @return boolean
--
function Memory:SafeAddFloat(address, value)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    local currentValue = self:SafeReadFloat(resolved)
    if not self:_IsNumber(currentValue) then
        logger:ErrorF("[Memory] Unable to add float value due to read failure at address '0x%08X'", resolved)
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteFloat(resolved, newValue)
    if not success then
        logger:ErrorF("[Memory] Unable to write new float value to address '0x%08X'", resolved)
        return false
    end
    logger:InfoF("[Memory] Successfully added %f to float value at address '0x%08X'. New value: %f", value, resolved, newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddFloat')

--
--- SafeReadDouble
--- ∑ Reads a double value from the specified memory address.
---   If the read is successful, it returns the double value; otherwise, it returns nil.
--- @param address string|number # The memory address or symbol to read from.
--- @return double|nil
--
function Memory:SafeReadDouble(address)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return nil end
    local value = readDouble(resolved)
    if not self:_IsNumber(value) then
        logger:ErrorF("[Memory] Unable to read double value at address '0x%08X'", resolved)
        return nil
    end
    logger:InfoF("[Memory] Successfully read double value from address '0x%08X': %f", resolved, value)
    return value
end
registerLuaFunctionHighlight('SafeReadDouble')

--
--- SafeWriteDouble
--- ∑ Writes a double value to the specified memory address.
---   Returns true if the write operation is successful, otherwise false.
--- @param address string|number # The memory address or symbol to write to.
--- @param value double # The double value to write to the address.
--- @return boolean
--
function Memory:SafeWriteDouble(address, value)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    local success = writeDouble(resolved, value)
    if not success then
        logger:ErrorF("[Memory] Unable to write double value %f to address '0x%08X'", value, resolved)
        return false
    end
    logger:InfoF("[Memory] Successfully wrote double value %f to address '0x%08X'", value, resolved)
    return true
end
registerLuaFunctionHighlight('SafeWriteDouble')

--
--- SafeAddDouble
--- ∑ Adds a value to the current double value at the specified address.
---   If the read and write operations are successful, returns true; otherwise, false.
--- @param address string|number # The memory address or symbol to modify.
--- @param value double # The value to add to the current double value.
--- @return boolean
--
function Memory:SafeAddDouble(address, value)
    local resolved = self:_RequireAddress(address, "Memory")
    if not resolved then return false end
    if not self:_RequireNumber(value, "Memory", "value") then return false end
    local currentValue = self:SafeReadDouble(resolved)
    if not self:_IsNumber(currentValue) then
        logger:ErrorF("[Memory] Unable to add double value due to read failure at address '0x%08X'", resolved)
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteDouble(resolved, newValue)
    if not success then
        logger:ErrorF("[Memory] Unable to write new double value to address '0x%08X'", resolved)
        return false
    end
    logger:InfoF(
        "[Memory] Successfully added %.2f to address '0x%08X'. Original value: %.2f, New value: %.2f", value, resolved, currentValue, newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddDouble')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Memory