# Manifold CE Utility

> File: [`Manifold-CE-Utility/Manifold-CE-Utility.lua`](../Manifold-CE-Utility/Manifold-CE-Utility.lua)
> Version: 1.1.0 · License: MIT · Authors: Leunsel, LeFiXER

A single autorun script with no dependencies. It extends the Cheat Engine user interface itself
with a menu of frequently used actions. It has nothing to do with the Manifold Framework or the
Template Loader and works on its own.

## 1. Installation

1. Download `Manifold-CE-Utility.lua`.
2. Drop it into Cheat Engine's `autorun` folder, typically:

```
C:\Program Files\Cheat Engine 7.5\autorun
```

Portable builds keep that folder somewhere else. You can find the correct path from the Cheat
Engine Lua console:

```lua
return getAutorunPath()
```

The script runs automatically on the next Cheat Engine start. Its entry point is the `Main()`
call at the end of the file.

### Re-running it at runtime

The script is reload-safe. It stores its runtime handles, the menu item and the caption timer,
under the global key `__MANIFOLD_CE_UTILITY_RUNTIME__` in `_G`. When the file is executed again
from the Lua engine, `DisposePreviousInstance()` tears the previous timer and menu item down
before rebuilding. The timer is disposed first, because its callback still holds a reference to
the old menu item. Without that step every reload would stack another menu entry and another
caption timer.

## 2. Menu structure

After startup an entry `[— Manifold —]` appears in Cheat Engine's main menu bar.

| Entry | Shortcut | Effect |
|---|---|---|
| Open Lua Engine | `Ctrl+L` | Shows the Lua engine window |
| Open Memory Viewer | | Shows the memory viewer |
| *(separator)* | | |
| Open Structure Dissect | | `createStructureForm(nil, nil, nil)` |
| Generate Structure Records | | Builds memory records from a selected structure |
| Remove All Structures | | Removes all global structures, destructive |
| *(separator)* | | |
| Deactivate All Scripts | `Ctrl+D` | Deactivates all active `vtAutoAssembler` entries, destructive |
| Deactivate Everything | `Ctrl+F` | Deactivates every active address list entry, destructive |
| Normalize Cheat Table IDs | | Reassigns IDs 1..N, transactionally, destructive |
| *(separator)* | | |
| Toggle Compact Mode | `Ctrl+Shift+F` | Hides and shows `Panel5` and `Splitter1` |
| *(separator)* | | |
| Open Autorun Folder | | Explorer in the `autorun` directory |
| Open Process Folder | | Explorer in the attached process's directory |
| *(separator)* | | |
| Session Settings | | Submenu, see below |

The four entries marked as destructive ask for confirmation before they run, as long as
`Config.ConfirmDestructiveActions` is left at its default.

### "Session Settings" submenu

| Entry | Effect |
|---|---|
| Animate Caption (check mark) | Toggles the rotating menu caption |
| Animation Speed, with Slow (600 ms), Normal (350 ms) and Fast (200 ms) | Timer interval |
| Confirm Destructive Actions (check mark) | Toggles the confirmation dialogs |
| *(separator)* | |
| Reset Caption Animation | Rebuilds the timer and resets the caption |

`RefreshSettingsMenu()` re-applies the check marks after every change. The three speed entries
are checked by comparing `Config.AnimationInterval` against 600, 350 and 200 exactly, so a
custom interval leaves all three unchecked.

These settings apply to the current Cheat Engine session only. There is no persistence. For a
permanent change, edit the `Config` table at the top of the file.

> Note: the segment's own `README.md` calls this menu "Manifold > Settings". In the code the
> entry is named "Session Settings".

## 3. Configuration

The `Config` table sits at the top of the file, starting at line 38:

```lua
local Config = {
    FontName = "Consolas",       -- currently unused
    FontSize = 9,                -- currently unused
    MenuCaption       = "Manifold",
    Prefix            = "[— ",
    Suffix            = " —]",
    AnimatedCaption   = false,
    AnimationInterval = 350,
    ConfirmDestructiveActions = true,
    Indices = { ... }            -- populated at runtime
}
```

Other relevant constants:

