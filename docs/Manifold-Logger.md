# Manifold Logger

`Manifold-Logger.lua` is an autorun extension for Cheat Engine. It provides one log for every
script on the machine and one window to read it in: a canvas-drawn, virtual, filterable log
console with per-level icons and colours, a rotating log file, and adapters for code that already
logs somewhere else.

It is deliberately optional at both ends. Nothing has to require it in order to log into it, and
nothing stops working when the window is closed or the extension is not installed at all.

---

## 1. Installation

`Manifold-Logger.lua` and the `Manifold-Logger-Modules` folder go next to each other in Cheat
Engine's autorun folder, usually `C:\Program Files\Cheat Engine 7.5\autorun`. Confirm the path
from the Lua console:

```lua
return getAutorunPath()
```

```
autorun/
  Manifold-Logger.lua
  Manifold-Logger-Modules/
    Manifold-Logger-Bridge.lua
    Manifold-Logger-Console.lua
    Manifold-Logger-Core.lua
    Manifold-Logger-File.lua
    Manifold-Logger-Format.lua
    Manifold-Logger-Host.lua
    Manifold-Logger-Icons.lua
    Manifold-Logger-Theme.lua
    Manifold-Logger-Version.lua
    Manifold-Logger-View.lua
    Manifold-Icons/
      Manifold-*.png                (16x16 RGBA)
```

`Manifold-Logger.lua` resolves everything from `getAutorunPath()`, so the folder name matters and
the location does not.

### Re-running it at runtime

Executing `Manifold-Logger.lua` again from the Lua console leaves the live log attached. Rebuilding
it would orphan every channel handed out so far, and the buffer is the one thing worth keeping
across a reload. For a genuine rebuild:

```lua
ManifoldLogger:Shutdown()
-- then execute Manifold-Logger.lua again
```

`Shutdown` releases `ManifoldLogger` and `ManifoldLoggerHost` last, after detaching every bridge,
destroying the window and closing the log file. That release is what makes the rebuild possible:
the entry point decides between a cold start and "already running" by looking at those globals, so
a shut-down host left in place would make the documented rebuild silently impossible. It is
guarded by identity, so an older generation cannot unpublish a newer one.

A cold start (no live host) clears `package.loaded` for its own modules first, so editing a module
and reloading really does run the new code.

---

## 2. Two globals

| Global | What it is |
|---|---|
| `ManifoldLogger` | The facade: `Open`, `Channel`, the level helpers, `Configure`, `Status` |
| `ManifoldLoggerHost` | The same object, under the name the other Manifold segments use for a host |

The contract a consumer needs is one line:

```lua
local log = ManifoldLogger and ManifoldLogger:Channel("MyTool")
if log then log:Info("ready") end
```

No `require`, no path, no load order, and nothing to clean up.

---

## 3. The record model

The unit is a **record**, not a line of text.

| Field | Meaning |
|---|---|
| `Seq` | Monotonic id. Survives the ring wrapping, so it identifies a record for selection |
| `Time`, `Millis` | Unix seconds and 0..999 milliseconds |
| `Level`, `Rank` | Name and numeric rank |
| `Channel` | Who produced it |
| `Message` | Text, possibly multi-line |
| `Fields` | Optional structured table |
| `Event` | Optional dotted event name |
| `Repeats` | How many identical messages collapsed into this one |
| `Forced` | Bypassed the level filter |
| `Suppressed` | Below the level: kept, but never reached a sink |
| `Dropped` | How many records the flood limiter dropped before this one |
| `Pinned` | Marked in the view |
| `Trace` | Traceback, when the record came from `Catch` |

Text is derived from the record, never the other way round. That is what lets the same record be
a coloured row on a canvas, a line in a file, a JSON object in an export and a CSV cell without
any of them being the canonical one.

### 3.1 Levels

```
TRACE 10 < DEBUG 20 < INFO 30 < SUCCESS 35 < WARNING 40 < ERROR 50 < CRITICAL 60
```

Ranks are spaced by ten so an intermediate level can be added later without renumbering the ones
a saved configuration already refers to.

`SUCCESS` shares `INFO`'s band on purpose. It is not a severity, it is an `INFO` that went well,
so a view filtered to `INFO` must show it and a view filtered to `WARNING` must not. It is
therefore absent from the console's level dropdown, which offers thresholds rather than names.

Aliases are accepted anywhere a level is: `WARN`, `FATAL`, `CRIT`, `ERR`, `VERBOSE`, `OK`, `OFF`.
They exist so the vocabularies of `Manifold.Logger` (`WARNING`) and the Template Loader (`FATAL`)
both map without a translation table at the call site.

