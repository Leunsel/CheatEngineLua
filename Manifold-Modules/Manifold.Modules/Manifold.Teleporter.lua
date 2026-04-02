local NAME = "Manifold.Teleporter.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.1.0"
local DESCRIPTION = "Manifold Framework Teleporter"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.

    ∂ v1.0.1 (2025-06-27)
        Updated Teleporter UI as well as the Save System.

    ∂ v1.0.2 (2025-06-27)
        Fixed the UI Search Query to work with the new system.

    ∂ v1.0.3 (2025-06-27)
        Added support for an Author.
        Added support for a Category.
        Updated the Teleporter UI to display categories.

    ∂ v1.0.4 (2025-06-27)
        Added a Theme to the Teleporter UI.

    ∂ v1.0.5 (2025-12-04)
        Updated the Teleporter to support different Value Types
        for position read and write operations. (Thank you, Hitman 2!)

    ∂ v1.0.6 (2025-12-07)
        Added Waypoint Specific Value Type support.

    ∂ v1.0.7 (2025-12-08)
        Added Pause Flag support to Teleporter functions, pausing
        the process while teleporting if set.

    ∂ v1.1.0 (2026-04-02)
        Refactored the Teleporter UI.
        Added automatic UI refresh after save mutations.
        Added a menu strip, toolbar, status bar and improved context menu.
        Removed obsolete legacy UI helpers and editor coupling.
        Added new Theme support to the Teleporter UI.
        Added support for a Y-Coordinate adjustment when teleporting, with configurable index and amount.
]]--

Teleporter = {
    Transform = {
        Symbol    = "TransformPtr",
        Offsets   = { 0x30, 0x34, 0x38 },
        ValueType = vtSingle
    },

    Waypoint = {
        Symbol    = "WaypointPtr",
        Offsets   = { 0x00, 0x04, 0x08 },
        ValueType = vtSingle
    },

    Additional = {
        Symbol    = nil,
        Offsets   = { 0x00, 0x04, 0x08 },
        ValueType = vtSingle
    },

    Symbols = {
        Saved  = "SavedPositionFlt",
        Backup = "BackupPositionFlt"
    },

    Settings = {
        ValueType = vtSingle,
        PauseWhileTeleporting = true,
        --- Y Coordinate Adjustment Settings ---
        AdjustYCoordinate = true,
        YCoordinateIndex = 1,
        AdjustmentAmount = 10.000
    },

    Saves = {},

    SaveFileName = "Teleporter.%s.Saves.txt",
    SaveMemoryRecordName = "[— Teleporter : Saves —] ()->"
}
Teleporter.__index = Teleporter

function Teleporter:New(config)
    local instance = setmetatable({}, self)
    self:CheckDependencies()
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
function Teleporter:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Prints module details in a readable formatted block.
--
function Teleporter:PrintModuleInfo()
    local info = self:GetModuleInfo()
    if not info then
        logger:Info("[Teleporter] Failed to retrieve module info.")
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
--- ∑ ...
--
function Teleporter:CheckDependencies()
    local dependencies = {
        { name = "logger", path = "Manifold.Logger",  init = function() logger = Logger:New() end },
        { name = "memory", path = "Manifold.Memory",  init = function() memory = Memory:New() end },
        { name = "customIO", path = "Manifold.CustomIO", init = function() customIO = CustomIO:New() end },
    }
    for _, dep in ipairs(dependencies) do
        local depName = dep.name
        if _G[depName] == nil then
            logger:Warning("[Teleporter] '" .. depName .. "' dependency not found. Attempting to load...")
            local success, result = pcall(CETrequire, dep.path)
            if success then
                logger:Info("[Teleporter] Loaded dependency '" .. depName .. "'.")
                if dep.init then dep.init() end
            else
                logger:Error("[Teleporter] Failed to load dependency '" .. depName .. "': " .. result)
            end
        else
            logger:Debug("[Teleporter] Dependency '" .. depName .. "' is already loaded")
        end
    end
end

local readFunctions = {
    [vtByte] = readByte, [vtWord] = readSmallInteger, [vtDword] = readInteger,
    [vtQword] = readQword, [vtSingle] = readFloat, [vtDouble] = readDouble
}
local writeFunctions = {
    [vtByte] = writeByte, [vtWord] = writeSmallInteger, [vtDword] = writeInteger,
    [vtQword] = writeQword, [vtSingle] = writeFloat, [vtDouble] = writeDouble
}
local valueTypeMap = { [0]="Byte", [1]="Word", [2]="Dword", [3]="Qword", [4]="Single", [5]="Double" }
local typeSizeMap = { [vtByte]=1, [vtWord]=2, [vtDword]=4, [vtQword]=8, [vtSingle]=4, [vtDouble]=8 }

--
--- ∑ Calculates the offsets for a 3D symbol based on the defined ValueType.
---   The function assumes that the symbol represents a 3D position with 3 components (X, Y, Z).
---   It calculates the offsets dynamically based on the size of the data type (e.g., vtSingle, vtDouble, etc.).
---   The offsets are always 3 in total (corresponding to X, Y, Z).
--- @returns table # A table containing the calculated offsets (e.g., { 0, 4, 8 } for vtSingle).
--
function Teleporter:CalculateSymbolOffsets()
    local size = typeSizeMap[self.Settings.ValueType] or 0
    local offsets = {}
    for i = 0, 2 do  -- Only 3 offsets: 0, 4, 8 (for 3D space)
        table.insert(offsets, i * size)
    end
    return offsets
end

--
--- ∑ Pauses the game if the setting is enabled during teleportation.
--
function Teleporter:PauseGame()
    if not self.Settings.PauseWhileTeleporting then
        logger:Debug("[Teleporter] PauseWhileTeleporting is disabled; skipping pause.")
        return
    end
    logger:Debug("[Teleporter] Pausing game for teleportation...")
    pause()
end

--
--- ∑ Unpauses the game if it was paused during teleportation.
--
function Teleporter:ResumeGame()
    if not self.Settings.PauseWhileTeleporting then
        logger:Debug("[Teleporter] PauseWhileTeleporting is disabled; skipping resume.")
        return
    end
    logger:Debug("[Teleporter] Resuming game after teleportation...")
    unpause()
end

--
--- ∑ Resolves a memory address using a teleporter function.
--- @param addressStr string # The address expression to resolve.
--- @param isPointer boolean # Whether the address should be resolved as a pointer.
--- @return integer|nil # The resolved address or nil on failure.
--
function Teleporter:ResolveAddress(addressStr, isPointer)
    if type(addressStr) ~= "string" or addressStr == "" then
        logger:Error("[Teleporter] Invalid address string provided for resolution.")
        return nil
    end
    local resolvedAddress = memory:SafeGetAddress(isPointer and ("[" .. addressStr .. "]+0") or addressStr)
    if not resolvedAddress then
        logger:ForceWarningF("[Teleporter] Failed to resolve address '%s' (Pointer: %s)", addressStr, tostring(isPointer))
        return nil
    end
    logger:DebugF("[Teleporter] Resolved address '%s' (Pointer: %s) -> 0x%X", addressStr, tostring(isPointer), resolvedAddress)
    return resolvedAddress
end

--
--- ∑ ...
--
function Teleporter:SetValueType(valueType)
    local typeName = valueTypeMap[valueType] or "Unknown"
    logger:DebugF("[Teleporter] Attempting to set ValueType: %s (ID: %d)", typeName, valueType)
    if readFunctions[valueType] and writeFunctions[valueType] then
        self.Settings.ValueType = valueType
        logger:InfoF("[Teleporter] Set Teleporter Value Type To %s (ID: %d)", typeName, valueType)
    else
        logger:ErrorF("[Teleporter] Invalid Value Type for Teleporter: %s (ID: %d)", typeName, valueType)
        logger:Debug("[Teleporter] Available Value Types: " .. table.concat(valueTypeMap, ", "))
    end
end
registerLuaFunctionHighlight('SetValueType')

--
--- ∑ Reads a position from memory based on a symbol and offsets.
--- @param symbol string # The base address or symbol to resolve.
--- @param offsets table # A table of integer offsets to apply.
--- @param isPointerRead boolean # Whether the address is a pointer.
--- @return table|nil # A table containing the position values or nil on failure.
--
function Teleporter:ReadPositionFromMemory(symbol, offsets, isPointerRead, valueType)
    if type(symbol) ~= "string" or symbol == "" then
        logger:Error("[Teleporter] Invalid symbol for position read.")
        return nil
    end
    if type(offsets) ~= "table" or #offsets == 0 then
        logger:Error("[Teleporter] Invalid or empty offsets for position read.")
        return nil
    end
    local baseAddress = self:ResolveAddress(symbol, isPointerRead)
    if not baseAddress then
        logger:Warning(string.format("[Teleporter] Failed to resolve address '%s' (Pointer: %s)", symbol, tostring(isPointerRead)))
        return nil
    end
    local readFunc = readFunctions[valueType]
    if not readFunc then
        logger:Error(string.format("[Teleporter] Unsupported value type '%s'", tostring(valueType)))
        return nil
    end
    local position = {}
    for i, offset in ipairs(offsets) do
        position[i] = readFunc(baseAddress + offset)
        -- Early-Out if "any" read fails...
        if not position[i] then
            return nil
        end
    end
    logger:Debug(string.format("[Teleporter] Read position from '0x%08X' -> {%.3f, %.3f, %.3f}", baseAddress, position[1], position[2], position[3]))
    return position
end
registerLuaFunctionHighlight('ReadPositionFromMemory')

