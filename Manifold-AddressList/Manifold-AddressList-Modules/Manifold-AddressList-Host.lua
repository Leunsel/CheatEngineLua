--[[
    The host. Builds every module in dependency order and is the object
    published as ManifoldAddressList.

    Build order, which is also the order a service may depend on another one.

      Version     the number, and nothing else
      Log         the Manifold Logger channel, or a timestamped print
      Settings    defaults, the entry file's overrides, the registry
      CE          the defensive Cheat Engine wrappers
      Icons       the 16x16 set, one image list per Cheat Engine session
      Theme       the Cheat Table's live palette and every themed control
      Records     the structure walk, the detail passes and the query language
      Properties  the schema, the bulk read and the bulk write
      Journal     undo and redo
      Checker     the table check
      Search      find and replace
      Exporter    writing a selection out
      Window      the controller, and the only writer in the segment

    Two services are held under a different name than their module. Lint and
    Export are facade methods here, so a field of the same name would shadow
    the method and a call would try to call a service table instead. The
    SigMaker host holds its finder the same way and for the same reason.

    The journal lives here rather than in the window, so undoing survives
    closing the window and reopening it. Everything else the window owns goes
    away with the form.

    What Uninstall means here. This segment registers no menu of its own, the
    Cheat Engine Utility carries the entry, so there is nothing to remove.
    Uninstall closes the window, stops both timers, destroys the surfaces, the
    tree, the inspector and the form, and destroys the icons. The entry file
    calls it on the previous generation before it drops the modules, because
    the icon set keeps its image list in a module local upvalue and dropping
    the module would orphan a live TImageList. Shutdown is Uninstall plus
    releasing both published globals by identity.

    Everything the window does is also a method here, so a Cheat Table's own
    Lua script can do the same work with no window on screen.

        ManifoldAddressList:Open()
        ManifoldAddressList:Lint()
        ManifoldAddressList:Find("health")
        ManifoldAddressList:Export("C:\\table.json")
        ManifoldAddressList:Status()

    The headless calls read the address list again before they run, so a script
    that just added records does not work from a tree that predates them. They
    write through the same window object the on screen one uses, which is what
    keeps one commit funnel and one undo history whether or not a form exists.
]]

local Version     = require("Manifold-AddressList-Version")
local Log         = require("Manifold-AddressList-Log")
local Settings    = require("Manifold-AddressList-Settings")
local CE          = require("Manifold-AddressList-CE")
local Icons       = require("Manifold-AddressList-Icons")
local Theme       = require("Manifold-AddressList-Theme")
local Types       = require("Manifold-AddressList-Types")
local Records     = require("Manifold-AddressList-Records")
local Properties  = require("Manifold-AddressList-Properties")
local Journal     = require("Manifold-AddressList-Journal")
local Lint        = require("Manifold-AddressList-Lint")
local Search      = require("Manifold-AddressList-Search")
local Export      = require("Manifold-AddressList-Export")
local Surface     = require("Manifold-AddressList-Surface")
local Tree        = require("Manifold-AddressList-Tree")
local Results     = require("Manifold-AddressList-Results")
local Grid        = require("Manifold-AddressList-Grid")
local Pointer     = require("Manifold-AddressList-Pointer")
local ScriptPage  = require("Manifold-AddressList-Script")
local DropDown    = require("Manifold-AddressList-DropDown")
local HotkeysPage = require("Manifold-AddressList-Hotkeys")
local Inspector   = require("Manifold-AddressList-Inspector")
local Window      = require("Manifold-AddressList-Window")

local Host = {}
Host.__index = Host

--- The _G slots the entry file publishes under. Named here so Shutdown
--- releases exactly what the entry file looked for.
Host.GlobalKey = "ManifoldAddressListHost"
Host.FacadeKey = "ManifoldAddressList"

