--[[
    The pointer page, where one record's pointer chain is read and rewritten.

    Cheat Engine stores a chain the other way round from the way a person walks
    it. Offset zero is applied LAST and the highest offset is applied to the
    base FIRST, which is why Cheat Engine's own pointer dialog draws the first
    dereference at the bottom of its list. This page shows the chain in the
    order it is walked, so row one is the first dereference, and it turns the
    list round again on the way out. Nothing else in the segment has to know
    about that, because the only two places the two orders meet are Reverse and
    Properties.WritePointer.

    Every level row carries three facts. The offset text, the pointer value read
    at that level and the address that level resolves to. A read that fails
    shows two question marks, and so does every level under it, because there is
    no address left to read from. The last row is what Cheat Engine calls
    CurrentAddress.

    The offsets are counted in Lua before anything is read. Offset and
    OffsetText are indexed tables with no bounds check behind them, and an index
    Cheat Engine does not have dereferences nil inside Pascal. That is an access
    violation and not a Lua error, so pcall never sees it and the process goes
    down with it. Everything here walks the buffer this page owns and never asks
    Cheat Engine for a level that is not there.

    The page writes nothing into a record. Apply builds one pointer change and
    hands it up through OnCommit, and the buffer is cleared only when the commit
    came back ok with something applied. One change and not one per level,
    because a half written chain points at nothing and there would be no way
    back from it.

    Reading the base through getAddressSafe and each level through readPointer
    is how the live values are found. Neither of the two raises, both answer nil
    when there is nothing there, and neither writes anything, so the whole row
    list is safe to rebuild on every keystroke.

    The address a chain resolves to is the thing a person most often wants to
    take somewhere else, so it can be copied three ways. The Copy button beside
    it, Copy address on the level list's right click menu, and Ctrl and C while
    the list has the keyboard, which copies the level that is picked. The list
    is a canvas and never takes the focus, so the window hands it the keys, and
    a key pressed while one of this page's text boxes has the focus is left to
    that box.

    Nothing on the page is laid out by alignment alone where alignment can go
    wrong. The level buttons sit in a flow bar that wraps them onto a second
    line instead of sliding them under each other, and their captions are
    short enough to share one line on the narrowest window. A second line
    there is what left the level list room for one level of three. Apply and
    Revert are the only thing along the bottom and are placed from the right
    edge by hand. The rows above the list are stacked by a Top far apart per
    slot, because the LCL orders top aligned controls by their Top and a tie
    goes to whichever control was touched last.

    The base row shares its width between the base box and a muted note that
    says where the base resolves to. The box comes first, with the larger
    share of the row and all of a longer base a person typed, and the note is
    the part that is cut, with the whole address in its hint.
]]

local SurfaceModule = require("Manifold-AddressList-Surface")
local TypesModule = require("Manifold-AddressList-Types")

local Pointer = {}
Pointer.__index = Pointer

--- What the inspector calls this page and what its tab says.
Pointer.Key = "Pointer"
Pointer.Caption = "Pointer"

--
--- ∑ The numbers this page measures itself against.
--
--- A chain longer than this is a mistake rather than a pointer. Cheat Engine
--- names no limit, so this is a sanity bound and not a Cheat Engine one.
local MAX_LEVELS = 32

--- What a new level starts as. Zero is a valid offset and it reads back the
--- pointer itself, which is what a person wants to see before typing.
local DEFAULT_OFFSET = "0"

--- What a level that cannot be read shows. Two question marks is what Cheat
--- Engine itself puts in its value column.
local UNREADABLE = "??"

--- Virtual key codes. The window hands a raw code in, so the modifiers are read
--- back through Cheat Engine rather than arriving with the key.
local VK_CONTROL = 17
local VK_RETURN = 13
local VK_C = 0x43
local VK_S = 0x53

--- How far apart the stacked rows are given their Top, so no two of them can
--- ever tie, whatever the page has been laid out to before.
local STACK_STEP = 10000

--- The space every row, bar and list keeps from the page's left and right
--- sides. The labels and the level buttons start on it, and the frames, Copy,
--- the level list and Apply all end on it, so both edges run straight down the
--- page.
local PAGE_EDGE = 6

--- A button's height on the bars, the space between two of them, the space
--- over and under a bar's lines, and the least that stands between two groups
--- sharing a line. A bar's two ends are the page edge.
local BUTTON_HEIGHT, BAR_GAP, BAR_PAD, BAR_SPLIT = 26, 6, 5, 18

--- The height of a field row. Copy is given the same height, so its top and
--- bottom edges carry on the frame's beside it.
local FIELD_HEIGHT = 28

--- The width of Apply and Revert, and of the Copy button beside the resolved
--- address. Every button along the bottom of a page has this width, which is
--- what lets four of them share one line on the narrowest page.
local BUTTON_WIDTH, COPY_WIDTH = 64, 64

--- The label column of a field row, the least the base box keeps, and the
--- space in front of the note beside it.
local LABEL_COLUMN, BASE_FRAME_MIN, BASE_NOTE_GAP = 104, 100, 6

--- The share of the base row the base box takes at least, once the label
--- column is off it. The note gets the rest.
local BASE_SHARE = 0.6

--- What a field row's frame puts round its text. A one pixel border and six
--- pixels of padding on either side.
local FRAME_CHROME = 2 * 1 + 2 * 6

--- The space under a field row, and the space it keeps from the card's right
--- edge, which is the page edge the label starts on. The three rows are one
--- form, so they stand as close as the Hotkeys page's fields do.
local ROW_GAP, ROW_RIGHT = 2, PAGE_EDGE

--
--- ∑ The columns of the level list, in characters. A width of zero takes
---   whatever is left over, and that is where the resolved address goes.
---
---   The three fixed columns are as narrow as their contents allow, so the
---   resolved address keeps eleven characters on the narrowest page the
---   inspector allows and eighteen on the narrowest window.
--
Pointer.Columns = {
    --- The word in the header and one character after it. A column the title
    --- fills to the edge runs straight into Offset, because the list keeps
    --- less than a character between two columns.
    Level = 6,
    --- An offset is rarely more than six hexadecimal digits, and the sign in
    --- front of it needs one more.
    Offset = 8,
    --- A user mode address on a sixty four bit Windows is twelve hexadecimal
    --- digits.
    Value = 12
}

--
--- ∑ The level buttons over the list, in reading order. The flow bar places
---   them in the order they are added and wraps them when the page is narrow.
---
---   The five together are three hundred and twenty four pixels with their
---   gaps, which is what fits one line on the narrowest window. The list is
---   about levels, so Add and Remove need no second word, and the hints say
---   the rest.
--
Pointer.Actions = {
    { Key = "Add", Caption = "Add", Width = 48,
      Hint = "Add a level under the one you picked. On a plain record this is what turns it into a pointer." },
    { Key = "Remove", Caption = "Remove", Width = 64,
      Hint = "Remove the level you picked. Removing the last one makes it a plain address again." },
    { Key = "Up", Caption = "Up", Width = 40,
      Hint = "Move the level one step towards the base." },
    { Key = "Down", Caption = "Down", Width = 52,
      Hint = "Move the level one step away from the base." },
    { Key = "Paste", Caption = "Paste path", Width = 96,
      Hint = "Read a pointer path off the clipboard, in the arrow, bracket or comma form." }
}

