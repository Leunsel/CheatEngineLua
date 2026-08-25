return {
    SchemaVersion = 2,
    Id = "manifold.mono.bytepatch",
    Caption = "Mono Byte Patch",
    Description = "Makes a managed method return immediately, or nops the selected instruction.",
    Author = "Leunsel",
    Version = "1.0.0",
    Category = "Mono — Managed Hooks",
    CategoryOrder = 13,
    Order = 30,
    Tags = { "mono", "managed", "bytepatch" },
    -- The return patches encode the x64 result registers, so this template
    -- stays off x86 rather than emitting bytes that mean something else there.
    Architectures = { "x64" },
    Capabilities = { "Mono.Runtime" },
    Requires = {
        "AddressValue", "HookName",
        "MonoDescriptor", "MonoResolve", "SelectionSize"
    },
    Inputs = {
        {
            Name = "PatchKind",
            Type = "enum",
            Caption = "Patch",
            Values = { "Return", "Return True", "Return False", "Return Zero", "Nop" },
            Default = "Return"
        }
    },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Patch",
        AllocationSize = "$100",
        AllocationNear = false
    }
}
