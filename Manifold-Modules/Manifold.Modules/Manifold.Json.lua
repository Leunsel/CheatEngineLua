local NAME        = "Manifold.Json.lua"
local AUTHOR      = {"Leunsel", "LeFiXER"}
local VERSION     = "1.0.2"
local DESCRIPTION = "Manifold Framework JSON Encoder / Decoder"

--[[
    ∂ v1.0.2 (2026-09-01)
        PrintModuleInfo is one block, and keeps its print fallback
        for use without a logger.

    ∂ v1.0.1 (2026-08-23)
        Optional Manifold.Logger integration. Encode and decode failures are
        reported through the framework logger when the Cheat Table has created
        one; the module loads, behaves and returns identically when it has not.

    ∂ v1.0.0 (2026-08-23)
        Initial release. Self-contained rewrite that replaces the vendored
        third-party (Jeffrey Friedl) implementation.
]]--

--[[
    Benchmarking (v1.0.0) Results:
                                  | New    | Old    | Ratio    |
             Encode (20k Records) | 0.187s | 0.310s | 1.66x    |
                           Decode | 0.234s | 0.280s | 1.20x    |
                50k Clean Strings | 0.046s | 0.069s | 1.50x    |
              50k Escaped Strings | 0.090s | 0.083s | ~Pairity |
]]

Json = {}
Json.__index = Json

local MODULE_PREFIX = "[Json]"

--
--- ∑ Opt-in per-call summaries. Off by default, and off costs a single field
---   read per public call - never per value, per key or per character.
---   Same idea as Patcher.Debug, but it defaults to false because this module
---   is on the hot path and because Manifold.Logger writes the log file BEFORE
---   it applies its level filter: every emitted line is two directory stats
---   plus an open/write/close, whatever level it carries.
--
Json.Debug = false

--
--- ∑ Bytes of the offending input quoted next to a decode failure in the log.
---   This is what separates "genuine syntax error at line 12" from "the file
---   was a 404 page", "the file was empty" and "the download was truncated".
---   Set to 0 to quote nothing.
--
Json.ExcerptBytes = 96

--
--- Two copies of this module exist in the repository and
--- CETrequire("Manifold.Json") resolves the flat one. Naming the chunk that
--- actually ran turns "but I already patched that" into a one line answer.
--
local SOURCE = "?"
if type(debug) == "table" and type(debug.getinfo) == "function" then
    local info = debug.getinfo(1, "S")
    if info and info.short_src then SOURCE = info.short_src end
end

--
--- Local alias so the module stays usable outside of Cheat Engine.
--- Inside CE this resolves to the real highlighter, elsewhere to a no-op.
--
local registerLuaFunctionHighlight = registerLuaFunctionHighlight or function() end

--- Forward declaration; defined further down next to the other sentinel helpers.
local _isModuleSelf

--
--- ∑ Manifold.Bootstrap handshake. Uses the framework core when the cheat
---   table has loaded it, and degrades to an inert stub when it has not. This
---   module is the framework leaf and must stay loadable entirely on its own,
---   which is exactly what the stub guarantees.
--
local BOOTSTRAP = rawget(_G, "ManifoldBootstrap") or {
    Declare = function(spec) return spec end,
    Resolve = function() return true end,
    Ready   = function(_, instance) return instance end,
    Once    = function(_, fn) if type(fn) == "function" then pcall(fn) end return true end,
}

--
--- ∑ Identity and dependency contract. The logger is RUNTIME, not optional.
---   Manifold.Json is position 1 in Bootstrap.ORDER - it is constructed before
---   any logger can exist, by design - so declaring the logger as a load-time
---   optional would mark this module DEGRADED on every single boot. Every log
---   site in this file is guarded and resolves the global at call time, which
---   is exactly what `runtime` describes.
--
local MODULE = BOOTSTRAP.Declare({
    class = "Json", global = "json",
    name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION,
    prefix = MODULE_PREFIX,
    deps = {
        { "logger", runtime = true },
    },
})


--
--- ∑ Creates a module instance.
---   Tolerates Json.New() as well as Json:New(); a missing self falls back to
---   the module table instead of producing a metatable-less orphan.
--- @return table
--
function Json:New()
    local instance = setmetatable({}, _isModuleSelf(self) and self or Json)
    instance.Name = NAME or "Unnamed Module"
    -- On the module table rather than on "self": New() is call-style agnostic
    -- and "self" may legitimately be nil here (the line above compensates).
    Json:CheckDependencies()
    return BOOTSTRAP.Ready(MODULE, instance)
end
registerLuaFunctionHighlight('New')

--
--- ∑ The single dependency lookup, shared by every Manifold module.
---   Manifold.Json declares only an OPTIONAL logger, so this never refuses; it
---   records whether diagnostics are live for the ready line. Unlike its
---   siblings it still loads nothing, which is the property that keeps the
---   framework leaf a leaf.
---   The bespoke startup banner this function used to emit is gone:
---   Bootstrap.Ready now emits exactly one line per module, carrying NAME and
---   VERSION, and it is latched on emission so a late logger still gets it.
--- @return boolean, table # resolved, list of missing dependency names
--
function Json:CheckDependencies()
    return BOOTSTRAP.Resolve(MODULE)
end
registerLuaFunctionHighlight('CheckDependencies')

--
--- ∑ Retrieves module metadata as a structured table.
--- @return table # {name, version, author, description}
--
function Json:GetModuleInfo()
    return { name = NAME, version = VERSION, author = AUTHOR, description = DESCRIPTION }
end
registerLuaFunctionHighlight('GetModuleInfo')

--
--- ∑ Prints module details in a readable formatted block.
---   Same shape as every other module, with one difference that keeps this
---   module usable standalone. The sibling bodies address the global "logger"
---   unconditionally and throw without one, this one falls back to print.
--
function Json:PrintModuleInfo()
    local info = self:GetModuleInfo()
    local author = type(info.author) == "table" and table.concat(info.author, ", ") or tostring(info.author)
    local title = "Module Info : " .. tostring(info.name)
    local rows = {
        { "Version",     info.version },
        { "Author",      author },
        { "Description", info.description },
    }
    if logger and logger.InfoBlock then
        logger:InfoBlock(title, rows, { indent = "\t" })
        return
    end
    print(title)
    for _, row in ipairs(rows) do
        print("\t" .. row[1] .. " : " .. tostring(row[2]))
    end
end
registerLuaFunctionHighlight('PrintModuleInfo')

--------------------------------------------------------
--                  Module Start                      --
--------------------------------------------------------

----------------------------------------------------------------
-- Localised standard library
----------------------------------------------------------------

local type, pairs, tostring, tonumber              = type, pairs, tostring, tonumber
local setmetatable, getmetatable, rawget, rawequal = setmetatable, getmetatable, rawget, rawequal
local pcall, error                                 = pcall, error
local sformat, sbyte, schar                        = string.format, string.byte, string.char
local ssub, sfind, srep, sgsub                     = string.sub, string.find, string.rep, string.gsub
local slower                                       = string.lower
local tconcat, tsort                               = table.concat, table.sort
local mfloor, mhuge                                = math.floor, math.huge
local mtype                                        = math.type       -- Lua 5.3+
local mtointeger                                   = math.tointeger  -- Lua 5.3+

----------------------------------------------------------------
-- Stable marker keys
-- These are plain strings on purpose.
----------------------------------------------------------------

local SELF_KEY = "__ManifoldJsonModule"
local NULL_KEY = "__ManifoldJsonNull"
local KIND_KEY = "__ManifoldJsonKind"
local ORDER_KEY = "__ManifoldJsonKeyOrder"
local ERROR_KEY = "__ManifoldJsonError"

Json[SELF_KEY] = true

----------------------------------------------------------------
-- Sentinels
----------------------------------------------------------------

