local NAME = "CTI.Utility"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.1"
local DESCRIPTION = "Cheat Table Interface (Utility)"

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

local helper = Helper:new({})

--
--- Several configuration properties that can be customized.
--- Set within the Table Lua Script and passed to the constructor of the class.
----------
Utility = {
    Author = "",                      --- Author of the table
    ProcessName = "",                 --- Name of the process to attach to
    GameVersion = "",                 --- Version of the game being targeted
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
function Utility:autoDisable(id, customInterval)
    if not inMainThread() then
        synchronize(function()
            self:autoDisable(id, customInterval)
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

--
--- Sets all memory records of type "Auto Assembler" in the address list to async mode.
--- This ensures the scripts execute asynchronously.
---     [+] Disclaimer: Script(s) need(s) to support async mode!
--- @return None.
----------
function Utility:setAllScriptsToAsync()
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr.Type == vtAutoAssembler and not mr.Async then
            mr.Async = true
        end
    end
end

--
--- Sets all memory records of type "Auto Assembler" in the address list to non-async mode.
--- This ensures the scripts execute synchronously.
--- @return None.
----------
function Utility:setAllScriptsToNotAsync()
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr.Type == vtAutoAssembler and mr.Async then
            mr.Async = false
        end
    end
end

--
--- Message Dialog Preset - Info
--- Displays an informational message dialog to the user.
--- @param message: The message text to display in the dialog.
--- @return None.
----------
function Utility:ShowInfo(message)
    messageDialog(message, mtInformation, mbOK)
end

--
--- Message Dialog Preset - Warning
--- Displays a warning message dialog to the user.
--- @param message: The message text to display in the dialog.
--- @return None.
----------
function Utility:ShowWarning(message)
    messageDialog(message, mtWarning, mbOK)
end

--
--- Message Dialog Preset - Error
--- Displays an error message dialog to the user.
--- @param message: The message text to display in the dialog.
--- @return None.
----------
function Utility:ShowError(message)
    messageDialog(message, mtError, mbOK)
end

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

--
--- Handler: BYTE Read
--- Reads a single byte from the specified address.
--- @param address: The memory address to read from.
--- @return The byte value, or nil if the read fails.
----------
function Utility:safeReadByte(address)
    local value = readBytes(address, 1)
    if value == nil then
        logger:error("Unable to read byte value at address " .. address)
        return nil
    end
    return value
end

--
--- Handler: BYTE Write
--- Writes a single byte to the specified address.
--- @param address: The memory address to write to.
--- @param value: The byte value to write.
--- @return true if the write succeeds, false otherwise.
----------
function Utility:safeWriteByte(address, value)
    local success = writeBytes(address, value)
    if not success then
        logger:error("Unable to write byte value to address " .. address)
        return false
    end
    return true
end

--
--- Handler: BYTE Add
--- Adds a value to the current byte value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
----------
function Utility:safeAddByte(address, value)
    local currentValue = self:safeReadByte(address)
    if currentValue == nil then
        logger:error("Unable to add byte value due to read failure at address " .. address)
        return false
    end
    local newValue = currentValue + value
    local success = self:safeWriteByte(address, newValue)
    if not success then
        logger:error("Unable to write new byte value to address " .. address)
        return false
    end
    return true
end

--
--- Handler: INTEGER Read
--- Reads an integer from the specified address.
--- @param address: The memory address to read from.
--- @return The integer value, or nil if the read fails.
----------
function Utility:safeReadInteger(address)
    local value = readInteger(address)
    if value == nil then
        logger:error("Unable to read integer value at address " .. address)
        return nil
    end
    return value
end

--
--- Handler: INTEGER Write
--- Writes an integer to the specified address.
--- @param address: The memory address to write to.
--- @param value: The integer value to write.
--- @return true if the write succeeds, false otherwise.
----------
function Utility:safeWriteInteger(address, value)
    local success = writeInteger(address, value)
    if not success then
        logger:error("Unable to write integer value to address " .. address)
        return false
    end
    return true
end

--
--- Handler: INTEGER Add
--- Adds a value to the current integer value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
----------
function Utility:safeAddInteger(address, value)
    local currentValue = self:safeReadInteger(address)
    if currentValue == nil then
        logger:error("Unable to add integer value due to read failure at address " .. address)
        return false
    end
    local newValue = currentValue + value
    local success = self:safeWriteInteger(address, newValue)
    if not success then
        logger:error("Unable to write new integer value to address " .. address)
        return false
    end
    return true
end

--
--- Handler: FLOAT Read
--- Reads a float from the specified address.
--- @param address: The memory address to read from.
--- @return The float value, or nil if the read fails.
----------
function Utility:SafeReadFloat(address)
    local value = readFloat(address)
    if value == nil then
        logger:error("Unable to read float value at address " .. address)
        return nil
    end
    return value
end
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
        logger:error("Unable to write float value to address " .. address)
        return false
    end
    return true
end

--
--- Handler: FLOAT Add
--- Adds a value to the current float value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
----------
function Utility:SafeAddFloat(address, value)
    local currentValue = self:safeReadFloat(address)
    if currentValue == nil then
        logger:error("Unable to add float value due to read failure at address " .. address)
        return false
    end
    local newValue = currentValue + value
    local success = self:safeWriteFloat(address, newValue)
    if not success then
        logger:error("Unable to write new float value to address " .. address)
        return false
    end
    return true
end

--
--- Handler: DOUBLE Read
--- Reads a double from the specified address.
--- @param address: The memory address to read from.
--- @return The double value, or nil if the read fails.
----------
function Utility:SafeReadDouble(address)
    local value = readDouble(address)
    if value == nil then
        logger:error("Unable to read double value at address " .. address)
        return nil
    end
    return value
end

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
        logger:error("Unable to write double value to address " .. address)
        return false
    end
    return true
end

--
--- Handler: DOUBLE Add
--- Adds a value to the current double value at the specified address.
--- @param address: The memory address to modify.
--- @param value: The value to add.
--- @return true if the operation succeeds, false otherwise.
----------
function Utility:SafeAddDouble(address, value)
    local currentValue = self:safeReadDouble(address)
    if currentValue == nil then
        logger:error("Unable to add double value due to read failure at address " .. address)
        return false
    end
    local newValue = currentValue + value
    local success = self:safeWriteDouble(address, newValue)
    if not success then
        logger:error("Unable to write new double value to address " .. address)
        return false
    end
    return true
end

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
function Utility:registerTimeTypes()
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

--
--- Resolves a multi-level pointer path to its final address.
--- Starts from a base address (or symbol) and iteratively applies offsets.
---     [+] Offset-List should end with 0x0
--- @param baseAddress: A string representing the base address or symbol name.
--- @param offsets: A table (array) of numerical offsets to apply sequentially.
--- @return The final resolved address, or nil if an error occurs during resolution.
----------
function Utility:resolvePointerPath(baseAddress, offsets)
    local address = getAddress(baseAddress)
    if not address then
        logger:error("Base address or symbol '" .. baseAddress .. "' not found.")
        return nil
    end
    logger:debug("Starting base address: " .. string.format("0x%X", address))
    for i, offset in ipairs(offsets) do
        if type(offset) ~= "number" then
            logger:error("Offset must be a number. Offset " .. i .. " is not a number.", {offset = offset, index = i})
            return nil
        end
        logger:debug("Applying offset " .. i .. ": " .. string.format("0x%X", offset))
        local value = readPointer(address)
        if not value then
            logger:error("Unable to read memory at address " .. string.format("0x%X", address))
            return nil
        end
        logger:debug("Value read from address " .. string.format("0x%X", address) .. ": " .. string.format("0x%X", value))
        address = value + offset
        logger:debug("New address after applying offset " .. i .. ": " .. string.format("0x%X", address))
    end
    logger:debug("Final resolved address: " .. string.format("0x%X", address))
    return address
end

--
--- Opens a specified link after confirming with the user.
--- @param link: The URL or link to open.
--- @return None.
----------
function Utility:openLink(link)
    local result = messageDialog(
        "Do you really want to open this link?\n" .. link,
        mtConfirmation,
        mbYes, mbNo)
    if result == mrYes then
        ShellExecute(link)
    end
end

--
--- Displays a startup message dialog with the provided string.
--- @param str: The message to display.
--- @return None.
----------
function Utility:startupMessage(str)
    if str then
        messageDialog(str, 2)
    end
end

--
--- Attaches the program to a specified process by name.
--- If no process name is provided, it will use the default stored process name.
--- @param processName: The name of the process to attach to.
--- @return None.
----------
function Utility:attachToProcess(processName)
    processName = processName or self.ProcessName
    local processID = getProcessIDFromProcessName(processName)
    if processID ~= nil then
        openProcess(processID)
    else
        -- messageDialog("Process not found: " .. processName, mtError, mbOK)
    end
end

--
--- Prompts the user to confirm if they want to terminate the currently attached process.
--- If confirmed, the process is terminated.
--- @return None.
----------
function Utility:closeProcess()
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

--
--- Automatically attempts to attach to a process at regular intervals until successful.
--- Once attached, the table setup is initialized.
--- @param processName: The name of the process to auto-attach to.
--- @return None. 
----------
function Utility:autoAttach(processName)
    processName = processName or self.ProcessName
    local function autoAttachTimer_tick(timer)
        if self.AutoAttachTimerTickMax > 0 and self.AutoAttachTimerTicks >= self.AutoAttachTimerTickMax then
            timer.destroy()
        end
        local processID = getProcessIDFromProcessName(processName)
        if processID ~= nil then
            timer.destroy()
            openProcess(processID)
            self:setupTable()
        end
        self.AutoAttachTimerTicks = self.AutoAttachTimerTicks + 1
    end
    local autoAttachTimer = createTimer(MainForm)
    autoAttachTimer.Interval = self.AutoAttachTimerInterval
    autoAttachTimer.OnTimer = autoAttachTimer_tick
end

--
--- Updates the main form's window title to reflect the current table, game, and Cheat Engine version.
--- @return None.
----------
function Utility:setTitle()
    if not inMainThread() then
        synchronize(function()
            self:setTitle()
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

--
--- Initializes and configures the table by setting up form management, applying themes, 
--- and configuring UI components like the table signature and slogan.
--- @return None.
----------
function Utility:setupTable()
    if not formManager then
        formManager = FormManager:new({ Signature = self.Signature, Slogan = self.Slogan })
    end
    getMainForm().Show()
    formManager:disableHeaderSorting()
    formManager:hideSignatureControls()
    formManager:enableCompactMode()
    formManager:createSloganStr(self.Slogan)
    formManager:createSignatureStr(self.Signature)
    formManager:loadThemes()
    formManager:applyTheme(self.DefaultTheme)
    self:setTitle()
end

return Utility
