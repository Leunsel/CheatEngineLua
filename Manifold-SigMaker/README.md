# Manifold SigMaker

Manifold SigMaker is an autorun extension for Cheat Engine. It takes the address selected in the
disassembler, grows an array-of-bytes signature that matches it and nothing else, and puts that
signature on the clipboard.

It replaces the GH SigMaker plugin. It exists because that plugin's masking rule is wrong in ways
that change which bytes you end up scanning for, and because a plugin that carries its own length
decoder goes stale every time a new instruction set arrives. This tool carries no decoder. It asks
Cheat Engine's own disassembler which bytes of an instruction are operands.

## What it does

**It masks what actually moves.** A displacement or a branch target changes when the binary is
rebuilt or relocated, so those become wildcards. An immediate is usually a real constant that
carries uniqueness, so sub rsp,28 keeps its 28. An immediate large enough to look like an address
is masked instead. Every part of that is a setting.

**It finds the operand bytes by probing.** For each byte of an instruction it flips that byte,
hands the result back to Cheat Engine, and reads the disassembly that comes out. When the length
is unchanged and the only difference in the text is a number, that byte carries a numeric operand.
When the length or the shape changed, the byte is structural and is kept. Only the lowest bit is
flipped. That leaves bit 7 alone, which is where the sign of a one byte displacement lives, and it
moves a target the shortest distance it can, so the target usually stays inside its own module and
keeps printing with a name.

There is no opcode table to fall behind. Whatever Cheat Engine's disassembler understands, this
understands, including instruction sets that postdate the plugin it replaces. The cost is one
disassembly per byte, which for a signature of a few instructions is a few dozen calls.

**The signature grows one instruction at a time** until exactly one match remains, then the
trailing wildcards are trimmed. Bytes behind a trailing wildcard were never what made the pattern
unique, so keeping them only makes the signature longer. Growth is bounded by a maximum
instruction count and a maximum length, so a bad address fails with a message instead of walking
to the end of the region. The plugin this was modelled on had no such bound.

**It tells you when the signature leaves the function.** Bytes past a ret or an unconditional jmp
belong to whatever the linker happened to put next, which moves independently of the code you are
signing. Reaching past that point is reported rather than refused, because on an epilogue it is
often the only way to become unique at all. An epilogue such as lea rsp,[rsp+20] followed by pop
rbp and ret looks the same in every function with that frame size.

## Output

By default the clipboard holds exactly this, ready to paste into a scan or an Auto Assembler
script:

```
48 8B 4C 24 ? 66 C1 E8 08 66 8B
```

Cheat Engine's scanner accepts a single question mark as well as a doubled one, so the pattern is
usable as printed. The old tool's three line form is still available, as is any combination of the
four parts in any order:

```lua
ManifoldSigMaker:SetOutput("header,code,aobq")
```

```
Address of signature = SouthPark_TFBW.exe + 0x0D762ED9
"\x48\x8B\x4C\x24\x00\x66\xC1\xE8\x08\x66\x8B", "xxxx?xxxxxx"
"48 8B 4C 24 ? 66 C1 E8 08 66 8B"
```

| Part | Renders |
|---|---|
| aob | 48 8B 4C 24 ? 66 C1 E8 08 66 8B |
| aobq | the same, quoted |
| code | "\x48\x8B...", "xxxx?xxxxxx" |
| header | Address of signature = module.exe + 0x0D762ED9 |

Shape and case follow GH SigMaker exactly, so a signature made here drops into anything that
already consumed that tool's output. Hex is uppercase throughout, the module offset is zero filled
to eight digits, and a masked byte is written as a zero byte in the code style string and as a
question mark in the pattern.

## Installation

Place Manifold-SigMaker.lua and the Manifold-SigMaker-Modules folder next to each other in the
autorun folder, usually C:\Program Files\Cheat Engine 7.5\autorun. On a portable build the folder
is somewhere else, and the Lua console will tell you where:

```lua
return getAutorunPath()
```

The layout has to be:

```
autorun/
  Manifold-SigMaker.lua
  Manifold-SigMaker-Modules/
    Manifold-SigMaker-CE.lua
    Manifold-SigMaker-Decoder.lua
    Manifold-SigMaker-Format.lua
    Manifold-SigMaker-Host.lua
    Manifold-SigMaker-Log.lua
    Manifold-SigMaker-Menu.lua
    Manifold-SigMaker-Settings.lua
    Manifold-SigMaker-Signature.lua
    Manifold-SigMaker-Version.lua
```

If only the single file is copied, Cheat Engine prints one readable line naming the folder it
could not find, rather than a require traceback on every start. Re-running the file rebuilds
everything from fresh module code and takes the previous generation's menu entry down first, so
nothing accumulates while you edit.

## Using it

Right-click an instruction in the Memory Viewer's disassembler and pick **Manifold: Copy
Signature**.

