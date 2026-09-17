--[[
    Theming and layout for the Logger console.

    Self contained. Loading Manifold.Forms here would define the global Forms
    class a second time from autorun, the collision Manifold.Bootstrap exists
    to detect. This copies its visual language and reads its palette, never
    more than that.

    The palette source is the ActiveDesignTheme of a live Manifold.Forms
    instance, and the bundled Bearded-Arc values when there is none.

    The palette is live. The console stays open while a Cheat Table is worked
    on, which is exactly when its theme gets changed. Every control this module
    colours is registered together with the closure that colours it, and
    Restyle runs them again. A Create function must therefore never capture the
    palette in its closures, it reads it inside them.

    A change is detected by identity. The ApplyTheme of Manifold.Forms assigns
    a fresh table from ResolveTheme on every application, so comparing the
    reference costs nothing on the console's refresh tick.

    Short lived dialogs mark the registry before they build and truncate it
    back afterwards, because their controls are freed when the modal returns
    and a closure must never outlive the control it colours. AskText is the
    only modal here. It builds its own form rather than asking CreateWindow
    for one, so the prompt keeps Cheat Engine as its owner while the console
    window CreateWindow builds is detached.

    This file is the Address List theme with three changes. The parts the
    console has no use for are left out, which are the code views, the tab
    strip, the colour swatch, the empty state panel, the native check box
    styling and the two choice dialogs. The level hues are added, with
    LevelColors, because only the log view paints with them. And text
    colours are made readable by the contrast ratio WCAG measures rather
    than by a distance in luma, through Luminance, Ratio and Readable. That
    is why GetPalette corrects the muted colour its own way, and why the
    stripe step has a name, STRIPE_STEP, so Surface, LevelColors and
    GetPalette all mean the same stripe. Everything else the two files share
    is kept word for word, except this header and the comment on Surface,
    which describes the log view. So a diff of the two shows those three
    changes, this header and that comment, and nothing else. The other
    comments in the shared part still take their examples from the Address
    List window.

    Cheat Engine and Lazarus facts this file relies on.
      * Native TButton ignores Color on Win32. Buttons are panels with a
        centred label, and the label covers the panel, so hover handlers go on
        both.
      * TMemo and TEdit inherit clWindow and are painted through WM_CTLCOLOR,
        so ParentColor must be off and Color set explicitly.
      * TPicture.LoadFromFile picks the format by the file's extension, which
        TGraphic.LoadFromFile does not, so an image control takes a PNG path
        straight away. An image list cannot take a file name at all, which is
        why the menus get their icons through Manifold-Logger-Icons.
      * TCheckBox only takes its caption font colour. The glyph is drawn by the
        system, which is why CreateCheck draws its own box out of panels.
      * alTop and alLeft put the LAST created control outermost. alBottom and
        alRight put the FIRST created one outermost. Every stack built here
        creates in the order that reading order needs, and says so.
      * A Lua OnClose must return caFree, caHide or caNone. Returning nothing
        is caNone and the window will not close, so nothing here assigns one.
      * Setting an edit's Text in code fires OnChange, so OnChange is assigned
        after the initial text. Setting a combo box's ItemIndex fires nothing.
      * A colour is a Windows COLORREF stored 0x00BBGGRR, so the low byte is
        red and the high byte is blue. The JSON themes store hash RRGGBB and
        Manifold.UI swaps the two outer bytes on load, so the constants below
        carry both spellings and the algebra splits red first.
      * A panel bevel is painted by the widgetset and cannot be relied on to
        take BevelColor. A border that has to be seen is a panel in the border
        colour with a second panel one pixel inside it, the way a card is
        built, and that is how the check box and the field frame are made.
      * OnResize fires whenever the size changes once the handle exists, and
        for every control when the form is first shown. Anything that fits
        itself to a width does it there, and does it again from nothing, so a
        resize that arrives twice changes nothing the second time.
      * An autosized label grows to its caption and an alRight one then runs
        over whatever sits to its left. A caption that has to stay inside a
        width is cut to that width first. Consolas is monospaced, so one
        measured character width says exactly how many characters fit.
      * A combo box draws its own items. Style csOwnerDrawFixed makes Windows
        ask for every item, the closed box included, and Cheat Engine hands
        that to a Lua OnDrawItem, so the closed box and the dropped list both
        take the input colours. Windows still paints the arrow button and a
        three pixel rim around the closed box, and the inner ring of that rim
        is the control's brush. In a field row the rim is pushed outside a
        clip panel, because a child window is always clipped to its parent. A
        Cheat Engine without the draw event keeps a native box, whose face
        Color does not reach.
      * The control's brush is also all a box with nothing picked shows,
        because the LCL never passes item minus one to the handler. Cheat
        Engine's dark mode makes that brush black on the first paint, and
        Color only reaches a brush that exists and only when the colour
        really changes. So a box is settled once it has been painted, by a
        write of a neighbouring colour and then the input colour. Somebody
        has to call Settle on a tick for that, and in the Logger that is the
        console's frame timer.
]]

local Theme = {}
Theme.__index = Theme

--- Bearded-Arc, as Cheat Engine BGR integers. The comment carries the JSON
--- form of the same colour, which is RGB.
Theme.Default = {
    COLOR_BG         = 0x0A0305, -- #05030a
    COLOR_PANEL      = 0x1A1013, -- #13101a
    COLOR_ACCENT     = 0x61CDEA, -- #eacd61
    COLOR_TEXT       = 0xFFBFFF, -- #FFBFFF
    COLOR_LABEL      = 0x61CDEA, -- #eacd61
    COLOR_BTN        = 0x1A1013, -- #13101a
    COLOR_BTN_HOVER  = 0x61CDEA, -- #eacd61
    COLOR_BTN_TEXT   = 0xFFBFFF, -- #FFBFFF
    COLOR_INPUT      = 0x0A0305, -- #05030a
    COLOR_INPUT_TEXT = 0xFF7FBF, -- #BF7FFF
    COLOR_BORDER     = 0x61CDEA, -- #eacd61
    COLOR_MUTED      = 0xE1BA8D  -- #8dbae1
}

Theme.FontName = "Consolas"
Theme.FontSize = 10

--- Severity hues for the canvases, Cheat Engine BGR. Surface contrast
--- corrects them against the background actually in use, so a hue picked
--- against the bundled dark theme still reads on a light one.
Theme.SeverityDefault = {
    Error   = 0x5C5CFF, -- #ff5c5c
    Warning = 0x3DB8FF  -- #ffb83d
}

--- Per level hues, sampled from the icon artwork so a row and its glyph are
--- the same colour. Cheat Engine BGR, and the comment carries the JSON form
--- of the same colour, which is RGB. LevelColors makes each one readable on
--- the plain and the striped rows of the log view, and a hue that already
--- reads on both is drawn exactly as the artwork has it.
Theme.LevelDefault = {
    TRACE    = 0xE1BA8D, -- #8dbae1
    DEBUG    = 0x0993FF, -- #ff9309
    INFO     = 0xDBDE08, -- #08dedb
    SUCCESS  = 0x0ACD52, -- #52cd0a
    WARNING  = 0x0CD7EE, -- #eed70c
    ERROR    = 0x310BD7, -- #d70b31
    CRITICAL = 0xFF30FF  -- #ff30ff
}

--
--- ∑ One theme per window. Icons is optional and only feeds the glyphs on
---   buttons and menu items.
--- @param services table|nil # Log and Icons.
--- @return table
--
function Theme:New(services)
    return setmetatable({
        Log = services and services.Log,
        Icons = services and services.Icons,
        Registry = {},        -- one re-apply closure per control coloured
        -- false, not nil. nil is a legitimate source, meaning no Cheat Table
        -- is loaded, so the first GetPalette has to miss the cache.
        CachedSource = false,
        Cached = nil,
        -- Character width and line height per font size, measured once each.
        Metrics = {},
        -- Every owner drawn combo box this theme made, with what is known about
        -- its brush, see Settle. And how many still wait for one.
        Combos = {},
        CombosPending = 0
    }, Theme)
end

--------------------------------------------------------
--                  The live palette                  --
--------------------------------------------------------

--
--- ∑ The Cheat Table's design theme table, or nil when no table is loaded.
---
---   The table itself is the change signal. The ApplyTheme of Manifold.Forms
---   sets ActiveDesignTheme to a fresh table from ResolveTheme on every
---   application, so a caller spots a theme change by comparing the reference
---   it saw last. No copy, no fingerprint.
--- @return table|nil
--
function Theme:Source()
    local forms = rawget(_G, "forms")
    if type(forms) ~= "table" then return nil end
    local ok, design = pcall(self.ProbeSource, forms)
    if not ok or type(design) ~= "table" or design.COLOR_BG == nil then return nil end
    return design
end

--- Hoisted so Source does not build a closure per call. Source runs on the
--- window's sync tick.
function Theme.ProbeSource(forms)
    return forms.ActiveDesignTheme
end

