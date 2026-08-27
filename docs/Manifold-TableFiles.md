# Manifold Table Files

A window that puts every file attached to the open Cheat Table in one place, with an editor
beside the list.

Cheat Engine reaches attached files only through `Table` in the menu bar, one context menu per
file. There is no enumeration call, no rename, and no way to look inside a file without opening
it. This module works around all three.

Runs from Cheat Engine's `autorun` folder. Independent of the Cheat Table, so it is available
before a table is loaded and stays available after one is closed.

---

## 1. Installation

`Manifold-TableFiles.lua` and the `Manifold-TableFiles-Modules` folder go next to each other in
the autorun folder:

```
autorun/
  Manifold-TableFiles.lua
  Manifold-TableFiles-Modules/
    Manifold-TableFiles-Editor.lua
    Manifold-TableFiles-Files.lua
    Manifold-TableFiles-Images.lua
    Manifold-TableFiles-Theme.lua
    Manifold-TableFiles-Types.lua
    Manifold-TableFiles-Version.lua
    Manifold-TableFiles-Viewer.lua
```

The entry point puts `Manifold-TableFiles-Modules` on `package.path` using `getAutorunPath()`, so
the folder name is not configurable. Nothing else ships: no PNGs, no DLLs, no external
dependencies.

### Re-running it at runtime

Executing `Manifold-TableFiles.lua` again returns the instance already published as
`ManifoldTableFiles` instead of building a second one. An open window is left alone.

---

## 2. Opening the window

With [Manifold CE Utility](Manifold-CE-Utility.md) installed, the entry sits in its menu directly
below `Remove All Structures`:

**Manifold -> Open Table File Viewer**

Without it, from the Lua console or a table's Lua script:

```lua
ManifoldTableFiles:Open()
```

This module registers no menu entry of its own. CE Utility contributes the entry and delegates to
whatever `ManifoldTableFiles` it finds, so the two cannot produce a duplicate. With the module
absent, the menu entry logs where to install it rather than failing.

`Open()` reuses an already-open window and brings it forward.

---

## 3. The window

```
+----------------------------------------------------------+
| Add... New... | Rename Duplicate Remove Export | Refresh  |
|                                        [ Filter...     ]  |
+-------------------------+--------------------------------+
| Table Files             | WeaponHook.CEA *               |
|                         |                                |
| ▌ a.lua      Lua    8 B |  [ENABLE]                      |
| ▌ b.CEA      Auto  12 B |  aobscanmodule(...)            |
| ▌ notes.txt  Text  40 B |                                |
+-------------------------+--------------------------------+
| 3 files          Auto Assembler  12 B  Ln 4, Col 9  Modif|
| Save                                              Close  |
+----------------------------------------------------------+
```

| Control | Effect | Shortcut |
|---|---|---|
| Add... | Attaches files from disk. Multi-select | `Ctrl+O` |
| New... | Creates a file with starter content for its type | `Ctrl+N` |
| Rename | Renames the selected file | `F2` |
| Duplicate | Copies the selected file under a free name | `Ctrl+D` |
| Remove | Deletes the selected files | `Del` |
| Export... | One file asks for a name, several ask for a folder | `Ctrl+E` |
| Refresh | Re-reads the table's file list | `F5` |
| Save | Writes the editor's contents back into the table | `Ctrl+S` |

The window dispatches these itself, from the form's `OnKeyDown`. It has to: Lazarus only
consults a form's **main menu** in `TCustomForm.IsShortcut`, so a `TPopupMenu`'s `Shortcut`
renders next to the caption and never fires. The property is kept for display; `Viewer:HandleKey`
is what runs.

Which pane has focus decides what a key means, tracked through `OnEnter` on the list and the
editors. `Del` and `F2` only act while the list has focus, so `Del` still deletes a character in
the editor, and undo, redo and the clipboard keys are left entirely to SynEdit.

### The list

Three columns — Name, Type, Size — with Name taking the majority of the width. Clicking a header
sorts by it; clicking the same header again reverses the direction. Sorting and filtering are
view operations: they never touch the editor.

