# Manifold SigMaker

> File: [`Manifold-SigMaker/Manifold-SigMaker.lua`](../Manifold-SigMaker/Manifold-SigMaker.lua)
> Version: 1.0.0 · License: MIT · Author: Leunsel

An autorun segment that turns the instruction selected in Cheat Engine's disassembler into an
array of bytes signature and puts it on the clipboard. It has no dependency on the Manifold
Framework and works on its own. One optional coupling: it logs through
[Manifold Logger](Manifold-Logger.md) when that is installed, and falls back to a timestamped
print when it is not.

It replaces the GH SigMaker plugin. It is not a port of it. That plugin carried its own
table driven length disassembler and derived the mask from it, and the rule it derived is wrong
in ways that matter, section 4.3. This one asks Cheat Engine's own disassembler which bytes are
operands, by changing a byte and reading what changed in the text.

## 1. Installation

Place Manifold-SigMaker.lua **and** the Manifold-SigMaker-Modules folder next to each other in
Cheat Engine's autorun folder, typically:

```
C:\Program Files\Cheat Engine 7.5\autorun
```

Portable builds keep that folder somewhere else. The Lua console tells you where:

```lua
return getAutorunPath()
```

The layout:

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

The script runs on the next Cheat Engine start and publishes the host twice under the same
object, as ManifoldSigMaker for everyday use and as ManifoldSigMakerHost for the entry file's own
takedown of a previous generation. The facade name is registered with
registerLuaFunctionHighlight when that function exists.

Copying only the entry file and forgetting the folder is the one mistake this can catch. The
require is wrapped, so it prints one line naming the folder and the directory it looked in
instead of a require traceback on every Cheat Engine start.

### Re-running it at runtime

Executing the entry file again from the Lua Engine rebuilds everything from fresh module code.
Cheat Engine's require is standard Lua require, so package.loaded survives a re-execution. The
nine module names this tree owns are dropped from it first, otherwise an edited module keeps
running the code it was loaded with. The previous generation's menu entry is taken down before
that happens, so nothing accumulates, and the startup line reads re-executed instead of ready.

### When the memory view is not open yet

The entry lives in the memory view's context menu, and at autorun time that window may never have
been opened. Installing then fails with a reason, which is logged at debug level rather than
thrown. Open the Memory Viewer once and run:

```lua
ManifoldSigMaker:Install()
```

## 2. The menu entry

Right-click an instruction in the Memory Viewer's disassembler and pick
**Manifold: Copy Signature**. The caption is the MenuCaption setting.

The item is added to the memory view form's own published TPopupMenu, the component named
debuggerpopup. The disassembler control's PopupMenu property is nil, and getVisibleDisassembler
is deprecated and returns a stub whose PopupMenu is nil as well, so the form's component is the
way in. Section 9 has the detail.

Clicking calls Copy on the address currently selected in the disassembler. An error raised
anywhere below that is caught and logged with the caption in front of it, so a failure shows up
in the console rather than as a Cheat Engine error dialog over the memory view.

Every item created here carries Tag 1297374332. Removal sweeps the popup for that tag rather
than trusting the reference it kept, so a generation whose item reference was lost, or a
re-execution that never got to remove its entry, cannot leave one behind. The Logger
(1297374300), the Template Loader (1297374284) and the CE Utility (1297374316) carry their own
values, so none of the four sweeps another's items.

## 3. How a signature is built

The address is the disassembler's selection, or the one passed in. A process has to be attached,
which is what getOpenedProcessID reports as a value other than zero.

The module containing the address comes from enumModules plus getModuleSize. Where two ranges
contain the address, the highest base wins, so a module mapped inside another one's range is the
answer. Under the default module scope an address that belongs to no module is refused with a
message that names the scope and the way out, because a module scoped scan would have nothing to
search.

Then one instruction is appended per round:

1. The instruction length comes from getInstructionSize, falling back to the length of the
   disassembly text when that answers nothing useful.
2. The bytes are read with readBytes in table form.
3. The decoder classifies every byte of the instruction and the settings decide which of them
   become wildcards, section 4.
4. The entries are appended to the pattern being built.
5. A copy of the pattern is trimmed of its trailing wildcards. Scanning happens only when at
   least MinPatternBytes remain, because a pattern that is all wildcards matches everywhere and
   a very short one matches almost everywhere.
