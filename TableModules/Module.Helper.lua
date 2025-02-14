local NAME = 'CTI.FormManager'
local AUTHOR = {'Leunsel', 'LeFiXER', 'TheyCallMeTim13'}
local VERSION = '1.0.2'
local DESCRIPTION = 'Cheat Table Interface (Helper)'

--[[
    Script Name: Module.Helper.lua
    Description: The Helper Module provides utility functions for Cheat Engine
                 tables, focusing on retrieving game process details, managing
                 memory modules, and printing relevant information. It serves
                 as a foundation for cheat table development, offering
                 streamlined access to process metadata, module details, and
                 address list features.
    
    Version History:
    -----------------------------------------------------------------------------
    Version | Date         | Author          | Changes
    -----------------------------------------------------------------------------
    1.0.0   | ----------   | Leunsel,LeFiXER | Initial release.
    1.0.1   | ----------   | Leunsel         | ----------
    1.0.2   | 14.02.2025   | Leunsel,LeFiXER | Added Version History
    -----------------------------------------------------------------------------
    
    Notes:
    - Features:
        - Process Information:
            * Retrieve the current process name (trimmed or full).
        - Module Management:
            * Fetch the main module details (name, address, path, version).
            * Determine if the module is 64-bit or 32-bit.
        - File Version Handling:
            * Retrieve file versions as structured data or formatted strings.
        - Registry Architecture Detection:
            * Identify whether the game is running in x64 or x32 mode.
        - Address List and Script Management:
            * Print available memory records and auto-assembler scripts.
        - Module Enumeration:
            * Display detailed information about all loaded modules.
--]]

--
--- Would contain several configuration properties that can be customized.
--- Set within the Table Lua Script and passed to the constructor of the class.
--- None in this case.
----------
Helper = {}

--
--- Set the metatable for the Helper object so that it behaves as an "object-oriented class".
----------
Helper.__index = Helper

--
--- Constructor for the Helper class. Initializes default formatters and settings.
--- @return A new instance of Helper.
----------
function Helper:new()
    local obj = setmetatable({}, self)
    return obj
end

--
--- Returns the current process name.
--- @return string: The name of the current process.
----------
function Helper:getProcess()
    return process
end

--
--- Returns the current process name with the ".exe" extension removed (if present).
--- @return string: The current process name without the ".exe" extension.
----------
function Helper:getProcessTrimmed()
    return process:gsub("%.exe$", "")
end

--
--- Retrieves the first module in the list of modules loaded by the game.
--- @return table|nil: The first module if available, otherwise nil.
----------
function Helper:getGameModule()
    local modules = enumModules()
    return (modules and modules[1]) or nil
end

--
--- Checks whether the game's main module is 64-bit.
--- @return boolean|nil: True if the module is 64-bit, otherwise nil.
----------
function Helper:getGameModuleIs64Bit()
    local gm = self:getGameModule()
    return gm and gm.Is64Bit or nil
end

--
--- Retrieves the name of the game's main module.
--- @return string|nil: The name of the main module, or nil if not available.
----------
function Helper:getGameModuleName()
    local gm = self:getGameModule()
    return gm and gm.Name or nil
end

--
--- Retrieves the file path to the main module of the game.
--- @return string|nil: The path to the main module file, or nil if not available.
----------
function Helper:getGameModulePathToFile()
    local gm = self:getGameModule()
    return gm and gm.PathToFile or nil
end

--
--- Retrieves the address of the main module of the game.
--- @return string|nil: The address of the main module, or nil if not available.
----------
function Helper:getGameModuleAddress()
    local gm = self:getGameModule()
    return gm and gm.Address or nil
end

--
--- Retrieves detailed information about the game's main module, including its name, 64-bit status,
--- file path, address, and version.
--- @return table: A table containing the modules information.
----------
function Helper:getGameModuleInfo()
    return {
            name = self:getGameModuleName(),
            is64Bit = self:getGameModuleIs64Bit(),
            pathToFile = self:getGameModulePathToFile(),
            address = self:getGameModuleAddress(),
            version = self:getGameVersion()
        }
end

--
--- Retrieves detailed string representations of the game's main module information, including its name,
--- 64-bit status, file path, address, and version string.
--- @return table: A table containing string representations of the module's details.
----------
function Helper:getGameModuleInfoStrs()
    return {
            name = self:getGameModuleName(),
            is64Bit = self:getGameModuleIs64Bit(),
            pathToFile = self:getGameModulePathToFile(),
            address = self:getGameModuleAddress(),
            versionStr = self:getGameVersionStr()
       }
end

--
--- Retrieves the version of the game's main module.
--- @return string|nil: The version of the main module, or nil if unavailable.
----------
function Helper:getGameVersion()
    local path = self:getGameModulePathToFile()
    return path and getFileVersion(path) or nil
end

--
--- Retrieves the version string of the game's main module.
--- @return string|nil: The version string, or nil if unavailable.
----------
function Helper:getGameVersionStr()
    return self:getFileVersionStr(self:getGameModulePathToFile())
end

--
--- Retrieves the file version of a given path and returns it as a string.
--- @param path: The file path.
--- @return string|nil: The file version string, or nil if the version cannot be retrieved.
----------
function Helper:getFileVersionStr(path)
    if not path then return nil end
    local _, vt = getFileVersion(path)
    if vt then
        return string.format("%s.%s.%s.%s", vt.major, vt.minor, vt.release, vt.build)
    end
    return nil
end

--
--- Returns a string representation of the registry size (x64 or x32) based on the game's main module's architecture.
--- @return string: A string indicating whether the game is running in 64-bit or 32-bit mode.
----------
function Helper:getRegistrySizeStr()
    return self:getGameModuleIs64Bit() and "(x64)" or "(x32)"
end

--
--- Prints the details of the address list, including the ID, description, and type of each address.
--- If no address list is found, an error message is displayed.
--- @return None.
----------
function Helper:printTableFeatures()
    local al = getAddressList()
    if not al then
        print("No address list found.")
        return
    end
    for i = 0, al.Count - 1 do
        print(string.format("[ID:%d] —> '%s' [Type:%s]", i, al[i].Description, al[i].Type))
    end
end

--
--- Prints the details of auto-assembler scripts in the address list, including the ID and description.
--- If no address list or auto-assembler scripts are found, an error message is displayed.
--- @return None.
----------
function Helper:printTableScripts()
    local al = getAddressList()
    if not al then
        print("No address list found.")
        return
    end
    for i = 0, al.Count - 1 do
        if al[i].Type == vtAutoAssembler then
            print(string.format("[ID:%d] —> '%s'", i, al[i].Description:gsub("%(%)%->", "")))
        end
    end
end

--
--- Prints detailed information about each module, including the module's name, address, and file path.
--- The architecture (x64 or x32) is also displayed for each module.
--- @return None.
----------
function Helper:printModuleDetails()
    local ind = '  '
    local modules = enumModules()
    
    for i = 1, #modules do
        if modules[i].Is64Bit then
            print(modules[i].Name .. '  x64')
        else
            print(modules[i].Name .. '  x32')
        end
        print(ind .. string.format('%016X', modules[i].Address))
        print(ind .. modules[i].PathToFile:sub(2, #modules[i].PathToFile))
    end
end

return Helper
