--[[
    Settings for "Example - Full Capability", and at the same time the
    documentation of every schema-2 settings feature.

    Settings files are DATA. They run in a minimal sandbox (ipairs, pairs,
    tonumber, tostring, math, string, table, the library tables are copies)
    with no io, no os, no _G and no Cheat Engine APIs. Anything that needs
    code belongs in a provider or an extension, not here.
]]

return {
    -- Schema 2 enables Id/Category/Requires/Inputs/... . Files without a
    -- SchemaVersion are treated as legacy (schema 1) and keep 2.x behaviour,
    -- including the unrestricted template environment.
    SchemaVersion = 2,

    -- Stable identity. Favorites, Recent, diagnostics and validation key on
    -- this, never on the caption. Legacy templates get "legacy.<file-name>".
    Id = "manifold.example.full-capability",

    -- Menu text (must be unique across all templates).
    Caption = "Example — Full Capability",

    -- Metadata for diagnostics, validation and future browsing UIs.
    Description = "Living reference template demonstrating the full template API.",
    Author = "Leunsel",
    Version = "1.0.0",
    Tags = { "example", "reference", "pointer" },

    -- '>' nests categories. CategoryOrder replaces the legacy "[n] " prefix
    -- (which still works for legacy templates).
    Category = "Examples",
    CategoryOrder = 14,
    -- Order sorts templates inside their category.
    Order = 10,

    -- InSubMenu = false would place the entry at the template root.
    InSubMenu = true,

    -- Optional keyboard shortcut, e.g. "Ctrl+Alt+E". Conflicts are detected
    -- and the second registration loses its shortcut.
    Shortcut = "",

    -- The context contract. Generation aborts with an explanation BEFORE
    -- anything renders when one of these cannot be resolved. Order matters
    -- for the user prompts (address before hook name).
    Requires = {
        "AddressValue", "Module", "HookName",
        "AoBStr", "OriginalBytes", "BaseAddressRegister"
    },

    -- Resolved if possible. The template must cope with nil/empty.
    Optional = {
        "BaseAddressOffset"
    },

    -- Restrict to one architecture with { "x64" }, this example runs on both.
    Architectures = { "x86", "x64" },

    -- Declared framework requirements. This template does NOT list
    -- "Manifold.AssemblerCommands". << ScanModule >> and << AssertBytes >>
    -- fall back to aobScanModule and assert, so it works either way.
    -- Templates that genuinely cannot work without the framework (the
    -- trampoline ones, the static resolver) declare the capability and the
    -- loader warns before generating.
    Capabilities = {},

    -- Schema-2 templates render in a restricted environment (helpers,
    -- context variables and a safe stdlib subset). Set this to true only if
    -- a template genuinely needs _G access like legacy templates have.
    AllowUnsafeGlobals = false,

    -- Declarative inputs. The dialog appears only because this list is
    -- non-empty. Values are available as plain template variables.
    Inputs = {
        {
            Name = "CompareRegister",
            Type = "string",
            Caption = "Compare Register",
            Default = "rax"
        },
        {
            Name = "UseReadMem",
            Type = "boolean",
            Caption = "Use readMem restore",
            Default = true
        },
        {
            Name = "PointerCount",
            Type = "integer",
            Caption = "Pointer slots",
            Default = 2,
            Min = 1,
            Max = 16
        },
        {
            Name = "RegisterMode",
            Type = "enum",
            Caption = "Register Mode",
            Values = { "Player", "Entity", "Both" },
            Default = "Both"
        }
    },

    -- Per-template memory overrides (the nested block is preferred in
    -- schema 2. The flat legacy fields still work).
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook",
        AllocationSize = "$1000",
        AllocationNear = true
    }
}
