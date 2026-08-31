--[[
    Everything that turns a record into characters.

    Kept apart from the log because a record has four renderings, and the log
    has no reason to prefer one of them.

      * the console draws it in COLUMNS and needs each piece separately
      * the log file wants ONE LINE, prefix and all
      * an export wants JSON LINES, so the fields survive as fields
      * the clipboard wants PLAIN TEXT that reads well pasted into an issue

    A logger that formats at emit time can only produce the second. This file
    has no state and touches nothing outside Lua, so all four are the same
    cheap function over the same record.

    Stringify is bounded on depth, bounded on element count and cycle-safe.
    What gets handed to a logger on a bad afternoon is a Cheat Engine userdata
    graph or a table that points at itself, and a logger that hangs while
    explaining a hang is worse than no logger.
]]

local Format = {}

Format.MaxDepth = 4        -- nesting levels Stringify will descend
Format.MaxItems = 32       -- entries per table before it says "..."
Format.MaxString = 4096    -- characters a single value may contribute

--------------------------------------------------------
--                       Scalars                      --
--------------------------------------------------------

--
--- ∑ Shortens a string to limit characters and marks that it was shortened.
--- @param text any
--- @param limit number|nil
--- @return string
--
function Format.Truncate(text, limit)
    text = tostring(text)
    limit = limit or Format.MaxString
    if #text <= limit then return text end
    return text:sub(1, limit - 3) .. "..."
end

--
--- ∑ Control characters made visible. A raw \r silently overwrites the line in
---   a console and truncates in a memo, and a NUL ends the string in half the
---   Win32 APIs it will pass through.
--- @param text string
--- @return string
--
function Format.Printable(text)
    return (tostring(text)
        :gsub("%z", "\\0")
        :gsub("\r\n", "\n")
        :gsub("\r", "\n")
        :gsub("\t", "    ")
        :gsub("[%z\1-\8\11\12\14-\31]", "?"))
end

--
--- ∑ Milliseconds as something a human reads at a glance.
--- @param ms number
--- @return string
--
function Format.Duration(ms)
    ms = tonumber(ms) or 0
    if ms < 1000 then return string.format("%d ms", ms) end
    if ms < 60000 then return string.format("%.2f s", ms / 1000) end
    return string.format("%d m %02d s", math.floor(ms / 60000), math.floor(ms % 60000 / 1000))
end

--
--- ∑ A byte count with a unit.
--- @param bytes number
--- @return string
--
function Format.Bytes(bytes)
    bytes = tonumber(bytes) or 0
    local units = { "B", "KB", "MB", "GB" }
    local index = 1
    while bytes >= 1024 and index < #units do
        bytes = bytes / 1024
        index = index + 1
    end
    if index == 1 then return string.format("%d %s", bytes, units[index]) end
    return string.format("%.1f %s", bytes, units[index])
end

--------------------------------------------------------
--                    Table rendering                 --
--------------------------------------------------------

