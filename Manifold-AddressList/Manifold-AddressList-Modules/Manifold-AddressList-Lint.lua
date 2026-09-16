--[[
    The table checker.

    One pass over a Records snapshot that reports what is wrong with a Cheat
    Table. It owns no window and keeps no state worth having. Run hands back a
    list of problems and a small statistics table, and everything that draws
    them lives somewhere else.

    Two of the checks cost real time, so both are opt in through the options.
    Reading a value touches the target process and can stall on a paged out
    address. Assembling a script runs Cheat Engine's Auto Assembler over it,
    which means every custom command handler a table registered gets executed
    while we are only asking a question. Neither runs unless the caller asked.

    The whole table is read even when the caller limits the check to a few
    records, because a duplicate description and a dead drop-down link are
    facts about the table and not about one record. Problems come back only for
    the records the caller asked about.

    Cheat Engine facts this file relies on.
      * IsReadable is stale until the value was read once, because Cheat Engine
        sets it inside its own value getter. So the unreadable check reads the
        value through Records and never trusts the flag.
      * A record that is not an Auto Assembler script reads no script at all,
        so the script checks resolve the record first and ask Properties.
      * LastAAExecutionFailedReason is usually the literal word Unknown, which
        says nothing, so the message drops it when that is all there is.
      * A drop-down link names the DESCRIPTION of the source record, not its
        id, which is why renaming a record breaks the link in silence. Any
        record can be the source, a group header included, because a header
        can carry a list although its own Value reads empty.
      * Changing a hotkey's keys does not re-register it, so two records really
        can hold one combination and only one of them will ever fire.
      * autoAssembleCheck runs the table's own Auto Assembler command handlers.
        That is the whole reason the assemble check is off by default.

    Nothing here raises. A missing service, a record that went away between the
    snapshot and the check, and a binding that refuses to answer all end as a
    quietly skipped check.
]]

local Lint = {}
Lint.__index = Lint

--- The Auto Assembler storage type. Written out so a Types module that was not
--- injected cannot stop the script checks from running.
local VT_AUTOASSEMBLER = 11

--- Error first, then warning, then info. The results strip and the tree edge
--- both want the worst severity of a record, so the order has to be total.
local SEVERITY_RANK = { error = 1, warning = 2, info = 3 }

--- A reason out of Cheat Engine can be a whole assembler dump, and a results
--- row is one line, so a long one gets cut.
local REASON_LIMIT = 200

--- What Cheat Engine writes when it has nothing to say about a failure.
local UNKNOWN_REASON = "Unknown"

--- Every check, in the order the documentation and the About block list them.
--- Code is what a problem carries and Title is the one line a reader gets.
Lint.Checks = {
    { Code = "EMPTY_SCRIPT",          Severity = "error",   Title = "An Auto Assembler record has no script" },
    { Code = "MISSING_ENABLE",        Severity = "error",   Title = "A script has no ENABLE section" },
    { Code = "MISSING_DISABLE",       Severity = "error",   Title = "A script has no DISABLE section" },
    { Code = "LAST_RUN_FAILED",       Severity = "error",   Title = "The last run of a script failed" },
    { Code = "DEAD_DROPDOWN_LINK",    Severity = "error",   Title = "A drop-down list is linked to a record that is not there" },
    { Code = "ASSEMBLE_FAILED",       Severity = "error",   Title = "A script does not assemble" },
    { Code = "DUPLICATE_DESCRIPTION", Severity = "warning", Title = "Two or more records share a description" },
    { Code = "HOTKEY_CONFLICT",       Severity = "warning", Title = "One key combination is on two hotkeys" },
    { Code = "UNREADABLE",            Severity = "warning", Title = "A value cannot be read" },
    { Code = "EMPTY_DESCRIPTION",     Severity = "info",    Title = "A record has no description" },
    { Code = "ACTIVE_UNDER_INACTIVE", Severity = "info",    Title = "An active record sits under an inactive group that hides it" }
}

--------------------------------------------------------
--                    Small helpers                   --
--------------------------------------------------------

--- os.clock in seconds, and zero when the host took even that away.
local function clock()
    local ok, value = pcall(os.clock)
    if ok and type(value) == "number" then return value end
    return 0
end

--- A short one line form of whatever a binding handed back.
local function shorten(text, limit)
    text = tostring(text or ""):gsub("[\r\n]+", " "):gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if #text > limit then return text:sub(1, limit - 3) .. "..." end
    return text
end

--- The flag names out of an option set string, as a set.
local function optionSet(text)
    local set = {}
    for name in tostring(text or ""):gmatch("[%a%d_]+") do set[name] = true end
    return set
end

