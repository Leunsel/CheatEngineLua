local NAME = 'CTI.AutoAssembler'
local AUTHOR = {'Leunsel', 'LeFiXER'}
local VERSION = '1.0.1'
local DESCRIPTION = 'Cheat Table Interface (Auto Assembler)'

--[[
    Script Name: Module.AutoAssembler.lua
    Description: The Auto Assembler Module is a Lua-based script designed for
                 Cheat Engine to handle and execute auto-assembly scripts
                 efficiently. This module includes advanced error handling,
                 logging, file management, and process validation to enhance
                 script execution reliability. It provides an interface for
                 executing Cheat Engine assembly scripts dynamically while
                 ensuring robust script management.
    
    Version History:
    -----------------------------------------------------------------------------
    Version | Date         | Author          | Changes
    -----------------------------------------------------------------------------
    1.0.0   | ----------   | Leunsel,LeFiXER | Initial release.
    1.0.1   | 14.02.2025   | Leunsel         | Added Version History
    -----------------------------------------------------------------------------
    
    Notes:
    - Base Idea:
        - TheyCallMeTim13

    - Sources:
        Lua:AutoAssemble
            + https://wiki.cheatengine.org/index.php?title=Lua:autoAssemble
            Parameter 	            Type 	    Description
            AutoAssemblerScript 	string 	    The script to run with Cheat Engine's auto assembler
            TargetSelf 	            boolean 	If set it will assemble into Cheat Engine itself
            DisableInfo 	        boolean 	If provided the [Disable] section will be handled

        Lua:AutoAssembleCheck
            + https://wiki.cheatengine.org/index.php?title=Lua:autoAssembleCheck
            Parameter 	            Type 	    Description
            AutoAssemblerScript 	string 	    The script to run with Cheat Engine's auto assembler.
            Enable 	                boolean 	If true the [Enable] section will be checked, else the
                                                [Disable] section is checked.
            TargetSelf 	            boolean 	If set it will check as if assembling into Cheat Engine
                                                itself.

    - Features:
        - Execute Auto Assembly Scripts:
            * Run assembly scripts dynamically within Cheat Engine.
        - Error Handling:
            * Captures and logs errors encountered during execution.
        - Logging System:
            * Stores logs for debugging and analysis on different levels.
        - Process Validation:
            * Ensures that scripts run only when the intended process is active.
        - File Management:
            * Saves and loads scripts from external files.
]]

--
--- Would contain several configuration properties that can be customized.
--- Set within the Table Lua Script and passed to the constructor of the class.
--- None in this case.
----------
AutoAssembler = {}

--
--- Set the metatable for the Auto Assembler object so that it behaves as an "object-oriented class".
----------
AutoAssembler.__index = AutoAssembler

--
--- This checks if the required module(s) (Logger) are already loaded.
--- If not, it attempts to load them using the CETrequire function.
----------
if not Logger then
    CETrequire("Module.Logger")
end

--
--- Attempts to parse a Lua error message to provide a more structured error report.
--- Extracts the line number and error message from the provided Lua error string.
--- @param err string - The raw error message to parse.
--- @return string|nil - A formatted error string or nil if parsing fails.
----------
local function tryParseLuaError(err)
    local function _tryParseLuaError(err)
        local msg = err:match('^(.-):')
        local lineNum = msg:match('.*%s(.-)$')
        msg = msg:gsub('.*%s(.-)$', '')
        lineNum = tonumber(lineNum)
        err = err:match(':%d+:(.*)$')
        return string.format('%sError in Lua script line: %d: %s', msg, lineNum, err)
    end
    local status, ret = pcall(_tryParseLuaError, err)
    if status then return ret end
end

--
--- Attempts to parse an AutoAssembler error message for clearer reporting.
--- Adjusts the line number by accounting for offsets and extracts the error message.
--- @param err string - The raw error message to parse.
--- @return string|nil - A formatted error string or nil if parsing fails.
----------
local function tryParseAssemblerError(err)
    local function _tryParseAssemblerError(err)
        local msg = err:match('^Error%sin%sline%s.-%s(.*)$')
        local lineNum = err:match('^Error%sin%sline%s(.-)%s.*$')
        lineNum = lineNum - 4
        return string.format('Error in AA script line %d: %s', lineNum, msg)
    end
    local status, ret = pcall(_tryParseAssemblerError, err)
    if status then return ret end
end

