--[[
    One place for this segment to log to.

    When Manifold Logger is installed, every line goes through a channel named
    "Address List". The lines then appear in the console beside the other
    Manifold tools, they filter along with them, and they land in the same log
    file. When the Logger is not installed, the same lines fall back to a
    timestamped print of the same shape, so nothing is lost and nothing raises.

    The channel is looked up again on every call, and that is deliberate.
    Autorun files run in an order nobody controls, so the Logger may not exist
    yet when this segment loads. The Logger can also be shut down and built
    again while Cheat Engine keeps running. A channel that had been captured
    once and held onto would then be writing into a buffer that no window
    shows. Comparing the host by identity is what notices a rebuilt one.

    House rules this module exists to serve. One line per completed operation.
    More than one fact is one Block. A loop reports once after the loop, never
    per item. A failure names the subject and the reason. There are no lines
    that announce what is about to happen.
]]

local Log = {}
Log.__index = Log

Log.ChannelName = "Address List"

--
--- ∑ Builds the channel front end. Nothing is resolved here, because the
---   Logger may well arrive after this segment did.
--- @param options table|nil # Print replaces the fallback sink, which is what
---        the tests capture.
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
--- ∑ The live channel, or nil when there is no Logger to write to. Called on
---   every emit, so a Logger that appears later is picked up and one that was
---   rebuilt is noticed by identity.
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

--- Whether the lines are reaching the Logger. The status block says which of
--- the two sinks is in use, so the user knows where to look for them.
function Log:Attached()
    return self:Resolve() ~= nil
end

--- The fallback shape matches the console, so a printed line and a logged one
--- read the same. A channel call that fails falls through to it rather than
--- swallowing the line.
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
        os.date("%H:%M:%S") or "??:??:??", level:upper(), Log.ChannelName, tostring(message)))
end

function Log:Debug(message) emit(self, "Debug", message) end
function Log:Info(message) emit(self, "Info", message) end
function Log:Warning(message) emit(self, "Warning", message) end
function Log:Error(message) emit(self, "Error", message) end

--
--- ∑ Renders a report of several rows as one string. It does not log. The
---   caller picks the level, which is why a failure block reads
---   log.Warning(log.Block(title, rows)) and a status block reads
---   log.Info(log.Block(title, rows)).
---
---   A row is either a table holding a label and a value, or a bare string. A
---   row written as false is skipped, which lets a conditional row be written
---   inline. A nil row would end the walk early and lose every row after it.
--- @param title string # The first line.
--- @param rows table # The rows, in display order.
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