--
--- ∑ Registers a closure that colours one control, runs it once, and keeps it
---   so Restyle can run it again. A closure that fails on its first run is not
---   kept. It never had a control to colour.
--- @param apply function
--- @return function|nil # The closure, or nil when it did not survive its
---         first run.
--
function Theme:Track(apply)
    if type(apply) ~= "function" then return nil end
    if not pcall(apply) then return nil end
    self.Registry[#self.Registry + 1] = apply
    return apply
end

--
--- ∑ Re-colours every tracked control against the palette as it is now.
---
---   A closure that raises is dropped rather than retried for the rest of the
---   session. This does not prune freed controls. The closures built here are
---   made of safeSet and safeFont, which pcall internally and return false, so
---   a freed control never raises. Forget covers that, and the window calls it
---   when it closes. The guard is for closures a caller registered.
--- @return number # How many controls were re-coloured.
--
function Theme:Restyle()
    local registry = self.Registry
    local kept = {}
    for index = 1, #registry do
        if pcall(registry[index]) then kept[#kept + 1] = registry[index] end
    end
    self.Registry = kept
    return #kept
end

--
--- ∑ Forgets every tracked control. Called when the window is released, so no
---   closure survives pointing at a control that has been freed.
--- @return nil
--
function Theme:Forget()
    self.Registry = {}
    self.Combos = {}
    self.CombosPending = 0
end

--
--- ∑ How many closures are registered right now. Taken before a short lived
---   dialog is built, so ForgetSince can drop exactly what the dialog added.
--- @return number
--
function Theme:Mark()
    return #self.Registry
end

--
--- ∑ Drops every closure registered after a mark. A modal's controls are freed
---   when it returns, and a closure that still points at one would be re-run
---   on the next theme change for nothing.
--- @param mark number
--- @return number # How many closures were dropped.
--
function Theme:ForgetSince(mark)
    mark = tonumber(mark) or 0
    if mark < 0 then mark = 0 end
    local dropped = 0
    for index = #self.Registry, mark + 1, -1 do
        self.Registry[index] = nil
        dropped = dropped + 1
    end
    -- A combo box the dialog made is freed with it, so the settle pass must
    -- not go looking for it afterwards. Every combo box registers a closure
    -- right after its entry, so an entry made before the mark sits below it.
    local kept = {}
    for _, entry in ipairs(self.Combos) do
        if entry.Mark < mark then kept[#kept + 1] = entry end
    end
    self.Combos = kept
    self.CombosPending = 0
    for _, entry in ipairs(kept) do
        if entry.Settled == nil then self.CombosPending = self.CombosPending + 1 end
    end
    return dropped
end

--------------------------------------------------------
--                     Primitives                     --
--------------------------------------------------------

local function safeSet(control, property, value)
    if not control then return false end
    return (pcall(function() control[property] = value end))
end

--
--- Builds one LCL control through the global that makes it. A Cheat Engine
--- without that global, or a constructor that raises, gives nil, and every
--- safeSet on nil is a no op. So a missing API costs a plain looking window
--- rather than an exception during construction.
--
local function make(name, parent)
    local create = rawget(_G, name)
    if type(create) ~= "function" then return nil end
    local ok, control = pcall(create, parent)
    if not ok then return nil end
    return control
end

--
--- Frees a window from Cheat Engine's main form. createForm assigns every Lua
--- form to the main application, which makes it an owned window. Windows keeps
--- it above Cheat Engine forever, gives it no taskbar button of its own and
--- minimises it whenever Cheat Engine is minimised. pmNone drops that
--- ownership and stAlways asks for the button back.
---
--- Two conditions. Set them while the form is still hidden, because the LCL
--- reads them when the window handle is realised. And never on a modal dialog.
--- An unowned modal can fall behind the window it blocks, and that window is
--- disabled, so the table looks frozen rather than busy.
---
--- None of the three appear in celua.txt. They are published properties of the
--- LCL form, which is what the object bridge reads, so they are reachable the
--- same way every other undocumented property is.
--
local function detachFromMainForm(form)
    safeSet(form, "PopupMode", "pmNone")
    safeSet(form, "PopupParent", nil)
    safeSet(form, "ShowInTaskBar", "stAlways")
end

local function safeFont(control, color, size, style)
    pcall(function()
        local font = control.Font
        font.Name = Theme.FontName
        font.Size = size or Theme.FontSize
        if color then font.Color = color end
        if style then font.Style = style end
    end)
end

local function setSpacing(control, spacing)
    if type(spacing) ~= "table" then return end
    pcall(function()
        local borderSpacing = control.BorderSpacing
        for key, value in pairs(spacing) do borderSpacing[key] = value end
    end)
end

--- True for the two alignments that stack sideways, which is what decides
--- whether a splitter is given a Width or a Height.
local function isHorizontalAlign(align)
    return align == "alLeft" or align == "alRight"
end

--- One property read as a number, or nil when it cannot be read or is not
--- a number. A freed control raises on any read, and that is a nil here.
local function readNumber(control, property)
    if not control then return nil end
    local ok, value = pcall(function() return control[property] end)
    if not ok then return nil end
    return tonumber(value)
end

--- The caption of a control as a string, or nil when it cannot be read.
local function readText(control)
    if not control then return nil end
    local ok, value = pcall(function() return control.Caption end)
    if not ok or value == nil then return nil end
    return tostring(value)
end

--- The width a control lays its children out in. ClientWidth first, and the
--- outer width when that is missing or still zero.
local function innerWidth(control)
    local width = readNumber(control, "ClientWidth")
    if width == nil or width <= 0 then width = readNumber(control, "Width") end
    return width
end

--- The same for the height.
local function innerHeight(control)
    local height = readNumber(control, "ClientHeight")
    if height == nil or height <= 0 then height = readNumber(control, "Height") end
    return height
end

--- Whether a control is meant to be on screen. A control that cannot say is
--- taken as shown, so a layout never loses one it could not ask.
local function isShown(control)
    local ok, value = pcall(function() return control.Visible end)
    return not ok or value ~= false
end

--- The point size of a control's font, and the segment size when the font
--- cannot be read or still says zero, which is what an untouched font says.
local function fontSizeOf(control)
    local size
    pcall(function() size = tonumber(control.Font.Size) end)
    if size == nil or size <= 0 then return Theme.FontSize end
    return size
end

--- How many characters a string holds. UTF-8 aware, because a record
--- description is whatever the user typed, and a byte count for a malformed
--- string.
local function textLength(text)
    local lib = rawget(_G, "utf8")
    if type(lib) == "table" and type(lib.len) == "function" then
        local count = lib.len(text)
        if count then return count end
    end
    return #text
end

--- The first count characters of a string, never cutting a character in half.
local function textHead(text, count)
    if count <= 0 then return "" end
    local lib = rawget(_G, "utf8")
    if type(lib) == "table" and type(lib.offset) == "function" and type(lib.len) == "function"
        and lib.len(text) then
        local stop = lib.offset(text, count + 1)
        if stop then return text:sub(1, stop - 1) end
        return text
    end
    return text:sub(1, count)
end

Theme.SafeSet = safeSet
Theme.SafeFont = safeFont

--------------------------------------------------------
--                   Colour algebra                   --
--------------------------------------------------------

--
--- ∑ Splits a Cheat Engine colour into its three channels, reddest first.
---
---   A Cheat Engine colour is a Windows COLORREF and it is stored 0x00BBGGRR,
---   so the LOW byte is red and the high byte is blue. People call that BGR
---   because of the byte order, and then reach for the low byte expecting
---   blue. The proof is in Theme.Default, where every constant carries the
---   hash RRGGBB a theme file writes, and in the conversion Manifold.UI does
---   on load, which is red or green shifted eight or blue shifted sixteen.
--- @param color number
--- @return number, number, number # Red, then green, then blue.
--
function Theme.Split(color)
    color = math.floor(tonumber(color) or 0) % 0x1000000
    return color % 256, math.floor(color / 256) % 256, math.floor(color / 65536) % 256
end

--- Puts three channels back into one colour, in the order Split hands them
--- out. A channel out of range is clamped and not wrapped, so a blend that
--- overshoots ends on white rather than on a wild hue.
function Theme.Join(red, green, blue)
    local function clamp(value)
        value = math.floor(value + 0.5)
        if value < 0 then return 0 end
        if value > 255 then return 255 end
        return value
    end
    return clamp(red) + clamp(green) * 256 + clamp(blue) * 65536
end

--
--- ∑ Linear blend. An amount of 0 returns from, 1 returns to.
--- @param from number
--- @param to number
--- @param amount number
--- @return number
--
function Theme.Mix(from, to, amount)
    local fr, fg, fb = Theme.Split(from)
    local tr, tg, tb = Theme.Split(to)
    return Theme.Join(fr + (tr - fr) * amount,
                      fg + (tg - fg) * amount,
                      fb + (tb - fb) * amount)
end

--
--- ∑ Perceived brightness, 0 to 255. The usual luma weights. The result
---   decides whether a palette is dark or light, and so which way a stripe or
---   a hover has to move to stay visible.
---
---   The weights only work on the channels they were measured for. The eye is
---   most sensitive to green and least to blue, so putting the red weight on
---   the blue byte makes a soft blue read as bright and a soft red as dark,
---   and every judgement downstream of this follows it. That is Contrast, and
---   through Contrast it is the colour of a record in the tree.
--- @param color number
--- @return number
--
function Theme.Luma(color)
    local red, green, blue = Theme.Split(color)
    return 0.299 * red + 0.587 * green + 0.114 * blue
end

function Theme.IsDark(color)
    return Theme.Luma(color) < 128
end

--
--- ∑ Moves a colour towards white on a dark background and towards black on a
---   light one. One call lightens or darkens correctly under any theme, which
---   a fixed lighten by ten percent cannot.
--- @param color number
--- @param amount number
--- @param reference number|nil # What counts as the background. Defaults to
---        the colour itself.
--- @return number
--
function Theme.Shade(color, amount, reference)
    local dark = Theme.IsDark(reference or color)
    return Theme.Mix(color, dark and 0xFFFFFF or 0x000000, amount)
end

--
--- ∑ Lightens or darkens a colour until it stands clear of the background. A
---   severity hue picked against the bundled dark theme can vanish on a user's
---   light one. This keeps every severity readable without a palette per
---   theme.
--- @param color number
--- @param background number
--- @param minimum number|nil # Required luma distance, default 70.
--- @return number
--
function Theme.Contrast(color, background, minimum)
    minimum = minimum or 70
    local target = Theme.IsDark(background) and 0xFFFFFF or 0x000000
    local result = color
    for _ = 1, 8 do
        if math.abs(Theme.Luma(result) - Theme.Luma(background)) >= minimum then break end
        result = Theme.Mix(result, target, 0.18)
    end
    return result
end

--------------------------------------------------------
--                  Readable colours                  --
--------------------------------------------------------

--- The contrast ratio text has to reach, the one WCAG asks of body text. A
--- log line at ten points is body text.
Theme.ReadableRatio = 4.5

--- One channel byte as the light it gives off, the way sRGB defines it.
local function toLinear(byte)
    local value = byte / 255
    if value <= 0.03928 then return value / 12.92 end
    return ((value + 0.055) / 1.055) ^ 2.4
end

--- The way back, from light to a byte that Join still has to round.
local function toByte(value)
    if value <= 0 then return 0 end
    if value >= 1 then return 255 end
    if value <= 0.0031308 then return value * 12.92 * 255 end
    return (1.055 * value ^ (1 / 2.4) - 0.055) * 255
end

--
--- ∑ The relative luminance of a colour, the light it gives off, from 0 for
---   black to 1 for white, the way WCAG defines it.
---
---   Luma weighs the stored bytes and Luminance weighs the light, which is
---   not the same thing. A deep red and a dark grey can sit seventy apart in
---   luma and still be under four to one apart to the eye, and that is how
---   the ERROR hue came to be drawn at 3.89 to 1 on the bundled rows.
--- @param color number
--- @return number
--
function Theme.Luminance(color)
    local red, green, blue = Theme.Split(color)
    return 0.2126 * toLinear(red) + 0.7152 * toLinear(green) + 0.0722 * toLinear(blue)
end

--
--- ∑ How far apart two colours are to the eye, as the contrast ratio WCAG
---   measures. One is no difference at all and twenty one is black on white.
---   The log view carries the same measure as View.Ratio, so it can judge a
---   colour without a theme, and the tests hold the two to the same answer.
--- @param first number
--- @param second number
--- @return number
--
function Theme.Ratio(first, second)
    local a, b = Theme.Luminance(first), Theme.Luminance(second)
    if a < b then a, b = b, a end
    return (a + 0.05) / (b + 0.05)
end

--- A colour in OKLab, as its lightness from 0 to 1 and two opponent axes.
--- OKLab is built so that a hue angle in it is the hue an eye sees, which is
--- not true of RGB. Brighten a red by mixing in white and it turns pink.
--- These are Bjorn Ottosson's published matrices.
local function toOklab(color)
    local red, green, blue = Theme.Split(color)
    red, green, blue = toLinear(red), toLinear(green), toLinear(blue)
    local l = 0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue
    local m = 0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue
    local s = 0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue
    l, m, s = l ^ (1 / 3), m ^ (1 / 3), s ^ (1 / 3)
    return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
           1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
           0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end

--- The way back, to linear red, green and blue. A channel can come out
--- below nought or above one, when the OKLab colour is one a screen cannot
--- show.
local function fromOklab(lightness, a, b)
    local l = lightness + 0.3963377774 * a + 0.2158037573 * b
    local m = lightness - 0.1055613458 * a - 0.0638541728 * b
    local s = lightness - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l * l * l, m * m * m, s * s * s
    return 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
           -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
           -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
end

--- How far a channel may stray past nought or one and still count, so the
--- rounding in the matrices does not throw out plain white.
local GAMUT_SLACK = 1e-6

--- Whether a screen can show a colour given as linear channels.
local function displayable(red, green, blue)
    local low, high = -GAMUT_SLACK, 1 + GAMUT_SLACK
    return red >= low and red <= high and green >= low and green <= high
        and blue >= low and blue <= high
end

--- How many halvings a search takes. Sixteen pins a value to a sixty five
--- thousandth of its range, far finer than one step of a byte.
local SEARCH_STEPS = 16

--- How many lightness steps Readable looks at before it narrows in, which
--- is fine enough that no band of readable colours slips between two.
local LIGHTNESS_GRID = 32

--
--- The colour at one lightness and hue, with as much of the chroma asked for
--- as a screen can show there. A bright red holds less chroma than a middle
--- one, so the chroma is walked down until the colour fits, and the hue is
--- never touched.
--
local function atLightness(lightness, chroma, hue)
    local cosine, sine = math.cos(hue), math.sin(hue)
    local red, green, blue = fromOklab(lightness, chroma * cosine, chroma * sine)
    if not displayable(red, green, blue) then
        local low, high = 0, chroma
        for _ = 1, SEARCH_STEPS do
            local middle = (low + high) / 2
            if displayable(fromOklab(lightness, middle * cosine, middle * sine)) then
                low = middle
            else
                high = middle
            end
        end
        red, green, blue = fromOklab(lightness, low * cosine, low * sine)
    end
    return Theme.Join(toByte(red), toByte(green), toByte(blue))
end

--
--- ∑ A colour that reads on every tone it is drawn over, at the contrast
---   ratio asked for, and as close to the colour it was handed as that
---   allows.
---
---   Only the lightness moves. The hue is held in OKLab, where it stays the
---   hue an eye sees, and the chroma is kept wherever a screen can show it,
---   so an artwork red that has to brighten becomes a brighter red and not a
---   pink.
---
---   The lightness is looked for, not stepped. A coarse pass over the whole
---   range finds the readable lightness nearest the colour's own, and a
---   search between the two then finds where reading starts, so the colour
---   moves no further than the ratio needs. A tie goes the way Shade goes,
---   towards white on a dark first tone and towards black on a light one.
---   When no lightness reads on every tone, which takes tones on both sides
---   of the middle, the one that reads best on the worst of them wins.
---
---   A colour that already reads comes back as it is, and so does one that
---   is not a number or has no tone to read on. Every answer is measured
---   after it was rounded to whole bytes, so it holds as it will be drawn.
--- @param color number
--- @param tones number|table # One tone or a list of them.
--- @param ratio number|nil # Default ReadableRatio.
--- @return number
--
function Theme.Readable(color, tones, ratio)
    ratio = tonumber(ratio) or Theme.ReadableRatio
    if type(tones) ~= "table" then tones = { tones } end
    local list = {}
    for _, tone in ipairs(tones) do
        if type(tone) == "number" then list[#list + 1] = tone end
    end
    if type(color) ~= "number" or #list == 0 then return color end

    local function worst(candidate)
        local lowest = math.huge
        for index = 1, #list do
            local value = Theme.Ratio(candidate, list[index])
            if value < lowest then lowest = value end
        end
        return lowest
    end
    if worst(color) >= ratio then return color end

    local lightness, a, b = toOklab(color)
    local chroma, hue = math.sqrt(a * a + b * b), math.atan(b, a)
    local function at(value) return atLightness(value, chroma, hue) end
    local function score(value) return worst(at(value)) end
    local upward = Theme.IsDark(list[1])

    local goal, gap = nil, math.huge
    local best, bestScore = 0, -math.huge
    for step = 0, LIGHTNESS_GRID do
        local value = step / LIGHTNESS_GRID
        local scored = score(value)
        if scored > bestScore then best, bestScore = value, scored end
        if scored >= ratio then
            local distance = math.abs(value - lightness)
            local tie = distance == gap and ((value > lightness) == upward)
            if distance < gap or tie then goal, gap = value, distance end
        end
    end

    if goal == nil then
        -- Nothing on the grid reads. The best of it is narrowed in on, one
        -- grid step either side, because a band of readable colours can be
        -- narrower than a step.
        local low = math.max(0, best - 1 / LIGHTNESS_GRID)
        local high = math.min(1, best + 1 / LIGHTNESS_GRID)
        for _ = 1, SEARCH_STEPS do
            local left, right = low + (high - low) / 3, high - (high - low) / 3
            if score(left) < score(right) then low = left else high = right end
        end
        local narrowed = (low + high) / 2
        local scored = score(narrowed)
        if scored > bestScore then best, bestScore = narrowed, scored end
        if bestScore < ratio then return at(best) end
        goal = best
    end

    -- The colour's own lightness does not read and the goal does. Halving
    -- between them keeps the end that reads, so the answer always does.
    local near, far = lightness, goal
    for _ = 1, SEARCH_STEPS do
        local middle = (near + far) / 2
        if score(middle) >= ratio then far = middle else near = middle end
    end
    return at(far)
end

--------------------------------------------------------
--                      Palette                       --
--------------------------------------------------------

--- How far a zebra stripe steps off the canvas background. Surface paints
--- the stripe with it, and LevelColors and GetPalette make their colours read
--- on that same stripe, so the three can never mean two different tones.
local STRIPE_STEP = 0.05

--
--- ∑ The tones muted text is drawn over. The canvas and its stripe, where
---   the log view puts its stamps and channels, the panel under the status
---   line and the card headers, and the form behind the text prompt.
--- @param palette table
--- @return table
--
local function mutedTones(palette)
    local canvas = palette.COLOR_INPUT
    return { canvas, Theme.Shade(canvas, STRIPE_STEP), palette.COLOR_PANEL, palette.COLOR_BG }
end

--
--- ∑ The active palette. A live Manifold.Forms instance with an applied theme
---   wins, so this window follows the Cheat Table's theme.
---
---   Cached against the source table's identity. The canvases ask on every
---   frame and every hover repaint asks again, so building a merged copy per
---   call would be a table allocation per paint.
--- @return table
--
function Theme:GetPalette()
    local source = self:Source()
    if source == self.CachedSource and self.Cached then return self.Cached end
    local palette
    if source then
        palette = {}
        -- Merged, not used directly. ResolveTheme only fills defaults on the
        -- branch that reads tokenColors. Handed a table that already looks
        -- like a design theme it copies it verbatim, missing keys and all.
        for key, value in pairs(Theme.Default) do
            palette[key] = source[key] or value
        end
        -- COLOR_MUTED is the framework's address list group header colour. It
        -- was picked to read against Cheat Engine's own list, and this window
        -- draws it on four tones of its own, so it is made readable on all of
        -- them. Dark-Aqua's group header blue reads at 3.88 to 1 on a stripe.
        palette.COLOR_MUTED = Theme.Readable(palette.COLOR_MUTED, mutedTones(palette))
    else
        -- Theme.Default is shared and handed back by reference. That is why
        -- the correction above sits inside the other branch and not after the
        -- if and else, where it would edit the bundled palette for good. Its
        -- muted blue reads on all four tones as it is, and a test holds it
        -- to that.
        palette = Theme.Default
    end
    self.CachedSource, self.Cached = source, palette
    return palette
end

--- How far the chrome tone steps away from the canvas background. It sits
--- between the stripe at five hundredths and the hover at fourteen, so a title
--- bar reads as part of the frame and never as a row under the mouse.
local CHROME_STEP = 0.09

--
--- ∑ The chrome tone for a canvas, which is a step from the canvas towards
---   the palette's panel colour, the tone the card header strips carry.
---   A palette whose panel is its input colour would leave a title bar
---   invisible, so that one gets a small step towards the border instead.
--- @param base number # The canvas background, which is the input colour.
--- @param palette table # The palette in hand.
--- @return number # A colour in Cheat Engine's BGR.
--
local function headerTone(base, palette)
    local panel = palette.COLOR_PANEL or base
    local gap = math.abs(Theme.Luma(panel) - Theme.Luma(base))
    if gap < 6 then
        return Theme.Mix(base, palette.COLOR_BORDER or base, 0.12)
    end
    -- The chrome step sits between the stripe and the hover. Walking towards
    -- the panel only that far means a palette whose panel is nowhere near the
    -- canvas, which happens when a theme sets a few keys and inherits the rest,
    -- still gets a quiet bar rather than a loud one.
    return Theme.Mix(base, panel, math.min(1, (CHROME_STEP * 255) / gap))
end

--
--- ∑ The colours the log view paints with that the palette does not name.
---   The row tones, the search highlight, the scrollbar and the accent the
---   pin marker and the repeat badge are drawn in. Derived from the input
---   colour, so a light theme gets a light stripe and a dark one a dark
---   stripe.
---
---   The log view paints every row from this one table. The drawn combo
---   boxes take the selection tones from it as well, for the highlighted
---   entry of a dropped list, so that entry looks like a selected record.
---
---   Three tones carry a row and they are spaced on purpose. A stripe is the
---   quietest thing that still groups a pair of rows, and it is the same step
---   LevelColors and GetPalette make their text read on. A hover has to be
---   read at a glance on a plain row AND on a striped one, so it sits far
---   enough past the stripe to be told apart from it. A selection leans on
---   the accent instead, because brightness alone cannot carry three states.
---   A search hit leans on the accent about twice as far as a selection, so
---   a hit on a selected row still stands out from it.
---
---   The level hues are made to read on the plain and the striped row, and
---   the muted colour on those two and on the panel and the form. The log
---   view lifts both itself where it draws them on a hover, a selection or a
---   hit.
---
---   The gutter, the rule, the severity hues, the check box parts, the header
---   and the focus colour are not read by the log view. They are derived all
---   the same, so this table keeps every key the Address List's has.
--- @param palette table|nil # The palette in hand. The live one when missing.
--- @return table # Key to colour, in Cheat Engine's BGR.
--
function Theme:Surface(palette)
    palette = palette or self:GetPalette()
    local base = palette.COLOR_INPUT
    local gutter = Theme.Shade(base, 0.03)
    return {
        Background    = base,
        Stripe        = Theme.Shade(base, STRIPE_STEP),
        Hover         = Theme.Shade(base, 0.14),
        Selection     = Theme.Mix(base, palette.COLOR_ACCENT, 0.28),
        SelectionText = palette.COLOR_TEXT,
        Gutter        = gutter,
        Rule          = Theme.Mix(base, palette.COLOR_BORDER, 0.22),
        Text          = palette.COLOR_TEXT,
        Muted         = palette.COLOR_MUTED,
        Accent        = palette.COLOR_ACCENT,
        Match         = Theme.Mix(base, palette.COLOR_ACCENT, 0.55),
        Scroll        = Theme.Shade(base, 0.08),
        Thumb         = Theme.Mix(base, palette.COLOR_BORDER, 0.45),
        ThumbHover    = palette.COLOR_ACCENT,
        -- Severity, for the problem edge on a row and the tag in the results
        -- strip. Contrast corrected against the row background.
        Error         = Theme.Contrast(Theme.SeverityDefault.Error, base),
        Warning       = Theme.Contrast(Theme.SeverityDefault.Warning, base),
        Info          = Theme.Contrast(palette.COLOR_MUTED, base),
        -- The drawn check box. Its border sits most of the way from the row
        -- background towards the border colour, so an unticked box is visible
        -- without shouting.
        Check         = palette.COLOR_ACCENT,
        CheckBorder   = Theme.Mix(base, palette.COLOR_BORDER, 0.7),
        -- Chrome. The column title bar of a list and a category row in the
        -- property grid. It is the panel colour, the same tone the card header
        -- strips around these canvases already carry, so a title bar belongs to
        -- the frame instead of shouting over every row. Brightness is the wrong
        -- tool here. What keeps it from reading as a hovered row is the hairline
        -- the painters draw under it and the bold label on it.
        Header        = headerTone(base, palette),
        Focus         = palette.COLOR_ACCENT
    }
end

--
--- ∑ The text colour of every level, readable on both tones a plain row of
---   the log view can have, the input colour and its stripe.
---
---   Readable by the contrast ratio, and with the artwork's hue kept. The
---   log view lifts a colour again on a selected or a hovered row, and only
---   there, so a colour that did not read on a plain row was never lifted.
---   The artwork red is 3.89 to 1 on the bundled background and 3.58 on its
---   stripe, which a distance in luma called clear.
---
---   A method of its own and not a Surface key. The log view caches the two
---   tables side by side and drops both when the palette changes, and no other
---   canvas has a use for a level hue.
---
---   The table is built fresh on every call, so a caller may keep it and no
---   later call changes what it holds.
--- @param palette table|nil # The palette in hand. The live one when missing.
--- @return table # Level name to colour, one entry per level in LevelDefault.
--
function Theme:LevelColors(palette)
    palette = palette or self:GetPalette()
    local background = palette.COLOR_INPUT
    local tones = { background, Theme.Shade(background, STRIPE_STEP) }
    local colors = {}
    for level, color in pairs(Theme.LevelDefault) do
        colors[level] = Theme.Readable(color, tones)
    end
    return colors
end

--------------------------------------------------------
--                    Fitting text                    --
--------------------------------------------------------

--- What a cut caption ends in. Three plain dots, the same the canvases draw,
--- so a cut reads the same in a label as it does in a row.
local ELLIPSIS = "..."

--- The string a character width is measured on. Ten characters, so a
--- fractional width from a scaled display still comes out right.
local CHAR_PROBE = "0123456789"

--- The Consolas advance width as a share of the em, 1126 of 2048 font units.
--- Only used when no canvas can be had to measure on.
local CONSOLAS_ADVANCE = 1126 / 2048

--
--- ∑ The character width and line height of Consolas at one point size,
---   measured once per size on a throwaway bitmap and remembered.
---
---   A bitmap and not the control's own canvas. A label is a graphic control
---   whose canvas only takes the control's font while it paints, so measuring
---   on it before then measures the default font. The bitmap gets the font
---   set explicitly and is freed straight away.
---
---   Without createBitmap the numbers are worked out the way GDI rounds them,
---   the em in whole pixels at 96 dots per inch and the advance rounded from
---   that, which is exact for Consolas on an unscaled display.
--- @param size number|nil # Points. The segment size when missing.
--- @return number, number # Pixels per character, pixels per line.
--
function Theme:TextMetrics(size)
    size = tonumber(size) or Theme.FontSize
    if size <= 0 then size = Theme.FontSize end
    if type(self.Metrics) ~= "table" then self.Metrics = {} end
    local known = self.Metrics[size]
    if known then return known.CharWidth, known.LineHeight end
    local charWidth, lineHeight = 0, 0
    local create = rawget(_G, "createBitmap")
    if type(create) == "function" then
        local ok, bitmap = pcall(create, 16, 16)
        if ok and bitmap then
            pcall(function()
                local canvas = bitmap.Canvas
                local font = canvas.Font
                font.Name = Theme.FontName
                font.Size = size
                charWidth = (tonumber(canvas.getTextWidth(CHAR_PROBE)) or 0) / #CHAR_PROBE
                lineHeight = tonumber(canvas.getTextHeight("Ag")) or 0
            end)
            pcall(function() bitmap.destroy() end)
        end
    end
    local em = math.floor(size * 96 / 72 + 0.5)
    if charWidth <= 0 then
        charWidth = math.max(1, math.floor(em * CONSOLAS_ADVANCE + 0.5))
    end
    if lineHeight <= 0 then lineHeight = em + 2 end
    self.Metrics[size] = { CharWidth = charWidth, LineHeight = lineHeight }
    return charWidth, lineHeight
end

--- Pixels per character of Consolas at one point size.
function Theme:CharWidth(size)
    return (self:TextMetrics(size))
end

--- A text cut to a width in whole Consolas characters at one point size.
--- Answers what fits and whether anything was cut.
local function fitString(self, text, width, size)
    local room = math.floor(math.max(0, tonumber(width) or 0) / self:CharWidth(size))
    if textLength(text) <= room then return text, false end
    if room > #ELLIPSIS then
        -- A space in front of the dots reads as a gap, so it goes.
        return (textHead(text, room - #ELLIPSIS):gsub("%s+$", "")) .. ELLIPSIS, true
    end
    -- No room for a word, so as many dots as fit say something is there and
    -- the hint says what.
    return ELLIPSIS:sub(1, room), true
end

--
--- ∑ Puts as much of a text on a control as fits a width, ending in dots when
---   it had to cut, and says the whole text in the hint when it did.
---
---   The width is counted in characters of Consolas at the control's own font
---   size. The font is monospaced, so that count is exact and no candidate
---   string has to be measured.
---
---   The hint is written every time, because a caption that fits again must
---   not keep the tooltip of the one that did not. The fourth argument is what
---   the control says when nothing was cut. A cut text shows the whole text
---   with that line under it.
--- @param control userdata # Anything with a Caption.
--- @param text string|nil
--- @param width number|nil # Pixels. The control's own width when missing.
--- @param hint string|nil # The control's own hint, if it has one.
--- @return string, boolean # What is shown, and whether it was cut.
--
function Theme:FitText(control, text, width, hint)
    text = text == nil and "" or tostring(text)
    width = tonumber(width) or readNumber(control, "Width") or 0
    local shown, cut = fitString(self, text, width, fontSizeOf(control))
    safeSet(control, "Caption", shown)
    local own = hint == nil and "" or tostring(hint)
    local tip = own
    if cut then tip = own ~= "" and (text .. "\n" .. own) or text end
    safeSet(control, "Hint", tip)
    safeSet(control, "ShowHint", tip ~= "")
    return shown, cut
end

--------------------------------------------------------
--                  Windows and layout                --
--------------------------------------------------------

--
--- ∑ A resizeable themed window.
---
---   Modal is for a window that will be shown with showModal. Such a window
---   keeps Cheat Engine as its owner so it cannot fall behind the window it
---   blocks. Every other window is detached.
---
---   EscCloses adds the key handler that the panel buttons cannot provide,
---   since none of them is a native Cancel button. The main window leaves it
---   off, because there Escape first clears the filter.
--- @param caption string
--- @param width number|nil
--- @param height number|nil
--- @param options table|nil # Modal, MinWidth, MinHeight and EscCloses.
--- @return userdata, table # The form and the palette as it is right now.
--
function Theme:CreateWindow(caption, width, height, options)
    options = options or {}
    -- false means do not show it yet. The caller shows it, which is also why
    -- detachFromMainForm below lands before the handle exists.
    local form = make("createForm", false)
    safeSet(form, "Caption", caption)
    safeSet(form, "Position", "poScreenCenter")
    safeSet(form, "BorderStyle", "bsSizeable")
    safeSet(form, "Width", width or 900)
    safeSet(form, "Height", height or 600)
    if not options.Modal then detachFromMainForm(form) end
    self:Track(function()
        local active = self:GetPalette()
        safeSet(form, "Color", active.COLOR_BG)
        safeFont(form, active.COLOR_TEXT)
    end)
    pcall(function()
        local constraints = form.Constraints
        constraints.MinWidth = options.MinWidth or 520
        constraints.MinHeight = options.MinHeight or 320
    end)
    if options.EscCloses then
        pcall(function()
            form.KeyPreview = true
            form.OnKeyDown = function(_, key)
                if key == 27 then
                    safeSet(form, "ModalResult", rawget(_G, "mrCancel") or 2)
                    pcall(function() form.close() end)
                end
                -- The key is handed back rather than swallowed. Returning 0
                -- here would eat every other key in the window.
                return key
            end
        end)
    end
    return form, self:GetPalette()
end

--
--- ∑ A themed panel. ColorKey names the palette entry to follow, so the panel
---   re-colours with the theme. Color is the escape hatch for a colour that is
---   not from the palette, such as a record's own colour, and is applied once.
--- @param parent userdata
--- @param options table|nil # ColorKey, Color, BevelOuter, BevelWidth,
---        BevelColorKey, BevelColor, Align, Height, Width, Anchors, Spacing.
--- @return userdata
--
function Theme:CreatePanel(parent, options)
    options = options or {}
    local panel = make("createPanel", parent)
    safeSet(panel, "Parent", parent)
    safeSet(panel, "Caption", "")
    safeSet(panel, "ParentColor", false)
    if options.Color then
        safeSet(panel, "Color", options.Color)
    else
        local key = options.ColorKey or "COLOR_PANEL"
        self:Track(function()
            safeSet(panel, "Color", self:GetPalette()[key])
        end)
    end
    safeSet(panel, "BevelOuter", options.BevelOuter or "bvNone")
    if options.BevelWidth then safeSet(panel, "BevelWidth", options.BevelWidth) end
    if options.BevelColorKey then
        local key = options.BevelColorKey
        self:Track(function()
            safeSet(panel, "BevelColor", self:GetPalette()[key])
        end)
    elseif options.BevelColor then
        safeSet(panel, "BevelColor", options.BevelColor)
    end
    if options.Align then safeSet(panel, "Align", options.Align) end
    if options.Height then safeSet(panel, "Height", options.Height) end
    if options.Width then safeSet(panel, "Width", options.Width) end
    if options.Anchors then safeSet(panel, "Anchors", options.Anchors) end
    setSpacing(panel, options.Spacing)
    return panel
end

--- The space in front of a card title and behind its counter.
local CARD_TITLE_PAD, CARD_COUNTER_PAD = 8, 8

--- The least a counter keeps clear of the title, so the two never touch.
local CARD_COUNTER_GAP = 12

--
--- ∑ A bordered card with an optional header strip, in the Manifold.Forms
---   idiom. A border panel, a body panel one pixel inside it so the border
---   shows through, then the header and the content.
---
---   The header carries two labels. The title on the left and a quieter
---   counter on the right, which is where a record count, the inspector's
---   subject or the number of problems goes. The counter is created first
---   because alRight puts the first created control outermost, so building it
---   first is what puts it at the right edge.
---
---   The counter is an autosized label, so a long text would grow it over the
---   title and out of the left edge. Every text is therefore fitted into the
---   room the title leaves before it is shown, when it is set and again when
---   the header changes size. Write it through the setter that comes back
---   fifth. A caption written straight onto the label still works, and the
---   next resize fits it too.
--- @param parent userdata
--- @param options table|nil # Align, Height, Width, Title, Counter, Spacing,
---        ContentColor, ContentColorKey, ContentPad and ContentSpacing.
--- @return userdata, userdata, userdata|nil, userdata|nil, function # content,
---         card, title label, counter label, setCounter(text) which answers
---         with what is shown
--
function Theme:CreateCard(parent, options)
    options = options or {}
    local card = self:CreatePanel(parent, {
        Align = options.Align or "alClient",
        Height = options.Height,
        Width = options.Width,
        ColorKey = "COLOR_BORDER",
        BevelOuter = "bvNone",
        Spacing = options.Spacing or { Around = 8 }
    })
    local body = self:CreatePanel(card, {
        Align = "alClient",
        ColorKey = "COLOR_PANEL",
        Spacing = { Around = 1 }
    })
    local titleLabel, counterLabel
    local setCounter = function() return "" end
    if options.Title then
        local header = self:CreatePanel(body, {
            Align = "alTop", Height = 24, ColorKey = "COLOR_PANEL"
        })
        counterLabel = make("createLabel", header)
        safeSet(counterLabel, "Parent", header)
        safeSet(counterLabel, "Align", "alRight")
        safeSet(counterLabel, "Layout", "tlCenter")
        safeSet(counterLabel, "Alignment", "taRightJustify")
        safeSet(counterLabel, "Transparent", true)
        self:Track(function()
            safeFont(counterLabel, self:GetPalette().COLOR_MUTED)
        end)
        setSpacing(counterLabel, { Right = CARD_COUNTER_PAD })

        titleLabel = make("createLabel", header)
        safeSet(titleLabel, "Parent", header)
        safeSet(titleLabel, "Align", "alClient")
        safeSet(titleLabel, "Layout", "tlCenter")
        safeSet(titleLabel, "Transparent", true)
        safeSet(titleLabel, "Caption", options.Title)
        self:Track(function()
            safeFont(titleLabel, self:GetPalette().COLOR_LABEL, Theme.FontSize, "[fsBold]")
        end)
        setSpacing(titleLabel, { Left = CARD_TITLE_PAD })

        -- The whole text and what the label shows of it. The second is how a
        -- caption written straight onto the label is told apart from a cut.
        local wanted, shown = tostring(options.Counter or ""), nil

        --- Fits the counter into what the header has left. A header that does
        --- not know its width yet shows the text whole, and the first resize
        --- after the form is shown fits it.
        local function fit(adopt)
            if adopt then
                local current = readText(counterLabel)
                if current ~= nil and current ~= shown then wanted = current end
            end
            local width = innerWidth(header)
            if width == nil or width <= 0 then
                safeSet(counterLabel, "Caption", wanted)
                safeSet(counterLabel, "Hint", "")
                shown = wanted
                return shown
            end
            local title = readText(titleLabel) or ""
            local titleWidth = textLength(title) * self:CharWidth(fontSizeOf(titleLabel))
            local room = width - CARD_TITLE_PAD - titleWidth - CARD_COUNTER_GAP - CARD_COUNTER_PAD
            shown = self:FitText(counterLabel, wanted, room)
            return shown
        end
        setCounter = function(text)
            wanted = text == nil and "" or tostring(text)
            return fit(false)
        end
        safeSet(header, "OnResize", function() fit(true) end)
        fit(false)
    end
    local content = self:CreatePanel(body, {
        Align = "alClient",
        Color = options.ContentColor,
        ColorKey = options.ContentColorKey or "COLOR_INPUT",
        Spacing = options.ContentSpacing or { Around = options.ContentPad or 6 }
    })
    return content, card, titleLabel, counterLabel, setCounter
end

function Theme:CreateToolBar(parent, height)
    return self:CreatePanel(parent, {
        Align = "alTop", Height = height or 40,
        Spacing = { Left = 8, Right = 8, Top = 8 }
    })
end

function Theme:CreateButtonBar(parent, height)
    return self:CreatePanel(parent, {
        Align = "alBottom", Height = height or 44,
        Spacing = { Left = 8, Right = 8, Bottom = 8 }
    })
end

--
--- ∑ Status line at the very bottom. Two labels rather than one. What is
---   happening on the left, quieter counts on the right, so the line can carry
---   several facts at once.
---
---   The detail is created before the primary label. alRight claims its width
---   first and alClient then takes what is left.
--- @param parent userdata
--- @param text string|nil # Initial text for the left label.
--- @return userdata, userdata, userdata # primary label, bar, detail label
--
function Theme:CreateStatusBar(parent, text)
    local bar = self:CreatePanel(parent, {
        Align = "alBottom", Height = 24, ColorKey = "COLOR_PANEL",
        Spacing = { Left = 8, Right = 8, Bottom = 4 }
    })
    local detail = make("createLabel", bar)
    safeSet(detail, "Parent", bar)
    safeSet(detail, "Align", "alRight")
    safeSet(detail, "Layout", "tlCenter")
    safeSet(detail, "Alignment", "taRightJustify")
    safeSet(detail, "Transparent", true)
    safeSet(detail, "Caption", "")
    self:Track(function() safeFont(detail, self:GetPalette().COLOR_MUTED) end)
    setSpacing(detail, { Right = 6 })

    local label = make("createLabel", bar)
    safeSet(label, "Parent", bar)
    safeSet(label, "Align", "alClient")
    safeSet(label, "Layout", "tlCenter")
    safeSet(label, "Transparent", true)
    safeSet(label, "Caption", text or "")
    self:Track(function() safeFont(label, self:GetPalette().COLOR_MUTED) end)
    setSpacing(label, { Left = 6 })
    return label, bar, detail
end

--
--- ∑ A thin vertical rule for grouping toolbar buttons. Aligned like a button,
---   so it takes its place in the same stack.
---
---   One panel, one pixel wide. An alClient child inside a wider holder does
---   not work. alClient overrides Width, so the rule fills the holder and the
---   separator comes out a solid bar. The margins do the spacing.
--- @param parent userdata
--- @return userdata
--
function Theme:CreateToolSeparator(parent)
    return self:CreatePanel(parent, {
        Align = "alLeft", Width = 1, ColorKey = "COLOR_BORDER",
        Spacing = { Left = 8, Right = 8, Top = 8, Bottom = 8 }
    })
end

--
--- ∑ Draggable divider between two panes.
---
---   Place it next to the pane it resizes and give it the same Align. That is
---   how the LCL pairs the two. Because alLeft and alTop put the last created
---   control outermost, a splitter for an alLeft pane is built BEFORE that
---   pane and one for an alBottom pane is built AFTER it.
---
---   A sideways splitter takes a Width and an up and down one takes a Height.
---   Setting the wrong one leaves a divider that is either invisible or as
---   thick as the pane, which is why the alignment decides it here rather than
---   at the call site.
--- @param parent userdata
--- @param options table|nil # Align, Width, Height and MinSize.
--- @return userdata
--
function Theme:CreateSplitter(parent, options)
    options = options or {}
    local align = options.Align or "alBottom"
    local horizontal = isHorizontalAlign(align)
    local thickness = (horizontal and options.Width or options.Height) or 5
    local splitter = make("createSplitter", parent)
    if not splitter then
        -- No createSplitter in this Cheat Engine. A thin panel keeps the
        -- visual seam, it just cannot be dragged.
        local fallback = { Align = align, ColorKey = "COLOR_BG" }
        if horizontal then fallback.Width = thickness else fallback.Height = thickness end
        return self:CreatePanel(parent, fallback)
    end
    safeSet(splitter, "Parent", parent)
    safeSet(splitter, "Align", align)
    if horizontal then
        safeSet(splitter, "Width", thickness)
    else
        safeSet(splitter, "Height", thickness)
    end
    safeSet(splitter, "MinSize", options.MinSize or 80)
    safeSet(splitter, "ResizeStyle", "rsUpdate")
    safeSet(splitter, "Beveled", false)
    safeSet(splitter, "ParentColor", false)
    self:Track(function() safeSet(splitter, "Color", self:GetPalette().COLOR_BG) end)
    return splitter
end

--------------------------------------------------------
--                      Controls                      --
--------------------------------------------------------

function Theme:StyleLabel(label, role)
    safeSet(label, "Transparent", true)
    self:Track(function()
        local palette = self:GetPalette()
        local color = palette.COLOR_LABEL
        if role == "muted" then color = palette.COLOR_MUTED end
        if role == "text" then color = palette.COLOR_TEXT end
        safeFont(label, color, Theme.FontSize, role == "header" and "[fsBold]" or nil)
    end)
end

function Theme:CreateLabel(parent, caption, role)
    local label = make("createLabel", parent)
    safeSet(label, "Parent", parent)
    safeSet(label, "Caption", caption or "")
    self:StyleLabel(label, role)
    return label
end

function Theme:StyleEdit(edit)
    safeSet(edit, "ParentColor", false)
    safeSet(edit, "BorderStyle", "bsNone")
    self:Track(function()
        local palette = self:GetPalette()
        safeSet(edit, "Color", palette.COLOR_INPUT)
        safeFont(edit, palette.COLOR_INPUT_TEXT)
    end)
end

--
--- ∑ A themed single line edit.
---
---   OnChange is assigned after the initial text, because writing Text in code
---   fires it. A handler assigned first would run once during construction,
---   before the caller's own state exists.
--- @param parent userdata
--- @param options table|nil # Align, Anchors, Width, Height, Left, Top, Hint,
---        Placeholder, Text, OnChange and Spacing.
--- @return userdata
--
function Theme:CreateEdit(parent, options)
    options = options or {}
    local edit = make("createEdit", parent)
    safeSet(edit, "Parent", parent)
    if options.Align then safeSet(edit, "Align", options.Align) end
    if options.Anchors then safeSet(edit, "Anchors", options.Anchors) end
    if options.Width then safeSet(edit, "Width", options.Width) end
    if options.Height then safeSet(edit, "Height", options.Height) end
    if options.Left then safeSet(edit, "Left", options.Left) end
    if options.Top then safeSet(edit, "Top", options.Top) end
    if options.Hint then
        safeSet(edit, "Hint", options.Hint)
        safeSet(edit, "ShowHint", true)
    end
    -- TextHint is the grey placeholder. It is a published property on
    -- TCustomEdit, so it goes through the RTTI fallback and may be absent.
    if options.Placeholder then safeSet(edit, "TextHint", options.Placeholder) end
    safeSet(edit, "Text", options.Text or "")
    self:StyleEdit(edit)
    if options.OnChange then safeSet(edit, "OnChange", options.OnChange) end
    setSpacing(edit, options.Spacing)
    return edit
end

--
--- ∑ Themes a combo box. Color and the font reach a native box only where
---   Windows asks the control for them, and an owner drawn one paints from
---   the palette itself, so the closure also repaints it. A theme change that
---   leaves the input colours alone still changes the selection and the muted
---   colour it paints with.
--- @param combo userdata
--- @return nil
--
function Theme:StyleCombo(combo)
    safeSet(combo, "ParentColor", false)
    self:Track(function()
        local palette = self:GetPalette()
        safeSet(combo, "Color", palette.COLOR_INPUT)
        safeFont(combo, palette.COLOR_INPUT_TEXT)
        pcall(function() combo.repaint() end)
    end)
end

--- The style that makes Windows ask the owner for every item, the closed box
--- included. The list cannot be typed into, like csDropDownList.
local COMBO_OWNER_DRAWN = "csOwnerDrawFixed"

--- An owner drawn item is one line of text and this many pixels. Windows gives
--- a native closed box the same, so the owner drawn box is exactly as tall as
--- a native one, which is the item and six pixels of rim.
local COMBO_ITEM_EXTRA = 2

--- How far the text sits inside its item. The LCL's own item painter leaves
--- the same two pixels, and so does a native closed box.
local COMBO_TEXT_PAD = 2

--- What Windows keeps around the item of an owner drawn closed box. One pixel
--- of border, one of the themed face and one ring in the control's brush, so
--- the item starts three pixels in on the left, the top and the bottom.
local COMBO_RIM = 3

--- The owner draw state as a set of names. Cheat Engine writes it with the
--- names joined by commas and no brackets, such as odSelected,odFocused, and
--- a table of names is taken as well.
local function drawState(state)
    local flags = {}
    if type(state) == "table" then
        for key, value in pairs(state) do
            if type(key) == "string" and value then flags[key] = true end
            if type(value) == "string" then flags[value] = true end
        end
        return flags
    end
    for name in tostring(state or ""):gmatch("[%a_][%w_]*") do flags[name] = true end
    return flags
end

--- The caption of one item of a combo box, or an empty string when there is
--- no such item or the list cannot be read. The index is held against Count
--- first, because the binding reads the list with no bounds check of its own
--- and an error inside a binding is not one pcall can be trusted to catch.
local function comboItem(combo, index)
    local ok, text = pcall(function()
        local items = combo.Items
        local count = tonumber(items.Count) or 0
        if index < 0 or index >= count then return nil end
        return items[index]
    end)
    if not ok or text == nil then return "" end
    return tostring(text)
end

--
--- ∑ Paints one item of an owner drawn combo box, the closed box included.
---
---   Cheat Engine calls this from OnDrawItem with the combo box, the index
---   from zero, the item rectangle as a table and the state as a string of
---   names. The LCL has already pointed the combo box's canvas at the device
---   context Windows handed over, put the control's brush and font on it, and
---   the highlight colours when the item is selected. It never asks for item
---   minus one, which is the closed box with nothing picked.
---
---   The closed box arrives with odComboBoxEdit and always takes the input
---   colours. A focused closed box arrives as selected as well, and a native
---   dark one shows no highlight there either. A selected row of the dropped
---   list takes the selection colours the canvases use. A disabled box writes
---   its text in the muted colour, like a disabled check box.
---
---   textOut is opaque and fills the text cell with the brush colour, so the
---   brush carries the item's background while the text goes down. Brush and
---   font colour are put back afterwards, because the canvas belongs to the
---   combo box and outlives this item.
---
---   Nothing raises out of here. A failure leaves the item as far as it got.
--- @param combo userdata
--- @param index number # The item, from zero.
--- @param rect table # Left, Top, Right and Bottom.
--- @param state string|table # The owner draw state.
--- @return boolean # Whether the item was painted.
--
function Theme:PaintComboItem(combo, index, rect, state)
    if not combo or type(rect) ~= "table" then return false end
    local left, top = tonumber(rect.Left), tonumber(rect.Top)
    local right, bottom = tonumber(rect.Right), tonumber(rect.Bottom)
    if not (left and top and right and bottom) or right <= left or bottom <= top then
        return false
    end
    local flags = drawState(state)
    local palette = self:GetPalette()
    local background, foreground = palette.COLOR_INPUT, palette.COLOR_INPUT_TEXT
    if flags.odDisabled then
        foreground = palette.COLOR_MUTED
    elseif flags.odSelected and not flags.odComboBoxEdit then
        local surface = self:Surface(palette)
        background, foreground = surface.Selection, surface.SelectionText
    end
    index = tonumber(index) or -1
    local caption = index >= 0 and comboItem(combo, index) or ""
    local shown = fitString(self, caption, right - left - 2 * COMBO_TEXT_PAD, fontSizeOf(combo))

    local ok, painted = pcall(function()
        local canvas = combo.Canvas
        local brush, font = canvas.Brush, canvas.Font
        local givenBrush, givenFont = brush.Color, font.Color
        local drawn = pcall(function()
            brush.Color = background
            canvas.fillRect(left, top, right, bottom)
            if shown ~= "" then
                font.Color = foreground
                local lineHeight = tonumber(canvas.getTextHeight(shown)) or 0
                local above = math.floor(math.max(0, bottom - top - lineHeight) / 2)
                canvas.textOut(left + COMBO_TEXT_PAD, top + above, shown)
            end
        end)
        brush.Color = givenBrush
        font.Color = givenFont
        return drawn
    end)
    return ok and painted == true
end

--
--- ∑ Makes a combo box draw its own items, or leaves it as it was.
---
---   The order is the point. ItemHeight goes first, because on an owner
---   drawn box that already has a window the LCL recreates the window for
---   it, and Cheat Engine's dark mode box only themes a new window again when
---   Style changes. The handler goes second, so the first paint of the new
---   window already reaches it. Style goes last and recreates the window once.
---
---   A Cheat Engine that never registered TDrawItemEvent drops the handler in
---   silence and raises when it is read back, and one whose combo box has no
---   owner drawn style drops that write. Either way the box is left native.
--- @param combo userdata|nil
--- @return boolean # Whether the box is owner drawn now.
--
local function ownerDraw(self, combo)
    if not combo then return false end
    local _, lineHeight = self:TextMetrics(Theme.FontSize)
    safeSet(combo, "ItemHeight", lineHeight + COMBO_ITEM_EXTRA)
    local entry = nil
    local function draw(sender, index, rect, state)
        pcall(self.PaintComboItem, self, sender or combo, index, rect, state)
        if entry ~= nil then pcall(self.ComboDrawn, self, entry) end
    end
    safeSet(combo, "OnDrawItem", draw)
    local readable, assigned = pcall(function() return combo.OnDrawItem end)
    if readable and type(assigned) == "function" then
        safeSet(combo, "Style", COMBO_OWNER_DRAWN)
        local known, style = pcall(function() return combo.Style end)
        if known and style == COMBO_OWNER_DRAWN then
            entry = { Combo = combo, Mark = #self.Registry, Shown = false,
                      Settled = nil, Drawn = nil, Chain = nil }
            self.Combos[#self.Combos + 1] = entry
            self.CombosPending = self.CombosPending + 1
            return true
        end
        safeSet(combo, "OnDrawItem", nil)
    end
    -- Zero hands the height back to Windows, which a native box uses anyway.
    safeSet(combo, "ItemHeight", 0)
    return false
end

--
--- ∑ Carries the input colour into a combo box's own brush.
---
---   Windows fills the closed box's item with the control's brush before it
---   asks the owner to draw, and the LCL never passes item minus one on. So a
---   box with nothing picked shows the brush and nothing else, and so does
---   the ring around every item. Cheat Engine's dark mode sets that brush to
---   black when the brush is made, on the box's first paint, and
---   TWinControl.SetColor only reaches a brush that already exists and only
---   for a colour that differs from the one the box has. The box was given the
---   input colour before its first paint, so every later write of the same
---   colour did nothing and the black stayed.
---
---   Writing a colour one step away and then the input colour is two real
---   changes, and the second leaves the brush on the input colour. Nothing
---   else changes, and the box repaints once.
--- @param combo userdata
--- @return boolean # Whether both writes went through.
--
function Theme:SettleCombo(combo)
    if not combo then return false end
    local color = math.floor(tonumber(self:GetPalette().COLOR_INPUT) or 0)
    local nudged = safeSet(combo, "Color", color ~ 1)
    local settled = safeSet(combo, "Color", color)
    return nudged and settled
end

--
--- ∑ Settles a combo box the moment it drew an item, once per input colour.
---
---   The LCL hands the control's brush to the canvas before it calls the draw
---   handler, so inside the handler the brush certainly exists and a settle
---   certainly lands. The repaint the settle asks for comes back here with
---   the colour already recorded and changes nothing.
--- @param entry table # The combo box's entry in Combos.
--- @return boolean # Whether it settled the box now.
--
function Theme:ComboDrawn(entry)
    local color = self:GetPalette().COLOR_INPUT
    if entry.Drawn == color then return false end
    entry.Drawn = color
    if entry.Settled == nil then self.CombosPending = math.max(0, self.CombosPending - 1) end
    entry.Settled = color
    return self:SettleCombo(entry.Combo)
end

--- The deepest a combo box is expected to sit below its form. A chain longer
--- than this is not a window this theme built.
local COMBO_CHAIN_LIMIT = 64

--- A combo box and its parents up to the form, the form first. Read once per
--- box, because a box is never moved to another parent, and a settle pass
--- runs sixty times a second while a box waits.
local function chainOf(entry)
    if entry.Chain ~= nil then return entry.Chain end
    local ok, chain = pcall(function()
        local list, current = {}, entry.Combo
        for _ = 1, COMBO_CHAIN_LIMIT do
            table.insert(list, 1, current)
            current = current.Parent
            if current == nil then return list end
        end
        return nil
    end)
    if ok and chain ~= nil then entry.Chain = chain end
    return entry.Chain
end

--- Whether a combo box is on screen, which is every control from the form
--- down to it visible, none of them without a size, and the form not
--- minimised. The form is asked first, so a box on a hidden page costs the
--- reads down to that page and no more. A box that cannot be read is taken
--- as not shown, the opposite of isShown, because a settle on a box that
--- never painted is wasted.
local function onScreen(entry)
    local chain = chainOf(entry)
    if chain == nil then return false end
    local ok, answer = pcall(function()
        for _, control in ipairs(chain) do
            if control.Visible == false then return false end
        end
        for _, control in ipairs(chain) do
            if (tonumber(control.Width) or 0) <= 0 or (tonumber(control.Height) or 0) <= 0 then
                return false
            end
        end
        local known, state = pcall(function() return chain[1].WindowState end)
        return not (known and state == "wsMinimized")
    end)
    return ok and answer == true
end

--
--- ∑ Puts right what only exists once Windows painted a native control,
---   which is the brush of an owner drawn combo box. The frame service calls
---   this at the start of every tick.
---
---   Every box that is on screen and has not been settled yet is settled.
---
---   A box with nothing picked never reaches the draw handler, so this is the
---   only place its brush can be put right. The brush exists once Windows has
---   painted the box, and Windows hands out a timer message only when no
---   paint is waiting, so a box that was on screen when the last tick started
---   and still is now has been painted in between. A box counts from the
---   second tick it is seen on, which also covers one a painter showed in the
---   middle of a tick, such as the grid's editor.
---
---   Nothing is read once every box is settled. A box that goes out of sight
---   before its second tick starts counting again when it comes back.
--- @return number # How many boxes were settled now.
--
function Theme:Settle()
    if self.CombosPending <= 0 then return 0 end
    local settled, pending = 0, 0
    for _, entry in ipairs(self.Combos) do
        if entry.Settled == nil then
            if not onScreen(entry) then
                entry.Shown = false
                pending = pending + 1
            elseif not entry.Shown then
                entry.Shown = true
                pending = pending + 1
            else
                entry.Settled = self:GetPalette().COLOR_INPUT
                self:SettleCombo(entry.Combo)
                settled = settled + 1
            end
        end
    end
    self.CombosPending = pending
    return settled
end

--
--- ∑ Stops watching a combo box that is about to be freed, so no settle pass
---   reads a control that is gone. The owner calls this before it destroys
---   one it made through CreateCombo.
--- @param combo userdata|nil
--- @return boolean # Whether the box was being watched.
--
function Theme:ForgetCombo(combo)
    if combo == nil then return false end
    for index, entry in ipairs(self.Combos) do
        if entry.Combo == combo then
            table.remove(self.Combos, index)
            if entry.Settled == nil then
                self.CombosPending = math.max(0, self.CombosPending - 1)
            end
            return true
        end
    end
    return false
end

--
--- ∑ A read only dropdown filled from Items.
---
---   Owner drawn where Cheat Engine allows it, so the closed box and the
---   dropped list are painted in the input colours by PaintComboItem and only
---   the rim and the arrow button stay native. Otherwise a native drop-down
---   list, whose face the theme cannot colour.
--- @param parent userdata
--- @param options table|nil # Items, ItemIndex, Align, Anchors, Width, Left,
---        Top, Hint and OnChange.
--- @return userdata
--
function Theme:CreateCombo(parent, options)
    options = options or {}
    local combo = make("createComboBox", parent)
    safeSet(combo, "Parent", parent)
    -- Before the items, so the one window the style change recreates is
    -- the only one, and the list is filled into it.
    if not ownerDraw(self, combo) then safeSet(combo, "Style", "csDropDownList") end
    if options.Align then safeSet(combo, "Align", options.Align) end
    if options.Anchors then safeSet(combo, "Anchors", options.Anchors) end
    if options.Width then safeSet(combo, "Width", options.Width) end
    if options.Left then safeSet(combo, "Left", options.Left) end
    if options.Top then safeSet(combo, "Top", options.Top) end
    if options.Hint then
        safeSet(combo, "Hint", options.Hint)
        safeSet(combo, "ShowHint", true)
    end
    for _, item in ipairs(options.Items or {}) do
        pcall(function() combo.Items.add(tostring(item)) end)
    end
    if options.ItemIndex then safeSet(combo, "ItemIndex", options.ItemIndex) end
    self:StyleCombo(combo)
    -- OnChange last. Setting ItemIndex fires nothing on a combo box, but the
    -- order matches every other control here, so nobody has to remember which
    -- one is the exception.
    if options.OnChange then safeSet(combo, "OnChange", options.OnChange) end
    return combo
end

--
--- ∑ Themes a memo. An explicit Background or Foreground is a caller borrowing
---   Cheat Engine's own editor colours, which are not ours to re-theme, so
---   that path is applied once and not tracked.
--- @param memo userdata
--- @param options table|nil # Background and Foreground.
--- @return nil
--
function Theme:StyleMemo(memo, options)
    options = options or {}
    safeSet(memo, "ParentColor", false)
    safeSet(memo, "BorderStyle", "bsNone")
    if options.Background or options.Foreground then
        local palette = self:GetPalette()
        safeSet(memo, "Color", options.Background or palette.COLOR_INPUT)
        safeFont(memo, options.Foreground or palette.COLOR_TEXT)
        return
    end
    self:Track(function()
        local palette = self:GetPalette()
        safeSet(memo, "Color", palette.COLOR_INPUT)
        safeFont(memo, palette.COLOR_TEXT)
    end)
end

function Theme:CreateMemo(parent, options)
    options = options or {}
    local memo = make("createMemo", parent)
    safeSet(memo, "Parent", parent)
    safeSet(memo, "Align", options.Align or "alClient")
    safeSet(memo, "ReadOnly", options.ReadOnly ~= false)
    safeSet(memo, "ScrollBars", options.ScrollBars or "ssBoth")
    safeSet(memo, "WordWrap", options.WordWrap == true)
    if options.Visible ~= nil then safeSet(memo, "Visible", options.Visible) end
    self:StyleMemo(memo, options)
    return memo
end

--------------------------------------------------------
--                       Buttons                      --
--------------------------------------------------------

--
--- ∑ A 16x16 glyph on a control, loaded straight from the icon folder.
---
---   TPicture.LoadFromFile sniffs the format from the extension, so this works
---   where the image list path cannot take a file name at all. Everything is
---   pcall'd and a failure is silent. A button without its glyph is still a
---   button. An exception during window construction is not.
--- @param parent userdata
--- @param iconName string
--- @param left number|nil
--- @param top number|nil
--- @return userdata|nil
--
function Theme:CreateGlyph(parent, iconName, left, top)
    if not self.Icons or not iconName then return nil end
    local fileName = self.Icons.Files and self.Icons.Files[iconName]
    if not fileName then return nil end
    local image = make("createImage", parent)
    if not image then return nil end
    local path = self.Icons:PathOf(fileName)
    local loaded = pcall(function() image.Picture.loadFromFile(path) end)
    if not loaded then
        pcall(function() image.destroy() end)
        return nil
    end
    safeSet(image, "Parent", parent)
    safeSet(image, "Transparent", true)
    safeSet(image, "Stretch", false)
    safeSet(image, "Center", true)
    safeSet(image, "Width", 16)
    safeSet(image, "Height", 16)
    safeSet(image, "Left", left or 6)
    safeSet(image, "Top", top or 5)
    -- A TImage over the button would swallow the click, so hand it on.
    safeSet(image, "Enabled", false)
    return image
end

--
--- ∑ Panel button with a centred label, an optional glyph, hover feedback and
---   an optional pressed state. Live sync and the inspector tabs are modes
---   rather than actions, so they need a look of their own when they are on.
---
---   Four states. Disabled is the button fill with a muted label, hover is the
---   hover fill with the background colour as text, pressed is halfway to the
---   hover fill, and normal is the button fill with the button text colour.
---
---   Without a caption the button is icon only. The glyph then fills the
---   button and draws its picture in the middle, so it stays centred however
---   the alignment stretches the button. An icon that cannot be loaded leaves
---   the first letter of its name instead of an empty square.
--- @param parent userdata
--- @param opts table # Caption, Icon, Width, Height, Align, Left, Top,
---        Anchors, Hint, OnClick, Toggle, Pressed, ModalResult with Form and
---        Spacing.
--- @return userdata, function, function, function, userdata # button,
---         setEnabled, setPressed, setCaption and the caption label
--
function Theme:CreateButton(parent, opts)
    opts = opts or {}
    local button = self:CreatePanel(parent, {
        -- paint() below drives the panel's colour and knows about hover and
        -- pressed as well, so set it once here rather than tracking it twice.
        Color = self:GetPalette().COLOR_BTN,
        BevelOuter = "bvRaised",
        BevelWidth = 1,
        BevelColorKey = "COLOR_BORDER",
        Spacing = opts.Spacing or { Left = 4, Top = 4, Bottom = 4 }
    })
    local width, height = opts.Width or 92, opts.Height or 26
    safeSet(button, "Width", width)
    safeSet(button, "Height", height)
    if opts.Align then
        safeSet(button, "Align", opts.Align)
    else
        safeSet(button, "Left", opts.Left or 0)
        safeSet(button, "Top", opts.Top or 0)
    end
    if opts.Anchors then safeSet(button, "Anchors", opts.Anchors) end
    if opts.Hint then
        safeSet(button, "Hint", opts.Hint)
        safeSet(button, "ShowHint", true)
    end
    safeSet(button, "Cursor", -21) -- crHandPoint

    local iconOnly = opts.Icon ~= nil and (opts.Caption == nil or opts.Caption == "")
    local glyph = opts.Icon
        and self:CreateGlyph(button, opts.Icon,
            iconOnly and math.floor((width - 16) / 2) or 6,
            math.floor((height - 16) / 2))
        or nil
    if glyph then
        -- Aligned rather than placed. An aligned button is stretched by its
        -- parent, and a glyph at a fixed Top would sit off centre in it. The
        -- image draws its picture centred in whatever it is given.
        if iconOnly then
            safeSet(glyph, "Align", "alClient")
        else
            safeSet(glyph, "Align", "alLeft")
            setSpacing(glyph, { Left = 6 })
        end
    end

    local caption = opts.Caption or ""
    if iconOnly and not glyph then caption = tostring(opts.Icon):sub(1, 1) end

    local label = make("createLabel", button)
    safeSet(label, "Parent", button)
    safeSet(label, "Align", "alClient")
    if glyph and not iconOnly then
        -- Leave room for the glyph rather than centring across it. The glyph
        -- already takes six and sixteen pixels, so four more make the gap.
        setSpacing(label, { Left = 4 })
        safeSet(label, "Alignment", "taLeftJustify")
    else
        safeSet(label, "Alignment", "taCenter")
    end
    safeSet(label, "Layout", "tlCenter")
    safeSet(label, "Transparent", true)
    safeSet(label, "Caption", caption)
    if opts.Hint then
        safeSet(label, "Hint", opts.Hint)
        safeSet(label, "ShowHint", true)
    end

    local enabled, pressed = true, opts.Pressed == true
    --- The palette is read here, not captured when the button was made. A
    --- button that cached its colours would keep the theme it was born under
    --- through every hover for the rest of the session.
    local function paint(hovered)
        local palette = self:GetPalette()
        local background, foreground
        if not enabled then
            background, foreground = palette.COLOR_BTN, palette.COLOR_MUTED
        elseif hovered then
            background, foreground = palette.COLOR_BTN_HOVER, palette.COLOR_BG
        elseif pressed then
            -- Halfway to the hover colour. Clearly on, clearly not under the
            -- cursor right now.
            background = Theme.Mix(palette.COLOR_BTN, palette.COLOR_BTN_HOVER, 0.55)
            foreground = palette.COLOR_BG
        else
            background, foreground = palette.COLOR_BTN, palette.COLOR_BTN_TEXT
        end
        safeSet(button, "Color", background)
        safeFont(label, foreground, Theme.FontSize, "[fsBold]")
        pcall(function() button.repaint() end)
    end

    local function click()
        if not enabled then return end
        if opts.Toggle then
            pressed = not pressed
            paint(false)
        end
        if opts.ModalResult and opts.Form then
            safeSet(opts.Form, "ModalResult", opts.ModalResult)
        end
        if type(opts.OnClick) == "function" then opts.OnClick(pressed) end
    end

    safeSet(button, "OnClick", click)
    safeSet(label, "OnClick", click)
    safeSet(button, "OnMouseEnter", function() paint(true) end)
    safeSet(button, "OnMouseLeave", function() paint(false) end)
    safeSet(label, "OnMouseEnter", function() paint(true) end)
    safeSet(label, "OnMouseLeave", function() paint(false) end)

    local function setEnabled(value)
        enabled = value ~= false
        safeSet(button, "Enabled", enabled)
        paint(false)
    end
    local function setPressed(value)
        pressed = value == true
        paint(false)
    end
    local function setCaption(text)
        safeSet(label, "Caption", text or "")
    end
    -- Tracked, so a theme change repaints the button in whatever state it is
    -- currently in rather than resetting it.
    self:Track(function() paint(false) end)
    return button, setEnabled, setPressed, setCaption, label
end

--- A toolbar button's height, and the width of one that carries only an icon.
local TOOL_HEIGHT, TOOL_SQUARE = 28, 30

--- The width of a toolbar button that carries a caption.
local TOOL_WIDE = 104

--
--- ∑ A toolbar button. Wider with a caption, square without one, and aligned
---   into the left stack by default.
---
---   The icon only form is thirty by twenty eight with the glyph centred, so
---   a toolbar of them fits a narrow window. Its hint is the only place its
---   name is written, so Shortcut is added to the hint in brackets unless the
---   hint already carries it. A toggle shows its pressed state in the fill,
---   which an icon does not hide.
---
---   A sideways aligned button is stretched to the height of its parent. When
---   no Spacing is given, the spare height is split above and below it, so
---   the button keeps its own height and sits on the middle line.
--- @param parent userdata
--- @param opts table # What CreateButton takes, plus Shortcut.
--- @return userdata, function, function, function, userdata
--
function Theme:CreateToolButton(parent, opts)
    local copy = {}
    for key, value in pairs(opts or {}) do copy[key] = value end
    local iconOnly = copy.Caption == nil or copy.Caption == ""
    copy.Width = copy.Width or (iconOnly and TOOL_SQUARE or TOOL_WIDE)
    copy.Height = copy.Height or TOOL_HEIGHT
    copy.Align = copy.Align or "alLeft"
    if copy.Shortcut ~= nil and copy.Shortcut ~= "" then
        local shortcut = tostring(copy.Shortcut)
        local hint = copy.Hint and tostring(copy.Hint) or ""
        if not hint:find(shortcut, 1, true) then
            copy.Hint = hint == "" and shortcut or (hint .. " (" .. shortcut .. ")")
        end
    end
    if copy.Spacing == nil and isHorizontalAlign(copy.Align) then
        local available = innerHeight(parent)
        if available and available > copy.Height then
            local spare = available - copy.Height
            local above = math.floor(spare / 2)
            copy.Spacing = { Left = 4, Top = above, Bottom = spare - above }
        end
    end
    return self:CreateButton(parent, copy)
end

--- The drawn check box is this many pixels square, the size of the system one.
local CHECK_SIZE = 13

--- Where the box starts, and the gap between the box and its caption.
local CHECK_LEFT, CHECK_GAP = 2, 6

--- How far the border and the tick sit inside the box. One pixel of border,
--- then two of the input colour around the tick.
local CHECK_BORDER, CHECK_INSET = 1, 2

--- The default height of a check panel, and what a natural width adds after
--- the caption so the last letter is not flush with the edge.
local CHECK_HEIGHT, CHECK_TAIL = 22, 4

--- How far a resting border leans from the background towards the border
--- colour. The same share the canvases use for the boxes they draw.
local CHECK_REST = 0.7

--- How far a disabled border and tick lean towards the muted colour.
local CHECK_DISABLED = 0.5

--
--- ∑ A check box drawn out of panels, so the box follows the palette.
---
---   A native TCheckBox only takes its caption colour. Its glyph is drawn by
---   the system in the system colours, which on a dark theme is a white square
---   in the middle of the window. This draws the box the way a card draws its
---   outline. A thirteen pixel panel in the border tone, a panel in the input
---   colour one pixel inside it, and a tick in the accent two pixels inside
---   that, shown only while it is checked.
---
---   The resting border is the tone the canvases draw their boxes in, most of
---   the way from the background to the border colour. The bundled palette
---   uses one colour for border and accent, so a full border would leave the
---   hover with nothing to change to. Under the mouse the border turns to the
---   accent, and a disabled box has a muted border and a muted tick.
---
---   The box is placed rather than aligned, so it keeps its thirteen pixels
---   and is centred again whenever the panel changes height. The caption sits
---   six pixels to its right on the same middle line. Every part takes the
---   click and the hover, so the caption toggles the box as well.
---
---   Without a Width the panel is as wide as the box and the caption need.
--- @param parent userdata
--- @param options table # Caption, Checked, Hint, Align, Width, Height,
---        ColorKey, Spacing and OnChange.
--- @return userdata, function, function, function, table # panel,
---         setChecked(value, silent), getChecked, setEnabled and the parts,
---         which are Box, Fill, Mark and Label.
--
function Theme:CreateCheck(parent, options)
    options = options or {}
    local colorKey = options.ColorKey or "COLOR_PANEL"
    local height = options.Height or CHECK_HEIGHT
    local caption = options.Caption == nil and "" or tostring(options.Caption)
    local width = options.Width
    if width == nil then
        width = CHECK_LEFT + CHECK_SIZE + CHECK_GAP + CHECK_TAIL
            + math.ceil(textLength(caption) * self:CharWidth(Theme.FontSize))
    end
    local panel = self:CreatePanel(parent, {
        Align = options.Align,
        Width = width,
        Height = height,
        ColorKey = colorKey,
        Spacing = options.Spacing
    })
    local palette = self:GetPalette()
    local box = self:CreatePanel(panel, {
        Color = Theme.Mix(palette[colorKey] or palette.COLOR_PANEL, palette.COLOR_BORDER, CHECK_REST),
        Width = CHECK_SIZE, Height = CHECK_SIZE
    })
    safeSet(box, "Left", CHECK_LEFT)
    safeSet(box, "Top", math.max(0, math.floor((height - CHECK_SIZE) / 2)))
    local fill = self:CreatePanel(box, {
        Align = "alClient", ColorKey = "COLOR_INPUT", Spacing = { Around = CHECK_BORDER }
    })
    local mark = self:CreatePanel(fill, {
        Align = "alClient", Color = palette.COLOR_ACCENT, Spacing = { Around = CHECK_INSET }
    })
    local label = make("createLabel", panel)
    safeSet(label, "Parent", panel)
    safeSet(label, "Caption", caption)
    safeSet(label, "Transparent", true)
    safeSet(label, "Align", "alClient")
    safeSet(label, "Layout", "tlCenter")
    setSpacing(label, { Left = CHECK_LEFT + CHECK_SIZE + CHECK_GAP })

    local checked, enabled, hovered = options.Checked == true, true, false

    --- The one painter for every state. Registered once, and it reads the
    --- state out of the upvalues, so a theme change repaints whatever the box
    --- shows right now.
    local function paint()
        local active = self:GetPalette()
        local base = active[colorKey] or active.COLOR_PANEL
        local border, tick, text
        if not enabled then
            border = Theme.Mix(base, active.COLOR_MUTED, CHECK_DISABLED)
            tick, text = border, active.COLOR_MUTED
        else
            border = hovered and active.COLOR_ACCENT
                or Theme.Mix(base, active.COLOR_BORDER, CHECK_REST)
            tick, text = active.COLOR_ACCENT, active.COLOR_TEXT
        end
        safeSet(box, "Color", border)
        safeSet(mark, "Color", tick)
        safeSet(mark, "Visible", checked)
        safeFont(label, text)
        pcall(function() box.repaint() end)
    end

    local function setChecked(value, silent)
        local wanted = value == true
        local changed = wanted ~= checked
        checked = wanted
        paint()
        if changed and not silent and type(options.OnChange) == "function" then
            options.OnChange(checked)
        end
    end

    local function toggle()
        if not enabled then return end
        setChecked(not checked)
    end

    local function hover(value)
        local wanted = value == true and enabled
        if wanted == hovered then return end
        hovered = wanted
        paint()
    end

    --- Puts the box back on the middle line of whatever height the panel has.
    local function centre()
        local available = innerHeight(panel) or height
        safeSet(box, "Top", math.max(0, math.floor((available - CHECK_SIZE) / 2)))
    end

    for _, control in ipairs({ panel, box, fill, mark, label }) do
        safeSet(control, "OnClick", toggle)
        safeSet(control, "OnMouseEnter", function() hover(true) end)
        safeSet(control, "OnMouseLeave", function() hover(false) end)
        if options.Hint then
            safeSet(control, "Hint", options.Hint)
            safeSet(control, "ShowHint", true)
        end
    end
    safeSet(panel, "OnResize", centre)

    local function setEnabled(value)
        enabled = value ~= false
        if not enabled then hovered = false end
        paint()
    end
    self:Track(paint)

    return panel, setChecked, function() return checked end, setEnabled,
        { Box = box, Fill = fill, Mark = mark, Label = label }
end

--------------------------------------------------------
--                Field rows and flow bars            --
--------------------------------------------------------

--- A field row's height and the width of its label column.
local FIELD_HEIGHT, FIELD_LABEL_WIDTH = 28, 104

--- The space in front of a field label, and what the label keeps clear of the
--- frame after it.
local FIELD_LABEL_PAD, FIELD_LABEL_GAP = 6, 6

--- The space between one field row and the next.
local FIELD_ROW_GAP = 4

--- What the text inside a frame keeps clear of the frame's sides.
local FIELD_INNER_PAD = 6

--- The frame's border, and how far a read only border leans from the row
--- background towards the border colour.
local FIELD_BORDER, FIELD_READONLY = 1, 0.45

--- How far a combo box is pushed past the clip panel on each side, which is
--- the rim Windows keeps around the item, so the clip shows the item and the
--- arrow button and none of the rim. Then the height a combo box is taken to
--- have before it can say, one Consolas line and eight pixels.
local COMBO_CLIP, COMBO_HEIGHT = COMBO_RIM, 23

--
--- ∑ A labelled input in the shape of the Teleporter's field rows.
---
---   A fixed label column in the muted colour with a small pad in front, then
---   the input in a frame. The frame is a panel in the border colour with a
---   panel in the input colour one pixel inside it, and the input sits in that
---   borderless and themed, so the frame is the only border there is. The row
---   and its frame are built in reading order, the label first because alLeft
---   puts the first created control at the left when the rest is alClient.
---
---   Kind picks the input.
---     * edit is a themed edit whose text sits on the frame's middle line.
---       Placeholder goes to its TextHint and ReadOnly keeps it selectable,
---       which is what makes a resolved address copyable.
---     * combo is a read only combo box that draws its own items. Its rim is
---       pushed outside a clip panel so it does not draw a second border
---       inside the frame, and the clip keeps the inner pad on both sides the
---       way an edit does, so the item starts where an edit's text starts and
---       the arrow button ends where it ends. Only the arrow button stays
---       native.
---     * check is a drawn check box with Caption beside it and no frame, its
---       box lined up with where the text of an edit starts.
---
---   OnChange is told the new value first. The edit's text, the combo box's
---   ItemIndex, or whether the check is ticked. It is assigned after the
---   initial value, so building the row never calls it.
--- @param parent userdata
--- @param options table # Label, LabelWidth, Height, Kind, Items, ItemIndex,
---        Placeholder, Text, Caption, Checked, Hint, ReadOnly, Align, Width,
---        ColorKey, Spacing and OnChange.
--- @return userdata, userdata, function, table # row, the input control,
---         setEnabled, and the parts, which are Label, Frame, Fill, Clip,
---         Input, Get(), Set(value, silent) and SetLabel(text).
--
function Theme:CreateFieldRow(parent, options)
    options = options or {}
    local kind = options.Kind or "edit"
    local height = options.Height or FIELD_HEIGHT
    local labelWidth = options.LabelWidth or FIELD_LABEL_WIDTH
    local colorKey = options.ColorKey or "COLOR_INPUT"
    local readOnly = options.ReadOnly == true
    local onChange = options.OnChange
    local row = self:CreatePanel(parent, {
        Align = options.Align or "alTop",
        Height = height,
        Width = options.Width,
        ColorKey = colorKey,
        Spacing = options.Spacing or { Bottom = FIELD_ROW_GAP }
    })
    local parts = {}

    local label
    if labelWidth > 0 then
        label = make("createLabel", row)
        safeSet(label, "Parent", row)
        -- Off before the width, or the label sizes itself to its caption.
        safeSet(label, "AutoSize", false)
        safeSet(label, "Align", "alLeft")
        safeSet(label, "Width", math.max(0, labelWidth - FIELD_LABEL_PAD))
        safeSet(label, "Layout", "tlCenter")
        safeSet(label, "Transparent", true)
        setSpacing(label, { Left = FIELD_LABEL_PAD })
        self:Track(function() safeFont(label, self:GetPalette().COLOR_MUTED) end)
    end
    local function setLabel(text)
        if not label then return "" end
        return (self:FitText(label, text,
            labelWidth - FIELD_LABEL_PAD - FIELD_LABEL_GAP, options.Hint))
    end
    setLabel(options.Label)
    parts.Label, parts.SetLabel = label, setLabel

    if kind == "check" then
        local panel, setChecked, getChecked, enable, check = self:CreateCheck(row, {
            Caption = options.Caption or options.Text or "",
            Checked = options.Checked == true,
            Hint = options.Hint,
            Align = "alClient",
            Height = height,
            ColorKey = colorKey,
            -- The frame border and the inner pad, less where the box starts.
            Spacing = { Left = FIELD_BORDER + FIELD_INNER_PAD - CHECK_LEFT },
            OnChange = onChange
        })
        parts.Input, parts.Check = panel, check
        parts.Get = getChecked
        parts.Set = setChecked
        return row, panel, enable, parts
    end

    local frame = self:CreatePanel(row, {
        Align = "alClient", Color = self:GetPalette().COLOR_BORDER
    })
    local fill = self:CreatePanel(frame, {
        Align = "alClient", ColorKey = "COLOR_INPUT", Spacing = { Around = FIELD_BORDER }
    })
    parts.Frame, parts.Fill = frame, fill
    local enabled = true
    local input

    if kind == "combo" then
        local clip = self:CreatePanel(fill, { ColorKey = "COLOR_INPUT" })
        input = self:CreateCombo(clip, {
            Items = options.Items,
            ItemIndex = options.ItemIndex,
            Hint = options.Hint,
            OnChange = type(onChange) == "function" and function(sender)
                onChange(readNumber(input, "ItemIndex") or -1, sender)
            end or nil
        })
        if readOnly then safeSet(input, "Enabled", false) end
        local placing = false
        --- Centres the clip panel in the frame and pushes the rim Windows
        --- keeps around the combo box's item just outside it. The clip keeps
        --- the inner pad on both sides, the same an edit keeps, so the arrow
        --- button ends where the text of an edit below it would. A frame that
        --- does not know its width yet keeps its heights and waits for the
        --- resize that comes with show.
        local function place()
            if placing then return end
            placing = true
            pcall(function()
                local fillWidth = innerWidth(fill) or 0
                local fillHeight = innerHeight(fill) or 0
                if fillHeight <= 0 then fillHeight = height - 2 * FIELD_BORDER end
                local comboHeight = readNumber(input, "Height") or 0
                if comboHeight <= 0 then comboHeight = COMBO_HEIGHT end
                local clipHeight = math.max(1, math.min(fillHeight, comboHeight - 2 * COMBO_CLIP))
                safeSet(clip, "Left", FIELD_INNER_PAD)
                safeSet(clip, "Top", math.floor((fillHeight - clipHeight) / 2))
                safeSet(clip, "Height", clipHeight)
                safeSet(input, "Left", -COMBO_CLIP)
                safeSet(input, "Top", -math.floor((comboHeight - clipHeight) / 2))
                if fillWidth > 0 then
                    local clipWidth = math.max(1, fillWidth - 2 * FIELD_INNER_PAD)
                    safeSet(clip, "Width", clipWidth)
                    safeSet(input, "Width", clipWidth + 2 * COMBO_CLIP)
                end
            end)
            placing = false
        end
        safeSet(fill, "OnResize", place)
        -- The combo box settles its own height once its handle exists, which
        -- can be after the frame was sized, so a change there places it again.
        safeSet(input, "OnChangeBounds", place)
        place()
        parts.Clip = clip
        parts.Get = function() return readNumber(input, "ItemIndex") or -1 end
        parts.Set = function(value) safeSet(input, "ItemIndex", tonumber(value) or -1) end
    else
        local _, lineHeight = self:TextMetrics(Theme.FontSize)
        local inner = height - 2 * FIELD_BORDER
        local above = math.max(0, math.floor((inner - lineHeight) / 2))
        input = self:CreateEdit(fill, {
            Align = "alClient",
            Text = options.Text,
            Placeholder = options.Placeholder,
            Hint = options.Hint,
            Spacing = { Left = FIELD_INNER_PAD, Right = FIELD_INNER_PAD, Top = above },
            OnChange = type(onChange) == "function" and function(sender)
                local ok, text = pcall(function() return input.Text end)
                onChange(ok and text or "", sender)
            end or nil
        })
        safeSet(input, "AutoSize", false)
        if readOnly then safeSet(input, "ReadOnly", true) end
        parts.Get = function()
            local ok, text = pcall(function() return input.Text end)
            return ok and tostring(text or "") or ""
        end
        parts.Set = function(value)
            safeSet(input, "Text", value == nil and "" or tostring(value))
        end
    end
    parts.Input = input

    if options.Hint then
        for _, control in ipairs({ frame, fill }) do
            safeSet(control, "Hint", options.Hint)
            safeSet(control, "ShowHint", true)
        end
    end

    --- The frame says what the input will do. The border colour when it
    --- takes typing, a quieter lean when it is read only, and muted when it
    --- is disabled.
    local function paintFrame()
        local palette = self:GetPalette()
        local base = palette[colorKey] or palette.COLOR_INPUT
        local color = palette.COLOR_BORDER
        if not enabled then
            color = Theme.Mix(base, palette.COLOR_MUTED, CHECK_DISABLED)
        elseif readOnly then
            color = Theme.Mix(base, palette.COLOR_BORDER, FIELD_READONLY)
        end
        safeSet(frame, "Color", color)
    end
    self:Track(paintFrame)

    local function setEnabled(value)
        enabled = value ~= false
        safeSet(input, "Enabled", enabled and not (kind == "combo" and readOnly))
        paintFrame()
    end

    return row, input, setEnabled, parts
end

--- The space between two controls on a flow bar, and around all of them.
local FLOW_GAP, FLOW_PADDING = 6, 4

--- Reads a padding that is either one number or a table of sides.
local function paddingOf(value)
    if type(value) == "table" then
        local around = tonumber(value.Around) or 0
        return tonumber(value.Left) or around, tonumber(value.Top) or around,
            tonumber(value.Right) or around, tonumber(value.Bottom) or around
    end
    local all = tonumber(value) or FLOW_PADDING
    return all, all, all, all
end

--
--- ∑ A bar that lays its controls out left to right and wraps them onto a new
---   line when the width runs out, then takes the height its lines need.
---
---   Alignment cannot do this. A row of alLeft and alRight buttons that is
---   wider than its parent slides the two stacks under each other, which is
---   how Apply and Revert vanished under Paste path. Here every control is
---   placed by hand, in the order it was added, and a control that does not
---   fit starts the next line. A line is as high as its tallest control and
---   the others sit on its middle line.
---
---   add takes the control out of any alignment and clears its border
---   spacing, so Gap and Padding are the only spacing there is. A hidden
---   control takes no room. The bar lays itself out again on every resize,
---   and relayout does it on demand, after a control was shown or hidden.
---   Setting its own height fires one more resize, which finds nothing to
---   change and stops.
---
---   Until the bar knows its width everything goes on one line.
--- @param parent userdata
--- @param options table|nil # Align, Gap, Padding as a number or as Left,
---        Top, Right and Bottom, ColorKey, Height and Spacing.
--- @return userdata, function, function # bar, add(control) which hands the
---         control back, relayout() which answers the height and the number
---         of lines
--
function Theme:CreateFlowBar(parent, options)
    options = options or {}
    local gap = tonumber(options.Gap) or FLOW_GAP
    local padLeft, padTop, padRight, padBottom = paddingOf(options.Padding)
    local align = options.Align or "alTop"
    local bar = self:CreatePanel(parent, {
        Align = align,
        Height = options.Height or (padTop + padBottom),
        ColorKey = options.ColorKey or "COLOR_INPUT",
        Spacing = options.Spacing
    })
    local children = {}
    local busy = false
    local lastHeight, lastLines = padTop + padBottom, 0

    local function arrange()
        local width = innerWidth(bar) or 0
        local limit = width > 0 and (width - padRight) or math.huge
        local x, y = padLeft, padTop
        local lineHeight, line, lines = 0, {}, 0

        local function flush()
            for _, item in ipairs(line) do
                safeSet(item.Control, "Left", item.X)
                safeSet(item.Control, "Top", y + math.floor((lineHeight - item.Height) / 2))
            end
        end

        for _, control in ipairs(children) do
            if isShown(control) then
                local w = readNumber(control, "Width") or 0
                local h = readNumber(control, "Height") or 0
                if #line > 0 and x + w > limit then
                    flush()
                    y = y + lineHeight + gap
                    x, lineHeight, line = padLeft, 0, {}
                end
                if #line == 0 then lines = lines + 1 end
                line[#line + 1] = { Control = control, X = x, Height = h }
                x = x + w + gap
                if h > lineHeight then lineHeight = h end
            end
        end
        flush()
        local total = padTop + padBottom
        if lines > 0 then total = y + lineHeight + padBottom end
        if align ~= "alClient" and readNumber(bar, "Height") ~= total then
            safeSet(bar, "Height", total)
        end
        return total, lines
    end

    local function relayout()
        if busy then return lastHeight, lastLines end
        busy = true
        local ok, total, lines = pcall(arrange)
        busy = false
        if ok then lastHeight, lastLines = total, lines end
        return lastHeight, lastLines
    end

    local function add(control)
        if control == nil then return nil end
        safeSet(control, "Parent", bar)
        safeSet(control, "Align", "alNone")
        setSpacing(control, { Around = 0, Left = 0, Top = 0, Right = 0, Bottom = 0 })
        children[#children + 1] = control
        relayout()
        return control
    end

    safeSet(bar, "OnResize", function() relayout() end)
    return bar, add, relayout
end

--------------------------------------------------------
--                       Menus                        --
--------------------------------------------------------

--
--- ∑ A popup menu with icons.
---
---   The item is created with the MENU as its owner and then added to the
---   parent's item list. Ownership decides who frees it, not who shows it, so
---   destroying the menu takes the whole tree with it.
---
---   Each item is built inside ONE pcall. An earlier version in a sibling
---   wrapped every individual assignment in its own pcall, which produced the
---   worst possible outcome, a menu that rendered its captions perfectly and
---   did nothing at all when clicked.
---
---   Icons resolve through SubMenuImages on the parent, so AttachTo runs on
---   menu.Items before any child sets an ImageIndex. The control it attaches
---   to must be a WINDOWED one. A TGraphicControl has no window handle, so
---   WM_CONTEXTMENU goes to its nearest windowed ancestor and a menu hung off
---   the child would never be shown.
---
---   Shortcut is display only. Cheat Engine does not dispatch a popup menu's
---   shortcuts, so the window keeps its own key handler.
--- @param control userdata # The control the menu belongs to.
--- @param options table|nil # Attach false builds the menu without hanging it
---        off the control.
--- @return table|nil # Menu, Add, Attach, Enable, Check and Entries.
--
function Theme:CreatePopupMenu(control, options)
    options = options or {}
    local createMenu = rawget(_G, "createPopupMenu")
    local createItem = rawget(_G, "createMenuItem")
    if type(createMenu) ~= "function" or type(createItem) ~= "function" then return nil end
    local ok, menu = pcall(createMenu, control)
    if not ok or not menu then return nil end
    if options.Attach ~= false then
        pcall(function() control.PopupMenu = menu end)
    end
    if self.Icons then pcall(function() self.Icons:AttachTo(menu.Items) end) end

    local entries = {}
    local function add(caption, onClick, opts)
        opts = opts or {}
        local parent = opts.Parent or menu.Items
        local item
        local built = pcall(function()
            item = createItem(menu)
            item.Caption = caption
            if opts.Shortcut then item.Shortcut = opts.Shortcut end
            if opts.Hint then item.Hint = opts.Hint end
            if opts.Checked ~= nil then
                item.AutoCheck = false
                item.Checked = opts.Checked == true
            end
            if onClick then item.OnClick = function() onClick(item) end end
            parent.add(item)
        end)
        if not built then return nil end
        if self.Icons and opts.Icon then
            if opts.Parent then pcall(function() self.Icons:AttachTo(opts.Parent) end) end
            self.Icons:Apply(item, opts.Icon)
        end
        if caption ~= "-" then entries[opts.Key or caption] = item end
        return item
    end
    local function enable(key, value)
        local item = entries[key]
        if item then pcall(function() item.Enabled = value == true end) end
    end
    local function check(key, value)
        local item = entries[key]
        if item then pcall(function() item.Checked = value == true end) end
    end
    local function attach(other) pcall(function() other.PopupMenu = menu end) end
    return { Menu = menu, Add = add, Attach = attach, Enable = enable,
             Check = check, Entries = entries }
end

--------------------------------------------------------
--                      Dialogs                       --
--------------------------------------------------------

--
--- ∑ A themed one line prompt.
---
---   inputQuery would be one call, but it is a native dialog. It ignores the
---   palette entirely and its return convention differs between Cheat Engine
---   builds. This is the modal pattern the rest of the Manifold windows use.
---
---   Enter accepts and Escape cancels, handled here because the buttons are
---   panels and the LCL has no Default or Cancel button to act on.
--- @param caption string
--- @param prompt string
--- @param default string|nil
--- @return string|nil # nil when cancelled.
--
function Theme:AskText(caption, prompt, default)
    local palette = self:GetPalette()
    local form = make("createForm", false)
    if not form then return nil end
    safeSet(form, "Caption", caption or "Manifold")
    safeSet(form, "BorderStyle", "bsDialog")
    safeSet(form, "Position", "poScreenCenter")
    safeSet(form, "Width", 440)
    safeSet(form, "Height", 150)
    safeSet(form, "Color", palette.COLOR_BG)
    safeFont(form, palette.COLOR_TEXT)
    -- A modal prompt lives for one call, so nothing it creates is worth a
    -- later restyle. ForgetSince at the end drops what its controls
    -- registered, before they are freed.
    local mark = self:Mark()

    local content = self:CreatePanel(form, {
        Align = "alClient", ColorKey = "COLOR_BG", Spacing = { Around = 12 }
    })
    local label = self:CreateLabel(content, prompt or "", "muted")
    safeSet(label, "Align", "alTop")
    safeSet(label, "Height", 20)
    local edit = self:CreateEdit(content, { Align = "alTop", Text = default or "" })
    setSpacing(edit, { Top = 8 })

    local bar = self:CreateButtonBar(form, 46)
    local result = nil
    local function accept()
        local ok, text = pcall(function() return edit.Text end)
        result = ok and text or nil
        pcall(function() form.close() end)
    end
    -- Cancel is built first so it lands at the right edge, with OK beside it.
    self:CreateButton(bar, {
        Caption = "Cancel", Align = "alRight", Width = 96,
        OnClick = function() pcall(function() form.close() end) end
    })
    self:CreateButton(bar, {
        Caption = "OK", Align = "alRight", Width = 96, OnClick = accept
    })
    pcall(function()
        form.KeyPreview = true
        form.OnKeyDown = function(_, key)
            if key == 13 then
                accept()
            elseif key == 27 then
                result = nil
                pcall(function() form.close() end)
            end
            return key
        end
    end)
    pcall(function() form.showModal() end)
    pcall(function() form.destroy() end)
    self:ForgetSince(mark)
    return result
end

return Theme
