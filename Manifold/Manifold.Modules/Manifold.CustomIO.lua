local NAME = "Manifold.CustomIO.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.1"
local DESCRIPTION = "Manifold Framework CustomIO"

--[[
    ∂ v1.0.0 (2025-02-26)
        Initial release with core functions.

    ∂ v1.0.1 (2025-03-27)
        Improved error handling, reduced 'string.format' usage.
        Added CSV read/write support and safe file deletion.
]]--

CustomIO = {}
CustomIO.__index = CustomIO

function CustomIO:New()
    local instance = setmetatable({}, self)
    self:CheckDependencies()
    instance.Name = NAME or "Unnamed Module"
    instance.DataDir = os.getenv("USERPROFILE") .. "\\AppData\\Local\\Manifold"
    return instance
end
registerLuaFunctionHighlight('New')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table # {name, version, author, description}
--
function CustomIO:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

--
--- ∑ Checks if all required dependencies are loaded, and loads them if necessary.
--- @return void
--- @note This function checks for the existence of the 'json' dependency,
---       and attempts to load them if not already present.
--
function CustomIO:CheckDependencies()
    local dependencies = {
        { name = "json", path = "Manifold.Json",  init = function() json = JSON:new() end },
        -- Logger is assumed to be loaded as it's a core dependency.
    }
    for _, dep in ipairs(dependencies) do
        local depName = dep.name
        if _G[depName] == nil then
            logger:Warning("[CustomIO] '" .. depName .. "' dependency not found. Attempting to load...")
            local success, result = pcall(CETrequire, dep.path)
            if success then
                logger:Info("[CustomIO] Loaded dependency '" .. depName .. "'.")
                if dep.init then dep.init() end
            else
                logger:Error("[CustomIO] Failed to load dependency '" .. depName .. "': " .. result)
            end
        else
            logger:Debug("[CustomIO] Dependency '" .. depName .. "' is already loaded")
        end
    end  
end

--
--- ∑ Checks if a directory exists.
--- @param dir string  # The directory path to check for existence.
--- @return boolean  # Returns 'true' if the directory exists, 'false' otherwise.
--
function CustomIO:DirectoryExists(dir)
    local attr = lfs.attributes(dir)
    return attr and attr.mode == "directory"
end
registerLuaFunctionHighlight('DirectoryExists')

--
--- ∑ Ensures that a directory exists, creating it if necessary.
--- @param path string  # The directory path to check or create.
--- @return boolean  # Returns 'true' if the directory exists or was created successfully, 'false' otherwise.
--
function CustomIO:EnsureDirectoryExists(path)
    if not customIO:DirectoryExists(path) then
        local success, err = customIO:CreateDirectory(path)
        if not success then
            logger:Error("[CustomIO] Failed to create folder '" .. path .. "': " .. (err or "Unknown error"))
            return false
        end
    end
    return true
end
registerLuaFunctionHighlight('EnsureDirectoryExists')

--
--- ∑ Builds a complete file path from the provided directory and file name.
--- @param dir string  # The directory path.
--- @param fileName string  # The file name (including extension).
--- @return string  # Returns the full path, properly formatted.
--
function CustomIO:BuildPath(dir, fileName)
    if not dir or type(dir) ~= "string" or dir == "" then
        logger:Error("[CustomIO] Invalid directory path.")
        return nil
    end
    if not fileName or type(fileName) ~= "string" or fileName == "" then
        logger:Error("[CustomIO] Invalid file name.")
        return nil
    end
    if not dir:match("[\\/]$") then
        dir = dir .. "\\"
    end
    return dir .. fileName
end
registerLuaFunctionHighlight('BuildPath')

--
--- ∑ Attempts to create a directory if it does not exist.
--- @param dir string  # The directory path to create.
--- @return boolean  # Returns 'true' if the directory was successfully created, 'false' if there was an error.
--- @note This function logs an error message if the directory creation fails.
--
function CustomIO:CreateDirectory(dir)
    local attributes = lfs.attributes(dir)
    if attributes and attributes.mode == "directory" then
        logger:Info("[CustomIO] Directory already exists: " .. dir)
        return true  -- No need to create it if it already exists
    end
    local success = lfs.mkdir(dir)
    if not success then
        local err = "Unknown error"
        if not lfs.attributes(dir) then
            err = "Permission denied or invalid path"
        end
        logger:Error("[CustomIO] Failed to create directory '" .. dir .. "'! Error: " .. err)
        return false, err
    end
    logger:Info("[CustomIO] Successfully created directory: " .. dir)
    return true
