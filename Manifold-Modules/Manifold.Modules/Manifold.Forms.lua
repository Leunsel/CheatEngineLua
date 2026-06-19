local NAME = "Manifold.Forms.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.1"
local DESCRIPTION = "Manifold Framework Forms"

--[[
    v1.0.1 (2026-06-17)
        Resolve registered control roots through the parent chain for reliable live theming.
]]--

Forms = {
    Registry = nil,
    ActiveTheme = nil,
    ActiveDesignTheme = nil
}
Forms.__index = Forms

local MODULE_PREFIX = "[Forms]"

local DEFAULT_THEME = {
    COLOR_BG           = 0x202020,
    COLOR_PANEL        = 0x2A2A2A,
    COLOR_ACCENT       = 0x4A4A4A,
    COLOR_TEXT         = 0xEAEAEA,
    COLOR_LABEL        = 0xC8C8C8,
    COLOR_BTN          = 0x2A2A2A,
    COLOR_BTN_HOVER    = 0x4A4A4A,
    COLOR_BTN_TEXT     = 0xEAEAEA,
    COLOR_TAB_ACTIVE   = 0x4A4A4A,
    COLOR_TAB_INACTIVE = 0x2A2A2A,
    COLOR_INPUT        = 0x1B1B1B,
    COLOR_INPUT_TEXT   = 0xEAEAEA,
    COLOR_BORDER       = 0x454545,
    COLOR_MUTED        = 0x8A8A8A,
    COLOR_SURFACE      = 0x2F2F2F,
    COLOR_SURFACE_ALT  = 0x242424,
    COLOR_SUCCESS      = 0x6FD96F,
}

--
--- ∑ Creates a shallow copy of a table.
--- @param source table # The source table to copy.
--- @returns table # A new table containing the source key/value pairs.
--
local function _copyTable(source)
    local target = {}
    for key, value in pairs(source or {}) do
        target[key] = value
    end
    return target
end

--
--- ∑ Checks whether a value can be called as a function.
--- @param value any # The value to inspect.
--- @returns boolean # True when the value is a function.
--
local function _isCallable(value)
    return type(value) == "function"
end

--
--- ∑ Creates a new Forms module instance.
--- @param config table # Optional instance configuration values.
--- @returns table # A configured Forms instance.
--
function Forms:New(config)
    local instance = setmetatable({}, self)
    instance.Name = NAME or "Unnamed Module"
    instance.Registry = { Controls = {}, Keys = {} }
    for key, value in pairs(config or {}) do
        if self[key] ~= nil then
            instance[key] = value
        elseif logger and logger.WarningF then
            logger:WarningF("Invalid property: '%s'", key)
        end
    end
    return instance
end
registerLuaFunctionHighlight('New')

--
--- ∑ Returns static module metadata.
--- @returns table # Module name, version, author, and description.
--
function Forms:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Logs module metadata through the shared logger.
--
function Forms:PrintModuleInfo()
    local info = self:GetModuleInfo()
    if not info then
        logger:Info(MODULE_PREFIX .. " Failed to retrieve module info.")
        return
    end
    logger:Info("Module Info : "  .. tostring(info.name))
    logger:Info("\tVersion:     " .. tostring(info.version))
    local author = type(info.author) == "table" and table.concat(info.author, ", ") or tostring(info.author)
    local description = type(info.description) == "table" and table.concat(info.description, ", ") or tostring(info.description)
    logger:Info("\tAuthor:      " .. author)
    logger:Info("\tDescription: " .. description .. "\n")
