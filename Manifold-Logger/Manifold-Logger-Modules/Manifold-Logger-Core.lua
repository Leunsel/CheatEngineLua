--[[
    The log itself: levels, records, channels, sinks and the ring buffer.

    Plain Lua over os.date and os.time plus one injected tick source. It knows
    nothing about Cheat Engine and nothing about drawing, so it runs and tests
    outside CE, and the console, the file writer and a caller's own callback are
    all the same kind of thing.

      * A record is the unit, not a line of text. Text is derived from it in
        Manifold-Logger-Format, never the other way round.
      * A channel is a named front end onto one log. Every consumer takes its
        own, so the console filters by producer with nobody agreeing on a
        message prefix first. Side-loading goes through this.
      * A sink is anything that consumes records. A sink with its own level
        follows that level, so the file archives TRACE while the console shows
        INFO. A sink without one follows the log.
      * The ring keeps the last Capacity records whatever the display level is.
        A record below the level is kept and marked Suppressed, so the level can
        be turned down after the interesting thing already happened.
      * Flood control is two independent mechanisms. Dedup collapses a repeated
        identical message into one record with a count. The token bucket bounds
        a burst of different messages per channel. Both are on by default and
        both stay visible in the record stream.

    Time. os.date resolves to whole seconds, too coarse to order the lines one
    Auto Assembler script produces. The constructor anchors os.time() against
    the tick source once, then derives each record's time from the tick delta.
    It re-anchors when the derived second and os.time() disagree by more than a
    second. With no tick source it degrades to os.time() and zero milliseconds.
]]

local Core = {}
Core.__index = Core

--
--- ∑ Level ranks. Spaced by ten so an intermediate level can be added later
---   without renumbering the ones a saved configuration already refers to.
---
---   SUCCESS shares INFO's band rather than sitting above it. It marks an INFO
---   that went well, so a viewer filtered to INFO must show it and a viewer
---   filtered to WARNING must not.
--
Core.Levels = {
    TRACE    = 10,
    DEBUG    = 20,
    INFO     = 30,
    SUCCESS  = 35,
    WARNING  = 40,
    ERROR    = 50,
    CRITICAL = 60,
    NONE     = 1000
}

--- Vocabularies other Manifold parts use, mapped onto ours. Manifold.Logger
--- says WARNING, the Template Loader says FATAL, half the world says WARN.
Core.Aliases = {
    WARN = "WARNING",
    FATAL = "CRITICAL",
    CRIT = "CRITICAL",
    ERR = "ERROR",
    VERBOSE = "TRACE",
    OK = "SUCCESS",
    OFF = "NONE"
}

--- Display order and per-level metadata. Icon is the logical icon name in
--- Manifold-Logger-Icons. Color is the artwork's own hue as a Cheat Engine BGR
--- integer, so a row and its glyph always agree.
Core.Order = { "TRACE", "DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR", "CRITICAL" }

Core.Meta = {
    TRACE    = { Rank = 10, Icon = "Trace",    Color = 0xE1BA8D, Tag = "TRC" },
    DEBUG    = { Rank = 20, Icon = "Debug",    Color = 0x0993FF, Tag = "DBG" },
    INFO     = { Rank = 30, Icon = "Info",     Color = 0xDBDE08, Tag = "INF" },
    SUCCESS  = { Rank = 35, Icon = "Success",  Color = 0x0ACD52, Tag = "OK " },
    WARNING  = { Rank = 40, Icon = "Warning",  Color = 0x0CD7EE, Tag = "WRN" },
    ERROR    = { Rank = 50, Icon = "Error",    Color = 0x310BD7, Tag = "ERR" },
    CRITICAL = { Rank = 60, Icon = "Critical", Color = 0xFF30FF, Tag = "CRT" }
}

--- Rank back to name, for the levels that own a rank of their own.
Core.RankNames = {}
for _, name in ipairs(Core.Order) do
    Core.RankNames[Core.Meta[name].Rank] = name
end

Core.Defaults = {
    Capacity      = 5000,   -- records kept in the ring
    Level         = "INFO", -- minimum rank that reaches the sinks
    CaptureLevel  = "TRACE",-- minimum rank that reaches the ring at all
    Dedup         = true,   -- collapse an immediately repeated message
    DedupWindow   = 30,     -- seconds after which a repeat starts a new record
    Throttle      = true,   -- bound a burst of different messages
    ThrottleBurst = 200,    -- records a channel may emit back to back
    ThrottleRate  = 100,    -- records per second a channel refills at
    Channel       = "Manifold"
}