--
--- ∑ Writes a position to memory based on a symbol and offsets.
--- @param symbol string # The base address or symbol to resolve.
--- @param offsets table # A table of integer offsets to apply.
--- @param position table # A table of values to write.
--- @param isPointerWrite boolean # Whether the address is a pointer.
--- @return boolean # Returns true if successful, false otherwise.
--
function Teleporter:WritePositionToMemory(symbol, offsets, position, isPointerWrite, valueType)
    if type(symbol) ~= "string" or symbol == "" then
        logger:Error("[Teleporter] Invalid symbol for position write.")
        return false
    end
    if type(offsets) ~= "table" or #offsets == 0 then
        logger:Error("[Teleporter] Invalid or empty offsets for position write.")
        return false
    end
    if type(position) ~= "table" or #position ~= #offsets then
        logger:Error("[Teleporter] Mismatched offsets and position values.")
        return false
    end
    local baseAddress = self:ResolveAddress(symbol, isPointerWrite)
    if not baseAddress then
        logger:WarningF("[Teleporter] Failed to resolve address '%s' (Pointer: %s)", symbol, tostring(isPointerWrite))
        return false
    end
    local writeFunc = writeFunctions[valueType]
    if not writeFunc then
        logger:ErrorF("[Teleporter] Unsupported value type '%s'", tostring(valueType))
        return false
    end
    for i, offset in ipairs(offsets) do
        if not writeFunc(baseAddress + offset, position[i]) then
            logger:Error(string.format("[Teleporter] Failed to write value at offset '0x%08X'", offset))
            return false
        end
    end
    logger:InfoF("[Teleporter] Wrote position to '0x%08X' -> {%.3f, %.3f, %.3f}", baseAddress, position[1], position[2], position[3])
    return true
end
registerLuaFunctionHighlight('WritePositionToMemory')

--
--- ∑ Reads the current position from memory.
--- @returns # the current coordinates as a table (x, y, z).
--
function Teleporter:GetCurrentPosition()
    return self:ReadPositionFromMemory(self.Transform.Symbol, self.Transform.Offsets, true, self.Transform.ValueType)
end
registerLuaFunctionHighlight('GetCurrentPosition')

--
--- ∑ Reads the current saved position from memory.
--- @returns # the current saved coordinates as a table (x, y, z).
--
function Teleporter:GetSavedPosition()
    return self:ReadPositionFromMemory(self.Symbols.Saved, self:CalculateSymbolOffsets(), false, self.Settings.ValueType)
end
registerLuaFunctionHighlight('GetSavedPosition')

--
--- ∑ Reads the current backup position from memory.
--- @returns # the current backup coordinates as a table (x, y, z).
--
function Teleporter:GetBackupPosition()
    return self:ReadPositionFromMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), false, self.Settings.ValueType)
end
registerLuaFunctionHighlight('GetBackupPosition')

--
--- ∑ Logs the distance traveled when teleporting.
--- @param oldPosition # The previous position {x, y, z}.
--- @param newPosition # The new position {x, y, z}.
--
function Teleporter:LogDistanceTraveled(oldPosition, newPosition)
    if not oldPosition or not newPosition then
        logger:Warning("[Teleporter] Cannot log distance traveled: missing position data.")
        return
    end
    local function calculateDistance(pos1, pos2)
        local dx, dy, dz = pos2[1] - pos1[1], pos2[2] - pos1[2], pos2[3] - pos1[3]
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    local distance = calculateDistance(oldPosition, newPosition)
    logger:InfoF("[Teleporter] Distance traveled: %.3f Units", distance)
end

--
--- ∑ Saves the current position to memory for later retrieval.
--- @returns # true if the position was successfully saved, false otherwise.
--
function Teleporter:SaveCurrentPosition()
    local currentPosition = self:GetCurrentPosition()
    if not currentPosition then
        logger:Error("[Teleporter] Failed to read current position for saving. Is it populated?")
        return false
    end
    local success = self:WritePositionToMemory(self.Symbols.Saved, self:CalculateSymbolOffsets(), currentPosition, false, self.Transform.ValueType)
    if success then
        logger:InfoF("[Teleporter] Saved position -> {%.3f, %.3f, %.3f}", currentPosition[1], currentPosition[2], currentPosition[3])
    end
    return success
end
registerLuaFunctionHighlight('SaveCurrentPosition')

--
--- ∑ Returns a copied target position and applies the configured coordinate adjustment if enabled.
--- @param position table # The source position table {x, y, z}.
--- @return table|nil # The copied and adjusted target position, or nil on invalid input.
--
function Teleporter:GetAdjustedTargetPosition(position)
    if type(position) ~= "table" or #position ~= 3 then
        logger:Error("[Teleporter] Invalid target position for adjustment.")
        return nil
    end
    local adjusted = { position[1], position[2], position[3] }
    if not self.Settings.AdjustYCoordinate then
        return adjusted
    end
    local coordinateIndex = tonumber(self.Settings.YCoordinateIndex) or 1
    local adjustmentAmount = tonumber(self.Settings.AdjustmentAmount) or 0
    if coordinateIndex < 1 or coordinateIndex > #adjusted then
        logger:WarningF("[Teleporter] Invalid YCoordinateIndex '%s'. Skipping adjustment.", tostring(self.Settings.YCoordinateIndex))
        return adjusted
    end
    adjusted[coordinateIndex] = adjusted[coordinateIndex] + adjustmentAmount
    logger:DebugF("[Teleporter] Adjusted coordinate index %d by %.3f -> {%.3f, %.3f, %.3f}",
        coordinateIndex, adjustmentAmount, adjusted[1], adjusted[2], adjusted[3])
    return adjusted
end
registerLuaFunctionHighlight('GetAdjustedTargetPosition')

--
--- ∑ Loads the previously saved position from memory and teleports the player there.
--- @returns # true if the position was successfully loaded, false otherwise.
--
function Teleporter:LoadSavedPosition()
    local currentPosition = self:GetCurrentPosition()
    local savedPosition = self:GetSavedPosition()
    if not savedPosition then
        logger:Error("[Teleporter] No saved position found. Is it populated?")
        return false
    end
    local targetPosition = self:GetAdjustedTargetPosition(savedPosition)
    if not targetPosition then
        return false
    end
    self:PauseGame()
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, targetPosition, true, self.Transform.ValueType)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, targetPosition, true, self.Additional.ValueType)
    end
    self:ResumeGame()
    if success then
        logger:InfoF("[Teleporter] Loaded saved position -> {%.3f, %.3f, %.3f}", targetPosition[1], targetPosition[2], targetPosition[3])
        self:LogDistanceTraveled(currentPosition, targetPosition)
        if self.Symbols and self.Symbols.Backup then
            self:WritePositionToMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), currentPosition, false, self.Settings.ValueType)
        else
            logger:Warning("[Teleporter] Backup symbol not found. Unable to store previous position.")
        end
    else
        logger:Error("[Teleporter] Something went wrong when loading the saved position.")
    end
    return success
end
registerLuaFunctionHighlight('LoadSavedPosition')

--
--- ∑ Loads the backup position from memory and teleports the player there.
--- @returns # true if the backup position was successfully loaded, false otherwise.
--
function Teleporter:LoadBackupPosition()
    local currentPosition = self:GetCurrentPosition()
    local backupPosition = self:GetBackupPosition()
    if not backupPosition then
        logger:Error("[Teleporter] No backup position found. Is it populated?")
        return false
    end
    local targetPosition = self:GetAdjustedTargetPosition(backupPosition)
    if not targetPosition then
        return false
    end
    self:PauseGame()
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, targetPosition, true, self.Transform.ValueType)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, targetPosition, true, self.Additional.ValueType)
    end
    self:ResumeGame()
    if success then
        logger:InfoF("[Teleporter] Loaded backup position -> {%.3f, %.3f, %.3f}", targetPosition[1], targetPosition[2], targetPosition[3])
        self:LogDistanceTraveled(currentPosition, targetPosition)
        if self.Symbols and self.Symbols.Backup then
            self:WritePositionToMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), currentPosition, false, self.Settings.ValueType)
        else
            logger:Warning("[Teleporter] Backup symbol not found. Unable to store previous position.")
        end
    else
        logger:Error("[Teleporter] Something went wrong when loading the backup position.")
    end
    return success
end
registerLuaFunctionHighlight('LoadBackupPosition')

--
--- ∑ Teleports the player to the specified coordinates.
--- @param position # A table containing the target coordinates {x, y, z}.
--- @returns # true if the teleportation was successful, false otherwise.
--
function Teleporter:TeleportToCoordinates(position)
    if type(position) ~= "table" or #position ~= 3 then
        logger:Error("[Teleporter] Invalid position format. Expected {x, y, z}.")
        return false
    end
    local currentPosition = self:GetCurrentPosition()
    if not currentPosition then
        logger:Error("[Teleporter] Unable to retrieve current position.")
        return false
    end
    local targetPosition = self:GetAdjustedTargetPosition(position)
    if not targetPosition then
        return false
    end
    self:PauseGame()
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, targetPosition, true, self.Transform.ValueType)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, targetPosition, true, self.Additional.ValueType)
    end
    self:ResumeGame()
    if success then
        logger:InfoF("[Teleporter] Teleported to coordinates -> {%.3f, %.3f, %.3f}", targetPosition[1], targetPosition[2], targetPosition[3])
        self:LogDistanceTraveled(currentPosition, targetPosition)
        if self.Symbols and self.Symbols.Backup then
            self:WritePositionToMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), currentPosition, false, self.Settings.ValueType)
        else
            logger:Warning("[Teleporter] Backup symbol not found. Unable to store previous position.")
        end
    else
        logger:Error("[Teleporter] Teleportation failed.")
    end
    return success
end
registerLuaFunctionHighlight('TeleportToCoordinates')

