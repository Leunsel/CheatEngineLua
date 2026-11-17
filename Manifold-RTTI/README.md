# Manifold RTTI

`Manifold-RTTI.lua` is an autorun script that reads the run-time type information (RTTI) of C++
games built with MSVC or clang-cl. Every object of a class with virtual functions starts with a
pointer to its class's virtual function table, and with RTTI switched on, which is the compiler's
default, the slot in front of that table leads to the class's name and its base classes. The
script reads that in the running game. It needs no signatures and no offsets.

## Highlights

Structure Dissect names objects. "Define new structure" names the structure after the object's
class (`Game::Player`, `std::_Func_impl_no_alloc<...>`), and an address that points at a base
class part of an object moves to the object's start. Expanding a pointer names the child
structure the same way.

After Cheat Engine's own guess, the fields that RTTI can explain get names: the object's virtual
function table pointers (`vftable`, `vftable (ITick)`), virtual base tables, member objects with
virtual functions, and pointer fields after the class they point to (`Game::Weapon*`).

Classes get symbols. `Game::Player::vftable` works in any address expression and resolves again
in every session, so a table can find a class's objects after a game update moved everything.

The **RTTI** menu answers "who owns this address", finds every object of a class and dissects an
object.

`ManifoldRTTI` is a Lua API for tables and the Lua console: `ManifoldRTTI.className(address)`,
`ManifoldRTTI.instances("Game::Weapon")`, `ManifoldRTTI.whois(address)` and more. Where the host
has no `getRTTIClassName`, the script provides it.

The script only reads the game. Nothing is injected, hooked or called inside it.

Supported are 64-bit and 32-bit programs. Unreal Engine games switch RTTI off by default and GCC
builds use another format; there the script finds nothing and stays out of the way. It runs
alongside [Manifold UE](../Manifold-UE/README.md) and leaves Unreal objects to it.

## Installation

Download `Manifold-RTTI.lua` and place it in the autorun folder, which is usually
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
2. Open Structure Dissect on an object address and choose "Define new structure". The proposed
   name is the object's class.
3. Or use **RTTI → Who owns an address...** on any address inside an object.

The full reference is in [`docs/Manifold-RTTI.md`](../docs/Manifold-RTTI.md).
