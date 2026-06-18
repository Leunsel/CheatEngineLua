local NAME = "Manifold.ProcessHandler.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.1.0"
local DESCRIPTION = "Manifold Framework ProcessHandler"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.

    ∂ v1.0.1 (2025-04-11)
        Minor comment adjustments.

    ∂ v1.0.2 (2026-06-17)
        AutoAttach Tick Reset upon start and removed duplicate StartAutoAttachTimer function.

    v1.1.0 (2026-06-18)
        Reworked the process lifecycle flow into AutoAttach, Attach/PostAttach, and ProcessWatch stages.
        Added safe cleanup and automatic AutoAttach restart when the process disappears.
]]--

ProcessHandler = {
    ProcessName = nil,
    AutoAttachTimerInterval = 100,
    AutoAttachTimerTicks = 0,
    AutoAttachTimerTickMax = 5000,
    AutoAttachTimer = nil,
    AutoAttachOptions = nil,
    ProcessWatchTimerInterval = 1000,
    ProcessWatchTimer = nil,
    IsAutoAttaching = false,
    IsWatchingProcess = false,
    AttachedProcessName = nil,
    AttachedProcessID = nil,
}
ProcessHandler.__index = ProcessHandler

function ProcessHandler:New()
    local instance = setmetatable({}, self)
    instance:CheckDependencies()
    instance.Name = NAME or "Unnamed Module"
    instance.AutoAttachTimerTicks = 0
    instance.AutoAttachTimer = nil
    instance.AutoAttachOptions = nil
    instance.ProcessWatchTimer = nil
    instance.IsAutoAttaching = false
    instance.IsWatchingProcess = false
    instance.AttachedProcessName = nil
    instance.AttachedProcessID = nil
    return instance
end
registerLuaFunctionHighlight('New')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table # {name, version, author, description}
--
function ProcessHandler:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Prints module details in a readable formatted block.
--
function ProcessHandler:PrintModuleInfo()
    local info = self:GetModuleInfo()
    if not info then
        logger:Info("[ProcessHandler] Failed to retrieve module info.")
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

--
--- ∑ Checks if all required dependencies are loaded, and loads them if necessary.
---   The dependencies are specified in a table with their names, paths, and initialization functions.
--- @return # void
--- @note This function checks for the existence of the 'logger' and 'utils' dependencies,
---       and attempts to load them if not already present. If loading fails, an error is logged.
---
---   This function ensures that all required dependencies are available before proceeding with the process handler's operations.
---   It checks if the dependencies are already loaded in the global environment, and if not, it attempts to load them using 'CETrequire'.
--
function ProcessHandler:CheckDependencies()
    local dependencies = {
        { name = "logger", path = "Manifold.Logger",  init = function() logger = Logger:New() end },
        { name = "utils", path = "Manifold.Utils",  init = function() utils = Utils:New() end },
        { name = "helper", path = "Manifold.Helper",  init = function() helper = Helper:New() end },
    }
    for _, dep in ipairs(dependencies) do
        local depName = dep.name
        if _G[depName] == nil then
            logger:Warning("[ProcessHandler] '" .. depName .. "' dependency not found. Attempting to load...")
            local success, result = pcall(CETrequire, dep.path)
            if success then
                logger:Info("[ProcessHandler] Loaded dependency '" .. depName .. "'.")
                if dep.init then dep.init() end
            else
                logger:Error("[ProcessHandler] Failed to load dependency '" .. depName .. "': " .. result)
            end
        else
            logger:Debug("[ProcessHandler] Dependency '" .. depName .. "' is already loaded")
        end
    end  
end

--
--- ∑ Checks if a process is currently attached.
--- @return boolean # True if a process is attached, false otherwise.
--- @note This function verifies if a process is attached by attempting to read its memory.
---
---   This function attempts to read from the process memory. If the read is successful and the result is not 'nil', it confirms that the process is attached.
---   If an error occurs while reading the memory, a warning message is logged to indicate whether the process is no longer available.
--
function ProcessHandler:IsAttachedProcessAvailable()
    if helper and type(helper.IsProcessAvailable) == "function" then
        return helper:IsProcessAvailable()
    end
    if not process or process == "" then
        return false
    end
    local success, result = pcall(readInteger, process)
    return success and result ~= nil
end
registerLuaFunctionHighlight('IsAttachedProcessAvailable')

