# Manifold RTTI

> File: [`Manifold-RTTI/Manifold-RTTI.lua`](../Manifold-RTTI/Manifold-RTTI.lua)
> Version: 1.0.0 · License: MIT · Author: Leunsel

A single autorun script with no dependencies. It reads the run-time type information that MSVC
and clang-cl put into C++ programs: the name of every class with virtual functions and the list
of its base classes. Structure Dissect, the symbol handler and a small menu use it to name what
is in memory.

Everything it does is a read of the game's memory. It injects nothing, installs no hook in the
game and calls no game function.

## 1. Installation

1. Download `Manifold-RTTI.lua`.
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
[12:00:00] [Manifold-RTTI] [Main] Version 1.0.0 ready. Structure Dissect names C++ objects; the RTTI menu finds them.
```

The script is reload safe. Its runtime handles live under `__MANIFOLD_RTTI_RUNTIME__` in `_G`;
executing the file again removes the previous menu, callbacks, symbol hook and the symbols the
previous run registered before installing new ones.

## 2. Where the information comes from

An object of a class with virtual functions starts with a pointer to the class's virtual function
table. With RTTI the pointer-sized slot in front of that table points to a *complete object
locator*, which leads to:

- the *type descriptor*, holding the class's decorated name (`.?AVPlayer@Game@@` is the class
  `Game::Player`), and
- the *class hierarchy descriptor*, holding every base class with its offset in the object.

The locator also says at which offset of the complete object its table pointer sits, so a pointer
to a base class part of an object leads back to the object's start.

Random data rarely looks like this, and the script checks every step: the locator's signature, on
64-bit its own image-relative address, a type descriptor whose name is a decorated class name, a
hierarchy with a sane number of bases, and every address inside a loaded module. A value that
passes all of them is RTTI.

Nothing is scanned when a process opens. Classes are learned from the addresses Structure Dissect,
the menu or a script ask about, and a class asked for by name is searched for when it is needed
(section 4).

There is nothing to read in:

- classes without virtual functions, which have no table;
- programs built without RTTI (`/GR-`), which includes Unreal Engine games by default;
- programs built with GCC or MinGW, which use the Itanium format.

## 3. Structure Dissect

The script registers a structure name lookup and a structure dissect override.

**Define new structure.** When the address holds a virtual function table pointer, the structure
is named after the object's class. When that pointer belongs to a base class part of a larger
object, the structure moves to the object's start. A class whose only virtual functions come from
a virtual base starts with a pointer to its virtual base table instead; the lookup follows it to
the base's table pointer and names the class all the same. An address that is a virtual function
table itself is named `<Class>::vftable`.

**Expanding pointers.** Expanding a pointer to an object names the child structure after its
class, which is the object's real class, not the declared one.

**Labels.** For an object start the override first lets Cheat Engine guess the structure (4 KB,
through `structure:autoGuess`), then names the pointer fields the guess left unnamed:

| Field holds | Name |
|---|---|
| the object's own table pointer | `vftable` |
| the table pointer of a base class part | `vftable (ITick)` |
| a virtual base table pointer | `vbtable` |
| the table pointer of a member object with virtual functions | `Outer::Inner vftable` |
| a pointer to an object | `Game::Weapon*` |
| a pointer to a base class part of an object | `ITick*` |

In a structure of a virtual function table, the entries are named `virtual 0`, `virtual 1` and on,
up to the locator of the next table.

A host whose `structure:autoGuess` does nothing would be left with an empty structure; there the
override declines, the host's own guess runs and only the name comes from the script.
`ManifoldRTTI.label(structure, address)` labels such a structure afterwards.

**Unreal Engine and Godot.** When [Manifold UE](Manifold-UE.md) or
[Manifold Godot](Manifold-Godot.md) is installed and claims an address, the script leaves it to
that script, which knows the real property names or engine members. It asks their `claims`
function only: `ManifoldUE.owner` resolves with the full search and does not remember a failure,
so in a game that is not Unreal it would search the whole process again on every lookup.

The checkbox **RTTI → Structure Dissect uses RTTI** turns both callbacks off and on.

## 4. Symbols

Every class the script meets gets a symbol for its virtual function table, so the disassembler,
the memory view and pointer values show the class:

| Symbol | Table |
|---|---|
| `Game::Player::vftable` | the table at the object's start |
| `Widget::vftable@ITick` | the table of the base class part `ITick` |
| `Diamond::vftable@28` | a table at offset 0x28 that belongs to a virtual base |

A symbol lookup callback resolves these names on demand, also for classes the script has not met
yet, so an address list entry or a script that uses `Game::Player::vftable` works again in the
next session and after a game update. `<Class>::vftable` alone always resolves to the table with
the smallest offset.

A class is found by name in three scans of one module: the decorated name leads to the type
descriptor, the descriptor's address to the locators that name it, and each locator's address to
the table behind it. The game's executable is searched first, then the other modules outside the
Windows folder. A miss is remembered until the module list is read again. Names are `Namespace::Class`;
a template instance such as `Holder<int, 4>` can only be found by name once the script has met it.

Without `registerSymbolLookupCallback` in the host, the symbols exist only for classes the script
has met in the session. `ManifoldRTTI.vtable(name)` looks one up and registers it.

## 5. The RTTI menu

| Entry | Does |
|---|---|
| Status | the process and how many classes and tables were seen, refreshed when the menu opens |
| Who owns an address... | names the object at or before the address, its class, the offset into it, the table and the base classes, and offers to dissect the object |
| Dissect object at address... | opens Structure Dissect on the object that contains the address |
| Find objects of a class... | scans writable memory for the class's table pointer, prints every object's address to the Lua console and offers to dissect the first |
| Forget what was learned | drops what the script knows about the process and its symbols |
| Structure Dissect uses RTTI | turns the dissect callbacks off and on |

**Who owns an address.** The lookup walks back from the address, up to 16 KB, to the closest
virtual function table pointer. RTTI does not say how large a class is, so a member object with
virtual functions counts as an object of its own: an address behind such a member is reported
inside the member.

## 6. Lua API

Addresses may be numbers, symbols or expressions. Every function except `demangle`, `mangle`,
`status` and `reset` raises an error when no process is open.

| Function | Returns |
|---|---|
| `className(address)` | the class of the object whose table pointer is at the address, or nil |
| `object(address)` | `address`, `start`, `offset`, `class`, `decorated`, `vtable`, `module`, `viaVirtualBase` |
| `owner(address, window)` | the same for the object at or before the address |
| `whois(address)` | the text the menu shows |
| `bases(address or class name)` | `name`, `decorated`, `depth`, `offset`, `virtual` for the class and every base; offsets of virtual bases need an address |
| `vtable(name, base)` | the class's table; `base` picks a base class part by name or hex offset |
| `vtables(name)` | `address`, `offset`, `symbol`, `module` of every table the class has |
| `instances(name, limit)` | the start of every object of exactly that class |
| `dissect(address)` | opens Structure Dissect on the object |
| `label(structure, address)` | names the unnamed pointer fields of an existing structure, returns how many |
| `classes()` | the names of the classes met so far |
| `demangle(decorated)`, `mangle(name)` | a decorated name as text, and the decorated candidates for a name |
| `status()`, `reset()` | one line about the process; forget everything learned |

`getRTTIClassName(address)` is Cheat Engine's own function; in a host that does not have it, the
script provides it with the same result as `className`.

Finding the objects of a class after a game update:

```lua
for _, player in ipairs(ManifoldRTTI.instances("Game::Player")) do
    print(string.format("%X", player))
