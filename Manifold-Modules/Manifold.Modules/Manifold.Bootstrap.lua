local NAME        = "Manifold.Bootstrap.lua"
local AUTHOR      = {"Leunsel", "LeFiXER"}
local VERSION     = "1.0.2"
local DESCRIPTION = "Manifold Framework Bootstrap - dependency lookup, module registry, collision detection"

--[[
    ∂ v1.0.2 (2026-08-27)
        Draining the pre-logger queue no longer forces every line.
        Only Warning and above are promoted; a queued Info is a
        startup banner and ReadyLevel already decides whether it
        shows. Manifold.Json and Manifold.Logger were the only two
        modules built before the logger, so they were the only
        banners that ignored that setting.

    ∂ v1.0.0 (2026-08-23)
        Initial release. One dependency lookup for every production module.
        Replaces the six divergent CheckDependencies variants (TODO R-B) and
        closes TODO T4 structurally: nothing in this file ever indexes the
        logger without a guard.

        This file requires nothing and declares nothing. It is the framework
        root, below Manifold.Json.

    Contract, in five lines:
      1. Bootstrap.KNOWN and Bootstrap.ORDER are the only place that knows how
         a Manifold module is found, built and sequenced.
      2. A module declares itself once at chunk scope (Bootstrap.Declare),
         gates its New() once (Bootstrap.Resolve) and closes its New() once
         (Bootstrap.Ready).
      3. Bootstrap.Ready emits EXACTLY ONE line per module per generation,
         carrying NAME and VERSION. Info when every declared dependency is
         satisfied, Warning when the module came up degraded. Never both, and
         never one line per dependency.
      4. Collisions are reported on their own lines, at their own severity,
         because a collision is not the routine event the ready line describes.
      5. CETrequire has no module cache (TODO R-C), so a second require
         re-executes a module file and orphans every live instance built from
         the old table (TODO T7). This file cannot prevent that from the
         outside; it prevents the requires it controls, and makes the ones it
         does not control VISIBLE.

    Naming: this is a namespace, not a class, so its functions are dot-called
    (Bootstrap.Ready) rather than colon-called. There is nothing to instantiate.
]]--

--
--- ∑ Local alias so the core stays usable outside of Cheat Engine (unit tests,
---   a bare lua.exe). Manifold.Logger calls the real function unguarded; the
---   framework root must not.
--
local registerLuaFunctionHighlight = rawget(_G, "registerLuaFunctionHighlight") or function() end

local MODULE_PREFIX = "[Bootstrap]"
local REGISTRY_KEY  = "__ManifoldBootstrapRegistry"
local ABI           = 1
local MAX_PENDING   = 128

--------------------------------------------------------
--          Reload-surviving singleton state          --
--------------------------------------------------------

--
--- ∑ CETrequire runs dofile/load on EVERY call, so this file is re-executed
---   whenever anything requires it again. Everything that must survive that
---   lives in one _G slot reached with rawget/rawset - the same pattern
---   Manifold.UI already uses for __ManifoldThemeApplyLock (Manifold.UI.lua:52).
---
---   REG.Api is the table published as _G.ManifoldBootstrap. It is created ONCE
---   and MUTATED IN PLACE on every later execution. That is what keeps a
---   module's captured `local BOOTSTRAP = ...` valid after a core reload: the
---   table identity never changes, only the functions hanging off it. A core
---   that orphaned its own consumers would be the very collision it exists to
---   detect.
--
local REG = rawget(_G, REGISTRY_KEY)
if type(REG) ~= "table" or REG.ABI ~= ABI then
    REG = {
        ABI          = ABI,
        Api          = {},     -- identity-stable API table
        Modules      = {},     -- class name -> descriptor, shared across generations
        Declared     = {},     -- class names, in declaration order
        Configs      = {},     -- instance name -> constructor config
        Pending      = {},     -- log lines produced before a logger existed
        Loading      = {},     -- instance name -> true, load re-entrancy guard
        Once         = {},     -- one-shot latches (Bootstrap.Once)
        OrphanSeen   = {},     -- instance name -> true, so orphan warnings do not repeat
        Unrecorded   = {},     -- emitted to console before the log file existed
        ReloadBatch  = {},     -- class names re-executed this generation
        DuplicateBatch = {},   -- class names re-declared on the same chunk
        ReloadGen    = 0,      -- generation the batches belong to
        ReloadSaid   = 0,      -- generation whose summary has been emitted
        LogBusy      = false,  -- logging re-entrancy guard
        CoreLoads    = 0,
    }
    rawset(_G, REGISTRY_KEY, REG)
end
-- Defensive: a registry of the same ABI may predate a field added here.
REG.Modules    = type(REG.Modules)    == "table" and REG.Modules    or {}
REG.Declared   = type(REG.Declared)   == "table" and REG.Declared   or {}
REG.Configs    = type(REG.Configs)    == "table" and REG.Configs    or {}
REG.Pending    = type(REG.Pending)    == "table" and REG.Pending    or {}
REG.Loading    = type(REG.Loading)    == "table" and REG.Loading    or {}
REG.Once       = type(REG.Once)       == "table" and REG.Once       or {}
REG.OrphanSeen = type(REG.OrphanSeen) == "table" and REG.OrphanSeen or {}
REG.Unrecorded = type(REG.Unrecorded) == "table" and REG.Unrecorded or {}
REG.ReloadBatch    = type(REG.ReloadBatch)    == "table" and REG.ReloadBatch    or {}
REG.DuplicateBatch = type(REG.DuplicateBatch) == "table" and REG.DuplicateBatch or {}
REG.ReloadGen  = REG.ReloadGen  or 0
REG.ReloadSaid = REG.ReloadSaid or 0
REG.CoreLoads  = (REG.CoreLoads or 0) + 1

