--[[
    Settings, with the three the menu can change persisted.

    The 1.x utility kept "Animate Caption", the speed and "Confirm Destructive
    Actions" for the session only; a permanent change meant editing the file.
    Cheat Engine's getSettings() hands any script a registry-backed store, so
    those three now survive a restart. Everything else stays a default in
    this file, overridable from the entry point, because a shortcut or a
    colour is a decision made once by whoever installs the tool.

    Values are stored as strings and decoded against the type of the
    default, so a hand-edited or damaged registry value falls back to the
    default instead of turning a boolean into the string "0".
]]

local Settings = {}
Settings.__index = Settings

Settings.RegistryPath = "Manifold CE Utility"

--- The keys that are written to and read from the registry. A dotted key
--- reaches into a nested table; the dot is a legal registry value name.
Settings.Persisted = {
    "AnimatedCaption",
    "AnimationInterval",
    "ConfirmDestructiveActions",
    "Structures.IncludeUnnamed"
}

Settings.Defaults = {
    MenuCaption = "Manifold",
    Prefix = "[— ",
    Suffix = " —]",
    AnimatedCaption = false,
    AnimationInterval = 350,
    MinAnimationInterval = 100,
    MaxAnimationInterval = 2000,
    ConfirmDestructiveActions = true,
    Persist = true,
    Shortcuts = {
        LuaEngine = "Ctrl+L",
        MemoryViewer = "",
        DeactivateScripts = "Ctrl+D",
        DeactivateEverything = "Ctrl+F",
        CompactMode = "Ctrl+Shift+F"
    },
    Structures = {
        -- Cheat Engine colours are BGR.
        HeaderColor = 0xD2FF00,
        ElementColor = 0xADAD5A,
        PointerColor = 0x61CDEA,
        -- How many levels of nested structures are expanded below the root. Past
        -- this a pointer becomes a plain hex value naming its target.
        MaxDepth = 4,
        -- Structure Dissect creates an element per offset, and on a structure
        -- of a few thousand bytes almost none of them carry a name. Off, only
        -- the elements labelled in the dissect window become records, plus any
        -- unlabelled container holding one. On, every element does.
        IncludeUnnamed = false,
        -- "[0004] — health" rather than "health".
        OffsetInDescription = true,
        -- What the base address dialog offers when no dissect window for
        -- the structure is open. "+0" makes a relative block that can be
        -- dropped under any pointer record.
        DefaultBase = "+0"
    }
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local made = {}
    for key, item in pairs(value) do made[key] = copy(item) end
    return made
end

local function merge(into, from)
    if type(from) ~= "table" then return end
    for key, value in pairs(from) do
        if type(value) == "table" and type(into[key]) == "table" then
            merge(into[key], value)
        else
            into[key] = copy(value)
        end
    end
end

--
--- ∑ Builds the settings: defaults, then the entry point's overrides, then
---   whatever the registry remembers for the persisted keys.
--- @param options table|nil # { Overrides, Persist }
--- @return table
--
function Settings:New(options)
    options = options or {}
    local instance = setmetatable(copy(Settings.Defaults), Settings)
    merge(instance, options.Overrides)
    if options.Persist ~= nil then instance.Persist = options.Persist end
    instance.AnimationInterval = instance:ClampInterval(instance.AnimationInterval)
    instance:Load()
    return instance
end

--
--- ∑ Keeps an interval inside the bounds a caption ticker is usable at.
--- @param value any
--- @return number
--
function Settings:ClampInterval(value)
    local number = tonumber(value) or Settings.Defaults.AnimationInterval
    number = math.floor(number)
    if number < self.MinAnimationInterval then return self.MinAnimationInterval end
    if number > self.MaxAnimationInterval then return self.MaxAnimationInterval end
    return number
end

--
--- ∑ The registry store, or nil when Cheat Engine cannot provide one.
--- @return userdata|table|nil
--
function Settings:Store()
    local get = rawget(_G, "getSettings")
    if type(get) ~= "function" then return nil end
    local ok, store = pcall(get, Settings.RegistryPath)
    if ok and store ~= nil then return store end
    return nil
end

local function encode(value)
    if type(value) == "boolean" then return value and "1" or "0" end
    return tostring(value)
end

local function decode(raw, like)
    -- Cheat Engine's store answers "" for a value that was never written,
    -- never nil. Both mean absent; encode never produces "".
    if raw == nil or raw == "" then return nil end
    if type(like) == "boolean" then
        if raw == true or raw == false then return raw end
        return raw == "1" or raw == "true"
    end
    if type(like) == "number" then return tonumber(raw) end
    return raw
end

--
--- ∑ Walks a dotted key. Returns the table holding the last segment and that
---   segment, so reading and writing share one resolution.
--- @param root table
--- @param key string
--- @return table|nil, string|nil
--
local function resolve(root, key)
    local holder = root
    for segment in key:gmatch("([^.]+)%.") do
        holder = holder[segment]
        if type(holder) ~= "table" then return nil end
    end
    return holder, key:match("([^.]+)$")
end

local function readKey(root, key)
    local holder, name = resolve(root, key)
    if not holder then return nil end
    return holder[name]
end

local function writeKey(root, key, value)
    local holder, name = resolve(root, key)
    if holder then holder[name] = value end
end

local function isPersisted(key)
    for _, name in ipairs(Settings.Persisted) do
        if name == key then return true end
    end
    return false
end

--
--- ∑ Reads the persisted keys. A value that does not decode against its
---   default is ignored, so a damaged registry cannot produce a nonsense
---   interval or a non-boolean flag.
--- @return boolean # Whether a store was available.
--
function Settings:Load()
    if not self.Persist then return false end
    local store = self:Store()
    if not store then return false end
    for _, key in ipairs(Settings.Persisted) do
        local okRead, raw = pcall(function() return store.Value[key] end)
        if okRead then
            local value = decode(raw, readKey(Settings.Defaults, key))
            if value ~= nil then
                if key == "AnimationInterval" then value = self:ClampInterval(value) end
                writeKey(self, key, value)
            end
        end
    end
    return true
end

--
--- ∑ Changes one setting and, for a persisted key, writes it through.
--- @param key string
--- @param value any
--- @return boolean # Whether the value reached the store. Non-persisted
---         keys report true: there was nothing to write.
--
function Settings:Set(key, value)
    if key == "AnimationInterval" then value = self:ClampInterval(value) end
    writeKey(self, key, value)
    if not self.Persist or not isPersisted(key) then return true end
    local store = self:Store()
    if not store then return false end
    return (pcall(function() store.Value[key] = encode(value) end)) == true
end

--
--- ∑ The values worth showing in a status report.
--- @return table
--
function Settings:Summary()
    return {
        AnimatedCaption = self.AnimatedCaption,
        AnimationInterval = self.AnimationInterval,
        ConfirmDestructiveActions = self.ConfirmDestructiveActions,
        IncludeUnnamed = self.Structures.IncludeUnnamed,
        Persist = self.Persist
    }
end

return Settings