--
--- Creates a new instance of the `AutoAssembler` class.
--- Initializes default properties, including states, logging, and file management settings.
--- @return A new instance of the `AutoAssembler` class.
----------
function AutoAssembler:new()
    local self = setmetatable({}, AutoAssembler)
    self.states = {}
    self.gameModuleIndex = nil
    self.printErrors = true
    self.localFilesFolder = 'cea'
    self.fileExtension = '.CEA'
    self.logger = Logger:new()
    self.logger:SetMinLevel("WARN")
    return self
end

--
--- Sets the name of the required process for the auto-assembler.
--- Ensures that the provided process name is a string.
--- @param processName string - The name of the required process.
--- @return None.
----------
function AutoAssembler:SetProcessName(processName)
    if type(processName) ~= "string" then
        error("Expected Process Name to be a string but got " .. type(processName))
    end
    self.requiredProcess = processName
end
registerLuaFunctionHighlight('SetProcessName')

--
--- Creates a callable object with optional properties and an optional base class.
--- The resulting object can be called as a function and inherits from the base class, if provided.
--- @param properties table|nil - A table of properties to initialize the object with.
--- @param baseClass table|nil - The base class to inherit from, if any.
--- @return table - The created callable object.
----------
function callableObject(properties, baseClass)
    local obj = properties or {}
    if baseClass then
        setmetatable(obj, { __index = baseClass })
    end
    setmetatable(obj, {
        __call = function(self, ...)
            return self
        end
    })
    return obj
end

--
--- Retrieves the unique state key for a given file name.
--- Ensures the key is derived from the file name and its extension.
--- @param self table - The auto-assembler instance.
--- @param name string - The name of the file.
--- @return string - The unique state key for the file.
----------
local State = callableObject({
    Name = nil,
    DisableInfo = nil,
    memrec = nil,
    Active = false,
    TargetSelf = false,
}, Object)

--
--- Ensures a given name includes the expected file extension.
--- Appends the file extension to the name if it is not already present.
--- @param self table - The auto-assembler instance.
--- @param name string - The name of the file.
--- @return string - The file name with the correct extension.
----------
local function GetStateKey(self, name)
    return (name:lower():find(self.fileExtension:lower()..'$') and name:match("^(.-)%"..self.fileExtension.."$")) or name
end

--
--- Ensures a given name includes the expected file extension.
--- If the file name does not already have the extension, it appends the specified file extension.
--- @param self table - The auto-assembler instance containing the `fileExtension` property.
--- @param name string - The name of the file.
--- @return string - The file name with the correct extension.
----------
local function GetFileName(self, name)
    return name:lower():find(self.fileExtension:lower()..'$') and name or name .. self.fileExtension
end

--
--- Retrieves the name of the currently attached process.
--- Returns the process name if attached, or `nil` if no process is attached.
--- Defaults to "Unknown Process" if the process is defined but invalid.
--- @return string|nil - The name of the attached process, or `nil` if no process is attached.
----------
function AutoAssembler:GetAttachedProcessName()
    if process == nil then
        return nil
    else
        return process or "Unknown Process"
    end
end
registerLuaFunctionHighlight('GetAttachedProcessName')

--
--- Checks whether Cheat Engine is currently attached to a process.
--- @return boolean - "true" if attached to a process, "false" otherwise.
----------
function isAttached()
    if process == nil or readInteger(process) == nil then
        return false
    else
        return true
    end
end
registerLuaFunctionHighlight('isAttached')

--
--- Sets the game module index based on a specified pattern.
--- Searches through the loaded modules for a name matching the pattern and updates the game module index accordingly.
--- @param findPattern string - The pattern to search for in the module names.
--- @return string|nil, number|nil - The name of the matching module and its index, or "nil" if no match is found.
----------
function AutoAssembler:SetGameModuleIndex(findPattern)
    self.logger:Info(string.format("Setting GameModuleIndex with pattern: %s", findPattern))
    local list = enumModules()
    for i = 1, #list do
        local module = list[i]
        if module and module.Name and module.Name:find(findPattern) then
            self.gameModuleIndex = i
            self.logger:Info(string.format("Found matching module: %s at index %d", module.Name, i))
            return module.Name, i
        end
    end
    self.logger:Warn("No matching module found for the given pattern.")
    return nil, nil
end
registerLuaFunctionHighlight('SetGameModuleIndex')

--
--- Retrieves the memory record associated with the given file.
--- Uses the state key to look up the memory record stored for the specified file.
--- @param fileName string - The name of the file for which the memory record is to be retrieved.
--- @return userdata|nil - The memory record if it exists, or "nil" if not found.
----------
function AutoAssembler:GetMemrec(fileName)
    local stateKey = GetStateKey(self, fileName)
    return self.states[stateKey] and self.states[stateKey].memrec or nil
