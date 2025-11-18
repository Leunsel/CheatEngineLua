local NAME = "Manifold.Callbacks.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.1"
local DESCRIPTION = "Manifold Framework Callbacks"

--[[
    ∂ v1.0.0 (2025-07-06)
        Started the development of the Callbacks module

    ∂ v1.0.1 (2025-11-18)
        Fixed a variety of bugs within the callback overrides.
        - Missing Return-Values
]]--

Callbacks = {
    DisableAutoAssemblerEdits = false,
    DisableDescriptionChange = false,
    DisableAddressChange = false,
    DisableTypeChange = false,
    -- DisableValueChange = false, -- This would render a Cheat Table useless, so it's not included
}
Callbacks.__index = Callbacks

local instance = nil

function Callbacks:New()
    if instance then
        return instance
    end
    instance = setmetatable({}, self)
    instance.Name = NAME or "Unnamed Module"
    -- ...
    instance.DisableAutoAssemblerEdits = false
    instance.DisableDescriptionChange = false
    instance.DisableAddressChange = false
    instance.DisableTypeChange = false
    return instance
end
registerLuaFunctionHighlight('New')

--[[
    ∑ Retrieves module metadata as a structured table.
    @return table # {name, version, author, description}
]]
function Callbacks:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
--- ∑ Retrieves the State of DisableAutoAssemblerEdits.
--- @return boolean # true if Auto Assembler edits are disabled, false otherwise
--
function Callbacks:GetDisableAutoAssemblerEdits()
    return self.DisableAutoAssemblerEdits
end
registerLuaFunctionHighlight('GetDisableAutoAssemblerEdits')

--
--- ∑ Sets the State of DisableAutoAssemblerEdits.
--- @param value boolean # true to disable Auto Assembler edits, false to enable
--
function Callbacks:SetDisableAutoAssemblerEdits(value)
    self.DisableAutoAssemblerEdits = value
end
registerLuaFunctionHighlight('SetDisableAutoAssemblerEdits')

--
--- ∑ Toggles the State of DisableAutoAssemblerEdits.
--- @return nil
--
function Callbacks:ToggleDisableAutoAssemblerEdits()
    self.DisableAutoAssemblerEdits = not self.DisableAutoAssemblerEdits
end
registerLuaFunctionHighlight('ToggleDisableAutoAssemblerEdits')

--
--- ∑ Retrieves the State of DisableDescriptionChange.
--- @return boolean # true if description changes are disabled, false otherwise
--
function Callbacks:GetDisableDescriptionChange()
    return self.DisableDescriptionChange
end
registerLuaFunctionHighlight('GetDisableDescriptionChange')

--
--- ∑ Sets the State of DisableDescriptionChange.
--- @param value boolean # true to disable description changes, false to enable
--
function Callbacks:SetDisableDescriptionChange(value)
    self.DisableDescriptionChange = value
end
registerLuaFunctionHighlight('SetDisableDescriptionChange')

--
--- ∑ Toggles the State of DisableDescriptionChange.
--- @return nil
--
function Callbacks:ToggleDisableDescriptionChange()
    self.DisableDescriptionChange = not self.DisableDescriptionChange
end
registerLuaFunctionHighlight('ToggleDisableDescriptionChange')

--
--- ∑ Retrieves the State of DisableAddressChange.
--- @return boolean # true if address changes are disabled, false otherwise
--
function Callbacks:GetDisableAddressChange()
    return self.DisableAddressChange
end
registerLuaFunctionHighlight('GetDisableAddressChange')

--
--- ∑ Sets the State of DisableAddressChange.
--- @param value boolean # true to disable address changes, false to enable
--
function Callbacks:SetDisableAddressChange(value)
    self.DisableAddressChange = value
end
registerLuaFunctionHighlight('SetDisableAddressChange')

--
--- ∑ Toggles the State of DisableAddressChange.
--- @return nil
--
function Callbacks:ToggleDisableAddressChange()
    self.DisableAddressChange = not self.DisableAddressChange
end
registerLuaFunctionHighlight('ToggleDisableAddressChange')

--
--- ∑ Retrieves the State of DisableTypeChange.
--- @return boolean # true if type changes are disabled, false otherwise
--
function Callbacks:GetDisableTypeChange()
    return self.DisableTypeChange
end
registerLuaFunctionHighlight('GetDisableTypeChange')

--
--- ∑ Sets the State of DisableTypeChange.
--- @param value boolean # true to disable type changes, false to enable
--
function Callbacks:SetDisableTypeChange(value)
    self.DisableTypeChange = value
end
registerLuaFunctionHighlight('SetDisableTypeChange')

--
--- ∑ Toggles the State of DisableTypeChange.
--- @return nil
--
function Callbacks:ToggleDisableTypeChange()
    self.DisableTypeChange = not self.DisableTypeChange
end
registerLuaFunctionHighlight('ToggleDisableTypeChange')

-- .....................................................

