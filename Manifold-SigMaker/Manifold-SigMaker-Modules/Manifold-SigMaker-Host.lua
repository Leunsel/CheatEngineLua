--[[
    The host. Wires the modules together and is the object published as
    ManifoldSigMaker.

    Build order:

      CE         the defensive API wrappers
      Log        the Manifold Logger channel, or print
      Settings   defaults, overrides, the persisted masking choices
      Decoder    which bytes of an instruction are operands
      Signature  growing a pattern until it is unique
      Menu       the entry in the disassembler context menu

    Everything the menu does is a method here, so a table's Lua script or the
    Lua console can do the same work without ever opening the menu:

        ManifoldSigMaker:Make()                  -- the selected address
        ManifoldSigMaker:Make(0x14D762ED9)       -- a given one
        ManifoldSigMaker:Copy()                  -- make and put on the clipboard
        ManifoldSigMaker:Pattern(address)        -- just the scan pattern
        ManifoldSigMaker:Status()
]]

local CE        = require("Manifold-SigMaker-CE")
local Log       = require("Manifold-SigMaker-Log")
local Settings  = require("Manifold-SigMaker-Settings")
local Decoder   = require("Manifold-SigMaker-Decoder")
local Signature = require("Manifold-SigMaker-Signature")
local Format    = require("Manifold-SigMaker-Format")
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
        Started = os.time()
    }, Host)
    instance.Signature = Signature:New({ CE = ce, Log = log, Settings = settings, Decoder = decoder })
    instance.Icons = Icons:New({ Root = options.Root })
    instance.Menu = Menu:New({ CE = ce, Log = log, Settings = settings,
        Icons = instance.Icons, MenuTag = Host.MenuTag })
    return instance
end

--------------------------------------------------------
--                        The menu                    --
--------------------------------------------------------

function Host:Install()
    return self.Menu:Install(function() self:Copy() end)
end

function Host:Uninstall()
    return self.Menu:Remove()
end

--- Rebuilds the entry. Worth calling after Cheat Engine has rebuilt the
--- memory view form, because the old item went with it.
function Host:Reinstall()
    self:Uninstall()
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

--------------------------------------------------------
--                       Lifecycle                    --
--------------------------------------------------------

function Host:Status()
    return {
        Version = Version.Full(),
        Menu = self.Menu:Installed(),
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
    return {
        { "Menu", status.Menu and "in the disassembler context menu" or "not installed" },
        { "Logger", status.Logger and "Manifold Logger" or "print fallback" },
        { "Wildcards", #mask > 0 and table.concat(mask, ", ") or "none" },
        { "Unique in", status.Settings.Scope == "module" and "the containing module" or "the whole process" },
        { "Clipboard", status.Settings.Output },
        { "Settings", status.Settings.Persist and "persisted in the registry" or "session only" },
        "",
        "ManifoldSigMaker:Copy() makes a signature for the selected address.",
        "ManifoldSigMaker:Pattern(address) returns just the scan pattern.",
        "ManifoldSigMaker:SetOutput('header,code,aobq') restores the defaults."
    }
end

function Host:Shutdown()
    self:Uninstall()
    if rawget(_G, Host.GlobalKey) == self then _G[Host.GlobalKey] = nil end
    if rawget(_G, Host.FacadeKey) == self then _G[Host.FacadeKey] = nil end
end

return Host
