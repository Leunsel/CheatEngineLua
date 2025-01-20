local NAME = "CTI.TableFileExplorer"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Cheat Table Interface (Table File Explorer)"

local Colors = {
    Black = 0x000000,
    White = 0xFFFFFF,
    Red = 0x0000FF,
    Green = 0x00FF00,
    Blue = 0xFF0000,
    Yellow = 0x00FFFF,
    Cyan = 0xFFFF00,
    Magenta = 0xFF00FF,
    Gray = 0x808080,
    LightGray = 0xD3D3D3,
    DarkGray = 0x404040,
    Orange = 0x007FFF,
    Purple = 0x800080,
    Brown = 0x2A2AA5,
    Pink = 0xCBC0FF
}

local Themes = {
    Dark = {
        FormColor = Colors.Black,
        TreeViewColor = Colors.Black,
        TreeViewFontColor = Colors.Green,
        SynEditColor = Colors.Black,
        SynEditFontColor = Colors.White,
        SynEditGutterColor = Colors.Black,
        SynEditGutterLineNumberBackground = Colors.Black,
        SynEditGutterLineNumberForeground = Colors.Green,
        SynEditGutterSeparatorBackground = Colors.Black,
    },
    Light = {
        FormColor = Colors.White,
        TreeViewColor = Colors.White,
        TreeViewFontColor = Colors.Black,
        SynEditColor = Colors.White,
        SynEditFontColor = Colors.Black,
        SynEditGutterColor = Colors.White,
        SynEditGutterLineNumberBackground = Colors.White,
        SynEditGutterLineNumberForeground = Colors.Black,
        SynEditGutterSeparatorBackground = Colors.White,
    },
    Monokai = {
        FormColor = 0x272822,
        TreeViewColor = 0x3E3D32,
        TreeViewFontColor = 0xF8F8F2,
        SynEditColor = 0x272822,
        SynEditFontColor = 0xF8F8F2,
        SynEditGutterColor = 0x272822,
        SynEditGutterLineNumberBackground = 0x272822,
        SynEditGutterLineNumberForeground = 0x75715E,
        SynEditGutterSeparatorBackground = 0x3E3D32,
    },
}

local AppName = "Table File Explorer"

local AllowedFileTypes = {
      ".CEA",
      ".lua",
      ".json"
}

TableFileExplorer = {
    Form = 0,
    TreeView = 0,
    SynEditAsm = 0,
    SynEditLua = 0,
    ButtonPanel = 0,
    Splitter = 0,
    LoadButton = 0,
    SaveButton = 0,
    UpdateTreeButton = 0,
    Logger = 0
}
TableFileExplorer.__index = TableFileExplorer

if not Logger then
    CETrequire("Module.Logger")
end

if not Utility then
    CETrequire("Module.Utility")
end

function TableFileExplorer:new()
    if self.Instance then
        return self.Instance
    end
    local self = setmetatable({}, TableFileExplorer)
    self.Logger = Logger:new()
    self:InitializeForm()
    self:InitializeMenuStrip()
    self:InitializeTreeView()
    self:InitializeSynEdits()
    self:InitializeStatusBar()
    self:ApplyTheme("Monokai")
    self.Logger:info("TableFileExplorer initialized.")
    self.Instance = self
    self.Form.Hide()
    self.Form.CenterScreen()
    return self
end

function TableFileExplorer:InitializeForm()
    self.Form = createForm(false)
    self.Form.Top = -2000
    self.Form.Show()
    self.Form.Caption = AppName
    self.Form.BorderStyle = bsSizeable
    self.Form.Color = Colors.Black
    self.Form.Width = 1100
    self.Form.Height = 710
    self.Form.Constraints.MinWidth = 1000 
    self.Form.Constraints.MinHeight = 700 
    self.Form.OnClose = function(sender, action)
        self.Form.Hide()
        action = caFree
    end
end

function TableFileExplorer:ToggleVisibility()
    if self.Form.Visible then
        self.Form.Hide()
    else
        self:UpdateTreeView()
        self.Form.Show()
    end
end