6. The scan counts matches with AOBScan, restricted to executable pages by ScanProtection and,
   under module scope, to the module's address range. Counting stops at two, because the only
   question is whether the pattern is unique yet.

One match ends it. The real entries are trimmed of their trailing wildcards and the signature is
returned. A trailing wildcard cannot have contributed to uniqueness, so it is length the
signature does not need.

Zero matches is an error, not a reason to grow. The address the signature was made from has to
match it, so zero means the memory moved underneath or the scan could not reach it.

### 3.1 The bounds

MaxInstructions (64) and MaxBytes (256) end the loop with a message naming the bound it hit. The
plugin this was modelled on had no equivalent, so a bad address walked until the scan range ran
out, and every round of that is a full scan of the module.

### 3.2 The function end

A signature that reaches past a ret or an unconditional jmp has left the function and is
describing whatever the linker happened to put next, which moves independently of the code being
signed. The mnemonics that count as an ending are ret, retn, retf, iret, iretd, iretq, jmp,
int3, ud2 and hlt.

On an epilogue that is the only way to become unique at all. A sequence such as
lea rsp,[rsp+20] then pop rbp then ret looks the same in every function with that frame size, so
refusing to cross the boundary would mean refusing to make a signature. StopAtFunctionEnd is
therefore off by default and the crossing is reported instead:

* The address of the instruction that ended the function is recorded on the signature as
  CrossedFunctionEnd.
* A note is added to the signature and a warning goes to the log.
* The report block carries a Warning row.

Only the first crossing is reported. With StopAtFunctionEnd on, the same situation is a refusal
whose message names the address and names the setting to turn off.

### 3.3 What comes back

A signature is a plain table:

| Field | Holds |
|---|---|
| Address | The address it was made for |
| Module | Name, Base and Size, or nil outside every module |
| Offset | The address relative to the module base, or nil |
| Entries | One entry per byte: Byte, Kind, Masked, and Value on an immediate |
| Pattern | The scan pattern, a masked byte written as two question marks |
| Instructions | How many instructions it took |
| Matches | Always 1 |
| Scope | The scope it was made unique in |
| Notes | Anything worth saying, as strings |
| CrossedFunctionEnd | The address of the terminator it reached past, or nil |

The Pattern field writes a wildcard as two question marks and the aob output part writes it as
one. Cheat Engine's scanner accepts both, so the difference is cosmetic. The two character form
keeps every token the same width, which is what the growth loop and the log read.

## 4. The masking policy

Displacements and branch targets change when a binary is rebuilt or relocated, so masking them is
what makes a signature survive a patch. An immediate is usually a real constant that carries
uniqueness, so sub rsp,28 keeps its 28. An immediate large enough to be an address is masked.
Every part of that is a setting.

### 4.1 Finding the operand bytes by probing

There is no opcode table here. For each byte of the instruction the decoder flips that byte,
hands the whole instruction to disassembleBytes, and compares the answer with the instruction as
it really reads. When the length is unchanged and only a number differs, that byte carries a
numeric operand. When the length or the shape changed, the byte is structural and is kept.

The comparison runs on a skeleton, which is the instruction text lowercased with every
hexadecimal literal replaced by a marker. Three things have to collapse into that marker or the
comparison lies:

* **The literals themselves.** No x86 register name is made only of hexadecimal digits, so the
  substitution never eats one. eax survives because of the x, rsp because of the s and the p, dh
  because of the h.
* **The sign in front of a literal.** Cheat Engine prints a displacement signed, so it writes
  lea rax,[rbp-20] and never [rbp+E0]. A probe that changes the sign therefore changes a
  character and not just digits. That is also why the probe flips bit 0 rather than complementing
  the byte. Bit 7 of a one byte displacement or a sign extended one byte immediate is its sign,
  and complementing always crossed zero. With the complement, and the sign left in the skeleton,
  no one byte displacement was ever recognised as an operand at all.
* **Symbols.** A resolved target prints as a module name plus an offset, for example
  mov rax,[game.exe+2F000] or call game.exe+215F0. Move it far enough and it degrades to a bare
  address, which is a different shape for the same kind of operand. The top byte of every rip
  relative displacement and every rel32 hits this, because one bit there moves the target by
  megabytes. A name carrying a dot is collapsed first, along with the offset behind it, so no
  register or mnemonic can match the rule.

