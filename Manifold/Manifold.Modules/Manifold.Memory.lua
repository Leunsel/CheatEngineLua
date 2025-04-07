local NAME = "Manifold.Memory.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Manifold Framework Memory"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.
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
--- @return table  {name, version, author, description}
--
function Memory:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
--- Handler: Safe Address Read
--- ∑ Retrieves the address corresponding to the given symbol (AddressString), 
---   and returns the address as an integer, or nil if not found.
--- @param AddressString: string The symbol or module name to query for the address.
--- @param local: boolean Optional flag to query the symbol table of the CE process (defaults to false).
--- @return integer The address corresponding to the AddressString, or nil if not found.
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
--- Handler: BYTE Read
--- ∑ Reads a single byte from the specified address.
--- @param address: The memory address to read from.
--- @return The byte value, or nil if the read fails.
--
function Memory:SafeReadByte(address)
    local value = readByte(address)
    if value == nil then
        logger:Error("[Memory] Unable to read byte value at address " .. self:SafeGetAddress(address))
        return nil
    end
    logger:Info("[Memory] Successfully read byte value from address " .. self:SafeGetAddress(address) .. ": " .. value)
    return value
end
registerLuaFunctionHighlight('SafeReadByte')

--
--- Handler: BYTE Write
--- ∑ Writes a single Byte to the specified address.
--- @param address: The memory address to write to.
--- @param value: The byte value to write.
--- @return true if the write succeeds, false otherwise.
--
function Memory:SafeWriteByte(address, value)
    local success = writeByte(address, value)
    if not success then
        logger:Error("[Memory] Unable to write byte value to address " .. self:SafeGetAddress(address))
        return false
    end
    logger:Info("[Memory] Successfully wrote byte value " .. tostring(value) .. " to address " .. self:SafeGetAddress(address))
    return true
end
registerLuaFunctionHighlight('SafeWriteByte')

