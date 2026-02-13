local NAME = "Manifold.AutoAssembler.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "2.0.1"
local DESCRIPTION = "Manifold Framework Auto-Assembler"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.
    
    ∂ v1.0.1 (2025-07-06)
        Fixed a typo in the MainForm.OnProcessOpened Override which prevented the States from being reset correctly.

    ∂ v2.0.0 (2026-02-12)
        Refactored the entire module to improve maintainability and extensibility.
        Added detailed logging for better debugging and user feedback.
        Implemented a transactional system to allow rolling back changes if a script fails.
        Improved error handling to provide clearer messages and prevent partial application of scripts.

    ∂ v2.0.1 (2026-02-13)
        Fixed a minor inconvenience that caused a forced log message about resetting after a process change, though not
        necessary.
]]--

AutoAssembler = {
    States = {},
    RequiredProcess = "",
    LocalFilesFolder = "CEA",
    FileExtension = ".CEA",
    BreakOnError = true,
    _instance = nil,
    _lastKnownPid = nil,
    _txDepth = 0,
    _txStack = nil,
    _processChangedMsg = nil,
}
AutoAssembler.__index = AutoAssembler

--
--- ∑ Ensures all required modules are loaded and ready to use.
---   This function tries to load missing dependencies via CETrequire and initializes them if needed.
--- @return nil
--
function AutoAssembler:CheckDependencies()
    local dependencies = {
        { name = "json", path = "Manifold.Json", init = function() json = JSON:new() end },
        { name = "logger", path = "Manifold.Logger", init = function() logger = Logger:New() end },
        { name = "customIO", path = "Manifold.CustomIO", init = function() customIO = CustomIO:New() end },
        { name = "processHandler", path = "Manifold.ProcessHandler", init = function() processHandler = ProcessHandler:New() end },
    }
    for _, dep in ipairs(dependencies) do
        local depName = dep.name
        if _G[depName] == nil then
            if _G.logger then
                logger:Warning("[Auto-Assembler] Missing dependency '" .. depName .. "'. Trying to load it now...")
            end
            local ok, err = pcall(CETrequire, dep.path)
            if ok then
                if _G.logger then
                    logger:Info("[Auto-Assembler] Dependency '" .. depName .. "' loaded successfully.")
                end
                if dep.init then
                    dep.init()
                end
            else
                if _G.logger then
                    logger:Error("[Auto-Assembler] Could not load '" .. depName .. "'. Reason: " .. tostring(err))
                end
            end
        else
            if _G.logger then
                logger:Debug("[Auto-Assembler] Dependency '" .. depName .. "' is already available.")
            end
        end
    end
end

--
--- ∑ ...
--
function AutoAssembler:New()
    local instance = setmetatable({}, self)
    instance:CheckDependencies()
    instance.Name = NAME or "Unnamed Module"
    instance.States = {}
    instance._txDepth = 0
    instance._txStack = nil
    instance._lastKnownPid = getOpenedProcessID()
    return instance
end

--
--- ∑ Returns the singleton AutoAssembler instance.
---   If the instance does not exist yet, it will be created.
--- @return table # Returns the singleton AutoAssembler instance.
--
function AutoAssembler:GetInstance()
    if not self._instance then
        self._instance = self:New()
    end
    return self._instance
end

function _isString(v) return type(v) == "string" end
function _trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--
--- ∑ Returns module metadata.
---   This includes name, version, author, and description.
--- @return table # Returns a metadata table.
--
function AutoAssembler:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end

--
--- ∑ Sets the expected process name for this table.
---   If a different process is attached, the Auto-Assembler will refuse to run scripts.
--- @param processName string # The expected process name.
--- @return nil
--
function AutoAssembler:SetProcessName(processName)
    if type(processName) ~= "string" then
        logger:Error("[Auto-Assembler] Process name must be a text value.")
        return
    end
    self.RequiredProcess = processName
    logger:Info("[Auto-Assembler] This table is configured for: " .. processName)
end

--
--- ∑ Retrieves the currently opened process id from Cheat Engine.
---   This is used to detect process changes.
--- @return number|nil # Returns the process id or nil if it cannot be read.
--
function AutoAssembler:_currentPid()
    local ok, pid = pcall(getOpenedProcessID)
    if ok then
        return pid
    end
    return nil
end

