local NAME = "CTI.Logger"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Cheat Table Interface (Logger)"

Logger = {}
Logger.__index = Logger

if not json then
    CETrequire("json")
end

Logger.LEVELS = {"DEBUG", "INFO", "WARN", "ERROR", "FATAL"}

Logger.Formatter = {}
Logger.Formatter.__index = Logger.Formatter

function Logger.Formatter:new()
    local instance = setmetatable({}, self)
    instance.formatters = {}
    instance.timestampEnabled = true
    instance.defaultPattern = "[%s] %s"
    instance:_registerDefaultFormatters()
    return instance
end

function Logger.Formatter:addFormatter(data_type, formatter)
    self.formatters[data_type] = formatter
end

function Logger.Formatter:format(data)
    local data_type = type(data)
    local formatter = self.formatters[data_type]
    if formatter then
        return formatter(data)
    else
        return self.formatters["unknown"](data)
    end
end

function Logger.Formatter:_registerDefaultFormatters()
    self.formatters["string"] = tostring
    self.formatters["number"] = tostring
    self.formatters["boolean"] = tostring
    self.formatters["nil"] = function() return "nil" end
    self.formatters["function"] = function(func)
        return string.format("<function: %s>", tostring(func))
    end
    self.formatters["userdata"] = function(udata)
        return string.format("<userdata: %s>", tostring(udata))
    end
    self.formatters["thread"] = function(thread)
        return string.format("<thread: %s>", tostring(thread))
    end
    self.formatters["table"] = function(tbl)
        return self:_formatTable(tbl, 10)
    end
    self.formatters["unknown"] = function(data)
        return string.format("<unknown: %s>", tostring(data))
    end
end

function Logger.Formatter:_formatTable(tbl, depth, indent)
    depth = depth or 0
    indent = indent or 0
    local maxDepth = 5
    if depth > maxDepth then
        -- return "{...}"
    end
    local indentStr = string.rep("  ", indent)
    local result = "{\n"
    if type(tbl) == "string" and tbl:match("<string:.*>") then
        local position = {}
        for num in tbl:match("<string:([0-9, %.%-]+)>"):gmatch("([0-9%.%-]+)") do
            table.insert(position, tonumber(num))
        end
        tbl = position
    end
    if type(tbl) == "table" then
        if #tbl > 0 then
            for i, v in ipairs(tbl) do
                local value
                if type(v) == "table" then
                    value = self:_formatTable(v, depth + 1, indent + 1)
                elseif type(v) == "userdata" then
                    value = string.format("<userdata: %s>", tostring(v))
                elseif type(v) == "number" then
                    value = string.format("%.2f", v)
                else
                    value = self:format(v)
                end
                result = result .. string.format("%s  [%d] = %s,\n", indentStr, i, value)
            end
        else
            for k, v in pairs(tbl) do
                local key = self:format(k)
                local value
                if type(v) == "table" then
                    value = self:_formatTable(v, depth + 1, indent + 1)
                elseif type(v) == "userdata" then
                    value = string.format("<userdata: %s>", tostring(v))
                elseif type(v) == "number" then
                    value = string.format("%.2f", v)
                else
                    value = self:format(v)
                end
                result = result .. string.format("%s  [%s] = %s,\n", indentStr, key, value)
            end
        end
    else
        result = result .. string.format("%s  %s,\n", indentStr, tostring(tbl))
    end
    result = result .. indentStr .. "}"
    return result
end

function Logger.Formatter:setTimestampEnabled(enabled)
    self.timestampEnabled = enabled
end

function Logger.Formatter:setDefaultPattern(pattern)
    self.defaultPattern = pattern or "[%s] %s"
end

function Logger.Formatter:formatMessage(level, message, data)
    local timestamp = self.timestampEnabled and os.date("%Y-%m-%d %H:%M:%S") or ""
    local formattedData = data and self:format(data) or nil
    local dataPart = formattedData and string.format(" - Data: %s", formattedData) or ""
    return string.format("%s [%s] %s%s", timestamp, level, message, dataPart)
