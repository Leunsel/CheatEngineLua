local NAME = "Manifold.Utils.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.3"
local DESCRIPTION = "Manifold Framework Utils"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.

    ∂ v1.0.1 (2025-02-26)
        Minor comment adjustments.

    ∂ v1.0.2 (2025-04-27)
        Added EnsureCompatibleCEVersion.
        Attempting to notify users of CE 7.6
        that a Table may be malfunctioning.

    ∂ v1.0.3 (2025-07-06)
        Synchronized some functions to ensure they run in the main thread.
        This is required for CE 7.6 to execute the functions properly.
]]--

Utils = {
    Author     = "",
    Target     = "",
    TargetStr  = "",
    AppID      = "",
    AppVersion = "",
    Version    = "",
    VerifyMD5  = true,
    MD5Hash    = "",
    AutoDisableTimerInterval = 100,    
}
Utils.__index = Utils

function Utils:New(config)
    local instance = setmetatable({}, self)
    instance.Name = NAME or "Unnamed Module"
    for key, value in pairs(config or {}) do
        if self[key] ~= nil then
            instance[key] = value
        else
            logger:WarningF("Invalid property: '%s'", key)
        end
    end
    return instance
end
registerLuaFunctionHighlight('New')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table # {name, version, author, description}
--
function Utils:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Prints module details in a readable formatted block.
--
function Utils:PrintModuleInfo()
    local info = self:GetModuleInfo()
    if not info then
        logger:Info("[Utils] Failed to retrieve module info.")
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
--- ∑ Retrieves the target (the current target object).
---   If the target doesn't exist, it returns nil.
--- @return # The current target or nil if no target is set.
--
function Utils:GetTarget()
    return self.Target or nil
end
registerLuaFunctionHighlight('GetTarget')

--
--- ∑ Retrieves the target's name without the file extension.
---   If the target doesn't exist, it returns nil.
--- @return # The target name without extension or nil if no target is set.
--
function Utils:GetTargetNoExt()
    return self.Target and customIO:StripExt(self.Target) or nil
end
registerLuaFunctionHighlight('GetTargetNoExt')

--
--- ∑ Automatically disables a memory record after a specified interval.
---   If called from a non-main thread, the function ensures thread safety by synchronizing execution.
--- @param id # The ID of the memory record to disable.
--- @param customInterval # (Optional) Custom time interval in milliseconds before disabling.
---                        Defaults to "self.AutoDisableTimerInterval" if not provided.
--- @return # void
--
function Utils:AutoDisable(id, customInterval)
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
--- ∑ Verifies the integrity of a file by comparing its MD5 hash to the provided hash.
---   If the hashes do not match, a warning is displayed to alert the user.
--- @param hash string # The expected MD5 hash of the file.
--- @return true | false # true is a match, false is a mismatch or error.
--
function Utils:VerifyFileHash()
    logger:Debug("[Utils] Starting file hash verification...")
    local filePath = helper:GetGameModulePathToFile()
    logger:Debug("[Utils] Retrieving file hash for: " .. tostring(filePath))
    if filePath == nil then
        logger:Warning("[Utils] File Path is nil. Hash Verification stopped!")
        return false
    end
    local fileHash = md5file(filePath)
    logger:Debug("[Utils] Calculated file hash: " .. tostring(fileHash))
    logger:Debug("[Utils] Expected file hash: " .. tostring(self.MD5Hash))
    if self.MD5Hash ~= fileHash then
        logger:Warning("[Utils] File hash mismatch detected!")
        self:ShowWarning("[Utils] File Hash Mismatch!\n\nExpected: " .. self.MD5Hash .. "\nReceived: " .. fileHash .. "\n\nThe Cheat Table might not be compatible with the current game version. Use at your own risk.")
        return false
    else
        logger:Debug("[Utils] File hash matched. The table 'should' work as expected.")
        return true
    end
end
registerLuaFunctionHighlight('VerifyFileHash')

--
--- ∑ Sets all memory records of type "Auto Assembler" in the address list to async mode.
---   This ensures the scripts execute asynchronously.
---     [+] Disclaimer: Script(s) need(s) to support async mode!
--- @return # void
--
function Utils:SetAllScriptsToAsync()
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr.Type == vtAutoAssembler then
            mr.Async = true
        end
    end
end
registerLuaFunctionHighlight('SetAllScriptsToAsync')

--
--- ∑ Sets all memory records of type "Auto Assembler" in the address list to non-async mode.
---   This ensures the scripts execute synchronously.
--- @return # void
--
function Utils:SetAllScriptsToNotAsync()
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr.Type == vtAutoAssembler then
            mr.Async = false
        end
    end
