local NAME = "CTI.Utility"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.2"
local DESCRIPTION = "Cheat Table Interface (Utility)"

--[[
    Script Name: Module.Utility.lua
    Description: The Utility Module is a core component of the Cheat Table
                 Interface (CTI) framework, designed to enhance Cheat Engine
                 scripts with robust utility functions. It provides essential
                 features such as memory manipulation, automated script execution,
                 message dialogs, and various helper functions for a streamlined
                 cheat development process.
    
    Version History:
    -----------------------------------------------------------------------------
    Version | Date         | Author          | Changes
    -----------------------------------------------------------------------------
    1.0.0   | ----------   | Leunsel,LeFiXER | Initial release.
    1.0.1   | ----------   | Leunsel         | -
    1.0.2   | 14.02.2025   | Leunsel,LeFiXER | Added Version History
    -----------------------------------------------------------------------------
    
    Notes:
    - Features:
        - Memory Management:
            * Read and write values of different data types (Byte, Integer, Float, Double).
            * Safely modify memory values with error handling.
        - Script Execution:
            * Enable or disable scripts asynchronously.
            * Support for automatic script deactivation.
        - File Integrity Verification:
            * Validate game executables using MD5 hash comparison.
        - Pointer Resolution:
            * Resolve complex multi-level pointer paths.
        - User Interface Functions:
            * Display informational, warning, error, and confirmation dialogs.
            * Open external links with confirmation prompts.
        - Custom Data Type Registration:
            * Register new memory value types, such as Military Hours for Dying Light.
--]]

--
--- This checks if the required modules (Helper, Logger, FormManager) are already loaded.
--- If not, it attempts to load them using the CETrequire function.
----------
if not Helper then
    CETrequire('Module.Helper')
end

if not Logger then
    CETrequire('Module.Logger')
end

if not FormManager then
    CETrequire('Module.FormManager')
end

--
--- Several configuration properties that can be customized.
--- Set within the Table Lua Script and passed to the constructor of the class.
----------
Utility = {
    Author = "",                      --- Author of the table
    ProcessName = "",                 --- Name of the process to attach to
    GameVersion = "",                 --- Version of the game being targeted
    MD5Hash = "",                     --- Supposed MD5 File Hash of the game's executable file
    GameID = "",                      --- Unique identifier for the game
    TableTitle = "",                  --- Title of the Cheat Table
    TableVersion = "",                --- Version of the Cheat Table
    Signature = "",                   --- Table signature for identification
    Slogan = "",                      --- Slogan for the table (displayed on the UI)
    DefaultTheme = "",                --- Default theme for the table interface
    IsRelease = false,                --- Whether the table is in release mode
    AutoDisableTimerInterval = 100,   --- Interval in milliseconds for auto-disable timers
    AutoAttachTimerInterval = 100,    --- Interval in milliseconds for auto-attach timers
    AutoAttachTimerTicks = 0,         --- Number of ticks for the auto-attach timer
    AutoAttachTimerTickMax = 5000     --- Max number of ticks before stopping the auto-attach timer
}

--
--- Set the metatable for the Utility object so that it behaves as an "object-oriented class".
----------
Utility.__index = Utility

--
--- This function creates a new instance of the Utility object.
--- It initializes the object with the properties passed as arguments and sets up
--- the FormManager and Logger components.
----------
function Utility:new(properties)
    local obj = setmetatable({}, self)
    for key, value in pairs(properties) do
        if self[key] ~= nil then
            obj[key] = value
        end
    end
    obj.formManager = FormManager:new(properties)
    obj.logger = Logger:new()
    return obj
end

