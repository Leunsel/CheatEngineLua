local NAME = "Manifold.TeleporterMap.lua"
local AUTHOR = {"Leunsel", "LeFiXER"}
local VERSION = "1.3.3"
local DESCRIPTION = "Manifold Framework Teleporter Map"

--[[
    ∂ v1.3.3 (2026-09-13)
        The menu bar is dark all the way through. A menu made in
        Lua misses the step that gives Cheat Engine's own menus
        their dark background, so the dropdowns had a light
        frame and light separators around dark entries. The
        menu strip asks Manifold.Forms for that step once it is
        built, and again when the Area submenu gets a changed
        list of areas, because a submenu that did not exist yet
        has no background of its own.

    ...

    ∂ v1.0.0 (2026-09-10)
        First release. An interactive map over the Teleporter's
        saves, painted on a canvas. A grid that rescales with the
        zoom, one marker per save, the player's live position
        with a trail behind it, and a teleport on a single click.
        The window is built through Manifold.Forms, so it follows
        the table's theme like every other Manifold window, and
        the canvas derives its colours from the same palette.

        Which two axes make the map is not fixed. A 3D game draws
        the two that are not the up axis, which the Teleporter
        already names through Settings.YCoordinateIndex, and a 2D
        game draws both of its axes. The plane can be changed at
        runtime, and the view is remembered per target process.
]]--

TeleporterMap = {
    --- Which two components of a position make the map, as indexes into the
    --- position. nil means derived: the up axis the Teleporter lifts is left
    --- out and the remaining two are used in memory order. A 2D game has no
    --- up axis and draws both of its components.
    ---     teleporterMap.Plane = { Horizontal = 1, Vertical = 3 }
    --- Flip a direction when the game's north points the other way. With
    --- FlipVertical off, a growing vertical value moves UP the screen, which
    --- is what a map reader expects and not what a screen does.
    Plane = {
        Horizontal     = nil,
        Vertical       = nil,
        FlipHorizontal = false,
        FlipVertical   = false,
    },

    --- Which of the game's maps the window shows. nil is every area,
    --- false is the saves that have none, a string is that area. Which
    --- area a save belongs to is the Teleporter's answer, so a table
    --- declares its areas there (teleporter.Areas.Names).
    Area = {
        Selected = nil,
    },

    View = {
        --- Pixels per world unit. nil fits every save on first open.
        Zoom             = nil,
        MinZoom          = 0.0005,
        MaxZoom          = 400,
        ZoomStep         = 1.25,
        --- How long a notch takes to arrive, in milliseconds. A notch is a
        --- quarter of the scale, and landing it in one frame is what reads
        --- as a jerk. 0 applies it at once, which is what the old map did
        --- and what ZoomBy still does for a script.
        ZoomAnimationMs  = 120,
        --- The animation's own frame time. It is a second timer on purpose:
        --- the window's other one polls the player, and drawing frames must
        --- not make it read memory six times as often.
        ZoomFrameMs      = 16,
        --- How far apart grid lines should sit on screen. The world spacing
        --- is the nearest 1, 2 or 5 times a power of ten that lands here.
        GridTargetPixels = 72,
        FollowPlayer     = false,
        ShowGrid         = true,
        ShowRulers       = true,
        ShowLabels       = true,
        ShowTrail        = true,
        ShowDetails      = true,
        --- A single click on a marker teleports. Off, a double click does.
        OneClickTeleport = true,
        --- Every teleport the map starts asks first. On by default because
        --- the map teleports on a single click, which is easy to do by
        --- accident while aiming at a crowded spot.
        ConfirmTeleport  = true,
        --- Markers carry the height of their save in their size and their
        --- shade: the highest save is drawn at MarkerRadius in the most
        --- recessive step of the ramp, the lowest at HeightScaleMax times
        --- it in the accent itself. Both come from one mirrored number, so
        --- size and shade cannot disagree, and the legend in the corner
        --- shows the pair. Off, every marker is the plain accent at the
        --- base radius and there is no legend. A 2D table has no height.
        ScaleByHeight    = true,
        HeightScaleMax   = 1.5,
        --- Teleport Here and Add Save Here take their height from the
        --- nearest save within this many world units on the map plane,
        --- because a save is a height somebody stood at. 0 disables it;
        --- Ctrl+Shift+click keeps the player's height for one jump.
        HeightSnapRadius = 25,
        --- Dims every save further than this from the player's height, in
        --- world units, so one floor of a building is one map. 0 is off.
        HeightBand       = 0,
        MarkerRadius     = 3,
        --- The reach of a click, which is deliberately wider than the mark:
        --- in a crowd the pointer only has to be nearer this save than the
        --- next one, and a marker drawn larger adds its own HitExtra.
        HitRadius        = 13,
        FontSize         = 9,
        --- A label tries eight places around its disc and takes the first
        --- that is clear of the marks, the readouts, the labels already
        --- placed and the edge of the map. One that fits nowhere is
        --- dropped, never clipped and never drawn over a mark. This caps
        --- how many are placed per frame; the status bar says how many of
        --- the names a frame managed to place.
        LabelLimit       = 150,
    },

    Player = {
        --- Milliseconds between reads of the player's position.
        RefreshInterval    = 100,
        --- Points kept behind the player.
        TrailLength        = 400,
        --- A move shorter than this, in world units, adds no trail point.
        TrailMinDistance   = 0.25,
        --- A jump longer than this starts a new trail segment rather than
        --- drawing a line across the map. Teleports are game-scale, so this
        --- is a setting and not a constant.
        TrailBreakDistance = 25,
        --- After this many failed reads in a row the poll slows down to one
        --- read per ten ticks. A game in a loading screen has no valid
        --- pointer, and ten reads a second of nothing is wasted.
        FailureBackoff     = 5,
    },

    Settings = {
        --- Remember zoom, centre, plane, the toggles, the shown area with
        --- its per-area cameras and the height band, per target process.
        PersistView  = true,
        ViewFileName = "Teleporter.%s.Map.txt",
    },
}
TeleporterMap.__index = TeleporterMap

local MODULE_PREFIX = "[TeleporterMap]"
local FILTER_EDIT_NAME = "ManifoldTeleporterMapFilter"
local DETAIL_EDIT_PREFIX = "ManifoldTeleporterMapDetail"
local AREA_COMBO_NAME = "ManifoldTeleporterMapArea"

--
--- ∑ What keeps a crowded map readable, in pixels.
---   MARKER_HALO is the ring of surface colour every disc is drawn on, so
---   two saves that touch still read as two saves. DISC_FLOOR is how far a
---   disc may shrink when the saves are closer together than it is wide.
---   EDGE_MARGIN is the one margin every box the map draws keeps from the
---   edge, and CHROME_INSET the deeper one the corner readouts sit at.
--
local MARKER_HALO      = 2
local MARKER_MIN       = 2
local DISC_FLOOR       = 0.62
local EDGE_MARGIN      = 6
local CHROME_INSET     = 12

--
--- ∑ What the label placer and the pile finder are allowed to cost. Both
---   run in the paint path ten times a second, so both are bucketed on a
---   screen grid: CELL is that grid, CELL_LIMIT how many rectangles one
---   cell holds before it counts as full. That is the bound, in place of a
---   per-frame budget: a candidate costs the same whether five hundred
---   saves or five sit on one pixel, and which names a frame places does
---   not depend on how far through the frame the placer got.
--
local CELL             = 48
local CELL_LIMIT       = 24
--- A bucket with this many discs in it is a pile whatever the exact
--- distances are, and is joined without measuring them.
local CLUSTER_DENSE    = 6
--- Below three, a heap is something the eye can count on its own.
local CLUSTER_MIN      = 3
--- What it costs the hover card to cover one disc of the very heap the
--- pointer is in, in units of "one ordinary mark covered". The card answers
--- what is under the pointer; covering the rest of that answer is the one
--- placement it must not choose, so a cell full of lone saves is cheaper.
local CARD_PILE_COST   = 12
--- How much a card may cover before it says less than it hides, and drops
--- its stack list to two names to fit somewhere quieter.
local CARD_BUSY        = 8
--- How far around the pointer counts as "the saves the card is talking
--- about". Wider than the stack list's own reach, because the heap a pointer
--- is in rarely ends where the hit test does.
local CARD_GUARD       = 48
--- How far a count may reach for its heap with a line. Further than this the
--- line is a diagonal across other people's saves, and the badge is better
--- off saying nothing: it was placed as near its pile as the map allowed.
local LEADER_MAX       = 56
--- An area names itself on the map once it has this many saves drawn.
local AREA_CAPTION_MIN = 4

--
--- ∑ The height colour ramp. Four steps read as four; more read as noise.
---   RAMP_STEP is the OKLab lightness between two steps - 0.075, comfortably
---   over the 0.06 an eye needs - and RAMP_FLOOR the contrast the most
---   recessive step must still have against the canvas. A palette that
---   cannot hold four steps that way gets three, or two, or none at all.
---
---   RAMP_FLOOR is 2.6 and not the bare 2.0 a mark has to clear, because the
---   two channels compound at the quiet end: the most recessive step is also
---   the SMALLEST disc, and on a crowded map it is drawn smaller again. A
---   step that is only just visible as a 15 px disc is not visible as a 7 px
---   one. The step count gives way instead - Dark-Dark-Hell, the tightest
---   bundled palette, draws three steps rather than a fourth nobody can find.
---
---   TEXT_FLOOR is what a number the map asks a reader to trust must clear
---   against the canvas. Scenery - rules, grid, badge outlines - is exempt;
---   it is not being read.
--
local HEIGHT_BANDS     = 4
local RAMP_STEP        = 0.075
local RAMP_FLOOR       = 2.6
local TEXT_FLOOR       = 4.5

--
--- ∑ Manifold.Bootstrap handshake. Uses the framework core when the cheat
---   table has loaded it, and degrades to an inert stub when it has not, so
---   this module stays loadable on its own. Identical in every module - this
---   is the one duplication the design costs, and it is irreducible: something
---   has to reach the loader before the loader exists.
--
local BOOTSTRAP = rawget(_G, "ManifoldBootstrap") or {
    Declare = function(spec) return spec end,
    Resolve = function() return true end,
    Ready   = function(_, instance) return instance end,
    Once    = function(_, fn) if type(fn) == "function" then pcall(fn) end return true end,
}

--
--- ∑ This module's identity and its dependency contract, in one place.
---     required = true -> New() refuses rather than pretending to be ready
---     runtime  = true -> documented only; never loaded here, never ordered on
--
local MODULE = BOOTSTRAP.Declare({
    class = "TeleporterMap", global = "teleporterMap",
    name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION,
    prefix = MODULE_PREFIX,
    deps = {
        { "logger",     required = true },
        { "forms",      required = true },
        { "teleporter", required = true },
        { "customIO" },
        { "json",  runtime = true },
        { "utils", runtime = true },
        { "ui",    runtime = true },
    },
})

