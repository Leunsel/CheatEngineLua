--[[
    The host. Wires the modules together, owns the menu spec, and is the
    object published as ManifoldCEUtility.

    Build order:

      CE          the defensive API wrappers
      Log         the Manifold Logger channel, or print
      Settings    defaults, overrides, the three persisted values
      Icons       the 16x16 set, one image list per session
      Structures  Generate Structure Records, Remove All Structures
      Records     Deactivate All Scripts, Deactivate Everything, Normalize IDs
      Shell       windows, folders, compact mode
      Menu        the root entry, its items, the caption ticker

    Everything the menu does is a method here, so a table's Lua script or the
    Lua console can call it without the menu:

        ManifoldCEUtility:GenerateStructureRecords()
        ManifoldCEUtility:DeactivateEverything()
        ManifoldCEUtility:Status()
]]

local CE         = require("Manifold-CE-Utility-CE")
local Log        = require("Manifold-CE-Utility-Log")
local Icons      = require("Manifold-CE-Utility-Icons")
local Settings   = require("Manifold-CE-Utility-Settings")
local Structures = require("Manifold-CE-Utility-Structures")
local Records    = require("Manifold-CE-Utility-Records")
local Shell      = require("Manifold-CE-Utility-Shell")
local Menu       = require("Manifold-CE-Utility-Menu")
local Version    = require("Manifold-CE-Utility-Version")

local Host = {}
Host.__index = Host

--- The _G slots the entry point publishes under. Named here so Shutdown
--- releases exactly what the entry point looks for.
Host.GlobalKey = "ManifoldCEUtilityHost"
Host.FacadeKey = "ManifoldCEUtility"

--- The "Manifold" marker on every menu item this tool creates. The Template
--- Loader and the Logger carry their own values, so the three never sweep
--- each other's entries.
Host.MenuTag = 1297374316

--
--- ∑ Builds the host and everything under it. Nothing touches Cheat Engine
---   until Install.
--- @param options table|nil # { Settings = overrides, Persist, Root, Print }
--- @return table
--
function Host:New(options)
    options = options or {}
    local ce = CE:New()
    local log = Log:New({ Print = options.Print })
    local settings = Settings:New({ Overrides = options.Settings, Persist = options.Persist })
    local icons = Icons:New({ Root = options.Root })
    local instance = setmetatable({
        CE = ce,
        Log = log,
        Settings = settings,
        Icons = icons,
        Version = Version,
        Started = os.time()
    }, Host)
    instance.Structures = Structures:New({ CE = ce, Log = log, Settings = settings })
    instance.Records = Records:New({ CE = ce, Log = log, Settings = settings })
    instance.Shell = Shell:New({ CE = ce, Log = log })
    instance.Menu = Menu:New({ CE = ce, Log = log, Icons = icons, Settings = settings, MenuTag = Host.MenuTag })
    return instance
end

--------------------------------------------------------
--                        The menu                    --
--------------------------------------------------------

