--[[
    UI: menu construction, template categorization, log viewer and preview.

    This module owns presentation only. Every action delegates to a callback
    provided by the runtime, the UI never parses templates, never builds
    context and never touches registrations itself.
    All menu items created here carry the Manifold Tag marker, so a rebuild
    removes exactly our own items and leaves Cheat Engine's and other
    extensions' entries untouched.
]]

local Icons = require("Manifold-TemplateLoader-Icons")

local UI = { ManagedMenuTag = 1297374284 }
UI.__index = UI

local function trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

local function itemContainer(menu)
    if menu and menu.ClassName == "TMainMenu" then return menu.Items end
    return menu
end

local function childCount(menu)
    local container = itemContainer(menu)
    return container and tonumber(container.Count) or 0
end

local function getChild(menu, index)
    local container = itemContainer(menu)
    return container and container.getItem and container:getItem(index) or nil
end

local function addToParent(parent, item)
    if parent.ClassName == "TMainMenu" then
        parent.Items:add(item)
    else
        parent:add(item)
    end
end

local function createMenu(parent, options)
    local item = createMenuItem(parent)
    for key, value in pairs(options or {}) do item[key] = value end
    item.Tag = UI.ManagedMenuTag
    addToParent(parent, item)
    return item
end

local function categoryParts(value)
    local parts = {}
    -- '>' is the explicit hierarchy separator. '/' stays available for labels
    -- such as the bundled "x86/x64" categories.
    for rawPart in tostring(value or "Templates"):gmatch("[^>]+") do
        local part = trim(rawPart)
        if part ~= "" then parts[#parts + 1] = part end
    end
    return #parts > 0 and parts or { "Templates" }
end

--- "[2] Name" -> "Name", 2. The bracket prefix is 2.x-compatible sort
--- metadata while schema-2 templates use CategoryOrder instead.
local function categoryCaption(value)
    local order, caption = value:match("^%s*%[([%-]?%d+)%]%s*(.-)%s*$")
    return caption and caption ~= "" and caption or value, tonumber(order) or math.huge
end

function UI:New(services)
    return setmetatable({
        Log = services.Log,
        CE = services.CE,
        Paths = services.Paths,
        Theme = services.Theme,
        Icons = Icons:New(),
        LogViewerForm = nil,
        OwnedForms = {}
    }, UI)
end

--
--- Destroys every form this UI created. Called on a full runtime reload so
--- no window survives pointing at a dead generation.
--
function UI:DestroyOwnedForms()
    for _, form in ipairs(self.OwnedForms) do
        pcall(function() form.destroy() end)
    end
    self.OwnedForms = {}
    self.LogViewerForm = nil
    self.LogViewerRefresh = nil
end

-- Generic menu helpers -------------------------------------------------------

--
--- Removes the items this loader created. TMenuItem.delete only DETACHES,
--- so each item is destroyed afterwards, otherwise every rebuild orphans a
--- whole menu tree plus its click closures. Destroying a category also
--- destroys its children, which is why template items must be moved out
--- first (see FlattenTemplateItems).
--
function UI:RemoveManagedItems(parent)
    if not parent then return end
    local container = itemContainer(parent)
    local detached = {}
    for index = childCount(parent) - 1, 0, -1 do
        local item = getChild(parent, index)
        if item and item.Tag == self.ManagedMenuTag then
            container:delete(index)
            detached[#detached + 1] = item
        end
    end
    for _, item in ipairs(detached) do
        pcall(function() item.destroy() end)
    end
end

--
--- Moves Cheat Engine's own template menu items back to the direct children
--- of the template root and drops our category containers.
--- This is mandatory before unregisterAutoAssemblerTemplate: CE 7.5's
--- TfrmAutoInject.removeTemplate frees a template item by scanning ONLY the
--- direct children of emplate1 (Don't ask me why it's called that way) for
--- Tag = id + 1. An item this loader moved into a category submenu is invisible
--- to that scan, so CE would leave it behind while registerAutoAssemblerTemplate
--- appends a fresh flat item, the window would end up showing every template
--- twice, and the stale entries would dispatch through reused template ids.
--
function UI:FlattenTemplateItems(rootMenu)
    if not rootMenu then return end
    local moved = {}
    local function collect(menu)
        for index = childCount(menu) - 1, 0, -1 do
            local item = getChild(menu, index)
            if item then
                if item.Tag == self.ManagedMenuTag then
                    collect(item)
                elseif menu ~= rootMenu then
                    itemContainer(menu):delete(index)
                    moved[#moved + 1] = item
                end
            end
        end
    end
    collect(rootMenu)
    self:RemoveManagedItems(rootMenu)
    for index = #moved, 1, -1 do
        rootMenu:add(moved[index])
    end
    return #moved
end

function UI:BuildTree(parent, tree)
    for _, entry in ipairs(tree or {}) do
        if entry.separator then
            createMenu(parent, { Caption = "-", Name = entry.name or "ManifoldSeparator" })
        else
            local item = createMenu(parent, {
                Caption = entry.caption,
                Name = entry.name,
                ImageIndex = entry.image,
                AutoCheck = false,
                RadioItem = entry.radio == true,
                Checked = entry.checked == true,
                OnClick = entry.onClick
            })
            -- Order is load-bearing. TMenuItem.SetImageIndex bails out early
            -- when no image list resolves, and GetImageList walks up from the
            -- item's PARENT, so the parent must already be carrying
            -- SubMenuImages before any child sets its ImageIndex.
            if entry.iconParent then self.Icons:AttachTo(item) end
            if entry.sub then self:BuildTree(item, entry.sub) end
            if entry.icon then self.Icons:Apply(item, entry.icon) end
        end
    end
end

function UI:FindMenuItem(form, name)
    local function visit(menu)
        if not menu then return nil end
        if menu.Name == name then return menu end
        for index = 0, childCount(menu) - 1 do
            local found = visit(getChild(menu, index))
            if found then return found end
        end
        return nil
    end
    if form and form.MainMenu1 and form.MainMenu1.Items then
        local found = visit(form.MainMenu1.Items)
        if found then return found end
    end
    for index = 0, (form and form.ComponentCount or 0) - 1 do
        local component = form.Component[index]
        if component and component.ClassName == "TMenuItem" and component.Name == name then return component end
    end
    return nil
end

function UI:AddSeparatorAfter(parentMenu, itemName)
    if not parentMenu then return false end
    for index = 0, childCount(parentMenu) - 1 do
        local item = getChild(parentMenu, index)
        if item and item.Name == itemName then
            local nextItem = getChild(parentMenu, index + 1)
            if nextItem and nextItem.Caption == "-" then return false end
            local separator = createMenuItem(parentMenu)
            separator.Caption = "-"
            parentMenu:insert(index + 1, separator)
            return true
        end
    end
    return false
end

-- Template menu categorization -----------------------------------------------

--
--- Moves the flat entries Cheat Engine created for registered templates into
--- the category hierarchy, then prepends Favorites and Recent submenus.
--- callbacks.onGenerateById(id) is used for Favorites/Recent clicks.
--
function UI:CategorizeMenuItems(definitions, rootMenu, indices, callbacks)
    if not rootMenu then return false, "Template root menu was not found" end
    local lookup = {}
    for _, template in ipairs(definitions) do
        lookup[template.settings.Caption] = template
    end
    local grouped, rootItems, matched = {}, {}, 0
    local categoryOrders = {}
    for index = childCount(rootMenu) - 1, 0, -1 do
        local item = getChild(rootMenu, index)
        local template = item and lookup[item.Caption]
        if template then
            matched = matched + 1
            rootMenu:delete(index)
            local settings = template.settings
            if settings.InSubMenu == false then
                rootItems[#rootItems + 1] = { item = item, template = template }
            else
                local category = settings.Category or "Templates"
                grouped[category] = grouped[category] or {}
                grouped[category][#grouped[category] + 1] = { item = item, template = template }
                if settings.CategoryOrder then
                    local current = categoryOrders[category]
                    categoryOrders[category] = current and math.min(current, settings.CategoryOrder)
                        or settings.CategoryOrder
                end
            end
        end
    end
    table.sort(rootItems, function(a, b) return a.template.settings.Caption:lower() < b.template.settings.Caption:lower() end)
    for _, entry in ipairs(rootItems) do
        entry.item.ImageIndex = indices.Template
        rootMenu:add(entry.item)
    end
    local categories = {}
    for category in pairs(grouped) do categories[#categories + 1] = category end
    local function effectiveOrder(category)
        if categoryOrders[category] then return categoryOrders[category] end
        return select(2, categoryCaption(category))
    end
    table.sort(categories, function(a, b)
        local aOrder, bOrder = effectiveOrder(a), effectiveOrder(b)
        if aOrder ~= bOrder then return aOrder < bOrder end
        return (categoryCaption(a)):lower() < (categoryCaption(b)):lower()
    end)
    local menuByPath, categorySequence = {}, 0
    for _, category in ipairs(categories) do
        local parent, path = rootMenu, ""
        for _, rawPart in ipairs(categoryParts(category)) do
            path = path == "" and rawPart or path .. "/" .. rawPart
            if not menuByPath[path] then
                local caption = categoryCaption(rawPart)
                categorySequence = categorySequence + 1
                menuByPath[path] = createMenu(parent, {
                    Caption = caption,
                    Name = "ManifoldCategory" .. tostring(categorySequence),
                    ImageIndex = indices.Inject
                })
            end
            parent = menuByPath[path]
        end
        local entries = grouped[category]
        table.sort(entries, function(a, b)
            local aOrder = tonumber(a.template.settings.Order) or math.huge
            local bOrder = tonumber(b.template.settings.Order) or math.huge
            if aOrder ~= bOrder then return aOrder < bOrder end
            return a.item.Caption:lower() < b.item.Caption:lower()
        end)
        for _, entry in ipairs(entries) do
            entry.item.ImageIndex = indices.Template
            parent:add(entry.item)
        end
    end
    if callbacks then
        self:_InsertQuickLists(definitions, rootMenu, indices, callbacks)
    end
    self.Log:InfoF("[UI] Categorized %d root template item(s) into %d category group(s).", matched, #categories)
    return true
end

--
--- Favorites and Recent are plain UI references onto existing definitions, so
--- the same template is never registered with Cheat Engine twice.
--
function UI:_InsertQuickLists(definitions, rootMenu, indices, callbacks)
    -- A repeated BuildMenu on the same window must not duplicate the lists.
    -- delete() only detaches, so the old items are destroyed here as well.
    -- They hold click closures onto template ids.
    local container = itemContainer(rootMenu)
    local stale = {}
    for index = childCount(rootMenu) - 1, 0, -1 do
        local item = getChild(rootMenu, index)
        local name = item and item.Name
        if name == "ManifoldFavorites" or name == "ManifoldRecent" or name == "ManifoldQuickSeparator" then
            container:delete(index)
            stale[#stale + 1] = item
        end
    end
    for _, item in ipairs(stale) do
        pcall(function() item.destroy() end)
    end
    local byId = {}
    for _, template in ipairs(definitions) do byId[template.id] = template end
    local function buildList(caption, name, ids)
        local entries = {}
        for _, id in ipairs(ids or {}) do
            local template = byId[id]
            if template then
                entries[#entries + 1] = {
                    caption = template.settings.Caption,
                    name = name .. "Item" .. #entries,
                    image = indices.Template,
                    onClick = function() callbacks.onGenerateById(id) end
                }
            end
        end
        if #entries == 0 then return nil end
        return { caption = caption, name = name, image = indices.Eye, sub = entries }
    end
    local tree = {}
    local favorites = buildList("Favorites", "ManifoldFavorites", callbacks.getFavorites())
    local recent = buildList("Recent", "ManifoldRecent", callbacks.getRecent())
    if favorites then tree[#tree + 1] = favorites end
    if recent then tree[#tree + 1] = recent end
    if #tree == 0 then return end
    tree[#tree + 1] = { separator = true, name = "ManifoldQuickSeparator" }
    -- Build detached at the root, then move each created item to the top in
    -- reverse so the declared order survives the insert-at-0 calls.
    local before = childCount(rootMenu)
    self:BuildTree(rootMenu, tree)
    local created = {}
    for index = childCount(rootMenu) - 1, before, -1 do
        created[#created + 1] = getChild(rootMenu, index)
        rootMenu:delete(index)
    end
    for _, item in ipairs(created) do
        rootMenu:insert(0, item)
    end
end

-- Main "Template Loader" menu ------------------------------------------------

local function levelMenu(config, callbacks)
    local levels, levelItems = { "TRACE", "DEBUG", "INFO", "WARNING", "ERROR" }, {}
    for _, level in ipairs(levels) do
        levelItems[#levelItems + 1] = {
            caption = level,
            name = "ManifoldLogLevel_" .. level,
            radio = true,
            checked = config.Logger.Level == level,
            -- Resolved against the parent's SubMenuImages, not the menu's own
            -- Images, so it indexes the Manifold icon list rather than CE's.
            icon = level ~= "TRACE" and level or "DEBUG",
            onClick = function(sender) callbacks.onLevelChange(level, sender) end
        }
    end
    return levelItems
end

--
--- The "Template Loader" menu.
---
--- Icons: the root item still uses a Cheat Engine bitmap from the window's
--- own aaImageList, because its parent is the main menu and attaching our
--- list there would re-index every OTHER top-level menu of the window.
--- Attaching it to the root item instead covers the whole subtree, since
--- TMenuItem.GetImageList walks up to the nearest ancestor carrying
--- SubMenuImages. Inside that subtree "icon" names an entry of the Manifold
--- icon set and "image" must NOT be used, the two index different lists.
--
function UI:GetMainMenuTree(config, indices, callbacks)
    return {
        {
            caption = "Template Loader", name = "ManifoldTemplateLoader", image = indices.Template,
            iconParent = true,
            sub = {
                { caption = "Templates", name = "ManifoldTemplatesMenu", icon = "Templates", sub = {
                    { caption = "Reload Templates", name = "ManifoldReloadTemplates", icon = "Reload",
                      onClick = callbacks.onReloadTemplates },
                    { caption = "Validate All Templates", name = "ManifoldValidateTemplates", icon = "Validate",
                      onClick = callbacks.onValidateTemplates },
                    { caption = "Open Template Folder", name = "ManifoldOpenFolder", icon = "Folder",
                      onClick = callbacks.onOpenFolder },
                    { caption = "Template Status", name = "ManifoldTemplateStatus", icon = "Status",
                      onClick = callbacks.onTemplateStatus },
                    { separator = true, name = "ManifoldFavSeparator" },
                    { caption = "Add Favorite...", name = "ManifoldAddFavorite", icon = "Favorite",
                      onClick = callbacks.onAddFavorite },
                    { caption = "Remove Favorite...", name = "ManifoldRemoveFavorite", icon = "FavoriteOff",
                      onClick = callbacks.onRemoveFavorite }
                } },
                { caption = "Settings", name = "ManifoldSettingsMenu", icon = "Settings", sub = {
                    { caption = "Generation", name = "ManifoldGenerationSettings", icon = "Generation", sub = {
                        { caption = "Set Info Line Count...", name = "ManifoldSetInfoLines", onClick = callbacks.onSetLineCount },
                        { caption = "Remove Spaces", name = "ManifoldRemoveSpaces", autoCheck = true,
                          checked = config.InjectionInfo.RemoveSpaces == true,
                          onClick = callbacks.onToggle("InjectionInfo", "RemoveSpaces") },
                        { caption = "Indent Information", name = "ManifoldAddTabs", autoCheck = true,
                          checked = config.InjectionInfo.AddTabs == true,
                          onClick = callbacks.onToggle("InjectionInfo", "AddTabs") },
                        { caption = "Hook-Name Suffix...", name = "ManifoldSetSuffix", onClick = callbacks.onSetAppend },
                        { separator = true, name = "ManifoldGenSeparator" },
                        { caption = "Validate Output (AA Syntax Check)", name = "ManifoldValidateOutput", autoCheck = true,
                          checked = config.Generation.ValidateOutput == true,
                          onClick = callbacks.onToggle("Generation", "ValidateOutput") },
                        { caption = "Preview Before Apply", name = "ManifoldPreview", autoCheck = true,
                          checked = config.Generation.PreviewBeforeApply == true,
                          onClick = callbacks.onToggle("Generation", "PreviewBeforeApply") }
                    } },
                    { caption = "Memory", name = "ManifoldMemorySettings", icon = "Memory", sub = {
                        { caption = "Ask For Hook Name", name = "ManifoldAskHookName", autoCheck = true,
                          checked = config.Memory.AskForHookName == true,
                          onClick = callbacks.onToggle("Memory", "AskForHookName") },
                        { caption = "Ask For Injection Address", name = "ManifoldAskAddress", autoCheck = true,
                          checked = config.Memory.AskForInjectionAddress == true,
                          onClick = callbacks.onToggle("Memory", "AskForInjectionAddress") },
                        { caption = "Allocate Near Injection", name = "ManifoldAllocationNear", autoCheck = true,
                          checked = config.Memory.AllocationNear == true,
                          onClick = callbacks.onToggle("Memory", "AllocationNear") },
                        { caption = "Set Allocation Size...", name = "ManifoldAllocationSize", onClick = callbacks.onSetAllocationSize },
                        { caption = "Default Hook Name...", name = "ManifoldDefaultHookName", onClick = callbacks.onSetDefaultHookName }
                    } },
                    { caption = "Reset Settings", name = "ManifoldResetConfig", icon = "Reset",
                      onClick = callbacks.onResetConfig }
                } },
                { caption = "Logging", name = "ManifoldLoggerSettings", icon = "Logging", sub = {
                    { caption = "Log Level (" .. tostring(config.Logger.Level) .. ")",
                      name = "ManifoldLogLevel", icon = "Level",
                      sub = levelMenu(config, callbacks) },
                    { caption = "Write Log File", name = "ManifoldLogToFile", autoCheck = true, icon = "WriteFile",
                      checked = config.Logger.LogToFile == true, onClick = callbacks.onLogToFile },
                    { caption = "View Logs", name = "ManifoldViewLogs", icon = "Eye", onClick = callbacks.onViewLogs },
                    { caption = "Open Log File", name = "ManifoldOpenLogFile", icon = "File", onClick = callbacks.onOpenLogFile },
                    { caption = "Open Log Folder", name = "ManifoldOpenLogFolder", icon = "Folder", onClick = callbacks.onOpenLogFolder }
                } },
                { caption = "Development", name = "ManifoldDevelopment", icon = "Development", sub = {
                    { caption = "Reload Templates", name = "ManifoldDevReloadTemplates", icon = "Reload",
                      onClick = callbacks.onReloadTemplates },
                    { caption = "Reload Providers And Extensions", name = "ManifoldReloadProviders", icon = "Providers",
                      onClick = callbacks.onReloadProviders },
                    { caption = "Full Runtime Reload", name = "ManifoldFullReload", icon = "FullReload",
                      onClick = callbacks.onFullReload }
                } },
                { caption = "Diagnostics", name = "ManifoldDiagnostics", icon = "Diagnostics", sub = {
                    { caption = "Runtime Status", name = "ManifoldRuntimeStatus", icon = "Status",
                      onClick = callbacks.onRuntimeStatus },
                    { caption = "Run Self-Check", name = "ManifoldSelfCheck", icon = "SelfCheck",
                      onClick = callbacks.onSelfCheck },
                    { caption = "Copy Diagnostic Report", name = "ManifoldCopyDiagnostics", icon = "Copy",
                      onClick = callbacks.onCopyDiagnostics }
                } },
                { caption = "About", name = "ManifoldAbout", icon = "About", onClick = callbacks.onAbout }
            }
        }
    }
end

-- Text windows ---------------------------------------------------------------

--
--- Themed, resizeable window whose content fills all remaining space.
--- "mode" selects the content control: nil = themed memo (reports, logs),
--- 1 = SynEdit with Auto Assembler highlighting, 0 = Lua highlighting.
--- Layout is Align-driven throughout, status line and button bar at the
--- bottom, the card with the text view on alClient, so resizing works.
--- Returns form, getText, setText, buttonBar, statusLabel.
--
function UI:_CreateTextForm(options)
    local theme = self.Theme
    local form = theme:CreateWindow(options.Caption, options.Width, options.Height)
    local statusLabel
    if options.Status ~= nil then
        statusLabel = theme:CreateStatusBar(form, options.Status)
    end
    local buttonBar = theme:CreateButtonBar(form)
    local content = theme:CreateCard(form, { Title = options.Title })
    local view, getText, setText
    if options.Mode ~= nil then
        view, getText, setText = theme:CreateCodeView(content, options.Mode)
    else
        view = theme:CreateMemo(content)
        getText = function() return view.Lines.Text end
        setText = function(value) view.Lines.Text = value end
    end
    view.Align = "alClient"
    setText(options.Text or "")
    return form, getText, setText, buttonBar, statusLabel
end

local function lineCount(text)
    if type(text) ~= "string" or text == "" then return 0 end
    local _, count = text:gsub("\n", "")
    return count + 1
end

--
--- Modal read-only text window with Copy and Close.
--
function UI:ShowTextWindow(caption, text, title)
    local ce = self.CE
    ce:RunInMain(function()
        local form, getText, _, buttonBar = self:_CreateTextForm{
            Caption = caption,
            Title = title or "Report",
            Text = text,
            Status = string.format("%d line(s)", lineCount(text))
        }
        -- alRight stacks right to left in creation order.
        self.Theme:CreateButton(buttonBar, {
            Caption = "Close", Align = "alRight",
            Form = form, ModalResult = rawget(_G, "mrCancel") or 2
        })
        self.Theme:CreateButton(buttonBar, {
            Caption = "Copy", Align = "alRight",
            OnClick = function() ce:WriteToClipboard(getText()) end
        })
        form.ShowModal()
        form.destroy()
    end)
end

--
--- Preview dialog with Auto Assembler highlighting. Returns true when the
--- user chose Insert.
--
function UI:ShowPreview(caption, text)
    local ce = self.CE
    local accepted = false
    ce:RunInMain(function()
        local form, getText, _, buttonBar = self:_CreateTextForm{
            Caption = "Preview - " .. tostring(caption),
            Title = tostring(caption),
            Text = text,
            Mode = 1,
            Width = 760, Height = 580,
            Status = string.format("%d line(s), nothing has been written to the editor yet",
                lineCount(text))
        }
        self.Theme:CreateButton(buttonBar, {
            Caption = "Close", Align = "alRight",
            Form = form, ModalResult = rawget(_G, "mrCancel") or 2
        })
        self.Theme:CreateButton(buttonBar, {
            Caption = "Copy", Align = "alRight",
            OnClick = function() ce:WriteToClipboard(getText()) end
        })
        self.Theme:CreateButton(buttonBar, {
            Caption = "Insert", Align = "alRight",
            Form = form, ModalResult = rawget(_G, "mrOK") or 1
        })
        accepted = form.ShowModal() == (rawget(_G, "mrOK") or 1)
        form.destroy()
    end)
    return accepted
end

-- Log viewer -----------------------------------------------------------------

local LOG_LEVEL_CHOICES = { "TRACE", "DEBUG", "INFO", "WARNING", "ERROR", "FATAL" }

function UI:ShowLogViewer(logger)
    local ce = self.CE
    ce:RunInMain(function()
        if self.LogViewerForm then
            -- The cached form may have been destroyed outside our control, so
            -- fall through and rebuild instead of silently doing nothing.
            local alive = pcall(function()
                self.LogViewerForm.Visible = true
                self.LogViewerForm.BringToFront()
            end)
            if alive then
                -- Closing only hides the viewer, so a reopen must refresh.
                -- Otherwise it shows the log as of the last time it was open.
                if self.LogViewerRefresh then pcall(self.LogViewerRefresh) end
                return
            end
            self.LogViewerForm = nil
            self.LogViewerRefresh = nil
        end
        local theme = self.Theme
        local form = theme:CreateWindow("Template Loader - Logs", 820, 540)
        self.LogViewerForm = form
        self.OwnedForms[#self.OwnedForms + 1] = form
        local statusLabel = theme:CreateStatusBar(form, "")
        local buttonBar = theme:CreateButtonBar(form)
        -- Filter row on top, log card filling the rest.
        local filterCard = theme:CreateCard(form, {
            Align = "alTop", Height = 56, Title = nil,
            ContentSpacing = { Left = 8, Right = 8, Top = 6, Bottom = 6 }
        })
        local levelLabel = createLabel(filterCard)
        levelLabel.Caption = "Level:"
        levelLabel.Left, levelLabel.Top = 4, 8
        theme:StyleLabel(levelLabel)
        local levelBox = createComboBox(filterCard)
        levelBox.Left, levelBox.Top, levelBox.Width = 56, 4, 110
        levelBox.Style = "csDropDownList"
        for _, level in ipairs(LOG_LEVEL_CHOICES) do levelBox.Items.add(level) end
        levelBox.ItemIndex = 0
        theme:StyleCombo(levelBox)
        local searchLabel = createLabel(filterCard)
        searchLabel.Caption = "Search:"
        searchLabel.Left, searchLabel.Top = 186, 8
        theme:StyleLabel(searchLabel)
        local searchEdit = createEdit(filterCard)
        searchEdit.Left, searchEdit.Top, searchEdit.Width = 250, 4, 260
        searchEdit.Anchors = "[akLeft,akTop,akRight]"
        searchEdit.Text = ""
        theme:StyleEdit(searchEdit)
        local logCard = theme:CreateCard(form, { Title = "Log" })
        local memo = theme:CreateMemo(logCard)
        local function refresh()
            local minLevel = logger.LogLevel[LOG_LEVEL_CHOICES[levelBox.ItemIndex + 1] or "TRACE"] or 1
            local entries, suppressed = logger:GetEntries(minLevel, searchEdit.Text)
            local lines = {}
            for _, entry in ipairs(entries) do lines[#lines + 1] = entry.Text end
            memo.Lines.Text = table.concat(lines, "\n")
            -- The ring keeps entries below the active log level, so the
            -- viewer can show what the console never printed. Say so, or the
            -- extra lines look like a bug.
            local status = string.format("%d of %d entries shown", #entries, logger.RingCount or #entries)
            if suppressed and suppressed > 0 then
                status = string.format("%s, %d below the active log level (%s), not printed",
                    status, suppressed, logger:GetLogLevelName())
            end
            statusLabel.Caption = status
        end
        levelBox.OnChange = refresh
        searchEdit.OnChange = refresh
        self.LogViewerRefresh = refresh
        local function addButton(caption, onClick)
            return theme:CreateButton(buttonBar, {
                Caption = caption, Align = "alRight", Width = 120, OnClick = onClick
            })
        end
        -- alRight stacks right to left in creation order.
        addButton("Open Log Folder", function()
            if self.Paths.LogDir then ce:ShellExecute(self.Paths.LogDir) end
        end)
        addButton("Open Log File", function()
            if logger.LogFileName then ce:ShellExecute(logger.LogFileName) end
        end)
        addButton("Copy", function() ce:WriteToClipboard(memo.Lines.Text) end)
        addButton("Clear", function()
            logger:ClearEntries()
            refresh()
        end)
        addButton("Refresh", refresh)
        -- Hide instead of free. The viewer is reused on the next "View Logs",
        -- and the runtime destroys it on a full reload via DestroyOwnedForms.
        form.OnClose = function()
            return rawget(_G, "caHide") or 1
        end
        refresh()
        form.Visible = true
    end)
end

return UI