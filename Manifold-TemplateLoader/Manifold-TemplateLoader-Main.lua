--[[
    Manifold.TemplateLoader.Main.lua
    --------------------------------

    AUTHOR  : Leunsel, LeFiXER
    LICENSE : MIT
    CREATED : 2025-06-21

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

    This file is part of the Manifold TemplateLoader system.
    The version number lives in Manifold-TemplateLoader-Version.lua.
]]

local sep = package.config:sub(1, 1)
package.path = getAutorunPath() .. "Manifold-TemplateLoader-Modules" .. sep .. "?.lua;" .. package.path

local Host = require("Manifold-TemplateLoader-Host")
local Runtime = require("Manifold-TemplateLoader-Runtime")

local host = Host:New()

-- Re-executing this file (e.g. from the table Lua script) must not build a
-- second runtime and double-register every template. The 2.x singleton had
-- the same effect, use "Full runtime reload" to actually reload.
if host.Loader then
    host:Log("Main.lua re-executed, the active runtime stays attached. Use 'Full runtime reload' to reload.")
    return
end

local runtime = Runtime:New()
host:Attach(runtime)

_G.ManifoldTemplateLoaderHost = host
_G.ManifoldTemplateLoader = host.Loader
loader = host.Loader -- backwards compatibility for existing autorun snippets

host.Loader:LoadTemplates()