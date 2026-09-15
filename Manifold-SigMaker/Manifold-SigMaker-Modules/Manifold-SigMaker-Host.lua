--[[
    The host. Wires the modules together and is the object published as
    ManifoldSigMaker.

    The tool has two halves. One turns an address into a signature, the other
    turns a signature back into an address, and they share everything below
    them: the same wrappers, the same log channel, the same settings and the
    same scanner.

    Build order:

      CE         the defensive API wrappers
      Log        the Manifold Logger channel, or print
      Settings   defaults, overrides, the persisted choices
      Decoder    which bytes of an instruction are operands
      Signature  growing a pattern until it is unique
      Pattern    reading a pasted signature back in
      Finder     scanning for one and reporting what was hit
      Menu       the entries in the memory view

    The finder is held as Finder and not as Find, which every other module is
    named after, because Find is the method that uses it and an instance field
    would shadow it.

    Everything the menu does is a method here, so a table's Lua script or the
    Lua console can do the same work without ever opening the menu:

        ManifoldSigMaker:Make()                  -- the selected address
        ManifoldSigMaker:Make(0x14D762ED9)       -- a given one
        ManifoldSigMaker:Copy()                  -- make and put on the clipboard
        ManifoldSigMaker:Pattern(address)        -- just the scan pattern
        ManifoldSigMaker:Find()                  -- ask, scan, go there
        ManifoldSigMaker:Find("48 8B ? ? ? 66")  -- scan for a given one
        ManifoldSigMaker:Scan(pattern)           -- the addresses, no interface
        ManifoldSigMaker:Goto("game.exe+1A2B")   -- just the memory view
        ManifoldSigMaker:Status()
]]

local CE        = require("Manifold-SigMaker-CE")
local Log       = require("Manifold-SigMaker-Log")
local Settings  = require("Manifold-SigMaker-Settings")
local Decoder   = require("Manifold-SigMaker-Decoder")
local Signature = require("Manifold-SigMaker-Signature")
local Format    = require("Manifold-SigMaker-Format")
local Pattern   = require("Manifold-SigMaker-Pattern")
local Find      = require("Manifold-SigMaker-Find")
local Menu      = require("Manifold-SigMaker-Menu")
local Icons     = require("Manifold-SigMaker-Icons")
local Version   = require("Manifold-SigMaker-Version")

local Host = {}
Host.__index = Host

Host.GlobalKey = "ManifoldSigMakerHost"
Host.FacadeKey = "ManifoldSigMaker"

--- The "Manifold" marker on every menu item this tool creates. The Logger
--- carries 1297374300, the Template Loader 1297374284 and the CE Utility
--- 1297374316, so none of them ever sweeps away another's items.
Host.MenuTag = 1297374332

function Host:New(options)
    options = options or {}
    local ce = CE:New()
    local log = Log:New({ Print = options.Print })
    local settings = Settings:New({ Overrides = options.Settings, Persist = options.Persist })
    local decoder = Decoder:New({ CE = ce, Log = log, Settings = settings })
    local instance = setmetatable({
        CE = ce,
        Log = log,
        Settings = settings,
        Decoder = decoder,
        Version = Version,
        Format = Format,
        Started = os.time(),
        -- The list of hits while one is open, and the place the last one had
        -- when it was closed.
        HitList = nil,
        HitBounds = nil
    }, Host)
    instance.Signature = Signature:New({ CE = ce, Log = log, Settings = settings, Decoder = decoder })
    -- The Pattern module is deliberately not held as a field. Pattern is
    -- already a method here, and an instance field would shadow it. Every
    -- caller inside this file reads it as the upvalue instead.
    instance.Finder = Find:New({ CE = ce, Log = log, Settings = settings })
    instance.Icons = Icons:New({ Root = options.Root })
    instance.Menu = Menu:New({ CE = ce, Log = log, Settings = settings,
        Icons = instance.Icons, MenuTag = Host.MenuTag })
    return instance
end

