return {
    SchemaVersion = 2,
    Id = "manifold.patch.replace",
    Caption = "Byte Replacement Hook",
    Description = "Overwrites the bytes at the signature and restores them on disable. " ..
                  "Nop the span, return early, return a value, or write your own bytes.",
    Category = "x86/x64 — Byte Patch Hooks",
    CategoryOrder = 7,
    Order = 10,
    Tags = { "patch", "bytes", "nop", "ret" },

    Requires = {
        "AddressValue", "Module", "AoBStr",
        "OriginalBytes", "JumpSize"
    },
    -- Only the Nop fallback path needs it, and only when the framework
    -- commands are unavailable.
    Optional = {
        "NopBytes"
    },
    Inputs = {
        {
            Name = "Mode",
            Type = "enum",
            Caption = "Replacement",
            Values = { "Nop", "Return", "Return value", "Custom bytes" },
            Default = "Nop"
        },
        {
            Name = "ReturnValue",
            Type = "integer",
            Caption = "Return value (mode: Return value)",
            Default = 1,
            Min = -2147483648,
            Max = 2147483647
        },
        {
            Name = "CustomBytes",
            Type = "string",
            Caption = "Bytes (mode: Custom bytes)",
            Default = "90 90 90"
        }
    },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook"
    }
}
