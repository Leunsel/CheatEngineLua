# GH SigMaker Patch

GH SigMaker is a Cheat Engine plugin by Guided Hacking. Its Copy Signature entry puts three
lines on the clipboard.

```
Address of signature = Game.exe + 0x0D762ED9
"\x48\x8B\x00\x00\x00\x66\xC1\xE8\x00\x66\x8B", "xx???xxx?xx"
"48 8B ? ? ? 66 C1 E8 ? 66 8B"
```

Most of the time only the last line is wanted, without the quotes. This script changes your own
copy of the plugin so that Copy Signature puts exactly that on the clipboard and nothing else.

```
48 8B ? ? ? 66 C1 E8 ? 66 8B
```

The signatures themselves are not touched. The plugin still decides which bytes become wildcards
and how long the pattern grows. Only the text it copies is shorter.

This patch is unofficial. It is not made, endorsed or supported by Guided Hacking, so please do not
report problems with a patched copy to them. Restore the original first and check whether the
problem is still there.

## What you need

GH SigMaker v2.0, the file GH-CE-SigMaker.dll, 36864 bytes, from
[Guided Hacking](https://guidedhacking.com/threads/gh-cheat-engine-sigmaker-ce-7-2.16541/). That is
the page the plugin itself links to. This repository does not include the plugin and never will.
The script only carries the file offsets of the bytes it changes, their values before and after,
and the hashes of the whole file before and after.

Windows with PowerShell 5.1 or later, which every supported Windows version ships with.

## Usage

Close Cheat Engine first. A plugin that is loaded cannot be written to.

**Double click GH-SigMaker-Patch.cmd.** It reads the plugin list Cheat Engine stores in the
registry, which holds every plugin added under Settings and Plugins. It also looks in the plugins
and autorun\plugins folders of every Cheat Engine installation under Program Files, if they exist.
Every v2.0 build found there is patched. Other plugins in that list are ignored. A copy anywhere
else has to be passed as a path.

**Or drop GH-CE-SigMaker.dll onto GH-SigMaker-Patch.cmd.** That patches exactly that file. A
folder works too. Explorer only puts quotes around a dropped path when it contains a space. A path
with an ampersand or a caret but no space therefore breaks apart before the script sees it. In that
case pass the path in quotes from a console instead.

When a file cannot be written, for example under Program Files, the script asks Windows for
administrator rights and repeats the work in an elevated window. It does not ask when the console
is already elevated or when -NoElevate is given. A file with the read only attribute is reported
on its own, because administrator rights do not help there. Closing the elevated window early does
no harm. The first window looks at the files afterwards and reports what really happened to them.

After a double click or a drop the window waits for a key, so the result can be read before it
closes. Started from an open cmd or PowerShell window it does not wait.

The .cmd takes a few switches, and so does the script behind it.

```
GH-SigMaker-Patch.cmd                         find and patch
GH-SigMaker-Patch.cmd -Check                  only report what was found
GH-SigMaker-Patch.cmd "D:\CE Plugins"         patch what is in that folder
GH-SigMaker-Patch.cmd -Restore                turn it back into the original
GH-SigMaker-Patch.cmd -NoBackup               skip the .original copy
GH-SigMaker-Patch.cmd -NoElevate              never ask for administrator rights
```

To call the script directly from a console, go through powershell.exe so the execution policy
does not get in the way.

```powershell
powershell -ExecutionPolicy Bypass -File .\GH-SigMaker-Patch.ps1 -Check
```

Running .\GH-SigMaker-Patch.ps1 on its own only works where local scripts are allowed. A copy
unpacked from a ZIP with Explorer also carries the download mark, which Unblock-File removes.

Do not end a quoted folder with a backslash when more arguments follow. Windows reads the
backslash and the quote as one literal quote and glues the rest of the line onto the path. The
script notices that and stops without changing anything.

## Safety

**Only the exact v2.0 build is touched.** The whole file is hashed with SHA-256 before anything
happens. A file that is neither the original build nor the already patched one is reported and left
alone, even if the bytes at the patched offsets happen to look right. A different build could have
its code in different places, and the same offsets would then land somewhere unrelated.

**Nothing is written until every path makes sense.** A path that does not exist, a folder that
cannot be read or holds no GH-CE-SigMaker.dll, or a mistyped switch that ended up as a path, stops
the run before the first file is changed.

**The result is checked before it is written.** The edits are applied in memory first and the
result has to hash to the known patched build. After writing, the file is read back and hashed
again.

**The file cannot change underneath it.** It is opened once with no other access allowed, and read,
checked and written through that one handle.

**Your original is kept.** Before the first patch the untouched file is saved next to it as
GH-CE-SigMaker.dll.original. The copy is written under a temporary name and only takes its real name
once it reads back as the original build. If a file or folder of that name already exists and is not
the original build, or cannot be read, a numbered name is used instead of overwriting it. When the
backup cannot be written at all, that is reported and the DLL stays as it was. A folder that only
administrators may add files to is handled like a file that needs administrator rights. -NoBackup
patches without the copy.

**Restore does not depend on that copy.** The original bytes are known, so restoring writes them
back and checks that the file hashes to the original build again.

**Running it twice does nothing the second time.** A file that is already in the wanted state is not
even opened for writing, so a second run needs no administrator rights and works with Cheat Engine
open.

| Exit code | Meaning |
|---|---|
| 0 | Everything found was patched, restored, or already in the wanted state |
| 1 | At least one file or path could not be handled, see the messages |
| 2 | No known build was found |

With -Check nothing is written, so 0 only means that everything found is a known build, original or
patched. The lines marked original and patched tell which.

## How the patch works

Everything happens in the one function the plugin registers for the disassembler context menu. It
builds its output in two string streams and copies the second one.

```
stream A   \x48\x8B...   ", "   mask   "   line break   "   48 8B ? ? ?
stream B   Address of signature = Game.exe + 0x...   line break   "   A   "
```

That is where the quotes around the last line come from. The first stream closes the mask and
opens a quote for the pattern, and the second stream wraps the whole first stream in one more pair.

Four edits leave only the pattern. Twelve bytes change in total.

| File offset | Before | After | Effect |
|---|---|---|---|
| 0x00ACC | 45 8B E5 4C 39 | E9 E1 00 00 00 | jumps from the start of stream A straight to the wildcard loop |
| 0x00D50 | 48 8D 4D F0 48 | E9 B7 00 00 00 | jumps over the address line in stream B |
| 0x00E22 | C2 | BD | the opening quote now points at an empty string |
| 0x00E40 | A4 | 9F | the closing quote now points at an empty string |

The last two are the lowest byte of a four byte displacement. Each quote call used to point at a
string holding one quote character. Five bytes earlier sits a NUL padding byte between two other
strings, so the call now prints an empty string.

The wildcard loop sets the fill character, the width and the hex format for every byte it writes,
so skipping the first loop loses nothing it relied on. The module name is still looked up and freed
as before. Only the text that would have gone into the stream is skipped.

Nothing is inserted or moved. Every address in the file stays where it was, so the relocations,
the exception tables and the control flow guard data all remain valid. Both jumps start and end in
the same exception handling state, so an exception inside the function unwinds exactly as it did
before.

## Credits

GH SigMaker is made by [Guided Hacking](https://guidedhacking.com/). This script exists because the
plugin is good and only its clipboard format was in the way. The repository licence covers this
script only. It does not cover GH SigMaker or a patched copy of it, which stay under Guided Hacking's
own terms.
