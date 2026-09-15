# Manifold SigMaker

> File: [`Manifold-SigMaker/Manifold-SigMaker.lua`](../Manifold-SigMaker/Manifold-SigMaker.lua)
> Version: 1.2.0 · License: MIT · Author: Leunsel

An autorun segment for the two directions of a signature. It turns the instruction selected in
Cheat Engine's disassembler into an array of bytes signature and puts it on the clipboard, and it
reads a signature back in, scans the process for it and goes to where it matched. It has no
dependency on the Manifold Framework and works on its own. One optional coupling: it logs through
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
    Manifold-SigMaker-Find.lua
    Manifold-SigMaker-Format.lua
    Manifold-SigMaker-Host.lua
    Manifold-SigMaker-Log.lua
    Manifold-SigMaker-Menu.lua
    Manifold-SigMaker-Pattern.lua
    Manifold-SigMaker-Settings.lua
    Manifold-SigMaker-Signature.lua
    Manifold-SigMaker-Version.lua
    Manifold-Icons/
      Manifold-Copy.png
      Manifold-Search.png
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
eleven module names this tree owns are dropped from it first, otherwise an edited module keeps
running the code it was loaded with. The previous generation's menu entries, and its list of hits
when one is open, are taken down before that happens, so nothing accumulates, and the startup line
reads re-executed instead of ready.

### When the memory view is not open yet

The entries live in the memory view's context menu, and at autorun time that window may never
have been opened. Installing then fails with a reason, which is logged at debug level rather than
thrown. Open the Memory Viewer once and run:

```lua
ManifoldSigMaker:Install()
```

## 2. The menu entries

Right-click an instruction in the Memory Viewer's disassembler. Two entries are there:

| Entry | Does |
|---|---|
| **Manifold: Copy Signature** | Builds a signature for the selected instruction, sections 3 and 4 |
| **Manifold: Find Signature** | Asks for a signature, scans for it and goes there, section 7 |

Both captions are settings, MenuCaption and Find.MenuCaption.

The items are added to the memory view form's own published TPopupMenu, the component named
debuggerpopup. The disassembler control's PopupMenu property is nil, and getVisibleDisassembler
is deprecated and returns a stub whose PopupMenu is nil as well, so the form's component is the
way in. Section 10 has the detail.

Clicking one calls Copy on the address currently selected in the disassembler, or Find. An error
raised anywhere below that is caught and logged with the caption in front of it, so a failure
shows up in the console rather than as a Cheat Engine error dialog over the memory view.

### The shortcut, and why there is a second menu

Find Signature also answers **Ctrl+Shift+F** while the Memory Viewer has focus. Find.Shortcut is
the key and ManifoldSigMaker:SetFindShortcut rebinds it.

A shortcut is dispatched by the focused form through its main menu. An item sitting in a popup
menu is never asked about a key, whatever its Shortcut property says, so a shortcut needs an item
in a menu bar to live in. That is what the small **Manifold** entry in the Memory Viewer's own
menu bar is: it carries the same two actions, and the finding one carries the key. The context
menu entry then prints the same key beside its caption, but only once that menu bar entry is
really there, because a key printed next to an entry that cannot be triggered by it would be a
lie. Find.MenuBar false leaves the entry out, and the shortcut with it.

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
| MenuCaption | "Manifold: Copy Signature" | The first context menu entry |
| Find.Protection | "+X" | Where a search looks first, in AOBScan protection flags |
| Find.Fallback | true | Widen a search that found nothing to all memory once, section 7.2 |
| Find.MinFixedBytes | 4 | Refuse to scan for a pattern with fewer fixed bytes than this |
| Find.MaxResults | 100 | How many hits the list of hits is given |
| Find.PrefillFromClipboard | true | Open the prompt on the clipboard when it holds a signature |
| Find.MenuCaption | "Manifold: Find Signature" | The second context menu entry |
| Find.Shortcut | "Ctrl+Shift+F" | The key, empty for none |
| Find.MenuBar | true | The Memory Viewer menu bar entry that carries the key |
| Find.MenuBarCaption | "Manifold" | Its caption |

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

