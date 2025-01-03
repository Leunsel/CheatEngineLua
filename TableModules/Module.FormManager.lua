local NAME = 'CTI.FormManager'
local AUTHOR = {'Leunsel', 'LeFiXER'}
local VERSION = '1.0.1'
local DESCRIPTION = 'Cheat Table Interface (Form Manager)'

FormManager = {
    Signature = "",
    Slogan = "",
    themes = {},
    instance = nil,
    currentTheme = nil
}
FormManager.__index = FormManager

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

-- FormManager Functions

function FormManager:runInMainThread(func)
    if not inMainThread() then
        synchronize(func)
        return
    end
    func()
end

function FormManager:getLoggerInstance(logger)
    self.logger = logger
end

function FormManager:readAll(file)
    local f = assert(io.open(file, "rb"))
    local content = f:read("*all")
    f:close()
    return content
end

function FormManager:rgb_to_bgr(RGB)
    local r = RGB // 0x10000
    local g = ((RGB % 0x10000) // 0x100) << 8
    local b = (RGB % 0x100) << 16
    return r + g + b
end

function string:bgr()
    local hexColorString = self:sub(2, 7)
    local RGB = tonumber(hexColorString, 16)
    return FormManager:rgb_to_bgr(RGB)
end

-- Token and Theme Functions

function FormManager:tokenSearch(scope, token)
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

function FormManager:tokenColor(raw, token)
    local rawColors = raw["colors"]
    if rawColors and rawColors[token] then
        return rawColors[token]:bgr()
    end
    local tokenColors = raw["tokenColors"]
    for _, item in ipairs(tokenColors) do
        if
            item["scope"] and self:tokenSearch(item["scope"], token) and item["settings"] and
                item["settings"]["foreground"]
         then
            return item["settings"]["foreground"]:bgr()
        end
    end
    return nil
end

function FormManager:loadThemes()
    local jsonThemes = {}
    if not json then
        json = CETrequire('json')
        self.logger:info("JSON library loaded successfully.")
    end
    local function readTableFile(name)
        if name == nil then
            self.logger:error("Invalid Table File Name.")
            error("Invalid Table File Name.")
        end
        local mainStringStream = createStringStream()
        local tableFile = findTableFile(name)
        if not tableFile then
            self.logger:error("Table file not found: " .. name)
            error("Table file not found: " .. name)
        end
        mainStringStream.copyFrom(tableFile.Stream, tableFile.Stream.Size)
        local data = mainStringStream.DataString
        mainStringStream.destroy()
        self.logger:info("Table file " .. name .. " read successfully.")
        return data
    end
    MainForm.findComponentByName("miTable").doClick()
    local tableMenu = MainForm.findComponentByName("miTable")
    if not tableMenu then
        self.logger:error("Error: MainForm does not contain 'miTable' component.")
        error("Error: MainForm does not contain 'miTable' component.")
    end
    local count = tableMenu.getCount()
    if count == 0 then
        self.logger:error("Error: 'miTable' component does not contain any items.")
        error("Error: 'miTable' component does not contain any items.")
    end
    self.logger:info("Found " .. count .. " items in the 'miTable' component.")
    for i = 0, count - 1 do
        if (tableMenu[i].Caption):find(".json") then
            table.insert(jsonThemes, tableMenu[i].Caption)
            self.logger:debug("Found JSON theme: " .. tableMenu[i].Caption)
        end
    end
    self.logger:info("Found " .. #jsonThemes .. " JSON themes.")
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
        self.logger:info("Loading theme: " .. themeName)
        for _, token in ipairs(tokens) do
            local dbg = false
            if dbg and not self:tokenColor(raw, token) then
                self.logger:error("Error: '" .. token .. "' token not found within '" .. themeName .. "' theme!")
            end
            self.themes[themeName][token] = self:tokenColor(raw, token)
        end
        self.logger:info("Successfully loaded theme: " .. themeName)
    end
end

function FormManager:logThemes()
    for themeName, themeData in pairs(self.themes) do
        print("Theme: " .. themeName)
        for token, color in pairs(themeData) do
            print("  " .. token .. ": " .. tostring(color))
        end
    end
end

-- UI Management Functions

function FormManager:createOrUpdateLabel(parent, label, defaultProperties)
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

function FormManager:createSloganStr(str)
    self:runInMainThread(function()
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
            self.SloganObj = self:createOrUpdateLabel(mainForm, nil, defaultProperties)
        else
            self:createOrUpdateLabel(mainForm, self.SloganObj, defaultProperties)
        end
        
        self.SloganObj = self.SloganObj
    end)
end

function FormManager:scrollText(text, interval, maxTicks)
    local function scrollTextInner(text)
        return text:sub(2) .. text:sub(1, 1)
    end

    self.scrollingText = " " .. text
    self.scrollInterval = 500  -- Default interval is 500 ms
    self.scrollMaxTicks = maxTicks or 0  -- Default is unlimited scrolling

    local function scrollTextTimer_tick(timer)
        if self.scrollMaxTicks ~= 0 then
            self.scrollMaxTicks = self.scrollMaxTicks - 1
            if self.scrollMaxTicks <= 0 then
                timer.destroy()
                return
            end
        end

        self.scrollingText = scrollTextInner(self.scrollingText)
        self:createSloganStr(self.scrollingText)
    end

    if self.scrollTextTimer then
        self.scrollTextTimer.destroy()
    end
    self.scrollTextTimer = createTimer(MainForm)
    self.scrollTextTimer.Interval = self.scrollInterval
    self.scrollTextTimer.OnTimer = scrollTextTimer_tick
end

function FormManager:destroyLabel(label)
    if label then
        label:destroy()
    end
end

function FormManager:destroySloganStr()
    self:runInMainThread(function()
        if self.SloganObj then
            self:destroyLabel(self.SloganObj)
            self.SloganObj = nil
        end
    end)
end

function FormManager:createSignatureStr(str)
    self:runInMainThread(function()
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

function FormManager:hideSignatureStr()
    self:runInMainThread(function()
        if self.SignatureObj then
            self.SignatureObj.Visible = false
        end
    end)
end

function FormManager:toggleControlVisibility(controlName)
    self:runInMainThread(function()
        local mainForm = getMainForm()
        if mainForm and mainForm[controlName] then
            mainForm[controlName].Visible = not mainForm[controlName].Visible
        end
    end)
end

function FormManager:setControlVisibility(controlName, isVisible)
    self:runInMainThread(function()
        local mainForm = getMainForm()
        if mainForm and mainForm[controlName] then
            mainForm[controlName].Visible = isVisible
        end
    end)
end


function FormManager:toggleHeaderSections(sections)
    self:runInMainThread(function()
        local header = getAddressList().Header
        for _, sectionIndex in ipairs(sections) do
            local section = header.Sections[sectionIndex]
            if section then
                section.Visible = not section.Visible
            end
        end
    end)
end

function FormManager:disableDragDrop()
    self:runInMainThread(function()
        local addressListTreeview = component_getComponent(AddressList, 0) -- Disable drag and drop events
        setMethodProperty(addressListTreeview, "OnDragOver", nil)
        setMethodProperty(addressListTreeview, "OnDragDrop", nil)
        setMethodProperty(addressListTreeview, "OnEndDrag", nil)
    end)
end

function FormManager:disableHeaderSorting()
    self:runInMainThread(function()
        local addressListHeader = component_getComponent(AddressList, 1)
        setMethodProperty(addressListHeader, "OnSectionClick", nil)
    end)
end

function FormManager:enableCompactMode()
    self:setControlVisibility("Panel5", false)
    self:setControlVisibility("Splitter1", false)
end

function FormManager:hideSignatureControls()
    self:setControlVisibility("CommentButton", false)
    self:setControlVisibility("advancedbutton", false)
end

function FormManager:toggleCompactMode()
    self:runInMainThread(function()
        self:toggleControlVisibility("Panel5")
        self:toggleControlVisibility("Splitter1")
    end)
end

function FormManager:toggleSignatureControls()
    self:toggleControlVisibility("CommentButton")
    self:toggleControlVisibility("advancedbutton")
end

function FormManager:manageHeaderSections()
    local sectionsToToggle = {0, 2, 3}
    self:toggleHeaderSections(sectionsToToggle)
end

-- Theme Application Functions

function FormManager:updateThemeSelector()
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
formManager:applyTheme(memrec.Description)
utility:autoDisable(memrec.ID)
[DISABLE]
]]
        mr.Description = themeName
        mr.Color = 0xFFFFF0
        mr.Parent = root
        mr.OnActivate = self.ToggleTrigger
        mr.OnDeactivate = self.ToggleTrigger
    end
end

function FormManager:getCurrentTheme()
    return self.currentTheme
end

function FormManager:applyTheme(themeName)
    local theme = self.themes[themeName]
    if theme == nil then
        self.logger:info("Theme '" .. themeName .. "' not found. Attempting to load themes.")
        self:loadThemes()
        theme = self.themes[themeName]
        if theme == nil then
            self.logger:error("Error: Theme '" .. themeName .. "' could not be found after loading themes.")
            print("Error: Theme '" .. themeName .. "' could not be found.")
            return
        end
    else
        self.logger:info("Applying theme '" .. themeName .. "'")
    end
    local addressList = getAddressList()
    local treeView = addressList.Control[0]
    treeView.Color = theme["editor.background"] or treeView.Color
    local font = createFont()
    font.Name = "Consolas"
    font.Color = theme["editor.foreground"] or font.Color
    treeView.Font = font
    self.logger:info("Updated treeView background color and font.")
    addressList.CheckboxColor = theme["keyword"] or addressList.CheckboxColor
    addressList.CheckboxActiveColor = theme["editor.foreground"] or addressList.CheckboxActiveColor
    addressList.CheckboxSelectedColor = theme["keyword"] or addressList.CheckboxSelectedColor
    addressList.CheckboxActiveSelectedColor = theme["editor.foreground"] or addressList.CheckboxActiveSelectedColor
    addressList.List.BackgroundColor = theme["editor.background"] or addressList.Control[0].BackgroundColor
    self.logger:info("Updated checkbox and list colors.")
    getMainForm().Foundlist3.Color = theme["editor.background"] or getMainForm().Foundlist3.Color
    getMainForm().Color = theme["editor.background"] or getMainForm().Color
    getMainForm().lblSigned.Font.Color = theme["keyword"] or getMainForm().lblSigned.Font.Color
    self.logger:info("Updated Main Form colors.")
    local sloganStr = MainForm.findComponentByName("SLOGAN_STR")
    if sloganStr then
        sloganStr.Font.Color = theme["keyword"] or sloganStr.Font.Color
        self.logger:info("Updated 'SLOGAN_STR' font color.")
    end
    local stringTypes = { [vtString] = true, [vtUnicodeString] = true }
    local integerTypes = { [vtByte] = true, [vtWord] = true, [vtDword] = true, [vtQword] = true }
    local floatTypes = { [vtSingle] = true, [vtDouble] = true }
    for i = 0, addressList.Count - 1 do
        local mr = addressList[i]
        mr.Color = theme["editor.foreground"] or mr.Color -- other
        if mr.Type == vtAutoAssembler then
            mr.Color = theme["entity.name.function"] or mr.Color -- script
            self.logger:debug("Applied 'entity.name.function' color to AutoAssembler type.")
        elseif mr.IsAddressGroupHeader then
            mr.Color = theme["keyword"] or mr.Color -- group with address
            self.logger:debug("Applied 'keyword' color to Address Group Header.")
        elseif mr.IsGroupHeader then
            mr.Color = theme["comment"] or mr.Color -- group without address
            self.logger:debug("Applied 'comment' color to Group Header.")
        elseif mr.OffsetCount == 0 and not tonumber(mr.AddressString, 16) then
            mr.Color = theme["variable.parameter"] or theme["variable"] or mr.Color -- user defined values
            self.logger:debug("Applied 'variable' color to user-defined values.")
        elseif mr.ShowAsHex then
            mr.Color = theme["support.class"] or theme["keyword.control"] or mr.Color -- pointers and hex values
            self.logger:debug("Applied 'support.class' color to Hex values.")
        elseif stringTypes[mr.Type] then
            mr.Color = theme["string"] or mr.Color -- string values
            self.logger:debug("Applied 'string' color to String type.")
        elseif integerTypes[mr.Type] then
            mr.Color = theme["entity.name.class"] or mr.Color -- integer values
            self.logger:debug("Applied 'entity.name.class' color to Integer type.")
        elseif floatTypes[mr.Type] then
            mr.Color = theme["constant.other.color"] or theme["constant.numeric"] or mr.Color -- float values
            self.logger:debug("Applied 'constant.other.color' color to Float type.")
        else
            mr.Color = theme["editor.foreground"] or mr.Color -- other
            self.logger:debug("Applied default 'editor.foreground' color.")
        end
    end
    self.currentTheme = themeName
    self.logger:info("Theme '" .. themeName .. "' applied successfully.")
end

-- Record Management Functions

function FormManager:delete_subrecords(record)
    while record ~= nil and record.Count > 0 do
        memoryrecord_delete(record.Child[0])
    end
end

function FormManager:deactivate_subrecords(record)
    for i = 0, record.Count - 1 do
        record.Child[i].Active = false
    end
end

return FormManager
