# Cheat Engine Lua Modules
This repository (will contain) a collection of Cheat Engine Lua modules designed to streamline and enhance the process of customizing (my) Cheat Tables. These modules provide a variety of tools for automating tasks, managing memory records, interacting with game processes, and more. By using these modules, you can speed up the table creation process and improve the efficiency of your scripts (I guess).

Whether you’re working with memory records, automating the auto-assembly process, or managing form interactions, these modules offer a range of features to help you create more robust and dynamic Cheat Tables.

![Preview](https://lowlevel.me/uploads/default/original/1X/b0d626ddea072d9171fb7f79588d5a71e4b91110.png)

## Features
The following modules are (will be) included in this repository:

#### 1. `(Module.)State.lua`
The State.lua module provides a simple and efficient interface for saving and loading the state of memory records in Cheat Engine tables. This module leverages the JSON format to serialize and deserialize state data, enabling easy storage and restoration of memory record states.

#### 2. `(Module.)Helper.lua`
`(Standalone)` The module is a comprehensive set of functions designed to assist with interacting with the game’s process and modules within Cheat Engine. It provides utilities for retrieving detailed information about the game process, including its version, architecture (`64-bit` or `32-bit`), and module details.

#### 3. `(Module.)Utility.lua`
The module offers a variety of functions and tools to enhance the user experience while working with Cheat Engine tables. It provides automatic attachment to processes, memory record management, safe data reading and writing, and user-friendly messages, among other features.

#### 4. `(Module.)Logger.lua`
`(Standalone)` The module is a powerful and flexible logging utility designed for Cheat Engine. It provides structured logging functionality that can be customized with different output formats, logging levels, and handlers. This module supports logging in plain text and JSON formats, allowing for easy integration with external systems or scripts.

#### 5. `(Module.)Teleporter.lua`
It allows for teleportation functionalities in a game, providing methods to read and write memory positions, save and load teleportation data, and optionally perform smooth teleportation over a defined duration. (Last option is unused within my tables.)

#### 6. `(Module.)FormManager.lua`
The module provides a flexible and (hopefully) efficient way to manage and customizing the UI components within Cheat Engine. This module allows you to load themes from Json Files dynamically and at runtime to enhance the overall look of my Cheat Tables as well as adding some extra components to the Cheat Engine Main Form to add a signature touch to Tables.

#### 7. `(Module.)AutoAssembler.lua`
This module is designed for automating Cheat Engine's auto-assembly process. It allows users to load and assemble cheat scripts dynamically into a game from either a table or a local `.CEA` file.
