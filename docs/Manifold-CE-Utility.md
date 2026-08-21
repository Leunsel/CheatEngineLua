# Manifold CE Utility

> File: [`Manifold-CE-Utility/Manifold-CE-Utility.lua`](../Manifold-CE-Utility/Manifold-CE-Utility.lua)
> Version: 1.1.0 · License: MIT · Authors: Leunsel, LeFiXER

A single, dependency-free autorun script. It extends the **Cheat Engine UI itself** with a menu of
frequently used actions. It is unrelated to the Manifold Framework and the Template Loader and
works standalone.

---

## 1. Installation

1. Download `Manifold-CE-Utility.lua`.
2. Drop it into Cheat Engine's `autorun` folder, typically:

```
C:\Program Files\Cheat Engine 7.5\autorun
```

Portable builds keep that folder elsewhere. Find the correct path from the Cheat Engine Lua
console:

```lua
return getAutorunPath()
```

The script runs automatically on the next Cheat Engine start. Its entry point is the `Main()`
call at the end of the file.

### Re-running it at runtime

The script is **reload-safe**. It stores its runtime handles (menu item, timer) under the global
key `__MANIFOLD_CE_UTILITY_RUNTIME__` in `_G`. When re-executed from the Lua engine,
`DisposePreviousInstance()` tears down the previous timer and menu item before rebuilding.
Without that, every reload would stack another menu entry and another caption timer.

---

## 2. Menu structure

After startup an entry `[— Manifold —]` appears in Cheat Engine's main menu bar.

| Entry | Shortcut | Effect |
|---|---|---|
| **Open Lua Engine** | `Ctrl+L` | Shows the Lua engine window |
| **Open Memory Viewer** | — | Shows the memory viewer |
| *— separator —* | | |
| **Open Structure Dissect** | — | `createStructureForm(nil, nil, nil)` |
| **Generate Structure Records** | — | Builds memory records from a selected structure |
| **Remove All Structures** | — | Removes **all** global structures ⚠️ |
| *— separator —* | | |
| **Deactivate All Scripts** | `Ctrl+D` | Deactivates all active `vtAutoAssembler` entries ⚠️ |
| **Deactivate Everything** | `Ctrl+F` | Deactivates **every** active address list entry ⚠️ |
| **Normalize Cheat Table IDs** | — | Reassigns IDs 1..N, transactionally ⚠️ |
| *— separator —* | | |
| **Toggle Compact Mode** | `Ctrl+Shift+F` | Hides/shows `Panel5` and `Splitter1` |
| *— separator —* | | |
| **Open Autorun Folder** | — | Explorer in the `autorun` directory |
| **Open Process Folder** | — | Explorer in the attached process's directory |
| *— separator —* | | |
| **Session Settings** ▸ | — | Submenu, see below |

⚠️ = destructive action, guarded by a confirmation dialog by default.

### "Session Settings" submenu

| Entry | Effect |
|---|---|
| **Animate Caption** (checkbox) | Toggles the rotating menu caption |
| **Animation Speed** ▸ Slow (600 ms) / Normal (350 ms) / Fast (200 ms) | Timer interval |
| **Confirm Destructive Actions** (checkbox) | Toggles confirmation dialogs |
| *— separator —* | |
| **Reset Caption Animation** | Rebuilds the timer, resets the caption |

These settings apply to the **current Cheat Engine session only**. There is no persistence. For
permanent changes, edit the `Config` table at the top of the file.

> Note: the segment's own `README.md` mentions a "Manifold > Settings" menu. In the code the entry
> is actually named **"Session Settings"**.

---

## 3. Configuration

The `Config` table sits at the top of the file (from line 38):

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
| `HEADER_COLOR` | `0xD2FF00` | Colour of the structure root record |
| `ADDRESS_COLOR` | `0xADAD5A` | Colour of structure child records |
| `ENABLE_FORMAT` | `false` | Enables `FormatDisplayName` for field names |

`Config.Indices` is filled by `GetImageListAndIndices()` with bitmap indices taken from the main
form's image list. Missing bitmaps are skipped silently (`tryAdd` wraps each in `pcall`); the menu
then works without icons.

---

## 4. Internal structure

The file is a flat script built from local functions — there are no classes or `:New()` instances
like in the framework.

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

Checks `inMainThread()` and either calls `func` directly or through `synchronize(func)`.
Everything is wrapped in `pcall`; errors end up in `FailLog`. Returns `true` on success,
`false` on failure.

### 4.3 UI references

`RefreshUiReferences()` re-resolves these before every access:

| Variable | Source |
|---|---|
| `mf` | `getMainForm()` |
| `mainMenu` | `mf.Menu` |
| `mv` | `getMemoryViewForm()` |
| `le` | `getLuaEngine()` |
| `il` | `mf.ImageList` or `mf.mfImageList` (lazy, via `safeGetImageList()`) |
| `al` | `getAddressList()` (via `GetAddressListOrLog(tag)`) |

Every access is wrapped in `pcall`; a missing API produces a `FailLog` entry instead of a crash.

### 4.4 Confirmations

```lua
ConfirmDestructiveAction(action, affectedCount) --> boolean
```

- With `Config.ConfirmDestructiveActions == false` it returns `true` immediately.
- If the dialog API is missing (`messageDialog`, `mtConfirmation`, `mbYes`, `mbNo`, `mrYes`), the
  action is **blocked** (`false`) rather than executed unprompted — a deliberately conservative
  choice.
- The dialog always names the number of affected entries.

