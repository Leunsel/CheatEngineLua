local NAME = "Manifold.Teleporter.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.7"
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
        PauseWhileTeleporting = true
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
    logger:Debug(string.format("[Teleporter] Read position from '%s' -> {%s}", symbol, table.concat(position, ", ")))
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
            logger:Error(string.format("[Teleporter] Failed to write value at offset '%d'", offset))
            return false
        end
    end
    logger:InfoF("[Teleporter] Wrote position to '%s' -> {%s}", symbol, table.concat(position, ", "))
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
    logger:Info("[Teleporter] Distance traveled: " .. distance .. " units")
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
        logger:InfoF("[Teleporter] Saved position -> {%s}", table.concat(currentPosition, ", "))
    end
    return success
end
registerLuaFunctionHighlight('SaveCurrentPosition')

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
    -- savedPosition[3] = savedPosition[3] + 0.000
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, savedPosition, true, self.Transform.ValueType)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, savedPosition, true, self.Additional.ValueType)
    end
    if success then
        logger:InfoF("[Teleporter] Loaded saved position -> {%s}", table.concat(savedPosition, ", "))
        self:LogDistanceTraveled(currentPosition, savedPosition)
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
    -- backupPosition[3] = backupPosition[3] + 0.000
    self:PauseGame()
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, backupPosition, true, self.Transform.ValueType)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, backupPosition, true, self.Additional.ValueType)
    end
    self:ResumeGame()
    if success then
        logger:InfoF("[Teleporter] Loaded backup position -> {%s}", table.concat(backupPosition, ", "))
        self:LogDistanceTraveled(currentPosition, backupPosition)
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
    self:PauseGame()
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, position, true, self.Transform.ValueType)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, position, true, self.Additional.ValueType)
    end
    self:ResumeGame()
    if success then
        logger:InfoF("[Teleporter] Teleported to coordinates -> {%s}", table.concat(position, ", "))
        self:LogDistanceTraveled(currentPosition, position)
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
    self:PauseGame()
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, waypointPosition, true, self.Transform.ValueType)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, waypointPosition, true, self.Additional.ValueType)
    end
    self:ResumeGame()
    if success then
        logger:InfoF("[Teleporter] Teleported to waypoint -> {%s}", table.concat(waypointPosition, ", "))
        self:LogDistanceTraveled(currentPosition, waypointPosition)
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
--- ∑ ...
--
local function validateName(name, action)
    if not name or type(name) ~= "string" then
        logger:ErrorF("[Teleporter] Invalid %s Name: '%s'.", action, tostring(name))
        return false
    end
    return true
end

--
--- ∑ ...
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

function Teleporter:GetCurrentAuthor()
    return os.getenv("USERNAME") or os.getenv("USER") or "Unknown"
end

--
--- ∑ Adds a new teleport save and writes to file storage.
--- @param name string # The name of the save.
--
function Teleporter:AddSave()
    if not inMainThread() then
        synchronize(function(thread)
            self:AddSave()
        end)
        return
    end
    local name = inputQuery("Rename Save", "Enter a name for the new save:", "Location")
    if not validateName(name, "Save") then return end
    local position = self:GetCurrentPosition()
    if not logSavePositionError(name, position) then return end
    self.Saves = self.Saves or {}
    if self.Saves[name] then
        logger:WarningF("[Teleporter] Duplicate Save Name: '%s'. Overwriting.", name)
    end
    self.Saves[name] = { X = position[1], Y = position[2], Z = position[3], Author = self:GetCurrentAuthor(), Description = "" }
    logger:InfoF("[Teleporter] Added Save: '%s' at position (%.4f, %.4f, %.4f).", name, position[1], position[2], position[3])
end
registerLuaFunctionHighlight('AddSave')

--
--- ∑ Deletes a saved teleport position and updates file storage.
--- @param saveName string # The name of the save to delete.
--
function Teleporter:DeleteSave(saveName)
    if not inMainThread() then
        synchronize(function(thread)
            self:DeleteSave(saveName)
        end)
        return
    end
    local name = saveName or inputQuery("Rename Save", "Enter a name for a save to be deleted:", "Location")
    if not validateName(name, "Delete") then return end
    if not self.Saves or not self.Saves[name] then
        logger:WarningF("[Teleporter] Save Not Found: '%s'.", name)
        return
    end
    self.Saves[name] = nil
    logger:InfoF("[Teleporter] Deleted Save: '%s'.", name)