--
--- ∑ Teleports the player to the currently set waypoint.
--- @returns # true if teleportation was successful, false otherwise.
--
function Teleporter:TeleportToWaypoint()
    local currentPosition = self:GetCurrentPosition()
    local waypointPosition = self:ReadPositionFromMemory(self.Waypoint.Symbol, self.Waypoint.Offsets, true, self.Waypoint.ValueType)
    if not waypointPosition then
        logger:Error("[Teleporter] No waypoint position found.")
        return false
    end
    local targetPosition = self:GetAdjustedTargetPosition(waypointPosition)
    if not targetPosition then
        return false
    end
    self:PauseGame()
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, targetPosition, true, self.Transform.ValueType)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, targetPosition, true, self.Additional.ValueType)
    end
    self:ResumeGame()
    if success then
        logger:InfoF("[Teleporter] Teleported to waypoint -> {%.3f, %.3f, %.3f}", targetPosition[1], targetPosition[2], targetPosition[3])
        self:LogDistanceTraveled(currentPosition, targetPosition)
        if self.Symbols and self.Symbols.Backup then
            self:WritePositionToMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), currentPosition, false, self.Settings.ValueType)
        else
            logger:Warning("[Teleporter] Backup symbol not found. Unable to store previous position.")
        end
    end
    return success
end
registerLuaFunctionHighlight('TeleportToWaypoint')

-- .....................................................

--
--- ∑ Validates the name of a save or waypoint.
--- @param name string # The name to validate.
--- @param action string # The action for which the name is being validated.
--- @returns boolean # true if the name is valid, false otherwise.
--
local function validateName(name, action)
    if not name or type(name) ~= "string" then
        logger:ErrorF("[Teleporter] Invalid %s Name: '%s'.", action, tostring(name))
        return false
    end
    return true
end

--
--- ∑ Teleports the player to a saved position.
--- @param name string # The name of the save to teleport to.
--- @return boolean # true if teleportation was successful, false otherwise.
--
function Teleporter:TeleportToSave(name)
    if not validateName(name, "Save") then
        logger:Error("[Teleporter] Invalid save name.")
        return false
    end
    local savePosition = self.Saves and self.Saves[name]
    if not savePosition or type(savePosition) ~= "table" or not savePosition.X or not savePosition.Y or not savePosition.Z then
        logger:ErrorF("[Teleporter] Save Not Found or invalid format: '%s'", name)
        return false
    end
    local success = self:TeleportToCoordinates({ savePosition.X, savePosition.Y, savePosition.Z --[[+ 10.000 ]] })
    if success then
        logger:InfoF("[Teleporter] Teleported to Save: '%s'", name)
    end
    return success
end
registerLuaFunctionHighlight('TeleportToSave')

--
--- ∑ Clears all child records from a given memory record, effectively resetting it.
--
function Teleporter:ClearSubrecords(record)
    while record ~= nil and record.Count > 0 do
        memoryrecord_delete(record.Child[0])
    end
end
registerLuaFunctionHighlight('ClearSubrecords')

--
--- ∑ Ensures the existence of the Teleporter directory within the DataDir.
---   If missing, it creates the directory.
--- @return string|nil # The Teleporter directory path if successful, otherwise nil.
--
function Teleporter:EnsureTeleporterDir()
    local teleporterDir = customIO.DataDir .. "\\Teleporter"
    if not customIO:EnsureDataDirectory() then
        logger:Warning("[Teleporter] Data Directory missing; cannot ensure Teleporter Directory.")
        return nil
    end
    local exists, err = customIO:DirectoryExists(teleporterDir)
    if not exists and err then
        logger:Error("[Teleporter] Failed to check Teleporter Dir: " .. err)
        return nil
    end
    if not exists then
        logger:Warning("[Teleporter] Teleporter Dir missing; creating it...")
        local ok, err = customIO:CreateDirectory(teleporterDir)
        if not ok then
            logger:Error("[Teleporter] Create Teleporter Dir failed: " .. (err or "Unknown error"))
            return nil
        end
        logger:Info("[Teleporter] Teleporter Dir created.")
    end
    return teleporterDir
end
registerLuaFunctionHighlight('EnsureTeleporterDir')

--
--- ∑ Retrieves the expected save file path for Teleporter state.
---   Ensures the Teleporter directory exists before returning the path.
--- @return string|nil # The full save file path if successful, otherwise nil.
--
function Teleporter:GetSaveFilePath()
    local teleporterDir = self:EnsureTeleporterDir()
    if not teleporterDir then
        logger:Error("[Teleporter] Cannot determine save file path; Teleporter directory is missing.")
        return nil, nil
    end
    local saveFilePath = string.format(self.SaveFileName, utils:GetTargetNoExt())
    logger:Info("[Teleporter] Save file path: " .. saveFilePath)
    return teleporterDir .. "\\" .. saveFilePath, saveFilePath
end
registerLuaFunctionHighlight('GetSaveFilePath')

--
--- ∑ Attempts to load the teleporter lookup table.
---   First, checks DataDir/Teleporter. If unavailable, falls back to TableFiles.
---   If both fail, logs an error.
--- @return table|nil # The loaded teleporter data, or nil on failure.
--
function Teleporter:SaveLookup()
    local saveFilePath, saveFileName = self:GetSaveFilePath()
    if saveFilePath then
        logger:Info("[Teleporter] Attempting to load Teleporter save file from '" .. saveFilePath .. "'")
        local data, err = customIO:ReadFromFileAsJson(saveFilePath)
        if data then
            self.Saves = data
            local saveCount = 0
            for _, _ in pairs(self.Saves) do
                saveCount = saveCount + 1
            end
            logger:Info("[Teleporter] Successfully loaded save data with " .. tostring(saveCount) .. " saves.")
            return data
        elseif err then
            logger:Warning("[Teleporter] Error loading save file: " .. err)
        end
    end
    logger:Info("[Teleporter] Attempting to load Teleporter data from TableFiles ('" .. saveFileName .. "')")
    local tableData, tableErr = customIO:ReadFromTableFileAsJson(saveFileName)
    if tableData then
        self.Saves = tableData
        local saveCount = 0
        for _, _ in pairs(self.Saves) do
            saveCount = saveCount + 1
        end
        logger:Info("[Teleporter] Successfully loaded table data with " .. tostring(saveCount) .. " saves.")
        return tableData
    elseif tableErr then
        logger:Warning("[Teleporter] Error loading from TableFiles: " .. tableErr)
    end
    logger:Warning("[Teleporter] No valid Teleporter save data found.")
    return nil
end
registerLuaFunctionHighlight('SaveLookup')

--
--- ∑ Saves the Teleporter lookup table to a Table File.
--- @return boolean # True if successful, false otherwise.
--
function Teleporter:WriteSavesToTableFile()
    local _, saveFileName = self:GetSaveFilePath()
    if not self.Saves or not next(self.Saves) then
        logger:Warning("[Teleporter] No data available to save to TableFiles.")
        return false
    end
    local success, err = customIO:WriteToTableFileAsJson(saveFileName, self.Saves)
    if success then
        logger:Info("[Teleporter] Successfully saved Teleporter data to TableFiles.")
        return true
    else
        logger:Error("[Teleporter] Failed to save Teleporter data to TableFiles: " .. (err or "Unknown error"))
        return false
    end
end
registerLuaFunctionHighlight('WriteSavesToTableFile')

--
--- ∑ Saves the Teleporter lookup table to DataDir/Teleporter.
--- @return boolean # True if successful, false otherwise.
--
function Teleporter:WriteSavesToDataDir()
    local saveFilePath = select(1, self:GetSaveFilePath())
    if not self.Saves or not next(self.Saves) then
        logger:Warning("[Teleporter] No data available to save to DataDir.")
        return false
    end
    local success, err = customIO:WriteToFileAsJson(saveFilePath, self.Saves)
    if success then
        logger:Info("[Teleporter] Successfully saved Teleporter data to DataDir.")
        return true
    else
        logger:Error("[Teleporter] Failed to save Teleporter data to DataDir: " .. (err or "Unknown error"))
        return false
    end
end
registerLuaFunctionHighlight('WriteSavesToDataDir')

--
--- ∑ Logs detailed errors when a save position is invalid, including the name of the save and the contents of the position table.
--- @param name string # The name of the save being validated.
--- @param position table # The position table to validate, expected to contain numeric values at indices 1, 2, and 3.
--- @returns boolean # true if the position is valid, false if it is invalid and an error was logged.
--
local function logSavePositionError(name, position)
    if not position or not position[1] or not position[2] or not position[3] then
        if type(position) == "table" then
            logger:ErrorF("[Teleporter] Invalid position for save '%s'. Position is a table, contents: X=%s, Y=%s, Z=%s", 
                           name, tostring(position[1]), tostring(position[2]), tostring(position[3]))
        else
            logger:ErrorF("[Teleporter] Invalid position for save '%s'. Position is not a table: %s", name, tostring(position))
        end
        return false
    end
    return true
end

--
--- ∑ Retrieves the current system username for use as the default author.
--- @returns string # The current username or "Unknown" if it cannot be determined.
--
function Teleporter:GetCurrentAuthor()
    return os.getenv("USERNAME") or os.getenv("USER") or "Unknown"
end

--
--- ∑ Ensures that the UI state table is initialized and returns it.
--- The UI state holds references to form controls and other relevant data for managing the Teleporter UI.
--- If the UI state is not already initialized, this function will create it with default values.
--- @return table # The UI state table containing references to form controls and other UI-related data.
--
function Teleporter:EnsureUiState()
    self.UiState = self.UiState or {
        Form = nil,
        TreeView = nil,
        SearchEdit = nil,
        NameEdit = nil,
        AuthorEdit = nil,
        CategoryEdit = nil,
        XEdit = nil,
        YEdit = nil,
        ZEdit = nil,
        DescriptionEdit = nil,
        StatusLabel = nil,
        CurrentSelection = nil,
        SearchQuery = "",
        IsRefreshing = false,
    }
    return self.UiState
