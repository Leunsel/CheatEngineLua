# Manifold Address List

> File: [`Manifold-AddressList/Manifold-AddressList.lua`](../Manifold-AddressList/Manifold-AddressList.lua)
> Version: 1.0.0 · License: MIT · Authors: Leunsel, LeFiXER

An autorun segment that puts the open Cheat Table's address list into one window. The record tree
is on the left, an inspector with five pages is on the right, a results strip for problems and
matches is along the bottom, and everything works on the whole selection at once with an undo
history this window keeps for itself. Cheat Engine has no structural undo, no bulk edit, no way to
see every hotkey in a table and no way to ask what is broken. That is the gap this fills.

It has no dependency on the Manifold Framework. Three couplings exist and all three are optional.
It logs through [Manifold Logger](Manifold-Logger.md) on a channel named Address List when that is
installed, and falls back to a timestamped print when it is not. It reads
`forms.ActiveDesignTheme` when a Cheat Table has a live `Manifold.Forms`, so the window follows the
table's theme, and falls back to the bundled Bearded-Arc palette when there is none. And
[Manifold CE Utility](Manifold-CE-Utility.md) carries the menu entry that opens it, because this
segment registers no menu of its own.

Nothing here writes to a Cheat Table's files. Every edit goes into the live records, exactly as an
edit made in Cheat Engine's own list would, and saving the table stays Cheat Engine's job.

## 1. Installation

Place `Manifold-AddressList.lua` **and** the `Manifold-AddressList-Modules` folder next to each
other in Cheat Engine's autorun folder, typically:

```
C:\Program Files\Cheat Engine 7.5\autorun
```

Portable builds keep that folder somewhere else. The Lua console tells you where:

```lua
return getAutorunPath()
```

The layout is the entry file, the twenty-four modules and the icon folder:

```
autorun/
  Manifold-AddressList.lua
  Manifold-AddressList-Modules/
    Manifold-AddressList-CE.lua
    Manifold-AddressList-DropDown.lua
    Manifold-AddressList-Export.lua
    Manifold-AddressList-Grid.lua
    Manifold-AddressList-Host.lua
    Manifold-AddressList-Hotkeys.lua
    Manifold-AddressList-Icons.lua
    Manifold-AddressList-Inspector.lua
    Manifold-AddressList-Journal.lua
    Manifold-AddressList-Lint.lua
    Manifold-AddressList-Log.lua
    Manifold-AddressList-Pointer.lua
    Manifold-AddressList-Properties.lua
    Manifold-AddressList-Records.lua
    Manifold-AddressList-Results.lua
    Manifold-AddressList-Script.lua
    Manifold-AddressList-Search.lua
    Manifold-AddressList-Settings.lua
    Manifold-AddressList-Surface.lua
    Manifold-AddressList-Theme.lua
    Manifold-AddressList-Tree.lua
    Manifold-AddressList-Types.lua
    Manifold-AddressList-Version.lua
    Manifold-AddressList-Window.lua
    Manifold-Icons/
      Manifold-*.png
```

The script runs on the next Cheat Engine start and publishes the host twice under the same object,
as ManifoldAddressList for everyday use and as ManifoldAddressListHost for the entry file's own
takedown of a previous generation. The facade name is registered with `registerLuaFunctionHighlight`
when that function exists.

Nothing touches Cheat Engine while the host is being built, so autorun with no Cheat Table loaded
and no process attached is safe. The startup line is a block naming the version, the record count
Cheat Engine reports, the icon state and the settings that matter.

Copying only the entry file and forgetting the folder is the one mistake this can catch. The
require is wrapped, so it prints one line naming the folder and the directory it looked in instead
of a require traceback on every Cheat Engine start.

### Re-running it at runtime

Executing the entry file again from the Lua Engine rebuilds everything from fresh module code.
Cheat Engine's require is standard Lua require, so `package.loaded` survives a re-execution. The
order matters and is fixed. The previous host's `Uninstall` runs first, which closes its window
without asking a page whether it minds, stops both timers and destroys the surfaces, the tree, the
inspector and the form. Then the previous generation's icons are destroyed explicitly, because the
Icons module keeps its image list in a module local upvalue and dropping the module would orphan a
live TImageList with nineteen PNGs in it. Only then are the twenty-four module names dropped from
`package.loaded`, and the startup line reads re-executed instead of ready.

The undo history does not survive that. It belongs to the generation that made it, and a
transaction written by code that no longer exists is not something to replay.

## 2. Opening the window

With the CE Utility installed, **Manifold -> Open Address List**.

Otherwise, from the Lua console or a table's Lua script:

```lua
ManifoldAddressList:Open()
ManifoldAddressList:Toggle()
ManifoldAddressList:Close()
```

Open builds the window the first time and brings it forward afterwards. Either way it reads the
whole address list before the window is shown, because a tree drawn from half-loaded nodes shows
blank descriptions for a quarter of a second and looks broken. A first load slower than 150 ms
says `Reading 4120 records...` on the status line while it happens.

The restyle runs once **after** the first show rather than before it. Cheat Engine overwrites some
control colours when the window handle is created, which for a hidden form is at `show()`, so
colours applied earlier would be thrown away.

Close asks the active inspector page whether it is holding an unsaved edit. A page that is offers
Save, Discard and Cancel, and Cancel gives the window back. Only the active page can be holding
one, because switching pages already goes through the same gate.

## 3. The window