end
registerLuaFunctionHighlight('CreateDirectory')

--
--- ∑ Opens a directory using the system's default file explorer.
--- @param dir string  # The directory path to open.
--- @return boolean  # Returns 'true' if the directory was opened successfully, 'false' otherwise.
--
function CustomIO:OpenDirectory(dir)
    if not dir or type(dir) ~= "string" or dir == "" then
        logger:Error("[CustomIO] Invalid directory path.")
        return false
    end
    if not self:DirectoryExists(dir) then
        logger:Error("[CustomIO] Directory does not exist: '" .. dir .. "'")
        return false
    end
    local success, result = pcall(os.execute, string.format('start /b "" "%s"', dir))
    if success then
        logger:Info("[CustomIO] Opened folder: '" .. dir .. "'")
        return true
    else
        logger:Error("[CustomIO] Failed to open folder '" .. dir .. "': " .. result)
        return false
    end
end
registerLuaFunctionHighlight('OpenDirectory')

--
--- ∑ Strips the extension from a file name.
--- @param fileName string  # The file name to process.
--- @return string|nil  # Returns the file name without the extension, or nil on error.
--
function CustomIO:StripExt(fileName)
    if not fileName or type(fileName) ~= "string" or fileName == "" then
        logger:Error("[CustomIO] Invalid file name provided for StripExt.")
        return nil
    end
    local nameWithoutExt = fileName:match("(.+)%.[^%.]+$")
    if not nameWithoutExt or nameWithoutExt == "" then
        logger:Warning("[CustomIO] Failed to strip extension from file name: '" .. fileName .. "'. Returning original name.")
        return fileName
    end
    logger:Info("[CustomIO] Stripped extension from file name: '" .. fileName .. "' -> '" .. nameWithoutExt .. "'")
    return nameWithoutExt
end
registerLuaFunctionHighlight('StripExt')

--
--- ∑ Checks if a file exists at the specified path.
--- @param filePath string  # The path of the file to check.
--- @return boolean  # Returns 'true' if the file exists, 'false' otherwise.
--- @note This function simply attempts to open the file in read mode. If the file can be opened, it is considered to exist.
--
function CustomIO:FileExists(filePath)
    local file = io.open(filePath, "r")
    if file then
        file:close()
        return true
    else
        return false
    end
end
registerLuaFunctionHighlight('FileExists')

--
--- ∑ Attempts to delete a file at the given path.
--- @param filePath string  # The path of the file to delete.
--- @return boolean  # Returns 'true' if the file was successfully deleted, 'false' if there was an error.
--- @note This function logs an error message if the file deletion fails.
--
function CustomIO:DeleteFile(filePath)
    if not filePath then
        return false, "File path is missing"
    end
    local success, err = pcall(function()
        os.remove(filePath)
    end)
    if not success then
        logger:Error("[CustomIO] Failed to delete file '" .. filePath .. "': " .. err)
        return false, err
    end
    return true
end
registerLuaFunctionHighlight('DeleteFile')

--
--- ∑ Reads the contents of a file and returns it as a string.
--- @param filePath string  # The path of the file to read from.
--- @returns string|nil, string|nil  # Returns the file contents or 'nil' with an error message.
--
function CustomIO:ReadFromFile(filePath)
    if not filePath then
        return nil, "Invalid parameter: filePath is missing"
    end
    local file, err = io.open(filePath, "r")
    if not file then
        return nil, "File not found or cannot be opened: " .. (err or "Unknown reason")
    end
    local content = file:read("*all")
    file:close()
    
    if not content then
        return nil, "Failed to read content from file"
    end
    return content
end
registerLuaFunctionHighlight('ReadFromFile')

--
--- ∑ Writes raw text data to a specified file, overwriting it.
--- @param filePath string  # The path of the file to write to.
--- @param text string  # The text content to be written.
--- @return boolean, string|nil  # Returns 'true' if successful, otherwise 'false' and an error message.
--
function CustomIO:WriteToFile(filePath, data)
    if not filePath or not data then
        return false, "Invalid parameters: filePath or data is missing"
    end
    local success, err = pcall(function()
        local file = assert(io.open(filePath, "w"))
        file:write(data)
        file:close()
    end)
    if not success then
        logger:Error("[CustomIO] Failed to write to file '" .. filePath .. "': " .. err)
        return false, err
    end
    return true
end
registerLuaFunctionHighlight('WriteToFile')