function TeleporterMap:New(config)
    local instance = setmetatable({}, self)
    self:CheckDependencies()
    instance.Name = NAME or "Unnamed Module"
    -- The option tables are copied per instance, so a table that edits
    -- teleporterMap.View.ShowGrid in place edits its own copy and not the
    -- class defaults every later instance would inherit.
    for _, key in ipairs({ "Plane", "Area", "View", "Player", "Settings" }) do
        local copy = {}
        for name, value in pairs(self[key]) do copy[name] = value end
        instance[key] = copy
    end
    local rejected = {}
    for key, value in pairs(config or {}) do
        if self[key] ~= nil then
            -- Only the option tables copied above merge key by key. rawget
            -- sees the per-instance copy and not the class table, so a config
            -- naming any other table replaces it on the instance instead of
            -- writing into the module for every instance.
            if type(value) == "table" and type(rawget(instance, key)) == "table" then
                for name, item in pairs(value) do instance[key][name] = item end
            else
                instance[key] = value
            end
        else
            rejected[#rejected + 1] = { tostring(key), type(value) }
        end
    end
    if #rejected > 0 then
        logger:WarningBlock(MODULE_PREFIX .. " Ignored " .. #rejected .. " unknown config properties", rejected)
    end
    instance.Camera = { X = 0, Y = 0, Scale = tonumber(instance.View.Zoom) or 1, Fitted = instance.View.Zoom ~= nil }
    instance.Markers = {}
    instance.Trail = {}
    return BOOTSTRAP.Ready(MODULE, instance)
end
registerLuaFunctionHighlight('New')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table # {name, version, author, description}
--
function TeleporterMap:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Logs module metadata through the shared logger.
--
function TeleporterMap:PrintModuleInfo()
    local info = self:GetModuleInfo()
    local author = type(info.author) == "table" and table.concat(info.author, ", ") or tostring(info.author)
    logger:InfoBlock("Module Info : " .. tostring(info.name), {
        { "Version",     info.version },
        { "Author",      author },
        { "Description", info.description },
    }, { indent = "\t" })
end
registerLuaFunctionHighlight('PrintModuleInfo')

--
--- ∑ One dependency check, through the framework core.
--
function TeleporterMap:CheckDependencies()
    return BOOTSTRAP.Resolve(MODULE)
end
registerLuaFunctionHighlight('CheckDependencies')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

local function trimString(value)
    if value == nil then return "" end
    return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function isFinite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--
--- ∑ Mixes two packed colours channel by channel. Cheat Engine colours are
---   BGR, but the same order goes in as comes out, so the function does not
---   need to know that.
---
---   Channels are taken apart with division and modulo rather than with the
---   shift operators. & | >> are a PARSE error on Lua 5.1, not a runtime one,
---   so one of them anywhere in this file would stop the whole module
---   loading there - and the rest of the file is written to load under any
---   Lua the framework runs on (see ARC_TANGENT below). Arithmetic on bytes
---   is exact in a double, so nothing is lost by saying it this way.
--- @param from number # The colour at t = 0.
--- @param to number # The colour at t = 1.
--- @param t number # 0 to 1.
--- @return number
--
local function mixColor(from, to, t)
    from = math.floor(tonumber(from) or 0)
    to = math.floor(tonumber(to) or 0)
    local mixed, scale = 0, 1
    for _ = 1, 3 do
        local a = math.floor(from / scale) % 256
        local b = math.floor(to / scale) % 256
        local c = math.floor(a + (b - a) * t + 0.5)
        mixed = mixed + clamp(c, 0, 255) * scale
        scale = scale * 256
    end
    return mixed
end

--------------------------------------------------------
--                  Colour, in OKLab                  --
--------------------------------------------------------

--
--- ∑ A height ramp has to be one hue with evenly spaced lightness, and it
---   has to hold on seven themes whose accents are a gold, a cyan, a pink,
---   an orange, two greens and a lilac. Channel arithmetic cannot do that:
---   mixing an accent toward the surface steps evenly in numbers and
---   unevenly to the eye, which is why four mixed steps flatten into one
---   colour at the size a marker is really drawn. OKLab's L is close to
---   what the eye calls lightness, so the ramp is built there, out of the
---   accent's own hue and chroma.
---
---   This runs once per theme, from Colors(), and never inside a frame.
--

--- Packed Cheat Engine colours are 0x00BBGGRR: red is the low byte. In
--- arithmetic, for the reason given at mixColor.
local function unpackColor(color)
    color = math.floor(tonumber(color) or 0) % 16777216
    return color % 256, math.floor(color / 256) % 256, math.floor(color / 65536) % 256
end

local function packColor(r, g, b)
    return clamp(math.floor(r), 0, 255)
         + clamp(math.floor(g), 0, 255) * 256
         + clamp(math.floor(b), 0, 255) * 65536
end

--- A byte of sRGB as linear light, and back.
local function toLinear(value)
    value = value / 255
    if value <= 0.04045 then return value / 12.92 end
    return ((value + 0.055) / 1.055) ^ 2.4
end

local function toByte(value)
    if value <= 0.0031308 then value = 12.92 * value
    else value = 1.055 * value ^ (1 / 2.4) - 0.055 end
    return math.floor(clamp(value, 0, 1) * 255 + 0.5)
end

local function cubeRoot(value)
    if value < 0 then return -((-value) ^ (1 / 3)) end
    return value ^ (1 / 3)
end

--- Two-argument atan under every Lua the framework runs on.
local ARC_TANGENT = math.atan2 or math.atan

--- @return number, number, number # L, chroma, hue in radians.
local function toOklch(color)
    local r, g, b = unpackColor(color)
    r, g, b = toLinear(r), toLinear(g), toLinear(b)
    local l = cubeRoot(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    local m = cubeRoot(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    local s = cubeRoot(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    local lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    local a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    local bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return lightness, math.sqrt(a * a + bb * bb), ARC_TANGENT(bb, a)
end

--- @return number, number, number # linear r, g, b, which may be out of gamut.
local function oklabToLinear(lightness, a, b)
    local l = lightness + 0.3963377774 * a + 0.2158037573 * b
    local m = lightness - 0.1055613458 * a - 0.0638541728 * b
    local s = lightness - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l * l * l, m * m * m, s * s * s
    return 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
          -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
          -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
end

--- A lightness and hue as a colour, with the chroma reduced until sRGB can
--- show it. Halving, because the gamut boundary is monotone in chroma.
local function fromOklch(lightness, chroma, hue)
    local cosine, sine = math.cos(hue), math.sin(hue)
    local low, high = 0, math.max(0, chroma)
    for _ = 1, 18 do
        local mid = (low + high) / 2
        local r, g, b = oklabToLinear(lightness, mid * cosine, mid * sine)
        if r >= -0.0005 and r <= 1.0005 and g >= -0.0005 and g <= 1.0005 and b >= -0.0005 and b <= 1.0005 then
            low = mid
        else
            high = mid
        end
    end
    local r, g, b = oklabToLinear(lightness, low * cosine, low * sine)
    return packColor(toByte(r), toByte(g), toByte(b))
end

--- The WCAG ratio between two packed colours. The one measurable promise a
--- ramp makes is that its quietest step is still a mark on this surface.
local function contrastRatio(a, b)
    local function relative(color)
        local r, g, b2 = unpackColor(color)
        return 0.2126 * toLinear(r) + 0.7152 * toLinear(g) + 0.0722 * toLinear(b2)
    end
    local high, low = relative(a), relative(b)
    if high < low then high, low = low, high end
    return (high + 0.05) / (low + 0.05)
end

--
--- ∑ A colour a number can be read in on this canvas. The muted token is
---   the right token for a readout - it is scenery beside the data - but on
---   a palette like Dark-Dark-Hell muted is 2.6:1 against its own canvas,
---   and the two numbers the map asks a reader to trust (what one grid step
---   is worth, and which heights the ramp spans) were then the least legible
---   text on the map. So the readout's colour is muted lifted toward the
---   label colour until it clears TEXT_FLOOR, and toward white after that if
---   a palette's own label colour cannot reach it either. On a palette whose
---   muted already clears it - five of the seven bundled themes - this
---   returns muted unchanged and nothing moves.
---
---   Only text goes through here. The rules of the scale bar, the grid and
---   the badge outlines stay muted: they are scenery, and lifting them would
---   put chrome back into competition with the marks.
--- @return number
--
local function readable(base, toward, surface)
    for step = 0, 10 do
        local color = mixColor(base, toward, step / 10)
        if contrastRatio(color, surface) >= TEXT_FLOOR then return color end
    end
    for step = 1, 10 do
        local color = mixColor(toward, 0xFFFFFF, step / 10)
        if contrastRatio(color, surface) >= TEXT_FLOOR then return color end
    end
    return 0xFFFFFF
end

--
--- ∑ The height ramp for an accent on a surface: the accent itself at the
---   salient end and RAMP_STEP of OKLab lightness down to the recessive
---   one, hue and chroma the accent's own. The salient end is never pushed
---   past the accent toward white, because that is where a theme keeps its
---   text and its selection, and a save is not either of those.
---
---   The step count is what gives way when a palette is tight, never the
---   gap between steps: a ramp whose quietest step cannot clear RAMP_FLOOR
---   against the canvas is tried again with one step fewer, and a palette
---   that cannot hold two gets no ramp at all. The map then draws every
---   marker in one colour, which is what it did before the ramp existed -
---   the encoding is on or off for a theme, never half readable on it.
---
---   The salient end is the accent itself, unless the accent cannot be seen
---   on this theme's own canvas. Then its hue is lifted until it can be:
---   every bundled theme is well clear of that, but a theme nobody
---   validated must still draw a save the user can find, and a mark the
---   surface swallows is not a mark.
--- @return table|nil, number # Packed colours recessive first, and the
---                             colour a marker with no height is drawn in.
--
local function heightRamp(accent, surface, steps)
    local lightness, chroma, hue = toOklch(accent)
    -- Which way is away from the surface, and which way is back toward it.
    -- A dark theme needs its accent lighter to be seen and a light theme
    -- needs it darker. Always walking toward white drew a #D09040 accent on
    -- a #F5F5F5 canvas so faintly that there was no mark left to find.
    local away = (toOklch(surface) > 0.5) and -0.02 or 0.02
    local top = accent
    if contrastRatio(accent, surface) < RAMP_FLOOR then
        local level = lightness
        while level > 0.02 and level < 0.98
              and contrastRatio(fromOklch(level, chroma, hue), surface) < RAMP_FLOOR do
            level = level + away
        end
        lightness, top = level, fromOklch(level, chroma, hue)
    end
    for count = math.max(2, math.floor(steps or 4)), 2, -1 do
        local ramp, usable = {}, true
        for index = 1, count do
            -- The steps run back toward the surface, opposite to the walk,
            -- because that is what makes a colour recede. With one fixed
            -- direction the ramp came out inverted on a light theme, and the
            -- high saves, the ones meant to fall back, were the loudest.
            local level = lightness - (count - index) * RAMP_STEP * (away > 0 and 1 or -1)
            if level <= 0.02 or level >= 0.98 then usable = false break end
            ramp[index] = (index == count) and top or fromOklch(level, chroma, hue)
        end
        if usable and contrastRatio(ramp[1], surface) >= RAMP_FLOOR then return ramp, top end
    end
    return nil, top
end

local function safeSet(control, property, value)
    if not control then return false end
    return (pcall(function() control[property] = value end))
end

local function safeGet(control, property)
    if not control then return nil end
    local ok, value = pcall(function() return control[property] end)
    if ok then return value end
    return nil
end

--
--- ∑ Names a control without letting the LCL rename its text.
---   TControl.SetName copies the new name into Text when the text still
---   equals the old name. A control made a moment ago has both empty, so
---   naming it for the focus fallback typed "ManifoldTeleporterMapFilter"
---   into the filter box. The text is read first and put back when the
---   name took it.
--
local function nameControl(control, name)
    local before = safeGet(control, "Text")
    safeSet(control, "Name", name)
    if before ~= nil and safeGet(control, "Text") ~= before then
        safeSet(control, "Text", before)
    end
end

--
--- ∑ The last two numbers in an argument list.
---   Cheat Engine's binding drops the LCL's Shift argument from mouse events,
---   so OnMouseDown arrives as (sender, button, x, y) and OnMouseMove as
---   (sender, x, y). Taking the last two numbers is correct under both.
--- @return number|nil, number|nil
--
local function coordinates(...)
    local x, y
    for index = select("#", ...), 1, -1 do
        local value = select(index, ...)
        if type(value) == "number" then
            if y == nil then
                y = value
            else
                x = value
                break
            end
        end
    end
    return x, y
end

local function isRightButton(button)
    return button == 1 or button == "mbRight"
end

local function isLeftButton(button)
    return button == 0 or button == "mbLeft" or button == nil
end

--- Modifier state, read from Cheat Engine rather than from the event, which
--- does not carry it.
local function keyPressed(code)
    local isKeyPressed = rawget(_G, "isKeyPressed")
    if type(isKeyPressed) ~= "function" then return false end
    local pressed = false
    pcall(function() pressed = isKeyPressed(code) == true end)
    return pressed
end

local function controlPressed() return keyPressed(0x11) end
local function shiftPressed() return keyPressed(0x10) end

--- The height band steps the comma and period keys walk through.
local HEIGHT_BAND_STEPS = { 0, 2, 5, 10, 25, 50 }

--- Whether any mouse button is down, read from Cheat Engine. nil when it
--- cannot be asked, so a caller keeps trusting its own bookkeeping.
local function mouseButtonDown()
    local isKeyPressed = rawget(_G, "isKeyPressed")
    if type(isKeyPressed) ~= "function" then return nil end
    local down = false
    pcall(function()
        down = isKeyPressed(0x01) == true or isKeyPressed(0x02) == true or isKeyPressed(0x04) == true
    end)
    return down
end

--------------------------------------------------------
--                   Pure geometry                    --
--------------------------------------------------------

--
--- ∑ World to screen and back, plus the arithmetic behind fitting, zooming
---   and the grid. Plain tables in, plain numbers out, so it runs without
---   Cheat Engine.
---
---   A view is { Width, Height, CenterX, CenterY, Scale, SignX, SignY }.
---   Scale is pixels per world unit. SignY is -1 by default, because screen
---   y grows downward and a map's vertical axis grows upward.
--
local Geometry = {}
TeleporterMap.Geometry = Geometry

function Geometry.Project(view, wx, wy)
    return view.Width / 2 + (wx - view.CenterX) * view.Scale * view.SignX,
           view.Height / 2 + (wy - view.CenterY) * view.Scale * view.SignY
end

function Geometry.Unproject(view, sx, sy)
    return view.CenterX + (sx - view.Width / 2) / (view.Scale * view.SignX),
           view.CenterY + (sy - view.Height / 2) / (view.Scale * view.SignY)
end

--
--- ∑ Scales the view by factor, keeping the world point under (sx, sy) where
---   it is on screen.
--- @return boolean # Whether the scale changed at all.
--
function Geometry.ZoomAt(view, factor, sx, sy, minScale, maxScale)
    local wx, wy = Geometry.Unproject(view, sx, sy)
    local scale = clamp(view.Scale * factor, minScale, maxScale)
    if scale == view.Scale then return false end
    view.Scale = scale
    view.CenterX = wx - (sx - view.Width / 2) / (scale * view.SignX)
    view.CenterY = wy - (sy - view.Height / 2) / (scale * view.SignY)
    return true
end

--
--- ∑ The grid spacing, in world units, that puts lines about targetPixels
---   apart at this scale: 1, 2 or 5 times a power of ten, rounded up.
--
function Geometry.NiceStep(scale, targetPixels)
    local raw = targetPixels / scale
    if not isFinite(raw) or raw <= 0 then return 1 end
    local exponent = math.floor(math.log(raw, 10))
    local magnitude = 10 ^ exponent
    local base = raw / magnitude
    local nice
    if base <= 1 then nice = 1
    elseif base <= 2 then nice = 2
    elseif base <= 5 then nice = 5
    else nice = 10 end
    return nice * magnitude
end

--
--- ∑ The bounding box of an array of { X, Y } points.
--- @return table|nil # { MinX, MaxX, MinY, MaxY }, or nil for no points.
--
function Geometry.Bounds(points)
    local bounds
    for _, point in ipairs(points or {}) do
        if isFinite(point.X) and isFinite(point.Y) then
            if not bounds then
                bounds = { MinX = point.X, MaxX = point.X, MinY = point.Y, MaxY = point.Y }
            else
                if point.X < bounds.MinX then bounds.MinX = point.X end
                if point.X > bounds.MaxX then bounds.MaxX = point.X end
                if point.Y < bounds.MinY then bounds.MinY = point.Y end
                if point.Y > bounds.MaxY then bounds.MaxY = point.Y end
            end
        end
    end
    return bounds
end

--
--- ∑ The scale and centre that show a bounding box inside width by height
---   with padding pixels to spare. A box with no extent, which is a single
---   save, gets a minimum span so it is not zoomed into a point.
--- @return number, number, number # scale, centreX, centreY
--
function Geometry.Fit(bounds, width, height, padding, minSpan, minScale, maxScale)
    padding = padding or 0
    minSpan = minSpan or 100
    local spanX = math.max(bounds.MaxX - bounds.MinX, minSpan)
    local spanY = math.max(bounds.MaxY - bounds.MinY, minSpan)
    local usableW = math.max(width - 2 * padding, 1)
    local usableH = math.max(height - 2 * padding, 1)
    local scale = math.min(usableW / spanX, usableH / spanY)
    scale = clamp(scale, minScale or 0, maxScale or math.huge)
    return scale, (bounds.MinX + bounds.MaxX) / 2, (bounds.MinY + bounds.MaxY) / 2
end

--
--- ∑ The marker closest to (sx, sy) within radius pixels, by its projected
---   SX and SY. A marker drawn larger than the base radius carries the
---   difference in HitExtra, so it is as easy to hit as it is to see.
---   Markers flagged Dimmed are skipped, so a filter narrows what a click
---   can hit as well as what stands out.
--
function Geometry.Nearest(markers, sx, sy, radius)
    local best, bestDistance = nil, nil
    for _, marker in ipairs(markers or {}) do
        if marker.SX and not marker.Dimmed then
            local dx, dy = marker.SX - sx, marker.SY - sy
            local distance = dx * dx + dy * dy
            local reach = radius + (marker.HitExtra or 0)
            if distance <= reach * reach and (bestDistance == nil or distance <= bestDistance) then
                best, bestDistance = marker, distance
            end
        end
    end
    return best
end

--
--- ∑ How much larger a marker is drawn for a height: 1 at the lowest save,
---   maxScale at the highest, linear between. 1 when there is no range to
---   speak of, the value is not a number, or scaling is switched off by a
---   maxScale of 1 or less.
--
function Geometry.HeightScale(value, low, high, maxScale)
    maxScale = tonumber(maxScale) or 1
    if not isFinite(maxScale) or maxScale <= 1 or not isFinite(value) or not isFinite(low) or not isFinite(high) then
        return 1
    end
    local span = high - low
    if span <= 0 then return 1 end
    local t = clamp((value - low) / span, 0, 1)
    return 1 + (maxScale - 1) * t
end

--
--- ∑ A world value as a short label: no trailing zeros, no exponent.
--
function Geometry.FormatUnits(value)
    if not isFinite(value) then return "?" end
    if value == math.floor(value) and math.abs(value) < 1e12 then
        return string.format("%d", value)
    end
    local text = string.format("%.3f", value)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    return text
end

--
--- ∑ A world value for a reader rather than for a machine: whole units at
---   ten and above, one decimal below. Every number the map paints on the
---   canvas goes through this, because "X 75.854  Z -162.519" is a
---   machine's answer to where a save is. FormatUnits stays the exact one,
---   for the clipboard, the status bar and the questions a teleport asks.
--
function Geometry.FormatRounded(value)
    if not isFinite(value) then return "?" end
    if math.abs(value) >= 10 then return string.format("%d", math.floor(value + 0.5)) end
    local text = string.format("%.1f", value)
    return (text:gsub("%.0$", ""))
end

--
--- ∑ The bounding box of the points that sit together, without the ones far
---   away from all of them. One save on the other side of the world
---   otherwise squeezes every other save into a corner of the window.
---
---   The quartile box is what "together" is measured against, because
---   quartiles do not move with the very points they are judging, and it is
---   widened by spread times its own size before anything is dropped. Fewer
---   than eight points is not a distribution, so those are all kept.
--- @param points table # Array of { X, Y }.
--- @param spread number|nil # How many half-boxes from the middle still counts.
--- @return table|nil, number # bounds, how many points were left out.
--
function Geometry.CoreBounds(points, spread)
    spread = tonumber(spread) or 2
    local xs, ys = {}, {}
    for _, point in ipairs(points or {}) do
        if isFinite(point.X) and isFinite(point.Y) then
            xs[#xs + 1] = point.X
            ys[#ys + 1] = point.Y
        end
    end
    if #xs < 8 then return Geometry.Bounds(points), 0 end
    table.sort(xs)
    table.sort(ys)
    local function quantile(list, q)
        return list[clamp(math.floor(q * (#list - 1) + 1.5), 1, #list)]
    end
    local x0, x1 = quantile(xs, 0.25), quantile(xs, 0.75)
    local y0, y1 = quantile(ys, 0.25), quantile(ys, 0.75)
    local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    -- An axis where the middle half of the saves share one value has no
    -- spread to scale, and a box built from that one value calls every other
    -- save an outlier. Using the whole extent of that axis instead lets it
    -- decide nothing, so the choice falls to the axis that does spread. That
    -- is the axis a tower of saves on one spot, or a corridor, differs on.
    local rx = (x1 > x0) and ((x1 - x0) / 2 * (1 + 2 * spread)) or math.max(xs[#xs] - xs[1], 1e-9)
    local ry = (y1 > y0) and ((y1 - y0) / 2 * (1 + 2 * spread)) or math.max(ys[#ys] - ys[1], 1e-9)
    local kept, dropped = {}, 0
    for _, point in ipairs(points) do
        if isFinite(point.X) and isFinite(point.Y) then
            if math.abs(point.X - cx) <= rx and math.abs(point.Y - cy) <= ry then
                kept[#kept + 1] = point
            else
                dropped = dropped + 1
            end
        end
    end
    if #kept == 0 then return Geometry.Bounds(points), 0 end
    -- A fit that leaves out a fifth of the map is not a fit of the map. The
    -- box is here for the rare save in a glitched room on the other side of
    -- the world. When it wants to drop more than that, what it is measuring
    -- is the shape of the level and all of it belongs on screen. This also
    -- catches an axis that is nearly flat rather than exactly flat, where a
    -- tight hub of eleven saves dropped the ten spread around it.
    if dropped > math.max(1, math.floor(#xs * 0.2)) then
        return Geometry.Bounds(points), 0
    end
    return Geometry.Bounds(kept), dropped
end

--
--- ∑ A value rounded to something a legend can print: the magnitude one
---   step of a five step scale over span sits at. Low ends are rounded
---   down and high ends up, so the printed range still covers the data.
---
---   The magnitude walks a 1-2-5 ladder and not powers of ten alone. A plain
---   power of ten leaves a step of 1 on a span of 41, and the legend then
---   ends on "81", which is a raw value that escaped the rounding. The
---   ladder step is taken downward - the largest of 1, 2 or 5 times a power
---   of ten that is no wider than a fifth of the span - so an end stays near
---   the data it stands for and is still a number a person says out loud: a
---   span of 41 prints 40 ... 85, one of 209 prints 20 ... 240.
--- @param value number
--- @param span number # The range the value is an end of.
--- @param up boolean|nil # Round up instead of down.
--
function Geometry.RoundUnits(value, span, up)
    if not isFinite(value) then return value end
    if not isFinite(span) or span <= 0 then return value end
    local raw = span / 5
    local power = 10 ^ math.floor(math.log(raw, 10))
    if not isFinite(power) or power <= 0 then return value end
    local base = raw / power
    local magnitude = power * ((base >= 5 and 5) or (base >= 2 and 2) or 1)
    if not isFinite(magnitude) or magnitude <= 0 then return value end
    local steps = up and math.ceil(value / magnitude) or math.floor(value / magnitude)
    return steps * magnitude
end

--
--- ∑ Which of count bands a value falls in, 1 at low and count at high.
---   Used for the height colour: five bands read as five steps, where a
---   continuous shade reads as noise.
--
function Geometry.HeightBandIndex(value, low, high, count)
    count = math.floor(tonumber(count) or 1)
    if count < 1 then count = 1 end
    if not isFinite(value) or not isFinite(low) or not isFinite(high) or high <= low then return count end
    local t = clamp((value - low) / (high - low), 0, 1)
    return clamp(math.floor(t * count) + 1, 1, count)
end

--
--- ∑ Whether two rectangles { X1, Y1, X2, Y2 } overlap.
--
function Geometry.Overlaps(a, b)
    return not (a.X2 < b.X1 or b.X2 < a.X1 or a.Y2 < b.Y1 or b.Y2 < a.Y1)
end

--
--- ∑ Pulls a point inside a width by height rectangle, inset by margin.
--- @return number, number, boolean # x, y, and whether it was outside.
--
function Geometry.ClampToRect(x, y, width, height, margin)
    local cx = clamp(x, margin, width - margin)
    local cy = clamp(y, margin, height - margin)
    return cx, cy, cx ~= x or cy ~= y
end

--------------------------------------------------------
--                       Plane                        --
--------------------------------------------------------

--
--- ∑ The axis the Teleporter treats as height, or nil when the game has
---   only two components and therefore no height to leave out.
---   Settings.YCoordinateIndex is trusted when the lift is switched on,
---   because switching it on is how a table says which axis that is. Off,
---   the second component is assumed, which is where most engines keep it.
--- @return number|nil
--
function TeleporterMap:GetUpAxis()
    local count = teleporter:AxisCount()
    if count < 3 then return nil end
    local settings = teleporter.Settings or {}
    local index = tonumber(settings.YCoordinateIndex)
    if settings.AdjustYCoordinate and index and index >= 1 and index <= count then
        return math.floor(index)
    end
    return 2
end
registerLuaFunctionHighlight('GetUpAxis')

--
--- ∑ The component a marker's size stands for: the one the plane leaves
---   out. That is the up axis whenever the plane does not draw it, else the
---   first component off the plane, and nil for a 2D table, which has
---   nothing left over.
--- @return number|nil
--
function TeleporterMap:HeightAxis()
    local h, v = self:GetPlane()
    if not h or not v then return nil end
    local count = teleporter:AxisCount()
    if count < 3 then return nil end
    local up = self:GetUpAxis()
    if up and up ~= h and up ~= v then return up end
    for index = 1, count do
        if index ~= h and index ~= v then return index end
    end
    return nil
end
registerLuaFunctionHighlight('HeightAxis')

--
--- ∑ The two position components that make the map, with their names.
--- @return number|nil, number|nil, string|nil, string|nil # horizontal index, vertical index, their names
--
function TeleporterMap:GetPlane()
    local axes = teleporter:GetAxes()
    local count = #axes
    if count < 2 then return nil end
    local plane = self.Plane or {}
    local h, v = tonumber(plane.Horizontal), tonumber(plane.Vertical)
    local valid = h and v and h ~= v and h >= 1 and h <= count and v >= 1 and v <= count
    if not valid then
        local up = self:GetUpAxis()
        h, v = nil, nil
        for index = 1, count do
            if index ~= up then
                if not h then
                    h = index
                elseif not v then
                    v = index
                    break
                end
            end
        end
    end
    return h, v, axes[h], axes[v]
end
registerLuaFunctionHighlight('GetPlane')

--
--- ∑ Chooses the two components to draw, by index, and rebuilds the map.
--- @param horizontal number
--- @param vertical number
--
function TeleporterMap:SetPlane(horizontal, vertical)
    self.Plane.Horizontal = horizontal
    self.Plane.Vertical = vertical
    self:RebuildMarkers()
    self.Trail = {}
    self:FitAll()
    self:_UpdateHeader()
    self:_MarkViewDirty()
end
registerLuaFunctionHighlight('SetPlane')

--
--- ∑ Every ordered pair of axes a 3D table could show, for the View menu.
--- @return table # Array of { H = index, V = index, Caption = "X / Z" }.
--
function TeleporterMap:PlaneChoices()
    local axes = teleporter:GetAxes()
    local choices = {}
    for h = 1, #axes do
        for v = h + 1, #axes do
            choices[#choices + 1] = { H = h, V = v, Caption = axes[h] .. " / " .. axes[v] }
        end
    end
    return choices
end
registerLuaFunctionHighlight('PlaneChoices')

--------------------------------------------------------
--                       Areas                        --
--------------------------------------------------------

--- The selection that means "the saves without an area".
local AREA_NONE = false

--
--- ∑ Fills a menu item's children from a spec, reusing the items that are
---   already there.
---
---   Nothing is ever freed. MenuItem.clear() destroys its children, and one
---   of them can be the item whose OnClick is running - an area is switched
---   from that very menu - or one the user has dropped open while a save
---   listener rebuilds the list underneath. Surplus items are hidden
---   instead, which costs a handful of invisible menu entries and cannot
---   fault.
--- @param owner table # The menu the items belong to.
--- @param parent table # The item whose children these are.
--- @param entries table # Array of { Caption, OnClick, Selected }.
--- @param store table # Kept in the UI state: one slot per item, ever.
--
local function syncMenuItems(owner, parent, entries, store)
    for index, entry in ipairs(entries) do
        local slot = store[index]
        if not slot then
            local item = createMenuItem(owner)
            safeSet(item, "AutoCheck", false)
            parent.add(item)
            slot = { Item = item }
            store[index] = slot
        end
        safeSet(slot.Item, "Caption", entry.Caption)
        safeSet(slot.Item, "Visible", true)
        safeSet(slot.Item, "Enabled", entry.Enabled ~= false)
        safeSet(slot.Item, "OnClick", entry.OnClick)
        slot.Selected = entry.Selected
    end
    for index = #entries + 1, #store do
        safeSet(store[index].Item, "Visible", false)
        safeSet(store[index].Item, "OnClick", nil)
        store[index].Selected = nil
    end
end

--
--- ∑ The selection as a string, for the per-area cameras and the file.
--- @return string # "all", "none" or "area:<name>".
--
function TeleporterMap:AreaKey(selected)
    if selected == nil then selected = self.Area.Selected end
    -- The plane is part of the key. A camera is a centre on two axes, and
    -- restoring one framed on X / Z while the map draws X / Y puts the view
    -- somewhere the saves have never been.
    local h, v = self:GetPlane()
    local plane = "@" .. tostring(h or "?") .. "/" .. tostring(v or "?")
    if selected == nil then return "all" .. plane end
    if selected == AREA_NONE then return "none" .. plane end
    return "area:" .. tostring(selected) .. plane
end
registerLuaFunctionHighlight('AreaKey')

--
--- ∑ The area a save belongs to, as the Teleporter answers it. A Teleporter
---   older than areas answers nil for everything, and the map then has one
---   area, which is every save.
--
function TeleporterMap:_SaveArea(save, known)
    if type(teleporter.GetSaveArea) ~= "function" then return nil, false end
    return teleporter:GetSaveArea(save, known)
end

--- Whether a save with this area shows under the current selection.
function TeleporterMap:_InSelectedArea(area)
    local selected = self.Area.Selected
    if selected == nil then return true end
    if selected == AREA_NONE then return area == nil end
    return area == selected
end

--
--- ∑ What the selector offers: All Areas, each area with its count, and
---   the saves without one whenever there are any, or that is the view
---   being shown.
--- @return table # Array of { Selected, Caption }.
--
function TeleporterMap:AreaEntries()
    local entries = {}
    if type(teleporter.GetAreas) ~= "function" then
        entries[1] = { Selected = nil, Caption = string.format("All Areas (%d)", teleporter:CountSaves()) }
        return entries
    end
    local areas, unassigned = teleporter:GetAreas()
    local selected = self.Area.Selected
    entries[#entries + 1] = { Selected = nil, Caption = string.format("All Areas (%d)", teleporter:CountSaves()) }
    local listed = type(selected) ~= "string"
    for _, area in ipairs(areas) do
        entries[#entries + 1] = { Selected = area.Name, Caption = string.format("%s (%d)", area.Name, area.Count) }
        if area.Name == selected then listed = true end
    end
    -- The area being shown is always in the list, the way (No Area) is.
    -- Its last save can be deleted or renamed away while it is on screen,
    -- and a dropdown that then reads "All Areas" over an empty map is a
    -- state the user can neither understand nor leave.
    if not listed then
        entries[#entries + 1] = { Selected = selected, Caption = string.format("%s (0)", tostring(selected)) }
    end
    if unassigned > 0 or selected == AREA_NONE then
        entries[#entries + 1] = { Selected = AREA_NONE, Caption = string.format("(No Area) (%d)", unassigned) }
    end
    return entries
end
registerLuaFunctionHighlight('AreaEntries')

--
--- ∑ Shows one area, every area (nil) or the saves without one (false).
---   The camera of the area being left is remembered and the other area's
---   comes back, or the view fits when it has none yet. The trail is
---   dropped, since a path across two maps means nothing.
--- @param selected string|nil|false
--
function TeleporterMap:SetArea(selected)
    if selected ~= nil and selected ~= AREA_NONE then
        selected = trimString(selected)
        if selected == "" then selected = nil end
    end
    self.AreaViews = self.AreaViews or {}
    -- Only a camera somebody framed. Before the first fit it is one pixel
    -- per unit at the origin, which would be restored later as if it had
    -- been chosen, instead of fitting the area. Settled first, so the file
    -- holds the zoom that was asked for and not the frame an animation
    -- happened to be on when the area was switched.
    self:SettleZoom()
    if self.Camera.Fitted then
        self.AreaViews[self:AreaKey()] = { Zoom = self.Camera.Scale, CenterX = self.Camera.X, CenterY = self.Camera.Y }
    end
    self.Area.Selected = selected
    self:RebuildMarkers()
    self.Trail = {}
    local restored = self.AreaViews[self:AreaKey()]
    if restored and isFinite(tonumber(restored.Zoom)) and tonumber(restored.Zoom) > 0 then
        self.Camera.Scale = clamp(tonumber(restored.Zoom), self.View.MinZoom, self.View.MaxZoom)
        self.Camera.X, self.Camera.Y = tonumber(restored.CenterX) or 0, tonumber(restored.CenterY) or 0
        self.Camera.Fitted = true
        -- A remembered camera left nothing out. The note belongs to a fit.
        self.FitDropped = 0
        self:Redraw()
    else
        self:FitAll()
    end
    self:_UpdateToggles()
    self:_MarkViewDirty()
    self:_UpdateInfo()
    self:SetStatus(self:AreaCaption() .. self:FitNote())
    return true
end
registerLuaFunctionHighlight('SetArea')

--
--- ∑ A line for the status bar and the header: how many saves, and where.
--- @return string
--
function TeleporterMap:AreaCaption()
    local selected = self.Area.Selected
    if selected == nil then return string.format("%d saves", #self.Markers) end
    if selected == AREA_NONE then return string.format("%d saves without an area", #self.Markers) end
    return string.format("%d saves in %s", #self.Markers, tostring(selected))
end
registerLuaFunctionHighlight('AreaCaption')

--
--- ∑ Steps through the selector's entries, wrapping. PageUp and PageDown.
--- @param step number # -1 or 1.
--
function TeleporterMap:CycleArea(step)
    local entries = self:AreaEntries()
    if #entries < 2 then return false end
    local current = 1
    for index, entry in ipairs(entries) do
        if entry.Selected == self.Area.Selected then current = index break end
    end
    local target = ((current - 1 + step) % #entries) + 1
    self:SetArea(entries[target].Selected)
    return true
end
registerLuaFunctionHighlight('CycleArea')

--
--- ∑ Fills the dropdown and the View -> Area submenu from the entries,
---   rebuilding them only when the captions changed, and never firing the
---   dropdown's OnChange while doing so.
--
function TeleporterMap:_RefreshAreaControls()
    local ui = self.UiState
    if not ui then return end
    local entries = self:AreaEntries()
    local parts, selectedIndex = {}, 0
    for index, entry in ipairs(entries) do
        parts[index] = entry.Caption
        if entry.Selected == self.Area.Selected then selectedIndex = index - 1 end
    end
    local signature = table.concat(parts, "\n")
    local changed = ui.AreaSignature ~= signature
    ui.AreaEntries = entries
    ui.AreaSignature = signature
    if ui.AreaCombo then
        ui.IsRefreshingAreas = true
        if changed then
            pcall(function()
                ui.AreaCombo.Items.clear()
                for _, caption in ipairs(parts) do ui.AreaCombo.Items.add(caption) end
            end)
        end
        safeSet(ui.AreaCombo, "ItemIndex", selectedIndex)
        ui.IsRefreshingAreas = false
    end
    if ui.AreaMenuItem and ui.MainMenu then
        ui.AreaMenuItems = ui.AreaMenuItems or {}
        local specs = {}
        for index, entry in ipairs(entries) do
            local choice = entry.Selected
            specs[index] = { Caption = entry.Caption, Selected = choice,
                             OnClick = function() self:SetArea(choice) end }
        end
        syncMenuItems(ui.MainMenu, ui.AreaMenuItem, specs, ui.AreaMenuItems)
        for index, slot in ipairs(ui.AreaMenuItems) do
            safeSet(slot.Item, "Checked", index <= #specs and slot.Selected == self.Area.Selected)
        end
        -- The Area submenu is filled here, after the menu bar was given its
        -- dark background, and a submenu that did not exist then has none.
        -- Only when the list changed, because the step is four native calls.
        if changed and ui.Form and type(forms.ThemeMenuBar) == "function" then
            forms:ThemeMenuBar(ui.Form)
        end
    end
end

--------------------------------------------------------
--                      Markers                       --
--------------------------------------------------------

--
--- ∑ One marker per save that has a usable position. Rebuilt when the saves
---   change, not per frame: projection happens per frame, the rest is fixed
---   until the Teleporter says otherwise.
--
function TeleporterMap:RebuildMarkers()
    local h, v = self:GetPlane()
    local up = self:HeightAxis()
    local markers = {}
    local known
    if type(teleporter.KnownAreas) == "function" then
        _, known = teleporter:KnownAreas()
    end
    local areaCounts, unassigned, total = {}, 0, 0
    if h and v then
        for key, save in pairs(teleporter.Saves or {}) do
            local position = teleporter:SaveToPosition(save)
            if position and isFinite(position[h]) and isFinite(position[v]) then
                total = total + 1
                local area, derived = self:_SaveArea(save, known)
                if area then
                    areaCounts[area] = (areaCounts[area] or 0) + 1
                else
                    unassigned = unassigned + 1
                end
                if self:_InSelectedArea(area) then
                    local name = teleporter:GetSaveDisplayName(save, key)
                    local category = teleporter:CategoryPathToText(teleporter:GetSaveCategoryPath(save, true), true)
                    local author = tostring(save.Author or "")
                    local description = tostring(save.Description or "")
                    markers[#markers + 1] = {
                        Key = key, Name = name, Category = category, Author = author,
                        Description = description, Position = position,
                        X = position[h], Y = position[v],
                        Height = up and position[up] or nil,
                        Area = area, AreaDerived = derived == true,
                        Search = string.lower(table.concat({ key, name, category, author, description, area or "" }, " ")),
                    }
                end
            end
        end
    end
    self.AreaCounts, self.UnassignedCount, self.TotalCount = areaCounts, unassigned, total
    table.sort(markers, function(a, b)
        local an, bn = a.Name:lower(), b.Name:lower()
        if an ~= bn then return an < bn end
        return a.Key < b.Key
    end)
    self.Markers = markers
    self:_ScaleMarkers(markers)
    self.MarkerSource = teleporter.Saves
    self.MarkerCount = teleporter:CountSaves()
    -- The selection survives a rebuild when its save still exists.
    if self.Selected then
        self.Selected = self:FindMarker(self.Selected.Key)
    end
    self.Hover = nil
    self:_ApplyFilter()
    self:_UpdateHeader()
    self:_UpdateDetails()
    self:_RefreshAreaControls()
    self.Dirty = true
    return markers
end
registerLuaFunctionHighlight('RebuildMarkers')

--- The configured HeightScaleMax as a usable number: finite and at least 1.
--- An infinite one would put NaN into every radius and stop the painter.
function TeleporterMap:_HeightScaleMax()
    local maxScale = tonumber(self.View.HeightScaleMax)
    if not isFinite(maxScale) or maxScale < 1 then return 1 end
    return maxScale
end

--
--- ∑ Re-sizes the markers when a View field they were sized from has been
---   edited in place since, which is the supported way to configure the
---   map at runtime. Called once per frame; the comparison is three fields.
--
function TeleporterMap:_EnsureScaled()
    local key = self.ScaleKey
    local base = tonumber(self.View.MarkerRadius) or 5
    local maxScale = self:_HeightScaleMax()
    local on = self.View.ScaleByHeight == true
    if key and key.Base == base and key.Max == maxScale and key.On == on then return end
    self:_ScaleMarkers()
end

--
--- ∑ Sizes every marker from the height of its save, so the axis the plane
---   leaves out is at least approximated. The range is taken over
---   every marker, filtered or not, so a filter does not resize what stays
---   visible. Radius is the pixel radius to draw, HitExtra what the hit
---   test adds to its reach.
--- @param markers table|nil # Defaults to the current markers.
--
function TeleporterMap:_ScaleMarkers(markers)
    markers = markers or self.Markers
    local base = tonumber(self.View.MarkerRadius) or 5
    local maxScale = self:_HeightScaleMax()
    -- What the sizes were computed from, so _EnsureScaled can tell when a
    -- View field was edited in place and the markers are stale.
    self.ScaleKey = { Base = base, Max = maxScale, On = self.View.ScaleByHeight == true }
    local low, high
    if self.View.ScaleByHeight and maxScale > 1 then
        for _, marker in ipairs(markers) do
            if isFinite(marker.Height) then
                if low == nil or marker.Height < low then low = marker.Height end
                if high == nil or marker.Height > high then high = marker.Height end
            end
        end
    end
    self.HeightRange = (low ~= nil and high ~= nil and high > low) and { Low = low, High = high } or nil
    for _, marker in ipairs(markers) do
        local scale = 1
        if self.HeightRange and isFinite(marker.Height) then
            -- Size reads as distance from the viewer: the lowest save is the
            -- largest disc, the highest the smallest. Mirroring the height
            -- about the range is the whole inversion; HeightScale stays the
            -- plain ramp it was.
            scale = Geometry.HeightScale(low + high - marker.Height, low, high, maxScale)
            -- The shade comes from the same mirrored number, kept as a
            -- fraction rather than a band, because how many bands there are
            -- is the palette's answer and not this one's: 0 is the highest
            -- save, 1 the lowest, and the painter asks the ramp it has.
            marker.HeightT = clamp((high - marker.Height) / (high - low), 0, 1)
        elseif self.HeightRange then
            -- A save whose height is not a number is drawn in the middle of
            -- both channels. It cannot be left at scale 1, which is the size
            -- of the HIGHEST save while the painter falls back to the colour
            -- of the lowest: the two channels would say opposite things in
            -- the one case the encoding claims cannot happen. HeightT stays
            -- nil, which is how the painter knows to use the middle shade.
            scale = Geometry.HeightScale((low + high) / 2, low, high, maxScale)
            marker.HeightT = nil
        else
            marker.HeightT = nil
        end
        marker.Scale = scale
        marker.Radius = base * scale
        marker.HitExtra = base * (scale - 1)
    end
    self:_MeasureSpacing(markers)
end

--
--- ∑ How far apart the saves on this map typically are, in world units: the
---   median distance from a marker to its nearest neighbour. The painter
---   turns it into pixels at the current zoom and never draws a disc wider
---   than the room a save actually has, which is what keeps a zoomed out map
---   from turning into one blob.
---
---   Measured per rebuild and not per frame, and from the saves rather than
---   from what happens to be on screen, so the same save keeps the same size
---   while the map is panned and only a zoom changes it. The size of a disc
---   has to mean height; it must not also mean "the camera moved".
--
function TeleporterMap:_MeasureSpacing(markers)
    self.Spacing = nil
    markers = markers or self.Markers
    local count = #markers
    if count < 3 then return end
    local bounds = Geometry.Bounds(markers)
    if not bounds then return end
    local span = math.max(bounds.MaxX - bounds.MinX, bounds.MaxY - bounds.MinY)
    if not isFinite(span) or span <= 0 then return end
    -- About one marker per cell, so a neighbour is nearly always inside the
    -- nine cells around a marker and the scan stays linear in the saves.
    local cell = span / math.max(1, math.floor(math.sqrt(count)))
    if not isFinite(cell) or cell <= 0 then return end
    local function key(cx, cy) return (cx + 65536) * 131072 + (cy + 65536) end
    local buckets = {}
    for _, marker in ipairs(markers) do
        if isFinite(marker.X) and isFinite(marker.Y) then
            local bucket = buckets[key(math.floor(marker.X / cell), math.floor(marker.Y / cell))]
            if not bucket then
                bucket = {}
                buckets[key(math.floor(marker.X / cell), math.floor(marker.Y / cell))] = bucket
            end
            -- A cell this crowded has already answered the question: what is
            -- nearest to anything in it is also in it.
            if #bucket < 12 then bucket[#bucket + 1] = marker end
        end
    end
    local distances = {}
    for _, marker in ipairs(markers) do
        if isFinite(marker.X) and isFinite(marker.Y) then
            local cx, cy = math.floor(marker.X / cell), math.floor(marker.Y / cell)
            local best
            for ox = -1, 1 do
                for oy = -1, 1 do
                    for _, other in ipairs(buckets[key(cx + ox, cy + oy)] or {}) do
                        if other ~= marker then
                            local dx, dy = other.X - marker.X, other.Y - marker.Y
                            local distance = dx * dx + dy * dy
                            if best == nil or distance < best then best = distance end
                        end
                    end
                end
            end
            if best and best > 0 then distances[#distances + 1] = math.sqrt(best) end
        end
    end
    if #distances < 3 then return end
    table.sort(distances)
    self.Spacing = distances[math.floor(#distances / 2) + 1]
end

--
--- ∑ Rebuilds when the Teleporter's save table was replaced or grew. The
---   Teleporter also announces edits through its save listeners, which
---   catches a moved save this cannot see.
--
function TeleporterMap:_SyncMarkers()
    if self.MarkerSource ~= teleporter.Saves or self.MarkerCount ~= teleporter:CountSaves() then
        self:RebuildMarkers()
    end
end

function TeleporterMap:FindMarker(key)
    for _, marker in ipairs(self.Markers) do
        if marker.Key == key then return marker end
    end
    return nil
end
registerLuaFunctionHighlight('FindMarker')

--
--- ∑ Flags every marker the filter box does not match as Dimmed.
---   Dimmed markers are painted faint and cannot be clicked, so a filter
---   makes a crowded area clickable as well as readable.
--
function TeleporterMap:_ApplyFilter()
    local query = string.lower(trimString(self.Filter))
    local band = tonumber(self.View.HeightBand) or 0
    local playerHeight = self:_PlayerHeight()
    local shown = 0
    for _, marker in ipairs(self.Markers) do
        local dimmed = query ~= "" and not marker.Search:find(query, 1, true)
        -- The band is a filter too: a save on another floor is dimmed and
        -- cannot be clicked, the same as one the text does not match.
        if not dimmed and band > 0 and playerHeight and isFinite(marker.Height) then
            dimmed = math.abs(marker.Height - playerHeight) > band
        end
        marker.Dimmed = dimmed
        if not dimmed then shown = shown + 1 end
    end
    self.ShownCount = shown
    self.BandAppliedAt = playerHeight
end

--- The player's value on the height axis, or nil.
function TeleporterMap:_PlayerHeight()
    local up = self:HeightAxis()
    local position = self.PlayerPosition
    if not up or not position or not isFinite(position[up]) then return nil end
    return position[up]
end

--
--- ∑ Sets the height band around the player, in world units. 0 is off.
--
function TeleporterMap:SetHeightBand(band)
    band = tonumber(band) or 0
    if not isFinite(band) or band < 0 then band = 0 end
    -- Without a height axis there is no distance to measure, so a band
    -- would sit in the status bar promising a filter that never applies.
    if band > 0 and not self:HeightAxis() then
        self:SetStatus("This table has no height axis, so there is no band to apply")
        return false
    end
    self.View.HeightBand = band
    self:_ApplyFilter()
    self:_UpdateHeader()
    self:_UpdateToggles()
    self:_MarkViewDirty()
    self:Redraw()
    self:_UpdateInfo()
    if band <= 0 then
        self:SetStatus("Height band off")
    elseif self:_PlayerHeight() then
        self:SetStatus(string.format("Height band ±%s u around the player", Geometry.FormatUnits(band)))
    else
        self:SetStatus(string.format("Height band ±%s u, waiting for the player", Geometry.FormatUnits(band)))
    end
    return true
end
registerLuaFunctionHighlight('SetHeightBand')

--
--- ∑ Steps the band through its fixed steps. Comma narrows, period widens.
--- @param step number # -1 or 1.
--
function TeleporterMap:CycleHeightBand(step)
    local current = tonumber(self.View.HeightBand) or 0
    local index = 1
    for position, value in ipairs(HEIGHT_BAND_STEPS) do
        if value <= current then index = position end
    end
    local target = clamp(index + step, 1, #HEIGHT_BAND_STEPS)
    if HEIGHT_BAND_STEPS[target] == current then return false end
    return self:SetHeightBand(HEIGHT_BAND_STEPS[target]) == true
end
registerLuaFunctionHighlight('CycleHeightBand')

--- Re-applies the band once the player has moved a quarter of it up or
--- down. Called from the poll, so it must stay this cheap.
function TeleporterMap:_FollowHeightBand()
    local band = tonumber(self.View.HeightBand) or 0
    if band <= 0 then return end
    local height = self:_PlayerHeight()
    if not height then return end
    local last = self.BandAppliedAt
    if last ~= nil and math.abs(height - last) <= band / 4 then return end
    self:_ApplyFilter()
    self:_UpdateHeader()
    self.Dirty = true
end

function TeleporterMap:SetFilter(text)
    self.Filter = tostring(text or "")
    self:_ApplyFilter()
    self:_UpdateHeader()
    self:Redraw()
end
registerLuaFunctionHighlight('SetFilter')

--
--- ∑ The marker under a screen point, or nil.
--
function TeleporterMap:MarkerAt(sx, sy)
    if type(sx) ~= "number" or type(sy) ~= "number" then return nil end
    return Geometry.Nearest(self.Markers, sx, sy, self.View.HitRadius or 10)
end
registerLuaFunctionHighlight('MarkerAt')

--
--- ∑ Makes a marker the selection, or clears it with nil.
--
function TeleporterMap:SelectMarker(marker)
    if self.Selected == marker then return end
    self.Selected = marker
    self:_UpdateDetails()
    if marker then
        self:SetStatus("Selected: " .. marker.Key)
    end
    self:Redraw()
end
registerLuaFunctionHighlight('SelectMarker')

--
--- ∑ Selects a save by key and centres the map on it.
--
function TeleporterMap:FocusSave(key)
    local marker = self:FindMarker(key)
    if not marker then
        -- The save may be on another map. Switch to it, then look again.
        -- Only when it would actually draw there. A save without a usable
        -- position never becomes a marker, and leaving the user's area to
        -- find that out is a switch with nothing to show for it.
        local save = teleporter.Saves and teleporter.Saves[key]
        local h, v = self:GetPlane()
        local position = (save and h) and teleporter:SaveToPosition(save) or nil
        if position and isFinite(position[h]) and isFinite(position[v]) then
            local area = self:_SaveArea(save)
            if not self:_InSelectedArea(area) then
                self:SetArea(area or AREA_NONE)
                marker = self:FindMarker(key)
            end
        end
    end
    if not marker then return false end
    self:SelectMarker(marker)
    self:CenterOn(marker.X, marker.Y)
    return true
end
registerLuaFunctionHighlight('FocusSave')

--------------------------------------------------------
--                       Camera                       --
--------------------------------------------------------

--
--- ∑ The view table Geometry works on, for the current surface size.
--
function TeleporterMap:_View(width, height)
    if not width then width, height = self:Size() end
    local plane = self.Plane
    return {
        Width = width, Height = height,
        CenterX = self.Camera.X, CenterY = self.Camera.Y, Scale = self.Camera.Scale,
        SignX = plane.FlipHorizontal and -1 or 1,
        SignY = plane.FlipVertical and 1 or -1,
    }
end

function TeleporterMap:_Adopt(view)
    self.Camera.X, self.Camera.Y, self.Camera.Scale = view.CenterX, view.CenterY, view.Scale
end

--
--- ∑ Screen point to world coordinates on the map plane.
--- @return number, number
--
function TeleporterMap:ToWorld(sx, sy)
    return Geometry.Unproject(self:_View(), sx, sy)
end
registerLuaFunctionHighlight('ToWorld')

--
--- ∑ Scales the view around a screen point, or around the centre.
--- @param factor number # Above 1 zooms in.
--- @param sx number|nil
--- @param sy number|nil
--
function TeleporterMap:ZoomBy(factor, sx, sy)
    local view = self:_View()
    if type(sx) ~= "number" or type(sy) ~= "number" then
        sx, sy = view.Width / 2, view.Height / 2
    end
    if Geometry.ZoomAt(view, factor, sx, sy, self.View.MinZoom, self.View.MaxZoom) then
        self:_Adopt(view)
        self:_MarkViewDirty()
        self:Redraw()
        self:_UpdateInfo()
    end
end
registerLuaFunctionHighlight('ZoomBy')

function TeleporterMap:ZoomIn() self:ZoomSmooth(self.View.ZoomStep or 1.25) end
function TeleporterMap:ZoomOut() self:ZoomSmooth(1 / (self.View.ZoomStep or 1.25)) end
registerLuaFunctionHighlight('ZoomIn')
registerLuaFunctionHighlight('ZoomOut')

--- The animation's timer, which only exists while the window does.
function TeleporterMap:_ZoomTimer()
    local ui = self.UiState
    return ui and ui.ZoomTimer or nil
end

function TeleporterMap:_ZoomTimerEnabled(enabled)
    local timer = self:_ZoomTimer()
    if timer then safeSet(timer, "Enabled", enabled == true) end
    -- A new flight must not inherit the gap since the last one ended.
    if enabled ~= true then self.ZoomClock = nil end
end

--
--- ∑ Milliseconds since the previous zoom frame.
---
---   The timer's interval is only what the LCL was asked for, not what
---   arrived. A frame repaints the whole map and costs more than the 16 ms it
---   was scheduled at, so counting intervals made ZoomAnimationMs mean about
---   this many frames, and the glide ran long by whatever the painting cost.
---   Read from a clock it means milliseconds again, and a slow frame drops
---   steps rather than stretching the zoom.
--- @param nominal number # The interval to assume with no clock to read, and
---                         on the first frame of a flight.
--- @return number # Milliseconds to advance by.
--
function TeleporterMap:_ZoomStepMs(nominal)
    nominal = tonumber(nominal) or 16
    local now
    if type(getTickCount64) == "function" then
        local ok, value = pcall(getTickCount64)
        if ok then now = tonumber(value) end
    end
    if now == nil and type(getTickCount) == "function" then
        local ok, value = pcall(getTickCount)
        if ok then now = tonumber(value) end
    end
    if not isFinite(now) then return nominal end
    local last = self.ZoomClock
    self.ZoomClock = now
    if not isFinite(last) or now <= last then return nominal end
    -- One very late frame must not fling the zoom onto its target. Past four
    -- intervals the step is capped and the glide simply finishes late.
    return math.min(now - last, nominal * 4)
end

--- Drops a zoom in flight. For the places that move the centre on purpose,
--- which the scale check below cannot see.
function TeleporterMap:_CancelZoom()
    self.ZoomAnim = nil
    self:_ZoomTimerEnabled(false)
end

--
--- ∑ The zoom in flight, or nil once something else has scaled the camera.
---   A fit, an area switch or SetZoom wins, because the user asked for that
---   more recently than for this zoom.
---
---   The centre is deliberately not watched. Follow Player re-centres on the
---   player ten times a second and a notch needs eight frames, so a tick
---   almost always landed inside a flight and the wheel delivered whatever
---   fraction of the notch had arrived by then. Ten notches gave 2.44x where
---   the notches asked for 9.31x. Moving the centre is no reason to abandon
---   a zoom, so the three places that do it on purpose say so themselves.
---
---   One question asked in one place, because the stepper and a new notch
---   disagreeing about whether the flight is still live is what let a notch
---   build on a dead animation's target and zoom seven times too far.
--
function TeleporterMap:_ZoomStillOurs()
    local anim = self.ZoomAnim
    if not anim then return nil end
    if self.Camera.Scale ~= anim.Scale then self:_CancelZoom() end
    return self.ZoomAnim
end

--
--- ∑ Zooms toward a factor over View.ZoomAnimationMs, around a screen
---   point. A wheel notch is a quarter of the scale and arriving in one
---   frame is what reads as a jerk.
---
---   The target is clamped once, here, so the steps toward it cannot
---   overshoot the limit and then crawl back. A second notch while the
---   first is still arriving moves the target rather than restarting from
---   wherever the eye happens to be, so spinning the wheel lands exactly
---   where the notches say. With no window, or with the option at 0, this
---   is ZoomBy.
--- @param factor number # Above 1 zooms in.
--- @param sx number|nil # The point to hold still; the middle when absent.
--- @param sy number|nil
--
function TeleporterMap:ZoomSmooth(factor, sx, sy)
    local duration = tonumber(self.View.ZoomAnimationMs) or 0
    if not isFinite(duration) or duration <= 0 or not self:_ZoomTimer() then
        self:ZoomBy(factor, sx, sy)
        return
    end
    if type(sx) ~= "number" or type(sy) ~= "number" then
        local width, height = self:Size()
        sx, sy = width / 2, height / 2
    end
    local anim = self:_ZoomStillOurs()
    local from = anim and anim.Target or self.Camera.Scale
    local target = clamp(from * (tonumber(factor) or 1), self.View.MinZoom, self.View.MaxZoom)
    if target == self.Camera.Scale then
        self.ZoomAnim = nil
        self:_ZoomTimerEnabled(false)
        return
    end
    self.ZoomAnim = {
        Target = target, X = sx, Y = sy, Remaining = duration,
        -- The scale the animation last wrote. Anything else that scales the
        -- camera is noticed by this not matching any more.
        Scale = self.Camera.Scale,
    }
    self:_ZoomTimerEnabled(true)
end
registerLuaFunctionHighlight('ZoomSmooth')

--
--- ∑ Advances a zoom in flight by dt milliseconds.
---
---   Each step is a FACTOR, not a difference. Zoom is geometric, so equal
---   fractions of the remaining ratio are what the eye reads as even
---   movement, and every step goes through Geometry.ZoomAt, which keeps the
---   world point under the anchor where it is. Composing steps therefore
---   cannot drift off it. The last step is the whole remaining ratio, so it
---   lands on the target exactly rather than near it.
--- @param dt number # Milliseconds since the last step.
--- @return boolean # Whether an animation is still running.
--
function TeleporterMap:_AdvanceZoom(dt)
    local anim = self:_ZoomStillOurs()
    if not anim then return false end
    dt = tonumber(dt) or 0
    local factor
    if dt >= anim.Remaining or anim.Remaining <= 0 then
        factor = anim.Target / self.Camera.Scale
        anim.Remaining = 0
    else
        factor = (anim.Target / self.Camera.Scale) ^ (dt / anim.Remaining)
        anim.Remaining = anim.Remaining - dt
    end
    local view = self:_View()
    if Geometry.ZoomAt(view, factor, anim.X, anim.Y, self.View.MinZoom, self.View.MaxZoom) then
        self:_Adopt(view)
        anim.Scale = self.Camera.Scale
        self:_MarkViewDirty()
        self:Redraw()
        self:_UpdateInfo()
    end
    if anim.Remaining <= 0 then
        self.ZoomAnim = nil
        self:_ZoomTimerEnabled(false)
        return false
    end
    return true
end

--
--- ∑ Puts a zoom in flight where it was going, at once. For a caller
---   that needs the camera to be at its destination: the view file being
---   written, a test, a script.
--- @return boolean # Whether there was one to finish.
--
function TeleporterMap:SettleZoom()
    if not self:_ZoomStillOurs() then return false end
    self:_AdvanceZoom(math.huge)
    return true
end
registerLuaFunctionHighlight('SettleZoom')

--
--- ∑ Sets the pixels-per-unit scale directly.
--
function TeleporterMap:SetZoom(scale)
    scale = tonumber(scale)
    if not isFinite(scale) or scale <= 0 then return end
    self.Camera.Scale = clamp(scale, self.View.MinZoom, self.View.MaxZoom)
    self.Camera.Fitted = true
    self:_MarkViewDirty()
    self:Redraw()
    self:_UpdateInfo()
end
registerLuaFunctionHighlight('SetZoom')

--
--- ∑ Puts a world point in the middle of the map.
--
function TeleporterMap:CenterOn(wx, wy)
    if not isFinite(wx) or not isFinite(wy) then return end
    self:_CancelZoom()
    self.Camera.X, self.Camera.Y = wx, wy
    self.Camera.Fitted = true
    self:_MarkViewDirty()
    self:Redraw()
    self:_UpdateInfo()
end
registerLuaFunctionHighlight('CenterOn')

--
--- ∑ Moves the view by a screen offset.
--
function TeleporterMap:PanBy(dx, dy)
    self:_CancelZoom()
    local view = self:_View()
    self.Camera.X = self.Camera.X - dx / (view.Scale * view.SignX)
    self.Camera.Y = self.Camera.Y - dy / (view.Scale * view.SignY)
    self:_MarkViewDirty()
    self:Redraw()
    self:_UpdateInfo()
end
registerLuaFunctionHighlight('PanBy')

--
--- ∑ Fits the saves that sit together, and the player when known, into the
---   view. A save far away from every other one is left out rather than
---   allowed to squeeze the rest into a corner - one glitched room on the
---   other side of the world is the usual case - and the status bar says how
---   many were left out. Shift+Home fits those as well.
---   With nothing to fit the view goes to the origin at one pixel per unit.
--- @param includeOutliers boolean|nil # Fit every save, however far away.
--
function TeleporterMap:FitAll(includeOutliers)
    local width, height = self:Size()
    if width <= 0 or height <= 0 then return false end
    local points = {}
    for _, marker in ipairs(self.Markers) do
        if not marker.Dimmed then points[#points + 1] = marker end
    end
    -- How many SAVES are being fitted. The player is fitted too but is not a
    -- save, and counting it made the status line report one more save than
    -- the map has, which is the worst place to be out by one: the line exists
    -- to promise that nothing was lost.
    local saveCount = #points
    local player = self:_PlayerPoint()
    if player then points[#points + 1] = player end
    local bounds, dropped
    -- Compared against true, so a control that hands its own sender to the
    -- click handler does not turn Fit All into Fit Everything.
    if includeOutliers == true then
        bounds, dropped = Geometry.Bounds(points), 0
    else
        bounds, dropped = Geometry.CoreBounds(points, 2)
    end
    if not bounds then
        self.Camera.X, self.Camera.Y, self.Camera.Scale = 0, 0, 1
    else
        local scale, cx, cy = Geometry.Fit(bounds, width, height, 40, 50, self.View.MinZoom, self.View.MaxZoom)
        self.Camera.X, self.Camera.Y, self.Camera.Scale = cx, cy, scale
    end
    self.Camera.Fitted = true
    self:_MarkViewDirty()
    self:Redraw()
    self:_UpdateInfo()
    -- A fit that quietly left saves out would be a map that lost them - but
    -- the point left out can be the player, who is not a save and whose
    -- absence is not a loss. Every dropped point lies outside the box of the
    -- kept ones, so the player's own position answers which case this is.
    local droppedSaves = dropped
    if player and dropped > 0 and bounds
       and not (player.X >= bounds.MinX and player.X <= bounds.MaxX
                and player.Y >= bounds.MinY and player.Y <= bounds.MaxY) then
        droppedSaves = dropped - 1
    end
    -- Kept, because the callers that fit and then write their own status
    -- line have to be able to say this too.
    self.FitDropped = droppedSaves
    if droppedSaves > 0 then
        self:SetStatus(string.format("Fitted %d saves%s", saveCount - droppedSaves, self:FitNote()))
    end
    return bounds ~= nil
end
registerLuaFunctionHighlight('FitAll')

--
--- ∑ What the last fit left out, as a phrase to hang on a status line.
---
---   A phrase rather than a line of its own. SetArea and Show both fit and
---   then write their own status, so a fit that set the line by itself had it
---   overwritten, and the one line that must never be lost is the one that
---   promises nothing was.
--- @return string # Empty when the fit left nothing out.
--
function TeleporterMap:FitNote()
    local dropped = tonumber(self.FitDropped) or 0
    if dropped <= 0 then return "" end
    return string.format(" - %d far away %s left out, Shift+Home fits those too",
                         dropped, dropped == 1 and "save is" or "saves are")
end
registerLuaFunctionHighlight('FitNote')

--
--- ∑ Fits the pile under the pointer, or the one the selection sits in, or
---   the largest one on the map. A count on a heap says how many saves
---   cannot be told apart at this zoom; this is the answer to it, and it is
---   a key and a menu entry rather than a new mouse gesture, because a
---   gesture would have to be tried in Cheat Engine and a key does not.
--
function TeleporterMap:ZoomToPile()
    local marker = self.Hover or self.Selected
    local cluster
    for _, group in ipairs(self.Clusters or {}) do
        if marker then
            for _, member in ipairs(group.Members or {}) do
                if member == marker then cluster = group break end
            end
            if cluster then break end
        end
        if not marker and (not cluster or group.Shown > cluster.Shown) then cluster = group end
    end
    if not cluster or cluster.Shown < 2 then
        self:SetStatus("No pile under the pointer to zoom into")
        return false
    end
    local width, height = self:Size()
    local bounds = Geometry.Bounds(cluster.Members)
    if not bounds or width <= 0 or height <= 0 then return false end
    local scale, cx, cy = Geometry.Fit(bounds, width, height, 60, self.Spacing or 5,
                                       self.View.MinZoom, self.View.MaxZoom)
    self.Camera.X, self.Camera.Y, self.Camera.Scale = cx, cy, scale
    self.Camera.Fitted = true
    self:_MarkViewDirty()
    self:Redraw()
    self:_UpdateInfo()
    self:SetStatus(string.format("Zoomed into %d saves", cluster.Shown))
    return true
end
registerLuaFunctionHighlight('ZoomToPile')

--
--- ∑ Centres the map on the player, when the position is readable.
--
function TeleporterMap:CenterOnPlayer()
    local point = self:_PlayerPoint()
    if not point then
        self:SetStatus("Player position is not readable")
        return false
    end
    self:CenterOn(point.X, point.Y)
    return true
end
registerLuaFunctionHighlight('CenterOnPlayer')

--
--- ∑ Locks the view centre to the player. Panning by hand unlocks it.
--
function TeleporterMap:SetFollow(enabled)
    enabled = enabled == true
    if self.View.FollowPlayer == enabled then return end
    self.View.FollowPlayer = enabled
    if enabled then self:CenterOnPlayer() end
    self:_UpdateToggles()
    self:_MarkViewDirty()
    self:Redraw()
end
registerLuaFunctionHighlight('SetFollow')

--
--- ∑ Flips a boolean View option and repaints. Used by the menu and the
---   keyboard, which is why it takes the option's name.
--
function TeleporterMap:Toggle(option)
    if type(self.View[option]) ~= "boolean" then return end
    if option == "FollowPlayer" then
        self:SetFollow(not self.View.FollowPlayer)
        return
    end
    self.View[option] = not self.View[option]
    if option == "ShowDetails" then self:_ApplyDetailsVisibility() end
    if option == "ScaleByHeight" then self:_ScaleMarkers() end
    self:_UpdateToggles()
    self:_MarkViewDirty()
    self:Redraw()
end
registerLuaFunctionHighlight('Toggle')

function TeleporterMap:FlipHorizontal()
    self.Plane.FlipHorizontal = not self.Plane.FlipHorizontal
    self:_UpdateToggles()
    self:_MarkViewDirty()
    self:Redraw()
end

function TeleporterMap:FlipVertical()
    self.Plane.FlipVertical = not self.Plane.FlipVertical
    self:_UpdateToggles()
    self:_MarkViewDirty()
    self:Redraw()
end
registerLuaFunctionHighlight('FlipHorizontal')
registerLuaFunctionHighlight('FlipVertical')

--------------------------------------------------------
--                       Player                       --
--------------------------------------------------------

--- Readers by value type, for the quiet fallback read. Built on first use,
--- so loading this file where the vt constants and the readers are absent,
--- which is anywhere but Cheat Engine, does not fail at chunk time.
local QUIET_READERS
local function quietReader(valueType)
    if not QUIET_READERS then
        QUIET_READERS = {}
        for _, pair in ipairs({ { "vtByte", "readByte" }, { "vtWord", "readSmallInteger" },
                                { "vtDword", "readInteger" }, { "vtQword", "readQword" },
                                { "vtSingle", "readFloat" }, { "vtDouble", "readDouble" } }) do
            local key, fn = rawget(_G, pair[1]), rawget(_G, pair[2])
            if key ~= nil and type(fn) == "function" then QUIET_READERS[key] = fn end
        end
    end
    if valueType == nil then return nil end
    return QUIET_READERS[valueType]
end

--
--- ∑ Reads the player's position without logging. The Teleporter's own read
---   reports every unresolvable pointer, which is right for a teleport and
---   wrong ten times a second in a loading screen.
--- @return table|nil
--
function TeleporterMap:PeekPlayerPosition()
    if type(teleporter.PeekCurrentPosition) == "function" then
        local ok, position = pcall(teleporter.PeekCurrentPosition, teleporter)
        if ok then return position end
        return nil
    end
    -- An older Teleporter has no quiet read, and its GetCurrentPosition
    -- reports every unresolvable pointer as a forced warning, which is a
    -- disk write per poll. The same read lives here instead, so a 1.4.x
    -- Teleporter still gets the player marker and the poll still logs
    -- nothing. It mirrors GetCurrentPosition: the pointer is "[Symbol]+0"
    -- and the value type is the Transform's own.
    local transform = teleporter.Transform
    if type(transform) ~= "table" or trimString(transform.Symbol) == "" then return nil end
    local offsets = transform.Offsets
    if type(offsets) ~= "table" or #offsets == 0 then return nil end
    local getPid = rawget(_G, "getOpenedProcessID")
    if type(getPid) == "function" and getPid() == 0 then return nil end
    local resolve = rawget(_G, "getAddressSafe")
    if type(resolve) ~= "function" then return nil end
    local ok, base = pcall(resolve, "[" .. trimString(transform.Symbol) .. "]+0")
    if not ok or type(base) ~= "number" or base == 0 then return nil end
    local readFunc = quietReader(transform.ValueType)
    if not readFunc then return nil end
    local position = {}
    for index, offset in ipairs(offsets) do
        local okRead, value = pcall(readFunc, base + offset)
        if not okRead or value == nil then return nil end
        position[index] = value
    end
    return position
end
registerLuaFunctionHighlight('PeekPlayerPosition')

--
--- ∑ The player's last known position on the map plane, or nil.
--
function TeleporterMap:_PlayerPoint()
    local position = self.PlayerPosition
    local h, v = self:GetPlane()
    if not position or not h then return nil end
    if not isFinite(position[h]) or not isFinite(position[v]) then return nil end
    return { X = position[h], Y = position[v] }
end

--
--- ∑ Appends a point to the trail when the player moved far enough, and
---   starts a new segment when the move was a jump.
--
function TeleporterMap:_ExtendTrail(point)
    local trail = self.Trail
    local last = trail[#trail]
    if last and not last.Break then
        local dx, dy = point.X - last.X, point.Y - last.Y
        local distance = math.sqrt(dx * dx + dy * dy)
        if distance < (self.Player.TrailMinDistance or 0) then return false end
        if distance > (self.Player.TrailBreakDistance or math.huge) then
            trail[#trail + 1] = { X = point.X, Y = point.Y, Break = true }
        else
            trail[#trail + 1] = { X = point.X, Y = point.Y }
        end
    else
        trail[#trail + 1] = { X = point.X, Y = point.Y }
    end
    local limit = self.Player.TrailLength or 400
    while #trail > limit do table.remove(trail, 1) end
    return true
end

--
--- ∑ The next trail point starts a new segment. Called after a teleport so
---   the jump is not drawn as a line across the map.
--
function TeleporterMap:_BreakTrail()
    local last = self.Trail[#self.Trail]
    if last then last.Break = true end
end

function TeleporterMap:ClearTrail()
    self.Trail = {}
    self:Redraw()
end
registerLuaFunctionHighlight('ClearTrail')

--
--- ∑ One poll. Reads the player, extends the trail, follows, and repaints
---   when something moved. Runs on the window's timer.
--
function TeleporterMap:Tick()
    local ui = self.UiState
    if not ui or not ui.Form then return end
    if safeGet(ui.Form, "Visible") == false then return end
    self:_SyncMarkers()
    self.TickCount = (self.TickCount or 0) + 1
    local backoff = self.Player.FailureBackoff or 5
    local slow = (self.PlayerFailures or 0) >= backoff
    local moved = false
    if not slow or self.TickCount % 10 == 0 then
        local position = self:PeekPlayerPosition()
        if position then
            local previous = self.PlayerPosition
            self.PlayerPosition = position
            self.PlayerFailures = 0
            moved = previous == nil
            if previous then
                for index = 1, #position do
                    if position[index] ~= previous[index] then moved = true break end
                end
            end
            if moved then
                local point = self:_PlayerPoint()
                if point then
                    self:_ExtendTrail(point)
                    if self.View.FollowPlayer then
                        self.Camera.X, self.Camera.Y = point.X, point.Y
                    end
                end
                if not self.Camera.Fitted then self:FitAll() end
                self:_FollowHeightBand()
            end
        else
            self.PlayerFailures = (self.PlayerFailures or 0) + 1
            if self.PlayerPosition and self.PlayerFailures >= backoff then
                -- Stale now. Painted faint until a read succeeds again.
                self.PlayerStale = true
                moved = true
            end
        end
        if position then self.PlayerStale = false end
    end
    if moved or self.Dirty then
        self:Redraw()
        self:_UpdateInfo()
    end
    self:_FlushViewFile()
end
registerLuaFunctionHighlight('Tick')

--------------------------------------------------------
--                      Teleport                      --
--------------------------------------------------------

--
--- ∑ Asks before a jump when View.ConfirmTeleport is on.
---   A build without the dialog, or one whose dialog raises, is treated as
---   a yes and reported once, so the option can never lock the map. That
---   is the behaviour the map had before the option existed.
--- @param what string # Named in the question.
--- @return boolean
--
function TeleporterMap:_ConfirmTeleport(what)
    if not self.View.ConfirmTeleport then return true end
    return self:_Ask("Teleport to " .. tostring(what) .. "?")
end

--
--- ∑ A Yes/No question. A build without the dialog, or one whose dialog
---   raises, is treated as a yes and reported once, so no option can lock
---   the map. The map's edits of a save ask through this every time.
--- @param question string
--- @return boolean
--
function TeleporterMap:_Ask(question)
    local dialog = rawget(_G, "messageDialog")
    local ok, answer
    if type(dialog) == "function" then
        ok, answer = pcall(dialog, question, rawget(_G, "mtConfirmation"), rawget(_G, "mbYes"), rawget(_G, "mbNo"))
    else
        ok, answer = false, "messageDialog is not available"
    end
    if not ok then
        if not self.ConfirmFailed then
            self.ConfirmFailed = true
            logger:WarningF(MODULE_PREFIX .. " The confirmation dialog failed, proceeding without it: %s", tostring(answer))
        end
        return true
    end
    return answer == rawget(_G, "mrYes")
end

--
--- ∑ Jumps to a marker's save.
--
function TeleporterMap:TeleportToMarker(marker)
    if not marker then return false end
    if not inMainThread() then
        synchronize(function() self:TeleportToMarker(marker) end)
        return
    end
    if not self:_ConfirmTeleport("'" .. marker.Name .. "'") then
        self:SetStatus("Teleport cancelled: " .. marker.Name)
        return false
    end
    self:_BreakTrail()
    local ok = teleporter:TeleportToSave(marker.Key)
    self:SetStatus(ok and ("Teleported to " .. marker.Name) or ("Teleport failed: " .. marker.Name))
    return ok
end
registerLuaFunctionHighlight('TeleportToMarker')

--
--- ∑ Jumps to the selected marker, which the toolbar and the menu call.
--
function TeleporterMap:TeleportToSelected()
    if not self.Selected then
        self:SetStatus("No save selected")
        return false
    end
    return self:TeleportToMarker(self.Selected)
end
registerLuaFunctionHighlight('TeleportToSelected')

--
--- ∑ The full position for a point on the map plane: the plane components
---   from the point, every other component from where the player is now.
---   A 3D game therefore keeps its height, which the Teleporter then lifts
---   by its own adjustment as it does for every jump.
--- @return table|nil
--
function TeleporterMap:PositionForPoint(wx, wy, keepPlayerHeight, source)
    local base = self:PeekPlayerPosition() or self.PlayerPosition
    if not base then return nil end
    local h, v = self:GetPlane()
    if not h then return nil end
    local position = {}
    for index = 1, #base do position[index] = base[index] end
    position[h], position[v] = wx, wy
    if not keepPlayerHeight then
        local up = self:HeightAxis()
        -- The caller may have resolved the source already, before asking
        -- the user. Looking it up a second time here would answer with
        -- whatever is shown NOW, which the dialog was open long enough to
        -- change, and the jump would not match the question.
        local nearest = up and (source or self:_HeightSource(wx, wy)) or nil
        if nearest then
            position[up] = nearest.Height
            source = nearest
        end
    else
        source = nil
    end
    return position, source
end
registerLuaFunctionHighlight('PositionForPoint')

--
--- ∑ The save whose height a point on the map takes: the closest marker on
---   the map plane within View.HeightSnapRadius that is shown and has a
---   height. nil when none is, or snapping is off.
--- @return table|nil # The marker.
--
function TeleporterMap:_HeightSource(wx, wy)
    local radius = tonumber(self.View.HeightSnapRadius) or 0
    if not isFinite(radius) or radius <= 0 then return nil end
    if not self:HeightAxis() then return nil end
    local best, bestDistance = nil, radius * radius
    for _, marker in ipairs(self.Markers) do
        if not marker.Dimmed and isFinite(marker.Height) then
            local dx, dy = marker.X - wx, marker.Y - wy
            local distance = dx * dx + dy * dy
            if distance <= bestDistance then
                best, bestDistance = marker, distance
            end
        end
    end
    return best
end

--
--- ∑ Jumps to a point on the map plane.
--
function TeleporterMap:TeleportToPoint(wx, wy, keepPlayerHeight)
    if not inMainThread() then
        synchronize(function() self:TeleportToPoint(wx, wy, keepPlayerHeight) end)
        return
    end
    local h, _, hName, vName = self:GetPlane()
    if not h or not (self:PeekPlayerPosition() or self.PlayerPosition) then
        self:SetStatus("Player position is not readable, cannot teleport")
        return false
    end
    local where = string.format("%s %s, %s %s", hName or "X", Geometry.FormatUnits(math.floor(wx * 100 + 0.5) / 100),
                                vName or "Y", Geometry.FormatUnits(math.floor(wy * 100 + 0.5) / 100))
    local source = (not keepPlayerHeight) and self:_HeightSource(wx, wy) or nil
    if source then
        where = where .. " (height from '" .. source.Name .. "')"
    end
    if not self:_ConfirmTeleport(where) then
        self:SetStatus("Teleport cancelled")
        return false
    end
    -- Read after the answer, not before it. The dialog can stay open for a
    -- while and the game keeps running, so the height comes from where the
    -- player is now, which is what the jump promises to keep.
    local position = self:PositionForPoint(wx, wy, keepPlayerHeight, source)
    if not position then
        self:SetStatus("Player position is not readable, cannot teleport")
        return false
    end
    self:_BreakTrail()
    local ok = teleporter:TeleportToCoordinates(position)
    self:SetStatus(ok and ("Teleported to " .. where) or "Teleport failed")
    return ok
end
registerLuaFunctionHighlight('TeleportToPoint')

--
--- ∑ Creates a save at a point on the map plane, asking for its name.
--
function TeleporterMap:AddSaveAtPoint(wx, wy)
    if not inMainThread() then
        synchronize(function() self:AddSaveAtPoint(wx, wy) end)
        return
    end
    local position = self:PositionForPoint(wx, wy)
    if not position then
        self:SetStatus("Player position is not readable, cannot add a save here")
        return false
    end
    if type(teleporter.CreateSaveAtPosition) ~= "function" then
        self:SetStatus("This Teleporter cannot create a save at a point")
        return false
    end
    local name = inputQuery("Add Save", "Enter a name for the new save:", "Location")
    if not name or trimString(name) == "" then return false end
    -- A save made while one area is shown belongs to it. That is the only
    -- place the map writes an area on its own.
    local area = type(self.Area.Selected) == "string" and self.Area.Selected or nil
    local ok = teleporter:CreateSaveAtPosition(position, name, nil, nil, area)
    if ok then
        self:RebuildMarkers()
        local key = teleporter:MakeSaveKey(nil, name)
        local marker = key and self:FindMarker(key)
        if marker then self:SelectMarker(marker) end
        self:SetStatus("Save created: " .. name)
    end
    return ok
end
registerLuaFunctionHighlight('AddSaveAtPoint')

--
--- ∑ Duplicates the save behind a marker, next to it in the same category.
--
function TeleporterMap:DuplicateMarker(marker)
    if not marker then return false end
    if type(teleporter.DuplicateSave) ~= "function" then
        self:SetStatus("This Teleporter cannot duplicate a save by key")
        return false
    end
    return teleporter:DuplicateSave(marker.Key) == true
end
registerLuaFunctionHighlight('DuplicateMarker')

--
--- ∑ Moves a save to where the player stands, or only its height there.
---   Always asks: a wrong click in a menu must not rewrite a save.
--- @param marker table
--- @param heightOnly boolean
--
function TeleporterMap:MoveSaveToPlayer(marker, heightOnly)
    if not marker then return false end
    if not inMainThread() then
        synchronize(function() self:MoveSaveToPlayer(marker, heightOnly) end)
        return
    end
    if type(teleporter.SetSavePosition) ~= "function" then
        self:SetStatus("This Teleporter cannot move a save")
        return false
    end
    local player = self:PeekPlayerPosition() or self.PlayerPosition
    if not player then
        self:SetStatus("Player position is not readable, cannot move the save")
        return false
    end
    local position = {}
    if heightOnly then
        local up = self:HeightAxis()
        if not up or not marker.Position then
            self:SetStatus("This table has no height axis")
            return false
        end
        for index = 1, #marker.Position do position[index] = marker.Position[index] end
        position[up] = player[up]
    else
        for index = 1, #player do position[index] = player[index] end
    end
    local question = heightOnly and ("Set the height of '" .. marker.Name .. "' to the player's?")
                                 or ("Move '" .. marker.Name .. "' to the player's position?")
    if not self:_Ask(question) then
        self:SetStatus("Move cancelled")
        return false
    end
    local ok = teleporter:SetSavePosition(marker.Key, position) == true
    if ok then
        self:SetStatus((heightOnly and "Height set: " or "Moved: ") .. marker.Name)
    end
    return ok
end
registerLuaFunctionHighlight('MoveSaveToPlayer')

--
--- ∑ Puts a save's coordinates on the clipboard, comma separated, in axis
---   order.
--
function TeleporterMap:CopyCoordinates(marker)
    if not marker or type(marker.Position) ~= "table" then return false end
    local parts = {}
    for index, value in ipairs(marker.Position) do parts[index] = Geometry.FormatUnits(value) end
    local text = table.concat(parts, ", ")
    local copy = rawget(_G, "writeToClipboard")
    if type(copy) ~= "function" then
        self:SetStatus("The clipboard is not available")
        return false
    end
    local ok = pcall(copy, text)
    self:SetStatus(ok and ("Copied: " .. text) or "Copy failed")
    return ok
end
registerLuaFunctionHighlight('CopyCoordinates')

--
--- ∑ Deletes the selected save through the Teleporter's own question, so
---   the map never asks about a deletion in words of its own. Delete.
--- @return boolean
--
function TeleporterMap:DeleteSelectedSave()
    if not self.Selected then return false end
    return teleporter:DeleteSave(self.Selected.Key) == true
end
registerLuaFunctionHighlight('DeleteSelectedSave')

--
--- ∑ Renames the selected save through the Teleporter's own prompt. F2.
--- @return boolean
--
function TeleporterMap:RenameSelectedSave()
    if not self.Selected then return false end
    return teleporter:RenameSave(self.Selected.Key) == true
end
registerLuaFunctionHighlight('RenameSelectedSave')

--
--- ∑ Opens the Teleporter window with the selected save in its editor.
--
function TeleporterMap:OpenInEditor()
    local marker = self.Selected
    if not marker then return false end
    if type(teleporter.InitTeleporterUI) ~= "function" then return false end
    teleporter:InitTeleporterUI()
    teleporter:SetSelectedSaveName(marker.Key)
    teleporter:RefreshUi(true)
    return true
end
registerLuaFunctionHighlight('OpenInEditor')

--------------------------------------------------------
--                    Persistence                     --
--------------------------------------------------------

--
--- ∑ Where the view for this target is remembered, or nil when the pieces
---   that name it are not loaded.
--
function TeleporterMap:GetViewFilePath()
    if not self.Settings.PersistView then return nil end
    if type(customIO) ~= "table" or type(utils) ~= "table" then return nil end
    if type(teleporter.EnsureTeleporterDir) ~= "function" then return nil end
    local ok, dir = pcall(teleporter.EnsureTeleporterDir, teleporter)
    if not ok or not dir then return nil end
    local okTarget, target = pcall(utils.GetTargetNoExt, utils)
    if not okTarget or not target or target == "" then return nil end
    return dir .. "\\" .. string.format(self.Settings.ViewFileName, target)
end
registerLuaFunctionHighlight('GetViewFilePath')

function TeleporterMap:_MarkViewDirty()
    self.ViewDirtyTicks = 0
    self.ViewDirty = true
end

--
--- ∑ Writes the view file once the camera has been still for a second.
---   Called from Tick, so a pan does not write a file per mouse move.
--
function TeleporterMap:_FlushViewFile()
    if not self.ViewDirty then return end
    self.ViewDirtyTicks = (self.ViewDirtyTicks or 0) + 1
    local ticksPerSecond = math.max(1, math.floor(1000 / (self.Player.RefreshInterval or 100)))
    if self.ViewDirtyTicks < ticksPerSecond then return end
    self:SaveView()
end

--
--- ∑ Writes the camera, the plane and its flips, the boolean toggles, the
---   height band, the shown area and one camera per area to the view file.
--- @return boolean
--
function TeleporterMap:SaveView()
    self.ViewDirty = false
    local path = self:GetViewFilePath()
    if not path then return false end
    local data = {
        Zoom = self.Camera.Scale, CenterX = self.Camera.X, CenterY = self.Camera.Y,
        Plane = {
            Horizontal = self.Plane.Horizontal, Vertical = self.Plane.Vertical,
            FlipHorizontal = self.Plane.FlipHorizontal, FlipVertical = self.Plane.FlipVertical,
        },
        View = {},
        HeightBand = tonumber(self.View.HeightBand) or 0,
        Area = {
            Kind = (self.Area.Selected == nil and "all") or (self.Area.Selected == AREA_NONE and "none") or "area",
            Name = type(self.Area.Selected) == "string" and self.Area.Selected or nil,
        },
        AreaViews = self.AreaViews,
    }
    for _, key in ipairs({ "FollowPlayer", "ShowGrid", "ShowRulers", "ShowLabels", "ShowTrail",
                           "ShowDetails", "OneClickTeleport", "ConfirmTeleport", "ScaleByHeight" }) do
        data.View[key] = self.View[key]
    end
    local ok, err = customIO:WriteToFileAsJson(path, data)
    if not ok then
        logger:WarningBlock(MODULE_PREFIX .. " Could not remember the view", {
            { "File",   path },
            { "Reason", tostring(err or "unknown error") },
        })
    end
    return ok
end
registerLuaFunctionHighlight('SaveView')

--
--- ∑ Reads back what SaveView wrote. A field the file does not carry keeps
---   its configured value, so a view file written by an older version is
---   read without complaint.
--- @return boolean
--
function TeleporterMap:LoadView()
    local path = self:GetViewFilePath()
    if not path then return false end
    if type(customIO.FileExists) == "function" and not customIO:FileExists(path) then return false end
    local data = customIO:ReadFromFileAsJson(path)
    if type(data) ~= "table" then return false end
    if isFinite(tonumber(data.Zoom)) and tonumber(data.Zoom) > 0 then
        self.Camera.Scale = clamp(tonumber(data.Zoom), self.View.MinZoom, self.View.MaxZoom)
        self.Camera.X = tonumber(data.CenterX) or 0
        self.Camera.Y = tonumber(data.CenterY) or 0
        self.Camera.Fitted = true
    end
    if type(data.Plane) == "table" then
        self.Plane.Horizontal = tonumber(data.Plane.Horizontal)
        self.Plane.Vertical = tonumber(data.Plane.Vertical)
        self.Plane.FlipHorizontal = data.Plane.FlipHorizontal == true
        self.Plane.FlipVertical = data.Plane.FlipVertical == true
    end
    if type(data.View) == "table" then
        for key, value in pairs(data.View) do
            if type(self.View[key]) == "boolean" and type(value) == "boolean" then
                self.View[key] = value
            end
        end
    end
    if isFinite(tonumber(data.HeightBand)) then
        self.View.HeightBand = math.max(0, tonumber(data.HeightBand))
    end
    if type(data.Area) == "table" then
        if data.Area.Kind == "none" then
            self.Area.Selected = AREA_NONE
        elseif data.Area.Kind == "area" and type(data.Area.Name) == "string" and data.Area.Name ~= "" then
            self.Area.Selected = data.Area.Name
        else
            self.Area.Selected = nil
        end
    end
    if type(data.AreaViews) == "table" then
        -- A key written before 1.2.1 carries no plane. A camera is a centre on
        -- two axes, so it only means anything on the plane it was framed on,
        -- and a file that never set a plane was framed on the derived one,
        -- which is the plane the map draws now. Those keys are carried over
        -- under it; a key that already names a plane wins. With an explicit
        -- plane the old keys cannot be placed, and dropping them costs a refit.
        local views = {}
        local derived = self.Plane.Horizontal == nil and self.Plane.Vertical == nil
        local h, v = self:GetPlane()
        local suffix = "@" .. tostring(h or "?") .. "/" .. tostring(v or "?")
        for key, view in pairs(data.AreaViews) do
            if type(key) == "string" and type(view) == "table" then
                if key:find("@", 1, true) then
                    views[key] = view
                elseif derived and views[key .. suffix] == nil then
                    views[key .. suffix] = view
                end
            end
        end
        self.AreaViews = views
    end
    self:_ScaleMarkers()
    return true
end
registerLuaFunctionHighlight('LoadView')

--------------------------------------------------------
--                      Surface                       --
--------------------------------------------------------

--
--- ∑ Creates the paint surface inside parent and wires its events.
---   createPaintBox gives a control with a Canvas and OnPaint, painted from
---   an off-screen bitmap. createImage is the fallback, whose picture bitmap
---   is already off screen.
--- @return boolean, string|nil
--
function TeleporterMap:_AttachSurface(parent)
    self.SurfaceParent = parent
    local createPaintBox = rawget(_G, "createPaintBox")
    if type(createPaintBox) == "function" then
        local ok, box = pcall(createPaintBox, parent)
        if ok and box then
            self.Surface, self.SurfaceKind = box, "paintbox"
        end
    end
    if not self.Surface then
        local createImage = rawget(_G, "createImage")
        if type(createImage) == "function" then
            local ok, image = pcall(createImage, parent)
            if ok and image then
                self.Surface, self.SurfaceKind = image, "image"
                safeSet(image, "Stretch", false)
                safeSet(image, "Center", false)
                safeSet(image, "AutoSize", false)
            end
        end
    end
    if not self.Surface then
        return false, "this Cheat Engine has neither createPaintBox nor createImage"
    end
    safeSet(self.Surface, "Parent", parent)
    safeSet(self.Surface, "Align", "alClient")
    self:_WireEvents()
    return true
end

--
--- ∑ Wraps an event handler so a defect in it is reported once through the
---   logger instead of once per mouse move into the Lua Engine window.
--
function TeleporterMap:_Guard(name, fn)
    return function(...)
        local ok, result = pcall(fn, ...)
        if ok then return result end
        local message = tostring(result)
        if self.LastGuardError ~= message then
            self.LastGuardError = message
            logger:ErrorF(MODULE_PREFIX .. " %s failed: %s", name, message)
        end
    end
end

function TeleporterMap:_WireEvents()
    local surface = self.Surface
    if self.SurfaceKind == "paintbox" then
        safeSet(surface, "OnPaint", self:_Guard("paint", function() self:_Present() end))
    end
    safeSet(surface, "OnResize", self:_Guard("resize", function() self:_OnResize() end))
    safeSet(surface, "OnMouseDown", self:_Guard("mouse down", function(_, button, ...)
        local x, y = coordinates(...)
        self:_MouseDown(button, x, y)
    end))
    safeSet(surface, "OnMouseUp", self:_Guard("mouse up", function(_, button, ...)
        local x, y = coordinates(...)
        self:_MouseUp(button, x, y)
    end))
    safeSet(surface, "OnMouseMove", self:_Guard("mouse move", function(_, ...)
        local x, y = coordinates(...)
        self:_MouseMove(x, y)
    end))
    safeSet(surface, "OnMouseLeave", self:_Guard("mouse leave", function() self:_MouseLeave() end))
    safeSet(surface, "OnDblClick", self:_Guard("double click", function() self:_DoubleClick() end))
    -- Up and Down only. TControl.DoMouseWheel calls OnMouseWheel first and
    -- falls through to DoMouseWheelUp/Down only when it did not report the
    -- event handled, so setting both zooms twice a notch. A paint box has
    -- no window handle, so the wheel reaches the parent panel too.
    local up = self:_Guard("wheel up", function()
        self:ZoomSmooth(self.View.ZoomStep or 1.25, self:_WheelPoint())
        return true
    end)
    local down = self:_Guard("wheel down", function()
        self:ZoomSmooth(1 / (self.View.ZoomStep or 1.25), self:_WheelPoint())
        return true
    end)
    for _, control in ipairs({ surface, self.SurfaceParent }) do
        safeSet(control, "OnMouseWheelUp", up)
        safeSet(control, "OnMouseWheelDown", down)
    end
end

--- Where a wheel notch zooms around: the cursor while it is over the map,
--- the middle otherwise.
function TeleporterMap:_WheelPoint()
    local mouse = self.Mouse
    if mouse then return mouse.X, mouse.Y end
    return nil, nil
end

--
--- ∑ Size of the drawable area.
--- @return number, number
--
function TeleporterMap:Size()
    local width, height = 0, 0
    pcall(function()
        width = tonumber(self.Surface.Width) or 0
        height = tonumber(self.Surface.Height) or 0
    end)
    return width, height
end

--
--- ∑ The canvas to render into, plus a function that puts it on screen.
---   Grow-only buffer: a resize drag delivers a size per WM_SIZE, and a
---   buffer larger than the control is harmless.
--- @return userdata|nil, function|nil
--
function TeleporterMap:_AcquireCanvas(width, height)
    if width <= 0 or height <= 0 then return nil end
    if self.SurfaceKind == "image" then
        local canvas
        local ok = pcall(function()
            local bitmap = self.PictureBitmap
            if not bitmap then
                bitmap = self.Surface.Picture.Bitmap
                self.PictureBitmap = bitmap
            end
            if tonumber(bitmap.Width) ~= width then bitmap.Width = width end
            if tonumber(bitmap.Height) ~= height then bitmap.Height = height end
            canvas = bitmap.Canvas
        end)
        if not ok or not canvas then
            self.PictureBitmap = nil
            return nil
        end
        return canvas, function() pcall(function() self.Surface.repaint() end) end
    end
    local create = rawget(_G, "createBitmap")
    if type(create) ~= "function" then return nil end
    if self.Buffer and (self.BufferWidth < width or self.BufferHeight < height) then
        pcall(function() self.Buffer.destroy() end)
        self.Buffer = nil
    end
    if not self.Buffer then
        local needWidth = math.max(width, self.BufferWidth or 0)
        local needHeight = math.max(height, self.BufferHeight or 0)
        local ok, bitmap = pcall(create, needWidth, needHeight)
        if not ok or not bitmap then return nil end
        self.Buffer = bitmap
        self.BufferWidth, self.BufferHeight = needWidth, needHeight
    end
    local canvas
    if not pcall(function() canvas = self.Buffer.Canvas end) or not canvas then return nil end
    return canvas, function() pcall(function() self.Surface.repaint() end) end
end

--- Blits the buffer. Only the paint box path needs it.
function TeleporterMap:_Present()
    if self.SurfaceKind ~= "paintbox" or not self.Buffer then return end
    pcall(function() self.Surface.Canvas.draw(0, 0, self.Buffer) end)
end

function TeleporterMap:_OnResize()
    if not self.Camera.Fitted then
        self:FitAll()
    else
        self:Redraw()
    end
end

--------------------------------------------------------
--                      Painting                      --
--------------------------------------------------------

local DEFAULT_PALETTE = {
    COLOR_BG           = 0x202020,
    COLOR_PANEL        = 0x2A2A2A,
    COLOR_ACCENT       = 0x4A4A4A,
    COLOR_TEXT         = 0xEAEAEA,
    COLOR_LABEL        = 0xC8C8C8,
    COLOR_BTN          = 0x2A2A2A,
    COLOR_BTN_HOVER    = 0x4A4A4A,
    COLOR_BTN_TEXT     = 0xEAEAEA,
    COLOR_TAB_ACTIVE   = 0x4A4A4A,
    COLOR_TAB_INACTIVE = 0x2A2A2A,
    COLOR_INPUT        = 0x1B1B1B,
    COLOR_INPUT_TEXT   = 0xEAEAEA,
    COLOR_BORDER       = 0x454545,
    COLOR_MUTED        = 0x8A8A8A,
    COLOR_SURFACE      = 0x2F2F2F,
    COLOR_SURFACE_ALT  = 0x242424,
    COLOR_SUCCESS      = 0x6FD96F,
}

--
--- ∑ The Forms palette the window is built in: the table's active design
---   theme when one is applied, the Forms defaults otherwise.
--
function TeleporterMap:Palette()
    local palette = type(forms) == "table" and forms.ActiveDesignTheme
    if type(palette) == "table" and palette.COLOR_BG then return palette end
    return DEFAULT_PALETTE
end
registerLuaFunctionHighlight('Palette')

--
--- ∑ Every colour the canvas uses, derived from the palette and cached
---   against it. The palette changes when a theme is applied, which is a
---   new table, so comparing the reference is the exact check.
--
function TeleporterMap:Colors()
    local palette = self:Palette()
    if self.CachedPalette == palette and self.CachedColors then return self.CachedColors end
    local bg = palette.COLOR_INPUT
    -- The ramp answers with the colour its salient end ended up being, which
    -- is the accent on every palette whose accent can be seen on its own
    -- canvas - every bundled one - and a lifted version of it on any other.
    local ramp, accent = heightRamp(palette.COLOR_ACCENT, bg, HEIGHT_BANDS)
    local colors = {
        Background   = bg,
        -- The grid is scenery, not data. It is derived from the muted token
        -- and mixed most of the way back into the surface, because
        -- COLOR_BORDER is the accent in every bundled theme and a grid in
        -- the marker colour competes with the markers.
        GridMinor    = mixColor(bg, palette.COLOR_MUTED, 0.22),
        GridMajor    = mixColor(bg, palette.COLOR_MUTED, 0.36),
        Axis         = mixColor(bg, palette.COLOR_MUTED, 0.55),
        -- The numbers along the edge are read, not glanced at, so they go
        -- through readable() like the rest of the HUD. The muted token on its
        -- own sits too close to the canvas to be read on Dark-Dark-Hell. This
        -- lands where Hud does and keeps its own name, because the two can
        -- need to part company later.
        Ruler        = readable(palette.COLOR_MUTED, palette.COLOR_LABEL, bg),
        Marker       = accent,
        -- A filtered out save is hollow, not faint. Faint has to mean one
        -- thing on this map, and now that the ramp owns how bright a disc
        -- is, faint means high. An outline means "not on this map today".
        MarkerDim    = mixColor(bg, palette.COLOR_MUTED, 0.65),
        MarkerHover  = palette.COLOR_TEXT,
        -- Every disc is drawn on a ring of the surface colour, so two discs
        -- that touch still read as two discs. This is that ring.
        Halo         = bg,
        Selection    = palette.COLOR_TEXT,
        -- Height as one hue in steps of OKLab lightness. Ramp[1] is the
        -- highest band and the most recessive, the last is the lowest band
        -- and the accent itself, which agrees with the size: a low save is
        -- the large bright one. nil when this palette cannot hold two steps
        -- clear of its own surface, and every marker is then the accent.
        Ramp         = ramp,
        Label        = palette.COLOR_LABEL,
        LabelDim     = mixColor(bg, palette.COLOR_LABEL, 0.45),
        LabelBox     = bg,
        -- A count on a pile wears a muted outline, but the number inside it
        -- has to be read, the same as the ruler's.
        Badge        = readable(palette.COLOR_MUTED, palette.COLOR_LABEL, bg),
        BadgeEdge    = mixColor(bg, palette.COLOR_MUTED, 0.55),
        Player       = palette.COLOR_SUCCESS,
        PlayerEdge   = bg,
        PlayerStale  = mixColor(bg, palette.COLOR_SUCCESS, 0.4),
        Trail        = mixColor(bg, palette.COLOR_SUCCESS, 0.55),
        -- The bar's rules are scenery and stay muted; its caption is a
        -- number and goes through Hud with the legend's two numbers.
        ScaleBar     = palette.COLOR_MUTED,
        Hud          = readable(palette.COLOR_MUTED, palette.COLOR_LABEL, bg),
        -- The card under the pointer, lifted off the canvas by a tenth of
        -- the text colour and outlined, so it reads as one object over
        -- whatever it covers.
        CardFill     = mixColor(bg, palette.COLOR_TEXT, 0.10),
        CardEdge     = mixColor(bg, palette.COLOR_TEXT, 0.40),
        CardText     = palette.COLOR_LABEL,
        CardMuted    = mixColor(bg, palette.COLOR_LABEL, 0.70),
    }
    -- A filtered out save must never shout louder than one that matched. On a
    -- palette whose accent sits close to its own surface there is no ramp to
    -- be quieter than, and the muted token can land brighter than the marker
    -- colour itself, which says the opposite of what dim means.
    local quietest = (ramp and ramp[1]) or accent
    if contrastRatio(colors.MarkerDim, bg) > contrastRatio(quietest, bg) then
        colors.MarkerDim = mixColor(bg, quietest, 0.55)
    end
    self.CachedPalette = palette
    self.CachedColors = colors
    return colors
end
registerLuaFunctionHighlight('Colors')

--- Schedules a repaint for the next tick, for changes that arrive in bursts.
function TeleporterMap:Invalidate()
    self.Dirty = true
end
registerLuaFunctionHighlight('Invalidate')

--
--- ∑ Renders a frame. One protected call for the whole frame, not one per
---   drawing operation. Five consecutive failures stop the map instead of
---   filling the log.
--- @return boolean
--
function TeleporterMap:Redraw()
    if not self.Surface or self.Painting or self.PaintDisabled then return false end
    self.Painting = true
    local ok, err = pcall(self._Frame, self)
    self.Painting = false
    self.Dirty = false
    if ok then
        self.PaintFailures = 0
        return true
    end
    self.PaintFailures = (self.PaintFailures or 0) + 1
    if self.PaintFailures == 1 then
        logger:ErrorF(MODULE_PREFIX .. " Paint failed: %s", tostring(err))
    end
    if self.PaintFailures >= 5 then
        self.PaintDisabled = true
        logger:Error(MODULE_PREFIX .. " The map stopped painting after 5 consecutive failures.")
    end
    return false
end
registerLuaFunctionHighlight('Redraw')

--
--- ∑ How wide a disc may be drawn at this zoom: never wider than the room a
---   save has beside its nearest neighbour. Far out that shrinks the discs
---   to a floor, so a crowd stays a set of marks instead of one texture;
---   close in it is 1 and nothing is shrunk at all.
---
---   It follows the zoom and the saves, never the count on screen, so a
---   disc does not change size while the map is panned and the ratio
---   between a low disc and a high one - which is the encoding - is the
---   same at every zoom.
--
function TeleporterMap:_DiscScale(view)
    local spacing = tonumber(self.Spacing)
    if not spacing or not isFinite(spacing) or spacing <= 0 then return 1 end
    local base = tonumber(self.View.MarkerRadius) or 5
    local widest = base * self:_HeightScaleMax() + MARKER_HALO
    if widest <= 0 then return 1 end
    return clamp(spacing * view.Scale / (2 * widest), DISC_FLOOR, 1)
end

function TeleporterMap:_Frame()
    local width, height = self:Size()
    local canvas, present = self:_AcquireCanvas(width, height)
    if not canvas then return end
    local view = self:_View(width, height)
    local colors = self:Colors()
    self:_EnsureScaled()
    if self.EmptyStyle == nil then
        self.EmptyStyle = pcall(function() canvas.Font.Style = "[]" end) and "[]" or ""
    end
    local font = canvas.Font
    font.Name = "Consolas"
    font.Size = self.View.FontSize or 9
    font.Style = self.EmptyStyle
    canvas.Brush.Color = colors.Background
    canvas.fillRect(0, 0, width, height)
    self.DiscScale = self:_DiscScale(view)
    local step = Geometry.NiceStep(view.Scale, self.View.GridTargetPixels or 72)
    if self.View.ShowGrid then self:_PaintGrid(canvas, view, colors, step) end
    if self.View.ShowTrail then self:_PaintTrail(canvas, view, colors) end
    -- The corner readouts are painted BEFORE the markers and the rectangles
    -- they took are kept, so a label can keep clear of them and a disc that
    -- happens to sit over one is still drawn. Chrome that covers data is the
    -- one thing a reader cannot argue with; a save over the scale bar is.
    local hud = {}
    for _, rect in ipairs(self.View.ShowRulers and self:_PaintRulers(canvas, view, colors, step) or {}) do
        hud[#hud + 1] = rect
    end
    -- The scale bar is painted after the rulers and knows what they took,
    -- because the two share the bottom left corner and "0" beside "200 u"
    -- reads as one string.
    hud[#hud + 1] = self:_PaintScaleBar(canvas, view, colors, false, hud)
    hud[#hud + 1] = self:_PaintHeightLegend(canvas, view, colors)
    -- The player is painted over the markers but measured with the chrome,
    -- so no name is placed where its crosshair and its word will be.
    hud[#hud + 1] = self:_PaintPlayer(canvas, view, colors, true)
    self.HudRects = hud
    self:_PaintMarkers(canvas, view, colors)
    self:_PaintPlayer(canvas, view, colors)
    -- The card is not chrome: it is the answer to what the pointer is on,
    -- and it is placed by the same avoider as the labels, so it lands beside
    -- the pile it describes rather than on it.
    self:_PaintHoverCard(canvas, view, colors)
    present()
end

--- The visible world range on each axis, low to high whatever the flips.
local function visibleRange(view)
    local x0, y0 = Geometry.Unproject(view, 0, 0)
    local x1, y1 = Geometry.Unproject(view, view.Width, view.Height)
    return math.min(x0, x1), math.max(x0, x1), math.min(y0, y1), math.max(y0, y1)
end

--
--- ∑ Grid lines every step units, a stronger line every fifth, and the two
---   axes through the origin strongest. Three passes so the strong lines
---   are drawn over the weak ones where they meet.
--
function TeleporterMap:_PaintGrid(canvas, view, colors, step)
    local minX, maxX, minY, maxY = visibleRange(view)
    local pen = canvas.Pen
    pen.Width = 1
    local function lines(pass)
        local k0, k1 = math.floor(minX / step), math.ceil(maxX / step)
        -- Guarded twice over: the step is chosen from the scale, so this is
        -- about thirty lines, but a corrupt camera must not loop forever.
        if k1 - k0 > 400 then return end
        for k = k0, k1 do
            local kind = k == 0 and 3 or (k % 5 == 0 and 2 or 1)
            if kind == pass then
                local sx = select(1, Geometry.Project(view, k * step, 0))
                sx = math.floor(sx + 0.5)
                canvas.line(sx, 0, sx, view.Height)
            end
        end
        k0, k1 = math.floor(minY / step), math.ceil(maxY / step)
        if k1 - k0 > 400 then return end
        for k = k0, k1 do
            local kind = k == 0 and 3 or (k % 5 == 0 and 2 or 1)
            if kind == pass then
                local _, sy = Geometry.Project(view, 0, k * step)
                sy = math.floor(sy + 0.5)
                canvas.line(0, sy, view.Width, sy)
            end
        end
    end
    pen.Color = colors.GridMinor
    lines(1)
    pen.Color = colors.GridMajor
    lines(2)
    pen.Color = colors.Axis
    lines(3)
end

--
--- ∑ World values along the top and left edges, on every fifth grid line.
---   Text is painted with the background brush, which erases the grid line
---   under it, so a label is never struck through.
--- @return table # The rectangles it drew, for the label placer.
--
function TeleporterMap:_PaintRulers(canvas, view, colors, step)
    local minX, maxX, minY, maxY = visibleRange(view)
    local major = step * 5
    canvas.Font.Color = colors.Ruler
    canvas.Brush.Color = colors.Background
    local textHeight = tonumber(canvas.getTextHeight("0")) or 12
    local rects = {}
    local k0, k1 = math.floor(minX / major), math.ceil(maxX / major)
    if k1 - k0 <= 100 then
        for k = k0, k1 do
            local sx = select(1, Geometry.Project(view, k * major, 0))
            local text = Geometry.FormatUnits(k * major)
            local x = math.floor(sx + 0.5) + 3
            -- Measured, not just positioned: a number that would run off the
            -- right edge is left out rather than drawn half.
            local width = tonumber(canvas.getTextWidth(text)) or (#text * 7)
            if x >= 0 and x + width <= view.Width - EDGE_MARGIN then
                canvas.textOut(x, 2, text)
                rects[#rects + 1] = { X1 = x - 2, Y1 = 0, X2 = x + width + 2, Y2 = textHeight + 4 }
            end
        end
    end
    k0, k1 = math.floor(minY / major), math.ceil(maxY / major)
    if k1 - k0 <= 100 then
        for k = k0, k1 do
            local _, sy = Geometry.Project(view, 0, k * major)
            if sy >= textHeight + 4 and sy <= view.Height then
                local text = Geometry.FormatUnits(k * major)
                local width = tonumber(canvas.getTextWidth(text)) or (#text * 7)
                local y = math.floor(sy + 0.5) - textHeight - 1
                canvas.textOut(3, y, text)
                rects[#rects + 1] = { X1 = 1, Y1 = y - 1, X2 = 5 + width, Y2 = y + textHeight + 1 }
            end
        end
    end
    return rects
end

--
--- ∑ The path behind the player, one line per pair of consecutive points,
---   broken where a point is flagged as the start of a new segment.
--
function TeleporterMap:_PaintTrail(canvas, view, colors)
    local trail = self.Trail
    if #trail < 2 then return end
    local pen = canvas.Pen
    pen.Color = colors.Trail
    pen.Width = 2
    local px, py
    for index, point in ipairs(trail) do
        local sx, sy = Geometry.Project(view, point.X, point.Y)
        if px and not point.Break then
            canvas.line(math.floor(px + 0.5), math.floor(py + 0.5), math.floor(sx + 0.5), math.floor(sy + 0.5))
        end
        px, py = sx, sy
    end
    pen.Width = 1
end

--
--- ∑ A screen index of everything a label must not cover: the discs, and
---   the labels already placed. Rectangles are bucketed on a coarse grid,
---   so a candidate box is tested against its neighbours and not against
---   every mark on the map.
--
local function occupancyKey(cx, cy)
    -- Screen cells only, so the offset is plenty, and one integer key avoids
    -- a table per column.
    return (cx + 4096) * 8192 + (cy + 4096)
end

local function newOccupancy()
    return { Cells = {} }
end

local function occupancyCells(rect)
    local x0, x1 = math.floor(rect.X1 / CELL), math.floor(rect.X2 / CELL)
    local y0, y1 = math.floor(rect.Y1 / CELL), math.floor(rect.Y2 / CELL)
    -- A rectangle wider than the map is a corrupt measurement, not a label.
    if x1 - x0 > 32 or y1 - y0 > 32 then return nil end
    return x0, x1, y0, y1
end

local function occupancyAdd(index, rect)
    local x0, x1, y0, y1 = occupancyCells(rect)
    if not x0 then return end
    for cx = x0, x1 do
        for cy = y0, y1 do
            local key = occupancyKey(cx, cy)
            local cell = index.Cells[key]
            if not cell then cell = {} index.Cells[key] = cell end
            if #cell < CELL_LIMIT then cell[#cell + 1] = rect else cell.Full = true end
        end
    end
end

local function occupancyHits(index, rect)
    local x0, x1, y0, y1 = occupancyCells(rect)
    if not x0 then return true end
    for cx = x0, x1 do
        for cy = y0, y1 do
            local cell = index.Cells[occupancyKey(cx, cy)]
            if cell then
                if cell.Full then return true end
                for _, other in ipairs(cell) do
                    if Geometry.Overlaps(rect, other) then return true end
                end
            end
        end
    end
    return false
end

--- How much a box would cover, rather than whether it covers anything. Only
--- the card asks: when every side of the pointer is busy it still has to go
--- somewhere, and the least busy side is where.
local function occupancyCount(index, rect)
    local x0, x1, y0, y1 = occupancyCells(rect)
    if not x0 then return CELL_LIMIT end
    local count = 0
    for cx = x0, x1 do
        for cy = y0, y1 do
            local cell = index.Cells[occupancyKey(cx, cy)]
            if cell then
                if cell.Full then count = count + CELL_LIMIT end
                for _, other in ipairs(cell) do
                    if Geometry.Overlaps(rect, other) then count = count + 1 end
                end
            end
        end
    end
    return count
end

--
--- ∑ The places a box may go around a mark, the most readable first:
---   beside it, then above and below, then the four corners. A label that
---   fits nowhere is dropped, never clipped and never painted over a mark.
--
local function boxCandidates(x, y, r, width, height)
    local half = math.floor(height / 2)
    local middle = math.floor(width / 2)
    return {
        { X = x + r + 5,             Y = y - half },
        { X = x - r - 5 - width,     Y = y - half },
        { X = x - middle,            Y = y - r - 4 - height },
        { X = x - middle,            Y = y + r + 4 },
        { X = x + r + 3,             Y = y - r - 3 - height },
        { X = x - r - 3 - width,     Y = y - r - 3 - height },
        { X = x + r + 3,             Y = y + r + 3 },
        { X = x - r - 3 - width,     Y = y + r + 3 },
    }
end

--
--- ∑ Places a width by height box around (x, y), avoiding everything in
---   the index and the edges of the map.
--- @param force boolean|nil # Take the first candidate that is on the map
---                            even when it collides. For the hover and the
---                            selection, which must always be named.
--- @return table|nil # { X1, Y1, X2, Y2 }
--
local function placeBox(index, view, x, y, r, width, height, force)
    local candidates = boxCandidates(x, y, r, width, height)
    local fallback
    for _, candidate in ipairs(candidates) do
        local box = { X1 = candidate.X, Y1 = candidate.Y,
                      X2 = candidate.X + width, Y2 = candidate.Y + height }
        if box.X1 >= EDGE_MARGIN and box.Y1 >= EDGE_MARGIN
           and box.X2 <= view.Width - EDGE_MARGIN and box.Y2 <= view.Height - EDGE_MARGIN then
            if not occupancyHits(index, box) then return box end
            fallback = fallback or box
        end
    end
    if force then
        if fallback then return fallback end
        -- Wider than the map, or against a corner: clamp it on, because a
        -- name the user just asked for is worth one overlap.
        local bx = clamp(x + r + 5, EDGE_MARGIN, math.max(EDGE_MARGIN, view.Width - EDGE_MARGIN - width))
        local by = clamp(y - math.floor(height / 2), EDGE_MARGIN, math.max(EDGE_MARGIN, view.Height - EDGE_MARGIN - height))
        return { X1 = bx, Y1 = by, X2 = bx + width, Y2 = by + height }
    end
    return nil
end

--- How many of a list of discs a box would cover.
local function coveredDiscs(discs, box)
    local count = 0
    for _, disc in ipairs(discs or {}) do
        if disc.X + disc.R >= box.X1 and disc.X - disc.R <= box.X2
           and disc.Y + disc.R >= box.Y1 and disc.Y - disc.R <= box.Y2 then
            count = count + 1
        end
    end
    return count
end

--
--- ∑ Where the hover card goes: beside the pointer, on the side with the
---   least under it. The card answers what the pointer is on, so it must not
---   cover that answer; when every side is busy the count of what a box
---   would cover breaks the tie, and the card never leaves the canvas.
---
---   "What the pointer is on" is not one disc but the heap the pointer is
---   in, so the members of that heap are passed in and weighed far heavier
---   than anything else the box might cover: a card that hides a dozen of
---   the saves it is describing has answered the question by deleting it.
---   The candidates include a plain left and right at the pointer's own
---   height, because a tall card in a crowd otherwise has only columns
---   through the heap to choose between.
--- @param discs table|nil # { X, Y, R } of the hovered marker's own pile.
--- @return table|nil, number, number # the box, how many of those discs it
---                                     covers, and how much it covers in all.
--
local function placeCard(index, view, x, y, width, height, discs)
    local half = math.floor(height / 2)
    local offsets = {
        { 18, 12 }, { -18 - width, 12 }, { 18, -12 - height }, { -18 - width, -12 - height },
        { 18, -half }, { -18 - width, -half },
        { -math.floor(width / 2), 22 }, { -math.floor(width / 2), -22 - height },
    }
    local best, bestScore, bestCovered, bestHits
    for _, offset in ipairs(offsets) do
        local bx = clamp(x + offset[1], EDGE_MARGIN, math.max(EDGE_MARGIN, view.Width - EDGE_MARGIN - width))
        local by = clamp(y + offset[2], EDGE_MARGIN, math.max(EDGE_MARGIN, view.Height - EDGE_MARGIN - height))
        local box = { X1 = bx, Y1 = by, X2 = bx + width, Y2 = by + height }
        local covered = coveredDiscs(discs, box)
        local hits = occupancyCount(index, box)
        local score = hits + covered * CARD_PILE_COST
        if score == 0 then return box, 0, 0 end
        if bestScore == nil or score < bestScore then
            best, bestScore, bestCovered, bestHits = box, score, covered, hits
        end
    end
    return best, bestCovered or 0, bestHits or 0
end

--
--- ∑ Where a line from (x, y) toward the centre of a box first meets that
---   box. A badge's leader has to point AT a pile without being drawn over
---   it, so it stops at the pile's bounding box instead of running to the
---   middle of the discs it is counting.
--- @return number, number
--
local function edgeToward(x, y, cx, cy, minX, minY, maxX, maxY)
    local dx, dy = cx - x, cy - y
    local function entry(value, low, high, delta)
        if delta == 0 then return 0 end
        if value < low then return (low - value) / delta end
        if value > high then return (high - value) / delta end
        return 0
    end
    local t = math.max(entry(x, minX, maxX, dx), entry(y, minY, maxY, dy))
    t = clamp(t, 0, 1)
    return x + dx * t, y + dy * t
end

--
--- ∑ Cuts a leader at the first disc it meets. A badge's line points into
---   the heap it counts, so it must reach the heap and stop: drawn across
---   the discs it is counting, the line is annotation over data, and one
---   that slides past a heap belonging to somebody else is worse than none.
---
---   It is tested against the drawn discs near it, taken from the same cell
---   grid the labels are placed on - not only against its own pile, because
---   the crossings a pile-only test leaves behind are exactly the ones over
---   a NEIGHBOUR's discs. A leader is short by construction (see LEADER_MAX
---   at the caller), so the cells its box covers are a handful.
--- @param cells table # occupancyKey -> array of { X, Y, R }.
--- @return number, number, number # the cut end, and its length squared.
--
local function clipToDiscs(cells, x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local lengthSq = dx * dx + dy * dy
    if lengthSq <= 0 then return x2, y2, 0 end
    local nearest = 1
    local cx0 = math.floor(math.min(x1, x2) / CELL) - 1
    local cx1 = math.floor(math.max(x1, x2) / CELL) + 1
    local cy0 = math.floor(math.min(y1, y2) / CELL) - 1
    local cy1 = math.floor(math.max(y1, y2) / CELL) + 1
    for cx = cx0, cx1 do
        for cy = cy0, cy1 do
            for _, disc in ipairs(cells[occupancyKey(cx, cy)] or {}) do
                local ox, oy = x1 - disc.X, y1 - disc.Y
                local reach = disc.R + MARKER_HALO
                local b = ox * dx + oy * dy
                local c = ox * ox + oy * oy - reach * reach
                local discriminant = b * b - lengthSq * c
                if discriminant >= 0 then
                    local root = math.sqrt(discriminant)
                    local t = (-b - root) / lengthSq
                    -- The line starts inside this disc: nothing left to draw.
                    if t < 0 and (-b + root) / lengthSq > 0 then t = 0 end
                    if t >= 0 and t < nearest then nearest = t end
                end
            end
        end
    end
    return x1 + dx * nearest, y1 + dy * nearest, lengthSq * nearest * nearest
end

--- Whether two boxes are within distance of each other.
local function boxesNear(a, b, distance)
    local dx = math.max(b.X1 - a.X2, a.X1 - b.X2, 0)
    local dy = math.max(b.Y1 - a.Y2, a.Y1 - b.Y2, 0)
    return dx * dx + dy * dy <= distance * distance
end

--
--- ∑ The piles on the map: single link clusters over the drawn discs, two
---   markers joined when their haloes touch. Bucketed on a screen grid one
---   disc pair wide, so the work is linear in the markers: a bucket with
---   CLUSTER_DENSE discs in it is a pile by construction and is joined
---   without measuring, and only the sparse buckets pay for distance tests,
---   of which there can never be more than a handful per marker.
--- @return table # cluster records { Count, Shown, Members, Min/Max X and Y }
--
local function clusterDiscs(draw, cell)
    local buckets, parent = {}, {}
    for index, item in ipairs(draw) do
        parent[index] = index
        local key = occupancyKey(math.floor(item.X / cell), math.floor(item.Y / cell))
        local bucket = buckets[key]
        if not bucket then bucket = {} buckets[key] = bucket end
        bucket[#bucket + 1] = index
    end
    local function find(index)
        while parent[index] ~= index do
            parent[index] = parent[parent[index]]
            index = parent[index]
        end
        return index
    end
    local function union(a, b)
        a, b = find(a), find(b)
        if a ~= b then parent[b] = a end
    end
    for _, bucket in pairs(buckets) do
        if #bucket >= CLUSTER_DENSE then
            for position = 2, #bucket do union(bucket[1], bucket[position]) end
        end
    end
    for index, item in ipairs(draw) do
        local cx, cy = math.floor(item.X / cell), math.floor(item.Y / cell)
        for ox = -1, 1 do
            for oy = -1, 1 do
                local bucket = buckets[occupancyKey(cx + ox, cy + oy)]
                if bucket then
                    -- A dense bucket is joined wholesale above, but it is not
                    -- skipped here: a disc on the rim of a heap, in a sparse
                    -- bucket of its own, physically touches the heap and
                    -- belongs to it. Skipping dense buckets left those discs
                    -- outside the pile they touch and the badge then counted
                    -- fewer saves than the eye sees. Only the first few
                    -- members of a bucket are measured, because they are all
                    -- in one pile already and one hit joins the whole of it.
                    local tested = math.min(#bucket, CLUSTER_DENSE)
                    for position = 1, tested do
                        local other = bucket[position]
                        if other ~= index then
                            local dx = draw[other].X - item.X
                            local dy = draw[other].Y - item.Y
                            local reach = item.R + draw[other].R + MARKER_HALO + 1
                            if dx * dx + dy * dy <= reach * reach then union(index, other) end
                        end
                    end
                end
            end
        end
    end
    local groups, clusters = {}, {}
    for index, item in ipairs(draw) do
        local root = find(index)
        local group = groups[root]
        if not group then
            group = { Count = 0, Shown = 0, Members = {}, Discs = {},
                      MinX = item.X, MinY = item.Y, MaxX = item.X, MaxY = item.Y }
            groups[root] = group
            clusters[#clusters + 1] = group
        end
        group.Count = group.Count + 1
        -- Where the pile's discs actually are, which is what a leader has to
        -- stop at and what the hover card has to stay off. Every drawn disc,
        -- the filtered out ones included: they are painted, so they can be
        -- crossed and they can be covered.
        group.Discs[#group.Discs + 1] = { X = item.X, Y = item.Y, R = item.R }
        -- Only the saves a click could land on are counted and zoomed to: a
        -- filtered out save is not part of the crowd the user is fighting.
        if not item.Marker.Dimmed then
            group.Shown = group.Shown + 1
            group.Members[#group.Members + 1] = item.Marker
        end
        if item.X - item.R < group.MinX then group.MinX = item.X - item.R end
        if item.X + item.R > group.MaxX then group.MaxX = item.X + item.R end
        if item.Y - item.R < group.MinY then group.MinY = item.Y - item.R end
        if item.Y + item.R > group.MaxY then group.MaxY = item.Y + item.R end
        item.Cluster = group
    end
    return clusters
end

--
--- ∑ A disc per marker on a ring of the surface colour, the piles counted,
---   and a label placed where it fits. A marker whose disc does not touch
---   the map is neither painted nor hittable: its SX and SY are cleared, so
---   a click at the edge cannot select a save the user never saw.
---
---   Four passes, in this order, because each depends on the one before it:
---   the discs, which is what makes the piles; the names the user asked for;
---   the areas and the counts; then the rest of the names, which avoid all
---   of it.
--
function TeleporterMap:_PaintMarkers(canvas, view, colors)
    local radius = tonumber(self.View.MarkerRadius) or 5
    local pen, brush = canvas.Pen, canvas.Brush
    pen.Width = 1
    local textHeight = tonumber(canvas.getTextHeight("0")) or 12
    local showLabels = self.View.ShowLabels
    local discScale = self.DiscScale or 1
    local ramp = colors.Ramp
    local steps = (type(ramp) == "table") and #ramp or 0
    -- The ramp is the height encoding, so it is gated on there being a
    -- height to encode - exactly the condition the legend is drawn under -
    -- and not on the theme happening to have a ramp. With ScaleByHeight off,
    -- or on a table with no height axis at all (a 2D game, or every save at
    -- one height), self.HeightRange is nil, no marker carries a HeightT, and
    -- every disc must be the plain accent. Gating on the theme instead
    -- painted the whole map in the ramp's middle step: a shade nobody chose,
    -- with no legend on the canvas to explain it.
    local useRamp = steps > 0 and self.HeightRange ~= nil and self.View.ScaleByHeight == true
    -- Who is on the map, and how large. A marker off the map keeps no screen
    -- position, so it cannot be clicked from the edge.
    local draw = {}
    for order, marker in ipairs(self.Markers) do
        local sx, sy = Geometry.Project(view, marker.X, marker.Y)
        local r = math.max(MARKER_MIN, math.floor((marker.Radius or radius) * discScale + 0.5))
        local visible = sx + r >= 0 and sx - r <= view.Width and sy + r >= 0 and sy - r <= view.Height
        if not visible then
            marker.SX, marker.SY = nil, nil
        else
            marker.SX, marker.SY = sx, sy
            draw[#draw + 1] = { Marker = marker, Order = order, R = r,
                                X = math.floor(sx + 0.5), Y = math.floor(sy + 0.5) }
        end
    end
    self.Clusters, self.PileCount, self.Card = nil, 0, nil
    if #draw == 0 then
        self.LabelsPlaced, self.LabelsWanted = 0, 0
        self:_UpdateStats()
        return
    end
    local widest, hoverItem = 0, nil
    for _, item in ipairs(draw) do
        item.Selected = item.Marker == self.Selected
        item.Hovered = item.Marker == self.Hover
        if item.Hovered then hoverItem = item end
        if item.R > widest then widest = item.R end
    end
    -- Back to front: the filtered out first, then large to small, then the
    -- selection and the hover. A small disc is a high save, and keeping it on
    -- top of the low ones is what makes a pile countable at all.
    table.sort(draw, function(a, b)
        local ra = a.Marker.Dimmed and 0 or (a.Hovered and 3 or (a.Selected and 2 or 1))
        local rb = b.Marker.Dimmed and 0 or (b.Hovered and 3 or (b.Selected and 2 or 1))
        if ra ~= rb then return ra < rb end
        if a.R ~= b.R then return a.R > b.R end
        return a.Order < b.Order
    end)
    for _, item in ipairs(draw) do
        local marker, x, y, r = item.Marker, item.X, item.Y, item.R
        -- Emphasis is a ring around the mark, never a recolour of it and
        -- never a growth: the disc has to keep saying how high its save is
        -- while the pointer is on it. Drawn first, so the halo and the disc
        -- cut the middle back out of it.
        if item.Selected or item.Hovered then
            local ring = r + MARKER_HALO + (item.Selected and 3 or 2)
            local edge = item.Selected and colors.Selection or colors.MarkerHover
            brush.Color, pen.Color = edge, edge
            canvas.ellipse(x - ring, y - ring, x + ring + 1, y + ring + 1)
        end
        -- The halo: a ring of the surface colour around every disc, painted
        -- per marker in draw order, so a marker in front carves its own gap
        -- out of the ones behind it and a pile stays countable.
        brush.Color, pen.Color = colors.Halo, colors.Halo
        canvas.ellipse(x - r - MARKER_HALO, y - r - MARKER_HALO,
                       x + r + MARKER_HALO + 1, y + r + MARKER_HALO + 1)
        if marker.Dimmed then
            -- Hollow, not dark. Faint means high on this map now, so a save
            -- the filter or the height band has put aside has to differ in
            -- something the ramp does not use.
            brush.Color, pen.Color = colors.Halo, colors.MarkerDim
        else
            -- Where height is being encoded the ramp answers for every save:
            -- the band its height falls in, and the middle step for a save
            -- whose height is not a number - the same middle its size was
            -- drawn at, so the two channels cannot contradict each other.
            -- colors.Marker is the accent, which is the ramp's low end, and
            -- it is right whenever there is no height being shown.
            local fill = colors.Marker
            if useRamp then
                fill = marker.HeightT
                    and ramp[Geometry.HeightBandIndex(marker.HeightT, 0, 1, steps)]
                    or ramp[math.ceil(steps / 2)]
            end
            brush.Color, pen.Color = fill, fill
        end
        canvas.ellipse(x - r, y - r, x + r + 1, y + r + 1)
    end
    -- What a label may not cover: every disc, and the readouts the frame
    -- painted and measured before it called this.
    local index = newOccupancy()
    -- The same discs again, as discs rather than as rectangles, on the same
    -- cell grid: a leader has to know what it would cross, and a rectangle
    -- cannot answer that. One cell holds CELL_LIMIT of them, which is the
    -- same bound the label placer works under.
    local discCells = {}
    for _, item in ipairs(draw) do
        occupancyAdd(index, { X1 = item.X - item.R - MARKER_HALO, Y1 = item.Y - item.R - MARKER_HALO,
                              X2 = item.X + item.R + MARKER_HALO, Y2 = item.Y + item.R + MARKER_HALO })
        local key = occupancyKey(math.floor(item.X / CELL), math.floor(item.Y / CELL))
        local cell = discCells[key]
        if not cell then cell = {} discCells[key] = cell end
        if #cell < CELL_LIMIT then cell[#cell + 1] = item end
    end
    for _, rect in ipairs(self.HudRects or {}) do occupancyAdd(index, rect) end

    -- The piles, found once and kept: the counts are drawn from them, and Z
    -- zooms into the one under the pointer.
    local clusters = clusterDiscs(draw, widest * 2 + MARKER_HALO * 2 + 2)
    self.Clusters = clusters

    -- The names, chosen before any of them is drawn. The hover and the
    -- selection first, then the marks that stand alone, then the smaller
    -- piles: a pile cannot have every name, and spending the room on its
    -- neighbours reads better than three names out of fifteen inside it.
    local labels = {}
    for _, item in ipairs(draw) do
        local emphasis = (item.Hovered and 2 or 0) + (item.Selected and 1 or 0)
        -- A filtered out save is hollow, not nameless. It competes for a name
        -- last, after every live save has had its turn, so it can only take
        -- room nothing else wanted - but a disc the user can see and cannot
        -- identify is a worse answer than a quiet name.
        local dimmed = showLabels and item.Marker.Dimmed and emphasis == 0
        -- The save under the pointer gets no label of its own. The card is
        -- already showing its name, and printing it a second time beside the
        -- disc says nothing while taking room the card and the neighbouring
        -- names have to work around.
        if not item.Hovered
           and (emphasis > 0 or dimmed or (showLabels and not item.Marker.Dimmed)) then
            item.Priority = dimmed and -1 or emphasis
            item.Crowd = item.Cluster and item.Cluster.Shown or 1
            labels[#labels + 1] = item
        end
    end
    table.sort(labels, function(a, b)
        if a.Priority ~= b.Priority then return a.Priority > b.Priority end
        if a.Crowd ~= b.Crowd then return a.Crowd < b.Crowd end
        if a.Y ~= b.Y then return a.Y < b.Y end
        if a.X ~= b.X then return a.X < b.X end
        return a.Order < b.Order
    end)

    local limit = self.View.LabelLimit or 150
    local placed, wanted = 0, 0
    local function drawLabel(item)
        wanted = wanted + 1
        if placed >= limit then return end
        local marker = item.Marker
        local text = marker.Name
        local emphasised = item.Priority > 0
        -- Measured in the style it is drawn in, because bold is wider. Kept
        -- on the marker, because measuring means a call into the LCL for
        -- every named save on every frame, and on a crowded map that was most
        -- of the frame spent re-measuring names that had not changed. The
        -- font height is part of the key, so a theme with a different font
        -- is measured again.
        canvas.Font.Style = emphasised and "[fsBold]" or self.EmptyStyle
        local width = marker.TextWidth
        if width == nil or marker.TextWidthFor ~= text
           or marker.TextWidthBold ~= emphasised or marker.TextWidthAt ~= textHeight then
            width = (tonumber(canvas.getTextWidth(text)) or (#text * 7)) + 4
            marker.TextWidth, marker.TextWidthFor = width, text
            marker.TextWidthBold, marker.TextWidthAt = emphasised, textHeight
        end
        local height = textHeight + 2
        -- A selected save carries its coordinates. Picking one from the list
        -- and then hunting for it on the map was the case with no answer.
        -- The save under the pointer never reaches here, because the card is
        -- already showing its numbers.
        local second
        if item.Selected then
            local _, _, hName, vName = self:GetPlane()
            second = string.format("%s %s  %s %s", hName or "X", Geometry.FormatRounded(marker.X),
                                                   vName or "Y", Geometry.FormatRounded(marker.Y))
            canvas.Font.Style = self.EmptyStyle
            local secondWidth = (tonumber(canvas.getTextWidth(second)) or (#second * 7)) + 4
            if secondWidth > width then width = secondWidth end
            height = height + textHeight
            canvas.Font.Style = emphasised and "[fsBold]" or self.EmptyStyle
        end
        -- Clear of the disc, its halo, and the ring an emphasised mark wears.
        local clearance = item.R + MARKER_HALO + (emphasised and 4 or 0)
        local box = placeBox(index, view, item.X, item.Y, clearance, width, height, emphasised)
        if box then
            occupancyAdd(index, box)
            placed = placed + 1
            brush.Color = colors.LabelBox
            canvas.Font.Color = marker.Dimmed and colors.LabelDim or colors.Label
            canvas.textOut(box.X1 + 2, box.Y1 + 1, text)
            if second then
                canvas.Font.Style = self.EmptyStyle
                canvas.Font.Color = colors.CardMuted
                canvas.textOut(box.X1 + 2, box.Y1 + 1 + textHeight, second)
            end
        end
        canvas.Font.Style = self.EmptyStyle
    end

    -- The hover and the selection answer a question the user just asked, so
    -- they are placed before anything else competes for the room. One bold
    -- row and no more: the numbers are in the card and in the details panel,
    -- which is where a number can be read instead of hunted for.
    for _, item in ipairs(labels) do
        if item.Priority > 0 then drawLabel(item) end
    end

    -- The card is measured and placed HERE, with the labels, and drawn at the
    -- end of the frame. It is the largest box the map paints, and placing it
    -- after the labels meant it scored against an index the labels had
    -- already filled and then painted over them anyway: a name cut mid-word
    -- by the card is a save the canvas renames. Reserved with everything
    -- else, the ordinary names go round it and it still lands on the least
    -- busy side of the pointer.
    local card = self:_HoverCard(canvas, colors)
    if card then
        -- The heap the pointer is in is passed to the placer, which weighs
        -- covering one of its discs above everything else a box could cover.
        -- What the card is answering about, and therefore what it must not
        -- land on: the pointer's own pile, plus every disc within CARD_GUARD
        -- of the pointer. The cluster alone is not enough - a heap's nearest
        -- neighbours are usually a cluster of their own, and a card that
        -- names five saves while covering three more of the same crowd has
        -- still answered the question by hiding it.
        local pile = {}
        if hoverItem then
            for _, disc in ipairs(hoverItem.Cluster and hoverItem.Cluster.Discs or {}) do
                pile[#pile + 1] = disc
            end
            local cx0 = math.floor((hoverItem.X - CARD_GUARD) / CELL)
            local cx1 = math.floor((hoverItem.X + CARD_GUARD) / CELL)
            local cy0 = math.floor((hoverItem.Y - CARD_GUARD) / CELL)
            local cy1 = math.floor((hoverItem.Y + CARD_GUARD) / CELL)
            for cx = cx0, cx1 do
                for cy = cy0, cy1 do
                    for _, item in ipairs(discCells[occupancyKey(cx, cy)] or {}) do
                        local dx, dy = item.X - hoverItem.X, item.Y - hoverItem.Y
                        if dx * dx + dy * dy <= CARD_GUARD * CARD_GUARD then
                            pile[#pile + 1] = item
                        end
                    end
                end
            end
        end
        local box, covered, hits = placeCard(index, view, card.X, card.Y, card.Width, card.Height, pile)
        -- Deep inside a crowd every side of the pointer is heap, and the
        -- least bad box still hides part of the answer. Then the card gives
        -- way instead of the data: the stack list drops to two names and the
        -- overflow line, which says the same thing in a box shallow enough to
        -- fit beside the pile rather than over it. The trigger is either a
        -- disc of the pointer's own heap - the answer hiding the answer - or
        -- simply covering too much of the map to be worth its ten lines.
        if box and (card.Stack or 0) > 2 and (covered > 0 or hits >= CARD_BUSY) then
            local short = self:_HoverCard(canvas, colors, 2)
            if short then
                local shortBox, shortCovered, shortHits = placeCard(index, view, short.X, short.Y,
                                                                    short.Width, short.Height, pile)
                if shortBox and (shortCovered < covered or shortHits < hits) then
                    card, box = short, shortBox
                end
            end
        end
        card.Box = box
        if box then occupancyAdd(index, box) end
    end
    self.Card = card

    if self.Area.Selected == nil then
        self:_PaintAreaCaptions(canvas, view, colors, index, draw, textHeight)
    end

    -- The piles, counted. A count is not a label: every disc under it is
    -- still drawn and still one click away, and the count is placed beside
    -- the pile, never over it.
    local badges = {}
    canvas.Font.Style = self.EmptyStyle
    for _, group in ipairs(clusters) do
        if group.Shown >= CLUSTER_MIN then
            local text = tostring(group.Shown)
            local width = (tonumber(canvas.getTextWidth(text)) or 8) + 9
            local height = textHeight + 3
            local cx = math.floor((group.MinX + group.MaxX) / 2)
            local cy = math.floor((group.MinY + group.MaxY) / 2)
            local reach = math.floor(math.max(group.MaxX - group.MinX, group.MaxY - group.MinY) / 2) + 2
            -- Against the pile first, then further out, and forced on the
            -- last try. How many saves are in a heap exists nowhere else on
            -- the canvas, and a count that was not drawn while the map card
            -- claims it is the one number a reader can check against the
            -- picture and find wrong.
            local box = placeBox(index, view, cx, cy, reach, width, height, false)
                     or placeBox(index, view, cx, cy, reach + 10, width, height, false)
                     or placeBox(index, view, cx, cy, reach + 24, width, height, false)
                     or placeBox(index, view, cx, cy, reach + 44, width, height, false)
                     or placeBox(index, view, cx, cy, reach + 16, width, height, true)
            if box then
                local badge = { Box = box, Text = text, Height = height }
                -- A leader to the heap it counts. A badge floating in clear
                -- space between two heaps is a number about neither of them.
                -- The line runs to the edge of the pile's box and is then cut
                -- at the first disc of that pile it meets, so it points INTO
                -- the heap without being drawn over the very discs it counts.
                -- Under about four pixels there is nothing left to say: the
                -- badge is already against its pile.
                local ax = clamp(cx, box.X1 - 1, box.X2 + 1)
                local ay = clamp(cy, box.Y1 - 1, box.Y2 + 1)
                local ex, ey = edgeToward(ax, ay, cx, cy, group.MinX, group.MinY, group.MaxX, group.MaxY)
                local reachSq = (ex - ax) * (ex - ax) + (ey - ay) * (ey - ay)
                local lengthSq = 0
                if reachSq <= LEADER_MAX * LEADER_MAX then
                    ex, ey, lengthSq = clipToDiscs(discCells, ax, ay, ex, ey)
                end
                if lengthSq >= 16 then
                    badge.AX, badge.AY = math.floor(ax + 0.5), math.floor(ay + 0.5)
                    badge.EX, badge.EY = math.floor(ex + 0.5), math.floor(ey + 0.5)
                    badge.Length = lengthSq
                end
                badges[#badges + 1] = badge
                occupancyAdd(index, box)
            end
        end
    end
    -- Two counts within a badge-height of each other read as one annotation
    -- carrying two numbers, and two leaders out of it then say which is
    -- which twice over. The shorter one goes: its badge is the one already
    -- touching its own heap. Only the last few badges are compared, which is
    -- every badge that could be that close to this one.
    for position = 2, #badges do
        local badge = badges[position]
        for other = math.max(1, position - 8), position - 1 do
            local previous = badges[other]
            if badge.Length and previous.Length
               and boxesNear(badge.Box, previous.Box, badge.Height) then
                if badge.Length <= previous.Length then badge.Length = nil else previous.Length = nil end
            end
        end
    end
    -- Every leader, then every badge. Drawing the boxes last is what keeps a
    -- line from ever crossing a count: the badge's own opaque fill takes back
    -- whatever passed under it, and the two numbers stay two statements.
    pen.Width = 1
    pen.Color = colors.BadgeEdge
    for _, badge in ipairs(badges) do
        if badge.Length then canvas.line(badge.AX, badge.AY, badge.EX, badge.EY) end
    end
    for _, badge in ipairs(badges) do
        brush.Color = colors.Background
        pen.Color = colors.BadgeEdge
        canvas.roundRect(badge.Box.X1, badge.Box.Y1, badge.Box.X2, badge.Box.Y2,
                         badge.Height, badge.Height)
        canvas.Font.Color = colors.Badge
        canvas.textOut(badge.Box.X1 + 5, badge.Box.Y1 + 1, badge.Text)
    end
    self.PileCount = #badges

    for _, item in ipairs(labels) do
        if item.Priority == 0 then drawLabel(item) end
    end
    for _, item in ipairs(labels) do
        if item.Priority < 0 then drawLabel(item) end
    end
    self.LabelsPlaced, self.LabelsWanted = placed, wanted
    self:_UpdateStats()
end

--
--- ∑ With every area drawn at once, each area names itself once where its
---   saves are. Which heap belongs to which map is otherwise a question only
---   the card can answer, one save at a time, and it is the first question
---   the eye asks of a map at that zoom.
---
---   The name goes at the median of the area's own marks, which lands inside
---   them even when they are spread, and it is placed by the same avoider as
---   everything else, so it never covers a disc or a name. It wears the HUD
---   colour, not the label colour: an area is not a save.
--
function TeleporterMap:_PaintAreaCaptions(canvas, view, colors, index, draw, textHeight)
    local groups, order = {}, {}
    for _, item in ipairs(draw) do
        local area = item.Marker.Area
        if area and not item.Marker.Dimmed then
            local group = groups[area]
            if not group then
                group = { X = {}, Y = {} }
                groups[area] = group
                order[#order + 1] = area
            end
            group.X[#group.X + 1] = item.X
            group.Y[#group.Y + 1] = item.Y
        end
    end
    table.sort(order)
    canvas.Font.Style = self.EmptyStyle
    for _, area in ipairs(order) do
        local group = groups[area]
        if #group.X >= AREA_CAPTION_MIN then
            table.sort(group.X)
            table.sort(group.Y)
            local middle = math.floor(#group.X / 2) + 1
            local text = string.upper(area)
            local width = (tonumber(canvas.getTextWidth(text)) or (#text * 7)) + 6
            local box = placeBox(index, view, group.X[middle], group.Y[middle], 12, width, textHeight + 2, false)
            if box then
                occupancyAdd(index, box)
                canvas.Brush.Color = colors.LabelBox
                canvas.Font.Color = colors.Hud
                canvas.textOut(box.X1 + 3, box.Y1 + 1, text)
            end
        end
    end
end

--
--- ∑ The player as a crosshair with its own word beside it, faint when the
---   last read is stale, and pulled to the edge of the map with a smaller
---   dot when off screen, so the direction to walk is still visible.
---
---   The shape carries it, not the colour. COLOR_SUCCESS is a green, and on
---   a theme whose accent is also green a green disc among green discs is
---   just another save; a crosshair with "You" next to it is not, in any
---   palette anyone can write.
--- @param reserve boolean|nil # Measure only: return the room it takes and
---                              draw nothing, for the label placer.
--- @return table|nil # { X1, Y1, X2, Y2 }
--
function TeleporterMap:_PaintPlayer(canvas, view, colors, reserve)
    local point = self:_PlayerPoint()
    if not point then return nil end
    local sx, sy = Geometry.Project(view, point.X, point.Y)
    local x, y, outside = Geometry.ClampToRect(sx, sy, view.Width, view.Height, CHROME_INSET)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    local pen, brush = canvas.Pen, canvas.Brush
    local fill = self.PlayerStale and colors.PlayerStale or colors.Player
    if outside then
        local rect = { X1 = x - 8, Y1 = y - 8, X2 = x + 8, Y2 = y + 8 }
        if reserve then return rect end
        pen.Width = 1
        brush.Color, pen.Color = colors.PlayerEdge, colors.PlayerEdge
        canvas.ellipse(x - 6, y - 6, x + 7, y + 7)
        brush.Color, pen.Color = fill, fill
        canvas.ellipse(x - 4, y - 4, x + 5, y + 5)
        return rect
    end
    -- Measured before anything is drawn, because the reservation and the
    -- drawing have to agree about which side the word is on.
    local textHeight = tonumber(canvas.getTextHeight("0")) or 12
    local word = "You"
    canvas.Font.Style = "[fsBold]"
    local wordWidth = tonumber(canvas.getTextWidth(word)) or 21
    canvas.Font.Style = self.EmptyStyle
    local wordX = x + 19
    if wordX + wordWidth + EDGE_MARGIN > view.Width then wordX = x - 19 - wordWidth end
    local rect = { X1 = math.min(x - 16, wordX - 2), Y1 = y - 16,
                   X2 = math.max(x + 16, wordX + wordWidth + 2), Y2 = y + 16 }
    if reserve then return rect end
    pen.Width = 1
    brush.Color, pen.Color = fill, fill
    canvas.ellipse(x - 8, y - 8, x + 9, y + 9)
    brush.Color, pen.Color = colors.Background, colors.Background
    canvas.ellipse(x - 6, y - 6, x + 7, y + 7)
    brush.Color, pen.Color = fill, fill
    canvas.ellipse(x - 2, y - 2, x + 3, y + 3)
    -- The ticks are cut out of the background first, so the crosshair reads
    -- over whatever it crosses.
    for _, tick in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
        local dx, dy = tick[1], tick[2]
        local x1, y1 = x + dx * 10, y + dy * 10
        local x2, y2 = x + dx * 15, y + dy * 15
        pen.Color, pen.Width = colors.Background, 3
        canvas.line(x1, y1, x2, y2)
        pen.Color, pen.Width = fill, 1
        canvas.line(x1, y1, x2, y2)
    end
    canvas.Font.Style = "[fsBold]"
    brush.Color = colors.Background
    canvas.Font.Color = fill
    canvas.textOut(wordX, y - math.floor(textHeight / 2), word)
    canvas.Font.Style = self.EmptyStyle
    return rect
end

--
--- ∑ A bar in the bottom left showing what one grid step is worth.
---
---   It shares that corner with the vertical ruler, which prints a value
---   wherever a grid line crosses the bottom of the map, and pinned at a
---   fixed x the caption ran into it: "0" and "200 u" side by side read as
---   one number. So the bar is measured like everything else the map draws
---   and steps out of the rectangles the rulers already took - right of them
---   while that fits on the row, up a row when it does not.
--- @param reserve boolean|nil # Measure only: return the room it takes and
---                              draw nothing, for the label placer.
--- @param reserved table|nil # Rectangles already taken in this frame.
--- @return table|nil # { X1, Y1, X2, Y2 }
--
function TeleporterMap:_PaintScaleBar(canvas, view, colors, reserve, reserved)
    local step = Geometry.NiceStep(view.Scale, 100)
    local pixels = math.floor(step * view.Scale + 0.5)
    if pixels < 10 or pixels > view.Width / 2 then return nil end
    local textHeight = tonumber(canvas.getTextHeight("0")) or 12
    local text = Geometry.FormatUnits(step) .. " u"
    local x, y = 12, view.Height - 14
    local function rectAt(px, py)
        return { X1 = px - 4, Y1 = py - textHeight - 5, X2 = px + pixels + 6, Y2 = py + 4 }
    end
    local rect = rectAt(x, y)
    for _ = 1, 3 do
        local blocker
        for _, other in ipairs(reserved or {}) do
            if Geometry.Overlaps(rect, other) then
                blocker = math.max(blocker or other.X2, other.X2)
            end
        end
        if not blocker then break end
        local shifted = blocker + 8
        if shifted + pixels + 6 <= view.Width - EDGE_MARGIN then
            x = shifted
        elseif y - textHeight - 5 - (textHeight + 8) >= EDGE_MARGIN then
            x, y = 12, y - textHeight - 8
        else
            break
        end
        rect = rectAt(x, y)
    end
    if reserve then return rect end
    local pen = canvas.Pen
    pen.Color = colors.ScaleBar
    pen.Width = 1
    canvas.line(x, y, x + pixels, y)
    canvas.line(x, y - 4, x, y + 1)
    canvas.line(x + pixels, y - 4, x + pixels, y + 1)
    canvas.Brush.Color = colors.Background
    -- The rules are scenery and stay muted; the caption is one of the two
    -- numbers this map asks a reader to trust, so it wears a text colour.
    canvas.Font.Color = colors.Hud
    canvas.textOut(x + 4, y - textHeight - 3, text)
    return rect
end

--
--- ∑ How many markers would be drawn inside a screen rectangle. The
---   readouts are painted under the marks, so a disc can never be hidden by
---   one; this is how a readout gets out of the marks' way instead, which is
---   the other half of that trade.
--- @return number
--
function TeleporterMap:_MarkersIn(view, rect)
    local count = 0
    for _, marker in ipairs(self.Markers) do
        if isFinite(marker.X) and isFinite(marker.Y) then
            local sx, sy = Geometry.Project(view, marker.X, marker.Y)
            if sx >= rect.X1 and sx <= rect.X2 and sy >= rect.Y1 and sy <= rect.Y2 then
                count = count + 1
            end
        end
    end
    return count
end

--
--- ∑ Bottom right: the marker scale itself, both channels of it. Five
---   discs from large and bright at the low end to small and faint at the
---   high end, between the two heights they stand for, rounded to numbers
---   a person reads rather than the raw ends of the range.
--
--- @param reserve boolean|nil # Measure only: return the room it takes and
---                              draw nothing, for the label placer.
--- @return table|nil # { X1, Y1, X2, Y2 }
function TeleporterMap:_PaintHeightLegend(canvas, view, colors, reserve)
    local range = self.HeightRange
    if not range or not self.View.ScaleByHeight then return nil end
    local up = self:HeightAxis()
    if not up then return nil end
    local axes = teleporter:GetAxes()
    local base = tonumber(self.View.MarkerRadius) or 5
    local maxScale = self:_HeightScaleMax()
    local pen, brush = canvas.Pen, canvas.Brush
    canvas.Font.Style = self.EmptyStyle
    local span = range.High - range.Low
    local lowText = string.format("%s %s", axes[up] or "H",
                                  Geometry.FormatUnits(Geometry.RoundUnits(range.Low, span, false)))
    local highText = Geometry.FormatUnits(Geometry.RoundUnits(range.High, span, true))
    local textHeight = tonumber(canvas.getTextHeight("0")) or 12
    local lowWidth = tonumber(canvas.getTextWidth(lowText)) or (#lowText * 7)
    local highWidth = tonumber(canvas.getTextWidth(highText)) or (#highText * 7)
    -- Band 1 is the highest saves, the last the lowest, and the disc for a
    -- band is the size a save in the middle of it is really drawn at, the
    -- crowding at this zoom included: the legend shows the discs on the map
    -- and not an idealised pair of them.
    local ramp = colors.Ramp
    local bands = (type(ramp) == "table") and #ramp or HEIGHT_BANDS
    local discScale = self.DiscScale or 1
    local sizes, big = {}, 0
    for band = 1, bands do
        local middle = (band - 0.5) / bands
        local size = math.max(MARKER_MIN, math.floor(base * (1 + (maxScale - 1) * middle) * discScale + 0.5))
        sizes[band] = size
        if size > big then big = size end
    end
    -- Lifted with the big disc, so a large scale is not cut off by the edge.
    local y = view.Height - math.max(14, big + 6)
    -- Laid out right to left, so it reads low to high left to right: the
    -- high value, the ramp as discs, the low value with the axis name.
    local x = view.Width - CHROME_INSET - highWidth
    local highX = x
    local centres = {}
    for band = 1, bands do
        x = x - 5 - sizes[band]
        centres[band] = x
        x = x - sizes[band]
    end
    x = x - 6 - lowWidth
    -- The legend is drawn under the markers, so a save can be drawn on top of
    -- it - and a marker beside the smallest legend disc reads as a fifth step
    -- of a four step ramp, which is the legend teaching the wrong scale. Data
    -- still wins, so the legend moves instead: straight up, one row at a
    -- time, to the first row in this corner that no marker is drawn in.
    local lift = 2 * big + 10
    local function rowRect(top)
        return { X1 = x - 4, Y1 = top - big - 4, X2 = view.Width - 8, Y2 = top + big + 4 }
    end
    local bestY, bestCount = y, nil
    for attempt = 0, 3 do
        local top = y - attempt * lift
        local rect = rowRect(top)
        if rect.Y1 < EDGE_MARGIN then break end
        local count = self:_MarkersIn(view, rect)
        if count == 0 then bestY, bestCount = top, 0 break end
        if bestCount == nil or count < bestCount then bestY, bestCount = top, count end
    end
    y = bestY
    if reserve then return rowRect(y) end
    pen.Width = 1
    canvas.Font.Color = colors.Hud
    brush.Color = colors.Background
    canvas.textOut(highX, y - math.floor(textHeight / 2), highText)
    for band = 1, bands do
        local size = sizes[band]
        local fill = (ramp and ramp[band]) or colors.Marker
        brush.Color = fill
        pen.Color = fill
        canvas.ellipse(centres[band] - size, y - size, centres[band] + size + 1, y + size + 1)
    end
    brush.Color = colors.Background
    canvas.textOut(x, y - math.floor(textHeight / 2), lowText)
    return rowRect(y)
end

--
--- ∑ The card under the pointer: which save it is on, where that save is,
---   which area it belongs to, what a click will do, and every other save
---   stacked under the same pointer. In a pile this is the only place those
---   names exist, and it is what turns a click on a crowd into a decision
---   instead of a guess.
--
--- @param maxStack number|nil # How many of the stacked names to list before
---                              the overflow line. Four unless the placer
---                              comes back and asks for a shallower card.
function TeleporterMap:_HoverCard(canvas, colors, maxStack)
    local hover = self.Hover
    if not hover or not hover.SX then return nil end
    local reach = (tonumber(self.View.HitRadius) or 13) + (hover.HitExtra or 0) + 6
    local stack = {}
    for _, marker in ipairs(self.Markers) do
        if marker ~= hover and marker.SX and not marker.Dimmed then
            local dx, dy = marker.SX - hover.SX, marker.SY - hover.SY
            local distance = dx * dx + dy * dy
            if distance <= reach * reach then
                stack[#stack + 1] = { Marker = marker, Distance = distance }
            end
        end
    end
    table.sort(stack, function(a, b)
        if a.Distance ~= b.Distance then return a.Distance < b.Distance end
        return a.Marker.Key < b.Marker.Key
    end)

    local lines = { { Text = hover.Name, Bold = true, Color = colors.CardText } }
    local _, _, hName, vName = self:GetPlane()
    local detail = string.format("%s %s  %s %s", hName or "X", Geometry.FormatRounded(hover.X),
                                 vName or "Y", Geometry.FormatRounded(hover.Y))
    local heightAxis = self:HeightAxis()
    if heightAxis and isFinite(hover.Height) then
        local axes = teleporter:GetAxes()
        detail = detail .. string.format("  %s %s", axes[heightAxis] or "H", Geometry.FormatRounded(hover.Height))
    end
    lines[#lines + 1] = { Text = detail, Color = colors.CardMuted }
    -- Which map a save belongs to only matters while several are drawn.
    if hover.Area and self.Area.Selected == nil then
        lines[#lines + 1] = { Text = hover.Area, Color = colors.CardMuted }
    end
    lines[#lines + 1] = { Text = self.View.OneClickTeleport and "Click to teleport here"
                                                             or "Double-click to teleport here",
                          Color = colors.CardMuted }
    if #stack > 0 then
        lines[#lines + 1] = { Text = string.format("%d more under the pointer:", #stack),
                              Color = colors.CardMuted, Rule = true }
        local shown = math.min(#stack, math.max(1, math.floor(tonumber(maxStack) or 4)))
        for position = 1, shown do
            lines[#lines + 1] = { Text = "  " .. stack[position].Marker.Name, Color = colors.CardText }
        end
        if #stack > shown then
            lines[#lines + 1] = { Text = string.format("  and %d more - press Z to zoom in", #stack - shown),
                                  Color = colors.CardMuted }
        end
    end

    local textHeight = tonumber(canvas.getTextHeight("0")) or 12
    local width = 0
    for _, line in ipairs(lines) do
        canvas.Font.Style = line.Bold and "[fsBold]" or self.EmptyStyle
        local measured = tonumber(canvas.getTextWidth(line.Text)) or (#line.Text * 7)
        if measured > width then width = measured end
    end
    canvas.Font.Style = self.EmptyStyle
    local padding, lineHeight = 6, textHeight + 1
    return {
        Lines = lines, Padding = padding, LineHeight = lineHeight, Stack = #stack,
        Width = width + padding * 2, Height = #lines * lineHeight + padding * 2,
        X = math.floor(hover.SX + 0.5), Y = math.floor(hover.SY + 0.5),
    }
end

--
--- ∑ Draws the card the label pass already placed and reserved. Drawing is
---   the last thing the frame does - the card belongs on top of what it
---   describes - but WHERE it goes was decided while the names were being
---   placed, so no name was written where the card would land.
--
function TeleporterMap:_PaintHoverCard(canvas, view, colors)
    local card = self.Card
    if not card or not card.Box then return end
    local pen, brush = canvas.Pen, canvas.Brush
    local x, y = card.Box.X1, card.Box.Y1
    local boxWidth, boxHeight = card.Width, card.Height
    brush.Color = colors.CardFill
    canvas.fillRect(x, y, x + boxWidth, y + boxHeight)
    pen.Color, pen.Width = colors.CardEdge, 1
    canvas.rect(x, y, x + boxWidth, y + boxHeight)
    local ty = y + card.Padding
    for _, line in ipairs(card.Lines) do
        if line.Rule then
            pen.Color = colors.CardEdge
            canvas.line(x + 4, ty - 2, x + boxWidth - 4, ty - 2)
        end
        canvas.Font.Style = line.Bold and "[fsBold]" or self.EmptyStyle
        canvas.Font.Color = line.Color
        brush.Color = colors.CardFill
        canvas.textOut(x + card.Padding, ty, line.Text)
        ty = ty + card.LineHeight
    end
    canvas.Font.Style = self.EmptyStyle
end

--------------------------------------------------------
--                    Interaction                     --
--------------------------------------------------------

function TeleporterMap:_MouseDown(button, x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return end
    self.Mouse = { X = x, Y = y }
    if isRightButton(button) then
        -- The popup menu opens on its own after this. Remember what is
        -- under the cursor so its items act on it.
        local marker = self:MarkerAt(x, y)
        local wx, wy = self:ToWorld(x, y)
        self.ContextPoint = { X = x, Y = y, WX = wx, WY = wy, Marker = marker }
        if marker then self:SelectMarker(marker) end
        self:_UpdateContextMenu()
        return
    end
    self.Drag = {
        StartX = x, StartY = y, CenterX = self.Camera.X, CenterY = self.Camera.Y,
        Marker = isLeftButton(button) and self:MarkerAt(x, y) or nil, Moved = false,
    }
end

function TeleporterMap:_MouseMove(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return end
    self.Mouse = { X = x, Y = y }
    local drag = self.Drag
    -- A drag whose button is no longer held is a leftover: the MouseUp that
    -- would have ended it went to a modal dialog, the confirmation being
    -- the usual one. Without this the map pans with the bare pointer.
    if drag and mouseButtonDown() == false then
        self.Drag, drag = nil, nil
        safeSet(self.Surface, "Cursor", self.Hover and -21 or 0)
    end
    if drag then
        local dx, dy = x - drag.StartX, y - drag.StartY
        if not drag.Moved and (math.abs(dx) > 3 or math.abs(dy) > 3) then
            drag.Moved = true
            self:_CancelZoom()
            if self.View.FollowPlayer then
                self.View.FollowPlayer = false
                self:_UpdateToggles()
            end
            safeSet(self.Surface, "Cursor", -22) -- crSizeAll
        end
        if drag.Moved then
            local view = self:_View()
            self.Camera.X = drag.CenterX - dx / (view.Scale * view.SignX)
            self.Camera.Y = drag.CenterY - dy / (view.Scale * view.SignY)
            self:Redraw()
        end
        self:_UpdateInfo()
        return
    end
    local marker = self:MarkerAt(x, y)
    if marker ~= self.Hover then
        self.Hover = marker
        safeSet(self.Surface, "Cursor", marker and -21 or 0) -- crHandPoint / crDefault
        self:Redraw()
    end
    self:_UpdateInfo()
end

function TeleporterMap:_MouseUp(button, x, y)
    local drag = self.Drag
    self.Drag = nil
    if not drag then return end
    safeSet(self.Surface, "Cursor", self.Hover and -21 or 0)
    if drag.Moved then
        self:_MarkViewDirty()
        return
    end
    if not isLeftButton(button) then return end
    if drag.Marker then
        self:SelectMarker(drag.Marker)
        if self.View.OneClickTeleport then
            self:TeleportToMarker(drag.Marker)
        end
    elseif controlPressed() then
        local wx, wy = self:ToWorld(drag.StartX, drag.StartY)
        self:TeleportToPoint(wx, wy, shiftPressed())
    else
        self:SelectMarker(nil)
    end
end

function TeleporterMap:_MouseLeave()
    self.Mouse = nil
    if self.Hover then
        self.Hover = nil
        safeSet(self.Surface, "Cursor", 0)
        self:Redraw()
    end
end

--
--- ∑ A double click jumps to the marker under the cursor. With one-click
---   teleport on, the first click already did, so this only matters when
---   it is off.
--
function TeleporterMap:_DoubleClick()
    -- The second click's MouseDown opened a drag whose MouseUp the dialog
    -- below will swallow. It must not survive the dialog.
    self.Drag = nil
    if self.View.OneClickTeleport then return end
    local mouse = self.Mouse
    local marker = mouse and self:MarkerAt(mouse.X, mouse.Y) or self.Hover
    if marker then
        self:SelectMarker(marker)
        self:TeleportToMarker(marker)
    end
end

--
--- ∑ Whether keystrokes belong to the filter box. OnEnter and OnExit say
---   so on a build that dispatches them; the form's ActiveControl is the
---   fallback, compared by name because two Lua wrappers of one control
---   need not be equal.
--
function TeleporterMap:_FilterHasFocus()
    if self.FilterFocused then return true end
    local ui = self.UiState
    if not ui or not ui.Form or not ui.FilterEdit then return false end
    local active = safeGet(ui.Form, "ActiveControl")
    return active ~= nil and safeGet(active, "Name") == FILTER_EDIT_NAME
end

--- Whether the area dropdown has focus. It answers Up, Down, Home, End,
--- PageUp and PageDown itself, and the map would otherwise eat all six
--- before the list ever sees them.
function TeleporterMap:_ComboHasFocus()
    if self.ComboFocused then return true end
    local ui = self.UiState
    if not ui or not ui.Form or not ui.AreaCombo then return false end
    local active = safeGet(ui.Form, "ActiveControl")
    return active ~= nil and safeGet(active, "Name") == AREA_COMBO_NAME
end

--
--- ∑ Whether keystrokes belong to one of the details card's boxes. They
---   are read only, but they take focus so their text can be selected and
---   copied, and a caret that Home, End and the arrows do not move is not
---   a box anyone can copy from. Tracked the same way as the filter box.
--
function TeleporterMap:_EditHasFocus()
    if self.EditFocused then return true end
    local ui = self.UiState
    if not ui or not ui.Form then return false end
    local active = safeGet(ui.Form, "ActiveControl")
    local name = active ~= nil and safeGet(active, "Name")
    return type(name) == "string" and name:sub(1, #DETAIL_EDIT_PREFIX) == DETAIL_EDIT_PREFIX
end

--- Names a details box and tracks its focus through OnEnter and OnExit, the
--- way the filter box is tracked; the name is the fallback for a build that
--- does not dispatch those two.
function TeleporterMap:_TrackEditFocus(edit, key)
    nameControl(edit, DETAIL_EDIT_PREFIX .. tostring(key):gsub("[^%w_]", ""))
    safeSet(edit, "OnEnter", function() self.EditFocused = true end)
    safeSet(edit, "OnExit", function() self.EditFocused = false end)
end

--
--- ∑ Keyboard handling, from the window's OnKeyDown.
--- @param key number # Virtual key code.
--- @return boolean # Whether the key was consumed.
--
function TeleporterMap:HandleKey(key)
    if self:_EditHasFocus() or self:_ComboHasFocus() then return false end
    if self:_FilterHasFocus() then
        if key == 27 then -- Escape clears the filter and hands focus back
            self:SetFilter("")
            local ui = self.UiState
            if ui and ui.FilterEdit then ui.FilterEdit.Text = "" end
            pcall(function() self.SurfaceParent.SetFocus() end)
            return true
        end
        return false
    end
    if key == 107 or key == 187 then self:ZoomIn() return true end     -- + / =
    if key == 109 or key == 189 then self:ZoomOut() return true end    -- - / _
    if key == 36 then self:FitAll(shiftPressed()) return true end      -- Home / Shift+Home
    if key == 35 then self:CenterOnPlayer() return true end            -- End
    if key == 32 then self:SetFollow(not self.View.FollowPlayer) return true end -- Space
    if key == 13 then self:TeleportToSelected() return true end        -- Enter
    if key == 27 then self:SelectMarker(nil) return true end           -- Escape
    if key == 37 then self:PanBy(-60, 0) return true end               -- arrows
    if key == 39 then self:PanBy(60, 0) return true end
    if key == 38 then self:PanBy(0, -60) return true end
    if key == 40 then self:PanBy(0, 60) return true end
    if key == 71 then self:Toggle("ShowGrid") return true end          -- G
    if key == 76 then self:Toggle("ShowLabels") return true end        -- L
    if key == 84 then self:Toggle("ShowTrail") return true end         -- T
    if key == 90 then self:ZoomToPile() return true end                -- Z
    if key == 33 then self:CycleArea(-1) return true end               -- PageUp
    if key == 34 then self:CycleArea(1) return true end                -- PageDown
    if key == 188 then self:CycleHeightBand(-1) return true end        -- ,
    if key == 190 then self:CycleHeightBand(1) return true end         -- .
    if key == 46 then self:DeleteSelectedSave() return true end        -- Delete
    if key == 113 then self:RenameSelectedSave() return true end       -- F2
    if key == 70 and controlPressed() then                             -- Ctrl+F
        local ui = self.UiState
        if ui and ui.FilterEdit then pcall(function() ui.FilterEdit.SetFocus() end) end
        return true
    end
    return false
end
registerLuaFunctionHighlight('HandleKey')

--------------------------------------------------------
--                       Window                       --
--------------------------------------------------------

function TeleporterMap:EnsureUiState()
    self.UiState = self.UiState or {}
    return self.UiState
end
registerLuaFunctionHighlight('EnsureUiState')

function TeleporterMap:SetStatus(text)
    local ui = self.UiState
    if ui and ui.StatusLabel then
        safeSet(ui.StatusLabel, "Caption", text or "Ready")
    end
end
registerLuaFunctionHighlight('SetStatus')

--- The right hand side of the status bar: cursor, zoom and player.
function TeleporterMap:_UpdateInfo()
    local ui = self.UiState
    if not ui or not ui.InfoLabel then return end
    local _, _, hName, vName = self:GetPlane()
    hName, vName = hName or "X", vName or "Y"
    local parts = {}
    if self.Mouse then
        local wx, wy = self:ToWorld(self.Mouse.X, self.Mouse.Y)
        parts[#parts + 1] = string.format("%s %s  %s %s", hName, Geometry.FormatUnits(wx), vName, Geometry.FormatUnits(wy))
    end
    parts[#parts + 1] = string.format("zoom %s px/u", Geometry.FormatUnits(math.floor(self.Camera.Scale * 1000 + 0.5) / 1000))
    local band = tonumber(self.View.HeightBand) or 0
    if band > 0 then
        parts[#parts + 1] = string.format("band ±%s u", Geometry.FormatUnits(band))
    end
    local point = self:_PlayerPoint()
    if point then
        parts[#parts + 1] = string.format("player %s %s  %s %s%s", hName, Geometry.FormatUnits(math.floor(point.X * 100 + 0.5) / 100),
                                          vName, Geometry.FormatUnits(math.floor(point.Y * 100 + 0.5) / 100),
                                          self.PlayerStale and " (stale)" or "")
    else
        parts[#parts + 1] = "player unknown"
    end
    safeSet(ui.InfoLabel, "Caption", table.concat(parts, "   |   "))
end

--- The map card's header: which plane, how many markers.
function TeleporterMap:_UpdateHeader()
    local ui = self.UiState
    if not ui then return end
    local _, _, hName, vName = self:GetPlane()
    if ui.MapHeaderLabel then
        local where = ""
        if self.Area.Selected == AREA_NONE then
            where = "  ·  No Area"
        elseif type(self.Area.Selected) == "string" then
            where = "  ·  " .. self.Area.Selected
        end
        safeSet(ui.MapHeaderLabel, "Caption", string.format("MAP  %s / %s%s", hName or "?", vName or "?", where))
    end
    if ui.MapStatsLabel then
        local total = #self.Markers
        local shown = self.ShownCount or total
        local caption = self:AreaCaption()
        if shown ~= total then caption = string.format("%d of %s", shown, caption) end
        -- What the canvas is saying, in words: how many heaps carry a count,
        -- and whether there was room for every name. A number painted on a
        -- picture needs a total somewhere to belong to, and a map that drops
        -- names must not look like a map that lost saves.
        local piles = tonumber(self.PileCount) or 0
        if piles > 0 then
            caption = string.format("%s  ·  %d pile%s", caption, piles, piles == 1 and "" or "s")
        end
        -- "41 of 45 names" next to "93 saves" reads as two denominators for
        -- one thing. The 45 are the names this frame had room to try - the
        -- marks on screen - and the clause has to name the screen, or a
        -- reader who counts the discs and counts the saves finds two
        -- different totals for what looks like one number.
        local placed, wanted = tonumber(self.LabelsPlaced) or 0, tonumber(self.LabelsWanted) or 0
        if wanted > placed then
            caption = string.format("%s  ·  %d of %d names on screen", caption, placed, wanted)
        end
        safeSet(ui.MapStatsLabel, "Caption", caption)
    end
end

--- What the painter found, in the map card's caption. Written from the paint
--- path, so it only touches a control when one of the three numbers actually
--- changed: a frame that draws the same picture writes nothing.
function TeleporterMap:_UpdateStats()
    local signature = string.format("%d/%d/%d", self.PileCount or 0,
                                    self.LabelsPlaced or 0, self.LabelsWanted or 0)
    if self.StatsSignature == signature then return end
    self.StatsSignature = signature
    self:_UpdateHeader()
end

--- Toggle buttons and checked menu items reflect the View options.
function TeleporterMap:_UpdateToggles()
    local ui = self.UiState
    if not ui then return end
    if ui.FollowLabel then
        safeSet(ui.FollowLabel, "Caption", self.View.FollowPlayer and "Follow: On" or "Follow: Off")
    end
    for _, entry in ipairs(ui.CheckedItems or {}) do
        local checked = entry.Checked()
        safeSet(entry.Item, "Checked", checked == true)
    end
end

function TeleporterMap:_ApplyDetailsVisibility()
    local ui = self.UiState
    if ui and ui.DetailsHost then
        safeSet(ui.DetailsHost, "Visible", self.View.ShowDetails ~= false)
    end
end

--- The details card shows the selection.
function TeleporterMap:_UpdateDetails()
    local ui = self.UiState
    if not ui or not ui.DetailNameEdit then return end
    local marker = self.Selected
    safeSet(ui.DetailNameEdit, "Text", marker and marker.Name or "")
    safeSet(ui.DetailCategoryEdit, "Text", marker and marker.Category or "")
    safeSet(ui.DetailAuthorEdit, "Text", marker and marker.Author or "")
    local areaText = ""
    if marker and marker.Area then
        areaText = marker.Area .. (marker.AreaDerived and " (derived)" or "")
    end
    safeSet(ui.DetailAreaEdit, "Text", areaText)
    for index, axis in ipairs(ui.DetailAxisKeys or {}) do
        local edit = ui["Detail" .. axis .. "Edit"]
        local value = marker and marker.Position and marker.Position[index]
        -- Three decimals, the same as Copy Coordinates. Not the canvas
        -- rounding: FormatRounded drops to whole numbers above ten, which
        -- is right for a label competing for room and wrong for the one
        -- place the coordinate is there to be read.
        safeSet(edit, "Text", value ~= nil and Geometry.FormatUnits(value) or "")
    end
    if ui.DetailDescriptionEdit then
        pcall(function() ui.DetailDescriptionEdit.Lines.Text = marker and marker.Description or "" end)
    end
end

--
--- ∑ Builds a menu from a flat spec. "-" is a separator. An entry may carry
---   a Checked function, in which case the item shows a check mark that
---   _UpdateToggles keeps current.
--
local function addMenuItems(self, owner, root, entries)
    local ui = self:EnsureUiState()
    ui.CheckedItems = ui.CheckedItems or {}
    for _, entry in ipairs(entries) do
        if entry then
            local item = createMenuItem(owner)
            item.Caption = entry[1]
            item.OnClick = entry[2]
            if type(entry.Checked) == "function" then
                safeSet(item, "AutoCheck", false)
                ui.CheckedItems[#ui.CheckedItems + 1] = { Item = item, Checked = entry.Checked }
            end
            root.add(item)
            if entry.Key then ui[entry.Key] = item end
            if type(entry.Children) == "table" then
                addMenuItems(self, owner, item, entry.Children)
            end
        end
    end
end

function TeleporterMap:_CreateMenuStrip(form)
    local ui = self:EnsureUiState()
    local menu = createMainMenu(form)
    form.Menu = menu
    ui.MainMenu = menu
    local bandEntries = {}
    for _, step in ipairs(HEIGHT_BAND_STEPS) do
        local caption = step == 0 and "Off" or ("±" .. Geometry.FormatUnits(step) .. " u")
        bandEntries[#bandEntries + 1] = { caption, function() self:SetHeightBand(step) end,
            Checked = function() return (tonumber(self.View.HeightBand) or 0) == step end }
    end
    local planeEntries = {}
    for _, choice in ipairs(self:PlaneChoices()) do
        planeEntries[#planeEntries + 1] = { choice.Caption, function() self:SetPlane(choice.H, choice.V) end,
            Checked = function()
                local h, v = self:GetPlane()
                return h == choice.H and v == choice.V
            end }
    end
    local function toggle(caption, option)
        return { caption, function() self:Toggle(option) end, Checked = function() return self.View[option] == true end }
    end
    local menus = {
        { "&File", {
            { "Reload Saves", function()
                teleporter:SaveLookup()
                self:RebuildMarkers()
                self:SetStatus("Saves reloaded")
            end },
            { "Open Teleporter", function()
                if type(teleporter.InitTeleporterUI) == "function" then teleporter:InitTeleporterUI() end
            end },
            { "-" },
            { "Close", function()
                local ui = self.UiState
                if ui and ui.Form then ui.Form.close() end
            end },
        } },
        { "&View", {
            { "Fit All (Home)", function() self:FitAll() end },
            { "Fit Every Save (Shift+Home)", function() self:FitAll(true) end },
            { "Zoom To Pile (Z)", function() self:ZoomToPile() end },
            { "Center On Player (End)", function() self:CenterOnPlayer() end },
            { "Zoom In (+)", function() self:ZoomIn() end },
            { "Zoom Out (-)", function() self:ZoomOut() end },
            { "-" },
            { "Follow Player (Space)", function() self:SetFollow(not self.View.FollowPlayer) end,
              Checked = function() return self.View.FollowPlayer == true end },
            toggle("Grid (G)", "ShowGrid"),
            toggle("Rulers", "ShowRulers"),
            toggle("Labels (L)", "ShowLabels"),
            toggle("Trail (T)", "ShowTrail"),
            toggle("Scale Markers By Height", "ScaleByHeight"),
            toggle("Details Panel", "ShowDetails"),
            { "Clear Trail", function() self:ClearTrail() end },
            { "-" },
            #planeEntries > 1 and { "Plane", nil, Children = planeEntries } or false,
            -- Filled by _RefreshAreaControls, which knows the areas.
            { "Area", nil, Children = {}, Key = "AreaMenuItem" },
            { "Height Band", nil, Children = bandEntries },
            { "Flip Horizontal", function() self:FlipHorizontal() end,
              Checked = function() return self.Plane.FlipHorizontal == true end },
            { "Flip Vertical", function() self:FlipVertical() end,
              Checked = function() return self.Plane.FlipVertical == true end },
        } },
        { "&Teleport", {
            { "To Selected Save (Enter)", function() self:TeleportToSelected() end },
            { "One-Click Teleport", function() self:Toggle("OneClickTeleport") end,
              Checked = function() return self.View.OneClickTeleport == true end },
            { "Confirm Before Teleport", function() self:Toggle("ConfirmTeleport") end,
              Checked = function() return self.View.ConfirmTeleport == true end },
            { "-" },
            { "Open Selected In Editor", function() self:OpenInEditor() end },
        } },
    }
    for _, entry in ipairs(menus) do
        local top = createMenuItem(menu)
        top.Caption = entry[1]
        menu.Items.add(top)
        addMenuItems(self, menu, top, entry[2])
    end
    -- Once the whole menu exists, because the dark background only reaches
    -- the submenus that are there when it is set.
    if type(forms.ThemeMenuBar) == "function" then forms:ThemeMenuBar(form) end
end

--
--- ∑ The right-click menu over the map. Captions name what is under the
---   cursor, which _UpdateContextMenu fills in just before it opens.
--
function TeleporterMap:_CreateContextMenu()
    local ui = self:EnsureUiState()
    local menu = createPopupMenu(self.Surface)
    ui.ContextMenu = menu
    local function point()
        return self.ContextPoint
    end
    local function marker()
        local context = self.ContextPoint
        return context and context.Marker or nil
    end
    ui.ContextItems = {}
    ui.ContextMarkerItems = {}
    local entries = {
        { "Teleport To Save", function()
            if marker() then self:TeleportToMarker(marker()) end
        end, Key = "Marker" },
        { "Teleport Here", function()
            local context = point()
            if context then self:TeleportToPoint(context.WX, context.WY) end
        end, Key = "Here" },
        { "Add Save Here...", function()
            local context = point()
            if context then self:AddSaveAtPoint(context.WX, context.WY) end
        end },
        { "-" },
        -- Everything that edits the save under the cursor goes through the
        -- Teleporter, which prompts, asks and notifies the map itself.
        { "Rename Save...", function()
            if marker() then teleporter:RenameSave(marker().Key) end
        end, Key = "Rename", NeedsMarker = true },
        { "Duplicate Save", function()
            if marker() then self:DuplicateMarker(marker()) end
        end, Key = "Duplicate", NeedsMarker = true },
        { "Delete Save", function()
            if marker() then teleporter:DeleteSave(marker().Key) end
        end, Key = "Delete", NeedsMarker = true },
        { "Set To Player Position", function()
            if marker() then self:MoveSaveToPlayer(marker(), false) end
        end, Key = "MoveTo", NeedsMarker = true },
        { "Set Height To Player", function()
            if marker() then self:MoveSaveToPlayer(marker(), true) end
        end, Key = "HeightTo", NeedsMarker = true },
        { "Set Area", nil, Key = "Area", NeedsMarker = true },
        { "Copy Coordinates", function()
            if marker() then self:CopyCoordinates(marker()) end
        end, Key = "Copy", NeedsMarker = true },
        { "-" },
        { "Center Here", function()
            local context = point()
            if context then self:CenterOn(context.WX, context.WY) end
        end },
        { "Fit All", function() self:FitAll() end },
        { "Open Selected In Editor", function() self:OpenInEditor() end },
    }
    for _, entry in ipairs(entries) do
        local item = createMenuItem(menu)
        item.Caption = entry[1]
        item.OnClick = entry[2]
        menu.Items.add(item)
        if entry.Key then ui.ContextItems[entry.Key] = item end
        if entry.NeedsMarker then ui.ContextMarkerItems[#ui.ContextMarkerItems + 1] = item end
    end
    safeSet(self.Surface, "PopupMenu", menu)
end

--
--- ∑ Fills the context menu's Set Area submenu with the known areas, a
---   (No Area) entry and Other..., rebuilding it only when the names
---   changed. A Teleporter without areas gets no such entry.
--
function TeleporterMap:_RefreshContextAreaMenu()
    local ui = self.UiState
    local item = ui and ui.ContextItems and ui.ContextItems.Area
    if not item then return end
    if type(teleporter.SetSaveArea) ~= "function" then
        safeSet(item, "Visible", false)
        return
    end
    local names = {}
    if type(teleporter.KnownAreas) == "function" then names = teleporter:KnownAreas() end
    local specs = {}
    local function add(caption, area)
        specs[#specs + 1] = { Caption = caption, Selected = area, OnClick = function()
            local marker = self.ContextPoint and self.ContextPoint.Marker
            if not marker then return end
            if area == nil then
                teleporter:PromptSaveArea(marker.Key)
            else
                teleporter:SetSaveArea(marker.Key, area)
            end
        end }
    end
    for _, name in ipairs(names) do add(name, name) end
    add("(No Area)", "")
    add("Other...", nil)
    ui.ContextAreaItems = ui.ContextAreaItems or {}
    syncMenuItems(ui.ContextMenu, item, specs, ui.ContextAreaItems)
    -- Remembered so _UpdateContextMenu can grey it out for a save whose
    -- area comes from its category: clearing a field it does not have
    -- would report success and change nothing.
    ui.ContextNoAreaItem = ui.ContextAreaItems[#names + 1] and ui.ContextAreaItems[#names + 1].Item or nil
end

function TeleporterMap:_UpdateContextMenu()
    local ui = self.UiState
    local context = self.ContextPoint
    if not ui or not ui.ContextItems or not context then return end
    local hasMarker = context.Marker ~= nil
    for _, item in ipairs(ui.ContextMarkerItems or {}) do
        safeSet(item, "Enabled", hasMarker)
    end
    self:_RefreshContextAreaMenu()
    -- Two entries need more than a marker: a height axis to set a height
    -- on, and an explicit field to clear.
    if ui.ContextItems.HeightTo then
        safeSet(ui.ContextItems.HeightTo, "Enabled", hasMarker and self:HeightAxis() ~= nil)
    end
    if ui.ContextNoAreaItem then
        safeSet(ui.ContextNoAreaItem, "Enabled", hasMarker and not context.Marker.AreaDerived)
    end
    local markerItem = ui.ContextItems.Marker
    if markerItem then
        if context.Marker then
            safeSet(markerItem, "Caption", "Teleport To '" .. context.Marker.Name .. "'")
            safeSet(markerItem, "Enabled", true)
        else
            safeSet(markerItem, "Caption", "Teleport To Save")
            safeSet(markerItem, "Enabled", false)
        end
    end
    local hereItem = ui.ContextItems.Here
    if hereItem then
        local _, _, hName, vName = self:GetPlane()
        safeSet(hereItem, "Caption", string.format("Teleport Here  (%s %s, %s %s)", hName or "X",
            Geometry.FormatUnits(math.floor(context.WX * 100 + 0.5) / 100), vName or "Y",
            Geometry.FormatUnits(math.floor(context.WY * 100 + 0.5) / 100)))
    end
end

function TeleporterMap:_CreateToolbar(parent, theme)
    local ui = self:EnsureUiState()
    local header = forms:CreatePanel(parent, {
        align = "alTop", height = 30, color = theme.COLOR_PANEL, role = "panel",
        bevelOuter = "bvNone",
        borderSpacing = { Left = 6, Right = 6, Top = 6, Bottom = 3 },
    })
    ui.ToolbarPanel = header
    -- The filter box sits on the right in the same three-panel nest the
    -- Teleporter's search box uses, so the roles theme it the same way.
    ui.FilterPanel = forms:CreatePanel(header, {
        align = "alRight", width = 220, color = theme.COLOR_BORDER, role = "border",
        bevelOuter = "bvRaised", bevelWidth = 1, bevelColor = theme.COLOR_BORDER,
    })
    ui.FilterFillPanel = forms:CreatePanel(ui.FilterPanel, {
        align = "alClient", color = theme.COLOR_INPUT, role = "inputPanel",
        borderSpacing = { Around = 1 },
    })
    ui.FilterInnerPanel = forms:CreatePanel(ui.FilterFillPanel, {
        align = "alClient", color = theme.COLOR_INPUT, role = "inputPanel",
        borderSpacing = { Left = 8, Right = 8, Top = 4 },
    })
    ui.FilterEdit = forms:CreateTextBox(ui.FilterInnerPanel, {
        align = "alClient", parentColor = false, color = theme.COLOR_INPUT,
        borderStyle = "bsNone", theme = theme, role = "input",
        textHint = "Filter saves...",
    })
    nameControl(ui.FilterEdit, FILTER_EDIT_NAME)
    ui.FilterEdit.OnChange = function() self:SetFilter(ui.FilterEdit.Text) end
    safeSet(ui.FilterEdit, "OnEnter", function() self.FilterFocused = true end)
    safeSet(ui.FilterEdit, "OnExit", function() self.FilterFocused = false end)

    -- The area dropdown, left of the filter, in the same nest. Only when
    -- the Teleporter knows about areas and Forms can build a combo.
    if type(teleporter.GetAreas) == "function" and type(forms.CreateComboBox) == "function" then
        ui.AreaPanel = forms:CreatePanel(header, {
            align = "alRight", width = 200, color = theme.COLOR_BORDER, role = "border",
            bevelOuter = "bvRaised", bevelWidth = 1, bevelColor = theme.COLOR_BORDER,
            borderSpacing = { Right = 6 },
        })
        ui.AreaFillPanel = forms:CreatePanel(ui.AreaPanel, {
            align = "alClient", color = theme.COLOR_INPUT, role = "inputPanel",
            borderSpacing = { Around = 1 },
        })
        ui.AreaCombo = forms:CreateComboBox(ui.AreaFillPanel, {
            align = "alClient", theme = theme, role = "combo",
            borderSpacing = { Left = 3, Right = 3, Top = 2 },
        })
        nameControl(ui.AreaCombo, AREA_COMBO_NAME)
        safeSet(ui.AreaCombo, "OnEnter", function() self.ComboFocused = true end)
        safeSet(ui.AreaCombo, "OnExit", function() self.ComboFocused = false end)
        ui.AreaCombo.OnChange = function()
            if ui.IsRefreshingAreas then return end
            local index = tonumber(ui.AreaCombo.ItemIndex) or -1
            local entry = ui.AreaEntries and ui.AreaEntries[index + 1]
            if entry then self:SetArea(entry.Selected) end
        end
    end

    local buttons = forms:CreatePanel(header, {
        align = "alClient", color = theme.COLOR_PANEL, role = "panel",
    })
    local toolbar = {
        { "Fit",      "Fit All",     86,  function() self:FitAll() end },
        { "Player",   "Player",      80,  function() self:CenterOnPlayer() end },
        { "Follow",   "Follow: Off", 108, function() self:SetFollow(not self.View.FollowPlayer) end },
        { "ZoomOut",  "-",           36,  function() self:ZoomOut() end },
        { "ZoomIn",   "+",           36,  function() self:ZoomIn() end },
        { "Teleport", "Teleport",    92,  function() self:TeleportToSelected() end },
    }
    ui.ButtonKeys = {}
    -- Built last to first. An alLeft control is created at Left = 0, so the
    -- LCL puts each new one LEFT of the ones before it and a list built in
    -- order arrives on screen reversed. The details rows below already do
    -- this for the same reason, with alTop.
    for index = #toolbar, 1, -1 do
        local entry = toolbar[index]
        local key, caption, width, handler = entry[1], entry[2], entry[3], entry[4]
        local button, label = forms:CreateButton(buttons, {
            caption = caption, width = width, theme = theme, onClick = handler,
        })
        ui[key .. "Button"] = button
        ui[key .. "Label"] = label
        ui.ButtonKeys[#ui.ButtonKeys + 1] = key .. "Button"
    end
    return header
end

function TeleporterMap:_CreateStatusBar(parent, theme)
    local ui = self:EnsureUiState()
    ui.StatusPanel = forms:CreatePanel(parent, {
        align = "alBottom", height = 26, color = theme.COLOR_BORDER, role = "border",
        bevelOuter = "bvNone", borderSpacing = { Around = 6 },
    })
    ui.StatusInnerPanel = forms:CreatePanel(ui.StatusPanel, {
        align = "alClient", color = theme.COLOR_PANEL, role = "panel",
        bevelOuter = "bvNone", borderSpacing = { Around = 1 },
    })
    ui.InfoLabel = forms:CreateLabel(ui.StatusInnerPanel, {
        align = "alRight", caption = "", theme = theme, role = "mutedLabel", fontSize = 9,
        transparent = true, borderSpacing = { Right = 8, Top = 4 },
    })
    ui.StatusLabel = forms:CreateLabel(ui.StatusInnerPanel, {
        align = "alLeft", caption = "Ready", theme = theme, role = "label",
        borderSpacing = { Left = 8, Top = 3 },
    })
    return ui.StatusPanel
end

function TeleporterMap:_CreateDetailsPanel(parent, theme)
    local ui = self:EnsureUiState()
    ui.DetailsHost = forms:CreatePanel(parent, {
        align = "alRight", width = 300, color = theme.COLOR_BG, role = "background",
        constraints = { MinWidth = 240 },
    })
    ui.DetailsPanel, ui.DetailsInnerPanel, ui.DetailsHeaderPanel, ui.DetailsContentPanel,
        ui.DetailsHeaderLabel = forms:CreateCard(ui.DetailsHost, {
            align = "alClient", theme = theme, title = "SELECTED SAVE",
        })
    local content = ui.DetailsContentPanel
    ui.DetailsFooterPanel = forms:CreatePanel(content, {
        align = "alBottom", height = 36, color = theme.COLOR_PANEL, role = "panel",
        bevelOuter = "bvLowered", bevelWidth = 1, bevelColor = theme.COLOR_BORDER,
        borderSpacing = { Top = 6 },
    })
    local footer = {
        { "DetailTeleport", "Teleport", 92,  function() self:TeleportToSelected() end },
        { "DetailEditor",   "Editor",   80,  function() self:OpenInEditor() end },
        { "DetailCenter",   "Center",   80,  function()
            if self.Selected then self:CenterOn(self.Selected.X, self.Selected.Y) end
        end },
    }
    -- Last to first, the same alLeft rule as the toolbar.
    for index = #footer, 1, -1 do
        local entry = footer[index]
        local button, label = forms:CreateButton(ui.DetailsFooterPanel, {
            caption = entry[2], width = entry[3], theme = theme, onClick = entry[4],
        })
        ui[entry[1] .. "Button"], ui[entry[1] .. "Label"] = button, label
        ui.ButtonKeys[#ui.ButtonKeys + 1] = entry[1] .. "Button"
    end
    ui.DetailMemoBorderPanel = forms:CreatePanel(content, {
        align = "alClient", color = theme.COLOR_BORDER, role = "border",
        bevelOuter = "bvRaised", bevelWidth = 1, bevelColor = theme.COLOR_BORDER,
        borderSpacing = { Top = 6, Bottom = 6 },
    })
    ui.DetailDescriptionEdit, ui.DetailMemoPanel, ui.DetailMemoInnerPanel =
        forms:CreateMemoFrame(ui.DetailMemoBorderPanel, {
            theme = theme, align = "alClient",
            borderSpacing = { Around = 1 },
            innerSpacing = { Left = 6, Right = 6, Top = 6, Bottom = 6 },
        })
    safeSet(ui.DetailDescriptionEdit, "ReadOnly", true)
    self:_TrackEditFocus(ui.DetailDescriptionEdit, "Description")
    local axes = teleporter:GetAxes()
    local ROW_HEIGHT = 40
    ui.DetailFieldsPanel = forms:CreatePanel(content, {
        align = "alTop", height = (4 + #axes) * ROW_HEIGHT - 2, color = theme.COLOR_PANEL, role = "panel",
    })
    -- alTop rows stack newest on top, so they are built last to first.
    local rows = {
        { "Name",     { caption = "Name" } },
        { "Category", { caption = "Category", labelWidth = 76 } },
        { "Author",   { caption = "Author" } },
        { "Area",     { caption = "Area" } },
    }
    for _, axis in ipairs(axes) do
        rows[#rows + 1] = { axis, { caption = axis } }
    end
    for index = #rows, 1, -1 do
        local key, options = rows[index][1], rows[index][2]
        options.theme = theme
        local edit, row, label, border, fill, inner = forms:CreateFieldRow(ui.DetailFieldsPanel, options)
        safeSet(edit, "ReadOnly", true)
        self:_TrackEditFocus(edit, key)
        ui["Detail" .. key .. "Edit"], ui["Detail" .. key .. "Row"], ui["Detail" .. key .. "Label"] = edit, row, label
        ui["Detail" .. key .. "Border"], ui["Detail" .. key .. "Fill"], ui["Detail" .. key .. "Inner"] = border, fill, inner
    end
    ui.DetailAxisKeys = axes
    return ui.DetailsHost
end

function TeleporterMap:_CreateMapPanel(parent, theme)
    local ui = self:EnsureUiState()
    ui.MapHost = forms:CreatePanel(parent, {
        align = "alClient", color = theme.COLOR_BG, role = "background",
    })
    ui.MapPanel, ui.MapInnerPanel, ui.MapHeaderPanel, ui.MapContentPanel, ui.MapHeaderLabel =
        forms:CreateCard(ui.MapHost, {
            align = "alClient", theme = theme, title = "MAP", contentSpacing = { Around = 6 },
        })
    ui.MapStatsLabel = forms:CreateLabel(ui.MapHeaderPanel, {
        align = "alRight", caption = "", theme = theme, role = "mutedLabel", fontSize = 9,
        transparent = true, borderSpacing = { Right = 8, Top = 4 },
    })
    ui.MapBorderPanel = forms:CreatePanel(ui.MapContentPanel, {
        align = "alClient", color = theme.COLOR_BORDER, role = "border",
        bevelOuter = "bvRaised", bevelWidth = 1, bevelColor = theme.COLOR_BORDER,
    })
    ui.MapSurfacePanel = forms:CreatePanel(ui.MapBorderPanel, {
        align = "alClient", color = theme.COLOR_INPUT, role = "inputPanel",
        borderSpacing = { Around = 1 },
    })
    local ok, reason = self:_AttachSurface(ui.MapSurfacePanel)
    if not ok then
        forms:CreateLabel(ui.MapSurfacePanel, {
            align = "alClient", alignment = "taCenter", layout = "tlCenter", transparent = true,
            caption = "No canvas: " .. tostring(reason), theme = theme, role = "mutedLabel",
        })
        logger:Error(MODULE_PREFIX .. " " .. tostring(reason))
        return ui.MapHost
    end
    self:_CreateContextMenu()
    return ui.MapHost
end

--
--- ∑ Opens the map window, or brings it to the front when it is open.
--- @return userdata|nil # The form.
--
function TeleporterMap:Show()
    if not inMainThread() then
        synchronize(function() self:Show() end)
        return
    end
    local ui = self:EnsureUiState()
    if ui.Form and ui.Form.ClassName and ui.Form.ClassName ~= "" then
        ui.Form.show()
        ui.Form.bringToFront()
        self:RebuildMarkers()
        self:Redraw()
        return ui.Form
    end
    local theme = self:Palette()
    local form = forms:CreateForm({
        caption = "[Manifold] Teleporter Map",
        width = 1180, height = 760,
        position = "poScreenCenter",
        role = "form",
        borderStyle = "bsSizeable",
        constraints = { MinWidth = 900, MinHeight = 560 },
    })
    form.Font.Name = "Consolas"
    form.Font.Size = 10
    ui.Form = form
    self.PaintDisabled, self.PaintFailures = false, 0
    self:_CreateMenuStrip(form)
    local function background(parent, opts)
        opts.color, opts.role = theme.COLOR_BG, "background"
        return forms:CreatePanel(parent, opts)
    end
    ui.RootPanel = background(form, { align = "alClient" })
    self:_CreateStatusBar(ui.RootPanel, theme)
    self:_CreateToolbar(ui.RootPanel, theme)
    ui.BodyPanel = background(ui.RootPanel, {
        align = "alClient", borderSpacing = { Left = 6, Right = 6, Bottom = 6 },
    })
    self:_CreateDetailsPanel(ui.BodyPanel, theme)
    self:_CreateMapPanel(ui.BodyPanel, theme)

    pcall(function()
        form.KeyPreview = true
        form.OnKeyDown = function(_, key)
            if self:HandleKey(key) then return 0 end
            return key
        end
    end)

    -- The Teleporter tells the map about edits. The listener is kept so the
    -- window's close can remove it again.
    if type(teleporter.AddSaveListener) == "function" then
        self.SaveListener = self.SaveListener or function() self:RebuildMarkers() end
        teleporter:AddSaveListener(self.SaveListener)
    end

    self:LoadView()
    self:RebuildMarkers()
    self:_ApplyDetailsVisibility()
    self:_UpdateToggles()
    self:_UpdateHeader()

    local timer = createTimer(form)
    timer.Interval = math.max(20, tonumber(self.Player.RefreshInterval) or 100)
    timer.OnTimer = self:_Guard("tick", function() self:Tick() end)
    timer.Enabled = true
    ui.Timer = timer

    -- A second timer, running only while a zoom is travelling. The one
    -- above reads the player's position and must keep its own cadence; a
    -- zoom needs frames, not memory reads.
    local zoomTimer = createTimer(form)
    local zoomFrame = math.max(8, math.floor(tonumber(self.View.ZoomFrameMs) or 16))
    zoomTimer.Interval = zoomFrame
    -- Paced by the clock rather than by the interval. See _ZoomStepMs.
    zoomTimer.OnTimer = self:_Guard("zoom", function()
        self:_AdvanceZoom(self:_ZoomStepMs(zoomFrame))
    end)
    zoomTimer.Enabled = false
    ui.ZoomTimer = zoomTimer

    form.OnClose = function()
        -- The file should hold the zoom that was asked for, not the frame
        -- the animation happened to be on when the window closed.
        self:SettleZoom()
        self:SaveView()
        pcall(function() timer.Enabled = false end)
        pcall(function() zoomTimer.Enabled = false end)
        self.ZoomAnim = nil
        if self.SaveListener and type(teleporter.RemoveSaveListener) == "function" then
            teleporter:RemoveSaveListener(self.SaveListener)
        end
        if self.Buffer then
            pcall(function() self.Buffer.destroy() end)
            self.Buffer, self.BufferWidth, self.BufferHeight = nil, nil, nil
        end
        self.Surface, self.SurfaceParent, self.PictureBitmap = nil, nil, nil
        self.Hover, self.Drag, self.Mouse = nil, nil, nil
        self.FilterFocused, self.EditFocused, self.ComboFocused = nil, nil, nil
        -- caFree frees every control with the form. The registry must not
        -- keep them, or the next theme change reads freed memory.
        if type(forms.UnregisterRoot) == "function" then
            forms:UnregisterRoot(form)
        end
        self.UiState = nil
        return caFree
    end

    form.show()
    form.centerScreen()
    if not self.Camera.Fitted then
        self:FitAll()
    else
        self:Redraw()
    end
    self:SetStatus(string.format("%d saves on the map%s", #self.Markers, self:FitNote()))
    self:_UpdateInfo()
    return form
end
registerLuaFunctionHighlight('Show')

--- The Teleporter's name for the same thing, for tables that call it that way.
function TeleporterMap:InitMapUI()
    return self:Show()
end
registerLuaFunctionHighlight('InitMapUI')

function TeleporterMap:Close()
    local ui = self.UiState
    if ui and ui.Form then ui.Form.close() end
end
registerLuaFunctionHighlight('Close')

--
--- ∑ Reaction to a theme change. The controls are recoloured by
---   Manifold.Forms through their roles before this is called; what is left
---   is the canvas, whose colours are derived from the new palette on the
---   next frame.
--- @return boolean # Whether the window was open.
--
function TeleporterMap:OnThemeApplied()
    local ui = self.UiState
    if not ui or not ui.Form then return false end
    self.CachedPalette = nil
    self:Redraw()
    return true
end
registerLuaFunctionHighlight('OnThemeApplied')

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return TeleporterMap
