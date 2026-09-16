--[[
    The results strip at the bottom of the window.

    Three things end up in the same place. The problem check writes its findings
    here, Find all writes its hits here and the session change list writes the
    edits made in this window here. They are one strip and not three, because a
    person only ever looks at one of them at a time and three cards would eat
    the bottom of the window for good.

    It is a thin shell over Surface.ListPainter, which already owns the
    columns, the hit testing, the hover, the one row selection, the scrollbar
    and the arrow keys. What is left here is what the three kinds do not share,
    which is the tag a row shows, the colour that tag draws in, how wide the tag
    column has to be for it and the two lines a strip with nothing in it puts in
    the middle of its canvas.

    The tag column is sized for the rows in hand rather than for the widest tag
    any of the three kinds could ever produce. A list of problems tags every row
    ERR, WRN or INF, and a column wide enough for the word Description would
    then leave eight characters of nothing on every row of it.

    A row is a record and not a line of text. Picking one tells the window
    which record it was, so the tree can select that record, and opening one
    tells the window to take the person to it, which for a script hit means the
    Script page at the line the hit was on.

    Nothing here holds a memory record. Every item carries the record id and
    the window resolves it when it needs the record itself.
]]

local SurfaceModule = require("Manifold-AddressList-Surface")

local Results = {}
Results.__index = Results

--
--- ∑ The three kinds of result, and what each one says when it is empty.
---
---   The kind decides the tag column and nothing else, which is why they live
---   in one table rather than in three branches spread through the file.
--
Results.Kinds = {
    Problems = {
        Title = "No problems found",
        Hint = "The table passed every check."
    },
    Matches = {
        Title = "No matches",
        Hint = "Nothing in the table matched what you looked for."
    },
    Changes = {
        Title = "Nothing has changed yet",
        Hint = "Edits you make in this window are listed here."
    }
}

--- What the strip says before any of the three has ever run.
Results.EmptyTitle = "Nothing to show"
Results.EmptyHint = "Run Problems or Find all to fill this strip."

--- The three letter tags a problem row shows. Three letters keep the column
--- narrow and they line up under each other, which a word would not.
local SEVERITY_TAG = { error = "ERR", warning = "WRN", info = "INF" }

--- The colour key each severity draws its tag in.
local SEVERITY_COLOR = { error = "Error", warning = "Warning", info = "Info" }

--
--- ∑ The column widths, in characters. A width of zero takes what is left.
--
Results.Columns = {
    --- The narrowest the tag column is ever drawn, which is what a list of
    --- problems needs and nothing more.
    TagMin = 3,
    --- The widest it is allowed to grow to. A field name is the longest tag any
    --- of the three kinds produces and Description is eleven characters.
    TagMax = 11,
    --- The record path. Wide enough for a group and a record.
    Label = 34
}

--- The three dots a cut label breaks with. ASCII, because a canvas draws what
--- the font has and a single glyph ellipsis is not in every one of them.
local ELLIPSIS = "..."

--------------------------------------------------------
--                   Small helpers                    --
--------------------------------------------------------

--- Sends one line to the log channel when there is one.
local function say(self, level, message)
    local sink = self and self.Log
    if sink == nil then return end
    local method = sink[level]
    if type(method) ~= "function" then return end
    pcall(method, sink, message)
end

--- Calls one of the owner's hooks without letting a defect in it reach the
--- painting loop.
local function fire(handler, ...)
    if type(handler) ~= "function" then return end
    pcall(handler, ...)
end

--
--- ∑ The tag one row shows.
---
---   A problem shows its severity, a match shows which field it was found in
---   and a change shows the time it happened, which the window puts in the tag
---   itself. An item that already carries a tag keeps it.
--- @param kind string|nil
--- @param item table
--- @return string
--
local function tagFor(kind, item)
    if type(item.Tag) == "string" and item.Tag ~= "" then return item.Tag end
    if kind == "Problems" then
        return SEVERITY_TAG[item.Severity] or "INF"
    end
    if kind == "Matches" then
        return tostring(item.Field or "")
    end
    return ""
end