end

--
--- ∑ Counts the number of saves currently stored in the Teleporter's Saves table.
--- @returns integer # The total number of saves.
--
function Teleporter:CountSaves()
    local count = 0
    for _ in pairs(self.Saves or {}) do
        count = count + 1
    end
    return count
end

--
--- ∑ Persists the current saves to storage. It first attempts to write to DataDir, and if that fails, it falls back to writing to TableFiles. Logs errors if both methods fail.
--- @param preferDataDir boolean # Whether to prefer saving to DataDir first. Defaults to true. If false, it will attempt to save to TableFiles first.
--- @returns boolean # true if the saves were successfully persisted, false otherwise.
--
function Teleporter:PersistSaves(preferDataDir)
    local ok = false
    if preferDataDir ~= false then
        ok = self:WriteSavesToDataDir()
        if not ok then
            logger:Warning("[Teleporter] Failed to persist saves to DataDir. Falling back to TableFile...")
        end
    end
    if not ok then
        ok = self:WriteSavesToTableFile()
    end
    if not ok then
        logger:Error("[Teleporter] Failed to persist Teleporter saves.")
    end
    return ok
end

--
--- ∑ Sets the status text in the UI, typically used to provide feedback to the user about the current state of the Teleporter (e.g., "Ready", "Error: Invalid Save Name", etc.).
--- @param text string # The status text to display. If nil or empty, defaults to "Ready".
--
function Teleporter:SetStatus(text)
    local ui = self:EnsureUiState()
    if ui.StatusLabel then
        ui.StatusLabel.Caption = text or "Ready"
    end
end

function Teleporter:ClearEditor()
    local ui = self:EnsureUiState()
    if ui.NameEdit then ui.NameEdit.Text = "" end
    if ui.AuthorEdit then ui.AuthorEdit.Text = self:GetCurrentAuthor() end
    if ui.CategoryEdit then ui.CategoryEdit.Text = "" end
    if ui.XEdit then ui.XEdit.Text = "" end
    if ui.YEdit then ui.YEdit.Text = "" end
    if ui.ZEdit then ui.ZEdit.Text = "" end
    if ui.DescriptionEdit then ui.DescriptionEdit.Lines.Text = "" end
    ui.CurrentSelection = nil
end

--
--- ∑ Retrieves the currently selected save name from the UI state.
--- @returns string|nil # The name of the currently selected save, or nil if no selection.
--
function Teleporter:GetSelectedSaveName()
    local ui = self:EnsureUiState()
    return ui.CurrentSelection
end

--
--- ∑ Sets the currently selected save name in the UI state.
--- @param name string # The name of the save to set as selected.
--
function Teleporter:SetSelectedSaveName(name)
    local ui = self:EnsureUiState()
    ui.CurrentSelection = name
end

--
--- ∑ Loads a save by name into the editor fields. Returns false if the save is not found.
--- @param name string # The name of the save to load.
--- @returns boolean # true if the save was loaded successfully, false otherwise.
--
function Teleporter:LoadSaveIntoEditor(name)
    local ui = self:EnsureUiState()
    local save = self.Saves and self.Saves[name]
    if not save then
        self:ClearEditor()
        return false
    end
    ui.CurrentSelection = name
    ui.NameEdit.Text = name
    ui.AuthorEdit.Text = save.Author or self:GetCurrentAuthor()
    ui.CategoryEdit.Text = save.Category or ""
    ui.XEdit.Text = tostring(save.X or "")
    ui.YEdit.Text = tostring(save.Y or "")
    ui.ZEdit.Text = tostring(save.Z or "")
    ui.DescriptionEdit.Lines.Text = save.Description or ""
    return true
end

--
--- ∑ Attempts to parse the position from the editor fields. Returns nil if any field is invalid.
--- @returns table|nil # A table containing the position {x, y, z} or nil if parsing fails.
--
function Teleporter:TryGetEditorPosition()
    local ui = self:EnsureUiState()
    local x = tonumber(ui.XEdit.Text)
    local y = tonumber(ui.YEdit.Text)
    local z = tonumber(ui.ZEdit.Text)
    if not x or not y or not z then
        return nil
    end
    return { x, y, z }
end

--
--- ∑ Generates a unique copy name for a save based on an existing name.
--- @param baseName string # The original name to base the copy name on.
--- @returns string # A unique name for the copied save (e.g., "Save (Copy)", "Save (Copy 2)", etc.).
--
function Teleporter:GenerateUniqueCopyName(baseName)
    local index = 1
    local name = string.format("%s (Copy)", baseName)
    while self.Saves and self.Saves[name] do
        index = index + 1
        name = string.format("%s (Copy %d)", baseName, index)
    end
    return name
end

--
--- ∑ Refreshes the Teleporter UI, optionally preserving the current selection.
--- @param preserveSelection boolean # Whether to preserve the current selection after refresh. Defaults to true.
--
function Teleporter:RefreshUi(preserveSelection)
    local ui = self:EnsureUiState()
    if ui.IsRefreshing or not ui.TreeView then
        return
    end
    ui.IsRefreshing = true
    local previousSelection = preserveSelection ~= false and ui.CurrentSelection or nil
    local query = (ui.SearchEdit and ui.SearchEdit.Text or ui.SearchQuery or ""):lower()
    ui.TreeView.beginUpdate()
    ui.TreeView.Items:clear()
    self:EnsureAuthorsAndCategories()
    local grouped = {}
    for saveName, data in pairs(self.Saves or {}) do
        if type(saveName) == "string" and type(data) == "table" and data.X and data.Y and data.Z then
            local author = data.Author or "Unknown"
            local category = (data.Category and data.Category ~= "") and data.Category or "Default"
            local description = data.Description or ""
            local haystack = string.lower(table.concat({ saveName, author, category, description }, " "))
            if query == "" or haystack:find(query, 1, true) then
                grouped[author] = grouped[author] or {}
                grouped[author][category] = grouped[author][category] or {}
                table.insert(grouped[author][category], saveName)
            end
        end
    end
    local authors = {}
    for author in pairs(grouped) do
        table.insert(authors, author)
    end
    table.sort(authors, function(a, b) return a:lower() < b:lower() end)
    for _, author in ipairs(authors) do
        local authorNode = ui.TreeView.Items:add()
        authorNode.Text = author
        local categories = {}
        for category in pairs(grouped[author]) do
            table.insert(categories, category)
        end
        table.sort(categories, function(a, b) return a:lower() < b:lower() end)
        for _, category in ipairs(categories) do
            local categoryNode = authorNode:add()
            categoryNode.Text = category
            local saves = grouped[author][category]
            table.sort(saves, function(a, b) return a:lower() < b:lower() end)
            for _, saveName in ipairs(saves) do
                local saveNode = categoryNode:add()
                saveNode.Text = saveName
                if previousSelection and previousSelection == saveName then
                    ui.TreeView.Selected = saveNode
                end
            end
        end
    end
    ui.TreeView.endUpdate()
    ui.IsRefreshing = false
    if previousSelection and self.Saves and self.Saves[previousSelection] then
        self:LoadSaveIntoEditor(previousSelection)
    elseif not previousSelection then
        self:ClearEditor()
    end
    if ui.TreeStatsLabel then
        ui.TreeStatsLabel.Caption = string.format("%d saves", self:CountSaves())
    end
    self:SetStatus(string.format("%d saves loaded", self:CountSaves()))
end

--
--- ∑ Creates a new save from the current position and persists it.
--- @param name string # The name of the save. If nil, the user will be prompted to enter a name.
--- @param category string # An optional category for the save.
--- @param description string # An optional description for the save.
--- @returns # true if the save was successfully created, false otherwise.
--
function Teleporter:CreateSaveFromCurrentPosition(name, category, description)
    local saveName = name
    if not saveName or saveName == "" then
        saveName = inputQuery("Add Save", "Enter a name for the new save:", "Location")
    end
    if not validateName(saveName, "Save") then
        return false
    end
    local position = self:GetCurrentPosition()
    if not logSavePositionError(saveName, position) then
        return false
    end
    self.Saves = self.Saves or {}
    self.Saves[saveName] = {
        X = position[1],
        Y = position[2],
        Z = position[3],
        Author = self:GetCurrentAuthor(),
        Category = category or "",
        Description = description or "",
    }
    self:PersistSaves(true)
    self:SetSelectedSaveName(saveName)
    self:RefreshUi(true)
    self:LoadSaveIntoEditor(saveName)
    self:SetStatus("Save created: " .. saveName)
    logger:InfoF("[Teleporter] Added Save: '%s'", saveName)
    return true
end

--
--- ∑ Adds a new save using the current position. If called from a non-main thread, it synchronizes the call to the main thread.
--- @returns # true if the save was successfully created, false otherwise.
--
function Teleporter:AddSave()
    if not inMainThread() then
        synchronize(function() self:AddSave() end)
        return
    end
    return self:CreateSaveFromCurrentPosition()
end

