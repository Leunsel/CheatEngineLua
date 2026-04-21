local NAME = "Manifold.Callbacks.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.5"
local DESCRIPTION = "Manifold Framework Callbacks"

--[[
    ∂ v1.0.0 (2025-07-06)
        Started the development of the Callbacks module

    ∂ v1.0.1 (2025-11-18)
        Fixed a variety of bugs within the callback overrides.
        - Missing Return-Values
    
    ∂ v1.0.2 (2025-12-08)
        Adjusted logging levels from Info to Debug for allowed
        changes/edits to reduce log noise.
    
    ∂ v1.0.3 (2025-12-08)
        Prepared MainForm OnClose override for proper deactivation
        of active Auto Assembler scripts before closing.
        TODO: Implement the deactivation logic.
        
    ∂ v1.0.4 (2025-12-30)
        Removed the MainForm OnClose override temporarily due to issues
        with Cheat Engine's closing process. Will revisit later.
        (Error: Cheat Engine does not close properly when this override is active.)

    ∂ v1.0.5 (2026-04-21)
        Refactored callback config flags into a shared configuration system.
        Reduced callback log noise by focusing on blocked actions and actual errors.
]]--

Callbacks = {}
Callbacks.__index = Callbacks

local MODULE_PREFIX = "[Callbacks]"
local DEFAULT_CONFIG = {
    DisableAutoAssemblerEdits = false,
    DisableDescriptionChange = false,
    DisableAddressChange = false,
    DisableTypeChange = false,
    DisableValueChange = false
}
local CONFIG_METHODS = {
    "DisableAutoAssemblerEdits",
    "DisableDescriptionChange",
    "DisableAddressChange",
    "DisableTypeChange",
    "DisableValueChange"
}

local instance = nil

local function _copyTable(source)
    local target = {}
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

function Callbacks:New()
    if instance then
        return instance
    end
    instance = setmetatable({}, self)
    instance.Name = NAME or "Unnamed Module"
    instance.Config = _copyTable(DEFAULT_CONFIG)
    instance:ResetConfig()
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

--
--- ∑ Prints module details in a readable formatted block.
--
function Callbacks:PrintModuleInfo()
    local info = self:GetModuleInfo()
    if not info then
        logger:Info(MODULE_PREFIX .. " Failed to retrieve module info.")
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

--
--- ∑ Validates callback config values.
--- @param value any
--- @param optionName string
--- @return boolean
--
function Callbacks:_RequireBoolean(value, optionName)
    if type(value) ~= "boolean" then
        logger:Error(MODULE_PREFIX .. " " .. tostring(optionName) .. " must be a boolean value.")
        return false
    end
    return true
end
registerLuaFunctionHighlight('_RequireBoolean')

--
--- ∑ Resets the callback configuration to the default values.
--- @return table
--
function Callbacks:ResetConfig()
    self.Config = _copyTable(DEFAULT_CONFIG)
    for key, value in pairs(self.Config) do
        self[key] = value
    end
    return self.Config
end
registerLuaFunctionHighlight('ResetConfig')

--
--- ∑ Returns a config value by option name.
--- @param optionName string
--- @return boolean|nil
--
function Callbacks:GetConfigValue(optionName)
    if self.Config[optionName] == nil then
        logger:Error(MODULE_PREFIX .. " Unknown config option: " .. tostring(optionName))
        return nil
    end
    return self.Config[optionName]
end
registerLuaFunctionHighlight('GetConfigValue')

--
--- ∑ Sets a config value by option name.
--- @param optionName string
--- @param value boolean
--- @return boolean
--
function Callbacks:SetConfigValue(optionName, value)
    if self.Config[optionName] == nil then
        logger:Error(MODULE_PREFIX .. " Unknown config option: " .. tostring(optionName))
        return false
    end
    if not self:_RequireBoolean(value, optionName) then
        return false
    end
    self.Config[optionName] = value
    self[optionName] = value
    return true
end
registerLuaFunctionHighlight('SetConfigValue')

--
--- ∑ Toggles a config value by option name.
--- @param optionName string
--- @return boolean|nil
--
function Callbacks:ToggleConfigValue(optionName)
    local currentValue = self:GetConfigValue(optionName)
    if currentValue == nil then
        return nil
    end
    self:SetConfigValue(optionName, not currentValue)
    return self.Config[optionName]
end
registerLuaFunctionHighlight('ToggleConfigValue')

--
--- ∑ Builds a readable memory record label for callback logs.
--- @param memrec MemoryRecord|nil
--- @return string
--
function Callbacks:_DescribeMemoryRecord(memrec)
    if not memrec then
        return "Unknown Record"
    end
    local description = memrec.Description
    if description == nil or description == "" then
        description = "Unnamed Record"
    end
    local address = memrec.CurrentAddress or 0
    return string.format("%s @ 0x%X", tostring(description), address)
end
registerLuaFunctionHighlight('_DescribeMemoryRecord')

--
--- ∑ Converts a callback execute state into a readable label.
--- @param newstate any
--- @return string
--
function Callbacks:_FormatExecuteState(newstate)
    local normalized = tostring(newstate):lower()
    if normalized == "true" then
        return "Activated"
    end
    if normalized == "false" then
        return "Deactivated"
    end
    return "Unknown"
