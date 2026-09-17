# Manifold Logger

`Manifold-Logger.lua` is an autorun extension for Cheat Engine that gives every script on the
machine one place to log to, and one window to read it in.

Cheat Engine has the Lua Engine window. It is a plain memo: one colour, no levels, no filter, no
search, nothing kept once it scrolls past, and everything from every script mixed into one stream.
This replaces all of that, and it does it without asking anybody to depend on it.

![Preview](https://i.imgur.com/Ss7k57r.png)

## Highlights

**The log view is drawn on a canvas**, not delegated to a memo or a list view. That is what buys
the 16x16 level icon in the gutter, the level's own colour on the tag, and on the message of a
success, a warning or anything worse, zebra striping, an in-place search highlight, a repeat
badge, a pin marker and a scrollbar in the theme's colours rather than the system's. It is
virtual, so five thousand records scroll exactly as fast as fifty.

**Channels, not prefixes.** Any script takes a channel of its own and logs into it. The console
filters by producer without anybody having to agree on a message prefix first.

```lua
local log = ManifoldLogger and ManifoldLogger:Channel("MyTool")
if log then log:Info("ready", { build = 3 }) end
```

That is nil-safe, needs no `require`, no path and no load order, and costs nothing when the
Logger is not installed. Sub-channels (`log:Sub("Scanner")`) nest, and filtering by the parent
includes the children.

**A record is data, not a line of text.** It carries a level, a channel, a millisecond timestamp,
an optional structured field table and its repeat count. Text is derived from it, which is why
the same record can be a coloured row on the canvas, a line in the log file, a JSON object in an
export and a CSV cell without any of them being the "real" one.

**Nothing is lost to a filter.** Records below the display level are kept and marked, so the level
can be turned down *after* the interesting thing already happened.

**Flood control that stays visible.** A message repeated identically collapses into one record
with a `x42` badge. A burst of different messages from one channel is bounded by a token bucket,
and the next record through says how many were dropped. Neither is silent.

**It notices your Cheat Table.** Open a table that loads the Manifold framework module set and the
console starts mirroring its log by itself, on a `Framework` channel, with no change to the table
and no dependency in either direction. It hooks the framework logger's own dispatch funnel, so the
mirror sees the level, the raw message and the forced flag rather than a line it has to parse -
and it sees them *before* the table's own level filter, so turning the console's level down shows
what the table decided not to print. Close the table, open another, reload it: the watch notices
and re-attaches. The Template Loader's log and plain `print` can be tapped the same way.

Every bridge is idempotent, reversible and non-owning: the producer keeps working when the console
is closed, destroyed, or was never installed.

**A log file that rotates.** Everything is written to
`%LOCALAPPDATA%\Manifold\Logs\Manifold.Console.log`, as text or as JSON lines, rotated at 2 MB
with three generations kept. `WARNING` and above are flushed to disk immediately; the rest ride the
C runtime's buffer, because a flush per line is a syscall per line and the lines that matter after
a crash are the loud ones.

## Installation

Place `Manifold-Logger.lua` **and** the `Manifold-Logger-Modules` folder next to each other in the
autorun folder, which is usually `C:\Program Files\Cheat Engine 7.5\autorun`. On a portable build,
or if Cheat Engine was installed elsewhere, the folder will be somewhere else.

To find it, run this in the Cheat Engine Lua console:

```lua
return getAutorunPath()
```

When updating, replace `Manifold-Logger.lua` **and the whole** `Manifold-Logger-Modules` folder
together. Then restart Cheat Engine, or run `ManifoldLogger:Shutdown()` and execute
`Manifold-Logger.lua` again. A console that meets the theme of another release may not build its
window. In that case the window stays closed, and a record on `Logger/Internal` says why.

The layout in the autorun folder has to be:

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
      Manifold-*.png
```

## Opening it

A **[— Manifold Logger —]** entry is added to Cheat Engine's main menu. From the Lua console or a table script:

```lua
ManifoldLogger:Open()
```

To leave the menu bar alone and open it from somewhere else instead:

```lua
ManifoldLogger:Configure({ InstallMenu = false })
```

## The window

From top to bottom, the window has:

- a toolbar with seven icon buttons in three groups, the search field and the menu button
- a filter row with the level box, the channel box and a button that clears all filters
- the log
- the detail card, when it is open, under a splitter
- the status line

The window opens at 980 by 620. Its smallest size is worked out from its parts. The width is what
the toolbar or the filter row needs, whichever is wider, so the search field always has room to
show its placeholder in full. The height holds the two bars, the status line, four log rows and
three lines of the detail card, so opening the card never squeezes the log. With Consolas on a
96 dpi display, that comes to 484 by 351.

The toolbar buttons have no captions. Hover over a button and its tooltip gives its name and, if it
has one, its shortcut. Pause, Follow, Wrap and Detail are toggles, and a filled button is on.

| Control | Effect |
|---|---|
| Pause | Holds new records out of the view. They are still recorded, and they appear on resume or with any command that reads the log again, such as F5, a filter change, pinning or Clear (Ctrl+P) |
| Follow | Keeps the newest record in view. Scrolling up turns it off, reaching the end turns it back on (End) |
| Wrap | Wraps long lines instead of cutting them. The menu's Wrap Long Lines is the same switch and stays in step |
| Copy | Copies the selection, or everything shown when nothing is selected (Ctrl+C) |
| Export | Writes the selection, or everything shown, to a file. The extension picks the format |
| Clear | Empties the buffer. The counters and the log file are untouched |
| Detail | Opens or closes the detail card for the selected record |
| Search | Filters and highlights, plain text, any case (Ctrl+F) |
| Menu | Everything else. Right-click anywhere in the log for the same menu |
| Level | Hides everything below a level. The records are kept either way |
| Channel | One producer only. Sub-channels of the choice are included |
| Clear filters | Resets the level, the channel and the search, so everything shows again |

**The detail card** shows the selected record in full: its fields, its traceback and its JSON
form. It follows the selection, not the mouse, so it stays put while records scroll past under the
pointer. With several records selected, it shows the one you clicked last, Shift and Ctrl clicks
included, as long as that one is still selected, and otherwise the first selected record. Its title
strip identifies the record at a glance with the level tag, the channel, the time and the repeat
count. When the record repeats, the count and the card catch up within a moment. While the log is
paused they catch up on resume, or on any command that reads the log again. Drag the splitter to resize the card. The log always keeps room for at least
four rows.

**The status line** shows the counts on the left. After an action, a message such as
`3 records copied` replaces the counts for two and a half seconds. Hovering over a row puts its
full text on the left side if the row was cut short, or explains its badge or pin. While the log is
paused, `PAUSED` leads the left side, in front of the counts, a message or a row's text alike. The
right side counts the critical, error and warning records and shows the size of the log file, or
`file off` when file logging stopped. Those counts cover the whole session, so Clear leaves them as
they are. If a side has to be shortened to fit, its tooltip holds the full text.

**Selected and hovered rows** get lighter or darker text if their normal colour would be hard to
read on the row's highlight, so an error on the selection stays readable. A search hit is a band in
the accent tone behind the matched text. Only the message column gets bands, so a record the search
found by its channel shows none. Inside a band the text is recoloured until it reads on the band, so
a level colour can turn white or black there.

**An empty log** says why it is empty: the buffer holds nothing, because nothing has been logged
yet or Clear emptied it, or the filter hides every record.

| Key | Effect |
|---|---|
| Up / Down | Scroll one row |
| PgUp / PgDn | Scroll one page |
| Home | Jump to the oldest record |
| End | Jump to the newest and follow again |
| Ctrl+A | Select everything shown |
| Ctrl+C | Copy the selection |
| Ctrl+F | Focus the search box |
| Ctrl+P / Pause | Pause and resume |
| Ctrl + / Ctrl - | Larger and smaller text |
| F5 | Refresh |
| F1 | About |
| Esc | Empty the search, then clear the selection, then hide the window |
| Double-click | Open the detail card on that record |

Ctrl+F and Esc also work while you type in the search box. The other keys go to the box while it
has focus, so Ctrl+A there selects the text you typed.

When there is no search text and nothing is selected, Esc hides the window. Nothing else stops: the
log, the buffer and the log file carry on, and the window comes back as you left it. The one
exception is an empty search box with the keyboard focus, where Esc stays with the box and the
window stays open.

## Logging into it

Seven levels, in rank order: `Trace`, `Debug`, `Info`, `Success`, `Warning`, `Error`, `Critical`.
`Success` deliberately shares `Info`'s band. It is not a severity, it is an `Info` that went well,
so a view filtered to `Info` shows it and one filtered to `Warning` does not.

Every level has four shapes:

```lua
log:Warning("disk is nearly full")            -- plain, with optional fields
log:WarningF("%d of %d slots used", 98, 100)  -- string.format at the call site
log:ForceWarning("...")                       -- bypasses the level filter
log:ForceWarningF("...", x)
```

Beyond the levels:

```lua
-- One record with aligned rows instead of six prefixed lines.
log:Info(ManifoldLogger:Block("Injection report", {
    { "Address", "game.exe+1A2B3C" },
    { "Bytes",   "48 8B 05" },
    { "Detour",  "installed" },
}))

-- A named event. The fields survive as fields into the JSON-lines export.
log:Event("trampoline.install", { name = "Health", overwrite = 7 })

-- A timed section. Opens quietly, closes with the elapsed milliseconds.
local scope = log:Scope("AOB scan")
scope:Step("module resolved")
scope:Done("4 results")            -- or scope:Fail(err)

-- pcall that logs the failure with the traceback attached to the record.
local ok = log:Catch(function() risky() end, "risky")

-- Logs and returns the condition, so the guard is one line.
if not log:Check(address, "no address") then return end
```

## Bridging code that logs somewhere else

```lua
-- The Cheat Table framework's logger (the global `logger`). Attached
-- automatically, and re-attached whenever a table is opened, reloaded or
-- closed - autorun runs long before any table exists, so a one-shot attach
-- would attach to nothing.
ManifoldLogger.Bridge:AttachFramework()
ManifoldLogger:Configure({ WatchTable = false })   -- to stop watching

-- The Manifold Template Loader. Also automatic.
ManifoldLogger.Bridge:AttachTemplateLoader()

-- Everything anything prints. Off by default; also a menu entry.
ManifoldLogger.Bridge:AttachPrint()

-- The other direction: mirror this log into the Lua Engine window.
ManifoldLogger:Configure({ PrintSink = true })

ManifoldLogger.Bridge:DetachAll()
```

The framework bridge shadows `logger._DispatchLog` on the instance, which is lossless and reverses
with a single `rawset`; it falls back to wrapping `SetOutput` and parsing the formatted line when a
framework version turns up without that funnel. The Template Loader bridge parses, because its log
only offers a formatted line. A channel is the front door and a bridge is the fallback: new code
should take a channel.

## Configuration

```lua
ManifoldLogger:Configure({
    Level         = "INFO",   -- what reaches the console, the file and the sinks
    Capacity      = 5000,     -- records kept in the ring
    FileLogging   = true,
    FileMode      = "text",   -- or "jsonl"
    FileLevel     = "TRACE",  -- the file is the archive; keep everything
    PrintSink     = false,    -- mirror into the Lua Engine window
    InstallMenu   = true,
    WatchTable    = true,     -- notice a Cheat Table's logger coming and going
    WatchInterval = 750,      -- ms between polls
    Dedup         = true,     -- collapse an immediately repeated message
    Throttle      = true,     -- bound a burst of different messages per channel
    ThrottleBurst = 200,
    ThrottleRate  = 100,      -- refill per second
})
```

`ManifoldLogger:Status()` reports the version, the level, the buffer, the channels, the attached
bridges, the state of the log file and whether the icon set loaded.

## Sinks

A sink is anything that consumes records: the console, the log file, `print`, or a function of
your own. A sink with a `Level` of its own follows that level, so the file archives `TRACE` while
the console shows `INFO`, without a second logger. A sink without one follows the log, so turning
the log down quietens everything together. The capture level is still the hard floor: a record
below it is never created, so no sink can see it.

```lua
ManifoldLogger.Log:AddSink("mine", {
    Level = "ERROR",
    Channels = { MyTool = true },      -- optional
    Write = function(sink, record)
        -- record.Level, record.Channel, record.Message, record.Fields, ...
    end,
})
```

A sink that raises three times is disabled and keeps its reason, rather than being retried on
every line for the rest of the session.

## Theme

The window carries its own copy of the Manifold design language, so it follows the Cheat Table's
active theme when a `Manifold.Forms` instance is loaded and falls back to the bundled Bearded-Arc
palette when it is not. The per-level hues are sampled from the icon artwork. A hue that does not
reach a 4.5 to 1 contrast ratio on the active palette's plain and striped rows is made lighter or
darker until it does, keeping its hue, so every level stays readable under a theme the Logger has
never seen. On a mid grey background from `#707070` to `#747474`, no colour at all reaches 4.5 to
1 on both rows. There a level takes the lightness that comes closest, which reads at 4.37 to 1 or
better.

**It follows a theme change while the window is open**, chrome included. That matters because this
window is meant to stay open while a table is being worked on, which is exactly when its theme gets
switched: a console that coloured itself once would end up half in the table's theme (the canvas,
which re-reads when it paints) and half in the bundled one (every panel, button, label and box,
which would not). Every control the theme colours is registered with the closure that colours it,
and the console re-runs them when it notices `forms.ActiveDesignTheme` has been replaced. The
composited level icons are dropped with it, because each one was baked against a row background
that no longer exists. It follows a theme change while paused, too - pausing stops the log from
moving, not the window from being the right colour.

