# Manifold CE Utility

`Manifold-CE-Utility.lua` is an extension for Cheat Engine that adds quality of life helpers,
wrapper functions and utility routines for the Cheat Engine Lua API. Once installed it is loaded
automatically every time Cheat Engine starts.

## Highlights

Menu initialization is reload safe, so re-running the autorun file does not accumulate caption
timers or menu entries.

Destructive bulk actions ask for confirmation, which is enabled by default.

Cheat Table ID normalization is transactional and rolls back if a write fails.

Caption animation and the confirmation prompts can be changed from the menu while Cheat Engine is
running.

![Preview](https://i.imgur.com/34oPdGt.png)

## Installation

Download `Manifold-CE-Utility.lua` and place it in the autorun folder, which is usually
`C:\Program Files\Cheat Engine 7.5\autorun`. On a portable build, or if Cheat Engine was
installed elsewhere, the folder will be somewhere else.

To find it, run this in the Cheat Engine Lua console:

```lua
return getAutorunPath()
```

The console prints the full path. Place the script in that folder and Cheat Engine will load it
the next time it starts.

## Runtime settings

Open the Manifold submenu and then Settings to enable or disable the animated caption, choose a
speed, reset its position, or toggle confirmations for destructive actions. These choices apply
to the current Cheat Engine session. The defaults are defined at the top of
`Manifold-CE-Utility.lua`.

With confirmations enabled, these actions show the number of affected entries before proceeding:

- Remove all global structures
- Deactivate all Auto Assembler scripts
- Deactivate every active address list entry
- Normalize Cheat Table IDs
