# Manifold-TemplateLoader-Json

## Overview

Provides JSON encoding and decoding for configuration and data exchange.

## Key Functions

| Function | Description |
|----------|-------------|
| `JSON:encode(value)` | Encode a Lua table as a JSON string. |
| `JSON:decode(text)` | Decode a JSON string to a Lua table. |
| `JSON:encode_pretty(value)` | Encode a Lua table as pretty-printed JSON. |

## Usage Example

```lua
local JSON = require("Manifold-TemplateLoader-Json")
local data = { foo = "bar" }
local jsonStr = JSON:encode(data)
local tbl = JSON:decode(jsonStr)
```