--
--- ∑ Deletes an existing save by name and persists changes.
--- @param saveName string # The name of the save to delete. If nil, the currently selected save will be used. If still nil, the user will be prompted to enter a name.
--- @returns # true if the save was successfully deleted, false otherwise.
--
function Teleporter:DeleteSave(saveName)
    if not inMainThread() then
        synchronize(function() self:DeleteSave(saveName) end)
        return
    end
    local name = saveName or self:GetSelectedSaveName() or inputQuery("Delete Save", "Enter a name for the save to delete:", "")
    if not validateName(name, "Delete") then
        return false
    end
    if not self.Saves or not self.Saves[name] then
        logger:WarningF("[Teleporter] Save Not Found: '%s'.", name)
        return false
    end
    local confirmed = messageDialog("Delete save '" .. name .. "'?", mtConfirmation, mbYes, mbNo)
    if confirmed ~= mrYes then
        return false
    end
    self.Saves[name] = nil
    self:PersistSaves(true)
    self:SetSelectedSaveName(nil)
    self:RefreshUi(false)
    self:ClearEditor()
    self:SetStatus("Save deleted: " .. name)
    logger:InfoF("[Teleporter] Deleted Save: '%s'.", name)
    return true
end

--
--- ∑ Renames an existing save to a new name and persists changes.
--- @param oldName string # The current name of the save to rename. If nil, the currently selected save will be used.
--- @param newName string # The new name for the save. If nil, the user will be prompted to enter a new name.
--- @returns # true if the save was successfully renamed, false otherwise.
--
function Teleporter:RenameSave(oldName, newName)
    if not inMainThread() then
        synchronize(function() self:RenameSave(oldName, newName) end)
        return
    end
    local sourceName = oldName or self:GetSelectedSaveName()
    if not validateName(sourceName, "Old") then
        return false
    end
    if not self.Saves or not self.Saves[sourceName] then
        logger:ErrorF("[Teleporter] Save Not Found for rename: '%s'.", sourceName)
        return false
    end
    local targetName = newName or inputQuery("Rename Save", "Enter a new name:", sourceName)
    if not validateName(targetName, "New") then
        return false
    end
    if sourceName ~= targetName and self.Saves[targetName] then
        logger:ErrorF("[Teleporter] Save Name Already Exists: '%s'.", targetName)
        return false
    end
    self.Saves[targetName] = self.Saves[sourceName]
    if targetName ~= sourceName then
        self.Saves[sourceName] = nil
    end
    self:PersistSaves(true)
    self:SetSelectedSaveName(targetName)
    self:RefreshUi(true)
    self:LoadSaveIntoEditor(targetName)
    self:SetStatus(string.format("Renamed '%s' -> '%s'", sourceName, targetName))
    logger:InfoF("[Teleporter] Renamed Save: '%s' to '%s'.", sourceName, targetName)
    return true
end

--
--- ∑ Duplicates the currently selected save with a new unique name and persists it.
--- @returns # true if the save was successfully duplicated, false otherwise.
--
function Teleporter:DuplicateSelectedSave()
    local sourceName = self:GetSelectedSaveName()
    if not sourceName or not self.Saves or not self.Saves[sourceName] then
        logger:Warning("[Teleporter] No valid save selected for duplication.")
        return false
    end
    local newName = self:GenerateUniqueCopyName(sourceName)
    local src = self.Saves[sourceName]
    self.Saves[newName] = {
        X = src.X,
        Y = src.Y,
        Z = src.Z,
        Author = src.Author or self:GetCurrentAuthor(),
        Category = src.Category or "",
        Description = src.Description or "",
    }
    self:PersistSaves(true)
    self:SetSelectedSaveName(newName)
    self:RefreshUi(true)
    self:LoadSaveIntoEditor(newName)
    self:SetStatus("Save duplicated: " .. newName)
    logger:InfoF("[Teleporter] Duplicated save '%s' as '%s'.", sourceName, newName)
    return true
end

--
--- ∑ Updates the currently selected save with values from the editor and persists changes.
--- @returns # true if the save was successfully updated, false otherwise.
--
function Teleporter:UpdateSelectedSaveFromEditor()
    local ui = self:EnsureUiState()
    local oldName = self:GetSelectedSaveName() or ui.NameEdit.Text
    local newName = ui.NameEdit.Text
    local position = self:TryGetEditorPosition()
    if not validateName(newName, "Save") then
        return false
    end
    if not position then
        logger:Warning("[Teleporter] Invalid input for update.")
        return false
    end
    if not self.Saves or not self.Saves[oldName] then
        logger:WarningF("[Teleporter] Update failed: Save '%s' does not exist.", tostring(oldName))
        return false
    end
    if oldName ~= newName and self.Saves[newName] then
        logger:WarningF("[Teleporter] Update failed: Save '%s' already exists.", newName)
        return false
    end
    if oldName ~= newName then
        self.Saves[newName] = self.Saves[oldName]
        self.Saves[oldName] = nil
    end
    local save = self.Saves[newName]
    save.X = position[1]
    save.Y = position[2]
    save.Z = position[3]
    save.Author = ui.AuthorEdit.Text ~= "" and ui.AuthorEdit.Text or self:GetCurrentAuthor()
    save.Category = ui.CategoryEdit.Text or ""
    save.Description = ui.DescriptionEdit.Lines.Text or ""
    self:PersistSaves(true)
    self:SetSelectedSaveName(newName)
    self:RefreshUi(true)
    self:LoadSaveIntoEditor(newName)
    self:SetStatus("Save updated: " .. newName)
    logger:InfoF("[Teleporter] Save '%s' updated.", newName)
    return true
end


local DEFAULT_THEME = {
    COLOR_BG           = 0x2E2723,
    COLOR_PANEL        = 0x3A312C,
    COLOR_ACCENT       = 0x9CBC1A,
    COLOR_TEXT         = 0xEAEAEA,
    COLOR_LABEL        = 0xB0B0B0,
    COLOR_BTN          = 0x2E2723,
    COLOR_BTN_HOVER    = 0x9CBC1A,
    COLOR_BTN_TEXT     = 0xEAEAEA,
    COLOR_TAB_ACTIVE   = 0x9CBC1A,
    COLOR_TAB_INACTIVE = 0x3A312C,
    COLOR_INPUT        = 0x1E1917,
    COLOR_INPUT_TEXT   = 0xEAEAEA,
    COLOR_BORDER       = 0x74614A,
    COLOR_MUTED        = 0x8B7B68,
    COLOR_SURFACE      = 0x433933,
    COLOR_SURFACE_ALT  = 0x241F1C,
    COLOR_SUCCESS      = 0x6FD96F,
}

--
--- ∑ Resolves the current UI theme by attempting to retrieve active theme data from the host application.
--- If active theme data is available, it maps relevant color values to the Teleporter theme.
--- If no theme data is available or an error occurs, it falls back to a default theme.
--- @returns table # A table containing color values for the UI theme.
--
function Teleporter:ResolveUiTheme()
    local theme = {}
    for key, value in pairs(DEFAULT_THEME) do
        theme[key] = value
    end
    if not _G.ui then
        return theme
    end
    local activeTheme = nil
    local ok = false
    if type(ui.GetActiveThemeData) == "function" then
        ok, activeTheme = pcall(function()
            return ui:GetActiveThemeData()
        end)
    elseif type(ui.GetTheme) == "function" and ui.ActiveTheme then
        ok, activeTheme = pcall(function()
            return ui:GetTheme(ui.ActiveTheme)
        end)
    end
    if not ok or type(activeTheme) ~= "table" then
        return theme
    end
    local function themeValue(key)
        local value = activeTheme[key]
        return value
    end
    theme.COLOR_BG           = themeValue("MainForm.Color") or theme.COLOR_BG
    theme.COLOR_PANEL        = themeValue("MainForm.Foundlist3.Color") or theme.COLOR_PANEL
    theme.COLOR_ACCENT       = themeValue("AddressList.Header.Canvas.Pen.Color") or themeValue("MainForm.Splitter1.Color") or theme.COLOR_ACCENT
    theme.COLOR_TEXT         = themeValue("Memrec.DefaultForeground.Color") or theme.COLOR_TEXT
    theme.COLOR_LABEL        = themeValue("AddressList.Header.Font.Color") or theme.COLOR_LABEL
    theme.COLOR_INPUT        = themeValue("AddressList.List.BackgroundColor") or themeValue("TreeView.Color") or theme.COLOR_INPUT
    theme.COLOR_INPUT_TEXT   = themeValue("TreeView.Font.Color") or theme.COLOR_INPUT_TEXT
    theme.COLOR_BORDER       = themeValue("MainForm.Panel4.BevelColor") or theme.COLOR_BORDER
    theme.COLOR_BTN          = theme.COLOR_PANEL
    theme.COLOR_BTN_HOVER    = theme.COLOR_ACCENT
    theme.COLOR_BTN_TEXT     = theme.COLOR_TEXT
    theme.COLOR_TAB_ACTIVE   = theme.COLOR_ACCENT
    theme.COLOR_TAB_INACTIVE = theme.COLOR_SURFACE or theme.COLOR_PANEL
    theme.COLOR_MUTED        = themeValue("Memrec.GroupHeader.Color") or theme.COLOR_MUTED
    theme.COLOR_SURFACE      = themeValue("Memrec.AutoAssembler.Color") or theme.COLOR_SURFACE
    theme.COLOR_SURFACE_ALT  = themeValue("Memrec.UserDefined.Color") or theme.COLOR_SURFACE_ALT
    theme.COLOR_SUCCESS      = themeValue("Memrec.StringType.Color") or theme.COLOR_SUCCESS
    return theme
end

function Teleporter:OnThemeApplied(themeData)
    local ui = self:EnsureUiState()
    ui.Theme = nil
    if type(themeData) == "table" then
        ui.Theme = themeData
    end
    if not ui.Form then
        return
    end
    self:RebuildTeleporterTheme()
end

