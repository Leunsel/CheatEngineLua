local NAME = "CTI.State"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.1"
local DESCRIPTION = "Cheat Table Interface (State)"

--[[
    Script Name: Module.State.lua
    Description: The State module provides a structured interface for saving and
                 loading state information for memory records in Cheat Engine.
                 It allows users to capture the current state of active memory
                 records and restore them later, ensuring consistency across
                 Cheat Engine sessions.
                 This module leverages the json.lua library to serialize and
                 deserialize state data and integrates with the CTI.Logger
                 module for structured logging.
    
    Version History:
    -----------------------------------------------------------------------------
    Version | Date         | Author          | Changes
    -----------------------------------------------------------------------------
    1.0.0   | ----------   | Leunsel,LeFiXER | Initial release.
    1.0.1   | 14.02.2025   | Leunsel,LeFiXER | Added Version History, Diff. Json Module
    -----------------------------------------------------------------------------
    
    Notes:
    - Base Idea:
        - TheyCallMeTim13

    - Features:
        - Saves the active state of memory records to a JSON file.
        - Loads and restores the active state from a JSON file.
        - Uses structured JSON for easy readability and data manipulation.
        - Logs operations with different severity levels (INFO, WARN, ERROR).
        - Includes error handling for missing memory records or corrupted JSON files.

    - Json Module:
        - https://github.com/rxi/json.lua (Old Module)

        - json.encode(value)
            Example:
                local data = {
                    name = "John",
                    age = 30,
                    isEmployed = true
                }

                local jsonString = json.encode(data)
                print(jsonString)

                {"name":"John","age":30,"isEmployed":true}

        - json.decode(jsonString)
            Example:
                local json = require("json")

                local jsonString = '{"name":"John","age":30,"isEmployed":true}'
                local data = json.decode(jsonString)

                print(data.name)  -- Output: John
                print(data.age)   -- Output: 30
                print(data.isEmployed)  -- Output: true

    Example Output - Using: State:SaveTableState(stateName)
        [
        {
            "type": "ScriptID",
            "active": true,
            "id": 1337200363,
            "name": "Table Activation ()->"
        },
        {
            "type": "HeaderID",
            "active": true,
            "id": 1337201298,
            "name": "[— Scripts —] ()->"
        },
        {
        ...
]]

--
--- Would contain several configuration properties that can be customized.
--- Set within the Table Lua Script and passed to the constructor of the class.
--- None in this case.
----------
State = {
    trainerOrigin = TrainerOrigin or ""
}

--
--- Set the metatable for the Teleporter object so that it behaves as an "object-oriented class".
----------
State.__index = State

--
--- This checks if the required modules (json, Logger) are already loaded.
--- If not, it attempts to load them using the CETrequire function.
----------
if not json then
    CETrequire("json")
    json = JSON:new()
end

if not Logger then
    CETrequire("Module.Logger")
end

--
--- This function creates a new instance of the State object.
--- It initializes the object with the properties passed as arguments and sets up
--- the Logger components.
----------
function State:new()
    local instance = setmetatable({}, self)
    self.logger = Logger:new()
    return instance
end

--
--- Get State File Path
--- Generates the file path for saving or loading a state based on the state name.
--- @param stateName: The name of the state to generate the file path for.
--- @return string: The file path for the specified state.
----------
function State:GetStateFilePath(stateName)
    if not process then
        self.logger:Error("No process found, cannot save state.")
        return
    end
    assert(type(stateName) == "string" and stateName ~= "", '"stateName" must be a non-empty string')
    return string.format("%s/%s.%s.state", self.trainerOrigin, process:gsub("%.exe$", ""), stateName)
end
registerLuaFunctionHighlight('GetStateFilePath')

--
--- Save Table State
--- Saves the current state of memory records to a JSON file.
--- Collects information about active memory records and stores them in a file.
--- @param stateName: The name of the state to be saved.
--- @return None.
----------
function State:SaveTableState(stateName)
    local filePath = self:GetStateFilePath(stateName)
    if not filePath then
        self.logger:Error("Failed to get state file path. Aborted.")
        return
    end
    local records = {}
    self.logger:Info("Starting to save table state: " .. stateName)
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr.Active then
            local recordType = mr.Type == vtAutoAssembler and "ScriptID" or (mr.IsGroupHeader and "HeaderID")
            if recordType then
                table.insert(records, { id = mr.ID, type = recordType, active = mr.Active, name = mr.Description })
            end
        end
    end
    -- Sorting the list will cause more problems than it would solve.
    -- table.sort(records, function(a, b) return a.id < b.id end)
    local success, err = pcall(function() self:WriteJsonFile(filePath, records) end)
    if success then
        self.logger:Info("Table state saved successfully to " .. filePath)
    else
        self.logger:Error("Failed to save table state: " .. (err or "Unknown error"))
    end
end
registerLuaFunctionHighlight('SaveTableState')

--
--- Load Table State
--- Loads the state of memory records from a JSON file and restores the records' active states.
--- @param stateName: The name of the state to be loaded.
--- @return None.
----------
function State:LoadTableState(stateName)
    if stateName == "none" then
        self.logger:Info("No state provided, deactivating all records.")
        self:DeactivateAllRecords()
        return
    end
    local filePath = self:GetStateFilePath(stateName)
    if not filePath then
        self.logger:Error("Failed to get state file path. Aborted.")
        return
    end
    self.logger:Info("Starting to load table state: " .. stateName)
    local records = self:ReadJsonFile(filePath)
    if not records then
        self.logger:Error("Failed to load state from file: " .. filePath)
        return
    end
    for _, record in ipairs(records) do
        local mr = AddressList.getMemoryRecordByID(tonumber(record.id))
        if mr then
            local isValid =
                (record.type == "ScriptID" and mr.Type == vtAutoAssembler) or
                (record.type == "HeaderID" and mr.IsGroupHeader)
            if isValid then
                mr.Active = record.active
                self.logger:Info(string.format(
                    "Memory record with ID %s set to %s.",
                    record.id,
                    record.active and "active" or "inactive"))
                local attempts = 0
                local maxAttempts = 50 -- Max 500ms (50 * 10ms)
                while mr.Active ~= record.active and attempts < maxAttempts do
                    sleep(10)
                    attempts = attempts + 1
                end
                if mr.Active ~= record.active then
                    self.logger:Error(string.format(
                        'Error: Memory record with ID %s failed to %s.',
                        record.id,
                        record.active and "activate" or "deactivate"))
                end
            end
        else
            self.logger:Warn(string.format('Warning: Memory record with ID %s not found.', record.id))
        end
        sleep(10)
    end
    self.logger:Info("Table state loaded successfully.")
end
registerLuaFunctionHighlight('LoadTableState')

--
--- Deactivate All Records
--- Disables all active memory records in the address list.
--- Iterates through all memory records and sets their `Active` state to `false`.
--- @return None.
----------
function State:DeactivateAllRecords()
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr.Active then
            mr.Active = false
        end
    end
end
registerLuaFunctionHighlight('DeactivateAllRecords')

--
--- Read JSON File
--- Reads the content of a JSON file and decodes it into a Lua table.
--- Handles errors in file reading or JSON decoding.
--- @param filePath: The path to the file to read.
--- @return data: The decoded Lua table from the JSON content, or `nil` if an error occurs.
----------
function State:ReadJsonFile(filePath)
    local file, err = io.open(filePath, "r")
    if not file then
        print(string.format('Warning: Failed to read file "%s": %s', filePath, err))
        return nil
    end
    local content = file:read("*all")
    file:close()
    local data = json:decode(content)
    if not data then
        print(string.format("Warning: Failed to decode JSON in file %s", filePath))
        return nil
    end
    return data
end
registerLuaFunctionHighlight('ReadJsonFile')

--
--- Write JSON File
--- Writes a Lua table to a JSON file after pretty-printing the content.
--- Handles errors in file writing or JSON serialization.
--- @param filePath: The path to the file to write.
--- @param data: The Lua table to be written to the file.
--- @return None.
----------
function State:WriteJsonFile(filePath, data)
    local success, err = pcall(function()
        local file = assert(io.open(filePath, "w"))
        file:write(json:encode_pretty(data))
        file:close()
    end)
    if not success then
        error(string.format("Failed to save state to file: %s", err))
    end
end
registerLuaFunctionHighlight('WriteJsonFile')

return State