--
--- ∑ Drops the parts of a script the section check must not see.
---
---   A brace block is a comment in the Auto Assembler and it nests, so the
---   balanced match does the work. A double slash runs to the end of its line.
---   What is left is lowered once, because both section names are looked for
---   as plain text.
--- @param text string
--- @return string
--
local function searchable(text)
    local out = tostring(text or ""):gsub("%b{}", " ")
    out = out:gsub("//[^\n]*", " ")
    return out:lower()
end

--- The line number Cheat Engine named in an error, when it named one.
local function lineIn(message)
    local line = tostring(message or ""):lower():match("line%s*(%d+)")
    return line and tonumber(line) or nil
end

--
--- ∑ The sorted virtual key list as one comparable string, which is the whole
---   identity of a key combination. Which key was pressed first changes
---   nothing about what fires.
--- @param keys table|nil # Virtual key codes.
--- @return string|nil
--
local function comboKey(keys)
    local copy = {}
    for _, key in ipairs(keys or {}) do
        local number = tonumber(key)
        if number and number ~= 0 then copy[#copy + 1] = number end
    end
    if #copy == 0 then return nil end
    table.sort(copy)
    for index, number in ipairs(copy) do copy[index] = tostring(number) end
    return table.concat(copy, "+")
end

--- One log line, and nothing at all when no channel was injected.
local function say(self, level, text)
    local log = self.Log
    if type(log) ~= "table" or type(log[level]) ~= "function" then return end
    pcall(log[level], log, text)
end

--------------------------------------------------------
--                 Reading the record                 --
--------------------------------------------------------

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

--- The script text of one node, or nil when nothing could read it.
local function scriptOf(self, snapshot, node)
    local props = self.Properties
    if type(props) ~= "table" or type(props.ReadScript) ~= "function" then return nil end
    local mr = recordOf(self, snapshot, node.ID)
    if mr == nil then return nil end
    local ok, text = pcall(props.ReadScript, props, mr)
    if not ok then return nil end
    return text
end

--- The hotkeys of one node, as Properties reports them.
local function hotkeysOf(self, snapshot, node)
    if (node.HotkeyCount or 0) <= 0 then return nil end
    local props = self.Properties
    if type(props) ~= "table" or type(props.ReadHotkeys) ~= "function" then return nil end
    local mr = recordOf(self, snapshot, node.ID)
    if mr == nil then return nil end
    local ok, list = pcall(props.ReadHotkeys, props, mr)
    if not ok or type(list) ~= "table" then return nil end
    return list
end

--
--- ∑ Makes sure every node carries its detail fields before a check reads
---   them. A snapshot is cheap because it reads two members per record, so
---   everything else arrives here.
--- @param self table
--- @param snapshot table
--- @return number # How many nodes were filled in.
--
local function ensureDetail(self, snapshot)
    local records = self.Records
    if type(records) ~= "table" then return 0 end
    if type(records.EnsureDetail) == "function" then
        local ok, count = pcall(records.EnsureDetail, records, snapshot, nil)
        if ok then return tonumber(count) or 0 end
        return 0
    end
    if type(records.Detail) == "function" then
        local ok, count = pcall(records.Detail, records, snapshot, nil, nil)
        if ok then return tonumber(count) or 0 end
    end
    return 0
end

--- The values of the records a value check covers, keyed by id.
local function readValues(self, snapshot, nodes)
    local records = self.Records
    if type(records) ~= "table" or type(records.Values) ~= "function" then return {} end
    local ids = {}
    for _, node in ipairs(nodes) do ids[#ids + 1] = node.ID end
    if #ids == 0 then return {} end
    local ok, map = pcall(records.Values, records, snapshot, ids)
    if not ok or type(map) ~= "table" then return {} end
    return map
end

--------------------------------------------------------
--                   Table wide facts                 --
--------------------------------------------------------

--- Every description in the table and how often it is used. The duplicate
--- check and the link check both read it, and both mean the whole table.
local function describeAll(snapshot)
    local counts = {}
    for _, node in ipairs(snapshot.Order or {}) do
        local description = node.Description
        if type(description) == "string" and description ~= "" then
            counts[description] = (counts[description] or 0) + 1
        end
    end
    return counts
end

--
--- ∑ Every key combination in the table and the records that hold it. A
---   conflict is a fact about two records, so it can only be found by looking
---   at all of them. The hotkeys of each record come back too, because reading
---   them a second time would mean resolving every record again.
--- @param self table
--- @param snapshot table
--- @return table, table # Combination key to a bucket, and id to hotkey list.
--
local function collectHotkeys(self, snapshot)
    local byCombo, byRecord = {}, {}
    for _, node in ipairs(snapshot.Order or {}) do
        local list = hotkeysOf(self, snapshot, node)
        if list then byRecord[node.ID] = list end
        for _, hotkey in ipairs(list or {}) do
            local key = comboKey(hotkey.Keys)
            if key then
                local bucket = byCombo[key]
                if bucket == nil then
                    bucket = { Text = hotkey.KeysText, Entries = {} }
                    byCombo[key] = bucket
                end
                if bucket.Text == nil or bucket.Text == "" then bucket.Text = hotkey.KeysText end
                bucket.Entries[#bucket.Entries + 1] = { ID = node.ID }
            end
        end
    end
    return byCombo, byRecord
end

--
--- ∑ Runs Cheat Engine's own check over both sections of one script.
---
---   This is the only place in the segment that executes anything a table
---   brought with it, because an Auto Assembler check runs the custom command
---   handlers the table registered. It is opt in for that reason alone.
--- @param self table
--- @param node table
--- @param script string
--- @param report function # Takes node, code, severity, message, field, line.
--- @return nil
--
local function assembleScript(self, node, script, report)
    local ce = self.CE
    if type(ce) ~= "table" or type(ce.AssembleCheck) ~= "function" then return end
    local sections = { { true, "[ENABLE]" }, { false, "[DISABLE]" } }
    for _, section in ipairs(sections) do
        local ran, ok, err = pcall(ce.AssembleCheck, ce, script, section[1])
        if ran and ok == false then
            local reason = shorten(err, REASON_LIMIT)
            local message = string.format("The %s section does not assemble.", section[2])
            if reason ~= "" then message = message .. " " .. reason end
            report(node, "ASSEMBLE_FAILED", "error", message, "Script", lineIn(reason))
        end
    end
end

--------------------------------------------------------
--                    The instance                    --
--------------------------------------------------------

--
--- ∑ One checker. Every service is optional and a missing one costs only the
---   checks that need it.
--- @param services table|nil # CE, Records, Properties, Types and Log.
--- @return table
--
function Lint:New(services)
    services = services or {}
    return setmetatable({
        CE = services.CE,
        Records = services.Records,
        Properties = services.Properties,
        Types = services.Types,
        Log = services.Log,
        LastStats = nil
    }, Lint)
end

--
--- ∑ Checks one table and reports what a person would want to fix.
---
---   The two expensive checks stay off unless the options turn them on. An id
---   set narrows what is reported without narrowing what is read, so a shared
---   description is still found when only one of the two records is in the set.
--- @param snapshot table # A Records snapshot.
--- @param options table|nil # ReadValues, Assemble and IDs.
--- @return table, table # The problems and the statistics.
--
function Lint:Run(snapshot, options)
    local started = clock()
    local problems, place = {}, {}
    local stats = { Checked = 0, Errors = 0, Warnings = 0, Infos = 0, Took = 0 }
    if type(snapshot) ~= "table" or type(snapshot.Order) ~= "table" then
        return problems, stats
    end
    options = options or {}

    local function report(node, code, severity, message, field, line)
        local problem = {
            ID = node.ID, Severity = severity, Code = code,
            Message = message, Field = field, Line = line
        }
        problems[#problems + 1] = problem
        place[problem] = { Index = node.Index or 0, Seq = #problems }
    end

    ensureDetail(self, snapshot)

    local wanted = options.IDs
    local checked = {}
    for _, node in ipairs(snapshot.Order) do
        if wanted == nil or wanted[node.ID] then checked[#checked + 1] = node end
    end
    stats.Checked = #checked

    local counts = describeAll(snapshot)
    local combos, hotkeysByID = collectHotkeys(self, snapshot)

    -- The records a value read would cover. Collected first, so one call into
    -- Records serves the whole run.
    local wantValues = {}
    if options.ReadValues then
        for _, node in ipairs(checked) do
            if not node.IsGroupHeader and not isScript(self, node) then
                wantValues[#wantValues + 1] = node
            end
        end
    end
    local values = options.ReadValues and readValues(self, snapshot, wantValues) or {}

    for _, node in ipairs(checked) do
        local description = node.Description or ""

        if description == "" then
            report(node, "EMPTY_DESCRIPTION", "info",
                "The record has no description.", "Description")
        elseif (counts[description] or 0) > 1 then
            report(node, "DUPLICATE_DESCRIPTION", "warning", string.format(
                "The description '%s' is on %d records, and a link or a lookup finds only one of them.",
                description, counts[description]), "Description")
        end

        if isScript(self, node) then
            local text = scriptOf(self, snapshot, node)
            local body = type(text) == "string" and text or ""
            if body:gsub("%s+", "") == "" then
                report(node, "EMPTY_SCRIPT", "error",
                    "The Auto Assembler record has no script.", "Script")
            else
                local hay = searchable(body)
                local hasEnable = hay:find("[enable]", 1, true) ~= nil
                local hasDisable = hay:find("[disable]", 1, true) ~= nil
                -- A script with neither section is something else entirely, a
                -- one shot the author runs by hand, so only a half written
                -- pair is reported.
                if hasEnable and not hasDisable then
                    report(node, "MISSING_DISABLE", "error",
                        "The script has no [DISABLE] section, so activating it cannot be undone.", "Script")
                elseif hasDisable and not hasEnable then
                    report(node, "MISSING_ENABLE", "error",
                        "The script has no [ENABLE] section, so activating it does nothing.", "Script")
                end
                if options.Assemble then assembleScript(self, node, body, report) end
            end
            if node.LastFailed then
                local reason = shorten(node.LastFailedReason, REASON_LIMIT)
                local message = "The last run of the script failed."
                if reason ~= "" and reason ~= UNKNOWN_REASON then
                    message = message .. " " .. reason
                end
                report(node, "LAST_RUN_FAILED", "error", message, "Script", lineIn(reason))
            end
        end

        if node.DropDownLinked then
            -- Every description in the table counts as a target, a group
            -- header's as much as a value's.
            local target = node.DropDownLinkedMemrec or ""
            if target == "" or counts[target] == nil then
                report(node, "DEAD_DROPDOWN_LINK", "error", string.format(
                    "The drop-down list is linked to '%s', and no record has that description.",
                    target), "DropDownLinkedMemrec")
            end
        end

        local seen = {}
        for _, hotkey in ipairs(hotkeysByID[node.ID] or {}) do
            local key = comboKey(hotkey.Keys)
            local bucket = key and combos[key] or nil
            if bucket and #bucket.Entries > 1 and not seen[key] then
                seen[key] = true
                local mine, others = 0, 0
                for _, entry in ipairs(bucket.Entries) do
                    if entry.ID == node.ID then mine = mine + 1 else others = others + 1 end
                end
                local combo = bucket.Text
                if combo == nil or combo == "" then combo = key end
                local message
                if others > 0 then
                    message = string.format(
                        "The key combination %s is on %d other record%s, and only one of them will fire.",
                        combo, others, others == 1 and "" or "s")
                else
                    message = string.format(
                        "The key combination %s is on this record %d times.", combo, mine)
                end
                report(node, "HOTKEY_CONFLICT", "warning", message, "HotkeyCount")
            end
        end

        if options.ReadValues then
            local entry = values[node.ID]
            if type(entry) == "table" and (entry.Readable == false or entry.Text == "??") then
                local where = node.AddressString or ""
                local message = "The value could not be read."
                if where ~= "" then
                    message = string.format("The value at %s could not be read.", where)
                end
                report(node, "UNREADABLE", "warning", message, "Value")
            end
        end

        if node.Active and node.ParentID ~= nil then
            local parent = (snapshot.ByID or {})[node.ParentID]
            if parent and parent.IsGroupHeader and not parent.Active then
                local flags = optionSet(parent.Options)
                if flags.moHideChildren or flags.moAlwaysHideChildren then
                    report(node, "ACTIVE_UNDER_INACTIVE", "info", string.format(
                        "The record is active under '%s', which is inactive and hides its children.",
                        parent.Description or ""), "Active")
                end
            end
        end
    end

    table.sort(problems, function(a, b)
        local left, right = place[a], place[b]
        if left.Index ~= right.Index then return left.Index < right.Index end
        local rankA = SEVERITY_RANK[a.Severity] or 9
        local rankB = SEVERITY_RANK[b.Severity] or 9
        if rankA ~= rankB then return rankA < rankB end
        return left.Seq < right.Seq
    end)

    for _, problem in ipairs(problems) do
        if problem.Severity == "error" then stats.Errors = stats.Errors + 1
        elseif problem.Severity == "warning" then stats.Warnings = stats.Warnings + 1
        else stats.Infos = stats.Infos + 1 end
    end
    stats.Took = math.floor((clock() - started) * 1000 + 0.5)
    self.LastStats = stats

    say(self, "Info", string.format(
        "Checked %d records, %d errors, %d warnings, %d notes in %d ms.",
        stats.Checked, stats.Errors, stats.Warnings, stats.Infos, stats.Took))
    return problems, stats
end

--
--- ∑ The worst severity per record, which is what the tree edge and the status
---   line want.
--- @param problems table # What Run returned.
--- @return table # A map of id to severity name.
--
function Lint.ByID(problems)
    local worst = {}
    for _, problem in ipairs(problems or {}) do
        local rank = SEVERITY_RANK[problem.Severity] or 9
        local held = worst[problem.ID]
        if held == nil or rank < (SEVERITY_RANK[held] or 9) then
            worst[problem.ID] = problem.Severity
        end
    end
    return worst
end

return Lint
