--[[
    The hotkeys page, which is an overview of every hotkey in the table and not
    a hotkey editor.

    Two Cheat Engine facts decide the whole shape of this page. Capturing a key
    combination means listening for key presses while the table's own hotkeys
    are registered, so the combination a person tries to record fires the very
    hotkeys they are looking at. And a hotkey's Keys setter fills one slot at a
    time and stops at the first empty one, so a shorter combination leaves the
    trailing keys of the old one behind, while the hotkey thread keeps the copy
    it registered with and never hears about the change at all. Changing keys
    therefore means destroying the hotkey and making a new one, which loses the
    id every undo entry is keyed by. So this page does not create hotkeys and
    does not change key combinations. It says so in one line on the page and it
    sends people to Cheat Engine for both.

    What it does do is show them. Every hotkey of the selection, or every
    hotkey in the whole table with the All records toggle, with the record it
    belongs to, and with the combinations that are used more than once flagged
    in the warning colour. The conflict scan always reads the whole table even
    when the list shows a selection, because a combination that clashes with a
    hotkey somewhere else is exactly the one nobody finds by looking.

    Four fields can be edited and all four go through the commit funnel, so
    they undo like every other edit. Test runs the action for real after a
    confirmation, which for a toggle hotkey means the record is activated or
    deactivated. Remove destroys the hotkey, which Cheat Engine cannot undo and
    this window cannot either, and both say so before they run.

    The page never writes to a record itself. It reads through Properties,
    hands undoable edits up as one transaction and the two actions up as
    actions, and keeps no memory record or hotkey wrapper between operations.

    Top to bottom the page reads the note, the tool line, the list, three
    fields and the commit bar. The tool line holds the All records toggle, the
    count, and Test and Remove, which act on the picked hotkey and so stand
    over the list the way the Pointer page keeps its level buttons over its
    own. The fields are field rows with one label column, framed and themed
    like every other input in the window. The commit bar keeps Only while held
    down at the left edge and Revert and Apply at the right, placed by hand so
    the two can never cover each other. The fields and the bar share one panel
    along the bottom, because two bottom aligned panels are ordered by their
    lower edges and the taller one ends up underneath, which is how the
    buttons once came to sit above the fields.

    The list keeps room for its header and three rows. At the window's
    smallest size the page has no room for those rows, the whole note and four
    field rows at once, which is why the check shares the commit bar and why
    the note gives its lines up first on a short page. A note that had to be
    cut says the rest in its hint, and so does a count that had to be
    shortened.

    The columns are fitted to every hotkey in the table and not to the rows on
    the list, so a record without hotkeys shows the same header as a record
    with some, and nothing moves when a selection brings rows along. On a
    narrow list Record gives way first, then Description, and Action keeps the
    room that tells the three toggles apart until nothing else is left to give.
]]

local SurfaceModule = require("Manifold-AddressList-Surface")
local PropertiesModule = require("Manifold-AddressList-Properties")
local InspectorModule = require("Manifold-AddressList-Inspector")

local Hotkeys = {}
Hotkeys.__index = Hotkeys

--- The tab this page lives behind.
Hotkeys.Key = "Hotkeys"
Hotkeys.Caption = "Hotkeys"

--
--- ∑ The one line that explains what this page will not do.
---
---   It is on the page and not only in the documentation, because the first
---   thing anybody looks for here is a New button, and an empty area that says
---   nothing would read as a page that is broken.
--
Hotkeys.Note =
    "Add or change key combinations in Cheat Engine. This page shows every hotkey in the table and finds conflicts."

--- The four fields this page may change, in the order the detail strip shows
--- them. They come from Properties, so the page and the window applier can
--- never drift apart on what a hotkey change may carry.
Hotkeys.Fields = PropertiesModule.HotkeyFields