function TableFileExplorer:InitializeMenuStrip()
    local menuStrip = createMainMenu(self.Form)
    if not menuStrip then
        self.Logger:error("Failed to create main menu.")
        return
    end
    local fileMenu = createMenuItem(menuStrip)
    fileMenu.Caption = "File"
    menuStrip.Items.add(fileMenu)
    local loadMenuItem = createMenuItem(fileMenu)
    loadMenuItem.Caption = "Load"
    loadMenuItem.OnClick = function() self:LoadFileContent() end
    fileMenu.add(loadMenuItem)
    local saveMenuItem = createMenuItem(fileMenu)
    saveMenuItem.Caption = "Save"
    saveMenuItem.OnClick = function() self:SaveFileContent() end
    fileMenu.add(saveMenuItem)
    local separator = createMenuItem(fileMenu)
    separator.Caption = "-"
    fileMenu.add(separator)
    local exitMenuItem = createMenuItem(fileMenu)
    exitMenuItem.Caption = "Exit"
    exitMenuItem.OnClick = function() self.Form.close() end
    fileMenu.add(exitMenuItem)

    local toolsMenu = createMenuItem(menuStrip)
    toolsMenu.Caption = "Tools"
    menuStrip.Items.add(toolsMenu)
    local updateTreeMenuItem = createMenuItem(toolsMenu)
    updateTreeMenuItem.Caption = "Update Tree"
    updateTreeMenuItem.OnClick = function() self:UpdateTreeView() end
    toolsMenu.add(updateTreeMenuItem)
    local helpMenu = createMenuItem(menuStrip)

    local themesMenu = createMenuItem(menuStrip)
    themesMenu.Caption = "Themes"
    menuStrip.Items.add(themesMenu)
    for themeName, _ in pairs(Themes) do
        local themeItem = createMenuItem(themesMenu)
        themeItem.Caption = themeName
        themeItem.OnClick = function() self:ApplyTheme(themeName) end
        themesMenu.add(themeItem)
    end

    helpMenu.Caption = "Help"
    menuStrip.Items.add(helpMenu)
    local aboutMenuItem = createMenuItem(helpMenu)
    aboutMenuItem.Caption = "About"
    aboutMenuItem.OnClick = function()
        local aboutMessage = string.format(
            "— Table File Explorer v%s\n\n" ..
            "— Authors\n%s\n\n" ..
            "— Description\n%s",
            VERSION,
            table.concat(AUTHOR, ", "),
            DESCRIPTION
        )
        utility:showInfo(aboutMessage)
    end
    helpMenu.add(aboutMenuItem)
end

function TableFileExplorer:InitializeTreeView()
    self.TreeView = createTreeView(self.Form)
    self.TreeView.Align = alLeft
    self.TreeView.BorderStyle = bsNone
    self.TreeView.Color = Colors.Black
    self.TreeView.Font.Color = Colors.Green
    self.TreeView.ReadOnly = true
    self.TreeView.RowSelect = true
    self.TreeView.ShowRoot = false
    self.TreeView.ExpandSignType = tvestPlusMinus
    self.TreeView.OnDblClick = function() self:LoadFileContent() end
    -- self.TreeView.OnChange = function() self:LoadFileContent() end
    self.TreeView.Width = 250
end

-- Mode 0: Lua
-- Mode 1: (A)uto(A)ssembler
function TableFileExplorer:CreateSynEdit(parent, mode)
    local synEdit = createSynEdit(parent, mode)
    synEdit.BorderStyle = bsNone
    synEdit.Align = alClient
    synEdit.Color = Colors.Black
    synEdit.Gutter.Color = Colors.Black
    synEdit.Gutter.Parts.SynGutterLineNumber1.MarkupInfo.Background = Colors.Black
    synEdit.Gutter.Parts.SynGutterLineNumber1.MarkupInfo.Foreground = Colors.Green
    synEdit.Gutter.Parts.SynGutterSeparator1.MarkupInfo.Background = Colors.Black
    synEdit.Font.Color = Colors.White
    synEdit.Gutter.Visible = true
    synEdit.RightEdge = -1
    synEdit.Visible = mode -- Makes sure oly one of them will be visible.
    return synEdit
end

function TableFileExplorer:InitializeSynEdits()
    self.SynEditAsm = self:CreateSynEdit(self.Form, 1)
    self.SynEditLua = self:CreateSynEdit(self.Form, 0)
