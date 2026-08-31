# Manifold Logger

`Manifold-Logger.lua` is an autorun extension for Cheat Engine that gives every script on the
machine one place to log to, and one window to read it in.

Cheat Engine has the Lua Engine window. It is a plain memo: one colour, no levels, no filter, no
search, nothing kept once it scrolls past, and everything from every script mixed into one stream.
This replaces all of that, and it does it without asking anybody to depend on it.

## Highlights

**The log view is drawn on a canvas**, not delegated to a memo or a list view. That is what buys
the 16x16 level icon in the gutter, the level's own colour on the tag and the message, zebra
striping, an in-place search highlight, a repeat badge, a pin marker and a scrollbar in the
theme's colours rather than the system's. It is virtual, so five thousand records scroll exactly
as fast as fifty.

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

| Control | Effect |
|---|---|
| Pause | Stops repainting. Records keep arriving and appear on resume |
| Follow | Keeps the newest record in view. Scrolling up turns it off, reaching the end turns it back on |
| Wrap | Wraps long lines instead of cutting them |
| Copy | Copies the selection, or everything shown when nothing is selected |
| Export | Writes what is shown to a file. The extension picks the format |
| Clear | Empties the buffer. The counters and the log file are untouched |
| Detail | Shows the focused record in full, fields, traceback and JSON |
| Menu | Everything else. Right-click anywhere in the log for the same menu |
| Level | Hides everything below a level. The records are kept either way |
| Channel | One producer only. Sub-channels of the choice are included |
| Search | Filters and highlights, plain text, case-insensitive |

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
| Esc | Clear the selection, or empty the search box while it has focus |
| Double-click | Open the detail pane on that record |

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
palette when it is not. The per-level hues are sampled from the icon artwork and then
contrast-corrected against whatever background the active palette actually uses, so every level
stays readable under a theme the Logger has never seen.

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
panel, so it is pushed away from the background until it is legible - the same treatment the
per-level hues get.

## Degrading

Nothing here is required for the rest to work.

| Missing | Result |
|---|---|
| The icon set | Rows draw a filled square in the level's colour instead of the glyph |
| `createPaintBox` | The view falls back to `createImage`, which is equally double-buffered |
| Both of them | The window falls back to a themed memo. No colour, no icons, still a log |
| A writable `%LOCALAPPDATA%` | File logging disables itself and says why in the status bar |
| `getMousePos` or a `PopUp` binding | The Menu button says so once; right-click still opens the menu |
| The window, entirely | Logging keeps working. The console is optional by design |

## License

MIT. See `LICENSE` in the repository root.
