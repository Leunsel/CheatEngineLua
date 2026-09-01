local NAME = "Manifold.Logger.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.2.0"
local DESCRIPTION = "Manifold Framework Logger"

--[[
    ∂ v1.2.0 (2026-09-01)
        The file half no longer goes through customIO, which is
        what closed the logger to customIO recursion. A failed
        write now switches disk logging off for the session
        instead of being retried on every line, and the
        directory check is cached rather than run twice per line.

    ∂ v1.1.0 (2026-08-26)
        Added BuildBlock() and the <Level>Block() helpers, so a
        multi-row report is one log entry with aligned labels
        instead of one prefixed line per row.
]]--

Logger = {
    Level = 4
}
Logger.__index = Logger

local MODULE_PREFIX = "[Logger]"

--
--- ∑ Manifold.Bootstrap handshake. Uses the framework core when the cheat
---   table has loaded it, and degrades to an inert stub when it has not, so
---   this module stays loadable on its own. Identical in every module - this
---   is the one duplication the design costs, and it is irreducible: something
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
    class = "Logger", global = "logger",
    name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION,
    prefix = MODULE_PREFIX,
    deps = {},
})

function Logger:New()
    local instance = setmetatable({}, self)
    instance.Name = NAME or "Unnamed Module"
    instance.Level = self.Levels.ERROR
    instance.Output = print
    instance.DataDir = os.getenv("USERPROFILE") .. "\\AppData\\Local\\Manifold"
    instance.LogFileName = "Manifold.Runtime.Unknown.log"
    -- Disk state. FileLogging is the switch a caller owns, the two underscore
    -- fields are bookkeeping for the write path and documented there.
    instance.FileLogging = true
    instance.FileLogError = nil
    instance._DirReady = false
    instance._InFileWrite = false
    return BOOTSTRAP.Ready(MODULE, instance)
end
registerLuaFunctionHighlight('New')

--
---- ∑ Retrieves module metadata as a structured table.
--- @return table # {name, version, author, description}
--
function Logger:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Prints module details in a readable formatted block.
--
function Logger:PrintModuleInfo()
    local info = self:GetModuleInfo()
    local author = type(info.author) == "table" and table.concat(info.author, ", ") or tostring(info.author)
    self:InfoBlock("Module Info : " .. tostring(info.name), {
        { "Version",     info.version },
        { "Author",      author },
        { "Description", info.description },
    }, { indent = "\t" })