end

function TableFileExplorer:UpdateTreeView()
    self.Logger:info("Updating TreeView.")
    self.TreeView.Items.clear()
    self:PopulateTreeView()
    self.Logger:info("TreeView updated successfully.")
end

function TableFileExplorer:PopulateTreeView()
    self.Logger:debug("Populating TreeView with table files.")
    local rootNode = self.TreeView.Items.add(nil, "Table Files")
    local fileTypeNodes = {}
    for _, fileName in ipairs(self:SearchForTableFiles()) do
        local fileExtension = fileName:match("^.+(%..+)$")
        if fileExtension then
            if not fileTypeNodes[fileExtension] then
                fileTypeNodes[fileExtension] = rootNode.add(fileExtension)
                self.Logger:debug("Created node for file type.", { FileType = fileExtension })
            end
            fileTypeNodes[fileExtension].add(fileName)
            self.Logger:debug("Added file to file type node.", { FileType = fileExtension, File = fileName })
        else
            self.Logger:warn("File without extension found, skipping.", { File = fileName })
        end
    end
    rootNode.Expand()
    self.Logger:info("TreeView populated with file type grouping.")
end

function TableFileExplorer:ApplyTheme(theme)
    local themeConfig = Themes[theme]
    if not themeConfig then
        self.Logger:error("Theme not found: " .. theme)
        return
    end
    self.Form.Color = themeConfig.FormColor
    self.TreeView.Color = themeConfig.TreeViewColor
    self.TreeView.Font.Color = themeConfig.TreeViewFontColor
    self.SynEditAsm.Color = themeConfig.SynEditColor
    self.SynEditAsm.Font.Color = themeConfig.SynEditFontColor
    self.SynEditAsm.Gutter.Color = themeConfig.SynEditGutterColor
    self.SynEditAsm.Gutter.Parts.SynGutterLineNumber1.MarkupInfo.Background = themeConfig.SynEditGutterLineNumberBackground
    self.SynEditAsm.Gutter.Parts.SynGutterLineNumber1.MarkupInfo.Foreground = themeConfig.SynEditGutterLineNumberForeground
    self.SynEditAsm.Gutter.Parts.SynGutterSeparator1.MarkupInfo.Background = themeConfig.SynEditGutterSeparatorBackground
    self.SynEditLua.Color = themeConfig.SynEditColor
    self.SynEditLua.Font.Color = themeConfig.SynEditFontColor
    self.SynEditLua.Gutter.Color = themeConfig.SynEditGutterColor
    self.SynEditLua.Gutter.Parts.SynGutterLineNumber1.MarkupInfo.Background = themeConfig.SynEditGutterLineNumberBackground
    self.SynEditLua.Gutter.Parts.SynGutterLineNumber1.MarkupInfo.Foreground = themeConfig.SynEditGutterLineNumberForeground
    self.SynEditLua.Gutter.Parts.SynGutterSeparator1.MarkupInfo.Background = themeConfig.SynEditGutterSeparatorBackground
    self.Logger:info("Applied theme: " .. theme)
end

function TableFileExplorer:InitializeStatusBar()
    self.StatusBar = createPanel(self.Form)
    self.StatusBar.Align = alBottom
    self.StatusBar.Height = 20
    self.StatusBar.BevelOuter = bvNone
    self.StatusBar.Color = Colors.DarkGray
    self.StatusBarLabels = {
        FileInfo = createLabel(self.StatusBar),
    }
end

function TableFileExplorer:UpdateStatusBarFileInfo(fileDetailsStr)
    self.StatusBarLabels.FileInfo.Caption = fileDetailsStr
end

function TableFileExplorer:GetFileDetailsStr(fileContent, fileName)
    -- Get the size in KB (by calculating the length of the content)
    local size = #fileContent / 1024  -- size in KB
    -- Get the modified date, assuming you still want it (optional, or can be handled here)
    -- Return a formatted string with all the required details
    return string.format(" File: %s  |  Size: %.2f KB", fileName, size)
end