--------------------------------------------------------
--                        The menu                    --
--------------------------------------------------------

--- The two entries, in the order they are shown.
function Host:MenuSpec()
    local settings = self.Settings
    return {
        {
            Caption = settings.MenuCaption,
            Icon = Icons.Files.Copy,
            OnClick = function() self:Copy() end
        },
        {
            Caption = settings.Find.MenuCaption,
            Icon = Icons.Files.Find,
            Shortcut = settings.Find.Shortcut,
            OnClick = function() self:Find() end
        }
    }
end

function Host:Install()
    return self.Menu:Install(self:MenuSpec())
end

--- Takes the entries down and closes the list of hits. Executing the entry
--- file again calls this on the generation before it, so neither the entries
--- nor a list can outlive the code that made them.
function Host:Uninstall()
    self:CloseHits()
    return self.Menu:Remove()
end

--- Rebuilds the entry. Worth calling after Cheat Engine has rebuilt the
--- memory view form, because the old item went with it. A list of hits that
--- is open stays open, so rebinding the key does not take it away.
function Host:Reinstall()
    self.Menu:Remove()
    return self:Install()
end

--------------------------------------------------------
--                        Actions                     --
--------------------------------------------------------

--
--- ∑ Builds a signature.
--- @param address number|nil # Defaults to the disassembler's selection.
--- @return table|nil, string|nil
--
function Host:Make(address)
    if address == nil then
        local selected, reason = self.CE:SelectedAddress()
        if not selected then
            self.Log:Warning("Copy signature: " .. tostring(reason) .. ".")
            return nil, reason
        end
        address = selected
    end
    local signature, reason = self.Signature:Make(address)
    if not signature then
        self.Log:Warning("Copy signature: " .. tostring(reason) .. ".")
        return nil, reason
    end
    return signature
end

--
--- ∑ Builds a signature and puts the lines named by Output on the clipboard.
--- @param address number|nil
--- @return string|nil, string|nil # The text that was copied.
--
function Host:Copy(address)
    local signature, reason = self:Make(address)
    if not signature then return nil, reason end
    local text, unknown = Format.Compose(signature, self.Settings.Output)
    if unknown then
        self.Log:Warning(string.format(
            "Output: '%s' is not a part name. Known parts are aob, aobq, code, header.", unknown))
    end
    if self.Settings.CopyToClipboard then
        local ok, err = self.CE:Clipboard(text)
        if not ok then self.Log:Warning("Clipboard: " .. tostring(err) .. ".") end
    end
    self.Log:Info(self.Log:Block("Signature", Format.Rows(signature)))
    return text
end

--- Just the scan pattern, for a script that wants to feed AOBScan itself.
--- Remember that AOBScan returns nil when nothing matched, not an empty list.
function Host:Pattern(address)
    local signature, reason = self:Make(address)
    if not signature then return nil, reason end
    return signature.Pattern, signature
end

--------------------------------------------------------
--                    Finding one again               --
--------------------------------------------------------

--
--- ∑ Asks for a signature, offering the clipboard when what is on it reads
---   as one. Only the pattern is offered, because inputQuery is a single
---   line and the three line form of a signature would show its header and
---   hide the bytes.
--- @return string|nil, string|nil
--
function Host:Ask()
    local default = ""
    if self.Settings.Find.PrefillFromClipboard then
        local clipboard = self.CE:ClipboardText()
        local parsed = clipboard and Pattern.Parse(clipboard) or nil
        if parsed and parsed.Fixed > 0 then default = parsed.Pattern end
    end
    local text, reason = self.CE:Input(self.Settings.Find.MenuCaption,
        "Paste a signature. A wildcard is ? or ??.", default)
    if text == nil then
        if reason then
            self.Log:Warning("Find signature: " .. tostring(reason) .. ".")
            return nil, reason
        end
        return nil, "cancelled"
    end
    if text:gsub("%s", "") == "" then return nil, "nothing was given" end
    return text
end