--- The longest action Cheat Engine names, in characters, which is how wide
--- the Action column may get so that every action can be read whole.
local LONGEST_ACTION = 0
for _, action in ipairs(PropertiesModule.HotkeyActions) do
    LONGEST_ACTION = math.max(LONGEST_ACTION, #action.Label)
end

--- The columns, in the order the correction names them. A width is in
--- characters and a width of zero takes whatever is left. A width is the most
--- that column may get, and the list fits each one to the hotkeys the table
--- holds, see ColumnsFor, so Description keeps the room short texts leave.
--- Floor is the least a column keeps when the list is narrow. Description's
--- floor is what it holds on to while Record gives way, and a column without
--- a floor never gives way at all, because a cut key combination or a cut
--- value reads as a different one. Action is as wide as the longest action at
--- most, because the two long toggles only differ near their ends.
Hotkeys.Columns = {
    { Key = "Keys", Title = "Keys", Width = 16 },
    { Key = "Action", Title = "Action", Width = LONGEST_ACTION + 1, Floor = 10 },
    { Key = "Value", Title = "Value", Width = 8 },
    { Key = "Record", Title = "Record", Width = 20, Floor = 7, ColorKey = "Muted" },
    { Key = "Description", Title = "Description", Width = 0, Floor = 16, ColorKey = "Muted" }
}

--
--- ∑ The order a narrow list takes its room back in, the first step first.
---
---   Record goes first, dropped outright where it would only repeat the one
---   record the list shows and cut down to its floor otherwise. Then Action
---   gives up what it holds beyond the width that keeps its actions apart,
---   see ApartWidth. Description then takes whatever is left, even under its
---   floor. Only a list too narrow for the columns that never give way and
---   the actions kept apart takes Action down to its own floor, where two
---   toggles read alike, because a Description with no room at all is worse.
--
Hotkeys.GiveWay = {
    { Key = "Record", To = "Floor", Drop = true },
    { Key = "Action", To = "Apart" },
    { Key = "Action", To = "Floor", Last = true }
}

--- One field row and the space under it, and the space over the first one.
--- The rows sit together as one form, so they stand closer than a lone row
--- would, which is also what leaves the list its rows on a short page.
local FIELD_HEIGHT, FIELD_GAP, DETAIL_TOP = 26, 2, 2

--- The field rows over the commit bar, in the order they read.
local FIELD_ROWS = 3

--- How far apart the stacked controls are given their Top, so no two of them
--- can ever tie.
local STACK_STEP = 10000

--- The space every row, list and bar keeps from the page's left and right
--- sides, which is where the field row labels start, and the height of the
--- tool line. The note, the list, the frames and the buttons all start and
--- end on these two edges.
local LEFT_PAD, TOGGLE_HEIGHT = 6, 26

--- The few pixels a drawn check keeps in front of its box. A check stands
--- that much before the page edge, so its box stands on the edge.
local CHECK_LEAD = 2

--- What a fitted column keeps after its longest text, because the list
--- leaves less than a character between two columns.
local COLUMN_GAP = 1

--- The width of one character when nobody measured one, which is Consolas at
--- the family size.
local DEFAULT_CHAR = 7

--- The space over and under the note while it shows anything.
local NOTE_TOP, NOTE_BOTTOM = 2, 2

--- The least that stands between the count and what is either side of it.
--- The toggle ends in a few pixels of its own, so the gap to its caption
--- reads wider than this.
local COUNT_GAP = 8

--- A button's height, the space between two buttons, what a bar keeps over
--- and under its lines, and the least that stands between the two groups on
--- one line. The Pointer, Script and Drop-down pages keep the same space over
--- and under their commit bars, so Revert and Apply stand at one height on
--- every page and do not jump when the tab changes. This one was three once,
--- which put them two pixels lower here than anywhere else.
local BUTTON_HEIGHT, BAR_GAP, BAR_PAD, BAR_SPLIT = 26, 6, 5, 18

--- What a bar keeps at its two ends. The left group starts with a check, so
--- it stands a check's lead before the page edge, and the right group ends on
--- the edge itself, where the frames above it end.
local BAR_LEFT, BAR_RIGHT = LEFT_PAD - CHECK_LEAD, LEFT_PAD

--- The width of every button on the page. Two on the tool line and two on the
--- commit bar, beside the toggle and the check, fit one line each on the
--- narrowest window.
local BUTTON_WIDTH = 64

--- How many rows the list keeps under its header before the note gives up a
--- line, and the height of a row while the list has not measured one yet,
--- which is Consolas at the family size.
local LIST_ROWS, LIST_ROW_HEIGHT = 3, 21

--- A line of the note while the theme cannot say.
local NOTE_LINE = 15

--- How many refreshes may go by before the page reads every hotkey again
--- although nothing in the snapshot suggests one changed. At the default sync
--- interval that is about every two seconds, which is soon enough to notice an
--- edit made in Cheat Engine and rare enough to cost nothing.
local SCAN_EVERY = 8

--- What the two actions tell a person before they run.
local TEST_NOTE =
    "The action really runs. A toggle hotkey activates or deactivates the record."
local REMOVE_NOTE =
    "This cannot be undone. Neither Cheat Engine nor this window keeps a hotkey to put back."

--------------------------------------------------------
--                   Small helpers                    --
--------------------------------------------------------

--- One guarded property write.
local function safeSet(control, key, value)
    if control == nil then return false end
    return (pcall(function() control[key] = value end))
end

--- Writes a text property only when it really changes. Rewriting the text a
--- person is typing into would put their caret back at the start of it, and a
--- live sync calls this on every tick.
local function setText(control, value)
    if control == nil then return false end
    local ok, held = pcall(function() return control.Text end)
    if ok and held == value then return true end
    return (pcall(function() control.Text = value end))
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

--- Calls one of the window's hooks without letting a defect in it reach the
--- control that fired.
local function fire(handler, ...)
    if type(handler) ~= "function" then return nil end
    local ok, first, second, third = pcall(handler, ...)
    if not ok then return nil end
    return first, second, third
end

local function quoted(text)
    return "'" .. tostring(text or "") .. "'"
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

--- The character width and line height of the segment font, with what GDI
--- answers for Consolas at ten points when the theme cannot say.
local function metricsOf(theme)
    local charWidth, lineHeight = 7, NOTE_LINE
    if theme ~= nil and type(theme.TextMetrics) == "function" then
        local ok, width, height = pcall(theme.TextMetrics, theme)
        if ok and tonumber(width) and width > 0 then charWidth = width end
        if ok and tonumber(height) and height > 0 then lineHeight = height end
    end
    return charWidth, lineHeight
end

--- Whether a control is meant to be on screen. One that cannot say counts as
--- shown.
local function isShown(control)
    local ok, value = pcall(function() return control.Visible end)
    return not ok or value ~= false
end

--- Whether a control has the keyboard right now. A build without focused
--- answers no, which hands the key to the list as before.
local function hasFocus(control)
    if control == nil then return false end
    local ok, focused = pcall(function() return control.focused() end)
    return ok and focused == true
end

--- Gives a top aligned control its place in the stack. Slot one is the
--- topmost.
local function stackAt(control, slot)
    safeSet(control, "Top", slot * STACK_STEP)
    return control
end

--- Breaks one group of buttons into lines no wider than width.
local function groupLines(group, width)
    local lines, line, used = {}, {}, 0
    for _, control in ipairs(group) do
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

--
--- ∑ Places a bar's two groups of buttons, the left one from the left edge and
---   the right one from the right edge.
---
---   The two share a line when they fit side by side. When they do not, the
---   right group takes a line of its own under the left one, and a group too
---   wide for a line wraps. Aligned to the two edges instead, a bar narrower
---   than both groups slides one under the other.
--- @param bar userdata
--- @param left table # Button panels, in reading order.
--- @param right table # The same, the outermost last.
--- @return number|nil # The height the lines need, or nil while the bar has
---         no width.
--
local function placeGroups(bar, left, right)
    local width = innerWidth(bar)
    if width == nil then return nil end
    local room = math.max(0, width - BAR_LEFT - BAR_RIGHT)
    local leftLines, rightLines = groupLines(left, room), groupLines(right, room)
    local rows = {}
    for index, line in ipairs(leftLines) do rows[index] = { Left = line } end
    if #leftLines == 1 and #rightLines == 1
        and leftLines[1].Span + BAR_SPLIT + rightLines[1].Span <= room then
        rows[1].Right = rightLines[1]
    else
        for _, line in ipairs(rightLines) do rows[#rows + 1] = { Right = line } end
    end
    local function place(line, x, y)
        for _, control in ipairs(line.Controls) do
            safeSet(control, "Left", x)
            safeSet(control, "Top", y)
            x = x + (readNumber(control, "Width") or 0) + BAR_GAP
        end
    end
    local y = BAR_PAD
    for _, row in ipairs(rows) do
        if row.Left then place(row.Left, BAR_LEFT, y) end
        if row.Right then place(row.Right, width - BAR_RIGHT - row.Right.Span, y) end
        y = y + BUTTON_HEIGHT + BAR_GAP
    end
    if #rows == 0 then return 2 * BAR_PAD end
    return y - BAR_GAP + BAR_PAD
end

--- Which columns a row draws in a colour of its own. A conflict wins over a
--- pending edit, because a combination that fires two records is the worse
--- news of the two.
local function colorsFor(fields, clash)
    local colors = {}
    for key, value in pairs(fields or {}) do
        if value ~= nil then
            if key == "OnlyWhileDown" then colors.Keys = "Accent" else colors[key] = "Accent" end
        end
    end
    if clash then colors.Keys = "Warning" end
    if next(colors) == nil then return nil end
    return colors
end

--- What names one pending edit. A record id and a hotkey id together, because
--- a hotkey id is only unique inside its own record.
local function editKey(id, hotkeyID)
    return tostring(id) .. "/" .. tostring(hotkeyID)
end

--
--- ∑ The identity of a key combination, so two hotkeys that hold the same keys
---   in a different order still count as the same combination.
---
---   The order is the order they were pressed in, which Windows does not care
---   about for a modifier, so the codes are sorted before they are joined.
--- @param keys table|nil # Virtual key codes.
--- @return string # Empty when the hotkey holds no keys at all.
--
function Hotkeys.ComboOf(keys)
    local out = {}
    for _, key in ipairs(keys or {}) do
        local number = math.tointeger(tonumber(key))
        if number ~= nil and number ~= 0 then out[#out + 1] = number end
    end
    if #out == 0 then return "" end
    table.sort(out)
    local parts = {}
    for index, number in ipairs(out) do parts[index] = tostring(number) end
    return table.concat(parts, "-")
end

--
--- ∑ The columns for one set of rows, each as wide as what it shows and
---   Description taking the rest.
---
---   A column with a width is its title or its longest text, whichever is
---   longer, and one character more. It never grows past the width the column
---   list gives it, so a very long text is cut rather than taking the
---   description's room. The page hands in every hotkey of the table and not
---   only the rows on the list, so an empty list is laid out the way it will
---   be once its rows arrive and the header does not jump when they do.
---
---   Told how wide the list is, the columns also keep Description at its
---   floor, taking the room back in the order GiveWay names. Record is
---   dropped rather than cut while the list shows the hotkeys of one record,
---   because the tree already says which record that is. Single says whether
---   it does, and without it the rows are asked, where no rows at all count as
---   one record. Whatever is left after that is Description's, even when it is
---   less than its floor.
---
---   The column list itself is left alone, every call hands back a new one.
--- @param rows table|nil # List rows, each with its column texts and its ID.
--- @param fit table|nil # Width, the pixels the list lays its columns out in
---        with its scroll bar already taken off, CharWidth, the pixels of one
---        character, All, true while the list shows the whole table, and
---        Single, true while it shows the hotkeys of one record.
--- @return table # The columns, in the column list's order.
--
function Hotkeys.ColumnsFor(rows, fit)
    rows = rows or {}
    fit = type(fit) == "table" and fit or {}
    local longest, owner, single = {}, nil, true
    local labels, seen = {}, {}
    for _, row in ipairs(rows) do
        for _, column in ipairs(Hotkeys.Columns) do
            if column.Width > 0 then
                local key = column.Key
                longest[key] = math.max(longest[key] or 0, textLength(row[key]))
            end
        end
        local who = row.ID
        if who == nil then who = row.Record end
        if owner == nil then owner = who elseif who ~= owner then single = false end
        local label = row.Action
        if label ~= nil and label ~= "" and not seen[label] then
            seen[label] = true
            labels[#labels + 1] = tostring(label)
        end
    end
    if fit.Single ~= nil then single = fit.Single == true end

    local out = {}
    for index, column in ipairs(Hotkeys.Columns) do
        local copy = {}
        for key, value in pairs(column) do copy[key] = value end
        if column.Width > 0 then
            local wanted = math.max(textLength(column.Title), longest[column.Key] or 0) + COLUMN_GAP
            copy.Width = math.min(column.Width, wanted)
        end
        out[index] = copy
    end

    local width = tonumber(fit.Width)
    if width == nil or width <= 0 then return out end
    local each = tonumber(fit.CharWidth)
    if each == nil or each <= 0 then each = DEFAULT_CHAR end
    local pad = SurfaceModule.Defaults.PadX

    -- The width that keeps every action on the rows apart from every other
    -- action there is, the ones Cheat Engine knows and the ones on the rows.
    local others = {}
    for index, action in ipairs(PropertiesModule.HotkeyActions) do others[index] = action.Label end
    for _, label in ipairs(labels) do others[#others + 1] = label end
    local apart = 0
    for _, label in ipairs(labels) do apart = math.max(apart, Hotkeys.ApartWidth(label, others)) end
    if apart > 0 then apart = apart + COLUMN_GAP end

    -- The same sum the list painter makes, so the room worked out here is
    -- the room Description really gets.
    local function room()
        local used = pad
        for _, column in ipairs(out) do
            if column.Width > 0 then used = used + math.floor(column.Width * each) + pad end
        end
        return width - used
    end
    local flexible = nil
    for _, column in ipairs(out) do
        if column.Width == 0 then flexible = column end
    end
    if flexible == nil then return out end
    local floor = math.floor((tonumber(flexible.Floor) or 0) * each)

    for _, step in ipairs(Hotkeys.GiveWay) do
        -- The last step only asks for some room, the others for the floor.
        local short = (step.Last and 0 or floor) - room()
        if short <= 0 then break end
        for index, column in ipairs(out) do
            if column.Key == step.Key then
                if step.Drop and single and fit.All ~= true then
                    table.remove(out, index)
                else
                    local least = tonumber(column.Floor) or column.Width
                    if step.To == "Apart" then least = math.max(least, apart) end
                    least = math.min(column.Width, least)
                    column.Width = math.max(least, column.Width - math.ceil(short / each))
                end
                break
            end
        end
    end
    return out
end

--- A text cut to a number of characters, the way the list cuts one. A text
--- that fits stays whole, a longer one keeps what fits before three dots, and
--- a room of three characters or less shows nothing, because the dots alone
--- take all of it.
local function cutTo(text, count)
    text = tostring(text or "")
    if #text <= count then return text end
    if count <= 3 then return "" end
    return text:sub(1, count - 3) .. "..."
end

--
--- ∑ How many characters one action needs before it can be told from every
---   other action once the list has cut them.
---
---   The two long toggles differ only in their last word, so both of them cut
---   to Toggle and three dots read alike, and so does the plain toggle beside
---   them. Every other action differs from the rest within its first letters.
---   Cutting to more characters only ever keeps a longer beginning, so once an
---   action reads apart it stays apart, and the whole action always does.
--- @param label string|nil # The action as the list shows it.
--- @param others table|nil # Every action it could be mistaken for. Without
---        them the actions Cheat Engine knows are taken.
--- @return number # Characters, without the gap after the column.
--
function Hotkeys.ApartWidth(label, others)
    label = tostring(label or "")
    if label == "" then return 0 end
    if others == nil then
        others = {}
        for index, action in ipairs(PropertiesModule.HotkeyActions) do others[index] = action.Label end
    end
    for count = 1, #label - 1 do
        local shown = cutTo(label, count)
        local alone = shown ~= ""
        for _, other in ipairs(others) do
            if alone and other ~= label and cutTo(other, count) == shown then alone = false end
        end
        if alone then return count end
    end
    return #label
end

--- One string that changes whenever a column list would lay out differently.
local function columnMark(columns)
    local parts = {}
    for index, column in ipairs(columns or {}) do
        parts[index] = tostring(column.Key) .. "=" .. tostring(column.Width)
    end
    return table.concat(parts, ",")
end

--
--- ∑ The hotkey object with that id on that record.
---
---   It is looked up again on every use and never kept, because a hotkey
---   wrapper held past a destroy is a use after free, the same as a record
---   wrapper is.
--- @param ce table
--- @param mr userdata
--- @param hotkeyID number
--- @return userdata|nil
--
local function hotkeyOf(ce, mr, hotkeyID)
    if ce == nil or mr == nil then return nil end
    local count = math.tointeger(tonumber(ce:Get(mr, "HotkeyCount")) or 0) or 0
    local holder = ce:Get(mr, "Hotkey")
    if holder == nil then return nil end
    for index = 0, count - 1 do
        local hotkey = ce:Get(holder, index)
        if hotkey ~= nil and math.tointeger(tonumber(ce:Get(hotkey, "ID")) or -1) == hotkeyID then
            return hotkey
        end
    end
    return nil
end

--------------------------------------------------------
--                    Construction                    --
--------------------------------------------------------

--
--- ∑ Builds the page. Nothing is created until Build.
--- @param services table|nil # Theme, Surface, Frame, Grid, Properties, Types,
---        Records, CE, Log and Settings.
--- @return table
--
function Hotkeys:New(services)
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
        NoteLabel = nil,
        ToggleBar = nil,      -- the tool line, All records, the count, Test and Remove
        ToolPanel = nil,      -- the holder Test and Remove sit in
        AllCheck = nil,       -- { Set, Get, Enable, Panel, Parts }
        CountLabel = nil,
        CountText = "",       -- what the count says, whole
        CountShorter = {},    -- shorter ways to say it, for a narrow line
        ListSurface = nil,
        List = nil,           -- the list painter
        ColumnMark = nil,     -- what the columns the list holds were fitted to
        Detail = nil,         -- the fields and the commit bar, under the list
        ActionBar = nil,      -- the commit bar, Only while held down, Revert and Apply
        Inputs = {},          -- field key to { Row, Input, Enable, Parts }
        ActionCombo = nil,
        ValueEdit = nil,
        DescriptionEdit = nil,
        WhileDown = nil,      -- { Set, Get, Enable, Panel, Parts }
        Buttons = {},         -- key to { Control, Enable }
        Laying = false,       -- a layout pass we started ourselves
        Built = false,

        IDs = {},             -- the selection the inspector handed in
        Snapshot = nil,
        All = false,          -- show every hotkey in the table
        Rows = {},            -- what the list is showing
        PlanRows = {},        -- every hotkey in the table, which the columns are fitted to
        Conflicts = {},       -- combination to how many hotkeys hold it
        Scanned = 0,          -- how many hotkeys the last scan found anywhere
        Mark = nil,           -- the fingerprint the last scan was made from
        Refreshes = 0,        -- how many times the window has refreshed this page
        Edits = {},           -- edit key to { ID, HotkeyID, Fields, Old }
        Current = nil,        -- the row the detail strip is on
        Loading = false,      -- a control change we caused ourselves

        Hovered = nil,        -- the row index the mouse is over

        OnCommit = nil,
        OnAct = nil,
        OnStatus = nil,
        --- The inspector assigns these two. The hint goes to the strip at the
        --- bottom of the card while the mouse is over a row that has something
        --- to say, and the guard is the window's busy counter around anything
        --- modal.
        OnHint = nil,
        OnGuard = nil,
        --- The inspector assigns this one as well. The page calls it whenever
        --- its title may have changed, so the header follows a toggle or an
        --- edit at once rather than on the next sync.
        OnTitleChanged = nil
    }, Hotkeys)
end

--- Reports one sentence to the window's status line.
function Hotkeys:Status(text)
    fire(self.OnStatus, text)
    return text
end

--
--- ∑ Creates the controls inside the inspector's page panel.
---
---   The note and the tool line are built in reading order and stacked by
---   slot. The fields and the commit bar share the one panel along the bottom,
---   and the list takes what is left.
--- @param parent userdata
--- @return boolean
--
function Hotkeys:Build(parent)
    local theme = self.Theme
    if theme == nil or parent == nil then return false end
    self.Parent = parent
    local ok, err = pcall(function()
        self.Panel = theme:CreatePanel(parent, { Align = "alClient", ColorKey = "COLOR_INPUT" })
        self.NoteLabel = theme:CreateLabel(self.Panel, Hotkeys.Note, "muted")
        safeSet(self.NoteLabel, "Align", "alTop")
        pcall(function()
            local spacing = self.NoteLabel.BorderSpacing
            spacing.Left, spacing.Right = LEFT_PAD, LEFT_PAD
            spacing.Top, spacing.Bottom = NOTE_TOP, NOTE_BOTTOM
        end)
        stackAt(self.NoteLabel, 1)
        InspectorModule.FitNote(theme, self.NoteLabel, Hotkeys.Note, nil)
        self:BuildTools(theme)
        self:BuildDetail(theme)
        self:BuildList(theme)
        safeSet(self.Panel, "OnResize", function() self:Relayout() end)
    end)
    if not ok then
        say(self, "Warning", "The hotkeys page could not be built whole, " .. tostring(err))
    end
    self.Built = true
    self:Fill()
    return ok
end

--- Hands every field's change to the same place, and ignores the ones the
--- page made itself.
function Hotkeys:Edited()
    if self.Loading then return end
    self:Capture()
    self:AfterEdit()
end

--
--- ∑ The tool line over the list. The toggle that widens the list to the whole
---   table at the left, Test and Remove at the right, and the count between
---   them, cut to what the two leave.
---
---   Test and Remove sit in one holder at the right edge and are placed inside
---   it by hand, so the LCL has a single right aligned control to order and
---   nothing it could swap.
--- @param theme table
--- @return nil
--
function Hotkeys:BuildTools(theme)
    local bar = theme:CreatePanel(self.Panel, {
        Align = "alTop", Height = TOGGLE_HEIGHT, ColorKey = "COLOR_INPUT"
    })
    stackAt(bar, 2)
    self.ToggleBar = bar

    local tools = theme:CreatePanel(bar, {
        Align = "alRight", Width = 2 * BUTTON_WIDTH + BAR_GAP, Height = TOGGLE_HEIGHT,
        ColorKey = "COLOR_INPUT", Spacing = { Right = BAR_RIGHT }
    })
    self.ToolPanel = tools
    local specs = {
        { Key = "Test", Caption = "Test",
          Hint = "Run this hotkey's action now. It asks first, and the action really runs.",
          OnClick = function() self:Test() end },
        { Key = "Remove", Caption = "Remove",
          Hint = "Destroy this hotkey. It asks first, and this cannot be undone.",
          OnClick = function() self:Remove() end }
    }
    for index, spec in ipairs(specs) do
        local control, enable = theme:CreateButton(tools, {
            Caption = spec.Caption, Width = BUTTON_WIDTH, Height = BUTTON_HEIGHT,
            Left = (index - 1) * (BUTTON_WIDTH + BAR_GAP),
            Top = math.floor((TOGGLE_HEIGHT - BUTTON_HEIGHT) / 2),
            Hint = spec.Hint, OnClick = spec.OnClick, Spacing = { Around = 0 }
        })
        self.Buttons[spec.Key] = { Control = control, Enable = enable }
    end

    local panel, setAll, getAll, enableAll, parts = theme:CreateCheck(bar, {
        Caption = "All records", Align = "alLeft", Height = TOGGLE_HEIGHT,
        ColorKey = "COLOR_INPUT", Spacing = { Left = LEFT_PAD - CHECK_LEAD },
        Hint = "Show every hotkey in the table instead of the ones on the selection.",
        OnChange = function(checked)
            if self.Loading then return end
            self.All = checked == true
            self:Rebuild()
        end
    })
    self.AllCheck = { Set = setAll, Get = getAll, Enable = enableAll, Panel = panel, Parts = parts }

    self.CountLabel = theme:CreateLabel(bar, "", "muted")
    safeSet(self.CountLabel, "AutoSize", false)
    safeSet(self.CountLabel, "Align", "alClient")
    safeSet(self.CountLabel, "Layout", "tlCenter")
    safeSet(self.CountLabel, "Alignment", "taLeftJustify")
    pcall(function()
        local spacing = self.CountLabel.BorderSpacing
        spacing.Left, spacing.Right = COUNT_GAP, COUNT_GAP
    end)
    safeSet(bar, "OnResize", function() self:FitCount() end)
end

--
--- ∑ The three field rows and the commit bar under them, in one panel along
---   the bottom.
---
---   The fields are field rows with one label column. Action is a combo box,
---   and Value and Description are edits. The last row keeps no gap of its
---   own, because the commit bar's padding already stands between it and the
---   buttons.
--- @param theme table
--- @return nil
--
function Hotkeys:BuildDetail(theme)
    self.Detail = theme:CreatePanel(self.Panel, {
        Align = "alBottom", ColorKey = "COLOR_INPUT",
        Spacing = { Top = DETAIL_TOP },
        Height = Hotkeys.DetailHeight(BUTTON_HEIGHT + 2 * BAR_PAD)
    })
    self:BuildButtons(theme)

    local labels = {}
    for index, action in ipairs(PropertiesModule.HotkeyActions) do labels[index] = action.Label end
    local fields = {
        { Key = "Action", Label = "Action", Kind = "combo", Items = labels,
          Hint = "What pressing the combination does to the record." },
        { Key = "Value", Label = "Value", Kind = "edit",
          Hint = "The value the Set, Increase and Decrease actions use." },
        { Key = "Description", Label = "Description", Kind = "edit",
          Hint = "What Cheat Engine shows for this hotkey." }
    }
    for index, field in ipairs(fields) do
        local row, input, enable, parts = theme:CreateFieldRow(self.Detail, {
            Label = field.Label, Kind = field.Kind, Items = field.Items, Hint = field.Hint,
            Height = FIELD_HEIGHT,
            Spacing = { Bottom = index < #fields and FIELD_GAP or 0, Right = LEFT_PAD },
            OnChange = function() self:Edited() end
        })
        stackAt(row, index)
        self.Inputs[field.Key] = { Row = row, Input = input, Enable = enable, Parts = parts }
    end
    self.ActionCombo = self.Inputs.Action.Input
    self.ValueEdit = self.Inputs.Value.Input
    self.DescriptionEdit = self.Inputs.Description.Input
end

--- How high the bottom panel is, the field rows with the gaps between them
--- and a commit bar of the given height.
function Hotkeys.DetailHeight(bar)
    return FIELD_ROWS * FIELD_HEIGHT + (FIELD_ROWS - 1) * FIELD_GAP + (tonumber(bar) or 0)
end

--
--- ∑ The commit bar under the fields. Only while held down at the left edge,
---   Revert and Apply at the right, placed by hand whenever the bar changes
---   size. A bar too narrow for both groups puts Revert and Apply on a line of
---   their own under the check.
---
---   The check is a field of the picked hotkey like the three rows above it,
---   and Apply writes it with them. Its box stands where the field labels
---   start.
--- @param theme table
--- @return nil
--
function Hotkeys:BuildButtons(theme)
    local bar = theme:CreatePanel(self.Detail, {
        Align = "alBottom", Height = BUTTON_HEIGHT + 2 * BAR_PAD, ColorKey = "COLOR_INPUT"
    })
    self.ActionBar = bar

    local hint = "The action runs while the combination is held and stops when it is let go."
    local panel, setDown, getDown, enableDown, parts = theme:CreateCheck(bar, {
        Caption = "Only while held down", Height = BUTTON_HEIGHT, Hint = hint,
        ColorKey = "COLOR_INPUT", Spacing = { Around = 0 },
        OnChange = function() self:Edited() end
    })
    self.Inputs.OnlyWhileDown = {
        Row = bar, Input = panel, Enable = enableDown,
        Parts = { Set = setDown, Get = getDown, Check = parts }
    }
    self.WhileDown = {
        Set = setDown, Get = getDown, Enable = enableDown, Panel = panel, Parts = parts
    }

    local specs = {
        { Key = "Revert", Caption = "Revert",
          Hint = "Throw the pending hotkey edits away.",
          OnClick = function() self:Discard() end },
        { Key = "Apply", Caption = "Apply",
          Hint = "Write the edited hotkey fields. This one can be undone.",
          OnClick = function() self:Save() end }
    }
    local left, right = { panel }, {}
    for _, spec in ipairs(specs) do
        local control, enable = theme:CreateButton(bar, {
            Caption = spec.Caption, Width = BUTTON_WIDTH, Height = BUTTON_HEIGHT,
            Hint = spec.Hint, OnClick = spec.OnClick, Spacing = { Around = 0 }
        })
        self.Buttons[spec.Key] = { Control = control, Enable = enable }
        right[#right + 1] = control
    end
    safeSet(bar, "OnResize", function()
        local height = placeGroups(bar, left, right)
        if height ~= nil and readNumber(bar, "Height") ~= height then
            safeSet(bar, "Height", height)
            self:Relayout()
        end
    end)
end

--
--- ∑ The least height the list keeps, its header and a few rows.
---
---   The row height is the one the list measured on its last paint, and the
---   family row height before it painted at all.
--- @return number
--
function Hotkeys:ListFloor()
    local row = LIST_ROW_HEIGHT
    local cache = self.ListSurface ~= nil and self.ListSurface.MetricsCache or nil
    local measured = type(cache) == "table" and tonumber(cache.RowHeight) or nil
    if measured ~= nil and measured > 0 then row = measured end
    return (LIST_ROWS + 1) * row
end

--
--- ∑ Gives the bottom panel the height its fields and its bar need, and the
---   note the lines the page can spare.
---
---   The tool line, the list's header and rows and the bottom panel come
---   first. The note wraps to the page's width and takes as many of its lines
---   as are left, all of them on a tall page, fewer with the rest in its hint
---   on a short one, and none at all when nothing is left. Everything here
---   depends on the page's size and on the bar's height, which depends on the
---   width alone, so a second pass finds nothing to change.
--- @return nil
--
function Hotkeys:Relayout()
    if self.Laying or self.Panel == nil then return end
    self.Laying = true
    pcall(function()
        local bar = readNumber(self.ActionBar, "Height") or (BUTTON_HEIGHT + 2 * BAR_PAD)
        local detail = Hotkeys.DetailHeight(bar)
        if readNumber(self.Detail, "Height") ~= detail then safeSet(self.Detail, "Height", detail) end

        local width = innerWidth(self.Panel)
        local height = innerHeight(self.Panel)
        local lines = nil
        if height ~= nil then
            local _, lineHeight = metricsOf(self.Theme)
            local tools = readNumber(self.ToggleBar, "Height") or TOGGLE_HEIGHT
            local spare = height - tools - self:ListFloor() - DETAIL_TOP - detail
                - NOTE_TOP - NOTE_BOTTOM
            lines = math.max(0, math.floor(spare / lineHeight))
        end
        local text = (lines == nil or lines > 0) and Hotkeys.Note or ""
        local noteHeight = InspectorModule.FitNote(self.Theme, self.NoteLabel, text,
            width and (width - 2 * LEFT_PAD) or nil, lines)
        pcall(function()
            local spacing = self.NoteLabel.BorderSpacing
            local top = noteHeight > 0 and NOTE_TOP or 0
            local bottom = noteHeight > 0 and NOTE_BOTTOM or 0
            if tonumber(spacing.Top) ~= top then spacing.Top = top end
            if tonumber(spacing.Bottom) ~= bottom then spacing.Bottom = bottom end
        end)
    end)
    self.Laying = false
end

--
--- ∑ Puts the count on the tool line in the room the toggle and the two
---   buttons leave.
---
---   The whole count first, then the shorter ways of saying it, and the
---   shortest cut to fit when none of them fits whole. Anything but the whole
---   count carries the whole count in its hint.
--- @return string # What the line shows.
--
function Hotkeys:FitCount()
    local label, text = self.CountLabel, self.CountText or ""
    if label == nil then return text end
    local width = innerWidth(self.ToggleBar)
    local theme = self.Theme
    if width == nil or theme == nil or type(theme.FitText) ~= "function" then
        safeSet(label, "Caption", text)
        return text
    end
    local check = readNumber(self.AllCheck and self.AllCheck.Panel, "Width") or 0
    local tools = readNumber(self.ToolPanel, "Width") or 0
    local room = math.max(0,
        width - (LEFT_PAD - CHECK_LEAD) - check - tools - BAR_RIGHT - 2 * COUNT_GAP)
    local charWidth = metricsOf(theme)
    local candidates = { text }
    for _, shorter in ipairs(self.CountShorter or {}) do candidates[#candidates + 1] = shorter end
    local chosen = candidates[#candidates]
    for _, candidate in ipairs(candidates) do
        if textLength(candidate) * charWidth <= room then
            chosen = candidate
            break
        end
    end
    local ok, shown = pcall(theme.FitText, theme, label, chosen, room)
    if not ok then
        safeSet(label, "Caption", text)
        return text
    end
    if shown ~= text then
        safeSet(label, "Hint", text)
        safeSet(label, "ShowHint", true)
    end
    return shown
end

--- The list itself, which takes whatever room the bars and the strip left.
function Hotkeys:BuildList(theme)
    local surface = self.SurfaceClass:New({
        Theme = theme, Log = self.Log, Settings = self.Settings,
        Frame = self.Frame, Name = "Hotkeys"
    })
    self.ListSurface = surface
    self.List = surface:ListPainter({
        Header = true,
        Columns = Hotkeys.Columns,
        OnPick = function(item) self:Pick(item) end,
        OnOpen = function() self:FocusValue() end
    })
    self.List:SetEmpty("No hotkeys", Hotkeys.Note)
    -- The columns are fitted to the width the list paints at, with the
    -- measured character, right before every frame. A frame whose columns
    -- changed asks for no second one, because the list reads them in this
    -- very frame.
    local paint = surface.Painter
    surface:SetPainter(function(owner, canvas, width, height, colors, metrics)
        pcall(self.FitColumns, self, width, height, metrics)
        if paint ~= nil then paint(owner, canvas, width, height, colors, metrics) end
    end)
    -- The list painter takes the mouse move for its own hover, so the hint has
    -- to be reported from a handler that does both.
    surface.OnMouseMove = function(x, y)
        self.List:MouseMove(x, y)
        self:Hover(self.List.Hover)
    end
    surface.OnMouseLeave = function()
        self.List:MouseLeave()
        self:Hover(nil)
    end
    local ok, reason = surface:Attach(self.Panel)
    if not ok then
        say(self, "Warning", "The hotkey list has no canvas, " .. tostring(reason))
        return
    end
    -- The list keeps the page edge on both sides, like the note over it and
    -- the fields under it.
    pcall(function()
        local spacing = surface.Control.BorderSpacing
        spacing.Left, spacing.Right = LEFT_PAD, LEFT_PAD
    end)
end

--
--- ∑ Fits the list's columns to the table's hotkeys and the list's width.
---
---   Without a size it asks the list for the one it has, and without metrics
---   it takes the ones the list measured on its last frame, or the theme's
---   before the first. The scroll bar comes off the width whenever the rows do
---   not all fit, the way the list works it out. The list is only handed new
---   columns when they differ, because that repaints it.
--- @param width number|nil
--- @param height number|nil
--- @param metrics table|nil # CharWidth and RowHeight.
--- @return table|nil # The columns, or nil without a list.
--
function Hotkeys:FitColumns(width, height, metrics)
    local list, surface = self.List, self.ListSurface
    if list == nil then return nil end
    width, height = tonumber(width), tonumber(height)
    if (width == nil or height == nil) and surface ~= nil then
        local ok, w, h = pcall(surface.Size, surface)
        if ok then width, height = width or w, height or h end
    end
    if type(metrics) ~= "table" and surface ~= nil then metrics = surface.MetricsCache end
    local charWidth = type(metrics) == "table" and tonumber(metrics.CharWidth) or nil
    if charWidth == nil or charWidth <= 0 then charWidth = metricsOf(self.Theme) end
    local rowHeight = type(metrics) == "table" and tonumber(metrics.RowHeight) or nil
    if rowHeight == nil or rowHeight <= 0 then rowHeight = LIST_ROW_HEIGHT end
    local room = nil
    if width ~= nil and width > 0 then
        room = width
        if height ~= nil and height > 0 then
            local scroll = SurfaceModule.Scroll
            local visible = scroll.Visible(height - rowHeight, rowHeight)
            room = width - scroll.Strip(#self.Rows, visible)
        end
    end
    -- Every hotkey in the table plans the columns, and the selection says
    -- whether the list names one record, so neither changes with the rows
    -- the list happens to show.
    local columns = Hotkeys.ColumnsFor(self.PlanRows or self.Rows, {
        Width = room, CharWidth = charWidth, All = self.All, Single = #self.IDs <= 1
    })
    local mark = columnMark(columns)
    if mark ~= self.ColumnMark then
        self.ColumnMark = mark
        list:SetColumns(columns)
    end
    return columns
end

--------------------------------------------------------
--                Reading the hotkeys                 --
--------------------------------------------------------

--
--- ∑ Reads every hotkey in the table once and builds both the conflict map and
---   the rows the list shows.
---
---   The whole table is read even when only a selection is shown, because the
---   conflict a person needs to find is the one with a hotkey they are not
---   looking at. Only records whose HotkeyCount is above zero are resolved, so
---   a table without hotkeys costs one pass over the snapshot and no Cheat
---   Engine call at all.
---
---   Every hotkey found becomes a row, and those rows are what the columns
---   are planned from. The rows the list shows are the same tables, so an
---   edit shown on the list is part of the plan as well.
--- @return table, table # The rows for the current view, and the conflict map.
--
function Hotkeys:Scan()
    local rows, conflicts, found, plan = {}, {}, 0, {}
    self.PlanRows = plan
    local snapshot, records, properties = self.Snapshot, self.Records, self.Properties
    if snapshot == nil or records == nil or properties == nil then
        self.Scanned = 0
        return rows, conflicts
    end
    -- The count lives in the detail pass, so a node that was never read would
    -- look like a record without hotkeys.
    if type(records.EnsureDetail) == "function" then
        pcall(records.EnsureDetail, records, snapshot, nil)
    end
    local wanted = {}
    for _, id in ipairs(self.IDs) do wanted[id] = true end

    local all = {}
    for _, node in ipairs(snapshot.Order) do
        -- The count comes from the detail pass, which may not have come round
        -- again since somebody added a hotkey in Cheat Engine. A selected
        -- record is therefore read whatever its count says, because that is
        -- the record the person is looking at.
        if (node.HotkeyCount or 0) > 0 or wanted[node.ID] then
            local mr = records:Resolve(node.ID, snapshot)
            if mr ~= nil then
                for _, hotkey in ipairs(properties:ReadHotkeys(mr)) do
                    found = found + 1
                    local combo = Hotkeys.ComboOf(hotkey.Keys)
                    if combo ~= "" then conflicts[combo] = (conflicts[combo] or 0) + 1 end
                    all[#all + 1] = { Node = node, Hotkey = hotkey, Combo = combo }
                end
            end
        end
    end
    for _, entry in ipairs(all) do
        self:Settle(entry)
        local row = self:RowOf(entry, conflicts)
        plan[#plan + 1] = row
        if self.All or wanted[entry.Node.ID] then rows[#rows + 1] = row end
    end
    self.Scanned = found
    return rows, conflicts
end

--- What a hotkey really holds, in the fields this page edits.
local function originalOf(hotkey)
    return {
        Value = hotkey.Value,
        Description = hotkey.Description,
        Action = hotkey.ActionNumber,
        OnlyWhileDown = hotkey.OnlyWhileDown == true
    }
end

--
--- ∑ Drops the pending fields of one hotkey that it already holds.
---
---   A field that asks for what the hotkey holds writes nothing, which is how
---   the current row's edit already works while somebody types. Applying is
---   where it matters most. The window writes the fields, reads the table
---   again and asks for the header, so the fields that landed are gone by
---   then and the header has no star. A field that was refused still differs
---   and stays.
--- @param entry table # Node and Hotkey, as Scan reads them.
--- @return nil
--
function Hotkeys:Settle(entry)
    local key = editKey(entry.Node.ID, entry.Hotkey.ID)
    local edit = self.Edits[key]
    if edit == nil then return end
    local held = originalOf(entry.Hotkey)
    for name, value in pairs(edit.Fields) do
        if held[name] == value then
            edit.Fields[name] = nil
            edit.Old[name] = nil
        end
    end
    if next(edit.Fields) == nil then self.Edits[key] = nil end
end

--
--- ∑ One list row, with the pending edits of that hotkey already shown in it.
---
---   A row shows what would be written and not only what is stored, so a
---   person can see several pending edits at once before applying them.
--- @param entry table # Node, Hotkey and Combo.
--- @param conflicts table
--- @return table
--
function Hotkeys:RowOf(entry, conflicts)
    local hotkey, node = entry.Hotkey, entry.Node
    local pending = self.Edits[editKey(node.ID, hotkey.ID)]
    local fields = pending and pending.Fields or {}
    local combo = entry.Combo
    local clash = combo ~= "" and (conflicts[combo] or 0) > 1
    local action = fields.Action or hotkey.ActionNumber
    local label = hotkey.ActionLabel
    for _, known in ipairs(PropertiesModule.HotkeyActions) do
        if known.Number == action then label = known.Label end
    end
    local keysText = hotkey.KeysText
    if keysText == nil or keysText == "" then
        local ce = self.CE
        keysText = ce ~= nil and ce:KeyComboText(hotkey.Keys) or ""
    end
    if keysText == "" then keysText = "no keys" end
    return {
        ID = node.ID,
        HotkeyID = hotkey.ID,
        Keys = keysText,
        Combo = combo,
        Conflict = clash,
        Action = label,
        Value = fields.Value or hotkey.Value,
        Record = node.Description ~= nil and node.Description ~= "" and node.Description
            or ("#" .. tostring(node.ID)),
        Description = fields.Description or hotkey.Description,
        OnlyWhileDown = fields.OnlyWhileDown,
        Pending = pending ~= nil,
        ColorKeys = colorsFor(fields, clash),
        -- What the record really holds right now, which is what a pending edit
        -- is compared against and what undo puts back.
        Original = originalOf(hotkey)
    }
end

--
--- ∑ Shows a selection.
--- @param ids table|nil
--- @param snapshot table|nil
--- @return nil
--
function Hotkeys:Show(ids, snapshot)
    local same = self:SameSelection(ids)
    self.IDs = {}
    for index, id in ipairs(ids or {}) do self.IDs[index] = id end
    self.Snapshot = snapshot
    if not same and next(self.Edits) ~= nil then
        -- A pending edit names a record and a hotkey by id, so it survives a
        -- selection change. It only leaves the list while All is off.
        self:Status("The pending hotkey edits are still there, Apply writes them.")
    end
    self:Rebuild()
end

--- Whether the ids handed in name the same records the page is already on.
function Hotkeys:SameSelection(ids)
    local given = ids or {}
    if #given ~= #self.IDs then return false end
    for index, id in ipairs(given) do
        if self.IDs[index] ~= id then return false end
    end
    return true
end

--
--- ∑ A number that changes when the table gained or lost a hotkey.
---
---   The snapshot carries the count per record and nothing else about a
---   hotkey, so this notices one being added or removed and cannot notice a
---   value being edited in Cheat Engine. That is what the counted rescan below
---   is for.
--- @return number
--
function Hotkeys:Fingerprint()
    local snapshot = self.Snapshot
    if snapshot == nil then return 0 end
    local mark = tonumber(snapshot.Signature) or 0
    for _, node in ipairs(snapshot.Order) do
        local count = node.HotkeyCount or 0
        if count > 0 then mark = mark + count * 31 + node.ID end
    end
    return mark
end

--- Whether a change list names a record this page is showing. A list carries
--- the id as the value and a set carries it as the key.
function Hotkeys:Touches(changedIds)
    if type(changedIds) ~= "table" then return true end
    local wanted = {}
    for _, row in ipairs(self.Rows) do wanted[row.ID] = true end
    for _, id in ipairs(self.IDs) do wanted[id] = true end
    for key, value in pairs(changedIds) do
        if type(value) == "number" then
            if wanted[value] then return true end
        elseif value == true and wanted[key] then
            return true
        end
    end
    return false
end

--
--- ∑ Re-reads after a sync or a commit. A pending edit is never overwritten,
---   because it is held by id and applied over whatever was read.
---
---   Reading every hotkey in the table is the one expensive thing this page
---   does, and the live sync calls this several times a second. So it happens
---   when a hotkey was added or removed, when the change names a record on
---   screen, and otherwise only every few refreshes, which is what picks an
---   edit made inside Cheat Engine up without paying for it on every tick.
--- @param snapshot table|nil
--- @param changedIds table|nil
--- @return boolean # Whether it read the table again.
--
function Hotkeys:Refresh(snapshot, changedIds)
    self.Snapshot = snapshot or self.Snapshot
    self.Refreshes = self.Refreshes + 1
    local mark = self:Fingerprint()
    if mark == self.Mark
        and self.Refreshes % SCAN_EVERY ~= 0
        and not self:Touches(changedIds) then
        return false
    end
    self.Mark = mark
    self:Rebuild()
    return true
end

--- Reads the table again and puts the list and the strip back the way they
--- were, on the same row when that row is still there.
function Hotkeys:Rebuild()
    local wasOn = self.Current
    local rows, conflicts = self:Scan()
    self.Rows, self.Conflicts = rows, conflicts
    self.Mark = self:Fingerprint()
    if self.List ~= nil then
        -- The columns change only when the rows need other widths, because
        -- every change repaints the list and a sync rebuilds it several times
        -- a second.
        self:FitColumns()
        self.List:SetItems(rows)
    end
    local index = nil
    if wasOn ~= nil then
        for position, row in ipairs(rows) do
            if row.ID == wasOn.ID and row.HotkeyID == wasOn.HotkeyID then
                index = position
                break
            end
        end
    end
    if index == nil and #rows > 0 then index = 1 end
    self.Current = index ~= nil and rows[index] or nil
    if self.List ~= nil and index ~= nil then self.List:Select(index, true) end
    self:Fill()
end

--------------------------------------------------------
--                    The controls                    --
--------------------------------------------------------

--- The two lines a list with nothing in it shows, which depend on whether the
--- table has hotkeys at all.
function Hotkeys:ApplyEmpty()
    if self.List == nil then return end
    if self.All then
        self.List:SetEmpty("No hotkeys in this table",
            "Cheat Engine adds them from a record's own hotkey window.")
        return
    end
    if self.Scanned > 0 then
        self.List:SetEmpty("No hotkeys on the selection",
            "Turn All records on to see the " .. self.Scanned .. " in the table.")
        return
    end
    self.List:SetEmpty("No hotkeys in this table",
        "Cheat Engine adds them from a record's own hotkey window.")
end

--- Writes the current row into the detail strip and puts every button into the
--- state it belongs in.
function Hotkeys:Fill()
    if not self.Built then return end
    self:ApplyEmpty()
    local row = self.Current
    local pending = row ~= nil and self.Edits[editKey(row.ID, row.HotkeyID)] or nil
    local fields = pending and pending.Fields or {}

    self.Loading = true
    if self.AllCheck ~= nil then self.AllCheck.Set(self.All, true) end
    if row == nil then
        setText(self.ValueEdit, "")
        setText(self.DescriptionEdit, "")
        safeSet(self.ActionCombo, "ItemIndex", -1)
        if self.WhileDown ~= nil then self.WhileDown.Set(false, true) end
    else
        setText(self.ValueEdit, fields.Value or row.Original.Value)
        setText(self.DescriptionEdit, fields.Description or row.Original.Description)
        local action = fields.Action or row.Original.Action
        local index = -1
        for position, known in ipairs(PropertiesModule.HotkeyActions) do
            if known.Number == action then index = position - 1 end
        end
        safeSet(self.ActionCombo, "ItemIndex", index)
        local down = fields.OnlyWhileDown
        if down == nil then down = row.Original.OnlyWhileDown end
        if self.WhileDown ~= nil then self.WhileDown.Set(down == true, true) end
    end
    self.Loading = false

    local live = row ~= nil
    self:EnableField("Value", live)
    self:EnableField("Description", live)
    -- An action Cheat Engine named in a way this build does not know cannot be
    -- offered as a choice, because writing one back would be a guess.
    self:EnableField("Action", live and row.Original.Action ~= nil)
    self:EnableField("OnlyWhileDown", live)
    self:UpdateButtons()
    self:UpdateCount()
end

--- Turns one field on or off, frame and all. A field that was not built
--- falls back to the bare control.
function Hotkeys:EnableField(key, value)
    local field = self.Inputs[key]
    if field == nil then return false end
    if type(field.Enable) == "function" then
        pcall(field.Enable, value == true)
    else
        safeSet(field.Input, "Enabled", value == true)
    end
    return true
end

--
--- ∑ The count beside the All records toggle, which says what the list is
---   showing, how much of the table it left out and how many conflicts it
---   holds.
---
---   Two shorter ways of saying it go with it, for a tool line too narrow for
---   the whole sentence. The conflicts are what a person comes to this page
---   for, so the shortest one keeps them and drops the rest.
--- @return string # The whole count.
--
function Hotkeys:UpdateCount()
    local shown = #self.Rows
    local what = shown == 1 and "1 hotkey" or (shown .. " hotkeys")
    local part = nil
    if not self.All and self.Scanned > shown then
        part = shown .. " of " .. self.Scanned
        what = what .. " of " .. self.Scanned
    end
    local clashes = self:ConflictCount()
    local shorter = {}
    local text = what
    if clashes > 0 then
        local said = clashes .. (clashes == 1 and " conflict" or " conflicts")
        text = what .. ", " .. said
        if part ~= nil then shorter[#shorter + 1] = part .. ", " .. said end
        shorter[#shorter + 1] = said
    elseif part ~= nil then
        shorter[#shorter + 1] = part
    end
    self.CountText, self.CountShorter = text, shorter
    self:FitCount()
    return text
end

--- How many of the shown rows hold a combination somebody else holds too.
function Hotkeys:ConflictCount()
    local count = 0
    for _, row in ipairs(self.Rows) do
        if row.Conflict then count = count + 1 end
    end
    return count
end

--- Turns the four buttons on and off from what is selected and what is
--- pending, and has the header say the title that goes with it. This runs
--- after every edit and every rebuild, which are the two things that change
--- the title between two syncs.
function Hotkeys:UpdateButtons()
    local dirty = self:IsDirty()
    local live = self.Current ~= nil
    local function set(key, enabled)
        local button = self.Buttons[key]
        if button ~= nil then button.Enable(enabled) end
    end
    set("Apply", dirty)
    set("Revert", dirty)
    set("Test", live)
    set("Remove", live)
    fire(self.OnTitleChanged)
end

--
--- ∑ Reports what the row under the mouse has to say, which the inspector
---   shows in the strip at the bottom of its card while the mouse is there.
---
---   A conflict is the one thing on this page a person cannot work out from
---   the row itself, because the hotkey it clashes with may be on a record
---   that is not even in the list.
--- @param index number|nil # The row the mouse is over.
--- @return nil
--
function Hotkeys:Hover(index)
    if index == self.Hovered then return end
    self.Hovered = index
    local row = index ~= nil and self.Rows[index] or nil
    if row == nil or not row.Conflict then
        fire(self.OnHint, nil)
        return
    end
    fire(self.OnHint, "Another hotkey in this table holds " .. row.Keys
        .. " as well. Both of them fire.")
end

--- Moves the detail strip onto the row somebody picked.
function Hotkeys:Pick(item)
    self.Current = item
    self:Fill()
end

--- Puts the caret in the Value box, which is what opening a row is for.
function Hotkeys:FocusValue()
    if self.ValueEdit == nil then return false end
    return (pcall(function() self.ValueEdit.setFocus() end))
end

--------------------------------------------------------
--                 The pending edits                  --
--------------------------------------------------------

--
--- ∑ Reads the detail strip back into the pending edit of the current row.
---
---   A field that was put back to what the record holds drops out of the edit,
---   and an edit with nothing left in it drops out altogether, so typing a
---   change and typing it back leaves the page clean.
--- @return table|nil # The pending edit, when there is one.
--
function Hotkeys:Capture()
    local row = self.Current
    if not self.Built or row == nil then return nil end
    local wanted = {}
    local value = safeGet(self.ValueEdit, "Text")
    if type(value) == "string" then wanted.Value = value end
    local description = safeGet(self.DescriptionEdit, "Text")
    if type(description) == "string" then wanted.Description = description end
    if row.Original.Action ~= nil then
        local index = math.tointeger(tonumber(safeGet(self.ActionCombo, "ItemIndex")) or -1) or -1
        local action = PropertiesModule.HotkeyActions[index + 1]
        if action ~= nil then wanted.Action = action.Number end
    end
    if self.WhileDown ~= nil then wanted.OnlyWhileDown = self.WhileDown.Get() == true end

    local key = editKey(row.ID, row.HotkeyID)
    local fields, old, count = {}, {}, 0
    for _, name in ipairs(Hotkeys.Fields) do
        local held = row.Original[name]
        if wanted[name] ~= nil and wanted[name] ~= held then
            fields[name] = wanted[name]
            old[name] = held
            count = count + 1
        end
    end
    if count == 0 then
        self.Edits[key] = nil
        return nil
    end
    local edit = { ID = row.ID, HotkeyID = row.HotkeyID, Fields = fields, Old = old }
    self.Edits[key] = edit
    return edit
end

--- What one edit costs. The row text follows the pending edit and the buttons
--- follow whether there is one.
function Hotkeys:AfterEdit()
    local row = self.Current
    if row ~= nil then
        local pending = self.Edits[editKey(row.ID, row.HotkeyID)]
        local fields = pending and pending.Fields or {}
        row.Value = fields.Value or row.Original.Value
        row.Description = fields.Description or row.Original.Description
        row.Pending = pending ~= nil
        local action = fields.Action or row.Original.Action
        for _, known in ipairs(PropertiesModule.HotkeyActions) do
            if known.Number == action then row.Action = known.Label end
        end
        row.ColorKeys = colorsFor(fields, row.Conflict)
        if self.ListSurface ~= nil then self.ListSurface:Invalidate() end
    end
    self:UpdateButtons()
end

function Hotkeys:IsDirty()
    self:Capture()
    return next(self.Edits) ~= nil
end

--- How many hotkeys and how many fields are waiting to be written.
function Hotkeys:PendingCount()
    local hotkeys, fields = 0, 0
    for _, edit in pairs(self.Edits) do
        hotkeys = hotkeys + 1
        for _ in pairs(edit.Fields) do fields = fields + 1 end
    end
    return hotkeys, fields
end

--- The label one transaction carries.
function Hotkeys:LabelFor(changes)
    if #changes == 1 then
        local change = changes[1]
        local node = self.Snapshot and self.Snapshot.ByID[change.ID] or nil
        local name = node and node.Description or ""
        local what = "Hotkey " .. string.lower(change.Key)
        if name ~= "" then return what .. " on " .. quoted(name) end
        return what
    end
    local hotkeys = self:PendingCount()
    return "Hotkey changes on " .. hotkeys .. (hotkeys == 1 and " hotkey" or " hotkeys")
end

--
--- ∑ Hands the pending edits up as one transaction, one change per field.
---
---   One change per field and not one per hotkey, because the window's applier
---   writes a hotkey field at a time and undo has to put each field back on
---   its own.
--- @return boolean # Whether the page is clean afterwards.
--
function Hotkeys:Save()
    self:Capture()
    if next(self.Edits) == nil then
        self:Status("There is nothing to apply.")
        return true
    end
    if type(self.OnCommit) ~= "function" then
        self:Status("This page is not wired to a window, nothing was written.")
        return false
    end
    local changes = {}
    for _, row in ipairs(self.Rows) do
        local edit = self.Edits[editKey(row.ID, row.HotkeyID)]
        if edit ~= nil then
            for _, key in ipairs(Hotkeys.Fields) do
                if edit.Fields[key] ~= nil then
                    changes[#changes + 1] = {
                        Kind = "hotkey", ID = edit.ID, HotkeyID = edit.HotkeyID,
                        Key = key, Old = edit.Old[key], New = edit.Fields[key]
                    }
                end
            end
        end
    end
    if #changes == 0 then
        -- Every pending edit belongs to a hotkey the list no longer shows,
        -- which only happens after somebody narrowed the view.
        self:Status("The edited hotkeys are not in the list any more.")
        return false
    end
    local tx = { Label = self:LabelFor(changes), Changes = changes }
    local ok, applied, failures = fire(self.OnCommit, tx)
    applied = tonumber(applied) or 0
    if ok == true and applied > 0 then
        self.Edits = {}
        self:Rebuild()
        return true
    end
    local failed = type(failures) == "table" and #failures or 0
    self:Status(failed > 0
        and ("The hotkey change was refused " .. failed .. (failed == 1 and " time." or " times."))
        or "The hotkey change was not applied.")
    return false
end

--- Throws the pending edits away and puts the strip back to what the hotkeys
--- hold.
function Hotkeys:Discard()
    self.Edits = {}
    self:Rebuild()
    self:Status("The pending hotkey edits were dropped.")
end

--------------------------------------------------------
--                  The two actions                   --
--------------------------------------------------------

--- The record and the hotkey of the current row, resolved fresh.
function Hotkeys:Resolve(row)
    local records, ce = self.Records, self.CE
    if row == nil or records == nil or ce == nil then return nil, nil end
    local mr = records:Resolve(row.ID, self.Snapshot)
    if mr == nil then return nil, nil end
    return mr, hotkeyOf(ce, mr, row.HotkeyID)
end

--
--- ∑ Runs the hotkey's action for real, after asking.
---
---   The confirmation happens inside the action the window runs, because a
---   dialog runs a message loop of its own and the window's Busy counter is
---   what keeps its timers out of that loop.
--- @return boolean
--
function Hotkeys:Test()
    local row = self.Current
    if row == nil then
        self:Status("Pick a hotkey first.")
        return false
    end
    if type(self.OnAct) ~= "function" then
        self:Status("This page is not wired to a window, nothing was run.")
        return false
    end
    local ce = self.CE
    local label = "Test hotkey " .. row.Keys
    local ok = fire(self.OnAct, label, { row.ID }, function()
        if ce == nil then return false, "Cheat Engine is not available." end
        local agreed = ce:Confirm("Run the hotkey action " .. quoted(row.Action)
            .. " on " .. quoted(row.Record) .. " now.", 1, TEST_NOTE)
        if not agreed then return false, "Nothing was run." end
        local _, hotkey = self:Resolve(row)
        if hotkey == nil then return false, "The hotkey is gone." end
        local run = ce:Get(hotkey, "doHotkey")
        if type(run) ~= "function" then return false, "This build cannot run a hotkey." end
        local ran = pcall(run)
        if not ran then return false, "Cheat Engine refused to run the hotkey." end
        return true
    end)
    if ok == true then
        self:Status("Ran " .. quoted(row.Action) .. " on " .. quoted(row.Record) .. ".")
        return true
    end
    self:Status("The hotkey was not run.")
    return false
end

--
--- ∑ Destroys the hotkey, after asking. There is no way back, which the
---   confirmation and the button hint both say.
--- @return boolean
--
function Hotkeys:Remove()
    local row = self.Current
    if row == nil then
        self:Status("Pick a hotkey first.")
        return false
    end
    if type(self.OnAct) ~= "function" then
        self:Status("This page is not wired to a window, nothing was removed.")
        return false
    end
    local ce = self.CE
    local label = "Remove hotkey " .. row.Keys
    local ok = fire(self.OnAct, label, { row.ID }, function()
        if ce == nil then return false, "Cheat Engine is not available." end
        local agreed = ce:Confirm("Remove the hotkey " .. row.Keys .. " from "
            .. quoted(row.Record) .. ".", 1, REMOVE_NOTE)
        if not agreed then return false, "Nothing was removed." end
        local _, hotkey = self:Resolve(row)
        if hotkey == nil then return false, "The hotkey is gone." end
        local destroy = ce:Get(hotkey, "destroy")
        if type(destroy) ~= "function" then return false, "This build cannot remove a hotkey." end
        local gone = pcall(destroy)
        if not gone then return false, "Cheat Engine refused to remove the hotkey." end
        return true
    end)
    if ok == true then
        self.Edits[editKey(row.ID, row.HotkeyID)] = nil
        self.Current = nil
        self:Rebuild()
        self:Status("Removed the hotkey " .. row.Keys .. " from " .. quoted(row.Record) .. ".")
        return true
    end
    self:Status("The hotkey was not removed.")
    return false
end

--------------------------------------------------------
--                    The keyboard                    --
--------------------------------------------------------

--
--- ∑ The keys the list answers. A canvas never takes focus, so the window
---   feeds them in.
---
---   The window cannot tell the fields from the list, so the page does. While
---   the combo box or one of the edits has the keyboard every key is left to
---   it, which is where Home moves the caret and the arrows pick an action.
--- @param key number
--- @return boolean
--
function Hotkeys:HandleKey(key)
    if self.List == nil then return false end
    for _, name in ipairs({ "Action", "Value", "Description" }) do
        local field = self.Inputs[name]
        if field ~= nil and hasFocus(field.Input) then return false end
    end
    return self.List:HandleKey(key) == true
end

--------------------------------------------------------
--                Titles and teardown                 --
--------------------------------------------------------

--
--- ∑ What the inspector header shows while this page is up.
--- @return string
--
function Hotkeys:Title()
    local mark = self:IsDirty() and " *" or ""
    local shown = #self.Rows
    if shown == 0 then return "No hotkeys" .. mark end
    local what = shown == 1 and "1 hotkey" or (shown .. " hotkeys")
    if self.All then return what .. " in the table" .. mark end
    local records = #self.IDs
    if records == 1 then return what .. " on one record" .. mark end
    return what .. " on " .. records .. " records" .. mark
end

--- Releases the canvas and forgets the controls. The panels belong to the
--- inspector card and are freed with it.
function Hotkeys:Destroy()
    if self.ListSurface ~= nil then
        self.ListSurface:Destroy()
        self.ListSurface = nil
    end
    self.List, self.ColumnMark = nil, nil
    self.Buttons, self.Inputs = {}, {}
    self.ActionCombo, self.ValueEdit, self.DescriptionEdit = nil, nil, nil
    self.WhileDown, self.AllCheck = nil, nil
    self.Detail, self.NoteLabel, self.CountLabel = nil, nil, nil
    self.ToggleBar, self.ActionBar, self.CountText = nil, nil, ""
    self.ToolPanel, self.CountShorter = nil, {}
    self.Panel, self.Parent = nil, nil
    self.Rows, self.Conflicts, self.Edits = {}, {}, {}
    self.PlanRows = {}
    self.Current, self.Snapshot = nil, nil
    self.IDs, self.Scanned = {}, 0
    self.Mark, self.Hovered = nil, nil
    self.Built = false
end

return Hotkeys