One colour is corrected rather than adopted: the framework's muted colour is its address-list
group-header colour, picked to read against Cheat Engine's list rather than against this console's
panel, so it gets the same treatment as the per-level hues. It has to reach 4.5 to 1 on the log,
its stripe, the panels and the window background.

## Degrading

Nothing here is required for the rest to work.

| Missing | Result |
|---|---|
| The icon set | Rows draw a filled square in the level's colour instead of the glyph |
| `createPaintBox` | The view falls back to `createImage`, which is equally double-buffered |
| Both of them | The window falls back to a themed memo. No colour, no icons, still a log |
| A writable `%LOCALAPPDATA%` | File logging disables itself. The status line says `file off`, and the Diagnostics menu's Session Report says why |
| `getMousePos` | The Menu button opens the menu near the window's top left corner instead of at the pointer |
| A `PopUp` binding | The Menu button says so on the status line and in the log. Right-click still opens the menu |
| The combo box draw event, `OnDrawItem` | The level and channel boxes stay native drop-down lists, which do not take the theme colours |
| `createTimer` | No live refresh. F5, and any command that reads the log again, repaint the view |
| The window, entirely | Logging keeps working. The console is optional by design |

## Changelog

### 1.1.0

- The window now uses the Address List's layout:
  - The toolbar has icon-only buttons, with the search field in a framed box beside them.
  - The level and channel boxes in the filter row are drawn in the theme's input colours.
  - A new button at the end of the filter row clears all filters.
  - The status line shortens both of its halves to fit.