end
registerLuaFunctionHighlight('DeleteSave')

--
--- ∑ Renames a saved teleport position and updates file storage.
--- @param oldName string # The old name of the save.
--- @param newName string # The new name of the save.
--
function Teleporter:RenameSave()
    if not inMainThread() then
        synchronize(function(thread)
            self:RenameSave()
        end)
        return
    end
    local oldName = inputQuery("Rename Save", "Enter a name for the save to be renamed:", "Location")
    if not validateName(oldName, "Old") then return end
    if not self.Saves or not self.Saves[oldName] then
        logger:ErrorF("[Teleporter] Save Not Found for rename: '%s'.", oldName)
        return
    end
    local newName = inputQuery("Rename Save", "Enter a new name for the save:", "Location")
    if not validateName(newName, "New") then return end
    if self.Saves[newName] then
        logger:ErrorF("[Teleporter] Save Name Already Exists: '%s'.", newName)
        return
    end
    self.Saves[newName] = self.Saves[oldName]
    self.Saves[oldName] = nil
    logger:InfoF("[Teleporter] Renamed Save: '%s' to '%s'.", oldName, newName)
end
registerLuaFunctionHighlight('RenameSave')

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
--- ∑ ...
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
--- ∑ Creates Teleporter saves and populates the memory record list.
--
function Teleporter:CreateTeleporterSaves()
    logger:Info("[Teleporter] Starting creation of Teleporter Saves...")
    local addressList = getAddressList()
    local root = addressList.getMemoryRecordByDescription(self.SaveMemoryRecordName)
    if not root then
        logger:ErrorF("[Teleporter] Failed to find root memory record: '%s'.", self.SaveMemoryRecordName)
        return
    end
    self:ClearSubrecords(root)
    local grouped = {}
    for saveName, data in pairs(self.Saves or {}) do
        if type(data) == "table" and data.X and data.Y and data.Z then
            local author = data.Author or "Unknown"
            local category = (data.Category ~= "" and data.Category) or "Default"
            grouped[author] = grouped[author] or {}
            grouped[author][category] = grouped[author][category] or {}
            table.insert(grouped[author][category], saveName)
        end
    end
    local sortedAuthors = {}
    for author in pairs(grouped) do table.insert(sortedAuthors, author) end
    table.sort(sortedAuthors, function(a, b) return a:lower() < b:lower() end)
    local totalSaves = 0
    for _, author in ipairs(sortedAuthors) do
        local authorHeader = addressList.createMemoryRecord()
        authorHeader.Type = vtGroupHeader
        authorHeader.Description = string.format("[— %s —] ()->", author)
        authorHeader.Color = 0xFFFFFF
        authorHeader.Parent = root
        authorHeader.IsAddressGroupHeader = false
        local categories = grouped[author]
        local sortedCategories = {}
        for category in pairs(categories) do table.insert(sortedCategories, category) end
        table.sort(sortedCategories, function(a, b) return a:lower() < b:lower() end)
        for _, category in ipairs(sortedCategories) do
            local categoryHeader = addressList.createMemoryRecord()
            categoryHeader.Type = vtGroupHeader
            categoryHeader.IsAddressGroupHeader = false
            categoryHeader.Description = string.format("[— %s —] ()->", category)
            categoryHeader.Color = 0xFFFFFF
            categoryHeader.Parent = authorHeader
            local saves = categories[category]
            table.sort(saves, function(a, b) return a:lower() < b:lower() end)
            for _, saveName in ipairs(saves) do
                local position = self.Saves[saveName]
                local scriptContent = string.format([[
{$lua}
[ENABLE]
if syntaxcheck then return end
--- Save: %s
--- Author: %s
---- X: %.4f
---- Y: %.4f
---- Z: %.4f
teleporter:TeleportToSave("%s")
utils:AutoDisable(memrec.ID)
[DISABLE]
]], saveName, author, position.X, position.Y, position.Z, saveName)
                local mr = addressList.createMemoryRecord()
                mr.Type = vtAutoAssembler
                mr.Description = "Teleport To: '" .. saveName .. "' ()->"
                mr.Color = 0xFFFFFF
                mr.Parent = categoryHeader
                mr.Script = scriptContent
                totalSaves = totalSaves + 1
            end
        end
    end

    logger:InfoF("[Teleporter] Successfully created %d Teleporter Saves (grouped by Author and Category).", totalSaves)
end
registerLuaFunctionHighlight('CreateTeleporterSaves')

