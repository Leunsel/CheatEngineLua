--[[
    Theming and layout for the Table Files window.

    Self-contained on purpose, for the same reason the Template Loader's copy
    is. This module must not load Manifold.Forms: that module defines the
    global "Forms" class and belongs to the Cheat Table's lifecycle, so a
    second copy loaded from autorun is exactly the collision
    Manifold.Bootstrap exists to detect. Instead it speaks the same visual
    language (cards with a border, a header strip and a content area, panel
    buttons with hover, a status line) and adopts the Table's palette
    read-only when one is live.

    Palette source, in order:
      1. forms.ActiveDesignTheme of a live Manifold.Forms instance,
      2. the bundled Manifold "Bearded-Arc" theme.

    This is a sibling of Manifold-TemplateLoader-Theme, not a require of it.
    Copying is the point: the loader lives in its own autorun tree and may be
    absent, upgraded or reloaded independently, and a viewer that edits files
    needs things a read-only preview never did. The differences from that
    copy, all additive:

      * CreateCodeView takes options and can hand back a writable editor.
        The loader only ever previews generated code.
      * StyleListView and AddListColumn, for the file list.
      * CreateToolBar, CreateToolSeparator and CreateSplitter, for the
        two-pane layout.
      * CreateEmptyState, for the panel shown when nothing is open or the
        file is not editable.
      * CreatePopupMenu, for the two context menus.
      * AskChoice and AskText. messageDialog tops out at the button set the
        LCL offers and the constants for a third button are not guaranteed to
        be defined, so "Save / Discard / Cancel" and "Replace / Skip / Keep
        both / Cancel" are built here instead: one mechanism, themed, and
        dependent on nothing this Cheat Engine build might lack.

    Layout rule for every window here: content is Align-driven, never
    absolute. A toolbar sits at the top, a button bar at the bottom, a status
    line below it, and the content fills the rest, so the window resizes
    properly.

    Cheat Engine specifics this file relies on, all verified against the CE
    7.5 and Lazarus sources:
      * CE's Lua __index resolves a name as (1) a published property, then
        (2) FindComponent on TComponent. TSynGutter publishes Color, Visible,
        Width and Parts. The parts list is a TComponent whose children carry
        the fixed names SynGutterMarks1, SynGutterLineNumber1,
        SynGutterChanges1, SynGutterSeparator1 and SynGutterCodeFolding1
        (TSynGutter.CreateDefaultGutterParts). That is the only way to reach
        the gutter styling, none of it is in CE's explicit SynEdit binding,
        which covers Lines/SelStart/SelEnd/... only.
      * TSynGutterLineNumber publishes MarkupInfo, whose Background and
        Foreground come from TSynHighlighterAttributes. Setting the gutter
        Color alone leaves the line numbers on their own light background,
        which is what makes an otherwise dark editor show a white gutter.
      * TSynAASyn hard-codes its token colors and exposes no attributes to
        Lua, so the code area's own colors are left to Cheat Engine.
      * Native TButton ignores Color on Win32, so buttons are panels with a
        centered label, the same technique Manifold.Forms uses.
      * TListView paints its background and text from Color and Font, but the
        selection bar comes from the system highlight brush and is not
        reachable without owner drawing. StyleListView therefore themes the
        list itself and leaves the selection to Windows.
]]

local Theme = {}
Theme.__index = Theme

