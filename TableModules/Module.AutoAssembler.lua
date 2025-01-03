local NAME = 'CTI.AutoAssembler'
local AUTHOR = {'Leunsel', 'LeFiXER'}
local VERSION = '1.0.1'
local DESCRIPTION = 'Cheat Table Interface (Auto Assembler)'

AutoAssembler = {}
AutoAssembler.__index = AutoAssembler

--[[
    Base Idea:
    - TheyCallMeTim13

    Lua:autoAssemble
        + https://wiki.cheatengine.org/index.php?title=Lua:autoAssemble
        Parameter 	            Type 	    Description
        AutoAssemblerScript 	string 	    The script to run with Cheat Engine's auto assembler
        TargetSelf 	            boolean 	If set it will assemble into Cheat Engine itself
        DisableInfo 	        boolean 	If provided the [Disable] section will be handled

    Lua:autoAssembleCheck
        + https://wiki.cheatengine.org/index.php?title=Lua:autoAssembleCheck
        Parameter 	            Type 	    Description
        AutoAssemblerScript 	string 	    The script to run with Cheat Engine's auto assembler.
        Enable 	                boolean 	If true the [Enable] section will be checked, else the [Disable] section is checked.
        TargetSelf 	            boolean 	If set it will check as if assembling into Cheat Engine itself.
]]

if not Logger then
    CETrequire("Module.Logger")
end

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

function AutoAssembler.new()
    local self = setmetatable({}, AutoAssembler)
    self.states = {}
    self.gameModuleIndex = nil
    self.printErrors = true
    self.localFilesFolder = 'cea'
    self.fileExtension = '.CEA'
    self.logger = Logger:new()
    self.logger:setMinLevel("WARN")
    return self
end

function AutoAssembler:setProcessName(processName)
    if type(processName) ~= "string" then
        error("Expected Process Name to be a string but got " .. type(processName))
    end
    self.requiredProcess = processName
end

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

local State = callableObject({
    Name = nil,
    DisableInfo = nil,
    memrec = nil,
    Active = false,
    TargetSelf = false,
}, Object)

local function getStateKey(self, name)
    return (name:lower():find(self.fileExtension:lower()..'$') and name:match("^(.-)%"..self.fileExtension.."$")) or name
end

local function getFileName(self, name)
    return name:lower():find(self.fileExtension:lower()..'$') and name or name .. self.fileExtension
end

function AutoAssembler:getAttachedProcessName()
    if process == nil then
        return nil
    else
        return process or "Unknown Process"
    end
end

function isAttached()
    if process == nil or readInteger(process) == nil then
        return false
    else
        return true
    end
end

function AutoAssembler:setGameModuleIndex(findPattern)
    self.logger:info(string.format("Setting GameModuleIndex with pattern: %s", findPattern))
    local list = enumModules()
    for i = 1, #list do
        local module = list[i]
        if module and module.Name and module.Name:find(findPattern) then
            self.gameModuleIndex = i
            self.logger:info(string.format("Found matching module: %s at index %d", module.Name, i))
            return module.Name, i
        end
    end
    self.logger:warn("No matching module found for the given pattern.")
    return nil, nil
end

function AutoAssembler:getMemrec(fileName)
    local stateKey = getStateKey(self, fileName)
    return self.states[stateKey] and self.states[stateKey].memrec or nil
end

function AutoAssembler:performAutoAssemble(fileName, fileStr, targetSelf, disableInfo)
    if not isAttached() then
        self.logger:error("Not attached to a process")
        return self:handleError("Not attached to a process")
    end
    if self.requiredProcess and self:getAttachedProcessName() ~= self.requiredProcess then
        local errorMsg = string.format("Incorrect process attached. Expected: %s, Found: %s", 
                                       tostring(self.requiredProcess), 
                                       self:getAttachedProcessName())
        self.logger:error(errorMsg)
        return self:handleError(errorMsg)
    end
    local stateKey = getStateKey(self, fileName)
    local state = self.states[stateKey] or { name = fileName }
    self.logger:debug(string.format("Performing auto-assemble for %s", fileName))
    local assembled, err = autoAssembleCheck(fileStr, not disableInfo)
    if not assembled then
        local errorMsg = string.format("Error assembling file %s: %s", fileName, err or "unknown error")
        self.logger:error(errorMsg)
        return self:handleError(errorMsg)
    end
    assembled, disableInfo = autoAssemble(fileStr, targetSelf, disableInfo)
    if assembled then
        state.DisableInfo = disableInfo
        state.Active = disableInfo and true or false
        self.states[stateKey] = state
        self.logger:info(string.format("Successfully assembled file %s", fileName))
    else
        local errorMsg = string.format("Failed to assemble file %s", fileName)
        self.logger:error(errorMsg)
        return self:handleError(errorMsg)
    end

    return true