- **ERROR rows get a new red.** Level colours are now corrected by their real contrast ratio.
  Each one has to reach 4.5 to 1 on both the plain and the striped rows. The icon's own red,
  `#d70b31`, reaches only 3.89 to 1 on the bundled background and 3.58 on its stripe, so it is
  lightened. Only the lightness changes, so it stays red.
- 1.0.0 corrected it by a distance in brightness instead. It mixed in white until the red stood
  70 apart from the background, and it measured that brightness with the red weight on the blue
  byte, so a soft red read as darker than it is. That weight is fixed too. With the right weight
  the icon's red already stands more than 70 apart, so the old rule alone would now leave it as it
  is.
- ERROR was `#de3756` in 1.0.0, and `#e45b74` under Dark-Cotton-Candy. It is now:
  - `#eb2e42` under the bundled palette and Bearded-Arc
  - `#ef3244` under Dark-Aqua
  - `#f43948` under Dark-Cotton-Candy
  - `#eb2d41` under Dark-Dark-Hell
  - `#ef3345` under Dark-Forest
  - `#e92b3f` under Dark-Hacker
  - `#ef3344` under Dark-Purple
- Under every palette but Dark-Cotton-Candy, ERROR is lighter than it was. `#de3756` fell short of
  4.5 to 1 on the stripe there.