--
--- ∑ Validates that a process is attached and matches the required process name.
---   This function throws an error if the process is missing or wrong.
--- @return nil
--
function AutoAssembler:_validateProcessOrThrow()
    if not processHandler or not processHandler.IsProcessAttached then
        error("[Auto-Assembler] Internal error: Process handler is not available.", 3)
    end
    if not processHandler:IsProcessAttached() then
        error("[Auto-Assembler] No process is attached. Please attach to the game first.", 3)
    end
    local attachedProcess = processHandler:GetAttachedProcessName()
    if self.RequiredProcess and self.RequiredProcess ~= "" and attachedProcess ~= self.RequiredProcess then
        error("[Auto-Assembler] Wrong process attached. Expected: " ..
            self.RequiredProcess ..
            " | Current: " ..
            tostring(attachedProcess), 3)
    end
end

--
--- ∑ Resets the Auto-Assembler state completely.
---   This is used after a process change to ensure the Auto-Assembler starts fresh.
--- @param reason string|nil # A human-friendly reason that will be logged.
--- @return nil
--
function AutoAssembler:Reset(reason)
    self.States = {}
    self._txDepth = 0
    self._txStack = nil
    if reason and reason ~= "" then
        logger:Info("[Auto-Assembler] Reset completed. Reason: " .. reason)
    else 
        logger:Info("[Auto-Assembler] Reset completed.")
    end
end

--
--- ∑ Disables all records without executing their [DISABLE] sections.
---   This is used after a process change to avoid running old disable logic in a new process.
--- @return boolean # Returns 'true' if the call succeeded, otherwise 'false'.
--
function AutoAssembler:DisableAllWithoutExecute()
    if not AddressList or not AddressList.disableAllWithoutExecute then
        logger:Warning("[Auto-Assembler] Could not disable records safely (AddressList.disableAllWithoutExecute is not available).")
        return false
    end
    local ok, err = pcall(function()
        AddressList.disableAllWithoutExecute()
        deleteAllRegisteredSymbols()
    end)
    if ok then
        logger:Info("[Auto-Assembler] All table records were disabled safely (without executing disable scripts).")
        return true
    end
    logger:Error("[Auto-Assembler] Failed to disable records safely. Reason: " .. tostring(err))
    return false
end

--
--- ∑ Handles a detected process change and aborts execution.
---   This function safely disables records without executing disable scripts, resets internal state, and throws an error.
--- @param oldPid number # Previous process id.
--- @param newPid number # Current process id.
--- @return nil
--
function AutoAssembler:_markProcessChangedAndThrow(oldPid, newPid)
    local msg = "[Auto-Assembler] The game session changed. To prevent broken hooks, everything was reset. Please run the script again."
    self._processChangedMsg = msg
    logger:Info("[Auto-Assembler] A new game session was detected. Resetting to keep everything safe...")
    self:DisableAllWithoutExecute()
    self:Reset("Game session changed")
    -- error(msg, 3)
end

--
--- ∑ Checks if the attached process id changed since the last run.
---   If it changed, the Auto-Assembler will reset and abort.
--- @return nil
--
function AutoAssembler:_checkProcessChangedOrThrow()
    local pid = self:_currentPid()
    if pid == nil then
        logger:Warning("[Auto-Assembler] Could not read the current process id. Continuing anyway.")
        return
    end
    if self._lastKnownPid == nil then
        self._lastKnownPid = pid
        return
    end
    if pid ~= self._lastKnownPid then
        local oldPid = self._lastKnownPid
        self._lastKnownPid = pid
        self:_markProcessChangedAndThrow(oldPid, pid)
    end
end

--
--- ∑ Ensures the necessary directories exist for storing files.
---   This function checks and creates directories for the data and process-specific directories if needed.
--- @return boolean # Returns 'true' if all directories are successfully created, otherwise 'false'.
--
function AutoAssembler:EnsureDirectoriesExist()
    if not customIO or not customIO.EnsureDataDirectory then
        logger:Error("[Auto-Assembler] File system support is not available (customIO missing).")
        return false
    end
    if not customIO:EnsureDataDirectory() then
        logger:Error("[Auto-Assembler] Could not prepare the base data folder.")
        return false
    end
    local ceaDir = string.format("%s/%s", customIO.DataDir, self.LocalFilesFolder)
    if not customIO:EnsureDirectoryExists(ceaDir) then
        logger:Error("[Auto-Assembler] Could not prepare the CEA folder: " .. ceaDir)
        return false
    end
    local processName = processHandler and processHandler:GetAttachedProcessName() or nil
    if not processName then
        logger:Error("[Auto-Assembler] No process attached. Cannot prepare process-specific CEA folder.")
        return false
    end
    local processDir = string.format("%s/%s", ceaDir, extractFileNameWithoutExt(processName))
    if not customIO:EnsureDirectoryExists(processDir) then
        logger:Error("[Auto-Assembler] Could not prepare the process-specific folder: " .. processDir)
        return false
    end
    return true
