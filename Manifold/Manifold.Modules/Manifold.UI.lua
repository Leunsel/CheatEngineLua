local NAME = "Manifold.UI.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Manifold Framework UI"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.
]]--

UI = {
    ThemeList = {},
    ActiveTheme = nil,
    CompactMode = false,
    -- Setup
    Theme = "",
    SloganStr = "",
    SignatureStr = "",
}
UI.__index = UI

function UI:New(config)
    local instance = setmetatable({}, self)
    self:CheckDependencies()
    self:EnsureThemeDirectory()
    instance.Name = NAME or "Unnamed Module"
    for key, value in pairs(config or {}) do
        if self[key] ~= nil then
            instance[key] = value
        else
            logger:WarningF("Invalid property: '%s'", key)
        end
    end
    return instance
end
registerLuaFunctionHighlight('New')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table  {name, version, author, description}
--
function UI:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

-- Predefined type tables for faster lookups
local STRING_TYPES = { [vtString] = true, [vtUnicodeString] = true }
local INTEGER_TYPES = { [vtByte] = true, [vtWord] = true, [vtDword] = true, [vtQword] = true }
local FLOAT_TYPES   = { [vtSingle] = true, [vtDouble] = true }

--
--- ∑ A list of tokens used for theming.
--
UI.ThemeTokens = {
    "TreeView.Color",
    "TreeView.Font.Color",
    "AddressList.CheckboxColor",
    "AddressList.CheckboxActiveColor",
    "AddressList.CheckboxSelectedColor",
    "AddressList.CheckboxActiveSelectedColor",
    "AddressList.List.BackgroundColor",
    "AddressList.Header.Font.Color",
    "AddressList.Header.Canvas.Brush.Color",
    "AddressList.Header.Canvas.Pen.Color",
    "MainForm.Color",
    "MainForm.Foundlist3.Color",
    "MainForm.Panel4.BevelColor",
    "MainForm.lblSigned.Font.Color",
    "MainForm.Splitter1.Color",
    "MainForm.SLOGAN_STR.Font.Color",
    "Memrec.AutoAssembler.Color",
    "Memrec.AddressGroupHeader.Color",
    "Memrec.GroupHeader.Color",
    "Memrec.UserDefined.Color",
    "Memrec.HexValues.Color",
    "Memrec.StringType.Color",
    "Memrec.IntegerType.Color",
    "Memrec.FloatType.Color",
    "Memrec.DefaultForeground.Color"
}

--
--- ∑ Checks if all required dependencies are loaded, and loads them if necessary.
--- @return void
--- @note Checks for 'json' as well as "customIO" and loads them if not already present.
--
function UI:CheckDependencies()
    local dependencies = {
        { name = "json", path = "Manifold.Json",  init = function() json = JSON:new() end },
        { name = "customIO", path = "Manifold.CustomIO",  init = function() customIO = CustomIO:New() end },
        { name = "logger", path = "Manifold.Logger",  init = function() logger = Logger:New() end },
    }
    for _, dep in ipairs(dependencies) do
        local depName = dep.name
        if _G[depName] == nil then
            logger:Warning("[UI] '" .. depName .. "' dependency not found. Attempting to load...")
            local success, result = pcall(CETrequire, dep.path)
            if success then
                logger:Info("[UI] Loaded dependency '" .. depName .. "'.")
                if dep.init then dep.init() end
            else
                logger:Error("[UI] Failed to load dependency '" .. depName .. "': " .. result)
            end
        else
            logger:Debug("[UI] Dependency '" .. depName .. "' is already loaded")
        end
    end    
end

--
--- ∑ Ensures that the Theme Directory exists within the Data Directory.
--- @return string|nil  The full path to the Theme Directory, or nil if creation failed.
--- @note First verifies that the DataDir exists. Then checks for the Theme Directory (DataDir\Themes) and creates it if necessary.
--
function UI:EnsureThemeDirectory()
    if not customIO:EnsureDataDirectory() then
        logger:Error("[UI] Data directory missing, can't create theme directory.")
        return nil
    end
    local themeDir = customIO.DataDir .. "\\Themes"
    if customIO:DirectoryExists(themeDir) then
        logger:Info("[UI] Theme directory exists.")
        return themeDir
    end
    logger:Warning("[UI] Theme directory missing, creating...")
    local success, err = customIO:CreateDirectory(themeDir)
    if not success then
        logger:Error("[UI] Failed to create theme directory: " .. (err or "Unknown error"))
        return nil
    else
        logger:Info("[UI] Theme directory created.")
        return themeDir
    end
end
registerLuaFunctionHighlight('EnsureThemeDirectory')

