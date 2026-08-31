--[[
    Manifold.Logger.lua
    --------------------------------

    AUTHOR  : Leunsel, LeFiXER
    LICENSE : MIT
    CREATED : 2026-08-31

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

    Entry point. Drop this file and the Manifold-Logger-Modules folder into
    Cheat Engine's autorun directory. Open() shows the console window,
    Channel() hands back a named channel:

        ManifoldLogger:Open()
        local log = ManifoldLogger:Channel("Mine")
        log:Info("ready", { build = 3 })

    Side-loading works. A script that logs through this requires nothing and
    does not care about load order:

        local log = ManifoldLogger and ManifoldLogger:Channel("MyTool")
        if log then log:Warning("something") end

    Re-running this file leaves the live log attached. Rebuilding would orphan
    every channel handed out so far and discard the buffer. Call
    ManifoldLogger:Shutdown() first for a real rebuild.

    Version number lives in Manifold-Logger-Version.lua.
]]

local sep = package.config:sub(1, 1)
local root = (type(getAutorunPath) == "function" and getAutorunPath() or "")
local modules = root .. "Manifold-Logger-Modules" .. sep
package.path = modules .. "?.lua;" .. package.path

-- Matches Manifold-Logger-Host.GlobalKey. Host:Shutdown clears it so the next
-- execution of this file takes the cold-start path.
local HOST_KEY = "ManifoldLoggerHost"

--
--- ∑ The module names this tree owns, in dependency order.
---   Cheat Engine's require is standard Lua require, so package.loaded
---   survives a re-execution of this file. A cold start drops these entries
---   first, otherwise an edited module keeps running its old code.
--
local MODULES = {
    "Manifold-Logger-Version",
    "Manifold-Logger-Format",
    "Manifold-Logger-Core",
    "Manifold-Logger-File",
    "Manifold-Logger-Icons",
    "Manifold-Logger-Theme",
    "Manifold-Logger-View",
    "Manifold-Logger-Bridge",
    "Manifold-Logger-Console",
    "Manifold-Logger-Host"
}

local existing = rawget(_G, HOST_KEY)

-- No live host means a cold start, which must not inherit modules from a
-- previous generation. A live host is the opposite case. Its instances hold
-- metatables from the modules loaded now, so replacing those orphans them.
if type(existing) ~= "table" then
    -- Icons keeps its singleton in a module-local upvalue. Dropping the module
    -- from package.loaded orphans a live TImageList, its PNGs and every
    -- composited bitmap, so ask the outgoing generation to let go first.
    local previousIcons = package.loaded["Manifold-Logger-Icons"]
    if type(previousIcons) == "table" and type(previousIcons.New) == "function" then
        pcall(function() previousIcons:New():Destroy() end)
    end
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
end

local Host = require("Manifold-Logger-Host")
local Version = require("Manifold-Logger-Version")

local host = existing
if type(host) == "table" and type(host.Channel) == "function" then
    -- Already running. Cheat Engine rebuilds its main menu in some situations,
    -- so re-install the entry, and report a re-execution, not a reload.
    host:RemoveMenu()
    if host.Settings.InstallMenu then host:InstallMenu() end
    host:Info(Version.Full() ..
        " re-executed. The live log stays attached; call ManifoldLogger:Shutdown() first for a full rebuild.")
else
    host = Host:New({
        Root = modules,
        Name = "Manifold"
    })
    if host.Settings.InstallMenu then host:InstallMenu() end

    local status = host:Status()
    host:Info(host:Block(Version.Full() .. " ready", {
        { "Level", status.Level },
        { "Buffer", string.format("%d records", status.Capacity) },
        { "Log file", status.File and status.File.Path or "disabled" },
        { "Icons", status.Icons },
        #status.Bridges > 0 and { "Bridged", table.concat(status.Bridges, ", ") } or false,
        "",
        "ManifoldLogger:Open() opens the console.",
        "ManifoldLogger:Channel('Name') hands any script its own channel."
    }))
end

_G[HOST_KEY] = host
_G.ManifoldLogger = host

return host
