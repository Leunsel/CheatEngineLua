--[[
    Manifold.TemplateLoader.Log.lua
    --------------------------------

    AUTHOR  : Leunsel
    VERSION : 2.0.0
    LICENSE : MIT
    CREATED : 2025-06-21
    UPDATED : 2025-06-22
    
    MIT License:
        Copyright (c) 2025 Leunsel

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.

    This file is part of the Manifold TemplateLoader system.
]]

local sep = package.config:sub(1, 1)

local Log = {
    CurrentLevel = 4,
    LogToFile = false,
    LogFileName = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "Manifold-TemplateLoader-Log.txt",
    LogLevel = {
        NONE = 0,
        DEBUG = 1,
        INFO = 2,
        WARNING = 3,
        ERROR = 4,
        CRITICAL = 5
    },
    LevelNames = {
        [0] = "NONE",
        [1] = "DEBUG",
        [2] = "INFO",
        [3] = "WARNING",
        [4] = "ERROR",
        [5] = "CRITICAL"
    }
}
Log.__index = Log

local instance = nil

function Log:New()
    if not instance then
        instance = setmetatable({}, Log)
    end
    return instance
end

function Log:GetLogLevel()
    return self.CurrentLevel
end

function Log:GetLogLevelName()
    return self.LevelNames[self.CurrentLevel] or "UNKNOWN"
end

function Log:SetLogLevel(level)
    if level >= self.LogLevel.NONE and level <= self.LogLevel.CRITICAL then
        self.CurrentLevel = level
    else
        -- error("Invalid log level: " .. tostring(level))
        return
    end
end

function Log:Stringify(tbl)
    local result = "{ "
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            v = self:Stringify(v)
        elseif type(v) == "string" then
            v = '"' .. v .. '"'
        end
        result = result .. k .. ": " .. tostring(v) .. ", "
    end
    result = result:sub(1, -3) .. " }"
    return result
end

local function formatLog(levelName, message)
    return string.format("[%s] [%s] %s", os.date("%H:%M:%S"), levelName, message)
end

function Log:Log(level, message)
    if level < self.CurrentLevel then return end
    local logMessage = formatLog(self.LevelNames[level] or "UNKNOWN", message)
    print(logMessage)
    self:_LogToFile(logMessage)
end

function Log:ForceLog(level, message)
    local logMessage = formatLog(self.LevelNames[level] or "UNKNOWN", message)
    print(logMessage)
    self:_LogToFile(logMessage)
end

function Log:_LogToFile(message)
    if not self.LogToFile then return end
    local file = io.open(self.LogFileName, "a")
    if file then
        file:write(message .. "\n")
        file:close()
    end
end

for name, level in pairs(Log.LogLevel) do
    if name ~= "NONE" then
        Log[name:sub(1,1):upper()..name:sub(2):lower()] = function(self, message)
            self:Log(level, message)
        end
        Log["Force"..(name:sub(1,1):upper()..name:sub(2):lower())] = function(self, message)
            self:ForceLog(level, message)
        end
        Log[name:sub(1,1):upper()..name:sub(2):lower().."F"] = function(self, formatStr, ...)
            self:Log(level, string.format(formatStr, ...))
        end
        Log["Force"..(name:sub(1,1):upper()..name:sub(2):lower()).."F"] = function(self, formatStr, ...)
            self:ForceLog(level, string.format(formatStr, ...))
        end
    end
end

function Log:ClearLogFile()
    if self.LogToFile then
        local file = io.open(self.LogFileName, "w")
        if file then file:close() end
    end
end

return Log