--
--- ∑ Memory Record Pre Execute Callback Override.
--- This function is called before a memory record is executed.
--- @param memoryrecord MemoryRecord # The memory record being executed
--- @param newstate string # The new state of the memory record
--
function onMemRecPreExecute(memoryrecord, newstate)
    local ok, err = pcall(function()
        local stateStr = "Unknown"
        local ns = tostring(newstate):lower()
        if ns == "true" then
            stateStr = "Activated"
        elseif ns == "false" then
            stateStr = "Deactivated"
        end
        local value = memoryrecord.Value
        if value == nil or value == "" then value = "N/A" end
        logger:InfoF(
            "[Callbacks] [PreExecute]\n" ..
            "\tDescription : %s\n" ..
            "\tState       : %s (%s)\n" ..
            "\tAddress     : 0x%X\n" ..
            "\tVarType     : %s\n" ..
            "\tValue       : %s",
            memoryrecord.Description,
            tostring(newstate), stateStr,
            memoryrecord.CurrentAddress or 0,
            memoryrecord.VarType or "N/A",
            tostring(value))
    end)
    if not ok and logger and logger.Error then
        logger:Error("[Callbacks] Error in onMemRecPreExecute: " .. tostring(err))
    end
end
registerLuaFunctionHighlight('onMemRecPreExecute')

--
--- ∑ Memory Record Post Execute Callback Override.
--- This function is called after a memory record has been executed.
--- @param memoryrecord MemoryRecord # The memory record that was executed
--- @param newstate string # The new state of the memory record
--- @param succeeded boolean # Whether the execution was successful
--
function onMemRecPostExecute(memoryrecord, newstate, succeeded)
    local ok, err = pcall(function()
        local stateStr = "Unknown"
        local ns = tostring(newstate):lower()
        if ns == "true" then
            stateStr = "Activated"
        elseif ns == "false" then
            stateStr = "Deactivated"
        end
        logger:InfoF(
            "[Callbacks] [PostExecute]\n" ..
            "\tDescription : %s\n" ..
            "\tState       : %s (%s)\n" ..
            "\tSucceeded   : %s",
            memoryrecord.Description,
            tostring(newstate), stateStr,
            tostring(succeeded))
    end)
    if not ok and logger and logger.Error then
        logger:Error("[Callbacks] Error in onMemRecPostExecute: " .. tostring(err))
    end
end
registerLuaFunctionHighlight('onMemRecPostExecute')

--
--- ∑ Memory Record Description Change Callback Override.
--- This function is called when a memory record's description is requested to be changed.
--- @param addresslist AddressList # The address list containing the memory record
--- @param memrec MemoryRecord # The memory record whose description is being changed
--- @return boolean # true to prevent the change, false to allow it
--
AddressList.OnDescriptionChange = function(addresslist, memrec)
    local ok, result = pcall(function()
        logger:InfoF(
            "[Callbacks] [OnDescriptionChange]\n" ..
            "\tDescription : %s\n" ..
            "\tAddress     : 0x%X",
            memrec.Description,
            memrec.CurrentAddress or 0)
        if callbacks.DisableDescriptionChange then
            logger:Warning("[Callbacks] Description changes are disabled. Change prevented.")
            return true  -- prevent
        end
        logger:Info("[Callbacks] Description change allowed.")
        return false  -- allow
    end)
    if not ok and logger and logger.Error then
        logger:Error("[Callbacks] Error in OnDescriptionChange: " .. tostring(result))
        return false -- on error allow change (safe behavior)
    end
    return result -- true = block, false = allow
end
registerLuaFunctionHighlight('AddressList.OnDescriptionChange')

--
--- ∑ Memory Record Address Change Callback Override.
--- This function is called when a memory record's address is requested to be changed.
--- @param addresslist AddressList # The address list containing the memory record
--- @param memrec MemoryRecord # The memory record whose address is being changed
--- @return boolean # true to prevent the change, false to allow it
--
AddressList.OnAddressChange = function(addresslist, memrec)
    local ok, result = pcall(function()
        logger:InfoF(
            "[Callbacks] [OnAddressChange]\n" ..
            "\tDescription : %s\n" ..
            "\tOld Address : 0x%X",
            memrec.Description,
            memrec.CurrentAddress or 0)
        if callbacks.DisableAddressChange then
            logger:Warning("[Callbacks] Address changes are disabled. Change prevented.")
            return true -- Prevent the change
        end
        logger:Info("[Callbacks] Address change allowed.")
        return false -- Allow
    end)
    if not ok and logger and logger.Error then
        logger:Error("[Callbacks] Error in OnAddressChange: " .. tostring(result))
        return false
    end
    return result -- true = block, false = allow
end
registerLuaFunctionHighlight('AddressList.OnAddressChange')

