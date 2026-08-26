local NAME = "Manifold.ProcessHandler.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.3.0"
local DESCRIPTION = "Manifold Framework ProcessHandler"

--[[
    v1.3.0 (2026-08-26)
        Watch epochs moved into a shared registry so a reloaded table
        retires the previous load's watchers instead of letting each
        one run its own cleanup. Liveness is debounced, cleanup is
        single-flight, and repeated cycles now stop with one error
        rather than looping.

    v1.2.8 (2026-08-23)
        Implemented the Bootstrap handshake so this module
        can be loaded on its own or through the framework.
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
    ProcessWatchTimerTicks = 0,
    ProcessWatchTimerLastTick = nil,
    ProcessWatchGeneration = 0,
    ProcessWatchFallbackTicks = 0,
    ProcessWatchFallbackLastTick = nil,
    ProcessWatchFailureStreak = 0,
    --- Consecutive bad probes before the target counts as gone. One failed read
    --- is not evidence. Two in a row is.
    LivenessFailureThreshold = 2,
    --- Cleanup-and-reattach cycles tolerated inside the window before the
    --- handler stops restarting itself and says so once.
    RestartStormLimit = 4,
    RestartStormWindowSeconds = 10,
    RestartStormTripped = false,
    IsAutoAttaching = false,
    IsWatchingProcess = false,
    AttachedProcessName = nil,
    AttachedProcessID = nil,
}
ProcessHandler.__index = ProcessHandler


local MODULE_PREFIX = "[ProcessHandler]"

--
--- ∑ Manifold.Bootstrap handshake. Uses the framework core when the cheat
---   table has loaded it, and degrades to an inert stub when it has not, so
---   this module stays loadable on its own. Identical in every module. This
---   is the one duplication the design costs, and it is irreducible. Something
---   has to reach the loader before the loader exists.
--
local BOOTSTRAP = rawget(_G, "ManifoldBootstrap") or {
    Declare = function(spec) return spec end,
    Resolve = function() return true end,
    Ready   = function(_, instance) return instance end,
    Once    = function(_, fn) if type(fn) == "function" then pcall(fn) end return true end,
}

--
--- ∑ This module's identity and its dependency contract, in one place.
---     required = true -> New() refuses rather than pretending to be ready
---     runtime  = true -> documented only; never loaded here, never ordered on
--
local MODULE = BOOTSTRAP.Declare({
    class = "ProcessHandler", global = "processHandler",
    name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION,
    prefix = MODULE_PREFIX,
    deps = {
        { "logger", required = true },
        { "utils", runtime = true },
    },
})

--
--- ∑ Internal helper to compare process names in a case-insensitive manner, treating nil and empty strings as non-matching.
--- @param left string|nil # First process name.
--- @param right string|nil # Second process name.
--- @return boolean # True when both names are non-empty and match case-insensitively.
--
local function _SameProcessName(left, right)
    left = tostring(left or "")
    right = tostring(right or "")
    return left ~= "" and right ~= "" and left:lower() == right:lower()
end

--
--- ∑ Safely destroys a timer, suppressing any errors that may occur during destruction.
--- @param timer timer|nil # The timer to destroy.
--- @return void
--- @note This function uses pcall to catch and ignore any errors that may arise from destroying
---       a timer, ensuring that the calling code can continue executing without interruption.
--
local function _DestroyTimer(timer)
    if timer then
        pcall(function() timer.destroy() end)
    end
end

--
--- ∑ Watch bookkeeping shared by every ProcessHandler in the Lua state.
---   It has to live in _G rather than in the instance or in a module upvalue.
---   Reloading a Cheat Table re-runs this file and builds a new instance, but
---   the timers and threads of the previous one keep running. When their
---   generation counter lived on their own instance nothing could ever retire
---   them, so each surviving watcher ran its own full cleanup when the game
---   exited. One shared epoch retires all of them at once.
--
local WATCH_REGISTRY_KEY = "__ManifoldProcessWatchRegistry"

local function _WatchRegistry()
    local registry = rawget(_G, WATCH_REGISTRY_KEY)
    if type(registry) ~= "table" then
        registry = { Epoch = 0, Busy = false, Restarts = {} }
        rawset(_G, WATCH_REGISTRY_KEY, registry)
    end
    if type(registry.Restarts) ~= "table" then registry.Restarts = {} end
    return registry
end

-- Loading this file is itself a reason to retire older watchers.
_WatchRegistry().Epoch = _WatchRegistry().Epoch + 1

function ProcessHandler:New(config)
    local instance = setmetatable({}, self)
    instance.Name = NAME or "Unnamed Module"
    instance:CheckDependencies()
    for key, value in pairs(config or {}) do
        instance[key] = value
    end
    return BOOTSTRAP.Ready(MODULE, instance)
end
registerLuaFunctionHighlight('New')

--
--- ∑ Returns module metadata.
--- @return table # {name, version, author, description}
--
function ProcessHandler:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Prints module metadata.
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
--- ∑ Loads required dependencies when missing.
--
--- ∑ The single dependency lookup, shared by every Manifold module.
---   The name is kept so external callers and the docs keep working, and so a
---   module can still be checked without being constructed.
---   Behaviour is refuse-and-report: Bootstrap.Resolve never loads anything.
---   A missing `required` dependency raises out of New() with one legible
---   message instead of this module pretending to be ready.
--- @return boolean, table # resolved, list of missing dependency names
--
function ProcessHandler:CheckDependencies()
    return BOOTSTRAP.Resolve(MODULE)
end
registerLuaFunctionHighlight('CheckDependencies')

--
--- ∑ Resolves and stores the target process name.
--- @param processName string|nil # Process name.
--- @return string|nil # Resolved process name.
--
function ProcessHandler:ResolveProcessName(processName)
    processName = processName or self.ProcessName or self.AttachedProcessName
    if not processName or processName == "" then
        logger:Error(MODULE_PREFIX .. " No process name configured.")
        return nil
    end
    self.ProcessName = processName
    return processName
end
registerLuaFunctionHighlight('ResolveProcessName')

--
--- ∑ Checks whether the current process can still be read.
--- @return integer|nil # The value returned by readInteger(process), if attached.
--
function ProcessHandler:IsAttachedProcessAvailable()
    if not process or process == "" then return nil end
    local ok, result = pcall(readInteger, process)
    if not ok then return nil end
    return result
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
    if not inMainThread() then
        synchronize(function()
            self:CloseProcess()
        end)
        return
    end
    if not self:IsProcessAttached() then
        -- `utils` is declared runtime (see the deps list above), so a table is
        -- entitled not to have it. Indexing it unguarded turned "nothing is
        -- attached" - an ordinary, expected state - into a hard crash.
        local message = "Not attached to a process!\nWhat do you expect me to close? :("
        if utils and type(utils.ShowError) == "function" then
            utils:ShowError(message)
        else
            logger:Error(MODULE_PREFIX .. " " .. message)
        end
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
    if not inMainThread() then
        synchronize(function()
            self:OpenLink(link)
        end)
        return
    end
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
--- ∑ Checks whether Cheat Engine has opened the expected target PID.
--- @param processName string|nil # Retained for call-site compatibility; PID is authoritative.
--- @param processID number|nil # Expected process id.
--- @return boolean # True when CE's opened PID matches the expected PID.
--
function ProcessHandler:IsAttachedToTarget(processName, processID)
    processID = processID or self.AttachedProcessID
    return processID ~= nil and getOpenedProcessID() == processID
end
registerLuaFunctionHighlight('IsAttachedToTarget')

--
--- ∑ Checks whether the expected target is attached and still readable.
--- @param processName string|nil # Retained for call-site compatibility.
--- @param processID number|nil # Retained for call-site compatibility.
--- @return boolean # True when readInteger(process) succeeds.
--
function ProcessHandler:IsTargetProcessValid(processName, processID)
    return self:IsAttachedProcessAvailable() ~= nil
end
registerLuaFunctionHighlight('IsTargetProcessValid')

--
--- ∑ Checks whether Cheat Engine is currently attached to a process.
--- @return boolean # True when a process is attached and readable.
--
function ProcessHandler:IsProcessAttached()
    return self:IsAttachedProcessAvailable() ~= nil
end
registerLuaFunctionHighlight('IsProcessAttached')

--
--- ∑ Retrieves the name of the currently attached process if available.
--- @return string|nil # The name of the currently attached process, or nil if not available.
--
function ProcessHandler:GetAttachedProcessName()
    if self:IsAttachedProcessAvailable() then return process end
    return nil
end
registerLuaFunctionHighlight('GetAttachedProcessName')

--
--- ∑ The attached process name without its ".exe" extension.
---   Exists so Helper:GetProcessTrimmed - deprecated in Helper 1.1.0 - has an
---   owner to delegate to. Parenthesised: a bare gsub returns the substitution
---   count as a second value.
--- @return string|nil
--
function ProcessHandler:GetAttachedNameNoExt()
    local name = self:GetAttachedProcessName()
    if type(name) ~= "string" or name == "" then return nil end
    return (name:gsub("%.exe$", ""))
end
registerLuaFunctionHighlight('GetAttachedNameNoExt')

--
--- ∑ Opens a new watch epoch and retires every watcher started before it,
---   including ones left behind by an earlier load of this module.
--- @return number # The epoch the caller now owns.
--
function ProcessHandler:BeginWatchEpoch()
    local registry = _WatchRegistry()
    registry.Epoch = registry.Epoch + 1
    self.ProcessWatchGeneration = registry.Epoch
    return registry.Epoch
end
registerLuaFunctionHighlight('BeginWatchEpoch')

--
--- ∑ Whether the caller still owns the current watch epoch.
--- @param epoch number # Epoch captured when the watcher was created.
--- @return boolean # False once a newer watcher has taken over.
--
function ProcessHandler:IsWatchEpochCurrent(epoch)
    return epoch ~= nil and _WatchRegistry().Epoch == epoch
end
registerLuaFunctionHighlight('IsWatchEpochCurrent')

--
--- ∑ Records a restart attempt and reports whether the handler should still
---   be restarting itself. A handler that tears the table down several times a
---   second is not recovering, it is thrashing, and it should say so once
---   instead of filling the log.
--- @return boolean, number # Allowed to restart, attempts inside the window.
--
function ProcessHandler:RegisterRestartAttempt()
    local registry = _WatchRegistry()
    local window = tonumber(self.RestartStormWindowSeconds) or 10
    local limit = tonumber(self.RestartStormLimit) or 4
    local now = os.time()
    local kept = {}
    for _, stamp in ipairs(registry.Restarts) do
        if now - stamp < window then
            kept[#kept + 1] = stamp
        end
    end
    kept[#kept + 1] = now
    registry.Restarts = kept
    return #kept <= limit, #kept
end
registerLuaFunctionHighlight('RegisterRestartAttempt')

--
--- ∑ Clears the restart-storm history, re-arming automatic recovery.
--
function ProcessHandler:ClearRestartHistory()
    _WatchRegistry().Restarts = {}
    self.RestartStormTripped = false
end
registerLuaFunctionHighlight('ClearRestartHistory')

function ProcessHandler:StopAutoAttachTimer(timer)
    local activeTimer = timer or self.AutoAttachTimer
    _DestroyTimer(activeTimer)
    if not timer or timer == self.AutoAttachTimer then
        self.AutoAttachTimer = nil
    end
    self.IsAutoAttaching = false
end
registerLuaFunctionHighlight('StopAutoAttachTimer')

--
--- ∑ Stops and destroys the process watch timer if it exists, and resets related state.
--- @param timer timer|nil # Optional timer to stop. If nil, stops the current process watch timer.
--- @return boolean # True when the timer was stopped.
--
function ProcessHandler:StopProcessWatchTimer(timer)
    local activeTimer = timer or self.ProcessWatchTimer
    local isCurrentTimer = not timer or timer == self.ProcessWatchTimer
    if isCurrentTimer then
        -- Retiring the epoch is what stops watchers belonging to other instances
        -- from each running their own copy of the cleanup below.
        self:BeginWatchEpoch()
        self.ProcessWatchFailureStreak = 0
    end
    if not activeTimer then
        if self.IsWatchingProcess then
            logger:Warning(MODULE_PREFIX .. " Process watch state was active, but no timer existed. Resetting watch state.")
            self.IsWatchingProcess = false
        else
            logger:Debug(MODULE_PREFIX .. " No process watch timer to stop.")
        end
        return false
    end
    _DestroyTimer(activeTimer)
    if isCurrentTimer then
        self.ProcessWatchTimer = nil
        self.IsWatchingProcess = false
        logger:Info(MODULE_PREFIX .. " Process watch timer stopped.")
    else
        logger:Debug(MODULE_PREFIX .. " Stale process watch timer destroyed.")
    end
    return true
end
registerLuaFunctionHighlight('StopProcessWatchTimer')

--
--- ∑ Starts a background fallback that detects a missing or replaced target PID when CE does not dispatch TTimer events.
--- @param processName string # Target process name.
--- @param processID number # PID expected to remain alive.
--- @return boolean # True when the fallback thread was started.
--
function ProcessHandler:StartProcessWatchFallback(processName, processID, epoch)
    if type(createThread) ~= "function" then
        logger:Warning(MODULE_PREFIX .. " [Fallback] createThread is unavailable. Process watch fallback was not started.")
        return false
    end
    epoch = epoch or self.ProcessWatchGeneration
    local interval = self.ProcessWatchTimerInterval
    -- os.time() only resolves to whole seconds, so the timer has to be quiet for
    -- more than one of them before its silence means anything.
    local silenceSeconds = math.max(2, math.ceil((tonumber(interval) or 1000) / 500))
    self.ProcessWatchFallbackTicks = 0
    self.ProcessWatchFallbackLastTick = nil
    local ok, err = pcall(function()
        createThread(function(thread)
            while not thread.Terminated and self:IsWatchEpochCurrent(epoch) do
                sleep(interval)
                if thread.Terminated or not self:IsWatchEpochCurrent(epoch) then
                    return
                end
                self.ProcessWatchFallbackTicks = self.ProcessWatchFallbackTicks + 1
                self.ProcessWatchFallbackLastTick = os.time()
                -- The TTimer is the primary watcher. This thread exists only for
                -- the case where CE stops dispatching timer events, so it stays
                -- out of the way while the timer is demonstrably still ticking.
                local lastTick = self.ProcessWatchTimerLastTick
                local timerIsSilent = lastTick == nil or (os.time() - lastTick) >= silenceSeconds
                if timerIsSilent then
                    local keepWatching = true
                    thread.synchronize(function()
                        keepWatching = self:EvaluateTarget("[Fallback]", epoch)
                    end)
                    if not keepWatching then
                        return
                    end
                end
            end
        end)
    end)
    if not ok then
        logger:Error(MODULE_PREFIX .. " [Fallback] Failed to start process watch fallback: " .. tostring(err))
        return false
    end
    return true
end
registerLuaFunctionHighlight('StartProcessWatchFallback')

--
--- ∑ Starts a timer that attaches to the target process when it appears.
--- @param processName string|nil # Target process name.
--- @param options number|table|nil # maxSecs number or options table.
--- @return boolean # True when the timer was started.
--
function ProcessHandler:AutoAttach(processName, options, internalRestart)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    if internalRestart ~= true then
        -- An explicit call is the operator saying "try again". Forget the storm.
        self:ClearRestartHistory()
    end
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
            logger:ForceInfo(MODULE_PREFIX .. " Auto-Attach timed out. You may attach manually from now.")
            return
        end
        local processID = getProcessIDFromProcessName(processName)
        if processID then
            self:StopAutoAttachTimer(timer)
            local opened, openResultOrErr = pcall(openProcess, processID)
            if not opened or openResultOrErr == false then
                logger:Error(MODULE_PREFIX .. " Failed to open process '" .. tostring(processName) .. "': " .. tostring(openResultOrErr))
                self:AutoAttach(processName, options)
                return
            end
            self.AttachedProcessName = processName
            self.AttachedProcessID = processID
            self.ProcessWatchFailureStreak = 0
            self:OnProcessAttached(processName, processID, options)
            return
        end
        self.AutoAttachTimerTicks = self.AutoAttachTimerTicks + 1
    end
    self.AutoAttachTimer.Enabled = true
    self.IsAutoAttaching = true
    logger:Info(MODULE_PREFIX .. " AutoAttach started for process: " .. tostring(processName))
    return true
end
registerLuaFunctionHighlight('AutoAttach')

--
--- ∑ Attaches Cheat Engine to a process and validates that it is the expected target.
--- @param processName string # Expected process name.
--- @param processID number|nil # Optional process id.
--- @return boolean # True when attach and validation succeed.
--
function ProcessHandler:AttachToProcess(processName, processID, options)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    local previousProcessID = self.AttachedProcessID
    processID = processID or getProcessIDFromProcessName(processName)
    if not processID then
        logger:Error(MODULE_PREFIX .. " Process '" .. tostring(processName) .. "' not found.")
        return false
    end
    if getOpenedProcessID() ~= processID then
        local ok, err = pcall(openProcess, processID)
        if not ok then
            logger:Error(MODULE_PREFIX .. " Failed to open process '" .. tostring(processName) .. "': " .. tostring(err))
            return false
        end
    end
    if not self:IsAttachedToTarget(processName, processID) then
        logger:Error(MODULE_PREFIX .. " Attach validation failed. Expected PID " .. tostring(processID) .. ", found PID " .. tostring(getOpenedProcessID()) .. ".")
        return false
    end
    if not self:IsAttachedProcessAvailable() then
        logger:Debug(MODULE_PREFIX .. " PID " .. tostring(processID) .. " is open, but CE has not finished resolving 'process' for readInteger(process) yet.")
        return false
    end
    if previousProcessID ~= nil and previousProcessID ~= processID then
        self:ResetProcessBoundState("Attached process changed. Previous PID: " .. tostring(previousProcessID) .. " | Current PID: " .. tostring(processID))
    end
    self.AttachedProcessName = processName
    self.AttachedProcessID = processID
    self:OnProcessAttached(processName, processID, options or self.AutoAttachOptions)
    return true
end
registerLuaFunctionHighlight('AttachToProcess')

--
--- ∑ Attaches to a process by name using AutoAttach, which will keep trying until the process is found or a timeout occurs.
--- @param processName string # Target process name.
--- @return boolean # True when the attach process was initiated.
--
function ProcessHandler:AttachToProcessByName(processName)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    local processID = getProcessIDFromProcessName(processName)
    if not processID then
        logger:Error(MODULE_PREFIX .. " Process '" .. tostring(processName) .. "' not found.")
        return false
    end
    return self:AttachToProcess(processName, processID, self.AutoAttachOptions)
end
registerLuaFunctionHighlight('AttachToProcessByName')

--
--- ∑ Runs post-attach work and starts the process watch timer.
--- @param processName string # Attached process name.
--- @param processID number # Attached process id.
--- @param options table|nil # Optional post-attach options.
--
function ProcessHandler:OnProcessAttached(processName, processID, options)
    options = options or {}
    if options.runPostAttachTasks ~= false then
        local ok, err = pcall(function() self:PerformPostAttachTasks() end)
        if not ok then
            logger:Error(MODULE_PREFIX .. " Post-attach tasks failed: " .. tostring(err))
        end
    end
    if type(options.onAttached) == "function" then
        local ok, err = pcall(options.onAttached, self, processName, processID)
        if not ok then
            logger:Error(MODULE_PREFIX .. " Post-attach callback failed: " .. tostring(err))
        end
    end
    self:StartProcessWatchTimer(processName)
    logger:Info(MODULE_PREFIX .. " Attached to '" .. tostring(processName) .. "' (PID: " .. tostring(processID) .. ").")
end
registerLuaFunctionHighlight('OnProcessAttached')

--
--- ∑ Starts a timer that periodically checks if the attached process is still available, and triggers cleanup if it is not.
--- @param processName string|nil # Optional process name to watch. If nil, uses the currently attached process name.
--- @return boolean # True when the timer was started.
--
function ProcessHandler:StartProcessWatchTimer(processName)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    self:StopProcessWatchTimer()
    local epoch = self:BeginWatchEpoch()
    self.ProcessWatchTimer = createTimer(MainForm)
    self.ProcessWatchTimerTicks = 0
    self.ProcessWatchTimerLastTick = nil
    self.ProcessWatchFailureStreak = 0
    self.ProcessWatchTimer.Interval = self.ProcessWatchTimerInterval
    self.ProcessWatchTimer.OnTimer = function(timer)
        if not self:IsWatchEpochCurrent(epoch) then
            -- Superseded by a newer watch. Destroy the timer directly rather than
            -- going through StopProcessWatchTimer, which would retire the epoch
            -- that the current watcher is relying on.
            _DestroyTimer(timer)
            return
        end
        self.ProcessWatchTimerTicks = self.ProcessWatchTimerTicks + 1
        self.ProcessWatchTimerLastTick = os.time()
        local ok, err = pcall(function()
            self:EvaluateTarget("watch timer", epoch, timer)
        end)
        if not ok then
            logger:Error(MODULE_PREFIX .. " Process watch timer callback failed: " .. tostring(err))
        end
    end
    self.ProcessWatchTimer.Enabled = true
    self.IsWatchingProcess = true
    self:StartProcessWatchFallback(processName, self.AttachedProcessID, epoch)
    logger:Info(MODULE_PREFIX .. " Process watch timer started for '" .. tostring(processName) .. "'.")
    return true
end
registerLuaFunctionHighlight('StartProcessWatchTimer')

--
--- ∑ Returns the current process-watch timer state for diagnostics.
--- @return table # Watch state, timer reference, tick count, and last tick timestamp.
--
function ProcessHandler:GetProcessWatchStatus()
    return {
        isWatching = self.IsWatchingProcess,
        timer = self.ProcessWatchTimer,
        ticks = self.ProcessWatchTimerTicks,
        lastTick = self.ProcessWatchTimerLastTick,
        fallbackTicks = self.ProcessWatchFallbackTicks,
        fallbackLastTick = self.ProcessWatchFallbackLastTick,
    }
end
registerLuaFunctionHighlight('GetProcessWatchStatus')

--
--- ∑ One honest answer about the target.
---   getOpenedProcessID() keeps returning the old PID long after the process is
---   gone, so it gets no vote here; the process list and an actual read are the
---   only two sources trusted.
--- @param processName string # Name being watched.
--- @param expectedProcessID number|nil # PID that should still own that name.
--- @return string, number|nil # "alive" | "gone" | "changed" | "unknown", current PID.
--
function ProcessHandler:ProbeTarget(processName, expectedProcessID)
    local queried, currentProcessID = pcall(getProcessIDFromProcessName, processName)
    if not queried then
        -- The query itself failed. That says nothing about the process.
        return "unknown", nil
    end
    local readable = self:IsAttachedProcessAvailable() ~= nil
    if currentProcessID == nil then
        return readable and "unknown" or "gone", nil
    end
    if expectedProcessID ~= nil and currentProcessID ~= expectedProcessID then
        return "changed", currentProcessID
    end
    if readable then
        return "alive", currentProcessID
    end
    return "unknown", currentProcessID
end
registerLuaFunctionHighlight('ProbeTarget')

--
--- ∑ The single decision point for both watchers.
---   Debounced, so one bad probe cannot tear the table down, and guarded, so two
---   watchers noticing the same death produce one cleanup rather than two.
--- @param source string # Which watcher is asking, for the log.
--- @param epoch number|nil # Epoch of the calling watcher.
--- @param timer timer|nil # Timer to stop if cleanup runs.
--- @return boolean # True while the watch should continue.
--
function ProcessHandler:EvaluateTarget(source, epoch, timer)
    if epoch ~= nil and not self:IsWatchEpochCurrent(epoch) then
        return false
    end
    if _WatchRegistry().Busy then
        logger:Debug(MODULE_PREFIX .. " " .. tostring(source) .. ": cleanup already in progress, standing down.")
        return false
    end
    local processName = self.AttachedProcessName or self.ProcessName
    local expectedProcessID = self.AttachedProcessID
    if not processName or processName == "" or expectedProcessID == nil then
        return false
    end
    local verdict, currentProcessID = self:ProbeTarget(processName, expectedProcessID)
    if verdict == "alive" then
        self.ProcessWatchFailureStreak = 0
        return true
    end
    local threshold = math.max(1, tonumber(self.LivenessFailureThreshold) or 2)
    self.ProcessWatchFailureStreak = (self.ProcessWatchFailureStreak or 0) + 1
    if self.ProcessWatchFailureStreak < threshold then
        logger:DebugF(MODULE_PREFIX .. " %s: '%s' probed '%s' (%d/%d). Waiting for confirmation.",
            tostring(source), tostring(processName), verdict,
            self.ProcessWatchFailureStreak, threshold)
        return true
    end
    local detail = string.format("%s Expected PID: %s | Current PID: %s",
        tostring(source), tostring(expectedProcessID), tostring(currentProcessID))
    if verdict == "changed" then
        self:HandleProcessChanged(expectedProcessID, currentProcessID, timer)
    else
        self:HandleProcessUnavailable(detail .. " Process is no longer available.", timer)
    end
    return false
end
registerLuaFunctionHighlight('EvaluateTarget')

--
--- ∑ Checks if the watched process is still available.
--- @param timer Timer # The timer that triggered the check.
--- @return boolean # True if the process is available. False if cleanup was triggered.
--
function ProcessHandler:CheckWatchedProcess(timer)
    return self:EvaluateTarget("watch timer", self.ProcessWatchGeneration, timer)
end
registerLuaFunctionHighlight('CheckWatchedProcess')

--
--- ∑ Disables all active records without executing their disable scripts, and clears registered symbols.
--- @return boolean # True when the cleanup was performed successfully. False if the required AddressList functions were not available or if an error occurred during cleanup.
--
function ProcessHandler:DisableAllWithoutExecute()
    local addressList = AddressList or (type(getAddressList) == "function" and getAddressList() or nil)
    if not addressList or not addressList.disableAllWithoutExecute then
        logger:Warning(MODULE_PREFIX .. " AddressList.disableAllWithoutExecute is not available.")
        return false
    end
    local ok, err = pcall(function()
        addressList.disableAllWithoutExecute()
        if type(deleteAllRegisteredSymbols) == "function" then
            deleteAllRegisteredSymbols()
        end
    end)
    if not ok then
        logger:Error(MODULE_PREFIX .. " Cleanup failed: " .. tostring(err))
        return false
    end
    logger:Info(MODULE_PREFIX .. " Cleanup complete. Records disabled without executing disable scripts.")
    return true
end
registerLuaFunctionHighlight('DisableAllWithoutExecute')

--
--- ∑ Resets the state of the auto-assembler and clears active patches, ensuring that any process-bound state is cleared.
--- @param reason string|nil # Optional reason for the reset, used for logging.
--- @return void
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
    end
    if rawget(_G, "trampolines") and type(trampolines.Reset) == "function" then
        trampolines:Reset()
    end
end
registerLuaFunctionHighlight('ResetProcessBoundState')

--
--- ∑ Cleans up the current state and restarts the auto-attach process.
--- @param reason string|nil # Optional reason for the cleanup, used for logging.
--- @param timer timer|nil # Optional timer to stop during cleanup. If nil, stops the current process watch timer.
--- @return void
--
function ProcessHandler:CleanupAndReattach(reason, timer)
    local registry = _WatchRegistry()
    if registry.Busy then
        logger:Debug(MODULE_PREFIX .. " Cleanup already in progress. Ignoring: " .. tostring(reason))
        return false
    end
    if self.RestartStormTripped then
        -- Already reported once. Repeating the teardown would only add noise to
        -- a situation that has stopped being automatic.
        logger:Debug(MODULE_PREFIX .. " Auto-Attach is disarmed after a restart storm. Ignoring: " .. tostring(reason))
        return false
    end
    registry.Busy = true
    local processName = self.ProcessName or self.AttachedProcessName
    local wasAttached = self.AttachedProcessID ~= nil
    local ok, err = pcall(function()
        self:StopAutoAttachTimer()
        self:StopProcessWatchTimer(timer)
        logger:Warning(MODULE_PREFIX .. " " .. tostring(reason or "Process unavailable") .. " Cleaning up and restarting AutoAttach.")
        if wasAttached then
            self:DisableAllWithoutExecute()
            self:ResetProcessBoundState(reason or "Process unavailable")
        else
            logger:Debug(MODULE_PREFIX .. " Nothing was attached; skipping record and patch cleanup.")
        end
        self.AttachedProcessName = nil
        self.AttachedProcessID = nil
        self.ProcessWatchFailureStreak = 0
    end)
    registry.Busy = false
    if not ok then
        logger:Error(MODULE_PREFIX .. " Cleanup failed: " .. tostring(err))
    end
    local allowed, attempts = self:RegisterRestartAttempt()
    if not allowed then
        self.RestartStormTripped = true
        logger:ForceErrorF(
            MODULE_PREFIX .. " %d cleanup cycles within %ds - this is thrashing, not recovery. " ..
            "Auto-Attach stopped. Call processHandler:AutoAttach(\"%s\") to resume once the cause is known.",
            attempts, tonumber(self.RestartStormWindowSeconds) or 10, tostring(processName))
        return false
    end
    if processName and processName ~= "" then
        self:AutoAttach(processName, self.AutoAttachOptions, true)
    end
    return true
end
registerLuaFunctionHighlight('CleanupAndReattach')

--
--- ∑ Handles the case when the process is unavailable.
--- @param reason string|nil # Optional reason for the unavailability, used for logging.
--- @param timer timer|nil # Optional timer to stop during handling. If nil, stops the current process watch timer.
--- @return void
--
function ProcessHandler:HandleProcessUnavailable(reason, timer)
    return self:CleanupAndReattach(reason, timer)
end
registerLuaFunctionHighlight('HandleProcessUnavailable')

--
--- ∑ Handles the case when the process changes (e.g., due to a new process with the same name appearing), by performing cleanup and attempting to reattach.
--- @param oldPid number|nil # The previous process ID, if known.
--- @param newPid number|nil # The new process ID, if known.
--- @return void
--
function ProcessHandler:HandleProcessChanged(oldPid, newPid, timer)
    return self:CleanupAndReattach("Process changed. Previous PID: " .. tostring(oldPid) .. " | Current PID: " .. tostring(newPid), timer)
end
registerLuaFunctionHighlight('HandleProcessChanged')

--
--- ∑ Performs necessary tasks after successfully attaching to the target process, such as initializing utilities and verifying file hashes.
--- @return void
--
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
