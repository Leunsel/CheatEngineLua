--[[
    Bridges. Side-loading somebody else's log into this console.

    The front door is a channel. A script asks for one and logs into it:

        local log = ManifoldLogger:Channel("MyTool")
        log:Info("started", { version = 3 })

    Records arrive structured, with level, fields and a channel to filter on.
    New code should use that. A bridge is the back door, for producers that
    already log elsewhere and cannot be changed: the framework's
    Manifold.Logger, the Template Loader's Log, a script that calls print. It
    taps their output and rebuilds records from it, recovering the level from
    formatted text, which is lossy.

    Every bridge follows four rules. Attaching twice attaches once. Detach
    restores what was there, from state kept on the bridge rather than in a
    closure nobody can reach. The producer keeps working when the console is
    closed or was never opened. And a print capture next to a print sink
    cannot recurse, because of the Relaying latch here and the Emitting latch
    in Core.

    The framework bridge is polled. An autorun script runs at Cheat Engine
    startup, but a Cheat Table's logger appears when a table is opened, minutes
    later, again for every table, a NEW instance each time. Bridge:Watch runs a
    timer costing one rawget and two comparisons per tick. Cheat Engine has no
    table load callback, and a metatable on _G would see only the FIRST
    assignment to a global, since __newindex stops firing once the key exists.
]]

local Core = require("Manifold-Logger-Core")

local Bridge = {}
Bridge.__index = Bridge

--
--- ∑ Builds the bridge set for one log.
--- @param log table # A Manifold-Logger-Core instance.
--- @return table
--
function Bridge:New(log)
    return setmetatable({
        Log = log,
        Attached = {},     -- name -> restore state
        Relaying = false,  -- true while inside a producer's own output
        Watcher = nil,     -- the poll timer, see Bridge:Watch
        Notice = nil       -- the channel attach/detach notes go to
    }, Bridge)
end

--- The channel the bridge talks about itself on. Kept apart from the
--- producers' channels, so an attach note can be filtered out without also
--- hiding the producer's own log.
function Bridge:Channel()
    if not self.Notice then self.Notice = self.Log:Channel("Logger/Bridge") end
    return self.Notice
end

function Bridge:IsAttached(name) return self.Attached[name] ~= nil end

