# Manifold-TemplateLoader-File

## Overview

Handles file and directory operations for the Template Loader.

## Key Functions

| Function | Description |
|----------|-------------|
| `File:New()` | Create a new file utility instance. |
| `File:Exists(path)` | Check if a file exists. |
| `File:FolderExists(dir)` | Check if a folder exists. |
| `File:ReadFile(path)` | Read file contents. |
| `File:WriteFile(path, content)` | Write content to a file. |
| `File:ScanFolder(dir, recursive)` | List files in a directory (optionally recursive). |

## Usage Example

```lua
local File = require("Manifold-TemplateLoader-File")
local file = File:New()
if file:Exists("C:/test.txt") then
    print(file:ReadFile("C:/test.txt"))
end
```