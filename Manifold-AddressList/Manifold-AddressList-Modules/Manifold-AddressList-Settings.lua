--[[
    Everything the window remembers between sessions.

    Cheat Engine's getSettings() hands any script a registry backed store, so
    the window size, the split, the columns and the search flags survive a
    restart. Values go in as strings and come back decoded against the type of
    the default, so a hand edited or damaged registry value falls back to the
    default instead of turning a number into a string.

    Two Cheat Engine facts shape the whole file.

    A value that was never written reads back as an empty string, never as
    nil, so both of those mean absent. An empty string can therefore not be
    stored as itself, because it would read back as absent and the default
    would win. A setting the user deliberately emptied goes in as a marker
    instead and comes back out as the empty string.

    A dotted key reaches into a nested table and is stored under that name,
    dot included, because a dot is a legal registry value name. That is why
    Window.Width is one key and not a nested store.

    Every number the window can drag or step is held inside bounds here and
    nowhere else. A splitter dragged to nothing and a font size stepped past
    what a canvas can measure both come back through Set, so clamping at the
    edge of the window would leave the registry holding the bad value.
]]

local Settings = {}
Settings.__index = Settings

--- Spelled out the way every sibling segment spells its own path.
Settings.RegistryPath = "Manifold Address List"

--- The keys that reach the registry. A dotted key reaches into a nested
--- table and is stored under that name.
Settings.Persisted = {
    "Window.Width",
    "Window.Height",
    "TreeWidth",
    "ResultsHeight",
    "FontSize",
    "LiveSync",
    "SyncInterval",
    "ShowValues",
    "ShowAddresses",
    "FollowCESelection",
    "MirrorSelectionToCE",
    "ConfirmScriptActivation",
    "InspectorPage",
    "Lint.ReadValues",
    "Lint.Assemble",
    "Search.MatchCase",
    "Search.WholeWord",
    "Search.Description",
    "Search.Script",
    "Search.DropDown",
    "Search.Scope",
    "Export.IncludeScripts",
    "Export.IncludeValues",
    "Export.IncludeChildren"
}

Settings.Defaults = {
    -- The window opens wide enough for the tree and the inspector side by
    -- side without a splitter drag on a 1366 wide screen.
    Window = { Width = 1180, Height = 740 },

    -- How much of that width the record tree takes. Wide enough for a
    -- description, a type tag, an address and a value on one row.
    TreeWidth = 540,

    -- The results strip, when it is shown at all. Enough for about six rows.
    ResultsHeight = 180,

    -- Consolas 10 is the family size. Everything the canvases draw is
    -- measured from the font, so this is the only size in the segment.
    FontSize = 10,

    -- Cheat Engine has no event for a record that changed, so the window
    -- polls. Off, the window only shows what the last refresh read.
    LiveSync = true,

    -- How often that poll runs. Windows rounds a timer up to its own tick,
    -- so anything under about 16 is the same as 16.
    SyncInterval = 250,

    -- Reading a value reads process memory and can fire the record's own
    -- OnValueChanged, so both columns are a choice and not a given.
    ShowValues = true,
    ShowAddresses = true,

    -- Following Cheat Engine's own selection is off, because a click in the
    -- main window would then throw away a multiple selection made here.
    FollowCESelection = false,

    -- Mirroring back into Cheat Engine is off for the same reason in
    -- reverse. Cheat Engine can only hold one selected record.
    MirrorSelectionToCE = false,

    -- Activating an Auto Assembler record runs its ENABLE section right
    -- away, with no dialog of Cheat Engine's own, so this window asks first.
    ConfirmScriptActivation = true,

    -- Which inspector tab opens with the window. A key from the tab strip.
    InspectorPage = "Properties",

    Lint = {
        -- Reading a value to find the unreadable ones costs a memory read
        -- per record, so a large table pays for it every check.
        ReadValues = false,
        -- Assembling every script to find the broken ones is the slowest
        -- check there is, and it needs the right process attached.
        Assemble = false
    },

    Search = {
        MatchCase = false,
        WholeWord = false,
        -- Descriptions and scripts are where a rename actually has to reach.
        -- A drop-down list is a rarer target, so it starts off.
        Description = true,
        Script = true,
        DropDown = false,
        -- All, Visible or Selection. Visible means the rows the filter shows.
        Scope = "All"
    },

    Export = {
        IncludeScripts = true,
        -- A value is read from process memory at the moment of the export,
        -- so it is a snapshot of a running game and not part of the table.
        IncludeValues = false,
        IncludeChildren = true
    }
}

