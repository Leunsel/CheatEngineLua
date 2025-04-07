local NAME = "Manifold.State.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Manifold Framework State"

--[[
    ∂ v1.0.0 (2025-03-24)
        Initial release with core functions.
]]--

State = {
    TableStateDir = nil
}
State.__index = State

function State:New()
    local instance = setmetatable({}, self)
    self:CheckDependencies()
    instance.Name = NAME or "Unnamed Module"
    instance.TableStateDir = State:EnsureStateDirectory()
    return instance
end
registerLuaFunctionHighlight('New')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table  {name, version, author, description}
--
function State:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

local HOTKEY_ACTIONS = {
    [0] = "mrhToggleActivation",
    [1] = "mrhToggleActivationAllowIncrease",
    [2] = "mrhToggleActivationAllowDecrease",
    [3] = "mrhActivate",
    [4] = "mrhDeactivate",
    [5] = "mrhSetValue",
    [6] = "mrhIncreaseValue",
    [7] = "mrhDecreaseValue"
}

local HOTKEY_ACTION_NUMBERS = {}
for num, name in pairs(HOTKEY_ACTIONS) do
    HOTKEY_ACTION_NUMBERS[name] = num
end

--
--- ∑ Checks if all required dependencies are loaded, and loads them if necessary.
--- @return void
--- @note This function checks for the existence of the 'json' and 'IO' dependencies,
---       and attempts to load them if not already present.
--
function State:CheckDependencies()
    local dependencies = {
        -- JSON is now handled by CustomIO
        -- { name = "json", path = "Manifold.Json",  init = function() json = JSON:new() end },
        { name = "logger", path = "Manifold.Logger",  init = function() logger = Logger:New() end },
        { name = "customIO", path = "Manifold.CustomIO", init = function() customIO = CustomIO:New() end },
        { name = "processHandler", path = "Manifold.ProcessHandler", init = function() processHandler = ProcessHandler:New() end}
    }
    for _, dep in ipairs(dependencies) do
        local depName = dep.name
        if _G[depName] == nil then
            logger:Warning("[State] '" .. depName .. "' dependency not found. Attempting to load...")
            local success, result = pcall(CETrequire, dep.path)
            if success then
                logger:Info("[State] Loaded dependency '" .. depName .. "'.")
                if dep.init then dep.init() end
            else
                logger:Error("[State] Failed to load dependency '" .. depName .. "': " .. result)
            end
        else
            logger:Debug("[State] Dependency '" .. depName .. "' is already loaded")
        end
    end  
end

--
--- ∑ Ensures that the Theme Directory exists within the Data Directory.
--- @return string|nil  The full path to the Theme Directory, or nil if creation failed.
--- @note First verifies that the DataDir exists. Then checks for the Theme Directory (DataDir\Themes) and creates it if necessary.
--
function State:EnsureStateDirectory()
    if not customIO:EnsureDataDirectory() then
        logger:Error("[State] Data Directory missing; cannot ensure State Directory.")
        return nil
    end
    local stateDir = customIO.DataDir .. "\\State"
    local exists, err = customIO:DirectoryExists(stateDir)
    if not exists and err then
        logger:Error("[State] Failed to check State Dir: " .. err)
        return nil
    end
    if not exists then
        logger:Warning("[State] State Dir missing; creating it...")
        local ok, err = customIO:CreateDirectory(stateDir)
        if not ok then
            logger:Error("[State] Create State Dir failed: " .. (err or "Unknown error"))
            return nil
        end
        logger:Info("[State] State Dir created.")
    end
    return stateDir
end
registerLuaFunctionHighlight('EnsureStateDirectory')