--
--- ∑ Severity of each line this core can produce. Lives in the registry so a
---   cheat table can set it once and a core reload cannot undo it.
---
---   ReadyLevel deserves a word. Logger:New() defaults to Levels.ERROR
---   (Manifold.Logger.lua:22), so a plain "Info" ready line reaches the log
---   FILE but not the console until the level is raised. The documented setup
---   (docs/Manifold-Framework.md, 2.2) already calls
---   logger:SetLevel(logger.Levels.INFO), which is the intended fix. If a table
---   deliberately runs at ERROR and still wants the banners on screen, set this
---   to "ForceInfo" - Manifold.Logger registers a Force<Level> variant for
---   every level (Manifold.Logger.lua:332) and it bypasses the filter.
--
REG.Settings = REG.Settings or {
    --- Plain Info, so the manifest RESPECTS the console level the cheat table
    --- chose. The corollary is that the table script must not clamp the level
    --- before the modules are constructed: calling
    --- logger:SetLevel(Levels.ERROR) directly after Logger:New() filters every
    --- Info line for the rest of the boot and the manifest disappears. Keep the
    --- level permissive while constructing and clamp it at the END, in the
    --- IsRelease branch. The log FILE receives the manifest either way -
    --- Logger:_DispatchLog writes before it filters.
    --- Set this to "ForceInfo" if you want the manifest on screen regardless
    --- of the level; Manifold.Logger registers a Force variant for each level.
    ReadyLevel    = "Info",      -- every declared dependency satisfied
    DegradedLevel = "Warning",   -- came up without an optional dependency
    ReloadLevel   = "Warning",   -- the same file was executed again
    ConflictLevel = "Error",     -- a DIFFERENT file or version claimed a name

    --- REFUSE AND REPORT.
    --- false (the default): Bootstrap.Resolve never loads anything. A missing
    --- dependency is reported and, when it is `required`, New() refuses. The
    --- cheat table's Lua script stays the single source of truth for what is
    --- loaded and in what order, which is the only way the order of execution
    --- can mean anything.
    --- Setting this true restores the pre-Bootstrap behaviour, where a module
    --- silently pulled in whatever it was missing - which is how Manifold.Forms
    --- and Manifold.Trampolines used to appear in tables that never asked for
    --- them.
    --- This gates the IMPLICIT path only. Bootstrap.Acquire and Bootstrap.Get
    --- are explicit lookups and always load; that is their purpose, and it is
    --- what stops the lazy call sites from minting a second Trampolines.
    AutoLoad      = false,
}

local Bootstrap = REG.Api

Bootstrap.NAME     = NAME
Bootstrap.VERSION  = VERSION
Bootstrap.Registry = REG
Bootstrap.Settings = REG.Settings

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--------------------------------------------------------
--                  Guarded logging                   --
--------------------------------------------------------

--
--- ∑ The only place in the framework allowed to touch the logger during
---   bootstrap. It survives three things the current CheckDependencies bodies
---   do not:
---     - the logger not existing yet (TODO T4): lines are queued, never thrown;
---     - a logger that raises: every dispatch is pcall'd;
---     - re-entrant logging: REG.LogBusy is a hard latch, not a counter.
---
---   There is deliberately no print() fallback. A logger-less run stays silent
---   for the same reason Manifold.Json documents at :108-110 - a print fallback
---   would spam every standalone and unit-test run, and the queue means nothing
---   is lost anyway.
--- @return table|nil
--
--
--- ∑ Queued levels that are promoted to their Force variant when the queue
---   drains. A warning or an error produced before any logger existed would
---   otherwise be lost for good, and nobody could have chosen a level for it.
---
---   Info and Debug are deliberately absent. A queued Info is a startup banner,
---   and ReadyLevel exists precisely so the console level decides whether it
---   shows. Promoting it made Manifold.Json and Manifold.Logger - the only two
---   modules built before the logger - the only banners that ignored that
---   setting, and stamped them [FORCED] into the bargain. The log FILE keeps
---   them either way: Logger:_DispatchLog writes before it filters.
--
local FORCE_ON_FLUSH = { Warning = true, Error = true, Critical = true }

local function _logger()
    local lg = rawget(_G, "logger")
    if type(lg) == "table" and type(lg.Info) == "function" then return lg end
    return nil
end

--
--- ∑ Replays lines that reached the console while the log FILE was still
---   unavailable. Logger:_WriteToLogFile needs the global customIO, and the
---   first modules in ORDER are constructed before customIO exists - so
---   without this the manifest in a submitted log file is missing exactly the
---   entries for Manifold.Json and Manifold.Logger.
---   Replayed straight into the file writer, so nothing is duplicated on the
---   console.
--
local function _recordMissed(lg)
    local missed = REG.Unrecorded
    if #missed == 0 or rawget(_G, "customIO") == nil then return end
    if type(lg._WriteToLogFile) ~= "function" or type(lg._FormatLogMessage) ~= "function" then
        REG.Unrecorded = {}
        return
    end
    REG.Unrecorded = {}
    for index = 1, #missed do
        local entry = missed[index]
        local ok, line = pcall(lg._FormatLogMessage, lg, entry[1], entry[2], false)
        if ok then pcall(lg._WriteToLogFile, lg, line) end
    end
end

