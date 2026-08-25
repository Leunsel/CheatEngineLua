--[[
    Configuration with schema versioning and migration.

    The JSON file written by 2.x (SchemaVersion 3) is read and migrated in
    place. A file with a NEWER schema than this build knows is loaded
    read-only and never overwritten, downgrading must not destroy a newer
    installation's settings. Saving always goes through an atomic write.
]]

local Config = {}
Config.__index = Config

Config.SchemaVersion = 4

local function deepCopy(source)
    if type(source) ~= "table" then return source end
    local copy = {}
    for key, value in pairs(source) do copy[key] = deepCopy(value) end
    return copy
end

--
--- Accepts only keys known to the defaults, with matching types. Unknown or
--- mistyped fields silently fall back to the default, so a corrupted file
--- can never break the loader.
--
local function mergeKnown(defaults, source)
    local merged = deepCopy(defaults)
    if type(source) ~= "table" then return merged end
    for key, defaultValue in pairs(defaults) do
        local candidate = source[key]
        if candidate ~= nil then
            if type(defaultValue) == "table" then
                merged[key] = mergeKnown(defaultValue, candidate)
            elseif type(candidate) == type(defaultValue) then
                merged[key] = candidate
            end
        end
    end
    return merged
end

Config.Defaults = {
    SchemaVersion = Config.SchemaVersion,
    Logger = {
        Level = "ERROR",
        LogToFile = true
    },
    InjectionInfo = {
        LineCount = 3,
        RemoveSpaces = true,
        AddTabs = true,
        AppendToHookName = "Hook"
    },
    Memory = {
        AskForHookName = true,
        AskForInjectionAddress = false,
        AllocationSize = "$1000",
        AllocationNear = true,
        DefaultHookName = "Injection"
    },
    Generation = {
        -- autoAssembleCheck runs custom AA commands (ManifoldScanModule does a
        -- real module scan) during its check, so output validation is opt-in.
        ValidateOutput = false,
        PreviewBeforeApply = false,
        WarnDeprecated = true
    },
    UI = {
        Favorites = {},
        Recent = {},
        RecentLimit = 8
    }
}

--
--- Migration steps. Migrations[n] upgrades a version-n file to n+1. Files
--- without a usable SchemaVersion are treated as pre-3 and merged against
--- the defaults first, which is exactly what 2.x did with them.
--
Config.Migrations = {
    [3] = function(data)
        -- v3 -> v4: Generation and UI sections are new. Existing fields are
        -- unchanged. A v3 file that stored the legacy CRITICAL log level maps
        -- onto FATAL.
        data.Generation = data.Generation or deepCopy(Config.Defaults.Generation)
        data.UI = data.UI or deepCopy(Config.Defaults.UI)
        if type(data.Logger) == "table" and data.Logger.Level == "CRITICAL" then
            data.Logger.Level = "FATAL"
        end
        data.SchemaVersion = 4
        return data
    end
}

local VALID_LEVELS = { TRACE = true, DEBUG = true, INFO = true, WARNING = true, ERROR = true, FATAL = true, NONE = true }

function Config:New(services)
    local instance = setmetatable({
        File = services.File,
        Json = services.Json,
        Log = services.Log,
        Paths = services.Paths,
        Data = deepCopy(Config.Defaults),
        ReadOnly = false,
        LoadedFrom = nil
    }, Config)
    return instance
end

function Config:_Decode(path)
    if not path or not self.File:Exists(path) then return nil end
    local source, readErr = self.File:ReadFile(path)
    if not source then
        self.Log:Error("[Config] Could not read configuration: " .. tostring(readErr))
        return nil
    end
    local ok, decoded = pcall(function() return self.Json:decode(source) end)
    if ok and type(decoded) == "table" then return decoded end
    -- Keep the broken file as evidence, then continue writable. The next
    -- settings change persists a clean file instead of silently failing for
    -- the whole session.
    self.Log:ForceError("[Config] Configuration file is invalid JSON. It was preserved as '"
        .. path .. ".invalid'. Defaults are used.")
    pcall(os.remove, path .. ".invalid")
    pcall(os.rename, path, path .. ".invalid")
    return nil
end

