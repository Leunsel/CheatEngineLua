# Cheat Engine Lua Modules

This repository contains a collection of Lua modules tailored for Cheat Engine to streamline and enhance the process of customizing Cheat Tables. These modules offer tools for automating tasks, managing memory records, interacting with game processes, and more. By leveraging these modules, you can accelerate table creation *(and hopefully improve the efficiency and robustness of your Cheat Tables)*.

Whether you're handling memory records, automating the auto-assembly process, or managing UI components, these modules provide the functionality to create more dynamic and feature-rich Cheat Tables.

![Preview](https://i.imgur.com/VwlTQhB.png)

---

## Credits
Acknowledgments and thanks to the following contributors and resources:

- **LeFiXER**: For invaluable guidance and extensive support throughout the development of this project.
- **rxi**: For sharing the `json.lua`, which made my life a lot easier.
- **TheyCallMeTim13**: For providing inspiration through his meticulously crafted Cheat Tables and for creating the `Module.Helper.lua` Module.

---

## Usage
Each module requires specific dependencies to function correctly. Below is a list of dependencies for each module:

### Module Dependencies

| Module                  | Dependencies                      |
|-------------------------|------------------------------------|
| **Module.Logger.lua**   | `json.lua`                        |
| **Module.State.lua**    | `json.lua`, `Module.Logger.lua`   |
| **Module.Helper.lua**   | *(Standalone)*                    |
| **Module.AutoAssembler.lua** | `Module.Logger.lua`           |
| **Module.FormManager.lua**   | `Module.Logger.lua`           |
| **Module.Teleporter.lua**    | `json.lua`, `Module.Logger.lua` |
| **Module.Utility.lua**       | `json.lua`, `Module.Logger.lua` |
| **Module.TableFileExplorer.lua**       | `Module.Logger.lua`, `Module.Utility.lua` |


To use a module, ensure all its dependencies are included in your Cheat Table script. Import the modules using the `require` function and call their respective functions as documented in their code or guides.

If used or shipped as Table-Files, the normal `require` method won't work.
```lua
local tableLuaFilesDirectory = "luaFiles"
local luaFileExt = ".lua"

function CETrequire(moduleStr)
    if moduleStr ~= nil then
        local localTableLuaFilePath = moduleStr
        if tableLuaFilesDirectory ~= nil and tableLuaFilesDirectory ~= "" then
            local sep = package.config:sub(1, 1)
            localTableLuaFilePath = tableLuaFilesDirectory .. sep .. moduleStr
        end
        local f, err = io.open(localTableLuaFilePath .. luaFileExt)
        if f and not err then
            f:close()
            return dofile(localTableLuaFilePath .. luaFileExt)
        else
            local tableFile = findTableFile(moduleStr .. luaFileExt)
            if tableFile == nil then
                return
            end
            local stream = tableFile.stream
            local fn, err = load(readStringLocal(stream.memory, stream.size))
            if not fn then
                 error('Error loading code: ' .. err)
            end
         return fn()
        end
    end
end

-- ...

CETrequire('json')
CETrequire('Module.State')
CETrequire('Module.Helper')
CETrequire('Module.Utility')
CETrequire('Module.Logger')
CETrequire('Module.Teleporter')
CETrequire('Module.FormManager')
CETrequire('Module.AutoAssembler')
```

---

## Contribution
Contributions are welcome! If you have ideas for improvements or new features or themes, feel free to open an issue or submit a pull request.
