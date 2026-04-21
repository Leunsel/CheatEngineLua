local NAME = "Manifold.Logger.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.2"
local DESCRIPTION = "Manifold Framework Logger"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.

    ∂ v1.0.1 (2025-04-11)
        Minor comment adjustments.
        Added a dedicated "Logs" Directory to log to.

    ∂ v1.0.2 (2026-04-21)
        Refactored duplicated log wrapper and file output logic into shared helpers.
        Reduced module size by dynamically registering level-specific logging functions.
]]--

Logger = {
    Level = 4
}
Logger.__index = Logger

local MODULE_PREFIX = "[Logger]"

function Logger:New()
    local instance = setmetatable({}, self)
    instance.Name = NAME or "Unnamed Module"
    instance.Level = self.Levels.ERROR
    instance.Output = print
    instance.DataDir = os.getenv("USERPROFILE") .. "\\AppData\\Local\\Manifold"
    instance.LogFileName = "Manifold.Runtime.Unknown.log"
    return instance
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
--- ∑ Ensures the logger data and log directories exist.
--- @return boolean
--
function Logger:_EnsureLogDirectories()
    if not customIO or not self.DataDir then
        return false
    end
    if not (customIO:DirectoryExists(self.DataDir) or customIO:CreateDirectory(self.DataDir)) then
        return false
    end
    local logsDir = self:_GetLogsDirectory()
    return customIO:DirectoryExists(logsDir) or customIO:CreateDirectory(logsDir)
end
registerLuaFunctionHighlight('_EnsureLogDirectories')

--
--- ∑ Appends a formatted message to the active log file when customIO is available.
--- @param formattedMessage string
--
function Logger:_WriteToLogFile(formattedMessage)
    if self:_EnsureLogDirectories() then
        customIO:AppendToFile(self:_GetLogFilePath(), formattedMessage)
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
        print("[Logger Error]: Invalid log level - " .. tostring(level))
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
        local failureKind = forced == true and "forced log" or "log"
        print("[Logger Error]: Failed to output " .. failureKind .. " - " .. tostring(err))
    end
end
registerLuaFunctionHighlight('_DispatchLog')

--
--- ∑ Clears the log file if it exists.
---   This function removes all content from the log file while keeping the file itself intact.
--- @return boolean # True if the file was cleared successfully, false if there was an error.
--
function Logger:ClearLogFile()
    local logsDir = self:_GetLogsDirectory()
    local fullFilePath = self:_GetLogFilePath()
    if not self:_EnsureLogDirectories() then
        logger:Error(MODULE_PREFIX .. " Failed to create 'Logs' directory: " .. logsDir)
        return false
    end
    local success, err = pcall(function()
        local file = io.open(fullFilePath, "w")
        if file then
            file:close()
            logger:Info(MODULE_PREFIX .. " Log file cleared: " .. fullFilePath)
            return true
        else
            logger:Error(MODULE_PREFIX .. " Failed to clear log file: " .. fullFilePath)
            return false
        end
    end)
    if not success then
        logger:Error(MODULE_PREFIX .. " Error clearing log file: " .. tostring(err))
        return false
    end

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
end

for _, definition in ipairs(LOG_METHODS) do
    _registerLogMethods(definition)
end

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Logger