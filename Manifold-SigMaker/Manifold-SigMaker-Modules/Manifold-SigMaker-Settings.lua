--[[
    Settings, with the ones the menu can change persisted.

    Cheat Engine's getSettings() hands any script a registry backed store, so
    the masking choices survive a restart. Values are stored there as strings
    and are decoded against the type of the default. A value that was never
    written comes back as an empty string, never as nil, so both of those
    have to be read as absent.

    A dotted key reaches into a nested table and is stored under that name,
    dot included.
]]

local Settings = {}
Settings.__index = Settings

Settings.RegistryPath = "Manifold SigMaker"

Settings.Persisted = {
    "Output",
    "StopAtFunctionEnd",
    "Mask.Displacement",
    "Mask.BranchTarget",
    "Mask.Immediate",
    "Scope",
    "CopyToClipboard"
}

Settings.Defaults = {
    -- How far a signature is allowed to grow before it gives up. GH SigMaker
    -- v2.0 had no cap at all and walked on to the end of the region.
    MaxInstructions = 64,
    MaxBytes = 256,

    -- A signature that reaches past a ret or an unconditional jmp has left the
    -- function and is describing whatever the linker happened to put next.
    -- An epilogue is the exception. The sequence
    -- "lea rsp,[rsp+20] / pop rbp / ret" looks the same in every
    -- function with that frame size, so walking past the end is the only way
    -- to become unique at all. That is why this stays off by default. Crossing
    -- the end is reported rather than refused.
    StopAtFunctionEnd = false,

    -- Do not scan for a pattern shorter than this. A single instruction can
    -- leave one structural byte behind. A call rel32 trims down to just E8.
    -- One byte matches roughly one address in 256, so Cheat Engine builds a
    -- list of millions of hits before anything can be counted.
    MinPatternBytes = 5,

    -- Code lives in executable pages. Restricting the scan to them is both
    -- faster and more correct. A copy of the bytes sitting in a heap buffer is
    -- not another place the signature could resolve to. An empty string here
    -- would search everything. See celua.txt under AOBScan.
    ScanProtection = "+X",

    -- "module" counts matches inside the module the address belongs to, which
    -- is what a later AOBScanModule will search. "process" counts everywhere,
    -- which is stricter and slower.
    Scope = "module",

    CopyToClipboard = true,

    -- Which lines reach the clipboard, in order. See Manifold-SigMaker-Format
    -- for the part names. "aob" is the bare scan pattern and the only part
    -- most work needs. "header,code,aobq" reproduces the three lines GH
    -- SigMaker v2.0 wrote.
    Output = "aob",

    --
    -- Which operand bytes become wildcards.
    --
    -- Displacements and branch targets move when a binary is rebuilt or
    -- relocated, so masking them is what makes a signature survive a patch.
    -- An immediate is usually a real constant. The 28 in sub rsp,28 is one of
    -- those, and a constant carries uniqueness, so an immediate is kept unless
    -- it is large enough to be an address.
    --
    Mask = {
        Displacement = true,     -- the number inside [ ]
        BranchTarget = true,     -- the target of jmp/call/jcc
        -- Takes true, false or "large". "large" masks only the immediates
        -- whose value is at least ImmediateThreshold, which are the ones that
        -- look like addresses rather than counts.
        Immediate = "large",
        ImmediateThreshold = 0x10000
    },

    MenuCaption = "Manifold: Copy Signature"
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
--- ∑ Walks a dotted key. Returns the table that holds the last segment and
---   the segment itself, so reading and writing share one resolution.
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

function Settings:New(options)
    options = options or {}
    local instance = setmetatable(copy(Settings.Defaults), Settings)
    merge(instance, options.Overrides)
    instance.Persist = (options.Persist ~= false)
    instance:Load()
    return instance
end

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

--- Mask.Immediate has three states, so it decodes as a string first.
local function decode(raw, like)
    if raw == nil or raw == "" then return nil end
    if type(like) == "boolean" then
        if raw == true or raw == false then return raw end
        return raw == "1" or raw == "true"
    end
    if type(like) == "number" then return tonumber(raw) end
    if raw == "1" or raw == "true" then return true end
    if raw == "0" or raw == "false" then return false end
    return raw
end

local function isPersisted(key)
    for _, name in ipairs(Settings.Persisted) do
        if name == key then return true end
    end
    return false
end

function Settings:Load()
    if not self.Persist then return false end
    local store = self:Store()
    if not store then return false end
    for _, key in ipairs(Settings.Persisted) do
        local okRead, raw = pcall(function() return store.Value[key] end)
        if okRead then
            local value = decode(raw, readKey(Settings.Defaults, key))
            if value ~= nil then writeKey(self, key, value) end
        end
    end
    return true
end

function Settings:Set(key, value)
    writeKey(self, key, value)
    if not self.Persist or not isPersisted(key) then return true end
    local store = self:Store()
    if not store then return false end
    return (pcall(function() store.Value[key] = encode(value) end)) == true
end

function Settings:Get(key)
    return readKey(self, key)
end

function Settings:Summary()
    return {
        Displacement = self.Mask.Displacement,
        BranchTarget = self.Mask.BranchTarget,
        Immediate = self.Mask.Immediate,
        Scope = self.Scope,
        Output = self.Output,
        StopAtFunctionEnd = self.StopAtFunctionEnd,
        CopyToClipboard = self.CopyToClipboard,
        Persist = self.Persist
    }
end

return Settings
