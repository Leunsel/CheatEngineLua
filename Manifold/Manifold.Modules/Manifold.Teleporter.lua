local NAME = "Manifold.Teleporter.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Manifold Framework Teleporter"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.
]]--

Teleporter = {
    Transform = { Symbol = "TransformPtr", Offsets = { 0x30, 0x34, 0x38 } },
    Waypoint = { Symbol = "WaypointPtr", Offsets = { 0x00, 0x04, 0x08 } },
    Additional = { Symbol = nil, Offsets = nil },
    Symbols = { Saved = "SavedPositionFlt", Backup = "BackupPositionFlt" },
    Settings = { ValueType = vtSingle },
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
function Teleporter:ReadPositionFromMemory(symbol, offsets, isPointerRead)
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
    local readFunc = readFunctions[self.Settings.ValueType]
    if not readFunc then
        logger:Error(string.format("[Teleporter] Unsupported value type '%s'", tostring(self.Settings.ValueType)))
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
function Teleporter:WritePositionToMemory(symbol, offsets, position, isPointerWrite)
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
    local writeFunc = writeFunctions[self.Settings.ValueType]
    if not writeFunc then
        logger:ErrorF("[Teleporter] Unsupported value type '%s'", tostring(self.Settings.ValueType))
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
    return self:ReadPositionFromMemory(self.Transform.Symbol, self.Transform.Offsets, true)
end
registerLuaFunctionHighlight('GetCurrentPosition')

--
--- ∑ Reads the current saved position from memory.
--- @returns # the current saved coordinates as a table (x, y, z).
--
function Teleporter:GetSavedPosition()
    return self:ReadPositionFromMemory(self.Symbols.Saved, self:CalculateSymbolOffsets(), false)
end
registerLuaFunctionHighlight('GetSavedPosition')

--
--- ∑ Reads the current backup position from memory.
--- @returns # the current backup coordinates as a table (x, y, z).
--
function Teleporter:GetBackupPosition()
    return self:ReadPositionFromMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), false)
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
    local success = self:WritePositionToMemory(self.Symbols.Saved, self:CalculateSymbolOffsets(), currentPosition, false)
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
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, savedPosition, true)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, savedPosition, true)
    end
    if success then
        logger:InfoF("[Teleporter] Loaded saved position -> {%s}", table.concat(savedPosition, ", "))
        self:LogDistanceTraveled(currentPosition, savedPosition)
        if self.Symbols and self.Symbols.Backup then
            self:WritePositionToMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), currentPosition, false)
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
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, backupPosition, true)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, backupPosition, true)
    end
    if success then
        logger:InfoF("[Teleporter] Loaded backup position -> {%s}", table.concat(backupPosition, ", "))
        self:LogDistanceTraveled(currentPosition, backupPosition)
        if self.Symbols and self.Symbols.Backup then
            self:WritePositionToMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), currentPosition, false)
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
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, position, true)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, position, true)
    end
    if success then
        logger:InfoF("[Teleporter] Teleported to coordinates -> {%s}", table.concat(position, ", "))
        self:LogDistanceTraveled(currentPosition, position)
        if self.Symbols and self.Symbols.Backup then
            self:WritePositionToMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), currentPosition, false)
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
    local waypointPosition = self:ReadPositionFromMemory(self.Waypoint.Symbol, self.Waypoint.Offsets, true)
    if not waypointPosition then
        logger:Error("[Teleporter] No waypoint position found.")
        return false
    end
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, waypointPosition, true)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, waypointPosition, true)
    end
    if success then
        logger:InfoF("[Teleporter] Teleported to waypoint -> {%s}", table.concat(waypointPosition, ", "))
        self:LogDistanceTraveled(currentPosition, waypointPosition)
        if self.Symbols and self.Symbols.Backup then
            self:WritePositionToMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), currentPosition, false)
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
    self.Saves[name] = { X = position[1], Y = position[2], Z = position[3], Author = self:GetCurrentAuthor() }
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
    local success = self:TeleportToCoordinates({ savePosition.X, savePosition.Y, savePosition.Z })
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
    local sortedLocationNames = {}
    for locationName, _ in pairs(self.Saves) do
        table.insert(sortedLocationNames, locationName)
    end
    table.sort(sortedLocationNames)
    logger:InfoF("[Teleporter] Found %d saves to process.", #sortedLocationNames)
    for _, saveName in ipairs(sortedLocationNames) do
        local position = self.Saves[saveName]
        local author = (position and position.Author) and tostring(position.Author) or "Unknown"
        logger:DebugF("[Teleporter] Processing save: '%s' (X: %.4f, Y: %.4f, Z: %.4f).", saveName, position.X, position.Y, position.Z)
        local mr = addressList.createMemoryRecord()
        mr.Type = vtAutoAssembler
        mr.Description = "Teleport To: '" .. saveName .. "' ()->"
        mr.Color = 0xFFFFFF
        mr.Parent = root
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
        mr.Script = scriptContent
    end
    logger:InfoF("[Teleporter] Successfully created %d Teleporter Saves.", #sortedLocationNames)
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
--- @return boolean # True if the update was successful, false otherwise.
--
function UpdateSave(name, newPos, TreeView)
    if not name or name == "" then
        logger:WarningF("[Teleporter] Update failed: Name is missing.")
        return false
    end
    if not newPos or type(newPos) ~= "table" or #newPos ~= 3 then
        logger:WarningF("[Teleporter] Update failed: Invalid position data.")
        return false
    end
    teleporter.Saves = teleporter.Saves or {}
    local selectedSaveName = TreeView.Selected and TreeView.Selected.Text or name
    if not teleporter.Saves[selectedSaveName] then
        logger:WarningF("[Teleporter] Update failed: Save '%s' does not exist.", selectedSaveName)
        return false
    end
    if selectedSaveName ~= name then
        teleporter.Saves[name] = teleporter.Saves[selectedSaveName]
        teleporter.Saves[selectedSaveName] = nil
    end
    local save = teleporter.Saves[name]
    save.X, save.Y, save.Z = newPos[1] or 0, newPos[2] or 0, newPos[3] or 0
    save.Author = save.Author or teleporter:GetCurrentAuthor()
    logger:InfoF("[Teleporter] Save '%s' updated: X=%.2f, Y=%.2f, Z=%.2f", name, save.X, save.Y, save.Z)
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
        logger:Warning("[Teleporter] No saves to load.")
        TreeView.endUpdate()
        return
    end
    -- teleporter:EnsureAuthors()
    local grouped = {}
    for name, data in pairs(teleporter.Saves) do
        if type(name) == "string" and type(data) == "table" and data.X and data.Y and data.Z then
            local author = data.Author or "Unknown"
            grouped[author] = grouped[author] or {}
            table.insert(grouped[author], name)
        else
            logger:WarningF("[Teleporter] Ignoring bad save: %s", tostring(name))
        end
    end
    for author, saves in pairs(grouped) do
        local authorNode = TreeView.Items:add()
        authorNode.Text = author
        table.sort(saves, function(a, b) return a:lower() < b:lower() end)
        for _, saveName in ipairs(saves) do
            local saveNode = authorNode:add()
            saveNode.Text = saveName
        end
    end
    TreeView.endUpdate()
end

--
--- ∑ Creates a button with a given caption and attaches it to a parent UI component.
--- @param parent userdata # The parent UI element.
--- @param caption string # The caption text for the button.
--- @return userdata # The created button instance.
--
local function CreateButtonWithCaption(parent, caption)
    local button = createButton(parent)
    button.Align = "alTop"
    button.Caption = caption
    button.BorderSpacing.Around = 2
    return button
end

--
--- ∑ Creates a labeled input field with a given label text and attaches it to a parent UI component.
--- @param parent userdata # The parent UI element.
--- @param labelText string # The label text for the input field.
--- @return userdata # The created input field instance.
--
local function CreateLabeledEdit(parent, labelText)
    local container = createPanel(parent)
    container.Align = "alTop"
    container.Height = 25
    container.BevelOuter = "bvNone"
    local label = createLabel(container)
    label.Caption = labelText
    label.Align = "alLeft"
    label.BorderSpacing.Around = 2
    local edit = createEdit(container)
    edit.Align = "alClient"
    edit.BorderSpacing.Around = 2
    return edit
end

--
--- Handles the selection of a save entry in the TreeView and updates UI input fields accordingly.
--- @param TreeView userdata
--- @param NameEdit, XEdit, YEdit, ZEdit ...
--
local function HandleTreeViewSelection(TreeView, NameEdit, XEdit, YEdit, ZEdit)
    TreeView.OnClick = function()
        local selected = TreeView.Selected
        if selected and selected.Level == 1 then
            local saveName = selected.Text
            local save = teleporter.Saves and teleporter.Saves[saveName]
            if save then
                NameEdit.Text = saveName
                XEdit.Text = tostring(save.X or "")
                YEdit.Text = tostring(save.Y or "")
                ZEdit.Text = tostring(save.Z or "")
            end
        end
    end
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
local function HandleUpdateButtonClick(UpdateButton, NameEdit, XEdit, YEdit, ZEdit, TreeView)
    UpdateButton.OnClick = function()
        local name = NameEdit.Text
        local newPos = { tonumber(XEdit.Text), tonumber(YEdit.Text), tonumber(ZEdit.Text) }
        if name ~= "" and newPos[1] and newPos[2] and newPos[3] then
            logger:Info("[Teleporter] Updating save: " .. name)
            local success = UpdateSave(name, newPos, TreeView)
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
            Author = originalSave.Author or Teleporter:GetCurrentAuthor()
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
--- ∑ Creates and initializes the Teleporter UI form.
--- @return userdata # The created form instance.
--
local function CreateTeleporterForm()
    local form = createForm(false)
    form.Top = -2000
    form.Show()
    form.Caption = "Teleporter Saves"
    form.Width = 700
    form.Height = 500
    form.Constraints.MinWidth = form.Width
    form.Constraints.MinHeight = form.Height
    form.Scaled = false
    form.BorderStyle = "bsSizeable"
    local defaultDPI = 96
    local currentDPI = getScreenDPI()
    local scaleFactor = defaultDPI / currentDPI
    local baseFontSize = 10
    form.Font.Name = "Consolas"
    form.Font.Size = baseFontSize * scaleFactor
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
    local panel = createPanel(parent)
    panel.Align = "alLeft"
    panel.Width = 450
    panel.BorderSpacing.Around = 3
    panel.BevelOuter = "bvNone"
    local searchEdit = createEdit(panel)
    searchEdit.Align = "alTop"
    searchEdit.Height = 30
    searchEdit.BorderSpacing.Around = 3
    searchEdit.Text = ""
    local treeView = createTreeView(panel)
    treeView.Align = "alClient"
    treeView.BorderSpacing.Around = 3
    return panel, searchEdit, treeView
end

--
--- ∑ Creates a panel containing input fields and action buttons for save details.
--- @param parent userdata # The parent UI element.
--- @return userdata, userdata, userdata, userdata, userdata #  
--- The created group box, name input, X input, Y input, Z input.
--
local function CreateSaveDetailsPanel(parent)
    local groupBox = createGroupBox(parent)
    groupBox.Align = "alTop"
    groupBox.AutoSize = true
    groupBox.Caption = "Save Details"
    groupBox.BorderSpacing.Around = 5
    local layoutPanel = createPanel(groupBox)
    layoutPanel.Align = "alClient"
    layoutPanel.AutoSize = true
    layoutPanel.BorderSpacing.Around = 5
    layoutPanel.BevelOuter = "bvNone"
    local zEdit = CreateLabeledEdit(layoutPanel, "Z: ")
    local yEdit = CreateLabeledEdit(layoutPanel, "Y: ")
    local xEdit = CreateLabeledEdit(layoutPanel, "X: ")
    local nameEdit = CreateLabeledEdit(layoutPanel, "") -- Name
    return groupBox, nameEdit, xEdit, yEdit, zEdit
end

--
--- ∑ Creates a panel with controls for save management.
--- @param parent userdata # The parent UI element.
--- @return userdata, ... # The created panel and button instances.
--
local function CreateControlsPanel(parent)
    local groupBox = createGroupBox(parent)
    groupBox.Align = "alTop"
    groupBox.AutoSize = true
    groupBox.Caption = "Controls"
    groupBox.BorderSpacing.Around = 5
    local buttonPanel = createPanel(groupBox)
    buttonPanel.Align = "alTop"
    buttonPanel.AutoSize = true
    buttonPanel.BorderSpacing.Around = 5
    buttonPanel.BevelOuter = "bvNone"
    local deleteAllButton = CreateButtonWithCaption(buttonPanel, "Delete All Saves")
    local deleteButton = CreateButtonWithCaption(buttonPanel, "Delete Save")
    local updateButton = CreateButtonWithCaption(buttonPanel, "Update Save")
    local duplicateButton = CreateButtonWithCaption(buttonPanel, "Duplicate Save")
    local teleportToSaveButton = CreateButtonWithCaption(buttonPanel, "Teleport To Save")
    return buttonPanel, deleteAllButton, deleteButton, updateButton, duplicateButton, teleportToSaveButton
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
    local buttonPanel, deleteAllButton, deleteButton, updateButton, duplicateButton, teleportToSaveButton = CreateControlsPanel(containerPanel)
    local saveDetailsGroupBox, nameEdit, xEdit, yEdit, zEdit = CreateSaveDetailsPanel(containerPanel)
    return containerPanel, saveDetailsGroupBox, buttonPanel, nameEdit, xEdit, yEdit, zEdit,
           deleteAllButton, deleteButton, updateButton, duplicateButton, teleportToSaveButton
end

--
--- ∑ Ensures all saves have an Author field.
--
function Teleporter:EnsureAuthors()
    local author = self:GetCurrentAuthor()
    for _, save in pairs(self.Saves or {}) do
        if type(save) == "table" and not save.Author then
            save.Author = author
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
    local Splitter = createSplitter(containerPanel)
    local saveDetailsWithControlsPanel, saveDetailsGroupBox, buttonPanel,
    nameEdit, xEdit, yEdit, zEdit, deleteAllButton, deleteButton, updateButton, duplicateButton,
    teleportToSaveButton = CreateSaveDetailsWithControlsPanel(containerPanel)
    local ListViewPanel, SearchEdit, TreeView = CreateTreeViewPanel(containerPanel)
    HandleTreeViewSelection(TreeView, nameEdit, xEdit, yEdit, zEdit)
    HandleDeleteAllButtonClick(deleteAllButton, TreeView)
    HandleDeleteButtonClick(deleteButton, nameEdit, TreeView)
    HandleUpdateButtonClick(updateButton, nameEdit, xEdit, yEdit, zEdit, TreeView)
    HandleDuplicateButtonClick(duplicateButton, nameEdit, TreeView)
    HandleTeleportButtonClick(teleportToSaveButton, nameEdit)
    LoadTeleporterSaves(TreeView)
    TeleporterForm.CenterScreen()
    local function updateTreeView(TreeView, searchQuery)
        TreeView.beginUpdate()
        TreeView.Items:clear()
        if not teleporter or not teleporter.Saves then
            TreeView.endUpdate()
            return
        end
        teleporter:EnsureAuthors()
        local grouped = {}
        for name, data in pairs(teleporter.Saves) do
            if type(name) == "string" and type(data) == "table" and data.X and data.Y and data.Z then
                if name:lower():find(searchQuery:lower()) then
                    local author = data.Author or "Unknown"
                    grouped[author] = grouped[author] or {}
                    table.insert(grouped[author], name)
                end
            end
        end
        for author, saves in pairs(grouped) do
            local authorNode = TreeView.Items:add()
            authorNode.Text = author
            table.sort(saves, function(a, b) return a:lower() < b:lower() end)
            for _, saveName in ipairs(saves) do
                local saveNode = authorNode:add()
                saveNode.Text = saveName
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