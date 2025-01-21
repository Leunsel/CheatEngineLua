local NAME = "CTI.Logger"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Cheat Table Interface (Logger)"

--
--- Would contain several configuration properties that can be customized.
--- Set within the Table Lua Script and passed to the constructor of the class.
--- None in this case.
----------
Logger = {}

--
--- Set the metatable for the Logger object so that it behaves as an "object-oriented class".
----------
Logger.__index = Logger


--
--- This checks if the required module(s) (json) are already loaded.
--- If not, it attempts to load them using the CETrequire function.
----------
if not json then
    CETrequire("json")
end

--
--- Define the available logging levels.
----------
Logger.LEVELS = {"DEBUG", "INFO", "WARN", "ERROR", "FATAL"}

--
--- Formatter class used for formatting log messages.
----------
Logger.Formatter = {}
Logger.Formatter.__index = Logger.Formatter

--
--- Constructor for the Formatter class. Initializes default formatters and settings.
--- @return A new instance of Logger.Formatter.
----------
function Logger.Formatter:new()
    local instance = setmetatable({}, self)
    instance.formatters = {}
    instance.timestampEnabled = true
    instance.defaultPattern = "[%s] %s"
    instance:_registerDefaultFormatters()
    return instance
end

--
--- Adds a custom formatter for a specific data type.
--- @param data_type: The type of data to format (e.g., "string", "table").
--- @param formatter: A function that formats data of the given type.
--- @return None.
----------
function Logger.Formatter:addFormatter(data_type, formatter)
    self.formatters[data_type] = formatter
end

--
--- Formats the given data using the appropriate formatter based on its type.
--- @param data: The data to format.
--- @return The formatted string representation of the data.
----------
function Logger.Formatter:format(data)
    local data_type = type(data)
    local formatter = self.formatters[data_type]
    if formatter then
        return formatter(data)
    else
        return self.formatters["unknown"](data)
    end
end

--
--- Registers the default formatters for common data types (e.g., string, number, table).
--- @return None.
----------
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