--------------------------------------------------------
--                     Construction                   --
--------------------------------------------------------

--
--- ∑ Resolves a level given as a name, an alias or a rank.
--- @param level string|number # "info", "WARN", 40, ...
--- @return string|nil, number|nil # Canonical name and rank, or nil.
--
function Core.ResolveLevel(level)
    if type(level) == "number" then
        -- An exact rank names a level. Anything else is a threshold and keeps
        -- its number, so a saved filter survives a new level being inserted
        -- between two existing ones.
        local name = Core.RankNames[level]
        if name then return name, level end
        return nil, level
    end
    if type(level) ~= "string" then return nil, nil end
    local upper = level:upper()
    upper = Core.Aliases[upper] or upper
    local rank = Core.Levels[upper]
    if rank then return upper, rank end
    return nil, nil
end

--
--- ∑ The rank a filter should use for a level given in any accepted form.
--- @param level string|number|nil
--- @param fallback number|nil
--- @return number
--
function Core.RankOf(level, fallback)
    local _, rank = Core.ResolveLevel(level)
    return rank or fallback or Core.Levels.TRACE
end

--
--- ∑ Builds a log.
--- @param options table|nil # Any key from Core.Defaults, plus:
---        Ticks function # Millisecond monotonic source (CE: getTickCount).
---        Name string # Shown in the console title bar.
--- @return table
--
function Core:New(options)
    options = options or {}
    local instance = setmetatable({
        Name         = options.Name or "Manifold",
        Capacity     = tonumber(options.Capacity) or Core.Defaults.Capacity,
        Rank         = Core.RankOf(options.Level or Core.Defaults.Level),
        CaptureRank  = Core.RankOf(options.CaptureLevel or Core.Defaults.CaptureLevel),
        Dedup        = options.Dedup ~= false,
        DedupWindow  = tonumber(options.DedupWindow) or Core.Defaults.DedupWindow,
        Throttle     = options.Throttle ~= false,
        ThrottleBurst= tonumber(options.ThrottleBurst) or Core.Defaults.ThrottleBurst,
        ThrottleRate = tonumber(options.ThrottleRate) or Core.Defaults.ThrottleRate,
        DefaultChannel = options.Channel or Core.Defaults.Channel,

        Ring         = {},      -- record array, oldest at RingStart
        RingStart    = 1,
        RingCount    = 0,
        Sequence     = 0,       -- monotonic record id, never reset by the ring

        Channels     = {},      -- name -> channel proxy
        ChannelOrder = {},      -- names in first-seen order
        Sinks        = {},      -- name -> sink
        SinkOrder    = {},
        Listeners    = {},      -- observer callbacks (the console refresh)

        Stats        = { Total = 0, Dropped = 0, Suppressed = 0, Deduped = 0,
                         Reentrant = 0, ByLevel = {}, ByChannel = {} },
        Buckets      = {},      -- channel to token bucket state
        Emitting     = false,   -- reentrancy latch, see :Emit
        Ticks        = type(options.Ticks) == "function" and options.Ticks or nil
    }, Core)
    instance:_AnchorClock()
    instance:Channel(instance.DefaultChannel)
    return instance
end

--------------------------------------------------------
--                        Clock                       --
--------------------------------------------------------

--
--- ∑ Pins the wall clock to the tick source so records can carry milliseconds
---   and a monotonic order. Called again whenever the two disagree by more
---   than a second, which keeps a long session from accumulating tick drift.
--- @return nil
--
function Core:_AnchorClock()
    self.AnchorTime = os.time()
    self.AnchorTick = self.Ticks and self.Ticks() or 0
end

--
--- ∑ Current time as (unix seconds, milliseconds 0..999). Without a tick
---   source the millisecond field is always zero rather than fabricated.
--- @return number, number
--
function Core:Now()
    if not self.Ticks then return os.time(), 0 end
    local elapsed = self.Ticks() - self.AnchorTick
    -- getTickCount wraps at 2^32 on a 49 day uptime. A negative delta is that
    -- wrap, so re-anchor rather than emit a nonsense stamp.
    if elapsed < 0 then
        self:_AnchorClock()
        elapsed = 0
    end
    local seconds = self.AnchorTime + math.floor(elapsed / 1000)
    local wall = os.time()
    if wall < seconds - 1 or wall > seconds + 1 then
        self:_AnchorClock()
        return self.AnchorTime, 0
    end
    return seconds, elapsed % 1000