--
--- ∑ The value used to represent JSON "null".
---   Lua tables cannot store nil, so a dedicated sentinel is required to
---   distinguish "key absent" from "key present but null".
--
local Null = setmetatable(
    { [NULL_KEY] = true },
    {
        __tostring = function() return "null" end,
        __newindex = function() error(MODULE_PREFIX .. " Json.Null is immutable.", 2) end,
        __metatable = "Manifold.Json.Null",
    }
)
Json.Null = Null

local ARRAY_MT  = { [KIND_KEY] = "array",  __tostring = function() return "json:array"  end }
local OBJECT_MT = { [KIND_KEY] = "object", __tostring = function() return "json:object" end }

--
--- ∑ Detects whether a value is a Manifold.Json null sentinel.
--- @param v any
--- @return boolean
--
local function _isNull(v)
    return type(v) == "table" and rawget(v, NULL_KEY) == true
end

--
--- ∑ Detects whether a value is the module table or an instance of it.
---   Walks the metatable chain with rawget only, so it can never trigger a
---   user __index metamethod and can never throw.
--- @param v any
--- @return boolean
--
_isModuleSelf = function(v)
    if type(v) ~= "table" then return false end
    if rawget(v, SELF_KEY) == true then return true end
    local mt, guard = getmetatable(v), 0
    while type(mt) == "table" and guard < 8 do
        local index = rawget(mt, "__index")
        if type(index) ~= "table" then return false end
        if rawget(index, SELF_KEY) == true then return true end
        mt, guard = getmetatable(index), guard + 1
    end
    return false
end

--
--- ∑ Returns the explicit array/object marker of a table, if any.
--- @param t table
--- @return string|nil # "array", "object" or nil
--- @return table|nil  # the metatable, when it is a table
--
local function _markerKind(t)
    local mt = getmetatable(t)
    if type(mt) == "table" then
        local kind = rawget(mt, KIND_KEY)
        if kind == "array" or kind == "object" then
            return kind, mt
        end
        return nil, mt
    end
    return nil, nil
end

----------------------------------------------------------------
-- Error plumbing
--
-- Internal failures unwind via error() so the recursive walkers stay free of
-- error propagation boilerplate. The public entry points catch them and
-- convert to the "nil, message" contract.
----------------------------------------------------------------

local function _fail(message)
    error({ [ERROR_KEY] = true, message = MODULE_PREFIX .. " " .. message }, 0)
end

--
--- ∑ Converts a raised failure into the public error message.
---   The second return is a fact this function already computed and threw
---   away: it lets the two call sites choose a log level without repeating the
---   ERROR_KEY test. It is never propagated to a public API - both call sites
---   assign it to a local first. Never write "return nil, _unwrapError(err)"
---   again or the boolean leaks out as a third return value.
--- @param err any
--- @return string  # the message, already carrying MODULE_PREFIX
--- @return boolean # true when this was an unexpected Lua error inside this
---                   module rather than a deliberate _fail(), i.e. a real bug
--
local function _unwrapError(err)
    if type(err) == "table" and rawget(err, ERROR_KEY) == true then
        return err.message, false
    end
    return MODULE_PREFIX .. " Internal error: " .. tostring(err), true
end

--
--- ∑ Makes a string safe to hand to the logger as exactly ONE line.
---   This module's error messages quote raw user data - an unexpected
---   character, a number token, a duplicate object key, and every object key
---   along the path built by _pathOf - and Manifold.Logger writes whatever it
---   is given straight into the log file. A decoded key containing a newline
---   would otherwise split one entry across two lines and corrupt the log for
---   whoever reads it afterwards.
---   Only the LOGGED text is sanitised. The message returned to the caller is
---   always verbatim, so callers that match on error strings keep working.
--- @param s string
--- @return string
--
local function _logSafe(s)
    -- Parenthesised: gsub returns a count as its second value, which must not
    -- leak into the argument list of the log call.
    return (sgsub(s, "%c", "."))
end

--
--- ∑ Renders a short printable window of the input around a byte offset.
---   Error path only: it runs after a pcall has already failed. Control bytes
---   collapse to dots so raw input can never break a log line, and the width
---   is capped by Json.ExcerptBytes.
--- @param s string
--- @param pos number|nil
--- @return string|nil
--
local EXCERPT_MAX = 4096

local function _excerpt(s, pos)
    local width = Json.ExcerptBytes
    -- "not (width >= 1)" rather than "width < 1": NaN fails every comparison,
    -- so only the negated form rejects it. Both bounds are then forced to
    -- integers, because string.sub raises on a float with no integer
    -- representation and this function runs OUTSIDE the decoder's pcall - a
    -- fractional Json.ExcerptBytes would otherwise turn a reported failure
    -- into a thrown one and break the module's total contract.
    if type(width) ~= "number" or not (width >= 1) then return nil end
    if width > EXCERPT_MAX then width = EXCERPT_MAX end
    width = mfloor(width)
    local length = #s
    if length == 0 then return "<empty>" end
    local at = (type(pos) == "number" and pos >= 1) and mfloor(pos) or 1
    if at > length then at = length end
    local from = at - mfloor(width / 2)
    if from < 1 then from = 1 end
    local to = from + width - 1
    if to > length then to = length end
    local chunk = _logSafe(ssub(s, from, to))
    return "@" .. at .. " " .. (from > 1 and "..." or "") .. chunk .. (to < length and "..." or "")
end

----------------------------------------------------------------
-- Option handling
----------------------------------------------------------------

--
--- ∑ Mutable module-wide defaults. Per-call options always win over these.
---   Option keys are matched case-insensitively and ignore underscores, so
---   "SortKeys", "sortkeys" and "sort_keys" all address the same setting.
--
Json.Defaults = {
    -- Encoding ------------------------------------------------------------
    Indent             = "  ",     -- string, or a number of spaces
    SortKeys           = nil,      -- nil = sort in pretty mode only
    PreserveOrder      = true,     -- honour a decoded key order when present
    EmptyTable         = "object", -- "object" | "array"
    SparseArray        = "null",   -- "null" | "object" | "error"
    MaxSparseRatio     = 8,        -- fall back to "object" beyond this density
    EscapeUnicode      = false,    -- emit non-ASCII as \uXXXX
    EscapeSlash        = false,    -- emit "/" as "\/"
    InvalidNumber      = "error",  -- NaN/Infinity: "error" | "null" | "string"
    InvalidValue       = "error",  -- functions/userdata: "error" | "null" | "skip"
    InvalidKey         = "error",  -- unusable table keys: "error" | "skip"
    MaxDepth           = 200,
    NullValue          = nil,      -- extra value to treat as null on encode
    -- Decoding ------------------------------------------------------------
    Null               = Null,     -- value produced for JSON null
    MarkTables         = true,     -- tag decoded tables as array/object
    RecordKeyOrder     = false,    -- remember object key order for round-trips
    AllowComments      = false,    -- // line and /* block */ comments
    AllowTrailingComma = false,
    AllowSingleQuotes  = false,
    AllowUnquotedKeys  = false,
    AllowTrailingData  = false,
    AllowDuplicateKeys = true,
    BigIntAsString     = false,    -- integers beyond int64 stay exact as strings
    UnpairedSurrogate  = "replace",-- "replace" | "error" | "raw"
    Lenient            = false,    -- enables the whole Allow* group at once
}

local ENCODE_KEYS = {
    "Pretty", "Indent", "SortKeys", "PreserveOrder", "EmptyTable", "SparseArray",
    "MaxSparseRatio", "EscapeUnicode", "EscapeSlash", "InvalidNumber",
    "InvalidValue", "InvalidKey", "MaxDepth", "NullValue",
}

local DECODE_KEYS = {
    "Null", "MarkTables", "RecordKeyOrder", "AllowComments", "AllowTrailingComma",
    "AllowSingleQuotes", "AllowUnquotedKeys", "AllowTrailingData",
    "AllowDuplicateKeys", "BigIntAsString", "UnpairedSurrogate", "Lenient",
    "MaxDepth",
}

local function _buildAliases(keys)
    local map = {}
    for i = 1, #keys do
        local canonical = keys[i]
        map[canonical] = canonical
        map[slower(canonical)] = canonical
    end
    return map