```
┌ Manifold — Address List  ·  1.0.0 ───────────────────────────────────────────────────────┐
│ [Refresh][Live] │ [Undo][Redo] │ [Find][Problems] │ [Export]  [filter........] [Menu]     │
├──────────────────────────────────┬───────────────────────────────────────────────────────┤
│ Records                    4120  │ Inspector                                  Properties │
│                                  │ [Properties][Pointer][Script][Drop-down][Hotkeys]     │
│  [x] Player                      │                                                       │
│      [ ] Health      4B  14A2B0  │  Identity                                             │
│      [x] Ammo    hk2 4B  14A2B4  │    Description        Health                          │
│  [ ] Weapons                 GRP │    Colour             Default                         │
│      [x] Infinite ammo    AA     │  Location                                             │
│                                  │    Address            game.exe+1A2B34                 │
├──────────────────────────────────┴───────────────────────────────────────────────────────┤
│ Results                                                                               12 │
│ ERR  Player > Ammo      The script has no [DISABLE] section, so activating it cannot ...  │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ 4120 records  ·  3 selected            21 groups | 44 scripts | 12 active | 12 problems   │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

Every list in this window is painted on a canvas rather than delegated to a control. Section 11
says why, in one sentence: Cheat Engine's Lua binding registers no custom draw event for a tree
view, publishes no hit test and offers no scroll box, so there is no control that can show a
record the way this window shows one. The canvas engine is a port of the Logger's log view, and
one Frame service owns every canvas in the window, ticking at 15 ms and painting only the ones
that marked themselves dirty. A tick is skipped entirely while the form is hidden or while
something modal is pumping messages.

The layout is built in the one order the LCL allows. alTop and alLeft put the **last** created
control outermost, alBottom and alRight put the **first** one outermost, so the build order is the
status bar, the results card, the results splitter, the find bar, the toolbar, the tree splitter,
the tree card and finally the inspector card. Getting that wrong does not look wrong in the source
at all, which is why the test suite asserts every edge.

### The record tree

One row per record, in Cheat Engine's own depth-first pre-order. A row carries, left to right, a
coloured edge when the problem check found something on that record, the indentation and the
expand arrow, the activation box, the description in the record's own colour, any badges, the type
tag, the address and the value.

- **The activation box** toggles the whole selection. A group header toggles like any other
  record, which is what Cheat Engine does with it.
- **The record's colour** is honoured, and pushed away from the row background until it is legible
  when a table picked a colour that reads against Cheat Engine's own list and not against this
  one. A record with no colour of its own draws in the theme's text colour. That is decided
  against `clWindowText` and the two values Cheat Engine stores for it, never against black.
- **Badges** sit at the end of the description rather than in a column of their own, because a
  record with a hotkey is the exception and a column would cost every row its width. `hk2` is two
  hotkeys, `dd` is a drop-down list, `lnk` is a drop-down list linked to another record.
- **The type tag** is `1B`, `2B`, `4B`, `8B`, `F`, `D`, `STR`, `WSTR`, `AOB`, `BIN`, `AA`, `CUS`
  or `GRP`, with a `P` in front on a record that has offsets, so a pointer to eight bytes is `P8B`.
  A type this segment does not know draws `?` rather than nothing, because a table written by a
  plugin can hold one.
- **The columns shrink before they disappear.** The description keeps the room whatever else has
  to go, because a record you cannot read the name of is useless.
- **The filter highlights what it matched**, in place, inside the description.

Identity is the record id throughout. The selection, the collapsed set, the focus and the scroll
position are all kept by id, so a refresh that moved every record leaves you looking at the same
records you were looking at.

The filter box takes a small language. Every token is an **and**. A bare word is a case
insensitive plain substring of the description and the address string, never a Lua pattern,
because a description full of brackets and percent signs is completely ordinary. Double quotes
keep spaces together, and a token that starts with a quote is text even when it carries a colon.

| Predicate | Matches |
|---|---|
| `type:4 bytes` | The type. Also `type:4b`, `type:dword`, `type:vtDword`, `type:aa`, `type:script` |
| `type:group` | A group header. Also `type:grp` |
| `type:pointer` | A record with offsets. Also `type:ptr` |
| `is:active` / `is:inactive` | Whether the record is on |
| `is:group` | A group header |
| `is:pointer` | A record with offsets |
| `is:script` | An Auto Assembler record |
| `is:dontsave` | The do not save flag |
| `is:linked` | A drop-down list taken from another record |
| `is:problem` | The problem check found something. Runs the check once when it has not run yet |
| `has:hotkey` | One or more hotkeys. `has:hotkeys` is the same |
| `has:dropdown` | A drop-down list of its own |
| `has:children` | A record with records under it |
| `has:color` | A colour of its own. `has:colour` is the same |
| `has:offsets` | The same set as `is:pointer` |
| `id:42` | One record, by id |

A record is visible when it matches, or when something under it does, so the ancestors of every
match come back with it. Those ancestors are shown open without touching what you collapsed by
hand, and clearing the filter puts your own collapsed set back exactly as it was.

### The inspector

Five tabs over the same selection: Properties, Pointer, Script, Drop-down and Hotkeys. Ctrl+1 to
Ctrl+5 reach them, and Ctrl+E and Ctrl+P are shortcuts to Script and Pointer. A tab whose page
cannot do anything with the current selection stays clickable and the page behind it draws an
empty state that says why, because a tab that greys itself out teaches nothing.

The card's header counter is the active page's title, and while the mouse sits over a grid row
with a hint it shows the hint instead. There is exactly one writer for that label, which is what
keeps it from flickering between a record name and a sentence.

**The Properties page** is the record schema in a grid, grouped into Identity, Location, Type,
State, Group and Advanced. It reads what the whole selection agrees on and shows `<mixed>` where
it does not, and it emits one transaction for the whole selection, so fourteen records change
under one undo entry. Rows carry the editor their property needs: text, a number with bounds, a
drop-down of the eleven editor types, a check box drawn by hand, a colour swatch that opens Cheat
Engine's picker, and read-only rows that show something worth seeing and refuse to be typed into.

Two rows behave unusually and say so in their hint.

- **Address is read only on a pointer record.** Writing `Address` on a record with offsets clears
  every offset, so the base of a pointer belongs to the Pointer page and the hint points there.
  One fact, one writer.
- **Readable only means anything once the value was read.** Cheat Engine sets `IsReadable` inside
  its own value getter and nowhere else, so the row reads the value of every subject record before
  it shows anything. Without that, a perfectly healthy record reports itself unreadable.

Live sync rebuilds these rows four times a second, so the rebuild is skipped outright while an
editor is open on a row and a refresh never discards what you typed. A commit happens on Enter, on
Tab, on a click on another row and on an explicit save, and never from a refresh. Losing focus
commits an ordinary row and cancels a dangerous one.

### The results strip

One strip at the bottom, three things in it, one at a time. The problem check writes its findings
there, Find all writes its hits there, and the Menu's Changes this session writes the transactions
this window made there. They share a strip because you only ever look at one of them, and three
cards would eat the bottom of the window for good. The strip and its splitter are hidden together
until something fills them, so the tree and the inspector get the whole height until then.

A row is a record and not a line of text. A click selects that record in the tree. A double click
takes the inspector to the page that can do something about it, which for a script hit is the
Script page at the line the hit was on. Right-click copies one message or all of them, or clears
the strip.

### The status line

The left half is what you have: the record count, how many are selected and how many the filter
matched. The number of selected records is always the number the next action will touch, because
the selection is intersected with the visible set whenever the filter changes.

The right half is what the table is: groups, scripts, pointers, active records, problems, and the
sync cost in milliseconds once it goes above twenty, so a table large enough to feel slow says so
rather than just being slow.

A message flashes over the left half for two and a half seconds after anything happens, then the
counts come back. The counts are always true, and a message is only worth reading right after the
thing it is about.

## 4. Editing

### 4.1 The commit funnel

One place in the whole segment writes to a memory record. No page, no menu, no service and no
public method writes one directly. A page builds a transaction and hands it up, the window
resolves every record by id, applies the changes through one table of appliers, collects what
failed and writes down only what landed.

```lua
window:Commit({
    Label = "Rename 14 records",
    Changes = {
        { Kind = "property", ID = 12, Key = "Description", Old = "hp", New = "health" },
        ...
    }
})
```

Six kinds of change exist, and undo goes through the same six appliers the edit used, so an undo
is exactly as guarded as the edit that made it.

| Kind | Writes |
|---|---|
| `property` | One schema property on one record |
| `pointer` | The base and the whole offset chain, as one change |
| `script` | An Auto Assembler record's script |
| `dropdown` | The list text, the three flags and the link |
| `hotkey` | One of a hotkey's value, description, action and only while down |
| `order` | The children of one group, in this order |

Three things fall out of that shape.

**A failed change is not a failed transaction.** Every change is tried, the ones that landed go
into the history and the ones that did not come back as a list of records and reasons, which is
logged as one warning block naming each of them. A history that claimed an edit which never
happened would be worse than no history at all.

**Cheat Engine's own side effects are recorded too.** An applier may answer a note carrying extra
changes, which the funnel writes into the same transaction. Turning a string record's unicode flag
on turns its code page flag off, so both go in and one undo puts both back.

**A bulk rename rebuilds the description cache once.** Drop-down links, `(description)` value
math and `getMemoryRecordByDescription` all resolve through that cache, so it is rebuilt after the
whole transaction rather than after each record, which is the difference between a rename of four
hundred records being instant and being slow.

Every commit ends with a repaint of Cheat Engine's own list, a re-read of the records it touched
and one Info line saying what happened.

### 4.2 Undo and redo

Ctrl+Z and Ctrl+Y, or the toolbar, or `ManifoldAddressList:Undo()`. The journal keeps two hundred
transactions. Undo walks a transaction's changes in reverse, because two changes to one field in
one transaction have to unwind in the order they were made. Redo walks them forwards. A push after
an undo cuts the redo tail off, which is what every editor does.

The journal lives on the host rather than in the window, so closing the window and opening it
again keeps the history. Re-executing the entry file does not.

**A different Cheat Table resets everything.** Ids start again from one in every Cheat Table, so
an undo held across a table change would write into records that have nothing to do with the ones
it was made against. Every snapshot carries a stamp computed from its root ids and the record
count. A snapshot that shares no record with the one before it drops the journal, the problems,
the results strip, the selection and the collapsed set, flashes `A different Cheat Table is
loaded. The undo history was dropped.` and logs one line. Every transaction also carries the stamp
of the table it was made against, so even a stale one that somehow survived is skipped rather than
applied.

A transaction whose changes were all skipped still moves the cursor. It happened, the records it
named are gone or refused it, and pretending it never happened would leave the history describing
a state that never existed.

The Menu's **Changes this session** lists the history newest first, with the time, the label, how
many changes it carried and whether it is currently undone.

### 4.3 What is not undoable

Five things leave through a different path, the window's guarded act, which never reaches the
journal. Each one says so before it runs.

**Activation.** Setting `Active` on an Auto Assembler record executes its `[ENABLE]` or
`[DISABLE]` section there and then, with no dialog of Cheat Engine's own. What a script did to the
process is not something a history can write back. This is also the only place in the segment that
writes `Active` at all, which is why the question lives in one place rather than in the three
callers that would each have asked it their own way. One script asks when
`ConfirmScriptActivation` is on, more than one always asks, and a refusal to show the dialog is a
no rather than a yes.

With `Async` on, the write returns before the script has finished and Cheat Engine reports nothing
when it is done. The ids that were still running are kept and re-read on every sync tick, and when
`AsyncProcessing` clears the window reads `LastAAExecutionFailed` and says what happened, per
record, once. A script still running after thirty seconds is let go with a warning, because
something in it is waiting on the game.

**A value write.** That writes process memory. The old bytes are gone, and the record's own
`OnValueChanged` may have run.

**A new record or a new group.** Undoing one would mean deleting a record, and this window never
deletes one. Both ask first, and the confirmation says `Cheat Engine deletes records, this window
does not.` This is also the one edit that marks the Cheat Table as edited, because
`createMemoryRecord` sets that flag itself.

**Removing a hotkey.** `destroy()` unregisters it and removes it from its record. There is nothing
left to put back.

**Testing a hotkey.** The action runs for real, which for a toggle hotkey means the record is
activated or deactivated.

### 4.4 Records are never deleted

Deleting stays in Cheat Engine. `mr.delete()` frees the record immediately, skips Cheat Engine's
own being-edited checks, and leaves raw pointers behind in an open Auto Assembler editor and in
the inline value editor. There is no safe way to do it from Lua and no way at all to undo it.
Select the record in Cheat Engine's own list and press Delete there.

### 4.5 Reordering happens inside a group

Cheat Engine's binding has exactly one move. Writing `Parent` or calling `appendToEntry` makes the
record the **last** child of the target. Nothing moves a record to the root, and nothing puts one
before a sibling. Everything this window offers is built from that one move.

- **Move up and Move down** re-append every child of the group in the order you asked for. The
  children were already in the group, so the parent reading right afterwards proves nothing, and
  the whole child order is read back instead.
- **Sort children by description** is the same change with a different order.
- **Move into group** appends the records in pre-order, so they arrive in the order they had.
  Records that came out of a group can be undone, by re-appending each old parent's children in
  the order they had, target group first. Records that came from the root cannot be put back by
  Cheat Engine at all, so that case asks first and is not undoable.

A record at the root has no parent to re-append into, so the root cannot be reordered. Move up,
Move down and Sort say `Cheat Engine offers no way to reorder records at the root.` rather than
doing nothing.

A move into the record itself, or into one of its own descendants, moves nothing and raises
nothing, because the LCL guards it with `HasAsParent` and Cheat Engine swallows what comes back.
Every such move is refused in Lua before the call goes out, and every move that does go out is
verified by reading the parent back.

### 4.6 An edit here does not mark the table as edited

Cheat Engine's `editedsincelastsave` is a plain field in the main form's public section. It is not
published, not a component and not referenced anywhere in the Lua binding, so nothing this window
does can set it. **Cheat Engine will not ask you to save on the way out, and the title bar will
not say the table changed.** Save the table yourself after editing.

The exception is `createMemoryRecord`, which sets the flag itself, so New record and New group do
mark the table. That is Cheat Engine's doing and not something this window arranged.

### 4.7 Live sync

Cheat Engine has no event for a record that changed, so the window polls. A poll that read
everything every time would cost more than the window is worth on a table of four thousand
records, so three schedules run underneath one timer, and each measures itself.

- **The structure walk** reads an id and a child count per record and nothing else. It runs when
  Cheat Engine's own count changed, and otherwise every fourth tick while it stays under four
  milliseconds and every twentieth once it costs more.
- **The detail sweep** reads the twenty fields the window draws, in a contiguous window that moves
  through the snapshot. It is contiguous and not a round robin because `getMemoryRecord` is only
  cheap when the index asked for sits next to the last one, and jumping about costs a tree walk
  per record. The budget halves when a tick spends more than eight milliseconds in it and grows
  again below four, and the sweep stops altogether once every node has been re-read since the last
  structure change, so an idle window costs nothing.
- **Values** come from process memory and can fire a record's own value handler, so they are read
  every other tick and only for the rows actually on screen.

The Live button and the Menu turn the poll off, which leaves the window showing what the last F5
read. F5 always reads everything.

`Follow Cheat Engine selection` and `Mirror selection to Cheat Engine` are both off by default and
both are one-way switches you can have at the same time. Mirror writes only when this window's
focus moved since the last write, and Follow ignores a Cheat Engine selection that equals the one
Mirror just wrote, so the two cannot take turns selecting each other. Mirror only sends the focus,
because Cheat Engine holds exactly one selected record.

## 5. Finding and replacing

Ctrl+H, or the Find button. The bar carries what to look for, what to replace it with, which
fields to read, the scope, and case and whole word switches.

| Field | Read from |
|---|---|
| Descriptions | The description of every record |
| Scripts | The Auto Assembler script, on records that have one |
| Drop-down lists | The list text, on records whose list is their own |

| Scope | Means |
|---|---|
| All | Every record in the table |
| Visible | The rows the filter is currently showing |
| Selection | The selected records |

**Find all** lists every match in the results strip, one row per match, with the record's path and
an excerpt of the line it sits on. A click selects the record, a double click opens the page that
edits the field and, for a script, puts the editor on the line.

**Replace all** is one transaction. Four hundred renames are one undo entry. The replacement runs
in one pass over the spans that were found before anything changed, because a loop that searched
again after each replacement would find the needle inside its own replacement and never finish,
which is what turns replacing `a` with `aa` into a hang.

Two kinds of record are skipped rather than written, and both are reported:

- **An active Auto Assembler script.** Rewriting the text of a running script leaves the process
  holding changes that no `[DISABLE]` section matches.
- **A linked drop-down list.** The list you see belongs to another record, so replacing in this
  record's own text would change nothing anybody can see.

Every search is a plain find and never a Lua pattern, in both directions. A description with a
percent sign or a bracket in it is ordinary text to a person and stays ordinary text here.

## 6. Problems

F7, or the Problems button, or `ManifoldAddressList:Lint()`. One pass over the whole table. The
findings land in the results strip, mark the tree with a coloured edge per record, and count on
the status line. `is:problem` in the filter narrows the tree to them, and runs the check once when
it has not run yet.

| Code | Severity | Reported when |
|---|---|---|
| `EMPTY_SCRIPT` | Error | An Auto Assembler record's script is empty or only whitespace |
| `MISSING_ENABLE` | Error | A script has a `[DISABLE]` section and no `[ENABLE]` one, so activating it does nothing |
| `MISSING_DISABLE` | Error | A script has an `[ENABLE]` section and no `[DISABLE]` one, so activating it cannot be undone |
| `LAST_RUN_FAILED` | Error | `LastAAExecutionFailed` is set on the record |
| `DEAD_DROPDOWN_LINK` | Error | The list is linked to a description that no record in the table has |
| `ASSEMBLE_FAILED` | Error | A section does not assemble. Off by default |
| `DUPLICATE_DESCRIPTION` | Warning | Two or more records share a description, and a link or a lookup finds only one of them |
| `HOTKEY_CONFLICT` | Warning | One key combination is registered twice, and only one of them will ever fire |
| `UNREADABLE` | Warning | The value could not be read. Off by default |
| `EMPTY_DESCRIPTION` | Info | The record has no description |
| `ACTIVE_UNDER_INACTIVE` | Info | An active record sits under an inactive group whose options hide its children |

A script with **neither** section is not reported. That is a one shot somebody runs by hand, not a
half written pair.

Three of the checks are facts about the table rather than about one record, so the whole table is
read even when the check is limited to a few records. A shared description is still found when
only one of the two records is in the set, and a hotkey conflict with something elsewhere in the
table is exactly the one nobody finds by looking.

Two checks cost real time and are off until the Menu turns them on.

- **Read values while checking** reads the value of every record that is not a group or a script,
  which touches the target process and can stall on a paged out address. It is also the only way
  the unreadable check means anything, because `IsReadable` is stale until the value was read.
- **Assemble scripts while checking** runs Cheat Engine's `autoAssembleCheck` over both sections
  of every script. That executes every custom Auto Assembler command handler the Cheat Table
  registered, while this window is only asking a question. That is the whole reason it is opt in.

`LastAAExecutionFailedReason` is usually the literal word `Unknown`, which says nothing, so the
message drops it when that is all Cheat Engine has.

## 7. The pages

### Pointer

The chain of one record, level by level, in the order it is walked. Row one is the first
dereference. Cheat Engine stores it the other way round, with offset zero applied **last** and the
highest offset applied to the base first, which is why its own pointer dialog draws the first
dereference at the bottom. The two orders meet in exactly two places in this segment, and the rest
of it never has to know.

Every row carries the offset text, the pointer value read at that level and the address that level
resolves to. A read that fails shows `??`, and so does every level under it, because there is no
address left to read from. The last row is what Cheat Engine calls `CurrentAddress`.

Add level, Remove level, Up and Down edit the chain. Paste path reads a chain off the clipboard in
the arrow, bracket or comma form. Adding the first level is what turns a plain record into a
pointer, and removing the last one makes it a plain address again.

Apply writes the base and the whole chain as **one** change, not one per level. A half written
chain points at nothing and there would be no way back from it.

The offsets are counted in Lua before anything is read. `Offset[i]` and `OffsetText[i]` have no
bounds check behind them and an index Cheat Engine does not have dereferences nil inside Pascal,
which is an access violation and not a Lua error, so no `pcall` would save the process. This page
walks the buffer it owns and never asks Cheat Engine for a level that is not there.

### Script

One Auto Assembler record's script, with Save, Revert, Check and Go to line. Ctrl+S saves and
Ctrl+G jumps to a line.

The editor comes from the theme, which hands back a control and two closures, and the page reads
and writes through those two and never through the control. On a Cheat Engine with `createSynEdit`
that is a highlighted editor with a gutter. Without it the same call returns a themed memo. The
text lives behind a different property on each, so a page reaching for `Lines.Text` itself would
work on one build and quietly do nothing on the other. Save, Revert, Check and Go to line work
either way, and the memo only loses the colours and the line numbers.

**Check never runs the script.** `autoAssembleCheck` assembles both sections without writing to
the process, so it is safe to press at any time, and it is the only way to find out whether a
script would work before turning it on. Failures go to the results strip with the line Cheat
Engine named, so a click lands on that line.

**Saving an active script asks first.** A script that is on right now was enabled by the text that
is about to be replaced, and its `[DISABLE]` section is the only thing that can undo what that
text did. Replacing both halves under a running script leaves the process holding changes nothing
can take back.

A record that is not an Auto Assembler record reads no script at all and a write to it is dropped,
so the page says to change the type on the Properties page first rather than letting you type into
something that will not be saved.

### Drop-down

The list a record offers instead of a bare number. One line is one entry: a value, a colon, then
the description shown in its place. Cheat Engine splits at the **first** colon, and a line without
one becomes an entry whose description is empty, which reads in the address list as a value that
lost its name. Nothing in Cheat Engine warns about it, so this page parses the text the same way,
previews what came out, and flags every line with no colon in it.

Four flags sit around the list. Three of them, Read only, Description only and Show as list item,
have getters that **follow the link**, so while a record is linked they hand back the linked
record's values and not this record's own. Writing one back would copy another record's setting
into this one. So while a record is linked the list text and those three checks are read only, the
page names the record the values come from, and the only things it will write are the link itself
and the description it points at. Unticking Linked is the way back, which is why that one check
stays live.

The linked record is named by its **description** and not by an id, because that is what Cheat
Engine stores. Renaming the source record breaks the link in silence, which is what
`DEAD_DROPDOWN_LINK` exists to catch. Go to linked record selects the source, or says the link
names nothing rather than moving the selection somewhere wrong.

Apply carries only the fields you actually changed, so a bulk apply over records whose flags
differ leaves the flags nobody touched alone.

### Hotkeys

An overview, not an editor. It lists every hotkey of the selection, or every hotkey in the table
with the All records toggle, in columns Keys, Action, Value, Record and Description, and flags in
the warning colour every combination that is on more than one hotkey. The conflict scan always
reads the whole table even when the list shows a selection.

Four fields can be edited and all four go through the commit funnel, so they undo like any other
edit: the value, the description, the action and only while the keys are held down. Test runs the
action for real after a confirmation. Remove destroys the hotkey, which neither Cheat Engine nor
this window can undo, and says so first.

**It does not create hotkeys and it does not change key combinations.** Two Cheat Engine facts
decide that.

Capturing a combination means listening for key presses while the table's own hotkeys are
registered, so the combination somebody tries to record fires the very hotkeys they are looking
at. And a hotkey's `Keys` setter fills one slot at a time and stops at the first empty one, so a
shorter combination leaves the trailing keys of the old one behind, while the thread that
registered the hotkey keeps the copy it registered with and never hears about the change at all.
Changing keys therefore means destroying the hotkey and creating a new one, which loses the id
every undo entry is keyed by.

The page says it on the page, in one muted line, because the first thing anybody looks for here is
a New button:

```
Add or change key combinations in Cheat Engine. This page shows every hotkey in the table and
finds conflicts.
```

## 8. Settings

`Manifold-AddressList-Settings.lua` holds the defaults.

| Setting | Default | Effect |
|---|---|---|
| Window.Width | 1180 | The window opens this wide. Minimum 760 |
| Window.Height | 740 | And this tall. Minimum 480 |
| TreeWidth | 540 | How much of the width the record tree takes, 320 to 1400 |
| ResultsHeight | 180 | The results strip, 90 to 600 |
| FontSize | 10 | Consolas 10 is the family size. Everything the canvases draw is measured off it, 7 to 16 |
| LiveSync | true | Keep reading the address list while the window is open |
| SyncInterval | 250 | How often that poll runs, 100 to 2000 ms |
| ShowValues | true | The value column, and the value reads that fill it |
| ShowAddresses | true | The address column |
| FollowCESelection | false | Take Cheat Engine's own selection |
| MirrorSelectionToCE | false | Push this window's focus into Cheat Engine's selection |
| ConfirmScriptActivation | true | Ask before activating a single Auto Assembler record. More than one always asks |
| InspectorPage | "Properties" | Which tab a fresh window opens on |
| Lint.ReadValues | false | Read every value while checking the table |
| Lint.Assemble | false | Assemble every script while checking the table |
| Search.MatchCase | false | Match upper and lower case exactly |
| Search.WholeWord | false | Only matches that stand on their own |
| Search.Description | true | Search descriptions |
| Search.Script | true | Search Auto Assembler scripts |
| Search.DropDown | false | Search drop-down lists |
| Search.Scope | "All" | All, Visible or Selection |
| Export.IncludeScripts | true | Scripts reach JSON and the outline |
| Export.IncludeValues | false | A value is read from a running process at the moment of the export |
| Export.IncludeChildren | true | An exported group carries what is under it |

Overrides go where the host is built in the entry file. Nested tables merge, so one search flag
can be changed without restating the others:

```lua
local host = Host:New({
    Settings = { FontSize = 11, LiveSync = false, Search = { MatchCase = true } }
})
```

Every number the window can drag or step is held inside its bounds here and nowhere else. A
splitter dragged to nothing and a font size stepped past what a canvas can measure both come back
through the same setter, so clamping at the edge of the window would leave the registry holding
the bad value.

### 8.1 Persistence

Twenty-four settings are written through `getSettings("Manifold Address List")` whenever a setter
changes them and read back on the next start, which is every row in the table above. The window
size, the tree width and the results height are written when the window closes, so the shape it is
left in is the shape it opens in.

A dotted key reaches into a nested table and is stored under that name, dot included, so the
registry holds one flat entry named `Search.MatchCase`. Values go in as strings, with a boolean
written as `1` or `0`, and are decoded against the **type of the default**, so a hand edited or
damaged registry value falls back to the default rather than turning a number into a string.

Cheat Engine answers an empty string, never nil, for a value that was never written, which is read
as absent, so a fresh install keeps every default. That is also why an empty string cannot be
stored as itself: a setting somebody deliberately emptied goes in as the marker `<empty>` and
comes back out as an empty string.

Passing `Persist = false` to the host keeps everything for the session only.

## 9. The public object

ManifoldAddressList is the host. Everything the window does is a method on it, so a Cheat Table's
own Lua script or the Lua console can do the same work with nothing on screen.

```lua
ManifoldAddressList:Open()                      -- shows the window, building it the first time
ManifoldAddressList:Close()                     -- a page holding an edit can refuse
ManifoldAddressList:Toggle()
ManifoldAddressList:IsOpen()

