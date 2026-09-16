# Manifold Address List

`Manifold-AddressList.lua` is an autorun extension for Cheat Engine that puts the open Cheat
Table's address list into one window, with the record tree on the left and an inspector on the
right, and edits records in bulk with an undo history of its own.

Cheat Engine's own address list edits one record at a time, through one modal dialog per field.
Renaming forty records is forty double clicks. Changing the type of a group of pointers is forty
more. Nothing you do there can be taken back, there is no way to see every hotkey in the table at
once, and there is no way to ask which records are broken. This window replaces all of that, and
it never takes anything away from Cheat Engine's own list: the two are looking at the same
records, and an edit made here shows up there as soon as it lands.

It has no dependency on the Manifold Framework and works on its own. Two optional couplings: it
logs through [Manifold Logger](../Manifold-Logger) when that is installed and falls back to a
timestamped print when it is not, and it adopts the Cheat Table's active theme when one is loaded.

![Preview](https://i.imgur.com/9DI1SiO.png)

## Highlights

**Everything is one selection.** Select fourteen records, type a new description, and it is one
edit and one undo entry. The Properties grid reads what the whole selection agrees on, shows
`<mixed>` where it does not, and writes only the fields you actually touched, so a bulk edit over
records that differ leaves what you did not touch alone.

**Undo that Cheat Engine does not have.** Every description, type, address, colour, option flag,
pointer chain, script, drop-down list, hotkey field and reorder goes through one funnel, is
written down with its old value and its new one, and comes back with Ctrl+Z. Two hundred
transactions are kept. Activation and value writes are deliberately outside it, because running an
Auto Assembler script and writing process memory are not things a history can reverse.

**The tree is drawn, not delegated.** Cheat Engine's Lua binding publishes no custom draw, no hit
test and no per node colour for a tree, so the record tree here is painted on a canvas. That is
what buys the record's own colour on its row, an activation box, a type tag, the address, the live
value, hotkey and drop-down badges, a coloured edge where a check found something, and an in-place
highlight of what the filter matched. It is virtual, so four thousand records scroll exactly as
fast as forty.

**A filter with a small language.** Plain words are a case insensitive substring of the
description and the address, and every word has to match. Beyond that there are four predicates,
`type:`, `is:`, `has:` and `id:`, so `is:script is:inactive` or `has:hotkey type:4 bytes` narrows
a table of thousands to the handful you meant. A match inside a collapsed group opens the group
without disturbing what you collapsed by hand.

**Find and replace across the whole table.** One search over descriptions, Auto Assembler scripts
and drop-down lists, scoped to everything, to the rows the filter shows or to the selection. Find
all lists every hit in the results strip and a click on one goes to it. Replace all is one
transaction, so four hundred renames are one undo entry. Every search is plain text, never a Lua
pattern, because a description full of brackets and percent signs is completely ordinary.

**It tells you what is wrong with the table.** Eleven checks, from a script with no `[DISABLE]`
section to a drop-down list linked to a record that no longer exists, to two records holding the
same key combination. The findings land in the results strip, mark the tree with a coloured edge,
and `is:problem` filters the tree down to them.

**It is honest about what Cheat Engine will not do.** Records are never deleted here. Reordering
happens inside a group, because appending to a parent is the only move the binding has. The
Hotkeys page shows and edits but does not create or rebind. Every one of those is explained where
you run into it, in the window, not only here.

**It follows the Cheat Table's theme.** The window carries its own copy of the Manifold design
language, reads `forms.ActiveDesignTheme` when a table has a live `Manifold.Forms`, and falls back
to the bundled Bearded-Arc palette when it does not. A theme switched while the window is open is
picked up within a second, chrome and canvases together.

## Installation

Place `Manifold-AddressList.lua` **and** the `Manifold-AddressList-Modules` folder next to each
other in the autorun folder, which is usually `C:\Program Files\Cheat Engine 7.5\autorun`. On a
portable build, or if Cheat Engine was installed elsewhere, the folder will be somewhere else.

To find it, run this in the Cheat Engine Lua console:

```lua
return getAutorunPath()
```

The layout in the autorun folder has to be:

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

If only the single file is copied, Cheat Engine prints one readable line naming the folder it
could not find, rather than a require traceback on every start. Re-running the file rebuilds
everything from fresh module code and takes the previous generation's window, timers and icons
down first, so nothing accumulates while you edit. The undo history does not survive that, because
it belongs to the generation that made it.

## Opening it

With [Manifold CE Utility](../Manifold-CE-Utility) installed, use **Manifold -> Open Address
List**.

Without it, from the Lua console or a table's Lua script:

```lua
ManifoldAddressList:Open()
```

This module registers no menu entry of its own, so the two never produce a duplicate one.

## The window

| Control | Effect |
|---|---|
| Refresh | Reads the whole address list again, every node, and repaints (F5) |
| Live | Keeps reading it while the window is open. Off, the window shows what the last refresh read |
| Undo | Puts the last transaction back (Ctrl+Z) |
| Redo | Does the last undone transaction again (Ctrl+Y or Ctrl+Shift+Z) |
| Find | Opens the find and replace bar (Ctrl+H) |
| Problems | Checks the table and lists what is wrong with it (F7) |
| Export | Writes the selected records, or every root record, to JSON, CSV, Markdown or text |
| Filter | Narrows the tree. Plain words, plus `type:`, `is:`, `has:` and `id:` (Ctrl+F) |
| Menu | Everything else. The same menu is on right-click in the record list |
| Activation box | Activates or deactivates the whole selection. A script asks first |
| Tabs | Properties, Pointer, Script, Drop-down and Hotkeys, over the same selection |
| Results strip | Problems, matches or the session's changes. One strip, one at a time |
| Status line | Records, selected, matches on the left. Groups, scripts, pointers, active and problems on the right |

| Key | Effect |
|---|---|
| Up / Down / PgUp / PgDn / Home / End | Move the focus in the tree, with Shift to extend the selection |
| Left / Right | Collapse, or step to the parent. Expand, or step to the first child |
| `*` | Expand the focused record and everything under it |
| Space | Activate or deactivate the selection |
| Enter | Open the focused record on the page that edits it |
| F2 | Edit the description in place |
| Ctrl+A | Select every visible record |
| Ctrl+C / Ctrl+Shift+C | Copy the descriptions, or the pointer paths |
| Ctrl+G | Show the focused record in the memory view |
| Ctrl+Up / Ctrl+Down | Move the focused record up or down inside its group |
| Ctrl+F | Focus the filter box |
| Ctrl+H | Show the find and replace bar |
| Ctrl+Z / Ctrl+Y | Undo and redo |
| Ctrl+E / Ctrl+P | Jump to the Script page, or the Pointer page |
| Ctrl+1 to Ctrl+5 | The five inspector tabs |
| Ctrl + / Ctrl - | Larger and smaller text on every canvas at once |
| F5 | Read the address list again |
| F7 | Check the table |
| Esc | Clear the filter, then hide the find bar, then close the window |

F5, F7, Ctrl+F and Esc work while you are typing in a box. Everything else goes to the pane the
last click landed on, so Ctrl+A in the filter box selects the text and Ctrl+A in the tree selects
the records.

## What is undoable and what is not

Undoable, as one transaction per action, however many records it touched:

descriptions, addresses, types, string length and the unicode and code page flags, the binary
start bit and bit count, the array length, the custom type name, show as hex and signed, colours,
allow increase and decrease, async, do not save, whether a record is a group header, all seven
option flags, the pointer chain, the Auto Assembler script, the drop-down list with its three
flags and its link, a hotkey's value, description, action and only while down, and reordering
inside a group.

Where Cheat Engine changes a second thing of its own accord, that comes along. Turning the unicode
flag on turns the code page flag off, and the funnel writes both into the transaction, so one undo
puts both back.

Not undoable, and the window says so before it runs each of them:

**Activation.** Setting `Active` on an Auto Assembler record executes its `[ENABLE]` or
`[DISABLE]` section immediately, with no dialog of Cheat Engine's own. What a script did to the
process is not something a history can write back, so activation goes down a separate path that
asks first. One script asks when the setting says to, more than one always asks.

**A value write.** That writes the target process. The old bytes are gone.

**A new record or a new group.** Undoing one would mean deleting a record, and this window never
deletes one. Both ask first, and the confirmation says so.

**Removing a hotkey.** `destroy()` unregisters it and there is nothing to put back.

**Testing a hotkey.** It runs the action for real.

## Records are never deleted here

Deleting stays in Cheat Engine. The Lua `delete()` frees the record immediately, skips Cheat
Engine's own being-edited checks, and leaves raw pointers behind in an open Auto Assembler editor
or in the inline value editor. There is no way from Lua to do it safely and no way to undo it, so
the window does not offer it at all. Select the record in Cheat Engine's own list and press
Delete there.

## Reordering happens inside a group

Cheat Engine's binding has exactly one move. Writing `Parent` or calling `appendToEntry` makes the
record the **last** child of the target. There is nothing that moves a record to the root, and
nothing that puts one before a sibling. So Move up, Move down and Sort children all work by
re-appending every child of one group in the order you asked for, which is a move Cheat Engine can
do, and the result is read back to prove it happened.

The root has no parent to re-append into, so records that sit at the root cannot be reordered at
all, and the window says that instead of pretending. Move into group is the same story from the
other side: records that came out of a group can be moved and undone, records that came from the
root can be moved and not undone, and that case asks first.

## The Hotkeys page shows, it does not create

It lists every hotkey of the selection, or of the whole table, with the keys, the action, the
value, the record and the description, and flags every combination that is on more than one
hotkey. Four fields can be edited and they undo like everything else. Test runs the action after a
confirmation. Remove destroys the hotkey and cannot be undone.

It does not create hotkeys and it does not change key combinations, for two reasons. Capturing a
combination means listening for keys while the table's own hotkeys are registered, so the
combination you press fires the very hotkeys you are looking at. And a hotkey's `Keys` setter
fills one slot at a time and stops at the first empty one, so a shorter combination leaves the
trailing keys of the old one behind, while the thread that registered it never hears about the
change. Changing keys therefore means destroying the hotkey and making a new one, which loses the
id every undo entry is keyed by. Add and rebind in Cheat Engine. The page says so in one line of
its own.

## An edit here does not mark the table as edited

Cheat Engine's "edited since last save" flag is a plain field on the main form. It is not
published, it is not a component and nothing in the Lua binding reaches it, so nothing this window
does can set it. Save the table yourself after editing, because Cheat Engine will not ask you to
on the way out.

There is exactly one exception, and it is not ours. `createMemoryRecord` sets the flag itself, so
New record and New group do mark the table.

## The problem check

Eleven checks, run on F7 or the Problems button. Two of them cost real time and are off until you
turn them on in the Menu, because reading a value touches the target process and assembling a
script runs whatever custom Auto Assembler commands the table registered.

| Code | Severity | Means |
|---|---|---|
| EMPTY_SCRIPT | Error | An Auto Assembler record has no script |
| MISSING_ENABLE | Error | A script has a `[DISABLE]` section and no `[ENABLE]` one |
| MISSING_DISABLE | Error | A script has an `[ENABLE]` section and no `[DISABLE]` one |
| LAST_RUN_FAILED | Error | The last run of a script failed, with Cheat Engine's reason when it gave one |
| DEAD_DROPDOWN_LINK | Error | A drop-down list is linked to a description no record has |
| ASSEMBLE_FAILED | Error | A section does not assemble. Off by default |
| DUPLICATE_DESCRIPTION | Warning | Two or more records share a description, and a link or a lookup finds only one |
| HOTKEY_CONFLICT | Warning | One key combination is on two hotkeys, and only one of them will fire |
| UNREADABLE | Warning | A value cannot be read. Off by default |
| EMPTY_DESCRIPTION | Info | A record has no description |
| ACTIVE_UNDER_INACTIVE | Info | An active record sits under an inactive group that hides its children |

A script with neither section is not reported. That is a one shot somebody runs by hand, not a
half written pair.

## Working without the window

Everything the window does is also a method on the published object, so a Cheat Table's own Lua
script can use it with nothing on screen:

```lua
ManifoldAddressList:Lint()                                   -- the problems and the counts
ManifoldAddressList:Find("health")                           -- every match, nothing written
ManifoldAddressList:Replace({ Needle = "hp",
                              Replacement = "health" })      -- one undo entry
ManifoldAddressList:Export("C:\\records.json")               -- the selection, or every root
ManifoldAddressList:Select({ 12, 13, 14 })
ManifoldAddressList:Undo()
ManifoldAddressList:Status()
```

Those read the address list again before they run, and they write through the same funnel and into
the same undo history the window uses, so a headless replace can be undone with Ctrl+Z after you
open the window.

## Degrading

Nothing below is required for the rest to work. `ManifoldAddressList:Diagnostics()` lists every
one of them and says what is missing on this build.

| Missing | Result |
|---|---|
| `createPaintBox` | The canvases fall back to `createImage`, which is equally double-buffered |
| `createSynEdit` | The Script page falls back to a themed memo. Save, Revert, Check and Go to line all still work |
| `createTimer` | The window only reads when you press F5 |
| `getSettings` | Nothing is remembered between sessions |
| `messageDialog` | Anything that asks first is refused, because a missing question is never a yes |
| `autoAssembleCheck` | Check on the Script page, and the assemble check, are not offered |
| `readPointer` | A pointer chain shows its offsets and no live values |
| The icon set | Buttons and menu entries simply have no glyph |

## License

MIT. See `LICENSE` in the repository root.

The full reference is in [docs/Manifold-AddressList.md](../docs/Manifold-AddressList.md).