--
--- ∑ Retrieves a sorted list of indexed memory records.
--- @return table  # A table containing indexed memory records.
--
function State:GetIndexedAddressList()
    if not AddressList then
        logger:Error("[State] AddressList is nil!")
        return nil
    end
    local indexedList = {}
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr then
            local hotkeys = {}
            if mr.HotkeyCount and mr.HotkeyCount > 0 then
                for hkIndex = 0, mr.HotkeyCount - 1 do
                    local hotkey = mr.getHotkey(hkIndex)
                    if hotkey then
                        table.insert(hotkeys, {
                            keys = hotkey.Keys,
                            action = HOTKEY_ACTION_NUMBERS[hotkey.Action] or 0,
                            description = hotkey.Description,
                            value = hotkey.Value
                        })
                    end
                end
            end
            table.insert(indexedList, {
                index = i,
                id = mr.ID,
                description = mr.Description,
                active = mr.Active,
                type = (mr.Type == vtAutoAssembler and "ScriptID") 
                    or (mr.IsGroupHeader and "HeaderID") 
                    or "MemoryRecord",
                HotkeyCount = mr.HotkeyCount,
                Hotkeys = hotkeys
            })
        end
    end
    table.sort(indexedList, function(a, b) return a.index < b.index end)
    local keyedList = {}
    for _, entry in ipairs(indexedList) do
        if entry.id then
            keyedList[entry.id] = entry
        end
    end
    return indexedList, keyedList
end
registerLuaFunctionHighlight('GetIndexedAddressList')

--
--- ∑ Retrieves the current process name.
--- @return string  # The current process name.
--- @throws error if the process is nil.
--
function State:GetProcessName()
    if not process then
        logger:Error("[State] Process is nil!")
        return nil
    end
    logger:Info("[State] Process: " .. process)
    return process
end

--
--- ∑ Retrieves the full file path for a state file based on the state name.
--- @param stateName string  # The name of the state.
--- @return string|nil  # The full file path to the state file, or nil if the path cannot be determined.
--- @note The file path is constructed using the process name and the state name.
--
function State:GetStateFilePath(stateName)
    if not stateName or stateName == "" then
        logger:Error("[State] Invalid state name!")
        return nil
    end
    local stateDir = self:EnsureStateDirectory()
    if not stateDir then
        return nil
    end
    procName = customIO:StripExt(processHandler:GetAttachedProcessName())
    local fileName = "Manifold." .. stateName .. "." .. procName .. ".State"
    local fullPath = stateDir .. "\\" .. fileName
    logger:Debug("[State] File path: " .. fullPath)
    return fullPath
end
registerLuaFunctionHighlight('GetStateFilePath')