Thirteen settings are written through getSettings("Manifold SigMaker") whenever a setter changes
them and read back on the next start: Output, StopAtFunctionEnd, Scope, CopyToClipboard,
Mask.Displacement, Mask.BranchTarget, Mask.Immediate, Find.Protection, Find.Fallback,
Find.MinFixedBytes, Find.MaxResults, Find.PrefillFromClipboard and Find.Shortcut. The bounds, the
threshold, the signature scan protection and the captions are override only, because they are
tuning and not choices a user makes twice.

A dotted key reaches into a nested table and is stored under that name, dot included, so the
registry holds one flat entry named Mask.Immediate. Values are stored as strings, with a boolean
written as 1 or 0, and decoded against the type of the default. Mask.Immediate decodes as a
string first, because it is the one tri-state value and the word large has to survive the round
trip. Cheat Engine answers an empty string, never nil, for a value that was never written, which
is read as absent, so a fresh install keeps every default. Passing Persist false to the host
keeps everything for the session only.

That last rule is why an empty string cannot be stored as itself. Find.Protection is empty when a
search is meant to cover all memory, which is a real choice and has to survive a restart, so an
empty value goes into the registry as the marker `<empty>` and comes back out as an empty
string.

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

## 7. Finding a signature again

The other direction. **Manifold: Find Signature**, or the shortcut with the Memory Viewer
focused, asks for a signature, scans the attached process for it, and goes to where it matched.

The prompt opens on the clipboard when what is on it reads as a signature, so copying one in one
Cheat Engine and finding it in another is a keystroke and a return. Only the pattern is offered,
because inputQuery is a single line and the three line form of a signature would show its header
and hide the bytes.

### 7.1 What it accepts

Every shape the copying half writes, and the ones the rest of the world writes:

| Pasted | Read as |
|---|---|
| `48 8B 4C 24 ? 48 83 EC 28` | the bare pattern |
| `"48 8B 4C 24 ?? 48 83 EC 28"` | the same, quoted |
| `"\x48\x8B\x4C\x24\x00", "xxxx?"` | the C string and its mask |
| `\x48\x8B\x4C\x24\x00` | a C string with no mask, so its zeroes are real bytes |
| `{ 0x48, 0x8B, 0x4C, 0x24, 0x00 }` | a C array |
| `488B4C2408` | one unbroken run of hex |
| `48 8? 4C 24` | a nibble wildcard, passed through untouched |

A wildcard may be written `?`, `??`, `*` or `.`, a byte may carry an `0x` in front or an `h`
behind, case does not matter, and braces, brackets, commas, semicolons and quotes are
punctuation. Header lines and `//`, `--`, `#` and `;` comments are dropped, so the whole of what
the copying half put on the clipboard pastes straight back in, whichever parts it was set to.
That round trip is in the test run for all five combinations of them.

Two details decide how a text is read.

**A mask is only meaningful next to a C string.** `\x00` is a wildcard in `"xxxx?"` and a real
zero byte without it, and nothing in the string itself says which. A C string that arrives alone
is therefore read literally, and the block says how many zero bytes were taken at face value
rather than guessing at them.

**A nibble wildcard survives.** Cheat Engine's scanner understands half a byte, so widening `4?`
to a whole wildcard or dropping the known nibble would both change the search. It does not count
towards the fixed length below, because half a byte of certainty is not what that judgement is
about.

### 7.2 Where it looks

The scan starts in executable memory, which is Find.Protection "+X". That is where code is, a
signature from this tool describes code, and restricting the scan is what keeps it quick in a
process carrying a gigabyte of heap.

A signature that describes data matches nothing there. Rather than report that as a miss, a scan
that came back empty is widened to all memory once, and both halves are reported, so a miss never
hides which memory was actually searched. Find.Fallback false turns the second attempt off.

A pattern with fewer than Find.MinFixedBytes fixed bytes is refused instead of scanned for. Cheat
Engine builds the complete result list before a caller can look at any of it, so a scan for two
fixed bytes allocates millions of entries and takes the interface with it for as long as that
lasts. The refusal names the way round it:

