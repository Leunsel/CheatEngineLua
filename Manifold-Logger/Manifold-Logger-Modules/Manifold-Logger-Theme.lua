--[[
    Theming and layout for the Logger console.

    Self-contained. Loading Manifold.Forms here would define the global Forms
    class a second time from autorun, the collision Manifold.Bootstrap exists
    to detect. This copies its visual language and its palette instead.

    Palette source, in order: forms.ActiveDesignTheme of a live
    Manifold.Forms instance, then the bundled Bearded-Arc theme.

    The palette is live. The Logger window stays open while a Cheat Table is
    worked on, which is when its theme gets changed. Every control this module
    colours is registered with the closure that colours it, and Restyle re-runs
    them. A Create function must never capture the palette in its closures.

    A change is detected by identity. Forms:ApplyTheme assigns a fresh table
    from ResolveTheme every run, so comparing the reference costs nothing on
    the console's 120 ms tick.

    Cheat Engine specifics, verified against CE 7.5 and Lazarus:
      * Native TButton ignores Color on Win32. Buttons are panels with a
        centred label.
      * TPicture.LoadFromFile sniffs the format by extension, unlike
        TGraphic.LoadFromFile, so an image control takes a .png path. The
        image list cannot. See Manifold-Logger-Icons.
      * TMemo and TEdit inherit clWindow and are painted through
        WM_CTLCOLOR*, so ParentColor must be off and Color set explicitly.
      * Colours are BGR integers. The JSON themes store #RRGGBB and
        Manifold.Forms converts on load, so the constants carry both.
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

--- Per-level hues, sampled from the icon artwork so a row and its glyph are
--- the same colour. Cheat Engine BGR.
Theme.LevelDefault = {
    TRACE    = 0xE1BA8D, -- #8dbae1
    DEBUG    = 0x0993FF, -- #ff9309
    INFO     = 0xDBDE08, -- #08dedb
    SUCCESS  = 0x0ACD52, -- #52cd0a
    WARNING  = 0x0CD7EE, -- #eed70c
    ERROR    = 0x310BD7, -- #d70b31
    CRITICAL = 0xFF30FF  -- #ff30ff
}

function Theme:New(services)
    return setmetatable({
        Log = services and services.Log,
        Icons = services and services.Icons,
        Registry = {},        -- one re-apply closure per control coloured
        -- false, not nil. nil is a legitimate source, meaning no Cheat Table
        -- is loaded, so the first GetPalette has to miss the cache.
        CachedSource = false,
        Cached = nil
    }, Theme)
end

--------------------------------------------------------
--                  The live palette                  --
--------------------------------------------------------

--
--- ∑ The Cheat Table's design theme table, or nil when no table is loaded.
---
---   The table itself is the change signal. Forms:ApplyTheme sets
---   ActiveDesignTheme to a fresh table from ResolveTheme on every
---   application, so a caller spots a theme change by comparing the reference
---   it saw last. No copy, no fingerprint.
--- @return table|nil
--
function Theme:Source()
    local forms = rawget(_G, "forms")
    if type(forms) ~= "table" then return nil end
    local ok, design = pcall(self.ProbeSource, forms)
    if not ok or type(design) ~= "table" or design.COLOR_BG == nil then return nil end
    return design
end

--- Hoisted so Source does not build a closure per call. Source runs on the
--- console's refresh tick.
function Theme.ProbeSource(forms)
    return forms.ActiveDesignTheme
end

--
--- ∑ Registers a closure that colours one control, runs it once, and keeps it
---   so Restyle can run it again. A closure that fails on its first run is not
---   kept. It never had a control to colour.
--- @param apply function
--- @return function|nil # The closure, or nil when it did not survive its
---         first run.
--
function Theme:Track(apply)
    if type(apply) ~= "function" then return nil end
    if not pcall(apply) then return nil end
    self.Registry[#self.Registry + 1] = apply
    return apply
end

--
--- ∑ Re-colours every tracked control against the palette as it is now.
---
---   A closure that raises is dropped rather than retried for the rest of the
---   session. This does not prune freed controls. The closures built here are
---   made of safeSet and safeFont, which pcall internally and return false, so
---   a freed control never raises. Forget covers that, and the console calls
---   it when it releases a window. The guard is for closures a caller
---   registered.
--- @return number # How many controls were re-coloured.
--
function Theme:Restyle()
    local registry = self.Registry
    local kept = {}
    for index = 1, #registry do
        if pcall(registry[index]) then kept[#kept + 1] = registry[index] end
    end
    self.Registry = kept
    return #kept
end

--
--- ∑ Forgets every tracked control. Called when a window is released, so no
---   closure survives pointing at a control that has been freed.
--- @return nil
--
function Theme:Forget()
    self.Registry = {}
end

--------------------------------------------------------
--                     Primitives                     --
--------------------------------------------------------

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

--------------------------------------------------------
--                   Colour algebra                   --
--------------------------------------------------------

--
--- ∑ Splits a Cheat Engine colour into its three channels. The order is BGR,
---   not RGB. The low byte is blue.
--- @param color number
--- @return number, number, number
--
function Theme.Split(color)
    color = math.floor(tonumber(color) or 0) % 0x1000000
    return color % 256, math.floor(color / 256) % 256, math.floor(color / 65536) % 256
end

function Theme.Join(blue, green, red)
    local function clamp(value)
        value = math.floor(value + 0.5)
        if value < 0 then return 0 end
        if value > 255 then return 255 end
        return value
    end
    return clamp(blue) + clamp(green) * 256 + clamp(red) * 65536
end

--
--- ∑ Linear blend. An amount of 0 returns from, 1 returns to.
--- @param from number
--- @param to number
--- @param amount number
--- @return number
--
function Theme.Mix(from, to, amount)
    local fb, fg, fr = Theme.Split(from)
    local tb, tg, tr = Theme.Split(to)
    return Theme.Join(fb + (tb - fb) * amount,
                      fg + (tg - fg) * amount,
                      fr + (tr - fr) * amount)
end

--
--- ∑ Perceived brightness, 0..255. The usual luma weights. The result decides
---   whether a palette is dark or light, and so which way a stripe or a hover
---   has to move to stay visible.
--- @param color number
--- @return number
--
function Theme.Luma(color)
    local blue, green, red = Theme.Split(color)
    return 0.299 * red + 0.587 * green + 0.114 * blue
end

function Theme.IsDark(color)
    return Theme.Luma(color) < 128
end

--
--- ∑ Moves a colour towards white on a dark background and towards black on a
---   light one. One call lightens or darkens correctly under any theme, which
---   a fixed lighten by ten percent cannot.
--- @param color number
--- @param amount number
--- @param reference number|nil # What counts as the background. Defaults to
---        the colour itself.
--- @return number
--
function Theme.Shade(color, amount, reference)
    local dark = Theme.IsDark(reference or color)
    return Theme.Mix(color, dark and 0xFFFFFF or 0x000000, amount)
end

--
--- ∑ Lightens or darkens a colour until it stands clear of the background. A
---   level hue picked against the bundled dark theme can vanish on a user's
---   light one. This keeps every level readable without a palette per theme.
--- @param color number
--- @param background number
--- @param minimum number|nil # Required luma distance, default 70.
--- @return number
--
function Theme.Contrast(color, background, minimum)
    minimum = minimum or 70
    local target = Theme.IsDark(background) and 0xFFFFFF or 0x000000
    local result = color
    for _ = 1, 8 do
        if math.abs(Theme.Luma(result) - Theme.Luma(background)) >= minimum then break end
        result = Theme.Mix(result, target, 0.18)
    end
    return result
end

--------------------------------------------------------
--                      Palette                       --
--------------------------------------------------------

--
--- ∑ The active palette. A live Manifold.Forms instance with an applied theme
---   wins, so the console follows the Cheat Table's theme.
---
---   Cached against the source table's identity. The canvas asks on every
---   frame and every hover repaint asks again, so building a merged copy per
---   call would be a table allocation per paint.
--- @return table
--
function Theme:GetPalette()
    local source = self:Source()
    if source == self.CachedSource and self.Cached then return self.Cached end
    local palette
    if source then
        palette = {}
        -- Merged, not used directly. ResolveTheme only fills defaults on the
        -- branch that reads tokenColors. Handed a table that already looks
        -- like a design theme it copies it verbatim, missing keys and all.
        for key, value in pairs(Theme.Default) do
            palette[key] = source[key] or value
        end
        -- COLOR_MUTED is the framework's address-list group-header colour. It
        -- was picked to read against Cheat Engine's list, and this console
        -- puts it on COLOR_PANEL, so correct it like the level hues.
        palette.COLOR_MUTED = Theme.Contrast(palette.COLOR_MUTED, palette.COLOR_PANEL)
    else
        -- Theme.Default is shared and handed back by reference. That is why
        -- the correction above sits inside the other branch and not after the
        -- if and else, where it would edit the bundled palette for good.
        palette = Theme.Default
    end
    self.CachedSource, self.Cached = source, palette
    return palette
end

--
--- ∑ The colours the canvas needs and the palette does not name. A zebra
---   stripe, a selection bar, a hairline between columns. Derived, so a light
---   theme gets a light stripe and a dark one a dark stripe.
--- @param palette table|nil
--- @return table
--
function Theme:Surface(palette)
    palette = palette or self:GetPalette()
    local base = palette.COLOR_INPUT
    return {
        Background = base,
        Stripe     = Theme.Shade(base, 0.045),
        Hover      = Theme.Shade(base, 0.10),
        Selection  = Theme.Mix(base, palette.COLOR_ACCENT, 0.28),
        SelectionText = palette.COLOR_TEXT,
        Gutter     = Theme.Shade(base, 0.03),
        Rule       = Theme.Mix(base, palette.COLOR_BORDER, 0.22),
        Text       = palette.COLOR_TEXT,
        Muted      = palette.COLOR_MUTED,
        Accent     = palette.COLOR_ACCENT,
        Match      = Theme.Mix(base, palette.COLOR_ACCENT, 0.55),
        Scroll     = Theme.Shade(base, 0.08),
        Thumb      = Theme.Mix(base, palette.COLOR_BORDER, 0.45),
        ThumbHover = palette.COLOR_ACCENT
    }
end

--
--- ∑ Per-level text colours, contrast-corrected against the background in
---   use.
--- @param palette table|nil
--- @return table # level name to colour
--
function Theme:LevelColors(palette)
    palette = palette or self:GetPalette()
    local background = palette.COLOR_INPUT
    local colors = {}
    for level, color in pairs(Theme.LevelDefault) do
        colors[level] = Theme.Contrast(color, background)
    end
    return colors
end

--------------------------------------------------------
--                  Windows and layout                --
--------------------------------------------------------

--
--- ∑ A resizeable themed window. ESC closes it. The buttons are panels, so
---   there is no native Cancel button to do that.
--- @param caption string
--- @param width number|nil
--- @param height number|nil
--- @return userdata, table
--
function Theme:CreateWindow(caption, width, height)
    -- false means do not show it yet. Console:Open makes it visible.
    local form = createForm(false)
    form.Caption = caption
    form.Position = "poScreenCenter"
    form.BorderStyle = "bsSizeable"
    form.Width = width or 900
    form.Height = height or 600
    self:Track(function()
        local active = self:GetPalette()
        safeSet(form, "Color", active.COLOR_BG)
        safeFont(form, active.COLOR_TEXT)
    end)
    pcall(function()
        local constraints = form.Constraints
        constraints.MinWidth = 520
        constraints.MinHeight = 320
    end)
    return form, self:GetPalette()
end

--
--- ∑ A themed panel. ColorKey names the palette entry to follow, so the panel
---   re-colours with the theme. Color is the escape hatch for a colour that is
---   not from the palette, and is applied once.
--- @param parent userdata
--- @param options table|nil # { ColorKey, Color, BevelOuter, BevelWidth,
---        BevelColorKey, Align, Height, Width, Anchors, Spacing }
--- @return userdata
--
function Theme:CreatePanel(parent, options)
    options = options or {}
    local panel = createPanel(parent)
    safeSet(panel, "Parent", parent)
    safeSet(panel, "Caption", "")
    safeSet(panel, "ParentColor", false)
    if options.Color then
        safeSet(panel, "Color", options.Color)
    else
        local key = options.ColorKey or "COLOR_PANEL"
        self:Track(function()
            safeSet(panel, "Color", self:GetPalette()[key])
        end)
    end
    safeSet(panel, "BevelOuter", options.BevelOuter or "bvNone")
    if options.BevelWidth then safeSet(panel, "BevelWidth", options.BevelWidth) end
    if options.BevelColorKey then
        local key = options.BevelColorKey
        self:Track(function()
            safeSet(panel, "BevelColor", self:GetPalette()[key])
        end)
    elseif options.BevelColor then
        safeSet(panel, "BevelColor", options.BevelColor)
    end
    if options.Align then safeSet(panel, "Align", options.Align) end
    if options.Height then safeSet(panel, "Height", options.Height) end
    if options.Width then safeSet(panel, "Width", options.Width) end
    if options.Anchors then safeSet(panel, "Anchors", options.Anchors) end
    setSpacing(panel, options.Spacing)
    return panel
end

--
--- ∑ A bordered card with an optional header strip, in the Manifold.Forms
---   idiom. Border panel, body panel, then header and content. Returns the
---   content panel, where the caller puts its control aligned alClient, then
---   the card and the header label.
--- @param parent userdata
--- @param options table|nil
--- @return userdata, userdata, userdata|nil
--
function Theme:CreateCard(parent, options)
    options = options or {}
    local card = self:CreatePanel(parent, {
        Align = options.Align or "alClient",
        Height = options.Height,
        Width = options.Width,
        ColorKey = "COLOR_BORDER",
        BevelOuter = "bvNone",
        Spacing = options.Spacing or { Around = 8 }
    })
    local body = self:CreatePanel(card, {
        Align = "alClient",
        ColorKey = "COLOR_PANEL",
        Spacing = { Around = 1 }
    })
    local headerLabel
    if options.Title then
        local header = self:CreatePanel(body, {
            Align = "alTop", Height = 24, ColorKey = "COLOR_PANEL"
        })
        headerLabel = createLabel(header)
        safeSet(headerLabel, "Parent", header)
        safeSet(headerLabel, "Align", "alClient")
        safeSet(headerLabel, "Layout", "tlCenter")
        safeSet(headerLabel, "Transparent", true)
        headerLabel.Caption = options.Title
        self:Track(function()
            safeFont(headerLabel, self:GetPalette().COLOR_LABEL, Theme.FontSize, "[fsBold]")
        end)
        setSpacing(headerLabel, { Left = 8 })
    end
    local content = self:CreatePanel(body, {
        Align = "alClient",
        Color = options.ContentColor,
        ColorKey = options.ContentColorKey or "COLOR_INPUT",
        Spacing = options.ContentSpacing or { Around = options.ContentPad or 6 }
    })
    return content, card, headerLabel
end

function Theme:CreateToolBar(parent, height)
    return self:CreatePanel(parent, {
        Align = "alTop", Height = height or 40,
        Spacing = { Left = 8, Right = 8, Top = 8 }
    })
end

function Theme:CreateButtonBar(parent, height)
    return self:CreatePanel(parent, {
        Align = "alBottom", Height = height or 44,
        Spacing = { Left = 8, Right = 8, Bottom = 8 }
    })
end

--
--- ∑ Status line at the very bottom. Two labels rather than one. What is
---   happening on the left, quieter detail on the right, so the line can carry
---   several facts at once.
--- @param parent userdata
--- @param text string|nil # Initial text for the left label.
--- @return userdata, userdata, userdata # primary label, bar, detail label
--
function Theme:CreateStatusBar(parent, text)
    local bar = self:CreatePanel(parent, {
        Align = "alBottom", Height = 24, ColorKey = "COLOR_PANEL",
        Spacing = { Left = 8, Right = 8, Bottom = 4 }
    })
    -- alRight before alClient. The detail claims its width, the primary label
    -- takes what is left.
    local detail = createLabel(bar)
    safeSet(detail, "Parent", bar)
    safeSet(detail, "Align", "alRight")
    safeSet(detail, "Layout", "tlCenter")
    safeSet(detail, "Alignment", "taRightJustify")
    safeSet(detail, "Transparent", true)
    detail.Caption = ""
    self:Track(function() safeFont(detail, self:GetPalette().COLOR_MUTED) end)
    setSpacing(detail, { Right = 6 })

    local label = createLabel(bar)
    safeSet(label, "Parent", bar)
    safeSet(label, "Align", "alClient")
    safeSet(label, "Layout", "tlCenter")
    safeSet(label, "Transparent", true)
    label.Caption = text or ""
    self:Track(function() safeFont(label, self:GetPalette().COLOR_MUTED) end)
    setSpacing(label, { Left = 6 })
    return label, bar, detail
end

--
--- ∑ A thin vertical rule for grouping toolbar buttons. Aligned like a button,
---   so it takes its place in the same left to right stack.
---
---   One panel, one pixel wide. An alClient child inside a wider holder does
---   not work. alClient overrides Width, so the rule fills the holder and the
---   separator comes out a solid bar. The margins do the spacing.
--- @param parent userdata
--- @return userdata
--
function Theme:CreateToolSeparator(parent)
    return self:CreatePanel(parent, {
        Align = "alLeft", Width = 1, ColorKey = "COLOR_BORDER",
        Spacing = { Left = 8, Right = 8, Top = 8, Bottom = 8 }
    })
end

--
--- ∑ Draggable divider between two panes. Placed after the pane it resizes and
---   given the same Align. That is how the LCL pairs the two.
--- @param parent userdata
--- @param options table|nil # { Align, Height, MinSize }
--- @return userdata
--
function Theme:CreateSplitter(parent, options)
    options = options or {}
    local create = rawget(_G, "createSplitter")
    local splitter
    if type(create) == "function" then
        local ok, made = pcall(create, parent)
        if ok and made then splitter = made end
    end
    if not splitter then
        -- No createSplitter in this Cheat Engine. A thin panel keeps the
        -- visual seam, it just cannot be dragged.
        return self:CreatePanel(parent, {
            Align = options.Align or "alBottom", Height = 4, ColorKey = "COLOR_BG"
        })
    end
    safeSet(splitter, "Parent", parent)
    safeSet(splitter, "Align", options.Align or "alBottom")
    safeSet(splitter, "Height", options.Height or 5)
    safeSet(splitter, "MinSize", options.MinSize or 80)
    safeSet(splitter, "ResizeStyle", "rsUpdate")
    safeSet(splitter, "Beveled", false)
    safeSet(splitter, "ParentColor", false)
    self:Track(function() safeSet(splitter, "Color", self:GetPalette().COLOR_BG) end)
    return splitter
end

--------------------------------------------------------
--                      Controls                      --
--------------------------------------------------------

function Theme:StyleLabel(label, role)
    safeSet(label, "Transparent", true)
    self:Track(function()
        local palette = self:GetPalette()
        local color = palette.COLOR_LABEL
        if role == "muted" then color = palette.COLOR_MUTED end
        if role == "text" then color = palette.COLOR_TEXT end
        safeFont(label, color, Theme.FontSize, role == "header" and "[fsBold]" or nil)
    end)
end

function Theme:CreateLabel(parent, caption, role)
    local label = createLabel(parent)
    safeSet(label, "Parent", parent)
    label.Caption = caption or ""
    self:StyleLabel(label, role)
    return label
end

function Theme:StyleEdit(edit)
    safeSet(edit, "ParentColor", false)
    safeSet(edit, "BorderStyle", "bsNone")
    self:Track(function()
        local palette = self:GetPalette()
        safeSet(edit, "Color", palette.COLOR_INPUT)
        safeFont(edit, palette.COLOR_INPUT_TEXT)
    end)
end

function Theme:CreateEdit(parent, options)
    options = options or {}
    local edit = createEdit(parent)
    safeSet(edit, "Parent", parent)
    if options.Align then safeSet(edit, "Align", options.Align) end
    if options.Anchors then safeSet(edit, "Anchors", options.Anchors) end
    if options.Width then safeSet(edit, "Width", options.Width) end
    if options.Height then safeSet(edit, "Height", options.Height) end
    if options.Left then safeSet(edit, "Left", options.Left) end
    if options.Top then safeSet(edit, "Top", options.Top) end
    if options.Hint then
        safeSet(edit, "Hint", options.Hint)
        safeSet(edit, "ShowHint", true)
    end
    -- TextHint is the grey placeholder. It is a published property on
    -- TCustomEdit, so it goes through CE's RTTI fallback and may be absent.
    if options.Placeholder then safeSet(edit, "TextHint", options.Placeholder) end
    edit.Text = options.Text or ""
    self:StyleEdit(edit)
    if options.OnChange then safeSet(edit, "OnChange", options.OnChange) end
    setSpacing(edit, options.Spacing)
    return edit
end

function Theme:StyleCombo(combo)
    safeSet(combo, "ParentColor", false)
    self:Track(function()
        local palette = self:GetPalette()
        safeSet(combo, "Color", palette.COLOR_INPUT)
        safeFont(combo, palette.COLOR_INPUT_TEXT)
    end)
end

--
--- ∑ A read-only dropdown filled from Items.
--- @param parent userdata
--- @param options table # { Items, ItemIndex, Width, OnChange, ... }
--- @return userdata
--
function Theme:CreateCombo(parent, options)
    options = options or {}
    local combo = createComboBox(parent)
    safeSet(combo, "Parent", parent)
    safeSet(combo, "Style", "csDropDownList")
    if options.Align then safeSet(combo, "Align", options.Align) end
    if options.Anchors then safeSet(combo, "Anchors", options.Anchors) end
    if options.Width then safeSet(combo, "Width", options.Width) end
    if options.Left then safeSet(combo, "Left", options.Left) end
    if options.Top then safeSet(combo, "Top", options.Top) end
    if options.Hint then
        safeSet(combo, "Hint", options.Hint)
        safeSet(combo, "ShowHint", true)
    end
    for _, item in ipairs(options.Items or {}) do
        pcall(function() combo.Items.add(tostring(item)) end)
    end
    if options.ItemIndex then safeSet(combo, "ItemIndex", options.ItemIndex) end
    self:StyleCombo(combo)
    -- OnChange last. Setting ItemIndex above would otherwise fire it during
    -- construction, before the caller's state exists.
    if options.OnChange then safeSet(combo, "OnChange", options.OnChange) end
    return combo
end

function Theme:StyleMemo(memo, options)
    options = options or {}
    safeSet(memo, "ParentColor", false)
    safeSet(memo, "BorderStyle", "bsNone")
    -- An explicit Background or Foreground is a caller borrowing Cheat
    -- Engine's own editor colours, which are not ours to re-theme.
    if options.Background or options.Foreground then
        safeSet(memo, "Color", options.Background or self:GetPalette().COLOR_INPUT)
        safeFont(memo, options.Foreground or self:GetPalette().COLOR_TEXT)
        return
    end
    self:Track(function()
        local palette = self:GetPalette()
        safeSet(memo, "Color", palette.COLOR_INPUT)
        safeFont(memo, palette.COLOR_TEXT)
    end)
end

function Theme:CreateMemo(parent, options)
    options = options or {}
    local memo = createMemo(parent)
    safeSet(memo, "Parent", parent)
    safeSet(memo, "Align", options.Align or "alClient")
    memo.ReadOnly = options.ReadOnly ~= false
    memo.ScrollBars = options.ScrollBars or "ssBoth"
    memo.WordWrap = options.WordWrap == true
    self:StyleMemo(memo, options)
    return memo
end

--------------------------------------------------------
--                       Buttons                      --
--------------------------------------------------------

--
--- ∑ A 16x16 glyph on a control, loaded straight from the icon folder.
---
---   TPicture.LoadFromFile sniffs the format from the extension, so this works
---   where the image list path cannot take a file name at all. Everything is
---   pcall'd and a failure is silent. A button without its glyph is still a
---   button. An exception during window construction is not.
--- @param parent userdata
--- @param iconName string
--- @param left number
--- @param top number
--- @return userdata|nil
--
function Theme:CreateGlyph(parent, iconName, left, top)
    if not self.Icons or not iconName then return nil end
    local fileName = self.Icons.Files and self.Icons.Files[iconName]
    if not fileName then return nil end
    local create = rawget(_G, "createImage")
    if type(create) ~= "function" then return nil end
    local ok, image = pcall(create, parent)
    if not ok or not image then return nil end
    local path = self.Icons:PathOf(fileName)
    local loaded = pcall(function() image.Picture.loadFromFile(path) end)
    if not loaded then
        pcall(function() image.destroy() end)
        return nil
    end
    safeSet(image, "Parent", parent)
    safeSet(image, "Transparent", true)
    safeSet(image, "Stretch", false)
    safeSet(image, "Center", true)
    safeSet(image, "Width", 16)
    safeSet(image, "Height", 16)
    safeSet(image, "Left", left or 6)
    safeSet(image, "Top", top or 5)
    -- A TImage over the button would swallow the click, so hand it on.
    safeSet(image, "Enabled", false)
    return image
end

--
--- ∑ Panel button with a centred label, optional glyph, hover feedback and an
---   optional pressed state. Follow, Wrap and Pause are modes rather than
---   actions, so they need a look of their own when they are on.
--- @param parent userdata
--- @param opts table # Caption, Icon, Width, Height, Align, Anchors, Hint,
---        OnClick, Toggle (bool), Pressed (bool), ModalResult+Form
--- @return userdata, function, function # button, setEnabled, setPressed
--
function Theme:CreateButton(parent, opts)
    opts = opts or {}
    local button = self:CreatePanel(parent, {
        -- paint() below drives the panel's colour and knows about hover and
        -- pressed as well, so set it once here rather than tracking it twice.
        Color = self:GetPalette().COLOR_BTN,
        BevelOuter = "bvRaised",
        BevelWidth = 1,
        BevelColorKey = "COLOR_BORDER",
        Spacing = opts.Spacing or { Left = 4, Top = 4, Bottom = 4 }
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

    local glyph = opts.Icon and self:CreateGlyph(button, opts.Icon, 6,
        math.floor((button.Height - 16) / 2)) or nil

    local label = createLabel(button)
    safeSet(label, "Parent", button)
    if glyph then
        -- Leave room for the glyph rather than centring across it.
        safeSet(label, "Align", "alClient")
        setSpacing(label, { Left = 26 })
        safeSet(label, "Alignment", "taLeftJustify")
    else
        safeSet(label, "Align", "alClient")
        safeSet(label, "Alignment", "taCenter")
    end
    safeSet(label, "Layout", "tlCenter")
    safeSet(label, "Transparent", true)
    label.Caption = opts.Caption or ""
    if opts.Hint then
        safeSet(label, "Hint", opts.Hint)
        safeSet(label, "ShowHint", true)
    end

    local enabled, pressed = true, opts.Pressed == true
    --- The palette is read here, not captured when the button was made. A
    --- button that cached its colours would keep the theme it was born under
    --- through every hover for the rest of the session.
    local function paint(hovered)
        local palette = self:GetPalette()
        local background, foreground
        if not enabled then
            background, foreground = palette.COLOR_BTN, palette.COLOR_MUTED
        elseif hovered then
            background, foreground = palette.COLOR_BTN_HOVER, palette.COLOR_BG
        elseif pressed then
            -- Halfway to the hover colour. Clearly on, clearly not under the
            -- cursor right now.
            background = Theme.Mix(palette.COLOR_BTN, palette.COLOR_BTN_HOVER, 0.55)
            foreground = palette.COLOR_BG
        else
            background, foreground = palette.COLOR_BTN, palette.COLOR_BTN_TEXT
        end
        safeSet(button, "Color", background)
        safeFont(label, foreground, Theme.FontSize, "[fsBold]")
        pcall(function() button.repaint() end)
    end

    local function click()
        if not enabled then return end
        if opts.Toggle then
            pressed = not pressed
            paint(false)
        end
        if opts.ModalResult and opts.Form then
            safeSet(opts.Form, "ModalResult", opts.ModalResult)
        end
        if type(opts.OnClick) == "function" then opts.OnClick(pressed) end
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
    local function setPressed(value)
        pressed = value == true
        paint(false)
    end
    -- Tracked, so a theme change repaints the button in whatever state it is
    -- currently in rather than resetting it.
    self:Track(function() paint(false) end)
    return button, setEnabled, setPressed
end

--
--- ∑ A square icon-only button for a toolbar. Carries a glyph and holds a
---   pressed state, which is what a follow the tail or wrap toggle needs.
--- @param parent userdata
--- @param opts table
--- @return userdata, function, function
--
function Theme:CreateToolButton(parent, opts)
    opts = opts or {}
    opts.Width = opts.Width or (opts.Caption and 104 or 30)
    opts.Height = opts.Height or 28
    opts.Align = opts.Align or "alLeft"
    return self:CreateButton(parent, opts)
end

--------------------------------------------------------
--                      Menus                         --
--------------------------------------------------------

--
--- ∑ A popup menu with icons.
---
---   The item is created with the MENU as its owner and then added to the
---   parent's item list. Ownership decides who frees it, not who shows it, so
---   destroying the menu takes the whole tree with it.
---
---   Icons resolve through SubMenuImages on the parent, so AttachTo runs on
---   menu.Items before any child sets an ImageIndex. See
---   Manifold-Logger-Icons:AttachTo for why that order matters. The control it
---   attaches to must be a WINDOWED one. A TGraphicControl has no window
---   handle, so WM_CONTEXTMENU goes to its nearest windowed ancestor and a
---   menu hung off the child would never be shown.
--- @param control userdata # The control the menu belongs to.
--- @param options table|nil # { Attach = false } to build the menu without
---        hanging it off the control, for a caller that pops it by hand.
--- @return table|nil # { Menu, Add, Attach, Enable, Check, Entries }
--
function Theme:CreatePopupMenu(control, options)
    options = options or {}
    local createMenu = rawget(_G, "createPopupMenu")
    local createItem = rawget(_G, "createMenuItem")
    if type(createMenu) ~= "function" or type(createItem) ~= "function" then return nil end
    local ok, menu = pcall(createMenu, control)
    if not ok or not menu then return nil end
    if options.Attach ~= false then
        pcall(function() control.PopupMenu = menu end)
    end
    if self.Icons then pcall(function() self.Icons:AttachTo(menu.Items) end) end

    local entries = {}
    local function add(caption, onClick, options)
        options = options or {}
        local parent = options.Parent or menu.Items
        local item
        local built = pcall(function()
            item = createItem(menu)
            item.Caption = caption
            if options.Shortcut then item.Shortcut = options.Shortcut end
            if options.Checked ~= nil then
                item.AutoCheck = false
                item.Checked = options.Checked == true
            end
            if onClick then item.OnClick = function() onClick(item) end end
            parent.add(item)
        end)
        if not built then return nil end
        if self.Icons and options.Icon then
            if options.Parent then pcall(function() self.Icons:AttachTo(options.Parent) end) end
            self.Icons:Apply(item, options.Icon)
        end
        if caption ~= "-" then entries[options.Key or caption] = item end
        return item
    end
    local function enable(key, value)
        local item = entries[key]
        if item then pcall(function() item.Enabled = value == true end) end
    end
    local function check(key, value)
        local item = entries[key]
        if item then pcall(function() item.Checked = value == true end) end
    end
    local function attach(other) pcall(function() other.PopupMenu = menu end) end
    return { Menu = menu, Add = add, Attach = attach, Enable = enable,
             Check = check, Entries = entries }
end

--------------------------------------------------------
--                      Dialogs                       --
--------------------------------------------------------

--
--- ∑ A themed one-line prompt.
---
---   inputQuery would be one call, but it is a native dialog. It ignores the
---   palette entirely, and its return convention differs between Cheat Engine
---   builds. This is the modal pattern the rest of the Manifold windows use.
--- @param caption string
--- @param prompt string
--- @param default string|nil
--- @return string|nil # nil when cancelled.
--
function Theme:AskText(caption, prompt, default)
    local palette = self:GetPalette()
    local form = createForm(false)
    form.Caption = caption or "Manifold"
    form.BorderStyle = "bsDialog"
    form.Position = "poScreenCenter"
    form.Width, form.Height = 440, 150
    safeSet(form, "Color", palette.COLOR_BG)
    safeFont(form, palette.COLOR_TEXT)
    -- A modal prompt lives for one call, so nothing it creates is worth a
    -- later restyle. The loop at the end drops what its controls registered.
    local mark = #self.Registry

    local content = self:CreatePanel(form, {
        Align = "alClient", ColorKey = "COLOR_BG", Spacing = { Around = 12 }
    })
    local label = self:CreateLabel(content, prompt or "", "muted")
    safeSet(label, "Align", "alTop")
    safeSet(label, "Height", 20)
    local edit = self:CreateEdit(content, { Align = "alTop", Text = default or "" })
    setSpacing(edit, { Top = 8 })

    local bar = self:CreateButtonBar(form, 46)
    local result = nil
    self:CreateButton(bar, {
        Caption = "Cancel", Align = "alRight", Width = 96,
        OnClick = function() pcall(function() form.close() end) end
    })
    self:CreateButton(bar, {
        Caption = "OK", Align = "alRight", Width = 96,
        OnClick = function()
            result = edit.Text
            pcall(function() form.close() end)
        end
    })
    -- Enter accepts, Escape cancels. Both are handled here because the buttons
    -- are panels, so the LCL has no Default or Cancel button to act on.
    pcall(function()
        form.KeyPreview = true
        form.OnKeyDown = function(_, key)
            if key == 13 then
                result = edit.Text
                pcall(function() form.close() end)
            elseif key == 27 then
                result = nil
                pcall(function() form.close() end)
            end
            return key
        end
    end)
    pcall(function() form.showModal() end)
    pcall(function() form.destroy() end)
    -- The dialog's controls are gone. Their closures must not outlive them.
    for index = #self.Registry, mark + 1, -1 do self.Registry[index] = nil end
    return result
end

return Theme
