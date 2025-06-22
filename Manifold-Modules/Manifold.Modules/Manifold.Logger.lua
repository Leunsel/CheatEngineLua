local NAME = "Manifold.Logger.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.1"
local DESCRIPTION = "Manifold Framework Logger"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.

    ∂ v1.0.1 (2025-04-11)
        Minor comment adjustments.
        Added a dedicated "Logs" Directory to log to.
]]--

Logger = {
    Level = 4
}
Logger.__index = Logger

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
    self:Info("[Logger] Log file set to: " .. self.LogFileName)
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
        self:ForceInfo("[Logger] Updated Log Level to: '" .. newLevel .. "' (" .. self.LevelNames[newLevel] .. ")")
    else
        self:Info("[Logger] Log Level is already set to: '" .. newLevel .. "' (" .. self.LevelNames[newLevel] .. "). Skipping!")
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
--- ∑ Clears the log file if it exists.
---   This function removes all content from the log file while keeping the file itself intact.
--- @return boolean # True if the file was cleared successfully, false if there was an error.
--
function Logger:ClearLogFile()
    local logsDir = self.DataDir .. "\\Logs"
    local fullFilePath = logsDir .. "\\" .. self.LogFileName
    if not customIO:DirectoryExists(logsDir) and not customIO:CreateDirectory(logsDir) then
        logger:Error("[Logger] Failed to create 'Logs' directory: " .. logsDir)
        return false
    end
    local success, err = pcall(function()
        local file = io.open(fullFilePath, "w")
        if file then
            file:close()  -- Simply close the file to clear its contents
            logger:Info("[Logger] Log file cleared: " .. fullFilePath)
            return true
        else
            logger:Error("[Logger] Failed to clear log file: " .. fullFilePath)
            return false
        end
    end)
    if not success then
        logger:Error("[Logger] Error clearing log file: " .. tostring(err))
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
    local levelName = type(level) == "number" and self.LevelNames[level] or level
    local levelId = self.Levels[levelName]
    if not levelId then
        print("[Logger Error]: Invalid log level - " .. tostring(level))
        return
    end
    local formattedMessage = GetDateTime() .. " [" .. levelName .. "] " .. self:Stringify(message)
    -- Write to file (always)
    -- We check for customIO since the dependency is loader AFTER the Logger.
    if customIO and self.DataDir and self.LogFileName then
        if customIO:DirectoryExists(self.DataDir) or customIO:CreateDirectory(self.DataDir) then
            local logsDir = self.DataDir .. "\\Logs"
            if customIO:DirectoryExists(logsDir) or customIO:CreateDirectory(logsDir) then
                local filePath = logsDir .. "\\" .. self.LogFileName
                customIO:AppendToFile(filePath, formattedMessage)
            end
        end
    end
    if levelId >= self.Level then
        local success, err = pcall(self.Output, formattedMessage)
        if not success then
            print("[Logger Error]: Failed to output log - " .. tostring(err))
        end
    end
end
registerLuaFunctionHighlight('Log')

--
--- ∑ Logs a forced log message regardless of the current log level.
--- @param levelName string # The log level (e.g., "DEBUG", "INFO").
--- @param message any # The message to be logged.
--
function Logger:ForceLog(level, message)
    local levelName = type(level) == "number" and self.LevelNames[level] or level
    local levelId = self.Levels[levelName]
    if not levelId then
        print("[Logger Error]: Invalid log level - " .. tostring(level))
        return
    end
    local formattedMessage = GetDateTime() .. " [" .. levelName .. "] [FORCED] " .. self:Stringify(message)
    -- Write to file (always)
    -- We check for customIO since the dependency is loader AFTER the Logger.
    if customIO and self.DataDir and self.LogFileName then
        if customIO:DirectoryExists(self.DataDir) or customIO:CreateDirectory(self.DataDir) then
            local logsDir = self.DataDir .. "\\Logs"
            if customIO:DirectoryExists(logsDir) or customIO:CreateDirectory(logsDir) then
                local filePath = logsDir .. "\\" .. self.LogFileName
                customIO:AppendToFile(filePath, formattedMessage)
            end
        end
    end
    local success, err = pcall(self.Output, formattedMessage)
    if not success then
        print("[Logger Error]: Failed to output forced log - " .. tostring(err))
    end
