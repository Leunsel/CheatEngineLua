# Manifold Table Files

`Manifold-TableFiles.lua` is an autorun extension for Cheat Engine that puts every file attached
to the open Cheat Table into one window, with an editor beside the list.

Cheat Engine reaches these files only through `Table` in the menu bar, one context menu per file.
There is no enumeration call and no way to see what a file contains without opening
it. This window replaces all of that.

## Highlights

The list is multi-select, so removing or exporting twenty files is one action. Each row carries a
small colour-coded file glyph, its type and its size, and the columns sort.

`.lua` opens in a SynEdit with Lua highlighting, `.CEA` / `.AA` / `.asm` in one with Auto
Assembler highlighting. Everything else opens as plain text rather than in the wrong colours.

Binary attachments are described, never loaded into an editor, so their bytes cannot be altered by
being looked at. Export, rename and remove still work on them.

Nothing loses work silently. Switching files, closing, renaming, exporting, deleting the open file
and replacing it during an import all pass through one gate that offers **Save**, **Discard** and
**Cancel**. Filtering, sorting and Refresh never touch the buffer at
all.

Import never overwrites an attachment on its own. A clash offers **Replace**, **Keep both**,
**Skip** or **Cancel**, and with several files to import the answer can be applied to the rest.

The window carries its own copy of the Manifold design framework, so it follows the Cheat Table's
active theme when one is loaded and falls back to the bundled Bearded-Arc palette when it is not.

![Preview](https://i.imgur.com/yMLZZgg.png)

## Installation

Place `Manifold-TableFiles.lua` **and** the `Manifold-TableFiles-Modules` folder next to each
other in the autorun folder, which is usually `C:\Program Files\Cheat Engine 7.5\autorun`. On a
portable build, or if Cheat Engine was installed elsewhere, the folder will be somewhere else.

To find it, run this in the Cheat Engine Lua console:

```lua
return getAutorunPath()
```

The layout in the autorun folder has to be:

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

## Opening it

With [Manifold CE Utility](../Manifold-CE-Utility) installed, use **Manifold -> Open Table File
Viewer**.

Without it, from the Lua console or a table's Lua script:

```lua
ManifoldTableFiles:Open()
```

This module registers no menu entry of its own, so the two never produce a duplicate one.

## The window

| Control | Effect |
|---|---|
| Add... | Attaches files from disk. Multi-select; a name clash asks what to do |
| New... | Creates a file, with starter content for the type chosen (Bug #1) |
| Rename | Renames the selected file, copy-verify-delete (Bug #2) |
| Duplicate | Copies the selected file under a free name |
| Remove | Deletes the selected files, one confirmation for the whole selection |
| Export... | One file asks for a name, several ask for a folder |
| Refresh | Re-reads the table's file list; the buffer and selection survive |
| Filter | Narrows by name, extension or type name. Case insensitive, plain substring |
| Save | Writes the editor's contents back into the table |

Right-clicking the list offers the file actions. Right-clicking the editor offers undo, the
clipboard, Find, Replace and Go to line. The shortcuts are dispatched by the window itself, and
which pane has focus decides what a key means, so `Delete` still deletes a character while the
caret is in the editor and undo and the clipboard stay SynEdit's own.

## Theming

`Manifold-TableFiles-Theme.lua` is a sibling of `Manifold-TemplateLoader-Theme.lua`, not a
require of it, and neither loads `Manifold.Forms`. That module defines the global `Forms` class
and belongs to the Cheat Table's lifecycle, so a second copy loaded from autorun is exactly the
collision `Manifold.Bootstrap` exists to detect. Both themes instead read
`forms.ActiveDesignTheme` when a table has one live and adopt its palette read-only.

The palette is re-read every time a window opens, so switching the table's theme is picked up by
the next open.