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

### Updating

Replace `Manifold-Logger.lua` and the **whole** `Manifold-Logger-Modules` folder together. The
console and the theme of one release are built for each other. A console that meets the theme of
another release may not build its window. In that case the window stays closed, and a record on
`Logger/Internal` says why. After copying, restart Cheat Engine, or run `ManifoldLogger:Shutdown()`
and then execute `Manifold-Logger.lua` again. Re-running the file without the shutdown keeps the
modules that are already loaded.

- **Restarting Cheat Engine** is the clean path.
- **The shutdown path** empties the in-memory buffer, and the log file keeps everything. A script
  that took a channel before the shutdown still holds the old log, so it should take its channel
  again.

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

```
┌ Manifold Logger 1.1.0 - Manifold ──────────────────────────────────────────────────────────┐
│ [||][>>][wr] │ [cp][ex][cl] │ [dt]  [search, any case                                ] [*] │
│ Level [Info       v]  Channel [All channels                                        v]  [x] │
│ ┌────────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ (i) 14:02:11.532 INF Framework     Teleport saved                                      │ │
│ │ (!) 14:02:11.610 WRN Framework     Slot 98 of 100 used                                 │ │
│ │ (x) 14:02:12.004 ERR Teleporter    No address for Player                            x3 │ │
│ └────────────────────────────────────────────────────────────────────────────────────────┘ │
│ ══════════════════════════════════════════════════════════════════════════════════════════ │
│ ┌ Record ───────────────────────────────────────────── ERR  Teleporter  14:02:12.004  x3 ┐ │
│ │ Time    : 2026-09-17 14:02:12.004                                                      │ │
│ │ Level   : ERROR                                                                        │ │
│ └────────────────────────────────────────────────────────────────────────────────────────┘ │
│ PAUSED  -  120 of 124 shown  -  4 hidden by filter         ERR 2  |  WRN 4  |  file 1.2 MB │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

From top to bottom, the window has five parts.

- **The toolbar.** On the left are seven icon buttons in three groups: Pause, Follow and Wrap,
  then Copy, Export and Clear, then Detail. The menu button sits at the right edge, and the search
  field takes the space in between.
- **The filter row.** The level box is on the left. The clear filters button is at the right edge,
  under the menu button. The channel box takes the space in between.
  - The two boxes and the search field are all field rows. Each one has a frame and uses the
    input colours.
  - The level row is as wide as its label plus its longest level name.
  - The channel row is never narrower than its label plus `All channels`.
- **The log card.** It takes whatever height is left.
- **The detail card.** It sits under its splitter, and both stay hidden until somebody asks for
  them.
- **The status line.** It is always at the bottom.

Every control is aligned, and nothing is placed by hand next to an aligned sibling.

**Build order.** The LCL puts the **last** created `alTop` or `alLeft` control outermost, and the
**first** created `alBottom` or `alRight` control outermost. A window built hidden is laid out in
one pass while every sibling still stands at zero, so the build order decides any tie. That makes
the build order:

1. the status line
2. the detail card
3. the detail splitter
4. the toolbar
5. the filter row
6. the log card

Two more steps keep the order certain:

- The toolbar's left group is built right to left, Detail first and Pause last.
- The two bars and the status line get first positions far apart from each other. The alignment
  then never has a tie to break, and it moves each one to where it belongs before anything is
  seen.

**Keeping the detail card above the status line.** A hidden control keeps the bounds it had, and
an `alBottom` stack sorts by the far edge. A card shown after the window shrank could therefore
sort below the status line. To prevent that, the card and its splitter move to the top edge
whenever they are shown or refitted. Their far edge is then their own height, so the status line
stays under them. The card is shown before the splitter.

**The least size is worked out, not written down.**

- **Width.** The frame, plus whichever is wider of the toolbar and the filter row. The toolbar is
  measured with the search field showing its whole placeholder.
- **Height.** The sum of:
  - the frame, the two bars and the status line
  - four log rows
  - three lines of the detail card
  - the gaps between them

  The detail card is counted even while it is hidden, so showing it at the least height never
  overlaps anything.

The window opens at 980 by 620. With Consolas at 96 dpi, the least size is 484 by 351. The
Diagnostics menu's Session Report shows the least size this window worked out.

**Refitting the detail card.** This happens whenever the window changes size and whenever a
splitter drag ends:

- The card keeps the height that was asked for.
- A lower window takes height from the card, and a taller window gives it back.
- The card never gets smaller than three lines.
- The log card never gets smaller than four rows.

**A build that fails** partway through frees what it made and writes one record to
`Logger/Internal`. The record names the error and says to copy the whole modules folder, because
the likeliest cause is a partial update where a new console meets an older theme. A Cheat Engine
with no `createForm` writes a warning instead and leaves the console closed.

### 6.1 Why a canvas

Neither of the obvious controls can do what a log needs.

* A memo is one colour. A log where `CRITICAL` looks exactly like `TRACE` is a text file with a
  scrollbar.
* A `TListView` can carry a per-row image and columns. Cheat Engine 7.5 does register its
  custom draw events (`OnCustomDrawItem` and `OnCustomDrawSubItem`), so a row can be given its own
  colour. The selection bar and the column header are still drawn by the system, though. A themed
  window would carry a bar and a header in the system palette, and drawing a themed selection
  means painting the whole row by hand anyway.

Painting it buys all of it at once: the 16x16 level icon in the gutter, the level's own hue on the
tag, zebra striping, a selection bar, in-place search highlighting, a repeat badge, a pin marker,
a level-coloured edge on anything at `WARNING` or above, a scrollbar in the theme's colours, and
text that stays readable on a selected or hovered row.

The message takes the level's hue only at `SUCCESS` and at `WARNING` or above, so a normal log is
not a rainbow. Every other message is drawn in the text colour, or in `SelectionText` on a
selected row. The message of a below-level record, and the fields and traceback rows of any
record, are drawn in the muted colour, whatever the level.

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
a timer, the refresh tick, turns the newest flag into one read of the log and one repaint every
120 ms.

That is also what makes **Pause** cheap: it stops the refresh tick from taking new records into
the view, and nothing else.

- The log keeps recording, so nothing is lost.
- The frame timer keeps painting what is shown, so the window still answers the mouse.
- Resuming reads everything that arrived meanwhile. So does every command that reads the log
  again while paused, among them F5, a new level, channel or search, the View menu's options,
  pinning, Clear, a text size change, the diagnostics entries and reopening the window.
- A repeat of the record the detail card shows reaches the card on resume, or earlier with any of
  those commands.

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
per column per row per frame is the most expensive thing a list like this can do. A reference
measurement gives an average character width, and a frame takes it only when it finds the metrics
missing or the size changed. That is the first frame, a resize, and anything that drops the
metrics, such as a new font size or a View menu option. A wider channel that moves the columns
takes it again in the same frame. Every other frame reuses it, and a line is only measured for
real when that estimate puts it near the column edge. In Consolas the estimate is exact, so a
frame measures only text that comes close to its limit. In practice that is the widest channel
name, because its column is exactly that wide, and any repeat badge on screen.

**Interaction asks for a frame and gets it within one 15 ms tick.** Painting inside a mouse event
floods the UI thread, because Cheat Engine sends a move event for every pixel the pointer crosses.
So nothing paints inside an event. The following only change state and mark the view dirty:

- a mouse move, a click or a wheel notch
- a key the log view handles, such as an arrow key
- a thumb drag
- a selection change
- the toolbar's Wrap toggle

A search change marks the view dirty as well, so the highlight moves on the next frame. The
filtered list it needs comes from the refresh tick, within 120 ms, or at once while the log is
paused. Wrap Long Lines in the menu reads the log again, like every View menu option, so it paints
at once.

A second timer, the frame timer, runs every 15 ms. Windows rounds a timer up to its own 15.6 ms
tick, so fifteen is the smallest interval that means what it says. On each tick, the frame timer:

1. returns at once while the window is hidden
2. runs the theme's settle pass (see 12.3)
3. repaints the view if it is dirty, and does nothing otherwise

A burst of mouse moves therefore costs one frame, not one frame per event.

The two timers split the work this way:

- **The refresh tick** (120 ms) reads the log and paints at once when records arrived. So does a
  command that reads the log again, such as a level or channel change or F5. Neither ever runs
  inside a mouse move. When a record already shown was only repeated, the tick leaves the repaint
  to the frame tick and brings the detail card up to date.
- **The frame tick** does the painting for everything else.

The frame timer has its own failure counter. After five failures in a row it stops, and the
refresh tick takes over its painting. A Cheat Engine without `createTimer` has neither timer.

`Release` treats both timers the same way:

- If the form was destroyed from outside, the timers were already freed with their owner, so
  `Release` leaves them alone.
- Otherwise it disables and destroys them before the form goes.

### 6.5 Following the tail

`Follow` pins the view to the newest record. Scrolling up turns it off; scrolling back to the end
turns it on again. A log that scrolled away under the cursor while someone was reading is the one
thing a log viewer must not do.

### 6.6 Controls

The toolbar buttons are icons with no caption, so each one is 30 wide and 28 high and a row of
them fits a narrow window. Each button's tooltip is the only place it states its name. The theme
adds the shortcut to the tooltip in brackets, so the Pause tooltip reads `Pause. Hold new records
out of the view until you resume or refresh. Nothing is lost. (Ctrl+P)`. Pause, Follow, Wrap and
Detail are toggles, and their fill shows their state. Each console keeps its buttons in its own
`Buttons` field, by key, each with its `Panel`, `Enable`, `Press` and `Label`.

| Control | Kind | Effect |
|---|---|---|
| Pause | Toggle | Hold new records out of the view. The log keeps recording them and the view still paints, see 6.4 (Ctrl+P) |
| Follow | Toggle | Keep the newest record in view. The view presses and releases it as scrolling disarms and re-arms following (End) |
| Wrap | Toggle | Wrap long lines instead of cutting them. `Console:SetWrap` keeps it and the menu's Wrap Long Lines check in step |
| Copy | Button | Copy the selection, or everything shown when nothing is selected (Ctrl+C) |
| Export | Button | Write the selection, or everything shown, to a file. The extension picks the format |
| Clear | Button | Empty the buffer. The counters and the log file are untouched |
| Detail | Toggle | Show or hide the detail card |
| Search | Field | Plain text, any case. Filters and highlights (Ctrl+F). The placeholder reads `search, any case` |
| Menu | Button | Everything else, also on right-click in the log |
| Level | Box | Threshold filter: All, Trace, Debug, Info, Warning, Error, Critical |
| Channel | Box | One producer, sub-channels included. `All channels` first, then every channel in first-seen order |
| Clear filters | Button | Level, channel and search go back to showing everything |

The level and channel boxes are owner drawn, so the closed box and the dropped list both use the
input colours. A channel name too long for the box is cut with dots. Setting a box's `ItemIndex`
in code fires nothing, so after a clear the console refreshes the filter itself.

| Key | Effect |
|---|---|
| Up / Down / PgUp / PgDn | Scroll |
| Home / End | Oldest record / newest and follow again |
| Ctrl+A / Ctrl+C | Select all shown / copy |
| Ctrl+F | Focus the search box |
| Ctrl+P, Pause | Pause and resume |
| Ctrl + / Ctrl - | Larger and smaller text (main row or keypad) |
| F5 / F1 | Refresh / About |
| Esc | Empty the search, then clear the selection, then hide the window |
| Double-click | Open the detail card on that record |

Ctrl+F and Esc work from anywhere. While the search box has focus, every other key belongs to the
box, so Ctrl+A and the arrow keys act on the search text there. When the box does not have focus,
those keys go to the log view.

**Escape** puts things away in the order a person expects:

1. If the search box holds text, or a search filter is active, Escape empties the search.
2. Otherwise, if records are selected, it clears the selection.
3. Otherwise it hides the window, the same `caHide` a close gives. The log, the buffer, the log
   file and every setting carry on.

There is one exception to step 3. An empty search box that has the focus hands the key back, so
an Escape aimed at the box never hides the window. The window does not use the theme's
`EscCloses` option, because it handles Escape itself.

**The detail card** shows the selected record in full, in this order:

1. the time with the date
2. the level and the channel
3. the event, the repeat count, the dropped count, the forced flag, the below-level flag and the
   source, for each one the record has
4. the message
5. the fields and the traceback, if the record has them
6. the record as a JSON line

The card follows the **selection**, not the row under the mouse (`View:SelectedRecord`). The
record shown is the one the last click landed on, while it stays selected, and otherwise the first
selected record. A right click on a row that is already selected keeps the selection and leaves
the card where it is. Every other click counts:

- A plain click selects its record and shows it.
- A Shift click selects the range and shows the record it landed on. The anchor stays where it
  was, so the next Shift click ranges from the same record.
- A Ctrl click that adds a record shows it. A Ctrl click that takes the shown record out moves the
  card to the first record still selected.

The view keeps that click as `Current` and `CurrentSeq`, beside `Anchor` and `AnchorSeq`. A
rebuild and records dropping off the front of the ring keep both on their records, and clearing
the selection forgets both. The card therefore stays put while records scroll past under a resting
pointer.

The context menu mostly acts on the selection. Copy Selected, Copy as JSON Lines and Pin / Unpin
take the selected records, and the two copies take everything shown when nothing is selected.
Only This Channel takes `View:FocusedRecord`, which prefers the row under the pointer. See 6.7 for
what a right click selects.

The counter in the card's title strip names the record, cut to fit the room the title leaves. It
holds the level tag, the channel, the time, `xN` for a repeat and `+N dropped` for a drop. With no
selection it reads `nothing selected`, and the memo reads `Select a record.` The memo is rewritten
only when the record, its repeat count or its drop count changed, or when the card opens. A repeat
of the record shown reaches the counter and the memo on the next refresh tick. While the log is
paused it arrives on resume, or on any command that reads the log again.

**The status line** has two halves, and both are cut to fit their room. A cut label carries its
whole text in its tooltip.

The left half shows one of three things, in this order of priority:

1. A flashed message, such as `3 records copied` or `Log file rotated`, for 2.5 seconds. The
   refresh tick lets it run out, even while records arrive or the log is paused.
2. While the pointer rests on a log row with something to say, that row's hint:
   - the whole text of a row that was cut
   - the whole channel name, when the channel column cut it
   - `repeated N times`, `N dropped after this` and `pinned`, for the marks the row carries
3. The counts: `N of M shown`, then `N hidden by filter` and `N dropped (flood)` when they are
   not zero. `M` is what the buffer holds, and the hidden count is `M` less `N`. A console with no
   canvas adds `no canvas:` and the reason.

While the log is paused, `PAUSED` leads the left half, whichever of the three it shows. Pausing
lasts until somebody resumes, so a flash or a hint that only lasts a moment must not hide it. The
theme cuts a sentence at its end, so the mark in front survives a cut.

The right half counts `CRT`, `ERR` and `WRN` records, each only when it is not zero, and shows the
log file's size, or `file off`. A repeat adds nothing to these counts, because they count records.
The counts come from the log's session counters (`Core:GetStats`), and `Core:Clear` empties the
ring without touching them, so Clear leaves them as they were. The right half takes what the left
half's text leaves, and never less than half the bar. When it cannot fit
every counter, it keeps as many whole counters as fit and ends in dots.

**An empty log view** draws two centred lines, a bold title and a muted hint, each cut to fit. The
console chooses the text:

- With an empty buffer, the title is `No records yet`, and the hint names
  `ManifoldLogger:Channel('Name')`.
- When the filter hides everything, the title is `Nothing matches`, and the hint says how many
  records are hidden. It then says that Esc empties the search, or, when no search is active, that
  Clear filters shows the records again.

**Rows on a highlight get readable colours.** The level hues and the muted colour are made to
read at 4.5:1 on the plain and the striped rows (see 12.1 and 12.3). A selected row leans towards the accent and a hovered row towards white,
so the same colour can drop to about 2:1 there. On those two row tones, `View:Legible` adjusts
every text colour and both marks until they reach the 4.5:1 contrast WCAG asks for:

- It asks the theme's `Contrast` for a little more distance each round.
- When `Contrast` stops short, it falls back to white or black, whichever reads better.
- On a selected row, a plain message starts from `SelectionText`.
- Search hits get the same treatment against the highlight tone, on every row. The text colour
  inside a hit is chosen for contrast against the highlight, so a level colour can turn white or
  black there. Under the bundled palette every hit is white, and under Dark-Forest, Dark-Hacker
  and Dark-Cotton-Candy every hit is black.

The answers are cached per colour table.

**Search hits** are drawn as bands that run from one pixel below the row's top edge to one pixel
above its bottom edge, so a hit reads as a band and not as a strip the height of the glyphs. The
message text is then drawn in runs, with the brush switched to the highlight colour for each hit.
`textOut` fills its own cell with the brush, so drawing the message in one piece would wipe the
highlight out.

Only the message column gets bands. That column holds the message and, below it, the fields row
and the traceback rows. The search itself matches the message, the channel and the fields
(`Format.Prepare`'s `Haystack`). So a record found only by its channel shows no band, and neither
does one found only by a field while structured fields are hidden. A row carries at most eight
bands.

**Badges.** A row with a repeat or drop badge cuts its message with dots before the badge.

**The scrollbar** takes its 12 px only while the list is longer than the view. A list that fits
runs its rows to the right edge, and a click there lands on a row. The thumb takes the accent
colour under the pointer and while it is dragged. The wrap width always leaves room for the strip,
so whether the strip shows can never change how many rows there are.

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
emit one record per level), export and about.

The menu is attached to the log card's **panel**, not to the paint surface. The surface is a
`TGraphicControl` and has no window handle, so `WM_CONTEXTMENU` is delivered to the nearest
windowed ancestor; a menu hung off the handle-less child would never appear. Nothing calls `PopUp`
for the right button - the LCL does that itself once the menu is attached, and doing both would
fight over which one shows. The right button's own handler selects the row under the cursor,
unless that row is already selected, and then the selection stays as it is. A right click outside
the selection therefore makes "Copy Selected", "Pin / Unpin" and "Only This Channel" act on the
record that was right-clicked. A right click inside a multi-row selection makes the copies and the
pin act on all of it.

The toolbar's **Menu** button is the one place that opens the menu explicitly, and it is the one
that may not work. No script shipped with Cheat Engine 7.5 calls `TPopupMenu.PopUp` from Lua, so
the binding is not something to count on. For that reason:

- The same menu is also attached to the button, so right-clicking the button always works.
- If `PopUp` turns out to be missing, the button says so on the status line and as a warning on
  `Logger/Internal`, rather than looking dead. The log's dedup folds a repeat of that warning into
  a counter.
- Without `getMousePos`, the menu opens near the window's top left corner instead of at the
  pointer.

**Wrap Long Lines** and the toolbar's Wrap toggle both go through `Console:SetWrap`, so whichever
one is used, the other follows.

**Emit one record per level** is the fastest way to check a palette change, a new icon set or a row
layout change: eight records, one per level plus a block, in one glance.

### 6.8 The window hides, it does not free

Closing and reopening a log viewer is something people do constantly, and rebuilding the form would
drop the filter, the scroll position and the selection every time. `OnClose` returns `caHide`,
and Escape with nothing left to clear hides the window the same way. The host frees the window
explicitly on `Shutdown`, and `Console:Destroy` stops both timers before the form goes.

A new window is restyled once it is on screen. Cheat Engine overwrites some colours when it
creates the handles, which for a window built hidden happens at show.

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
  applied once. Nothing in the console uses `Color` today. The option stays for a colour that
  must not follow the theme.

Two of the framework's keys are taken with care rather than adopted outright.

`COLOR_MUTED` is `Memrec.GroupHeader.Color` - a colour chosen to stand out against Cheat Engine's
address list, not against this console's panel, and nothing in a theme file promises it is legible
here. The console uses it for the log's timestamps and channels, the status line, the card
counters and the field labels. So `GetPalette` passes it through `Theme.Readable` on the way in,
the same correction the per-level hues get. It has to reach 4.5:1 on four tones: the input colour
and its stripe under the log, the panel under the status line and the card headers, and the form
colour behind the text prompt. That lightens Dark-Aqua's `#0076cc` to `#1a82d8` and Dark-Dark-Hell's
`#9e1b1b` to `#d25047`. The correction happens **inside** the branch that builds a merged copy: the
other branch hands back the shared bundled palette by reference, and correcting it there would
permanently alter Bearded-Arc for the rest of the session. The bundled muted blue needs no
correction, since it reads at 9.17:1 or better on all four tones, and a test checks that it
reads there unchanged.

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
`Theme:GetPalette` caches its merged copy against the same identity. That matters because the
canvas asks for the palette on every frame, and the frame timer can paint about sixty times a
second.