--
--- Auto Disable
--- Automatically disables a memory record after a specified interval.
--- If called from a non-main thread, the function ensures thread safety by synchronizing execution.
--- @param id: The ID of the memory record to disable.
--- @param customInterval: (Optional) Custom time interval in milliseconds before disabling.
---                        Defaults to `self.AutoDisableTimerInterval` if not provided.
--- @return None.
----------
function Utility:AutoDisable(id, customInterval)
    if not inMainThread() then
        synchronize(function()
            self:AutoDisable(id, customInterval)
        end)
        return
    end
    checkSynchronize()
    local function autoDisableTimer_tick(timer)
        timer.destroy()
        local mr = AddressList.getMemoryRecordByID(id)
        if mr ~= nil and mr.Active then
            while mr.Async and mr.AsyncProcessing do
                sleep(0)
            end
            mr.Active = false
            while mr.Async and mr.AsyncProcessing do
                checkSynchronize()
                MainForm.repaint()
                sleep(0)
            end
        end
    end
    local autoDisableTimer = createTimer(MainForm)
    autoDisableTimer.Interval = customInterval or self.AutoDisableTimerInterval
    autoDisableTimer.OnTimer = autoDisableTimer_tick
end
registerLuaFunctionHighlight('AutoDisable')

--
--- Sets all memory records of type "Auto Assembler" in the address list to async mode.
--- This ensures the scripts execute asynchronously.
---     [+] Disclaimer: Script(s) need(s) to support async mode!
--- @return None.
----------
function Utility:SetAllScriptsToAsync()
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr.Type == vtAutoAssembler and not mr.Async then
            mr.Async = true
        end
    end
end
registerLuaFunctionHighlight('SetAllScriptsToAsync')

--
--- Sets all memory records of type "Auto Assembler" in the address list to non-async mode.
--- This ensures the scripts execute synchronously.
--- @return None.
----------
function Utility:SetAllScriptsToNotAsync()
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr.Type == vtAutoAssembler and mr.Async then
            mr.Async = false
        end
    end
end
registerLuaFunctionHighlight('SetAllScriptsToNotAsync')

--
--- Message Dialog Preset - Info
--- Displays an informational message dialog to the user.
--- @param message: The message text to display in the dialog.
--- @return None.
----------
function Utility:ShowInfo(message)
    messageDialog(message, mtInformation, mbOK)
end
registerLuaFunctionHighlight('ShowInfo')

--
--- Message Dialog Preset - Warning
--- Displays a warning message dialog to the user.
--- @param message: The message text to display in the dialog.
--- @return None.
----------
function Utility:ShowWarning(message)
    messageDialog(message, mtWarning, mbOK)
end
registerLuaFunctionHighlight('ShowWarning')

--
--- Message Dialog Preset - Error
--- Displays an error message dialog to the user.
--- @param message: The message text to display in the dialog.
--- @return None.
----------
function Utility:ShowError(message)
    messageDialog(message, mtError, mbOK)
end
registerLuaFunctionHighlight('ShowError')

--
--- Message Dialog Preset - Confirmation
--- Displays a confirmation message dialog to the user with "Yes" and "No" options.
--- @param message: The message text to display in the dialog.
--- @return true if the user selects "Yes", false otherwise.
----------
function Utility:ShowConfirmation(message)
    local result = messageDialog(message, mtConfirmation, mbYes, mbNo)
    return result == mrYes
end
registerLuaFunctionHighlight('ShowConfirmation')

--
--- Verifies the integrity of a file by comparing its MD5 hash to the provided hash.
--- If the hashes do not match, a warning is displayed to alert the user.
--- @param hash string - The expected MD5 hash of the file.
--- @return None.
----------
function Utility:VerifyFileHash()
    local fileHash = md5file(helper:getGameModulePathToFile())
    if self.MD5Hash ~= fileHash then
        self:ShowWarning("File Hash Mismatch!\n\nExpected: " .. self.MD5Hash .. "\nReceived: " .. fileHash .. "\n\nThe Cheat Table might not be compatible with the current game version. Use at your own risk.")
    end
end
registerLuaFunctionHighlight('VerifyFileHash')

--
--- Handler: BYTE Read
--- Reads a single byte from the specified address.
--- @param address: The memory address to read from.
--- @return The byte value, or nil if the read fails.
----------
function Utility:SafeReadByte(address)
    local value = readBytes(address, 1)
    if value == nil then
        logger:Error("Unable to read byte value at address " .. address)
        return nil
    end
    return value
end
registerLuaFunctionHighlight('SafeReadByte')