function Teleporter:RebuildTeleporterTheme()
    local ui = self:EnsureUiState()
    local selected = self:GetSelectedSaveName()
    local search = ui.SearchEdit and ui.SearchEdit.Text or ""
    if ui.Form then
        ui.Form.close()
    end
    self.UiState = nil
    self:InitTeleporterUI()
    local newUi = self:EnsureUiState()
    if newUi.SearchEdit then
        newUi.SearchEdit.Text = search
    end
    self:SetSelectedSaveName(selected)
    self:RefreshUi(true)
    if selected then
        self:LoadSaveIntoEditor(selected)
    end
end

--
--- ∑ Applies font settings to a given control, including font name, size, color, and style.
--- This function checks if the control and its Font property exist before applying the specified settings.
--- @param control table # The UI control to which the font settings will be applied.
--- @param color integer # An optional color value to apply to the font. If nil, the font color will not be changed.
--- @param size integer # An optional font size to apply. If nil, the font size will default to 10.
--- @param style string # An optional font style to apply (e.g., "[fsBold]"). If nil, the font style will not be changed.
--
local function UiApplyFont(control, color, size, style)
    if not control or not control.Font then
        return
    end
    control.Font.Name = "Consolas"
    control.Font.Size = size or 10
    if color ~= nil then
        control.Font.Color = color
    end
    if style then
        control.Font.Style = style
    end
end

--
--- ∑ Retrieves the current UI theme, ensuring that it is resolved and cached in the UI state for future use.
--- If the theme has not been resolved yet, this function will call ResolveUiTheme to obtain the theme data and store it in the UI state before returning it.
--- @returns table # The current UI theme containing color values for styling the Teleporter UI.
--
function Teleporter:GetUiTheme()
    local uiState = self:EnsureUiState()
    if not uiState.Theme then
        uiState.Theme = self:ResolveUiTheme()
    end
    return uiState.Theme
end

--
--- ∑ Applies the current UI theme to all relevant editor controls, ensuring consistent styling across the Teleporter UI.
--- This function iterates through each editor control (name, author, category, position fields, search, and description)
--- and applies the appropriate colors, fonts, and border styles based on the resolved theme.
--- If a control has a repaint method, it is called to ensure the visual updates take effect immediately.
-- This function should be called whenever the theme is changed or when the editor is initialized to ensure the controls match the current theme.
--
function Teleporter:ApplyEditorTheme()
    local theme = self:GetUiTheme()
    local ui = self:EnsureUiState()
    local function applyEdit(ctrl)
        if not ctrl then
            return
        end
        ctrl.ParentColor = false
        ctrl.Color = theme.COLOR_INPUT
        ctrl.BorderStyle = "bsNone"
        UiApplyFont(ctrl, theme.COLOR_INPUT_TEXT, 10)
        if ctrl.repaint then
            ctrl:repaint()
        elseif ctrl.Repaint then
            ctrl:Repaint()
        end
    end
    applyEdit(ui.NameEdit)
    applyEdit(ui.AuthorEdit)
    applyEdit(ui.CategoryEdit)
    applyEdit(ui.XEdit)
    applyEdit(ui.YEdit)
    applyEdit(ui.ZEdit)
    applyEdit(ui.SearchEdit)
    if ui.DescriptionEdit then
        ui.DescriptionEdit.ParentColor = false
        ui.DescriptionEdit.Color = theme.COLOR_INPUT
        ui.DescriptionEdit.BorderStyle = "bsNone"
        UiApplyFont(ui.DescriptionEdit, theme.COLOR_INPUT_TEXT, 10)
        if ui.DescriptionEdit.repaint then
            ui.DescriptionEdit:repaint()
        elseif ui.DescriptionEdit.Repaint then
            ui.DescriptionEdit:Repaint()
        end
    end
end

--
--- ∑ Creates a new panel control with specified parent, alignment, height, and color.
--- The panel is configured with no bevel and the specified background color.
--- @param parent table # The parent control to which the panel will be added.
--- @param align string # The alignment for the panel (e.g., "alLeft", "alTop"). Defaults to "alTop" if not provided.
--- @param height integer # An optional height for the panel. If not provided, the panel will size to its content.
--- @param color integer # The background color for the panel.
--- @returns table # The created panel control.
--
local function UiCreatePanel(parent, align, height, color)
    local panel = createPanel(parent)
    panel.Align = align or "alTop"
    if height ~= nil then
        panel.Height = height
    end
    panel.BevelOuter = "bvNone"
    panel.Color = color
    return panel
end

--
--- ∑ Creates a bordered card UI element with a header and content area, styled according to the provided theme.
--- The card consists of an outer panel with a border color, an inner panel for the background, a header panel with a title label, and a content panel for additional controls.
--- @param parent table # The parent control to which the card will be added.
--- @param align string # The alignment for the card (e.g., "alLeft", "alTop"). Defaults to "alTop" if not provided.
--- @param size integer # An optional height for the card. If not provided, the card will size to its content.
--- @param theme table # The theme containing color values for styling the card and its components.
--- @param title string # The text to display in the card's header. Defaults to "SECTION" if not provided.
--- @returns table, table, table, table # The outer panel, inner panel, header panel, and content panel of the created card, respectively.
--
local function UiCreateBorderCard(parent, align, size, theme, title)
    local outer = UiCreatePanel(parent, align, size, theme.COLOR_BORDER)
    outer.BorderSpacing.Around = 6
    local inner = UiCreatePanel(outer, "alClient", nil, theme.COLOR_PANEL)
    inner.BorderSpacing.Around = 2
    local header = UiCreatePanel(inner, "alTop", 24, theme.COLOR_PANEL)
    local headerLabel = createLabel(header)
    headerLabel.Align = "alLeft"
    headerLabel.Caption = title or "SECTION"
    headerLabel.BorderSpacing.Left = 6
    headerLabel.BorderSpacing.Top = 4
    UiApplyFont(headerLabel, theme.COLOR_LABEL, 10, "[fsBold]")
    local content = UiCreatePanel(inner, "alClient", nil, theme.COLOR_PANEL)
    content.BorderSpacing.Around = 6
    return outer, inner, header, content
end

--
--- ∑ Creates a styled label control with specified caption, theme colors, alignment, and width.
--- The label is configured to use the theme's label color and a consistent font size, and is aligned according to the provided parameters.
--- @param parent table # The parent control to which the label will be added.
--- @param caption string # The text to display in the label.
--- @param theme table # The theme containing color values for styling the label.
--- @param align string # The alignment for the label (e.g., "alLeft", "alTop"). Defaults to "alLeft" if not provided.
--- @param width integer # An optional width for the label. If not provided, the label will size to its content.
--- @returns table # The styled label control.
--
local function UiCreateLabel(parent, caption, theme, align, width)
    local label = createLabel(parent)
    label.Align = align or "alLeft"
    if width then
        label.Width = width
    end
    label.Caption = caption or ""
    UiApplyFont(label, theme.COLOR_LABEL, 10)
    return label
end

--
--- ∑ Creates a styled edit control for single-line text input, using the provided theme for consistent styling.
--- The edit control is configured with appropriate colors, font, and border style to match the overall theme of the UI.
--- @param parent table # The parent control to which the edit will be added.
--- @param theme table # The theme containing color values for styling the edit control.
--- @returns table # The styled edit control for single-line text input.
--
local function UiCreateStyledEdit(parent, theme)
    local edit = createEdit(parent)
    edit.Align = "alClient"
    edit.ParentColor = false
    edit.Color = theme.COLOR_INPUT
    edit.BorderStyle = "bsNone"
    UiApplyFont(edit, theme.COLOR_INPUT_TEXT, 10)
    return edit
end

--
--- ∑ Creates a styled memo control wrapped in themed panels for consistent styling.
--- The function returns the memo control for multi-line text input, wrapped in panels that provide padding
--- and background color according to the provided theme.
--- @param parent table # The parent control to which the memo will be added.
--- @param theme table # The theme containing color values for styling the memo and its panels.
--- @returns table # The memo control for multi-line text input.
--
local function UiCreateStyledMemo(parent, theme)
    local outer = UiCreatePanel(parent, "alClient", nil, theme.COLOR_INPUT)
    outer.BorderSpacing.Around = 1
    local inner = UiCreatePanel(outer, "alClient", nil, theme.COLOR_INPUT)
    inner.BorderSpacing.Left = 6
    inner.BorderSpacing.Right = 6
    inner.BorderSpacing.Top = 6
    inner.BorderSpacing.Bottom = 6
    local memo = createMemo(inner)
    memo.Align = "alClient"
    memo.ParentColor = false
    memo.Color = theme.COLOR_INPUT
    memo.BorderStyle = "bsNone"
    memo.WordWrap = true
    memo.ScrollBars = "ssAutoBoth"
    UiApplyFont(memo, theme.COLOR_INPUT_TEXT, 10)
    return memo
end