### 3.2 Timestamps

`os.date` resolves to whole seconds, which is not enough to order the lines a single Auto
Assembler script produces. The log anchors `os.time()` against `getTickCount()` once, then derives
each record's time from the tick delta. Records get real milliseconds and a monotonic order.
Drift is corrected by re-anchoring whenever the derived second and `os.time()` disagree by more
than a second, and a negative delta (the 49-day `getTickCount` wrap) re-anchors rather than
producing a nonsense stamp. Without a tick source the log still works, to the second.

---

## 4. Channels

A channel is a named front end onto one log. It holds no state beyond its name and optional
default fields, so handing one out costs nothing.

```lua
local log = ManifoldLogger:Channel("Framework")
local scan = log:Sub("Scanner")            -- "Framework/Scanner"
```

Filtering by a parent includes its children: `Framework` matches `Framework/Scanner` and does not
match `FrameworkOther`. Channels are listed in first-seen order, so the console's dropdown is
stable rather than a `pairs()` shuffle.

---

## 5. Logging

Every level has four shapes, on both the host and a channel:

```lua
log:Warning("disk is nearly full", { free = 214 })
log:WarningF("%d of %d slots used", 98, 100)
log:ForceWarning("shown regardless of the level")
log:ForceWarningF("%s", reason)
```

### 5.1 Blocks

A multi-row report written as N log calls repeats the timestamp and channel on every row, which is
most of the line width. `Block` renders it as one record with labels that line up on their own:

```lua
log:Info(ManifoldLogger:Block("Injection report", {
    { "Address", "game.exe+1A2B3C" },
    { "Bytes",   "48 8B 05" },
    detour and { "Detour", "installed" } or false,   -- `false` skips, `nil` would truncate
    "",
    "trailing note",
}))
```

Use `false` to skip a row. A bare `nil` would cut the list short, because the walk is an `ipairs`
and stops at the first hole. A multi-line value hangs under its own label.

### 5.2 Events

```lua
log:Event("trampoline.install", { name = "Health", overwrite = 7 })
```

The message stays human-readable so the console shows something useful; the fields survive as
fields into the JSON-lines export, which is what makes a log answerable by a script rather than
only readable by a person. This is item R-D in the framework TODO.

### 5.3 Scopes

```lua
local scope = log:Scope("AOB scan")
scope:Step("module resolved")            -- TRACE, invisible unless someone looks
scope:Done("4 results")                  -- one record carrying elapsed_ms
scope:Fail(err)                          -- the same, at ERROR
```

Closing twice logs once.

### 5.4 Catch and Check

```lua
local ok, err = log:Catch(function() risky() end, "risky")
if not log:Check(address, "no address") then return end
```

`Catch` returns exactly what `pcall` does, so the caller still decides what a failure means. The
traceback is taken inside an `xpcall` handler, not after `pcall` returned: by then the failing
stack is already unwound and a traceback would describe the wrapper instead of the fault.

---

## 6. The console

Layout, top to bottom: a toolbar of icon buttons, a filter row, the canvas log view, an optional
detail pane behind a splitter, and a status line. Everything is Align-driven, never absolute, so
the window resizes properly.

### 6.1 Why a canvas

Neither of the obvious controls can do what a log needs.

* A memo is one colour. A log where `CRITICAL` looks exactly like `TRACE` is a text file with a
  scrollbar.
* A `TListView` can carry a per-row image and columns, but its per-row **colour** is only
  reachable through `OnCustomDrawItem`, which Cheat Engine's binding does not expose. Half
  owner-drawing it would leave the selection bar and the header painted by Windows in the system
  palette, next to a fully themed window.

Painting it buys all of it at once: the 16x16 level icon in the gutter, the level's own hue on the
tag and the message, zebra striping, a selection bar, in-place search highlighting, a repeat
badge, a pin marker, a level-coloured edge on anything at `WARNING` or above, and a scrollbar in
the theme's colours.

The view is **virtual**: only the rows on screen are touched, so a repaint costs the window height,
not the buffer size.

### 6.2 The paint surface

Cheat Engine's control set varies between builds, so the canvas is acquired by probing:

1. `createPaintBox` - a `TGraphicControl` with a `Canvas` and `OnPaint`. Rendering still goes
   through an off-screen bitmap that `OnPaint` blits, so a repaint is one blit and there is
   nothing to flicker.
2. `createImage` - a `TImage`, whose `Picture.Bitmap` *is* an off-screen buffer. Rendering into
   that bitmap's canvas and calling `repaint` is already double-buffered.
3. Neither - the console falls back to a themed memo. Degraded, never broken.

