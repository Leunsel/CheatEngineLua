local NAME = 'CTI.FormManager'
local AUTHOR = {'Leunsel', 'LeFiXER'}
local VERSION = '1.0.3'
local DESCRIPTION = 'Cheat Table Interface (Form Manager)'

--[[
    Script Name: Module.FormManager.lua
    Description: Form Manager is a Module designed to customize the appearance
                 of the Cheat Engine Main Form and it's child components.
    
    Version History:
    -----------------------------------------------------------------------------
    Version | Date         | Author          | Changes
    -----------------------------------------------------------------------------
    1.0.0   | ----------   | Leunsel,LeFiXER | Initial release.
    1.0.1   | ----------   | Leunsel         | Added TableFileExplorer
    1.0.2   | 14.02.2025   | Leunsel,LeFiXER | Updated to a diff. Json Module
    1.0.3   | 26.02.2025   | Leunsel         | Reduced usage of string.format
    -----------------------------------------------------------------------------
    
    Notes:
    - ...
--]]

--
--- Several configuration properties that can be customized.
--- Set within the Table Lua Script and passed to the constructor of the class.
----------
FormManager = {
    Signature = "",
    Slogan = "",
    themes = {},
    instance = nil,
    currentTheme = nil
}

--
--- Set the metatable for the FormManager object so that it behaves as an "object-oriented class".
----------
FormManager.__index = FormManager

--
--- This checks if the required module(s) (Logger) are already loaded.
--- If not, it attempts to load them using the CETrequire function.
----------
if not Logger then
    CETrequire("Module.Logger")
end

function FormManager:new(properties)
    if FormManager.instance then
        return FormManager.instance
    end
    local obj = setmetatable({}, self)
    obj.logger = Logger:new()
    FormManager.instance = obj
    return obj
end

--
--- Updates the theme selector in the address list by removing any existing theme-related entries 
--- and dynamically adding memory records for each available theme.
--- @return None.
----------
function FormManager:UpdateThemeSelector()
    local addressList = getAddressList()
    local root = addressList.getMemoryRecordByDescription("[— Theme Selector —]")
    self:delete_subrecords(root)
    for themeName, _ in pairs(self.themes) do
        local mr = addressList.createMemoryRecord()
        mr.Type = vtAutoAssembler
        mr.Script =
            [[{$lua}
[ENABLE]
if syntaxcheck then return end
formManager:ApplyTheme(memrec.Description)
utility:AutoDisable(memrec.ID)
[DISABLE]
]]
        mr.Description = themeName
        mr.Color = 0xFFFFF0
        mr.Parent = root
        mr.OnActivate = self.ToggleTrigger
        mr.OnDeactivate = self.ToggleTrigger
    end
end
registerLuaFunctionHighlight('UpdateThemeSelector')

--
--- Returns the currently applied theme name.
--- @return string - The name of the currently applied theme.
----------
function FormManager:GetCurrentTheme()
    return self.currentTheme
end

--
--- Reads the content of a file and returns it as a string.
--- @param file string - The path to the file to be read.
--- @return string - The content of the file.
----------
function FormManager:ReadAll(file)
    local f = assert(io.open(file, "rb"))
    local content = f:read("*all")
    f:close()
    return content
end