`Console:CheckTheme` runs on the tick and on `Open` - a theme may have been applied while the
window was hidden. It restyles the chrome and repaints the canvas; the canvas notices the new
palette itself and drops the composited icons with it.

The check sits **before** the tick's pause guard. Pausing stops the log from moving; it does not
mean the window may be the wrong colour, and a theme switched while the console is paused would
otherwise leave it half themed until somebody resumed it. Nothing about it resumes the log:
`CheckTheme` repaints the records already shown, it never refreshes them.

### 12.3 What this copy is

`Manifold-Logger-Theme.lua` is the Address List's theme with three changes, and the shared part is
kept word for word. A diff of the two files therefore shows those three changes, the wording of
the file header and the comment on `Surface`, nothing else. The comment on `Surface` describes the
log view. The other comments in the shared part still take their examples from the Address List
window.

**Left out**, because the console never builds them:

- the code views
- the tab strip
- the colour swatch
- the empty state panel
- the native check box styling
- the two choice dialogs

**Added:** the level hues, `Theme.LevelDefault`, and `Theme:LevelColors`.

- Each hue is sampled from the level's icon artwork, so a row and its glyph always agree.
- Each hue has to reach a contrast ratio of 4.5:1 on both tones a plain row of the log view can
  have, the input colour and its stripe. A hue chosen against the bundled dark theme would
  otherwise disappear on a light one. A hue that already reads on both is drawn exactly as the
  artwork has it.