--
--- Handler: BYTE Add
--- ∑ Adds a value to the current Byte value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
--
function Memory:SafeAddByte(address, value)
    local currentValue = self:SafeReadByte(address)
    if currentValue == nil then
        logger:Error("[Memory] Unable to add byte value due to read failure at address " .. self:SafeGetAddress(address))
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteByte(address, newValue)
    if not success then
        logger:Error("[Memory] Unable to write new byte value to address " .. self:SafeGetAddress(address))
        return false
    end
    logger:Info("[Memory] Successfully added " .. tostring(value) .. " to byte value at address " .. self:SafeGetAddress(address) .. ". New value: " .. newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddByte')

--
--- Handler: WORD Read
--- ∑ Reads a single 2-Byte from the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
--
function Memory:SafeReadWord(address)
    local value = readSmallInteger(address)
    if value == nil then
        logger:Error("[Memory] Unable to read word value at address " .. self:SafeGetAddress(address))
        return nil
    end
    logger:Info("[Memory] Successfully read word value from address " .. self:SafeGetAddress(address) .. ": " .. value)
    return value
end
registerLuaFunctionHighlight('SafeReadWord')

--
--- Handler: WORD Write
--- ∑ Writes a single 2-Byte value to the specified address.
--- @param address: The memory address to write to.
--- @param value: The word value to write.
--- @return true if the write succeeds, false otherwise.
--
function Memory:SafeWriteWord(address, value)
    local success = writeSmallInteger(address, value)
    if not success then
        logger:Error("[Memory] Unable to write word value " .. tostring(value) .. " to address " .. self:SafeGetAddress(address))
        return false
    end
    logger:Info("[Memory] Successfully wrote word value " .. tostring(value) .. " to address " .. self:SafeGetAddress(address))
    return true
end
registerLuaFunctionHighlight('SafeWriteWord')

--
--- Handler: WORD Add
--- ∑ Adds a value to the current word value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
--
function Memory:SafeAddWord(address, value)
    local currentValue = self:SafeReadWord(address)
    if currentValue == nil then
        logger:Error("[Memory] Unable to add word value due to read failure at address " .. self:SafeGetAddress(address))
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteWord(address, newValue)
    if not success then
        logger:Error("[Memory] Unable to write new word value to address " .. self:SafeGetAddress(address))
        return false
    end
    logger:Info("[Memory] Successfully added " .. tostring(value) .. " to word value at address " .. self:SafeGetAddress(address) .. ". New value: " .. newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddWord')

--
--- Handler: INTEGER Read
--- ∑ Reads an integer from the specified address.
--- @param address: The memory address to read from.
--- @return The integer value, or nil if the read fails.
--
function Memory:SafeReadInteger(address)
    local value = readInteger(address)
    if value == nil then
        logger:Error("[Memory] Unable to read integer value at address " .. self:SafeGetAddress(address))
        return nil
    end
    logger:Info("[Memory] Successfully read integer value from address " .. self:SafeGetAddress(address) .. ": " .. value)
    return value
end
registerLuaFunctionHighlight('SafeReadInteger')

--
--- Handler: INTEGER Write
--- ∑ Writes an integer to the specified address.
--- @param address: The memory address to write to.
--- @param value: The integer value to write.
--- @return true if the write succeeds, false otherwise.
--
function Memory:SafeWriteInteger(address, value)
    local success = writeInteger(address, value)
    if not success then
        logger:Error("[Memory] Unable to write integer value to address " .. self:SafeGetAddress(address))
        return false
    end
    return true
end
registerLuaFunctionHighlight('SafeWriteInteger')

--
--- Handler: INTEGER Add
--- ∑ Adds a value to the current integer value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
--
function Memory:SafeAddInteger(address, value)
    local currentValue = self:SafeReadInteger(address)
    if currentValue == nil then
        logger:Error("[Memory] Unable to add integer value due to read failure at address " .. self:SafeGetAddress(address))
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteInteger(address, newValue)
    if not success then
        logger:Error("[Memory] Unable to write new integer value to address " .. self:SafeGetAddress(address))
        return false
    end
    logger:Info("[Memory] Successfully added " .. tostring(value) .. " to integer value at address " .. self:SafeGetAddress(address) .. ". New value: " .. newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddInteger')

--
--- Handler: QWORD Read
--- ∑ Reads an 8-Byte value from the specified address.
--- @param address: The memory address to read from.
--- @return value: The QWord value read from the address or nil if the read fails.
--
function Memory:SafeReadQWord(address)
    local value = readQword(address)
    if value == nil then
        logger:Error("[Memory] Unable to read QWord from address " .. self:SafeGetAddress(address))
        return nil
    end
    logger:Info("[Memory] Successfully read QWord value " .. tostring(value) .. " from address " .. self:SafeGetAddress(address))
    return value
end
registerLuaFunctionHighlight('SafeReadQWord')

--
--- Handler: QWORD Write
--- ∑ Writes an 8-Byte value to the specified address.
--- @param address: The memory address to write to.
--- @param value: The QWord value to write.
--- @return true if the write succeeds, false otherwise.
--
function Memory:SafeWriteQWord(address, value)
    local success = writeQword(address, value)  -- Assuming writeBytes can handle 8-byte writes for QWords
    if not success then
        logger:Error("[Memory] Unable to write QWord value " .. tostring(value) .. " to address " .. self:SafeGetAddress(address))
        return false
    end
    logger:Info("[Memory] Successfully wrote QWord value " .. tostring(value) .. " to address " .. self:SafeGetAddress(address))
    return true
end
registerLuaFunctionHighlight('SafeWriteQWord')

--
--- Handler: QWORD Add
--- ∑ Adds a value to the current QWord value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
--
function Memory:SafeAddQWord(address, value)
    local currentValue = self:SafeReadQWord(address)
    if currentValue == nil then
        logger:Error("[Memory] Unable to add QWord value due to read failure at address " .. self:SafeGetAddress(address))
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteQWord(address, newValue)
    if not success then
        logger:Error("[Memory] Unable to write new QWord value to address " .. self:SafeGetAddress(address))
        return false
    end
    logger:Info("[Memory] Successfully added " .. tostring(value) .. " to QWord value at address " .. self:SafeGetAddress(address) .. ". New value: " .. newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddQWord')

--
--- Handler: FLOAT Read
--- ∑ Reads a float from the specified address.
--- @param address: The memory address to read from.
--- @return The float value, or nil if the read fails.
--
function Memory:SafeReadFloat(address)
    local value = readFloat(address)
    if value == nil then
        logger:Error("[Memory] Unable to read float value at address " .. self:SafeGetAddress(address))
        return nil
    end
    logger:Info("[Memory] Successfully read float value from address " .. self:SafeGetAddress(address) .. ": " .. value)
    return value
end
registerLuaFunctionHighlight('SafeReadFloat')
--
--- Handler: FLOAT Write
--- ∑ Writes a float to the specified address.
--- @param address: The memory address to write to.
--- @param value: The float value to write.
--- @return true if the write succeeds, false otherwise.
--
function Memory:SafeWriteFloat(address, value)
    local success = writeFloat(address, value)
    if not success then
        logger:Error("[Memory] Unable to write float value to address " .. self:SafeGetAddress(address))
        return false
    end
    logger:Info("[Memory] Successfully wrote float value " .. tostring(value) .. " to address " .. self:SafeGetAddress(address))
    return true
end
registerLuaFunctionHighlight('SafeWriteFloat')

--
--- Handler: FLOAT Add
--- ∑ Adds a value to the current float value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
--
function Memory:SafeAddFloat(address, value)
    local currentValue = self:SafeReadFloat(address)
    if currentValue == nil then
        logger:Error("[Memory] Unable to add float value due to read failure at address " .. self:SafeGetAddress(address))
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteFloat(address, newValue)
    if not success then
        logger:Error("[Memory] Unable to write new float value to address " .. self:SafeGetAddress(address))
        return false
    end
    logger:Info("[Memory] Successfully added " .. tostring(value) .. " to float value at address " .. self:SafeGetAddress(address) .. ". New value: " .. newValue)
    return true
end
registerLuaFunctionHighlight('SafeAddFloat')

--
--- Handler: DOUBLE Read
--- ∑ Reads a double from the specified address.
--- @param address: The memory address to read from.
--- @return The double value, or nil if the read fails.
--
function Memory:SafeReadDouble(address)
    local value = readDouble(address)
    if value == nil then
        logger:Error("[Memory] Unable to read double value at address " .. self:SafeGetAddress(address))
        return nil
    end
    logger:Info("[Memory] Successfully read double value from address " .. self:SafeGetAddress(address) .. ": " .. value)
    return value
end
registerLuaFunctionHighlight('SafeReadDouble')

--
--- Handler: DOUBLE Write
--- ∑ Writes a double to the specified address.
--- @param address: The memory address to write to.
--- @param value: The double value to write.
--- @return true if the write succeeds, false otherwise.
--
function Memory:SafeWriteDouble(address, value)
    local success = writeDouble(address, value)
    if not success then
        logger:Error("[Memory] Unable to write double value to address " .. self:SafeGetAddress(address))
        return false
    end
    logger:Info("[Memory] Successfully wrote double value " .. tostring(value) .. " to address " .. self:SafeGetAddress(address))
    return true
end
registerLuaFunctionHighlight('SafeWriteDouble')

--
--- Handler: DOUBLE Add
--- ∑ Adds a value to the current double value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
--
function Memory:SafeAddDouble(address, value)
    local currentValue = self:SafeReadDouble(address)
    if currentValue == nil then
        logger:Error("[Memory] Unable to add double value due to read failure at address " .. self:SafeGetAddress(address))
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteDouble(address, newValue)
    if not success then
        logger:Error("[Memory] Unable to write new double value to address " .. self:SafeGetAddress(address))
        return false
    end
    logger:Info(string.format("[Memory] Successfully added %.2f to address %s. Original value: %.2f, New value: %.2f", value, self:SafeGetAddress(address), currentValue, newValue))
    return true
end
registerLuaFunctionHighlight('SafeAddDouble')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Memory
