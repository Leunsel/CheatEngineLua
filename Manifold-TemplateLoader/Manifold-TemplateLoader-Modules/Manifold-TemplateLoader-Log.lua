--[[
    Logging for the Template Loader.

    Levels: TRACE < DEBUG < INFO < WARNING < ERROR < FATAL.

    Discarding below-level entries would save close to nothing anyway. The
    call sites build their text with string.format BEFORE calling in, so the
    formatting cost is already paid by the time the level is checked. What is
    added here is one os.date, one table and one ring slot per call, against
    a buffer that is bounded by construction.
    File output is optional and guarded by a reentrancy latch. A failure
    while writing the log must never log again.
    The logger is infrastructure only. It needs no configuration to work,
    before Config is loaded it simply prints, so no module can fail just
    because logging is not set up yet.
]]

local Log = {}
Log.__index = Log

Log.LogLevel = {
    TRACE = 1,
    DEBUG = 2,
    INFO = 3,
    WARNING = 4,
    ERROR = 5,
    FATAL = 6,
    NONE = 7,
    -- Legacy aliases from the 2.x configuration schema.
    CRITICAL = 6
}

Log.LevelNames = {
    [1] = "TRACE",
    [2] = "DEBUG",
    [3] = "INFO",
    [4] = "WARNING",
    [5] = "ERROR",
    [6] = "FATAL",
    [7] = "NONE"
}

Log.RingSize = 500

function Log:New(options)
    options = options or {}
    local instance = setmetatable({
        CurrentLevel = Log.LogLevel.ERROR,
        -- Everything reaches the ring. CurrentLevel only gates the output.
        CaptureLevel = Log.LogLevel.TRACE,
        LogToFile = false,
        LogFileName = options.LogFileName,
        Ring = {},
        RingStart = 1,
        RingCount = 0,
        Listeners = {},
        _writingToFile = false
    }, Log)
    return instance
end

function Log:GetLogLevel() return self.CurrentLevel end

--
--- Floor for the ring buffer. Raising it above TRACE really does drop
--- entries, the viewer can then never show them, so this exists as an
--- escape hatch, not as a second log level.
--
function Log:SetCaptureLevel(level)
    if type(level) == "string" then level = Log.LogLevel[level:upper()] end
    if type(level) == "number" and Log.LevelNames[level] then
        self.CaptureLevel = level
        return true
    end
    return false
end

function Log:GetLogLevelName()
    return Log.LevelNames[self.CurrentLevel] or "UNKNOWN"
end

function Log:SetLogLevel(level)
    if type(level) == "string" then level = Log.LogLevel[level:upper()] end
    if type(level) == "number" and Log.LevelNames[level] then
        self.CurrentLevel = level
        return true
    end
    return false
end

function Log:SetLogFile(path)
    if type(path) == "string" and path ~= "" then self.LogFileName = path end
end