end
registerLuaFunctionHighlight('SetAllScriptsToNotAsync')

--
--- ∑ Message Dialog Preset - Info
---   Displays an informational message dialog to the user.
--- @param message # The message text to display in the dialog.
--- @return # void
--
function Utils:ShowInfo(message)
    if not inMainThread() then
        synchronize(function()
            self:ShowInfo(message)
        end)
        return
    end
    messageDialog(message, mtInformation, mbOK)
end
registerLuaFunctionHighlight('ShowInfo')

--
--- ∑ Message Dialog Preset - Warning
---   Displays a warning message dialog to the user.
--- @param message # The message text to display in the dialog.
--- @return # void
--
function Utils:ShowWarning(message)
    if not inMainThread() then
        synchronize(function()
            self:ShowWarning(message)
        end)
        return
    end
    messageDialog(message, mtWarning, mbOK)
end
registerLuaFunctionHighlight('ShowWarning')

--
--- ∑ Message Dialog Preset - Error
---   Displays an error message dialog to the user.
--- @param message # The message text to display in the dialog.
--- @return # void
--
function Utils:ShowError(message)
    if not inMainThread() then
        synchronize(function()
            self:ShowError(message)
        end)
        return
    end
    messageDialog(message, mtError, mbOK)
end
registerLuaFunctionHighlight('ShowError')

--
--- ∑ Message Dialog Preset - Confirmation
---   Displays a confirmation message dialog to the user with "Yes" and "No" options.
--- @param message # The message text to display in the dialog.
--- @return # true if the user selects "Yes", false otherwise.
--
function Utils:ShowConfirmation(message)
    if not inMainThread() then
        synchronize(function()
            self:ShowConfirmation(message)
        end)
        return
    end
    local result = messageDialog(message, mtConfirmation, mbYes, mbNo)
    return result == mrYes
end
registerLuaFunctionHighlight('ShowConfirmation')
--
--- ∑ Ensures that the user is running the required Cheat Engine version.
---   Displays a warning if the version does not match the required version.
---   Optionally closes Cheat Engine if the version mismatch is critical.
--- @param requiredVersion # The exact Cheat Engine version the table was designed for.
--- @param closeOnFail # If true, the table will close automatically on version mismatch.
--
function Utils:EnsureCompatibleCEVersion(requiredVersion, closeOnFail)
    if not inMainThread() then
        synchronize(function()
            self:EnsureCompatibleCEVersion(requiredVersion, closeOnFail)
        end)
        return
    end
    if type(requiredVersion) ~= 'number' then
        logger:Error('[Utils] EnsureCompatibleCEVersion: requiredVersion must be a number')
        return
    end
    local currentVersion = getCEVersion()
    logger:Debug(string.format('[Utils] Detected Cheat Engine version: %.1f', currentVersion))
    if currentVersion ~= requiredVersion then
        local msg = string.format(
            "— Cheat Engine Version Mismatch\n\n" ..
            "This table was developed and tested specifically for Cheat Engine version %.1f.\n" ..
            "You are currently using version %.1f.\n\n" ..
            "Using a different version may result in unexpected behavior, errors, or instability.\n\n" ..
            "For the best experience, please use the recommended Cheat Engine version.",
            requiredVersion, currentVersion
        )
        if closeOnFail then
            msg = msg .. "\n\nThe table will now close to prevent any issues."
            self:ShowError(msg)
            closeCE()
        else
            msg = msg .. "\n\nIt is highly recommended to use the correct version."
            self:ShowWarning(msg)
        end
    end
end
registerLuaFunctionHighlight('EnsureCompatibleCEVersion')