- `LevelColors` is a method and not a `Surface` key, because the view caches the two tables side
  by side and no other canvas needs a level hue. It builds a fresh table on every call.

**Changed:** text colours are made readable by the contrast ratio WCAG measures, not by a distance
in luma.

- `Theme.Luminance` is the relative luminance of a colour, and `Theme.Ratio` is the ratio between
  two colours, from 1 to 21. `View.Ratio` is the same measure inside the view, so the view can
  judge a colour without a theme. The tests hold the two to the same answer.
- `Theme.Readable(color, tones, ratio)` returns a colour that reaches the ratio on every tone in
  the list, `Theme.ReadableRatio` (4.5) unless told otherwise. Only the lightness moves. The hue
  is held in OKLab and the chroma is kept wherever the screen can show it, so a red that has to
  brighten stays red instead of turning pink. The search finds the nearest lightness that reads.
  When no lightness reads on every tone, the one that reads best on the worst tone wins. So
  `Readable` is best effort. A grey canvas from `#707070` to `#747474` and its stripe leave no
  colour at all that reaches 4.5:1 on both, and every level there gets 4.37:1 to 4.49:1. A colour
  that already reads comes back unchanged.
- `LevelColors` and `GetPalette` call `Readable`, the first for the level hues and the second for
  the muted colour (see 12.1). The stripe step is the constant `STRIPE_STEP`, so `Surface`,
  `LevelColors` and `GetPalette` always mean the same stripe.
