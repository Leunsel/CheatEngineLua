local NAME = "Manifold.ProcessHandler.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.1"
local DESCRIPTION = "Manifold Framework ProcessHandler"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.

    ∂ v1.0.1 (2025-04-11)
        Minor comment adjustments.
]]--

ProcessHandler = {
    AutoAttachTimerInterval = 100,
    AutoAttachTimerTicks = 0,     
    AutoAttachTimerTickMax = 5000,
}
ProcessHandler.__index = ProcessHandler

function ProcessHandler:New()
    local instance = setmetatable({}, self)
    self:CheckDependencies()
    instance.Name = NAME or "Unnamed Module"
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
function ProcessHandler:IsProcessAttached()
    if not process then
        logger:Warning("[ProcessHandler] No process attached.")
        return false
    end
    local success, result = pcall(readInteger, process)
    if success and result ~= nil then
        -- ProcessHandler is attached and accessible
        return true
    else
        if not success then
            logger:Warning("[ProcessHandler] Failed to read process memory: '" .. result .. "'.")
        else
            logger:Warning("[ProcessHandler] Process is no longer or was never accessible.")
        end
        return false
    end
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
    if self:IsProcessAttached() then
        return process
    else
        return nil
    end
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
function ProcessHandler:AutoAttach(processName)
    processName = processName or self.ProcessName
    logger:Debug("[ProcessHandler] Starting AutoAttach for process: " .. tostring(processName))
    local function autoAttachTimer_tick(timer)
        -- logger:Info("[ProcessHandler] Timer fired!")
        if self:ShouldStopAutoAttach(timer) then return end
        local processID = getProcessIDFromProcessName(processName)
        if processID then
            self:TryAttachToProcess(timer, processName, processID)
        end
        self.AutoAttachTimerTicks = self.AutoAttachTimerTicks + 1
    end
    self:StartAutoAttachTimer(autoAttachTimer_tick)
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
        timer.destroy()
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
function ProcessHandler:TryAttachToProcess(timer, processName, processID)
    logger:Debug("[ProcessHandler] Found " .. processName .. " with PID " .. processID .. ". Attempting to attach...")
    timer.destroy()
    local currentProcessID = getOpenedProcessID()
    if currentProcessID == processID then
        logger:Debug("[ProcessHandler] Process is already attached (PID: " .. currentProcessID .. "). Skipping reattachment.")
    else
        logger:Debug("[ProcessHandler] Previously attached PID: " .. tostring(currentProcessID))
        logger:Debug("[ProcessHandler] Attempting to open process with ID: " .. processID)
        openProcess(processID) 
        logger:Debug("[ProcessHandler] Called openProcess with process ID: " .. processID)
    end
    -- Always execute the post-attachment tasks regardless of reattachment
    self:HandleProcessMismatch(processName, processID)
    self:PerformPostAttachTasks()
    logger:Debug("[ProcessHandler] Auto Attach Complete. Process: '" .. processName .. "' | PID: " .. tostring(processID) .. " | Status: " .. (processID and "Success" or "Failed"))
end

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
            openProcess(processName) 
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
    if self.AutoAttachTimer then
        self.AutoAttachTimer.destroy()
    end
    self.AutoAttachTimer = createTimer(MainForm)
    self.AutoAttachTimer.Interval = self.AutoAttachTimerInterval
    self.AutoAttachTimer.OnTimer = callback
    logger:Debug("[ProcessHandler] AutoAttach timer started with interval: " .. self.AutoAttachTimerInterval .. "ms")
end

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
--- ∑ Starts an auto-attach timer with a specified callback.
---   The callback function will be called on each timer tick.
--- @param callback function # The function to call on each timer tick.
--- @return # void
--- @note 
--- - Creates a timer attached to the MainForm.
--- - Sets the timer's interval based on AutoAttachTimerInterval.
--- - Logs the timer start and its interval.
---
---   This function sets up a recurring timer to periodically call the specified callback. 
---   The interval is determined by the 'AutoAttachTimerInterval' property, and the start of the timer is logged for tracking purposes.
---
function ProcessHandler:StartAutoAttachTimer(callback)
    local autoAttachTimer = createTimer(MainForm)
    autoAttachTimer.Interval = self.AutoAttachTimerInterval
    autoAttachTimer.OnTimer = callback
    logger:Info("[ProcessHandler] AutoAttach timer started with interval: " .. self.AutoAttachTimerInterval .. "ms")
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
    if self:IsProcessAttached() then
        local attachedProcess = process
        local expectedProcess = utils:GetTarget()
        local processID = getProcessIDFromProcessName(expectedProcess)
        if attachedProcess == expectedProcess then
            logger:Debug("[ProcessHandler] Already attached to the correct process: " .. expectedProcess)
            return true
        else
            self:HandleProcessMismatch(expectedProcess, processID)
            return self:IsProcessAttached() and process == expectedProcess
        end
    end
    if not processName or processName == "" then
        logger:Error("[ProcessHandler] Invalid process name provided.")
        return false
    end
    local processID = getProcessIDFromProcessName(processName)
    if not processID then
        logger:Error("[ProcessHandler] Process '" .. processName .. "' not found.")
        return false
    end
    logger:Debug("[ProcessHandler] Attempting to attach to process '" .. processName .. "' (PID: " .. processID .. ").")
    openProcess(processID)
    if self:IsProcessAttached() and process == processName then
        logger:Debug("[ProcessHandler] Successfully attached to process '" .. processName .. "' (PID: " .. processID .. ").")
        return true
    else
        logger:Error("[ProcessHandler] Failed to attach to process '" .. processName .. "'.")
        return false
    end
end
registerLuaFunctionHighlight('AttachToProcessByName')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return ProcessHandler