Flipping the lowest bit is what makes all three work at once. It always changes the byte, it never
touches bit 7, and it moves a rip relative or rel32 target the shortest distance it can, so the
target usually stays inside its module and keeps its name.

The probe buffer is padded to sixteen bytes with nop. A disassembler needs room to look ahead,
and a one byte instruction handed over on its own, 5D for pop rbp, is not enough for Cheat Engine
to answer at all. The padding sits after a complete instruction so it cannot change how that
instruction decodes, and it is identical for the base reading and for every probe.

This costs one disassembly per byte, which for a signature of a few instructions is a few dozen
calls. In exchange there is no opcode table to go stale. Whatever Cheat Engine's disassembler
understands, this understands, including instruction sets that postdate the plugin it replaces,
and it cannot disagree with the disassembler the user is looking at.

An instruction Cheat Engine will not disassemble at all does not take the signature down with it.
Every byte of it is kept literal, which is always a correct if unhelpful answer, and a note
naming the address and the byte count is carried on the signature and logged. A signature that is
longer than it had to be still works. Refusing to make one does not.

### 4.2 What a masked byte is called

A byte that carries an operand is classified before the settings see it:

| Test | Kind | Setting |
|---|---|---|
| The number that changed sits inside brackets | displacement | Mask.Displacement |
| The mnemonic is a branch | branch | Mask.BranchTarget |
| Anything else | immediate | Mask.Immediate |

Brackets are tested before the mnemonic, and the order matters. An indirect branch such as
call qword ptr [rip+X] or jmp [rax+18] carries a memory displacement and not a code target, and
the two are governed by different settings. Testing the mnemonic first put every import thunk and
every vtable dispatch in the wrong bucket.

The bracket test walks the two texts until they diverge and reads the bracket depth at that
point, so it is the changed number that decides and not the presence of brackets anywhere in the
line.

An immediate also gets a value, so the large policy has something to compare. The literal is read
out of the base text and sign extended at its printed width, meaning two, four, eight or sixteen
hexadecimal digits, and the magnitude is kept. Cheat Engine prints an immediate unsigned and at
its encoded width, so FFFFFFFF is minus one and not four billion. Without the sign extension every
or eax,FFFFFF00 looked like an address and was wildcarded by the large policy.

### 4.3 Why not the plugin's rule

GH SigMaker v2.0 computes its mask as

```
keep = immSize ~= 0 and (len - immSize) or (1 + hasModRM)
```

where keep counts from byte zero, so prefixes eat the budget.

| Instruction | GH SigMaker | Manifold SigMaker |
|---|---|---|
| 48 8B 4C 24 08 | 48 8B ? ? ? | 48 8B 4C 24 ? |
| 8B 05 disp32 | 8B 05 ? ? ? ? | 8B 05 ? ? ? ? |
| 48 8B 05 disp32 | 48 8B ? ? ? ? ? | 48 8B 05 ? ? ? ? |
| F3 0F 1E FA | F3 0F ? ? | F3 0F 1E FA |
| C7 45 F8 imm32 | C7 45 F8 ? ? ? ? | C7 45 ? imm32 |

The same instruction masks differently depending on whether it carries a REX prefix, endbr64 has
its own opcode wildcarded, and the displacement is kept while the immediate is thrown away, which
is backwards for a signature. Its decoder also predates VEX and mishandles the 0F 38 opcode map.
The output format was worth keeping, section 6. The rule was not.

## 5. Settings

Manifold-SigMaker-Settings.lua holds the defaults:

| Setting | Default | Effect |
|---|---|---|
| Mask.Displacement | true | The number inside brackets becomes a wildcard |
| Mask.BranchTarget | true | The target of jmp, call and jcc becomes a wildcard |
| Mask.Immediate | "large" | true masks every immediate, false none, "large" only those at or above the threshold |
| Mask.ImmediateThreshold | 0x10000 | At or above this an immediate is treated as an address |
| Output | "aob" | Which lines reach the clipboard, comma separated, section 6 |
| Scope | "module" | Where the signature has to be unique, the containing module or "process" |
| MaxInstructions | 64 | Give up rather than grow forever |
| MaxBytes | 256 | The same, by length |
| MinPatternBytes | 5 | Do not scan below this |
| StopAtFunctionEnd | false | Refuse to reach past a ret or a jmp rather than warning, section 3.2 |
| ScanProtection | "+X" | Executable pages only. An empty string searches everything |
| CopyToClipboard | true | Off returns the text without touching the clipboard |
| MenuCaption | "Manifold: Copy Signature" | The context menu entry |