--
--- ∑ Registers a custom memory value type for "Military Hours" used in the game "Dying Light."
---   Converts a 4-byte floating-point value representing in-game time into military time format (0-2400).
---   Handles both reading (bytes to value) and writing (value to bytes).
---
--- ∑ Conversion Details:
---   - In-game time (float) is scaled by 24 (hours in a day) and then by 100 (to represent military time).
---   - Reverse scaling is applied for writing values back to memory.
--- @return # void
--
function Utils:RegisterTimeTypes()
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
--- ∑ Registers a custom memory value type for "Decrypted" used to decrypt data from memory.
---   Uses 16 bytes of data, where:
---     - The first 8 bytes represent the encrypted value.
---     - The next 8 bytes represent a multiplier.
---   The decrypted value is computed as: encrypted / multiplier.
---   When writing a value back, the value is multiplied by the multiplier (retrieved from memory) and split into 16 bytes.
---   (Used in: Monster Hunter Wilds)
--- @return # void
--
function Utils:RegisterDecryptionType()
    local TypeName, ByteCount, IsFloat = "Decrypted", 16, false
    local function BytesToValue(b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, b16, address)
        local encrypted = b1 | (b2 << 8) | (b3 << 16) | (b4 << 24) | (b5 << 32) | (b6 << 40) | (b7 << 48) | (b8 << 56)
        local multiplier = b9 | (b10 << 8) | (b11 << 16) | (b12 << 24) | (b13 << 32) | (b14 << 40) | (b15 << 48) | (b16 << 56)
        return encrypted / multiplier
    end
    local function ValueToBytes(value, address)
        local multiplier = readQword(address + 8) or 1
        local encrypted = value * multiplier
        return encrypted & 0xFF, (encrypted >> 8) & 0xFF, (encrypted >> 16) & 0xFF, (encrypted >> 24) & 0xFF,
               (encrypted >> 32) & 0xFF, (encrypted >> 40) & 0xFF, (encrypted >> 48) & 0xFF, (encrypted >> 56) & 0xFF,
               multiplier & 0xFF, (multiplier >> 8) & 0xFF, (multiplier >> 16) & 0xFF, (multiplier >> 24) & 0xFF,
               (multiplier >> 32) & 0xFF, (multiplier >> 40) & 0xFF, (multiplier >> 48) & 0xFF, (multiplier >> 56) & 0xFF
    end
    registerCustomTypeLua(TypeName, ByteCount, BytesToValue, ValueToBytes, IsFloat)
end

--
--- ∑ Removes table files that contain the specified string in their name.
---   Opens the "miTable" menu, checks all listed table files, and deletes those containing the given extension.
--- @param extension string # The string to match in the table file names (e.g., ".lua").
--- @return # void
--
function Utils:RemoveTableFilesByExtension(extension)
    if not inMainThread() then
        synchronize(function()
            self:RemoveTableFilesByExtension(extension)
        end)
        return
    end
    extension = extension or ".lua"
    local miTable = MainForm.findComponentByName("miTable")
    if not miTable then
        logger:Error("[Utils] Menu item 'miTable' not found.")
        return
    end
    logger:Info("[Utils] Opening the 'miTable' menu...")
    miTable.doClick()  -- Ensure the table menu is opened
    logger:Info("[Utils] 'miTable' menu opened successfully.")
    if miTable.Count == 0 then
        logger:Info("[Utils] No table files found in the menu.")
        return
    end
    for i = miTable.Count, 1, -1 do
        local item = miTable.Item[i - 1]
        local tableFileName = item.Caption:match("^%s*(.-)%s*$")  -- Trim leading/trailing spaces
        if tableFileName:find(extension, 1, true) then
            logger:Info("[Utils] Attempting to remove file: '" .. tableFileName .. "'...")
            local tableFile = findTableFile(tableFileName)
            if tableFile then
                logger:Info("[Utils] Found file: '" .. tableFileName .. "'. Deleting...")
                tableFile.delete()
                logger:Info("[Utils] File '" .. tableFileName .. "' deleted successfully.")
            else
                logger:Warning("[Utils] File '" .. tableFileName .. "' not found for deletion.")
            end
        else
            logger:Debug("[Utils] Skipping file without '" .. extension .. "' in its name: '" .. tableFileName .. "'.")
        end
    end
    logger:Info("[Utils] All files with '" .. extension .. "' processed.")
end
registerLuaFunctionHighlight('RemoveTableFilesByExtension')

--
--- ∑ Executes the table Lua script by triggering the Execute button.
--- @return boolean # True if execution succeeds, false otherwise.
--
function Utils:ExecuteTableLuaScript()
    if not inMainThread() then
        synchronize(function()
            self:ExecuteTableLuaScript()
        end)
        return
    end
    local form = nil
    for i = 0, getFormCount() - 1 do
        if getForm(i).Caption == "Lua script: Cheat Table" then
            form = getForm(i)
            break
        end
    end
    if not form then
        logger:Error("[Utils] Failed to find the Table Lua Form.")
        return false
    end
    local executeButton = form.findComponentByName("btnExecute")
    if not executeButton or not executeButton.OnClick then
        logger:Error("[Utils] Failed to find the Execute button in the Table Lua Form.")
        return false
    end
    logger:Info("[Utils] Triggering the Table Lua Script execution...")
    executeButton.OnClick(executeButton) -- Simulates button press
    return true
end
registerLuaFunctionHighlight('ExecuteTableLuaScript')