--
--- ∑ The Cheat Engine globals this segment degrades around, and what each one
---   costs when the build does not have it. The diagnostics block is the only
---   place a person can find out why a feature is quietly not there.
--
Host.Probes = {
    { Name = "createPaintBox",          Costs = "the canvases fall back to an image" },
    { Name = "createSynEdit",           Costs = "the script page falls back to a memo" },
    { Name = "createTimer",             Costs = "the window only reads on F5" },
    { Name = "getSettings",             Costs = "nothing is remembered between sessions" },
    { Name = "messageDialog",           Costs = "anything that asks first is refused" },
    { Name = "createSaveDialog",        Costs = "an export needs its path in the call" },
    { Name = "createColorDialog",       Costs = "the colour of a record cannot be picked" },
    { Name = "autoAssembleCheck",       Costs = "scripts are never checked" },
    { Name = "getAddressSafe",          Costs = "an address is never resolved to a number" },
    { Name = "readPointer",             Costs = "a pointer chain shows no levels" },
    { Name = "convertKeyComboToString", Costs = "hotkeys are spelled out locally" },
    { Name = "getMemoryViewForm",       Costs = "Show in memory view does nothing" }
}

--------------------------------------------------------
--                      Helpers                       --
--------------------------------------------------------

--- Sends one line to the channel. The host never raises out of a facade call,
--- because the Cheat Engine Utility reaches Open through a pcall and a Cheat
--- Table script reaches the rest of these with no guard at all.
local function say(self, level, message)
    local sink = self and self.Log
    if sink == nil then return end
    local method = sink[level]
    if type(method) ~= "function" then return end
    pcall(method, sink, message)
end

--
--- ∑ Runs one facade call with the defect kept out of the caller.
--- @param self table
--- @param what string # What was being done, in the words a person reads.
--- @param fn function
--- @return any ... # Whatever fn answered, or nothing when it raised.
--
local function guarded(self, what, fn)
    local results = table.pack(pcall(fn))
    if results[1] then return table.unpack(results, 2, results.n) end
    say(self, "Error", what .. " failed. " .. tostring(results[2]))
    return nil
end

--
--- ∑ Runs something that pops a dialog with the window's timers held off.
---
---   A modal runs a nested message loop, so the frame timer and the sync timer
---   both keep firing underneath it. The window counts that itself and the
---   host has no counter of its own, so anything modal here goes through the
---   window's gate whether or not a form is on screen.
--- @param self table
--- @param fn function
--- @return any
--
local function modal(self, fn)
    local window = self.Window
    if window ~= nil and type(window.Guard) == "function" then
        return window:Guard(fn)
    end
    return (pcall(fn))
end

--- A boolean that falls back to another one when the caller said nothing.
local function pick(value, fallback)
    if value == nil then return fallback == true end
    return value == true
end

--- A list of ids as a set, which is the shape the search and the check take.
local function idSet(ids)
    if type(ids) ~= "table" then return nil end
    local set = {}
    for _, id in ipairs(ids) do set[id] = true end
    for id, value in pairs(ids) do
        if value == true and type(id) == "number" then set[id] = true end
    end
    if next(set) == nil then return nil end
    return set
end

--- The severities of a list of problems, counted. The window's own check does
--- not hand its statistics back, so this is how a facade call still answers
--- the same shape whether or not a window was on screen. A problem carries the
--- lowercase word the checker wrote into it, so these compare against that and
--- not against a capitalised one, which would count every problem as a note.
local function statsOf(problems, checked, took)
    local stats = { Checked = checked or 0, Errors = 0, Warnings = 0, Infos = 0, Took = took or 0 }
    for _, problem in ipairs(problems or {}) do
        if problem.Severity == "error" then stats.Errors = stats.Errors + 1
        elseif problem.Severity == "warning" then stats.Warnings = stats.Warnings + 1
        else stats.Infos = stats.Infos + 1 end
    end
    return stats
end

--------------------------------------------------------
--                    Construction                    --
--------------------------------------------------------

