# Manifold CE Utility

> File: [`Manifold-CE-Utility/Manifold-CE-Utility.lua`](../Manifold-CE-Utility/Manifold-CE-Utility.lua)
> Version: 2.0.0 · License: MIT · Authors: Leunsel, LeFiXER

An autorun segment that extends the Cheat Engine user interface itself with a menu of
frequently used actions. It has no dependency on the Manifold Framework and works on its own.
Two optional couplings: it logs through [Manifold Logger](Manifold-Logger.md) when that is
installed, and it contributes the menu entries that open [Manifold Table Files](Manifold-TableFiles.md)
and the Logger's console.

Version 2.0.0 is a rewrite. The 1.x file was one flat script; 2.0.0 is an entry file plus a
`-Modules` folder of `:New()` classes with dependency injection, the same shape as the Logger and
Table Files segments. The reasons are in section 8.

## 1. Installation

Place `Manifold-CE-Utility.lua` **and** the `Manifold-CE-Utility-Modules` folder next to each
other in Cheat Engine's `autorun` folder, typically:

```
C:\Program Files\Cheat Engine 7.5\autorun
```

Portable builds keep that folder somewhere else. The Lua console tells you where:

```lua
return getAutorunPath()
```

The layout:

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
    Manifold-Icons/            fourteen 16x16 PNGs
