--[[
    The host. One log, one console, one public name.

    Every other module in this tree can be built more than once. The log
    cannot. A second log would leave every channel handed out earlier writing
    into a buffer no window shows, so the host lives in a _G slot rather than
    in this chunk, which is re-executed on every reload.

    Build order:

      Log      the record buffer, channels and sinks   (Core)
      Writer   the rotating file on disk               (File)
      Icons    the shared 16x16 set                    (Icons)
      Theme    the palette and the control factory     (Theme)
      Bridge   the taps onto other producers           (Bridge)
      Console  the window, built lazily on first Open  (Console)

    The console is last and lazy. Logging works with no window at all, so
    nothing builds one until somebody calls Open.

    Published under two names, both the same object: ManifoldLogger, the
    facade below, and ManifoldLoggerHost, the name other Manifold segments
    use for a host.

    A consumer needs only this. Nil-safe, no require, no load order.

        local log = ManifoldLogger and ManifoldLogger:Channel("MyTool")
        if log then log:Info("here") end
]]

local Core    = require("Manifold-Logger-Core")
local Format  = require("Manifold-Logger-Format")
local File    = require("Manifold-Logger-File")
local Icons   = require("Manifold-Logger-Icons")
local Theme   = require("Manifold-Logger-Theme")
local Bridge  = require("Manifold-Logger-Bridge")
local Console = require("Manifold-Logger-Console")
local Version = require("Manifold-Logger-Version")

local Host = {}
Host.__index = Host

Host.MenuTag = 1297374300   -- "Manifold" marker, one past the Template Loader's

--- The _G slot the host publishes itself under. Named here, not only in the
--- entry point, so Shutdown releases exactly what the entry point looks for.
Host.GlobalKey = "ManifoldLoggerHost"
Host.FacadeKey = "ManifoldLogger"

Host.Defaults = {
    Name        = "Manifold",
    Level       = "INFO",       -- what reaches the sinks
    Capacity    = 5000,
    Dedup       = true,         -- collapse an immediately repeated message
    Throttle    = true,         -- bound a burst of different messages
    ThrottleBurst = 200,
    ThrottleRate  = 100,
    FileLogging = true,
    FileLevel   = "TRACE",      -- the file is the archive, keep everything
    FileMode    = "text",       -- or "jsonl"
    PrintSink   = false,        -- mirror into the Lua Engine window
    InstallMenu = true,
    AutoBridge  = true,         -- tap Manifold.Logger / Template Loader if present
    -- Autorun runs at Cheat Engine start. A Cheat Table's logger appears
    -- minutes later and is rebuilt for every table opened after that, so
    -- without the watch AutoBridge attaches to nothing and stays there.
    -- See Manifold-Logger-Bridge:Watch.
    WatchTable  = true,
    WatchInterval = 750         -- ms between polls
}

--------------------------------------------------------
--                    Construction                    --
--------------------------------------------------------

--
--- ∑ Builds the host and everything that does not need a window.
--- @param options table|nil # Any key from Host.Defaults, plus Root for the
---        icon folder (tests) and Directory for the log folder.
--- @return table
--
function Host:New(options)
    options = options or {}
    local settings = {}
    for key, value in pairs(Host.Defaults) do settings[key] = value end
    for key, value in pairs(options) do settings[key] = value end

    local instance = setmetatable({
        Settings = settings,
        Version = Version,
        Console = nil,
        Menu = nil,
        Started = os.time()
    }, Host)

    instance.Log = Core:New({
        Name = settings.Name,
        Level = settings.Level,
        Capacity = settings.Capacity,
        Channel = settings.Name,
        Dedup = settings.Dedup,
        Throttle = settings.Throttle,
        ThrottleBurst = settings.ThrottleBurst,
        ThrottleRate = settings.ThrottleRate,
        -- getTickCount supplies the millisecond stamp and the monotonic order.
        -- Without it the log still works, to the second.
        Ticks = rawget(_G, "getTickCount")
    })
    instance.Default = instance.Log:Channel(settings.Name)
    instance.Icons = Icons:New({ Root = settings.Root })
    instance.Theme = Theme:New({ Icons = instance.Icons })
    instance.Bridge = Bridge:New(instance.Log)

    if settings.FileLogging then instance:EnableFileLogging(true) end
    if settings.PrintSink then instance.Bridge:AttachPrintSink({ Render = function(record)
        return Format.Line(record)
    end }) end
    if settings.AutoBridge then instance.Bridge:AttachAvailable({ Print = false }) end
    if settings.WatchTable then
        instance.Bridge:Watch({ Interval = settings.WatchInterval })
    end

    return instance