--
--- ∑ Prints all saved Teleporter locations to the log.
--
function Teleporter:PrintSaves()
    if not self.Saves or next(self.Saves) == nil then
        logger:ForceError("[Teleporter] No Saves Found!")
        return
    end
    for name, position in pairs(self.Saves) do
        if position and position.X and position.Y and position.Z then
            local positionStr = string.format("(%.4f, %.4f, %.4f)", position.X, position.Y, position.Z)
            local authorStr = position.Author and tostring(position.Author) or "Unknown"
            logger:ForceInfoF("[Teleporter] Location '%s' saved by '%s' at coordinates %s.", name, authorStr, positionStr)
        else
            logger:ForceErrorF("[Teleporter] Invalid save position for '%s'. Details: %s", name, tostring(position))
        end
    end
end
registerLuaFunctionHighlight('PrintSaves')

--
--- ∑ Updates an existing Teleporter save with new coordinates.
--- @param name string # The name of the save to update.
--- @param newPos table # A table containing the new {X, Y, Z} coordinates.
--- @param TreeView object # The TreeView control to update.
--- @param newAuthor string # The new author of the save (optional).
--- @param newCategory string # The new category of the save (optional).
--- @param newDescription string # The new description of the save (optional).
--- @return boolean # True if the update was successful, false otherwise.
--
function UpdateSave(name, newPos, TreeView, newAuthor, newCategory, newDescription)
    if not name or name == "" then
        logger:WarningF("[Teleporter] Update failed: Name is missing.")
        return false
    end
    if not newPos or type(newPos) ~= "table" or #newPos ~= 3 then
        logger:WarningF("[Teleporter] Update failed: Invalid position data.")
        return false
    end
    teleporter.Saves = teleporter.Saves or {}
    local oldName = TreeView.Selected and TreeView.Selected.Text or name
    if not teleporter.Saves[oldName] then
        logger:WarningF("[Teleporter] Update failed: Save '%s' does not exist.", oldName)
        return false
    end
    if oldName ~= name then
        teleporter.Saves[name] = teleporter.Saves[oldName]
        teleporter.Saves[oldName] = nil
    end
    local save = teleporter.Saves[name]
    save.X, save.Y, save.Z = newPos[1], newPos[2], newPos[3]
    save.Author = newAuthor or save.Author or teleporter:GetCurrentAuthor()
    save.Category = newCategory or ""
    save.Description = newDescription or ""
    logger:InfoF("[Teleporter] Save '%s' updated: Author='%s', Category='%s', X=%.2f, Y=%.2f, Z=%.2f, Description='%s'",
                 name, save.Author, save.Category, save.X, save.Y, save.Z, save.Description or "")
    return true
end
registerLuaFunctionHighlight('UpdateSave')

--
--- ∑ Loads all Teleporter saves into a UI TreeView component.
--- @param TreeView userdata # The UI TreeView element to populate.
--
local function LoadTeleporterSaves(TreeView)
    TreeView.beginUpdate()
    TreeView.Items:clear()
    if not teleporter or not teleporter.Saves then
        TreeView.endUpdate()
        return
    end
    teleporter:EnsureAuthorsAndCategories()
    for name, data in pairs(teleporter.Saves) do
        if type(data) == "table" and data.Description == nil then
            data.Description = ""
        end
    end
    local grouped = {}
    for name, data in pairs(teleporter.Saves) do
        if type(name) == "string" and type(data) == "table" and data.X and data.Y and data.Z then
            local author   = data.Author or "Unknown"
            local category = data.Category ~= "" and data.Category or "Default"
            grouped[author] = grouped[author] or {}
            grouped[author][category] = grouped[author][category] or {}
            table.insert(grouped[author][category], name)
        end
    end
    for author, categoryMap in pairs(grouped) do
        local authorNode = TreeView.Items:add()
        authorNode.Text = author
        local sortedCategories = {}
        for category in pairs(categoryMap) do
            table.insert(sortedCategories, category)
        end
        table.sort(sortedCategories, function(a, b) return a:lower() < b:lower() end)
        for _, category in ipairs(sortedCategories) do
            local saves = categoryMap[category]
            local categoryNode = authorNode:add()
            categoryNode.Text = category
            table.sort(saves, function(a, b) return a:lower() < b:lower() end)
            for _, saveName in ipairs(saves) do
                local saveNode = categoryNode:add()
                saveNode.Text = saveName
            end
        end
    end
    TreeView.endUpdate()
end

