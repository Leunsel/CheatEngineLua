--[[
    Manifold.CE.Utility.lua
    --------------------------------

    AUTHOR  : Leunsel, LeFiXER
    VERSION : 1.0.0
    LICENSE : MIT
    CREATED : 2025-11-17
    UPDATED : 2025-11-20
    
    MIT License:
        Copyright (c) 2025 Leunsel

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.

    This file is part of the Manifold CE system.
]]

----------------------------------------
-- CONFIG
----------------------------------------
local Config = {
    -- Unused for now
    FontName = "Consolas",
    FontSize = 9,
    -- Menu entry & animation
    MenuCaption       = "Manifold",
    Prefix            = "[— ",
    Suffix            = " —]",
    AnimatedCaption   = true,
    AnimationInterval = 200,
    -- indices placeholder (filled at runtime)
    Indices = {
        StructureDissect = nil,
        LuaEngine        = nil,
        Open             = nil,
        NewWindow        = nil,
        Toggle           = nil,
        Destroy          = nil,
        Folder           = nil
    }
}

----------------------------------------
-- LOCALS / REFERENCES
----------------------------------------
local mf       = getMainForm()
local il       = nil
local mv       = getMemoryViewForm()
local le       = getLuaEngine()
local al       = getAddressList()
local mainMenu = mf and mf.Menu

-- internal state
local toolsMenuItem = nil
local rotationTimer = nil
local tickerBuffer  = nil

-- colors & flags
local HEADER_COLOR  = 0xD2FF00
local ADDRESS_COLOR = 0xADAD5A
local ENABLE_FORMAT = false

----------------------------------------
-- LOGGING (only Fail-Logs)
----------------------------------------

--
--- ∑ Prints a formatted fail log message to the Cheat Engine console.
--- @param tag string # Category or context of the failure.
--- @param msg string # The error message to print.
--- @return nil # No return value.
--
local function FailLog(tag, msg)
    if not tag then tag = "Unknown" end
    if not msg then msg = "<empty>" end
    local t = os.date("%H:%M:%S") or "??:??:??"
    print(string.format("[%s] [FAIL] [%s] %s", t, tostring(tag), tostring(msg)))
end

----------------------------------------
-- THREAD / SYNCHRONIZATION
----------------------------------------

--
--- ∑ Executes a function in the main thread (or synchronizes to it).
--- @param func function # The function to call.
--- @return nil # No return value.
--
local function RunInMainThread(func)
    if type(func) ~= "function" then
        FailLog("RunInMainThread", "Invalid parameter; expected function.")
        return
    end
    if inMainThread() then
        local ok, err = pcall(func)
        if not ok then FailLog("RunInMainThread", "Error executing in main thread: " .. tostring(err)) end
    else
        local ok, err = pcall(function() synchronize(func) end)
        if not ok then FailLog("RunInMainThread", "Synchronization failed: " .. tostring(err)) end
    end
end

----------------------------------------
-- UTILS
----------------------------------------

--
--- ∑ Retrieves (and lazily initializes) the ImageList reference.
--- @return table|nil # The ImageList or nil if unavailable.
--
local function safeGetImageList()
    -- lazy init, return existing otherwise
    if il then return il end
    -- try to obtain image list from MainForm
    if mf and mf.ImageList then
        il = mf.ImageList
        return il
    end
    -- fallback: try known references (best-effort)
    if getMainForm and getMainForm().mfImageList then
        il = getMainForm().mfImageList
        return il
    end
    FailLog("Init", "Could not find an ImageList. Some menu icons may be missing.")
    return nil
end

--
--- ∑ Trims surrounding whitespace from a string.
--- @param s string # The string to trim.
--- @return string # The trimmed string.
--
local function trim(s)
    if not s then return "" end
    return s:gsub("^%s*", ""):gsub("%s*$", "")
end

--
--- ∑ Extracts inner text from a `[Caption]`, otherwise returns cleaned caption.
--- @param caption string # The original caption string.
--- @return string # The extracted label text.
--
local function extractInnerTextFromCaption(caption)
    -- Try to match content inside square brackets first, otherwise attempt a word extraction
    if not caption or caption == "" then return "" end
    local inner = caption:match("%[(.+)%]") or caption
    inner = trim(inner)
    -- If surrounding prefix / suffix characters exist (like "—"), strip them from inner if they were included
    -- But keep inner as-is otherwise
    return inner
