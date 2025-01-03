local NAME = 'CTI.FormManager'
local AUTHOR = {'Leunsel', 'LeFiXER'}
local VERSION = '1.0.1'
local DESCRIPTION = 'Cheat Table Interface (Helper)'

Helper = {}
Helper.__index = Helper

function Helper:new()
    local obj = setmetatable({}, self)
    return obj
end

function Helper:getProcess()
    return process
end

function Helper:getProcessTrimmed()
    return process:gsub("%.exe$", "")
end

function Helper:getGameModule()
    local modules = enumModules()
    return (modules and modules[1]) or nil
end

function Helper:getGameModuleIs64Bit()
    local gm = self:getGameModule()
    return gm and gm.Is64Bit or nil
end

function Helper:getGameModuleName()
    local gm = self:getGameModule()
    return gm and gm.Name or nil
end

function Helper:getGameModulePathToFile()
    local gm = self:getGameModule()
    return gm and gm.PathToFile or nil
end

function Helper:getGameModuleAddress()
    local gm = self:getGameModule()
    return gm and gm.Address or nil
end

function Helper:getGameModuleInfo()
    return {
            name = self:getGameModuleName(),
            is64Bit = self:getGameModuleIs64Bit(),
            pathToFile = self:getGameModulePathToFile(),
            address = self:getGameModuleAddress(),
            version = self:getGameVersion()
        }
end

function Helper:getGameModuleInfoStrs()
    return {
            name = self:getGameModuleName(),
            is64Bit = self:getGameModuleIs64Bit(),
            pathToFile = self:getGameModulePathToFile(),
            address = self:getGameModuleAddress(),
            versionStr = self:getGameVersionStr()
       }
end

function Helper:getGameVersion()
    local path = self:getGameModulePathToFile()
    return path and getFileVersion(path) or nil
end

function Helper:getGameVersionStr()
    return self:getFileVersionStr(self:getGameModulePathToFile())
end

function Helper:getFileVersionStr(path)
    if not path then return nil end
    local _, vt = getFileVersion(path)
    if vt then
        return string.format("%s.%s.%s.%s", vt.major, vt.minor, vt.release, vt.build)
    end
    return nil
end

function Helper:getRegistrySizeStr()
    return self:getGameModuleIs64Bit() and "(x64)" or "(x32)"
end

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