--
--- ∑ Lists several hits in a window that stays open. A click on a line goes
---   to that hit and leaves the list where it is, so the hits of one scan can
---   be compared one after another without scanning for them again.
---
---   A list that is still open is filled again rather than built again, so it
---   keeps the place and the size it was given. A list that was closed opens
---   again where it was.
---
---   Without a list the first hit is not offered as a guess. Every address is
---   already in the log block by the time this runs, so the way out is
---   ManifoldSigMaker:Goto(address) and not a coin toss.
--- @param result table
--- @return boolean|nil, string|nil
--
function Host:ListHits(result)
    local title, lines = self.Finder:Title(result), self.Finder:Lines(result)
    local current = self.HitList
    if current then
        current.Result = result
        if self.CE:RefillList(current.Window, title, lines) then return true end
        self:CloseHits()
    end

    local state = { Result = result }
    local window, reason = self.CE:OpenList({
        Title = title,
        Lines = lines,
        Owner = self.CE:MemoryView(),
        Bounds = self.HitBounds,
        OnPick = function(index)
            if self.HitList ~= state then return end
            local ok, err = pcall(self.ShowHit, self, index)
            if not ok then
                self.Log:Error(string.format("Going to hit %d failed: %s", index, tostring(err)))
            end
        end,
        OnClose = function(bounds)
            self.HitBounds = bounds
            if self.HitList == state then self.HitList = nil end
        end
    })
    if not window then
        self.Log:Warning(string.format(
            "Find signature: %s, so the hits are only in the log. " ..
            "ManifoldSigMaker:Goto(address) goes to one of them.", tostring(reason)))
        return nil, reason
    end
    state.Window = window
    self.HitList = state
    return true
end

--
--- ∑ Goes to one hit of the list that is open. A memory view that is already
---   on screen is moved without being raised, so the list keeps the keyboard.
--- @param index number # The line, counted from one.
--- @return number|nil, string|nil
--
function Host:ShowHit(index)
    local current = self.HitList
    if not current then return nil, "no list of hits is open" end
    local result = current.Result
    local address = result.Addresses[tonumber(index) or 0]
    if not address then return nil, "the list has no hit " .. tostring(index) end
    local shown, reason = self.CE:ShowAddress(address, result.Pattern.Tokens, true)
    if not shown then
        self.Log:Warning("Find signature: " .. tostring(reason) .. ".")
        return nil, reason
    end
    return address
end

--- Closes the list of hits when one is open.
function Host:CloseHits()
    local current = self.HitList
    if not current then return false end
    self.HitList = nil
    self.CE:CloseList(current.Window)
    return true
end

--
--- ∑ Scans for a signature and goes to where it matched.
---
---   With no text it asks for one. One hit is a jump. Several are a list that
---   stays open, and a click on one of its lines goes there. The whole list
---   reaches the log either way, so it is still there once the window is gone.
--- @param text string|nil # Any form Manifold-SigMaker-Pattern reads.
--- @return number|nil, string|nil # The address, or nil and a reason. The
---         reason is "listed" when the hits went into the list.
--
function Host:Find(text)
    if text == nil then
        local asked, askReason = self:Ask()
        if not asked then return nil, askReason end
        text = asked
    end

    local result, scanReason = self.Finder:Scan(text)
    if not result then
        self.Log:Warning("Find signature: " .. tostring(scanReason) .. ".")
        return nil, scanReason
    end
    self.Log:Info(self.Log:Block("Find signature", self.Finder:Rows(result)))

    -- A list on screen holds the hits of the scan before this one. Several
    -- new hits take it over, and anything else closes it, so a list never
    -- shows hits that are not the latest.
    if result.Count > 1 then
        local listed, listReason = self:ListHits(result)
        if not listed then return nil, listReason end
        return nil, "listed"
    end
    self:CloseHits()

    if result.Count == 0 then
        local nothing = self.Finder:NothingFound(result)
        self.Log:Warning("Find signature: " .. nothing .. ".")
        return nil, nothing
    end

    local address = result.Addresses[1]
    -- The whole pattern is selected in the hex view, so what matched is
    -- visible as a block rather than as one address.
    local shown, showReason = self.CE:ShowAddress(address, result.Pattern.Tokens)
    if not shown then
        self.Log:Warning("Find signature: " .. tostring(showReason) .. ".")
        return address, showReason
    end
    return address
