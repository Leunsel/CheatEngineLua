# Manifold UE

> File: [`Manifold-UE/Manifold-UE.lua`](../Manifold-UE/Manifold-UE.lua)
> Version: 1.0.0 · License: MIT · Author: Leunsel

A single autorun script with no dependencies. It brings the runtime half of Manifold-UE, the
internal overlay for Unreal Engine games, into Cheat Engine: the name table, the object array and
the reflection layout are found in the running game, and offsets, types and names come from the
engine's own metadata. There is no SDK, no game profile and no signature.

Everything it does is a read of the game's memory. It injects nothing, installs no hook in the
game and calls no game function. Values change only where you edit them yourself.

## 1. Installation

1. Download `Manifold-UE.lua`.
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
[12:00:00] [Manifold-UE] [Main] Version 1.0.0 ready. Open an Unreal Engine game and use Structure Dissect or the Unreal Engine menu.
```

The script is reload safe. Its runtime handles live under `__MANIFOLD_UE_RUNTIME__` in `_G`;
executing the file again removes the previous menu, callbacks and symbol hook before installing
new ones. The custom types are registered once per Cheat Engine run and dispatch through that
table, so a reload changes their behaviour without registering them twice.

## 2. Resolving a game

The engine is resolved the first time something needs it in a process: Structure Dissect, a
menu entry, a `ManifoldUE` call, or a symbol such as `Actor_RootComponent` in the address list.
It takes a few seconds once; the result lasts until another process is opened. The Lua engine
shows what was found:

```
[Manifold-UE] [Resolve] FNamePool at 7FF7B19F6680 (4.23+) | GObjects at 7FF7B1A329E0 (data scan) | 49561 objects, 5716 types | 1.8 s (names 1.40 s, objects 0.24 s, types 0.12 s, layout 0.00 s, engine 0.03 s)
[Manifold-UE] [Resolve] UObject index C class 10 name 18 outer 20 | Super 40 Properties 50 Name 28 Next 20 Offset 4C Size 3C Extra 78 | FField fields, float vectors
```

When a stage fails, the message names it ("object array (GObjects) not found", "property chain of
ScriptStruct 'Vector' not found", ...). **Unreal Engine → Resolve again** starts over, for example
after the game finished loading.

The stages, in order:

| Stage | How |
|---|---|
| Name table, UE 4.23+ | Block 0 of `FNamePool` starts with the entries `None` and `ByteProperty`. An array of bytes scan finds the block, a pointer scan finds `Blocks[0]` inside a loaded image, 0x10 into the pool. |
| Name table, UE 4.22 and older | The `FNameEntry` of `None` has index 0. Two pointer scans lead from it to its chunk and from the chunk to the `TNameEntryArray`. Entries 1 and 2 must read `ByteProperty` and `IntProperty`. |
| Object array | Modular builds export `GUObjectArray` from `<App>-CoreUObject-*.dll`. Otherwise the writable sections of the executable (and of Core/CoreUObject in modular builds) are searched for the counters of `FChunkedFixedUObjectArray`; a second, slower pass tries the other known layouts, including the fixed array of 4.11 to 4.19. |
| UObject layout | The first 64 objects are the CoreUObject package and its classes. Their item size, index offset (objects carry their own index), name offset (`/Script/CoreUObject` or `Object` must decode), class offset (`Object` is a `Class`, the package a `Package`) and outer offset are read from them. |
| Types | One pass over the object array indexes every class, struct and enum by name. |
| Reflection layout | `UStruct::SuperStruct` from Struct → Field → Object. The property chain, field name, next and offset from ScriptStruct `Vector`, which holds exactly X, Y and Z at 0/4/8 (float, UE4) or 0/8/16 (double, UE5). `FField` (4.25+) and `UProperty` chains are told apart there. The class/struct slot behind a property from `Actor.RootComponent` and `SceneComponent.RelativeLocation`. Struct size from structs of known size. Function children and flags from functions whose declarations imply their flags. |

Only 64-bit games are supported.

## 3. Structure Dissect

The script registers a structure name lookup and a structure dissect override.

**Define new structure.** The lookup finds the object that contains the address. Objects carry
their own index, so a start is confirmed with two reads; the search walks back from the address
for up to 64 KB and falls back to a pass over the object array for larger objects. The structure
is named after the object's class and starts at the object.

**Filling.** For an object start the class is filled; for an address that starts a struct
property inside an object (for example a `RelativeLocation`), that struct is filled. Anything
else is left to Cheat Engine's own guess. The elements are:

| Unreal | Element |
|---|---|
| UObject header | `VTable`, `ObjectFlags`, `InternalIndex`, `ClassPrivate`, `NamePrivate`, `OuterPrivate` |
| float, double, (u)int8/16/32/64 | the matching type, signed where Unreal's type is signed |
| enums | the underlying size, the enum's name in the description |
| bitfield bool | a one-bit binary element at the bool's byte and bit, in hosts whose structure elements have `BitStart` and `BitLength` (Manifold Engine); in Cheat Engine one byte per bool in hex, with its mask in the description |
| FName | `UE FName` |
| FString | `UE FString` |
| object and class pointers | pointer, with the class (`AActor*`, `TSubclassOf<AActor>`) in the description |
| weak, lazy and soft object pointers | `UE Object Index` |
| nested structs | inline, as `RelativeLocation.X`, up to six levels deep |
| static arrays | one element per entry, as `Name[i]` |
| TArray | the data pointer, `.Num` and `.Max` |
| TSet, TMap | the element pointer and `.Num` |
| delegates | the object reference and the function name |
| not reflected | 8-byte slots up to the class size: a pointer where the live value looks like one, hex otherwise |

**Expanding pointers.** Expanding a pointer to another object calls the same override, so it is
filled from its own class, which is the live class (`ABP_Player_C`), not just the declared one.

Expanding a TArray's data pointer fills the block from the array's element type, named after it
and its length (`TArray<AActor*>[12]`): pointers for object arrays (expanding one dissects that object), the struct's
fields per entry for struct arrays, plain values otherwise, up to 64 entries and never more than
`.Num`. This works for the arrays of the objects filled in this session; the data pointer of an
array that has been reallocated since, or of another instance shown in a second column, is left to
Cheat Engine's own guess.

The checkbox **Unreal Engine → Structure Dissect uses Unreal names** turns both callbacks off and
on.

## 4. Custom types

| Name | Bytes | Shows |
|---|---|---|
| `UE FName` | 8 | the name, with its number suffix (`BP_Player_C_2147481654`) |
| `UE FString` | 16 | the string the `TCHAR*` points at, up to 512 characters |
| `UE Object Index` | 8 | the object a `FWeakObjectPtr` refers to, as `Name (Class)` |

They show `(Unreal Engine not resolved)` until the engine was resolved in the current process;
they never start a resolve themselves. `UE FName` can be written with a name that has been read
before; the other two are read only.

## 5. Symbols and records

After a resolve, `GObjects`, `FNamePool` (`GNames` before 4.23) and `GameEngine` are registered.

Property offsets are named `<Type>_<Property>`, the type being the one that declares the property:
`Actor_RootComponent`, `SceneComponent_RelativeLocation`, `Vector_Z`. A symbol lookup callback
resolves them on demand, so an address such as

```
[[[[[[[[GameEngine+Engine_GameViewport]+GameViewportClient_World]+World_OwningGameInstance]+GameInstance_LocalPlayers]+0]+Player_PlayerController]+PlayerController_AcknowledgedPawn]+Actor_RootComponent]+SceneComponent_RelativeLocation+Vector_Z
```

keeps working in the next session and after a game update.

Structure Dissect and such a symbol resolve the engine on their own only in a process that looks
like an Unreal game: a `-Win64-` or `Shipping` executable, one under `Binaries\Win64`, a
CoreUObject module, or an executable that carries the UTF-16 package name `/Script/CoreUObject`
(one scan of the main module, once per process). Any other process is given up after that scan.
Without this check the name pool scan ran in every process, and in a Godot game a false pool led
to a 19-second search for the object array on the first dissect. **Resolve again** and the
`ManifoldUE` functions still try any process, including the slower search for older name tables.

Every symbol the script registered (`GObjects`, `FNamePool`, `GameEngine`, the offsets) is
unregistered again when another process is opened, so they never name addresses of the next
game.

`ManifoldUE.record` builds that address and the matching record:

```lua
ManifoldUE.record("Pawn Z", nil, "RootComponent", "RelativeLocation", "Z")
```

The steps start at the local pawn. With `nil` as type, the type follows the property: float,
double, integers, bytes, `UE FName` and `UE FString`. `ManifoldUE.recordFrom(object, root,
description, type, ...)` starts at any object.

## 6. The Unreal Engine menu

| Entry | Does |
|---|---|
| Status | what was resolved, refreshed when the menu opens |
| Resolve again | forgets the process's results and resolves from scratch |
| Dissect GameEngine / World / local PlayerController / local Pawn | opens Structure Dissect on it, through `GameEngine → GameViewport → World → OwningGameInstance → LocalPlayers[0] → PlayerController → AcknowledgedPawn` |
| Dissect object at address... | asks for an address or expression and dissects the object that contains it |
| Inspector... | the type browser below |
| Who owns an address... | names the object, class and property path of an address and offers to dissect the owner |
| Structure Dissect uses Unreal names | turns the dissect callbacks off and on |

**Inspector.** The left list holds every class and struct; typing filters it, and `.text`
searches property names instead. The right list shows the selected type's properties with offset,
type and declaring type, or its functions with flags and parameters. The buttons dissect a live
instance, list up to 500 instances to pick one from, switch between properties and functions,
copy the selected property's offset symbol, and print the type as a C++-like listing to the Lua
console.

## 7. Lua API

Every function resolves the engine first if needed and raises an error when that fails.
Addresses may be numbers, symbols or expressions; types may be names or addresses.

| Function | Returns |
|---|---|
| `init(force)` | `true`; `force` resolves again |
| `status()` | one line about the current process |
| `type(name)` | the class or struct object |
| `fields(type, ownOnly)` | properties sorted by offset: `name`, `type`, `offset`, `size`, `dim`, `owner`, `mask`, `byteOffset`, `inner`, ... |
| `field(type, name)`, `offset(type, name)` | one property, its offset |
| `functions(class, inherited)` | `name`, `owner`, `flags`, `params` |
| `enum(name)` | `{ name, value }` entries |
| `dump(type)`, `search(text)` | printed listings, also returned |
| `instances(class, limit)` | live objects of the class and its children, without default objects |
| `find(name or full name)` | the first object with that name |
| `owner(address)` | the object that contains the address and its class |
| `claims(address)` | whether this script names the address; for other dissect scripts such as Manifold RTTI, resolves the way a dissect does (at most once per process, never the full search) and never raises |
| `whois(address)` | `"Name (Class) +offset: path  type"` and the details |
| `engine()`, `world()`, `controller()`, `pawn()` | the objects of the local player's chain |
| `walk(object, root, ...)` | the address of a property path and its symbol expression |
| `pawnField(...)` | `walk` from the engine to the local pawn and on |
| `record(description, type, ...)`, `recordFrom(object, root, description, type, ...)` | a new address list record |
| `dissect(address)` | opens Structure Dissect on the object |
| `isOffline()` | `true` offline, `false` connected or hosting remote players, `nil` cannot tell |
| `name(address)`, `nameOf(object)`, `fullName(object)`, `classOf(object)`, `className(object)` | names and classes |
| `count()`, `objectAt(index)`, `isObject(address)`, `objects()`, `names()`, `layout()` | the raw object array and the resolved layout |

## 8. Limits

- 64-bit games only.
- Games that encrypt or move their name table or object array, or that change `FNameEntry`, are
  not found.
- Native members are shown as raw slots; only reflected properties have names.
- `FText`, `TSet` and `TMap` contents are not decoded.
- The pre-4.23 name table is found for the common `FNameEntry` layouts (text at 0x10, 0x0C or
  0x08).