--
--- Recursively formats a table into a string representation.
--- (Should) Limits depth to prevent excessive recursion for deeply nested tables. (Doesn't)
--- @param tbl: The table to format.
--- @param depth: The current depth of recursion.
--- @param indent: The current indentation level.
--- @return A string representation of the table.
----------
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

--
--- Enables or disables the inclusion of timestamps in log messages.
--- @param enabled: A boolean indicating whether timestamps should be included.
--- @return None.
----------
function Logger.Formatter:setTimestampEnabled(enabled)
    self.timestampEnabled = enabled
end

--
--- Sets the default pattern for formatting log messages.
--- @param pattern: A string pattern for formatting messages. Defaults to "[%s] %s".
--- @return None.
----------
function Logger.Formatter:setDefaultPattern(pattern)
    self.defaultPattern = pattern or "[%s] %s"
end

--
--- Formats a log message with the specified level, message, and optional data.
--- @param level: The log level (e.g., "INFO", "DEBUG").
--- @param message: The main log message.
--- @param data: Optional data to include in the log message.
--- @return A formatted log message string.
----------
function Logger.Formatter:formatMessage(level, message, data)
    local timestamp = self.timestampEnabled and os.date("%Y-%m-%d %H:%M:%S") or ""
    local formattedData = data and self:format(data) or nil
    local dataPart = formattedData and string.format(" - Data: %s", formattedData) or ""
    return string.format("%s [%s] %s%s", timestamp, level, message, dataPart)
end

--
--- -''-
--- Same as 'Logger' Information.
----------
Logger.Handler = {}
Logger.Handler.__index = Logger.Handler

--
--- Creates a new Logger.Handler instance.
--- @param formatter: An optional Logger.Formatter instance for formatting log messages.
--- @return A new instance of Logger.Handler.
----------
function Logger.Handler:new(formatter)
    local instance = setmetatable({}, self)
    instance.formatter = formatter or Logger.Formatter:new()
    instance.handlers = {}
    instance.minLevel = "DEBUG"
    return instance
end

--
--- Adds a handler for a specific log level.
--- @param level: The log level for which the handler is applicable (e.g., "DEBUG").
--- @param handler: A function to handle log messages.
--- @param formatter: An optional custom formatter for this handler.
--- @return None.
----------
function Logger.Handler:addHandler(level, handler, formatter)
    self.handlers[level] = self.handlers[level] or {}
    table.insert(self.handlers[level], {handler = handler, formatter = formatter})
end

--
--- Sets the minimum log level for this handler. Messages below this level are ignored.
--- @param level: The minimum log level (e.g., "INFO").
--- @return None.
----------
function Logger.Handler:setMinLevel(level)
    self.minLevel = level
end

--
--- Handles a log message by dispatching it to the appropriate handlers based on its level.
--- @param level: The log level of the message.
--- @param message: The main log message.
--- @param data: Optional additional data to include with the log message.
--- @return None.
----------
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

--
--- Retrieves the index of a log level in the Logger.LEVELS table.
--- @param level: A string representing the log level (e.g., "DEBUG", "INFO").
--- @return The index of the log level in Logger.LEVELS, or 0 if not found.
----------
function Logger.Handler:getLevelIndex(level)
    for i, lvl in ipairs(Logger.LEVELS) do
        if lvl == level then
            return i
        end
    end
    return 0
end

local instance = nil

---
--- Creates or retrieves a singleton instance of the Logger.
--- Initializes a Logger instance with a default formatter and handler.
--- @return A Logger instance.
----------
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

--
--- Sets the minimum log level for logging.
--- Messages below this level will be ignored by the logger.
--- @param level: A string representing the minimum log level (e.g., "ERROR", "DEBUG").
--- @return None.
----------
function Logger:setMinLevel(level)
    self.handler:setMinLevel(level)
end

--
--- Adds a handler for a specific log level to the logger.
--- A handler is a function that processes log messages.
--- @param level: A string representing the log level (e.g., "DEBUG").
--- @param handler: A function to handle the log message.
--- @param formatter: (Optional) A custom formatter for this handler.
--- @return None.
----------
function Logger:addHandler(level, handler, formatter)
    self.handler:addHandler(level, handler, formatter)
end

--
--- Logs a message with the "DEBUG" level.
--- @param message: A string representing the log message.
--- @param data: (Optional) Additional data to include in the log message.
--- @return None.
----------
function Logger:debug(message, data)
    if self.useJson then
        self:logJson("DEBUG", message, data)
    else
        self.handler:handle("DEBUG", message, data)
    end
end

--
--- Logs a message with the "INFO" level.
--- @param message: A string representing the log message.
--- @param data: (Optional) Additional data to include in the log message.
--- @return None.
----------
function Logger:info(message, data)
    if self.useJson then
        self:logJson("INFO", message, data)
    else
        self.handler:handle("INFO", message, data)
    end
end

--
--- Logs a message with the "WARN" level.
--- @param message: A string representing the log message.
--- @param data: (Optional) Additional data to include in the log message.
--- @return None.
----------
function Logger:warn(message, data)
    if self.useJson then
        self:logJson("WARN", message, data)
    else
        self.handler:handle("WARN", message, data)
    end
end

--
--- Logs a message with the "ERROR" level.
--- @param message: A string representing the log message.
--- @param data: (Optional) Additional data to include in the log message.
--- @return None.
----------
function Logger:error(message, data)
    if self.useJson then
        self:logJson("ERROR", message, data)
    else
        self.handler:handle("ERROR", message, data)
    end
end

--
--- Logs a message with the "FATAL" level.
--- @param message: A string representing the log message.
--- @param data: (Optional) Additional data to include in the log message.
--- @return None.
----------
function Logger:fatal(message, data)
    if self.useJson then
        self:logJson("FATAL", message, data)
    else
        self.handler:handle("FATAL", message, data)
    end
end

--
--- Adds a file handler to the logger, which writes log messages to a specified file.
--- If the file exceeds the specified size, the log file will be rotated (renamed and a new file will be created).
--- @param filename: The name of the file where logs will be written.
--- @param maxFileSize: The maximum file size (in bytes) before log rotation occurs.
--- @return None.
----------
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

--
--- Handles log file rotation. If the file size exceeds the specified limit, the current log file will be renamed
--- and a new empty log file will be created.
--- @param filename: The name of the log file.
--- @param maxFileSize: The maximum allowable file size before rotation is triggered.
--- @return None.
----------
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

--
--- Logs a message in JSON format, including level, message, and optional data.
--- @param level: The log level (e.g., "DEBUG", "INFO").
--- @param message: The log message.
--- @param data: Optional additional data to include in the log entry.
--- @return None.
----------
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

--
--- Enables or disables JSON mode for logging. If enabled, log messages will be outputted in JSON format.
--- @param enabled: A boolean indicating whether to enable or disable JSON mode.
--- @return None.
----------
function Logger:setJsonMode(enabled)
    self.useJson = enabled
end

return Logger
