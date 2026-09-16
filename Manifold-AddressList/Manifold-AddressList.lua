--[[
    Manifold.AddressList.lua
    --------------------------------

    AUTHOR  : Leunsel, LeFiXER
    LICENSE : MIT
    CREATED : 2026-09-16

    MIT License:
        Copyright (c) 2026 Leunsel

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

    This is the entry point. Copy this file and the Manifold-AddressList-Modules
    folder side by side into Cheat Engine's autorun directory. It opens one
    window over the address list of whatever Cheat Table is loaded, with the
    record tree on the left and an inspector on the right, and it edits records
    in bulk with an undo history of its own.

    This segment adds no menu entry anywhere. The Cheat Engine Utility carries
    one called Open Address List, and without that the way in is the method.

        ManifoldAddressList:Open()
            Shows the window, building it the first time.

        ManifoldAddressList:Toggle()
            The same entry, the other way round.

        ManifoldAddressList:Lint()
            Checks the table and answers the problems and the counts.

        ManifoldAddressList:Find("health")
            Every match in the descriptions and the scripts.

        ManifoldAddressList:Replace({ Needle = "hp", Replacement = "health" })
            The same search, written back as one undo entry.

        ManifoldAddressList:Export("C:\\records.json")
            The selection, or every root record when nothing is selected.

        ManifoldAddressList:Status()
            Reports what is loaded and how it is currently configured.

    Every one of those works with no window on screen, so a Cheat Table's own
    Lua script can use them without showing anything.

    Executing this file a second time is safe and is the normal way to pick up
    an edit. The window of the previous run is closed, its timers are stopped
    and its icons are freed before the new modules are read from disk, so
    nothing accumulates and no old code stays behind. The undo history does not
    survive that, because it belongs to the generation that made it.

    The window size, the split, the columns and the search flags live in
    Manifold-AddressList-Settings.lua and can be overridden below. The version
    number lives in Manifold-AddressList-Version.lua.
]]

local sep = package.config:sub(1, 1)
local root = (type(getAutorunPath) == "function" and getAutorunPath() or "")
local modules = root .. "Manifold-AddressList-Modules" .. sep
package.path = modules .. "?.lua;" .. package.path

--
--- ∑ The names of the modules this tree owns, in dependency order. Cheat
---   Engine's require is the ordinary Lua require, so package.loaded survives
---   a second execution of this file. Every name listed here is dropped from
---   it first. Without that step an edited module would quietly keep running
---   its old code.
--
local MODULES = {
    "Manifold-AddressList-Version",
    "Manifold-AddressList-Log",
    "Manifold-AddressList-Settings",
    "Manifold-AddressList-CE",
    "Manifold-AddressList-Icons",
    "Manifold-AddressList-Theme",
    "Manifold-AddressList-Types",
    "Manifold-AddressList-Records",
    "Manifold-AddressList-Properties",
    "Manifold-AddressList-Journal",
    "Manifold-AddressList-Lint",
    "Manifold-AddressList-Search",
    "Manifold-AddressList-Export",
    "Manifold-AddressList-Surface",
    "Manifold-AddressList-Tree",
    "Manifold-AddressList-Results",
    "Manifold-AddressList-Grid",
    "Manifold-AddressList-Pointer",
    "Manifold-AddressList-Script",
    "Manifold-AddressList-DropDown",
    "Manifold-AddressList-Hotkeys",
    "Manifold-AddressList-Inspector",
    "Manifold-AddressList-Window",
    "Manifold-AddressList-Host"
}

-- This has to stay the same as Manifold-AddressList-Host.GlobalKey.
local HOST_KEY = "ManifoldAddressListHost"

-- A previous generation goes first, in this order and no other. Uninstall
-- closes its window and stops its timers, then its icon set is destroyed
-- explicitly, because Icons keeps its image list in a module local upvalue and
-- dropping the module below would orphan a live TImageList with every PNG in
-- it. Only then do the modules go.
local previous = rawget(_G, HOST_KEY)
if type(previous) == "table" then
    if type(previous.Uninstall) == "function" then pcall(previous.Uninstall, previous) end
    local icons = previous.Icons
    if type(icons) == "table" and type(icons.Destroy) == "function" then
        pcall(icons.Destroy, icons)
    end
end
for _, name in ipairs(MODULES) do package.loaded[name] = nil end

-- Someone who copied this file on its own and left the folder behind gets one
-- readable line here. The alternative is a require traceback on every single
-- Cheat Engine start.
local okHost, Host = pcall(require, "Manifold-AddressList-Host")
if not okHost then
    print(string.format("[Address List] Manifold-AddressList-Modules was not found next to this file in %s. " ..
        "Copy the folder there too. (%s)", root, tostring(Host)))
    return nil
end
local Version = require("Manifold-AddressList-Version")

local host = Host:New({
    -- Anything put here overrides Manifold-AddressList-Settings.Defaults, the
    -- way the commented line below would.
    -- Settings = { FontSize = 11, LiveSync = false, Search = { MatchCase = true } }
})

_G[HOST_KEY] = host
_G[Host.FacadeKey] = host
if type(registerLuaFunctionHighlight) == "function" then
    registerLuaFunctionHighlight(Host.FacadeKey)
end

-- Startup-Log.
--[[
host.Log:Info(host.Log:Block(Version.Full() .. (previous and " re-executed" or " ready"),
    host:StatusRows()))
]]

return host