local COLOR_BG           = 0x2E2723
local COLOR_PANEL        = 0x3A312C
local COLOR_ACCENT       = 0x9CBC1A
local COLOR_TEXT         = 0xEAEAEA
local COLOR_LABEL        = 0xB0B0B0
local COLOR_BTN          = 0x2E2723
local COLOR_BTN_HOVER    = 0x9CBC1A
local COLOR_BTN_TEXT     = 0xEAEAEA
local COLOR_TAB_ACTIVE   = 0x9CBC1A
local COLOR_TAB_INACTIVE = 0x3A312C

--
--- ∑ Creates a button with a given caption and attaches it to a parent UI component.
--- @param parent userdata # The parent UI element.
--- @param caption string # The caption text for the button.
--- @return userdata # The created button instance.
--
local function CreateButtonWithCaption(parent, caption)
    local panel = createPanel(parent)
    panel.Align = "alTop"
    panel.Height = 25
    panel.BevelOuter = bvRaised
    panel.BevelWidth = 1
    panel.Color = COLOR_BG
    panel.Cursor = -21 -- crHandPoint
    panel.Caption = caption
    panel.BorderSpacing.Around = 3
    panel.BorderColor = 0xFF0000
    local label = createLabel(panel)
    panel.OnMouseEnter = function()
        panel.Color = COLOR_TAB_ACTIVE
        label.Font.Color = COLOR_BG
    end
    panel.OnMouseLeave = function()
        panel.Color = COLOR_BG
        label.Font.Color = COLOR_TEXT
    end
    return panel
end

local function createDarkPanel(parent)
    local panel = createPanel(parent)
    panel.Color = COLOR_PANEL
    return panel
end

--
--- ∑ Creates a labeled input field with a given label text and attaches it to a parent UI component.
--- @param parent userdata # The parent UI element.
--- @param labelText string # The label text for the input field.
--- @return userdata # The created input field instance.
--
local function CreateLabeledEdit(parent, labelText)
    local container = createDarkPanel(parent)
    container.Align = "alTop"
    container.Height = 25
    container.BevelOuter = "bvNone"
    local label = createLabel(container)
    label.Caption = labelText
    label.Align = "alLeft"
    label.BorderSpacing.Around = 2
    label.Font.Color = COLOR_LABEL
    label.Font.Name = "Consolas"
    label.Font.Size = 10
    local edit = createEdit(container)
    edit.Align = "alClient"
    edit.BorderSpacing.Around = 2
    -- edit.Color = COLOR_BG
    edit.Font.Color = COLOR_TEXT
    edit.Font.Name = "Consolas"
    edit.Font.Size = 10
    return edit
end

--
--- Handles the selection of a save entry in the TreeView and updates UI input fields accordingly.
--- @param TreeView userdata
--- @param NameEdit, XEdit, YEdit, ZEdit ...
--
local function HandleTreeViewSelection(TreeView, NameEdit, AuthorEdit, CategoryEdit, XEdit, YEdit, ZEdit, DescriptionEdit)
    TreeView.OnClick = function()
        local selected = TreeView.Selected
        if not selected then return end
        if selected.Level == 2 then
            local saveName = selected.Text
            local categoryNode = selected.Parent
            local authorNode = categoryNode and categoryNode.Parent
            if teleporter.Saves and teleporter.Saves[saveName] then
                local save = teleporter.Saves[saveName]
                NameEdit.Text = saveName
                AuthorEdit.Text = authorNode and authorNode.Text or "Unknown"
                CategoryEdit.Text = categoryNode and categoryNode.Text or "Default"
                XEdit.Text = tostring(save.X or "")
                YEdit.Text = tostring(save.Y or "")
                ZEdit.Text = tostring(save.Z or "")
                DescriptionEdit.Lines.Text = save.Description or ""
            else
                DescriptionEdit.Lines.Text = ""
            end
        else
            DescriptionEdit.Lines.Text = ""
        end
    end
    TreeView.OnDblClick = function()
        local selected = TreeView.Selected
        if not selected or selected.Level ~= 2 then return end
        local saveName = selected.Text
        if teleporter.Saves and teleporter.Saves[saveName] then
            logger:InfoF("[Teleporter] Double-clicked save '%s' - attempting teleport.", saveName)
            teleporter:TeleportToSave(saveName)
        end
    end
end

