# Manifold Godot

> File: [`Manifold-Godot/Manifold-Godot.lua`](../Manifold-Godot/Manifold-Godot.lua)
> Version: 1.0.0 · License: MIT · Author: Leunsel

A single autorun script with no dependencies. It teaches Cheat Engine the bookkeeping of Godot 4
games: the StringName table, the ObjectDB slot array, ClassDB's class table and the SceneTree are
found in the running game, and every member offset the script uses is measured there too. There is
no game profile, no version table and no signature.

Everything it does is a read of the game's memory. It injects nothing, installs no hook in the
game and calls no game function. Values change only where you edit them yourself.

## 1. Installation

1. Download `Manifold-Godot.lua`.
2. Drop it into Cheat Engine's `autorun` folder, typically:

```
C:\Program Files\Cheat Engine 7.5\autorun
```

Portable builds keep that folder somewhere else. The Lua console tells you where:

```lua
return getAutorunPath()
```

On load the script prints one line:

```
[12:00:00] [Manifold-Godot] [Main] Version 1.0.0 ready. Open a Godot 4 game and use Structure Dissect or the Godot Engine menu.
```

The script is reload safe. Its runtime handles live under `__MANIFOLD_GODOT_RUNTIME__` in `_G`;
executing the file again removes the previous menu, callbacks and symbol hook before installing
new ones. The custom types are registered once per Cheat Engine run and dispatch through that
table.

## 2. Resolving a game

The engine is resolved the first time something needs it in a process: Structure Dissect, a menu
entry, a `ManifoldGodot` call, or one of its symbols in the address list. It takes well under a
second; the result lasts until another process is opened. The Lua engine shows what was found:

```
[Manifold-Godot] [Resolve] Godot 4.6.3.stable.mono.custom_build | StringNames at 7FF71AE58090 | ObjectDB at 7FF71AED82B8 (5102 objects) | ClassDB at 7FF71AFDF368 (969 classes) | 0.3 s (version 0.01 s, names 0.11 s, objects 0.03 s, classes 0.05 s, scene 0.06 s)
[Manifold-Godot] [Resolve] StringName hash 10 text 8 size 8 | Object id 50 type B8 (gdtype) script 60 meta 68 | ClassInfo name 148 inherits 140 create 158 methods 28 | MethodBind name 10 code 48
[Manifold-Godot] [Resolve] SceneTree 299445F2AC0, root 29945902820 | Node parent 140 owner 148 children 150 name 1D8 tree 1E0 | Resource path 140
```