--
--- ∑ What the menu contains. A table, so the order and the captions are
---   readable in one place and a test can walk it.
--- @return table
--
function Host:MenuSpec()
    local settings = self.Settings
    local shortcuts = settings.Shortcuts
    return {
        { Caption = "Open Lua Engine", Icon = "LuaEngine", Shortcut = shortcuts.LuaEngine,
          OnClick = function() self.Shell:OpenLuaEngine() end },
        { Caption = "Open Memory Viewer", Icon = "MemoryView", Shortcut = shortcuts.MemoryViewer,
          OnClick = function() self.Shell:OpenMemoryViewer() end },
        "-",
        { Caption = "Open Structure Dissect", Icon = "Dissect",
          OnClick = function() self.Shell:OpenStructureDissect() end },
        { Caption = "Generate Structure Records", Icon = "Generate",
          OnClick = function() self.Structures:Generate() end },
        { Caption = "Remove All Structures", Icon = "Remove",
          OnClick = function() self.Structures:RemoveAll() end },
        { Caption = "Open Table File Viewer", Icon = "TableFiles",
          OnClick = function() self.Shell:OpenTableFiles() end },
        { Caption = "Open Log Console", Icon = "LogConsole",
          OnClick = function() self.Shell:OpenLogConsole() end },
        "-",
        { Caption = "Deactivate All Scripts", Icon = "Deactivate", Shortcut = shortcuts.DeactivateScripts,
          OnClick = function() self.Records:Deactivate(true) end },
        { Caption = "Deactivate Everything", Icon = "DeactivateAll", Shortcut = shortcuts.DeactivateEverything,
          OnClick = function() self.Records:Deactivate(false) end },
        { Caption = "Normalize Cheat Table IDs", Icon = "Normalize",
          OnClick = function() self.Records:NormalizeIDs() end },
        "-",
        { Caption = "Toggle Compact Mode", Icon = "Compact", Shortcut = shortcuts.CompactMode,
          OnClick = function() self.Shell:ToggleCompactMode() end },
        "-",
        { Caption = "Open Autorun Folder", Icon = "Folder",
          OnClick = function() self.Shell:OpenAutorunFolder() end },
        { Caption = "Open Process Folder", Icon = "Folder",
          OnClick = function() self.Shell:OpenProcessFolder() end },
        "-",
        { Caption = "Settings", Icon = "Settings", Items = {
            { Caption = "Animate Caption",
              Checked = function() return settings.AnimatedCaption end,
              OnClick = function() self:SetAnimatedCaption(not settings.AnimatedCaption) end },
            { Caption = "Animation Speed", Items = {
                { Caption = "Slow (600 ms)",
                  Checked = function() return settings.AnimationInterval == 600 end,
                  OnClick = function() self:SetAnimationInterval(600) end },
                { Caption = "Normal (350 ms)",
                  Checked = function() return settings.AnimationInterval == 350 end,
                  OnClick = function() self:SetAnimationInterval(350) end },
                { Caption = "Fast (200 ms)",
                  Checked = function() return settings.AnimationInterval == 200 end,
                  OnClick = function() self:SetAnimationInterval(200) end }
            } },
            { Caption = "Confirm Destructive Actions",
              Checked = function() return settings.ConfirmDestructiveActions end,
              OnClick = function() self:SetConfirmDestructiveActions(not settings.ConfirmDestructiveActions) end },
            { Caption = "Include Unnamed Elements",
              Checked = function() return settings.Structures.IncludeUnnamed end,
              OnClick = function() self:SetIncludeUnnamed(not settings.Structures.IncludeUnnamed) end },
            "-",
            { Caption = "Reset Caption Animation",
              OnClick = function() self.Menu:StartTicker() end }
        } },
        { Caption = "About", Icon = "About",
          OnClick = function() self:About() end }
    }
end

function Host:Install()
    return self.Menu:Install(self:MenuSpec())
end

function Host:Uninstall()
    return self.Menu:Remove()
end

--- Rebuilds the menu. What Cheat Engine calls when it rebuilds its own.
function Host:Reinstall()
    self:Uninstall()
    return self:Install()
end

--------------------------------------------------------
--                       Settings                     --
--------------------------------------------------------

function Host:SetAnimatedCaption(enabled)
    self.Settings:Set("AnimatedCaption", enabled == true)
    self.Menu:StartTicker()
    self.Menu:RefreshChecks()
    return self.Settings.AnimatedCaption
end

function Host:SetAnimationInterval(milliseconds)
    self.Settings:Set("AnimationInterval", milliseconds)
    self.Menu:StartTicker()
    self.Menu:RefreshChecks()
    return self.Settings.AnimationInterval
end

function Host:SetConfirmDestructiveActions(enabled)
    self.Settings:Set("ConfirmDestructiveActions", enabled == true)
    self.Menu:RefreshChecks()
    return self.Settings.ConfirmDestructiveActions
end

--
--- ∑ Whether Generate Structure Records creates a record for every element or
---   only for the ones labelled in Structure Dissect.
--- @param enabled boolean
--- @return boolean
--
function Host:SetIncludeUnnamed(enabled)
    self.Settings:Set("Structures.IncludeUnnamed", enabled == true)
    self.Menu:RefreshChecks()
    return self.Settings.Structures.IncludeUnnamed
