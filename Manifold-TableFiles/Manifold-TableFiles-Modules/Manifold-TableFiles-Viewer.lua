--[[
    The Table Files window: state, controller and composition.

    Cheat Engine only reaches attached files through the Table menu, one
    context menu per file, so anything in bulk is tedious. The list here is
    multi-select, which makes removing or exporting twenty files one action,
    and the editor beside it saves back into the table.

    THE STATE MODEL

    The controls are a rendering of this, not the thing itself:

        state.Files      every attached file, as info records (metadata only)
        state.Visible    Files after the filter and the sort
        state.Filter     the filter string
        state.Sort       { Key = "Name"|"Type"|"Size", Ascending = boolean }
        state.Selection  the selected names, in list order
        state.Rendering  true while the list is being repopulated

    The editor owns what the editor knows: the active file, the buffer and
    the dirty flag. The viewer asks it, and never reads a SynEdit directly.

    Keeping the two apart is what fixes the worst bug in the first version:
    the filter box called the same Refresh that rebuilt everything, so typing
    into it silently discarded an unsaved edit. Here the list view and the
    editor are refreshed by different calls, and only an explicit change of
    file goes through ResolveDirtyBuffer.

    NAVIGATION AND UNSAVED WORK

    ResolveDirtyBuffer is the single gate in front of anything that would
    replace or remove the buffer: switching files, closing, renaming, saving
    over, deleting the open file, exporting it. It offers Save, Discard and
    Cancel, and a Cancel really cancels the operation that asked.

    LAYOUT

    Aligned controls are placed towards their own edge as they are created,
    so the last one built ends up closest to that edge and the visual order
    is the reverse of the creation order. Hence the splitter before the list
    it divides, and the bars built right to left.

        +--------------------------------------------------+
        | Add  New | Rename Duplicate Remove Export | Refr  |  alTop
        +---------------+----------------------------------+
        | list card     |§| editor card                    |  alLeft | alClient
        +---------------+----------------------------------+
        | status                                    detail |  alBottom
        | Save                                       Close |  alBottom
        +--------------------------------------------------+
]]

local Viewer = {}
Viewer.__index = Viewer

local LIST_WIDTH = 400
--- Type and Size are fixed; Name takes everything else. AutoWidthLastColumn
--- would grow the wrong one, so the split is worked out on every resize.
local COLUMN_TYPE, COLUMN_SIZE = 104, 62
local COLUMN_NAME_MIN = 120
--- Room for the vertical scrollbar, so a full list does not push the columns
--- past the right edge and produce a horizontal one as well.
local SCROLLBAR = 20

--
--- @param services table # Theme, Files, Types, Images, Editor, Log,
---        RunInMainThread, Confirm and Version. Everything the window needs
---        from outside, so the module stays testable without Cheat Engine.
--
function Viewer:New(services)
    services = services or {}
    return setmetatable({
        Theme = services.Theme,
        Files = services.Files,
        Types = services.Types,
        Images = services.Images,
        EditorClass = services.Editor,
        Log = services.Log,
        RunInMainThread = services.RunInMainThread,
        Confirm = services.Confirm,
        Version = services.Version,
        State = nil,
        Editor = nil
    }, Viewer)
end

function Viewer:Say(message)
    if type(self.Log) == "function" then self.Log(message, false) end
end

function Viewer:Fail(message)
    if type(self.Log) == "function" then self.Log(message, true) end
end

-- State -----------------------------------------------------------------------

--
--- ∑ Re-reads the table's file list. Metadata only: no file body is touched,
---   so this stays cheap with hundreds of attachments.
--- @return nil # No return value.
--
function Viewer:ReloadFiles()
    local state = self.State
    if not state then return end
    state.Files = self.Files:List()
end

--- Case-insensitive plain substring. A pattern match would turn the dot in a
--- file name into a wildcard.
local function matchesFilter(info, needle)
    if needle == "" then return true end
    if info.Name:lower():find(needle, 1, true) then return true end
    -- "lua", "cea" and friends select by type as well, which is the one bit
    -- of type filtering worth having without inventing a query language.
    return info.Extension == needle or info.Type.Display:lower():find(needle, 1, true) ~= nil
end

local function compare(a, b, key, ascending)
    local first, second
    if key == "Type" then
        first, second = a.Type.Display:lower(), b.Type.Display:lower()
    elseif key == "Size" then
        first, second = a.Size, b.Size
    else
        first, second = a.Name:lower(), b.Name:lower()
    end
    if first == second then return a.Name:lower() < b.Name:lower() end
    if ascending then return first < second end
    return first > second
end