When a stage fails, the message names it ("StringName table not found", "ClassDB class table not
found", ...). **Godot Engine → Resolve again** starts over.

The stages, in order:

| Stage | How |
|---|---|
| Version | The executable holds `Godot Engine v4.` as a literal. A Godot 3 executable that carries `Godot Engine v3.` is reported as such; one without either literal is "not a Godot 4 game". A game that is not Godot costs this one scan of its module and nothing more. |
| StringName table | 65536 slots of name pointers are the densest run of heap pointers in the executable's data. Every name in a slot belongs there by its own hash, so each one votes for where the table starts and at which offset the hash sits; only the real pair gets a majority. The text field, a C string before 4.4, and where the string keeps its length are then read off sampled names, checked against their djb2 hash. |
| ObjectDB | The static pointer to the slot array sits next to `slot_max`, a power of two. Every live object stores its own ObjectID (slot plus validator), which both confirms the array and gives the offset of `Object::_instance_id`. |
| ClassDB | The `HashMap<StringName, ClassInfo>` whose first class is `Object`. In `ClassInfo`, `name` equals the key, `inherits` reads `Object` for Node and `Node` for Timer, the creation function is the code pointer whose decoded `memnew` size grows from Node to Timer, and `method_map` is the map whose entries are method binds that carry their own name. |
| Class names | The pointer in every object that leads to a registered class name: `GDType` in 4.6, the cached class StringName before. Run-time type information (MSVC or Itanium) is the fallback for objects still under construction. |
| Scripts | The pointer whose target points back at the object is the script instance. Its script and `Resource::path` (the String that starts with `res://`) follow from that. |
| Metadata | The HashMap after the script instance, recognised by its shape even when it is empty. |
| Scene tree | The one `SceneTree` object points to a `Window` whose name is `root` and which points back at the tree. Its children map, and the children's pointer back to it, give `Node::children` and `Node::parent`. The tree is optional; early in a game's start it may not exist yet and is looked for again on demand. |

Class sizes come from the creation functions: ClassDB keeps no `sizeof`, but `memnew(T)` loads the
size right before it allocates. Abstract classes use the size of their closest creatable base.

Only 64-bit games are supported.

## 3. Structure Dissect

The script registers a structure name lookup and a structure dissect override.

**Define new structure.** The lookup finds the object that contains the address: a sorted list of
all live objects (refreshed every two seconds) gives the closest start below the address, and the
class size decides whether the address is still inside it. The structure is named after the
object's Godot class and starts at the object.

**Filling.** The elements are:

| Godot | Element |
|---|---|
| Object | `VTable`, `_extension`, `_extension_instance`, `_instance_id` (`Godot ObjectID`), `_gdtype_ptr`, `script_instance` with the instance class and script path in its description, `metadata` |
| Node | `scene_file_path` (`Godot String`), `instance_state`, `inherited_state`, `parent` and `owner` with their names, `children`, `name` (`Godot StringName`), `tree` |
| Resource | `path` |
| SceneTree | `root` |
| HashMap | `.elements`, `.hashes`, `.head`, `.tail`, `.capacity_index`, `.size` |
| everything else | 8-byte slots up to the class size: a pointer where the live value looks like one, hex otherwise |

**Expanding pointers.** Expanding a pointer to another object fills that one from its own class.
Expanding `children.head` or `metadata.head`, and the `next` of any entry, fills the map entry:
`next`, `prev`, `key` and the node or the Variant. A Variant shows its type and its value as the
matching element: bool, int, float, String, StringName, the object reference, or the float and
integer vectors (`Vector2`, `Vector3`, `Color`, `Quaternion`, ...).

Expanding `script_instance` fills the instance: its owner, its script and, for C#, the GCHandle
whose slot holds the managed object.

The checkbox **Godot Engine → Structure Dissect uses Godot names** turns both callbacks off and on.

**With Manifold RTTI and Manifold UE.** All three can be loaded together, in any order. Godot
games built with MSVC or clang-cl carry run-time type information on every engine object; RTTI
asks `ManifoldGodot.claims` first and leaves every object, script instance and map entry this
script names to it, also a C++ object embedded inside a Godot object. C++ objects outside the
ObjectDB stay RTTI's. Manifold UE does not resolve in a Godot game at all.

## 4. Custom types

| Name | Bytes | Shows |
|---|---|---|
| `Godot StringName` | 8 | the name |
| `Godot String` | 8 | the UTF-32 string, up to 4096 characters |
| `Godot ObjectID` | 8 | the object, as `Class 'name' #slot`, or `#slot (freed)` |

They show `?` until the engine was resolved in the current process; they never start a resolve
themselves. All three are read only.

## 5. Symbols

After a resolve these are registered. Every name starts with `Godot`, so none can meet Manifold
UE's `<Type>_<Property>` offsets:

| Symbol | Is |
|---|---|
| `GodotStringNames` | the StringName table |
| `GodotObjectDB` | the static that holds the slot array pointer |
| `GodotClassDB` | `ClassDB::classes` |
| `GodotSceneTree` | the static that holds the SceneTree pointer |
| `GodotObject_instance_id`, `GodotObject_gdtype`, `GodotObject_script_instance`, `GodotObject_metadata` | Object member offsets |
| `GodotNode_scene_file_path`, `GodotNode_parent`, `GodotNode_owner`, `GodotNode_children`, `GodotNode_name`, `GodotNode_tree` | Node member offsets |
| `GodotSceneTree_root`, `GodotResource_path` | the root window and a resource's path |

A symbol lookup callback also resolves them on demand, so an address list entry built from them
works again in the next session.

Nodes have symbols by path: `GodotPath__root__Main__Player` is `/root/Main/Player`, looked up
fresh every time it is used and never registered, because the node is a new object after every
scene change. `ManifoldGodot.symbol(node)` builds it; nodes whose path has characters other than
letters, digits and single underscores have none. With them an address like

```
[GodotPath__root__Main__Player+GodotNode_parent]+GodotNode_name
```

survives a restart of the game.

**Godot Engine → Name engine methods in the disassembler** registers `Class::method` for every
method ClassDB binds (`Node::get_name`, `SceneTree::get_root`, ...), at the code the method bind
calls. In Unrailed 2 that is 14611 symbols in a quarter of a second. `Class::vftable` stays
Manifold RTTI's; no method of that name is registered.

Every symbol the script registered is unregistered again when another process is opened, so the
method names of one game never label the code of the next.

## 6. The Godot Engine menu

| Entry | Does |
|---|---|
| Status | what was resolved, refreshed when the menu opens |
| Resolve again | forgets the process's results and resolves from scratch |
| Dissect SceneTree / root window | opens Structure Dissect on it |
| Dissect node by path... | asks for a path such as `/root/Main/Player` |
| Dissect object at address... | asks for an address or expression and dissects the object that contains it |
| Print scene tree | prints every node with its class, script and address to the Lua console |
| Find nodes by name... | prints the nodes whose name contains the text |
| Instances of a class... | prints up to 500 live objects of the class and its subclasses |
| Who owns an address... | names the object, class, offset, node path and script, and offers to dissect the owner |
| Name engine methods in the disassembler | see above |
| Structure Dissect uses Godot names | turns the dissect callbacks off and on |

## 7. Lua API

Every function resolves the engine first if needed and raises an error when that fails.
Addresses may be numbers, symbols or expressions; nodes may also be paths that start with `/`.

| Function | Returns |
|---|---|
| `init(force)` | `true`; `force` resolves again |
| `status()` | one line about the current process |
| `version()` | the version text, major, minor and patch |
| `layout()` | the probed offsets |
| `count()`, `objects(limit)` | the live objects |
| `isObject(address)`, `fromId(id)`, `idOf(object)` | ObjectDB lookups |
| `className(object)`, `size(class or object)` | the Godot class and its size |
| `classes()`, `class(name)` | class names; `name`, `inherits`, `ancestry`, `size`, `methods` |
| `inherits(class, base)` | `true` when the class is or derives from the base |
| `methods(class, inherited)`, `method(class, name)` | `name`, `class`, `address`, `bind`, `virtual`; one method's code address |
| `instances(class, limit, exact)` | live objects of the class and, unless `exact`, its subclasses |
| `tree()`, `root()`, `node(path)` | the SceneTree, the root window, a node |
| `nodeName(node)`, `parent(node)`, `children(node)`, `path(node)`, `symbol(node)` | the node's place in the tree |
| `find(text, limit)` | nodes whose name contains the text |
| `printTree(node, depth, limit)` | the printed tree, also returned |
| `script(object)`, `scriptPath(object)`, `managed(object)` | the script, its path, and for C# the managed object and its handle |
| `name(address)`, `nameText(data)`, `findName(text)`, `string(address)`, `resourcePath(resource)` | names and strings |
| `owner(address)`, `whois(address)` | the object containing an address, a description of it |
| `claims(address)` | whether this script names the address; for other dissect scripts, resolves at most once per process and never raises |
| `dissect(address or path)` | opens Structure Dissect on the object |
| `nameMethods()` | registers the method symbols and returns how many |

## 8. Limits

- 64-bit Godot 4 games only. Godot 3 keeps its objects and names in different structures.
- Verified on one game: Unrailed 2, Godot 4.6.3 (.NET), built with clang-cl. The layouts of other
  4.x releases, debug templates and MinGW builds are told apart by the probes, but no such game
  has been tested.
- Engine C++ members beyond Object, Node, Resource and SceneTree are shown as raw slots; ClassDB
  describes properties by getters and setters, not by offsets.
- GDScript member variables and the fields of C# objects are not decoded. For C# the managed
  object is reachable through `script_instance → gchandle.handle`, where Cheat Engine's own guess
  takes over.
- Games that encrypt or move the StringName table or ObjectDB are not found.