function ProcessHandler:IsProcessAttached()
    if self:IsAttachedProcessAvailable() then
        return true
    end
    logger:Warning("[ProcessHandler] No process attached or process is no longer accessible.")
    return false
end
registerLuaFunctionHighlight('IsProcessAttached')

--
--- ∑ Retrieves the name of the currently attached process.
--- @return string|nil # The name of the attached process, or nil if no process is attached.
---
---   This function checks if a process is attached by calling 'IsProcessAttached'. If the process is attached, it returns the name of the process.
---   If no process is attached, it returns 'nil'.
--
function ProcessHandler:GetAttachedProcessName()
    if self:IsAttachedProcessAvailable() then return process end
    return nil
end
registerLuaFunctionHighlight('GetAttachedProcessName')

--
--- ∑ Closes the currently attached process after user confirmation.
--- @return # void
--- @note Displays a confirmation dialog before terminating the process.
---
---   This function asks the user for confirmation before attempting to terminate the currently attached process using the 'taskkill' command.
---   If no process is attached, an error message is shown.
--
function ProcessHandler:CloseProcess()
    if not self:IsProcessAttached() then
        utils:ShowError("Not attached to a process!\nWhat do you expect me to close? :(")
        return
    end
    local processID = getOpenedProcessID()
    local processName = process
    local message = string.format("Do you really want to terminate the process %s (PID: %d)?", processName, processID)
    local result = messageDialog(message, mtConfirmation, mbYes, mbNo)
    if result == mrYes then
        local command = string.format("taskkill /PID %d /F", processID)
        os.execute(command)
    end
end
registerLuaFunctionHighlight('CloseProcess')

--
--- ∑ Opens a specified link in the default web browser after user confirmation.
--- @param link string The URL to open.
--- @return # void
--- @note Displays a confirmation dialog before proceeding.
---
---   This function prompts the user for confirmation before opening a specified URL in the default web browser.
---   If the user confirms, the link is opened using 'ShellExecute'.
--
function ProcessHandler:OpenLink(link)
    local result = messageDialog(
        "Do you really want to open this link?\n" .. link,
        mtConfirmation,
        mbYes, mbNo)
    if result == mrYes then
        ShellExecute(link)
    end
end
registerLuaFunctionHighlight('OpenLink')

--
--- ∑ Automatically attaches to a specified process by repeatedly checking for its existence.
--- @param processName string|nil The name of the process to attach to. Uses the default process if nil.
--- @return # void
---
---   This function automatically attempts to attach to a process by its name at regular intervals, using the 'AutoAttachTimer'.
---   If the process is found, the 'TryAttachToProcess' function is called to attach to it. If the process is not found within the maximum retries, the timer stops.
--
function ProcessHandler:ResolveProcessName(processName)
    processName = processName or self.ProcessName or self.AttachedProcessName
    if not processName or processName == "" then
        logger:Error("[ProcessHandler] No process name configured.")
        return nil
    end
    self.ProcessName = processName
    return processName
end
registerLuaFunctionHighlight('ResolveProcessName')

function ProcessHandler:AutoAttach(processName, options)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    self.AutoAttachOptions = options
    self:StopProcessWatchTimer()
    self:StopAutoAttachTimer()
    self.AutoAttachTimerTicks = 0
    self.IsAutoAttaching = true
    logger:Debug("[ProcessHandler] Starting AutoAttach for process: " .. tostring(processName))
    local function autoAttachTimer_tick(timer)
        if self:ShouldStopAutoAttach(timer) then return end
        local processID = getProcessIDFromProcessName(processName)
        if processID then
            self:TryAttachToProcess(timer, processName, processID, options)
        end
        self.AutoAttachTimerTicks = self.AutoAttachTimerTicks + 1
    end
    self:StartAutoAttachTimer(autoAttachTimer_tick)
    return true
end
registerLuaFunctionHighlight('AutoAttach')

--
--- ∑ Determines whether the auto-attach timer should stop due to exceeding retry limits.
--- @param timer Timer # The active timer instance.
--- @return boolean # True if the auto-attach process should stop, false otherwise.
---
---   This function checks if the maximum number of retries for the auto-attach process has been exceeded. 
---   If it has, the timer is destroyed, and an error message is logged.
--
function ProcessHandler:ShouldStopAutoAttach(timer)
    if self.AutoAttachTimerTickMax > 0 and self.AutoAttachTimerTicks >= self.AutoAttachTimerTickMax then
        self:StopAutoAttachTimer(timer)
        logger:Error("[ProcessHandler] Auto-Attach couldn't find the process in time. You may attach manually from now!")
        return true
    end
    return false