--
--- ∑ Creates and initializes the Teleporter UI form.
--- @return userdata # The created form instance.
--
local function CreateTeleporterForm()
    local form = createForm(false)
    form.Top = -2000
    form.Show()
    form.Caption = "Teleporter Saves"
    -- form.Color = 0x0a0305
    form.Width = 700
    form.Height = 500
    form.Constraints.MinWidth = form.Width
    form.Constraints.MinHeight = form.Height
    form.Scaled = false
    form.BorderStyle = "bsSizeable"
    form.Color = COLOR_BG
    local defaultDPI = 96
    local currentDPI = getScreenDPI()
    local scaleFactor = defaultDPI / currentDPI
    local baseFontSize = 10
    form.Font.Name = "Consolas"
    form.Font.Size = baseFontSize * scaleFactor
    form.Font.Color = COLOR_TEXT
    form.Position = "poScreenCenter"
    form.CenterScreen()
    return form
end

--
--- ∑ Creates a panel containing a TreeView and search bar for Teleporter saves.
--- @param parent userdata # The parent UI element.
--- @return userdata, userdata, userdata - The created panel, search bar, and TreeView instances.
--
local function CreateTreeViewPanel(parent)
    local panel = createDarkPanel(parent)
    panel.Align = "alTop"
    panel.Constraints.MinHeight = 315
    panel.BorderSpacing.Around = 3
    panel.BevelOuter = "bvNone"
    panel.Anchors = "[akTop,akLeft,akRight,akBottom]"
    local searchEdit = createEdit(panel)
    searchEdit.Align = "alTop"
    searchEdit.Height = 30
    searchEdit.BorderSpacing.Around = 3
    searchEdit.Text = ""
    searchEdit.TextHint = "Search Saves..."
    searchEdit.Color = COLOR_BG
    searchEdit.Font.Color = COLOR_TEXT
    searchEdit.Font.Name = "Consolas"
    searchEdit.Font.Size = 10
    local treeView = createTreeView(panel)
    treeView.Align = "alClient"
    treeView.BorderSpacing.Around = 3
    treeView.AutoExpand = true
    treeView.ReadOnly = true
    treeView.AutoSize = true
    treeView.BorderStyle = "bsNone"
    treeView.Color = COLOR_PANEL
    treeView.Font.Color = COLOR_TEXT
    treeView.Font.Name = "Consolas"
    treeView.Font.Size = 10
    treeView.ScrollBars = "ssAutoBoth"
    return panel, searchEdit, treeView
end

local function CreateSaveDetailsTabControl(parent)
    local tabButtonPanel = createDarkPanel(parent)
    tabButtonPanel.Align = "alTop"
    tabButtonPanel.Height = 25
    tabButtonPanel.BevelOuter = "bvNone"
    tabButtonPanel.BorderSpacing.Around = 4
    local tabContentPanel = createDarkPanel(parent)
    tabContentPanel.Align = "alClient"
    tabContentPanel.AutoSize = true
    tabContentPanel.BevelOuter = "bvNone"
    tabContentPanel.BorderSpacing.Around = 4
    local tabs = {
        {caption = "Details"},
        {caption = "Coordinates"},
        {caption = "Description"}
    }
    local tabPanels = {}
    local tabPages = {}
    for i, tab in ipairs(tabs) do
        local page = createDarkPanel(tabContentPanel)
        page.Align = "alClient"
        page.Visible = (i == 1)
        page.BevelOuter = "bvNone"
        tabPages[i] = page
    end
    local function selectTab(idx)
        for i, page in ipairs(tabPages) do
            page.Visible = (i == idx)
            if tabPanels[i] then
                tabPanels[i].Color = (i == idx) and COLOR_TAB_ACTIVE or COLOR_TAB_INACTIVE
                tabPanels[i].Font.Color = (i == idx) and COLOR_BG or COLOR_TEXT
            end
        end
    end
    for i, tab in ipairs(tabs) do
        local p = createDarkPanel(tabButtonPanel)
        p.Left = (i-1)*140
        p.Top = 2
        p.Width = 132
        p.Height = 25
        p.BevelOuter = bvRaised
        p.BevelWidth = 1
        p.Caption = tab.caption
        p.Font.Name = "Consolas"
        p.Font.Size = 10
        p.Color = COLOR_TAB_INACTIVE
        p.Font.Color = COLOR_TEXT
        p.ParentFont = false
        p.Cursor = -21 -- crHandPoint
        p.OnClick = function()
            selectTab(i)
        end
        tabPanels[i] = p
    end
    selectTab(1)
    return tabButtonPanel, tabContentPanel, tabPages
end

