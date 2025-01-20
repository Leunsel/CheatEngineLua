local NAME = "CTI.Teleporter"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Cheat Table Interface (Teleporter)"

--
--- Several configuration properties that can be customized.
--- Set within the Table Lua Script and passed to the constructor of the class.
----------
Teleporter = {
    ---
    ---- Required Offsets for Teleporter;
    ---- TransformSymbol    [Required]
    ---- SymbolOffsets      [Required]
    ---- WaypointOffsets    [Optional]
    TransformOffsets = {},
    WaypointOffsets = {},
    SymbolOffsets = {},
    ---
    ---- Required Symbols for Teleporter;
    ---- TransformSymbol        [Required]
    ---- SavedPositionSymbol    [Required]
    ---- BackupPositionSymbol   [Required]
    ---- Waypoint               [Optional]
    TransformSymbol = "",
    WaypointSymbol = "",
    SavedPositionSymbol = "",
    BackupPositionSymbol = "",
    ---
    ---- Settings for Teleporter;
    ---- DebugMode        [Optional]
    ---- ValueType        [Required]
    DebugMode = false,
    ValueType = vtSingle,
    ---
    ---- Table Stored Saves for Teleporter;
    Saves = {}
}

Teleporter.__index = Teleporter
Teleporter.SaveFileName = "Teleporter.Saves.txt"
Teleporter.SaveMemoryRecordName = "[— Teleporter Saves —] ()->"
Teleporter.UseSmoothTeleport = false
Teleporter.MaxDuration = 200

--
--- This checks if the required modules (json, Logger) are already loaded.
--- If not, it attempts to load them using the CETrequire function.
----------
if not json then
    CETrequire("json")
end

if not Logger then
    CETrequire("Module.Logger")
end

--
--- This function resolves the address of a given symbol.
--- It checks if the symbol is a pointer, and if so, uses readPointer to resolve its address.
--- If the symbol is not a pointer, it simply retrieves its address using getAddress.
--- @param symbol: The symbol (address or pointer) to resolve.
--- @param isPointer: A boolean flag indicating whether the symbol is a pointer.
--- @return The resolved address of the symbol, or nil if the resolution fails.
local function resolveAddress(symbol, isPointer)
    if isPointer then
        return readPointer(symbol)
    else
        return getAddress(symbol)
    end
end

--
--- These tables map different data types (such as Byte, Word, Dword, etc.) 
--- to their corresponding read and write functions, providing an abstraction layer
--- for reading and writing data to memory in different formats.

--
--- The `readFunctions` table maps data types to the appropriate read function.
--- It is used to easily read different types of data from memory based on the data type.
--- Map of data types to corresponding read functions
----------
local readFunctions = {
    [vtByte] = readBytes,          -- Byte: readBytes function
    [vtWord] = readSmallInteger,   -- Word: readSmallInteger function
    [vtDword] = readInteger,       -- Dword: readInteger function
    [vtQword] = readQword,         -- Qword: readQword function
    [vtSingle] = readFloat,        -- Single (Float): readFloat function
    [vtDouble] = readDouble,       -- Double: readDouble function
}

--
--- The `writeFunctions` table maps data types to the appropriate write function.
--- It is used to easily write different types of data to memory based on the data type.
--- Map of data types to corresponding write functions
----------
local writeFunctions = {
    [vtByte] = writeBytes,         -- Byte: writeBytes function
    [vtWord] = writeSmallInteger,  -- Word: writeSmallInteger function
    [vtDword] = writeInteger,      -- Dword: writeInteger function
    [vtQword] = writeQword,        -- Qword: writeQword function
    [vtSingle] = writeFloat,       -- Single (Float): writeFloat function
    [vtDouble] = writeDouble,      -- Double: writeDouble function
}

--
--- This function creates a new instance of the Teleporter object.
--- It initializes the object with the properties passed as arguments and sets up
--- the Logger components.
----------
function Teleporter:new(properties)
    local obj = setmetatable({}, self)
    obj.logger = Logger:new()
    for key, value in pairs(properties or {}) do
        if self[key] ~= nil then
            obj[key] = value
        else
            error(string.format("Invalid property: '%s'", key))
        end
    end
    obj.logger = Logger:new()
    return obj
end