| Constant | Value | Meaning |
|---|---|---|
| `MIN_ANIMATION_INTERVAL` | `100` | Lower bound enforced by `NormalizeAnimationInterval` |
| `MAX_ANIMATION_INTERVAL` | `2000` | Upper bound |
| `RUNTIME_STATE_KEY` | `"__MANIFOLD_CE_UTILITY_RUNTIME__"` | Reload key in `_G` |
| `NORMALIZE_TMP_BASE` | `1000000000` | Start of the temporary ID range used by the normalizer |
| `HEADER_COLOR` | `0xD2FF00` | Colour of the structure root record |
| `ADDRESS_COLOR` | `0xADAD5A` | Colour of structure child records |
| `ENABLE_FORMAT` | `false` | Enables `FormatDisplayName` for field names |

`Config.Indices` is filled by `GetImageListAndIndices()`. It copies bitmaps off existing Cheat
Engine menu items, five from the memory view form and two from the main form, adds them to the
main form's image list and stores the resulting indices. Missing bitmaps are skipped silently,
because `tryAdd` wraps every `add` in `pcall`. The menu then works without those icons.

## 4. Internal structure

The file is a flat script built from local functions. There are no classes and no `:New()`
instances like in the framework.

### 4.1 Logging

Only failures are logged:

```lua
FailLog(tag, msg)  --> "[HH:MM:SS] [FAIL] [tag] msg"
```

Success messages go straight to `print` as `[OK] ...` or `[INFO] ...`.

### 4.2 Thread safety

```lua
RunInMainThread(func)
```

It checks `inMainThread()` and either calls `func` directly or hands it to `synchronize(func)`.
If `inMainThread` is unavailable or the call to it fails, the function assumes it is already on
the main thread. Everything is wrapped in `pcall` and errors end up in `FailLog`. It returns
`true` on success and `false` on failure, including the case where the argument is not a
function.

### 4.3 UI references

`RefreshUiReferences()` resolves the main form, the main menu, the memory view form and the Lua
engine. Callers invoke it again before they touch any of those, so a form that only appears
later is still picked up.

| Variable | Source |
|---|---|
| `mf` | `getMainForm()` |
| `mainMenu` | `mf.Menu` |
| `mv` | `getMemoryViewForm()` |
| `le` | `getLuaEngine()` |

Two more handles live outside that function. `il` is resolved on first use by
`safeGetImageList()`, which tries `mf.ImageList` and then `mf.mfImageList` and caches whichever
one it finds. `al` is set by `GetAddressListOrLog(tag)` from `getAddressList()` at the start of
every address list operation.

Every access is wrapped in `pcall`. A missing API produces a `FailLog` entry instead of a crash.

### 4.4 Confirmations

```lua
ConfirmDestructiveAction(action, affectedCount) --> boolean
```

- With `Config.ConfirmDestructiveActions == false` it returns `true` immediately.
- If the dialog API is missing (`messageDialog`, `mtConfirmation`, `mbYes`, `mbNo`, `mrYes`),
  the action is blocked and the function returns `false` rather than letting it run unprompted.
  That is a deliberately conservative choice.
- The dialog names the number of affected entries whenever the caller passes one, which all
  four callers do.

## 5. Function reference

All functions are `local` and there is no public API. This reference exists for readers who want
to modify the script.

### 5.1 Structure tools

| Function | Description |
|---|---|
| `RecordFactory.Create(parent, desc, addr, vartype, color, isHeader)` | Creates a memory record. With `isHeader` it sets `isAddressGroupHeader = true`, `OffsetCount = 1` and `Offset[0] = 0`. Returns the record or `nil`. |
| `FormatDisplayName(n)` | Cosmetic name cleanup, only active when `ENABLE_FORMAT = true`. See the note below. |
| `SelectStructure()` | Shows `showSelectionList("Structure Selector", "Choose a Structure", list, false)` over all named global structures and returns the chosen one. |
| `BuildStructureRecords(struct)` | Creates a root record named after `struct.Name` (`vtCustom`, `+0`, header) and one child `[OFFSET] — Name` per element at `+OFFSET`. Elements of type `vtPointer` become group headers themselves. A single `repaint` at the end. |
| `GenerateStructure()` | `SelectStructure()` followed by `BuildStructureRecords()` |
| `DeleteAllStructures()` | Iterates `getStructureCount()` backwards and calls `structure:removeFromGlobalStructureList()`. |

`FormatDisplayName` removes balanced `[...]` groups, collapses runs of whitespace, keeps at most
the last two word tokens, splits CamelCase into separate words, replaces underscores with spaces
and uppercases the first letter. The gsub that is meant to strip a leading `b_` or `m_` is
written as `(?:[Bb]_?|m_)`, which is regular expression syntax that Lua patterns do not
understand, so that one step never fires on a real field name.

