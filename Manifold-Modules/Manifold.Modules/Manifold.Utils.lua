local NAME = "Manifold.Utils.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.1.0"
local DESCRIPTION = "Manifold Framework Utils"

--[[
    ∂ v1.1.0 (2026-08-23)
        ResolvePointerPath moved to Manifold.Memory; the name here forwards and
        is deprecated. GetTitleComponents no longer reaches for `helper`
        unguarded and now actually reaches its AppVersion fallback (TODO T8).
        GetTarget/GetTargetNoExt can return nil as documented - "" is truthy in
        Lua, so `self.Target or nil` never could. AutoDisable's two async waits
        are bounded by AutoDisableWaitTimeout; the first used to spin with no
        checkSynchronize and could hang the main thread. VERSION corrected: it
        read 1.0.3 while this changelog already said 1.0.5.

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
    AutoDisableWaitTimeout   = 5000,  
    IsRelease = false,      
}
Utils.__index = Utils


local MODULE_PREFIX = "[Utils]"

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
    class = "Utils", global = "utils",
    name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION,
    prefix = MODULE_PREFIX,
    deps = {
        { "logger", required = true },
        { "customIO", runtime = true },
        { "helper", runtime = true },
        { "memory", runtime = true },   -- only for the deprecated ResolvePointerPath forward
        { "ui", runtime = true },
    },
})

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
    return BOOTSTRAP.Ready(MODULE, instance)
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
    -- `self.Target` defaults to "" and an empty string is TRUTHY in Lua, so
    -- `self.Target or nil` could never return nil. Test the emptiness.
    if type(self.Target) ~= "string" or self.Target == "" then return nil end
    return self.Target
end
registerLuaFunctionHighlight('GetTarget')

--
--- ∑ Retrieves the target's name without the file extension.
---   If the target doesn't exist, it returns nil.
--- @return # The target name without extension or nil if no target is set.
--
function Utils:GetTargetNoExt()
    local target = self:GetTarget()
    if target == nil then return nil end
    -- customIO is declared runtime, so a table may legitimately not have it.
    if type(customIO) ~= "table" or type(customIO.StripExt) ~= "function" then
        return (target:gsub("%.[^.]*$", ""))
    end
    return customIO:StripExt(target)
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
    -- Both waits are bounded. The first one in particular used to spin with no
    -- checkSynchronize at all, so an async record that never finished processing
    -- hung the main thread with no way out. A timeout degrades to "gave up" -
    -- the record is still deactivated - instead of freezing Cheat Engine.
    local timeout = self.AutoDisableWaitTimeout or 5000
    local function waitForAsync(mr, pump)
        local waited = 0
        while mr.Async and mr.AsyncProcessing and waited < timeout do
            if pump then
                checkSynchronize()
                MainForm.repaint()
            end
            sleep(1)
            waited = waited + 1
        end
        return not (mr.Async and mr.AsyncProcessing)
    end
    local function autoDisableTimer_tick(timer)
        timer.destroy()
        local mr = AddressList.getMemoryRecordByID(id)
        if mr ~= nil and mr.Active then
            if not waitForAsync(mr, false) then
                logger:WarningF("%s AutoDisable timed out waiting for record %s to finish processing; disabling anyway.",
                                MODULE_PREFIX, tostring(id))
            end
            mr.Active = false
            waitForAsync(mr, true)
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
    if not inMainThread() then
        synchronize(function()
            self:SetAllScriptsToAsync()
        end)
        return
    end
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
    if not inMainThread() then
        synchronize(function()
            self:SetAllScriptsToNotAsync()
        end)
        return
    end
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
    message = message or "Are you sure?"
    if not inMainThread() then
        local result
        synchronize(function()
            result = self:ShowConfirmation(message)
        end)
        return result
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
    if getCustomType("Military Hours") then return end
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
    if getCustomType("Decrypted") then return end
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
registerLuaFunctionHighlight('RegisterDecryptionType')

