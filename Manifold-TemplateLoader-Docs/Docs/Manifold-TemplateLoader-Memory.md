# Manifold-TemplateLoader-Memory

## Overview

Provides memory-related utilities for Cheat Engine scripting, including instruction analysis, injection info, and process/module data.

## Key Functions

| Function | Description |
|----------|-------------|
| `Memory:New()` | Create a new memory instance. |
| `Memory:GetCurrentDate()` | Get the current date. |
| `Memory:GetCurrentTime()` | Get the current time. |
| `Memory:GetInstructionSize(addr)` | Get instruction size at address. |
| `Memory:GetOpcodes(addr, size)` | Get opcodes for a memory region. |
| `Memory:GetBytes(addr, size)` | Get bytes for a memory region. |
| `Memory:GetNopPadding(size, minSize)` | Get NOP padding string. |
| `Memory:GetJumpType()` | Get jump type (jmp/jmp far). |
| `Memory:GetJumpSize(addr, minSize)` | Get jump size for an address. |
| `Memory:GetInjectionInfo(addr, lines, removeSpaces)` | Get formatted injection info. |
| `Memory:GetInjectionInfoStr(addr)` | Get injection info as a string. |
| `Memory:GetMemoryInfo()` | Get a table with all relevant memory info for template use. |

## Usage Example

```lua
local Memory = require("Manifold-TemplateLoader-Memory")
local mem = Memory:New()
local info = mem:GetMemoryInfo()
print(info.Process, info.Module, info.Address)
```