local function sanitizeStringList(value, limit)
    local list = {}
    if type(value) ~= "table" then return list end
    for _, entry in ipairs(value) do
        if type(entry) == "string" and entry ~= "" then
            list[#list + 1] = entry
            if limit and #list >= limit then break end
        end
    end
    return list
end

function Config:_Migrate(data)
    -- Captured from the RAW file before any merge. mergeKnown rebuilds
    -- list-shaped values from the (empty) defaults, so the pre-versioned
    -- branch below would otherwise destroy them, and then persist the loss.
    local rawUI = type(data.UI) == "table" and data.UI or {}
    local favorites = sanitizeStringList(rawUI.Favorites, 64)
    local recent = sanitizeStringList(rawUI.Recent, 32)
    local version = tonumber(data.SchemaVersion)
    if not version or version < 3 then
        -- Pre-versioned or 2.x-era file. Shape it against the defaults, then
        -- run the normal migration chain from 3.
        data = mergeKnown(Config.Defaults, data)
        data.SchemaVersion = 3
        version = 3
    end
    if version > Config.SchemaVersion then
        self.Log:ForceWarningF(
            "[Config] Configuration schema %d is newer than this loader supports (%d). Loading read-only. The file will not be modified.",
            version, Config.SchemaVersion)
        self.ReadOnly = true
        local merged = mergeKnown(Config.Defaults, data)
        merged.UI.Favorites, merged.UI.Recent = favorites, recent
        return merged
    end
    while version < Config.SchemaVersion do
        local migrate = Config.Migrations[version]
        if not migrate then break end
        local ok, migrated = pcall(migrate, data)
        if not ok or type(migrated) ~= "table" then
            self.Log:ForceError("[Config] Migration from schema " .. version .. " failed: " .. tostring(migrated))
            self.ReadOnly = true
            return mergeKnown(Config.Defaults, data)
        end
        data = migrated
        version = tonumber(data.SchemaVersion) or (version + 1)
        self.Log:InfoF("[Config] Configuration migrated to schema %d.", version)
    end
    local merged = mergeKnown(Config.Defaults, data)
    merged.UI.Favorites, merged.UI.Recent = favorites, recent
    return merged
end

function Config:_Normalize()
    local logger = self.Data.Logger
    logger.Level = type(logger.Level) == "string" and logger.Level:upper() or "ERROR"
    if not VALID_LEVELS[logger.Level] then logger.Level = "ERROR" end
    local injection = self.Data.InjectionInfo
    local count = tonumber(injection.LineCount)
    injection.LineCount = (count and count > 0 and count == math.floor(count)) and count
        or Config.Defaults.InjectionInfo.LineCount
    if type(injection.AppendToHookName) ~= "string" then
        injection.AppendToHookName = Config.Defaults.InjectionInfo.AppendToHookName
    end
    local memory = self.Data.Memory
    memory.AllocationSize = Config.NormalizeAllocationSize(memory.AllocationSize)
        or Config.Defaults.Memory.AllocationSize
    local hookName = type(memory.DefaultHookName) == "string"
        and memory.DefaultHookName:match("^%s*(.-)%s*$") or ""
    memory.DefaultHookName = hookName ~= "" and hookName or Config.Defaults.Memory.DefaultHookName
    local ui = self.Data.UI
    local limit = tonumber(ui.RecentLimit)
    ui.RecentLimit = (limit and limit >= 1 and limit <= 32) and math.floor(limit)
        or Config.Defaults.UI.RecentLimit
end

function Config:Load()
    self.ReadOnly = false
    local primaryPath = self.Paths.ConfigPath
    local primaryExists = self.File:Exists(primaryPath)
    local decoded = self:_Decode(primaryPath)
    local loadedFrom = decoded and primaryPath or nil
    if not decoded and self.Paths.LegacyConfigPath and self.Paths.LegacyConfigPath ~= primaryPath then
        decoded = self:_Decode(self.Paths.LegacyConfigPath)
        if decoded then loadedFrom = self.Paths.LegacyConfigPath end
    end
    -- The migration mutates the decoded table in place, so the on-disk
    -- schema must be captured BEFORE migrating to decide about persisting.
    local diskSchema = decoded and tonumber(decoded.SchemaVersion) or nil
    if decoded then
        self.Data = self:_Migrate(decoded)
    else
        self.Data = deepCopy(Config.Defaults)
    end
    self:_Normalize()
    self.LoadedFrom = loadedFrom
    -- Persist migrations and the move away from the legacy path, but never
    -- overwrite a file from a newer schema.
    if not self.ReadOnly and ((decoded and loadedFrom ~= primaryPath) or (not decoded and not primaryExists)
        or (decoded and diskSchema ~= Config.SchemaVersion)) then
        self:Save()
    end
    return self.Data
end

function Config:Save()
    if self.ReadOnly then
        self.Log:Warning("[Config] Configuration is read-only (newer or invalid file). Changes are not persisted.")
        return false
    end
    local ok, encoded = pcall(function() return self.Json:encode_pretty(self.Data) end)
    if not ok then
        self.Log:Error("[Config] Failed to encode configuration: " .. tostring(encoded))
        return false
    end
    local folderOk, folderErr = self.File:EnsureFolder(self.Paths.ConfigDir)
    if not folderOk then
        self.Log:Error("[Config] Failed to create configuration directory: " .. tostring(folderErr))
        return false
    end
    local saved, err = self.File:WriteFileAtomic(self.Paths.ConfigPath, encoded)
    if not saved then
        self.Log:Error("[Config] Failed to save configuration: " .. tostring(err))
        return false
    end
    return true
end

function Config:Reset()
    self.Data = deepCopy(Config.Defaults)
    self.ReadOnly = false
    self:_Normalize()
    return self:Save()
end

--
--- '$1000' / '4096' style allocation size. Returns the normalized string or
--- nil for anything that is not a positive decimal or $HEX value.
--
function Config.NormalizeAllocationSize(value)
    if type(value) == "number" then
        if value > 0 and value == math.floor(value) then
            return string.format("$%X", value)
        end
        return nil
    end
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    if value == "" then return nil end
    local hexValue = value:match("^%$[%x]+$") and tonumber(value:sub(2), 16)
    if hexValue and hexValue > 0 then return value:upper() end
    if value:match("^%d+$") and tonumber(value) > 0 then return value end
    return nil
end

--
--- The memory option set for one generation. Global defaults overlaid with
--- the template's own overrides.
--
function Config:GetMemoryOptions(overrides)
    local options = deepCopy(self.Data.Memory)
    options.AppendToHookName = self.Data.InjectionInfo.AppendToHookName
    -- An unparseable per-template override falls back to the user's
    -- configured global size, not to a hardcoded constant.
    local globalSize = Config.NormalizeAllocationSize(options.AllocationSize) or "$1000"
    for key, value in pairs(overrides or {}) do
        if value ~= nil then options[key] = value end
    end
    options.AllocationSize = Config.NormalizeAllocationSize(options.AllocationSize) or globalSize
    options.AppendToHookName = type(options.AppendToHookName) == "string" and options.AppendToHookName or "Hook"
    return options
end

return Config