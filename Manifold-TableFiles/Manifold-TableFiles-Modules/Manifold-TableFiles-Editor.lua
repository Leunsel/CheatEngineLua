--[[
    The editor: the controls, the active buffer, and the dirty flag.

    Split out of the viewer because these three belong together and nothing
    else should touch them. The viewer asks this module what the buffer holds
    and whether it changed; it never reads a SynEdit itself.

    Three editors exist because createSynEdit fixes its highlighter when the
    control is built (mode 0 Lua, mode 1 Auto Assembler), so one control
    cannot switch languages. A fourth slot is a plain panel used for the empty
    and binary states. All four fill the same host, one visible at a time.

    What Cheat Engine actually exposes on a SynEdit, from the CE 7.5 Lua API:

        properties  Lines Gutter ReadOnly SelStart SelEnd SelText
                    CanPaste CanRedo CanUndo CharWidth LineHeight
        methods     CopyToClipboard CutToClipboard PasteFromClipboard
                    Undo Redo ClearUndo MarkTextAsSaved
                    ClearSelection SelectAll

    Notably absent: SearchReplace, CaretX/CaretY and GotoLineAndCenter. Find,
    Replace, Go to line and the Ln/Col readout are therefore built on Lines
    plus SelStart/SelEnd, which are documented, rather than on methods that
    are not there. Nothing here pretends to offer a command it cannot run.

    The one genuinely uncertain part is how SynEdit counts a line break when
    it converts a character index into a caret position: Lazarus versions
    differ between one and two characters. Rather than guess, the first
    selection calibrates it by selecting a known string and reading SelText
    back. If neither length reproduces the expected text the feature reports
    failure instead of moving the caret somewhere wrong.
]]

local Editor = {}
Editor.__index = Editor

function Editor:New(services)
    services = services or {}
    return setmetatable({
        Theme = services.Theme,
        Types = services.Types,
        Log = services.Log,
        OnDirtyChanged = nil,
        OnCaretMoved = nil,
        Slots = {},
        Host = nil,
        Empty = nil,
        ActiveSlot = nil,
        Name = nil,
        Info = nil,
        Dirty = false,
        Loading = false,
        LineBreak = nil
    }, Editor)
end

-- Construction ----------------------------------------------------------------

--
--- ∑ Builds the editors into a host panel.
--- @param host table # The panel they fill.
--- @return nil # No return value.
--
function Editor:Build(host)
    local theme = self.Theme
    self.Host = host
    for key, mode in pairs({ lua = 0, asm = 1, text = false }) do
        local control, getText, setText = theme:CreateCodeView(
            host, mode ~= false and mode or nil,
            { ReadOnly = false, Visible = false })
        pcall(function()
            control.OnChange = function() self:MarkDirty() end
        end)
        -- No caret event is exposed, so the readout is refreshed on the two
        -- things that move it and are reachable: typing and clicking.
        pcall(function()
            control.OnKeyUp = function() self:CaretMoved() end
            control.OnClick = function() self:CaretMoved() end
        end)
        self.Slots[key] = { Control = control, Get = getText, Set = setText }
    end
    self.Empty = theme:CreateEmptyState(host)
    self:ShowEmpty("No file selected", "Select a table file to view or edit it.")
end

--
--- ∑ Shows exactly one slot and hides the others.
--- @param key string|nil # "lua", "asm", "text", or nil for the empty state.
--- @return table|nil # The slot, or nil for the empty state.
--
function Editor:ShowSlot(key)
    for name, slot in pairs(self.Slots) do
        pcall(function() slot.Control.Visible = (name == key) end)
    end
    pcall(function() self.Empty.Panel.Visible = (key == nil) end)
    self.ActiveSlot = key and self.Slots[key] or nil
    return self.ActiveSlot
end

--
--- ∑ Shows the message panel instead of an editor.
--- @param title string # The headline.
--- @param hint string|nil # A quieter second line.
--- @return nil # No return value.
--
function Editor:ShowEmpty(title, hint)
    self:ShowSlot(nil)
    if self.Empty then self.Empty.Set(title, hint) end
end

-- The buffer ------------------------------------------------------------------

--
--- ∑ Puts a file in the editor.
---   Setting the text fires OnChange, which is not an edit, so the dirty flag
---   is held down for the duration.
--- @param info table # The file's info record.
--- @param text string # Its contents.
--- @return nil # No return value.
--
function Editor:Load(info, text)
    local key = self.Types.EditorKeyFor(info.Type)
    local slot = self:ShowSlot(key)
    self.Loading = true
    pcall(function() slot.Set(text) end)
    -- A freshly loaded buffer is the saved state, so undo must not be able to
    -- step behind it into the previous file's contents.
    pcall(function() slot.Control.ClearUndo() end)
    pcall(function() slot.Control.MarkTextAsSaved() end)
    self.Loading = false
    self.Name = info.Name
    self.Info = info
    self.LineBreak = nil
    self:SetDirty(false)
    self:CaretMoved()
end