--- The two buttons along the bottom, Apply at the right edge and Revert to its
--- left.
Pointer.Commits = {
    { Key = "Revert", Caption = "Revert", Width = BUTTON_WIDTH,
      Hint = "Throw away what you typed and read the record again." },
    { Key = "Apply", Caption = "Apply", Width = BUTTON_WIDTH,
      Hint = "Write the whole chain to the record as one change (Ctrl+S)." }
}

--------------------------------------------------------
--                    Small helpers                   --
--------------------------------------------------------

local function trim(text)
    return (tostring(text == nil and "" or text):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- One guarded property write, so a control that is gone and a property this
--- build does not have both come back as false rather than as a raise.
local function safeSet(control, property, value)
    if control == nil then return false end
    return (pcall(function() control[property] = value end))
end

--- Sends one line to the log channel when there is one.
local function say(self, level, message)
    local sink = self and self.Log
    if sink == nil then return end
    local method = sink[level]
    if type(method) ~= "function" then return end
    pcall(method, sink, message)
end

--- Tells the window what just happened. A page never writes to the status bar
--- itself, it says something and the window decides where that goes.
local function status(self, text)
    if type(self.OnStatus) ~= "function" then return end
    pcall(self.OnStatus, tostring(text == nil and "" or text))
end

--- A shallow copy of a list of strings, so a buffer and the baseline it came
--- from can never share a table.
local function copyList(list)
    local out = {}
    for index, value in ipairs(list or {}) do out[index] = value end
    return out
end

--- The first reason out of a failure list, so a refused commit says why rather
--- than only that it did not work.
local function reasonOf(failures)
    if type(failures) ~= "table" then return nil end
    for _, failure in ipairs(failures) do
        if type(failure) == "table" and failure.Reason ~= nil then return tostring(failure.Reason) end
        if type(failure) == "string" then return failure end
    end
    return nil
end

--- An address as Cheat Engine writes one. Eight digits is the shape a person
--- reads fastest and a longer address simply takes more of them.
local function hexOf(value)
    local number = tonumber(value)
    if number == nil then return UNREADABLE end
    number = math.floor(number)
    if number < 0 then return string.format("-%X", -number) end
    return string.format("%08X", number)
end

--------------------------------------------------------
--                   Layout helpers                   --
--------------------------------------------------------

--- One property read as a number, or nil when it cannot be read.
local function readNumber(control, property)
    if control == nil then return nil end
    local ok, value = pcall(function() return control[property] end)
    if not ok then return nil end
    return tonumber(value)
end

--- The width a control lays its children out in, or nil while it has none.
local function innerWidth(control)
    local width = readNumber(control, "ClientWidth")
    if width == nil or width <= 0 then width = readNumber(control, "Width") end
    if width == nil or width <= 0 then return nil end
    return width
end

--- Whether a control is meant to be on screen. One that cannot say counts as
--- shown, so a layout never loses a button it could not ask.
local function isShown(control)
    local ok, value = pcall(function() return control.Visible end)
    return not ok or value ~= false
end

--- Whether a text box has the keyboard right now. A build without focused
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
--- ∑ A bar of buttons with one group kept to the left edge and one to the
---   right, placed by hand.
---
---   Aligned to the two edges, a bar narrower than both groups slides one
---   under the other, which is how Apply and Revert vanished under Paste path.
---   Here the two groups share a line when they fit side by side, the right
---   group takes a line of its own when they do not, and a group too wide for
---   one line wraps. The bar then takes the height its lines need.
---
---   It is meant to be the only control along the bottom of its parent. Two
---   bottom aligned panels are ordered by their lower edges, so a bar that
---   grows a line would trade places with its neighbour.
---
---   Until the bar knows its width nothing is placed. The resize that comes
---   when the page is shown places everything.
--- @param theme table
--- @param parent userdata
--- @param options table # Left and Right, lists of Key, Caption, Icon, Width,
---        Hint and OnClick, plus Align and OnHeight(height).
--- @return userdata, table, function # bar, key to { Control, Enable }, and
---         relayout() which answers the bar's height
--
local function actionBar(theme, parent, options)
    local bar = theme:CreatePanel(parent, {
        Align = options.Align or "alBottom",
        Height = 2 * BAR_PAD + BUTTON_HEIGHT,
        ColorKey = "COLOR_INPUT"
    })
    local buttons, left, right = {}, {}, {}
    local function build(specs, into)
        for _, spec in ipairs(specs or {}) do
            local control, enable = theme:CreateButton(bar, {
                Caption = spec.Caption, Icon = spec.Icon, Width = spec.Width,
                Height = BUTTON_HEIGHT, Hint = spec.Hint, OnClick = spec.OnClick,
                Spacing = { Around = 0 }
            })
            into[#into + 1] = control
            buttons[spec.Key] = { Control = control, Enable = enable }
        end
    end
    build(options.Left, left)
    build(options.Right, right)

    local function place(line, x, y, tall)
        for _, control in ipairs(line.Controls) do
            local each = readNumber(control, "Width") or 0
            local high = readNumber(control, "Height") or 0
            safeSet(control, "Left", x)
            safeSet(control, "Top", y + math.floor((tall - high) / 2))
            x = x + each + BAR_GAP
        end
    end

    -- Both sides are looked at by name. A row with only a right side has no
    -- first element, and a walk over the pair would stop before it.
    local function tallest(row)
        local most = 0
        for _, side in pairs({ Left = row.Left, Right = row.Right }) do
            for _, control in ipairs(side.Controls) do
                most = math.max(most, readNumber(control, "Height") or 0)
            end
        end
        return most
    end

    local function arrange()
        local width = innerWidth(bar)
        if width == nil then return nil end
        local room = math.max(0, width - 2 * PAGE_EDGE)
        local leftLines, rightLines = groupLines(left, room), groupLines(right, room)
        local rows = {}
        for index, line in ipairs(leftLines) do rows[index] = { Left = line } end
        if #leftLines == 1 and #rightLines == 1
            and leftLines[1].Span + BAR_SPLIT + rightLines[1].Span <= room then
            rows[1].Right = rightLines[1]
        else
            for _, line in ipairs(rightLines) do rows[#rows + 1] = { Right = line } end
        end
        local y = BAR_PAD
        for _, row in ipairs(rows) do
            local tall = tallest(row)
            if row.Left then place(row.Left, PAGE_EDGE, y, tall) end
            if row.Right then place(row.Right, width - PAGE_EDGE - row.Right.Span, y, tall) end
            y = y + tall + BAR_GAP
        end
        local height = #rows > 0 and (y - BAR_GAP + BAR_PAD) or (2 * BAR_PAD)
        if readNumber(bar, "Height") ~= height then
            safeSet(bar, "Height", height)
            if type(options.OnHeight) == "function" then pcall(options.OnHeight, height) end
        end
        return height
    end

    -- Taking a new height fires one more resize while this one runs, and
    -- that one has nothing to add.
    local busy = false
    local function relayout()
        if busy then return nil end
        busy = true
        local ok, height = pcall(arrange)
        busy = false
        if not ok then return nil end
        return height
    end
    safeSet(bar, "OnResize", function() relayout() end)
    return bar, buttons, relayout
end

--------------------------------------------------------
--                    Pure reading                    --
--------------------------------------------------------

--
--- ∑ The number behind an offset text.
---
---   Cheat Engine reads an offset as hexadecimal, so ten means sixteen, and
---   nothing here second guesses that. A leading 0x or a dollar sign is
---   accepted because a person pasting from a disassembler has one, and a minus
---   sign is accepted because a chain walking backwards through a structure is
---   ordinary.
--- @param text string|number|nil
--- @return number|nil # nil when it is not a hexadecimal number.
--
function Pointer.OffsetValue(text)
    if type(text) == "number" then return math.floor(text) end
    local clean = trim(text)
    if clean == "" then return nil end
    local sign = 1
    local head = clean:sub(1, 1)
    if head == "-" then
        sign, clean = -1, clean:sub(2)
    elseif head == "+" then
        clean = clean:sub(2)
    end
    clean = (clean:gsub("^0[xX]", ""):gsub("^%$", ""))
    if clean == "" or clean:match("[^%x]") ~= nil then return nil end
    local value = tonumber(clean, 16)
    if value == nil then return nil end
    return sign * value
end

--
--- ∑ Turns a list round.
---
---   Cheat Engine's offset zero is the offset applied last, so its order and
---   the order the chain is walked in are mirror images of each other. This is
---   the only place in the page that knows it.
--- @param list table|nil
--- @return table
--
function Pointer.Reverse(list)
    local out = {}
    for index = #(list or {}), 1, -1 do out[#out + 1] = list[index] end
    return out
end

--
--- ∑ Whether two chains say the same thing.
---
---   Dirty is one use of it. Telling a record that moved from one that did not
---   is the other, and that is what stops a sync tick from rebuilding a page
---   the person is in the middle of reading.
--- @param a table|nil
--- @param b table|nil
--- @return boolean
--
function Pointer.SamePointer(a, b)
    if a == nil or b == nil then return a == b end
    if a.Base ~= b.Base then return false end
    if #a.Offsets ~= #b.Offsets then return false end
    for index, text in ipairs(a.Offsets) do
        if text ~= b.Offsets[index] then return false end
    end
    return true
end

--- Splits on a plain separator. Lua patterns are never used on text a person
--- typed, because a bracket in it would be read as a pattern.
local function splitOn(text, separator)
    local parts, start = {}, 1
    while true do
        local from, to = text:find(separator, start, true)
        if from == nil then break end
        parts[#parts + 1] = text:sub(start, from - 1)
        start = to + 1
    end
    parts[#parts + 1] = text:sub(start)
    return parts
end

--
--- ∑ Peels one bracket form from the outside in.
---
---   The outermost bracket carries the offset applied last, which is the last
---   level in chain order, so the recursion naturally builds the chain in the
---   order it is walked. The depth is counted rather than matched, because the
---   innermost text may hold a bracket of its own.
---
---   A bracket with nothing written after it is a level all the same, with an
---   offset of zero. The brackets are the dereferences and the text after them
---   is only what is added afterwards, so dropping that level would turn one
---   chain into a shorter one that reads somewhere else.
--- @param text string
--- @param depthLeft number # How many brackets are still allowed, so a broken
---        paste cannot recurse forever.
--- @return table|nil # Base and Offsets in chain order.
--
local function peelBrackets(text, depthLeft)
    local clean = trim(text)
    if depthLeft <= 0 then return nil end
    if clean:sub(1, 1) ~= "[" then
        if clean == "" then return nil end
        return { Base = clean, Offsets = {} }
    end
    local depth, close = 0, nil
    for index = 1, #clean do
        local character = clean:sub(index, index)
        if character == "[" then
            depth = depth + 1
        elseif character == "]" then
            depth = depth - 1
            if depth == 0 then
                close = index
                break
            end
        end
    end
    if close == nil then return nil end
    local inner = peelBrackets(clean:sub(2, close - 1), depthLeft - 1)
    if inner == nil then return nil end
    local tail = trim((trim(clean:sub(close + 1)):gsub("^%+", "")))
    if tail == "" then tail = DEFAULT_OFFSET end
    inner.Offsets[#inner.Offsets + 1] = tail
    return inner
end

--
--- ∑ Reads a pointer path a person pasted, in any of the three shapes this
---   window has seen people use.
---
---   The arrow form is what Cheat Engine's own pointer scanner copies, the
---   bracket form is what a person writes down while reading a disassembly and
---   the comma form is what a spreadsheet gives back. All three end up as a
---   base and a list of offsets in chain order.
--- @param text string|nil
--- @return table|nil # Base and Offsets in chain order.
--- @return string|nil # Why it could not be read.
--
function Pointer.ParsePath(text)
    if type(text) ~= "string" then return nil, "There is no pointer path to read." end
    local clean = trim((text:gsub("[\r\n]+", " ")))
    if clean == "" then return nil, "There is no pointer path to read." end

    -- The arrow form is looked for first, because a path copied out of a
    -- pointer scanner can carry brackets around its base as well.
    local out
    if clean:find("->", 1, true) == nil and clean:sub(1, 1) == "[" then
        out = peelBrackets(clean, MAX_LEVELS + 1)
        if out == nil then return nil, "That bracket form could not be read." end
    end
    if out == nil then
        local parts
        if clean:find("->", 1, true) ~= nil then
            parts = splitOn(clean, "->")
        elseif clean:find(",", 1, true) ~= nil then
            parts = splitOn(clean, ",")
        else
            parts = { clean }
        end
        out = { Base = trim(parts[1]), Offsets = {} }
        for index = 2, #parts do
            local offset = trim((trim(parts[index]):gsub("^%+", "")))
            if offset == "" then return nil, "That pointer path has an empty offset." end
            out.Offsets[#out.Offsets + 1] = offset
        end
    end

    if out.Base == "" then return nil, "That pointer path has no base address." end
    if #out.Offsets > MAX_LEVELS then
        return nil, "A pointer chain is limited to " .. MAX_LEVELS .. " levels."
    end
    for index, offset in ipairs(out.Offsets) do
        if Pointer.OffsetValue(offset) == nil then
            return nil, "Offset " .. index .. " is not a hexadecimal number."
        end
    end
    return out
end

--- How an offset reads on screen. A sign in front says which way the level
--- walks, and a text the person already signed is left alone.
local function offsetLabel(text)
    local clean = trim(text)
    if clean == "" then return "?" end
    local head = clean:sub(1, 1)
    if head == "+" or head == "-" then return clean end
    return "+" .. clean
end

--------------------------------------------------------
--                    Construction                    --
--------------------------------------------------------

--
--- ∑ Builds the page. Nothing is created until Build, so the inspector can hold
---   one before its card exists.
--- @param services table|nil # Theme, Surface, Frame, Grid, Properties, Types,
---        Records, CE, Log and Settings.
--- @return table
--
function Pointer:New(services)
    services = services or {}
    return setmetatable({
        Theme = services.Theme,
        Log = services.Log,
        Settings = services.Settings,
        Frame = services.Frame,
        CE = services.CE,
        Types = services.Types or TypesModule,
        Records = services.Records,
        Properties = services.Properties,
        SurfaceClass = services.Surface or SurfaceModule,

        Parent = nil,
        Host = nil,             -- the windowed panel the list and its menu live on
        Surface = nil,
        List = nil,
        Rows = {},              -- Base, Offset and Resolved, each { Row, Input, Enable, Parts }
        BaseEdit = nil,
        BaseLabel = nil,        -- the muted label showing what the base resolves to
        BaseText = "",          -- what that label would say with room enough
        OffsetEdit = nil,
        OffsetCaption = nil,    -- says which level the offset edit is on
        ResolvedEdit = nil,     -- read only, the address the whole chain lands on
        LevelBar = nil,         -- the flow bar the level buttons wrap in
        ActionBar = nil,        -- Apply and Revert along the bottom
        Buttons = {},           -- key to setEnabled
        Controls = {},          -- key to the button panel, for the layout checks
        Menu = nil,             -- the level list's right click menu
        Empty = nil,            -- the themed empty state over the list

        Snapshot = nil,
        IDs = {},
        ID = nil,               -- the one record this page edits
        Reason = nil,           -- why it is showing an empty state instead

        Baseline = nil,         -- Base and Offsets in chain order, as the record holds them
        Buffer = nil,           -- the same shape, as the person edited it
        LevelRows = {},         -- what the list is showing right now
        Level = nil,            -- the level the offset edit is on
        Loading = false,        -- true while a control value is set in code

        OnCommit = nil,
        OnAct = nil,
        OnStatus = nil,
        --- The inspector's busy guard. This page opens no modal of its own, so
        --- it is declared and never used, which keeps the shape of every page
        --- the same.
        OnGuard = nil,
        --- The hovered hint the inspector's hint strip shows. This page has
        --- no rows that explain themselves, so it never sends one.
        OnHint = nil
    }, Pointer)
end

--
--- ∑ Creates the controls inside the inspector's page panel.
---
---   Top to bottom the page reads base address, offset, where the chain
---   resolves to, the level buttons, the level list, and Apply and Revert. The
---   rows and the flow bar are stacked by slot, so they are built in that
---   order. The action bar is the only control along the bottom and the list
---   takes what is left.
--- @param parent userdata
--- @return boolean
--
function Pointer:Build(parent)
    self.Parent = parent
    local theme = self.Theme
    if theme == nil then
        say(self, "Warning", "The pointer page was built without a theme.")
        return false
    end
    local ok, err = pcall(function()
        self:BuildFields(theme, parent)
        self:BuildLevelBar(theme, parent)
        self:BuildActions(theme, parent)
        -- The list keeps the page edge on both sides, like the rows over it
        -- and the bar under it.
        local host = theme:CreatePanel(parent, {
            Align = "alClient", ColorKey = "COLOR_INPUT",
            Spacing = { Left = PAGE_EDGE, Right = PAGE_EDGE }
        })
        self.Host = host
        self.Empty = theme:CreateEmptyState(host)
        safeSet(self.Empty.Panel, "Visible", false)
        self:BuildList(host)
        self:BuildMenu(theme, host)
    end)
    if not ok then
        say(self, "Warning", "The pointer page could not be built whole, " .. tostring(err))
    end
    self:Apply()
    return ok
end

--
--- ∑ The three field rows. The base and the offset take typing, and the
---   resolved address is read only, which keeps it selectable, with a Copy
---   button beside it.
---
---   The base row also says where the base itself resolves to, in a muted
---   note at its right end. That note is cut to what the base box leaves, see
---   FitBase.
--- @param theme table
--- @param parent userdata
--- @return nil
--
function Pointer:BuildFields(theme, parent)
    local baseRow, baseEdit, baseEnable, baseParts = theme:CreateFieldRow(parent, {
        Label = "Base address", Height = FIELD_HEIGHT,
        Spacing = { Bottom = ROW_GAP, Right = ROW_RIGHT },
        Placeholder = "game.exe+1A2B34",
        Hint = "The address the chain starts from, such as game.exe+1A2B34.",
        OnChange = function() self:TakeBase() end
    })
    stackAt(baseRow, 1)
    self.Rows.Base = { Row = baseRow, Input = baseEdit, Enable = baseEnable, Parts = baseParts }
    self.BaseEdit = baseEdit
    local note = theme:CreateLabel(baseRow, "", "muted")
    safeSet(note, "Align", "alRight")
    safeSet(note, "Layout", "tlCenter")
    safeSet(note, "Alignment", "taRightJustify")
    pcall(function() note.BorderSpacing.Left = BASE_NOTE_GAP end)
    self.BaseLabel = note
    safeSet(baseRow, "OnResize", function() self:FitBase() end)

    local offsetRow, offsetEdit, offsetEnable, offsetParts = theme:CreateFieldRow(parent, {
        Label = "Offset", Height = FIELD_HEIGHT,
        Spacing = { Bottom = ROW_GAP, Right = ROW_RIGHT },
        Hint = "The offset of the level you picked, in hexadecimal.",
        OnChange = function() self:TakeOffset() end
    })
    stackAt(offsetRow, 2)
    self.Rows.Offset = { Row = offsetRow, Input = offsetEdit, Enable = offsetEnable, Parts = offsetParts }
    self.OffsetEdit = offsetEdit
    self.OffsetCaption = offsetParts and offsetParts.Label or nil

    local resolvedRow, resolvedEdit, resolvedEnable, resolvedParts = theme:CreateFieldRow(parent, {
        Label = "Resolves to", Height = FIELD_HEIGHT,
        Spacing = { Bottom = ROW_GAP, Right = ROW_RIGHT },
        ReadOnly = true,
        Hint = "The address the whole chain lands on. Select it or press Copy to take it along."
    })
    stackAt(resolvedRow, 3)
    self.Rows.Resolved = {
        Row = resolvedRow, Input = resolvedEdit, Enable = resolvedEnable, Parts = resolvedParts
    }
    self.ResolvedEdit = resolvedEdit
    local copy, copyEnable = theme:CreateButton(resolvedRow, {
        Caption = "Copy", Icon = "Copy", Align = "alRight",
        Width = COPY_WIDTH, Height = FIELD_HEIGHT,
        Hint = "Copy the address the chain resolves to.",
        Spacing = { Left = BASE_NOTE_GAP, Top = 0, Bottom = 0 },
        OnClick = function() self:CopyAddress(nil) end
    })
    self.Buttons.Copy = copyEnable
    self.Controls.Copy = copy
end

--- The level buttons, in a bar that wraps them rather than letting one slide
--- under the next.
function Pointer:BuildLevelBar(theme, parent)
    local bar, add = theme:CreateFlowBar(parent, {
        Align = "alTop", ColorKey = "COLOR_INPUT", Gap = BAR_GAP,
        Padding = { Left = PAGE_EDGE, Top = 2, Right = PAGE_EDGE, Bottom = 6 }
    })
    stackAt(bar, 4)
    self.LevelBar = bar
    for _, action in ipairs(Pointer.Actions) do
        local button, setEnabled = theme:CreateButton(bar, {
            Caption = action.Caption, Width = action.Width, Height = BUTTON_HEIGHT,
            Hint = action.Hint, Spacing = { Around = 0 },
            OnClick = function() self:Run(action.Key) end
        })
        add(button)
        self.Buttons[action.Key] = setEnabled
        self.Controls[action.Key] = button
    end
end

--- Apply and Revert, kept to the right edge of their own bar.
function Pointer:BuildActions(theme, parent)
    local right = {}
    for index, spec in ipairs(Pointer.Commits) do
        right[index] = {
            Key = spec.Key, Caption = spec.Caption, Width = spec.Width, Hint = spec.Hint,
            OnClick = function()
                if spec.Key == "Apply" then self:Save() else self:Revert() end
            end
        }
    end
    local bar, buttons = actionBar(theme, parent, { Right = right })
    self.ActionBar = bar
    for key, entry in pairs(buttons) do
        self.Buttons[key] = entry.Enable
        self.Controls[key] = entry.Control
    end
end

--
--- ∑ The level list's right click menu.
---
---   It hangs off the windowed panel the list sits on, because the list is a
---   paint box and a paint box has no window of its own to receive the right
---   click. The list picks the row under the mouse before the menu opens, so
---   Copy address copies the row that was pointed at.
--- @param theme table
--- @param host userdata
--- @return table|nil
--
function Pointer:BuildMenu(theme, host)
    if type(theme.CreatePopupMenu) ~= "function" then return nil end
    local menu = theme:CreatePopupMenu(host)
    if menu == nil then return nil end
    self.Menu = menu
    menu.Add("Copy address", function() self:CopyAddress(self.Level) end,
        { Key = "copyaddress", Shortcut = "Ctrl+C", Icon = "Copy",
          Hint = "Copy the address the picked level resolves to." })
    menu.Add("Copy pointer path", function() self:CopyPath() end,
        { Key = "copypath", Hint = "Copy the base and every offset as one path." })
    safeSet(menu.Menu, "OnPopup", function() self:MenuOpening() end)
    return menu
end

--- Works out what the menu may do, one moment before it is shown.
function Pointer:MenuOpening()
    local menu = self.Menu
    if menu == nil then return false end
    menu.Enable("copyaddress", self:AddressAt(self.Level) ~= nil)
    menu.Enable("copypath", self:Editable())
    return true
end

--
--- ∑ How wide the base box asks to be, out of the room the label column
---   leaves on its row.
---
---   The larger share of that room at least, and more when the base typed into
---   it needs more to be read whole. Never more than the room itself.
--- @param space number # The row's width less the label column and the gap
---        in front of the note.
--- @return number
--
function Pointer:BaseFrameWant(space)
    local theme = self.Theme
    local charWidth = 7
    if theme ~= nil and type(theme.CharWidth) == "function" then
        local ok, measured = pcall(theme.CharWidth, theme)
        measured = ok and tonumber(measured) or nil
        if measured ~= nil and measured > 0 then charWidth = measured end
    end
    local typed = trim(self.Buffer ~= nil and self.Buffer.Base or "")
    local length = #typed
    local lib = rawget(_G, "utf8")
    if type(lib) == "table" and type(lib.len) == "function" then
        length = lib.len(typed) or length
    end
    -- One character more than the text, which is where the caret stands.
    local need = math.ceil((length + 1) * charWidth) + FRAME_CHROME
    local want = math.max(BASE_FRAME_MIN, math.ceil(space * BASE_SHARE), need)
    return math.max(0, math.min(want, space))
end

--
--- ∑ Cuts the note on the base row to what the base box leaves.
---
---   The label column and the base box come first. The note gets the rest,
---   and a cut note carries the whole address in its hint. The note is a label
---   that is as wide as its caption, so cutting it is what hands the box its
---   width.
--- @return string # What the note shows.
--
function Pointer:FitBase()
    local note = self.BaseLabel
    if note == nil then return "" end
    local text = self.BaseText or ""
    local theme = self.Theme
    local width = self.Rows.Base and innerWidth(self.Rows.Base.Row) or nil
    if text == "" or width == nil or theme == nil or type(theme.FitText) ~= "function" then
        safeSet(note, "Caption", text)
        return text
    end
    local space = width - LABEL_COLUMN - BASE_NOTE_GAP
    local room = space - self:BaseFrameWant(space)
    local ok, shown = pcall(theme.FitText, theme, note, text, math.max(0, room),
        "Where the base address resolves to right now.")
    if not ok then
        safeSet(note, "Caption", text)
        return text
    end
    return shown
end

--
--- ∑ Puts a list painter on a canvas inside host.
---
---   The list is built before the canvas is attached, so a Cheat Engine with
---   neither a paint box nor an image still answers Levels, the selection and
---   the arrow keys while the page shows nothing at all.
--- @param host userdata
--- @return boolean
--
function Pointer:BuildList(host)
    local surface = self.SurfaceClass:New({
        Theme = self.Theme, Log = self.Log, Settings = self.Settings,
        Frame = self.Frame, Name = "Pointer"
    })
    self.Surface = surface
    self.List = surface:ListPainter({
        Header = true,
        Columns = {
            { Key = "Level", Title = "Level", Width = Pointer.Columns.Level, ColorKey = "Muted" },
            { Key = "Offset", Title = "Offset", Width = Pointer.Columns.Offset },
            { Key = "Value", Title = "Points to", Width = Pointer.Columns.Value, ColorKey = "Muted" },
            { Key = "Address", Title = "Resolves to", Width = 0 }
        },
        OnPick = function(item) self:PickLevel(item and item.Index or nil) end,
        OnOpen = function(item) self:OpenLevel(item) end
    })
    self.List:SetEmpty("This record has no pointer levels",
        "Add turns it into a pointer.")
    local ok, reason = surface:Attach(host)
    if not ok then
        say(self, "Warning", "The pointer page has no canvas, " .. tostring(reason))
        return false
    end
    return true
end

--------------------------------------------------------
--                    The subject                     --
--------------------------------------------------------

--
--- ∑ Which record this page can edit, out of what the tree has selected.
---
---   One record and never a group, because a chain belongs to an address and a
---   plain group header has none. An address group header does have one, so it
---   is allowed through like any other record.
--- @param ids table|nil
--- @param snapshot table|nil
--- @return number|nil # The record id.
--- @return string|nil # Why there is none.
--
function Pointer:SubjectOf(ids, snapshot)
    if ids == nil or #ids == 0 then return nil, "Nothing is selected" end
    if #ids > 1 then return nil, "More than one record is selected" end
    local id = ids[1]
    local node = snapshot ~= nil and snapshot.ByID ~= nil and snapshot.ByID[id] or nil
    if node == nil then return nil, "That record is gone" end
    if self.Records ~= nil and not node.Loaded then
        pcall(function() self.Records:EnsureDetail(snapshot, { id }) end)
    end
    local types = self.Types or TypesModule
    if types.IsGroup(node) and node.IsAddressGroupHeader ~= true then
        return nil, "That record is a group header"
    end
    return id
end

--- The two lines the page shows when it has no record to work on.
Pointer.Empties = {
    ["Nothing is selected"] = {
        Title = "No record is selected",
        Hint = "Pick one record in the tree to edit its pointer chain."
    },
    ["More than one record is selected"] = {
        Title = "Select one record",
        Hint = "A pointer chain belongs to one record, so this page edits one at a time."
    },
    ["That record is gone"] = {
        Title = "That record is gone",
        Hint = "It was removed from the table while this page was open."
    },
    ["That record is a group header"] = {
        Title = "A group header has no address",
        Hint = "Pick a record with an address under it."
    }
}

--
--- ∑ Points the page at a selection. The same record with an unsaved chain
---   keeps what the person typed, because the inspector already asked before
---   the subject was allowed to change.
--- @param ids table|nil
--- @param snapshot table|nil
--- @return nil
--
function Pointer:Show(ids, snapshot)
    self.Snapshot = snapshot
    self.IDs = ids or {}
    local id, reason = self:SubjectOf(self.IDs, snapshot)
    if id ~= nil and id == self.ID and self:IsDirty() then
        self:Apply()
        return
    end
    self.ID, self.Reason = id, reason
    self:Load()
end

--- Reads the record's own chain, in chain order.
function Pointer:ReadRecord()
    local records, props = self.Records, self.Properties
    if self.ID == nil or records == nil or props == nil then
        return { Base = "", Offsets = {} }
    end
    local mr = records:Resolve(self.ID, self.Snapshot)
    if mr == nil then return { Base = "", Offsets = {} } end
    local pointer = props:ReadPointer(mr)
    return {
        Base = tostring(pointer.Base or ""),
        Offsets = Pointer.Reverse(pointer.Offsets or {})
    }
end

--
--- ∑ Takes one chain as both the baseline and the buffer, and puts it into the
---   two edits without the page hearing about its own writes.
--- @param pointer table|nil # Base and Offsets in chain order, or nothing.
--- @return nil
--
function Pointer:Adopt(pointer)
    self.Level = nil
    if pointer == nil then
        self.Baseline, self.Buffer = nil, nil
    else
        self.Baseline = pointer
        self.Buffer = { Base = pointer.Base, Offsets = copyList(pointer.Offsets) }
    end
    self.Loading = true
    safeSet(self.BaseEdit, "Text", pointer ~= nil and pointer.Base or "")
    safeSet(self.OffsetEdit, "Text", "")
    self.Loading = false
end

--
--- ∑ Throws the buffer away and reads the record again. This is what Show, a
---   record that moved under a clean page and the Revert button all go through.
--- @return nil
--
function Pointer:Load()
    self:Adopt(self.ID ~= nil and self:ReadRecord() or nil)
    self:Apply()
end

--------------------------------------------------------
--                    The level list                  --
--------------------------------------------------------

--
--- ∑ The rows the list shows, with the chain walked once for the live values.
---
---   A level whose pointer could not be read shows two question marks, and so
---   does every level under it, because there is no address left to read from.
--- @return table
--
function Pointer:BuildRows()
    local out = {}
    local buffer = self.Buffer
    if buffer == nil then return out end
    local ce = self.CE
    local address = ce ~= nil and ce:AddressOf(buffer.Base) or nil
    for index, text in ipairs(buffer.Offsets) do
        local delta = Pointer.OffsetValue(text)
        local read, resolved
        if address ~= nil and ce ~= nil then read = ce:ReadPointer(address) end
        if read ~= nil and delta ~= nil then resolved = read + delta end
        out[index] = {
            Index = index,
            Level = tostring(index),
            Offset = offsetLabel(text),
            Value = read ~= nil and hexOf(read) or UNREADABLE,
            Address = resolved ~= nil and hexOf(resolved) or UNREADABLE,
            Resolved = resolved,
            ColorKeys = {
                Value = read ~= nil and "Text" or "Muted",
                Address = resolved ~= nil and "Text" or "Muted"
            }
        }
        address = resolved
    end
    return out
end

--- The rows as they stand, which is what the tests read and what the window
--- would copy a pointer path out of.
function Pointer:Levels()
    return self.LevelRows
end

--- The address the last level resolves to, which is what Cheat Engine calls
--- CurrentAddress. Nothing when the chain could not be walked.
function Pointer:CurrentAddress()
    local last = self.LevelRows[#self.LevelRows]
    if last == nil then
        local ce = self.CE
        if ce == nil or self.Buffer == nil then return nil end
        return ce:AddressOf(self.Buffer.Base)
    end
    return last.Resolved
end

--
--- ∑ Rebuilds everything on screen from the buffer. One call after any edit,
---   so nothing can update half of the page.
--- @return nil
--
function Pointer:Apply()
    self.LevelRows = self:BuildRows()
    local editable = self:Editable()
    local count = editable and #self.Buffer.Offsets or 0
    if self.Level ~= nil and (self.Level < 1 or self.Level > count) then
        self.Level = count > 0 and math.min(self.Level, count) or nil
    end

    if self.List ~= nil then
        self.List:SetItems(self.LevelRows)
        if self.Level ~= nil then
            self.List:Select(self.Level, true)
        else
            self.List:ClearSelection()
        end
    end

    if self.Empty ~= nil then
        local message = editable and nil or Pointer.Empties[self.Reason or ""]
        if message == nil and not editable then
            message = { Title = "Nothing to edit", Hint = "Pick one record in the tree." }
        end
        if message ~= nil then self.Empty.Set(message.Title, message.Hint) end
        safeSet(self.Empty.Panel, "Visible", message ~= nil)
    end

    local resolved = nil
    if editable and self.CE ~= nil then resolved = self.CE:AddressOf(self.Buffer.Base) end
    self.BaseText = editable and (resolved ~= nil and hexOf(resolved) or UNREADABLE) or ""
    self:FitBase()

    local offsetLabel = self.Level ~= nil and ("Offset " .. self.Level) or "Offset"
    local offsetParts = self.Rows.Offset and self.Rows.Offset.Parts or nil
    if offsetParts ~= nil and type(offsetParts.SetLabel) == "function" then
        pcall(offsetParts.SetLabel, offsetLabel)
    else
        safeSet(self.OffsetCaption, "Caption", offsetLabel)
    end
    self:EnableRow("Base", editable)
    self:EnableRow("Offset", editable and self.Level ~= nil)
    self:EnableRow("Resolved", editable)

    local final = editable and self:CurrentAddress() or nil
    local finalText = ""
    if editable then finalText = final ~= nil and hexOf(final) or UNREADABLE end
    self.Loading = true
    if self.ResolvedEdit ~= nil then
        local ok, held = pcall(function() return self.ResolvedEdit.Text end)
        if not ok or held ~= finalText then safeSet(self.ResolvedEdit, "Text", finalText) end
    end
    self.Loading = false

    local dirty = self:IsDirty()
    self:Enable("Add", editable and count < MAX_LEVELS)
    self:Enable("Remove", editable and self.Level ~= nil)
    self:Enable("Up", editable and self.Level ~= nil and self.Level > 1)
    self:Enable("Down", editable and self.Level ~= nil and self.Level < count)
    self:Enable("Paste", editable)
    self:Enable("Apply", editable and dirty)
    self:Enable("Revert", editable and dirty)
    self:Enable("Copy", final ~= nil)

    if self.Surface ~= nil then self.Surface:Invalidate() end
end

--- Turns one field row on or off, frame and all. A row that was not built
--- falls back to the bare control.
function Pointer:EnableRow(key, value)
    local row = self.Rows[key]
    if row == nil then return false end
    if type(row.Enable) == "function" then
        pcall(row.Enable, value == true)
    else
        safeSet(row.Input, "Enabled", value == true)
    end
    return true
end

--- One button's enabled state, when that button was built at all.
function Pointer:Enable(key, value)
    local setEnabled = self.Buttons[key]
    if type(setEnabled) ~= "function" then return false end
    pcall(setEnabled, value == true)
    return true
end

--- True when there is a record and a buffer to edit.
function Pointer:Editable()
    return self.ID ~= nil and self.Buffer ~= nil
end

--
--- ∑ Moves the offset edit onto one level.
--- @param index number|nil
--- @return nil
--
function Pointer:PickLevel(index)
    if not self:Editable() then return end
    local count = #self.Buffer.Offsets
    if index ~= nil and (index < 1 or index > count) then index = nil end
    self.Level = index
    self.Loading = true
    safeSet(self.OffsetEdit, "Text", index ~= nil and self.Buffer.Offsets[index] or "")
    self.Loading = false
    self:Apply()
end

--- Opening a level shows what it resolves to in the memory view, which is the
--- one thing a person wants from a row they double clicked.
function Pointer:OpenLevel(item)
    local ce = self.CE
    if ce == nil or item == nil or item.Resolved == nil then
        status(self, "That level could not be read, so there is nothing to show.")
        return false
    end
    local ok, err = ce:ShowInMemoryView(item.Resolved)
    if not ok then
        status(self, "The memory view could not be opened, " .. tostring(err))
        return false
    end
    return true
end

--------------------------------------------------------
--                      Copying                       --
--------------------------------------------------------

--
--- ∑ The address one level resolves to, or the one the whole chain lands on
---   when no level is named.
--- @param index number|nil
--- @return number|nil
--
function Pointer:AddressAt(index)
    if not self:Editable() then return nil end
    if index == nil then return self:CurrentAddress() end
    local row = self.LevelRows[index]
    return row ~= nil and row.Resolved or nil
end

--- Puts one line on the clipboard and says so. Without Cheat Engine's
--- clipboard the page says that instead.
local function toClipboard(self, text, what)
    local ce = self.CE
    if ce == nil or type(ce.ToClipboard) ~= "function" then
        status(self, "This Cheat Engine has no clipboard to copy to.")
        return false
    end
    local ok, done, err = pcall(ce.ToClipboard, ce, text)
    if not ok or done ~= true then
        status(self, "Nothing was copied, " .. tostring(ok and err or done))
        return false
    end
    status(self, "Copied " .. what .. ".")
    return true
end

--
--- ∑ Copies the address a level resolves to, or the chain's own address when
---   no level is named. This is what the Copy button, the menu and Ctrl and C
---   all come to.
--- @param index number|nil # The level, in chain order.
--- @return boolean, string|nil # Whether something was copied, and what.
--
function Pointer:CopyAddress(index)
    if not self:Editable() then
        status(self, "There is no pointer to copy an address from.")
        return false
    end
    local address = self:AddressAt(index)
    if address == nil then
        status(self, index ~= nil
            and ("Level " .. index .. " could not be read, so there is no address to copy.")
            or "The chain could not be read, so there is no address to copy.")
        return false
    end
    local text = hexOf(address)
    local what = index ~= nil and ("the address of level " .. index .. ", " .. text)
        or ("the address the chain resolves to, " .. text)
    return toClipboard(self, text, what), text
end

--
--- ∑ The chain as one line, the base first and then every offset in the order
---   they are walked, the way the window copies a record's pointer. Paste path
---   reads it back.
--- @return string|nil
--
function Pointer:PathText()
    local buffer = self.Buffer
    if buffer == nil then return nil end
    local parts = { trim(buffer.Base) }
    for _, offset in ipairs(buffer.Offsets) do parts[#parts + 1] = trim(offset) end
    return table.concat(parts, " -> ")
end

--- Copies the chain as a path.
function Pointer:CopyPath()
    if not self:Editable() then
        status(self, "There is no pointer path to copy.")
        return false
    end
    local text = self:PathText()
    return toClipboard(self, text, "the pointer path"), text
end

--------------------------------------------------------
--                     The buffer                     --
--------------------------------------------------------

--- Takes the base edit's text into the buffer. The Loading flag is what keeps
--- this quiet while the page is the one writing the text, because setting Text
--- in code fires OnChange.
function Pointer:TakeBase()
    if self.Loading or not self:Editable() then return end
    local text = ""
    pcall(function() text = tostring(self.BaseEdit.Text or "") end)
    self.Buffer.Base = text
    self:Apply()
end

--- Takes the offset edit's text into the level it is on.
function Pointer:TakeOffset()
    if self.Loading or not self:Editable() or self.Level == nil then return end
    local text = ""
    pcall(function() text = tostring(self.OffsetEdit.Text or "") end)
    self.Buffer.Offsets[self.Level] = text
    self:Apply()
end

--
--- ∑ Runs one of the bottom row's actions by key, so the buttons, the keyboard
---   and the tests all reach the same code.
--- @param key string
--- @return boolean
--
function Pointer:Run(key)
    if key == "Add" then return self:AddLevel() end
    if key == "Remove" then return self:RemoveLevel() end
    if key == "Up" then return self:MoveLevel(-1) end
    if key == "Down" then return self:MoveLevel(1) end
    if key == "Paste" then return self:PastePath() end
    return false
end

--
--- ∑ Adds a level under the one the person is on, or at the end when they are
---   on none. On a record with no offsets at all this is what turns a plain
---   address into a pointer.
--- @return boolean
--
function Pointer:AddLevel()
    if not self:Editable() then return false end
    local offsets = self.Buffer.Offsets
    if #offsets >= MAX_LEVELS then
        status(self, "A pointer chain is limited to " .. MAX_LEVELS .. " levels.")
        return false
    end
    local at = (self.Level or #offsets) + 1
    table.insert(offsets, at, DEFAULT_OFFSET)
    self:PickLevel(at)
    return true
end

--
--- ∑ Removes the level the person is on. Removing the last one makes the
---   record a plain address again, which is what Cheat Engine does when the
---   offset count reaches zero.
--- @return boolean
--
function Pointer:RemoveLevel()
    if not self:Editable() then return false end
    if self.Level == nil then
        status(self, "Pick a level first.")
        return false
    end
    local offsets = self.Buffer.Offsets
    table.remove(offsets, self.Level)
    local landing = #offsets > 0 and math.min(self.Level, #offsets) or nil
    self:PickLevel(landing)
    return true
end

--
--- ∑ Moves the level one step along the chain. A negative step walks towards
---   the base.
--- @param step number
--- @return boolean
--
function Pointer:MoveLevel(step)
    if not self:Editable() or self.Level == nil then return false end
    local offsets = self.Buffer.Offsets
    local to = self.Level + step
    if to < 1 or to > #offsets then return false end
    offsets[self.Level], offsets[to] = offsets[to], offsets[self.Level]
    self:PickLevel(to)
    return true
end

--
--- ∑ Replaces the whole buffer with a pasted path.
---
---   Without a text of its own it reads the clipboard, which is where a path
---   copied out of Cheat Engine's pointer scanner or out of a forum post is.
--- @param text string|nil
--- @return boolean
--
function Pointer:PastePath(text)
    if not self:Editable() then return false end
    local fromClipboard = text == nil
    if fromClipboard and self.CE ~= nil then text = self.CE:FromClipboard() end
    if text == nil or trim(text) == "" then
        status(self, fromClipboard
            and "There is no pointer path on the clipboard."
            or "There is no pointer path to read.")
        return false
    end
    local path, err = Pointer.ParsePath(text)
    if path == nil then
        status(self, err)
        return false
    end
    self.Buffer = { Base = path.Base, Offsets = path.Offsets }
    self.Level = nil
    self.Loading = true
    safeSet(self.BaseEdit, "Text", path.Base)
    safeSet(self.OffsetEdit, "Text", "")
    self.Loading = false
    self:PickLevel(#path.Offsets > 0 and 1 or nil)
    status(self, "Read a chain of " .. #path.Offsets .. " levels. Apply writes it to the record.")
    return true
end

--------------------------------------------------------
--                Saving and reverting                --
--------------------------------------------------------

--- True while the buffer says something the record does not.
function Pointer:IsDirty()
    if self.Buffer == nil or self.Baseline == nil then return false end
    return not Pointer.SamePointer(self.Buffer, self.Baseline)
end

--
--- ∑ Whether the buffer is something Cheat Engine could be given.
--- @return boolean
--- @return string|nil
--
function Pointer:Validate()
    local buffer = self.Buffer
    if buffer == nil then return false, "There is no record to write to." end
    if trim(buffer.Base) == "" then return false, "Type a base address." end
    if #buffer.Offsets > MAX_LEVELS then
        return false, "A pointer chain is limited to " .. MAX_LEVELS .. " levels."
    end
    for index, text in ipairs(buffer.Offsets) do
        if Pointer.OffsetValue(text) == nil then
            return false, "Level " .. index .. " is not a hexadecimal number."
        end
    end
    return true
end

--- The name this page puts in a label, which is the description or the id when
--- the record has none.
function Pointer:Name()
    local node = self.Snapshot ~= nil and self.Snapshot.ByID ~= nil
        and self.Snapshot.ByID[self.ID] or nil
    local name = node ~= nil and node.Description or nil
    if name == nil or name == "" then return "#" .. tostring(self.ID) end
    return name
end

--
--- ∑ Hands the whole chain up as one pointer change.
---
---   One change and not one per level, because Cheat Engine clears the offsets
---   when the address is written and a chain applied in pieces would point at
---   nothing in between. The buffer is cleared only when the commit came back
---   ok with something applied, which is what keeps an edit alive through a
---   refused write.
--- @return boolean
--
function Pointer:Save()
    if not self:Editable() then
        status(self, "There is no record to write to.")
        return false
    end
    if not self:IsDirty() then return true end
    local ok, err = self:Validate()
    if not ok then
        status(self, err)
        return false
    end
    if type(self.OnCommit) ~= "function" then
        status(self, "This page is not connected to the window.")
        return false
    end
    local change = {
        Kind = "pointer",
        ID = self.ID,
        Old = { Base = self.Baseline.Base, Offsets = Pointer.Reverse(self.Baseline.Offsets) },
        New = { Base = self.Buffer.Base, Offsets = Pointer.Reverse(self.Buffer.Offsets) }
    }
    local committed, applied, failures = self.OnCommit({
        Label = "Pointer on '" .. self:Name() .. "'",
        Changes = { change }
    })
    if committed == true and (tonumber(applied) or 0) > 0 then
        self.Baseline = { Base = self.Buffer.Base, Offsets = copyList(self.Buffer.Offsets) }
        self:Apply()
        return true
    end
    status(self, reasonOf(failures) or "The pointer was not written.")
    self:Apply()
    return false
end

--- Throws the buffer away and reads the record again.
function Pointer:Discard()
    if self.ID == nil then return end
    self:Load()
end

--- What the Revert button does, which is Discard plus a word about it.
function Pointer:Revert()
    if not self:IsDirty() then return false end
    self:Discard()
    status(self, "The pointer chain was read again from the record.")
    return true
end

--------------------------------------------------------
--                  The page contract                 --
--------------------------------------------------------

--
--- ∑ Takes a newer snapshot without throwing away what the person typed.
---
---   The live values are rebuilt either way, because a pointer moves while the
---   game runs and a chain nobody touched should still show where it lands now.
---   A clean page reads the record again and only rebuilds its edits when the
---   record really moved, because a sync tick that reset the picked level every
---   quarter of a second would make the page unusable.
--- @param snapshot table|nil
--- @param changedIds table|nil # A list or a set of ids. Ignored, because the
---        chain itself is compared and that is a better answer.
--- @return nil
--
function Pointer:Refresh(snapshot, changedIds)
    self.Snapshot = snapshot or self.Snapshot
    if self.ID == nil then
        self:Show(self.IDs, self.Snapshot)
        return
    end
    local node = self.Snapshot ~= nil and self.Snapshot.ByID ~= nil
        and self.Snapshot.ByID[self.ID] or nil
    if node == nil then
        self.ID, self.Reason = nil, "That record is gone"
        self:Load()
        return
    end
    if not self:IsDirty() then
        local fresh = self:ReadRecord()
        if not Pointer.SamePointer(fresh, self.Baseline) then self:Adopt(fresh) end
    end
    self:Apply()
end

--- The line the inspector's header shows while this page is the active one.
function Pointer:Title()
    if self.ID == nil then return self.Reason or "Nothing to edit" end
    local levels = self.Buffer ~= nil and #self.Buffer.Offsets or 0
    local text
    if levels == 0 then
        text = self:Name() .. ", plain address"
    elseif levels == 1 then
        text = self:Name() .. ", 1 level"
    else
        text = self:Name() .. ", " .. levels .. " levels"
    end
    if self:IsDirty() then text = text .. " *" end
    return text
end

--- Whether one of this page's own text boxes has the keyboard.
function Pointer:Typing()
    for _, key in ipairs({ "Base", "Offset", "Resolved" }) do
        local row = self.Rows[key]
        if row ~= nil and hasFocus(row.Input) then return true end
    end
    return false
end

--
--- ∑ The keys this page answers. A canvas never takes focus, so the window
---   feeds them in from its own handler.
---
---   The window cannot tell this page's text boxes from the list, so the page
---   does. While a box has the keyboard only Ctrl and S is taken, and every
---   other key goes to the box, which is where Ctrl and C copies the selected
---   text and Home moves the caret. Otherwise Ctrl and C copies the address of
---   the picked level, and of the whole chain when none is picked.
--- @param key number # A virtual key code.
--- @return boolean # Whether the key was used.
--
function Pointer:HandleKey(key)
    if self.List == nil then return false end
    local ce = self.CE
    local ctrlDown = ce ~= nil and ce:IsKeyDown(VK_CONTROL) or false
    if ctrlDown and key == VK_S then
        self:Save()
        return true
    end
    if self:Typing() then return false end
    if ctrlDown and key == VK_C then
        if not self:Editable() then return false end
        self:CopyAddress(self.Level)
        return true
    end
    if key == VK_RETURN then
        return self.List:HandleKey(key) == true
    end
    if not self:Editable() then return false end
    local used = self.List:HandleKey(key) == true
    if used then self:PickLevel(self.List:SelectedIndex()) end
    return used
end

--- Releases the canvas. Every control belongs to the inspector's page panel and
--- is freed with the form, so nothing else is destroyed here.
function Pointer:Destroy()
    if self.Surface ~= nil then
        self.Surface:Destroy()
        self.Surface = nil
    end
    self.List, self.Empty = nil, nil
    self.BaseEdit, self.OffsetEdit, self.BaseLabel, self.OffsetCaption = nil, nil, nil, nil
    self.ResolvedEdit, self.LevelBar, self.ActionBar, self.Menu = nil, nil, nil, nil
    self.Buttons, self.Controls, self.Rows, self.BaseText = {}, {}, {}, ""
    self.Parent, self.Host = nil, nil
    self.Buffer, self.Baseline, self.LevelRows = nil, nil, {}
    self.ID, self.Level = nil, nil
end

return Pointer
