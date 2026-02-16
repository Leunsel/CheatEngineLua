local NAME = "Manifold.Patcher.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Manifold Framework Patcher"

--[[
    ∂ v1.0.0 (2026-02-16)
        Initial release with core functions.

    ∂ v1.0.1 (2026-02-16)
        Added Dependency Check and Lua Syntax Highlighting.
]]
        
Patcher = {
    Version = VERSION,
    TableHash = "",
    Snapshots = {},
    TableSnapshots = {},
    AppliedPatches = {},
    ShouldCheckForPatches = true,
    SafeMode = true,
    Debug = true,
    StrictTargetResolution = true,
    DefaultScriptReplaceMode = "plain"
}
Patcher.__index = Patcher

function Patcher:New(version)
    local instance = setmetatable({}, self)
    instance.Version = version or VERSION
    instance.TableHash = nil
    instance.Snapshots = {}
    instance.TableSnapshots = {}
    instance.AppliedPatches = {}
    return instance
end
registerLuaFunctionHighlight("New")

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table # {name, version, author, description}
--
function Patcher:GetModuleInfo()
    return {name = NAME, version = self.Version, author = AUTHOR, description = DESCRIPTION}
end
registerLuaFunctionHighlight("GetModuleInfo")

--
--- ∑ Prints module details in a readable formatted block.
--
function Patcher:PrintModuleInfo()
    local info = self:GetModuleInfo()
    if not info then
        logger:Info("[Patcher] Failed to retrieve module info.")
        return
    end
    logger:Info("Module Info : " .. tostring(info.name))
    logger:Info("\tVersion:     " .. tostring(info.version))
    local author = type(info.author) == "table" and table.concat(info.author, ", ") or tostring(info.author)
    local description =
        type(info.description) == "table" and table.concat(info.description, ", ") or tostring(info.description)
    logger:Info("\tAuthor:      " .. author)
    logger:Info("\tDescription: " .. description .. "\n")
end
registerLuaFunctionHighlight("PrintModuleInfo")

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
--- ∑ Ensures all required modules are loaded and ready to use.
---   This function tries to load missing dependencies via CETrequire and initializes them if needed.
--- @return nil
--
function Patcher:CheckDependencies()
    local dependencies = {
        { name = "json", path = "Manifold.Json", init = function() json = JSON:new() end },
        { name = "logger", path = "Manifold.Logger", init = function() logger = Logger:New() end },
        { name = "utils", path = "Manifold.Utils", init = function() utils = Utils:New() end },
    }
    for _, dep in ipairs(dependencies) do
        local depName = dep.name
        if _G[depName] == nil then
            if _G.logger then
                logger:Warning("[Patcher] Missing dependency '" .. depName .. "'. Trying to load it now...")
            end
            local ok, err = pcall(CETrequire, dep.path)
            if ok then
                if _G.logger then
                    logger:Info("[Patcher] Dependency '" .. depName .. "' loaded successfully.")
                end
                if dep.init then
                    dep.init()
                end
            else
                if _G.logger then
                    logger:Error("[Patcher] Could not load '" .. depName .. "'. Reason: " .. tostring(err))
                end
            end
        else
            if _G.logger then
                logger:Debug("[Patcher] Dependency '" .. depName .. "' is already available.")
            end
        end
    end
end

--
--- ∑ Escapes special characters in a string for use in Lua pattern matching.
--- @param s any # The input value to escape, which will be converted to a string.
--- @return string # The escaped string safe for pattern matching.
--
local function escapePattern(s)
    return (tostring(s)):gsub("(%W)", "%%%1")
end

--
--- ∑ Retrieves a memory record by its description, with optional strict matching.
--- @param desc string # The description of the memory record to find.
--- @param strict boolean # If true, requires an exact match of the description; if false, allows partial matches.
--- @return MemoryRecord? # The memory record with the specified description, or nil if not found.
--
local function GetRecordByDescription(desc, strict)
    if not desc then
        return nil
    end
    local rec = AddressList.getMemoryRecordByDescription(desc)
    if not rec then
        return nil
    end
    if strict and rec.Description ~= desc then
        return nil
    end
    return rec
end

--
--- ∑ Retrieves a memory record by its unique ID.
--- @param id number|string # The unique ID of the memory record, or a string that can be converted to a number.
--- @return MemoryRecord? # The memory record with the specified ID, or nil if not found.
--
local function GetRecordByID(id)
    if id == nil then
        return nil
    end
    return AddressList.getMemoryRecordByID(tonumber(id))