--
--- ∑ Shows a file that cannot be edited as text.
---   The bytes are never loaded into an editor, because a control that
---   normalises what it is given would write back something other than what
---   was read.
--- @param info table # The file's info record.
--- @return nil # No return value.
--
function Editor:LoadUneditable(info, reason)
    self.Name = nil
    self.Info = info
    self:SetDirty(false)
    self:ShowEmpty(info.Name, reason)
end

--
--- ∑ Empties the editor.
--- @param title string|nil # Optional headline for the empty state.
--- @param hint string|nil # Optional second line.
--- @return nil # No return value.
--
function Editor:Clear(title, hint)
    self.Name = nil
    self.Info = nil
    self:SetDirty(false)
    self:ShowEmpty(title or "No file selected", hint or "Select a table file to view or edit it.")
end

--- The text currently in the editor, or nil when nothing is open.
function Editor:Text()
    if not self.ActiveSlot then return nil end
    local ok, text = pcall(self.ActiveSlot.Get)
    if not ok then return nil end
    return text
end

--- The name of the file in the editor, or nil.
function Editor:ActiveName() return self.Name end

function Editor:IsDirty() return self.Dirty == true end

function Editor:SetDirty(value)
    local wanted = value == true
    if self.Dirty == wanted then return end
    self.Dirty = wanted
    if type(self.OnDirtyChanged) == "function" then self.OnDirtyChanged(wanted) end
end

function Editor:MarkDirty()
    if self.Loading or not self.Name then return end
    self:SetDirty(true)
end

--- Called after a successful save: the buffer becomes the stored state.
function Editor:MarkSaved()
    self:SetDirty(false)
    if self.ActiveSlot then
        pcall(function() self.ActiveSlot.Control.MarkTextAsSaved() end)
    end
end

function Editor:CaretMoved()
    if type(self.OnCaretMoved) == "function" then self.OnCaretMoved() end
end

--- Puts the keyboard back in the editor, e.g. after a dialog.
function Editor:Focus()
    if not self.ActiveSlot then return end
    pcall(function() self.ActiveSlot.Control.setFocus() end)
end

-- Clipboard and undo ----------------------------------------------------------

--
--- ∑ Runs one of the SynEdit methods Cheat Engine exposes on the active
---   editor. Anything not open, or any method this build lacks, is a no-op
---   rather than an error.
--- @param method string # The method name.
--- @return boolean # Whether it ran.
--
function Editor:Command(method)
    if not self.ActiveSlot then return false end
    local control = self.ActiveSlot.Control
    local ok = pcall(function()
        local fn = control[method]
        if type(fn) ~= "function" then error("unavailable", 0) end
        fn()
    end)
    return ok
end

function Editor:Undo() return self:Command("Undo") end
function Editor:Redo() return self:Command("Redo") end
function Editor:Cut() return self:Command("CutToClipboard") end
function Editor:Copy() return self:Command("CopyToClipboard") end
function Editor:Paste() return self:Command("PasteFromClipboard") end
function Editor:SelectAll() return self:Command("SelectAll") end

--- Whether a command is currently meaningful. Used to grey context menu
--- entries rather than offering something that would do nothing.
function Editor:Can(what)
    if not self.ActiveSlot then return false end
    local ok, value = pcall(function() return self.ActiveSlot.Control[what] end)
    if not ok then return false end
    return value == true
end

-- Positions -------------------------------------------------------------------