--
--- ∑ Saves the current state of the memory records to a state file.
--- @param stateName string  # The name of the state to save.
--- @return boolean  # Returns true if the state was successfully saved, otherwise false.
--- @note This function retrieves the active memory records and writes them to the state file.
--
function State:SaveTableState(stateName)
    if not stateName or stateName == "" then
        logger:Error("[State] Invalid state name!")
        return false
    end
    local stateData = {}
    local indexedList, keyedList = self:GetIndexedAddressList()
    for _, rec in ipairs(indexedList) do
        if rec.active or (rec.HotkeyCount and rec.HotkeyCount > 0) then
            local recordData = {
                index = rec.index,
                id = rec.id,
                description = rec.description,
                type = rec.type,
                active = rec.active,
                hotkeys = {}
            }
            if rec.Hotkeys and #rec.Hotkeys > 0 then
                for _, hotkey in ipairs(rec.Hotkeys) do
                    table.insert(recordData.hotkeys, {
                        keys = hotkey.keys,
                        action = hotkey.action,
                        description = hotkey.description,
                        value = hotkey.value
                    })
                end
            end
            if #recordData.hotkeys > 0 or rec.active then
                table.insert(stateData, recordData)
            end
        end
    end
    if #stateData == 0 then
        logger:Warning("[State] No active records to save.")
        return false
    end
    logger:Info("[State] " .. #stateData .. " records to save.")
    local procName = processHandler:GetAttachedProcessName()
    if not procName then
        logger:Error("[State] No process attached. Cannot save state '" .. stateName .. "'.")
        return false
    end
    local filePath = self:GetStateFilePath(stateName)
    if not filePath then
        return false
    end
    local ok = self:WriteStateFile(filePath, stateData)
    if ok then
        logger:Info("[State] State saved to '" .. filePath .. "'.")
    end
    return ok
end
registerLuaFunctionHighlight('SaveTableState')

--
--- ∑ Creates lookup tables for faster access by ID and description.
--- @return table  # Returns the indexed list of memory records.
--- @return table  # Returns a map of memory records by their ID.
--- @return table  # Returns a map of memory records by their description.
--
function State:CreateLookupTables()
    local indexedList = self:GetIndexedAddressList()
    local idMap, descMap = {}, {}
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr then
            idMap[mr.ID] = mr
            descMap[mr.Description] = mr
        end
    end
    return indexedList, idMap, descMap
end

--
--- ∑ ...
--
function State:SetMemoryRecordState(mr, state)
    if mr.Active == state then
        return true -- No need to change state
    end
    mr.Active = state
    MainForm.repaint()
    while mr.Async and mr.AsyncProcessing do
        MainForm.repaint()
        sleep(5)
    end
    if mr.Active == state then
        logger:Info(string.format("[State] Memory Record ID=%s successfully %s.",
            tostring(mr.ID), state and "activated" or "deactivated"))
        return true
    else
        logger:Warning(string.format("[State] Memory Record ID=%s failed to %s.",
            tostring(mr.ID), state and "activate" or "deactivate"))
        return false
    end
end

--
--- ∑ Restores the state of memory records based on the state file.
--- Only the records listed in the state file will be activated; all others will be deactivated.
--- @param stateData table  # The list of state data to restore.
--- @return void  # This function does not return a value.
--
function State:RestoreState(stateData)
    if not (AddressList and stateData) then
        logger:Error("[State] AddressList or stateData is not available.")
        return { activatedCount = 0, deactivatedCount = 0, unchangedCount = 0, failedCount = 0 }
    end
    local stateLookup = {}
    for _, rec in ipairs(stateData) do
        stateLookup[rec.id] = rec
    end
    local stats = { activatedCount = 0, deactivatedCount = 0, unchangedCount = 0, failedCount = 0 }
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr then
            local rec = stateLookup[mr.ID]
            local targetState = rec and rec.active or false
            if mr.Active == targetState then
                stats.unchangedCount = stats.unchangedCount + 1
                logger:Info(string.format("[State] Unchanged Memory Record ID=%s (Description='%s').",
                    tostring(mr.ID), tostring(mr.Description)))
            else
                if self:SetMemoryRecordState(mr, targetState) then
                    if targetState then
                        stats.activatedCount = stats.activatedCount + 1
                    else
                        stats.deactivatedCount = stats.deactivatedCount + 1
                    end
                    logger:Info(string.format("[State] %s Memory Record ID=%s (Description='%s').",
                        targetState and "Activated" or "Deactivated",
                        tostring(mr.ID), tostring(mr.Description)))
                else
                    stats.failedCount = stats.failedCount + 1
                    logger:Warning(string.format("[State] Failed to %s Memory Record ID=%s (Description='%s').",
                        targetState and "activate" or "deactivate",
                        tostring(mr.ID), tostring(mr.Description)))
                end
            end
            if rec and rec.hotkeys and #rec.hotkeys > 0 then
                for hotkeyIndex = mr.HotkeyCount - 1, 0, -1 do
                    mr.Hotkey[hotkeyIndex].destroy()
                end
                for _, hotkeyData in ipairs(rec.hotkeys) do
                    logger:Info("[State] " .. logger:Stringify(rec.hotkeys))
                    local hk = mr.createHotkey(hotkeyData.keys, hotkeyData.action, hotkeyData.value, hotkeyData.description)
                end
                logger:Info(string.format("[State] Restored %d hotkeys for Memory Record ID=%s (Description='%s').",
                    #rec.hotkeys, tostring(mr.ID), tostring(mr.Description)))
            end
        end
    end
    return stats
end

--
--- ∑ Loads the state of memory records from a state file.
--- @param stateName string  # The name of the state to load.
--- @return boolean  # Returns true if the state was successfully loaded, otherwise false.
--
function State:LoadTableState(stateName)
    if not stateName or stateName == "" then
        logger:Error("[State] Invalid state name!")
        return false
    end
    local procName = processHandler:GetAttachedProcessName()
    if not procName then
        logger:Error("[State] No process attached. Cannot load state '" .. stateName .. "'.")
        return false
    end
    local filePath = self:GetStateFilePath(stateName)
    if not filePath then
        logger:Error("[State] State file path not resolved.")
        return false
    end
    local stateData = self:ReadStateFile(filePath)
    if not stateData then
        logger:Error("[State] Failed to read state file.")
        return false
    end
    local stats = self:RestoreState(stateData)
    logger:Info(string.format(
        "[State] State '%s' loaded. Activated: %d, Deactivated: %d, Unchanged: %d, Failed: %d",
        stateName, stats.activatedCount, stats.deactivatedCount, stats.unchangedCount, stats.failedCount
    ))
    return true
end
registerLuaFunctionHighlight('LoadTableState')

--
--- ∑ Restores all memory records to their original inactive state.
--- This function deactivates all memory records by iterating through the entire 'AddressList'. 
--- If a record is active, it will be deactivated. 
--- If deactivation fails, a warning will be logged.
--- @return void  # This function does not return a value.
--
function State:RestoreOriginalState()
    if not AddressList then
        logger:Error("[State] AddressList is not available.")
        return { deactivatedCount = 0, unchangedCount = 0, failedCount = 0 }
    end
    local stats = { deactivatedCount = 0, unchangedCount = 0, failedCount = 0 }
    for i = AddressList.Count - 1, 0, -1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr then
            if mr.Active then
                if self:SetMemoryRecordState(mr, false) then
                    stats.deactivatedCount = stats.deactivatedCount + 1
                    logger:Info(string.format("[State] Memory Record ID=%s has been successfully deactivated.",
                        tostring(mr.ID)))
                else
                    stats.failedCount = stats.failedCount + 1
                    logger:Warning(string.format("[State] Memory Record ID=%s failed to deactivate properly.",
                        tostring(mr.ID)))
                end
            else
                stats.unchangedCount = stats.unchangedCount + 1
                logger:Info(string.format("[State] Memory Record ID=%s was already deactivated.",
                    tostring(mr.ID)))
            end
        end
    end
    logger:Info(string.format(
        "[State] RestoreOriginalState completed. Deactivated: %d, Unchanged: %d, Failed: %d",
        stats.deactivatedCount, stats.unchangedCount, stats.failedCount
    ))
    return stats
end
registerLuaFunctionHighlight('RestoreOriginalState')

--
--- ∑ Writes the state data to a file.
--- @param path string  # The path to the file where the state will be written.
--- @param data table  # The data to be written to the file.
--- @return boolean  # Returns true if the data was successfully written, otherwise false.
--- @note This function calls the WriteToFileAsJson function to write the state data as JSON.
--
function State:WriteStateFile(path, data)
    if not path or path == "" then
        logger:Error("[State] Invalid file path!")
        return false
    end
    if not data or type(data) ~= "table" then
        logger:Error("[State] Invalid data provided!")
        return false
    end
    logger:Debug("[State] Writing state file...")
    local ok, err = customIO:WriteToFileAsJson(path, data)
    if not ok then
        logger:Error("[State] Write failed: " .. (err or "Unknown error"))
        return false
    end
    logger:Info("[State] State written to file.")
    return true
end
registerLuaFunctionHighlight('WriteStateFile')

--
--- ∑ Reads the state data from a file.
--- @param path string  # The path to the file to read.
--- @return table|nil  # Returns the state data if successful, otherwise nil.
--- @note This function calls the ReadFromFileAsJson function to read the state data from a JSON file.
--
function State:ReadStateFile(path)
    if not path or path == "" then
        logger:Error("[State] Invalid file path!")
        return nil
    end
    logger:Debug("[State] Reading state file: " .. path)
    local data, err = customIO:ReadFromFileAsJson(path)
    if not data then
        logger:Error("[State] Read failed: " .. (err or "Unknown error"))
        return nil
    end
    logger:Info("[State] State loaded from file.")
    return data
end
registerLuaFunctionHighlight('ReadStateFile')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return State