end
registerLuaFunctionHighlight('PrintModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
--- ∑ Ensures that the retained Forms control registry exists.
--- @returns table # The registry table containing Controls and Keys indexes.
--
function Forms:_EnsureRegistry()
    self.Registry = self.Registry or { Controls = {}, Keys = {} }
    self.Registry.Controls = self.Registry.Controls or {}
    self.Registry.Keys = self.Registry.Keys or {}
    return self.Registry
end

--
--- ∑ Sets a control property without raising runtime errors for unsupported properties.
--- @param control table # The control to update.
--- @param propertyName string # The property name to assign.
--- @param value any # The value to write.
--
function Forms:_SafeSet(control, propertyName, value)
    if not control or propertyName == nil then return end
    pcall(function()
        control[propertyName] = value
    end)
end

--
--- ∑ Reads a control property without raising runtime errors for unsupported properties.
--- @param control table # The control to inspect.
--- @param propertyName string # The property name to read.
--- @returns any # The property value, or nil when unavailable.
--
function Forms:_SafeGet(control, propertyName)
    if not control or propertyName == nil then return nil end
    local ok, value = pcall(function()
        return control[propertyName]
    end)
    return ok and value or nil
end

--
--- ∑ Calls a control method when it exists and is callable.
--- @param control table # The control containing the method.
--- @param methodName string # The method name to call.
--
function Forms:_Call(control, methodName)
    if not control or methodName == nil then return end
    local method = self:_SafeGet(control, methodName)
    if _isCallable(method) then
        pcall(function()
            method(control)
        end)
    end
end

--
--- ∑ Repaints a control if it exposes a repaint method.
--- @param control table # The control to repaint.
--
function Forms:Repaint(control)
    if not control then return end
    if self:_SafeGet(control, "repaint") then
        self:_Call(control, "repaint")
    elseif self:_SafeGet(control, "Repaint") then
        self:_Call(control, "Repaint")
    end
end
registerLuaFunctionHighlight('Repaint')

--
--- ∑ Applies the standard Forms font settings to a control.
--- @param control table # The control whose Font object should be updated.
--- @param color integer # Optional font color.
--- @param size integer # Optional font size.
--- @param style string # Optional Cheat Engine font style string.
--
function Forms:ApplyFont(control, color, size, style)
    if not control then return end
    local font = self:_SafeGet(control, "Font")
    if not font then return end
    pcall(function()
        font.Name = "Consolas"
        font.Size = size or font.Size or 10
        if color ~= nil then font.Color = color end
        if style ~= nil then font.Style = style end
    end)
end
registerLuaFunctionHighlight('ApplyFont')

--
--- ∑ Applies BorderSpacing values to a control.
--- @param control table # The control whose BorderSpacing should be updated.
--- @param spacing number|table # Either a single Around value or a table of spacing fields.
--
function Forms:SetBorderSpacing(control, spacing)
    if not control or spacing == nil then return end
    local borderSpacing = self:_SafeGet(control, "BorderSpacing")
    if not borderSpacing then return end
    if type(spacing) == "number" then
        pcall(function() borderSpacing.Around = spacing end)
        return
    end
    if type(spacing) ~= "table" then return end
    for key, value in pairs(spacing) do
        pcall(function()
            borderSpacing[key] = value
        end)
    end
end
registerLuaFunctionHighlight('SetBorderSpacing')

--
--- ∑ Applies a background color and disables inherited parent color.
--- @param control table # The control to color.
--- @param color integer # The BGR color value to apply.
--
function Forms:_SetColor(control, color)
    if not control or color == nil then return end
    self:_SafeSet(control, "ParentColor", false)
    self:_SafeSet(control, "Color", color)
end

--
--- ∑ Applies bevel settings to a control when supported.
--- @param control table # The control to update.
--- @param outer string # Optional BevelOuter value.
--- @param color integer # Optional BevelColor value.
--- @param width integer # Optional BevelWidth value.
--
function Forms:_SetBevel(control, outer, color, width)
    if not control then return end
    if outer ~= nil then self:_SafeSet(control, "BevelOuter", outer) end
    if color ~= nil then self:_SafeSet(control, "BevelColor", color) end
    if width ~= nil then self:_SafeSet(control, "BevelWidth", width) end
end

--
--- ∑ Applies common control options shared by Forms factories.
--- @param control table # The control to configure.
--- @param opts table # Option table containing common properties and layout values.
--
function Forms:_ApplyCommonOptions(control, opts)
    opts = opts or {}
    local directProps = {
        "Name", "Align", "Alignment", "Layout", "BorderStyle", "Width", "Height", "Left", "Top",
        "Caption", "Text", "TextHint", "AutoSize", "Visible", "Transparent",
        "ParentColor", "ScrollBars", "WordWrap", "ReadOnly",
        "ViewStyle", "AutoWidthLastColumn", "RowSelect", "FullRowSelect",
        "HideSelection", "AutoExpand", "Cursor", "Position", "Scaled", "Hint", "ShowHint"
    }
    for _, prop in ipairs(directProps) do
        local key = prop:sub(1, 1):lower() .. prop:sub(2)
        if opts[prop] ~= nil then
            self:_SafeSet(control, prop, opts[prop])
        elseif opts[key] ~= nil then
            self:_SafeSet(control, prop, opts[key])
        end
    end
    if opts.borderSpacing ~= nil then
        self:SetBorderSpacing(control, opts.borderSpacing)
    end
    if opts.constraints and self:_SafeGet(control, "Constraints") then
        local constraints = self:_SafeGet(control, "Constraints")
        for key, value in pairs(opts.constraints) do
            pcall(function() constraints[key] = value end)
        end
    end
end

--
--- ∑ Resolves the root form/control for registry visibility tracking.
--- @param parent table # The parent control of the new control.
--- @param opts table # Option table that may provide root or isRoot.
--- @returns table # The resolved root control.
--
function Forms:_ResolveRoot(parent, opts)
    opts = opts or {}
    if opts.root then return opts.root end
    local root = self:_SafeGet(parent, "_formsRoot")
    if root then return root end
    local current = parent
    local resolved = parent
    local guard = 0
    while current and guard < 64 do
        local inheritedRoot = self:_SafeGet(current, "_formsRoot")
        if inheritedRoot then
            return inheritedRoot
        end
        resolved = current
        local nextParent = self:_SafeGet(current, "Parent")
        if not nextParent or nextParent == current then
            break
        end
        current = nextParent
        guard = guard + 1
    end
    return resolved
end

--
--- ∑ Registers a control for retained theming and role-based updates.
--- @param control table # The control to register.
--- @param role string # The semantic Forms role for theming.
--- @param opts table # Original creation options for the control.
--- @returns table # The registered control.
--
function Forms:RegisterControl(control, role, opts)
    if not control then return control end
    opts = opts or {}
    local registry = self:_EnsureRegistry()
    local key = tostring(control)
    local root = self:_ResolveRoot(opts.parent, opts)
    if opts.root then root = opts.root end
    if opts.isRoot then root = control end
    pcall(function() control._formsRoot = root end)
    pcall(function() control._formsRole = role or opts.role or "panel" end)
    if registry.Keys[key] then
        registry.Keys[key].role = role or opts.role or registry.Keys[key].role
        registry.Keys[key].options = opts
        registry.Keys[key].root = root
        return control
    end
    local entry = {
        control = control,
        role = role or opts.role or "panel",
        options = opts,
        root = root
    }
    registry.Controls[#registry.Controls + 1] = entry
    registry.Keys[key] = entry
    if self.ActiveDesignTheme then
        self:ApplyThemeToControl(entry, self.ActiveDesignTheme, true)
    end
    return control
end
registerLuaFunctionHighlight('RegisterControl')

--
--- ∑ Registers a form as a Forms root control.
--- @param form table # The form to register.
--- @param opts table # Optional form registration options.
--- @returns table # The registered form.
--
function Forms:RegisterForm(form, opts)
    opts = opts or {}
    opts.isRoot = true
    return self:RegisterControl(form, opts.role or "form", opts)
end
registerLuaFunctionHighlight('RegisterForm')

--
--- ∑ Converts a Manifold UI theme into the normalized Forms design palette.
--- @param theme table # A Manifold theme token table or normalized Forms theme.
--- @returns table # A normalized Forms design theme.
--
function Forms:ResolveTheme(theme)
    if type(theme) == "table" and theme.COLOR_BG then
        return _copyTable(theme)
    end
    local design = _copyTable(DEFAULT_THEME)
    if type(theme) ~= "table" then
        return design
    end
    design.COLOR_BG = theme["MainForm.Color"] or design.COLOR_BG
    design.COLOR_PANEL = theme["MainForm.Foundlist3.Color"] or design.COLOR_PANEL
    design.COLOR_ACCENT = theme["AddressList.CheckboxActiveColor"] or design.COLOR_ACCENT
    design.COLOR_TEXT = theme["Memrec.DefaultForeground.Color"] or theme["AddressList.Header.Font.Color"] or design.COLOR_TEXT
    design.COLOR_LABEL = theme["Memrec.DefaultForeground.Color"] or theme["AddressList.Header.Font.Color"] or design.COLOR_LABEL
    design.COLOR_BTN = theme["AddressList.Header.Canvas.Brush.Color"] or design.COLOR_BTN
    design.COLOR_BTN_HOVER = theme["AddressList.CheckboxActiveColor"] or theme["AddressList.Header.Canvas.Pen.Color"] or design.COLOR_BTN_HOVER
    design.COLOR_BTN_TEXT = design.COLOR_LABEL
    design.COLOR_INPUT = theme["AddressList.List.BackgroundColor"] or design.COLOR_INPUT
    design.COLOR_INPUT_TEXT = theme["TreeView.Font.Color"] or theme["AddressList.Header.Font.Color"] or design.COLOR_INPUT_TEXT
    design.COLOR_BORDER = theme["AddressList.Header.Canvas.Pen.Color"] or theme["MainForm.Panel4.BevelColor"] or design.COLOR_BORDER
    design.COLOR_MUTED = theme["Memrec.GroupHeader.Color"] or design.COLOR_MUTED
    design.COLOR_SURFACE = theme["MainForm.Foundlist3.Color"] or design.COLOR_SURFACE
    design.COLOR_SURFACE_ALT = theme["MainForm.Color"] or design.COLOR_SURFACE_ALT
    return design
end
registerLuaFunctionHighlight('ResolveTheme')

--
--- ∑ Checks whether a registry entry belongs to a visible root.
--- @param entry table # A Forms registry entry.
--- @returns boolean # True when the root is visible or visibility cannot be determined.
--
function Forms:_IsVisibleRoot(entry)
    if not entry or not entry.root then return true end
    local visible = self:_SafeGet(entry.root, "Visible")
    return visible ~= false
end

--
--- ∑ Applies a normalized Forms theme to one registered control.
--- @param entry table # A Forms registry entry.
--- @param designTheme table # The normalized Forms design theme.
--- @param includeHidden boolean # Whether hidden roots should also be updated.
--
function Forms:ApplyThemeToControl(entry, designTheme, includeHidden)
    if not entry or not entry.control then return end
    if includeHidden ~= true and not self:_IsVisibleRoot(entry) then return end
    local control = entry.control
    local role = entry.role or "panel"
    local opts = entry.options or {}
    local theme = designTheme or self.ActiveDesignTheme or DEFAULT_THEME
    local fontSize = opts.fontSize or opts.size or 10
    local fontStyle = opts.fontStyle or opts.style
    local function roleColor(color)
        if opts.lockColor == true and opts.color ~= nil then
            return opts.color
        end
        return color
    end
    if role == "form" or role == "root" or role == "background" or role == "body" then
        self:_SetColor(control, theme.COLOR_BG)
        self:ApplyFont(control, theme.COLOR_TEXT, fontSize, fontStyle)
    elseif role == "panel" or role == "toolbar" or role == "footer" then
        self:_SetColor(control, roleColor(theme.COLOR_PANEL))
        self:_SetBevel(control, opts.bevelOuter, theme.COLOR_BORDER, opts.bevelWidth)
        self:ApplyFont(control, theme.COLOR_TEXT, fontSize, fontStyle)
    elseif role == "surface" then
        self:_SetColor(control, roleColor(theme.COLOR_SURFACE))
        self:_SetBevel(control, opts.bevelOuter, theme.COLOR_BORDER, opts.bevelWidth)
        self:ApplyFont(control, theme.COLOR_TEXT, fontSize, fontStyle)
    elseif role == "surfaceAlt" then
        self:_SetColor(control, roleColor(theme.COLOR_SURFACE_ALT))
        self:_SetBevel(control, opts.bevelOuter, theme.COLOR_BORDER, opts.bevelWidth)
        self:ApplyFont(control, theme.COLOR_TEXT, fontSize, fontStyle)
    elseif role == "preview" or role == "swatch" then
        if opts.lockColor ~= true then
            self:_SetColor(control, opts.color or theme.COLOR_SURFACE)
        end
        self:_SetBevel(control, opts.bevelOuter, theme.COLOR_BORDER, opts.bevelWidth)
    elseif role == "border" or role == "cardBorder" or role == "fieldBorder" then
        self:_SetColor(control, theme.COLOR_BORDER)
        self:_SetBevel(control, opts.bevelOuter or "bvRaised", theme.COLOR_BORDER, opts.bevelWidth or 1)
    elseif role == "header" then
        self:_SetColor(control, theme.COLOR_BTN)
        self:_SetBevel(control, opts.bevelOuter, theme.COLOR_BORDER, opts.bevelWidth)
    elseif role == "inputPanel" or role == "fieldFill" or role == "fieldInner" or role == "memoPanel" or role == "memoInner" then
        self:_SetColor(control, theme.COLOR_INPUT)
        self:_SetBevel(control, opts.bevelOuter, theme.COLOR_BORDER, opts.bevelWidth)
    elseif role == "input" or role == "textbox" then
        self:_SetColor(control, theme.COLOR_INPUT)
        self:_SafeSet(control, "BorderStyle", opts.borderStyle or "bsNone")
        self:ApplyFont(control, theme.COLOR_INPUT_TEXT, fontSize, fontStyle)
    elseif role == "memo" then
        self:_SetColor(control, theme.COLOR_INPUT)
        self:_SafeSet(control, "BorderStyle", opts.borderStyle or "bsNone")
        self:ApplyFont(control, theme.COLOR_INPUT_TEXT, fontSize, fontStyle)
    elseif role == "tree" or role == "treeview" or role == "listview" then
        self:_SetColor(control, theme.COLOR_INPUT)
        self:_SafeSet(control, "BorderStyle", opts.borderStyle or "bsNone")
        self:ApplyFont(control, theme.COLOR_INPUT_TEXT, fontSize, fontStyle)
    elseif role == "button" then
        self:_SetColor(control, theme.COLOR_BTN)
        self:_SetBevel(control, opts.bevelOuter or "bvRaised", theme.COLOR_BORDER, opts.bevelWidth or 1)
        pcall(function()
            control._theme = theme
        end)
        self:ApplyFont(control, theme.COLOR_BTN_TEXT, fontSize, fontStyle or "[fsBold]")
        local label = self:_SafeGet(control, "_label") or opts.label
        if label then
            self:ApplyFont(label, theme.COLOR_BTN_TEXT, fontSize, fontStyle or "[fsBold]")
        end
    elseif role == "buttonLabel" then
        self:ApplyFont(control, theme.COLOR_BTN_TEXT, fontSize, fontStyle or "[fsBold]")
    elseif role == "headerLabel" then
        self:ApplyFont(control, theme.COLOR_LABEL, fontSize, fontStyle or "[fsBold]")
    elseif role == "mutedLabel" then
        self:ApplyFont(control, theme.COLOR_MUTED, fontSize, fontStyle)
    elseif role == "label" then
        self:ApplyFont(control, theme.COLOR_LABEL, fontSize, fontStyle)
    else
        self:_SetColor(control, roleColor(theme.COLOR_PANEL))
        self:ApplyFont(control, opts.fontColor or theme.COLOR_TEXT, fontSize, fontStyle)
    end
    self:Repaint(control)
end
registerLuaFunctionHighlight('ApplyThemeToControl')

--
--- ∑ Applies a theme to all registered Forms controls.
--- @param theme table # A Manifold theme token table or normalized Forms theme.
--- @param includeHidden boolean # Whether hidden roots should also be updated.
--- @returns table # The normalized Forms design theme that was applied.
--
function Forms:ApplyTheme(theme, includeHidden)
    local registry = self:_EnsureRegistry()
    local designTheme = self:ResolveTheme(theme)
    self.ActiveTheme = theme
    self.ActiveDesignTheme = designTheme
    for _, entry in ipairs(registry.Controls) do
        self:ApplyThemeToControl(entry, designTheme, includeHidden)
    end
    return designTheme
end
registerLuaFunctionHighlight('ApplyTheme')

--
--- ∑ Updates a Forms button to its normal or hover visual state.
--- @param button table # The Forms button panel.
--- @param isHover boolean # True for hover state, false for normal state.
--
function Forms:SetButtonState(button, isHover)
    if not button then return end
    local theme = self:_SafeGet(button, "_theme") or self.ActiveDesignTheme or DEFAULT_THEME
    self:_SetColor(button, isHover and theme.COLOR_BTN_HOVER or theme.COLOR_BTN)
    local label = self:_SafeGet(button, "_label")
    if label then
        self:ApplyFont(label, isHover and theme.COLOR_BG or theme.COLOR_BTN_TEXT, 10, "[fsBold]")
    end
    self:Repaint(button)
end
registerLuaFunctionHighlight('SetButtonState')

--
--- ∑ Creates and registers a themed form.
--- @param opts table # Form creation and layout options.
--- @returns table # The created form.
--
function Forms:CreateForm(opts)
    opts = opts or {}
    local form
    if opts.visible ~= nil then
        form = createForm(opts.visible)
    else
        form = createForm()
    end
    form.BorderStyle = "bsSizeable"
    self:_ApplyCommonOptions(form, opts)
    self:RegisterForm(form, opts)
    return form
end
registerLuaFunctionHighlight('CreateForm')

--
--- ∑ Creates and registers a themed panel.
--- @param parent table # The parent control.
--- @param opts table # Panel creation and layout options.
--- @returns table # The created panel.
--
function Forms:CreatePanel(parent, opts)
    opts = opts or {}
    opts.parent = parent
    local panel = createPanel(parent)
    self:_ApplyCommonOptions(panel, opts)
    if opts.height ~= nil then self:_SafeSet(panel, "Height", opts.height) end
    if opts.width ~= nil then self:_SafeSet(panel, "Width", opts.width) end
    if opts.color ~= nil then self:_SetColor(panel, opts.color) end
    self:_SetBevel(panel, opts.bevelOuter or "bvNone", opts.bevelColor, opts.bevelWidth)
    self:RegisterControl(panel, opts.role or "panel", opts)
    return panel
end
registerLuaFunctionHighlight('CreatePanel')

--
--- ∑ Creates and registers a themed label.
--- @param parent table # The parent control.
--- @param opts table # Label creation and layout options.
--- @returns table # The created label.
--
function Forms:CreateLabel(parent, opts)
    opts = opts or {}
    opts.parent = parent
    local label = createLabel(parent)
    self:_ApplyCommonOptions(label, opts)
    self:RegisterControl(label, opts.role or "label", opts)
    return label
end
registerLuaFunctionHighlight('CreateLabel')

--
--- ∑ Creates and registers a themed single-line text box.
--- @param parent table # The parent control.
--- @param opts table # Text box creation and layout options.
--- @returns table # The created edit control.
--
function Forms:CreateTextBox(parent, opts)
    opts = opts or {}
    opts.parent = parent
    local edit = createEdit(parent)
    self:_ApplyCommonOptions(edit, opts)
    self:RegisterControl(edit, opts.role or "input", opts)
    return edit
end
registerLuaFunctionHighlight('CreateTextBox')

--
--- ∑ Creates and registers a themed multi-line memo.
--- @param parent table # The parent control.
--- @param opts table # Memo creation and layout options.
--- @returns table # The created memo control.
--
function Forms:CreateMemo(parent, opts)
    opts = opts or {}
    opts.parent = parent
    local memo = createMemo(parent)
    self:_ApplyCommonOptions(memo, opts)
    self:RegisterControl(memo, opts.role or "memo", opts)
    return memo
end
registerLuaFunctionHighlight('CreateMemo')

--
--- ∑ Creates a themed memo wrapped in input-colored panels.
--- @param parent table # The parent control.
--- @param opts table # Memo frame creation and layout options.
--- @returns table, table, table # The memo control, outer memo panel, and inner memo panel.
--
function Forms:CreateMemoFrame(parent, opts)
    opts = opts or {}
    local theme = opts.theme or self.ActiveDesignTheme or DEFAULT_THEME
    local outer = self:CreatePanel(parent, {
        align = opts.align or "alClient",
        height = opts.height,
        color = theme.COLOR_INPUT,
        role = "memoPanel",
        bevelOuter = opts.bevelOuter or "bvLowered",
        bevelWidth = opts.bevelWidth or 1,
        bevelColor = theme.COLOR_BORDER,
        borderSpacing = opts.borderSpacing or { Around = 1 }
    })
    local inner = self:CreatePanel(outer, {
        align = "alClient",
        color = theme.COLOR_INPUT,
        role = "memoInner",
        borderSpacing = opts.innerSpacing or { Left = 6, Right = 6, Top = 6, Bottom = 6 }
    })
    local memo = self:CreateMemo(inner, {
        align = "alClient",
        parentColor = false,
        color = theme.COLOR_INPUT,
        borderStyle = "bsNone",
        wordWrap = opts.wordWrap ~= false,
        scrollBars = opts.scrollBars or "ssAutoBoth",
        role = "memo"
    })
    return memo, outer, inner
end
registerLuaFunctionHighlight('CreateMemoFrame')

--
--- ∑ Creates a bordered card with header, content panel, and title label.
--- @param parent table # The parent control.
--- @param opts table # Card creation and layout options.
--- @returns table, table, table, table, table # Outer border, inner panel, header panel, content panel, and header label.
--
function Forms:CreateCard(parent, opts)
    opts = opts or {}
    local theme = opts.theme or self.ActiveDesignTheme or DEFAULT_THEME
    local outer = self:CreatePanel(parent, {
        align = opts.align or "alTop",
        height = opts.size or opts.height,
        width = opts.width,
        color = theme.COLOR_BORDER,
        role = "cardBorder",
        bevelOuter = "bvRaised",
        bevelWidth = 1,
        bevelColor = theme.COLOR_BORDER,
        borderSpacing = opts.borderSpacing or { Around = 6 }
    })
    local inner = self:CreatePanel(outer, {
        align = "alClient",
        color = theme.COLOR_PANEL,
        role = "panel",
        borderSpacing = { Around = 1 }
    })
    local header = self:CreatePanel(inner, {
        align = "alTop",
        height = opts.headerHeight or 24,
        color = theme.COLOR_PANEL,
        role = "header",
        bevelOuter = "bvLowered",
        bevelWidth = 1,
        bevelColor = theme.COLOR_BORDER
    })
    local headerLabel = self:CreateLabel(header, {
        align = "alLeft",
        caption = opts.title or "SECTION",
        transparent = true,
        role = "headerLabel",
        borderSpacing = { Left = 6, Top = 4 },
        style = "[fsBold]"
    })
    local content = self:CreatePanel(inner, {
        align = "alClient",
        color = theme.COLOR_PANEL,
        role = "panel",
        borderSpacing = opts.contentSpacing or { Around = 6 }
    })
    return outer, inner, header, content, headerLabel
end
registerLuaFunctionHighlight('CreateCard')

--
--- ∑ Creates a themed labeled input row.
--- @param parent table # The parent control.
--- @param opts table # Field row creation and layout options.
--- @returns table, table, table, table, table, table, table # Edit, row, label, border, fill, inner panel, and label/edit gap.
--
function Forms:CreateFieldRow(parent, opts)
    opts = opts or {}
    local theme = opts.theme or self.ActiveDesignTheme or DEFAULT_THEME
    local row = self:CreatePanel(parent, {
        align = opts.align or "alTop",
        height = opts.height or 34,
        color = theme.COLOR_PANEL,
        role = "panel",
        borderSpacing = opts.borderSpacing or { Bottom = 6 }
    })
    local border = self:CreatePanel(row, {
        align = "alClient",
        color = theme.COLOR_BORDER,
        role = "fieldBorder",
        bevelOuter = "bvRaised",
        bevelWidth = 1,
        bevelColor = theme.COLOR_BORDER
    })
    local fill = self:CreatePanel(border, {
        align = "alClient",
        color = theme.COLOR_INPUT,
        role = "fieldFill",
        borderSpacing = { Around = 1 }
    })
    local inner = self:CreatePanel(fill, {
        align = "alClient",
        color = theme.COLOR_INPUT,
        role = "fieldInner",
        borderSpacing = opts.innerSpacing or { Left = 6, Right = 8, Top = 4, Bottom = 4 }
    })
    local label = self:CreateLabel(inner, {
        align = "alLeft",
        width = opts.labelWidth or 52,
        caption = opts.caption or "",
        alignment = "taLeftJustify",
        layout = "tlCenter",
        transparent = true,
        role = "label",
        style = "[fsBold]"
    })
    local gap = self:CreatePanel(inner, {
        align = "alLeft",
        width = opts.gapWidth or 6,
        color = theme.COLOR_INPUT,
        role = "fieldInner"
    })
    local edit = self:CreateTextBox(inner, {
        align = "alClient",
        parentColor = false,
        color = theme.COLOR_INPUT,
        borderStyle = "bsNone",
        textHint = opts.textHint or "",
        role = "input",
        borderSpacing = { Left = 10, Top = 3 }
    })
    return edit, row, label, border, fill, inner, gap
end
registerLuaFunctionHighlight('CreateFieldRow')

--
--- ∑ Creates a themed panel button with a centered label and hover behavior.
--- @param parent table # The parent control.
--- @param opts table # Button creation, layout, and click handler options.
--- @returns table, table # The button panel and its label.
--
function Forms:CreateButton(parent, opts)
    opts = opts or {}
    local theme = opts.theme or self.ActiveDesignTheme or DEFAULT_THEME
    local button = self:CreatePanel(parent, {
        align = opts.align or "alLeft",
        height = opts.height or 30,
        width = opts.width or 92,
        color = theme.COLOR_BTN,
        role = "button",
        bevelOuter = opts.bevelOuter or "bvRaised",
        bevelWidth = opts.bevelWidth or 1,
        bevelColor = theme.COLOR_BORDER,
        cursor = opts.cursor or -21,
        borderSpacing = opts.borderSpacing or { Right = 6 },
        fontSize = opts.fontSize or 10,
        style = opts.style or "[fsBold]"
    })
    local label = self:CreateLabel(button, {
        align = "alClient",
        alignment = "taCenter",
        layout = "tlCenter",
        caption = opts.caption or "Button",
        transparent = true,
        role = "buttonLabel",
        fontSize = opts.fontSize or 10,
        style = opts.style or "[fsBold]"
    })
    pcall(function()
        button._theme = theme
        button._label = label
    end)
    local function clickHandler()
        if type(opts.onClick) == "function" then
            opts.onClick()
        end
    end
    button.OnClick = clickHandler
    label.OnClick = clickHandler
    button.OnMouseEnter = function() self:SetButtonState(button, true) end
    button.OnMouseLeave = function() self:SetButtonState(button, false) end
    label.OnMouseEnter = function() self:SetButtonState(button, true) end
    label.OnMouseLeave = function() self:SetButtonState(button, false) end
    return button, label
end
registerLuaFunctionHighlight('CreateButton')

--
--- ∑ Replaces the click handler on a Forms button and its label.
--- @param button table # The Forms button panel.
--- @param handler function # The click handler to assign.
--- @returns table # The updated button panel.
--
function Forms:SetButtonOnClick(button, handler)
    if not button then return nil end
    self:_SafeSet(button, "OnClick", handler)
    local label = self:_SafeGet(button, "_label")
    if label then
        self:_SafeSet(label, "OnClick", handler)
    end
    return button
end
registerLuaFunctionHighlight('SetButtonOnClick')

--
--- ∑ Creates and registers a themed tree view.
--- @param parent table # The parent control.
--- @param opts table # Tree view creation and layout options.
--- @returns table # The created tree view.
--
function Forms:CreateTreeView(parent, opts)
    opts = opts or {}
    opts.parent = parent
    local tree = createTreeView(parent)
    self:_ApplyCommonOptions(tree, opts)
    self:RegisterControl(tree, opts.role or "tree", opts)
    return tree
end
registerLuaFunctionHighlight('CreateTreeView')

--
--- ∑ Creates and registers a themed list view.
--- @param parent table # The parent control.
--- @param opts table # List view creation and layout options.
--- @returns table # The created list view.
--
function Forms:CreateListView(parent, opts)
    opts = opts or {}
    opts.parent = parent
    local list = createListView(parent)
    list.BorderStyle = "bsNone"
    self:_ApplyCommonOptions(list, opts)
    self:RegisterControl(list, opts.role or "listview", opts)
    return list
end
registerLuaFunctionHighlight('CreateListView')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Forms
