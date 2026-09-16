--[[
    Writing a selection out of the table.

    Three steps that do not know about each other. Collect turns a Records
    snapshot and a set of ids into plain Lua tables, Build turns those tables
    into text in one of four formats, and Write puts the text on disk. Only the
    first step touches Cheat Engine, so the formats can be tested with tables
    written by hand and the file writer can be tested with a string.

    The encoders are pure and deterministic. The same item list gives the same
    bytes every time, because the JSON object keys are sorted and nothing here
    walks a table in hash order. That is what makes an export diffable, which
    is most of the point of exporting a table into a repository.

    Collect keeps the tree. An item carries its children when the caller asked
    for them, and only the JSON format keeps the nesting. The flat formats walk
    the same tree in pre-order, so a row order is a reading order.

    Cheat Engine facts this file relies on.
      * The offsets of a pointer run the other way round on screen. Offset[0]
        is applied to the base LAST, so the exported chain is reversed into the
        order a person reads it, first dereference first.
      * A record colour is BGR and the default is the system colour
        clWindowText, so a record with no colour of its own exports as nothing
        rather than as black.
      * Reading a value reads the target process, so values are only read when
        the caller asked for them.
      * A record that is not an Auto Assembler script has no script at all.
      * A drop-down list reads back through its Text with a carriage return and
        a line feed after every line, the last one included.

    Nothing here raises. A record that went away between the snapshot and the
    export is left out of the items, and a file that will not open comes back
    as false and a reason.
]]

local Export = {}
Export.__index = Export

--- The formats, keyed by what a file extension resolves to.
Export.Formats = { json = "JSON", csv = "CSV", md = "Markdown", txt = "Text" }

--- The flat formats carry these columns, in this order. A script does not fit
--- a table cell, so it only reaches JSON and the outline.
Export.Columns = {
    { Key = "ID",          Label = "ID" },
    { Key = "Path",        Label = "Path" },
    { Key = "Description", Label = "Description" },
    { Key = "Type",        Label = "Type" },
    { Key = "Address",     Label = "Address" },
    { Key = "Value",       Label = "Value" },
    { Key = "Active",      Label = "Active" },
    { Key = "Hotkeys",     Label = "Hotkeys" }
}

--- What a file name ending resolves to.
local EXTENSIONS = {
    json = "json", csv = "csv", md = "md", markdown = "md", txt = "txt", text = "txt"
}

--- The Auto Assembler storage type, spelled out so a missing Types module
--- cannot stop a script from being exported.
local VT_AUTOASSEMBLER = 11

--- The default record colour is a system colour, not a black. Comparing
--- against a literal black would export every plain record as coloured.
local CL_WINDOWTEXT = 0x80000008

--- A table that nests deeper than this is a cycle, and an encoder that follows
--- one never returns.
local MAX_DEPTH = 32

--- Two spaces per level in the outline, which is what keeps a deep group
--- readable in a plain text editor.
local OUTLINE_INDENT = "  "

--------------------------------------------------------
--                        JSON                        --
--------------------------------------------------------

local JSON_ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"
}

--- A JSON string. Everything below a space becomes an escape, because a raw
--- control character in a script would make the file unreadable.
local function jsonString(text)
    local body = tostring(text):gsub('[%c"\\]', function(char)
        return JSON_ESCAPES[char] or string.format("\\u%04X", char:byte())
    end)
    return '"' .. body .. '"'
end

--- A JSON number. An integer stays an integer, because 17.0 as a record id
--- reads as a mistake.
local function jsonNumber(value)
    if math.type(value) == "integer" then return string.format("%d", value) end
    if value ~= value or value == math.huge or value == -math.huge then return "null" end
    return (string.format("%.14g", value))
end