end
registerLuaFunctionHighlight('PrintModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
--- ∑ Logger levels for controlling log output.
--- @table Levels # {DEBUG, INFO, WARNING, ERROR, CRITICAL}
--
Logger.Levels = {
    DEBUG = 1,
    INFO = 2,
    WARNING = 3,
    ERROR = 4,
    CRITICAL = 5
}

-- Map numeric levels back to names
Logger.LevelNames = {}
for name, id in pairs(Logger.Levels) do
    Logger.LevelNames[id] = name
end

local LOG_METHODS = {
    {name = "Debug",    level = Logger.Levels.DEBUG   },
    {name = "Info",     level = Logger.Levels.INFO    },
    {name = "Warning",  level = Logger.Levels.WARNING },
    {name = "Error",    level = Logger.Levels.ERROR   },
    {name = "Critical", level = Logger.Levels.CRITICAL}
}

--
--- ∑ Sets the log file name for the logger. 
---   If no name is provided, the default log file name is used.
--- @param name string # The name of the log file. If not provided, a default name is used.
--
function Logger:SetLogFileName(name)
    if not name or name == "" then
        self.LogFileName = "Manifold.Runtime.Unknown.log"
    else
        self.LogFileName = "Manifold.Runtime.".. name ..".log"
    end
    -- A new target is a new chance for a directory that was not there before.
    self._DirReady = false
    self:Info(MODULE_PREFIX .. " Log file set to: " .. self.LogFileName)
end
registerLuaFunctionHighlight('SetLogFileName')

--
--- ∑ Sets the logging level for the logger. 
---   The level controls which messages are logged based on severity.
--- @param level number # The log level to set. It can be a number (1 = DEBUG, 2 = INFO, etc.) or a string.
--
function Logger:SetLevel(level)
    local newLevel = type(level) == "number" and level or self.Levels[level] or self.Levels.INFO
    if self.Level ~= newLevel then
        self.Level = newLevel
        self:ForceInfo(MODULE_PREFIX .. " Updated Log Level to: '" .. newLevel .. "' (" .. self.LevelNames[newLevel] .. ")")
    else
        self:Info(MODULE_PREFIX .. " Log Level is already set to: '" .. newLevel .. "' (" .. self.LevelNames[newLevel] .. "). Skipping!")
    end
end
registerLuaFunctionHighlight('SetLevel')

--
--- ∑ Sets the output function for log messages. 
---   This function will handle where log messages are output (e.g., print or a custom function).
--- @param outputFunc function # The function to handle output (e.g., print). If not provided, it defaults to `print`.
--
function Logger:SetOutput(outputFunc)
    self.Output = outputFunc or print
end
registerLuaFunctionHighlight('SetOutput')

--
--- ∑ Retrieves the current date and time in a formatted string.
--- @return string # The current time formatted as "[HH:MM:SS]".
--
local function GetDateTime()
    return os.date("[%H:%M:%S]")
end

--
--- ∑ Returns the absolute log directory path.
--- @return string
--
function Logger:_GetLogsDirectory()
    return self.DataDir .. "\\Logs"
end
registerLuaFunctionHighlight('_GetLogsDirectory')

--
--- ∑ Returns the absolute log file path.
--- @return string
--
function Logger:_GetLogFilePath()
    return self:_GetLogsDirectory() .. "\\" .. self.LogFileName
end
registerLuaFunctionHighlight('_GetLogFilePath')

--
--- ∑ Creates a directory when it is missing, using lfs directly.
---   Deliberately not customIO. This module is declared a framework leaf and
---   customIO reports its own failures through this logger, so borrowing
---   customIO here is what closed the loop:
---     _WriteToLogFile -> customIO:CreateDirectory -> logger:Error -> _WriteToLogFile
---   Going straight to lfs removes the cycle instead of guarding it.
--- @param path string
--- @return boolean
--
local function _ensureDirectory(path)
    local fs = rawget(_G, "lfs")
    if type(fs) ~= "table" or type(path) ~= "string" or path == "" then
        return false
    end
    local attributes = fs.attributes(path)
    if attributes and attributes.mode == "directory" then
        return true
    end
    fs.mkdir(path)
    attributes = fs.attributes(path)
    return attributes ~= nil and attributes.mode == "directory"
end

--
--- ∑ Confirms the log directories exist.
---   The answer is cached. The previous version ran two lfs.attributes calls
---   for every single line, which on a table load meant several hundred
---   directory lookups to write a file whose path never changes.
---   _DirReady is cleared by SetLogFileName, EnableFileLogging and by a failed
---   write, so a folder that disappears mid-session is still noticed.
--- @return boolean
--
function Logger:_EnsureLogDirectories()
    if self._DirReady then
        return true
    end
    if not _ensureDirectory(self.DataDir) then
        return false
    end
    if not _ensureDirectory(self:_GetLogsDirectory()) then
        return false
    end
    self._DirReady = true
    return true
end
registerLuaFunctionHighlight('_EnsureLogDirectories')

--
--- ∑ Switches disk logging off for the rest of the session.
---   Called from the write path, so it must not write. The flag is set before
---   the report, which keeps that report on the Output function only.
---   The console and print keep working. Only the file stops.
--- @param reason any # What went wrong, kept on the instance as FileLogError.
--
function Logger:DisableFileLogging(reason)
    if self.FileLogging == false then
        return
    end
    self.FileLogging = false
    self.FileLogError = tostring(reason or "unknown")
    self._DirReady = false
    self:ForceWarning(MODULE_PREFIX .. " Disk logging disabled for this session: " .. self.FileLogError)
end
registerLuaFunctionHighlight('DisableFileLogging')

--
--- ∑ Turns disk logging back on and forgets the cached directory state, so the
---   next line re-checks the path. The way back after DisableFileLogging, for
---   a caller that has fixed the cause.
--
function Logger:EnableFileLogging()
    self.FileLogging = true
    self.FileLogError = nil
    self._DirReady = false
end
registerLuaFunctionHighlight('EnableFileLogging')

--
--- ∑ Reports whether the file half of the logger is alive.
--- @return boolean, string|nil # Enabled, and the reason it was switched off.
--
function Logger:GetFileLoggingState()
    return self.FileLogging ~= false, self.FileLogError
end
registerLuaFunctionHighlight('GetFileLoggingState')

--
--- ∑ The append itself. Raises on failure so the caller can react once.
---   The second attempt re-checks the directories, which covers the Logs
---   folder being removed while Cheat Engine is running. That is the one
---   failure worth a retry, and one retry is where it ends.
--- @param formattedMessage string
--
function Logger:_AppendToLogFile(formattedMessage)
    local path = self:_GetLogFilePath()
    local file
    for _ = 1, 2 do
        if self:_EnsureLogDirectories() then
            file = io.open(path, "a")
            if file then break end
        end
        self._DirReady = false
    end
    if not file then
        error("cannot open '" .. path .. "' for appending", 0)
    end
    file:write(formattedMessage, "\n")
    file:close()
end
registerLuaFunctionHighlight('_AppendToLogFile')

--
--- ∑ Appends a formatted message to the active log file.
---   Three guards, each for a different failure:
---     FileLogging   the switch a caller owns, and the one a failed write flips
---     _InFileWrite  a log call raised from inside this write cannot re-enter
---     the pcall      a raise here must never escape into the caller's code
---   A failed write disables the file for the session rather than being
---   retried on every following line, which is what made an unwritable data
---   directory cost one open attempt per log call.
--- @param formattedMessage string
--
function Logger:_WriteToLogFile(formattedMessage)
    if self.FileLogging == false or self._InFileWrite then
        return
    end
    self._InFileWrite = true
    local ok, err = pcall(self._AppendToLogFile, self, formattedMessage)
    self._InFileWrite = false
    if not ok then
        self:DisableFileLogging(err)
    end
end
registerLuaFunctionHighlight('_WriteToLogFile')

--
--- ∑ Resolves a numeric or string log level to its name and id.
--- @param level number|string
--- @return string|nil, integer|nil
--
function Logger:_ResolveLevel(level)
    local levelName = type(level) == "number" and self.LevelNames[level] or level
    local levelId = self.Levels[levelName]
    if not levelId then
        -- print, not self:Error. A bad level cannot be reported through the
        -- machinery that just rejected it.
        print(MODULE_PREFIX .. " Invalid log level: " .. tostring(level))
        return nil, nil
    end
    return levelName, levelId
end
registerLuaFunctionHighlight('_ResolveLevel')

--
--- ∑ Builds the final log line for a message and level.
--- @param levelName string
--- @param message any
--- @param forced boolean
--- @return string
--
function Logger:_FormatLogMessage(levelName, message, forced)
    local forcedFlag = forced and " [FORCED]" or ""
    return GetDateTime() .. " [" .. levelName .. "]" .. forcedFlag .. " " .. self:Stringify(message)
end
registerLuaFunctionHighlight('_FormatLogMessage')

--
--- ∑ Centralized logging implementation for normal and forced log output.
--- @param level number|string
--- @param message any
--- @param forced boolean
--
function Logger:_DispatchLog(level, message, forced)
    local levelName, levelId = self:_ResolveLevel(level)
    if not levelId then
        return
    end
    local formattedMessage = self:_FormatLogMessage(levelName, message, forced == true)
    self:_WriteToLogFile(formattedMessage)
    if forced ~= true and levelId < self.Level then
        return
    end
    local success, err = pcall(self.Output, formattedMessage)
    if not success then
        -- Same reason as _ResolveLevel. The Output function is what failed,
        -- so the report cannot go through it.
        local failureKind = forced == true and "forced log" or "log"
        print(MODULE_PREFIX .. " Output failed for a " .. failureKind .. " line: " .. tostring(err))
    end
end
registerLuaFunctionHighlight('_DispatchLog')

--
--- ∑ Clears the log file if it exists.
---   This function removes all content from the log file while keeping the file itself intact.
--- @return boolean # True if the file was cleared successfully, false if there was an error.
--
function Logger:ClearLogFile()
    local path = self:_GetLogFilePath()
    if not self:_EnsureLogDirectories() then
        self:ErrorBlock(MODULE_PREFIX .. " Clear log file failed", {
            { "Directory", self:_GetLogsDirectory() },
            { "Reason",    "missing and not creatable" },
        })
        return false
    end
    local ok, err = pcall(function()
        local file = assert(io.open(path, "w"))
        file:close()
    end)
    if not ok then
        self:ErrorBlock(MODULE_PREFIX .. " Clear log file failed", {
            { "File",   path },
            { "Reason", tostring(err) },
        })
        return false
    end
    self:Info(MODULE_PREFIX .. " Log file cleared: " .. path)
    return true
end
registerLuaFunctionHighlight('ClearLogFile')

--
--- ∑ Converts values into a string representation. 
---   This handles recursion for tables and other complex types.
--- @param value any # The value to be converted into a string.
--- @param processed table # A table used to track already processed tables to avoid infinite recursion.
--- @return string # The stringified value.
--
function Logger:Stringify(value, processed)
    processed = processed or {}
    if type(value) == "table" then
        if processed[value] then return "{...}" end
        processed[value] = true
        local result = {}
        for k, v in pairs(value) do
            local key = tostring(k)
            local valueStr = (type(v) == "table") and self:Stringify(v, processed) or tostring(v)
            table.insert(result, key .. " = " .. valueStr)
        end
        return "{ " .. table.concat(result, ", ") .. " }"
    elseif type(value) == "function" or type(value) == "userdata" or type(value) == "thread" then
        return tostring(value)
    elseif type(value) == "string" then
        return value:gsub("\0", "\\0")  -- Replace null byte with readable \0
    elseif type(value) == "nil" then
        return "nil"
    else
        return tostring(value)
    end
end
registerLuaFunctionHighlight('Stringify')

--
--- ∑ Renders a titled block of label/value rows into one string.
---   A block written as N separate log calls repeats the timestamp and module
---   prefix on every row, which is most of the line width and drowns the content.
---   Building it here means one call, one prefix, and labels that line up on their
---   own rather than by hand-counted padding in each format string.
--- @param title string # First line of the block, prefix included by the caller.
--- @param rows table # Array of {label, value} pairs or plain strings.
---   Use `false` to skip a row - a bare `nil` would cut the list short,
---   since the walk is an ipairs and stops at the first hole.
--- @param options table|nil # { indent = "   ", separator = " : ", align = true }
--- @return string # The block, newline separated.
--
function Logger:BuildBlock(title, rows, options)
    options = options or {}
    local indent = options.indent or "   "
    local separator = options.separator or " : "
    local align = options.align ~= false
    local entries = {}
    local labelWidth = 0
    for _, row in ipairs(rows or {}) do
        if row then
            if type(row) == "table" then
                local label = tostring(row[1] or "")
                local value = row[2]
                if value == nil then value = row.value end
                entries[#entries + 1] = { Label = label, Value = self:Stringify(value) }
                if align and #label > labelWidth then
                    labelWidth = #label
                end
            else
                entries[#entries + 1] = { Text = tostring(row) }
            end
        end
    end
    local lines = {}
    if title ~= nil and tostring(title) ~= "" then
        lines[#lines + 1] = tostring(title)
    end
    for _, entry in ipairs(entries) do
        if entry.Text ~= nil then
            lines[#lines + 1] = indent .. entry.Text
        else
            local label = entry.Label
            if align and #label < labelWidth then
                label = label .. string.rep(" ", labelWidth - #label)
            end
            local head = indent .. label .. separator
            -- A multi-line value keeps its shape by hanging under its own label.
            local first = true
            for piece in (entry.Value:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"):gmatch("(.-)\n") do
                if first then
                    lines[#lines + 1] = head .. piece
                    first = false
                else
                    lines[#lines + 1] = string.rep(" ", #head) .. piece
                end
            end
            if first then
                lines[#lines + 1] = head
            end
        end
    end
    return table.concat(lines, "\n")
end
registerLuaFunctionHighlight('BuildBlock')

--
--- ∑ Logs a message at a specified log level.
---   The level is checked against the current logging level to decide if the message should be logged.
--- @param levelName string # The log level (e.g., "DEBUG", "INFO").
--- @param message any # The message to be logged.
--
function Logger:Log(level, message)
    self:_DispatchLog(level, message, false)
end
registerLuaFunctionHighlight('Log')

--
--- ∑ Logs a forced log message regardless of the current log level.
--- @param levelName string # The log level (e.g., "DEBUG", "INFO").
--- @param message any # The message to be logged.
--
function Logger:ForceLog(level, message)
    self:_DispatchLog(level, message, true)
end
registerLuaFunctionHighlight('ForceLog')

--
--- ∑ Registers level-specific log helpers (plain, formatted, and forced variants).
--
local function _registerLogMethods(definition)
    local name = definition.name
    local level = definition.level
    Logger[name] = function(self, message)
        self:Log(level, tostring(message))
    end
    registerLuaFunctionHighlight(name)
    Logger[name .. "F"] = function(self, message, ...)
        self:Log(level, string.format(message, ...))
    end
    registerLuaFunctionHighlight(name .. "F")
    Logger["Force" .. name] = function(self, message)
        self:ForceLog(level, tostring(message))
    end
    registerLuaFunctionHighlight("Force" .. name)
    Logger["Force" .. name .. "F"] = function(self, message, ...)
        self:ForceLog(level, string.format(message, ...))
    end
    registerLuaFunctionHighlight("Force" .. name .. "F")
    Logger[name .. "Block"] = function(self, title, rows, options)
        self:Log(level, self:BuildBlock(title, rows, options))
    end
    registerLuaFunctionHighlight(name .. "Block")
    Logger["Force" .. name .. "Block"] = function(self, title, rows, options)
        self:ForceLog(level, self:BuildBlock(title, rows, options))
    end
    registerLuaFunctionHighlight("Force" .. name .. "Block")
end

for _, definition in ipairs(LOG_METHODS) do
    _registerLogMethods(definition)
end

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Logger