end

local ENCODE_ALIASES = _buildAliases(ENCODE_KEYS)
local DECODE_ALIASES = _buildAliases(DECODE_KEYS)

--
--- Union of both option sets. Json.Prettify deliberately runs one raw option
--- table through the decode aliases and then the encode aliases, so a key is
--- only genuinely unknown when it resolves in neither.
--
local ALL_ALIASES
do
    local all = {}
    for i = 1, #ENCODE_KEYS do all[#all + 1] = ENCODE_KEYS[i] end
    for i = 1, #DECODE_KEYS do all[#all + 1] = DECODE_KEYS[i] end
    ALL_ALIASES = _buildAliases(all)
end

--- Option keys already examined, so a bad key inside a loop cannot turn one
--- typo into thousands of log file writes.
local _seenOptionKeys = {}

--
--- ∑ Resolves a raw user option table into canonical option names.
--- @param options table|nil
--- @param aliases table
--- @return table|nil
--
local function _normalizeOptions(options, aliases)
    if type(options) ~= "table" then return nil end
    local resolved
    for key, value in pairs(options) do
        if type(key) == "string" then
            local canonical = aliases[key]
            if not canonical then
                local lowered = slower(key)
                canonical = aliases[lowered] or aliases[(sgsub(lowered, "_", ""))]
            end
            if canonical then
                resolved = resolved or {}
                resolved[canonical] = value
            elseif _seenOptionKeys[key] == nil then
                -- Cold branch: a valid option never reaches it. An unknown key
                -- is dropped in total silence today, which makes a typo such as
                -- "sortkey" behave as an unexplained no-op with no trace at
                -- all. Report it once per key per module load.
                _seenOptionKeys[key] = true
                local lowered = slower(key)
                local known = ALL_ALIASES[key] or ALL_ALIASES[lowered]
                              or ALL_ALIASES[(sgsub(lowered, "_", ""))]
                if not known and logger and logger.Warning then
                    -- pcall: this runs outside any protected region and the
                    -- public API must stay total. See the note in _encode.
                    pcall(logger.Warning, logger,
                          MODULE_PREFIX .. " Ignored unknown option '" .. _logSafe(key) .. "'.")
                end
            end
        end
    end
    return resolved
end

--
--- ∑ Reads a single option, falling back to Json.Defaults and then a literal.
--
local function _pick(options, key, fallback)
    if options ~= nil then
        local value = options[key]
        if value ~= nil then return value end
    end
    local defaults = Json.Defaults
    if defaults ~= nil then
        local value = defaults[key]
        if value ~= nil then return value end
    end
    return fallback
end

--
--- ∑ Normalises an indent setting into a string.
--- @param indent string|number|boolean|nil
--- @return string
--
local function _resolveIndent(indent)
    local kind = type(indent)
    if kind == "string" then return indent end
    if kind == "number" then return srep(" ", indent < 0 and 0 or mfloor(indent)) end
    return "  "
end

----------------------------------------------------------------
-- UTF-8 helpers
----------------------------------------------------------------

local REPLACEMENT = "\239\191\189" -- U+FFFD