- The luma rule this replaced mixed a hue with white, or with black on a light palette, in steps
  of 18 percent until it stood seventy apart from the background in luma. With 1.0.0's `Luma`,
  which put the red weight on the blue byte, that rule moved the ERROR artwork red, `#d70b31`, to
  `#de3756`. With the corrected `Luma` it would let `#d70b31` through unchanged, because the red
  sits 71.9 apart from the bundled background, yet it reads at only 3.89:1 on the plain row and
  3.58:1 on the stripe. Fixing `Luma` alone would have made ERROR harder to read, which is why the
  rule itself was replaced.

**What the console uses**, directly or through another member:

| Part | Members |
|---|---|
| The live palette | `Source`, `GetPalette`, `Track`, `Restyle`, `Forget`, and `Mark` and `ForgetSince` around the prompt |
| Colour algebra | `Split`, `Join`, `Mix`, `Luma`, `IsDark`, `Shade`, `Contrast`. The view's `Legible` calls `Contrast` |
| Readable colours | `Luminance`, `Ratio`, `Readable` and `ReadableRatio`. `LevelColors` and `GetPalette` call `Readable` |
| Canvas colours | `Surface`, which derives the stripe, hover, selection, highlight, scrollbar and header tones and the severity hues |
| Text fitting | `TextMetrics` and `CharWidth`, measured once per font size. `FitText` cuts a caption with dots and puts the whole text in the tooltip |
| The window and its frame | `CreateWindow` (with `MinWidth`, `MinHeight`, `EscCloses` and `Modal`), `CreatePanel`, `CreateCard`, `CreateToolBar`, `CreateStatusBar`, `CreateToolSeparator`, `CreateSplitter` |
| Inputs | `CreateFieldRow`, a label column and a framed edit or combo box, built on `CreateEdit` and `CreateCombo`. `CreateMemo` for the detail card and the memo fallback |
| Buttons | `CreateToolButton` for every toolbar button, built on `CreateButton` and `CreateGlyph` |
| Menus and prompts | `CreatePopupMenu`, and `AskText`, the export prompt when there is no save dialog, built on `CreateLabel` and `CreateButtonBar` |
| The combo boxes | `Settle`, on the frame tick |

