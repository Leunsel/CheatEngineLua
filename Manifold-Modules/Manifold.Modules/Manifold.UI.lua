local NAME = "Manifold.UI.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.5"
local DESCRIPTION = "Manifold Framework UI"
 --

--[[
    ∂ v1.0.5 (2026-06-17)
        Added Manifold.Forms integration for live theming of registered forms.
        Requires Manifold.Forms for Theme Creator UI control generation.
        Removed legacy CE-control fallback builders from the Theme Creator path.
        Corrected minor logging inconsistencies.
]] 

UI = {
    ThemeList = {},
    ActiveTheme = nil,
    CompactMode = false,
    IsApplyingTheme = false,
    ThemeApplyLockTimeoutMs = 8000,
    -- Setup
    Theme = "",
    SloganStr = "",
    SignatureStr = ""
}
UI.__index = UI

--
--- ∑ Compares two version strings to determine if the current version meets or exceeds the required version.
--- @param current string # The current version string (e.g., "1.0.5").
--- @param required string # The required version string to compare against (e.g., "1.0.0").
--- @return boolean # True if the current version is greater than or equal to the required version, otherwise false.
--- @note The function splits the version strings into their numeric components and compares them sequentially. It handles versions of different lengths by treating missing components as zero.
--
local function _VersionAtLeast(current, required)
    local currentParts = {}
    local requiredParts = {}
    for part in tostring(current or ""):gmatch("%d+") do
        currentParts[#currentParts + 1] = tonumber(part) or 0
    end
    for part in tostring(required or ""):gmatch("%d+") do
        requiredParts[#requiredParts + 1] = tonumber(part) or 0
    end
    local count = math.max(#currentParts, #requiredParts)
    for index = 1, count do
        local currentPart = currentParts[index] or 0
        local requiredPart = requiredParts[index] or 0
        if currentPart > requiredPart then return true end
        if currentPart < requiredPart then return false end
    end
    return true
end

local THEME_APPLY_LOCK = rawget(_G, "__ManifoldThemeApplyLock")
if type(THEME_APPLY_LOCK) ~= "table" then
    THEME_APPLY_LOCK = {
        Active = false,
        Token = nil,
        ThemeName = nil,
        StartedAt = 0,
    }
    rawset(_G, "__ManifoldThemeApplyLock", THEME_APPLY_LOCK)
end

--
--- ∑ Returns a millisecond timestamp for lightweight runtime locks.
--- @returns integer # A monotonic-ish timestamp in milliseconds.
--
local function _ThemeLockNow()
    if type(getTickCount64) == "function" then
        local ok, value = pcall(getTickCount64)
        if ok and value then return value end
    end
    if type(getTickCount) == "function" then
        local ok, value = pcall(getTickCount)
        if ok and value then return value end
    end
    return math.floor((os.clock() or 0) * 1000)
end

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
registerLuaFunctionHighlight("New")

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table  {name, version, author, description}
--
function UI:GetModuleInfo()
    return {name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION}
end
registerLuaFunctionHighlight("GetModuleInfo")

--
--- ∑ Prints module details in a readable formatted block.
--
function UI:PrintModuleInfo()
    local info = self:GetModuleInfo()
    if not info then
        logger:Info("[UI] Failed to retrieve module info.")
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

-- Predefined type tables for faster lookups
local STRING_TYPES = {[vtString] = true, [vtUnicodeString] = true}
local INTEGER_TYPES = {[vtByte] = true, [vtWord] = true, [vtDword] = true, [vtQword] = true}
local FLOAT_TYPES = {[vtSingle] = true, [vtDouble] = true}

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

UI.TokenDescriptions = {
    ["TreeView.Color"] = "Not used. Use AddressList instead.",
    ["TreeView.Font.Color"] = "Not used. Use AddressList instead.",
    ["AddressList.CheckboxColor"] = "Outline of unchecked boxes",
    ["AddressList.CheckboxActiveColor"] = "Fill of checked boxes",
    ["AddressList.CheckboxSelectedColor"] = "Outline of selected boxes",
    ["AddressList.CheckboxActiveSelectedColor"] = "Fill of checked + selected",
    ["AddressList.List.BackgroundColor"] = "Background of address list",
    ["AddressList.Header.Font.Color"] = "Font color of list header",
    ["AddressList.Header.Canvas.Brush.Color"] = "Background of list header",
    ["AddressList.Header.Canvas.Pen.Color"] = "Border of list header",
    ["MainForm.Color"] = "Background of main window",
    ["MainForm.Foundlist3.Color"] = "Background of scan result list",
    ["MainForm.Panel4.BevelColor"] = "Bevel color of bottom panel",
    ["MainForm.lblSigned.Font.Color"] = "Font color of signed label",
    ["MainForm.Splitter1.Color"] = "Color of splitter line",
    ["MainForm.SLOGAN_STR.Font.Color"] = "Font color of slogan label",
    ["Memrec.AutoAssembler.Color"] = "Color of AA script entries",
    ["Memrec.AddressGroupHeader.Color"] = "Color of group headers (old)",
    ["Memrec.GroupHeader.Color"] = "Color of group headers",
    ["Memrec.UserDefined.Color"] = "Font for user-defined types",
    ["Memrec.HexValues.Color"] = "Font for hex value entries",
    ["Memrec.StringType.Color"] = "Font for string entries",
    ["Memrec.IntegerType.Color"] = "Font for integer entries",
    ["Memrec.FloatType.Color"] = "Font for float entries",
    ["Memrec.DefaultForeground.Color"] = "Fallback/default font color"
}

--
--- ∑ Checks if all required dependencies are loaded, and loads them if necessary.
--- @return # void
--- @note Checks for 'json' as well as "customIO" and loads them if not already present.
--
function UI:CheckDependencies()
    local function depLog(level, message)
        if logger and logger[level] then
            logger[level](logger, message)
        end
    end
    local dependencies = {
        {name = "logger", path = "Manifold.Logger", init = function()
                logger = Logger:New()
            end},
        {name = "json", path = "Manifold.Json", init = function()
                json = JSON:new()
            end},
        {name = "customIO", path = "Manifold.CustomIO", init = function()
                customIO = CustomIO:New()
            end},
        {name = "forms", path = "Manifold.Forms", init = function()
                forms = Forms:New()
            end}
    }
    for _, dep in ipairs(dependencies) do
        local depName = dep.name
        if _G[depName] == nil then
            depLog("Warning", "[UI] '" .. depName .. "' dependency not found. Attempting to load...")
            local success, result = pcall(CETrequire, dep.path)
            if success then
                if dep.init then
                    dep.init()
                end
                depLog("Info", "[UI] Loaded dependency '" .. depName .. "'.")
            else
                depLog("Error", "[UI] Failed to load dependency '" .. depName .. "': " .. tostring(result))
            end
        else
            depLog("Debug", "[UI] Dependency '" .. depName .. "' is already loaded")
        end
    end
    if _VersionAtLeast(VERSION, "1.0.5") and not (forms and type(forms.CreatePanel) == "function") then
        local message = "[UI] As of Version 1.0.5, Manifold.Forms is required to generate the UI-Components."
        depLog("Error", message)
        error(message, 2)
    end
end

--
--- ∑ Ensures that the Theme Directory exists within the Data Directory.
--- @return string|nil # The full path to the Theme Directory, or nil if creation failed.
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
registerLuaFunctionHighlight("EnsureThemeDirectory")

--
--- ∑ Initializes the Table Menu component from the MainForm.
--- @return # void
--- @note Logs an error if the component is missing.
--
function UI:InitializeTableMenu()
    local success, err =
        pcall(
        function()
            local tableMenu = MainForm.findComponentByName("miTable")
            if not tableMenu then
                logger:Critical("[UI] Missing 'miTable' component. Can't load themes.")
                return
            end
            tableMenu.doClick()
            logger:Info("[UI] 'miTable' content loaded.")
        end
    )
    if not success then
        logger:Error("[UI] Error in InitializeTableMenu: " .. tostring(err))
    end
end
registerLuaFunctionHighlight("InitializeTableMenu")

--
--- ∑ Retrieves JSON theme file names from the Table Menu component.
--- @return table|nil # A table of JSON file names, or nil if none found.
--
function UI:GetJsonThemesFromTableMenu()
    local jsonThemes = {}
    local success, err =
        pcall(
        function()
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
        end
    )
    if not success then
        logger:Error("[UI] Error in GetJsonThemesFromTableMenu: " .. tostring(err))
    end
    return #jsonThemes > 0 and jsonThemes or nil
end
registerLuaFunctionHighlight("GetJsonThemesFromTableMenu")

--
--- ∑ Retrieves the list of theme tokens.
--- @return table # The theme tokens list.
--
function UI:GetThemeTokens()
    return self.ThemeTokens
end

--
--- ∑ Converts a hex color string to BGR format.
--- @return number # The BGR color value.
--
function string:bgr()
    local hexColorString = self:sub(2, 7)
    local RGB = tonumber(hexColorString, 16)
    return UI:RGB2BGR(RGB)
end

--
--- ∑ Converts an RGB color to its BGR equivalent.
--- @param RGB number # The RGB color value (0xRRGGBB).
--- @return number # The BGR color value (0xBBGGRR).
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
--- @param scope table|string # The scope to search within.
--- @param token string # The token to search for.
--- @return boolean # True if the token is found, otherwise false.
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
--- @param raw table # The raw theme data (decoded JSON).
--- @param token string # The token to look up.
--- @return number|nil # The color in BGR format, or nil if not found.
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
            table.insert(invalid, {token = token, value = tostring(color)})
        end
        processed[token] = color
    end
    if #missing > 0 then
        logger:Warning(
            ("[UI] Theme '%s' is missing %d tokens: %s"):format(themeName, #missing, table.concat(missing, ", "))
        )
    end
    if #invalid > 0 then
        for _, entry in ipairs(invalid) do
            logger:Warning(
                ("[UI] Invalid token in theme '%s': '%s' -> '%s' (Expected number)"):format(
                    themeName,
                    entry.token,
                    entry.value
                )
            )
        end
    end
    return processed
end
registerLuaFunctionHighlight("ProcessThemeData")

--
--- ∑ Loads a theme from a JSON file.
--- @param themeFile string # The file path of the theme.
--- @param isExternal boolean # True if the theme is external, false if internal.
--- @return # void
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
    local success, err =
        pcall(
        function()
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
        end
    )
    if not success then
        logger:Error("[UI] Error in LoadTheme for '" .. themeFile .. "': " .. tostring(err))
    end
end
registerLuaFunctionHighlight("LoadTheme")

--
--- ∑ Loads JSON theme files from the Data Directory.
--- @param jsonThemes table # Table to store found theme file paths.
--- @return # void
--- @note Reads each ".json" file and adds valid ones to the list.
--
function UI:LoadJsonThemesFromDataDir(jsonThemes)
    local dataDir = customIO.DataDir .. "\\Themes"
    local foundFiles = false
    local success, err =
        pcall(
        function()
            for file in lfs.dir(dataDir) do
                if file:match("%.json$") and file ~= "." and file ~= ".." then
                    local filePath = dataDir .. "\\" .. file
                    local themeData, readErr = customIO:ReadFromFileAsJson(filePath)
                    local trimmedPath = filePath:match("[\\/](Manifold[\\/].*)") or filePath
                    if themeData then
                        table.insert(jsonThemes, {file = filePath, source = "external"})
                        logger:Info("[UI] Found external JSON theme in Data Directory: '...\\" .. trimmedPath .. "'")
                        foundFiles = true
                    else
                        logger:Warning("[UI] Skipped invalid JSON file '" .. trimmedPath .. "': " .. tostring(readErr))
                    end
                end
            end
        end
    )
    if not success then
        logger:Error("[UI] Error in LoadJsonThemesFromDataDir: " .. tostring(err))
    end
    if not foundFiles then
        logger:Warning("[UI] No JSON files found in Data Directory.")
    end
end
registerLuaFunctionHighlight("LoadJsonThemesFromDataDir")

--
--- ∑ Finalizes the theme loading process.
--- @param jsonThemes table # Table of valid JSON file paths.
--- @return # void
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
        local isExternal = theme.source == "external"
        local success, err =
            pcall(
            function()
                self:LoadTheme(themeFile, isExternal)
            end
        )
        if not success then
            logger:Error(
                "[UI] Failed to load theme: '" .. extractFileNameWithoutExt(themeFile) .. "' - " .. tostring(err)
            )
        end
    end
end
registerLuaFunctionHighlight("FinalizeThemes")

--
--- ∑ Loads all available themes from the Table Menu.
--- @return # void
--- @note Iterates over found JSON files and loads each theme.
--
function UI:LoadThemes()
    self.ThemeList = {}
    local jsonThemes = {}
    local success, err =
        pcall(
        function()
            if customIO:EnsureDataDirectory() then
                self:LoadJsonThemesFromDataDir(jsonThemes)
            end
            local tableMenuThemes = self:GetJsonThemesFromTableMenu()
            if tableMenuThemes then
                for _, theme in ipairs(tableMenuThemes) do
                    table.insert(jsonThemes, {file = theme, source = "internal"})
                end
            end
            self:FinalizeThemes(jsonThemes)
        end
    )
    if not success then
        logger:Error("[UI] Error in LoadThemes: " .. tostring(err))
    end
end
registerLuaFunctionHighlight("LoadThemes")

--
--- ∑ Retrieves a theme by its name. If not found, attempts to reload themes.
--- @param themeName string # The name of the theme.
--- @return table|nil # The theme data, or nil if not found.
--
function UI:GetTheme(themeName)
    local theme = self.ThemeList[themeName]
    if not theme then
        logger:Warning("[UI] Theme '" .. tostring(themeName) .. "' not found. Attempting to reload.")
        local success, err =
            pcall(
            function()
                self:LoadThemes()
            end
        )
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
registerLuaFunctionHighlight("GetTheme")

--
--- ∑ Applies the theme to the TreeView component.
--- @param theme table # The theme data.
--- @return # void
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
--- @param theme table # The theme data.
--- @return # void
--
function UI:ApplyThemeToAddressList(theme)
    local addressList = getAddressList()
    addressList.CheckboxColor = theme["AddressList.CheckboxColor"] or addressList.CheckboxColor
    addressList.CheckboxActiveColor = theme["AddressList.CheckboxActiveColor"] or addressList.CheckboxActiveColor
    addressList.CheckboxSelectedColor = theme["AddressList.CheckboxSelectedColor"] or addressList.CheckboxSelectedColor
    addressList.CheckboxActiveSelectedColor =
        theme["AddressList.CheckboxActiveSelectedColor"] or addressList.CheckboxActiveSelectedColor
    addressList.List.BackgroundColor =
        theme["AddressList.List.BackgroundColor"] or addressList.Control[0].BackgroundColor
    addressList.Header.Font.Color = theme["AddressList.Header.Font.Color"] or addressList.Header.Font.Color
    addressList.Header.Canvas.OnChange = function(self)
        self.brush.color = theme["AddressList.Header.Canvas.Brush.Color"] or self.brush.color
        self.pen.Color = theme["AddressList.Header.Canvas.Pen.Color"] or self.pen.Color
    end
    MainForm.repaint()
    logger:Info("[UI] Updated Address List Checkbox and List colors.")
end

--
--- ∑ Applies the theme to the Lua Engine controls.
--- @param luaEngine table # The Lua Engine instance.
--- @param theme table # The theme data.
--- @return # void
--
function UI:ApplyThemeToLuaEngineControls(luaEngine, theme)
    local mainColor = theme["MainForm.Color"] or luaEngine.Color
    local headerFontColor = theme["AddressList.Header.Font.Color"] or luaEngine.mOutput.Font.Color
    local foundlistColor = theme["MainForm.Foundlist3.Color"] or mainColor

    luaEngine.Caption = "[Manifold] Logger"
    luaEngine.Color = mainColor
    luaEngine.mScript.Color = mainColor
    luaEngine.mOutput.Color = mainColor
    luaEngine.mOutput.Font.Name = "Consolas"
    luaEngine.mOutput.Font.Color = headerFontColor
    luaEngine.mOutput.BorderStyle = "bsNone"
    luaEngine.mOutput.ScrollBars = "ssAuto"
    luaEngine.mOutput.Visible = true
    luaEngine.mScript.BorderStyle = "bsNone"
    luaEngine.mScript.ScrollBars = "ssNone"
    luaEngine.mScript.Gutter.Color = mainColor

    local gutter = luaEngine.mScript.SynLeftGutterPartList1
    if gutter then
        local gutterText = gutter.SynGutterLineNumber1.MarkupInfo
        gutterText.Foreground = headerFontColor
        gutterText.Background = mainColor
        if gutter.SynGutterSeparator1 then
            gutter.SynGutterSeparator1.Visible = false
        end
    end

    if Manifold.Setup.IsRelease then
        if luaEngine.Panel1 then luaEngine.Panel1.Visible = false end
        if luaEngine.Splitter1 then luaEngine.Splitter1.Visible = false end
    else
        if luaEngine.Panel1 then luaEngine.Panel1.Visible = true end
        if luaEngine.Splitter1 then luaEngine.Splitter1.Visible = true end
    end

    if luaEngine.GroupBox1 then
        luaEngine.GroupBox1.Visible = false
        luaEngine.mOutput.Align = luaEngine.GroupBox1.Align
    end

    luaEngine.mOutput.Parent = luaEngine
    luaEngine.mScript.RightEdge = -1
end

--
--- ∑ Creates or updates the Lua Engine Execute panel.
--- @param luaEngine table # The Lua Engine instance.
--- @param foundlistColor number # The color for the found list.
--- @param headerFontColor number # The font color for the header.
--- @param o_LuaEngine_btnExecute_OnClick function # The original OnClick handler for the Execute button.
--- @return # void
--
function UI:CreateOrUpdateLuaEngineExecutePanel(luaEngine, foundlistColor, headerFontColor, mainColor, o_LuaEngine_btnExecute_OnClick)
    if not btnExecutePanel then
        btnExecutePanel = createPanel(luaEngine.Panel3)
        btnExecutePanel.Name = "btnExecutePanel"
        btnExecutePanel.Align = "alCenter"
        btnExecutePanel.Height = 25
        btnExecutePanel.BevelOuter = bvRaised
        btnExecutePanel.BevelWidth = 1
        btnExecutePanel.Color = foundlistColor
        btnExecutePanel.Cursor = -21 -- crHandPoint
        btnExecutePanel.Caption = "Execute"
        btnExecutePanel.BorderSpacing.Around = 3
        btnExecutePanel.BorderColor = 0xFF0000
        btnExecutePanel.OnClick = function()
            if o_LuaEngine_btnExecute_OnClick then
                o_LuaEngine_btnExecute_OnClick(luaEngine.btnExecute)
            end
        end
        luaEngine.btnExecute.Visible = false
    end
    btnExecutePanel.OnMouseEnter = function()
        btnExecutePanel.Color = headerFontColor
        btnExecutePanel.Font.Color = mainColor
    end
    btnExecutePanel.OnMouseLeave = function()
        btnExecutePanel.Color = mainColor
        btnExecutePanel.Font.Color = headerFontColor
    end
    btnExecutePanel.Color = mainColor
    btnExecutePanel.Font.Color = headerFontColor
end

local o_LuaEngine_btnExecute_OnClick = getLuaEngine().btnExecute.OnClick
--
----- ∑ Applies the theme to the Lua Engine component.
--- @param theme table # The theme data.
--- @return # void
-- @note This function applies the theme to the Lua Engine controls and creates or updates the execute panel.
--
function UI:ApplyThemeToLuaEngine(theme)
    if not inMainThread() then
        synchronize(function() self:ApplyThemeToLuaEngine(theme) end)
        return
    end
    local luaEngine = getLuaEngine()
    if not luaEngine then
        logger:Warning("[UI] Lua Engine not initialized. Cannot apply theme.")
        return
    end
    local mainColor = theme["MainForm.Color"] or luaEngine.Color
    local headerFontColor = theme["AddressList.Header.Font.Color"] or luaEngine.mOutput.Font.Color
    local foundlistColor = theme["MainForm.Foundlist3.Color"] or mainColor

    self:ApplyThemeToLuaEngineControls(luaEngine, theme)
    -- Edge case of the Lua Engine already being present due to autorun scripts for example...
    -- We need to apply the theme a second time!
    self:ApplyThemeToLuaEngineControls(luaEngine, theme)
    self:CreateOrUpdateLuaEngineExecutePanel(luaEngine, foundlistColor, headerFontColor, mainColor, o_LuaEngine_btnExecute_OnClick)
end

--
--- ∑ Applies the theme to the Main Form.
--- @param theme table # The theme data.
--- @return # void
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
--- @param record table # The address record.
--- @param theme table # The theme data.
--- @param stringTypes table # Lookup table for string types.
--- @param integerTypes table # Lookup table for integer types.
--- @param floatTypes table # Lookup table for float types.
--- @return number # The color value to be applied.
--
function UI:GetRecordColor(record, theme, stringTypes, integerTypes, floatTypes)
    local token, color, reason
    if record.Type == vtAutoAssembler then
        token, color, reason = "Memrec.AutoAssembler.Color", theme["Memrec.AutoAssembler.Color"], "AutoAssembler Type"
    elseif record.IsAddressGroupHeader then
        token, color, reason =
            "Memrec.AddressGroupHeader.Color",
            theme["Memrec.AddressGroupHeader.Color"],
            "Address Group Header"
    elseif record.IsGroupHeader then
        token, color, reason = "Memrec.GroupHeader.Color", theme["Memrec.GroupHeader.Color"], "Group Header"
    elseif record.OffsetCount == 0 and not tonumber(record.AddressString, 16) then
        token, color, reason =
            "Memrec.UserDefined.Color",
            theme["Memrec.UserDefined.Color"] or theme["Memrec.DefaultForeground.Color"],
            "User-defined values"
    elseif record.ShowAsHex then
        token, color, reason =
            "Memrec.HexValues.Color",
            theme["Memrec.HexValues.Color"] or theme["Memrec.DefaultForeground.Color"],
            "Hex Values"
    elseif stringTypes[record.Type] then
        token, color, reason = "Memrec.StringType.Color", theme["Memrec.StringType.Color"], "String Type"
    elseif integerTypes[record.Type] then
        token, color, reason = "Memrec.IntegerType.Color", theme["Memrec.IntegerType.Color"], "Integer Type"
    elseif floatTypes[record.Type] then
        token, color, reason = "Memrec.FloatType.Color", theme["Memrec.FloatType.Color"], "Float Type"
    else
        token, color, reason =
            "Memrec.DefaultForeground.Color",
            theme["Memrec.DefaultForeground.Color"],
            "Default editor foreground"
    end
    local appliedColor = color or record.Color
    local recordName = record.Description or "<Unnamed Record>"
    -- Uncomment for debugging:
    -- logger:Debug(string.format("Determined Theme Color For Record: '%s' Reason: %s | Color: 0x%06X", record.Description or "<Unnamed Record>", reason, appliedColor))
    return appliedColor
end

--
--- ∑ Applies the theme to each address record in the Address List.
--- @param theme table # The theme data.
--- @return # void
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
    logger:Info(
        "[UI] Memrec Color Update complete: " .. updatedCount .. " updated, " .. skippedCount .. " (identical) skipped."
    )
end

--
--- ∑ Sets all Teleporter UI control colors/fonts from host theme tokens.
---   All Teleporter theming is centralized here so themes can be reapplied live.
--- @param uiState table # The Teleporter UI state.
--- @param theme table # The processed theme token table.
--
function UI:SetTeleporterControlColors(uiState, theme)
    if not uiState or type(theme) ~= "table" then
        return
    end
    local mainBg = theme["MainForm.Color"]
    local panelBg = theme["MainForm.Foundlist3.Color"] or mainBg
    local headerBg = theme["AddressList.Header.Canvas.Brush.Color"] or panelBg
    local borderColor = theme["AddressList.Header.Canvas.Pen.Color"] or theme["MainForm.Panel4.BevelColor"]
    local inputBg = theme["AddressList.List.BackgroundColor"] or panelBg
    local inputText = theme["TreeView.Font.Color"] or theme["AddressList.Header.Font.Color"] or theme["Memrec.DefaultForeground.Color"]
    local labelText = theme["Memrec.DefaultForeground.Color"] or theme["AddressList.Header.Font.Color"]
    local mutedText = theme["Memrec.GroupHeader.Color"] or labelText
    local buttonBg = headerBg
    local buttonHover = theme["AddressList.CheckboxActiveColor"] or borderColor or buttonBg
    local buttonText = labelText
    local buttonHoverText = mainBg or buttonText
    local function repaintControl(control)
        if not control then return end
        if control.repaint then
            control:repaint()
        elseif control.Repaint then
            control:Repaint()
        end
    end
    local function applyFont(control, color, size, style)
        if not control or not control.Font then return end
        control.Font.Name = "Consolas"
        control.Font.Size = size or 10
        if color ~= nil then control.Font.Color = color end
        if style ~= nil then control.Font.Style = style end
    end
    local function setBevel(control, outer, color, width)
        if not control then return end
        if outer ~= nil then control.BevelOuter = outer end
        if color ~= nil and control.BevelColor ~= nil then control.BevelColor = color end
        if width ~= nil and control.BevelWidth ~= nil then control.BevelWidth = width end
    end
    local function setPanel(control, color)
        if not control then return end
        control.ParentColor = false
        if color ~= nil then control.Color = color end
        repaintControl(control)
    end
    local function setLabel(control, color, size, style)
        if not control then return end
        applyFont(control, color, size, style)
        repaintControl(control)
    end
    local function setEdit(control)
        if not control then return end
        control.ParentColor = false
        control.Color = inputBg or control.Color
        control.BorderStyle = "bsNone"
        applyFont(control, inputText, 10)
        repaintControl(control)
    end
    local function setMemo(control)
        if not control then return end
        control.ParentColor = false
        control.Color = inputBg or control.Color
        control.BorderStyle = "bsNone"
        applyFont(control, inputText, 10)
        repaintControl(control)
    end
    local function setButton(control)
        if not control then return end
        control.ParentColor = false
        control.Color = buttonBg or control.Color
        setBevel(control, "bvRaised", borderColor, 1)
        if control._theme and type(control._theme) == "table" then
            control._theme.COLOR_BTN = buttonBg
            control._theme.COLOR_BTN_HOVER = buttonHover
            control._theme.COLOR_BTN_TEXT = buttonText
            control._theme.COLOR_BG = buttonHoverText
            control._theme.COLOR_BORDER = borderColor
        end
        applyFont(control, buttonText, 10, "[fsBold]")
        if control._label then
            applyFont(control._label, buttonText, 10, "[fsBold]")
        end
        repaintControl(control)
    end
    setPanel(uiState.Form, mainBg)
    setPanel(uiState.RootPanel, mainBg)
    setPanel(uiState.ToolbarPanel, panelBg)
    setPanel(uiState.StatusPanel, borderColor)
    setPanel(uiState.StatusInnerPanel, panelBg)
    setPanel(uiState.LeftPanel, borderColor)
    setPanel(uiState.LeftInnerPanel, panelBg)
    setPanel(uiState.LeftHeaderPanel, headerBg)
    setBevel(uiState.LeftHeaderPanel, "bvLowered", borderColor, 1)
    setPanel(uiState.LeftContentPanel, panelBg)
    setPanel(uiState.RightPanel, borderColor)
    setPanel(uiState.RightInnerPanel, panelBg)
    setPanel(uiState.RightHeaderPanel, headerBg)
    setBevel(uiState.RightHeaderPanel, "bvLowered", borderColor, 1)
    setPanel(uiState.RightContentPanel, panelBg)
    setPanel(uiState.EditorPanel, borderColor)
    setPanel(uiState.TreePanel, borderColor)
    setPanel(uiState.SearchPanel, borderColor)
    setBevel(uiState.SearchPanel, "bvRaised", borderColor, 1)
    setPanel(uiState.SearchFillPanel, inputBg)
    setPanel(uiState.SearchInnerPanel, inputBg)
    setPanel(uiState.TreeBorderPanel, borderColor)
    setBevel(uiState.TreeBorderPanel, "bvRaised", borderColor, 1)
    setPanel(uiState.TreeHostPanel, inputBg)
    setPanel(uiState.FieldsHostPanel, panelBg)
    setPanel(uiState.TopGroupPanel, panelBg)
    setPanel(uiState.BottomGroupPanel, panelBg)
    setPanel(uiState.FooterPanel, panelBg)
    setBevel(uiState.FooterPanel, "bvLowered", borderColor, 1)
    setPanel(uiState.MemoBorderPanel, borderColor)
    setBevel(uiState.MemoBorderPanel, "bvRaised", borderColor, 1)
    setPanel(uiState.MemoPanel, inputBg)
    setBevel(uiState.MemoPanel, "bvLowered", borderColor, 1)
    setPanel(uiState.MemoInnerPanel, inputBg)
    for _, key in ipairs({"Name","Author","Category","X","Y","Z"}) do
        setPanel(uiState[key .. "Row"], panelBg)
        setPanel(uiState[key .. "Border"], borderColor)
        setBevel(uiState[key .. "Border"], "bvRaised", borderColor, 1)
        setPanel(uiState[key .. "Fill"], inputBg)
        setPanel(uiState[key .. "Inner"], inputBg)
    end
    setLabel(uiState.StatusLabel, labelText, 10)
    setLabel(uiState.TreeStatsLabel, mutedText, 9)
    setLabel(uiState.TreeHeaderLabel, labelText, 10, "[fsBold]")
    setLabel(uiState.EditorHeaderLabel, labelText, 10, "[fsBold]")
    setLabel(uiState.NameLabel, labelText, 10, "[fsBold]")
    setLabel(uiState.AuthorLabel, labelText, 10, "[fsBold]")
    setLabel(uiState.CategoryLabel, labelText, 10, "[fsBold]")
    setLabel(uiState.XLabel, labelText, 10, "[fsBold]")
    setLabel(uiState.YLabel, labelText, 10, "[fsBold]")
    setLabel(uiState.ZLabel, labelText, 10, "[fsBold]")
    setEdit(uiState.NameEdit)
    setEdit(uiState.AuthorEdit)
    setEdit(uiState.CategoryEdit)
    setEdit(uiState.XEdit)
    setEdit(uiState.YEdit)
    setEdit(uiState.ZEdit)
    setEdit(uiState.SearchEdit)
    setMemo(uiState.DescriptionEdit)
    for _, key in ipairs({"SaveButton","LoadButton","DeleteButton","RefreshButton","WaypointButton","AddButton","DuplicateButton","TeleportButton","UpdateButton","ClearButton","RenameButton","UseCurrentPositionButton"}) do
        setButton(uiState[key])
    end
    if uiState.TreeView then
        uiState.TreeView.ParentColor = false
        uiState.TreeView.Color = theme["TreeView.Color"] or inputBg or uiState.TreeView.Color
        applyFont(uiState.TreeView, inputText, 10)
        repaintControl(uiState.TreeView)
    end
end
registerLuaFunctionHighlight("SetTeleporterControlColors")

--
--- ∑ Applies the processed host theme directly to the Teleporter UI controls.
---   This enables live theme updates without rebuilding the Teleporter window.
--- @param teleporter table # The Teleporter instance.
--- @param theme table # The processed theme token table.
--
function UI:ApplyThemeToTeleporter(teleporter, theme)
    if not teleporter or type(teleporter.EnsureUiState) ~= "function" then return end
    local uiState = teleporter:EnsureUiState()
    if not uiState or not uiState.Form then return end
    self:SetTeleporterControlColors(uiState, theme)
    if uiState.Form.repaint then
        uiState.Form:repaint()
    elseif uiState.Form.Repaint then
        uiState.Form:Repaint()
    end
end
registerLuaFunctionHighlight("ApplyThemeToTeleporter")

--
--- ∑ Applies a processed theme to every registered Manifold.Forms control.
---   This keeps already existing Forms windows in sync when themes are changed from the UI module.
--- @param theme table # The processed theme token table.
--- @param includeHidden boolean # Whether hidden registered forms should also be updated.
--- @returns table|nil # The normalized Forms design theme, or nil when Forms is unavailable.
--
function UI:ApplyThemeToForms(theme, includeHidden)
    if not forms or type(forms.ApplyTheme) ~= "function" then
        return nil
    end
    local appliedTheme = nil
    local function apply()
        appliedTheme = forms:ApplyTheme(theme, includeHidden == true)
    end
    if type(inMainThread) == "function" and type(synchronize) == "function" and not inMainThread() then
        synchronize(apply)
    else
        apply()
    end
    return appliedTheme
end
registerLuaFunctionHighlight("ApplyThemeToForms")

--
--- ∑ Attempts to acquire the global theme-apply lock.
--- @param themeName string # The requested theme name.
--- @returns string|nil, table|nil # Lock token on success; current lock data on failure.
--
function UI:AcquireThemeApplyLock(themeName)
    local now = _ThemeLockNow()
    local timeout = tonumber(self.ThemeApplyLockTimeoutMs) or 8000
    if THEME_APPLY_LOCK.Active then
        local elapsed = now - (tonumber(THEME_APPLY_LOCK.StartedAt) or now)
        if elapsed < timeout then
            return nil, THEME_APPLY_LOCK
        end
        if logger and logger.WarningF then
            logger:WarningF("[UI] Theme apply lock for '%s' is stale after %d ms. Releasing it.", tostring(THEME_APPLY_LOCK.ThemeName), elapsed)
        end
    end
    local token = tostring(self) .. ":" .. tostring(themeName or "<unknown>") .. ":" .. tostring(now)
    THEME_APPLY_LOCK.Active = true
    THEME_APPLY_LOCK.Token = token
    THEME_APPLY_LOCK.ThemeName = tostring(themeName or "<unknown>")
    THEME_APPLY_LOCK.StartedAt = now
    self.IsApplyingTheme = true
    return token, THEME_APPLY_LOCK
end
registerLuaFunctionHighlight("AcquireThemeApplyLock")

--
--- ∑ Releases the global theme-apply lock when the caller owns it.
--- @param token string # The lock token returned by AcquireThemeApplyLock.
--
function UI:ReleaseThemeApplyLock(token)
    if token ~= nil and THEME_APPLY_LOCK.Token == token then
        THEME_APPLY_LOCK.Active = false
        THEME_APPLY_LOCK.Token = nil
        THEME_APPLY_LOCK.ThemeName = nil
        THEME_APPLY_LOCK.StartedAt = 0
    end
    self.IsApplyingTheme = false
end
registerLuaFunctionHighlight("ReleaseThemeApplyLock")

--
--- ∑ Applies a specified theme to all UI components.
--- @param themeName string # The name of the theme to apply.
--- @param allowReapply boolean # (Optional) If true, forces reapplication even if the theme is already active.
--- @return # void
--
function UI:ApplyTheme(themeName, allowReapply)
    if not inMainThread() then
        local returnValue
        synchronize(function()
            returnValue = self:ApplyTheme(themeName, allowReapply)
        end)
        return returnValue
    end
    local token, activeLock = self:AcquireThemeApplyLock(themeName)
    if not token then
        local activeName = activeLock and activeLock.ThemeName or "<unknown>"
        logger:WarningF("[UI] A theme is already being applied: '%s'. Skipping theme '%s'.", tostring(activeName), tostring(themeName))
        return false
    end
    local ok, result = pcall(function()
        local theme = self:GetTheme(themeName)
        if not theme then
            return false
        end
        if self.ActiveTheme == themeName and not allowReapply then
            logger:Warning("[UI] Theme '" .. themeName .. "' is already applied.")
            return false
        end
        logger:Info("[UI] Applying theme: '" .. themeName .. "'")
        MainForm.Show()
        self:ApplyThemeToTreeView(theme)
        self:ApplyThemeToAddressList(theme)
        self:ApplyThemeToMainForm(theme)
        self:ApplyThemeToAddressRecords(theme)
        self:ApplyThemeToLuaEngine(theme)
        MainForm.repaint()
        self.ActiveTheme = themeName
        self:ApplyThemeToForms(theme, false)
        if teleporter and type(self.ApplyThemeToTeleporter) == "function" then
            self:ApplyThemeToTeleporter(teleporter, theme)
        end
        logger:Info("[UI] Theme '" .. themeName .. "' applied.")
        return true
    end)
    self:ReleaseThemeApplyLock(token)
    if not ok then
        logger:Error("[UI] Failed to apply theme '" .. tostring(themeName) .. "': " .. tostring(result))
        return false
    end
    return result == true
end
registerLuaFunctionHighlight("ApplyTheme")

--
--- ∑ Deletes all subrecords (child memory records) of the given parent record.
---   Iterates through the subrecords and removes them one by one.
--- @param record userdata # The parent memory record whose subrecords will be deleted.
--
function UI:DeleteSubrecords(record)
    while record ~= nil and record.Count > 0 do
        memoryrecord_delete(record.Child[0])
    end
end

--
--- ∑ Updates the theme selector in the address list by removing any existing theme-related entries
---   and dynamically adding memory records for each available theme.
--- @return # void
--
function UI:UpdateThemeSelector()
    if not inMainThread() then
        synchronize(function()
            self:UpdateThemeSelector()
        end)
        return
    end
    local addressList = getAddressList()
    local root = addressList.getMemoryRecordByDescription("[— UI : Theme Selector —] ()->")
    self:DeleteSubrecords(root) -- Helper function to remove all child records

    for themeName, _ in pairs(self.ThemeList) do
        local mr = addressList.createMemoryRecord()
        mr.Type = vtAutoAssembler
        mr.Script = string.format([=[{$lua}
[ENABLE]
-- ...........................[ENABLE]...........................
if syntaxcheck then return end
ui:ApplyTheme(memrec.Description)
utils:AutoDisable(memrec.ID)
[DISABLE]
-- ..........................[DISABLE]...........................

--- Script generated using %s
---- Version: %s
---- Source: https://github.com/Leunsel/CheatEngineLua/tree/main/Manifold-Modules
]=], NAME, VERSION)
        mr.Description = themeName
        mr.Color = 0xFFFFF0
        mr.Parent = root
        -- mr.OnActivate = self.ToggleTrigger
        -- mr.OnDeactivate = self.ToggleTrigger
    end
end
registerLuaFunctionHighlight("UpdateThemeSelector")

--
--- ∑ Runs a function in the main thread if not already in the main thread.
--- @param func function # The function to execute.
--
function UI:RunInMainThread(func)
    if type(func) ~= "function" then
        logger:ErrorF("[UI] Invalid parameter for 'RunInMainThread'. Expected a function, got '%s'.", type(func))
        return
    end
    if inMainThread() then
        local success, result = pcall(func)
        if not success then
            logger:ErrorF("[UI] Error while executing function in main thread: %s", result)
        end
    else
        local success, result =
            pcall(
            function()
                synchronize(func)
            end
        )
        if not success then
            logger:ErrorF("[UI] Failed to synchronize function execution in main thread: %s", result)
        end
    end
end

--
--- ∑ Sets the visibility of a UI control.
--- @param controlName string # The name of the control.
--- @param isVisible boolean # Whether the control should be visible.
--- @return # void
--
function UI:SetControlVisibility(controlName, isVisible)
    self:RunInMainThread(
        function()
            if MainForm and MainForm[controlName] then
                MainForm[controlName].Visible = isVisible
            end
        end
    )
end
registerLuaFunctionHighlight("SetControlVisibility")

--
--- ∑ Toggles the visibility of a UI control.
--- @param controlName string # The name of the control.
--- @return # void
--
function UI:ToggleControlVisibility(controlName)
    self:RunInMainThread(
        function()
            if MainForm and MainForm[controlName] then
                MainForm[controlName].Visible = not MainForm[controlName].Visible
            end
        end
    )
end

--
--- ∑ Enables compact mode by hiding specific UI panels.
--- @return # void
--
function UI:EnableCompactMode()
    self:RunInMainThread(
        function()
            self.CompactMode = true
            self:SetControlVisibility("Splitter1", false)
            self:SetControlVisibility("Panel5", false)
        end
    )
end
registerLuaFunctionHighlight("EnableCompactMode")

--
--- ∑ Disables compact mode by showing specific UI panels.
--- @return # void
--
function UI:DisableCompactMode()
    self:RunInMainThread(
        function()
            self.CompactMode = false
            self:SetControlVisibility("Splitter1", true)
            self:SetControlVisibility("Panel5", true)
        end
    )
end
registerLuaFunctionHighlight("DisableCompactMode")

--
--- ∑ Toggles compact mode.
--- @return # void
--
function UI:ToggleCompactMode()
    self:RunInMainThread(
        function()
            self.CompactMode = not self.CompactMode
            self:ToggleControlVisibility("Panel5")
            self:ToggleControlVisibility("Splitter1")
        end
    )
end
registerLuaFunctionHighlight("ToggleCompactMode")

--
--- ∑ Toggles the visibility of signature-area-related controls.
--- @return # void
--
function UI:ToggleSignatureControls()
    self:ToggleControlVisibility("CommentButton")
    self:ToggleControlVisibility("advancedbutton")
end
registerLuaFunctionHighlight("ToggleSignatureControls")

--
--- ∑ Hides the signature-area-related controls.
--- @return # void
--
function UI:HideSignatureControls()
    self:SetControlVisibility("CommentButton", false)
    self:SetControlVisibility("advancedbutton", false)
end
registerLuaFunctionHighlight("HideSignatureControls")

--
--- ∑ Disables drag-and-drop functionality for the address list tree view.
--- @return # void
--
function UI:DisableDragDrop()
    self:RunInMainThread(
        function()
            local addressListTreeview = component_getComponent(AddressList, 0) -- Disable drag and drop events
            setMethodProperty(addressListTreeview, "OnDragOver", nil)
            setMethodProperty(addressListTreeview, "OnDragDrop", nil)
            setMethodProperty(addressListTreeview, "OnEndDrag", nil)
        end
    )
end
registerLuaFunctionHighlight("DisableDragDrop")

--
--- ∑ Disables sorting functionality for the address list header.
--- @return # void
--
function UI:DisableHeaderSorting()
    self:RunInMainThread(
        function()
            local addressListHeader = component_getComponent(AddressList, 1)
            setMethodProperty(addressListHeader, "OnSectionClick", nil)
        end
    )
end
registerLuaFunctionHighlight("DisableHeaderSorting")

--
--- ∑ Hides the bevel around the address list.
--- @return # void
--
function UI:HideAddresslistBevel()
    self:RunInMainThread(
        function()
            if MainForm then
                AddressList.BevelOuter = "bvNone" -- AddressList; Original: bvRaised
            end
        end
    )
end
registerLuaFunctionHighlight("HideAddresslistBevel")

--
--- ∑ Creates or updates a label in the UI.
---   If the label does not exist, it is created with the specified parent and properties.
--- @param parent userdata # The parent container for the label.
--- @param label userdata|nil # The existing label to update, or nil to create a new one.
--- @param properties table # A table containing label properties such as alignment, font, and visibility.
--- @return userdata # The created or updated label.
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
--- @param name string # The name of the label.
--- @param text string # The text content for the label.
--- @param properties table # A table of properties for the label.
--- @return # None.
--
function UI:UpdateTextLabel(name, text, properties)
    self:RunInMainThread(
        function()
            local mainForm = getMainForm()
            local label = mainForm:findComponentByName(name)
            properties.Name = name
            properties.Caption = text or ""
            self[name] = self:CreateOrUpdateLabel(mainForm, label, properties)
        end
    )
end

--
--- ∑ Destroys a text label by name.
---   Ensures thread safety by running in the main thread.
--- @param name string # The name of the label to destroy.
--- @return # None.
--
function UI:DestroyTextLabel(name)
    self:RunInMainThread(
        function()
            if self[name] then
                self[name]:destroy()
                self[name] = nil
            end
        end
    )
end

--
--- ∑ Creates a slogan text label in the UI.
---   If no text is provided, it uses the default `SloganStr`.
--- @param text string|nil # The slogan text to display.
--- @return # None.
--
function UI:CreateSloganStr(text)
    self:UpdateTextLabel(
        "SLOGAN_STR",
        text or self.SloganStr,
        {
            Alignment = "taCenter",
            Font = {Name = "Consolas", Size = 20, Style = "fsBold"},
            Visible = true
        }
    )
end

--
--- ∑ Destroys the slogan text label.
--- @return # None.
--
function UI:DestroySloganStr()
    self:DestroyTextLabel("SLOGAN_STR")
end

--
--- ∑ Updates or creates the signature text in the UI.
---   The signature is displayed in a predefined label (`lblSigned`).
--- @param str string|nil # The signature text to display.
--- @return None.
--
function UI:CreateSignatureStr(str)
    self:RunInMainThread(
        function()
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
        end
    )
end

--
--- ∑ Hides the signature text label.
--- @return # None.
--
function UI:HideSignatureStr()
    self:RunInMainThread(
        function()
            if self.SignatureObj then
                self.SignatureObj.Visible = false
            end
        end
    )
end

--
--- ∑ Starts a text animation using a sequence of predefined effects.
---   Supports multiple animation types, cycling through them at defined intervals.
--- @param text string # The text to animate.
--- @param config table|nil # A table containing animation settings (animations list, interval, duration, pauses).
--- @return # None.
--
function UI:StartTextAnimation(text, config)
    config = config or {}
    local animations = config.animations or {"Typing", "Reveal", "Scrolling" --[["Glitch",]], "Matrix"}
    local interval = config.interval or 100
    local minDuration = config.minDuration or 5000
    local pauseBetweenAnimations = config.pauseBetweenAnimations or 1000

    local duration = math.max(#text * 200, minDuration)
    local index = 1

    local animationFunctions = {
        Typing = function()
            self:TypingEffect(text, interval)
        end,
        Reveal = function()
            self:RevealEffect(text, interval)
        end,
        Scrolling = function()
            self:ScrollText(text, interval)
        end,
        Glitch = function()
            self:GlitchText(text, interval)
        end,
        Matrix = function()
            self:MatrixReveal(text, interval)
        end
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
--- @param interval number # The interval in milliseconds.
--- @param callback function # The function to execute on each tick.
--- @return userdata # The created timer object.
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
--- @param text string # The text to scroll.
--- @param interval number|nil # The time in milliseconds between updates (default: 100ms).
--- @param maxTicks number|nil # The maximum number of scroll cycles (default: text length).
--- @return None.
--
function UI:ScrollText(text, interval, maxTicks)
    local function ScrollTextInner(text)
        return text:sub(2) .. text:sub(1, 1)
    end
    self.scrollingText = text .. " "
    self.scrollInterval = interval or 100 -- Default interval
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
--- @param text string # The text to type.
--- @param interval number|nil # The delay in milliseconds between each character (default: 100ms).
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
--- @param text string # The text to reveal.
--- @param interval number|nil # The delay in milliseconds between updates (default: 100ms).
--- @return None.
--
function UI:RevealEffect(text, interval)
    local placeholders = {"#", "@", "%", "&", "?", "*", "!"} -- Add more symbols if needed
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
--- @param text string # The text to glitch.
--- @param interval number|nil # The time in milliseconds between updates (default: 100ms).
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
--- @param text string # The text to reveal.
--- @param interval number|nil # The delay in milliseconds between updates (default: 100ms).
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
    if not inMainThread() then
        synchronize(function()
            self:InitializeForm()
        end)
        return
    end
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
    if self.ActiveTheme ~= self.Theme then
        logger:Info("[UI] Active theme '" .. tostring(self.ActiveTheme) .. "' does not match configured theme '" .. tostring(self.Theme) .. "'. Applying configured theme.")
        self:LoadThemes()
        self:ApplyTheme(self.Theme)
    else
        logger:Info("[UI] Active theme '" .. tostring(self.ActiveTheme) .. "' matches configured theme. No need to apply.")
    end 
end

--
--- ∑ Creates a styled label.
---   Configures the appearance and layout of the label.
--- @param parent # UI parent component for the label.
--- @param caption # Text to display on the label.
--- @param x # X position of the label.
--- @param y # Y position of the label.
--- @param size # Font size of the label.
--- @return label A styled label component.
--
function UI:CreateStyledLabel(parent, caption, x, y, size, bold)
    local label = forms:CreateLabel(parent, {
        caption = caption or "",
        left = x or 0,
        top = y or 0,
        fontSize = size or 10,
        style = bold or "[fsBold]",
        role = "label"
    })
    if not label then
        error("Failed to create label.")
    end
    return label
end

--
--- ∑ Creates a styled edit field.
---   Configures the appearance and layout of the edit field.
--- @param parent # UI parent component for the edit field.
--- @param text # Initial text in the edit field.
--- @param align # Alignment of the edit field.
--- @return edit A styled edit field component.
--
function UI:CreateStyledEdit(parent, text, align)
    local edit = forms:CreateTextBox(parent, {
        text = text or "",
        align = align or alTop,
        borderSpacing = { Around = 3 },
        role = "input"
    })
    if not edit then
        error("Failed to create edit field.")
    end
    return edit
end

--
--- ∑ Creates a styled button.
---   Configures the appearance and layout of the button.
--- @param parent # UI parent component for the button.
--- @param caption # Text displayed on the button.
--- @param width # Width of the button.
--- @return btn A styled button component.
--
function UI:CreateStyledButton(parent, caption, width)
    local btn = forms:CreateButton(parent, {
        caption = caption or "Button",
        align = alLeft,
        borderSpacing = { Around = 5 },
        fontSize = 10,
        style = "[fsBold]",
        width = width or 100,
        role = "button"
    })
    if not btn then
        error("Failed to create button.")
    end
    return btn
end

function UI:SetFormsButtonHandler(button, handler)
    if not button then return end
    forms:SetButtonOnClick(button, handler)
end

--
--- ∑ Creates the main form for the Theme Creator.
---   Configures the properties of the theme creator form.
--- @return form # The created theme creator form.
--
function UI:CreateThemeCreatorForm()
    local form = forms:CreateForm({
        caption = "[Manifold] Theme Creator",
        width = 980,
        height = 620,
        position = "poScreenCenter",
        role = "form"
    })
    if not form then
        error("Failed to create form.")
    end
    form.Position = "poScreenCenter"
    form.Font.Size = 9
    form.Font.Name = "Consolas"
    form.Scaled = false
    form.BorderStyle = "bsSizeable"
    form.Constraints.MinWidth = 980
    form.Constraints.MinHeight = 620
    return form
end

--
--- ∑ Creates a panel for theme metadata.
---   Adds input fields for Theme Name, Author, and Description.
--- @param form # The parent form to contain the panel.
--- @return themeNameInput, authorInput, descriptionInput The created input fields for metadata.
--
function UI:CreateThemeInfoPanel(form, opts)
    opts = opts or {}
    local _, _, _, content = forms:CreateCard(form, {
        title = opts.title or "METADATA",
        align = opts.align or alTop,
        height = opts.height or 158,
        borderSpacing = opts.borderSpacing or { Left = 6, Top = 6, Right = 6 },
        contentSpacing = opts.contentSpacing or { Around = 8 }
    })
    local descEdit = forms:CreateFieldRow(content, {
        caption = "Description",
        labelWidth = 88,
        textHint = "Description",
        borderSpacing = { Bottom = 0 }
    })
    local authorEdit = forms:CreateFieldRow(content, {
        caption = "Author",
        labelWidth = 88,
        textHint = "Author"
    })
    local nameEdit = forms:CreateFieldRow(content, {
        caption = "Name",
        labelWidth = 88,
        textHint = "Theme name"
    })
    return descEdit, nameEdit, authorEdit
end

--
--- ∑ Creates a list view control.
---   Configures the appearance and layout of the list view.
--- @param form # UI parent form for the list view.
--- @return listView # A configured list view component.
--
function UI:CreateListViewControl(form, opts)
    opts = opts or {}
    local _, _, _, content = forms:CreateCard(form, {
        title = opts.title or "THEME TOKENS",
        align = opts.align or alClient,
        height = opts.height,
        width = opts.width,
        borderSpacing = opts.borderSpacing or { Left = 6, Top = 6, Right = 6 },
        contentSpacing = opts.contentSpacing or { Around = 6 }
    })
    local listView = forms:CreateListView(content, {
        align = alClient,
        viewStyle = "vsReport",
        readOnly = true,
        autoWidthLastColumn = true,
        rowSelect = true,
        fullRowSelect = true,
        hideSelection = false,
        borderSpacing = { Around = 0 },
        fontSize = 9,
        role = "listview"
    })
    if not listView then
        error("Failed to create list view.")
    end
    listView.Align = alClient
    listView.ViewStyle = "vsReport"
    listView.ReadOnly = true
    listView.AutoWidthLastColumn = true
    listView.RowSelect = true
    listView.FullRowSelect = true
    listView.HideSelection = false
    listView.BorderSpacing.Around = 3
    listView.Font.Size = 9
    listView.Font.Name = "Consolas"
    listView.Columns.Add().Caption = "Color"
    listView.Columns[0].AutoSize = true
    listView.Columns.Add().Caption = "Token"
    listView.Columns[1].AutoSize = true
    self.ThemeCreatorImageList = createImageList()
    self.ThemeCreatorImageList.Width = 16
    self.ThemeCreatorImageList.Height = 16
    listView.SmallImages = self.ThemeCreatorImageList
    self.ThemeCreatorListView = listView
    return listView
end

--
--- ∑ Rebuilds the image list for a list view control.
---   Updates the image list with the new color-token pairs.
--- @param listView # The list view to rebuild the image list for.
--- @param listOfColorsAndTokens # List of color-token pairs to update the image list with.
--
function UI:RebuildImageList(listView, listOfColorsAndTokens)
    if not listView then
        return
    end
    listOfColorsAndTokens = listOfColorsAndTokens or self:GetColorsAndTokensFromListView(listView)
    if not listOfColorsAndTokens or #listOfColorsAndTokens == 0 then
        return
    end
    if self.ThemeCreatorImageList then
        pcall(function()
            self.ThemeCreatorImageList.Destroy()
        end)
    end
    self.ThemeCreatorImageList = createImageList()
    self.ThemeCreatorImageList.Width = 16
    self.ThemeCreatorImageList.Height = 16
    listView.SmallImages = self.ThemeCreatorImageList
    for i, pair in ipairs(listOfColorsAndTokens) do
        local colorHex = pair[1]
        local rgbColor = tonumber(colorHex:sub(2), 16)
        local bgrColor = self:RGB2BGR(rgbColor)
        local bmp = createBitmap(16, 16)
        bmp.Canvas.Brush.Color = bgrColor
        bmp.Canvas.FillRect(0, 0, 16, 16)
        self.ThemeCreatorImageList.Add(bmp)
        bmp.Destroy()
        if listView.Items.Count > i - 1 then
            listView.Items[i - 1].ImageIndex = i - 1
        end
    end
end

--
--- ∑ Retrieves the active theme data from the theme list.
---   Logs a warning if no active theme or theme data is found.
--- @return activeTheme # The data for the active theme, or nil if not found.
--
function UI:GetActiveThemeData()
    local activeThemeName = self.ActiveTheme
    if not activeThemeName then
        logger:Warning("[UI] No active theme set.")
        return nil
    end
    local activeTheme = self.ThemeList[activeThemeName]
    if not activeTheme then
        logger:Warning("[UI] Active theme not found in ThemeList: " .. activeThemeName)
        return nil
    end
    return activeTheme
end

--
--- ∑ Populates the list view with theme tokens and their default colors.
---   Sets up list items for each token in `self.ThemeTokens`.
--- @param listView # The list view to populate with tokens.
--- @param tokenInputs # Table to store token-to-list-item mappings.
--
function UI:PopulateListView(listView, tokenInputs)
    local activeThemeData = self:GetActiveThemeData()
    if not activeThemeData then
        return
    end
    local listOfColorsAndTokens = {}
    for token, colorValue in pairs(activeThemeData) do
        local rgbColor = colorValue or 0xFFFFFF -- Fallback to white if nil.
        local colorHex = string.format("#%06X", self:BGR2RGB(rgbColor))
        table.insert(listOfColorsAndTokens, {colorHex, token})
        local item = listView.Items.Add()
        item.Caption = colorHex
        item.SubItems.Add(token)
        tokenInputs[token] = item
    end
    self:RebuildImageList(listView, listOfColorsAndTokens)
    self:SetThemeCreatorStatus(tostring(#listOfColorsAndTokens) .. " tokens loaded")
end

--
--- ∑ Handles color selection for a theme token.
---   Opens a color dialog to select a new color and updates the preview panel and selected token label.
--- @param item # List item representing the token.
--- @param token # The name of the token selected.
--
function UI:HandleColorSelection(item, token)
    if not (item and token) then return end
    local oldColor = self:RGB2BGR(tonumber(item.Caption:sub(2), 16)) or 0xFFFFFF
    local cd = createColorDialog(self.ThemeCreatorForm)
    cd.Color = oldColor
    if cd.Execute() then
        local newColor = cd.Color & 0xFFFFFF
        local newColorHex = string.format("#%06X", self:BGR2RGB(newColor))
        item.Caption = newColorHex
        self.PreviewPanel.Color = newColor
        self:UpdateColorLabels(self:BGR2RGB(newColor))
        self:UpdateSelectedToken(token)
    end
    local listView = self.ThemeCreatorListView
    if listView then
        self:RebuildImageList(listView, self:GetColorsAndTokensFromListView(listView))
    end
end

--
--- ∑ Extracts colors and tokens from the list view.
---   Collects the color and token pairs from the list view items.
--- @param listView # The list view to extract the colors and tokens from.
--- @return rawList # A list of color-token pairs extracted from the list view.
--
function UI:GetColorsAndTokensFromListView(listView)
    local rawList = {}
    for i = 0, listView.Items.Count - 1 do
        local item = listView.Items[i]
        if item and item.Caption and item.SubItems and item.SubItems[0] then
            table.insert(rawList, {item.Caption, item.SubItems[0]})
        end
    end
    return rawList
end

--
--- ∑ Handles the double-click event for the list view.
---   Opens the color selection dialog for the selected item.
--- @param listView # The list view component.
--- @param tokenInputs # A table of token-to-list-item mappings.
--
function UI:OnListViewDblClick(listView, tokenInputs)
    if not listView then
        return
    end
    listView.OnDblClick = function()
        local sel = listView.Selected
        if not sel then
            return
        end
        local token = sel.SubItems and sel.SubItems[0]
        if not token or token == "" then
            return
        end
        self:HandleColorSelection(sel, token)
    end
end

--
--- ∑ Handles the selection of a list view item.
---   Updates the preview panel and RGB/BGR labels based on the selected color.
--- @param listView # The list view component.
--
function UI:OnListViewSelectItem(listView)
    if not listView then
        return
    end
    listView.OnSelectItem = function(_, item, selected)
        if selected and item then
            local colorNum = tonumber(item.Caption:sub(2), 16) or 0xFFFFFF
            self.PreviewPanel.Color = self:RGB2BGR(colorNum)
            self.SelectedTokenLabel.Caption = item.SubItems[0]
            self:UpdateColorLabels(colorNum)
            self:UpdateSelectedToken(item.SubItems[0])
            self:SetThemeCreatorStatus("Selected: " .. tostring(item.SubItems[0]))
        end
    end
end

--
--- ∑ Updates the RGB and BGR labels based on the selected color.
---   Converts the color number to RGB and BGR and updates the labels.
--- @param colorNum # The selected color in hexadecimal format.
--
function UI:UpdateColorLabels(colorNum)
    local r = (colorNum >> 16) & 0xFF
    local g = (colorNum >> 8) & 0xFF
    local b = colorNum & 0xFF
    self.RGBLabel.Caption = string.format("RGB: (%d, %d, %d)", r, g, b)
    self.HexLabel.Caption = string.format("Hex: #%02X%02X%02X", r, g, b)
end

--
--- ∑ Updates the UI to display information about the selected token.
---   Sets the selected token name and its associated description.
--- @param tokenName # The name of the token to display. If nil, sets default text "(No Token)".
--
function UI:UpdateSelectedToken(tokenName)
    self.SelectedTokenLabel.Caption = tokenName or "(No Token)"
    local desc = self.TokenDescriptions[tokenName or ""] or "(No Description)"
    self.DescriptionLabel.Caption = desc
end

--
--- ∑ Helper function to create a small copy-to-clipboard button for a label.
--- @param parent # The parent control
--- @param targetLabel # The label to copy from
--- @param topOffset # Optional vertical offset override
--
function UI:CreateCopyButton(parent, targetLabel, topOffset)
    local btn = forms:CreateButton(parent, {
        caption = "Copy",
        width = 58,
        height = 22,
        left = targetLabel.Left + targetLabel.Width + 10,
        top = topOffset or targetLabel.Top,
        role = "button"
    })
    self:SetFormsButtonHandler(btn, function()
        writeToClipboard(targetLabel.Caption)
    end)
    return btn
end

--
--- ∑ Creates a preview panel for theme tokens with extra info and controls.
---   Displays the selected token color and its corresponding RGB/BGR/Hex values,
---   and offers interaction via a color picker and clipboard buttons.
--- @param form # The parent form for the preview panel.
--
function UI:CreateTokenPreviewPanel(form, opts)
    opts = opts or {}
    local cardAlign = opts.align or alBottom
    local cardHeight = opts.height
    if cardHeight == nil and cardAlign ~= alClient then
        cardHeight = 142
    end
    local _, _, _, content = forms:CreateCard(form, {
        title = opts.title or "TOKEN PREVIEW",
        align = cardAlign,
        height = cardHeight,
        borderSpacing = opts.borderSpacing or { Left = 6, Top = 6, Right = 6 },
        contentSpacing = opts.contentSpacing or { Around = 8 }
    })
    local rowContainer = forms:CreatePanel(content, {
        align = alClient,
        role = "panel"
    })
    self.PreviewPanel = forms:CreatePanel(rowContainer, {
        align = alLeft,
        width = 104,
        height = 104,
        color = 0x808080,
        role = "swatch",
        lockColor = true,
        bevelOuter = "bvLowered",
        bevelWidth = 1,
        borderSpacing = { Right = 10 },
        hint = "Preview Area",
        showHint = true
    })
    self.PreviewPanel.Constraints.MaxWidth = 104
    self.PreviewPanel.Constraints.MaxHeight = 104

    local controlsStack = forms:CreatePanel(rowContainer, {
        align = alClient,
        role = "panel"
    })
    local function createLabelRow(refName, caption, canCopy)
        local row = forms:CreatePanel(controlsStack, {
            align = alTop,
            height = 24,
            role = "panel",
            borderSpacing = { Bottom = 2 }
        })
        local copyBtn
        if canCopy then
            copyBtn = forms:CreateButton(row, {
                caption = "Copy",
                align = alRight,
                width = 58,
                height = 22,
                fontSize = 9,
                borderSpacing = { Left = 6 }
            })
        end
        local label = forms:CreateLabel(row, {
            align = alClient,
            caption = caption,
            layout = "tlCenter",
            transparent = true,
            role = "label",
            fontSize = 10,
            style = "[]"
        })
        self[refName] = label
        if copyBtn then
            self:SetFormsButtonHandler(copyBtn, function()
                writeToClipboard(label.Caption or "")
            end)
        end
    end
    createLabelRow("HexLabel", "Hex: #FFFFFF", true)
    createLabelRow("RGBLabel", "RGB: (255, 255, 255)", true)
    createLabelRow("DescriptionLabel", "(No Description)", false)
    createLabelRow("SelectedTokenLabel", "(No Token)", false)
end

--
--- ∑ Creates a panel for theme-related actions.
---   Adds buttons for applying the theme, exporting the theme, and loading a theme.
--- @param form # The parent form for the button panel.
--- @return applyBtn, exportBtn, loadBtn # The action buttons for theme management.
--
function UI:CreateButtonPanel(form, opts)
    opts = opts or {}
    local activeTheme = nil
    if self.ActiveTheme and self.ThemeList then
        activeTheme = self.ThemeList[self.ActiveTheme]
    end
    local designTheme = forms.ActiveDesignTheme or forms:ResolveTheme(activeTheme)
    local toolbar = forms:CreatePanel(form, {
        align = opts.align or alBottom,
        height = opts.height or 30,
        color = designTheme.COLOR_PANEL,
        role = "panel",
        borderSpacing = opts.borderSpacing or { Left = 6, Right = 6, Top = 6, Bottom = 3 }
    })
    local buttonRow = forms:CreatePanel(toolbar, {
        align = alClient,
        color = designTheme.COLOR_PANEL,
        role = "panel"
    })
    local loadBtn = forms:CreateButton(buttonRow, {
        caption = "Load Theme",
        width = 132,
        height = 30,
        borderSpacing = { Right = 6 }
    })
    local exportBtn = forms:CreateButton(buttonRow, {
        caption = "Export as JSON",
        width = 144,
        height = 30,
        borderSpacing = { Right = 6 }
    })
    local applyBtn = forms:CreateButton(buttonRow, {
        caption = "Apply Theme",
        width = 132,
        height = 30,
        borderSpacing = { Right = 6 }
    })
    return applyBtn, exportBtn, loadBtn
end

--
--- ∑ Sets up the "Load Theme" button and its functionality.
---   Opens a file dialog to load a theme from a JSON file and applies it to the UI.
--- @param loadBtn # The "Load Theme" button component.
--- @param tokenInputs # A table of token input fields associated with theme elements.
--- @param nameEdit # The edit field for the theme's name.
--- @param authorEdit # The edit field for the theme's author.
--- @param descEdit # The edit field for the theme's description.
--
function UI:SetupLoadButton(loadBtn, tokenInputs, nameEdit, authorEdit, descEdit)
    self:SetFormsButtonHandler(loadBtn, function()
        local themePath = self:PromptThemeFile()
        if not themePath then return end
        local themeData = self:LoadThemeData(themePath)
        if not themeData then return end
        local themeObj = self:NormalizeTheme(themeData)
        self:PopulateThemeUI(themeData, tokenInputs, nameEdit, authorEdit, descEdit)
        self:ApplyThemeObject(themeObj)
        local listView = self.ThemeCreatorListView
        if listView then
            self:RebuildImageList(listView, self:GetColorsAndTokensFromListView(listView))
        end
        if listView and listView.Selected and listView.Selected.Caption then
            local hex = listView.Selected.Caption:match("^#?(%x%x%x%x%x%x)$")
            if hex then
                local r = tonumber(hex:sub(1, 2), 16)
                local g = tonumber(hex:sub(3, 4), 16)
                local b = tonumber(hex:sub(5, 6), 16)
                self.PreviewPanel.Color = (b << 16) | (g << 8) | r
            end
        end
        logger:Info("[UI] Theme loaded and applied successfully!")
        self:SetThemeCreatorStatus("Theme loaded")
    end)
end

--
--- ∑ Prompts the user to select a theme file.
---   Opens a file dialog for the user to choose a JSON theme file.
--- @return filePath # The path to the selected theme file, or nil if no file was selected.
--
function UI:PromptThemeFile()
    local dlg = createOpenDialog(self.ThemeCreatorForm)
    dlg.DefaultExt = "json"
    dlg.Filter = "JSON Files (*.json)|*.json"
    return dlg.Execute() and dlg.FileName or nil
end

--
--- ∑ Loads theme data from a file.
---   Reads and parses the content of a JSON file to extract theme data.
--- @param path # The path to the theme file to load.
--- @return themeData # The theme data extracted from the file, or nil if loading failed.
--
function UI:LoadThemeData(path)
    local file, err = io.open(path, "r")
    if not file then
        logger:Error("[UI] Failed to open theme file: " .. tostring(err))
        return nil
    end
    local content = file:read("*a")
    file:close()
    local ok, result = pcall(function() return json:decode(content) end)
    if not ok then
        logger:Error("[UI] Failed to parse theme JSON: " .. tostring(result))
        return nil
    end
    return result
end

--
--- ∑ Normalizes theme data.
---   Ensures required fields are populated with default values if they are missing.
--- @param data # The raw theme data to normalize.
--- @return normalizedTheme # A table with normalized theme data.
--
function UI:NormalizeTheme(data)
    local function IsEmpty(value)
        return type(value) ~= "string" or value:match("^%s*$")
    end
    local tokens = {}
    for _, t in ipairs(data.tokenColors or {}) do
        if t.element and t.setting and t.setting.color then
            tokens[t.element] = t.setting.color
        end
    end
    return {
        Name        = IsEmpty(data.name)        and "Unnamed Theme"    or data.name,
        Author      = IsEmpty(data.author)      and "Unknown Author"   or data.author,
        Description = IsEmpty(data.description) and "No Description"   or data.description,
        Tokens      = tokens
    }
end

--
--- ∑ Populates the UI with theme data.
---   Updates the UI controls (e.g., name, author, description, token colors) with the given theme data.
--- @param themeData # The theme data to populate the UI with.
--- @param tokenInputs # A table of input fields for token colors.
--- @param nameEdit # The input field for the theme name.
--- @param authorEdit # The input field for the theme author.
--- @param descEdit # The input field for the theme description.
--
function UI:PopulateThemeUI(themeData, tokenInputs, nameEdit, authorEdit, descEdit)
    nameEdit.Text = themeData.name or ""
    authorEdit.Text = themeData.author or ""
    descEdit.Text = themeData.description or ""
    for _, token in ipairs(themeData.tokenColors or {}) do
        local element = token.element
        local color = token.setting and token.setting.color
        if element and color then
            local input = tokenInputs[element]
            if input then
                input.Caption = color
                if logger and logger.DebugF then
                    logger:DebugF("[UI] Setting token: %s to color: %s", element, color)
                end
            else
                logger:Warning("[UI] Token input not found for element: " .. element)
            end
        end
    end
    local listView = self.ThemeCreatorListView
    if listView then
        self:RebuildImageList(listView, self:GetColorsAndTokensFromListView(listView))
    end
end

--
--- ∑ Applies the given theme object to the UI components.
---   Applies color settings from the theme to various UI components like tree views, address lists, and main form.
--- @param themeObj # The theme object containing tokens and color settings.
--
function UI:ApplyThemeObject(themeObj)
    if not themeObj or not themeObj.Tokens then
        logger:Warning("[UI] Invalid theme object.")
        return false
    end
    local lockName = themeObj.Name or "Theme Object"
    local lockToken, activeLock = self:AcquireThemeApplyLock(lockName)
    if not lockToken then
        local activeName = activeLock and activeLock.ThemeName or "<unknown>"
        logger:WarningF("[UI] A theme is already being applied: '%s'. Skipping theme object '%s'.", tostring(activeName), tostring(lockName))
        return false
    end

    local ok, result = pcall(function()
        local builtTheme = {}
        for token, colorHex in pairs(themeObj.Tokens) do
            if type(colorHex) == "string" and colorHex:match("^#%x%x%x%x%x%x$") then
                local rgbColor = tonumber(colorHex:sub(2), 16)
                if rgbColor then
                    builtTheme[token] = self:RGB2BGR(rgbColor)
                else
                    logger:Warning(
                        string.format(
                            "[UI] Failed to convert color for token '%s': '%s' (parsed: %s)",
                            token, colorHex, tostring(rgbColor)))
                end
            else
                logger:Warning(string.format("[UI] Invalid color format for token '%s': %s", token, tostring(colorHex)))
            end
        end
        logger:Info("[UI] Applying theme object: '" .. tostring(lockName) .. "'")
        self:ApplyThemeToTreeView(builtTheme)
        self:ApplyThemeToAddressList(builtTheme)
        self:ApplyThemeToMainForm(builtTheme)
        self:ApplyThemeToAddressRecords(builtTheme)
        self:ApplyThemeToLuaEngine(builtTheme)
        self:ApplyThemeToForms(builtTheme, false)
        if teleporter and type(self.ApplyThemeToTeleporter) == "function" then
            self:ApplyThemeToTeleporter(teleporter, builtTheme)
        end
        return true
    end)

    self:ReleaseThemeApplyLock(lockToken)
    if not ok then
        logger:Error("[UI] Failed to apply theme object '" .. tostring(lockName) .. "': " .. tostring(result))
        return false
    end
    return result == true
end

--
--- ∑ Sets up the "Apply Theme" button and its functionality.
---   Collects theme data from the UI and applies it when the button is clicked.
--- @param applyBtn # The "Apply Theme" button component.
--- @param tokenInputs # A table of token input fields associated with theme elements.
--- @param nameEdit # The edit field for the theme's name.
--- @param authorEdit # The edit field for the theme's author.
--- @param descEdit # The edit field for the theme's description.
--
function UI:SetupApplyButton(applyBtn, tokenInputs, nameEdit, authorEdit, descEdit)
    self:SetFormsButtonHandler(applyBtn, function()
        local themeObj = {
            Name = nameEdit.Text or "Unnamed Theme",
            Author = authorEdit.Text or "Unknown Author",
            Description = descEdit.Text or "No Description",
            Tokens = {}
        }
        for token, item in pairs(tokenInputs) do
            themeObj.Tokens[token] = item.Caption or "#FFFFFF"
        end
        self:ApplyThemeObject(themeObj)
        self:SetThemeCreatorStatus("Theme applied")
    end)
end

--
--- ∑ Sets up the "Export Theme" button and its functionality.
---   Exports the current theme data as a JSON file after collecting theme information from the UI.
--- @param exportBtn # The "Export Theme" button component.
--- @param nameEdit # The edit field for the theme's name.
--- @param authorEdit # The edit field for the theme's author.
--- @param descEdit # The edit field for the theme's description.
--- @param tokenInputs # A table of token input fields associated with theme elements.
--
function UI:SetupExportButton(exportBtn, nameEdit, authorEdit, descEdit, tokenInputs)
    self:SetFormsButtonHandler(exportBtn, function()
        local themeData = {
            name        = nameEdit.Text,
            author      = authorEdit.Text,
            description = descEdit.Text,
            tokenColors = {}
        }
        for token, item in pairs(tokenInputs) do
            local hex = tonumber(item.Caption:sub(2), 16)
            if hex then
                local r = (hex >> 16) & 0xFF
                local g = (hex >> 8)  & 0xFF
                local b = hex & 0xFF
                local rgb = (r << 16) | (g << 8) | b

                table.insert(themeData.tokenColors, {
                    element = token,
                    setting = { color = string.format("#%06X", rgb) }
                })
            end
        end
        local success, jsonStr = pcall(function()
            return json:encode_pretty(themeData, { indent = true })
        end)
        if not success or not jsonStr then
            return logger:Error("[UI] Failed to serialize theme data.")
        end
        local dlg = createSaveDialog(self.ThemeCreatorForm)
        dlg.DefaultExt = "json"
        dlg.Filter     = "JSON Files (*.json)|*.json"
        if themeData.name and themeData.name ~= "" then
            local safeName = themeData.name:gsub("[\\/:*?\"<>|]", "") -- strip invalid filename chars
            dlg.FileName = safeName .. ".json"
        end
        if not dlg.Execute() then return end
        local file = io.open(dlg.FileName, "w")
        if file then
            file:write(jsonStr)
            file:close()
            logger:Info("[UI] Theme exported successfully!")
            self:SetThemeCreatorStatus("Theme exported")
        else
            logger:Error("[UI] Failed to write file.")
        end
    end)
end

function UI:SetThemeCreatorStatus(text)
    if self.ThemeCreatorStatusLabel then
        self.ThemeCreatorStatusLabel.Caption = text or "Theme Creator ready"
    end
end

function UI:CreateThemeCreatorStatusBar(parent)
    local statusPanel = forms:CreatePanel(parent, {
        align = alBottom,
        height = 26,
        role = "border",
        bevelOuter = "bvNone",
        borderSpacing = { Left = 6, Top = 6, Right = 6, Bottom = 6 }
    })
    local innerPanel = forms:CreatePanel(statusPanel, {
        align = alClient,
        role = "panel",
        borderSpacing = { Around = 1 }
    })
    self.ThemeCreatorStatusLabel = forms:CreateLabel(innerPanel, {
        align = alLeft,
        caption = "Theme Creator ready",
        borderSpacing = { Left = 8, Top = 3 },
        transparent = true,
        role = "label"
    })
    return statusPanel
end

--
--- ∑ Initializes the theme creation UI form.
---   Creates and configures all the necessary UI elements and sets up buttons for applying, loading, and exporting themes.
---
function UI:InitializeThemeCreator()
    if not inMainThread() then
        synchronize(function()
            self:InitializeThemeCreator()
        end)
        return
    end
    if self.ThemeCreatorForm and self.ThemeCreatorForm.Visible then
        self.ThemeCreatorForm.BringToFront()
        return
    end
    if not self.ThemeCreatorForm then
        self.ThemeCreatorForm = self:CreateThemeCreatorForm()
        local tokenInputs = {}
        local descEdit, nameEdit, authorEdit
        local listView
        local applyBtn, exportBtn, loadBtn
        local root = forms:CreatePanel(self.ThemeCreatorForm, {
            align = alClient,
            role = "background"
        })
        self.ThemeCreatorRootPanel = root
        self:CreateThemeCreatorStatusBar(root)
        applyBtn, exportBtn, loadBtn = self:CreateButtonPanel(root, {
            align = alTop,
            height = 30,
            borderSpacing = { Left = 6, Top = 6, Right = 6, Bottom = 3 }
        })
        local body = forms:CreatePanel(root, {
            align = alClient,
            role = "background",
            borderSpacing = { Left = 6, Right = 6 }
        })
        self.ThemeCreatorBodyPanel = body
        local editorHost = forms:CreatePanel(body, {
            align = alClient,
            role = "background"
        })
        editorHost.Constraints.MinWidth = 320
        local splitter = createSplitter(body)
        splitter.Align = alLeft
        splitter.Width = 6
        splitter.MinSize = 260
        splitter.ResizeStyle = "rsUpdate"
        self.ThemeCreatorSplitter = splitter
        local tokenHost = forms:CreatePanel(body, {
            align = alLeft,
            width = 360,
            role = "background"
        })
        tokenHost.Constraints.MinWidth = 280
        self.ThemeCreatorTokenHost = tokenHost
        self.ThemeCreatorEditorHost = editorHost
        listView = self:CreateListViewControl(tokenHost, {
            title = "THEME TOKENS",
            align = alClient,
            borderSpacing = { Right = 6 },
            contentSpacing = { Around = 6 }
        })
        descEdit, nameEdit, authorEdit = self:CreateThemeInfoPanel(editorHost, {
            title = "THEME EDITOR",
            align = alTop,
            height = 158,
            borderSpacing = { Left = 6, Right = 6 },
            contentSpacing = { Around = 8 }
        })
        self:CreateTokenPreviewPanel(editorHost, {
            title = "TOKEN PREVIEW",
            align = alClient,
            borderSpacing = { Left = 6, Top = 6, Right = 6 },
            contentSpacing = { Around = 8 }
        })
        self.ThemeCreatorTokenInputs = tokenInputs
        self:PopulateListView(listView, tokenInputs)
        self:OnListViewDblClick(listView, tokenInputs)
        self:OnListViewSelectItem(listView)
        self:SetupApplyButton(applyBtn, tokenInputs, nameEdit, authorEdit, descEdit)
        self:SetupExportButton(exportBtn, nameEdit, authorEdit, descEdit, tokenInputs)
        self:SetupLoadButton(loadBtn, tokenInputs, nameEdit, authorEdit, descEdit)
        self.ThemeCreatorForm.OnClose = function(sender, action)
            self.ThemeCreatorForm.Hide()
            action = caHide
        end
    end
    self.ThemeCreatorForm.Show()
end
registerLuaFunctionHighlight("InitializeThemeCreator")

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return UI