end

--
--- ∑ Attempts to attach to a found process.
--- @param timer Timer # The active timer instance.
--- @param processName string # The name of the process.
--- @param processID number # The ID of the process.
--- @return # void
---
---   This function attempts to attach to the specified process by checking if the process is already attached. If not, it attempts to attach to it.
---   It also performs necessary post-attachment tasks and handles any process mismatches.
--
function ProcessHandler:TryAttachToProcess(timer, processName, processID, options)
    logger:Debug("[ProcessHandler] Found " .. processName .. " with PID " .. processID .. ". Attempting to attach...")
    self:StopAutoAttachTimer(timer)
    if not self:AttachToProcess(processName, processID) then
        self:AutoAttach(processName, options)
        return false
    end
    self:OnProcessAttached(processName, processID, options)
    return true
end

--
--- ∑ Attaches Cheat Engine to a process by name and/or process id.
--- @param processName string # The expected process name.
--- @param processID number|nil # Optional process id. If nil, the id is resolved by name.
--- @return boolean # True if the attach succeeded and the process is available.
--
function ProcessHandler:AttachToProcess(processName, processID)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    processID = processID or getProcessIDFromProcessName(processName)
    if not processID then
        logger:Error("[ProcessHandler] Process '" .. tostring(processName) .. "' not found.")
        return false
    end
    local currentProcessID = getOpenedProcessID()
    if currentProcessID == processID then
        logger:Debug("[ProcessHandler] Process is already attached (PID: " .. tostring(currentProcessID) .. ").")
    else
        logger:Debug("[ProcessHandler] Previously attached PID: " .. tostring(currentProcessID))
        logger:Debug("[ProcessHandler] Attempting to open process with ID: " .. tostring(processID))
        local ok, err = pcall(openProcess, processID)
        if not ok then
            logger:Error("[ProcessHandler] Failed to open process '" .. tostring(processName) .. "': " .. tostring(err))
            return false
        end
    end
    self:HandleProcessMismatch(processName, processID)
    if not self:IsAttachedProcessAvailable() then
        logger:Error("[ProcessHandler] Process '" .. tostring(processName) .. "' was found but is not accessible after attach.")
        return false
    end
    self.AttachedProcessName = processName
    self.AttachedProcessID = processID
    return true
end
registerLuaFunctionHighlight('AttachToProcess')

--
--- ∑ Runs post-attach tasks and starts the process watch timer.
--- @param processName string # The attached process name.
--- @param processID number # The attached process id.
--- @param options table|nil # Optional flow options.
--- @return # void
--
function ProcessHandler:OnProcessAttached(processName, processID, options)
    options = options or {}
    if options.runPostAttachTasks ~= false then
        local ok, err = pcall(function() self:PerformPostAttachTasks() end)
        if not ok then
            logger:Error("[ProcessHandler] Post-attach tasks failed: " .. tostring(err))
        end
    end
    if type(options.onAttached) == "function" then
        local ok, err = pcall(options.onAttached, self, processName, processID)
        if not ok then
            logger:Error("[ProcessHandler] Post-attach callback failed: " .. tostring(err))
        end
    end
    logger:Debug("[ProcessHandler] Auto Attach Complete. Process: '" .. tostring(processName) .. "' | PID: " .. tostring(processID))
    self:StartProcessWatchTimer(processName)
end
registerLuaFunctionHighlight('OnProcessAttached')

--
--- ∑ Ensures the attached process matches the expected process name and ID.
--- @param processName string # The expected process name.
--- @param processID number # The expected process ID.
--- @return # void
---
---   This function checks if the currently attached process matches the expected name and ID. If there is a mismatch, it attempts to reattach to the correct process.
---   It logs the status and any necessary actions taken during this process.
--
function ProcessHandler:HandleProcessMismatch(processName, processID)
    local attachedProcess = process
    if attachedProcess ~= processName then
        logger:Warning("[ProcessHandler] Process mismatch detected! Expected: " .. processName .. ", Found: " .. tostring(attachedProcess))
        if getOpenedProcessID() ~= processID then
            logger:Debug("[ProcessHandler] Reattempting openProcess with process name: " .. processName)
            local ok, err = pcall(openProcess, processName)
            if not ok then
                logger:Error("[ProcessHandler] Reattachment by process name failed: " .. tostring(err))
            end
        else
            logger:Debug("[ProcessHandler] Process ID matches but name mismatch. No reattachment needed.")
        end
    end
    logger:Debug("[ProcessHandler] Successfully attached to " .. processName .. " with PID " .. getOpenedProcessID())