The file also keeps two members the console does not build with today:

- `CreateCheck`, which a field row of the check kind uses
- `CreateFlowBar`

More detail on some of these:

- **`CreateCard`** can carry a title and a counter in its header strip. The counter is cut to fit
  the room the title leaves. The detail card uses both, and the log card has neither.
- **`CreateToolButton`** with no caption is 30 wide and 28 high, with the glyph centred. It adds
  its shortcut to the tooltip, and it centres itself vertically in its bar.
- **`Luma`** weights the low byte as red (see section 13). Until 1.1.0 it put the red weight on
  the blue byte, which made a soft red read as dark. `Luma` still decides which way `Shade` and
  `Contrast` move a colour and whether a palette counts as dark, but it no longer decides whether
  text reads. `Readable` does, by the contrast ratio.
- **ERROR** is lighter than its artwork red in every shipped palette. The 4.5:1 rule on the plain
  and striped rows moves it, and the `Luma` fix alone would have left it at the artwork red.
  Measured from `LevelColors`:

  | Palette | ERROR | Plain row | Stripe |
  |---|---|---|---|
  | Bundled, Bearded-Arc | `#eb2e42` | 4.89:1 | 4.50:1 |
  | Dark-Aqua | `#ef3244` | 4.95:1 | 4.53:1 |
  | Dark-Cotton-Candy | `#f43948` | 4.99:1 | 4.50:1 |
  | Dark-Dark-Hell | `#eb2d41` | 4.90:1 | 4.51:1 |
  | Dark-Forest | `#ef3345` | 4.94:1 | 4.50:1 |
  | Dark-Hacker | `#e92b3f` | 4.88:1 | 4.52:1 |
  | Dark-Purple | `#ef3344` | 4.96:1 | 4.51:1 |

  In 1.0.0, ERROR was `#de3756`, and `#e45b74` under Dark-Cotton-Candy. The stripe is the tone
  that decides, and the other six levels already reach 4.5:1 on both tones, so they keep their
  artwork colours in every shipped palette.

  Against 1.0.0 the change goes two ways.

  - **Every palette but Dark-Cotton-Candy.** ERROR is lighter than it was. `#de3756` has a
    relative luminance of 0.189, and the new reds 0.194 to 0.211. `#de3756` read at 4.53:1 to
    4.79:1 on the plain row and fell short of 4.5:1 on the stripe.
  - **Dark-Cotton-Candy.** ERROR is darker than it was, and has less contrast. `#e45b74` has a
    relative luminance of 0.252 and read at 5.46:1 on the plain row. `#f43948` has 0.226 and reads
    at 4.99:1. The old rule compared luma against the input colour only, and on this palette's
    background one 18 percent step of white did not reach seventy, so it took a second step. That
    went further than reading needs. `Readable` stops at the nearest lightness that reaches 4.5:1
    on both tones, which is darker than `#e45b74`.

