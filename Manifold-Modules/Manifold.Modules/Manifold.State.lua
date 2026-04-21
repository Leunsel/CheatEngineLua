local NAME = "Manifold.State.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.4"
local DESCRIPTION = "Manifold Framework State"

--[[
    ∂ v1.0.0 (2025-03-24)
        Initial release with core functions.

    ∂ v1.0.1 (2025-04-16)
        Minor comment adjustments.

    ∂ v1.0.2 (2025-12-27)
        Some minor adjustments to state restoration logic. - LeFiXER
    
    ∂ v1.0.3 (2024-06-12)
        Improved async memory record handling during state restoration. - Leunsel

    ∂ v1.0.4 (2026-04-21)
        Reduced duplicated state serialization and validation logic.
        Simplified restore/save flows and trimmed low-value debug logging.
]]--

State = {
    TableStateDir = nil
}
State.__index = State

local MODULE_PREFIX = "[State]"

function State:New()
    local instance = setmetatable({}, self)
    self:CheckDependencies()
    instance.Name = NAME or "Unnamed Module"
    instance.TableStateDir = self:EnsureStateDirectory()
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

--
--- ∑ Prints module details in a readable formatted block.
--
function State:PrintModuleInfo()
    local info = self:GetModuleInfo()
    if not info then
        logger:Info(MODULE_PREFIX .. " Failed to retrieve module info.")
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

local function _isValidString(value)
    return type(value) == "string" and value ~= ""
end

local function _describeRecord(mr)
    if not mr then
        return "Unknown Record"
    end
    return string.format("ID=%s (Description='%s')", tostring(mr.ID), tostring(mr.Description))
end

local function _serializeHotkeys(mr)
    local hotkeys = {}
    if not (mr and mr.HotkeyCount and mr.HotkeyCount > 0) then
        return hotkeys
    end
    for hkIndex = 0, mr.HotkeyCount - 1 do
        local hotkey = mr.getHotkey(hkIndex)
        if hotkey then
            hotkeys[#hotkeys + 1] = {
                keys = hotkey.Keys,
                action = HOTKEY_ACTION_NUMBERS[hotkey.Action] or 0,
                description = hotkey.Description,
                value = hotkey.Value
            }
        end
    end
    return hotkeys
end

--
--- ∑ Checks if all required dependencies are loaded, and loads them if necessary.
--- @return void
--- @note This function checks for the existence of the 'json' and 'IO' dependencies,
---       and attempts to load them if not already present.
--
function State:CheckDependencies()
    local dependencies = {
        { name = "logger", path = "Manifold.Logger",  init = function() logger = Logger:New() end },
        { name = "customIO", path = "Manifold.CustomIO", init = function() customIO = CustomIO:New() end },
        { name = "processHandler", path = "Manifold.ProcessHandler", init = function() processHandler = ProcessHandler:New() end}
    }
    for _, dep in ipairs(dependencies) do
        if _G[dep.name] == nil then
            logger:Warning(MODULE_PREFIX .. " '" .. dep.name .. "' dependency not found. Attempting to load...")
            local success, result = pcall(CETrequire, dep.path)
            if success then
                if dep.init then dep.init() end
                logger:Info(MODULE_PREFIX .. " Loaded dependency '" .. dep.name .. "'.")
            else
                logger:Error(MODULE_PREFIX .. " Failed to load dependency '" .. dep.name .. "': " .. tostring(result))
            end
        end
    end  
end
registerLuaFunctionHighlight('CheckDependencies')

