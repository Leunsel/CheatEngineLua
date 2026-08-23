local NAME = "Manifold.Helper.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.1.0"
local DESCRIPTION = "Manifold Framework Helper - facts about the target's main module"

--[[
    ∂ v1.1.0 (2026-08-23)
        Narrowed to one goal: read-only facts about the target process's main
        loaded module - its record, name, path, base address, bitness and file
        version. Everything this module says is derived from enumModules()[1].

        Added GetFileVersionStr, which Manifold.Utils has called since v1.0.0
        and which never existed (TODO T8).

        Deprecated GetProcess, IsProcessAvailable and GetProcessTrimmed. Those
        three describe the CE `process` global, which is Manifold.ProcessHandler's
        goal, not this one - IsProcessAvailable was a line-for-line copy of
        ProcessHandler:IsAttachedProcessAvailable. They still answer, and now
        delegate when ProcessHandler is loaded. They will be removed in 2.0.0.
]]--

Helper = {}
Helper.__index = Helper


local MODULE_PREFIX = "[Helper]"

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
    class = "Helper", global = "helper",
    name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION,
    prefix = MODULE_PREFIX,
    deps = {
        { "logger" },
    },
})

function Helper:New()
    local instance = setmetatable({}, self)
    instance.Name = NAME or "Unnamed Module"
    return BOOTSTRAP.Ready(MODULE, instance)
end
registerLuaFunctionHighlight('New')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table # {name, version, author, description}
--
function Helper:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Prints module details in a readable formatted block.
--
function Helper:PrintModuleInfo()
    local info = self:GetModuleInfo()
    if not info then
        logger:Info("[Helper] Failed to retrieve module info.")
        return
    end
    logger:Info("Module Info : "  .. tostring(info.name))
    logger:Info("\tVersion:     " .. tostring(info.version))
    local author = type(info.author) == "table" and table.concat(info.author, ", ") or tostring(info.author)
    local description = type(info.description) == "table" and table.concat(info.description, ", ") or tostring(info.description)
    logger:Info("\tAuthor:      " .. author)
    logger:Info("\tDescription: " .. description .. "\n")
