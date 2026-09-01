local NAME = "Manifold.Teleporter.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.4.1"
local DESCRIPTION = "Manifold Framework Teleporter"

--[[
    ∂ v1.4.1 (2026-09-01)
        The window builder lost a third of its lines without
        losing a control. Panel properties moved into the option
        tables Manifold.Forms already accepts, the menus and the
        toolbar are built from specs, every field row is built
        the same way, and EnsureUiState no longer declares ninety
        fields by assigning nil to them, which built nothing.
        One tail for add, update, rename, duplicate and delete.

    ∂ v1.4.0 (2026-09-01)
        A position is no longer three components by definition.
        Transform.Offsets decides how many there are and Axes
        names them, so a 2D game needs two offsets and nothing
        else. Saves carry one key per axis, so existing 3D files
        are unchanged. ValidateConfiguration reports a symbol
        whose offsets disagree with the Transform.
]]--

Teleporter = {
    --- Names for the components of a position, in memory order.
    --- How MANY there are is not decided here. Transform.Offsets decides that,
    --- because that is the one place the memory layout is already written down.
    --- Axes only supplies the letters, which reach the save file as keys and
    --- the editor as field captions. A 2D game therefore needs two offsets and
    --- nothing else:
    ---     teleporter.Transform.Offsets = { 0x30, 0x34 }
    --- and gets X and Y. A top-down game that thinks in X and Z says so:
    ---     teleporter.Axes = { "X", "Z" }
    --- Extra names are ignored, missing ones fall back to X, Y, Z, W.
    Axes = { "X", "Y", "Z" },

    Transform = {
        Symbol    = "TransformPtr",
        Offsets   = { 0x30, 0x34, 0x38 },
        ValueType = vtSingle
    },

    Waypoint = {
        Symbol    = "WaypointPtr",
        Offsets   = { 0x00, 0x04, 0x08 },
        ValueType = vtSingle
    },

    Additional = {
        Symbol    = nil,
        Offsets   = { 0x00, 0x04, 0x08 },
        ValueType = vtSingle
    },

    Symbols = {
        Saved  = "SavedPositionFlt",
        Backup = "BackupPositionFlt"
    },

    Settings = {
        ValueType = vtSingle,
        PauseWhileTeleporting = true,
        --- Per-step logging during a jump. OFF by default, same reasoning as
        --- Memory.LogSuccessfulOperations: one teleport walked through pause,
        --- three address resolutions, three writes and a resume, and every one
        --- of those lines is a file write because the log writes the file
        --- before it applies the level filter. Turn it on to trace a jump.
        LogVerbose = false,
        --- Y Coordinate Adjustment Settings ---
        AdjustYCoordinate = true,
        YCoordinateIndex = 1,
        AdjustmentAmount = 10.000
    },

    Saves = {},

    SaveFileName = "Teleporter.%s.Saves.txt",
    SaveMemoryRecordName = "[— Teleporter : Saves —] ()->"
}
Teleporter.__index = Teleporter


local MODULE_PREFIX = "[Teleporter]"

--
--- ∑ Manifold.Bootstrap handshake. Uses the framework core when the cheat
---   table has loaded it, and degrades to an inert stub when it has not, so
---   this module stays loadable on its own. Identical in every module - this
---   is the one duplication the design costs, and it is irreducible: something
---   has to reach the loader before the loader exists.
--
local BOOTSTRAP = rawget(_G, "ManifoldBootstrap") or {
    Declare = function(spec) return spec end,
    Resolve = function() return true end,
    Ready   = function(_, instance) return instance end,
    Once    = function(_, fn) if type(fn) == "function" then pcall(fn) end return true end,
}

--
--- ∑ This module's identity and its dependency contract, in one place.
---     required = true -> New() refuses rather than pretending to be ready
---     runtime  = true -> documented only; never loaded here, never ordered on
--
local MODULE = BOOTSTRAP.Declare({
    class = "Teleporter", global = "teleporter",
    name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION,
    prefix = MODULE_PREFIX,
    deps = {
        { "logger", required = true },
        { "forms", required = true },
        { "memory" },
        { "customIO" },
        { "ui", runtime = true },
    },
})