```
Find signature: the pattern has 2 fixed byte(s) and 4 are needed. A pattern that short
matches in thousands of places, and Cheat Engine builds every one of them before the first
can be read. ManifoldSigMaker:SetFindMinimum(2) allows it anyway.
```

The scan runs on the thread it was called from, which is the interface thread when it came from
the menu, so a large process freezes Cheat Engine for as long as the scan takes. The elapsed time
is in the block, which is the honest way to see what a given pattern costs.

### 7.3 What happens to the hits

Nothing found is a warning that says where it looked. One hit is a jump, with nothing to
confirm. More than one is a list in a window of its own, titled with the count and the pattern:

```
2 matches for 48 8B 0D 11 ?? ?? 44
  1.  game.exe+100  (140000100)
  2.  game.exe+400  (140000400)
```

The window is not modal. A click on a line goes to that hit and the window stays, so the hits of
one scan can be tried one after another, and the arrow keys walk through them the same way. None
of that scans again. The list holds the addresses the scan found, and a click only moves the
memory view.

The list goes away when its own close button closes it, or when the next Find that runs a scan
replaces it. Several new hits are listed in the same window, which keeps the place and the size it
was given. One hit or none closes it, so the list never shows hits older than the latest scan. A
cancelled prompt, or a pattern refused as too short, scans nothing and leaves the list alone. A
list that was closed opens again where it was, for as long as SigMaker stays loaded.

Three things make that work:

* **The list belongs to the memory view.** Its PopupParent is the memory view form, and Windows
  keeps an owned window above its owner, so a jump that brings the memory view up cannot bury
  the list. createForm leaves PopupMode at pmAuto and LCL applies ownership when the window
  handle is made, so it is set before anything else touches the form.
* **A click leaves the keyboard with the list.** It moves a memory view that is already on screen
  without raising it, section 7.4, so the next arrow key still reaches the list.
* **A click is OnClick.** LCL's list box calls it for a click on a line, for a click on the line
  that is already selected, and for the arrow keys, and never when ItemIndex is set in code.
  Going back to a hit after looking around is one more click on the same line, and filling the
  list jumps nowhere.

A list that opens for the first time sits over the right hand side of the memory view, below its
menu and toolbar. The jump puts the hit on the top line of the disassembler, with the bytes and the
instruction on the left, so that is where the window is least in the way.

Every hit reaches the log either way, before the list is shown, so the addresses are still there
once the window is gone:

```
Find signature
  Pattern  : 48 8B 0D 11 ?? ?? 44
  Bytes    : 7, 2 wildcarded
  Searched : executable memory
  Hits     : 2
  Time     : 0.06 s

  1.  game.exe+100  (140000100)
  2.  game.exe+400  (140000400)
```

The block lists the first 25 hits and then says how many more there are. Find.MaxResults, 100 by
default, is how many the list itself is given; past that the block reports the real total and
the window lists the first ones under a title like "The first 100 of 40000 matches for ...", so a
pattern with 40000 matches says 40000 rather than pretending there were 100.

On a Cheat Engine without createForm or createListBox the first hit is not offered as a guess.
The scan still logged every address, and the warning says the way out:

```lua
ManifoldSigMaker:Goto("game.exe+1A2B3C")
```

### 7.4 The jump

The memory view is shown and brought to the front, the disassembler's TopAddress and
SelectedAddress are moved to the hit, the hex view is pointed at it, and the bytes the pattern
covers are selected there, so a match is visible as a block and not as one address.

A click in the list of hits skips the first step when the memory view is already on screen.
Showing a form raises it and hands it the keyboard, so every click would take the focus from the
list and send the next arrow key to the disassembler. A memory view that is not on screen is still
shown and brought up, because a jump nobody can see is no jump at all.

Every one of those writes goes through the property first and through the published setter,
setSelectedAddress and the like, after it. Which of the two a given build accepts is not
something a caller can know. None of it past the form itself is required: a build whose hex view
will not take a selection still gets the jump, it just does not get the highlight.

