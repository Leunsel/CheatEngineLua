# Manifold-TemplateLoader-Manager

## Overview

Manages template discovery, loading, and initialization.

## Key Functions

| Function | Description |
|----------|-------------|
| `Manager:New()` | Create a new manager instance. |
| `Manager:DiscoverTemplates()` | Scan the template folder for available templates. |
| `Manager:InitTemplate(templateName)` | Initialize a template with its settings. |
| `Manager:GetTemplateFolder()` | Get the template folder path. |
| `Manager:NormalizePath(path)` | Normalize a file path. |

## Usage Example

```lua
local Manager = require("Manifold-TemplateLoader-Manager")
local manager = Manager:New()
local templates = manager:DiscoverTemplates()
for _, t in ipairs(templates) do
    print(t.name)
end
```