end

-- 
--- Debug
--- ∑ Logs a debug message. 
---   The message is converted to a string and logged at the DEBUG level.
--- @param message any # The message to be logged.
function Logger:Debug(message) self:Log(self.Levels.DEBUG, tostring(message)) end
registerLuaFunctionHighlight('Debug')

-- 
--- Info
--- ∑ Logs an info message. 
---   The message is converted to a string and logged at the INFO level.
--- @param message any # The message to be logged.
function Logger:Info(message) self:Log(self.Levels.INFO, tostring(message)) end
registerLuaFunctionHighlight('Info')

-- 
--- Warning
--- ∑ Logs a warning message. 
---   The message is converted to a string and logged at the WARNING level.
--- @param message any # The message to be logged.
function Logger:Warning(message) self:Log(self.Levels.WARNING, tostring(message)) end
registerLuaFunctionHighlight('Warning')

-- 
--- Error
--- ∑ Logs an error message. 
---   The message is converted to a string and logged at the ERROR level.
--- @param message any # The message to be logged.
function Logger:Error(message) self:Log(self.Levels.ERROR, tostring(message)) end
registerLuaFunctionHighlight('Error')

-- 
--- Critical
--- ∑ Logs a critical message. 
---   The message is converted to a string and logged at the CRITICAL level.
--- @param message any # The message to be logged.
function Logger:Critical(message) self:Log(self.Levels.CRITICAL, tostring(message)) end
registerLuaFunctionHighlight('Critical')

-- 
--- DebugF
--- ∑ Logs a formatted debug message. 
---   The message is formatted using the provided arguments and logged at the DEBUG level.
--- @param message any # The message to be logged.
--- @param ... any # Additional arguments to format the message.
function Logger:DebugF(message, ...) self:Log(self.Levels.DEBUG, string.format(message, ...)) end
registerLuaFunctionHighlight('DebugF')

-- 
--- InfoF
--- ∑ Logs a formatted info message. 
---   The message is formatted using the provided arguments and logged at the INFO level.
--- @param message any # The message to be logged.
--- @param ... any # Additional arguments to format the message.
function Logger:InfoF(message, ...) self:Log(self.Levels.INFO, string.format(message, ...)) end
registerLuaFunctionHighlight('InfoF')

-- 
--- WarningF
--- ∑ Logs a formatted warning message. 
---   The message is formatted using the provided arguments and logged at the WARNING level.
--- @param message any # The message to be logged.
--- @param ... any # Additional arguments to format the message.
function Logger:WarningF(message, ...) self:Log(self.Levels.WARNING, string.format(message, ...)) end
registerLuaFunctionHighlight('WarningF')

-- 
--- ErrorF
--- ∑ Logs a formatted error message. 
---   The message is formatted using the provided arguments and logged at the ERROR level.
--- @param message any # The message to be logged.
--- @param ... any # Additional arguments to format the message.
function Logger:ErrorF(message, ...) self:Log(self.Levels.ERROR, string.format(message, ...)) end
registerLuaFunctionHighlight('ErrorF')

-- 
--- CriticalF
--- ∑ Logs a formatted critical message. 
---   The message is formatted using the provided arguments and logged at the CRITICAL level.
--- @param message any # The message to be logged.
--- @param ... any # Additional arguments to format the message.
function Logger:CriticalF(message, ...) self:Log(self.Levels.CRITICAL, string.format(message, ...)) end
registerLuaFunctionHighlight('CriticalF')