--
--- Handler: BYTE Write
--- Writes a single byte to the specified address.
--- @param address: The memory address to write to.
--- @param value: The byte value to write.
--- @return true if the write succeeds, false otherwise.
----------
function Utility:SafeWriteByte(address, value)
    local success = writeBytes(address, value)
    if not success then
        logger:Error("Unable to write byte value to address " .. address)
        return false
    end
    return true
end
registerLuaFunctionHighlight('SafeWriteByte')

--
--- Handler: BYTE Add
--- Adds a value to the current byte value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
----------
function Utility:SafeAddByte(address, value)
    local currentValue = self:SafeReadByte(address)
    if currentValue == nil then
        logger:Error("Unable to add byte value due to read failure at address " .. address)
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteByte(address, newValue)
    if not success then
        logger:Error("Unable to write new byte value to address " .. address)
        return false
    end
    return true
end
registerLuaFunctionHighlight('SafeAddByte')

--
--- Handler: INTEGER Read
--- Reads an integer from the specified address.
--- @param address: The memory address to read from.
--- @return The integer value, or nil if the read fails.
----------
function Utility:SafeReadInteger(address)
    local value = readInteger(address)
    if value == nil then
        logger:Error("Unable to read integer value at address " .. address)
        return nil
    end
    return value
end
registerLuaFunctionHighlight('SafeReadInteger')

--
--- Handler: INTEGER Write
--- Writes an integer to the specified address.
--- @param address: The memory address to write to.
--- @param value: The integer value to write.
--- @return true if the write succeeds, false otherwise.
----------
function Utility:SafeWriteInteger(address, value)
    local success = writeInteger(address, value)
    if not success then
        logger:Error("Unable to write integer value to address " .. address)
        return false
    end
    return true
end
registerLuaFunctionHighlight('SafeWriteInteger')

--
--- Handler: INTEGER Add
--- Adds a value to the current integer value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
----------
function Utility:SafeAddInteger(address, value)
    local currentValue = self:SafeReadInteger(address)
    if currentValue == nil then
        logger:Error("Unable to add integer value due to read failure at address " .. address)
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteInteger(address, newValue)
    if not success then
        logger:Error("Unable to write new integer value to address " .. address)
        return false
    end
    return true
end
registerLuaFunctionHighlight('SafeAddInteger')

--
--- Handler: FLOAT Read
--- Reads a float from the specified address.
--- @param address: The memory address to read from.
--- @return The float value, or nil if the read fails.
----------
function Utility:SafeReadFloat(address)
    local value = readFloat(address)
    if value == nil then
        logger:Error("Unable to read float value at address " .. address)
        return nil
    end
    return value
end
registerLuaFunctionHighlight('SafeReadFloat')
--
--- Handler: FLOAT Write
--- Writes a float to the specified address.
--- @param address: The memory address to write to.
--- @param value: The float value to write.
--- @return true if the write succeeds, false otherwise.
----------
function Utility:SafeWriteFloat(address, value)
    local success = writeFloat(address, value)
    if not success then
        logger:Error("Unable to write float value to address " .. address)
        return false
    end
    return true
end
registerLuaFunctionHighlight('SafeWriteFloat')

--
--- Handler: FLOAT Add
--- Adds a value to the current float value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
----------
function Utility:SafeAddFloat(address, value)
    local currentValue = self:SafeReadFloat(address)
    if currentValue == nil then
        logger:Error("Unable to add float value due to read failure at address " .. address)
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteFloat(address, newValue)
    if not success then
        logger:Error("Unable to write new float value to address " .. address)
        return false
    end
    return true
end
registerLuaFunctionHighlight('SafeAddFloat')

--
--- Handler: DOUBLE Read
--- Reads a double from the specified address.
--- @param address: The memory address to read from.
--- @return The double value, or nil if the read fails.
----------
function Utility:SafeReadDouble(address)
    local value = readDouble(address)
    if value == nil then
        logger:Error("Unable to read double value at address " .. address)
        return nil
    end
    return value
end
registerLuaFunctionHighlight('SafeReadDouble')

