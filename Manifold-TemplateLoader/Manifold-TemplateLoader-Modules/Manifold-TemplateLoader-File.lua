--[[
    Manifold.TemplateLoader.File.lua
    --------------------------------

    AUTHOR  : Leunsel, LeFiXER
    VERSION : 2.0.0
    LICENSE : MIT
    CREATED : 2025-06-21
    UPDATED : 2025-06-24

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
]]

File = {}
File.__index = File

local instance = nil

function File:New()
    if not instance then
        instance = setmetatable({}, File)
    end
    return instance
end

function File:Exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    path = path:gsub("\\", "/"):gsub("/+$", "")
    local attr = lfs.attributes(path)
    return attr and attr.mode == "file"
end

function File:FolderExists(dir)
    local attr = lfs.attributes(dir)
    return attr and attr.mode == "directory"
end

function File:Size(dir)
    local attr = type(dir) == "string" and lfs.attributes(dir)
    return attr and attr.size or 0
end

function File:ReadFile(path)
    path = path:gsub("\\", "/"):gsub("/+$", "")
    local file, err = io.open(path, "rb")
    if not file then error("Failed to open file: " .. tostring(path) .. ". Error: " .. tostring(err)) end
    local content = file:read("*a")
    file:close()
    return content
end

function File:WriteFile(dir, content)
    local file, err = io.open(dir, "wb")
    if not file then error("Failed to write to file: " .. tostring(dir) .. ". Error: " .. tostring(err)) end
    file:write(content)
    file:close()
end

function File:ScanFolder(dir, recursive)
    local files = {}
    if type(dir) ~= "string" or dir == "" then
        return files
    end
    dir = dir:gsub("\\", "/")
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local fulldir = dir .. "/" .. entry
            local attr = lfs.attributes(fulldir)
            if attr then
                if attr.mode == "directory" and recursive then
                    local subfiles = self:ScanFolder(fulldir, true)
                    for _, f in ipairs(subfiles) do
                        files[#files + 1] = f
                    end
                elseif attr.mode == "file" then
                    files[#files + 1] = fulldir
                end
            end
        end
    end
    return files
end

return File