ManifoldAddressList:Select({ 12, 13, 14 })      -- point the window at records
ManifoldAddressList:Selected()                  -- the ids the next action would touch
ManifoldAddressList:Snapshot()                  -- the whole table as plain Lua tables

ManifoldAddressList:Lint()                      -- the problems, and the counts beside them
ManifoldAddressList:Lint({ Assemble = true })   -- with the expensive checks on
ManifoldAddressList:Find("health")              -- every match, nothing written
ManifoldAddressList:Replace({ Needle = "hp", Replacement = "health" })
ManifoldAddressList:Export("C:\\table.json")    -- json, csv, md or txt, picked by the ending
ManifoldAddressList:Undo()
ManifoldAddressList:Redo()

ManifoldAddressList:Status()                    -- a table
ManifoldAddressList:About()                     -- logs the block and makes sure it is visible
ManifoldAddressList:Diagnostics()               -- the deeper block, including what this build has
ManifoldAddressList:Uninstall()                 -- closes the window and frees everything
ManifoldAddressList:Shutdown()                  -- Uninstall, plus releasing both globals
```

The headless calls read the address list again before they run, so a script that just added
records does not work from a tree that predates them. They write through the same funnel and into
the same journal the on-screen window uses, which is what keeps one commit path and one undo
history whether or not a form exists. A replace run from the console can be undone with Ctrl+Z
after you open the window.

`Selected` answers this window's selection when it is open, and Cheat Engine's own selected
records when it is not, so a script can pass them straight into Export.

`Find` returns one entry per match, with the record id, the field, the line, the column, the
length and an excerpt. `Replace` returns how many fields were written and the ones that were
refused with a sentence saying why. `Lint` returns the problems in pre-order and a table of
Checked, Errors, Warnings, Infos and Took.

`Status` reports the version, whether the window is open, the record count, the selection size,
the problem count, the undo depth, whether the icon set loaded, whether the Logger was found and
the settings that matter. `StatusRows` is the same thing shaped for a log block, which is what the
startup line prints:

```
Manifold Address List 1.0.0 ready
  Authors      : Leunsel, LeFiXER
  Window       : not open
  Records      : 4120
  Undo history : 0 entries
  Icons        : loaded
  Logger       : Manifold Logger
  Live sync    : on, every 250 ms
  Columns      : values, addresses
  Settings     : persisted in the registry

  ManifoldAddressList:Open() opens the window.
  ManifoldAddressList:Lint() checks the table and reports what is wrong.
  ManifoldAddressList:Status() returns this as a table.