local function _VersionAtLeast(current, required)
    local currentParts = {}
    local requiredParts = {}
    for part in tostring(current or ""):gmatch("%d+") do
        currentParts[#currentParts + 1] = tonumber(part) or 0
    end
    for part in tostring(required or ""):gmatch("%d+") do
        requiredParts[#requiredParts + 1] = tonumber(part) or 0
    end
    local count = math.max(#currentParts, #requiredParts)
    for index = 1, count do
        local currentPart = currentParts[index] or 0
        local requiredPart = requiredParts[index] or 0
        if currentPart > requiredPart then return true end
        if currentPart < requiredPart then return false end
    end
    return true
end

function Teleporter:New(config)
    local instance = setmetatable({}, self)
    self:CheckDependencies()
    instance.Name = NAME or "Unnamed Module"
    local rejected = {}
    for key, value in pairs(config or {}) do
        if self[key] ~= nil then
            instance[key] = value
        else
            rejected[#rejected + 1] = { tostring(key), type(value) }
        end
    end
    if #rejected > 0 then
        logger:WarningBlock(MODULE_PREFIX .. " Ignored " .. #rejected .. " unknown config properties", rejected)
    end
    return BOOTSTRAP.Ready(MODULE, instance)
end
registerLuaFunctionHighlight('New')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table # {name, version, author, description}
--
function Teleporter:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Prints module details in a readable formatted block.
--
function Teleporter:PrintModuleInfo()
    local info = self:GetModuleInfo()
    local author = type(info.author) == "table" and table.concat(info.author, ", ") or tostring(info.author)
    logger:InfoBlock("Module Info : " .. tostring(info.name), {
        { "Version",     info.version },
        { "Author",      author },
        { "Description", info.description },
    }, { indent = "\t" })
end
registerLuaFunctionHighlight('PrintModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
--- ∑ ...
--
--- ∑ The single dependency lookup, shared by every Manifold module.
---   The name is kept so external callers and the docs keep working, and so a
---   module can still be checked without being constructed.
---   Behaviour is refuse-and-report: Bootstrap.Resolve never loads anything.
---   A missing `required` dependency raises out of New() with one legible
---   message instead of this module pretending to be ready.
--- @return boolean, table # resolved, list of missing dependency names
--
function Teleporter:CheckDependencies()
    return BOOTSTRAP.Resolve(MODULE)
end
registerLuaFunctionHighlight('CheckDependencies')

local readFunctions = {
    [vtByte] = readByte, [vtWord] = readSmallInteger, [vtDword] = readInteger,
    [vtQword] = readQword, [vtSingle] = readFloat, [vtDouble] = readDouble
}
local writeFunctions = {
    [vtByte] = writeByte, [vtWord] = writeSmallInteger, [vtDword] = writeInteger,
    [vtQword] = writeQword, [vtSingle] = writeFloat, [vtDouble] = writeDouble
}
local valueTypeMap = { [0]="Byte", [1]="Word", [2]="Dword", [3]="Qword", [4]="Single", [5]="Double" }
local typeSizeMap = { [vtByte]=1, [vtWord]=2, [vtDword]=4, [vtQword]=8, [vtSingle]=4, [vtDouble]=8 }
local DEFAULT_CATEGORY = "Default"
local CATEGORY_PATH_SEPARATOR = " / "
local TREE_BRANCH = "├─ "
local TREE_LAST   = "└─ "
local TREE_TRUNK  = "│  "
local TREE_BLANK  = "   "
local DESCRIPTION_INDENT = "   "
local DEFAULT_DESCRIPTION_WIDTH = 92

local function trimString(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

--
--- ∑ Character count of a string, so padding stays aligned when names carry
---   multi-byte characters such as the em dash left over from legacy save names.
--
local function displayWidth(value)
    local text = tostring(value or "")
    local ok, count = pcall(function() return utf8.len(text) end)
    return (ok and count) or #text
end

--
--- ∑ Wraps text to a column width while keeping the breaks the author typed.
---   Blank lines survive as paragraph separators; a word longer than the width
---   gets its own line rather than being cut.
--- @param text string # Raw text.
--- @param width number # Maximum characters per line.
--- @return table # Wrapped lines.
--
local function wrapText(text, width)
    local lines = {}
    local normalized = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    for paragraph in (normalized .. "\n"):gmatch("(.-)\n") do
        if paragraph:match("^%s*$") then
            if #lines > 0 then
                lines[#lines + 1] = ""
            end
        else
            local current = ""
            for word in paragraph:gmatch("%S+") do
                if current == "" then
                    current = word
                elseif displayWidth(current) + 1 + displayWidth(word) <= width then
                    current = current .. " " .. word
                else
                    lines[#lines + 1] = current
                    current = word
                end
            end
            if current ~= "" then
                lines[#lines + 1] = current
            end
        end
    end
    while #lines > 0 and lines[#lines] == "" do
        lines[#lines] = nil
    end
    return lines
end

--
--- ∑ "1 save" / "3 saves", so summary lines read like prose.
--
local function pluralize(count, singular, plural)
    return string.format("%d %s", count, count == 1 and singular or plural)
end

local function sortCaseInsensitive(values)
    table.sort(values, function(a, b)
        return tostring(a):lower() < tostring(b):lower()
    end)
    return values
end

local function sortedKeys(source)
    local keys = {}
    for key in pairs(source or {}) do
        keys[#keys + 1] = key
    end
    return sortCaseInsensitive(keys)
end

local function newCategoryNode()
    return { Categories = {}, Saves = {} }
end

--- Fallback names, used for any component Axes does not name.
local DEFAULT_AXIS_NAMES = { "X", "Y", "Z", "W" }

--
--- ∑ How many components a position has, taken from Transform.Offsets.
---   That table already had to be written for the game, so making it the
---   authority means a 2D table configures one thing instead of two.
--- @return number # 3 unless the Transform says otherwise.
--
function Teleporter:AxisCount()
    local offsets = self.Transform and self.Transform.Offsets
    local count = type(offsets) == "table" and #offsets or 0
    if count > 0 then
        return count
    end
    -- No Transform yet. Fall back to however many names are configured, so
    -- the module still answers sensibly before it has been set up.
    return math.max(1, #(self.Axes or DEFAULT_AXIS_NAMES))
end
registerLuaFunctionHighlight('AxisCount')

--
--- ∑ The axis names for this table, in memory order.
---   Cached, because the save tree asks for them once per rendered row. The
---   cache is keyed on what it was built from, so changing either the offsets
---   or the names is picked up without anyone having to say so.
--- @return table # Array of names, one per component.
--
function Teleporter:GetAxes()
    local count = self:AxisCount()
    local configured = self.Axes
    local cache = self._AxisCache
    if cache and cache.Count == count and cache.Source == configured
       and cache.SourceCount == (configured and #configured or 0) then
        return cache.Names
    end
    local names, taken = {}, {}
    for index = 1, count do
        local name = configured and configured[index] or DEFAULT_AXIS_NAMES[index]
        name = trimString(name)
        -- Two components sharing a name would collapse into one save key, so a
        -- duplicate or a blank gets a positional name instead of being trusted.
        if name == "" or taken[name] then
            name = DEFAULT_AXIS_NAMES[index] or ("A" .. index)
            if taken[name] then
                name = "A" .. index
            end
        end
        taken[name] = true
        names[index] = name
    end
    self._AxisCache = {
        Names = names, Count = count, Source = configured,
        SourceCount = configured and #configured or 0,
    }
    return names
end
registerLuaFunctionHighlight('GetAxes')

--
--- ∑ Drops the cached axis names. Only needed when Axes is edited in place
---   rather than replaced, which GetAxes cannot notice on its own.
--
function Teleporter:RefreshAxes()
    self._AxisCache = nil
end
registerLuaFunctionHighlight('RefreshAxes')

--
--- ∑ Checks that every configured symbol has one offset per axis.
---   The Transform sets the count, so this finds the case where a table was
---   shortened to two components but the Waypoint still lists three. That
---   mismatch only shows up when somebody presses the waypoint button, which
---   is a long way from where the mistake was made.
---   A symbol with no name is skipped. That is how a table says it does not
---   use that feature.
--- @param quiet boolean|nil # Skip the log entry and just return the answer.
--- @return boolean, table # Whether it is consistent, and the rows explaining it.
--
function Teleporter:ValidateConfiguration(quiet)
    local axes = self:GetAxes()
    local expected = #axes
    local rows = { { "Axes", expected .. " (" .. table.concat(axes, ", ") .. ")" } }
    local problems = 0
    for _, name in ipairs({ "Transform", "Waypoint", "Additional" }) do
        local block = self[name]
        -- trimString turns a missing symbol into "", which is the same answer
        -- as a blank one and the same decision: skip it.
        local symbol = block and trimString(block.Symbol) or ""
        if symbol ~= "" then
            local offsets = type(block.Offsets) == "table" and #block.Offsets or 0
            if offsets ~= expected then
                problems = problems + 1
                rows[#rows + 1] = { name, offsets .. " offsets for '" .. symbol ..
                                          "', expected " .. expected }
            end
        end
    end
    if not quiet then
        if problems > 0 then
            logger:WarningBlock(MODULE_PREFIX .. " Offsets do not match the axis count", rows)
        else
            logger:DebugBlock(MODULE_PREFIX .. " Configuration is consistent", rows)
        end
    end
    return problems == 0, rows
end
registerLuaFunctionHighlight('ValidateConfiguration')

--
--- ∑ Reads a position out of a save entry.
---   A save stores one key per axis, so a 2D save is { X = .., Y = .. } and
---   nothing has to know about a third component that was never there.
--- @param save table|nil # A save entry.
--- @return table|nil # The position, or nil when an axis is missing.
--
function Teleporter:SaveToPosition(save)
    if type(save) ~= "table" then
        return nil
    end
    local position = {}
    for index, axis in ipairs(self:GetAxes()) do
        local value = tonumber(save[axis])
        if value == nil then
            return nil
        end
        position[index] = value
    end
    return position
end
registerLuaFunctionHighlight('SaveToPosition')

--
--- ∑ Writes a position into a save entry, one key per axis.
---   Axis names this table no longer uses are removed rather than left behind,
---   so a file that was written while the table was configured differently
---   does not keep a stale coordinate nobody updates.
--- @param save table # The save entry to write into.
--- @param position table # The position to store.
--- @return table # The same save entry.
--
function Teleporter:PositionToSave(save, position)
    local axes = self:GetAxes()
    local inUse = {}
    for index, axis in ipairs(axes) do
        save[axis] = position[index]
        inUse[axis] = true
    end
    for _, name in ipairs(DEFAULT_AXIS_NAMES) do
        if not inUse[name] then
            save[name] = nil
        end
    end
    return save
end
registerLuaFunctionHighlight('PositionToSave')

--
--- ∑ Calculates the offsets for a position symbol from the configured ValueType.
---   One offset per axis, so the Saved and Backup symbols follow the Transform
---   without being configured separately.
--- @returns table # For example { 0, 4, 8 } for three vtSingle components.
--
function Teleporter:CalculateSymbolOffsets()
    local size = typeSizeMap[self.Settings.ValueType] or 0
    local offsets = {}
    for index = 0, self:AxisCount() - 1 do
        offsets[#offsets + 1] = index * size
    end
    return offsets
end

--
--- ∑ Pauses the game if the setting is enabled during teleportation.
--
function Teleporter:PauseGame()
    if not self.Settings.PauseWhileTeleporting then
        return
    end
    pause()
end

--
--- ∑ Unpauses the game if it was paused during teleportation.
--
function Teleporter:ResumeGame()
    if not self.Settings.PauseWhileTeleporting then
        return
    end
    unpause()
end

--
--- ∑ Resolves a memory address using a teleporter function.
--- @param addressStr string # The address expression to resolve.
--- @param isPointer boolean # Whether the address should be resolved as a pointer.
--- @return integer|nil # The resolved address or nil on failure.
--
function Teleporter:ResolveAddress(addressStr, isPointer)
    if type(addressStr) ~= "string" or addressStr == "" then
        logger:Error(MODULE_PREFIX .. " Invalid address string provided for resolution.")
        return nil
    end
    local resolvedAddress = memory:SafeGetAddress(isPointer and ("[" .. addressStr .. "]+0") or addressStr)
    if not resolvedAddress then
        logger:ForceWarningF(MODULE_PREFIX .. " Failed to resolve address '%s' (Pointer: %s)", addressStr, tostring(isPointer))
        return nil
    end
    if self.Settings.LogVerbose then
        logger:DebugF(MODULE_PREFIX .. " Resolved address '%s' (Pointer: %s) -> 0x%X", addressStr, tostring(isPointer), resolvedAddress)
    end
    return resolvedAddress
end

--
--- ∑ ...
--
function Teleporter:SetValueType(valueType)
    local typeName = valueTypeMap[valueType] or "Unknown"
    if readFunctions[valueType] and writeFunctions[valueType] then
        self.Settings.ValueType = valueType
        logger:InfoF(MODULE_PREFIX .. " Value type set to %s (ID: %d).", typeName, valueType)
    else
        -- The rejection and what would have been accepted, together. Split
        -- over two lines the reader had to scroll to find the answer.
        logger:ErrorBlock(MODULE_PREFIX .. " Invalid value type", {
            { "Requested", typeName .. " (ID: " .. tostring(valueType) .. ")" },
            { "Available", table.concat(valueTypeMap, ", ") },
        })
    end
end
registerLuaFunctionHighlight('SetValueType')

--
--- ∑ Reads a position from memory based on a symbol and offsets.
--- @param symbol string # The base address or symbol to resolve.
--- @param offsets table # A table of integer offsets to apply.
--- @param isPointerRead boolean # Whether the address is a pointer.
--- @return table|nil # A table containing the position values or nil on failure.
--
function Teleporter:ReadPositionFromMemory(symbol, offsets, isPointerRead, valueType)
    if type(symbol) ~= "string" or symbol == "" then
        logger:Error(MODULE_PREFIX .. " Invalid symbol for position read.")
        return nil
    end
    if type(offsets) ~= "table" or #offsets == 0 then
        logger:Error(MODULE_PREFIX .. " Invalid or empty offsets for position read.")
        return nil
    end
    -- ResolveAddress reports an unresolvable symbol itself, in the same
    -- words. Repeating it here wrote the same line twice per failure.
    local baseAddress = self:ResolveAddress(symbol, isPointerRead)
    if not baseAddress then
        return nil
    end
    local readFunc = readFunctions[valueType]
    if not readFunc then
        logger:Error(string.format(MODULE_PREFIX .. " Unsupported value type '%s'", tostring(valueType)))
        return nil
    end
    local position = {}
    for i, offset in ipairs(offsets) do
        position[i] = readFunc(baseAddress + offset)
        -- Early-Out if "any" read fails...
        if not position[i] then
            return nil
        end
    end
    if self.Settings.LogVerbose then
        logger:DebugF(MODULE_PREFIX .. " Read position from '0x%08X' -> %s", baseAddress, self:FormatPosition(position))
    end
    return position
end
registerLuaFunctionHighlight('ReadPositionFromMemory')

--
--- ∑ Writes a position to memory based on a symbol and offsets.
--- @param symbol string # The base address or symbol to resolve.
--- @param offsets table # A table of integer offsets to apply.
--- @param position table # A table of values to write.
--- @param isPointerWrite boolean # Whether the address is a pointer.
--- @return boolean # Returns true if successful, false otherwise.
--
function Teleporter:WritePositionToMemory(symbol, offsets, position, isPointerWrite, valueType)
    if type(symbol) ~= "string" or symbol == "" then
        logger:Error(MODULE_PREFIX .. " Invalid symbol for position write.")
        return false
    end
    if type(offsets) ~= "table" or #offsets == 0 then
        logger:Error(MODULE_PREFIX .. " Invalid or empty offsets for position write.")
        return false
    end
    if type(position) ~= "table" or #position ~= #offsets then
        logger:Error(MODULE_PREFIX .. " Mismatched offsets and position values.")
        return false
    end
    -- See ReadPositionFromMemory. ResolveAddress owns this message.
    local baseAddress = self:ResolveAddress(symbol, isPointerWrite)
    if not baseAddress then
        return false
    end
    local writeFunc = writeFunctions[valueType]
    if not writeFunc then
        logger:ErrorF(MODULE_PREFIX .. " Unsupported value type '%s'", tostring(valueType))
        return false
    end
    for i, offset in ipairs(offsets) do
        if not writeFunc(baseAddress + offset, position[i]) then
            logger:Error(string.format(MODULE_PREFIX .. " Failed to write value at offset '0x%08X'", offset))
            return false
        end
    end
    if self.Settings.LogVerbose then
        logger:DebugF(MODULE_PREFIX .. " Wrote position to '0x%08X' -> %s", baseAddress, self:FormatPosition(position))
    end
    return true
end
registerLuaFunctionHighlight('WritePositionToMemory')

--
--- ∑ Reads the current position from memory.
--- @returns # the current coordinates as a table (x, y, z).
--
function Teleporter:GetCurrentPosition()
    return self:ReadPositionFromMemory(self.Transform.Symbol, self.Transform.Offsets, true, self.Transform.ValueType)
end
registerLuaFunctionHighlight('GetCurrentPosition')

--
--- ∑ Reads the current saved position from memory.
--- @returns # the current saved coordinates as a table (x, y, z).
--
function Teleporter:GetSavedPosition()
    return self:ReadPositionFromMemory(self.Symbols.Saved, self:CalculateSymbolOffsets(), false, self.Settings.ValueType)
end
registerLuaFunctionHighlight('GetSavedPosition')

--
--- ∑ Reads the current backup position from memory.
--- @returns # the current backup coordinates as a table (x, y, z).
--
function Teleporter:GetBackupPosition()
    return self:ReadPositionFromMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), false, self.Settings.ValueType)
end
registerLuaFunctionHighlight('GetBackupPosition')

--
--- ∑ Formats a position as one readable value, however many components it has.
---   Formats what it is given rather than what the configuration expects, so a
---   position read through a symbol whose offsets disagree with the Transform
---   still shows its real contents instead of the word unknown.
--- @param position table|nil # A position of any length.
--- @return string
--
function Teleporter:FormatPosition(position)
    if type(position) ~= "table" or #position == 0 then
        return "unknown"
    end
    local parts = {}
    for index = 1, #position do
        parts[index] = string.format("%.3f", tonumber(position[index]) or 0)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end
registerLuaFunctionHighlight('FormatPosition')

--
--- ∑ The straight line distance between two positions.
--- @param oldPosition table # {x, y, z}
--- @param newPosition table # {x, y, z}
--- @return number|nil
--
function Teleporter:GetDistance(oldPosition, newPosition)
    if type(oldPosition) ~= "table" or type(newPosition) ~= "table" then
        return nil
    end
    -- Summed over however many components the shorter of the two has, so a
    -- 2D table measures in the plane and a 3D one in space, with no branch.
    local components = math.min(#oldPosition, #newPosition)
    if components == 0 then
        return nil
    end
    local total = 0
    for index = 1, components do
        local delta = (tonumber(newPosition[index]) or 0) - (tonumber(oldPosition[index]) or 0)
        total = total + delta * delta
    end
    return math.sqrt(total)
end
registerLuaFunctionHighlight('GetDistance')

--
--- ∑ Logs the distance traveled when teleporting.
--- @deprecated Kept for callers outside this module. A jump is reported by
---   _ReportJump now, which puts the distance in the same entry as the
---   destination instead of on a line of its own.
--- @param oldPosition # The previous position {x, y, z}.
--- @param newPosition # The new position {x, y, z}.
--
function Teleporter:LogDistanceTraveled(oldPosition, newPosition)
    local distance = self:GetDistance(oldPosition, newPosition)
    if not distance then
        logger:Warning(MODULE_PREFIX .. " Cannot log distance traveled, a position is missing.")
        return
    end
    logger:InfoF(MODULE_PREFIX .. " Distance traveled: %.3f Units", distance)
end

--
--- ∑ Reports one completed jump as a single entry.
---   Every teleport used to write three to four separate lines, plus the
---   per-step lines underneath it, so a jump cost around a dozen file writes
---   and read as a paragraph. One block, one write, one place to look.
--- @param what string # What kind of jump this was.
--- @param fromPosition table|nil # Where the jump started.
--- @param toPosition table # Where it ended.
--- @param backupStored boolean|nil # Whether the previous position was kept.
--
function Teleporter:_ReportJump(what, fromPosition, toPosition, backupStored)
    local distance = self:GetDistance(fromPosition, toPosition)
    logger:InfoBlock(MODULE_PREFIX .. " " .. what, {
        { "From",     self:FormatPosition(fromPosition) },
        { "To",       self:FormatPosition(toPosition) },
        distance and { "Distance", string.format("%.3f Units", distance) } or false,
        { "Backup",   backupStored and "stored" or "not stored" },
    })
end

--
--- ∑ Saves the current position to memory for later retrieval.
--- @returns # true if the position was successfully saved, false otherwise.
--
function Teleporter:SaveCurrentPosition()
    local currentPosition = self:GetCurrentPosition()
    if not currentPosition then
        logger:Error(MODULE_PREFIX .. " Failed to read current position for saving. Is it populated?")
        return false
    end
    local success = self:WritePositionToMemory(self.Symbols.Saved, self:CalculateSymbolOffsets(), currentPosition, false, self.Transform.ValueType)
    if success then
        logger:Info(MODULE_PREFIX .. " Saved position " .. self:FormatPosition(currentPosition) .. ".")
    end
    return success
end
registerLuaFunctionHighlight('SaveCurrentPosition')

--
--- ∑ Returns a copied target position and applies the configured coordinate adjustment if enabled.
--- @param position table # The source position table {x, y, z}.
--- @return table|nil # The copied and adjusted target position, or nil on invalid input.
--
function Teleporter:GetAdjustedTargetPosition(position)
    local count = self:AxisCount()
    if type(position) ~= "table" or #position ~= count then
        -- The most likely cause is a Waypoint or Additional offset list that
        -- was not shortened along with the Transform, so both counts are named.
        logger:ErrorBlock(MODULE_PREFIX .. " Position has the wrong number of components", {
            { "Expected", count .. " (" .. table.concat(self:GetAxes(), ", ") .. ")" },
            { "Received", type(position) == "table" and #position or type(position) },
            { "Check",    "teleporter:ValidateConfiguration() lists every symbol whose offsets disagree" },
        })
        return nil
    end
    local adjusted = {}
    for index = 1, count do
        adjusted[index] = position[index]
    end
    if not self.Settings.AdjustYCoordinate then
        return adjusted
    end
    local coordinateIndex = tonumber(self.Settings.YCoordinateIndex) or 1
    local adjustmentAmount = tonumber(self.Settings.AdjustmentAmount) or 0
    if coordinateIndex < 1 or coordinateIndex > #adjusted then
        logger:WarningF(MODULE_PREFIX .. " Invalid YCoordinateIndex '%s'. Skipping adjustment.", tostring(self.Settings.YCoordinateIndex))
        return adjusted
    end
    adjusted[coordinateIndex] = adjusted[coordinateIndex] + adjustmentAmount
    if self.Settings.LogVerbose then
        logger:DebugF(MODULE_PREFIX .. " Adjusted coordinate index %d by %.3f -> {%.3f, %.3f, %.3f}",
                      coordinateIndex, adjustmentAmount, adjusted[1], adjusted[2], adjusted[3])
    end
    return adjusted
end
registerLuaFunctionHighlight('GetAdjustedTargetPosition')

--
--- ∑ Loads the previously saved position from memory and teleports the player there.
--- @returns # true if the position was successfully loaded, false otherwise.
--
function Teleporter:LoadSavedPosition()
    local currentPosition = self:GetCurrentPosition()
    local savedPosition = self:GetSavedPosition()
    if not savedPosition then
        logger:Error(MODULE_PREFIX .. " No saved position found. Is it populated?")
        return false
    end
    local targetPosition = self:GetAdjustedTargetPosition(savedPosition)
    if not targetPosition then
        return false
    end
    self:PauseGame()
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, targetPosition, true, self.Transform.ValueType)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, targetPosition, true, self.Additional.ValueType)
    end
    self:ResumeGame()
    if success then
        local backupStored = false
        if self.Symbols and self.Symbols.Backup then
            backupStored = self:WritePositionToMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), currentPosition, false, self.Settings.ValueType) == true
        end
        self:_ReportJump("Loaded saved position", currentPosition, targetPosition, backupStored)
    else
        logger:Error(MODULE_PREFIX .. " Something went wrong when loading the saved position.")
    end
    return success
end
registerLuaFunctionHighlight('LoadSavedPosition')

--
--- ∑ Loads the backup position from memory and teleports the player there.
--- @returns # true if the backup position was successfully loaded, false otherwise.
--
function Teleporter:LoadBackupPosition()
    local currentPosition = self:GetCurrentPosition()
    local backupPosition = self:GetBackupPosition()
    if not backupPosition then
        logger:Error(MODULE_PREFIX .. " No backup position found. Is it populated?")
        return false
    end
    local targetPosition = self:GetAdjustedTargetPosition(backupPosition)
    if not targetPosition then
        return false
    end
    self:PauseGame()
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, targetPosition, true, self.Transform.ValueType)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, targetPosition, true, self.Additional.ValueType)
    end
    self:ResumeGame()
    if success then
        local backupStored = false
        if self.Symbols and self.Symbols.Backup then
            backupStored = self:WritePositionToMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), currentPosition, false, self.Settings.ValueType) == true
        end
        self:_ReportJump("Loaded backup position", currentPosition, targetPosition, backupStored)
    else
        logger:Error(MODULE_PREFIX .. " Something went wrong when loading the backup position.")
    end
    return success
end
registerLuaFunctionHighlight('LoadBackupPosition')

--
--- ∑ Teleports the player to the specified coordinates.
--- @param position # A table containing the target coordinates {x, y, z}.
--- @returns # true if the teleportation was successful, false otherwise.
--
function Teleporter:TeleportToCoordinates(position)
    local count = self:AxisCount()
    if type(position) ~= "table" or #position ~= count then
        logger:ErrorBlock(MODULE_PREFIX .. " Invalid position format", {
            { "Expected", count .. " values (" .. table.concat(self:GetAxes(), ", ") .. ")" },
            { "Received", type(position) == "table" and (#position .. " values") or type(position) },
        })
        return false
    end
    local currentPosition = self:GetCurrentPosition()
    if not currentPosition then
        logger:Error(MODULE_PREFIX .. " Unable to retrieve current position.")
        return false
    end
    local targetPosition = self:GetAdjustedTargetPosition(position)
    if not targetPosition then
        return false
    end
    self:PauseGame()
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, targetPosition, true, self.Transform.ValueType)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, targetPosition, true, self.Additional.ValueType)
    end
    self:ResumeGame()
    if success then
        local backupStored = false
        if self.Symbols and self.Symbols.Backup then
            backupStored = self:WritePositionToMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), currentPosition, false, self.Settings.ValueType) == true
        end
        self:_ReportJump("Teleported to coordinates", currentPosition, targetPosition, backupStored)
    else
        logger:Error(MODULE_PREFIX .. " Teleportation failed.")
    end
    return success
end
registerLuaFunctionHighlight('TeleportToCoordinates')

--
--- ∑ Teleports the player to the currently set waypoint.
--- @returns # true if teleportation was successful, false otherwise.
--
function Teleporter:TeleportToWaypoint()
    local currentPosition = self:GetCurrentPosition()
    local waypointPosition = self:ReadPositionFromMemory(self.Waypoint.Symbol, self.Waypoint.Offsets, true, self.Waypoint.ValueType)
    if not waypointPosition then
        logger:Error(MODULE_PREFIX .. " No waypoint position found.")
        return false
    end
    local targetPosition = self:GetAdjustedTargetPosition(waypointPosition)
    if not targetPosition then
        return false
    end
    self:PauseGame()
    local success = self:WritePositionToMemory(self.Transform.Symbol, self.Transform.Offsets, targetPosition, true, self.Transform.ValueType)
    if success and self.Additional and self.Additional.Symbol and self.Additional.Offsets then
        success = self:WritePositionToMemory(self.Additional.Symbol, self.Additional.Offsets, targetPosition, true, self.Additional.ValueType)
    end
    self:ResumeGame()
    if success then
        local backupStored = false
        if self.Symbols and self.Symbols.Backup then
            backupStored = self:WritePositionToMemory(self.Symbols.Backup, self:CalculateSymbolOffsets(), currentPosition, false, self.Settings.ValueType) == true
        end
        self:_ReportJump("Teleported to waypoint", currentPosition, targetPosition, backupStored)
    end
    return success
end
registerLuaFunctionHighlight('TeleportToWaypoint')

--
--- ∑ Normalizes category input into a category path.
---   Accepts a string path ("World / Region / Room") or a numeric table.
--- @param categoryInput string|table # Raw category value.
--- @return table # Ordered category path parts.
--
function Teleporter:NormalizeCategoryPath(categoryInput)
    local path = {}
    if type(categoryInput) == "table" then
        for index = 1, #categoryInput do
            local part = trimString(categoryInput[index])
            if part ~= "" then
                path[#path + 1] = part
            end
        end
    elseif type(categoryInput) == "string" then
        local normalized = categoryInput:gsub("\\", "/"):gsub(">", "/"):gsub("|", "/")
        for part in normalized:gmatch("[^/]+") do
            part = trimString(part)
            if part ~= "" then
                path[#path + 1] = part
            end
        end
    end
    return path
end
registerLuaFunctionHighlight('NormalizeCategoryPath')

--
--- ∑ Converts a category path table into the editor/display text format.
--- @param categoryPath table|string # Category path table or string.
--- @param includeDefault boolean # Whether an empty path should return "Default".
--- @return string # Display text for the path.
--
function Teleporter:CategoryPathToText(categoryPath, includeDefault)
    local path = self:NormalizeCategoryPath(categoryPath)
    if #path == 0 then
        return includeDefault ~= false and DEFAULT_CATEGORY or ""
    end
    return table.concat(path, CATEGORY_PATH_SEPARATOR)
end
registerLuaFunctionHighlight('CategoryPathToText')

--
--- ∑ Retrieves the category path for a save, supporting both new and legacy data.
--- @param save table # Save data.
--- @param includeDefault boolean # Whether an empty path should become {"Default"}.
--- @return table # Ordered category path parts.
--
function Teleporter:GetSaveCategoryPath(save, includeDefault)
    local path = {}
    if type(save) == "table" then
        path = self:NormalizeCategoryPath(save.Categories)
        if #path == 0 then
            path = self:NormalizeCategoryPath(save.Category)
        end
    end
    if #path == 0 and includeDefault ~= false then
        path = { DEFAULT_CATEGORY }
    end
    return path
end
registerLuaFunctionHighlight('GetSaveCategoryPath')

--
--- ∑ Stores a normalized category path on a save while keeping legacy Category text.
--- @param save table # Save data to update.
--- @param categoryInput string|table # Category path from the UI or caller.
--
function Teleporter:SetSaveCategoryPath(save, categoryInput)
    if type(save) ~= "table" then
        return
    end
    local path = self:NormalizeCategoryPath(categoryInput)
    if #path == 0 then
        save.Category = ""
        save.Categories = nil
        return
    end
    save.Categories = path
    save.Category = self:CategoryPathToText(path, false)
end
registerLuaFunctionHighlight('SetSaveCategoryPath')

--
--- ∑ Builds the unique storage key for a save from its category path and display name.
---   Identity is the full path, so the same display name may live in several categories.
--- @param categoryInput table|string # Category path parts or path text.
--- @param saveName string # Display name of the save.
--- @return string|nil # Storage key, or nil when the name is empty.
--
function Teleporter:MakeSaveKey(categoryInput, saveName)
    local name = trimString(saveName)
    if name == "" then
        return nil
    end
    local path = self:NormalizeCategoryPath(categoryInput)
    if #path == 0 then
        path[1] = DEFAULT_CATEGORY
    end
    path[#path + 1] = name
    return table.concat(path, CATEGORY_PATH_SEPARATOR)
end
registerLuaFunctionHighlight('MakeSaveKey')

--
--- ∑ Returns the storage key a save should live under, derived from its own fields.
--- @param save table # Save data carrying Name and Categories.
--- @return string|nil # Storage key, or nil when the save carries no name.
--
function Teleporter:GetSaveKey(save)
    if type(save) ~= "table" then
        return nil
    end
    return self:MakeSaveKey(self:GetSaveCategoryPath(save, true), save.Name)
end
registerLuaFunctionHighlight('GetSaveKey')

--
--- ∑ Returns the display name of a save, falling back to the key for legacy data.
--- @param save table # Save data.
--- @param fallbackKey string|nil # Key to fall back to when no name is stored.
--- @return string # Display name.
--
function Teleporter:GetSaveDisplayName(save, fallbackKey)
    if type(save) == "table" then
        local name = trimString(save.Name)
        if name ~= "" then
            return name
        end
    end
    return trimString(fallbackKey)
end
registerLuaFunctionHighlight('GetSaveDisplayName')

--
--- ∑ Resolves caller input to a storage key.
---   Accepts a full key, or a bare display name while it stays unambiguous. That name
---   fallback is what keeps scripts generated before path keys existed working.
--- @param input string # Storage key or display name.
--- @return string|nil, string|nil # Resolved key, or nil plus the reason it failed.
--
function Teleporter:ResolveSaveKey(input)
    local needle = trimString(input)
    if needle == "" then
        return nil, "empty name"
    end
    if type(self.Saves) ~= "table" then
        return nil, "no saves loaded"
    end
    if type(self.Saves[needle]) == "table" then
        return needle
    end
    local matches = {}
    for key, save in pairs(self.Saves) do
        if type(save) == "table" and trimString(save.Name) == needle then
            matches[#matches + 1] = key
        end
    end
    if #matches == 1 then
        return matches[1]
    end
    if #matches > 1 then
        sortCaseInsensitive(matches)
        return nil, string.format("ambiguous, matches %d categories (%s)", #matches, table.concat(matches, ", "))
    end
    return nil, "not found"
end
registerLuaFunctionHighlight('ResolveSaveKey')

--
--- ∑ Adds a save name to a nested category tree.
--- @param root table # Category tree root.
--- @param categoryPath table # Ordered category path parts.
--- @param saveName string # Save name to add.
--
function Teleporter:AddSaveToCategoryTree(root, categoryPath, saveName)
    local node = root
    for _, category in ipairs(categoryPath or {}) do
        node.Categories[category] = node.Categories[category] or newCategoryNode()
        node = node.Categories[category]
    end
    node.Saves[#node.Saves + 1] = saveName
end
registerLuaFunctionHighlight('AddSaveToCategoryTree')

--
--- ∑ Builds the Author -> Category Path -> Save hierarchy used by UI and CE records.
--- @param includeSaveFunc function|nil # Optional predicate: fn(saveKey, saveData, author, categoryText).
--- @return table # Nested hierarchy grouped by author. Leaf entries are storage keys.
--
function Teleporter:BuildSaveHierarchy(includeSaveFunc)
    self:EnsureAuthorsAndCategories()
    local grouped = {}
    for saveKey, data in pairs(self.Saves or {}) do
        if type(saveKey) == "string" and self:SaveToPosition(data) ~= nil then
            local author = trimString(data.Author)
            if author == "" then
                author = "Unknown"
            end
            local categoryPath = self:GetSaveCategoryPath(data, true)
            local categoryText = self:CategoryPathToText(categoryPath, true)
            if not includeSaveFunc or includeSaveFunc(saveKey, data, author, categoryText) then
                grouped[author] = grouped[author] or newCategoryNode()
                self:AddSaveToCategoryTree(grouped[author], categoryPath, saveKey)
            end
        end
    end
    return grouped
end
registerLuaFunctionHighlight('BuildSaveHierarchy')

--
--- ∑ Rebuilds the storage key a tree node points at, ignoring author/category headers.
---   The tree mirrors Author -> Category Path -> Save, so the ancestor texts below the
---   author node are exactly the save's category path followed by its display name.
--- @param node table # Tree node to inspect.
--- @return string|nil # Save key when the node represents a save.
--
function Teleporter:GetSaveKeyFromTreeNode(node)
    if not node or type(self.Saves) ~= "table" then
        return nil
    end
    if (tonumber(node.Count) or 0) > 0 then
        return nil
    end
    local chain = {}
    local current, guard = node, 0
    while current and guard < 64 do
        chain[#chain + 1] = trimString(current.Text)
        local ok, parent = pcall(function() return current.Parent end)
        current = ok and parent or nil
        guard = guard + 1
    end
    if #chain > 1 then
        -- chain runs leaf -> author. Drop the author entry and flip back into path order.
        local path = {}
        for index = #chain - 1, 1, -1 do
            path[#path + 1] = chain[index]
        end
        local key = table.concat(path, CATEGORY_PATH_SEPARATOR)
        if type(self.Saves[key]) == "table" then
            return key
        end
    end
    -- Fallback for hosts where TTreeNode.Parent is unavailable: match on the leaf text.
    return (self:ResolveSaveKey(node.Text))
end
registerLuaFunctionHighlight('GetSaveKeyFromTreeNode')

--
--- ∑ Deprecated alias kept for callers written against the pre-path-key API.
--- @param node table # Tree node to inspect.
--- @return string|nil # Save key when the node represents a save.
--
function Teleporter:GetSaveNameFromTreeNode(node)
    return self:GetSaveKeyFromTreeNode(node)
end
registerLuaFunctionHighlight('GetSaveNameFromTreeNode')

--
--- ∑ Renders the save hierarchy as a tree, ready to be logged or shown elsewhere.
---   Kept separate from PrintSaves so the layout can be tested and reused without
---   going through the logger.
--- @param options table|nil # { coordinates = true, descriptions = true, width = 92 }
--- @return table # { Lines, Summary, Totals = { Saves, Categories, Authors, Invalid } }
--
function Teleporter:FormatSaveTree(options)
    options = options or {}
    local showCoordinates = options.coordinates ~= false
    local showDescriptions = options.descriptions ~= false
    local wrapWidth = tonumber(options.width) or DEFAULT_DESCRIPTION_WIDTH
    local totals = { Saves = 0, Categories = 0, Authors = 0, Invalid = 0 }
    local invalidKeys = {}
    local axes = self:GetAxes()
    for key, save in pairs(self.Saves or {}) do
        if self:SaveToPosition(save) == nil then
            totals.Invalid = totals.Invalid + 1
            invalidKeys[#invalidKeys + 1] = tostring(key)
        end
    end
    sortCaseInsensitive(invalidKeys)
    -- Flatten first so column widths can be measured before anything is rendered.
    local items = {}
    local function collect(node, prefix)
        local categories = sortedKeys(node.Categories)
        sortCaseInsensitive(node.Saves)
        local remaining = #categories + #node.Saves
        for _, category in ipairs(categories) do
            remaining = remaining - 1
            local isLast = remaining == 0
            totals.Categories = totals.Categories + 1
            items[#items + 1] = {
                Kind = "category",
                Prefix = prefix .. (isLast and TREE_LAST or TREE_BRANCH),
                Text = category,
            }
            collect(node.Categories[category], prefix .. (isLast and TREE_BLANK or TREE_TRUNK))
        end
        for _, saveKey in ipairs(node.Saves) do
            remaining = remaining - 1
            local isLast = remaining == 0
            local save = self.Saves[saveKey]
            totals.Saves = totals.Saves + 1
            items[#items + 1] = {
                Kind = "save",
                Prefix = prefix .. (isLast and TREE_LAST or TREE_BRANCH),
                Continuation = prefix .. (isLast and TREE_BLANK or TREE_TRUNK),
                Text = self:GetSaveDisplayName(save, saveKey),
                Save = save,
            }
        end
    end
    local grouped = self:BuildSaveHierarchy()
    for _, author in ipairs(sortedKeys(grouped)) do
        totals.Authors = totals.Authors + 1
        items[#items + 1] = { Kind = "author", Prefix = "", Text = author }
        collect(grouped[author], "")
    end
    local nameWidth, coordWidth = 0, 0
    for _, item in ipairs(items) do
        if item.Kind == "save" then
            local width = displayWidth(item.Prefix) + displayWidth(item.Text)
            if width > nameWidth then
                nameWidth = width
            end
            for _, axis in ipairs(axes) do
                local width = #string.format("%.3f", tonumber(item.Save[axis]) or 0)
                if width > coordWidth then
                    coordWidth = width
                end
            end
        end
    end
    -- One right aligned column per axis, so a 2D table gets two columns and a
    -- 3D one gets three without the layout knowing which it is.
    local columns = {}
    for index = 1, #axes do
        columns[index] = string.format("%%%ds", coordWidth)
    end
    local coordFormat = table.concat(columns, "  ")
    local lines = {}
    for _, item in ipairs(items) do
        local line = item.Prefix .. item.Text
        if item.Kind == "save" and showCoordinates then
            local values = {}
            for index, axis in ipairs(axes) do
                values[index] = string.format("%.3f", tonumber(item.Save[axis]) or 0)
            end
            line = line .. string.rep(" ", nameWidth - displayWidth(line) + 2)
                        .. string.format(coordFormat, table.unpack(values))
        end
        lines[#lines + 1] = line
        if item.Kind == "save" and showDescriptions then
            for _, wrapped in ipairs(wrapText(trimString(item.Save.Description), wrapWidth)) do
                if wrapped == "" then
                    -- Paragraph break: keep the trunk, drop the padding behind it.
                    lines[#lines + 1] = (item.Continuation:gsub("%s+$", ""))
                else
                    lines[#lines + 1] = item.Continuation .. DESCRIPTION_INDENT .. wrapped
                end
            end
        end
    end
    if totals.Invalid > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = string.format("Skipped %s without coordinates:",
            pluralize(totals.Invalid, "entry", "entries"))
        for _, key in ipairs(invalidKeys) do
            lines[#lines + 1] = TREE_BRANCH .. key
        end
        lines[#lines] = TREE_LAST .. invalidKeys[#invalidKeys]
    end
    local summary = string.format("Saves — %s across %s from %s",
        pluralize(totals.Saves, "save", "saves"),
        pluralize(totals.Categories, "category", "categories"),
        pluralize(totals.Authors, "author", "authors"))
    return { Lines = lines, Summary = summary, Totals = totals }
end
registerLuaFunctionHighlight('FormatSaveTree')

--
--- ∑ Logs every saved location as one tree, grouped by author and category path.
---   Emitted as a single forced entry so the log prefix does not repeat on every
---   row and the tree keeps its shape.
--- @param options table|nil # Passed through to FormatSaveTree.
--- @return boolean # true when something was printed.
--
function Teleporter:PrintSaves(options)
    if not self.Saves or next(self.Saves) == nil then
        logger:ForceError(MODULE_PREFIX .. " No saves found.")
        return false
    end
    local rendered = self:FormatSaveTree(options)
    logger:ForceInfo(string.format("%s %s\n%s", MODULE_PREFIX, rendered.Summary,
        table.concat(rendered.Lines, "\n")))
    return true
end
registerLuaFunctionHighlight('PrintSaves')

-- .....................................................

--
--- ∑ Validates the name of a save or waypoint.
--- @param name string # The name to validate.
--- @param action string # The action for which the name is being validated.
--- @returns boolean # true if the name is valid, false otherwise.
--
local function validateName(name, action)
    if not name or type(name) ~= "string" then
        logger:ErrorF(MODULE_PREFIX .. " Invalid %s Name: '%s'.", action, tostring(name))
        return false
    end
    return true
end

--
--- ∑ Teleports the player to a saved position.
--- @param name string # Storage key of the save, or its display name when unambiguous.
--- @return boolean # true if teleportation was successful, false otherwise.
--
function Teleporter:TeleportToSave(name)
    if not validateName(name, "Save") then
        logger:Error(MODULE_PREFIX .. " Invalid save name.")
        return false
    end
    local saveKey, reason = self:ResolveSaveKey(name)
    local save = saveKey and self.Saves and self.Saves[saveKey]
    local position = self:SaveToPosition(save)
    if not position then
        logger:ErrorBlock(MODULE_PREFIX .. " Save not found, or it has no usable position", {
            { "Requested", tostring(name) },
            { "Reason",    tostring(reason or "the entry is missing an axis") },
            { "Axes",      table.concat(self:GetAxes(), ", ") },
        })
        return false
    end
    local success = self:TeleportToCoordinates(position)
    if success then
        logger:InfoF(MODULE_PREFIX .. " Teleported to Save: '%s'", saveKey)
    end
    return success
end
registerLuaFunctionHighlight('TeleportToSave')

--
--- ∑ Clears all child records from a given memory record, effectively resetting it.
--
function Teleporter:ClearSubrecords(record)
    while record ~= nil and record.Count > 0 do
        memoryrecord_delete(record.Child[0])
    end
end
registerLuaFunctionHighlight('ClearSubrecords')

--
--- ∑ Ensures the existence of the Teleporter directory within the DataDir.
---   If missing, it creates the directory.
--- @return string|nil # The Teleporter directory path if successful, otherwise nil.
--
function Teleporter:EnsureTeleporterDir()
    local teleporterDir = customIO.DataDir .. "\\Teleporter"
    if not customIO:EnsureDataDirectory() then
        logger:Warning(MODULE_PREFIX .. " Data Directory missing; cannot ensure Teleporter Directory.")
        return nil
    end
    local exists, err = customIO:DirectoryExists(teleporterDir)
    if not exists and err then
        logger:Error(MODULE_PREFIX .. " Failed to check Teleporter Dir: " .. err)
        return nil
    end
    if not exists then
        local ok, createErr = customIO:CreateDirectory(teleporterDir)
        if not ok then
            logger:ErrorBlock(MODULE_PREFIX .. " Teleporter directory unavailable", {
                { "Directory", teleporterDir },
                { "Reason",    createErr or "unknown error" },
            })
            return nil
        end
        logger:Debug(MODULE_PREFIX .. " Created directory: " .. teleporterDir)
    end
    return teleporterDir
end
registerLuaFunctionHighlight('EnsureTeleporterDir')

--
--- ∑ Retrieves the expected save file path for Teleporter state.
---   Ensures the Teleporter directory exists before returning the path.
--- @return string|nil # The full save file path if successful, otherwise nil.
--
function Teleporter:GetSaveFilePath()
    local teleporterDir = self:EnsureTeleporterDir()
    if not teleporterDir then
        logger:Error(MODULE_PREFIX .. " Cannot determine save file path; Teleporter directory is missing.")
        return nil, nil
    end
    local saveFilePath = string.format(self.SaveFileName, utils:GetTargetNoExt())
    -- Called by every read and every write. SaveLookup names the file it
    -- actually used, so announcing the path here said it twice.
    return teleporterDir .. "\\" .. saveFilePath, saveFilePath
end
registerLuaFunctionHighlight('GetSaveFilePath')

--
--- ∑ Attempts to load the teleporter lookup table.
---   First, checks DataDir/Teleporter. If unavailable, falls back to TableFiles.
---   If both fail, logs an error.
--- @return table|nil # The loaded teleporter data, or nil on failure.
--
function Teleporter:SaveLookup()
    local saveFilePath, saveFileName = self:GetSaveFilePath()
    -- Both sources are tried in order and the outcome is reported once, at the
    -- end. Narrating each attempt meant a successful load from the first
    -- source still wrote three lines, and a fallback wrote five.
    local dataDirError, tableFileError
    local function adopt(data)
        self.Saves = data
        if (self:EnsureAuthorsAndCategories() or 0) > 0 then
            self:PersistSaves(true)
        end
        return self:CountSaves()
    end
    if saveFilePath then
        local data, err = customIO:ReadFromFileAsJson(saveFilePath)
        if data then
            logger:InfoBlock(MODULE_PREFIX .. " Loaded saves", {
                { "Source", "data directory" },
                { "File",   saveFilePath },
                { "Saves",  adopt(data) },
            })
            return self.Saves
        end
        dataDirError = err
    end
    local tableData, tableErr = customIO:ReadFromTableFileAsJson(saveFileName)
    if tableData then
        logger:InfoBlock(MODULE_PREFIX .. " Loaded saves", {
            { "Source", "table file" },
            { "File",   saveFileName },
            { "Saves",  adopt(tableData) },
        })
        return self.Saves
    end
    tableFileError = tableErr
    logger:WarningBlock(MODULE_PREFIX .. " No save data found", {
        { "Data directory", saveFilePath or "unavailable" },
        dataDirError and { "Reason", tostring(dataDirError) } or false,
        { "Table file",     saveFileName or "unavailable" },
        tableFileError and { "Reason", tostring(tableFileError) } or false,
    })
    return nil
end
registerLuaFunctionHighlight('SaveLookup')

--
--- ∑ Saves the Teleporter lookup table to a Table File.
--- @return boolean # True if successful, false otherwise.
--
function Teleporter:WriteSavesToTableFile()
    local _, saveFileName = self:GetSaveFilePath()
    if not self.Saves or not next(self.Saves) then
        logger:Warning(MODULE_PREFIX .. " No data available to save to TableFiles.")
        return false
    end
    local success, err = customIO:WriteToTableFileAsJson(saveFileName, self.Saves)
    if success then
        logger:Info(MODULE_PREFIX .. " Saved " .. self:CountSaves() .. " saves to the table file.")
        return true
    end
    logger:ErrorBlock(MODULE_PREFIX .. " Could not save to the table file", {
        { "File",   tostring(saveFileName) },
        { "Reason", err or "unknown error" },
    })
    return false
end
registerLuaFunctionHighlight('WriteSavesToTableFile')

--
--- ∑ Saves the Teleporter lookup table to DataDir/Teleporter.
--- @return boolean # True if successful, false otherwise.
--
function Teleporter:WriteSavesToDataDir()
    local saveFilePath = select(1, self:GetSaveFilePath())
    if not self.Saves or not next(self.Saves) then
        logger:Warning(MODULE_PREFIX .. " No data available to save to DataDir.")
        return false
    end
    local success, err = customIO:WriteToFileAsJson(saveFilePath, self.Saves)
    if success then
        logger:Info(MODULE_PREFIX .. " Saved " .. self:CountSaves() .. " saves to the data directory.")
        return true
    end
    logger:ErrorBlock(MODULE_PREFIX .. " Could not save to the data directory", {
        { "File",   tostring(saveFilePath) },
        { "Reason", err or "unknown error" },
    })
    return false
end
registerLuaFunctionHighlight('WriteSavesToDataDir')

--
--- ∑ Creates Teleporter saves and populates the memory record list.
--
function Teleporter:CreateTeleporterSaves()
    if not inMainThread() then
        synchronize(function() self:CreateTeleporterSaves() end)
        return
    end
    local addressList = getAddressList()
    if not addressList then
        logger:Error(MODULE_PREFIX .. " AddressList not available.")
        return
    end
    local root = addressList.getMemoryRecordByDescription(self.SaveMemoryRecordName)
    if not root then
        logger:ErrorF(MODULE_PREFIX .. " Failed to find root memory record: '%s'.", self.SaveMemoryRecordName)
        return
    end
    local didBeginUpdate = false
    if addressList.beginUpdate then
        addressList.beginUpdate()
        didBeginUpdate = true
    elseif addressList.BeginUpdate then
        addressList:BeginUpdate()
        didBeginUpdate = true
    end
    local axes = self:GetAxes()
    local ok, err = pcall(function()
        self:ClearSubrecords(root)
        local grouped = self:BuildSaveHierarchy()
        local totalSaves = 0
        local function createSaveRecord(parentRecord, saveKey, author)
            local position = self.Saves[saveKey]
            if type(position) ~= "table" then
                return
            end
            local displayName = self:GetSaveDisplayName(position, saveKey)
            local categoryText = self:CategoryPathToText(self:GetSaveCategoryPath(position, true), true)
            -- The coordinate comment is built per axis, so the generated
            -- script documents two values for a 2D table and three for a 3D
            -- one instead of printing a Z that does not exist.
            local coordinateLines = {}
            for _, axis in ipairs(axes) do
                coordinateLines[#coordinateLines + 1] =
                    string.format("---- %s: %.4f", axis, tonumber(position[axis]) or 0)
            end
            local scriptContent = string.format([[
{$lua}
if syntaxcheck then return end
[ENABLE]
-- ...........................[ENABLE]...........................
--- Save: %s
--- Author: %s
--- Category: %s
%s
teleporter:TeleportToSave("%s")
utils:AutoDisable(memrec.ID)
[DISABLE]
-- ..........................[DISABLE]...........................

--- Script generated using %s
---- Version: %s
---- Source: https://github.com/Leunsel/CheatEngineLua/tree/main/Manifold-Modules
]], displayName, author, categoryText, table.concat(coordinateLines, "\n"), saveKey, NAME or "Manifold.Teleporter.lua", VERSION or "Unknown")

            local mr = addressList.createMemoryRecord()
            mr.Type = vtAutoAssembler
            mr.Description = "Teleport To: '" .. displayName .. "' ()->"
            mr.Color = 0xFFFFFF
            mr.Parent = parentRecord
            mr.Script = scriptContent
            totalSaves = totalSaves + 1
        end
        local function createCategoryRecords(parentRecord, node, author)
            for _, category in ipairs(sortedKeys(node.Categories)) do
                local categoryHeader = addressList.createMemoryRecord()
                categoryHeader.Type = vtGroupHeader
                categoryHeader.IsAddressGroupHeader = false
                categoryHeader.Description = string.format("[— %s —] ()->", category)
                categoryHeader.Color = 0xFFFFFF
                categoryHeader.Parent = parentRecord
                createCategoryRecords(categoryHeader, node.Categories[category], author)
            end
            sortCaseInsensitive(node.Saves)
            for _, saveKey in ipairs(node.Saves) do
                createSaveRecord(parentRecord, saveKey, author)
            end
        end
        for _, author in ipairs(sortedKeys(grouped)) do
            local authorHeader = addressList.createMemoryRecord()
            authorHeader.Type = vtGroupHeader
            authorHeader.Description = string.format("[— %s —] ()->", author)
            authorHeader.Color = 0xFFFFFF
            authorHeader.Parent = root
            authorHeader.IsAddressGroupHeader = false
            createCategoryRecords(authorHeader, grouped[author], author)
        end
        logger:InfoF(MODULE_PREFIX .. " Created %d save records, grouped by author and category path.", totalSaves)
    end)
    if didBeginUpdate then
        if addressList.endUpdate then
            addressList.endUpdate()
        elseif addressList.EndUpdate then
            addressList:EndUpdate()
        end
    end
    if not ok then
        logger:ErrorF(MODULE_PREFIX .. " Failed to create Teleporter saves: %s", tostring(err))
    end
end
registerLuaFunctionHighlight('CreateTeleporterSaves')

--
--- ∑ Logs detailed errors when a save position is invalid, including the name of the save and the contents of the position table.
--- @param name string # The name of the save being validated.
--- @param position table # The position table to validate, expected to contain numeric values at indices 1, 2, and 3.
--- @returns boolean # true if the position is valid, false if it is invalid and an error was logged.
--
local function logSavePositionError(teleporter, name, position)
    local axes = teleporter:GetAxes()
    if type(position) ~= "table" then
        logger:ErrorBlock(MODULE_PREFIX .. " Cannot save a position that was never read", {
            { "Save",     tostring(name) },
            { "Received", type(position) },
        })
        return false
    end
    local rows = { { "Save", tostring(name) } }
    local complete = #position >= #axes
    for index, axis in ipairs(axes) do
        if position[index] == nil then complete = false end
        rows[#rows + 1] = { axis, tostring(position[index]) }
    end
    if complete then
        return true
    end
    logger:ErrorBlock(MODULE_PREFIX .. " Invalid position for save", rows)
    return false
end

--
--- ∑ Retrieves the current system username for use as the default author.
--- @returns string # The current username or "Unknown" if it cannot be determined.
--
function Teleporter:GetCurrentAuthor()
    return os.getenv("USERNAME") or os.getenv("USER") or "Unknown"
end

--
--- ∑ Ensures that the UI state table exists and returns it.
---   It holds every control the window built, keyed by name, plus the two
---   pieces of state the refresh loop needs. The controls are not declared
---   here. They used to be, as ninety lines assigning nil, which in Lua
---   constructs nothing: the table it produced had exactly the two entries
---   below. Each Create* function registers what it built, and the two Keys
---   lists say which of the variable sets actually exist.
---
---     <Field>Edit / Row / Label / Border / Fill / Inner   one field row
---     AxisFieldKeys                                       the coordinate rows
---     ButtonKeys                                          the buttons
---
--- @return table # The UI state.
--
function Teleporter:EnsureUiState()
    self.UiState = self.UiState or { SearchQuery = "", IsRefreshing = false }
    return self.UiState
end

--
--- ∑ Counts the number of saves currently stored in the Teleporter's Saves table.
--- @returns integer # The total number of saves.
--
function Teleporter:CountSaves()
    local count = 0
    for _ in pairs(self.Saves or {}) do
        count = count + 1
    end
    return count
end

--
--- ∑ Persists the current saves to storage. It first attempts to write to DataDir, and if that fails, it falls back to writing to TableFiles. Logs errors if both methods fail.
--- @param preferDataDir boolean # Whether to prefer saving to DataDir first. Defaults to true. If false, it will attempt to save to TableFiles first.
--- @returns boolean # true if the saves were successfully persisted, false otherwise.
--
function Teleporter:PersistSaves(preferDataDir)
    local ok = false
    if preferDataDir ~= false then
        ok = self:WriteSavesToDataDir()
        if not ok then
            logger:Warning(MODULE_PREFIX .. " Failed to persist saves to DataDir. Falling back to TableFile...")
        end
    end
    if not ok then
        ok = self:WriteSavesToTableFile()
    end
    if not ok then
        logger:Error(MODULE_PREFIX .. " Failed to persist Teleporter saves.")
    end
    return ok
end

--
--- ∑ Sets the status text in the UI, typically used to provide feedback to the user about the current state of the Teleporter (e.g., "Ready", "Error: Invalid Save Name", etc.).
--- @param text string # The status text to display. If nil or empty, defaults to "Ready".
--
function Teleporter:SetStatus(text)
    local ui = self:EnsureUiState()
    if ui.StatusLabel then
        ui.StatusLabel.Caption = text or "Ready"
    end
end

function Teleporter:ClearEditor()
    local ui = self:EnsureUiState()
    ui.CurrentSelection = nil
    if ui.NameEdit then ui.NameEdit.Text = "" end
    if ui.AuthorEdit then ui.AuthorEdit.Text = self:GetCurrentAuthor() end
    if ui.CategoryEdit then ui.CategoryEdit.Text = "" end
    for _, edit in ipairs(self:GetAxisEdits()) do
        edit.Text = ""
    end
    if ui.DescriptionEdit then ui.DescriptionEdit.Lines.Text = "" end
    ui.CurrentSelection = nil
end

--
--- ∑ Retrieves the currently selected save name from the UI state.
--- @returns string|nil # The name of the currently selected save, or nil if no selection.
--
function Teleporter:GetSelectedSaveName()
    local ui = self:EnsureUiState()
    return ui.CurrentSelection
end

--
--- ∑ Sets the currently selected save name in the UI state.
--- @param name string # The name of the save to set as selected.
--
function Teleporter:SetSelectedSaveName(name)
    local ui = self:EnsureUiState()
    ui.CurrentSelection = name
end

--
--- ∑ Loads a save into the editor fields. Returns false if the save is not found.
--- @param name string # Storage key of the save, or its display name when unambiguous.
--- @returns boolean # true if the save was loaded successfully, false otherwise.
--
function Teleporter:LoadSaveIntoEditor(name)
    local ui = self:EnsureUiState()
    local saveKey = self:ResolveSaveKey(name)
    local save = saveKey and self.Saves and self.Saves[saveKey]
    if not save then
        self:ClearEditor()
        return false
    end
    ui.CurrentSelection = saveKey
    -- The editor may not exist. AddSave, CreateSaveFromCurrentPosition and
    -- TeleportToSave are all callable from a table script without the window
    -- ever having been opened, and each of them ends up here.
    if not ui.NameEdit then
        return true
    end
    ui.NameEdit.Text = self:GetSaveDisplayName(save, saveKey)
    ui.AuthorEdit.Text = save.Author or self:GetCurrentAuthor()
    ui.CategoryEdit.Text = self:CategoryPathToText(self:GetSaveCategoryPath(save, false), false)
    for index, axis in ipairs(self:GetAxes()) do
        local edit = ui[axis .. "Edit"]
        if edit then edit.Text = tostring(save[axis] or "") end
    end
    ui.DescriptionEdit.Lines.Text = save.Description or ""
    return true
end

--
--- ∑ The editor's coordinate boxes, in axis order.
---   Skips any that were never built, so a caller written against three axes
---   does not raise on a table configured for two.
--- @return table # Array of text boxes.
--
function Teleporter:GetAxisEdits()
    local ui = self:EnsureUiState()
    local edits = {}
    for _, axis in ipairs(ui.AxisFieldKeys or self:GetAxes()) do
        local edit = ui[axis .. "Edit"]
        if edit then edits[#edits + 1] = edit end
    end
    return edits
end
registerLuaFunctionHighlight('GetAxisEdits')

--
--- ∑ Writes the saves out and brings the window back in step with them.
---   Add, update, rename, duplicate and delete all ended with the same five
---   calls in slightly different orders, which is five places to forget one.
--- @param key string|nil # The save to select afterwards. nil means the
---   selection is gone, which is the delete case, and the editor is cleared.
--- @param status string # The status bar line.
--- @return boolean # Always true, so a caller can `return self:_Commit(...)`.
--
function Teleporter:_CommitSaveChange(key, status)
    self:PersistSaves(true)
    self:SetSelectedSaveName(key)
    self:RefreshUi(key ~= nil)
    if key then
        self:LoadSaveIntoEditor(key)
    else
        self:ClearEditor()
    end
    self:SetStatus(status)
    return true
end

--
--- ∑ Attempts to parse the position from the editor fields.
--- @returns table|nil # The position, or nil when a field is empty or not a number.
--
function Teleporter:TryGetEditorPosition()
    local ui = self:EnsureUiState()
    local position = {}
    for index, axis in ipairs(self:GetAxes()) do
        local edit = ui[axis .. "Edit"]
        local value = edit and tonumber(edit.Text)
        if value == nil then
            return nil
        end
        position[index] = value
    end
    return position
end

--
--- ∑ Generates a copy name that is unique inside the given category.
--- @param baseName string # The original display name to base the copy name on.
--- @param categoryInput table|string # Category path the copy will live in.
--- @returns string # A unique name for the copied save (e.g., "Save (Copy)", "Save (Copy 2)", etc.).
--
function Teleporter:GenerateUniqueCopyName(baseName, categoryInput)
    local index = 1
    local name = string.format("%s (Copy)", baseName)
    while self.Saves and self.Saves[self:MakeSaveKey(categoryInput, name)] do
        index = index + 1
        name = string.format("%s (Copy %d)", baseName, index)
    end
    return name
end

--
--- ∑ Refreshes the Teleporter UI, optionally preserving the current selection.
--- @param preserveSelection boolean # Whether to preserve the current selection after refresh. Defaults to true.
--
function Teleporter:RefreshUi(preserveSelection)
    local ui = self:EnsureUiState()
    if ui.IsRefreshing or not ui.TreeView then
        return
    end
    ui.IsRefreshing = true
    local previousSelection = preserveSelection ~= false and ui.CurrentSelection or nil
    local query = (ui.SearchEdit and ui.SearchEdit.Text or ui.SearchQuery or ""):lower()
    ui.TreeView.beginUpdate()
    ui.TreeView.Items:clear()
    local grouped = self:BuildSaveHierarchy(function(saveKey, data, author, categoryText)
        local description = data.Description or ""
        local haystack = string.lower(table.concat({
            saveKey, self:GetSaveDisplayName(data, saveKey), author, categoryText, description
        }, " "))
        return query == "" or haystack:find(query, 1, true)
    end)
    local function addCategoryNodes(parentTreeNode, categoryNode)
        for _, category in ipairs(sortedKeys(categoryNode.Categories)) do
            local categoryTreeNode = parentTreeNode:add()
            categoryTreeNode.Text = category
            addCategoryNodes(categoryTreeNode, categoryNode.Categories[category])
        end
        sortCaseInsensitive(categoryNode.Saves)
        for _, saveKey in ipairs(categoryNode.Saves) do
            local saveNode = parentTreeNode:add()
            saveNode.Text = self:GetSaveDisplayName(self.Saves[saveKey], saveKey)
            if previousSelection and previousSelection == saveKey then
                ui.TreeView.Selected = saveNode
            end
        end
    end
    for _, author in ipairs(sortedKeys(grouped)) do
        local authorNode = ui.TreeView.Items:add()
        authorNode.Text = author
        addCategoryNodes(authorNode, grouped[author])
    end
    ui.TreeView.endUpdate()
    ui.IsRefreshing = false
    if previousSelection and self.Saves and self.Saves[previousSelection] then
        self:LoadSaveIntoEditor(previousSelection)
    elseif not previousSelection then
        self:ClearEditor()
    end
    if ui.TreeStatsLabel then
        ui.TreeStatsLabel.Caption = string.format("%d saves", self:CountSaves())
    end
    self:SetStatus(string.format("%d saves loaded", self:CountSaves()))
end

--
--- ∑ Creates a new save from the current position and persists it.
--- @param name string # The name of the save. If nil, the user will be prompted to enter a name.
--- @param category string # An optional category for the save.
--- @param description string # An optional description for the save.
--- @returns # true if the save was successfully created, false otherwise.
--
function Teleporter:CreateSaveFromCurrentPosition(name, category, description)
    local saveName = name
    if not saveName or saveName == "" then
        saveName = inputQuery("Add Save", "Enter a name for the new save:", "Location")
    end
    if not validateName(saveName, "Save") then
        return false
    end
    local position = self:GetCurrentPosition()
    if not logSavePositionError(self, saveName, position) then
        return false
    end
    self.Saves = self.Saves or {}
    local save = self:PositionToSave({
        Name = trimString(saveName),
        Author = self:GetCurrentAuthor(),
        Description = description or "",
    }, position)
    self:SetSaveCategoryPath(save, category)
    local saveKey = self:GetSaveKey(save)
    if not saveKey then
        logger:Error(MODULE_PREFIX .. " Cannot create a save without a name.")
        return false
    end
    if self.Saves[saveKey] then
        logger:ErrorF(MODULE_PREFIX .. " Save Already Exists In That Category: '%s'.", saveKey)
        return false
    end
    self.Saves[saveKey] = save
    logger:InfoF(MODULE_PREFIX .. " Added Save: '%s'", saveKey)
    return self:_CommitSaveChange(saveKey, "Save created: " .. save.Name)
end

--
--- ∑ Adds a new save using the current position. If called from a non-main thread, it synchronizes the call to the main thread.
--- @returns # true if the save was successfully created, false otherwise.
--
function Teleporter:AddSave()
    if not inMainThread() then
        synchronize(function() self:AddSave() end)
        return
    end
    return self:CreateSaveFromCurrentPosition()
end
registerLuaFunctionHighlight('AddSave')

--
--- ∑ Deletes an existing save by name and persists changes.
--- @param saveName string # The name of the save to delete. If nil, the currently selected save will be used. If still nil, the user will be prompted to enter a name.
--- @returns # true if the save was successfully deleted, false otherwise.
--
function Teleporter:DeleteSave(saveName)
    if not inMainThread() then
        synchronize(function() self:DeleteSave(saveName) end)
        return
    end
    local name = saveName or self:GetSelectedSaveName() or inputQuery("Delete Save", "Enter a name for the save to delete:", "")
    if not validateName(name, "Delete") then
        return false
    end
    local saveKey, reason = self:ResolveSaveKey(name)
    if not saveKey then
        logger:WarningF(MODULE_PREFIX .. " Save Not Found: '%s' (%s).", tostring(name), tostring(reason))
        return false
    end
    local displayName = self:GetSaveDisplayName(self.Saves[saveKey], saveKey)
    local confirmed = messageDialog("Delete save '" .. saveKey .. "'?", mtConfirmation, mbYes, mbNo)
    if confirmed ~= mrYes then
        return false
    end
    self.Saves[saveKey] = nil
    logger:InfoF(MODULE_PREFIX .. " Deleted Save: '%s'.", saveKey)
    return self:_CommitSaveChange(nil, "Save deleted: " .. displayName)
end

--
--- ∑ Renames an existing save to a new name and persists changes.
--- @param oldName string # The current name of the save to rename. If nil, the currently selected save will be used.
--- @param newName string # The new name for the save. If nil, the user will be prompted to enter a new name.
--- @returns # true if the save was successfully renamed, false otherwise.
--
function Teleporter:RenameSave(oldName, newName)
    if not inMainThread() then
        synchronize(function() self:RenameSave(oldName, newName) end)
        return
    end
    local sourceInput = oldName or self:GetSelectedSaveName()
    if not validateName(sourceInput, "Old") then
        return false
    end
    local sourceKey, reason = self:ResolveSaveKey(sourceInput)
    if not sourceKey then
        logger:ErrorF(MODULE_PREFIX .. " Save Not Found for rename: '%s' (%s).", tostring(sourceInput), tostring(reason))
        return false
    end
    local save = self.Saves[sourceKey]
    local sourceName = self:GetSaveDisplayName(save, sourceKey)
    local targetName = newName or inputQuery("Rename Save", "Enter a new name:", sourceName)
    if not validateName(targetName, "New") then
        return false
    end
    -- Renaming only touches the display name. The category half of the key stays put.
    local targetKey = self:MakeSaveKey(self:GetSaveCategoryPath(save, true), targetName)
    if not targetKey then
        logger:Error(MODULE_PREFIX .. " Invalid new save name.")
        return false
    end
    if sourceKey ~= targetKey and self.Saves[targetKey] then
        logger:ErrorF(MODULE_PREFIX .. " Save Name Already Exists In That Category: '%s'.", targetKey)
        return false
    end
    save.Name = trimString(targetName)
    self.Saves[targetKey] = save
    if targetKey ~= sourceKey then
        self.Saves[sourceKey] = nil
    end
    logger:InfoF(MODULE_PREFIX .. " Renamed Save: '%s' to '%s'.", sourceKey, targetKey)
    return self:_CommitSaveChange(targetKey,
        string.format("Renamed '%s' -> '%s'", sourceName, save.Name))
end

--
--- ∑ Duplicates the currently selected save with a new unique name and persists it.
--- @returns # true if the save was successfully duplicated, false otherwise.
--
function Teleporter:DuplicateSelectedSave()
    local sourceKey = self:GetSelectedSaveName()
    if not sourceKey or not self.Saves or type(self.Saves[sourceKey]) ~= "table" then
        logger:Warning(MODULE_PREFIX .. " No valid save selected for duplication.")
        return false
    end
    local src = self.Saves[sourceKey]
    local categoryPath = self:GetSaveCategoryPath(src, false)
    local newName = self:GenerateUniqueCopyName(self:GetSaveDisplayName(src, sourceKey), categoryPath)
    local copiedSave = {
        Name = newName,
        Author = src.Author or self:GetCurrentAuthor(),
        Description = src.Description or "",
    }
    for _, axis in ipairs(self:GetAxes()) do
        copiedSave[axis] = src[axis]
    end
    self:SetSaveCategoryPath(copiedSave, categoryPath)
    local newKey = self:GetSaveKey(copiedSave)
    self.Saves[newKey] = copiedSave
    logger:InfoF(MODULE_PREFIX .. " Duplicated save '%s' as '%s'.", sourceKey, newKey)
    return self:_CommitSaveChange(newKey, "Save duplicated: " .. newName)
end

--
--- ∑ Updates the currently selected save with values from the editor and persists changes.
--- @returns # true if the save was successfully updated, false otherwise.
--
function Teleporter:UpdateSelectedSaveFromEditor()
    local ui = self:EnsureUiState()
    local oldKey = self:GetSelectedSaveName() or self:ResolveSaveKey(ui.NameEdit.Text)
    local newName = ui.NameEdit.Text
    local position = self:TryGetEditorPosition()
    if not validateName(newName, "Save") then
        return false
    end
    if not position then
        logger:Warning(MODULE_PREFIX .. " Invalid input for update.")
        return false
    end
    if not oldKey or type(self.Saves) ~= "table" or type(self.Saves[oldKey]) ~= "table" then
        logger:WarningF(MODULE_PREFIX .. " Update failed: Save '%s' does not exist.", tostring(oldKey))
        return false
    end
    -- The key is derived from category path + name, so editing either one rekeys the save.
    local newKey = self:MakeSaveKey(ui.CategoryEdit.Text or "", newName)
    if not newKey then
        logger:Error(MODULE_PREFIX .. " Update failed: Invalid save name.")
        return false
    end
    if oldKey ~= newKey and self.Saves[newKey] then
        logger:WarningF(MODULE_PREFIX .. " Update failed: '%s' already exists.", newKey)
        return false
    end
    local save = self.Saves[oldKey]
    save.Name = trimString(newName)
    self:PositionToSave(save, position)
    save.Author = ui.AuthorEdit.Text ~= "" and ui.AuthorEdit.Text or self:GetCurrentAuthor()
    self:SetSaveCategoryPath(save, ui.CategoryEdit.Text or "")
    save.Description = ui.DescriptionEdit.Lines.Text or ""
    if oldKey ~= newKey then
        self.Saves[newKey] = save
        self.Saves[oldKey] = nil
    end
    logger:InfoF(MODULE_PREFIX .. " Save '%s' updated.", newKey)
    return self:_CommitSaveChange(newKey, "Save updated: " .. save.Name)
end

--
--- ∑ Registers the six controls a field row is made of under one name, so the
---   editor can reach any of them as ui.NameEdit, ui.XBorder and so on, and
---   Manifold.UI can theme a row it was never told about by name.
--- @param ui table # The UI state.
--- @param key string # Field name, for example "Name" or "X".
--
local function registerFieldRow(ui, key, edit, row, label, border, fill, inner)
    ui[key .. "Edit"], ui[key .. "Row"], ui[key .. "Label"] = edit, row, label
    ui[key .. "Border"], ui[key .. "Fill"], ui[key .. "Inner"] = border, fill, inner
end

--
--- ∑ Wraps an action so it only runs when a save is selected. Both menus are
---   built out of these, and neither should do anything on an empty tree.
--- @param teleporter table # The Teleporter instance.
--- @param action function # fn(saveKey)
--- @return function
--
local function onSelectedSave(teleporter, action)
    return function()
        local name = teleporter:GetSelectedSaveName()
        if name then action(name) end
    end
end

--
--- ∑ Builds a menu from a flat spec.
---   A caption of "-" is a separator, which is what Cheat Engine's menu items
---   call a bare dash, and a nil handler leaves the item inert.
--- @param owner table # The menu the items belong to.
--- @param root table # The item or Items collection they are added to.
--- @param entries table # Array of { caption, handler } pairs.
--
local function addMenuItems(owner, root, entries)
    for _, entry in ipairs(entries) do
        if entry then
            local item = createMenuItem(owner)
            item.Caption = entry[1]
            item.OnClick = entry[2]
            root.add(item)
        end
    end
end

local BUILD_THEME = {
    COLOR_BG           = 0x202020,
    COLOR_PANEL        = 0x2A2A2A,
    COLOR_ACCENT       = 0x4A4A4A,
    COLOR_TEXT         = 0xEAEAEA,
    COLOR_LABEL        = 0xC8C8C8,
    COLOR_BTN          = 0x2A2A2A,
    COLOR_BTN_HOVER    = 0x4A4A4A,
    COLOR_BTN_TEXT     = 0xEAEAEA,
    COLOR_TAB_ACTIVE   = 0x4A4A4A,
    COLOR_TAB_INACTIVE = 0x2A2A2A,
    COLOR_INPUT        = 0x1B1B1B,
    COLOR_INPUT_TEXT   = 0xEAEAEA,
    COLOR_BORDER       = 0x454545,
    COLOR_MUTED        = 0x8A8A8A,
    COLOR_SURFACE      = 0x2F2F2F,
    COLOR_SURFACE_ALT  = 0x242424,
    COLOR_SUCCESS      = 0x6FD96F,
}

--
--- ∑ Applies the given theme data to the Teleporter UI by delegating to the UI module.
--- @param themeData table # The processed theme token table.
--
function Teleporter:OnThemeApplied(themeData)
    local uiState = self:EnsureUiState()
    if not uiState or not uiState.Form then
        return
    end
    if _G.ui and type(ui.ApplyThemeToTeleporter) == "function" then
        ui:ApplyThemeToTeleporter(self, themeData)
    end
end

--
--- ∑ Creates the main menu strip for the Teleporter UI, populating it with "File", "Saves", and "Tools" menus and their respective items.
--- Each menu item is associated with a handler function that performs the corresponding action when clicked.
--- @param parent table # The parent control to which the menu strip will be added.
--
function Teleporter:CreateMenuStrip(parent)
    local menu = createMainMenu(parent)
    parent.Menu = menu
    local hasWaypoint = self.Waypoint and trimString(self.Waypoint.Symbol) ~= ""
    local menus = {
        { "&File", {
            { "Load Saves", function()
                self:SaveLookup()
                self:RefreshUi(true)
                self:SetStatus("Saves loaded")
            end },
            { "Save To DataDir", function()
                self:WriteSavesToDataDir()
                self:SetStatus("Saved to DataDir")
            end },
            { "Save To TableFile", function()
                self:WriteSavesToTableFile()
                self:SetStatus("Saved to TableFile")
            end },
            { "-" },
            { "Close", function()
                if self.UiState and self.UiState.Form then self.UiState.Form.close() end
            end },
        } },
        { "&Saves", {
            { "Add Current Position", function() self:AddSave() end },
            { "Update Selected",      function() self:UpdateSelectedSaveFromEditor() end },
            { "Duplicate Selected",   function() self:DuplicateSelectedSave() end },
            { "Rename Selected",      function() self:RenameSave() end },
            { "Delete Selected",      function() self:DeleteSave() end },
        } },
        { "&Tools", {
            { "Teleport To Selected Save",
              onSelectedSave(self, function(name) self:TeleportToSave(name) end) },
            -- Only offered when the table actually has a waypoint symbol.
            hasWaypoint and { "Teleport To Waypoint", function() self:TeleportToWaypoint() end } or false,
            { "Save Current Runtime Position", function()
                self:SaveCurrentPosition()
                self:SetStatus("Runtime position saved")
            end },
            { "Load Runtime Position", function() self:LoadSavedPosition() end },
        } },
    }
    for _, entry in ipairs(menus) do
        local top = createMenuItem(menu)
        top.Caption = entry[1]
        menu.Items.add(top)
        addMenuItems(menu, top, entry[2])
    end
end

--
--- ∑ Creates the header panel for the Teleporter UI, containing buttons for adding, duplicating, deleting, teleporting to, and updating saves.
--- Each button is associated with a handler function that performs the corresponding action when clicked.
--- @param parent table # The parent control to which the header panel will be added.
--- @returns table # The header panel containing the action buttons.
--
function Teleporter:CreateHeader(parent)
    local ui = self:EnsureUiState()
    local theme = BUILD_THEME
    local header = forms:CreatePanel(parent, {
        align = "alTop", height = 30, color = theme.COLOR_PANEL, role = "panel",
        bevelOuter = "bvNone",
        borderSpacing = { Left = 6, Right = 6, Top = 6, Bottom = 3 },
    })
    local buttons = forms:CreatePanel(header, {
        align = "alClient", color = theme.COLOR_PANEL, role = "panel",
    })
    -- Left to right, in creation order. ButtonKeys is what the theming walks,
    -- so a button added here needs no second edit anywhere else.
    local toolbar = {
        { "Add",       "Add Current", 108, function() self:AddSave() end },
        { "Duplicate", "Duplicate",    92, function() self:DuplicateSelectedSave() end },
        { "Delete",    "Delete",       80, function() self:DeleteSave() end },
        { "Teleport",  "Teleport",     86, function()
            local name = self:GetSelectedSaveName()
            if name then self:TeleportToSave(name) end
        end },
        { "Update",    "Update",       84, function() self:UpdateSelectedSaveFromEditor() end },
    }
    ui.ButtonKeys = ui.ButtonKeys or {}
    for _, entry in ipairs(toolbar) do
        local key, caption, width, handler = entry[1], entry[2], entry[3], entry[4]
        ui[key .. "Button"] = forms:CreateButton(buttons, {
            caption = caption, width = width, theme = theme, onClick = handler,
        })
        ui.ButtonKeys[#ui.ButtonKeys + 1] = key .. "Button"
    end
    ui.ToolbarPanel = header
    return header
end

--
--- ∑ Creates the status bar panel for the Teleporter UI, containing a label to display status messages to the user.
--- The status bar is styled according to the current UI theme and provides a method for updating the displayed status message.
--- @param parent table # The parent control to which the status bar will be added.
--- @returns table # The status bar panel containing the status label.
--
function Teleporter:CreateStatusBar(parent)
    local ui = self:EnsureUiState()
    local theme = BUILD_THEME
    ui.StatusPanel = forms:CreatePanel(parent, {
        align = "alBottom", height = 26, color = theme.COLOR_BORDER, role = "border",
        bevelOuter = "bvNone", borderSpacing = { Around = 6 },
    })
    ui.StatusInnerPanel = forms:CreatePanel(ui.StatusPanel, {
        align = "alClient", color = theme.COLOR_PANEL, role = "panel",
        bevelOuter = "bvNone", borderSpacing = { Around = 1 },
    })
    ui.StatusLabel = forms:CreateLabel(ui.StatusInnerPanel, {
        align = "alLeft", caption = "Ready", theme = theme, role = "label",
        borderSpacing = { Left = 8, Top = 3 },
    })
    forms:ApplyFont(ui.StatusLabel, theme.COLOR_TEXT, 10)
    return ui.StatusPanel
end

--
--- ∑ Creates the main tree view panel for displaying saved locations, including a search box for filtering saves and a label showing the count of saves.
--- The tree view allows users to select saves, which will load the save details into the editor, and supports double-clicking to teleport to the selected save.
--- @param parent table # The parent control to which the tree panel will be added.
--- @returns table # The outer panel containing the tree view and related controls.
--
function Teleporter:CreateTreePanel(parent)
    local theme = BUILD_THEME
    local ui = self:EnsureUiState()
    ui.LeftPanel, ui.LeftInnerPanel, ui.LeftHeaderPanel, ui.LeftContentPanel, ui.TreeHeaderLabel =
        forms:CreateCard(parent, {
            align = "alClient", size = 330, theme = theme, title = "SAVED LOCATIONS",
            width = 530,
        })
    ui.TreePanel = ui.LeftPanel
    ui.TreeStatsLabel = forms:CreateLabel(ui.LeftHeaderPanel, {
        align = "alRight", caption = string.format("%d saves", self:CountSaves()),
        theme = theme, role = "mutedLabel", fontSize = 9, transparent = true,
        borderSpacing = { Right = 8, Top = 4 },
    })
    forms:ApplyFont(ui.TreeStatsLabel, theme.COLOR_MUTED, 9)
    -- Search box. Border, fill and inner are the same three panel nest a field
    -- row uses, kept apart here because this one carries no label.
    ui.SearchPanel = forms:CreatePanel(ui.LeftContentPanel, {
        align = "alTop", height = 32, color = theme.COLOR_BORDER, role = "border",
        bevelOuter = "bvRaised", bevelWidth = 1, bevelColor = theme.COLOR_BORDER,
        borderSpacing = { Bottom = 6 },
    })
    ui.SearchFillPanel = forms:CreatePanel(ui.SearchPanel, {
        align = "alClient", color = theme.COLOR_INPUT, role = "inputPanel",
        borderSpacing = { Around = 1 },
    })
    ui.SearchInnerPanel = forms:CreatePanel(ui.SearchFillPanel, {
        align = "alClient", color = theme.COLOR_INPUT, role = "inputPanel",
        borderSpacing = { Left = 8, Right = 8, Top = 4 },
    })
    ui.SearchEdit = forms:CreateTextBox(ui.SearchInnerPanel, {
        align = "alClient", parentColor = false, color = theme.COLOR_INPUT,
        borderStyle = "bsNone", theme = theme, role = "input",
        textHint = "Search saves...",
    })
    ui.SearchEdit.OnChange = function() self:RefreshUi(true) end

    ui.TreeBorderPanel = forms:CreatePanel(ui.LeftContentPanel, {
        align = "alClient", color = theme.COLOR_BORDER, role = "border",
        bevelOuter = "bvRaised", bevelWidth = 1, bevelColor = theme.COLOR_BORDER,
    })
    ui.TreeHostPanel = forms:CreatePanel(ui.TreeBorderPanel, {
        align = "alClient", color = theme.COLOR_PANEL, role = "panel",
        borderSpacing = { Around = 1 },
    })
    local tree = forms:CreateTreeView(ui.TreeHostPanel, {
        align = "alClient", readOnly = true, autoExpand = true,
        borderStyle = "bsNone", scrollBars = "ssAutoBoth", role = "tree",
    })
    forms:ApplyFont(tree, theme.COLOR_INPUT_TEXT, 10)
    ui.TreeView = tree
    -- Single click selects and loads, double click jumps.
    local function onNode(action)
        return function()
            local saveKey = self:GetSaveKeyFromTreeNode(tree.Selected)
            if saveKey then
                self:SetSelectedSaveName(saveKey)
                action(saveKey)
            end
        end
    end
    tree.OnClick = onNode(function(saveKey)
        self:LoadSaveIntoEditor(saveKey)
        self:SetStatus("Selected: " .. saveKey)
    end)
    tree.OnDblClick = onNode(function(saveKey) self:TeleportToSave(saveKey) end)
    return ui.LeftPanel
end

--
--- ∑ Creates the editor panel for viewing and editing the details of a selected save, including fields for name, author, category, position, and description.
--- The editor allows users to modify the save details and update the save, as well as fill the fields with the current in-game position.
--- @param parent table # The parent control to which the editor panel will be added.
--- @returns table # The outer panel containing the editor controls.
--
function Teleporter:CreateEditorPanel(parent)
    local theme = BUILD_THEME
    local ui = self:EnsureUiState()
    ui.RightPanel, ui.RightInnerPanel, ui.RightHeaderPanel, ui.RightContentPanel,
        ui.EditorHeaderLabel = forms:CreateCard(parent, {
            align = "alClient", theme = theme, title = "SAVE EDITOR",
        })
    ui.EditorPanel = ui.RightPanel
    local content = ui.RightContentPanel
    ui.FooterPanel = forms:CreatePanel(content, {
        align = "alBottom", height = 36, color = theme.COLOR_PANEL, role = "panel",
        bevelOuter = "bvLowered", bevelWidth = 1, bevelColor = theme.COLOR_BORDER,
        borderSpacing = { Top = 6 },
    })
    ui.ButtonKeys = ui.ButtonKeys or {}
    local footerButtons = {
        { "Clear",              "Clear",                72, function()
            self:ClearEditor()
            self:SetStatus("Editor cleared")
        end },
        { "Rename",             "Rename",               84, function() self:RenameSave() end },
        { "UseCurrentPosition", "Use Current Position", 148, function()
            local pos = self:GetCurrentPosition()
            if not pos then return end
            for index, axis in ipairs(self:GetAxes()) do
                local edit = ui[axis .. "Edit"]
                if edit then edit.Text = tostring(pos[index]) end
            end
            self:SetStatus("Editor filled with current position")
        end },
    }
    for _, entry in ipairs(footerButtons) do
        ui[entry[1] .. "Button"] = forms:CreateButton(ui.FooterPanel, {
            caption = entry[2], width = entry[3], theme = theme, onClick = entry[4],
        })
        ui.ButtonKeys[#ui.ButtonKeys + 1] = entry[1] .. "Button"
    end
    ui.MemoBorderPanel = forms:CreatePanel(content, {
        align = "alClient", color = theme.COLOR_BORDER, role = "border",
        bevelOuter = "bvRaised", bevelWidth = 1, bevelColor = theme.COLOR_BORDER,
        borderSpacing = { Top = 6, Bottom = 6 },
    })
    ui.DescriptionEdit, ui.MemoPanel, ui.MemoInnerPanel =
        forms:CreateMemoFrame(ui.MemoBorderPanel, {
            theme = theme, align = "alClient",
            borderSpacing = { Around = 1 },
            innerSpacing = { Left = 6, Right = 6, Top = 6, Bottom = 6 },
        })
    -- The coordinate group is sized from the number of axes rather than fixed
    -- at three rows, so a 2D table gets a shorter panel and the description
    -- box below it grows into the space instead of leaving a gap.
    local axes = self:GetAxes()
    local ROW_HEIGHT = 40
    local coordinateHeight = math.max(ROW_HEIGHT, #axes * ROW_HEIGHT - 2)
    local identityHeight = 3 * ROW_HEIGHT - 2
    ui.FieldsHostPanel = forms:CreatePanel(content, {
        align = "alTop", height = identityHeight + coordinateHeight + 8,
        color = theme.COLOR_PANEL, role = "panel",
    })
    ui.BottomGroupPanel = forms:CreatePanel(ui.FieldsHostPanel, {
        align = "alTop", height = coordinateHeight, color = theme.COLOR_PANEL, role = "panel",
    })
    ui.TopGroupPanel = forms:CreatePanel(ui.FieldsHostPanel, {
        align = "alTop", height = identityHeight, color = theme.COLOR_PANEL, role = "panel",
    })
    -- Every row is built the same way, identity and coordinates alike, and
    -- registers its six controls under its own name.
    --
    -- Both groups are built back to front. These are alTop rows and a control
    -- created later ends up above the ones before it, so the reversed order
    -- leaves them on screen as listed here.
    local identityRows = {
        { "Name",     { caption = "Name" } },
        { "Author",   { caption = "Author" } },
        { "Category", { caption = "Category Path", labelWidth = 108,
                        textHint = "World / Region / Room" } },
    }
    local function buildRows(parentPanel, rows)
        for index = #rows, 1, -1 do
            local key, options = rows[index][1], rows[index][2]
            options.theme = theme
            registerFieldRow(ui, key, forms:CreateFieldRow(parentPanel, options))
        end
    end
    buildRows(ui.TopGroupPanel, identityRows)
    local coordinateRows = {}
    for index, axis in ipairs(axes) do
        coordinateRows[index] = { axis, { caption = axis } }
    end
    buildRows(ui.BottomGroupPanel, coordinateRows)
    ui.AxisFieldKeys = axes
    return ui.RightPanel
end

-- ∑ Creates the context menu for the tree view, providing options to teleport to a save, load it into the editor, update it from the editor, duplicate it, rename it, or delete it.
--- @returns table # The context menu.
function Teleporter:CreateTreeContextMenu()
    local ui = self:EnsureUiState()
    if not ui.TreeView then
        return
    end
    local menu = createPopupMenu(ui.TreeView)
    ui.TreeView.PopupMenu = menu
    addMenuItems(menu, menu.Items, {
        { "Teleport",           onSelectedSave(self, function(name) self:TeleportToSave(name) end) },
        { "Load Into Editor",   onSelectedSave(self, function(name) self:LoadSaveIntoEditor(name) end) },
        { "Update From Editor", function() self:UpdateSelectedSaveFromEditor() end },
        { "Duplicate",          function() self:DuplicateSelectedSave() end },
        { "Rename",             function() self:RenameSave() end },
        { "Delete",             function() self:DeleteSave() end },
    })
end

--
--- ∑ Ensures all saves have an Author field.
--
function Teleporter:EnsureAuthorsAndCategories()
    if type(self.Saves) ~= "table" then
        return 0
    end
    local entries, migrated, needsRekey = {}, 0, false
    for key, data in pairs(self.Saves) do
        local newKey = key
        if type(data) == "table" then
            data.Author = data.Author or self:GetCurrentAuthor()
            data.Category = data.Category or ""
            self:SetSaveCategoryPath(data, self:GetSaveCategoryPath(data, false))
            data.Description = data.Description or ""
            if trimString(data.Name) == "" then
                -- Legacy entry: the key doubled as the display name before path keys existed.
                data.Name = trimString(key)
                migrated = migrated + 1
            end
            newKey = self:GetSaveKey(data) or key
        end
        if newKey ~= key then
            needsRekey = true
        end
        entries[#entries + 1] = { OldKey = key, NewKey = newKey, Data = data }
    end
    if not needsRekey then
        return migrated
    end
    -- Rebuild under the new keys. Sorted so any collision suffix lands deterministically.
    table.sort(entries, function(a, b)
        return tostring(a.OldKey):lower() < tostring(b.OldKey):lower()
    end)
    local rebuilt, collisions = {}, 0
    for _, entry in ipairs(entries) do
        local key = entry.NewKey
        if rebuilt[key] ~= nil and type(entry.Data) == "table" then
            local baseName = self:GetSaveDisplayName(entry.Data, entry.OldKey)
            local categoryPath = self:GetSaveCategoryPath(entry.Data, true)
            local suffix, candidateName, candidateKey = 2, nil, nil
            repeat
                candidateName = string.format("%s (%d)", baseName, suffix)
                candidateKey = self:MakeSaveKey(categoryPath, candidateName)
                suffix = suffix + 1
            until rebuilt[candidateKey] == nil or suffix > 999
            entry.Data.Name = candidateName
            key = candidateKey
            collisions = collisions + 1
        end
        rebuilt[key] = entry.Data
    end
    self.Saves = rebuilt
    if migrated > 0 then
        logger:InfoF(MODULE_PREFIX .. " Migrated %d save(s) to category path keys.", migrated)
    end
    if collisions > 0 then
        logger:WarningF(MODULE_PREFIX .. " Renamed %d save(s) that collided inside their own category.", collisions)
    end
    return migrated
end

--
--- ∑ Gets a table of save authors.
--- @returns table # A table mapping save names to their respective authors.
--
function Teleporter:GetAuthors()
    local authors = {}
    for name, save in pairs(self.Saves or {}) do
        if type(save) == "table" then
            authors[name] = save.Author or "Unknown"
        else
            authors[name] = "Unknown"
        end
    end
    return authors
end

--
--- ∑ Initializes the Teleporter UI, synchronizing if necessary.
--- If the UI already exists, it will be shown and brought to the front. Otherwise, a new UI will be created with the appropriate theme and controls.
--- @returns table # The form representing the Teleporter UI.
--
function Teleporter:InitTeleporterUI()
    if not inMainThread() then
        synchronize(function() self:InitTeleporterUI() end)
        return
    end
    local uiState = self:EnsureUiState()
    if uiState.Form and uiState.Form.ClassName and uiState.Form.ClassName ~= "" then
        uiState.Form.show()
        uiState.Form.bringToFront()
        self:RefreshUi(true)
        return uiState.Form
    end
    local theme = BUILD_THEME
    local form = forms:CreateForm({
        caption = "[Manifold] Teleporter",
        width = 1120,
        height = 720,
        position = "poScreenCenter",
        role = "form",
        borderStyle = "bsSizeable",
        constraints = { MinWidth = 980, MinHeight = 620 },
    })
    form.Font.Name = "Consolas"
    form.Font.Size = 10
    form.show()
    uiState.Form = form
    self:CreateMenuStrip(form)
    -- Three nested backgrounds: the whole client area, then the part below the
    -- toolbar and above the status bar, then the two halves either side of the
    -- splitter. The tree is alLeft and the editor takes what is left.
    local function background(parent, opts)
        opts.color, opts.role = theme.COLOR_BG, "background"
        return forms:CreatePanel(parent, opts)
    end
    uiState.RootPanel = background(form, { align = "alClient" })
    self:CreateStatusBar(uiState.RootPanel)
    self:CreateHeader(uiState.RootPanel)
    uiState.BodyPanel = background(uiState.RootPanel, {
        align = "alClient", borderSpacing = { Left = 6, Right = 6, Bottom = 6 },
    })
    uiState.EditorHost = background(uiState.BodyPanel, {
        align = "alClient", width = form.Width / 2, constraints = { MinWidth = 400 },
    })
    local splitter = createSplitter(uiState.BodyPanel)
    uiState.Splitter = splitter
    splitter.Align = "alLeft"
    splitter.Width = 6
    splitter.MinSize = 250
    splitter.ResizeStyle = "rsUpdate"
    uiState.TreeHost = background(uiState.BodyPanel, {
        align = "alLeft", width = form.Width / 2, constraints = { MinWidth = 250 },
    })
    self:CreateEditorPanel(uiState.EditorHost)
    self:CreateTreePanel(uiState.TreeHost)
    self:CreateTreeContextMenu()
    form.OnClose = function()
        self:SetStatus("Closed")
        self.UiState = nil
        return caFree
    end
    self:SaveLookup()
    self:RefreshUi(true)
    self:ClearEditor()
    self:SetStatus("Teleporter ready")
    form.centerScreen()
    -- Adopt the cheat table's theme if one is loaded. The window is built in
    -- BUILD_THEME either way, so it is never unstyled while this is decided.
    if _G.ui and type(ui.ApplyThemeToTeleporter) == "function" then
        local ok, activeTheme = pcall(function()
            if type(ui.GetActiveThemeData) == "function" then
                return ui:GetActiveThemeData()
            elseif type(ui.GetTheme) == "function" and ui.ActiveTheme then
                return ui:GetTheme(ui.ActiveTheme)
            end
        end)
        if ok and type(activeTheme) == "table" then
            ui:ApplyThemeToTeleporter(self, activeTheme)
        end
    end
    return form
end
registerLuaFunctionHighlight('InitTeleporterUI')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Teleporter