end

Logger.Handler = {}
Logger.Handler.__index = Logger.Handler

function Logger.Handler:new(formatter)
    local instance = setmetatable({}, self)
    instance.formatter = formatter or Logger.Formatter:new()
    instance.handlers = {}
    instance.minLevel = "DEBUG"
    return instance
end

function Logger.Handler:addHandler(level, handler, formatter)
    self.handlers[level] = self.handlers[level] or {}
    table.insert(self.handlers[level], {handler = handler, formatter = formatter})
end

function Logger.Handler:setMinLevel(level)
    self.minLevel = level
end

function Logger.Handler:handle(level, message, data)
    local levelIndex = self:getLevelIndex(level)
    local minLevelIndex = self:getLevelIndex(self.minLevel)
    if levelIndex >= minLevelIndex then
        local handlers = self.handlers[level]
        if handlers then
            for _, entry in ipairs(handlers) do
                local formatter = entry.formatter or self.formatter
                local formattedMessage = formatter:formatMessage(level, message, data)
                entry.handler(formattedMessage)
            end
        else
            print(self.formatter:formatMessage(level, message, data))
        end
    end
end

function Logger.Handler:getLevelIndex(level)
    for i, lvl in ipairs(Logger.LEVELS) do
        if lvl == level then
            return i
        end
    end
    return 0
end

local instance = nil

function Logger:new()
    if not instance then
        instance = setmetatable({}, self)
        instance.formatter = Logger.Formatter:new()
        instance.handler = Logger.Handler:new(instance.formatter)
        instance.minLevel = "ERROR"
        instance.useJson = false
    end
    return instance
end

function Logger:setMinLevel(level)
    self.handler:setMinLevel(level)
end

function Logger:addHandler(level, handler, formatter)
    self.handler:addHandler(level, handler, formatter)
end

function Logger:debug(message, data)
    if self.useJson then
        self:logJson("DEBUG", message, data)
    else
        self.handler:handle("DEBUG", message, data)
    end
end

function Logger:info(message, data)
    if self.useJson then
        self:logJson("INFO", message, data)
    else
        self.handler:handle("INFO", message, data)
    end
end

function Logger:warn(message, data)
    if self.useJson then
        self:logJson("WARN", message, data)
    else
        self.handler:handle("WARN", message, data)
    end
end

function Logger:error(message, data)
    if self.useJson then
        self:logJson("ERROR", message, data)
    else
        self.handler:handle("ERROR", message, data)
    end
end

function Logger:fatal(message, data)
    if self.useJson then
        self:logJson("FATAL", message, data)
    else
        self.handler:handle("FATAL", message, data)
    end
end

function Logger:addFileHandler(filename, maxFileSize)
    local fileHandler = function(message)
        local file = io.open(filename, "a")
        if file then
            file:write(message .. "\n")
            file:close()
        end
        self:handleLogRotation(filename, maxFileSize)
    end
    for _, level in ipairs(Logger.LEVELS) do
        self:addHandler(level, fileHandler)
    end
end

function Logger:handleLogRotation(filename, maxFileSize)
    local file = io.open(filename, "r")
    if file then
        local fileSize = file:seek("end")
        file:close()
        if fileSize > maxFileSize then
            local backupFile = filename .. "." .. os.date("%Y%m%d%H%M%S")
            os.rename(filename, backupFile)
            io.open(filename, "w")
        end
    end
end

function Logger:logJson(level, message, data)
    local logEntry = {
        level = level,
        message = message,
        -- data = data or {}
    }
    if type(logEntry.data) == "table" then
        if not pcall(function() json.encode(logEntry.data) end) then
            logEntry.data = tostring(logEntry.data)
        end
    end
    local jsonData = json.encode(logEntry)
    self.handler:handle(level, jsonData, logEntry)
end

function Logger:setJsonMode(enabled)
    self.useJson = enabled
end

return Logger