Example output of Generate Structure Records:

```
PlayerStruct                 (vtCustom, +0, header, 0xD2FF00)
├─ [0000] — health           (+0000)
├─ [0004] — stamina          (+0004)
└─ [0018] — pInventory       (+0018, header, because vtPointer)
```

### 5.2 Deactivation tools

| Function | Description |
|---|---|
| `CountActiveRecords(addressList, scriptsOnly)` | Counts active records. With `scriptsOnly` only `vtAutoAssembler` entries count. Feeds the number shown in the confirmation dialog. |
| `DeactivateActiveScripts()` | Sets `Active = false` on all active AA scripts, iterating backwards. |
| `DeactivateEverything()` | The same, without the type filter. |

Both iterate the address list backwards, so that deactivating an entry does not shift the
indices of the entries that follow. If the count comes back as zero they print an informational
line and return without showing a dialog.

> Important: both set `Active = false` and therefore trigger the records' `[DISABLE]` sections.
> That differs from `AddressList.disableAllWithoutExecute()`, which the framework's
> `ProcessHandler` uses when the attached process disappears.

### 5.3 ID normalization

`NormalizeCheatTableIDs()` assigns the IDs `1..N` to all records, recursively including
children, in tree order. It runs transactionally in three phases:

```
1. Read all current IDs        → originalIds[]
                                 (an invalid value aborts before anything changes)
2. Find a collision-free temp range (FindTemporaryIdBase, base 1_000_000_000)
   → write temporaryIds[] to every record
3. Write finalIds[] = 1..N to every record
```

If phase 2 or 3 fails, `RestoreRecordIds()` first moves the records back into the temporary
range and only then restores the original IDs. Otherwise a partially written target sequence
could collide with the original IDs that have not been overwritten yet.

Helpers:

| Function | Description |
|---|---|
| `CollectRecordsRecursive(rec, out, seen)` | Depth-first walk over `rec.Child[i]` or `rec[i]`, using `rec.Count` as the child count, with cycle protection through `seen`. |
| `GetAllAddressListRecords(addressList)` | Collects all records including children in tree order. |
| `SetRecordId(record, id)` | Prefers `record.setID(id)`, falls back to `record.ID = id`. |
| `FindTemporaryIdBase(originalIds, count)` | Searches from `1_000_000_000` for a block of `count` free IDs up to `2^31-2`. |

### 5.4 Miscellaneous

| Function | Description |
|---|---|
| `OpenFolder(folder, tag)` | `ShellExecute(folder)` with error logging. |
| `OpenProcessFolder()` | Derives the folder from `enumModules()[1].PathToFile`. |
| `OpenAutorunFolder()` | Opens whatever `getAutorunPath()` returns. |
| `ToggleControlVisibility(name)` | Inverts `mf[name].Visible`. |
| `ToggleCompactMode()` | Toggles `Panel5` and `Splitter1` in one main thread call. |

### 5.5 Caption animation

```
StartCaptionAnimation()
 ├─ StopCaptionAnimation()          -- dispose the old timer
 ├─ SetMenuCaption(label)           -- Prefix .. label .. Suffix
 ├─ bail out if AnimatedCaption == false or #label < 2
 ├─ PrepareTicker(label)            -- tickerBuffer = " label "
 └─ createTimer → OnTimer: SetMenuCaption(RotateTicker())
```

`RotateTicker()` shifts the buffer cyclically by one character. An error inside the timer
callback stops the animation immediately instead of logging once per tick. The interval goes
through `NormalizeAnimationInterval` before the timer is created, so it always ends up between
100 and 2000 milliseconds.

## 6. Customization recipes

Change the menu caption and enable the animation:

```lua
MenuCaption       = "Tools",
Prefix            = "« ",
Suffix            = " »",
AnimatedCaption   = true,
AnimationInterval = 250,
```

Disable confirmations permanently, which is not recommended:

```lua
ConfirmDestructiveActions = false,
```

Add your own menu entry by inserting into `CreateUtilityEntries()`:

```lua
AddSubItem("My Entry", function()
    RunInMainThread(function()
        print("Hello from the Manifold menu")
    end)
end, Config.Indices.Toggle, "Ctrl+M")
```

`AddSubItem(caption, onclick, imageIndex, shortcut)` attaches the item under the root entry and
automatically wraps the handler in `pcall` and `FailLog`.

Clean up structure field names cosmetically:

```lua
local ENABLE_FORMAT = true
```