end

--
--- ∑ Applies settings to a host that already exists, which is what a reload
---   of the autorun file does. Only the keys given are touched.
--- @param options table
--- @return table # self
--
function Host:Configure(options)
    options = options or {}
    for key, value in pairs(options) do self.Settings[key] = value end
    if options.Level then self.Log:SetLevel(options.Level) end
    if options.Capacity then self.Log:SetCapacity(options.Capacity) end
    -- Flood control is live state on the log, not a stored setting. A
    -- Configure that only wrote to Settings would change nothing.
    if options.Dedup ~= nil then self.Log.Dedup = options.Dedup ~= false end
    if options.Throttle ~= nil then self.Log.Throttle = options.Throttle ~= false end
    if options.ThrottleBurst then self.Log.ThrottleBurst = tonumber(options.ThrottleBurst) end
    if options.ThrottleRate then self.Log.ThrottleRate = tonumber(options.ThrottleRate) end
    -- The file sink carries its own mode and level, so a change to either
    -- needs the sink rebuilt, not re-flagged.
    if options.FileLogging ~= nil then
        self:EnableFileLogging(options.FileLogging)
    elseif (options.FileMode or options.FileLevel) and self.Settings.FileLogging then
        self:EnableFileLogging(true)
    end
    if options.PrintSink ~= nil then
        if options.PrintSink then
            self.Bridge:AttachPrintSink({ Render = function(record) return Format.Line(record) end })
        else
            self.Bridge:DetachPrintSink()
        end
    end
    if options.InstallMenu ~= nil then
        if options.InstallMenu then self:InstallMenu() else self:RemoveMenu() end
    end
    if options.WatchTable ~= nil then
        if options.WatchTable then
            self.Bridge:Watch({ Interval = self.Settings.WatchInterval })
        else
            self.Bridge:Unwatch()
        end
    end
    return self
end

--------------------------------------------------------
--                     File logging                   --
--------------------------------------------------------

--
--- ∑ Turns the log file on or off, building the writer on first use.
--- @param enabled boolean
--- @return boolean
--
function Host:EnableFileLogging(enabled)
    if not enabled then
        self.Log:RemoveSink("file")
        self.Settings.FileLogging = false
        return true
    end
    if not self.Writer then
        self.Writer = File.NewWriter({
            Directory = self.Settings.Directory,
            FileName = self.Settings.FileName,
            Header = function()
                return string.format("\n=== %s  %s  session start ===",
                    Version.Full(), os.date("%Y-%m-%d %H:%M:%S"))
            end
        })
    end
    local mode = self.Settings.FileMode
    self.Log:AddSink("file", File.NewSink(self.Writer, {
        Level = self.Settings.FileLevel,
        Mode = mode,
        Render = function(record, activeMode)
            if activeMode == "jsonl" then return Format.JsonRecord(record) end
            -- Indented so a block or a traceback stays visibly attached to
            -- the line it belongs to when the file is read in an editor.
            return Format.Indent(Format.Line(record, { Date = false }))
        end
    }))
    self.Settings.FileLogging = true
    -- A console built before file logging was switched on holds a nil writer,
    -- so its open log file actions and its status bar would stay blank.
    if self.Console then self.Console.Writer = self.Writer end
    return true
end

--------------------------------------------------------
--                      The window                    --
--------------------------------------------------------

function Host:GetConsole()
    if not self.Console then
        self.Console = Console:New({
            Log = self.Log, Theme = self.Theme,
            Icons = self.Icons, Writer = self.Writer
        })
    end
    return self.Console
end

function Host:Open() return self:GetConsole():Open() end
function Host:Close() if self.Console then self.Console:Close() end end
function Host:Toggle() return self:GetConsole():Toggle() end
function Host:IsOpen() return self.Console ~= nil and self.Console:IsOpen() end

--------------------------------------------------------
--                      Channels                      --
--------------------------------------------------------

--
--- ∑ A named channel. This is the entire public contract for a producer.
--- @param name string
--- @param fields table|nil # Merged into every record from this channel.
--- @return table
--
function Host:Channel(name, fields)
    return self.Log:Channel(name, fields)
end