Goto takes the same three forms as everything else in Cheat Engine: a number, hexadecimal with or
without `0x`, or a module and an offset like `game.exe+1A2B`. It resolves plain hexadecimal
itself and asks getAddressSafe about anything else, which is the documented resolver that answers
nil instead of raising.

## 8. The public object

ManifoldSigMaker is the host. Everything the menu entry does is a method on it, so a table's Lua
script or the Lua console can use it with no menu at all:

```lua
ManifoldSigMaker:Copy()                 -- the selected address, to the clipboard
ManifoldSigMaker:Copy(0x14D762ED9)      -- a given address
ManifoldSigMaker:Pattern(0x14D762ED9)   -- just the scan pattern, plus the signature
ManifoldSigMaker:Make(0x14D762ED9)      -- the signature table, nothing copied

ManifoldSigMaker:Find()                      -- ask, scan, go there
ManifoldSigMaker:Find("48 8B ? ? ? 66")      -- the same without the prompt
ManifoldSigMaker:ShowHit(2)                  -- line 2 of the open list of hits, like a click
ManifoldSigMaker:CloseHits()                 -- close that list
ManifoldSigMaker:Scan("48 8B ? ? ? 66")      -- the addresses, no prompt, list or jump
ManifoldSigMaker:Goto("game.exe+1A2B")       -- just the memory view

ManifoldSigMaker:SetMaskDisplacement(false)
ManifoldSigMaker:SetMaskBranchTarget(false)
ManifoldSigMaker:SetMaskImmediate(true)      -- true, false or "large"
ManifoldSigMaker:SetOutput("aob")            -- aob, aobq, code, header
ManifoldSigMaker:SetScope("process")         -- "module" or "process"
ManifoldSigMaker:SetFindProtection("")       -- "" searches all memory, "+X" executable only
ManifoldSigMaker:SetFindFallback(false)      -- never widen a search that found nothing
ManifoldSigMaker:SetFindMinimum(2)           -- allow a shorter pattern
ManifoldSigMaker:SetFindMaxResults(20)       -- how many hits the list of hits shows
ManifoldSigMaker:SetFindPrefill(false)       -- do not offer the clipboard
ManifoldSigMaker:SetFindShortcut("Ctrl+Alt+G")
ManifoldSigMaker:Status()                    -- a table
ManifoldSigMaker:Install()                   -- also Uninstall and Reinstall
ManifoldSigMaker:Shutdown()
```

Copy returns the text it composed even when CopyToClipboard is off, so a script can take the
output without the clipboard being touched. Make and Pattern return nil and a reason when
anything went wrong, and the reason has already been logged.

Pattern is the one to feed straight into AOBScan or an Auto Assembler script.

Find returns the address it went to, or nil and a reason. A cancelled prompt is "cancelled",
which is not a failure and is not logged as one. Several hits go into the list rather than
anywhere, and Find returns nil and "listed", which is not a failure either. Before 1.2.0 the list
was modal and Find returned the hit that was picked. A script that wants the addresses asks Scan
for them. ShowHit goes to one line of the open list the way a click does, and CloseHits closes
the list. Scan is the same search with no interface at all: it returns the addresses and the whole
result beside them, and touches neither the memory view nor a window. Goto only moves the memory
view.

Status reports the version, whether the menu entries are installed, whether the shortcut is
really answered by something, whether the Logger was found, and the settings that matter.
StatusRows is the same thing shaped for a log block, which is what the startup line prints:

```
Manifold SigMaker 1.2.0 ready
  Menu      : in the disassembler context menu
  Shortcut  : Ctrl+Shift+F
  Logger    : Manifold Logger
  Wildcards : displacements, branch targets, large immediates
  Unique in : the containing module
  Clipboard : aob
  Search    : executable memory, widened to all memory when nothing matches, at least 4 fixed byte(s)
  Settings  : persisted in the registry
```

Uninstall closes the list of hits along with the menu entries. Reinstall leaves the list open, so
rebinding the key does not take it away. Shutdown removes the menu entries, closes the list and
releases both globals.

## 9. Internal structure

