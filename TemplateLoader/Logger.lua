local NAME = "TemplateLoader.Logger"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Cheat Engine Template Framework (Logger)"

--[[
    -- To debug the module, use the following setup to load modules from the autorun folder:
    local sep = package.config:sub(1, 1)
    package.path = getAutorunPath() .. "Modules" .. sep .. "?.lua;" .. package.path
    local Logger = require("Logger")
]]

local Logger = {}

Logger.logLevel = "DEBUG"
Logger.logToFile = false
Logger.logFilePath = "ScriptTemplateFramework.log"
Logger.dateFormat = "%Y-%m-%d %H:%M:%S"

Logger.ShouldLog = true

Logger.levels = {
    DEBUG = 1,
    INFO = 2,
    SUCCESS = 3,
    WARN = 4,
    ERROR = 5,
    CRITICAL = 6
}

function Logger.toggle()
    Logger.ShouldLog = not Logger.ShouldLog
end

local function getTimestamp()
    return os.date(Logger.dateFormat)
end

function Logger.toggleDebugPrints()
    Logger.ShouldLog = not Logger.ShouldLog
    Logger.log("INFO", "Logger: The Debug Logs have been " .. (Logger.ShouldLog and "activated" or "deactivated") .. ".", true)
end

local function writeToFile(message)
    if Logger.ShouldLog and Logger.logToFile then
        local file = io.open(Logger.logFilePath, "a")
        if file then
            file:write(message .. "\n")
            file:close()
        else
            error("Failed to open log file: " .. Logger.logFilePath)
        end
    end
end

function Logger.log(level, message, bypass)
    if bypass or Logger.ShouldLog and Logger.levels[level] and Logger.levels[level] >= Logger.levels[Logger.logLevel] then
        local formattedMessage = string.format("\n[%s] [%s]\n>> %s", getTimestamp(), level, message)
        print(formattedMessage)
        writeToFile(formattedMessage)
    end
end

function Logger.debug(message) Logger.log("DEBUG", message) end
function Logger.info(message) Logger.log("INFO", message) end
function Logger.success(message) Logger.log("SUCCESS", message) end
function Logger.warn(message) Logger.log("WARN", message) end
function Logger.error(message) Logger.log("ERROR", message) end
function Logger.critical(message) Logger.log("CRITICAL", message) end

function Logger.setLogLevel(level)
    if Logger.levels[level] then
        Logger.logLevel = level
        Logger.info("Log level changed to: " .. level)
    else
        Logger.warn("Invalid log level: " .. tostring(level))
    end
end

return Logger