function Host:SetLevel(level) return self.Log:SetLevel(level) end
function Host:GetLevel() return self.Log:GetLevelName() end
function Host:Clear() self.Log:Clear() end
function Host:Records(filter) return self.Log:Snapshot(filter) end
function Host:Stats() return self.Log:GetStats() end

--
--- ∑ Forwards the level helpers onto the host's own channel, so
---   ManifoldLogger:Warning("...") works without asking for a channel first.
---   Same four shapes Core generates.
--
for _, level in ipairs(Core.Order) do
    local title = level:sub(1, 1):upper() .. level:sub(2):lower()
    Host[title] = function(self, message, fields) return self.Default[title](self.Default, message, fields) end
    Host[title .. "F"] = function(self, format, ...) return self.Default[title .. "F"](self.Default, format, ...) end
    Host["Force" .. title] = function(self, message, fields)
        return self.Default["Force" .. title](self.Default, message, fields)
    end
    Host["Force" .. title .. "F"] = function(self, format, ...)
        return self.Default["Force" .. title .. "F"](self.Default, format, ...)
    end
end

function Host:Emit(level, message, fields, options) return self.Log:Emit(level, message, fields, options) end
function Host:Event(name, fields, options) return self.Default:Event(name, fields, options) end
function Host:Scope(label, options) return self.Default:Scope(label, options) end
function Host:Catch(fn, label, options) return self.Default:Catch(fn, label, options) end
function Host:Check(condition, message, fields) return self.Default:Check(condition, message, fields) end
function Host:Block(title, rows, options) return Format.Block(title, rows, options) end

--------------------------------------------------------
--                        Menu                        --
--------------------------------------------------------

--
--- ∑ Adds a Manifold Logger entry to Cheat Engine's main menu.
---
---   Contributed, not assumed. The Manifold CE Utility owns the Manifold
---   top-level menu when it is installed, so a second entry beside it is
---   noise. Opt out with InstallMenu = false and let the CE Utility call
---   ManifoldLogger:Open() from its own menu.
---
---   Every item created here carries Host.MenuTag, so RemoveMenu takes back
---   exactly its own and a reload replaces rather than duplicates.
--- @return boolean, string|nil
--
function Host:InstallMenu()
    if self.Menu then return true end
    local getMainForm = rawget(_G, "getMainForm")
    local createMenuItem = rawget(_G, "createMenuItem")
    if type(getMainForm) ~= "function" or type(createMenuItem) ~= "function" then
        return false, "no main form or menu API"
    end
    local mainMenu
    local ok = pcall(function() mainMenu = getMainForm().Menu end)
    if not ok or not mainMenu then return false, "the main menu is not available" end

    local root
    local built = pcall(function()
        root = createMenuItem(mainMenu)
        root.Caption = "[— Manifold Logger —]"
        root.Tag = Host.MenuTag
        mainMenu.Items.add(root)
    end)
    if not built or not root then return false, "could not create the menu item" end
    self.Icons:AttachTo(root)

    local function item(caption, onClick, icon)
        local child
        local made = pcall(function()
            child = createMenuItem(mainMenu)
            child.Caption = caption
            child.Tag = Host.MenuTag
            if onClick then
                child.OnClick = function() pcall(onClick) end
            end
            root.add(child)
        end)
        if made and child and icon then self.Icons:Apply(child, icon) end
        return child
    end

    item("Open Console", function() self:Open() end, "Logging")
    item("-")
    item("Clear Buffer", function() self:Clear() end, "Clear")
    item("Open Log Folder", function()
        local execute = rawget(_G, "shellExecute")
        local status = self.Writer and self.Writer:Status()
        if type(execute) == "function" and status and status.Directory then
            pcall(execute, status.Directory)
        end
    end, "Folder")
    item("-")
    item("Capture print()", function()
        if self.Bridge:IsAttached("print") then
            self.Bridge:DetachPrint()
            self:Info("print() capture stopped.")
        else
            local ok2, reason = self.Bridge:AttachPrint()
            self:Info(ok2 and "print() is now captured into this log."
                or ("print() capture failed: " .. tostring(reason)))
        end
    end, "Eye")
    item("Session Report", function()
        self:GetConsole():ReportStats()
        self:Open()
    end, "Metrics")

    self.Menu = root
    self.MenuContainer = mainMenu.Items
    return true
end

