local NAME = "Manifold.Logger.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Manifold Framework Logger"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.
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
--- @return table  {name, version, author, description}
--
function Logger:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
---- ∑ Logger levels for controlling log output.
--- @table Levels {DEBUG, INFO, WARNING, ERROR, CRITICAL}
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
--- ∑ ...
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
---- ∑ Sets the logging level.
--- @param level number The log level to set.
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
--- @param outputFunc function The function to handle output (e.g., print).
--
function Logger:SetOutput(outputFunc)
    self.Output = outputFunc or print
end
registerLuaFunctionHighlight('SetOutput')

--
--- ∑ Retrieves the current date and time in a formatted string.
--- @return string The current time formatted as "[HH:MM:SS]".
--
local function GetDateTime()
    return os.date("[%H:%M:%S]")
end

--
--- ∑ Clears the log file if it exists.
--- @return boolean True if the file was cleared successfully, false if there was an error.
--
function Logger:ClearLogFile()
    local fullFilePath = self.DataDir .. "\\" .. self.LogFileName
    local success, err = pcall(function()
        local file = io.open(fullFilePath, "w")  -- Open the file in write mode to overwrite it
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
--- @param value any The value to be converted to a string.
--- @param processed table A table of processed tables to avoid infinite recursion.
--- @return string The stringified value.
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
--- @param levelName string The log level (e.g., "DEBUG", "INFO").
--- @param message any The message to be logged.
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
            local filePath = self.DataDir .. "\\" .. self.LogFileName
            customIO:AppendToFile(filePath, formattedMessage)
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
--- @param levelName string The log level (e.g., "DEBUG", "INFO").
--- @param message any The message to be logged.
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
            local fullFilePath = self.DataDir .. "\\" .. self.LogFileName
            customIO:AppendToFile(fullFilePath, formattedMessage)
        end
    end
    local success, err = pcall(self.Output, formattedMessage)
    if not success then
        print("[Logger Error]: Failed to output forced log - " .. tostring(err))
    end
end

--
--- ∑ Logs a debug message.
--- @param message any The message to be logged.
--
function Logger:Debug(message)    self:Log(self.Levels.DEBUG, tostring(message)) end
registerLuaFunctionHighlight('Debug')

--
--- ∑ Logs an info message.
--- @param message any The message to be logged.
--
function Logger:Info(message)     self:Log(self.Levels.INFO, tostring(message)) end
registerLuaFunctionHighlight('Info')

--
--- ∑ Logs a warning message.
--- @param message any The message to be logged.
--
function Logger:Warning(message)  self:Log(self.Levels.WARNING, tostring(message)) end
registerLuaFunctionHighlight('Warning')

--
--- ∑ Logs an error message.
--- @param message any The message to be logged.
--
function Logger:Error(message)    self:Log(self.Levels.ERROR, tostring(message)) end
registerLuaFunctionHighlight('Error')

--
--- ∑ Logs a critical message.
--- @param message any The message to be logged.
--
function Logger:Critical(message) self:Log(self.Levels.CRITICAL, tostring(message)) end
registerLuaFunctionHighlight('Critical')

--
--- ∑ Logs a formatted debug message.
--- @param message any The message to be logged.
--- @param ... any Additional arguments to format the message.
--
function Logger:DebugF(message, ...)    self:Log(self.Levels.DEBUG, string.format(message, ...)) end
registerLuaFunctionHighlight('DebugF')

--
--- ∑ Logs a formatted info message.
--- @param message any The message to be logged.
--- @param ... any Additional arguments to format the message.
--
function Logger:InfoF(message, ...)     self:Log(self.Levels.INFO, string.format(message, ...)) end
registerLuaFunctionHighlight('InfoF')

--
--- ∑ Logs a formatted warning message.
--- @param message any The message to be logged.
--- @param ... any Additional arguments to format the message.
--
function Logger:WarningF(message, ...)  self:Log(self.Levels.WARNING, string.format(message, ...)) end
registerLuaFunctionHighlight('WarningF')

--
--- ∑ Logs a formatted error message.
--- @param message any The message to be logged.
--- @param ... any Additional arguments to format the message.
--
function Logger:ErrorF(message, ...)    self:Log(self.Levels.ERROR, string.format(message, ...)) end
registerLuaFunctionHighlight('ErrorF')

--
--- ∑ Logs a formatted critical message.
--- @param message any The message to be logged.
--- @param ... any Additional arguments to format the message.
--
function Logger:CriticalF(message, ...) self:Log(self.Levels.CRITICAL, string.format(message, ...)) end
registerLuaFunctionHighlight('CriticalF')

--
--- ∑ Logs a forced debug message.
--- @param message any The message to be logged.
--
function Logger:ForceDebug(message)    self:ForceLog(self.Levels.DEBUG, tostring(message)) end
registerLuaFunctionHighlight('ForceDebug')

--
--- ∑ Logs a forced info message.
--- @param message any The message to be logged.
--
function Logger:ForceInfo(message)     self:ForceLog(self.Levels.INFO, tostring(message)) end
registerLuaFunctionHighlight('ForceInfo')

--
--- ∑ Logs a forced warning message.
--- @param message any The message to be logged.
--
function Logger:ForceWarning(message)  self:ForceLog(self.Levels.WARNING, tostring(message)) end
registerLuaFunctionHighlight('ForceWarning')

--
--- ∑ Logs a forced error message.
--- @param message any The message to be logged.
--
function Logger:ForceError(message)    self:ForceLog(self.Levels.ERROR, tostring(message)) end
registerLuaFunctionHighlight('ForceError')

--
--- ∑ Logs a forced critical message.
--- @param message any The message to be logged.
--
function Logger:ForceCritical(message) self:ForceLog(self.Levels.CRITICAL, tostring(message)) end
registerLuaFunctionHighlight('ForceCritical')

--
--- ∑ Logs a forced formatted debug message.
--- @param message any The message to be logged.
--- @param ... any Additional arguments to format the message.
--
function Logger:ForceDebugF(message, ...)    self:ForceLog(self.Levels.DEBUG, string.format(message, ...)) end
registerLuaFunctionHighlight('ForceDebugF')

--
--- ∑ Logs a forced formatted info message.
--- @param message any The message to be logged.
--- @param ... any Additional arguments to format the message.
--
function Logger:ForceInfoF(message, ...)     self:ForceLog(self.Levels.INFO, string.format(message, ...)) end
registerLuaFunctionHighlight('ForceInfoF')

--
--- ∑ Logs a forced formatted warning message.
--- @param message any The message to be logged.
--- @param ... any Additional arguments to format the message.
--
function Logger:ForceWarningF(message, ...)  self:ForceLog(self.Levels.WARNING, string.format(message, ...)) end
registerLuaFunctionHighlight('ForceWarningF')

--
--- ∑ Logs a forced formatted error message.
--- @param message any The message to be logged.
--- @param ... any Additional arguments to format the message.
--
function Logger:ForceErrorF(message, ...)    self:ForceLog(self.Levels.ERROR, string.format(message, ...)) end
registerLuaFunctionHighlight('ForceErrorF')

--
--- ∑ Logs a forced formatted critical message.
--- @param message any The message to be logged.
--- @param ... any Additional arguments to format the message.
--
function Logger:ForceCriticalF(message, ...) self:ForceLog(self.Levels.CRITICAL, string.format(message, ...)) end
registerLuaFunctionHighlight('ForceCriticalF')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Logger