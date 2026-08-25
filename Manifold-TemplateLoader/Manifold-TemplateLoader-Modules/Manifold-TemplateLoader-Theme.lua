--[[
    Theming and layout for the Template Loader's own windows.

    Self-contained on purpose. The loader must not load Manifold.Forms itself.
    That module defines the global "Forms" class and belongs to the Cheat
    Table's lifecycle. A second copy loaded from autorun is exactly the
    collision Manifold.Bootstrap exists to detect. Instead this module speaks
    the same visual language (cards with a border, a header strip and a
    content area, panel buttons with hover, a status line) and adopts the
    Table's palette read-only when one is live.

    Palette source, in order:
      1. forms.ActiveDesignTheme of a live Manifold.Forms instance,
      2. the bundled Manifold "Bearded-Arc" theme.

    Layout rule for every window here: content is Align-driven, never
    absolute. A button bar sits at the bottom, an optional status line below
    it, and the content fills the rest, so all windows resize properly.

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
        CE = services and services.CE,
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

--
--- The active palette. A live Manifold.Forms instance with an applied theme
--- wins, so loader windows follow the Cheat Table's theme. It is re-read per
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
        constraints.MinWidth = 420
        constraints.MinHeight = 260
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
--- Status line at the very bottom. Returns the label so callers can update
--- its Caption.
--
function Theme:CreateStatusBar(parent, text)
    local palette = self:GetPalette()
    local bar = self:CreatePanel(parent, {
        Align = "alBottom",
        Height = 24,
        Color = palette.COLOR_PANEL,
        Spacing = { Left = 8, Right = 8, Bottom = 4 }
    })
    local label = createLabel(bar)
    safeSet(label, "Align", "alClient")
    safeSet(label, "Layout", "tlCenter")
    safeSet(label, "Transparent", true)
    label.Caption = text or ""
    safeFont(label, palette.COLOR_MUTED)
    setSpacing(label, { Left = 6 })
    return label, bar
end

-- Controls --------------------------------------------------------------------

function Theme:StyleLabel(label, role)
    local palette = self:GetPalette()
    local color = palette.COLOR_LABEL
    if role == "muted" then color = palette.COLOR_MUTED end
    if role == "text" then color = palette.COLOR_TEXT end
    safeSet(label, "Transparent", true)
    safeFont(label, color, Theme.FontSize, role == "header" and "[fsBold]" or nil)
end

function Theme:StyleEdit(edit)
    local palette = self:GetPalette()
    safeSet(edit, "ParentColor", false)
    safeSet(edit, "Color", palette.COLOR_INPUT)
    safeSet(edit, "BorderStyle", "bsNone")
    safeFont(edit, palette.COLOR_INPUT_TEXT)
end

function Theme:StyleCombo(combo)
    local palette = self:GetPalette()
    safeSet(combo, "ParentColor", false)
    safeSet(combo, "Color", palette.COLOR_INPUT)
    safeFont(combo, palette.COLOR_INPUT_TEXT)
end

function Theme:StyleCheckBox(checkbox)
    local palette = self:GetPalette()
    safeFont(checkbox, palette.COLOR_TEXT)
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
--
function Theme:StyleGutter(syn)
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
    -- The bookmark strip is a wide empty column in a read-only view.
    local marks = part("SynGutterMarks1")
    if marks then applied.Marks = safeSet(marks, "Visible", false) end
    -- The change bar and the separator line both paint in their own colors
    -- and only add noise to a preview.
    local changes = part("SynGutterChanges1")
    if changes then applied.Changes = safeSet(changes, "Visible", false) end
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
--- Read-only memo filling its parent, themed and scrollable. Every memo in
--- the loader goes through here so none of them can end up on the default
--- white background.
--
function Theme:CreateMemo(parent, options)
    local memo = createMemo(parent)
    memo.ReadOnly = true
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
    if not self.CE then return nil end
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
    for _, form in ipairs(self.CE:EnumerateAutoAssemblerForms()) do
        pcall(function() probe(form.Assemblescreen) end)
        if background then return background, foreground end
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
--- Read-only code view with Auto Assembler (mode 1) or Lua (mode 0)
--- highlighting, falling back to a themed memo. Returns the control plus
--- getText/setText so callers need not know which one they got.
--
function Theme:CreateCodeView(parent, mode)
    local palette = self:GetPalette()
    local createSyn = rawget(_G, "createSynEdit")
    if type(createSyn) == "function" then
        local ok, syn = pcall(createSyn, parent, mode)
        if ok and syn then
            safeSet(syn, "ReadOnly", true)
            pcall(function()
                syn.Font.Name = Theme.FontName
                syn.Font.Size = Theme.FontSize
            end)
            -- TSynEdit.Color defaults to clWhite. Highlighter attributes
            -- paint their own background only up to the right edge column,
            -- so leaving Color unset shows a bright block beyond it. The
            -- reason Cheat Engine sets RightEdge = -1 on its own editors.
            -- Set both.
            local background, foreground = self:GetEditorColors()
            safeSet(syn, "Color", background or palette.COLOR_INPUT)
            if type(foreground) == "number" then
                pcall(function() syn.Font.Color = foreground end)
            end
            safeSet(syn, "RightEdge", -1)
            self:StyleGutter(syn)
            return syn,
                function() return syn.Lines.Text end,
                function(text) syn.Lines.Text = text end
        end
    end
    -- Fallback path. A memo showing the same code, so it gets the same
    -- colors the SynEdit would have received.
    local background, foreground = self:GetEditorColors()
    local memo = createMemo(parent)
    memo.ReadOnly = true
    memo.ScrollBars = "ssBoth"
    memo.WordWrap = false
    self:StyleMemo(memo, { Background = background, Foreground = foreground })
    return memo,
        function() return memo.Lines.Text end,
        function(text) memo.Lines.Text = text end
end

--
--- Panel button with a centered label and hover feedback. opts:
--- Caption, Width, Height, Align (or Left/Top), Anchors, OnClick,
--- ModalResult together with Form to close a modal window.
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
    safeSet(button, "Cursor", -21) -- crHandPoint
    local label = createLabel(button)
    safeSet(label, "Align", "alClient")
    safeSet(label, "Alignment", "taCenter")
    safeSet(label, "Layout", "tlCenter")
    safeSet(label, "Transparent", true)
    label.Caption = opts.Caption or "Button"
    safeFont(label, palette.COLOR_BTN_TEXT, Theme.FontSize, "[fsBold]")
    local function click()
        if opts.ModalResult and opts.Form then
            safeSet(opts.Form, "ModalResult", opts.ModalResult)
        end
        if type(opts.OnClick) == "function" then opts.OnClick() end
    end
    local function hover(on)
        safeSet(button, "Color", on and palette.COLOR_BTN_HOVER or palette.COLOR_BTN)
        safeFont(label, on and palette.COLOR_BG or palette.COLOR_BTN_TEXT, Theme.FontSize, "[fsBold]")
        pcall(function() button.repaint() end)
    end
    button.OnClick = click
    label.OnClick = click
    safeSet(button, "OnMouseEnter", function() hover(true) end)
    safeSet(button, "OnMouseLeave", function() hover(false) end)
    safeSet(label, "OnMouseEnter", function() hover(true) end)
    safeSet(label, "OnMouseLeave", function() hover(false) end)
    return button
end

return Theme