Each row carries a 16x16 glyph in its type's accent colour. Blue is Lua, red the Auto Assembler
family, amber the data formats, grey text and unknown files, violet binary. The glyph is a marker
for scanning, not an illustration; the file name stays the information.

### Selection

Selecting exactly one file opens it. A multiple selection is for the bulk actions and
deliberately leaves the buffer where it is. Double-clicking opens a row.

### The status line

Left, what the list is showing: `63 files`, `18 of 63 files` when filtered, `4 of 63 files
selected` for a multi-selection, `No files attached` for an empty table. Right, what the editor
holds: type, size, `Ln 42, Col 18`, and `Modified` while there are unsaved changes.

---

## 4. Not losing work

### 4.1 One gate

`ResolveDirtyBuffer` is the single gate in front of anything that would replace or discard the
editor's contents. It offers **Save**, **Discard** and **Cancel**, and every caller honours a
Cancel by abandoning the operation that asked.

It is reached from: switching files, double-clicking another row, closing the window, renaming
the open file, duplicating it, deleting it, exporting it, and replacing it during an import.

These deliberately do **not** reach it, because none of them touches the buffer:

- typing in the filter box
- clicking a column header to sort
- pressing Refresh

The first of those was the worst bug in version 1: the filter called the same rebuild as
everything else, so typing into it silently discarded an unsaved edit.

### 4.2 Refresh

Refresh means "agree with the table again", not "start over". The buffer, the selection and the
filter all survive it.

The one case that needs saying out loud is the open file having disappeared from the table while
it was open. With a clean buffer the editor returns to its empty state. With unsaved changes the
buffer is kept and the user is told that saving will re-create the file — the alternative would
be throwing away work because something else removed a file.

### 4.3 Export

An unsaved buffer is settled through the same gate before anything is written, so what lands on
disk is never an older copy than what the editor is showing.

---

## 5. Import collisions

A name that is already attached is never overwritten on its own. The clash offers:

| Choice | Effect |
|---|---|
| Replace | Overwrites the attachment |
| Keep both | Attaches the incoming file under a free name (`Hook (2).CEA`) |
| Skip | Leaves the attachment alone |
| Cancel | Stops the import where it is |

With more than one file left to import, the answer can be applied to the remaining conflicts.

Replace is staged rather than destructive: the incoming file is imported under a temporary free
name first, and the old attachment is only removed once those bytes are safely in. A failed
import therefore cannot destroy the copy that was already there.

---

## 6. Behaviour worth knowing

### 6.1 Creating a file

The New File dialog puts a button on five types — `.lua`, `.CEA`, `.AA`, `.json`, `.txt` — and not
on every extension the registry knows. A button per extension does not fit across the dialog; the
first ones end up past its left edge where they cannot be clicked. Any other extension is typed
into the name instead, and the name has the last word: clicking `.TXT` and then typing `Notes.md`
produces a Markdown file, not a text file with a text file's starter content.

### 6.2 Which editor a file opens in

`createSynEdit`'s second argument fixes the highlighter when the control is built, so one editor
cannot switch between languages. The window builds three and shows whichever the type calls for.

| Extension | Type | Editor |
|---|---|---|
| `.lua` | Lua Script | SynEdit, Lua highlighting (mode `0`) |
| `.CEA`, `.aa` | Auto Assembler | SynEdit, Auto Assembler highlighting (mode `1`) |
| `.asm` | Assembly | SynEdit, Auto Assembler highlighting |
| `.json`, `.xml`, `.csv`, `.ini` | data formats | Plain text |
| `.txt`, `.md` | Text | Plain text |
| anything else | Other | Plain text |

Cheat Engine has no JSON highlighter and the Lua one would colour the wrong tokens, so the data
formats are honestly plain. Where `createSynEdit` is unavailable every slot falls back to a
themed memo, so the window still works.

### 6.3 Binary attachments

Cheat Table attachments are not guaranteed to be source. A file whose type says it is not text,
or whose bytes contain a NUL or more than ten percent control characters in the first 4 KB, is
described rather than loaded:

> **sound.wav**
> Binary, 41.2 KB. Binary attachments are not opened for editing; export, rename and remove still
> work.

Nothing is loaded into an editor, so nothing can be normalised and written back transformed. An
empty file counts as text — it has to stay editable, or a new file could never be filled in.