end

--
--- ∑ Starts the AutoAttach timer to attempt process attachment at regular intervals.
--- @param callback function # The function to execute on each timer tick.
--- @return # void
--- @note If an existing timer is running, it will be destroyed before creating a new one.
---
---   This function starts the AutoAttach timer to try to attach to a process at regular intervals. 
---   If a timer is already running, it will be destroyed to ensure only one instance is active.
--
function ProcessHandler:StartAutoAttachTimer(callback)
    self:StopAutoAttachTimer()
    self.AutoAttachTimer = createTimer(MainForm)
    self.AutoAttachTimer.Interval = self.AutoAttachTimerInterval
    self.AutoAttachTimer.OnTimer = callback
    self.AutoAttachTimer.Enabled = true
    self.IsAutoAttaching = true
    logger:Debug("[ProcessHandler] AutoAttach timer started with interval: " .. self.AutoAttachTimerInterval .. "ms")
end

function ProcessHandler:StopAutoAttachTimer(timer)
    local activeTimer = timer or self.AutoAttachTimer
    if activeTimer then
        pcall(function() activeTimer.destroy() end)
    end
    if not timer or timer == self.AutoAttachTimer then
        self.AutoAttachTimer = nil
    end
    self.IsAutoAttaching = false
end
registerLuaFunctionHighlight('StopAutoAttachTimer')

--
--- ∑ Starts the timer that watches the attached process.
--- @param processName string|nil # Process name to use when AutoAttach needs to restart.
--- @return boolean # True if the watch timer was started.
--
function ProcessHandler:StartProcessWatchTimer(processName)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    self:StopProcessWatchTimer()
    self.ProcessWatchTimer = createTimer(MainForm)
    self.ProcessWatchTimer.Interval = self.ProcessWatchTimerInterval
    self.ProcessWatchTimer.OnTimer = function(timer)
        self:CheckWatchedProcess(timer)
    end
    self.ProcessWatchTimer.Enabled = true
    self.IsWatchingProcess = true
    logger:Debug("[ProcessHandler] Process watch timer started with interval: " .. tostring(self.ProcessWatchTimerInterval) .. "ms")
    return true
end
registerLuaFunctionHighlight('StartProcessWatchTimer')

--
--- ∑ Stops the process watch timer.
--- @param timer Timer|nil # Optional timer instance to destroy.
--- @return # void
--
function ProcessHandler:StopProcessWatchTimer(timer)
    local activeTimer = timer or self.ProcessWatchTimer
    if activeTimer then
        pcall(function() activeTimer.destroy() end)
    end
    if not timer or timer == self.ProcessWatchTimer then
        self.ProcessWatchTimer = nil
    end
    self.IsWatchingProcess = false
end
registerLuaFunctionHighlight('StopProcessWatchTimer')

--
--- ∑ Checks whether the watched process is still available.
--- @param timer Timer|nil # The active watch timer.
--- @return boolean # True while the process is still available.
--
function ProcessHandler:CheckWatchedProcess(timer)
    if self:IsAttachedProcessAvailable() then
        return true
    end
    self:HandleProcessUnavailable("Process is no longer available.", timer)
    return false
end
registerLuaFunctionHighlight('CheckWatchedProcess')

--
--- ∑ Disables table records without executing their disable sections.
--- @return boolean # True if the cleanup succeeded.
--
function ProcessHandler:DisableAllWithoutExecute()
    local addressList = AddressList
    if not addressList and type(getAddressList) == "function" then
        addressList = getAddressList()
    end
    if not addressList or not addressList.disableAllWithoutExecute then
        logger:Warning("[ProcessHandler] Could not disable records safely (AddressList.disableAllWithoutExecute is not available).")
        return false
    end
    local ok, err = pcall(function()
        addressList.disableAllWithoutExecute()
        if type(deleteAllRegisteredSymbols) == "function" then
            deleteAllRegisteredSymbols()
        end
    end)
    if ok then
        logger:Info("[ProcessHandler] All table records were disabled safely (without executing disable scripts).")
        return true
    end
    logger:Error("[ProcessHandler] Failed to disable records safely. Reason: " .. tostring(err))
    return false
end
registerLuaFunctionHighlight('DisableAllWithoutExecute')