--
--- ∑ Resolves a pointer path by applying offsets to a base address.
---   Reads memory at each step and follows the pointer chain until the final address is resolved.
--- @param baseAddress string|number # The base address or symbol.
--- @param offsets table<number> # A table containing offsets to apply.
--- @return number|nil # The resolved address, or nil if an error occurs.
--
function Utils:ResolvePointerPath(baseAddress, offsets)
    if type(baseAddress) ~= "string" and type(baseAddress) ~= "number" then
        logger:Error("[Utils] Invalid base address type. Expected string or number, got " .. type(baseAddress))
        return nil
    end
    local address = memory:SafeGetAddress(baseAddress)
    if not address then
        logger:Error("[Utils] Base address or symbol '" .. tostring(baseAddress) .. "' not found.")
        return nil
    end
    logger:Debug("[Utils] Starting base address: " .. string.format("0x%X", address))
    if type(offsets) ~= "table" then
        logger:Error("[Utils] Offsets parameter must be a table. Received " .. type(offsets))
        return nil
    end
    for i, offset in ipairs(offsets) do
        if type(offset) ~= "number" then
            logger:Error("[Utils] Offset must be a number. Offset " .. i .. " is not a number.")
            return nil
        end
        logger:Debug("[Utils] Applying offset " .. i .. ": " .. string.format("0x%X", offset))
        local value = readPointer(address)
        if not value then
            logger:Error("[Utils] Unable to read memory at address " .. string.format("0x%X", address))
            return nil
        end
        logger:Debug("[Utils] Value read from address " .. string.format("0x%X", address) .. ": " .. string.format("0x%X", value))
        address = value + offset
        logger:Debug("[Utils] New address after applying offset " .. i .. ": " .. string.format("0x%X", address))
    end
    logger:Debug("[Utils] Final resolved address: " .. string.format("0x%X", address))
    return address
end
registerLuaFunctionHighlight('ResolvePointerPath')

--
--- ∑ Lua Engine Shortcut
--- @return # void
--
function Utils:OpenLuaEngineWindow()
    if not inMainThread() then
        return synchronize(function()
            self:OpenLuaEngineWindow()
        end)
    end
    local luaEngine = getLuaEngine() or createLuaEngine()
    if luaEngine then
        luaEngine.Show()
    else
        logger:Warning("[Utils] Failed to open Lua Engine!")
    end
end
registerLuaFunctionHighlight('OpenLuaEngineWindow')

--
--- ∑ Sets the title of the main Cheat Engine window.
---   Ensures thread safety by synchronizing execution if called from a non-main thread.
---   The title is formatted using the 'FormatTitle' function based on various components.
--- @return # void
--
function Utils:SetTitle()
    if not inMainThread() then
        synchronize(function()
            self:SetTitle()
        end)
        return
    end
    local success, titleStr = pcall(function()
        return self:FormatTitle(self:GetTitleComponents())
    end)
    if success then
        getMainForm().Caption = titleStr
    else
        getMainForm().Caption = "Error: Failed to Set Title"
        logger:Error("[Utils] Failed to set title: " .. titleStr)
    end
end
registerLuaFunctionHighlight('SetTitle')

--
--- ∑ Formats the Cheat Engine window title using predefined components.
---   Constructs a formatted string with relevant game and table version information.
--- @param components table # A table containing title components such as game version, table version, and registry size.
--- @return string # The formatted title string.
--
function Utils:FormatTitle(components)
    return string.format(
        "%s %s V:%s — CET V:%s — CE %s V:%s",
        components.tableTitle or "Unknown Table",
        components.registrySizeStr or "Unknown Registry Size",
        components.gameVersion or "Unknown Game Version",
        components.tableVersion or "Unknown Table Version",
        components.ceRegistrySizeStr or "Unknown CE Registry",
        components.ceVersion or "Unknown CE Version"
    )
end
registerLuaFunctionHighlight('FormatTitle')

--
--- ∑ Retrieves components used to construct the Cheat Engine window title.
---   Extracts information such as game version, table version, registry size, and CE version.
--- @return table # A table containing title components.
--
function Utils:GetTitleComponents()
    return {
        tableTitle = self.TargetStr or "TableTitle",
        tableVersion = self.Version or "TableVersion",
        gameVersion = self.AppVersion or helper:GetFileVersionStr(helper:GetGameModulePathToFile()) or "GameVersion",
        registrySizeStr = helper:GetRegistrySizeStr() or "",
        ceRegistrySizeStr = cheatEngineIs64Bit() and "(x64)" or "(x32)",
        ceVersion = getCEVersion() or "CE Version"
    }
end
registerLuaFunctionHighlight('GetTitleComponents')

--
--- ∑ Initializes the Cheat Table by setting up the UI and window title.
---   Calls 'ui:InitializeForm()' to prepare the user interface and 'SetTitle()' to update the window title.
--- @return # void
--
function Utils:InitializeTable()
    ui:InitializeForm()
    self:SetTitle()
end
registerLuaFunctionHighlight('InitializeTable')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Utils