--
--- ∑ Registers a custom memory value type for "Playtime Float" used in the game "Mewgenics".
---   Uses 8 bytes of data representing total playtime in seconds, which is then converted to a float format of hours.minutesseconds.
---   For example, 1 hour, 30 minutes, and 45 seconds would be
---   represented as 1.3045 (1 hour, 30 minutes as .30, and 45 seconds as .0045).
---   When writing a value back, the float is converted to total seconds and then to the
---   appropriate byte format for memory storage.
--- @return # void
--
function Utils:RegisterPlaytimeMilitaryType()
    if getCustomType("Playtime Float") then return end
    local TypeName  = "Playtime Float"
    local ByteCount = 8
    local IsFloat   = true
    local function bytesToValue(b1, b2, b3, b4, b5, b6, b7, b8)
        local raw = b1 | (b2 << 8) | (b3 << 16) | (b4 << 24) | (b5 << 32)| (b6 << 40) | (b7 << 48) | (b8 << 56)
        local totalSeconds = math.floor(raw / 60)
        local hours   = math.floor(totalSeconds / 3600)
        local minutes = math.floor((totalSeconds % 3600) / 60)
        local seconds = totalSeconds % 60
        return hours + (minutes / 100) + (seconds / 10000)
    end
    local function valueToBytes(value)
        local v = tonumber(value) or 0
        local hours     = math.floor(v)
        local remainder = v - hours
        local minutes = math.floor((remainder * 100) + 0.0001)
        local seconds = math.floor(((remainder * 10000) % 100) + 0.0001)
        local totalSeconds = (hours   * 3600) + (minutes * 60) +  seconds
        local raw = totalSeconds * 60
        return raw & 0xFF, ( raw >> 8 )  & 0xFF,
              ( raw >> 16 ) & 0xFF, ( raw >> 24 ) & 0xFF,
              ( raw >> 32 ) & 0xFF, ( raw >> 40 ) & 0xFF,
              ( raw >> 48 ) & 0xFF, ( raw >> 56 ) & 0xFF
    end
    registerCustomTypeLua(TypeName, ByteCount, bytesToValue, valueToBytes, IsFloat)
end
registerLuaFunctionHighlight('RegisterPlaytimeMilitaryType')

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
--- ∑ Follows a pointer chain from a base address or symbol.
--- @deprecated Moved to Manifold.Memory in Utils 1.1.0. Call
---   memory:ResolvePointerPath instead; this forwards and will be removed in 2.0.0.
---   The move was made on what the function touches: it resolved an address and
---   read pointers, both of which are Memory's goal, and touched no Utils config.
---   This forward is also strictly safer than the body it replaces, which
---   indexed the `memory` global unguarded and raised for any table that did
---   not load Manifold.Memory.
--- @param baseAddress string|number
--- @param offsets table
--- @return number|nil
--
function Utils:ResolvePointerPath(baseAddress, offsets, isLocal)
    if type(memory) ~= "table" or type(memory.ResolvePointerPath) ~= "function" then
        logger:ErrorF("%s ResolvePointerPath needs Manifold.Memory, which this table has not loaded.",
                      MODULE_PREFIX)
        return nil
    end
    return memory:ResolvePointerPath(baseAddress, offsets, isLocal)
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
    -- AppVersion defaults to "" and "" is TRUTHY in Lua, so `self.AppVersion or
    -- ...` could never reach the fallback (TODO T8). `helper` is a runtime dep,
    -- so a table is entitled not to have it - reaching for it unguarded made
    -- the window caption read "Error: Failed to Set Title" via SetTitle's pcall.
    local appVersion = (type(self.AppVersion) == "string" and self.AppVersion ~= "") and self.AppVersion or nil
    local fileVersion, registrySize = nil, ""
    if type(helper) == "table" then
        if type(helper.GetFileVersionStr) == "function" then
            fileVersion = helper:GetFileVersionStr()
        end
        if type(helper.GetRegistrySizeStr) == "function" then
            registrySize = helper:GetRegistrySizeStr() or ""
        end
    end
    return {
        tableTitle = self.TargetStr or "TableTitle",
        tableVersion = self.Version or "TableVersion",
        gameVersion = appVersion or fileVersion or "GameVersion",
        registrySizeStr = registrySize,
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
    if not inMainThread() then
        synchronize(function()
            self:InitializeTable()
        end)
        return
    end
    ui:InitializeForm()
    self:SetTitle()
end
registerLuaFunctionHighlight('InitializeTable')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Utils