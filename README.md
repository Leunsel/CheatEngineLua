# Cheat Engine Lua Modules

## Features

The following modules are (will be) included in this repository:

### 1. `(Module.)State.lua`
The State.lua module provides a simple and efficient interface for saving and loading the state of memory records in Cheat Engine tables. This module leverages the JSON format to serialize and deserialize state data, enabling easy storage and restoration of memory record states.

### 2. `(Module.)Helper.lua`
`(Standalone)` The module is a comprehensive set of functions designed to assist with interacting with the game’s process and modules within Cheat Engine. It provides utilities for retrieving detailed information about the game process, including its version, architecture (`64-bit` or `32-bit`), and module details.

### 3. `(Module.)Utility.lua`
The module offers a variety of functions and tools to enhance the user experience while working with Cheat Engine tables. It provides automatic attachment to processes, memory record management, safe data reading and writing, and user-friendly messages, among other features.

### 4. `(Module.)Logger.lua`
`(Standalone)` The module is a powerful and flexible logging utility designed for Cheat Engine. It provides structured logging functionality that can be customized with different output formats, logging levels, and handlers. This module supports logging in plain text and JSON formats, allowing for easy integration with external systems or scripts.

### 5. `(Module.)Teleporter.lua`
...

### 6. `(Module.)FormManager.lua`
...

### 7. `(Module.)AutoAssembler.lua`
This module is designed for automating Cheat Engine's auto-assembly process. It allows users to load and assemble cheat scripts dynamically into a game from either a table or a local `.CEA` file.
