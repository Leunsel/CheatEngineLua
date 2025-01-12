local NAME = "Loader.Main"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.0.0"
local DESCRIPTION = "Cheat Engine Template Framework (Main)"

--[[
    -- To debug the module, use the following setup to load modules from the autorun folder:
    local sep = package.config:sub(1, 1)
    package.path = getAutorunPath() .. sep .. "?.lua;" .. package.path
    local Loader = require("TemplateLoader.Loader")
]]

local sep = package.config:sub(1, 1)
package.path = getAutorunPath() .. "Modules" .. sep .. "?.lua;" .. package.path
local Loader = require("Loader")

--[[
The ScriptTemplateFramework is a powerful and flexible foundation designed to streamline the development of scripts
and templates within the Cheat Engine environment. It provides a consistent structure, reusable components, and
predefined functionality, which reduces redundancy and allows developers to focus on the specific logic of their
scripts.

Key benefits of the ScriptTemplateFramework:
1. Modular:
   Design Easily extend and customize components like template loading, logging, memory handling, etc.
2. Efficiency:
   Provides pre-built utilities and functions, speeding up the development process and reducing boilerplate code.
3. Scalability:
   Easily accommodates complex templates and scripts while maintaining organization and readability.
4. Consistency:
   Standardized naming conventions and structure across all templates make it easier for teams to collaborate
   and maintain code.
5. Debugging:
   Integrated logging and debugging tools simplify tracking and troubleshooting, helping developers iterate
   more quickly.
6. Hot-Reloading:
   Nearly everything within the framework can be hot-reloaded with the press of a button, allowing
   for instant updates and changes without needing to restart or reload the entire environment.

Overall, the ScriptTemplateFramework accelerates script and template development, improves code maintainability, and
enhances collaboration among developers, making it an essential tool for efficient Cheat Engine scripting.
]]

-- 'Loader' is an instance of Loader that has been created and initialized by calling Loader.createAndLoad(). 
-- This process discovers all available templates, registers them, and prepares the loader for further operations.
local Loader = Loader.createAndLoad()
Loader:attachMenuToForm()

local isReleaseMode = false

if isReleaseMode then
    Loader:loadTemplates()
else
    Loader:debugTemplates()
end