--
--- ∑ Creates a panel containing input fields and action buttons for save details.
--- @param parent userdata # The parent UI element.
--- @return userdata, userdata, userdata, userdata, userdata #  
--- The created group box, name input, X input, Y input, Z input.
--
local function CreateSaveDetailsPanel(parent)
    local layoutPanel = createPanel(parent)
    layoutPanel.Align = "alClient"
    layoutPanel.AutoSize = true
    layoutPanel.BorderSpacing.Around = 5
    layoutPanel.BevelOuter = "bvNone"
    local updateButton = CreateButtonWithCaption(layoutPanel, "Update Save")
    local teleportToSaveButton = CreateButtonWithCaption(layoutPanel, "Teleport To Save")
    local nameEdit = CreateLabeledEdit(layoutPanel, "Name: ")
    nameEdit.TextHint = "Save Name"
    local categoryEdit = CreateLabeledEdit(layoutPanel, "Category: ")
    categoryEdit.TextHint = "Save Category"
    local authorEdit = CreateLabeledEdit(layoutPanel, "Author: ")
    authorEdit.TextHint = "Save Author"
    return groupBox, nameEdit, authorEdit, categoryEdit, teleportToSaveButton, updateButton
end

local function CreateCoordinatesPanel(parent)
    local coordinatesPanel = createPanel(parent)
    coordinatesPanel.Align = "alClient"
    coordinatesPanel.BevelOuter = "bvNone"
    coordinatesPanel.BorderSpacing.Around = 5
    local zEdit = CreateLabeledEdit(coordinatesPanel, "Z: ")
    zEdit.TextHint = "Z Coordinate"
    local yEdit = CreateLabeledEdit(coordinatesPanel, "Y: ")
    yEdit.TextHint = "Y Coordinate"
    local xEdit = CreateLabeledEdit(coordinatesPanel, "X: ")
    xEdit.TextHint = "X Coordinate"
    return xEdit, yEdit, zEdit
end

local function CreateDescriptionPanel(parent)
    local descriptionPanel = createDarkPanel(parent)
    descriptionPanel.Align = "alClient"
    descriptionPanel.BevelOuter = "bvNone"
    descriptionPanel.BorderSpacing.Around = 5
    local descriptionEdit = createMemo(descriptionPanel)
    descriptionEdit.Align = "alClient"
    descriptionEdit.BorderSpacing.Around = 5
    descriptionEdit.TextHint = "Description (optional)"
    descriptionEdit.Color = COLOR_BG
    descriptionEdit.Font.Color = COLOR_TEXT
    descriptionEdit.Font.Name = "Consolas"
    descriptionEdit.Font.Size = 10
    descriptionEdit.WordWrap = true
    descriptionEdit.Scrollbars = "ssAutoBoth"
    return descriptionEdit
end

--
--- ∑ Handles the deletion of a selected save when the delete button is clicked.
--- @param DeleteButton userdata # The UI button for deleting saves.
--- @param NameEdit userdata # The input field for the save name.
--- @param TreeView userdata # The UI TreeView element containing save entries.
--
local function HandleDeleteButtonClick(DeleteButton, NameEdit, TreeView)
    DeleteButton.OnClick = function()
        local selectedName = NameEdit.Text
        if selectedName ~= "" and teleporter and teleporter.DeleteSave then
            logger:Info("[Teleporter] Deleting save: " .. selectedName)
            teleporter:DeleteSave(selectedName)
            LoadTeleporterSaves(TreeView)
        else
            logger:Warning("[Teleporter] No valid save selected for deletion.")
        end
    end
end

--
--- ∑ Handles updating a selected save when the update button is clicked.
--- @param UpdateButton userdata # The UI button for updating saves.
--- @param NameEdit userdata # The input field for the save name.
--- @param XEdit userdata # The input field for the X coordinate.
--- @param YEdit userdata # The input field for the Y coordinate.
--- @param ZEdit userdata # The input field for the Z coordinate.
--- @param TreeView userdata # The UI TreeView element containing save entries.
--
local function HandleUpdateButtonClick(UpdateButton, NameEdit, AuthorEdit, CategoryEdit, XEdit, YEdit, ZEdit, TreeView, DescriptionEdit)
    UpdateButton.OnClick = function()
        local name = NameEdit.Text
        local newPos = { tonumber(XEdit.Text), tonumber(YEdit.Text), tonumber(ZEdit.Text) }
        local newAuthor = AuthorEdit.Text
        local newCategory = CategoryEdit.Text
        local newDescription = DescriptionEdit.Lines.Text -- Use Lines.Text for full memo content
        if name ~= "" and newPos[1] and newPos[2] and newPos[3] then
            logger:Info("[Teleporter] Updating save: " .. name)
            local success = UpdateSave(name, newPos, TreeView, newAuthor, newCategory, newDescription)
            if success then
                LoadTeleporterSaves(TreeView)
            else
                logger:Warning("[Teleporter] Update failed.")
            end
        else
            logger:Warning("[Teleporter] Invalid input for update.")
        end
    end
