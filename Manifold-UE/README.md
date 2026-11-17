# Manifold UE

`Manifold-UE.lua` is an autorun script that teaches Cheat Engine the reflection data of Unreal
Engine 4 and 5 games. It needs no SDK, no game-specific offsets and no signatures: it finds the
name table, the object array and the reflection layout in the running game and asks the engine
for everything else.

## Highlights

Structure Dissect knows Unreal objects. "Define new structure" names the structure after the
object's class and starts it at the object, even when the address points into its middle. The
fields are the class's reflected properties with their real names: nested structs inline,
bitfield bools as single bits (or with their masks), enums and object pointers with their types, and the native bytes
in between as pointers or hex values. Expanding a pointer to another object fills that one the
same way, and expanding a TArray shows its entries.

Three custom types show Unreal values as text: `UE FName`, `UE FString` and `UE Object Index`
(weak and soft object references).

Offsets get names. `Actor_RootComponent` or `SceneComponent_RelativeLocation` work in any address
expression and resolve again in every session, so an address list entry built from them survives
a game update. `GObjects`, `FNamePool` (or `GNames`) and `GameEngine` are registered as well.

The **Unreal Engine** menu has an inspector (types, properties, functions, live instances), a
"Who owns an address" lookup and quick dissects of the engine, the world, the local player
controller and the local pawn.

`ManifoldUE` is a Lua API for tables and the Lua console: `ManifoldUE.offset("Actor",
"RootComponent")`, `ManifoldUE.pawn()`, `ManifoldUE.whois(address)`, `ManifoldUE.record(...)` and
more.

The script only reads the game. Nothing is injected, hooked or called inside it.

Supported are x64 games on UE 4.11 to 5.6, monolithic and modular builds.

## Installation

Download `Manifold-UE.lua` and place it in the autorun folder, which is usually
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
2. Open Structure Dissect on any object address and choose "Define new structure". The first
   use in a process resolves the engine, which takes a few seconds; the Lua engine prints what it
   found.
3. Or use **Unreal Engine → Dissect local Pawn** and expand from there.

The full reference, including how the engine is found and what each menu entry does, is in
[`docs/Manifold-UE.md`](../docs/Manifold-UE.md).