function TableFileExplorer:InitializeSynEditEvents()
    self.SynEditAsm.OnCaretMove = function(sender)
        local line = sender.CaretY
        local column = sender.CaretX
        self:UpdateStatusBarCursorPosition(line, column)
    end

    self.SynEditLua.OnCaretMove = function(sender)
        local line = sender.CaretY
        local column = sender.CaretX
        self:UpdateStatusBarCursorPosition(line, column)
    end
end

function TableFileExplorer:LoadFileContent()
    local selectedNode = self.TreeView.Selected
    if selectedNode and selectedNode.Text ~= "Table Files" then
        local fileName = selectedNode.Text
        local fileExtension = fileName:match("^.+(%..+)$")
        if not self:IsValidFileType(fileExtension) then
            self.Logger:error("Error: Invalid file type for " .. fileName)
            return
        end
        self:SetSynEditVisibility(fileExtension)
        local filePath = fileName
        local fileContent = self:ReadFileContent(filePath)
        if fileExtension == ".CEA" then
            self.SynEditAsm.Lines.Text = fileContent
        else
            self.SynEditLua.Lines.Text = fileContent
        end
        local fileDetailsStr = self:GetFileDetailsStr(fileContent, fileName)
        self:UpdateStatusBarFileInfo(fileDetailsStr)
        self.Logger:info("File content loaded successfully.", { File = fileName })
    end
end

function TableFileExplorer:SaveFileContent()
    local selectedNode = self.TreeView.Selected
    if not selectedNode or selectedNode.Text == "Table Files" then
        self.Logger:error("Error: No file selected to save.")
        return
    end
    local fileName = selectedNode.Text
    local fileExtension = fileName:match("^.+(%..+)$")
    if not self:IsValidFileType(fileExtension) then
        self.Logger:error("Error: Invalid file type for saving.", { File = fileName })
        return
    end
    local fileContent = ""
    if fileExtension == ".CEA" then
        fileContent = self.SynEditAsm.Lines.Text
    else
        fileContent = self.SynEditLua.Lines.Text
    end
    if not fileContent or fileContent == "" then
        self.Logger:warn("Attempted to save empty file content.", { File = fileName })
        return
    end
    self.Logger:info("Saving file content to table file.", { File = fileName })
    local tableFile = findTableFile(fileName)
    if not tableFile then
        tableFile = createTableFile(fileName)
    end
    if not tableFile then
        self.Logger:error("Failed to create or find table file.", { File = fileName })
        return
    end
    local stream = tableFile.getData()
    local bytes = { string.byte(fileContent, 1, -1) }
    stream.write(bytes)
    self.Logger:info("File content saved successfully.", { File = fileName })
end

function TableFileExplorer:IsValidFileType(fileExtension)
    for _, ext in ipairs(AllowedFileTypes) do
        if fileExtension == ext then
            return true
        end
    end
    return false
end

function TableFileExplorer:SearchForTableFiles()
    self.Logger:debug("Initiating search for table files.")
    local tableMenu = MainForm.findComponentByName("miTable")
    if not tableMenu then
        self.Logger:error("Error: MainForm does not contain 'miTable' component.")
        error("Error: MainForm does not contain 'miTable' component.")
    end

    local tableFiles = {}
    for i = 0, tableMenu.getCount() - 1 do
        local item = tableMenu[i]
        if self:IsValidFileType(item.Caption:match("^.+(%..+)$")) then
            table.insert(tableFiles, item.Caption)
            self.Logger:debug("Found table file.", { File = item.Caption })
        end
    end
    self.Logger:info("Search for table files completed.", { FileCount = #tableFiles })
    return tableFiles
end

function TableFileExplorer:ReadFileContent(filePath)
    local file, err = io.open(filePath, "r")
    if file then
        local content = file:read("*all")
        file:close()
        return content
    end

    local tableFile = findTableFile(filePath)
    if not tableFile then
        showMessage("Error: Table file not found: " .. filePath)
        return ""
    end

    local stream = tableFile.stream
    return readStringLocal(stream.memory, stream.size)
end

function TableFileExplorer:SetSynEditVisibility(fileExtension)
    if fileExtension == ".CEA" then
        self.SynEditAsm.Visible = true
        self.SynEditLua.Visible = false
    else
        self.SynEditAsm.Visible = false
        self.SynEditLua.Visible = true
    end
end

-- TableFileExplorer:new()

return TableFileExplorer