--
--- ∑ The label one row shows.
---
---   The record path, and the line number behind it when the hit or the problem
---   sits on one. Without it a person reading a list of script findings has no
---   way to tell which of six hits in one script a row is about.
---
---   A path too long for the column loses characters out of its MIDDLE. The
---   group at the front is what several rows share and the record name at the
---   end is what tells them apart, so cutting the tail off would leave two
---   problems in one group reading exactly the same.
--- @param item table
--- @param room number # How many characters the column holds.
--- @return string
--
local function labelFor(item, room)
    local label = tostring(item.Label or "")
    local line = tonumber(item.Line)
    if line ~= nil then
        if label == "" then
            label = "line " .. math.floor(line)
        else
            label = label .. "  (line " .. math.floor(line) .. ")"
        end
    end
    room = math.floor(tonumber(room) or 0)
    if room <= 0 or #label <= room then return label end
    local keep = room - #ELLIPSIS
    if keep < 2 then return label:sub(#label - room + 1) end
    -- The tail takes the larger half, because the record name lives there.
    local tail = math.ceil(keep / 2)
    return label:sub(1, keep - tail) .. ELLIPSIS .. label:sub(#label - tail + 1)
end

--
--- ∑ How wide the tag column has to be for the rows the strip is holding.
---
---   A field name needs eleven characters and ERR needs three, and a list of
---   problems that reserved eleven for a three letter tag would spend most of a
---   column on nothing on every row it drew. The widest tag in hand decides it,
---   so the three kinds each get the column they need.
--- @param items table
--- @return number # A width in characters.
--
local function tagWidth(items)
    local widest = Results.Columns.TagMin
    for _, item in ipairs(items) do
        local length = #tostring(item.Tag or "")
        if length > widest then widest = length end
    end
    if widest > Results.Columns.TagMax then return Results.Columns.TagMax end
    return widest
end

--
--- ∑ Where the needle sits inside the message, so the list painter can fill
---   behind it.
---
---   A search hit carries the column and the length of the match inside its own
---   excerpt, which is what the message column shows, so the span is those two
---   numbers and no searching has to happen twice.
--- @param item table
--- @return table|nil
--
local function spansFor(item)
    if type(item.Spans) == "table" then return item.Spans end
    local column, length = tonumber(item.Column), tonumber(item.Length)
    if column == nil or length == nil or length <= 0 then return nil end
    return { Message = { { Start = column, Stop = column + length - 1 } } }
end

--------------------------------------------------------
--                    Construction                    --
--------------------------------------------------------

--
--- ∑ Builds the strip. Nothing is created until Attach, so the window can hold
---   one before the results card exists.
--- @param services table|nil # Theme, Surface, Log, Settings and Frame.
--- @return table
--
function Results:New(services)
    services = services or {}
    return setmetatable({
        Theme = services.Theme,
        Log = services.Log,
        Settings = services.Settings,
        Frame = services.Frame,
        SurfaceClass = services.Surface or SurfaceModule,

        Surface = nil,
        List = nil,
        Parent = nil,

        ItemKind = nil,     -- Problems, Matches or Changes
        Items = {},         -- what SetItems normalised
        TagWidth = Results.Columns.TagMin,   -- in characters, from the tags in hand

        OnPick = nil,
        OnOpen = nil
    }, Results)
end

--
--- ∑ Creates the canvas inside parent and puts a list painter on it.
---
---   The list is built before the canvas is attached, so a build with neither a
---   paint box nor an image still answers Count, Selected and the arrow keys
---   while the window shows its fallback.
--- @param parent userdata
--- @return boolean, string|nil
--
function Results:Attach(parent)
    self.Parent = parent
    local surface = self.SurfaceClass:New({
        Theme = self.Theme, Log = self.Log, Settings = self.Settings,
        Frame = self.Frame, Name = "Results"
    })
    self.Surface = surface
    self.List = surface:ListPainter({
        Stripe = true,
        OnPick = function(item) fire(self.OnPick, item) end,
        OnOpen = function(item) fire(self.OnOpen, item) end
    })
    self:ApplyColumns()
    self:ApplyEmpty()
    self.List:SetItems(self.Items)

    local ok, reason = surface:Attach(parent)
    if not ok then
        say(self, "Warning", "The results strip has no canvas, " .. tostring(reason))
        return false, reason
    end
    return true
end

--
--- ∑ Puts the columns on the list, with the tag column sized for the rows the
---   strip is holding.
---
---   One writer for the three of them, so Attach and SetItems cannot end up
---   disagreeing about where the message column starts.
--- @return nil
--
function Results:ApplyColumns()
    self.TagWidth = tagWidth(self.Items)
    if self.List == nil then return end
    self.List:SetColumns({
        { Key = "Tag", Width = self.TagWidth, ColorKey = "Muted" },
        { Key = "Label", Width = Results.Columns.Label, ColorKey = "Muted" },
        { Key = "Message", Width = 0, ColorKey = "Text" }
    })
end

--- The two lines the strip shows while it holds nothing, which depend on what
--- the strip was last asked to show.
function Results:ApplyEmpty()
    if self.List == nil then return end
    local kind = Results.Kinds[self.ItemKind]
    if kind == nil then
        self.List:SetEmpty(Results.EmptyTitle, Results.EmptyHint)
        return
    end
    self.List:SetEmpty(kind.Title, kind.Hint)
end

--------------------------------------------------------
--                     The items                      --
--------------------------------------------------------

--
--- ∑ Fills the strip.
---
---   Every item is copied into the shape the list painter reads, so the caller
---   hands over whatever the problem check, the search or the change list
---   produced and nothing has to be reshaped twice.
--- @param kind string|nil # Problems, Matches or Changes.
--- @param items table|nil
--- @return number # How many rows there are now.
--
function Results:SetItems(kind, items)
    local changed = kind ~= self.ItemKind
    self.ItemKind = kind
    local out = {}
    for index, item in ipairs(items or {}) do
        local colorKey = "Muted"
        if kind == "Problems" then
            colorKey = SEVERITY_COLOR[item.Severity] or "Info"
        end
        out[index] = {
            ID = item.ID,
            Tag = tagFor(kind, item),
            Label = labelFor(item, Results.Columns.Label),
            Message = tostring(item.Message or ""),
            Severity = item.Severity,
            Line = item.Line,
            Field = item.Field,
            Spans = spansFor(item),
            -- The tag is the only column whose colour changes per row, and the
            -- list painter reads the override off the item itself.
            ColorKeys = { Tag = colorKey },
            Source = item
        }
    end
    self.Items = out
    self:ApplyColumns()
    self:ApplyEmpty()
    if self.List ~= nil then
        -- A different kind is a different list, so nothing is followed across
        -- the change and the strip starts at the top of what it now shows.
        if changed then self.List:ClearSelection() end
        self.List:SetItems(out)
        if changed and self.Surface ~= nil then self.Surface:ScrollTo(1) end
    end
    return #out
end

function Results:Count()
    return #self.Items
end

function Results:Kind()
    return self.ItemKind
end

--- The row the person is on, or nothing when nothing was picked.
function Results:Selected()
    if self.List == nil then return nil end
    return self.List:SelectedItem()
end

--- The item the window handed in for the picked row, which is what the caller
--- recognises. The row itself is this module's own shape.
function Results:SelectedSource()
    local item = self:Selected()
    return item and item.Source or nil
end

--
--- ∑ Picks one row without the person having clicked it, which is how the
---   window keeps the strip in step with the tree.
--- @param index number
--- @param silent boolean|nil
--- @return table|nil
--
function Results:Select(index, silent)
    if self.List == nil then return nil end
    return self.List:Select(index, silent)
end

--- The first row that belongs to a record, so selecting a record in the tree
--- can move the strip to it.
function Results:IndexOfID(id)
    for index, item in ipairs(self.Items) do
        if item.ID == id then return index end
    end
    return nil
end

function Results:Clear()
    return self:SetItems(self.ItemKind, {})
end

--------------------------------------------------------
--                    The keyboard                    --
--------------------------------------------------------

--
--- ∑ The keys the strip answers. A canvas never takes focus, so the window
---   feeds them in from its own key handler.
--- @param key number # A virtual key code.
--- @return boolean # Whether the key was used.
--
function Results:HandleKey(key)
    if self.List == nil then return false end
    return self.List:HandleKey(key) == true
end

--------------------------------------------------------
--                      Teardown                      --
--------------------------------------------------------

--- Releases the canvas and leaves the frame service. The card it was drawn on
--- belongs to the window and is freed with it.
function Results:Destroy()
    if self.Surface ~= nil then
        self.Surface:Destroy()
        self.Surface = nil
    end
    self.List, self.Parent = nil, nil
    self.Items = {}
end

return Results