MinPatternBytes is five because one instruction can trim to a single structural byte. A call
rel32 trims to E8 on its own, and a one byte scan matches roughly one address in 256, so Cheat
Engine builds a list of millions of hits before anything can count them.

ScanProtection is "+X" because code lives in executable pages. Restricting the scan is both
faster and more correct, since a copy of the bytes sitting in a heap buffer is not another place
the signature could resolve to.

Overrides go where the host is built in the entry file. Nested tables merge, so one masking
choice can be changed without restating the others:

```lua
local host = Host:New({
    Settings = { Scope = "process", Mask = { Immediate = true } }
})
```

### 5.1 Persistence

Seven settings are written through getSettings("Manifold SigMaker") whenever a setter changes
them and read back on the next start: Output, StopAtFunctionEnd, Scope, CopyToClipboard,
Mask.Displacement, Mask.BranchTarget and Mask.Immediate. The bounds, the threshold, the scan
protection and the caption are override only, because they are tuning and not choices a user
makes twice.

A dotted key reaches into a nested table and is stored under that name, dot included, so the
registry holds one flat entry named Mask.Immediate. Values are stored as strings, with a boolean
written as 1 or 0, and decoded against the type of the default. Mask.Immediate decodes as a
string first, because it is the one tri-state value and the word large has to survive the round
trip. Cheat Engine answers an empty string, never nil, for a value that was never written, which
is read as absent, so a fresh install keeps every default. Passing Persist false to the host
keeps everything for the session only.

## 6. The output parts

By default the clipboard holds exactly the scan pattern, ready to paste into a scan or an Auto
Assembler script:

```
48 8B 4C 24 ? 66 C1 E8 08 66 8B
```

Four parts exist, and the Output setting names the ones that are rendered, in the order they are
named:

| Part | Renders |
|---|---|
| aob | 48 8B 4C 24 ? 66 C1 E8 ? 66 8B |
| aobq | the same, wrapped in quotes |
| code | the C style byte string and mask pair |
| header | Address of signature = SouthPark_TFBW.exe + 0x0D762ED9 |

Naming all three of the old tool's parts reproduces its output exactly, uppercase hexadecimal
throughout, the module offset zero filled to eight digits, a masked byte written as a zero byte
in the code string and as a single question mark in the pattern:

```lua
ManifoldSigMaker:SetOutput("header,code,aobq")
```

```
Address of signature = SouthPark_TFBW.exe + 0x0D762ED9
"\x48\x8B\x4C\x24\x00\x66\xC1\xE8\x00\x66\x8B", "xxxx?xxx?xx"
"48 8B 4C 24 ? 66 C1 E8 ? 66 8B"
```

A signature made outside every module, which needs process scope, gets the bare address in the
header instead of a module and an offset.

An unknown part name is reported rather than silently dropped. SetOutput refuses the whole
string and names the four parts. Composing with one anyway renders the parts it recognises and
returns the first unknown name, which Copy turns into a warning. A specification that names
nothing usable falls back to the bare pattern, because copying an empty string would look like
the tool had done nothing at all.

### 6.1 The report

Every copy also logs a block, so the console shows what was made without the clipboard having to
be pasted somewhere to find out. This is the fallback rendering. With Manifold Logger installed
the block is drawn by the Logger instead.

```
Signature
  Address       : SouthPark_TFBW.exe + 0xD762ED9
  Pattern       : 48 8B 4C 24 ? 66 C1 E8 ? 66 8B
  Mask          : xxxx?xxx?xx
  Bytes         : 11, 2 wildcarded
  Instructions  : 3
  Unique in     : SouthPark_TFBW.exe
  Displacements : 2
```

The counts of displacements, branch targets and immediates appear only when they are not zero.
A Warning row appears when the signature reached past the end of a function, and a Notes row
carries anything the decoder had to say.