--
--- ∑ Ensures that the State Directory exists within the Data Directory.
--- @return string|nil  The full path to the State Directory, or nil if creation failed.
--- @note First verifies that the DataDir exists. Then checks for the State Directory (DataDir\State) and creates it if necessary.
--
function State:EnsureStateDirectory()
    if not customIO:EnsureDataDirectory() then
        logger:Error(MODULE_PREFIX .. " Data Directory missing; cannot ensure State Directory.")
        return nil
    end
    local stateDir = customIO.DataDir .. "\\State"
    if not customIO:DirectoryExists(stateDir) then
        logger:Warning(MODULE_PREFIX .. " State Dir missing; creating it...")
        local ok, err = customIO:CreateDirectory(stateDir)
        if not ok then
            logger:Error(MODULE_PREFIX .. " Create State Dir failed: " .. (err or "Unknown error"))
            return nil
        end
        logger:Info(MODULE_PREFIX .. " State Dir created.")
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
        logger:Error(MODULE_PREFIX .. " AddressList is nil!")
        return nil
    end
    local indexedList = {}
    for i = 0, AddressList.Count - 1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr then
            indexedList[#indexedList + 1] = {
                index = i,
                id = mr.ID,
                description = mr.Description,
                active = mr.Active,
                type = (mr.Type == vtAutoAssembler and "ScriptID") 
                    or (mr.IsGroupHeader and "HeaderID") 
                    or "MemoryRecord",
                HotkeyCount = mr.HotkeyCount,
                Hotkeys = _serializeHotkeys(mr)
            }
        end
    end
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
--- ∑ Retrieves the full file path for a state file based on the state name.
--- @param stateName string  # The name of the state.
--- @return string|nil  # The full file path to the state file, or nil if the path cannot be determined.
--- @note The file path is constructed using the process name and the state name.
--
function State:GetStateFilePath(stateName)
    if not _isValidString(stateName) then
        logger:Error(MODULE_PREFIX .. " Invalid state name!")
        return nil
    end
    local stateDir = self.TableStateDir or self:EnsureStateDirectory()
    if not stateDir then
        return nil
    end
    local procName = customIO:StripExt(processHandler:GetAttachedProcessName())
    local fileName = "Manifold." .. stateName .. "." .. procName .. ".State"
    return stateDir .. "\\" .. fileName
end
registerLuaFunctionHighlight('GetStateFilePath')

--
--- ∑ Builds a compact state entry for an active record or record with hotkeys.
--- @param rec table
--- @return table|nil
--
function State:_BuildStateRecord(rec)
    local hotkeys = rec.Hotkeys or {}
    if not rec.active and #hotkeys == 0 then
        return nil
    end
    return {
        index = rec.index,
        id = rec.id,
        description = rec.description,
        type = rec.type,
        active = rec.active,
        hotkeys = hotkeys
    }
end
registerLuaFunctionHighlight('_BuildStateRecord')