--
--- ∑ Memory Record Type Change Callback Override.
--- This function is called when a memory record's type is requested to be changed.
--- @param addresslist AddressList # The address list containing the memory record
--- @param memrec MemoryRecord # The memory record whose type is being changed
--- @return boolean # true to prevent the change, false to allow it
--
AddressList.OnTypeChange = function(addresslist, memrec)
    local ok, result = pcall(function()
        logger:InfoF(
            "[Callbacks] [OnTypeChange]\n" ..
            "\tDescription : %s\n" ..
            "\tAddress     : 0x%X\n" ..
            "\tOld Type    : %s",
            memrec.Description,
            memrec.CurrentAddress or 0,
            memrec.VarType or "N/A")
        if callbacks.DisableTypeChange then
            logger:Warning("[Callbacks] Type changes are disabled. Change prevented.")
            return true -- Prevent the change
        end
        logger:Info("[Callbacks] Type change allowed.")
        return false -- Allow
    end)
    if not ok and logger and logger.Error then
        logger:Error("[Callbacks] Error in OnTypeChange: " .. tostring(result))
        return false
    end
    return result -- true = block, false = allow
end
registerLuaFunctionHighlight('AddressList.OnTypeChange')

--
--- Memory Record Value Change Callback Override.
--- This function is called when a memory record's value is requested to be changed.
--- @param addresslist AddressList # The address list containing the memory record
--- @param memrec MemoryRecord # The memory record whose value is being changed
--- @return boolean # true to prevent the change, false to allow it
--
AddressList.OnValueChange = function(addresslist, memrec)
    local ok, result = pcall(function()
        local value = memrec.Value
        if value == nil or value == "" then value = "N/A" end
        logger:InfoF(
            "[Callbacks] [OnValueChange]\n" ..
            "\tDescription : %s\n" ..
            "\tAddress     : 0x%X\n" ..
            "\tOld Value   : %s",
            memrec.Description,
            memrec.CurrentAddress or 0,
            tostring(value))
        if callbacks.DisableValueChange then
            logger:Warning("[Callbacks] Value changes are disabled. Change prevented.")
            return true -- Prevent
        end
        logger:Info("[Callbacks] Value change allowed.")
        return false -- Allow
    end)
    if not ok and logger and logger.Error then
        logger:Error("[Callbacks] Error in OnValueChange: " .. tostring(result))
        return false
    end
    return result -- true = block, false = allow
end
registerLuaFunctionHighlight('AddressList.OnValueChange')

--
--- ∑ Memory Record Auto Assembler Edit Callback Override.
--- This function is called when an Auto Assembler edit is requested for a memory record.
--- @param addresslist AddressList # The address list containing the memory record
--- @param memrec MemoryRecord # The memory record being edited
--- @return boolean # true to prevent the edit, false to allow it
--
local o_AddressList_OnAutoAssemblerEdit = AddressList.OnAutoAssemblerEdit
AddressList.OnAutoAssemblerEdit = function(addresslist, memrec)
    local ok, result = pcall(function()
        logger:InfoF(
            "[Callbacks] [OnAutoAssemblerEdit]\n" ..
            "\tDescription : %s\n" ..
            "\tAddress     : 0x%X",
            memrec.Description,
            memrec.CurrentAddress or 0)
        if callbacks.DisableAutoAssemblerEdits then
            logger:Warning("[Callbacks] Auto Assembler edits are disabled. Edit prevented.")
            return true -- Prevent edit
        end
        logger:Info("[Callbacks] Auto Assembler edit allowed.")
        if o_AddressList_OnAutoAssemblerEdit then
            local ok2, err2 = pcall(o_AddressList_OnAutoAssemblerEdit, addresslist, memrec)
            if not ok2 then
                logger:Error("[Callbacks] Error in original OnAutoAssemblerEdit: " .. tostring(err2))
            end
        end
        return false -- Allow edit
    end)
    if not ok then
        logger:Error("[Callbacks] Error in OnAutoAssemblerEdit: " .. tostring(result))
        return false -- safe fallback: allow edit
    end
    return result -- true = block, false = allow
end

registerLuaFunctionHighlight('AddressList.OnAutoAssemblerEdit')

--
--- ∑ Lua Engine OnShow Callback Override.
--- This function is called when the Lua Engine is shown.
--- It applies the active theme to the Lua Engine if available.
--- @param ... any # Additional parameters passed to the original OnShow function
--
local LuaEngine = getLuaEngine()
local o_LuaEngine_OnShow = LuaEngine and LuaEngine.OnShow
LuaEngine.OnShow = function(...)
    if o_LuaEngine_OnShow then
        local ok, err = pcall(o_LuaEngine_OnShow, ...)
        if not ok and logger and logger.Error then
            logger:Error("[Callbacks] Error in original LuaEngine.OnShow: " .. tostring(err))
        end
    end
    if ui and ui.ActiveTheme and ui.ActiveTheme ~= "" and ui.ApplyThemeToLuaEngine and ui.GetActiveThemeData then
        local ok, themeData = pcall(ui.GetActiveThemeData, ui)
        if ok and themeData then
            -- Double call is intentional for proper theme application
            for _ = 1, 2 do
                local ok2, err2 = pcall(ui.ApplyThemeToLuaEngine, ui, themeData)
                if not ok2 and logger and logger.Error then
                    logger:Error("[Callbacks] Error applying theme to Lua Engine: " .. tostring(err2))
                end
            end
        elseif not ok and logger and logger.Error then
            logger:Error("[Callbacks] Error getting active theme data: " .. tostring(themeData))
        end
    end
end

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Callbacks