--
--- ∑ Deterministic key order. Numbers ascending, then everything else by its
---   string form. pairs() order is a hash walk, so without this the same table
---   renders differently on two runs and a diff of two logs is noise.
--- @param value table
--- @return table
--
local function sortedKeys(value)
    local numbers, others = {}, {}
    for key in pairs(value) do
        if type(key) == "number" then numbers[#numbers + 1] = key
        else others[#others + 1] = key end
    end
    table.sort(numbers)
    table.sort(others, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(others) do numbers[#numbers + 1] = key end
    return numbers
end

--- True when the table is a dense 1..n array, which renders as a list.
local function isArray(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
    end
    return count == #value
end

--
--- ∑ Any Lua value as a bounded, cycle-safe string.
--- @param value any
--- @param options table|nil # { Depth, MaxItems, Quote }
--- @return string
--
function Format.Stringify(value, options)
    options = options or {}
    local maxDepth = options.Depth or Format.MaxDepth
    local maxItems = options.MaxItems or Format.MaxItems
    local quote = options.Quote == true
    local seen = {}

    local function render(item, depth)
        local kind = type(item)
        if kind == "string" then
            local text = Format.Truncate(Format.Printable(item))
            return quote and ('"' .. text:gsub('"', '\\"') .. '"') or text
        elseif kind == "number" then
            if item % 1 == 0 and math.abs(item) < 1e15 then return string.format("%d", item) end
            return tostring(item)
        elseif kind == "boolean" or kind == "nil" then
            return tostring(item)
        elseif kind ~= "table" then
            -- Functions, userdata and threads have nothing but an address, and
            -- the address still tells two CE objects apart.
            return tostring(item)
        end
        if seen[item] then return "<cycle>" end
        if depth > maxDepth then return "{...}" end
        seen[item] = true
        local parts, count = {}, 0
        if isArray(item) then
            for index = 1, #item do
                count = count + 1
                if count > maxItems then parts[#parts + 1] = "..." break end
                parts[#parts + 1] = render(item[index], depth + 1)
            end
            seen[item] = nil
            return "[" .. table.concat(parts, ", ") .. "]"
        end
        for _, key in ipairs(sortedKeys(item)) do
            count = count + 1
            if count > maxItems then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = tostring(key) .. " = " .. render(item[key], depth + 1)
        end
        seen[item] = nil
        return "{ " .. table.concat(parts, ", ") .. " }"
    end

    return render(value, 1)
end

--
--- ∑ A structured field table as key=value pairs, in key order. Values holding
---   a space are quoted, so the result stays parseable by eye and by a
---   one-line grep.
--- @param fields table|nil
--- @return string # Empty when there is nothing to show.
--
function Format.Fields(fields)
    if type(fields) ~= "table" then return "" end
    local parts = {}
    for _, key in ipairs(sortedKeys(fields)) do
        local value = Format.Stringify(fields[key], { Depth = 2, MaxItems = 8 })
        if value:find("[%s=]") then value = '"' .. value:gsub('"', "'") .. '"' end
        parts[#parts + 1] = tostring(key) .. "=" .. value
    end
    return table.concat(parts, " ")
end

--------------------------------------------------------
--                        Blocks                      --
--------------------------------------------------------

--
--- ∑ Renders a titled block of label/value rows into one string.
---
---   The same block written as N log calls repeats the timestamp and the
---   channel on every row, which is most of the line width. Building it here
---   gives one record, one prefix, and labels that line up on their own rather
---   than by hand-counted padding in each format string. The console indents
---   the continuation lines under their record, so a block stays one
---   selectable, copyable unit.
--- @param title string|nil # First line, or nil for a headless block.
--- @param rows table # Array of {label, value} pairs or plain strings.
---        Use false to skip a row. A bare nil would cut the list short, since
---        the walk is an ipairs and stops at the first hole.
--- @param options table|nil # { Indent = "   ", Separator = " : ", Align = true }
--- @return string
--
function Format.Block(title, rows, options)
    options = options or {}
    local indent = options.Indent or "   "
    local separator = options.Separator or " : "
    local align = options.Align ~= false
    local entries, labelWidth = {}, 0
    for _, row in ipairs(rows or {}) do
        if row then
            if type(row) == "table" then
                local label = tostring(row[1] or row.label or "")
                local value = row[2]
                if value == nil then value = row.value end
                entries[#entries + 1] = { Label = label, Value = Format.Stringify(value) }
                if align and #label > labelWidth then labelWidth = #label end
            else
                entries[#entries + 1] = { Text = tostring(row) }
            end
        end
    end
    local lines = {}
    if title ~= nil and tostring(title) ~= "" then lines[#lines + 1] = tostring(title) end
    for _, entry in ipairs(entries) do
        if entry.Text ~= nil then
            lines[#lines + 1] = indent .. entry.Text
        else
            local label = entry.Label
            if align and #label < labelWidth then
                label = label .. string.rep(" ", labelWidth - #label)
            end
            local head = indent .. label .. separator
            -- A multi-line value keeps its shape by hanging under its own label.
            local first = true
            for piece in (entry.Value:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"):gmatch("(.-)\n") do
                if first then
                    lines[#lines + 1] = head .. piece
                    first = false
                else
                    lines[#lines + 1] = string.rep(" ", #head) .. piece
                end
            end
            if first then lines[#lines + 1] = head end
        end
    end
    return table.concat(lines, "\n")
end

--------------------------------------------------------
--                   Record rendering                 --
--------------------------------------------------------

--
--- ∑ Everything derived from a record that costs more than a table lookup,
---   computed once and kept on the record itself.
---
---   A console that keeps up depends on this. Rendering a record touches
---   os.date, five gsubs, a table.sort and a handful of concatenations.
---   Doing that per record per frame is O(buffer) work at the frame rate,
---   and with a full ring the window crawls. Once per record the same work
---   is O(arrivals).
---
---   Safe because the only fields written after a record is emitted are
---   Repeats, LastTime, LastMillis, Pinned, Event and Render itself, and none
---   of the four values below is derived from any of them. The repeat badge is
---   built at paint time from Repeats so this cache cannot go stale.
--- @param record table
--- @return table # { Stamp, Fields, Lines, Haystack }
--
function Format.Prepare(record)
    local cache = record.Render
    if cache then return cache end
    local message = record.Message or ""
    local channel = record.Channel or ""
    local fields = Format.Fields(record.Fields)
    cache = {
        Stamp    = Format.Stamp(record),
        Fields   = fields,
        Lines    = Format.Lines(message),
        -- Lowercased here so a search does not lowercase the whole buffer on
        -- every keystroke. Core.Matches is told it may take this as-is.
        Haystack = (message .. " " .. channel .. " " .. fields):lower()
    }
    record.Render = cache
    return cache
end

--
--- ∑ A record's timestamp. This one calls os.date every time. Prefer
---   Format.Prepare(record).Stamp on any path that runs per frame, which
---   reads the stamp already cached on the record.
--- @param record table
--- @param options table|nil # { Millis = true, Date = false }
--- @return string
--
function Format.Stamp(record, options)
    options = options or {}
    local pattern = options.Date and "%Y-%m-%d %H:%M:%S" or "%H:%M:%S"
    local stamp = os.date(pattern, record.Time)
    if options.Millis ~= false then
        stamp = stamp .. string.format(".%03d", record.Millis or 0)
    end
    return stamp
end

--
--- ∑ The four pieces the console draws in its own columns, returned
---   separately rather than joined. The view colours the level tag
---   differently from the message, and measures each column on its own.
---   Neither works on a concatenated line.
--- @param record table
--- @param options table|nil # Passed through to Format.Stamp.
--- @return table # { Stamp, Tag, Channel, Message, Suffix }
--
function Format.Columns(record, options)
    options = options or {}
    local meta = options.Meta or {}
    local suffix = {}
    if (record.Repeats or 1) > 1 then suffix[#suffix + 1] = string.format("x%d", record.Repeats) end
    if record.Dropped then suffix[#suffix + 1] = string.format("+%d dropped", record.Dropped) end
    if record.Forced then suffix[#suffix + 1] = "forced" end
    local cache = Format.Prepare(record)
    local message = record.Message or ""
    if cache.Fields ~= "" then message = message .. "  " .. cache.Fields end
    -- Only a caller that asked for a different stamp shape pays for one.
    local stamp = (options.Date or options.Millis == false)
        and Format.Stamp(record, options) or cache.Stamp
    return {
        Stamp = stamp,
        Tag = meta.Tag or record.Level,
        Channel = record.Channel or "",
        Message = message,
        Suffix = #suffix > 0 and ("[" .. table.concat(suffix, ", ") .. "]") or nil
    }
end

--
--- ∑ One record as one line of text, which is what a file and the clipboard
---   want. Multi-line messages keep their newlines. The caller decides whether
---   to indent the continuations, and Format.Indent does.
--- @param record table
--- @param options table|nil # { Millis, Date, Channel = true, Suppressed = true }
--- @return string
--
function Format.Line(record, options)
    options = options or {}
    local columns = Format.Columns(record, options)
    local parts = { "[" .. columns.Stamp .. "]", "[" .. record.Level .. "]" }
    if options.Channel ~= false and columns.Channel ~= "" then
        parts[#parts + 1] = "[" .. columns.Channel .. "]"
    end
    if options.Suppressed ~= false and record.Suppressed then parts[#parts + 1] = "[hidden]" end
    if columns.Suffix then parts[#parts + 1] = columns.Suffix end
    parts[#parts + 1] = columns.Message
    return table.concat(parts, " ")
end

--
--- ∑ Indents every line after the first, so a block or a traceback stays
---   visibly attached to the record it belongs to.
--- @param text string
--- @param indent string|nil
--- @return string
--
function Format.Indent(text, indent)
    indent = indent or "    "
    local lines, first = {}, true
    for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = first and line or (indent .. line)
        first = false
    end
    -- The trailing empty piece the pattern always produces.
    if lines[#lines] == indent or lines[#lines] == "" then lines[#lines] = nil end
    return table.concat(lines, "\n")
end

--
--- ∑ Splits a message into its physical lines, which is what the canvas view
---   iterates over. Always returns at least one entry, so a blank message
---   still occupies a row.
--- @param text string
--- @return table
--
function Format.Lines(text)
    local out = {}
    for line in (Format.Printable(text) .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = line
    end
    if #out > 1 and out[#out] == "" then out[#out] = nil end
    if #out == 0 then out[1] = "" end
    return out
end

--
--- ∑ Soft-wraps one line to a width, breaking on spaces where it can and
---   mid-token where it must.
---
---   measure covers both the file (width in characters) and the canvas (width
---   in pixels, measured by the device context). It is called on candidate
---   prefixes, so a proportional font wraps correctly rather than by an
---   assumed average character width.
--- @param text string
--- @param width number # In whatever unit measure returns.
--- @param measure function|nil # text -> width. Defaults to #text.
--- @return table # One or more pieces.
--
function Format.Wrap(text, width, measure)
    measure = measure or function(value) return #value end
    if width <= 0 or measure(text) <= width then return { text } end
    local pieces, current = {}, ""
    local function flush()
        if current ~= "" then pieces[#pieces + 1] = current end
        current = ""
    end
    -- Tokens keep their trailing run of spaces, so the break lands after a
    -- word rather than before its separator.
    for token in text:gmatch("%S+%s*") do
        if current == "" then
            current = token
        elseif measure(current .. token) <= width then
            current = current .. token
        else
            flush()
            current = token
        end
        -- A single token longer than the line has to be cut somewhere.
        while measure(current) > width and #current > 1 do
            local cut = #current
            while cut > 1 and measure(current:sub(1, cut)) > width do cut = cut - 1 end
            pieces[#pieces + 1] = current:sub(1, cut)
            current = current:sub(cut + 1)
        end
    end
    flush()
    if #pieces == 0 then pieces[1] = text end
    return pieces
end

--------------------------------------------------------
--                        JSON                        --
--------------------------------------------------------

local JSON_ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"
}

local function jsonString(value)
    return '"' .. tostring(value):gsub('[%z\1-\31\\"]', function(character)
        return JSON_ESCAPES[character] or string.format("\\u%04x", character:byte())
    end) .. '"'
end

--
--- ∑ A minimal JSON encoder, deliberately not a dependency on Manifold.Json.
---
---   That module belongs to the Cheat Table's lifecycle and defines a global
---   class. Loading a second copy from autorun is the collision
---   Manifold.Bootstrap exists to detect. What is needed here is one line of
---   output per record over strings, numbers, booleans and flat tables, which
---   is forty lines instead of a dependency at a possibly different version
---   than the table's.
--- @param value any
--- @param depth number|nil
--- @return string
--
function Format.Json(value, depth)
    depth = depth or 1
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return tostring(value) end
    if kind == "number" then
        -- NaN and the infinities have no JSON spelling. null is the honest one.
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        if value % 1 == 0 and math.abs(value) < 1e15 then return string.format("%d", value) end
        return string.format("%.14g", value)
    end
    if kind ~= "table" then return jsonString(value) end
    if depth > Format.MaxDepth then return jsonString("{...}") end
    if isArray(value) then
        local parts = {}
        for index = 1, math.min(#value, Format.MaxItems) do
            parts[index] = Format.Json(value[index], depth + 1)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for _, key in ipairs(sortedKeys(value)) do
        parts[#parts + 1] = jsonString(key) .. ":" .. Format.Json(value[key], depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

--
--- ∑ One record as one JSON object, the shape R-D in the framework TODO asks
---   for. The fields survive as fields, so a log becomes something a script
---   can answer questions about rather than something to read.
--- @param record table
--- @return string
--
function Format.JsonRecord(record)
    return Format.Json({
        seq = record.Seq,
        time = os.date("!%Y-%m-%dT%H:%M:%S", record.Time) ..
               string.format(".%03dZ", record.Millis or 0),
        level = record.Level,
        channel = record.Channel,
        event = record.Event,
        message = record.Message,
        fields = record.Fields,
        repeats = (record.Repeats or 1) > 1 and record.Repeats or nil,
        forced = record.Forced or nil,
        suppressed = record.Suppressed or nil,
        dropped = record.Dropped,
        source = record.Source,
        trace = record.Trace
    })
end

--------------------------------------------------------
--                       Export                       --
--------------------------------------------------------

local function csvCell(value)
    value = tostring(value or "")
    if value:find('[",\n]') then return '"' .. value:gsub('"', '""') .. '"' end
    return value
end

--
--- ∑ A set of records as one document.
--- @param records table
--- @param mode string|nil # "text" (default), "jsonl", "csv" or "markdown"
--- @param options table|nil # Passed to Format.Line for the text mode.
--- @return string
--
function Format.Export(records, mode, options)
    mode = (mode or "text"):lower()
    local lines = {}
    if mode == "jsonl" then
        for index, record in ipairs(records) do lines[index] = Format.JsonRecord(record) end
    elseif mode == "csv" then
        lines[1] = "seq,time,level,channel,repeats,message,fields"
        for index, record in ipairs(records) do
            lines[index + 1] = table.concat({
                csvCell(record.Seq),
                csvCell(Format.Stamp(record, { Date = true })),
                csvCell(record.Level),
                csvCell(record.Channel),
                csvCell(record.Repeats or 1),
                csvCell(record.Message),
                csvCell(Format.Fields(record.Fields))
            }, ",")
        end
    elseif mode == "markdown" then
        lines[1] = "| Time | Level | Channel | Message |"
        lines[2] = "|---|---|---|---|"
        for index, record in ipairs(records) do
            -- A pipe inside a cell would end the cell. A newline would end the row.
            local message = (record.Message or ""):gsub("|", "\\|"):gsub("\n", "<br>")
            lines[index + 2] = string.format("| %s | %s | %s | %s |",
                Format.Stamp(record), record.Level, record.Channel, message)
        end
    else
        for index, record in ipairs(records) do
            lines[index] = Format.Indent(Format.Line(record, options))
        end
    end
    return table.concat(lines, "\n")
end

--
--- ∑ The extension an export mode should be saved as.
--- @param mode string
--- @return string
--
function Format.ExtensionFor(mode)
    mode = (mode or "text"):lower()
    if mode == "jsonl" then return ".jsonl" end
    if mode == "csv" then return ".csv" end
    if mode == "markdown" then return ".md" end
    return ".log"
end

return Format