--
--- ∑ Initializes the Table Menu component from the MainForm.
--- @return void
--- @note Logs an error if the component is missing.
--
function UI:InitializeTableMenu()
    local success, err = pcall(function()
        local tableMenu = MainForm.findComponentByName("miTable")
        if not tableMenu then
            logger:Critical("[UI] Missing 'miTable' component. Can't load themes.")
            return
        end
        tableMenu.doClick()
        logger:Info("[UI] 'miTable' content loaded.")
    end)
    if not success then
        logger:Error("[UI] Error in InitializeTableMenu: " .. tostring(err))
    end
end
registerLuaFunctionHighlight('InitializeTableMenu')

--
--- ∑ Retrieves JSON theme file names from the Table Menu component.
--- @return table|nil  A table of JSON file names, or nil if none found.
--
function UI:GetJsonThemesFromTableMenu()
    local jsonThemes = {}
    local success, err = pcall(function()
        self:InitializeTableMenu()
        local tableMenu = MainForm.findComponentByName("miTable")
        if not tableMenu then
            logger:Error("[UI] 'miTable' component not found.")
            return
        end

        local count = tableMenu.getCount()
        if count == 0 then
            logger:Error("[UI] No items found in 'miTable' component.")
            return
        end
        logger:Info("[UI] Found " .. count .. " items in 'miTable'.")

        for i = 0, count - 1 do
            local caption = tableMenu[i].Caption
            if caption:find("%.json$") then
                table.insert(jsonThemes, caption)
                logger:Debug("[UI] JSON file found: '" .. caption .. "'")
            end
        end
    end)
    if not success then
        logger:Error("[UI] Error in GetJsonThemesFromTableMenu: " .. tostring(err))
    end
    return #jsonThemes > 0 and jsonThemes or nil
end
registerLuaFunctionHighlight('GetJsonThemesFromTableMenu')

--
--- ∑ Retrieves the list of theme tokens.
--- @return table  The theme tokens list.
--
function UI:GetThemeTokens()
    return self.ThemeTokens
end

--
--- ∑ Converts a hex color string to BGR format.
--- @return number  The BGR color value.
--
function string:bgr()
    local hexColorString = self:sub(2, 7)
    local RGB = tonumber(hexColorString, 16)
    return UI:RGB2BGR(RGB)
end

--
--- ∑ Converts an RGB color to its BGR equivalent.
--- @param RGB number  The RGB color value (0xRRGGBB).
--- @return number  The BGR color value (0xBBGGRR).
--
function UI:RGB2BGR(RGB)
    local r = (RGB >> 16) & 0xFF
    local g = (RGB >> 8) & 0xFF 
    local b = RGB & 0xFF        
    return (b << 16) | (g << 8) | r 
end

--
--- ∑ Converts a BGR color to its RGB equivalent.
--- @param BGR number  The BGR color value (0xBBGGRR).
--- @return number  The RGB color value (0xRRGGBB).
--
function UI:BGR2RGB(BGR)
    local b = (BGR >> 16) & 0xFF  
    local g = (BGR >> 8) & 0xFF   
    local r = BGR & 0xFF          
    return (r << 16) | (g << 8) | b 
end

--
--- ∑ Searches for a token in a given scope.
--- @param scope table|string  The scope to search within.
--- @param token string  The token to search for.
--- @return boolean  True if the token is found, otherwise false.
--
function UI:TokenSearch(scope, token)
    if type(scope) == "table" then
        -- Try direct key lookup first if it's used as a set
        if scope[token] then
            return true
        end
        for i = 1, #scope do
            if scope[i] == token then
                return true
            end
        end
    elseif type(scope) == "string" then
        if scope == token or scope:find("%f[%w]" .. token .. "%f[%W]") then
            return true
        end
    end
    return false
end

--
--- ∑ Retrieves the color associated with a given token from a raw theme definition.
--- @param raw table  The raw theme data (decoded JSON).
--- @param token string  The token to look up.
--- @return number|nil  The color in BGR format, or nil if not found.
--
function UI:TokenColor(raw, token)
    local tokenColors = raw["tokenColors"]
    for _, item in ipairs(tokenColors) do
        if item["element"] == token and item["setting"] and item["setting"]["color"] then
            return item["setting"]["color"]:bgr()
        end
    end
    return nil
end