```

That is the fallback rendering. With Manifold Logger installed the block is drawn by the Logger
instead, and the same rows arrive in its console.

`Uninstall` is what the entry file calls on a previous generation. This segment registers no menu,
so there is nothing to remove: it closes the window without asking a page whether it minds, stops
both timers, destroys the surfaces, the tree, the inspector and the form, and destroys the icon
set. `Shutdown` is that plus releasing both published globals, compared by identity so a newer
generation that already took them over keeps them.

No facade call raises. The CE Utility reaches Open through a `pcall` and a Cheat Table script
reaches the rest with no guard at all, so every one of them catches its own defect and logs it.

## 10. Internal structure

Twenty-four modules and one entry file. The order below is also the order they are built in, and
a module may only depend on one above it.

**Foundation**

| Module | Owns |
|---|---|
| -Version | The version number. Nothing else in the tree carries one |
| -Log | The Manifold Logger channel named Address List, the print fallback, and Block |
| -Settings | Defaults, the entry file's overrides, the bounds, the dotted keys and the registry store |
| -CE | Every Cheat Engine global this segment touches, each one guarded and looked up at call time |
| -Icons | The 16x16 set, one image list per Cheat Engine session, and the glyphs composited for the canvas |
| -Theme | The Cheat Table's live palette, every themed control, the window, the cards, the modal helpers and the code view |

**Data**

| Module | Owns |
|---|---|
| -Types | The mapping between a record's integer type and its enum name, the tags, the labels and what a person may type |
| -Records | The snapshot, the structure walk, the budgeted detail passes, the query language, flattening to rows and the three structure moves |
| -Properties | The property schema, the bulk read, the bulk write, and the readers and writers for the pointer chain, the script, the drop-down list and the hotkeys |

**Services**

| Module | Owns |
|---|---|
| -Journal | Undo and redo. It never touches Cheat Engine, it is handed one Apply function |
| -Lint | The eleven checks, their severities and their codes |
| -Search | Find and replace. The two functions that matter are pure |
| -Export | Collect, Build in four formats, and Write |

**Canvas**

| Module | Owns |
|---|---|
| -Surface | The shared canvas engine: the probe, the off-screen bitmap, scrolling, the drawn scrollbar, the wheel, text measuring and truncation, the check box, the arrow, the Frame service and the column driven ListPainter |
| -Tree | The record tree, its rows, its selection model, its mouse and its keyboard |
| -Results | The results strip, and what each of its three kinds says when it is empty |
| -Grid | The property grid, and editing in place under a refresh that runs four times a second |

**Pages**

| Module | Owns |
|---|---|
| -Inspector | The tab strip, one panel per page, the page change gate, the header counter, and the Properties page itself |
| -Pointer | The pointer chain, in the order it is walked |
| -Script | The Auto Assembler editor, Check and Go to line |
| -DropDown | The list, its four flags and the link |
| -Hotkeys | The overview, the conflicts, the four editable fields, Test and Remove |

**Shell**

| Module | Owns |
|---|---|
| -Window | The form, the two timers, the layout, the menus, the keyboard, the commit funnel, the appliers, the acts, the status line and every hook the tree, the results strip and the inspector reach the outside through |
| -Host | Building everything in order, the journal, the facade methods, Status, About, Diagnostics, Uninstall and Shutdown |

Globals are never captured at load time. A test can therefore stub the whole API, and an older
Cheat Engine degrades to a logged reason rather than an error raised while autorun is still
loading. Nothing in the wrappers turns a failure into a fake success: a missing confirmation
dialog blocks the action, it never reads as consent.

Memory record wrappers are never kept. Cheat Engine builds a fresh wrapper on every access and
never invalidates the old ones, so a wrapper held past a delete is a use after free, and two
wrappers of one record are not the same Lua value. Ids are the only identity there is, and every
id is resolved again at the moment it is used.

### 10.1 The tests

`Manifold-AddressList-Tests/Run.lua` runs the whole segment headlessly on any Lua 5.3:

```
lua Run.lua <projectDir> <scratchDir> <filter>
```

Eight files run in dependency order: the stub itself, the foundation, the theme, the data modules,
the services, the canvas, the pages and the window. Each starts from a fresh stub with the segment
modules dropped from `package.loaded`, so nothing one file did can reach the next. There are 3051
checks.

`CEStub.lua` is the Cheat Engine they run against, and it is written to be wrong in exactly the
ways the real one is. `appendToEntry` into a record's own branch is a silent no-op rather than an
error. Reading an event of an unregistered type raises while writing one does nothing. `Options`
drops the whole assignment on one unknown flag. `getSettings` answers an empty string for a key
nobody wrote. `createMemoryRecord` gives a `vtDword` record described "Plugin Address". An
`OnClose` that returns nothing means the form stays open. `getMemoryRecord` refuses a negative
index. Setting a tree's `Selected` in code fires `OnSelectionChanged`, a check box's `Checked`
fires `OnChange` and `OnClick`, and a combo box's `ItemIndex` fires nothing. `Stub.OnScreen`
models the LCL alignment rule, and one test guards the rule itself so nobody "fixes" it the wrong
way round. A module that regresses to any of those fails in the test run instead of quietly
producing a window that does not work on a real Cheat Engine.

## 11. Cheat Engine behaviours that contradict celua.txt

Everything below was read out of the Cheat Engine 7.5 and Lazarus 2.2 sources, or measured. Each
one differs from what the documentation says, or is not in the documentation at all, and each one
decided something about how this segment is built.

**A tree view has no custom draw from Lua.** `TTVCustomDrawItemEvent` and its advanced form are
not in `LuaCaller`'s registered type list, in 7.5 or in master. Assigning `OnCustomDrawItem` on a
tree is swallowed without a word and reading it back raises. `GetNodeAt` is public rather than
published, so there is no hit test either, and no drag event is assignable. A list view does have
all six custom draw events, which several readings of the documentation get backwards, but a list
view is not a tree. That is why the record tree in this window is painted on a canvas: there is no
control in the binding that can show a record with its own colour, a check box, badges and a
problem marker.

**Reading an `On*` of an unregistered type raises.** Writing one is a silent no-op, because
`lua_setProperty` wraps its body in `try ... except end`. The getter has no such guard. Cheat
Engine's own address list owns `OnSelectionChanged`, `OnAdvancedCustomDrawItem`, the drag handlers
and several more, so this segment never reads or writes an event on any Cheat Engine object at
all. The CE wrapper refuses any member matching `On` followed by a capital, which is also why a
hotkey's `OnlyWhileDown` is still readable.

**`getAddressList().refresh()` does not repaint the record tree.** `TControl.Refresh` is not
virtual and `TAddresslist.refresh` is a static method, so the call reaches the panel and never the
tree window inside it. `getAddressList().List.repaint()` is what shows a change. Every commit here
ends with that call, on the tree found by component name.

**A Lua edit never marks the Cheat Table as edited, and nothing can.** `editedsincelastsave` is a
plain field in the main form's public section, not published, not a component and not referenced
in the Lua handler. The one exception is `createMemoryRecord`, because `addaddress` sets the flag
itself. Everything else this window writes leaves Cheat Engine believing the table is unchanged.

**`Parent = x` and `appendToEntry(x)` fail silently.** A target that is the record itself or one
of its own descendants moves nothing and raises nothing, because the LCL's `MoveTo` guards with
`HasAsParent`. Both are also the only move there is, and both append as the **last** child.
`Parent = nil` dereferences a nil pointer inside `appendToEntry`, and the access violation happens
inside `lua_setProperty`, which swallows it. So nothing is ever moved without reading the parent
back afterwards, and a reorder inside one group is verified by reading the whole child order back,
because the parent never changes there.

**`pcall` does not catch an access violation inside a binding.** `Offset[i]` and `OffsetText[i]`
outside the offset count, `getMemoryRecord` with a negative index and `appendToEntry(nil)` all
dereference nil inside Pascal with no handler, and that takes the process down rather than
returning an error to Lua. Every one of those is bounds-checked or nil-checked in Lua **before**
the call.

**`mr.Address = s` clears the pointer offsets.** Editing a pointer means writing the address, then
the offset count, then each offset text, then `reinterpret()`, in that order. That is why the
Properties grid's Address row is read only on a record with offsets and sends you to the Pointer
page.

**`Offset[0]` is applied last.** Cheat Engine walks `for i := offsetCount-1 downto 0`, so the
highest offset is applied to the base first, which is why its own pointer dialog draws the first
dereference at the bottom of the list. This window shows the chain in the order it is walked and
turns it round again on the way out.

**`Type` takes an integer and range checks nothing.** A string or nil written to it becomes
`vtByte` without a word. `VarType` reads the enum name back and accepts either form. Setting 7
stores `vtString` with the unicode flag on, and setting 12 stores a pointer sized integer with
show as hex, so neither value is ever read back from a record. The editor type list here holds
eleven entries, those two are deliberately not among them, and every write takes its integer from
that list.

**One unknown element makes a whole `Options` write fail silently.** FPC's `StringToSet` raises
`EPropertyError` on a name it does not know, and `lua_setProperty` swallows it, so the whole
assignment is dropped. `moHideChildren` and `moAlwaysHideChildren` also exclude each other only
against the set the record **already** has, so writing both at once to a record holding neither
stores both. Every option write therefore rewrites the whole set string, reads it back, and
derives what changed from what came back rather than from what was asked for.

**Setting `Active` is ignored in three cases.** When the value is already that, while
`AsyncProcessing` is true, and when the script failed to assemble, which leaves it false. It is
also assigned only after the script has run, so `Active` is read back after every write. And
deactivating a group with `moDeactivateChildrenAsWell` pumps messages, so timers and handlers can
re-enter in the middle of it. That is why the window's busy flag is a counter and not a flag, and
why both timers stand down while it is above zero.

**`LastAAExecutionFailedReason` is usually the literal word `Unknown`.** Reporting it as given
would put a message on screen that says nothing, so it is dropped when that is all there is.

**`IsReadable` is stale until the value was read once.** Cheat Engine sets it inside `GetValue`
and nowhere else, so a record whose value was never read reports itself unreadable. The Properties
row reads the value first, and the hint says so.

**`getMemoryRecord(i)` is only cheap next to the last index asked for.** The LCL caches exactly
one node, so a round robin over a large table costs a tree walk per record. The detail sweep here
moves through a contiguous window for that reason alone.

**`getSelectedRecords()` answers nothing at zero and a sparse table otherwise**, so it is read
with `pairs` and never with `ipairs`. And `setSelectedRecord` given a record that is gone clears
the **whole** selection instead of raising, so an id is resolved before it is handed over.

**Changing a hotkey's `Keys` leaves trailing keys behind.** The setter fills one slot at a time
and stops at the first zero, so a shorter combination keeps the tail of the old one. It also does
not re-register, so the thread keeps the combination it was created with. Changing keys means
destroy and create, which loses the id. That is why the Hotkeys page does not do it.

**`createMemoryRecord()` gives a `vtDword` record described "Plugin Address"**, appended at the
end of the root. Not `vtByte`, which two independent stubs of this API got wrong.

**A Lua `OnClose` that returns nothing means `caNone`.** The form stays open, and a window nobody
can close is the result. This window's `OnClose` always returns `caFree` or `caNone` deliberately,
and the theme's Esc handling is left off so the window can decide for itself what Escape means.

**alTop and alLeft put the last created control outermost. alBottom and alRight put the first
one outermost.** The LCL's `InsertBefore` says so in its own comment, contrary to the VCL. Reading
a layout wrongly here produces a window that looks almost right, so the test suite asserts every
edge.

**`canvas.textRect` is not a clipping call.** Its first argument is a rect table and it renders
through Cheat Engine's formatted text renderer, which would read a record description as markup.
Nothing in this segment calls it. Text is measured with `getTextWidth`, truncated in Lua and drawn
with `textOut`. `fillRect` takes four integers in 7.5 and no rect table.

**A graphic control never takes focus and never receives the mouse wheel.** A paint box and an
image are both graphic controls, so the wheel handlers go on the surface **and** on its windowed
parent, and the keyboard is routed by the window through `KeyPreview` and a note of which pane the
last mouse down landed on. The wheel event carries no delta at all, only a position, so the
direction is which of the two handlers ran. A mouse button arrives as an integer and never as a
name, so the right button is `1`.

**Writing a property in code fires events, unevenly.** `edit.Text = s` fires `OnChange`,
`checkbox.Checked = v` fires `OnChange` **and** `OnClick`, and `combo.ItemIndex = i` fires
nothing. Handlers are assigned after initial values, or guarded with a loading flag.

**`getSettings` answers an empty string and never nil** for a key that was never written, so a
fresh install keeps its defaults and a deliberately empty value needs a marker of its own.

**Writing a read-only member does two different things, both bad.** An explicitly registered one,
such as `Selected` or `CurrentAddress`, replaces the getter on that wrapper. A published read-only
property, such as `Index` or `Count`, is swallowed and changes nothing. A misspelt property name
lands raw in that one wrapper's metatable and appears to work. Nothing here writes one, and
anything that matters is read back.

**After bulk description changes, call `rebuildDescriptionCache()`.** Drop-down links,
`(description)` value math and `getMemoryRecordByDescription` all resolve through it, and without
the rebuild they resolve to the wrong record.