| Module | Owns |
|---|---|
| -CE | Defensive wrappers over the Cheat Engine API: Call, Get, Write, RunInMain, the form, popup and menu bar accessors, SplitDisassembly, Disassemble, DisassembleBytes, ReadBytes, ModuleAt, ScanMatches, CountMatches, ShowAddress, AddressName, Resolve, Input, the list window with OpenList, RefillList and CloseList, Clipboard. Every global is looked up at call time. |
| -Log | The Manifold Logger channel named SigMaker or the print fallback, and Block. |
| -Settings | Defaults, overrides, dotted keys, the registry store. |
| -Decoder | The probe, the skeleton, the classification of a byte, and the policy that turns it into a mask. |
| -Signature | The growth loop, the trimming, the bounds and the function end rule. |
| -Format | The four output parts, Compose, and the rows of the report block. |
| -Pattern | Reading a pasted signature in any of its shapes. Syntax only, no policy. |
| -Find | The search: the minimum length, the protection, the widening, the rows of its block, and the title and lines of the list of hits. |
| -Menu | The entries in the context menu, the shortcut carrier in the menu bar, and the tag sweep that removes both. |
| -Host | Wiring, the actions, the list of hits and what a click on it does, the setters, Status and Shutdown. |
| -Version | The version number. Nothing else in the tree carries one. |

Globals are never captured at load time. A test can therefore stub the whole API, and an older
Cheat Engine degrades to a logged reason rather than an error raised while autorun is still
loading. Nothing in these wrappers turns a failure into a fake success.

The Logger channel is resolved on every call and re-resolved when the Logger host is rebuilt.
Autorun files run in an order nobody controls, and the Logger can be shut down and rebuilt while
Cheat Engine is running, so a channel captured once would end up writing into a buffer no window
shows.

### 9.1 The tests

Manifold-SigMaker-Tests/Run.lua runs the whole segment headlessly on any Lua 5.3:

```
lua Run.lua <projectDir>
```

It covers the API wrappers, the settings and their persistence, the classification of a byte, the
masking policy, the growth loop and its bounds, the output parts, the reading of a pasted
signature, the search and where it looks, the list of hits and the jump, the menu entries and the
shortcut, and the entry file executed twice. There are 340 checks, and one of them is the round
trip: what the copying half writes, in all five combinations of output parts, is read back by the
finding half as the same pattern.

CEStub.lua is the Cheat Engine it runs against, and the interesting thing about it is that it
carries a small model of an x86-64 decoder rather than a table of canned answers. A canned table
cannot test the probe, because the probe asks about byte sequences nobody canned. The model is
not a correct disassembler and does not try to be. What it has to be is self consistent in
exactly the way a real one is, in three respects. Flipping a displacement or immediate byte
changes only a number. Flipping a ModRM, SIB or REX byte changes registers or the length.
Flipping an opcode byte changes the mnemonic or the length. Anything it does not know decodes as
db, which the decoder correctly reads as structural.

It also models the Cheat Engine behaviour of section 10 faithfully, including the ones that are
easy to get right by accident: the trailing spaces and the doubled separator in a disassembly
line, the reversed return values of splitDisassembledString, the string form of disassembleBytes
reading one byte and then zeroes, the minimum buffer a disassembly needs, AOBScan answering nil
rather than an empty list and hiding everything outside executable memory under "+X", getSettings
answering an empty string, a hex view whose selection is writable only through its setters, and
getVisibleDisassembler handing back a stub whose PopupMenu is nil. A caller that regresses to any of those fails in the
test run instead of quietly producing a signature that masks nothing.

The windows are modelled the same way. createForm leaves PopupMode at pmAuto, and an owner set
once the window handle exists is counted, because LCL only applies ownership when the handle is
made, and showing a form or reading its canvas makes it. A list box calls OnClick for a user's
click and never for an ItemIndex set in code. A window closed with caFree is gone together with
its list, and touching either afterwards raises, where the real Cheat Engine would read freed
memory. That is how the tests hold the list of hits to never outliving its window, a new scan,
an Uninstall, or the entry file executed again.

## 10. Cheat Engine behaviours that contradict celua.txt

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
