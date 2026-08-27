local NAME = "Manifold.ProcessHandler.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "2.0.0"
local DESCRIPTION = "Manifold Framework ProcessHandler"

--[[
    ∂ v2.0.0 (2026-08-27)
        Rewritten around one idea: readInteger(process) is the only
        statement about process state that Cheat Engine gets right.
        getOpenedProcessID() keeps returning a dead PID, and
        getProcessIDFromProcessName() keeps serving one from a cached
        list, so neither may decide anything. Both are used to FIND a
        process. Only a read confirms one.
        The job is four steps and nothing else: wait for the process,
        attach to it, watch it, and start over when it dies.
]]--

ProcessHandler = {
    --- Target process name, e.g. "Game.exe".
    ProcessName = nil,
    --- Poll intervals in milliseconds.
    AutoAttachTimerInterval = 1000,
    ProcessWatchTimerInterval = 1000,
    --- Consecutive failed reads before the process counts as gone. One failed
    --- read is not evidence; two in a row is.
    LivenessFailureThreshold = 2,
    --- Losing the same PID this many times in a row, each time within
    --- QuickLossSeconds of attaching, means the reattach is not recovering
    --- anything, so auto-restart stops and says so once. An attach that lasted
    --- longer than that was a normal session and resets the count.
    SamePidLossLimit = 3,
    QuickLossSeconds = 10,

    AutoAttachOptions = nil,
    AutoAttachTimer = nil,
    ProcessWatchTimer = nil,
    IsAutoAttaching = false,
    IsWatchingProcess = false,
    AttachedProcessName = nil,
    AttachedProcessID = nil,
    Disarmed = false,
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
---     runtime  = true -> documented only. Never loaded here, never ordered on
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

--------------------------------------------------------
--                     Internals                      --
--------------------------------------------------------

--
--- ∑ The single source of truth about the target.
---   Cheat Engine has three ways to answer "is the process there", and two of
---   them lie. getOpenedProcessID() keeps reporting the PID of a process that
---   exited, and getProcessIDFromProcessName() keeps serving that PID from a
---   cached list, so an exited game is still "found" and openProcess still
---   succeeds on it. Reading its memory is the only answer that tracks reality.
--- @return integer|nil # The probe value, or nil when the process is not there.
--
local function _Probe()
    if type(process) ~= "string" or process == "" then return nil end
    local ok, value = pcall(readInteger, process)
    if not ok then return nil end
    return value
end

--
--- ∑ Destroys a timer, ignoring a host that has already disposed of it.
--
local function _DestroyTimer(timer)
    if timer then pcall(function() timer.destroy() end) end
end

--
--- ∑ Watch epochs, kept in _G so they survive a table reload.
---
---   Reloading a cheat table re-runs this file and builds a new handler, but
---   the timers and threads of the previous one keep running. A counter held on
---   the instance could never retire those, and every surviving watcher then
---   ran its own cleanup when the game exited. One process-wide epoch retires
---   all of them at once.
--
local EPOCH_KEY = "__ManifoldProcessHandlerEpoch"

local function _NewEpoch()
    local value = (tonumber(rawget(_G, EPOCH_KEY)) or 0) + 1
    rawset(_G, EPOCH_KEY, value)
    return value
end

local function _IsEpochCurrent(epoch)
    return epoch ~= nil and rawget(_G, EPOCH_KEY) == epoch
end

-- Loading this file is itself a reason to retire older watchers.
_NewEpoch()

--------------------------------------------------------
--                   Module Start                     --
--------------------------------------------------------

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
    local author = type(info.author) == "table" and table.concat(info.author, ", ") or tostring(info.author)
    logger:InfoBlock("Module Info : " .. tostring(info.name), {
        { "Version",     info.version },
        { "Author",      author },
        { "Description", info.description },
    }, { indent = "\t" })
end
registerLuaFunctionHighlight('PrintModuleInfo')

--
--- ∑ The single dependency lookup, shared by every Manifold module.
--- @return boolean, table # resolved, list of missing dependency names
--
function ProcessHandler:CheckDependencies()
    return BOOTSTRAP.Resolve(MODULE)
end
registerLuaFunctionHighlight('CheckDependencies')

--
--- ∑ Resolves and remembers the process name to work with.
--- @param processName string|nil # Explicit name, or nil to reuse the stored one.
--- @return string|nil # The name, or nil when none is configured.
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

--------------------------------------------------------
--                       State                        --
--------------------------------------------------------

--
--- ∑ Raw probe value, for callers that want the read itself.
--- @return integer|nil
--
function ProcessHandler:IsAttachedProcessAvailable()
    return _Probe()
end
registerLuaFunctionHighlight('IsAttachedProcessAvailable')

--
--- ∑ Whether a process is attached and readable.
--- @return boolean
--
function ProcessHandler:IsProcessAttached()
    return _Probe() ~= nil
end
registerLuaFunctionHighlight('IsProcessAttached')

--
--- ∑ Name of the attached process, or nil when nothing is attached.
--- @return string|nil
--
function ProcessHandler:GetAttachedProcessName()
    if self:IsProcessAttached() then return process end
    return nil
end
registerLuaFunctionHighlight('GetAttachedProcessName')

--
--- ∑ Attached process name without its extension, e.g. "Game" for "Game.exe".
--- @return string|nil
--
function ProcessHandler:GetAttachedNameNoExt()
    local name = self:GetAttachedProcessName()
    if not name then return nil end
    return (name:gsub("%.[^%.]*$", ""))
end
registerLuaFunctionHighlight('GetAttachedNameNoExt')

--------------------------------------------------------
--                      Cleanup                       --
--------------------------------------------------------

--
--- ∑ Disables every active record without running its disable script, and drops
---   registered symbols. The scripts cannot run: their process is gone.
--- @return boolean
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
--- ∑ Clears everything that was bound to the old process image: assembler
---   state, stored patches and installed detours.
--- @param reason string|nil # Passed through to the assembler for its log.
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
--- ∑ Runs post-attach work. Both calls are guarded: utils is a runtime
---   dependency, so a table is entitled not to have it.
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

--------------------------------------------------------
--                     Lifecycle                      --
--------------------------------------------------------

--
--- ∑ Stops both timers and retires the watch epoch, which also terminates any
---   watcher left behind by an earlier load of this file.
--
function ProcessHandler:Stop()
    _DestroyTimer(self.AutoAttachTimer)
    _DestroyTimer(self.ProcessWatchTimer)
    self.AutoAttachTimer, self.ProcessWatchTimer = nil, nil
    self.IsAutoAttaching, self.IsWatchingProcess = false, false
    _NewEpoch()
end
registerLuaFunctionHighlight('Stop')

--- Forward declaration: tryAttach starts the watch, and the watch is defined
--- after the loss handler it calls.
local startWatch

--
--- ∑ The process is gone. Clear everything bound to it and wait for it again.
---
---   Refuses to keep going when the same PID is lost repeatedly: reattaching to
---   a process that dies again immediately is not recovery, and repeating it
---   only buries the cause in log noise.
--
local function handleLoss(self, processName, reason)
    local lostProcessID = self.AttachedProcessID
    local lasted = tonumber(self.AttachedAt) and (os.time() - self.AttachedAt) or 0
    local quick = lasted < (tonumber(self.QuickLossSeconds) or 10)
    if quick and lostProcessID ~= nil and self.LastLostProcessID == lostProcessID then
        self.SamePidLosses = (self.SamePidLosses or 0) + 1
    else
        self.SamePidLosses = 1
    end
    self.LastLostProcessID = lostProcessID

    self:Stop()
    logger:Warning(MODULE_PREFIX .. " " .. tostring(reason))
    self:DisableAllWithoutExecute()
    self:ResetProcessBoundState(reason)
    self.AttachedProcessName, self.AttachedProcessID = nil, nil

    if self.SamePidLosses >= (tonumber(self.SamePidLossLimit) or 3) then
        self.Disarmed = true
        logger:ForceErrorF(MODULE_PREFIX .. " Lost PID %s %d times in a row. Auto-Attach stopped; " ..
            "call processHandler:AutoAttach(\"%s\") once the cause is known.",
            tostring(lostProcessID), self.SamePidLosses, tostring(processName))
        return
    end
    self:AutoAttach(processName, self.AutoAttachOptions, true)
end

--
--- ∑ Background watcher for hosts where Cheat Engine stops dispatching TTimer
---   events. It stays out of the way while the timer is demonstrably ticking,
---   so the two never race, and it calls the very same check.
--
local function startFallback(self, epoch, check)
    if type(createThread) ~= "function" then
        logger:Warning(MODULE_PREFIX .. " createThread is unavailable; the watch has no fallback.")
        return
    end
    local interval = self.ProcessWatchTimerInterval
    -- os.time() resolves to whole seconds, so the timer has to be quiet for
    -- more than one of them before its silence means anything.
    local silenceSeconds = math.max(2, math.ceil((tonumber(interval) or 1000) / 500))
    pcall(function()
        createThread(function(thread)
            while not thread.Terminated and _IsEpochCurrent(epoch) do
                sleep(interval)
                if thread.Terminated or not _IsEpochCurrent(epoch) then return end
                local lastTick = self.LastWatchTick
                if lastTick == nil or (os.time() - lastTick) >= silenceSeconds then
                    local keepWatching = true
                    thread.synchronize(function() keepWatching = check("fallback") end)
                    if not keepWatching then return end
                end
            end
        end)
    end)
end

--
--- ∑ Starts watching the attached process. Returns nothing. The watch ends by
---   itself when the epoch is retired or the process is lost.
--
startWatch = function(self, processName, epoch)
    local failures = 0
    --- @return boolean # true while the watch should continue.
    local function check(source)
        if not _IsEpochCurrent(epoch) then return false end
        if _Probe() ~= nil then
            failures = 0
            return true
        end
        failures = failures + 1
        local threshold = math.max(1, tonumber(self.LivenessFailureThreshold) or 2)
        if failures < threshold then
            logger:DebugF(MODULE_PREFIX .. " %s: '%s' did not answer a read (%d/%d).",
                tostring(source), tostring(processName), failures, threshold)
            return true
        end
        handleLoss(self, processName, string.format(
            "%s: '%s' (PID %s) stopped answering reads. Cleaning up and waiting for it again.",
            tostring(source), tostring(processName), tostring(self.AttachedProcessID)))
        return false
    end

    local timer = createTimer(MainForm)
    timer.Interval = self.ProcessWatchTimerInterval
    timer.OnTimer = function(activeTimer)
        if not _IsEpochCurrent(epoch) then
            _DestroyTimer(activeTimer)
            return
        end
        self.LastWatchTick = os.time()
        local ok, err = pcall(check, "watch timer")
        if not ok then
            logger:Error(MODULE_PREFIX .. " Watch timer failed: " .. tostring(err))
        end
    end
    timer.Enabled = true
    self.ProcessWatchTimer = timer
    self.IsWatchingProcess = true
    self.LastWatchTick = nil
    startFallback(self, epoch, check)
    logger:Info(MODULE_PREFIX .. " Watching '" .. tostring(processName) .. "'.")
end

--
--- ∑ Opens a PID and confirms it with a read, then wires everything up.
---
---   The read is the point. Cheat Engine will happily hand out and open the PID
---   of a process that has already exited, so an attach reported on openProcess
---   alone is how a handler ends up talking to a corpse.
--- @return boolean # true when the process is really there.
--
local function tryAttach(self, processName, processID, options, epoch)
    local opened, result = pcall(openProcess, processID)
    if not opened or result == false or _Probe() == nil then
        if self.StaleNoticePid ~= processID then
            self.StaleNoticePid = processID
            logger:WarningF(MODULE_PREFIX .. " '%s' is listed as PID %s but does not answer a read. " ..
                "Ignoring the stale entry and waiting for the real process.",
                tostring(processName), tostring(processID))
        end
        return false
    end
    _DestroyTimer(self.AutoAttachTimer)
    self.AutoAttachTimer, self.IsAutoAttaching = nil, false
    self.StaleNoticePid = nil
    self.AttachedProcessName = processName
    self.AttachedProcessID = processID
    self.AttachedAt = os.time()
    options = options or {}
    if options.runPostAttachTasks ~= false then
        local ok, err = pcall(function() self:PerformPostAttachTasks() end)
        if not ok then logger:Error(MODULE_PREFIX .. " Post-attach tasks failed: " .. tostring(err)) end
    end
    if type(options.onAttached) == "function" then
        local ok, err = pcall(options.onAttached, self, processName, processID)
        if not ok then logger:Error(MODULE_PREFIX .. " Post-attach callback failed: " .. tostring(err)) end
    end
    logger:InfoF(MODULE_PREFIX .. " Attached to '%s' (PID: %s).", tostring(processName), tostring(processID))
    startWatch(self, processName, epoch)
    return true
end

--
--- ∑ Waits for the process and attaches as soon as it is really there.
--- @param processName string|nil # Target name; falls back to the stored one.
--- @param options number|table|nil # Seconds to wait, or
---        { maxSecs, runPostAttachTasks, onAttached }.
--- @param internalRestart boolean|nil # true when called by the loss handler.
--- @return boolean # true when the waiting timer was started.
--
function ProcessHandler:AutoAttach(processName, options, internalRestart)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    if internalRestart == true then
        -- Only an explicit call may lift a disarm. Otherwise the loop the
        -- disarm exists to stop would simply restart itself.
        if self.Disarmed then
            logger:Debug(MODULE_PREFIX .. " Auto-Attach is disarmed; not restarting by itself.")
            return false
        end
    else
        -- An explicit call is the operator saying "try again".
        self.Disarmed, self.SamePidLosses, self.LastLostProcessID = false, 0, nil
    end
    local maxSeconds = 0
    if type(options) == "number" then
        maxSeconds, options = options, nil
    elseif type(options) == "table" then
        maxSeconds = tonumber(options.maxSecs or options.maxSeconds or options.timeoutSeconds) or 0
    end
    self.AutoAttachOptions = options
    self:Stop()
    local epoch = _NewEpoch()
    local ticks = 0
    local timer = createTimer(MainForm)
    timer.Interval = self.AutoAttachTimerInterval
    timer.OnTimer = function(activeTimer)
        if not _IsEpochCurrent(epoch) then
            _DestroyTimer(activeTimer)
            return
        end
        if maxSeconds > 0 and ticks >= maxSeconds then
            self:Stop()
            logger:ForceInfo(MODULE_PREFIX .. " Auto-Attach timed out. You may attach manually from now.")
            return
        end
        ticks = ticks + 1
        local found, processID = pcall(getProcessIDFromProcessName, processName)
        if found and processID then
            tryAttach(self, processName, processID, options, epoch)
        end
    end
    timer.Enabled = true
    self.AutoAttachTimer = timer
    self.IsAutoAttaching = true
    logger:Info(MODULE_PREFIX .. " AutoAttach started for process: " .. tostring(processName))
    return true
end
registerLuaFunctionHighlight('AutoAttach')

--
--- ∑ Attaches to a named process right now, without waiting.
--- @param processName string|nil # Target name; falls back to the stored one.
--- @return boolean # true when the attach succeeded and was confirmed.
--
function ProcessHandler:AttachToProcessByName(processName)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    local found, processID = pcall(getProcessIDFromProcessName, processName)
    if not found or not processID then
        logger:ErrorF(MODULE_PREFIX .. " Process '%s' not found.", tostring(processName))
        return false
    end
    self:Stop()
    return tryAttach(self, processName, processID, self.AutoAttachOptions, _NewEpoch())
end
registerLuaFunctionHighlight('AttachToProcessByName')

--
--- ∑ Attaches to a specific PID, or resolves the name when no PID is given.
--- @param processName string|nil
--- @param processID number|nil
--- @param options table|nil
--- @return boolean
--
function ProcessHandler:AttachToProcess(processName, processID, options)
    processName = self:ResolveProcessName(processName)
    if not processName then return false end
    if not processID then return self:AttachToProcessByName(processName) end
    self:Stop()
    return tryAttach(self, processName, processID, options or self.AutoAttachOptions, _NewEpoch())
end
registerLuaFunctionHighlight('AttachToProcess')

--------------------------------------------------------
--                   User actions                     --
--------------------------------------------------------

--
--- ∑ Terminates the attached process after confirmation.
--
function ProcessHandler:CloseProcess()
    if not inMainThread() then
        synchronize(function() self:CloseProcess() end)
        return
    end
    if not self:IsProcessAttached() then
        -- utils is a runtime dependency, so a table is entitled not to have it.
        -- Indexing it unguarded turned "nothing is attached", an ordinary state,
        -- into a hard crash.
        local message = "Not attached to a process!\nWhat do you expect me to close? :("
        if utils and type(utils.ShowError) == "function" then
            utils:ShowError(message)
        else
            logger:Error(MODULE_PREFIX .. " " .. message)
        end
        return
    end
    local processID = getOpenedProcessID()
    local message = string.format("Do you really want to terminate the process %s (PID: %d)?", process, processID)
    if messageDialog(message, mtConfirmation, mbYes, mbNo) == mrYes then
        os.execute(string.format("taskkill /PID %d /F", processID))
    end
end
registerLuaFunctionHighlight('CloseProcess')

--
--- ∑ Opens a link in the default handler after confirmation. Used by cheat
---   tables for things like steam://run/<appid>.
--- @param link string
--
function ProcessHandler:OpenLink(link)
    if not inMainThread() then
        synchronize(function() self:OpenLink(link) end)
        return
    end
    if messageDialog("Do you really want to open this link?\n" .. tostring(link),
                     mtConfirmation, mbYes, mbNo) == mrYes then
        ShellExecute(link)
    end
end
registerLuaFunctionHighlight('OpenLink')

--------------------------------------------------------
--                    Module End                      --
--------------------------------------------------------

return ProcessHandler
