local NAME = "CTI.Utility"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.3"
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
    1.0.3   | 21.02.2025   | Leunsel         | Added Slogan Animations + Refactored
    -----------------------------------------------------------------------------
    
    Notes:
    - Features:
        - Memory Management:
            Read and write values of different data types (Byte, Integer, Float, Double).
            Safely modify memory values with error handling.
        - Script Execution:
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

--
--- Several configuration properties that can be customized.
--- Set within the Table Lua Script and passed to the constructor of the class.
----------
Utility = {
    -- Passed by Author
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
    -- Fixed Variables
    AutoDisableTimerInterval = 100,   --- Interval in milliseconds for auto-disable timers
    AutoAttachTimerInterval = 100,    --- Interval in milliseconds for auto-attach timers
    AutoAttachTimerTicks = 0,         --- Number of ticks for the auto-attach timer
    AutoAttachTimerTickMax = 5000,     --- Max number of ticks before stopping the auto-attach timer
    SloganObj = nil,
    SignatureObj = nil
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
--- Removes all table files currently listed in the menu.
--- This function finds all loaded table files in the "miTable" menu and deletes them one by one.
--- @return None.
----------
function Utility:RemoveAllTableFiles()
    local miTable = MainForm.findComponentByName("miTable")
    if not miTable then
        self.logger:Error("Menu item 'miTable' not found.")
        return
    end
    self.logger:Info("Opening the 'miTable' menu...")
    miTable.doClick()  -- Ensure the table menu is opened
    self.logger:Info("'miTable' menu opened successfully.")
    -- Check if there are any items in the menu
    if miTable.Count == 0 then
        self.logger:Info("No table files found in the menu.")
        return
    end
    -- Loop through all items in the menu, starting from the last
    for i = miTable.Count, 1, -1 do
        local tableFileName = miTable.Item[i - 1].Caption
        self.logger:Info(string.format("Attempting to remove table file: '%s'...", tableFileName))
        local tableFile = findTableFile(tableFileName)
        if tableFile then
            -- Table file found, proceeding with deletion
            self.logger:Info(string.format("Found table file: '%s'. Deleting...", tableFileName))
            tableFile.delete()
            self.logger:Info(string.format("Table file '%s' deleted successfully.", tableFileName))
        else
            -- Table file not found
            self.logger:Warning(string.format("Table file '%s' not found for deletion.", tableFileName))
        end
    end
    self.logger:Info("All table files processed.")
end
registerLuaFunctionHighlight('RemoveAllTableFiles')

--
--- Runs a given function in the main thread. If already in the main thread, it executes the function immediately.
--- @param func function - The function to be executed in the main thread.
--- @return None.
----------
function Utility:RunInMainThread(func)
    if not inMainThread() then
        synchronize(func)
        return
    end
    func()
end

--
--- Creates or updates a label with the specified properties.
--- If a label already exists, it updates its properties; otherwise, it creates a new label.
--- @param parent Object - The parent control that will contain the label.
--- @param label Object|nil - The existing label to update, or nil to create a new label.
--- @param defaultProperties table - A table containing the default properties to apply to the label.
---  - Name string - The name of the label (optional).
---  - Caption string - The text to display on the label (optional).
---  - Alignment string - The alignment of the labels text (optional).
---  - FontName string - The font name to use for the labels text (optional).
---  - FontSize number - The font size to use for the labels text (optional).
---  - FontStyle string - The font style to use for the labels text (optional).
---  - FontColor number - The font color to use for the labels text (optional).
---  - Visible boolean - Whether the label is visible or not (optional).
---  - BorderSpacingBottom number - The bottom border spacing for the label (optional).
--- @return Object - The created or updated label.
----------
function Utility:CreateOrUpdateLabel(parent, label, defaultProperties)
    if not label then
        label = createLabel(parent)
        label.Align = defaultProperties.Align or alTop
        label.AutoSize = true
    end
    label.Name = defaultProperties.Name or label.Name
    label.Caption = defaultProperties.Caption or label.Caption
    label.Alignment = defaultProperties.Alignment or label.Alignment
    label.Font.Name = defaultProperties.FontName or label.Font.Name
    label.Font.Color = defaultProperties.FontColor or label.Font.Color
    label.Font.Size = defaultProperties.FontSize or label.Font.Size
    label.Font.Style = defaultProperties.FontStyle or label.Font.Style
    label.Visible = (defaultProperties.Visible ~= nil) and defaultProperties.Visible or label.Visible
    label.BorderSpacing.Bottom = defaultProperties.BorderSpacingBottom or label.BorderSpacing.Bottom
    return label
end

--
--- Creates or updates a slogan string label with the given text.
--- @param str string - The text to display in the slogan label.
--- @return None.
----------
function Utility:CreateSloganStr(str)
    self:RunInMainThread(function()
        local mainForm = getMainForm()
        local defaultProperties = {
            Name = "SLOGAN_STR",
            Caption =  str or self.Slogan or "",
            Alignment = "taCenter",
            FontName = "Consolas",
            FontSize = 20,
            FontStyle = "fsBold",
            Visible = true
        }
        self.SloganObj = mainForm:findComponentByName("SLOGAN_STR")
        if not self.SloganObj then
            self.SloganObj = self:CreateOrUpdateLabel(mainForm, nil, defaultProperties)
        else
            self:CreateOrUpdateLabel(mainForm, self.SloganObj, defaultProperties)
        end
        self.SloganObj = self.SloganObj
    end)
end

-- 
--- Starts the animation sequence for a given text, cycling through different animations like Typing, Reveal, and Scrolling.
--- @param text string - The text to animate.
--- @return None.
----------
function Utility:StartTextAnimation(text, config)
    config = config or {}
    local animations = config.animations or { "Typing", "Reveal", "Scrolling", "Glitch", "Matrix" }
    local interval = config.interval or 100  
    local minDuration = config.minDuration or 5000  
    local pauseBetweenAnimations = config.pauseBetweenAnimations or 1000  
    ---
    local duration = math.max(#text * 100, minDuration)  
    local index = 1
    ---
    local animationFunctions = {
        Typing = function() self:TypingEffect(text, interval) end,
        Reveal = function() self:RevealEffect(text, interval) end,
        Scrolling = function() self:ScrollText(text, interval) end,
        Glitch = function() self:GlitchText(text, interval) end,
        Matrix = function() self:MatrixReveal(text, interval) end
    }
    ---
    local function CycleAnimations(timer)
        local selectedAnimation = animations[index]
        if animationFunctions[selectedAnimation] then
            animationFunctions[selectedAnimation]()
        end
        index = (index % #animations) + 1
    end
    ---
    if self.MainAnimationTimer then
        self.MainAnimationTimer.destroy()
    end
    ---
    self.MainAnimationTimer = createTimer(MainForm)
    self.MainAnimationTimer.Interval = duration + pauseBetweenAnimations
    self.MainAnimationTimer.OnTimer = CycleAnimations
    ---
    CycleAnimations(self.MainAnimationTimer)
end
registerLuaFunctionHighlight('StartTextAnimation')

function Utility:CreateTimer(interval, callback)
    local timer = createTimer(MainForm)
    timer.Interval = interval
    timer.OnTimer = callback
    return timer
end
registerLuaFunctionHighlight('CreateTimer')

-- 
--- Scrolls the given text in a looping fashion, where each character is shifted to the left.
--- @param text string - The text to scroll.
--- @param interval number - The interval (in milliseconds) between each scroll.
--- @param maxTicks number - The maximum number of scroll steps to perform.
--- @return None.
----------
function Utility:ScrollText(text, interval, maxTicks)
    local function ScrollTextInner(text)
        return text:sub(2) .. text:sub(1, 1)
    end
    self.scrollingText = text .. " "
    self.scrollInterval = interval or 100  -- Default interval
    self.scrollMaxTicks = maxTicks or #self.scrollingText
    local function ScrollTextTimer_tick(timer)
        if self.scrollMaxTicks ~= 0 then
            self.scrollMaxTicks = self.scrollMaxTicks - 1
            if self.scrollMaxTicks <= 0 then
                timer.destroy()
                self:CreateSloganStr(text)
                return
            end
        end
        self.scrollingText = ScrollTextInner(self.scrollingText)
        self:CreateSloganStr(self.scrollingText)
    end
    if self.ScrollTextTimer then
        self.ScrollTextTimer.destroy()
    end
    self:CreateTimer(interval or 100, ScrollTextTimer_tick)
end
registerLuaFunctionHighlight('ScrollText')

-- 
--- Creates a typing effect where each character of the text is revealed one by one.
--- @param text string - The text to be typed out.
--- @param interval number - The interval (in milliseconds) between each character being typed.
--- @return None.
----------
function Utility:TypingEffect(text, interval)
    local index = 1
    local function TypingTimer_tick(timer)
        if index > #text then
            timer.destroy()
            return
        end
        self:CreateSloganStr(text:sub(1, index))
        index = index + 1
    end
    self:CreateTimer(interval or 100, TypingTimer_tick)
end
registerLuaFunctionHighlight('TypingEffect')

-- 
--- Reveals the text one character at a time by replacing "#" (or any other symbol)
--- with each character in the string.
--- @param text string - The text to reveal.
--- @param interval number - The interval (in milliseconds) between each character being revealed.
--- @return None.
----------q
function Utility:RevealEffect(text, interval)
    local placeholders = { "#", "@", "%", "&", "?", "*", "!" }  -- Add more symbols if needed
    local revealStr = ""
    for i = 1, #text do
        revealStr = revealStr .. (text:sub(i, i) == " " and " " or placeholders[math.random(1, #placeholders)])
    end
    local index = 1
    local function RevealTimer_tick(timer)
        while index <= #text and text:sub(index, index) == " " do
            index = index + 1
        end
        if index > #text then
            timer.destroy()
            return
        end
        revealStr = revealStr:sub(1, index - 1) .. text:sub(index, index) .. revealStr:sub(index + 1)
        self:CreateSloganStr(revealStr)
        index = index + 1
    end
    self:CreateTimer(interval or 100, RevealTimer_tick)
end
registerLuaFunctionHighlight('RevealEffect')

-- 
--- Creates a glitching text effect by randomly altering characters for a limited duration.
--- @param text string - The text to glitch.
--- @param interval number - The interval (in milliseconds) between each glitch update.
--- @return None.
----------
function Utility:GlitchText(text, interval)
    local duration = math.max(#text * 100, 5000)
    local endTime = getTickCount() + duration
    local function GlitchTimer_tick(timer)
        if getTickCount() >= endTime then
            timer.destroy()
            self:CreateSloganStr(text)
            return
        end
        local glitchedText = {}
        for i = 1, #text do
            glitchedText[i] = text:sub(i, i)
        end
        for i = 1, math.random(1, #text // 3) do
            local pos
            repeat
                pos = math.random(1, #text)
            until text:sub(pos, pos) ~= " "
            
            glitchedText[pos] = string.char(math.random(33, 126))
        end
        self:CreateSloganStr(table.concat(glitchedText))
    end
    self:CreateTimer(interval or 100, GlitchTimer_tick)
end
registerLuaFunctionHighlight('GlitchText')

-- 
--- Simulates a "Matrix-style" reveal by randomly revealing characters in the text.
--- @param text string - The text to be revealed.
--- @param interval number - The interval (in milliseconds) between each character reveal.
--- @return None.
----------
function Utility:MatrixReveal(text, interval)
    local revealStr = {}
    for i = 1, #text do
        revealStr[i] = text:sub(i, i) == " " and " " or "#"
    end
    local revealed = table.concat(revealStr)
    local function MatrixTimer_tick(timer)
        if revealed == text then
            timer.destroy()
            return
        end
        local pos
        repeat
            pos = math.random(1, #text)
        until revealStr[pos] ~= text:sub(pos, pos) and text:sub(pos, pos) ~= " "
        revealStr[pos] = text:sub(pos, pos)
        revealed = table.concat(revealStr)
        self:CreateSloganStr(revealed)
    end
    self:CreateTimer(interval or 100, MatrixTimer_tick)
end
registerLuaFunctionHighlight('MatrixReveal')

--
--- Destroys a given label if it exists.
--- @param label object - The label object to be destroyed.
--- @return None.
----------
function Utility:DestroyLabel(label)
    if label then
        label:destroy()
    end
end
registerLuaFunctionHighlight('DestroyLabel')

--
--- Destroys the slogan string object and sets it to nil.
--- @return None.
----------
function Utility:DestroySloganStr()
    self:RunInMainThread(function()
        if self.SloganObj then
            self:DestroyLabel(self.SloganObj)
            self.SloganObj = nil
        end
    end)
end
registerLuaFunctionHighlight('DestroySloganStr')

--
--- Creates or updates the signature string label with the given text.
--- @param str string - The text to display in the signature string label.
--- @return None.
----------
function Utility:CreateSignatureStr(str)
    self:RunInMainThread(function()
        local mainForm = getMainForm()
        local lblSigned = mainForm.lblSigned
        if lblSigned then
            lblSigned.Caption = str or self.Signature or ""
            lblSigned.Visible = true
            lblSigned.BorderSpacing.Bottom = 5
            lblSigned.AutoSize = true
            lblSigned.Font.Name = "Consolas"
            lblSigned.Font.Size = 11
            lblSigned.Font.Style = "fsBold"
        end
        self.SignatureObj = lblSigned
    end)
end
registerLuaFunctionHighlight('CreateSignatureStr')

--
--- Hides the signature string label if it exists.
--- @return None.
----------
function Utility:HideSignatureStr()
    self:RunInMainThread(function()
        if self.SignatureObj then
            self.SignatureObj.Visible = false
        end
    end)
end
registerLuaFunctionHighlight('HideSignatureStr')

--
--- Toggles the visibility of a specified control in the main form.
--- @param controlName string - The name of the control to toggle visibility for.
--- @return None.
----------
function Utility:ToggleControlVisibility(controlName)
    self:RunInMainThread(function()
        local mainForm = getMainForm()
        if mainForm and mainForm[controlName] then
            mainForm[controlName].Visible = not mainForm[controlName].Visible
        end
    end)
end
registerLuaFunctionHighlight('ToggleControlVisibility')

--
--- Sets the visibility of a specified control in the main form.
--- @param controlName string - The name of the control to modify visibility.
--- @param isVisible boolean - True to make the control visible, false to hide it.
--- @return None.
----------
function Utility:SetControlVisibility(controlName, isVisible)
    self:RunInMainThread(function()
        local mainForm = getMainForm()
        if mainForm and mainForm[controlName] then
            mainForm[controlName].Visible = isVisible
        end
    end)
end
registerLuaFunctionHighlight('SetControlVisibility')

---
--- Sets the BevelOuter property of AddressList and MainForm.Panel4 to None.
--- @return None.
----------
function Utility:HideAddresslistBevel()
    self:RunInMainThread(function()
        local mainForm = getMainForm()
        if mainForm then
            AddressList.BevelOuter = "bvNone" -- AddressList
        end
    end)
end
registerLuaFunctionHighlight('HideAddresslistBevel')

--
--- Toggles the visibility of specified header sections in the address list.
--- @param sections table - An array of section indices to toggle visibility for.
--- @return None.
----------
function Utility:ToggleHeaderSections(sections)
    self:RunInMainThread(function()
        local header = getAddressList().Header
        for _, sectionIndex in ipairs(sections) do
            local section = header.Sections[sectionIndex]
            if section then
                section.Visible = not section.Visible
            end
        end
    end)
end
registerLuaFunctionHighlight('ToggleHeaderSections')

--
--- Disables drag-and-drop functionality for the address list tree view.
--- @return None.
----------
function Utility:DisableDragDrop()
    self:RunInMainThread(function()
        local addressListTreeview = component_getComponent(AddressList, 0) -- Disable drag and drop events
        setMethodProperty(addressListTreeview, "OnDragOver", nil)
        setMethodProperty(addressListTreeview, "OnDragDrop", nil)
        setMethodProperty(addressListTreeview, "OnEndDrag", nil)
    end)
end
registerLuaFunctionHighlight('DisableDragDrop')

--
--- Disables sorting functionality for the address list header.
--- @return None.
----------
function Utility:DisableHeaderSorting()
    self:RunInMainThread(function()
        local addressListHeader = component_getComponent(AddressList, 1)
        setMethodProperty(addressListHeader, "OnSectionClick", nil)
    end)
end
registerLuaFunctionHighlight('DisableHeaderSorting')

--
--- Enables compact mode by hiding specific controls in the form.
--- @return None.
----------
function Utility:EnableCompactMode()
    self:SetControlVisibility("Panel5", false)
    self:SetControlVisibility("Splitter1", false)
end
registerLuaFunctionHighlight('EnableCompactMode')

--
--- Hides signature-related controls in the form.
--- @return None.
----------
function Utility:HideSignatureControls()
    self:SetControlVisibility("CommentButton", false)
    self:SetControlVisibility("advancedbutton", false)
end
registerLuaFunctionHighlight('HideSignatureControls')

--
--- Toggles compact mode by toggling the visibility of specific controls.
--- @return None.
----------
function Utility:ToggleCompactMode()
    self:RunInMainThread(function()
        self:ToggleControlVisibility("Panel5")
        self:ToggleControlVisibility("Splitter1")
    end)
end
registerLuaFunctionHighlight('ToggleCompactMode')

--
--- Toggles the visibility of signature-related controls.
--- @return None.
----------
function Utility:ToggleSignatureControls()
    self:ToggleControlVisibility("CommentButton")
    self:ToggleControlVisibility("advancedbutton")
end
registerLuaFunctionHighlight('ToggleSignatureControls')

--
--- Manages the header sections by toggling visibility for predefined indices.
--- @return None.
----------
function Utility:ManageHeaderSections()
    local sectionsToToggle = {0, 2, 3}
    self:toggleHeaderSections(sectionsToToggle)
end
registerLuaFunctionHighlight('ManageHeaderSections')

--
--- Retrieves title components for formatting the main form title.
--- @return table A table containing the title components:
---  - tableTitle (string): The table name or default "TableTitle".
---  - tableVersion (string): The table version or default "TableVersion".
---  - gameVersion (string): The detected game version or "GameVersion".
---  - registrySizeStr (string): Registry size string, if available.
---  - ceRegistrySizeStr (string): CE architecture (x64 or x32).
---  - ceVersion (string): Cheat Engine version.
----------
local function Utility:GetTitleComponents()
    return {
        tableTitle = self.TableTitle or "TableTitle",
        tableVersion = self.TableVersion or "TableVersion",
        gameVersion = self.GameVersion or Helper:getFileVersionStr(Helper:getGameModulePathToFile()) or "GameVersion",
        registrySizeStr = Helper:getRegistrySizeStr() or "",
        ceRegistrySizeStr = cheatEngineIs64Bit() and "(x64)" or "(x32)",
        ceVersion = getCEVersion()
    }
end
registerLuaFunctionHighlight('GetTitleComponents')

--
--- Formats a title string using provided components.
--- @param components table A table containing the title elements:
---  - tableTitle (string)
---  - registrySizeStr (string)
---  - gameVersion (string)
---  - tableVersion (string)
---  - ceRegistrySizeStr (string)
---  - ceVersion (string)
--- @return string The formatted title string.
----------
local function Utility:FormatTitle(components)
    return string.format(
        "%s %s V:%s — CET V:%s — CE %s V:%s",
        components.tableTitle,
        components.registrySizeStr,
        components.gameVersion,
        components.tableVersion,
        components.ceRegistrySizeStr,
        components.ceVersion
    )
end
registerLuaFunctionHighlight('FormatTitle')

--
--- Sets the main form's title by generating and applying a formatted title string.
--- Ensures thread safety by running in the main thread.
--- @return None
----------
function Utility:SetTitle()
    if not inMainThread() then
        synchronize(function()
            self:SetTitle()
        end)
        return
    end
    local titleStr = self:FormatTitle(self:GetTitleComponents())
    getMainForm().Caption = titleStr
end
registerLuaFunctionHighlight('SetTitle')

--
--- Configures and displays the main form.
--- @return None
---
function Utility:SetupMainForm()
    getMainForm().Show()
end

--
--- Applies UI configurations such as disabling sorting, hiding elements, 
--- enabling compact mode, and setting up the signature and slogan.
--- @return None
----------
function Utility:SetupUIComponents()
    self:DisableHeaderSorting()
    self:HideSignatureControls()
    self:EnableCompactMode()
    self:CreateSlogan()
    self:CreateSignature()
    self:HideAddresslistBevel()
end

--
--- Creates and sets up the slogan text if available.
--- @return None
----------
function Utility:CreateSlogan()
    if self.Slogan then
        self:CreateSloganStr(self.Slogan)
    end
end

--
--- Creates and sets up the signature text if available.
--- @return None
----------
function Utility:CreateSignature()
    if self.Signature then
        self:CreateSignatureStr(self.Signature)
    end
end

--
--- Initializes and configures the table by setting up the UI and form properties.
--- Calls multiple helper functions to manage different components.
--- @return None
----------
function Utility:SetupTable()
    self:SetupMainForm()
    self:SetupUIComponents()
    self:SetTitle()
end
registerLuaFunctionHighlight('SetupTable')

return Utility
