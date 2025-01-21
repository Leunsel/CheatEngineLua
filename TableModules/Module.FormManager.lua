local NAME = 'CTI.FormManager'
local AUTHOR = {'Leunsel', 'LeFiXER'}
local VERSION = '1.0.1'
local DESCRIPTION = 'Cheat Table Interface (Form Manager)'

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

FormManager.SloganObj = nil
FormManager.SignatureObj = nil

function FormManager:new(properties)
    if FormManager.instance then
        return FormManager.instance
    end
    local obj = setmetatable({}, self)
    for key, value in pairs(properties) do
        if self[key] ~= nil then
            obj[key] = value
        end
    end
    obj.logger = Logger:new()
    -- obj.logger:setMinLevel("ERROR")
    FormManager.instance = obj
    return obj
end

--
--- Runs a given function in the main thread. If already in the main thread, it executes the function immediately.
--- @param func function - The function to be executed in the main thread.
--- @return None.
----------
function FormManager:RunInMainThread(func)
    if not inMainThread() then
        synchronize(func)
        return
    end
    func()
end

--
--- Sets the logger instance for logging within the FormManager.
--- @param logger table - The logger instance to be used.
--- @return None.
----------
function FormManager:GetLoggerInstance(logger)
    self.logger = logger
end

--
--- Creates or updates a label with the specified properties.
--- If a label already exists, it updates its properties; otherwise, it creates a new label.
--- @param parent Object - The parent control that will contain the label.
--- @param label Object|nil - The existing label to update, or nil to create a new label.
--- @param defaultProperties table - A table containing the default properties to apply to the label.
---   @field Name string - The name of the label (optional).
---   @field Caption string - The text to display on the label (optional).
---   @field Alignment string - The alignment of the labels text (optional).
---   @field FontName string - The font name to use for the labels text (optional).
---   @field FontSize number - The font size to use for the labels text (optional).
---   @field FontStyle string - The font style to use for the labels text (optional).
---   @field FontColor number - The font color to use for the labels text (optional).
---   @field Visible boolean - Whether the label is visible or not (optional).
---   @field BorderSpacingBottom number - The bottom border spacing for the label (optional).
--- @return Object - The created or updated label.
----------
function FormManager:CreateOrUpdateLabel(parent, label, defaultProperties)
    if not label then
        label = createLabel(parent)
        label.Align = defaultProperties.Align or alTop
        label.AutoSize = true
    end
    label.Name = defaultProperties.Name or label.Name
    label.Caption = defaultProperties.Caption or label.Caption
    label.Alignment = defaultProperties.Alignment or label.Alignment
    label.Font.Name = defaultProperties.FontName or label.Font.Name
    label.Font.Color = defaultProperties.FontColor or label.Font.Color
    label.Font.Size = defaultProperties.FontSize or label.Font.Size
    label.Font.Style = defaultProperties.FontStyle or label.Font.Style
    label.Visible = (defaultProperties.Visible ~= nil) and defaultProperties.Visible or label.Visible
    label.BorderSpacing.Bottom = defaultProperties.BorderSpacingBottom or label.BorderSpacing.Bottom
    return label
end

--
--- Creates or updates a slogan string label with the given text.
--- @param str string - The text to display in the slogan label.
--- @return None.
----------
function FormManager:CreateSloganStr(str)
    self:RunInMainThread(function()
        local mainForm = getMainForm()
        local defaultProperties = {
            Name = "SLOGAN_STR",
            Caption =  str or self.Slogan or "",
            Alignment = "taCenter",
            FontName = "Consolas",
            FontSize = 20,
            FontStyle = "fsBold",
            Visible = true
        }
        self.SloganObj = mainForm:findComponentByName("SLOGAN_STR")
        if not self.SloganObj then
            self.SloganObj = self:CreateOrUpdateLabel(mainForm, nil, defaultProperties)
        else
            self:CreateOrUpdateLabel(mainForm, self.SloganObj, defaultProperties)
        end
        self.SloganObj = self.SloganObj
    end)
end