--- Bearded-Arc, as Cheat Engine BGR integers (the JSON stores #RRGGBB).
Theme.Default = {
    COLOR_BG         = 0x0A0305, -- #05030a
    COLOR_PANEL      = 0x1A1013, -- #13101a
    COLOR_ACCENT     = 0x61CDEA, -- #eacd61
    COLOR_TEXT       = 0xFFBFFF, -- #FFBFFF
    COLOR_LABEL      = 0x61CDEA, -- #eacd61
    COLOR_BTN        = 0x1A1013, -- #13101a
    COLOR_BTN_HOVER  = 0x61CDEA, -- #eacd61
    COLOR_BTN_TEXT   = 0xFFBFFF, -- #FFBFFF
    COLOR_INPUT      = 0x0A0305, -- #05030a
    COLOR_INPUT_TEXT = 0xFF7FBF, -- #BF7FFF
    COLOR_BORDER     = 0x61CDEA, -- #eacd61
    COLOR_MUTED      = 0xE1BA8D  -- #8dbae1
}

Theme.FontName = "Consolas"
Theme.FontSize = 10

function Theme:New(services)
    return setmetatable({
        Log = services and services.Log,
        Palette = nil
    }, Theme)
end

local function safeSet(control, property, value)
    if not control then return false end
    return (pcall(function() control[property] = value end))
end

local function safeFont(control, color, size, style)
    pcall(function()
        local font = control.Font
        font.Name = Theme.FontName
        font.Size = size or Theme.FontSize
        if color then font.Color = color end
        if style then font.Style = style end
    end)
end

local function setSpacing(control, spacing)
    if type(spacing) ~= "table" then return end
    pcall(function()
        local borderSpacing = control.BorderSpacing
        for key, value in pairs(spacing) do borderSpacing[key] = value end
    end)
end

Theme.SafeSet = safeSet
Theme.SafeFont = safeFont

--
--- The active palette. A live Manifold.Forms instance with an applied theme
--- wins, so this window follows the Cheat Table's theme. It is re-read per
--- call so a theme change is picked up by the next window that opens.
--
function Theme:GetPalette()
    local forms = rawget(_G, "forms")
    local ok, design = pcall(function()
        return type(forms) == "table" and forms.ActiveDesignTheme or nil
    end)
    if ok and type(design) == "table" and design.COLOR_BG then
        local palette = {}
        for key, value in pairs(Theme.Default) do
            palette[key] = design[key] or value
        end
        return palette
    end
    return self.Palette or Theme.Default
end

-- Windows and layout ----------------------------------------------------------

--
--- A resizeable themed window. ESC closes it. The buttons are panels, so
--- there is no native Cancel button to do that.
--
function Theme:CreateWindow(caption, width, height)
    local palette = self:GetPalette()
    local form = createForm(false)
    form.Caption = caption
    form.Position = "poScreenCenter"
    form.BorderStyle = "bsSizeable"
    form.Width = width or 720
    form.Height = height or 520
    safeSet(form, "Color", palette.COLOR_BG)
    safeFont(form, palette.COLOR_TEXT)
    pcall(function()
        local constraints = form.Constraints
        constraints.MinWidth = 560
        constraints.MinHeight = 320
    end)
    pcall(function()
        form.KeyPreview = true
        form.OnKeyDown = function(sender, key)
            if key == 27 then
                form.ModalResult = rawget(_G, "mrCancel") or 2
                pcall(function() form.Close() end)
            end
            return key
        end
    end)
    return form, palette
end

function Theme:CreatePanel(parent, options)
    options = options or {}
    local palette = self:GetPalette()
    local panel = createPanel(parent)
    safeSet(panel, "Parent", parent)
    safeSet(panel, "Caption", "")
    safeSet(panel, "ParentColor", false)
    safeSet(panel, "Color", options.Color or palette.COLOR_PANEL)
    safeSet(panel, "BevelOuter", options.BevelOuter or "bvNone")
    if options.BevelWidth then safeSet(panel, "BevelWidth", options.BevelWidth) end
    if options.BevelColor then safeSet(panel, "BevelColor", options.BevelColor) end
    if options.Align then safeSet(panel, "Align", options.Align) end
    if options.Height then safeSet(panel, "Height", options.Height) end
    if options.Width then safeSet(panel, "Width", options.Width) end
    setSpacing(panel, options.Spacing)
    return panel
end

--
--- A bordered card with a header strip, in the Manifold.Forms idiom.
--- border panel -> body panel -> header + content. Returns the content
--- panel (where callers put their control, aligned alClient) plus the card
--- and its header label.
--
function Theme:CreateCard(parent, options)
    options = options or {}
    local palette = self:GetPalette()
    local card = self:CreatePanel(parent, {
        Align = options.Align or "alClient",
        Height = options.Height,
        Width = options.Width,
        Color = palette.COLOR_BORDER,
        BevelOuter = "bvNone",
        Spacing = options.Spacing or { Around = 8 }
    })
    local body = self:CreatePanel(card, {
        Align = "alClient",
        Color = palette.COLOR_PANEL,
        Spacing = { Around = 1 }
    })
    local headerLabel
    if options.Title then
        local header = self:CreatePanel(body, {
            Align = "alTop",
            Height = 24,
            Color = palette.COLOR_PANEL
        })
        headerLabel = createLabel(header)
        safeSet(headerLabel, "Parent", header)
        safeSet(headerLabel, "Align", "alClient")
        safeSet(headerLabel, "Layout", "tlCenter")
        safeSet(headerLabel, "Transparent", true)
        headerLabel.Caption = options.Title
        safeFont(headerLabel, palette.COLOR_LABEL, Theme.FontSize, "[fsBold]")
        setSpacing(headerLabel, { Left = 8 })
    end
    local content = self:CreatePanel(body, {
        Align = "alClient",
        Color = options.ContentColor or palette.COLOR_INPUT,
        Spacing = options.ContentSpacing or { Around = 6 }
    })
    return content, card, headerLabel
end

--
--- Bottom button bar. Buttons added to it with Align = "alRight" appear
--- right to left in creation order, so create the rightmost one first.
--
function Theme:CreateButtonBar(parent, height)
    return self:CreatePanel(parent, {
        Align = "alBottom",
        Height = height or 44,
        Spacing = { Left = 8, Right = 8, Bottom = 8 }
    })
end

--
--- Top strip for actions. The mirror image of CreateButtonBar: buttons
--- aligned alLeft appear left to right in creation order, so the bar reads
--- in the order it is built.
--
function Theme:CreateToolBar(parent, height)
    return self:CreatePanel(parent, {
        Align = "alTop",
        Height = height or 44,
        Spacing = { Left = 8, Right = 8, Top = 8 }
    })
end

--
--- Status line at the very bottom. Two labels rather than one: what is
--- happening on the left, quieter detail on the right, so the line can carry
--- several facts without becoming a run-on sentence. Returns both plus the
--- bar.
--
function Theme:CreateStatusBar(parent, text)
    local palette = self:GetPalette()
    local bar = self:CreatePanel(parent, {
        Align = "alBottom",
        Height = 24,
        Color = palette.COLOR_PANEL,
        Spacing = { Left = 8, Right = 8, Bottom = 4 }
    })
    -- alRight before alClient: the detail claims its width, the primary
    -- label takes what is left.
    local detail = createLabel(bar)
    safeSet(detail, "Parent", bar)
    safeSet(detail, "Align", "alRight")
    safeSet(detail, "Layout", "tlCenter")
    safeSet(detail, "Alignment", "taRightJustify")
    safeSet(detail, "Transparent", true)
    detail.Caption = ""
    safeFont(detail, palette.COLOR_MUTED)
    setSpacing(detail, { Right = 6 })

    local label = createLabel(bar)
    safeSet(label, "Parent", bar)
    safeSet(label, "Align", "alClient")
    safeSet(label, "Layout", "tlCenter")
    safeSet(label, "Transparent", true)
    label.Caption = text or ""
    safeFont(label, palette.COLOR_MUTED)
    setSpacing(label, { Left = 6 })
    return label, bar, detail
end

--
--- A thin vertical rule for grouping toolbar buttons. Aligned like a button
--- so it takes its place in the same left-to-right stack.
---
--- One panel, one pixel wide. An earlier version put an alClient child inside
--- a wider holder to draw the line, which does not work: alClient overrides
--- Width, so the "rule" filled the whole holder and the separator came out as
--- a solid bar the width of the gap. The margins do the spacing instead, and
--- Top/Bottom keep the rule short of the bar's full height.
--
function Theme:CreateToolSeparator(parent)
    local palette = self:GetPalette()
    return self:CreatePanel(parent, {
        Align = "alLeft", Width = 1, Color = palette.COLOR_BORDER,
        Spacing = { Left = 8, Right = 8, Top = 9, Bottom = 9 }
    })
end

--
--- A restrained empty state: a headline and a quieter line under it, both
--- centred in the area an editor would otherwise fill. Returns the panel and
--- a setter.
--
function Theme:CreateEmptyState(parent)
    local palette = self:GetPalette()
    local panel = self:CreatePanel(parent, {
        Align = "alClient",
        Color = palette.COLOR_INPUT
    })
    -- A middle band holding both labels, so the pair sits on the centre line
    -- instead of at the top edge.
    local band = self:CreatePanel(panel, {
        Align = "alClient", Color = palette.COLOR_INPUT
    })
    -- Hint first, headline second: alTop puts the last one built on top.
    local hint = createLabel(band)
    safeSet(hint, "Parent", band)
    safeSet(hint, "Align", "alTop")
    safeSet(hint, "Alignment", "taCenter")
    safeSet(hint, "Transparent", true)
    safeFont(hint, palette.COLOR_MUTED)

    local title = createLabel(band)
    safeSet(title, "Parent", band)
    safeSet(title, "Align", "alTop")
    safeSet(title, "Alignment", "taCenter")
    safeSet(title, "Transparent", true)
    safeFont(title, palette.COLOR_LABEL, Theme.FontSize, "[fsBold]")
    setSpacing(title, { Top = 96, Bottom = 6 })

    return {
        Panel = panel,
        Title = title,
        Hint = hint,
        Set = function(titleText, hintText)
            pcall(function() title.Caption = titleText or "" end)
            pcall(function() hint.Caption = hintText or "" end)
            pcall(function() hint.Visible = (hintText ~= nil and hintText ~= "") end)
        end
    }
end

--
--- A popup menu on a control.
---
--- Built the way Manifold.Teleporter builds its tree menu, which is the
--- pattern in this codebase that is known to work: the menu is owned by the
--- control it belongs to, it is assigned to that control's PopupMenu
--- straight away, and each item's handler is assigned directly rather than
--- through a wrapper.
---
--- Each item is built inside ONE pcall, and a failure is reported. An earlier
--- version wrapped every individual assignment in its own pcall, which
--- produced the worst possible outcome: a menu that rendered its captions and
--- shortcuts perfectly and did nothing at all when clicked, with no trace of
--- why.
---
--- Shortcut is set for display only. Cheat Engine does not dispatch a popup
--- menu's shortcuts, so the window keeps its own key handler; see
--- Viewer:HandleKey.
--- @param control table # The control the menu belongs to.
--- @return table|nil # { Menu, Add, Attach, Enable, Entries }, or nil where
---         Cheat Engine has no menu API.
--
function Theme:CreatePopupMenu(control)
    local createMenu = rawget(_G, "createPopupMenu")
    local createItem = rawget(_G, "createMenuItem")
    if type(createMenu) ~= "function" or type(createItem) ~= "function" then
        return nil
    end
    local ok, menu = pcall(createMenu, control)
    if not ok or not menu then
        if self.Log then self.Log("createPopupMenu failed: " .. tostring(menu), true) end
        return nil
    end
    if not (pcall(function() control.PopupMenu = menu end)) then
        if self.Log then self.Log("could not attach the popup menu to its control", true) end
    end

    local entries = {}
    local function add(caption, onClick, shortcut)
        local item
        local built, err = pcall(function()
            item = createItem(menu)
            item.Caption = caption
            if shortcut then item.Shortcut = shortcut end
            if onClick then item.OnClick = onClick end
            menu.Items.add(item)
        end)
        if not built then
            if self.Log then
                self.Log("menu entry '" .. tostring(caption) .. "' failed: " .. tostring(err), true)
            end
            return nil
        end
        if caption ~= "-" then entries[caption] = item end
        return item
    end
    --- Shows the same menu on another control, e.g. the second and third
    --- editors, which are separate SynEdits sharing one menu.
    local function attach(other)
        pcall(function() other.PopupMenu = menu end)
    end
    local function enable(caption, value)
        local item = entries[caption]
        if item then pcall(function() item.Enabled = value == true end) end
    end
    return { Menu = menu, Add = add, Attach = attach, Enable = enable, Entries = entries }
end

--
--- Draggable divider between two panes. Placed after the pane it resizes,
--- taking the same Align, which is how the LCL pairs the two.
--
function Theme:CreateSplitter(parent, options)
    options = options or {}
    local palette = self:GetPalette()
    local create = rawget(_G, "createSplitter")
    local splitter
    if type(create) == "function" then
        local ok, made = pcall(create, parent)
        if ok and made then splitter = made end
    end
    -- No createSplitter in this Cheat Engine: a thin panel keeps the visual
    -- seam, it just cannot be dragged.
    if not splitter then
        return self:CreatePanel(parent, {
            Align = options.Align or "alLeft",
            Width = 4,
            Color = palette.COLOR_BG
        })
    end
    safeSet(splitter, "Parent", parent)
    safeSet(splitter, "Align", options.Align or "alLeft")
    safeSet(splitter, "Width", options.Width or 4)
    safeSet(splitter, "MinSize", options.MinSize or 160)
    safeSet(splitter, "ResizeStyle", "rsUpdate")
    safeSet(splitter, "Beveled", false)
    safeSet(splitter, "ParentColor", false)
    safeSet(splitter, "Color", palette.COLOR_BG)
    return splitter
end

-- Controls --------------------------------------------------------------------

function Theme:StyleEdit(edit)
    local palette = self:GetPalette()
    safeSet(edit, "ParentColor", false)
    safeSet(edit, "Color", palette.COLOR_INPUT)
    safeSet(edit, "BorderStyle", "bsNone")
    safeFont(edit, palette.COLOR_INPUT_TEXT)
end

function Theme:StyleCheckBox(checkbox)
    local palette = self:GetPalette()
    safeFont(checkbox, palette.COLOR_TEXT)
end

--
--- Themes a list view. Color and Font reach the rows; the selection bar is
--- painted by the system highlight brush and stays as Windows draws it,
--- which is also the one part users already recognise as "selected".
---
--- The report-mode flags are set here rather than at the call site because
--- several of them only behave together: RowSelect without FullRowSelect
--- highlights the first column only, and HideSelection left on makes the
--- selection vanish the moment focus moves to the editor.
--- @param options table|nil # Images (a TImageList for the type glyphs).
--
function Theme:StyleListView(list, options)
    options = options or {}
    local palette = self:GetPalette()
    safeSet(list, "ParentColor", false)
    safeSet(list, "Color", palette.COLOR_INPUT)
    safeSet(list, "BorderStyle", "bsNone")
    safeFont(list, palette.COLOR_TEXT)
    safeSet(list, "ViewStyle", "vsReport")
    safeSet(list, "MultiSelect", true)
    safeSet(list, "RowSelect", true)
    safeSet(list, "FullRowSelect", true)
    safeSet(list, "ReadOnly", true)
    safeSet(list, "HideSelection", false)
    -- The last column absorbs the leftover width, which is what stops a
    -- horizontal scrollbar appearing every time the window is resized.
    safeSet(list, "AutoWidthLastColumn", false)
    if options.Images then
        safeSet(list, "SmallImages", options.Images)
    end
    return list
end

--
--- Adds a report column.
--- @param list table # The list view.
--- @param caption string # Header text.
--- @param width number # Width in pixels.
--- @return table|nil # The column.
--
function Theme:AddListColumn(list, caption, width)
    local column
    local ok = pcall(function() column = list.Columns.add() end)
    if not ok or not column then return nil end
    safeSet(column, "Caption", caption)
    safeSet(column, "Width", width)
    return column
end

--
--- Memos need the background set as explicitly as a SynEdit does. TMemo
--- inherits clWindow (white) and a read-only edit control on Win32 is
--- painted through WM_CTLCOLORSTATIC, so ParentColor must be off and Color
--- set for the assignment to take effect at all.
--- @param options table|nil # Background/Foreground override, e.g. the
---        colors of Cheat Engine's editor for a code view
--
function Theme:StyleMemo(memo, options)
    options = options or {}
    local palette = self:GetPalette()
    safeSet(memo, "ParentColor", false)
    safeSet(memo, "Color", options.Background or palette.COLOR_INPUT)
    safeSet(memo, "BorderStyle", "bsNone")
    safeFont(memo, options.Foreground or palette.COLOR_TEXT)
end

--
--- Themes a SynEdit's gutter. The text area itself is left alone. TSynAASyn
--- hard-codes token colors and exposes no attributes to Lua, so Cheat
--- Engine's own editor colors are both the readable and the familiar
--- choice. The gutter, however, keeps its light default and has to be
--- brought in line explicitly. Including the line-number MarkupInfo, which
--- paints its own background over the gutter Color.
--- @param options table|nil # KeepMarks leaves the bookmark strip visible,
---        which an editable view wants and a preview does not.
--
function Theme:StyleGutter(syn, options)
    options = options or {}
    local palette = self:GetPalette()
    local applied = {}
    applied.Border = safeSet(syn, "BorderStyle", "bsNone")
    local gutter
    local ok = pcall(function() gutter = syn.Gutter end)
    if not ok or not gutter then return applied end
    applied.Color = safeSet(gutter, "Color", palette.COLOR_PANEL)
    local parts
    if not pcall(function() parts = gutter.Parts end) or not parts then return applied end
    local function part(name)
        local item
        if pcall(function() item = parts[name] end) and item then return item end
        return nil
    end
    -- The bookmark strip is a wide empty column in a read-only view, but it
    -- is where an editable one puts its bookmarks.
    local marks = part("SynGutterMarks1")
    if marks then applied.Marks = safeSet(marks, "Visible", options.KeepMarks == true) end
    -- The change bar earns its place once the text can change; the separator
    -- line only ever adds noise.
    local changes = part("SynGutterChanges1")
    if changes then applied.Changes = safeSet(changes, "Visible", options.KeepChanges == true) end
    local separator = part("SynGutterSeparator1")
    if separator then applied.Separator = safeSet(separator, "Visible", false) end
    local lineNumbers = part("SynGutterLineNumber1")
    if lineNumbers then
        pcall(function()
            local markup = lineNumbers.MarkupInfo
            markup.Background = palette.COLOR_PANEL
            markup.Foreground = palette.COLOR_MUTED
            applied.LineNumbers = true
        end)
    end
    return applied
end

--
--- Memo filling its parent, themed and scrollable. Every memo here goes
--- through this so none of them can end up on the default white background.
--
function Theme:CreateMemo(parent, options)
    options = options or {}
    local memo = createMemo(parent)
    safeSet(memo, "Parent", parent)
    memo.ReadOnly = options.ReadOnly ~= false
    memo.ScrollBars = "ssBoth"
    memo.WordWrap = false
    safeSet(memo, "Align", "alClient")
    self:StyleMemo(memo, options)
    return memo
end

--
--- Background and text color for a code view, taken from Cheat Engine's own
--- editor rather than from this palette.
--- That indirection is deliberate. TSynAASyn loads its token colors from the
--- user's registry syntax settings and otherwise picks a dark or a light
--- default set from ShouldAppsUseDarkMode, and none of those attributes are
--- reachable from Lua. Copying the background CE uses for its own Auto
--- Assembler editor therefore guarantees the tokens stay readable in both
--- modes, which imposing a fixed palette color could not.
--- @return number|nil, number|nil # background, font color
--
function Theme:GetEditorColors()
    local background, foreground
    local function probe(editor)
        if background then return end
        pcall(function()
            local color = editor.Color
            if type(color) == "number" then
                background = color
                foreground = editor.Font.Color
            end
        end)
    end
    -- Any open Auto Assembler window is the best source: same highlighter,
    -- same light/dark decision.
    local count = 0
    pcall(function() count = tonumber(getFormCount()) or 0 end)
    for index = 0, count - 1 do
        local form
        pcall(function() form = getForm(index) end)
        local className
        pcall(function() className = form.ClassName end)
        if className == "TfrmAutoInject" then
            pcall(function() probe(form.Assemblescreen) end)
            if background then return background, foreground end
        end
    end
    -- The Lua Engine window is the fallback source. A different highlighter,
    -- but the same light/dark decision.
    pcall(function()
        local engine = getLuaEngine()
        if engine then probe(engine.mScript) end
    end)
    return background, foreground
end

--
--- Drops one option out of a SynEdit's option set.
---
--- TSynEdit.Options is a Lazarus set, which Cheat Engine surfaces as the
--- bracketed string form ("[eoAutoIndent,eoScrollPastEol,...]"), the same
--- convention as Font.Style. The set is rebuilt from its own tokens rather
--- than patched with a substitution, so no other option can be lost and the
--- result cannot end up malformed. If the property cannot be read the set is
--- left alone: clobbering it with a guess would be worse than the behaviour
--- being removed.
--- @param syn table # The SynEdit.
--- @param unwanted string # The option to drop, e.g. "eoScrollPastEol".
--- @return boolean # Whether the option was present and removed.
--
function Theme:DropEditorOption(syn, unwanted)
    local ok, options = pcall(function() return syn.Options end)
    if not ok or type(options) ~= "string" then return false end
    local kept, found = {}, false
    for token in options:gmatch("[%a][%w_]*") do
        if token == unwanted then
            found = true
        else
            kept[#kept + 1] = token
        end
    end
    if not found then return false end
    return (safeSet(syn, "Options", "[" .. table.concat(kept, ",") .. "]"))
end

--
--- Code view with Auto Assembler (mode 1) or Lua (mode 0) highlighting,
--- falling back to a themed memo. Returns the control plus getText/setText
--- so callers need not know which one they got.
---
--- createSynEdit fixes the highlighter when the control is built, so one
--- editor cannot switch between Lua and Auto Assembler. Callers that need
--- both build one per mode.
--- @param mode number|nil # 0 Lua, 1 Auto Assembler, nil plain text
--- @param options table|nil # ReadOnly (default true), Visible
--
function Theme:CreateCodeView(parent, mode, options)
    options = options or {}
    local readOnly = options.ReadOnly ~= false
    local palette = self:GetPalette()
    local background, foreground = self:GetEditorColors()
    local createSyn = rawget(_G, "createSynEdit")
    if mode ~= nil and type(createSyn) == "function" then
        local ok, syn = pcall(createSyn, parent, mode)
        if ok and syn then
            safeSet(syn, "Parent", parent)
            safeSet(syn, "Align", "alClient")
            safeSet(syn, "ReadOnly", readOnly)
            if options.Visible ~= nil then safeSet(syn, "Visible", options.Visible) end
            pcall(function()
                syn.Font.Name = Theme.FontName
                syn.Font.Size = Theme.FontSize
            end)
            -- TSynEdit.Color defaults to clWhite. Highlighter attributes
            -- paint their own background only up to the right edge column,
            -- so leaving Color unset shows a bright block beyond it. The
            -- reason Cheat Engine sets RightEdge = -1 on its own editors.
            -- Set both.
            safeSet(syn, "Color", background or palette.COLOR_INPUT)
            if type(foreground) == "number" then
                pcall(function() syn.Font.Color = foreground end)
            end
            safeSet(syn, "RightEdge", -1)
            safeSet(syn, "ScrollBars", "ssBoth")
            safeSet(syn, "WordWrap", false)
            -- Without this the caret can be put anywhere to the right of a
            -- line's last character and typing starts there, padding with
            -- spaces the user never asked for. A source editor should clamp
            -- to the end of the line.
            self:DropEditorOption(syn, "eoScrollPastEol")
            self:StyleGutter(syn, { KeepChanges = not readOnly })
            return syn,
                function() return syn.Lines.Text end,
                function(text) syn.Lines.Text = text end
        end
    end
    -- Fallback path. A memo showing the same content, so it gets the same
    -- colors the SynEdit would have received.
    local memo = self:CreateMemo(parent, {
        ReadOnly = readOnly,
        Background = background,
        Foreground = foreground
    })
    if options.Visible ~= nil then safeSet(memo, "Visible", options.Visible) end
    return memo,
        function() return memo.Lines.Text end,
        function(text) memo.Lines.Text = text end
end

--
--- Panel button with a centered label and hover feedback. opts:
--- Caption, Width, Height, Align (or Left/Top), Anchors, OnClick, Hint,
--- ModalResult together with Form to close a modal window.
--- Returns the button plus a setEnabled function; a panel has no Enabled
--- state of its own that reads as disabled, so it is drawn muted instead.
--
function Theme:CreateButton(parent, opts)
    local palette = self:GetPalette()
    local button = self:CreatePanel(parent, {
        Color = palette.COLOR_BTN,
        BevelOuter = "bvRaised",
        BevelWidth = 1,
        BevelColor = palette.COLOR_BORDER,
        Spacing = opts.Spacing or { Left = 6, Top = 6, Bottom = 6 }
    })
    button.Width = opts.Width or 92
    button.Height = opts.Height or 26
    if opts.Align then
        safeSet(button, "Align", opts.Align)
    else
        button.Left = opts.Left or 0
        button.Top = opts.Top or 0
    end
    if opts.Anchors then safeSet(button, "Anchors", opts.Anchors) end
    if opts.Hint then
        safeSet(button, "Hint", opts.Hint)
        safeSet(button, "ShowHint", true)
    end
    safeSet(button, "Cursor", -21) -- crHandPoint
    local label = createLabel(button)
    safeSet(label, "Parent", button)
    safeSet(label, "Align", "alClient")
    safeSet(label, "Alignment", "taCenter")
    safeSet(label, "Layout", "tlCenter")
    safeSet(label, "Transparent", true)
    label.Caption = opts.Caption or "Button"
    safeFont(label, palette.COLOR_BTN_TEXT, Theme.FontSize, "[fsBold]")
    if opts.Hint then
        safeSet(label, "Hint", opts.Hint)
        safeSet(label, "ShowHint", true)
    end

    local enabled = true
    local function paint(hovered)
        if not enabled then
            safeSet(button, "Color", palette.COLOR_BTN)
            safeFont(label, palette.COLOR_MUTED, Theme.FontSize, "[fsBold]")
        elseif hovered then
            safeSet(button, "Color", palette.COLOR_BTN_HOVER)
            safeFont(label, palette.COLOR_BG, Theme.FontSize, "[fsBold]")
        else
            safeSet(button, "Color", palette.COLOR_BTN)
            safeFont(label, palette.COLOR_BTN_TEXT, Theme.FontSize, "[fsBold]")
        end
        pcall(function() button.repaint() end)
    end
    local function click()
        if not enabled then return end
        if opts.ModalResult and opts.Form then
            safeSet(opts.Form, "ModalResult", opts.ModalResult)
        end
        if type(opts.OnClick) == "function" then opts.OnClick() end
    end
    button.OnClick = click
    label.OnClick = click
    safeSet(button, "OnMouseEnter", function() paint(true) end)
    safeSet(button, "OnMouseLeave", function() paint(false) end)
    safeSet(label, "OnMouseEnter", function() paint(true) end)
    safeSet(label, "OnMouseLeave", function() paint(false) end)

    local function setEnabled(value)
        enabled = value ~= false
        safeSet(button, "Enabled", enabled)
        paint(false)
    end
    return button, setEnabled
end

-- Dialogs ---------------------------------------------------------------------

--
--- A modal question with as many answers as it needs.
---
--- messageDialog tops out at the button set the LCL offers and returns a
--- modal result that has to be mapped back, and the constants for the third
--- button are not guaranteed to be present. Building the dialog here instead
--- means "Save / Discard / Cancel" and "Replace / Skip / Keep both / Cancel"
--- are the same mechanism, both themed, and neither depends on a constant
--- this Cheat Engine build may not define.
---
--- @param options table # Caption, Title, Message, Choices (array of
---        {Key, Caption, Hint}), CheckBox (optional text), Width, Height.
--- @return string|nil, boolean # The chosen Key (nil if dismissed), and
---         whether the checkbox was ticked.
--
function Theme:AskChoice(options)
    options = options or {}
    local choices = options.Choices or {}
    if #choices == 0 then return nil, false end

    -- Wide enough for the buttons it is about to build. Getting this wrong
    -- does not wrap or scroll, it pushes the first choices off the left edge
    -- where they cannot be clicked at all.
    local needed = 32
    for _, choice in ipairs(choices) do needed = needed + (choice.Width or 104) + 12 end
    local form, palette = self:CreateWindow(options.Caption or "Manifold",
        math.max(options.Width or 520, needed),
        options.Height or (options.CheckBox and 220 or 190))
    pcall(function()
        form.BorderStyle = "bsDialog"
        form.Position = "poScreenCenter"
        local constraints = form.Constraints
        constraints.MinWidth = 0
        constraints.MinHeight = 0
    end)

    local chosen = nil
    local ticked = false

    local bar = self:CreateButtonBar(form, 46)
    local checkbox
    if options.CheckBox then
        local strip = self:CreatePanel(form, {
            Align = "alBottom", Height = 26, Color = palette.COLOR_BG,
            Spacing = { Left = 16, Right = 16 }
        })
        checkbox = createCheckBox(strip)
        safeSet(checkbox, "Parent", strip)
        safeSet(checkbox, "Align", "alClient")
        safeSet(checkbox, "Caption", options.CheckBox)
        self:StyleCheckBox(checkbox)
    end

    local content = self:CreatePanel(form, {
        Align = "alClient", Color = palette.COLOR_BG,
        Spacing = { Left = 16, Right = 16, Top = 14 }
    })
    -- alTop stacks towards the top as controls are created, so the LAST one
    -- built ends up highest. The message is created first so the title sits
    -- above it.
    if options.Message then
        local message = createLabel(content)
        safeSet(message, "Parent", content)
        safeSet(message, "Align", "alTop")
        safeSet(message, "Transparent", true)
        safeSet(message, "WordWrap", true)
        message.Caption = options.Message
        safeFont(message, palette.COLOR_MUTED)
    end

    local title = createLabel(content)
    safeSet(title, "Parent", content)
    safeSet(title, "Align", "alTop")
    safeSet(title, "Transparent", true)
    safeSet(title, "WordWrap", true)
    title.Caption = options.Title or ""
    safeFont(title, palette.COLOR_TEXT, Theme.FontSize, "[fsBold]")
    setSpacing(title, { Bottom = 8 })

    -- alRight stacks towards the right edge as they are created, so building
    -- them in the given order leaves the first choice leftmost.
    for _, choice in ipairs(choices) do
        self:CreateButton(bar, {
            Caption = choice.Caption,
            Align = "alRight",
            Width = choice.Width or 104,
            Hint = choice.Hint,
            OnClick = function()
                chosen = choice.Key
                if checkbox then
                    local ok, value = pcall(function() return checkbox.Checked end)
                    ticked = ok and value == true
                end
                safeSet(form, "ModalResult", rawget(_G, "mrOk") or 1)
                pcall(function() form.close() end)
            end
        })
    end

    local shown = pcall(function() form.showModal() end)
    if not shown then
        -- No modal loop available: treat it as a dismissal rather than
        -- silently picking an answer for the user.
        pcall(function() form.destroy() end)
        return nil, false
    end
    pcall(function() form.destroy() end)
    return chosen, ticked
end

--
--- A single line of input, themed to match. Falls back to Cheat Engine's own
--- inputQuery when a modal cannot be built.
--- @return string|nil # The text, or nil when cancelled.
--
function Theme:AskText(caption, prompt, default)
    local form, palette = self:CreateWindow(caption or "Manifold", 460, 190)
    pcall(function()
        form.BorderStyle = "bsDialog"
        local constraints = form.Constraints
        constraints.MinWidth = 0
        constraints.MinHeight = 0
    end)

    local accepted = false
    local bar = self:CreateButtonBar(form, 46)
    local content = self:CreatePanel(form, {
        Align = "alClient", Color = palette.COLOR_BG,
        Spacing = { Left = 16, Right = 16, Top = 16 }
    })
    -- Same stacking rule: the field is created first so the prompt ends up
    -- above it rather than under it.
    local edit = createEdit(content)
    safeSet(edit, "Parent", content)
    safeSet(edit, "Align", "alTop")
    safeSet(edit, "Height", 24)
    pcall(function() edit.Text = default or "" end)
    self:StyleEdit(edit)

    local label = createLabel(content)
    safeSet(label, "Parent", content)
    safeSet(label, "Align", "alTop")
    safeSet(label, "Transparent", true)
    label.Caption = prompt or ""
    safeFont(label, palette.COLOR_MUTED)
    setSpacing(label, { Bottom = 8 })

    self:CreateButton(bar, {
        Caption = "OK", Align = "alRight", Width = 96,
        OnClick = function()
            accepted = true
            safeSet(form, "ModalResult", rawget(_G, "mrOk") or 1)
            pcall(function() form.close() end)
        end
    })
    self:CreateButton(bar, {
        Caption = "Cancel", Align = "alRight", Width = 96,
        OnClick = function()
            safeSet(form, "ModalResult", rawget(_G, "mrCancel") or 2)
            pcall(function() form.close() end)
        end
    })

    pcall(function() edit.setFocus() end)
    local shown = pcall(function() form.showModal() end)
    if not shown then
        pcall(function() form.destroy() end)
        if type(inputQuery) == "function" then
            return inputQuery(caption, prompt, default)
        end
        return nil
    end
    local value = nil
    pcall(function() value = edit.Text end)
    pcall(function() form.destroy() end)
    if not accepted then return nil end
    return value
end

return Theme
