--[[
    Manifold.TableFiles.lua
    --------------------------------

    AUTHOR  : Leunsel, LeFiXER
    LICENSE : MIT
    CREATED : 2026-08-27

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

    Entry point. Drop this file and its -Modules folder into Cheat Engine's
    autorun directory, then open the window from anywhere:

        ManifoldTableFiles:Open()

    Manifold-CE-Utility adds a menu entry for it when both are installed.
    This module registers no menu of its own, so the two never produce a
    duplicate entry.

    The version number lives in Manifold-TableFiles-Version.lua.
]]

local sep = package.config:sub(1, 1)
local root = (type(getAutorunPath) == "function" and getAutorunPath() or "")
package.path = root .. "Manifold-TableFiles-Modules" .. sep .. "?.lua;" .. package.path

local Version = require("Manifold-TableFiles-Version")
local Types = require("Manifold-TableFiles-Types")
local Theme = require("Manifold-TableFiles-Theme")
local Images = require("Manifold-TableFiles-Images")
local Files = require("Manifold-TableFiles-Files")
local Editor = require("Manifold-TableFiles-Editor")
local Viewer = require("Manifold-TableFiles-Viewer")

--
--- ∑ One log line, in the shape the rest of the Manifold tools use. A live
---   Manifold.Logger is preferred, so the table's own log keeps everything
---   in one place; without one this falls back to a timestamped print.
--- @param message string # What happened.
--- @param isError boolean|nil # Whether it was a failure.
--- @return nil # No return value.
--
local function Log(message, isError)
    local logger = rawget(_G, "logger")
    if type(logger) == "table" then
        local method = isError and logger.Error or logger.Info
        if type(method) == "function" then
            local ok = pcall(method, logger, "[TableFiles] " .. tostring(message))
            if ok then return end
        end
    end
    print(string.format("[%s] [%s] [TableFiles] %s",
        os.date("%H:%M:%S") or "??:??:??",
        isError and "FAIL" or "INFO",
        tostring(message)))
end

--
--- ∑ Executes a function in the main thread (or synchronizes to it).
---   Every window here is built from this: touching the LCL from a timer or
---   a worker thread is what makes Cheat Engine fall over.
--- @param func function # The function to call.
--- @return boolean # Whether it ran.
--
local function RunInMainThread(func)
    if type(func) ~= "function" then
        Log("RunInMainThread: expected a function.", true)
        return false
    end
    local isMainThread = true
    if type(inMainThread) == "function" then
        local ok, result = pcall(inMainThread)
        isMainThread = (not ok) or result
    end
    if isMainThread or type(synchronize) ~= "function" then
        local ok, err = pcall(func)
        if not ok then
            Log("Error executing in main thread: " .. tostring(err), true)
            return false
        end
        return true
    end
    local ok, err = pcall(function() synchronize(func) end)
    if not ok then
        Log("Synchronization failed: " .. tostring(err), true)
        return false
    end
    return true
end

--
--- ∑ Asks before something irreversible. Without a usable dialog API the
---   answer is no: a missing confirmation must never read as consent.
--- @param action string # What is about to happen.
--- @param affectedCount number|nil # How many entries it touches.
--- @return boolean # True when the user agreed.
--
local function Confirm(action, affectedCount)
    if type(messageDialog) ~= "function"
        or type(mtConfirmation) ~= "number"
        or type(mbYes) ~= "number"
        or type(mbNo) ~= "number"
        or type(mrYes) ~= "number" then
        Log("Confirmation API unavailable; blocked action: " .. tostring(action), true)
        return false
    end
    local countText = affectedCount and ("\n\nAffected entries: " .. tostring(affectedCount)) or ""
    local message = action .. countText .. "\n\nDo you want to continue?"
    local result = nil
    local ok = RunInMainThread(function()
        result = messageDialog(message, mtConfirmation, mbYes, mbNo)
    end)
    if not ok then
        Log("Confirmation dialog failed.", true)
        return false
    end
    if result ~= mrYes then
        Log("Action cancelled: " .. tostring(action))
        return false
    end
    return true
end

-- Re-executing this file (from the table's Lua script, say) must not build a
-- second viewer and leave the first one orphaned with its window still open.
local existing = rawget(_G, "ManifoldTableFiles")
if type(existing) == "table" and existing.Open then
    return existing
end

local viewer = Viewer:New({
    Theme = Theme:New({ Log = Log }),
    Types = Types,
    Images = Images:New({ Log = Log, Types = Types }),
    Files = Files:New({ Log = Log, Types = Types }),
    Editor = Editor,
    Log = Log,
    RunInMainThread = RunInMainThread,
    Confirm = Confirm,
    Version = Version
})

_G.ManifoldTableFiles = viewer

-- Log(Version.Full() .. " ready.")

return viewer