end

----------------------------------------
-- RECORD FACTORY & STRUCTURE BUILDER
----------------------------------------
local RecordFactory = {}

--
--- ∑ Creates a MemoryRecord entry with the given metadata.
--- @param parent table|nil # Parent record or nil to create a root record.
--- @param desc string # Display name / description of the record.
--- @param addr string # Address or offset string.
--- @param vartype integer # CE vartype.
--- @param color integer # Display color.
--- @param isHeader boolean # Whether the entry is a group header.
--- @return table|nil # The created MemoryRecord, or nil on failure.
--
function RecordFactory.Create(parent, desc, addr, vartype, color, isHeader)
    if not desc or not addr then
        FailLog("RecordFactory", "Missing description or address.")
        return nil
    end
    if not al then
        FailLog("RecordFactory", "AddressList handle unavailable.")
        return nil
    end
    local ok, r = pcall(function() return al.createMemoryRecord() end)
    if not ok or not r then
        FailLog("RecordFactory", "Failed to create MemoryRecord instance.")
        return nil
    end
    r.setDescription(desc)
    r.setAddress(addr)
    r.Type  = vartype
    r.Color = color
    if isHeader then
        r.isAddressGroupHeader = true
        r.OffsetCount = 1
        r.Offset[0] = 0
    end
    if parent then
        local ok2, err2 = pcall(function() r.appendToEntry(parent) end)
        if not ok2 then
            FailLog("RecordFactory", "appendToEntry failed: " .. tostring(err2))
            -- continue; record exists unattached
        end
    end
    return r
end

--
--- ∑ Formats names for structure records (pretty display).
--- @param n string # Original name from structure dissect.
--- @return string # Formatted display name.
--
local function FormatDisplayName(n)
    if not n or n == "" then return "<empty>" end
    local s = n
        :gsub("%b[]", "")
        :gsub("^%s*(?:[Bb]_?|m_)", "")
        :gsub("%s+", " ")
    local a, b = s:match("([%w_]+)%s+([%w_]+)$")
    local text = b and (a .. " " .. b) or (a or s)
    text = text:gsub("(%l)(%u)", "%1 %2")
               :gsub("_", " ")
               :gsub("^%s*(%l)", string.upper)
    return text
end

--
--- ∑ Opens a selection dialog allowing the user to choose a structure.
--- @return table|nil # The selected structure or nil on cancel.
--
local function SelectStructure()
    local count = getStructureCount()
    if count <= 0 then
        FailLog("StructureSelector", "No structures available.")
        return nil
    end
    local list = createStringList()
    for i = 0, count - 1 do
        local s = getStructure(i)
        if s and s.Name and s.Name ~= "" then
            list.add(s.Name)
        end
    end
    if list.Count == 0 then
        FailLog("StructureSelector", "Structures exist but names are empty.")
        return nil
    end
    local idx = showSelectionList("Structure Selector", "Choose a Structure", list, false)
    if not idx or idx < 0 then
        FailLog("StructureSelector", "No structure selected.")
        return nil
    end
    return getStructure(idx)
end

--
--- ∑ Builds MemoryRecords for each element in a structure.
--- @param struct table # The structure object returned by CE.
--- @return nil # No return value.
--
local function BuildStructureRecords(struct)
    if not struct then
        FailLog("StructureBuilder", "No structure provided.")
        return
    end
    local root = RecordFactory.Create(nil, struct.Name, "+0", vtCustom, HEADER_COLOR, true)
    if not root then
        FailLog("StructureBuilder", "Failed to create root record for structure: " .. tostring(struct.Name))
        return
    end
    -- iterate and create child records; one repaint at the end
    for i = 0, (struct.Count or 0) - 1 do
        local e = struct.Element[i]
        if not e or not e.Name or e.Name == "" then
            FailLog("StructureBuilder", "Invalid or unnamed element at index " .. tostring(i))
        else
            local hex   = string.format("%04X", tonumber(e.Offset) or 0)
            local name  = ENABLE_FORMAT and FormatDisplayName(e.Name) or e.Name
            local isPtr = (e.Vartype == vtPointer)
            local desc  = string.format("[%s] — %s", hex, name)
            local rec = RecordFactory.Create(root, desc, "+" .. hex, e.Vartype, ADDRESS_COLOR, isPtr)
            if not rec then
                FailLog("StructureBuilder", "Failed to create record for element: " .. tostring(e.Name))
            end
        end
    end
    -- Repaint once after creation
    if mf and mf.repaint then
        local ok, err = pcall(function() mf.repaint() end)
        if not ok then FailLog("StructureBuilder", "mf.repaint failed: " .. tostring(err)) end
    end
