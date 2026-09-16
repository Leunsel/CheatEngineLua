--[[
    Find and replace across the table.

    The two functions that matter are pure. Find returns the spans of a needle
    inside a string and ReplaceText builds the new string out of those spans,
    so neither of them ever looks at Cheat Engine and both can be reasoned
    about on their own. Everything else in this file walks a Records snapshot
    and feeds those two.

    Replacement happens in one pass over the spans that were found BEFORE
    anything changed. A naive loop that searched again after each replacement
    would find the needle inside its own replacement and never stop, which is
    what turns replacing a with aa into a hang.

    Nothing here writes to a record. Plan describes what a replace would do and
    the Window applies it through the commit funnel, so one undo entry covers
    the whole replacement and a record that went away in the meantime is
    reported instead of crashing the run.

    Search never uses a Lua pattern. A description with a percent sign or a
    bracket in it is ordinary text to a person and has to stay ordinary text
    here, so every search is a plain find.

    Cheat Engine facts this file relies on.
      * A record that is not an Auto Assembler script reads no script at all,
        so the script field is only offered where there is one.
      * A drop-down list is a TStringList read through its Text, which puts a
        carriage return and a line feed after every line, the last one
        included. Line numbers count what Cheat Engine hands over.
      * While a drop-down list is linked, the list a person sees belongs to
        another record, so replacing in this record's own text would change
        nothing anybody can see.
      * Setting Active on an Auto Assembler record runs the script. Rewriting
        the text of a running script leaves the process holding code that no
        DISABLE section matches, so an active script is skipped and said so.
]]

local Search = {}
Search.__index = Search

--- The fields a search can cover, in the order hits are reported per record.
Search.Fields = { "Description", "Script", "DropDown" }

--- One results row is one line, so an excerpt is cut to something that fits a
--- strip of that width without wrapping.
local EXCERPT_LIMIT = 120

--- How much of the line before the match an excerpt keeps, so a match deep
--- inside a long script line still arrives with context in front of it.
local EXCERPT_LEAD = 24

--- The Auto Assembler storage type, spelled out so a missing Types module
--- cannot stop a script search.
local VT_AUTOASSEMBLER = 11

--------------------------------------------------------
--                    Pure searching                  --
--------------------------------------------------------

--- True when nothing word like touches the match on either side. A word is the
--- letters, the digits and the underscore, which is what an identifier is made
--- of in a script and in a description alike.
local function standsAlone(text, from, to)
    local before = from > 1 and text:sub(from - 1, from - 1) or ""
    local after = to < #text and text:sub(to + 1, to + 1) or ""
    if before ~= "" and before:match("[%w_]") then return false end
    if after ~= "" and after:match("[%w_]") then return false end
    return true
end