--
--- ∑ Builds the host and everything under it. Nothing touches Cheat Engine
---   until a facade call asks it to, so this is safe at autorun time with no
---   Cheat Table loaded and no process attached.
--- @param options table|nil # Settings overrides, Persist, Root for the icon
---        folder and Print for the fallback log sink.
--- @return table
--
function Host:New(options)
    options = options or {}
    local log = Log:New({ Print = options.Print })
    local settings = Settings:New({ Overrides = options.Settings, Persist = options.Persist })
    local ce = CE:New({ Log = log })
    local icons = Icons:New({ Root = options.Root })
    local theme = Theme:New({ Log = log, Icons = icons })
    local records = Records:New({ CE = ce, Types = Types, Log = log })
    local properties = Properties:New({ CE = ce, Types = Types, Log = log })
    local journal = Journal:New({ Log = log })

    local instance = setmetatable({
        Version = Version,
        Types = Types,
        Log = log,
        Settings = settings,
        CE = ce,
        Icons = icons,
        Theme = theme,
        Records = records,
        Properties = properties,
        Journal = journal,

        -- Lint and Export are method names on this table, so the two services
        -- are held under a name that cannot shadow them.
        Checker = nil,
        Search = nil,
        Exporter = nil,

        Window = nil,
        Started = os.time()
    }, Host)

    instance.Checker = Lint:New({ CE = ce, Records = records, Properties = properties,
        Types = Types, Log = log })
    instance.Search = Search:New({ Records = records, Properties = properties,
        Types = Types, Log = log })
    instance.Exporter = Export:New({ Records = records, Properties = properties,
        Types = Types, Log = log })

    instance.Window = Window:New({
        Theme = theme, Icons = icons, Log = log, Settings = settings, CE = ce,
        Types = Types, Records = records, Properties = properties, Journal = journal,
        Lint = instance.Checker, Search = instance.Search, Export = instance.Exporter,
        Version = Version,
        Surface = Surface, Tree = Tree, Results = Results, Grid = Grid,
        Inspector = Inspector,
        Pages = { Pointer = Pointer, Script = ScriptPage,
                  DropDown = DropDown, Hotkeys = HotkeysPage }
    })
    return instance
end

--------------------------------------------------------
--                      The window                    --
--------------------------------------------------------

--
--- ∑ Opens the window, building it on first use. This is the whole contract
---   the Cheat Engine Utility's menu entry uses, which reaches a global table
---   and calls Open on it as a method.
--- @return boolean
--
function Host:Open()
    return guarded(self, "Opening the Address List", function()
        return self.Window:Open()
    end) == true
end

--- Asks the window to close. A page holding an unsaved edit can refuse, which
--- is why this answers whether it actually closed.
function Host:Close()
    return guarded(self, "Closing the Address List", function()
        return self.Window:Close()
    end) == true
end

--- Open when it is closed and closed when it is open.
function Host:Toggle()
    if self:IsOpen() then return self:Close() end
    return self:Open()
end

function Host:IsOpen()
    return guarded(self, "Reading the Address List state", function()
        return self.Window:IsOpen()
    end) == true
end

--
--- ∑ Selects records in the window, which is what a Cheat Table script uses to
---   point the window at what it just built.
--- @param ids table # A list of record ids.
--- @return boolean
--
function Host:Select(ids)
    return guarded(self, "Selecting records", function()
        return self.Window:Select(ids)
    end) == true
end

--
--- ∑ The ids the next action would touch. With no window on screen there is no
---   selection of our own, so Cheat Engine's own selected records answer
---   instead and a script can pass them straight back into Export.
--- @return table # A list of ids, empty when nothing is selected.
--
function Host:Selected()
    local ids = guarded(self, "Reading the selection", function()
        if self.Window:IsOpen() then return self.Window:SelectedIDs() end
        return self.CE:SelectedRecordIDs()
    end)
    return type(ids) == "table" and ids or {}
end

--------------------------------------------------------
--                 Working without a window           --
--------------------------------------------------------

--
--- ∑ A snapshot of the address list with every node read.
---
---   The window is the one thing that owns a snapshot, open or not, so a
---   headless call asks it to read again rather than keeping a second tree
---   nobody keeps up to date. A full read is what the checks, the search and
---   the export all need anyway.
--- @return table|nil
--
function Host:Snapshot()
    local window = self.Window
    if window == nil then return nil end
    guarded(self, "Reading the address list", function() window:Sync(true) end)
    return window.Snapshot
end