### 6.4 Renaming

Cheat Engine has no rename for table files, so `Files:Rename` is copy, verify, delete:

1. Copy the source to the target, refusing outright if that name is taken.
2. Read both back and compare.
3. Only then delete the source.

A copy that does not read back intact is removed again and the original is left untouched. The
test suite forces exactly this case with a storage layer that reports success while losing a
byte.

### 6.5 Reading and writing

Import and export go through the MemoryStream's `loadFromFileNoError` / `saveToFileNoError`, so
the bytes never pass through a Lua string: nothing can be transformed on the way and a large
attachment costs no Lua memory. `copyFrom` does the same for Duplicate. Each falls back to a
byte-level path where those methods are missing.

The byte-level path steps through the stream in 4 KB pieces, because
`string.char(table.unpack(bytes))` over a whole file blows Lua's argument limit. Writing
truncates first by assigning `Size = 0`; without that the write appends to the old contents.

Line endings are never normalised, and a file is never rewritten because it was merely opened.

### 6.6 Editor commands

What Cheat Engine actually exposes on a SynEdit:

```
properties  Lines Gutter ReadOnly SelStart SelEnd SelText
            CanPaste CanRedo CanUndo CharWidth LineHeight
methods     CopyToClipboard CutToClipboard PasteFromClipboard
            Undo Redo ClearUndo MarkTextAsSaved ClearSelection SelectAll
```

Undo, redo and the clipboard delegate straight to those. `SearchReplace`, `CaretX`/`CaretY` and
`GotoLineAndCenter` are **not** exposed, so Find, Replace, Go to line and the `Ln, Col` readout
are built on `Lines` plus `SelStart`/`SelEnd` instead. Nothing pretends to offer a command it
cannot run.

Loading a file clears the undo history and marks the text saved, so undo cannot step backwards
into the previous file's contents.

---

## 7. Internal structure

| Module | Responsibility |
|---|---|
| `Manifold-TableFiles.lua` | Composition root. Builds the services, publishes `ManifoldTableFiles` |
| `-Types.lua` | Extension → type, colour, highlighter mode, icon key, editability |
| `-Files.lua` | Everything that touches attached files. No UI, callable headless |
| `-Images.lua` | The generated file-type image list |
| `-Theme.lua` | Visual primitives: windows, cards, buttons, lists, dialogs, empty states |
| `-Editor.lua` | Editor controls, the active buffer, the dirty flag, positions |
| `-Viewer.lua` | The window: state, controller, composition |
| `-Version.lua` | Single source of truth for the version number |

The composition root supplies the services, which is what keeps everything testable without Cheat
Engine: a logger that prefers a live `Manifold.Logger` and falls back to a timestamped `print`, a
main-thread dispatcher, a confirmation prompt, and the version.

### 7.1 The state model

The controls are a rendering of the state, not the state itself:

```
state.Files      every attached file, as info records (metadata only)
state.Visible    Files after the filter and the sort
state.Filter     the filter string
state.Sort       { Key = "Name" | "Type" | "Size", Ascending = boolean }
state.Selection  the selected names, in list order
state.Rendering  true while the list is being repopulated
```

The editor owns what the editor knows: the active file, the buffer, the dirty flag. The viewer
asks it and never reads a SynEdit directly. Keeping the two apart is what makes filtering and
refreshing safe.

### 7.2 Enumerating attached files

There is no API for this. The `Table` menu is the list, so `Files:ListNames` walks `miTable` and
keeps the captions that resolve through `findTableFile`.

Two details matter and both caused an empty list at first.

The main form is reached through `getMainForm()`, the documented accessor the rest of the Manifold
tools use. `mf` is a local inside `Manifold-CE-Utility`, not something Cheat Engine publishes, so
a standalone module reaching for it as a global finds nothing at all.

Cheat Engine fills the file entries into that menu when it is opened, but the menu always carries
its own commands, so its child count says nothing about whether the files are listed yet: a fresh
instance with files attached but the menu never opened looks exactly like a table with no files.
Finding no files is therefore the signal to click the menu and read it again, which also keeps
the click off the common path.

