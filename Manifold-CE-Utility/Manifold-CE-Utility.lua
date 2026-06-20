--[[
    Manifold.CE.Utility.lua
    --------------------------------

    AUTHOR  : Leunsel, LeFiXER
    VERSION : 1.1.0
    LICENSE : MIT
    CREATED : 2025-11-17
    UPDATED : 2026-06-20
    
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
    AnimatedCaption   = false,
    AnimationInterval = 350,
    ConfirmDestructiveActions = true,
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

local MIN_ANIMATION_INTERVAL = 100
local MAX_ANIMATION_INTERVAL = 2000
local RUNTIME_STATE_KEY = "__MANIFOLD_CE_UTILITY_RUNTIME__"

-- Keep runtime handles outside this autorun chunk. When the file is executed
-- again from CE's Lua engine, the previous menu and timer can be disposed first.
local RuntimeState = rawget(_G, RUNTIME_STATE_KEY)
if type(RuntimeState) ~= "table" then
    RuntimeState = {}
    _G[RUNTIME_STATE_KEY] = RuntimeState
end

----------------------------------------
-- LOCALS / REFERENCES
----------------------------------------
local mf       = nil
local il       = nil
local mv       = nil
local le       = nil
local al       = nil
local mainMenu = nil

-- internal state
local toolsMenuItem = nil
local rotationTimer = nil
local tickerBuffer  = nil
local settingsItems = {}
local RefreshSettingsMenu = nil

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

local function DestroyComponent(component)
    if not component then return end
    pcall(function() component.Enabled = false end)
    pcall(function() component.destroy() end)
end

local function DisposePreviousInstance()
    -- Timers must go first because their callbacks still capture the previous menu.
    DestroyComponent(RuntimeState.rotationTimer)
    DestroyComponent(RuntimeState.menuItem)
    RuntimeState.rotationTimer = nil
    RuntimeState.menuItem = nil
end

local function RefreshUiReferences()
    if type(getMainForm) == "function" then
        local ok, currentMainForm = pcall(getMainForm)
        if ok and currentMainForm then
            mf = currentMainForm
            mainMenu = mf.Menu
        end
    end
    if type(getMemoryViewForm) == "function" then
        local ok, currentMemoryView = pcall(getMemoryViewForm)
        if ok and currentMemoryView then mv = currentMemoryView end
    end
    if type(getLuaEngine) == "function" then
        local ok, currentLuaEngine = pcall(getLuaEngine)
        if ok and currentLuaEngine then le = currentLuaEngine end
    end
end

local function GetAddressListOrLog(tag)
    if type(getAddressList) ~= "function" then
        FailLog(tag, "getAddressList is unavailable.")
        return nil
    end
    local ok, currentAddressList = pcall(getAddressList)
    if not ok or not currentAddressList then
        FailLog(tag, "AddressList handle unavailable: " .. tostring(currentAddressList))
        return nil
    end
    al = currentAddressList
    return al
end

local function RepaintMainForm(tag)
    RefreshUiReferences()
    if mf and mf.repaint then
        local ok, err = pcall(function() mf.repaint() end)
        if not ok then FailLog(tag, "mf.repaint failed: " .. tostring(err)) end
    end
end

local function ConfirmDestructiveAction(action, affectedCount)
    RunInMainThread(function()
        local result
        ConfirmDestructiveAction = function(action, affectedCount)
            return result
        end
    end)
    if not Config.ConfirmDestructiveActions then return true end
    if type(messageDialog) ~= "function"
        or type(mtConfirmation) ~= "number"
        or type(mbYes) ~= "number"
        or type(mbNo) ~= "number"
        or type(mrYes) ~= "number" then
        FailLog("Confirmation", "Confirmation API unavailable; blocked action: " .. action)
        return false
    end
    local countText = affectedCount and ("\n\nAffected entries: " .. tostring(affectedCount)) or ""
    local message = action .. countText .. "\n\nDo you want to continue?"
    local ok, result = pcall(function()
        return messageDialog(message, mtConfirmation, mbYes, mbNo)
    end)
    if not ok then
        FailLog("Confirmation", "Dialog failed: " .. tostring(result))
        return false
    end
    if result ~= mrYes then
        print("[INFO] Action cancelled: " .. action)
        return false
    end
    return true
end

----------------------------------------
-- UTILS
----------------------------------------

--
--- ∑ Retrieves (and lazily initializes) the ImageList reference.
--- @return table|nil # The ImageList or nil if unavailable.
--
local function safeGetImageList()
    if il then return il end
    RefreshUiReferences()
    if mf and mf.ImageList then
        il = mf.ImageList
        return il
    end
    if mf and mf.mfImageList then
        il = mf.mfImageList
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
    RepaintMainForm("StructureBuilder")
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
    if type(getStructureCount) ~= "function" or type(getStructure) ~= "function" then
        FailLog("DeleteStructures", "Structure API unavailable.")
        return
    end
    local okCount, count = pcall(getStructureCount)
    if not okCount or type(count) ~= "number" or count < 1 then
        FailLog("DeleteStructures", "No structures to delete.")
        return
    end
    if not ConfirmDestructiveAction("Remove all global structures?", count) then return end

    local removed = 0
    for i = count, 1, -1 do
        local okStructure, structure = pcall(function() return getStructure(i - 1) end)
        if okStructure and structure then
            local ok, err = pcall(function() structure:removeFromGlobalStructureList() end)
            if ok then
                removed = removed + 1
            else
                FailLog("DeleteStructures", "Failed removing structure at index " .. tostring(i - 1) .. ": " .. tostring(err))
            end
        end
    end
    print("[OK] Removed " .. tostring(removed) .. " structure(s).")
end

----------------------------------------
-- MISC UTILITIES (Process folders, autorun)
----------------------------------------

--
--- ∑ Opens the Windows file explorer in the target process folder.
--- @return nil # No return value.
--
local function OpenFolder(folder, tag)
    if type(folder) ~= "string" or folder == "" then
        FailLog(tag, "Folder path unavailable.")
        return
    end
    local ok, err = pcall(function() ShellExecute(folder) end)
    if not ok then FailLog(tag, "Could not open folder: " .. tostring(err)) end
end

local function OpenProcessFolder()
    local ok, modules = pcall(enumModules)
    if not ok or type(modules) ~= "table" or #modules == 0 then
        FailLog("OpenProcessFolder", "enumModules returned empty.")
        return
    end
    local processPath = modules[1] and modules[1].PathToFile
    if type(processPath) ~= "string" or processPath == "" then
        FailLog("OpenProcessFolder", "Process path unavailable.")
        return
    end
    local folder = processPath:match("^(.*)\\[^\\]+$")
    if not folder or folder == "" then
        FailLog("OpenProcessFolder", "Could not determine process folder.")
        return
    end
    OpenFolder(folder, "OpenProcessFolder")
end

--
--- ∑ Opens the Cheat Engine autorun folder in Windows.
--- @return nil # No return value.
--
local function OpenAutorunFolder()
    local ok, folder = pcall(getAutorunPath)
    if not ok then
        FailLog("OpenAutorunFolder", "Autorun path unavailable: " .. tostring(folder))
        return
    end
    OpenFolder(folder, "OpenAutorunFolder")
end

----------------------------------------
-- DEACTIVATE / TOGGLE UTILITIES
----------------------------------------

--
--- ∑ Deactivates all AutoAssembler scripts in the address list.
--- @return nil # No return value.
--
local function CountActiveRecords(addressList, scriptsOnly)
    local count = 0
    for i = addressList.Count - 1, 0, -1 do
        local record = addressList[i]
        if record then
            local okActive, active = pcall(function() return record.Active end)
            local matchesType = true
            if scriptsOnly then
                local okType, recordType = pcall(function() return record.Type end)
                matchesType = okType and recordType == vtAutoAssembler
            end
            if okActive and active and matchesType then count = count + 1 end
        end
    end
    return count
end

local function DeactivateActiveScripts()
    local addressList = GetAddressListOrLog("DeactivateActiveScripts")
    if not addressList then return end
    local count = CountActiveRecords(addressList, true)
    if count == 0 then
        print("[INFO] No active AutoAssembler scripts found.")
        return
    end
    if not ConfirmDestructiveAction("Deactivate all active AutoAssembler scripts?", count) then return end

    local deactivated = 0
    for i = addressList.Count - 1, 0, -1 do
        local record = addressList[i]
        if record then
            local okType, isScript = pcall(function() return record.Type == vtAutoAssembler end)
            if okType and isScript then
                local okActive, active = pcall(function() return record.Active end)
                if okActive and active then
                    local ok, err = pcall(function() record.Active = false end)
                    if ok then deactivated = deactivated + 1 else FailLog("DeactivateActiveScripts", tostring(err)) end
                end
            end
        end
    end
    RepaintMainForm("DeactivateActiveScripts")
    print("[OK] Deactivated " .. tostring(deactivated) .. " script(s).")
end

--
--- ∑ Deactivates every active entry in the address list.
--- @return nil # No return value.
--
local function DeactivateEverything()
    local addressList = GetAddressListOrLog("DeactivateEverything")
    if not addressList then return end
    local count = CountActiveRecords(addressList, false)
    if count == 0 then
        print("[INFO] No active records found.")
        return
    end
    if not ConfirmDestructiveAction("Deactivate every active address-list entry?", count) then return end

    local deactivated = 0
    for i = addressList.Count - 1, 0, -1 do
        local record = addressList[i]
        if record then
            local okActive, active = pcall(function() return record.Active end)
            if okActive and active then
                local ok, err = pcall(function() record.Active = false end)
                if ok then deactivated = deactivated + 1 else FailLog("DeactivateEverything", tostring(err)) end
            end
        end
    end
    RepaintMainForm("DeactivateEverything")
    print("[OK] Deactivated " .. tostring(deactivated) .. " record(s).")
end

local NORMALIZE_TMP_BASE = 1000000000

--
--- ∑ ...
--- @param rec table # MemoryRecord
--- @param out table # array
--
local function CollectRecordsRecursive(rec, out, seen)
    if not rec or seen[rec] then return end
    seen[rec] = true
    out[#out + 1] = rec
    local childCount = 0
    local okCount, cnt = pcall(function() return rec.Count end)
    if okCount and type(cnt) == "number" then childCount = cnt end
    for i = 0, childCount - 1 do
        local child = nil
        local okChild = pcall(function()
            if rec.Child then
                child = rec.Child[i]
            else
                child = rec[i]
            end
        end)
        if okChild and child then
            CollectRecordsRecursive(child, out, seen)
        end
    end
end

--
--- ∑ ...
--- @return table # array of MemoryRecords
--
local function GetAllAddressListRecords(addressList)
    local records = {}
    local seen = {}
    for i = 0, addressList.Count - 1 do
        local record = addressList[i]
        if record then
            CollectRecordsRecursive(record, records, seen)
        end
    end
    return records
end

local function SetRecordId(record, id)
    return pcall(function()
        if record.setID then
            record.setID(id)
        else
            record.ID = id
        end
    end)
end

local function RestoreRecordIds(records, originalIds, temporaryIds)
    local restored = true
    -- Re-enter the collision-free temporary range before restoring original IDs.
    -- This also handles a failure after only part of the final ID sequence was written.
    if temporaryIds then
        for idx = 1, #records do
            local ok, err = SetRecordId(records[idx], temporaryIds[idx])
            if not ok then
                restored = false
                FailLog("NormalizeIDs", "Rollback preparation failed on record #" .. idx .. ": " .. tostring(err))
            end
        end
    end
    for idx = 1, #records do
        local ok, err = SetRecordId(records[idx], originalIds[idx])
        if not ok then
            restored = false
            FailLog("NormalizeIDs", "Rollback failed on record #" .. idx .. ": " .. tostring(err))
        end
    end
    return restored
end

local function FindTemporaryIdBase(originalIds, recordCount)
    local used = {}
    for _, id in ipairs(originalIds) do used[id] = true end
    local candidate = NORMALIZE_TMP_BASE
    local limit = 2147483647 - recordCount - 1
    while candidate <= limit do
        local available = true
        for offset = 1, recordCount do
            if used[candidate + offset] then
                available = false
                break
            end
        end
        if available then return candidate end
        candidate = candidate + recordCount + 1
    end
    return nil
end

--
--- ∑ ...
--- @return nil
--
local function NormalizeCheatTableIDs()
    local addressList = GetAddressListOrLog("NormalizeIDs")
    if not addressList then return end
    local records = GetAllAddressListRecords(addressList)
    if #records == 0 then
        FailLog("NormalizeIDs", "No records found to normalize.")
        return
    end
    if not ConfirmDestructiveAction("Normalize Cheat Table IDs?", #records) then return end

    local originalIds = {}
    for idx = 1, #records do
        local ok, id = pcall(function() return records[idx].ID end)
        if not ok or type(id) ~= "number" or id ~= math.floor(id) then
            FailLog("NormalizeIDs", "Could not read a valid ID from record #" .. idx .. ". No changes were made.")
            return
        end
        originalIds[idx] = id
    end

    local temporaryBase = FindTemporaryIdBase(originalIds, #records)
    if not temporaryBase then
        FailLog("NormalizeIDs", "Could not reserve a collision-free temporary ID range.")
        return
    end
    local temporaryIds = {}
    local finalIds = {}
    for idx = 1, #records do
        temporaryIds[idx] = temporaryBase + idx
        finalIds[idx] = idx
    end

    for idx = 1, #records do
        local ok, err = SetRecordId(records[idx], temporaryIds[idx])
        if not ok then
            FailLog("NormalizeIDs", "Temporary ID assignment failed on record #" .. idx .. ": " .. tostring(err))
            RestoreRecordIds(records, originalIds, temporaryIds)
            return
        end
    end
    for idx = 1, #records do
        local ok, err = SetRecordId(records[idx], finalIds[idx])
        if not ok then
            FailLog("NormalizeIDs", "Final ID assignment failed on record #" .. idx .. ": " .. tostring(err))
            RestoreRecordIds(records, originalIds, temporaryIds)
            return
        end
    end
    RepaintMainForm("NormalizeIDs")
    print("[OK] Normalized " .. tostring(#records) .. " Cheat Table ID(s).")
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
    RefreshUiReferences()
    if mf and mf[controlName] then
        local ok, err = pcall(function() mf[controlName].Visible = not mf[controlName].Visible end)
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
local function NormalizeAnimationInterval(interval)
    local value = tonumber(interval) or 350
    value = math.floor(value)
    if value < MIN_ANIMATION_INTERVAL then return MIN_ANIMATION_INTERVAL end
    if value > MAX_ANIMATION_INTERVAL then return MAX_ANIMATION_INTERVAL end
    return value
end

local function BuildMenuCaption(label)
    return (Config.Prefix or "") .. tostring(label or "") .. (Config.Suffix or "")
end

local function SetMenuCaption(label)
    if not toolsMenuItem then return end
    local caption = BuildMenuCaption(label)
    RunInMainThread(function()
        if toolsMenuItem then toolsMenuItem.Caption = caption end
    end)
end

local function PrepareTicker(inner)
    tickerBuffer = " " .. tostring(inner or "") .. " "
end

local function RotateTicker()
    if not tickerBuffer or #tickerBuffer < 2 then return "" end
    tickerBuffer = tickerBuffer:sub(2) .. tickerBuffer:sub(1, 1)
    return tickerBuffer
end

local function StopCaptionAnimation()
    local timer = rotationTimer
    rotationTimer = nil
    tickerBuffer = nil
    if RuntimeState.rotationTimer == timer then RuntimeState.rotationTimer = nil end
    DestroyComponent(timer)
end

local function StartCaptionAnimation()
    StopCaptionAnimation()
    if not toolsMenuItem then
        FailLog("AnimateCaption", "toolsMenuItem is nil.")
        return
    end

    local label = trim(tostring(Config.MenuCaption or ""))
    SetMenuCaption(label)
    if not Config.AnimatedCaption or #label < 2 then return end

    Config.AnimationInterval = NormalizeAnimationInterval(Config.AnimationInterval)
    PrepareTicker(label)
    local ok, timer = pcall(function() return createTimer(nil) end)
    if not ok or not timer then
        FailLog("AnimateCaption", "Could not create timer: " .. tostring(timer))
        return
    end
    rotationTimer = timer
    RuntimeState.rotationTimer = timer
    timer.Interval = Config.AnimationInterval
    timer.OnTimer = function()
        if not toolsMenuItem then
            StopCaptionAnimation()
            return
        end
        SetMenuCaption(RotateTicker())
    end
end

local function SetCaptionAnimationEnabled(enabled)
    Config.AnimatedCaption = enabled and true or false
    StartCaptionAnimation()
    if RefreshSettingsMenu then RefreshSettingsMenu() end
end

local function SetCaptionAnimationInterval(interval)
    Config.AnimationInterval = NormalizeAnimationInterval(interval)
    StartCaptionAnimation()
    if RefreshSettingsMenu then RefreshSettingsMenu() end
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
    RefreshUiReferences()
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
    RefreshUiReferences()
    if not mainMenu then
        FailLog("Menu", "Main menu not available.")
        return
    end
    toolsMenuItem = createMenuItem(mainMenu)
    toolsMenuItem.Caption = BuildMenuCaption(Config.MenuCaption)
    toolsMenuItem.ImageList = safeGetImageList()
    mainMenu.Items.add(toolsMenuItem)
    RuntimeState.menuItem = toolsMenuItem
    StartCaptionAnimation()
end

--
--- ∑ Adds a child menu entry under the main Tools entry.
--- @param caption string # Text to display on the item.
--- @param onclick function # Function to execute on click.
--- @param imageIndex number|nil # Optional icon index for ImageList.
--- @param shortcut string|nil # Optional keyboard shortcut.
--- @return table|nil # The created item or nil on failure.
--
local function AddMenuItem(parent, caption, onclick, imageIndex, shortcut)
    if not parent then
        FailLog("Menu", "Parent menu item is nil.")
        return nil
    end
    local item = createMenuItem(parent)
    item.Caption = caption or ""
    if imageIndex then item.ImageIndex = imageIndex end
    if shortcut then item.Shortcut = shortcut end
    if onclick then item.OnClick = onclick end
    parent.add(item)
    return item
end

local function AddSubItem(caption, onclick, imageIndex, shortcut)
    return AddMenuItem(toolsMenuItem, caption, onclick, imageIndex, shortcut)
end

--
--- ∑ Add a separator menu item to the Cheat Engine main menu.
--- @return table|nil # The separator item or nil on failure.
--
local function AddSeparator(parent)
    parent = parent or toolsMenuItem
    if not parent then return nil end
    local separator = createMenuItem(parent)
    separator.Caption = "-"
    parent.add(separator)
    return separator
end

local function AddSettingsEntries()
    AddSeparator()
    local settingsMenu = AddMenuItem(toolsMenuItem, "Session Settings")
    if not settingsMenu then return end

    settingsItems.animatedCaption = AddMenuItem(settingsMenu, "Animate Caption", function()
        SetCaptionAnimationEnabled(not Config.AnimatedCaption)
    end)
    local speedMenu = AddMenuItem(settingsMenu, "Animation Speed")
    if speedMenu then
        settingsItems.speedSlow = AddMenuItem(speedMenu, "Slow (600 ms)", function() SetCaptionAnimationInterval(600) end)
        settingsItems.speedNormal = AddMenuItem(speedMenu, "Normal (350 ms)", function() SetCaptionAnimationInterval(350) end)
        settingsItems.speedFast = AddMenuItem(speedMenu, "Fast (200 ms)", function() SetCaptionAnimationInterval(200) end)
    end
    settingsItems.confirmDestructiveActions = AddMenuItem(settingsMenu, "Confirm Destructive Actions", function()
        Config.ConfirmDestructiveActions = not Config.ConfirmDestructiveActions
        RefreshSettingsMenu()
    end)
    AddSeparator(settingsMenu)
    AddMenuItem(settingsMenu, "Reset Caption Animation", function()
        StartCaptionAnimation()
        RefreshSettingsMenu()
    end)

    RefreshSettingsMenu = function()
        if settingsItems.animatedCaption then settingsItems.animatedCaption.Checked = Config.AnimatedCaption end
        if settingsItems.confirmDestructiveActions then settingsItems.confirmDestructiveActions.Checked = Config.ConfirmDestructiveActions end
        if settingsItems.speedSlow then settingsItems.speedSlow.Checked = Config.AnimationInterval == 600 end
        if settingsItems.speedNormal then settingsItems.speedNormal.Checked = Config.AnimationInterval == 350 end
        if settingsItems.speedFast then settingsItems.speedFast.Checked = Config.AnimationInterval == 200 end
    end
    RefreshSettingsMenu()
end

--
--- ∑ Creates all submenu entries under the Manifold utilities menu.
--- @return nil # No return value.
--
local function CreateUtilityEntries()
    AddSubItem("Open Lua Engine", function()
        RunInMainThread(function()
            RefreshUiReferences()
            if le then le.Show() end
        end)
    end, Config.Indices.LuaEngine, "Ctrl+L")
    AddSubItem("Open Memory Viewer", function()
        RunInMainThread(function()
            RefreshUiReferences()
            if mv then mv.Show() end
        end)
    end, Config.Indices.Open)
    AddSeparator()
    AddSubItem("Open Structure Dissect", function() RunInMainThread(function() createStructureForm(nil, nil, nil) end) end, Config.Indices.NewWindow)
    AddSubItem("Generate Structure Records", function() GenerateStructure() end, Config.Indices.NewWindow)
    AddSubItem("Remove All Structures", function() DeleteAllStructures() end, Config.Indices.Destroy)
    AddSeparator()
    AddSubItem("Deactivate All Scripts", function() DeactivateActiveScripts() end, Config.Indices.Toggle, "Ctrl+D")
    AddSubItem("Deactivate Everything", function() DeactivateEverything() end, Config.Indices.Toggle, "Ctrl+F")
    AddSubItem("Normalize Cheat Table IDs", function() NormalizeCheatTableIDs() end, Config.Indices.Toggle)
    AddSeparator()
    AddSubItem("Toggle Compact Mode", function() ToggleCompactMode() end, Config.Indices.Open, "Ctrl+Shift+F")
    AddSeparator()
    AddSubItem("Open Autorun Folder", function() OpenAutorunFolder() end, Config.Indices.Folder)
    AddSubItem("Open Process Folder", function() OpenProcessFolder() end, Config.Indices.Folder)
    AddSettingsEntries()
end

----------------------------------------
-- ENTRYPOINT
----------------------------------------

--
--- ∑ Initializes menu icons, creates menu and registers all utility entries.
--- @return nil # No return value.
--
local function Main()
    DisposePreviousInstance()
    RefreshUiReferences()
    GetImageListAndIndices()
    AddTopMenuEntry()
    if toolsMenuItem then CreateUtilityEntries() end
end

Main()