--
--- ∑ Checks the table and reports what is wrong with it.
---
---   With the window open and nothing overridden this runs the window's own
---   check, so the results strip and the markers in the tree agree with what
---   comes back. The window reads its choices from the settings, so a call
---   that overrides one of them runs the checker directly instead and leaves
---   what is on screen alone. The window does not hand its own statistics
---   over, so those are counted here.
--- @param options table|nil # ReadValues, Assemble and IDs, defaulting to the
---        settings and to the whole table.
--- @return table, table # The problems in pre-order, and the statistics.
--
function Host:Lint(options)
    options = options or {}
    local window = self.Window
    local lint = self.Settings.Lint or {}
    local started = os.clock()

    if self:IsOpen() and options.IDs == nil
        and options.ReadValues == nil and options.Assemble == nil then
        local problems = guarded(self, "Checking the table", function()
            return window:RunProblems()
        end) or {}
        local count = window.Snapshot and window.Snapshot.Count or 0
        return problems, statsOf(problems, count, (os.clock() - started) * 1000)
    end

    local snapshot = self:Snapshot()
    if snapshot == nil then return {}, statsOf({}, 0, 0) end
    local problems, stats = guarded(self, "Checking the table", function()
        return self.Checker:Run(snapshot, {
            ReadValues = pick(options.ReadValues, lint.ReadValues),
            Assemble = pick(options.Assemble, lint.Assemble),
            IDs = idSet(options.IDs)
        })
    end)
    problems = problems or {}
    return problems, stats or statsOf(problems, snapshot.Count, 0)
end

--
--- ∑ What the find bar would have looked for, so a call from the Lua console
---   and a click in the window search the same fields the same way.
--- @param options table|string|nil # A bare string is the needle.
--- @return table
--
function Host:SearchOptions(options)
    if type(options) == "string" then options = { Needle = options } end
    options = options or {}
    local search = self.Settings.Search or {}
    local fields = options.Fields
    if type(fields) ~= "table" then
        fields = {}
        if search.Description ~= false then fields.Description = true end
        if search.Script ~= false then fields.Script = true end
        if search.DropDown == true then fields.DropDown = true end
    end
    return {
        Needle = tostring(options.Needle or ""),
        Replacement = options.Replacement,
        Fields = fields,
        MatchCase = pick(options.MatchCase, search.MatchCase),
        WholeWord = pick(options.WholeWord, search.WholeWord),
        IDs = idSet(options.IDs)
    }
end

--
--- ∑ Every match in the table, one entry per match. Nothing is written and
---   nothing is shown, so this is the call a script uses to find out whether
---   something is there at all.
--- @param options table|string # Needle, Replacement, Fields, MatchCase,
---        WholeWord and IDs. A bare string is the needle.
--- @return table # The hits.
--
function Host:Find(options)
    local wanted = self:SearchOptions(options)
    if wanted.Needle == "" then
        say(self, "Warning", "Find needs something to look for.")
        return {}
    end
    local snapshot = self:Snapshot()
    if snapshot == nil then return {} end
    local hits = guarded(self, "Finding '" .. wanted.Needle .. "'", function()
        return self.Search:Hits(snapshot, wanted)
    end)
    return type(hits) == "table" and hits or {}
end