--
--- ... Unused actually but preserved.
----------
function Teleporter:LogTeleportAction(actionType, details)
    if self.DebugMode then
        local timestamp = os.date("%Y-%m-%d %H:%M:%S")
        local logMessage = string.format("[%s] '%s':\n", timestamp, actionType)
        for key, value in pairs(details or {}) do
            if type(value) == "table" then
                if value.X and value.Y and value.Z then
                    logMessage = logMessage .. string.format(
                        "  %s: (%.2f, %.2f, %.2f)\n", key, value.X, value.Y, value.Z
                    )
                elseif #value == 3 then
                    logMessage = logMessage .. string.format(
                        "  %s: (%.2f, %.2f, %.2f)\n", key, value[1], value[2], value[3]
                    )
                else
                    logMessage = logMessage .. string.format("  %s: %s\n", key, tostring(value))
                end
            elseif type(value) == "number" then
                logMessage = logMessage .. string.format("  %s: %.2f\n", key, value)
            else
                logMessage = logMessage .. string.format("  %s: %s\n", key, tostring(value))
            end
        end
        print(logMessage)
    end
end

--
--- Sets the value type for the Teleporter class.
--- This defines the type of data (e.g., byte, integer, float) used when reading/writing position values.
--- @param valueType: The value type to set for reading and writing positions.
--- Valid types are defined in the readFunctions and writeFunctions tables.
----------
function Teleporter:SetValueType(valueType)
    if readFunctions[valueType] and writeFunctions[valueType] then
        self.ValueType = valueType
        self.logger:info("Set Teleporter Value Type", { ValueType = valueType })
    else
        self.logger:error("Invalid Value Type: " .. tostring(valueType))
    end
end

--
--- Toggles the smooth teleportation setting.
--- Smooth teleportation is used to move between positions with gradual interpolation.
----------
function Teleporter:ToggleSmoothTeleport()
    self.UseSmoothTeleport = not self.UseSmoothTeleport
end

--
--- Reads the position from memory using the provided symbol and offsets.
--- It resolves the base address and reads the position based on the value type.
--- @param symbol: The memory symbol representing the base address of the position.
--- @param offsets: The list of offsets to access the position data in memory.
--- @param isPointerRead: A flag indicating whether the base address is a pointer.
--- @return A table containing the position data, or nil if the read fails.
----------
function Teleporter:ReadPositionFromMemory(symbol, offsets, isPointerRead)
    local baseAddress = resolveAddress(symbol, isPointerRead)
    if not baseAddress then
        self.logger:error("Failed to Read Position From Memory", { Symbol = symbol, Error = "Base address not found or invalid" })
        return nil
    end
    local readFunc = readFunctions[self.ValueType]
    if not readFunc then
        self.logger:error("Read Function Not Found", { ValueType = self.ValueType })
        return nil
    end
    local position = {}
    for i, offset in ipairs(offsets) do
        position[i] = readFunc(baseAddress + offset)
    end
    self.logger:info("Read Position From Memory", { Symbol = symbol, Position = table.concat(position, ", ") })
    return position
end

--
--- Writes a position to memory using the provided symbol, offsets, and position data.
--- It resolves the base address and writes the position based on the value type.
--- @param symbol: The memory symbol representing the base address of the position.
--- @param offsets: The list of offsets to write the position data to.
--- @param position: The table containing the position values to write.
--- @param isPointerWrite: A flag indicating whether the base address is a pointer.
----------
function Teleporter:WritePositionToMemory(symbol, offsets, position, isPointerWrite)
    local baseAddress = resolveAddress(symbol, isPointerWrite)
    if not baseAddress then
        self.logger:error("Failed to Write Position To Memory", { Symbol = symbol, Error = "Base address not found or invalid" })
        return
    end
    local writeFunc = writeFunctions[self.ValueType]
    if not writeFunc then
        self.logger:error("Write Function Not Found", { ValueType = self.ValueType })
        return
    end
    for i, offset in ipairs(offsets) do
        writeFunc(baseAddress + offset, position[i])
    end
    self.logger:info("Write Position To Memory", { Symbol = symbol, Position = position })
end

