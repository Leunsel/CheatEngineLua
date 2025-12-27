local NAME = "Manifold.Memory.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.2"
local DESCRIPTION = "Manifold Framework Memory"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.

    ∂ v1.0.1 (2025-04-11)
        Minor comment adjustments.

    ∂ v1.0.2 (2025-12-27)
        Minor log formatting adjustments.
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
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
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
    logger:Info("Module Info : "  .. tostring(info.name))
    logger:Info("\tVersion:     " .. tostring(info.version))
    local author = type(info.author) == "table" and table.concat(info.author, ", ") or tostring(info.author)
    local description = type(info.description) == "table" and table.concat(info.description, ", ") or tostring(info.description)
    logger:Info("\tAuthor:      " .. author)
    logger:Info("\tDescription: " .. description .. "\n")
end
registerLuaFunctionHighlight('PrintModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

-- 
--- SafeGetAddress
--- ∑ Retrieves the address for a given symbol (AddressString). 
---   If the address is found, it returns the address as an integer. 
---   Otherwise, it returns nil.
--- @param AddressString string # The symbol or module name to query for the address.
--- @param isLocal boolean # Optional flag to query the local symbol table (default is false).
--- @return integer # The address corresponding to AddressString, or nil if not found.
--
function Memory:SafeGetAddress(AddressString, isLocal)
    local localQuery = isLocal or false
    local address = getAddressSafe(AddressString, localQuery)
    if not address then
        logger:Error("[Memory] Unable to find address for symbol: " .. AddressString)
        return nil
    end
    return address
end
registerLuaFunctionHighlight('SafeGetAddress')

-- 
--- SafeReadByte
--- ∑ Reads a byte from the given address. 
---   If the read is successful, it returns the byte value; otherwise, it returns nil.
--- @param address integer # The memory address to read from.
--- @return integer # The byte value read from the address, or nil if the read fails.
--
function Memory:SafeReadByte(address)
    local value = readByte(address)
    if value == nil then
        logger:ErrorF("[Memory] Unable to read byte value at address '0x%08X'", self:SafeGetAddress(address))
        return nil
    end
    logger:InfoF("[Memory] Successfully read byte value from address '0x%08X' : %d", self:SafeGetAddress(address), value)
    return value
end
registerLuaFunctionHighlight('SafeReadByte')

-- 
--- SafeWriteByte
--- ∑ Writes a byte to the specified address.
---   Returns true if the write is successful, otherwise false.
--- @param address integer # The memory address to write to.
--- @param value integer # The byte value to write.
--- @return boolean # True if the write is successful, false otherwise.
--
function Memory:SafeWriteByte(address, value)
    local success = writeByte(address, value)
    if not success then
        logger:ErrorF("[Memory] Unable to write byte value to address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    logger:InfoF("[Memory] Successfully wrote byte value " .. tostring(value) .. " to address '0x%08X'", self:SafeGetAddress(address))
    return true
end
registerLuaFunctionHighlight('SafeWriteByte')

-- 
--- SafeAddByte
--- ∑ Adds a value to the current byte value at the given address.
---   If the read and write operations are successful, returns true; otherwise, returns false.
--- @param address integer # The memory address to modify.
--- @param value integer # The value to add to the current byte value.
--- @return boolean # True if the operation succeeds, false otherwise.
--
function Memory:SafeAddByte(address, value)
    local currentValue = self:SafeReadByte(address)
    if currentValue == nil then
        logger:ErrorF("[Memory] Unable to add byte value due to read failure at address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteByte(address, newValue)
    if not success then
        logger:ErrorF("[Memory] Unable to write new byte value to address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    logger:InfoF("[Memory] Successfully added " .. tostring(value) .. " to byte value at address '0x%08X'. New value: %d", self:SafeGetAddress(address), newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddByte')

-- 
--- SafeReadWord
--- ∑ Reads a 2-byte value from the specified address.
---   If successful, returns the word value; otherwise, returns nil.
--- @param address integer # The memory address to read from.
--- @return integer # The 2-byte value read from the address, or nil if the read fails.
--
function Memory:SafeReadWord(address)
    local value = readSmallInteger(address)
    if value == nil then
        logger:ErrorF("[Memory] Unable to read word value at address '0x%08X'", self:SafeGetAddress(address))
        return nil
    end
    logger:InfoF("[Memory] Successfully read word value from address '0x%08X': %d", self:SafeGetAddress(address), value)
    return value
end
registerLuaFunctionHighlight('SafeReadWord')

-- 
--- SafeWriteWord
--- ∑ Writes a 2-byte value to the specified address.
---   Returns true if the write is successful, otherwise false.
--- @param address integer # The memory address to write to.
--- @param value integer # The word value to write.
--- @return boolean # True if the write is successful, false otherwise.
--
function Memory:SafeWriteWord(address, value)
    local success = writeSmallInteger(address, value)
    if not success then
        logger:ErrorF("[Memory] Unable to write word value %d to address '0x%08X'", value, self:SafeGetAddress(address))
        return false
    end
    logger:InfoF("[Memory] Successfully wrote word value %d to address '0x%08X'", value, self:SafeGetAddress(address))
    return true
end
registerLuaFunctionHighlight('SafeWriteWord')

-- 
--- SafeAddWord
--- ∑ Adds a value to the current 2-byte value at the specified address.
---   Returns true if the operation succeeds, otherwise false.
--- @param address integer # The memory address to modify.
--- @param value integer # The value to add.
--- @return boolean # True if the operation succeeds, false otherwise.
--
function Memory:SafeAddWord(address, value)
    local currentValue = self:SafeReadWord(address)
    if currentValue == nil then
        logger:ErrorF("[Memory] Unable to add word value due to read failure at address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteWord(address, newValue)
    if not success then
        logger:ErrorF("[Memory] Unable to write new word value to address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    logger:InfoF("[Memory] Successfully added " .. tostring(value) .. " to word value at address '0x%08X'. New value: %d", self:SafeGetAddress(address), newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddWord')

-- 
--- SafeReadInteger
--- ∑ Reads a 4-byte integer from the specified address.
---   Returns the integer value if the read is successful; otherwise, returns nil.
--- @param address integer # The memory address to read from.
--- @return integer # The integer value read from the address, or nil if the read fails.
--
function Memory:SafeReadInteger(address)
    local value = readInteger(address)
    if value == nil then
        logger:ErrorF("[Memory] Unable to read integer value at address '0x%08X'", self:SafeGetAddress(address))
        return nil
    end
    logger:InfoF("[Memory] Successfully read integer value from address '0x%08X': %d", self:SafeGetAddress(address), value)
    return value
end
registerLuaFunctionHighlight('SafeReadInteger')

-- 
--- SafeWriteInteger
--- ∑ Writes a 4-byte integer to the specified address.
---   Returns true if the write is successful; otherwise, false.
--- @param address integer # The memory address to write to.
--- @param value integer # The integer value to write.
--- @return boolean # True if the write is successful, false otherwise.
--
function Memory:SafeWriteInteger(address, value)
    local success = writeInteger(address, value)
    if not success then
        logger:ErrorF("[Memory] Unable to write integer value %d to address '0x%08X'", value, self:SafeGetAddress(address))
        return false
    end
    return true
end
registerLuaFunctionHighlight('SafeWriteInteger')


-- 
--- SafeAddInteger
--- ∑ Adds a value to the current integer value at the specified address.
---   Returns true if the operation succeeds, otherwise false.
--- @param address integer # The memory address to modify.
--- @param value integer # The value to add.
--- @return boolean # True if the operation succeeds, false otherwise.
--
function Memory:SafeAddInteger(address, value)
    local currentValue = self:SafeReadInteger(address)
    if currentValue == nil then
        logger:ErrorF("[Memory] Unable to add integer value due to read failure at address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteInteger(address, newValue)
    if not success then
        logger:ErrorF("[Memory] Unable to write new integer value to address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    logger:InfoF("[Memory] Successfully added %d to integer value at address '0x%08X'. New value: %d", value, self:SafeGetAddress(address), newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddInteger')

-- 
--- SafeReadQWord
--- ∑ Reads an 8-byte QWord value from the specified address.
---   Returns the value if successful, otherwise returns nil.
--- @param address integer # The memory address to read from.
--- @return integer # The 8-byte value read from the address, or nil if the read fails.
--
function Memory:SafeReadQWord(address)
    local value = readQword(address)
    if value == nil then
        logger:ErrorF("[Memory] Unable to read QWord from address '0x%08X'", self:SafeGetAddress(address))
        return nil
    end
    logger:InfoF("[Memory] Successfully read QWord value %d from address '0x%08X'", value, self:SafeGetAddress(address))
    return value
end
registerLuaFunctionHighlight('SafeReadQWord')

-- 
--- SafeWriteQWord
--- ∑ Writes an 8-byte QWord value to the specified address.
---   Returns true if the write is successful, otherwise false.
--- @param address integer # The memory address to write to.
--- @param value integer # The QWord value to write.
--- @return boolean # True if the write is successful, false otherwise.
--
function Memory:SafeWriteQWord(address, value)
    local success = writeQword(address, value)  -- Assuming writeBytes can handle 8-byte writes for QWords
    if not success then
        logger:ErrorF("[Memory] Unable to write QWord value %d to address '0x%08X'", value, self:SafeGetAddress(address))
        return false
    end
    logger:InfoF("[Memory] Successfully wrote QWord value %d to address '0x%08X'", value, self:SafeGetAddress(address))
    return true
end
registerLuaFunctionHighlight('SafeWriteQWord')

-- 
--- SafeAddQWord
--- ∑ Adds a value to the current QWord value at the specified address.
---   Returns true if the operation succeeds, otherwise false.
--- @param address integer # The memory address to modify.
--- @param value integer # The value to add.
--- @return boolean # True if the operation succeeds, false otherwise.
--
function Memory:SafeAddQWord(address, value)
    local currentValue = self:SafeReadQWord(address)
    if currentValue == nil then
        logger:ErrorF("[Memory] Unable to add QWord value due to read failure at address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteQWord(address, newValue)
    if not success then
        logger:ErrorF("[Memory] Unable to write new QWord value to address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    logger:InfoF("[Memory] Successfully added %d to QWord value at address '0x%08X'. New value: %d", value, self:SafeGetAddress(address), newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddQWord')

-- 
--- SafeReadFloat
--- ∑ Reads a float value from the specified memory address.
---   If the read is successful, it returns the float value; otherwise, it returns nil.
--- @param address integer # The memory address to read from.
--- @return float # The float value read from the address, or nil if the read fails.
--
function Memory:SafeReadFloat(address)
    local value = readFloat(address)
    if value == nil then
        logger:ErrorF("[Memory] Unable to read float value at address '0x%08X'", self:SafeGetAddress(address))
        return nil
    end
    logger:InfoF("[Memory] Successfully read float value from address '0x%08X': %f", self:SafeGetAddress(address), value)
    return value
end
registerLuaFunctionHighlight('SafeReadFloat')

-- 
--- SafeWriteFloat
--- ∑ Writes a float value to the specified memory address.
---   Returns true if the write operation succeeds, otherwise false.
--- @param address integer # The memory address to write to.
--- @param value float # The float value to write to the address.
--- @return boolean # True if the write is successful, false otherwise.
--
function Memory:SafeWriteFloat(address, value)
    local success = writeFloat(address, value)
    if not success then
        logger:ErrorF("[Memory] Unable to write float value to address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    logger:InfoF("[Memory] Successfully wrote float value %f to address '0x%08X'", value, self:SafeGetAddress(address))
    return true
end
registerLuaFunctionHighlight('SafeWriteFloat')

-- 
--- SafeAddFloat
--- ∑ Adds a value to the current float value at the specified address.
---   If the read and write operations are successful, returns true; otherwise, false.
--- @param address integer # The memory address to modify.
--- @param value float # The value to add to the current float value.
--- @return boolean # True if the addition is successful, false otherwise.
--
function Memory:SafeAddFloat(address, value)
    local currentValue = self:SafeReadFloat(address)
    if currentValue == nil then
        logger:ErrorF("[Memory] Unable to add float value due to read failure at address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteFloat(address, newValue)
    if not success then
        logger:ErrorF("[Memory] Unable to write new float value to address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    logger:InfoF("[Memory] Successfully added %f to float value at address '0x%08X'. New value: %f", value, self:SafeGetAddress(address), newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddFloat')

-- 
--- SafeReadDouble
--- ∑ Reads a double value from the specified memory address.
---   If the read is successful, it returns the double value; otherwise, it returns nil.
--- @param address integer # The memory address to read from.
--- @return double # The double value read from the address, or nil if the read fails.
--
function Memory:SafeReadDouble(address)
    local value = readDouble(address)
    if value == nil then
        logger:ErrorF("[Memory] Unable to read double value at address '0x%08X'", self:SafeGetAddress(address))
        return nil
    end
    logger:InfoF("[Memory] Successfully read double value from address '0x%08X': %f", self:SafeGetAddress(address), value)
    return value
end
registerLuaFunctionHighlight('SafeReadDouble')

-- 
--- SafeWriteDouble
--- ∑ Writes a double value to the specified memory address.
---   Returns true if the write operation is successful, otherwise false.
--- @param address integer # The memory address to write to.
--- @param value double # The double value to write to the address.
--- @return boolean # True if the write is successful, false otherwise.
--
function Memory:SafeWriteDouble(address, value)
    local success = writeDouble(address, value)
    if not success then
        logger:ErrorF("[Memory] Unable to write double value to address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    logger:InfoF("[Memory] Successfully wrote double value %f to address '0x%08X'", value, self:SafeGetAddress(address))
    return true
end
registerLuaFunctionHighlight('SafeWriteDouble')

-- 
--- SafeAddDouble
--- ∑ Adds a value to the current double value at the specified address.
---   If the read and write operations are successful, returns true; otherwise, false.
--- @param address integer # The memory address to modify.
--- @param value double # The value to add to the current double value.
--- @return boolean # True if the operation is successful, false otherwise.
--
function Memory:SafeAddDouble(address, value)
    local currentValue = self:SafeReadDouble(address)
    if currentValue == nil then
        logger:ErrorF("[Memory] Unable to add double value due to read failure at address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteDouble(address, newValue)
    if not success then
        logger:ErrorF("[Memory] Unable to write new double value to address '0x%08X'", self:SafeGetAddress(address))
        return false
    end
    logger:InfoF("[Memory] Successfully added %.2f to address '0x%08X'. Original value: %.2f, New value: %.2f", value, self:SafeGetAddress(address), currentValue, newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddDouble')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Memory