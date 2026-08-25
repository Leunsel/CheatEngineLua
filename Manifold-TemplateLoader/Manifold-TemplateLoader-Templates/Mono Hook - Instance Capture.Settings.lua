return {
    SchemaVersion = 2,
    Id = "manifold.mono.instance",
    Caption = "Mono Hook — Instance Capture",
    Description = "Prologue hook that stores an argument register, usually the object in rcx.",
    Author = "Leunsel",
    Version = "1.0.0",
    Category = "Mono — Managed Hooks",
    CategoryOrder = 13,
    Order = 20,
    Tags = { "mono", "managed", "pointer" },
    -- The register names below are the x64 argument registers, so this one
    -- does not offer itself on x86.
    Architectures = { "x64" },
    Capabilities = { "Mono.Runtime" },
    Requires = {
        "AddressValue", "HookName",
        "MonoDescriptor", "MonoResolve", "JumpSize"
    },
    Inputs = {
        {
            Name = "CaptureRegister",
            Type = "enum",
            Caption = "Argument Register",
            Values = { "rcx", "rdx", "r8", "r9" },
            Default = "rcx"
        }
    },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook",
        AllocationSize = "$1000",
        AllocationNear = true
    }
}