--
--- Calculates the Euclidean distance between two 3D positions.
--- @param pos_start: The starting position (table with 3 values: x, y, z).
--- @param pos_end: The ending position (table with 3 values: x, y, z).
--- @return The 3D distance between the two positions.
----------
function Teleporter:CalculateDistance3D(pos_start, pos_end)
    local dx, dy, dz = pos_end[1] - pos_start[1], pos_end[2] - pos_start[2], pos_end[3] - pos_start[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--
--- Saves the current position by reading it from memory and writing it to a saved position symbol.
----------
function Teleporter:SaveCurrentPosition()
    local currentPosition = self:ReadPositionFromMemory(self.TransformSymbol, self.TransformOffsets, true)
    if not currentPosition then
        self.logger:error("Failed to Save Current Position", { Symbol = self.TransformSymbol, Error = "Could not read current position" })
        return
    end
    self:WritePositionToMemory(self.SavedPositionSymbol, self.SymbolOffsets, currentPosition, false)
    self.logger:info("Saved Current Position", { Position = currentPosition })
end

function Teleporter:SmoothTeleport(startPos, endPos, maxDuration)
    --[[
    if not inMainThread() then
        synchronize(function(thread)
            self:SmoothTeleport(startPos, endPos, maxDuration)
        end)
        return
    end
    ]]
    local steps = maxDuration or 250 
    local stepDuration = (maxDuration or 2) / steps
    local t = 0
    local elapsedTime = 0
    while t < 1 do
        elapsedTime = elapsedTime + stepDuration
        t = math.min(elapsedTime / (maxDuration or 2), 1)
        local easedT = t < 0.5 and 2 * t * t or -1 + (4 - 2 * t) * t
        local newPos = {
            startPos[1] + (endPos[1] - startPos[1]) * easedT,
            startPos[2] + (endPos[2] - startPos[2]) * easedT,
            startPos[3] + (endPos[3] - startPos[3]) * easedT
        }
        self:WritePositionToMemory(self.TransformSymbol, self.TransformOffsets, newPos, true)
        sleep(1)
    end
    self:WritePositionToMemory(self.TransformSymbol, self.TransformOffsets, endPos, true)
end

--[[
function Teleporter:SmoothTeleport(startPos, endPos, maxDuration)
    if not inMainThread() then return synchronize(function() self:SmoothTeleport(startPos, endPos, maxDuration) end) end
    local duration, startTime, step = (maxDuration or 2) * 1000, os.clock() * 1000, 1 / 60
    repeat
        local t = math.min((os.clock() * 1000 - startTime) / duration, 1)^2
        self:WritePositionToMemory(self.TransformSymbol, self.TransformOffsets, {
            startPos[1] + (endPos[1] - startPos[1]) * t,
            startPos[2] + (endPos[2] - startPos[2]) * t,
            startPos[3] + (endPos[3] - startPos[3]) * t
        }, true)
        sleep(1)
    until t >= 1
    self:WritePositionToMemory(self.TransformSymbol, self.TransformOffsets, endPos, true)
end
]]

--
--- Loads the saved position from memory and teleports to it.
--- If smooth teleportation is enabled, it performs a smooth transition; otherwise, it jumps directly.
--- It also saves the current position to a backup location.
----------
function Teleporter:LoadSavedPosition()
    local currentPosition = self:ReadPositionFromMemory(self.TransformSymbol, self.TransformOffsets, true)
    local savedPosition = self:ReadPositionFromMemory(self.SavedPositionSymbol, self.SymbolOffsets, false)
    if savedPosition then
        if self.UseSmoothTeleport then
            self:SmoothTeleport(currentPosition, savedPosition, self.MaxDuration)
        else
            self:WritePositionToMemory(self.TransformSymbol, self.TransformOffsets, savedPosition, true)
        end
        self:WritePositionToMemory(self.BackupPositionSymbol, self.SymbolOffsets, currentPosition, false)
        self.logger:info("Loaded Saved Position", { Position = savedPosition })
    else
        self.logger:warn("No Saved Position Found")
    end
end

--
--- Loads the backup position from memory and teleports to it.
--- Similar to LoadSavedPosition but uses a backup position.
----------
function Teleporter:LoadBackupPosition()
    local currentPosition = self:ReadPositionFromMemory(self.TransformSymbol, self.TransformOffsets, true)
    local backupPosition = self:ReadPositionFromMemory(self.BackupPositionSymbol, self.SymbolOffsets, false)
    if backupPosition then
        if self.UseSmoothTeleport then
            self:SmoothTeleport(currentPosition, backupPosition, self.MaxDuration)
        else
            self:WritePositionToMemory(self.TransformSymbol, self.TransformOffsets, backupPosition, true)
        end
        self:WritePositionToMemory(self.BackupPositionSymbol, self.SymbolOffsets, currentPosition, false)
        self.logger:info("Loaded Backup Position", { Position = backupPosition })
    else
        self.logger:warn("No Backup Position Found")
    end
end

--
--- Teleports to a waypoint by reading the waypoint's position from memory and moving the character there.
--- Similar to LoadSavedPosition, but it uses a specific waypoint symbol to teleport.
----------
function Teleporter:TeleportToWaypoint()
    local currentPosition = self:ReadPositionFromMemory(self.TransformSymbol, self.TransformOffsets, true)
    local waypointPosition = self:ReadPositionFromMemory(self.WaypointSymbol, self.WaypointOffsets, true)
    if waypointPosition then
        if self.UseSmoothTeleport then
            self:SmoothTeleport(currentPosition, waypointPosition, self.MaxDuration)
        else
            self:WritePositionToMemory(self.TransformSymbol, self.TransformOffsets, waypointPosition, true)
        end
        self:WritePositionToMemory(self.BackupPositionSymbol, self.SymbolOffsets, currentPosition, false)
        self.logger:info("Teleported To Waypoint", { Position = waypointPosition })
    else
        self.logger:warn("No Waypoint Found")
    end
end

--
--- Teleports to a specific set of coordinates (x, y, z).
--- Similar to LoadSavedPosition but allows for teleporting to arbitrary coordinates.
----------
function Teleporter:TeleportToCoordinates(x, y, z)
    local currentPosition = self:ReadPositionFromMemory(self.TransformSymbol, self.TransformOffsets, true)
    local targetPosition = { x, y, z }
    if self.UseSmoothTeleport then
        self:SmoothTeleport(currentPosition, targetPosition, self.MaxDuration)
    else
        self:WritePositionToMemory(self.TransformSymbol, self.TransformOffsets, targetPosition, true)
    end
    self:WritePositionToMemory(self.BackupPositionSymbol, self.SymbolOffsets, currentPosition, false)
    self.logger:info("Teleported To Coordinates", { Position = targetPosition })
end

--
--- Reads the current position from memory.
--- @returns the current coordinates as a table (x, y, z).
----------
function Teleporter:GetCurrentCoordinates()
    return self:ReadPositionFromMemory(self.TransformSymbol, self.TransformOffsets, true)
end

--
--- Saves the current state (positions) to a file in JSON format.
--- If no save file name is provided, it uses the default file name.
--- If no saves exist, it logs a warning.
----------
function Teleporter:WriteSavesToFile(fileName)
    fileName = fileName or self.SaveFileName
    self.logger:info("Writing Saves to File", { File = fileName })
    if not self.Saves or next(self.Saves) == nil then
        self.logger:warn("No Saves Found", { Saves = self.Saves })
        return
    end
    local jsonString = json.encode(self.Saves)
    if not jsonString then
        self.logger:error("Failed to serialize saves to JSON", { Error = "Serialization error" })
        return
    end
    local tableFile = findTableFile(fileName)
    if not tableFile then
        tableFile = createTableFile(fileName)
    end
    if not tableFile then
        self.logger:error("Failed to create or find table file", { File = fileName })
        return
    end
    local stream = tableFile.getData()
    local bytes = { string.byte(jsonString, 1, -1) }
    stream.write(bytes)
    self.logger:info("Saves written to file successfully", { File = fileName })
end

--
--- Reads the saved state (positions) from a file in JSON format.
--- If the file is not found or there is an error during deserialization, it logs the error.
----------
function Teleporter:ReadSavesFromFile(fileName)
    fileName = fileName or self.SaveFileName
    self.logger:info("Reading Saves from File", { File = fileName })
    local tableFile = findTableFile(fileName)
    if not tableFile then
        self.logger:warn("File not found", { File = fileName })
        return
    end
    local stream = tableFile.getData()
    local bytes = stream.read(stream.Size)
    local jsonString = string.char(table.unpack(bytes))
    local saves = json.decode(jsonString)
    if not saves or type(saves) ~= "table" then
        self.logger:error("Failed to deserialize saves from JSON", { Error = jsonString })
        return
    end
    self.Saves = saves
    self.logger:info("Loaded Saves from File", { File = fileName })
end

--
--- Example:
--- teleporter:AddSave("Home Base") -- Saves the current location as "Home Base".
---
--- Created Table Entry Example:
--- {
---     ["Home Base"] = { X = 100.0, Y = 50.0, Z = 200.0 }
--- }
---
--- Adds a new teleportation save with a specified name.
--- If the name is not provided or invalid, it prompts the user to enter one.
--- It saves the current coordinates (X, Y, Z) under the provided name and logs the action.
----------
function Teleporter:AddSave(name)
    if not inMainThread() then
        synchronize(function(thread)
            self:AddSave(name)
        end)
        return
    end
    if not name or type(name) ~= "string" then
        name = inputQuery("Save Teleport", "Enter a name for your save:", "Location")
    end
    if not name or type(name) ~= "string" then
        self.logger:error("Invalid Save Name", { Name = name })
        return
    end
    local position = self:GetCurrentCoordinates()
    if not (position and type(position) == "table" and position[1] and position[2] and position[3]) then
        self.logger:error("Invalid Save Position", { Position = position })
        return
    end
    self.Saves = self.Saves or {}
    if self.Saves[name] then
        self.logger:warn("Duplicate Save Name", { Name = name, ExistingPosition = self.Saves[name] })
    end
    self.Saves[name] = { X = position[1], Y = position[2], Z = position[3] }
    if self.logger then
        self.logger:info("Added Save", { Name = name, Position = { X = position[1], Y = position[2], Z = position[3] } })
    end
end

--
--- Deletes an existing save by its name.
--- If the save doesn't exist, it logs a warning. 
--- It prompts the user for a name if one isn't provided.
----------
function Teleporter:DeleteSave(name)
    if not inMainThread() then
        synchronize(function(thread)
            self:DeleteSave(name)
        end)
        return
    end
    if not name or type(name) ~= "string" then
        name = inputQuery("Delete Save", "Enter a name for a save to be deleted:", "Location")
    end
    if not name or type(name) ~= "string" then
        self.logger:error("Invalid Delete Name", { Name = name })
        return
    end
    if not self.Saves or not self.Saves[name] then
        self.logger:warn("Save Not Found", { Name = name })
        return
    end
    self.Saves[name] = nil
    self.logger:info("Deleted Save", { Name = name })
end

--
--- Before Renaming:
--- self.Saves = {
---     ["Home Base"] = { X = 100.0, Y = 50.0, Z = 200.0 },
---     ["Village"] = { X = 300.0, Y = 75.0, Z = 400.0 }
--- }
---
--- User Inputs:
--- Old Name: "Home Base"
--- New Name: "Castle"
---
--- After Renaming:
--- self.Saves = {
---     ["Castle"] = { X = 100.0, Y = 50.0, Z = 200.0 },
---     ["Village"] = { X = 300.0, Y = 75.0, Z = 400.0 }
--- }
---
--- Renames an existing save.
--- Prompts the user for the old name and new name. 
--- If the new name is already taken or invalid, it logs an error.
--- If the renaming is successful, it logs the action.
----------
function Teleporter:RenameSave()
    if not inMainThread() then
        synchronize(function(thread)
            self:RenameSave()
        end)
        return
    end
    local oldName = inputQuery("Rename Save", "Enter a name for the save to be renamed:", "Location")
    if not oldName or type(oldName) ~= "string" then
        self.logger:error("Invalid Old Name", { OldName = oldName })
        return
    end
    if not self.Saves or not self.Saves[oldName] then
        self.logger:error("Save Not Found", { Name = oldName })
        return
    end
    local newName = inputQuery("Rename Save", "Enter a new name for the save:", "Location")
    if not newName or type(newName) ~= "string" then
        self.logger:error("Invalid New Name", { NewName = newName })
        return
    end
    if self.Saves[newName] then
        self.logger:error("Save Name Already Exists", { Name = newName })
        return
    end
    self.Saves[newName] = self.Saves[oldName]
    self.Saves[oldName] = nil
    if self.logger then
        self.logger:info("Renamed Save", { OldName = oldName, NewName = newName })
    end
end

--
--- Teleports the player to a saved location by its name.
--- If the name is invalid or the save is not found, it logs an error.
--- If SmoothTeleport is enabled, it performs a smooth teleport; otherwise, it writes the new position to memory.
----------
function Teleporter:TeleportToSave(name)
    if not name or type(name) ~= "string" then
        self.logger:error("Invalid Save Name", { Name = name })
        return
    end
    local currentPosition = self:ReadPositionFromMemory(self.TransformSymbol, self.TransformOffsets, true)
    local savePosition = self.Saves[name]
    if not savePosition then
        self.logger:error("Save Not Found", { Name = name })
        return
    end
    if self.UseSmoothTeleport then
        self:SmoothTeleport(currentPosition, { savePosition.X, savePosition.Y, savePosition.Z }, self.MaxDuration)
    else
        self:WritePositionToMemory(self.TransformSymbol, self.TransformOffsets, { savePosition.X, savePosition.Y, savePosition.Z }, true)
    end
    self:TeleportToCoordinates(savePosition.X, savePosition.Y, savePosition.Z)
    self.logger:info("Teleported To Save", { Name = name, Position = savePosition })
end

--
--- Example:
--- Given the following saves:
--- self.Saves = {
---     ["Home Base"] = { X = 100.1234, Y = 50.5678, Z = 200.9101 }
--- }
---
--- The resulting memory records would be:
----    Script: "Teleport To: 'Home Base' ()->"
---     	{$lua}
---     	[ENABLE]
---     	if syntaxcheck then return end
---     	--- Save: Home Base
---     	---- X: 100.1234
---     	---- Y: 50.5678
---     	---- Z: 200.9101
---     	teleporter:TeleportToSave("Home Base")
---     	utility:autoDisable(memrec.ID)
---     	[DISABLE]
---     	}
---
--- Creates teleportation memory records for all saved locations.
--- It generates teleport records in an address list for each save, sorted by save name.
----------
function Teleporter:CreateTeleporterSaves()
    local addressList = getAddressList()
    local root = addressList.getMemoryRecordByDescription(self.SaveMemoryRecordName)
    self:ClearSubrecords(root)
    local sortedLocationNames = {}
    for locationName, _ in pairs(self.Saves) do
        table.insert(sortedLocationNames, locationName)
    end
    table.sort(sortedLocationNames)
    for _, saveName in ipairs(sortedLocationNames) do
        local position = self.Saves[saveName]
        
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
---- X: %.4f
---- Y: %.4f
---- Z: %.4f
teleporter:TeleportToSave("%s")
utility:autoDisable(memrec.ID)
[DISABLE]
]], saveName, position.X, position.Y, position.Z, saveName)
        mr.Script = scriptContent
    end
    self:LogTeleportAction("Created Teleporter Saves", { Count = tonumber(#self.Saves) })
end

--
--- Clears all child memory records under the given root record.
--- It recursively deletes subrecords until none remain.
----------
function Teleporter:ClearSubrecords(record)
    while record ~= nil and record.Count > 0 do
        memoryrecord_delete(record.Child[0])
    end
end

--
--- Prints the list of saved locations, including their names and coordinates.
--- If no saves are found, it logs a warning.
----------
function Teleporter:PrintSaves()
    local restoreDebugState = self.DebugMode
    self.DebugMode = true
    if not self.Saves or next(self.Saves) == nil then
        self:LogTeleportAction("No Saves Found", { Saves = "No saves present." })
        return
    end
    for name, position in pairs(self.Saves) do
        if position and position.X and position.Y and position.Z then
            local positionStr = string.format("(%f, %f, %f)", position.X, position.Y, position.Z)
            self:LogTeleportAction("Save", { Name = name, Position = positionStr })
        else
            self:LogTeleportAction("Invalid Save Position", { Name = name, Position = position })
        end
    end
    self:LogTeleportAction("Printed Saves", { Saves = "Successfully printed saves." })
    self.DebugMode = restoreDebugState
end

--
--- Creates a teleport memory record for the current position.
--- This allows a teleport action to be executed based on the current position when the record is enabled.
----------
function Teleporter:CreateTeleportMemoryRecord()
    local currentPosition = self:ReadPositionFromMemory(self.TransformSymbol, self.TransformOffsets, true)
    local x, y, z = currentPosition[1], currentPosition[2], currentPosition[3]
    local enableScript = string.format("{$lua}\n[ENABLE]\nif syntaxcheck then return end\nteleporter:TeleportToCoordinates(%.4f, %.4f, %.4f)\nutility:autoDisable(memrec.ID)\n[DISABLE]", x, y, z)
    local addressesList = getAddressList()
    local function createMemoryRecord(type, description)
        local memoryRecord = addressesList.createMemoryRecord()
        memoryRecord.Type = type
        memoryRecord.Description = description
        memoryRecord.Color = color or 0xFFFFFF
        memoryRecord.Options = options or ""
        if parent then
            memoryRecord.appendToEntry(parent)
        end
        return memoryRecord
    end
    local memoryRecord = createMemoryRecord(vtAutoAssembler, "Teleport To: 'Location' ()->")
    memoryRecord.Script = enableScript
    return memoryRecord
end

return Teleporter