end

--
--- ∑ Formats the file name by ensuring the correct extension is appended.
---   If the file name already has the correct extension, it returns the file name unchanged.
--- @param name string # The name of the file to be formatted.
--- @return string # Returns the formatted file name with the correct extension.
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
--- @param fileName string # The name of the file to get the full path for.
--- @return string|nil # Returns the full file path, or 'nil' if there is an error.
--
function AutoAssembler:GetFilePath(fileName)
    if not self:EnsureDirectoriesExist() then
        logger:Error("[Auto-Assembler] Folder check failed. Cannot load side-loaded script files.")
        return nil
    end
    local processName = processHandler:GetAttachedProcessName()
    if not processName then
        logger:Error("[Auto-Assembler] No process attached. Cannot build file path.")
        return nil
    end
    return customIO.DataDir ..
        "\\" ..
        self.LocalFilesFolder ..
        "\\" ..
        extractFileNameWithoutExt(processName) ..
        "\\" ..
        self:FormatFileName(fileName)
end

--
--- ∑ Loads an Auto-Assembler script from either raw text or from a side-loaded file.
---   If the input contains line breaks, it is treated as raw script text.
---   Otherwise it is treated as a file name and loaded from the process-specific side-loading folder.
--- @param nameOrText string # A script text or a file name.
--- @return string|nil, string # Returns the script text on success, otherwise nil plus a human-readable error.
--
function AutoAssembler:_loadScriptText(nameOrText)
    if not _isString(nameOrText) then
        return nil, "Script input must be text (file name or raw script)."
    end
    local s = nameOrText
    if s:find("\n") then
        return s, "<raw>"
    end
    local fileName = _trim(s)
    local filePath = self:GetFilePath(fileName)
    if not filePath then
        return nil, "The side-loading folder could not be prepared. Please attach to the game and try again."
    end
    local content, err = customIO:ReadFromFile(filePath)
    if content then
        logger:Info("[Auto-Assembler] Loaded script file: " .. fileName)
        return content, fileName
    end
    if customIO.ReadFromTableFile then
        content, err = customIO:ReadFromTableFile(fileName)
        if content then
            logger:Info("[Auto-Assembler] Loaded script from table file: " .. fileName)
            return content, fileName
        end
    end
    return nil, "Could not find or read the script file: " .. fileName
end

--
--- ∑ Creates a stable state key for a script.
---   If a memrec is provided, a stable identifier (ID/Description) is used to avoid mismatches across executions.
--- @param name string # The logical script name (usually the file name).
--- @param memrec table|nil # Optional memory record reference.
--- @return string # Returns the state key.
--
function AutoAssembler:_stateKey(name, memrec)
    local base = tostring(name or "<unknown>")
    if memrec ~= nil then
        local id = memrec.ID
        if id ~= nil then
            return base .. "#MRID:" .. tostring(id)
        end
        local desc = memrec.Description
        if desc ~= nil and desc ~= "" then
            return base .. "#MRDESC:" .. tostring(desc)
        end
        return base .. "#MR:" .. tostring(memrec)
    end
    return base
end

--
--- ∑ Retrieves an existing state or creates a new one.
---   States store disable information to allow clean toggling and rollback behavior.
--- @param key string # The state key.
--- @return table # Returns the state table.
--
function AutoAssembler:_getOrCreateState(key)
    local st = self.States[key]
    if not st then
        st = {
            Key = key,
            Name = key,
            DisableInfo = nil,
            Active = false,
            TargetSelf = false,
            Memrec = nil,
            LastScriptText = nil,
            LastLogicalName = nil
        }
        self.States[key] = st
        logger:Info("[Auto-Assembler] Tracking script state: " .. key)
    end
    return st
end