--
--- ∑ Every place the needle sits inside the text.
---
---   Plain text only. Matches never overlap, because the next search starts
---   after the end of the last one, which is what a replacement needs.
--- @param text string # What is searched.
--- @param needle string # What is looked for.
--- @param options table|nil # MatchCase and WholeWord.
--- @return table # A list of spans with Start and Stop, both inclusive.
--
function Search.Find(text, needle, options)
    local spans = {}
    if type(text) ~= "string" or type(needle) ~= "string" then return spans end
    if needle == "" then return spans end
    options = options or {}
    local hay, pin = text, needle
    if not options.MatchCase then hay, pin = text:lower(), needle:lower() end
    local from = 1
    while from <= #hay do
        local start, stop = hay:find(pin, from, true)
        if start == nil then break end
        if not options.WholeWord or standsAlone(hay, start, stop) then
            spans[#spans + 1] = { Start = start, Stop = stop }
            from = stop + 1
        else
            from = start + 1
        end
    end
    return spans
end

--
--- ∑ The text with every match replaced, in one pass.
---
---   The spans are taken first and the result is assembled from them, so a
---   replacement that contains the needle is never searched again.
--- @param text string
--- @param needle string
--- @param replacement string|nil # An empty replacement deletes the needle.
--- @param options table|nil # MatchCase and WholeWord.
--- @return string, number # The new text and how many matches were replaced.
--
function Search.ReplaceText(text, needle, replacement, options)
    if type(text) ~= "string" then return "", 0 end
    local spans = Search.Find(text, needle, options)
    if #spans == 0 then return text, 0 end
    replacement = replacement == nil and "" or tostring(replacement)
    local parts, last = {}, 1
    for _, span in ipairs(spans) do
        parts[#parts + 1] = text:sub(last, span.Start - 1)
        parts[#parts + 1] = replacement
        last = span.Stop + 1
    end
    parts[#parts + 1] = text:sub(last)
    return table.concat(parts), #spans
end

--------------------------------------------------------
--                  Lines and excerpts                --
--------------------------------------------------------

--- Where every line of the text begins, so a position can be turned into a
--- line and a column without walking the whole string again.
local function lineStarts(text)
    local starts, from = { 1 }, 1
    while true do
        local brk = text:find("\n", from, true)
        if brk == nil then break end
        starts[#starts + 1] = brk + 1
        from = brk + 1
    end
    return starts
end

--- The line and the column of one position, both counted from one.
local function placeOf(starts, position)
    local low, high = 1, #starts
    while low < high do
        local mid = (low + high + 1) // 2
        if starts[mid] <= position then low = mid else high = mid - 1 end
    end
    return low, position - starts[low] + 1
end

--- One line of the text, without the line break and without the carriage
--- return a Cheat Engine string list leaves in front of it.
local function lineAt(text, starts, line)
    local from = starts[line]
    local stop = starts[line + 1] and (starts[line + 1] - 2) or #text
    if stop < from then return "" end
    return (text:sub(from, stop):gsub("\r$", ""))
end

--
--- ∑ A one line excerpt that always shows the match.
---
---   A long script line would otherwise scroll the match off the right hand
---   side of the results strip, so the window follows the column and says with
---   three dots where it cut.
--- @param line string
--- @param column number # Where the match starts, counted from one.
--- @return string
--
local function excerptOf(line, column)
    line = line:gsub("\t", " ")
    if #line <= EXCERPT_LIMIT then return line end
    local from = math.max(1, (column or 1) - EXCERPT_LEAD)
    if from + EXCERPT_LIMIT - 1 > #line then
        from = math.max(1, #line - EXCERPT_LIMIT + 1)
    end
    local piece = line:sub(from, from + EXCERPT_LIMIT - 1)
    if from > 1 then piece = "..." .. piece end
    if from + EXCERPT_LIMIT - 1 < #line then piece = piece .. "..." end
    return piece
end

--------------------------------------------------------
--                 Reading the record                 --
--------------------------------------------------------

--- One log line, and nothing at all when no channel was injected.
local function say(self, level, text)
    local log = self.Log
    if type(log) ~= "table" or type(log[level]) ~= "function" then return end
    pcall(log[level], log, text)
end

--- True when the node holds an Auto Assembler script.
local function isScript(self, node)
    local types = self.Types
    if type(types) == "table" and type(types.IsScript) == "function" then
        local ok, value = pcall(types.IsScript, node)
        if ok and value ~= nil then return value == true end
    end
    return node.Type == VT_AUTOASSEMBLER or node.VarType == "vtAutoAssembler"
end

--- The memory record behind one id, or nil when it is gone.
local function recordOf(self, snapshot, id)
    local records = self.Records
    if type(records) ~= "table" or type(records.Resolve) ~= "function" then return nil end
    local ok, mr = pcall(records.Resolve, records, id, snapshot)
    if not ok then return nil end
    return mr
end

--- Loads the detail fields of the nodes a search reads, because a snapshot on
--- its own carries only the shape of the tree.
local function ensureDetail(self, snapshot, ids)
    local records = self.Records
    if type(records) ~= "table" then return end
    if type(records.EnsureDetail) == "function" then
        pcall(records.EnsureDetail, records, snapshot, ids)
        return
    end
    if type(records.Detail) == "function" then
        pcall(records.Detail, records, snapshot, nil, nil)
    end
end

--
--- ∑ The searchable text of one record, per field.
---
---   A field that does not apply is absent rather than empty, so a record
---   without a script never shows up as a script with nothing in it.
--- @param self table
--- @param snapshot table
--- @param node table
--- @param fields table # A set of field names.
--- @return table # Field name to text.
--
local function textsOf(self, snapshot, node, fields)
    local out = {}
    if fields.Description then out.Description = node.Description or "" end
    local wantsScript = fields.Script and isScript(self, node)
    local wantsDrop = fields.DropDown and true or false
    if not wantsScript and not wantsDrop then return out end

    local props = self.Properties
    if type(props) ~= "table" then return out end
    local mr = recordOf(self, snapshot, node.ID)
    if mr == nil then return out end

    if wantsScript and type(props.ReadScript) == "function" then
        local ok, text = pcall(props.ReadScript, props, mr)
        if ok and type(text) == "string" then out.Script = text end
    end
    if wantsDrop and type(props.ReadDropDown) == "function" then
        local ok, dropdown = pcall(props.ReadDropDown, props, mr)
        if ok and type(dropdown) == "table" and type(dropdown.Text) == "string" then
            out.DropDown = dropdown.Text
        end
    end
    return out
end

--- The set of fields a search covers. A caller that names none gets the
--- descriptions, which is the field that costs nothing to read.
local function fieldSet(fields)
    if type(fields) ~= "table" then return { Description = true } end
    local any = false
    for _, name in ipairs(Search.Fields) do
        if fields[name] then any = true end
    end
    if not any then return { Description = true } end
    return fields
end

--- Why this field of this record must not be rewritten, or nil when it may be.
local function refuseReason(field, node)
    if field == "Script" and node.Active then
        return "The script is active. Deactivate it before replacing in it."
    end
    if field == "DropDown" and node.DropDownLinked then
        return "The drop-down list is linked to another record. Replace it there."
    end
    return nil
end

--
--- ∑ Walks the records a search covers and hands each field's text to a visitor.
--- @param self table
--- @param snapshot table
--- @param options table
--- @param visit function # Takes node, field and text.
--- @return number # How many records were read.
--
local function walk(self, snapshot, options, visit)
    if type(snapshot) ~= "table" or type(snapshot.Order) ~= "table" then return 0 end
    local wanted = options.IDs
    local fields = fieldSet(options.Fields)
    local nodes, ids = {}, {}
    for _, node in ipairs(snapshot.Order) do
        if wanted == nil or wanted[node.ID] then
            nodes[#nodes + 1] = node
            ids[#ids + 1] = node.ID
        end
    end
    if #nodes == 0 then return 0 end
    ensureDetail(self, snapshot, wanted and ids or nil)
    for _, node in ipairs(nodes) do
        local texts = textsOf(self, snapshot, node, fields)
        for _, field in ipairs(Search.Fields) do
            if fields[field] and texts[field] ~= nil then
                visit(node, field, texts[field])
            end
        end
    end
    return #nodes
end

--------------------------------------------------------
--                    The instance                    --
--------------------------------------------------------

--
--- ∑ One searcher. Records and Properties are what turn a snapshot into text,
---   and a missing one only costs the fields that need it.
--- @param services table|nil # Records, Properties, Types and Log.
--- @return table
--
function Search:New(services)
    services = services or {}
    return setmetatable({
        Records = services.Records,
        Properties = services.Properties,
        Types = services.Types,
        Log = services.Log,
        LastCount = 0
    }, Search)
end

--
--- ∑ Every match in the table, one entry per match.
---
---   A multi line field reports the line and the column inside that field, so
---   the results strip can say where in a script something sits and the script
---   page can jump there. With a replacement in the options each hit also
---   carries what its line would look like afterwards.
--- @param snapshot table
--- @param options table # Needle, Replacement, Fields, MatchCase, WholeWord, IDs.
--- @return table # The hits.
--
function Search:Hits(snapshot, options)
    local hits = {}
    options = options or {}
    local needle = options.Needle
    if type(needle) ~= "string" or needle == "" then return hits end
    local replacement = options.Replacement

    walk(self, snapshot, options, function(node, field, text)
        local spans = Search.Find(text, needle, options)
        if #spans == 0 then return end
        local starts = lineStarts(text)
        local cache = {}
        for _, span in ipairs(spans) do
            local line, column = placeOf(starts, span.Start)
            local body = cache[line]
            if body == nil then
                body = lineAt(text, starts, line)
                cache[line] = body
            end
            local after = nil
            if replacement ~= nil then
                local replaced = Search.ReplaceText(body, needle, replacement, options)
                after = excerptOf(replaced, column)
            end
            hits[#hits + 1] = {
                ID = node.ID, Field = field, Line = line, Column = column,
                Length = span.Stop - span.Start + 1,
                Excerpt = excerptOf(body, column), After = after
            }
        end
    end)

    self.LastCount = #hits
    say(self, "Info", string.format("Found %d match%s for '%s'.",
        #hits, #hits == 1 and "" or "es", needle))
    return hits
end

--
--- ∑ What a replace all would change, one entry per record and field.
---
---   Nothing is written here. The plan carries the whole old and new text of
---   each field so the Window can commit it as one undoable transaction, and
---   everything that must not be touched comes back in the second list with a
---   sentence saying why.
--- @param snapshot table
--- @param options table # Needle, Replacement, Fields, MatchCase, WholeWord, IDs.
--- @return table, table # The plan and the skipped fields.
--
function Search:Plan(snapshot, options)
    local plan, skipped = {}, {}
    options = options or {}
    local needle = options.Needle
    if type(needle) ~= "string" or needle == "" then return plan, skipped end
    local replacement = options.Replacement == nil and "" or tostring(options.Replacement)

    walk(self, snapshot, options, function(node, field, text)
        local spans = Search.Find(text, needle, options)
        if #spans == 0 then return end
        local reason = refuseReason(field, node)
        if reason then
            skipped[#skipped + 1] = { ID = node.ID, Field = field, Reason = reason }
            return
        end
        local fresh, count = Search.ReplaceText(text, needle, replacement, options)
        if count > 0 and fresh ~= text then
            plan[#plan + 1] = {
                ID = node.ID, Field = field, Old = text, New = fresh, Count = count
            }
        end
    end)

    say(self, "Info", string.format("Planned %d replacement%s, %d skipped.",
        #plan, #plan == 1 and "" or "s", #skipped))
    return plan, skipped
end

return Search