--
--- Converts an RGB value to BGR format by swapping the red and blue channels.
--- @param RGB number - The RGB value as an integer.
--- @return number - The BGR value as an integer.
----------
function FormManager:rgb_to_bgr(RGB)
    local r = RGB // 0x10000
    local g = ((RGB % 0x10000) // 0x100) << 8
    local b = (RGB % 0x100) << 16
    return r + g + b
end

--
--- Converts a hex RGB string to its equivalent BGR value.
--- @return number - The BGR value corresponding to the hex RGB string.
----------
function string:bgr()
    local hexColorString = self:sub(2, 7)
    local RGB = tonumber(hexColorString, 16)
    return FormManager:rgb_to_bgr(RGB)
end

--
--- Searches for a token within a given scope (either a table or string).
--- @param scope table|string - The scope to search within (can be a table or a string).
--- @param token string - The token to search for.
--- @return boolean - Returns true if the token is found, false otherwise.
----------
function FormManager:TokenSearch(scope, token)
    if type(scope) == "table" then
        if scope[token] == token then
            return true
        end
        for _, item in ipairs(scope) do
            if item == token then
                return true
            end
        end
    end
    if type(scope) == "string" and (scope == token or scope:split(", ")[token]) then
        return true
    end
    return false
end

--- Retrieves the color associated with a token from the raw theme data.
--- @param raw table - The raw theme data in JSON format.
--- @param token string - The token for which to retrieve the color.
--- @return number|nil - The color for the token in BGR format, or nil if not found.
----------
function FormManager:TokenColor(raw, token)
    local rawColors = raw["colors"]
    if rawColors and rawColors[token] then
        return rawColors[token]:bgr()
    end
    local tokenColors = raw["tokenColors"]
    for _, item in ipairs(tokenColors) do
        if
            item["scope"] and self:TokenSearch(item["scope"], token) and item["settings"] and
                item["settings"]["foreground"]
         then
            return item["settings"]["foreground"]:bgr()
        end
    end
    return nil
end

--
--- Loads themes from JSON files available in the table menu.
--- This function reads theme data from `.json` files and stores it in `self.themes`.
--- The JSON files must be accessible via the Cheat Engine table menu.
--- @return None.
----------
function FormManager:LoadThemes()
    if not json then
        CETrequire("json")
        json = JSON:new()
    end
    -- Load all JSON themes from the table menu
    local jsonThemes = self:GetJsonThemesFromTableMenu()
    self.logger:Info("Found " .. #jsonThemes .. " JSON themes.")
    -- Load each theme and extract tokens
    for _, themeFile in ipairs(jsonThemes) do
        self:LoadTheme(themeFile)
    end
end
registerLuaFunctionHighlight('LoadThemes')

--
--- Retrieves JSON theme file names from the table menu.
--- @return table - A list of JSON theme file names.
----------
function FormManager:GetJsonThemesFromTableMenu()
    local jsonThemes = {}
    self:InitializeTableMenu()
    local tableMenu = MainForm.findComponentByName("miTable")
    local count = tableMenu.getCount()
    if count == 0 then
        self.logger:Error("Error: 'miTable' component does not contain any items.")
        error("Error: 'miTable' component does not contain any items.")
    end
    self.logger:Info("Found " .. count .. " items in the 'miTable' component.")
    for i = 0, count - 1 do
        local caption = tableMenu[i].Caption
        if caption:find(".json") then
            table.insert(jsonThemes, caption)
            self.logger:Debug("Found JSON theme: " .. caption)
        end
    end
    return jsonThemes
end

--
--- @return None.
----------
function FormManager:InitializeTableMenu()
    local tableMenu = MainForm.findComponentByName("miTable")
    if not tableMenu then
        self.logger:Error("Error: MainForm does not contain 'miTable' component.")
        error("Error: MainForm does not contain 'miTable' component.")
    end
    tableMenu.doClick()
end

--
--- Loads a single theme and its tokens.
--- @param themeFile string - The file name of the theme to load.
----------
function FormManager:LoadTheme(themeFile)
    local themeName = extractFileNameWithoutExt(themeFile)
    self.logger:Info("Loading theme: " .. themeName)
    local rawData = json:decode(self:ReadTableFile(themeFile))
    local tokens = self:GetThemeTokens()
    self.themes[themeName] = {}
    local missingTokens, invalidTokens = {}, {}
    for _, token in ipairs(tokens) do
        local color = self:TokenColor(rawData, token)
        if not color then
            table.insert(missingTokens, token)
        elseif type(color) ~= "number" then
            table.insert(invalidTokens, { token = token, value = tostring(color) })
        end
        self.themes[themeName][token] = color
    end
    -- Log missing tokens
    if #missingTokens > 0 then
        self.logger:Warn(string.format("Theme '%s' is missing %d tokens: %s", 
            themeName, #missingTokens, table.concat(missingTokens, ", ")))
    end
    -- Log invalid tokens
    if #invalidTokens > 0 then
        for _, entry in ipairs(invalidTokens) do
            self.logger:Warn(string.format("Invalid token in theme '%s': '%s' -> '%s' (Expected number)", 
                themeName, entry.token, entry.value))
        end
    end
    self.logger:Info("Successfully loaded theme: " .. themeName)
end

--
--- Reads the content of a table file.
--- @param fileName string - The name of the table file to read.
--- @return string - The content of the table file.
----------
function FormManager:ReadTableFile(fileName)
    if not fileName then
        self.logger:Error("Invalid Table File Name.")
        error("Invalid Table File Name.")
    end
    local tableFile = findTableFile(fileName)
    if not tableFile then
        self.logger:Error("Table file not found: " .. fileName)
        error("Table file not found: " .. fileName)
    end
    local stream = createStringStream()
    stream.copyFrom(tableFile.Stream, tableFile.Stream.Size)
    local data = stream.DataString
    stream.destroy()
    self.logger:Info("Table file " .. fileName .. " read successfully.")
    return data
end

--
--- Returns the list of tokens to extract from themes.
--- @return table - A list of token names.
----------
function FormManager:GetThemeTokens()
    return {
        "editor.background",
        "editor.foreground",
        "comment",
        "string",
        "keyword",
        "variable",
        "variable.parameter",
        "keyword.control",
        "constant.numeric",
        "entity.name.function",
        "entity.name.class",
        "support.class",
        "constant.other.color"
    }
end

--
--- Logs all available themes and their associated color properties.
--- Iterates through the `self.themes` table and prints each theme's name and its tokens with corresponding colors.
--- If no themes are available, it outputs a message indicating the absence of themes.
--- @return None.
----------
function FormManager:LogThemes()
    for themeName, themeData in pairs(self.themes) do
        self.logger:Fatal("Theme: " .. themeName)
        for token, color in pairs(themeData) do
            self.logger:Error("\t" .. token .. ": " .. self:ConvertToHex(self:ConvertBGRtoRGB(color)))
        end
    end
end
registerLuaFunctionHighlight('LogThemes')

--
--- Applies a visual theme to the user interface by customizing the colors of various UI elements.
--- If the specified theme is not found, it attempts to reload themes before applying.
--- Updates address list, main form colors, fonts, and other visual properties based on the selected theme.
--- @param themeName string - The name of the theme to apply.
----------
function FormManager:ApplyTheme(themeName, allowReapply)
    local theme = self:GetTheme(themeName)
    if not theme then return end
    if self.currentTheme == themeName and not allowReapply then 
        self.logger:Warn("Theme '" .. themeName .. "' is already applied. Skipping.")
        return
    end
    self:ApplyThemeToTreeView(theme)
    self:ApplyThemeToAddressList(theme)
    self:ApplyThemeToMainForm(theme)
    self:ApplyThemeToAddressRecords(theme)
    self.currentTheme = themeName
    self.logger:Info("Theme '" .. themeName .. "' applied successfully.")
end
registerLuaFunctionHighlight('ApplyTheme')

--
--- Retrieves the theme by name, loading themes if necessary.
--- @param themeName string - The name of the theme to retrieve.
--- @return table - The theme data or nil if not found.
----------
function FormManager:GetTheme(themeName)
    local theme = self.themes[themeName]
    if not theme then
        self.logger:Info("Theme '" .. themeName .. "' not found. Attempting to load themes.")
        self:LoadThemes()
        theme = self.themes[themeName]
        if not theme then
            self.logger:Error("Error: Theme '" .. themeName .. "' could not be found after loading themes.")
        end
    else
        self.logger:Info("Applying theme '" .. themeName .. "'.")
    end
    return theme
end

--
--- Applies the theme to the TreeView component.
--- @param theme table - The theme data.
----------
function FormManager:ApplyThemeToTreeView(theme)
    local addressList = getAddressList()
    local treeView = addressList.Control[0]
    treeView.Color = theme["editor.background"] or treeView.Color
    local font = createFont()
    font.Name = "Consolas"
    font.Color = theme["editor.foreground"] or font.Color
    treeView.Font = font
    self.logger:Info("Updated TreeView background color and font.")
end

--
--- Applies the theme to the Address List component.
--- @param theme table - The theme data.
----------
function FormManager:ApplyThemeToAddressList(theme)
    local addressList = getAddressList()
    addressList.CheckboxColor = theme["keyword"] or addressList.CheckboxColor
    addressList.CheckboxActiveColor = theme["editor.foreground"] or addressList.CheckboxActiveColor
    addressList.CheckboxSelectedColor = theme["keyword"] or addressList.CheckboxSelectedColor
    addressList.CheckboxActiveSelectedColor = theme["editor.foreground"] or addressList.CheckboxActiveSelectedColor
    addressList.List.BackgroundColor = theme["editor.background"] or addressList.Control[0].BackgroundColor
    addressList.Header.Font.Color = theme["keyword"] or AddressList.Header.Font.Color
    self.logger:Info("Updated Address List checkbox and list colors.")
end

--
--- Applies the theme to the Main Form components.
--- @param theme table - The theme data.
----------
function FormManager:ApplyThemeToMainForm(theme)
    local mainForm = getMainForm()
    mainForm.Foundlist3.Color = theme["editor.background"] or mainForm.Foundlist3.Color
    mainForm.Color = theme["editor.background"] or mainForm.Color
    mainForm.Panel4.BevelColor = theme["keyword"] or mainForm.Panel4.BevelColor
    mainForm.lblSigned.Font.Color = theme["keyword"] or mainForm.lblSigned.Font.Color
    mainForm.Splitter1.Color = theme["keyword"] or mainForm.Splitter1.Color
    local sloganStr = MainForm.findComponentByName("SLOGAN_STR")
    if sloganStr then
        sloganStr.Font.Color = theme["keyword"] or sloganStr.Font.Color
        self.logger:Info("Updated 'SLOGAN_STR' font color.")
    end
    self.logger:Info("Updated Main Form colors.")
end

--
--- Applies the theme to all Address Records.
--- @param theme table - The theme data.
----------
function FormManager:ApplyThemeToAddressRecords(theme)
    local addressList = getAddressList()
    local stringTypes = { [vtString] = true, [vtUnicodeString] = true }
    local integerTypes = { [vtByte] = true, [vtWord] = true, [vtDword] = true, [vtQword] = true }
    local floatTypes = { [vtSingle] = true, [vtDouble] = true }
    local updatedCount, skippedCount = 0, 0
    for i = 0, addressList.Count - 1 do
        local record = addressList[i]
        local newColor = self:GetRecordColor(record, theme, stringTypes, integerTypes, floatTypes)
        -- Ensure correct BGR handling when comparing colors
        if record.Color ~= newColor then
            local logMessage = "Updating color for '" .. record.Description .. "': Old (#" .. string.format("%06X", record.Color) .. ") -> New (#" .. string.format("%06X", newColor) .. ")"
            self.logger:Info(logMessage)
            record.Color = newColor
            updatedCount = updatedCount + 1
        else
            local logMessage = "Skipping '" .. record.Description .. "': Color already set to #" .. string.format("%06X", record.Color)
            self.logger:Debug(logMessage)
            skippedCount = skippedCount + 1
        end
    end
    self.logger:Info("Color update complete: " .. updatedCount .. " updated, " .. skippedCount .. " skipped.")
end

--
--- Determines the appropriate color for an address record based on its type.
--- @param record table - The address record.
--- @param theme table - The theme data.
--- @param stringTypes table - The valid string types.
--- @param integerTypes table - The valid integer types.
--- @param floatTypes table - The valid float types.
--- @return string - The color to apply.
----------
function FormManager:GetRecordColor(record, theme, stringTypes, integerTypes, floatTypes)
    local token, color, reason
    if record.Type == vtAutoAssembler then
        token, color, reason = "entity.name.function", theme["entity.name.function"], "AutoAssembler Type"
    elseif record.IsAddressGroupHeader then
        token, color, reason = "keyword", theme["keyword"], "Address Group Header"
    elseif record.IsGroupHeader then
        token, color, reason = "comment", theme["comment"], "Group Header"
    elseif record.OffsetCount == 0 and not tonumber(record.AddressString, 16) then
        token, color, reason = "variable.parameter", theme["variable.parameter"] or theme["variable"], "User-defined values"
    elseif record.ShowAsHex then
        token, color, reason = "support.class", theme["support.class"] or theme["keyword.control"], "Hex Values"
    elseif stringTypes[record.Type] then
        token, color, reason = "string", theme["string"], "String Type"
    elseif integerTypes[record.Type] then
        token, color, reason = "entity.name.class", theme["entity.name.class"], "Integer Type"
    elseif floatTypes[record.Type] then
        token, color, reason = "constant.other.color", theme["constant.other.color"] or theme["constant.numeric"], "Float Type"
    else
        token, color, reason = "editor.foreground", theme["editor.foreground"], "Default editor foreground"
    end
    local appliedColor = color or record.Color
    local recordName = record.Description or "<Unnamed Record>"
    self.logger:Debug(string.format(
        "Determined Theme Color For Record: '%s' Reason: %s | Color: 0x%06X",
        recordName, reason, appliedColor
    ))
    return appliedColor
end

--
--- Sets a color property, prompting the user if no color is given.
--- @param color string|nil - The color value.
--- @param default string - The default color value.
--- @return string - The final color value.
----------
function FormManager:SetColor(color)
    if not inMainThread() then
        self.logger:Debug("Switching to main thread to set color.")
        synchronize(function(thread)
            self:SetColor(color)
        end)
        return
    end
    if not color then
        self.logger:Info("Prompting user for color input.")
        color = inputQuery("(Hex) Color", "Enter the color to apply:", "#RRGGBB")
    end
    if not color:match("^#%x%x%x%x%x%x$") then
        self.logger:Error("Invalid color format. Expected #RRGGBB.")
        return nil
    end
    local r, g, b = self:ConvertToRGB(color)
    if not (r and g and b) or r > 255 or g > 255 or b > 255 then
        self.logger:Error("Invalid color value. Each component must be between 00 and FF.")
        return nil
    end
    self.logger:Info("Color set successfully: " .. color)
    return color:bgr()
end

--
--- Sets a font color property for a given component.
--- @param component table - The UI component.
--- @param color string|nil - The color value.
----------
function FormManager:SetFontColor(component, color)
    if not component then
        self.logger:Warning("Component is nil. Cannot set font color.")
        return
    end
    local font = createFont()
    font.Name = "Consolas"
    font.Color = self:SetColor(color) or "#FFFFFF"
    component.Font = font
    self.logger:Info("Font color updated for component.")
end

--
--- Sets the color for Foundlist3
--- @param color string|nil
----------
function FormManager:SetFoundlist3Color(color)
    MainForm.Foundlist3.Color = self:SetColor(color)
end
registerLuaFunctionHighlight('SetFoundlist3Color')

--
--- Gets the color for Foundlist3
--- @return string
----------
function FormManager:GetFoundlist3Color()
    local colorInfo = FormManager:GetFullColorInfo(MainForm.Foundlist3.Color)
    self.logger:Fatal("Foundlist3 Color:", { ColorInfo = colorInfo})
    return color
end
registerLuaFunctionHighlight('GetFoundlist3Color')

--
--- Sets the color for MainForm
--- @param color string|nil
----------
function FormManager:SetMainFormColor(color)
    MainForm.Color = self:SetColor(color)
end
registerLuaFunctionHighlight('SetMainFormColor')

--
--- Gets the color for MainForm
--- @return string
----------
function FormManager:GetMainFormColor()
    local colorInfo = FormManager:GetFullColorInfo(MainForm.Color)
    self.logger:Fatal("MainForm Color:",{ ColorInfo = colorInfo})
    return color
end
registerLuaFunctionHighlight('GetMainFormColor')

--
--- Sets the color for lblSigned Font
--- @param color string|nil
----------
function FormManager:SetLblSignedFontColor(color)
    MainForm.lblSigned.Font.Color = self:SetColor(color)
end
registerLuaFunctionHighlight('SetLblSignedFontColor')

--
--- Gets the color for lblSigned Font
--- @return string
----------
function FormManager:GetLblSignedFontColor()
    local colorInfo = FormManager:GetFullColorInfo(MainForm.lblSigned.Font.Color)
    self.logger:Fatal("lblSigned Font Color:",{ ColorInfo = colorInfo})
    return color
end
registerLuaFunctionHighlight('GetLblSignedFontColor')

--
--- Sets the checkbox color in AddressList
--- @param color string|nil
----------
function FormManager:SetCheckboxColor(color)
    AddressList.CheckboxColor = self:SetColor(color)
end
registerLuaFunctionHighlight('SetCheckboxColor')

--
--- Gets the checkbox color in AddressList
--- @return string
----------
function FormManager:GetCheckboxColor()
    local colorInfo = FormManager:GetFullColorInfo(AddressList.CheckboxColor)
    self.logger:Fatal("Addresslist Checkbox Color:",{ ColorInfo = colorInfo})
    return color
end
registerLuaFunctionHighlight('GetCheckboxColor')

--
--- Sets the background color of the AddressList
--- @param color string|nil
----------
function FormManager:SetAddressListBackgroundColor(color)
    AddressList.List.BackgroundColor = self:SetColor(color)
end
registerLuaFunctionHighlight('SetAddressListBackgroundColor')

--
--- Gets the background color of the AddressList
--- @return string
----------
function FormManager:GetAddressListBackgroundColor()
    local colorInfo = FormManager:GetFullColorInfo(AddressList.Control[0].Color)
    self.logger:Fatal("Addresslist Background Color:",{ ColorInfo = colorInfo})
    return color
end
registerLuaFunctionHighlight('GetAddressListBackgroundColor')

--
--- Sets the color for the first control in AddressList
--- @param color string|nil
----------
function FormManager:SetAddressListControlColor(color)
    AddressList.Control[0].Color = self:SetColor(color)
end
registerLuaFunctionHighlight('SetAddressListControlColor')

--
--- Gets the color for the first control in AddressList
--- @return string
----------
function FormManager:GetAddressListControlColor()
    local colorInfo = FormManager:GetFullColorInfo(AddressList.Control[0].Color)
    self.logger:Fatal("AddressList Control[0] Color:",{ ColorInfo = colorInfo})
    return color
end
registerLuaFunctionHighlight('GetAddressListControlColor')

--
--- Converts a color integer to hex format
--- @param color number
--- @return string
----------
function FormManager:ConvertToHex(color)
    return string.format("#%06X", color)
end

--
--- Converts a color integer to RGB format
--- @param color number
--- @return number, number, number
----------
function FormManager:ConvertToRGB(color)
    local r = (color >> 16) & 0xFF
    local g = (color >> 8) & 0xFF
    local b = color & 0xFF
    return r, g, b
end

--
--- Converts a BGR color integer to RGB
--- @param color number
--- @return number
----------
function FormManager:ConvertBGRtoRGB(color)
    local b = (color >> 16) & 0xFF
    local g = (color >> 8) & 0xFF
    local r = color & 0xFF
    return (r << 16) | (g << 8) | b
end

function FormManager:ConvertRGBtoBGR(color)
    local r = (color >> 16) & 0xFF
    local g = (color >> 8) & 0xFF
    local b = color & 0xFF
    return (b << 16) | (g << 8) | r
end

--
--- Converts RGB to CMYK
--- @param r number
--- @param g number
--- @param b number
--- @return number, number, number, number
----------
function FormManager:ConvertRGBtoCMYK(r, g, b)
    if r == 0 and g == 0 and b == 0 then
        return 0, 0, 0, 100
    end

    local c = 1 - (r / 255)
    local m = 1 - (g / 255)
    local y = 1 - (b / 255)
    local k = math.min(c, m, y)

    c = (c - k) / (1 - k)
    m = (m - k) / (1 - k)
    y = (y - k) / (1 - k)

    return c * 100, m * 100, y * 100, k * 100
end

--
--- Converts RGB to HSL
--- @param r number
--- @param g number
--- @param b number
--- @return number, number, number
----------
function FormManager:ConvertRGBtoHSL(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local max, min = math.max(r, g, b), math.min(r, g, b)
    local h, s, l = 0, 0, (max + min) / 2

    if max ~= min then
        local d = max - min
        s = l > 0.5 and d / (2 - max - min) or d / (max + min)
        if max == r then h = (g - b) / d + (g < b and 6 or 0)
        elseif max == g then h = (b - r) / d + 2
        elseif max == b then h = (r - g) / d + 4
        end
        h = h / 6
    end

    return h * 360, s * 100, l * 100
end

--
--- Converts RGB to HSV
--- @param r number
--- @param g number
--- @param b number
--- @return number, number, number
----------
function FormManager:ConvertRGBtoHSV(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local max, min = math.max(r, g, b), math.min(r, g, b)
    local h, s, v = 0, 0, max

    local d = max - min
    s = max == 0 and 0 or d / max

    if max ~= min then
        if max == r then h = (g - b) / d + (g < b and 6 or 0)
        elseif max == g then h = (b - r) / d + 2
        elseif max == b then h = (r - g) / d + 4
        end
        h = h / 6
    end

    return h * 360, s * 100, v * 100
end

--
--- Gets all color representations from an integer color
--- @param color number
--- @return table
----------
function FormManager:GetFullColorInfo(color)
    local rgbColor = self:ConvertBGRtoRGB(color) -- Convert from BGR to RGB beforehand
    local hexColor = self:ConvertToHex(rgbColor)
    local r, g, b = self:ConvertToRGB(rgbColor)
    local c, m, y, k = self:ConvertRGBtoCMYK(r, g, b)
    local hHSL, sHSL, lHSL = self:ConvertRGBtoHSL(r, g, b)
    local hHSV, sHSV, vHSV = self:ConvertRGBtoHSV(r, g, b)
    return {
        hex = hexColor,
        rgb = { r, g, b },
        cmyk = { c, m, y, k },
        hsl = { hHSL, sHSL, lHSL },
        hsv = { hHSV, sHSV, vHSV }
    }
end

--
--- Deletes all subrecords (child memory records) of the given parent record.
--- Iterates through the subrecords and removes them one by one.
--- @param record userdata - The parent memory record whose subrecords will be deleted.
----------
function FormManager:delete_subrecords(record)
    while record ~= nil and record.Count > 0 do
        memoryrecord_delete(record.Child[0])
    end
end

--
--- Deactivates all subrecords (child memory records) of the given parent record.
--- Iterates through the subrecords and sets their "Active" property to false.
--- @param record userdata - The parent memory record whose subrecords will be deactivated.
----------
function FormManager:deactivate_subrecords(record)
    for i = 0, record.Count - 1 do
        record.Child[i].Active = false
    end
end

--
--
---
----
------------
-- New Module Section: Memory Record Factory
------------
----
---
--
--

--
--- Memory Record Factory
--- This section provides utilities for creating and managing memory records,
--- allowing for easy organization and nesting within an address list. 
--- It includes functionality for creating generic records, headers, 
--- and structures recursively, ensuring flexibility and efficiency in memory management.
----------

FormManager.FallbackDescription = "Default Description"
FormManager.FallbackAddress = 0x0
FormManager.FallbackType = vtByte

--
--- Value Type Map
--- Maps value type IDs to their corresponding string representations.
----------
local ValueTypeMap = {
    [0] = "vtByte",
    [1] = "vtWord",
    [2] = "vtDword",
    [3] = "vtQword",
    [4] = "vtSingle",
    [5] = "vtDouble",
    [6] = "vtString",
    [7] = "vtUnicodeString",
    [8] = "vtByteArray",
    [9] = "vtBinary",
    [11] = "vtAutoAssembler",
    [12] = "vtPointer",
    [13] = "vtCustom",
    [14] = "vtGrouped"
}

--
--- Retrieves the string representation of a value type by its ID.
--- @param id Number The ID of the value type.
--- @return String|nil The string representation of the value type, or nil if not found.
----------
function FormManager:GetValueTypeString(id)
    return ValueTypeMap[id]
end

--
--- Creates a generic memory record and adds it to the address list or a specified parent.
--- @param parent MemoryRecord|nil Parent memory record  to nest under, or nil for root.
--- @param description String|nil Description of the memory record.
--- @param valueType Number|nil Value type (e.g., "vtByte", "vtDword", etc.). 
---        vtByte=0; vtWord=1; vtDword=2; vtQword=3; vtSingle=4; vtDouble=5; vtString=6;
---        vtUnicodeString=7; vtByteArray=8; vtBinary=9; vtAutoAssembler=11; vtPointer=12;
---        vtCustom=13; vtGrouped=14
--- @return MemoryRecord The newly created memory record.
----------
function FormManager:CreateMemoryRecord(parent, description, valueType)
    -- self.logger:Info("Creating memory record with parameters - Parent: " .. tostring(parent.Description) .. ", Description: " .. tostring(description) .. ", ValueType: " .. self:GetValueTypeString(valueType))
    local addressList = getAddressList()
    local container = parent or addressList
    local record = addressList.createMemoryRecord()
    record.Parent = container
    record.Description = description or self.FallbackDescription
    record.Type = valueType or self.FallbackType
    self.logger:Info("Memory record created: " .. record.Description)
    return record
end

--
--- Creates a header memory record with address support.
--- @param parent MemoryRecord|nil Parent memory record  to nest under, or nil for root.
--- @param description String|nil Description of the memory record.
--- @return MemoryRecord The newly created header memory record.
----------
function FormManager:CreateHeaderWithAddress(parent, description, address)
    -- self.logger:Info("Creating header with address - Parent: " .. tostring(parent.Description) .. ", Description: " .. tostring(description) .. ", Address: " .. tostring(address))
    local record = self:CreateMemoryRecord(parent, description)
    record.IsAddressGroupHeader = true
    record.Description = description or self.FallbackDescription
    record.Address = address or self.FallbackAddress
    self.logger:Info("Header with address created: " .. record.Description .. " with Address: " .. record.Address)
    return record
end

--
--- Creates a generic header memory record without address support.
--- @param parent MemoryRecord|nil Parent memory record  to nest under, or nil for root.
--- @param description String|nil Description of the memory record.
--- @return MemoryRecord The newly created header memory record.
----------
function FormManager:CreateGenericHeader(parent, description)
    -- self.logger:Info("Creating generic header - Parent: " .. tostring(parent.Description) .. ", Description: " .. tostring(description))
    local record = self:CreateMemoryRecord(parent, description)
    record.IsGroupHeader = true
    record.Description = description or self.FallbackDescription
    self.logger:Info("Generic header created: " .. record.Description)
    return record
end

--
--- Retrieves a memory record by its description. If the record does not exist and "createIfNotFound" is "true", 
--- it creates a new generic group header memory record with the given description.
--- @param description String The description of the memory record to search for.
--- @param createIfNotFound Boolean|nil Whether to create a new memory record if one does not exist (default: false).
--- @return MemoryRecord|nil The memory record found or created, or "nil" if not found and creation is disabled.
----------
function FormManager:GetMemoryRecordByDescription(description, createIfNotFound)
    local addressList = getAddressList()
    local record = addressList.getMemoryRecordByDescription(description)
    if record then
        self.logger:Info("Memory record found: " .. description .. " with Type: " .. self:GetValueTypeString(record.Type))
        return record
    elseif createIfNotFound then
        self.logger:Info("Memory record not found. Creating new generic header: " .. description)
        record = self:CreateGenericHeader(nil, description)
        if record then
            self.logger:Info("New generic header created: " .. description)
            return record
        else
            self.logger:Error("Memory record not found and creation failed: " .. description)
        end
    else
        self.logger:Error("Memory record not found and creation not allowed: " .. description)
    end
end
registerLuaFunctionHighlight('GetMemoryRecordByDescription')

--
--- Recursive function to create a memory record structure.
--- @param parent MemoryRecord|nil The parent record or nil for root.
--- @param structure Table The structure definition.
----------
function FormManager:BuildStructure(parent, structure)
    for _,item in ipairs(structure) do 
        self.logger:Info("Processing item: " .. tostring(item.description) .. " with isHeader: " .. tostring(item.isHeader))
        local record
        if item.isHeader then
            if item.address then 
                record = self:CreateHeaderWithAddress(parent, item.description, item.address)
            else record = self:CreateGenericHeader(parent, item.description)
            end
        else
            record = self:CreateMemoryRecord(parent, item.description, item.valueType)
        end
        if item.hideChildren then
            record.Options = "[moHideChildren]"
            self.logger:Info("Item '" .. item.description .. "' is set to hide children.")
        end
        if item.children then
            self.logger:Info("Item '" .. item.description .. "' has children, building structure for them.")
            self:BuildStructure(record, item.children)
        end
    end
end
registerLuaFunctionHighlight('BuildStructure')

return FormManager