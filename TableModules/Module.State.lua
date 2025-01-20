local NAME = "CTI.State"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Cheat Table Interface (State)"

--[[
    Base Idea:
    - TheyCallMeTim13
    
    This module provides a simple interface for saving and loading state information for memory records in Cheat Engine.
    It uses the JSON module to serialize and deserialize the state data.

    Json Module:
        + https://github.com/rxi/json.lua

        + json.encode(value)
            Example:
                local data = {
                    name = "John",
                    age = 30,
                    isEmployed = true
                }

                local jsonString = json.encode(data)
                print(jsonString)

                {"name":"John","age":30,"isEmployed":true}

        + json.decode(jsonString)
            Example:
                local json = require("json")

                local jsonString = '{"name":"John","age":30,"isEmployed":true}'
                local data = json.decode(jsonString)

                print(data.name)  -- Output: John
                print(data.age)   -- Output: 30
                print(data.isEmployed)  -- Output: true

    Example Output - Using: State:saveTableState(stateName)
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
State = {}

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
    local instance = setmetatable({
        trainerOrigin = TrainerOrigin or "",
        logger = Logger:new()
    }, self)
    return instance
end

--
--- Get State File Path
--- Generates the file path for saving or loading a state based on the state name.
--- @param stateName: The name of the state to generate the file path for.
--- @return string: The file path for the specified state.
----------
function State:getStateFilePath(stateName)
    assert(type(stateName) == "string" and stateName ~= "", '"stateName" must be a non-empty string')
    return string.format("%s/%s.%s.state", self.trainerOrigin, process:gsub("%.exe$", ""), stateName)
end

--
--- Save Table State
--- Saves the current state of memory records to a JSON file.
--- Collects information about active memory records and stores them in a file.
--- @param stateName: The name of the state to be saved.
--- @return None.
----------
function State:saveTableState(stateName)
    local filePath = self:getStateFilePath(stateName)
    local records = {}
    self.logger:info("Starting to save table state: " .. stateName)
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
    local success, err = pcall(function() self:writeJsonFile(filePath, records) end)
    if success then
        self.logger:info("Table state saved successfully to " .. filePath)
    else
        self.logger:error("Failed to save table state: " .. (err or "Unknown error"))
    end
end

--
--- Load Table State
--- Loads the state of memory records from a JSON file and restores the records' active states.
--- @param stateName: The name of the state to be loaded.
--- @return None.
----------
function State:loadTableState(stateName)
    if stateName == "none" then
        self.logger:info("No state provided, deactivating all records.")
        self:deactivateAllRecords()
        return
    end
    local filePath = self:getStateFilePath(stateName)
    self.logger:info("Starting to load table state: " .. stateName)
    local records = self:readJsonFile(filePath)
    if not records then
        self.logger:error("Failed to load state from file: " .. filePath)
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
                self.logger:info(string.format(
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
                    self.logger:error(string.format(
                        'Error: Memory record with ID %s failed to %s.',
                        record.id,
                        record.active and "activate" or "deactivate"))
                end
            end
        else
            self.logger:warn(string.format('Warning: Memory record with ID %s not found.', record.id))
        end
        sleep(10)
    end
    self.logger:info("Table state loaded successfully.")
end

--
--- Deactivate All Records
--- Disables all active memory records in the address list.
--- Iterates through all memory records and sets their `Active` state to `false`.
--- @return None.
----------
function State:deactivateAllRecords()
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr.Active then
            mr.Active = false
        end
    end
end

--
--- Read JSON File
--- Reads the content of a JSON file and decodes it into a Lua table.
--- Handles errors in file reading or JSON decoding.
--- @param filePath: The path to the file to read.
--- @return data: The decoded Lua table from the JSON content, or `nil` if an error occurs.
----------
function State:readJsonFile(filePath)
    local file, err = io.open(filePath, "r")
    if not file then
        print(string.format('Warning: Failed to read file "%s": %s', filePath, err))
        return nil
    end
    local content = file:read("*all")
    file:close()
    local success, data = pcall(json.decode, content)
    if not success then
        print(string.format("Warning: Failed to decode JSON in file %s", filePath))
        return nil
    end
    return data
end

--
--- Write JSON File
--- Writes a Lua table to a JSON file after pretty-printing the content.
--- Handles errors in file writing or JSON serialization.
--- @param filePath: The path to the file to write.
--- @param data: The Lua table to be written to the file.
--- @return None.
----------
function State:writeJsonFile(filePath, data)
    local success, err = pcall(function()
        local file = assert(io.open(filePath, "w"))
        file:write(self:prettyPrintJson(data))
        file:close()
    end)
    if not success then
        error(string.format("Failed to save state to file: %s", err))
    end
end

-- 
--- Pretty Print JSON
--- Recursively prints a table as a formatted, indented JSON-like string.
--- Handles tables, strings, and other types (such as numbers and booleans).
--- @param data: The Lua table or value to print in JSON format.
--- @param indentLevel: The indentation level for nested elements (default is 0).
--- @return result: A string containing the formatted JSON-like representation of the data.
----------
function State:prettyPrintJson(data, indentLevel)
    local indent = indentLevel or 0
    local padding = string.rep("  ", indent)
    local result = ""
    if type(data) == "table" then
        local isArray = #data > 0
        result = isArray and "[\n" or "{\n"
        for key, value in pairs(data) do
            local keyStr = isArray and "" or string.format('%s"%s": ', padding .. "  ", tostring(key))
            result = result .. keyStr .. self:prettyPrintJson(value, indent + 1) .. ",\n"
        end
        result = result:gsub(",\n$", "\n") -- Remove trailing comma
        result = result .. padding .. (isArray and "]" or "}")
    elseif type(data) == "string" then
        result = string.format('"%s"', data:gsub('"', '\\"')) -- Escape quotes
    else
        result = tostring(data)
    end
    return result
end

return State