--
--- ∑ The bounds each numeric setting is held inside. A key with no entry here
---   is stored as it was given. The window minimum is a floor with no ceiling,
---   because a screen can be any size and a window that is too large is still
---   usable.
--
Settings.Bounds = {
    FontSize = { Min = 7, Max = 16 },
    SyncInterval = { Min = 100, Max = 2000 },
    TreeWidth = { Min = 320, Max = 1400 },
    ResultsHeight = { Min = 90, Max = 600 },
    ["Window.Width"] = { Min = 760 },
    ["Window.Height"] = { Min = 480 }
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local made = {}
    for key, item in pairs(value) do made[key] = copy(item) end
    return made
end

--- Nested tables merge rather than replace, so an entry file can override one
--- search flag without restating the whole group.
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
--- ∑ Walks a dotted key. Returns the table that holds the last segment and
---   the segment itself, so reading and writing share one resolution.
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

--
--- ∑ Holds one value inside its bounds. A key with no bounds comes straight
---   back, and a value that is not a number at all falls back to the default
---   rather than becoming zero.
--- @param key string # A plain or dotted key.
--- @param value any
--- @return any
--
function Settings.Clamp(key, value)
    local bound = Settings.Bounds[key]
    if bound == nil then return value end
    local number = tonumber(value)
    if number == nil then return readKey(Settings.Defaults, key) end
    number = math.floor(number)
    if bound.Min and number < bound.Min then number = bound.Min end
    if bound.Max and number > bound.Max then number = bound.Max end
    return number
end

--- Runs every bound over an instance. Overrides from the entry file and a
--- registry written by an older version both come through here.
local function applyBounds(instance)
    for key in pairs(Settings.Bounds) do
        writeKey(instance, key, Settings.Clamp(key, readKey(instance, key)))
    end
end

--
--- ∑ Builds the settings. Defaults first, then the entry file's overrides,
---   then whatever the registry remembers, then the bounds over all of it.
--- @param options table|nil # Overrides and Persist.
--- @return table
--
function Settings:New(options)
    options = options or {}
    local instance = setmetatable(copy(Settings.Defaults), Settings)
    merge(instance, options.Overrides)
    instance.Persist = (options.Persist ~= false)
    instance:Load()
    applyBounds(instance)
    return instance
end

--
--- ∑ The registry store, or nil when Cheat Engine cannot provide one. Looked
---   up at call time, so a test can stub it and a build without it degrades to
---   a session that remembers nothing.
--- @return table|userdata|nil
--
function Settings:Store()
    local get = rawget(_G, "getSettings")
    if type(get) ~= "function" then return nil end
    local ok, store = pcall(get, Settings.RegistryPath)
    if ok and store ~= nil then return store end
    return nil
end

--- What a deliberately empty string is stored as. Cheat Engine answers an
--- empty string for a value nobody ever wrote, so storing one as itself would
--- read back as absent and the default would win.
local EMPTY = "<empty>"

local function encode(value)
    if type(value) == "boolean" then return value and "1" or "0" end
    if value == "" then return EMPTY end
    return tostring(value)
end

--- Decodes against the type of the default, so a damaged value falls back to
--- the default instead of arriving as a string where a number is expected.
local function decode(raw, like)
    if raw == nil or raw == "" then return nil end
    if raw == EMPTY then return "" end
    if type(like) == "boolean" then
        if raw == true or raw == false then return raw end
        return raw == "1" or raw == "true"
    end
    if type(like) == "number" then return tonumber(raw) end
    return raw
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
---   interval or a flag that is neither true nor false.
--- @return boolean # Whether a store was available at all.
--
function Settings:Load()
    if not self.Persist then return false end
    local store = self:Store()
    if not store then return false end
    for _, key in ipairs(Settings.Persisted) do
        local okRead, raw = pcall(function() return store.Value[key] end)
        if okRead then
            local value = decode(raw, readKey(Settings.Defaults, key))
            if value ~= nil then writeKey(self, key, Settings.Clamp(key, value)) end
        end
    end
    return true
end

--
--- ∑ Changes one setting and, for a persisted key, writes it through. The
---   value is clamped before either, so the field and the registry always
---   hold the same usable number.
--- @param key string
--- @param value any
--- @return boolean # Whether the value reached the store. A key that is not
---         persisted reports true, because there was nothing to write.
--
function Settings:Set(key, value)
    value = Settings.Clamp(key, value)
    writeKey(self, key, value)
    if not self.Persist or not isPersisted(key) then return true end
    local store = self:Store()
    if not store then return false end
    return (pcall(function() store.Value[key] = encode(value) end)) == true
end

--- One setting by plain or dotted key.
function Settings:Get(key)
    return readKey(self, key)
end

--
--- ∑ The values worth showing in a status block.
--- @return table
--
function Settings:Summary()
    return {
        Width = self.Window.Width,
        Height = self.Window.Height,
        TreeWidth = self.TreeWidth,
        ResultsHeight = self.ResultsHeight,
        FontSize = self.FontSize,
        LiveSync = self.LiveSync,
        SyncInterval = self.SyncInterval,
        ShowValues = self.ShowValues,
        ShowAddresses = self.ShowAddresses,
        FollowCESelection = self.FollowCESelection,
        MirrorSelectionToCE = self.MirrorSelectionToCE,
        ConfirmScriptActivation = self.ConfirmScriptActivation,
        InspectorPage = self.InspectorPage,
        LintReadValues = self.Lint.ReadValues,
        LintAssemble = self.Lint.Assemble,
        SearchScope = self.Search.Scope,
        Persist = self.Persist
    }
end

return Settings
