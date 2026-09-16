--[[
    The drop-down page, which is the list of choices a record offers instead of
    a bare number.

    A drop-down list is one string list on the record. One line is one entry, a
    value, then a colon, then the description shown in its place. Cheat Engine
    splits at the FIRST colon and a line without one becomes an entry whose
    description is empty, which reads in the address list as a value that lost
    its name. Nothing warns about it, so this page parses the text the same way
    Cheat Engine does, previews what came out and flags every line that has no
    colon in it.

    Four flags sit around the list and three of them cannot be read honestly
    while the record is linked. Cheat Engine's getters for Read only,
    Description only and Show as list item follow the link and hand back the
    LINKED record's values, so what a check box would show is not this record's
    own state at all. Writing one of those back would then copy another
    record's setting into this one. So while a record is linked the list box
    and those three checks show what Cheat Engine really uses, the list and the
    flags at the end of the link, read only, the page says where they come
    from, and the only things it will write are the link itself and the
    description it points at. The list box says it at every size, because on a
    short page the preview under it is the first thing to go.

    Unticking Linked is the way back, which is why that one check stays live.
    It hands the list box and the three checks over at once, before anything
    is applied. The box shows the record's own list to edit, the checks keep
    what they showed and can be changed, and Apply unlinks the record. Cheat
    Engine hides a linked record's own flags and nothing can read them, so
    Apply writes the three flags as they are ticked, which is the only way
    the record ends up with the flags the page showed. Ticking Linked again
    puts the linked list back in the box, and Revert puts back what was read.

    The linked record is named by its DESCRIPTION and not by an id, because
    that is what Cheat Engine stores. A description that names nothing is a
    dead link, so Go to linked record says so rather than moving the selection
    somewhere wrong.

    While a record is linked its own list is kept but never used, so the list
    box and the preview show the list Cheat Engine really takes the entries
    from and the preview says whose it is. Cheat Engine's count, value and
    description getters look the name up in the address list's description
    lookup and ask that record, which follows a link of its own in turn. A name
    that finds nothing gives no entries at all, and so does a link that comes
    back round to a record it already passed. The list object itself does not
    follow the link, which is why the page walks the link with Cheat Engine's
    own lookup rather than reading the list of the record it shows. A link that
    was typed and not applied yet is previewed the same way, as what Apply
    would make of it.

    Any record can carry a list, a group header as much as a value. A header's
    own Value reads empty, but the list on it is real, and a header that holds
    one is a common place for other records to link theirs to. So this
    page edits a header like any other record, and the linked record may name
    one. The only records it leaves out are the ones that went away since the
    last walk, because there is nothing left to read on those.

    The page never writes to a record. Apply builds one dropdown change per
    record and hands it up, carrying only the fields the person really changed
    and, for a record it unlinks, the three flags the checks show. So a bulk
    apply over records whose flags differ leaves the flags nobody touched
    alone.

    Top to bottom the page reads the notes, the four flags one per line, the
    linked record with its Go to button, the list itself, the preview and the
    Apply bar. The notes wrap to the page's width and take exactly the height
    their lines need, and the line that says how to write a list says nothing
    and takes no room while the list cannot be typed into. Everything above the
    list is stacked by a Top far apart per slot, because the LCL orders top
    aligned controls by their Top and a tie goes to whichever control was
    touched last. The preview and the Apply bar share one panel along the
    bottom, because two bottom aligned panels are ordered by their lower edges
    and the taller one ends up underneath, which is how Apply came to sit above
    the preview. When the page is too short for the preview it gives its room
    to the list.

    The list text only ever shows whole lines. A multi line edit draws a line
    that does not fit cut through the middle, so the box is made a whole
    number of lines high and the few pixels left over go under it, inside its
    frame. The count is taken from the box's client height, which is what is
    left once Windows has taken its scroll bars.
]]

local SurfaceModule = require("Manifold-AddressList-Surface")
local InspectorModule = require("Manifold-AddressList-Inspector")

local DropDown = {}
DropDown.__index = DropDown

--- The tab this page lives behind, so the inspector and the window name it the
--- same way without either of them spelling it out twice.
DropDown.Key = "DropDown"
DropDown.Caption = "Drop-down"

--- The muted line the page shows at the top while the list can be typed
--- into, so a person who has never seen a drop-down list knows what a line
--- looks like. It says nothing while the record is linked.
DropDown.Hint = "One entry per line, as value:description."

--- What the page says while the record takes its list from another record.
--- The name of that record goes in at the end, then ShownNote, then OwnNote.
DropDown.LinkedNote =
    "Linked. Cheat Engine uses the list and the first three flags of "
DropDown.ShownNote = ", shown here read only."

--- The way back to the record's own list, said after every linked note. The
--- second one is for several records at once.
DropDown.OwnNote = "Untick Linked to edit this record's own list and flags."
DropDown.OwnNoteMany = "Untick Linked to edit the records' own lists and flags."

--- What the page says once Linked was unticked and before Apply, for one
--- record and for several.
DropDown.UnlinkNote = "Apply unlinks this record. It then uses the list below, and the three "
    .. "flags are written as ticked here, because Cheat Engine hides a linked record's own."
DropDown.UnlinkNoteMany = "Apply unlinks these records. They then use the list below, and the three "
    .. "flags are written as ticked here, because Cheat Engine hides a linked record's own."

--- The flag fields whose getters follow the link. They are read only while the
--- record is linked, because the value that comes back belongs to the linked
--- record and writing it back would copy it into this one.
DropDown.Followed = { ReadOnly = true, DescriptionOnly = true, DisplayAsItem = true }

--- Every field the page carries, in the order Apply writes them. Text first
--- and the link last, which is the order Properties writes them in as well.
DropDown.Fields = {
    "Text", "ReadOnly", "DescriptionOnly", "DisplayAsItem", "LinkedMemrec", "Linked"
}

--- What the linked record box says while it is empty, longest first. The page
--- shows the longest one its box holds, because a placeholder cut through a
--- letter reads as a broken control.
DropDown.LinkPlaceholders = {
    "another record's description",
    "a record's description",
    "description"
}

--- The four checks, in the order they are read top to bottom.
DropDown.Flags = {
    { Key = "ReadOnly", Caption = "Read only",
      Hint = "The value can only be picked from the list, not typed." },
    { Key = "DescriptionOnly", Caption = "Description only",
      Hint = "Show the description of the matching entry instead of the value." },
    { Key = "DisplayAsItem", Caption = "Show as list item",
      Hint = "Show this record in Cheat Engine as an item of its drop-down list." },
    { Key = "Linked", Caption = "Linked",
      Hint = "Take the list and the flags from another record, named by its description." }
}

--- What one preview row says about a line Cheat Engine cannot split.
local NO_COLON = "no colon, the whole line becomes the value"
local EMPTY_LINE = "an empty line, Cheat Engine keeps it as an empty entry"

--- How tall the preview canvas is at most. Six rows and its own header, which
--- is enough to see a short list whole without taking the memo's room.
local PREVIEW_HEIGHT = 150

--- The least the preview canvas is worth showing at, and the least the list
--- keeps before the preview gives way.
local PREVIEW_MIN, MEMO_MIN = 56, 60

--- The line over the preview canvas, and the space above and before it.
local PREVIEW_LABEL_HEIGHT, PREVIEW_LABEL_TOP = 15, 4

--- How far apart the stacked controls are given their Top, so no two of them
--- can ever tie.
local STACK_STEP = 10000

--- How many links the preview follows before it calls the chain a loop.
--- Cheat Engine has no such number and finds a loop by walking it, which a
--- chain this long can only be.
local LINK_DEPTH = 32

--- The space every row, list and bar keeps from the page's left and right
--- sides, which is where the field row labels start, and the space over and
--- under a note. The notes, the checks, the frames, the preview and the
--- buttons all start and end on these two edges.
local LEFT_PAD, NOTE_TOP, NOTE_GAP = 6, 2, 4

--- The height of one flag's line, and the few pixels a drawn check keeps in
--- front of its box. A check stands that much before the page edge, so its
--- box stands on the edge.
local FLAG_HEIGHT, CHECK_LEAD = 22, 2

--- The height of the linked record row. Go to is given the same height, so
--- its edges line up with the frame beside it.
local FIELD_HEIGHT = 28

--- What a single line edit keeps clear of its text on either side, which a
--- placeholder has to fit inside of as well, and the width of one character
--- when the theme cannot say, which is Consolas at the family size.
local EDIT_MARGIN, DEFAULT_CHAR = 2, 7

--- The space round the list's frame, and inside it round the text.
local MEMO_GAP, MEMO_INSET = 2, 4

--- The height of one line of list text when the theme cannot say, which is
--- Consolas at the family size.
local MEMO_LINE = 15