- **Under Dark-Cotton-Candy, ERROR is darker than it was, and has less contrast.** The old rule
  took two steps of white there instead of one, which went further than reading needs.
  `#e45b74` read at 5.46 to 1 on the plain row. The new rule stops at the nearest lightness that
  reads, so `#f43948` reads at 4.99 to 1 on the plain row and 4.50 on the stripe.
- The other levels already reach 4.5 to 1 and keep their icon colours.
- Muted text, such as timestamps, channel names and the status line, is corrected the same way. It
  has to reach 4.5 to 1 on the log, its stripe, the panels and the window background. That makes
  it lighter under Dark-Aqua and Dark-Dark-Hell.
- Selected and hovered rows adjust any text colour that would be hard to read on them.
- Search hits stay visible behind the matched text, and the matched text takes a colour that reads
  on the highlight. Before, the text drew over its own highlight.
- A row with a repeat badge ends in dots before the badge, instead of losing its end under it.
- An empty log says whether the buffer is empty or the filter hides everything.
- The scrollbar only takes space when the log actually scrolls.
- Hovering over a row that was cut short, or that has a badge or a pin, explains it on the status line.
- A message on the status line stays for two and a half seconds, even while records arrive.
- The detail card follows the selection instead of the row under the mouse, and shows the record
  you clicked last. Its title strip names the record, and a repeat of that record reaches the
  card.
- A detail card opened after the window was made smaller stays above the status line.
- Esc empties the search, then clears the selection, then hides the window.
- Wrap on the toolbar and Wrap Long Lines in the menu now stay in step.
- Painting happens on a 15 ms frame timer. A mouse move or a click only asks for a new frame.
- The smallest window size is worked out from the controls instead of being fixed at 520 by 320.
  It counts the height the log and the detail card need as well as the width of the bars.
- Layout fixes:
  - The filter row now sits under the toolbar instead of above it.
  - The toolbar reads left to right.
  - Buttons no longer overlap in a narrow window.
- If the window cannot be built, the Logger removes the parts it made and writes a record to
  `Logger/Internal`. It no longer leaves a half-built window behind.

### 1.0.0

- First release.

## License

MIT. See `LICENSE` in the repository root.
