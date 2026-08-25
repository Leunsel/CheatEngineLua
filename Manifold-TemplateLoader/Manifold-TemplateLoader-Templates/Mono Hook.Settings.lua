return {
    SchemaVersion = 2,
    Id = "manifold.mono.hook",
    Caption = "Mono Hook",
    Description = "Code cave hook on a managed method, resolved by name through FINDMONOMETHOD.",
    Author = "Leunsel",
    Version = "1.0.0",
    Category = "Mono — Managed Hooks",
    CategoryOrder = 13,
    Order = 10,
    Tags = { "mono", "managed" },
    Architectures = { "x86", "x64" },
    -- Cheat Engine's own Mono support, which autorun/monoscript.lua registers.
    -- Without it there is no USEMONO and no FINDMONOMETHOD.
    Capabilities = { "Mono.Runtime" },
    -- MonoDescriptor and MonoResolve are nil when the address is not inside a
    -- JIT compiled method, so requiring them stops the generation early with a
    -- readable reason. MonoIsJitted is a boolean and would pass the check even
    -- when false, so it is deliberately not listed here.
    Requires = {
        "AddressValue", "HookName",
        "MonoDescriptor", "MonoResolve", "JumpSize"
    },
    Memory = {
        AskForInjectionAddress = false,
        AskForHookName = true,
        AppendToHookName = "Hook",
        AllocationSize = "$1000",
        AllocationNear = true
    }
}