--
--- ∑ Begins a transactional group for multiple AutoAssemble calls.
---   This allows rolling back previously applied scripts if a later script fails.
--- @return nil
--
function AutoAssembler:_txBegin()
    self._txDepth = self._txDepth + 1
    if self._txDepth == 1 then
        self._txStack = {}
        logger:Debug("[Auto-Assembler] Starting a grouped operation...")
    end
end

--
--- ∑ Commits the current transaction.
---   On the top-level transaction, this clears the rollback stack.
--- @return nil
--
function AutoAssembler:_txCommit()
    if self._txDepth == 1 then
        logger:Debug("[Auto-Assembler] Grouped operation completed.")
        self._txStack = nil
    end
    self._txDepth = math.max(0, self._txDepth - 1)
end

--
--- ∑ Records a successfully enabled script for potential rollback.
---   Stored entries are used to disable applied scripts if a later failure happens.
--- @param key string # The state key.
--- @param scriptText string # The full script text.
--- @param targetSelf boolean # True if assembling into Cheat Engine itself.
--- @param disableInfo table # Disable information returned by autoAssemble.
--- @param logicalName string # Human-friendly logical name.
--- @return nil
--
function AutoAssembler:_txRememberEnable(key, scriptText, targetSelf, disableInfo, logicalName)
    if self._txDepth <= 0 or not self._txStack then
        return
    end
    table.insert(self._txStack, { key = key, scriptText = scriptText, targetSelf = targetSelf, disableInfo = disableInfo, logicalName = logicalName or key })
end

--
--- ∑ Rolls back all scripts enabled in the current transaction.
---   This disables applied scripts in reverse order to restore a safe state.
--- @return nil
--
function AutoAssembler:_txRollback()
    if not self._txStack or #self._txStack == 0 then
        self._txDepth = 0
        self._txStack = nil
        return
    end
    logger:Error("[Auto-Assembler] The script failed. Rolling back previous changes to keep things safe...")
    for i = #self._txStack, 1, -1 do
        local e = self._txStack[i]
        local st = self.States[e.key]
        if st and e.disableInfo then
            logger:ForceInfo("[Auto-Assembler] Rolling back: " .. tostring(e.logicalName))
            local ok, err = pcall(function()
                local success = autoAssemble(e.scriptText, e.targetSelf, e.disableInfo)
                if not success then error("Disable failed during rollback.", 0) end
            end)
            if ok then
                st.DisableInfo = nil
                st.Active = false
                logger:ForceInfo("[Auto-Assembler] Rollback successful: " .. tostring(e.logicalName))
            else
                logger:Error("[Auto-Assembler] Rollback could not disable: " .. tostring(e.logicalName) .. " | Reason: " .. tostring(err))
            end
        end
    end
    self._txStack = nil
    self._txDepth = 0
end

--
--- ∑ Runs an Auto-Assembler script by file name (side-loaded) or by raw script text.
---   This function is process-aware, supports toggling via disableInfo, and supports rollback on failure.
--- @param fileOrText string # The script file name or the raw script text.
--- @param memrecOrTargetSelf table|boolean|nil # Optional memory record or a boolean for targetSelf.
--- @param targetSelf boolean|nil # Optional targetSelf flag if memrecOrTargetSelf is a memrec.
--- @return boolean # Returns true on success, otherwise false (or throws if BreakOnError is true).
--
function AutoAssembler:AutoAssemble(fileOrText, memrecOrTargetSelf, targetSelf)
    local isTopLevel = (self._txDepth == 0)
    self:_txBegin()
    local ok, resultOrErr = pcall(function()
        self:_validateProcessOrThrow()
        self:_checkProcessChangedOrThrow()
        local memrec = (type(memrecOrTargetSelf) == "boolean") and nil or memrecOrTargetSelf
        local ts = (type(memrecOrTargetSelf) == "boolean") and memrecOrTargetSelf or targetSelf
        ts = (ts == true)
        local scriptText, logicalNameOrErr = self:_loadScriptText(fileOrText)
        if not scriptText then
            error("[Auto-Assembler] Cannot continue. " .. tostring(logicalNameOrErr), 0)
        end
        local key = self:_stateKey(logicalNameOrErr, memrec)
        local st = self:_getOrCreateState(key)
        st.TargetSelf = ts
        st.Memrec = memrec
        st.LastScriptText = scriptText
        st.LastLogicalName = logicalNameOrErr
        local willEnable = (st.DisableInfo == nil)
        if willEnable then
            logger:Info("[Auto-Assembler] Turning ON: " .. tostring(logicalNameOrErr))
        else
            logger:Info("[Auto-Assembler] Turning OFF: " .. tostring(logicalNameOrErr))
        end
        local checkOk, checkErr = autoAssembleCheck(scriptText, willEnable, ts)
        if not checkOk then
            error("[Auto-Assembler] Script has a problem and cannot be used: " .. tostring(checkErr), 0)
        end
        local success, disableInfo = autoAssemble(scriptText, ts, st.DisableInfo)
        if not success then
            error("[Auto-Assembler] The script could not be applied. Please try again or report this script.", 0)
        end
        st.DisableInfo = disableInfo
        st.Active = (disableInfo ~= nil)
        if willEnable and disableInfo then
            self:_txRememberEnable(key, scriptText, ts, disableInfo, logicalNameOrErr)
        end
        if st.Active then
            logger:Info("[Auto-Assembler] Done: " .. tostring(logicalNameOrErr) .. " is now ON.")
        else
            logger:Info("[Auto-Assembler] Done: " .. tostring(logicalNameOrErr) .. " is now OFF.")
        end
        return true
    end)
    if ok then
        self:_txCommit()
        return true
    end
    if not isTopLevel then
        self._txDepth = math.max(0, self._txDepth - 1)
        error(resultOrErr, 0)
    end
    self:_txRollback()
    if self.BreakOnError then
        logger:Error(tostring(resultOrErr))
        error(tostring(resultOrErr), 2)
    end
    return false
