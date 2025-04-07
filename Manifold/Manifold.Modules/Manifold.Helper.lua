local NAME = "Manifold.Helper.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Manifold Framework Helper"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.
]]--

Helper = {}
Helper.__index = Helper

function Helper:New()
    local instance = setmetatable({}, self)
    instance.Name = NAME or "Unnamed Module"
    return instance
end
registerLuaFunctionHighlight('New')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table  {name, version, author, description}
--
function Helper:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
--- Handler: Process Get
--- ∑ Retrieves the current process object.
--- @return process The current process object.
--
function Helper:GetProcess()
    return process
end
registerLuaFunctionHighlight('GetProcess')

--
--- Handler: Process Trimmed Get
--- ∑ Retrieves the current process name without the ".exe" extension.
--- @return string The name of the current process without the ".exe" extension.
--
function Helper:GetProcessTrimmed()
    return process:gsub("%.exe$", "")
end
registerLuaFunctionHighlight('GetProcessTrimmed')

--
--- Handler: Game Module Get
--- ∑ Retrieves the first game module loaded in the process.
--- @return module The first game module object, or nil if no modules are loaded.
--
function Helper:GetGameModule()
    local modules = enumModules()
    return (modules and modules[1]) or nil
end
registerLuaFunctionHighlight('GetGameModule')

--
--- Handler: Game Module Is 64-bit
--- ∑ Determines if the game module is 64-bit.
--- @return boolean true if the game module is 64-bit, false if it is not, or nil if no module is found.
--
function Helper:GetGameModuleIs64Bit()
    local gm = self:GetGameModule()
    return gm and gm.Is64Bit or nil
end
registerLuaFunctionHighlight('GetGameModuleIs64Bit')

--
--- Handler: Game Module Name Get
--- ∑ Retrieves the name of the game module.
--- @return string The name of the game module, or nil if no module is found.
--
function Helper:GetGameModuleName()
    local gm = self:GetGameModule()
    return gm and gm.Name or nil
end
registerLuaFunctionHighlight('GetGameModuleName')

--
--- Handler: Game Module Path Get
--- ∑ Retrieves the path to the game module's file.
--- @return string The path to the game module's file, or nil if no module is found.
--
function Helper:GetGameModulePathToFile()
    local gm = self:GetGameModule()
    return gm and gm.PathToFile or nil
end
registerLuaFunctionHighlight('GetGameModulePathToFile')

--
--- Handler: Game Module Address Get
--- ∑ Retrieves the address of the game module in memory.
--- @return integer The address of the game module, or nil if no module is found.
--
function Helper:GetGameModuleAddress()
    local gm = self:GetGameModule()
    return gm and gm.Address or nil
end
registerLuaFunctionHighlight('GetGameModuleAddress')

function Helper:GetRegistrySizeStr()
    return self:GetGameModuleIs64Bit() and "(x64)" or "(x32)"
end

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Helper
