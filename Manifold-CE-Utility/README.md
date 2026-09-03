# Manifold CE Utility

`Manifold-CE-Utility.lua` is an autorun extension for Cheat Engine that adds a `[— Manifold —]`
entry to the main menu bar with the actions that come up every day: turning a dissected
structure into memory records, deactivating every script at once, renumbering the table's IDs,
and opening the windows and folders that are otherwise three clicks away.

## Highlights

**Generate Structure Records** builds a proper record tree from a global structure. Only the
elements you labelled in Structure Dissect become records, because a dissected structure of a few
thousand bytes has an element per offset and generating one record each buries the address list.
On a real table that is 3657 records down to 13; where a structure is labelled throughout, as one
filled from a Unreal Engine dump is, almost nothing is dropped. An unlabelled element that holds
labelled ones survives as their container, and **Settings › Include Unnamed Elements** brings the
rest back.

The root is an address group header at the base you enter, every element hangs under it with a
relative `+offset` address, strings and byte arrays carry their length, hexadecimal and signed
display flags are kept, and a pointer to another structure becomes a header with one offset whose
children resolve against the structure it points to, while an inline nested structure becomes a
header without one. Nesting stops at a configurable depth and at cycles. When a Structure Dissect
window for that structure is open, its address is what the dialog offers.

Every action is also a method on `ManifoldCEUtility`, so a table's Lua script or the Lua console
can drive it without the menu.

Destructive actions ask first and show the number of entries they touch. The ID normalizer is
transactional: it moves every record through a temporary range so no ID ever collides, and a
failure in either phase puts back exactly the records that changed.

Four settings persist between Cheat Engine sessions through `getSettings()`: the caption
animation, its speed, whether to confirm destructive actions, and whether unlabelled structure
elements become records.

The menu carries its own 16x16 icon set and never modifies Cheat Engine's own image list.
Re-running the file rebuilds the menu from fresh module code; the previous generation's menu,
timer and image list are taken down first.

Log lines go to [Manifold Logger](../Manifold-Logger) under the channel `CE Utility` when it is
installed, and fall back to `print` otherwise.

![Preview](https://i.imgur.com/34oPdGt.png)

## Installation

Place `Manifold-CE-Utility.lua` **and** the `Manifold-CE-Utility-Modules` folder next to each
other in the autorun folder, which is usually `C:\Program Files\Cheat Engine 7.5\autorun`. On a
portable build, or if Cheat Engine was installed elsewhere, the folder will be somewhere else.

To find it, run this in the Cheat Engine Lua console:

```lua
return getAutorunPath()
```

The layout in the autorun folder has to be:

```
autorun/
  Manifold-CE-Utility.lua
  Manifold-CE-Utility-Modules/
    Manifold-CE-Utility-CE.lua
    Manifold-CE-Utility-Host.lua
    Manifold-CE-Utility-Icons.lua
    Manifold-CE-Utility-Log.lua
    Manifold-CE-Utility-Menu.lua
    Manifold-CE-Utility-Records.lua
    Manifold-CE-Utility-Settings.lua
    Manifold-CE-Utility-Shell.lua
    Manifold-CE-Utility-Structures.lua
    Manifold-CE-Utility-Version.lua
    Manifold-Icons/
```

## The menu

| Entry | Shortcut | Effect |
|---|---|---|
| Open Lua Engine | `Ctrl+L` | Shows the Lua Engine window |
| Open Memory Viewer | | Shows the Memory Viewer |
| Open Structure Dissect | | Opens an empty Structure Dissect window |
| Generate Structure Records | | Asks for a structure and a base, builds the record tree |
| Remove All Structures | | Removes every global structure, destructive |
| Open Table File Viewer | | Opens [Manifold Table Files](../Manifold-TableFiles), if installed |
| Open Log Console | | Opens the [Manifold Logger](../Manifold-Logger) console, if installed |
| Deactivate All Scripts | `Ctrl+D` | Deactivates every active Auto Assembler script, destructive |
| Deactivate Everything | `Ctrl+F` | Deactivates every active record, destructive |
| Normalize Cheat Table IDs | | Renumbers every record 1..N in tree order, destructive |
| Toggle Compact Mode | `Ctrl+Shift+F` | Hides and shows the scanner half of the main form |
| Open Autorun Folder | | Explorer in the autorun directory |
| Open Process Folder | | Explorer in the attached process's directory |
| Settings | | Caption animation, its speed, confirmations, unlabelled elements |
| About | | Version, what is installed, where the log goes |

The shortcuts and the caption are defaults in `Manifold-CE-Utility-Settings.lua` and can be
overridden where the host is built in `Manifold-CE-Utility.lua`:

```lua
local host = Host:New({
    Settings = { MenuCaption = "Tools", Shortcuts = { LuaEngine = "Ctrl+Shift+L" } }
})
```

## Without the menu

```lua
ManifoldCEUtility:GenerateStructureRecords()
ManifoldCEUtility:DeactivateEverything()
ManifoldCEUtility:NormalizeIDs()
ManifoldCEUtility:SetCompactMode(true)
ManifoldCEUtility:Status()
ManifoldCEUtility:Reinstall()
```

The full reference is in [`docs/Manifold-CE-Utility.md`](../docs/Manifold-CE-Utility.md).
