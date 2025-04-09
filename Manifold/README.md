# Manifold Framework

**Manifold** is a modular Lua framework designed for Cheat Engine, providing utilities for memory manipulation, user interface customization, process handling, logging, and more. With an emphasis on extensibility and developer ergonomics, Manifold allows rapid game-hacking toolkit development.

## Features

- Modular architecture (plug-and-play system)
- Structured logging and error handling
- AutoAssembler and memory utilities
- Process-aware state management
- Dynamic UI theming with JSON support
- File I/O abstraction with safe directory handling
- Teleporter and trainer-friendly enhancements

---

## 📁 Understanding the "DataDirectory"

Manifold uses a structured `DataDirectory` to store runtime data, CEA files, logs, and theme information. This directory is typically resolved to:
```lua
os.getenv("USERPROFILE") .. "\\AppData\\Local\\Manifold"
```
Inside it, the framework organizes data as follows:
```
Manifold/
├── CEA/
│   └── <ProcessName>/
│       └── *.CEA                      → AutoAssembler files specific to the current process
├── Themes/
│   └── *.json                         → Custom theme JSON files
├── Teleporter/
│   └── Teleporter.<Process>.Saves.txt → Custom theme JSON files
├── Logs/
│   └── Manifold.Runtime.<Process>.log
└── ... (other runtime files)
```
If folders are missing, the framework creates them at runtime via Manifold.CustomIO.

You can also manually configure or retrieve paths using:
```lua
local dataDir = Manifold.CustomIO.GetDataDir()
```

---

## 📦 Module Load Order

Manifold’s load order ensures critical infrastructure is ready before dependent modules initialize.  
The main loader (`Manifold.lua`) handles modules in the following order:

### 🔧 Core Utilities
These modules provide foundational functionality such as file I/O, logging, and general utilities.

- `Manifold.CustomIO`
- `Manifold.Logger`
- `Manifold.Utils`

### 🧰 Support Systems
These modules assist with data handling, process access, and helper functionality.

- `Manifold.Helper`
- `Manifold.Json`
- `Manifold.ProcessHandler`

### 🧠 Functional Modules
These are the primary tools used during runtime, including memory scanning, state saving, and auto assembling.

- `Manifold.Memory`
- `Manifold.State`
- `Manifold.AutoAssembler`
- `Manifold.Teleporter`

### 🎨 UI and Themes
Responsible for user interface rendering and theme management.

- `Manifold.UI`

Each module is loaded once and registered to the global `Manifold` table.  
Modules are expected to **self-register** when required, exposing their functionality under the appropriate `Manifold.<ModuleName>` namespace.


---

## 🤝 Contributing

Contributions, bug reports, and new modules are welcome! Please follow the established directory structure and coding patterns.

---

## 📜 License

This project is licensed under the terms of the **MIT** License.