end
registerLuaFunctionHighlight('PrintModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--------------------------------------------------------
--   Deprecated - owned by Manifold.ProcessHandler    --
--------------------------------------------------------
--
--- These three describe the CE `process` global, not the target's main module,
--- so they are not this module's goal. IsProcessAvailable in particular was a
--- line-for-line duplicate of ProcessHandler:IsAttachedProcessAvailable, and
--- ProcessHandler builds IsProcessAttached, IsTargetProcessValid and
--- GetAttachedProcessName on its copy while nothing in the framework called
--- this one.
---
--- They still answer, because they are published API and reachable by name from
--- any .CT in the wild. Each delegates to ProcessHandler when it is loaded and
--- otherwise runs its original body: Helper is ORDER position 4 and
--- ProcessHandler is 7, so Helper must not depend on it, and a table that loads
--- Helper alone has to keep working.
---
--- Scheduled for removal in Helper 2.0.0.
--

--
--- ∑ Retrieves the current process object.
--- @deprecated Use the `process` global, or processHandler:GetAttachedProcessName().
--- @return process # The current process object.
--
function Helper:GetProcess()
    return process
end
registerLuaFunctionHighlight('GetProcess')

--
--- ∑ Checks if the current process is available and valid.
--- @deprecated Use processHandler:IsProcessAttached().
--- @return boolean # true if the process is available, false otherwise.
--
function Helper:IsProcessAvailable()
    local handler = rawget(_G, "processHandler")
    if type(handler) == "table" and type(handler.IsAttachedProcessAvailable) == "function" then
        return handler:IsAttachedProcessAvailable() ~= nil
    end
    if not process or process == "" then
        return false
    end
    local ok, result = pcall(readInteger, process)
    return ok and result ~= nil
end
registerLuaFunctionHighlight('IsProcessAvailable')

--
--- ∑ Retrieves the current process name without the ".exe" extension.
--- @deprecated Use processHandler:GetAttachedNameNoExt().
---   Parenthesised on purpose: a bare gsub returns the substitution COUNT as a
---   second value, which leaks into any multi-value context - a table
---   constructor, the tail of an argument list, a return chain.
---   The match stays anchored to ".exe" rather than routing through
---   customIO:StripExt, which strips any final extension and would turn a
---   process named "foo.bar" into "foo".
--- @return string|nil # the process name without ".exe", or nil when detached
--
function Helper:GetProcessTrimmed()
    local handler = rawget(_G, "processHandler")
    if type(handler) == "table" and type(handler.GetAttachedNameNoExt) == "function" then
        return handler:GetAttachedNameNoExt()
    end
    if type(process) ~= "string" or process == "" then return nil end
    return (process:gsub("%.exe$", ""))
end
registerLuaFunctionHighlight('GetProcessTrimmed')

--------------------------------------------------------
--        The target's main module - the goal         --
--------------------------------------------------------

--
--- ∑ Retrieves the first game module loaded in the process.
--- @return module # The first game module object, or nil if no modules are loaded.
--
function Helper:GetGameModule()
    -- Guarded: this is the one CE primitive the whole module is built on, and
    -- every other function reaches it through here. An unguarded call raised
    -- before GetFileVersionStr could apply its own careful guards, and made the
    -- module unloadable outside Cheat Engine for no reason.
    if type(enumModules) ~= "function" then return nil end
    local ok, modules = pcall(enumModules)
    if not ok or type(modules) ~= "table" then return nil end
    return modules[1] or nil
end
registerLuaFunctionHighlight('GetGameModule')

--
--- ∑ Checks if the game module is 64-bit.
---   Written as an explicit nil check, not `gm and gm.Is64Bit or nil`: that
---   idiom collapses a legitimate `false` - a 32-bit target - into nil, so the
---   documented boolean|nil was really true|nil.
--- @return boolean|nil # true/false for the module, nil when there is none
--
function Helper:GetGameModuleIs64Bit()
    local gm = self:GetGameModule()
    if gm == nil then return nil end
    return gm.Is64Bit == true
end
registerLuaFunctionHighlight('GetGameModuleIs64Bit')

--
--- ∑ Retrieves the name of the game module.
--- @return string # The name of the game module, or nil if no module is found.
--
function Helper:GetGameModuleName()
    local gm = self:GetGameModule()
    return gm and gm.Name or nil
end
registerLuaFunctionHighlight('GetGameModuleName')

--
--- ∑ Retrieves the path to the game module's file.
--- @return string # The file path to the game module, or nil if no module is found.
--
function Helper:GetGameModulePathToFile()
    local gm = self:GetGameModule()
    return gm and gm.PathToFile or nil
end
registerLuaFunctionHighlight('GetGameModulePathToFile')

--
--- ∑ Retrieves the address of the game module in memory.
--- @return integer # The address of the game module in memory, or nil if no module is found.
--
function Helper:GetGameModuleAddress()
    local gm = self:GetGameModule()
    return gm and gm.Address or nil
end
registerLuaFunctionHighlight('GetGameModuleAddress')

--
--- ∑ Retrieves the registry size string based on the game module's architecture.
--- @return string # A string representing the architecture: "(x64)" for 64-bit or "(x32)" for 32-bit.
--
function Helper:GetRegistrySizeStr()
    return self:GetGameModuleIs64Bit() and "(x64)" or "(x32)"
end
registerLuaFunctionHighlight('GetRegistrySizeStr')

--
--- ∑ Reads the target module's file version as a dotted string.
---   Closes TODO T8: Manifold.Utils has called helper:GetFileVersionStr since
---   v1.0.0 and it has never existed. It stayed latent only because
---   Utils.AppVersion defaults to "" and "" is truthy in Lua, so the fallback
---   was unreachable - the moment a table left AppVersion empty expecting
---   auto-detection, SetTitle fell into its pcall path and the window caption
---   became "Error: Failed to Set Title".
--- @param path string|nil # defaults to this module's own PathToFile
--- @return string|nil # "major.minor.release.build", or nil when unavailable
--
function Helper:GetFileVersionStr(path)
    path = path or self:GetGameModulePathToFile()
    if type(path) ~= "string" or path == "" then return nil end
    if type(getFileVersion) ~= "function" then return nil end
    -- CE returns (versionString, versionInfoTable); the table is the reliable
    -- half, the string is locale- and resource-dependent.
    local ok, _, info = pcall(getFileVersion, path)
    if not ok or type(info) ~= "table" then return nil end
    return string.format("%d.%d.%d.%d",
        info.major or 0, info.minor or 0, info.release or 0, info.build or 0)
end
registerLuaFunctionHighlight('GetFileVersionStr')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Helper
