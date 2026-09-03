# Manifold CE Fixes

`Manifold-CE-Fixes.lua` is an autorun script that carries workarounds for defects in Cheat
Engine itself that upstream has not fixed. Once installed it is loaded automatically every time
Cheat Engine starts.

## Highlights

Structure Dissect no longer raises an access violation on a middle click in the description
column. The row is selected as before; only the clipboard copy, which had no column to read, is
skipped. Middle clicks on value cells still copy the value.

Installation is reload safe, so re-running the autorun file neither stacks form notifications
nor wraps a window twice.

Every fix degrades visibly. When an API it needs is missing, the script prints one line and
installs nothing.

## Installation

Download `Manifold-CE-Fixes.lua` and place it in the autorun folder, which is usually
`C:\Program Files\Cheat Engine 7.5\autorun`. On a portable build, or if Cheat Engine was
installed elsewhere, the folder will be somewhere else.

To find it, run this in the Cheat Engine Lua console:

```lua
return getAutorunPath()
```

The console prints the full path. Place the script in that folder and Cheat Engine will load it
the next time it starts.

The write-up of each fix, including the cause in Cheat Engine's source and how to verify it, is
in [`docs/Manifold-CE-Fixes.md`](../docs/Manifold-CE-Fixes.md).