**The combo boxes are owner drawn** (`csOwnerDrawFixed`), so the closed box and the dropped list
both use the input colours:

- Windows still paints the arrow button and a three pixel rim, and a field row clips the rim away.
- Cheat Engine's dark mode gives the control a black brush on its first paint, and a box with
  nothing picked shows only that brush. `Theme:Settle` fixes that once the box has been painted,
  by writing a neighbouring colour and then the input colour. In the console, the frame timer runs
  `Settle`. Without a frame timer, the refresh tick runs it.
- A Cheat Engine without the draw event keeps native drop-down lists.

The Template Loader's and Table Files' copies pick the palette up when a window opens and leave it
there. That suits a window that is opened, looked at and closed. This copy follows a theme change
live, as the Address List's does, because the console stays open while the table is worked on.

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
* Colours are Windows COLORREF values, stored `0x00BBGGRR`, so the low byte is red and the high
  byte is blue. People call that BGR because of the byte order, and then reach for the low byte
  expecting blue. The JSON themes store `#RRGGBB`, and `Manifold.UI` swaps the two outer bytes on
  load. `Theme.Split` returns red first, and `Theme.Luma` weights the low byte as red.
* `alTop` and `alLeft` put the **last** created control outermost, and `alBottom` and `alRight`
  put the **first** one outermost. A window built hidden is laid out in one pass with every
  sibling at zero, so the build order decides the tie. A hidden control keeps its old bounds, and
  an `alBottom` stack sorts by the far edge.