--
--- ∑ Creates a styled input row with a label and an edit control, wrapped in themed panels for consistent styling.
--- The function returns the edit control for data entry, the outer row panel for layout, and the label for potential updates to the caption or styling.
--- @param parent table # The parent control to which the row will be added.
--- @param caption string # The text to display in the label for this row.
--- @param theme table # The theme containing color values for styling the row and its components.
--- @returns table, table, table # The edit control for user input, the outer panel representing the row, and the label control.
--
local function UiCreateFieldRow(parent, caption, theme)
    local row = UiCreatePanel(parent, "alTop", 34, theme.COLOR_PANEL)
    row.BorderSpacing.Bottom = 6
    local border = UiCreatePanel(row, "alClient", nil, theme.COLOR_BORDER)
    local fill = UiCreatePanel(border, "alClient", nil, theme.COLOR_INPUT)
    fill.BorderSpacing.Around = 1
    local inner = UiCreatePanel(fill, "alClient", nil, theme.COLOR_INPUT)
    inner.BorderSpacing.Left = 6
    inner.BorderSpacing.Right = 8
    inner.BorderSpacing.Top = 4
    inner.BorderSpacing.Bottom = 4
    local label = createLabel(inner)
    label.Align = "alLeft"
    label.Width = 52
    label.Caption = caption
    label.Alignment = "taLeftJustify"
    label.Layout = "tlCenter"
    label.Transparent = true
    UiApplyFont(label, theme.COLOR_LABEL, 10, "[fsBold]")
    local gap = UiCreatePanel(inner, "alLeft", nil, theme.COLOR_INPUT)
    gap.Width = 6
    local edit = createEdit(inner)
    edit.BorderSpacing.Left = 10
    edit.BorderSpacing.Top = 3
    edit.Align = "alClient"
    edit.ParentColor = false
    edit.Color = theme.COLOR_INPUT
    edit.BorderStyle = "bsNone"
    edit.TextHint = ""
    UiApplyFont(edit, theme.COLOR_INPUT_TEXT, 10)
    return edit, row, label
end

--
--- ∑ Sets the visual state of a button based on whether it is being hovered over, using the provided theme for colors.
--- This function updates the button's background color and the font color of its label (if it has one) to reflect the hover state.
--- @param button table # The button control to update. Expected to have a _theme property
--- @param isHover boolean # Whether the button is currently being hovered over.
--
local function UiSetButtonState(button, isHover)
    if not button or not button._theme then
        return
    end
    local theme = button._theme
    button.Color = isHover and theme.COLOR_BTN_HOVER or theme.COLOR_BTN
    if button._label and button._label.Font then
        button._label.Font.Color = isHover and theme.COLOR_BG or theme.COLOR_BTN_TEXT
    end
end

--
--- ∑ Creates a styled panel that functions as a button, with a label centered on it, and sets up event handlers for click and hover states.
--- The button's appearance changes when hovered, and it executes the provided onClick function when clicked
--- @param parent table # The parent control to which the button will be added.
--- @param caption string # The text to display on the button.
--- @param width integer # The width of the button in pixels. If nil, a default width will be used.
--- @param theme table # The theme containing color values for styling the button.
--- @param onClick function # The function to execute when the button is clicked.
--- @returns table # The panel control that functions as a button.
--
local function UiCreatePanelButton(parent, caption, width, theme, onClick)
    local button = UiCreatePanel(parent, "alLeft", 30, theme.COLOR_BTN)
    button.Width = width or 92
    button.BevelOuter = "bvRaised"
    button.BevelWidth = 1
    button.BevelColor = theme.COLOR_BORDER
    button.Cursor = -21
    button.BorderSpacing.Right = 6
    button._theme = theme
    local label = createLabel(button)
    label.Align = "alClient"
    label.Alignment = "taCenter"
    label.Layout = "tlCenter"
    label.Caption = caption
    UiApplyFont(label, theme.COLOR_BTN_TEXT, 10, "[fsBold]")
    label.Transparent = true
    button._label = label
    local function clickHandler()
        if type(onClick) == "function" then
            onClick()
        end
    end
    button.OnClick = clickHandler
    label.OnClick = clickHandler
    button.OnMouseEnter = function() UiSetButtonState(button, true) end
    button.OnMouseLeave = function() UiSetButtonState(button, false) end
    label.OnMouseEnter = function() UiSetButtonState(button, true) end
    label.OnMouseLeave = function() UiSetButtonState(button, false) end
    return button
end

--
--- ∑ Creates the main menu strip for the Teleporter UI, populating it with "File", "Saves", and "Tools" menus and their respective items.
--- Each menu item is associated with a handler function that performs the corresponding action when clicked.
--- @param parent table # The parent control to which the menu strip will be added.
--
function Teleporter:CreateMenuStrip(parent)
    local menu = createMainMenu(parent)
    parent.Menu = menu
    local function menuItem(root, caption, handler)
        local item = createMenuItem(menu)
        item.Caption = caption
        if handler then
            item.OnClick = handler
        end
        root.add(item)
        return item
    end
    local fileItem = createMenuItem(menu)
    fileItem.Caption = "&File"
    menu.Items.add(fileItem)
    menuItem(fileItem, "Load Saves", function()
        self:SaveLookup()
        self:RefreshUi(true)
        self:SetStatus("Saves loaded")
    end)
    menuItem(fileItem, "Save To DataDir", function()
        self:WriteSavesToDataDir()
        self:SetStatus("Saved to DataDir")
    end)
    menuItem(fileItem, "Save To TableFile", function()
        self:WriteSavesToTableFile()
        self:SetStatus("Saved to TableFile")
    end)
    menuItem(fileItem, "-", nil)
    menuItem(fileItem, "Close", function()
        if self.UiState and self.UiState.Form then
            self.UiState.Form.close()
        end
    end)
    local savesItem = createMenuItem(menu)
    savesItem.Caption = "&Saves"
    menu.Items.add(savesItem)
    menuItem(savesItem, "Add Current Position", function() self:AddSave() end)
    menuItem(savesItem, "Update Selected", function() self:UpdateSelectedSaveFromEditor() end)
    menuItem(savesItem, "Duplicate Selected", function() self:DuplicateSelectedSave() end)
    menuItem(savesItem, "Rename Selected", function() self:RenameSave() end)
    menuItem(savesItem, "Delete Selected", function() self:DeleteSave() end)
    local toolsItem = createMenuItem(menu)
    toolsItem.Caption = "&Tools"
    menu.Items.add(toolsItem)
    menuItem(toolsItem, "Teleport To Selected Save", function()
        local name = self:GetSelectedSaveName()
        if name then self:TeleportToSave(name) end
    end)
    menuItem(toolsItem, "Teleport To Waypoint", function() self:TeleportToWaypoint() end)
    menuItem(toolsItem, "Save Current Runtime Position", function()
        self:SaveCurrentPosition()
        self:SetStatus("Runtime position saved")
    end)
    menuItem(toolsItem, "Load Runtime Position", function() self:LoadSavedPosition() end)
end

--
--- ∑ Creates the header panel for the Teleporter UI, containing buttons for adding, duplicating, deleting, teleporting to, and updating saves.
--- Each button is associated with a handler function that performs the corresponding action when clicked.
--- @param parent table # The parent control to which the header panel will be added.
--- @returns table # The header panel containing the action buttons.
--
function Teleporter:CreateHeader(parent)
    local theme = self:GetUiTheme()
    local header = UiCreatePanel(parent, "alTop", 30, theme.COLOR_PANEL)
    header.BevelOuter = "bvNone"
    header.BorderSpacing.Left = 6
    header.BorderSpacing.Right = 6
    header.BorderSpacing.Top = 6
    header.BorderSpacing.Bottom = 3
    local buttons = UiCreatePanel(header, "alClient", nil, theme.COLOR_PANEL)
    UiCreatePanelButton(buttons, "Add Current", 108, theme, function() self:AddSave() end)
    UiCreatePanelButton(buttons, "Duplicate", 92, theme, function() self:DuplicateSelectedSave() end)
    UiCreatePanelButton(buttons, "Delete", 80, theme, function() self:DeleteSave() end)
    UiCreatePanelButton(buttons, "Teleport", 86, theme, function()
        local name = self:GetSelectedSaveName()
        if name then self:TeleportToSave(name) end
    end)
    UiCreatePanelButton(buttons, "Update", 84, theme, function() self:UpdateSelectedSaveFromEditor() end)
    return header
end

--
--- ∑ Creates the status bar panel for the Teleporter UI, containing a label to display status messages to the user.
--- The status bar is styled according to the current UI theme and provides a method for updating the displayed status message.
--- @param parent table # The parent control to which the status bar will be added.
--- @returns table # The status bar panel containing the status label.
--
function Teleporter:CreateStatusBar(parent)
    local theme = self:GetUiTheme()
    local statusPanel = UiCreatePanel(parent, "alBottom", 26, theme.COLOR_PANEL)
    statusPanel.BevelOuter = "bvRaised"
    statusPanel.BevelColor = theme.COLOR_BORDER
    statusPanel.BevelWidth = 1
    statusPanel.BorderSpacing.Around = 6
    local label = createLabel(statusPanel)
    label.Align = "alClient"
    label.Caption = "Ready"
    label.BorderSpacing.Left = 8
    label.BorderSpacing.Top = 5
    UiApplyFont(label, theme.COLOR_TEXT, 10)
    local ui = self:EnsureUiState()
    ui.StatusLabel = label
    return statusPanel
end