--
--- Handler: DOUBLE Write
--- Writes a double to the specified address.
--- @param address: The memory address to write to.
--- @param value: The double value to write.
--- @return true if the write succeeds, false otherwise.
----------
function Utility:SafeWriteDouble(address, value)
    local success = writeDouble(address, value)
    if not success then
        logger:Error("Unable to write double value to address " .. address)
        return false
    end
    return true
end
registerLuaFunctionHighlight('SafeWriteDouble')

--
--- Handler: DOUBLE Add
--- Adds a value to the current double value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
----------
function Utility:SafeAddDouble(address, value)
    local currentValue = self:SafeReadDouble(address)
    if currentValue == nil then
        logger:Error("Unable to add double value due to read failure at address " .. address)
        return false
    end
    local newValue = currentValue + value
    local success = self:SafeWriteDouble(address, newValue)
    if not success then
        logger:Error("Unable to write new double value to address " .. address)
        return false
    end
    return true
end
registerLuaFunctionHighlight('SafeAddDouble')

--
--- Conversion Table(s)
--- Registers a custom memory value type for "Military Hours" used in the game "Dying Light."
--- Converts a 4-byte floating-point value representing in-game time into military time format (0-2400).
--- Handles both reading (bytes to value) and writing (value to bytes).
---
--- Conversion Details:
--- - In-game time (float) is scaled by 24 (hours in a day) and then by 100 (to represent military time).
--- - Reverse scaling is applied for writing values back to memory.
--- @return None.
----------
function Utility:RegisterTimeTypes()
    local TypeName = 'Military Hours'
    local ByteCount = 4
    local IsFloat = true
    local function BytesToValue(...)
        local bytes = { ... }
        return ((byteTableToFloat({ bytes[1], bytes[2], bytes[3], bytes[4] }) * 24) * 100)
    end
    local function ValueToBytes(value)
        local bytes = floatToByteTable((value / 24) / 100)
        return bytes[1], bytes[2], bytes[3], bytes[4]
    end
    registerCustomTypeLua(TypeName, ByteCount, BytesToValue, ValueToBytes, IsFloat)
end
registerLuaFunctionHighlight('RegisterTimeTypes')

--
--- Resolves a multi-level pointer path to its final address.
--- Starts from a base address (or symbol) and iteratively applies offsets.
---     [+] Offset-List should end with 0x0
--- @param baseAddress: A string representing the base address or symbol name.
--- @param offsets: A table (array) of numerical offsets to apply sequentially.
--- @return The final resolved address, or nil if an error occurs during resolution.
----------
function Utility:ResolvePointerPath(baseAddress, offsets)
    local address = getAddressSafe(baseAddress)
    if not address then
        logger:Error("Base address or symbol '" .. baseAddress .. "' not found.")
        return nil
    end
    logger:Debug("Starting base address: " .. string.format("0x%X", address))
    for i, offset in ipairs(offsets) do
        if type(offset) ~= "number" then
            logger:Error("Offset must be a number. Offset " .. i .. " is not a number.", {offset = offset, index = i})
            return nil
        end
        logger:Debug("Applying offset " .. i .. ": " .. string.format("0x%X", offset))
        local value = readPointer(address)
        if not value then
            logger:Error("Unable to read memory at address " .. string.format("0x%X", address))
            return nil
        end
        logger:Debug("Value read from address " .. string.format("0x%X", address) .. ": " .. string.format("0x%X", value))
        address = value + offset
        logger:Debug("New address after applying offset " .. i .. ": " .. string.format("0x%X", address))
    end
    logger:Debug("Final resolved address: " .. string.format("0x%X", address))
    return address
end
registerLuaFunctionHighlight('ResolvePointerPath')

--
--- Opens a specified link after confirming with the user.
--- @param link: The URL or link to open.
--- @return None.
----------
function Utility:OpenLink(link)
    local result = messageDialog(
        "Do you really want to open this link?\n" .. link,
        mtConfirmation,
        mbYes, mbNo)
    if result == mrYes then
        ShellExecute(link)
    end
end
registerLuaFunctionHighlight('OpenLink')

--
--- Displays a startup message dialog with the provided string.
--- @param str: The message to display.
--- @return None.
----------
function Utility:StartupMessage(str)
    if str then
        messageDialog(str, 2)
    end
