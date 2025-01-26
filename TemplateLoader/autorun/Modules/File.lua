local NAME = "TemplateLoader.File"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Cheat Engine Template Framework (File)"

--[[
    -- To debug the module, use the following setup to load modules from the autorun folder:
    local sep = package.config:sub(1, 1)
    package.path = getAutorunPath() .. "Modules" .. sep .. "?.lua;" .. package.path
    local File = require("File")
]]

local File = {}

function File.exists(name)
    if not name then return false end
    return os.rename(name, name) ~= nil
end

function File.scanFolder(path, recursive)
    local files = {}
    path = path:gsub("\\", "/")
    for filename in lfs.dir(path) do
        if filename ~= "." and filename ~= ".." then
            local fullPath = path .. "/" .. filename
            local fileAttributes = lfs.attributes(fullPath)

            if fileAttributes then
                local isDirectory = fileAttributes.mode == "directory"

                if not isDirectory then
                    table.insert(files, fullPath)
                elseif recursive then
                    for _, subFile in ipairs(File.scanFolder(fullPath, recursive)) do
                        table.insert(files, subFile)
                    end
                end
            end
        end
    end
    return files
end

function File.size(name)
    if not name then return 0 end
    local file, err = io.open(name, "rb")
    if not file then
        error("Failed to open file: ".. name.. ". Error: ".. tostring(err))
    end
    local size = file:seek("end")
    file:close()
    return size
end

function File.readFile(path)
    local file, err = io.open(path, "r")
    if not file then
        error("Failed to open file: " .. path .. ". Error: " .. tostring(err))
    end
    local content = file:read("*a")
    file:close()
    return content
end

function File.writeFile(path, content)
    local file, err = io.open(path, "w")
    if not file then
        error("Failed to write to file: " .. path .. ". Error: " .. tostring(err))
    end
    file:write(content)
    file:close()
end

return File