--
--- ∑ Appends raw text data to a specified file.
--- @param filePath string  # The path of the file to append to.
--- @param text string  # The text content to be appended.
--- @return boolean, string|nil  # Returns 'true' if successful, otherwise 'false' and an error message.
--
function CustomIO:AppendToFile(filePath, data)
    if not filePath or not data then
        return false, "Invalid parameters: filePath or data is missing"
    end
    local success, err = pcall(function()
        local file = assert(io.open(filePath, "a"))
        file:write(data .. "\n")
        file:close()
    end)
    if not success then
        logger:Error("[CustomIO] Failed to append to file '" .. filePath .. "': " .. err)
        return false, err
    end
    return true
end
registerLuaFunctionHighlight('AppendToFile')

--
--- ∑ Attempts to read a CSV file and returns its contents as a table.
--- @param filePath string  # The path of the CSV file to read.
--- @return table  # Returns a table of rows (each row being a table of values), or 'nil' and an error message if failed.
--- @note This function assumes the CSV data is comma-separated and may fail for complex CSV formats (e.g., with commas inside quoted fields).
--
function CustomIO:ReadCSV(filePath)
    local content, err = self:ReadFromFile(filePath)
    if not content then return nil, err end

    local result = {}
    for line in content:gmatch("([^\n]*)\n?") do
        local row = {}
        for value in line:gmatch("([^,]+)") do
            table.insert(row, value)
        end
        table.insert(result, row)
    end
    return result
end
registerLuaFunctionHighlight('ReadCSV')

--
--- ∑ Writes data to a CSV file at the specified path.
--- @param filePath string  # The path of the CSV file to write to.
--- @param data table  # A table containing rows, where each row is a table of values.
--- @return boolean  # Returns 'true' if the data was successfully written, 'false' if there was an error.
--- @note This function assumes a simple CSV format (comma-separated values). It does not handle special cases like quoted fields with commas.
--
function CustomIO:WriteCSV(filePath, data)
    if not filePath or not data then
        return false, "Invalid parameters: filePath or data is missing"
    end
    local success, err = pcall(function()
        local file = assert(io.open(filePath, "w"))
        for _, row in ipairs(data) do
            file:write(table.concat(row, ",") .. "\n")
        end
        file:close()
    end)
    if not success then
        logger:Error("[CustomIO] Failed to write to CSV file '" .. filePath .. "': " .. err)
        return false, err
    end
    return true
end
registerLuaFunctionHighlight('WriteCSV')

--
--- ∑ Reads the content of a Cheat Engine table file and returns it as a string.
--- If the file does not exist, it logs a warning and returns 'nil'.
--- @param fileName string  # The name of the table file to read from.
--- @return string|nil  # Returns the file content as a string, or 'nil' if an error occurs.
--
function CustomIO:ReadFromTableFile(fileName)
    if not fileName then
        return nil, "Invalid parameter: fileName is missing"
    end
    logger:Info("[CustomIO] Reading data from Table File '" .. fileName .. "'!")
    local tableFile = findTableFile(fileName)
    if not tableFile then
        logger:Warning("[CustomIO] Table File '" .. fileName .. "' not found!")
        return nil, "File not found"
    end
    local success, content = pcall(function()
        local stream = tableFile.getData()
        local bytes = stream.read(stream.Size)
        return string.char(table.unpack(bytes))
    end)
    if not success or not content then
        logger:Error("[CustomIO] Failed to read from Table File '" .. fileName .. "'!")
        return nil, "Read error"
    end
    logger:Info("[CustomIO] Successfully read data from Table File '" .. fileName .. "'!")
    return content
end
registerLuaFunctionHighlight('ReadFromTableFile')

--
--- ∑ Writes a given text string to a Cheat Engine table file.
---   If the specified file is not found, the function attempts to create it.
--- @param fileName string  # The name of the table file to write to.
--- @param text string  # The text content to be written to the file.
--- @return boolean  # Returns true if the write operation is successful, otherwise false.
--
function CustomIO:WriteToTableFile(fileName, text)
    if not fileName or type(text) ~= "string" then
        logger:Error("[CustomIO] Invalid parameters: fileName or text is missing or not a string!")
        return false
    end
    logger:Info("[CustomIO] Writing data to file '" .. fileName .. "'!")
    local tableFile = findTableFile(fileName) or createTableFile(fileName)
    if not tableFile then
        logger:Error("[CustomIO] Failed to create/find table file '" .. fileName .. "'!")
        return false
    end
    local success, err = pcall(function()
        local stream = tableFile.getData()
        stream.Position = 0
        stream.Size = 0
        stream.write(text)
    end)
    if not success then
        logger:Error("[CustomIO] Failed to write data to file '" .. fileName .. "'! Error: " .. err)
        return false
    end
    logger:Info("[CustomIO] Successfully wrote data to file '" .. fileName .. "'!")
    return true