--
--- Registers a callback invoked with each new entry (the log viewer uses
--- this to refresh live). Listener failures are swallowed. Logging must
--- never break because a UI observer died.
--
function Log:AddListener(callback)
    if type(callback) == "function" then
        self.Listeners[#self.Listeners + 1] = callback
    end
end

function Log:ClearListeners()
    self.Listeners = {}
end

local function formatFields(fields)
    if type(fields) ~= "table" then return "" end
    local parts = {}
    for _, key in ipairs({ "generation", "template", "stage", "provider" }) do
        if fields[key] ~= nil then
            parts[#parts + 1] = string.format("[%s:%s]", key:sub(1, 1):upper() .. key:sub(2), tostring(fields[key]))
        end
    end
    if fields.duration ~= nil then
        parts[#parts + 1] = string.format("(%.2f ms)", tonumber(fields.duration) or 0)
    end
    if #parts == 0 then return "" end
    return " " .. table.concat(parts, " ")
end

function Log:_Push(entry)
    local index
    if self.RingCount < Log.RingSize then
        self.RingCount = self.RingCount + 1
        index = self.RingCount
    else
        index = self.RingStart
        self.RingStart = self.RingStart % Log.RingSize + 1
    end
    self.Ring[index] = entry
    for _, listener in ipairs(self.Listeners) do
        pcall(listener, entry)
    end
end

--
--- Ring entries oldest-first, optionally filtered by minimum level and a
--- plain-text (case-insensitive) search over the formatted line.
--
function Log:GetEntries(minLevel, search)
    local entries, suppressed = {}, 0
    search = type(search) == "string" and search ~= "" and search:lower() or nil
    for offset = 0, self.RingCount - 1 do
        local index = self.RingCount < Log.RingSize
            and offset + 1
            or (self.RingStart + offset - 1) % Log.RingSize + 1
        local entry = self.Ring[index]
        if entry and (not minLevel or entry.Level >= minLevel) then
            if not search or entry.Text:lower():find(search, 1, true) then
                entries[#entries + 1] = entry
                if entry.Suppressed then suppressed = suppressed + 1 end
            end
        end
    end
    return entries, suppressed
end

function Log:ClearEntries()
    self.Ring = {}
    self.RingStart = 1
    self.RingCount = 0
end

function Log:_Emit(level, message, fields, forced)
    local visible = forced or level >= self.CurrentLevel
    if not visible and level < (self.CaptureLevel or Log.LogLevel.TRACE) then return end
    local text = string.format("[%s] [%s]%s %s",
        os.date("%H:%M:%S"), Log.LevelNames[level] or "UNKNOWN", formatFields(fields), tostring(message))
    -- Suppressed entries are kept and flagged rather than dropped, so the
    -- viewer can both show them and say how many never reached the console.
    self:_Push({ Level = level, Text = text, Time = os.time(), Suppressed = not visible })
    if not visible then return end

    print(text)
    self:_WriteToFile(text)
end

function Log:_WriteToFile(text)
    if not self.LogToFile or not self.LogFileName then return end
    if self._writingToFile then return end
    self._writingToFile = true
    local ok = pcall(function()
        local handle = io.open(self.LogFileName, "a")
        if handle then
            handle:write(text .. "\n")
            handle:close()
        end
    end)
    self._writingToFile = false
    if not ok then
        -- Disable rather than retry forever against an unwritable path.
        self.LogToFile = false
        print("[TemplateLoader.Log] Log file is not writable. File logging disabled.")
    end
end

function Log:ClearLogFile()
    if not self.LogFileName then return end
    pcall(function()
        local handle = io.open(self.LogFileName, "w")
        if handle then handle:close() end
    end)
end

function Log:Stringify(value)
    if type(value) ~= "table" then return tostring(value) end
    local parts = {}
    for key, entry in pairs(value) do
        if type(entry) == "table" then
            entry = self:Stringify(entry)
        elseif type(entry) == "string" then
            entry = '"' .. entry .. '"'
        end
        parts[#parts + 1] = tostring(key) .. ": " .. tostring(entry)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

-- Generated per-level API. log:Debug(msg, fields), log:DebugF(fmt, ...),
-- log:ForceDebug(msg) and so on for every level name.
for name, level in pairs({ TRACE = 1, DEBUG = 2, INFO = 3, WARNING = 4, ERROR = 5, FATAL = 6 }) do
    local title = name:sub(1, 1):upper() .. name:sub(2):lower()
    Log[title] = function(self, message, fields)
        self:_Emit(level, message, fields, false)
    end
    Log[title .. "F"] = function(self, formatString, ...)
        self:_Emit(level, string.format(formatString, ...), nil, false)
    end
    Log["Force" .. title] = function(self, message, fields)
        self:_Emit(level, message, fields, true)
    end
    Log["Force" .. title .. "F"] = function(self, formatString, ...)
        self:_Emit(level, string.format(formatString, ...), nil, true)
    end
end

-- Legacy alias: 2.x code and configs said CRITICAL where 3.x says FATAL.
Log.Critical = Log.Fatal
Log.ForceCritical = Log.ForceFatal

return Log