end

--
--- ∑ Disables an active script state.
---   If no arguments are provided, all active states will be disabled.
--- @param fileOrKey string|nil # Optional state key or script name.
--- @param memrec table|nil # Optional memory record to build a stable state key.
--- @return boolean # Returns true on success, otherwise throws.
--
function AutoAssembler:Disable(fileOrKey, memrec)
    self:_validateProcessOrThrow()
    local function disableState(st)
        if not st or not st.Active or not st.DisableInfo then
            return true
        end
        local scriptText = st.LastScriptText
        if not scriptText then
            error("[Auto-Assembler] Cannot turn off a script because its text is missing.", 0)
        end
        logger:Info("[Auto-Assembler] Turning OFF: " .. tostring(st.LastLogicalName or st.Key))
        local ok, err = pcall(function()
            local success = autoAssemble(scriptText, st.TargetSelf, st.DisableInfo)
            if not success then error("Disable failed.", 0) end
        end)
        if not ok then
            error("[Auto-Assembler] Failed to turn off: " .. tostring(st.LastLogicalName or st.Key) .. " | Reason: " .. tostring(err), 0)
        end
        st.DisableInfo = nil
        st.Active = false
        logger:Info("[Auto-Assembler] Done: " .. tostring(st.LastLogicalName or st.Key) .. " is now OFF.")
        return true
    end
    if fileOrKey == nil then
        logger:Info("[Auto-Assembler] Turning OFF all active scripts...")
        for _, st in pairs(self.States) do if st.Active then disableState(st) end end
        return true
    end
    local key = tostring(fileOrKey)
    if memrec ~= nil then
        key = self:_stateKey(key, memrec)
    end
    local st = self.States[key]
    if not st then
        logger:Warning("[Auto-Assembler] Nothing to turn off (script was not active): " .. tostring(key))
        return true
    end
    return disableState(st)
end

--
--- ∑ Hook called by Cheat Engine when a new process is opened.
---   If the process changed, the Auto-Assembler will safe-disable all records and reset its internal state.
--- @return nil
--
local _o_MainForm_OnProcessOpened = MainForm.OnProcessOpened
function MainForm.OnProcessOpened()
    local inst = AutoAssembler:GetInstance()
    local newPid = getOpenedProcessID()
    local oldPid = inst._lastKnownPid
    inst._lastKnownPid = newPid
    if oldPid ~= 0 and oldPid ~= nil and newPid ~= nil and oldPid ~= newPid then
        logger:Warning("[Auto-Assembler] A new game session was detected. Resetting to keep everything safe...")
        inst:DisableAllWithoutExecute()
        inst:Reset("New game session opened")
        logger:Info("[Auto-Assembler] Everything was reset. Please run the script again.")
    end
    if _o_MainForm_OnProcessOpened then
        _o_MainForm_OnProcessOpened()
    end
end

return AutoAssembler