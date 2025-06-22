local NAME = "Manifold.AutoAssembler.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Manifold Framework Auto-Assembler"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.
]]--

AutoAssembler = {
    States = {},
    RequiredProcess = "",
    GameModuleIndex = "",
    PrintErrors = true,
    LocalFilesFolder = 'CEA',
    FileExtension = '.CEA',
    BreakOnError = true,
}
AutoAssembler.__index = AutoAssembler

function AutoAssembler:New()
    local instance = setmetatable({}, self)
    self:CheckDependencies()
    instance.Name = NAME or "Unnamed Module"
    return instance
end
registerLuaFunctionHighlight('New')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table  {name, version, author, description}
--
function AutoAssembler:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
--- ∑ ...
--
function AutoAssembler:CheckDependencies()
    local dependencies = {
        { name = "json", path = "Manifold.Json",  init = function() json = JSON:new() end },
        { name = "logger", path = "Manifold.Logger",  init = function() logger = Logger:New() end },
        { name = "customIO", path = "Manifold.CustomIO", init = function() customIO = CustomIO:New() end },
        { name = "processHandler", path = "Manifold.ProcessHandler", init = function() processHandler = ProcessHandler:New() end },
    }
    for _, dep in ipairs(dependencies) do
        local depName = dep.name
        if _G[depName] == nil then
            logger:Warning("[Auto-Assembler] '" .. depName .. "' dependency not found. Attempting to load...")
            local success, result = pcall(CETrequire, dep.path)
            if success then
                logger:Info("[Auto-Assembler] Loaded dependency '" .. depName .. "'.")
                if dep.init then dep.init() end
            else
                logger:Error("[Auto-Assembler] Failed to load dependency '" .. depName .. "': " .. result)
            end
        else
            logger:Debug("[Auto-Assembler] Dependency '" .. depName .. "' is already loaded")
        end
    end
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

