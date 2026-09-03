--[[
    Manifold.CE.Utility.lua
    --------------------------------

    AUTHOR  : Leunsel, LeFiXER
    LICENSE : MIT
    CREATED : 2025-11-17

    MIT License:
        Copyright (c) 2025 Leunsel

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.

    Entry point. Drop this file and the Manifold-CE-Utility-Modules folder
    into Cheat Engine's autorun directory. A "[— Manifold —]" entry appears
    in the main menu bar. Everything on it is also a method:

        ManifoldCEUtility:GenerateStructureRecords()
        ManifoldCEUtility:DeactivateEverything()
        ManifoldCEUtility:Status()

    Re-running this file rebuilds the menu from fresh module code. The
    previous generation's menu, timer and image list are taken down first,
    so nothing accumulates.

    Defaults for the caption, the shortcuts and the structure colours live
    in Manifold-CE-Utility-Settings.lua and can be overridden below.
    The version number lives in Manifold-CE-Utility-Version.lua.
]]

local sep = package.config:sub(1, 1)
local root = (type(getAutorunPath) == "function" and getAutorunPath() or "")
local modules = root .. "Manifold-CE-Utility-Modules" .. sep
package.path = modules .. "?.lua;" .. package.path

--
--- ∑ The module names this tree owns. Cheat Engine's require is standard
---   Lua require, so package.loaded survives a re-execution of this file.
---   They are dropped first, otherwise an edited module keeps running its
---   old code.
--
local MODULES = {
    "Manifold-CE-Utility-Version",
    "Manifold-CE-Utility-CE",
    "Manifold-CE-Utility-Log",
    "Manifold-CE-Utility-Icons",
    "Manifold-CE-Utility-Settings",
    "Manifold-CE-Utility-Structures",
    "Manifold-CE-Utility-Records",
    "Manifold-CE-Utility-Shell",
    "Manifold-CE-Utility-Menu",
    "Manifold-CE-Utility-Host"
}

-- Matches Manifold-CE-Utility-Host.GlobalKey.
local HOST_KEY = "ManifoldCEUtilityHost"

-- 1.x kept its root item and caption timer here, untagged, so the Tag sweep
-- below cannot reach them. Timer first: its callback captures the item. Its
-- image list is Cheat Engine's own and must not be destroyed.
local LEGACY_KEY = "__MANIFOLD_CE_UTILITY_RUNTIME__"
local legacy = rawget(_G, LEGACY_KEY)
if type(legacy) == "table" then
    for _, field in ipairs({ "rotationTimer", "menuItem" }) do
        local component = legacy[field]
        if component ~= nil then
            pcall(function() component.Enabled = false end)
            pcall(function() component.destroy() end)
            legacy[field] = nil
        end
    end
    _G[LEGACY_KEY] = nil
end

-- A previous generation goes first: its menu and timer through Uninstall,
-- and its image list explicitly. Icons keeps that list in a module-local
-- upvalue, so dropping the module below would orphan a live TImageList.
local previous = rawget(_G, HOST_KEY)
if type(previous) == "table" then
    if type(previous.Uninstall) == "function" then pcall(previous.Uninstall, previous) end
    local icons = previous.Icons
    if type(icons) == "table" and type(icons.Destroy) == "function" then pcall(icons.Destroy, icons) end
end
for _, name in ipairs(MODULES) do package.loaded[name] = nil end

-- 1.x was a single file. Someone upgrading by copying only this file gets
-- one readable line instead of a require traceback on every start.
local okHost, Host = pcall(require, "Manifold-CE-Utility-Host")
if not okHost then
    print(string.format("[CE Utility] Manifold-CE-Utility-Modules was not found next to this file in %s. " ..
        "Copy the folder there too. (%s)", root, tostring(Host)))
    return nil
end
local Version = require("Manifold-CE-Utility-Version")

local host = Host:New({
    -- Overrides for Manifold-CE-Utility-Settings.Defaults, for example:
    -- Settings = { MenuCaption = "Tools", Shortcuts = { LuaEngine = "Ctrl+Shift+L" } }
})
local installed, reason = host:Install()

_G[HOST_KEY] = host
_G[Host.FacadeKey] = host
if type(registerLuaFunctionHighlight) == "function" then
    registerLuaFunctionHighlight(Host.FacadeKey)
end

--[[
if installed then
    host.Log:Info(host.Log:Block(Version.Full() .. (previous and " re-executed" or " ready"), host:StatusRows()))
else
    host.Log:Error(Version.Full() .. ": the menu could not be installed. " .. tostring(reason) .. ".")
end
]]

return host