--- The line number column of the preview. Four digits, then two blank
--- characters before the value, because the list keeps less than a character
--- between two columns and a number running into a value reads as one number.
local LINE_DIGITS, LINE_GAP = 4, 2

--- How far a read only frame leans from the page towards the border colour.
local FRAME_READONLY = 0.45

--- A button's height on the Apply bar, the space between two buttons, the
--- space over and under the bar's lines and the space at its two ends, the
--- width of Apply and Revert, and that of the Go to button. The ends are the
--- page's own edge, so Apply ends where the frames above it end.
local BUTTON_HEIGHT, BAR_GAP, BAR_PAD, BAR_EDGE = 26, 6, 5, LEFT_PAD
local BUTTON_WIDTH, GOTO_WIDTH = 64, 64

--------------------------------------------------------
--                   Small helpers                    --
--------------------------------------------------------

--- One guarded property write. A control that is gone and a property this
--- build does not have both come back as false rather than as a raise.
local function safeSet(control, key, value)
    if control == nil then return false end
    return (pcall(function() control[key] = value end))
end

--- One line ending and no trailing blank line. A string list reads its text
--- back with a break after the last line, and the memo and the record both go
--- through one of those, so everything is compared in this shape.
local function normalise(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("\r\n", "\n"):gsub("\n+$", ""))
end

--- Writes a text property only when it really changes. Rewriting the text a
--- person is typing into would put their caret back at the start of it, and a
--- live sync reaches this on every tick.
local function setText(control, value)
    if control == nil then return false end
    local ok, held = pcall(function() return control.Text end)
    if ok and held == value then return true end
    return (pcall(function() control.Text = value end))
end

--- The text of a memo, written only when it really differs. A memo reads its
--- lines back with a line break after the last one, so the two are compared
--- without it.
local function setLines(memo, value)
    if memo == nil then return false end
    local ok, held = pcall(function() return memo.Lines.Text end)
    if ok and normalise(held) == value then return true end
    return (pcall(function() memo.Lines.Text = value end))
end

--- One guarded property read, for the controls this page made itself.
local function safeGet(control, key)
    if control == nil then return nil end
    local ok, value = pcall(function() return control[key] end)
    if not ok then return nil end
    return value
end

--- Sends one line to the log channel when there is one.
local function say(self, level, message)
    local sink = self and self.Log
    if sink == nil then return end
    local method = sink[level]
    if type(method) ~= "function" then return end
    pcall(method, sink, message)
end

--- One property read as a number, or nil when it cannot be read.
local function readNumber(control, key)
    local value = tonumber(safeGet(control, key))
    return value
end

--- The width a control lays its children out in, or nil while it has none.
local function innerWidth(control)
    local width = readNumber(control, "ClientWidth")
    if width == nil or width <= 0 then width = readNumber(control, "Width") end
    if width == nil or width <= 0 then return nil end
    return width
end

--- The same for the height.
local function innerHeight(control)
    local height = readNumber(control, "ClientHeight")
    if height == nil or height <= 0 then height = readNumber(control, "Height") end
    if height == nil or height <= 0 then return nil end
    return height
end

--- The height of one line of the segment font, the family's when the theme
--- cannot say.
local function lineHeightOf(theme)
    if theme ~= nil and type(theme.TextMetrics) == "function" then
        local ok, _, measured = pcall(theme.TextMetrics, theme)
        measured = ok and tonumber(measured) or nil
        if measured ~= nil and measured > 0 then return measured end
    end
    return MEMO_LINE
end

--- Whether a control is meant to be on screen. One that cannot say counts as
--- shown.
local function isShown(control)
    local ok, value = pcall(function() return control.Visible end)
    return not ok or value ~= false
end

--- Gives a top aligned control its place in the stack. Slot one is the
--- topmost.
local function stackAt(control, slot)
    safeSet(control, "Top", slot * STACK_STEP)
    return control
end

--- The space one aligned control takes along the stack, its height and the
--- space above and below it.
local function stackHeight(control)
    if control == nil or not isShown(control) then return 0 end
    local height = readNumber(control, "Height") or 0
    local ok, above, below = pcall(function()
        local spacing = control.BorderSpacing
        local around = tonumber(spacing.Around) or 0
        return (tonumber(spacing.Top) or 0) + around, (tonumber(spacing.Bottom) or 0) + around
    end)
    if not ok then above, below = 0, 0 end
    return height + above + below
end