end

--------------------------------------------------------
--                        Actions                     --
--------------------------------------------------------

function Host:GenerateStructureRecords() return self.Structures:Generate() end
function Host:RemoveAllStructures() return self.Structures:RemoveAll() end
function Host:DeactivateScripts() return self.Records:Deactivate(true) end
function Host:DeactivateEverything() return self.Records:Deactivate(false) end
function Host:NormalizeIDs() return self.Records:NormalizeIDs() end
function Host:ToggleCompactMode() return self.Shell:ToggleCompactMode() end
function Host:SetCompactMode(enabled) return self.Shell:SetCompactMode(enabled == true) end
function Host:OpenLuaEngine() return self.Shell:OpenLuaEngine() end
function Host:OpenMemoryViewer() return self.Shell:OpenMemoryViewer() end
function Host:OpenStructureDissect() return self.Shell:OpenStructureDissect() end
function Host:OpenTableFiles() return self.Shell:OpenTableFiles() end
function Host:OpenLogConsole() return self.Shell:OpenLogConsole() end
function Host:OpenAutorunFolder() return self.Shell:OpenAutorunFolder() end
function Host:OpenProcessFolder() return self.Shell:OpenProcessFolder() end

--------------------------------------------------------
--                       Lifecycle                    --
--------------------------------------------------------

--
--- ∑ What About shows and what a diagnostic wants to know.
--- @return table
--
function Host:Status()
    return {
        Version = Version.Full(),
        Menu = self.Menu:Installed(),
        Icons = self.Icons.Loaded and "loaded" or (self.Icons.Reason or "not loaded"),
        IconsMissing = self.Icons.Missing or {},
        Logger = self.Log:Attached(),
        Settings = self.Settings:Summary(),
        Compact = self.Shell:IsCompact()
    }
end

--
--- ∑ Rows for the status block, shared by About and the startup line.
--- @return table
--
function Host:StatusRows()
    local status = self:Status()
    local icons = status.Icons
    if #status.IconsMissing > 0 then
        icons = icons .. ", missing: " .. table.concat(status.IconsMissing, ", ")
    end
    return {
        { "Menu", status.Menu and "installed" or "not installed" },
        { "Icons", icons },
        { "Logger", status.Logger and "Manifold Logger" or "print fallback" },
        { "Animate caption", string.format("%s (%d ms)", tostring(status.Settings.AnimatedCaption),
            status.Settings.AnimationInterval) },
        { "Confirm destructive", tostring(status.Settings.ConfirmDestructiveActions) },
        { "Structure records", status.Settings.IncludeUnnamed and "every element" or "labelled elements only" },
        { "Settings", status.Settings.Persist and "persisted in the registry" or "session only" },
        "",
        "ManifoldCEUtility:Status() returns this as a table.",
        "ManifoldCEUtility:Reinstall() rebuilds the menu."
    }
end

--
--- ∑ Logs the status block and makes sure it can be seen: the Logger's
---   console when lines go there, a message box otherwise.
--- @return string
--
function Host:About()
    local text = self.Log:Block(Version.Full(), self:StatusRows())
    self.Log:Info(text)
    local logger = rawget(_G, "ManifoldLogger")
    if self.Log:Attached() and type(logger) == "table" and type(logger.Open) == "function" then
        pcall(logger.Open, logger)
    else
        local dialog = rawget(_G, "messageDialog")
        if type(dialog) == "function" then
            self.CE:RunInMain(function() dialog(text) end)
        end
    end
    return text
end

--
--- ∑ Takes everything down and releases the published names. The next
---   execution of the entry point then starts cold.
--- @return nil
--
function Host:Shutdown()
    self:Uninstall()
    self.Icons:Destroy()
    if rawget(_G, Host.GlobalKey) == self then _G[Host.GlobalKey] = nil end
    if rawget(_G, Host.FacadeKey) == self then _G[Host.FacadeKey] = nil end
end

return Host