A `TPaintBox` and a `TImage` are both `TGraphicControl`s: they have no window handle, so
`WM_MOUSEWHEEL` is delivered to the nearest windowed ancestor rather than to them. The wheel
handler is therefore installed on the surface **and** on its parent panel; exactly one of them can
receive the message, and both do the same thing.

Only `OnMouseWheelUp`/`OnMouseWheelDown` are wired, never `OnMouseWheel` as well.
`TControl.DoMouseWheel` calls `OnMouseWheel` first and falls through to the Up/Down pair only when
that one did not report the event as handled, so setting both scrolls twice per notch on any build
whose binding does not carry the `Handled` flag back out of Lua.

### 6.3 Icons on a canvas

Drawing a 32-bit PNG onto a canvas per row, per repaint, is a `StretchMaskBlt` each time, and on a
build that does not blend it the glyph arrives as a black tile. Each icon is instead composited
**once** onto an opaque bitmap of the row's background colour and cached, keyed by
`(icon, background)`. Every row draw is then a plain opaque blit: faster, and immune to how the
widgetset feels about alpha. The cache is discarded when the palette moves, which is the only time
a background changes.

If the icon set cannot be loaded at all, rows draw a filled square in the level's colour instead.
The levels stay distinguishable.

### 6.4 Refresh, and why it is cheap

The log calls back on every record. Repainting per record would make a script that logs a thousand
lines take a thousand repaints and would starve the code being logged. A record only sets a flag;
a timer turns the newest flag into one repaint every 120 ms.

That is also what makes **Pause** cheap: it stops the repaint, not the recording, so nothing is
lost and resuming shows everything that arrived meanwhile.

Four things keep the frame itself cheap, and all four matter more with a full buffer than with an
empty one.

**Nothing is rendered twice.** Everything derived from a record - its timestamp, its rendered
fields, its physical lines, and the lowercased text a search runs against - is computed once and
kept on the record (`Format.Prepare`). Doing that work per record per frame is O(buffer) at the
frame rate; doing it once per record is O(arrivals). It is safe because a record never changes
after it is emitted except for `Repeats`, `LastTime`, `LastMillis` and `Pinned`, and none of the
four cached values is derived from any of those - the repeat badge is built at paint time from
`Repeats` precisely so the cache cannot go stale.

**The shown list is extended, not rebuilt.** The console keeps one array for the life of the
window and mutates it in place: records that arrived are filtered and appended, records that fell
out of the ring are dropped off the front, and everything between them is left alone. A full
re-scan happens only when the filter changed, the buffer was cleared, or a pin moved. `Core:Since`
walks backwards from the newest record and stops at the last one already seen, so it costs what
arrived rather than what is held.

**Rows are extended too.** The view holds that array by reference; its identity is the evidence
that the rows it already built still belong to these records. New records append rows, trimmed
records drop theirs off the front, and the scroll position moves with them. Zebra striping reads
`record.Seq` rather than a list position, which is what makes trimming a `table.move` instead of a
renumbering pass over every row that is left.