end
registerLuaFunctionHighlight('GetMemrec')

--
--- Performs the core auto-assembly logic for a given file. 
--- Validates the process attachment and executes the assembly with appropriate state updates.
--- @param fileName string - The name of the file to auto-assemble.
--- @param fileStr string - The contents of the file to be assembled.
--- @param targetSelf boolean - Indicates whether to target the current process ("true") or not ("false").
--- @param disableInfo table|nil - Contains information necessary for disabling the script; nil when enabling.
--- @return boolean - "true" if the assembly process was successful, "false" otherwise.
----------
function AutoAssembler:PerformAutoAssemble(fileName, fileStr, targetSelf, disableInfo)
    if not isAttached() then
        self.logger:Error("Not attached to a process")
        return self:HandleError("Not attached to a process")
    end
    if self.requiredProcess and self:GetAttachedProcessName() ~= self.requiredProcess then
        local errorMsg = string.format("Incorrect process attached. Expected: %s, Found: %s", 
                                       tostring(self.requiredProcess), 
                                       self:GetAttachedProcessName())
        self.logger:Error(errorMsg)
        return self:HandleError(errorMsg)
    end
    local stateKey = GetStateKey(self, fileName)
    local state = self.states[stateKey] or { name = fileName }
    self.logger:Debug(string.format("Performing auto-assemble for %s", fileName))
    local assembled, err = autoAssembleCheck(fileStr, not disableInfo)
    if not assembled then
        local errorMsg = string.format("Error assembling file %s: %s", fileName, err or "unknown error")
        self.logger:Error(errorMsg)
        return self:HandleError(errorMsg)
    end
    assembled, disableInfo = AutoAssemble(fileStr, targetSelf, disableInfo)
    if assembled then
        state.DisableInfo = disableInfo
        state.Active = disableInfo and true or false
        self.states[stateKey] = state
        self.logger:Info(string.format("Successfully assembled file %s", fileName))
    else
        local errorMsg = string.format("Failed to assemble file %s", fileName)
        self.logger:Error(errorMsg)
        return self:HandleError(errorMsg)
    end
    return true
end
registerLuaFunctionHighlight('PerformAutoAssemble')

--
--- Performs the auto-assembly process for a given file, validating preconditions and maintaining state.
--- This method handles loading the specified file, checking process attachment requirements, 
--- and updating the state for enabling or disabling scripts.
--- @param fileName string - The name of the file to auto-assemble.
--- @param memrecOrTargetSelf userdata|boolean - Either a memory record to associate with this assembly, or a boolean indicating "targetSelf".
--- @param targetSelf boolean|nil - Indicates whether to target the current process ("true") or not ("false"). Ignored if "memrecOrTargetSelf" is a memory record.
--- @return boolean - "true" if the auto-assembly process was successful, "false" otherwise.
----------
function AutoAssembler:AutoAssemble(fileName, memrecOrTargetSelf, targetSelf)
    self.logger:Info(string.format("Starting auto-assembly for file: %s", fileName))
    if not targetSelf and not isAttached() then
        self.logger:Error("Attempted to assemble without being attached to a process.")
        return self:HandleError("Not attached to a process")
    end
    if self.requiredProcess and self:GetAttachedProcessName() ~= self.requiredProcess then
        local errorMsg = string.format(
            "Incorrect process attached. Expected: %s, Found: %s",
            tostring(self.requiredProcess),
            self:GetAttachedProcessName()
        )
        self.logger:Error(errorMsg)
        return self:HandleError(errorMsg)
    end
    self.logger:Info(string.format("Loading file: %s", fileName))
    local fileStr, err = self:LoadFile(fileName)
    if not fileStr then
        self.logger:Error(string.format("Failed to load file %s: %s", fileName, err))
        return self:HandleError(err)
    end
    local stateKey = GetStateKey(self, fileName)
    local state = self.states[stateKey] or { name = fileName }
    self.logger:Debug(string.format("State initialized for file: %s | Current State: %s", fileName, tostring(state.Active or false)))
    local disableInfo = state.DisableInfo
    local memrec
    if type(memrecOrTargetSelf) == "boolean" then
        memrec = nil
        targetSelf = memrecOrTargetSelf
        self.logger:Debug("Determined memrecOrTargetSelf as a boolean; adjusting targetSelf.")
    else
        memrec = memrecOrTargetSelf
        self.logger:Debug(string.format("Memory record provided: %s", tostring(memrec)))
    end
    local enabling = memrec and not memrec.Active or not state.Active
    if enabling then
        self.logger:Info("Enabling the script; clearing disable information.")
        disableInfo = nil
    else
        self.logger:Info("Disabling the script; existing disable information retained.")
    end
    state.memrec = memrec
    state.TargetSelf = targetSelf
    self.states[stateKey] = state
    self.logger:Info(string.format("State updated for file: %s | Enabling: %s", fileName, tostring(enabling)))
    local result = self:PerformAutoAssemble(fileName, fileStr, targetSelf, disableInfo)
    if result then
        self.logger:Info(string.format("Auto-assembly completed successfully for file: %s", fileName))
    else
        self.logger:Error(string.format("Auto-assembly failed for file: %s", fileName))
    end

    return result