end
registerLuaFunctionHighlight('_FormatExecuteState')

--
--- ∑ Logs a blocked callback action with concise record context.
--- @param actionName string
--- @param memrec MemoryRecord|nil
--
function Callbacks:_LogBlockedAction(actionName, memrec)
    logger:WarningF("%s %s prevented for %s", MODULE_PREFIX, tostring(actionName), self:_DescribeMemoryRecord(memrec))
end
registerLuaFunctionHighlight('_LogBlockedAction')

--
--- ∑ Handles a guarded change callback with shared error and block logging.
--- @param optionName string
--- @param actionName string
--- @param memrec MemoryRecord|nil
--- @param errorContext string
--- @return boolean
--
function Callbacks:_HandleProtectedChange(optionName, actionName, memrec, errorContext)
    local ok, result = pcall(function()
        if self:GetConfigValue(optionName) then
            self:_LogBlockedAction(actionName, memrec)
            return true
        end
        return false
    end)
    if not ok then
        logger:Error(MODULE_PREFIX .. " Error in " .. tostring(errorContext) .. ": " .. tostring(result))
        return false
    end
    return result
end
registerLuaFunctionHighlight('_HandleProtectedChange')

--
--- ∑ Generates config getter/setter/toggle helpers for supported options.
--
local function _registerConfigMethods(optionName)
    local getterName = "Get" .. optionName
    local setterName = "Set" .. optionName
    local toggleName = "Toggle" .. optionName
    Callbacks[getterName] = function(self)
        return self:GetConfigValue(optionName)
    end
    registerLuaFunctionHighlight(getterName)
    Callbacks[setterName] = function(self, value)
        return self:SetConfigValue(optionName, value)
    end
    registerLuaFunctionHighlight(setterName)
    Callbacks[toggleName] = function(self)
        return self:ToggleConfigValue(optionName)
    end
    registerLuaFunctionHighlight(toggleName)
end

for _, optionName in ipairs(CONFIG_METHODS) do
    _registerConfigMethods(optionName)
end

-- .....................................................

--
--- ∑ Memory Record Pre Execute Callback Override.
--- This function is called before a memory record is executed.
--- @param memoryrecord MemoryRecord # The memory record being executed
--- @param newstate string # The new state of the memory record
--
function onMemRecPreExecute(memoryrecord, newstate)
    local ok, err = pcall(function()
        logger:DebugF("%s PreExecute %s (%s)", MODULE_PREFIX, callbacks:_DescribeMemoryRecord(memoryrecord), callbacks:_FormatExecuteState(newstate))
    end)
    if not ok and logger and logger.Error then
        logger:Error(MODULE_PREFIX .. " Error in onMemRecPreExecute: " .. tostring(err))
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
        if not succeeded then
            logger:WarningF("%s PostExecute failed for %s (%s)", MODULE_PREFIX, callbacks:_DescribeMemoryRecord(memoryrecord), callbacks:_FormatExecuteState(newstate))
        end
    end)
    if not ok and logger and logger.Error then
        logger:Error(MODULE_PREFIX .. " Error in onMemRecPostExecute: " .. tostring(err))
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
    return callbacks:_HandleProtectedChange("DisableDescriptionChange", "Description change", memrec, "OnDescriptionChange")
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
    return callbacks:_HandleProtectedChange("DisableAddressChange", "Address change", memrec, "OnAddressChange")
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
    return callbacks:_HandleProtectedChange("DisableTypeChange", "Type change", memrec, "OnTypeChange")
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
    return callbacks:_HandleProtectedChange("DisableValueChange", "Value change", memrec, "OnValueChange")
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
        if callbacks:GetDisableAutoAssemblerEdits() then
            callbacks:_LogBlockedAction("Auto Assembler edit", memrec)
            return true -- Prevent edit
        end
        if o_AddressList_OnAutoAssemblerEdit then
            local ok2, err2 = pcall(o_AddressList_OnAutoAssemblerEdit, addresslist, memrec)
            if not ok2 then
                logger:Error(MODULE_PREFIX .. " Error in original OnAutoAssemblerEdit: " .. tostring(err2))
            end
        end
        return false -- Allow edit
    end)
    if not ok then
        logger:Error(MODULE_PREFIX .. " Error in OnAutoAssemblerEdit: " .. tostring(result))
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
            logger:Error(MODULE_PREFIX .. " Error in original LuaEngine.OnShow: " .. tostring(err))
        end
    end
    if ui and ui.ActiveTheme and ui.ActiveTheme ~= "" and ui.ApplyThemeToLuaEngine and ui.GetActiveThemeData then
        local ok, themeData = pcall(ui.GetActiveThemeData, ui)
        if ok and themeData then
            -- Double call is intentional for proper theme application
            for _ = 1, 2 do
                local ok2, err2 = pcall(ui.ApplyThemeToLuaEngine, ui, themeData)
                if not ok2 and logger and logger.Error then
                    logger:Error(MODULE_PREFIX .. " Error applying theme to Lua Engine: " .. tostring(err2))
                end
            end
        elseif not ok and logger and logger.Error then
            logger:Error(MODULE_PREFIX .. " Error getting active theme data: " .. tostring(themeData))
        end
    end
end

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Callbacks