end

--
--- ∑ Handles duplicating a selected save when the duplicate button is clicked.
--- @param DuplicateButton userdata # The UI button for duplicating saves.
--- @param NameEdit userdata # The input field for the save name.
--- @param TreeView userdata # The UI TreeView element containing save entries.
--
local function HandleDuplicateButtonClick(DuplicateButton, NameEdit, TreeView)
    DuplicateButton.OnClick = function()
        local selectedName = NameEdit.Text
        if not selectedName or selectedName == "" or not teleporter.Saves[selectedName] then
            logger:Warning("[Teleporter] No valid save selected for duplication.")
            return
        end
        local newSaveName = selectedName .. " (Copy)"
        local counter = 1
        while teleporter.Saves[newSaveName] do
            counter = counter + 1
            newSaveName = string.format("%s_copy%d", selectedName, counter)
        end
        local originalSave = teleporter.Saves[selectedName]
        teleporter.Saves[newSaveName] = {
            X = originalSave.X,
            Y = originalSave.Y,
            Z = originalSave.Z,
            Author = originalSave.Author or Teleporter:GetCurrentAuthor(),
            Description = originalSave.Description or ""
        }
        logger:InfoF("[Teleporter] Duplicated save '%s' as '%s'.", selectedName, newSaveName)
        LoadTeleporterSaves(TreeView)
    end
end

--
--- ∑ Teleports the player to the selected save location.
--- @param NameEdit userdata # The name input field.
--- @return boolean # True if teleportation is successful, false otherwise.
--
local function HandleTeleportButtonClick(TeleportButton, NameEdit)
    TeleportButton.OnClick = function()
        local saveName = NameEdit.Text
        if not saveName or saveName == "" then
            logger:Warning("[Teleporter] No save selected for teleportation.")
            return false
        end
        if not teleporter.Saves or not teleporter.Saves[saveName] then
            logger:ErrorF("[Teleporter] Save '%s' does not exist.", saveName)
            return false
        end
        logger:InfoF("[Teleporter] Teleporting to save: '%s'", saveName)
        teleporter:TeleportToSave(saveName)
        return true
    end
end

--
--- ∑ Handles deleting all saves when the delete all button is clicked.
--- @param DeleteAllButton userdata # The UI button for deleting all saves.
--- @param TreeView userdata # The UI TreeView element containing save entries.
--
local function HandleDeleteAllButtonClick(DeleteAllButton, TreeView)
    DeleteAllButton.OnClick = function()
        teleporter.Saves = nil
        LoadTeleporterSaves(TreeView)
    end
end

--
--- ∑ Creates a context menu for the TreeView with options to teleport, update, duplicate, and delete saves.
--- @param TreeView userdata # The TreeView control to attach the context menu to.
--- @param NameEdit userdata # The input field for the save name.
--- @param AuthorEdit userdata # The input field for the save author.
--- @param CategoryEdit userdata # The input field for the save category.
--- @param XEdit userdata # The input field for the X coordinate.
--- @param YEdit userdata # The input field for the Y coordinate.
--- @param ZEdit userdata # The input field for the Z coordinate.
--- @return 
--
local function CreateContextMenuForTreeView(TreeView, NameEdit, AuthorEdit, CategoryEdit, XEdit, YEdit, ZEdit)
    local contextMenu = createPopupMenu(TreeView)
    TreeView.PopupMenu = contextMenu
    local teleportItem = createMenuItem(contextMenu)
    teleportItem.Caption = "Teleport To Save"
    HandleTeleportButtonClick(teleportItem, NameEdit)
    contextMenu.Items.add(teleportItem)
    local updateItem = createMenuItem(contextMenu)
    updateItem.Caption = "Update Save"
    HandleUpdateButtonClick(updateItem, NameEdit, AuthorEdit, CategoryEdit, XEdit, YEdit, ZEdit, TreeView)
    contextMenu.Items.add(updateItem)
    local duplicateItem = createMenuItem(contextMenu)
    duplicateItem.Caption = "Duplicate Save"
    HandleDuplicateButtonClick(duplicateItem, NameEdit, TreeView)
    contextMenu.Items.add(duplicateItem)
    local deleteItem = createMenuItem(contextMenu)
    deleteItem.Caption = "Delete Save"
    HandleDeleteButtonClick(deleteItem, NameEdit, TreeView)
    contextMenu.Items.add(deleteItem)