The entry is added to the memory view's own menu component, the one named debuggerpopup. If the
memory view has never been opened when Cheat Engine starts, there is nothing to attach to yet.
Open it once and run:

```lua
ManifoldSigMaker:Install()
```

Everything the menu does is also a method, so a table's Lua script or the console can use it
without the menu:

```lua
ManifoldSigMaker:Copy()                 -- selected address, to the clipboard
ManifoldSigMaker:Copy(0x14D762ED9)      -- a given address
ManifoldSigMaker:Pattern(0x14D762ED9)   -- just "48 8B 4C 24 ? 66 C1 E8 08 66 8B"
ManifoldSigMaker:Make(0x14D762ED9)      -- the signature as a table
ManifoldSigMaker:Status()
```

Pattern is the one to feed straight into AOBScan or an Auto Assembler script. Every call logs a
block showing the address, the pattern, how many bytes were wildcarded and what kind each was, so
you can see what was made without pasting the clipboard somewhere to look at it.

## Settings

Defaults live in Manifold-SigMaker-Settings.lua. Cheat Engine hands any script a registry backed
store, so the masking choices, the scope, the output list, the clipboard switch and the function
end rule all survive a restart. The bounds and the scan protection are defaults rather than
persisted values, and are changed in the file or as overrides.

| Setting | Default | Effect |
|---|---|---|
| Mask.Displacement | true | The number inside brackets becomes a wildcard |
| Mask.BranchTarget | true | The target of jmp, call and jcc becomes a wildcard |
| Mask.Immediate | large | true masks every immediate, false masks none, and large masks only the immediates whose value is at least ImmediateThreshold |
| Mask.ImmediateThreshold | 0x10000 | At or above this an immediate is treated as an address |
| Output | aob | Which lines reach the clipboard, comma separated, in order: aob, aobq, code, header |
| Scope | module | Where the signature has to be unique. Either the containing module or process |
| StopAtFunctionEnd | false | When on, a signature that would reach past a ret or an unconditional jmp is refused instead of reported |
| MaxInstructions | 64 | Give up rather than grow forever |
| MaxBytes | 256 | The same bound, by length |
| MinPatternBytes | 5 | Do not scan below this. One instruction can trim to a single byte, and a one byte scan matches roughly one address in every 256 |
| ScanProtection | +X | Executable pages only. An empty string searches everything |
| CopyToClipboard | true | Off returns the text without touching the clipboard |
| MenuCaption | Manifold: Copy Signature | The wording of the context menu entry |

The large setting for immediates reads a value the way the instruction means it. Cheat Engine
prints an immediate unsigned and at its encoded width, so FFFFFFFF is minus one rather than four
billion. Without that reading, an instruction like or eax,FFFFFF00 looked like an address and got
wildcarded.

From the Lua console:

```lua
ManifoldSigMaker:SetOutput("aob")               -- just the pattern, the default
ManifoldSigMaker:SetOutput("header,code,aobq")  -- the old tool's three lines
ManifoldSigMaker:SetMaskImmediate(true)         -- mask every immediate
ManifoldSigMaker:SetMaskDisplacement(false)     -- keep displacements literal
ManifoldSigMaker:SetScope("process")            -- unique in the whole process
```

Anything without a setter is reachable as an override where the host is built in
Manifold-SigMaker.lua:

```lua
local host = Host:New({
    Settings = { Scope = "process", Mask = { Immediate = true } }
})
```

Module scope counts matches inside the module the address belongs to, which is what a later
AOBScanModule will search. Process scope counts everywhere, which is stricter and slower.

## Why not just port the old plugin

GH SigMaker v2.0 computes its mask with one formula:

```
keep = immSize ~= 0 and (len - immSize) or (1 + hasModRM)
```

The count starts at byte zero, so prefixes eat the budget before the opcode is reached. Here is
what that produces next to what this tool produces:

| Instruction | GH SigMaker | Manifold SigMaker |
|---|---|---|
| 48 8B 4C 24 08 | 48 8B ? ? ? | 48 8B 4C 24 ? |
| 8B 05 disp32 | 8B 05 ? ? ? ? | 8B 05 ? ? ? ? |
| 48 8B 05 disp32 | 48 8B ? ? ? ? ? | 48 8B 05 ? ? ? ? |
| F3 0F 1E FA | F3 0F ? ? | F3 0F 1E FA |
| C7 45 F8 imm32 | C7 45 F8 ? ? ? ? | C7 45 ? imm32 |

Three things go wrong there. The same instruction masks differently depending on whether it
carries a REX prefix, which is why the two loads in the middle disagree. The endbr64 in the fourth
row has its own opcode bytes wildcarded. In the last row the displacement is kept and the immediate
is thrown away, which is backwards for a signature, since the displacement is the part that moves.
That decoder also predates VEX and mishandles the 0F 38 opcode map.

The output format was worth keeping. The rule was not.

The full reference is in [docs/Manifold-SigMaker.md](../docs/Manifold-SigMaker.md).