end
registerLuaFunctionHighlight('AutoAssemble')

--
--- Loads the contents of a specified file, attempting multiple locations if necessary.
--- First tries reading from the primary location, and if that fails, attempts to read from a table file.
--- @param fileName string - The name of the file to load.
--- @return string|nil - The content of the file if successful, or `nil` if the file could not be loaded.
--- @return string|nil - An error message if loading fails, or `nil` if successful.
----------
function AutoAssembler:LoadFile(fileName)
    local fileStr, err = self:Read(fileName)
    if not fileStr then
        self.logger:Warn(string.format("File %s not found in primary location, attempting table file...", fileName))
        fileStr, err = self:ReadTableFile(fileName)
    end
    if not fileStr then
        -- local errorMsg = string.format("Failed to load file %s: %s", fileName, err or "unknown error")
        -- self.logger:Error(errorMsg)
        return nil, err or 'File not found'
    end
    self.logger:Info(string.format("File %s loaded successfully", fileName))
    return fileStr, nil
end
registerLuaFunctionHighlight('LoadFile')

--
--- Reads the content of a file from the primary location.
--- Constructs the full path to the file based on the `TrainerOrigin` and subdirectories.
--- @param fileName string - The name of the file to read.
--- @return string|nil - The file content if successful, or `nil` if the file could not be opened.
--- @return string|nil - An error message if reading fails, or `nil` if successful.
----------
function AutoAssembler:Read(fileName)
    self.logger:Info(string.format("Reading file: %s", fileName))
    local sep = package.config:sub(1, 1)
    local trainerOriginPath = TrainerOrigin or ''
    if trainerOriginPath == '' then
        return nil, "TrainerOrigin path is empty"
    end
    local fullPath = trainerOriginPath .. 'cea' .. sep .. fileName
    self.logger:Info(string.format("Attempting to read file from path: %s", fullPath))
    
    local f, err = io.open(fullPath, 'r')
    if not f then
        self.logger:Warn(string.format("Failed to open file: %s", fullPath))
        return nil, err
    end
    local content = f:read('*all')
    f:close()
    return content, nil
end
registerLuaFunctionHighlight('Read')

--
--- Reads the content of a file from the table file storage.
--- Uses the `findTableFile` function to locate the file and retrieves its content.
--- @param fileName string - The name of the table file to read.
--- @return string|nil - The file content if successful, or `nil` if the file could not be found.
--- @return string|nil - An error message if reading fails, or `nil` if successful.
----------
function AutoAssembler:ReadTableFile(fileName)
    self.logger:Info(string.format("Reading table file: %s", fileName))
    local tableFile = findTableFile(fileName)
    if not tableFile then
        return nil, 'Table file not found'
    end
    local stream = tableFile.getData()
    return readStringLocal(stream.memory, stream.size), nil
end
registerLuaFunctionHighlight('ReadTableFile')

--
--- Logs and handles an error message.
--- Logs the error through the logger and raises a Lua error.
--- @param msg string - The error message to handle.
--- @return None. This function does not return, as it raises an error.
----------
function AutoAssembler:HandleError(msg)
    self.logger:Error(msg)
    error(msg)
end

--
--- Sets the state for a specific key in the `states` table.
--- This function updates or initializes the state associated with the given key.
--- @param stateKey string - The key used to identify the state.
--- @param stateData table - The data representing the state to set.
--- @return None.
----------
function AutoAssembler:SetState(stateKey, stateData)
    self.states[stateKey] = stateData
end

--
--- Initializes the `AutoAssembler.states` table and retrieves the process ID.
--- This function should be called when a new process is opened.
--- @return None.
----------
function MainForm.OnProcessOpened()
    AutoAssembler.states = {}
    ProcessID = getOpenedProcessID()
end

return AutoAssembler