end

--
--- ∑ Creates a panel with save details and controls.
--- @param parent userdata # The parent UI element.
--- @return ... # The created panels, edits, and buttons.
--
local function CreateSaveDetailsWithControlsPanel(parent)
    local containerPanel = createPanel(parent)
    containerPanel.Align = "alClient"
    containerPanel.BevelOuter = "bvNone"
    local tabButtonPanel, tabContentPanel, tabPages = CreateSaveDetailsTabControl(containerPanel)
    local saveDetailsGroupBox, nameEdit, authorEdit, categoryEdit, teleportToSaveButton, updateButton = CreateSaveDetailsPanel(tabPages[1])
    local xEdit, yEdit, zEdit = CreateCoordinatesPanel(tabPages[2])
    local descriptionEdit = CreateDescriptionPanel(tabPages[3])
    return containerPanel, saveDetailsGroupBox,
           nameEdit, authorEdit, categoryEdit, xEdit, yEdit, zEdit, teleportToSaveButton, updateButton, descriptionEdit
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
--
function Teleporter:InitTeleporterUI()
    if not inMainThread() then
        synchronize(function()
            self:InitTeleporterUI()
        end)
        return
    end
    TeleporterForm = CreateTeleporterForm()
    local containerPanel = createPanel(TeleporterForm)
    containerPanel.Align = "alClient"
    containerPanel.BevelOuter = "bvNone"
    local saveDetailsWithControlsPanel, saveDetailsGroupBox,
          nameEdit, authorEdit, categoryEdit, xEdit, yEdit, zEdit, teleportToSaveButton, updateButton, descriptionEdit = CreateSaveDetailsWithControlsPanel(containerPanel)
    local TreeViewPanel, SearchEdit, TreeView = CreateTreeViewPanel(containerPanel)
    HandleTreeViewSelection(TreeView, nameEdit, authorEdit, categoryEdit, xEdit, yEdit, zEdit, descriptionEdit)
    HandleUpdateButtonClick(updateButton, nameEdit, authorEdit, categoryEdit, xEdit, yEdit, zEdit, TreeView, descriptionEdit)
    HandleTeleportButtonClick(teleportToSaveButton, nameEdit)
    CreateContextMenuForTreeView(TreeView, nameEdit, authorEdit, categoryEdit, xEdit, yEdit, zEdit)
    LoadTeleporterSaves(TreeView)
    TeleporterForm.CenterScreen()
    local function updateTreeView(TreeView, searchQuery)
        TreeView.beginUpdate()
        TreeView.Items:clear()
        if not teleporter or not teleporter.Saves then
            TreeView.endUpdate()
            return
        end
        teleporter:EnsureAuthorsAndCategories()
        local grouped = {}
        for saveName, data in pairs(teleporter.Saves) do
            if type(saveName) == "string" and type(data) == "table" and data.X and data.Y and data.Z then
                local author = data.Author or "Unknown"
                local category = data.Category ~= "" and data.Category or "Default"
                if saveName:lower():find(searchQuery:lower())
                or author:lower():find(searchQuery:lower())
                or category:lower():find(searchQuery:lower()) then
                    grouped[author] = grouped[author] or {}
                    grouped[author][category] = grouped[author][category] or {}
                    table.insert(grouped[author][category], saveName)
                end
            end
        end
        for author, categoryMap in pairs(grouped) do
            local authorNode = TreeView.Items:add()
            authorNode.Text = author
            for category, saves in pairs(categoryMap) do
                local categoryNode = authorNode:add()
                categoryNode.Text = category
                table.sort(saves, function(a, b) return a:lower() < b:lower() end)
                for _, name in ipairs(saves) do
                    local saveNode = categoryNode:add()
                    saveNode.Text = name
                end
            end
        end
        TreeView.endUpdate()
    end
    SearchEdit.OnChange = function()
        updateTreeView(TreeView, SearchEdit.Text)
    end
end
registerLuaFunctionHighlight('InitTeleporterUI')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Teleporter