end

--
--- ∑ Generates MemoryRecords based on user-selected structure.
--- @return nil # No return value.
--
local function GenerateStructure()
    local struct = SelectStructure()
    if not struct then
        -- SelectStructure logs failure
        return
    end
    BuildStructureRecords(struct)
end

----------------------------------------
-- STRUCTURE MANAGEMENT
----------------------------------------

--
--- ∑ Removes all global structures from Cheat Engine.
--- @return nil # No return value.
--
local function DeleteAllStructures()
    local count = getStructureCount()
    if not count or count < 1 then
        FailLog("DeleteStructures", "No structures to delete.")
        return
    end
    -- remove from global list in reverse order
    for i = count, 1, -1 do
        local s = getStructure(i - 1)
        if s then
            local ok, err = pcall(function() s:removeFromGlobalStructureList() end)
            if not ok then FailLog("DeleteStructures", "Failed removing structure at index " .. tostring(i - 1) .. ": " .. tostring(err)) end
        end
    end
end

----------------------------------------
-- MISC UTILITIES (Process folders, autorun)
----------------------------------------

--
--- ∑ Opens the Windows file explorer in the target process folder.
--- @return nil # No return value.
--
local function OpenProcessFolder()
    local modules = enumModules()
    if not modules or #modules == 0 then
        FailLog("OpenProcessFolder", "enumModules returned empty.")
        return
    end
    local processPath = modules[1].PathToFile
    if not processPath or processPath == "" then
        FailLog("OpenProcessFolder", "Process path unavailable.")
        return
    end
    local folder = processPath:match("^(.*)\\[^\\]+$")
    if folder and folder ~= "" then
        ShellExecute(folder)
    else
        FailLog("OpenProcessFolder", "Could not determine process folder.")
    end
end

--
--- ∑ Opens the Cheat Engine autorun folder in Windows.
--- @return nil # No return value.
--
local function OpenAutorunFolder()
    local folder = getAutorunPath()
    if folder and folder ~= "" then
        ShellExecute(folder)
    else
        FailLog("OpenAutorunFolder", "Autorun path unavailable.")
    end
end

----------------------------------------
-- DEACTIVATE / TOGGLE UTILITIES
----------------------------------------

--
--- ∑ Deactivates all AutoAssembler scripts in the address list.
--- @return nil # No return value.
--
local function DeactivateActiveScripts()
    if not al then
        FailLog("DeactivateActiveScripts", "AddressList handle unavailable.")
        return
    end
    for i = al.Count - 1, 0, -1 do
        if al[i].Type == vtAutoAssembler then
            al[i].Active = false
        end
    end
    if mf and mf.repaint then mf.repaint() end
end

--
--- ∑ Deactivates every active entry in the address list.
--- @return nil # No return value.
--
local function DeactivateEverything()
    if not al then
        FailLog("DeactivateEverything", "AddressList handle unavailable.")
        return
    end
    for i = al.Count - 1, 0, -1 do
        if al[i].Active then
            al[i].Active = false
        end
    end
    if mf and mf.repaint then mf.repaint() end
end

----------------------------------------
-- UI CONTROL TOGGLE & COMPACT MODE
----------------------------------------

--
--- ∑ Toggles visibility of a UI control on MainForm.
--- @param controlName string # The component name to toggle.
--- @return nil # No return value.
--
local function ToggleControlVisibility(controlName)
    if MainForm and MainForm[controlName] then
        local ok, err = pcall(function() MainForm[controlName].Visible = not MainForm[controlName].Visible end)
        if not ok then FailLog("ToggleControlVisibility", "Failed toggling " .. tostring(controlName) .. ": " .. tostring(err)) end
    else
        FailLog("ToggleControlVisibility", "Control '" .. tostring(controlName) .. "' not found on MainForm.")
    end