local function _emit(lg, level, message)
    local fn = lg[level]
    if type(fn) ~= "function" then fn = lg.Info end
    if type(fn) ~= "function" then return false end
    -- Replay first, so the recovered lines land in the file in their original
    -- order rather than after whichever line happened to trigger the replay.
    _recordMissed(lg)
    pcall(fn, lg, message)
    -- The file sink is not up until customIO exists. Remember what it missed.
    if rawget(_G, "customIO") == nil then
        local missed = REG.Unrecorded
        if #missed < MAX_PENDING then
            -- Force<Level> is a console concept; the log file records the plain
            -- level, upper-cased to match Logger.LevelNames.
            missed[#missed + 1] = { (level:gsub("^Force", "")):upper(), message }
        end
    end
    return true
end

--
--- ∑ Replays every line queued before a logger existed, oldest first. Safe to
---   call at any time; a no-op when there is nothing to say or nobody to say it
---   to.
--- @return integer # lines flushed
--
function Bootstrap.Flush()
    local pending = REG.Pending
    local count = #pending
    if count == 0 or REG.LogBusy then return 0 end
    local lg = _logger()
    if not lg then return 0 end
    REG.LogBusy = true
    -- Swap the queue out BEFORE draining: a logger that logs back into the core
    -- then appends to a fresh table instead of mutating the one being walked.
    REG.Pending = {}
    for index = 1, count do
        -- Only queued lines are promoted, and only the ones that report a
        -- problem: those were produced before any logger existed and would be
        -- lost otherwise. A level the caller already asked to force (ReadyLevel
        -- = "ForceInfo", say) is left exactly as it is.
        local level = pending[index][1]
        if not level:match("^Force") and FORCE_ON_FLUSH[level] and lg["Force" .. level] then
            level = "Force" .. level
        end
        _emit(lg, level, pending[index][2])
    end
    REG.LogBusy = false
    return count
end
registerLuaFunctionHighlight('Flush')

--
--- ∑ Queue-then-drain. Ordering is preserved whether or not a logger exists at
---   the moment a line is produced, which is what lets Manifold.Json (ORDER #1,
---   before any logger) still get its banner.
--- @param level string
--- @param message string
--
local function _log(level, message)
    -- A live logger and nothing deferred: emit straight away, at the plain
    -- level, so the cheat table's console level applies normally. Only lines
    -- produced while NO logger exists take the queue - and those are the ones
    -- Flush is entitled to force, because nobody could have chosen a level for
    -- them yet.
    local lg = _logger()
    if lg ~= nil and #REG.Pending == 0 and not REG.LogBusy then
        _emit(lg, level, message)
        return
    end

    local pending = REG.Pending
    local count = #pending
    if count < MAX_PENDING then
        pending[count + 1] = { level, message }
    elseif count == MAX_PENDING then
        pending[count + 1] = { "Warning", MODULE_PREFIX .. " deferred log buffer full; later pre-logger lines dropped." }
    end
    Bootstrap.Flush()
end

--
--- ∑ Renders a titled block of label/value rows into one string, so a report
---   becomes one log entry instead of one prefixed line per field.
---
---   Delegates to Logger:BuildBlock whenever a logger exists, so the shape stays
---   identical to every other module's blocks and only has to be maintained in
---   one place. The fallback is not optional: this file runs before
---   Manifold.Logger is constructed, and PrintModuleInfo is callable at any
---   point, that one included.
--- @param title string|nil # First line, module prefix included by the caller.
--- @param rows table # {label, value} pairs. Use `false` to skip a row, never nil.
--- @param options table|nil # { indent, separator, align }, as Logger:BuildBlock.
--- @return string
--
local function _block(title, rows, options)
    local lg = _logger()
    if lg ~= nil and type(lg.BuildBlock) == "function" then
        return lg:BuildBlock(title, rows, options)
    end
    options = options or {}
    local indent = options.indent or "   "
    local separator = options.separator or " : "
    local align = options.align ~= false
    local labelWidth = 0
    if align then
        for _, row in ipairs(rows or {}) do
            if row and #tostring(row[1]) > labelWidth then labelWidth = #tostring(row[1]) end
        end
    end
    local lines = {}
    if title ~= nil and tostring(title) ~= "" then lines[#lines + 1] = tostring(title) end
    for _, row in ipairs(rows or {}) do
        if row then
            local label = tostring(row[1])
            if #label < labelWidth then label = label .. string.rep(" ", labelWidth - #label) end
            lines[#lines + 1] = indent .. label .. separator .. tostring(row[2])
        end
    end
    return table.concat(lines, "\n")
end

--
--- ∑ Runs fn exactly once per Lua state, latched in the reload-surviving
---   registry so a re-executed module file cannot reset it.
---
---   This is for load-time side effects that must not stack. Manifold.Callbacks
---   chains AddressList.OnAutoAssemblerEdit (:347-348) and LuaEngine.OnShow
---   (:376-378) on top of whatever was there, so every re-require adds a
---   permanent wrapper layer and the chain grows without bound.
--- @param key string
--- @param fn function
--- @return boolean # true when fn ran now
--
function Bootstrap.Once(key, fn)
    if type(key) ~= "string" or type(fn) ~= "function" then return false end
    if REG.Once[key] then return false end
    REG.Once[key] = true
    local ok, err = pcall(fn)
    if not ok then
        REG.Once[key] = nil
        _log("Error", string.format("%s one-shot '%s' failed: %s", MODULE_PREFIX, key, tostring(err)))
        return false
    end
    return true
end
registerLuaFunctionHighlight('Once')

--------------------------------------------------------
--          KNOWN - what a Manifold module is         --
--------------------------------------------------------

--
--- ∑ The single source of truth for how a module is found and built.
---     path      CETrequire argument
---     class     global name of the module TABLE the file assigns
---     construct how the instance is built, given the cheat table's config
---     contract  optional predicate every consumer gets for free. This is where
---               the forms.CreatePanel gate that Manifold.UI (:234-237) and
---               Manifold.Teleporter (:153-155) each hand-roll a copy of is
---               stated ONCE.
---     rebuild   true only for modules that hold no live state and may
---               therefore be safely reconstructed after a reload.
--
Bootstrap.KNOWN = {
    json = {
        path = "Manifold.Json", class = "Json", rebuild = true,
        construct = function() return Json:New() end,
        contract  = function(i) return type(i.Encode) == "function" and type(i.Decode) == "function" end,
    },
    logger = {
        path = "Manifold.Logger", class = "Logger", rebuild = false,
        construct = function(config)
            local instance = Logger:New()
            if type(config) == "table" then
                if config.LogFileName then instance:SetLogFileName(config.LogFileName) end
                if config.Level       then instance:SetLevel(config.Level)             end
                if config.Output      then instance:SetOutput(config.Output)           end
            end
            return instance
        end,
        contract = function(i) return type(i.Info) == "function" and type(i.Error) == "function" end,
    },
    customIO = {
        path = "Manifold.CustomIO", class = "CustomIO", rebuild = false,
        construct = function() return CustomIO:New() end,
        contract  = function(i)
            return type(i.DirectoryExists) == "function"
               and type(i.CreateDirectory) == "function"
               and type(i.AppendToFile)    == "function"
        end,
    },
    helper = {
        path = "Manifold.Helper", class = "Helper", rebuild = true,
        construct = function() return Helper:New() end,
    },
    memory = {
        path = "Manifold.Memory", class = "Memory", rebuild = true,
        construct = function() return Memory:New() end,
    },
    forms = {
        path = "Manifold.Forms", class = "Forms", rebuild = false,
        construct = function(config) return Forms:New(config) end,
        contract  = function(i) return type(i.CreatePanel) == "function" end,
    },
    utils = {
        path = "Manifold.Utils", class = "Utils", rebuild = false,
        construct = function(config) return Utils:New(config) end,
    },
    processHandler = {
        path = "Manifold.ProcessHandler", class = "ProcessHandler", rebuild = false,
        construct = function(config) return ProcessHandler:New(config) end,
    },
    ui = {
        path = "Manifold.UI", class = "UI", rebuild = false,
        construct = function(config) return UI:New(config) end,
    },
    state = {
        path = "Manifold.State", class = "State", rebuild = false,
        construct = function() return State:New() end,
    },
    trampolines = {
        path = "Manifold.Trampolines", class = "Trampolines", rebuild = false,
        construct = function() return Trampolines:New() end,
    },
    assemblerCommands = {
        path = "Manifold.AssemblerCommands", class = "AssemblerCommands", rebuild = false,
        construct = function() return AssemblerCommands:New() end,
    },
    autoAssembler = {
        path = "Manifold.AutoAssembler", class = "AutoAssembler", rebuild = false,
        construct = function(config)
            local instance = AutoAssembler:GetInstance()
            if type(config) == "table" and config.ProcessName
               and type(instance.SetProcessName) == "function" then
                instance:SetProcessName(config.ProcessName)
            end
            return instance
        end,
    },
    teleporter = {
        path = "Manifold.Teleporter", class = "Teleporter", rebuild = false,
        construct = function(config) return Teleporter:New(config) end,
    },
    callbacks = {
        path = "Manifold.Callbacks", class = "Callbacks", rebuild = false,
        construct = function() return Callbacks:New() end,
    },
}

--
--- ∑ THE order of execution. Editing this array is the only supported way to
---   change load order.
---
---   It is a topological sort over LOAD-TIME edges only. Runtime-only edges are
---   declared `runtime = true` by the modules themselves and constrain nothing,
---   which is what makes the framework's cycles harmless:
---     UI <-> Teleporter  - both edges guarded and runtime-only, no constraint
---     AutoAssembler <-> ProcessHandler - back edge is rawget-guarded, runtime
---     Utils -> UI        - one-directional; the apparent back edge at
---                          Manifold.UI.lua:1205 is inside the [=[ ]=] long
---                          string opened at :1200, i.e. generated AA script
---                          text, not a reference in UI's chunk
---
---   Two hand-injected constraints the pure topological pass does not produce:
---     logger BEFORE customIO - CustomIO's json-miss path indexes logger
---                              unguarded (Manifold.CustomIO.lua:98)
---     callbacks LAST         - its chunk binds CE handlers at load time
--
Bootstrap.ORDER = {
    "json", "logger", "customIO", "helper", "memory", "forms",
    "processHandler", "ui", "utils", "state", "trampolines",
    "assemblerCommands", "autoAssembler", "teleporter", "callbacks",
}

--- Why utils sits AFTER ui, though nothing forces it to:
--- utils:InitializeTable() (Manifold.Utils.lua:620) calls ui:InitializeForm().
--- That is a runtime edge, so it constrains nothing at construction - but a
--- cheat table that groups each module's require, New and setup together would
--- otherwise have to hoist that one call out of the Utils block. Utils declares
--- only `logger` as required, so it is free to sit anywhere after the logger,
--- and putting it here lets the setup stay where it belongs. ProcessHandler
--- declares `utils` runtime (:102), so moving utils later costs nothing.

--------------------------------------------------------
--                   Introspection                    --
--------------------------------------------------------

--
--- ∑ short_src of the chunk `level` frames up.
---
---   Deliberately NOT pcall'd: pcall inserts a C frame and shifts every level
---   by one, which would make every module report this file as its source.
---   debug.getinfo returns nil past the top of the stack, it does not raise, so
---   a direct call with a positive literal level is both correct and safe.
--- @param level integer
--- @return string
--
--
--- ∑ Reduces a chunk source to something a log line can carry.
---   In a release table the modules are embedded table files loaded through
---   load() with no chunk name, so short_src is the entire FIRST LINE of the
---   file - enormous and useless. Name it for what it is instead. On disk,
---   keep only the file name; the directory is the same for every module.
--- @param src string|nil
--- @return string
--
local function _shortSource(src)
    if type(src) ~= "string" or src == "" then return "?" end
    if src:sub(1, 8) == "[string " then return "embedded" end
    return src:match("([^/\\]+)$") or src
end

local function _chunkSource(level)
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then return "?" end
    local info = debug.getinfo(level, "S")
    if type(info) ~= "table" then return "?" end
    return _shortSource(info.short_src)
end

--
--- ∑ Splits a list of names into short, indented continuation lines so a
---   fifteen-module roster never becomes one unreadable line.
--- @param items table
--- @param width integer
--- @return table # list of strings
--
local function _wrapList(items, width)
    local lines, current = {}, nil
    for index = 1, #items do
        local item = tostring(items[index])
        if current == nil then
            current = item
        elseif #current + #item + 2 <= width then
            current = current .. ", " .. item
        else
            lines[#lines + 1] = current
            current = item
        end
    end
    if current then lines[#lines + 1] = current end
    return lines
end

Bootstrap.SOURCE = _chunkSource(2)

--
--- ∑ The USABILITY half of validation: does this value answer the calls its
---   consumers make?
--- @param key string
--- @param value any
--- @param extra function|nil # the caller's own validate predicate
--- @return boolean, string|nil
--
function Bootstrap.Contract(key, value, extra)
    if value == nil then return false, "absent" end
    local spec = Bootstrap.KNOWN[key]
    if spec and type(spec.contract) == "function" then
        local ok, result = pcall(spec.contract, value)
        if not ok or result ~= true then
            return false, "does not satisfy its contract (an older copy of " .. tostring(spec.path) .. "?)"
        end
    end
    if type(extra) == "function" then
        local ok, result = pcall(extra, value)
        if not ok or result ~= true then
            return false, "failed the caller's validate()"
        end
    end
    return true
end
registerLuaFunctionHighlight('Contract')

--
--- ∑ Contract PLUS identity: is this global still a pristine instance of the
---   module table that is loaded right now?
---
---   The metatable test is the concrete detector for TODO T7. Every Manifold
---   constructor is `setmetatable({}, self)` with self being the class global,
---   so an instance whose metatable is no longer the CURRENT class table was
---   built by a chunk that has since been re-executed. It still answers method
---   calls, against an orphaned copy of the class - precisely the silent
---   failure this core exists to make loud.
--- @param key string
--- @param value any
--- @param extra function|nil
--- @return boolean, string|nil
--
function Bootstrap.Validate(key, value, extra)
    if value == nil then return false, "absent" end
    local spec = Bootstrap.KNOWN[key]
    if spec == nil then return Bootstrap.Contract(key, value, extra) end
    if type(value) ~= "table" then return false, "not a table" end
    local class = rawget(_G, spec.class)
    if type(class) ~= "table" then return false, "class global '" .. spec.class .. "' is gone" end
    local ok, mt = pcall(getmetatable, value)
    if not ok or mt ~= class then
        return false, "orphaned (built before '" .. spec.path .. "' was re-executed)"
    end
    return Bootstrap.Contract(key, value, extra)
end
registerLuaFunctionHighlight('Validate')

--------------------------------------------------------
--                    Acquisition                     --
--------------------------------------------------------

--
--- ∑ The sanctioned replacement for a bare pcall(CETrequire, path).
---
---   CETrequire re-executes the file on every call (TODO R-C). This skips the
---   call entirely when the module table is already present, which is the only
---   collision PREVENTION available without patching CETrequire itself.
---   CETrequire also returns nil silently for a module it cannot find
---   (docs/Manifold-Framework.md), so a typo'd path becomes a real error here
---   instead of surfacing later as "attempt to index a nil value".
--- @param path string
--- @param class string
--- @param force boolean|nil # re-execute even when present (development only)
--- @return table|nil, string|nil
--
function Bootstrap.Require(path, class, force)
    if not force and type(rawget(_G, class)) == "table" then
        return rawget(_G, class)
    end
    local requireFn = rawget(_G, "CETrequire")
    if type(requireFn) ~= "function" then
        return nil, "CETrequire is not available in this Lua state"
    end
    local ok, err = pcall(requireFn, path)
    if not ok then return nil, tostring(err) end
    local moduleTable = rawget(_G, class)
    if type(moduleTable) ~= "table" then
        return nil, string.format("'%s' did not define the global '%s' (missing file or typo'd path)", path, class)
    end
    return moduleTable
end
registerLuaFunctionHighlight('Require')

--
--- ∑ Guarantees that `key` names a live, usable instance in _G, loading and
---   constructing it only if it genuinely is not there.
---
---   This is THE dependency lookup. Lazy runtime call sites must use it instead
---   of calling Class:New() - AutoAssembler:_getTrampolineApi (:484-500) and
---   AssemblerCommands:_getTrampolines (:992-999) otherwise mint a second
---   Trampolines whose detour store is empty while the first still holds live
---   hooks.
--- @param key string
--- @param config table|nil
--- @return table|nil, string|nil
--
function Bootstrap.Acquire(key, config)
    local spec = Bootstrap.KNOWN[key]
    if spec == nil then
        return nil, string.format("'%s' is not a known Manifold module", tostring(key))
    end
    local current = rawget(_G, key)
    local valid, why = Bootstrap.Validate(key, current)
    if valid then return current end
    if current == nil then
        -- The global was lost but the registry still holds the instance:
        -- republish the SAME object rather than building a second one behind
        -- live state.
        -- Only when the module TABLE is still loaded. If the class global is
        -- gone too, this is a teardown (Bootstrap.Reload) and the module has to
        -- be re-required, not resurrected.
        local mod = REG.Modules[spec.class]
        if mod and mod.instance ~= nil and type(rawget(_G, spec.class)) == "table"
           and Bootstrap.Contract(key, mod.instance) then
            rawset(_G, key, mod.instance)
            _log("Warning", string.format("%s global '%s' had been lost; republished the registered instance.",
                                          MODULE_PREFIX, key))
            return mod.instance
        end
    else
        local usable = Bootstrap.Contract(key, current)
        if not usable then
            -- Present but genuinely unusable. Rebuilding cannot fix a version
            -- mismatch, so do not churn a live object; hand it back with the
            -- reason and let the consumer's own gate decide whether that is
            -- fatal.
            _log("Error", string.format("%s '%s' is present but %s", MODULE_PREFIX, key, tostring(why)))
            return current, why
        elseif not spec.rebuild then
            -- Orphaned by a reload, but it still answers its calls.
            -- Reconstructing would silently drop whatever live state it holds
            -- (Trampolines.ActiveDetours, ProcessHandler's attachment, UI's
            -- theme lock), so keep it and say so - once.
            if not REG.OrphanSeen[key] then
                REG.OrphanSeen[key] = true
                _log("Warning", string.format(
                    "%s ORPHAN: '%s' survived a re-execution; keeping it. Reload('%s') for a clean one.",
                    MODULE_PREFIX, key, key))
            end
            return current
        end
    end
    if REG.Loading[key] then
        return rawget(_G, key), string.format("re-entrant load of '%s' (a load-time cycle reached it again)", key)
    end
    REG.Loading[key] = true
    local class, failure = Bootstrap.Require(spec.path, spec.class)
    local instance
    if class ~= nil then
        local ok, built = pcall(spec.construct, config or REG.Configs[key])
        if not ok then
            failure = tostring(built)
        elseif type(built) ~= "table" then
            failure = string.format("the constructor for '%s' returned %s", key, type(built))
        else
            instance = built
        end
    end
    REG.Loading[key] = nil
    if instance == nil then return nil, failure end
    REG.OrphanSeen[key] = nil
    rawset(_G, key, instance)
    return instance
end
registerLuaFunctionHighlight('Acquire')

--
--- ∑ Read-first lookup for runtime call sites. Same as Acquire, named for the
---   place it is used.
--- @param key string
--- @return table|nil, string|nil
--
function Bootstrap.Get(key)
    return Bootstrap.Acquire(key)
end
registerLuaFunctionHighlight('Get')

--
--- ∑ Teaches the core about a module that is not in KNOWN - a Manifold.Dev
---   tool, a fork, a project-specific module. It then gets the same lookup, the
---   same collision detection and the same ready line, but no position in the
---   order of execution. Never overwrites an existing entry.
--- @param key string # instance global name
--- @param spec table # {path, class, construct?, contract?, rebuild?}
--- @return table|nil, string|nil
--
function Bootstrap.Register(key, spec)
    if type(key) ~= "string" or type(spec) ~= "table" then
        return nil, "Bootstrap.Register(key, spec) expects a string and a table"
    end
    if type(spec.path) ~= "string" or type(spec.class) ~= "string" then
        return nil, "a module spec needs 'path' and 'class'"
    end
    if Bootstrap.KNOWN[key] ~= nil then return Bootstrap.KNOWN[key] end
    spec.construct = spec.construct or function(config)
        local class = rawget(_G, spec.class)
        return class and class:New(config)
    end
    spec.rebuild = spec.rebuild == true
    Bootstrap.KNOWN[key] = spec
    return spec
end
registerLuaFunctionHighlight('Register')

--
--- ∑ Stores the constructor config for a module so that a LAZY bring-up gets
---   the configuration the cheat table intended. Call before Bootstrap.Boot().
--- @param key string
--- @param config table
--- @return table # Bootstrap, for chaining
--
function Bootstrap.Configure(key, config)
    REG.Configs[key] = config
    return Bootstrap
end
registerLuaFunctionHighlight('Configure')

--------------------------------------------------------
--                    Declaration                     --
--------------------------------------------------------

local function _normalizeDeps(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for index = 1, #list do
        local raw = list[index]
        local dep
        if type(raw) == "string" then
            dep = { name = raw }
        elseif type(raw) == "table" then
            dep = {
                name     = raw.name or raw[1],
                config   = raw.config,
                validate = raw.validate,
                required = raw.required == true,
                runtime  = raw.runtime == true,
            }
            -- Escape hatch: a dep may teach the core about a module that is not
            -- in KNOWN by carrying path/class inline (dev tools, forks).
            if dep.name and raw.path and raw.class then
                Bootstrap.Register(dep.name, {
                    path = raw.path, class = raw.class, construct = raw.construct,
                    contract = raw.contract, rebuild = raw.rebuild,
                })
            end
        end
        if dep and type(dep.name) == "string" then
            out[#out + 1] = dep
        end
    end
    return out
end

--
--- ∑ Declared once at chunk scope by every production module, right under its
---   MODULE_PREFIX local. The descriptor table is created once per class name
---   and MUTATED on later generations, so a `local MODULE` captured by an older
---   closure stays valid.
---
---   This function is also the collision DETECTOR: it runs on every execution
---   of the module file, so a second execution is visible here and nowhere
---   else. Three cases, at three severities, because they are not equally bad:
---     CONFLICT  a different file or version claimed this name - never benign
---     RELOAD    the same file ran again - normal during development
---     DUPLICATE the same chunk declared twice without re-execution
--- @param spec table # {class, global, name, version, author, description, prefix, deps}
---        class  global name of the module TABLE    ("State")
---        global global name of the INSTANCE        ("state")
--- @return table # the descriptor, passed later to Resolve and Ready
--
function Bootstrap.Declare(spec)
    if type(spec) ~= "table" then
        error(MODULE_PREFIX .. " Bootstrap.Declare expects a table.", 2)
    end
    local className = spec.class
    if type(className) ~= "string" or className == "" then
        error(MODULE_PREFIX .. " Bootstrap.Declare needs a 'class' (the module table's global name).", 2)
    end
    local version = tostring(spec.version or "?")
    local source  = spec.source or _chunkSource(3)   -- _chunkSource <- Declare <- module chunk
    local class   = rawget(_G, className)
    local label   = tostring(spec.name or className)
    -- Roster lines list many modules at once, so they use the bare class name
    -- rather than the full file name.
    local short   = tostring(className)
    local mod     = REG.Modules[className]
    if mod == nil then
        mod = { className = className, generation = 0, firstSource = source }
        REG.Modules[className] = mod
        REG.Declared[#REG.Declared + 1] = className
    elseif mod.version ~= version or mod.source ~= source then
        _log(REG.Settings.ConflictLevel, string.format(
            "%s CONFLICT: '%s' was v%s (%s), now v%s (%s) - two files claim this global.",
            MODULE_PREFIX, label, tostring(mod.version), tostring(mod.source), version, source))
    elseif mod.class ~= nil and mod.class ~= class then
        -- Re-running the table script re-executes all fifteen files at once, so
        -- one warning per module is fifteen near-identical lines. Batch them and
        -- let the first Ready of the generation emit a single short summary.
        if REG.ReloadGen ~= mod.generation + 1 then
            -- A new generation: drop whatever the previous one left behind, so
            -- the roster never accumulates across re-runs.
            REG.ReloadBatch, REG.DuplicateBatch = {}, {}
            REG.ReloadGen = mod.generation + 1
        end
        REG.ReloadBatch[#REG.ReloadBatch + 1] = short
    else
        if REG.ReloadGen ~= mod.generation + 1 then
            REG.ReloadBatch, REG.DuplicateBatch = {}, {}
            REG.ReloadGen = mod.generation + 1
        end
        REG.DuplicateBatch[#REG.DuplicateBatch + 1] = short
    end
    mod.generation  = mod.generation + 1
    mod.name        = label
    mod.version     = version
    mod.author      = spec.author
    mod.description = spec.description
    mod.prefix      = spec.prefix or ("[" .. className .. "]")
    mod.global      = spec.global
    mod.source      = source
    mod.class       = class
    mod.deps        = _normalizeDeps(spec.deps)
    mod.resolved    = nil
    mod.missing     = nil
    mod.loaded      = nil
    mod.runtime     = nil
    return mod
end
registerLuaFunctionHighlight('Declare')

--------------------------------------------------------
--                     Resolution                     --
--------------------------------------------------------

local function _resolveOne(mod, dep)
    local key = dep.name
    local valid, why = Bootstrap.Validate(key, rawget(_G, key), dep.validate)
    if valid then
        -- The happy path returns here and logs NOTHING. That is what keeps the
        -- framework at one line per module instead of one line per dependency.
        return rawget(_G, key)
    end
    if not REG.Settings.AutoLoad then
        -- Refuse and report. Resolve never loads; it verifies.
        --
        -- But "not Validate" is not the same as "missing". Validate also fails
        -- for an instance that was orphaned when its module file was executed
        -- again (CETrequire has no cache, TODO R-C/T7). Such an instance still
        -- answers every call its consumers make, so it is a COLLISION to
        -- report - not a missing dependency to refuse on. Treating it as
        -- missing would make every module refuse to start after a single
        -- development reload.
        local current = rawget(_G, key)
        if current ~= nil and Bootstrap.Contract(key, current, dep.validate) then
            if not REG.OrphanSeen[key] then
                REG.OrphanSeen[key] = true
                _log(REG.Settings.ReloadLevel, string.format(
                    "%s ORPHAN: '%s' survived a re-execution; keeping it. Restart the table for a clean instance.",
                    MODULE_PREFIX, key))
            end
            return current
        end
        return nil, why or string.format("'%s' has not been created yet", key)
    end
    local built, failure = Bootstrap.Acquire(key, dep.config)
    if built ~= nil then
        -- Contract, not Validate: Acquire has already reported an orphan it
        -- chose to keep, and an orphan that still answers its calls is not a
        -- missing dependency.
        local usable, whyAfter = Bootstrap.Contract(key, built, dep.validate)
        if not usable then
            built, failure = nil, whyAfter
        end
    end
    if built == nil then
        return nil, failure or why
    end
    _log("Warning", string.format("%s dependency '%s' was %s; resolved out of band. Check the order of execution.",
                                  mod.prefix, key, tostring(why)))
    return built
end

--
--- ∑ The single dependency lookup for the whole framework. Replaces every
---   per-module CheckDependencies body.
---
---   `required = true` raises out of New() with one legible message. That is
---   deliberate and preserves the two hard gates that live inside
---   CheckDependencies today (Manifold.UI.lua:234-237,
---   Manifold.Teleporter.lua:153-155).
---
---   `runtime = true` is documentation only: never loaded here, never gating,
---   never ordered. That is how the UI <-> Teleporter cycle stays harmless.
--- @param mod table # descriptor from Bootstrap.Declare
--- @return boolean, table # resolved, list of missing names
--
function Bootstrap.Resolve(mod)
    if type(mod) ~= "table" or type(mod.deps) ~= "table" then return false, {} end
    local loaded, missing, runtime = {}, {}, {}
    for index = 1, #mod.deps do
        local dep = mod.deps[index]
        if dep.runtime then
            runtime[#runtime + 1] = dep.name
        else
            local value, why = _resolveOne(mod, dep)
            if value == nil then
                missing[#missing + 1] = dep.name
                if dep.required then
                    local message = string.format("%s %s v%s cannot start - it requires '%s': %s",
                        mod.prefix, mod.name, mod.version, dep.name, tostring(why or "unavailable"))
                    _log("Error", message)
                    Bootstrap.Flush()
                    error(message, 3)   -- 3: Resolve <- CheckDependencies <- New
                end
            else
                loaded[#loaded + 1] = dep.name
            end
        end
    end
    mod.loaded   = loaded
    mod.missing  = missing
    mod.runtime  = runtime
    mod.resolved = #missing == 0
    return mod.resolved, missing
end
registerLuaFunctionHighlight('Resolve')

--------------------------------------------------------
--                     Readiness                      --
--------------------------------------------------------

--
--- ∑ The last statement of every module's New():
---       return ManifoldBootstrap.Ready(MODULE, instance)
---
---   Registers the instance and emits EXACTLY ONE line, at most once per module
---   per generation:
---     Info    - every non-runtime dependency satisfied
---     Warning - came up DEGRADED, naming what is missing
---   A module that failed a required dependency never reaches this function, so
---   an absent line is a reliable "this module did not come up" signal.
--- @param mod table
--- @param instance table
--- @return table # the same instance, unchanged
--
--
--- ∑ Emits the batched re-execution summary, once per generation, as a short
---   headline plus wrapped continuation lines. Re-running the table script
---   re-executes every module, so this replaces fifteen near-identical
---   warnings with three short lines that say the same thing.
--
local function _flushReloadBatch()
    if REG.ReloadGen == 0 or REG.ReloadSaid >= REG.ReloadGen then return end
    local reloaded  = REG.ReloadBatch
    local duplicate = REG.DuplicateBatch
    if #reloaded == 0 and #duplicate == 0 then return end
    REG.ReloadSaid   = REG.ReloadGen
    REG.ReloadBatch  = {}
    REG.DuplicateBatch = {}

    if #reloaded > 0 then
        _log(REG.Settings.ReloadLevel, string.format(
            "%s RELOAD gen %d: %d module(s) re-executed; instances from gen %d are orphaned.",
            MODULE_PREFIX, REG.ReloadGen, #reloaded, REG.ReloadGen - 1))
        local lines = _wrapList(reloaded, 68)
        for index = 1, #lines do
            _log(REG.Settings.ReloadLevel, MODULE_PREFIX .. "   " .. lines[index])
        end
    end
    if #duplicate > 0 then
        _log(REG.Settings.ReloadLevel, string.format(
            "%s DUPLICATE gen %d: %d module(s) declared twice on one chunk.",
            MODULE_PREFIX, REG.ReloadGen, #duplicate))
        local lines = _wrapList(duplicate, 68)
        for index = 1, #lines do
            _log(REG.Settings.ReloadLevel, MODULE_PREFIX .. "   " .. lines[index])
        end
    end
end

function Bootstrap.Ready(mod, instance)
    if type(mod) ~= "table" then return instance end
    -- All Declare calls have run by the time the first module is constructed,
    -- so the batch is complete here.
    _flushReloadBatch()
    if mod.resolved == nil then Bootstrap.Resolve(mod) end

    if instance ~= nil then
        if mod.instance ~= nil and mod.instance ~= instance and mod.announced == mod.generation then
            -- A SECOND instance of the same generation. Not a reload - two live
            -- objects, and whichever global wins decides which one the rest of
            -- the framework talks to.
            _log(REG.Settings.ReloadLevel, string.format(
                "%s COLLISION/INSTANCE: %s v%s built a second instance on generation %d; the first one is still referenced somewhere.",
                MODULE_PREFIX, mod.name, mod.version, mod.generation))
        end
        mod.instance = instance
        -- Publish into an EMPTY slot only. The cheat table still owns the
        -- assignment; this just makes the module reachable the moment New()
        -- returns, including from a lazy Acquire further up the same stack, and
        -- removes the asymmetry where whichever other module's init closure ran
        -- first decided what `logger` or `json` pointed at (TODO T7).
        if type(mod.global) == "string" and rawget(_G, mod.global) == nil then
            rawset(_G, mod.global, instance)
        end
    end
    if mod.announced ~= mod.generation then
        mod.announced = mod.generation
        -- Kept deliberately short: name and version are what the user asked
        -- for, and this line is printed fifteen times per boot. Dependencies
        -- appear only when there are some; the generation only when it is not
        -- the first; the chunk source not at all - it is in Bootstrap.Report()
        -- and in the CONFLICT line, which are the places it actually matters.
        local suffix = mod.generation > 1 and (" | gen " .. mod.generation) or ""
        if mod.resolved then
            local deps = (mod.loaded and #mod.loaded > 0)
                and (" | " .. table.concat(mod.loaded, ", ")) or ""
            _log(REG.Settings.ReadyLevel, string.format("%s %s v%s ready%s%s",
                mod.prefix, mod.name, mod.version, deps, suffix))
        else
            _log(REG.Settings.DegradedLevel, string.format("%s %s v%s DEGRADED | missing: %s%s",
                mod.prefix, mod.name, mod.version, table.concat(mod.missing, ", "), suffix))
        end
    end
    Bootstrap.Flush()
    return instance
end
registerLuaFunctionHighlight('Ready')

--------------------------------------------------------
--                       Boot                         --
--------------------------------------------------------

--
--- ∑ Proves the order of execution: every ORDER key exists in KNOWN, every
---   KNOWN key appears in ORDER exactly once, and every non-runtime dependency
---   a module declared sits EARLIER in ORDER. Because every load-time edge is
---   forced to point strictly backwards in a linear array, an order that passes
---   this cannot contain a load-time cycle.
--- @param raise boolean|nil # default false
--- @return boolean, table
--
function Bootstrap.Verify(raise)
    local problems, seen = {}, {}
    for index = 1, #Bootstrap.ORDER do
        local key = Bootstrap.ORDER[index]
        if seen[key] then
            problems[#problems + 1] = string.format("'%s' appears twice in ORDER (%d and %d)", key, seen[key], index)
        elseif Bootstrap.KNOWN[key] == nil then
            problems[#problems + 1] = string.format("ORDER position %d names '%s', which is not in KNOWN", index, key)
        end
        seen[key] = index
    end
    for key in pairs(Bootstrap.KNOWN) do
        if seen[key] == nil then
            problems[#problems + 1] = string.format("'%s' is in KNOWN but missing from ORDER", key)
        end
    end
    for _, className in ipairs(REG.Declared) do
        local mod = REG.Modules[className]
        local position = mod and mod.global and seen[mod.global]
        if mod and position then
            for _, dep in ipairs(mod.deps or {}) do
                if not dep.runtime then
                    local depPosition = seen[dep.name]
                    if depPosition == nil then
                        problems[#problems + 1] = string.format("'%s' declares unknown dependency '%s'",
                                                                mod.global, dep.name)
                    elseif depPosition > position then
                        problems[#problems + 1] = string.format(
                            "'%s' (ORDER %d) load-depends on '%s' (ORDER %d), which loads later",
                            mod.global, position, dep.name, depPosition)
                    end
                end
            end
        end
    end
    if #problems > 0 then
        local message = MODULE_PREFIX .. " order of execution is invalid:\n  - " .. table.concat(problems, "\n  - ")
        _log("Error", message)
        if raise == true then error(message, 2) end
        return false, problems
    end
    return true, problems
end
registerLuaFunctionHighlight('Verify')

--
--- ∑ Walks Bootstrap.ORDER and acquires every module: the order of execution,
---   executed. Entirely optional - the hand-written CETrequire sequence in
---   docs/Manifold-Framework.md keeps working unchanged, because it produces
---   the same globals and the same ready lines.
--- @param options table|nil
---        options.config      { [key] = constructorConfig }
---        options.skip        { [key] = true }
---        options.only        { "key", ... }
---        options.after       { [key] = function(instance) end }
---        options.stopOnError boolean
---        options.verify      boolean, default true
--- @return boolean, table # ok, failure descriptions
--
function Bootstrap.Boot(options)
    options = options or {}
    for key, config in pairs(options.config or {}) do
        REG.Configs[key] = config
    end
    local only
    if options.only then
        only = {}
        for _, key in ipairs(options.only) do only[key] = true end
    end
    local skip, failed = options.skip or {}, {}
    for index = 1, #Bootstrap.ORDER do
        local key = Bootstrap.ORDER[index]
        if not skip[key] and (only == nil or only[key]) then
            local instance, err = Bootstrap.Acquire(key)
            if instance == nil then
                failed[#failed + 1] = key .. " (" .. tostring(err) .. ")"
                if options.stopOnError then
                    Bootstrap.Flush()
                    error(string.format("%s boot stopped at '%s': %s", MODULE_PREFIX, key, tostring(err)), 2)
                end
            else
                local after = options.after and options.after[key]
                if type(after) == "function" then
                    local ok, hookErr = pcall(after, instance)
                    if not ok then
                        _log("Error", string.format("%s post-load hook for '%s' failed: %s",
                                                    MODULE_PREFIX, key, tostring(hookErr)))
                    end
                end
            end
        end
    end
    -- Verified AFTER the walk, not before: only now has every module declared
    -- itself, so the "load-depends on something that loads later" check has
    -- data to work with.
    if options.verify ~= false then Bootstrap.Verify(false) end

    if #failed > 0 then
        _log("Error", MODULE_PREFIX .. " boot incomplete: " .. table.concat(failed, "; "))
    end
    Bootstrap.Flush()
    return #failed == 0, failed
end
registerLuaFunctionHighlight('Boot')

--
--- ∑ Forces one module through a full reload: drop the globals, re-require,
---   reconstruct. The one supported way to reload during development; the next
---   ready line carries its COLLISION/RELOAD clause.
--- @param key string
--- @return table|nil, string|nil
--
function Bootstrap.Reload(key)
    local spec = Bootstrap.KNOWN[key]
    if spec == nil then return nil, "unknown module '" .. tostring(key) .. "'" end
    local mod = REG.Modules[spec.class]
    -- Drop the registry's cached instance as well, or Acquire's republish path
    -- would hand the old object straight back and the reload would be a no-op.
    if mod then mod.instance = nil end
    rawset(_G, spec.class, nil)
    rawset(_G, key, nil)
    REG.OrphanSeen[key] = nil
    return Bootstrap.Acquire(key)
end
registerLuaFunctionHighlight('Reload')

--
--- ∑ Re-writes the manifest of every module that has announced so far into
---   the log FILE.
---
---   Exists because logger:ClearLogFile() truncates the file, and by the time a
---   cheat table can call it - customIO must exist first - Manifold.Json,
---   Manifold.Logger and Manifold.CustomIO have already been recorded. Clearing
---   therefore erases exactly the three entries a support log most needs.
---
---   Call it ONCE, immediately after logger:ClearLogFile(). Modules constructed
---   afterwards record themselves normally, so the result is one complete
---   manifest with no duplicates. Calling it at any other point will duplicate
---   entries; it is a repair for a known truncation, not a general dump.
--- @return integer # entries written
--
function Bootstrap.WriteManifest()
    local lg = _logger()
    if lg == nil then return 0 end
    if type(lg._WriteToLogFile) ~= "function" or type(lg._FormatLogMessage) ~= "function" then
        return 0
    end
    -- This writes everything announced so far, which is a superset of whatever
    -- the pre-customIO stash is still holding. Drop the stash, or those entries
    -- would be replayed a second time by the next log call.
    REG.Unrecorded = {}
    local written = 0
    for index = 1, #REG.Declared do
        local mod = REG.Modules[REG.Declared[index]]
        if type(mod) == "table" and mod.name and mod.announced == mod.generation then
            local suffix = (mod.generation or 1) > 1 and (" | gen " .. mod.generation) or ""
            local body = string.format("%s %s v%s ready%s",
                mod.prefix or MODULE_PREFIX, mod.name, tostring(mod.version), suffix)
            local ok, line = pcall(lg._FormatLogMessage, lg, "INFO", body, false)
            if ok and pcall(lg._WriteToLogFile, lg, line) then
                written = written + 1
            end
        end
    end
    return written
end
registerLuaFunctionHighlight('WriteManifest')

--------------------------------------------------------
--                     Reporting                      --
--------------------------------------------------------

--
--- ∑ Everything the registry knows. Two rows with the same name and different
---   sources is a collision you can act on.
--- @return table
--
function Bootstrap.Report()
    local rows = {}
    for _, className in ipairs(REG.Declared) do
        local mod = REG.Modules[className]
        if mod then
            local status = "declared"
            if mod.resolved == true then
                status = "ok"
            elseif mod.resolved == false then
                status = "degraded [" .. table.concat(mod.missing or {}, ", ") .. "]"
            end
            rows[#rows + 1] = {
                class = className, global = mod.global, name = mod.name, version = mod.version,
                generation = mod.generation, source = mod.source, status = status,
            }
        end
    end
    return rows
end
registerLuaFunctionHighlight('Report')

--
--- ∑ Logs the report as one block. Explicitly outside the one-line-per-module
---   rule: this is an on-demand diagnostic, not part of startup.
---
---   One short header per module, then tab-indented fields - the same shape
---   every module's own PrintModuleInfo uses (see Manifold.Logger.lua:45-52).
---   The previous single-line-per-module table needed a 28-column name field
---   that "Manifold.AssemblerCommands.lua" overflowed anyway, and every row
---   then re-stated the module prefix and the field order. Vertical fields
---   need no alignment at all and stay readable however long a value gets -
---   a degraded status naming four missing dependencies included.
---
---   Each module is one log entry rather than five, so the timestamp and the
---   module prefix appear once per module instead of once per field.
--
function Bootstrap.PrintReport()
    local rows = Bootstrap.Report()
    _log("Info", string.format("%s registry: %d module(s), core load #%d, src %s",
                               MODULE_PREFIX, #rows, REG.CoreLoads, Bootstrap.SOURCE))
    for _, row in ipairs(rows) do
        _log("Info", _block(MODULE_PREFIX .. " " .. tostring(row.name), {
            { "Version",    row.version },
            { "Generation", row.generation },
            { "Status",     row.status },
            { "Source",     row.source },
        }, { indent = "\t" }))
    end
    Bootstrap.Flush()
end
registerLuaFunctionHighlight('PrintReport')

--------------------------------------------------------
--                  Module metadata                   --
--------------------------------------------------------

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table # {name, version, author, description}
--
function Bootstrap.GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Prints module details in a readable formatted block.
--
function Bootstrap.PrintModuleInfo()
    local info = Bootstrap.GetModuleInfo()
    _log("Info", _block("Module Info : " .. tostring(info.name), {
        { "Version",     info.version },
        { "Author",      table.concat(info.author, ", ") },
        { "Description", info.description },
    }, { indent = "\t" }))
    Bootstrap.Flush()
end
registerLuaFunctionHighlight('PrintModuleInfo')

--
--- ∑ Published under the unambiguous name the module prelude looks for, plus
---   the house-style table global that TODO R-B already names.
--
rawset(_G, "ManifoldBootstrap", Bootstrap)
rawset(_G, "Bootstrap", Bootstrap)

if REG.CoreLoads > 1 then
    _log("Warning", string.format(
        "%s v%s re-executed (load #%d); registry intact, references still valid.",
        MODULE_PREFIX, VERSION, REG.CoreLoads))
end

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Bootstrap