--- The right hand buttons of the Apply bar, broken into lines no wider than
--- width. One line on anything but a very narrow page.
local function buttonLines(buttons, width)
    local lines, line, used = {}, {}, 0
    for _, control in ipairs(buttons) do
        if isShown(control) then
            local each = readNumber(control, "Width") or 0
            if #line > 0 and used + BAR_GAP + each > width then
                lines[#lines + 1] = { Controls = line, Span = used }
                line, used = {}, 0
            end
            used = #line > 0 and (used + BAR_GAP + each) or each
            line[#line + 1] = control
        end
    end
    if #line > 0 then lines[#lines + 1] = { Controls = line, Span = used } end
    return lines
end

--- Calls one of the window's hooks without letting a defect in it reach the
--- control that fired.
local function fire(handler, ...)
    if type(handler) ~= "function" then return nil end
    local ok, first, second, third = pcall(handler, ...)
    if not ok then return nil end
    return first, second, third
end

--- A record description with quotes around it, for a sentence a person reads.
local function quoted(text)
    return "'" .. tostring(text or "") .. "'"
end

--- How many characters a text is, counting a multi byte character once.
local function textLength(text)
    text = tostring(text or "")
    local lib = rawget(_G, "utf8")
    if type(lib) == "table" and type(lib.len) == "function" then
        local count = lib.len(text)
        if count then return count end
    end
    return #text
end

--- The blank state of the page, so a page with nothing to show still has every
--- field to compare against.
local function blank()
    return {
        Text = "", ReadOnly = false, DescriptionOnly = false,
        DisplayAsItem = false, Linked = false, LinkedMemrec = ""
    }
end

local function copy(state)
    local out = blank()
    for _, key in ipairs(DropDown.Fields) do
        if state[key] ~= nil then out[key] = state[key] end
    end
    return out
end

--------------------------------------------------------
--                      Parsing                       --
--------------------------------------------------------

--
--- ∑ Splits the list text the way Cheat Engine splits it, at the first colon
---   of each line, and says which lines it could not split.
---
---   This is a pure function so the preview and the tests read the same
---   parser. Cheat Engine keeps an empty line as an entry of its own, so an
---   empty line is reported rather than dropped.
--- @param text string|nil
--- @return table # One entry per line of Line, Raw, Value, Description, Note.
--- @return number # How many lines carry no colon.
--
function DropDown.Parse(text)
    local entries, flagged = {}, 0
    if type(text) ~= "string" or text == "" then return entries, 0 end
    local normalised = normalise(text)
    local line = 0
    for raw in (normalised .. "\n"):gmatch("(.-)\n") do
        line = line + 1
        local value, description = raw:match("^(.-):(.*)$")
        local entry = {
            Line = line, Raw = raw, Value = value or raw,
            Description = description or "", Note = nil
        }
        if value == nil then
            flagged = flagged + 1
            entry.Note = raw == "" and EMPTY_LINE or NO_COLON
        end
        entries[line] = entry
    end
    return entries, flagged
end

--
--- ∑ The one line under the preview header, which says how much came out of
---   the text and how much of it Cheat Engine cannot use.
--- @param entries table
--- @param flagged number
--- @return string
--
function DropDown.Summary(entries, flagged)
    local count = type(entries) == "table" and #entries or 0
    flagged = tonumber(flagged) or 0
    if count == 0 then return "No entries" end
    local text = count == 1 and "1 entry" or (count .. " entries")
    if flagged > 0 then
        text = text .. ", " .. flagged .. (flagged == 1 and " line" or " lines") .. " without a colon"
    end
    return text
end

--------------------------------------------------------
--                    Construction                    --
--------------------------------------------------------

--
--- ∑ Builds the page. Nothing is created until Build, so the inspector can
---   hold one before its card exists.
--- @param services table|nil # Theme, Surface, Frame, Grid, Properties, Types,
---        Records, CE, Log and Settings.
--- @return table
--
function DropDown:New(services)
    services = services or {}
    return setmetatable({
        Theme = services.Theme,
        SurfaceClass = services.Surface or SurfaceModule,
        Frame = services.Frame,
        Grid = services.Grid,
        Properties = services.Properties,
        Types = services.Types,
        Records = services.Records,
        CE = services.CE,
        Log = services.Log,
        Settings = services.Settings,

        Parent = nil,
        Panel = nil,
        Body = nil,
        Empty = nil,          -- the empty state, from Theme
        Memo = nil,
        MemoFrame = nil,      -- the border round the list text
        MemoFill = nil,       -- the input coloured panel inside that border
        NoteLabel = nil,
        NoteText = "",        -- what the note says, whole
        HintLabel = nil,
        HintText = DropDown.Hint, -- what the line under the note says, empty while linked
        LinkRow = nil,        -- the field row that names the linked record
        LinkEdit = nil,
        LinkEnable = nil,     -- turns that row on and off, frame and all
        Footer = nil,         -- the preview and the Apply bar, along the bottom
        ActionBar = nil,
        PreviewPanel = nil,
        PreviewLabel = nil,
        PreviewSurface = nil,
        Preview = nil,        -- the list painter on that surface
        Checks = {},          -- key to { Panel, Row, Set, Get, Enable, Parts }
        Buttons = {},         -- key to { Control, Enable }
        Stack = {},           -- the controls above the list, top to bottom
        Laying = false,       -- a layout pass we started ourselves
        Built = false,

        IDs = {},             -- what the inspector last handed in
        Subject = {},         -- the ids this page can really edit
        Snapshot = nil,
        Baseline = blank(),   -- what the records held when they were read
        Buffer = blank(),     -- what the controls hold now
        MixedFlags = false,   -- the subject records do not agree on the flags
        Reason = nil,         -- why there is nothing to edit
        Loading = false,      -- a control change we caused ourselves
        ShowsLinked = false,  -- the list box and the three checks show the linked record
        Held = {},            -- id to what that record held when it was read
        Source = nil,         -- where the list in use comes from, see SourceOf
        Watched = {},         -- the ids the links pass through, as a set
        Saving = false,       -- Apply is waiting for the window's answer

        OnCommit = nil,
        OnAct = nil,
        OnStatus = nil,
        --- The inspector assigns these two. The hint goes to the strip at the
        --- bottom of the card, and the guard is the window's busy counter
        --- around anything modal.
        OnHint = nil,
        OnGuard = nil,
        --- The inspector assigns this one as well. The page calls it whenever
        --- its title may have changed, so the star in the header comes and
        --- goes with the edit and not with the next sync.
        OnTitleChanged = nil,
        --- The window may assign this to take the person to a record. Without
        --- it the page falls back to selecting the record in Cheat Engine.
        OnGoTo = nil
    }, DropDown)
end

--- Reports one sentence to the window's status line.
function DropDown:Status(text)
    fire(self.OnStatus, text)
    return text
end

--
--- ∑ Creates the controls inside the inspector's page panel.
---
---   The controls above the list are built in reading order and stacked by
---   slot. The bottom panel holds the preview and the Apply bar, and the list
---   takes what is left.
--- @param parent userdata
--- @return boolean
--
function DropDown:Build(parent)
    local theme = self.Theme
    if theme == nil or parent == nil then return false end
    self.Parent = parent
    local ok, err = pcall(function()
        self.Panel = theme:CreatePanel(parent, { Align = "alClient", ColorKey = "COLOR_INPUT" })
        self.Empty = theme:CreateEmptyState(self.Panel)
        self.Body = theme:CreatePanel(self.Panel, { Align = "alClient", ColorKey = "COLOR_INPUT" })

        self:BuildNotes(theme)
        self:BuildFlags(theme)
        self:BuildLinkRow(theme)
        self:BuildFooter(theme)
        self:BuildMemo(theme)
        safeSet(self.Body, "OnResize", function() self:Relayout() end)
    end)
    if not ok then
        say(self, "Warning", "The drop-down page could not be built whole, " .. tostring(err))
    end
    self.Built = true
    self:Fill()
    return ok
end

--- Hands every edit control's change to the same place, and ignores the ones
--- the page made itself.
function DropDown:Edited()
    if self.Loading then return end
    self:Capture()
    self:AfterEdit()
end

--- The two muted lines at the top, the note that only speaks while a record
--- is linked or the flags disagree, and the line that says what a list line
--- looks like, which only speaks while the list can be typed into.
function DropDown:BuildNotes(theme)
    self.NoteLabel = theme:CreateLabel(self.Body, "", "muted")
    safeSet(self.NoteLabel, "Align", "alTop")
    pcall(function()
        local spacing = self.NoteLabel.BorderSpacing
        spacing.Left, spacing.Right, spacing.Top = LEFT_PAD, LEFT_PAD, NOTE_TOP
    end)
    stackAt(self.NoteLabel, 1)
    InspectorModule.FitNote(theme, self.NoteLabel, "", nil)

    self.HintLabel = theme:CreateLabel(self.Body, DropDown.Hint, "muted")
    safeSet(self.HintLabel, "Align", "alTop")
    pcall(function()
        local spacing = self.HintLabel.BorderSpacing
        spacing.Left, spacing.Right, spacing.Top, spacing.Bottom = LEFT_PAD, LEFT_PAD, NOTE_TOP, NOTE_GAP
    end)
    stackAt(self.HintLabel, 2)
    InspectorModule.FitNote(theme, self.HintLabel, DropDown.Hint, nil)
    self.Stack = { self.NoteLabel, self.HintLabel }
end

--
--- ∑ The four checks, one per line.
---
---   Each check is as wide as its box and caption and sits at the left of a
---   line of its own, so a click in the empty rest of the line toggles
---   nothing.
--- @param theme table
--- @return nil
--
function DropDown:BuildFlags(theme)
    for index, flag in ipairs(DropDown.Flags) do
        local row = theme:CreatePanel(self.Body, {
            Align = "alTop", Height = FLAG_HEIGHT, ColorKey = "COLOR_INPUT"
        })
        stackAt(row, 2 + index)
        local panel, setChecked, getChecked, setEnabled, parts = theme:CreateCheck(row, {
            Caption = flag.Caption, Align = "alLeft",
            Height = FLAG_HEIGHT, Hint = flag.Hint, ColorKey = "COLOR_INPUT",
            Spacing = { Left = LEFT_PAD - CHECK_LEAD },
            OnChange = function() self:Edited() end
        })
        local check = {
            Panel = panel, Row = row, Set = setChecked, Get = getChecked,
            Parts = parts, Enabled = true
        }
        -- The drawn box keeps whether it is enabled to itself, so the page
        -- keeps its own copy for the tests and for anyone reading the page.
        check.Enable = function(value)
            check.Enabled = value ~= false
            setEnabled(check.Enabled)
        end
        self.Checks[flag.Key] = check
        self.Stack[#self.Stack + 1] = row
    end
end

--
--- ∑ The row that names the linked record, a field row with Go to beside it.
---
---   Go to is as high as the row, so its top and bottom edges carry on the
---   frame's. The row fits its placeholder whenever it changes size, which is
---   the only time the box beside Go to can change width.
--- @param theme table
--- @return nil
--
function DropDown:BuildLinkRow(theme)
    local row, edit, enable = theme:CreateFieldRow(self.Body, {
        Label = "Linked record",
        Height = FIELD_HEIGHT,
        Placeholder = DropDown.LinkPlaceholders[1],
        Hint = "The description of the record this one takes its list from. A group header can be one.",
        Spacing = { Top = 2, Bottom = 2, Right = LEFT_PAD },
        OnChange = function() self:Edited() end
    })
    stackAt(row, 3 + #DropDown.Flags)
    self.LinkRow, self.LinkEdit, self.LinkEnable = row, edit, enable
    local goTo, goEnable = theme:CreateButton(row, {
        Caption = "Go to", Align = "alRight", Width = GOTO_WIDTH, Height = FIELD_HEIGHT,
        Hint = "Select the record this one takes its list from.",
        Spacing = { Left = 6, Top = 0, Bottom = 0 },
        OnClick = function() self:GoToLinked() end
    })
    self.Buttons.GoTo = { Control = goTo, Enable = goEnable }
    self.Stack[#self.Stack + 1] = row
    safeSet(row, "OnResize", function() self:FitPlaceholder() end)
end

--
--- ∑ The longest placeholder a box of that width holds.
---
---   Consolas is monospaced, so a text is its length times one character wide.
---   A box too narrow for even the shortest one still gets the shortest,
---   because an empty box would say nothing at all. This needs no control,
---   so the tests can ask it with any measurement they like.
--- @param width number|nil # The box's client width in pixels. Without one the
---        longest placeholder is the answer.
--- @param charWidth number|nil # Pixels per character, seven when missing.
--- @return string
--
function DropDown.LinkPlaceholderFor(width, charWidth)
    local list = DropDown.LinkPlaceholders
    width = tonumber(width)
    if width == nil or width <= 0 then return list[1] end
    local each = tonumber(charWidth)
    if each == nil or each <= 0 then each = DEFAULT_CHAR end
    local room = width - 2 * EDIT_MARGIN
    for _, text in ipairs(list) do
        if textLength(text) * each <= room then return text end
    end
    return list[#list]
end

--
--- ∑ Gives the linked record box the longest placeholder its width holds,
---   measured with the theme's own character width.
--- @return string|nil # The placeholder it shows, or nil without a box.
--
function DropDown:FitPlaceholder()
    local edit = self.LinkEdit
    if edit == nil then return nil end
    local charWidth = nil
    local theme = self.Theme
    if theme ~= nil and type(theme.TextMetrics) == "function" then
        local ok, measured = pcall(theme.TextMetrics, theme)
        if ok then charWidth = tonumber(measured) end
    end
    local text = DropDown.LinkPlaceholderFor(innerWidth(edit), charWidth)
    if safeGet(edit, "TextHint") ~= text then safeSet(edit, "TextHint", text) end
    return text
end

--
--- ∑ The list text, in a frame of the border colour like every other input.
---
---   A memo in the input colour on a page in the input colour has no edge at
---   all, so the frame is what shows where the text goes. It leans quieter
---   while the record is linked, because the text cannot be typed into then.
--- @param theme table
--- @return nil
--
function DropDown:BuildMemo(theme)
    local frame = theme:CreatePanel(self.Body, {
        Align = "alClient", Color = theme:GetPalette().COLOR_BORDER,
        Spacing = { Left = LEFT_PAD, Right = LEFT_PAD, Top = MEMO_GAP, Bottom = MEMO_GAP }
    })
    self.MemoFrame = frame
    local fill = theme:CreatePanel(frame, {
        Align = "alClient", ColorKey = "COLOR_INPUT", Spacing = { Around = 1 }
    })
    self.MemoFill = fill
    self.Memo = theme:CreateMemo(fill, { Align = "alClient", ReadOnly = false })
    safeSet(self.Memo, "WordWrap", false)
    safeSet(self.Memo, "ScrollBars", "ssAutoBoth")
    pcall(function() self.Memo.BorderSpacing.Around = MEMO_INSET end)
    safeSet(self.Memo, "OnChange", function() self:Edited() end)
    safeSet(fill, "OnResize", function() self:FitMemo() end)
    theme:Track(function() self:PaintMemoFrame() end)
end

--
--- ∑ Makes the list text a whole number of lines high.
---
---   The box fills its frame less the inset, and what does not make a whole
---   line goes into the space under it. What the box gives to its own scroll
---   bars is the gap between its height and its client height, so the lines
---   are counted in what is really left for text. Only the box's own spacing
---   changes, never the size of anything around it, so the resize this causes
---   finds nothing more to do.
--- @return number|nil # How many lines the box shows, or nil while it has no size.
--
function DropDown:FitMemo()
    local fill, memo = self.MemoFill, self.Memo
    local height = innerHeight(fill)
    if memo == nil or height == nil then return nil end
    local line = lineHeightOf(self.Theme)
    local outer = readNumber(memo, "Height")
    local client = readNumber(memo, "ClientHeight")
    local chrome = 0
    if outer ~= nil and client ~= nil and client > 0 and outer > client then
        chrome = outer - client
    end
    local room = math.max(0, height - 2 * MEMO_INSET - chrome)
    local lines = math.floor(room / line)
    local spare = room - lines * line
    pcall(function()
        local spacing = memo.BorderSpacing
        if tonumber(spacing.Bottom) ~= spare then spacing.Bottom = spare end
    end)
    return lines
end

--- The list's frame in the colour that says whether it can be typed into.
function DropDown:PaintMemoFrame()
    local theme = self.Theme
    if theme == nil or self.MemoFrame == nil then return end
    local palette = theme:GetPalette()
    local color = palette.COLOR_BORDER
    if self.ShowsLinked and #self.Subject > 0 then
        color = theme.Mix(palette.COLOR_INPUT, palette.COLOR_BORDER, FRAME_READONLY)
    end
    safeSet(self.MemoFrame, "Color", color)
end

--
--- ∑ The preview's columns.
---
---   The line numbers stand right aligned, and the header draws its title from
---   the left edge of the column whatever the column's alignment. So the title
---   is written as wide as the digits, with the hash in the last digit's
---   place, and the number and the title both carry the blank characters that
---   keep them clear of the value. The list font is monospaced, so a blank is
---   exactly as wide as a digit.
--
DropDown.PreviewColumns = {
    { Key = "Line", Width = LINE_DIGITS + LINE_GAP, Align = "right", ColorKey = "Muted",
      Title = string.rep(" ", LINE_DIGITS - 1) .. "#" .. string.rep(" ", LINE_GAP),
      Text = function(item)
          if item == nil or item.Line == nil then return "" end
          return tostring(item.Line) .. string.rep(" ", LINE_GAP)
      end },
    { Key = "Value", Title = "Value", Width = 14 },
    { Key = "Description", Title = "Description", Width = 0 }
}

--
--- ∑ The panel along the bottom, with the parsed preview over the Apply bar.
---
---   The preview is the only place a person sees what Cheat Engine will
---   really make of what they typed. Apply is created first and sits at the
---   bottom of the panel on its own, with the preview taking the rest.
--- @param theme table
--- @return nil
--
function DropDown:BuildFooter(theme)
    self.Footer = theme:CreatePanel(self.Body, {
        Align = "alBottom", ColorKey = "COLOR_INPUT",
        Height = PREVIEW_HEIGHT + PREVIEW_LABEL_HEIGHT + PREVIEW_LABEL_TOP + BUTTON_HEIGHT + 2 * BAR_PAD
    })
    self:BuildButtons(theme)

    self.PreviewPanel = theme:CreatePanel(self.Footer, {
        Align = "alClient", ColorKey = "COLOR_INPUT",
        Spacing = { Left = LEFT_PAD, Right = LEFT_PAD }
    })
    self.PreviewLabel = theme:CreateLabel(self.PreviewPanel, "No entries", "muted")
    safeSet(self.PreviewLabel, "Align", "alTop")
    pcall(function() self.PreviewLabel.BorderSpacing.Top = PREVIEW_LABEL_TOP end)

    local surface = self.SurfaceClass:New({
        Theme = theme, Log = self.Log, Settings = self.Settings,
        Frame = self.Frame, Name = "DropDownPreview"
    })
    self.PreviewSurface = surface
    self.Preview = surface:ListPainter({
        Header = true,
        Columns = DropDown.PreviewColumns
    })
    self.Preview:SetEmpty("No entries yet", "Type one line per entry above.")
    local ok, reason = surface:Attach(self.PreviewPanel)
    if not ok then
        say(self, "Warning", "The drop-down preview has no canvas, " .. tostring(reason))
    end
end

--
--- ∑ Apply and Revert, kept to the right edge of a bar of their own and
---   placed by hand, Apply outermost.
---
---   A pair aligned to the right edge swaps places in a window that was built
---   hidden, so the two are placed from the edge whenever the bar changes
---   size. On a page too narrow for both side by side Revert goes on a line
---   of its own under Apply's.
--- @param theme table
--- @return nil
--
function DropDown:BuildButtons(theme)
    local bar = theme:CreatePanel(self.Footer, {
        Align = "alBottom", Height = BUTTON_HEIGHT + 2 * BAR_PAD, ColorKey = "COLOR_INPUT"
    })
    self.ActionBar = bar
    local revert, revertEnable = theme:CreateButton(bar, {
        Caption = "Revert", Width = BUTTON_WIDTH, Height = BUTTON_HEIGHT, Spacing = { Around = 0 },
        Hint = "Throw the pending edits away and read the records again.",
        OnClick = function() self:Discard() end
    })
    local apply, applyEnable = theme:CreateButton(bar, {
        Caption = "Apply", Width = BUTTON_WIDTH, Height = BUTTON_HEIGHT, Spacing = { Around = 0 },
        Hint = "Write the list and the flags to every selected record.",
        OnClick = function() self:Save() end
    })
    self.Buttons.Apply = { Control = apply, Enable = applyEnable }
    self.Buttons.Revert = { Control = revert, Enable = revertEnable }
    local order = { revert, apply }
    safeSet(bar, "OnResize", function() self:PlaceButtons(order) end)
end

--- Places the Apply bar's buttons from the right edge and takes the height
--- their lines need.
function DropDown:PlaceButtons(order)
    local bar = self.ActionBar
    local width = innerWidth(bar)
    if width == nil then return nil end
    local y = BAR_PAD
    for _, line in ipairs(buttonLines(order, math.max(0, width - 2 * BAR_EDGE))) do
        local x = width - BAR_EDGE - line.Span
        for _, control in ipairs(line.Controls) do
            safeSet(control, "Left", x)
            safeSet(control, "Top", y)
            x = x + (readNumber(control, "Width") or 0) + BAR_GAP
        end
        y = y + BUTTON_HEIGHT + BAR_GAP
    end
    local height = y - BAR_GAP + BAR_PAD
    if readNumber(bar, "Height") ~= height then
        safeSet(bar, "Height", height)
        self:Relayout()
    end
    return height
end

--
--- ∑ Wraps the notes to the page's width and gives the note and the preview
---   what the page can spare.
---
---   Everything here depends on the page's own size and on the notes' text,
---   never on the preview, so a second pass finds nothing to change. The
---   flags, the linked record row, the Apply bar and a few lines of the list
---   come first. The note takes as many of its lines as are left, all of them
---   on a tall page and fewer with the rest in its hint on a short one, so a
---   long note can never squeeze the list to nothing. The preview gets its
---   full height when there is room, less when there is not, and none at all
---   once it would be too short to read.
--- @return nil
--
function DropDown:Relayout()
    if self.Laying or self.Body == nil then return end
    self.Laying = true
    pcall(function()
        local theme = self.Theme
        local width = innerWidth(self.Body)
        local textWidth = width and (width - 2 * LEFT_PAD) or nil
        -- The hint is never hidden, for the same reason as the note. Without
        -- words it takes no height and no space round it.
        local hintHeight = InspectorModule.FitNote(theme, self.HintLabel, self.HintText, textWidth)
        pcall(function()
            local spacing = self.HintLabel.BorderSpacing
            local top, bottom = hintHeight > 0 and NOTE_TOP or 0, hintHeight > 0 and NOTE_GAP or 0
            if tonumber(spacing.Top) ~= top then spacing.Top = top end
            if tonumber(spacing.Bottom) ~= bottom then spacing.Bottom = bottom end
        end)

        local height = innerHeight(self.Body)
        local bar = readNumber(self.ActionBar, "Height") or (BUTTON_HEIGHT + 2 * BAR_PAD)
        local lines = nil
        if height ~= nil then
            local fixed = 0
            for _, control in ipairs(self.Stack) do
                if control ~= self.NoteLabel then fixed = fixed + stackHeight(control) end
            end
            local spare = height - fixed - bar - 2 * MEMO_GAP - MEMO_MIN - NOTE_TOP
            lines = math.max(0, math.floor(spare / lineHeightOf(theme)))
        end
        local text = (lines == nil or lines > 0) and self.NoteText or ""
        local noteHeight = InspectorModule.FitNote(theme, self.NoteLabel, text, textWidth, lines)
        pcall(function()
            local top = noteHeight > 0 and NOTE_TOP or 0
            local spacing = self.NoteLabel.BorderSpacing
            if tonumber(spacing.Top) ~= top then spacing.Top = top end
        end)

        if height == nil then return end
        local above = 0
        for _, control in ipairs(self.Stack) do above = above + stackHeight(control) end
        local preview = PREVIEW_LABEL_TOP + PREVIEW_LABEL_HEIGHT + PREVIEW_HEIGHT
        local room = height - above - bar - 2 * MEMO_GAP - MEMO_MIN
        if room < preview then preview = room end
        local shown = preview - PREVIEW_LABEL_TOP - PREVIEW_LABEL_HEIGHT >= PREVIEW_MIN
        if isShown(self.PreviewPanel) ~= shown then safeSet(self.PreviewPanel, "Visible", shown) end
        local footer = bar + (shown and preview or 0)
        if readNumber(self.Footer, "Height") ~= footer then safeSet(self.Footer, "Height", footer) end
    end)
    self.Laying = false
end

--------------------------------------------------------
--                Reading the records                 --
--------------------------------------------------------

--
--- ∑ Works out which of the handed in ids this page can edit and why the rest
---   are out.
---
---   Every record can carry a list, a group header included. A header's own
---   Value reads empty, but the list on it is real, and a header that holds
---   one is a common place for other records to link theirs to. So the only
---   records left out are the ones that are gone since the last walk, because
---   there is nothing left on them to read.
--- @param ids table|nil
--- @param snapshot table|nil
--- @return table, string|nil # The usable ids, and the reason when there are none.
--
function DropDown:SubjectOf(ids, snapshot)
    local out = {}
    if snapshot == nil then return out, "There is no address list to read." end
    local known = type(snapshot.ByID) == "table" and snapshot.ByID or {}
    local given = 0
    for _, id in ipairs(ids or {}) do
        given = given + 1
        if known[id] ~= nil then out[#out + 1] = id end
    end
    if given == 0 then return out, "Pick a record in the tree to edit its drop-down list." end
    if #out == 0 then
        return out, given == 1 and "That record is gone from the table."
            or "Those records are gone from the table."
    end
    return out, nil
end

--
--- ∑ Reads the drop-down state of every subject record and decides whether
---   they can be edited together.
---
---   The records have to share the list text for a bulk apply to mean
---   anything. The flags may differ, because only the fields somebody changes
---   are written, and the page says so rather than pretending they agree.
--- @return boolean, string|nil # Whether there is something to edit.
--
function DropDown:ReadSubject()
    local properties, records = self.Properties, self.Records
    self.MixedFlags = false
    if properties == nil or records == nil then
        return false, "The record services are not available."
    end
    local first, anyLinked = nil, false
    self.Held = {}
    for _, id in ipairs(self.Subject) do
        local mr = records:Resolve(id, self.Snapshot)
        if mr == nil then return false, "The record is gone." end
        local state = properties:ReadDropDown(mr)
        self.Held[id] = copy(state)
        if first == nil then
            first = state
        else
            if state.Text ~= first.Text then
                return false, "These records do not share one drop-down list."
            end
            for _, key in ipairs(DropDown.Fields) do
                if key ~= "Text" and state[key] ~= first[key] then self.MixedFlags = true end
            end
        end
        if state.Linked then anyLinked = true end
    end
    if first == nil then return false, "Pick a record in the tree to edit its drop-down list." end
    -- One linked record in the set is enough to make the followed flags
    -- untrustworthy for the whole set, so the whole set goes read only.
    first.Linked = anyLinked or first.Linked == true
    self.Baseline = copy(first)
    self.Buffer = copy(first)
    return true, nil
end

--
--- ∑ Shows a selection. The buffer survives only while the subject is the
---   same set of records, because pending text belongs to the records it was
---   typed for.
--- @param ids table|nil
--- @param snapshot table|nil
--- @return nil
--
function DropDown:Show(ids, snapshot)
    local same = self:SameSubject(ids)
    local dirty = same and self:IsDirty() or false
    self.IDs = {}
    for index, id in ipairs(ids or {}) do self.IDs[index] = id end
    self.Snapshot = snapshot
    if same and dirty then
        -- The same records, so what somebody typed is still about them.
        self:Fill()
        return
    end
    if not same and self:IsDirty() then
        self:Status("The pending drop-down edits were dropped, the selection changed.")
    end
    local subject, reason = self:SubjectOf(self.IDs, snapshot)
    self.Subject, self.Reason = subject, reason
    if reason == nil then
        local ok, why = self:ReadSubject()
        if not ok then
            self.Subject, self.Reason = {}, why
            self.Baseline, self.Buffer = blank(), blank()
        end
    else
        self.Baseline, self.Buffer = blank(), blank()
    end
    self:Fill()
end

--- Whether the ids handed in name the same records the page is already on.
function DropDown:SameSubject(ids)
    local given = ids or {}
    if #given ~= #self.IDs then return false end
    for index, id in ipairs(given) do
        if self.IDs[index] ~= id then return false end
    end
    return #given > 0
end

--
--- ∑ Re-reads after a sync or a commit, without ever throwing away what
---   somebody is in the middle of typing.
--- @param snapshot table|nil
--- @param changedIds table|nil # A list or a set of ids, nil for everything.
--- @return nil
--
function DropDown:Refresh(snapshot, changedIds)
    self.Snapshot = snapshot or self.Snapshot
    if #self.Subject == 0 then
        local subject, reason = self:SubjectOf(self.IDs, self.Snapshot)
        self.Subject, self.Reason = subject, reason
        if reason == nil then
            local ok, why = self:ReadSubject()
            if not ok then self.Subject, self.Reason = {}, why end
        end
        self:Fill()
        return
    end
    -- While Apply waits, the window writes the records, reads them again and
    -- tells this page before it asks for the header. A write that reached
    -- these records is what the page shows from now on, so it is read back
    -- here and the header comes out clean. A write that reached none of them
    -- names none of them, and the pending edit stays as it was.
    if not self.Saving and self:IsDirty() then return end
    if changedIds ~= nil and not self:Touches(changedIds) then return end
    self:Reread()
end

--- Reads the subject records again and shows what they hold, which throws
--- away whatever the buffer held.
function DropDown:Reread()
    local ok, why = self:ReadSubject()
    if not ok then
        self.Subject, self.Reason = {}, why
        self.Baseline, self.Buffer = blank(), blank()
        self.Held = {}
    end
    self:Fill()
end

--- Whether a change list names one of the records this page is showing, or a
--- record one of their links passes through, whose list and flags are the
--- ones on screen. A list carries the id as the value and a set carries it as
--- the key.
function DropDown:Touches(changedIds)
    if type(changedIds) ~= "table" then return true end
    local wanted = {}
    for _, id in ipairs(self.Subject) do wanted[id] = true end
    for id in pairs(self.Watched or {}) do wanted[id] = true end
    for key, value in pairs(changedIds) do
        if type(value) == "number" then
            if wanted[value] then return true end
        elseif value == true and wanted[key] then
            return true
        end
    end
    return false
end

--------------------------------------------------------
--                    The controls                    --
--------------------------------------------------------

--- Writes the buffer into the controls and puts the whole page into the state
--- the buffer describes. Every write happens with Loading on, so nothing here
--- looks like an edit somebody made.
function DropDown:Fill()
    if not self.Built then return end
    local editable = #self.Subject > 0
    safeSet(self.Empty and self.Empty.Panel, "Visible", not editable)
    safeSet(self.Body, "Visible", editable)
    if self.Empty ~= nil and type(self.Empty.Set) == "function" then
        pcall(self.Empty.Set, "No drop-down list to edit", self.Reason)
    end
    if not editable then
        -- A page with nothing to edit is never dirty, and leaving Apply lit
        -- from the last selection would be a button that does nothing.
        self.ShowsLinked = false
        self:UpdateButtons()
        return
    end

    self.Loading = true
    setText(self.LinkEdit, self.Buffer.LinkedMemrec)
    local linked = self.Checks.Linked
    if linked ~= nil then linked.Set(self.Buffer.Linked == true, true) end
    self.Loading = false
    self:Present(true)
end

--
--- ∑ Puts the list box and the three followed checks into the state the
---   buffer's Linked describes, and everything that reads them after.
---
---   While the buffer is linked the box shows the list Cheat Engine takes the
---   entries from and the checks show the flags that come with it, both read
---   only, and they follow the link as it is typed. Otherwise they show the
---   buffer, which is the record's own list and flags, and can be edited. The
---   buffer is written into them only when the page was showing the linked
---   record until now or when asked to, because rewriting the text somebody
---   is typing would put their caret back at the start.
--- @param force boolean|nil # Write the buffer in even when nothing switched.
--- @return nil
--
function DropDown:Present(force)
    local linked = self.Buffer.Linked == true
    -- The own list goes into the box before anything reads the box back, and
    -- the page says it shows the linked record before anything could read
    -- that list as the buffer's.
    self.Loading = true
    if not linked and (force or self.ShowsLinked) then
        setLines(self.Memo, self.Buffer.Text)
        for key in pairs(DropDown.Followed) do
            local check = self.Checks[key]
            if check ~= nil then
                check.Set(self.Buffer[key] == true, true)
                check.Enable(true)
            end
        end
    end
    self.ShowsLinked = linked
    self.Loading = false

    local source = self:UpdateSource()
    if linked then
        self.Loading = true
        setLines(self.Memo, normalise(source.Kind == "linked" and source.Text or ""))
        local flags = self:FlagsInUse(source)
        for key in pairs(DropDown.Followed) do
            local check = self.Checks[key]
            if check ~= nil then
                check.Set(flags[key] == true, true)
                check.Enable(false)
            end
        end
        self.Loading = false
    end
    if safeGet(self.Memo, "ReadOnly") ~= linked then safeSet(self.Memo, "ReadOnly", linked) end

    -- New text can bring the box's scroll bars in or take them away, and
    -- either one moves how many whole lines it has room for.
    self:FitMemo()
    self:PaintMemoFrame()
    self:UpdatePreview(source)
    self:UpdateNote()
    self:UpdateButtons()
end

--
--- ∑ The three followed flags as Cheat Engine answers them for the place the
---   list comes from.
---
---   A link that reaches a record gives that record's flags. A link that
---   reaches nothing gives false for all three, which is what Cheat Engine's
---   getters answer then. Records that use different lists have no one answer,
---   so the page keeps what it read of the first of them.
--- @param source table # An UpdateSource answer.
--- @return table # Flag key to boolean.
--
function DropDown:FlagsInUse(source)
    local out = {}
    if source.Kind == "linked" then
        for key in pairs(DropDown.Followed) do out[key] = (source.Flags or {})[key] == true end
    elseif source.Kind == "mixed" then
        for key in pairs(DropDown.Followed) do out[key] = self.Baseline[key] == true end
    else
        for key in pairs(DropDown.Followed) do out[key] = false end
    end
    return out
end

--
--- ∑ The muted note that says what the page is showing and why some of it
---   cannot be changed, and the line under it that says how a list is
---   written, which only speaks while the list can be typed into.
---
---   The note says nothing at all most of the time, and then it takes no
---   room. It speaks while the record is linked, and after Linked was
---   unticked it says what Apply is about to do. Neither line is ever hidden,
---   because a control that comes back from hidden can take a different place
---   in the stack.
--- @return string # What the note says.
--
function DropDown:UpdateNote()
    local parts = {}
    local many = #self.Subject > 1
    if self.Buffer.Linked == true then
        local source = self.Source or {}
        local name = quoted(source.Name)
        if source.Kind == "linked" then
            local via = ""
            local chain = source.Chain or {}
            if #chain > 1 then
                local passed = {}
                for index = 1, #chain - 1 do passed[index] = quoted(chain[index]) end
                via = ", by way of " .. table.concat(passed, " and ")
            end
            parts[#parts + 1] = DropDown.LinkedNote .. name .. via .. DropDown.ShownNote
        elseif source.Kind == "dead" then
            parts[#parts + 1] = "No record has the description " .. name
                .. ", so Cheat Engine shows no list."
        elseif source.Kind == "loop" then
            parts[#parts + 1] = "The link comes back round to " .. name
                .. ", so Cheat Engine shows no list."
        elseif source.Kind == "unnamed" and source.Name ~= nil then
            parts[#parts + 1] = name .. " is linked but names no record, so Cheat Engine shows no list."
        elseif source.Kind == "unnamed" then
            parts[#parts + 1] = "Linked, but no record is named, so Cheat Engine shows no list."
        else
            parts[#parts + 1] = "These records take their lists from different places, so none is shown here."
        end
        parts[#parts + 1] = many and DropDown.OwnNoteMany or DropDown.OwnNote
    elseif self.Baseline.Linked == true then
        parts[#parts + 1] = many and DropDown.UnlinkNoteMany or DropDown.UnlinkNote
    end
    if self.MixedFlags then
        parts[#parts + 1] = "These records do not all hold the same flags. Only what you change here is written."
    end
    local text = table.concat(parts, " ")
    local hint = self.ShowsLinked and "" or DropDown.Hint
    if text ~= self.NoteText or hint ~= self.HintText then
        self.NoteText, self.HintText = text, hint
        self:Relayout()
    end
    return text
end

--
--- ∑ What the subject records would hold once the pending edit is applied,
---   one state per record. The fields nobody changed stay each record's own.
--- @return table # id to state.
--
function DropDown:Effective()
    local changed = self:Changes()
    local out = {}
    for _, id in ipairs(self.Subject) do
        local state = copy(self.Held[id] or self.Baseline)
        for key, value in pairs(self:ChangesFor(id, changed)) do state[key] = value end
        out[id] = state
    end
    return out
end

--
--- ∑ What Apply writes to one record, which is what the person changed and,
---   for a record that is being unlinked, the three followed flags as well.
---
---   Cheat Engine hides a linked record's own flags behind the linked
---   record's, so what the page read and showed for them is not what the
---   record holds. Left out, the record would come back from the unlink with
---   flags nobody saw. Written, it holds what the checks say.
--- @param id number
--- @param changed table # A Changes answer.
--- @return table # Field to value.
--
function DropDown:ChangesFor(id, changed)
    local out = {}
    for key, value in pairs(changed) do out[key] = value end
    local held = self.Held[id] or self.Baseline
    if held.Linked == true and changed.Linked == false then
        for key in pairs(DropDown.Followed) do
            if out[key] == nil then out[key] = self.Buffer[key] == true end
        end
    end
    return out
end

--
--- ∑ The record Cheat Engine finds under a description, looked up the way a
---   drop-down link looks it up.
---
---   That is the address list's own description lookup, which is not the same
---   as searching the snapshot. It ignores case and the last record given a
---   description is the one it keeps. Without Cheat Engine the snapshot
---   answers, first match wins.
--- @param name string|nil
--- @return number|nil # The record's id.
--- @return userdata|nil # The record, valid for this call only.
--
function DropDown:LookUp(name)
    if type(name) ~= "string" or name == "" then return nil end
    local ce = self.CE
    if ce ~= nil then
        local find = ce:Get(ce:AddressList(), "getMemoryRecordByDescription")
        if type(find) == "function" then
            local ok, mr = pcall(find, name)
            if not ok or mr == nil then return nil end
            local id = math.tointeger(tonumber(ce:Get(mr, "ID")))
            if id == nil then return nil end
            return id, mr
        end
    end
    local snapshot = self.Snapshot
    for _, node in ipairs(snapshot and snapshot.Order or {}) do
        if node.Description == name then
            local records = self.Records
            local mr = records ~= nil and records:Resolve(node.ID, snapshot) or nil
            return node.ID, mr
        end
    end
    return nil
end

--
--- ∑ Where one record's entries come from, the way Cheat Engine's getters
---   find them.
---
---   An unlinked record uses its own list. A linked one uses the list of the
---   record its link names, and when that record is linked as well, the list
---   its link names, until a record that is not linked. A name nothing answers
---   to gives no list, and so does a link that comes back to a record already
---   passed, which Cheat Engine's loop check drops. The subject records are
---   taken as the pending edit would leave them, everything else as Cheat
---   Engine holds it now.
--- @param id number # The subject record.
--- @param state table # What that record would hold.
--- @param effective table # id to state for every subject record.
--- @return table # Kind, one of own, linked, dead, loop and unnamed, with
---         Text, the list in use, Flags, the three followed flags that come
---         with it, Name, the record named last, ID, the record the list is
---         on, Chain, every name followed in order, and IDs, every record
---         passed.
--
function DropDown:SourceOf(id, state, effective)
    if state.Linked ~= true then return { Kind = "own", Text = state.Text or "" } end
    local seen, chain, ids = { [id] = true }, {}, {}
    local name = tostring(state.LinkedMemrec or "")
    for _ = 1, LINK_DEPTH do
        if name == "" then
            return { Kind = "unnamed", Name = chain[#chain], Chain = chain, IDs = ids }
        end
        local target, mr = self:LookUp(name)
        if target == nil then
            return { Kind = "dead", Name = name, Chain = chain, IDs = ids }
        end
        if seen[target] then
            return { Kind = "loop", Name = name, Chain = chain, IDs = ids }
        end
        seen[target] = true
        chain[#chain + 1] = name
        ids[#ids + 1] = target
        local held = effective[target]
        if held == nil then
            local properties = self.Properties
            held = (properties ~= nil and mr ~= nil) and properties:ReadDropDown(mr) or blank()
        end
        if held.Linked ~= true then
            local flags = {}
            for key in pairs(DropDown.Followed) do flags[key] = held[key] == true end
            return { Kind = "linked", ID = target, Name = name, Text = held.Text or "",
                     Flags = flags, Chain = chain, IDs = ids }
        end
        name = tostring(held.LinkedMemrec or "")
    end
    return { Kind = "loop", Name = name, Chain = chain, IDs = ids }
end

--- Whether two records take their entries from the same place.
local function sameSource(a, b)
    if a.Kind ~= b.Kind then return false end
    if a.Kind == "own" then return a.Text == b.Text end
    if a.Kind == "linked" then return a.ID == b.ID end
    return a.Name == b.Name
end

--
--- ∑ Works out where the list on screen comes from for the whole subject.
---
---   Several records are only previewed together when they all take their
---   entries from the same place, because one preview cannot show two lists.
--- @return table # One SourceOf answer, or Kind mixed.
--
function DropDown:UpdateSource()
    local found, watched = nil, {}
    if #self.Subject > 0 then
        local effective = self:Effective()
        for _, id in ipairs(self.Subject) do
            local source = self:SourceOf(id, effective[id], effective)
            for _, passed in ipairs(source.IDs or {}) do watched[passed] = true end
            if found == nil then
                found = source
            elseif found.Kind ~= "mixed" and not sameSource(found, source) then
                found = { Kind = "mixed" }
            end
        end
    end
    self.Source = found or { Kind = "own", Text = self.Buffer.Text }
    self.Watched = watched
    return self.Source
end

--
--- ∑ What the preview says over its rows and in place of them, for the place
---   the list comes from.
--- @param source table # An UpdateSource answer.
--- @param entries table
--- @param flagged number
--- @return string, string, string # The line over the rows, and the title
---         and hint shown when there are none.
--
function DropDown.PreviewWords(source, entries, flagged)
    local kind = source and source.Kind or "own"
    local name = quoted(source and source.Name)
    if kind == "own" then
        return DropDown.Summary(entries, flagged), "No entries yet", "Type one line per entry above."
    end
    if kind == "linked" then
        local via = ""
        local chain = source.Chain or {}
        if #chain > 1 then
            local passed = {}
            for index = 1, #chain - 1 do passed[index] = quoted(chain[index]) end
            via = ", by way of " .. table.concat(passed, " and ")
        end
        return DropDown.Summary(entries, flagged) .. " from " .. name .. via,
            "No entries in " .. name, "Cheat Engine shows this record without a list."
    end
    if kind == "dead" then
        return "No list, nothing is described " .. name, "No list in use",
            "Cheat Engine finds no record described " .. name .. "."
    end
    if kind == "loop" then
        return "No list, the link comes back to " .. name, "No list in use",
            "The link comes back round to " .. name .. ", so Cheat Engine drops it."
    end
    if kind == "unnamed" then
        local who = source.Name ~= nil and (name .. " is linked but names") or "The link names"
        return "No list, the link names no record", "No list in use",
            who .. " no record, so Cheat Engine has no list to show."
    end
    return "No list, the records use different ones", "Different lists in use",
        "These records take their entries from different places. Pick one to see its list."
end

--
--- ∑ Fills the preview with the entries Cheat Engine uses.
---
---   That is the text in the box for a record that is not linked, and the
---   list of the record the link leads to for one that is, parsed the same
---   way. The line over the rows says whose list it is. Where the list comes
---   from is worked out again first, from what the controls hold now, unless
---   the caller just did, and the note reads it afterwards.
--- @param source table|nil # An UpdateSource answer that is still current.
--- @return table, number # The rows and how many lines were flagged.
--
function DropDown:UpdatePreview(source)
    source = source or self:UpdateSource()
    local text = ""
    if source.Kind == "own" or source.Kind == "linked" then text = source.Text end
    local entries, flagged = DropDown.Parse(text)
    local rows = {}
    for index, entry in ipairs(entries) do
        local flag = entry.Note ~= nil
        rows[index] = {
            Line = entry.Line,
            Value = entry.Value,
            Description = flag and entry.Note or entry.Description,
            Flagged = flag,
            -- The list painter reads a per row colour override off the item,
            -- which is how one bad line stands out without a column of its own.
            ColorKeys = flag and { Value = "Warning", Description = "Warning" } or nil
        }
    end
    local caption, title, hint = DropDown.PreviewWords(source, entries, flagged)
    if self.Preview ~= nil then
        self.Preview:SetEmpty(title, hint)
        self.Preview:SetItems(rows)
    end
    safeSet(self.PreviewLabel, "Caption", caption)
    return rows, flagged
end

--- Turns the two buttons on and off from what the buffer says.
function DropDown:UpdateButtons()
    local dirty = self:IsDirty()
    local apply, revert = self.Buttons.Apply, self.Buttons.Revert
    if apply ~= nil then apply.Enable(dirty) end
    if revert ~= nil then revert.Enable(dirty) end
    local goTo = self.Buttons.GoTo
    if goTo ~= nil then
        goTo.Enable(self.Buffer.Linked == true and self.Buffer.LinkedMemrec ~= "")
    end
    -- The star in the header goes with Apply, so the header is asked for
    -- whenever Apply is.
    fire(self.OnTitleChanged)
end

--- Reads the controls back into the buffer. Everything that asks whether the
--- page is dirty goes through here first, so it does not matter whether the
--- change arrived as a typed character or as a line written by a test. While
--- the list box and the three checks show the linked record they are not the
--- buffer's and are left out, so the record's own list and flags wait in the
--- buffer for Linked to be unticked.
function DropDown:Capture()
    if not self.Built or #self.Subject == 0 then return self.Buffer end
    if not self.ShowsLinked then
        local ok, value = pcall(function() return self.Memo.Lines.Text end)
        if ok and type(value) == "string" then self.Buffer.Text = normalise(value) end
    end
    local link = safeGet(self.LinkEdit, "Text")
    if type(link) == "string" then self.Buffer.LinkedMemrec = link end
    for _, flag in ipairs(DropDown.Flags) do
        local check = self.Checks[flag.Key]
        if check ~= nil and not (self.ShowsLinked and DropDown.Followed[flag.Key]) then
            self.Buffer[flag.Key] = check.Get() == true
        end
    end
    return self.Buffer
end

--- What one edit costs. Ticking or unticking Linked hands the list box and
--- the three checks over, the list box follows a link as it is typed, the
--- preview follows the text and the link, the note follows the link and the
--- buttons and the header follow the buffer.
function DropDown:AfterEdit()
    self:Present(false)
end

--------------------------------------------------------
--                  The dirty state                   --
--------------------------------------------------------

--
--- ∑ The fields that differ from what the records held, with the values to
---   write into them.
--- @return table, number
--
function DropDown:Changes()
    self:Capture()
    local out, count = {}, 0
    if #self.Subject == 0 then return out, 0 end
    local linked = self.Buffer.Linked == true
    for _, key in ipairs(DropDown.Fields) do
        local wanted, held = self.Buffer[key], self.Baseline[key]
        -- While the record stays linked, the text and the followed flags are
        -- not what Cheat Engine uses, so they are never written. Unticking
        -- Linked is what lets them through.
        local blocked = linked and (key == "Text" or DropDown.Followed[key])
        if not blocked and wanted ~= held then
            out[key] = wanted
            count = count + 1
        end
    end
    return out, count
end

function DropDown:IsDirty()
    local _, count = self:Changes()
    return count > 0
end

--- The label one transaction carries, which names what really changed rather
--- than the page it was changed on.
function DropDown:LabelFor(changed)
    local text, flags, link = changed.Text ~= nil, false, false
    for _, flag in ipairs(DropDown.Flags) do
        if changed[flag.Key] ~= nil then
            if flag.Key == "Linked" then link = true else flags = true end
        end
    end
    if changed.LinkedMemrec ~= nil then link = true end
    local what = "Drop-down list"
    if not text and link and not flags then what = "Drop-down link"
    elseif not text and flags then what = "Drop-down flags" end
    local subject = #self.Subject
    if subject == 1 then
        local node = self.Snapshot and self.Snapshot.ByID[self.Subject[1]] or nil
        local name = node and node.Description or ""
        if name ~= "" then return what .. " on " .. quoted(name) end
        return what .. " on one record"
    end
    return what .. " on " .. subject .. " records"
end

--
--- ∑ Hands the pending edits up as one transaction, with one dropdown change
---   per record.
---
---   Old is read per record and not taken from the page, because a bulk apply
---   over records whose flags differ has a different old value per record and
---   undo has to put each one back where it came from.
--- @return boolean # Whether the page is clean afterwards.
--
function DropDown:Save()
    if #self.Subject == 0 then return true end
    local changed, count = self:Changes()
    if count == 0 then
        self:Status("There is nothing to apply.")
        return true
    end
    if type(self.OnCommit) ~= "function" then
        self:Status("This page is not wired to a window, nothing was written.")
        return false
    end
    local properties, records = self.Properties, self.Records
    local changes = {}
    for _, id in ipairs(self.Subject) do
        local mr = records and records:Resolve(id, self.Snapshot) or nil
        local held = (mr ~= nil and properties ~= nil) and properties:ReadDropDown(mr) or nil
        -- The record's own values when it could be read, and what the page
        -- read at the start when it could not. Chosen as a whole table rather
        -- than per field, because a field that is false would otherwise fall
        -- through to the other side of an and or.
        local source = held or self.Baseline
        local old, new = {}, {}
        for key, value in pairs(self:ChangesFor(id, changed)) do
            new[key] = value
            old[key] = source[key]
        end
        changes[#changes + 1] = { Kind = "dropdown", ID = id, Old = old, New = new }
    end
    local tx = { Label = self:LabelFor(changed), Changes = changes }
    self.Saving = true
    local ok, applied, failures = fire(self.OnCommit, tx)
    self.Saving = false
    applied = tonumber(applied) or 0
    if ok == true and applied > 0 then
        -- What Cheat Engine holds now and not what the page asked for. A new
        -- link hands the followed flags over to the linked record, and a
        -- record that refused keeps its own values.
        self:Reread()
        return true
    end
    local failed = type(failures) == "table" and #failures or 0
    self:Status(failed > 0
        and ("The drop-down change was refused for " .. failed
            .. (failed == 1 and " record." or " records."))
        or "The drop-down change was not applied.")
    return false
end

--- Throws the pending edits away and puts the controls back to what the
--- records hold.
function DropDown:Discard()
    self.Buffer = copy(self.Baseline)
    self:Fill()
    self:Status("The pending drop-down edits were dropped.")
end

--------------------------------------------------------
--                      Actions                       --
--------------------------------------------------------

--
--- ∑ Takes the person to the record this one is linked to.
---
---   Cheat Engine names the source by description, so the id has to be looked
---   up in the snapshot. Every record in it is a target, a group header as
---   much as a value, because a header that carries a list is a common thing
---   to link to. A description that names nothing is a dead link and the page
---   says so rather than moving the selection somewhere wrong.
--- @return boolean, number|nil # Whether it went somewhere, and where.
--
function DropDown:GoToLinked()
    self:Capture()
    local name = self.Buffer.LinkedMemrec
    if name == nil or name == "" then
        self:Status("This record names no linked record.")
        return false
    end
    -- The record Cheat Engine's own lookup answers with, which is the one the
    -- link really takes its list from, and only while the window knows it.
    local target = self:LookUp(name)
    local known = self.Snapshot and self.Snapshot.ByID or nil
    if target ~= nil and (known == nil or known[target] == nil) then target = nil end
    if target == nil then
        self:Status("No record in this table is described " .. quoted(name) .. ".")
        return false
    end
    if type(self.OnGoTo) == "function" then
        fire(self.OnGoTo, target)
        self:Status("Went to " .. quoted(name) .. ".")
        return true, target
    end
    -- Without a window hook the next best thing is Cheat Engine's own
    -- selection, which the window follows when the person asked it to.
    local ce = self.CE
    if type(self.OnAct) == "function" and ce ~= nil then
        fire(self.OnAct, "Go to linked record", { target }, function()
            return ce:SelectRecord(target)
        end)
        self:Status("Selected " .. quoted(name) .. " in Cheat Engine.")
        return true, target
    end
    self:Status("There is no way to go to " .. quoted(name) .. " from here.")
    return false
end

--------------------------------------------------------
--                    The keyboard                    --
--------------------------------------------------------

--
--- ∑ The keys this page answers, which is none of them. The memo and the edit
---   keep every key they are given, and the window owns the rest.
--- @param key number
--- @return boolean
--
function DropDown:HandleKey(key)
    return false
end

--------------------------------------------------------
--                Titles and teardown                 --
--------------------------------------------------------

--
--- ∑ What the inspector header shows while this page is up.
--- @return string
--
function DropDown:Title()
    local count = #self.Subject
    if count == 0 then return "No drop-down list" end
    local mark = self:IsDirty() and " *" or ""
    if count == 1 then
        local node = self.Snapshot and self.Snapshot.ByID[self.Subject[1]] or nil
        local name = node and node.Description or ""
        if name ~= "" then return "Drop-down list of " .. quoted(name) .. mark end
        return "Drop-down list of one record" .. mark
    end
    return "Drop-down list of " .. count .. " records" .. mark
end

--- Releases the canvas and forgets the controls. The panels belong to the
--- inspector card and are freed with it.
function DropDown:Destroy()
    if self.PreviewSurface ~= nil then
        self.PreviewSurface:Destroy()
        self.PreviewSurface = nil
    end
    self.Preview = nil
    self.Checks, self.Buttons, self.Stack = {}, {}, {}
    self.Memo, self.LinkEdit, self.NoteLabel, self.HintLabel = nil, nil, nil, nil
    self.MemoFrame, self.MemoFill, self.LinkRow, self.LinkEnable = nil, nil, nil, nil
    self.Footer, self.ActionBar, self.NoteText = nil, nil, ""
    self.HintText, self.ShowsLinked = DropDown.Hint, false
    self.PreviewPanel, self.PreviewLabel = nil, nil
    self.Empty, self.Body, self.Panel, self.Parent = nil, nil, nil, nil
    self.Subject, self.IDs = {}, {}
    self.Baseline, self.Buffer = blank(), blank()
    self.Held, self.Source, self.Watched, self.Saving = {}, nil, {}, false
    self.Built = false
end

return DropDown