end

--
--- ∑ The scan on its own, with no prompt, no list and no jump. This is what a
---   table's Lua script asks for when it wants the addresses.
--- @param text string
--- @return table|nil, table|string # The addresses and the whole result, or
---         nil and a reason.
--
function Host:Scan(text)
    local result, reason = self.Finder:Scan(text)
    if not result then return nil, reason end
    return result.Addresses, result
end

--
--- ∑ Puts the memory view on an address.
--- @param where number|string # 14D762ED9, "0x14D762ED9" or "game.exe+1A2B".
--- @return number|nil, string|nil
--
function Host:Goto(where)
    local address, reason = self.CE:Resolve(where)
    if not address then
        self.Log:Warning("Go to: " .. tostring(reason) .. ".")
        return nil, reason
    end
    local shown, showReason = self.CE:ShowAddress(address)
    if not shown then
        self.Log:Warning("Go to: " .. tostring(showReason) .. ".")
        return nil, showReason
    end
    return address
end

--------------------------------------------------------
--                       Settings                     --
--------------------------------------------------------

function Host:SetMaskDisplacement(enabled)
    self.Settings:Set("Mask.Displacement", enabled == true)
    return self.Settings.Mask.Displacement
end

function Host:SetMaskBranchTarget(enabled)
    self.Settings:Set("Mask.BranchTarget", enabled == true)
    return self.Settings.Mask.BranchTarget
end

--- Takes true, false or "large". See Manifold-SigMaker-Settings.
function Host:SetMaskImmediate(value)
    self.Settings:Set("Mask.Immediate", value)
    return self.Settings.Mask.Immediate
end

