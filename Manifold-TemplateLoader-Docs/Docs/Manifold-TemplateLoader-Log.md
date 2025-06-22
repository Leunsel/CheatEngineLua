# Manifold-TemplateLoader-Log

## Overview

Handles logging for the Template Loader system, supporting multiple log levels and file logging.

## Log Levels

- `NONE` (0)
- `DEBUG` (1)
- `INFO` (2)
- `WARNING` (3)
- `ERROR` (4)
- `CRITICAL` (5)

## Key Functions

| Function | Description |
|----------|-------------|
| `Log:New()` | Create a new logger instance. |
| `Log:SetLogLevel(level)` | Set the current log level. |
| `Log:Log(level, message)` | Log a message at the specified level. |
| `Log:Debug(message)` | Log a debug message. |
| `Log:Info(message)` | Log an info message. |
| `Log:Warning(message)` | Log a warning message. |
| `Log:Error(message)` | Log an error message. |
| `Log:Critical(message)` | Log a critical message. |
| `Log:ClearLogFile()` | Clear the log file if file logging is enabled. |

## Usage Example

```lua
local Log = require("Manifold-TemplateLoader-Log")
local log = Log:New()
log:SetLogLevel(log.LogLevel.DEBUG)
log:Info("This is an info message.")
```