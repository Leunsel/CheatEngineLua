# Manifold Framework

**Manifold** is a modular Lua framework designed for Cheat Engine, providing utilities for memory manipulation, user interface customization, process handling, logging, and more. Manifold aims to allow for faster and easier Cheat Table development.

---

## 🚀 Features

- Modular plug-and-play architecture
- Structured logging and error handling
- AutoAssembler integration and memory utilities
- Process-aware state persistence
- Themeable UI with JSON support
- File I/O abstraction with safe directory handling
- Trainer-friendly Teleporter system

---

## 📁 Data Directory Structure

Manifold organizes runtime and user data into a well-defined `DataDirectory`, resolved by default to:

```lua
os.getenv("USERPROFILE") .. "\\AppData\\Local\\Manifold"
```

### Directory Layout
```
Manifold/
├── CEA/
│   └── <ProcessName>/
│       └── *.CEA                      → AutoAssembler files per process
├── Themes/
│   └── *.json                         → UI theme configuration files
├── Teleporter/
│   └── Teleporter.<Process>.Saves.txt → Teleport save data
├── Logs/
│   └── Manifold.Runtime.<Process>.log → Execution logs
└── ... (other runtime files)
```

Directories are created automatically at runtime by `Manifold.CustomIO`. To retrieve or configure the path manually:

```lua
local dataDir = Manifold.CustomIO.GetDataDir()
```

---

## 📦 Module Overview

Manifold modules are loaded in a controlled sequence to ensure dependency resolution:

### 🔧 Core Utilities
- `Manifold.CustomIO`
- `Manifold.Logger`
- `Manifold.Utils`

### 🧰 Support Systems
- `Manifold.Helper`
- `Manifold.Json`
- `Manifold.ProcessHandler`

### 🧠 Functional Modules
- `Manifold.Memory`
- `Manifold.State`
- `Manifold.AutoAssembler`
- `Manifold.Teleporter`

### 🎨 UI and Themes
- `Manifold.UI`

Modules self-register to the `Manifold` table when loaded. Each is only loaded once.

---

## 📥 Loading Manifold Modules

Modules are loaded via a custom helper function, `CETrequire`, which attempts to load from disk first, then from embedded Cheat Engine `TableFiles`.

### 🔁 CETrequire Function

```lua
local tableLuaFilesDirectory = "luaFiles"
local luaFileExt = ".lua"

function CETrequire(moduleStr)
    if not moduleStr then return end
    local sep = package.config:sub(1, 1)
    local localTableLuaFilePath = tableLuaFilesDirectory ~= "" and (tableLuaFilesDirectory .. sep .. moduleStr) or moduleStr
    local fullPath = localTableLuaFilePath .. luaFileExt

    local f = io.open(fullPath)
    if f then
        f:close()
        return dofile(fullPath)
    end

    local tableFile = findTableFile(moduleStr .. luaFileExt)
    if not tableFile then return end

    local stream = tableFile.stream
    local fn, err = load(readStringLocal(stream.memory, stream.size))
    if not fn then
        error("Error loading module '" .. moduleStr .. "': " .. err)
    end

    return fn()
end
```

### Example
```lua
CETrequire("Manifold.State")
local state = State:New()
--- Module and it's functions are now available:
state:SaveTableState("Profile-Easy")
```

Some modules may require additional setup after loading (e.g., Teleporter).

---

## 🤝 Contributing

Contributions, bug reports, and feature requests are welcome! Please follow the existing coding style and modular structure.

---

## 📜 License

This project is licensed under the terms of the **MIT License**.