```

The script runs on the next Cheat Engine start and publishes `ManifoldCEUtility`.

### Re-running it at runtime

Executing the entry file again from the Lua Engine rebuilds everything from fresh module code.
The previous generation is taken down first: its menu and caption timer through `Uninstall`, its
image list explicitly, because `Icons` keeps that list in a module-local upvalue and dropping the
module from `package.loaded` would otherwise orphan a live `TImageList`. Nothing accumulates; the
startup line reads `re-executed` instead of `ready`.

A live 1.x instance is taken down the same way. 1.x kept its root item and caption timer,
untagged, in `_G.__MANIFOLD_CE_UTILITY_RUNTIME__`; both are destroyed before 2.0 builds, so
2.0 can be executed over a running 1.x without restarting Cheat Engine. Its image list is left
alone: 1.x borrowed Cheat Engine's own.

Two lighter operations exist without re-executing the file:

```lua
ManifoldCEUtility:Reinstall()   -- rebuilds the menu, keeps the modules
ManifoldCEUtility:Shutdown()    -- removes the menu, releases the globals
```

## 2. The menu

The entry `[— Manifold —]` appears in the main menu bar.

| Entry | Shortcut | Effect |
|---|---|---|
| Open Lua Engine | `Ctrl+L` | Shows the Lua Engine window |
| Open Memory Viewer | | Shows the Memory Viewer |
| *(separator)* | | |
| Open Structure Dissect | | `createStructureForm(nil, nil, nil)` |
| Generate Structure Records | | Section 3 |
| Remove All Structures | | Removes every global structure, destructive |
| Open Table File Viewer | | `ManifoldTableFiles:Open()`, with an install hint when absent |
| Open Log Console | | `ManifoldLogger:Open()`, with an install hint when absent |
| *(separator)* | | |
| Deactivate All Scripts | `Ctrl+D` | `Active = false` on every active `vtAutoAssembler` record, destructive |
| Deactivate Everything | `Ctrl+F` | `Active = false` on every active record, destructive |
| Normalize Cheat Table IDs | | Renumbers 1..N in tree order, transactionally, destructive |
| *(separator)* | | |
| Toggle Compact Mode | `Ctrl+Shift+F` | Hides and shows `Panel5` and `Splitter1` on the main form |
| *(separator)* | | |
| Open Autorun Folder | | Explorer in the `autorun` directory |
| Open Process Folder | | Explorer in the attached process's directory |
| *(separator)* | | |
| Settings | | Submenu, below |
| About | | Version and status, section 7 |

The four destructive entries ask for confirmation and name the number of entries they touch, as
long as "Confirm Destructive Actions" is on. A missing dialog API blocks the action rather than
letting it run unprompted.

### The Settings submenu

| Entry | Effect |
|---|---|
| Animate Caption (check mark) | Rotates the menu caption |
| Animation Speed › Slow (600 ms), Normal (350 ms), Fast (200 ms) | Timer interval |
| Confirm Destructive Actions (check mark) | The confirmation dialogs |
| Include Unnamed Elements (check mark) | Off, Generate Structure Records creates a record only for the elements labelled in Structure Dissect. On, for every element. Section 3.3 |
| *(separator)* | |
| Reset Caption Animation | Rebuilds the timer and resets the caption |

These three settings persist between Cheat Engine sessions, section 5.

## 3. Generate Structure Records

The flow:

1. A selection list of every global structure. Unnamed structures are offered as
   `(unnamed structure #n)` rather than dropped, and the choice maps back through an index table,
   so an unnamed structure in the middle of the list no longer shifts every later choice by one.
2. An input dialog for the base address. When a Structure Dissect window for that structure is
   open, its first column's address is what the dialog offers; otherwise `+0`. Any interpretable
   address string works: a number, a symbol, a pointer path.
3. The plan: plain tables describing every record, section 3.2. Unlabelled
   elements are pruned out of it unless "Include Unnamed Elements" is on,
   section 3.3.
4. The records are created on the main thread, the root is selected, the main form repainted,
   and a summary block is logged.

### 3.1 What is generated

```
Player                               address group header, Address = <base>
├─ [0000] — health                   +0        4 Bytes
├─ [0004] — stamina                  +4        Float
├─ [0008] — name                     +8        String, Size 16
├─ [0018] — flags                    +18       4 Bytes, hexadecimal
└─ [0020] — inventory -> Inventory   +20       header, OffsetCount 1, Offset[0] 0
   ├─ [0000] — count                 +0        (element offset minus ChildStructStart)
   └─ [0008] — items                 +8
```

A child's `+offset` is relative to its parent's resolved address, which is how Cheat Engine's
own relative addresses work. That is also why `+0` is a usable root address: the whole block can
be dropped under any pointer record afterwards.

A pointer element with a `ChildStruct` becomes an address group header with one offset of `0`,
so its children resolve against the structure it points to. A child structure entered at
`ChildStructStart` gets its element offsets shifted by that amount; an element below the entry
point comes out as a negative relative address such as `-8`.

### 3.2 Type mapping

| Element `Vartype` | Record |
|---|---|
| Byte, 2 Bytes, 4 Bytes, 8 Bytes, Float, Double | The same type |
| `vtString` | `vtString`, `String.Size = Bytesize` |
| `vtWideString` / `vtUnicodeString` | `vtString`, `String.Unicode = true`, `String.Size = Bytesize / 2` |
| `vtByteArray` | `vtByteArray`, `Aob.Size = Bytesize` |
| `vtBinary` | `vtBinary`, `Binary.Startbit = 0`, `Binary.Size = min(Bytesize * 8, 32)` |
| `vtPointer` with `ChildStruct` | Address group header with `Offset[0] = 0` and the child's elements underneath |
| `vtPointer` with `ChildStruct` and `NestedStructure` | Address group header without offsets: the child is laid out inline at the element's offset and its elements are relative to it |
| `vtPointer` without | `vtQword` on a 64-bit target, `vtDword` on 32-bit, shown as hex |
| `vtCustom` with a `CustomType` whose `name` is set | `vtCustom` with that name |
| `vtCustom` without | `vtByteArray` of `Bytesize`, counted as "kept as bytes" |
| anything else | `vtByteArray` of `Bytesize` |

`DisplayMethod` `dtHexadecimal` sets `ShowAsHex`, `dtSignedInteger` sets `ShowAsSigned`.

### 3.3 Only labelled elements

Structure Dissect creates an element for every offset it walks. A structure of a few thousand
bytes therefore carries a few thousand elements, and on an auto-created one almost none of them
have a name. Generating a record for each buried the address list, so by default only the
elements you actually labelled in the dissect window become records.

Measured against real tables in this repository's author's collection:

| Structure | Elements | Records, all | Records, labelled only |
|---|---|---|---|
| `SettingsDI`, Dying Light 2 | 3656 | 3657 | 13 |
| `Health`, Rift Apart | 1765 | 1766 | 5 |
| `DamagePacket`, Rift Apart | 3348 | 3349 | 266 |
| `CH_P_EVE_01_Blueprint_C`, Stellar Blade | 130 | 131 | 113 |

The last row is the point of the rule working in both directions: a structure filled from a
Unreal Engine dump is labelled throughout, and almost nothing is dropped.

An unlabelled element is kept when something labelled hangs under it, so naming a field inside
an unlabelled pointer never loses it. Such a container keeps its type-derived description,
`[0008] — Pointer -> Inner`, and is counted separately in the summary.

When a structure has no labelled elements at all, nothing is created and the report says how
many elements were skipped and where the switch is. Turn on **Settings › Include Unnamed
Elements** to get a record per element; unlabelled ones are then described by their type,
`[0050] — Byte`.

### 3.4 Depth and cycles

Nesting stops at `Structures.MaxDepth` levels below the root (default 4) and at a cycle, a
structure that is already on the path being expanded. In both cases the pointer becomes a plain
hex value whose description names the target and the reason: `-> Inventory (depth limit)` or
`-> Player (cycle)`. An inline nested structure that hits a limit stays a header with nothing
under it, marked `(inline, depth limit)` or `(inline, cycle)`, since a pointer-sized value would
misdescribe inline bytes.

### 3.5 The summary

```
Structure records generated
  Structure           : Player
  Base                : game.exe+10
  Records             : 13
  Pointers            : 3
  Nested structures   : 1
  Unlabelled, skipped : 1
  Not expanded        : 1 (depth limit or cycle)
```

Rows that would read zero are left out. A failure mid-way reports how many of the planned
records were created and what stopped it; the records made so far stay in the table.

## 4. The other actions

**Remove All Structures** walks `getStructureCount()` backwards calling
`removeFromGlobalStructureList()` on each, so an index stays valid after the one above it is gone.

**Deactivate All Scripts** and **Deactivate Everything** collect every record, children
included, and set `Active = false` backwards, children before parents. That runs each record's
`[DISABLE]` section; it is the button for bringing a table to a known state with its hooks
removed. The framework's `ProcessHandler` uses `disableAllWithoutExecute()` for the opposite
case, a process that is already gone. A record that refuses is counted and reported; the rest are
still deactivated.

**Normalize Cheat Table IDs** assigns 1..N in tree order in three phases: read every ID (an
unreadable one aborts before anything changes), move every record into a temporary range no
current ID occupies, then write 1..N. Cheat Engine keeps IDs unique, which is why the temporary
range exists: writing 1..N straight over the originals would collide with any original that is a
small number. A failure in either phase puts back exactly the records that changed, parking the
ones already holding a final ID in the temporary range first for the same reason. The confirmation
dialog says what stops matching afterwards: Manifold state files, table Lua using
`getMemoryRecordByID`, hotkeys and scripts given an ID.

**Toggle Compact Mode** flips `Visible` on `Panel5` and `Splitter1`, the same two controls the
framework's `Manifold.UI:EnableCompactMode` touches.

**Open Process Folder** takes `enumModules()[1].PathToFile` and opens its directory. With no
process attached it says so instead of opening nothing.

## 5. Settings

`Manifold-CE-Utility-Settings.lua` holds the defaults:

```lua
MenuCaption = "Manifold",  Prefix = "[— ",  Suffix = " —]",
AnimatedCaption = false,  AnimationInterval = 350,          -- clamped to 100..2000
ConfirmDestructiveActions = true,
Persist = true,
Shortcuts = { LuaEngine = "Ctrl+L", MemoryViewer = "", DeactivateScripts = "Ctrl+D",
              DeactivateEverything = "Ctrl+F", CompactMode = "Ctrl+Shift+F" },
Structures = { HeaderColor = 0xD2FF00, ElementColor = 0xADAD5A, PointerColor = 0x61CDEA,
               MaxDepth = 4, IncludeUnnamed = false, OffsetInDescription = true, DefaultBase = "+0" }
```

Override any of them where the host is built in the entry file. Nested tables merge, so one
shortcut can be changed without restating the others:

```lua
local host = Host:New({
    Settings = { MenuCaption = "Tools", Shortcuts = { LuaEngine = "Ctrl+Shift+L" } }
})
```

### 5.1 Persistence

`AnimatedCaption`, `AnimationInterval`, `ConfirmDestructiveActions` and
`Structures.IncludeUnnamed` are written through `getSettings("Manifold CE Utility")` whenever the
menu changes them and read back on the next start. A dotted key reaches into a nested table and
is stored under that name, dot included. Values are stored as strings (`"1"` / `"0"` for booleans) and decoded against the type of
the default, so a damaged registry value falls back to the default instead of turning a boolean
into a string. Cheat Engine answers an empty string, never nil, for a value that was never
written; that is treated as absent, so a fresh install keeps every default. `Persist = false`
keeps everything for the session only, which is what 1.x did.

## 6. Logging

Lines go to the Manifold Logger channel `CE Utility` when `ManifoldLogger` exists, and to a
timestamped `print` otherwise:

```
[19:47:50] [INFO] [CE Utility] Compact mode on.
```

The channel is resolved on every call and re-resolved when the Logger host is rebuilt, so a
`ManifoldLogger:Shutdown()` followed by a re-execution of the Logger never leaves this segment
writing into a buffer no window shows. Multi-row reports use the Logger's `Block` renderer when
it is there and an aligned fallback when it is not.

## 7. The public object

`ManifoldCEUtility` is the host. Everything the menu does is a method on it:

```lua
ManifoldCEUtility:GenerateStructureRecords()      -- returns ok, rootRecord
ManifoldCEUtility:RemoveAllStructures()
ManifoldCEUtility:DeactivateScripts()
ManifoldCEUtility:DeactivateEverything()
ManifoldCEUtility:NormalizeIDs()
ManifoldCEUtility:ToggleCompactMode()
ManifoldCEUtility:SetCompactMode(true)
ManifoldCEUtility:OpenLuaEngine()                 -- also OpenMemoryViewer, OpenStructureDissect,
                                                  -- OpenTableFiles, OpenLogConsole,
                                                  -- OpenAutorunFolder, OpenProcessFolder
ManifoldCEUtility:SetAnimatedCaption(true)
ManifoldCEUtility:SetAnimationInterval(200)
ManifoldCEUtility:SetConfirmDestructiveActions(false)
ManifoldCEUtility:SetIncludeUnnamed(true)         -- every element, not only the labelled ones
ManifoldCEUtility:Status()                        -- a table
ManifoldCEUtility:About()                         -- logs the status block and shows it
ManifoldCEUtility:Reinstall()
ManifoldCEUtility:Shutdown()
```

`About` logs the block and makes sure it can be seen: it opens the Logger console when lines go
there, and shows a message box otherwise.

## 8. Internal structure

| Module | Owns |
|---|---|
| `-CE` | Defensive wrappers: `Call`, `Get`, `RunInMain`, `Confirm`, `Input`, `Shell`, and the form and address list accessors. Every global is looked up at call time. |
| `-Log` | The Logger channel or the `print` fallback, and `Block`. |
| `-Settings` | Defaults, overrides, clamping, the registry store. |
| `-Icons` | The 16x16 set: one `TImageList` per session, attached to the root item's `SubMenuImages`. |
| `-Structures` | `List`, `Select`, `SuggestBase`, `Plan` (plan, prune, tally), `Materialize`, `Generate`, `RemoveAll`. |
| `-Records` | `Collect`, `Active`, `Deactivate`, `FreeRange`, `Assign`, `Restore`, `NormalizeIDs`. |
| `-Shell` | Windows, folders, compact mode. |
| `-Menu` | The root entry built from the host's spec, check marks, the Tag sweep, the ticker. |
| `-Host` | Wiring, the menu spec, the settings actions, `Status`, `About`, `Shutdown`. |
| `-Version` | The version number. |

### Why the rewrite

The 1.x "Generate Structure Records" built records straight off the structure and got most of it
wrong: the address list handle was only fetched by the deactivation actions, so on a fresh session
the generator failed with "AddressList handle unavailable"; the selection list skipped unnamed
structures but used the list index against `getStructure`, so one unnamed structure shifted every
choice after it; strings and byte arrays never got their size; the root was `vtCustom` with no
custom type name at `+0`; a pointer element became a group header with a pointer offset whether or
not it pointed at a structure, and a child structure was never expanded; the cosmetic name
formatter used regular-expression syntax Lua patterns do not have. And it generated a record for
every element of the structure, which on a dissected one of a few thousand bytes meant a few
thousand records. The menu icons were bitmaps
borrowed off Cheat Engine's own menu items and pushed into the main form's image list on every
execution, and which ones existed depended on which forms had been built yet.

2.0.0 separates planning from creation so the interesting part is testable without Cheat Engine,
carries its own icon set, and follows the segment layout the Logger and Table Files established.

### Cheat Engine facts the code depends on

* `TMenuItem` has no `ImageList` property. Children resolve `ImageIndex` against the nearest
  ancestor's `SubMenuImages`, so the list is attached to the root item once. `SetImageIndex`
  early-exits on an unchanged value, so `-1` is written first.
* `createPNG(1, 1)` then `loadFromFile` is the way to load a PNG; `createBitmap` reads BMP only.
  `imagelist.add` never returns `-1`, so success is checked by watching `Count` rise.
* Cheat Engine hands out a fresh userdata per property access, so two handles to the same object
  do not compare equal. Structures are matched by name, records de-duplicated by ID.
* The address list's `Count` and `[]` index every record including children, in tree order. The
  walk follows `Child[]` as well, with a seen-set, so it is right either way.
* `getSettings().Value[key]` reads `""`, never nil, for a value that was never written.
* A structure element's custom type is reachable as `element.CustomType.name`, and
  `element.NestedStructure` marks a child structure laid out inline rather than behind a pointer.
  Neither is in celua.txt; both are in the 7.5 sources.
* Every menu item carries `Tag = 1297374316`. Removal sweeps the main menu for that tag rather
  than trusting a kept reference, the pattern the Logger's `RemoveMenu` proved. The Logger and the
  Template Loader use their own values, so the three never remove each other's entries.