**A frame is one protected call.** Guarding each canvas operation individually costs a closure and
a `pcall` per operation per row per frame - thousands of allocations a second to defend against a
failure that is not intermittent: an API mismatch fails on the first frame and on every frame
after it. So the frame is guarded as a whole, a failure becomes one record on the
`Logger/Internal` channel (where the log's own dedup collapses a repeat into a counter), and five
consecutive failures stop the view rather than filling Cheat Engine's log.

Text measurement follows the same rule. `canvas.getTextWidth` is a Win32 text-extent call, and one
per column per row per frame is the most expensive thing a list like this can do. One reference
measurement per frame gives an average character width; a line is only measured for real when that
estimate puts it near the column edge. In Consolas the estimate is exact, so a normal frame
measures nothing at all.

**Interaction does not wait for the timer.** Scrolling, hovering, selecting and dragging the
scrollbar repaint immediately. The timer exists to coalesce arrivals, not to pace the mouse: a
wheel notch that takes up to a frame to show is the difference between a window that feels direct
and one that feels broken.

### 6.5 Following the tail

`Follow` pins the view to the newest record. Scrolling up turns it off; scrolling back to the end
turns it on again. A log that scrolled away under the cursor while someone was reading is the one
thing a log viewer must not do.

### 6.6 Controls

| Control | Effect |
|---|---|
| Pause | Stop repainting; records keep arriving |
| Follow | Keep the newest record in view |
| Wrap | Wrap long lines instead of cutting them |
| Copy | Copy the selection, or everything shown when nothing is selected |
| Export | Write what is shown to a file; the extension picks the format |
| Clear | Empty the buffer; counters and the log file are untouched |
| Detail | Show the focused record in full |
| Menu | Everything else; also on right-click |
| Level | Threshold filter |
| Channel | One producer, children included |
| Search | Plain text, case-insensitive, filters and highlights |

| Key | Effect |
|---|---|
| Up / Down / PgUp / PgDn | Scroll |
| Home / End | Oldest record / newest and follow again |
| Ctrl+A / Ctrl+C | Select all shown / copy |
| Ctrl+F | Focus the search box |
| Ctrl+P, Pause | Pause and resume |
| Ctrl + / Ctrl - | Larger and smaller text (main row or keypad) |
| F5 / F1 | Refresh / About |
| Esc | Clear the selection, or empty the search box while it has focus |

The window uses `KeyPreview`, which would otherwise steal every keystroke from the search box, so
the box reports its own focus through `OnEnter`/`OnExit`. Reading `form.ActiveControl` back and
comparing it is not reliable: two lookups of the same Cheat Engine object need not produce the
same Lua value.

A key the window consumes is swallowed: Cheat Engine exposes the LCL's `var Key: Word` as the
handler's **return value**, so returning `0` stops the key and returning it unchanged lets it
through to the focused control as well. Both key handlers already compute whether they consumed
the key, and that answer is what decides.

### 6.7 The menu

Right-click, or the **Menu** button: copy (text or JSON lines), select all, pin, filter to this
channel, clear filters, view options (timestamps, channels, structured fields, wrap, text size),
log file actions (open file, open folder, rotate, clear), diagnostics (session report, icon probe,
emit one record per level) and export.

The menu is attached to the log card's **panel**, not to the paint surface. The surface is a
`TGraphicControl` and has no window handle, so `WM_CONTEXTMENU` is delivered to the nearest
windowed ancestor; a menu hung off the handle-less child would never appear. Nothing calls `PopUp`
for the right button - the LCL does that itself once the menu is attached, and doing both would
fight over which one shows. The right button's own handler only moves the selection to the row
under the cursor, which is what makes "Copy selected", "Pin" and "Only this channel" act on the
record that was right-clicked.

The toolbar's **Menu** button is the one place that opens the menu explicitly, and it is the one
that may not work: no script shipped with Cheat Engine 7.5 calls `TPopupMenu.PopUp` from Lua, so
the binding is not something to count on. The same menu is therefore attached to the button as
well - right-clicking it always works - and if `PopUp` turns out to be missing the button says so
once, on the `Logger/Internal` channel, rather than looking dead.

**Emit one record per level** is the fastest way to check a palette change, a new icon set or a row
layout change: eight records, one per level plus a block, in one glance.

### 6.8 The window hides, it does not free

Closing and reopening a log viewer is something people do constantly, and rebuilding the form would
drop the filter, the scroll position and the selection every time. `OnClose` returns `caHide`; the
host frees the window explicitly on `Shutdown`.

---

## 7. Flood control

Two independent mechanisms, because the two floods are different. Both are on by default and both
stay visible in the record stream rather than being silent.

**Dedup** collapses an immediately repeated identical message into one record with a count, shown
as a `x42` badge. Only the previous record is considered, so an alternating pair of messages is
never folded together.

**The token bucket** bounds a burst of *different* messages per channel. It refills at
`ThrottleRate` per second and holds `ThrottleBurst`, so a script that logs a hundred lines at load
time passes untouched while a hook logging every frame is cut off; the next record through carries
`Dropped`, and the console draws it as `+37`. Dropped records never reach the ring: the ring exists
to be readable, and ten thousand identical frames is the one case where keeping them costs more
than it explains.

---

## 8. Sinks

A sink is anything that consumes records: the console view, the log file, `print`, a caller's own
function. A sink with a `Level` of its own follows that level, so the file archives `TRACE` while
the console shows `INFO`, without a second logger. A sink without one follows the log's level, so
turning the log down quietens `print` and the console together. `CaptureLevel` is still the hard
floor for everything: a record below it never becomes a record at all, so no sink can see it.

A `Forced` record reaches every sink regardless, which is what "bypasses the level filter" means.

```lua
ManifoldLogger.Log:AddSink("mine", {
    Level = "ERROR",
    Channels = { MyTool = true },        -- optional
    Write = function(sink, record) ... end,
    Close = function(sink) ... end,      -- optional
})
```

A sink that raises three times is disabled and keeps its reason on `sink.LastError`, rather than
being retried on every line for the rest of the session.

Records are written to the **ring before the sinks**, so a sink that raises cannot lose the record
that explains why. A sink that logs (a file writer reporting that it cannot write) would recurse
without bound; one latch in `Core:Emit` spans both the sinks and the listeners and drops the inner
record after counting it.

---

## 9. Bridges

Two ways to connect a producer, and the difference matters.

**The front door is a channel.** Records arrive structured, with a level, fields and a producer the
console can filter on. Nothing is parsed and nothing is guessed.

**The back door is a bridge.** Code that already exists and logs somewhere else cannot be asked to
change, so a bridge taps its output and turns it back into records. It has to reconstruct the level
from formatted text, which is lossy, so it is the fallback rather than the design.

| Bridge | Mechanism | Attached by default |
|---|---|---|
| `AttachFramework` | Shadows `logger._DispatchLog` on the instance; falls back to wrapping `SetOutput` | Yes, and re-attached by the watch |
| `AttachTemplateLoader` | `Log:AddListener`, an observer; the loader's output is untouched | Yes, when it is installed |
| `AttachPrint` | Replaces `_G.print`, still calling the original | No |
| `AttachPrintSink` | The other direction: mirrors this log into the Lua Engine window | No |

### 9.1 Mirroring a Cheat Table

`Manifold.Logger` funnels every level helper, every `Force` variant and every block through one
method, `_DispatchLog(level, message, forced)`, and calls it **before** applying its own level
filter. Shadowing that method on the *instance* is therefore a lossless tap: the mirror gets the
level as the framework named it, the message before it was formatted into a line, and the forced
flag, and it gets lines the table's own level would have hidden. Because the shadow sits on the
instance and the class method underneath is untouched, detaching is one `rawset` back to `nil`.

`SetOutput` is the fallback, used when a framework version turns up without that funnel. It sees
one already formatted line, so the level has to be read back out of the text, and only lines the
framework's own level let through ever arrive. A rename in the framework therefore costs fidelity,
not the mirror.

Either way the framework keeps working exactly as it did: the original is called on every line and
its own output still reaches wherever it went before.

### 9.2 The watch

Autorun runs when Cheat Engine starts. A Cheat Table's logger is created when a table is opened,
which is minutes later, is created again for every table opened after that, and is a new instance
every time. A bridge attached once at load time therefore attaches to nothing, forever.

So the framework bridge is polled. `Bridge:Watch` runs a timer owned by Cheat Engine's main form -
one `rawget` and two comparisons per tick - and reacts to four events:

| Event | What happens |
|---|---|
| A logger appears | Attach, and say so on the `Logger/Bridge` channel, naming the table |
| A different instance appears | Detach the old, attach the new |
| The global disappears | Detach, and say the mirroring stopped |
| Something else overwrites the hook | Re-attach on top of whatever is there now |

The table's name comes from `logger.LogFileName`, which `SetLogFileName` builds as
`Manifold.Runtime.<name>.log`.

There is no Cheat Engine callback that fires when a table loads, and the alternatives are worse. A
metatable on `_G` sees only the *first* assignment to a global - `__newindex` does not fire once
the key exists - and it would mean an autorun script taking over the global environment's
metatable, which is not ours to take. Polling is honest, cheap and self-correcting.

`WatchTable = false` turns it off; `WatchInterval` sets the period.

### 9.3 The two directions of `print`

Capturing `print` and mirroring the log **into** `print` are opposite taps, and with both on they
form a loop that has to be broken at both ends, differently:

* The capture prints unconditionally and only skips **recording** while the `Relaying` latch is
  held. Skipping the print as well would silence the sink completely - pushing lines to the Lua
  Engine window is the sink's whole job.
* The sink ignores records that arrived on the capture's own channel. Those were already printed
  once, by the capture, on the way in; printing them again is how the window ends up with every
  line twice.

The framework tap holds the same latch across the framework's *own* dispatch, not just around the
mirror. That call ends in the framework's `Output`, which is normally `print`, so an unlatched call
would record the same line a second time - on the `print` channel, without its level and without
its forced flag.

Every bridge is:

* **idempotent** - attaching twice attaches once, so a hot reload cannot build a chain of wrappers;
* **reversible** - `Detach` restores exactly what was there, and only if nothing else took the slot
  in the meantime, so an older output is never put back over a newer one;
* **non-owning** - the producer keeps working when the console is closed, destroyed or never opened;
* **loop-proof** - capturing `print` next to a sink that writes to `print` is a recursion, broken by
  the `Relaying` latch and again by `Core`'s own re-entrancy latch.

`Manifold.Logger` applies its own level filter before its output is called, so a line it suppressed
never reaches the bridge. That is correct: the bridge observes what the framework decided to say.
Lower *its* level to see more.

---

## 10. The log file

`%LOCALAPPDATA%\Manifold\Logs\Manifold.Console.log`, shared with the framework's own
`Manifold.Runtime.<table>.log` files. One folder to open, one folder to clean out; the names do not
collide.

Rotated at 2 MB with three generations (`.1` .. `.3`). Rotation is checked by counting bytes, not
by asking the file system: `lfs.attributes` per line is a syscall per line, and the writer knows
what it wrote.

The writer **never logs**. Every failure path is reachable from inside a log call, so reporting a
write failure by logging it would recurse through the sink that just failed. Failures are recorded
on the writer and surfaced by whoever asks - the console's status bar says `file off`, and the
session report gives the reason. It also disables itself rather than retrying: a path that is not
writable at the first line is not writable at the ten-thousandth either.

It also does **not** flush every line. A flush is a syscall, and a Cheat Table that logs a few
hundred lines while it loads would pay one per line for no benefit: the C runtime's buffer already
holds them, and `Close`, `Rotate` and `Clear` all flush. What *is* flushed immediately is anything
the sink marks important, which is `WARNING` and above - those are the lines that matter when the
process is about to stop existing, which is the only case a lost tail costs anything. `FlushEvery`
bounds how far behind the rest can fall (64 lines by default) and `FlushAlways` restores
flush-per-line.

`FileMode = "jsonl"` writes one JSON object per record instead of a line of text.

---

## 11. Export

| Extension | Format |
|---|---|
| `.log`, anything else | Text, one line per record, continuations indented |
| `.jsonl`, `.json` | One JSON object per record, fields intact |
| `.csv` | `seq,time,level,channel,repeats,message,fields` |
| `.md` | A Markdown table; pipes escaped, newlines become `<br>` |

The selection is exported when there is one, otherwise everything the filter shows.

---

## 12. Theming

The console carries its own copy of the Manifold design language. It must **not** load
`Manifold.Forms`: that module defines the global `Forms` class and belongs to the Cheat Table's
lifecycle, so a second copy loaded from autorun is exactly the collision `Manifold.Bootstrap`
exists to detect. It reads `forms.ActiveDesignTheme` when a live instance is present and falls
back to the bundled Bearded-Arc palette otherwise.

### 12.1 The palette is live

`Manifold.Forms:ResolveTheme` always returns a **complete** `COLOR_*` table - it copies its own
defaults first and overrides them from the theme file's `tokenColors` - so a live design theme
never has to be merged key by key for completeness. It is merged anyway, because this module names
a couple of keys the framework's table does not have to carry.

What did have to change is *when* the colours are applied. The Logger's window is meant to stay
open while a table is being worked on, and that is precisely when its theme gets switched. A window
that coloured itself at construction ends up **half** in the table's theme and half in the bundled
one: the canvas re-reads the palette when it paints, every panel, button, label and box does not.
That is not a partial adoption, it is a stale one, and it is what the symptom "the theme only
partly reaches the Logger" actually was.

So every control this theme colours is registered together with the closure that colours it:

```lua
self:Track(function()
    safeSet(panel, "Color", self:GetPalette()[key])
end)
```

`Theme:Restyle()` re-runs them; `Theme:Forget()` drops them when the window is released, so no
closure survives pointing at a freed control. A closure that fails on its first run is never
registered, and one that starts failing later is dropped rather than retried on every theme change.

Two rules follow from this and both are load-bearing:

* **A `Create*` function must not capture the palette in its closures.** A button's hover and
  pressed states read the palette when they paint. A button that cached its colours would keep the
  theme it was born under for the rest of the session, which is exactly the bug at one control's
  scale.
* **`Color` and `ColorKey` mean different things.** `ColorKey` names a palette entry to follow;
  `Color` is the escape hatch for a colour that is deliberately not from the palette, and it is
  applied once. The code view's background is the one real user of `Color`: it borrows Cheat
  Engine's own editor colours, which are not ours to re-theme.

Two of the framework's keys are taken with care rather than adopted outright.

`COLOR_MUTED` is `Memrec.GroupHeader.Color` - a colour chosen to stand out against Cheat Engine's
address list, not against this console's panel, and nothing in a theme file promises it is legible
here. The console uses it for the status line and the filter captions, so it is contrast-corrected
on the way in, in the same spirit as the per-level hues. The correction happens **inside** the
branch that builds a merged copy: the other branch hands back the shared bundled palette by
reference, and correcting it there would permanently alter Bearded-Arc for the rest of the session.

Completeness is also not guaranteed, contrary to what a first reading of `ResolveTheme` suggests.
It fills its own defaults and overrides them from `tokenColors` on one branch, but handed a table
that already looks like a design theme it returns a verbatim copy with nothing filled in. What
reaches `ActiveDesignTheme` is therefore only as complete as whoever called `ApplyTheme`, which is
why the palette is merged key by key against this module's own defaults rather than used directly.

### 12.2 Noticing the change

By **identity**, not by comparing colours. `Forms:ApplyTheme` assigns `ActiveDesignTheme` a fresh
table returned by `ResolveTheme` on every application, so

```lua
if self.Theme:Source() ~= self.ThemeSource then ... end
```

is an allocation-free check, cheap enough to run on the console's existing 120 ms tick, and exact.
`Theme:GetPalette` caches its merged copy against the same identity, which matters because the
canvas asks for the palette on every frame and every hover repaint asks again.

`Console:CheckTheme` runs on the tick and on `Open` - a theme may have been applied while the
window was hidden. It restyles the chrome and repaints the canvas; the canvas notices the new
palette itself and drops the composited icons with it.

The check sits **before** the tick's pause guard. Pausing stops the log from moving; it does not
mean the window may be the wrong colour, and a theme switched while the console is paused would
otherwise leave it half themed until somebody resumed it. Nothing about it resumes the log:
`CheckTheme` repaints the records already shown, it never refreshes them.

### 12.3 What this copy has that its siblings do not

The Template Loader's and Table Files' copies pick the palette up when a window opens and leave it
there, which is right for a window that is opened, looked at and closed. Beyond the live palette,
what this copy has that they do not, all because it paints its own list:

* `Mix`, `Shade`, `Luma` and `Contrast` - the canvas needs colours the palette does not name: a
  zebra stripe two shades off the background, a selection bar, a hairline. `Shade` moves towards
  white on a dark theme and towards black on a light one, so one call is correct under both.
* `LevelColors` - each level's hue, taken from its icon artwork so a row and its glyph always
  agree, then pushed away from the background in use until it is legible. A hue chosen against the
  bundled dark theme would otherwise disappear on a user's light one.
* `CreateToolButton` - a panel button that can carry a glyph and hold a pressed state, which is
  what `Follow`, `Wrap` and `Pause` are. A toggle that looks identical in both states is the
  fastest way to make a toolbar lie.

---

## 13. Cheat Engine specifics this depends on

All verified against the CE 7.5 and Lazarus sources.

* `createPNG(w,h)` returns a `TPortableNetworkGraphic`, which descends
  `TFPImageBitmap -> TCustomBitmap -> TGraphic`. That makes it valid for both
  `customimagelist_add` (which casts to `TCustomBitmap`) and `canvas.draw` (which wants a
  `TGraphic`).
* `createBitmap():loadFromFile('x.png')` does **not** work. `TBitmap` reads only BMP, and
  `TGraphic.LoadFromFile` does no format sniffing, so it runs the BMP reader over PNG bytes and
  raises. `TPicture.LoadFromFile` *does* sniff by extension, which is why the toolbar glyphs can
  be loaded from a file and the image list cannot.
* `createPicture()` is a `TPicture`, which is not a `TGraphic`. Handing one to `add()` or to
  `canvas.draw` is an unchecked pointer type-pun, and `picture.getBitmap()` converts in place and
  frees the PNG behind your back. Avoided entirely.
* `imagelist.add` never returns `-1`. Given something it will not take it returns the pre-insert
  `Count`, a plausible index for an image that was never added, so success is verified by watching
  `Count` actually increase.
* A size mismatch in an image list **stretches** (`TFPImageCanvas.StretchDraw`), it does not centre
  or clip, so the list size is read back after being set rather than assumed.
* `TMenuItem` has no `ImageList` property in any Lazarus version. CE's `lua_setProperty` stashes
  unknown property writes in the userdata's metatable inside a `try..except`, so
  `item.ImageList = list` assigns cleanly, reads back correctly and does nothing. The property is
  `SubMenuImages`, and because `TMenuItem.GetImageList` starts its walk at the item's **parent**, an
  item's own `SubMenuImages` applies to its children and never to itself.
* `TMenuItem.SetImageIndex` early-exits when the new value equals the old and again when no image
  list resolves, so `-1` is written first to guarantee a real transition, and only after
  `SubMenuImages` is already attached to the parent.
* `TMenuItem.delete` only **detaches**. Items are destroyed afterwards, or every reload orphans a
  whole menu tree plus its click closures.
* Native `TButton` ignores `Color` on Win32, so buttons are panels with a centred label.
* `TMemo` and `TEdit` inherit `clWindow` (white) and are painted through `WM_CTLCOLOR*`, so
  `ParentColor` must be off and `Color` set explicitly for the assignment to take effect.
* Colours are BGR integers, not RGB. The JSON themes store `#RRGGBB`.
* `OnKeyDown`'s return value is the LCL's `var Key: Word`. Returning `0` swallows the key.
* No script that ships with Cheat Engine 7.5 calls `TPopupMenu.PopUp`, `getMousePos` or
  `createPaintBox`; all three are treated as optional, and the console degrades visibly rather
  than silently when one is absent. `createImage` **is** used by Cheat Engine's own ceshare
  scripts, which is why it is the fallback that matters.
* **Mouse events do not carry the LCL's `Shift` argument.** Cheat Engine's binding drops it, so
  `OnMouseDown` arrives as `(sender, button, x, y)` and `OnMouseMove` as `(sender, x, y)`, not the
  five and four argument shapes the LCL declares. Assuming the LCL's shape makes `y` nil and turns
  every mouse move into a raised error, which Cheat Engine prints - one line per event, which will
  make any window feel broken long before anything in its paint path does. The view takes the
  coordinates as the last two numbers in the argument list, which is correct under both
  conventions.
* `TControl.DoMouseWheel` calls `OnMouseWheel` first and only falls through to
  `DoMouseWheelUp`/`Down` when that one reported the event as handled. Setting both therefore
  scrolls twice per notch on any build whose binding does not carry the `Handled` flag back out of
  Lua, so only the Up/Down pair is used.

---

## 14. Degrading

| Missing | Result |
|---|---|
| The icon set | Rows draw a filled square in the level's colour |
| `createPaintBox` | Falls back to `createImage`, equally double-buffered |
| Both | The window falls back to a themed memo: no colour, no icons, still a log |
| `createPopupMenu` | No context menu; the toolbar and keys still work |
| `createSaveDialog` | Export asks for a path through a themed prompt instead |
| `createTimer` | No live refresh; F5 and any interaction still repaint |
| `lfs` | File logging disables itself and says why |
| A writable `%LOCALAPPDATA%` | The same |
| The window, entirely | Logging keeps working. The console is optional by design |

---

## 15. Internal structure

| File | Responsibility |
|---|---|
| `Manifold-Logger.lua` | Autorun entry: paths, the singleton, the two globals |
| `-Host` | Owns the log, the writer, the icons, the theme, the bridges and the console |
| `-Core` | Levels, records, the ring, channels, sinks, flood control, scopes |
| `-Format` | Every rendering: text, columns, blocks, wrapping, JSON, export |
| `-File` | The defensive fs layer and the rotating writer |
| `-Icons` | The image list for menus, and the composited glyphs for the canvas |
| `-Theme` | The palette, the colour algebra and the control factory |
| `-View` | The canvas: geometry, incremental rows, painting, scrolling, selection, hit-testing |
| `-Console` | The window: toolbar, filters, detail pane, menu, refresh timer |
| `-Bridge` | The taps onto other producers |
| `-Version` | The single source of the version number |

`Core`, `Format` and `File` touch nothing outside plain Lua, and every geometric decision in the
view lives in `View.Layout` as free functions over plain tables. That is not tidiness for its own
sake: it is what lets the row builder, the scroll clamp and the scrollbar thumb be tested without
Cheat Engine, and those three are where the bugs in a list like this live.

---

## 16. Tests

`Manifold-Logger-Tests/` holds a Cheat Engine stub and a self-validating run script:

```
lua Run.lua <projectDir> <scratchDir>
```

It covers the record model, the formatters, the rotating writer against the real file system, the
view's geometry, the icon loader against the real PNGs, the bridges, and the console end to end -
including the canvas, so the paint path is executed and asserted rather than assumed. The stub
records every drawing call, so a test can check that a row was painted, that the icon composite was
blitted exactly once from the cache, that the scrollbar thumb landed where the geometry says and
that a search match was highlighted at the right width.

The parts that are easy to get subtly wrong have tests of their own: that an arrival appends rows
instead of rebuilding them (the row array's identity is the assertion), that a ring which wrapped
trims the front off both lists and moves the scroll position with it, that the memoised render
cache survives a dedup increment, that the framework hook is lossless and leaves nothing behind
when it detaches, that the watch reacts to a table appearing, being replaced, having its hook
stolen and going away, and that a frame which raises is reported once rather than per row.

The stub reproduces the traps rather than smoothing them over. Its `imagelist.add` returns the
pre-insert count when it refuses a graphic, exactly as the real one does, which is what proves the
loader watches `Count` instead of trusting the return value.