--
--- ∑ Resets related module state after a process disappears.
--- @param reason string|nil # Reason passed to reset-capable modules.
--- @return # void
--
function ProcessHandler:ResetProcessBoundState(reason)
    local assembler = rawget(_G, "autoAssembler") or rawget(_G, "autoassembler")
    if not assembler and rawget(_G, "AutoAssembler") and AutoAssembler._instance then
        assembler = AutoAssembler._instance
    end
    if assembler and type(assembler.Reset) == "function" then
        assembler:Reset(reason or "Process unavailable")
    end
    if rawget(_G, "assemblerCommands") and type(assemblerCommands.ActivePatches) == "table" then
        assemblerCommands.ActivePatches = {}
        logger:Info("[ProcessHandler] Cleared active patches list after process loss.")
    end
end
registerLuaFunctionHighlight('ResetProcessBoundState')

--
--- ∑ Handles an explicit process change reported by Cheat Engine.
--- @param oldPid number|nil # Previous process id.
--- @param newPid number|nil # New process id.
--- @return # void
--
function ProcessHandler:HandleProcessChanged(oldPid, newPid)
    self:StopAutoAttachTimer()
    self:StopProcessWatchTimer()
    logger:Warning("[ProcessHandler] A new game session was detected. Resetting process-bound state...")
    self:DisableAllWithoutExecute()
    self:ResetProcessBoundState("New game session opened")
    self.AttachedProcessName = process
    self.AttachedProcessID = newPid
    if self.AttachedProcessName and self.AttachedProcessName ~= "" and self:IsAttachedProcessAvailable() then
        self.ProcessName = self.AttachedProcessName
        self:StartProcessWatchTimer(self.ProcessName)
    end
    logger:Info("[ProcessHandler] Process change cleanup complete. Previous PID: " .. tostring(oldPid) .. " | Current PID: " .. tostring(newPid))
end
registerLuaFunctionHighlight('HandleProcessChanged')

--
--- ∑ Handles the loss of the attached process and restarts AutoAttach.
--- @param reason string|nil # Human-readable cleanup reason.
--- @param timer Timer|nil # Optional watch timer instance.
--- @return # void
--
function ProcessHandler:HandleProcessUnavailable(reason, timer)
    local processName = self.ProcessName or self.AttachedProcessName
    self:StopProcessWatchTimer(timer)
    logger:Warning("[ProcessHandler] " .. tostring(reason or "Process became unavailable.") .. " Cleaning up and restarting AutoAttach.")
    self:DisableAllWithoutExecute()
    self:ResetProcessBoundState(reason or "Process unavailable")
    self.AttachedProcessName = nil
    self.AttachedProcessID = nil
    if processName and processName ~= "" then
        self:AutoAttach(processName, self.AutoAttachOptions)
    end
end
registerLuaFunctionHighlight('HandleProcessUnavailable')

--
--- ∑ Performs tasks after a successful process attach.
--- @return # void
--- @note This function is intended to run any post-attachment operations, such as
---       setting up tables or verifying file hashes. (Currently unused...)
---
---   This function is used for any necessary post-attachment tasks, such as initializing tables or verifying file integrity.
---   Currently, these tasks are placeholders and may be customized as needed.
--
function ProcessHandler:PerformPostAttachTasks()
    utils:InitializeTable()
    if utils.VerifyMD5 then
        utils:VerifyFileHash()
    end
end

--
--- ∑ Attaches to a process by its name.
---   If the process is already attached, it checks if it matches the expected process name.
---   If not, it handles the mismatch.
--- @param processName string # The name of the process to attach to.
--- @return bool # Returns true if successfully attached to the process, false otherwise.
--- @note
--- - If the process name is invalid or not found, an error is logged.
--- - If the process is already attached and matches the expected process, a debug message is logged.
--- - If the process does not match, it handles the mismatch and attempts to attach to the correct process.
---
---   This function allows the user to attach to a specified process by name. If the process is already attached and is the expected one, it confirms the attachment. 
---   Otherwise, it tries to attach to the process specified by 'processName'. If the process cannot be found or attached, an error is logged.
---
function ProcessHandler:AttachToProcessByName(processName)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    local processID = getProcessIDFromProcessName(processName)
    if not self:AttachToProcess(processName, processID) then
        return false
    end
    self:OnProcessAttached(processName, processID)
    return true
end
registerLuaFunctionHighlight('AttachToProcessByName')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return ProcessHandler