--
--- ∑ ...
--
function UI:ProcessThemeData(rawData, themeName)
    local tokens = self:GetThemeTokens()
    local processed = {}
    local missing, invalid = {}, {}
    for _, token in ipairs(tokens) do
        local color = self:TokenColor(rawData, token)
        if not color then
            table.insert(missing, token)
        elseif type(color) ~= "number" then
            table.insert(invalid, { token = token, value = tostring(color) })
        end
        processed[token] = color
    end
    if #missing > 0 then
        logger:Warning(("[UI] Theme '%s' is missing %d tokens: %s")
            :format(themeName, #missing, table.concat(missing, ", ")))
    end
    if #invalid > 0 then
        for _, entry in ipairs(invalid) do
            logger:Warning(("[UI] Invalid token in theme '%s': '%s' -> '%s' (Expected number)")
                :format(themeName, entry.token, entry.value))
        end
    end
    return processed
end
registerLuaFunctionHighlight('ProcessThemeData')

--
--- ∑ Loads a theme from a JSON file.
--- @param themeFile string  The file path of the theme.
--- @param isExternal boolean  True if the theme is external, false if internal.
--- @return void
--- @note 
--- - Reads the raw JSON data from the file (using ReadFromFileAsJson for external files or ReadFromTableFile for internal files).  
--- - Processes the theme data using UI:ProcessThemeData to map tokens to color values and logs missing or invalid tokens.  
--- - Stores the processed theme data in self.ThemeList under the theme name (with "(External)" appended for external themes).
--
function UI:LoadTheme(themeFile, isExternal)
    if not themeFile or themeFile == "" then
        logger:Error("[UI] Invalid file path passed.")
        return
    end
    local themeName = extractFileNameWithoutExt(themeFile:match("([^\\]+)$"))
    if isExternal then 
        themeName = themeName .. " (External)" 
    end
    logger:Info("[UI] Loading theme: '" .. themeName .. "'")
    local success, err = pcall(function()
        local rawData
        if isExternal then
            rawData, err = customIO:ReadFromFileAsJson(themeFile)
        else
            local fileData = customIO:ReadFromTableFile(themeFile)
            rawData, err = json:decode(fileData)
        end

        if not rawData then
            logger:Error("[UI] Failed to load theme: '" .. themeName .. "' - " .. (err or "Unknown error"))
            return
        end
        local processedData = self:ProcessThemeData(rawData, themeName)
        self.ThemeList[themeName] = processedData
        logger:Info("[UI] Theme '" .. themeName .. "' loaded successfully.")
    end)
    if not success then
        logger:Error("[UI] Error in LoadTheme for '" .. themeFile .. "': " .. tostring(err))
    end
end
registerLuaFunctionHighlight('LoadTheme')

--
--- ∑ Loads JSON theme files from the Data Directory.
--- @param jsonThemes table Table to store found theme file paths.
--- @return void
--- @note Reads each ".json" file and adds valid ones to the list.
--
function UI:LoadJsonThemesFromDataDir(jsonThemes)
    local dataDir = customIO.DataDir .. "\\Themes"
    local foundFiles = false
    local success, err = pcall(function()
        for file in lfs.dir(dataDir) do
            if file:match("%.json$") and file ~= "." and file ~= ".." then
                local filePath = dataDir .. "\\" .. file
                local themeData, readErr = customIO:ReadFromFileAsJson(filePath)
                if themeData then
                    table.insert(jsonThemes, { file = filePath, source = 'external' })
                    logger:Info("[UI] Found external JSON theme in Data Directory: '" .. filePath .. "'")
                    foundFiles = true
                else
                    logger:Warning("[UI] Skipped invalid JSON file '" .. filePath .. "': " .. tostring(readErr))
                end
            end
        end
    end)
    if not success then
        logger:Error("[UI] Error in LoadJsonThemesFromDataDir: " .. tostring(err))
    end
    if not foundFiles then
        logger:Warning("[UI] No JSON files found in Data Directory.")
    end
end
registerLuaFunctionHighlight('LoadJsonThemesFromDataDir')

--
--- ∑ Finalizes the theme loading process.
--- @param jsonThemes table Table of valid JSON file paths.
--- @return void
--- @note Loads themes from valid JSON files and logs success or failure.
--
function UI:FinalizeThemes(jsonThemes)
    if #jsonThemes == 0 then
        logger:Error("[UI] No valid JSON files found.")
        return
    end
    logger:Info("[UI] Found " .. #jsonThemes .. " valid themes.")
    for _, theme in ipairs(jsonThemes) do
        local themeFile = theme.file
        local isExternal = theme.source == 'external'
        local success, err = pcall(function()
            self:LoadTheme(themeFile, isExternal)
        end)
        if not success then
            logger:Error("[UI] Failed to load theme: '" ..
                         extractFileNameWithoutExt(themeFile) .. "' - " .. tostring(err))
        end
    end
end
registerLuaFunctionHighlight('FinalizeThemes')

--
--- ∑ Loads all available themes from the Table Menu.
--- @return void
--- @note Iterates over found JSON files and loads each theme.
--
function UI:LoadThemes()
    self.ThemeList = {}
    local jsonThemes = {}
    local success, err = pcall(function()
        if customIO:EnsureDataDirectory() then
            self:LoadJsonThemesFromDataDir(jsonThemes)
        end
        local tableMenuThemes = self:GetJsonThemesFromTableMenu()
        if tableMenuThemes then
            for _, theme in ipairs(tableMenuThemes) do
                table.insert(jsonThemes, { file = theme, source = 'internal' })
            end
        end
        self:FinalizeThemes(jsonThemes)
    end)
    if not success then
        logger:Error("[UI] Error in LoadThemes: " .. tostring(err))
    end
end
registerLuaFunctionHighlight('LoadThemes')

--
--- ∑ Retrieves a theme by its name. If not found, attempts to reload themes.
--- @param themeName string  The name of the theme.
--- @return table|nil  The theme data, or nil if not found.
--
function UI:GetTheme(themeName)
    local theme = self.ThemeList[themeName]
    if not theme then
        logger:Warning("[UI] Theme '" .. tostring(themeName) .. "' not found. Attempting to reload.")
        local success, err = pcall(function()
            self:LoadThemes()
        end)
        if not success then
            logger:Error("[UI] Error while reloading themes: " .. tostring(err))
            return nil
        end
        theme = self.ThemeList[themeName]
        if not theme then
            logger:Error("[UI] Theme '" .. tostring(themeName) .. "' could not be found after reload.")
            return nil
        end
    end
    return theme
end
registerLuaFunctionHighlight('GetTheme')

--
--- ∑ Applies the theme to the TreeView component.
--- @param theme table  The theme data.
--- @return void
--
function UI:ApplyThemeToTreeView(theme)
    local addressList = getAddressList()
    local treeView = addressList.Control[0]
    treeView.Color = theme["TreeView.Color"] or treeView.Color
    local font = createFont()
    font.Name = "Consolas"
    font.Color = theme["TreeView.Font.Color"] or font.Color
    treeView.Font = font
    logger:Info("[UI] Updated TreeView background color and font.")
end

--
--- ∑ Applies the theme to the Address List component.
--- @param theme table  The theme data.
--- @return void
--
function UI:ApplyThemeToAddressList(theme)
    local addressList = getAddressList()
    addressList.CheckboxColor = theme["AddressList.CheckboxColor"] or addressList.CheckboxColor
    addressList.CheckboxActiveColor = theme["AddressList.CheckboxActiveColor"] or addressList.CheckboxActiveColor
    addressList.CheckboxSelectedColor = theme["AddressList.CheckboxSelectedColor"] or addressList.CheckboxSelectedColor
    addressList.CheckboxActiveSelectedColor = theme["AddressList.CheckboxActiveSelectedColor"] or addressList.CheckboxActiveSelectedColor
    addressList.List.BackgroundColor = theme["AddressList.List.BackgroundColor"] or addressList.Control[0].BackgroundColor
    addressList.Header.Font.Color = theme["AddressList.Header.Font.Color"] or addressList.Header.Font.Color
    addressList.Header.Canvas.OnChange = function(self)
        self.brush.color = theme["AddressList.Header.Canvas.Brush.Color"] or self.brush.color
        self.pen.Color = theme["AddressList.Header.Canvas.Pen.Color"] or self.pen.Color
    end
    MainForm.repaint()
    logger:Info("[UI] Updated Address List Checkbox and List colors.")
end

--
--- ∑ Applies the theme to the Main Form.
--- @param theme table  The theme data.
--- @return void
--
function UI:ApplyThemeToMainForm(theme)
    local mainForm = getMainForm()
    mainForm.Foundlist3.Color = theme["MainForm.Foundlist3.Color"] or mainForm.Foundlist3.Color
    mainForm.Color = theme["MainForm.Color"] or mainForm.Color
    mainForm.Panel4.BevelColor = theme["MainForm.Panel4.BevelColor"] or mainForm.Panel4.BevelColor
    mainForm.lblSigned.Font.Color = theme["MainForm.lblSigned.Font.Color"] or mainForm.lblSigned.Font.Color
    mainForm.Splitter1.Color = theme["MainForm.Splitter1.Color"] or mainForm.Splitter1.Color
    local sloganStr = MainForm.findComponentByName("SLOGAN_STR")
    if sloganStr then
        sloganStr.Font.Color = theme["MainForm.SLOGAN_STR.Font.Color"] or sloganStr.Font.Color
        logger:Info("[UI] Updated 'SLOGAN_STR' font color.")
    end
    logger:Info("[UI] Updated Main Form colors.")
end

--
--- ∑ Determines the appropriate color for an address record based on its properties and the theme.
--- @param record table  The address record.
--- @param theme table  The theme data.
--- @param stringTypes table  Lookup table for string types.
--- @param integerTypes table  Lookup table for integer types.
--- @param floatTypes table  Lookup table for float types.
--- @return number  The color value to be applied.
--
function UI:GetRecordColor(record, theme, stringTypes, integerTypes, floatTypes)
    local token, color, reason
    if record.Type == vtAutoAssembler then
        token, color, reason = "Memrec.AutoAssembler.Color", theme["Memrec.AutoAssembler.Color"], "AutoAssembler Type"
    elseif record.IsAddressGroupHeader then
        token, color, reason = "Memrec.AddressGroupHeader.Color", theme["Memrec.AddressGroupHeader.Color"], "Address Group Header"
    elseif record.IsGroupHeader then
        token, color, reason = "Memrec.GroupHeader.Color", theme["Memrec.GroupHeader.Color"], "Group Header"
    elseif record.OffsetCount == 0 and not tonumber(record.AddressString, 16) then
        token, color, reason = "Memrec.UserDefined.Color", theme["Memrec.UserDefined.Color"] or theme["Memrec.DefaultForeground.Color"], "User-defined values"
    elseif record.ShowAsHex then
        token, color, reason = "Memrec.HexValues.Color", theme["Memrec.HexValues.Color"] or theme["Memrec.DefaultForeground.Color"], "Hex Values"
    elseif stringTypes[record.Type] then
        token, color, reason = "Memrec.StringType.Color", theme["Memrec.StringType.Color"], "String Type"
    elseif integerTypes[record.Type] then
        token, color, reason = "Memrec.IntegerType.Color", theme["Memrec.IntegerType.Color"], "Integer Type"
    elseif floatTypes[record.Type] then
        token, color, reason = "Memrec.FloatType.Color", theme["Memrec.FloatType.Color"], "Float Type"
    else
        token, color, reason = "Memrec.DefaultForeground.Color", theme["Memrec.DefaultForeground.Color"], "Default editor foreground"
    end
    local appliedColor = color or record.Color
    local recordName = record.Description or "<Unnamed Record>"
    -- Uncomment for debugging:
    -- logger:Debug(string.format("Determined Theme Color For Record: '%s' Reason: %s | Color: 0x%06X", record.Description or "<Unnamed Record>", reason, appliedColor))
    return appliedColor
end

--
--- ∑ Applies the theme to each address record in the Address List.
--- @param theme table  The theme data.
--- @return void
--
function UI:ApplyThemeToAddressRecords(theme)
    local addressList = getAddressList()
    local count = addressList.Count
    local updatedCount, skippedCount = 0, 0
    for i = 0, count - 1 do
        local record = addressList[i]
        local newColor = self:GetRecordColor(record, theme, STRING_TYPES, INTEGER_TYPES, FLOAT_TYPES)
        if record.Color ~= newColor then
            record.Color = newColor
            updatedCount = updatedCount + 1
        else
            skippedCount = skippedCount + 1
        end
    end
    logger:Info("[UI] Memrec Color Update complete: " .. updatedCount .. " updated, " .. skippedCount .. " (identical) skipped.")
end

--
--- ∑ Applies a specified theme to all UI components.
--- @param themeName string  The name of the theme to apply.
--- @param allowReapply boolean  (Optional) If true, forces reapplication even if the theme is already active.
--- @return void
--
function UI:ApplyTheme(themeName, allowReapply)
    local theme = self:GetTheme(themeName)
    if not theme then return end
    if self.ActiveTheme == themeName and not allowReapply then 
        logger:Warning("[UI] Theme '" .. themeName .. "' is already applied.")
        return
    end
    MainForm.Show()
    self:ApplyThemeToTreeView(theme)
    self:ApplyThemeToAddressList(theme)
    self:ApplyThemeToMainForm(theme)
    self:ApplyThemeToAddressRecords(theme)
    MainForm.repaint()
    self.ActiveTheme = themeName
    logger:Info("[UI] Theme '" .. themeName .. "' applied.")
end
registerLuaFunctionHighlight('ApplyTheme')

--
--- ∑ Deletes all subrecords (child memory records) of the given parent record.
---   Iterates through the subrecords and removes them one by one.
--- @param record userdata - The parent memory record whose subrecords will be deleted.
--
function UI:DeleteSubrecords(record)
    while record ~= nil and record.Count > 0 do
        memoryrecord_delete(record.Child[0])
    end
end

--
--- ∑ Updates the theme selector in the address list by removing any existing theme-related entries 
---   and dynamically adding memory records for each available theme.
--- @return void
--
function UI:UpdateThemeSelector()
    local addressList = getAddressList()
    local root = addressList.getMemoryRecordByDescription("[— UI : Theme Selector —] ()->")
    self:DeleteSubrecords(root)  -- Helper function to remove all child records

    for themeName, _ in pairs(self.ThemeList) do
        local mr = addressList.createMemoryRecord()
        mr.Type = vtAutoAssembler
        mr.Script =
            [[{$lua}
[ENABLE]
if syntaxcheck then return end
ui:ApplyTheme(memrec.Description)
utils:AutoDisable(memrec.ID)
[DISABLE]
]]
        mr.Description = themeName
        mr.Color = 0xFFFFF0
        mr.Parent = root
        -- mr.OnActivate = self.ToggleTrigger
        -- mr.OnDeactivate = self.ToggleTrigger
    end
end
registerLuaFunctionHighlight('UpdateThemeSelector')

--
--- ∑ Runs a function in the main thread if not already in the main thread.
--- @param func function The function to execute.
--
function UI:RunInMainThread(func)
    if type(func) ~= "function" then
        logger:Error("[UI] Invalid parameter for 'RunInMainThread'. Expected a function, got '%s'.", type(func))
        return
    end
    if inMainThread() then
        local success, result = pcall(func)
        if not success then
            logger:Error("[UI] Error while executing function in main thread: %s", result)
        end
    else
        local success, result = pcall(function()
            synchronize(func)
        end)
        if not success then
            logger:Error("[UI] Failed to synchronize function execution in main thread: %s", result)
        end
    end
end

--
--- ∑ Sets the visibility of a UI control.
--- @param controlName string  The name of the control.
--- @param isVisible boolean  Whether the control should be visible.
--- @return void
--
function UI:SetControlVisibility(controlName, isVisible)
    if MainForm and MainForm[controlName] then
        MainForm[controlName].Visible = isVisible
    end
end
registerLuaFunctionHighlight('SetControlVisibility')

--
--- ∑ Toggles the visibility of a UI control.
--- @param controlName string  The name of the control.
--- @return void
--
function UI:ToggleControlVisibility(controlName)
    self:RunInMainThread(function()
        if MainForm and MainForm[controlName] then
            MainForm[controlName].Visible = not MainForm[controlName].Visible
        end
    end)
end

--
--- ∑ Enables compact mode by hiding specific UI panels.
--- @return void
--
function UI:EnableCompactMode()
    self.CompactMode = true
    self:SetControlVisibility("Splitter1", false)
    self:SetControlVisibility("Panel5", false)
end
registerLuaFunctionHighlight('EnableCompactMode')

--
--- ∑ Disables compact mode by showing specific UI panels.
--- @return void
--
function UI:DisableCompactMode()
    self:RunInMainThread(function()
        self.CompactMode = false
        self:SetControlVisibility("Splitter1", true)
        self:SetControlVisibility("Panel5", true)
    end) 
end
registerLuaFunctionHighlight('DisableCompactMode')

--
--- ∑ Toggles compact mode.
--- @return void
--
function UI:ToggleCompactMode()
    self:RunInMainThread(function()
        self.CompactMode = not self.CompactMode
        self:ToggleControlVisibility("Panel5")
        self:ToggleControlVisibility("Splitter1")
    end)
end
registerLuaFunctionHighlight('ToggleCompactMode')

--
--- ∑ Toggles the visibility of signature-area-related controls.
--- @return void
--
function UI:ToggleSignatureControls()
    self:ToggleControlVisibility("CommentButton")
    self:ToggleControlVisibility("advancedbutton")
end
registerLuaFunctionHighlight('ToggleSignatureControls')

--
--- ∑ Hides the signature-area-related controls.
--- @return void
--
function UI:HideSignatureControls()
    self:SetControlVisibility("CommentButton", false)
    self:SetControlVisibility("advancedbutton", false)
end
registerLuaFunctionHighlight('HideSignatureControls')

--
--- ∑ Disables drag-and-drop functionality for the address list tree view.
--- @return void
--
function UI:DisableDragDrop()
    self:RunInMainThread(function()
        local addressListTreeview = component_getComponent(AddressList, 0) -- Disable drag and drop events
        setMethodProperty(addressListTreeview, "OnDragOver", nil)
        setMethodProperty(addressListTreeview, "OnDragDrop", nil)
        setMethodProperty(addressListTreeview, "OnEndDrag", nil)
    end)
end
registerLuaFunctionHighlight('DisableDragDrop')

--
--- ∑ Disables sorting functionality for the address list header.
--- @return void
--
function UI:DisableHeaderSorting()
    self:RunInMainThread(function()
        local addressListHeader = component_getComponent(AddressList, 1)
        setMethodProperty(addressListHeader, "OnSectionClick", nil)
    end)
end
registerLuaFunctionHighlight('DisableHeaderSorting')

--
--- ∑ Hides the bevel around the address list.
--- @return void
--
function UI:HideAddresslistBevel()
    if MainForm then
        AddressList.BevelOuter = "bvNone" -- AddressList; Original: bvRaised
    end
end
registerLuaFunctionHighlight('HideAddresslistBevel')

--
--- ∑ Creates or updates a label in the UI.
---   If the label does not exist, it is created with the specified parent and properties.
--- @param parent userdata - The parent container for the label.
--- @param label userdata|nil - The existing label to update, or nil to create a new one.
--- @param properties table - A table containing label properties such as alignment, font, and visibility.
--- @return userdata - The created or updated label.
--
function UI:CreateOrUpdateLabel(parent, label, properties)
    if not label then
        label = createLabel(parent)
        label.Align = properties.Align or alTop
        label.AutoSize = true
    end
    for key, value in pairs(properties) do
        if key == "Font" then
            for fontKey, fontValue in pairs(value) do
                label.Font[fontKey] = fontValue
            end
        else
            label[key] = value
        end
    end
    
    return label
end

--
--- ∑ Updates the text of an existing label or creates a new one if it does not exist.
---   Ensures thread safety by running in the main thread.
--- @param name string - The name of the label.
--- @param text string - The text content for the label.
--- @param properties table - A table of properties for the label.
--- @return None.
--
function UI:UpdateTextLabel(name, text, properties)
    self:RunInMainThread(function()
        local mainForm = getMainForm()
        local label = mainForm:findComponentByName(name)
        properties.Name = name
        properties.Caption = text or ""
        self[name] = self:CreateOrUpdateLabel(mainForm, label, properties)
    end)
end

--
--- ∑ Destroys a text label by name.
---   Ensures thread safety by running in the main thread.
--- @param name string - The name of the label to destroy.
--- @return None.
--
function UI:DestroyTextLabel(name)
    self:RunInMainThread(function()
        if self[name] then
            self[name]:destroy()
            self[name] = nil
        end
    end)
end

--
--- ∑ Creates a slogan text label in the UI.
---   If no text is provided, it uses the default `SloganStr`.
--- @param text string|nil - The slogan text to display.
--- @return None.
--
function UI:CreateSloganStr(text)
    self:UpdateTextLabel("SLOGAN_STR", text or self.SloganStr, {
        Alignment = "taCenter",
        Font = { Name = "Consolas", Size = 20, Style = "fsBold" },
        Visible = true
    })
end

--
--- ∑ Destroys the slogan text label.
--- @return None.
--
function UI:DestroySloganStr()
    self:DestroyTextLabel("SLOGAN_STR")
end

--
--- ∑ Updates or creates the signature text in the UI.
---   The signature is displayed in a predefined label (`lblSigned`).
--- @param str string|nil - The signature text to display.
--- @return None.
--
function UI:CreateSignatureStr(str)
    self:RunInMainThread(function()
        local lblSigned = getMainForm().lblSigned
        if lblSigned then
            lblSigned.Caption = str or self.SignatureStr or ""
            lblSigned.Visible = true
            lblSigned.BorderSpacing.Bottom = 5
            lblSigned.AutoSize = true
            lblSigned.Font.Name = "Consolas"
            lblSigned.Font.Size = 11
            lblSigned.Font.Style = "fsBold"
        end
        self.SignatureObj = lblSigned
    end)
end

--
--- ∑ Hides the signature text label.
--- @return None.
--
function UI:HideSignatureStr()
    self:RunInMainThread(function()
        if self.SignatureObj then
            self.SignatureObj.Visible = false
        end
    end)
end

--
--- ∑ Starts a text animation using a sequence of predefined effects.
---   Supports multiple animation types, cycling through them at defined intervals.
--- @param text string - The text to animate.
--- @param config table|nil - A table containing animation settings (animations list, interval, duration, pauses).
--- @return None.
--
function UI:StartTextAnimation(text, config)
    config = config or {}
    local animations = config.animations or { "Typing", "Reveal", "Scrolling", --[["Glitch",]] "Matrix" }
    local interval = config.interval or 100  
    local minDuration = config.minDuration or 5000  
    local pauseBetweenAnimations = config.pauseBetweenAnimations or 1000  

    local duration = math.max(#text * 200, minDuration)  
    local index = 1

    local animationFunctions = {
        Typing = function() self:TypingEffect(text, interval) end,
        Reveal = function() self:RevealEffect(text, interval) end,
        Scrolling = function() self:ScrollText(text, interval) end,
        Glitch = function() self:GlitchText(text, interval) end,
        Matrix = function() self:MatrixReveal(text, interval) end
    }

    local function CycleAnimations(timer)
        local selectedAnimation = animations[index]
        if animationFunctions[selectedAnimation] then
            animationFunctions[selectedAnimation]()
        end
        index = (index % #animations) + 1
    end

    if self.MainAnimationTimer then
        self.MainAnimationTimer.destroy()
    end

    self.MainAnimationTimer = createTimer(MainForm)
    self.MainAnimationTimer.Interval = duration + pauseBetweenAnimations
    self.MainAnimationTimer.OnTimer = CycleAnimations

    CycleAnimations(self.MainAnimationTimer)
end

--
--- ∑ Creates a timer that executes a callback at a specified interval.
--- @param interval number - The interval in milliseconds.
--- @param callback function - The function to execute on each tick.
--- @return userdata - The created timer object.
--
function UI:CreateTimer(interval, callback)
    local timer = createTimer(MainForm)
    timer.Interval = interval
    timer.OnTimer = callback
    return timer
end

--
--- ∑ Scrolls text horizontally in a loop for a given duration.
---   Each tick shifts the text by one character to create a scrolling effect.
--- @param text string - The text to scroll.
--- @param interval number|nil - The time in milliseconds between updates (default: 100ms).
--- @param maxTicks number|nil - The maximum number of scroll cycles (default: text length).
--- @return None.
--
function UI:ScrollText(text, interval, maxTicks)
    local function ScrollTextInner(text)
        return text:sub(2) .. text:sub(1, 1)
    end
    self.scrollingText = text .. " "
    self.scrollInterval = interval or 100  -- Default interval
    self.scrollMaxTicks = maxTicks or #self.scrollingText
    local function ScrollTextTimer_tick(timer)
        if self.scrollMaxTicks ~= 0 then
            self.scrollMaxTicks = self.scrollMaxTicks - 1
            if self.scrollMaxTicks <= 0 then
                timer.destroy()
                self:CreateSloganStr(text)
                return
            end
        end
        self.scrollingText = ScrollTextInner(self.scrollingText)
        self:CreateSloganStr(self.scrollingText)
    end
    if self.ScrollTextTimer then
        self.ScrollTextTimer.destroy()
    end
    self:CreateTimer(interval or 100, ScrollTextTimer_tick)
end

--
--- ∑ Displays a typing effect where text appears character by character.
--- @param text string - The text to type.
--- @param interval number|nil - The delay in milliseconds between each character (default: 100ms).
--- @return None.
--
function UI:TypingEffect(text, interval)
    local index = 1
    local function TypingTimer_tick(timer)
        if index > #text then
            timer.destroy()
            return
        end
        self:CreateSloganStr(text:sub(1, index))
        index = index + 1
    end
    self:CreateTimer(interval or 100, TypingTimer_tick)
end

--
--- ∑ Reveals text gradually by replacing placeholder characters with real ones.
--- @param text string - The text to reveal.
--- @param interval number|nil - The delay in milliseconds between updates (default: 100ms).
--- @return None.
--
function UI:RevealEffect(text, interval)
    local placeholders = { "#", "@", "%", "&", "?", "*", "!" }  -- Add more symbols if needed
    local revealStr = ""
    for i = 1, #text do
        revealStr = revealStr .. (text:sub(i, i) == " " and " " or placeholders[math.random(1, #placeholders)])
    end
    local index = 1
    local function RevealTimer_tick(timer)
        while index <= #text and text:sub(index, index) == " " do
            index = index + 1
        end
        if index > #text then
            timer.destroy()
            return
        end
        revealStr = revealStr:sub(1, index - 1) .. text:sub(index, index) .. revealStr:sub(index + 1)
        self:CreateSloganStr(revealStr)
        index = index + 1
    end
    self:CreateTimer(interval or 100, RevealTimer_tick)
end

--
--- ∑ Applies a glitch animation where random characters in the text change periodically.
---   The animation runs for a calculated duration based on text length.
--- @param text string - The text to glitch.
--- @param interval number|nil - The time in milliseconds between updates (default: 100ms).
--- @return None.
--
function UI:GlitchText(text, interval)
    local duration = math.max(#text * 100, 5000)
    local endTime = getTickCount() + duration
    local function GlitchTimer_tick(timer)
        if getTickCount() >= endTime then
            timer.destroy()
            self:CreateSloganStr(text)
            return
        end
        local glitchedText = {}
        for i = 1, #text do
            glitchedText[i] = text:sub(i, i)
        end
        for i = 1, math.random(1, #text // 3) do
            local pos
            repeat
                pos = math.random(1, #text)
            until text:sub(pos, pos) ~= " "
            
            glitchedText[pos] = string.char(math.random(33, 126))
        end
        self:CreateSloganStr(table.concat(glitchedText))
    end
    self:CreateTimer(interval or 100, GlitchTimer_tick)
end

--
--- ∑ Simulates a "Matrix-style" text reveal effect where characters gradually appear.
--- @param text string - The text to reveal.
--- @param interval number|nil - The delay in milliseconds between updates (default: 100ms).
--- @return None.
--
function UI:MatrixReveal(text, interval)
    local revealStr = {}
    for i = 1, #text do
        revealStr[i] = text:sub(i, i) == " " and " " or "#"
    end
    local revealed = table.concat(revealStr)
    local function MatrixTimer_tick(timer)
        if revealed == text then
            timer.destroy()
            return
        end
        local pos
        repeat
            pos = math.random(1, #text)
        until revealStr[pos] ~= text:sub(pos, pos) and text:sub(pos, pos) ~= " "
        revealStr[pos] = text:sub(pos, pos)
        revealed = table.concat(revealStr)
        self:CreateSloganStr(revealed)
    end
    self:CreateTimer(interval or 100, MatrixTimer_tick)
end

--
--- ∑ Initializes the Cheat Engine UI.
---   Configures the UI appearance, slogan, signature, and theme.
--- @return None.
--
function UI:InitializeForm()
    MainForm.Show()
    -- ........................
    self:EnableCompactMode()
    self:HideAddresslistBevel()
    self:DisableHeaderSorting()
    self:HideSignatureControls()
    -- ........................
    self:CreateSloganStr(self.SloganStr)
    self:CreateSignatureStr(self.SignatureStr)
    -- ........................
    self:LoadThemes()
    self:ApplyTheme(self.Theme)
end

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return UI