--
--- ∑ Saves the current state of the memory records to a state file.
--- @param stateName string  # The name of the state to save.
--- @return boolean  # Returns true if the state was successfully saved, otherwise false.
--- @note This function retrieves the active memory records and writes them to the state file.
--
function State:SaveTableState(stateName)
    if not _isValidString(stateName) then
        logger:Error(MODULE_PREFIX .. " Invalid state name!")
        return false
    end
    local stateData = {}
    local indexedList = self:GetIndexedAddressList()
    for _, rec in ipairs(indexedList) do
        local recordData = self:_BuildStateRecord(rec)
        if recordData then
            stateData[#stateData + 1] = recordData
        end
    end
    if #stateData == 0 then
        logger:Warning(MODULE_PREFIX .. " No active records to save.")
        return false
    end
    local procName = processHandler:GetAttachedProcessName()
    if not procName then
        logger:Error(MODULE_PREFIX .. " No process attached. Cannot save state '" .. stateName .. "'.")
        return false
    end
    local filePath = self:GetStateFilePath(stateName)
    if not filePath then
        return false
    end
    local ok = self:WriteStateFile(filePath, stateData)
    if ok then
        logger:Info(string.format("%s State '%s' saved with %d records.", MODULE_PREFIX, stateName, #stateData))
    end
    return ok
end
registerLuaFunctionHighlight('SaveTableState')

--
--- ∑ Runs a function on CE's main thread (GUI thread) to safely touch MemoryRecords/Hotkeys.
--- @param fn function
--
function State:_RunOnMainThread(fn)
    if type(fn) ~= "function" then return end

    -- Cheat Engine provides 'synchronize' to execute code on the main thread.
    if type(synchronize) == "function" then
        synchronize(fn)
    else
        -- Fallback: if not available, execute directly.
        -- (In standard CE Lua, synchronize exists.)
        fn()
    end
end

--
--- ∑ Sets the active state of a memory record (direct) on the main thread.
--- If the record is async, waits for completion up to timeoutMs (no infinite wait).
--- @param mr MemoryRecord The memory record to modify.
--- @param state boolean The desired active state (true to activate, false to deactivate).
--- @param timeoutMs number|nil Max wait time for async processing in milliseconds (default: 2000).
--- @return boolean # Returns true if the state was set, false otherwise.
--
function State:SetMemoryRecordState(mr, state, timeoutMs)
    if not mr then
        logger:Warning(MODULE_PREFIX .. " SetMemoryRecordState called with nil mr.")
        return false
    end
    if mr.Active == state then
        return true
    end
    timeoutMs = tonumber(timeoutMs) or 10000
    local didTimeout = false
    local waitedMs = 0
    local asyncWasProcessing = false
    local id = tostring(mr.ID)
    local desc = tostring(mr.Description)
    self:_RunOnMainThread(function()
        -- Apply state immediately
        mr.Active = state
        if type(processMessages) == "function" then processMessages() end
        if MainForm and type(MainForm.repaint) == "function" then MainForm.repaint() end
        -- If async, wait (bounded) until processing finishes
        if mr.Async then
            asyncWasProcessing = true
            local startMs = (type(getTickCount) == "function")
                and getTickCount()
                or math.floor(os.clock() * 1000)
            while mr.AsyncProcessing do
                if type(processMessages) == "function" then processMessages() end
                if MainForm and type(MainForm.repaint) == "function" then MainForm.repaint() end
                if type(sleep) == "function" then sleep(10) end
                local nowMs = (type(getTickCount) == "function")
                    and getTickCount()
                    or math.floor(os.clock() * 1000)
                waitedMs = nowMs - startMs
                if waitedMs >= timeoutMs then
                    didTimeout = true
                    break
                end
            end
            if waitedMs == 0 then
                local endMs = (type(getTickCount) == "function")
                    and getTickCount()
                    or math.floor(os.clock() * 1000)
                waitedMs = endMs - startMs
            end
        end
    end)
    if mr.Active ~= state then
        logger:Warning(string.format("%s Failed to set %s. Active=%s Async=%s AsyncProcessing=%s", MODULE_PREFIX, _describeRecord(mr), tostring(mr.Active), tostring(mr.Async), tostring(mr.AsyncProcessing)))
        return false
    end
    if asyncWasProcessing then
        if didTimeout then
            logger:Warning(string.format("%s %s timed out after %dms. AsyncProcessing=%s", MODULE_PREFIX, _describeRecord(mr), waitedMs, tostring(mr.AsyncProcessing)))
        else
            logger:Info(string.format("%s %s %s. Async completed in %dms.", MODULE_PREFIX, _describeRecord(mr), state and "activated" or "deactivated", waitedMs))
        end
    else
        logger:Info(string.format("%s %s %s.", MODULE_PREFIX, _describeRecord(mr), state and "activated" or "deactivated"))
    end
    return true
end
registerLuaFunctionHighlight('SetMemoryRecordState')

--
--- ∑ Restores the state of memory records based on the state file.
--- Only the records listed in the state file will be activated; all others will be deactivated.
--- @param stateData table  # The list of state data to restore.
--- @return void  # This function does not return a value.
--
function State:RestoreState(stateData)
    if not (AddressList and stateData) then
        logger:Error(MODULE_PREFIX .. " AddressList or stateData is not available.")
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
            else
                if self:SetMemoryRecordState(mr, targetState) then
                    if targetState then
                        stats.activatedCount = stats.activatedCount + 1
                    else
                        stats.deactivatedCount = stats.deactivatedCount + 1
                    end
                else
                    stats.failedCount = stats.failedCount + 1
                end
            end
            if rec and rec.hotkeys and #rec.hotkeys > 0 then
                self:_RunOnMainThread(function()
                    for hotkeyIndex = mr.HotkeyCount - 1, 0, -1 do
                        mr.Hotkey[hotkeyIndex].destroy()
                    end
                    for _, hotkeyData in ipairs(rec.hotkeys) do
                        local hk = mr.createHotkey(
                            hotkeyData.keys,
                            hotkeyData.action,
                            hotkeyData.value,
                            hotkeyData.description)
                    end
                    if type(processMessages) == "function" then processMessages() end
                    if MainForm and type(MainForm.repaint) == "function" then MainForm.repaint() end
                end)
                logger:Info(string.format("%s Restored %d hotkeys for %s.", MODULE_PREFIX, #rec.hotkeys, _describeRecord(mr)))
            end
        end
    end
    logger:Info(string.format("%s Restore complete. Activated: %d, Deactivated: %d, Unchanged: %d, Failed: %d", MODULE_PREFIX, stats.activatedCount, stats.deactivatedCount, stats.unchangedCount, stats.failedCount))
    return stats
end
registerLuaFunctionHighlight('RestoreState')

--
--- ∑ Loads the state of memory records from a state file.
--- @param stateName string  # The name of the state to load.
--- @return boolean  # Returns true if the state was successfully loaded, otherwise false.
--
function State:LoadTableState(stateName)
    if not _isValidString(stateName) then
        logger:Error(MODULE_PREFIX .. " Invalid state name!")
        return false
    end
    local procName = processHandler:GetAttachedProcessName()
    if not procName then
        logger:Error(MODULE_PREFIX .. " No process attached. Cannot load state '" .. stateName .. "'.")
        return false
    end
    local filePath = self:GetStateFilePath(stateName)
    if not filePath then
        logger:Error(MODULE_PREFIX .. " State file path not resolved.")
        return false
    end
    local stateData = self:ReadStateFile(filePath)
    if not stateData then
        logger:Error(MODULE_PREFIX .. " Failed to read state file.")
        return false
    end
    self:RestoreState(stateData)
    logger:Info(string.format("%s State '%s' loaded.", MODULE_PREFIX, stateName))
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
        logger:Error(MODULE_PREFIX .. " AddressList is not available.")
        return { deactivatedCount = 0, unchangedCount = 0, failedCount = 0 }
    end
    local stats = { deactivatedCount = 0, unchangedCount = 0, failedCount = 0 }
    for i = AddressList.Count - 1, 0, -1 do
        local mr = AddressList.getMemoryRecord(i)
        if mr then
            if mr.Active then
                if self:SetMemoryRecordState(mr, false) then
                    stats.deactivatedCount = stats.deactivatedCount + 1
                else
                    stats.failedCount = stats.failedCount + 1
                end
            else
                stats.unchangedCount = stats.unchangedCount + 1
            end
        end
    end
    logger:Info(string.format("%s RestoreOriginalState completed. Deactivated: %d, Unchanged: %d, Failed: %d", MODULE_PREFIX, stats.deactivatedCount, stats.unchangedCount, stats.failedCount))
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
    if not _isValidString(path) then
        logger:Error(MODULE_PREFIX .. " Invalid file path!")
        return false
    end
    if not data or type(data) ~= "table" then
        logger:Error(MODULE_PREFIX .. " Invalid data provided!")
        return false
    end
    local ok, err = customIO:WriteToFileAsJson(path, data)
    if not ok then
        logger:Error(MODULE_PREFIX .. " Write failed: " .. (err or "Unknown error"))
        return false
    end
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
    if not _isValidString(path) then
        logger:Error(MODULE_PREFIX .. " Invalid file path!")
        return nil
    end
    local data, err = customIO:ReadFromFileAsJson(path)
    if not data then
        logger:Error(MODULE_PREFIX .. " Read failed: " .. (err or "Unknown error"))
        return nil
    end
    return data
end
registerLuaFunctionHighlight('ReadStateFile')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return State