end

registerLuaFunctionHighlight('WriteToTableFile')

--
--- ∑ Reads the content of a Cheat Engine table file and returns it as a JSON object.
--- If the file does not exist, it logs a warning and returns 'nil'.
--- @param fileName string  # The name of the table file to read from.
--- @return table|nil  # Returns the file content as a parsed JSON table, or 'nil' if an error occurs.
--
function CustomIO:ReadFromTableFileAsJson(fileName)
    local content, err = self:ReadFromTableFile(fileName)
    if not content then
        return nil, err
    end
    local success, jsonData = pcall(function()
        return json:decode(content)
    end)
    if not success or not jsonData then
        logger:Error("[CustomIO] Failed to parse JSON from Table File '" .. fileName .. "'!")
        return nil, "JSON parse error"
    end
    return jsonData
end
registerLuaFunctionHighlight('ReadFromTableFileAsJson')

--
--- ∑ Writes a given table as JSON to a Cheat Engine table file.
--- If the specified file is not found, the function attempts to create it.
--- @param fileName string  # The name of the table file to write to.
--- @param data table  # The table to be serialized as JSON and written to the file.
--- @return boolean  # Returns true if the write operation is successful, otherwise false.
--
function CustomIO:WriteToTableFileAsJson(fileName, data)
    if not fileName or type(data) ~= "table" then
        logger:Error("[CustomIO] Invalid parameters: fileName is missing or data is not a table!")
        return false
    end
    local jsonText = json:encode(content)
    if not jsonText then
        logger:Error("[CustomIO] Failed to encode table data as JSON!")
        return false
    end
    return self:WriteToTableFile(fileName, jsonText)
end
registerLuaFunctionHighlight('WriteToTableFileAsJson')

--
--- ∑ Reads a JSON file, decodes it into a Lua table, and returns the data.
--- @param filePath string  # The path of the JSON file to read from.
--- @returns table|nil, string|nil  # Returns the parsed table or 'nil' with an error message.
--
function CustomIO:ReadFromFileAsJson(filePath)
    if not self:FileExists(filePath) then
        return nil, string.format("File '%s' does not exist.", filePath)
    end
    local content, err = self:ReadFromFile(filePath)
    if not content then
        return nil, err
    end
    -- logger:Debug("[CustomIO] Raw content read from file: " .. content)
    local data, decodeErr = json:decode(content)
    if not data then
        return nil, string.format("Failed to parse JSON: %s", decodeErr or "Unknown error")
    end
    -- logger:Debug("[CustomIO] Decoded JSON data: " .. tostring(data))
    return data
end
registerLuaFunctionHighlight('ReadFromFileAsJson')

--
--- ∑ Serializes Lua data into JSON and writes it to a specified file.
--- @param filePath string  # The path of the file to write to.
--- @param data table  # The Lua table to be serialized as JSON.
--- @return boolean, string|nil  # Returns 'true' if successful, otherwise 'false' and an error message.
--
function CustomIO:WriteToFileAsJson(filePath, data)
    if not filePath or not data then
        return false, "Invalid parameters: filePath or data is missing"
    end
    local success, err = pcall(function()
        local file = assert(io.open(filePath, "w"))
        file:write(json:encode_pretty(data))
        file:close()
    end)
    if not success then
        return false, string.format("Failed to write JSON to file: %s", err)
    end
    return true
end
registerLuaFunctionHighlight('WriteToFileAsJson')

--
--- ∑ Ensures the Data Directory exists.
--- @return true|false
--- @note Attempts to create the directory if it does not exist. Logs success or failure.
--
function CustomIO:EnsureDataDirectory()
    local dataDir = self.DataDir
    if self:DirectoryExists(dataDir) then return true end
    logger:Warning("[CustomIO] Data Directory does not exist, attempting to create it.")
    local success, err = self:CreateDirectory(dataDir)
    if not success then
        logger:Error("[CustomIO] Failed to create Data Directory: " .. (err or "Unknown Error"))
        return false
    end
    logger:Info("[CustomIO] Successfully created Data Directory: '" .. dataDir .. "'")
    return true
end
registerLuaFunctionHighlight('EnsureDataDirectory')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return CustomIO