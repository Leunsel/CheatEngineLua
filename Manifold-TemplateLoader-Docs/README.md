# Manifold Template Loader Documentation

## Overview

The **Manifold Template Loader** is a Lua-based system designed for Cheat Engine, enabling users to manage and utilize templates for memory manipulation and scripting. This documentation provides a comprehensive guide to the system's components, usage, and configuration.

---

## Table of Contents

1. [Introduction](#introduction)
2. [Installation](#installation)
3. [Components](#components)
   - [Manifold-TemplateLoader-Log](#manifold-template-loader-log)
   - [Manifold-TemplateLoader-Memory](#manifold-template-loader-memory)
   - [Manifold-TemplateLoader-Manager](#manifold-template-loader-manager)
   - [Manifold-TemplateLoader-Loader](#manifold-template-loader-loader)
   - [Manifold-TemplateLoader-Json](#manifold-template-loader-json)
   - [Manifold-TemplateLoader-File](#manifold-template-loader-file)
4. [Configuration](#configuration)
5. [Usage](#usage)
6. [Logging](#logging)
7. [Template Management](#template-management)
8. [Error Handling](#error-handling)
9. [License](#license)
10. [Contributing](#contributing)

---

## Introduction

The Manifold Template Loader system is designed to facilitate the creation, management, and execution of templates for Cheat Engine scripts. It provides a structured approach to handle various aspects of template loading, memory manipulation, and logging.

---

## Installation

To install the Manifold Template Loader, follow these steps:

1. Download the latest version from the repository.
2. Extract the files to the Cheat Engine autorun directory:
   ```
   C:\Program Files\Cheat Engine 7.5\autorun\Manifold-TemplateLoader-Modules\
   ```
3. Ensure that all dependencies are met, including LuaFileSystem (lfs).

---

## Components

### Manifold-TemplateLoader-Log

This module handles logging for the entire system, providing various log levels (DEBUG, INFO, WARNING, ERROR, CRITICAL) and options to log to a file.

#### Key Functions

- `Log:New()`: Creates a new log instance.
- `Log:SetLogLevel(level)`: Sets the current log level.
- `Log:Log(level, message)`: Logs a message at the specified level.

### Manifold-TemplateLoader-Memory

This module manages memory-related operations, including retrieving memory information, checking pointer sizes, and handling injection information.

#### Key Functions

- `Memory:New()`: Creates a new memory instance.
- `Memory:GetCurrentDate()`: Returns the current date.
- `Memory:GetInstructionSize(addr)`: Retrieves the size of the instruction at the specified address.

### Manifold-TemplateLoader-Manager

This module is responsible for managing templates, including discovering, loading, and initializing them.

#### Key Functions

- `Manager:New()`: Creates a new manager instance.
- `Manager:DiscoverTemplates()`: Scans the template folder for available templates.
- `Manager:InitTemplate(templateName)`: Initializes a specified template.

### Manifold-TemplateLoader-Loader

This module orchestrates the loading of templates and their configurations, applying settings and managing the environment.

#### Key Functions

- `Loader:New()`: Creates a new loader instance.
- `Loader:LoadConfig()`: Loads the configuration from a JSON file.
- `Loader:GenerateTemplateScript(template, script, sender)`: Generates a script from the specified template.

### Manifold-TemplateLoader-Json

This module provides JSON encoding and decoding capabilities, allowing for easy configuration management.

#### Key Functions

- `JSON:encode(value)`: Encodes a Lua table into a JSON string.
- `JSON:decode(text)`: Decodes a JSON string into a Lua table.

### Manifold-TemplateLoader-File

This module handles file operations, including reading, writing, and scanning directories.

#### Key Functions

- `File:Exists(path)`: Checks if a file exists at the specified path.
- `File:ReadFile(path)`: Reads the content of a file.
- `File:ScanFolder(dir, recursive)`: Scans a directory for files.

---

## Configuration

The configuration for the Manifold Template Loader is managed through a JSON file located at:

```
C:\Program Files\Cheat Engine 7.5\autorun\Manifold-TemplateLoader-Modules\Manifold-TemplateLoader-Config.json
```

### Example Configuration

```json
{
    "Logger": {
        "Level": "INFO",
        "LogToFile": true
    },
    "InjectionInfo": {
        "LineCount": 3,
        "RemoveSpaces": true,
        "AddTabs": true,
        "AppendToHookName": "Hook"
    }
}
```

---

## Usage

To use the Manifold Template Loader, follow these steps:

1. Initialize the loader:
   ```lua
   local Loader = require("Manifold-TemplateLoader-Loader")
   local loaderInstance = Loader:New()
   ```

2. Load templates:
   ```lua
   loaderInstance:LoadTemplates()
   ```

3. Generate a script from a template:
   ```lua
   loaderInstance:GenerateTemplateScript(template, script, sender)
   ```

---

## Logging

The logging system allows you to track the operations of the Manifold Template Loader. You can set the log level and choose whether to log to a file.

### Example Logging Usage

```lua
local Log = require("Manifold-TemplateLoader-Log")
local log = Log:New()
log:SetLogLevel(Log.LogLevel.DEBUG)
log:Info("This is an info message.")
```

---

## Template Management

Templates are managed through the Manager module. You can discover, load, and initialize templates as needed.

### Example Template Management

```lua
local Manager = require("Manifold-TemplateLoader-Manager")
local managerInstance = Manager:New()
local templates = managerInstance:DiscoverTemplates()
```

---

## Error Handling

The system includes error handling mechanisms to ensure that issues are logged and managed appropriately. Use the logging functions to capture errors and warnings.

### Example Error Handling

```lua
if not file:Exists(path) then
    log:Error("File does not exist: " .. path)
end
```

---

## License

The Manifold Template Loader is licensed under the MIT License. See the LICENSE file for more details.

---

## Contributing

Contributions to the Manifold Template Loader are welcome! Please follow these steps:

1. Fork the repository.
2. Create a new branch for your feature or bug fix.
3. Submit a pull request with a description of your changes.

---

This documentation provides a comprehensive overview of the Manifold Template Loader system. For further details, please refer to the source code and comments within each module.