end

--
--- ∑ Retrieves a memory record by its zero-based index in the address list.
--- @param index number|string # The zero-based index of the memory record, or a string that can be converted to a number.
--- @return MemoryRecord? # The memory record at the specified index, or nil if the
--
local function GetRecordByIndex(index)
    index = tonumber(index)
    if not index or index < 0 or index >= AddressList.Count then
        return nil
    end
    return AddressList[index]
end

--
--- ∑ Resolves the target memory record for a given patch object using multiple strategies.
--- @param patch table # The patch object containing target resolution information.
--- @return MemoryRecord? # The resolved target memory record, or nil if not found.
--
function Patcher:ResolveTarget(patch)
    if type(patch.Target) == "table" then
        local t = patch.Target
        return GetRecordByIndex(t.Index) or GetRecordByID(t.ID) or
            GetRecordByDescription(t.Description, self.StrictTargetResolution)
    end
    return GetRecordByIndex(patch.Index) or GetRecordByID(patch.IDTarget) or
        GetRecordByDescription(patch.TargetDescription, self.StrictTargetResolution) or
        GetRecordByID(patch.ID)
end

--
--- ∑ Splits a dot-separated path string into its components.
--- @param path string # The dot-separated path (e.g. "Description", "Offset.0", "DropDownList.1").
--- @return table # An array of path components (e.g. {"Description"}, {"Offset", "0"}, {"DropDownList", "1"}).
--
local function splitPath(path)
    local out = {}
    for part in tostring(path):gmatch("[^%.]+") do
        out[#out + 1] = part
    end
    return out
end

--
--- ∑ Retrieves a value from the target object at the specified path.
--- @param obj table|userdata # The target object to query.
--- @param path string # The property path to retrieve (e.g. "Description", "Offset", "DropDownList").
--- @return any # The value at the specified path, or nil if not found.
--
local function getByPath(obj, path)
    local parts = splitPath(path)
    local cur = obj
    for i = 1, #parts do
        if cur == nil then
            return nil
        end
        cur = cur[parts[i]]
    end
    return cur
end

--
--- ∑ Sets a value on the target object at the specified path, creating intermediate tables if necessary.
--- @param obj table|userdata # The target object to modify.
--- @param path string # The property path to set (e.g. "Description", "Offset", "DropDownList").
--- @param value any # The value to set at the specified path.
--- @return boolean, string # True if set successfully, false and error message on failure.
--
local function setByPath(obj, path, value)
    local parts = splitPath(path)
    local cur = obj
    for i = 1, #parts - 1 do
        local k = parts[i]
        if cur[k] == nil then
            return false, ("Intermediate path missing: " .. k)
        end
        cur = cur[k]
    end
    local last = parts[#parts]
    cur[last] = value
    return true
end

--
--- ∑ Converts various input types to a boolean value.
--- @param v any # The input value to convert (boolean, number, string).
--- @return boolean? # The converted boolean value, or nil if conversion fails.
--
local function toBool(v)
    if type(v) == "boolean" then
        return v
    end
    if type(v) == "number" then
        return v ~= 0
    end
    if type(v) == "string" then
        local s = v:lower()
        if s == "true" or s == "1" or s == "yes" or s == "on" then
            return true
        end
        if s == "false" or s == "0" or s == "no" or s == "off" then
            return false
        end
    end
    return nil
end

local VALID_OPTIONS = {
    moHideChildren = true,
    moActivateChildrenAsWell = true,
    moDeactivateChildrenAsWell = true,
    moRecursiveSetValue = true,
    moAllowManualCollapseAndExpand = true,
    moManualExpandCollapse = true,
    moAlwaysHideChildren = true
}

--
--- ∑ Normalizes an options input into a consistent string format.
--- @param v table|string # The input value representing options, either as a table of option names or a comma-separated string.
--- @return string # A normalized string representation of the options (e.g. "[opt1,opt2]").
--
local function normalizeOptions(v)
    -- Accepts: "[a,b]" or "a,b" or {"a","b"}
    local list = {}
    if type(v) == "table" then
        for _, opt in ipairs(v) do
            opt = tostring(opt)
            if VALID_OPTIONS[opt] then
                list[#list + 1] = opt
            end
        end
    else
        local s = tostring(v or "")
        s = s:gsub("^%[", ""):gsub("%]$", "")
        for token in s:gmatch("[^,%s]+") do
            token = tostring(token)
            if VALID_OPTIONS[token] then
                list[#list + 1] = token
            end
        end
    end
    table.sort(list)
    return "[" .. table.concat(list, ",") .. "]"
end

--
--- ∑ Normalizes an offsets input into a consistent table format.
--- @param v table|string # The input value representing offsets, either as a table of numbers or a comma-separated string.
--- @return table? # A normalized table of offsets, or nil if the input is invalid.
--
local function normalizeOffsets(v)
    if type(v) ~= "table" then
        return nil
    end
    local out = {}
    for i = 1, #v do
        out[i] = tonumber(v[i]) or 0
    end
    return out
end

--
--- ∑ Safely executes a function and returns its value, or a fallback if an error occurs.
--- @param fn function # The function to execute safely.
--- @param fallback any # The value to return if the function execution fails.
--- @return any # The result of the function if successful, or the fallback value on error.
--
local function safeGet(fn, fallback)
    local ok, v = pcall(fn)
    if ok then return v end
    return fallback
end

--
--- ∑ Normalizes a dropdown list input into a consistent table format.
--- @param v table|string|userdata # The input value representing the dropdown list.
--- @return table? # A normalized table of dropdown entries, or nil if the input is invalid.
--
local function normalizeDropDownList(v)
    -- accepts: table, string (multiline), StringList
    if v == nil then
        return {}
    end
    if type(v) == "table" then
        local out = {}
        for _, line in ipairs(v) do
            out[#out + 1] = tostring(line)
        end
        return out
    end
    if type(v) == "string" then
        local out = {}
        for line in v:gmatch("[^\r\n]+") do
            out[#out + 1] = line
        end
        return out
    end
    -- CE StringList?
    if type(v) == "userdata" and v.Count and v.Strings then
        local out = {}
        for i = 0, v.Count - 1 do
            out[#out + 1] = tostring(v.Strings[i])
        end
        return out
    end
    return nil
end

--
--- ∑ Reads the dropdown list entries from a memory record and returns them as a table.
--- @param record MemoryRecord # The memory record to read the dropdown list from.
--- @return table # A table containing the dropdown list entries.
--
function Patcher:_ReadDropDownList(record)
    local dd = record.DropDownList
    local c = 0
    if dd and dd.Count then
        c = tonumber(dd.Count) or 0
    else
        c = tonumber(record.DropDownCount) or 0
    end
    local list = {}
    if c > 0 and dd then
        for i = 0, c - 1 do
            local s = safeGet(function()
                return (dd.Strings and dd.Strings[i]) or dd[i]
            end, nil)
            if s ~= nil then list[#list+1] = tostring(s) end
        end
    end
    return list
end
-- registerLuaFunctionHighlight("_ReadDropDownList")

--
--- ∑ Reads the offsets from a memory record and returns them as a table.
--- @param record MemoryRecord # The memory record to read the offsets from.
--- @return table # A table containing the offsets.
--
function Patcher:_ReadOffsets(record)
    local c = tonumber(record.OffsetCount) or 0
    local out = {}
    if c > 0 then
        for i = 0, c - 1 do
            out[#out+1] = tonumber(record.Offset[i]) or 0
        end
    end
    return out
end
-- registerLuaFunctionHighlight("_ReadOffsets")

--
--- ∑ Reads the state of a memory record into a structured table, optionally including script and value.
--- @param record MemoryRecord # The memory record to read the state from.
--- @param include table # A table specifying which optional fields to include (e.g. {Script=true, Value=true}).
--- @return table # A structured table representing the state of the memory record.
--
function Patcher:_ReadRecordState(record, include)
    include = include or {}
    local state = {
        Target = {
            Index = safeGet(function() return record.Index end, nil),
            ID = safeGet(function() return record.ID end, nil),
            Description = safeGet(function() return record.Description end, ""),
        },
        Description = safeGet(function() return record.Description end, ""),
        Address = safeGet(function() return record.Address end, ""),
        Type = safeGet(function() return record.Type end, nil),
        VarType = safeGet(function() return record.VarType end, nil),
        Color = safeGet(function() return record.Color end, nil),
        Active = safeGet(function() return record.Active end, nil),
        ShowAsHex = safeGet(function() return record.ShowAsHex end, nil),
        ShowAsSigned= safeGet(function() return record.ShowAsSigned end, nil),
        AllowIncrease = safeGet(function() return record.AllowIncrease end, nil),
        AllowDecrease = safeGet(function() return record.AllowDecrease end, nil),
        Collapsed = safeGet(function() return record.Collapsed end, nil),
        Async = safeGet(function() return record.Async end, nil),
        DontSave = safeGet(function() return record.DontSave end, nil),
        DropDownLinked = safeGet(function() return record.DropDownLinked end, nil),
        DropDownLinkedMemrec = safeGet(function() return record.DropDownLinkedMemrec end, ""),
        DropDownReadOnly = safeGet(function() return record.DropDownReadOnly end, nil),
        DropDownDescriptionOnly = safeGet(function() return record.DropDownDescriptionOnly end, nil),
        DisplayAsDropDownListItem = safeGet(function() return record.DisplayAsDropDownListItem end, nil),
        Options = safeGet(function() return record.Options end, ""),
        Offset = self:_ReadOffsets(record),
        DropDownList = self:_ReadDropDownList(record),
    }
    if include.Script then
        state.Script = safeGet(function() return record.Script end, nil)
    end
    if include.Value then
        state.Value = safeGet(function() return record.Value end, nil)
    end
    if include.CustomTypeName then
        state.CustomTypeName = safeGet(function() return record.CustomTypeName end, nil)
    end
    return state
end
-- registerLuaFunctionHighlight("_ReadRecordState")

--
--- ∑ Takes a snapshot of the current state of all memory records in the address list, storing it under a given name.
--- @param name string # The name to identify the snapshot.
--- @param opts table # Options for what to include in the snapshot (e.g. {IncludeScript=true, IncludeValue=true}).
--- @return string # The generated hash of the current table state at the time of the snapshot.
--
function Patcher:TakeTableSnapshot(name, opts)
    name = tostring(name or "default")
    opts = opts or {}
    local snap = {
        name = name,
        createdAt = os.time(),
        version = tostring(self.Version or ""),
        requiredHash = self:GenerateTableHash(),
        recordsByID = {},
        recordsByDesc = {},
        records = {},
        include = {
            Script = opts.IncludeScript == true,
            Value  = opts.IncludeValue == true,  -- oft volatil, standardmäßig aus
            CustomTypeName = opts.IncludeCustomTypeName == true,
        }
    }
    for i = 0, AddressList.Count - 1 do
        local rec = AddressList[i]
        local st = self:_ReadRecordState(rec, snap.include)
        snap.records[#snap.records+1] = st
        local id = st.Target.ID
        local desc = st.Target.Description
        if id ~= nil then snap.recordsByID[id] = st end
        if desc and desc ~= "" then snap.recordsByDesc[desc] = st end
    end
    self.TableSnapshots[name] = snap
    if self.Debug then
        logger:InfoF("[Patcher] TableSnapshot '%s' stored (records=%d, hash=%s)", name, #snap.records, tostring(snap.requiredHash))
    end
    return snap.requiredHash
end
registerLuaFunctionHighlight("TakeTableSnapshot")

--
--- ∑ Compares two values for deep equality, handling tables recursively.
--- @param a any # The first value to compare.
--- @param b any # The second value to compare.
--- @return boolean # True if the values are deeply equal, false otherwise.
--
local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return false end
    if #a ~= #b then return false end
    for i=1,#a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

--
--- ∑ Generates a patch object representing the differences between the current state of memory records and a previously taken snapshot.
--- @param name string # The name of the snapshot to compare against.
--- @param meta table # Additional metadata to include in the generated patch (e.g. TargetVersion).
--- @return table, string # The generated patch object, or nil and an error message if the snapshot is not found.
--
function Patcher:GeneratePatchFromSnapshot(name, meta)
    name = tostring(name or "default")
    meta = meta or {}
    local snap = self.TableSnapshots[name]
    if not snap then
        return nil, ("Snapshot not found: " .. name)
    end
    local currentHash = self:GenerateTableHash()
    local patches = {}
    local autoId = 1
    local function nextPatchId()
        local id = string.format("AUTO_%04d", autoId)
        autoId = autoId + 1
        return id
    end
    local fields = {
        "Description","Address","Type","VarType","Color",
        "Active","ShowAsHex","ShowAsSigned","AllowIncrease","AllowDecrease","Collapsed","Async","DontSave",
        "DropDownLinked","DropDownLinkedMemrec","DropDownReadOnly","DropDownDescriptionOnly","DisplayAsDropDownListItem",
        "Options","Offset","DropDownList",
    }
    if snap.include.Script then fields[#fields+1] = "Script" end
    if snap.include.Value then fields[#fields+1] = "Value" end
    if snap.include.CustomTypeName then fields[#fields+1] = "CustomTypeName" end
    for i = 0, AddressList.Count - 1 do
        local rec = AddressList[i]
        local cur = self:_ReadRecordState(rec, snap.include)
        local old = nil
        if cur.Target.ID ~= nil then old = snap.recordsByID[cur.Target.ID] end
        if not old and cur.Target.Description ~= "" then old = snap.recordsByDesc[cur.Target.Description] end
        if old then
            for _, key in ipairs(fields) do
                local a = old[key]
                local b = cur[key]
                local changed = false
                if type(a) == "table" or type(b) == "table" then
                    changed = not deepEqual(a or {}, b or {})
                else
                    changed = (a ~= b)
                end
                if changed then
                    patches[#patches+1] = {
                        ID = nextPatchId(),
                        Target = {
                            Index = cur.Target.Index,
                            ID = cur.Target.ID,
                            Description = cur.Target.Description,
                        },
                        Op = "set",
                        Path = key,
                        Value = (key == "Options") and normalizeOptions(b) or b
                    }
                end
            end
        end
    end
    local out = {
        status = "ok",
        targetVersion = meta.TargetVersion or tostring(self.Version or ""),
        requiredHash  = snap.requiredHash,
        newHash       = currentHash,
        patches       = patches
    }
    return out
end
registerLuaFunctionHighlight("GeneratePatchFromSnapshot")

--
--- ∑ Creates a snapshot of the target record's property before modification for potential rollback.
--- @param target MemoryRecord # The memory record to snapshot.
--- @param path string # The property path to snapshot (e.g. "Description", "Offset", "DropDownList").
--- @return nil # No return value.
--
function Patcher:CreateSnapshot(target, path)
    local id = target.ID
    self.Snapshots[id] = self.Snapshots[id] or {}
    if self.Snapshots[id][path] ~= nil then
        return
    end
    if path == "Offset" then
        local offsets = {}
        for i = 0, target.OffsetCount - 1 do
            offsets[i] = target.Offset[i]
        end
        self.Snapshots[id]["Offset"] = offsets
        self.Snapshots[id]["OffsetCount"] = target.OffsetCount
    elseif path == "DropDownList" then
        local list = {}
        local dd = target.DropDownList
        local c = 0
        if dd and dd.Count then
            c = tonumber(dd.Count) or 0
        elseif target.DropDownCount then
            c = tonumber(target.DropDownCount) or 0
        end
        if c > 0 and dd then
            for i = 0, c - 1 do
                local ok, s = pcall(function() return (dd.Strings and dd.Strings[i]) or dd[i] end)
                if ok and s ~= nil then
                    list[#list + 1] = tostring(s)
                end
            end
        end
        self.Snapshots[id]["DropDownList"] = list
    else
        self.Snapshots[id][path] = getByPath(target, path)
    end
    if self.Debug then
        logger:InfoF("[Patcher] Snapshot: ID=%d Path='%s'", id, tostring(path))
    end
end
registerLuaFunctionHighlight("CreateSnapshot")

--
--- ∑ Clears all stored snapshots and applied patch records.
--- This is typically called after a successful patch application or a rollback.
--
function Patcher:ClearSnapshots()
    self.Snapshots = {}
    self.AppliedPatches = {}
end
registerLuaFunctionHighlight("ClearSnapshots")

--
--- ∑ Reverts all applied patches by restoring properties from snapshots.
--- @return nil # No return value.
--
function Patcher:RevertPatches()
    for id, props in pairs(self.Snapshots) do
        local target = AddressList.getMemoryRecordByID(id)
        if target then
            for path, val in pairs(props) do
                if path == "Offset" then
                    target.OffsetCount = props["OffsetCount"] or 0
                    for i, v in pairs(val) do
                        target.Offset[i] = v
                    end
                elseif path == "DropDownList" then
                    target.DropDownList.clear()
                    for _, entry in pairs(val) do
                        target.DropDownList.add(entry)
                    end
                elseif path ~= "OffsetCount" then
                    pcall( function() setByPath(target, path, val) end)
                end
            end
        end
    end
    self:ClearSnapshots()
    logger:Info("[Patcher] Rollback completed.")
end
registerLuaFunctionHighlight("RevertPatches")

--
--- ∑ Patches the script of a memory record based on the provided value, which can be a string or a replace operation.
--- @param target MemoryRecord # The memory record whose script is to be patched.
--- @param value string|table # The new script string or a table specifying replace parameters.
--- @return boolean, string # True if patched successfully, false and error message on failure.
--
function Patcher:PatchScript(target, value)
    if not target or type(target.Script) ~= "string" then
        return false, "Target has no script"
    end
    self:CreateSnapshot(target, "Script")
    if type(value) == "string" then
        target.Script = value
        return true
    end
    -- Segment replace
    if type(value) == "table" and value.replace and value.with then
        local mode = value.mode or self.DefaultScriptReplaceMode -- "plain" | "pattern"
        local original = target.Script
        local search = tostring(value.replace)
        if mode ~= "pattern" then
            search = escapePattern(search) -- plain
        end
        local n = tonumber(value.count) or 1 -- 1 = first occurrence
        if value.all == true then
            n = nil
        end
        local replaced, count = original:gsub(search, tostring(value.with), n)
        if count == 0 then
            return false, ("String not found in script: " .. tostring(value.replace))
        end
        target.Script = replaced
        return true
    end
    return false, "Invalid script patch payload"
end
registerLuaFunctionHighlight("PatchScript")

local SCHEMA = {
    -- string
    Description = {kind = "string", path = "Description"},
    Address = {kind = "string", path = "Address"},
    Value = {kind = "string", path = "Value"},
    CustomTypeName = {kind = "string", path = "CustomTypeName"},
    DropDownLinkedMemrec = {kind = "string", path = "DropDownLinkedMemrec"},
    -- number
    Type = {kind = "number", path = "Type"},
    VarType = {kind = "string", path = "VarType"},
    Color = {kind = "number", path = "Color"},
    -- bool
    Active = {kind = "bool", path = "Active"},
    ShowAsHex = {kind = "bool", path = "ShowAsHex"},
    ShowAsSigned = {kind = "bool", path = "ShowAsSigned"},
    AllowIncrease = {kind = "bool", path = "AllowIncrease"},
    AllowDecrease = {kind = "bool", path = "AllowDecrease"},
    Collapsed = {kind = "bool", path = "Collapsed"},
    Async = {kind = "bool", path = "Async"},
    DontSave = {kind = "bool", path = "DontSave"},
    -- ...
    DropDownLinked = {kind = "bool", path = "DropDownLinked"},
    DropDownReadOnly = {kind = "bool", path = "DropDownReadOnly"},
    DropDownDescriptionOnly = {kind = "bool", path = "DropDownDescriptionOnly"},
    DisplayAsDropDownListItem = {kind = "bool", path = "DisplayAsDropDownListItem"},
    -- special
    Options = {kind = "options", path = "Options"},
    Offset = {kind = "offsets", path = "Offset"},
    DropDownList = {kind = "dropdown", path = "DropDownList"},
    Script = {kind = "script", path = "Script"}
    -- String.Size / String.Unicode / String.Codepage
    -- Binary.Startbit / Binary.Size
    -- Aob.Size
}

--
--- ∑ Coerces a value to the appropriate type based on the kind and sets it on the target record.
--- @param target MemoryRecord # The target memory record to modify.
--- @param path string # The property path to set (e.g. "Description", "Offset", "DropDownList").
--- @param kind string # The kind of the property (e.g. "string", "number", "bool", "options", "offsets", "dropdown", "script").
--- @param value any # The value to coerce and set.
--- @return boolean, string # True if set successfully, false and error message on failure.
--
function Patcher:CoerceAndSet(target, path, kind, value)
    self:CreateSnapshot(target, path)
    if kind == "string" then
        return setByPath(target, path, tostring(value))
    elseif kind == "number" then
        local n = tonumber(value)
        if n == nil then
            return false, "Expected number"
        end
        return setByPath(target, path, n)
    elseif kind == "bool" then
        local b = toBool(value)
        if b == nil then
            return false, "Expected boolean"
        end
        return setByPath(target, path, b)
    elseif kind == "options" then
        return setByPath(target, path, normalizeOptions(value))
    elseif kind == "offsets" then
        local offsets = normalizeOffsets(value)
        if not offsets then
            return false, "Expected offsets table"
        end
        target.OffsetCount = #offsets
        for i = 0, #offsets - 1 do
            target.Offset[i] = offsets[i + 1]
        end
        return true
    elseif kind == "dropdown" then
        local list = normalizeDropDownList(value)
        if not list then
            return false, "Expected dropdown list (table/string/StringList)"
        end
        target.DropDownList.clear()
        for _, entry in ipairs(list) do
            target.DropDownList.add(entry)
        end
        return true
    elseif kind == "script" then
        local ok, err = self:PatchScript(target, value)
        if not ok then
            return false, err
        end
        return true
    end
    return false, ("Unknown kind: " .. tostring(kind))
end
registerLuaFunctionHighlight("CoerceAndSet")

--
--- ∑ Normalizes a patch object to ensure it has the required structure and defaults.
--- @param patch table # The patch object to normalize.
--- @return table? # The normalized patch object, or nil if invalid.
--
function Patcher:NormalizePatch(patch)
    if type(patch) ~= "table" then
        return nil
    end
    if patch.Path ~= nil then
        patch.Op = patch.Op or "set"
        return patch
    end
    return patch
end
registerLuaFunctionHighlight("NormalizePatch")

--
--- ∑ Applies a single patch to the target memory record.
--- @param patch table # The patch object containing target resolution and property changes.
--- @return boolean, string # True if applied successfully, false and error message on failure.
--
function Patcher:ApplyPatch(patch)
    patch = self:NormalizePatch(patch)
    if not patch or type(patch) ~= "table" then
        return false, "Invalid patch object"
    end
    local target = self:ResolveTarget(patch)
    if not target then
        return false, ("Target not found for patch " .. tostring(patch.ID))
    end
    local op = patch.Op or "set"
    if op ~= "set" then
        return false, ("Unsupported op: " .. tostring(op))
    end
    local path = tostring(patch.Path or "")
    if path == "" then
        return false, "Missing Path"
    end
    local spec = SCHEMA[path]
    local kind = spec and spec.kind or "any"
    local realPath = spec and spec.path or path
    if kind == "any" then
        self:CreateSnapshot(target, realPath)
        local ok, err = setByPath(target, realPath, patch.Value)
        if not ok then
            return false, err
        end
        return true
    end
    local ok, err = self:CoerceAndSet(target, realPath, kind, patch.Value)
    if not ok then
        return false, err
    end
    return true
end
registerLuaFunctionHighlight("ApplyPatch")

--
--- ∑ Serializes a memory record into a string representation for hashing.
--- @param record MemoryRecord # The memory record to serialize.
--- @return string # The serialized string representation of the record.
--
function Patcher:SerializeRecord(record)
    local data = {}
    data[#data + 1] = tostring(record.ID or "")
    data[#data + 1] = tostring(record.Description or "")
    data[#data + 1] = tostring(record.Address or "")
    data[#data + 1] = tostring(record.Type or "")
    data[#data + 1] = tostring(record.Options or "")
    if record.Script then
        data[#data + 1] = record.Script
    end
    if record.OffsetCount and record.OffsetCount > 0 then
        data[#data + 1] = tostring(record.OffsetCount)
        for i = 0, record.OffsetCount - 1 do
            data[#data + 1] = tostring(record.Offset[i])
        end
    end
    if record.DropDownCount and record.DropDownCount > 0 then
        local dd = record.DropDownList
        local c = (dd and dd.Count and tonumber(dd.Count)) or tonumber(record.DropDownCount) or 0
        if c > 0 and dd then
        data[#data+1] = tostring(c)
        for i=0,c-1 do
            local ok, s = pcall(function() return (dd.Strings and dd.Strings[i]) or dd[i] end)
            if ok and s ~= nil then
                data[#data+1] = tostring(s)
            end
        end
        end
    end
    return table.concat(data, "|")
end
registerLuaFunctionHighlight("SerializeRecord")

--
--- ∑ Builds a fingerprint string representing the current state of the address list for patch validation.
--- @return string # The fingerprint string representing the current table state.
--
function Patcher:BuildTableFingerprint()
    local records = {}
    for i = 0, AddressList.Count - 1 do
        records[#records + 1] = self:SerializeRecord(AddressList[i])
    end
    table.sort(records)
    return table.concat(records, "\n")
end
registerLuaFunctionHighlight("BuildTableFingerprint")

--
--- ∑ Generates an MD5 hash of the current table state for patch validation.
--- @return string # The MD5 hash representing the current table state.
--
function Patcher:GenerateTableHash()
    return stringToMD5String(self:BuildTableFingerprint())
end
registerLuaFunctionHighlight("GenerateTableHash")

--
--- ∑ Requests patches from the server based on current version and table hash.
--- @param url string # The URL to request patches from.
--- @return table? # The decoded response from the server, or nil on failure.
--
function Patcher:RequestPatches(url)
    local internet = getInternet()
    if not internet then
        logger:Warning("[Patcher] Internet unavailable. Cannot check for patches.")
        return nil
    end
    local payload = {
        version = self.Version,
        fingerprint = self:GenerateTableHash()
    }
    local response = internet.postURL(url, json:encode(payload))
    if not response or response == "" then
        return nil
    end
    local ok, decoded = pcall(function() return json:decode(response)end)
    if not ok then
        return nil
    end
    return decoded
end
registerLuaFunctionHighlight("RequestPatches")

--
--- ∑ Main function to check for and apply patches from the server.
--- @param url string # The URL to request patches from.
--- @return boolean # True if patches were applied successfully, false otherwise.
--
function Patcher:CheckAndApply(url)
    if not self.ShouldCheckForPatches then
        logger:Info("[Patcher] Patch check disabled. Skipping...")
        return false
    end
    logger:Info("[Patcher] Checking for patches at: " .. tostring(url))
    local data = self:RequestPatches(url)
    if not data then
        logger:Warning("[Patcher] No response or invalid response.")
        return false
    end
    local status = data.status
    local patches = data.patches
    local expectedNewHash = data.newHash
    if not status and type(data) == "table" then
        status = (patches and "ok") or nil
    end
    if status == "up-to-date" then
        logger:Info("[Patcher] Up to date.")
        return false
    end
    if status == "hash-mismatch" then
        logger:Warning("[Patcher] Hash mismatch (Unauthentic Cheat Table).")
        return false
    end
    if status ~= "ok" then
        logger:Warning("[Patcher] Unexpected server status: " .. tostring(status))
        return false
    end
    if type(patches) ~= "table" or #patches == 0 then
        logger:Warning("[Patcher] No valid patches.")
        return false
    end
    local msg = string.format("There are %d Patch(es) available for your version of the Cheat Table. Do you want to apply them?", #patches)
    if not utils:ShowConfirmation(msg) then
        logger:Info("[Patcher] User declined patch application.")
        return false
    end
    self:ClearSnapshots()
    logger:Info("[Patcher] Applying " .. #patches .. " patch(es)...")
    for _, patch in ipairs(patches) do
        local ok, err =
            pcall(
            function()
                local aok, aerr = self:ApplyPatch(patch)
                if not aok then
                    error(aerr)
                end
            end
        )
        if not ok then
            logger:Warning("[Patcher] Patch failed: " .. tostring(patch.ID) .. " | " .. tostring(err))
            if self.SafeMode then
                logger:Info("[Patcher] SafeMode: reverting...")
                self:RevertPatches()
            end
            return false
        else
            self.AppliedPatches[#self.AppliedPatches + 1] = patch.ID or "?"
            if self.Debug then
                logger:Info("[Patcher] Applied: " .. tostring(patch.ID))
            end
        end
    end
    if expectedNewHash then
        local newHash = self:GenerateTableHash()
        if newHash ~= expectedNewHash then
            logger:Warning("[Patcher] Post-patch hash mismatch. Expected=" .. tostring(expectedNewHash) .. " Got=" .. tostring(newHash))
            if self.SafeMode then
                logger:Info("[Patcher] SafeMode: reverting due to hash mismatch...")
                self:RevertPatches()
                return false
            end
        else
            logger:Info("[Patcher] Post-patch hash verified: " .. tostring(newHash))
        end
    end
    logger:Info("[Patcher] All patches applied successfully.")
    return true
end
registerLuaFunctionHighlight("CheckAndApply")

--
--- ∑ Entry point to start the patching process by checking for patches and applying them if available.
--- @param url string # The URL to request patches from.
--- @return boolean # True if patches were applied successfully, false otherwise.
--
function Patcher:Start(url)
    self.TableHash = self:GenerateTableHash()
    return self:CheckAndApply(url)
end
registerLuaFunctionHighlight("Start")

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Patcher