local NAME = "Manifold.ProcessHandler.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.2.0"
local DESCRIPTION = "Manifold Framework ProcessHandler"

--[[
    v1.2.0 (2026-06-19)
        Reduced ProcessHandler to the core lifecycle:
        AutoAttach -> openProcess -> validate target -> PostAttach -> Watch -> Cleanup -> AutoAttach.
]]--

ProcessHandler = {
    ProcessName = nil,
    AutoAttachTimerInterval = 1000,
    AutoAttachTimerTickMax = 0,
    AutoAttachTimerTicks = 0,
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

local function _SameProcessName(left, right)
    left = tostring(left or "")
    right = tostring(right or "")
    return left ~= "" and right ~= "" and left:lower() == right:lower()
end

local function _DestroyTimer(timer)
    if timer then
        pcall(function() timer.destroy() end)
    end
end

function ProcessHandler:New(config)
    local instance = setmetatable({}, self)
    instance.Name = NAME or "Unnamed Module"
    instance:CheckDependencies()
    for key, value in pairs(config or {}) do
        instance[key] = value
    end
    return instance
end
registerLuaFunctionHighlight('New')

--
--- Returns module metadata.
--- @return table # {name, version, author, description}
--
function ProcessHandler:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- Prints module metadata.
--
function ProcessHandler:PrintModuleInfo()
    local info = self:GetModuleInfo()
    logger:Info("Module Info : "  .. tostring(info.name))
    logger:Info("\tVersion:     " .. tostring(info.version))
    logger:Info("\tAuthor:      " .. table.concat(info.author, ", "))
    logger:Info("\tDescription: " .. tostring(info.description) .. "\n")
end
registerLuaFunctionHighlight('PrintModuleInfo')

--
--- Loads required dependencies when missing.
--
function ProcessHandler:CheckDependencies()
    local dependencies = {
        { name = "logger", path = "Manifold.Logger", init = function() logger = Logger:New() end },
        { name = "utils", path = "Manifold.Utils", init = function() utils = Utils:New() end },
    }
    for _, dep in ipairs(dependencies) do
        if _G[dep.name] == nil then
            local ok, result = pcall(CETrequire, dep.path)
            if ok then
                if dep.init then dep.init() end
                logger:Info("[ProcessHandler] Loaded dependency '" .. dep.name .. "'.")
            else
                logger:Error("[ProcessHandler] Failed to load dependency '" .. dep.name .. "': " .. tostring(result))
            end
        end
    end
end

--
--- Resolves and stores the target process name.
--- @param processName string|nil # Process name.
--- @return string|nil # Resolved process name.
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

--
--- Checks whether the current process can still be read.
--- @return boolean # True when readInteger(process) succeeds.
--
function ProcessHandler:IsAttachedProcessAvailable()
    if not process or process == "" then return false end
    local ok, result = pcall(readInteger, process)
    return ok and result ~= nil
end
registerLuaFunctionHighlight('IsAttachedProcessAvailable')

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
--- Checks whether Cheat Engine is attached to the expected target.
--- @param processName string|nil # Expected process name.
--- @param processID number|nil # Expected process id.
--- @return boolean # True when process name and PID match.
--
function ProcessHandler:IsAttachedToTarget(processName, processID)
    processName = processName or self.AttachedProcessName or self.ProcessName
    processID = processID or self.AttachedProcessID
    return processID ~= nil and getOpenedProcessID() == processID and _SameProcessName(process, processName)
end
registerLuaFunctionHighlight('IsAttachedToTarget')

--
--- Checks whether the expected target is attached and still readable.
--- @param processName string|nil # Expected process name.
--- @param processID number|nil # Expected process id.
--- @return boolean # True when target and read check are valid.
--
function ProcessHandler:IsTargetProcessValid(processName, processID)
    return self:IsAttachedToTarget(processName, processID) and self:IsAttachedProcessAvailable()
end
registerLuaFunctionHighlight('IsTargetProcessValid')

function ProcessHandler:IsProcessAttached()
    return self:IsAttachedProcessAvailable()
end
registerLuaFunctionHighlight('IsProcessAttached')

function ProcessHandler:GetAttachedProcessName()
    if self:IsAttachedProcessAvailable() then return process end
    return nil
end
registerLuaFunctionHighlight('GetAttachedProcessName')

function ProcessHandler:StopAutoAttachTimer(timer)
    local activeTimer = timer or self.AutoAttachTimer
    _DestroyTimer(activeTimer)
    if not timer or timer == self.AutoAttachTimer then
        self.AutoAttachTimer = nil
    end
    self.IsAutoAttaching = false
end
registerLuaFunctionHighlight('StopAutoAttachTimer')

function ProcessHandler:StopProcessWatchTimer(timer)
    local activeTimer = timer or self.ProcessWatchTimer
    _DestroyTimer(activeTimer)
    if not timer or timer == self.ProcessWatchTimer then
        self.ProcessWatchTimer = nil
    end
    self.IsWatchingProcess = false
end
registerLuaFunctionHighlight('StopProcessWatchTimer')

--
--- Starts a timer that attaches to the target process when it appears.
--- @param processName string|nil # Target process name.
--- @param options number|table|nil # maxSecs number or options table.
--- @return boolean # True when the timer was started.
--
function ProcessHandler:AutoAttach(processName, options)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    local maxSecs = 0
    if type(options) == "number" then
        maxSecs = options
        options = nil
    elseif type(options) == "table" then
        maxSecs = tonumber(options.maxSecs or options.maxSeconds or options.timeoutSeconds) or 0
    end
    self.AutoAttachOptions = options
    self.AutoAttachTimerTicks = 0
    self:StopProcessWatchTimer()
    self:StopAutoAttachTimer()
    self.AutoAttachTimer = createTimer(MainForm)
    self.AutoAttachTimer.Interval = self.AutoAttachTimerInterval
    self.AutoAttachTimer.OnTimer = function(timer)
        if maxSecs > 0 and self.AutoAttachTimerTicks >= maxSecs then
            self:StopAutoAttachTimer(timer)
            logger:ForceInfo("[ProcessHandler] Auto-Attach timed out. You may attach manually from now.")
            return
        end
        local processID = getProcessIDFromProcessName(processName)
        if processID then
            self:StopAutoAttachTimer(timer)
            if not self:AttachToProcess(processName, processID, options) then
                self:AutoAttach(processName, options)
            end
        end
        self.AutoAttachTimerTicks = self.AutoAttachTimerTicks + 1
    end
    self.AutoAttachTimer.Enabled = true
    self.IsAutoAttaching = true
    logger:Info("[ProcessHandler] AutoAttach started for process: " .. tostring(processName))
    return true
end
registerLuaFunctionHighlight('AutoAttach')

--
--- Attaches Cheat Engine to a process and validates that it is the expected target.
--- @param processName string # Expected process name.
--- @param processID number|nil # Optional process id.
--- @return boolean # True when attach and validation succeed.
--
function ProcessHandler:AttachToProcess(processName, processID, options)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    processID = processID or getProcessIDFromProcessName(processName)
    if not processID then
        logger:Error("[ProcessHandler] Process '" .. tostring(processName) .. "' not found.")
        return false
    end
    if getOpenedProcessID() ~= processID then
        local ok, err = pcall(openProcess, processID)
        if not ok then
            logger:Error("[ProcessHandler] Failed to open process '" .. tostring(processName) .. "': " .. tostring(err))
            return false
        end
    end
    if not self:IsAttachedToTarget(processName, processID) then
        logger:Error("[ProcessHandler] Attach validation failed. Expected '" .. tostring(processName) .. "' (PID: " .. tostring(processID) .. "), found '" .. tostring(process) .. "' (PID: " .. tostring(getOpenedProcessID()) .. ").")
        return false
    end
    if not self:IsAttachedProcessAvailable() then
        logger:Error("[ProcessHandler] Process '" .. tostring(processName) .. "' is attached but not readable.")
        return false
    end
    self.AttachedProcessName = processName
    self.AttachedProcessID = processID
    self:OnProcessAttached(processName, processID, options or self.AutoAttachOptions)
    return true
end
registerLuaFunctionHighlight('AttachToProcess')

function ProcessHandler:AttachToProcessByName(processName)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    local processID = getProcessIDFromProcessName(processName)
    if not processID then
        logger:Error("[ProcessHandler] Process '" .. tostring(processName) .. "' not found.")
        return false
    end
    return self:AttachToProcess(processName, processID, self.AutoAttachOptions)
end
registerLuaFunctionHighlight('AttachToProcessByName')

--
--- Runs post-attach work and starts the process watch timer.
--- @param processName string # Attached process name.
--- @param processID number # Attached process id.
--- @param options table|nil # Optional post-attach options.
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
    self:StartProcessWatchTimer(processName)
    logger:Info("[ProcessHandler] Attached to '" .. tostring(processName) .. "' (PID: " .. tostring(processID) .. ").")
end
registerLuaFunctionHighlight('OnProcessAttached')

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
    logger:Info("[ProcessHandler] Process watch timer started for '" .. tostring(processName) .. "'.")
    return true
end
registerLuaFunctionHighlight('StartProcessWatchTimer')

function ProcessHandler:CheckWatchedProcess(timer)
    if self:IsTargetProcessValid(self.AttachedProcessName, self.AttachedProcessID) then
        return true
    end
    self:HandleProcessUnavailable("Process is no longer available.", timer)
    return false
end
registerLuaFunctionHighlight('CheckWatchedProcess')

function ProcessHandler:DisableAllWithoutExecute()
    local addressList = AddressList or (type(getAddressList) == "function" and getAddressList() or nil)
    if not addressList or not addressList.disableAllWithoutExecute then
        logger:Warning("[ProcessHandler] AddressList.disableAllWithoutExecute is not available.")
        return false
    end
    local ok, err = pcall(function()
        addressList.disableAllWithoutExecute()
        if type(deleteAllRegisteredSymbols) == "function" then
            deleteAllRegisteredSymbols()
        end
    end)
    if not ok then
        logger:Error("[ProcessHandler] Cleanup failed: " .. tostring(err))
        return false
    end
    logger:Info("[ProcessHandler] Cleanup complete. Records disabled without executing disable scripts.")
    return true
end
registerLuaFunctionHighlight('DisableAllWithoutExecute')

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
    end
end
registerLuaFunctionHighlight('ResetProcessBoundState')

function ProcessHandler:CleanupAndReattach(reason, timer)
    local processName = self.ProcessName or self.AttachedProcessName
    self:StopAutoAttachTimer()
    self:StopProcessWatchTimer(timer)
    logger:Warning("[ProcessHandler] " .. tostring(reason or "Process unavailable") .. " Cleaning up and restarting AutoAttach.")
    self:DisableAllWithoutExecute()
    self:ResetProcessBoundState(reason or "Process unavailable")
    self.AttachedProcessName = nil
    self.AttachedProcessID = nil
    if processName and processName ~= "" then
        self:AutoAttach(processName, self.AutoAttachOptions)
    end
end
registerLuaFunctionHighlight('CleanupAndReattach')

function ProcessHandler:HandleProcessUnavailable(reason, timer)
    self:CleanupAndReattach(reason, timer)
end
registerLuaFunctionHighlight('HandleProcessUnavailable')

function ProcessHandler:HandleProcessChanged(oldPid, newPid)
    self:CleanupAndReattach("Process changed. Previous PID: " .. tostring(oldPid) .. " | Current PID: " .. tostring(newPid))
end
registerLuaFunctionHighlight('HandleProcessChanged')

function ProcessHandler:PerformPostAttachTasks()
    if utils and type(utils.InitializeTable) == "function" then
        utils:InitializeTable()
    end
    if utils and utils.VerifyMD5 and type(utils.VerifyFileHash) == "function" then
        utils:VerifyFileHash()
    end
end
registerLuaFunctionHighlight('PerformPostAttachTasks')

return ProcessHandler