end

--------------------------------------------------------
--                       Settings                     --
--------------------------------------------------------

--
--- ∑ Minimum level that reaches the sinks. Everything above CaptureLevel still
---   reaches the ring, so the console can show what the console never printed.
--- @param level string|number
--- @return boolean # Whether the level was understood.
--
function Core:SetLevel(level)
    local _, rank = Core.ResolveLevel(level)
    if not rank then return false end
    self.Rank = rank
    return true
end

function Core:GetLevel() return self.Rank end

function Core:GetLevelName()
    return Core.RankNames[self.Rank] or (self.Rank >= Core.Levels.NONE and "NONE") or tostring(self.Rank)
end

--
--- ∑ Floor for the ring. Raising it above TRACE really does discard records.
---   An escape hatch for a session that produces more than the ring can hold,
---   not a second log level.
--- @param level string|number
--- @return boolean
--
function Core:SetCaptureLevel(level)
    local _, rank = Core.ResolveLevel(level)
    if not rank then return false end
    self.CaptureRank = rank
    return true
end

--
--- ∑ Resizes the ring, keeping the newest records when it shrinks.
--- @param capacity number
--- @return boolean
--
function Core:SetCapacity(capacity)
    capacity = math.floor(tonumber(capacity) or 0)
    -- One is a legitimate ring, keep the last record. Zero is not a buffer.
    -- The constructor imposes no minimum either, and two different floors for
    -- the same number would be a trap.
    if capacity < 1 then return false end
    local kept = self:Records()
    local first = math.max(1, #kept - capacity + 1)
    self.Ring, self.RingStart, self.RingCount = {}, 1, 0
    self.Capacity = capacity
    for index = first, #kept do
        self.RingCount = self.RingCount + 1
        self.Ring[self.RingCount] = kept[index]
    end
    return true
end

--------------------------------------------------------
--                      Channels                      --
--------------------------------------------------------

local Channel = {}
Channel.__index = Channel

--
--- ∑ A named front end onto one log. Holds no state of its own beyond the name
---   and optional default fields, so handing one out costs nothing and a
---   consumer cannot break the log by holding it too long.
--- @param name string
--- @param fields table|nil # Merged into every record from this channel.
--- @return table
--
function Core:Channel(name, fields)
    name = tostring(name or self.DefaultChannel)
    local existing = self.Channels[name]
    if existing then
        if fields then existing.Fields = fields end
        return existing
    end
    local channel = setmetatable({ Log = self, Name = name, Fields = fields }, Channel)
    self.Channels[name] = channel
    self.ChannelOrder[#self.ChannelOrder + 1] = name
    return channel
end

--
--- ∑ Channel names in first-seen order, so the console's channel filter has a
---   stable list rather than a pairs() shuffle.
--- @return table
--
function Core:ChannelNames()
    local names = {}
    for index, name in ipairs(self.ChannelOrder) do names[index] = name end
    return names
end

--
--- ∑ A sub-channel. "Framework" becomes "Framework/Teleporter". Filtering by
---   the parent matches the children too, see Core.MatchesChannel.
--- @param name string
--- @return table
--
function Channel:Sub(name)
    return self.Log:Channel(self.Name .. "/" .. tostring(name), self.Fields)
end

--
--- ∑ True when a record's channel is the filter or a descendant of it.
--- @param channel string
--- @param filter string
--- @return boolean
--
function Core.MatchesChannel(channel, filter)
    if channel == filter then return true end
    return channel:sub(1, #filter + 1) == filter .. "/"
end

--------------------------------------------------------
--                        Sinks                       --
--------------------------------------------------------

--
--- ∑ Registers a consumer of records.
--- @param name string # Replaces a sink of the same name.
--- @param sink table|function # A function is wrapped as { Write = fn }.
---        Recognised keys: Write(sink, record), Level, Channels (set of
---        names), Close(sink), Enabled.
--- @return table # The registered sink.
--
function Core:AddSink(name, sink)
    if type(sink) == "function" then
        -- The callback needs its own local first. The sink parameter is about
        -- to be reassigned to the table, and a closure over the parameter
        -- would then call the table instead of the function.
        local callback = sink
        sink = { Write = function(_, record) return callback(record) end }
    end
    if type(sink) ~= "table" or type(sink.Write) ~= "function" then return nil end
    name = tostring(name)
    if self.Sinks[name] then self:RemoveSink(name) end
    sink.Name = name
    -- nil means "follow the log". Only a sink that named a level gets a rank
    -- of its own.
    sink.Rank = sink.Level and Core.RankOf(sink.Level) or nil
    if sink.Enabled == nil then sink.Enabled = true end
    sink.Failures = 0
    self.Sinks[name] = sink
    self.SinkOrder[#self.SinkOrder + 1] = name
    return sink
end

--
--- ∑ Removes a sink and gives it a chance to close whatever it owns.
--- @param name string
--- @return boolean
--
function Core:RemoveSink(name)
    local sink = self.Sinks[name]
    if not sink then return false end
    if type(sink.Close) == "function" then pcall(sink.Close, sink) end
    self.Sinks[name] = nil
    for index, entry in ipairs(self.SinkOrder) do
        if entry == name then table.remove(self.SinkOrder, index) break end
    end
    return true
end

function Core:GetSink(name) return self.Sinks[name] end

--
--- ∑ Observers notified about every ring change, called as (record, kind) with
---   kind "new", "update" (a dedup counter moved) or "clear". The console uses
---   it to know it has to repaint. Failures are swallowed, because logging must
---   not break when a window died.
--- @param callback function
--- @return function # The same callback, so it can be removed later.
--
function Core:AddListener(callback)
    if type(callback) ~= "function" then return nil end
    self.Listeners[#self.Listeners + 1] = callback
    return callback
end

function Core:RemoveListener(callback)
    for index, entry in ipairs(self.Listeners) do
        if entry == callback then table.remove(self.Listeners, index) return true end
    end
    return false
end

--------------------------------------------------------
--                    Flood control                   --
--------------------------------------------------------

--
--- ∑ Token bucket per channel. Returns whether this record may pass, and how
---   many were dropped since the last one that did.
---
---   The bucket refills at ThrottleRate per second and holds ThrottleBurst. A
---   script that logs a hundred lines at load time passes untouched. A hook
---   logging every frame is cut off after the burst and the count is reported
---   instead. Dropped records never reach the ring.
--- @param channel string
--- @param seconds number
--- @return boolean, number
--
function Core:_Admit(channel, seconds)
    if not self.Throttle then return true, 0 end
    local bucket = self.Buckets[channel]
    if not bucket then
        bucket = { Tokens = self.ThrottleBurst, Stamp = seconds, Dropped = 0 }
        self.Buckets[channel] = bucket
    end
    local elapsed = seconds - bucket.Stamp
    if elapsed > 0 then
        bucket.Tokens = math.min(self.ThrottleBurst, bucket.Tokens + elapsed * self.ThrottleRate)
        bucket.Stamp = seconds
    end
    if bucket.Tokens >= 1 then
        bucket.Tokens = bucket.Tokens - 1
        local dropped = bucket.Dropped
        bucket.Dropped = 0
        return true, dropped
    end
    bucket.Dropped = bucket.Dropped + 1
    self.Stats.Dropped = self.Stats.Dropped + 1
    return false, 0
end

--------------------------------------------------------
--                      Emitting                      --
--------------------------------------------------------

--
--- ∑ Appends to the ring, overwriting the oldest record when it is full.
--- @param record table
--- @return table
--
function Core:_Push(record)
    if self.RingCount < self.Capacity then
        self.RingCount = self.RingCount + 1
        self.Ring[self.RingCount] = record
    else
        self.Ring[self.RingStart] = record
        self.RingStart = self.RingStart % self.Capacity + 1
    end
    return record
end

--- The newest record in the ring, or nil.
function Core:Last()
    if self.RingCount == 0 then return nil end
    if self.RingCount < self.Capacity then return self.Ring[self.RingCount] end
    return self.Ring[(self.RingStart + self.Capacity - 2) % self.Capacity + 1]
end

local function notify(self, record, kind)
    for _, listener in ipairs(self.Listeners) do
        pcall(listener, record, kind)
    end
end

--
--- ∑ The one dispatch point. Everything else in this file and every generated
---   helper ends up here.
---
---   The order matters: resolve level, capture filter, dedup, throttle, ring,
---   sinks, listeners. Dedup runs before the throttle so a repeated line
---   collapses into a counter instead of eating the channel's tokens. The ring
---   is written before the sinks so a sink that raises cannot lose the record
---   that explains why.
---
---   Reentrancy. A sink that logs, such as a file writer reporting it cannot
---   write, would recurse without bound. The latch counts the inner record and
---   drops it rather than growing the stack.
--- @param level string|number
--- @param message any
--- @param fields table|nil
--- @param options table|nil # { Channel, Forced, Trace, Pinned, Source }
--- @return table|nil # The record, or nil when it never reached the ring.
--
function Core:Emit(level, message, fields, options)
    options = options or {}
    local name, rank = Core.ResolveLevel(level)
    if not name then name, rank = "INFO", Core.Levels.INFO end
    if self.Emitting then
        -- Counted apart from the flood drops. A sink or a listener logged while
        -- it was being called, which is a defect in that consumer, and the
        -- status bar would otherwise report it as "dropped (flood)".
        self.Stats.Reentrant = self.Stats.Reentrant + 1
        return nil
    end

    local channel = tostring(options.Channel or self.DefaultChannel)
    local visible = options.Forced == true or rank >= self.Rank
    if not visible and rank < self.CaptureRank then
        self.Stats.Suppressed = self.Stats.Suppressed + 1
        return nil
    end

    local seconds, millis = self:Now()
    local text = type(message) == "string" and message or tostring(message)

    -- Dedup. Only against the immediately preceding record, so an alternating
    -- pair of messages is never silently folded into one.
    if self.Dedup then
        local last = self:Last()
        if last and last.Level == name and last.Channel == channel
           and last.Message == text and last.Forced == (options.Forced == true)
           and (seconds - last.Time) <= self.DedupWindow then
            last.Repeats = last.Repeats + 1
            last.LastTime, last.LastMillis = seconds, millis
            self.Stats.Deduped = self.Stats.Deduped + 1
            self.Emitting = true
            notify(self, last, "update")
            self.Emitting = false
            return last
        end
    end

    local admitted, dropped = self:_Admit(channel, seconds)
    if not admitted then return nil end

    self.Sequence = self.Sequence + 1
    local record = {
        Seq       = self.Sequence,
        Time      = seconds,
        Millis    = millis,
        LastTime  = seconds,
        LastMillis= millis,
        Level     = name,
        Rank      = rank,
        Channel   = channel,
        Message   = text,
        Fields    = fields,
        Repeats   = 1,
        Forced    = options.Forced == true,
        Suppressed= not visible,
        Pinned    = options.Pinned == true,
        Source    = options.Source,
        Trace     = options.Trace,
        Dropped   = dropped > 0 and dropped or nil
    }
    self:_Push(record)

    self.Stats.Total = self.Stats.Total + 1
    self.Stats.ByLevel[name] = (self.Stats.ByLevel[name] or 0) + 1
    self.Stats.ByChannel[channel] = (self.Stats.ByChannel[channel] or 0) + 1
    if not visible then self.Stats.Suppressed = self.Stats.Suppressed + 1 end

    -- The latch spans the sinks AND the listeners. Both are foreign code that
    -- may well log, a file writer reporting it cannot write or a view raising
    -- while it repaints, and a recursion here would be unbounded.
    self.Emitting = true
    -- Each sink is gated by its own level. A sink that asked for one gets what
    -- it asked for, which is how the file archives records the console level
    -- hides. A sink that did not ask follows the log, so turning the log down
    -- quietens print and the console together. CaptureRank above is still the
    -- hard floor. Nothing below it becomes a record, so no sink can see it.
    for _, sinkName in ipairs(self.SinkOrder) do
        local sink = self.Sinks[sinkName]
        if sink and sink.Enabled
           and (options.Forced == true or rank >= (sink.Rank or self.Rank))
           and (not sink.Channels or sink.Channels[channel]) then
            local ok, err = pcall(sink.Write, sink, record)
            if not ok then
                -- A sink that raises is disabled after three failures rather
                -- than retried on every line for the rest of the session. The
                -- reason is kept on the sink itself.
                sink.Failures = sink.Failures + 1
                sink.LastError = tostring(err)
                if sink.Failures >= 3 then sink.Enabled = false end
            end
        end
    end
    notify(self, record, "new")
    self.Emitting = false
    return record
end

--------------------------------------------------------
--                   Reading the ring                 --
--------------------------------------------------------

--
--- ∑ Every record, oldest first. A fresh array, so a caller may sort or
---   truncate it without disturbing the ring.
--- @return table
--
function Core:Records()
    local out = {}
    if self.RingCount < self.Capacity then
        for index = 1, self.RingCount do out[index] = self.Ring[index] end
        return out
    end
    for offset = 0, self.Capacity - 1 do
        out[offset + 1] = self.Ring[(self.RingStart + offset - 1) % self.Capacity + 1]
    end
    return out
end

--
--- ∑ The ring position of the oldest and newest records. An incremental
---   consumer uses them to notice that records fell off the front without
---   materialising the buffer to find out.
--- @return number, number # oldest Seq, newest Seq. Both 0 when empty.
--
function Core:Bounds()
    if self.RingCount == 0 then return 0, 0 end
    local newest = self:Last()
    local oldest
    if self.RingCount < self.Capacity then
        oldest = self.Ring[1]
    else
        oldest = self.Ring[self.RingStart]
    end
    return oldest and oldest.Seq or 0, newest and newest.Seq or 0
end

--
--- ∑ Records newer than seq, oldest first.
---
---   Walks BACKWARDS from the newest and stops as soon as it reaches seq, so
---   the cost is the number of new records rather than the size of the ring.
---   The console refresh then costs what arrived, not what it is holding.
--- @param seq number
--- @param limit number|nil # Stop after this many, newest kept.
--- @return table
--
function Core:Since(seq, limit)
    seq = seq or 0
    local out = {}
    local count = self.RingCount
    if count == 0 then return out end
    local capacity = self.Capacity
    local wrapped = count >= capacity
    for offset = count - 1, 0, -1 do
        local index = wrapped and ((self.RingStart + offset - 1) % capacity + 1) or (offset + 1)
        local record = self.Ring[index]
        if not record or record.Seq <= seq then break end
        out[#out + 1] = record
        if limit and #out >= limit then break end
    end
    -- Collected newest first. Hand back oldest first, which is display order.
    local reversed = {}
    for index = #out, 1, -1 do reversed[#reversed + 1] = out[index] end
    return reversed
end

--
--- ∑ Walks the ring oldest first without materialising it. Records() allocates
---   an array the size of the buffer, which a consumer that only looks at each
---   record once should not pay for.
--- @param visit function # Called as (record, index). Return false to stop.
--- @return number # How many records were visited.
--
function Core:ForEach(visit)
    local count = self.RingCount
    if count == 0 then return 0 end
    local capacity = self.Capacity
    local wrapped = count >= capacity
    for offset = 0, count - 1 do
        local index = wrapped and ((self.RingStart + offset - 1) % capacity + 1) or (offset + 1)
        local record = self.Ring[index]
        if record and visit(record, offset + 1) == false then return offset + 1 end
    end
    return count
end

--
--- ∑ True when a record passes a filter.
--- @param record table
--- @param filter table|nil # { MinRank, Levels (name set), Channel (name or
---        set), Search (plain, case-insensitive), PinnedOnly, IncludeSuppressed }
--- @param haystack string|nil # Pre-rendered text to search, when the caller
---        already has one. It must ALREADY BE LOWERCASE. Lowering it here would
---        put an O(message) allocation back on the per-record path this
---        argument exists to remove. Falls back to the message plus the
---        channel, lowered on the spot.
--- @param searchLower string|nil # filter.Search, lowered once by the caller.
--- @return boolean
--
function Core.Matches(record, filter, haystack, searchLower)
    if not filter then return true end
    if filter.MinRank and record.Rank < filter.MinRank then return false end
    if filter.Levels and not filter.Levels[record.Level] then return false end
    if filter.PinnedOnly and not record.Pinned then return false end
    if filter.IncludeSuppressed == false and record.Suppressed then return false end
    local channel = filter.Channel
    if channel then
        if type(channel) == "string" then
            if not Core.MatchesChannel(record.Channel, channel) then return false end
        elseif type(channel) == "table" then
            local hit = false
            for name in pairs(channel) do
                if Core.MatchesChannel(record.Channel, name) then hit = true break end
            end
            if not hit then return false end
        end
    end
    local search = searchLower
    if search == nil and filter.Search and filter.Search ~= "" then
        search = filter.Search:lower()
    end
    if search and search ~= "" then
        local text = haystack or (record.Message .. " " .. record.Channel):lower()
        if not text:find(search, 1, true) then return false end
    end
    return true
end

--
--- ∑ Filtered snapshot plus what the filter hid, which the status bar needs in
---   order to say "412 of 5000" honestly.
--- @param filter table|nil
--- @param render function|nil # Renders a record to searchable text.
--- @return table, table # records, { Total, Shown, Hidden, Suppressed }
--
function Core:Snapshot(filter, render)
    local all = self:Records()
    local out, suppressed = {}, 0
    -- Lowered once for the whole pass rather than once per record.
    local searchLower = filter and filter.Search and filter.Search ~= ""
        and filter.Search:lower() or nil
    for index = 1, #all do
        local record = all[index]
        if Core.Matches(record, filter, render and render(record) or nil, searchLower) then
            out[#out + 1] = record
            if record.Suppressed then suppressed = suppressed + 1 end
        end
    end
    return out, {
        Total = #all, Shown = #out, Hidden = #all - #out, Suppressed = suppressed
    }
end

--
--- ∑ Empties the ring. The counters survive on purpose. They describe the
---   session, not the buffer, and a cleared view that also reset "142 errors"
---   would hide the very thing the user cleared the noise to find.
--- @return nil
--
function Core:Clear()
    self.Ring, self.RingStart, self.RingCount = {}, 1, 0
    -- Inside the latch, like every other call into foreign code. A listener
    -- that logs while the buffer is being emptied would otherwise land a record
    -- in the ring the clear had just emptied.
    self.Emitting = true
    notify(self, nil, "clear")
    self.Emitting = false
end

--
--- ∑ Session counters, with the per-level table filled in for every level so a
---   caller can iterate Core.Order without nil checks.
--- @return table
--
function Core:GetStats()
    local stats = {
        Total = self.Stats.Total, Dropped = self.Stats.Dropped,
        Suppressed = self.Stats.Suppressed, Deduped = self.Stats.Deduped,
        Reentrant = self.Stats.Reentrant,
        Buffered = self.RingCount, Capacity = self.Capacity,
        ByLevel = {}, ByChannel = {}
    }
    for _, name in ipairs(Core.Order) do
        stats.ByLevel[name] = self.Stats.ByLevel[name] or 0
    end
    for name, count in pairs(self.Stats.ByChannel) do
        stats.ByChannel[name] = count
    end
    return stats
end

--------------------------------------------------------
--                  Structured helpers                --
--------------------------------------------------------

--
--- ∑ A named event with structured fields, what a machine-readable log wants
---   instead of a sentence. The message stays human-readable so the console
---   shows something useful. The fields are what JSON-lines export and any
---   later analysis read.
--- @param name string # Dotted event name, e.g. "trampoline.install".
--- @param fields table|nil
--- @param options table|nil # { Level, Channel, Forced }
--- @return table|nil
--
function Core:Event(name, fields, options)
    options = options or {}
    local record = self:Emit(options.Level or "INFO", tostring(name), fields, {
        Channel = options.Channel, Forced = options.Forced
    })
    if record then record.Event = tostring(name) end
    return record
end

local Scope = {}
Scope.__index = Scope

--
--- ∑ A timed section. Opens with a TRACE line, closes with one record that
---   carries the elapsed milliseconds as a field, so "what took so long"
---   becomes a sort rather than a subtraction done by eye.
--- @param label string
--- @param options table|nil # { Level, Channel, Fields }
--- @return table
--
function Core:Scope(label, options)
    options = options or {}
    local seconds, millis = self:Now()
    local scope = setmetatable({
        Log = self, Label = tostring(label),
        Level = options.Level or "INFO",
        Channel = options.Channel,
        Fields = options.Fields,
        Start = seconds * 1000 + millis,
        Steps = 0, Closed = false
    }, Scope)
    self:Emit("TRACE", scope.Label .. " ...", options.Fields, { Channel = scope.Channel })
    return scope
end

function Scope:Elapsed()
    local seconds, millis = self.Log:Now()
    return (seconds * 1000 + millis) - self.Start
end

local function scopeFields(self, extra)
    local fields = { elapsed_ms = self:Elapsed() }
    for key, value in pairs(self.Fields or {}) do fields[key] = value end
    for key, value in pairs(extra or {}) do fields[key] = value end
    return fields
end

--- A progress line inside the scope. TRACE, so it is invisible unless somebody
--- went looking.
function Scope:Step(message, fields)
    self.Steps = self.Steps + 1
    return self.Log:Emit("TRACE", self.Label .. ": " .. tostring(message),
        scopeFields(self, fields), { Channel = self.Channel })
end

--- Closes the scope successfully. Idempotent, a scope closed twice logs once.
function Scope:Done(message, fields)
    if self.Closed then return nil end
    self.Closed = true
    return self.Log:Emit(self.Level,
        string.format("%s (%d ms)", message and tostring(message) or self.Label, self:Elapsed()),
        scopeFields(self, fields), { Channel = self.Channel })
end

--- Closes the scope as a failure, at ERROR.
function Scope:Fail(message, fields)
    if self.Closed then return nil end
    self.Closed = true
    return self.Log:Emit("ERROR",
        string.format("%s failed after %d ms: %s", self.Label, self:Elapsed(), tostring(message)),
        scopeFields(self, fields), { Channel = self.Channel })
end

--
--- ∑ Runs fn under pcall and logs the failure with a traceback attached to the
---   record. Returns exactly what pcall does, so a caller can still decide what
---   a failure means.
---
---   debug.traceback is called INSIDE an xpcall handler. By the time pcall has
---   returned the failing stack is unwound, and a traceback would describe this
---   function instead of the fault.
--- @param fn function
--- @param label string|nil
--- @param options table|nil # { Channel, Level }
--- @return boolean, any
--
function Core:Catch(fn, label, options)
    options = options or {}
    if type(fn) ~= "function" then return false, "not a function" end
    local trace
    local ok, err = xpcall(fn, function(message)
        trace = debug and debug.traceback and debug.traceback(tostring(message), 2) or nil
        return message
    end)
    if not ok then
        self:Emit(options.Level or "ERROR",
            string.format("%s raised: %s", label and tostring(label) or "call", tostring(err)),
            nil, { Channel = options.Channel, Trace = trace })
    end
    return ok, err
end

--------------------------------------------------------
--                 Generated level API                --
--------------------------------------------------------

--
--- ∑ Every level gets four shapes on both Core and Channel:
---     Info(message, fields)          the plain line
---     InfoF(format, ...)             string.format at the call site
---     ForceInfo(message, fields)     bypasses the level filter
---     ForceInfoF(format, ...)
---   The names are title-cased so they read as methods, log:Warning and
---   log:Critical, rather than as constants.
--
local function titleCase(name)
    return name:sub(1, 1):upper() .. name:sub(2):lower()
end

for _, level in ipairs(Core.Order) do
    local title = titleCase(level)

    Core[title] = function(self, message, fields)
        return self:Emit(level, message, fields)
    end
    Core[title .. "F"] = function(self, format, ...)
        return self:Emit(level, string.format(tostring(format), ...))
    end
    Core["Force" .. title] = function(self, message, fields)
        return self:Emit(level, message, fields, { Forced = true })
    end
    Core["Force" .. title .. "F"] = function(self, format, ...)
        return self:Emit(level, string.format(tostring(format), ...), nil, { Forced = true })
    end

    Channel[title] = function(self, message, fields)
        return self.Log:Emit(level, message, fields or self.Fields, { Channel = self.Name })
    end
    Channel[title .. "F"] = function(self, format, ...)
        return self.Log:Emit(level, string.format(tostring(format), ...), self.Fields,
            { Channel = self.Name })
    end
    Channel["Force" .. title] = function(self, message, fields)
        return self.Log:Emit(level, message, fields or self.Fields,
            { Channel = self.Name, Forced = true })
    end
    Channel["Force" .. title .. "F"] = function(self, format, ...)
        return self.Log:Emit(level, string.format(tostring(format), ...), self.Fields,
            { Channel = self.Name, Forced = true })
    end
end

--- The channel versions of everything except the levels themselves.
function Channel:Emit(level, message, fields, options)
    options = options or {}
    options.Channel = self.Name
    return self.Log:Emit(level, message, fields or self.Fields, options)
end

function Channel:Event(name, fields, options)
    options = options or {}
    options.Channel = self.Name
    return self.Log:Event(name, fields or self.Fields, options)
end

function Channel:Scope(label, options)
    options = options or {}
    options.Channel = self.Name
    return self.Log:Scope(label, options)
end

function Channel:Catch(fn, label, options)
    options = options or {}
    options.Channel = self.Name
    return self.Log:Catch(fn, label, options)
end

--
--- ∑ Logs a condition failure and returns the condition, so a caller can write
---   if not log:Check(x, "no x") then return end without a second branch that
---   says the same thing.
--- @param condition any
--- @param message string
--- @param fields table|nil
--- @return any # The condition, unchanged.
--
function Core:Check(condition, message, fields)
    if not condition then self:Emit("ERROR", message, fields) end
    return condition
end

function Channel:Check(condition, message, fields)
    if not condition then self:Emit("ERROR", message, fields) end
    return condition
end

Core.ChannelClass = Channel
Core.ScopeClass = Scope

return Core