--
--- ∑ Which lines land on the clipboard, as a comma separated list of part
---   names: aob, aobq, code, header.
--- @param spec string
--- @return string|nil, string|nil
--
function Host:SetOutput(spec)
    local named = {}
    for name in tostring(spec or ""):gmatch("[^,%s]+") do
        if not Format.Parts[name:lower()] then
            return nil, string.format(
                "'%s' is not a part name. Known parts are aob, aobq, code, header.", name)
        end
        named[#named + 1] = name:lower()
    end
    if #named == 0 then return nil, "name at least one part" end
    self.Settings:Set("Output", table.concat(named, ","))
    return self.Settings.Output
end

--- "module" or "process".
function Host:SetScope(scope)
    if scope ~= "module" and scope ~= "process" then
        return nil, "scope must be 'module' or 'process'"
    end
    self.Settings:Set("Scope", scope)
    return self.Settings.Scope
end

--
--- ∑ Which memory a search covers, in the protection flag form celua.txt
---   documents under AOBScan: a sign, + - or *, followed by X, W or C. "+X"
---   is executable memory, "" is everything.
--- @param flags string
--- @return string|nil, string|nil
--
function Host:SetFindProtection(flags)
    flags = tostring(flags or "")
    -- Every valid pair is removed, and whatever is left over is what makes it
    -- invalid. A Lua pattern cannot repeat a group, so the obvious
    -- "^([%+%-%*][XWC])+$" quietly matches nothing at all.
    if (flags:gsub("[%+%-%*][XWCxwc]", "")) ~= "" then
        return nil, string.format(
            "'%s' is not a protection filter. It is a sign, + - or *, and then X, W or C, " ..
            "as in '+X-C'. An empty one searches all memory", flags)
    end
    self.Settings:Set("Find.Protection", flags:upper())
    return self.Settings.Find.Protection
end

--- Whether a search that found nothing in executable memory is repeated over
--- all of it before it gives up.
function Host:SetFindFallback(enabled)
    self.Settings:Set("Find.Fallback", enabled == true)
    return self.Settings.Find.Fallback
end

--- The shortest pattern a search will accept, counted in fixed bytes.
function Host:SetFindMinimum(bytes)
    local count = tonumber(bytes)
    if not count or count < 1 then return nil, "the minimum is a count of bytes, at least 1" end
    self.Settings:Set("Find.MinFixedBytes", math.floor(count))
    return self.Settings.Find.MinFixedBytes
end

--- How many hits a scan hands to the list of hits.
function Host:SetFindMaxResults(count)
    local limit = tonumber(count)
    if not limit or limit < 1 then return nil, "the limit is a count of hits, at least 1" end
    self.Settings:Set("Find.MaxResults", math.floor(limit))
    return self.Settings.Find.MaxResults
end

--- Whether the prompt opens on the clipboard when it holds a signature.
function Host:SetFindPrefill(enabled)
    self.Settings:Set("Find.PrefillFromClipboard", enabled == true)
    return self.Settings.Find.PrefillFromClipboard
end

--
--- ∑ The key that opens the search, written the way Cheat Engine writes one:
---   "Ctrl+Shift+F". An empty string takes the key away. The entries are
---   rebuilt, because a shortcut is read off a menu item when it is created.
--- @param shortcut string
--- @return string|nil, string|nil
--
function Host:SetFindShortcut(shortcut)
    shortcut = tostring(shortcut or "")
    self.Settings:Set("Find.Shortcut", shortcut)
    if self.Menu:Installed() then self:Reinstall() end
    return self.Settings.Find.Shortcut
end

--------------------------------------------------------
--                       Lifecycle                    --
--------------------------------------------------------

function Host:Status()
    return {
        Version = Version.Full(),
        Menu = self.Menu:Installed(),
        Shortcut = self.Menu:ShortcutInstalled(),
        Logger = self.Log:Attached(),
        Settings = self.Settings:Summary()
    }
end

function Host:StatusRows()
    local status = self:Status()
    local mask = {}
    if status.Settings.Displacement then mask[#mask + 1] = "displacements" end
    if status.Settings.BranchTarget then mask[#mask + 1] = "branch targets" end
    if status.Settings.Immediate == true then mask[#mask + 1] = "immediates"
    elseif status.Settings.Immediate == "large" then mask[#mask + 1] = "large immediates" end
    local settings = status.Settings
    local shortcut = settings.FindShortcut
    if shortcut == nil or shortcut == "" then
        shortcut = "none"
    elseif not status.Shortcut then
        shortcut = shortcut .. ", not installed"
    end
    return {
        { "Menu", status.Menu and "in the disassembler context menu" or "not installed" },
        { "Shortcut", shortcut },
        { "Logger", status.Logger and "Manifold Logger" or "print fallback" },
        { "Wildcards", #mask > 0 and table.concat(mask, ", ") or "none" },
        { "Unique in", settings.Scope == "module" and "the containing module" or "the whole process" },
        { "Clipboard", settings.Output },
        { "Search", string.format("%s, %s, at least %d fixed byte(s)",
            Find.Where(settings.FindProtection),
            settings.FindFallback and "widened to all memory when nothing matches"
                or "never widened",
            settings.FindMinFixedBytes) },
        { "Settings", settings.Persist and "persisted in the registry" or "session only" },
        "",
        "ManifoldSigMaker:Copy() makes a signature for the selected address.",
        "ManifoldSigMaker:Find() scans for one and goes to where it matched.",
        "ManifoldSigMaker:Goto(address) just moves the memory view.",
        "ManifoldSigMaker:SetOutput('header,code,aobq') restores the old three lines."
    }
end

function Host:Shutdown()
    self:Uninstall()
    if rawget(_G, Host.GlobalKey) == self then _G[Host.GlobalKey] = nil end
    if rawget(_G, Host.FacadeKey) == self then _G[Host.FacadeKey] = nil end
end

return Host
