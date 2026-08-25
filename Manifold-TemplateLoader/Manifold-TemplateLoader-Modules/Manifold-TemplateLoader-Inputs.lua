--[[
    Declarative template inputs.

    A template's settings can declare typed inputs. This module validates the
    declarations at discovery time and collects the values in one dialog at
    generation time. The dialog only appears when a template actually has
    inputs. Cancelling aborts the generation before anything renders, so the
    editor is never touched.
]]

local Errors = require("Manifold-TemplateLoader-Errors")

local Inputs = {}
Inputs.__index = Inputs

Inputs.Types = { string = true, boolean = true, integer = true, number = true, enum = true }

function Inputs:New(services)
    return setmetatable({
        CE = services.CE,
        Log = services.Log,
        Theme = services.Theme
    }, Inputs)
end

-- Validation -----------------------------------------------------------------

local function validateOne(definition, index)
    if type(definition) ~= "table" then
        return nil, string.format("Input #%d must be a table", index)
    end
    local name = definition.Name
    if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
        return nil, string.format("Input #%d has no valid Name (must be an identifier)", index)
    end
    local inputType = definition.Type or "string"
    if not Inputs.Types[inputType] then
        return nil, string.format("Input '%s' has unknown Type '%s'", name, tostring(inputType))
    end
    local normalized = {
        Name = name,
        Type = inputType,
        Caption = type(definition.Caption) == "string" and definition.Caption or name,
        Default = definition.Default
    }
    if inputType == "enum" then
        if type(definition.Values) ~= "table" or #definition.Values == 0 then
            return nil, string.format("Enum input '%s' needs a non-empty Values list", name)
        end
        normalized.Values = {}
        for _, value in ipairs(definition.Values) do
            if type(value) ~= "string" then
                return nil, string.format("Enum input '%s' has a non-string value", name)
            end
            normalized.Values[#normalized.Values + 1] = value
        end
        if normalized.Default == nil then normalized.Default = normalized.Values[1] end
        local found = false
        for _, value in ipairs(normalized.Values) do
            if value == normalized.Default then found = true break end
        end
        if not found then
            return nil, string.format("Enum input '%s' default '%s' is not in Values", name, tostring(normalized.Default))
        end
    elseif inputType == "boolean" then
        normalized.Default = normalized.Default == true
    elseif inputType == "integer" or inputType == "number" then
        normalized.Min = tonumber(definition.Min)
        normalized.Max = tonumber(definition.Max)
        normalized.Default = tonumber(normalized.Default) or 0
        if inputType == "integer" then normalized.Default = math.floor(normalized.Default) end
    else
        normalized.Default = normalized.Default == nil and "" or tostring(normalized.Default)
    end
    return normalized
end

--
--- Validates a full Inputs declaration. Returns the normalized list or
--- nil, message.
--
function Inputs:ValidateDefinitions(definitions)
    if definitions == nil then return {} end
    if type(definitions) ~= "table" then return nil, "Inputs must be a list" end
    local normalized, seen = {}, {}
    for index, definition in ipairs(definitions) do
        local entry, problem = validateOne(definition, index)
        if not entry then return nil, problem end
        if seen[entry.Name] then
            return nil, string.format("Input '%s' is declared twice", entry.Name)
        end
        seen[entry.Name] = true
        normalized[#normalized + 1] = entry
    end
    return normalized
end

-- Value parsing --------------------------------------------------------------

function Inputs:ParseValue(definition, raw)
    if definition.Type == "boolean" then
        return raw == true
    elseif definition.Type == "enum" then
        for _, value in ipairs(definition.Values) do
            if value == raw then return raw end
        end
        return nil, string.format("'%s' must be one of: %s", definition.Caption, table.concat(definition.Values, ", "))
    elseif definition.Type == "integer" or definition.Type == "number" then
        local number = tonumber(raw)
        if not number then
            return nil, string.format("'%s' must be a number", definition.Caption)
        end
        if definition.Type == "integer" then
            if number ~= math.floor(number) then
                return nil, string.format("'%s' must be a whole number", definition.Caption)
            end
        end
        if definition.Min and number < definition.Min then
            return nil, string.format("'%s' must be at least %s", definition.Caption, tostring(definition.Min))
        end
        if definition.Max and number > definition.Max then
            return nil, string.format("'%s' must be at most %s", definition.Caption, tostring(definition.Max))
        end
        return number
    end
    return tostring(raw or "")
end

-- Collection dialog ----------------------------------------------------------

local ROW_HEIGHT = 32
local LABEL_WIDTH, CONTROL_WIDTH = 160, 220

--
--- One row per input, laid out inside a card so the dialog matches the rest
--- of the loader's windows and stays resizeable.
--
function Inputs:_BuildForm(definitions, templateCaption)
    local theme = self.Theme
    local width = LABEL_WIDTH + CONTROL_WIDTH + 60
    local height = #definitions * ROW_HEIGHT + 150
    local form, content
    if theme then
        form = theme:CreateWindow(tostring(templateCaption or "Template") .. " - Inputs", width, height)
        local buttonBar = theme:CreateButtonBar(form)
        content = theme:CreateCard(form, { Title = "Template Inputs" })
        -- alRight stacks right to left in creation order.
        theme:CreateButton(buttonBar, {
            Caption = "Cancel", Align = "alRight",
            Form = form, ModalResult = rawget(_G, "mrCancel") or 2
        })
        theme:CreateButton(buttonBar, {
            Caption = "OK", Align = "alRight",
            Form = form, ModalResult = rawget(_G, "mrOK") or 1
        })
    else
        form = createForm(false)
        form.Caption = tostring(templateCaption or "Template") .. " - Inputs"
        form.Position = "poScreenCenter"
        form.BorderStyle = "bsSizeable"
        form.Width, form.Height = width, height
        content = form
        local okButton = createButton(form)
        okButton.Caption = "OK"
        okButton.Left, okButton.Top, okButton.Width = width - 190, height - 70, 80
        okButton.Anchors = "[akRight,akBottom]"
        okButton.ModalResult = rawget(_G, "mrOK") or 1
        okButton.Default = true
        local cancelButton = createButton(form)
        cancelButton.Caption = "Cancel"
        cancelButton.Left, cancelButton.Top, cancelButton.Width = width - 100, height - 70, 80
        cancelButton.Anchors = "[akRight,akBottom]"
        cancelButton.ModalResult = rawget(_G, "mrCancel") or 2
        cancelButton.Cancel = true
    end
    local controls = {}
    for index, definition in ipairs(definitions) do
        local top = 6 + (index - 1) * ROW_HEIGHT
        if definition.Type == "boolean" then
            local checkbox = createCheckBox(content)
            checkbox.Caption = definition.Caption
            checkbox.Left, checkbox.Top = 4, top + 4
            checkbox.Checked = definition.Default == true
            if theme then theme:StyleCheckBox(checkbox) end
            controls[definition.Name] = { Definition = definition, Control = checkbox }
        else
            local label = createLabel(content)
            label.Caption = definition.Caption .. ":"
            label.Left, label.Top = 4, top + 6
            if theme then theme:StyleLabel(label) end
            local control
            if definition.Type == "enum" then
                control = createComboBox(content)
                control.Style = "csDropDownList"
                local selected = 0
                for valueIndex, value in ipairs(definition.Values) do
                    control.Items.add(value)
                    if value == definition.Default then selected = valueIndex - 1 end
                end
                control.ItemIndex = selected
                if theme then theme:StyleCombo(control) end
            else
                control = createEdit(content)
                control.Text = tostring(definition.Default == nil and "" or definition.Default)
                if theme then theme:StyleEdit(control) end
            end
            control.Left, control.Top, control.Width = LABEL_WIDTH, top + 2, CONTROL_WIDTH
            control.Anchors = "[akLeft,akTop,akRight]"
            controls[definition.Name] = { Definition = definition, Control = control }
        end
    end
    return form, controls
end

function Inputs:_ReadControls(controls)
    local values, problems = {}, {}
    for name, entry in pairs(controls) do
        local raw
        if entry.Definition.Type == "boolean" then
            raw = entry.Control.Checked == true
        elseif entry.Definition.Type == "enum" then
            local itemIndex = entry.Control.ItemIndex
            raw = itemIndex >= 0 and entry.Definition.Values[itemIndex + 1] or nil
        else
            raw = entry.Control.Text
        end
        local value, problem = self:ParseValue(entry.Definition, raw)
        if problem then
            problems[#problems + 1] = problem
        else
            values[name] = value
        end
    end
    return values, problems
end

--
--- Shows the input dialog and returns the value table, or nil plus a
--- structured error (INPUT_CANCELLED when the user backed out).
--
function Inputs:Collect(definitions, templateCaption)
    if not definitions or #definitions == 0 then return {} end
    local ce = self.CE
    local collect = function()
        local form, controls = self:_BuildForm(definitions, templateCaption)
        local mrOk = rawget(_G, "mrOK") or 1
        local result, problems
        while true do
            local modal = form.ShowModal()
            if modal ~= mrOk then
                form.destroy()
                return nil, Errors.New{
                    Code = Errors.Codes.INPUT_CANCELLED, Stage = Errors.Stages.Inputs,
                    Template = templateCaption, Message = "Input dialog was cancelled"
                }
            end
            result, problems = self:_ReadControls(controls)
            if #problems == 0 then
                form.destroy()
                return result
            end
            ce:MessageDialog(table.concat(problems, "\n"), rawget(_G, "mtError") or 1, rawget(_G, "mbOK") or 2)
        end
    end
    if ce:InMainThread() then
        return collect()
    end
    local values, err
    synchronize(function() values, err = collect() end)
    return values, err
end

return Inputs