* A combo box with `csOwnerDrawFixed` asks for every item, the closed box included. Cheat Engine
  7.5 registers `TDrawItemEvent`, so a Lua `OnDrawItem` can paint it. The LCL never passes item
  minus one, so a box with nothing picked shows only its brush, which Cheat Engine's dark mode
  makes black on the first paint.
* Setting an edit's `Text` in code fires `OnChange`. Setting a combo box's `ItemIndex` fires
  nothing. The console mutes its own search handler while it empties the field, and refreshes by
  hand after it resets the two boxes.
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
| `createForm` | The console stays closed, and a warning on `Logger/Internal` says why |
| A modules folder copied in part | The build can fail. It then frees what it made and says so on `Logger/Internal` |
| `createPopupMenu` | No context menu; the toolbar and keys still work |
| `PopUp` | The Menu button says so on the status line and in the log; right-click still opens the menu |
| `getMousePos` | The Menu button opens the menu near the window's top left corner |
| `TDrawItemEvent` | The level and channel boxes stay native drop-down lists, whose face ignores the palette |
| `createSaveDialog` | Export asks for a path through a themed prompt instead |
| `createTimer` | No live refresh and no frame timer. A click, a key or a wheel notch only marks the view, and F5 or any command that reads the log again paints it |
| The frame timer, after five failures | It stops, and the refresh tick paints and settles instead |
| `lfs` | File logging disables itself. The status line says `file off`, and the Session Report says why |
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
| `-Theme` | The palette, the colour algebra, readable colours and the control factory. The Address List's theme plus the level hues and the contrast ratio correction |
| `-View` | The canvas: geometry, incremental rows, painting, scrolling, selection, hit-testing, legible colours, row hints |
| `-Console` | The window: layout and least size, toolbar, filters, detail card, status line, menu, keys, refresh and frame timers |
| `-Bridge` | The taps onto other producers |
| `-Version` | The single source of the version number |

`Core`, `Format` and `File` touch nothing outside plain Lua, and every geometric decision in the
view lives in `View.Layout` as free functions over plain tables. That is not tidiness for its own
sake: it is what lets the row builder, the scroll clamp and the scrollbar thumb be tested without
Cheat Engine, and those three are where the bugs in a list like this live.

---

## 16. Tests

`Manifold-Logger-Tests/` holds a Cheat Engine stub, a runner and one test file per part of the
segment. `.gitignore` keeps the folder out of the repository, so it exists only on the
development machine.

```
lua Run.lua <projectDir> <scratchDir> [filter] [verbose]
```

The development machine has no `lua.exe`, so the suite is driven through Python `lupa` on a Lua
5.3 runtime. That runtime loads `Run.lua` and calls it with the project folder and a scratch
folder. The runner returns the number of failures, and its last line is the summary. The suite
has 2858 checks.

`Run.lua` runs these files, in this order:

1. `Test-Format`
2. `Test-Core`
3. `Test-File`
4. `Test-View`
5. `Test-Icons`
6. `Test-Theme`
7. `Test-Bridge`
8. `Test-Console`
9. `Test-Layout`

Each file returns `function(T, Stub, ctx)`, the shape the Address List suite uses. Before a file
runs, the runner drops the Logger modules from `package.loaded` and makes a fresh stub, so nothing
one file built can reach the next. The optional filter picks files by name, so `View` runs
`Test-View` alone.

What each part covers:

- **The record model, the formatters and the rotating writer.** The writer is tested against the
  real file system.
- **The icon loader,** against the real PNGs.
- **The bridges.** The framework hook is lossless and leaves nothing behind when it detaches. The
  watch reacts to a table appearing, being replaced, having its hook stolen and going away.
- **The view.**
  - An arrival appends rows instead of rebuilding them. The row array's identity is the assertion.
  - A ring that wrapped trims the front off both lists and moves the scroll position with it.
  - A frame that raises is reported once, not once per row.
  - The search highlight is the brush of the `textOut` that draws a hit.
  - A badge row's message ends in dots before the badge.
  - The empty state is two centred lines on the background brush.
  - A list that fits has no scrollbar strip, and a click at its right edge selects a row.
  - `Legible` lifts ERROR and the muted colour to 4.5:1 on a selection.
  - Under the bundled palette, four dark ones and a light one, every text on a plain or striped
    row reads at 4.5:1, and so does every hit on the highlight.
  - `OnHint` carries a cut row's whole text, and nil once the pointer leaves.
  - A mouse move records no canvas operation. It only marks the view dirty.
  - The detail record is the one the last click landed on, Shift and Ctrl clicks included, and a
    rebuild or records leaving the front keep it on its record.