--- The editor's lines as a plain array, so offsets can be computed without
--- guessing how the control joins them.
function Editor:Lines()
    local lines = {}
    local text = self:Text()
    if not text then return lines end
    -- gmatch with a greedy-free pattern keeps a trailing empty line.
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        lines[#lines + 1] = line
    end
    return lines
end

--
--- ∑ The character offset SynEdit wants for a given line and column, for a
---   given assumption about how long a line break is.
--- @param lines table # The lines.
--- @param lineNumber number # 1-based.
--- @param column number # 1-based.
--- @param breakLength number # 1 or 2.
--- @return number # A 1-based character index.
--
local function offsetOf(lines, lineNumber, column, breakLength)
    local offset = 1
    for index = 1, math.min(lineNumber, #lines + 1) - 1 do
        offset = offset + #(lines[index] or "") + breakLength
    end
    return offset + (column - 1)
end

--
--- ∑ Selects a range, working out how this SynEdit counts line breaks the
---   first time it is asked.
---   Lazarus versions disagree on whether a break is one character or two,
---   and there is no property to ask. So both are tried and the one whose
---   SelText matches the text that should be there is remembered. If neither
---   does, nothing is selected and the caller is told.
--- @param lineNumber number # 1-based line.
--- @param column number # 1-based column.
--- @param expected string # The text that should end up selected.
--- @return boolean # Whether the selection landed on the expected text.
--
function Editor:SelectAt(lineNumber, column, expected)
    if not self.ActiveSlot then return false end
    local control = self.ActiveSlot.Control
    local lines = self:Lines()
    local candidates = self.LineBreak and { self.LineBreak } or { 2, 1 }
    for _, breakLength in ipairs(candidates) do
        local offset = offsetOf(lines, lineNumber, column, breakLength)
        local ok = pcall(function()
            control.SelStart = offset
            control.SelEnd = offset + #expected
        end)
        if ok then
            local matched, selected = pcall(function() return control.SelText end)
            if matched and selected == expected then
                self.LineBreak = breakLength
                return true
            end
            -- An empty expectation cannot be verified this way; accept the
            -- first assumption and let the caret land.
            if matched and expected == "" then
                return true
            end
        end
    end
    return false
end

--
--- ∑ Finds text and selects it.
--- @param needle string # What to look for.
--- @param options table|nil # MatchCase, Backwards, FromStart.
--- @return boolean, number|nil # Found, plus the line it is on.
--
function Editor:Find(needle, options)
    options = options or {}
    if type(needle) ~= "string" or needle == "" then return false end
    local lines = self:Lines()
    if #lines == 0 then return false end

    local startLine, startColumn = 1, 1
    if not options.FromStart then
        local line, column = self:CaretLineCol()
        startLine, startColumn = line or 1, (column or 1)
        -- Continue past the current selection so repeated finds advance.
        local selected = self.ActiveSlot and select(2, pcall(function()
            return self.ActiveSlot.Control.SelText
        end)) or nil
        if type(selected) == "string" and #selected > 0 then
            startColumn = startColumn + #selected
        end
    end

    local function search(haystack, from)
        if options.MatchCase then return haystack:find(needle, from, true) end
        return haystack:lower():find(needle:lower(), from, true)
    end

    -- Forwards from the caret, then wrapping around to the top.
    local order = {}
    for index = startLine, #lines do order[#order + 1] = index end
    for index = 1, startLine do order[#order + 1] = index end
    for position, lineNumber in ipairs(order) do
        local from = (position == 1) and startColumn or 1
        local found = search(lines[lineNumber], from)
        if found then
            self:SelectAt(lineNumber, found, lines[lineNumber]:sub(found, found + #needle - 1))
            return true, lineNumber
        end
    end
    return false
end

--
--- ∑ Replaces every occurrence, in one pass over the text.
---   Done on the string rather than by repeated find-and-select, so a
---   replacement containing the search text cannot loop.
--- @param needle string # What to replace.
--- @param replacement string # What with.
--- @param matchCase boolean|nil # Whether case matters.
--- @return number # How many were replaced.
--
function Editor:ReplaceAll(needle, replacement, matchCase)
    if not self.ActiveSlot or type(needle) ~= "string" or needle == "" then return 0 end
    local text = self:Text()
    if not text then return 0 end
    local pieces, count, position = {}, 0, 1
    local haystack = matchCase and text or text:lower()
    local wanted = matchCase and needle or needle:lower()
    while true do
        local from, to = haystack:find(wanted, position, true)
        if not from then break end
        pieces[#pieces + 1] = text:sub(position, from - 1)
        pieces[#pieces + 1] = replacement
        position = to + 1
        count = count + 1
    end
    if count == 0 then return 0 end
    pieces[#pieces + 1] = text:sub(position)
    self.ActiveSlot.Set(table.concat(pieces))
    self:MarkDirty()
    return count
end

--
--- ∑ Moves the caret to the start of a line.
--- @param lineNumber number # 1-based.
--- @return boolean # Whether the line exists and the caret moved.
--
function Editor:GotoLine(lineNumber)
    lineNumber = tonumber(lineNumber)
    local lines = self:Lines()
    if not lineNumber or lineNumber < 1 or lineNumber > #lines then return false end
    -- Selecting the line's text is what lets SelectAt verify it landed right.
    local target = lines[lineNumber]
    if target == "" then
        -- Nothing to verify against, so aim at a neighbour first to calibrate.
        for probe = 1, #lines do
            if lines[probe] ~= "" then
                self:SelectAt(probe, 1, lines[probe])
                break
            end
        end
    end
    local ok = self:SelectAt(lineNumber, 1, target)
    if ok then
        pcall(function() self.ActiveSlot.Control.SelEnd = self.ActiveSlot.Control.SelStart end)
        self:CaretMoved()
    end
    return ok
end

--
--- ∑ Where the caret is, derived from SelStart because no caret property is
---   exposed. Uses whichever line break length has been calibrated; before
---   any selection has happened it assumes two, which is right on Windows.
--- @return number|nil, number|nil # Line and column, both 1-based.
--
function Editor:CaretLineCol()
    if not self.ActiveSlot then return nil end
    local ok, selStart = pcall(function() return self.ActiveSlot.Control.SelStart end)
    if not ok or type(selStart) ~= "number" then return nil end
    local breakLength = self.LineBreak or 2
    local lines = self:Lines()
    local offset = 1
    for index = 1, #lines do
        local lineLength = #lines[index]
        if selStart <= offset + lineLength then
            return index, selStart - offset + 1
        end
        offset = offset + lineLength + breakLength
    end
    return math.max(#lines, 1), 1
end

return Editor
