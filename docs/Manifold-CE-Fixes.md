# Manifold CE Fixes

> File: [`Manifold-CE-Fixes/Manifold-CE-Fixes.lua`](../Manifold-CE-Fixes/Manifold-CE-Fixes.lua)
> Version: 1.0.0 · License: MIT · Author: Leunsel

A single autorun script with no dependencies. It carries workarounds for defects in Cheat Engine
itself that upstream has not fixed. It has nothing to do with the Manifold Framework and works on
its own. Every fix in it is self contained, survives being executed again from the Lua engine,
and degrades visibly: when an API it needs is missing it prints one line and installs nothing.

## 1. Installation

1. Download `Manifold-CE-Fixes.lua`.
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
call at the end of the file. On load it prints one line to the Lua engine:

```
[12:00:00] [Manifold-CE-Fixes] [Main] Structure Dissect middle-click guard armed.
```

### Re-running it at runtime

The script is reload safe. It stores its runtime handles under the global key
`__MANIFOLD_CE_FIXES_RUNTIME__` in `_G`: the form notification and, per tree view, the guard
function it assigned. Executing the file again releases the previous notification, registers a
new one and walks the open windows. A window whose tree view already carries the guard is left
alone, because reading the event property back returns the very function that was assigned, so
identity settles it. A Structure Dissect window that was open before the script was first loaded
gets the guard on that walk.

## 2. Fix: Structure Dissect access violation on middle click

### 2.1 Symptom

Middle-clicking the description text of a row in Structure Dissect, the left column, raises an
access violation. With [Manifold Exception Handler](Manifold-ExceptionHandler.md) installed the
ledger shows this record on the `cheatengine-x86_64-SSE4-AVX2.exe` build of 7.5:

```
0xC0000005  read at 0x10
ExceptionAddress 0x006EB130
0x006EB130 -> 0x006EE4BC -> 0x006EE835 -> 0x006F2F94
```

Middle-clicking a value cell does not fault, and neither does a right click anywhere.

### 2.2 Cause

`TfrmStructures2.tvStructureViewMouseDown` in `StructuresFrm2.pas` does three things for a
middle click: it focuses the column under the cursor, it selects the row the way a right click
does, and it copies the value of the cell to the clipboard. The column comes from
`getColumnAtXPos`, which walks the sections of `HeaderControl1` starting at index 1, because
section 0 is the `Offset-description` column and has no value column behind it. A click on the
description text, or right of the last column, therefore yields `nil`. The first use is guarded
(`if c<>nil then c.focus`), the clipboard branch is not: `getAddressFromNode(n, c, error)` reads
a field of the nil column at offset `0x10`.

Verified against the 7.5 source and the shipped binary. The handler is unchanged in upstream
master as of 2026-09-02.

### 2.3 What the guard does

The script wraps `tvStructureView.OnMouseDown` on every Structure Dissect window. The wrapper
mirrors the form's column lookup, and when a middle click has no column under it, it hands the
click to the original handler as a right click. The middle-button branch without the clipboard
copy is exactly the right-button branch, so the row is still selected and nothing is
dereferenced.

| Click | Cheat Engine 7.5 | With the guard |
|---|---|---|
| Middle click on a value cell | Copies the value to the clipboard | Unchanged |
| Middle click on the description text, or right of the last column | Access violation | Selects the row, copies nothing |
| Right or middle click with Shift or Ctrl on an unselected row | Adds the row to the selection | Unchanged, see below |
| Every other click, key and wheel event | | Unchanged |

Two details keep the emulation faithful:

- **Column lookup.** The form tests `x + ScrolledLeft` against `Sections[i].Left..Right` for
  `i >= 1`, bounds inclusive. The wrapper computes the same thing: a section's `Left` is the sum
  of the widths before it, a hidden section has width 0, and the form keeps
  `HeaderControl1.Left` at `-ScrolledLeft`, so `x - HeaderControl1.Left` is the header coordinate
  the form itself would test. If the lookup fails for any reason the click is treated as unsafe
  and goes the right-click way, with one line in the Lua engine.
- **Shift state.** Cheat Engine's Lua bridge calls the original handler with an empty `Shift`
  set, so through any Lua wrapper the handler would select only the clicked row where the form
  adds it to the selection. For a right or middle click with Shift or Ctrl held, the wrapper finds
  the row under the cursor first, walking the displayed nodes the way `GetNodeAtY` does, and
  selects it with the same call the form makes. The handler then sees it selected and leaves the
  selection alone.

### 2.4 Limits

- Only the middle *button*. Wheel rotation goes through the LCL's own scrolling and never
  reaches this handler.
- A middle click on the description text copies nothing. Cheat Engine has no column to read
  there; the crash was the only outcome it ever had.
- If `isKeyPressed` is missing, Shift and Ctrl are not bridged and a modified right click
  selects only the clicked row. If `userDataToInteger` is missing, a reload wraps an open window
  a second time; the guard then runs twice, which is harmless.
- The script installs nothing and prints one line when `registerFormAddNotification` is missing,
  or when a Structure Dissect window offers neither `registerCreateCallback` nor
  `registerFirstShowCallback`.

### 2.5 Verifying

1. Open Structure Dissect on any process and dissect an address.
2. Middle-click the description text of a row. The row is selected and Cheat Engine keeps
   running.
3. Middle-click a value cell. The clipboard holds the value.
4. Hold Ctrl and right-click an unselected row. It is added to the selection.
5. With [Manifold Exception Handler](Manifold-ExceptionHandler.md) active, the ledger shows no
   `0x006EB130` record for these clicks.

## 3. How the hook attaches

`registerFormAddNotification` fires from `Screen.AddForm` inside `TCustomForm.CreateNew`, which
is before the form's resource is streamed, so `tvStructureView` does not exist yet at that
moment. The script therefore registers a create callback on the form. That callback runs from
`DoCreate`, after streaming and after `FormCreate`, and installs the wrapper. It is deliberately
not unregistered from inside itself, because `unregisterCreateCallback` frees the caller object
that is still executing.

The wrapper receives `(sender, button, x, y)` from Cheat Engine and forwards exactly four
arguments, which is the shape the bridge's native caller requires. It also accepts the LCL's
five-argument shape and takes the coordinates as the last two numbers.

## 4. Adding a fix

Each fix needs three things: an install function that is safe to call twice on the same object,
a way to recognise that the object already carries the fix, and one log tag. Keep the shape of
the Structure Dissect guard, call the fix from `Main()`, and add a section to this document.