function Bridge:Names()
    local names = {}
    for name in pairs(self.Attached) do names[#names + 1] = name end
    table.sort(names)
    return names
end

--------------------------------------------------------
--                   Text reconstruction              --
--------------------------------------------------------

--
--- ∑ Pulls a level back out of an already formatted line.
---
---   Manifold.Logger and the Template Loader's Log both build lines as
---   "[HH:MM:SS] [LEVEL] rest", with an optional "[FORCED]" between the two.
---   That is deterministic, so parsing is safe here. Anything that does not
---   match keeps its whole text and is filed at the caller's default level, so
---   no line is lost to a failed match.
--- @param text string
--- @return string|nil, string, boolean # level, message, forced
--
function Bridge.Parse(text)
    text = tostring(text)
    local level, rest = text:match("^%[%d%d:%d%d:%d%d[%.%d]*%]%s+%[(%a+)%]%s*(.*)$")
    if not level then return nil, text, false end
    local forced = false
    local stripped = rest:match("^%[FORCED%]%s*(.*)$")
    if stripped then
        forced = true
        rest = stripped
    end
    local name = Core.ResolveLevel(level)
    if not name then return nil, text, false end
    return name, rest, forced
end

--------------------------------------------------------
--            Manifold.Logger (the framework)         --
--------------------------------------------------------

--
--- ∑ The name of the Cheat Table a framework logger belongs to, taken from
---   the log file it was told to write. Manifold.Logger:SetLogFileName builds
---   "Manifold.Runtime.<name>.log", so this reverses exactly that.
--- @param logger table
--- @return string|nil
--
function Bridge.TableName(logger)
    local name = type(logger) == "table" and logger.LogFileName or nil
    if type(name) ~= "string" then return nil end
    local match = name:match("^Manifold%.Runtime%.(.+)%.log$")
    if match == "Unknown" then return nil end
    return match
end

--
--- ∑ Taps the Cheat Table framework's logger. Two hooks, the better one first.
---
---   _DispatchLog is Manifold.Logger's single funnel. Every level helper,
---   every Force variant and every block ends up there, before the level
---   filter, with level, raw message and forced flag still separate. Shadowing
---   it on the INSTANCE, never on the class, mirrors losslessly and reverses
---   with one rawset, because the class method underneath is untouched.
---
---   SetOutput is the fallback for a framework version with no _DispatchLog.
---   It receives one formatted line, so the level is read back out of the
---   text, and it only sees what the framework's own filter let through.
---
---   _WriteToLogFile looks like a third option and is not one. Bootstrap calls
---   it directly to replay lines it queued before a logger existed, so a hook
---   there would mirror those twice.
---
---   Either way the framework keeps working as it did. The original is called
---   on every line and its output still reaches the Lua Engine window.
--- @param options table|nil # { Channel = "Framework", Logger = <instance> }
--- @return boolean, string|nil
--
function Bridge:AttachFramework(options)
    options = options or {}
    if self.Attached.framework then return true end
    local logger = options.Logger or rawget(_G, "logger")
    if type(logger) ~= "table" then
        return false, "no Manifold.Logger instance is loaded (the global 'logger')"
    end
    local channel = self.Log:Channel(options.Channel or "Framework")

    -- Preferred: the pre-filter funnel.
    local dispatch = logger._DispatchLog
    if type(dispatch) == "function" then
        -- Number to name. Manifold.Logger builds LevelNames at load time.
        -- Without it a raw numeric level reaches Core.ResolveLevel, which
        -- knows nothing of a foreign 1..5 scale and files every line at INFO.
        local names = logger.LevelNames
        if type(names) ~= "table" and type(logger.Levels) == "table" then
            names = {}
            for levelName, id in pairs(logger.Levels) do names[id] = levelName end
        end
        local hadOwn = rawget(logger, "_DispatchLog") ~= nil
        local relay
        relay = function(instance, level, message, forced)
            if self.Relaying then
                return dispatch(instance, level, message, forced)
            end
            self.Relaying = true
            local name = level
            if type(level) == "number" and type(names) == "table" then
                name = names[level]
            end
            -- Stringify is the framework's own renderer, so a table logged
            -- there reads the same in both windows.
            local text = message
            if type(text) ~= "string" and type(instance.Stringify) == "function" then
                local rendered, value = pcall(instance.Stringify, instance, message)
                text = rendered and value or tostring(message)
            end
            pcall(function()
                channel:Emit(name or "INFO", text, nil, { Forced = forced == true })
            end)
            -- The latch is held ACROSS the framework's dispatch, not just the
            -- mirror. That call ends in Output, normally print, so with the
            -- print capture on the line returns as a second, level-less record.
            local ok, err = pcall(dispatch, instance, level, message, forced)
            self.Relaying = false
            if not ok then error(err, 0) end
        end
        rawset(logger, "_DispatchLog", relay)
        self.Attached.framework = {
            Kind = "dispatch", Logger = logger, Relay = relay,
            Original = dispatch, HadOwn = hadOwn, Channel = channel
        }
        return true
    end

    -- Fallback: the formatted output.
    if type(logger.SetOutput) ~= "function" then
        return false, "the global 'logger' is not a Manifold.Logger"
    end
    local previous = logger.Output
    local relay = function(line)
        if self.Relaying then return end
        self.Relaying = true
        if type(previous) == "function" then pcall(previous, line) end
        self.Relaying = false
        local level, message, forced = Bridge.Parse(line)
        channel:Emit(level or "INFO", message, nil, { Forced = forced })
    end
    logger:SetOutput(relay)
    self.Attached.framework = {
        Kind = "output", Logger = logger, Previous = previous,
        Relay = relay, Channel = channel
    }
    return true
end

--
--- ∑ True while our hook is still the one installed. A table script that
---   calls SetOutput after we attached, and a framework reload that rebuilds
---   the instance, both read as not intact here. The watch then re-attaches on
---   top of whatever is there now.
--- @return boolean
--
function Bridge:FrameworkIntact()
    local state = self.Attached.framework
    if not state then return false end
    if state.Kind == "dispatch" then
        return rawget(state.Logger, "_DispatchLog") == state.Relay
    end
    return state.Logger.Output == state.Relay
end

function Bridge:DetachFramework()
    local state = self.Attached.framework
    if not state then return false end
    self.Attached.framework = nil
    -- Only restore when our hook is still the one in place. Putting an older
    -- handler back over a newer one would silence whoever installed it.
    if state.Kind == "dispatch" then
        if rawget(state.Logger, "_DispatchLog") == state.Relay then
            -- nil, not the captured function, when the instance had none of
            -- its own. Leaving a copy behind would shadow the class method and
            -- freeze this instance on today's implementation.
            rawset(state.Logger, "_DispatchLog", state.HadOwn and state.Original or nil)
        end
    elseif state.Logger.Output == state.Relay then
        state.Logger:SetOutput(state.Previous)
    end
    return true
end

--------------------------------------------------------
--                      The watch                     --
--------------------------------------------------------

Bridge.WatchInterval = 750   -- ms between polls, see the file header

--
--- ∑ Starts watching for a Cheat Table's framework logger. One rawget and two
---   comparisons per tick, and one attach when something has changed. The
---   timer is owned by Cheat Engine's main form, so it lives as long as Cheat
---   Engine does rather than as long as any window of ours.
--- @param options table|nil # { Interval, Channel, Announce }
--- @return boolean, string|nil
--
function Bridge:Watch(options)
    options = options or {}
    if self.Watcher then return true end
    local create = rawget(_G, "createTimer")
    if type(create) ~= "function" then return false, "createTimer is not available" end
    local owner
    local getMainForm = rawget(_G, "getMainForm")
    if type(getMainForm) == "function" then pcall(function() owner = getMainForm() end) end
    local ok, timer = pcall(create, owner)
    if not ok or not timer then return false, "createTimer failed" end
    self.WatchOptions = options
    pcall(function()
        timer.Interval = tonumber(options.Interval) or Bridge.WatchInterval
        timer.OnTimer = function() self:Poll() end
        timer.Enabled = true
    end)
    self.Watcher = timer
    -- A table may already be open when the watch starts. Do not make it wait a
    -- full interval to find out.
    self:Poll()
    return true
end

function Bridge:Unwatch()
    local timer = self.Watcher
    self.Watcher = nil
    if not timer then return false end
    pcall(function() timer.Enabled = false end)
    pcall(function() timer.destroy() end)
    return true
end

--
--- ∑ One tick of the watch. Reacts to four things: a framework logger
---   appearing, being replaced by a new instance, disappearing, and having
---   our hook overwritten by somebody else.
--- @return string|nil # What happened, when anything did.
--
function Bridge:Poll()
    local logger = rawget(_G, "logger")
    local state = self.Attached.framework
    local usable = type(logger) == "table"
        and (type(logger._DispatchLog) == "function" or type(logger.SetOutput) == "function")

    if not usable then
        if state then
            self:DetachFramework()
            self:Channel():Info("The Cheat Table's logger is gone. Mirroring stopped.")
            return "detached"
        end
        return nil
    end
    if state and state.Logger == logger and self:FrameworkIntact() then return nil end

    local replaced = state ~= nil
    if state then self:DetachFramework() end
    local options = self.WatchOptions or {}
    local attached, reason = self:AttachFramework({
        Channel = options.Channel, Logger = logger
    })
    if not attached then return nil, reason end
    if options.Announce == false then return replaced and "replaced" or "attached" end

    local kind = self.Attached.framework.Kind
    local name = Bridge.TableName(logger)
    self:Channel():Info(string.format(
        "Mirroring the Cheat Table's Manifold.Logger%s (%s hook)%s.",
        name and (" for " .. name) or "",
        kind,
        replaced and ", replacing the previous one" or ""))
    return replaced and "replaced" or "attached"
end

--------------------------------------------------------
--                   Template Loader                  --
--------------------------------------------------------

--
--- ∑ Taps the Template Loader's own log.
---
---   That one has a listener API, Log:AddListener, so this observes rather
---   than wraps. The loader's output is untouched and there is nothing to
---   restore. Its ring keeps entries below its own level and flags them
---   Suppressed. That flag is carried across, so a record the loader never
---   printed still arrives here marked as such.
--- @param options table|nil # { Channel = "TemplateLoader", Host = <host> }
--- @return boolean, string|nil
--
function Bridge:AttachTemplateLoader(options)
    options = options or {}
    if self.Attached.templateloader then return true end
    local host = options.Host or rawget(_G, "ManifoldTemplateLoaderHost")
    local loaderLog = nil
    pcall(function() loaderLog = host and host.Loader and host.Loader.Log or nil end)
    if type(loaderLog) ~= "table" or type(loaderLog.AddListener) ~= "function" then
        return false, "the Manifold Template Loader is not installed"
    end
    local channel = self.Log:Channel(options.Channel or "TemplateLoader")
    local names = loaderLog.LevelNames or {}
    local listener = function(entry)
        if type(entry) ~= "table" then return end
        local level = names[entry.Level] or "INFO"
        local _, message = Bridge.Parse(entry.Text or "")
        channel:Emit(level, message, nil, { Forced = not entry.Suppressed })
    end
    loaderLog:AddListener(listener)
    self.Attached.templateloader = { Log = loaderLog, Listener = listener }
    return true
end

function Bridge:DetachTemplateLoader()
    local state = self.Attached.templateloader
    if not state then return false end
    -- The loader's Log has ClearListeners but no RemoveListener, and clearing
    -- would also drop its own viewer's refresh hook. Only our entry is pulled
    -- out of the Listeners array.
    self.Attached.templateloader = nil
    local log = state.Log
    local listener = state.Listener
    for index, entry in ipairs(log.Listeners or {}) do
        if entry == listener then table.remove(log.Listeners, index) break end
    end
    return true
end

--------------------------------------------------------
--                        print                       --
--------------------------------------------------------

--
--- ∑ Captures everything anything prints.
---
---   The blunt instrument. Every Cheat Table script, every table Lua snippet
---   and every third-party autorun file prints, so with this on the console
---   becomes a searchable, filterable, persistent Lua Engine window.
---
---   Off by default. It makes the console responsible for output it has no
---   context for, and print is a global that other tools also wrap.
--- @param options table|nil # { Channel = "print", Level = "INFO" }
--- @return boolean, string|nil
--
function Bridge:AttachPrint(options)
    options = options or {}
    if self.Attached.print then return true end
    local previous = rawget(_G, "print")
    if type(previous) ~= "function" then return false, "print is not a function" end
    local channelName = options.Channel or "print"
    local channel = self.Log:Channel(channelName)
    local level = options.Level or "INFO"
    -- The print sink reads this to recognise its own echo.
    self.PrintChannelName = channelName
    local capture = function(...)
        -- Printing is unconditional, only RECORDING is latched. A line the
        -- print sink pushes out must reach the Lua Engine window, but must not
        -- return as a second record. AttachPrintSink breaks the other half.
        previous(...)
        if self.Relaying then return end
        -- print joins with tabs and stringifies each argument. Matching that
        -- keeps the console's copy identical to the Lua Engine's.
        local count = select("#", ...)
        local parts = {}
        for index = 1, count do parts[index] = tostring((select(index, ...))) end
        local text = table.concat(parts, "\t")
        local parsedLevel, message = Bridge.Parse(text)
        channel:Emit(parsedLevel or level, message)
    end
    rawset(_G, "print", capture)
    self.Attached.print = { Previous = previous, Capture = capture, Channel = channelName }
    return true
end

function Bridge:DetachPrint()
    local state = self.Attached.print
    if not state then return false end
    -- Only restore when we are still the outermost wrapper. Something else may
    -- have wrapped print after us, and putting the original back would unhook
    -- that too.
    if rawget(_G, "print") == state.Capture then
        rawset(_G, "print", state.Previous)
    end
    self.Attached.print = nil
    return true
end

--------------------------------------------------------
--                    Print sink                      --
--------------------------------------------------------

--
--- ∑ The other direction. Everything logged here also goes to Cheat Engine's
---   Lua Engine window.
---
---   This is the one thing that can form a loop with AttachPrint, so it has a
---   guard for each half. Relaying stops the line this sink prints from being
---   recorded again by the capture, without stopping it being printed. The
---   channel test below stops this sink echoing a record the capture itself
---   produced, which the capture already printed on its way in.
--- @param options table|nil # { Level, Render }
--- @return table
--
function Bridge:AttachPrintSink(options)
    options = options or {}
    local render = options.Render
    return self.Log:AddSink("print", {
        Level = options.Level,
        Write = function(_, record)
            if self.Attached.print and record.Channel == self.PrintChannelName then
                return
            end
            local text = render and render(record) or tostring(record.Message)
            self.Relaying = true
            pcall(print, text)
            self.Relaying = false
        end
    })
end

function Bridge:DetachPrintSink()
    return self.Log:RemoveSink("print")
end

--------------------------------------------------------
--                      Bulk                          --
--------------------------------------------------------

--
--- ∑ Attaches everything that is present, ignoring what is not.
--- @param options table|nil # { Framework, TemplateLoader, Print } booleans
--- @return table # name -> true, or the reason it did not attach
--
function Bridge:AttachAvailable(options)
    options = options or {}
    local report = {}
    if options.Framework ~= false then
        local ok, reason = self:AttachFramework()
        report.framework = ok or reason
    end
    if options.TemplateLoader ~= false then
        local ok, reason = self:AttachTemplateLoader()
        report.templateloader = ok or reason
    end
    if options.Print == true then
        local ok, reason = self:AttachPrint()
        report.print = ok or reason
    end
    return report
end

function Bridge:DetachAll()
    self:Unwatch()
    self:DetachFramework()
    self:DetachTemplateLoader()
    self:DetachPrint()
    self:DetachPrintSink()
end

return Bridge