end
```

## 7. Names

Decorated names are turned into C++ the way type names use them: nested scopes, templates with
their arguments (types, integers and parameter packs), back references, anonymous namespaces,
pointers, references, `const`, function types and lambdas or classes inside functions. The text
leaves out `class` and `struct`, writes `const char*` and separates template arguments with `, `:

| Decorated | Shown |
|---|---|
| `.?AVInventory@Detail@Game@@` | `Game::Detail::Inventory` |
| `.?AU?$Holder@PEAUWeapon@Game@@$03@@` | `Holder<Game::Weapon*, 4>` |
| `.?AU?$Wrap@V?$function@$$A6AHMPEBD@Z@std@@@@` | `Wrap<std::function<int (float, const char*)>>` |
| `.?AUHidden@?A0x564404e4@@` | `` `anonymous namespace'::Hidden `` |
| `.?AV?$_Func_impl_no_alloc@V<lambda_4>@?1??main@@YAHHPEAPEAD@Z@HH@std@@` | `std::_Func_impl_no_alloc<main()::<lambda_4>, int, int>` |

A name the decoder cannot read, such as one with a member pointer or an array type in its
template arguments, keeps its decorated form, which is still unique and can still be looked up.

## 8. Limits

- Only classes with virtual functions, and only programs built with RTTI by MSVC or clang-cl.
- RTTI holds no class sizes and no field names; fields other than pointers keep Cheat Engine's
  guess.
- "Who owns an address" reports the nearest object, which can be a member object (section 5).
- Templates can only be found by name once the script has met them.
- `Find objects of a class` finds objects of exactly that class, not of classes derived from it.