-- 
--- ForceDebug
--- ∑ Logs a forced debug message. 
---   The message is converted to a string and forced to log at the DEBUG level, ignoring any log level filters.
--- @param message any # The message to be logged.
function Logger:ForceDebug(message) self:ForceLog(self.Levels.DEBUG, tostring(message)) end
registerLuaFunctionHighlight('ForceDebug')

-- 
--- ForceInfo
--- ∑ Logs a forced info message. 
---   The message is converted to a string and forced to log at the INFO level, ignoring any log level filters.
--- @param message any # The message to be logged.
function Logger:ForceInfo(message) self:ForceLog(self.Levels.INFO, tostring(message)) end
registerLuaFunctionHighlight('ForceInfo')

-- 
--- ForceWarning
--- ∑ Logs a forced warning message. 
---   The message is converted to a string and forced to log at the WARNING level, ignoring any log level filters.
--- @param message any # The message to be logged.
function Logger:ForceWarning(message) self:ForceLog(self.Levels.WARNING, tostring(message)) end
registerLuaFunctionHighlight('ForceWarning')

-- 
--- ForceError
--- ∑ Logs a forced error message. 
---   The message is converted to a string and forced to log at the ERROR level, ignoring any log level filters.
--- @param message any # The message to be logged.
function Logger:ForceError(message) self:ForceLog(self.Levels.ERROR, tostring(message)) end
registerLuaFunctionHighlight('ForceError')

-- 
--- ForceCritical
--- ∑ Logs a forced critical message. 
---   The message is converted to a string and forced to log at the CRITICAL level, ignoring any log level filters.
--- @param message any # The message to be logged.
function Logger:ForceCritical(message) self:ForceLog(self.Levels.CRITICAL, tostring(message)) end
registerLuaFunctionHighlight('ForceCritical')

-- 
--- ForceDebugF
--- ∑ Logs a forced formatted debug message. 
---   The message is formatted using the provided arguments and forced to log at the DEBUG level, ignoring any log level filters.
--- @param message any # The message to be logged.
--- @param ... any # Additional arguments to format the message.
function Logger:ForceDebugF(message, ...) self:ForceLog(self.Levels.DEBUG, string.format(message, ...)) end
registerLuaFunctionHighlight('ForceDebugF')

-- 
--- ForceInfoF
--- ∑ Logs a forced formatted info message. 
---   The message is formatted using the provided arguments and forced to log at the INFO level, ignoring any log level filters.
--- @param message any # The message to be logged.
--- @param ... any # Additional arguments to format the message.
function Logger:ForceInfoF(message, ...) self:ForceLog(self.Levels.INFO, string.format(message, ...)) end
registerLuaFunctionHighlight('ForceInfoF')

-- 
--- ForceWarningF
--- ∑ Logs a forced formatted warning message. 
---   The message is formatted using the provided arguments and forced to log at the WARNING level, ignoring any log level filters.
--- @param message any # The message to be logged.
--- @param ... any # Additional arguments to format the message.
function Logger:ForceWarningF(message, ...) self:ForceLog(self.Levels.WARNING, string.format(message, ...)) end
registerLuaFunctionHighlight('ForceWarningF')

-- 
--- ForceErrorF
--- ∑ Logs a forced formatted error message. 
---   The message is formatted using the provided arguments and forced to log at the ERROR level, ignoring any log level filters.
--- @param message any # The message to be logged.
--- @param ... any # Additional arguments to format the message.
function Logger:ForceErrorF(message, ...) self:ForceLog(self.Levels.ERROR, string.format(message, ...)) end
registerLuaFunctionHighlight('ForceErrorF')

-- 
--- ForceCriticalF
--- ∑ Logs a forced formatted critical message. 
---   The message is formatted using the provided arguments and forced to log at the CRITICAL level, ignoring any log level filters.
--- @param message any # The message to be logged.
--- @param ... any # Additional arguments to format the message.
function Logger:ForceCriticalF(message, ...) self:ForceLog(self.Levels.CRITICAL, string.format(message, ...)) end
registerLuaFunctionHighlight('ForceCriticalF')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Logger