--
--- Starts scrolling a given text in the slogan label at a specified interval.
--- @param text string - The text to scroll.
--- @param interval number - The time interval (in ms) between scroll updates.
--- @param maxTicks number - Maximum number of scroll iterations (0 for unlimited scrolling).
--- @return None.
----------
function FormManager:ScrollText(text, interval, maxTicks)
    local function ScrollTextInner(text)
        return text:sub(2) .. text:sub(1, 1)
    end
    self.scrollingText = " " .. text
    self.scrollInterval = 500  -- Default interval is 500 ms
    self.scrollMaxTicks = maxTicks or 0  -- Default is unlimited scrolling
    local function ScrollTextTimer_tick(timer)
        if self.scrollMaxTicks ~= 0 then
            self.scrollMaxTicks = self.scrollMaxTicks - 1
            if self.scrollMaxTicks <= 0 then
                timer.destroy()
                return
            end
        end

        self.scrollingText = ScrollTextInner(self.scrollingText)
        self:CreateSloganStr(self.scrollingText)
    end
    if self.ScrollTextTimer then
        self.ScrollTextTimer.destroy()
    end
    self.ScrollTextTimer = createTimer(MainForm)
    self.ScrollTextTimer.Interval = self.scrollInterval
    self.ScrollTextTimer.OnTimer = ScrollTextTimer_tick
end
registerLuaFunctionHighlight('ScrollText')

--
--- Destroys a given label if it exists.
--- @param label object - The label object to be destroyed.
--- @return None.
----------
function FormManager:DestroyLabel(label)
    if label then
        label:destroy()
    end
end
registerLuaFunctionHighlight('DestroyLabel')

--
--- Destroys the slogan string object and sets it to nil.
--- @return None.
----------
function FormManager:DestroySloganStr()
    self:RunInMainThread(function()
        if self.SloganObj then
            self:DestroyLabel(self.SloganObj)
            self.SloganObj = nil
        end
    end)
end
registerLuaFunctionHighlight('DestroySloganStr')