--
--- ∑ Creates the main tree view panel for displaying saved locations, including a search box for filtering saves and a label showing the count of saves.
--- The tree view allows users to select saves, which will load the save details into the editor, and supports double-clicking to teleport to the selected save.
--- @param parent table # The parent control to which the tree panel will be added.
--- @returns table # The outer panel containing the tree view and related controls.
--
function Teleporter:CreateTreePanel(parent)
    local theme = self:GetUiTheme()
    local ui = self:EnsureUiState()
    local outer, inner, header, content = UiCreateBorderCard(parent, "alLeft", 330, theme, "SAVED LOCATIONS")
    outer.Width = 330
    local hint = createLabel(header)
    hint.Align = "alRight"
    hint.Caption = string.format("%d saves", self:CountSaves())
    hint.BorderSpacing.Right = 8
    hint.BorderSpacing.Top = 4
    UiApplyFont(hint, theme.COLOR_MUTED, 9)
    local searchBorder = UiCreatePanel(content, "alTop", 32, theme.COLOR_BORDER)
    searchBorder.BorderSpacing.Bottom = 6
    local searchFill = UiCreatePanel(searchBorder, "alClient", nil, theme.COLOR_INPUT)
    searchFill.BorderSpacing.Around = 1
    local searchInner = UiCreatePanel(searchFill, "alClient", nil, theme.COLOR_INPUT)
    searchInner.BorderSpacing.Left = 8
    searchInner.BorderSpacing.Right = 8
    searchInner.BorderSpacing.Top = 4
    local searchEdit = createEdit(searchInner)
    searchEdit.Align = "alClient"
    searchEdit.ParentColor = false
    searchEdit.Color = theme.COLOR_INPUT
    searchEdit.BorderStyle = "bsNone"
    searchEdit.TextHint = "Search saves..."
    UiApplyFont(searchEdit, theme.COLOR_INPUT_TEXT, 10)
    searchEdit.OnChange = function()
        self:RefreshUi(true)
    end
    ui.SearchEdit = searchEdit
    local treeBorder = UiCreatePanel(content, "alClient", nil, theme.COLOR_PANEL)
    local treeHost = UiCreatePanel(treeBorder, "alClient", nil, theme.COLOR_PANEL)
    treeHost.BorderSpacing.Around = 1
    local tree = createTreeView(treeHost)
    tree.Align = "alClient"
    tree.ReadOnly = true
    tree.AutoExpand = true
    tree.BorderStyle = "bsNone"
    tree.ScrollBars = "ssAutoBoth"
    tree.Color = theme.COLOR_PANEL
    UiApplyFont(tree, theme.COLOR_INPUT_TEXT, 10)
    ui.TreeView = tree
    ui.TreeStatsLabel = hint
    tree.OnClick = function()
        local selected = tree.Selected
        if selected and selected.Level == 2 then
            self:SetSelectedSaveName(selected.Text)
            self:LoadSaveIntoEditor(selected.Text)
            self:SetStatus("Selected: " .. selected.Text)
        end
    end
    tree.OnDblClick = function()
        local selected = tree.Selected
        if selected and selected.Level == 2 then
            self:SetSelectedSaveName(selected.Text)
            self:TeleportToSave(selected.Text)
        end
    end
    return outer
end

--
--- ∑ Creates the editor panel for viewing and editing the details of a selected save, including fields for name, author, category, position, and description.
--- The editor allows users to modify the save details and update the save, as well as fill the fields with the current in-game position.
--- @param parent table # The parent control to which the editor panel will be added.
--- @returns table # The outer panel containing the editor controls.
--
function Teleporter:CreateEditorPanel(parent)
    local theme = self:GetUiTheme()
    local outer, inner, header, content = UiCreateBorderCard(parent, "alClient", nil, theme, "SAVE EDITOR")
    local footer = UiCreatePanel(content, "alBottom", 36, theme.COLOR_PANEL)
    footer.BorderSpacing.Top = 6
    UiCreatePanelButton(footer, "Clear", 72, theme, function()
        self:ClearEditor()
        self:SetStatus("Editor cleared")
    end)
    UiCreatePanelButton(footer, "Rename", 84, theme, function()
        self:RenameSave()
    end)
    UiCreatePanelButton(footer, "Use Current Position", 148, theme, function()
        local pos = self:GetCurrentPosition()
        local ui = self:EnsureUiState()
        if pos then
            ui.XEdit.Text = tostring(pos[1])
            ui.YEdit.Text = tostring(pos[2])
            ui.ZEdit.Text = tostring(pos[3])
            self:SetStatus("Editor filled with current position")
        end
    end)
    local memoBorder = UiCreatePanel(content, "alClient", nil, theme.COLOR_BORDER)
    memoBorder.BorderSpacing.Top = 6
    memoBorder.BorderSpacing.Bottom = 6
    local description = UiCreateStyledMemo(memoBorder, theme)
    local fieldsHost = UiCreatePanel(content, "alTop", 244, theme.COLOR_PANEL)
    local bottomGroup = UiCreatePanel(fieldsHost, "alTop", 118, theme.COLOR_PANEL)
    local topGroup = UiCreatePanel(fieldsHost, "alTop", 118, theme.COLOR_PANEL)
    local categoryEdit = UiCreateFieldRow(topGroup, "Category", theme)
    local authorEdit   = UiCreateFieldRow(topGroup, "Author", theme)
    local nameEdit     = UiCreateFieldRow(topGroup, "Name", theme)
    local zEdit = UiCreateFieldRow(bottomGroup, "Z", theme)
    local yEdit = UiCreateFieldRow(bottomGroup, "Y", theme)
    local xEdit = UiCreateFieldRow(bottomGroup, "X", theme)
    local ui = self:EnsureUiState()
    ui.NameEdit = nameEdit
    ui.AuthorEdit = authorEdit
    ui.CategoryEdit = categoryEdit
    ui.XEdit = xEdit
    ui.YEdit = yEdit
    ui.ZEdit = zEdit
    ui.DescriptionEdit = description
    return outer
end

-- ∑ Creates the context menu for the tree view, providing options to teleport to a save, load it into the editor, update it from the editor, duplicate it, rename it, or delete it.
--- @returns table # The context menu.
function Teleporter:CreateTreeContextMenu()
    local ui = self:EnsureUiState()
    if not ui.TreeView then
        return
    end
    local menu = createPopupMenu(ui.TreeView)
    ui.TreeView.PopupMenu = menu
    local function addItem(caption, handler)
        local item = createMenuItem(menu)
        item.Caption = caption
        item.OnClick = handler
        menu.Items.add(item)
        return item
    end
    addItem("Teleport", function()
        local name = self:GetSelectedSaveName()
        if name then self:TeleportToSave(name) end
    end)
    addItem("Load Into Editor", function()
        local name = self:GetSelectedSaveName()
        if name then self:LoadSaveIntoEditor(name) end
    end)
    addItem("Update From Editor", function() self:UpdateSelectedSaveFromEditor() end)
    addItem("Duplicate", function() self:DuplicateSelectedSave() end)
    addItem("Rename", function() self:RenameSave() end)
    addItem("Delete", function() self:DeleteSave() end)
end

--
--- ∑ Ensures all saves have an Author field.
--
function Teleporter:EnsureAuthorsAndCategories()
    for name, data in pairs(self.Saves or {}) do
        if type(data) == "table" then
            data.Author = data.Author or self:GetCurrentAuthor()
            data.Category = data.Category or ""
            data.Description = data.Description or ""
        end
    end
end

--
--- ∑ Gets a table of save authors.
--- @returns table # A table mapping save names to their respective authors.
--
function Teleporter:GetAuthors()
    local authors = {}
    for name, save in pairs(self.Saves or {}) do
        if type(save) == "table" then
            authors[name] = save.Author or "Unknown"
        else
            authors[name] = "Unknown"
        end
    end
    return authors
end

--
--- ∑ Initializes the Teleporter UI, synchronizing if necessary.
--- If the UI already exists, it will be shown and brought to the front. Otherwise, a new UI will be created with the appropriate theme and controls.
--- @returns table # The form representing the Teleporter UI.
--
function Teleporter:InitTeleporterUI()
    if not inMainThread() then
        synchronize(function() self:InitTeleporterUI() end)
        return
    end
    local ui = self:EnsureUiState()
    ui.Theme = self:ResolveUiTheme()
    if ui.Form and ui.Form.ClassName and ui.Form.ClassName ~= "" then
        ui.Form.show()
        ui.Form.bringToFront()
        self:RefreshUi(true)
        return ui.Form
    end
    local theme = self:GetUiTheme()
    local form = createForm()
    form.Caption = "Teleporter"
    form.Width = 1120
    form.Height = 720
    form.Position = "poScreenCenter"
    form.BorderStyle = "bsSizeable"
    form.Color = theme.COLOR_BG
    form.Font.Name = "Consolas"
    form.Font.Size = 10
    form.Constraints.MinWidth = 980
    form.Constraints.MinHeight = 620
    form.show()
    ui.Form = form
    self:CreateMenuStrip(form)
    local root = UiCreatePanel(form, "alClient", nil, theme.COLOR_BG)
    self:CreateStatusBar(root)
    self:CreateHeader(root)
    local body = UiCreatePanel(root, "alClient", nil, theme.COLOR_BG)
    body.BorderSpacing.Left = 6
    body.BorderSpacing.Right = 6
    body.BorderSpacing.Bottom = 6
    self:CreateEditorPanel(body)
    local gap = UiCreatePanel(body, "alLeft", nil, theme.COLOR_BG)
    gap.Width = 6
    self:CreateTreePanel(body)
    self:CreateTreeContextMenu()
    self:ApplyEditorTheme()
    local themeTimer = createTimer(form)
    themeTimer.Interval = 1
    themeTimer.OnTimer = function(timer)
        timer.Enabled = false
        self:ApplyEditorTheme()
        if timer.destroy then
            timer:destroy()
        elseif timer.Destroy then
            timer:Destroy()
        end
    end
    form.OnClose = function(sender)
        self:SetStatus("Closed")
        ui.Form = nil
        ui.TreeView = nil
        ui.TreeStatsLabel = nil
        ui.SearchEdit = nil
        ui.NameEdit = nil
        ui.AuthorEdit = nil
        ui.CategoryEdit = nil
        ui.XEdit = nil
        ui.YEdit = nil
        ui.ZEdit = nil
        ui.DescriptionEdit = nil
        ui.StatusLabel = nil
        ui.Theme = nil
        return caFree
    end
    self:SaveLookup()
    self:RefreshUi(true)
    self:ClearEditor()
    self:SetStatus("Teleporter ready")
    form.centerScreen()
    return form
end
registerLuaFunctionHighlight('InitTeleporterUI')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Teleporter