## 7. The public object

ManifoldSigMaker is the host. Everything the menu entry does is a method on it, so a table's Lua
script or the Lua console can use it with no menu at all:

```lua
ManifoldSigMaker:Copy()                 -- the selected address, to the clipboard
ManifoldSigMaker:Copy(0x14D762ED9)      -- a given address
ManifoldSigMaker:Pattern(0x14D762ED9)   -- just the scan pattern, plus the signature
ManifoldSigMaker:Make(0x14D762ED9)      -- the signature table, nothing copied
ManifoldSigMaker:SetMaskDisplacement(false)
ManifoldSigMaker:SetMaskBranchTarget(false)
ManifoldSigMaker:SetMaskImmediate(true)      -- true, false or "large"
ManifoldSigMaker:SetOutput("aob")            -- aob, aobq, code, header
ManifoldSigMaker:SetScope("process")         -- "module" or "process"
ManifoldSigMaker:Status()                    -- a table
ManifoldSigMaker:Install()                   -- also Uninstall and Reinstall
ManifoldSigMaker:Shutdown()
```

Copy returns the text it composed even when CopyToClipboard is off, so a script can take the
output without the clipboard being touched. Make and Pattern return nil and a reason when
anything went wrong, and the reason has already been logged.

Pattern is the one to feed straight into AOBScan or an Auto Assembler script.

Status reports the version, whether the menu entry is installed, whether the Logger was found,
and the settings that matter. StatusRows is the same thing shaped for a log block, which is what
the startup line prints:

```
Manifold SigMaker 1.0.0 ready
  Menu      : in the disassembler context menu
  Logger    : Manifold Logger
  Wildcards : displacements, branch targets, large immediates
  Unique in : the containing module
  Clipboard : aob
  Settings  : persisted in the registry
```

Shutdown removes the menu entry and releases both globals.

## 8. Internal structure

| Module | Owns |
|---|---|
| -CE | Defensive wrappers over the Cheat Engine API: Call, Get, RunInMain, the form and popup accessors, SplitDisassembly, Disassemble, DisassembleBytes, ReadBytes, ModuleAt, CountMatches, Clipboard. Every global is looked up at call time. |
| -Log | The Manifold Logger channel named SigMaker or the print fallback, and Block. |
| -Settings | Defaults, overrides, dotted keys, the registry store. |
| -Decoder | The probe, the skeleton, the classification of a byte, and the policy that turns it into a mask. |
| -Signature | The growth loop, the trimming, the bounds and the function end rule. |
| -Format | The four output parts, Compose, and the rows of the report block. |
| -Menu | The entry in the disassembler context menu and the tag sweep that removes it. |
| -Host | Wiring, the actions, the setters, Status and Shutdown. |
| -Version | The version number. Nothing else in the tree carries one. |

Globals are never captured at load time. A test can therefore stub the whole API, and an older
Cheat Engine degrades to a logged reason rather than an error raised while autorun is still
loading. Nothing in these wrappers turns a failure into a fake success.

The Logger channel is resolved on every call and re-resolved when the Logger host is rebuilt.
Autorun files run in an order nobody controls, and the Logger can be shut down and rebuilt while
Cheat Engine is running, so a channel captured once would end up writing into a buffer no window
shows.

### 8.1 The tests

Manifold-SigMaker-Tests/Run.lua runs the whole segment headlessly on any Lua 5.3:

```
lua Run.lua <projectDir>
```

It covers the API wrappers, the settings and their persistence, the classification of a byte, the
masking policy, the growth loop and its bounds, the output parts, the menu entry, and the entry
file executed twice. There are 167 checks.

CEStub.lua is the Cheat Engine it runs against, and the interesting thing about it is that it
carries a small model of an x86-64 decoder rather than a table of canned answers. A canned table
cannot test the probe, because the probe asks about byte sequences nobody canned. The model is
not a correct disassembler and does not try to be. What it has to be is self consistent in
exactly the way a real one is, in three respects. Flipping a displacement or immediate byte
changes only a number. Flipping a ModRM, SIB or REX byte changes registers or the length.
Flipping an opcode byte changes the mnemonic or the length. Anything it does not know decodes as
db, which the decoder correctly reads as structural.

