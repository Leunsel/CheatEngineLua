local NAME = "TemplateLoader.Loader"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Cheat Engine Template Framework (Loader)"

--[[
    -- To debug the module, use the following setup to load modules from the autorun folder:
    local sep = package.config:sub(1, 1)
    package.path = getAutorunPath() .. "Modules" .. sep .. "?.lua;" .. package.path
    local Loader = require("Loader")
]]

local sep = package.config:sub(1, 1)
package.path = getAutorunPath() .. "Modules" .. sep .. "?.lua;" .. package.path
local Logger = require("Logger")
local File = require("File")
local Memory = require("Memory")
local Manager = require("Manager")

Logger.ShouldLog = false

Loader = {
    registeredTemplates = {}
}
Loader.__index = Loader

function Loader:reloadDependencies()
    -- Todo: (?) Actually see if everything was successful...
    -- Clearing modules
    Logger.info("Loader: Clearing package.loaded cache for TemplateLoader modules...")
    package.loaded["File"] = nil
    Logger.info("Loader: 'File' cleared.")
    
    package.loaded["Memory"] = nil
    Logger.info("Loader: 'Memory' cleared.")
    
    package.loaded["Manager"] = nil
    Logger.info("Loader: 'Manager' cleared.")

    Logger.info("Loader: 'Logger' is to be cleared... Reloading next...")

    Logger.forceClose = true
    Logger.form.Close()
    package.loaded["Logger"] = nil

    -- Reload modules
    Logger = require("Logger")
    Logger.toggle()
    Logger.info("Loader: 'Logger' reloaded.")
    
    Manager = require("Manager")
    Logger.info("Loader: 'Manager' reloaded.")
    
    Memory = require("Memory")
    Logger.info("Loader: 'Memory' reloaded.")
    
    File = require("File")
    Logger.info("Loader: 'File' reloaded.")
end

function Loader:getRegisteredTemplates()
    local templates = {}
    for caption, id in pairs(self.registeredTemplates) do
        table.insert(templates, { caption = caption, id = id })
    end
    return templates
end