end

function AutoAssembler:autoAssemble(fileName, memrecOrTargetSelf, targetSelf)
    self.logger:info(string.format("Starting auto-assembly for file: %s", fileName))
    if not targetSelf and not isAttached() then
        self.logger:error("Attempted to assemble without being attached to a process.")
        return self:handleError("Not attached to a process")
    end
    if self.requiredProcess and self:getAttachedProcessName() ~= self.requiredProcess then
        local errorMsg = string.format(
            "Incorrect process attached. Expected: %s, Found: %s",
            tostring(self.requiredProcess),
            self:getAttachedProcessName()
        )
        self.logger:error(errorMsg)
        return self:handleError(errorMsg)
    end
    self.logger:info(string.format("Loading file: %s", fileName))
    local fileStr, err = self:loadFile(fileName)
    if not fileStr then
        self.logger:error(string.format("Failed to load file %s: %s", fileName, err))
        return self:handleError(err)
    end
    local stateKey = getStateKey(self, fileName)
    local state = self.states[stateKey] or { name = fileName }
    self.logger:debug(string.format("State initialized for file: %s | Current State: %s", fileName, tostring(state.Active or false)))
    local disableInfo = state.DisableInfo
    local memrec
    if type(memrecOrTargetSelf) == "boolean" then
        memrec = nil
        targetSelf = memrecOrTargetSelf
        self.logger:debug("Determined memrecOrTargetSelf as a boolean; adjusting targetSelf.")
    else
        memrec = memrecOrTargetSelf
        self.logger:debug(string.format("Memory record provided: %s", tostring(memrec)))
    end
    local enabling = memrec and not memrec.Active or not state.Active
    if enabling then
        self.logger:info("Enabling the script; clearing disable information.")
        disableInfo = nil
    else
        self.logger:info("Disabling the script; existing disable information retained.")
    end
    state.memrec = memrec
    state.TargetSelf = targetSelf
    self.states[stateKey] = state
    self.logger:info(string.format("State updated for file: %s | Enabling: %s", fileName, tostring(enabling)))
    local result = self:performAutoAssemble(fileName, fileStr, targetSelf, disableInfo)
    if result then
        self.logger:info(string.format("Auto-assembly completed successfully for file: %s", fileName))
    else
        self.logger:error(string.format("Auto-assembly failed for file: %s", fileName))
    end

    return result
end

function AutoAssembler:loadFile(fileName)
    local fileStr, err = self:read(fileName)
    if not fileStr then
        self.logger:warn(string.format("File %s not found in primary location, attempting table file...", fileName))
        fileStr, err = self:readTableFile(fileName)
    end
    if not fileStr then
        -- local errorMsg = string.format("Failed to load file %s: %s", fileName, err or "unknown error")
        -- self.logger:error(errorMsg)
        return nil, err or 'File not found'
    end
    self.logger:info(string.format("File %s loaded successfully", fileName))
    return fileStr, nil
end

function AutoAssembler:read(fileName)
    self.logger:info(string.format("Reading file: %s", fileName))
    local sep = package.config:sub(1, 1)
    local trainerOriginPath = TrainerOrigin or ''
    if trainerOriginPath == '' then
        return nil, "TrainerOrigin path is empty"
    end
    local fullPath = trainerOriginPath .. 'cea' .. sep .. fileName
    self.logger:info(string.format("Attempting to read file from path: %s", fullPath))
    
    local f, err = io.open(fullPath, 'r')
    if not f then
        self.logger:warn(string.format("Failed to open file: %s", fullPath))
        return nil, err
    end
    local content = f:read('*all')
    f:close()
    return content, nil
end

function AutoAssembler:readTableFile(fileName)
    self.logger:info(string.format("Reading table file: %s", fileName))
    local tableFile = findTableFile(fileName)
    if not tableFile then
        return nil, 'Table file not found'
    end
    local stream = tableFile.getData()
    return readStringLocal(stream.memory, stream.size), nil
end

function AutoAssembler:handleError(msg)
    self.logger:error(msg)
    error(msg)
end

function AutoAssembler:setState(stateKey, stateData)
    self.states[stateKey] = stateData
end

function MainForm.OnProcessOpened()
    AutoAssembler.states = {}
    ProcessID = getOpenedProcessID()
end

return AutoAssembler
