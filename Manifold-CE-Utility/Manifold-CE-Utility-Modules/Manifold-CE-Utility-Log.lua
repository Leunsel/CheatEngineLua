--[[
    One place to log to.

    When Manifold Logger is installed, everything goes through a channel
    named "CE Utility", so it shows up in the console with the other
    Manifold tools, filters with them and lands in the same log file.
    Without it, lines fall back to a timestamped print in the shape the
    rest of the Manifold tools use.

    The channel is resolved at call time, not at load time. Autorun files run
    in an order nobody controls, and the Logger can be shut down and rebuilt
    while Cheat Engine is running; a channel captured once would then write
    into a buffer no window shows. Holding the host it came from and
    comparing on every call is what keeps this correct across a rebuild.
]]

local Log = {}
Log.__index = Log

Log.ChannelName = "CE Utility"

--
--- ∑ Builds a logger.
--- @param options table|nil # { Print } to replace the fallback sink (tests).
--- @return table
--
function Log:New(options)
    options = options or {}
    return setmetatable({
        Channel = nil,
        HostSeen = nil,
        Print = options.Print or print
    }, Log)
end

--
--- ∑ The Manifold Logger channel, or nil when the Logger is not installed.
--- @return table|nil
--
function Log:Resolve()
    local host = rawget(_G, "ManifoldLogger")
    if type(host) ~= "table" or type(host.Channel) ~= "function" then
        self.Channel, self.HostSeen = nil, nil
        return nil
    end
    if self.Channel and self.HostSeen == host then return self.Channel end
    local ok, channel = pcall(host.Channel, host, Log.ChannelName)
    if ok and type(channel) == "table" then
        self.Channel, self.HostSeen = channel, host
        return channel
    end
    self.Channel, self.HostSeen = nil, nil
    return nil
end

--- Whether lines currently reach the Manifold Logger.
function Log:Attached()
    return self:Resolve() ~= nil
end

local function emit(self, level, message)
    local channel = self:Resolve()
    if channel then
        local method = channel[level]
        if type(method) == "function" then
            local ok = pcall(method, channel, message)
            if ok then return end
        end
    end
    self.Print(string.format("[%s] [%s] [%s] %s",
        os.date("%H:%M:%S") or "??:??:??",
        level:upper(),
        Log.ChannelName,
        tostring(message)))
end

function Log:Debug(message) emit(self, "Debug", message) end
function Log:Info(message) emit(self, "Info", message) end
function Log:Warning(message) emit(self, "Warning", message) end
function Log:Error(message) emit(self, "Error", message) end

--
--- ∑ A multi-row report rendered as one record, with labels that line up.
---   Rows are { label, value } pairs or bare strings; false skips a row, so a
---   conditional row can be written inline without leaving a hole that
---   would stop the walk.
--- @param title string
--- @param rows table
--- @return string
--
function Log:Block(title, rows)
    local host = rawget(_G, "ManifoldLogger")
    if type(host) == "table" and type(host.Block) == "function" then
        local ok, text = pcall(host.Block, host, title, rows)
        if ok and type(text) == "string" then return text end
    end
    local width = 0
    for _, row in ipairs(rows) do
        if type(row) == "table" and row[1] ~= nil then
            width = math.max(width, #tostring(row[1]))
        end
    end
    local lines = { tostring(title) }
    for _, row in ipairs(rows) do
        if type(row) == "table" then
            lines[#lines + 1] = string.format("  %-" .. width .. "s : %s",
                tostring(row[1]), tostring(row[2]))
        elseif type(row) == "string" then
            lines[#lines + 1] = row == "" and "" or ("  " .. row)
        end
    end
    return table.concat(lines, "\n")
end

return Log
