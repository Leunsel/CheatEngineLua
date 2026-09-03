--[[
    Manifold.SigMaker.lua
    --------------------------------

    AUTHOR  : Leunsel
    LICENSE : MIT
    CREATED : 2026-09-03

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

    This is the entry point. Copy this file and the Manifold-SigMaker-Modules
    folder side by side into Cheat Engine's autorun directory. The next time
    Cheat Engine starts, the context menu in the disassembler carries a new
    entry called "Manifold: Copy Signature".

    Everything that entry does is also available as a method.

        ManifoldSigMaker:Copy()
            Builds a signature for the address selected in the disassembler
            and puts it on the clipboard.

        ManifoldSigMaker:Pattern(0x14D762ED9)
            Returns only the scan pattern for the address it is given.

        ManifoldSigMaker:Status()
            Reports what is loaded and how it is currently configured.

    Executing this file a second time is safe and is the normal way to pick up
    an edit. The menu entry from the previous run is taken down before the new
    one is built, and the modules are read from disk again, so nothing
    accumulates and no old code stays behind.

    The masking policy keeps its defaults in Manifold-SigMaker-Settings.lua.
    They can be overridden below. The version number lives in
    Manifold-SigMaker-Version.lua.
]]

local sep = package.config:sub(1, 1)
local root = (type(getAutorunPath) == "function" and getAutorunPath() or "")
local modules = root .. "Manifold-SigMaker-Modules" .. sep
package.path = modules .. "?.lua;" .. package.path

--
--- ∑ The names of the modules this tree owns. Cheat Engine's require is the
---   ordinary Lua require, so package.loaded survives a second execution of
---   this file. Every name listed here is dropped from it first. Without
---   that step an edited module would quietly keep running its old code.
--
local MODULES = {
    "Manifold-SigMaker-Version",
    "Manifold-SigMaker-CE",
    "Manifold-SigMaker-Log",
    "Manifold-SigMaker-Settings",
    "Manifold-SigMaker-Decoder",
    "Manifold-SigMaker-Signature",
    "Manifold-SigMaker-Format",
    "Manifold-SigMaker-Icons",
    "Manifold-SigMaker-Menu",
    "Manifold-SigMaker-Host"
}

-- This has to stay the same as Manifold-SigMaker-Host.GlobalKey.
local HOST_KEY = "ManifoldSigMakerHost"

local previous = rawget(_G, HOST_KEY)
if type(previous) == "table" and type(previous.Uninstall) == "function" then
    pcall(previous.Uninstall, previous)
end
for _, name in ipairs(MODULES) do package.loaded[name] = nil end

-- Someone who copied this file on its own and left the folder behind gets one
-- readable line here. The alternative is a require traceback on every single
-- Cheat Engine start.
local okHost, Host = pcall(require, "Manifold-SigMaker-Host")
if not okHost then
    print(string.format("[SigMaker] Manifold-SigMaker-Modules was not found next to this file in %s. " ..
        "Copy the folder there too. (%s)", root, tostring(Host)))
    return nil
end
local Version = require("Manifold-SigMaker-Version")

local host = Host:New({
    -- Anything put here overrides Manifold-SigMaker-Settings.Defaults, so:
    -- Settings = { Scope = "process", Mask = { Immediate = true } }
})

_G[HOST_KEY] = host
_G[Host.FacadeKey] = host
if type(registerLuaFunctionHighlight) == "function" then
    registerLuaFunctionHighlight(Host.FacadeKey)
end

-- At autorun time the memory view may not exist yet. Installing on demand
-- keeps the menu entry working without forcing that window open at startup.
local installed, reason = host:Install()
if not installed then
    host.Log:Debug("The disassembler menu entry is not installed yet: " .. tostring(reason) ..
        ". Call ManifoldSigMaker:Install() once the memory view is open.")
end

host.Log:Info(host.Log:Block(Version.Full() .. (previous and " re-executed" or " ready"),
    host:StatusRows()))

return host