--
--- ∑ Applies the filter and the sort. Touches no control and no buffer.
--- @return nil # No return value.
--
function Viewer:ApplyView()
    local state = self.State
    if not state then return end
    local needle = tostring(state.Filter or ""):lower():match("^%s*(.-)%s*$")
    local visible = {}
    for _, info in ipairs(state.Files) do
        if matchesFilter(info, needle) then visible[#visible + 1] = info end
    end
    table.sort(visible, function(a, b)
        return compare(a, b, state.Sort.Key, state.Sort.Ascending)
    end)
    state.Visible = visible
end

--
--- ∑ Repopulates the list view from state.Visible and restores the selection
---   for the rows that are still there.
---   Rendering is bracketed by beginUpdate/endUpdate so a few hundred files
---   do not repaint per row, and by state.Rendering so the selection events
---   it raises are ignored.
--- @return nil # No return value.
--
function Viewer:RenderList()
    local state = self.State
    if not state or not state.List then return end
    local wanted = {}
    for _, name in ipairs(state.Selection) do wanted[name] = true end

    state.Rendering = true
    pcall(function() state.List.beginUpdate() end)
    pcall(function()
        state.List.Items.clear()
        for _, info in ipairs(state.Visible) do
            local item = state.List.Items.add()
            item.Caption = info.Name
            item.SubItems.add(info.Type.Display)
            item.SubItems.add(self.Files.FormatSize(info.Size))
            if state.ImageIndex then
                item.ImageIndex = state.ImageIndex(info.Type.Key)
            end
            if wanted[info.Name] then item.Selected = true end
        end
    end)
    pcall(function() state.List.endUpdate() end)
    state.Rendering = false

    -- The selection may have shrunk: rows that the filter hid are no longer
    -- selectable, so the record of it has to agree with what is on screen.
    self:CaptureSelection()
    self:UpdateStatus()
    self:UpdateActions()
end

--
--- ∑ Gives Name whatever width Type and Size do not need.
---   The LCL can only auto-size the LAST column, which here is the one that
---   should stay narrow, so the split is computed instead. Called on every
---   resize, which is what keeps the list free of a horizontal scrollbar as
---   the splitter moves.
--- @return nil # No return value.
--
function Viewer:FitColumns()
    local state = self.State
    if not state or not state.List or not state.NameColumn then return end
    local width
    if not pcall(function() width = tonumber(state.List.ClientWidth) end) or not width then
        pcall(function() width = tonumber(state.List.Width) end)
    end
    if not width or width <= 0 then return end
    local remaining = width - COLUMN_TYPE - COLUMN_SIZE - SCROLLBAR
    pcall(function()
        state.NameColumn.Width = math.max(COLUMN_NAME_MIN, remaining)
    end)
end

--- Puts the keyboard back on the file list, e.g. after a dialog closed.
function Viewer:FocusList()
    local state = self.State
    if not state or not state.List then return end
    pcall(function() state.List.setFocus() end)
end

--- Reads the selection out of the list and into the state.
function Viewer:CaptureSelection()
    local state = self.State
    if not state or not state.List then return end
    local names = {}
    pcall(function()
        for index = 0, (tonumber(state.List.Items.Count) or 0) - 1 do
            local item = state.List.Items[index]
            if item and item.Selected then names[#names + 1] = item.Caption end
        end
    end)
    state.Selection = names
end

--- The selected names.
function Viewer:SelectedNames()
    return self.State and self.State.Selection or {}
end

--- Puts the list selection back on one name, without raising a file switch.
function Viewer:ReselectOnly(name)
    local state = self.State
    if not state or not state.List then return end
    state.Rendering = true
    pcall(function()
        for index = 0, (tonumber(state.List.Items.Count) or 0) - 1 do
            local item = state.List.Items[index]
            if item then item.Selected = (item.Caption == name) end
        end
    end)
    state.Rendering = false
    self:CaptureSelection()
    self:UpdateStatus()
    self:UpdateActions()
end

-- Status and enabled states ---------------------------------------------------

function Viewer:UpdateStatus()
    local state = self.State
    if not state or not state.Status then return end
    local total, shown = #state.Files, #state.Visible
    local selected = #state.Selection

    local primary
    if total == 0 then
        primary = "No files attached"
    elseif shown ~= total then
        primary = string.format("%d of %d files", shown, total)
    elseif selected > 1 then
        primary = string.format("%d of %d files selected", selected, total)
    else
        primary = string.format("%d file%s", total, total == 1 and "" or "s")
    end

    -- The detail half describes what is open, not what is selected: those
    -- differ during a multi-selection and the editor is the one that matters.
    local detail = {}
    local activeName = self.Editor and self.Editor:ActiveName()
    local info = self.Editor and self.Editor.Info
    if activeName and info then
        detail[#detail + 1] = info.Type.Display
        detail[#detail + 1] = self.Files.FormatSize(info.Size)
        local line, column = self.Editor:CaretLineCol()
        if line then detail[#detail + 1] = string.format("Ln %d, Col %d", line, column) end
        if self.Editor:IsDirty() then detail[#detail + 1] = "Modified" end
    elseif info then
        detail[#detail + 1] = info.Type.Display
        detail[#detail + 1] = self.Files.FormatSize(info.Size)
    end

    pcall(function() state.Status.Caption = primary end)
    pcall(function() state.Detail.Caption = table.concat(detail, "     ") end)

    if state.EditorTitle then
        local caption = "No file selected"
        if activeName then
            caption = activeName .. (self.Editor:IsDirty() and " *" or "")
        elseif info then
            caption = info.Name
        end
        pcall(function() state.EditorTitle.Caption = caption end)
    end
end

--
--- ∑ Brings every action's enabled state in line with the selection and the
---   buffer, so nothing is offered that would do nothing.
--- @return nil # No return value.
--
function Viewer:UpdateActions()
    local state = self.State
    if not state then return end
    local count = #state.Selection
    local dirty = self.Editor and self.Editor:IsDirty()

    local function set(name, enabled)
        local setter = state.Actions[name]
        if setter then setter(enabled) end
    end
    set("Rename", count == 1)
    set("Duplicate", count == 1)
    set("Remove", count >= 1)
    set("Export", count >= 1)
    set("Save", dirty == true)

    if state.Popup then
        state.Popup.Enable("Rename", count == 1)
        state.Popup.Enable("Duplicate", count == 1)
        state.Popup.Enable("Remove", count >= 1)
        state.Popup.Enable("Export...", count >= 1)
        state.Popup.Enable("Copy Name", count == 1)
    end
end

-- The dirty gateway -----------------------------------------------------------

--
--- ∑ The single gate in front of anything that would replace or discard the
---   editor's contents.
---
---   Every caller must honour a false: it means the user chose Cancel and
---   the operation that asked has to stop. Nothing in this file discards a
---   buffer without coming through here.
--- @param reason string # What is about to happen, phrased for the dialog.
--- @return boolean # True when it is safe to proceed.
--
function Viewer:ResolveDirtyBuffer(reason)
    if not self.Editor or not self.Editor:IsDirty() then return true end
    local name = self.Editor:ActiveName() or "The open file"
    local choice = self.Theme:AskChoice({
        Caption = "Unsaved changes",
        Title = "'" .. name .. "' has unsaved changes.",
        Message = "Save them before " .. reason .. "?",
        Choices = {
            { Key = "save", Caption = "Save" },
            { Key = "discard", Caption = "Discard" },
            { Key = "cancel", Caption = "Cancel" }
        }
    })
    if choice == "save" then return self:Save() end
    if choice == "discard" then return true end
    -- Anything else, a dismissed dialog included, keeps the buffer.
    return false
end

-- Opening files ---------------------------------------------------------------

--
--- ∑ Puts a file in the editor. Binary attachments are described rather than
---   loaded: a control that normalises what it is given would write back
---   something other than what was read.
--- @param name string # The file to open.
--- @return nil # No return value.
--
function Viewer:OpenFile(name)
    local info = self.Files:GetInfo(name)
    if not info.Exists then
        self.Editor:Clear(name, "This file is no longer attached to the table.")
        self:UpdateStatus()
        return
    end
    if not info.IsText then
        self.Editor:LoadUneditable(info, string.format(
            "%s, %s. Binary attachments are not opened for editing; export, rename and remove still work.",
            info.Type.Display, self.Files.FormatSize(info.Size)))
        self:UpdateStatus()
        return
    end
    local text, err = self.Files:Read(name)
    if not text then
        self.Editor:LoadUneditable(info, tostring(err))
        self:UpdateStatus()
        return
    end
    if self.Files.LooksBinary(text) then
        local binary = self.Files:GetInfo(name)
        binary.Type = self.Types.Binary
        binary.IsText = false
        self.Editor:LoadUneditable(binary, string.format(
            "This file contains binary data (%s). It is not opened for editing so its bytes cannot be altered; export, rename and remove still work.",
            self.Files.FormatSize(info.Size)))
        self:UpdateStatus()
        return
    end
    self.Editor:Load(info, text)
    self:UpdateStatus()
end

--
--- ∑ Reacts to the list selection changing.
---   One file opens in the editor; a multiple selection is for the bulk
---   actions and deliberately leaves the buffer where it is.
--- @return nil # No return value.
--
function Viewer:SelectionChanged()
    local state = self.State
    if not state or state.Rendering then return end
    self:CaptureSelection()
    self:UpdateStatus()
    self:UpdateActions()

    local selected = state.Selection
    if #selected ~= 1 then return end
    local wanted = selected[1]
    if wanted == self.Editor:ActiveName() then return end
    if not self:ResolveDirtyBuffer("opening '" .. wanted .. "'") then
        -- Cancelled: the list must not appear to have moved on.
        local active = self.Editor:ActiveName()
        if active then self:ReselectOnly(active) end
        return
    end
    self:OpenFile(wanted)
end

-- Actions ---------------------------------------------------------------------

function Viewer:Save()
    local editor = self.Editor
    if not editor or not editor:ActiveName() then return false end
    local text = editor:Text()
    if text == nil then return false end
    local name = editor:ActiveName()
    if not self.Files:Write(name, text) then
        self:Fail("Could not save '" .. name .. "'.")
        return false
    end
    editor:MarkSaved()
    -- The size changed, so the row and the status line are both stale.
    self:ReloadFiles()
    self:ApplyView()
    self:RenderList()
    if editor.Info then editor.Info = self.Files:GetInfo(name) end
    self:UpdateStatus()
    self:Say("Saved '" .. name .. "'.")
    return true
end

--
--- ∑ Re-reads the table's files without disturbing the editor.
---   Refresh means "agree with the table again", not "start over": the
---   buffer, the selection and the filter all survive it. The one case that
---   needs saying out loud is the open file having disappeared from under us.
--- @return nil # No return value.
--
function Viewer:Refresh()
    local state = self.State
    if not state then return end
    local activeName = self.Editor:ActiveName()
    self:ReloadFiles()
    self:ApplyView()
    self:RenderList()
    if activeName and not self.Files:Exists(activeName) then
        if self.Editor:IsDirty() then
            self:Fail("'" .. activeName .. "' is no longer attached to this table. " ..
                      "The editor still holds your changes; saving will re-create it.")
        else
            self.Editor:Clear("No file selected", "Select a table file to view or edit it.")
        end
        self:UpdateStatus()
    end
end

--
--- ∑ Creates a new file. The type decides the extension and any starter
---   content, so a new Auto Assembler script opens with its two blocks
---   already in place rather than as an empty buffer.
--- @return nil # No return value.
--
function Viewer:NewFile()
    local creatable = self.Types.Creatable()
    local choices = {}
    for _, definition in ipairs(creatable) do
        choices[#choices + 1] = {
            Key = definition.Extension,
            Caption = "." .. definition.Extension:upper(),
            Hint = definition.Display,
            Width = 88
        }
    end
    choices[#choices + 1] = { Key = "cancel", Caption = "Cancel", Width = 92 }
    local kind = self.Theme:AskChoice({
        Caption = "New table file",
        Title = "What kind of file?",
        Message = "These are shortcuts. Any other extension can be typed into the name, "
            .. "and it decides the syntax highlighting either way.",
        Choices = choices
    })
    if not kind or kind == "cancel" then return end

    local definition = self.Types.ByExtension(kind)
    if not definition then return end

    local suggestion = self.Files:SuggestName("New File." .. definition.Extension)
    local name = self.Theme:AskText("New table file", "File name:", suggestion)
    if not name then return end
    name = tostring(name):match("^%s*(.-)%s*$")
    if name == "" then return end
    -- A name typed without an extension gets the one that was chosen.
    if self.Types.ExtensionOf(name) == "" then name = name .. "." .. definition.Extension end

    -- The name has the last word: typing "Notes.md" after clicking .TXT
    -- should produce Markdown, not a text file with a text file's template.
    local finalType = self.Types.ByExtension(self.Types.ExtensionOf(name)) or definition
    local content = finalType.Template
    if content and content:find("%%s") then content = string.format(content, name) end
    local ok, err = self.Files:Create(name, content)
    if not ok then
        self:Fail("Could not create '" .. name .. "': " .. tostring(err))
        self.Theme:AskChoice({
            Caption = "New table file", Title = "The file was not created.",
            Message = tostring(err), Choices = { { Key = "ok", Caption = "OK" } }
        })
        return
    end
    self:Say("Created '" .. name .. "'.")
    self.State.Selection = { name }
    self:Refresh()
    if self:ResolveDirtyBuffer("opening '" .. name .. "'") then
        self:ReselectOnly(name)
        self:OpenFile(name)
    end
end

--
--- ∑ Attaches files from disk.
---   A name that is already attached is never overwritten without being
---   asked about. With several files to import the answer can be applied to
---   the rest, which is the difference between a bulk import and twenty
---   dialogs.
--- @return nil # No return value.
--
function Viewer:Add()
    local state = self.State
    local dialog = createOpenDialog(state.Form)
    pcall(function()
        dialog.Options = "[ofAllowMultiSelect,ofFileMustExist]"
        dialog.Filter = "Table files|*.lua;*.CEA;*.AA;*.asm;*.txt;*.json|All files|*.*"
    end)
    if not dialog.execute() then return end

    local paths = {}
    pcall(function()
        for index = 0, (tonumber(dialog.Files.Count) or 0) - 1 do
            paths[#paths + 1] = dialog.Files[index]
        end
    end)
    if #paths == 0 then
        local single
        pcall(function() single = dialog.FileName end)
        if single and single ~= "" then paths = { single } end
    end
    if #paths == 0 then return end

    local added, skipped, failed, replaced = 0, 0, {}, 0
    local standing = nil
    local lastName = nil

    for position, path in ipairs(paths) do
        local name = self.Files.BaseName(path)
        local action = "import"
        if self.Files:Exists(name) then
            action = standing
            if not action then
                local remaining = #paths - position
                local choice, applyToAll = self.Theme:AskChoice({
                    Caption = "File already attached",
                    Title = "'" .. name .. "' is already attached to this table.",
                    Message = "Replacing it overwrites the attached copy. Keeping both attaches the new file under a free name.",
                    Choices = {
                        { Key = "replace", Caption = "Replace" },
                        { Key = "keep", Caption = "Keep both", Width = 110 },
                        { Key = "skip", Caption = "Skip" },
                        { Key = "cancel", Caption = "Cancel" }
                    },
                    CheckBox = remaining > 0
                        and string.format("Apply to the remaining %d file(s)", remaining)
                        or nil,
                    Width = 620
                })
                action = choice or "cancel"
                if applyToAll then standing = action end
            end
        end

        if action == "cancel" then
            self:Say(string.format("Import cancelled after %d file(s).", added))
            break
        elseif action == "skip" then
            skipped = skipped + 1
        else
            local target = name
            if action == "keep" then
                target = self.Files:SuggestName(name)
            elseif action == "replace" then
                -- The open buffer is about to be replaced underneath: settle
                -- it first, and drop the attachment only once the new bytes
                -- are safely in, so a failed import cannot destroy the old copy.
                if self.Editor:ActiveName() == name
                    and not self:ResolveDirtyBuffer("replacing '" .. name .. "'") then
                    break
                end
                local staging = self.Files:SuggestName(name)
                local ok, err = self.Files:ImportOne(path, staging)
                if ok then
                    self.Files:Delete({ name })
                    local renamed, renameErr = self.Files:Rename(staging, name)
                    if renamed then
                        replaced = replaced + 1
                        lastName = name
                    else
                        failed[#failed + 1] = name .. " (" .. tostring(renameErr) .. ")"
                    end
                else
                    failed[#failed + 1] = name .. " (" .. tostring(err) .. ")"
                end
                target = nil
            end
            if target then
                local ok, err = self.Files:ImportOne(path, target)
                if ok then
                    added = added + 1
                    lastName = target
                else
                    failed[#failed + 1] = target .. " (" .. tostring(err) .. ")"
                end
            end
        end
    end

    local parts = {}
    if added > 0 then parts[#parts + 1] = string.format("%d added", added) end
    if replaced > 0 then parts[#parts + 1] = string.format("%d replaced", replaced) end
    if skipped > 0 then parts[#parts + 1] = string.format("%d skipped", skipped) end
    if #parts > 0 then self:Say("Import: " .. table.concat(parts, ", ") .. ".") end
    if #failed > 0 then
        self:Fail("Could not import: " .. table.concat(failed, "; "))
    end

    if lastName then self.State.Selection = { lastName } end
    self:Refresh()
    -- Replacing the open file means what is in the editor is now stale.
    local activeName = self.Editor:ActiveName()
    if activeName and replaced > 0 and not self.Editor:IsDirty() then
        self:OpenFile(activeName)
    end
end

function Viewer:Rename()
    local selected = self:SelectedNames()
    if #selected ~= 1 then
        self:Say("Select exactly one file to rename.")
        return
    end
    local oldName = selected[1]
    -- Renaming copies what is stored, so an unsaved buffer has to be settled
    -- or the edit would be left behind under the old name.
    if self.Editor:ActiveName() == oldName
        and not self:ResolveDirtyBuffer("renaming '" .. oldName .. "'") then
        return
    end
    local newName = self.Theme:AskText("Rename table file", "New name:", oldName)
    if not newName then return end
    newName = tostring(newName):match("^%s*(.-)%s*$")
    if newName == oldName then return end

    local ok, err = self.Files:Rename(oldName, newName)
    if not ok then
        self:Fail("Rename failed: " .. tostring(err))
        self.Theme:AskChoice({
            Caption = "Rename table file", Title = "'" .. oldName .. "' was not renamed.",
            Message = tostring(err), Choices = { { Key = "ok", Caption = "OK" } }
        })
        return
    end
    local wasActive = self.Editor:ActiveName() == oldName
    self:Say("Renamed '" .. oldName .. "' to '" .. newName .. "'.")
    self.State.Selection = { newName }
    self:Refresh()
    self:ReselectOnly(newName)
    if wasActive then self:OpenFile(newName) end
    self:FocusList()
end

function Viewer:Duplicate()
    local selected = self:SelectedNames()
    if #selected ~= 1 then
        self:Say("Select exactly one file to duplicate.")
        return
    end
    local source = selected[1]
    -- The copy is made from what is stored, so say so rather than quietly
    -- duplicating a version the user is not looking at.
    if self.Editor:ActiveName() == source
        and not self:ResolveDirtyBuffer("duplicating '" .. source .. "'") then
        return
    end
    local ok, result = self.Files:Duplicate(source)
    if not ok then
        self:Fail("Duplicate failed: " .. tostring(result))
        return
    end
    self:Say("Duplicated '" .. source .. "' as '" .. result .. "'.")
    self.State.Selection = { result }
    self:Refresh()
    self:ReselectOnly(result)
    self:FocusList()
end

function Viewer:Delete()
    local selected = self:SelectedNames()
    if #selected == 0 then
        self:Say("Select the files to remove.")
        return
    end
    local activeName = self.Editor:ActiveName()
    local hitsActive = false
    for _, name in ipairs(selected) do
        if name == activeName then hitsActive = true end
    end
    -- Deleting what is being edited destroys the buffer too, so it goes
    -- through the same gate as any other way of losing it.
    if hitsActive and not self:ResolveDirtyBuffer("removing '" .. activeName .. "'") then
        return
    end

    local what = #selected == 1
        and ("Remove the table file '" .. selected[1] .. "'")
        or ("Remove " .. #selected .. " table files")
    if type(self.Confirm) == "function" and not self.Confirm(what, #selected) then return end

    local removed, failed = self.Files:Delete(selected)
    self:Say(string.format("Removed %d of %d table file(s).", removed, #selected))
    if #failed > 0 then
        self:Fail("Could not remove: " .. table.concat(failed, ", "))
    end
    if hitsActive and not self.Files:Exists(activeName) then
        self.Editor:Clear("No file selected", "Select a table file to view or edit it.")
    end
    self.State.Selection = {}
    self:Refresh()
    self:FocusList()
end

--
--- ∑ Writes the selection out to disk.
---   An unsaved buffer is settled first, so what lands on disk is never an
---   older copy than what the editor is showing.
--- @return nil # No return value.
--
function Viewer:Export()
    local state = self.State
    local selected = self:SelectedNames()
    if #selected == 0 then
        self:Say("Select the files to export.")
        return
    end
    local activeName = self.Editor:ActiveName()
    for _, name in ipairs(selected) do
        if name == activeName and not self:ResolveDirtyBuffer("exporting '" .. name .. "'") then
            return
        end
    end

    if #selected == 1 then
        local dialog = createSaveDialog(state.Form)
        pcall(function() dialog.FileName = selected[1] end)
        if not dialog.execute() then return end
        local ok, err = self.Files:Export(selected[1], dialog.FileName)
        if ok then
            self:Say("Exported '" .. selected[1] .. "'.")
        else
            self:Fail("Export failed: " .. tostring(err))
        end
        return
    end

    local dialog = createSelectDirectoryDialog(state.Form)
    if not dialog.execute() then return end
    local written, failed = 0, {}
    for _, name in ipairs(selected) do
        local ok, err = self.Files:Export(name, dialog.FileName .. "\\" .. name)
        if ok then written = written + 1 else failed[#failed + 1] = name .. " (" .. tostring(err) .. ")" end
    end
    self:Say(string.format("Exported %d of %d table file(s).", written, #selected))
    if #failed > 0 then self:Fail("Could not export: " .. table.concat(failed, "; ")) end
end

function Viewer:CopyName()
    local selected = self:SelectedNames()
    if #selected ~= 1 then return end
    local copied = false
    if type(writeToClipboard) == "function" then
        copied = pcall(writeToClipboard, selected[1])
    end
    if copied then
        self:Say("Copied '" .. selected[1] .. "' to the clipboard.")
    else
        self:Fail("The clipboard is not reachable from this Cheat Engine build.")
    end
end

-- Editor commands -------------------------------------------------------------

function Viewer:FindInEditor()
    if not self.Editor:ActiveName() then return end
    local needle = self.Theme:AskText("Find", "Find what:", self.State.LastSearch or "")
    if not needle or needle == "" then return end
    self.State.LastSearch = needle
    local found, line = self.Editor:Find(needle, { FromStart = false })
    if found then
        self:Say(string.format("Found '%s' on line %d.", needle, line))
    else
        self:Say(string.format("'%s' is not in this file.", needle))
    end
    self.Editor:Focus()
    self:UpdateStatus()
end

function Viewer:ReplaceInEditor()
    if not self.Editor:ActiveName() then return end
    local needle = self.Theme:AskText("Replace", "Find what:", self.State.LastSearch or "")
    if not needle or needle == "" then return end
    self.State.LastSearch = needle
    local replacement = self.Theme:AskText("Replace", "Replace with:", self.State.LastReplace or "")
    if replacement == nil then return end
    self.State.LastReplace = replacement
    local count = self.Editor:ReplaceAll(needle, replacement, false)
    self:Say(count == 0
        and string.format("'%s' is not in this file.", needle)
        or string.format("Replaced %d occurrence(s).", count))
    self.Editor:Focus()
    self:UpdateStatus()
end

function Viewer:GotoLine()
    if not self.Editor:ActiveName() then return end
    local answer = self.Theme:AskText("Go to line", "Line number:", "")
    local line = tonumber(answer)
    if not line then return end
    if not self.Editor:GotoLine(line) then
        self:Say("There is no line " .. tostring(line) .. " in this file.")
    end
    self.Editor:Focus()
    self:UpdateStatus()
end

-- The window ------------------------------------------------------------------

function Viewer:IsOpen()
    local state = self.State
    if not state or not state.Form then return false end
    local ok, className = pcall(function() return state.Form.ClassName end)
    return ok and className ~= nil
end

function Viewer:Build()
    local theme = self.Theme
    local state = {
        Files = {}, Visible = {}, Selection = {},
        Filter = "", Sort = { Key = "Name", Ascending = true },
        Rendering = false, Actions = {}
    }
    self.State = state

    local caption = "Manifold — Table Files"
    if self.Version then caption = caption .. "  ·  " .. self.Version.String() end
    local form, palette = theme:CreateWindow(caption, 1120, 700)
    state.Form = form

    self.Images:Build(palette)
    state.ImageIndex = function(key) return self.Images:IndexOf(key) end

    -- Toolbar. Built right to left, so it reads Add / New | Rename /
    -- Duplicate / Remove / Export | Refresh, with the filter on the far right.
    local toolbar = theme:CreateToolBar(form, 42)

    local filter = createEdit(toolbar)
    theme.SafeSet(filter, "Parent", toolbar)
    theme.SafeSet(filter, "Align", "alRight")
    theme.SafeSet(filter, "Width", 240)
    theme.SafeSet(filter, "TextHint", "Filter by name or type...")
    pcall(function() filter.BorderSpacing.Around = 6 end)
    theme:StyleEdit(filter)
    -- Filtering touches the view and nothing else. This is the call that used
    -- to rebuild the world and take the buffer with it.
    filter.OnChange = function()
        state.Filter = tostring(filter.Text or "")
        self:ApplyView()
        self:RenderList()
    end
    state.FilterControl = filter

    local function toolButton(text, handler, hint, actionKey)
        local _, setEnabled = theme:CreateButton(toolbar, {
            Caption = text, Align = "alLeft", Width = 94,
            Hint = hint, OnClick = handler
        })
        if actionKey then state.Actions[actionKey] = setEnabled end
    end
    toolButton("Refresh", function() self:Refresh() end, "Re-read the table's file list (F5)")
    theme:CreateToolSeparator(toolbar)
    toolButton("Export...", function() self:Export() end, "Write the selected files to disk", "Export")
    toolButton("Remove", function() self:Delete() end, "Delete the selected files from the table", "Remove")
    toolButton("Duplicate", function() self:Duplicate() end, "Copy the selected file under a free name", "Duplicate")
    toolButton("Rename", function() self:Rename() end, "Rename the selected file (F2)", "Rename")
    theme:CreateToolSeparator(toolbar)
    toolButton("New...", function() self:NewFile() end, "Create a new table file")
    toolButton("Add...", function() self:Add() end, "Attach files from disk to this table")

    local status, _, detail = theme:CreateStatusBar(form, "")
    state.Status, state.Detail = status, detail

    local footer = theme:CreateButtonBar(form, 44)
    local _, setSaveEnabled = theme:CreateButton(footer, {
        Caption = "Save", Align = "alRight", Width = 96,
        Hint = "Write the editor's contents back into the table (Ctrl+S)",
        OnClick = function() self:Save() end
    })
    state.Actions.Save = setSaveEnabled
    theme:CreateButton(footer, {
        Caption = "Close", Align = "alRight", Width = 96,
        OnClick = function() pcall(function() form.close() end) end
    })

    -- The splitter is built before the card it divides so it ends up to the
    -- right of it.
    theme:CreateSplitter(form, { Align = "alLeft", MinSize = 220 })
    -- The width the splitter was left at is kept for the session, so
    -- reopening the window does not undo the user's arrangement.
    local listWidth = self.ListWidth or LIST_WIDTH
    local listContent, listCard = theme:CreateCard(form, {
        Align = "alLeft", Width = listWidth, Title = "Table Files"
    })
    state.ListCard = listCard
    local list = createListView(listContent)
    theme.SafeSet(list, "Parent", listContent)
    theme.SafeSet(list, "Align", "alClient")
    theme:StyleListView(list, { Images = self.Images:GetList() })
    state.NameColumn = theme:AddListColumn(list, "Name", listWidth - COLUMN_TYPE - COLUMN_SIZE - SCROLLBAR)
    theme:AddListColumn(list, "Type", COLUMN_TYPE)
    theme:AddListColumn(list, "Size", COLUMN_SIZE)
    pcall(function() list.OnResize = function() self:FitColumns() end end)
    pcall(function() list.OnSelectItem = function() self:SelectionChanged() end end)
    pcall(function() list.OnDblClick = function() self:ActivateSelected() end end)
    pcall(function()
        list.OnColumnClick = function(_, column)
            self:SortByColumn(column)
        end
    end)
    state.List = list

    local editorContent, _, editorTitle = theme:CreateCard(form, {
        Align = "alClient", Title = "No file selected"
    })
    state.EditorTitle = editorTitle

    self.Editor = self.EditorClass:New({
        Theme = theme, Types = self.Types, Log = self.Log
    })
    self.Editor.OnDirtyChanged = function()
        self:UpdateStatus()
        self:UpdateActions()
    end
    self.Editor.OnCaretMoved = function() self:UpdateStatus() end
    self.Editor:Build(editorContent)

    -- Which pane has focus decides what a keystroke means. Tracked through
    -- OnEnter rather than read back from Form.ActiveControl, because two
    -- lookups of the same Cheat Engine object need not be the same Lua value
    -- and comparing them would be unreliable.
    pcall(function() list.OnEnter = function() state.Focus = "list" end end)
    for _, slot in pairs(self.Editor.Slots) do
        pcall(function() slot.Control.OnEnter = function() state.Focus = "editor" end end)
    end
    state.Focus = "list"

    self:BuildMenus()

    form.OnClose = function()
        if not self:ResolveDirtyBuffer("closing the window") then return caNone end
        -- Keep the pane width for the next open in this session.
        pcall(function() self.ListWidth = tonumber(state.ListCard.Width) or self.ListWidth end)
        -- Let go of everything that points at LCL objects the form is about
        -- to free, so a reopen cannot touch stale userdata.
        self.Images:Destroy()
        self.Editor = nil
        self.State = nil
        return caFree
    end

    self:ReloadFiles()
    self:ApplyView()
    self:RenderList()
    self:FitColumns()
    if #state.Files == 0 then
        self.Editor:Clear("No table files attached",
            "Use Add... to attach files from disk, or New... to create one.")
    end
    self:UpdateStatus()
    return form, palette
end

--
--- ∑ Context menus for the two panes.
---   The shortcuts live on whichever menu belongs to the control that would
---   sensibly receive them: the LCL dispatches a popup menu's shortcut while
---   its control has focus, so file keys do not fire while the caret is in
---   the editor and Delete keeps meaning "delete a character" there.
--- @return nil # No return value.
--
function Viewer:BuildMenus()
    local state = self.State
    local theme = self.Theme

    local popup = theme:CreatePopupMenu(state.List)
    if popup then
        popup.Add("New...", function() self:NewFile() end, "Ctrl+N")
        popup.Add("Add...", function() self:Add() end, "Ctrl+O")
        popup.Add("-")
        popup.Add("Rename", function() self:Rename() end, "F2")
        popup.Add("Duplicate", function() self:Duplicate() end, "Ctrl+D")
        popup.Add("Copy Name", function() self:CopyName() end)
        popup.Add("-")
        popup.Add("Export...", function() self:Export() end, "Ctrl+E")
        popup.Add("Remove", function() self:Delete() end, "Del")
        popup.Add("-")
        popup.Add("Refresh", function() self:Refresh() end, "F5")
        state.Popup = popup
    end

    -- One menu shared by the three editors; the first owns it, the others
    -- borrow it.
    local firstSlot = self.Editor.Slots.lua or self.Editor.Slots.asm or self.Editor.Slots.text
    local editorMenu = firstSlot and theme:CreatePopupMenu(firstSlot.Control) or nil
    if editorMenu then
        editorMenu.Add("Undo", function() self.Editor:Undo() end, "Ctrl+Z")
        editorMenu.Add("Redo", function() self.Editor:Redo() end, "Ctrl+Y")
        editorMenu.Add("-")
        editorMenu.Add("Cut", function() self.Editor:Cut() end, "Ctrl+X")
        editorMenu.Add("Copy", function() self.Editor:Copy() end, "Ctrl+C")
        editorMenu.Add("Paste", function() self.Editor:Paste() end, "Ctrl+V")
        editorMenu.Add("Select All", function() self.Editor:SelectAll() end, "Ctrl+A")
        editorMenu.Add("-")
        editorMenu.Add("Find...", function() self:FindInEditor() end, "Ctrl+F")
        editorMenu.Add("Replace...", function() self:ReplaceInEditor() end, "Ctrl+H")
        editorMenu.Add("Go to Line...", function() self:GotoLine() end, "Ctrl+G")
        editorMenu.Add("-")
        editorMenu.Add("Save", function() self:Save() end, "Ctrl+S")
        -- Asked just before the menu appears, so what it offers matches what
        -- the editor could actually do at that moment. CanUndo, CanRedo and
        -- CanPaste are properties Cheat Engine does expose.
        pcall(function()
            editorMenu.Menu.OnPopup = function() self:UpdateEditorMenu() end
        end)
        for _, slot in pairs(self.Editor.Slots) do
            editorMenu.Attach(slot.Control)
        end
        state.EditorPopup = editorMenu
    end

    self:BindKeys()
end

--
--- ∑ The window's keyboard shortcuts.
---
---   These have to be dispatched here. Lazarus only consults a form's main
---   menu in TCustomForm.IsShortcut; a PopupMenu's Shortcut is rendered next
---   to the caption but never fires, so a menu can advertise Ctrl+N and do
---   nothing. The Shortcut properties stay for display, and this is what
---   actually runs.
---
---   Which pane has focus decides what a key means, so nothing is taken away
---   from the editor: Del still deletes a character there, and the clipboard
---   and undo keys are left entirely to SynEdit, which handles them itself.
--- @return nil # No return value.
--
function Viewer:BindKeys()
    local state = self.State
    if not state or not state.Form then return end
    pcall(function()
        state.Form.KeyPreview = true
        state.Form.OnKeyDown = function(_, key)
            self:HandleKey(key)
            return key
        end
    end)
end

--- Virtual key codes. Named because 113 in a condition means nothing.
local VK_CONTROL, VK_DELETE, VK_ESCAPE, VK_F2, VK_F5 = 0x11, 0x2E, 0x1B, 0x71, 0x74
local VK_D, VK_E, VK_F, VK_G, VK_H, VK_N, VK_O, VK_S = 0x44, 0x45, 0x46, 0x47, 0x48, 0x4E, 0x4F, 0x53

function Viewer:CtrlDown()
    if type(isKeyPressed) ~= "function" then return false end
    local ok, down = pcall(isKeyPressed, VK_CONTROL)
    return ok and down == true
end

--
--- ∑ Runs one shortcut.
--- @param key number # The virtual key code.
--- @return boolean # Whether it was acted on.
--
function Viewer:HandleKey(key)
    local state = self.State
    if not state then return false end
    local ctrl = self:CtrlDown()
    local focus = state.Focus or "list"

    -- Anywhere in the window.
    if ctrl and key == VK_S then self:Save() return true end
    if key == VK_F5 then self:Refresh() return true end

    if focus == "editor" then
        -- Only what SynEdit does not already own. Undo, redo, cut, copy,
        -- paste and select-all are its own and are left alone.
        if ctrl and key == VK_F then self:FindInEditor() return true end
        if ctrl and key == VK_H then self:ReplaceInEditor() return true end
        if ctrl and key == VK_G then self:GotoLine() return true end
        return false
    end

    -- The file list.
    if key == VK_F2 then self:Rename() return true end
    if key == VK_DELETE then self:Delete() return true end
    if key == VK_ESCAPE then pcall(function() state.Form.close() end) return true end
    if ctrl then
        if key == VK_N then self:NewFile() return true end
        if key == VK_O then self:Add() return true end
        if key == VK_D then self:Duplicate() return true end
        if key == VK_E then self:Export() return true end
    end
    return false
end

--
--- ∑ Greys the editor menu entries that would do nothing.
--- @return nil # No return value.
--
function Viewer:UpdateEditorMenu()
    local state = self.State
    if not state or not state.EditorPopup or not self.Editor then return end
    local menu = state.EditorPopup
    local open = self.Editor:ActiveName() ~= nil
    menu.Enable("Undo", open and self.Editor:Can("CanUndo"))
    menu.Enable("Redo", open and self.Editor:Can("CanRedo"))
    menu.Enable("Paste", open and self.Editor:Can("CanPaste"))
    for _, caption in ipairs({ "Cut", "Copy", "Select All",
                              "Find...", "Replace...", "Go to Line..." }) do
        menu.Enable(caption, open)
    end
    menu.Enable("Save", self.Editor:IsDirty())
end

--- Double-clicking a row opens it, which is the one thing a double click
--- should do here.
function Viewer:ActivateSelected()
    local selected = self:SelectedNames()
    if #selected ~= 1 then return end
    if selected[1] == self.Editor:ActiveName() then return end
    if not self:ResolveDirtyBuffer("opening '" .. selected[1] .. "'") then return end
    self:OpenFile(selected[1])
end

--
--- ∑ Sorts by a clicked column header, flipping the direction when the same
---   column is clicked again.
--- @param column table # The clicked TListColumn.
--- @return nil # No return value.
--
function Viewer:SortByColumn(column)
    local state = self.State
    if not state then return end
    local index
    pcall(function() index = tonumber(column.Index) end)
    local key = ({ [0] = "Name", [1] = "Type", [2] = "Size" })[index or 0] or "Name"
    if state.Sort.Key == key then
        state.Sort.Ascending = not state.Sort.Ascending
    else
        state.Sort.Key, state.Sort.Ascending = key, true
    end
    self:ApplyView()
    self:RenderList()
end

--
--- ∑ Opens the window, or brings the open one forward.
--- @return nil # No return value.
--
function Viewer:Open()
    local run = self.RunInMainThread
    local function build()
        if self:IsOpen() then
            pcall(function() self.State.Form.show() end)
            pcall(function() self.State.Form.bringToFront() end)
            return
        end
        local form = self:Build()
        pcall(function() form.show() end)
    end
    if type(run) == "function" then run(build) else build() end
end

return Viewer