--
--- Creates or updates the signature string label with the given text.
--- @param str string - The text to display in the signature string label.
--- @return None.
----------
function FormManager:CreateSignatureStr(str)
    self:RunInMainThread(function()
        local mainForm = getMainForm()
        local lblSigned = mainForm.lblSigned
        if lblSigned then
            lblSigned.Caption = str or self.Signature or ""
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
registerLuaFunctionHighlight('CreateSignatureStr')

--
--- Hides the signature string label if it exists.
--- @return None.
----------
function FormManager:HideSignatureStr()
    self:RunInMainThread(function()
        if self.SignatureObj then
            self.SignatureObj.Visible = false
        end
    end)
end
registerLuaFunctionHighlight('HideSignatureStr')

--
--- Toggles the visibility of a specified control in the main form.
--- @param controlName string - The name of the control to toggle visibility for.
--- @return None.
----------
function FormManager:ToggleControlVisibility(controlName)
    self:RunInMainThread(function()
        local mainForm = getMainForm()
        if mainForm and mainForm[controlName] then
            mainForm[controlName].Visible = not mainForm[controlName].Visible
        end
    end)
end
registerLuaFunctionHighlight('ToggleControlVisibility')

--
--- Sets the visibility of a specified control in the main form.
--- @param controlName string - The name of the control to modify visibility.
--- @param isVisible boolean - True to make the control visible, false to hide it.
--- @return None.
----------
function FormManager:SetControlVisibility(controlName, isVisible)
    self:RunInMainThread(function()
        local mainForm = getMainForm()
        if mainForm and mainForm[controlName] then
            mainForm[controlName].Visible = isVisible
        end
    end)
end
registerLuaFunctionHighlight('SetControlVisibility')

--
--- Toggles the visibility of specified header sections in the address list.
--- @param sections table - An array of section indices to toggle visibility for.
--- @return None.
----------
function FormManager:ToggleHeaderSections(sections)
    self:RunInMainThread(function()
        local header = getAddressList().Header
        for _, sectionIndex in ipairs(sections) do
            local section = header.Sections[sectionIndex]
            if section then
                section.Visible = not section.Visible
            end
        end
    end)
end
registerLuaFunctionHighlight('ToggleHeaderSections')

--
--- Disables drag-and-drop functionality for the address list tree view.
--- @return None.
----------
function FormManager:DisableDragDrop()
    self:RunInMainThread(function()
        local addressListTreeview = component_getComponent(AddressList, 0) -- Disable drag and drop events
        setMethodProperty(addressListTreeview, "OnDragOver", nil)
        setMethodProperty(addressListTreeview, "OnDragDrop", nil)
        setMethodProperty(addressListTreeview, "OnEndDrag", nil)
    end)
end
registerLuaFunctionHighlight('DisableDragDrop')

--
--- Disables sorting functionality for the address list header.
--- @return None.
----------
function FormManager:DisableHeaderSorting()
    self:RunInMainThread(function()
        local addressListHeader = component_getComponent(AddressList, 1)
        setMethodProperty(addressListHeader, "OnSectionClick", nil)
    end)
end
registerLuaFunctionHighlight('DisableHeaderSorting')

--
--- Enables compact mode by hiding specific controls in the form.
--- @return None.
----------
function FormManager:EnableCompactMode()
    self:SetControlVisibility("Panel5", false)
    self:SetControlVisibility("Splitter1", false)
end
registerLuaFunctionHighlight('EnableCompactMode')

--
--- Hides signature-related controls in the form.
--- @return None.
----------
function FormManager:HideSignatureControls()
    self:SetControlVisibility("CommentButton", false)
    self:SetControlVisibility("advancedbutton", false)
end
registerLuaFunctionHighlight('HideSignatureControls')

--
--- Toggles compact mode by toggling the visibility of specific controls.
--- @return None.
----------
function FormManager:ToggleCompactMode()
    self:RunInMainThread(function()
        self:ToggleControlVisibility("Panel5")
        self:ToggleControlVisibility("Splitter1")
    end)
end
registerLuaFunctionHighlight('ToggleCompactMode')

--
--- Toggles the visibility of signature-related controls.
--- @return None.
----------
function FormManager:ToggleSignatureControls()
    self:ToggleControlVisibility("CommentButton")
    self:ToggleControlVisibility("advancedbutton")
end
registerLuaFunctionHighlight('ToggleSignatureControls')

--
--- Manages the header sections by toggling visibility for predefined indices.
--- @return None.
----------
function FormManager:ManageHeaderSections()
    local sectionsToToggle = {0, 2, 3}
    self:toggleHeaderSections(sectionsToToggle)
end
registerLuaFunctionHighlight('ManageHeaderSections')

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
    local jsonThemes = {}
    if not json then
        json = CETrequire('json')
        self.logger:Info("JSON library loaded successfully.")
    end
    -- Helper function to read the content of a table file.
    --- @param name string - The name of the table file to read.
    --- @return string - The content of the table file.
    ----------
    local function readTableFile(name)
        if name == nil then
            self.logger:Error("Invalid Table File Name.")
            error("Invalid Table File Name.")
        end
        local mainStringStream = createStringStream()
        local tableFile = findTableFile(name)
        if not tableFile then
            self.logger:Error("Table file not found: " .. name)
            error("Table file not found: " .. name)
        end
        mainStringStream.copyFrom(tableFile.Stream, tableFile.Stream.Size)
        local data = mainStringStream.DataString
        mainStringStream.destroy()
        self.logger:Info("Table file " .. name .. " read successfully.")
        return data
    end
    --
    --- This "doClick()" is not optional.
    --- Cheat Engine is so damn retarded that the Table File Menu
    --- is not properly initialized unless you've actually interacted
    --- with the Menu Item.
    --- By default, Cheat Engine loads:
    ---     [+] Lua Files
    --- Nothing else.
    MainForm.findComponentByName("miTable").doClick()
    local tableMenu = MainForm.findComponentByName("miTable")
    if not tableMenu then
        self.logger:Error("Error: MainForm does not contain 'miTable' component.")
        error("Error: MainForm does not contain 'miTable' component.")
    end
    local count = tableMenu.getCount()
    if count == 0 then
        self.logger:Error("Error: 'miTable' component does not contain any items.")
        error("Error: 'miTable' component does not contain any items.")
    end
    self.logger:Info("Found " .. count .. " items in the 'miTable' component.")
    for i = 0, count - 1 do
        if (tableMenu[i].Caption):find(".json") then
            table.insert(jsonThemes, tableMenu[i].Caption)
            self.logger:Debug("Found JSON theme: " .. tableMenu[i].Caption)
        end
    end
    self.logger:Info("Found " .. #jsonThemes .. " JSON themes.")
    for i = 1, #jsonThemes do
        local raw = json.decode(readTableFile(jsonThemes[i]))
        local themeName = extractFileNameWithoutExt(jsonThemes[i])
        local tokens = {
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
            "editor.selectionHighlightBackground",
            "editor.inactiveSelectionBackground",
            "activityBarBadge.background",
            "support.class",
            "invalid",
            "keyword.operator",
            "constant.other.color"
        }
        self.themes[themeName] = {}
        self.logger:Info("Loading theme: " .. themeName)
        for _, token in ipairs(tokens) do
            local dbg = false
            if dbg and not self:TokenColor(raw, token) then
                self.logger:Error("Error: '" .. token .. "' token not found within '" .. themeName .. "' theme!")
            end
            self.themes[themeName][token] = self:TokenColor(raw, token)
        end
        self.logger:Info("Successfully loaded theme: " .. themeName)
    end
end
registerLuaFunctionHighlight('LoadThemes')

--
--- Logs all available themes and their associated color properties.
--- Iterates through the `self.themes` table and prints each theme's name and its tokens with corresponding colors.
--- If no themes are available, it outputs a message indicating the absence of themes.
--- @return None.
----------
function FormManager:LogThemes()
    for themeName, themeData in pairs(self.themes) do
        self.logger:Info("Theme: " .. themeName)
        for token, color in pairs(themeData) do
            self.logger:Debug("  " .. token .. ": " .. tostring(color))
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
function FormManager:ApplyTheme(themeName)
    local theme = self.themes[themeName]
    if theme == nil then
        self.logger:Info("Theme '" .. themeName .. "' not found. Attempting to load themes.")
        self:LoadThemes()
        theme = self.themes[themeName]
        if theme == nil then
            self.logger:Error("Error: Theme '" .. themeName .. "' could not be found after loading themes.")
            return
        end
    else
        self.logger:Info("Applying theme '" .. themeName .. "'")
    end
    local addressList = getAddressList()
    local treeView = addressList.Control[0]
    treeView.Color = theme["editor.background"] or treeView.Color
    local font = createFont()
    font.Name = "Consolas"
    font.Color = theme["editor.foreground"] or font.Color
    treeView.Font = font
    self.logger:Info("Updated treeView background color and font.")
    addressList.CheckboxColor = theme["keyword"] or addressList.CheckboxColor
    addressList.CheckboxActiveColor = theme["editor.foreground"] or addressList.CheckboxActiveColor
    addressList.CheckboxSelectedColor = theme["keyword"] or addressList.CheckboxSelectedColor
    addressList.CheckboxActiveSelectedColor = theme["editor.foreground"] or addressList.CheckboxActiveSelectedColor
    addressList.List.BackgroundColor = theme["editor.background"] or addressList.Control[0].BackgroundColor
    self.logger:Info("Updated checkbox and list colors.")
    getMainForm().Foundlist3.Color = theme["editor.background"] or getMainForm().Foundlist3.Color
    getMainForm().Color = theme["editor.background"] or getMainForm().Color
    getMainForm().lblSigned.Font.Color = theme["keyword"] or getMainForm().lblSigned.Font.Color
    self.logger:Info("Updated Main Form colors.")
    local sloganStr = MainForm.findComponentByName("SLOGAN_STR")
    if sloganStr then
        sloganStr.Font.Color = theme["keyword"] or sloganStr.Font.Color
        self.logger:Info("Updated 'SLOGAN_STR' font color.")
    end
    local stringTypes = { [vtString] = true, [vtUnicodeString] = true }
    local integerTypes = { [vtByte] = true, [vtWord] = true, [vtDword] = true, [vtQword] = true }
    local floatTypes = { [vtSingle] = true, [vtDouble] = true }
    for i = 0, addressList.Count - 1 do
        local mr = addressList[i]
        mr.Color = theme["editor.foreground"] or mr.Color -- other
        if mr.Type == vtAutoAssembler then
            mr.Color = theme["entity.name.function"] or mr.Color -- script
            self.logger:Debug("Applied 'entity.name.function' color to AutoAssembler type.")
        elseif mr.IsAddressGroupHeader then
            mr.Color = theme["keyword"] or mr.Color -- group with address
            self.logger:Debug("Applied 'keyword' color to Address Group Header.")
        elseif mr.IsGroupHeader then
            mr.Color = theme["comment"] or mr.Color -- group without address
            self.logger:Debug("Applied 'comment' color to Group Header.")
        elseif mr.OffsetCount == 0 and not tonumber(mr.AddressString, 16) then
            mr.Color = theme["variable.parameter"] or theme["variable"] or mr.Color -- user defined values
            self.logger:Debug("Applied 'variable' color to user-defined values.")
        elseif mr.ShowAsHex then
            mr.Color = theme["support.class"] or theme["keyword.control"] or mr.Color -- pointers and hex values
            self.logger:Debug("Applied 'support.class' color to Hex values.")
        elseif stringTypes[mr.Type] then
            mr.Color = theme["string"] or mr.Color -- string values
            self.logger:Debug("Applied 'string' color to String type.")
        elseif integerTypes[mr.Type] then
            mr.Color = theme["entity.name.class"] or mr.Color -- integer values
            self.logger:Debug("Applied 'entity.name.class' color to Integer type.")
        elseif floatTypes[mr.Type] then
            mr.Color = theme["constant.other.color"] or theme["constant.numeric"] or mr.Color -- float values
            self.logger:Debug("Applied 'constant.other.color' color to Float type.")
        else
            mr.Color = theme["editor.foreground"] or mr.Color -- other
            self.logger:Debug("Applied default 'editor.foreground' color.")
        end
    end
    self.currentTheme = themeName
    self.logger:Info("Theme '" .. themeName .. "' applied successfully.")
end
registerLuaFunctionHighlight('ApplyTheme')

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

return FormManager
