--[[
    The file type registry.

    One place decides what an extension means. Before this module the answer
    was spread over the viewer as repeated extension tests, which is how a
    highlighter mode and an icon colour end up disagreeing about the same
    file.

    A type record carries everything the rest of the tool asks about a file:

        Key          stable identifier, used as the image list key
        Extension    lower case, without the dot ("" for no extension)
        Display      human readable name for the Type column
        Category     "script" | "assembler" | "data" | "text" | "other"
        Mode         createSynEdit's second argument, or nil for plain text
        Color        accent colour as a Cheat Engine BGR integer
        IsText       whether the file is edited as text at all
        Highlighted  whether Cheat Engine can colour it

    Colours are BGR integers, which is what Cheat Engine's Canvas and Font
    take. The comment on each line is the familiar #RRGGBB form. They are
    muted on purpose: the file name is the information, the icon only helps
    the eye find a row.
]]

local Types = {}
Types.__index = Types

--
--- ∑ Turns #RRGGBB into the BGR integer Cheat Engine wants.
---   Kept here rather than in the theme so the table below can be read and
---   edited in the notation everyone writes colours in.
--- @param rgb number # 0xRRGGBB.
--- @return number # 0xBBGGRR.
--
local function bgr(rgb)
    local r = math.floor(rgb / 0x10000) % 0x100
    local g = math.floor(rgb / 0x100) % 0x100
    local b = rgb % 0x100
    return b * 0x10000 + g * 0x100 + r
end

Types.ToBGR = bgr

--- The order here is the order the New File dialog offers them in.
Types.Definitions = {
    {
        Key = "lua", Offer = true, Extension = "lua", Display = "Lua Script",
        Category = "script", Mode = 0, Color = bgr(0x4FA6D9),
        IsText = true, Highlighted = true,
        Template = "--[[\n    %s\n]]\n\n"
    },
    {
        Key = "cea", Offer = true, Extension = "cea", Display = "Auto Assembler",
        Category = "assembler", Mode = 1, Color = bgr(0xD9534F),
        IsText = true, Highlighted = true,
        Template = "[ENABLE]\n\n\n[DISABLE]\n\n"
    },
    {
        Key = "aa", Offer = true, Extension = "aa", Display = "Auto Assembler",
        Category = "assembler", Mode = 1, Color = bgr(0xD9534F),
        IsText = true, Highlighted = true,
        Template = "[ENABLE]\n\n\n[DISABLE]\n\n"
    },
    {
        Key = "asm", Extension = "asm", Display = "Assembly",
        Category = "assembler", Mode = 1, Color = bgr(0xC05A4E),
        IsText = true, Highlighted = true
    },
    {
        -- Cheat Engine has no JSON highlighter, and the Lua one would colour
        -- the wrong tokens. Plain text is the honest choice.
        Key = "json", Offer = true, Extension = "json", Display = "JSON",
        Category = "data", Mode = nil, Color = bgr(0xD9A441),
        IsText = true, Highlighted = false,
        Template = "{\n}\n"
    },
    {
        Key = "txt", Offer = true, Extension = "txt", Display = "Text",
        Category = "text", Mode = nil, Color = bgr(0x8D9BA8),
        IsText = true, Highlighted = false
    },
    {
        Key = "xml", Extension = "xml", Display = "XML",
        Category = "data", Mode = nil, Color = bgr(0xD9A441),
        IsText = true, Highlighted = false
    },
    {
        Key = "csv", Extension = "csv", Display = "CSV",
        Category = "data", Mode = nil, Color = bgr(0xD9A441),
        IsText = true, Highlighted = false
    },
    {
        Key = "ini", Extension = "ini", Display = "Config",
        Category = "data", Mode = nil, Color = bgr(0xD9A441),
        IsText = true, Highlighted = false
    },
    {
        Key = "md", Extension = "md", Display = "Markdown",
        Category = "text", Mode = nil, Color = bgr(0x8D9BA8),
        IsText = true, Highlighted = false
    }
}

--- Anything not in the table. Treated as text until the contents say
--- otherwise, because most things people attach are.
Types.Unknown = {
    Key = "other", Extension = "", Display = "Other",
    Category = "other", Mode = nil, Color = bgr(0x6E7A85),
    IsText = true, Highlighted = false
}

--- What a file turns out to be once its bytes have been looked at. Not
--- reachable by extension: it is the answer to "this is not text after all".
Types.Binary = {
    Key = "binary", Extension = "", Display = "Binary",
    Category = "other", Mode = nil, Color = bgr(0x9A6BB5),
    IsText = false, Highlighted = false
}

local byExtension = nil

local function index()
    if byExtension then return byExtension end
    byExtension = {}
    for _, definition in ipairs(Types.Definitions) do
        byExtension[definition.Extension] = definition
    end
    return byExtension
end

--
--- ∑ The extension of a file name, lower case and without the dot.
--- @param fileName string # The file name.
--- @return string # The extension, or "" when there is none.
--
function Types.ExtensionOf(fileName)
    return (tostring(fileName or ""):match("%.([%w_]+)$") or ""):lower()
end

--
--- ∑ The type record for a file name. Never nil.
--- @param fileName string # The file name.
--- @return table # A type record; Types.Unknown for anything unrecognised.
--
function Types.For(fileName)
    return index()[Types.ExtensionOf(fileName)] or Types.Unknown
end

--
--- ∑ Every distinct type record, including the two that no extension maps
---   to. This is what the image list builds its icons from, so every key the
---   viewer can ask for has a picture.
--- @return table # Array of type records, each Key appearing once.
--
function Types.All()
    local seen, all = {}, {}
    for _, definition in ipairs(Types.Definitions) do
        if not seen[definition.Key] then
            seen[definition.Key] = true
            all[#all + 1] = definition
        end
    end
    all[#all + 1] = Types.Unknown
    all[#all + 1] = Types.Binary
    return all
end

--
--- ∑ The types the New File dialog puts a button on, in order.
---   Deliberately a short list. Every text type can still be created by
---   typing its extension into the name, and a dialog with a button per
---   known extension does not fit across the screen: eleven of them ran off
---   the left edge where they could not be clicked at all.
--- @return table # Array of type records.
--
function Types.Creatable()
    local creatable = {}
    for _, definition in ipairs(Types.Definitions) do
        if definition.Offer then creatable[#creatable + 1] = definition end
    end
    return creatable
end

--
--- ∑ The type whose starter content a new file should get, by extension.
--- @param extension string # Without the dot.
--- @return table|nil # The type record, or nil when it is not a known one.
--
function Types.ByExtension(extension)
    return index()[tostring(extension or ""):lower()]
end

--
--- ∑ Which editor a type is shown in. Three exist because createSynEdit
---   fixes the highlighter at construction time, so one control cannot
---   switch languages.
--- @param typeRecord table # A type record.
--- @return string # "lua", "asm" or "text".
--
function Types.EditorKeyFor(typeRecord)
    local mode = typeRecord and typeRecord.Mode
    if mode == 0 then return "lua" end
    if mode == 1 then return "asm" end
    return "text"
end

return Types
