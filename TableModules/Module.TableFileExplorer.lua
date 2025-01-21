local NAME = "CTI.TableFileExplorer"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Cheat Table Interface (Table File Explorer)"

--
--- Form Caption Placeholder
----------
local AppName = "Table File Explorer"

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

local AllowedFileTypes = {
      ".CEA",
      ".lua",
      ".json"
}

--
--- Several configuration properties that can be customized.
--- Set within the Table Lua Script and passed to the constructor of the class.
----------
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

--
--- Set the metatable for the Teleporter object so that it behaves as an "object-oriented class".
----------
TableFileExplorer.__index = TableFileExplorer

--
--- This checks if the required modules (Utility, Logger) are already loaded.
--- If not, it attempts to load them using the CETrequire function.
----------
if not Logger then
    CETrequire("Module.Logger")
end

if not Utility then
    CETrequire("Module.Utility")
end

--
--- This function creates a new instance of the Table File Explorer object.
--- It initializes the object with the properties passed as arguments and sets up
--- the Logger components.
----------
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

--
--- This function initializes the main form of the Table File Explorer.
--- It sets up the form's properties, such as size, position, and event handlers.
--- Could be customized further but this serves the purpose already.
--- @return None.
----------
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

--
--- This function toggles the visibility of the main form.
--- It hides the form if it's visible and shows it after updating the TreeView if it's hidden.
--- @return None.
----------
function TableFileExplorer:ToggleVisibility()
    if self.Form.Visible then
        self.Form.Hide()
    else
        self:UpdateTreeView()
        self.Form.Show()
    end
end

--
--- This function initializes the menu strip for the Table File Explorer.
--- It creates and configures the File, Tools, Themes, and Help menus with their
--- respective menu items and event handlers.
--- @return None.
----------
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
            DESCRIPTION )
        utility:showInfo(aboutMessage)
    end
    helpMenu.add(aboutMenuItem)
end

--
--- This function initializes the TreeView component of the Table File Explorer.
--- It configures the TreeView's properties, such as alignment, color, font, and event handlers.
--- @return None.
----------
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

--
--- This function creates and returns a SynEdit component with the specified mode.
--- It configures the SynEdit's appearance and properties, such as color, font, and visibility.
--- @param parent: The parent component to attach the SynEdit to.
--- @param mode: The mode of the SynEdit (0 for Lua, 1 for AutoAssembler).
--- @return The configured SynEdit component.
----------
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

--
--- This function initializes the SynEdit components for Lua and Assembler modes.
--- It creates and configures two SynEdit components and assigns them to the respective fields.
--- @return None.
----------
function TableFileExplorer:InitializeSynEdits()
    self.SynEditAsm = self:CreateSynEdit(self.Form, 1)
    self.SynEditLua = self:CreateSynEdit(self.Form, 0)
end

--
--- This function updates the TreeView by clearing its current items and repopulating it with new data.
--- It logs the progress of the update process.
--- @return None.
----------
function TableFileExplorer:UpdateTreeView()
    self.Logger:info("Updating TreeView.")
    self.TreeView.Items.clear()
    self:PopulateTreeView()
    self.Logger:info("TreeView updated successfully.")
end

--
--- This function populates the TreeView with table files grouped by their file types.
--- It creates nodes for each file type and adds corresponding files under them.
--- Files without extensions are skipped, and their occurrence is logged.
--- @return None.
----------
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

--
--- This function applies the specified theme to the Table File Explorer.
--- It updates the colors and fonts of various components, such as the form, TreeView, and SynEdit.
--- @param theme: The name of the theme to apply.
--- @return None.
----------
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

--
--- This function initializes the status bar for the Table File Explorer.
--- It creates and configures a panel at the bottom of the form to display status information.
--- @return None.
----------
function TableFileExplorer:InitializeStatusBar()
    self.StatusBar = createPanel(self.Form)
    self.StatusBar.Align = alBottom
    self.StatusBar.Height = 20
    self.StatusBar.BevelOuter = bvNone
    self.StatusBar.Color = Colors.DarkGray
    self.StatusBarLabels = { FileInfo = createLabel(self.StatusBar) }
end

--
--- This function updates the file information displayed in the status bar.
--- It sets the caption of the file info label with the provided details string.
--- @param fileDetailsStr: A string containing the file details to display.
--- @return None.
----------
function TableFileExplorer:UpdateStatusBarFileInfo(fileDetailsStr)
    self.StatusBarLabels.FileInfo.Caption = fileDetailsStr
end

--
--- This function generates a formatted string containing details about a file.
--- The details include the file name and its size in kilobytes.
--- @param fileContent: The content of the file as a string.
--- @param fileName: The name of the file.
--- @return A formatted string with file details.
----------
function TableFileExplorer:GetFileDetailsStr(fileContent, fileName)
    -- Get the size in KB (by calculating the length of the content)
    local size = #fileContent / 1024  -- size in KB
    return string.format(" File: %s  |  Size: %.2f KB", fileName, size)
end

--
--- This function initializes event handlers for the SynEdit components.
--- It assigns caret move events to update the cursor position in the status bar.
--- @return None.
----------
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

--
--- This function loads the content of the selected file into the appropriate SynEdit component.
--- It validates the file type, retrieves its content, updates the status bar, and logs the process.
--- @return None.
----------
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

--
--- This function saves the content of the selected file back to the table file.
--- It validates the file type, retrieves the current content from the SynEdit component, and writes it to the file.
--- @return None.
----------
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

--
--- This function checks if a given file extension is valid based on the allowed file types.
--- @param fileExtension: The file extension to validate.
--- @return A boolean indicating whether the file type is valid.
----------
function TableFileExplorer:IsValidFileType(fileExtension)
    for _, ext in ipairs(AllowedFileTypes) do
        if fileExtension == ext then
            return true
        end
    end
    return false
end

--
--- This function searches for table files in the main menu and returns a list of valid file names.
--- It logs the search process and ensures only valid file types are included.
--- @return A table containing the names of the valid table files.
----------
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

--
--- This function reads the content of a file given its file path or table file.
--- It handles both standard file system files and table files in memory.
--- @param filePath: The path of the file to read.
--- @return The content of the file as a string, or an empty string if reading fails.
----------
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

--
--- This function sets the visibility of the SynEdit components based on the file type.
--- It ensures only the relevant SynEdit component is visible for the given file extension.
--- @param fileExtension: The file extension to determine visibility.
----------
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