--
--- ∑ Retrieves the state key associated with the given file name.
---   If the file name ends with the expected file extension, it strips the extension and returns the base name.
---   If the file name does not match the expected pattern, it returns the original file name.
--- @param name string  # The file name for which to derive the state key.
--- @return string|nil  # Returns the derived state key (base name) or the original name if no match is found.
--
function AutoAssembler:GetStateKey(name)
    if type(name) ~= "string" then
        logger:Error("[Auto-Assembler] Invalid file name type. Expected string, got '" .. type(name) .. "'.")
        return nil
    end
    local fileExtensionPattern = self.FileExtension:lower()
    local lowerName = name:lower()
    if lowerName:find(fileExtensionPattern .. '$') then
        local baseName = name:sub(1, #name - #fileExtensionPattern)
        if baseName and baseName ~= "" then
            logger:Info("[Auto-Assembler] Extracted base name (State Key) '" .. baseName .. "' from '" .. name .. "'.")
            return baseName
        else
            logger:Warning("[Auto-Assembler] File name match failed for '" .. name .. "'. Returning the original name.")
        end
    end
    return name
end

--
--- ∑ Updates or creates a state for a given file.
---   This function checks if the state for a given file exists or not, then updates or creates it accordingly.
--- @param fileName string  # The name of the file for which the state is being updated.
--- @param memrec table|nil  # The memory record associated with the state (optional).
--- @param targetSelf boolean  # A flag indicating whether the assembly is targeting the self process.
--- @return table|nil  # Returns the updated state or 'nil' if an error occurs.
--
function AutoAssembler:UpdateState(fileName, memrec, targetSelf)
    if type(fileName) ~= "string" then
        logger:Error("[Auto-Assembler] Invalid file name type. Expected string, got %s.", type(fileName))
        return nil
    end
    local stateKey = self:GetStateKey(fileName)
    if not stateKey then
        logger:Error("[Auto-Assembler] Failed to derive state key for '".. fileName .."'.")
        return nil
    end
    local state = self.States[stateKey] or { name = fileName, Active = false, TargetSelf = false, memrec = nil, DisableInfo = nil }
    state.memrec = memrec
    state.TargetSelf = targetSelf
    state.Active = (memrec and not memrec.Active) or not state.Active
    if not state.Active then
        state.DisableInfo = state.DisableInfo or "Disabled due to memory record inactivity"
    else
        state.DisableInfo = nil
    end
    self.States[stateKey] = state
    return state
end

--
--- ∑ Ensures the necessary directories exist for storing files.
---   This function checks and creates directories for the data and process-specific directories if needed.
--- @return boolean  # Returns 'true' if all directories are successfully created, otherwise 'false'.
--
function AutoAssembler:EnsureDirectoriesExist()
    if not customIO:EnsureDataDirectory() then
        logger:Error("[Auto-Assembler] Failed to ensure base data directory.")
        return false
    end
    local ceaDir = string.format("%s/%s", customIO.DataDir, self.LocalFilesFolder)
    if not customIO:EnsureDirectoryExists(ceaDir) then
        logger:Error("[Auto-Assembler] Failed to create/check directory: " .. ceaDir)
        return false
    end
    local processName = processHandler:GetAttachedProcessName()
    if not processName then
        logger:Error("[Auto-Assembler] No process attached. Cannot determine process-specific directory.")
        return false
    end
    local processDir = string.format("%s/%s", ceaDir, extractFileNameWithoutExt(processName))
    if not customIO:EnsureDirectoryExists(processDir) then
        logger:Error("[Auto-Assembler] Failed to create/check process-specific directory: " .. processDir)
        return false
    end
    return true
end

--
--- ∑ Formats the file name by ensuring the correct extension is appended.
---   If the file name already has the correct extension, it returns the file name unchanged.
--- @param name string  # The name of the file to be formatted.
--- @return string  # Returns the formatted file name with the correct extension.
--
function AutoAssembler:FormatFileName(name)
    if name:lower():find(self.FileExtension:lower() .. '$') then
        return name
    end
    return name .. self.FileExtension
end

--
--- ∑ Retrieves the full file path for a given file name.
---   This function ensures that the required directories exist and constructs the full path to the file.
--- @param fileName string  # The name of the file to get the full path for.
--- @return string|nil  # Returns the full file path, or 'nil' if there is an error.
--
function AutoAssembler:GetFilePath(fileName)
    if not self:EnsureDirectoriesExist() then
        logger:Error("[Auto-Assembler] Directory check failed. Cannot get file path.")
        return nil
    end
    local processName = processHandler:GetAttachedProcessName()
    if not processName then
        logger:Error("[Auto-Assembler] No process attached. Cannot generate file path.")
        return nil
    end
    return customIO.DataDir .. "\\" .. self.LocalFilesFolder .. "\\" .. extractFileNameWithoutExt(processName) .. "\\" .. self:FormatFileName(fileName)
end

--
--- ∑ Validates if the current process is valid.
---   This function checks if a process is attached and whether it matches the required process name.
--- @return boolean  # Returns 'true' if the process is valid, otherwise 'false'.
--
function AutoAssembler:ValidateProcess()
    if not processHandler:IsProcessAttached() then
        logger:Error("[Auto-Assembler] Not attached to any process.")
        return false
    end
    local attachedProcess = processHandler:GetAttachedProcessName()
    if self.RequiredProcess and attachedProcess ~= self.RequiredProcess then
        logger:Error("[Auto-Assembler] Incorrect process. Expected '" .. self.RequiredProcess .. "', but found '" .. (attachedProcess or "None") .. "'.")
        return false
    end
    return true
end

--
--- ∑ Loads the content of a file, either from a local file or from a TableFile.
---   This function attempts to read the file from disk and falls back to the TableFiles if unsuccessful.
--- @param fileName string  # The name of the file to load.
--- @return string|nil  # Returns the file content as a string, or 'nil' if an error occurs.
--
function AutoAssembler:LoadFile(fileName)
    local filePath = self:GetFilePath(fileName)
    if not filePath then
        logger:Error("[Auto-Assembler] Unable to resolve file path for '" .. fileName .. "'.")
        return nil, "Invalid file path"
    end
    local fileContent, err = customIO:ReadFromFile(filePath)
    if fileContent then
        logger:Info("[Auto-Assembler] Successfully loaded file '" .. fileName .. "' from '" .. filePath .. "'.")
        return fileContent
    end
    logger:Warning("[Auto-Assembler] Could not load local file '" .. fileName .. "'. Falling back to TableFiles.")
    fileContent, err = customIO:ReadFromTableFile(fileName)
    if not fileContent then
        logger:Warning("[Auto-Assembler] Failed to load file '" .. fileName .. "' from TableFiles: " .. (err or "Unknown error"))
        return nil, err
    end
    return fileContent
end
registerLuaFunctionHighlight('LoadFile')

--
--- ∑ Performs the auto-assembly process for a given file.
---   This function performs a series of assembly steps, checking the file and performing the assembly, while logging errors.
--- @param fileName string  # The name of the file to assemble.
--- @param fileStr string  # The content of the file to assemble.
--- @param targetSelf boolean  # Flag indicating whether the assembly is targeting the self process.
--- @param disableInfo table|nil  # Information on whether the process should be disabled.
--- @return boolean  # Returns 'true' if the assembly was successful, 'false' otherwise.
--
function AutoAssembler:PerformAutoAssemble(fileName, fileStr, targetSelf, disableInfo)
    logger:Debug("[Auto-Assembler] Performing Assembly for file '" .. fileName .. "'.")
    local assembled, err = autoAssembleCheck(fileStr, not disableInfo)
    if not assembled then
        local msg = "[Auto-Assembler] Assembly check failed for file '" .. fileName .. "': " .. (err or "Unknown Error")
        logger:Error(msg)
        if self.BreakOnError then
            error(msg)
        end
        return false
    end
    assembled, disableInfo = AutoAssemble(fileStr, targetSelf, disableInfo)
    if not assembled then
        -- logger:Error("[Auto-Assembler] Assembly failed for file '" .. fileName .. "'.")
        return false
    end
    local stateKey = self:GetStateKey(fileName)
    self.States[stateKey].DisableInfo = disableInfo
    self.States[stateKey].Active = disableInfo and true or false
    -- logger:Info("[Auto-Assembler] Assembly successful for file '" .. fileName .. "'.")
    return true
end

--
--- ∑ Logs the symbols and allocations for a given state.
---   This function logs the symbols and their corresponding addresses, as well as the allocation details like size, preferred address, and actual address.
--- @param state table  # The state containing the symbols and allocations to log.
--
function AutoAssembler:LogSymbolsAndAllocations(state)
    if state.DisableInfo then
        if state.DisableInfo.symbols then
            logger:Info("[Auto-Assembler] Symbols for: '" .. state.name .. "'")
            for symbol, address in pairs(state.DisableInfo.symbols) do
                logger:Info(string.format("[Auto-Assembler] [Symbol] %s -> [Address] 0x%X", symbol, address))
            end
        else
            logger:Warning("[Auto-Assembler] No symbols found in DisableInfo.")
        end
        if state.DisableInfo.allocs then
            logger:Info("[Auto-Assembler] Allocations for: '" .. state.name .. "'")
            for allocName, allocDetails in pairs(state.DisableInfo.allocs) do
                -- logger:Info(string.format("[Auto-Assembler] [Allocation] %s -> [Size] %d -> [Preferred Address] 0x%X -> [Actual Address] 0x%X", allocName, allocDetails.size, allocDetails.prefered, allocDetails.address))
            end
        else
            logger:Warning("[Auto-Assembler] No allocations found in DisableInfo.")
        end
    else
        logger:Warning("[Auto-Assembler] DisableInfo is missing in the current state.")
    end
end

--
--- ∑ Performs the entire auto-assembly process for a given file.
---   This function coordinates the validation, state update, file loading, and assembly steps.
--- @param fileName string  # The name of the file to auto-assemble.
--- @param memrecOrTargetSelf table|boolean  # Either the memory record to associate with the file or a flag indicating whether the assembly is targeting the self process.
--- @param targetSelf boolean  # Flag indicating whether the assembly is targeting the self process.
--- @return boolean  # Returns 'true' if the auto-assembly was successful, 'false' otherwise.
--
function AutoAssembler:AutoAssemble(fileName, memrecOrTargetSelf, targetSelf)
    local processName = processHandler:GetAttachedProcessName()
    if not processName or processName == "Unknown Process" then
        local msg = "[Auto-Assembler] No valid process attached. Auto-Assembly for '" .. fileName .. "' halted."
        logger:Error(msg)
        if self.BreakOnError then
            error(msg)
        end
        return false
    end
    if not self:ValidateProcess() then return false end
    logger:Info("[Auto-Assembler] Initiating Auto-Assembly for file '" .. fileName .. "'.")
    local memrec = (type(memrecOrTargetSelf) == "boolean") and nil or memrecOrTargetSelf
    targetSelf = (type(memrecOrTargetSelf) == "boolean") and memrecOrTargetSelf or targetSelf
    local fileStr, err = self:LoadFile(fileName)
    if not fileStr then
        local msg = "[Auto-Assembler] Unable to load file '" .. fileName .. "': " .. err
        logger:Error(msg)
        if self.BreakOnError then error(msg) end
        return false
    end
    local state = self:UpdateState(fileName, memrec, targetSelf)
    logger:Info("[Auto-Assembler] State updated for file '" .. fileName .. "'. Enabled: '" .. tostring(state.Active) .. "'.")
    if self:PerformAutoAssemble(fileName, fileStr, targetSelf, state.DisableInfo) then
        self:LogSymbolsAndAllocations(state)
        logger:Info("[Auto-Assembler] Auto-Assembly successfully completed for file '" .. fileName .. "'.")
        return true
    else
        local msg = "[Auto-Assembler] Auto-Assembly failed for file '" .. fileName .. "'."
        logger:Error(msg)
        if self.BreakOnError then error(msg) end
        return false
    end
end
registerLuaFunctionHighlight('AutoAssemble')

--
--- ∑ Sets the required process name for the auto-assembler.
--- This function allows the user to specify which process the auto-assembler should target.
--- @param processName string  # The name of the required process.
--
function AutoAssembler:SetProcessName(processName)
    if type(processName) ~= "string" then
        logger:Error("[Auto-Assembler] Invalid process name; expected a string, got '" .. type(processName) .. "'.")
    end
    logger:Info("[Auto-Assembler] Process name set to '" .. processName .. "'. Scripts will only be assembled if this process matches the target.")
    self.RequiredProcess = processName
end
registerLuaFunctionHighlight('SetProcessName')

local o_MainForm_OnProcessOpened = MainForm.OnProcessOpened

--
--- ∑ OnProcessOpened Override
--
function MainForm.OnProcessOpened()
    AutoAssembler.states = {}
    ProcessID = getOpenedProcessID()
	o_MainForm_OnProcessOpened()
end

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return AutoAssembler