function Loader.new()
    local self = setmetatable({}, Loader)
    self.templates = Manager.discoverTemplates()
    Logger.success("Loader: Discovered " .. #self.templates .. " templates.")
    return self
end

function Loader:loadTemplates()
    if not self.templates or #self.templates == 0 then
        Logger.warn("Loader: No templates found during loadTemplates.")
        return
    end

    for _, template in ipairs(self.templates) do
        Logger.debug("Loader: Registering template - '" .. template.fileName .. "'")
        self:registerTemplate(template)
    end

    Logger.success("Loader: All templates successfully registered.")
end

function Loader:registerTemplate(template)
    local caption = template.fileName
    local shortcut = template.settings and template.settings.Shortcut
    Logger.info("Loader: Preparing to register template: '" .. caption .. "'")

    local id = registerAutoAssemblerTemplate(
        caption,
        function(script, sender)
            Logger.info("Loader: Generating script for template - '" .. caption .. "'")
            self:generateTemplateScript(template, script, sender)
        end,
        shortcut
    )

    if id then
        self.registeredTemplates[caption] = id
        Logger.success("Loader: Registered template '" .. caption .. "' with ID: " .. id)
    else
        Logger.error("Loader: Failed to register template: '" .. caption .. "'")
    end
end

function Loader:generateTemplateScript(template, script, sender)
    Logger.info("Loader: Initializing environment for template: '" .. template.fileName .. "'")
    local env = self:initializeEnvironment(template.settings)

    Logger.info("Loader: Compiling header template (if exists).")
    env.Header = self:compileHeaderTemplate(env)

    Logger.info("Loader: Compiling script for template: '" .. template.fileName .. "'")
    local compiledTemplate = self:compileFile(template.scriptPath, env)
    if compiledTemplate then
        Logger.success("Loader: Successfully compiled template: '" .. template.fileName .. "'")
        self:applyCompiledTemplate(compiledTemplate, script)
    else
        Logger.error("Loader: Failed to compile template at '" .. template.scriptPath .. "'")
    end
end

function Loader:unregisterTemplate(caption)
    local id = self.registeredTemplates[caption]
    if id then
        unregisterAutoAssemblerTemplate(id)
        self.registeredTemplates[caption] = nil
        Logger.success("Loader: Unregistered template '" .. caption .. "' with ID: " .. id)
    else
        Logger.warn("Loader: Attempted to unregister unknown template: " .. caption)
    end
end

function Loader:initializeMenu(form)
    local function createMenuItemWithParent(parentMenu, caption, name, options)
        local menuItem = createMenuItem(parentMenu)
        menuItem.Caption = caption
        menuItem.Name = name
        if options then
            if options.ImageIndex then menuItem.ImageIndex = options.ImageIndex end
            if options.AutoCheck ~= nil then menuItem.AutoCheck = options.AutoCheck end
            if options.OnClick then menuItem.OnClick = options.OnClick end
        end

        if parentMenu == form.MainMenu1 then
            parentMenu.Items.add(menuItem)
        else
            parentMenu.add(menuItem)
        end

        return menuItem
    end

    Logger.debug("Loader: Initializing menu...")

    -- Cache Image Indices
    local memoryViewForm = getMemoryViewForm() -- Only as single ref. needed.
    local aaImageList = form.aaImageList
    local ResyncIndex = aaImageList.add(MainForm.miResyncFormsWithLua.Bitmap)
    local BreakAndTraceIndex = aaImageList.add(memoryViewForm.miBreakAndTrace.Bitmap)
    local LoadTraceIndex = aaImageList.add(memoryViewForm.miLoadTrace.Bitmap)

    -- Main Menu Item
    local templateOptionsMenu = createMenuItemWithParent(form.MainMenu1, "Template Options", "TemplateOptions")

    -- Sub Menu Items
    local subMenus = {
        {caption = "Hot Reload Templates", name = "HotReloadTemplates", ImageIndex = ResyncIndex, 
            onClick = function()
                Logger.debug("Loader: Hot reloading templates...")
                self:reloadTemplates()
            end},
        {caption = "Debug Templates", name = "DebugTemplates", ImageIndex = BreakAndTraceIndex, 
            onClick = function()
                Logger.debug("Loader: Debugging templates...")
                self:debugTemplates()
            end},
        {caption = "Toggle Logger", name = "ToggleLogger", ImageIndex = LoadTraceIndex, 
            onClick = function()
                Logger.toggle()
            end},
        {caption = "Reload Dependencies", name = "ReloadDependencies", ImageIndex = ResyncIndex, 
            onClick = function()
                self:reloadDependencies()
            end}
    }

    for _, menu in ipairs(subMenus) do
        createMenuItemWithParent(templateOptionsMenu, menu.caption, menu.name, {
            ImageIndex = menu.ImageIndex,
            OnClick = menu.onClick
        })
    end
end

function Loader:attachMenuToForm()
    local function delayedExecute(func, delay, ...)
        createTimer(delay, func, ...)
    end

    local function onFormCreate(form)
        if form.ClassName == "TfrmAutoInject" then
            delayedExecute(function() self:initializeMenu(form) end, 50)
        end
    end

    Logger.info("Loader: Attaching menu to TfrmAutoInject form.")
    registerFormAddNotification(onFormCreate)
end

function Loader:reloadTemplates()
    Logger.info("Loader: Reloading all templates...")

    for caption, id in pairs(self.registeredTemplates) do
        unregisterAutoAssemblerTemplate(id)
        Logger.success("Loader: Unregistered template '" .. caption .. "' with ID: " .. id)
    end
    self.registeredTemplates = {}

    self.templates = Manager.discoverTemplates()
    Logger.success("Loader: Discovered " .. #self.templates .. " templates during reload.")

    self:loadTemplates()

    Logger.success("Loader: All templates reloaded.")
end

function Loader:initializeEnvironment(settings)
    local env = Memory.Script.gatherMemoryInfo(settings or {})
    env.FinalCompilation = false
    setmetatable(env, { __index = _G })
    Logger.success("Loader: Environment initialized.")
    return env
end

function Loader:compileHeaderTemplate(env)
    local headerPath = Manager.getTemplatesFolder() .. sep .. 'Header' .. Manager.getCeaExtension()
    headerPath = headerPath:gsub("\\", "/")
    headerPath = headerPath:gsub("//+", "/")
    Logger.debug("Loader: Header template path: ".. headerPath)
    if File.exists(headerPath) then
        Logger.success("Loader: Found header template at: " .. headerPath)
        local compiledHeader, err = self:compileFile(headerPath, env)
        if not compiledHeader then
            Logger.error("Loader: Error compiling header template: " .. err)
        else
            Logger.success("Loader: Header template compiled successfully.")
        end
        return compiledHeader
    else
        Logger.warn("Loader: No header template found.")
    end
    return nil
end

function Loader:compileFile(filePath, env)
    if not filePath or not File.exists(filePath) then
        Logger.error("Loader: File not found: " .. tostring(filePath))
        return nil, "File not found"
    end

    Logger.debug("Loader: Compiling file at: " .. filePath)
    local f, err = io.open(filePath, 'r')
    if not f then
        Logger.error("Loader: Error opening file: " .. err)
        return nil, err
    end

    local template = f:read('*all')
    f:close()
    Logger.success("Loader: File read successfully.")
    return self:compile(template, env)
end

function Loader:compile(template, env)
    if not template or template == '' then
        Logger.warn("Loader: Empty template.")
        return ''
    end

    local builder = { '_ret = {}\n' }
    local pos = 1
    while pos <= #template do
        local startTag = template:find('<[<%%]', pos)
        if not startTag then
            self:append(builder, template:sub(pos))
            break
        end

        self:append(builder, template:sub(pos, startTag - 1))
        local endTag = template:find('[>%%]>', startTag)
        if not endTag then
            Logger.critical("Loader: Missing closing tag for block: " .. template:sub(startTag, startTag + 2))
            error("Loader: Missing closing tag for block: " .. template:sub(startTag, startTag + 2))
        end
        self:runBlock(builder, template:sub(startTag, endTag + 1))
        pos = endTag + 2
    end

    builder[#builder + 1] = 'return table.concat(_ret)'
    Logger.success("Loader: Builder completed.")
    local func, err = load(table.concat(builder, '\n'), 'template', 't', env)
    if not func then
        Logger.error("Loader: Error compiling template: " .. err)
        return nil, err
    end
    return func()
end

function Loader:append(builder, text, code)
    if code then
        builder[#builder + 1] = code
    else
        local fmt = '_ret[#_ret + 1] = [%s[\n%s]%s]'
        local mlsFix = string.rep('=', 10)
        builder[#builder + 1] = string.format(fmt, mlsFix, text, mlsFix)
    end
end

function Loader:runBlock(builder, text)
    local tag = text:sub(1, 2)
    if tag == '<<' then
        local code = text:sub(3, #text - 2):gsub("^%s*(.-)%s*$", "%1")
        self:append(builder, nil, string.format('_ret[#_ret + 1] = tostring(%s)', code))
    elseif tag == '<%' then
        local code = text:sub(3, #text - 2)
        self:append(builder, nil, code)
    else
        self:append(builder, text)
    end
end

function Loader:applyCompiledTemplate(compiledTemplate, script)
    Logger.info("Loader: Applying compiled template.")
    if type(script.addText) == 'function' then
        script.addText(compiledTemplate)
    else
        local s = script.getText()
        script.clear()
        script.setText(s .. compiledTemplate)
    end
end

function Loader:debugTemplates()
    if not self.templates or #self.templates == 0 then
        Logger.warn("Loader: No templates discovered.")
        return
    end

    Logger.success("Loader: Discovered templates:")
    for _, template in ipairs(self.templates) do
        Logger.debug(string.format("  Name: %s --- File: %s", template.name, template.fileName .. Manager.getCeaExtension()))
    end
end

function Loader.createAndLoad()
    local loader = Loader.new()
    loader:loadTemplates()
    return loader
end

return Loader