--
--- ∑ Encodes a Unicode code point as UTF-8.
---   Implemented with plain arithmetic so the module works on any Lua 5.x.
--- @param cp number
--- @return string
--
local function _utf8Char(cp)
    if cp < 0x80 then
        return schar(cp)
    elseif cp < 0x800 then
        return schar(0xC0 + mfloor(cp / 0x40),
                     0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return schar(0xE0 + mfloor(cp / 0x1000),
                     0x80 + (mfloor(cp / 0x40) % 0x40),
                     0x80 + (cp % 0x40))
    elseif cp < 0x110000 then
        return schar(0xF0 + mfloor(cp / 0x40000),
                     0x80 + (mfloor(cp / 0x1000) % 0x40),
                     0x80 + (mfloor(cp / 0x40) % 0x40),
                     0x80 + (cp % 0x40))
    end
    return REPLACEMENT
end

--
--- ∑ Decodes one UTF-8 sequence.
--- @param s string
--- @param i number # byte index of the sequence start
--- @return number|nil # code point, or nil when the sequence is malformed
--- @return number     # number of bytes consumed (always >= 1)
--
local function _utf8Decode(s, i)
    local c1 = sbyte(s, i)
    if c1 == nil then return nil, 1 end
    if c1 < 0x80 then return c1, 1 end
    if c1 >= 0xF0 and c1 <= 0xF7 then
        local c2, c3, c4 = sbyte(s, i + 1, i + 3)
        if c2 and c3 and c4 and c2 >= 0x80 and c3 >= 0x80 and c4 >= 0x80 then
            return (c1 % 0x08) * 0x40000 + (c2 % 0x40) * 0x1000 + (c3 % 0x40) * 0x40 + (c4 % 0x40), 4
        end
    elseif c1 >= 0xE0 then
        local c2, c3 = sbyte(s, i + 1, i + 2)
        if c2 and c3 and c2 >= 0x80 and c3 >= 0x80 then
            return (c1 % 0x10) * 0x1000 + (c2 % 0x40) * 0x40 + (c3 % 0x40), 3
        end
    elseif c1 >= 0xC0 then
        local c2 = sbyte(s, i + 1)
        if c2 and c2 >= 0x80 then
            return (c1 % 0x20) * 0x40 + (c2 % 0x40), 2
        end
    end
    return nil, 1
end

----------------------------------------------------------------
-- Encoder
----------------------------------------------------------------

local ESCAPE_MAP, ESCAPE_MAP_SLASH = {}, {}
do
    ESCAPE_MAP['"']  = '\\"'
    ESCAPE_MAP['\\'] = '\\\\'
    ESCAPE_MAP['\b'] = '\\b'
    ESCAPE_MAP['\f'] = '\\f'
    ESCAPE_MAP['\n'] = '\\n'
    ESCAPE_MAP['\r'] = '\\r'
    ESCAPE_MAP['\t'] = '\\t'
    for i = 0, 31 do
        local c = schar(i)
        if not ESCAPE_MAP[c] then ESCAPE_MAP[c] = sformat("\\u%04x", i) end
    end
    ESCAPE_MAP[schar(127)] = "\\u007f"
    for k, v in pairs(ESCAPE_MAP) do ESCAPE_MAP_SLASH[k] = v end
    ESCAPE_MAP_SLASH['/'] = '\\/'
end

local ESCAPE_PATTERN       = '[%c"\\\127]'
local ESCAPE_PATTERN_SLASH = '[%c"\\/\127]'
local SAFE_RUN_PATTERN     = '^[^%c"\\/\127\128-\255]+'

--
--- ∑ Escapes and quotes a string, additionally escaping every non-ASCII
---   code point as \uXXXX (with surrogate pairs above U+FFFF).
--- @param s string
--- @param map table
--- @return string
--
local function _quoteUnicode(s, map)
    local buf, n, i, len = { '"' }, 1, 1, #s
    while i <= len do
        local b, e = sfind(s, SAFE_RUN_PATTERN, i)
        if b then
            n = n + 1
            buf[n] = ssub(s, b, e)
            i = e + 1
        end
        if i > len then break end
        local byte = sbyte(s, i)
        if byte < 0x80 then
            local char = ssub(s, i, i)
            n = n + 1
            buf[n] = map[char] or char
            i = i + 1
        else
            local cp, size = _utf8Decode(s, i)
            if cp == nil then
                n = n + 1
                buf[n] = "\\ufffd"
            elseif cp < 0x10000 then
                n = n + 1
                buf[n] = sformat("\\u%04x", cp)
            else
                local v = cp - 0x10000
                n = n + 1
                buf[n] = sformat("\\u%04x\\u%04x",
                                 0xD800 + mfloor(v / 0x400),
                                 0xDC00 + (v % 0x400))
            end
            i = i + size
        end
    end
    n = n + 1
    buf[n] = '"'
    return tconcat(buf, "", 1, n)
end

--
--- ∑ Builds the "$.a.b[3]" path shown in encoder diagnostics.
---   Called only when an error is being raised, so the hot path never pays
---   for it. Segments are stored raw and rendered here.
--
local function _pathOf(st, depth)
    local parts, n = { "$" }, 1
    local stack = st.path
    for i = 1, depth do
        local segment = stack[i]
        if segment ~= nil then
            n = n + 1
            parts[n] = (type(segment) == "string") and ("." .. segment)
                                                   or ("[" .. tostring(segment) .. "]")
        end
    end
    return tconcat(parts, "", 1, n)
end

--
--- ∑ Renders a Lua number as a JSON number, preserving round-trip precision.
--- @param v number
--- @param st table
--- @param depth number # only consulted when raising an error
--- @return string
--
local function _encodeNumber(v, st, depth)
    if v ~= v or v == mhuge or v == -mhuge then
        local label = (v ~= v) and "NaN" or (v > 0 and "Infinity" or "-Infinity")
        local mode = st.invalidNumber
        if mode == "null" then return "null" end
        if mode == "string" then return '"' .. label .. '"' end
        _fail("Cannot encode " .. label .. " at " .. _pathOf(st, depth) ..
              " (JSON has no such literal).")
    end
    if mtype then
        if mtype(v) == "integer" then return tostring(v) end
    elseif mfloor(v) == v and v >= -1e15 and v <= 1e15 then
        return sformat("%d", v)
    end
    local text = sformat("%.14g", v)
    if tonumber(text) ~= v then
        text = sformat("%.17g", v)
    end
    return text
end

--
--- ∑ Deterministic ordering for mixed-type table keys.
---   Numbers sort numerically, strings lexicographically, and different key
---   types are grouped by their type name so the result is always stable.
--
local function _keyLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
end

--
--- ∑ Converts a non-string table key into its JSON object key form.
---   Plain string keys never reach this function; _encodeObject writes them
---   straight into the buffer.
--- @return string|nil # nil means "skip this member"
--
local function _encodeKey(key, st, depth)
    local kind = type(key)
    if kind == "number" then
        return '"' .. _encodeNumber(key, st, depth) .. '"'
    elseif kind == "boolean" then
        return key and '"true"' or '"false"'
    end
    if st.invalidKey == "skip" then return nil end
    _fail("Cannot use a " .. kind .. " as an object key at " .. _pathOf(st, depth) .. ".")
end

local _encodeValue -- forward declaration, recursion

--
--- ∑ Writes a quoted, escaped string into the buffer.
---   Clean strings are pushed as three buffer slots ('"', body, '"') so no
---   intermediate copy of the string is ever allocated.
--
local function _putString(s, st)
    local buf, n = st.buf, st.n
    if st.escapeUnicode then
        n = n + 1
        buf[n] = _quoteUnicode(s, st.map)
    else
        n = n + 1; buf[n] = '"'
        n = n + 1
        if sfind(s, st.pattern) then
            buf[n] = sgsub(s, st.pattern, st.map)
        else
            buf[n] = s
        end
        n = n + 1; buf[n] = '"'
    end
    st.n = n
end

--
--- ∑ Collects and orders the keys of a table destined for a JSON object.
--
local function _objectKeys(t, st, mt)
    local keys, n = {}, 0
    if st.preserveOrder and type(mt) == "table" then
        local order = rawget(mt, ORDER_KEY)
        if type(order) == "table" then
            local emitted = {}
            for i = 1, #order do
                local key = order[i]
                if t[key] ~= nil and not emitted[key] then
                    emitted[key] = true
                    n = n + 1
                    keys[n] = key
                end
            end
            local extra, extraCount = {}, 0
            for key in pairs(t) do
                if not emitted[key] then
                    extraCount = extraCount + 1
                    extra[extraCount] = key
                end
            end
            if extraCount > 0 then
                tsort(extra, _keyLess)
                for i = 1, extraCount do
                    n = n + 1
                    keys[n] = extra[i]
                end
            end
            return keys, n
        end
    end
    for key in pairs(t) do
        n = n + 1
        keys[n] = key
    end
    if st.sortKeys and n > 1 then
        tsort(keys, _keyLess)
    end
    return keys, n
end

--
--- ∑ Classifies a table as array, sparse array or object.
--- @return string # "array", "sparse" or "object"
--- @return number # element count / highest index, meaningful for arrays
--
local function _classify(t, st, marker)
    if marker == "array" then
        -- The common case is a dense array, which a single key count confirms.
        -- Only the odd shapes pay for the full analysis below.
        local count, total = #t, 0
        for _ in pairs(t) do total = total + 1 end
        if total == count then return "array", count end
        local highest = count
        for key in pairs(t) do
            if type(key) == "number" and key > highest and mfloor(key) == key then
                highest = key
            end
        end
        return (highest == count) and "array" or "sparse", highest
    elseif marker == "object" then
        return "object", 0
    end
    local count, highest, allInteger = 0, 0, true
    for key in pairs(t) do
        if type(key) == "number" and key >= 1 and mfloor(key) == key then
            count = count + 1
            if key > highest then highest = key end
        else
            allInteger = false
            break
        end
    end
    if not allInteger then return "object", 0 end
    if count == 0 then
        return (st.emptyTable == "array") and "array" or "object", 0
    end
    if highest == count then return "array", count end
    return "sparse", highest
end

--
--- ∑ Returns the "\n" + indent string for a depth, memoised per call.
--
local function _pad(st, depth)
    local cache = st.indentCache
    local pad = cache[depth]
    if not pad then
        pad = "\n" .. srep(st.indentUnit, depth)
        cache[depth] = pad
    end
    return pad
end

--
--- ∑ Encodes a table as a JSON array.
--
local function _encodeArray(t, count, st, depth)
    local buf = st.buf
    local n = st.n
    if count == 0 then
        n = n + 1; buf[n] = "[]"
        st.n = n
        return
    end
    local path = st.path
    local child = depth + 1
    if st.pretty then
        local pad = _pad(st, child)
        local commaPad = st.commaCache[child]
        if not commaPad then
            commaPad = "," .. pad
            st.commaCache[child] = commaPad
        end
        n = n + 1; buf[n] = "["
        n = n + 1; buf[n] = pad
        st.n = n
        for i = 1, count do
            if i > 1 then
                n = st.n + 1; buf[n] = commaPad; st.n = n
            end
            path[child] = i
            local value = t[i]
            if value == nil then
                n = st.n + 1; buf[n] = "null"; st.n = n
            else
                _encodeValue(value, st, child)
            end
        end
        n = st.n
        n = n + 1; buf[n] = _pad(st, depth)
        n = n + 1; buf[n] = "]"
        st.n = n
    else
        n = n + 1; buf[n] = "["
        st.n = n
        for i = 1, count do
            if i > 1 then
                n = st.n + 1; buf[n] = ","; st.n = n
            end
            path[child] = i
            local value = t[i]
            if value == nil then
                n = st.n + 1; buf[n] = "null"; st.n = n
            else
                _encodeValue(value, st, child)
            end
        end
        n = st.n
        n = n + 1; buf[n] = "]"
        st.n = n
    end
end

--
--- ∑ Encodes a table as a JSON object.
--
local function _encodeObject(t, st, depth, mt)
    local keys, count = _objectKeys(t, st, mt)
    local buf = st.buf
    local n = st.n
    if count == 0 then
        n = n + 1; buf[n] = "{}"
        st.n = n
        return
    end
    local pretty = st.pretty
    local path = st.path
    local child = depth + 1
    local skipInvalid = st.invalidValue == "skip"
    local pad, commaPad, separator
    if pretty then
        pad = _pad(st, child)
        commaPad = st.commaCache[child]
        if not commaPad then
            commaPad = "," .. pad
            st.commaCache[child] = commaPad
        end
        separator = ": "
    else
        separator = ":"
    end
    local openIndex = n + 1
    buf[openIndex] = "{"
    st.n = openIndex
    local written = 0
    for i = 1, count do
        local key = keys[i]
        local keyType = type(key)
        path[child] = key
        local literalKey = nil    -- pre-rendered key for non-string key types
        local usable = true
        if keyType ~= "string" then
            literalKey = _encodeKey(key, st, child)
            usable = literalKey ~= nil
        end
        if usable and skipInvalid then
            local valueType = type(t[key])
            if valueType == "function" or valueType == "userdata" or valueType == "thread" then
                usable = false
            end
        end
        if usable then
            written = written + 1
            n = st.n
            if pretty then
                n = n + 1; buf[n] = (written == 1) and pad or commaPad
            elseif written > 1 then
                n = n + 1; buf[n] = ","
            end
            st.n = n
            if literalKey then
                n = st.n + 1; buf[n] = literalKey; st.n = n
            else
                _putString(key, st)
            end
            n = st.n + 1; buf[n] = separator; st.n = n
            _encodeValue(t[key], st, child)
        end
    end
    n = st.n
    if written == 0 then
        -- every member was filtered out, so the opening brace becomes the
        -- whole object
        buf[openIndex] = "{}"
    else
        if pretty then
            n = n + 1; buf[n] = _pad(st, depth)
        end
        n = n + 1; buf[n] = "}"
        st.n = n
    end
end

--
--- ∑ Encodes a sparse integer-keyed table.
---   Fills the gaps with null when the density is reasonable, otherwise falls
---   back to an object so no data is ever silently dropped.
--
local function _encodeSparse(t, highest, st, depth, mt)
    local mode = st.sparseArray
    if mode == "error" then
        _fail("Refusing to encode a sparse array at " .. _pathOf(st, depth) ..
              " (highest index " .. highest .. ").")
    end
    if mode == "null" then
        local count = 0
        for _ in pairs(t) do count = count + 1 end
        if highest <= count * st.maxSparseRatio then
            return _encodeArray(t, highest, st, depth)
        end
    end
    return _encodeObject(t, st, depth, mt)
end

--
--- ∑ Encodes any Lua value into the encoder buffer.
--
_encodeValue = function(value, st, depth)
    local kind = type(value)
    if kind == "string" then
        return _putString(value, st)
    end
    local buf, n = st.buf, st.n
    if kind == "number" then
        n = n + 1
        buf[n] = _encodeNumber(value, st, depth)
        st.n = n
        return
    elseif kind == "boolean" then
        n = n + 1
        buf[n] = value and "true" or "false"
        st.n = n
        return
    elseif kind == "nil" then
        n = n + 1
        buf[n] = "null"
        st.n = n
        return
    elseif kind == "table" then
        if rawget(value, NULL_KEY) == true then
            n = n + 1
            buf[n] = "null"
            st.n = n
            return
        end
        if st.nullValue ~= nil and rawequal(value, st.nullValue) then
            n = n + 1
            buf[n] = "null"
            st.n = n
            return
        end
        if depth >= st.maxDepth then
            _fail("Maximum nesting depth of " .. st.maxDepth .. " exceeded at " ..
                  _pathOf(st, depth) .. ".")
        end
        local seen = st.seen
        if seen[value] then
            _fail("Circular reference detected at " .. _pathOf(st, depth) .. ".")
        end
        seen[value] = true
        local marker, mt = _markerKind(value)
        local shape, count = _classify(value, st, marker)
        if shape == "array" then
            _encodeArray(value, count, st, depth)
        elseif shape == "sparse" then
            _encodeSparse(value, count, st, depth, mt)
        else
            _encodeObject(value, st, depth, mt)
        end
        seen[value] = nil
        return
    end
    if st.nullValue ~= nil and rawequal(value, st.nullValue) then
        n = n + 1
        buf[n] = "null"
        st.n = n
        return
    end
    local mode = st.invalidValue
    if mode == "null" or mode == "skip" then
        -- "skip" only removes object members; anywhere else null is the only
        -- structurally valid substitute.
        n = n + 1
        buf[n] = "null"
        st.n = n
        return
    end
    _fail("Cannot encode a " .. kind .. " at " .. _pathOf(st, depth) .. ".")
end

--
--- ∑ Builds the encoder state for one call.
--
local function _encodeState(options, pretty)
    local escapeSlash = _pick(options, "EscapeSlash", false) and true or false
    local escapeUnicode = _pick(options, "EscapeUnicode", false) and true or false
    local sortKeys = _pick(options, "SortKeys", nil)
    if sortKeys == nil then sortKeys = pretty end
    local map = escapeSlash and ESCAPE_MAP_SLASH or ESCAPE_MAP
    local pattern = escapeSlash and ESCAPE_PATTERN_SLASH or ESCAPE_PATTERN
    return {
        buf            = {},
        n              = 0,
        path           = {},
        seen           = {},
        indentCache    = {},
        commaCache     = {},
        pretty         = pretty and true or false,
        indentUnit     = _resolveIndent(_pick(options, "Indent", "  ")),
        sortKeys       = sortKeys and true or false,
        preserveOrder  = _pick(options, "PreserveOrder", true) and true or false,
        emptyTable     = _pick(options, "EmptyTable", "object"),
        sparseArray    = _pick(options, "SparseArray", "null"),
        maxSparseRatio = _pick(options, "MaxSparseRatio", 8),
        invalidNumber  = _pick(options, "InvalidNumber", "error"),
        invalidValue   = _pick(options, "InvalidValue", "error"),
        invalidKey     = _pick(options, "InvalidKey", "error"),
        maxDepth       = _pick(options, "MaxDepth", 200),
        nullValue      = _pick(options, "NullValue", nil),
        escapeUnicode  = escapeUnicode,
        map            = map,
        pattern        = pattern,
    }
end

--
--- ∑ Encoder entry point shared by Encode and EncodePretty.
--
local function _encode(value, options, pretty)
    if not pretty and options ~= nil and options.Pretty then
        pretty = true
    end
    -- Json.Debug is read first so a disabled flag short-circuits before the
    -- logger global is even touched. Per call, never per value.
    local tracing = Json.Debug and logger and logger.Debug
    local started = tracing and os.clock() or nil
    local st = _encodeState(options, pretty)
    local ok, err = pcall(_encodeValue, value, st, 0)
    if not ok then
        -- "message" already carries MODULE_PREFIX (see _fail); never prefix it
        -- again or the line reads "[Json] [Json] ...".
        local message, internal = _unwrapError(err)
        if internal then
            if logger and logger.Critical then pcall(logger.Critical, logger, _logSafe(message)) end
        elseif logger and logger.Error then
            pcall(logger.Error, logger, _logSafe(message))
        end
        return nil, message
    end
    local result = tconcat(st.buf, "", 1, st.n)
    if tracing then
        -- Json formats and hands over the finished string, so no user data can
        -- ever reach an unprotected string.format inside the logger.
        pcall(logger.Debug, logger, sformat("%s Encoded %d bytes (pretty=%s) in %.3fs.",
              MODULE_PREFIX, #result, tostring(st.pretty), os.clock() - started))
    end
    return result
end

----------------------------------------------------------------
-- Decoder
----------------------------------------------------------------

local UNESCAPE = {
    [34]  = '"',
    [92]  = '\\',
    [47]  = '/',
    [98]  = '\b',
    [102] = '\f',
    [110] = '\n',
    [114] = '\r',
    [116] = '\t',
}

--
--- ∑ Resolves a byte offset into a human readable line/column pair.
--
local function _lineColumn(s, pos)
    local line, lineStart, index = 1, 0, 1
    while true do
        local newline = sfind(s, "\n", index, true)
        if not newline or newline >= pos then break end
        line = line + 1
        lineStart = newline
        index = newline + 1
    end
    return line, pos - lineStart
end

local function _failAt(st, pos, message)
    -- Recorded for the failure report only. This runs on a path that is about
    -- to throw, so a successful decode never pays for it, and one store serves
    -- every _failAt call site in the decoder at once. A store cannot raise, so
    -- it is safe to add inside the protected region where a log call is not.
    st.errPos = pos
    local line, column = _lineColumn(st.s, pos)
    _fail(message .. " (line " .. line .. ", column " .. column .. ")")
end

--
--- ∑ Skips whitespace.
--
local function _skipSpace(s, pos)
    local _, stop = sfind(s, "^[ \t\n\r]*", pos)
    return stop + 1
end

--
--- ∑ Skips whitespace as well as // and /* */ comments.
--
local function _skipSpaceAndComments(s, pos, st)
    while true do
        local _, stop = sfind(s, "^[ \t\n\r]*", pos)
        pos = stop + 1
        if sbyte(s, pos) ~= 47 then return pos end -- '/'
        local next = sbyte(s, pos + 1)
        if next == 47 then                          -- //
            local _, lineEnd = sfind(s, "^[^\n]*", pos + 2)
            pos = lineEnd + 1
        elseif next == 42 then                      -- /*
            local _, blockEnd = sfind(s, "*/", pos + 2, true)
            if not blockEnd then
                _failAt(st, pos, "Unterminated block comment")
            end
            pos = blockEnd + 1
        else
            return pos
        end
    end
end

--
--- ∑ Parses a quoted string starting at the opening quote.
--- @return string, number # the value and the position after the closing quote
--
local function _decodeString(st, pos)
    local s = st.s
    local quote = sbyte(s, pos)
    local i = pos + 1
    local _, stop, captured
    if quote == 34 then
        _, stop, captured = sfind(s, '^([^"\\%c]*)"', i)
    else
        _, stop, captured = sfind(s, "^([^'\\%c]*)'", i)
    end
    if stop then return captured, stop + 1 end
    local buf, n = {}, 0
    local chunkPattern = (quote == 34) and '^([^"\\]*)' or "^([^'\\]*)"
    while true do
        local _, chunkEnd, chunk = sfind(s, chunkPattern, i)
        if #chunk > 0 then
            if not st.lenient and sfind(chunk, "%c") then
                _failAt(st, i, "Raw control character in string")
            end
            n = n + 1
            buf[n] = chunk
        end
        i = chunkEnd + 1
        local byte = sbyte(s, i)
        if byte == nil then
            _failAt(st, pos, "Unterminated string")
        elseif byte == quote then
            i = i + 1
            break
        end
        -- byte is a backslash here
        i = i + 1
        local escape = sbyte(s, i)
        if escape == nil then
            _failAt(st, i, "Unterminated escape sequence")
        end
        local simple = UNESCAPE[escape]
        if simple then
            n = n + 1
            buf[n] = simple
            i = i + 1
        elseif escape == 117 then -- 'u'
            local hex = ssub(s, i + 1, i + 4)
            if #hex < 4 or sfind(hex, "%X") then
                _failAt(st, i, "Malformed \\u escape sequence")
            end
            local cp = tonumber(hex, 16)
            i = i + 5
            if cp >= 0xD800 and cp <= 0xDBFF then
                local paired = false
                if sbyte(s, i) == 92 and sbyte(s, i + 1) == 117 then
                    local lowHex = ssub(s, i + 2, i + 5)
                    if #lowHex == 4 and not sfind(lowHex, "%X") then
                        local low = tonumber(lowHex, 16)
                        if low >= 0xDC00 and low <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
                            i = i + 6
                            paired = true
                        end
                    end
                end
                if not paired then
                    local mode = st.unpairedSurrogate
                    if mode == "error" then
                        _failAt(st, i, "Unpaired UTF-16 high surrogate in \\u escape")
                    elseif mode == "replace" then
                        cp = 0xFFFD
                    end
                end
            elseif cp >= 0xDC00 and cp <= 0xDFFF then
                local mode = st.unpairedSurrogate
                if mode == "error" then
                    _failAt(st, i, "Unpaired UTF-16 low surrogate in \\u escape")
                elseif mode == "replace" then
                    cp = 0xFFFD
                end
            end
            n = n + 1
            buf[n] = _utf8Char(cp)
        elseif st.lenient then
            n = n + 1
            buf[n] = schar(escape)
            i = i + 1
        else
            _failAt(st, i, "Invalid escape character '\\" .. schar(escape) .. "'")
        end
    end
    return tconcat(buf, "", 1, n), i
end

--
--- ∑ Parses a JSON number.
--
local function _decodeNumber(st, pos)
    local s = st.s
    local start = pos
    local byte = sbyte(s, pos)
    local isFloat = false
    if byte == 45 then                       -- '-'
        pos = pos + 1
        byte = sbyte(s, pos)
    elseif st.lenient and byte == 43 then    -- '+'
        pos = pos + 1
        byte = sbyte(s, pos)
        start = pos
    end
    if st.lenient then
        if sfind(s, "^Infinity", pos) then
            return (sbyte(s, start) == 45 or ssub(s, start, start) == "-") and -mhuge or mhuge, pos + 8
        elseif sfind(s, "^NaN", pos) then
            return 0 / 0, pos + 3
        end
    end
    if byte == 48 then                       -- '0'
        pos = pos + 1
        local next = sbyte(s, pos)
        if not st.lenient and next and next >= 48 and next <= 57 then
            _failAt(st, pos, "Numbers may not have leading zeros")
        end
    elseif byte and byte >= 49 and byte <= 57 then
        local _, stop = sfind(s, "^[0-9]+", pos)
        pos = stop + 1
    elseif st.lenient and byte == 46 then    -- ".5"
        -- handled by the fraction block below
    else
        _failAt(st, pos, "Invalid number literal")
    end
    byte = sbyte(s, pos)
    if byte == 46 then                       -- '.'
        isFloat = true
        local _, stop = sfind(s, "^[0-9]+", pos + 1)
        if stop then
            pos = stop + 1
        elseif st.lenient then
            pos = pos + 1
        else
            _failAt(st, pos + 1, "Expected digits after the decimal point")
        end
        byte = sbyte(s, pos)
    end
    if byte == 101 or byte == 69 then        -- 'e' / 'E'
        isFloat = true
        local exponent = pos + 1
        local sign = sbyte(s, exponent)
        if sign == 43 or sign == 45 then exponent = exponent + 1 end
        local _, stop = sfind(s, "^[0-9]+", exponent)
        if not stop then
            _failAt(st, exponent, "Expected digits in the exponent")
        end
        pos = stop + 1
    end
    local token = ssub(s, start, pos - 1)
    local value = tonumber(token)
    if value == nil then
        _failAt(st, start, "Invalid number literal '" .. token .. "'")
    end
    if not isFloat and mtointeger then
        local integer = mtointeger(value)
        if integer then
            value = integer
        elseif st.bigIntAsString then
            return token, pos
        end
    end
    return value, pos
end

local _decodeValue -- forward declaration, recursion

local function _decodeArray(st, pos, depth)
    if depth > st.maxDepth then
        _failAt(st, pos, "Maximum nesting depth of " .. st.maxDepth .. " exceeded")
    end
    local s = st.s
    local skip = st.skip
    local result, count = {}, 0
    pos = skip(s, pos + 1, st)
    if sbyte(s, pos) == 93 then -- ']'
        if st.markTables then setmetatable(result, ARRAY_MT) end
        return result, pos + 1
    end
    while true do
        local value
        value, pos = _decodeValue(st, pos, depth + 1)
        count = count + 1
        result[count] = value
        pos = skip(s, pos, st)
        local byte = sbyte(s, pos)
        if byte == 44 then      -- ','
            pos = skip(s, pos + 1, st)
            if sbyte(s, pos) == 93 then
                if not st.allowTrailingComma then
                    _failAt(st, pos, "Trailing comma in array")
                end
                pos = pos + 1
                break
            end
        elseif byte == 93 then  -- ']'
            pos = pos + 1
            break
        elseif byte == nil then
            _failAt(st, pos, "Unterminated array")
        else
            _failAt(st, pos, "Expected ',' or ']' in array")
        end
    end
    if st.markTables then setmetatable(result, ARRAY_MT) end
    return result, pos
end

local function _decodeObject(st, pos, depth)
    if depth > st.maxDepth then
        _failAt(st, pos, "Maximum nesting depth of " .. st.maxDepth .. " exceeded")
    end
    local s = st.s
    local skip = st.skip
    local result = {}
    local order, orderCount = nil, 0
    if st.recordKeyOrder then order = {} end
    pos = skip(s, pos + 1, st)
    if sbyte(s, pos) == 125 then -- '}'
        if st.markTables then
            setmetatable(result, order and { [KIND_KEY] = "object", [ORDER_KEY] = order } or OBJECT_MT)
        end
        return result, pos + 1
    end
    while true do
        local byte = sbyte(s, pos)
        local key
        if byte == 34 then
            key, pos = _decodeString(st, pos)
        elseif byte == 39 and st.allowSingleQuotes then
            key, pos = _decodeString(st, pos)
        elseif st.allowUnquotedKeys and byte and sfind(s, "^[%a_$]", pos) then
            local _, stop = sfind(s, "^[%w_$]+", pos)
            key = ssub(s, pos, stop)
            pos = stop + 1
        elseif byte == nil then
            _failAt(st, pos, "Unterminated object")
        else
            _failAt(st, pos, "Expected a string key in object")
        end
        if not st.allowDuplicateKeys and result[key] ~= nil then
            _failAt(st, pos, "Duplicate object key '" .. tostring(key) .. "'")
        end
        pos = skip(s, pos, st)
        if sbyte(s, pos) ~= 58 then -- ':'
            _failAt(st, pos, "Expected ':' after object key")
        end
        pos = skip(s, pos + 1, st)
        local value
        value, pos = _decodeValue(st, pos, depth + 1)
        if order and result[key] == nil then
            orderCount = orderCount + 1
            order[orderCount] = key
        end
        result[key] = value
        pos = skip(s, pos, st)
        byte = sbyte(s, pos)
        if byte == 44 then      -- ','
            pos = skip(s, pos + 1, st)
            if sbyte(s, pos) == 125 then
                if not st.allowTrailingComma then
                    _failAt(st, pos, "Trailing comma in object")
                end
                pos = pos + 1
                break
            end
        elseif byte == 125 then -- '}'
            pos = pos + 1
            break
        elseif byte == nil then
            _failAt(st, pos, "Unterminated object")
        else
            _failAt(st, pos, "Expected ',' or '}' in object")
        end
    end
    if st.markTables then
        setmetatable(result, order and { [KIND_KEY] = "object", [ORDER_KEY] = order } or OBJECT_MT)
    end
    return result, pos
end

--
--- ∑ Parses any JSON value at the given position.
--
_decodeValue = function(st, pos, depth)
    local s = st.s
    local byte = sbyte(s, pos)
    if byte == 34 then                                   -- '"'
        return _decodeString(st, pos)
    elseif byte == 123 then                              -- '{'
        return _decodeObject(st, pos, depth)
    elseif byte == 91 then                               -- '['
        return _decodeArray(st, pos, depth)
    elseif byte == 116 then                              -- 't'
        if sfind(s, "^true", pos) then return true, pos + 4 end
    elseif byte == 102 then                              -- 'f'
        if sfind(s, "^false", pos) then return false, pos + 5 end
    elseif byte == 110 then                              -- 'n'
        if sfind(s, "^null", pos) then return st.null, pos + 4 end
    elseif byte == 45 or (byte and byte >= 48 and byte <= 57) then
        return _decodeNumber(st, pos)
    elseif byte == nil then
        _failAt(st, pos, "Unexpected end of input")
    end
    if st.lenient then
        if byte == 39 and st.allowSingleQuotes then
            return _decodeString(st, pos)
        elseif byte == 43 or byte == 46 or byte == 73 or byte == 78 then -- '+' '.' 'I' 'N'
            return _decodeNumber(st, pos)
        end
    end
    _failAt(st, pos, "Unexpected character '" .. ssub(s, pos, pos) .. "'")
end

--
--- ∑ Builds the decoder state for one call.
--
local function _decodeState(text, options)
    local lenient = _pick(options, "Lenient", false) and true or false
    local function flag(key)
        if lenient then return true end
        return _pick(options, key, false) and true or false
    end
    local allowComments = flag("AllowComments")
    -- Null is resolved by hand because "false" is a meaningful value here:
    -- it means "drop null members entirely" rather than "use the default".
    local nullValue
    if options ~= nil and options.Null ~= nil then
        nullValue = options.Null
    else
        local defaults = Json.Defaults
        nullValue = defaults and defaults.Null
        if nullValue == nil then nullValue = Null end
    end
    if nullValue == false then nullValue = nil end
    return {
        s                  = text,
        null               = nullValue,
        lenient            = lenient,
        markTables         = _pick(options, "MarkTables", true) and true or false,
        recordKeyOrder     = _pick(options, "RecordKeyOrder", false) and true or false,
        allowTrailingComma = flag("AllowTrailingComma"),
        allowSingleQuotes  = flag("AllowSingleQuotes"),
        allowUnquotedKeys  = flag("AllowUnquotedKeys"),
        allowTrailingData  = flag("AllowTrailingData"),
        allowDuplicateKeys = _pick(options, "AllowDuplicateKeys", true) and true or false,
        bigIntAsString     = _pick(options, "BigIntAsString", false) and true or false,
        unpairedSurrogate  = _pick(options, "UnpairedSurrogate", "replace"),
        maxDepth           = _pick(options, "MaxDepth", 200),
        skip               = allowComments and _skipSpaceAndComments or _skipSpace,
    }
end

--
--- ∑ Decoder entry point.
--

--
--- ∑ The whole decode pass, so that every failure — including the ones raised
---   while skipping leading comments or while checking for trailing data —
---   unwinds into the single pcall below instead of escaping the module.
--
local function _decodeTop(st)
    local text = st.s
    local skip = st.skip
    local start = 1
    if sbyte(text, 1) == 239 and sbyte(text, 2) == 187 and sbyte(text, 3) == 191 then
        start = 4 -- UTF-8 BOM
    end
    start = skip(text, start, st)
    if start > #text then
        _fail("Cannot decode empty input.")
    end
    local value, stop = _decodeValue(st, start, 1)
    if not st.allowTrailingData then
        local tail = skip(text, stop, st)
        if tail <= #text then
            _failAt(st, tail, "Trailing data after the top level value")
        end
    end
    return value
end

--
--- ∑ Decoder entry point.
--- @param text any
--- @param options table|nil
--- @param quiet boolean|nil # suppresses reporting. Set by Json.Validate only,
---                            where a rejection is the expected answer rather
---                            than a fault.
--
local function _decode(text, options, quiet)
    if type(text) ~= "string" then
        -- Returns before the pcall, so it never reaches the failure branch
        -- below and needs its own report. This is almost always an unchecked
        -- file read that produced nil, and it is invisible today: CustomIO
        -- flattens it into "Failed to parse JSON: %s" and Patcher pcalls and
        -- discards the message entirely.
        local message = MODULE_PREFIX .. " Decode expects a string, got " .. type(text) .. "."
        if not quiet and logger and logger.Error then
            pcall(logger.Error, logger, message)
        end
        return nil, message
    end
    -- Json.Debug is read first so a disabled flag short-circuits before the
    -- logger global is even touched. Per call, never per value.
    local tracing = Json.Debug and logger and logger.Debug
    local started = tracing and os.clock() or nil
    local st = _decodeState(text, options)
    local ok, value = pcall(_decodeTop, st)
    if not ok then
        -- See the note in _encode: after the pcall, always. _failAt has already
        -- embedded "(line N, column M)", which proves WHERE; the excerpt adds
        -- what was actually there, which is what tells a maintainer whether
        -- they are looking at broken JSON, an HTML error page, an empty file
        -- or a truncated download. The excerpt is appended to the LOGGED text
        -- only - the returned message is unchanged, so callers that match on
        -- error strings keep working.
        local message, internal = _unwrapError(value)
        if not quiet and logger then
            local detail = message .. " | input=" .. #text .. "B"
            local near = _excerpt(text, st.errPos)
            if near then detail = detail .. " near " .. near end
            if internal then
                if logger.Critical then pcall(logger.Critical, logger, _logSafe(detail)) end
            elseif logger.Error then
                pcall(logger.Error, logger, _logSafe(detail))
            end
        end
        return nil, message
    end
    if tracing then
        pcall(logger.Debug, logger, sformat("%s Decoded %d bytes in %.3fs.",
              MODULE_PREFIX, #text, os.clock() - started))
    end
    return value
end

----------------------------------------------------------------
-- Public API
--
-- Every entry point below is call-style agnostic. Json.Encode(v),
-- Json:Encode(v), instance:Encode(v) and a detached "local f = json.Encode"
-- all behave identically. There is deliberately no "must be called in method
-- format" guard anywhere in this module.
----------------------------------------------------------------

--
--- ∑ Normalises the argument list of a public call.
---   Drops a leading self, then accepts an options table in either the second
---   or the third slot (the third slot keeps the legacy "(value, etc, options)"
---   signature working).
--
local function _shiftArgs(a, b, c, d)
    if _isModuleSelf(a) then a, b, c = b, c, d end
    local options
    if type(c) == "table" then
        options = c
    elseif type(b) == "table" then
        options = b
    end
    return a, options
end

--
--- ∑ Encodes a Lua value into compact JSON.
--- @param value any   # the value to encode
--- @param options table|nil # per-call overrides, see Json.Defaults
--- @return string|nil # the JSON text, or nil on failure
--- @return string|nil # the error message when encoding failed
--
function Json.Encode(a, b, c, d)
    local value, raw = _shiftArgs(a, b, c, d)
    return _encode(value, _normalizeOptions(raw, ENCODE_ALIASES), false)
end
registerLuaFunctionHighlight('Encode')

--
--- ∑ Encodes a Lua value into indented, human readable JSON.
--- @param value any
--- @param options table|nil # per-call overrides, see Json.Defaults
--- @return string|nil, string|nil
--
function Json.EncodePretty(a, b, c, d)
    local value, raw = _shiftArgs(a, b, c, d)
    return _encode(value, _normalizeOptions(raw, ENCODE_ALIASES), true)
end
registerLuaFunctionHighlight('EncodePretty')

--
--- ∑ Decodes JSON text into a Lua value.
---   JSON null becomes Json.Null so it survives inside tables; pass
---   { Null = false } to drop null members instead.
--- @param text string
--- @param options table|nil # per-call overrides, see Json.Defaults
--- @return any|nil     # the decoded value, or nil on failure
--- @return string|nil  # the error message when decoding failed
--
function Json.Decode(a, b, c, d)
    local text, raw = _shiftArgs(a, b, c, d)
    return _decode(text, _normalizeOptions(raw, DECODE_ALIASES))
end
registerLuaFunctionHighlight('Decode')

--
--- ∑ Checks whether a string is valid JSON.
---   Decodes quietly. A rejection is what this function is FOR, so letting the
---   failure report fire here would make the one API whose failure is a normal
---   outcome the loudest thing in an end user's log file. Set Json.Debug to
---   see rejections, or call Json.Decode when you want them at Error level.
--- @param text string
--- @param options table|nil
--- @return boolean, string|nil
--
function Json.Validate(a, b, c, d)
    local text, raw = _shiftArgs(a, b, c, d)
    local _, err = _decode(text, _normalizeOptions(raw, DECODE_ALIASES), true)
    if err then
        if Json.Debug and logger and logger.Debug then
            -- "err" already starts with MODULE_PREFIX, so the context is
            -- appended rather than prepended.
            pcall(logger.Debug, logger, _logSafe(err) .. " (via Json.Validate)")
        end
        return false, err
    end
    return true
end
registerLuaFunctionHighlight('Validate')

--
--- ∑ Enables or disables per-call diagnostics.
---   Free when off. Turn it on only while reproducing a problem: Manifold.
---   Logger writes the log file before applying its level filter, so every
---   emitted line costs real file I/O no matter which level it carries.
--- @param enabled boolean
--- @return boolean # the resulting state
--
function Json.SetDebug(a, b)
    local enabled = _isModuleSelf(a) and b or a
    enabled = enabled and true or false
    if Json.Debug == enabled then return enabled end
    Json.Debug = enabled
    if logger and logger.Info then
        logger:Info(MODULE_PREFIX .. " Debug logging " .. (enabled and "enabled." or "disabled."))
    end
    return enabled
end
registerLuaFunctionHighlight('SetDebug')

--
--- ∑ Re-encodes JSON text without whitespace.
--- @param text string
--- @return string|nil, string|nil
--
function Json.Minify(a, b, c, d)
    local text, raw = _shiftArgs(a, b, c, d)
    local value, err = _decode(text, _normalizeOptions(raw, DECODE_ALIASES))
    if err then return nil, err end
    return _encode(value, nil, false)
end
registerLuaFunctionHighlight('Minify')

--
--- ∑ Re-encodes JSON text with indentation.
--- @param text string
--- @param options table|nil
--- @return string|nil, string|nil
--
function Json.Prettify(a, b, c, d)
    local text, raw = _shiftArgs(a, b, c, d)
    local options = _normalizeOptions(raw, DECODE_ALIASES)
    local decodeOptions = options
    if decodeOptions == nil then decodeOptions = {} end
    if decodeOptions.RecordKeyOrder == nil then decodeOptions.RecordKeyOrder = true end
    local value, err = _decode(text, decodeOptions)
    if err then return nil, err end
    return _encode(value, _normalizeOptions(raw, ENCODE_ALIASES), true)
end
registerLuaFunctionHighlight('Prettify')

--
--- ∑ Tags a table so it always encodes as a JSON array, even when empty.
--- @param t table|nil
--- @return table
--
function Json.NewArray(a, b)
    local t = _isModuleSelf(a) and b or a
    return setmetatable(type(t) == "table" and t or {}, ARRAY_MT)
end
registerLuaFunctionHighlight('NewArray')

--
--- ∑ Tags a table so it always encodes as a JSON object, even when empty.
--- @param t table|nil
--- @return table
--
function Json.NewObject(a, b)
    local t = _isModuleSelf(a) and b or a
    return setmetatable(type(t) == "table" and t or {}, OBJECT_MT)
end
registerLuaFunctionHighlight('NewObject')

--
--- ∑ Reports whether a value is the JSON null sentinel.
--- @param v any
--- @return boolean
--
function Json.IsNull(a, b)
    local v = _isModuleSelf(a) and b or a
    return _isNull(v)
end
registerLuaFunctionHighlight('IsNull')

--
--- ∑ Reports whether a table carries the explicit array marker.
--- @param v any
--- @return boolean
--
function Json.IsArray(a, b)
    local v = _isModuleSelf(a) and b or a
    return type(v) == "table" and _markerKind(v) == "array"
end
registerLuaFunctionHighlight('IsArray')

--
--- ∑ Reports whether a table carries the explicit object marker.
--- @param v any
--- @return boolean
--
function Json.IsObject(a, b)
    local v = _isModuleSelf(a) and b or a
    return type(v) == "table" and _markerKind(v) == "object"
end
registerLuaFunctionHighlight('IsObject')

----------------------------------------------------------------
-- Compatibility layer
-- Keeps every call site that was written against the previous JSON module
-- working unchanged: JSON:new(), json:encode(), json:encode_pretty() and
-- json:decode() all route into the implementations above.
----------------------------------------------------------------

Json.VERSION = VERSION

Json.new           = Json.New
Json.encode        = Json.Encode
Json.encode_pretty = Json.EncodePretty
Json.decode        = Json.Decode
Json.newArray      = Json.NewArray
Json.newObject     = Json.NewObject
Json.null          = Null

function Json.__tostring()
    return "Manifold.Json " .. VERSION
end

--
--- Legacy global. Existing modules construct their instance with JSON:new(),
--- so the alias keeps them working without edits.
--
JSON = Json

--------------------------------------------------------
--                   Module End                       --
--------------------------------------------------------

return Json