A list refresh reads metadata only — name, extension, type, size — so a table with hundreds of
attachments costs no file reads. Contents are read when a file is opened.

---

## 8. The image list

One 16x16 glyph per file type, drawn in process with `createBitmap` and the Canvas, added to a
`createImageList` and handed to the list view as `SmallImages`.

The technique is adapted from the Manifold UI Theme Creator's colour swatches
(`Manifold.UI.lua`, `UI:RebuildImageList`). It is an adaptation of the concept, not a dependency:
Table Files works whether or not the Theme Creator or the Manifold Framework is present.

Two differences from that implementation, both deliberate:

- The Theme Creator rebuilds its list whenever a colour changes, because its images *are* the
  data. These are a fixed set of type glyphs, so the list is built once per window and the viewer
  only assigns indices afterwards. It is rebuilt only if the palette itself moved.
- It trusts `add()`'s return value. That is not safe: Cheat Engine's `customimagelist_add`
  returns the **pre-insert Count** when it rejects a bitmap, so a failed add yields a
  plausible-looking index for an image that is not there. Success is confirmed by watching
  `Count` grow. The same trap is documented in `Manifold-TemplateLoader-Icons`.

A bitmap that does not match the list's `Width`/`Height` is stretched by
`TFPImageCanvas.StretchDraw`, not clipped, so the size is read back after being set rather than
assumed. Where `createImageList` is missing the list simply runs without icons.

---

## 9. Theming

`Manifold-TableFiles-Theme.lua` is a sibling of `Manifold-TemplateLoader-Theme.lua`, not a
require of it.

Neither loads `Manifold.Forms`. That module defines the global `Forms` class and belongs to the
Cheat Table's lifecycle, so a second copy loaded from autorun is exactly the collision
`Manifold.Bootstrap` exists to detect. Both themes instead read `forms.ActiveDesignTheme` when a
table has one live and adopt its palette read-only, falling back to the bundled Bearded-Arc
colours otherwise. The palette is re-read whenever a window opens.

### 9.1 What cannot be themed

`TSynAASyn` hard-codes its token colours and exposes no attributes to Lua, so the code area takes
Cheat Engine's own editor background instead of a palette colour. That keeps the tokens readable
whether Cheat Engine came up light or dark, which a fixed colour could not.

A `TListView` paints its rows from `Color` and `Font`, but the selection bar comes from the
system highlight brush and is not reachable without owner drawing. The list is themed, the
selection stays as Windows draws it.

### 9.2 Properties that are not in Cheat Engine's binding

`ViewStyle`, `MultiSelect`, `FullRowSelect`, `AutoWidthLastColumn`, `OnSelectItem`, `OnDblClick`
and `OnColumnClick` are not part of CE's documented ListView binding. They reach Lazarus through
CE's published-property RTTI fallback, which is why every one of them is set through `safeSet` or
a `pcall`: a build that lacks one degrades rather than raising.

`TSynEdit.Options` is the same kind of property. It is read back as its bracketed string form and
rewritten from its own tokens to drop `eoScrollPastEol`, which otherwise lets the caret sit
anywhere to the right of a line and start typing there. If the property cannot be read the set is
left alone rather than replaced with a guess.

### 9.3 Where failures must not be silent

Every individual assignment wrapped in its own `pcall` is how a context menu came to render its
captions and shortcuts perfectly while doing nothing at all: the one assignment that mattered
failed and left no trace. Menu construction is therefore one `pcall` per entry with the failure
reported, and the popup is built the way `Manifold.Teleporter` builds its tree menu — owned by
the control it belongs to, assigned to that control's `PopupMenu` straight away, handlers
assigned directly.

---

## 10. Tests

```bash
lua Manifold-TableFiles-Tests/Run.lua <projectDir> <scratchDir>
```

Runs headless against `CEStub.lua`, with no table and no attached process. Covers the type
registry, the file layer, the image list, the editor and the window end to end.

The lifecycle section walks every path where data could be lost: editing then filtering, sorting,
refreshing, switching files, closing, exporting, renaming and deleting; import collisions in all
four resolutions; a rename whose copy does not land; a file that disappears while it is open;
and reopening the window after it was closed.
