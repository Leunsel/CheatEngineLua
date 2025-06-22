# Manifold-TemplateLoader-Loader

## Overview

Orchestrates template loading, configuration, and menu integration.

## Key Functions

| Function | Description |
|----------|-------------|
| `Loader:New()` | Create a new loader instance and load config. |
| `Loader:LoadConfig()` | Load configuration from JSON. |
| `Loader:SaveConfig()` | Save configuration to JSON. |
| `Loader:LoadTemplates()` | Register all discovered templates. |
| `Loader:ReloadTemplates()` | Reload all templates. |
| `Loader:ReloadDependencies()` | Reload all core modules. |
| `Loader:SetupMenu(form)` | Add Template Loader menu to Cheat Engine. |
| `Loader:GenerateTemplateScript(template, script, sender)` | Generate and apply a script from a template. |

## Usage Example

```lua
local Loader = require("Manifold-TemplateLoader-Loader")
local loader = Loader:New()
loader:LoadTemplates()
```