It also models the Cheat Engine behaviour of section 9 faithfully, including the ones that are
easy to get right by accident: the trailing spaces and the doubled separator in a disassembly
line, the reversed return values of splitDisassembledString, the string form of disassembleBytes
reading one byte and then zeroes, the minimum buffer a disassembly needs, AOBScan answering nil
rather than an empty list, getSettings answering an empty string, and getVisibleDisassembler
handing back a stub whose PopupMenu is nil. A caller that regresses to any of those fails in the
test run instead of quietly producing a signature that masks nothing.

## 9. Cheat Engine behaviours that contradict celua.txt

Everything below was measured on Cheat Engine 7.5. Each one differs from what the documentation
says, or is not in the documentation at all, and each one broke something before it was found.

**splitDisassembledString returns its four values in reverse.** celua.txt line 596 describes them
as the address, bytes, opcode and extra field. What comes back is extra, opcode, bytes, address:

```lua
print(splitDisassembledString("00403E5E - 5D - pop rbp"))
  -->        pop rbp    5D    00403E5E
```

Reading it as documented puts the opcode text where the bytes belong. On a long instruction that
went unnoticed, because the opcode text happens to contain hexadecimal pairs, the ea in lea and
the 08 in [rsp+08], so the byte count came out non zero. On pop rbp there are none, the count was
zero, and the whole line was rejected as undisassemblable. Nothing in this segment uses the
function. SplitDisassembly parses the line itself.

**A disassembly line carries trailing spaces and a doubled separator.** The real shape puts a
space after the byte list and after the opcode, so the separator reads as two spaces, a hyphen
and a space, and the line ends in whitespace:

```
140000000 - 48 8B 4C 24 08  - mov rcx,[rsp+08]  
```

Anything parsing the line has to cope with that. The two separators are structural, and a
displacement is written [rbp-20] with no spaces around the sign, so the two cannot be confused.

**disassembleBytes only works when handed a byte table.** celua.txt line 601 documents it as
taking a hexadecimal byte string or a byte table. On 7.5 the string form reads the first byte and
then zeroes, whatever the spacing or the case:

```
disassembleBytes("488B4C2408", 0x140000000)
  -> 140000000 - 48 00 00  - add [rax],al
disassembleBytes({0x48,0x8B,0x4C,0x24,0x08}, 0x140000000)
  -> 140000000 - 48 8B 4C 24 08  - mov rcx,[rsp+08]
```

Never pass a string.

**A one byte instruction handed over alone gives Cheat Engine no room to look ahead.** 5D for
pop rbp on its own returns nothing at all, which used to abort a whole signature. The probe
buffer is padded to sixteen bytes with nop for that reason.

**getVisibleDisassembler is deprecated and returns a stub.** celua.txt line 3073 says as much,
and the stub's PopupMenu is nil, which is what misled everyone who tried to attach a menu entry
through it. The real control is getMemoryViewForm().DisassemblerView, and the context menu is the
memory view form's own published TPopupMenu named debuggerpopup.

**Cheat Engine prints a displacement signed.** It writes lea rax,[rbp-20] and never [rbp+E0]. The
sign is a character rather than a digit, which is why the probe flips one bit instead of
complementing the byte. Bit 7 of a one byte displacement or a sign extended one byte immediate is
its sign, and complementing it always crossed zero, so no one byte displacement was ever
recognised as an operand.

**A resolved target prints as a module name plus an offset.** It reverts to a bare address once
it leaves the module, so the same kind of operand has two different text shapes. The top byte of
every rip relative displacement and every rel32 crosses that line, because one bit there moves
the target by megabytes.

**enumModules gives no size.** celua.txt line 153 lists Name, Address, Is64Bit and PathToFile,
and there is no size among them. getModuleSize supplies it by name.

**getSettings answers an empty string and never nil** for a value that was never written. That is
read as absent, so a fresh install keeps its defaults instead of decoding an empty string into
false.

**AOBScan returns nil rather than an empty list when nothing matched.** Reporting that as a
missing API told the user the scanner was broken when it had simply found nothing. It is also the
only documented way to a real count, celua.txt line 543, since AOBScanUnique returns the first
hit at random and verifies nothing. The StringList it hands back has to be destroyed.