--
--- ∑ Replaces every match in one transaction, so four hundred renames are one
---   undo entry.
---
---   The write goes through the window's commit funnel whether or not a form
---   exists, because that funnel is the only writer in the segment and the
---   journal it pushes to is this host's. A closed window simply has no tree
---   and no inspector to refresh afterwards.
--- @param options table # Needle, Replacement, Fields, MatchCase, WholeWord
---        and IDs.
--- @return number, table # How many fields were written, and the fields that
---         were refused with a sentence saying why.
--
function Host:Replace(options)
    local wanted = self:SearchOptions(options)
    if wanted.Needle == "" then
        say(self, "Warning", "Replace needs something to look for.")
        return 0, {}
    end
    wanted.Replacement = wanted.Replacement == nil and "" or tostring(wanted.Replacement)
    local snapshot = self:Snapshot()
    if snapshot == nil then return 0, {} end

    local window = self.Window
    local plan, skipped = guarded(self, "Planning a replacement", function()
        return self.Search:Plan(snapshot, wanted)
    end)
    plan, skipped = plan or {}, skipped or {}
    if #plan == 0 then return 0, skipped end

    local changes = {}
    for _, entry in ipairs(plan) do
        local change = window:ChangeForField(entry)
        if change ~= nil then changes[#changes + 1] = change end
    end
    local label = "Replace '" .. wanted.Needle .. "' in " .. #changes
        .. " field" .. (#changes == 1 and "" or "s")
    local ok, applied = window:Commit({ Label = label, Changes = changes })
    return (ok and applied) or 0, skipped
end

--
--- ∑ Writes a selection out to a file. The ending of the path picks the
---   format, so a name ending in csv is a csv and anything unrecognised is an
---   outline rather than a refusal.
--- @param path string # Where to write.
--- @param options table|nil # IDs, IncludeScripts, IncludeValues,
---        IncludeChildren and Format, defaulting to the settings and to every
---        root record.
--- @return boolean, string|nil
--
function Host:Export(path, options)
    if type(path) ~= "string" or path == "" then
        return false, "There is no file name to export to."
    end
    options = options or {}
    local snapshot = self:Snapshot()
    if snapshot == nil then return false, "The address list could not be read." end
    local defaults = self.Settings.Export or {}
    local ids = options.IDs
    if type(ids) ~= "table" or next(ids) == nil then ids = snapshot.Roots end

    local text, detail = guarded(self, "Exporting records", function()
        local items = self.Exporter:Collect(snapshot, ids, {
            IncludeScripts = pick(options.IncludeScripts, defaults.IncludeScripts ~= false),
            IncludeValues = pick(options.IncludeValues, defaults.IncludeValues),
            IncludeChildren = pick(options.IncludeChildren, defaults.IncludeChildren ~= false)
        })
        if #items == 0 then return nil, "There is nothing to export." end
        -- The second value is the format on the way out and the reason on the
        -- way out empty handed, because only one of the two can happen.
        local format = options.Format or Export.FormatFor(path) or "json"
        return self.Exporter:Build(items, format), format
    end)
    if type(text) ~= "string" then
        return false, detail or "The export could not be built."
    end

    local ok, failure = self.Exporter:Write(path, text)
    if not ok then
        say(self, "Warning", "Export to " .. path .. " failed. " .. tostring(failure))
        return false, failure
    end
    local log = self.Log
    if log ~= nil then
        pcall(function()
            log:Info(log:Block("Exported the address list", {
                { "Format", detail or "json" }, { "File", path }, { "Bytes", #text }
            }))
        end)
    end
    return true
end

--- Puts the last transaction back. The journal writes through the same
--- appliers the edit used, so an undo is exactly as guarded as the edit.
function Host:Undo()
    return guarded(self, "Undoing", function() return self.Window:Undo() end) == true
end

--- Does the last undone transaction again, in the order it was made.
function Host:Redo()
    return guarded(self, "Redoing", function() return self.Window:Redo() end) == true
end

--------------------------------------------------------
--                 Status and diagnostics             --
--------------------------------------------------------

--
--- ∑ What About shows and what a script asks when it wants to know the state
---   of this segment.
---
---   Nothing here reads the whole table. The entry file logs this block at
---   autorun time, where there is usually no Cheat Table and never a process,
---   so the record count comes from Cheat Engine's own count and not from a
---   structure walk.
--- @return table
--
function Host:Status()
    local window = self.Window
    local snapshot = window and window.Snapshot or nil
    local open = self:IsOpen()
    local count = snapshot and snapshot.Count or nil
    if count == nil then
        local read = guarded(self, "Counting the records", function() return self.CE:Count() end)
        count = tonumber(read) or 0
    end
    return {
        Version = Version.Full(),
        Open = open,
        Records = count,
        Selected = #self:Selected(),
        Problems = window and window.Problems and #window.Problems or 0,
        Undo = self.Journal and #self.Journal:Entries() or 0,
        Icons = self.Icons.Loaded and "loaded" or (self.Icons.Reason or "not loaded yet"),
        IconsMissing = self.Icons.Missing or {},
        Logger = self.Log:Attached(),
        Settings = self.Settings:Summary()
    }
end

--
--- ∑ Rows for the status block, shared by About and by the line the entry file
---   logs at startup.
--- @return table
--
function Host:StatusRows()
    local status = self:Status()
    local settings = status.Settings
    local icons = status.Icons
    -- Only the count here. Nineteen file names on one row would push every
    -- other row off the side of the console, and Diagnostics names them.
    if #status.IconsMissing > 0 then
        icons = icons .. ", " .. #status.IconsMissing .. " file"
            .. (#status.IconsMissing == 1 and "" or "s") .. " missing"
    end
    return {
        { "Authors", Version.Authors() },
        { "Window", status.Open and "open" or "not open" },
        { "Records", status.Records },
        { "Undo history", status.Undo .. " entr" .. (status.Undo == 1 and "y" or "ies") },
        { "Icons", icons },
        { "Logger", status.Logger and "Manifold Logger" or "print fallback" },
        { "Live sync", settings.LiveSync
            and ("on, every " .. settings.SyncInterval .. " ms") or "off" },
        { "Columns", (settings.ShowValues and "values" or "no values") .. ", "
            .. (settings.ShowAddresses and "addresses" or "no addresses") },
        { "Settings", settings.Persist and "persisted in the registry" or "session only" },
        "",
        "ManifoldAddressList:Open() opens the window.",
        "ManifoldAddressList:Lint() checks the table and reports what is wrong.",
        "ManifoldAddressList:Status() returns this as a table."
    }
end

--
--- ∑ Logs the status block and makes sure it can be seen. The Logger's console
---   when the lines go there, a message box otherwise.
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
            modal(self, function() self.CE:RunInMain(function() dialog(text) end) end)
        end
    end
    return text
end

--
--- ∑ The deeper block. What this Cheat Engine offers, what the icon set found
---   and what the window is doing right now.
---
---   The window logs its own half, because that is the part only it knows and
---   it is the owner of that line. Both halves come back as one string for a
---   caller that wants to put them somewhere else.
--- @return string
--
function Host:Diagnostics()
    local ce, log = self.CE, self.Log
    local rows = {
        { "Version", Version.Full() },
        { "Address list", ce:AddressList() ~= nil and "readable" or "not available" },
        { "Records", tonumber(ce:Count()) or 0 },
        { "Process", ce:ProcessOpen() and "attached" or "none" },
        { "Main thread", ce:InMainThread() and "yes" or "no" },
        { "Icon folder", self.Icons:PathOf("") },
        { "Icons", self.Icons.Loaded and "loaded" or (self.Icons.Reason or "not loaded yet") },
        ""
    }
    for _, missing in ipairs(self.Icons.Missing or {}) do
        rows[#rows + 1] = { "Missing icon", missing }
    end
    if #(self.Icons.Missing or {}) > 0 then rows[#rows + 1] = "" end
    for _, probe in ipairs(Host.Probes) do
        rows[#rows + 1] = { probe.Name,
            ce:Has(probe.Name) and "present" or ("missing, " .. probe.Costs) }
    end

    local text = log and log:Block(Version.Full() .. " diagnostics", rows) or ""
    if log ~= nil then pcall(log.Info, log, text) end

    local window = self.Window
    if window ~= nil and self:IsOpen() then
        local extra = guarded(self, "Reading the window diagnostics", function()
            return window:Diagnostics()
        end)
        if type(extra) == "string" and extra ~= "" then text = text .. "\n\n" .. extra end
    end
    return text
end

--------------------------------------------------------
--                      Lifecycle                     --
--------------------------------------------------------

--
--- ∑ Takes everything this generation built down.
---
---   There is no menu to remove, so this closes the window without asking a
---   page whether it minds, stops both timers, destroys the surfaces and the
---   form and then destroys the icon set. The entry file calls it on the
---   previous generation, where a page that refused to close would leave two
---   generations of code running at once.
--- @return boolean
--
function Host:Uninstall()
    local window = self.Window
    if window ~= nil then pcall(window.Destroy, window) end
    if self.Icons ~= nil then pcall(self.Icons.Destroy, self.Icons) end
    return true
end

--
--- ∑ Uninstall, plus letting the published names go. They are compared by
---   identity, so a newer generation that already took them over keeps them.
--- @return nil
--
function Host:Shutdown()
    self:Uninstall()
    if rawget(_G, Host.GlobalKey) == self then _G[Host.GlobalKey] = nil end
    if rawget(_G, Host.FacadeKey) == self then _G[Host.FacadeKey] = nil end
end

return Host