---

## 5. Function reference

All functions are `local`; there is no public API. This reference exists for readers who want to
modify the script.

### 5.1 Structure tools

| Function | Description |
|---|---|
| `RecordFactory.Create(parent, desc, addr, vartype, color, isHeader)` | Creates a memory record. With `isHeader` it sets `isAddressGroupHeader = true`, `OffsetCount = 1`, `Offset[0] = 0`. Returns the record or `nil`. |
| `FormatDisplayName(n)` | Cosmetic name cleanup: strips `[...]`, `b_`/`m_` prefixes, splits CamelCase, replaces `_` with spaces. Only active when `ENABLE_FORMAT = true`. |
| `SelectStructure()` | Shows `showSelectionList("Structure Selector", ...)` over all global structures and returns the chosen one. |
| `BuildStructureRecords(struct)` | Creates a root record `struct.Name` (`vtCustom`, `+0`, header) and one child `[OFFSET] — Name` per element at `+OFFSET`. Elements of type `vtPointer` become group headers themselves. A single `repaint` at the end. |
| `GenerateStructure()` | `SelectStructure()` + `BuildStructureRecords()` |
| `DeleteAllStructures()` | Iterates `getStructureCount()` backwards and calls `structure:removeFromGlobalStructureList()`. |

**Example output of `Generate Structure Records`:**

```
PlayerStruct                 (vtCustom, +0, header, 0xD2FF00)
├─ [0000] — health           (+0000)
├─ [0004] — stamina          (+0004)
└─ [0018] — pInventory       (+0018, header, because vtPointer)
```

### 5.2 Deactivation tools

| Function | Description |
|---|---|
| `CountActiveRecords(addressList, scriptsOnly)` | Counts active records; with `scriptsOnly`, only `vtAutoAssembler`. Feeds the number shown in the confirmation dialog. |
| `DeactivateActiveScripts()` | Sets `Active = false` on all active AA scripts (iterating backwards). |
| `DeactivateEverything()` | Same, without the type filter. |

Both iterate the address list **backwards** so that deactivating an entry does not shift the
indices of the entries that follow.

> Important: both set `Active = false` and therefore trigger the records' `[DISABLE]` sections.
> That differs from `AddressList.disableAllWithoutExecute()`, which the framework's
> `ProcessHandler` uses when the process disappears.

### 5.3 ID normalization

`NormalizeCheatTableIDs()` assigns IDs `1..N` to all records (recursively, including children) in
tree order. It runs **transactionally in three phases**:

```
1. Read all current IDs        → originalIds[]
                                 (an invalid value aborts before anything changes)
2. Find a collision-free temp range (FindTemporaryIdBase, base 1_000_000_000)
   → write temporaryIds[] to every record
3. Write finalIds[] = 1..N to every record
```

If phase 2 or 3 fails, `RestoreRecordIds()` first moves the records back into the temp range and
only then restores the original IDs — otherwise a partially written target sequence could collide
with the not-yet-overwritten original IDs.

Helpers:

| Function | Description |
|---|---|
| `CollectRecordsRecursive(rec, out, seen)` | Depth-first walk over `rec.Child[i]` / `rec[i]`, with cycle protection through `seen`. |
| `GetAllAddressListRecords(addressList)` | Collects all records including children in tree order. |
| `SetRecordId(record, id)` | Prefers `record.setID(id)`, falls back to `record.ID = id`. |
| `FindTemporaryIdBase(originalIds, count)` | Searches from `1_000_000_000` for a block of `count` free IDs up to `2^31-2`. |

### 5.4 Miscellaneous

| Function | Description |
|---|---|
| `OpenFolder(folder, tag)` | `ShellExecute(folder)` with error logging. |
| `OpenProcessFolder()` | Derives the folder from `enumModules()[1].PathToFile`. |
| `OpenAutorunFolder()` | `getAutorunPath()` |
| `ToggleControlVisibility(name)` | Inverts `mf[name].Visible`. |
| `ToggleCompactMode()` | Toggles `Panel5` and `Splitter1` in one main-thread call. |

### 5.5 Caption animation

```
StartCaptionAnimation()
 ├─ StopCaptionAnimation()          -- dispose the old timer
 ├─ SetMenuCaption(label)           -- Prefix .. label .. Suffix
 ├─ bail out if AnimatedCaption == false or #label < 2
 ├─ PrepareTicker(label)            -- tickerBuffer = " label "
 └─ createTimer → OnTimer: SetMenuCaption(RotateTicker())
```

`RotateTicker()` shifts the buffer cyclically by one character. An error inside the timer callback
stops the animation immediately instead of logging once per tick.

---

## 6. Customization recipes

**Change the menu caption and enable the animation:**

```lua
MenuCaption       = "Tools",
Prefix            = "« ",
Suffix            = " »",
AnimatedCaption   = true,
AnimationInterval = 250,
```

**Disable confirmations permanently** (not recommended):

```lua
ConfirmDestructiveActions = false,
```

**Add your own menu entry** — insert into `CreateUtilityEntries()`:

```lua
AddSubItem("My Entry", function()
    RunInMainThread(function()
        print("Hello from the Manifold menu")
    end)
end, Config.Indices.Toggle, "Ctrl+M")
```

`AddSubItem(caption, onclick, imageIndex, shortcut)` attaches under the root entry and
automatically wraps the handler in `pcall` + `FailLog`.

**Clean up structure field names cosmetically:**

```lua
local ENABLE_FORMAT = true
```