--- True when the table is a plain list. An empty table counts as one, because
--- every table this module builds that can be empty is a list.
local function isArray(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" then return false end
        count = count + 1
    end
    return count == #value
end

local function encode(value, unit, newline, pad, depth)
    if value == nil then return "null" end
    local kind = type(value)
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then return jsonNumber(value) end
    if kind == "string" then return jsonString(value) end
    if kind ~= "table" then return "null" end
    if depth > MAX_DEPTH then return "null" end

    local inner = pad .. unit
    if isArray(value) then
        if #value == 0 then return "[]" end
        local parts = {}
        for index, item in ipairs(value) do
            parts[index] = inner .. encode(item, unit, newline, inner, depth + 1)
        end
        return "[" .. newline .. table.concat(parts, "," .. newline) .. newline .. pad .. "]"
    end

    local entries = {}
    for key, item in pairs(value) do
        entries[#entries + 1] = { Name = tostring(key), Value = item }
    end
    table.sort(entries, function(a, b) return a.Name < b.Name end)
    local parts = {}
    for index, entry in ipairs(entries) do
        parts[index] = inner .. jsonString(entry.Name) .. (unit == "" and ":" or ": ")
            .. encode(entry.Value, unit, newline, inner, depth + 1)
    end
    return "{" .. newline .. table.concat(parts, "," .. newline) .. newline .. pad .. "}"
end

--
--- ∑ One Lua value as JSON text, with the object keys in sorted order so two
---   exports of the same table are the same bytes.
--- @param value any # Tables, strings, numbers, booleans and nil.
--- @param indent number|string|nil # Spaces per level, or the unit itself. Zero is compact.
--- @return string
--
function Export.Json(value, indent)
    local unit = "  "
    if type(indent) == "number" then unit = string.rep(" ", math.max(0, math.floor(indent))) end
    if type(indent) == "string" then unit = indent end
    return encode(value, unit, unit == "" and "" or "\n", "", 1)
end

--------------------------------------------------------
--                         CSV                        --
--------------------------------------------------------

--- One cell as text. A boolean reads as a word and an integer keeps its shape.
local function cellText(value)
    if value == nil then return "" end
    local kind = type(value)
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        if math.type(value) == "integer" then return string.format("%d", value) end
        return (string.format("%.14g", value))
    end
    return tostring(value)
end

--- RFC 4180 quoting. A quote, a comma, a line break or an edge of whitespace
--- forces quotes, and a quote inside them is doubled.
local function csvField(text)
    if text:find('[",\r\n]') or text:match("^%s") or text:match("%s$") then
        return '"' .. text:gsub('"', '""') .. '"'
    end
    return text
end

--
--- ∑ Rows and columns as RFC 4180 text, with a carriage return and a line feed
---   after every record, the last one included.
--- @param rows table # A list of maps from column key to value.
--- @param columns table # A list of keys, or of tables with Key and Label.
--- @return string
--
function Export.Csv(rows, columns)
    local keys, labels = {}, {}
    for index, column in ipairs(columns or {}) do
        if type(column) == "table" then
            keys[index] = column.Key
            labels[index] = column.Label or column.Key
        else
            keys[index] = column
            labels[index] = column
        end
    end
    if #keys == 0 then return "" end

    local lines = {}
    local head = {}
    for index, label in ipairs(labels) do head[index] = csvField(cellText(label)) end
    lines[1] = table.concat(head, ",")
    for _, row in ipairs(rows or {}) do
        local cells = {}
        for index, key in ipairs(keys) do
            cells[index] = csvField(cellText(row[key]))
        end
        lines[#lines + 1] = table.concat(cells, ",")
    end
    return table.concat(lines, "\r\n") .. "\r\n"
end

--
--- ∑ The format a path asks for, or nil when the ending means nothing here.
--- @param path string
--- @return string|nil
--
function Export.FormatFor(path)
    if type(path) ~= "string" then return nil end
    local ending = path:match("%.([%a%d]+)%s*$")
    if ending == nil then return nil end
    return EXTENSIONS[ending:lower()]
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

--- What a person calls this record's type.
local function typeLabel(self, node)
    if node.IsGroupHeader then return "Group" end
    local types = self.Types
    if type(types) == "table" and type(types.LabelFor) == "function" then
        local ok, label = pcall(types.LabelFor, node)
        if ok and type(label) == "string" and label ~= "" then return label end
    end
    return tostring(node.VarType or node.Type or "")
end

--- The memory record behind one id, or nil when it is gone.
local function recordOf(self, snapshot, id)
    local records = self.Records
    if type(records) ~= "table" or type(records.Resolve) ~= "function" then return nil end
    local ok, mr = pcall(records.Resolve, records, id, snapshot)
    if not ok then return nil end
    return mr
end

--- The Parent greater than Child path of one record, for the reader.
local function pathOf(self, snapshot, id, fallback)
    local records = self.Records
    if type(records) == "table" and type(records.Path) == "function" then
        local ok, text = pcall(records.Path, records, snapshot, id)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    return fallback or ""
end

--- Loads the detail fields of the nodes an export reads.
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

--- The values of the exported records, keyed by id.
local function readValues(self, snapshot, ids)
    local records = self.Records
    if type(records) ~= "table" or type(records.Values) ~= "function" then return {} end
    if #ids == 0 then return {} end
    local ok, map = pcall(records.Values, records, snapshot, ids)
    if not ok or type(map) ~= "table" then return {} end
    return map
end

--- The colour as hash RRGGBB, or nil when the record wears the default.
local function colourOf(self, node)
    local colour = node.Color
    if type(colour) ~= "number" then return nil end
    local default = rawget(_G, "clWindowText")
    if type(default) ~= "number" then default = CL_WINDOWTEXT end
    if colour == default then return nil end
    local props = self.Properties
    if type(props) == "table" and type(props.BgrToHex) == "function" then
        local ok, text = pcall(props.BgrToHex, colour)
        if ok and type(text) == "string" then return text end
    end
    -- Cheat Engine stores a colour the other way round, so the low byte is the
    -- red one and the hex reads back reversed.
    local value = colour & 0xFFFFFF
    return string.format("#%02X%02X%02X", value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF)
end

--- The option flags of a record as a list, in the order Cheat Engine wrote
--- them back.
local function optionList(text)
    local out = {}
    for name in tostring(text or ""):gmatch("[%a%d_]+") do out[#out + 1] = name end
    return out
end

--------------------------------------------------------
--                    Collecting                      --
--------------------------------------------------------

--
--- ∑ One exported record, without its children.
--- @param self table
--- @param snapshot table
--- @param node table
--- @param options table
--- @param values table # Id to value entry.
--- @return table
--
local function itemOf(self, snapshot, node, options, values)
    local item = {
        ID = node.ID,
        ParentID = node.ParentID,
        Path = pathOf(self, snapshot, node.ID, node.Description),
        Description = node.Description or "",
        Type = typeLabel(self, node),
        Group = node.IsGroupHeader == true,
        Address = node.AddressString or "",
        Active = node.Active == true,
        Colour = colourOf(self, node),
        Options = optionList(node.Options)
    }

    local props = self.Properties
    local mr = nil
    local needsRecord = (node.OffsetCount or 0) > 0 or (node.HotkeyCount or 0) > 0
        or node.DropDownLinked or (node.DropDownCount or 0) > 0
        or (options.IncludeScripts and isScript(self, node))
    if needsRecord and type(props) == "table" then
        mr = recordOf(self, snapshot, node.ID)
    end

    if mr ~= nil and (node.OffsetCount or 0) > 0 and type(props.ReadPointer) == "function" then
        local ok, pointer = pcall(props.ReadPointer, props, mr)
        if ok and type(pointer) == "table" then
            item.Address = pointer.Base or item.Address
            local chain = {}
            -- Offset[0] is applied to the base last, so the list is reversed
            -- into the order the path reads.
            local offsets = pointer.Offsets or {}
            for index = #offsets, 1, -1 do chain[#chain + 1] = tostring(offsets[index]) end
            item.Offsets = chain
        end
    end

    if mr ~= nil and (node.HotkeyCount or 0) > 0 and type(props.ReadHotkeys) == "function" then
        local ok, list = pcall(props.ReadHotkeys, props, mr)
        if ok and type(list) == "table" and #list > 0 then
            local hotkeys = {}
            for index, hotkey in ipairs(list) do
                hotkeys[index] = {
                    Keys = hotkey.KeysText or "",
                    Action = hotkey.Action or "",
                    Value = hotkey.Value or "",
                    Description = hotkey.Description or ""
                }
            end
            item.Hotkeys = hotkeys
        end
    end

    if mr ~= nil and type(props.ReadDropDown) == "function"
        and (node.DropDownLinked or (node.DropDownCount or 0) > 0) then
        local ok, dropdown = pcall(props.ReadDropDown, props, mr)
        if ok and type(dropdown) == "table" then
            local text = dropdown.Text or ""
            if text ~= "" or dropdown.Linked then
                item.DropDown = { Text = text }
                if dropdown.Linked then
                    item.DropDown.Linked = dropdown.LinkedMemrec or ""
                end
            end
        end
    end

    if mr ~= nil and options.IncludeScripts and isScript(self, node)
        and type(props.ReadScript) == "function" then
        local ok, text = pcall(props.ReadScript, props, mr)
        if ok and type(text) == "string" and text ~= "" then item.Script = text end
    end

    if options.IncludeValues then
        local entry = values[node.ID]
        if type(entry) == "table" then item.Value = entry.Text or "" end
    end

    return item
end

--- The set of ids to export, out of a list, a set or nothing at all.
local function idSet(snapshot, ids)
    local set = {}
    if ids == nil then
        for _, id in ipairs(snapshot.Roots or {}) do set[id] = true end
        return set
    end
    if type(ids) ~= "table" then return set end
    if #ids > 0 then
        for _, id in ipairs(ids) do set[id] = true end
        return set
    end
    for id, wanted in pairs(ids) do
        if wanted then set[id] = true end
    end
    return set
end

--- True when one of the record's ancestors is in the set, which is how a
--- child of a selected group stops being a top level item.
local function coveredBy(snapshot, set, node)
    local parentId, guard = node.ParentID, 0
    while parentId ~= nil and guard < 256 do
        if set[parentId] then return true end
        local parent = (snapshot.ByID or {})[parentId]
        parentId = parent and parent.ParentID or nil
        guard = guard + 1
    end
    return false
end

--------------------------------------------------------
--                    The instance                    --
--------------------------------------------------------

--
--- ∑ One exporter. Records and Properties read the table, Types names the
---   record types and a missing one only costs the field it would have filled.
--- @param services table|nil # Records, Properties, Types and Log.
--- @return table
--
function Export:New(services)
    services = services or {}
    return setmetatable({
        Records = services.Records,
        Properties = services.Properties,
        Types = services.Types,
        Log = services.Log,
        LastCount = 0
    }, Export)
end

--
--- ∑ Turns a selection into plain tables.
---
---   With IncludeChildren the result is a tree of the selected records whose
---   ancestors are not themselves selected, each carrying its own children.
---   Without it the result is exactly the selected records in pre-order and
---   nothing nests. An empty selection gives an empty list and reads nothing.
--- @param snapshot table
--- @param ids table|nil # A list of ids, a set of ids, or nil for the roots.
--- @param options table|nil # IncludeScripts, IncludeValues and IncludeChildren.
--- @return table # The items.
--
function Export:Collect(snapshot, ids, options)
    local items = {}
    if type(snapshot) ~= "table" or type(snapshot.Order) ~= "table" then return items end
    options = options or {}
    local wanted = idSet(snapshot, ids)

    local tops, emitted = {}, {}
    for _, node in ipairs(snapshot.Order) do
        if wanted[node.ID] then
            if options.IncludeChildren then
                if not coveredBy(snapshot, wanted, node) then tops[#tops + 1] = node end
            else
                tops[#tops + 1] = node
                emitted[#emitted + 1] = node
            end
        end
    end
    if options.IncludeChildren then
        local topSet = {}
        for _, node in ipairs(tops) do topSet[node.ID] = true end
        for _, node in ipairs(snapshot.Order) do
            if topSet[node.ID] or coveredBy(snapshot, topSet, node) then
                emitted[#emitted + 1] = node
            end
        end
    end
    if #emitted == 0 then
        self.LastCount = 0
        return items
    end

    local list = {}
    for _, node in ipairs(emitted) do list[#list + 1] = node.ID end
    ensureDetail(self, snapshot, list)

    local values = {}
    if options.IncludeValues then
        local readable = {}
        for _, node in ipairs(emitted) do
            if not node.IsGroupHeader then readable[#readable + 1] = node.ID end
        end
        values = readValues(self, snapshot, readable)
    end

    local byID = {}
    for _, node in ipairs(emitted) do
        byID[node.ID] = itemOf(self, snapshot, node, options, values)
    end
    if options.IncludeChildren then
        for _, node in ipairs(emitted) do
            local children = {}
            for _, childId in ipairs(node.Children or {}) do
                if byID[childId] then children[#children + 1] = byID[childId] end
            end
            if #children > 0 then byID[node.ID].Children = children end
        end
    end
    for _, node in ipairs(tops) do items[#items + 1] = byID[node.ID] end

    self.LastCount = #emitted
    say(self, "Debug", string.format("Collected %d records for export.", #emitted))
    return items
end

--------------------------------------------------------
--                    The formats                     --
--------------------------------------------------------

--- Every item in reading order, children after their parent.
local function flatten(items, out)
    out = out or {}
    for _, item in ipairs(items or {}) do
        out[#out + 1] = item
        flatten(item.Children, out)
    end
    return out
end

--- The address with its pointer chain, in the order the path reads.
local function addressText(item)
    local text = item.Address or ""
    for _, offset in ipairs(item.Offsets or {}) do
        text = text .. " -> " .. tostring(offset)
    end
    return text
end

--- The key combinations of a record on one line.
local function hotkeyText(item)
    local parts = {}
    for _, hotkey in ipairs(item.Hotkeys or {}) do
        parts[#parts + 1] = hotkey.Keys ~= "" and hotkey.Keys or "(no keys)"
    end
    return table.concat(parts, ", ")
end

--- One item as a row for the flat formats.
local function rowOf(item)
    return {
        ID = item.ID, Path = item.Path, Description = item.Description,
        Type = item.Type, Address = addressText(item), Value = item.Value,
        Active = item.Active, Hotkeys = hotkeyText(item)
    }
end

--- A markdown cell. A pipe would end the cell and a line break would end the
--- row, so both are taken out.
local function mdCell(value)
    local text = cellText(value):gsub("[\r\n]+", " "):gsub("|", "\\|")
    return text
end

local function buildMarkdown(items)
    local lines = {}
    local head, rule = {}, {}
    for index, column in ipairs(Export.Columns) do
        head[index] = mdCell(column.Label)
        rule[index] = "---"
    end
    lines[1] = "| " .. table.concat(head, " | ") .. " |"
    lines[2] = "| " .. table.concat(rule, " | ") .. " |"
    for _, item in ipairs(flatten(items)) do
        local row, cells = rowOf(item), {}
        for index, column in ipairs(Export.Columns) do
            cells[index] = mdCell(row[column.Key])
        end
        lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |"
    end
    return table.concat(lines, "\n") .. "\n"
end

local function outlineOf(items, depth, lines)
    for _, item in ipairs(items or {}) do
        local pad = string.rep(OUTLINE_INDENT, depth)
        local head = pad .. (item.Description ~= "" and item.Description or "(no description)")
        head = head .. " [" .. (item.Type or "") .. "]"
        local address = addressText(item)
        if address ~= "" then head = head .. " " .. address end
        if item.Value ~= nil and item.Value ~= "" then head = head .. " = " .. item.Value end
        if item.Active then head = head .. " (active)" end
        lines[#lines + 1] = head

        local inner = pad .. OUTLINE_INDENT
        if item.Colour then lines[#lines + 1] = inner .. "colour " .. item.Colour end
        if item.Options and #item.Options > 0 then
            lines[#lines + 1] = inner .. "options " .. table.concat(item.Options, ", ")
        end
        for _, hotkey in ipairs(item.Hotkeys or {}) do
            local text = inner .. "hotkey " .. (hotkey.Keys ~= "" and hotkey.Keys or "(no keys)")
            text = text .. " " .. tostring(hotkey.Action or "")
            if hotkey.Value ~= nil and hotkey.Value ~= "" then text = text .. " " .. hotkey.Value end
            if hotkey.Description ~= nil and hotkey.Description ~= "" then
                text = text .. " " .. hotkey.Description
            end
            lines[#lines + 1] = text
        end
        if item.DropDown then
            if item.DropDown.Linked then
                lines[#lines + 1] = inner .. "drop-down linked to " .. item.DropDown.Linked
            end
            for line in tostring(item.DropDown.Text or ""):gmatch("[^\r\n]+") do
                lines[#lines + 1] = inner .. "drop-down " .. line
            end
        end
        if item.Script then
            lines[#lines + 1] = inner .. "script"
            for line in (item.Script .. "\n"):gmatch("(.-)\r?\n") do
                lines[#lines + 1] = inner .. OUTLINE_INDENT .. line
            end
        end
        outlineOf(item.Children, depth + 1, lines)
    end
    return lines
end

--
--- ∑ The items as text in one of the four formats.
---
---   JSON keeps the nesting and everything else walks the same tree in reading
---   order. A format nobody recognises falls back to the outline, because a
---   person who typed an ending we do not know still wants their records.
--- @param items table # What Collect returned.
--- @param format string|nil # json, csv, md or txt.
--- @return string
--
function Export:Build(items, format)
    items = items or {}
    format = Export.Formats[format] and format or "txt"
    if format == "json" then
        return Export.Json(items, 2)
    end
    if format == "csv" then
        local rows = {}
        for index, item in ipairs(flatten(items)) do rows[index] = rowOf(item) end
        return Export.Csv(rows, Export.Columns)
    end
    if format == "md" then
        return buildMarkdown(items)
    end
    local lines = outlineOf(items, 0, {})
    if #lines == 0 then return "" end
    return table.concat(lines, "\n") .. "\n"
end

--
--- ∑ Puts the text on disk and reads the size back, because a write that was
---   never flushed looks exactly like one that worked.
--- @param path string
--- @param text string
--- @return boolean, string|nil
--
function Export:Write(path, text)
    if type(path) ~= "string" or path == "" then
        return false, "There is no file name to write to."
    end
    text = text == nil and "" or tostring(text)
    local handle, openError = io.open(path, "wb")
    if handle == nil then
        return false, "The file could not be opened. " .. tostring(openError)
    end
    local written, writeError = handle:write(text)
    handle:close()
    if not written then
        return false, "The file could not be written. " .. tostring(writeError)
    end
    local check = io.open(path, "rb")
    if check == nil then
        return false, "The file was written but could not be read back."
    end
    local size = check:seek("end")
    check:close()
    if size ~= #text then
        return false, string.format("The file holds %d bytes and the export is %d.", size or -1, #text)
    end
    say(self, "Info", string.format("Exported %d bytes to %s.", #text, path))
    return true
end

return Export