- **The theme.**
  - The colour algebra reads red from the low byte, so a soft red reads brighter than a soft
    blue.
  - `Readable` measures by the contrast ratio, moves only the lightness and keeps the hue.
  - ERROR is `#eb2e42` on the bundled palette and every other level keeps its artwork colour.
  - The level hues stay readable under a light palette.
  - Under every shipped theme file, every level reads at 4.5:1 on the plain and striped rows, and
    the muted colour reads on the canvas, its stripe, the panel and the form.
  - `Surface` derives every key the canvases read.
  - A card counter, a field row, an icon-only tool button and an owner-drawn combo box each lay
    out and paint the way the console needs.
  - `Settle` takes a box off Cheat Engine's black brush.
- **The console, end to end.**
  - The toolbar reads Pause to Detail, and each tooltip names its button and its shortcut.
  - The filters, and the order in which Escape clears things.
  - The detail card follows the selection and names the record in its counter. After a Shift
    click through the mouse handlers it shows the record the click landed on, and after a Ctrl
    click takes that record out it shows the one still selected. A repeat of the record shown
    reaches the card on the next tick, and a repeat of another record leaves the card alone.
  - Showing or hiding the detail card keeps the selected record on screen.
  - The status line shows a flash, then a row's hint, then the counts. While paused, `PAUSED`
    stays in front of all three.
  - The empty log view says why it is empty.
  - The frame timer paints, settles, and stops itself when it keeps failing.
  - `Destroy` stops both timers first.
  - A console that cannot be built frees what it made and says so.
  - A new window is restyled once it is on screen.
  - The Menu button, with and without `PopUp`.
  - The memo fallback.
- **The layout.** First, `Stub.Layout` is pinned to the LCL rules with small hand-built forms. Then
  the real console is laid out at its own least size and at the size it opens at. At both sizes
  the tests check that:
  - the toolbar reads left to right
  - the search field sits between Detail and the Menu button and shows its whole placeholder
  - the filter row sits under the toolbar
  - the status line is at the bottom
  - nothing overlaps and nothing is cut
  - the least size equals the form's constraints. That is 484 by 344 under the stub's font
    metrics, which make a line 14 px high where GDI's Consolas makes it 15.

  The detail card is shown, dragged, and shown again after the window shrank while it was hidden.
  Each time it stays between the log card and the status line.

The stub records every drawing call. That is how a test can check:

- that a row was painted
- that the icon composite was blitted exactly once from the cache
- that the scrollbar thumb landed where the geometry says

Its layout engine is the Address List stub's, which follows Lazarus 2.2's `wincontrol.inc`.
`Stub.Layout` places every control the way the LCL would, and `Stub.Overlaps` and `Stub.Clipped`
report what collides or does not fit.

The stub reproduces the traps rather than smoothing them over. Its `imagelist.add` returns the
pre-insert count when it refuses a graphic, exactly as the real one does, which is what proves the
loader watches `Count` instead of trusting the return value. A combo box gets dark mode's black
brush on its first paint, as it does in Cheat Engine.

### 16.1 The render harness

`Manifold-Logger-Tests/Render/` draws the whole console window offline, without Cheat Engine:

```
python window.py --outline --sheet
```

`window.lua` runs the real `Manifold-Logger.lua` on the stub, logs a table session into several
channels, opens the console and lays it out with `Stub.Layout`. `window.py` then paints the
control tree and replays every canvas under GDI's rules. Text is measured by GDI against the real
Consolas. The pictures and a `report.json` land in `out/`.

- **Sizes.** Each scenario is drawn at the size the console opens at and at the least size the
  window works out for itself.
- **Palettes.** The bundled one and Dark-Aqua by default. `--theme` picks any Manifold theme file
  by its short name.
- **Findings.** Each picture lists four kinds:
  - `layout`, which is `Stub.Overlaps` and `Stub.Clipped`
  - `brush`, a `textOut` whose opaque cell wiped out something under it
  - `contrast`, text below 4.5:1
  - `native`, a part Windows draws in its own colours
- **`--outline`** also writes a copy of each picture with every control a `layout` finding names
  framed in red and every cell a `brush` finding counts framed in orange. `contrast` and `native`
  findings are only listed, never framed.
- **The driver.** A scenario finds a toolbar button by the key the console keeps it under, since
  the buttons have no caption. It moves the pointer the way the LCL tracks it: the control the
  pointer leaves gets `OnMouseLeave` before the control it reaches gets `OnMouseEnter`. So once
  the pointer is on a button, the log view has dropped its hovered row and the status line has
  dropped that row's hint. A step the console no longer offers prints a `driver` line, and the
  window is drawn without that step.
- **More.** `Render/README.md` lists the scenarios and the other options.
