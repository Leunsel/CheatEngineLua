--[[
    Windows, folders and the compact main form.

    The small actions: showing a Cheat Engine window, opening a folder in
    Explorer, and hiding the bottom half of the main form. Each reports what
    it could not do rather than failing quietly; a menu entry that does
    nothing is the worst outcome for a quality-of-life menu.
]]

local Shell = {}
Shell.__index = Shell

--- The main form controls compact mode hides: the bottom panel with the
--- scanner and the splitter above it. The same two Manifold.UI's
--- EnableCompactMode touches.
Shell.CompactControls = { "Panel5", "Splitter1" }

function Shell:New(deps)
    return setmetatable({
        CE = deps.CE,
        Log = deps.Log
    }, Shell)
end

--------------------------------------------------------
--                        Windows                     --
--------------------------------------------------------

function Shell:ShowForm(getter, label)
    local ok, err = self.CE:RunInMain(function()
        local form = getter()
        if not form then error(label .. " is not available", 0) end
        form.show()
    end)
    if not ok then self.Log:Warning("Open " .. label .. ": " .. tostring(err) .. ".") end
    return ok == true
end

function Shell:OpenLuaEngine()
    return self:ShowForm(function() return self.CE:LuaEngine() end, "the Lua Engine")
end

function Shell:OpenMemoryViewer()
    return self:ShowForm(function() return self.CE:MemoryView() end, "the Memory Viewer")
end

function Shell:OpenStructureDissect()
    local ok, err = self.CE:RunInMain(function()
        local create = rawget(_G, "createStructureForm")
        if type(create) ~= "function" then error("createStructureForm is not available", 0) end
        create(nil, nil, nil)
    end)
    if not ok then self.Log:Warning("Open Structure Dissect: " .. tostring(err) .. ".") end
    return ok == true
end

--
--- ∑ Opens Manifold Table Files. The viewer lives in its own autorun
---   segment and registers no menu of its own; this is its menu entry.
--- @return boolean
--
function Shell:OpenTableFiles()
    local viewer = rawget(_G, "ManifoldTableFiles")
    if type(viewer) ~= "table" or type(viewer.Open) ~= "function" then
        self.Log:Warning("Manifold Table Files is not installed. Copy Manifold-TableFiles.lua " ..
            "and its -Modules folder into Cheat Engine's autorun directory.")
        return false
    end
    local ok, err = pcall(viewer.Open, viewer)
    if not ok then self.Log:Error("Open Table Files: " .. tostring(err)) end
    return ok
end

--
--- ∑ Opens the Manifold Logger console. The Logger installs a menu of its
---   own by default; with InstallMenu = false it expects this entry to be
---   the way in, which its Host says in as many words.
--- @return boolean
--
function Shell:OpenLogConsole()
    local logger = rawget(_G, "ManifoldLogger")
    if type(logger) ~= "table" or type(logger.Open) ~= "function" then
        self.Log:Warning("Manifold Logger is not installed. Copy Manifold-Logger.lua " ..
            "and its -Modules folder into Cheat Engine's autorun directory.")
        return false
    end
    local ok, err = pcall(logger.Open, logger)
    if not ok then self.Log:Error("Open Log Console: " .. tostring(err)) end
    return ok
end

--------------------------------------------------------
--                        Folders                     --
--------------------------------------------------------

function Shell:OpenFolder(folder, label)
    if type(folder) ~= "string" or folder == "" then
        self.Log:Warning(label .. ": no folder to open.")
        return false
    end
    local ok, err = self.CE:Shell(folder)
    if not ok then self.Log:Error(label .. ": " .. tostring(err) .. ".") end
    return ok
end

function Shell:OpenAutorunFolder()
    return self:OpenFolder(self.CE:Call("getAutorunPath"), "Open autorun folder")
end

--
--- ∑ The folder of the attached process's main module.
--- @return string|nil, string|nil
--
function Shell:ProcessFolder()
    if not self.CE:ProcessOpen() then return nil, "no process is attached" end
    local modules = self.CE:Call("enumModules")
    if type(modules) ~= "table" or #modules == 0 then return nil, "enumModules returned nothing" end
    local path = self.CE:Get(modules[1], "PathToFile")
    if type(path) ~= "string" or path == "" then return nil, "the main module has no path" end
    local folder = path:match("^(.*)[\\/][^\\/]+$")
    if not folder or folder == "" then return nil, "could not derive a folder from " .. path end
    return folder
end

function Shell:OpenProcessFolder()
    local folder, reason = self:ProcessFolder()
    if not folder then
        self.Log:Warning("Open process folder: " .. reason .. ".")
        return false
    end
    return self:OpenFolder(folder, "Open process folder")
end

--------------------------------------------------------
--                      Compact mode                  --
--------------------------------------------------------

--- Whether the main form is compact, or nil when it cannot be asked.
function Shell:IsCompact()
    local form = self.CE:MainForm()
    local panel = form and self.CE:Get(form, Shell.CompactControls[1]) or nil
    if panel == nil then return nil end
    return self.CE:Get(panel, "Visible") == false
end

function Shell:SetCompactMode(enabled)
    local ok, err = self.CE:RunInMain(function()
        local form = self.CE:MainForm()
        if not form then error("the main form is not available", 0) end
        for _, name in ipairs(Shell.CompactControls) do
            local control = form[name]
            if control == nil then error("control '" .. name .. "' was not found on the main form", 0) end
            control.Visible = not enabled
        end
    end)
    if not ok then
        self.Log:Warning("Compact mode: " .. tostring(err) .. ".")
        return false
    end
    self.Log:Info(enabled and "Compact mode on." or "Compact mode off.")
    return true
end

function Shell:ToggleCompactMode()
    local compact = self:IsCompact()
    if compact == nil then
        self.Log:Warning("Compact mode: the main form is not available.")
        return false
    end
    return self:SetCompactMode(not compact)
end

return Shell