end

--- Reference:
-- https://github.com/Leunsel/CheatEngineLua/blob/main/Manifold-Modules/Manifold.Modules/Manifold.UI.lua#L939
--
--- ∑ Toggles Cheat Engine compact mode UI.
--- @return nil # No return value.
--
local function ToggleCompactMode()
    RunInMainThread(function()
        ToggleControlVisibility("Panel5")
        ToggleControlVisibility("Splitter1")
    end)
end

----------------------------------------
-- CAPTION ANIMATION
----------------------------------------

--
--- ∑ Prepares the text buffer for caption rotation.
--- @param inner string # The caption text to animate.
--- @return nil # No return value.
--
local function PrepareTicker(inner)
    tickerBuffer = " " .. (tostring(inner) or "") .. " "
end

--
--- ∑ Rotates the ticker/caption text by one position.
--- @return string # The rotated caption.
--
local function RotateTicker()
    if not tickerBuffer or #tickerBuffer < 2 then return "" end
    tickerBuffer = tickerBuffer:sub(2) .. tickerBuffer:sub(1,1)
    return tickerBuffer
end

--
--- ∑ Starts animated caption rotation for the top-menu entry.
--- @return nil # No return value.
--
local function StartCaptionAnimation()
    if rotationTimer then
        rotationTimer.Enabled = false
        rotationTimer.destroy()
        rotationTimer = nil
    end
    if not toolsMenuItem then
        FailLog("AnimateCaption", "toolsMenuItem is nil.")
        return
    end
    local caption = Config.MenuCaption or ""
    local inner = extractInnerTextFromCaption(caption)
    if #inner < 2 then
        -- nothing to animate
        return
    end
    PrepareTicker(inner)
    rotationTimer = createTimer(nil)
    rotationTimer.Interval = Config.AnimationInterval or 150
    rotationTimer.OnTimer = function()
        if not toolsMenuItem then return end
        local rotated = RotateTicker() -- includes surrounding spaces we supplied
        -- ensure spaces between prefix/rotated/suffix
        local result = (Config.Prefix or "") .. rotated .. (Config.Suffix or "")
        -- set Caption in main-thread safe manner
        RunInMainThread(function()
            toolsMenuItem.Caption = result
        end)
        -- store inner rotated state if desired
        Config.MenuCaption = result
    end
end

--
--- ∑ Stops animated caption rotation.
--- @return nil # No return value.
--
local function StopCaptionAnimation()
    if rotationTimer then
        rotationTimer.Enabled = false
        rotationTimer.destroy()
        rotationTimer = nil
    end
end

----------------------------------------
-- MENU CREATION
----------------------------------------

--- Reference:
-- https://github.com/Leunsel/CheatEngineLua/blob/main/Manifold-TemplateLoader/Manifold-TemplateLoader-Modules/Manifold-TemplateLoader-Loader.lua#L693
--
--- ∑ Adds all menu icon bitmaps to the ImageList and stores indices.
--- @return nil # No return value.
--
local function GetImageListAndIndices()
    local images = safeGetImageList()
    if not images then return end
    -- try-catch each add because some bitmap refs might not exist
    local function tryAdd(bitmap)
        if not bitmap then return nil end
        local ok, idx = pcall(function() return images.add(bitmap) end)
        if not ok then return nil end
        return idx
    end
    -- best-effort population: ignore missing bitmaps
    Config.Indices.LuaEngine        = tryAdd(mv and mv.miLuaEngine and mv.miLuaEngine.Bitmap)
    Config.Indices.StructureDissect = tryAdd(mv and mv.Dissectcode1 and mv.Dissectcode1.Bitmap)
    Config.Indices.Open             = tryAdd(mv and mv.miWatchMemoryPageAccess and mv.miWatchMemoryPageAccess.Bitmap)
    Config.Indices.NewWindow        = tryAdd(mv and mv.Newwindow1 and mv.Newwindow1.Bitmap)
    Config.Indices.Toggle           = tryAdd(mv and mv.miDebugToggleBreakpoint and mv.miDebugToggleBreakpoint.Bitmap)
    Config.Indices.Destroy          = tryAdd(mf and mf.New1 and mf.New1.Bitmap)
    Config.Indices.Folder           = tryAdd(mf and mf.miOpenFile and mf.miOpenFile.Bitmap)