end
registerLuaFunctionHighlight('StartupMessage')

--
--- Attaches the program to a specified process by name.
--- If no process name is provided, it will use the default stored process name.
--- @param processName: The name of the process to attach to.
--- @return None.
----------
function Utility:AttachToProcess(processName)
    processName = processName or self.ProcessName
    local processID = getProcessIDFromProcessName(processName)
    if processID ~= nil then
        openProcess(processID)
    else
        -- messageDialog("Process not found: " .. processName, mtError, mbOK)
    end
end
registerLuaFunctionHighlight('AttachToProcess')

--
--- Prompts the user to confirm if they want to terminate the currently attached process.
--- If confirmed, the process is terminated.
--- @return None.
----------
function Utility:CloseProcess()
    local processID = getOpenedProcessID()
    if processID == 0 then
        messageDialog("No process is currently attached.", mtError, mbOK)
        return
    end
    local processName = process
    local message = string.format("Do you really want to terminate the process %s (PID: %d)?", processName, processID)
    local result = messageDialog(message, mtConfirmation, mbYes, mbNo)
    if result == mrYes then
        local command = string.format("taskkill /PID %d /F", processID)
        os.execute(command)
    end
end
registerLuaFunctionHighlight('CloseProcess')

--
--- Automatically attempts to attach to a process at regular intervals until successful.
--- Once attached, the table setup is initialized.
--- @param processName: The name of the process to auto-attach to.
--- @return None. 
----------
function Utility:AutoAttach(processName)
    processName = processName or self.ProcessName
    local function autoAttachTimer_tick(timer)
        if self.AutoAttachTimerTickMax > 0 and self.AutoAttachTimerTicks >= self.AutoAttachTimerTickMax then
            timer.destroy()
        end
        local processID = getProcessIDFromProcessName(processName)
        if processID ~= nil then
            timer.destroy()
            openProcess(processID)
            self:VerifyFileHash()
            self:SetupTable()
        end
        self.AutoAttachTimerTicks = self.AutoAttachTimerTicks + 1
    end
    local autoAttachTimer = createTimer(MainForm)
    autoAttachTimer.Interval = self.AutoAttachTimerInterval
    autoAttachTimer.OnTimer = autoAttachTimer_tick
end
registerLuaFunctionHighlight('AutoAttach')

--
--- Updates the main form's window title to reflect the current table, game, and Cheat Engine version.
--- @return None.
----------
function Utility:SetTitle()
    if not inMainThread() then
        synchronize(function()
            self:SetTitle()
        end)
        return
    end
    local tableTitle = self.TableTitle or "TableTitle"
    local tableVersion = self.TableVersion or "TableVersion"
    local gameVersion = self.GameVersion or Helper:getFileVersionStr(Helper:getGameModulePathToFile()) or "GameVersion"
    local registrySizeStr = Helper:getRegistrySizeStr() or ""
    local ceRegistrySizeStr = (cheatEngineIs64Bit() and "(x64)") or "(x32)"
    local titleStr = string.format(
        "%s %s V:%s — CET V:%s — CE %s V:%s",
        tableTitle,
        registrySizeStr,
        gameVersion,
        tableVersion,
        ceRegistrySizeStr,
        getCEVersion()
    )
    getMainForm().Caption = titleStr
    -- return titleStr
end
registerLuaFunctionHighlight('SetTitle')

--
--- Initializes and configures the table by setting up form management, applying themes, 
--- and configuring UI components like the table signature and slogan.
--- @return None.
----------
function Utility:SetupTable()
    if not formManager then
        formManager = FormManager:new({ Signature = self.Signature, Slogan = self.Slogan })
    end
    getMainForm().Show()
    formManager:DisableHeaderSorting()
    formManager:HideSignatureControls()
    formManager:EnableCompactMode()
    formManager:CreateSloganStr(self.Slogan)
    formManager:CreateSignatureStr(self.Signature)
    formManager:LoadThemes()
    formManager:ApplyTheme(self.DefaultTheme)
    self:SetTitle()
end
registerLuaFunctionHighlight('SetupTable')

return Utility
