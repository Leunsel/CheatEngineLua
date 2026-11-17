# Manifold Godot

`Manifold-Godot.lua` is an autorun script that teaches Cheat Engine the bookkeeping of Godot 4
games. It needs no game-specific offsets and no signatures: it finds the StringName table, the
ObjectDB, ClassDB and the SceneTree in the running game and measures every member offset it uses
there.

## Highlights

Structure Dissect knows Godot objects. "Define new structure" names the structure after the
object's Godot class and starts it at the object, even when the address points into its middle.
The Object and Node members are named (instance id, script instance, metadata, name, parent,
owner, children, scene tree), and the native bytes up to the class's real size follow as pointers
or hex values. Expanding a child list or metadata shows its entries, expanding a script instance
shows its script and, for C#, the managed object handle.

Three custom types show Godot values as text: `Godot StringName`, `Godot String` and
`Godot ObjectID`.

Offsets and nodes get names. `GodotNode_parent` or `GodotObject_script_instance` work in any
address expression, and `GodotPath__root__Main__Player` is the node at `/root/Main/Player`, looked
up again every time, so an address list entry built from them survives a restart of the game.

It runs side by side with Manifold UE and Manifold RTTI in any load order: each answers only for
its own engine, and RTTI leaves Godot objects to this script.

The disassembler can name the engine's methods (`Node::get_name`, `SceneTree::get_root`, ...), read
from the method binds ClassDB keeps for every class.

The **Godot Engine** menu dissects the scene tree, its root and any node by path, prints the scene
tree, finds nodes by name and instances of a class, and tells who owns an address.

`ManifoldGodot` is a Lua API for tables and the Lua console: `ManifoldGodot.node("/root/Main")`,
`ManifoldGodot.printTree()`, `ManifoldGodot.instances("Camera3D")`,
`ManifoldGodot.whois(address)` and more.

The script only reads the game. Nothing is injected, hooked or called inside it.

Supported are x64 Godot 4 games. It has been verified on Godot 4.6.3 (.NET).

## Installation

Download `Manifold-Godot.lua` and place it in the autorun folder, which is usually
`C:\Program Files\Cheat Engine 7.5\autorun`. On a portable build, or if Cheat Engine was
installed elsewhere, the folder will be somewhere else.

To find it, run this in the Cheat Engine Lua console:

```lua
return getAutorunPath()
```

The console prints the full path. Place the script in that folder and Cheat Engine will load it
the next time it starts.

## First steps

1. Open the game's process.
2. Use **Godot Engine → Print scene tree**. The first use in a process resolves the engine, which
   takes well under a second; the Lua engine prints what it found.
3. Pick a node and use **Godot Engine → Dissect node by path...**, or open Structure Dissect on any
   object address and choose "Define new structure".

The full reference, including how the engine is found and what each menu entry does, is in
[`docs/Manifold-Godot.md`](../docs/Manifold-Godot.md).
