--[[
    Small, defensive file-system wrapper used by the template loader.
]]

local File = {}
File.__index = File

local instance = nil

local function normalizePath(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return path:gsub("\\", "/"):gsub("/+$", "")
end

function File:New()
    if not instance then
        instance = setmetatable({}, File)
    end
    return instance
end

function File:Exists(path)
    path = normalizePath(path)
    if not path then return false end
    local ok, attr = pcall(lfs.attributes, path)
    return ok and attr and attr.mode == "file" or false
end

function File:FolderExists(path)
    path = normalizePath(path)
    if not path then return false end
    local ok, attr = pcall(lfs.attributes, path)
    return ok and attr and attr.mode == "directory" or false
end

function File:EnsureFolder(path)
    path = normalizePath(path)
    if not path then return false, "Invalid directory path" end
    if self:FolderExists(path) then return true end

    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path and not self:FolderExists(parent) then
        local parentOk, parentErr = self:EnsureFolder(parent)
        if not parentOk then return false, parentErr end
    end

    local ok, created, err = pcall(lfs.mkdir, path)
    if ok and created then return true end
    if self:FolderExists(path) then return true end
    return false, tostring(err or created)
end

function File:Size(path)
    path = normalizePath(path)
    if not path then return 0 end
    local ok, attr = pcall(lfs.attributes, path)
    return ok and attr and attr.size or 0
end

function File:ReadFile(path)
    path = normalizePath(path)
    if not path then return nil, "Invalid file path" end

    local handle, err = io.open(path, "rb")
    if not handle then
        return nil, string.format("Unable to open '%s': %s", path, tostring(err))
    end

    local content = handle:read("*a")
    handle:close()
    if content == nil then
        return nil, "Unable to read '" .. path .. "'"
    end
    return content
end

function File:WriteFile(path, content)
    path = normalizePath(path)
    if not path then return false, "Invalid file path" end
    if type(content) ~= "string" then return false, "File content must be a string" end

    local handle, err = io.open(path, "wb")
    if not handle then
        return false, string.format("Unable to write '%s': %s", path, tostring(err))
    end

    local ok, writeErr = handle:write(content)
    handle:close()
    if not ok then
        return false, tostring(writeErr)
    end
    return true
end

function File:ScanFolder(path, recursive)
    path = normalizePath(path)
    local files = {}
    if not path or not self:FolderExists(path) then return files end

    local ok, iterator, directory = pcall(lfs.dir, path)
    if not ok then return files end

    for entry in iterator, directory do
        if entry ~= "." and entry ~= ".." then
            local fullPath = path .. "/" .. entry
            local attrOk, attr = pcall(lfs.attributes, fullPath)
            if attrOk and attr then
                if attr.mode == "directory" and recursive then
                    local nested = self:ScanFolder(fullPath, true)
                    for _, nestedPath in ipairs(nested) do
                        files[#files + 1] = nestedPath
                    end
                elseif attr.mode == "file" then
                    files[#files + 1] = fullPath
                end
            end
        end
    end

    table.sort(files, function(a, b) return a:lower() < b:lower() end)
    return files
end

return File