end

--
--- ∑ Adds the root menu item (the top-level menu entry).
--- @return nil # No return value.
--
local function AddTopMenuEntry()
    if not mainMenu then
        FailLog("Menu", "Main menu not available.")
        return
    end
    toolsMenuItem = createMenuItem(mainMenu)
    toolsMenuItem.Caption = Config.MenuCaption or (Config.Prefix .. (Config.MenuCaption or "") .. Config.Suffix)
    toolsMenuItem.ImageList = safeGetImageList()
    mainMenu.Items.add(toolsMenuItem)
    if Config.AnimatedCaption then
        StartCaptionAnimation()
    end
end

--
--- ∑ Adds a child menu entry under the main Tools entry.
--- @param caption string # Text to display on the item.
--- @param onclick function # Function to execute on click.
--- @param imageIndex number|nil # Optional icon index for ImageList.
--- @param shortcut string|nil # Optional keyboard shortcut.
--- @return table|nil # The created item or nil on failure.
--
local function AddSubItem(caption, onclick, imageIndex, shortcut)
    if not toolsMenuItem then
        FailLog("Menu :: AddSubItem", "toolsMenuItem is nil.")
        return nil
    end
    local item = createMenuItem(toolsMenuItem)
    item.Caption = caption or ""
    if imageIndex then
        item.ImageIndex = imageIndex
    end
    if shortcut then
        item.Shortcut = shortcut
    end
    item.OnClick = onclick
    toolsMenuItem.add(item)
    return item
end

--
--- ∑ Add a separator menu item to the Cheat Engine main menu.
--- @return table|nil # The separator item or nil on failure.
--
local function AddSeparator()
    if not toolsMenuItem then return end
    local sep = createMenuItem(toolsMenuItem)
    sep.Caption = "-"
    toolsMenuItem.add(sep)
    return sep
end

--
--- ∑ Creates all submenu entries under the Manifold utilities menu.
--- @return nil # No return value.
--
local function CreateUtilityEntries()
    AddSubItem("Open Lua Engine",            function() RunInMainThread(function() if le then le.Show() end end) end,           Config.Indices.LuaEngine,   "Ctrl+L")
    AddSubItem("Open Memory Viewer",         function() RunInMainThread(function() if mv then mv.Show() end end) end,           Config.Indices.Open)
    AddSeparator()
    AddSubItem("Open Structure Dissect",     function() RunInMainThread(function() createStructureForm(nil,nil,nil) end) end,   Config.Indices.NewWindow)
    AddSubItem("Generate Structure Records", function() GenerateStructure() end,                                                Config.Indices.NewWindow)
    AddSubItem("Remove All Structures",      function() DeleteAllStructures() end,                                              Config.Indices.Destroy)
    AddSeparator()
    AddSubItem("Deactivate Scripts",         function() DeactivateActiveScripts() end,                                          Config.Indices.Toggle,      "Ctrl+D")
    AddSubItem("Deactivate Everything",      function() DeactivateEverything() end,                                             Config.Indices.Toggle,      "Ctrl+F")
    AddSeparator()
    AddSubItem("Toggle Compact Mode",        function() ToggleCompactMode() end,                                                Config.Indices.Open,        "Ctrl+Shift+F")
    AddSeparator()
    AddSubItem("Open Autorun Folder",        function() OpenAutorunFolder() end,                                                Config.Indices.Folder)
    AddSubItem("Open Process Folder",        function() OpenProcessFolder() end,                                                Config.Indices.Folder)
end

----------------------------------------
-- ENTRYPOINT
----------------------------------------

--
--- ∑ Initializes menu icons, creates menu and registers all utility entries.
--- @return nil # No return value.
--
local function Main()
    GetImageListAndIndices()
    AddTopMenuEntry()
    CreateUtilityEntries()
end

Main()