--
--- ∑ The main menu's item container, resolved fresh. RemoveMenu runs exactly
---   when Cheat Engine may have rebuilt its main menu, the one case where the
---   container captured at install time is a dead handle. Fall back to the
---   captured one only when there is nothing to ask.
--- @return userdata|nil
--
function Host:MenuItems()
    local getMainForm = rawget(_G, "getMainForm")
    if type(getMainForm) == "function" then
        local items
        local ok = pcall(function() items = getMainForm().Menu.Items end)
        if ok and items then
            -- Prove the handle answers before handing it back.
            if pcall(function() return items.Count end) then return items end
        end
    end
    local captured = self.MenuContainer
    if captured and pcall(function() return captured.Count end) then return captured end
    return nil
end

--
--- ∑ Takes the menu entry back out.
---
---   The container is the one captured at install time, not root.Parent.
---   TMenuItem's parent is reachable in Lazarus but not reliably through
---   Cheat Engine's binding, and a walk that finds nothing would leave the
---   item attached. Matching is by Tag, not identity, because two lookups of
---   the same Cheat Engine object need not give the same Lua value.
---
---   TMenuItem.delete only detaches, so items are destroyed afterwards.
---   Destroying the root destroys its children with it.
--- @return boolean
--
function Host:RemoveMenu()
    local root = self.Menu
    local container = self:MenuItems()
    self.Menu, self.MenuContainer = nil, nil
    if not root and not container then return false end
    -- Every tagged item, not just the one still held. An earlier generation
    -- whose root reference was lost would otherwise be unlinked from the menu
    -- and leaked along with its click closures.
    local detached = {}
    if container then
        pcall(function()
            for index = (tonumber(container.Count) or 0) - 1, 0, -1 do
                local child = container.getItem(index)
                if child and child.Tag == Host.MenuTag then
                    container.delete(index)
                    detached[#detached + 1] = child
                end
            end
        end)
    end
    local destroyed = false
    for _, item in ipairs(detached) do
        if item == root then destroyed = true end
        pcall(function() item.destroy() end)
    end
    if root and not destroyed then pcall(function() root.destroy() end) end
    return true
end

--------------------------------------------------------
--                      Lifecycle                     --
--------------------------------------------------------

--
--- ∑ What the console's About block and any diagnostic wants to know.
--- @return table
--
function Host:Status()
    return {
        Version = Version.String(),
        Name = self.Settings.Name,
        Level = self.Log:GetLevelName(),
        Buffered = self.Log.RingCount,
        Capacity = self.Log.Capacity,
        Channels = self.Log:ChannelNames(),
        Bridges = self.Bridge:Names(),
        Watching = self.Bridge.Watcher ~= nil,
        Table = Bridge.TableName(rawget(_G, "logger")),
        Console = self:IsOpen() and "open" or (self.Console and "hidden" or "not built"),
        File = self.Writer and self.Writer:Status() or nil,
        Icons = self.Icons.Loaded and "loaded" or (self.Icons.Reason or "not loaded"),
        Uptime = os.time() - self.Started
    }
end

--
--- ∑ Throws the window away. The next Open rebuilds it, picking up a theme
---   change or a new icon set. The log itself survives a reload.
--- @return nil
--
function Host:ReloadConsole()
    if self.Console then
        self.Console:Destroy()
        self.Console = nil
    end
    self.Icons:Invalidate()
end

--
--- ∑ Full teardown. Detaches every bridge, closes the file and destroys the
---   window, so nothing survives pointing at a dead generation.
--- @return nil
--
function Host:Shutdown()
    self:RemoveMenu()
    self.Bridge:DetachAll()
    if self.Console then
        self.Console:Destroy()
        self.Console = nil
    end
    self:EnableFileLogging(false)
    if self.Writer then
        self.Writer:Close()
        -- The reference goes too. Writer:Status().Enabled is the writer's own
        -- health flag and Close does not clear it, so a status reader would go
        -- on reporting a file nobody is writing.
        self.Writer = nil
    end
    self.Icons:Destroy()
    -- Release the published names LAST. The entry point tells a cold start
    -- from "already running" by looking at them, so a shut-down host left in
    -- place makes the documented rebuild impossible. Guarded by identity, so
    -- an older generation cannot unpublish a newer one.
    if rawget(_G, Host.GlobalKey) == self then
        rawset(_G, Host.GlobalKey, nil)
        rawset(_G, Host.FacadeKey, nil)
    end
end

return Host
